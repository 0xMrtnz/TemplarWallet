# Testing with Blockstream Jade (testnet)

> **Superseded by [`HARDWARE_TESTING.md`](HARDWARE_TESTING.md)**, which covers
> Ledger as well as Jade, all three desktop platforms, and the current
> behaviour (split sign/broadcast, multisig device co-signing, Linux udev
> install, tagged errors). Kept for the Jade-specific device notes below.

Two independent flows exist. Test both.

| Flow | Transport | Network support | Status in app |
|------|-----------|-----------------|---------------|
| A. USB import + sign | HWI subprocess | Bitcoin testnet (+ Liquid **watch-only** companion via ELIP151) | Wired end-to-end |
| B. Air-gap QR | Camera + QR codes | Bitcoin testnet | Wired end-to-end |
| Liquid signing on Jade | — | — | **Not implemented** (`JadeLiquidSigner` in `templar-core/src/liquid/hardware.rs` is all `todo!()` stubs — building it is the follow-up task after this testing round) |

## 0. Prerequisites (once)

1. **Jade firmware updated** (via Blockstream Green mobile/desktop) and initialized with a seed you use for testing only.
2. **Enable testnet on the Jade**: Options → Settings → Device → *Enable Testnet* (wording varies by firmware). Without this the device refuses `--chain test` requests.
3. **Install HWI** (flow A only):
   ```bash
   ./scripts/setup_hwi_macos.sh
   ```
   This creates the venv where the app looks for it (inside the app's data dir). Smoke-test with the `hwi enumerate` line the script prints — Jade must be connected, unlocked, and **not** open in Green at the same time (one app per serial port).
4. **Jade unlock needs internet** on the host: the PIN flow talks to Blockstream's blind pinserver. Enter the PIN on the device when it asks.
5. Testnet coins: https://coinfaucet.eu/en/btc-testnet/ (BTC), https://liquidtestnet.com/faucet (L-BTC).

## A. USB flow (HWI)

1. Connect Jade via USB-C, unlock it (PIN on device). Close Green.
2. App → wallet picker → **New Wallet** → wizard: networks as you like (Bitcoin, or Bitcoin + Liquid), kind **Hardware wallet** → USB.
3. Hardware setup screen → **Scan** → the Jade appears with its master fingerprint → select → **Import**.
   - Under the hood: `hwi enumerate` → `hwi -f <fp> --chain test getdescriptors` → native-segwit `wpkh(...)` descriptors → Bitcoin watch-only wallet.
   - With Liquid enabled it also creates a paired `<name> (Liquid)` wallet: ELIP151 confidential descriptor derived from the signing xpub — balances/receive work, **signing does not** (see table).
4. Verify a receive address: Receive screen → compare the address with the one Jade shows on its display (the app calls `hwi displayaddress` — confirm on device).
5. Fund it from the faucet, wait for sync, check balance.
6. Send test: Send wizard → build transaction → the app builds a PSBT and hands it to HWI → **confirm outputs + fee on the Jade screen** → app broadcasts. Check the txid on https://blockstream.info/testnet/.
7. Re-open test: quit app, relaunch, open the wallet from the picker — the picker asks *connect device* vs *watch-only*; test both paths (watch-only must hide nothing except signing).

## B. Air-gap QR flow (no USB, no HWI)

**Bitcoin only.** Jade's QR mode carries Bitcoin alone — it exports no master blinding key and signs no PSET — so the air-gap setup builds a Bitcoin wallet and says so up front, and `create_watch_only_wallet` refuses an `airgap` + CT-descriptor pairing (`LIQUID_HW_UNSUPPORTED`). Liquid on a Jade means USB, flow A.

0. Unlock the device first. **QR PIN unlock is not self-contained**: the animated QR that appears after the PIN is a pinserver handshake, and something online has to scan it and show the reply back — that is the Blockstream app, not Templar. Fully offline alternative: Options → *Temporary Signer* (enter the recovery phrase on the device, no PIN, gone at reboot).
1. On the Jade: QR mode (Options → *QR Mode* on recent firmware) → **Options → Wallet → Export Xpub** → Native Segwit, Testnet → animated QR (BC-UR).
2. App → New Wallet → kind **Hardware** → **Air-gap** setup → scan the QR with the webcam (or paste the descriptor/xpub text). Since the import normalizer accepts bare xpubs, multipath descriptors, and `#checksum` suffixes, any of Jade's export formats works.
3. Fund + sync as above.
4. Sign test: Send wizard → the app shows the **unsigned PSBT as animated QR** (UR2) → scan it with the Jade camera → Jade displays outputs → approve → Jade shows the signed PSBT QR → scan it back with the webcam in the app → broadcast.

## What to record for each test

- Firmware version, HWI version (`hwi --version`).
- Exact failing command from the app log (`[hw] ...` lines on stderr) — the app shells out, so any failure reproduces in a terminal with the same `hwi` arguments.
- Known quirks: enumeration fails if Green is open; Jade auto-locks after idle → re-unlock and rescan; first Liquid sync is slow (full scan).
