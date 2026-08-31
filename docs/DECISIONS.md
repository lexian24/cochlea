# Decision record

## D1 — Default base model: Whisper large-v3-turbo

**Status:** decided. Resolves the first open question in
[SPEC §7](SPEC.md#7-open-questions).

**Context.** The spec left the default open between Whisper turbo ("the safe
pick") and SenseVoice-Small ("faster and stronger on Mandarin/Cantonese/English
but non-autoregressive, which changes the biasing implementation"), and asked
for a benchmark at M0.

**Decision.** Whisper large-v3-turbo.

**Why, given the benchmark has not been run.** The benchmark would decide
accuracy and speed. Three things decide the architecture, and they do not need
it:

1. **Biasing is layer 1, and it is the layer that pays off first.** Contextual
   biasing works by adjusting token scores during autoregressive decoding.
   SenseVoice is non-autoregressive, so there is no decode loop to bias — the
   whole of M2, the instant-feedback layer that makes the product feel alive on
   day one, would need a different mechanism that nobody has designed yet.
   Choosing SenseVoice means choosing to redesign M2 before shipping it.
2. **P2 is the largest realistic audience and does not benefit.**
   SenseVoice's advantage is Mandarin and Cantonese. The monolingual developer
   is the majority, is the most likely contributor, and gains nothing from it —
   while paying for it in a redesigned biasing layer.
3. **Whisper is MIT.** SenseVoice's terms are not, and F23 requires a licence
   audit before distributing anything. Whisper removes that blocker entirely
   for the default install; SenseVoice keeps it on the critical path.

**What this costs.** P1, the code-switching maintainer, gets the weaker
day-one experience — the spec already says this is the weakest persona journey.
Whisper commits to one language token per window, so mid-utterance switching
stays structurally hard. The mitigations remain what §3 says: a documented
decoding configuration for mixed input, and honest expectations in the README.

**What would reverse this.** If the M0 benchmark shows SenseVoice materially
better on the maintainer's own zh-en usage *and* someone designs a biasing
mechanism for a non-autoregressive model, revisit. The `Transcriber` protocol
exists so that reversal is a new conformance, not a rewrite.

**Variant.** `large-v3-turbo` rather than `large-v3`: roughly the same encoder
with a much smaller decoder, which is where autoregressive decode time goes.
F18's sub-1s budget is the binding constraint, and turbo is the variant that
meets it. Note it inherits large-v3's **128 mel bins**, not the 80 of earlier
Whisper variants — which matters for §1.2, since stored mel features are bound
to the model that produced them.

---

## D2 — Model checksums are resolved, not hardcoded (for now)

**Status:** superseded by [D4](#d4--the-provider-digests-are-pinned-and-the-resolver-that-read-them-was-broken).
The digests are now pinned, and the resolved-mode fallback this record
describes was found to have never worked. Kept for the reasoning, which
still holds; read D4 for what is true now.

**Context.** F21 requires first-run model download with checksum verification.
A checksum must be *known* to be pinned, and the environment this was built in
cannot reach huggingface.co (blocked by network policy), so the real digest for
the chosen model could not be obtained.

**Decision.** `ModelDescriptor.pinnedSHA256` is optional. When present the
download is verified against it. When absent, the app resolves the digest from
the provider's API (HuggingFace returns the SHA-256 of each LFS blob) over
TLS, then verifies the downloaded bytes against that.

**The weakness, stated plainly.** Resolved mode is trust-on-first-use: whoever
controls the API controls both the file and the digest it is checked against.
A pinned digest is strictly stronger because it is verified against a value
committed to this repository and reviewable in a diff.

**Consequence.** Pinning is required before distribution. Whoever cuts the
first release that ships a model must run
`scripts/pin-model.sh <repo-id>` on a machine that can reach the provider, and
commit the result. Until then the app warns on every unpinned download rather
than staying quiet about a weaker guarantee.

**Rejected alternative.** Inventing a plausible-looking digest to fill the
field. It would make every download fail as a checksum mismatch that reads like
file corruption, and it would turn F21's guarantee into a lie that looks like a
feature.

---

## D3 — iPhone is a read-only extension; sync is one-way

**Status:** decided. Design in [STAGE2-IPHONE.md](STAGE2-IPHONE.md). Not built,
and not to be started until stage 1 — a working Mac app — is done.

**Context.** Most of the maintainer's dictation happens on iPhone, which raised
whether cochlea should be a phone tool that trains on a Mac, or a Mac tool that
extends to a phone.

**Decision.** A Mac tool. The Mac captures corrections, trains, and owns the
lexicon. The iPhone receives a read-only lexicon snapshot and uses it to fix the
output of Apple's own keyboard dictation. Nothing flows back from the phone.

**Why one-way rather than the seemingly better bidirectional.** A phone that
contributes corrections sounds strictly better and is not. Making the Mac the
only writer removes three problems at once: conflict resolution between two
writers of the same store; a holdout that would have to span devices or let
invariant 2 quietly lapse; and a post-correction adapter fitted to two
different engines' error distributions at once. §1.3's claim that text pairs
are base-model-agnostic is about portability, not about error distribution —
one-way means that distinction never has to be resolved.

**What it costs.** Corrections made on the phone are applied and then
forgotten. Given that the Mac already collects a better correction signal —
with acoustic evidence and a fix-last panel — this is a small loss for a large
simplification.

**Consequence: no schema change.** An earlier draft of this recommended adding
`device_id` and a cross-device holdout flag as cheap insurance against a
bidirectional future. Under D3 neither is needed and neither should be added.
The correction store stays as it is.

**What would reverse this.** Evidence that phone-side corrections are both
frequent and materially better than what the Mac captures. That is measurable
once stage 1 reports a real corrections-per-100-words figure (M1), so the
question can be answered with data rather than intuition.

---

## D4 — The provider digests are pinned, and the resolver that read them was broken

**Status:** decided. Supersedes the "for now" in [D2](#d2--model-checksums-are-resolved-not-hardcoded-for-now).

**Context.** D2 left `pinnedSHA256` empty because the environment the app was
written in could not reach huggingface.co, and recorded that pinning was
required before distributing a build that downloads weights. This was done on
a machine with access. Doing it surfaced a defect that no amount of reading
would have found.

**What was broken.** `ModelResolver.resolve` read the digest from
`entry["lfs"]["oid"]`. The `?blobs=true` endpoint it calls does not use that
key — it publishes the digest as `lfs.sha256`. So `resolvedDigest` was `nil`
for every file, and with `pinnedSHA256` also empty, every `RemoteFile` carried
`sha256: nil`. `ModelDownloader.ensureAvailable` refuses a file with no digest
(`noDigestAvailable`, correctly — F21 says do not install unverified weights),
and it checks that first, before downloading anything.

The consequence is worth stating plainly: **the first-run model download could
never have succeeded.** Not "was weaker than pinned mode" — it threw on the
first file, every time. D2 described resolved mode as trust-on-first-use, which
implied it worked and was merely weaker. It did not work at all. The same bug
sat in `scripts/pin-model.sh`, which is why the script that would have revealed
it reported "no files with digests found" instead.

Both were unreachable without network access, and both were invisible to CI,
which compiles but does not resolve.

**Decision.**

1. `ModelResolver.providerDigest(from:)` accepts `lfs.sha256` *or* `lfs.oid`.
   The two HuggingFace endpoints spell the same value differently — the model
   endpoint uses `sha256`, `paths-info` uses `oid` — and accepting both means a
   change of endpoint is not a silent loss of verification.
2. The **top-level** `oid` is never consulted, and a width check enforces it.
   For a file git stores directly that field is the blob SHA-1: 40 hex
   characters, not a digest of the contents. Reading it would fail every
   download as a checksum mismatch that reads like file corruption — precisely
   the outcome D2 refused to ship a fabricated digest for. Rejecting it is a
   64-hex-character check, not a special case.
3. Digests are normalised to lowercase on both sides, because
   `ModelDownloader` formats its computed hash with `%02x` and an uppercase
   expectation would mismatch a byte-identical file.
4. Both catalogued models are pinned, weights and `config.json`.

**On `config.json`, which is the part that is not clean.** No HuggingFace
endpoint publishes a SHA-256 for a file that is not LFS-tracked, and
`config.json` is not LFS-tracked in any mlx-community Whisper repo. `paths-info`
offers only the git blob SHA-1. So `scripts/pin-model.sh` fetches those files
and hashes them locally.

That origin is trust-on-first-use — the same weakness D2 named. What changes is
not the fetch but the destination: the digest lands in a diff, gets reviewed,
and is thereafter verified against a committed value rather than against
whatever the API says today. That is the whole of what pinning buys, and it is
worth being exact that it does not retroactively authenticate the first fetch.

A second consequence follows and should not be lost: an **unpinned** model still
cannot be installed, because its `config.json` will resolve to a nil digest and
the downloader will refuse it. That is the correct behaviour under F21 and it is
now the *only* behaviour. Adding a model to `ModelCatalog` therefore means
running `scripts/pin-model.sh` for it — a test asserts every catalogued model is
pinned, so this fails loudly rather than at a user's first run.

**Verified, not assumed.** Resolution and download were executed against
huggingface.co on Apple Silicon: both models resolve with a digest on every
file; `config.json` downloads and matches its pinned digest; and a deliberately
wrong digest is rejected with the download discarded. The weights themselves
were not downloaded — 1.6 GB — so the resumable large-file path and its `Range`
handling remain unexercised.

**What would reverse this.** Nothing about the key names, which are observed
behaviour. If HuggingFace begins publishing content digests for non-LFS files,
`config.json` could be resolved rather than pinned, and the local-hashing branch
of `pin-model.sh` could go.

---

## D5 — ASR runs in Python, in a process the app spawns

**Status:** decided. Implements M0's transcription path.
[macos/BUILDING.md](../macos/BUILDING.md) offered three routes; this is a
fourth, and the reason it was not on the list is a fact about the ecosystem
that only checking turned up.

**Context.** `Transcriber` is a three-method protocol that nothing conformed
to, so nothing in this repository transcribed audio. BUILDING.md framed the
choice as mlx-swift versus WhisperKit versus whisper.cpp, with SPEC §4's
"one model format for inference *and* training" favouring mlx-swift.

**What checking found.**

1. **There is no Whisper for Swift MLX.** `mlx-swift-examples/Libraries`
   contains MLXMNIST and StableDiffusion. Taking that route means porting the
   encoder, decoder, mel frontend and a 51866-token tokenizer from the Python
   implementation before anything transcribes at all.
2. **`mlx-tune`, the trainer SPEC §4 names, is Python.** So M5 trains in
   Python whichever way M0 goes. The Swift side was never going to train, which
   means "one format for inference and training" was never an argument for
   putting *inference* in Swift — only for keeping it on MLX.

**Decision.** Inference runs in Python, in a child process the app spawns and
talks to over pipes. Swift keeps what it is uniquely able to do — the hotkey,
audio capture, and typing at the cursor — and `SidecarTranscriber` conforms to
the existing `Transcriber` protocol, so `DictationController` is unchanged.

**Why, and the reason is M2 rather than M5.** Contextual biasing adjusts token
scores inside the decode loop. The lexicon those scores come from is
`cochlea.lexicon`, in Python. Every Swift route puts a language boundary
between the decode loop and the lexicon, and that boundary is crossed once per
token. D1 calls biasing "the layer that pays off first" and the reason for
preferring Whisper over SenseVoice at all; putting it out of reach to gain a
Swift-native runtime would be paying for the decision twice.

The M5 argument survives too, and more cleanly than the alternatives: the
adapter `mlx-tune` produces is loaded by the same MLX runtime that serves
inference, with no conversion step between them.

**Why a child process rather than a socket.** A socket needs a port or a path,
a permission story, a cleanup story for when the app is killed, and an answer
for a second instance. A pipe to a child has none of those, and the kernel
closes it when either side dies.

**Why this costs less than it looks.** Measured on an M2: **0–1 ms** of the
round trip is the pipe. Latency is the whole objection to a sidecar, and it is
0.1% of M0's one-second budget. The reason it is so small is that push-to-talk
sends one message per utterance, not per frame — the audio is already buffered
in Swift when the hotkey is released.

**What it costs, stated plainly.**

- **A second runtime to install.** Mitigated by the fact that the Homebrew
  formula already installs a Python virtualenv with `dictate` in it; this adds
  a dependency to an existing mechanism rather than introducing one. The app
  looks for `dictate` at Homebrew's two prefixes and honours `COCHLEA_DICTATE`.
  It deliberately does not consult `PATH`: a GUI app launched from Finder does
  not inherit the shell's, so trusting it would work from a terminal and fail
  on double-click.
- **A protocol to keep compatible.** Versioned, and the app refuses a mismatch
  with a message naming which side is older.
- **Two failure modes instead of one** — a missing helper and a missing model.
  They are reported separately because their fixes differ.
- **Process lifecycle.** The child is respawned if it dies. A backend error on
  one utterance does not kill it, because the loaded model is the expensive
  thing to lose.

**What would reverse this.** A Whisper implementation for Swift MLX with a
biasing hook, which would remove the language boundary without giving up the
shared format. `Transcriber` is what keeps that a new conformance rather than a
rewrite — the same seam D1 relied on.

**Verified end to end**, Swift spawning Python against a checksum-verified
`whisper-small`: warm-up 3.1 s, then 655–661 ms per 12.8-second utterance, of
which 0–1 ms is the pipe, transcript correct. What is *not* verified is
everything upstream of `transcribe(samples:)` — the hotkey, the microphone and
the injector still need a human at a real keyboard.

---

## D6 — fp16 by default, and the M0 benchmark SPEC §7 asked for

**Status:** the precision is decided. The default model is **measured and open**
— see "What this does to D1".

**Context.** SPEC §7 asked for a benchmark at M0 and D1 chose
`large-v3-turbo` without one, on architectural grounds, noting "F18's sub-1s
budget is the binding constraint, and turbo is the variant that meets it".
It is now runnable: `dictate asr-check <wav> --model <dir>`.

**Measured** on an Apple M2, 8 GB, macOS 26, mlx-whisper 0.4.3, warm median of
several runs on synthesised speech:

| model | precision | 6.2 s utterance | 12.8 s utterance |
|---|---|---|---|
| large-v3-turbo | fp16 | 1.95 s | 2.06 s |
| large-v3-turbo | fp32 | 3.28 s | 3.88 s |
| whisper-small | fp16 | 0.56 s | **0.66 s** |
| whisper-small | fp32 | 1.13 s | 1.54 s |

**Decision: fp16.** It is a flat ~2x against a budget of one second, and the
transcripts were identical on every sample benchmarked. `fp16=False` remains
available for debugging a suspected precision problem.

**A property of Whisper worth recording:** doubling the audio barely moved the
number (1.95 s → 2.06 s). Whisper pads every input to a 30-second window, so
cost is per-window, not per-second. M0's "10-second utterance" criterion is
really a one-window criterion, and utterances shorter than 30 s all cost the
same.

**What this does to D1.** `large-v3-turbo` misses M0's acceptance criterion by
2x on this machine, and the claim that turbo "meets" the sub-1s budget is
false here. `whisper-small` meets it with room to spare.

This is **not** enough to reverse D1 on its own, and it is recorded rather than
acted on for two reasons. It is one machine, and a base M2 with 8 GB is the low
end of the supported range — the same measurement on an M3 Max would likely
put turbo under the bar. And the samples were synthesised speech, which says
nothing about the accuracy gap on accented, noisy or technical input, where
large-v3-turbo is expected to be materially better. Choosing the smaller model
on latency alone would be trading an unmeasured amount of accuracy for a
measured amount of speed.

What the numbers do establish is that **one default cannot serve both ends of
the hardware range**, which is what `ModelCatalog.whisperSmall` already
anticipates by existing "for constrained machines". The open question is
whether selection should be automatic — a first-run benchmark — or a documented
choice. That is a product decision, and it needs a second machine's numbers
before it is worth making.

Nothing here disturbs D1's *architectural* reasoning: Whisper over SenseVoice
rests on the biasing argument, not on the variant.

**Addendum: language detection is a measurable cost, not just a correctness
risk.** Warm, five runs each, same 12.8-second utterance and the same resident
`whisper-small`:

| `language` | median |
|---|---|
| unset (detect) | 657 ms |
| `"en"` | 475 ms |

Detection is a separate encoder pass over the first window, so pinning the
language removes 182 ms — 28% — from every utterance. It also removes a
failure mode observed in testing: a clipped or short utterance gets read as
whatever language it most resembles, and a wrong guess mistranscribes the
entire window rather than a word of it. An English sentence came back as
Malay.

`Configuration.language` therefore exists and defaults to unset. Unset stays
the default because P1's code-switching needs per-window detection and is the
maintainer's own journey; anyone who does not switch languages should set it,
and gets both the accuracy and the 182 ms.
