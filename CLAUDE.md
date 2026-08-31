# Working on cochlea

Local-only macOS dictation that adapts to one person. Read
[docs/SPEC.md](docs/SPEC.md) before making design decisions — it records the
failure modes the design has to survive, and most "obvious" improvements are
already refuted there.

## Layout

- `src/cochlea/` — the adaptation engine, in Python. Tested (137 tests).
- `macos/` — the M0 app, in Swift. Compiles in CI; has never been *run*.
- `docs/DECISIONS.md` — decision records. Add one rather than silently
  reversing a choice.

## Running tests

```sh
pip install -e ".[dev,zh,acoustic]"
pytest -q                 # NOT `python -m pytest`
```

Use `pytest`, not `python -m pytest`. The latter prepends the CWD to
`sys.path`, which masks import errors that break a clean checkout — that bug
shipped once already and CI was the only thing that caught it. If you add a
shared test helper, put it in `tests/helpers.py`; do not import across test
modules.

The optional extras must stay optional: `pytest` with only `[dev]` installed
has to pass, with the `zh` and `acoustic` tests skipping. That is invariant 4
and CI enforces it in the `text-only` job.

## Invariants

Violating any of these is a bug regardless of what the tests say. Full list in
[SPEC §6](docs/SPEC.md#6-invariants). The ones most easily broken by accident:

1. **No adapter is promoted without passing the eval gate.** Enforced in
   `AdapterRegistry.promote`, which raises rather than trusting its caller.
2. **Holdout data is never trained on.** `store.training_set()` excludes it;
   do not add another path that reads utterances for training.
4. **Text-only mode is fully functional.** Never make the acoustic path a
   prerequisite for anything in layers 1 or 2.
7. **Acoustic retention is opt-in.** `CorrectionStore(text_only=True)` refuses
   features at the boundary rather than omitting them. Keep it that way — F7
   makes writing unencrypted audio features the worst available failure.
8. **No permission before the feature that needs it.** Both macOS prompts live
   in `DictationController.beginListening()`. Nothing goes in
   `applicationDidFinishLaunching`.

## Things that look wrong but are deliberate

- **`ModelCatalog.pinnedSHA256` is empty.** See DECISIONS D2. Do not invent a
  digest — a wrong one fails every download as a checksum mismatch that reads
  like file corruption. Run `scripts/pin-model.sh` on a machine with network
  access to huggingface.co and commit the result.
- **The app refuses to transcribe rather than returning placeholder text.**
  Typing invented words at the user's cursor is worse than typing nothing.
- **Homophony and orthographic variants use explicit tables, not the metaphone
  key.** Metaphone drops non-initial vowels, so `knew` and `no` collide. This
  was a real bug; the comment in `lexicon.py` explains it.
- **`batch shrinks rather than substituting`** in `training.py` — a smaller
  correct batch beats a larger poisoned one (F3).

## Current state

- **M0** compiles but has no ASR backend. `Transcriber` is a three-method
  protocol; nothing conforms to it. Start at [macos/BUILDING.md](macos/BUILDING.md).
- **M1–M6** orchestration is built and tested; what is missing in each case
  needs Apple Silicon or a model.
- **Stage 2 (iPhone)** is designed, not started, and deliberately requires no
  schema change: [docs/STAGE2-IPHONE.md](docs/STAGE2-IPHONE.md).

## Conventions

- Match the failure-mode idiom: when you hit something the spec did not
  anticipate, register it (F25+) rather than working around it silently.
- Commit messages explain *why*, and record what was verified versus assumed.
- Do not claim something passes without running it.
