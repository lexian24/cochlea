"""On-device ASR — the M0 transcription backend.

SPEC §4 puts inference and training on MLX so that one weight format serves
both, which is what M5's acoustic LoRA needs. That argument survives contact
with the ecosystem, but not in the shape the spec assumed: there is no Whisper
implementation for Swift MLX, and ``mlx-tune`` — the trainer §4 names — is
Python. The Swift side was never going to train. So inference lives here, in
Python, next to the trainer and next to the lexicon, and the macOS app talks to
it over the protocol in :mod:`cochlea.sidecar`. See docs/DECISIONS.md D5.

The decisive reason is M2 rather than M5. Contextual biasing adjusts token
scores inside the decode loop, and the lexicon those scores come from is
:mod:`cochlea.lexicon`. Any arrangement that puts a language boundary between
the decode loop and the lexicon pays it once per token.

Importing this module never requires MLX. Invariant 4 is that text-only mode is
fully functional, and the import graph is where that is easiest to break.
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

SAMPLE_RATE = 16_000

# What ModelResolver.isNeeded downloads and D4 pins, which is also exactly what
# mlx_whisper.load_model reads. The two lists agreeing is not a coincidence to
# rely on silently: verify_model_directory below fails loudly if it stops
# holding, rather than letting mlx_whisper raise a bare FileNotFoundError.
REQUIRED_FILES = ("config.json",)
WEIGHT_FILES = ("weights.safetensors", "weights.npz")


@dataclass(frozen=True)
class Transcription:
    """Mirrors the Swift ``TranscriptionResult``."""

    text: str
    language: str | None
    inference_ms: int


class ASRUnavailable(RuntimeError):
    """Raised when no backend can run, with the reason a user can act on."""


class ASRBackend(Protocol):
    identifier: str

    def warm_up(self) -> None: ...

    def transcribe(self, samples, language: str | None = None) -> Transcription: ...


def verify_model_directory(path: Path) -> Path:
    """Check a downloaded model directory before handing it to the loader.

    The app downloads and checksum-verifies the weights itself (F21, D4) and
    passes the directory here, so this does not fetch anything. It exists to
    turn a missing file into a sentence that names the fix.
    """
    path = Path(path)
    if not path.is_dir():
        raise ASRUnavailable(
            f"no model directory at {path}. The app downloads the model on "
            f"first run; run `dictate doctor` to see what is installed."
        )
    missing = [f for f in REQUIRED_FILES if not (path / f).exists()]
    if missing:
        raise ASRUnavailable(f"{path} is missing {', '.join(missing)}")
    if not any((path / w).exists() for w in WEIGHT_FILES):
        raise ASRUnavailable(
            f"{path} holds no weights file (expected one of "
            f"{', '.join(WEIGHT_FILES)})"
        )
    return path


class MLXWhisperBackend:
    """Whisper on MLX, per D1 and D5.

    The model is loaded once and stays resident: F19 makes first-invocation
    latency a separate acceptance number from the warm median, and a process
    that reloads weights per utterance fails it every time. ``mlx_whisper``
    caches the loaded model internally (``ModelHolder``), so residency is a
    property of keeping this process alive.
    """

    def __init__(self, model_path: str | Path, *, identifier: str | None = None,
                 fp16: bool = True):
        self.model_path = str(verify_model_directory(Path(model_path)))
        self.identifier = identifier or Path(self.model_path).name
        # Half precision is not a tuning knob to leave at a safe-looking
        # default: measured on an M2, fp32 costs almost exactly 2x wall clock
        # (large-v3-turbo 2.06s -> 3.88s on a 12.8s utterance), against an M0
        # budget of one second. Transcripts were identical on the samples
        # benchmarked. See docs/DECISIONS.md D6.
        self.fp16 = fp16
        self._transcribe = None

    def _load(self):
        if self._transcribe is not None:
            return self._transcribe
        try:
            import mlx_whisper
        except ImportError as exc:                      # pragma: no cover
            raise ASRUnavailable(
                "mlx-whisper is not installed. It is an optional extra because "
                "it requires Apple Silicon: pip install 'cochlea[asr]'"
            ) from exc
        self._transcribe = mlx_whisper.transcribe
        return self._transcribe

    def warm_up(self) -> None:
        """Load the weights now so the first utterance does not pay for it.

        Decoding one frame of silence is what actually forces the load; simply
        importing does not. The cost is a fraction of a second against a
        multi-second model load.
        """
        import numpy as np

        transcribe = self._load()
        transcribe(np.zeros(SAMPLE_RATE // 10, dtype=np.float32),
                   path_or_hf_repo=self.model_path,
                   fp16=self.fp16)

    def transcribe(self, samples, language: str | None = None) -> Transcription:
        import numpy as np

        transcribe = self._load()
        audio = np.asarray(samples, dtype=np.float32)
        started = time.perf_counter()
        # A waveform, never a path. mlx_whisper.load_audio shells out to
        # ffmpeg for a file path, and ffmpeg is not a dependency this project
        # wants: it is a large install, it is absent from a stock macOS, and
        # the app already holds the samples in memory. Passing the array skips
        # load_audio entirely.
        result = transcribe(
            audio,
            path_or_hf_repo=self.model_path,
            language=language,
            fp16=self.fp16,
        )
        elapsed_ms = int((time.perf_counter() - started) * 1000)
        return Transcription(
            text=result.get("text", "").strip(),
            language=result.get("language"),
            inference_ms=elapsed_ms,
        )


def available() -> bool:
    """Whether an ASR backend could run here, without importing the heavy one.

    Deliberately does not import ``mlx_whisper``: that pulls in MLX and Metal,
    which costs seconds, and callers ask this question to decide whether to
    bother.
    """
    import importlib.util

    return importlib.util.find_spec("mlx_whisper") is not None


def describe() -> str:
    """One line for `dictate doctor`."""
    if not available():
        return "none (install the 'asr' extra; needs Apple Silicon)"
    try:
        from mlx_whisper import _version

        return f"mlx-whisper {_version.__version__}"
    except Exception:
        return "mlx-whisper (version unknown)"
