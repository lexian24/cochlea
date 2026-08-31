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
echo "resolving ${REPO}"
JSON="$(curl -fsSL "$API")" || {
  echo "could not reach the provider. This is expected in sandboxed or" >&2
  echo "network-restricted environments; run it somewhere with access." >&2
  exit 1
}

python3 - "$JSON" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
wanted = (".safetensors", ".npz")
keep = {"config.json", "tokenizer.json", "preprocessor_config.json"}
rows = []
for entry in data.get("siblings", []):
    name = entry.get("rfilename", "")
    if "/" in name:
        continue
    if not (name.endswith(wanted) or name in keep):
        continue
    digest = (entry.get("lfs") or {}).get("oid")
    if digest:
        rows.append((name, digest))
if not rows:
    sys.exit("no files with digests found; the provider may not expose LFS oids")
print("Paste into ModelCatalog.swift as pinnedSHA256:\n")
print("        pinnedSHA256: [")
for name, digest in sorted(rows):
    print(f'            "{name}": "{digest}",')
print("        ]")
PY
