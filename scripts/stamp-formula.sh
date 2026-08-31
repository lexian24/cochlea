#!/usr/bin/env bash
# Fill in url + sha256 in Formula/cochlea.rb for a release tag.
#
# A Homebrew formula cannot be published with a placeholder checksum, and the
# checksum cannot be known until the tag exists. This script closes that gap in
# one step so cutting a release does not involve hand-editing a hash.
#
#   scripts/stamp-formula.sh v0.1.0                 # fetch the GitHub tarball
#   scripts/stamp-formula.sh v0.1.0 ./local.tar.gz  # use a local tarball
set -euo pipefail

TAG="${1:?usage: stamp-formula.sh <tag> [local-tarball]}"
LOCAL="${2:-}"
REPO="lexian24/cochlea"
FORMULA="$(dirname "$0")/../Formula/cochlea.rb"
URL="https://github.com/${REPO}/archive/refs/tags/${TAG}.tar.gz"
VERSION="${TAG#v}"

if [[ -n "$LOCAL" ]]; then
  [[ -f "$LOCAL" ]] || { echo "no such tarball: $LOCAL" >&2; exit 1; }
  SHA="$(sha256sum "$LOCAL" | cut -d' ' -f1)"
else
  command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
  TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
  echo "fetching $URL"
  curl -fsSL "$URL" -o "$TMP" || { echo "tag $TAG not published yet" >&2; exit 1; }
  SHA="$(sha256sum "$TMP" | cut -d' ' -f1)"
fi

python3 - "$FORMULA" "$URL" "$SHA" <<'PY'
import re, sys
path, url, sha = sys.argv[1:4]
src = open(path).read()
src, n_url = re.subn(r'^(\s*)url\s+".*"$', lambda m: f'{m.group(1)}url "{url}"',
                     src, count=1, flags=re.M)
src, n_sha = re.subn(r'^(\s*)sha256\s+"[0-9a-f]{64}"$',
                     lambda m: f'{m.group(1)}sha256 "{sha}"',
                     src, count=1, flags=re.M)
if n_url != 1 or n_sha != 1:
    sys.exit(f"failed to rewrite formula (url={n_url}, sha256={n_sha})")
# Drop the not-publishable banner once the fields are real.
src = re.sub(r"# STATUS: not yet publishable\..*?docs/RELEASING\.md\.\n#\n", "",
             src, flags=re.S)
open(path, "w").write(src)
print(f"stamped {path}\n  url    {url}\n  sha256 {sha}")
PY

echo
echo "Next: bump version in pyproject.toml to ${VERSION} if it is not already,"
echo "      then commit the formula and open a PR to the tap."
