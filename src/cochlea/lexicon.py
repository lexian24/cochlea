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

import json
import math
import os
import re
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

from . import phonetics
from .attribution import changed_spans
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


    # -- persistence -----------------------------------------------------
    #
    # JSON rather than a table in adapters.db. The lexicon is small, it is
    # rewritten whole every time, and it is the one piece of adaptation state a
    # user might reasonably want to read, edit or delete by hand -- which is
    # the difference between a privacy claim someone can check and one they
    # have to take on faith.

    def to_dict(self) -> dict:
        return {
            "version": 1,
            "language": self.language,
            "entries": [
                {
                    "term": e.term,
                    "boost": e.boost,
                    "added_at": e.added_at,
                    "last_used_at": e.last_used_at,
                    "hits": e.hits,
                    "rejections": e.rejections,
                }
                for e in self.entries.values()
            ],
            "canonical": dict(self._canonical),
        }

    @classmethod
    def from_dict(cls, data: dict) -> "Lexicon":
        lexicon = cls(language=data.get("language", "en"))
        for row in data.get("entries", []):
            term = row.get("term")
            if not term:
                continue
            # Constructed directly rather than through `add`, which would reset
            # the timestamps and re-run the F5 admission check. Admission is a
            # decision already taken; re-taking it on load would silently drop
            # entries if the homophone table ever grew, and the user would have
            # no way to tell that from the file not having been written.
            lexicon.entries[term] = Entry(
                term=term,
                boost=min(float(row.get("boost", 1.0)), MAX_BOOST),
                added_at=float(row.get("added_at", time.time())),
                last_used_at=float(row.get("last_used_at", time.time())),
                hits=int(row.get("hits", 0)),
                rejections=int(row.get("rejections", 0)),
            )
        lexicon._canonical.update(data.get("canonical", {}))
        return lexicon

    def save(self, path: str | Path) -> Path:
        """Write the lexicon, readable only by its owner.

        Written to a temporary file and renamed, because a lexicon truncated by
        a crash mid-write is worse than no lexicon: it loads without error and
        biases towards a fragment of what the user meant.
        """
        target = Path(path)
        target.parent.mkdir(parents=True, exist_ok=True)
        temporary = target.with_suffix(target.suffix + ".tmp")
        temporary.write_text(json.dumps(self.to_dict(), indent=2, ensure_ascii=False))
        # These are terms lifted from the user's own messages. 0600 before the
        # rename, so there is no window in which they are world-readable.
        os.chmod(temporary, 0o600)
        temporary.replace(target)
        return target

    @classmethod
    def load(cls, path: str | Path, *, language: str = "en") -> "Lexicon":
        """Read a lexicon, or return an empty one if there is nothing to read.

        A missing file is the normal state before the first import, and a
        corrupt one must not stop dictation: biasing is an improvement to ASR,
        never a prerequisite for it. Both return an empty lexicon, which
        degrades to exactly the unbiased behaviour.
        """
        try:
            data = json.loads(Path(path).read_text())
        except (OSError, ValueError):
            return cls(language=language)
        if not isinstance(data, dict):
            return cls(language=language)
        return cls.from_dict(data)


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
            if len(tok) < 3 or _is_ordinary(tok, vocab) or tok in PLACEHOLDERS:
                continue
            counts[tok] = counts.get(tok, 0) + 1
    return sorted(
        ((t, c) for t, c in counts.items() if c >= min_count),
        key=lambda kv: (-kv[1], kv[0]),
    )


#: Inflections to strip before asking whether a word is ordinary.
#:
#: A baseline word list holds lemmas, so "logs", "running" and "started" all
#: miss it and every one of them was admitted to the lexicon as project
#: vocabulary. Each junk entry is another chance for F2 to over-trigger, and
#: an entry for "logs" is worse than useless: Whisper already knows the word,
#: so the boost can only ever push it over something the user actually said.
_SUFFIXES = ("s", "es", "ed", "ing", "ly", "er", "est", "'s")


def _is_ordinary(token: str, vocab: set[str]) -> bool:
    """Whether a word is common enough that biasing it can only do harm."""
    word = token.lower()
    if word in vocab:
        return True
    for suffix in _SUFFIXES:
        if not word.endswith(suffix) or len(word) - len(suffix) < 3:
            continue
        stem = word[: -len(suffix)]
        # "running" -> "runn" -> "run", "carries" -> "carri" -> "carry".
        for candidate in (stem, stem[:-1], stem + "e", stem[:-1] + "y"):
            if candidate in vocab:
                return True
    return False


def terms_from_correction(
    hypothesis: str,
    final_text: str,
    *,
    vocabulary: set[str] | None = None,
    language: str = "en",
    max_terms: int = 3,
) -> list[str]:
    """What a correction says the recogniser does not know.

    This is the M1 -> M2 link, and without it a correction does nothing a user
    can feel: it lands in the store, waits for a trainer that does not exist
    yet, and the very next utterance mishears the same word again. Biasing
    needs no training, so the word the user just typed by hand can be in force
    on the next sentence.

    Only the *replacement* words are candidates, and only the ones that survive
    the same filter an import uses. A correction is evidence that the
    recogniser got a word wrong; it is not evidence that the word is unusual.
    Fixing "there" to "their" says nothing biasing can act on -- F5 rejects it
    outright -- and fixing "fell" to "failed" is a word Whisper knows perfectly
    well, which it mis-heard for acoustic reasons a lexicon entry cannot fix
    and could make worse.

    Returns at most ``max_terms``, longest first: a correction that rewrote
    half a sentence is a revision by another name, and admitting every word of
    it is how a lexicon fills with noise (F25).
    """
    vocab = (
        {w.lower() for w in vocabulary}
        if vocabulary is not None
        else set(_vocabulary.load(language))
    )
    _, after = changed_spans(hypothesis, final_text)
    candidates: list[str] = []
    for token in _WORD.findall(after):
        token = token.rstrip("._-")
        if len(token) < 3 or token in PLACEHOLDERS:
            continue
        if _is_ordinary(token, vocab) and not looks_technical(token):
            continue
        if _homophones_of(token):          # F5: biasing cannot separate these
            continue
        if token not in candidates:
            candidates.append(token)
    candidates.sort(key=lambda t: (-len(t), t))
    return candidates[:max_terms]


def extract_phrases(
    samples: Iterable[str],
    *,
    vocabulary: set[str] | None = None,
    min_count: int = 3,
    max_words: int = 4,
    language: str = "en",
) -> list[tuple[str, int]]:
    """Word sequences the user repeats, which single terms cannot express.

    Biasing a phrase is not the same as biasing its words. "pull request" as
    two entries boosts "request" in every sentence the user speaks, including
    the ones about a request that has nothing to do with a pull; as one entry
    it boosts "request" only after "pull" has been generated, which is both
    more effective and less damaging under F2. A sequence is therefore the
    natural unit and a single word is the one-element case of it.

    What counts as a phrase here is deliberately narrow, because F2 punishes
    a large lexicon of weak entries far more than it punishes a small one of
    strong entries:

    - It must recur. A phrase said once is a sentence, not a habit.
    - It must not be entirely ordinary words. "in the same" recurs constantly
      in anyone's writing and boosting it biases the decoder towards nothing
      in particular, at the cost of every word it competes with.
    - It must not start or end on a stopword. "the eval gate" and "eval gate
      before" are artefacts of where the window fell; "eval gate" is the
      phrase, and admitting all three spends three entries to say one thing.

    Returns ``(phrase, count)``, most frequent first. Counts are of the exact
    sequence, so a longer phrase never outranks the shorter one it contains.
    """
    vocab = (
        {w.lower() for w in vocabulary}
        if vocabulary is not None
        else set(_vocabulary.load(language))
    )
    counts: dict[str, int] = {}
    for text in samples:
        for clause in _CLAUSE_BREAK.split(text):
            tokens = [t.rstrip("._-") for t in _WORD.findall(clause or "")]
            tokens = [t for t in tokens if t]
            for size in range(2, max_words + 1):
                for start in range(len(tokens) - size + 1):
                    window = tokens[start:start + size]
                    if not _is_phrase(window, vocab):
                        continue
                    phrase = " ".join(window)
                    counts[phrase] = counts.get(phrase, 0) + 1
    admitted = _drop_subsumed({p: c for p, c in counts.items() if c >= min_count})
    return sorted(admitted.items(), key=lambda kv: (-kv[1], kv[0]))


def _drop_subsumed(counts: dict[str, int]) -> dict[str, int]:
    """Remove a phrase that a shorter one already accounts for.

    If "nginx logs" and "check the nginx logs" occur the same number of times,
    every occurrence of the second is an occurrence of the first, so the
    longer one carries no evidence the shorter does not -- it costs an entry
    and, under F2, a share of the damage a lexicon can do, to say the same
    thing. A longer phrase survives only when it is genuinely rarer than its
    parts, which is what a real compound term looks like.
    """
    by_words = {phrase: phrase.split() for phrase in counts}
    keep: dict[str, int] = {}
    for phrase, count in counts.items():
        words = by_words[phrase]
        subsumed = any(
            other is not phrase
            and len(by_words[other]) < len(words)
            and counts[other] == count
            and _contains(words, by_words[other])
            for other in counts
        )
        if not subsumed:
            keep[phrase] = count
    return keep


def _contains(words: list[str], part: list[str]) -> bool:
    """Whether ``part`` appears as a contiguous run inside ``words``."""
    return any(words[i:i + len(part)] == part
               for i in range(len(words) - len(part) + 1))


def _is_phrase(window: list[str], vocab: set[str]) -> bool:
    """Whether a window of words is worth an entry of its own."""
    if any(w in PLACEHOLDERS for w in window):
        return False
    # A one-character word is an artefact, not part of a phrase. ``_WORD``
    # requires a leading letter, so a flag like "-f" arrives as a bare "f" and
    # produced "apply f" and "f now" as candidates.
    if any(len(w) < 2 for w in window):
        return False
    if window[0].lower() in _STOPWORDS or window[-1].lower() in _STOPWORDS:
        return False
    # At least one word the decoder is likely to get wrong. A phrase made
    # entirely of ordinary words is a turn of speech, not a term.
    return any(
        not _is_ordinary(w, vocab) or looks_technical(w)
        for w in window
    )


#: Where one phrase cannot continue into the next.
#:
#: A full stop only breaks a clause when whitespace or the end of the text
#: follows it. ``_WORD`` deliberately admits a dot inside a token so that
#: ``chat.db`` and ``large-v3`` survive term extraction, which means a naive
#: split on "." would take those apart -- and a naive split on whitespace
#: would glue "logs." to the sentence after it, producing "logs. Deploy" as a
#: phrase. Neither is something anyone says, and neither could ever match at
#: decode time.
_CLAUSE_BREAK = re.compile(r"[.!?]+(?=\s|$)|[,;:()\[\]{}\n\"]+|\s[-\u2013\u2014]\s")

#: Words that cannot begin or end a phrase.
#:
#: Not a general stopword list -- filtering these out of the *middle* would
#: break the phrases worth having ("out of memory", "state of the art"). They
#: are excluded only at the edges, where they mark a window that fell in the
#: wrong place rather than a phrase.
_STOPWORDS = {
    "a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "from",
    "had", "has", "have", "he", "her", "his", "i", "if", "in", "is", "it",
    "its", "me", "my", "not", "of", "on", "or", "our", "she", "so", "that",
    "the", "their", "them", "then", "there", "these", "they", "this", "to",
    "too", "up", "was", "we", "were", "what", "when", "which", "who", "will",
    "with", "would", "you", "your",
}


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
