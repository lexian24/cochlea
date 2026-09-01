"""The `dictate` subcommands the app depends on.

`correct` is the one the fix-last panel calls. Attribution lives in Python
because F1's three-signal heuristic is one rule, and a second implementation
in Swift would be two that have to agree forever.
"""

import json

from cochlea import cli

def test_correct_records_a_correction(tmp_path, capsys):
    home = tmp_path / "home"
    rc = cli.main([
        "--store", str(home / "corrections.db"),
        "correct",
        "--hypothesis", "check the ginks logs",
        "--final", "check the nginx logs",
        "--latency-ms", "1800",
    ])
    assert rc == 0
    assert "correction" in capsys.readouterr().out


def test_correct_quarantines_what_fails_two_signals(tmp_path, capsys):
    # F1: quarantine is for the ambiguous middle, and it must reach the review
    # queue rather than being filed silently either way.
    db = tmp_path / "corrections.db"
    rc = cli.main([
        "--store", str(db), "correct",
        "--hypothesis", "the cat sat on the mat",
        "--final", "the dog ran quickly through",
        "--latency-ms", "2000",
    ])
    assert rc == 0
    assert "adjudication" in capsys.readouterr().out
    assert cli.main(["--store", str(db), "review"]) == 0
    assert "quarantined" in capsys.readouterr().out


def test_correct_files_a_rewrite_as_a_revision(tmp_path, capsys):
    rc = cli.main([
        "--store", str(tmp_path / "corrections.db"), "correct",
        "--hypothesis", "meet me at the cafe",
        "--final", "actually let us reschedule to next week entirely",
        "--latency-ms", "60000",
    ])
    assert rc == 0
    out = capsys.readouterr().out
    assert "revision" in out
    assert "never trained on" in out


def test_correct_emits_json_for_the_app(tmp_path, capsys):
    rc = cli.main([
        "--store", str(tmp_path / "corrections.db"), "correct",
        "--hypothesis", "check the ginks logs",
        "--final", "check the nginx logs",
        "--latency-ms", "1800", "--json",
    ])
    assert rc == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["attribution"] == "correction"
    assert len(payload["id"]) == 32
    assert payload["failed_signals"] == []
