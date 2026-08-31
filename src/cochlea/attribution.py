"""The attribution filter — F1, "revision mistaken for correction".

Three signals, per SPEC §2.1:

  latency   corrections happen fast
  phonetic  corrections are phonetically close to what was said
  locality  corrections are short substitutions; revisions are rewrites

The brief specifies one threshold: "quarantine anything that fails two of
three". It does not say what failing all three means, so this module reads a
total failure as a confident REVISION and a partial failure (exactly two) as
genuinely ambiguous, which is what the review queue exists to adjudicate.

Latency is only evidence on the fix-last path. An item cleared from the review
queue is slow *by construction* — the user clears the queue when idle (SPEC
§1.1) — so counting its latency as a failed signal would systematically
misattribute the entire secondary path. There, only two signals apply.
"""

from __future__ import annotations

from dataclasses import dataclass
from difflib import SequenceMatcher
from typing import Optional

from . import phonetics
from .store import CORRECTION, QUARANTINED, REVISION, UNEDITED


@dataclass(frozen=True)
class Thresholds:
    max_latency_ms: int = 15_000
    max_phonetic_distance: float = 0.34
    max_edit_fraction: float = 0.34


@dataclass
class Verdict:
    attribution: str
    phonetic_distance: Optional[float]
    signals: dict           # name -> True (pass) / False (fail)
    reason: str

    @property
    def failed(self) -> list[str]:
        return [k for k, ok in self.signals.items() if not ok]


def changed_spans(hypothesis: str, final_text: str) -> tuple[str, str]:
    """The substituted words only, as (before, after).

    Comparing whole utterances would let a one-word fix inside a long sentence
    look phonetically near-identical no matter what replaced it.
    """
    a, b = hypothesis.split(), final_text.split()
    before, after = [], []
    for tag, i1, i2, j1, j2 in SequenceMatcher(None, a, b).get_opcodes():
        if tag == "replace":
            before.extend(a[i1:i2])
            after.extend(b[j1:j2])
    return " ".join(before), " ".join(after)


def edit_fraction(hypothesis: str, final_text: str) -> float:
    """Fraction of words touched. 0.0 = identical, 1.0 = total rewrite."""
    a, b = hypothesis.split(), final_text.split()
    if not a and not b:
        return 0.0
    touched = sum(
        max(i2 - i1, j2 - j1)
        for tag, i1, i2, j1, j2 in SequenceMatcher(None, a, b).get_opcodes()
        if tag != "equal"
    )
    return touched / max(len(a), len(b), 1)


def classify(
    hypothesis: str,
    final_text: Optional[str],
    *,
    correction_source: str = "fix_last",
    latency_ms: Optional[int] = None,
    language: str = "en",
    thresholds: Thresholds = Thresholds(),
) -> Verdict:
    if final_text is None or final_text == hypothesis:
        return Verdict(UNEDITED, None, {}, "no edit was made")

    backend = phonetics.get(language)
    before, after = changed_spans(hypothesis, final_text)
    # A pure insertion or deletion substitutes nothing, so there is no acoustic
    # claim to check; that is revision-shaped, and the signal fails.
    dist = backend.distance(before, after) if before and after else 1.0
    frac = edit_fraction(hypothesis, final_text)

    signals: dict[str, bool] = {}
    if correction_source == "fix_last" and latency_ms is not None:
        signals["latency"] = latency_ms <= thresholds.max_latency_ms
    signals["phonetic"] = dist <= thresholds.max_phonetic_distance
    signals["locality"] = frac <= thresholds.max_edit_fraction

    fails = [k for k, ok in signals.items() if not ok]
    if not fails:
        verdict, why = CORRECTION, "all signals pass"
    elif len(fails) == 1:
        verdict, why = CORRECTION, f"one signal failed ({fails[0]}); below quarantine threshold"
    elif len(fails) == len(signals) and len(signals) >= 3:
        verdict, why = REVISION, "every signal failed; treated as a rewrite, not an ASR error"
    else:
        verdict, why = QUARANTINED, f"{len(fails)} signals failed ({', '.join(fails)}); needs adjudication"

    return Verdict(verdict, round(dist, 4), signals, why)
