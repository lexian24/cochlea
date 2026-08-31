"""The common-word baseline that term extraction measures against.

Term extraction is only as good as its notion of "ordinary word". With no
baseline, every token is out-of-vocabulary and the lexicon fills with "are",
"open" and "mode" — which is worse than useless, because each junk entry is
another chance for F2 to over-trigger.

The bundled list is ~1000 high-frequency English words: enough to separate
project vocabulary from prose, and small enough to read. A production build
should replace ``load()`` with a real frequency-ranked dictionary (CMUdict,
wordfreq, or the platform lexicon); the interface is a set of lowercase words,
so swapping the source changes nothing downstream.
"""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path

_DATA = Path(__file__).parent / "data"


@lru_cache(maxsize=None)
def load(language: str = "en") -> frozenset[str]:
    path = _DATA / f"common_{language}.txt"
    if not path.exists():
        return frozenset()
    return frozenset(
        line.strip().lower() for line in path.read_text().splitlines() if line.strip()
    )


def is_common(word: str, language: str = "en") -> bool:
    return word.lower() in load(language)
