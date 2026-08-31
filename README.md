# cochlea

A macOS dictation app whose model adapts to one person. Local-only, no cloud.
Distributed via Homebrew, aimed at technically comfortable users.

## Status

**Pre-M0. Nothing is implemented yet.** This repository currently contains the
engineering spec and handoff brief only. There is no binary, no Homebrew
formula, and no install path. Do not write install instructions here until M0
actually ships.

## Start here

- [`docs/SPEC.md`](docs/SPEC.md) — the handoff brief: locked decisions, failure
  mode register, personas, architecture, milestone plan with acceptance
  criteria, and invariants.

If you are picking this project up, read the spec end to end before writing
code. In particular, §1 records three decisions that shape the correction store
schema; changing them later means a migration.

## The one-paragraph version

Dictation quality for an individual is limited less by the base ASR model than
by that person's vocabulary, names, code-switching, and orthography. cochlea
captures corrections through explicit user action (never by monitoring text
fields), stores them in a schema-versioned local database, and uses them to
drive three adaptation layers: a lexicon with contextual biasing (instant), a
post-correction LM adapter (nightly), and an acoustic adapter (monthly,
opt-in, default off).

The correction store is the durable asset. Adapters are derived artifacts and
must always be rebuildable from the store alone.

## Invariants

Violating any of these is a bug regardless of test results. Full text in
[§6 of the spec](docs/SPEC.md#6-invariants).

1. No adapter is promoted without passing the eval gate.
2. Holdout data is never trained on.
3. Importers discard other participants' content before writing to disk.
4. Text-only mode is fully functional at every milestone.
5. Adapters are rebuildable from the correction store alone.
6. Training never blocks or degrades dictation.
7. Acoustic retention is opt-in and defaults to off.
8. No permission is requested before the feature that needs it is invoked.
9. No training layer ships before its eval gate exists.

## Licensing

**The project license is not yet chosen.** Until it is, this code carries no
grant and external contribution is blocked. The spec recommends MIT and explains
why in [Appendix B](docs/SPEC.md#decisions-taken-on-the-handoff-read); the choice
is the copyright holder's to make.

Model weights and training corpora carry their own terms, several of which are
not MIT and some of which impose conditions on distributing derived adapters.
Per F23, every shipped artifact's license must be recorded in
`LICENSES-MODELS.md` before anything is distributed. That file does not exist
yet because nothing is distributed yet.
