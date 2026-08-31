"""Lexicon and contextual biasing — the instant adaptation layer.

F2 is the governing failure mode: once a term is boosted, it starts winning
against genuine words that sound like it. Everything here exists to bound that:
a hard cap on boost magnitude, decay on negative signal, and expiry of entries
that stop earning their place.

F5 is enforced at admission: a term that is phonetically identical to a common
word cannot be fixed by biasing, and boosting it actively hurts. Those entries
are rejected rather than added and left to decay.
"""

from __future__ import annotations

import math
import re
import time
from dataclasses import dataclass, field
from typing import Iterable

from . import phonetics
from . import vocabulary as _vocabulary
from .privacy import PLACEHOLDERS

MAX_BOOST = 3.0          # F2: hard cap, never exceeded
DECAY_ON_REJECT = 0.5    # multiplicative, applied when a boosted token is deleted
EXPIRY_SECONDS = 60 * 60 * 24 * 7 * 6   # F2: unused for six weeks -> expired

_WORD = re.compile(r"[A-Za-z][A-Za-z0-9_.-]*")

# F5 admission check.
#
# Homophony must NOT be derived from the metaphone key. Metaphone drops
# non-initial vowels, so "knew" and "no" both reduce to "N" and a
# distance==0 test rejects "knew" as a homophone of "no" — a confident false
# rejection of a term the user legitimately wants. Deciding homophony needs
# real pronunciations, so this is an explicit curated table; a production
# build should back it with CMUdict (or the platform lexicon) and drop the
# hand-maintained list.
_HOMOPHONE_GROUPS: list[set[str]] = [
    {"there", "their", "they're"},
    {"to", "too", "two"},
    {"hear", "here"},
    {"write", "right", "rite"},
    {"no", "know"},
    {"for", "four", "fore"},
    {"buy", "by", "bye"},
    {"sea", "see"},
    {"one", "won"},
    {"would", "wood"},
    {"new", "knew"},
    {"week", "weak"},
    {"red", "read"},
]

# Frequent words used as the out-of-vocabulary baseline for term extraction.
_COMMON = {w for group in _HOMOPHONE_GROUPS for w in group} | {
    "the", "and", "with", "that", "this", "from", "have", "will", "your",
}


def _homophones_of(word: str) -> set[str]:
    low = word.lower()
    out: set[str] = set()
    for group in _HOMOPHONE_GROUPS:
        if low in group:
            out |= group - {low}
    return out


class HomophoneRejected(ValueError):
    """Raised when an entry would collide with a common word (F5)."""


@dataclass
class Entry:
    term: str
    boost: float = 1.0
    added_at: float = field(default_factory=time.time)
    last_used_at: float = field(default_factory=time.time)
    hits: int = 0
    rejections: int = 0

    def expired(self, now: float | None = None) -> bool:
        return ((now or time.time()) - self.last_used_at) > EXPIRY_SECONDS


class Lexicon:
    def __init__(self, language: str = "en"):
        self.language = language
        self.entries: dict[str, Entry] = {}
        self._canonical: dict[str, str] = {}

    # -- admission -------------------------------------------------------
    def add(self, term: str, boost: float = 1.5) -> Entry:
        if collisions := _homophones_of(term):
            raise HomophoneRejected(
                f"{term!r} is a homophone of {sorted(collisions)}; "
                "biasing cannot separate homophones and would create errors "
                "(SPEC F5). Route this to the post-correction LM instead."
            )
        entry = self.entries.get(term)
        if entry is None:
            entry = self.entries[term] = Entry(term=term)
        entry.boost = min(boost, MAX_BOOST)     # F2: cap
        entry.last_used_at = time.time()
        return entry

    def remove(self, term: str) -> None:
        self.entries.pop(term, None)

    # -- feedback --------------------------------------------------------
    def record_hit(self, term: str) -> None:
        if e := self.entries.get(term):
            e.hits += 1
            e.last_used_at = time.time()

    def record_rejection(self, term: str) -> None:
        """The user deleted a boosted token: decay it (F2, negative signal)."""
        if e := self.entries.get(term):
            e.rejections += 1
            e.boost *= DECAY_ON_REJECT
            if e.boost < 1.05:      # no longer meaningfully boosting
                del self.entries[term]

    def expire(self, now: float | None = None) -> list[str]:
        dead = [t for t, e in self.entries.items() if e.expired(now)]
        for t in dead:
            del self.entries[t]
        return dead

    # -- orthography (F6) ------------------------------------------------
    def canonicalize(self, variant: str, canonical: str) -> None:
        self._canonical[variant] = canonical

    def apply_canonical(self, text: str) -> str:
        return _WORD.sub(
            lambda m: self._canonical.get(m.group(0), m.group(0)), text
        )

    def boost_for(self, term: str) -> float:
        e = self.entries.get(term)
        return e.boost if e and not e.expired() else 1.0


# -- term extraction -----------------------------------------------------------


def looks_technical(token: str) -> bool:
    """Identifier-shaped: digits, dots, dashes, underscores, or internal caps.

    Catches kubectl-style tools only via the vocabulary check, but reliably
    catches large-v3, mlx-tune, chat.db, is_from_me, NSURLIsExcluded.
    """
    if any(c.isdigit() or c in "._-" for c in token):
        return True
    return token[1:] != token[1:].lower()      # internal capital


def extract_terms(
    samples: Iterable[str],
    *,
    vocabulary: set[str] | None = None,
    min_count: int = 2,
    language: str = "en",
) -> list[tuple[str, int]]:
    """Out-of-vocabulary tokens, capitalized non-dictionary words, identifiers.

    A token earns a place if it is not an ordinary word AND it is either
    identifier-shaped, capitalized where a common word would not be, or simply
    absent from the baseline vocabulary. Returns (term, count) by count desc.
    """
    vocab = (
        {w.lower() for w in vocabulary}
        if vocabulary is not None
        else set(_vocabulary.load(language))
    )
    counts: dict[str, int] = {}
    for text in samples:
        for tok in _WORD.findall(text):
            if len(tok) < 3 or tok.lower() in vocab or tok in PLACEHOLDERS:
                continue
            counts[tok] = counts.get(tok, 0) + 1
    return sorted(
        ((t, c) for t, c in counts.items() if c >= min_count),
        key=lambda kv: (-kv[1], kv[0]),
    )


def detect_variants(
    samples: Iterable[str],
    language: str = "en",
    min_count: int = 2,
) -> list[tuple[str, str, int, int]]:
    """Two spellings of the same token, used interchangeably (F6).

    Orthographic, not phonetic. An earlier version keyed this on metaphone
    distance and reported "now"/"no", "s"/"so" and "f4"/"f19" as variants of
    each other: metaphone drops non-initial vowels, so unrelated short tokens
    collide. Variants are instead near-identical *spellings* of a token that is
    not an ordinary word -- if both spellings are common English words they are
    two different words, not one word spelled two ways.

    Returns (variant_a, variant_b, count_a, count_b), most frequent first.
    """
    counts: dict[str, int] = {}
    for text in samples:
        for tok in _WORD.findall(text):
            counts[tok.lower()] = counts.get(tok.lower(), 0) + 1
    common = _vocabulary.load(language)
    frequent = sorted(t for t, c in counts.items() if c >= min_count)
    out: list[tuple[str, str, int, int]] = []
    for i, a in enumerate(frequent):
        for b in frequent[i + 1:]:
            if a in common and b in common:
                continue                      # two real words, not one variant
            if len(a) < 2 or len(b) < 2:
                continue
            short, long_ = sorted((a, b), key=len)
            if abs(len(a) - len(b)) > 2:
                continue
            if long_ == short + "s":
                continue                      # plural, not a spelling variant
            dist = phonetics._levenshtein(a, b)
            # Either the shorter spelling extends into the longer one
            # (la/lah, ok/okay) or they differ by a single character
            # (colour/color). Anything looser matches unrelated words.
            if not (long_.startswith(short) or dist == 1):
                continue
            out.append((a, b, counts[a], counts[b]))
    return sorted(out, key=lambda r: -(r[2] + r[3]))
