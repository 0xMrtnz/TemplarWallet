# Hardware wallet testing — Ledger (USB) + Jade (USB & QR)

Testnet only. Covers macOS, Windows and Linux. Supersedes the Jade-only subset
in `JADE_TESTING.md`.

Every claim below is traced to a code path so a failure can be localised
without guessing. Run the tests in order — later ones assume a funded wallet
from earlier ones.

> ## Platform support at a glance
>
> Support is now per **device family**, not per operating system.
>
> | | Windows | Linux | macOS |
> |---|---|---|---|
> | **Bitcoin** over USB — **Ledger, Jade** (native, in-process) | ✅ | ✅ (after the one-click udev fix) | ✅ |
> | **Bitcoin** over USB — Trezor, Coldcard, KeepKey, BitBox (HWI) | ✅ | ✅ (after the udev fix) | ❌ sandbox |
> | **Liquid** over USB — **Jade only** | ✅ | ✅ | ✅ |
> | Air-gap QR / file / paste (Bitcoin only) | ✅ | ✅ | ✅ |
> | Camera QR scanning | ❌ (paste/file) | ❌ (paste/file) | ✅ |
>
> Ledger and Jade are driven by `crates/templar-core/src/bitcoin/device/` inside
> this process — Ledger over USB HID (Ledger's own `ledger_bitcoin_client` on
> our 64-byte framing), Jade over USB serial (its CBOR dialect on `lwk_jade`'s
> transport). No subprocess is involved, so they behave the same on all three
> platforms, and HWI is no longer required to *install* for either.
>
> **The remaining macOS gap is HWI, and it is the App Sandbox, not a bug here.**
> Families without a native driver still shell out to the `hwi` CLI, and the
> sandbox will not let the app start one. Measured on macOS 15:
>
> * `hwi` in the app's data container → `execve` returns EPERM, with and
>   without the `com.apple.quarantine` attribute. The identical binary runs
>   from a shell (`hwi 3.2.0`, `enumerate` in 6.5 s).
> * `hwi` inside `templar_wallet.app/Contents/Resources`, ad-hoc signed → execs,
>   then hangs in its PyInstaller bootloader. No result after four minutes,
>   twice.
>
> So on macOS a Trezor or Coldcard is *detected and named* but cannot be
> driven; the UI says so on the card and offers the two routes that do work —
> a Ledger or Jade over USB, or air-gap by QR. Adding a native driver for
> those families closes the last cell; nothing else about the design changes.
>
> **One HID thread.** All `hidapi` calls run on a single owner thread
> (`device/hid.rs`). On macOS, enumerating from a second thread — or cycling
> `hid_init`/`hid_exit` per call — aborts the process with SIGTRAP, and
> Flutter's FFI calls arrive on whichever isolate thread is free. Regression
> test: `enumeration_survives_calls_from_many_threads`.

---

## 0. What is wired

| Flow | Transport | Code path | Status |
|---|---|---|---|
| Import **Ledger / Jade** | USB, in-process | `hw_descriptors_by_fingerprint` → `device::open_by_fingerprint` → `wpkh_descriptors` | wired, all platforms |
| Import Trezor / Coldcard / KeepKey / BitBox | USB (HWI subprocess) | same call, HWI fallback → `hwi enumerate` + `getdescriptors` | wired, not macOS |
| Verify receive address on device | USB | `verify_hw_address` → native `display_address`, else `hwi displayaddress` | wired |
| Sign a BTC send, then broadcast | USB | `sign_transaction_hw` → native `sign_psbt`, else `hwi signtx` | wired, retryable |
| **Co-sign a multisig PSBT with a device** | USB | `sign_psbt_hw` → cosign view's "Sign with device" | wired |
| Fetch BIP48 cosigner xpub for multisig | USB | `get_hw_cosigner_xpub` → native `cosigner_xpub`, else `hwi getxpub m/48h/1h/0h/2h` | wired |
| Import air-gap signer (xpub/descriptor) | QR camera, paste, or file | `create_watch_only_wallet(airgap: true)` | wired |
| Sign a BTC send air-gapped | animated BC-UR QR out; QR / paste / **file** back | `ur_psbt_encode` → device → `ur_decode_parts` → `broadcast_signed_psbt` | wired |
| Install HWI | all platforms | in-app installer → bitcoin-core/HWI release, SHA256-verified | wired |
| Install Linux device permissions | Linux | `UdevInstaller` → bundled HWI udev rules via `pkexec` | wired |
| **Liquid wallet on a Jade** (send + receive) | USB serial (`lwk_jade`, in-process) | `JadeLiquidSigner` → `ct(slip77(<device key>),elwpkh(…))` | wired, **spendable** |
| Liquid-only Jade wallet (no Bitcoin side) | USB serial | `import_jade_liquid_wallet` | wired — the one hardware setup that works on macOS |
| **Liquid on any non-Jade device** | — | refused at import *and* at send | **impossible by device firmware — see §5c** |

---

## 1. Preflight

### 1.1 HWI toolchain

The app resolves `hwi` in this order (`templar_core::resolve_hwi_bin`, the single
source of truth used by both the status probe and the subprocess runner):

1. binary installed in-session by the UI installer
2. `TEMPLAR_HWI_BIN`
3. `<data_dir>/hwi/hwi` — where the in-app installer puts it
4. `<data_dir>/venv/bin/hwi` — the venv `scripts/setup_hwi_macos.sh` creates
5. `hwi` on `PATH`

If none resolve, every hardware call fails with `HWI_MISSING: …` and the UI
shows the install card. **This is the intended first-run path on all three
platforms** — the installer downloads the official standalone build for the
machine's OS/arch, verifies it against the release `SHA256SUMS`, and activates
it without a restart.

Verified asset names at HWI 3.2.0 (match `HwiInstaller.platformTag()`):
`mac-arm64`, `mac-x86_64`, `linux-aarch64`, `linux-x86_64`, `windows-x86_64`.
The macOS/Linux tarballs contain a bare `hwi`; the Windows zip contains
`hwi.exe` — both are what `_extractBinary` looks for.

`scripts/setup_hwi_macos.sh` still exists as a macOS dev convenience. It is not
the supported user path; the in-app installer is, on every OS.

### 1.2 Per-platform first run

**macOS.** Bitcoin over USB is unavailable — see the box at the top of this
file. Test the *messaging*: the wizard's USB option is disabled with the reason
on it, the hardware setup screen shows the "Bitcoin over USB is not available"
card listing any natively detected device, and the connect gate refuses
immediately rather than polling. That card also offers **Liquid wallet on a
Jade**, which does work here — run §5c, and the air-gap tests (§4) for Bitcoin.

Entitlements still grant `device.usb`, `device.serial` and `device.camera` —
needed by the native device layer that replaces HWI, and by the QR scanner.

**Windows.** Nothing to install beyond HWI. Ledger needs no driver on Win10+.
HWI subprocesses are spawned with `CREATE_NO_WINDOW`, so no console flashes —
if you see one, that path is not going through `hwi_json`.

**Linux.** Device nodes are root-only until udev rules are installed. The
hardware setup screen detects this two ways — proactively (`hwi_status` reports
`udev_rules_installed: false`) and reactively (`HWI_PERMISSION` from a failed
enumerate) — and offers **Fix device permissions**, which installs the bundled
HWI rules with one `pkexec` prompt and reloads udev. Test both entry points.
Without `pkexec` the card prints the exact `sudo` commands instead.
After installing: replug the device, and log out/in once (the `plugdev` group
only applies to new sessions).

### 1.3 Launch

```bash
# One instance only — the sled DB lock is exclusive; a second instance makes
# every BDK call fail with "Bitcoin wallet not open".
cd src/templar_wallet && flutter run -d macos --debug   # or -d windows / -d linux
```

Keep the console visible: every HWI invocation logs `[hw] <bin> <args>` on
stderr and is reproducible verbatim in a terminal.

### 1.4 Devices

**Ledger (Nano S / S Plus / X):** plug in, unlock, open the **Bitcoin Testnet**
app (not "Bitcoin" — HWI is called with `--chain test`), quit Ledger Live.

**Jade:** firmware current, **Options → Settings → Device → Enable Testnet**,
quit Blockstream Green (one app per serial port). PIN unlock needs internet on
the host.

**Faucets:** BTC https://coinfaucet.eu/en/btc-testnet/ · L-BTC https://liquidtestnet.com/faucet

### 1.5 CLI smoke test — do this before touching the app

```bash
# macOS/Linux; on Windows use the installed hwi.exe path
"$HWI" enumerate
```

Expect one entry with `model` and `fingerprint`. An entry carrying `error` and
no fingerprint is a device-state problem; the app classifies it and shows the
matching remedy rather than an empty list.

---

## 2. Test A — Ledger over USB (Bitcoin)

### A1 · Import
1. Wallet picker → **New Wallet** → Bitcoin only → **Hardware wallet** → **USB**.
2. **Scan** → the Ledger appears with its 8-hex master fingerprint → select → name → **Import**.
   - The **`wpkh(`** descriptor is explicitly picked out of HWI's array — HWI
     returns legacy/wit/sh-wit/taproot and only native segwit is supported.
   - **Expect:** type label `Hardware (<fp>)`, watch-only, `m/84'/1'/0'`.

### A2 · Verify the address on the device
Receive screen → verify button (BTC only).
- **Expect:** the device screen shows an address matching the app character for character.
- The index is BDK's `LastUnused`, so repeated verifies do not burn addresses.
- **A mismatch here is the most important failure in this document.** Stop and report it.

### A3 · Fund and sync
Faucet → the verified address → sync. First sync of a fresh descriptor does a
deep scan (gap limit 200) and is slow.

### A4 · Send + on-device signing
Send wizard → BTC → review → **Send**.
1. **Connect gate** polls until a device matching *this wallet's fingerprint* appears.
2. **Pre-sign address verification**: the device displays an address and you confirm it — proof the connected device controls this wallet before anything is built.
3. `sign_transaction_hw` builds and signs; `broadcast_signed_psbt` publishes.
   - **Expect:** outputs + fee on the device, you approve, the app returns a txid.
   - Reject on the device → `SIGNING_FAILED` with "the device did not sign", **not** an opaque finalize error. The backend checks HWI's `signed` flag *and* compares signature counts, so an unsigned PSBT never reaches the network layer.

### A5 · Broadcast retry (new behaviour — test deliberately)
Approve on the device, then kill connectivity before the broadcast (pull the
network, or point the app at an unreachable Electrum).
- **Expect:** "The device signed, but broadcasting failed… Press Send again to retry."
- Press **Send** again **with the device unplugged**: it must broadcast without asking the device to sign again, and without the address-verification step.
- Now change the amount and press Send: the retained signature must be discarded and a fresh on-device approval requested. (The retained PSBT is keyed to the exact outputs/fee/UTXOs/asset.)

### A6 · Reopen behaviour
Quit, relaunch, open from the picker → choose *connect device* vs *watch-only*.

### A7 · Negative cases
| Case | Expected |
|---|---|
| Unplug, then Send | Connect gate blocks with "device not detected" |
| Device locked | `DEVICE_NOT_READY` with the device's own complaint |
| Mainnet Bitcoin app open | Refused; no silent mainnet PSBT |
| Ledger Live running | Enumeration fails; must not hang |
| Reject on device | `SIGNING_FAILED`; nothing broadcast |
| **A different device than the wallet's, immediately after import** | Connect gate keeps waiting. This was broken before — the freshly imported wallet carried a bare `Hardware` label with no fingerprint, so any device satisfied the gate until the next restart. Test it right after import *and* after a restart. |
| HWI deleted mid-session | `HWI_MISSING` → install card, polling paused |

---

## 3. Test B — Jade over USB

Native serial path (no HWI), plus:

- Jade enumerates over **USB serial** (`/dev/cu.usbmodem*`, `/dev/ttyACM*`, `COM*`). Test the CLI first, then the app — on macOS this is what `device.serial` exists for, on Linux what `55-usb-jade.rules` covers.
- With Liquid enabled in the wizard **and** a Jade selected, pairing creates **one
  wallet with both chains** — Bitcoin descriptors in the profile, the Liquid CT
  descriptor on the same entry. There is no `<name> (Liquid)` companion any more:
  that shape stored a `ct(...)` descriptor in the Bitcoin slot, so the companion's
  Bitcoin screens could only answer *"Bitcoin wallet not open"*.
- Both descriptors are read in **one device session** (`WalletManager::hw_pairing`),
  so one unlock covers both chains. Watch for a second PIN prompt: that means
  something reopened the device.
- **One row per device.** macOS publishes every serial port twice, as
  `/dev/cu.<name>` and `/dev/tty.<name>`. Enumeration collapses them (keeping the
  call-out node) and the device list dedupes again by fingerprint, so a single Jade
  must appear exactly once and be unlocked exactly once. Regression tests:
  `macos_callout_and_dialin_nodes_are_the_same_device`,
  `serial_enumeration_lists_each_port_once`.
- Jade auto-locks when idle; that looks like "device disappeared".
- **A locked Jade holds any open for 90 s** (`lwk_jade`'s timeout, waiting for the
  PIN) and then fails with `DEVICE_NOT_READY`. This is why the UI never opens a
  device on a timer: detection (`enumerate_native_devices`, USB descriptors only)
  polls freely, while identification runs when the user asks for it. Unit tests
  that would open an attached device skip themselves — with hardware on the desk
  the suite would otherwise spend 90 s per test waiting for a PIN.

### B1 · Pairing recap (the last step)
After naming the wallet, the flow ends on a summary rather than a bare "done":
per-network status (Bitcoin ✓ / Liquid ✓ or the reason it is missing), the
descriptors that were stored, the device model and fingerprint, and the checks
that were made — including **the Bitcoin descriptor's fingerprint equals the
device's**. Verify:

| Case | Expected |
|---|---|
| Jade, Bitcoin + Liquid, both read | "Pairing complete", both cards green, both descriptors shown |
| Liquid read fails (decline the unlock on the device) | "Paired, with one part missing" — the Bitcoin wallet exists and is usable, the Liquid card carries the device's reason and a **Retry Liquid** button |
| Retry Liquid, this time unlocking | Liquid card turns green; the same wallet now has both chains (no second wallet appears in the picker) |
| Ledger, Bitcoin + Liquid asked | Liquid card explains the firmware limit; nothing Liquid is created |

### B2 · Adding Liquid later
Pair a Jade with **Bitcoin only**, open the wallet → Wallet Info → **Add Liquid
from my Jade**. It reconnects, checks the fingerprint matches this wallet, reads
the CT descriptor and stores it on the same entry; the sidebar's Liquid section
appears without a restart. Negative cases: an air-gap wallet and a non-Jade
wallet must not offer the button, and the backend must refuse both anyway
(`adding_liquid_is_refused_where_no_device_could_provide_it`).

---

## 4. Test C — Jade air-gap over QR

### C1 · Export from the device
Unlock first: QR PIN unlock relays through the Blockstream app (Templar is not a
pinserver relay), or use *Temporary Signer* to stay offline. Then Jade → QR Mode
→ Options → Wallet → Export Xpub (`ur:crypto-account`, `ur:crypto-hdkey`, or a
plain-text descriptor QR).

**Liquid is not on this route.** QR mode is Bitcoin-only on the device, so the
wizard warns before the device choice and the air-gap setup never asks for a CT
descriptor; the backend rejects one anyway (`LIQUID_HW_UNSUPPORTED`).

### C2 · Import
New Wallet → **Hardware** → **Air-gap** → step 3 → **Scan** (macOS) or **Paste**.
- On Windows/Linux the Scan control is **not rendered** — there is no camera
  plugin for those desktops, so the button would only ever open an apology.
  Paste is right beside it and takes the same payload.
- **Expect:** type label `Air-gap watch-only`; descriptors validated *before*
  anything is persisted; receive branch `/0/*`, change branch `/1/*`.

### C3 · Air-gap signing round trip
Send → BTC → review → **Send**:
1. Unsigned PSBT shown as an **animated UR QR** (frame counter beneath).
2. Scan with the Jade camera → verify outputs and fee **on the device** against the app's review screen → approve.
3. Bring the signed PSBT back by whichever route the platform offers:
   - **Scan signed QR** (macOS),
   - **Load .psbt file** (all platforms),
   - paste the base64.
4. **Review dialog before broadcast** decodes the signed PSBT and shows what it actually pays. Read it.
5. Confirm → broadcast → txid.

### C4 · Negative cases
| Case | Expected |
|---|---|
| Cancel mid multi-frame scan | Progress resets, no stuck spinner |
| QR that is not a PSBT | "The scanned QR did not contain a PSBT." |
| Unsupported UR type | `Unsupported UR type "…" — expected crypto-psbt or crypto-account` |
| Mainnet xpub at import | Rejected (testnet-only app) |
| Reject on the Jade | Nothing broadcast |
| Load a .psbt file that is empty / garbage | Clear message, nothing broadcast |
| **Select L-BTC on an air-gap wallet** | Not offered at all: Liquid assets are filtered out of the asset step for hardware and air-gap wallets. If you reach it another way, the send is refused with `LIQUID_HW_UNSUPPORTED` — the backend rejects it even if the UI ever lets it through. |

---

## 5. Test D — HW device in a multisig

### D1 · Enroll
Wizard → **Multisig** → hardware → import keys → `get_hw_cosigner_xpub`.
- **Expect:** `[<fp>/48'/1'/0'/2']tpub…` (BIP48 P2WSH testnet).
- Build a 2-of-3, confirm the wallet opens and derives addresses.

### D2 · Sign with the device (new — this is the gap that was closed)
Fund the multisig, start a send, and take the partial PSBT to the co-sign view
(Send → **Cosign a transaction**), or stay on the coordinator's
**Co-signatures needed** sheet.
- Co-sign view: press **Sign with device** → connect gate → approve on the
  device.
- Co-signatures sheet (alpha.13): the wallet's hardware key must be flagged —
  the wizard flags keys read over USB; otherwise dashboard Keys → the key →
  Rename → **USB hardware wallet**. While that key's signature is missing the
  sheet shows **Sign with USB hardware wallet** → the gate accepts only the
  wallet's hardware keys → **Sign on device** → approve on the device.
- **Expect:** the signature count rises, that key's wedge fills in its own
  colour, its row flips to *Signed*, and the note names it.
- Previously the device could contribute an xpub at setup and then never be
  asked to sign: the send flow chooses its path from the wallet's type label,
  and a multisig wallet's label is `Multisig`, never `Hardware (…)`.
- Negative: press **Sign with device** with a device that holds none of the
  wallet's keys → "the device returned the transaction without adding a
  signature", not a silent no-op.
- **Device-specific caveat:** recent Ledger firmware requires a multisig wallet
  *policy* to be registered on the device before it will sign for it, and HWI
  3.x exposes no registration command. Expect Ledger multisig signing to refuse;
  Jade, Coldcard and Trezor sign a multisig PSBT directly. Record which device
  you used — a refusal there is the device's policy, not this code path.

### D3 · Liquid side of a multisig
A multisig can hold both chains (see [`LIQUID_MULTISIG.md`](LIQUID_MULTISIG.md)).
Only a Jade can contribute to the Liquid half:

- **Jade enrolled:** the import step reads *two* keys in one session —
  `[fp/48'/1'/0'/2']tpub…` for Bitcoin and `[fp/87'/1'/0']tpub…` for Liquid.
  The slot shows "Liquid key ready".
- **Ledger/Trezor/Coldcard/KeepKey enrolled:** the slot states the device is
  Bitcoin-only and the wallet is created Bitcoin-only — those devices can
  neither sign Elements nor contribute a usable Liquid key.
- **Co-signing a PSET with a Jade:** co-sign view → **Sign with device**. The
  wallet is registered on the device first (16-char name, one confirmation per
  device); without that registration the Jade refuses to sign for a multisig at
  all. No device picker appears — a Jade is the only possible answer.
- Air-gap is not an option on this route: PSETs have no QR transport.

---

## 5b. Native device layer (the HWI replacement)

`crates/templar-core/src/bitcoin/device/` talks to devices from our own process,
with no subprocess — the only design that can work under the macOS sandbox,
and one that removes the HWI install step from every platform.

**Landed: detection.** `enumerate_native_devices` reads USB descriptors via
`hidapi` (Ledger, Trezor, Coldcard, KeepKey, BitBox02) and `serialport` (Jade),
identifying devices by the same USB ids as the bundled udev rules. It takes no
locks on the device and cannot disturb one mid-operation, so it is safe to poll.

**The sandbox permits this.** Measured from inside the running sandboxed app:
`hwi_status` reports `hid_device_count: 18` on a MacBook with no wallet
attached — i.e. the HID bus is fully visible to us in-process, while the same
app cannot exec HWI at all. That is what makes the native path the way out on
macOS rather than a second dead end, and `hid_device_count` stays in the
diagnostics so a future zero (HID denied) is never mistaken for "no device
plugged in".

Test it on each platform with a device attached and with none:

- With a Ledger attached, the macOS "USB signing unavailable" card must list it
  by product name and `2c97:xxxx`. That proves HID access works inside the
  sandbox — the foundation the protocol work builds on.
- With a Jade attached it must appear over `serial` with one of
  `10c4:ea60`, `1a86:55d4`, `303a:4001`.
- With nothing attached the list must be empty and must not error.
- A generic USB-to-serial cable (CH340, `1a86:7523`) must **not** appear.

**Not landed: the protocols.** Extended-pubkey export, PSBT signing and
on-device address display still go through HWI, so they remain Windows/Linux
only. Ledger speaks APDUs over HID; Jade speaks CBOR over serial. Each needs a
physical device to develop against — do not trust an untested implementation of
either with funds.

## 5c. Test E — Liquid on a Jade

Jade is the only hardware wallet that can sign Liquid. Every other USB signer
is Bitcoin-only **in firmware**: an Elements sighash commits to 33-byte value
and asset commitments where Bitcoin's BIP143 commits to an 8-byte amount, so a
Bitcoin signer cannot produce the preimage at all. No derivation trick changes
that, which is why the app refuses the pairing rather than offering a
receive-only Liquid wallet.

### E1 · The blinding key must come from the device
The descriptor is `ct(slip77(<key read from the Jade>),elwpkh([fp/84h/1h/0h]xpub/<0;1>/*))`.

Check it on the created wallet: **it must contain `slip77(`, not `elip151`.**
An ELIP151 blinding key is derived from the descriptor rather than the seed, so
the app would derive addresses and unblind incoming funds while the Jade could
not recognise the outputs as its own — receivable, unspendable. That is exactly
what the old code produced, and it is the single most important regression to
watch for here.

### E2 · Three ways in
- **Paired with Bitcoin** (all platforms): wizard → Bitcoin + Liquid → Hardware
  → USB → Jade. Creates **one** wallet holding both chains, both descriptors read
  in a single unlocked session — so they cannot come from two different devices,
  which was the failure mode when the Liquid half opened its own connection.
- **Added afterwards**: Wallet Info → **Add Liquid from my Jade** on a wallet
  paired Bitcoin-only (§B2). The connected Jade's fingerprint must match the
  wallet's, or it is refused with both fingerprints named.
- **Liquid only** (fallback, all platforms): the "Set up a Liquid-only wallet
  instead" action offered on the recap when the Bitcoin half could not be read →
  name it → unlock the Jade. The resulting wallet reports **no Bitcoin side**
  (`bitcoin_enabled: false`): the picker badges it *Liquid only*, and the Bitcoin
  receive tab is hidden rather than shown and failing.

### E3 · Send
Fund the Liquid wallet, then send. The app builds the PSET, the Jade shows the
outputs and asset amounts, you approve, it broadcasts.
- The device is opened **at signing time**, not at wallet open — holding the
  serial port would block Blockstream Green and every other Jade-aware app for
  the whole session. Confirm Green can still reach the Jade between sends.
- Reject on the device → "The Jade did not add any signature", nothing broadcast.

### E4 · Negative cases
| Case | Expected |
|---|---|
| Wizard: Bitcoin + Liquid, then select a **Ledger** | Warning card: this device is Bitcoin-only, wallet will be Bitcoin-only. No Liquid side is created, and the recap says why. |
| Open a Liquid-only wallet → Receive | Only the Liquid tab exists. The old build offered a Bitcoin tab whose only answer was "Bitcoin wallet not open". |
| Liquid-only wallet, sidebar | No **Peg** entry: a peg needs a Bitcoin side to move value to. |
| Send Liquid from a Jade wallet | The connect gate appears first ("Connect your device to sign") and checks the fingerprint, then the Jade signs the PSET. Browsing the same wallet with the device unplugged must keep working. |
| Force `import_hw_wallet` with `liquid: true` on a non-Jade | `LIQUID_HW_UNSUPPORTED` — the backend refuses even though the UI already did |
| Send Liquid from a wallet whose profile is a non-Jade device | `LIQUID_HW_UNSUPPORTED`, before any PSET is built |
| Jade unplugged at send | `DEVICE_NOT_FOUND` naming the fix (unlock, close Green) |
| A *different* Jade than the wallet's, at import | Refused with both fingerprints named |
| Green open while connecting | Port busy — must be a clear error, not a hang |
| Air-gap wallet, L-BTC selected | Not offered; there is no Liquid PSET QR flow on either side |

## 6. What is still missing

1. **Liquid on anything but a Jade — permanently.** Not a gap in this codebase:
   Ledger, Trezor, Coldcard and KeepKey have no Liquid support in firmware and
   cannot produce an Elements signature. Enforced in three places so it cannot
   be reached by accident: the wizard warns and drops Liquid, `import_hw_wallet`
   refuses the pairing, and `send_liquid` refuses the spend.

2. **Liquid air-gap (QR) signing.** Jade over USB signs Liquid; there is no
   Liquid PSET QR transport, so air-gap wallets stay Bitcoin-only. This is the
   next real Liquid feature if macOS users want Liquid without a cable.

3. **Jade's Bitcoin side on macOS** still needs HWI, so it waits on the native
   driver work — a Jade on macOS can hold a Liquid wallet today but not a
   Bitcoin one.

4. **Camera QR scanning on Windows/Linux.** `mobile_scanner` has no
   implementation for those desktops. Scan controls hide themselves there and
   every flow completes via paste or file, so nothing is blocked — but reading
   an animated QR off the device screen still needs a camera-capable machine.

5. **Taproot / Miniscript-in-`tr()`** — BDK 0.30 limitation, unrelated to
   hardware, deferred to a BDK 1.x migration.

---

## 7. What to record for every run

- OS + version, device + firmware, `hwi --version` (shown in the hardware setup screen), app commit.
- The exact `[hw] …` line for any failure — it reproduces verbatim in a terminal.
- The error's tag (`HWI_MISSING`, `HWI_PERMISSION`, `DEVICE_NOT_READY`, `DEVICE_NOT_FOUND`, `SIGNING_FAILED`, `LIQUID_HW_UNSUPPORTED`) — if a failure shows an untagged raw string, that is itself a bug worth filing.
- Screenshot of any device screen that disagrees with the app.
- For sends: the txid and its blockstream.info/testnet link.
