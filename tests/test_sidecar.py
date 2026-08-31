"""The protocol the macOS app speaks to the ASR process (D5).

Every test here runs with a fake backend and no MLX. That is the point: the
framing is where an audio pipe actually breaks — short reads, a declared length
that disagrees with the bytes, a backend that raises mid-utterance — and none
of those need Apple Silicon to provoke. Invariant 4 also requires this file to
pass on a text-only install, which CI's `text-only` job checks.
"""

import io
import json
import math

import pytest

from cochlea.asr import ASRUnavailable, Transcription
from cochlea.sidecar import (PROTOCOL_VERSION, ProtocolError, Sidecar,
                             _read_exactly, decode_samples, encode_samples)


class FakeBackend:
    identifier = "fake"

    def __init__(self, raises=None):
        self.raises = raises
        self.warmed = 0
        self.seen = []

    def warm_up(self):
        self.warmed += 1

    def transcribe(self, samples, language=None):
        if self.raises:
            raise self.raises
        self.seen.append((list(samples), language))
        return Transcription(text=f"{len(samples)} samples", language="en",
                             inference_ms=7)


def drive(requests: bytes, backend=None):
    """Run the server over a scripted stdin, return the replies it wrote."""
    backend = backend or FakeBackend()
    out = io.BytesIO()
    server = Sidecar(backend, io.BytesIO(requests), out)
    server.serve()
    out.seek(0)
    return [json.loads(line) for line in out.read().splitlines() if line], backend


def request(op, payload=b"", **fields):
    line = json.dumps({"op": op, **fields}).encode() + b"\n"
    return line + payload


# --- framing -----------------------------------------------------------------

def test_samples_round_trip_through_the_wire_format():
    original = [0.0, 1.0, -1.0, 0.25, -0.75]
    assert list(decode_samples(encode_samples(original))) == original


def test_a_truncated_float_is_an_error_not_a_silent_drop():
    with pytest.raises(ProtocolError):
        decode_samples(b"\x00\x00\x00")


def test_read_exactly_reassembles_a_short_read():
    """A pipe hands over whatever is buffered, not what was asked for."""

    class Dribbling(io.RawIOBase):
        def __init__(self, data):
            self.data, self.pos = data, 0

        def read(self, size=-1):
            chunk = self.data[self.pos:self.pos + 3]   # never more than 3
            self.pos += len(chunk)
            return chunk

    assert _read_exactly(Dribbling(b"0123456789"), 10) == b"0123456789"


def test_read_exactly_raises_when_the_stream_ends_early():
    with pytest.raises(ProtocolError):
        _read_exactly(io.BytesIO(b"123"), 10)


# --- the conversation --------------------------------------------------------

def test_ready_is_announced_before_any_request():
    replies, _ = drive(b"")
    assert replies[0]["op"] == "ready"
    assert replies[0]["protocol"] == PROTOCOL_VERSION
    assert replies[0]["ok"] is True


def test_warmup_loads_the_model_once():
    replies, backend = drive(request("warmup"))
    assert backend.warmed == 1
    assert replies[1] == {"ok": True, "op": "warmup", "backend": "fake"}


def test_transcribe_carries_audio_and_returns_text():
    samples = [0.5, -0.5, 0.25]
    replies, backend = drive(
        request("transcribe", encode_samples(samples), samples=len(samples)))
    assert replies[1]["text"] == "3 samples"
    assert replies[1]["language"] == "en"
    assert replies[1]["inference_ms"] == 7
    heard, language = backend.seen[0]
    assert language is None
    assert all(math.isclose(a, b, rel_tol=1e-6) for a, b in zip(heard, samples))


def test_language_is_passed_through_when_forced():
    _, backend = drive(request("transcribe", encode_samples([0.0]),
                               samples=1, language="zh"))
    assert backend.seen[0][1] == "zh"


def test_two_utterances_on_one_connection():
    """The model stays resident across utterances -- that is the whole point (F19)."""
    body = (request("transcribe", encode_samples([0.1, 0.2]), samples=2)
            + request("transcribe", encode_samples([0.3]), samples=1))
    replies, backend = drive(body)
    assert [r["text"] for r in replies[1:]] == ["2 samples", "1 samples"]
    assert len(backend.seen) == 2


def test_shutdown_is_acknowledged_and_ends_the_loop():
    replies, _ = drive(request("shutdown") + request("ping"))
    assert replies[-1] == {"ok": True, "op": "shutdown"}
    assert len(replies) == 2                    # the ping was never reached


def test_closed_stdin_ends_the_loop_cleanly():
    """The app quitting is normal, not an error."""
    replies, _ = drive(b"")
    assert len(replies) == 1                    # just the banner


# --- failures ----------------------------------------------------------------

def test_a_declared_length_that_lies_is_a_protocol_error():
    """Claim 100 samples, send 2. Reading on would consume the next request."""
    replies, _ = drive(request("transcribe", encode_samples([0.1, 0.2]),
                               samples=100))
    assert replies[1]["ok"] is False
    assert replies[1]["kind"] == "protocol"


def test_a_backend_failure_does_not_kill_the_process():
    """One bad utterance must not cost the user their loaded model."""
    body = (request("transcribe", encode_samples([0.1]), samples=1)
            + request("ping"))
    replies, _ = drive(body, backend=FakeBackend(raises=RuntimeError("boom")))
    assert replies[1]["ok"] is False
    assert replies[1]["kind"] == "backend"
    assert "boom" in replies[1]["error"]
    assert replies[2] == {"ok": True, "op": "ping"}      # still serving


def test_an_unavailable_backend_is_reported_as_such():
    replies, _ = drive(request("transcribe", encode_samples([0.1]), samples=1),
                       backend=FakeBackend(raises=ASRUnavailable("no metal")))
    assert replies[1]["kind"] == "unavailable"


def test_malformed_json_does_not_end_the_session():
    replies, _ = drive(b"not json\n" + request("ping"))
    assert replies[1]["kind"] == "protocol"
    assert replies[2] == {"ok": True, "op": "ping"}


def test_an_unknown_op_is_refused():
    replies, _ = drive(request("dance"))
    assert replies[1]["ok"] is False


def test_a_negative_sample_count_is_refused():
    replies, _ = drive(request("transcribe", b"", samples=-1))
    assert replies[1]["kind"] == "protocol"
