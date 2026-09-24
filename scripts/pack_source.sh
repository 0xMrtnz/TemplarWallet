#!/usr/bin/env bash
# Pack the source tree for a Linux or Windows build on someone else's PC.
#
#   ./scripts/pack_source.sh
#
# Output: dist/TemplarWallet-src-<version>-<commit>[-dirty].zip, plus its
# SHA-256 on the terminal.
#
# What goes in: every tracked file plus the untracked files .gitignore does not
# exclude, as they are in the working tree right now. That is the tree the Mac
# builds its DMG and APKs from, so all four platforms ship the same code,
# uncommitted changes included. Left out: build output, and docs/pdf +
# docs/design (~30 MB of PDFs and mockups that no build step reads).
#
# At the root of the zip, next to the sources:
#   BUILD-ME.txt            what the builder does, in three steps per OS
#   SOURCE-INFO.txt         version, commit, branch, whether the tree was dirty
#   SOURCE-MANIFEST.sha256  one hash per file. build_linux.sh and
#                           build_windows.ps1 check it and write the verdict
#                           into BUILD-INFO, so a build from an edited or stale
#                           tree is visible when the files come back.
#
# See docs/build/HELPER_BUILDS.md.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

VERSION="$(sed -n 's/^version:[[:space:]]*\([^+[:space:]]*\).*/\1/p' src/templar_wallet/pubspec.yaml | head -1)"
[[ -n "$VERSION" ]] || { echo "no version line in src/templar_wallet/pubspec.yaml" >&2; exit 1; }
COMMIT="$(git rev-parse --short=12 HEAD)"
BRANCH="$(git branch --show-current 2>/dev/null || true)"
DIRTY=""
[[ -z "$(git status --porcelain)" ]] || DIRTY="-dirty"
NAME="TemplarWallet-src-$VERSION-$COMMIT$DIRTY"
OUT="$ROOT/dist/$NAME.zip"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
DEST="$STAGE/$NAME"
mkdir -p "$DEST" "$ROOT/dist"

# NUL-separated end to end so names with spaces survive. `-c` also lists
# tracked files deleted in the working tree; the -f test drops those.
git ls-files -z -co --exclude-standard \
  | grep -zvE '^docs/(pdf|design)/' \
  | while IFS= read -r -d '' f; do [[ -f "$f" ]] && printf '%s\0' "$f"; done \
  | LC_ALL=C sort -z > "$STAGE/files"

COUNT="$(tr -cd '\0' < "$STAGE/files" | wc -c | tr -d ' ')"
echo "== $COUNT files from $COMMIT${DIRTY:+ (with uncommitted changes)}"

tar -c --null -T "$STAGE/files" -f - | tar -x -C "$DEST" -f -

# sha256sum -c format ("<hash>  <path>"): readable by sha256sum on Linux,
# shasum -c on macOS, and the parser in build_windows.ps1.
(cd "$DEST" && xargs -0 shasum -a 256 < "$STAGE/files") > "$DEST/SOURCE-MANIFEST.sha256"

cat > "$DEST/SOURCE-INFO.txt" <<INFO
Templar Wallet source bundle
version:  $VERSION
commit:   $COMMIT${DIRTY:+ + uncommitted changes}
branch:   ${BRANCH:-detached}
packed:   $(date -u +%Y-%m-%dT%H:%M:%SZ)
files:    $COUNT (hashes in SOURCE-MANIFEST.sha256)
INFO

cat > "$DEST/BUILD-ME.txt" <<INFO
Templar Wallet $VERSION - how to build it
==========================================

Each script installs or downloads what it needs, builds, and leaves the
results in the "dist" folder next to this file. Send back everything it
lists at the end. If it stops with an error, send the log file it names.

LINUX (x64 PC)
--------------
Needs: Docker or Podman, about 15 GB free disk, a good connection.
Nothing else gets installed on the computer: the build runs in a container.

  1. Unzip this folder anywhere.
  2. In a terminal inside it:   bash scripts/build_linux.sh
     If Docker answers "permission denied":   sudo bash scripts/build_linux.sh
  3. Send back from dist/:
       TemplarWallet-$VERSION-linux-x64.tar.gz
       SHA256SUMS-linux-x64.txt
       BUILD-INFO-linux-x64.txt

The first run downloads a build image (Ubuntu 22.04 + Rust + Flutter, a few
GB) and compiles everything, so it can take an hour. Later runs reuse both.

WINDOWS 10 / 11 (x64 PC)
------------------------
Needs: about 25 GB free disk, a good connection, an account that can approve
installs (UAC prompts).

  1. Right-click the zip > Extract All, to a SHORT path without spaces,
     e.g. C:\\src\\ . Long paths break the Windows C++ build.
  2. Open the extracted folder, then scripts, and double-click
     build_windows.cmd
     It checks for Visual Studio Build Tools (C++), Git and Inno Setup and
     offers to install whatever is missing (one UAC prompt each). Rust and
     Flutter are downloaded into their own folder. If it asks you to turn on
     Developer Mode, do it in the Settings window it opens (Flutter needs it
     for symlinks), then press Enter.
  3. Send back from dist\\:
       TemplarWallet-$VERSION-windows-x64-setup.exe
       TemplarWallet-$VERSION-windows-x64.zip
       SHA256SUMS-windows-x64.txt
       BUILD-INFO-windows-x64.txt

The first run installs about 10 GB of tools and can take an hour or more.

Also paste the contents of the SHA256SUMS file into a chat message, separate
from the files themselves: it lets the owner check the files that arrive are
the files you built.
INFO

rm -f "$OUT"
(cd "$STAGE" && zip -qrX "$OUT" "$NAME")

echo "== $OUT ($(du -h "$OUT" | cut -f1))"
echo "   sha256 $(shasum -a 256 "$OUT" | cut -d' ' -f1)"
echo
echo "Send the zip to the builder. BUILD-ME.txt inside it has the steps."
echo "When files come back:  cd <folder with them> && shasum -a 256 -c SHA256SUMS-*.txt"
