import time
import pytest
from cochlea.lexicon import (EXPIRY_SECONDS, MAX_BOOST, HomophoneRejected, Lexicon,
                            detect_variants, extract_terms)


def test_boost_is_capped():
    """F2: magnitude cap is not advisory."""
    assert Lexicon().add("kubectl", boost=1000.0).boost == MAX_BOOST


def test_homophone_entries_are_rejected():
    """F5: boosting a homophone creates errors instead of fixing them."""
    lx = Lexicon()
    with pytest.raises(HomophoneRejected):
        lx.add("their")
    assert "their" not in lx.entries


def test_near_homophone_proper_noun_is_still_admitted():
    """The F5 guard must not swallow the terms the product exists to fix."""
    assert Lexicon().add("Giang").boost > 1.0


def test_negative_signal_decays_an_over_trigger():
    """F2 acceptance: a deliberately-induced over-trigger decays within N."""
    lx = Lexicon()
    lx.add("nginx", boost=MAX_BOOST)
    n = 0
    while "nginx" in lx.entries and n < 10:
        lx.record_rejection("nginx"); n += 1
    assert "nginx" not in lx.entries, "over-trigger never decayed"
    assert n <= 3, f"took {n} rejections to decay; too slow to be useful"


def test_unused_entries_expire():
    lx = Lexicon()
    e = lx.add("transient")
    e.last_used_at = time.time() - EXPIRY_SECONDS - 1
    assert lx.expire() == ["transient"] and lx.boost_for("transient") == 1.0


def test_hits_keep_an_entry_alive():
    lx = Lexicon()
    e = lx.add("kubectl")
    e.last_used_at = time.time() - EXPIRY_SECONDS - 1
    lx.record_hit("kubectl")
    assert lx.expire() == []


def test_term_extraction_finds_project_vocabulary():
    samples = ["bump nginx to 1.25", "fix nginx retry", "kubectl apply", "kubectl get pods"]
    terms = dict(extract_terms(samples, min_count=2))
    assert "nginx" in terms and "kubectl" in terms
    assert terms["nginx"] == 2


def test_orthography_variants_are_detected():
    """F6: the canonicalization prompt."""
    variants = detect_variants(["ok la", "yes la", "fine lah", "sure lah"], min_count=2)
    assert ("la", "lah") in [(a, b) for a, b, _, _ in variants]


def test_canonicalization_rewrites_text():
    lx = Lexicon()
    lx.canonicalize("la", "lah")
    assert lx.apply_canonical("ok la and la") == "ok lah and lah"


# --- regressions found by running the P2 journey against a real repo ---------

def test_common_words_are_not_extracted_as_terms():
    """The lexicon filled with 'are', 'open', 'mode', 'was' before this."""
    samples = ["the mode was open and are ready"] * 3
    assert extract_terms(samples, min_count=2) == []


def test_redaction_placeholders_never_become_terms():
    """Importing a corpus containing PII must not teach the word 'EMAIL'."""
    from cochlea.privacy import redact
    samples = [redact("ping alice@example.com and bob@example.com")] * 3
    assert not [t for t, _ in extract_terms(samples, min_count=2)
                if t in {"EMAIL", "URL", "NUMBER", "POSTAL"}]


def test_technical_identifiers_survive_extraction():
    samples = ["use mlx-tune on large-v3", "mlx-tune with large-v3 again"]
    terms = dict(extract_terms(samples, min_count=2))
    assert "mlx-tune" in terms and "large-v3" in terms


@pytest.mark.parametrize("a,b", [("la", "lah"), ("ok", "okay"), ("colour", "color")])
def test_real_orthography_variants_are_detected(a, b):
    samples = [f"x {a}"] * 2 + [f"y {b}"] * 2
    pairs = {tuple(sorted((x, y))) for x, y, _, _ in detect_variants(samples, min_count=2)}
    assert tuple(sorted((a, b))) in pairs


@pytest.mark.parametrize("a,b", [
    ("now", "no"),        # two common words, not one word spelled twice
    ("open", "opus"),     # unrelated, distance 2, no prefix relation
    ("warm", "was"),      # unrelated
    ("invariant", "invariants"),   # plural, not a spelling variant
])
def test_unrelated_pairs_are_not_reported_as_variants(a, b):
    samples = [f"x {a}"] * 3 + [f"y {b}"] * 3
    pairs = {tuple(sorted((x, y))) for x, y, _, _ in detect_variants(samples, min_count=2)}
    assert tuple(sorted((a, b))) not in pairs
