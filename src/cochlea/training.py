"""Training orchestration — M4.

This module owns *when and on what* a layer trains, not how. The trainer
itself is a protocol: the actual LoRA fit needs MLX on Apple Silicon, and
keeping it behind a seam is what lets the replay buffer, the resource gate and
the rebuild path be tested anywhere.

F3 is the failure this exists to prevent: training only on corrected utterances
teaches the model its correct outputs were wrong.
"""

from __future__ import annotations

import random
from dataclasses import dataclass, field
from typing import Iterable, Optional, Protocol, Sequence

from .adapters import AdapterRegistry, promote_if_gate_passes
from .evaluation import EvalResult, GateDecision, Transcriber, evaluate, gate
from .store import CORRECTION, UNEDITED, CorrectionStore

#: F3: every batch mixes corrected and accepted-as-correct utterances.
#: Corrected examples are the signal; accepted ones are what stops the model
#: concluding that everything it used to get right was wrong.
CORRECTED_RATIO = 0.5

#: F4: un-edited utterances are weak positives, not gold labels. They enter
#: training at a reduced weight.
WEAK_POSITIVE_WEIGHT = 0.3


@dataclass(frozen=True)
class Example:
    utterance_id: str
    source_text: str        # what ASR produced
    target_text: str        # what the user meant
    weight: float

    @property
    def is_correction(self) -> bool:
        return self.source_text != self.target_text


class Trainer(Protocol):
    """Fits one layer. One implementation per layer (SPEC §4)."""

    layer: str

    def train(self, examples: Sequence[Example], base_model: str,
              config: dict) -> dict: ...


class ResourceGuard:
    """F20: training must not compete with the user's work.

    Every condition is injected rather than probed, so the policy is testable
    without a battery. A real build wires these to IOKit power sources, the
    idle timer, and vm_stat.
    """

    def __init__(self, *, on_ac_power: bool = True, idle_seconds: float = 3600,
                 low_power_mode: bool = False, available_memory_gb: float = 16.0,
                 required_memory_gb: float = 4.0, min_idle_seconds: float = 300):
        self.on_ac_power = on_ac_power
        self.idle_seconds = idle_seconds
        self.low_power_mode = low_power_mode
        self.available_memory_gb = available_memory_gb
        self.required_memory_gb = required_memory_gb
        self.min_idle_seconds = min_idle_seconds

    def blockers(self) -> list[str]:
        reasons = []
        if not self.on_ac_power:
            reasons.append("not on AC power")
        if self.low_power_mode:
            reasons.append("low power mode is on")
        if self.idle_seconds < self.min_idle_seconds:
            reasons.append(
                f"machine idle for {self.idle_seconds:.0f}s, "
                f"need {self.min_idle_seconds:.0f}s")
        if self.available_memory_gb < self.required_memory_gb:
            reasons.append(
                f"{self.available_memory_gb:.1f}GB free, "
                f"need {self.required_memory_gb:.1f}GB; training would swap")
        return reasons

    def may_train(self) -> bool:
        return not self.blockers()


def build_replay_batch(store: CorrectionStore, *, size: int = 64,
                       corrected_ratio: float = CORRECTED_RATIO,
                       generic: Sequence[Example] = (),
                       rng: Optional[random.Random] = None) -> list[Example]:
    """Assemble one training batch (F3, F4).

    Never returns a corrections-only batch. If there are not enough accepted
    utterances to hit the ratio, the batch shrinks rather than tipping into
    corrections-only — a smaller correct batch beats a larger poisoned one.
    """
    rng = rng or random.Random(0)
    rows = store.training_set()          # excludes holdout (invariant 2)
    corrected, accepted = [], []
    for row in rows:
        target = row["final_text"] if row["final_text"] is not None else row["hypothesis"]
        if row["attribution"] == CORRECTION and row["final_text"] is not None:
            corrected.append(Example(row["id"], row["hypothesis"], target, 1.0))
        elif row["attribution"] == UNEDITED:
            accepted.append(
                Example(row["id"], row["hypothesis"], target, WEAK_POSITIVE_WEIGHT))

    want_corrected = int(size * corrected_ratio)
    want_accepted = size - want_corrected
    take_corrected = min(want_corrected, len(corrected))
    take_accepted = min(want_accepted, len(accepted))

    # Preserve the ratio by shrinking, never by substituting.
    if take_accepted < want_accepted and corrected_ratio > 0:
        take_corrected = min(
            take_corrected,
            int(take_accepted * corrected_ratio / (1 - corrected_ratio))
            if corrected_ratio < 1 else take_corrected,
        )

    batch = rng.sample(corrected, take_corrected) + rng.sample(accepted, take_accepted)
    batch += list(generic)
    rng.shuffle(batch)
    return batch


class TrainingRun:
    """One gated training run: build, train, evaluate, promote or roll back."""

    def __init__(self, store: CorrectionStore, registry: AdapterRegistry,
                 trainer: Trainer, *, guard: Optional[ResourceGuard] = None):
        self.store, self.registry, self.trainer = store, registry, trainer
        self.guard = guard or ResourceGuard()

    def run(self, base_model: str, config: dict, transcriber: Transcriber,
            *, batch_size: int = 64, entities: Iterable[str] = ()) -> tuple[bool, str]:
        if blockers := self.guard.blockers():
            return False, "training deferred: " + "; ".join(blockers)

        batch = build_replay_batch(self.store, size=batch_size)
        if not batch:
            return False, "nothing to train on"
        if all(e.is_correction for e in batch):
            # Belt and braces: F3 is severe enough to be worth a hard stop.
            return False, "refusing to train on a corrections-only batch (F3)"

        self.trainer.train(batch, base_model, config)
        candidate = evaluate(self.store, transcriber, entities)
        baseline_adapter = self.registry.current(self.trainer.layer)
        baseline = baseline_adapter.eval if baseline_adapter else None

        adapter = self.registry.register(
            self.trainer.layer, base_model, config, candidate)
        decision = gate(candidate, baseline)
        return promote_if_gate_passes(self.registry, adapter.id, decision)


def rebuild(store: CorrectionStore, registry: AdapterRegistry,
            trainers: Sequence[Trainer], base_model: str, config: dict,
            transcriber: Transcriber) -> list[tuple[str, bool, str]]:
    """`dictate rebuild` — regenerate every adapter from the store alone (F13).

    Invariant 5. After a base model upgrade every existing adapter is bound to
    the wrong weights; this reconstructs them from the correction store, which
    is the only durable asset (SPEC §1.3).
    """
    results = []
    for trainer in trainers:
        run = TrainingRun(store, registry, trainer,
                          guard=ResourceGuard())      # defaults permit
        ok, message = run.run(base_model, config, transcriber)
        results.append((trainer.layer, ok, message))
    return results
