from cochlea.attribution import Thresholds, classify, changed_spans, edit_fraction
from cochlea.store import CORRECTION, QUARANTINED, REVISION, UNEDITED


def test_no_edit_is_unedited():
    v = classify("the server is down", None)
    assert v.attribution == UNEDITED and v.phonetic_distance is None


def test_identical_final_text_is_unedited():
    assert classify("abc", "abc").attribution == UNEDITED


def test_fast_close_local_edit_is_a_correction():
    v = classify("meet young at three", "meet Giang at three", latency_ms=1500)
    assert v.attribution == CORRECTION
    assert all(v.signals.values())


def test_slow_distant_rewrite_is_a_revision():
    v = classify("lets grab lunch tomorrow",
                 "actually lets skip lunch and meet on friday instead",
                 latency_ms=90_000)
    assert v.attribution == REVISION
    assert v.failed == ["latency", "phonetic", "locality"]


def test_two_failed_signals_quarantines_for_adjudication():
    """The one threshold the SPEC states explicitly: fails two of three."""
    v = classify("send it to bob", "send it to robert immediately", latency_ms=800)
    assert v.signals["latency"] is True
    assert v.attribution == QUARANTINED
    assert len(v.failed) == 2


def test_one_failed_signal_is_still_a_correction():
    v = classify("deploy with cube cuddle", "deploy with kubectl", latency_ms=1200)
    assert len(v.failed) == 1 and v.attribution == CORRECTION


def test_review_queue_does_not_penalise_latency():
    """The queue is cleared when idle, so its latency is not evidence (SPEC §1.1).

    The same edit is a correction from the queue but must not be judged on a
    latency it structurally cannot meet.
    """
    edit = ("meet young at three", "meet Giang at three")
    slow = classify(*edit, correction_source="review_queue",
                    latency_ms=3_600_000)
    assert "latency" not in slow.signals
    assert slow.attribution == CORRECTION


def test_pure_insertion_is_not_a_correction():
    """Nothing was substituted, so there is no acoustic claim to check."""
    v = classify("the server is down",
                 "the server is down and I have paged the on call",
                 latency_ms=20_000)
    assert v.signals["phonetic"] is False
    assert v.attribution == REVISION


def test_phonetic_distance_uses_changed_span_not_whole_utterance():
    """A one-word fix in a long sentence must not look near-identical."""
    hyp = "the quarterly report for the northern region is ready for review now"
    fin = hyp.replace("northern", "elephant")
    before, after = changed_spans(hyp, fin)
    assert (before, after) == ("northern", "elephant")
    v = classify(hyp, fin, latency_ms=1000)
    # Whole-sentence comparison would score ~0.05 here and pass the phonetic
    # signal; scoring the replaced span alone correctly fails it.
    assert v.phonetic_distance > 0.5
    assert v.signals["phonetic"] is False
    # Latency and locality still pass, so by the two-of-three rule this is
    # a correction -- one failed signal is below the quarantine threshold.
    assert v.failed == ["phonetic"] and v.attribution == CORRECTION


def test_thresholds_are_tunable():
    edit = ("meet young at three", "meet Giang at three")
    strict = Thresholds(max_phonetic_distance=0.01)
    assert classify(*edit, latency_ms=100, thresholds=strict).signals["phonetic"] is False


def test_edit_fraction_bounds():
    assert edit_fraction("a b c", "a b c") == 0.0
    assert edit_fraction("a b c", "x y z") == 1.0
