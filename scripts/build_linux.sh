#!/usr/bin/env bash
# Build the Linux x64 bundle of Templar Wallet on any Linux PC.
#
#   bash scripts/build_linux.sh            # inside a container (default)
#   bash scripts/build_linux.sh --native   # with this machine's own toolchain
#   bash scripts/build_linux.sh --reset    # drop the build cache volume first
#
# Output in dist/:
#   TemplarWallet-<version>-linux-x64.tar.gz   unpack, run ./templar_wallet
#   SHA256SUMS-linux-x64.txt                   checksum of the tarball
#   BUILD-INFO-linux-x64.txt                   source check, toolchain, glibc floor
#   build-linux-x64.log                        everything printed, for failures
#
# WHY A CONTAINER. A Linux binary runs only where glibc is at least as new as
# the one it was linked against. The image is Ubuntu 22.04 (glibc 2.35), the
# same base CI pins, so the bundle runs on Ubuntu 22.04+ and Debian 12+
# whatever distro the builder has. It also leaves the host alone: the
# toolchain lives in the image, caches in the named volume below, the source
# is mounted read-only, and only dist/ is written. Docker or Podman both work.
# The image is always linux/amd64: on an ARM host it runs emulated (slow) and
# still produces the x64 bundle.
#
# --native uses Rust, Flutter 3.44.1 and the packages from
# docs/build/LinuxBuild.md as installed on this machine, and writes target/
# and build/ into the source tree. The bundle then needs this machine's glibc
# or newer; BUILD-INFO names the floor.
#
# See docs/build/HELPER_BUILDS.md.
set -euo pipefail

# Keep in step with scripts/build_windows.ps1 and with FLUTTER_VERSION and
# RUST_TOOLCHAIN in .github/workflows/ci.yml and release.yml.
FLUTTER_VERSION="3.44.1"
# releases_linux.json on storage.googleapis.com/flutter_infra_release
FLUTTER_SHA256="287937458126a53284ed112c8c7dbc647bea2d09ab65d46e2d5cf94e901aac69"
RUST_TOOLCHAIN="1.95.0"
BASE_IMAGE="ubuntu:22.04"
IMAGE="templar-wallet-linux-build:flutter$FLUTTER_VERSION-rust$RUST_TOOLCHAIN"
VOLUME="templar-wallet-linux-build"
LABEL="linux-x64"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MODE=container; RESET=0
for a in "$@"; do
  case "$a" in
    --native) MODE=native ;;
    --reset) RESET=1 ;;
    --in-container) MODE=inside ;;   # internal: the half that runs in the image
    -h|--help) sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $a (try --help)" >&2; exit 2 ;;
  esac
done

say() { printf '\n== %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

app_version() {
  sed -n 's/^version:[[:space:]]*\([^+[:space:]]*\).*/\1/p' "$1/src/templar_wallet/pubspec.yaml" | head -1
}

# The line of `flutter --version` that names the version ("Flutter 3.44.1 •
# channel stable • …"). The output is read whole, never piped into head:
# once a day Flutter opens with a "new version available" banner, so head
# took the banner, and flutter, still writing to the closed pipe, exited 255,
# which under pipefail ended the whole build.
flutter_version_line() {
  local out line
  out="$(flutter --version 2>/dev/null)" || true
  while IFS= read -r line; do
    if [[ "$line" == "Flutter "* ]]; then
      printf '%s\n' "$line"
      return 0
    fi
  done <<<"$out"
  echo "Flutter (version unknown)"
}

# ── The build itself: the same steps as the linux job of release.yml ────────
# $1 source tree (built in place), $2 output dir, $3 build-host description,
# $4 the pristine source to check against the manifest (defaults to $1).
build_bundle() {
  local src="$1" out="$2" host="$3" pristine="${4:-$1}"
  local app="$src/src/templar_wallet"
  local version; version="$(app_version "$src")"
  [[ -n "$version" ]] || die "no version line in src/templar_wallet/pubspec.yaml"
  local cargo=(cargo)
  [[ -n "${CARGO_TOOLCHAIN:-}" ]] && cargo=(cargo "+$CARGO_TOOLCHAIN")

  say "source check"
  local source_line check_line
  source_line="$(source_description "$pristine")"
  check_line="$(manifest_check "$pristine")"
  echo "   source: $source_line"
  echo "   check:  $check_line"

  say "toolchain"
  "${cargo[@]}" --version
  rustc ${CARGO_TOOLCHAIN:++$CARGO_TOOLCHAIN} --version
  flutter_version_line

  say "Rust engine: cargo build --release -p wallet-ffi"
  (cd "$src" && "${cargo[@]}" build --release --locked -p wallet-ffi)
  local so="${CARGO_TARGET_DIR:-$src/target}/release/libwallet_ffi.so"
  [[ -f "$so" ]] || die "cargo finished but $so is missing"
  # Dart looks these up by name; a link that dropped them fails at launch.
  # (Read once, not piped into grep -q, which can close the pipe on nm.)
  local sym exports
  exports="$(nm -D --defined-only "$so")"
  for sym in wallet_call wallet_free_string wallet_set_data_dir; do
    grep -qE " T $sym\$" <<<"$exports" || die "$so does not export $sym"
  done

  say "Flutter app: flutter build linux --release"
  (cd "$app" && flutter pub get --enforce-lockfile && flutter build linux --release)
  local bundle="$app/build/linux/x64/release/bundle"
  [[ -x "$bundle/templar_wallet" ]] || die "flutter finished but $bundle/templar_wallet is missing"

  say "bundle"
  # The Dart loader looks for <exe dir>/lib/libwallet_ffi.so.
  cp "$so" "$bundle/lib/"
  cp "$src/docs/RELEASE_NOTES.md" "$bundle/README.md"
  cp "$src/packaging/linux/dev.templarwallet.templar_wallet.desktop" "$bundle/"

  # Every library the app loads must resolve on this system: a missing one
  # is a launch failure on every machine, not just this one.
  local missing
  missing="$(cd "$bundle" && LD_LIBRARY_PATH="$bundle/lib" ldd templar_wallet lib/*.so 2>&1 | grep 'not found' || true)"
  [[ -z "$missing" ]] || die "unresolved libraries in the bundle:
$missing"

  # The newest glibc symbol any binary in the bundle asks for = the oldest
  # glibc the bundle runs on.
  local glibc
  glibc="$(cd "$bundle" && objdump -T templar_wallet lib/*.so 2>/dev/null \
    | grep -o 'GLIBC_[0-9][0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -1)"

  local name="TemplarWallet-$version-$LABEL"
  mkdir -p "$out"
  rm -f "$out/$name.tar.gz"
  tar -C "$(dirname "$bundle")" --transform "s,^bundle,$name," \
      --sort=name --owner=0 --group=0 --numeric-owner \
      -czf "$out/$name.tar.gz" bundle
  (cd "$out" && sha256sum "$name.tar.gz" > "SHA256SUMS-$LABEL.txt")

  cat > "$out/BUILD-INFO-$LABEL.txt" <<INFO
Templar Wallet build ($LABEL)
version:       $version
source:        $source_line
source check:  $check_line
built:         $(date -u +%Y-%m-%dT%H:%M:%SZ)
build host:    $host
rust:          $(rustc ${CARGO_TOOLCHAIN:++$CARGO_TOOLCHAIN} --version)
flutter:       $(flutter_version_line)
glibc needed:  ${glibc:-unknown} or newer
sha256:        $(cut -d' ' -f1 "$out/SHA256SUMS-$LABEL.txt")  $name.tar.gz
INFO

  say "done"
  echo "   $out/$name.tar.gz ($(du -h "$out/$name.tar.gz" | cut -f1))"
  echo "   runs on glibc ${glibc:-?}+"
  echo "   check: $check_line"
}

# "d821497589b3 + uncommitted changes (branch feature/android)" from the
# source bundle, or the git state of a clone.
source_description() {
  local src="$1"
  if [[ -f "$src/SOURCE-INFO.txt" ]]; then
    local commit branch
    commit="$(sed -n 's/^commit:[[:space:]]*//p' "$src/SOURCE-INFO.txt")"
    branch="$(sed -n 's/^branch:[[:space:]]*//p' "$src/SOURCE-INFO.txt")"
    echo "bundle $commit (branch $branch)"
  elif git -C "$src" rev-parse --git-dir >/dev/null 2>&1; then
    local dirty=""
    [[ -z "$(git -C "$src" status --porcelain 2>/dev/null)" ]] || dirty=" + uncommitted changes"
    echo "git $(git -C "$src" rev-parse --short=12 HEAD)$dirty"
  else
    echo "unknown (no SOURCE-INFO.txt, not a git checkout)"
  fi
}

manifest_check() {
  local src="$1" manifest="$1/SOURCE-MANIFEST.sha256"
  [[ -f "$manifest" ]] || { echo "not checked (no SOURCE-MANIFEST.sha256)"; return; }
  local total bad
  total="$(grep -c . "$manifest")"
  bad="$(cd "$src" && sha256sum -c --quiet SOURCE-MANIFEST.sha256 2>/dev/null | sed -n 's/: FAILED.*$//p' || true)"
  if [[ -z "$bad" ]]; then
    echo "unmodified ($total files match SOURCE-MANIFEST.sha256)"
  else
    echo "MODIFIED: $(printf '%s\n' "$bad" | wc -l | tr -d ' ') of $total files differ or are missing: $(printf '%s\n' "$bad" | head -5 | paste -sd' ' -)"
  fi
}

# ── Inside the image ─────────────────────────────────────────────────────────
if [[ "$MODE" == inside ]]; then
  # /src read-only source, /work cache volume, /out the host's dist/.
  export CARGO_HOME=/work/cargo-home PUB_CACHE=/work/pub-cache
  mkdir -p /work/src "$CARGO_HOME" "$PUB_CACHE"
  say "sync source into the build volume"
  # --delete mirrors the sources; excluded build output is kept, which is
  # what makes the second run incremental.
  rsync -a --delete \
    --exclude=/.git/ --exclude=/target/ --exclude=/dist/ \
    --exclude=/src/templar_wallet/build/ --exclude=.dart_tool/ \
    --exclude=/src/templar_wallet/linux/flutter/ephemeral/ \
    /src/ /work/src/
  # A crash anywhere still hands the files already written back to the host
  # user instead of leaving them owned by root.
  if [[ -n "${HOST_UID:-}" ]]; then
    trap 'chown -R "$HOST_UID:${HOST_GID:-$HOST_UID}" /out 2>/dev/null || true' EXIT
  fi
  build_bundle /work/src /out "container $BASE_IMAGE ($(uname -m))" /src
  exit 0
fi

# ── On the host ──────────────────────────────────────────────────────────────
mkdir -p "$ROOT/dist"
LOG="$ROOT/dist/build-$LABEL.log"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1
echo "Templar Wallet $LABEL build, $(date -u +%Y-%m-%dT%H:%M:%SZ), log: $LOG"

if [[ "$MODE" == native ]]; then
  need=()
  for tool in cargo rustc flutter clang cmake ninja pkg-config nm objdump ldd sha256sum; do
    command -v "$tool" >/dev/null || need+=("$tool")
  done
  pkg-config --exists gtk+-3.0 2>/dev/null || need+=("gtk+-3.0 headers")
  pkg-config --exists libudev 2>/dev/null || need+=("libudev headers")
  if (( ${#need[@]} )); then
    die "missing: ${need[*]}
On Debian/Ubuntu:
  sudo apt install -y build-essential clang cmake ninja-build pkg-config \\
    libgtk-3-dev liblzma-dev libstdc++-12-dev libudev-dev curl git unzip xz-utils zip
Rust: https://rustup.rs   Flutter $FLUTTER_VERSION: https://docs.flutter.dev/install/archive
Or skip all of this and run without --native (needs only Docker)."
  fi
  have_flutter="$(flutter_version_line)"
  have_flutter="${have_flutter#Flutter }"
  have_flutter="${have_flutter%% *}"
  [[ "$have_flutter" == "$FLUTTER_VERSION" ]] \
    || echo "WARNING: Flutter $have_flutter here, the project pins $FLUTTER_VERSION."
  if command -v rustup >/dev/null; then
    rustup toolchain install "$RUST_TOOLCHAIN" --profile minimal
    export CARGO_TOOLCHAIN="$RUST_TOOLCHAIN"
  else
    echo "WARNING: no rustup; building with $(rustc --version), the project pins $RUST_TOOLCHAIN."
  fi
  distro="$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || uname -sr)"
  build_bundle "$ROOT" "$ROOT/dist" "native $distro ($(uname -m))"
  exit 0
fi

command -v docker >/dev/null || die "Docker is not installed.
  Ubuntu/Debian:  sudo apt install -y docker.io
  Fedora:         sudo dnf install -y podman podman-docker
Then run this again. (Or build without a container: --native.)"
docker info >/dev/null 2>&1 || die "Docker is installed but not reachable.
If it says permission denied, either run:  sudo bash scripts/build_linux.sh
or add yourself to the docker group once:  sudo usermod -aG docker \$USER  (then log out and in).
If the daemon is stopped:  sudo systemctl start docker"

if (( RESET )); then
  say "dropping build cache volume $VOLUME"
  docker volume rm -f "$VOLUME" >/dev/null || true
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  say "building image $IMAGE (once; a few GB of downloads)"
  docker build --platform linux/amd64 -t "$IMAGE" \
    --build-arg "BASE_IMAGE=$BASE_IMAGE" \
    --build-arg "FLUTTER_VERSION=$FLUTTER_VERSION" \
    --build-arg "FLUTTER_SHA256=$FLUTTER_SHA256" \
    --build-arg "RUST_TOOLCHAIN=$RUST_TOOLCHAIN" \
    - <<'DOCKERFILE'
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
ARG FLUTTER_VERSION
ARG FLUTTER_SHA256
ARG RUST_TOOLCHAIN
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    RUSTUP_HOME=/opt/rustup \
    CARGO_HOME=/opt/cargo \
    PATH=/opt/cargo/bin:/opt/flutter/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Flutter's Linux desktop list plus libudev (hidapi/serialport USB ids).
RUN apt-get update \
 && apt-get install -y \
      build-essential clang cmake ninja-build pkg-config \
      libgtk-3-dev liblzma-dev libstdc++-12-dev libudev-dev \
      binutils ca-certificates curl file git rsync unzip xz-utils zip \
 && rm -rf /var/lib/apt/lists/*
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --no-modify-path --profile minimal --default-toolchain "${RUST_TOOLCHAIN}" \
 && rustc --version
RUN curl -fsSL -o /tmp/flutter.tar.xz \
      "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
 && echo "${FLUTTER_SHA256}  /tmp/flutter.tar.xz" | sha256sum -c - \
 && tar -xJf /tmp/flutter.tar.xz -C /opt \
 && rm /tmp/flutter.tar.xz \
 && git config --system --add safe.directory '*' \
 && flutter config --no-analytics \
 && flutter precache --linux \
 && flutter --version
DOCKERFILE
fi

# Hand dist/ back to the calling user, except under rootless engines, where
# root in the container already is that user and a chown would map the
# files to a subordinate uid instead.
HOST_ENV=()
if ! docker --version 2>/dev/null | grep -qi podman \
   && ! docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless; then
  HOST_ENV=(-e "HOST_UID=${SUDO_UID:-$(id -u)}" -e "HOST_GID=${SUDO_GID:-$(id -g)}")
fi

say "building in the container (cache volume: $VOLUME)"
# --init forwards Ctrl+C to the build; z relabels the mounts for SELinux
# hosts (Fedora) and is ignored everywhere else.
docker run --rm --init --platform linux/amd64 \
  -v "$ROOT:/src:ro,z" \
  -v "$VOLUME:/work" \
  -v "$ROOT/dist:/out:z" \
  ${HOST_ENV[@]+"${HOST_ENV[@]}"} \
  "$IMAGE" bash /src/scripts/build_linux.sh --in-container

echo
echo "Send back these files from $ROOT/dist:"
for f in "$ROOT"/dist/TemplarWallet-*-"$LABEL".tar.gz "$ROOT/dist/SHA256SUMS-$LABEL.txt" "$ROOT/dist/BUILD-INFO-$LABEL.txt"; do
  [[ -f "$f" ]] && echo "   $(basename "$f")"
done
echo "And paste the SHA256SUMS line into a chat message too:"
cat "$ROOT/dist/SHA256SUMS-$LABEL.txt"
