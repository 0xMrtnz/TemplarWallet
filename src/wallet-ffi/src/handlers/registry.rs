//! Registry operations — list wallets, no wallet open required.

use templar_core::{
    account_xpub_bip84, generate_mnemonic_phrase, keyorigin_xpub_bip48, master_xprv,
    normalize_cosigner_key, validate_descriptor_pair, validate_mnemonic, BlindingKeySource,
    CoinChain, CosignerKeyInfo, CosignerRole, LiquidMultisigSetup, LiquidWalletConfig,
    LiquidWalletManager, MultisigSetupInfo, WalletEntry, WalletManager, WalletProfile,
};

use std::path::Path;

use crate::handlers::vault::{ensure_unlocked, require_encryption_for_seed};
use crate::state::AppFfiState;
use crate::types::WalletSummaryDto;

pub fn list_wallets(state: &AppFfiState) -> Result<Vec<WalletSummaryDto>, String> {
    let registry = &state.registry;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64;

    let dtos = registry
        .wallets
        .iter()
        .map(|w| {
            let (wallet_type, is_watch_only) = match &w.profile {
                WalletProfile::Software { .. } => ("singlesig", false),
                WalletProfile::HardwareWallet { .. } => ("watch_only", true),
                WalletProfile::Multisig { .. } => ("multisig", false),
                WalletProfile::Policy { .. } => ("policy", false),
            };

            let key = wallet_key_identity(&w.profile);
            let device_model = match &w.profile {
                WalletProfile::HardwareWallet { device_model, .. } => Some(device_model.clone()),
                _ => None,
            };

            WalletSummaryDto {
                id: w.id.clone(),
                name: w.name.clone(),
                wallet_type: wallet_type.to_string(),
                network: "testnet".to_string(),
                balance_sats: 0,
                tx_count: 0,
                last_sync_at: now - 300,
                is_watch_only,
                type_label: w.profile.type_label(),
                // Asked of the entry, which looks at both shapes a Liquid side
                // can take: a Liquid config, or a legacy Liquid-only hardware
                // profile. The bare `liquid_enabled` bool drifts false on
                // registry entries written before the flag existed.
                liquid_enabled: w.has_liquid(),
                // False for a Liquid-only entry, so the UI can hide the Bitcoin
                // screens instead of offering ones that can only fail.
                bitcoin_enabled: w.has_bitcoin(),
                device_model,
                master_fingerprint: key.fingerprint,
                xpub: key.xpub,
                required_sigs: key.required_sigs,
                total_signers: key.total_signers,
            }
        })
        .collect();

    Ok(dtos)
}

/// Public identity of a wallet, for the picker. Read from the registry only —
/// no BDK database is opened (that would take the sled lock on every wallet).
#[derive(Default)]
struct KeyIdentity {
    fingerprint: Option<String>,
    xpub: Option<String>,
    required_sigs: Option<usize>,
    total_signers: Option<usize>,
}

fn wallet_key_identity(profile: &WalletProfile) -> KeyIdentity {
    match profile {
        // Cheap BIP32 derivation — no wallet database involved.
        WalletProfile::Software { mnemonic } => match account_xpub_bip84(mnemonic) {
            Ok((fp, xpub)) => KeyIdentity {
                fingerprint: Some(fp),
                xpub: Some(xpub),
                ..Default::default()
            },
            Err(_) => KeyIdentity::default(),
        },
        // Hardware / air-gap / watch-only: the descriptor carries both.
        WalletProfile::HardwareWallet {
            receive_descriptor, ..
        } => match WalletManager::pub_info_from_descriptor(receive_descriptor, &[]) {
            Some(info) => KeyIdentity {
                fingerprint: Some(info.fingerprint),
                xpub: Some(info.xpub),
                ..Default::default()
            },
            None => KeyIdentity::default(),
        },
        // Multisig has no single key: show the threshold plus the local
        // signing fingerprint (the key this device actually holds).
        WalletProfile::Multisig {
            required_sigs,
            total_signers,
            local_fingerprint,
            ..
        } => KeyIdentity {
            fingerprint: local_fingerprint.clone(),
            xpub: None,
            required_sigs: Some(*required_sigs),
            total_signers: Some(*total_signers),
        },
        WalletProfile::Policy {
            local_fingerprint, ..
        } => KeyIdentity {
            fingerprint: local_fingerprint.clone(),
            ..Default::default()
        },
    }
}

pub fn reload_registry(state: &mut AppFfiState) -> Result<(), String> {
    state.registry = state.load_registry()?;
    Ok(())
}

/// Generate a fresh BIP39 mnemonic. Returns a list of words.
pub fn generate_mnemonic(word_count: usize) -> Result<Vec<String>, String> {
    let phrase = generate_mnemonic_phrase(word_count).map_err(|e| e.to_string())?;
    Ok(phrase.split_whitespace().map(str::to_string).collect())
}

/// Create and persist a new software wallet from a BIP39 mnemonic phrase.
///
/// When `liquid` is true, also derives the Liquid wallet descriptor and saves it
/// in the registry entry so the paired Liquid wallet can be opened immediately.
/// When false, the wallet is Bitcoin-only and no Liquid config is stored.
///
/// Returns the new wallet's `WalletSummaryDto`.
pub fn create_wallet(
    state: &mut AppFfiState,
    name: &str,
    mnemonic: &str,
    liquid: bool,
) -> Result<WalletSummaryDto, String> {
    // While the vault is locked the in-memory registry is empty; saving would
    // write a plaintext registry.json that the next unlock silently shadows.
    ensure_unlocked(state)?;
    // This wallet's seed is about to be written to disk — refuse unless at-rest
    // encryption is set up (A2). Covers every caller, wizard or not.
    require_encryption_for_seed(state)?;
    // Reject an invalid phrase up front (bad wordlist/checksum). Without this a
    // typo'd import is persisted and only fails later at open_wallet, leaving an
    // orphan registry entry (N2).
    validate_mnemonic(mnemonic).map_err(|e| e.to_string())?;

    // Derive the Liquid descriptor only when the user opted in.
    let liquid_config = if liquid {
        match LiquidWalletManager::from_mnemonic(mnemonic) {
            Ok(mgr) => Some(LiquidWalletConfig {
                descriptor: mgr.descriptor,
                ever_synced: false,
                asset_metadata: vec![],
            }),
            Err(e) => {
                // Non-fatal — wallet still usable for Bitcoin only.
                eprintln!("[create_wallet] Liquid descriptor derivation failed: {e}");
                None
            }
        }
    } else {
        None
    };
    let liquid_enabled = liquid_config.is_some();

    let mut entry = WalletEntry::new(
        name.to_string(),
        String::new(),
        WalletProfile::Software {
            mnemonic: mnemonic.to_string(),
        },
    );
    entry.liquid = liquid_config;
    entry.liquid_enabled = liquid_enabled;

    let id = entry.id.clone();
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64;

    state.registry.add(entry);
    state.save_registry()?;

    Ok(WalletSummaryDto {
        id,
        name: name.to_string(),
        wallet_type: "singlesig".to_string(),
        network: "testnet".to_string(),
        balance_sats: 0,
        tx_count: 0,
        last_sync_at: now,
        is_watch_only: false,
        type_label: "Software".to_string(),
        liquid_enabled,
        ..Default::default()
    })
}

/// Turn the Liquid side on for a software wallet that was created or restored
/// Bitcoin-only.
///
/// Restore used to pass `liquid: false` unconditionally, so every recovered
/// wallet ended up without a Liquid descriptor — no LIQUID section, no L-BTC
/// address, no CT descriptor — even though the same seed derives both chains.
/// Rather than force a re-import, this derives the descriptor from the seed
/// already in the entry and persists it. Idempotent: a wallet that already has
/// Liquid returns `Ok`.
///
/// Software profiles only. A hardware or multisig wallet's Liquid side needs
/// keys this app does not hold (a Jade slip77 key, the cosigners' BIP87
/// xpubs), so it must be set up when the wallet is created.
pub fn enable_liquid(state: &mut AppFfiState, wallet_id: &str) -> Result<(), String> {
    // Same guard as create_wallet: with the vault locked the in-memory registry
    // is empty, and saving it would write over the encrypted one.
    ensure_unlocked(state)?;

    let entry = state
        .registry
        .find(wallet_id)
        .ok_or_else(|| format!("Wallet not found: {wallet_id}"))?;
    if entry.has_liquid() {
        return Ok(());
    }
    let mnemonic = match &entry.profile {
        WalletProfile::Software { mnemonic } => mnemonic.clone(),
        _ => {
            return Err(
                "Liquid can only be added to a software wallet. Hardware and \
                        multisig wallets need their Liquid keys collected at setup time."
                    .into(),
            )
        }
    };

    let descriptor = LiquidWalletManager::from_mnemonic(&mnemonic)
        .map_err(|e| format!("Failed to derive the Liquid descriptor: {e}"))?
        .descriptor;

    let entry = state
        .registry
        .find_mut(wallet_id)
        .ok_or_else(|| format!("Wallet not found: {wallet_id}"))?;
    entry.liquid = Some(LiquidWalletConfig {
        descriptor,
        ever_synced: false,
        asset_metadata: vec![],
    });
    entry.liquid_enabled = true;
    state.save_registry()?;

    // Reopen so the Liquid manager exists in this session: without it every
    // Liquid call would answer "Liquid wallet not open" until the next restart.
    if state.active_wallet_id.as_deref() == Some(wallet_id) {
        crate::handlers::wallet_ops::open_wallet(state, wallet_id)?;
    }
    Ok(())
}

/// Create and persist an M-of-N multisig wallet from cosigner keyorigin xpubs.
///
/// `local_mnemonics` holds the seed of every key this device signs with; each
/// matching xpub in the descriptor is replaced by its xprv, so one sign pass
/// covers them all. Empty = watch-only coordinator. Returns the new wallet's
/// `WalletSummaryDto`.
///
/// `liquid_xpubs` are the same cosigners' BIP87 keys (`[fp/87h/1h/0h]tpub…`),
/// in the same order — a Liquid multisig is a second account on each seed, not
/// a re-use of the BIP48 Bitcoin key, so the caller collects both. Empty means
/// Bitcoin-only. `liquid_capable_keys` is how many of those keys the wizard
/// believes can actually produce an Elements signature (see the fund-trap
/// check below).
#[allow(clippy::too_many_arguments)]
pub fn create_multisig_wallet(
    state: &mut AppFfiState,
    name: &str,
    required_sigs: usize,
    total_signers: usize,
    cosigner_xpubs: &[String],
    local_mnemonics: &[String],
    liquid_xpubs: &[String],
    liquid_capable_keys: Option<usize>,
) -> Result<WalletSummaryDto, String> {
    ensure_unlocked(state)?;
    // A coordinator holding no key needs no vault; one that keeps a signing
    // seed here does (A2).
    if !local_mnemonics.is_empty() {
        require_encryption_for_seed(state)?;
    }
    // Every key is normalized and checked here, before a descriptor exists.
    // What arrives is whatever a co-signer sent — a scanned crypto-account
    // decodes to a whole `wpkh(...)` descriptor, Jade writes hardened steps as
    // `h`, a mainnet device's key is indistinguishable from a testnet one
    // except by its path — and a bad one used to reach the registry and only
    // fail at open, leaving a wallet that could never be opened again.
    let cosigner_xpubs = &normalize_key_list(cosigner_xpubs, CosignerRole::Bitcoin)?;

    let mut setup = MultisigSetupInfo::new(name, required_sigs, total_signers);
    setup.xpubs = cosigner_xpubs.to_vec();
    if !setup.is_complete() {
        return Err(format!(
            "Invalid multisig setup: {} of {} keys collected, threshold {}",
            cosigner_xpubs.len(),
            total_signers,
            required_sigs
        ));
    }
    if local_mnemonics.len() > total_signers {
        return Err("More local keys than total signers".into());
    }
    // Every local mnemonic must be one of the cosigners — catch mismatches
    // here with a clear message instead of a descriptor error later.
    for mn in local_mnemonics {
        let xpub = keyorigin_xpub_bip48(mn).map_err(|e| e.to_string())?;
        if !cosigner_xpubs.contains(&xpub) {
            let fp = xpub
                .trim_start_matches('[')
                .split('/')
                .next()
                .unwrap_or("?")
                .to_string();
            return Err(format!(
                "Local key {fp} is not among the cosigner xpubs. \
                 Add its xpub as one of the {total_signers} keys first."
            ));
        }
    }

    // Build the Liquid descriptor before anything is written: a wallet that
    // ends up half-created — Bitcoin side persisted, Liquid side rejected —
    // would need a repair path that does not exist.
    let liquid_descriptor = if liquid_xpubs.is_empty() {
        None
    } else {
        let liquid_xpubs = &normalize_key_list(liquid_xpubs, CosignerRole::Liquid)?;
        Some(build_liquid_multisig_descriptor(
            required_sigs,
            total_signers,
            liquid_xpubs,
            local_mnemonics,
            liquid_capable_keys,
        )?)
    };

    let (recv_desc, change_desc) = setup.build_descriptors().map_err(|e| e.to_string())?;

    let (recv_final, change_final, local_fps) = if local_mnemonics.is_empty() {
        (recv_desc, change_desc, Vec::new())
    } else {
        WalletManager::multisig_descriptors_with_signing_keys(
            local_mnemonics,
            &setup,
            &recv_desc,
            &change_desc,
        )
        .map_err(|e| e.to_string())?
    };

    // Last gate: parse the pair exactly as opening the wallet will. Nothing
    // above can be trusted to have caught every shape of bad key, and a
    // wallet that saves but cannot open is the worst outcome of the three.
    validate_descriptor_pair(&recv_final, &change_final).map_err(|e| e.to_string())?;

    let is_watch_only = local_fps.is_empty();
    let mut entry = WalletEntry::new(
        name.to_string(),
        String::new(),
        WalletProfile::Multisig {
            name: name.to_string(),
            required_sigs,
            total_signers,
            cosigner_xpubs: setup.xpubs.clone(),
            receive_descriptor: recv_final,
            change_descriptor: change_final,
            local_fingerprint: local_fps.first().cloned(),
            local_fingerprints: local_fps,
            // Kept only when there is a Liquid side to sign: LWK needs the
            // master seed, and storing seeds a wallet has no use for is
            // gratuitous exposure.
            local_mnemonics: if liquid_descriptor.is_some() {
                local_mnemonics.to_vec()
            } else {
                Vec::new()
            },
        },
    );

    let liquid_enabled = liquid_descriptor.is_some();
    if let Some(desc) = liquid_descriptor {
        entry = entry.with_liquid_descriptor(desc);
    }

    let id = entry.id.clone();
    let type_label = entry.profile.type_label();
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64;

    state.registry.add(entry);
    state.save_registry()?;

    Ok(WalletSummaryDto {
        id,
        name: name.to_string(),
        wallet_type: "multisig".to_string(),
        network: "testnet".to_string(),
        balance_sats: 0,
        tx_count: 0,
        last_sync_at: now,
        is_watch_only,
        type_label,
        liquid_enabled,
        ..Default::default()
    })
}

/// Normalizes a whole cosigner list, naming the key that is wrong.
///
/// "Key 2" is the wizard's own numbering, so the message points at the card
/// the user has to go back to rather than at an index.
fn normalize_key_list(raw: &[String], role: CosignerRole) -> Result<Vec<String>, String> {
    let mut out = Vec::with_capacity(raw.len());
    for (i, key) in raw.iter().enumerate() {
        let info = normalize_cosigner_key(key, role).map_err(|e| format!("Key {}: {e}", i + 1))?;
        if let Some(dup) = out.iter().position(|k| *k == info.normalized) {
            return Err(format!(
                "Key {} is the same key as key {}. A multisig needs {} different \
                 keys — repeating one lowers the threshold it actually enforces.",
                i + 1,
                dup + 1,
                raw.len()
            ));
        }
        out.push(info.normalized);
    }
    Ok(out)
}

/// Rebuilds a multisig wallet's descriptors from the cosigner keys it stored.
///
/// The repair path for wallets created before the keys were checked: a key
/// that arrived as a whole descriptor (an air-gapped device's scanned
/// `crypto-account`) was nested inside `sortedmulti` and persisted, so the
/// wallet saved and then failed every open with a Miniscript error. The keys
/// themselves are fine — only the string built from them is wrong — so
/// normalizing them and rebuilding recovers the same wallet, same addresses,
/// without collecting anything from the devices again.
///
/// Refuses rather than guesses when this app holds a signing key it cannot
/// rebuild: the descriptor then carries an xprv that is not in the registry,
/// and a rebuild would quietly turn a signing wallet into a watch-only one.
pub fn repair_multisig_wallet(
    state: &mut AppFfiState,
    wallet_id: &str,
) -> Result<WalletSummaryDto, String> {
    ensure_unlocked(state)?;
    let entry = state
        .registry
        .find(wallet_id)
        .cloned()
        .ok_or("Wallet not found")?;

    let WalletProfile::Multisig {
        name,
        required_sigs,
        total_signers,
        cosigner_xpubs,
        receive_descriptor,
        change_descriptor,
        local_fingerprints,
        local_mnemonics,
        ..
    } = entry.profile.clone()
    else {
        return Err("Only a multisig wallet is built from cosigner keys".into());
    };

    if validate_descriptor_pair(&receive_descriptor, &change_descriptor).is_ok() {
        return Err(format!(
            "\"{name}\" has nothing to repair — its descriptors are valid. Whatever \
             stopped it from opening is somewhere else."
        ));
    }
    if !local_fingerprints.is_empty() && local_mnemonics.is_empty() {
        return Err(format!(
            "\"{name}\" signs with a key held in this app, and the descriptor is the \
             only copy of it. Repairing would leave a watch-only wallet — create it \
             again instead."
        ));
    }

    let mut setup = MultisigSetupInfo::new(&name, required_sigs, total_signers);
    setup.xpubs = normalize_key_list(&cosigner_xpubs, CosignerRole::Bitcoin)?;
    let (recv, change) = setup.build_descriptors().map_err(|e| e.to_string())?;
    let (recv, change, fps) = if local_mnemonics.is_empty() {
        (recv, change, Vec::new())
    } else {
        WalletManager::multisig_descriptors_with_signing_keys(
            &local_mnemonics,
            &setup,
            &recv,
            &change,
        )
        .map_err(|e| e.to_string())?
    };
    validate_descriptor_pair(&recv, &change).map_err(|e| e.to_string())?;

    let profile = WalletProfile::Multisig {
        name: name.clone(),
        required_sigs,
        total_signers,
        cosigner_xpubs: setup.xpubs.clone(),
        receive_descriptor: recv,
        change_descriptor: change,
        local_fingerprint: fps.first().cloned(),
        local_fingerprints: fps.clone(),
        local_mnemonics,
    };
    let is_watch_only = fps.is_empty();
    let type_label = profile.type_label();
    let liquid_enabled = entry.liquid_descriptor().is_some();
    let updated = state
        .registry
        .find_mut(wallet_id)
        .ok_or("Wallet not found")?;
    updated.profile = profile;
    state.save_registry()?;

    Ok(WalletSummaryDto {
        id: wallet_id.to_string(),
        name,
        wallet_type: "multisig".to_string(),
        network: "testnet".to_string(),
        balance_sats: 0,
        tx_count: 0,
        last_sync_at: 0,
        is_watch_only,
        type_label,
        liquid_enabled,
        ..Default::default()
    })
}

/// Checks one cosigner key as it is typed or scanned, for the wizard.
///
/// Same rules as wallet creation, reported early: the wizard shows the
/// fingerprint and path it resolved, or the reason it cannot use the key,
/// while the user is still looking at the field they filled.
pub fn validate_cosigner_key(raw: &str, liquid: bool) -> Result<CosignerKeyInfo, String> {
    let role = if liquid {
        CosignerRole::Liquid
    } else {
        CosignerRole::Bitcoin
    };
    normalize_cosigner_key(raw, role).map_err(|e| e.to_string())
}

/// Build and validate the CT descriptor for a multisig's Liquid side.
///
/// Refuses three things that would otherwise surface as a broken wallet:
/// a key list that does not line up with the Bitcoin side, a local seed whose
/// BIP87 key is not in the descriptor (so this app could never sign), and a
/// wallet whose threshold exceeds the number of keys that can sign on Liquid
/// at all.
fn build_liquid_multisig_descriptor(
    required_sigs: usize,
    total_signers: usize,
    liquid_xpubs: &[String],
    local_mnemonics: &[String],
    liquid_capable_keys: Option<usize>,
) -> Result<String, String> {
    if liquid_xpubs.len() != total_signers {
        return Err(format!(
            "Liquid needs one BIP87 key per cosigner: got {} for a {}-of-{} wallet. \
             The Liquid side is a separate account (m/87'/1'/0') on each seed, so \
             every co-signer exports a second key.",
            liquid_xpubs.len(),
            required_sigs,
            total_signers
        ));
    }

    // A Liquid signature can only come from software keys held here or from a
    // Jade — every other device is Bitcoin-only in firmware. If fewer keys
    // than the threshold can sign, the wallet would receive funds it could
    // never spend, so it is refused at creation rather than discovered later
    // with money in it.
    if let Some(capable) = liquid_capable_keys {
        if capable < required_sigs {
            return Err(format!(
                "Only {capable} of the {total_signers} keys can sign on Liquid, but \
                 {required_sigs} signatures are required. Liquid funds sent to this \
                 wallet could never be spent. Add a Blockstream Jade or a key held \
                 in this app, or create the wallet as Bitcoin-only."
            ));
        }
    }

    // Every local seed must appear in the Liquid key list too — a mismatch
    // here means the BIP87 keys were collected in a different order, or the
    // wrong account was exported, and the app would silently become a
    // Liquid coordinator that cannot sign.
    for mn in local_mnemonics {
        let xpub = LiquidMultisigSetup::derive_xpub_from_mnemonic(mn).map_err(|e| e.to_string())?;
        if !liquid_xpubs.contains(&xpub) {
            let fp = xpub
                .trim_start_matches('[')
                .split('/')
                .next()
                .unwrap_or("?")
                .to_string();
            return Err(format!(
                "Local key {fp} has no matching BIP87 key in the Liquid list. \
                 Check the keys are in the same order as the Bitcoin ones."
            ));
        }
    }

    // Deterministic from the keys (ELIP151, carried as raw SLIP77 bytes so a
    // Jade can register it): every co-signer who builds this wallet from the
    // same N keys gets the same descriptor, blinding key included — the way
    // the Bitcoin side already works. A coordinator-generated random key,
    // which this used to be, meant each co-signer's copy was a different
    // Liquid wallet: it could not read the coordinator's PSET, and could not
    // finalize it.
    LiquidMultisigSetup::build_descriptor(required_sigs, liquid_xpubs, &BlindingKeySource::Elip151)
        .map_err(|e| e.to_string())
}

/// Derive the BIP48 cosigner xpub (`[fp/48'/1'/0'/2']tpub…`) from a mnemonic.
pub fn derive_cosigner_xpub(mnemonic: &str) -> Result<String, String> {
    keyorigin_xpub_bip48(mnemonic).map_err(|e| e.to_string())
}

/// Derive the BIP87 Liquid cosigner xpub (`[fp/87'/1'/0']tpub…`) from a
/// mnemonic. The Liquid half of an enrolment; the Bitcoin half is
/// [`derive_cosigner_xpub`].
pub fn derive_liquid_cosigner_xpub(mnemonic: &str) -> Result<String, String> {
    LiquidMultisigSetup::derive_xpub_from_mnemonic(mnemonic).map_err(|e| e.to_string())
}

/// BIP87 Liquid cosigner xpub for an existing software wallet in the registry.
pub fn get_liquid_cosigner_xpub(state: &AppFfiState, wallet_id: &str) -> Result<String, String> {
    ensure_unlocked(state)?;
    let entry = state
        .registry
        .wallets
        .iter()
        .find(|w| w.id == wallet_id)
        .ok_or("Wallet not found")?;
    match &entry.profile {
        WalletProfile::Software { mnemonic } => {
            LiquidMultisigSetup::derive_xpub_from_mnemonic(mnemonic).map_err(|e| e.to_string())
        }
        _ => Err("Only software wallets can export a cosigner key".to_string()),
    }
}

/// BIP48 cosigner xpub for an existing software wallet in the registry.
pub fn get_cosigner_xpub(state: &AppFfiState, wallet_id: &str) -> Result<String, String> {
    ensure_unlocked(state)?;
    let entry = state
        .registry
        .wallets
        .iter()
        .find(|w| w.id == wallet_id)
        .ok_or("Wallet not found")?;
    match &entry.profile {
        WalletProfile::Software { mnemonic } => {
            keyorigin_xpub_bip48(mnemonic).map_err(|e| e.to_string())
        }
        _ => Err("Only software wallets can export a cosigner key".to_string()),
    }
}

/// Return the BIP39 seed words of a software wallet.
pub fn get_mnemonic(state: &AppFfiState, wallet_id: &str) -> Result<Vec<String>, String> {
    ensure_unlocked(state)?;
    let entry = state
        .registry
        .wallets
        .iter()
        .find(|w| w.id == wallet_id)
        .ok_or("Wallet not found")?;
    match &entry.profile {
        WalletProfile::Software { mnemonic } => {
            Ok(mnemonic.split_whitespace().map(str::to_string).collect())
        }
        _ => Err("This wallet has no seed phrase stored on this device".to_string()),
    }
}

/// Return the raw master extended private key (xprv/tprv) of a software wallet.
pub fn get_private_key(state: &AppFfiState, wallet_id: &str) -> Result<String, String> {
    ensure_unlocked(state)?;
    let entry = state
        .registry
        .wallets
        .iter()
        .find(|w| w.id == wallet_id)
        .ok_or("Wallet not found")?;
    match &entry.profile {
        WalletProfile::Software { mnemonic } => master_xprv(mnemonic).map_err(|e| e.to_string()),
        _ => Err("This wallet has no private key stored on this device".to_string()),
    }
}

/// Rename a wallet in the registry and persist the change.
pub fn rename_wallet(
    state: &mut AppFfiState,
    wallet_id: &str,
    new_name: &str,
) -> Result<(), String> {
    ensure_unlocked(state)?;
    let entry = state
        .registry
        .find_mut(wallet_id)
        .ok_or("Wallet not found")?;
    entry.name = new_name.to_string();
    state.save_registry()
}

/// Freezes or unfreezes `outpoints` of a wallet on `chain`, persisted on its
/// registry entry — sealed with the vault, read back by every builder and
/// signer. A save that fails leaves the list as it was.
pub fn set_utxos_frozen(
    state: &mut AppFfiState,
    wallet_id: &str,
    chain: &str,
    outpoints: &[String],
    frozen: bool,
) -> Result<(), String> {
    ensure_unlocked(state)?;
    let chain = CoinChain::parse(chain).ok_or_else(|| format!("Unknown chain: {chain}"))?;
    let entry = state
        .registry
        .find_mut(wallet_id)
        .ok_or("Wallet not found")?;
    let before = entry.frozen.clone();
    entry.frozen.set(chain, outpoints, frozen)?;
    if let Err(e) = state.save_registry() {
        if let Some(entry) = state.registry.find_mut(wallet_id) {
            entry.frozen = before;
        }
        return Err(e);
    }
    Ok(())
}

/// Delete a wallet from the registry, persist, and remove its on-disk BDK
/// database. The LWK `enc_cache` subdirs are left behind: they are keyed by a
/// descriptor hash we cannot recompute here, and are harmless cache data.
pub fn delete_wallet(state: &mut AppFfiState, wallet_id: &str) -> Result<(), String> {
    ensure_unlocked(state)?;
    let removed = state.registry.find(wallet_id).cloned();

    // If the wallet being deleted is currently open, close it first — sled
    // keeps its directory locked while open, and removing files under a live
    // handle fails on Windows.
    if state.active_wallet_id.as_deref() == Some(wallet_id) {
        state.bitcoin = None;
        state.liquid = None;
        state.active_wallet_id = None;
        state.last_sync_btc = None;
        state.last_sync_liquid = None;
        state.last_sync_at = None;
    }

    state.registry.wallets.retain(|w| w.id != wallet_id);
    state.save_registry()?;

    // Best-effort cleanup after the registry write succeeded: the entry is
    // gone either way, and a leftover sled dir is only a cache.
    if let Some(entry) = removed {
        if let Some(dir) = bdk_db_dir(&state.data_dir, &entry) {
            if state
                .registry
                .wallets
                .iter()
                .any(|w| bdk_db_dir(&state.data_dir, w).as_deref() == Some(&dir))
            {
                // Another registered wallet resolves to the same directory
                // (a multisig from before databases were keyed by id, sharing
                // its name and threshold with a newer one that has not been
                // opened yet) — deleting it would destroy a live cache.
                eprintln!("[delete_wallet] keeping shared BDK db dir {dir}");
            } else {
                let path = state.data_dir.join(&dir);
                match std::fs::remove_dir_all(&path) {
                    Ok(()) => eprintln!("[delete_wallet] removed {}", path.display()),
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                    Err(e) => eprintln!("[delete_wallet] could not remove {}: {e}", path.display()),
                }
            }
        }
    }
    Ok(())
}

/// Directory name (under `data_dir`) of the BDK sled database this wallet
/// owns, mirroring exactly how the open paths build it:
/// - Software → `bdk_sw_<master fingerprint>` (`WalletManager::new`)
/// - Hardware/watch-only/air-gap → `bdk_hw_<wallet id>` (`open_wallet`'s
///   `from_descriptors` db key); Liquid-only `ct(...)` entries never open a
///   BDK database, and the legacy shared `bdk_hw_db` is never returned.
/// - Multisig → `bdk_ms_<wallet id>` once the wallet has one, else the
///   name-keyed directory older builds gave it (`from_multisig_profile`)
/// - Policy → `bdk_<profile key>`
fn bdk_db_dir(data_dir: &Path, entry: &WalletEntry) -> Option<String> {
    match &entry.profile {
        WalletProfile::Software { mnemonic } => account_xpub_bip84(mnemonic)
            .ok()
            .map(|(fp, _)| format!("bdk_sw_{fp}")),
        WalletProfile::HardwareWallet {
            receive_descriptor, ..
        } => {
            if receive_descriptor.trim_start().starts_with("ct(") {
                None
            } else {
                Some(format!("bdk_hw_{}", entry.id))
            }
        }
        WalletProfile::Multisig { .. } => {
            let own = WalletManager::multisig_db_dir(&entry.id);
            Some(if data_dir.join(&own).exists() {
                own
            } else {
                WalletManager::legacy_multisig_db_dir(&entry.profile)
            })
        }
        WalletProfile::Policy { .. } => Some(format!("bdk_{}", entry.profile.key())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MN: &str =
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

    #[test]
    fn software_profile_exposes_key_identity() {
        let profile = WalletProfile::Software {
            mnemonic: MN.to_string(),
        };
        let key = wallet_key_identity(&profile);
        assert!(key.fingerprint.is_some(), "fingerprint missing");
        assert!(
            key.xpub.as_deref().unwrap_or("").starts_with("tpub"),
            "xpub: {:?}",
            key.xpub
        );
    }
}
