"""Adapter versioning, promotion, retention and rollback.

Adapters are derived artifacts (SPEC §1.3): every one is bound to specific base
weights and is worthless after an upgrade, so nothing here is precious and
delete-and-rebuild is always available.

F14 requires that promotion is gated and that regression rolls back
automatically. F15 requires that every session can name the adapter version,
base model, config hash and eval score that produced it -- without that,
"it was better last week" is unfalsifiable.
"""

from __future__ import annotations

import hashlib
import json
import sqlite3
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from .evaluation import EvalResult, GateDecision

#: Adapters are tens of MB; keeping several costs little and buys a rollback.
RETAIN = 5

LAYERS = ("lexicon", "postcorr", "acoustic")

_SCHEMA = """
CREATE TABLE IF NOT EXISTS adapter (
    id            TEXT PRIMARY KEY,
    layer         TEXT    NOT NULL,
    version       INTEGER NOT NULL,
    base_model_id TEXT    NOT NULL,
    config_hash   TEXT    NOT NULL,
    created_at    REAL    NOT NULL,
    eval_json     TEXT,
    promoted      INTEGER NOT NULL DEFAULT 0,
    retired_at    REAL,
    UNIQUE (layer, version)
);
"""


def config_hash(config: dict) -> str:
    """Stable hash of a training config, for F15's reproducibility record."""
    blob = json.dumps(config, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(blob.encode()).hexdigest()[:16]


@dataclass
class Adapter:
    id: str
    layer: str
    version: int
    base_model_id: str
    config_hash: str
    created_at: float
    eval: Optional[EvalResult] = None
    promoted: bool = False

    @classmethod
    def _from_row(cls, row: sqlite3.Row) -> "Adapter":
        raw = json.loads(row["eval_json"]) if row["eval_json"] else None
        return cls(
            id=row["id"], layer=row["layer"], version=row["version"],
            base_model_id=row["base_model_id"], config_hash=row["config_hash"],
            created_at=row["created_at"],
            eval=EvalResult(**raw) if raw else None,
            promoted=bool(row["promoted"]),
        )


class AdapterRegistry:
    def __init__(self, path: str | Path = ":memory:", *, retain: int = RETAIN):
        self.db = sqlite3.connect(str(path))
        self.db.row_factory = sqlite3.Row
        self.db.executescript(_SCHEMA)
        self.retain = retain

    # -- registration ----------------------------------------------------
    def register(self, layer: str, base_model_id: str, config: dict,
                 evaluation: Optional[EvalResult] = None) -> Adapter:
        if layer not in LAYERS:
            raise ValueError(f"unknown layer {layer!r}; expected one of {LAYERS}")
        cur = self.db.execute(
            "SELECT COALESCE(MAX(version), 0) AS v FROM adapter WHERE layer=?", (layer,)
        )
        version = cur.fetchone()["v"] + 1
        chash = config_hash(config)
        aid = f"{layer}-v{version}-{chash[:8]}"
        self.db.execute(
            "INSERT INTO adapter (id, layer, version, base_model_id, config_hash,"
            " created_at, eval_json, promoted) VALUES (?,?,?,?,?,?,?,0)",
            (aid, layer, version, base_model_id, chash, time.time(),
             json.dumps(evaluation.as_dict()) if evaluation else None),
        )
        self.db.commit()
        return self.get(aid)

    def get(self, adapter_id: str) -> Adapter:
        row = self.db.execute("SELECT * FROM adapter WHERE id=?", (adapter_id,)).fetchone()
        if row is None:
            raise KeyError(f"no adapter {adapter_id!r}")
        return Adapter._from_row(row)

    def history(self, layer: str) -> list[Adapter]:
        return [Adapter._from_row(r) for r in self.db.execute(
            "SELECT * FROM adapter WHERE layer=? ORDER BY version DESC", (layer,))]

    def current(self, layer: str) -> Optional[Adapter]:
        row = self.db.execute(
            "SELECT * FROM adapter WHERE layer=? AND promoted=1 "
            "ORDER BY version DESC LIMIT 1", (layer,)).fetchone()
        return Adapter._from_row(row) if row else None

    # -- promotion -------------------------------------------------------
    def promote(self, adapter_id: str, decision: GateDecision) -> Adapter:
        """Promote a candidate. Refuses unless the gate said so (invariant 1)."""
        if not decision.promoted:
            raise PermissionError(
                f"refusing to promote {adapter_id}: gate said {decision.reason}. "
                "Invariant 1 -- no adapter is promoted without passing the eval gate."
            )
        adapter = self.get(adapter_id)
        self.db.execute("UPDATE adapter SET promoted=0, retired_at=? "
                        "WHERE layer=? AND promoted=1", (time.time(), adapter.layer))
        self.db.execute("UPDATE adapter SET promoted=1, retired_at=NULL WHERE id=?",
                        (adapter_id,))
        self.db.commit()
        self._prune(adapter.layer)
        return self.get(adapter_id)

    def rollback(self, layer: str, to_version: Optional[int] = None) -> Optional[Adapter]:
        """`dictate rollback`. Defaults to the previously promoted version."""
        history = self.history(layer)
        if not history:
            return None
        if to_version is not None:
            target = next((a for a in history if a.version == to_version), None)
            if target is None:
                raise KeyError(f"no {layer} adapter at version {to_version}")
        else:
            current = self.current(layer)
            candidates = [a for a in history
                          if a.eval is not None and (current is None or a.version < current.version)]
            if not candidates:
                return None
            target = candidates[0]
        self.db.execute("UPDATE adapter SET promoted=0, retired_at=? "
                        "WHERE layer=? AND promoted=1", (time.time(), layer))
        self.db.execute("UPDATE adapter SET promoted=1, retired_at=NULL WHERE id=?",
                        (target.id,))
        self.db.commit()
        return self.get(target.id)

    def _prune(self, layer: str) -> list[str]:
        """Retain the last N; never delete the promoted one."""
        keep = {a.id for a in self.history(layer)[: self.retain]}
        if cur := self.current(layer):
            keep.add(cur.id)
        doomed = [a.id for a in self.history(layer) if a.id not in keep]
        for aid in doomed:
            self.db.execute("DELETE FROM adapter WHERE id=?", (aid,))
        self.db.commit()
        return doomed

    def close(self) -> None:
        self.db.close()


def promote_if_gate_passes(registry: AdapterRegistry, adapter_id: str,
                           decision: GateDecision) -> tuple[bool, str]:
    """Promote on pass, roll back on regression -- with no user intervention.

    This is M3's acceptance criterion in one function: a corrupted adapter is
    caught by the gate and the previous one is restored automatically.
    """
    if decision.promoted:
        registry.promote(adapter_id, decision)
        return True, f"promoted {adapter_id}"
    layer = registry.get(adapter_id).layer
    restored = registry.current(layer) or registry.rollback(layer)
    where = f"; retained {restored.id}" if restored else "; no adapter promoted"
    return False, f"rejected {adapter_id} ({decision.reason}){where}"
