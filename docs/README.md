# Docs map

Reference material only — nothing here is compiled or shipped except
`RELEASE_NOTES.md`, which every desktop release bundle carries as `README.md`.

| Path | What is in it |
|------|---------------|
| [`RELEASE_NOTES.md`](RELEASE_NOTES.md) | Install and first run, per platform — what a user reads |
| [`INSTALLAZIONE.md`](INSTALLAZIONE.md) | The same, in Italian |
| [`guides/`](guides) | Runbooks: hardware wallets, Jade, Liquid multisig, the Templar Protocol connector |
| [`build/`](build) | Platform build notes (Linux, Windows), builds on a helper PC, the release runbook |
| [`fixtures/`](fixtures) | Request fixtures for testing the Templar Protocol connector without a site |
| [`ANDROID_PORT.md`](ANDROID_PORT.md) | How the Android port was done and what it decided |
| [`guide.md`](guide.md) | Walkthrough of the wallet as the signing side of the Templar Protocol |

## Start here for…

- **What the app should look like** → [`../design.md`](../design.md), the rules
  every screen is held to; the tokens live in `src/templar_wallet/lib/theme/`.
- **How the UI talks to the engine** → `src/templar_wallet/lib/bridge/wallet_bridge.dart`
  (the Dart interface) and `src/wallet-ffi/src/dispatch.rs` (every JSON method).
- **Testing with a Jade / Ledger** → `guides/HARDWARE_TESTING.md`,
  `guides/JADE_TESTING.md`.
- **Liquid multisig setup and signing** → `guides/LIQUID_MULTISIG.md`.
- **Templar Protocol connector** (`templar://` links, escrow key, regtest,
  fixtures) → `guides/PROTOCOL_CONNECTOR.md`.
- **Cutting a release** → `build/RELEASE.md`.
