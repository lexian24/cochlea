# Changelog

Notable changes, newest first. Dates are when the work landed, not when it
was released.

The format is loosely [Keep a Changelog](https://keepachangelog.com/); the
project follows [semantic versioning](https://semver.org/) once it has a
stable interface, which it does not yet.

## Unreleased

Nothing since 0.2.0.

## 0.2.0 — 2026-09-01

The release where it became usable. Before this, the adaptation engine was
built and the app compiled; nobody had dictated a sentence with it.

### Added

- **Dictation works end to end.** Hotkey, microphone, voice detection,
  transcription and typing at the cursor, hand-tested on an M2 at 383–441 ms
  warm against a 1000 ms budget.
- **Streaming output.** Each phrase appears at your cursor when you pause,
  rather than everything at the end. Commits are serialised so segments reach
  the cursor in the order they were spoken (D9, F26).
- **Tap to latch.** Hold the shortcut for push-to-talk, or tap it once and it
  keeps listening until you tap again — one binding, both behaviours (D7).
  A hard cap closes the microphone on a session you walked away from.
- **Rebindable shortcuts**, for dictation and for fix-last, from a Settings
  window reachable from the menu bar.
- **Contextual biasing.** The recogniser is biased towards your own
  vocabulary, measured at about +5% latency for 25 entries and +27% for 400
  (D8). The unit is a token *sequence*, so phrases are boosted in context and
  a single word is the one-element case of the same mechanism (D10).
- **Import your own writing.** `dictate import text <file>` seeds the lexicon
  from a chat export or your notes; `dictate import gitlog` from commit
  history. Both propose without writing until `--commit`. A conversation with
  more than one speaker is refused rather than guessed at (invariant 3).
- **Fix-last.** One shortcut opens what you just dictated, corrects it in your
  document, and files the pair through the revision filter (D11, D13).
- **A correction teaches immediately.** The word the recogniser did not know
  is added to the lexicon and is in force on the next utterance — no training
  involved (D12).
- **The menu bar wears the cochlea mark**, drawn from the same geometry as the
  logo, and inverts for exactly as long as the microphone is open.
- `dictate asr-check`, `dictate lexicon`, `dictate correct`.
- [`docs/PRIVACY.md`](docs/PRIVACY.md), [`CONTRIBUTING.md`](CONTRIBUTING.md),
  [`SECURITY.md`](SECURITY.md), and a hand-test walkthrough in
  [`macos/TESTING.md`](macos/TESTING.md).

### Fixed

Six defects that only a person at a real keyboard could find:

- **The first-run model download could never have succeeded.** The resolver
  read the top-level `oid` — a git blob SHA-1 — instead of `lfs.sha256`, so
  every file failed its checksum as if corrupt (D4).
- **The voice detector never fired.** Its threshold sat below the measured
  noise floor of an ordinary room, so every frame of silence counted as
  speech. Now relative to a measured floor, with a ceiling — without one, a
  user who speaks immediately seeds the estimate with speech and loses the
  utterance.
- **Connecting AirPods hung the whole app.** `AVAudioEngine` held a reference
  to hardware that no longer existed and `start()` blocked the main actor.
- **The last 85 ms of every utterance was discarded.** `installTap`'s
  `bufferSize` is a hint the engine ignores.
- **The microphone opened 2084 ms after key-down**, so the first words were
  spoken into a microphone that was not open.
- **An English sentence transcribed as Malay**, because Whisper detects
  language from a window that had been clipped.

### Changed

- Streaming is the default. It gives up the M4 post-correction pass, which
  does not exist yet, so today the choice costs nothing (D9).
- `whisper-small` is the default model. `large-v3-turbo` misses the latency
  budget on an 8 GB M2 by roughly 2x (D6).
- Latency is measured from the audio being complete, not from the microphone
  opening — the old number included the whole of the user's speech, so no
  utterance longer than a second could pass the budget however fast the model
  was.

### Known limitations

- **The app is built from source.** Shipping a downloadable build needs an
  Apple Developer Program membership so it can be signed and notarized, and
  that recurring cost has been decided against — so there is no cask, and
  there is not going to be one (F22). Compiling it yourself works and always
  will, because a locally built app is never quarantined.
- **Nothing trains a model yet.** The evaluation harness that will gate
  training is built and tested; the trainer is not.
- **The review queue is CLI-only** (`dictate review`).
- **Corrections have no negative signal.** The sidecar reports which biased
  terms won, and nothing reads it yet.
- **Term extraction still proposes words the model already knows** in some
  cases, which is why import shows you everything before keeping it (F25).

## 0.1.0

Initial engine: correction store, revision filter, phonetic backends,
importers, lexicon, evaluation harness with the promotion gate, training
orchestration, retention policy, and app-keyed profiles. No dictation.
