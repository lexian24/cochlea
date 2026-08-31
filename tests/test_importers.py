import os
import subprocess
import pytest
from cochlea.importers import REGISTRY, get
from cochlea.privacy import contains_pii, redact


def _repo(tmp_path, commits):
    r = tmp_path / "r"; r.mkdir()
    run = lambda *a: subprocess.run(["git", "-C", str(r), *a], check=True,
                                    capture_output=True)
    run("init", "-q", "-b", "main")
    run("config", "user.email", "me@example.com")
    run("config", "user.name", "Me")
    for i, (msg, email, name) in enumerate(commits):
        (r / f"f{i}").write_text("x")
        run("add", "-A")
        run("-c", f"user.email={email}", "-c", f"user.name={name}",
            "commit", "-q", "-m", msg)
    return r


def test_gitlog_yields_only_the_users_own_commits(tmp_path):
    """Invariant 3, enforced structurally: git never reads the other commits."""
    r = _repo(tmp_path, [
        ("add kubectl retry", "me@example.com", "Me"),
        ("SOMEONE ELSES COMMIT", "other@example.com", "Other"),
        ("fix nginx timeout", "me@example.com", "Me"),
    ])
    texts = [s.text for s in get("gitlog").extract(str(r), author="me@example.com")]
    joined = " ".join(texts)
    assert "kubectl" in joined and "nginx" in joined
    assert "SOMEONE ELSES COMMIT" not in joined
    assert all(s.own_content for s in get("gitlog").extract(str(r), author="me@example.com"))


def test_gitlog_refuses_to_import_everyone(tmp_path, monkeypatch):
    """With no identity configured, importing would sweep in every contributor."""
    r = _repo(tmp_path, [("only commit", "me@example.com", "Me")])
    subprocess.run(["git", "-C", str(r), "config", "--unset", "user.email"], check=True)
    # `git config user.email` falls back to global and system config, so the
    # local unset alone does not produce an unconfigured repo.
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", os.devnull)
    monkeypatch.setenv("GIT_CONFIG_SYSTEM", os.devnull)
    with pytest.raises(ValueError, match="invariant 3"):
        list(get("gitlog").extract(str(r)))


def test_gitlog_defaults_to_the_configured_user(tmp_path):
    r = _repo(tmp_path, [
        ("my own commit", "me@example.com", "Me"),
        ("not mine", "other@example.com", "Other"),
    ])
    texts = " ".join(s.text for s in get("gitlog").extract(str(r)))
    assert "my own commit" in texts and "not mine" not in texts


def test_pii_is_redacted_at_parse_time(tmp_path):
    """F8: strip before writing, never store-then-filter."""
    r = _repo(tmp_path, [
        ("contact alice@example.com about card 4111 1111 1111 1111",
         "me@example.com", "Me")])
    text = " ".join(s.text for s in get("gitlog").extract(str(r), author="me@example.com"))
    assert "alice@example.com" not in text and "4111" not in text
    assert "[EMAIL]" in text and "[NUMBER]" in text


def test_redaction_preserves_technical_vocabulary():
    """The lexicon is the point; over-redaction would defeat the import."""
    t = "kubectl apply -f deploy.yaml against nginx 1.25"
    assert redact(t) == t and not contains_pii(t)


def test_unknown_importer_is_a_clear_error():
    with pytest.raises(KeyError, match="unknown importer"):
        get("whatsapp")


def test_registry_is_populated():
    assert "gitlog" in REGISTRY


def test_zero_match_import_explains_itself(tmp_path):
    """A silent 'imported 0 samples' is the bug this guards against."""
    from cochlea.importers.gitlog import NoCommitsMatched
    r = _repo(tmp_path, [("only commit", "me@example.com", "Me")])
    with pytest.raises(NoCommitsMatched) as ei:
        list(get("gitlog").extract(str(r), author="nobody@nowhere.test"))
    msg = str(ei.value)
    assert "no commits by 'nobody@nowhere.test'" in msg
    assert "me@example.com" in msg and "--author" in msg


def test_authors_listing_counts_commits(tmp_path):
    r = _repo(tmp_path, [
        ("a", "me@example.com", "Me"), ("b", "me@example.com", "Me"),
        ("c", "other@example.com", "Other"),
    ])
    assert get("gitlog").authors(str(r)) == [("me@example.com", 2), ("other@example.com", 1)]
