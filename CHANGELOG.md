# Changelog

All notable changes to Templar Wallet. Versions follow
[Semantic Versioning](https://semver.org); while the version starts with 0,
any release may change anything.

## [0.1.0] — 2026-09-24

The first public release. Testnet only: Bitcoin testnet and Liquid testnet,
plus a local Liquid regtest for development. Mainnet is refused by design.

### Wallets

- Software single-sig (BIP84) with Bitcoin and, optionally, Liquid from the
  same recovery phrase.
- Multisig on Bitcoin (P2WSH, BIP48 keys) and Liquid (BIP87 keys, shared
  blinding key), created in a guided wizard; keys from this device, other
  devices, hardware wallets or QR.
- Miniscript policy wallets from templates or a policy builder: timelocks,
  hashlocks, thresholds, AND/OR.
- Watch-only wallets from descriptors, hardware wallets (Ledger and Jade over
  USB, Trezor / Coldcard / KeepKey / BitBox through HWI on Windows and Linux)
  and air-gapped signing over animated QR (BC-UR).

### Security

- Recovery phrases are sealed in a vault (Argon2id + XChaCha20-Poly1305)
  behind an app password; nothing secret is written in the clear.
- Touch ID on macOS and fingerprint unlock on Android; auto-lock after a
  chosen idle time; the password (or Touch ID) is asked again before a send
  is signed and before the recovery phrase is shown.
- Co-signing refuses a transaction whose amounts it cannot prove: Bitcoin
  inputs without consistent previous outputs, Liquid outputs whose blinded
  amounts do not open.
- Fee rates are held to 0.1–1000 sat/vB, absurd fees are refused, every
  Bitcoin transaction signals RBF.

### Coin control

- The UTXO screen shows every coin as a banknote or a row, sized by its share
  of the asset's holdings, with labels, details and a link to the explorer.
- **Freeze coins**: select them and press Freeze, or use the button in a
  coin's details. A frozen coin stays in the balance, but the engine never
  spends it — automatic selection and MAX leave it out, the send wizard's
  picker shows it locked, consolidation skips it, and a PSBT or PSET that
  would spend it (even one built by a co-signer or a protocol site) is
  refused before signing. On Liquid, a payment that moves an asset other
  than L-BTC cannot leave coins out yet, so it is refused with the reason
  instead. Unfreeze the same way.
- Consolidation of Bitcoin coins, reviewed and signed like any other
  transaction; incoming coins show as pending until they confirm.

### Everything else

- Guided send (several recipients, MAX, fee presets, manual inputs) and
  receive with BIP21 payment requests; activity and a portfolio chart.
- PSBT / PSET co-signing: import by paste, file or camera, inspect what the
  transaction does, sign, merge co-signers' copies, broadcast.
- Liquid assets: issuance, reissuance and burn on testnet; LiquiDEX swaps;
  peg-in / peg-out against a simulated provider.
- Templar Protocol connector: `templar://` links let a Templar Protocol site
  ask this wallet to connect or sign a loan transaction, which the wallet
  shows next to its own reading of it and signs only after you confirm.
- macOS, Windows (installer and portable zip), Linux and Android builds,
  published by CI with fixed download links.
