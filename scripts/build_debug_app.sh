#!/usr/bin/env bash
# Build the Flutter macOS app (debug) and drop it on the Desktop as
# "Templar Wallet Debug.app" for quick manual verification after a change.
#
# Same bundle id as the release build, so it opens the REAL vault (not a
# TEMPLAR_DATA_DIR scratch dir) — run only one Templar instance at a time
# (single-process sled lock). The Xcode Run Script phase builds and bundles
# libwallet_ffi.dylib, so this picks up Rust changes too.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/src/templar_wallet"
flutter pub get >/dev/null
flutter build macos --debug
SRC="build/macos/Build/Products/Debug/templar_wallet.app"
DEST="$HOME/Desktop/Templar Wallet Debug.app"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"
BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
COMMIT="$(git -C "$ROOT" rev-parse --short HEAD)"
echo "Built Templar Wallet Debug from $BRANCH @ $COMMIT"
echo "→ $DEST"
