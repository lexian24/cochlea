"""Acoustic feature storage — M5. Opt-in, default off.

F7 is the governing risk: the feature store is a rolling record of everything
dictated, which plausibly includes credentials, health information and private
messages. Every control here exists to bound that.

The encryption is real (AES-GCM via the `cryptography` package when present)
but the *key management* is not: on macOS the key belongs in the Keychain, and
F7 explicitly says not to rely on FileVault being on. The fallback below keeps
the key in a 0600 file, which is weaker and says so.
"""

from __future__ import annotations

import hashlib
import hmac
import os
import secrets
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Optional

#: F7: two caps, whichever binds first.
DEFAULT_MAX_HOURS = 10.0
DEFAULT_MAX_AGE_DAYS = 30

#: F10: below this similarity an utterance is quarantined, not discarded.
SPEAKER_MATCH_THRESHOLD = 0.62


class KeyStore:
    """Holds the feature-encryption key.

    On macOS this must be the Keychain. This implementation is the portable
    fallback and is deliberately loud about being weaker.
    """

    def __init__(self, path: Path):
        self.path = Path(path)

    @property
    def is_keychain_backed(self) -> bool:
        return False

    def load_or_create(self) -> bytes:
        if self.path.exists():
            return self.path.read_bytes()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        key = secrets.token_bytes(32)
        # Create with the right mode rather than chmod-ing after: otherwise the
        # key is world-readable for the moment in between.
        fd = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            os.write(fd, key)
        finally:
            os.close(fd)
        return key

    def destroy(self) -> None:
        if self.path.exists():
            self.path.unlink()


class FeatureStore:
    """Encrypted, capped, backup-excluded storage for mel features."""

    def __init__(self, directory: Path, keystore: KeyStore, *,
                 enabled: bool = False,
                 max_hours: float = DEFAULT_MAX_HOURS,
                 max_age_days: int = DEFAULT_MAX_AGE_DAYS):
        self.directory = Path(directory)
        self.keystore = keystore
        self.enabled = enabled
        self.max_hours = max_hours
        self.max_age_days = max_age_days

    # -- writing ---------------------------------------------------------
    def put(self, utterance_id: str, features: bytes, *,
            duration_seconds: float) -> Path:
        if not self.enabled:
            raise PermissionError(
                "acoustic retention is off (SPEC invariant 7). Nothing is "
                "stored unless the user opts in."
            )
        self.directory.mkdir(parents=True, exist_ok=True)
        self._mark_excluded_from_backup()
        path = self.directory / f"{utterance_id}.mel.enc"
        payload = self._encrypt(features)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            os.write(fd, payload)
        finally:
            os.close(fd)
        (self.directory / f"{utterance_id}.meta").write_text(
            f"{time.time()}\n{duration_seconds}\n")
        return path

    def get(self, utterance_id: str) -> bytes:
        path = self.directory / f"{utterance_id}.mel.enc"
        return self._decrypt(path.read_bytes())

    # -- crypto ----------------------------------------------------------
    def _encrypt(self, plaintext: bytes) -> bytes:
        key = self.keystore.load_or_create()
        try:
            from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        except BaseException as exc:    # pragma: no cover - environment dependent
            # Deliberately broad. A broken install can fail with more than
            # ImportError (a mis-packaged build raises a pyo3 PanicException,
            # which is not even an Exception subclass). Whatever the cause,
            # the outcome must be the same: refuse, never fall back to
            # plaintext. F7 makes writing unencrypted audio features the worst
            # available failure.
            raise RuntimeError(
                "acoustic retention requires working AES-GCM for encryption at "
                "rest (SPEC F7); refusing to write plaintext audio features to "
                f"disk. Underlying error: {exc!r}"
            ) from exc
        nonce = secrets.token_bytes(12)
        return nonce + AESGCM(key).encrypt(nonce, plaintext, None)

    def _decrypt(self, blob: bytes) -> bytes:
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        key = self.keystore.load_or_create()
        return AESGCM(key).decrypt(blob[:12], blob[12:], None)

    # -- retention -------------------------------------------------------
    def _entries(self) -> list[tuple[str, float, float]]:
        out = []
        if not self.directory.exists():
            return out
        for meta in self.directory.glob("*.meta"):
            try:
                stamp, duration = meta.read_text().split()
            except ValueError:
                continue
            out.append((meta.stem, float(stamp), float(duration)))
        return sorted(out, key=lambda e: e[1])          # oldest first

    def stored_hours(self) -> float:
        return sum(d for _, _, d in self._entries()) / 3600.0

    def enforce_retention(self, now: Optional[float] = None) -> list[str]:
        """Apply both caps, whichever binds first (F7). Returns ids removed."""
        now = now or time.time()
        removed: list[str] = []
        entries = self._entries()

        # Age cap.
        cutoff = now - self.max_age_days * 86400
        for uid, stamp, _ in list(entries):
            if stamp < cutoff:
                self._remove(uid)
                removed.append(uid)
                entries = [e for e in entries if e[0] != uid]

        # Volume cap: drop oldest until under.
        total = sum(d for _, _, d in entries) / 3600.0
        for uid, _, duration in list(entries):
            if total <= self.max_hours:
                break
            self._remove(uid)
            removed.append(uid)
            total -= duration / 3600.0
        return removed

    def _remove(self, utterance_id: str) -> None:
        for suffix in (".mel.enc", ".meta"):
            path = self.directory / f"{utterance_id}{suffix}"
            if path.exists():
                path.unlink()

    def purge(self) -> int:
        """One-click purge (F7). Removes features and the key itself."""
        count = 0
        if self.directory.exists():
            for path in self.directory.iterdir():
                path.unlink()
                count += 1
        self.keystore.destroy()
        return count

    def _mark_excluded_from_backup(self) -> None:
        """F7: keep the store out of Time Machine and iCloud.

        The portable half is the `.nobackup` marker. The macOS half is
        `NSURLIsExcludedFromBackupKey`, which has no portable equivalent and is
        set by the app target.
        """
        marker = self.directory / ".nobackup"
        if not marker.exists():
            marker.write_text(
                "Excluded from backup: this directory holds a rolling record "
                "of dictated audio features (SPEC F7).\n")


@dataclass(frozen=True)
class SpeakerVerdict:
    score: float
    matches: bool
    reason: str


class SpeakerVerifier:
    """F10: someone else speaks into the mic.

    Mismatches are quarantined, never discarded — the spec is explicit, and it
    also catches accidental capture the user may want back. The embedding model
    (ECAPA or CAM++ class) is not implemented here; this owns the enrollment,
    comparison and threshold policy, which is the part that decides behaviour.
    """

    def __init__(self, enrolled: Optional[Iterable[float]] = None,
                 threshold: float = SPEAKER_MATCH_THRESHOLD):
        self.enrolled = list(enrolled) if enrolled is not None else None
        self.threshold = threshold

    @property
    def is_enrolled(self) -> bool:
        return self.enrolled is not None

    def enroll(self, embedding: Iterable[float]) -> None:
        self.enrolled = list(embedding)

    @staticmethod
    def cosine(a: list[float], b: list[float]) -> float:
        if not a or not b or len(a) != len(b):
            raise ValueError("embeddings must be non-empty and the same length")
        dot = sum(x * y for x, y in zip(a, b))
        na = sum(x * x for x in a) ** 0.5
        nb = sum(y * y for y in b) ** 0.5
        return 0.0 if na == 0 or nb == 0 else dot / (na * nb)

    def verify(self, embedding: Iterable[float]) -> SpeakerVerdict:
        if not self.is_enrolled:
            # Without enrolment there is no claim to check. Treating unknown as
            # "matches" would silently train on whoever is at the machine.
            return SpeakerVerdict(0.0, False,
                                  "no enrolled speaker; cannot verify")
        score = self.cosine(self.enrolled, list(embedding))
        if score >= self.threshold:
            return SpeakerVerdict(score, True, "matches the enrolled speaker")
        return SpeakerVerdict(
            score, False,
            f"similarity {score:.2f} below {self.threshold:.2f}; quarantined "
            f"for review, not discarded")
