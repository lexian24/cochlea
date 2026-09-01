"""The text importer, which is where invariant 3 is hardest to hold.

A git log filters by author inside git, so other people's commits are never
read. A chat export has no such structure: both halves of the conversation are
in the same file, in the same shape, and telling them apart is this module's
whole job.
"""

import pytest

from cochlea.importers import REGISTRY, get
from cochlea.importers.textfile import AmbiguousAuthorship, TextFileImporter

CONVERSATION = """\
Lexian: I opened a pull request against main
Wei: which branch
Lexian: the kubectl one, check the nginx logs
Wei: nginx looks fine here
Lexian: run kubectl apply again
"""

PROSE = """\
Remember to check the nginx logs before deploying.
The kubectl timeout is set too low.
Ask about the eval gate: it blocks promotion.
"""


@pytest.fixture
def write(tmp_path):
    def _write(content, name="chat.txt"):
        path = tmp_path / name
        path.write_text(content)
        return str(path)
    return _write


def test_it_is_registered():
    assert "text" in REGISTRY
    assert get("text").name == "text"


def test_a_conversation_with_two_speakers_refuses_without_an_author(write):
    # Invariant 3, and F8's rejection of store-then-filter: the refusal has to
    # happen before anything is yielded, not after it is written and cleaned up.
    with pytest.raises(AmbiguousAuthorship) as excinfo:
        list(TextFileImporter().extract(write(CONVERSATION)))
    assert "Lexian" in str(excinfo.value) and "Wei" in str(excinfo.value)


def test_an_author_selects_only_their_own_lines(write):
    samples = list(TextFileImporter().extract(write(CONVERSATION), author="Lexian"))
    joined = " ".join(s.text for s in samples)
    assert "pull request" in joined
    assert "which branch" not in joined
    assert "looks fine here" not in joined
    assert all(s.own_content for s in samples)


def test_the_author_match_is_case_insensitive(write):
    samples = list(TextFileImporter().extract(write(CONVERSATION), author="lexian"))
    assert len(samples) == 3


def test_an_author_nobody_matches_is_an_error_not_an_empty_import(write):
    # Silently importing nothing reads as "my chat had no useful words in it",
    # which sends the user looking in the wrong place.
    with pytest.raises(AmbiguousAuthorship):
        list(TextFileImporter().extract(write(CONVERSATION), author="Nobody"))


def test_prose_is_taken_whole_without_an_author(write):
    # A notes file is the user's own by construction: they chose the file, and
    # there is no second speaker to exclude.
    samples = list(TextFileImporter().extract(write(PROSE)))
    assert len(samples) == 3


def test_a_colon_in_prose_does_not_invent_a_speaker(write):
    # "Ask about the eval gate: it blocks promotion." would otherwise make a
    # speaker called "Ask about the eval gate" and drop every other line.
    samples = list(TextFileImporter().extract(write(PROSE)))
    assert any("eval gate" in s.text for s in samples)


def test_a_single_speaker_throughout_needs_no_author(write):
    monologue = "Lexian: first note\nLexian: second note\nLexian: third note\n"
    samples = list(TextFileImporter().extract(write(monologue)))
    assert [s.text for s in samples] == ["first note", "second note", "third note"]


def test_a_timestamped_export_still_finds_the_speaker(write):
    whatsapp = (
        "[2026-08-30, 09:14:02] Lexian: check the nginx logs\n"
        "[2026-08-30, 09:14:40] Wei: on it\n"
        "[2026-08-30, 09:15:11] Lexian: kubectl apply worked\n"
    )
    samples = list(TextFileImporter().extract(write(whatsapp), author="Lexian"))
    assert [s.text for s in samples] == ["check the nginx logs", "kubectl apply worked"]


def test_content_is_redacted_before_it_is_yielded(write):
    # Redaction is not the caller's job: an importer that yields raw PII has
    # already lost, because the caller may write before it inspects.
    samples = list(TextFileImporter().extract(
        write("mail me at someone@example.com about the nginx logs\n")))
    assert "example.com" not in samples[0].text


def test_an_unreadable_file_says_so(write, tmp_path):
    with pytest.raises(ValueError, match="could not read"):
        list(TextFileImporter().extract(str(tmp_path / "nothing.txt")))


def test_an_empty_file_says_so(write):
    with pytest.raises(ValueError, match="no text"):
        list(TextFileImporter().extract(write("\n   \n\n")))
