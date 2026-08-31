"""PII redaction for imported text (F8).

Applied at parse time, before anything reaches disk. The patterns are
deliberately blunt: F8 asks for "obvious PII patterns", and a redactor that
tries to be clever produces false negatives that are invisible until they are
already stored.
"""

from __future__ import annotations

import re

_PATTERNS: list[tuple[str, re.Pattern]] = [
    ("EMAIL", re.compile(r"\b[\w.+-]+@[\w-]+\.[\w.]+\b")),
    ("URL", re.compile(r"\bhttps?://\S+", re.I)),
    # 7+ consecutive digits, and digit runs broken by spaces/dashes: phone
    # numbers, card numbers, national IDs, account numbers.
    ("NUMBER", re.compile(r"\b(?:\d[\d\s-]{6,}\d)\b")),
    ("POSTAL", re.compile(
        r"\b\d{1,5}\s+[A-Z][a-z]+(?:\s+[A-Z][a-z]+)*\s+"
        r"(?:Street|St|Road|Rd|Avenue|Ave|Lane|Ln|Drive|Dr|Blvd)\b")),
]


#: Labels substituted in by :func:`redact`. Term extraction must skip these --
#: otherwise importing a corpus that contained any PII teaches the lexicon the
#: word "EMAIL".
PLACEHOLDERS = frozenset({"EMAIL", "URL", "NUMBER", "POSTAL"})


def redact(text: str) -> str:
    for label, pattern in _PATTERNS:
        text = pattern.sub(f"[{label}]", text)
    return text


def contains_pii(text: str) -> bool:
    return any(p.search(text) for _, p in _PATTERNS)
