"""M3 acceptance: the gate, the holdout, and automatic rollback."""

import pytest

from cochlea.adapters import (AdapterRegistry, config_hash,
                              promote_if_gate_passes)
from cochlea.evaluation import (HoldoutManager, EvalResult, evaluate, gate)
from cochlea.metrics import entity_error_rate, wer
from cochlea.store import CORRECTION, CorrectionStore, Utterance
from helpers import CorruptTranscriber, PerfectTranscriber, populate


# --- holdout ----------------------------------------------------------------

def test_holdout_reservation_is_reproducible():
    """F16: membership is derived, not drawn, so it is reproducible.

    Utterance ids are random per store, so this is determinism for a given
    store -- which is what lets `dictate doctor` state which rotation an eval
    score came from.
    """
    store = CorrectionStore()
    populate(store)
    ids = [r["id"] for r in store.all()]
    a = HoldoutManager(store, salt="r0")
    b = HoldoutManager(store, salt="r0")
    assert [a._selected(i) for i in ids] == [b._selected(i) for i in ids]
    assert any(a._selected(i) for i in ids)          # and it selects something


def test_a_different_salt_selects_a_different_share():
    store = CorrectionStore()
    populate(store, 200)
    ids = [r["id"] for r in store.all()]
    r0 = {i for i in ids if HoldoutManager(store, salt="r0")._selected(i)}
    r1 = {i for i in ids if HoldoutManager(store, salt="r1")._selected(i)}
    assert r0 != r1


def test_holdout_fraction_is_approximately_honoured():
    store = CorrectionStore()
    populate(store, 400)
    reserved = HoldoutManager(store, fraction=0.15, salt="r0").reserve()
    assert 0.10 < len(reserved) / 400 < 0.20


def test_rotation_reserves_more_without_releasing_the_old():
    """Reservation is permanent: nothing measured can later be trained on."""
    store = CorrectionStore()
    populate(store, 300)
    h = HoldoutManager(store, salt="r0")
    first = set(h.reserve())
    second = set(h.rotate("r1"))
    held = {r["id"] for r in store.holdout_set()}
    assert first and second
    assert first.isdisjoint(second)       # rotation adds new items
    assert first | second == held         # and keeps every earlier one


def test_invalid_fraction_rejected():
    with pytest.raises(ValueError):
        HoldoutManager(CorrectionStore(), fraction=0.0)


def test_holdout_is_never_in_the_training_set():
    """Invariant 2, proven over the whole store rather than a sample."""
    store = CorrectionStore()
    populate(store, 200)
    HoldoutManager(store, salt="r0").reserve()
    held = {r["id"] for r in store.holdout_set()}
    trainable = {r["id"] for r in store.training_set()}
    assert held and trainable
    assert held.isdisjoint(trainable)


def test_evaluation_only_ever_reads_holdout_items():
    """The other half of invariant 2: the gate must not peek at training data."""
    store = CorrectionStore()
    populate(store, 100)
    HoldoutManager(store, salt="r0").reserve()
    held = {r["id"] for r in store.holdout_set()}
    t = PerfectTranscriber(store)
    evaluate(store, t)
    assert set(t.seen) == held


# --- metrics ----------------------------------------------------------------

def test_perfect_transcriber_scores_zero_on_every_metric():
    store = CorrectionStore(); populate(store, 100)
    HoldoutManager(store, salt="r0").reserve()
    r = evaluate(store, PerfectTranscriber(store), entities=["kubectl"])
    assert r.corrections_per_100_words == 0.0
    assert r.word_error_rate == 0.0 and r.entity_error_rate == 0.0
    assert r.n > 0 and r.entities_evaluated > 0


def test_corrupt_transcriber_scores_badly():
    store = CorrectionStore(); populate(store, 100)
    HoldoutManager(store, salt="r0").reserve()
    r = evaluate(store, CorruptTranscriber(), entities=["kubectl"])
    assert r.corrections_per_100_words > 0
    assert r.entity_error_rate == 1.0      # every kubectl lost


def test_empty_holdout_yields_an_empty_result():
    assert evaluate(CorrectionStore(), PerfectTranscriber(CorrectionStore())).n == 0


# --- the gate ---------------------------------------------------------------

def good(n=50): return EvalResult(n, 1.0, 0.1, 0.2)
def bad(n=50):  return EvalResult(n, 9.0, 0.9, 0.8)


def test_gate_promotes_an_improvement():
    assert gate(good(), bad()).promoted


def test_gate_rejects_a_regression():
    d = gate(bad(), good())
    assert not d.promoted and "regression" in d.reason


def test_gate_promotes_when_there_is_no_incumbent():
    assert gate(good(), None).promoted


def test_gate_refuses_to_decide_on_a_tiny_holdout():
    """A gate that passes on four utterances is not a gate."""
    d = gate(good(n=3), bad())
    assert not d.promoted and "insufficient evidence" in d.reason


def test_gate_tolerates_noise_but_not_real_regression():
    base = EvalResult(50, 1.0, 0.1, 0.2)
    assert gate(EvalResult(50, 1.01, 0.1, 0.2), base).promoted        # within tolerance
    assert not gate(EvalResult(50, 1.5, 0.1, 0.2), base).promoted     # beyond it


def test_wer_is_reported_but_never_gates():
    """F17: a candidate with far worse WER still promotes on the primary metric."""
    base = EvalResult(50, 5.0, 0.5, 0.10)
    cand = EvalResult(50, 1.0, 0.5, 0.99)      # much better primary, much worse WER
    assert gate(cand, base).promoted
