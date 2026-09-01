# Contributing to cochlea

Thank you for looking. This document is short and specific: it covers the
things about this project that will surprise you, not the things every
project shares.

## Read the spec first

[`docs/SPEC.md`](docs/SPEC.md) is the design record. It is not aspirational
documentation — it is a register of **failure modes the design has to
survive**, and most improvements that look obvious are already refuted there
with a reason.

Before proposing a change to how adaptation works, check whether it is
already answered:

| If you are thinking… | See |
|---|---|
| "why not just watch the text field and diff it?" | [§1](docs/SPEC.md#1-decisions-to-lock-before-writing-code) |
| "why not boost every word the user types?" | [F2](docs/SPEC.md#f2--biasing-over-triggers-and-creates-new-errors), [F25](docs/SPEC.md#f25--the-lexicon-fills-with-words-the-model-already-knows) |
| "why not train on every correction?" | [F1](docs/SPEC.md#f1--revision-mistaken-for-correction) |
| "why not stream partial words?" | [F18](docs/SPEC.md#f18--layer-stacking-adds-latency), [D9](docs/DECISIONS.md) |
| "why is the ASR a Python subprocess?" | [D5](docs/DECISIONS.md) |

If the spec did not anticipate what you hit, **register it** as a new failure
mode (F27+) rather than working around it quietly. That register is the most
valuable thing in this repository.

## Invariants

These are in [SPEC §6](docs/SPEC.md#6-invariants). Violating one is a bug
regardless of what the tests say, and a pull request that does will be asked
to change rather than to add a test. The four broken most easily by accident:

1. **No adapter is promoted without passing the eval gate.** Enforced in
   `AdapterRegistry.promote`, which raises rather than trusting its caller.
2. **Holdout data is never trained on.** `store.training_set()` excludes it.
   Do not add a second path that reads utterances for training.
4. **Text-only mode is fully functional.** `pytest` with only `[dev]`
   installed must pass, with the `zh`, `acoustic` and `asr` tests skipping.
   CI enforces this in the `text-only` job.
7. **Acoustic retention is opt-in.** `CorrectionStore(text_only=True)`
   *refuses* features at the boundary rather than omitting them.

## Running things

```sh
pip install -e ".[dev,zh,acoustic]"
pytest -q                    # NOT `python -m pytest`
```

`python -m pytest` prepends the working directory to `sys.path`, which masks
import errors that break a clean checkout. That bug shipped once and CI was
the only thing that caught it.

Speech recognition is Apple Silicon only:

```sh
pip install -e ".[asr]"
dictate asr-check sample.wav --model ~/.cochlea/models/whisper-small
```

Nothing outside `cochlea.asr` may import MLX at module scope. The sidecar
protocol is deliberately testable with a fake backend so CI covers it on
Linux.

## The Swift side

`macos/` builds with SwiftPM and has no dependencies. Two things to know:

- **CI builds with Swift 5.10 on `macos-14`**, which is likely older than
  your toolchain. A SwiftUI change that compiles locally can still fail CI
  with *"unable to type-check this expression in reasonable time"*. The cause
  is almost always a `"..." + "..." + "..."` chain inside a view builder. Use
  one `"""` literal with `\` continuations, and split a `body` that grows past
  a screen into `@ViewBuilder` properties. There is no local reproduction;
  the rule is the check.
- **`swift test` needs full Xcode.** With Command Line Tools only you can
  `swift build` but not run XCTest, so CI is the only place Swift tests
  execute.

## What cannot be tested

The hotkey, the microphone, the injector, and every window need a person at a
real keyboard. [`macos/TESTING.md`](macos/TESTING.md) is that walkthrough,
written so a report is actionable: each test names what should happen and what
to write down when it does not. Six real defects have been found that way and
none of them could have been found any other way.

If you change something in that list, add or update its test.

## Commit messages

They explain **why**, and they record **what was verified versus assumed**.
This is enforced by review, and it is the convention that makes the history
worth reading:

```
Stop discarding the last 85 ms of every utterance

Two presses reported byte-identical sample counts, which should be
impossible for different hold durations. Cause: `installTap`'s `bufferSize`
is a hint the engine ignores -- it delivers 100 ms buffers whatever you ask
for (measured at 512, 1024 and 4096, all identical).

Verified: a 2.00 s hold went from 1.94 s of audio to 2.03 s. Not verified:
behaviour on a device with a different native sample rate.
```

Do not claim something passes without having run it.

## Pull requests

- One concern per pull request.
- CI must be green: `test` on three Pythons, `text-only`, and `macos-app`.
- If you changed a design decision, add a record to
  [`docs/DECISIONS.md`](docs/DECISIONS.md) rather than silently reversing one.

## Things that look wrong but are deliberate

Before "fixing" any of these, read the comment next to them:

- **Digest parsing reads `lfs.sha256`, never the top-level `oid`.** The
  top-level field is a git blob SHA-1; pinning one fails every download as a
  checksum mismatch that reads like file corruption ([D4](docs/DECISIONS.md)).
- **The app refuses to transcribe rather than returning placeholder text.**
  Typing invented words at someone's cursor is worse than typing nothing.
- **Homophony uses explicit tables, not the metaphone key.** Metaphone drops
  non-initial vowels, so `knew` and `no` collide. That was a real bug.
- **A training batch shrinks rather than substituting.** A smaller correct
  batch beats a larger poisoned one ([F3](docs/SPEC.md)).
- **Biasing takes the maximum per token, never the sum.** Summing reached +69
  logits across overlapping entries and the decoder ran away — 298 ms became
  11 seconds ([D8](docs/DECISIONS.md)).

## Security and privacy

Report vulnerabilities privately: see [SECURITY.md](SECURITY.md).

The privacy claims in [`docs/PRIVACY.md`](docs/PRIVACY.md) are meant to be
*checkable*. A change that weakens one — a new network call, a new file
written outside `~/.cochlea`, anything that reads another application's
contents — needs to say so explicitly in the pull request, and will most
likely be declined.
