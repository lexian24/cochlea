"""The correction store: the project's durable asset (SPEC §1.3).

Adapters are derived artifacts and must be rebuildable from this store alone
(invariant 5). Everything here except ``features_path``/``features_kind`` is
base-model-portable, which is what lets text-derived personalization survive a
base model upgrade (SPEC §1.3, P6).
"""

from __future__ import annotations

import sqlite3
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterator, Optional, Sequence

from . import SCHEMA_VERSION

# attribution values, per the SPEC §4 schema sketch
CORRECTION = "correction"
REVISION = "revision"
QUARANTINED = "quarantined"
UNEDITED = "unedited"

# features_kind values
MEL80, MEL128, OPUS, NO_FEATURES = "mel80", "mel128", "opus", "none"

_SCHEMA = """
CREATE TABLE IF NOT EXISTS utterance (
    id                    TEXT PRIMARY KEY,
    created_at            REAL    NOT NULL,
    schema_version        INTEGER NOT NULL,
    base_model_id         TEXT    NOT NULL,
    adapter_ids           TEXT    NOT NULL DEFAULT '[]',
    hypothesis            TEXT    NOT NULL,
    final_text            TEXT,
    correction_source     TEXT    NOT NULL,
    correction_latency_ms INTEGER,
    phonetic_distance     REAL,
    attribution           TEXT    NOT NULL,
    speaker_match_score   REAL,
    app_bundle_id         TEXT,
    profile_id            TEXT    NOT NULL DEFAULT 'default',
    features_path         TEXT,
    features_kind         TEXT    NOT NULL DEFAULT 'none',
    holdout               INTEGER NOT NULL DEFAULT 0,
    CHECK (attribution IN ('correction','revision','quarantined','unedited')),
    CHECK (correction_source IN ('fix_last','review_queue','none')),
    CHECK (features_kind IN ('mel80','mel128','opus','none')),
    CHECK (holdout IN (0,1))
);
CREATE INDEX IF NOT EXISTS idx_utt_attribution ON utterance(attribution);
CREATE INDEX IF NOT EXISTS idx_utt_holdout     ON utterance(holdout);

CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
"""


@dataclass
class Utterance:
    hypothesis: str
    base_model_id: str
    final_text: Optional[str] = None
    correction_source: str = "none"
    correction_latency_ms: Optional[int] = None
    phonetic_distance: Optional[float] = None
    attribution: str = UNEDITED
    speaker_match_score: Optional[float] = None
    app_bundle_id: Optional[str] = None
    profile_id: str = "default"
    features_path: Optional[str] = None
    features_kind: str = NO_FEATURES
    holdout: bool = False
    id: str = field(default_factory=lambda: uuid.uuid4().hex)
    created_at: float = field(default_factory=time.time)

    @property
    def text(self) -> str:
        """The best-known transcript: the user's edit if present, else the ASR's."""
        return self.final_text if self.final_text is not None else self.hypothesis


class CorrectionStore:
    """SQLite-backed, schema-versioned, human-inspectable (SPEC §1.3).

    ``text_only=True`` is the P4 configuration: the store refuses to record any
    reference to acoustic features. This is invariant 4 and invariant 7 enforced
    at the boundary rather than by convention.
    """

    def __init__(self, path: str | Path = ":memory:", *, text_only: bool = True):
        self.path = str(path)
        self.text_only = text_only
        self.db = sqlite3.connect(self.path)
        self.db.row_factory = sqlite3.Row
        self.db.executescript(_SCHEMA)
        cur = self.db.execute("SELECT value FROM meta WHERE key='schema_version'")
        row = cur.fetchone()
        if row is None:
            self.db.execute(
                "INSERT INTO meta (key, value) VALUES ('schema_version', ?)",
                (str(SCHEMA_VERSION),),
            )
            self.db.commit()
        elif int(row["value"]) != SCHEMA_VERSION:
            raise RuntimeError(
                f"store at {self.path} is schema v{row['value']}, "
                f"this build speaks v{SCHEMA_VERSION}; migrate before use"
            )

    # -- writing ---------------------------------------------------------
    def add(self, utt: Utterance) -> str:
        if self.text_only and (
            utt.features_path is not None or utt.features_kind != NO_FEATURES
        ):
            raise ValueError(
                "text-only store refuses acoustic features (SPEC invariant 7): "
                f"features_kind={utt.features_kind!r} path={utt.features_path!r}"
            )
        self.db.execute(
            """INSERT INTO utterance (
                 id, created_at, schema_version, base_model_id, adapter_ids,
                 hypothesis, final_text, correction_source, correction_latency_ms,
                 phonetic_distance, attribution, speaker_match_score,
                 app_bundle_id, profile_id, features_path, features_kind, holdout)
               VALUES (?,?,?,?,'[]',?,?,?,?,?,?,?,?,?,?,?,?)""",
            (
                utt.id, utt.created_at, SCHEMA_VERSION, utt.base_model_id,
                utt.hypothesis, utt.final_text, utt.correction_source,
                utt.correction_latency_ms, utt.phonetic_distance, utt.attribution,
                utt.speaker_match_score, utt.app_bundle_id, utt.profile_id,
                utt.features_path, utt.features_kind, int(utt.holdout),
            ),
        )
        self.db.commit()
        return utt.id

    def mark_holdout(self, utterance_id: str) -> None:
        """Reserve an utterance from training, permanently (invariant 2)."""
        self.db.execute(
            "UPDATE utterance SET holdout=1 WHERE id=?", (utterance_id,)
        )
        self.db.commit()

    # -- reading ---------------------------------------------------------
    def _rows(self, where: str = "", args: Sequence = ()) -> Iterator[sqlite3.Row]:
        yield from self.db.execute(
            f"SELECT * FROM utterance {where} ORDER BY created_at", args
        )

    def all(self) -> list[sqlite3.Row]:
        return list(self._rows())

    def training_set(self) -> list[sqlite3.Row]:
        """Every utterance eligible for training.

        Excludes holdout (invariant 2), quarantined items awaiting adjudication
        (F1, F10), and revisions, which are not evidence about ASR (F1).
        """
        return list(
            self._rows(
                "WHERE holdout=0 AND attribution IN (?,?)", (CORRECTION, UNEDITED)
            )
        )

    def holdout_set(self) -> list[sqlite3.Row]:
        return list(self._rows("WHERE holdout=1"))

    def review_queue(self) -> list[sqlite3.Row]:
        """Quarantined items, surfaced for manual adjudication (F1)."""
        return list(self._rows("WHERE attribution=?", (QUARANTINED,)))

    def corrections_per_100_words(self) -> float:
        """The primary metric (F17). Measured over everything dictated."""
        words = corrections = 0
        for row in self._rows():
            words += len(row["hypothesis"].split())
            if row["attribution"] == CORRECTION:
                corrections += 1
        return 0.0 if words == 0 else 100.0 * corrections / words

    def purge(self, *, audio_only: bool = False) -> int:
        """`dictate purge`. Returns rows affected."""
        if audio_only:
            cur = self.db.execute(
                "UPDATE utterance SET features_path=NULL, features_kind='none' "
                "WHERE features_kind != 'none'"
            )
        else:
            cur = self.db.execute("DELETE FROM utterance")
        self.db.commit()
        return cur.rowcount

    def close(self) -> None:
        self.db.close()
