"""M4: replay buffer, resource gating, and rebuild from the store alone."""

import random
import pytest

from cochlea.adapters import AdapterRegistry
from cochlea.evaluation import EvalResult, HoldoutManager, evaluate, gate
from cochlea.store import (CORRECTION, UNEDITED, CorrectionStore, Utterance)
from cochlea.training import (CORRECTED_RATIO, WEAK_POSITIVE_WEIGHT, Example,
                              ResourceGuard, TrainingRun, build_replay_batch,
                              rebuild)

from tests.test_evaluation import CorruptTranscriber, PerfectTranscriber


class RecordingTrainer:
    layer = "postcorr"
    def __init__(self):
        self.batches = []
    def train(self, examples, base_model, config):
        self.batches.append(list(examples))
        return {"loss": 0.1}


def seed(store, corrections=40, accepted=40):
    for i in range(corrections):
        store.add(Utterance(hypothesis=f"cube cuddle {i} get pods",
                            final_text=f"kubectl {i} get pods",
                            base_model_id="m", attribution=CORRECTION))
    for i in range(accepted):
        store.add(Utterance(hypothesis=f"the build number {i} is green",
                            base_model_id="m", attribution=UNEDITED))
    return store


# --- replay buffer (F3, F4) -------------------------------------------------

def test_batch_is_never_corrections_only():
    """F3: the failure this whole mechanism exists to prevent."""
    store = seed(CorrectionStore())
    batch = build_replay_batch(store, size=40)
    assert batch
    assert any(not e.is_correction for e in batch)


def test_batch_honours_the_corrected_ratio():
    store = seed(CorrectionStore(), corrections=200, accepted=200)
    batch = build_replay_batch(store, size=100, corrected_ratio=0.5)
    corrected = sum(e.is_correction for e in batch)
    assert 0.4 <= corrected / len(batch) <= 0.6


def test_unedited_examples_carry_a_lower_weight():
    """F4: weak positives, not gold labels."""
    store = seed(CorrectionStore())
    batch = build_replay_batch(store, size=40)
    weak = [e for e in batch if not e.is_correction]
    assert weak and all(e.weight == WEAK_POSITIVE_WEIGHT for e in weak)
    assert all(e.weight == 1.0 for e in batch if e.is_correction)


def test_batch_shrinks_rather_than_tipping_to_corrections_only():
    """With few accepted utterances, keep the ratio and take fewer corrections."""
    store = seed(CorrectionStore(), corrections=200, accepted=4)
    batch = build_replay_batch(store, size=100, corrected_ratio=0.5)
    corrected = sum(e.is_correction for e in batch)
    assert len(batch) < 100
    assert corrected <= 6           # bounded by the 4 accepted, not by 200


def test_batch_excludes_holdout():
    """Invariant 2, at the point where training data is actually assembled."""
    store = seed(CorrectionStore())
    HoldoutManager(store, salt="r0").reserve()
    held = {r["id"] for r in store.holdout_set()}
    batch = build_replay_batch(store, size=200)
    assert held and not (held & {e.utterance_id for e in batch})


def test_generic_examples_are_mixed_in():
    store = seed(CorrectionStore())
    generic = [Example("g1", "hello there", "hello there", 0.2)]
    batch = build_replay_batch(store, size=20, generic=generic)
    assert "g1" in {e.utterance_id for e in batch}


def test_empty_store_yields_an_empty_batch():
    assert build_replay_batch(CorrectionStore(), size=10) == []


# --- resource guard (F20) ---------------------------------------------------

def test_guard_permits_on_ac_idle_with_headroom():
    assert ResourceGuard().may_train()


@pytest.mark.parametrize("kwargs,expected", [
    ({"on_ac_power": False}, "not on AC power"),
    ({"low_power_mode": True}, "low power mode"),
    ({"idle_seconds": 10}, "idle"),
    ({"available_memory_gb": 1.0}, "swap"),
])
def test_guard_blocks_and_says_why(kwargs, expected):
    guard = ResourceGuard(**kwargs)
    assert not guard.may_train()
    assert any(expected in b for b in guard.blockers())


def test_guard_reports_every_blocker_not_just_the_first():
    guard = ResourceGuard(on_ac_power=False, low_power_mode=True, idle_seconds=0)
    assert len(guard.blockers()) == 3


# --- gated training run -----------------------------------------------------

def _prepared():
    store = seed(CorrectionStore(), corrections=80, accepted=80)
    HoldoutManager(store, salt="r0").reserve()
    return store, AdapterRegistry(), RecordingTrainer()


def test_training_is_deferred_when_resources_say_no():
    """F20: training never competes with the user's work."""
    store, registry, trainer = _prepared()
    run = TrainingRun(store, registry, trainer,
                      guard=ResourceGuard(on_ac_power=False))
    ok, msg = run.run("m", {}, PerfectTranscriber(store))
    assert not ok and "deferred" in msg
    assert trainer.batches == []          # nothing was trained
    assert registry.current("postcorr") is None


def test_successful_run_promotes_through_the_gate():
    store, registry, trainer = _prepared()
    ok, msg = TrainingRun(store, registry, trainer).run(
        "m", {"lr": 1e-4}, PerfectTranscriber(store))
    assert ok and registry.current("postcorr") is not None
    assert trainer.batches, "trainer was never called"


def test_a_regressing_run_is_not_promoted():
    """F14 end to end: a bad run cannot become the daily driver."""
    store, registry, trainer = _prepared()
    good = TrainingRun(store, registry, trainer)
    assert good.run("m", {"v": 1}, PerfectTranscriber(store))[0]
    first = registry.current("postcorr").id

    bad = TrainingRun(store, registry, trainer)
    ok, msg = bad.run("m", {"v": 2}, CorruptTranscriber())
    assert not ok
    assert registry.current("postcorr").id == first


def test_run_refuses_when_there_is_nothing_to_train_on():
    store = CorrectionStore()
    ok, msg = TrainingRun(store, AdapterRegistry(), RecordingTrainer()).run(
        "m", {}, PerfectTranscriber(store))
    assert not ok and "nothing to train on" in msg


# --- rebuild (F13, invariant 5) ---------------------------------------------

def test_rebuild_regenerates_adapters_from_the_store_alone():
    """Invariant 5, and P6's journey after a base model upgrade."""
    store, registry, trainer = _prepared()
    results = rebuild(store, registry, [trainer], "whisper-large-v3", {"rank": 8},
                      PerfectTranscriber(store))
    assert results == [("postcorr", True, results[0][2])]
    current = registry.current("postcorr")
    assert current is not None
    assert current.base_model_id == "whisper-large-v3"   # rebuilt against the new base


def test_rebuild_is_repeatable():
    store, registry, trainer = _prepared()
    rebuild(store, registry, [trainer], "m2", {}, PerfectTranscriber(store))
    v1 = registry.current("postcorr").version
    rebuild(store, registry, [trainer], "m2", {}, PerfectTranscriber(store))
    assert registry.current("postcorr").version > v1
