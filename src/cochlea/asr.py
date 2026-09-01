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

import contextlib
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

# `cochlea.biasing` is imported lazily, inside the two functions that use it.
# It reaches `cochlea.lexicon` and from there `cochlea.phonetics`, which pulls
# pypinyin at import: 72 ms of the 107 ms it costs to import this module, or
# two thirds of it, paid by the sidecar at startup for something no unbiased
# decode touches. F19 makes that a number worth not spending.

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
    #: Lexicon entries that were boosted and appeared in the result.
    #:
    #: F2's decay and expiry key off use, and an entry boosted every utterance
    #: that never wins is indistinguishable from one never tried unless the
    #: decode says which ones landed. Empty when no lexicon was supplied.
    biased_terms: tuple[str, ...] = ()


class ASRUnavailable(RuntimeError):
    """Raised when no backend can run, with the reason a user can act on."""


class ASRBackend(Protocol):
    identifier: str

    def warm_up(self) -> None: ...

    def transcribe(self, samples, language: str | None = None,
                   lexicon=None) -> Transcription: ...


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

    def transcribe(self, samples, language: str | None = None,
                   lexicon=None) -> Transcription:
        import numpy as np

        transcribe = self._load()
        audio = np.asarray(samples, dtype=np.float32)
        started = time.perf_counter()
        # A waveform, never a path. mlx_whisper.load_audio shells out to
        # ffmpeg for a file path, and ffmpeg is not a dependency this project
        # wants: it is a large install, it is absent from a stock macOS, and
        # the app already holds the samples in memory. Passing the array skips
        # load_audio entirely.
        with biased_decoding(lexicon):
            result = transcribe(
                audio,
                path_or_hf_repo=self.model_path,
                language=language,
                fp16=self.fp16,
            )
        elapsed_ms = int((time.perf_counter() - started) * 1000)
        text = result.get("text", "").strip()
        if lexicon is None:
            hits: tuple[str, ...] = ()
        else:
            from .biasing import credit_hits

            hits = tuple(credit_hits(lexicon, text))
        return Transcription(
            text=text,
            language=result.get("language"),
            inference_ms=elapsed_ms,
            biased_terms=hits,
        )


# -- contextual biasing (M2, D8) ----------------------------------------------
#
# The one piece of coupling to mlx-whisper's internals this design accepts.
# ``DecodingTask.__init__`` builds ``self.logit_filters`` as a plain list with
# no public injection point, so appending to it means wrapping that
# initialiser. The alternative -- ``initial_prompt`` -- is not a biasing hook:
# it conditions the context and competes for the 224-token prompt budget, and
# it does not adjust token scores at all. See D8.

#: The lexicon in force for the current ``transcribe`` call, or ``None``.
#:
#: A module-level slot rather than a parameter because the filter is
#: constructed deep inside mlx-whisper, several frames below anything cochlea
#: calls. The sidecar is single-threaded and holds the model for the life of
#: the process (D5), so there is exactly one decode in flight at a time.
_active_lexicon = None

#: Bumped whenever the active lexicon changes, so a cached index built for a
#: previous one is never reused. Comparing lexicon contents would be more
#: precise and more expensive than rebuilding.
_lexicon_generation = 0

#: ``id(tokenizer) -> (generation, BiasIndex)``. One decode makes a new
#: ``DecodingTask`` per 30-second window and again per temperature fallback,
#: so tokenising 400 entries in the initialiser would repeat several times per
#: utterance.
_index_cache: dict = {}


class _LexiconBiasFilter:
    """Adds each entry's boost to its next token, at every decode step.

    Implements mlx-whisper's ``LogitFilter`` structurally: the list it joins is
    duck-typed, so subclassing would mean importing the class at module scope
    and dragging MLX in with it.
    """

    def __init__(self, index):
        self.index = index

    def apply(self, logits, tokens):
        import mlx.core as mx
        import numpy as np

        rows = np.asarray(tokens)
        if rows.ndim == 1:
            rows = rows[None, :]
        delta = np.zeros(logits.shape, dtype=np.float32)
        vocabulary = delta.shape[-1]
        for row in range(rows.shape[0]):
            # Per row, because best-of sampling decodes several candidate
            # sequences at once and they have different histories -- so they
            # are at different points in a phrase and must not share a boost.
            for token, boost in self.index.boosts_for(rows[row].tolist()).items():
                if token < vocabulary:
                    delta[row, token] = boost
        return logits + mx.array(delta)


def _install_bias_filter() -> None:
    """Wrap ``DecodingTask.__init__`` so every decode carries the filter.

    Idempotent, and safe to call when no lexicon is active: the filter is built
    from whatever index the active lexicon produces, and no active lexicon
    means no filter is appended at all. Patching once and gating per call is
    what keeps an unbiased decode paying nothing.
    """
    from mlx_whisper import decoding

    if getattr(decoding.DecodingTask, "_cochlea_biasing", False):
        return
    original = decoding.DecodingTask.__init__

    def __init__(self, model, options):
        original(self, model, options)
        index = _index_for(self.tokenizer)
        if index:
            self.logit_filters.append(_LexiconBiasFilter(index))

    decoding.DecodingTask.__init__ = __init__
    decoding.DecodingTask._cochlea_biasing = True


def _index_for(tokenizer):
    """The bias index for the active lexicon, tokenised by this tokenizer.

    Built here rather than in ``transcribe`` because this is the first place
    the tokenizer actually being used is in scope -- constructing a matching
    one from outside means reproducing mlx-whisper's choice of multilingual
    flag, language and task, and getting any of them wrong yields token ids
    that silently boost the wrong words.
    """
    if _active_lexicon is None:
        return None
    from .biasing import build_index

    key = id(tokenizer)
    cached = _index_cache.get(key)
    if cached is not None and cached[0] == _lexicon_generation:
        return cached[1]
    index = build_index(_active_lexicon, tokenizer.encode)
    _index_cache[key] = (_lexicon_generation, index)
    return index


@contextlib.contextmanager
def biased_decoding(lexicon):
    """Bias one decode towards ``lexicon``, or nothing if it is ``None``."""
    global _active_lexicon, _lexicon_generation

    if lexicon is None or not lexicon.entries:
        yield
        return
    _install_bias_filter()
    previous, _active_lexicon = _active_lexicon, lexicon
    _lexicon_generation += 1
    try:
        yield
    finally:
        _active_lexicon = previous
        _lexicon_generation += 1


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
        # Names the package, not just the extra. "install the 'asr' extra" does
        # not tell someone what is missing or why it might not install, and
        # this line is the first place a formula-only install looks.
        return "none -- mlx-whisper not installed (pip install 'cochlea[asr]'; " \
               "Apple Silicon only)"
    try:
        from mlx_whisper import _version

        return f"mlx-whisper {_version.__version__}"
    except Exception:
        return "mlx-whisper (version unknown)"
