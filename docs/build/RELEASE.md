# Releasing Templar Wallet

How a version goes from this tree to the download links on the website: one
tag, one CI run, one GitHub release whose files keep the same names from
version to version.

> **The short version:** bump the version, write its CHANGELOG section, push a
> `vX.Y.Z` tag. `.github/workflows/release.yml` builds macOS, Windows, Linux
> and Android on GitHub-hosted runners and, only if every build succeeds,
> publishes the release. The website's links (§ 2) then serve the new files
> without anyone touching the site.

---

## 1. Cut a release

1. **Pick the version.** A plain `X.Y.Z` is a public release. A suffix
   (`X.Y.Z-rc.1`) makes a pre-release: built and published the same way, but
   the website's links keep serving the last plain `X.Y.Z` (§ 3).
2. **Bump it** in `src/templar_wallet/pubspec.yaml`:
   ```yaml
   version: 0.1.1+17
   ```
   The number after `+` is Android's `versionCode` and must be higher than
   the last release's: Android refuses an update whose code is not. (Each
   split APK's code is derived from it: `2000 + N` for arm64, `4000 + N` for
   x86_64.)
3. **Write the CHANGELOG section** at the top of `CHANGELOG.md`:
   ```markdown
   ## [0.1.1] — 2026-10-15

   One or two sentences on what this version is about.

   ### Fixes

   - …
   ```
   Its body becomes the release notes. The workflow finds it by the heading,
   `## [X.Y.Z]` (plain `## X.Y.Z` works too), and takes everything up to the
   next `## ` heading. Without a section the release says only "see
   CHANGELOG.md", and the run shows a warning.
4. **Update `docs/RELEASE_NOTES.md`.** It ships inside the Linux tarball and
   the Windows zip and installer as `README.md`; check that its install steps
   and file names still match § 2.
5. **Run the checks** CI will run (`.github/workflows/ci.yml`):
   ```bash
   cargo fmt --all -- --check
   cargo clippy --locked -p templar-core -p wallet-ffi --all-targets -- -D warnings
   cargo test --locked -p templar-core -p wallet-ffi
   cd src/templar_wallet && flutter analyze && flutter test
   ```
   CI runs clippy with the Rust version pinned in the workflows
   (`RUST_TOOLCHAIN`); run it with that one, since a newer clippy may know
   lints the pinned one does not.
6. **Commit, push to `main`**, and wait for the `ci` run to go green.
7. **Tag and push the tag:**
   ```bash
   git tag -a v0.1.1 -m "Templar Wallet 0.1.1"
   git push origin v0.1.1
   ```
   The tag must be exactly `v` plus the pubspec version without its `+N`. The
   workflow checks that first and stops, before building anything, if they
   differ.
8. **Watch Actions → release** (about 40 minutes). Once every build has
   passed, the release appears on the Releases page, published and marked
   *Latest*, with the seven files of § 2.
9. **Check it from the outside:** download through the stable links, check
   the files against `SHA256SUMS.txt`, install on at least one machine per
   platform (§ 8).

### When the run fails

Nothing is published unless every platform built; the site's links keep
serving the previous release meanwhile.

- **A flaky job** (network, a runner hiccup): *Re-run failed jobs* on the run
  page. The release job runs as soon as everything before it is green.
- **A real bug:** fix it on `main`, then move the tag to the fixed commit:
  ```bash
  git push --delete origin v0.1.1 && git tag -d v0.1.1
  git tag -a v0.1.1 -m "Templar Wallet 0.1.1" && git push origin v0.1.1
  ```
  That is only fine while nothing is published for that tag. A published
  version is never reused: its files are on people's disks and their
  checksums on the web. The workflow refuses to replace a published release;
  bump the version instead.
- A draft left behind by an interrupted attempt is deleted and recreated by
  the next one, automatically.

---

## 2. The download links

The website links to these. They never change; each always serves the newest
published, non-pre-release version:

| For | Link |
|---|---|
| macOS, Apple silicon and Intel | <https://github.com/0xB4LdW1n/TemplarWallet/releases/latest/download/TemplarWallet-macos.dmg> |
| Windows x64, installer | <https://github.com/0xB4LdW1n/TemplarWallet/releases/latest/download/TemplarWallet-windows-x64-setup.exe> |
| Windows x64, portable | <https://github.com/0xB4LdW1n/TemplarWallet/releases/latest/download/TemplarWallet-windows-x64.zip> |
| Linux x64 | <https://github.com/0xB4LdW1n/TemplarWallet/releases/latest/download/TemplarWallet-linux-x64.tar.gz> |
| Android phones (arm64) | <https://github.com/0xB4LdW1n/TemplarWallet/releases/latest/download/TemplarWallet-android-arm64.apk> |
| Android emulators, x86_64 Chromebooks | <https://github.com/0xB4LdW1n/TemplarWallet/releases/latest/download/TemplarWallet-android-x86_64.apk> |
| SHA-256 of all six | <https://github.com/0xB4LdW1n/TemplarWallet/releases/latest/download/SHA256SUMS.txt> |

The release page itself: <https://github.com/0xB4LdW1n/TemplarWallet/releases/latest>.
A specific version's file: `…/releases/download/vX.Y.Z/<file>`.

What is inside:

- **DMG:** `Templar Wallet.app`, universal (arm64 + x86_64), next to an
  Applications link. Not notarized yet (§ 6).
- **Windows zip:** the app folder with the files at the zip's root: extract
  it all, run `templar_wallet.exe`. It registers nothing, so `templar://`
  links need the installer.
- **Windows installer:** the same app, a wizard that asks where the program
  and the wallet data go (§ 5), `templar://` registration. Not code-signed
  yet (§ 6).
- **Linux tarball:** one folder, `TemplarWallet-linux-x64/`, with the
  `.desktop` entry for `templar://` links:
  `tar xzf TemplarWallet-linux-x64.tar.gz && ./TemplarWallet-linux-x64/templar_wallet`.
  Built on Ubuntu 22.04: needs glibc 2.35 or newer. No signing authority
  exists for Linux, so nothing warns.
- **APKs:** one per ABI, signed with the release key (§ 4). Its certificate's
  SHA-256 is printed in every release's notes.

---

## 3. What the workflows do

| Workflow | Runs on | Does |
|---|---|---|
| `ci.yml` | every push to `main`; every pull request, forks included; by hand | rustfmt, clippy `-D warnings`, `cargo test`, `flutter analyze` (fatal on infos), `flutter test`. Read-only token, no secrets. |
| `release.yml` | a `v*` tag push; by hand (Actions → release → *Run workflow*) | the checks above, then the five builds, then, for a tag (or a manual run with *draft*), the release |

The jobs of `release.yml`:

| Job | Runner | Makes |
|---|---|---|
| `version` | ubuntu-24.04 | reads the version from `pubspec.yaml`; fails a tag that does not match it |
| `checks` | (runs `ci.yml`) | the gate: no build starts before it passes |
| `macos` | macos-26 | `TemplarWallet-macos.dmg`; fails unless both the app and `libwallet_ffi.dylib` are universal |
| `android` | ubuntu-24.04 | both APKs; the Rust engine is built in a step that never sees the signing key |
| `linux` | ubuntu-22.04 | `TemplarWallet-linux-x64.tar.gz` |
| `windows` | windows-2025 | the installer (Inno Setup, installed if the image lacks it) and the zip |
| `release` | ubuntu-24.04 | `SHA256SUMS.txt`, the notes, the release. The only job that can write to the repository. |

Worth knowing:

- **All or nothing.** The release job needs every build to succeed. It then
  checks that all six files are there, and `gh release create` uploads them
  to a draft that is published only once every upload succeeded.
- **Release notes** are the CHANGELOG section's body, a table of the stable
  links, and the Android certificate fingerprint.
- **Pre-releases.** A tag with a suffix publishes a pre-release. It is never
  *Latest*, so the site's links do not move; its notes link to its own files.
- **An older line.** A plain tag lower than the current *Latest* (a fix for an
  older version, published after a newer one) is published without becoming
  *Latest*, so the site keeps serving the newest version.
- **Manual runs** build everything and attach the files to the run (run page →
  *Summary* → *Artifacts*) under the same names. Without the signing secrets
  the APKs carry a throwaway debug key and the run says so. Tick *draft* to
  also get a draft release, visible to maintainers only, to look over the page
  before tagging. Do not publish that draft by hand: push the tag; the tag
  build replaces the draft.
- **No caches in the builds.** A release is compiled from `Cargo.lock` and
  `pubspec.lock` alone, so nothing a cache entry carries can end up in a
  published binary or run next to the signing key. The gate (`ci.yml`) does
  use caches, which only makes it faster.
- **Hosted runners only.** Every job runs on a GitHub-hosted runner, free for a
  public repository. Never attach a self-hosted runner to this repository: a
  pull request from a fork could run code on it.
- **Pinned actions.** Third-party actions are pinned to a full commit SHA with
  the release named in a comment. To update one, resolve the new tag to its
  commit, dereferencing an annotated tag:
  `gh api repos/<owner>/<repo>/git/ref/tags/<tag>` (if `object.type` is
  `tag`, follow `gh api repos/<owner>/<repo>/git/tags/<sha>`).
- **Pinned toolchains.** `FLUTTER_VERSION` and `RUST_TOOLCHAIN` sit at the top
  of both workflows; `scripts/build_linux.sh` and `scripts/build_windows.ps1`
  carry the same pins. Bump all four together.
- **The Linux image has a deadline.** GitHub retires `ubuntu-22.04` on
  2027-04-17, with brownout days (jobs fail) in March and April 2027. Before
  then, move the `linux` job to `ubuntu-24.04` building inside an
  `ubuntu:22.04` container, the same base `scripts/build_linux.sh` uses, so
  the glibc floor stays at 2.35.

---

## 4. The Android signing key

Android installs an update only when it is signed with the same key as the
app already on the device. Every published APK must therefore carry one and
the same key for as long as the app exists, never a debug key: a CI runner
makes a fresh debug key per run, and an APK signed with one could never be
updated by the next release.

### 4a. Create the key, once

```bash
keytool -genkeypair -v -keystore ~/templar-upload.jks -storetype PKCS12 \
  -keyalg RSA -keysize 4096 -validity 10000 -alias templar \
  -dname "CN=Templar Wallet"
```

`keytool` asks for a password. A PKCS12 keystore uses that one password for
the key as well, so the keystore and key passwords below are the same.

Keep the `.jks` and its password in two places at least, offline (a password
manager plus an encrypted backup). If they are lost, no installed copy can
ever be updated again: every user would have to uninstall and restore from
their recovery phrase. Never commit the file; `android/.gitignore` ignores
`*.jks`, `*.keystore`, `*.p12` and `key.properties` under `android/`, but
keeping the key outside the repository altogether is safer.

### 4b. Give it to CI

Four repository secrets (*Settings → Secrets and variables → Actions*, or
`gh`):

| Secret | Value |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | the `.jks` file, base64-encoded |
| `ANDROID_KEYSTORE_PASSWORD` | the keystore password |
| `ANDROID_KEY_ALIAS` | `templar` (the `-alias` above) |
| `ANDROID_KEY_PASSWORD` | the key password; for PKCS12, the keystore password again |

```bash
R=0xB4LdW1n/TemplarWallet
base64 -i ~/templar-upload.jks | gh secret set ANDROID_KEYSTORE_BASE64 -R $R   # macOS
# Linux: base64 -w0 ~/templar-upload.jks | gh secret set ANDROID_KEYSTORE_BASE64 -R $R
gh secret set ANDROID_KEYSTORE_PASSWORD -R $R      # prompts for the value
gh secret set ANDROID_KEY_ALIAS -R $R --body templar
gh secret set ANDROID_KEY_PASSWORD -R $R           # prompts for the value
gh secret list -R $R
```

Line breaks in the base64 value do no harm; CI strips whitespace before
decoding.

How CI uses them: the `android` job decodes the keystore into the runner's
temp folder in the one step that builds the APKs, hands it to Gradle through
the `TEMPLAR_*` variables, and deletes it when the step ends. The Rust build
runs in an earlier step without them, and pull requests never get them. A
tag build without all four fails before it builds anything; after the build
it checks that both APKs carry the same certificate and that it is not a
debug one.

### 4c. Release builds on your machine

`./scripts/build_android.sh --release` signs with the release key when Gradle
finds one (`src/templar_wallet/android/app/build.gradle.kts`), looking in:

1. the environment: `TEMPLAR_KEYSTORE_PATH`, `TEMPLAR_KEYSTORE_PASSWORD`,
   `TEMPLAR_KEY_ALIAS`, `TEMPLAR_KEY_PASSWORD`;
2. `src/templar_wallet/android/key.properties` (gitignored, Flutter's
   format):
   ```properties
   storeFile=/Users/you/keys/templar-upload.jks
   storePassword=…
   keyAlias=templar
   keyPassword=…
   ```
   Use an absolute `storeFile`; a relative one resolves against
   `android/app/`.
3. Neither: the build is signed with your debug key and Gradle prints a
   warning. Fine for testing on your own phone, but that APK and a
   release-signed one cannot update each other.

Half a configuration (a path without its password, say) stops the build
instead of quietly falling back to the debug key.

### 4d. Rotation

- **The secrets** (a new password, a re-upload): change the password on a
  copy of the keystore (`keytool -storepasswd -keystore <copy>.jks`), prove
  the copy still signs with a local `--release` build (§ 4c) using the new
  password for both store and key, then make it the keystore and
  `gh secret set` whichever secrets changed. Users notice nothing: the key
  is the same.
- **The key itself**, only if it leaks: every installed copy trusts the old
  one. APK Signature Scheme v3 supports key rotation: `apksigner rotate`
  records a lineage from the old key to the new one, and APKs signed with
  that lineage update existing installs (see the `apksigner` documentation).
  Gradle cannot do that alone; it would take an `apksigner sign` step after
  the build. Without rotation, users must uninstall and reinstall, restoring
  from their recovery phrase.
- **What is an APK signed with?**
  `apksigner verify --print-certs TemplarWallet-android-arm64.apk` (Android
  SDK build-tools). The SHA-256 must match the one in the release notes.

### 4e. Coming from the alphas

The 0.1.0-alpha APKs were signed with a development debug key. 0.1.0 is the
first one signed with the release key, so it cannot install over an alpha:
testers back up their recovery phrases, uninstall the alpha, then install
0.1.0.

---

## 5. The Windows installer

`packaging/windows/templar-wallet.iss`, compiled by Inno Setup 6.3 or newer
(7 works too). CI passes the version and overrides the output name:

```powershell
iscc /DMyAppVersion=0.1.0 packaging\windows\templar-wallet.iss
# → dist\TemplarWallet-0.1.0-windows-x64-setup.exe
# CI: … /O<folder> /FTemplarWallet-windows-x64-setup
```

The wizard asks for two locations, and they are not interchangeable:

| Page | Default | Replaced by an update? | Removed by the uninstaller? |
|---|---|---|---|
| Destination (the program) | `%ProgramFiles%\Templar Wallet` | yes, wholesale | yes |
| Wallet data | `%APPDATA%\templar_wallet` | never | **never** |

The destination page is always shown, including on a reinstall or an
upgrade, which is exactly when someone wants to move the program to another
drive, and both paths are restated on the Ready page before anything is
written. **Wallet data is deliberately left behind on uninstall**: removing
an app must never destroy someone's keys.

The wallet-data choice is recorded in `install.conf` beside the executable:

```ini
version=0.1.0
data_dir=%APPDATA%\templar_wallet
```

`wallet-ffi` reads it **once**, on the first run of a fresh install, when it
has no config of its own yet (`AppFfiState::new`, `src/wallet-ffi/src/state.rs`).
After that the app records the location in `templar_wallet.json` and stops
consulting the file, so a later reinstall can never redirect an existing user
away from the wallets they already have. Precedence, highest first:
`wallet_set_data_dir` → `TEMPLAR_DATA_DIR` → the saved config → `install.conf`
→ the platform default.

A path under the installing user's `%APPDATA%` is written back as an
unexpanded `%APPDATA%` reference on purpose: one per-machine install then
still gives every Windows account on the box its own private wallet folder.

For unattended installs, pass the folders on the command line:

```powershell
TemplarWallet-windows-x64-setup.exe /VERYSILENT ^
  /DIR="D:\Apps\Templar Wallet" /DATADIR="D:\Wallets\Templar"
```

The wizard also remembers the data folder chosen by a previous run, so an
upgrade proposes the same one.

---

## 6. Code signing for macOS and Windows (not in CI yet)

The DMG and the installer CI publishes are unsigned. macOS says "Apple could
not verify…" and Windows SmartScreen "Windows protected your PC";
`docs/RELEASE_NOTES.md` tells users the way past each. No code can remove
these warnings: both need a paid identity certificate.

| Platform | Requirement | Cost | Without it |
|---|---|---|---|
| macOS | **Developer ID Application** certificate from the Apple Developer Program, plus **notarization** | $99/year | "Apple could not verify… is free of malware." Opening takes the steps in RELEASE_NOTES.md. |
| Windows | **Authenticode** code-signing certificate (OV or EV) | ~$200–600/year | SmartScreen: "Windows protected your PC" → *More info* → *Run anyway*. |

Two things worth knowing before spending money:

- **macOS notarization is all-or-nothing, and it works.** Sign, notarize and
  staple, and the warning is gone for every user, offline.
- **Windows OV certificates do not silence SmartScreen at once.** SmartScreen
  is reputation-based: a new OV signature still warns until enough people
  have installed it. An **EV** certificate has reputation from day one, which
  is the only reason to pay its premium.

**Wire signing into `release.yml`, not into a local build**, so a release stays
one run whose files match `SHA256SUMS.txt`:

- macOS: store the Developer ID certificate (`.p12`, base64) and a notary
  credential as secrets; in the `macos` job, import the certificate into a
  temporary keychain, store a `notarytool` profile in it, and set
  `SIGN_IDENTITY` and `NOTARY_PROFILE` for `scripts/make_dmg.sh`, which already
  signs, notarizes and staples when they are set (§ 6a).
- Windows: certificates now come on a hardware token or through a cloud
  signing service. A token cannot be plugged into a hosted runner; a cloud
  service can be driven from the `windows` job (its `signtool` integration).
  Sign `templar_wallet.exe` before Inno Setup packs it, then the installer.

If you ever sign a file by hand instead, replace it on the release together
with a regenerated `SHA256SUMS.txt`:
`gh release upload vX.Y.Z <file> SHA256SUMS.txt --clobber`.

### 6a. macOS: certificate, notarization, DMG

**Get the certificate** (once):

1. Join the [Apple Developer Program](https://developer.apple.com/programs/).
2. Xcode → Settings → Accounts → *Manage Certificates* → **+** →
   **Developer ID Application**. This installs it into your login keychain.
3. Confirm it is there and note the exact string:
   ```bash
   security find-identity -v -p codesigning
   # → "Developer ID Application: Your Name (ABCDE12345)"
   ```

**Store a notarization credential** (once): create an app-specific password
at <https://appleid.apple.com> → Sign-In and Security → App-Specific
Passwords, then:

```bash
xcrun notarytool store-credentials templar-notary \
  --apple-id "you@example.com" \
  --team-id "ABCDE12345" \
  --password "abcd-efgh-ijkl-mnop"
```

`templar-notary` is the profile name passed as `NOTARY_PROFILE`.

**Build the DMG:**

```bash
./scripts/make_packaging_assets.sh          # once, or after editing the artwork

SIGN_IDENTITY="Developer ID Application: Your Name (ABCDE12345)" \
NOTARY_PROFILE="templar-notary" \
./scripts/make_dmg.sh
# → dist/TemplarWallet-<version>-macos.dmg
```

With neither variable set it makes an unsigned DMG, which is what CI does.
The script signs the embedded `libwallet_ffi.dylib` first and the bundle
second (`--deep` is deprecated and signs nested code incorrectly), enables
the **hardened runtime** notarization requires, signs the DMG itself,
submits it to Apple, and **staples** the ticket so the DMG opens cleanly on a
machine with no network.

**Verify before shipping:**

```bash
spctl -a -t open --context context:primary-signature -vv dist/TemplarWallet-*.dmg
# want: source=Notarized Developer ID   accepted

# The real test: simulate a download, which is what sets the quarantine flag.
xattr -w com.apple.quarantine "0081;00000000;Safari;" /tmp/copy.dmg
open /tmp/copy.dmg
```

**The DMG window layout.** Icon positions live in a `.DS_Store`, and only
Finder writes one, through AppleScript, which needs an Automation permission
that locked-down Macs may refuse. `make_dmg.sh` handles every case and always
produces an installable DMG. To record the layout once, so every build is
byte-identical and needs no AppleScript:

1. Run `./scripts/make_dmg.sh` and let it produce a DMG.
2. `hdiutil attach` it, or mount the intermediate read-write image.
3. In Finder: View → *as Icons*, hide the toolbar, set the window to roughly
   660×420, icon size ~96, View Options → Background → Picture →
   `.background/background.tiff`, then drag the app icon onto the left dashed
   square and Applications onto the right one.
4. Close the window (that flushes the `.DS_Store`), then:
   ```bash
   cp "/Volumes/Templar Wallet/.DS_Store" packaging/macos/dmg-DS_Store
   ```
5. Commit it. From then on the script copies it in verbatim.

### 6b. Windows: Authenticode

With a certificate available to `signtool` (check with
`certutil -user -store My`), define a sign tool in Inno Setup,
**Tools → Configure Sign Tools… → Add**, named `templar`, with the command:

```
"C:\Program Files (x86)\Windows Kits\10\bin\10.0.22621.0\x64\signtool.exe" sign /fd sha256 /tr http://timestamp.digicert.com /td sha256 /a $f
```

Sign the app itself first, so it is trusted and not just its wrapper, then
compile with signing enabled:

```powershell
signtool sign /fd sha256 /tr http://timestamp.digicert.com /td sha256 /a `
  src\templar_wallet\build\windows\x64\runner\Release\templar_wallet.exe
iscc /DSIGN /DMyAppVersion=0.1.0 packaging\windows\templar-wallet.iss
signtool verify /pa /v dist\TemplarWallet-*-setup.exe
```

`/tr` (an RFC 3161 timestamp) is not optional: without it every signature
stops validating the day the certificate expires, and installed copies start
warning. Test on a **clean** Windows VM: the build machine trusts its own
certificate and will not show what a stranger sees.

---

## 7. Local builds

Each OS builds on its own machine: Flutter desktop does not cross-compile.
Local builds carry the version in their file names and are for testing; the
files of a release only ever come from CI.

| Platform | Command | Output |
|---|---|---|
| macOS | `cd src/templar_wallet && flutter build macos --release`, then `./scripts/make_dmg.sh` from the repository root | `dist/TemplarWallet-<version>-macos.dmg` |
| Android | `./scripts/build_android.sh --release` | `src/templar_wallet/build/app/outputs/flutter-apk/app-<abi>-release.apk` |
| Linux | `bash scripts/build_linux.sh` (in an Ubuntu 22.04 container, so glibc 2.35 like CI) | `dist/TemplarWallet-<version>-linux-x64.tar.gz` |
| Windows | double-click `scripts\build_windows.cmd` | `dist\TemplarWallet-<version>-windows-x64-setup.exe` and `.zip` |

- **macOS:** the Xcode Run Script phase builds and bundles
  `libwallet_ffi.dylib`, one slice per Rust target installed. For a DMG that
  runs on Intel Macs too, `rustup target add x86_64-apple-darwin` once.
- **Android:** needs the Android SDK and a JDK 17; the script installs NDK
  28.2.13676358, cargo-ndk and the Rust targets when they are missing, and
  signs as described in § 4c.
- **Linux and Windows** on someone else's PC, from a source zip:
  `HELPER_BUILDS.md`. Step by step by hand: `LinuxBuild.md`, `WindowsBuild.md`.

---

## 8. Release checklist

- [ ] `version:` in `src/templar_wallet/pubspec.yaml` bumped, `+N` higher than the last release's
- [ ] `CHANGELOG.md` has a `## [X.Y.Z] — date` section
- [ ] `docs/RELEASE_NOTES.md` current: it ships in the bundles as `README.md`
- [ ] `ci` green on `main`
- [ ] tag `vX.Y.Z` pushed; the `release` run green; the release is *Latest* with seven files
- [ ] the stable links download the new version; the files match `SHA256SUMS.txt`
- [ ] installed from a **downloaded** copy on macOS, Windows, Linux and Android
- [ ] wallet data survives upgrading over the previous version (Windows installer, Android update)
