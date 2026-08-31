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
