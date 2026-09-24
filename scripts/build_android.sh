#!/usr/bin/env bash
# Build the Android APKs: Rust engine (.so per ABI) + Flutter app.
#
#   ./scripts/build_android.sh              # debug APKs (sideload / adb install)
#   ./scripts/build_android.sh --release    # release APKs
#   ./scripts/build_android.sh --so-only    # just refresh jniLibs
#   ./scripts/build_android.sh --apk-only   # APKs from the jniLibs already built
#
# One APK per ABI in src/templar_wallet/build/app/outputs/flutter-apk/:
# app-arm64-v8a-<mode>.apk (phones) and app-x86_64-<mode>.apk (emulators).
#
# --release signs with the release key when one is configured (the TEMPLAR_*
# environment variables or android/key.properties, see
# android/app/build.gradle.kts), else with the debug key, and says so.
# CI runs the two halves as separate steps (--so-only, then --apk-only) so
# the key is not in the environment while every crate's build script runs.
#
# Needs an Android SDK ($ANDROID_HOME, else Android Studio's default location
# for this OS), Flutter with the Android toolchain, a JDK 17 and rustup. The
# rest is installed on first use when missing: NDK 28.2.13676358 (through the
# SDK's sdkmanager), cargo-ndk, and the aarch64/x86_64 Android Rust targets.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/src/templar_wallet"
JNI="$APP/android/app/src/main/jniLibs"
# Same version app/build.gradle.kts pins (16 KB page alignment).
NDK_VER="28.2.13676358"
# What gets installed when cargo-ndk is missing; any 4.x builds this.
CARGO_NDK_VER="4.1.2"
MIN_SDK=24
ABIS=(arm64-v8a x86_64)
RUST_TARGETS=(aarch64-linux-android x86_64-linux-android)

MODE=debug; BUILD_SO=1; BUILD_APK=1
for a in "$@"; do
  case "$a" in
    --release) MODE=release ;;
    --debug) MODE=debug ;;
    --so-only) BUILD_APK=0 ;;
    --apk-only) BUILD_SO=0 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done
if (( ! BUILD_SO && ! BUILD_APK )); then
  echo "--so-only and --apk-only exclude each other" >&2; exit 2
fi

if [[ -n "${ANDROID_HOME:-}" ]]; then SDK="$ANDROID_HOME"
elif [[ -n "${ANDROID_SDK_ROOT:-}" ]]; then SDK="$ANDROID_SDK_ROOT"
elif [[ "$(uname -s)" == Darwin ]]; then SDK="$HOME/Library/Android/sdk"
else SDK="$HOME/Android/Sdk"
fi

# "28.2.13676358" for an NDK directory, empty for anything else.
ndk_release() {
  sed -n 's/^Pkg\.Revision[[:space:]]*=[[:space:]]*//p' "$1/source.properties" 2>/dev/null || true
}

sdkmanager_path() {
  local c
  for c in "$SDK/cmdline-tools/latest/bin/sdkmanager" "$SDK"/cmdline-tools/*/bin/sdkmanager; do
    if [[ -x "$c" ]]; then echo "$c"; return 0; fi
  done
  command -v sdkmanager || true
}

# Exactly NDK $NDK_VER, whatever else is installed. An ANDROID_NDK_HOME that
# names another release is overridden: GitHub's Ubuntu runners preset it (and
# ANDROID_NDK_ROOT) to their default NDK, which is not this one.
if [[ -n "${ANDROID_NDK_HOME:-}" && "$(ndk_release "$ANDROID_NDK_HOME")" == "$NDK_VER" ]]; then
  NDK="$ANDROID_NDK_HOME"
else
  NDK="$SDK/ndk/$NDK_VER"
  if [[ ! -d "$NDK" ]]; then
    SDKMANAGER="$(sdkmanager_path)"
    if [[ -z "$SDKMANAGER" ]]; then
      echo "NDK $NDK_VER not found under $SDK/ndk, and no sdkmanager to install it with." >&2
      echo "Install it in Android Studio (Settings > Languages & Frameworks > Android SDK >" >&2
      echo "SDK Tools > NDK (Side by side), $NDK_VER), or point ANDROID_HOME at an SDK that has it." >&2
      exit 1
    fi
    echo "== installing NDK $NDK_VER ($SDKMANAGER)"
    # No `yes |`: under pipefail its SIGPIPE would fail the step. The licence
    # is accepted on CI runners; elsewhere `sdkmanager --licenses` does it.
    "$SDKMANAGER" --install "ndk;$NDK_VER" </dev/null
  fi
  if [[ "$(ndk_release "$NDK")" != "$NDK_VER" ]]; then
    echo "no NDK $NDK_VER at $NDK" >&2; exit 1
  fi
fi
# cargo-ndk takes the first of these that is set, and warns when they differ.
export ANDROID_NDK_HOME="$NDK" ANDROID_NDK_ROOT="$NDK"
echo "== NDK: $ANDROID_NDK_HOME"

if (( BUILD_SO )); then
  if ! cargo ndk --version >/dev/null 2>&1; then
    echo "== installing cargo-ndk $CARGO_NDK_VER"
    cargo install cargo-ndk --locked --version "$CARGO_NDK_VER"
  fi
  if command -v rustup >/dev/null; then
    installed="$(cd "$ROOT" && rustup target list --installed)"
    for t in "${RUST_TARGETS[@]}"; do
      if ! grep -qx "$t" <<<"$installed"; then
        echo "== adding Rust target $t"
        (cd "$ROOT" && rustup target add "$t")
      fi
    done
  fi

  # The USB hardware stack (hidapi, serialport, Jade, Ledger) does not build or
  # run on Android: --no-default-features leaves it out; QR air-gap stays.
  echo "== cargo ndk ($MODE): ${ABIS[*]} → $JNI"
  CARGO_ARGS=(build -p wallet-ffi --no-default-features)
  # CI builds exactly what Cargo.lock says; a stale lockfile fails there
  # instead of being rewritten.
  if [[ -n "${CI:-}" ]]; then CARGO_ARGS+=(--locked); fi
  if [[ "$MODE" == release ]]; then
    CARGO_ARGS+=(--release)
  else
    # A debug .so with full DWARF is ~270 MB per ABI and nothing on Android
    # reads it (no native debugger in this workflow). Keep symbols, drop
    # debuginfo: the APK stays installable in seconds instead of minutes.
    export CARGO_PROFILE_DEV_STRIP=debuginfo
  fi
  NDK_TARGETS=()
  for abi in "${ABIS[@]}"; do NDK_TARGETS+=(-t "$abi"); done
  (cd "$ROOT" && cargo ndk "${NDK_TARGETS[@]}" --platform "$MIN_SDK" -o "$JNI" "${CARGO_ARGS[@]}")

  # cargo-ndk copies every .so it finds in the target dir; only ours is loaded
  # (libwallet_ffi.so needs nothing beyond libc/libm/libdl), the rest is bloat.
  for abi in "${ABIS[@]}"; do
    find "$JNI/$abi" -name '*.so' ! -name 'libwallet_ffi.so' -delete
  done
fi

# The C ABI must have survived the link: Dart looks these up by name. Checked
# on every run, so --apk-only never packages missing or stale-named libraries.
NMS=("$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/bin/llvm-nm)
NM="${NMS[0]}"
[[ -x "$NM" ]] || { echo "no llvm-nm in $ANDROID_NDK_HOME" >&2; exit 1; }
for abi in "${ABIS[@]}"; do
  so="$JNI/$abi/libwallet_ffi.so"
  [[ -f "$so" ]] || { echo "missing $so (build it: --so-only)" >&2; exit 1; }
  symbols="$("$NM" -D "$so")"
  for sym in wallet_call wallet_free_string wallet_set_data_dir; do
    grep -q " T $sym\$" <<<"$symbols" || { echo "$so: symbol $sym not exported" >&2; exit 1; }
  done
  printf '   %-10s %s  (%s)\n' "$abi" "$so" "$(du -h "$so" | cut -f1)"
done
(( BUILD_APK )) || exit 0

# One APK per ABI: a phone only ever needs arm64-v8a, and a fat debug APK
# (three libflutter ABIs + two engines) is ~300 MB — too big for a full
# phone and slow over USB. ABIs limited to the ones jniLibs carries.
echo "== flutter build apk --$MODE --split-per-abi"
PUB_ARGS=(pub get)
# In CI pubspec.lock decides every package version, as in the desktop builds.
if [[ -n "${CI:-}" ]]; then PUB_ARGS+=(--enforce-lockfile); fi
(cd "$APP" && flutter "${PUB_ARGS[@]}" >/dev/null \
  && flutter build apk "--$MODE" --split-per-abi --target-platform android-arm64,android-x64)
OUT_DIR="$APP/build/app/outputs/flutter-apk"
for abi in "${ABIS[@]}"; do
  apk="$OUT_DIR/app-$abi-$MODE.apk"
  [[ -f "$apk" ]] || { echo "APK not found at $apk" >&2; exit 1; }
  printf '== APK %-10s %5s  %s\n' "$abi" "$(du -h "$apk" | cut -f1)" "$apk"
done
echo "   phone:    adb install -r \"$OUT_DIR/app-arm64-v8a-$MODE.apk\""
echo "   emulator: adb install -r \"$OUT_DIR/app-<abi of the AVD>-$MODE.apk\""
