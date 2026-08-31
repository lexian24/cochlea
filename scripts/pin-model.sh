#!/usr/bin/env bash
# Pin a model's file checksums into ModelCatalog.swift.
#
# docs/DECISIONS.md D2: an unpinned download is trust-on-first-use — it checks
# the bytes against what the provider says, not against anything reviewed.
# Pinning is required before distributing a build that downloads weights.
#
# Run this on a machine that can reach huggingface.co, then commit the result
# so the digests are reviewable in a diff.
#
#   scripts/pin-model.sh mlx-community/whisper-large-v3-turbo
set -euo pipefail

REPO="${1:?usage: pin-model.sh <huggingface-repo-id>}"
API="https://huggingface.co/api/models/${REPO}?blobs=true"

command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
echo "resolving ${REPO}" >&2
JSON="$(curl -fsSL "$API")" || {
  echo "could not reach the provider. This is expected in sandboxed or" >&2
  echo "network-restricted environments; run it somewhere with access." >&2
  exit 1
}

python3 - "$JSON" "$REPO" <<'PY'
import hashlib
import json
import subprocess
import sys

data = json.loads(sys.argv[1])
repo = sys.argv[2]

WEIGHTS = (".safetensors", ".npz")
KEEP = {"config.json", "tokenizer.json", "preprocessor_config.json"}

# Anything we would have to fetch in order to hash it. The weights are
# gigabytes and are always LFS-tracked, so this ceiling should never be
# reached by a file we actually download; if it is, that is a repository
# layout this script has not seen and should not guess at.
MAX_LOCAL_HASH_BYTES = 8 * 1024 * 1024


def is_sha256(value):
    # 64 hex characters. A git blob oid is a 40-character SHA-1, and pinning
    # one would fail every download as a checksum mismatch that reads like
    # file corruption.
    return isinstance(value, str) and len(value) == 64 and \
        all(c in "0123456789abcdefABCDEF" for c in value)


def published_digest(entry):
    """The SHA-256 HuggingFace publishes for an LFS-tracked file.

    The `?blobs=true` endpoint spells it `lfs.sha256`; `paths-info` spells the
    same value `lfs.oid`. Accept either. The *top-level* `oid` is a git blob
    SHA-1 and is deliberately not consulted.
    """
    lfs = entry.get("lfs") or {}
    for key in ("sha256", "oid"):
        if is_sha256(lfs.get(key)):
            return lfs[key].lower()
    return None


def hash_over_the_wire(name, size):
    """SHA-256 of a file git stores directly, which no endpoint publishes.

    config.json is not LFS-tracked in any mlx-community Whisper repo, so the
    only way to pin it is to fetch the bytes and hash them here. That is the
    same trust-on-first-use D2 describes — the difference is that the result
    lands in a diff a human reviews, which is the whole point of pinning.
    """
    if size > MAX_LOCAL_HASH_BYTES:
        sys.exit(f"{name} is {size} bytes and carries no published digest; "
                 f"refusing to download it to compute one")
    url = f"https://huggingface.co/{repo}/resolve/main/{name}"
    print(f"  hashing {name} ({size} B) — not LFS, no published digest",
          file=sys.stderr)
    # curl, not urllib: the script already requires curl, and a python.org
    # framework build ships no CA bundle, so urllib fails TLS verification on
    # a machine where curl succeeds. One HTTP client means one trust store.
    fetched = subprocess.run(["curl", "-fsSL", url],
                             check=True, capture_output=True).stdout
    return hashlib.sha256(fetched).hexdigest()


rows = []
saw_weights = False
for entry in data.get("siblings", []):
    name = entry.get("rfilename", "")
    if "/" in name:                                  # no nested quantisations
        continue
    if not (name.endswith(WEIGHTS) or name in KEEP):
        continue
    if name.endswith(WEIGHTS):
        saw_weights = True
    digest = published_digest(entry) or hash_over_the_wire(name, entry.get("size", 0))
    rows.append((name, digest))

if not saw_weights:
    sys.exit(f"no weight file (.safetensors/.npz) found in {repo}")

print("Paste into ModelCatalog.swift as pinnedSHA256:\n")
print("        pinnedSHA256: [")
for name, digest in sorted(rows):
    print(f'            "{name}": "{digest}",')
print("        ]")
PY
