# Building cochlea.app locally

> **Status: it builds, and it transcribes.** Written on Linux with no Swift
> toolchain, first compiled by CI, and since built and run on an Apple M2
> (macOS 26, Swift 6.2.3). The `macos-app` job in `.github/workflows/ci.yml`
> is the source of truth for whether it currently builds.
>
> Speech recognition runs in a Python child process ([D5](../docs/DECISIONS.md)),
> verified end to end at 655–661 ms per utterance. What has *not* been
> exercised is everything needing a human: the hotkey, the microphone and the
> injector. See "Still unverified" below — that list is the honest state.

## First run

```sh
git pull
cd macos && swift build          # expect errors; see below
```

When it builds:

```sh
python3 Tools/make_logo.py       # regenerate SVGs (only if you changed the mark)
Tools/make-icns.sh               # SVG -> cochlea.icns   (needs librsvg)
Tools/build-app.sh               # -> build/cochlea.app
xattr -dr com.apple.quarantine build/cochlea.app
open build/cochlea.app
```

It appears in the menu bar with no Dock icon. The hotkey is **Control-Option-D**
(push to talk).

To transcribe it needs the `dictate` helper and a model. Both are checked at
launch, and a missing one is reported when you first press the hotkey rather
than at startup:

```sh
pip install -e '.[asr]'                     # Apple Silicon only
export COCHLEA_DICTATE=$(which dictate)     # if not installed via Homebrew
dictate asr-check some-16k-mono.wav --model ~/.cochlea/models/whisper-small
```

## What the first real compile found

The Swift was written blind, so this section used to be five guesses. CI has
since actually built it on macOS 14 (Swift 5.10, arm64), so here is what
happened instead.

**23 of 25 compile steps passed on the first attempt.** `CochleaCore`,
`CochleaASR`, `CochleaInput` and `CochleaAudio` all built clean — including
`AudioCapture`'s `AVAudioConverter` block, the Carbon `HotkeyMonitor`, the
`CGEvent` `TextInjector`, and the resumable downloader.

**One error, since fixed:**

```
CochleaApp/main.swift:66:16: error: call to main actor-isolated initializer
'init()' in a synchronous nonisolated context
```

Top-level code in `main.swift` is nonisolated in Swift 5.10, so constructing a
`@MainActor AppDelegate` there is an isolation error. The file is now
`CochleaMain.swift` with an `@main @MainActor enum` — which also fixes a bug
the compiler did not catch: `NSApplication.delegate` is *weak*, so a local
`delegate` would have been deallocated immediately. It is a `static let` now.

### Still unverified — the compiler cannot check these

Compiling is not running. These need a real Mac, a microphone and your hands:

1. **`kEventHotKeyReleased` delivery.** `HotkeyMonitor` assumes
   `RegisterEventHotKey` reports key-up as well as key-down, which push-to-talk
   depends on entirely. It compiles; whether it fires is a runtime question.
   Fallback is an `NSEvent` global monitor, which changes the permission story.
2. **`AVAudioConverter` on device change.** The converter is built once in
   `start()`. Check what happens when AirPods connect mid-session and the input
   sample rate changes.
3. **`keyboardSetUnicodeString` chunking.** 16 UTF-16 units per event is
   conservative folklore, not a documented limit. Test long utterances and
   non-Latin scripts.
4. **Main-actor traffic.** Every audio frame hops to the main actor via
   `Task { @MainActor in ... }`. It compiles under Swift 5.10; it may be too
   much traffic in practice, and Swift 6 strict concurrency will likely object.
   The segmenter probably belongs off-main.
5. **`URLSession.AsyncBytes` throughput.** The downloader iterates one byte at
   a time into 1 MB writes. Over 1.6 GB the per-byte `await` overhead may be
   unacceptable — profile before assuming it is fine.

## The ASR backend

This used to be the gap. It is now `SidecarTranscriber`, which conforms to
`Transcriber` by talking to a Python child process over pipes
([D5](../docs/DECISIONS.md)).

The three routes this section used to list were mlx-swift, WhisperKit and
whisper.cpp, with SPEC §4's shared-format argument favouring the first. Two
facts settled it differently:

- **There is no Whisper for Swift MLX.** `mlx-swift-examples/Libraries` holds
  MLXMNIST and StableDiffusion. That route means porting the encoder, decoder,
  mel frontend and tokenizer before anything transcribes.
- **`mlx-tune`, the trainer SPEC §4 names, is Python.** M5 trains in Python
  whichever way M0 goes, so "one format for inference and training" was never
  an argument for putting *inference* in Swift.

The deciding argument is M2 rather than M5: biasing adjusts token scores inside
the decode loop, and the lexicon is `cochlea.lexicon`. A Swift runtime puts a
language boundary between them, crossed once per token.

The pipe costs **0–1 ms** per utterance, because push-to-talk sends one message
per utterance rather than per frame.

```
Swift            hotkey → AudioCapture → VAD → [pipe] → TextInjector
Python (dictate asr-serve)    mlx-whisper decode loop ← lexicon biasing (M2)
```

If you replace this with an in-process Swift runtime, record it as a decision
and say what it costs M2 — do not let it become an accident.

`ModelCatalog` carries the descriptor; `ModelResolver` resolves the file list
and digests from HuggingFace. Both catalogued models are **pinned**, and the
resolve-and-verify path has been run against the live provider — see
[D4](../docs/DECISIONS.md), which also records the bug that made first-run
download impossible until it was run somewhere with network access. Adding a
model means running `scripts/pin-model.sh <repo-id>` for it.

## Before it ships to anyone

**F22, signing and notarization.** An unsigned app requesting Accessibility and
Microphone is blocked by Gatekeeper. This needs an Apple Developer Program
membership and a notarization step in CI. Until then `xattr -dr` is a developer
workaround, not something to put in a README for users.

Then `Casks/cochlea.rb` becomes real and `brew install --cask cochlea` works.

## Invariants this target must not break

- **8 — no permission before the feature.** Both prompts are in
  `beginListening()`. Nothing is requested in `applicationDidFinishLaunching`.
- **7 — acoustic retention is opt-in.** M0 stores no audio at all.
- **6 — training never blocks dictation.** M0 has no training. Keep the trained
  layers behind the `Transcriber` seam, not in the capture path.
