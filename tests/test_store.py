import pytest
from cochlea.store import (CORRECTION, MEL80, NO_FEATURES, QUARANTINED, REVISION,
                           UNEDITED, CorrectionStore, Utterance)


def utt(**kw):
    kw.setdefault("hypothesis", "hello world")
    kw.setdefault("base_model_id", "whisper-turbo")
    return Utterance(**kw)


def test_roundtrip_and_schema_version():
    s = CorrectionStore()
    uid = s.add(utt())
    row = s.all()[0]
    assert row["id"] == uid and row["schema_version"] == 1


def test_text_only_store_refuses_acoustic_features():
    """Invariant 7 / P4: enforced at the boundary, not by convention."""
    s = CorrectionStore(text_only=True)
    with pytest.raises(ValueError, match="text-only"):
        s.add(utt(features_path="/tmp/x.mel", features_kind=MEL80))
    assert s.all() == []


def test_acoustic_store_accepts_features_when_opted_in():
    s = CorrectionStore(text_only=False)
    s.add(utt(features_path="/tmp/x.mel", features_kind=MEL80))
    assert s.all()[0]["features_kind"] == MEL80


def test_holdout_never_appears_in_training_set():
    """Invariant 2, the one the eval gate depends on."""
    s = CorrectionStore()
    keep = s.add(utt(hypothesis="a", final_text="b", attribution=CORRECTION))
    held = s.add(utt(hypothesis="c", final_text="d", attribution=CORRECTION))
    s.mark_holdout(held)
    ids = {r["id"] for r in s.training_set()}
    assert keep in ids and held not in ids
    assert {r["id"] for r in s.holdout_set()} == {held}


def test_quarantined_and_revisions_excluded_from_training():
    s = CorrectionStore()
    s.add(utt(attribution=QUARANTINED))
    s.add(utt(attribution=REVISION))
    ok = s.add(utt(attribution=CORRECTION))
    assert {r["id"] for r in s.training_set()} == {ok}


def test_unedited_are_trainable_as_weak_positives():
    """F4: weak positives, not excluded, not gold."""
    s = CorrectionStore()
    uid = s.add(utt(attribution=UNEDITED))
    assert uid in {r["id"] for r in s.training_set()}


def test_corrections_per_100_words_is_the_primary_metric():
    s = CorrectionStore()
    for _ in range(9):
        s.add(utt(hypothesis="one two three four five six"))      # 6 words each
    s.add(utt(hypothesis="one two three", final_text="one two four",
              attribution=CORRECTION))                             # 3 words
    # 9*6 + 3 = 57 words dictated, 1 correction
    assert s.corrections_per_100_words() == pytest.approx(100 / 57, rel=1e-3)


def test_purge_all_and_audio_only():
    s = CorrectionStore(text_only=False)
    s.add(utt(features_path="/tmp/a.mel", features_kind=MEL80))
    assert s.purge(audio_only=True) == 1
    assert s.all()[0]["features_kind"] == NO_FEATURES
    assert s.all()[0]["features_path"] is None
    assert s.purge() == 1 and s.all() == []


def test_schema_mismatch_refuses_to_open(tmp_path):
    p = tmp_path / "c.db"
    CorrectionStore(p).close()
    import sqlite3
    db = sqlite3.connect(p)
    db.execute("UPDATE meta SET value='99' WHERE key='schema_version'")
    db.commit(); db.close()
    with pytest.raises(RuntimeError, match="schema v99"):
        CorrectionStore(p)
