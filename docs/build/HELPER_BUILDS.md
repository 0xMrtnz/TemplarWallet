# Linux and Windows builds on a helper's PC

Releases are built by CI (`RELEASE.md`). These two scripts make the same
Linux and Windows bundles on someone else's PC instead: a test build of work
that is not pushed yet, a second build to compare with CI's, or a build when
CI is unavailable. The helper needs no GitHub access and no knowledge of the
project: they get a zip, run one script, and send the results back.

## The round trip

1. **Pack, on the Mac.**
   ```bash
   ./scripts/pack_source.sh
   ```
   Writes `dist/TemplarWallet-src-<version>-<commit>[-dirty].zip` (about 3 MB)
   from the working tree as it is, uncommitted changes included, so it is the
   same code the DMG and APKs were just built from. `docs/pdf` and
   `docs/design` stay out: no build step reads them. The zip carries
   `BUILD-ME.txt` (the helper's instructions), `SOURCE-INFO.txt` and
   `SOURCE-MANIFEST.sha256`.

2. **Send the zip.** Any channel.

3. **The helper builds.**

   | PC | Command | Needs |
   |---|---|---|
   | Linux x64 | `bash scripts/build_linux.sh` | Docker or Podman |
   | Windows 10/11 x64 | double-click `scripts\build_windows.cmd` | nothing; offers to install the rest |

4. **Files come back**, plus the `SHA256SUMS-*.txt` lines pasted into a chat
   message, separately from the files.

   | From Linux | From Windows |
   |---|---|
   | `TemplarWallet-<v>-linux-x64.tar.gz` | `TemplarWallet-<v>-windows-x64-setup.exe` |
   | | `TemplarWallet-<v>-windows-x64.zip` |
   | `SHA256SUMS-linux-x64.txt` | `SHA256SUMS-windows-x64.txt` |
   | `BUILD-INFO-linux-x64.txt` | `BUILD-INFO-windows-x64.txt` |

5. **Check, on the Mac**, in the folder the files landed in:
   ```bash
   shasum -a 256 -c SHA256SUMS-linux-x64.txt SHA256SUMS-windows-x64.txt
   ```
   The hashes must also match the lines pasted in chat. Then read
   `BUILD-INFO-*.txt`: `source` must name the commit of the zip you sent, and
   `source check` must say `unmodified (N files match ...)`. `MODIFIED` lists
   the first files that differ: a stale folder, or a file the helper edited
   to get past an error. Do not ship that build.

6. **Share them with testers directly.** Do not attach them to a GitHub
   release: a release carries exactly the files CI built, under version-less
   names, with their checksums in `SHA256SUMS.txt`, and the website links to
   them (`RELEASE.md` § 2).

When a build fails, the helper sends `dist/build-linux-x64.log` or
`dist\build-windows-x64.log`: everything the script printed.

## What the scripts do

Both follow the `linux` / `windows` jobs of `.github/workflows/release.yml`
step for step (Rust engine, Flutter app, library copied beside the executable,
`docs/RELEASE_NOTES.md` as `README.md`, packaging), with `--locked` Cargo and
`--enforce-lockfile` pub so the lockfiles decide every dependency version.
Only names and layout differ: the scripts put the version in their file
names and give the tarball and the zip a `TemplarWallet-<version>-…` top
folder, where CI's tarball has `TemplarWallet-linux-x64/` and CI's zip keeps
the files at its root.

**`scripts/build_linux.sh`** builds inside an `ubuntu:22.04` image, the base
CI pins, so the bundle needs glibc 2.35 or newer (Ubuntu 22.04+, Debian 12+)
whatever distro the helper runs. The image holds Rust and Flutter at the
pinned versions, the Flutter archive checked against its published SHA-256.
The source is mounted read-only; build caches live in the Docker volume
`templar-wallet-linux-build`, so a second run only rebuilds what changed;
only `dist/` is written on the host. The image is always `linux/amd64`, so an
ARM host still produces the x64 bundle, slowly. Before packaging, the script
checks that the Rust library exports the symbols Dart looks up and that every
library in the bundle resolves (`ldd`). `BUILD-INFO` records the glibc floor
read from the binaries.

- `--native` skips the container and uses the machine's own toolchain (the
  packages in `LinuxBuild.md`). The glibc floor is then that machine's.
- `--reset` drops the cache volume first.

**`scripts/build_windows.ps1`** (what `build_windows.cmd` runs) checks for
Visual Studio 2022 Build Tools with the C++ workload and C++ CMake tools, Git
and Inno Setup, and offers to install each one that is missing through winget
(`-Yes` installs without asking). Rust comes through rustup at the pinned
toolchain (MSVC); Flutter is a private copy of the pinned SDK under
`%LOCALAPPDATA%\templar-build` (or `C:\templar-build` when the profile path
has a space, which Flutter cannot build from), SHA-256 checked. Neither is
put on PATH. It asks for Developer Mode when it is off, because Flutter links
plugins with symlinks, and warns when the source folder path has spaces or
is long. The file must stay plain ASCII: Windows PowerShell 5.1 reads a
script without a byte-order mark in the ANSI code page.

Space and time on a first run, before caches:

| | Disk | Time |
|---|---|---|
| Linux | about 15 GB, mostly the image | about an hour |
| Windows | about 25 GB, of which Visual Studio Build Tools about 7 GB | an hour or more |

## Pins

Flutter version, the Flutter archive SHA-256 and the Rust toolchain sit at the
top of both scripts; bump them together, and with `FLUTTER_VERSION` and
`RUST_TOOLCHAIN` in `.github/workflows/ci.yml` and `release.yml`. The hashes
come from
`https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json`
and `releases_windows.json`. A new Linux pin changes the image tag, so the next
run builds a fresh image; the old one goes with `docker image rm`.

## Trust

The helper's PC becomes part of the chain that produces these binaries. The
manifest check catches a stale or edited source tree. It does not protect
against a compromised machine, which could also fake the check. That is an
acceptable risk for test builds, and the reason releases come only from CI.
