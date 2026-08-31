"""Shared test doubles.

Lives in its own module rather than being imported across test files. An
earlier version did `from tests.test_evaluation import ...`, which works only
when the repository root happens to be on sys.path — true under
`python -m pytest` (which prepends the CWD) and false under the `pytest`
console script. The suite therefore passed locally and failed to collect at all
in CI. pytest puts this file's directory on sys.path for test modules that are
not in a package, so `from helpers import ...` works under both.
"""

from cochlea.store import CORRECTION, UNEDITED, CorrectionStore, Utterance


class PerfectTranscriber:
    """Returns exactly what the user meant."""

    def __init__(self, store):
        self.by_id = {r["id"]: (r["final_text"] or r["hypothesis"]) for r in store.all()}
        self.seen = []

    def transcribe(self, utterance_id, hypothesis):
        self.seen.append(utterance_id)
        return self.by_id[utterance_id]


class CorruptTranscriber:
    """A deliberately corrupted adapter: it mangles everything."""

    def __init__(self):
        self.seen = []

    def transcribe(self, utterance_id, hypothesis):
        self.seen.append(utterance_id)
        return "zzz " * max(len(hypothesis.split()), 1)


def populate(store, n=40):
    """A store of straightforward corrections."""
    ids = []
    for i in range(n):
        ids.append(store.add(Utterance(
            hypothesis=f"deploy service number {i} to the cluster",
            final_text=f"deploy service number {i} to the kubectl cluster",
            base_model_id="whisper-turbo", attribution=CORRECTION)))
    return ids


def seed(store, corrections=40, accepted=40):
    """A store mixing corrections with accepted-as-correct utterances (F3)."""
    for i in range(corrections):
        store.add(Utterance(hypothesis=f"cube cuddle {i} get pods",
                            final_text=f"kubectl {i} get pods",
                            base_model_id="m", attribution=CORRECTION))
    for i in range(accepted):
        store.add(Utterance(hypothesis=f"the build number {i} is green",
                            base_model_id="m", attribution=UNEDITED))
    return store
