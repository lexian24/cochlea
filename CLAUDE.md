# Working on cochlea

Local-only macOS dictation that adapts to one person. Read
[docs/SPEC.md](docs/SPEC.md) before making design decisions — it records the
failure modes the design has to survive, and most "obvious" improvements are
already refuted there.

## Layout

- `src/cochlea/` — the adaptation engine and the ASR sidecar, in Python.
  Tested (221 tests).
- `macos/` — the M0 app, in Swift. Builds in CI; the ASR path has been run,
  the capture path has not.
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
has to pass, with the `zh`, `acoustic` and `asr` tests skipping. That is
invariant 4 and CI enforces it in the `text-only` job. `asr` matters most here,
because MLX has no wheel outside Apple Silicon — nothing outside
`cochlea.asr` may import it at module scope, and the sidecar protocol is
deliberately testable with a fake backend so CI covers it on Linux.

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

- **Digest parsing reads `lfs.sha256`, never the top-level `oid`.** See
  DECISIONS D4. The top-level field is a git blob SHA-1 and pinning one fails
  every download as a checksum mismatch that reads like file corruption; the
  64-hex-character width check is what prevents it. Adding a model to
  `ModelCatalog` means running `scripts/pin-model.sh <repo-id>` for it — an
  unpinned model cannot install, because its non-LFS `config.json` has no
  digest any provider endpoint will give you.
- **The app refuses to transcribe rather than returning placeholder text.**
  Typing invented words at the user's cursor is worse than typing nothing.
- **Homophony and orthographic variants use explicit tables, not the metaphone
  key.** Metaphone drops non-initial vowels, so `knew` and `no` collide. This
  was a real bug; the comment in `lexicon.py` explains it.
- **`batch shrinks rather than substituting`** in `training.py` — a smaller
  correct batch beats a larger poisoned one (F3).

## Current state

- **M0** transcribes. `SidecarTranscriber` conforms to `Transcriber` by talking
  to a Python child process over pipes (DECISIONS D5); ASR itself is
  `mlx-whisper`, in the `asr` extra. Verified end to end at 655–661 ms per
  utterance with `whisper-small`. Untested: everything needing a human — the
  hotkey, the microphone, the injector. See [macos/BUILDING.md](macos/BUILDING.md).
- **M1–M6** orchestration is built and tested; what is missing in each case
  needs a trainer or a model.
- **Stage 2 (iPhone)** is designed, not started, and deliberately requires no
  schema change: [docs/STAGE2-IPHONE.md](docs/STAGE2-IPHONE.md).

## Running the ASR path

```sh
pip install -e ".[dev,zh,acoustic,asr]"    # asr is Apple Silicon only
dictate asr-check utterance.wav --model ~/.cochlea/models/whisper-small
```

`asr-check` is the M0 benchmark SPEC §7 asked for: it reports cold and warm
separately, because F19 makes them separate acceptance numbers, and prints
whether the warm median meets the 1s budget. Numbers from one M2 are in
DECISIONS D6 — `large-v3-turbo` misses the budget there and `whisper-small`
meets it, which is measured on one machine and not yet a reason to change D1.

## The CI toolchain is two versions behind this machine

`swift build` here is Swift 6.2; the `macos-app` job builds on `macos-14` with
**Swift 5.10**, matching `Package.swift`'s `swift-tools-version: 5.9`. That is
deliberate — a Homebrew user on an older macOS gets the old compiler — but it
means a SwiftUI change that builds cleanly here can still fail CI, and the
failure is always the same one:

```
error: the compiler is unable to type-check this expression in reasonable time
```

The cause is almost always a **`"..." + "..." + "..."` chain inside a view
builder**. `+` has many overloads and the 5.10 solver considers them
combinatorially with everything else in the body. Two rules avoid it:

- Long UI strings are one `"""` literal with `\` line continuations, never a
  `+` chain. Outside a view builder, where there is a declared return type, a
  chain is fine.
- A `body` that grows past a screen gets split into `@ViewBuilder` computed
  properties.

Neither `-warn-long-expression-type-checking` nor `-solver-scope-threshold`
reproduces it on 6.2 — both report nothing on a body 5.10 refuses. There is no
local check; the rules are the check.

## Conventions

- Match the failure-mode idiom: when you hit something the spec did not
  anticipate, register it (F25+) rather than working around it silently.
- Commit messages explain *why*, and record what was verified versus assumed.
- Do not claim something passes without running it.
