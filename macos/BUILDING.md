# Building cochlea.app locally

> **Status: CI compiles this on macOS 14.** It was written on Linux with no
> Swift toolchain, so every line was unverified until GitHub Actions built it.
> The `macos-app` job in `.github/workflows/ci.yml` is the source of truth for
> whether it currently builds — check it before you start.
>
> It still does not *do* anything: there is no ASR backend, so it cannot
> transcribe. See "Wiring up an ASR backend" below.

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
(push to talk). It will not transcribe: there is no ASR backend.

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

## Wiring up an ASR backend

This is the gap. `Transcriber` is a three-method protocol in
`Sources/CochleaASR/Transcriber.swift`; nothing conforms to it except
`UnavailableTranscriber`, which throws.

The model is decided — Whisper large-v3-turbo, reasoning in
[docs/DECISIONS.md](../docs/DECISIONS.md) — but the runtime is not written.
Three routes:

| Route | Pro | Con |
|---|---|---|
| **mlx-swift** | Matches SPEC §4: one model format for inference *and* training, which is what M5's acoustic LoRA needs | Whisper support in Swift MLX needs checking; may mean porting the Python `mlx-examples` implementation |
| **WhisperKit** | Mature, MIT, Swift-native, works today | CoreML, not MLX — breaks the shared-format rationale, so training needs a second copy of the weights |
| **whisper.cpp** | Fastest to wire up, well-trodden | Same split-format problem, plus a C interop layer |

The spec chose MLX deliberately so M5 does not need two model formats. If you
take WhisperKit to get M0 shipped, record it as a decision and note what it
costs M5 — do not let it become an accident.

`ModelCatalog` carries the descriptor; `ModelResolver` resolves the file list
and digests from HuggingFace. Checksums are **not pinned** — see
[D2](../docs/DECISIONS.md). Run `scripts/pin-model.sh
mlx-community/whisper-large-v3-turbo` on your machine and commit the result;
this repo was built somewhere that could not reach huggingface.co.

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
