"""M6: app-keyed profiles, shared acoustic adapter, asymmetric formality."""

import pytest

from cochlea.profiles import FORMAL_BOOST_SCALE, Formality, Profile, ProfileSet


def build():
    ps = ProfileSet()
    work = ps.add(Profile(name="work", formality=Formality.FORMAL,
                          app_patterns=["com.microsoft.Outlook", "com.apple.mail"]))
    chat = ps.add(Profile(name="chat", formality=Formality.CASUAL,
                          app_patterns=["com.tinyspeck.*"]))
    return ps, work, chat


def test_profile_is_selected_by_frontmost_app():
    ps, work, chat = build()
    assert ps.select("com.apple.mail").name == "work"
    assert ps.select("com.tinyspeck.slackmacgap").name == "chat"


def test_unknown_app_falls_back_to_default():
    ps, _, _ = build()
    assert ps.select("com.unknown.app").name == "default"
    assert ps.select(None).name == "default"


def test_glob_patterns_match():
    ps, _, chat = build()
    assert chat.matches("com.tinyspeck.anything")
    assert not chat.matches("com.slack.other")


def test_duplicate_profile_names_rejected():
    ps, _, _ = build()
    with pytest.raises(ValueError, match="already exists"):
        ps.add(Profile(name="work"))


def test_profiles_have_independent_lexicons():
    """F11: vocabulary varies by context, so it cannot be shared."""
    ps, work, chat = build()
    work.add_term("kubectl")
    assert work.boost_for("kubectl") > 1.0
    assert chat.boost_for("kubectl") == 1.0


# --- F12: the asymmetry -----------------------------------------------------

def test_slang_is_disabled_in_a_formal_profile():
    """Personal slang in a work email is the embarrassing direction."""
    work = Profile(name="work", formality=Formality.FORMAL)
    work.add_term("lah", slang=True)
    assert work.boost_for("lah") == 1.0


def test_slang_is_active_in_a_casual_profile():
    chat = Profile(name="chat", formality=Formality.CASUAL)
    chat.add_term("lah", boost=2.0, slang=True)
    assert chat.boost_for("lah") == 2.0


def test_formal_profiles_bias_conservatively_but_still_bias():
    """Work jargon in a formal context is wanted, just applied gently."""
    work = Profile(name="work", formality=Formality.FORMAL)
    work.add_term("kubectl", boost=3.0)
    boost = work.boost_for("kubectl")
    assert boost == pytest.approx(1.0 + 2.0 * FORMAL_BOOST_SCALE)
    assert 1.0 < boost < 3.0


def test_the_harmless_direction_is_not_suppressed():
    """F12 is asymmetric: work jargon in personal dictation is fine."""
    chat = Profile(name="chat", formality=Formality.CASUAL)
    chat.add_term("kubectl", boost=3.0)
    assert chat.boost_for("kubectl") == 3.0


def test_acoustic_adaptation_is_not_per_profile():
    """F11: the voice does not change with context.

    Profiles carry lexicon and style only. If a profile ever grows an acoustic
    adapter field, this test should be the thing that objects.
    """
    profile = Profile(name="work")
    assert not any("acoustic" in f for f in vars(profile))
