"""M5: opt-in acoustic retention, caps, encryption, quarantine, purge."""

import time
import pytest

from cochlea.retention import (DEFAULT_MAX_AGE_DAYS, FeatureStore, KeyStore,
                               SpeakerVerifier)
from cochlea.store import MEL80, CorrectionStore, QUARANTINED, Utterance

try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM  # noqa: F401
    HAVE_CRYPTO = True
except BaseException:      # a mis-packaged build can fail with more than ImportError
    HAVE_CRYPTO = False

#: Encryption at rest needs the `acoustic` extra. Without it F7 says the store
#: must refuse to write rather than fall back to plaintext, so these tests skip
#: rather than fail — the same contract as the optional `zh` backend. The
#: fail-closed test below deliberately does NOT skip: that behaviour must hold
#: precisely when cryptography is missing.
requires_crypto = pytest.mark.skipif(
    not HAVE_CRYPTO, reason="needs the `acoustic` extra (cryptography)")


@pytest.fixture
def store(tmp_path):
    return FeatureStore(tmp_path / "features", KeyStore(tmp_path / "key.bin"),
                        enabled=True)


# --- opt-in (invariant 7) ---------------------------------------------------

def test_retention_is_off_by_default(tmp_path):
    fs = FeatureStore(tmp_path / "f", KeyStore(tmp_path / "k"))
    assert not fs.enabled
    with pytest.raises(PermissionError, match="invariant 7"):
        fs.put("u1", b"mel", duration_seconds=1.0)
    assert not (tmp_path / "f").exists()      # nothing created at all


# --- encryption at rest (F7) ------------------------------------------------

@requires_crypto
def test_features_are_not_readable_on_disk(store):
    plaintext = b"this would be a mel spectrogram" * 20
    path = store.put("u1", plaintext, duration_seconds=2.0)
    on_disk = path.read_bytes()
    assert plaintext not in on_disk
    assert store.get("u1") == plaintext


@requires_crypto
def test_key_file_is_not_world_readable(tmp_path, store):
    store.put("u1", b"x", duration_seconds=1.0)
    mode = (tmp_path / "key.bin").stat().st_mode & 0o777
    assert mode == 0o600


@requires_crypto
def test_feature_files_are_not_world_readable(store):
    path = store.put("u1", b"x", duration_seconds=1.0)
    assert path.stat().st_mode & 0o777 == 0o600


@requires_crypto
def test_backup_exclusion_marker_is_written(store):
    store.put("u1", b"x", duration_seconds=1.0)
    assert (store.directory / ".nobackup").exists()


# --- retention caps (F7) ----------------------------------------------------

@requires_crypto
def test_volume_cap_drops_oldest_first(tmp_path):
    fs = FeatureStore(tmp_path / "f", KeyStore(tmp_path / "k"),
                      enabled=True, max_hours=1.0)
    for i in range(5):
        fs.put(f"u{i}", b"x", duration_seconds=1800)     # 30 min each
        time.sleep(0.005)
    assert fs.stored_hours() == pytest.approx(2.5)
    removed = fs.enforce_retention()
    assert fs.stored_hours() <= 1.0
    assert "u0" in removed and "u4" not in removed       # oldest went first


@requires_crypto
def test_age_cap_drops_stale_entries(tmp_path):
    fs = FeatureStore(tmp_path / "f", KeyStore(tmp_path / "k"),
                      enabled=True, max_age_days=7)
    fs.put("old", b"x", duration_seconds=10)
    (fs.directory / "old.meta").write_text(f"{time.time() - 8 * 86400}\n10\n")
    fs.put("new", b"x", duration_seconds=10)
    removed = fs.enforce_retention()
    assert removed == ["old"]
    assert fs.get("new") == b"x"


@requires_crypto
def test_retention_holds_under_sustained_heavy_use(tmp_path):
    """M5 acceptance: the cap is enforced under sustained use, not just once."""
    fs = FeatureStore(tmp_path / "f", KeyStore(tmp_path / "k"),
                      enabled=True, max_hours=2.0)
    for i in range(200):
        fs.put(f"u{i}", b"x" * 64, duration_seconds=120)   # 2 min each
        fs.enforce_retention()
        assert fs.stored_hours() <= 2.0 + 1e-6


# --- purge ------------------------------------------------------------------

@requires_crypto
def test_purge_removes_everything_verifiably(store, tmp_path):
    for i in range(5):
        store.put(f"u{i}", b"secret", duration_seconds=1.0)
    assert store.purge() > 0
    assert list(store.directory.iterdir()) == []
    assert not (tmp_path / "key.bin").exists()     # the key goes too
    assert store.stored_hours() == 0.0


# --- speaker verification (F10) ---------------------------------------------

def test_matching_speaker_passes():
    v = SpeakerVerifier(enrolled=[1.0, 0.5, 0.2])
    assert v.verify([1.0, 0.5, 0.2]).matches


def test_different_speaker_is_quarantined_not_discarded():
    """F10: quarantine, and say so."""
    v = SpeakerVerifier(enrolled=[1.0, 0.0, 0.0])
    verdict = v.verify([0.0, 1.0, 0.0])
    assert not verdict.matches
    assert "quarantined" in verdict.reason and "not discarded" in verdict.reason


def test_unenrolled_verifier_does_not_wave_everything_through():
    """Treating unknown as a match would train on whoever is at the machine."""
    assert not SpeakerVerifier().verify([1.0, 2.0]).matches


def test_mismatched_embedding_lengths_are_an_error():
    with pytest.raises(ValueError):
        SpeakerVerifier(enrolled=[1.0, 2.0]).verify([1.0])


def test_quarantined_speaker_never_reaches_the_training_set():
    """M5 acceptance: a second speaker's utterances are not trained on."""
    cs = CorrectionStore()
    verifier = SpeakerVerifier(enrolled=[1.0, 0.0, 0.0])
    for embedding, text in [([1.0, 0.0, 0.0], "mine"), ([0.0, 1.0, 0.0], "theirs")]:
        verdict = verifier.verify(embedding)
        cs.add(Utterance(
            hypothesis=text, final_text=text + " fixed", base_model_id="m",
            attribution="correction" if verdict.matches else QUARANTINED,
            speaker_match_score=verdict.score))
    trainable = {r["hypothesis"] for r in cs.training_set()}
    assert trainable == {"mine"}
    assert len(cs.review_queue()) == 1


@requires_crypto
def test_opting_out_leaves_text_layers_working(tmp_path):
    """M5 acceptance: layers 1 and 2 stay fully functional after opting out."""
    fs = FeatureStore(tmp_path / "f", KeyStore(tmp_path / "k"), enabled=True)
    fs.put("u1", b"x", duration_seconds=1.0)
    fs.purge()
    fs.enabled = False

    cs = CorrectionStore(text_only=True)
    cs.add(Utterance(hypothesis="cube cuddle", final_text="kubectl",
                     base_model_id="m", attribution="correction"))
    assert len(cs.training_set()) == 1        # text pairs unaffected


def test_nothing_is_written_when_encryption_is_unavailable(tmp_path, monkeypatch):
    """F7: a broken crypto stack must fail closed, never write plaintext.

    Found the hard way — a mis-packaged `cryptography` raises a pyo3
    PanicException, which is not an Exception subclass, so a narrow
    `except ImportError` would have let it propagate as a crash rather than a
    refusal. Either way nothing may reach disk.
    """
    fs = FeatureStore(tmp_path / "f", KeyStore(tmp_path / "k"), enabled=True)

    def explode(self, plaintext):
        raise RuntimeError("encryption unavailable (SPEC F7)")

    monkeypatch.setattr(FeatureStore, "_encrypt", explode)
    with pytest.raises(RuntimeError, match="F7"):
        fs.put("u1", b"sensitive mel data", duration_seconds=1.0)

    written = [p for p in fs.directory.iterdir() if p.suffix != ""] \
        if fs.directory.exists() else []
    assert not [p for p in written if p.name.startswith("u1")]
