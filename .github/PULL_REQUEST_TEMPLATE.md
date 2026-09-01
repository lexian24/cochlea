## What and why

<!-- The problem, then the change. Why this way rather than the obvious way. -->

## Verified

<!-- What you actually ran, and what it printed. Separate this from what you
     are assuming. "Verified: 232 Python tests, and the transcript changed from
     X to Y on my M2. Not verified: behaviour on Intel." -->

## Checklist

- [ ] `pytest -q` passes (not `python -m pytest` — it masks import errors)
- [ ] `pytest -q` passes with only `[dev]` installed, with `zh`/`acoustic`/`asr` tests skipping (invariant 4)
- [ ] `swift build --package-path macos` is clean, if Swift changed
- [ ] No `"..." + "..."` string chains inside a SwiftUI view builder (CI's Swift 5.10 rejects them)
- [ ] A design decision changed → a record added to `docs/DECISIONS.md`
- [ ] Something the spec did not anticipate → registered as a failure mode in `docs/SPEC.md`
- [ ] Behaviour only a person can check → a test added to `macos/TESTING.md`
