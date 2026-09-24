#!/bin/bash
# Renders the installer artwork that scripts/make_dmg.sh consumes:
#   packaging/macos/dmg-background.png / @2x / .tiff   (DMG window backdrop)
#   packaging/macos/VolumeIcon.icns                    (mounted volume icon)
#   packaging/windows/wizard-*.bmp                     (Inno Setup wizard art)
#
# Same renderer as scripts/generate_icons.sh — a Chromium-family browser, the
# only thing on a stock Mac that rasterizes SVG without flattening alpha onto
# white. See that script for the story.
#
# Usage: ./scripts/make_packaging_assets.sh   (from the repo root, macOS)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p packaging/macos packaging/windows

BROWSER=""
for candidate in \
  "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" \
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  "/Applications/Chromium.app/Contents/MacOS/Chromium" \
  "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"; do
  if [ -x "$candidate" ]; then BROWSER="$candidate"; break; fi
done
[ -n "$BROWSER" ] || { echo "No Chromium-family browser found." >&2; exit 1; }

# shot <svg> <width> <height> <scale> <out.png>
shot() {
  local svg="$1" w="$2" h="$3" scale="$4" out="$5"
  cat > "$TMP/wrap.html" <<HTML
<!doctype html><meta charset="utf-8">
<style>
  html,body { margin:0; padding:0; background:transparent; }
  img { display:block; width:${w}px; height:${h}px; }
</style>
<img src="file://$ROOT/$svg">
HTML
  "$BROWSER" --headless --disable-gpu --no-sandbox --hide-scrollbars \
    --default-background-color=00000000 \
    --force-device-scale-factor="$scale" \
    --screenshot="$out" --window-size="$w,$h" \
    "file://$TMP/wrap.html" >/dev/null 2>&1
  [ -f "$out" ] || { echo "render failed: $svg @${scale}x" >&2; exit 1; }
}

echo "==> DMG background"
shot assets/brand/dmg-background.svg 660 420 1 packaging/macos/dmg-background.png
shot assets/brand/dmg-background.svg 660 420 2 packaging/macos/dmg-background@2x.png
# One TIFF carrying both densities is how a DMG gets a non-blurry backdrop on
# a Retina display; Finder picks the representation itself.
tiffutil -cathidpicheck \
  packaging/macos/dmg-background.png \
  packaging/macos/dmg-background@2x.png \
  -out packaging/macos/dmg-background.tiff >/dev/null
echo "    packaging/macos/dmg-background.{png,@2x.png,tiff}"

echo "==> Volume icon"
ICONSET="$TMP/VolumeIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  shot assets/brand/templar-icon.svg "$s" "$s" 1 "$ICONSET/icon_${s}x${s}.png"
  shot assets/brand/templar-icon.svg "$s" "$s" 2 "$ICONSET/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$ICONSET" -o packaging/macos/VolumeIcon.icns
echo "    packaging/macos/VolumeIcon.icns"

echo "==> Inno Setup wizard art"
# Inno Setup wants BMP, and it does NOT support alpha — these are rendered onto
# the brand canvas rather than transparent, then flattened by sips.
shot assets/brand/wizard-banner.svg 497 314 1 "$TMP/wizard-large.png"
shot assets/brand/wizard-header.svg 55 58 1 "$TMP/wizard-small.png"
sips -s format bmp -s formatOptions default "$TMP/wizard-large.png" \
  --out packaging/windows/wizard-large.bmp >/dev/null
sips -s format bmp -s formatOptions default "$TMP/wizard-small.png" \
  --out packaging/windows/wizard-small.bmp >/dev/null
# sips writes a top-down DIB (negative biHeight). Inno Setup ignores the sign
# and draws the rows in file order, which is how both wizard images ended up
# upside down in the installer. Rewrite them bottom-up.
python3 scripts/bmp_bottom_up.py \
  packaging/windows/wizard-large.bmp packaging/windows/wizard-small.bmp
echo "    packaging/windows/wizard-{large,small}.bmp"

echo
echo "Done."
