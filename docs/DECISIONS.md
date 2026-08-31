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

**Status:** decided, with a known weakness.

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
