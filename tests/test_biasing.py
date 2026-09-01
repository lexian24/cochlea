"""The half of contextual biasing that can be tested without MLX.

Which is deliberately the interesting half. D8 measured that the mechanism
works; what these cover is that the right token gets boosted at the right
decode step, and that the failure D8 hit -- accumulating boosts until the
decoder ran away -- cannot come back.
"""

import pytest

from cochlea.biasing import (MAX_LOGIT_BOOST, BiasedSequence, BiasIndex,
                             build_index, credit_hits, logit_boost)
from cochlea.lexicon import Lexicon


class FakeTokenizer:
    """Whitespace-and-character tokenisation with stable ids.

    Enough to exercise sequence prefixes, and it makes the assertions readable:
    a real BPE vocabulary would put the interesting behaviour behind opaque
    integers.
    """

    def __init__(self):
        self._ids: dict[str, int] = {}

    def encode(self, text: str) -> list[int]:
        pieces = [p for p in text.replace(" ", " ▁").split(" ") if p]
        return [self._ids.setdefault(p, len(self._ids) + 100) for p in pieces]


def test_neutral_strength_does_not_bias():
    # 1.0 is "admitted but not boosted" on the lexicon's scale. If it mapped to
    # anything positive, every entry would bias whether it had earned it.
    assert logit_boost(1.0) == 0.0
    assert logit_boost(0.5) == 0.0


def test_the_default_strength_lands_on_the_measured_working_point():
    # D8: boost 3 recovered "kubectl" but not "nginx"; boost 6 recovered both.
    # The lexicon's default add strength is 1.5, so that is where it has to map
    # or the measurement describes a configuration nothing reaches.
    assert logit_boost(1.5) == pytest.approx(6.0)


def test_the_cap_holds_however_high_the_strength_goes():
    assert logit_boost(3.0) == MAX_LOGIT_BOOST
    assert logit_boost(1000.0) == MAX_LOGIT_BOOST


def test_a_sequence_initial_token_is_boosted_with_nothing_generated():
    index = BiasIndex([BiasedSequence(term="kubectl", tokens=(1, 2), boost=6.0)])
    assert index.boosts_for([]) == {1: 6.0}


def test_the_rest_of_a_phrase_is_boosted_only_after_its_prefix():
    # The whole point of sequences over words: "request" must be boosted after
    # "pull" and not on its own, or the phrase entry degrades into two word
    # entries and biases text that has nothing to do with it.
    #
    # The first token of a sequence is boosted at every step, not only the
    # first: the phrase can begin anywhere in the utterance, so the empty
    # prefix always matches. That is why these assert on membership rather
    # than on the whole mapping.
    index = BiasIndex([BiasedSequence(term="pull request", tokens=(1, 2, 3), boost=6.0)])
    assert index.boosts_for([]) == {1: 6.0}
    assert index.boosts_for([1])[2] == 6.0
    assert index.boosts_for([1, 2])[3] == 6.0
    # A prefix that does not match does not open the rest of the phrase.
    assert 2 not in index.boosts_for([9])
    assert 3 not in index.boosts_for([1, 9])


def test_a_prefix_is_matched_at_the_end_of_a_longer_history():
    # Real decoding arrives with a start-of-transcript token, a language token
    # and prior text in front of the prefix. Matching has to look at the tail.
    index = BiasIndex([BiasedSequence(term="pull request", tokens=(1, 2), boost=6.0)])
    assert index.boosts_for([50258, 50259, 700, 701, 1])[2] == 6.0
    assert 2 not in index.boosts_for([50258, 50259, 700, 701])


def test_whisper_special_tokens_match_nothing_rather_than_matching_wrongly():
    index = BiasIndex([BiasedSequence(term="nginx", tokens=(1,), boost=6.0)])
    # Only the sequence-initial boost, from the empty prefix.
    assert index.boosts_for([50363, 50364]) == {1: 6.0}


def test_overlapping_entries_take_the_maximum_and_never_the_sum():
    # This is D8's runaway decode. Twenty-five entries sharing a prefix summed
    # to +69 logits; the decoder emitted "termnumbertermnumber term..." until it
    # hit the token limit, turning a 68-character transcript into 1169 and
    # inference from 298 ms into 11 seconds.
    shared = [BiasedSequence(term=f"term{i}", tokens=(1, 10 + i), boost=6.0)
              for i in range(25)]
    index = BiasIndex(shared)
    boosts = index.boosts_for([])
    assert boosts == {1: 6.0}, "25 entries sharing a first token must not compound"
    assert max(boosts.values()) <= MAX_LOGIT_BOOST


def test_the_strongest_entry_wins_a_shared_token():
    index = BiasIndex([
        BiasedSequence(term="weak", tokens=(1,), boost=2.0),
        BiasedSequence(term="strong", tokens=(1,), boost=7.0),
    ])
    assert index.boosts_for([]) == {1: 7.0}


def test_an_empty_index_is_falsy_and_boosts_nothing():
    index = BiasIndex([])
    assert not index
    assert index.boosts_for([1, 2, 3]) == {}


def test_zero_boost_sequences_are_dropped_at_construction():
    # Cheaper than checking per decode step, and it keeps `max_length` from
    # being inflated by entries that can never contribute.
    index = BiasIndex([BiasedSequence(term="x", tokens=(1,), boost=0.0)])
    assert not index


def test_building_from_a_lexicon_indexes_both_surface_forms():
    # Whisper's BPE treats " kubectl" and "kubectl" as different tokens, so a
    # term indexed one way biases mid-sentence but not at the start of one --
    # which reads as the feature working intermittently.
    lexicon = Lexicon()
    lexicon.add("kubectl")
    tokenizer = FakeTokenizer()
    index = build_index(lexicon, tokenizer.encode)
    bare = tokenizer.encode("kubectl")
    spaced = tokenizer.encode(" kubectl")
    assert bare != spaced
    boosts = index.boosts_for([])
    assert bare[0] in boosts and spaced[0] in boosts


def test_expired_entries_are_not_indexed():
    # F2's expiry has to reach the decoder, not just the store.
    lexicon = Lexicon()
    lexicon.add("kubectl")
    tokenizer = FakeTokenizer()
    far_future = lexicon.entries["kubectl"].last_used_at + 60 * 60 * 24 * 365
    assert not build_index(lexicon, tokenizer.encode, now=far_future)


def test_a_decayed_entry_stops_reaching_the_decoder():
    # record_rejection halves the strength; below 1.05 the entry is deleted
    # outright. Either way it must stop biasing.
    lexicon = Lexicon()
    lexicon.add("kubectl", boost=1.05)
    lexicon.record_rejection("kubectl")
    assert not build_index(lexicon, FakeTokenizer().encode)


def test_credit_hits_records_only_terms_that_appeared():
    # F2's decay keys off use. Without this an entry that is boosted every
    # utterance and never wins looks exactly like one never tried.
    lexicon = Lexicon()
    lexicon.add("kubectl")
    lexicon.add("nginx")
    hits = credit_hits(lexicon, "Deploy with kubectl and check the logs")
    assert hits == ["kubectl"]
    assert lexicon.entries["kubectl"].hits == 1
    assert lexicon.entries["nginx"].hits == 0


def test_credit_hits_is_case_insensitive():
    lexicon = Lexicon()
    lexicon.add("kubectl")
    assert credit_hits(lexicon, "Kubectl apply -f") == ["kubectl"]


def test_terms_for_attributes_a_boosted_token_back_to_its_entries():
    index = BiasIndex([
        BiasedSequence(term="kubectl", tokens=(1, 2), boost=6.0),
        BiasedSequence(term="kubelet", tokens=(1, 3), boost=6.0),
    ])
    assert index.terms_for(1) == {"kubectl", "kubelet"}
    assert index.terms_for(2) == {"kubectl"}
