# Building cochlea.app locally

> **This has never been compiled.** It was written on Linux with no Swift
> toolchain, no macOS SDK and no Apple Silicon. Assume it does not build until
> you have built it. The Python half is the tested half.

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

## Expected first-build failures, roughly in order

These are my best guesses at what I got wrong, written blind. Ranked by how
likely they are to bite.

1. **`kEventHotKeyReleased` may not fire.** `HotkeyMonitor` assumes
   `RegisterEventHotKey` delivers key-up as well as key-down, which the whole
   push-to-talk interaction depends on. If it does not, switch to an
   `NSEvent.addGlobalMonitorForEvents` flags-changed monitor — but note that
   changes the permission story, since a global monitor sees more.
2. **Actor isolation.** `DictationController` is `@MainActor` and the audio tap
   fires on a real-time thread; every frame currently hops to the main actor
   via `Task { @MainActor in ... }`. Swift 6 strict concurrency will likely
   complain, and the traffic may be too high regardless — the segmenter
   probably belongs off-main with only the finished utterance hopping over.
3. **`AVAudioConverter` input block.** The single-shot `supplied` flag pattern
   is standard, but check behaviour when the input device changes sample rate
   mid-session (AirPods connecting) — the converter is built once in `start()`.
4. **`keyboardSetUnicodeString` chunking.** 16 UTF-16 units per event is
   conservative folklore, not a documented limit. Verify with long utterances
   and non-Latin scripts.
5. **`URLSession.AsyncBytes` throughput.** `ModelDownloader` iterates one byte
   at a time, buffered into 1 MB writes. Over a 1.6 GB model the per-byte
   `await` overhead may be unacceptable. If so, move to
   `URLSessionDownloadTask` with resume data — at the cost of resume no longer
   surviving app restarts.

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
