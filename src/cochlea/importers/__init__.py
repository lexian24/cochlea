"""Importer — ``extract(source) -> Iterable[TextSample]`` (SPEC §4).

Every importer filters to the user's own content *internally*, before yielding.
Invariant 3 is "importers discard other participants' content before writing to
disk" — store-then-filter is explicitly rejected by F8, so the filtering
belongs inside ``extract``, not in the caller.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable, Protocol


@dataclass(frozen=True)
class TextSample:
    text: str
    source: str
    # Provenance for auditing. An importer that cannot prove the sample is the
    # user's own must not yield it.
    own_content: bool = True


class Importer(Protocol):
    name: str

    def extract(self, source: str) -> Iterable[TextSample]: ...


from .gitlog import GitLogImporter  # noqa: E402
from .textfile import TextFileImporter  # noqa: E402

REGISTRY = {imp.name: imp for imp in (GitLogImporter(), TextFileImporter())}


def get(name: str) -> Importer:
    if name not in REGISTRY:
        raise KeyError(f"unknown importer {name!r}; have {sorted(REGISTRY)}")
    return REGISTRY[name]
