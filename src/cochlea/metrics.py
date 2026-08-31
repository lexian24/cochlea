"""Evaluation metrics.

F17 is the governing decision: users do not experience WER, they experience how
often they have to fix something, and a wrong proper noun costs far more than a
wrong article. So the metric that gates promotion is corrections per 100 words,
entity error rate is the secondary, and WER is computed and reported but never
allowed to decide anything.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from difflib import SequenceMatcher
from typing import Iterable, Sequence

_WORD = re.compile(r"[\w'-]+")


def tokenize(text: str) -> list[str]:
    return _WORD.findall(text.lower())


@dataclass(frozen=True)
class ErrorCounts:
    substitutions: int = 0
    deletions: int = 0
    insertions: int = 0
    reference_length: int = 0

    @property
    def errors(self) -> int:
        return self.substitutions + self.deletions + self.insertions

    @property
    def rate(self) -> float:
        if self.reference_length == 0:
            return 0.0 if self.errors == 0 else 1.0
        return self.errors / self.reference_length

    def __add__(self, other: "ErrorCounts") -> "ErrorCounts":
        return ErrorCounts(
            self.substitutions + other.substitutions,
            self.deletions + other.deletions,
            self.insertions + other.insertions,
            self.reference_length + other.reference_length,
        )


def align(reference: Sequence[str], hypothesis: Sequence[str]) -> ErrorCounts:
    """Word-level alignment counts between a reference and a hypothesis."""
    sub = dele = ins = 0
    for tag, i1, i2, j1, j2 in SequenceMatcher(None, reference, hypothesis).get_opcodes():
        if tag == "replace":
            ref_len, hyp_len = i2 - i1, j2 - j1
            sub += min(ref_len, hyp_len)
            dele += max(0, ref_len - hyp_len)
            ins += max(0, hyp_len - ref_len)
        elif tag == "delete":
            dele += i2 - i1
        elif tag == "insert":
            ins += j2 - j1
    return ErrorCounts(sub, dele, ins, len(reference))


def wer(reference: str, hypothesis: str) -> float:
    """Word error rate. Reported, never gating (F17)."""
    return align(tokenize(reference), tokenize(hypothesis)).rate


def entity_error_rate(
    reference: str, hypothesis: str, entities: Iterable[str]
) -> tuple[int, int]:
    """(missed, total) for the entities that appear in the reference.

    The secondary metric. A proper noun or project term the user actually said
    but did not get back is the error class that costs them the most, and it is
    invisible in an aggregate WER dominated by articles.
    """
    hyp = set(tokenize(hypothesis))
    ref = tokenize(reference)
    missed = total = 0
    for entity in {e.lower() for e in entities}:
        parts = tokenize(entity)
        if not parts or not _contains(ref, parts):
            continue                      # not said in this utterance
        total += 1
        if not all(p in hyp for p in parts):
            missed += 1
    return missed, total


def _contains(haystack: Sequence[str], needle: Sequence[str]) -> bool:
    n = len(needle)
    return any(list(haystack[i:i + n]) == list(needle)
               for i in range(len(haystack) - n + 1))
