"""`git log --author` importer.

The user's own commit messages. This is the P2 happy path: a monolingual
developer imports their git history and the lexicon fills with the project's
real vocabulary — library names, tools, colleagues' names in co-author trailers
— before they have made a single correction.

Filtering to the user is done by git itself via ``--author``, which satisfies
invariant 3 structurally: other people's commits are never read, not read and
then dropped.
"""

from __future__ import annotations

import subprocess
from typing import Iterable

from ..privacy import redact
from . import TextSample


class NoCommitsMatched(ValueError):
    """The author filter matched nothing. Almost always a wrong address."""

    def __init__(self, author: str, candidates: list[tuple[str, int]]):
        self.author, self.candidates = author, candidates
        listed = "\n".join(f"    {n:5} {a}" for a, n in candidates[:10]) or "    (none)"
        super().__init__(
            f"no commits by {author!r} in this repository.\n"
            f"  Authors present:\n{listed}\n"
            f"  Pass --author to choose one."
        )


class GitLogImporter:
    name = "gitlog"

    def authors(self, source: str) -> list[tuple[str, int]]:
        """(email, commit count) for every author, most prolific first.

        Used only to make a zero-match import explainable; no message bodies are
        read, so this does not touch other people's content.
        """
        proc = subprocess.run(
            ["git", "-C", source, "log", "--pretty=format:%ae"],
            capture_output=True, text=True, check=True,
        )
        counts: dict[str, int] = {}
        for line in proc.stdout.splitlines():
            if line.strip():
                counts[line.strip()] = counts.get(line.strip(), 0) + 1
        return sorted(counts.items(), key=lambda kv: -kv[1])

    def extract(
        self, source: str, *, author: str | None = None, limit: int = 5000
    ) -> Iterable[TextSample]:
        if author is None:
            author = subprocess.run(
                ["git", "-C", source, "config", "user.email"],
                capture_output=True, text=True, check=False,
            ).stdout.strip()
            if not author:
                raise ValueError(
                    "no author given and git config user.email is unset; "
                    "refusing to import every contributor's commits (invariant 3)"
                )
        proc = subprocess.run(
            ["git", "-C", source, "log", f"--author={author}",
             f"--max-count={limit}", "--pretty=format:%s%n%b%x00"],
            capture_output=True, text=True, check=True,
        )
        if not proc.stdout.strip():
            raise NoCommitsMatched(author, self.authors(source))
        for chunk in proc.stdout.split("\x00"):
            text = redact(chunk.strip())
            if text:
                yield TextSample(text=text, source=f"gitlog:{source}", own_content=True)
