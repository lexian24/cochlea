"""PhoneticBackend — ``distance(a, b) -> float``, registered per language.

SPEC §4 and P5: the phonetic-distance signal in F1 is language-pair specific.
Hardcoding it means surgery to support a new pair, so the backend is pluggable
and there is always a fallback for unsupported languages.

Distances are normalized to [0.0, 1.0]; 0.0 means "sounds identical".
"""

from __future__ import annotations

from typing import Callable, Dict, Protocol


class PhoneticBackend(Protocol):
    language: str

    def distance(self, a: str, b: str) -> float: ...


def _levenshtein(a: str, b: str) -> int:
    if a == b:
        return 0
    if not a:
        return len(b)
    if not b:
        return len(a)
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def _norm(a: str, b: str) -> float:
    longest = max(len(a), len(b))
    return 0.0 if longest == 0 else _levenshtein(a, b) / longest


class EditDistanceBackend:
    """Character-level fallback for languages with no registered backend (P5)."""

    language = "*"

    def distance(self, a: str, b: str) -> float:
        return _norm(a.lower(), b.lower())


# --- English -----------------------------------------------------------------

_VOWELS = set("AEIOU")


def metaphone(word: str) -> str:
    """A deliberately small Metaphone.

    This is a reduced implementation, not full Double Metaphone. It collapses
    the confusions that actually show up in dictation corrections — voiced/
    unvoiced pairs, silent leading letters, digraphs — and is enough to separate
    "sounds close" from "sounds nothing alike", which is all F1's signal needs.
    """
    w = "".join(ch for ch in word.upper() if ch.isalpha())
    if not w:
        return ""
    for pre, keep in (("KN", 1), ("GN", 1), ("PN", 1), ("AE", 1), ("WR", 1)):
        if w.startswith(pre):
            w = w[keep:]
            break
    if w.startswith("X"):
        w = "S" + w[1:]
    out: list[str] = []
    i, n = 0, len(w)
    while i < n:
        c = w[i]
        nxt = w[i + 1] if i + 1 < n else ""
        if out and c == out[-1] and c != "C":
            i += 1
            continue
        if c in _VOWELS:
            if i == 0:
                out.append(c)
        elif c == "B":
            if not (i == n - 1 and i > 0 and w[i - 1] == "M"):
                out.append("B")
        elif c == "C":
            if nxt == "H":
                out.append("X")
                i += 1
            elif nxt in "IEY":
                out.append("S")
            else:
                out.append("K")
        elif c == "D":
            if nxt == "G":
                out.append("J")
                i += 1
            else:
                out.append("T")
        elif c == "G":
            out.append("K" if nxt != "H" else "K")
        elif c == "H":
            if i > 0 and w[i - 1] in _VOWELS and nxt not in _VOWELS:
                pass
            else:
                out.append("H")
        elif c in "FJLMNR":
            out.append(c)
        elif c == "K":
            if not (i > 0 and w[i - 1] == "C"):
                out.append("K")
        elif c == "P":
            out.append("F" if nxt == "H" else "P")
            if nxt == "H":
                i += 1
        elif c == "Q":
            out.append("K")
        elif c == "S":
            out.append("X" if nxt == "H" else "S")
            if nxt == "H":
                i += 1
        elif c == "T":
            if nxt == "H":
                out.append("0")
                i += 1
            else:
                out.append("T")
        elif c == "V":
            out.append("F")
        elif c in "WY":
            if nxt in _VOWELS:
                out.append(c)
        elif c == "X":
            out.extend("KS")
        elif c == "Z":
            out.append("S")
        i += 1
    return "".join(out)


class MetaphoneBackend:
    language = "en"

    def distance(self, a: str, b: str) -> float:
        ka, kb = metaphone(a), metaphone(b)
        if not ka and not kb:
            return 0.0
        if not ka or not kb:
            return 1.0
        return _norm(ka, kb)


# --- Mandarin ----------------------------------------------------------------


class PinyinBackend:
    """Requires the ``zh`` extra (``pip install 'cochlea[zh]'``)."""

    language = "zh"

    def __init__(self) -> None:
        from pypinyin import Style, lazy_pinyin  # noqa: F401

        self._to_pinyin = lambda s: " ".join(
            lazy_pinyin(s, style=Style.NORMAL, errors=lambda x: list(x))
        )

    def distance(self, a: str, b: str) -> float:
        return _norm(self._to_pinyin(a), self._to_pinyin(b))


# --- registry ----------------------------------------------------------------

_FALLBACK = EditDistanceBackend()
_REGISTRY: Dict[str, PhoneticBackend] = {}


def register(backend: PhoneticBackend) -> None:
    _REGISTRY[backend.language] = backend


def get(language: str) -> PhoneticBackend:
    """Return the backend for ``language``, or the documented fallback (P5)."""
    return _REGISTRY.get(language, _FALLBACK)


def available() -> list[str]:
    return sorted(_REGISTRY)


def _bootstrap() -> None:
    register(MetaphoneBackend())
    try:
        register(PinyinBackend())
    except Exception:
        # pypinyin absent: zh falls back to character-level distance, which is
        # the contract in P5, not a failure.
        pass


_bootstrap()
