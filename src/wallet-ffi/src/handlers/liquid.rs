//! Liquid-specific operations — send, issue, reissue, burn, registry.

use std::collections::BTreeSet;

use templar_core::liquid::assets::AssetMetadata;
use templar_core::liquid::wallet::refuse_frozen_inputs;
use templar_core::registry::{LiquidWalletConfig, WalletProfile};
use templar_core::{CoinChain, LiquidMultisigSetup, LiquidWalletManager};

use templar_core::{LiquidBackend, LiquidNetwork, REGTEST_DEFAULT_POLICY_ASSET};

use crate::state::AppFfiState;
use crate::types::{
    IssueResultDto, LiquidNetworkDto, PsetInputDto, PsetInspectionDto, PsetOutputDto,
    PsetRecipientDto, TxIoDto, TxOutputSpec, TxPreviewDto,
};

/// The wallet's Templar Protocol escrow account key, `[fingerprint/2121h/1h/0h]tpub…`
/// — what the `templar://connect` callback sends as `escrow_xpub`.
///
/// Software wallets only: the key is a hardened account below the seed, and
/// a device (Jade) would have to derive and export it itself. Multisig and
/// policy wallets have no single seed to derive it from.
pub fn protocol_escrow_xpub(state: &AppFfiState, wallet_id: &str) -> Result<String, String> {
    let entry = state.registry.find(wallet_id).ok_or("Wallet not found")?;
    match &entry.profile {
        WalletProfile::Software { mnemonic } => {
            templar_core::escrow_xpub_from_mnemonic(mnemonic).map_err(|e| e.to_string())
        }
        WalletProfile::HardwareWallet { .. } => Err(
            "This wallet's keys live on a device. Templar Protocol escrow keys from a Jade are \
             not supported yet — connect a software wallet."
                .into(),
        ),
        WalletProfile::Multisig { .. } | WalletProfile::Policy { .. } => Err(
            "Templar Protocol escrow keys come from a single-seed software wallet; this wallet \
             has no single seed to derive one from."
                .into(),
        ),
    }
}

/// The active Liquid network and chain backend, for the settings screen and
/// for anything that must refuse to act across networks.
pub fn network_info(state: &AppFfiState) -> LiquidNetworkDto {
    let network = &state.liquid_network;
    // A bad `TEMPLAR_LIQUID_BACKEND` value is reported by sync; here it only
    // needs a description, so fall back to the network's natural backend.
    let backend =
        LiquidBackend::from_env(network).unwrap_or_else(|_| LiquidBackend::default_for(network));
    LiquidNetworkDto {
        network: network.name().to_string(),
        short_name: network.short_name().to_string(),
        policy_asset: network.policy_asset_hex(),
        backend: backend.kind().to_string(),
        backend_description: backend.describe(),
        env_locked: state.liquid_network_env_locked,
        regtest_default_policy_asset: REGTEST_DEFAULT_POLICY_ASSET.to_string(),
    }
}

/// Switches the Liquid network. Closes the open wallet: the UI reopens it
/// (on the new network) and syncs.
pub fn set_network(
    state: &mut AppFfiState,
    network: &str,
    policy_asset: Option<&str>,
) -> Result<(), String> {
    let network = LiquidNetwork::parse(network, policy_asset).map_err(|e| e.to_string())?;
    state.set_liquid_network(network)
}

/// A Liquid send after MAX resolution: fixed recipients plus an optional
/// L-BTC drain destination (the "send MAX L-BTC" output).
struct ResolvedLiquidSend {
    recipients: Vec<(String, u64, String)>,
    drain_lbtc_to: Option<String>,
}

/// Turn the wire outputs into concrete `(address, amount, asset)` triples.
///
/// Per-output `asset_id` falls back to the transaction-level asset. MAX
/// outputs resolve here: tokens get their full balance (fees are paid in
/// L-BTC, so the whole token balance is spendable); L-BTC MAX becomes the
/// builder's drain destination so LWK computes `balance − fee` exactly.
fn resolve_liquid_outputs(
    liq: &LiquidWalletManager,
    outputs: &[TxOutputSpec],
    default_asset: &str,
) -> Result<ResolvedLiquidSend, String> {
    let mut recipients = Vec::with_capacity(outputs.len());
    let mut drain_lbtc_to = None;

    let policy_asset = liq.policy_asset_hex();
    // Balance is only needed to resolve token MAX outputs.
    let needs_balance = outputs
        .iter()
        .any(|o| o.send_max && o.asset_id.as_deref().unwrap_or(default_asset) != policy_asset);
    let balance = if needs_balance {
        Some(liq.get_balance().map_err(|e| e.to_string())?)
    } else {
        None
    };

    for out in outputs {
        let asset = out
            .asset_id
            .clone()
            .unwrap_or_else(|| default_asset.to_string());
        if !out.send_max {
            recipients.push((out.address.clone(), out.amount_sats.max(0) as u64, asset));
            continue;
        }
        if asset == policy_asset {
            drain_lbtc_to = Some(out.address.clone());
            continue;
        }
        // Token MAX: full balance minus whatever the fixed outputs already
        // send of the same asset.
        let total = balance
            .as_ref()
            .and_then(|b| b.assets.get(&asset).copied())
            .unwrap_or(0);
        let already: u64 = outputs
            .iter()
            .filter(|o| !o.send_max && o.asset_id.as_deref().unwrap_or(default_asset) == asset)
            .map(|o| o.amount_sats.max(0) as u64)
            .sum();
        let max = total.saturating_sub(already);
        if max == 0 {
            return Err("MAX resolves to zero — no spendable balance for this asset".into());
        }
        recipients.push((out.address.clone(), max, asset));
    }

    Ok(ResolvedLiquidSend {
        recipients,
        drain_lbtc_to,
    })
}

/// Ticker and precision-aware display amount for one previewed output.
fn asset_display(state: &AppFfiState, asset_id: &str, amount: u64) -> (String, String) {
    if state.is_policy_asset(asset_id) {
        (
            "L-BTC".to_string(),
            format!("{:.8} L-BTC", amount as f64 / 1e8),
        )
    } else {
        (
            state.asset_registry.ticker(asset_id).to_string(),
            state
                .asset_registry
                .format_amount_with_fallback(asset_id, amount),
        )
    }
}

/// Preview a Liquid send without broadcasting.
/// Uses LWK PSET builder + get_details for exact fee.
pub fn preview_send(
    state: &AppFfiState,
    outputs: &[TxOutputSpec],
    default_asset: &str,
) -> Result<TxPreviewDto, String> {
    let frozen = state.frozen_on(CoinChain::Liquid);
    let liq = state.liquid.as_ref().ok_or("Liquid wallet not open")?;
    let resolved = resolve_liquid_outputs(liq, outputs, default_asset)?;
    let pset = liq
        .create_tx_multi(
            &resolved.recipients,
            resolved.drain_lbtc_to.as_deref(),
            &frozen,
        )
        .map_err(|e| e.to_string())?;
    let details = liq.inspect_pset(&pset).map_err(|e| e.to_string())?;
    let fee_sats = details.fee as i64;

    // Outputs for the review diagram — one row per external recipient, each
    // carrying its own asset. Liquid inputs stay auto-selected and blinded,
    // so only the recipient side is listed. MAX outputs (including the L-BTC
    // drain) show their concrete resolved amount here.
    let out_rows: Vec<TxIoDto> = details
        .recipients
        .iter()
        .map(|r| {
            let amount = r.amount.unwrap_or(0);
            let (ticker, display) = match r.asset.as_deref() {
                Some(aid) => {
                    let (t, d) = asset_display(state, aid, amount);
                    (Some(t), Some(d))
                }
                None => (None, None),
            };
            TxIoDto {
                outpoint: None,
                address: r.address.clone().unwrap_or_else(|| "(confidential)".into()),
                amount_sats: amount as i64,
                is_change: false,
                asset_id: r.asset.clone(),
                ticker,
                amount_display: display,
            }
        })
        .collect();

    let distinct_assets: BTreeSet<&str> = out_rows
        .iter()
        .filter_map(|o| o.asset_id.as_deref())
        .collect();
    let amount_display = if distinct_assets.len() == 1 {
        let aid = distinct_assets.iter().next().unwrap();
        let total: u64 = out_rows.iter().map(|o| o.amount_sats.max(0) as u64).sum();
        asset_display(state, aid, total).1
    } else {
        format!(
            "{} outputs · {} assets",
            out_rows.len(),
            distinct_assets.len()
        )
    };

    let lbtc_out: i64 = out_rows
        .iter()
        .filter(|o| o.asset_id.as_deref() == Some(liq.policy_asset_hex().as_str()))
        .map(|o| o.amount_sats)
        .sum();
    let total_display = if lbtc_out > 0 {
        format!("{} sats total", lbtc_out + fee_sats)
    } else {
        format!("{} sats fee", fee_sats)
    };

    Ok(TxPreviewDto {
        chain: "liquid".to_string(),
        recipient_address: outputs
            .first()
            .map(|o| o.address.clone())
            .unwrap_or_default(),
        amount_display,
        fee_sats,
        fee_display: format!("{} sats", fee_sats),
        total_display,
        fee_rate: 0.0,
        vsize_est: 0,
        inputs: Vec::new(),
        outputs: out_rows,
    })
}

/// Build, sign, and broadcast a Liquid send.
///
/// Returns the txid as a JSON string, except for a multisig that this app
/// cannot finish alone: that returns `{partial_pset, sigs_have, sigs_needed,
/// chain}` for the co-signing flow, mirroring what `send_bitcoin` does with a
/// PSBT.
pub fn send_liquid(
    state: &mut AppFfiState,
    wallet_id: &str,
    outputs: &[TxOutputSpec],
    default_asset: &str,
) -> Result<serde_json::Value, String> {
    // Decide who signs before building anything: a hardware wallet has no
    // software key, and discovering that after the PSET is built would waste
    // the user's time and leave a half-finished transaction around.
    let signer = liquid_signer_for(state, wallet_id)?;
    #[cfg(feature = "hardware")]
    let network = state.liquid_network.clone();
    let frozen = state.frozen_on(CoinChain::Liquid);

    let liq = state.liquid.as_mut().ok_or("Liquid wallet not open")?;
    let resolved = resolve_liquid_outputs(liq, outputs, default_asset)?;
    let mut pset = liq
        .create_tx_multi(
            &resolved.recipients,
            resolved.drain_lbtc_to.as_deref(),
            &frozen,
        )
        .map_err(|e| e.to_string())?;

    match signer {
        LiquidSigner::Software => {
            liq.sign(&mut pset).map_err(|e| e.to_string())?;
        }
        LiquidSigner::Jade => {
            // Connect at signing time, not at wallet open: the device is
            // typically plugged in only when the user is about to spend, and
            // holding the serial port open would block Green and every other
            // Jade-aware app for the whole session.
            #[cfg(feature = "hardware")]
            {
                let jade = templar_core::JadeLiquidSigner::connect_on(&network)
                    .map_err(|e| e.to_string())?;
                jade.sign_pset(&mut pset).map_err(|e| e.to_string())?;
            }
            #[cfg(not(feature = "hardware"))]
            return Err(crate::handlers::hw::HW_UNSUPPORTED.to_string());
        }
        LiquidSigner::Multisig {
            mnemonics,
            required_sigs,
        } => {
            LiquidMultisigSetup::sign_pset_with_mnemonics(&mut pset, &mnemonics)
                .map_err(|e| e.to_string())?;
            let have = signatures_on_weakest_input(liq, &pset)?;
            if (have as usize) < required_sigs {
                // Not a failure: the transaction is built and carries whatever
                // this app could add. Hand it back so the remaining keys —
                // another app instance, a Jade, a co-signer across the room —
                // can sign it. Broadcasting is a separate, explicit step.
                let b64 = LiquidWalletManager::pset_to_base64(&pset).map_err(|e| e.to_string())?;
                return Ok(serde_json::json!({
                    "partial_pset": b64,
                    "sigs_have": have,
                    "sigs_needed": required_sigs,
                    "chain": "liquid",
                }));
            }
        }
    };

    let txid = liq.broadcast(&mut pset).map_err(|e| e.to_string())?;
    Ok(serde_json::Value::String(txid))
}

/// Which key signs this wallet's Liquid transactions.
enum LiquidSigner {
    Software,
    Jade,
    /// M-of-N: sign with every seed held here, then let the rest of the
    /// co-signers finish the PSET.
    Multisig {
        mnemonics: Vec<String>,
        required_sigs: usize,
    },
}

/// Pick the signer from the wallet's profile, and refuse the combinations that
/// cannot work.
///
/// A Liquid wallet paired with a Bitcoin-only device is the dangerous case: it
/// can derive addresses and receive, so funds arrive, but no signature can
/// ever be produced for them. That pairing is blocked at creation, and blocked
/// again here in case an older registry entry carries one.
fn liquid_signer_for(state: &AppFfiState, wallet_id: &str) -> Result<LiquidSigner, String> {
    let entry = state.registry.find(wallet_id).ok_or("Wallet not found")?;
    match &entry.profile {
        WalletProfile::HardwareWallet { device_model, .. } => {
            if templar_core::is_jade_model(device_model) {
                Ok(LiquidSigner::Jade)
            } else {
                Err(format!(
                    "{}: {}",
                    templar_core::ERR_LIQUID_HW_UNSUPPORTED,
                    templar_core::liquid_hw_unsupported_reason()
                ))
            }
        }
        WalletProfile::Multisig {
            local_mnemonics,
            required_sigs,
            ..
        } => Ok(LiquidSigner::Multisig {
            mnemonics: local_mnemonics.clone(),
            required_sigs: *required_sigs,
        }),
        _ => Ok(LiquidSigner::Software),
    }
}

/// How many signatures the least-signed input carries — the number that has to
/// reach the threshold before a PSET can be finalized.
fn signatures_on_weakest_input(
    liq: &LiquidWalletManager,
    pset: &templar_core::Pset,
) -> Result<u32, String> {
    Ok(liq
        .inspect_pset(pset)
        .map_err(|e| e.to_string())?
        .sigs_present_min)
}

/// How many signatures this wallet needs before its PSETs can be finalized.
fn required_sigs_for(state: &AppFfiState, wallet_id: &str) -> usize {
    match state.registry.find(wallet_id).map(|e| &e.profile) {
        Some(WalletProfile::Multisig { required_sigs, .. }) => *required_sigs,
        _ => 1,
    }
}

/// Decode a PSET and describe it: fee, where the money goes, and how close it
/// is to being spendable. The pre-signature safety check for every multi-party
/// Liquid transaction — the co-signer sees the real recipients, not a blob.
///
/// Needs the wallet open: amounts and assets in a PSET are blinded, and only a
/// wallet holding the blinding key can read them.
pub fn inspect_pset(
    state: &AppFfiState,
    wallet_id: &str,
    pset_base64: &str,
) -> Result<PsetInspectionDto, String> {
    let liq = state.liquid.as_ref().ok_or("Liquid wallet not open")?;
    let pset = LiquidWalletManager::pset_from_base64(pset_base64).map_err(|e| e.to_string())?;
    let details = liq.inspect_pset(&pset).map_err(|e| e.to_string())?;
    // The quorum is the transaction's, not the inspecting wallet's: a
    // co-signer reading a 2-of-3 from their own single-key wallet used to be
    // told one signature was enough, and offered to finalize after theirs.
    // Read `k` off the multisig scripts this wallet is asked to sign; fall
    // back to the wallet's own threshold when the PSET does not say.
    let needed = details
        .inputs
        .iter()
        .filter(|i| i.is_ours)
        .filter_map(|i| i.threshold)
        .max()
        .map(|k| k as usize)
        .unwrap_or_else(|| required_sigs_for(state, wallet_id));

    let recipients = details
        .recipients
        .iter()
        .map(|r| {
            let (ticker, display_amount) = match (&r.asset, r.amount) {
                (Some(asset), Some(amount)) => {
                    let (t, d) = asset_display(state, asset, amount);
                    (Some(t), Some(d))
                }
                _ => (None, None),
            };
            PsetRecipientDto {
                address: r.address.clone(),
                asset_id: r.asset.clone(),
                ticker,
                amount_sats: r.amount.map(|v| v as i64),
                display_amount,
                unverified: r.unverified,
            }
        })
        .collect();

    let (_, fee_display) = asset_display(state, &liq.policy_asset_hex(), details.fee);

    let display = |asset: &Option<String>, amount: Option<u64>| match (asset, amount) {
        (Some(asset), Some(amount)) => {
            let (t, d) = asset_display(state, asset, amount);
            (Some(t), Some(d))
        }
        (Some(asset), None) => (Some(asset_display(state, asset, 0).0), None),
        _ => (None, None),
    };
    let inputs = details
        .inputs
        .iter()
        .map(|i| {
            let (ticker, display_amount) = display(&i.asset, i.amount);
            PsetInputDto {
                index: i.index,
                outpoint: i.outpoint.clone(),
                is_ours: i.is_ours,
                script_type: i.script_type.clone(),
                witness_script: i.witness_script.clone(),
                witness_script_asm: i.witness_script_asm.clone(),
                asset_id: i.asset.clone(),
                ticker,
                amount_sats: i.amount.map(|v| v as i64),
                display_amount,
                key_fingerprints: i.key_fingerprints.clone(),
                signed_by: i.signed_by.clone(),
                threshold: i.threshold,
                unverified: i.unverified,
            }
        })
        .collect();
    let outputs = details
        .outputs
        .iter()
        .map(|o| {
            let (ticker, display_amount) = display(&o.asset, o.amount);
            PsetOutputDto {
                index: o.index,
                kind: o.kind.clone(),
                script_type: o.script_type.clone(),
                address: o.address.clone(),
                asset_id: o.asset.clone(),
                ticker,
                amount_sats: o.amount.map(|v| v as i64),
                display_amount,
                unverified: o.unverified,
            }
        })
        .collect();

    let has_unverified_outputs = details.has_unverified_outputs();
    Ok(PsetInspectionDto {
        network: details.network.clone(),
        fee_sats: details.fee as i64,
        fee_display,
        recipients,
        inputs,
        outputs,
        sigs_have: details.sigs_present_min,
        sigs_needed: needed as u32,
        signers_present: details.signers_present.clone(),
        signers_missing: details.signers_missing.clone(),
        can_finalize: !has_unverified_outputs && details.sigs_present_min as usize >= needed,
        raw_pset: pset_base64.trim().to_string(),
        has_unverified_outputs,
        net_change: details.net_change.clone(),
    })
}

/// Add this wallet's software signature(s) to a PSET. Returns the PSET back as
/// base64.
///
/// Works for a multisig holding local seeds and for a plain software wallet
/// whose key is enrolled in someone else's multisig — signing matches on the
/// master fingerprint recorded in the PSET, so the signer does not need the
/// wallet the transaction was built from.
/// The checks every Liquid signing route runs before a key touches the PSET,
/// whoever the caller is: the PSET belongs to this wallet's network and
/// derivations ([`LiquidWalletManager::inspect_pset`]), and every output it
/// asks the key to pay says what it pays in a way the commitments prove.
fn ensure_pset_signable(state: &AppFfiState, pset_base64: &str) -> Result<(), String> {
    let liq = state
        .liquid
        .as_ref()
        .ok_or("Open this wallet's Liquid side before signing a Liquid transaction")?;
    let pset = LiquidWalletManager::pset_from_base64(pset_base64).map_err(|e| e.to_string())?;
    let details = liq.inspect_pset(&pset).map_err(|e| e.to_string())?;
    if details.has_unverified_outputs() {
        return Err(
            "Refusing to sign: an output of this transaction claims an amount or asset its \
             commitment does not prove, so what it really pays cannot be shown."
                .into(),
        );
    }
    Ok(())
}

pub fn sign_pset(
    state: &AppFfiState,
    wallet_id: &str,
    pset_base64: &str,
) -> Result<String, String> {
    let entry = state.registry.find(wallet_id).ok_or("Wallet not found")?;
    let mut pset = LiquidWalletManager::pset_from_base64(pset_base64).map_err(|e| e.to_string())?;
    ensure_pset_signable(state, pset_base64)?;
    // A PSET built elsewhere may reach for a coin the user froze here.
    refuse_frozen_inputs(&pset, entry.frozen.on(CoinChain::Liquid), true)
        .map_err(|e| e.to_string())?;

    let mnemonics: Vec<String> = match &entry.profile {
        WalletProfile::Software { mnemonic } => vec![mnemonic.clone()],
        WalletProfile::Multisig {
            local_mnemonics, ..
        } => {
            if local_mnemonics.is_empty() {
                return Err(
                    "This multisig wallet holds no local key for Liquid — it can \
                            only coordinate. Sign with a wallet or Jade that holds one of \
                            the cosigner keys."
                        .into(),
                );
            }
            local_mnemonics.clone()
        }
        WalletProfile::HardwareWallet { .. } => {
            return Err("This wallet's key lives on a device — use the device to sign.".into())
        }
        WalletProfile::Policy { .. } => {
            return Err("Liquid does not support Miniscript policy wallets here.".into())
        }
    };

    let added = LiquidMultisigSetup::sign_pset_with_mnemonics(&mut pset, &mnemonics)
        .map_err(|e| e.to_string())?;
    if added == 0 {
        return Err(
            "No signature was added — this wallet's key(s) either already signed \
                    this transaction or are not part of its spending policy."
                .into(),
        );
    }
    LiquidWalletManager::pset_to_base64(&pset).map_err(|e| e.to_string())
}

/// Sign a PSET with a connected Jade — the hardware half of the co-signing
/// flow.
///
/// A multisig has to be registered on the device before it will sign, so the
/// wallet's CT descriptor is sent first; the device shows the wallet once and
/// remembers it. Singlesig skips straight to signing.
#[cfg(feature = "hardware")]
pub fn sign_pset_hw(
    state: &AppFfiState,
    wallet_id: &str,
    pset_base64: &str,
) -> Result<String, String> {
    let entry = state.registry.find(wallet_id).ok_or("Wallet not found")?;
    let mut pset = LiquidWalletManager::pset_from_base64(pset_base64).map_err(|e| e.to_string())?;
    ensure_pset_signable(state, pset_base64)?;
    // A PSET built elsewhere may reach for a coin the user froze here.
    refuse_frozen_inputs(&pset, entry.frozen.on(CoinChain::Liquid), true)
        .map_err(|e| e.to_string())?;
    let jade = templar_core::JadeLiquidSigner::connect_on(&state.liquid_network)
        .map_err(|e| e.to_string())?;

    match (&entry.profile, entry.liquid_descriptor()) {
        (WalletProfile::Multisig { .. }, Some(desc)) => {
            let name = LiquidMultisigSetup::jade_multisig_name(&entry.name, desc);
            jade.sign_multisig_pset(&name, desc, &mut pset)
                .map_err(|e| e.to_string())?;
        }
        (WalletProfile::Multisig { .. }, None) => {
            return Err("This multisig wallet has no Liquid side.".into())
        }
        _ => {
            jade.sign_pset(&mut pset).map_err(|e| e.to_string())?;
        }
    }
    LiquidWalletManager::pset_to_base64(&pset).map_err(|e| e.to_string())
}

/// Merge signed copies of one PSET into a single transaction.
///
/// Co-signers who sign in parallel each return the same transaction carrying
/// their own signature; this is what puts them back together. Signing in a
/// chain (A → B → C) does not need it.
pub fn combine_psets(state: &AppFfiState, psets_base64: &[String]) -> Result<String, String> {
    if psets_base64.len() < 2 {
        return Err("Combining needs at least two signed copies of the transaction.".into());
    }
    let liq = state.liquid.as_ref().ok_or("Liquid wallet not open")?;
    let psets = psets_base64
        .iter()
        .map(|b| LiquidWalletManager::pset_from_base64(b).map_err(|e| e.to_string()))
        .collect::<Result<Vec<_>, String>>()?;
    let combined = liq.combine(&psets).map_err(|e| e.to_string())?;
    LiquidWalletManager::pset_to_base64(&combined).map_err(|e| e.to_string())
}

/// Finalize a fully-signed PSET and broadcast it. Returns the txid.
pub fn broadcast_pset(state: &AppFfiState, pset_base64: &str) -> Result<String, String> {
    let liq = state.liquid.as_ref().ok_or("Liquid wallet not open")?;
    let mut pset = LiquidWalletManager::pset_from_base64(pset_base64).map_err(|e| e.to_string())?;
    liq.broadcast(&mut pset).map_err(|e| e.to_string())
}

/// Issue a new Liquid asset and register it with the testnet registry.
pub fn issue_asset(
    state: &mut AppFfiState,
    name: &str,
    ticker: &str,
    precision: u8,
    domain: &str,
    amount_sats: u64,
    reissuance_tokens: u64,
) -> Result<IssueResultDto, String> {
    // Cheap guard; templar-core re-validates the full contract before signing.
    if precision > 8 {
        return Err("Precision must be between 0 and 8".to_string());
    }
    let frozen = state.frozen_on(CoinChain::Liquid);
    let liq = state.liquid.as_mut().ok_or("Liquid wallet not open")?;
    let result = liq
        .issue_asset(
            name,
            ticker,
            precision,
            domain,
            amount_sats,
            reissuance_tokens,
            &frozen,
        )
        .map_err(|e| e.to_string())?;

    // Persist the asset's metadata (and its reissuance token's) so ticker and
    // precision survive a restart — dashboard, history, and send formatting
    // all resolve through AssetRegistry.local_metadata, which open_wallet
    // reloads from the registry entry. The issuance already succeeded
    // on-chain, so persistence is best-effort and never fails the call.
    let mut metas = vec![AssetMetadata {
        asset_id: result.asset_id.clone(),
        name: name.to_string(),
        ticker: Some(ticker.to_string()),
        precision,
        domain: Some(domain.to_string()),
        is_reissuance_token: false,
        parent_asset_id: None,
    }];
    if let Some(token_id) = &result.token_id {
        metas.push(AssetMetadata {
            asset_id: token_id.clone(),
            name: format!("{name} Reissuance Token"),
            ticker: Some(format!("{ticker}-RT")),
            precision: 0,
            domain: Some(domain.to_string()),
            is_reissuance_token: true,
            parent_asset_id: Some(result.asset_id.clone()),
        });
    }
    persist_asset_metadata(state, &metas);

    let proof_url = format!(
        "https://{}/.well-known/liquid-asset-proof-{}",
        domain, result.asset_id
    );
    let proof_content = format!(
        "Authorize linking the domain name {} to the Liquid asset {}",
        domain, result.asset_id
    );

    Ok(IssueResultDto {
        asset_id: result.asset_id,
        token_id: result.token_id,
        txid: result.txid,
        registry_registered: result.registry_registered,
        proof_url,
        proof_content,
    })
}

/// Stores asset metadata in the live `AssetRegistry` (immediate display) and
/// in the active wallet's liquid config in the registry (survives restart —
/// `open_wallet` reloads it). A wallet whose liquid side was auto-derived and
/// never saved gets its config created from the open manager's descriptor.
/// Best-effort: a failed save is logged, never surfaced.
fn persist_asset_metadata(state: &mut AppFfiState, metas: &[AssetMetadata]) {
    for meta in metas {
        state.asset_registry.add_local_metadata(meta.clone());
    }
    let descriptor = state.liquid.as_ref().map(|l| l.descriptor.clone());
    let Some(wallet_id) = state.active_wallet_id.clone() else {
        return;
    };
    let Some(entry) = state.registry.find_mut(&wallet_id) else {
        return;
    };
    if entry.liquid.is_none() {
        let Some(descriptor) = descriptor else { return };
        entry.liquid = Some(LiquidWalletConfig {
            descriptor,
            ever_synced: false,
            asset_metadata: Vec::new(),
        });
    }
    let Some(liq_cfg) = entry.liquid.as_mut() else {
        return;
    };
    for meta in metas {
        match liq_cfg
            .asset_metadata
            .iter_mut()
            .find(|m| m.asset_id == meta.asset_id)
        {
            Some(existing) => *existing = meta.clone(),
            None => liq_cfg.asset_metadata.push(meta.clone()),
        }
    }
    if let Err(e) = state.save_registry() {
        eprintln!("[wallet-ffi] Failed to persist issued-asset metadata: {e}");
    }
}

/// Reissue (mint more supply of) an existing Liquid asset.
pub fn reissue_asset(
    state: &mut AppFfiState,
    asset_id: &str,
    amount_sats: u64,
) -> Result<IssueResultDto, String> {
    let frozen = state.frozen_on(CoinChain::Liquid);
    let liq = state.liquid.as_mut().ok_or("Liquid wallet not open")?;
    let result = liq
        .reissue_asset(asset_id, amount_sats, &frozen)
        .map_err(|e| e.to_string())?;
    Ok(IssueResultDto {
        asset_id: result.asset_id,
        token_id: result.token_id,
        txid: result.txid,
        registry_registered: false,
        proof_url: String::new(),
        proof_content: String::new(),
    })
}

/// Burn (permanently destroy) units of a Liquid asset.
pub fn burn_asset(
    state: &mut AppFfiState,
    asset_id: &str,
    amount_sats: u64,
) -> Result<String, String> {
    let frozen = state.frozen_on(CoinChain::Liquid);
    let liq = state.liquid.as_mut().ok_or("Liquid wallet not open")?;
    liq.burn_asset(asset_id, amount_sats, &frozen)
        .map_err(|e| e.to_string())
}

/// Re-submit an asset contract to the Liquid registry (after domain proof is live).
pub fn reregister_asset(
    state: &AppFfiState,
    asset_id: &str,
    name: &str,
    ticker: &str,
    precision: u8,
    domain: &str,
) -> bool {
    match state.liquid.as_ref() {
        Some(liq) => liq.reregister_asset(asset_id, name, ticker, precision, domain),
        None => false,
    }
}
