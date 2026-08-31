"""Profiles — M6.

F11 decomposes adaptation by what actually varies. The voice does not change
with context, so acoustic adaptation is per-person and shared. Vocabulary and
style do, so lexicon and style are per-profile, keyed on the frontmost
application.

F12 is the asymmetry that shapes the defaults: work jargon leaking into
personal dictation is harmless, personal slang in a work email is
embarrassing. So formality is not symmetric — a formal profile suppresses
informal entries, but a casual profile does not suppress formal ones.
"""

from __future__ import annotations

import fnmatch
from dataclasses import dataclass, field
from typing import Iterable, Optional

from .lexicon import Lexicon


class Formality(str):
    """Marker values for a profile's register."""
    FORMAL = "formal"
    CASUAL = "casual"


#: F12: in a formal context, biasing is applied conservatively.
FORMAL_BOOST_SCALE = 0.5


@dataclass
class Profile:
    name: str
    formality: str = Formality.CASUAL
    #: Bundle-id globs that select this profile, e.g. "com.tinyspeck.slackmacgap".
    app_patterns: list[str] = field(default_factory=list)
    lexicon: Lexicon = field(default_factory=Lexicon)
    #: Terms derived from informal sources; suppressed in formal contexts.
    slang_terms: set[str] = field(default_factory=set)

    @property
    def is_formal(self) -> bool:
        return self.formality == Formality.FORMAL

    def matches(self, bundle_id: Optional[str]) -> bool:
        if bundle_id is None:
            return False
        return any(fnmatch.fnmatch(bundle_id, p) for p in self.app_patterns)

    def add_term(self, term: str, boost: float = 1.5, *, slang: bool = False):
        entry = self.lexicon.add(term, boost)
        if slang:
            self.slang_terms.add(term)
        return entry

    def boost_for(self, term: str) -> float:
        """The boost actually applied, after the F12 formality rules."""
        if self.is_formal and term in self.slang_terms:
            return 1.0                      # slang-derived entries are disabled
        raw = self.lexicon.boost_for(term)
        if self.is_formal and raw > 1.0:
            # Conservative, not off: a formal context still wants the user's
            # colleagues' names and project vocabulary.
            return 1.0 + (raw - 1.0) * FORMAL_BOOST_SCALE
        return raw


class ProfileSet:
    """Selects a profile from the frontmost application.

    Acoustic adaptation is explicitly *not* per-profile: it is one adapter for
    the person, shared across every profile (F11).
    """

    def __init__(self, default: Optional[Profile] = None):
        self.default = default or Profile(name="default")
        self.profiles: list[Profile] = []

    def add(self, profile: Profile) -> Profile:
        if any(p.name == profile.name for p in self.profiles):
            raise ValueError(f"profile {profile.name!r} already exists")
        self.profiles.append(profile)
        return profile

    def remove(self, name: str) -> None:
        self.profiles = [p for p in self.profiles if p.name != name]

    def get(self, name: str) -> Profile:
        for profile in self.profiles:
            if profile.name == name:
                return profile
        if self.default.name == name:
            return self.default
        raise KeyError(f"no profile named {name!r}")

    def select(self, bundle_id: Optional[str]) -> Profile:
        """First match wins; order is the user's precedence."""
        for profile in self.profiles:
            if profile.matches(bundle_id):
                return profile
        return self.default

    def names(self) -> list[str]:
        return [self.default.name] + [p.name for p in self.profiles]
