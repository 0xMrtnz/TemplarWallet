# Security

Templar Wallet handles keys, so security reports get priority over everything
else.

## Scope

The wallet runs on **Bitcoin testnet and Liquid testnet** (plus a local Liquid
regtest for development). It refuses mainnet by design, so no report can put
real funds at risk today — but the key handling, the encrypted vault and the
signing checks are the ones mainnet will use, and that is what matters.

Particularly interesting:

- anything that reads a recovery phrase or private key without the app
  password (the vault is Argon2id + XChaCha20-Poly1305, see
  `crates/templar-core/src/vault.rs`);
- a transaction the review screen shows one way and the signature commits to
  another (PSBT / PSET inspection in `crates/templar-core/src/bitcoin/psbt.rs`
  and `crates/templar-core/src/liquid/pset.rs`);
- a way to spend a frozen coin, or to make the wallet sign for a coin it
  should not;
- a `templar://` link or a QR code that makes the app do something the user
  did not confirm.

## Reporting

Please **do not open a public issue** for a vulnerability. Use GitHub's
private reporting instead: the repository's **Security** tab → **Report a
vulnerability**. Include what you did, what happened, and the version
(Settings › About).

You will get an answer within a few days. Fixes ship in a new release, and
the report is credited in the changelog unless you ask otherwise.
