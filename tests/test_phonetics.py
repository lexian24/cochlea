import pytest
from cochlea import phonetics


def test_registry_has_en_and_fallback():
    assert "en" in phonetics.available()
    assert phonetics.get("does-not-exist").language == "*"


def test_identical_words_are_zero_distance():
    assert phonetics.get("en").distance("nginx", "nginx") == 0.0


def test_close_words_are_closer_than_unrelated_ones():
    en = phonetics.get("en")
    assert en.distance("Giang", "young") < en.distance("Giang", "elephant")


def test_homophones_collapse_to_zero_under_metaphone():
    """F5 in evidence: biasing cannot separate these."""
    assert phonetics.get("en").distance("their", "there") == 0.0


def test_fallback_is_used_for_unregistered_language():
    """P5: a new language pair must work without surgery."""
    tl = phonetics.get("tl")
    assert 0.0 < tl.distance("kumain", "kumsin") < 0.5


def test_registering_a_new_backend_overrides_fallback():
    class Always: 
        language = "xx"
        def distance(self, a, b): return 0.42
    phonetics.register(Always())
    try:
        assert phonetics.get("xx").distance("a", "b") == 0.42
    finally:
        phonetics._REGISTRY.pop("xx")


def test_distances_are_normalized():
    en = phonetics.get("en")
    for a, b in [("", ""), ("a", ""), ("cat", "elephant"), ("x", "y")]:
        assert 0.0 <= en.distance(a, b) <= 1.0


@pytest.mark.skipif("zh" not in phonetics.available(), reason="pypinyin absent")
def test_pinyin_backend_separates_by_sound_not_glyph():
    zh = phonetics.get("zh")
    assert zh.distance("张伟", "章伟") == 0.0     # same sound, different glyph
    assert zh.distance("张伟", "李娜") > 0.5
