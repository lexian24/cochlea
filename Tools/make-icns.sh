#!/usr/bin/env bash
# Build cochlea.icns from Resources/logo/icon.svg. macOS only (needs iconutil).
#
# Regenerate the SVG first if the mark changed:  python3 Tools/make_logo.py
set -euo pipefail
cd "$(dirname "$0")/.."

SVG="Resources/logo/icon.svg"
SET="build/cochlea.iconset"
OUT="macos/Resources/cochlea.icns"

command -v iconutil >/dev/null || { echo "iconutil not found — macOS only" >&2; exit 1; }
RENDER=""
for c in rsvg-convert magick convert; do command -v "$c" >/dev/null && RENDER="$c" && break; done
if [ -z "$RENDER" ]; then
  echo "need an SVG rasteriser: brew install librsvg   (or imagemagick)" >&2
  exit 1
fi

rm -rf "$SET"; mkdir -p "$SET" "$(dirname "$OUT")"
render() { # size, outfile
  case "$RENDER" in
    rsvg-convert) rsvg-convert -w "$1" -h "$1" "$SVG" -o "$2" ;;
    *)            "$RENDER" -background none -density 512 -resize "${1}x${1}" "$SVG" "$2" ;;
  esac
}
for s in 16 32 128 256 512; do
  render "$s"           "$SET/icon_${s}x${s}.png"
  render "$((s * 2))"   "$SET/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$SET" -o "$OUT"
echo "wrote $OUT"
