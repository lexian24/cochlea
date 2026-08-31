#!/usr/bin/env bash
# Prepare this machine to hand-test M0. See macos/TESTING.md.
#
# Idempotent: safe to re-run after any change. Run it again after editing
# Swift, because it rebuilds and re-signs the bundle.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
MODEL="${COCHLEA_TEST_MODEL:-whisper-small}"
ok=0

say()  { printf '%s\n' "$*"; }
good() { printf '  \033[32mok\033[0m    %s\n' "$*"; }
bad()  { printf '  \033[31mmiss\033[0m  %s\n' "$*"; ok=1; }

say "cochlea — test setup"
say

# 1. The Python helper the app shells out to for speech recognition (D5).
#    The app does not consult PATH (a Finder-launched app does not inherit the
#    shell's), so this has to be somewhere it actually looks.
if [ -x "$REPO/.venv/bin/dictate" ]; then
  ln -sf "$REPO/.venv/bin/dictate" /opt/homebrew/bin/dictate 2>/dev/null \
    && good "dictate -> /opt/homebrew/bin/dictate" \
    || bad  "could not link into /opt/homebrew/bin (try: sudo)"
else
  bad "no .venv/bin/dictate — run: python3 -m venv .venv && .venv/bin/pip install -e '.[dev,asr]'"
fi

# 2. A model. The app downloads and checksum-verifies this itself on first run
#    (F21, D4); this only reports whether it is already there.
if [ -f "$HOME/.cochlea/models/$MODEL/config.json" ]; then
  good "model $MODEL installed"
else
  bad "no model at ~/.cochlea/models/$MODEL"
  say "        the app downloads it on first run, or see macos/TESTING.md"
fi

# 3. Point the app at that model. whisper-small meets M0's latency budget on
#    an 8 GB M2; large-v3-turbo does not (D6). Written only if absent, so an
#    edit of yours survives a re-run.
mkdir -p "$HOME/.cochlea"
if [ -f "$HOME/.cochlea/config.json" ]; then
  good "config exists (model: $(python3 -c 'import json,os,sys; print(json.load(open(os.path.expanduser("~/.cochlea/config.json"))).get("modelIdentifier","?"))' 2>/dev/null || echo '?'))"
else
  cat > "$HOME/.cochlea/config.json" <<JSON
{
  "acousticRetentionEnabled": false,
  "home": "file://$HOME/.cochlea/",
  "keepModelResident": true,
  "latencyBudgetMillis": 1000,
  "mode": "commitOnRelease",
  "modelIdentifier": "$MODEL"
}
JSON
  good "wrote ~/.cochlea/config.json (model: $MODEL)"
fi

# 4. Build, sign, unquarantine. Ad-hoc signing is not cosmetic: TCC keys an
#    unsigned bundle by path and re-prompts unpredictably across rebuilds.
say "  ...   building (first build takes a minute)"
if bash Tools/build-app.sh >/tmp/cochlea-build.log 2>&1; then
  codesign --force --sign - --identifier com.cochlea.app build/cochlea.app >/dev/null 2>&1
  xattr -dr com.apple.quarantine build/cochlea.app 2>/dev/null
  good "build/cochlea.app built, signed, unquarantined"
else
  bad "build failed — see /tmp/cochlea-build.log"
  tail -20 /tmp/cochlea-build.log | sed 's/^/        /'
fi

say
if [ "$ok" -ne 0 ]; then
  say "Fix the 'miss' lines above, then run this again."
  exit 1
fi

cat <<'NEXT'
Ready. Start the app in this terminal so you can watch what it does:

    ./build/cochlea.app/Contents/MacOS/cochlea

Then hold Control-Option-D, say a sentence, and release. Each test and what
to look for is in macos/TESTING.md. Ctrl-C here quits the app.
NEXT
