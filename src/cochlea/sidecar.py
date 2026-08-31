"""The protocol the macOS app speaks to the ASR process.

D5 puts inference in Python, so something has to carry audio from the Swift
capture path to it and text back. That something is this: a child process
speaking newline-delimited JSON over stdin and stdout, with raw audio following
the request line it belongs to.

A child process over pipes rather than a socket, deliberately. A socket needs a
port or a path, a permission story, a cleanup story when the app is killed, and
an answer for a second instance. A pipe to a child has none of those: the
kernel closes it when either side dies, and the child is owned by exactly one
app.

Framing::

    -> {"op": "transcribe", "samples": 98400}\\n   then samples*4 bytes
    <- {"ok": true, "text": "...", "language": "en", "inference_ms": 412}\\n

Audio is little-endian float32 at 16 kHz, mono, which is what
``AudioCapture`` already converts to and what Whisper's frontend consumes.
Little-endian is not a portability bug waiting to happen: both ends of this
pipe are the same Apple Silicon machine, and the header is checked against the
byte count so a mismatch is an error rather than noise.
"""

from __future__ import annotations

import array
import json
import sys
from pathlib import Path
from typing import BinaryIO

from .asr import ASRUnavailable, MLXWhisperBackend, SAMPLE_RATE

PROTOCOL_VERSION = 1


class ProtocolError(RuntimeError):
    pass


def _read_exactly(stream: BinaryIO, count: int) -> bytes:
    """Read exactly ``count`` bytes or raise.

    ``BufferedReader.read(n)`` is documented to return short reads, and audio
    arrives in whatever chunk sizes the pipe hands over. Treating a short read
    as the whole message silently truncates the utterance.
    """
    chunks = []
    remaining = count
    while remaining > 0:
        chunk = stream.read(remaining)
        if not chunk:
            raise ProtocolError(
                f"stream closed with {remaining} of {count} bytes unread")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def decode_samples(payload: bytes) -> array.array:
    """Little-endian float32 bytes to samples."""
    if len(payload) % 4:
        raise ProtocolError(f"{len(payload)} bytes is not a whole number of floats")
    samples = array.array("f")
    samples.frombytes(payload)
    if sys.byteorder != "little":                       # pragma: no cover
        samples.byteswap()
    return samples


def encode_samples(samples) -> bytes:
    """The inverse, for tests and for anything driving the sidecar from Python."""
    out = array.array("f", samples)
    if sys.byteorder != "little":                       # pragma: no cover
        out.byteswap()
    return out.tobytes()


class Sidecar:
    """One request/response cycle at a time, over two pipes.

    Single-threaded on purpose. The app holds the hotkey until the utterance
    ends, so there is exactly one transcription in flight, and concurrency here
    would buy nothing but a way to interleave two replies on one pipe.
    """

    def __init__(self, backend, stdin: BinaryIO, stdout: BinaryIO):
        self.backend = backend
        self.stdin = stdin
        self.stdout = stdout

    def _send(self, message: dict) -> None:
        self.stdout.write(json.dumps(message).encode("utf-8") + b"\n")
        self.stdout.flush()

    def announce(self) -> None:
        self._send({
            "ok": True,
            "op": "ready",
            "protocol": PROTOCOL_VERSION,
            "backend": self.backend.identifier,
            "sample_rate": SAMPLE_RATE,
        })

    def serve(self) -> int:
        self.announce()
        while True:
            line = self.stdin.readline()
            if not line:
                return 0                                # the app went away
            try:
                request = json.loads(line)
            except json.JSONDecodeError as exc:
                self._send({"ok": False, "kind": "protocol", "error": str(exc)})
                continue
            if request.get("op") == "shutdown":
                self._send({"ok": True, "op": "shutdown"})
                return 0
            try:
                self._send(self.handle(request))
            except ProtocolError as exc:
                # Framing is unrecoverable: the reader and writer no longer
                # agree on where the next message starts, so stopping is
                # honest and restarting the child is the app's job.
                self._send({"ok": False, "kind": "protocol", "error": str(exc)})
                return 1
            except ASRUnavailable as exc:
                self._send({"ok": False, "kind": "unavailable", "error": str(exc)})
            except Exception as exc:                    # noqa: BLE001
                self._send({"ok": False, "kind": "backend",
                            "error": f"{type(exc).__name__}: {exc}"})

    def handle(self, request: dict) -> dict:
        op = request.get("op")
        if op == "ping":
            return {"ok": True, "op": "ping"}
        if op == "warmup":
            self.backend.warm_up()
            return {"ok": True, "op": "warmup", "backend": self.backend.identifier}
        if op == "transcribe":
            declared = request.get("samples")
            if not isinstance(declared, int) or declared < 0:
                raise ProtocolError(f"bad sample count {declared!r}")
            payload = _read_exactly(self.stdin, declared * 4)
            samples = decode_samples(payload)
            result = self.backend.transcribe(samples, language=request.get("language"))
            return {
                "ok": True,
                "op": "transcribe",
                "text": result.text,
                "language": result.language,
                "inference_ms": result.inference_ms,
            }
        raise ProtocolError(f"unknown op {op!r}")


def _silence_stray_stdout() -> BinaryIO:
    """Take exclusive ownership of stdout, and send everyone else to stderr.

    This is not defensive tidiness. ``huggingface_hub`` writes progress bars and
    ``mlx_whisper`` writes decoded text to stdout, and a single stray byte
    between two JSON lines desynchronises the protocol for the rest of the
    session — as a parse error on whatever message happens to follow, which
    reads like a bug anywhere but here.

    Returns the real stdout buffer; after this call ``print`` goes to stderr,
    where the app can log it.
    """
    raw = sys.stdout.buffer
    sys.stdout = sys.stderr
    return raw


def serve(model_path: str | Path, *, identifier: str | None = None) -> int:
    """Entry point for ``dictate asr-serve``."""
    stdout = _silence_stray_stdout()
    try:
        backend = MLXWhisperBackend(model_path, identifier=identifier)
    except ASRUnavailable as exc:
        stdout.write(json.dumps(
            {"ok": False, "op": "ready", "kind": "unavailable",
             "error": str(exc)}).encode("utf-8") + b"\n")
        stdout.flush()
        return 1
    return Sidecar(backend, sys.stdin.buffer, stdout).serve()
