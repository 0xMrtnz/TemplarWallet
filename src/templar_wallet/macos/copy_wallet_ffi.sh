#!/bin/sh
# Rebuilds the Rust FFI dylib and bundles it into the built .app so Dart's
# dlopen() finds it at Contents/Frameworks/libwallet_ffi.dylib.
#
# Invoked from the Runner target's "Run Script" build phase, so Xcode build
# vars ($SRCROOT, $BUILT_PRODUCTS_DIR, $CONTENTS_FOLDER_PATH) are in scope.
# $SRCROOT = <repo>/src/templar_wallet/macos  →  repo root = $SRCROOT/../../..
set -e

REPO_ROOT="$SRCROOT/../../.."
CARGO="$HOME/.cargo/bin/cargo"
RUSTUP="$HOME/.cargo/bin/rustup"

# Flutter builds the app universal (arm64 + x86_64); the dylib must match or
# Intel Macs crash at dlopen. Build every architecture whose Rust target is
# installed and lipo them together — with only the host target installed this
# degrades to a host-arch dylib (fine for local dev runs).
SLICES=""
for TARGET in aarch64-apple-darwin x86_64-apple-darwin; do
    if "$RUSTUP" target list --installed 2>/dev/null | grep -q "$TARGET"; then
        "$CARGO" build --release -p wallet-ffi --target "$TARGET" \
            --manifest-path "$REPO_ROOT/Cargo.toml"
        SLICES="$SLICES $REPO_ROOT/target/$TARGET/release/libwallet_ffi.dylib"
    fi
done

DEST="$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH/Frameworks"
mkdir -p "$DEST"

if [ -z "$SLICES" ]; then
    # rustup missing (plain cargo install): host-only build, old behavior.
    "$CARGO" build --release -p wallet-ffi --manifest-path "$REPO_ROOT/Cargo.toml"
    cp "$REPO_ROOT/target/release/libwallet_ffi.dylib" "$DEST/"
else
    lipo -create $SLICES -output "$DEST/libwallet_ffi.dylib"
fi

# Ad-hoc sign so the hardened-runtime app will load it.
codesign --force --sign - "$DEST/libwallet_ffi.dylib"

echo "wallet-ffi: bundled libwallet_ffi.dylib ($(lipo -archs "$DEST/libwallet_ffi.dylib" 2>/dev/null || echo host)) -> $DEST"
