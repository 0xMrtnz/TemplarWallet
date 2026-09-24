//! Open wallet — initialize BDK + LWK managers from registry entry.

use templar_core::{LiquidWalletManager, WalletManager, WalletProfile};

use crate::state::{AppFfiState, ChainSyncOutcome};

/// Open a wallet by ID — initializes WalletManager and optionally LiquidWalletManager.
/// Stores them in `state.bitcoin` and `state.liquid`.
pub fn open_wallet(state: &mut AppFfiState, wallet_id: &str) -> Result<(), String> {
    let entry = state
        .registry
        .find(wallet_id)
        .ok_or_else(|| format!("Wallet not found: {}", wallet_id))?
        .clone();

    let data_dir = state.data_dir.clone();

    // Clear state from the previous wallet so no asset metadata, UTXOs, or liquid
    // state from wallet A bleeds into wallet B. active_wallet_id must clear too:
    // it is only set again on success, so a failed open can never leave a stale
    // id that makes ensure_wallet_open skip the re-open and strand every later
    // call on "Bitcoin wallet not open".
    state.asset_registry.clear_local_metadata();
    state.bitcoin = None;
    state.liquid = None;
    state.active_wallet_id = None;
    // Sync outcomes belong to the previous wallet — the new one starts out
    // "never synced" so the dashboard cannot inherit a stale green state.
    state.last_sync_btc = None;
    state.last_sync_liquid = None;
    state.last_sync_at = None;

    let liq_data_dir = Some(data_dir.as_path());
    let liq_network = state.liquid_network.clone();

    // A hardware-wallet profile can hold either a Bitcoin descriptor (wpkh/pkh/...)
    // or a Liquid CT descriptor (ct(...)) — a Liquid-only entry. The CT case has no
    // entry.liquid config, so route it straight to the Liquid manager and skip the
    // Bitcoin manager entirely (from_descriptors can't parse ct(...)).
    //
    // `has_bitcoin` is the same test the wallet summaries answer with, so what the
    // UI offers and what this opens cannot disagree — a wallet advertising Bitcoin
    // it has no manager for is the "Bitcoin wallet not open" error users hit.
    let hw_liquid_desc = match &entry.profile {
        WalletProfile::HardwareWallet {
            receive_descriptor, ..
        } if !entry.has_bitcoin() => Some(receive_descriptor.clone()),
        _ => None,
    };

    // Build Bitcoin WalletManager from profile. `None` = this profile has no BTC
    // wallet (e.g. a Liquid-only HW entry); only `Some(Err)` is a real failure.
    let btc_result: Option<Result<WalletManager, String>> = match &entry.profile {
        WalletProfile::Software { mnemonic } => {
            Some(WalletManager::new(&data_dir, mnemonic).map_err(|e| e.to_string()))
        }
        WalletProfile::HardwareWallet { .. } if hw_liquid_desc.is_some() => None,
        WalletProfile::HardwareWallet {
            receive_descriptor,
            change_descriptor,
            ..
        } => Some(
            WalletManager::from_descriptors(
                &data_dir,
                receive_descriptor,
                change_descriptor,
                // Key the BDK db by the unique wallet id, not the device fingerprint.
                // Two wallets on one device (or a deleted-then-recreated wallet) share a
                // fingerprint; keying by it makes them collide on one sled db, which BDK
                // rejects when the stored descriptor differs from the new one.
                &format!("hw_{}", wallet_id),
            )
            .map_err(|e| e.to_string()),
        ),
        WalletProfile::Multisig { .. } | WalletProfile::Policy { .. } => Some(
            WalletManager::from_multisig_profile(&data_dir, &entry.profile, wallet_id)
                .map_err(|e| e.to_string()),
        ),
    };

    // Remember a BTC init failure so we can surface it after attempting liquid,
    // instead of silently leaving state.bitcoin = None and failing later with a
    // generic "Bitcoin wallet not open".
    let btc_init_err = match btc_result {
        Some(Ok(mgr)) => {
            state.bitcoin = Some(mgr);
            None
        }
        Some(Err(e)) => {
            eprintln!("[wallet-ffi] BTC wallet init error: {}", e);
            Some(e)
        }
        None => None,
    };

    // Liquid-only hardware wallet: open the CT descriptor as a watch-only LWK wallet.
    // This entry has no Bitcoin side — if Liquid can't open, the wallet is unusable,
    // so fail loudly instead of showing an empty dashboard.
    if let Some(desc) = &hw_liquid_desc {
        match LiquidWalletManager::watch_only_with_persist_on(&liq_network, desc, liq_data_dir) {
            Ok(mgr) => state.liquid = Some(mgr),
            Err(e) => {
                state.bitcoin = None;
                return Err(format!("Failed to open Liquid wallet: {e}"));
            }
        }
    }

    // Build Liquid wallet — from saved descriptor, or auto-generate for Software wallets.
    // Pass data_dir so LWK uses FsPersister for incremental on-disk caching (faster re-opens).
    if let Some(liq_cfg) = &entry.liquid {
        let liq_result = match &entry.profile {
            WalletProfile::Software { mnemonic } => LiquidWalletManager::new_with_persist_on(
                &liq_network,
                mnemonic,
                &liq_cfg.descriptor,
                liq_data_dir,
            )
            .map_err(|e| e.to_string()),
            _ => LiquidWalletManager::watch_only_with_persist_on(
                &liq_network,
                &liq_cfg.descriptor,
                liq_data_dir,
            )
            .map_err(|e| e.to_string()),
        };
        match liq_result {
            Ok(mgr) => state.liquid = Some(mgr),
            // This wallet explicitly has Liquid enabled: opening it without the
            // Liquid side would silently show a wrong (BTC-only) balance. Fail
            // the open so the UI reports the real problem, e.g. a descriptor
            // that was stored malformed by an older build.
            Err(e) => {
                state.bitcoin = None;
                return Err(format!("Failed to open Liquid wallet: {e}"));
            }
        }
    } else if let WalletProfile::Software { mnemonic } = &entry.profile {
        // No saved liquid descriptor — derive default WPKH SLIP77 wallet automatically
        eprintln!("[wallet-ffi] No liquid config found, auto-deriving from mnemonic...");
        match LiquidWalletManager::from_mnemonic_with_persist_on(
            &liq_network,
            mnemonic,
            liq_data_dir,
        ) {
            Ok(mgr) => {
                eprintln!(
                    "[wallet-ffi] Liquid auto-init OK on {liq_network}, descriptor={}",
                    mgr.descriptor
                );
                state.liquid = Some(mgr);
            }
            Err(e) => eprintln!("[wallet-ffi] Liquid auto-init ERROR: {}", e),
        }
    } else {
        eprintln!(
            "[wallet-ffi] No liquid config and non-Software profile — liquid wallet not opened"
        );
    }

    // Load asset metadata from the wallet's liquid config into the asset registry
    if let Some(liq_cfg) = &entry.liquid {
        for meta in &liq_cfg.asset_metadata {
            state.asset_registry.add_local_metadata(meta.clone());
        }
        eprintln!(
            "[wallet-ffi] Loaded {} asset metadata entries from wallet config",
            liq_cfg.asset_metadata.len()
        );
    }

    // If the wallet has no Liquid-only role and BTC failed to open, the open is a
    // failure — report the real reason rather than letting later calls hit the
    // generic "Bitcoin wallet not open".
    if state.bitcoin.is_none() {
        if let Some(e) = btc_init_err {
            return Err(format!("Failed to open Bitcoin wallet: {e}"));
        }
    }

    state.active_wallet_id = Some(wallet_id.to_string());

    Ok(())
}

/// Sync BTC wallet (blocking — BDK RefCell requires single-threaded access).
///
/// A missing manager is only `Skipped` when the active wallet legitimately has
/// no Bitcoin side (a Liquid-only ct() entry). For every other profile it is
/// an `Error` — silently returning Ok here let the footer go green without a
/// Bitcoin wallet ever opening (e.g. sled lock held by another process).
pub fn sync_bitcoin(state: &mut AppFfiState) -> ChainSyncOutcome {
    match &state.bitcoin {
        Some(mgr) => match mgr.sync() {
            Ok(()) => ChainSyncOutcome::Ok,
            Err(e) => ChainSyncOutcome::Error(e.to_string()),
        },
        None if active_wallet_is_liquid_only(state) => ChainSyncOutcome::Skipped,
        None => {
            eprintln!("[wallet-ffi] BTC sync failed — no Bitcoin wallet loaded (Sled lock held by another process?)");
            ChainSyncOutcome::Error(
                "Bitcoin wallet is not open — reopen the wallet (its database may be \
                 locked by another instance)"
                    .to_string(),
            )
        }
    }
}

/// Sync Liquid wallet.
pub fn sync_liquid(state: &mut AppFfiState) -> ChainSyncOutcome {
    match &mut state.liquid {
        Some(mgr) => match mgr.sync() {
            Ok(()) => ChainSyncOutcome::Ok,
            Err(e) => ChainSyncOutcome::Error(e.to_string()),
        },
        None => ChainSyncOutcome::Skipped, // no liquid wallet is fine
    }
}

/// True when the active wallet is a Liquid-only entry (a hardware/watch-only
/// profile whose descriptor is a CT descriptor) — such wallets have no Bitcoin
/// side by design, so skipping the BTC sync is legitimate.
fn active_wallet_is_liquid_only(state: &AppFfiState) -> bool {
    let Some(id) = state.active_wallet_id.as_deref() else {
        return false;
    };
    match state.registry.find(id).map(|e| &e.profile) {
        Some(WalletProfile::HardwareWallet {
            receive_descriptor, ..
        }) => receive_descriptor.trim_start().starts_with("ct("),
        _ => false,
    }
}
