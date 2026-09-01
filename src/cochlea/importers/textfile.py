"""Plain-text importer, for a chat export or anything the user has written.

This is the answer to "how do I give it my own language before I have made a
single correction" for anyone whose writing is not a git history. Every chat
app can export to text, and a text file is the one format that needs no
permission, no database schema and no reverse engineering.

Invariant 3 is the whole difficulty. A chat export is *not* the user's own
content: it is a conversation, and half of it belongs to someone else. F8
rejects store-then-filter, so the filtering happens here, before anything is
yielded — and when this importer cannot tell whose words are whose, it
refuses rather than guessing. Importing the other side of a conversation
would put another person's vocabulary into a model that types at the user's
cursor, which is both a privacy failure and a quality one.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Iterable

from ..privacy import redact
from . import TextSample

#: ``Name: message`` at the start of a line, the shape almost every chat
#: export shares. WhatsApp and Signal put a timestamp in front, so anything
#: up to the last "] " is skipped before looking for the speaker.
_SPEAKER = re.compile(
    r"^(?:\[[^\]]*\]\s*|\d{1,4}[-/]\d{1,2}[-/]\d{1,4},?\s+[\d:apmAPM\s]+[-–]\s*)?"
    r"(?P<who>[^:\n]{1,40}?):\s(?P<text>.*)$"
)

#: A file with fewer speaker-prefixed lines than this is treated as prose the
#: user wrote, not as a conversation. Prose contains colons — "Note: this is
#: fine" — so a handful of matches must not turn a notes file into a
#: transcript with a phantom speaker called "Note".
_CONVERSATION_RATIO = 0.5


class AmbiguousAuthorship(ValueError):
    """The file is a conversation and nobody said which speaker is the user."""

    def __init__(self, speakers: list[tuple[str, int]]):
        self.speakers = speakers
        listed = "\n".join(f"    {n:5} {who}" for who, n in speakers[:10]) or "    (none)"
        super().__init__(
            "this looks like a conversation with more than one speaker, and "
            "importing the other side would put someone else's vocabulary into "
            "your dictation (invariant 3).\n"
            f"  Speakers present:\n{listed}\n"
            "  Pass --author to choose yourself."
        )


class TextFileImporter:
    name = "text"

    def speakers(self, source: str) -> list[tuple[str, int]]:
        """(speaker, line count), most talkative first."""
        counts: dict[str, int] = {}
        for line in self._lines(source):
            if match := _SPEAKER.match(line):
                who = match.group("who").strip()
                counts[who] = counts.get(who, 0) + 1
        return sorted(counts.items(), key=lambda kv: -kv[1])

    def extract(self, source: str, *, author: str | None = None
                ) -> Iterable[TextSample]:
        lines = self._lines(source)
        if not lines:
            raise ValueError(f"{source} has no text in it")

        matched = [m for m in (_SPEAKER.match(line) for line in lines) if m]
        is_conversation = len(matched) >= _CONVERSATION_RATIO * len(lines)

        if not is_conversation:
            # Prose the user wrote: notes, a document, a drafts export. Every
            # line is theirs by construction, because they chose the file.
            for line in lines:
                if text := redact(line.strip()):
                    yield TextSample(text=text, source=f"text:{source}",
                                     own_content=True)
            return

        speakers = self.speakers(source)
        if author is None:
            if len(speakers) > 1:
                raise AmbiguousAuthorship(speakers)
            # One speaker throughout is a monologue -- a notes app that stamps
            # every entry, or a channel only the user posts in.
            author = speakers[0][0]

        wanted = author.strip().lower()
        found = False
        for match in matched:
            if match.group("who").strip().lower() != wanted:
                continue                    # never yielded, so never written
            found = True
            if text := redact(match.group("text").strip()):
                yield TextSample(text=text, source=f"text:{source}",
                                 own_content=True)
        if not found:
            raise AmbiguousAuthorship(speakers)

    @staticmethod
    def _lines(source: str) -> list[str]:
        path = Path(source)
        try:
            raw = path.read_text(errors="replace")
        except OSError as exc:
            raise ValueError(f"could not read {source}: {exc}") from exc
        return [line for line in raw.splitlines() if line.strip()]
