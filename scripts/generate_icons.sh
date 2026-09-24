#!/bin/bash
# Regenerates every raster brand asset from assets/brand/templar-icon.svg
# (the badge) and, for Android's adaptive icon and splash, from
# assets/brand/templar-cross.svg (the bare mark).
#
# Run this after editing the brand SVGs — the PNG/ICO files are build products,
# not hand-edited art.
#
# WHY A BROWSER AND NOT qlmanage: QuickLook composites SVGs onto WHITE and
# throws the alpha away. The squircle's corners came out opaque white, which
# macOS then drew as four white triangles around the Dock icon. Any
# Chromium-family browser rasterizes with real transparency via
# --default-background-color=00000000.
#
# The SVG is embedded in a generated HTML wrapper sized to the exact pixel
# dimensions we want; pointing the browser straight at the .svg renders it at
# its own intrinsic size and screenshots only the top-left corner of it.
#
# Usage: ./scripts/generate_icons.sh   (from the repo root, macOS)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

SRC="assets/brand/templar-icon.svg"
CROSS="assets/brand/templar-cross.svg"
FLUTTER="src/templar_wallet"
MACOS_ICONSET="$FLUTTER/macos/Runner/Assets.xcassets/AppIcon.appiconset"
ANDROID_RES="$FLUTTER/android/app/src/main/res"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ "$(uname)" != "Darwin" ]; then
  echo "This script targets macOS. The generated PNG/ICO files are committed," >&2
  echo "so other platforms never need to run it." >&2
  exit 1
fi

# Any Chromium-family browser will do; first one found wins.
BROWSER=""
for candidate in \
  "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" \
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  "/Applications/Chromium.app/Contents/MacOS/Chromium" \
  "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"; do
  if [ -x "$candidate" ]; then BROWSER="$candidate"; break; fi
done
if [ -z "$BROWSER" ]; then
  echo "No Chromium-family browser found (looked for Brave, Chrome, Chromium," >&2
  echo "Edge). One is required: it is the only renderer on a stock Mac that" >&2
  echo "preserves SVG transparency." >&2
  exit 1
fi

# Renders $SRC at NxN into $TMP/N.png, corners genuinely transparent.
render() {
  local size="$1"
  cat > "$TMP/wrap_$size.html" <<HTML
<!doctype html><meta charset="utf-8">
<style>
  html,body { margin:0; padding:0; background:transparent; }
  img { display:block; width:${size}px; height:${size}px; }
</style>
<img src="file://$ROOT/$SRC">
HTML
  "$BROWSER" --headless --disable-gpu --no-sandbox --hide-scrollbars \
    --default-background-color=00000000 \
    --force-device-scale-factor=1 \
    --screenshot="$TMP/$size.png" --window-size="$size,$size" \
    "file://$TMP/wrap_$size.html" >/dev/null 2>&1
  [ -f "$TMP/$size.png" ] || { echo "render failed at ${size}px" >&2; exit 1; }
}

echo "Rendering ${SRC} with $(basename "$BROWSER")..."
for s in 16 24 32 48 64 128 256 512 1024; do render "$s"; done

# Guardrail: the exact regression this script exists to prevent.
python3 scripts/png_to_ico.py --assert-transparent-corner "$TMP/512.png"

echo "macOS app icon → $MACOS_ICONSET"
for s in 16 32 64 128 256 512 1024; do
  cp "$TMP/$s.png" "$MACOS_ICONSET/app_icon_$s.png"
done

echo "In-app logo → $FLUTTER/assets/images/templar-wallet-logo.png"
cp "$TMP/512.png" "$FLUTTER/assets/images/templar-wallet-logo.png"

echo "Windows icon → $FLUTTER/windows/runner/resources/app_icon.ico"
python3 scripts/png_to_ico.py "$FLUTTER/windows/runner/resources/app_icon.ico" \
  "$TMP/16.png" "$TMP/24.png" "$TMP/32.png" "$TMP/48.png" \
  "$TMP/64.png" "$TMP/128.png" "$TMP/256.png"

echo "Linux icon → $FLUTTER/linux/runner/resources/templar_wallet.png"
mkdir -p "$FLUTTER/linux/runner/resources"
cp "$TMP/256.png" "$FLUTTER/linux/runner/resources/templar_wallet.png"

# ---------------------------------------------------------------- Android
# Android wants dp sizes at five densities (mdpi 1x, hdpi 1.5x, xhdpi 2x,
# xxhdpi 3x, xxxhdpi 4x). Scales are kept in quarters so hdpi stays integer
# for every even dp value used below.
#
# Three artworks:
#  * the full badge ($SRC) — legacy launcher icon (API 24–25, 48dp) and the
#    pre-Android-12 starting window logo (96dp, drawable/launch_background.xml);
#  * the bare cross ($CROSS) on a transparent canvas — adaptive-icon
#    foreground (108dp canvas) and Android 12+ splash icon (288dp canvas).
#    Launchers mask the adaptive canvas to its inner 72dp and the splash icon
#    to its inner 2/3 circle, so both put the cross at 50% of the canvas: its
#    arm tips (1.07x the bounding box) then stay inside the 66dp safe zone;
#  * the same cross as a VectorDrawable — the monochrome (themed-icon) layer.
# The adaptive background is a gradient <shape> in drawable/, not a raster.
DENSITIES="mdpi:4 hdpi:6 xhdpi:8 xxhdpi:12 xxxhdpi:16"
FG_CANVAS_DP=108; FG_MARK_DP=54
SPLASH_CANVAS_DP=288; SPLASH_MARK_DP=144
LEGACY_ICON_DP=48; LAUNCH_LOGO_DP=96

# dp_px DP QUARTERS → pixels; refuses fractional results rather than rounding.
dp_px() {
  local dp="$1" q="$2"
  if (( (dp * q) % 4 != 0 )); then
    echo "${dp}dp is not a whole pixel at scale $q/4" >&2; exit 1
  fi
  echo $(( dp * q / 4 ))
}

# Renders $CROSS centred on a transparent CANVASxCANVAS px page, its bounding
# box scaled to MARKxMARK px, into OUT. Same browser, same alpha guardrail as
# render(); only the wrapper differs. The mark is placed as an SVG <image>
# rather than an <img>: the offset is half a pixel at hdpi, and CSS layout
# snaps an <img> to whole pixels (one pixel off-centre) while SVG user space
# keeps the fraction and rasterizes the vector exactly where it belongs.
render_mark() {
  local canvas="$1" mark="$2" out="$3"
  local offset; offset="$(awk "BEGIN { print ($canvas - $mark) / 2 }")"
  local wrap="$TMP/wrap_mark_${canvas}_${mark}.html"
  cat > "$wrap" <<HTML
<!doctype html><meta charset="utf-8">
<style>
  html,body { margin:0; padding:0; background:transparent; }
  svg { display:block; }
</style>
<svg xmlns="http://www.w3.org/2000/svg" width="${canvas}" height="${canvas}" viewBox="0 0 ${canvas} ${canvas}">
  <image href="file://$ROOT/$CROSS" x="${offset}" y="${offset}" width="${mark}" height="${mark}"/>
</svg>
HTML
  "$BROWSER" --headless --disable-gpu --no-sandbox --hide-scrollbars \
    --default-background-color=00000000 \
    --force-device-scale-factor=1 \
    --screenshot="$out" --window-size="$canvas,$canvas" \
    "file://$wrap" >/dev/null 2>&1
  [ -f "$out" ] || { echo "render failed: $out" >&2; exit 1; }
}

# assert_px FILE PX — the PNG's IHDR must say PXxPX (a browser that ignored
# --window-size would silently hand back a viewport-sized screenshot).
assert_px() {
  python3 - "$1" "$2" <<'PY'
import struct, sys
path, want = sys.argv[1], int(sys.argv[2])
with open(path, "rb") as fh:
    w, h = struct.unpack(">II", fh.read(24)[16:24])
if (w, h) != (want, want):
    sys.exit(f"{path}: {w}x{h}, expected {want}x{want}")
PY
}

echo "Android icons + splash → $ANDROID_RES"
for entry in $DENSITIES; do
  density="${entry%%:*}"; q="${entry##*:}"
  mkdir -p "$ANDROID_RES/mipmap-$density" "$ANDROID_RES/drawable-$density"

  # Legacy launcher icon (API < 26): the full badge at 48dp.
  px="$(dp_px "$LEGACY_ICON_DP" "$q")"
  [ -f "$TMP/$px.png" ] || render "$px"
  cp "$TMP/$px.png" "$ANDROID_RES/mipmap-$density/ic_launcher.png"

  # Pre-12 starting window logo: the badge at 96dp.
  px="$(dp_px "$LAUNCH_LOGO_DP" "$q")"
  [ -f "$TMP/$px.png" ] || render "$px"
  cp "$TMP/$px.png" "$ANDROID_RES/drawable-$density/launch_logo.png"

  # Adaptive-icon foreground (API 26+): 108dp canvas, cross at 54dp.
  canvas="$(dp_px "$FG_CANVAS_DP" "$q")"; mark="$(dp_px "$FG_MARK_DP" "$q")"
  out="$ANDROID_RES/mipmap-$density/ic_launcher_foreground.png"
  render_mark "$canvas" "$mark" "$out"; assert_px "$out" "$canvas"

  # Android 12+ splash icon: 288dp canvas, cross at 144dp.
  canvas="$(dp_px "$SPLASH_CANVAS_DP" "$q")"; mark="$(dp_px "$SPLASH_MARK_DP" "$q")"
  out="$ANDROID_RES/drawable-$density/splash_icon.png"
  render_mark "$canvas" "$mark" "$out"; assert_px "$out" "$canvas"
  echo "  $density: ic_launcher $(dp_px "$LEGACY_ICON_DP" "$q")px, launch_logo $(dp_px "$LAUNCH_LOGO_DP" "$q")px, foreground $(dp_px "$FG_CANVAS_DP" "$q")px, splash_icon $(dp_px "$SPLASH_CANVAS_DP" "$q")px"
done

# Guardrail, Android edition: the transparent canvases must have stayed
# transparent (a launcher would otherwise draw a black square around the cross).
for f in mipmap-xxxhdpi/ic_launcher.png mipmap-xxxhdpi/ic_launcher_foreground.png \
         drawable-xxxhdpi/splash_icon.png; do
  python3 scripts/png_to_ico.py --assert-transparent-corner "$ANDROID_RES/$f"
done

echo "Android monochrome (themed) icon → $ANDROID_RES/drawable/ic_launcher_monochrome.xml"
python3 scripts/svg_mark_to_vector.py "$CROSS" \
  "$ANDROID_RES/drawable/ic_launcher_monochrome.xml" \
  --canvas "$FG_CANVAS_DP" --mark "$FG_MARK_DP"

echo
echo "Done. Rebuild the app to pick the new icons up:"
echo "  cd $FLUTTER && flutter clean && flutter run -d macos"
echo "  ./scripts/build_android.sh   # Android: launcher, themed icon and splash"
