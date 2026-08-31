"""The evaluation harness. M3, and the gate every training layer must pass.

Two invariants live here:

  2. Holdout data is never trained on.
  9. No training layer ships before its eval gate exists.

F16 is why the holdout is rolling rather than fixed: if the gate is a static
set, training eventually overfits to it and the gate stops meaning anything.
F14 is why promotion is gated at all -- a bad run that silently degrades the
daily driver is the failure that kills trust fastest.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from typing import Callable, Iterable, Optional, Protocol, Sequence

from .metrics import entity_error_rate, wer
from .store import CORRECTION, CorrectionStore

#: Fraction of eligible utterances permanently reserved from training.
HOLDOUT_FRACTION = 0.15

#: A candidate may not be worse than the incumbent by more than this on the
#: primary metric. Zero would reject on noise; too loose and F14 walks through.
REGRESSION_TOLERANCE = 0.02


class Transcriber(Protocol):
    """Whatever produces text from a stored utterance under some adapter set.

    The harness never loads a model itself. That keeps the gate testable
    without Apple Silicon, and keeps M3 genuinely ahead of M4/M5 rather than
    entangled with them.
    """

    def transcribe(self, utterance_id: str, hypothesis: str) -> str: ...


@dataclass(frozen=True)
class EvalResult:
    n: int
    corrections_per_100_words: float     # primary, gates promotion (F17)
    entity_error_rate: float             # secondary
    word_error_rate: float               # reported, never gating (F17)
    entities_evaluated: int = 0

    def better_than(self, other: "EvalResult",
                    tolerance: float = REGRESSION_TOLERANCE) -> bool:
        """Lower is better on the primary metric."""
        return self.corrections_per_100_words <= (
            other.corrections_per_100_words + tolerance
        )

    def as_dict(self) -> dict:
        return {
            "n": self.n,
            "corrections_per_100_words": round(self.corrections_per_100_words, 4),
            "entity_error_rate": round(self.entity_error_rate, 4),
            "word_error_rate": round(self.word_error_rate, 4),
            "entities_evaluated": self.entities_evaluated,
        }


class HoldoutManager:
    """Rolling holdout reservation and rotation (F16).

    Membership is derived from a hash of the utterance id and a rotation salt,
    not from a random draw, so it is reproducible: the same store and the same
    salt always reserve the same items, and `dictate doctor` can state which
    rotation an eval score came from.
    """

    def __init__(self, store: CorrectionStore, *,
                 fraction: float = HOLDOUT_FRACTION, salt: str = "r0"):
        if not 0.0 < fraction < 1.0:
            raise ValueError(f"holdout fraction must be in (0,1), got {fraction}")
        self.store, self.fraction, self.salt = store, fraction, salt

    def _selected(self, utterance_id: str) -> bool:
        digest = hashlib.sha256(f"{self.salt}:{utterance_id}".encode()).digest()
        return int.from_bytes(digest[:4], "big") / 0xFFFFFFFF < self.fraction

    def reserve(self) -> list[str]:
        """Mark the current rotation's share as holdout. Returns ids reserved.

        Reservation is permanent per SPEC §4: an id already reserved stays
        reserved even when the salt rotates, so nothing that has ever been used
        to measure can later be trained on.
        """
        reserved = []
        for row in self.store.all():
            if row["holdout"]:
                continue
            if self._selected(row["id"]):
                self.store.mark_holdout(row["id"])
                reserved.append(row["id"])
        return reserved

    def rotate(self, new_salt: str) -> list[str]:
        """Advance the rotation and reserve the new share on top of the old."""
        self.salt = new_salt
        return self.reserve()


def evaluate(store: CorrectionStore, transcriber: Transcriber,
             entities: Iterable[str] = ()) -> EvalResult:
    """Score a transcriber over the holdout only.

    The reference is what the user actually meant: their correction where they
    made one, the ASR's output where they accepted it (F4 -- a weak positive,
    used here as the best available reference, not as gold).
    """
    rows = store.holdout_set()
    entities = list(entities)
    if not rows:
        return EvalResult(0, 0.0, 0.0, 0.0)

    words = corrected = missed = ent_total = 0
    wer_weighted = 0.0
    for row in rows:
        reference = row["final_text"] if row["final_text"] is not None else row["hypothesis"]
        produced = transcriber.transcribe(row["id"], row["hypothesis"])
        n_words = max(len(reference.split()), 1)
        words += n_words
        if produced.strip() != reference.strip():
            corrected += 1
        wer_weighted += wer(reference, produced) * n_words
        m, t = entity_error_rate(reference, produced, entities)
        missed += m
        ent_total += t

    return EvalResult(
        n=len(rows),
        corrections_per_100_words=100.0 * corrected / words,
        entity_error_rate=(missed / ent_total) if ent_total else 0.0,
        word_error_rate=wer_weighted / words,
        entities_evaluated=ent_total,
    )


@dataclass
class GateDecision:
    promoted: bool
    reason: str
    candidate: EvalResult
    baseline: Optional[EvalResult] = None

    def __str__(self) -> str:
        verdict = "PROMOTE" if self.promoted else "REJECT"
        return f"{verdict}: {self.reason}"


def gate(candidate: EvalResult, baseline: Optional[EvalResult],
         *, tolerance: float = REGRESSION_TOLERANCE,
         min_holdout: int = 5) -> GateDecision:
    """Decide whether a candidate adapter may be promoted (F14).

    Refusing to promote on an under-powered holdout is deliberate: a gate that
    passes because it measured four utterances is not a gate.
    """
    if candidate.n < min_holdout:
        return GateDecision(
            False,
            f"holdout has {candidate.n} item(s), need at least {min_holdout} "
            f"to decide; not promoting on insufficient evidence",
            candidate, baseline,
        )
    if baseline is None:
        return GateDecision(True, "no incumbent to regress against", candidate, baseline)
    if candidate.better_than(baseline, tolerance):
        return GateDecision(
            True,
            f"corrections/100w {candidate.corrections_per_100_words:.3f} "
            f"vs incumbent {baseline.corrections_per_100_words:.3f} "
            f"(tolerance {tolerance})",
            candidate, baseline,
        )
    return GateDecision(
        False,
        f"regression: corrections/100w {candidate.corrections_per_100_words:.3f} "
        f"vs incumbent {baseline.corrections_per_100_words:.3f} "
        f"exceeds tolerance {tolerance}",
        candidate, baseline,
    )
