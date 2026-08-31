#!/usr/bin/env bash
# Build cochlea.app from the SwiftPM package.
#
# SwiftPM produces a bare executable; a menu bar app needs a bundle with an
# Info.plist carrying LSUIElement (no Dock icon) and the two usage strings
# macOS shows when it asks for permission. This assembles that.
#
# NOTE: macos/ has never been compiled. Expect `swift build` to fail first.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/cochlea.app"
VERSION="$(grep -m1 '^version' pyproject.toml | cut -d'"' -f2)"

echo "==> swift build ($CONFIG)"
swift build --package-path macos -c "$CONFIG"
BIN="$(swift build --package-path macos -c "$CONFIG" --show-bin-path)/CochleaApp"
[ -x "$BIN" ] || { echo "no binary at $BIN" >&2; exit 1; }

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/cochlea"
[ -f macos/Resources/cochlea.icns ] && cp macos/Resources/cochlea.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>cochlea</string>
  <key>CFBundleDisplayName</key>       <string>cochlea</string>
  <key>CFBundleIdentifier</key>        <string>com.cochlea.app</string>
  <key>CFBundleVersion</key>           <string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleExecutable</key>        <string>cochlea</string>
  <key>CFBundleIconFile</key>          <string>cochlea</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>LSMinimumSystemVersion</key>    <string>14.0</string>
  <!-- Menu bar accessory: no Dock icon, no window. -->
  <key>LSUIElement</key>               <true/>
  <!-- Shown by macOS in the permission prompt. Invariant 8 means these are
       read at first use of the feature, never at launch. -->
  <key>NSMicrophoneUsageDescription</key>
  <string>cochlea listens only while you hold the dictation hotkey, and only on this Mac.</string>
</dict>
</plist>
PLIST

echo "==> $APP"
echo
echo "Unsigned. Gatekeeper will block it (SPEC F22). To run it locally now:"
echo "   xattr -dr com.apple.quarantine $APP"
echo "Then grant Accessibility in System Settings > Privacy & Security."
