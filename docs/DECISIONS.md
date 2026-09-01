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

---

## D7 — Hybrid activation: hold to talk, or tap to latch

**Status:** decided and implemented.

**Context.** M0 shipped push-to-talk on a hardcoded Control-Option-D. The
maintainer's objection was specific and correct: holding a chord through a long
paragraph is its own kind of work, and the shortcut could not be changed
without a rebuild.

**Decision.** Three activation modes — `holdToTalk`, `toggle`, `hybrid` — with
**hybrid as the default**: hold the shortcut and it behaves exactly as M0 did;
tap it and dictation latches until the next tap. The threshold is 400 ms.

**Why hybrid rather than a mode setting.** Both behaviours are wanted, by the
same person, minutes apart: hold for a phrase, tap for a paragraph. A mode
setting makes the user predict which one they will need before they start
speaking, and be wrong. Hybrid reads the intent from how the key was pressed,
which is information the user has already supplied. The explicit modes remain
for anyone who wants the old behaviour guaranteed.

**What it costs, and the thing that had to be answered.** Push-to-talk bounded
the microphone with the user's hand. Toggle and hybrid do not, so it becomes
possible to start dictating and walk away — and a microphone nobody remembers
leaving open is the one failure this project's privacy positioning cannot
survive. So `maximumUtteranceSeconds` is not optional and defaults to five
minutes. When it fires the transcript is kept, not discarded: the user said
those words, and throwing them away would add a second failure to the first.

The 400 ms threshold is a guess and is not yet measured against real use. It is
a constant in one place for that reason.

**Consequence.** `HotkeyBinding` moved to `CochleaCore` because `Configuration`
persists it, and `HotkeyMonitor.rebind` exists because Carbon has no rebind
call — an `EventHotKeyRef` is registered for one combination and unregistered
as a unit, so tear-down and re-registration is the whole mechanism. A shortcut
recorded in Settings is live before the window closes.

---

## D8 — Contextual biasing works, and the cap must be per token

**Status:** measured. The mechanism is proven; the lexicon integration is not
built yet.

**Context.** M2 is the layer D1 calls "the layer that pays off first", and the
whole argument for D5 (ASR in a Python sidecar) was that biasing needs the
decode loop next to the lexicon. That claim had never been tested.

**It works.** `mlx_whisper.decoding` applies a list of `LogitFilter` objects at
every decode step, and hands each one the tokens generated so far — which is
exactly what phrase-level biasing needs, since a phrase's benefit only appears
across several steps. Measured on `whisper-small` with a synthesised sentence:

| | transcript |
|---|---|
| unbiased | "Deploy the service with **QBeckle** and check the **ginks** logs" |
| boost 3.0 | "…with **kubectl** and check the gink's logs" |
| boost 6.0 | "…with **kubectl** and check the **nginx** logs" |

`logit_filters` is a plain list built in `DecodingTask.__init__` with no public
injection point, so appending to it means patching that initialiser. That is the
one piece of coupling to mlx-whisper's internals this design accepts.

**`initial_prompt` is not a biasing hook.** It conditions the context and
competes for the 224-token prompt budget; it does not adjust token scores. Any
design that reaches for it instead of a `LogitFilter` is reaching for the weaker
thing because it is the documented one.

**The cap must be per token, not per entry — and this is F2 with teeth.** The
first implementation accumulated boosts (`+=`). With 25 entries sharing a
prefix, one token reached +69 logits and the decoder emitted
`"termnumbertermnumber termnumber…"` until it hit the token limit: a 68-character
transcript became 1169 characters, and latency went from 298 ms to 11 seconds.
That is not a slow filter, it is a runaway decode. Taking the maximum instead of
the sum fixes it completely.

**Measured cost, after the fix**, on a 12.8-second utterance:

| lexicon entries | median | over baseline |
|---|---|---|
| 0 | 295 ms | — |
| 25 | 308 ms | +5% |
| 100 | 321 ms | +9% |
| 400 | 375 ms | +27% |

400 entries fits F18's budget with room to spare.

**On over-triggering.** No false positives were observed up to boost 20, either
for terms absent from the audio or for a deliberate near-homophone ("modal"
against a recording saying "model"). That is a handful of synthesised samples,
not a corpus, so it is evidence that the working point is around 6 — not
evidence that F2 is solved. The decay, negative-signal and expiry mitigations
F2 specifies are still required.

---

## D9 — Streaming commits at pauses, and it is the default

**Date.** 2026-09-01. **Status.** Accepted, with a scheduled revisit at M4.

**Context.** Latch activation (D7) made long dictation practical and, in doing
so, made the wait unbearable: hold-to-talk bounded an utterance at the length of
a held chord, but a latched session is minutes long and nothing appeared at the
cursor until it ended. "Can we stream the output rather than waiting for the
whole audio to stop" is the direct consequence of shipping D7.

**What streaming means here.** The commit unit is a segment, not a word. The
detector already ended an utterance on trailing silence mid-hold; streaming
reuses that mechanism at a shorter pause (0.7 s rather than the 1.5 s hangover)
and, instead of ending the session, types that piece and keeps listening.

Word-level partial hypotheses were not built and are not planned for this
layer. They require revising text that is already on screen, and F18 rules that
out: the only way to revise typed text is backspacing, which breaks terminals
and sends half-finished messages in chat boxes that submit on Enter. A segment
is the largest unit that is never wrong later, so it is the right unit to
commit. Showing unstable text in a floating overlay — where it can be revised
because it is not in anyone's document — remains the way to get "as you speak"
feedback, and is deliberately deferred.

**No protocol change.** The sidecar (D5) still receives complete audio and
returns complete text. Segmentation happens on the Swift side, before the pipe.
Streaming was affordable precisely because it needed nothing from the layer
that is hardest to change.

**Order is a correctness property, not a nicety.** Segments are transcribed
asynchronously and a shorter one decodes faster, so independent tasks type
them backwards — measured, and reliably: five items with inverted delays came
out `[4, 3, 2, 1, 0]` every time. Under F18 that cannot be repaired after the
fact, because the text is already in the user's document. `CommitQueue`
serialises them, and the guarantee is structural rather than probabilistic:
every link awaits its predecessor, and links are only created on the main actor
in capture order.

**The separator has to be reconstructed.** A space that used to fall inside one
transcript is now a decision at every boundary, made without the ability to fix
it afterwards. Unconditional spacing breaks Chinese and puts a space before
every comma; no spacing runs English words together. `TranscriptJoiner` decides
from the boundary characters, and follows the unspaced side at a code-switch
boundary — `开会 discuss` reads correctly and `开会discuss` does not, while
`deploy 到` is acceptable either way. Hangul is deliberately excluded from the
unspaced set: Korean sits beside the CJK blocks and does space its words.

**Why it is the default.** The only thing streaming gives up is the M4
post-correction pass, which does not exist. Until it does, this is a choice
between a mode with a cost and no benefit and a mode with a benefit and no
cost. When M4 lands the trade becomes real and this decision should be
re-taken rather than inherited; the setting is already there for anyone who
wants the other behaviour today.

**Also fixed here.** `LatencySample.captureMillis` ran from the moment the
microphone opened, so the number checked against the 1 s budget included the
whole of the user's speech and no utterance longer than a second could pass
however fast the model was. Streaming turned that from wrong into absurd — a
three-minute session would have reported three minutes of latency. It now
measures from the audio being complete to work starting on it, which is the
drain wait plus queue time: the wait the user actually experiences after they
stop speaking.

---

## D10 — The lexicon is a file, and biasing is wired to it

**Date.** 2026-09-01. **Status.** Accepted.

**Context.** D8 established that contextual biasing works and found its
working point. What it did not do was connect anything: `dictate import` built
a `Lexicon` in memory, printed what it had found, and discarded it. The decode
loop and the lexicon were in the same process — D5's entire justification —
and never met.

**The path, end to end.** `dictate import text <file> --author <you>` →
`~/.cochlea/lexicon.json` → `dictate asr-serve` loads it → the decoder biases
towards it. Measured on the same synthesised utterance as D8, through the
shipping code rather than a scratch script:

| | transcript | warm median |
|---|---|---|
| unbiased | "…check the **gink's** logs" | 295 ms |
| 5 entries | "…check the **nginx** logs" | 303–309 ms |

**Strength maps to logits at a fixed rate.** The lexicon's scale (1.0 neutral,
capped at 3.0) is not the decoder's. The conversion is chosen so the lexicon's
default strength of 1.5 lands exactly on D8's measured working point of 6.0
logits, with a hard ceiling of 8.0 — above the working point, well below the
20 where over-triggering was looked for and not found. F2's cap is therefore
enforced twice, and the second one is the one that reaches the decoder.

**Phrases, not just words, and it is the same mechanism.** The unit is a token
*sequence*; a single word is the one-element case. Verified against the real
BPE rather than a stand-in: " request" is boosted only after " pull" has been
generated, never on its own. This matters beyond convenience — two word
entries for "pull request" lift "request" in every sentence the user speaks,
which is precisely the over-triggering F2 describes.

Both surface forms of every entry are indexed, with and without a leading
space. Whisper's BPE makes " kubectl" and "kubectl" different tokens entirely
(and "pull request" without the space tokenises as `p`/`ull`/` request`), so
indexing one form biases a word mid-sentence but not at the start of one —
which reads as the feature working intermittently rather than as a bug.

**JSON, not a table in `adapters.db`.** The lexicon is small, rewritten whole,
and is the one piece of adaptation state a user might reasonably want to read,
edit or delete by hand. That is the difference between a privacy claim someone
can check and one they have to take on faith. Written 0600 via a temporary
file and a rename, because a lexicon truncated mid-write loads without error
and biases towards a fragment.

**Import proposes; it does not write.** `--commit` is required. This is text
lifted out of the user's private messages, and the least the tool can do
before keeping any of it is show them exactly what it took. It is also the
mitigation in force for F25.

**A text importer, because invariant 3 is the hard part.** `gitlog` filters by
author inside git, so other people's commits are never read. A chat export has
no such structure: both halves are in one file in the same shape. The text
importer detects the conversation shape, and when it finds more than one
speaker and no `--author`, it **refuses** — it does not import and filter, and
it does not guess. Prose with no speaker prefixes is taken whole, since the
user chose the file and there is no second party to exclude.

**Not done.** The app does not yet feed hits back: the sidecar reports
`biased_terms` on every transcription and nothing reads them, so F2's decay
still has no negative signal in the running system. That closes when correction
capture (M1) lands, which is where the lexicon gets a second writer and the
question of who owns the file has to be settled.

---

## D11 — Fix-last may take text back, under a bound it cannot verify

**Date.** 2026-09-01. **Status.** Accepted.

**Context.** SPEC §1 rules out watching text fields through the Accessibility
API: fragile, breaks on every app update, and irreconcilable with the privacy
positioning. The consequence is that an edit the user makes in their own
document is invisible to this app, and corrections can only be captured
through an explicit action. Fix-last is that action.

The spec describes the panel as *reopening* the last utterance. It does not
say whether accepting a correction should also repair the document, and that
turns out to be the decision that determines whether anyone uses it. If the
panel only records, the user fixes the same error twice — once in their
document and once in a window — and the capture rate the whole project depends
on goes to approximately zero. If it repairs, the correction is *cheaper* than
fixing by hand, and it gets made.

**So it repairs, by backspacing, and F18 has to be squared with that.** F18
forbids revising already-typed text because backspacing breaks terminals and
submits half-finished messages in chat boxes that send on Enter. That
reasoning is about *automatic* revision — the app deciding on its own to
rewrite something. Fix-last differs on every axis that made it dangerous: the
user asked by name, seconds after the text appeared, and the panel states
exactly how many characters will be deleted before they confirm. Nothing in
the dictation path calls `deleteBackward`; only this does.

**The bound is on how wrong it can be, not a check that it is right.** The app
cannot see the document, so it cannot know whether the cursor moved. Two
guards, both crude on purpose:

- **Time.** Past `replaceWindowSeconds` (120 by default) the offer is
  withdrawn. A correction made ten minutes later is being made somewhere else.
- **Intervening dictation.** Any new utterance ends it, because the older text
  is no longer what sits next to the cursor.

When either fails, the panel still opens and still records — it just says why
it will not touch the text and asks the user to fix it themselves. Recording
never expires; only repair does.

**Two buttons rather than a setting.** "Fix it and remember" and "Just
remember it" are both present whenever repair is possible, because the app
genuinely cannot tell which is safe and the user can. A preference would ask
them to decide once, in the abstract, for a question whose answer changes
every time.

**Attribution stays in Python.** The panel calls `dictate correct`, which runs
F1's three-signal filter and files the result. A Swift implementation would be
a second copy of one rule, and two copies of a heuristic diverge. The verdict
comes back and is shown: a quarantined correction is one the user will have to
adjudicate and a revision is one that will never be trained on, and both look
identical to "saved" if the app does not say so.

**Carbon forced a refactor.** `RegisterEventHotKey` delivers every hotkey to
the same installed handler, so two `HotkeyMonitor` instances would each fire on
the other's presses — pressing fix-last would also start dictating. The events
carry an `EventHotKeyID`; reading it is what tells them apart, and that means
one monitor owning every shortcut rather than one per shortcut.

---

## D12 — A correction teaches the lexicon immediately

**Date.** 2026-09-01. **Status.** Accepted.

**Context.** Fix-last (D11) filed corrections into the store and nothing else
happened. The store is the input to M4's trainer, which does not exist — so
from the user's side, correcting a word did *nothing*: the same word was
misheard on the very next utterance, and there was no way to tell whether the
correction had been recorded at all. That is the shape of a feature people stop
using after three tries, and low capture volume is the risk SPEC §1 already
names as the one that decides whether any of this works.

**Biasing needs no training.** M2's whole property is that it takes effect
immediately, and the lexicon is a file the ASR helper reads at startup. A word
the user has just typed by hand is exactly the evidence the lexicon wants. So a
correction now adds it, and the app says which words it learned.

**Gated on the F1 verdict, not on the text.** Only a `correction` teaches. A
revision is someone changing their mind, and the words they changed it to are
not evidence the recogniser got anything wrong; learning from those fills the
lexicon with the user's whole vocabulary rather than the part that needs help,
which is F25 arriving through a second door.

**Three kinds of correction teach nothing, on purpose:**

- **Ordinary words.** `fell` → `failed` is two words Whisper knows perfectly
  well, confused for acoustic reasons. A lexicon entry cannot fix that and can
  make it worse by boosting one over the other.
- **Homophones.** `there` → `their` is F5 exactly: biasing cannot separate
  them, so an entry creates errors instead of removing them. Rejected at
  admission and again before admission is attempted.
- **Rewrites.** Bounded at three terms per correction, because a correction
  that replaced half a sentence is a revision the filter did not catch.

**What this does not do.** It does not touch the boost of an existing entry, so
correcting the same word twice does not escalate it — F2's cap is about
magnitude and this is about admission. Nor does it remove entries: the negative
signal still has no path from the app, because nothing reads the sidecar's
`biased_terms` yet.

---

## D13 — Fix-last corrects a session, not a segment

**Date.** 2026-09-01. **Status.** Accepted. Supersedes part of [D11](#d11).

**Context.** Streaming (D9) commits at every pause, so one spoken paragraph is
half a dozen commits. Fix-last held only the most recent one, which meant it
offered the final phrase — almost never where the error was. Hand-testing put
it plainly: people dictate a whole thought, read it back, and *then* fix it.
The unit they want to correct is the thing they just said, not its last clause.

The unit is now the **session**: everything one hold or latch put at the
cursor, joined. The hypothesis and the injected text are accumulated
separately, because they differ by exactly the separators the joiner added —
the correction pair needs the raw hypothesis, and the deletion needs the
character count actually in the document.

**A new session starts on the first commit, not on key-down.** An accidental
tap or a hold through silence must not discard the paragraph the user is still
reading. Only text actually arriving replaces it.

**The window moved from two minutes to five, and now runs from the end of the
session.** Measured per-commit, a long dictation could age out of its own
correction window while still being spoken. Counted from when the user stopped
talking, five minutes is the span in which someone reads back what they said —
and the guard was never really about time, which is only a proxy for "the
cursor has probably moved".
