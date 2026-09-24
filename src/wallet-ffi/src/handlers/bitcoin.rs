//! Bitcoin wallet operations — balance, addresses, UTXOs, transactions, send.

use templar_core::bitcoin::wallet::refuse_frozen_inputs;
use templar_core::{
    check_input_utxos, inspect_psbt, public_descriptor, CoinChain, WalletManager, WalletProfile,
};

use crate::state::{AppFfiState, ChainSyncOutcome};
use crate::types::{
    AddressInfoDto, AssetBalanceDto, DashboardDto, PsbtInputDto, PsbtInspectionDto, PsbtOutputDto,
    PsbtSignerDto, RecentActivityDto, TransactionDto, TxIoDto, TxPreviewDto, UtxoDto,
    WalletInfoDto,
};

const DUST_THRESHOLD: u64 = 546;

pub fn get_dashboard(state: &AppFfiState, wallet_id: &str) -> Result<DashboardDto, String> {
    let entry = state.registry.find(wallet_id).ok_or("Wallet not found")?;

    // A Liquid-only entry (hardware ct() descriptor) has no Bitcoin side at
    // all — a zero BTC row and a BTC-denominated total would be fabricated
    // data, so the BTC row is suppressed entirely.
    // Same predicate the wallet summaries and `open_wallet` use, so what the
    // dashboard shows and what was actually opened cannot disagree.
    let is_liquid_only = !entry.has_bitcoin();

    // Per-asset status follows the recorded sync outcome — "synced" is only
    // ever claimed after a sync actually succeeded on that chain.
    let btc_status = match &state.last_sync_btc {
        Some(ChainSyncOutcome::Ok) => "synced",
        _ => "not synced",
    };
    let mut assets: Vec<AssetBalanceDto> = Vec::new();
    let mut balance_sats: i64 = 0;
    if !is_liquid_only {
        let btc_asset = if let Some(mgr) = &state.bitcoin {
            let bal = mgr.get_balance().map_err(|e| e.to_string())?;
            let total = bal.confirmed + bal.untrusted_pending + bal.trusted_pending;
            balance_sats = total as i64;
            AssetBalanceDto {
                asset_id: "BTC".to_string(),
                ticker: "BTC".to_string(),
                name: "Bitcoin".to_string(),
                amount: total as i64,
                display_amount: format_btc(total),
                fiat_estimate: None,
                status: btc_status.to_string(),
                utxo_count: mgr.list_unspent().map(|u| u.len()).unwrap_or(0),
                is_native: true,
            }
        } else {
            btc_zero()
        };
        assets.push(btc_asset);
    }

    // L-BTC balance, captured for the Liquid-only total below.
    let mut liquid_lbtc: Option<u64> = None;

    // Add Liquid assets if liquid wallet open
    if let Some(liq) = &state.liquid {
        // A failed balance read must NOT masquerade as an all-zero balance —
        // keep every row but mark it "unavailable" (offline node, cache error).
        let bal = match liq.get_balance() {
            Ok(b) => Some(b),
            Err(e) => {
                eprintln!("[wallet-ffi] Liquid balance read failed: {e}");
                None
            }
        };
        let liq_status = match (&bal, &state.last_sync_liquid) {
            (None, _) => "unavailable",
            (Some(_), Some(ChainSyncOutcome::Ok)) => "synced",
            _ => "not synced",
        };

        // How many coins back each asset. Liquid rows used to hard-code 0,
        // which rendered every asset card as "0 UTXOs" no matter what the
        // wallet held. One pass over the coin set, indexed by asset id.
        let mut liquid_utxo_counts: std::collections::HashMap<String, usize> =
            std::collections::HashMap::new();
        if let Ok(utxos) = liq.wollet.utxos() {
            for u in utxos {
                *liquid_utxo_counts
                    .entry(u.unblinded.asset.to_string())
                    .or_insert(0) += 1;
            }
        }

        // Always show LBTC (even at 0 — indicates liquid wallet is connected).
        // The policy asset is the open wallet's own, so a regtest wallet
        // reports its node's L-BTC and not the testnet id.
        let policy_asset = liq.policy_asset_hex();
        let lbtc = bal.as_ref().map(|b| b.lbtc());
        liquid_lbtc = lbtc;
        assets.push(AssetBalanceDto {
            asset_id: policy_asset.clone(),
            ticker: "LBTC".to_string(),
            name: "Liquid Bitcoin".to_string(),
            amount: lbtc.unwrap_or(0) as i64,
            display_amount: lbtc.map(format_btc).unwrap_or_else(|| "—".to_string()),
            fiat_estimate: None,
            status: liq_status.to_string(),
            utxo_count: liquid_utxo_counts.get(&policy_asset).copied().unwrap_or(0),
            is_native: false,
        });

        // Track which asset IDs we've already added
        let mut shown = std::collections::HashSet::new();
        shown.insert(policy_asset.clone());

        // Assets with actual on-chain balance (post-sync)
        if let Some(bal) = &bal {
            for (aid, amount) in &bal.assets {
                if *aid == policy_asset {
                    continue;
                }
                shown.insert(aid.clone());
                let meta = state.asset_registry.get_local_metadata(aid);
                let ticker = meta
                    .and_then(|m| m.ticker.as_deref())
                    .unwrap_or_else(|| state.asset_registry.ticker(aid))
                    .to_string();
                let name = meta.map(|m| m.name.as_str()).unwrap_or(&ticker).to_string();
                let status = if meta.is_some() {
                    liq_status
                } else {
                    "third-party"
                };
                assets.push(AssetBalanceDto {
                    asset_id: aid.clone(),
                    ticker,
                    name,
                    amount: *amount as i64,
                    // Per-asset precision from the registry (issued-asset
                    // metadata or defaults), not a raw satoshi count.
                    display_amount: state
                        .asset_registry
                        .format_amount_with_fallback(aid, *amount),
                    fiat_estimate: None,
                    status: status.to_string(),
                    utxo_count: liquid_utxo_counts.get(aid).copied().unwrap_or(0),
                    is_native: false,
                });
            }
        }

        // Known assets from local metadata not yet in balance (show at 0 before
        // sync; "—" when the balance itself could not be read).
        for (aid, meta) in &state.asset_registry.local_metadata {
            if shown.contains(aid) {
                continue;
            }
            let ticker = meta.ticker.as_deref().unwrap_or("").to_string();
            let status = if meta.is_reissuance_token {
                "reissue-token"
            } else {
                liq_status
            };
            assets.push(AssetBalanceDto {
                asset_id: aid.clone(),
                ticker: ticker.clone(),
                name: meta.name.clone(),
                amount: 0,
                display_amount: if bal.is_some() {
                    state.asset_registry.format_amount_with_fallback(aid, 0)
                } else {
                    "—".to_string()
                },
                fiat_estimate: None,
                status: status.to_string(),
                utxo_count: liquid_utxo_counts.get(aid).copied().unwrap_or(0),
                is_native: false,
            });
        }
    }

    let recent_activity = get_recent_activity(state).unwrap_or_default();

    // Liquid-only wallets total in L-BTC ("—" while the balance is
    // unreadable); everything else keeps the BTC-denominated total.
    let total_display = if is_liquid_only {
        match liquid_lbtc {
            Some(v) => format!("{:.8} L-BTC", v as f64 / 1e8),
            None => "—".to_string(),
        }
    } else {
        format_btc(balance_sats as u64)
    };

    Ok(DashboardDto {
        wallet_id: wallet_id.to_string(),
        wallet_name: entry.name.clone(),
        total_balance_display: total_display,
        sync_state: derive_sync_state(state).to_string(),
        assets,
        recent_activity,
        liquid_network: state.liquid_network.name().to_string(),
    })
}

/// Wallet-level sync state from the recorded per-chain outcomes:
/// `"never"` (no sync since this wallet was opened), `"synced"` (every present
/// chain synced), `"partial"` (some chains failed), `"error"` (all failed).
fn derive_sync_state(state: &AppFfiState) -> &'static str {
    let attempted: Vec<&ChainSyncOutcome> = [&state.last_sync_btc, &state.last_sync_liquid]
        .into_iter()
        .flatten()
        .filter(|o| !matches!(o, ChainSyncOutcome::Skipped))
        .collect();
    if attempted.is_empty() {
        return "never";
    }
    let ok = attempted
        .iter()
        .filter(|o| matches!(o, ChainSyncOutcome::Ok))
        .count();
    if ok == attempted.len() {
        "synced"
    } else if ok > 0 {
        "partial"
    } else {
        "error"
    }
}

fn get_recent_activity(state: &AppFfiState) -> Result<Vec<RecentActivityDto>, String> {
    let mut items: Vec<RecentActivityDto> = Vec::new();

    if let Some(btc) = &state.bitcoin {
        let tip = btc.get_tip_height();
        let txs = btc.list_transactions().map_err(|e| e.to_string())?;
        for tx in txs.iter().take(5) {
            let direction = if tx.received > tx.sent {
                "incoming"
            } else {
                "outgoing"
            };
            let net = tx.received as i64 - tx.sent as i64;
            let amount = if net >= 0 {
                format!("+{}", format_btc(net as u64))
            } else {
                format!("-{}", format_btc((-net) as u64))
            };
            let confirmations = tx
                .confirmation_time
                .as_ref()
                .map(|ct| tip.saturating_sub(ct.height) + 1)
                .unwrap_or(0);
            items.push(RecentActivityDto {
                txid: tx.txid.to_string(),
                direction: direction.to_string(),
                chain: "bitcoin".to_string(),
                amount,
                ticker: "BTC".to_string(),
                timestamp: tx
                    .confirmation_time
                    .as_ref()
                    .map(|c| c.timestamp as i64)
                    .unwrap_or(0),
                confirmations,
                note: None,
                counterparty: None,
            });
        }
    }

    if let Some(liq) = &state.liquid {
        if let Ok(txs) = liq.list_transactions() {
            let liq_tip = txs.iter().filter_map(|t| t.height).max().unwrap_or(0);
            for tx in txs.iter().take(3) {
                let confirmations = tx
                    .height
                    .map(|h| liq_tip.saturating_sub(h) + 1)
                    .unwrap_or(0);
                // One row per asset the transaction actually moved — a token
                // transfer must not surface as an empty/misleading L-BTC row.
                for (asset_id, delta) in liquid_delta_rows(&tx.balance, &state.policy_asset_hex()) {
                    let direction = if delta >= 0 { "incoming" } else { "outgoing" };
                    let (ticker, amount) = liquid_delta_display(state, &asset_id, delta);
                    items.push(RecentActivityDto {
                        txid: tx.txid.clone(),
                        direction: direction.to_string(),
                        chain: "liquid".to_string(),
                        amount,
                        ticker,
                        timestamp: tx.timestamp.map(|t| t as i64).unwrap_or(0),
                        confirmations,
                        note: None,
                        counterparty: None,
                    });
                }
            }
        }
    }

    items.sort_by(|a, b| newest_first(a.timestamp, a.confirmations, b.timestamp, b.confirmations));
    Ok(items)
}

/// Newest first, with everything unconfirmed at the very top.
///
/// Both engines report no block time for an unconfirmed transaction, which
/// arrives here as `timestamp: 0`. Sorting on that value alone dates the
/// newest transaction in the wallet to 1970 and buries it under years of
/// history — the transaction the user just broadcast is the one they are
/// looking for.
fn newest_first(a_ts: i64, a_conf: u32, b_ts: i64, b_conf: u32) -> std::cmp::Ordering {
    match (a_conf == 0, b_conf == 0) {
        (true, false) => std::cmp::Ordering::Less,
        (false, true) => std::cmp::Ordering::Greater,
        _ => b_ts.cmp(&a_ts),
    }
}

/// Current receive address, or — with `fresh` — the *next* one.
///
/// The receive screen loads the last unused address (so revisiting it does not
/// burn indexes); the "New address" button asks for `fresh`, which advances the
/// derivation index even if the current address never received anything.
/// Liquid CT addresses stay stable and ignore `fresh`.
pub fn generate_receive_address(
    state: &AppFfiState,
    asset: &str,
    fresh: bool,
) -> Result<AddressInfoDto, String> {
    match asset {
        // The Flutter UI sends the bare ticker "LBTC"; older callers used
        // "L-BTC"/"liquid". Accept all so the Liquid tab never silently falls
        // through to the Bitcoin branch and hands back a BTC address.
        "LBTC" | "L-BTC" | "liquid" => {
            let liq = state.liquid.as_ref().ok_or("Liquid wallet not open")?;
            let addr = liq.get_new_address().map_err(|e| e.to_string())?;
            Ok(AddressInfoDto {
                address: addr,
                index: 0,
                asset: asset.to_string(),
                label: None,
                received_sats: 0,
                derivation_path: None,
            })
        }
        _ => {
            let btc = state.bitcoin.as_ref().ok_or("Bitcoin wallet not open")?;
            let info = if fresh {
                btc.get_fresh_address().map_err(|e| e.to_string())?
            } else {
                btc.get_new_address().map_err(|e| e.to_string())?
            };
            Ok(AddressInfoDto {
                address: info.address.to_string(),
                index: info.index,
                asset: "BTC".to_string(),
                label: None,
                received_sats: 0,
                derivation_path: None,
            })
        }
    }
}

pub fn list_transactions(state: &AppFfiState) -> Result<Vec<TransactionDto>, String> {
    let mut result: Vec<TransactionDto> = Vec::new();

    if let Some(btc) = &state.bitcoin {
        let tip = btc.get_tip_height();
        let txs = btc.list_transactions().map_err(|e| e.to_string())?;
        for tx in txs {
            let net = tx.received as i64 - tx.sent as i64;
            let direction = if net >= 0 { "incoming" } else { "outgoing" };
            let amount = if net >= 0 {
                format!("+{}", format_btc(net as u64))
            } else {
                format!("-{}", format_btc((-net) as u64))
            };
            let confirmations = tx
                .confirmation_time
                .as_ref()
                .map(|ct| tip.saturating_sub(ct.height) + 1)
                .unwrap_or(0);
            result.push(TransactionDto {
                txid: tx.txid.to_string(),
                direction: direction.to_string(),
                chain: "bitcoin".to_string(),
                amount,
                ticker: "BTC".to_string(),
                timestamp: tx
                    .confirmation_time
                    .as_ref()
                    .map(|c| c.timestamp as i64)
                    .unwrap_or(0),
                confirmations,
                fee: tx.fee.map(|f| format!("{} sats", f)),
                note: None,
                counterparty: None,
                fiat_estimate: None,
            });
        }
    }

    if let Some(liq) = &state.liquid {
        if let Ok(txs) = liq.list_transactions() {
            let liq_tip = txs.iter().filter_map(|t| t.height).max().unwrap_or(0);
            for tx in txs {
                let confirmations = tx
                    .height
                    .map(|h| liq_tip.saturating_sub(h) + 1)
                    .unwrap_or(0);
                // One row per asset delta (L-BTC first). The fee rides on the
                // first row only, so a multi-asset tx doesn't repeat it.
                let fee = format!("{} sats", tx.fee);
                for (i, (asset_id, delta)) in
                    liquid_delta_rows(&tx.balance, &state.policy_asset_hex())
                        .into_iter()
                        .enumerate()
                {
                    let direction = if delta >= 0 { "incoming" } else { "outgoing" };
                    let (ticker, amount) = liquid_delta_display(state, &asset_id, delta);
                    result.push(TransactionDto {
                        txid: tx.txid.clone(),
                        direction: direction.to_string(),
                        chain: "liquid".to_string(),
                        amount,
                        ticker,
                        timestamp: tx.timestamp.map(|t| t as i64).unwrap_or(0),
                        confirmations,
                        fee: (i == 0).then(|| fee.clone()),
                        note: None,
                        counterparty: None,
                        fiat_estimate: None,
                    });
                }
            }
        }
    }

    result.sort_by(|a, b| newest_first(a.timestamp, a.confirmations, b.timestamp, b.confirmations));
    Ok(result)
}

pub fn list_utxos(state: &AppFfiState, chain: &str) -> Result<Vec<UtxoDto>, String> {
    match chain.to_lowercase().as_str() {
        "liquid" => {
            let liq = state.liquid.as_ref().ok_or("Liquid wallet not open")?;
            let frozen = state.frozen_on(CoinChain::Liquid);
            let utxos = liq.wollet.utxos().map_err(|e| e.to_string())?;
            // Real depth against the synced chain tip. The highest block any
            // wallet transaction landed in is only a floor — a coin with no
            // later wallet activity would read "1 confirmation" forever — so
            // it is used only when the wallet has never synced (tip 0).
            let synced_tip = liq.wollet.tip().height();
            let liq_tip = if synced_tip > 0 {
                synced_tip
            } else {
                liq.list_transactions()
                    .map(|txs| txs.iter().filter_map(|t| t.height).max().unwrap_or(0))
                    .unwrap_or(0)
            };
            Ok(utxos
                .into_iter()
                .map(|u| {
                    let amount = u.unblinded.value;
                    let outpoint = format!("{}:{}", u.outpoint.txid, u.outpoint.vout);
                    let asset_id = u.unblinded.asset.to_string();
                    let is_policy = state.is_policy_asset(&asset_id);
                    let (ticker, display_amount) = if is_policy {
                        (
                            "L-BTC".to_string(),
                            format!("{:.8} L-BTC", amount as f64 / 1e8),
                        )
                    } else {
                        // Registry-resolved ticker + per-asset precision
                        // (falls back to a short asset-id prefix / 8 decimals
                        // for unknown third-party assets).
                        let ticker = state.asset_registry.ticker(&asset_id).to_string();
                        let value = state
                            .asset_registry
                            .format_amount_with_fallback(&asset_id, amount);
                        (ticker.clone(), format!("{value} {ticker}"))
                    };
                    let confirmations: u32 =
                        u.height.map(|h| liq_tip.saturating_sub(h) + 1).unwrap_or(0);
                    // An incoming coin that has not confirmed is pending
                    // first and anything else second; dust only means
                    // something for the policy asset, where a satoshi is a
                    // satoshi.
                    // Frozen leads: it is the one state the user chose, and
                    // the one that decides whether the coin can be spent.
                    let state_label = if frozen.contains(&outpoint) {
                        "frozen"
                    } else if u.height.is_none() {
                        "unconfirmed"
                    } else if is_policy && amount <= DUST_THRESHOLD {
                        "dusty"
                    } else {
                        "available"
                    };
                    UtxoDto {
                        outpoint,
                        amount: amount as i64,
                        display_amount,
                        confirmations,
                        state: state_label.to_string(),
                        label: None,
                        address: Some(u.address.to_string()),
                        ticker: Some(ticker),
                        asset_id: Some(asset_id),
                    }
                })
                .collect())
        }
        _ => {
            let btc = state.bitcoin.as_ref().ok_or("Bitcoin wallet not open")?;
            let utxos = btc.list_unspent().map_err(|e| e.to_string())?;
            let frozen = state.frozen_on(CoinChain::Bitcoin);
            // BDK lists a mempool output the moment a sync sees it, with no
            // depth on the UTXO itself; the transaction that created it
            // carries the block it landed in, if any. One pass over the
            // history gives every coin its real confirmation count, so an
            // incoming payment shows up as pending instead of as a coin
            // that was always there.
            let tip = btc.get_tip_height();
            let depth_by_txid: std::collections::HashMap<String, u32> = btc
                .list_transactions()
                .map(|txs| {
                    txs.iter()
                        .map(|tx| {
                            let depth = tx
                                .confirmation_time
                                .as_ref()
                                .map(|ct| tip.saturating_sub(ct.height) + 1)
                                .unwrap_or(0);
                            (tx.txid.to_string(), depth)
                        })
                        .collect()
                })
                .unwrap_or_default();
            Ok(utxos
                .into_iter()
                .map(|u| {
                    let amount = u.txout.value;
                    let txid = u.outpoint.txid.to_string();
                    let outpoint = format!("{txid}:{}", u.outpoint.vout);
                    // A coin whose transaction the history does not know is
                    // treated as confirmed: the history is the same database
                    // the UTXO came from, so the only way to miss it is a
                    // wallet that has never synced, and pretending such coins
                    // are pending would freeze every coin in an offline
                    // wallet.
                    let confirmations = depth_by_txid.get(&txid).copied().unwrap_or(1);
                    let state_label = if frozen.contains(&outpoint) {
                        "frozen"
                    } else if confirmations == 0 {
                        "unconfirmed"
                    } else if amount <= DUST_THRESHOLD {
                        "dusty"
                    } else {
                        "available"
                    };
                    UtxoDto {
                        outpoint,
                        amount: amount as i64,
                        display_amount: format_btc(amount),
                        confirmations,
                        state: state_label.to_string(),
                        label: None,
                        address: None,
                        ticker: Some("BTC".to_string()),
                        asset_id: None,
                    }
                })
                .collect())
        }
    }
}

pub fn get_wallet_info(state: &AppFfiState, wallet_id: &str) -> Result<WalletInfoDto, String> {
    let entry = state.registry.find(wallet_id).ok_or("Wallet not found")?;

    let (fingerprint, path, script_type, xpub, recv_desc, chg_desc, multi_desc, cosigners) =
        match &entry.profile {
            templar_core::WalletProfile::Software { mnemonic } => {
                if let Some(info) = state.bitcoin.as_ref().and_then(|b| b.pub_info.as_ref()) {
                    (
                        info.fingerprint.clone(),
                        info.derivation_path.clone(),
                        "P2WPKH (Native SegWit)".to_string(),
                        info.xpub.clone(),
                        info.receive_descriptor.clone(),
                        String::new(),
                        None,
                        vec![],
                    )
                } else {
                    // BDK manager not open (e.g. sled DB locked by another
                    // instance) — fingerprint, xpub, and descriptor are pure
                    // BIP32 derivations from the registry mnemonic, so show
                    // them anyway instead of blank fields. Parse through
                    // pub_info_from_descriptor so the payload has the same
                    // shape as the BDK-derived pub_info.
                    let derived =
                        templar_core::account_xpub_bip84(mnemonic)
                            .ok()
                            .and_then(|(fp, xpub)| {
                                WalletManager::pub_info_from_descriptor(
                                    &format!("wpkh([{}/84'/1'/0']{}/0/*)", fp, xpub),
                                    &[],
                                )
                            });
                    match derived {
                        Some(info) => (
                            info.fingerprint,
                            info.derivation_path,
                            "P2WPKH (Native SegWit)".to_string(),
                            info.xpub,
                            info.receive_descriptor,
                            String::new(),
                            None,
                            vec![],
                        ),
                        None => placeholder_info(),
                    }
                }
            }
            templar_core::WalletProfile::Multisig {
                receive_descriptor,
                change_descriptor,
                required_sigs,
                total_signers,
                local_fingerprint,
                cosigner_xpubs,
                ..
            } => (
                local_fingerprint.clone().unwrap_or_default(),
                // The Bitcoin account these keys come from. BIP48 script-type
                // 2 is P2WSH multisig; m/87'/1'/0' is the *Liquid* account and
                // belongs to the CT descriptor below, not here.
                "m/48'/1'/0'/2'".to_string(),
                format!("P2WSH {}-of-{} Multisig", required_sigs, total_signers),
                String::new(),
                receive_descriptor.clone(),
                change_descriptor.clone(),
                None,
                cosigner_xpubs.clone(),
            ),
            templar_core::WalletProfile::HardwareWallet {
                device_fingerprint,
                receive_descriptor,
                change_descriptor,
                ..
            } => (
                device_fingerprint.clone(),
                "m/84'/1'/0'".to_string(),
                "P2WPKH (Native SegWit)".to_string(),
                String::new(),
                receive_descriptor.clone(),
                change_descriptor.clone(),
                None,
                vec![],
            ),
            templar_core::WalletProfile::Policy {
                receive_descriptor,
                change_descriptor,
                local_fingerprint,
                ..
            } => (
                local_fingerprint.clone().unwrap_or_default(),
                "custom".to_string(),
                "P2WSH Miniscript".to_string(),
                String::new(),
                receive_descriptor.clone(),
                change_descriptor.clone(),
                None,
                vec![],
            ),
        };

    // Read off the profile rather than threaded through the tuple above: only
    // one arm has them, and every other arm would carry two placeholders.
    let (required_sigs, local_fingerprints) = match &entry.profile {
        templar_core::WalletProfile::Multisig {
            required_sigs,
            local_fingerprints,
            ..
        } => (Some(*required_sigs as u32), local_fingerprints.clone()),
        _ => (None, Vec::new()),
    };

    let liquid_desc = entry.liquid.as_ref().map(|l| l.descriptor.clone());

    // Never expose a signing descriptor. Multisig/Policy profiles persist the
    // descriptor with the local xprv/tprv embedded (so the wallet can sign);
    // strip any private key back to its xpub/tpub before it crosses the FFI,
    // since these fields are copied/exported/QR'd as watch-only in the UI (N1).
    let recv_desc = public_descriptor(&recv_desc);
    let chg_desc = public_descriptor(&chg_desc);
    let multi_desc = multi_desc.map(|d| public_descriptor(&d));

    Ok(WalletInfoDto {
        id: entry.id.clone(),
        name: entry.name.clone(),
        network: "Testnet".to_string(),
        master_fingerprint: fingerprint,
        derivation_path: path,
        script_type,
        xpub,
        receive_descriptor: recv_desc,
        change_descriptor: chg_desc,
        multipath_descriptor: multi_desc,
        liquid_descriptor: liquid_desc,
        master_blinding_key: None,
        has_seed: entry.profile.is_software(),
        has_passphrase: false,
        last_backup_at: None,
        cosigner_keys: cosigners,
        required_sigs,
        local_fingerprints,
        liquid_network: state.liquid_network.name().to_string(),
    })
}

// ── helpers ──────────────────────────────────────────────────────────────────

fn format_btc(sats: u64) -> String {
    format!("{:.8} BTC", sats as f64 / 1e8)
}

/// Signed, precision-aware display for one Liquid per-asset delta.
/// Returns `(ticker, amount)`, e.g. `("L-BTC", "+0.00100000 L-BTC")` or
/// `("USDT", "-12.50 USDT")` — ticker and precision resolved via the asset
/// registry (local issued-asset metadata first).
fn liquid_delta_display(state: &AppFfiState, asset_id: &str, delta: i64) -> (String, String) {
    let sign = if delta >= 0 { "+" } else { "-" };
    let magnitude = delta.unsigned_abs();
    if state.is_policy_asset(asset_id) {
        (
            "L-BTC".to_string(),
            format!("{sign}{:.8} L-BTC", magnitude as f64 / 1e8),
        )
    } else {
        let ticker = state.asset_registry.ticker(asset_id).to_string();
        let value = state
            .asset_registry
            .format_amount_with_fallback(asset_id, magnitude);
        let amount = format!("{sign}{value} {ticker}");
        (ticker, amount)
    }
}

/// One display row per nonzero asset delta of a Liquid transaction:
/// `(asset_id, delta)`, L-BTC (`policy_asset`) first, then other assets in a
/// deterministic order. A tx whose deltas are all zero still yields one
/// L-BTC row so it never disappears from history.
fn liquid_delta_rows(
    balance: &std::collections::HashMap<String, i64>,
    policy_asset: &str,
) -> Vec<(String, i64)> {
    let mut rows: Vec<(String, i64)> = balance
        .iter()
        .filter(|(_, delta)| **delta != 0)
        .map(|(asset, delta)| (asset.clone(), *delta))
        .collect();
    rows.sort_by(|a, b| {
        (b.0 == policy_asset)
            .cmp(&(a.0 == policy_asset))
            .then_with(|| a.0.cmp(&b.0))
    });
    if rows.is_empty() {
        rows.push((policy_asset.to_string(), 0));
    }
    rows
}

/// Recipient list for a Bitcoin send: `(address, amount_sats, send_max)`
/// triples. A MAX recipient drains the remainder, so its amount is ignored.
pub type BtcOutputs = Vec<(String, u64, bool)>;

fn io_to_dto(io: templar_core::TxPreviewIo) -> TxIoDto {
    TxIoDto {
        outpoint: io.outpoint,
        address: io.address,
        amount_sats: io.amount_sats as i64,
        is_change: io.is_change,
        asset_id: None,
        ticker: None,
        amount_display: None,
    }
}

pub fn preview_send(
    state: &AppFfiState,
    outputs: &BtcOutputs,
    fee_rate: f32,
    utxos: Option<Vec<String>>,
) -> Result<TxPreviewDto, String> {
    let btc = state.bitcoin.as_ref().ok_or("Bitcoin wallet not open")?;
    let psbt = btc
        .create_tx_multi(
            outputs,
            fee_rate,
            None,
            utxos,
            &state.frozen_on(CoinChain::Bitcoin),
        )
        .map_err(|e| e.to_string())?;

    // Compute fee: sum of segwit witness_utxo values minus all outputs.
    let in_sum: u64 = psbt
        .inputs
        .iter()
        .filter_map(|i| i.witness_utxo.as_ref().map(|u| u.value))
        .sum();
    let out_sum: u64 = psbt.unsigned_tx.output.iter().map(|o| o.value).sum();
    let fee_sats = in_sum.saturating_sub(out_sum);
    // BDK targeted `fee_rate` on the estimated signed weight, so fee/rate
    // recovers that vsize estimate without hand-rolling witness sizes.
    let vsize_est = if fee_rate > 0.0 {
        (fee_sats as f64 / fee_rate as f64).round() as i64
    } else {
        0
    };

    let requested: Vec<String> = outputs.iter().map(|(a, _, _)| a.clone()).collect();
    let (inputs, outs) = btc.preview_psbt_io(&psbt, &requested);
    // Total leaving the wallet, from the built PSBT — a MAX recipient has no
    // meaningful amount in `outputs`, its concrete value only exists here.
    let send_total: u64 = outs
        .iter()
        .filter(|o| !o.is_change)
        .map(|o| o.amount_sats)
        .sum();
    let total = send_total + fee_sats;

    Ok(TxPreviewDto {
        chain: "bitcoin".to_string(),
        recipient_address: outputs
            .first()
            .map(|(a, _, _)| a.clone())
            .unwrap_or_default(),
        amount_display: format_btc(send_total),
        fee_sats: fee_sats as i64,
        fee_display: format!("{} sats ({:.1} sat/vB)", fee_sats, fee_rate),
        total_display: format_btc(total),
        fee_rate: fee_rate as f64,
        vsize_est,
        inputs: inputs.into_iter().map(io_to_dto).collect(),
        outputs: outs.into_iter().map(io_to_dto).collect(),
    })
}

/// Build, sign, and broadcast. Returns the txid as a JSON string on success.
///
/// When the wallet's local key(s) cannot satisfy the spending policy (multisig
/// needing external cosigners), broadcasting must not happen: extract_tx() on
/// an unfinalized PSBT yields a witness-less transaction that Electrum rejects
/// raw. Instead the partially-signed PSBT comes back as a JSON object
/// `{"partial_psbt", "sigs_have", "sigs_needed"}` for the UI to export.
pub fn send_bitcoin(
    state: &AppFfiState,
    outputs: &BtcOutputs,
    fee_rate: f32,
    utxos: Option<Vec<String>>,
) -> Result<serde_json::Value, String> {
    let btc = state.bitcoin.as_ref().ok_or("Bitcoin wallet not open")?;
    let mut psbt = btc
        .create_tx_multi(
            outputs,
            fee_rate,
            None,
            utxos,
            &state.frozen_on(CoinChain::Bitcoin),
        )
        .map_err(|e| e.to_string())?;
    let finalized = btc.sign(&mut psbt).map_err(|e| e.to_string())?;
    if !finalized {
        let psbt_b64 = WalletManager::psbt_to_base64(&psbt);
        let info = inspect_psbt(&psbt_b64, Some(btc)).map_err(|e| e.to_string())?;
        return Ok(serde_json::json!({
            "partial_psbt": psbt_b64,
            "sigs_have": info.sigs_present,
            "sigs_needed": info.sigs_required,
        }));
    }
    let tx = psbt.extract_tx();
    let txid = btc.broadcast(tx).map_err(|e| e.to_string())?;
    Ok(serde_json::Value::String(txid.to_string()))
}

/// Build the **unsigned** consolidation PSBT (base64): spends exactly the given
/// UTXOs into one fresh address of this wallet.
///
/// Signing and broadcasting are separate calls (`sign_psbt`,
/// `broadcast_signed_psbt`), so the UI can show what will be signed — and the
/// QR of it — before any key is touched, then show the signed transaction
/// before it reaches the network. [`consolidate_utxos`] remains the one-shot
/// form.
pub fn build_consolidation_psbt(
    state: &AppFfiState,
    outpoints: &[String],
    chain: &str,
    fee_rate: f32,
) -> Result<String, String> {
    if chain.eq_ignore_ascii_case("liquid") {
        return Err("Liquid consolidation is not supported yet".into());
    }
    let btc = state.bitcoin.as_ref().ok_or("Bitcoin wallet not open")?;
    let dest = btc.get_new_address().map_err(|e| e.to_string())?;
    let psbt = btc
        .create_consolidation_tx(
            &dest.address.to_string(),
            fee_rate,
            outpoints,
            &state.frozen_on(CoinChain::Bitcoin),
        )
        .map_err(|e| e.to_string())?;
    Ok(WalletManager::psbt_to_base64(&psbt))
}

/// Consolidate the given Bitcoin UTXOs into a single output sent back to a fresh
/// address of this wallet. Drains the selected UTXOs (minus fee), signs with the
/// software key, and broadcasts. Returns the txid.
pub fn consolidate_utxos(
    state: &AppFfiState,
    outpoints: &[String],
    chain: &str,
    fee_rate: f32,
) -> Result<String, String> {
    if chain.eq_ignore_ascii_case("liquid") {
        return Err("Liquid consolidation is not supported yet".into());
    }

    let btc = state.bitcoin.as_ref().ok_or("Bitcoin wallet not open")?;

    let dest = btc.get_new_address().map_err(|e| e.to_string())?;
    let mut psbt = btc
        .create_consolidation_tx(
            &dest.address.to_string(),
            fee_rate,
            outpoints,
            &state.frozen_on(CoinChain::Bitcoin),
        )
        .map_err(|e| e.to_string())?;
    let finalized = btc.sign(&mut psbt).map_err(|e| e.to_string())?;
    if !finalized {
        // Same hazard as send_bitcoin: an under-signed PSBT extracts to a
        // witness-less tx. Consolidation has no cosigner hand-off UI, so fail.
        return Err(
            "This wallet needs signatures from other cosigners — consolidation is only \
             available for wallets that can sign fully on this device"
                .into(),
        );
    }
    let tx = psbt.extract_tx();
    let txid = btc.broadcast(tx).map_err(|e| e.to_string())?;
    Ok(txid.to_string())
}

/// Build a transaction and sign it on the wallet's USB device. Returns the
/// **signed PSBT** (base64) — broadcasting is a separate call.
///
/// Splitting sign from broadcast is what makes a failed broadcast retryable:
/// the signed PSBT reaches the caller, so a network hiccup no longer costs the
/// user another round of on-device approval (and no longer risks a second
/// signature over the same coins).
#[cfg(feature = "hardware")]
pub fn sign_transaction_hw(
    state: &AppFfiState,
    wallet_id: &str,
    outputs: &BtcOutputs,
    fee_rate: f32,
    utxos: Option<Vec<String>>,
) -> Result<String, String> {
    let entry = state.registry.find(wallet_id).ok_or("Wallet not found")?;
    let fingerprint = match &entry.profile {
        WalletProfile::HardwareWallet {
            device_fingerprint, ..
        } if device_fingerprint != "airgap" => device_fingerprint.clone(),
        WalletProfile::HardwareWallet { .. } => {
            return Err("This is an air-gap wallet — sign it by QR, not USB".into())
        }
        _ => return Err("Not a hardware wallet".into()),
    };

    let btc = state.bitcoin.as_ref().ok_or("Bitcoin wallet not open")?;
    let psbt = btc
        .create_tx_multi(
            outputs,
            fee_rate,
            None,
            utxos,
            &state.frozen_on(CoinChain::Bitcoin),
        )
        .map_err(|e| e.to_string())?;

    let psbt_b64 = WalletManager::psbt_to_base64(&psbt);
    WalletManager::sign_psbt_with_hw(&fingerprint, &psbt_b64).map_err(|e| e.to_string())
}

/// Build, sign via hardware wallet (HWI subprocess), and broadcast. Returns txid.
///
/// Kept for callers that want the one-shot behaviour; the send flow uses
/// [`sign_transaction_hw`] + [`broadcast_signed_psbt`] so a broadcast failure
/// keeps the signed PSBT.
#[cfg(feature = "hardware")]
pub fn send_bitcoin_hw(
    state: &AppFfiState,
    wallet_id: &str,
    outputs: &BtcOutputs,
    fee_rate: f32,
    utxos: Option<Vec<String>>,
) -> Result<String, String> {
    let signed_b64 = sign_transaction_hw(state, wallet_id, outputs, fee_rate, utxos)?;
    broadcast_signed_psbt(state, &signed_b64)
}

/// Build an unsigned PSBT for an air-gap wallet. Returns base64 PSBT for export.
pub fn build_unsigned_psbt(
    state: &AppFfiState,
    outputs: &BtcOutputs,
    fee_rate: f32,
    utxos: Option<Vec<String>>,
) -> Result<String, String> {
    let btc = state.bitcoin.as_ref().ok_or("Bitcoin wallet not open")?;
    let psbt = btc
        .create_tx_multi(
            outputs,
            fee_rate,
            None,
            utxos,
            &state.frozen_on(CoinChain::Bitcoin),
        )
        .map_err(|e| e.to_string())?;
    Ok(WalletManager::psbt_to_base64(&psbt))
}

/// Broadcast a signed PSBT (for air-gap: user signed externally). Returns txid.
pub fn broadcast_signed_psbt(state: &AppFfiState, signed_psbt_b64: &str) -> Result<String, String> {
    let btc = state.bitcoin.as_ref().ok_or("Bitcoin wallet not open")?;
    let mut psbt = WalletManager::psbt_from_base64(signed_psbt_b64).map_err(|e| e.to_string())?;
    let tx = btc
        .finalize_external(&mut psbt)
        .map_err(|e| e.to_string())?;
    let txid = btc.broadcast(tx).map_err(|e| e.to_string())?;
    Ok(txid.to_string())
}

/// Display the next receive address on the connected hardware wallet screen.
/// Returns the address string after the device confirms it.
#[cfg(feature = "hardware")]
pub fn get_hw_address(state: &AppFfiState, wallet_id: &str) -> Result<String, String> {
    let entry = state.registry.find(wallet_id).ok_or("Wallet not found")?;
    let fingerprint = match &entry.profile {
        WalletProfile::HardwareWallet {
            device_fingerprint, ..
        } if device_fingerprint != "airgap" => device_fingerprint.clone(),
        _ => return Err("Not a USB hardware wallet".into()),
    };

    let btc = state.bitcoin.as_ref().ok_or("Bitcoin wallet not open")?;

    // Get the current address index from BDK without incrementing.
    let addr_info = btc.get_new_address().map_err(|e| e.to_string())?;
    let index = addr_info.index;

    let devices = WalletManager::enumerate_hw_devices().map_err(|e| e.to_string())?;
    let device = devices
        .iter()
        .find(|d| d.fingerprint == fingerprint)
        .ok_or("Hardware wallet not connected — plug in and unlock your device")?;

    btc.verify_address_on_device(device, index)
        .map_err(|e| e.to_string())
}

fn btc_zero() -> AssetBalanceDto {
    AssetBalanceDto {
        asset_id: "BTC".to_string(),
        ticker: "BTC".to_string(),
        name: "Bitcoin".to_string(),
        amount: 0,
        display_amount: "0.00000000 BTC".to_string(),
        fiat_estimate: None,
        status: "not synced".to_string(),
        utxo_count: 0,
        is_native: true,
    }
}

fn placeholder_info() -> (
    String,
    String,
    String,
    String,
    String,
    String,
    Option<String>,
    Vec<String>,
) {
    (
        String::new(),
        "m/84'/1'/0'".to_string(),
        "P2WPKH".to_string(),
        String::new(),
        String::new(),
        String::new(),
        None,
        vec![],
    )
}

/// Lists external BTC addresses that have received funds (received_sats > 0).
pub fn list_previous_addresses(
    state: &AppFfiState,
    asset: &str,
) -> Result<Vec<AddressInfoDto>, String> {
    match asset {
        "LBTC" | "L-BTC" | "liquid" => {
            // LWK exposes every wallet output (spent included) via txos();
            // templar-core aggregates them into per-address history. Only L-BTC
            // counts toward received_sats — token-only addresses report 0.
            let liq = state.liquid.as_ref().ok_or("Liquid wallet not open")?;
            let addrs = liq
                .list_received_external_addresses()
                .map_err(|e| e.to_string())?;
            Ok(addrs
                .into_iter()
                .map(|(address, index, received)| AddressInfoDto {
                    address,
                    index,
                    asset: asset.to_string(),
                    label: None,
                    received_sats: received as i64,
                    derivation_path: None,
                })
                .collect())
        }
        _ => {
            let btc = state.bitcoin.as_ref().ok_or("Bitcoin wallet not open")?;
            let addrs = btc
                .list_received_external_addresses()
                .map_err(|e| e.to_string())?;
            Ok(addrs
                .into_iter()
                .map(|(address, index, received)| AddressInfoDto {
                    address,
                    index,
                    asset: "BTC".to_string(),
                    label: None,
                    received_sats: received as i64,
                    derivation_path: Some(format!("m/84'/1'/0'/0/{index}")),
                })
                .collect())
        }
    }
}

/// Merge signed copies of one transaction into a single PSBT.
///
/// Wallet-independent: combining is a property of the PSBTs themselves
/// (`Psbt::combine` keeps every partial signature and refuses two different
/// transactions), so a coordinator can fold in a co-signer's copy whether the
/// co-signers signed in turn or in parallel from the same original. The
/// first entry is the copy being handed out; the rest are what came back.
pub fn combine_psbts_handler(psbts_base64: &[String]) -> Result<String, String> {
    if psbts_base64.len() < 2 {
        return Err("Combining needs at least two copies of the transaction".to_string());
    }
    let mut merged =
        WalletManager::psbt_from_base64(&psbts_base64[0]).map_err(|e| e.to_string())?;
    for (n, other) in psbts_base64.iter().enumerate().skip(1) {
        let partial = WalletManager::psbt_from_base64(other).map_err(|e| e.to_string())?;
        merged.combine(partial).map_err(|e| {
            format!(
                "Copy {} is not a signed copy of this transaction: {e}",
                n + 1
            )
        })?;
    }
    Ok(WalletManager::psbt_to_base64(&merged))
}

/// Parse a PSBT and return inputs, outputs, fee, and signer status.
///
/// The open Bitcoin wallet, when there is one, lets the inspection say which
/// inputs and outputs are the wallet's own — the difference between "a
/// transaction" and "your coin, leaving".
pub fn inspect_psbt_handler(
    state: &AppFfiState,
    psbt_base64: &str,
) -> Result<PsbtInspectionDto, String> {
    let result = inspect_psbt(psbt_base64, state.bitcoin.as_ref()).map_err(|e| e.to_string())?;

    let inputs = result
        .inputs
        .into_iter()
        .map(|i| PsbtInputDto {
            outpoint: i.outpoint,
            amount_sats: i.amount_sats.map(|a| a as i64),
            display_amount: i
                .amount_sats
                .map(format_btc)
                .unwrap_or_else(|| "unknown".to_string()),
            utxo_status: i.utxo_status.as_str().to_string(),
            is_mine: i.is_mine,
        })
        .collect();

    let outputs = result
        .outputs
        .into_iter()
        .map(|o| PsbtOutputDto {
            address: o.address,
            amount_sats: o.amount_sats as i64,
            display_amount: o.display_amount,
            is_mine: o.is_mine,
        })
        .collect();

    let signers = result
        .signers
        .into_iter()
        .map(|s| PsbtSignerDto {
            fingerprint: s.fingerprint,
            has_signed: s.has_signed,
        })
        .collect();

    Ok(PsbtInspectionDto {
        inputs,
        outputs,
        fee_sats: result.fee_sats.map(|f| f as i64),
        fee_display: result.fee_display,
        sigs_present: result.sigs_present,
        sigs_required: result.sigs_required,
        signers,
        policy_hint: result.policy_hint,
        raw_psbt: result.raw_psbt,
        finalized: result.finalized,
        utxo_check: result.utxo_check.as_str().to_string(),
        ownership_known: result.ownership_known,
    })
}

/// Sign a PSBT with the wallet's local key(s). Returns signed PSBT as base64.
///
/// Software wallets sign with their mnemonic; Multisig wallets sign with the
/// xprv(s) embedded in their descriptor. Pure watch-only wallets (no local
/// key) are refused.
pub fn sign_psbt_handler(
    state: &AppFfiState,
    wallet_id: &str,
    psbt_base64: &str,
) -> Result<String, String> {
    let entry = state.registry.find(wallet_id).ok_or("Wallet not found")?;
    let mut psbt = WalletManager::psbt_from_base64(psbt_base64).map_err(|e| e.to_string())?;
    // A PSBT built elsewhere may reach for a coin the user froze here.
    refuse_frozen_inputs(&psbt, entry.frozen.on(CoinChain::Bitcoin)).map_err(|e| e.to_string())?;
    // What the review screen showed must be what the signature commits to.
    check_input_utxos(&psbt).map_err(|e| e.to_string())?;
    match &entry.profile {
        WalletProfile::Software { mnemonic } => {
            let before: usize = psbt.inputs.iter().map(|i| i.partial_sigs.len()).sum();
            // Sign the wallet's own inputs with its BDK signer. This is the
            // singlesig P2WPKH path — a normal send or a consolidation — which
            // sign_psbt_as_cosigner alone cannot handle (it needs a
            // witness_script, present only on P2WSH inputs). Reuse the open
            // manager when this is the active wallet; its sled DB is
            // exclusively locked and must not be opened twice.
            match (&state.active_wallet_id, &state.bitcoin) {
                (Some(active), Some(mgr)) if active == wallet_id => {
                    mgr.sign_no_finalize(&mut psbt).map_err(|e| e.to_string())?;
                }
                _ => {
                    let mgr =
                        WalletManager::new(&state.data_dir, mnemonic).map_err(|e| e.to_string())?;
                    mgr.sign_no_finalize(&mut psbt).map_err(|e| e.to_string())?;
                }
            }
            // Then add this key's signatures to any *foreign* wsh inputs it
            // cosigns (a multisig PSBT pasted in for co-signing). The wallet's
            // own P2WPKH inputs are already signed above; the cosigner pass
            // skips inputs without a witness_script.
            WalletManager::sign_psbt_as_cosigner(mnemonic, &mut psbt).map_err(|e| e.to_string())?;
            // Counted before either pass ran: a PSBT that already carried
            // other parties' signatures must not read as "signed" when this
            // key added nothing.
            let after: usize = psbt.inputs.iter().map(|i| i.partial_sigs.len()).sum();
            if after <= before {
                return Err(
                    "This wallet's key signs none of the inputs in this transaction — it may \
                     belong to a different wallet, already signed this copy, or this PSBT \
                     needs another cosigner."
                        .into(),
                );
            }
        }
        WalletProfile::Multisig {
            local_fingerprint,
            local_fingerprints,
            ..
        } => {
            if local_fingerprints.is_empty() && local_fingerprint.is_none() {
                return Err(
                    "This multisig wallet holds no local keys — it can only coordinate. \
                     Sign with a wallet or device that holds one of the cosigner keys"
                        .into(),
                );
            }
            let (sigs_before, _) = WalletManager::count_signatures(&psbt);
            // Reuse the already-open manager when this is the active wallet
            // (its sled DB is exclusively locked); otherwise open on the side.
            match (&state.active_wallet_id, &state.bitcoin) {
                (Some(active), Some(mgr)) if active == wallet_id => {
                    mgr.sign_no_finalize(&mut psbt).map_err(|e| e.to_string())?;
                }
                _ => {
                    let mgr = WalletManager::from_multisig_profile(
                        &state.data_dir,
                        &entry.profile,
                        wallet_id,
                    )
                    .map_err(|e| e.to_string())?;
                    mgr.sign_no_finalize(&mut psbt).map_err(|e| e.to_string())?;
                }
            }
            let (sigs_after, _) = WalletManager::count_signatures(&psbt);
            if sigs_after <= sigs_before {
                return Err(
                    "No signature was added — this wallet's key(s) either already signed this \
                     PSBT or are not part of its spending policy"
                        .into(),
                );
            }
        }
        _ => {
            return Err(
                "This wallet type cannot co-sign PSBTs here — only software and multisig \
                 wallets with a local key can"
                    .into(),
            )
        }
    }
    Ok(WalletManager::psbt_to_base64(&psbt))
}
