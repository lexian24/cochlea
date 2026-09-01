"""M3 acceptance: versioning, retention, and automatic rollback (F14, F15)."""

import pytest

from cochlea.adapters import (RETAIN, AdapterRegistry, config_hash,
                              promote_if_gate_passes)
from cochlea.evaluation import EvalResult, HoldoutManager, evaluate, gate
from cochlea.store import CORRECTION, CorrectionStore, Utterance

from helpers import CorruptTranscriber, PerfectTranscriber, populate


def good(n=50): return EvalResult(n, 1.0, 0.1, 0.2)
def bad(n=50):  return EvalResult(n, 9.0, 0.9, 0.8)


def test_versions_increment_per_layer():
    r = AdapterRegistry()
    a = r.register("postcorr", "whisper-turbo", {"lr": 1e-4})
    b = r.register("postcorr", "whisper-turbo", {"lr": 2e-4})
    c = r.register("acoustic", "whisper-turbo", {"lr": 1e-4})
    assert (a.version, b.version, c.version) == (1, 2, 1)


def test_config_hash_is_stable_and_order_independent():
    assert config_hash({"a": 1, "b": 2}) == config_hash({"b": 2, "a": 1})
    assert config_hash({"a": 1}) != config_hash({"a": 2})


def test_unknown_layer_rejected():
    with pytest.raises(ValueError, match="unknown layer"):
        AdapterRegistry().register("nonsense", "m", {})


def test_promotion_requires_a_passing_gate():
    """Invariant 1, enforced in the registry rather than by the caller."""
    r = AdapterRegistry()
    a = r.register("postcorr", "m", {}, bad())
    decision = gate(bad(), good())
    assert not decision.promoted
    with pytest.raises(PermissionError, match="Invariant 1"):
        r.promote(a.id, decision)
    assert r.current("postcorr") is None


def test_promotion_replaces_the_incumbent():
    r = AdapterRegistry()
    a = r.register("postcorr", "m", {"v": 1}, good())
    r.promote(a.id, gate(good(), None))
    b = r.register("postcorr", "m", {"v": 2}, good())
    r.promote(b.id, gate(good(), good()))
    assert r.current("postcorr").id == b.id
    assert not r.get(a.id).promoted


def test_rollback_restores_the_previous_version():
    r = AdapterRegistry()
    a = r.register("postcorr", "m", {"v": 1}, good())
    r.promote(a.id, gate(good(), None))
    b = r.register("postcorr", "m", {"v": 2}, good())
    r.promote(b.id, gate(good(), good()))
    assert r.rollback("postcorr").id == a.id
    assert r.current("postcorr").id == a.id


def test_rollback_to_an_explicit_version():
    r = AdapterRegistry()
    for i in range(3):
        a = r.register("postcorr", "m", {"v": i}, good())
        r.promote(a.id, gate(good(), None))
    assert r.rollback("postcorr", to_version=1).version == 1


def test_rollback_to_a_missing_version_is_an_error():
    r = AdapterRegistry()
    r.promote(r.register("postcorr", "m", {}, good()).id, gate(good(), None))
    with pytest.raises(KeyError):
        r.rollback("postcorr", to_version=99)


def test_retention_keeps_the_last_n_and_never_drops_the_promoted_one():
    r = AdapterRegistry(retain=3)
    first = r.register("postcorr", "m", {"v": 0}, good())
    r.promote(first.id, gate(good(), None))
    for i in range(1, 8):
        r.register("postcorr", "m", {"v": i}, good())
    r.promote(r.register("postcorr", "m", {"v": 99}, good()).id, gate(good(), good()))
    history = r.history("postcorr")
    assert len(history) <= 3 + 1
    assert r.current("postcorr") is not None


# --- the acceptance criterion, stated verbatim in SPEC M3 -------------------

def test_corrupted_adapter_is_caught_by_the_gate_and_rolled_back_automatically():
    """"A deliberately corrupted adapter is caught by the gate and rolled back
    automatically without user intervention." No manual step appears below.
    """
    store = CorrectionStore()
    populate(store, 120)
    HoldoutManager(store, salt="r0").reserve()
    registry = AdapterRegistry()

    # A good adapter is trained, scores well, and is promoted.
    baseline = evaluate(store, PerfectTranscriber(store), entities=["kubectl"])
    v1 = registry.register("postcorr", "whisper-turbo", {"run": 1}, baseline)
    promoted, msg = promote_if_gate_passes(registry, v1.id, gate(baseline, None))
    assert promoted and registry.current("postcorr").id == v1.id

    # The next run is corrupted. It is evaluated on the same holdout.
    candidate = evaluate(store, CorruptTranscriber(), entities=["kubectl"])
    v2 = registry.register("postcorr", "whisper-turbo", {"run": 2}, candidate)
    promoted, msg = promote_if_gate_passes(
        registry, v2.id, gate(candidate, baseline))

    # It is refused, and the daily driver is still the good one.
    assert not promoted
    assert "regression" in msg
    assert registry.current("postcorr").id == v1.id
    assert not registry.get(v2.id).promoted


def test_doctor_fields_are_sufficient_to_triage_a_regression():
    """F15: adapter version, base model, config hash and eval score, all present.

    The holdout is marked explicitly rather than drawn by `HoldoutManager`.
    Selection is a hash over random utterance ids, so reserving from 80 items
    at 15% put the holdout below `gate`'s `min_holdout` of 5 about once in 211
    runs -- the gate then correctly refused, nothing was promoted, `current`
    returned None, and this test failed on an AttributeError that looked
    nothing like its cause. What is under test here is which fields survive
    promotion, so the holdout is a fixture and should not be a dice roll.
    """
    store = CorrectionStore(); populate(store, 80)
    for row in store.all()[:20]:
        store.mark_holdout(row["id"])
    r = AdapterRegistry()
    result = evaluate(store, PerfectTranscriber(store))
    a = r.register("postcorr", "whisper-turbo", {"lr": 1e-4, "rank": 8}, result)
    r.promote(a.id, gate(result, None))
    cur = r.current("postcorr")
    assert cur.version == 1
    assert cur.base_model_id == "whisper-turbo"
    assert len(cur.config_hash) == 16
    assert cur.eval is not None and cur.eval.n > 0
    assert cur.eval.as_dict()["word_error_rate"] is not None
