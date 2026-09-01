"""Turning lexicon entries into per-token score adjustments during decoding.

This is the mechanism D8 measured and D1 calls the layer that pays off first.
It is deliberately separate from :mod:`cochlea.asr`: nothing here imports MLX,
because invariant 4 confines that to the ASR module and because the
interesting part — deciding which token gets boosted at which decode step —
is what needs testing, and it needs testing on a machine that cannot run MLX
at all.

The unit is a **token sequence**, not a word. A phrase only pays off across
several decode steps: to make the decoder prefer "pull request" the boost has
to arrive on "request" *after* "pull" has been generated, and never on
"request" on its own. Sequence-prefix matching is what makes that the same
mechanism as boosting a single word rather than a second one bolted alongside.

F2 governs everything here. The cap is applied per token, and the reason is in
D8: an earlier version summed the boosts of every entry sharing a prefix,
reached +69 logits, and the decoder ran away — a 68-character transcript
became 1169 characters and inference went from 298 ms to 11 seconds. That is
not a slow filter, it is a broken one. Taking a maximum is what makes the
worst case bounded rather than proportional to how many entries happen to
overlap.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable, Iterable, Mapping, Sequence

from .lexicon import MAX_BOOST, Lexicon

#: The largest adjustment any single token may receive, in logits.
#:
#: D8 measured the working point at 6: boost 3 recovered "kubectl" but not
#: "nginx", boost 6 recovered both, and no false positives appeared up to 20 —
#: on a handful of synthesised samples, which is evidence for a working point
#: and not evidence that F2 is solved. The cap sits above the working point and
#: well below where over-triggering was looked for, so it bounds the damage a
#: mis-set entry can do without being the thing that limits a correct one.
MAX_LOGIT_BOOST = 8.0

#: Converts a lexicon strength into logits.
#:
#: Chosen so the lexicon's default strength of 1.5 lands exactly on D8's
#: measured working point of 6.0. A strength of 1.0 means "not boosted" on the
#: lexicon's scale and must map to zero, or every admitted term would bias
#: whether it had earned it or not.
LOGITS_PER_STRENGTH = 12.0


def logit_boost(strength: float) -> float:
    """Lexicon strength (1.0 = neutral, capped at ``MAX_BOOST``) → logits."""
    if strength <= 1.0:
        return 0.0
    return min(MAX_LOGIT_BOOST, (min(strength, MAX_BOOST) - 1.0) * LOGITS_PER_STRENGTH)


@dataclass(frozen=True)
class BiasedSequence:
    """One tokenisation of one lexicon entry, with its boost in logits."""

    term: str
    tokens: tuple[int, ...]
    boost: float


class BiasIndex:
    """Answers "which tokens get boosted next, and by how much?".

    Built once per utterance and queried once per decode step, so the query has
    to be cheap: a linear scan over entries would be O(entries x length) every
    step, which is the shape of cost that made a large lexicon unaffordable.
    Keying on the matched prefix makes it O(longest sequence) dictionary
    lookups instead, independent of how many entries there are.
    """

    def __init__(self, sequences: Iterable[BiasedSequence]):
        self._by_prefix: dict[tuple[int, ...], dict[int, float]] = {}
        self._terms: dict[int, set[str]] = {}
        self.max_length = 0
        for sequence in sequences:
            if not sequence.tokens or sequence.boost <= 0:
                continue
            self.max_length = max(self.max_length, len(sequence.tokens))
            for index, token in enumerate(sequence.tokens):
                prefix = sequence.tokens[:index]
                bucket = self._by_prefix.setdefault(prefix, {})
                # F2, and the whole of D8's runaway decode: the maximum, never
                # the sum. Overlapping entries must not compound.
                bucket[token] = max(bucket.get(token, 0.0), sequence.boost)
                self._terms.setdefault(token, set()).add(sequence.term)

    def __bool__(self) -> bool:
        return bool(self._by_prefix)

    @property
    def size(self) -> int:
        """How many distinct prefixes are indexed, for diagnostics."""
        return len(self._by_prefix)

    def boosts_for(self, generated: Sequence[int]) -> Mapping[int, float]:
        """Boosts to apply at this decode step, given the tokens so far.

        Every suffix of ``generated`` up to the longest indexed sequence is a
        candidate prefix, including the empty one — which is what lets a phrase
        start at all. Whisper's special tokens (start-of-transcript, language,
        timestamps) are in ``generated`` too and simply match nothing, so they
        need no filtering: a sequence that cannot continue contributes nothing
        rather than contributing wrongly.
        """
        boosts: dict[int, float] = {}
        for length in range(0, min(self.max_length, len(generated)) + 1):
            prefix = tuple(generated[len(generated) - length:]) if length else ()
            for token, boost in self._by_prefix.get(prefix, {}).items():
                if boost > boosts.get(token, 0.0):
                    boosts[token] = boost
        return boosts

    def terms_for(self, token: int) -> set[str]:
        """Which entries could have put a boost on this token.

        Used to credit a hit, which is the negative-signal half of F2: an entry
        that never wins should decay, and one cannot tell it from an entry that
        wins constantly without recording which ones did.
        """
        return self._terms.get(token, set())


def build_index(
    lexicon: Lexicon,
    encode: Callable[[str], Sequence[int]],
    *,
    now: float | None = None,
) -> BiasIndex:
    """Tokenise every live lexicon entry into a queryable index.

    ``encode`` is injected rather than imported: the tokenizer lives inside
    ``mlx_whisper``, and taking it as an argument is what keeps this module
    importable — and testable — on a machine with no MLX.

    Each term is indexed **twice**, with and without a leading space. Whisper's
    BPE treats " kubectl" and "kubectl" as different tokens entirely, and which
    one the decoder is reaching for depends on whether the word starts a
    sentence. Indexing one of them biases a word in the middle of a sentence
    but not at the start of one, which reads as the feature working
    intermittently.
    """
    sequences: list[BiasedSequence] = []
    for term, entry in lexicon.entries.items():
        if entry.expired(now):
            continue
        boost = logit_boost(entry.boost)
        if boost <= 0:
            continue
        for surface in (term, " " + term):
            tokens = tuple(encode(surface))
            if tokens:
                sequences.append(BiasedSequence(term=term, tokens=tokens, boost=boost))
    return BiasIndex(sequences)


def credit_hits(lexicon: Lexicon, text: str) -> list[str]:
    """Record which biased terms actually made it into the transcript.

    Without this the lexicon has no negative signal at all: F2's decay and
    expiry both key off use, and an entry that is boosted every utterance and
    never wins looks exactly like one that has not been tried yet.
    """
    lowered = text.lower()
    hit = [term for term in lexicon.entries if term.lower() in lowered]
    for term in hit:
        lexicon.record_hit(term)
    return hit
