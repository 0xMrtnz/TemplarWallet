# Templar Wallet — Windows Build Guide

Builds two artifacts: the Rust FFI library (`wallet_ffi.dll`) and the Flutter
desktop app (`templar_wallet.exe`). Assumes you cloned the repository and work
at its root, where the workspace `Cargo.toml` lives. All commands are for
PowerShell.

> Rather not do this by hand? `scripts/build_windows.cmd` checks and installs the
> requirements and runs every step below: see `HELPER_BUILDS.md`. The published
> installer and zip come from the `windows` job of
> `.github/workflows/release.yml`, which runs these same steps and then Inno
> Setup (`docs/build/RELEASE.md` § 5).

## 1. Requirements

### Visual Studio 2022 (Build Tools or full IDE)

Install **Visual Studio 2022** with the workload
**"Desktop development with C++"**. This provides MSVC, the Windows SDK, and
CMake — required by both the Rust MSVC toolchain and the Flutter Windows
build. (VS Code alone is NOT sufficient.)

Download: https://visualstudio.microsoft.com/downloads/

### Git

https://git-scm.com/download/win — needed by Flutter itself.

### Rust (MSVC toolchain)

Download and run `rustup-init.exe` from https://rustup.rs — accept the
default `stable-x86_64-pc-windows-msvc` toolchain. Then verify:

```powershell
rustc --version   # any recent stable (edition 2021)
```

No OpenSSL/vcpkg setup is needed: on Windows the TLS stack uses the built-in
SChannel, and the Electrum client uses pure-Rust rustls.

Hardware wallet support needs nothing extra either: `hidapi` compiles against
the Windows HID API and `serialport` against the Win32 comms API, both part of
the SDK the Visual Studio workload already installs. Ledger devices need no
driver on Windows 10 or later.

### Flutter

Requires **Flutter stable ≥ 3.44** (project pins Dart SDK `^3.12.0`).

```powershell
git clone https://github.com/flutter/flutter.git -b stable $env:USERPROFILE\flutter
# Add to PATH (persistent):
[Environment]::SetEnvironmentVariable('Path', $env:Path + ';' + $env:USERPROFILE + '\flutter\bin', 'User')
# Reopen the terminal, then:
flutter config --enable-windows-desktop
flutter doctor    # must show a green check for "Visual Studio"
```

## 2. Build the Rust FFI library

From the repo root (where the workspace `Cargo.toml` is):

```powershell
cargo build --release -p wallet-ffi
```

Output: `target\release\wallet_ffi.dll`

Note: compiles ~500 crates (BDK, LWK, etc.) — first build takes several
minutes. The workspace is only `templar-core` + `wallet-ffi`; the legacy egui
desktop crate no longer exists.

## 3. Build the Flutter app

```powershell
cd src\templar_wallet
flutter pub get
flutter build windows --release
```

Localizations (`app_localizations.dart`) are generated automatically from
`assets\l10n\` during the build — no manual `build_runner` step is needed.

Output: `build\windows\x64\runner\Release\`

## 4. Bundle the FFI library

On Windows the app loads the DLL by name (`wallet_ffi.dll`), resolved from
the executable's directory (see `lib/bridge/ffi_wallet_bridge.dart`). Copy it
next to the exe:

```powershell
Copy-Item ..\..\target\release\wallet_ffi.dll build\windows\x64\runner\Release\
```

Without this, the app fails at startup with a dynamic library load error.

## 5. Run

```powershell
.\build\windows\x64\runner\Release\templar_wallet.exe
```

To distribute, ship the whole `Release\` directory (exe + `data\` +
`flutter_windows.dll` + plugin DLLs + `wallet_ffi.dll`). On machines without
Visual Studio, the target may also need the
[Visual C++ Redistributable](https://aka.ms/vs/17/release/vc_redist.x64.exe).

## Notes & caveats

- **Testnet only** — Bitcoin testnet + Liquid testnet; no mainnet.
- **Network endpoints**: Electrum `ssl://electrum.blockstream.info:60002`
  (Bitcoin) and `elements-testnet.blockstream.info:50002` (Liquid); outbound
  TLS access required at runtime.
- **QR camera scanning** (`mobile_scanner`) has no Windows desktop
  implementation — the app builds and runs fine, but the "Scan QR" camera
  option is unavailable; use Paste/File import instead.
- **Hardware wallets**: runtime hardware signing shells out to the `hwi`
  binary. Optional — only needed if you use hardware-wallet features.
- Wallet data defaults to `%APPDATA%\templar_wallet`. The installer lets the
  user put it elsewhere and records the choice in `install.conf` beside the
  executable; a build run straight out of the tree has no such file and always
  uses the default. See `docs/build/RELEASE.md` § 5.
- If `cargo build` errors with `link.exe not found`, the C++ workload is
  missing — rerun the Visual Studio Installer and add
  "Desktop development with C++".
