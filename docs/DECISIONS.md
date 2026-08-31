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
