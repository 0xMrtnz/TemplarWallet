#!/bin/bash
# Builds the macOS disk image: Templar Wallet.app next to an Applications
# symlink, on the branded background, optionally signed and notarized.
#
#   ./scripts/make_dmg.sh [path/to/templar_wallet.app]
#
# Defaults to the release build under src/templar_wallet/build. Output lands in
# dist/TemplarWallet-<version>-macos.dmg.
#
# SIGNING (optional, set in the environment):
#   SIGN_IDENTITY   "Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE  a notarytool keychain profile name
# Both are needed for an install with no Gatekeeper warning. Without them you
# still get a working DMG, but macOS will refuse it on first open until the
# user right-clicks → Open. See docs/build/RELEASE.md.
#
# WINDOW LAYOUT: icon positions live in a .DS_Store. Finder is the only thing
# that writes one, via AppleScript, and that needs Automation permission which
# CI runners and locked-down Macs do not grant. So:
#   1. if packaging/macos/dmg-DS_Store exists, it is copied in verbatim — no
#      AppleScript, works everywhere, and is the reproducible path;
#   2. otherwise AppleScript is attempted and its failure is not fatal;
#   3. either way the DMG is valid and installable.
# docs/build/RELEASE.md explains how to record the .DS_Store once by hand.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

APP="${1:-src/templar_wallet/build/macos/Build/Products/Release/templar_wallet.app}"
VOLNAME="Templar Wallet"
STAGE="$(mktemp -d)"
MOUNT=""
cleanup() {
  [ -n "$MOUNT" ] && hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
  rm -rf "$STAGE"
}
trap cleanup EXIT

if [ ! -d "$APP" ]; then
  echo "No app bundle at: $APP" >&2
  echo "Build one first:  cd src/templar_wallet && flutter build macos --release" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$APP/Contents/Info.plist" 2>/dev/null || echo 0.0.0)"
mkdir -p dist
OUT="dist/TemplarWallet-${VERSION}-macos.dmg"
RW="$STAGE/rw.dmg"

echo "==> Staging"
mkdir -p "$STAGE/vol/.background"
# Copy, preserving symlinks and extended attributes — a plain cp -R corrupts
# the framework symlinks inside the bundle and breaks the signature.
ditto "$APP" "$STAGE/vol/$VOLNAME.app"
ln -s /Applications "$STAGE/vol/Applications"

if [ -f packaging/macos/dmg-background.tiff ]; then
  cp packaging/macos/dmg-background.tiff "$STAGE/vol/.background/background.tiff"
  BG_NAME="background.tiff"
elif [ -f packaging/macos/dmg-background.png ]; then
  cp packaging/macos/dmg-background.png "$STAGE/vol/.background/background.png"
  BG_NAME="background.png"
else
  echo "    no background found — run ./scripts/make_packaging_assets.sh" >&2
  BG_NAME=""
fi

if [ -f packaging/macos/VolumeIcon.icns ]; then
  cp packaging/macos/VolumeIcon.icns "$STAGE/vol/.VolumeIcon.icns"
  SetFile -a C "$STAGE/vol" 2>/dev/null || true
fi

# ── Sign the app before it is sealed into the image ──────────────────────────
if [ -n "${SIGN_IDENTITY:-}" ]; then
  echo "==> Signing app"
  # --deep is deprecated and does not sign nested code correctly; sign the
  # embedded dylib first, then the bundle.
  find "$STAGE/vol/$VOLNAME.app/Contents/Frameworks" -name '*.dylib' -print0 2>/dev/null |
    while IFS= read -r -d '' lib; do
      codesign --force --timestamp --options runtime \
        --sign "$SIGN_IDENTITY" "$lib"
    done
  codesign --force --timestamp --options runtime \
    --entitlements src/templar_wallet/macos/Runner/Release.entitlements \
    --sign "$SIGN_IDENTITY" "$STAGE/vol/$VOLNAME.app"
  codesign --verify --strict --verbose=2 "$STAGE/vol/$VOLNAME.app"
else
  echo "==> SIGN_IDENTITY unset — building an UNSIGNED dmg"
fi

# ── Read-write image, so Finder can record the window layout ─────────────────
echo "==> Creating image"
hdiutil create -srcfolder "$STAGE/vol" -volname "$VOLNAME" \
  -fs HFS+ -format UDRW -ov "$RW" -quiet

MOUNT="/Volumes/$VOLNAME"
hdiutil attach "$RW" -readwrite -noverify -noautoopen -quiet
sleep 1

if [ -f packaging/macos/dmg-DS_Store ]; then
  echo "==> Applying recorded window layout"
  cp packaging/macos/dmg-DS_Store "$MOUNT/.DS_Store"
elif [ -n "$BG_NAME" ]; then
  echo "==> Asking Finder to lay the window out"
  # Not fatal: without Automation permission this times out, and the DMG is
  # still perfectly installable, just with a default window.
  osascript <<APPLESCRIPT || echo "    Finder scripting unavailable — DMG will use the default window layout." >&2
    with timeout of 30 seconds
      tell application "Finder"
        tell disk "$VOLNAME"
          open
          set current view of container window to icon view
          set toolbar visible of container window to false
          set statusbar visible of container window to false
          set the bounds of container window to {200, 150, 860, 570}
          set opts to the icon view options of container window
          set arrangement of opts to not arranged
          set icon size of opts to 96
          set background picture of opts to file ".background:$BG_NAME"
          set position of item "$VOLNAME.app" of container window to {165, 210}
          set position of item "Applications" of container window to {495, 210}
          close
          open
          update without registering applications
          delay 2
        end tell
      end tell
    end timeout
APPLESCRIPT
fi

sync
hdiutil detach "$MOUNT" -quiet
MOUNT=""

echo "==> Compressing"
rm -f "$OUT"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" -quiet

# ── Sign + notarize the image itself ─────────────────────────────────────────
if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$OUT"
fi

if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "==> Notarizing (this waits on Apple, usually 1-5 minutes)"
  xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" --wait
  # Stapling the ticket is what makes the DMG open cleanly OFFLINE.
  xcrun stapler staple "$OUT"
  xcrun stapler validate "$OUT"
  echo "==> Gatekeeper assessment"
  spctl -a -t open --context context:primary-signature -vv "$OUT" || true
else
  echo "==> NOTARY_PROFILE unset — not notarized"
fi

echo
echo "Built $OUT"
ls -lh "$OUT"
