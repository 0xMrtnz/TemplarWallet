# wallet-ffi

Rust FFI bridge between `templar_wallet` Flutter app and `templar-core`.

## Purpose

This crate exposes `templar-core` functionality over a C-compatible FFI boundary that `flutter_rust_bridge` can generate Dart bindings for.

## Planned bridge methods (Phase 13)

These correspond 1:1 to `WalletBridge` abstract class in `lib/bridge/wallet_bridge.dart`:

- `list_wallets() -> Vec<WalletSummaryDto>`
- `open_wallet(wallet_id: String)`
- `get_wallet_summary(wallet_id: String) -> DashboardDataDto`
- `generate_receive_address(wallet_id: String, asset: String) -> AddressInfoDto`
- `list_previous_addresses(wallet_id: String, asset: String) -> Vec<AddressInfoDto>`
- `list_activity(wallet_id: String) -> Vec<TransactionDto>`
- `list_utxos(wallet_id: String, chain: String) -> Vec<UtxoDto>`
- `get_wallet_info(wallet_id: String) -> WalletInfoDto`
- `sync_wallet(wallet_id: String)`

## Setup (Phase 13)

```bash
cargo init --lib
# Add to Cargo.toml: flutter_rust_bridge = "2"
# Run: flutter_rust_bridge_codegen generate
```
