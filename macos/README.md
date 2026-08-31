# cochlea — macOS app (M0)

> ## Builds, but has never been run.
>
> Written on Linux with no Swift toolchain — every line was unverified until CI
> built it. It **builds on macOS 14 (Swift 5.10) and on macOS 26 (Swift 6.2.3,
> M2)**, checked by the `macos-app` job.
>
> It transcribes: `SidecarTranscriber` drives a Python `mlx-whisper` process
> ([D5](../docs/DECISIONS.md)), run end to end at 655–661 ms per utterance.
>
> Compiling is still not running, and neither is that. Nothing here has been
> exercised with a real microphone, a real hotkey press, or Accessibility
> permission granted — the three things between a working recogniser and a
> working dictation app. See [BUILDING.md](BUILDING.md).

## What this is

M0 from [the spec](../docs/SPEC.md#5-milestones): a dictation app with no
learning at all. Hotkey → capture → VAD → ASR → text at your cursor, plus a
menu bar presence and a checksum-verified first-run model download.

There is deliberately **no** correction capture, lexicon, or training here.
That is what the spec asks for, and F24 is the reason: if M0 is not competitive
on its own, nothing downstream gets a chance.

## Layout

| Target | Contains |
|---|---|
| `CochleaCore` | Configuration, model catalog, resumable checksum-verified downloader, latency recorder. Foundation only. |
| `CochleaAudio` | `AVAudioEngine` capture converted to 16 kHz mono, energy VAD, utterance segmenter. |
| `CochleaASR` | The `Transcriber` protocol and a refusing default. No model backend. |
| `CochleaInput` | Carbon global hotkey, Accessibility permission, `CGEvent` type-at-cursor. |
| `CochleaApp` | Menu bar item, orchestration, entry point. |

```sh
cd macos
swift build
swift test          # CochleaCoreTests only; the rest needs a mic and a model
```

**Building the actual `.app`, and what to expect on first compile:
[BUILDING.md](BUILDING.md).**

## Deliberate gaps, not oversights

- **`ModelCatalog.known` is empty.** SPEC §7 leaves the default base model open
  pending an M0 benchmark of Whisper turbo against SenseVoice-Small, and F23
  requires a licence audit before any weight is distributed. Publishing a URL
  and checksum here would invent both answers. The downloader is written and
  ready; it has nothing to fetch.
- **No ASR backend.** `Transcriber` is a protocol and the shipped
  implementation throws. That choice is what keeps the benchmark above possible
  without rewriting the capture path — SenseVoice is non-autoregressive, which
  changes the biasing implementation, so committing early would be expensive.
  Until a backend exists the app **refuses to transcribe rather than inventing
  text**: typing invented words at someone's cursor is worse than typing
  nothing.
- **`postProcess` is identity.** The post-correction LM is M4. It is gated on
  `Mode.allowsPostCorrection` already, so F18 holds when it arrives.

## Things I would check first on a Mac

Written blind, so these are the places I would expect to be wrong:

1. **Hotkey release events.** `RegisterEventHotKey` delivering
   `kEventHotKeyReleased` reliably for push-to-talk is the assumption the whole
   interaction rests on. If it does not, the fallback is an `NSEvent` global
   monitor, which needs a different permission story.
2. **Downloader throughput.** `URLSession.AsyncBytes` iterates one byte at a
   time. It is buffered into 1 MB writes here, but the per-byte `await`
   overhead across a 1.6 GB model may be unacceptable. Profile it; if so, move
   to `URLSessionDownloadTask` with resume data, at the cost of resume no
   longer surviving app restarts.
3. **`keyboardSetUnicodeString` chunking.** 16 UTF-16 units per event is
   conservative folklore, not a documented limit. Verify against long
   utterances and non-Latin scripts.
4. **Audio format conversion.** The `AVAudioConverter` input block returns each
   buffer once; check behaviour when the input device changes sample rate
   mid-session (AirPods connecting).
5. **Actor hops.** `DictationController` is `@MainActor` and the audio tap fires
   on a real-time thread. Every frame currently hops to the main actor, which
   may be too much traffic; the segmenter may belong off-main.

## Before this ships

- **F22, signing and notarization.** An unsigned app requesting Accessibility
  and Microphone access is blocked by Gatekeeper. The spec requires this
  resolved *before* M0 ships. It costs an Apple Developer Program membership
  plus notarization setup, and it is a hard blocker for distributing a `.app`.
- **Distribution.** A `.app` goes through a Homebrew **cask**, not the formula
  in `../Formula` — that formula packages the Python CLI. See
  [docs/RELEASING.md](../docs/RELEASING.md).
- **Permission copy.** `AccessibilityPermission.explanation` is the text the
  user reads before granting the scariest permission the app asks for. Per F9's
  reasoning it should be reviewed by someone other than its author.

## Invariants this target must not break

- **8 — no permission is requested before the feature that needs it.** Both the
  microphone and Accessibility prompts are in `beginListening()`, on the first
  hotkey press. Nothing is requested in `applicationDidFinishLaunching`.
- **7 — acoustic retention is opt-in.** `Configuration.acousticRetentionEnabled`
  defaults to `false`. M0 stores no audio at all.
- **6 — training never blocks dictation.** M0 has no training. Keep it that way:
  the trained layers belong behind the `Transcriber` seam, not in this path.
