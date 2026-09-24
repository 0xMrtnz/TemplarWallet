# Templar Wallet — install and first run

Templar Wallet runs on **Bitcoin testnet and Liquid testnet** only. It refuses
mainnet by design: use free test coins, never real funds.

Download from the
[latest release](https://github.com/0xMrtnz/TemplarWallet/releases/latest)
and check the file against `SHA256SUMS.txt` on the same page
(`shasum -a 256 <file>` on macOS and Linux, `certutil -hashfile <file> SHA256`
on Windows).

| System | File | Needs |
|---|---|---|
| macOS | `TemplarWallet-macos.dmg` | macOS 10.15 or newer, Apple Silicon or Intel |
| Windows | `TemplarWallet-windows-x64-setup.exe` (installer) or `TemplarWallet-windows-x64.zip` (portable) | Windows 10 or 11, 64-bit |
| Linux | `TemplarWallet-linux-x64.tar.gz` | x86_64, glibc 2.35 or newer |
| Android | `TemplarWallet-android-arm64.apk` (phones) / `TemplarWallet-android-x86_64.apk` (emulators) | Android 7.0 or newer |

The app talks to Blockstream's public testnet servers over TLS; there is no
account and no API key.

## macOS

The build is not notarized by Apple yet, so macOS blocks the first launch.

**Method 1 — Terminal (always works, required on macOS 26 Tahoe):**

```bash
xattr -c ~/Downloads/TemplarWallet-macos.dmg
open ~/Downloads/TemplarWallet-macos.dmg        # drag Templar Wallet to Applications
xattr -rc "/Applications/Templar Wallet.app"
open "/Applications/Templar Wallet.app"
```

**Method 2 — System Settings (macOS 15 Sequoia and older):** open the app
once and let it be blocked, then System Settings › Privacy & Security › scroll
to *"Templar Wallet was blocked…"* › **Open Anyway**.

The first time you scan a QR code macOS asks for the camera — allow it.

## Windows

- **Installer** (recommended): run `TemplarWallet-windows-x64-setup.exe`. It
  asks where to keep wallet data and registers `templar://` links, which the
  Templar Protocol needs. SmartScreen shows *"Windows protected your PC"*
  because the build is not code-signed yet: **More info › Run anyway**.
- **Portable**: extract the whole zip (not just the exe) and run
  `templar_wallet.exe`. It does not register `templar://` links.
- If it complains about `VCRUNTIME140.dll` or `MSVCP140.dll`, install the
  [Visual C++ Redistributable (x64)](https://aka.ms/vs/17/release/vc_redist.x64.exe).

## Linux

```bash
tar xzf TemplarWallet-linux-x64.tar.gz
```

Then run `templar_wallet` from the extracted folder. The only system
dependency is GTK 3 (`sudo apt install libgtk-3-0` or `sudo dnf install gtk3`
if it is missing). The build comes from Ubuntu 22.04, so it needs that
generation or newer — Ubuntu 22.04+, Debian 12+, Fedora 36+, current Arch.
An error like `` version `GLIBC_2.xx' not found `` means the distribution is
older than that.

To open `templar://` links from the browser, install the desktop entry from
the extracted folder (see
[the connector guide](guides/PROTOCOL_CONNECTOR.md#url-scheme-registration)).
Hardware wallets need udev rules; the app's hardware screen offers **Fix
device permissions** to install them.

## Android

Allow installs from your browser or file manager when Android asks, then open
the APK. Phones take the `arm64` file; the `x86_64` one is for emulators.

**Coming from a tester build (0.1.0-alpha):** those APKs were signed with a
development key, and Android refuses to install 0.1.0 over them. Write down
the recovery phrase of every wallet on the phone, uninstall the old app
(this deletes its wallets from the phone), install 0.1.0 and restore them.
Desktop tester builds update in place.

## First run

1. Set the **app password**. It encrypts every recovery phrase on the device
   and is asked again before a send is signed and before a phrase is shown.
2. Create or restore a wallet, open **Receive**, and fund it from a faucet:
   - Bitcoin testnet: https://coinfaucet.eu/en/btc-testnet/
   - Liquid testnet (L-BTC and test assets): https://liquidtestnet.com/faucet
     or https://faucet.vulpem.com
3. Press **Sync**. The first Liquid sync scans the whole history and can take
   a minute.

## Hardware wallets

- Ledger and Jade sign over USB on macOS, Windows and Linux with nothing to
  install. Trezor, Coldcard, KeepKey and BitBox go through the `hwi` tool on
  Windows and Linux (the app offers to download it).
- Air-gapped signing works over animated QR codes; where there is no camera,
  import the signed transaction with **Paste** or **File**.
- Android has no USB hardware-wallet support; use QR signing there.

## Known limitations

- Testnet and a local regtest only; no mainnet.
- Camera scanning works on macOS and Android; Windows and Linux import by
  paste or file.
- Transactions signal RBF, but there is no fee-bump screen yet.
- On Liquid, a payment that moves an asset other than L-BTC cannot leave
  frozen coins out yet: it is refused until the coins it needs are unfrozen.
- The peg-in / peg-out flow runs against a simulated provider.
- One instance at a time: a second copy of the app on the same data folder
  refuses to open it.

## App data and a clean reset

To start over, quit the app and delete the data folder. **This erases your
wallets and their recovery phrases.**

| System | Wallet data | Config file |
|---|---|---|
| macOS | `~/Library/Containers/dev.templarwallet.templarWallet/Data/Library/Application Support/templar_wallet` | `templar_wallet.json` in the container's `Library/Application Support` |
| Linux | `~/.local/share/templar_wallet` | `~/.config/templar_wallet.json` |
| Windows | `%APPDATA%\templar_wallet`, or the folder chosen in the installer | `%APPDATA%\templar_wallet.json` |

Settings › Vault & backup › Storage shows the folder actually in use.

## Reporting a problem

Open an issue at <https://github.com/0xMrtnz/TemplarWallet/issues> with your
system and version, what you did, what you expected and what happened.
Attach `logs/templar.log` from the wallet data folder (and `templar.log.1` if
there is one). Security problems go through private reporting instead — see
[SECURITY.md](../SECURITY.md).
