# Templar Wallet

> [!WARNING]
> **Alpha software, testnet only.** Templar Wallet is still in alpha: expect
> bugs, rough edges and breaking changes between releases. Everything runs on
> Bitcoin testnet and Liquid testnet (plus a local Liquid regtest for
> development) and mainnet is refused by design — use free test coins only,
> and never import a recovery phrase that holds real funds.

A Bitcoin and Liquid wallet for macOS, Windows, Linux and Android, built
around **Miniscript custody**: besides single-sig and multisig, a wallet can
carry a real spending policy — timelocks, hashlocks, thresholds, AND/OR —
from a template or a policy builder.

## What it does

- **Wallets** — software single-sig (BIP84), multisig on Bitcoin (P2WSH) and
  Liquid, Miniscript policy wallets, watch-only, hardware wallets (Ledger and
  Jade over USB, others through HWI) and air-gapped signing over QR (BC-UR).
- **Encrypted at rest** — recovery phrases live in a vault sealed with
  Argon2id + XChaCha20-Poly1305 behind an app password; Touch ID on macOS,
  fingerprint on Android, auto-lock everywhere.
- **Send and receive** — a guided send with fee presets, MAX, several
  recipients, manual coin selection and RBF; payment requests (BIP21) on
  receive; activity and a portfolio chart.
- **Coin control** — every coin as a banknote or a row, sized by its share of
  your holdings; labels, consolidation, and **freezing**: a frozen coin stays
  in the balance but is never spent — not by a payment, not by MAX, not by a
  consolidation — until you unfreeze it.
- **Co-signing** — import a PSBT or PSET by paste, file or camera, read what
  it really does, sign, merge co-signers' copies, broadcast.
- **Liquid** — confidential assets, issuance / reissuance / burn on testnet,
  LiquiDEX swaps and a peg-in / peg-out flow (simulated provider).
- **Templar Protocol** — the wallet is the signing side of the Templar
  Protocol, a peer-to-peer Liquid lending protocol: a site hands over loan
  transactions through `templar://` links, the wallet shows them and signs
  only what you confirm ([connector guide](docs/guides/PROTOCOL_CONNECTOR.md)).

## Download

Every release is built by CI from a tagged commit and published on the
[Releases](https://github.com/0xMrtnz/TemplarWallet/releases) page, with a
`SHA256SUMS.txt` beside the files. Every build is an alpha and runs on testnet
only. The newest build is always at these links:

| Platform | File |
|---|---|
| macOS 10.15+ (Apple Silicon and Intel) | [TemplarWallet-macos.dmg](https://github.com/0xMrtnz/TemplarWallet/releases/latest/download/TemplarWallet-macos.dmg) |
| Windows 10/11 x64 — installer | [TemplarWallet-windows-x64-setup.exe](https://github.com/0xMrtnz/TemplarWallet/releases/latest/download/TemplarWallet-windows-x64-setup.exe) |
| Windows 10/11 x64 — portable | [TemplarWallet-windows-x64.zip](https://github.com/0xMrtnz/TemplarWallet/releases/latest/download/TemplarWallet-windows-x64.zip) |
| Linux x64 (glibc 2.35+: Ubuntu 22.04+, Debian 12+) | [TemplarWallet-linux-x64.tar.gz](https://github.com/0xMrtnz/TemplarWallet/releases/latest/download/TemplarWallet-linux-x64.tar.gz) |
| Android 7.0+ phones (arm64) | [TemplarWallet-android-arm64.apk](https://github.com/0xMrtnz/TemplarWallet/releases/latest/download/TemplarWallet-android-arm64.apk) |
| Android emulators / x86_64 devices | [TemplarWallet-android-x86_64.apk](https://github.com/0xMrtnz/TemplarWallet/releases/latest/download/TemplarWallet-android-x86_64.apk) |

The desktop builds are not signed with a paid certificate yet, so macOS and
Windows warn on first launch. How to get past that, per platform:
[`docs/RELEASE_NOTES.md`](docs/RELEASE_NOTES.md) (English) ·
[`docs/INSTALLAZIONE.md`](docs/INSTALLAZIONE.md) (italiano).

## Layout

| Path | What |
|------|------|
| `crates/templar-core/` | Wallet engine — BDK 0.30 (Bitcoin) + LWK 0.9 (Liquid), Miniscript policy engine, encrypted vault. No GUI dependencies. |
| `src/wallet-ffi/` | C ABI bridge → `libwallet_ffi.{dylib,so,dll}`; JSON methods in `dispatch.rs` |
| `src/templar_wallet/` | Flutter app (macOS, Windows, Linux, Android) |
| `assets/brand/` | Logo SVGs — the source of every icon raster |
| `packaging/` | DMG artwork, Inno Setup script, Linux desktop entry |
| `scripts/` | Build, packaging and icon scripts |
| `docs/` | Reference material — start at [`docs/README.md`](docs/README.md) |

---

## Build the executable from source

The app is two artifacts that must ship together:

1. the Rust FFI library — `libwallet_ffi.dylib` / `libwallet_ffi.so` / `wallet_ffi.dll`
2. the Flutter desktop bundle

**Flutter desktop does not cross-compile — each OS must be built on that OS.**
If the native library is missing at runtime, a release build stops on a fatal
error screen (it never falls back to fake data), so step "bundle the library"
below is not optional.

### Prerequisites (all platforms)

| Tool | Version |
|------|---------|
| Rust | stable (edition 2021) — <https://rustup.rs> |
| Flutter | **3.44.1** stable (pinned by CI; Dart SDK `^3.12.0`) |

```bash
git clone https://github.com/0xMrtnz/TemplarWallet.git
cd TemplarWallet
```

First Rust build compiles ~500 crates (BDK, LWK) and takes several minutes.

### macOS

Needs Xcode + command line tools (`xcode-select --install`).

```bash
cd src/templar_wallet
flutter pub get
flutter build macos --release
```

Nothing else to do: the Xcode **Run Script** phase builds `libwallet_ffi.dylib`
for every installed Rust target, `lipo`s them into one universal binary, and
drops it in `templar_wallet.app/Contents/Frameworks/`.

Run it:

```bash
open build/macos/Build/Products/Release/templar_wallet.app
```

Optional, for Intel-Mac compatibility of your own build:
`rustup target add x86_64-apple-darwin aarch64-apple-darwin`.

To produce a DMG: `./scripts/make_dmg.sh` from the repo root → `dist/`.

Hardware wallets on macOS need the app-managed HWI venv:
`./scripts/setup_hwi_macos.sh`.

### Linux

Deps (Debian/Ubuntu — 22.04 or newer):

```bash
sudo apt update
sudo apt install -y build-essential clang cmake ninja-build pkg-config \
                    libgtk-3-dev libssl-dev libudev-dev curl git unzip
flutter config --enable-linux-desktop
```

Fedora: `clang cmake ninja-build pkgconf-devel gtk3-devel openssl-devel systemd-devel`.
`libudev-dev` matters at build time: without it `serialport` compiles but reports
no USB metadata, and a Blockstream Jade is never recognised.

```bash
# 1. native library
cargo build --release -p wallet-ffi

# 2. app bundle
cd src/templar_wallet
flutter pub get
flutter build linux --release

# 3. bundle the library next to the executable
cp ../../target/release/libwallet_ffi.so build/linux/x64/release/bundle/lib/

# 4. run
./build/linux/x64/release/bundle/templar_wallet
```

Ship the whole `bundle/` directory — it is self-contained apart from GTK 3
(`libgtk-3-0`) on the target machine. The binary is linked against the build
host's glibc; CI builds on Ubuntu 22.04 (glibc 2.35) for Ubuntu 22.04+/Debian 12+.

Hardware-wallet device nodes are root-only until udev rules are installed — the
in-app hardware screen has a **Fix device permissions** button that writes them
via one `pkexec` prompt. Replug the device afterwards.

Full notes: [`docs/build/LinuxBuild.md`](docs/build/LinuxBuild.md).

### Windows

Install **Visual Studio 2022** with the **"Desktop development with C++"**
workload (MSVC + Windows SDK + CMake), Git for Windows, and Rust via
`rustup-init.exe` (default `stable-x86_64-pc-windows-msvc`). Then:

```powershell
flutter config --enable-windows-desktop
flutter doctor    # "Visual Studio" must be green
```

No OpenSSL/vcpkg setup is needed — TLS uses SChannel and rustls.

```powershell
# 1. native library
cargo build --release -p wallet-ffi

# 2. app bundle
cd src\templar_wallet
flutter pub get
flutter build windows --release

# 3. bundle the DLL next to the exe
Copy-Item ..\..\target\release\wallet_ffi.dll build\windows\x64\runner\Release\

# 4. run
.\build\windows\x64\runner\Release\templar_wallet.exe
```

Ship the whole `Release\` folder (exe + `data\` + Flutter and plugin DLLs +
`wallet_ffi.dll`). Machines without Visual Studio may also need the
[VC++ Redistributable](https://aka.ms/vs/17/release/vc_redist.x64.exe).

Installer: `packaging\windows\templar-wallet.iss` (Inno Setup 6 or 7) →
`ISCC.exe /DMyAppVersion=<version> packaging\windows\templar-wallet.iss`.

Full notes: [`docs/build/WindowsBuild.md`](docs/build/WindowsBuild.md).

### Where the app looks for the native library

| OS | Search order |
|----|--------------|
| macOS | `<app>/Contents/Frameworks/`, next to the executable, then `target/{release,debug}/` |
| Linux | `<exe dir>/lib/`, `<exe dir>/`, then `target/release/` |
| Windows | `<exe dir>/`, `<exe dir>\lib\`, cwd, then `target\{release,debug}\` |

The dev fallbacks are why `flutter run` works from `src/templar_wallet` after a
plain `cargo build --release -p wallet-ffi`.

---

## Develop

```bash
cargo test -p templar-core -p wallet-ffi     # engine suite (offline, seconds)
cargo clippy -p templar-core -p wallet-ffi --all-targets -- -D warnings
cargo fmt --all

cd src/templar_wallet
flutter analyze
flutter test
flutter run -d macos                          # or -d linux / -d windows / an Android device
```

Runtime endpoints can be overridden with `TEMPLAR_ELECTRUM_URL`,
`TEMPLAR_LIQUID_ELECTRUM_URL`, `TEMPLAR_DATA_DIR`, `TEMPLAR_HWI_BIN` (the full
list is in [`CLAUDE.md`](CLAUDE.md#env-overrides)).

Brand rasters are build products: edit `assets/brand/*.svg`, then run
`./scripts/generate_icons.sh` (macOS only).

How releases are cut and published: [`docs/build/RELEASE.md`](docs/build/RELEASE.md).

## Security

Please report vulnerabilities privately — see [`SECURITY.md`](SECURITY.md).

## License

[MIT](LICENSE). The vendored `biometric_storage` plugin under
`src/templar_wallet/packages/` keeps its own MIT license.
