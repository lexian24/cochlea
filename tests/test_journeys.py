"""The persona journeys from SPEC §3, executed rather than described.

Each test walks one persona's documented path through the layers that exist
today. The macOS capture path (M0) is not implemented, so where a journey says
"dictate", these tests inject the hypothesis the ASR would have produced and
exercise everything downstream of it: attribution, the store, the lexicon, and
the invariants each persona depends on.
"""

import subprocess

import pytest

from cochlea.attribution import classify
from cochlea.importers import get as get_importer
from cochlea.lexicon import HomophoneRejected, Lexicon, detect_variants, extract_terms
from cochlea.store import (CORRECTION, MEL80, QUARANTINED, CorrectionStore,
                           Utterance, UNEDITED)


def make_repo(tmp_path, commits, email="dev@example.com"):
    r = tmp_path / "proj"; r.mkdir()
    run = lambda *a: subprocess.run(["git", "-C", str(r), *a], check=True,
                                    capture_output=True)
    run("init", "-q", "-b", "main")
    run("config", "user.email", email)
    run("config", "user.name", "Dev")
    for i, (msg, author) in enumerate(commits):
        (r / f"f{i}").write_text("x")
        run("add", "-A")
        run("-c", f"user.email={author}", "-c", "user.name=X",
            "commit", "-q", "-m", msg)
    return r


def dictate(store, hypothesis, final_text=None, *, latency_ms=None,
            source="fix_last", language="en", **kw):
    """One utterance through the pipeline: classify, then persist."""
    v = classify(hypothesis, final_text, correction_source=source,
                 latency_ms=latency_ms, language=language)
    utt = Utterance(
        hypothesis=hypothesis, final_text=final_text, base_model_id="whisper-turbo",
        correction_source=source if final_text else "none",
        correction_latency_ms=latency_ms, phonetic_distance=v.phonetic_distance,
        attribution=v.attribution, **kw)
    store.add(utt)
    return v


# --- P2: monolingual developer, the largest realistic OSS audience -----------

def test_p2_monolingual_developer_journey(tmp_path):
    """install -> import git log only -> dictate -> lexicon fills from corrections.

    Never touches a language setting. The whole journey must work with the
    default (monolingual, text-only) configuration.
    """
    repo = make_repo(tmp_path, [
        ("add kubectl retry on nginx upstream timeout", "dev@example.com"),
        ("bump nginx to 1.25 and pin kubectl", "dev@example.com"),
        ("refactor kubectl client", "dev@example.com"),
        ("UNRELATED work by a colleague on nginx", "someone@else.com"),
    ])

    # 1. import git log only
    samples = list(get_importer("gitlog").extract(str(repo)))
    joined = " ".join(s.text for s in samples)
    assert "UNRELATED" not in joined, "invariant 3 violated at import"

    # 2. lexicon is populated before the first correction is ever made
    lx = Lexicon()
    for term, _count in extract_terms((s.text for s in samples), min_count=2):
        try:
            lx.add(term)
        except HomophoneRejected:
            pass
    assert lx.boost_for("kubectl") > 1.0
    assert lx.boost_for("nginx") > 1.0

    # 3. dictate on the default store (text-only by default)
    store = CorrectionStore()
    dictate(store, "deploy the new pods now")                       # unedited
    v = dictate(store, "run cube cuddle get pods",
                "run kubectl get pods", latency_ms=1800)            # fix-last
    assert v.attribution == CORRECTION

    # 4. the store reflects it, and the primary metric is computable
    assert len(store.training_set()) == 2      # correction + weak positive (F4)
    assert store.corrections_per_100_words() > 0


def test_p2_never_needs_a_language_setting():
    """Multilingual machinery must be invisible when unused."""
    v = classify("run cube cuddle", "run kubectl", latency_ms=900)   # no language=
    assert v.attribution == CORRECTION


# --- P4: privacy maximalist --------------------------------------------------

def test_p4_text_only_mode_is_fully_functional(tmp_path):
    """Invariant 4. Layers 1 and 2 need only text pairs.

    This persona gets everything except acoustic adaptation. "Fully functional"
    means the journey completes, not that it degrades gracefully.
    """
    store = CorrectionStore(text_only=True)

    dictate(store, "meet young at three", "meet Giang at three", latency_ms=1200)
    dictate(store, "the build is green")
    dictate(store, "send it to bob", "send it to robert immediately", latency_ms=600)

    assert len(store.all()) == 3
    assert len(store.training_set()) == 2
    assert len(store.review_queue()) == 1        # the ambiguous one, quarantined
    assert store.corrections_per_100_words() > 0

    # nothing acoustic was recorded anywhere
    assert all(r["features_path"] is None and r["features_kind"] == "none"
               for r in store.all())

    # and the store actively refuses acoustic data, it does not merely omit it
    with pytest.raises(ValueError):
        store.add(Utterance(hypothesis="x", base_model_id="m",
                            features_path="/tmp/a.mel", features_kind=MEL80))


def test_p4_lexicon_layer_works_without_any_audio():
    lx = Lexicon()
    lx.add("kubectl")
    assert lx.boost_for("kubectl") > 1.0        # layer 1, text only


# --- P1: bilingual developer, code-switching --------------------------------

def test_p1_zh_corrections_use_the_pinyin_backend():
    pytest.importorskip("pypinyin")
    store = CorrectionStore()
    # same sound, wrong characters: the canonical acoustic-adjacent correction
    v = dictate(store, "我叫章伟", "我叫张伟", latency_ms=1500, language="zh")
    assert v.phonetic_distance == 0.0
    assert v.attribution == CORRECTION


def test_p1_orthography_variants_surface_for_canonicalization():
    """F6: the good UX moment that demonstrates the product thesis."""
    variants = detect_variants(["ok la", "yes la", "fine lah", "sure lah"], min_count=2)
    assert variants, "no canonicalization prompt was produced"
    a, b, *_ = variants[0]
    lx = Lexicon()
    lx.canonicalize(a, b)
    assert lx.apply_canonical("ok la") == f"ok {b}"


# --- P5: unsupported language pair ------------------------------------------

def test_p5_unsupported_language_pair_works_without_surgery():
    """The fallback must carry a language nobody has written a backend for."""
    store = CorrectionStore()
    v = dictate(store, "gusto ko kumsin", "gusto ko kumain",
                latency_ms=1400, language="tl")     # Tagalog: no backend
    assert v.attribution == CORRECTION
    assert v.phonetic_distance is not None and v.phonetic_distance < 0.34


# --- P6: returning user after a base model upgrade --------------------------

def test_p6_text_pairs_survive_a_base_model_change(tmp_path):
    """SPEC §1.3: text-derived personalization is base-model-portable.

    The asymmetry users must be told about: text pairs carry over, acoustic
    history does not.
    """
    path = tmp_path / "c.db"
    old = CorrectionStore(path, text_only=False)
    old.add(Utterance(hypothesis="cube cuddle", final_text="kubectl",
                      base_model_id="whisper-turbo", attribution=CORRECTION,
                      features_path="/tmp/a.mel", features_kind=MEL80))
    old.close()

    # base model upgrade: the text pair is still readable and still trainable
    new = CorrectionStore(path, text_only=False)
    row = new.all()[0]
    assert (row["hypothesis"], row["final_text"]) == ("cube cuddle", "kubectl")
    assert row["base_model_id"] == "whisper-turbo"      # provenance retained
    assert len(new.training_set()) == 1

    # the acoustic half is what does not carry: mel80 belongs to the old encoder
    assert row["features_kind"] == MEL80
    purged = new.purge(audio_only=True)
    assert purged == 1 and new.all()[0]["final_text"] == "kubectl"


# --- invariants that no single persona owns ---------------------------------

def test_holdout_is_never_reachable_from_the_training_set():
    """Invariant 2, checked over a realistic mixed store."""
    store = CorrectionStore()
    ids = []
    for i in range(20):
        v = dictate(store, f"hypothesis number {i} here",
                    f"hypothesis number {i} there", latency_ms=1000)
        ids.append(store.all()[-1]["id"])
    for uid in ids[::4]:
        store.mark_holdout(uid)
    held = {r["id"] for r in store.holdout_set()}
    trainable = {r["id"] for r in store.training_set()}
    assert held and not (held & trainable)
