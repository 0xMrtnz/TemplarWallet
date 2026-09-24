# CLAUDE.md — Templar Wallet

## What This Is

Templar Wallet is a Bitcoin + Liquid Network wallet for macOS, Windows, Linux
and Android. Its differentiator is
**Miniscript-powered custody**: wallets with real spending policies (timelocks,
hashlocks, thresholds, AND/OR logic) via predefined templates or a custom policy
builder — not just singlesig and basic multisig.

It is also the signing wallet of the Templar Protocol, a peer-to-peer lending
protocol on Liquid (`templar://` links, `docs/guides/PROTOCOL_CONNECTOR.md`).

**Testnet only.** Bitcoin testnet + Liquid testnet. No mainnet spending path.

## Architecture

Three layers. The Flutter app is the product.

```
TemplarWallet/
├── Cargo.toml                  # workspace: crates/templar-core, src/wallet-ffi
├── crates/templar-core/        # Backend. ZERO GUI deps.
│   └── src/
│       ├── lib.rs  error.rs (TemplarError)  config.rs  registry.rs
│       ├── types.rs  derivation.rs (SLIP-77)  qr.rs (UR2/SeedQR)
│       ├── frozen.rs           # frozen coins: per-wallet set + checks
│       ├── vault.rs            # Argon2id + XChaCha20 at-rest encryption
│       ├── policy/             # Miniscript engine: engine, templates,
│       │                       #   fragments, validator
│       ├── bitcoin/            # wallet (BDK), multisig, psbt, watch_only,
│       │   └── device/         #   hardware (hwi CLI) + native drivers:
│       │                       #   hid.rs, ledger.rs, jade_btc.rs
│       └── liquid/             # wallet (LWK), multisig, pset, assets,
│                               #   watch_only, hardware (Jade),
│                               #   liquidex.rs + book.rs (v0 swaps),
│                               #   protocol.rs (Templar Protocol escrow key)
│
├── src/wallet-ffi/             # C ABI bridge -> libwallet_ffi.{dylib,so,dll}
│   └── src/                    # lib.rs exports wallet_call + wallet_free_string
│       ├── dispatch.rs         # JSON method router
│       ├── state.rs            # AppFfiState: data dir, vault, instance lock
│       └── handlers/           # bitcoin, liquid, registry, wallet_ops, hw,
│                               #   history, psbt/vault, peg, swaps
│
└── src/templar_wallet/         # Flutter app (macOS / Linux / Windows / Android)
    ├── lib/
    │   ├── main.dart  app/shell.dart
    │   ├── bridge/             # ffi_wallet_bridge.dart (DynamicLibrary),
    │   │                       #   bridge_provider.dart
    │   ├── theme/              # app_colors, app_scheme, app_theme,
    │   │                       #   app_typography, app_motion, asset_palette
    │   ├── shared/widgets/     # design-system kit (glass_card, value_chart,
    │   │                       #   utxo_views, ur_qr, step_flow_scaffold, …)
    │   └── features/           # welcome, wallet_picker, create_wallet,
    │                           #   import_wallet, dashboard, send, receive,
    │                           #   history, utxos, wallet_info, psbt, liquid,
    │                           #   peg, swap, hardware, vault, protocol,
    │                           #   settings
    ├── assets/images/          # templar-wallet-logo.png, templar-cross.svg
    └── macos/ linux/ windows/ android/  # platform runners
```

### Data flow

Flutter → `wallet_call(json)` → `dispatch.rs` → handler → `templar-core` → BDK/LWK.
`bridge_provider.dart` falls back to `MockWalletBridge` when the dylib fails to
load — **a mock fallback can look like a working wallet**; check which bridge is
live before trusting any on-screen balance.

## Critical Constraints

1. **BDK 0.30** — RefCell internally, NOT thread-safe. During `sync()` no other
   wallet method may run. Wrapped in `Arc<Mutex<Option<WalletManager>>>`.
   Miniscript works inside `wsh()` but NOT inside `tr()` (needs BDK 1.x).
2. **LWK 0.9 modern API** — `Wollet::without_persist()`, `get_details(&pset)`,
   `finalize(&mut pset)`, `combine()`. Thread-safe. Never the old MemoryPersist
   pattern.
3. **Offline-first** — Electrum clients are constructed only in sync/broadcast
   paths, never in wallet constructors. Opening a wallet must work with no net.
4. **Vault encryption** — Argon2id + XChaCha20 at rest (`vault.rs`). Seed
   material is never written plaintext to the registry.
5. **Cross-OS parity** — runtime deps must resolve identically on macOS, Windows
   and Linux. No platform-divergent flows.
6. **English only** — code, comments, UI strings.
7. **Asset issuance is testnet-only** — Liquid › Issue / Reissue / Burn ship for
   testnet assets; the registry submission is refused on regtest.
8. **Frozen coins are never spent** — the set lives on the registry entry
   (`WalletEntry.frozen`, `frozen.rs`). Every builder takes it
   (`AppFfiState::frozen_on`): BDK leaves it out with `unspendable`, LWK with
   `set_wallet_utxos` where LWK allows it (L-BTC-only payments) and refuses
   otherwise; every signer runs `refuse_frozen_inputs` first. A new spend or
   sign path must do both.

## Brand

- Name: **Templar Wallet**. Bundle id `dev.templarwallet.templarWallet`.
  Binary/product name stays snake_case `templar_wallet`; CI renames the macOS
  bundle to `Templar Wallet.app`.
- Accent: **Templar crimson `#C1121F`** (`AppColors.accentDefault`). Every other
  accent shade derives from it — re-tint by changing that one constant.
- `danger` is `#EF4444`: brighter and lighter than the accent on purpose, since
  the brand colour is also red. Never darken it toward the accent.
- Logo source of truth: `assets/brand/templar-icon.svg` (badge) and
  `assets/brand/templar-cross.svg` (bare mark). All PNG/ICO rasters are build
  products — edit the SVG then run `./scripts/generate_icons.sh`.
- **`design.md` (repo root) is the rule set every screen is held to** — the
  gallery of surfaces, the single Action colour, chrome that recedes, the one
  shadow, and the small rewards. Read it before changing a pixel.

## Miniscript in BDK 0.30

Supported inside `wsh()`: `pk`, `multi(k,…)`, `and_v(v:pk(A),older(N))`,
`and_v(v:pk(A),after(N))`, `and_v(v:pk(A),sha256(H))`,
`or_d(pk(A),and_v(v:pk(B),older(N)))`, `thresh(k,…)`, `andor(A,B,C)`.

Not supported (deferred to BDK 1.x): `tr(...)` Taproot script paths, `musig(...)`.

## LWK 0.9 patterns

```rust
// Singlesig
let signer = SwSigner::new(mnemonic, false)?;      // false = testnet
let desc   = signer.wpkh_slip77_descriptor()?;
let wollet = Wollet::without_persist(ElementsNetwork::LiquidTestnet, desc)?;

// Multisig 2-of-3 — ct() only accepts ELEMENTS scripts (elwsh/elwpkh),
// plain wpkh inside ct() is rejected.
let desc = format!(
    "ct(slip77({blinding}),elwsh(multi(2,{a}/<0;1>/*,{b}/<0;1>/*,{c}/<0;1>/*)))"
);

// PSET: inspect before signing — this is the multi-party security gate.
let details = wollet.get_details(&pset)?;   // fee, recipients,
                                            // fingerprints_has/_missing
let n = signer.sign(&mut pset)?;
wollet.combine(&mut base, &signed_by_bob)?; // parallel signing
let tx = wollet.finalize(&mut pset)?;
```

Jade descriptors must use the **device's** slip77 key, never elip151.
Liquid hardware support is **Jade-only**.

## Key Dependencies

| Crate | Version | Role |
|-------|---------|------|
| bdk | 0.30 | Bitcoin wallet engine (Miniscript wsh) |
| lwk_wollet / lwk_signer / lwk_common | 0.9 | Liquid |
| lwk_jade | 0.9 (serial) | Jade transport |
| hidapi | 2.6 | Ledger + HID signers, in-process |
| serialport | 4.9 | Jade (USB-CDC) |
| sled | 0.34 | BDK embedded DB |
| thiserror | 1.0 | Typed errors |

Flutter: go_router, provider, qr_flutter, mobile_scanner, google_fonts, ffi,
file_selector, shared_preferences, app_links, share_plus, url_launcher.

## Servers & faucets

- Bitcoin testnet Electrum: `ssl://electrum.blockstream.info:60002`
  (`TEMPLAR_ELECTRUM_URL` overrides)
- Liquid testnet Electrum: `elements-testnet.blockstream.info:50002`
  (`TEMPLAR_LIQUID_ELECTRUM_URL` overrides)
- Faucets: https://liquidtestnet.com/faucet · https://faucet.vulpem.com

## Env overrides

`TEMPLAR_DATA_DIR`, `TEMPLAR_HWI_BIN`, `TEMPLAR_ELECTRUM_URL`,
`TEMPLAR_LIQUID_ELECTRUM_URL`, `TEMPLAR_SWAP_BOOK_URL`.

Liquid network (`crates/templar-core/src/liquid/{network,chain}.rs`):
`TEMPLAR_LIQUID_NETWORK=testnet|regtest` (locks the Settings switch; default =
the value saved in `AppConfig`, else testnet), `TEMPLAR_LIQUID_REGTEST_POLICY_ASSET`,
`TEMPLAR_LIQUID_BACKEND=electrum|elements_rpc` (default: electrum on testnet,
`elementsd` RPC on regtest), `TEMPLAR_LIQUID_ELECTRUM_TLS=0|1`,
`TEMPLAR_ELEMENTS_RPC_URL/USER/PASS` (default `http://127.0.0.1:18884`,
`templar`/`templar` — the Templar Protocol's local regtest node). Core keeps no
global network:
the FFI state passes it to the `*_on` constructors; the no-suffix constructors
read the env and default to testnet (what the Templar Protocol relies on). Peg,
public order book and asset-registry submission are refused on regtest.

## Build & Run

```bash
# Rust (the workspace is templar-core + wallet-ffi only)
cargo test -p templar-core -p wallet-ffi
cargo clippy -p templar-core -p wallet-ffi --all-targets -- -D warnings
cargo fmt --all

# App — the Xcode Run Script phase builds and bundles libwallet_ffi.dylib
cd src/templar_wallet
flutter pub get
flutter analyze            # zero issues, infos included
flutter test
flutter run -d macos

# Brand rasters, after editing assets/brand/*.svg (macOS only)
./scripts/generate_icons.sh
```

`scripts/setup_hwi_macos.sh` installs the app-managed HWI venv.
`scripts/build_android.sh --release` builds the APKs (one per ABI).
`scripts/pack_source.sh` zips the working tree for someone else's PC, where
`scripts/build_linux.sh` (Docker, Ubuntu 22.04) and `scripts/build_windows.ps1`
build the Linux and Windows bundles CI would (`docs/build/HELPER_BUILDS.md`).

CI, all on GitHub-hosted runners (never attach a self-hosted runner to this
public repo): `.github/workflows/ci.yml` gates every push to `main` and every
PR with the Rust and Flutter checks above (Rust and Flutter versions pinned
in the workflow). `.github/workflows/release.yml` builds macOS (universal
DMG), Windows (installer + zip), Linux (tarball, Ubuntu 22.04) and Android
(two APKs, release-signed from repository secrets) and, on a `vX.Y.Z` tag
matching the pubspec version, publishes the release only if every build
passed, under version-less names the website links to via
`/releases/latest/download/`. Runbook, signing key and stable links:
`docs/build/RELEASE.md`.

## Docs

Everything reference-only lives under `docs/` — see `docs/README.md` for the map.
