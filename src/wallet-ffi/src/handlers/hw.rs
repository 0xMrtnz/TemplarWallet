//! Hardware wallet import via HWI subprocess and watch-only (air-gap) setup.
//!
//! All calls are **blocking** — the dispatcher runs them in a background Dart isolate.

#[cfg(feature = "hardware")]
use templar_core::{HwDeviceInfo, LiquidWalletConfig};
use templar_core::{WalletEntry, WalletManager, WalletProfile};

use crate::state::AppFfiState;
#[cfg(feature = "hardware")]
use crate::types::HwImportResultDto;
use crate::types::WalletSummaryDto;

/// Enumerate connected USB hardware devices via HWI.
#[cfg(feature = "hardware")]
pub fn enumerate_hw_devices() -> Result<Vec<HwDeviceInfo>, String> {
    WalletManager::enumerate_hw_devices().map_err(|e| e.to_string())
}

/// Devices the OS can see, read in-process from USB descriptors — no `hwi`,
/// no subprocess.
///
/// Detection only: this says a Ledger is plugged in, not which wallet it
/// holds, because a master fingerprint requires the per-family protocol. It
/// exists so a platform where the HWI subprocess cannot run (macOS under the
/// App Sandbox) can still tell "nothing is plugged in" apart from "your device
/// is here but this build cannot talk to it yet".
#[cfg(feature = "hardware")]
pub fn enumerate_native_devices() -> Result<Vec<templar_core::NativeDeviceInfo>, String> {
    templar_core::enumerate_native().map_err(|e| e.to_string())
}

/// Fetch the BIP48 cosigner xpub from a connected USB device
/// (`[fingerprint/48'/1'/0'/2']tpub…` — same shape as software cosigner keys).
#[cfg(feature = "hardware")]
pub fn get_hw_cosigner_xpub(fingerprint: &str) -> Result<String, String> {
    WalletManager::hw_cosigner_xpub(fingerprint).map_err(|e| e.to_string())
}

/// Derive a Liquid CT descriptor from a Bitcoin xpub or wpkh descriptor:
/// `ct(elip151,elwpkh([fp/path]xpub/<0;1>/*))`.
///
/// ELIP151 derives the blinding key from the descriptor, so no seed is needed
/// — which is exactly why this is for **software and watch-only** wallets
/// only. Never use it for a wallet a device will sign: a Jade blinds with its
/// own SLIP-0077 key, so it would not recognise these outputs as its own and
/// would refuse to spend them. The Jade import reads the descriptor off the
/// device instead (see `jade_liquid_descriptor`).
pub fn derive_liquid_descriptor(btc_desc: &str) -> Result<String, String> {
    let (recv, _change) =
        templar_core::normalize_watch_only_descriptors(btc_desc).map_err(|e| e.to_string())?;
    let ct = templar_core::liquid_descriptor_from_wpkh(&recv).map_err(|e| e.to_string())?;
    // Round-trip through the CT validator so the button can never fill the
    // field with something the wallet would later refuse.
    templar_core::validate_ct_descriptor(&ct).map_err(|e| e.to_string())
}

/// Everything the hardware setup screen needs to decide what to show, in one
/// round trip: which binary will run, its version, and — on Linux — whether
/// udev rules are in place, since without them enumeration fails for every
/// non-root user and that is the platform's single biggest first-run wall.
#[cfg(feature = "hardware")]
pub fn hwi_diagnostics() -> serde_json::Value {
    let bin = templar_core::resolve_hwi_bin();
    serde_json::json!({
        "hardware_supported": true,
        "resolved_bin": bin.as_ref().map(|p| p.to_string_lossy().to_string()),
        // and_then, not and: `and` would evaluate hwi_version() — a subprocess
        // spawn — even when there is no binary to ask.
        "version": bin.as_ref().and_then(|_| templar_core::hwi_version()),
        "platform": platform_tag(),
        // Only meaningful on Linux; null elsewhere so the UI can skip the card.
        "udev_rules_installed": udev_rules_installed(),
        "liquid_hw_signing": templar_core::LIQUID_HW_SIGNING_SUPPORTED,
        // Total HID devices visible to us, wallet or not. Zero on a laptop
        // means the platform is denying HID access outright, which no user
        // action fixes — worth distinguishing from "nothing is plugged in".
        "hid_device_count": templar_core::hid_device_count(),
        // Families this build drives in-process, and whether the HWI fallback
        // can run here at all. The UI states both instead of guessing from the
        // platform tag — the answer is per device family, not per OS, and
        // duplicating the rule in Dart is how the two drift apart.
        "native_families": templar_core::native_family_names(),
        "hwi_usable": templar_core::hwi_usable(),
    })
}

/// Stable tag every USB hardware route answers with when the build has no
/// `hardware` feature (Android). Same `TAG: reason` shape as the other
/// hardware errors, so the Dart classifier needs no special case.
#[cfg(not(feature = "hardware"))]
pub const HW_UNSUPPORTED: &str = "HW_UNSUPPORTED: Hardware wallets over USB are not available on \
     this platform. Use a QR air-gap wallet to sign instead.";

/// The no-hardware shape of `hwi_status`: same keys, everything off, plus
/// `hardware_supported: false` so the UI can hide the whole flow.
#[cfg(not(feature = "hardware"))]
pub fn hwi_diagnostics() -> serde_json::Value {
    serde_json::json!({
        "hardware_supported": false,
        "resolved_bin": serde_json::Value::Null,
        "version": serde_json::Value::Null,
        "platform": platform_tag(),
        "udev_rules_installed": udev_rules_installed(),
        "liquid_hw_signing": templar_core::LIQUID_HW_SIGNING_SUPPORTED,
        "hid_device_count": 0,
        "native_families": Vec::<&str>::new(),
        "hwi_usable": false,
    })
}

fn platform_tag() -> &'static str {
    if cfg!(target_os = "macos") {
        "macos"
    } else if cfg!(target_os = "windows") {
        "windows"
    } else if cfg!(target_os = "linux") {
        "linux"
    } else if cfg!(target_os = "android") {
        "android"
    } else {
        "unknown"
    }
}

/// `Some(true/false)` on Linux, `None` on platforms where udev is irrelevant.
///
/// Presence of *any* known HWI rules file counts: distributions and users
/// install different subsets, and demanding the full set would nag people
/// whose device already works.
fn udev_rules_installed() -> Option<bool> {
    if !cfg!(target_os = "linux") {
        return None;
    }
    const NAMES: [&str; 9] = [
        "20-hw1.rules",
        "51-coinkite.rules",
        "51-hid-digitalbitbox.rules",
        "51-trezor.rules",
        "51-usb-keepkey.rules",
        "52-hid-digitalbitbox.rules",
        "53-hid-bitbox02.rules",
        "54-hid-bitbox02.rules",
        "55-usb-jade.rules",
    ];
    for dir in [
        "/etc/udev/rules.d",
        "/lib/udev/rules.d",
        "/usr/lib/udev/rules.d",
    ] {
        for name in NAMES {
            if std::path::Path::new(dir).join(name).exists() {
                return Some(true);
            }
        }
    }
    Some(false)
}

/// The receive descriptor of a registry entry, where it has one.
///
/// A software wallet stores a mnemonic instead, and needs no descriptor here:
/// it never reaches a device.
#[cfg(feature = "hardware")]
fn receive_descriptor_of(entry: &templar_core::WalletEntry) -> Option<String> {
    use templar_core::WalletProfile::*;
    match &entry.profile {
        HardwareWallet {
            receive_descriptor, ..
        }
        | Multisig {
            receive_descriptor, ..
        }
        | Policy {
            receive_descriptor, ..
        } => {
            // A multisig or policy wallet that holds a local key stores its
            // *signing* descriptor, with that key's tprv embedded. A device
            // needs the public shape only, and anything a driver echoes into
            // an error must never carry a private key.
            Some(templar_core::public_descriptor(receive_descriptor))
        }
        Software { .. } => None,
    }
}

/// Sign a base64 PSBT with the USB device identified by `fingerprint`.
///
/// Wallet-independent on purpose: this is what lets a hardware device act as a
/// co-signer on a multisig PSBT, which previously had no path at all — the
/// send flow only reached a device when the *whole wallet* was a hardware
/// wallet, so an enrolled device key could never actually sign.
///
/// The open wallet's receive descriptor rides along when there is one: a
/// Ledger signs under a wallet policy, and for multisig that policy can only
/// be rebuilt from the descriptor — the PSBT carries public keys, not the
/// cosigners' xpubs. Without an open wallet the device falls back to its own
/// single-sig key, which is the right answer for the single-sig case and an
/// explicit error for the other.
#[cfg(feature = "hardware")]
pub fn sign_psbt_hw(
    state: &AppFfiState,
    fingerprint: &str,
    psbt_base64: &str,
) -> Result<String, String> {
    if psbt_base64.trim().is_empty() {
        return Err("No PSBT to sign".to_string());
    }
    // Same gate as software signing: the amounts the review showed must be
    // the amounts the device's signature commits to.
    let psbt = WalletManager::psbt_from_base64(psbt_base64.trim()).map_err(|e| e.to_string())?;
    templar_core::check_input_utxos(&psbt).map_err(|e| e.to_string())?;
    templar_core::bitcoin::wallet::refuse_frozen_inputs(
        &psbt,
        &state.frozen_on(templar_core::CoinChain::Bitcoin),
    )
    .map_err(|e| e.to_string())?;
    let descriptor = state
        .active_wallet_id
        .as_deref()
        .and_then(|id| state.registry.find(id))
        .and_then(receive_descriptor_of);
    WalletManager::sign_psbt_with_hw_desc(fingerprint, psbt_base64.trim(), descriptor.as_deref())
        .map_err(|e| e.to_string())
}

/// Point the app at a freshly installed `hwi` binary (auto-downloaded by the
/// UI) without restarting. The standalone binary is self-contained — no
/// PYTHONPATH or venv wiring needed. Stored via templar-core's `set_hwi_env`
/// rather than `std::env::set_var`, which is UB once other threads exist.
#[cfg(feature = "hardware")]
pub fn set_hwi_path(path: &str) -> Result<(), String> {
    let p = std::path::Path::new(path);
    if !p.is_file() {
        return Err(format!("No hwi binary at {path}"));
    }
    templar_core::bitcoin::hardware::set_hwi_env(templar_core::bitcoin::hardware::HwiEnv {
        bin: p.to_path_buf(),
        ..Default::default()
    });
    eprintln!("[hw] HWI binary set to {path}");
    Ok(())
}

/// Pair a hardware wallet: **one** wallet with the sides the device can hold.
///
/// - Bitcoin always: descriptors read from the device.
/// - Liquid when `liquid == true` and the device is a **Jade** — the only
///   family with Liquid in firmware. The CT descriptor is read from the device
///   so the Jade can actually spend from it, and it is stored on the same
///   entry, next to the Bitcoin descriptors.
///
/// Both sides come from a single device session ([`WalletManager::hw_pairing`]):
/// a Jade asks for its PIN on every connection and only one program can hold
/// its serial port, so the old two-connection shape cost two prompts and let
/// the second connection lose the port — which is how a wallet ended up with a
/// Liquid side and a Bitcoin side that was never created.
///
/// A Liquid failure does not fail the pairing: the Bitcoin wallet is real and
/// usable, and the reason travels back in `liquid_error` for the recap screen
/// to show. A non-Jade device asked for Liquid is refused the Liquid side the
/// same way — pairing Liquid with a device that cannot sign Elements would
/// create somewhere funds arrive and never leave.
#[cfg(feature = "hardware")]
pub fn import_hw_wallet(
    state: &mut AppFfiState,
    name: &str,
    fingerprint: &str,
    liquid: bool,
) -> Result<HwImportResultDto, String> {
    // While the vault is locked the in-memory registry is empty; saving would
    // write a plaintext registry.json that the next unlock silently shadows.
    crate::handlers::vault::ensure_unlocked(state)?;
    if name.trim().is_empty() {
        return Err("Wallet name is required".to_string());
    }

    let pairing = WalletManager::hw_pairing(fingerprint, liquid).map_err(|e| e.to_string())?;

    // Validate before storing: a CT descriptor the wallet would later refuse
    // must never reach the registry, or the wallet opens broken.
    let mut liquid_error = pairing.liquid_error.clone();
    let liquid_desc = match pairing.liquid_ct_descriptor.as_deref() {
        Some(desc) => match templar_core::validate_ct_descriptor(desc) {
            Ok(valid) => Some(valid),
            Err(e) => {
                liquid_error = Some(e.to_string());
                None
            }
        },
        None => None,
    };

    let profile = WalletProfile::HardwareWallet {
        device_fingerprint: pairing.fingerprint.clone(),
        device_model: pairing.model.clone(),
        receive_descriptor: pairing.receive_descriptor.clone(),
        change_descriptor: pairing.change_descriptor.clone(),
    };
    let mut entry = WalletEntry::new(name.trim().to_string(), String::new(), profile);
    if let Some(desc) = liquid_desc.clone() {
        entry = entry.with_liquid_descriptor(desc);
    }

    let summary = summary_of(&entry);
    state.registry.add(entry);
    state.save_registry()?;

    Ok(HwImportResultDto {
        wallet: summary,
        fingerprint: pairing.fingerprint,
        device_model: pairing.model,
        bitcoin_descriptor: pairing.receive_descriptor,
        liquid_descriptor: liquid_desc,
        liquid_error,
        liquid_requested: liquid,
    })
}

/// Add a Liquid side to a hardware wallet that was paired Bitcoin-only.
///
/// The device must be the one this wallet belongs to: its fingerprint is
/// matched before anything is read, so a second Jade on the desk cannot lend
/// its Liquid descriptor to another device's wallet — that would produce a
/// Liquid wallet whose owner device could never sign for it.
#[cfg(feature = "hardware")]
pub fn add_liquid_to_wallet(
    state: &mut AppFfiState,
    wallet_id: &str,
) -> Result<WalletSummaryDto, String> {
    crate::handlers::vault::ensure_unlocked(state)?;

    let entry = state
        .registry
        .find(wallet_id)
        .ok_or_else(|| format!("Wallet not found: {wallet_id}"))?
        .clone();

    if entry.has_liquid() {
        return Err("This wallet already has a Liquid side.".to_string());
    }
    let WalletProfile::HardwareWallet {
        device_fingerprint,
        device_model,
        ..
    } = &entry.profile
    else {
        return Err(
            "Only a hardware wallet can read a Liquid descriptor from its device.".to_string(),
        );
    };
    // An air-gap or pure watch-only entry has no device to ask: its
    // "fingerprint" is the literal "airgap", and Jade's QR mode carries no
    // blinding key at all.
    if device_fingerprint == "airgap" {
        return Err(format!(
            "{}: This wallet was set up air-gapped (QR), and Jade's QR mode is \
             Bitcoin-only. Connect the Jade over USB and pair a new wallet to \
             use Liquid.",
            templar_core::ERR_LIQUID_HW_UNSUPPORTED
        ));
    }
    if !templar_core::is_jade_model(device_model) {
        return Err(format!(
            "{}: {}",
            templar_core::ERR_LIQUID_HW_UNSUPPORTED,
            templar_core::liquid_hw_unsupported_reason()
        ));
    }

    let descriptor =
        WalletManager::hw_liquid_ct_descriptor(device_fingerprint).map_err(|e| e.to_string())?;
    let descriptor =
        templar_core::validate_ct_descriptor(&descriptor).map_err(|e| e.to_string())?;

    let stored = state
        .registry
        .find_mut(wallet_id)
        .ok_or_else(|| format!("Wallet not found: {wallet_id}"))?;
    stored.liquid = Some(LiquidWalletConfig {
        descriptor,
        ever_synced: false,
        asset_metadata: Vec::new(),
    });
    stored.liquid_enabled = true;
    let summary = summary_of(stored);
    state.save_registry()?;
    Ok(summary)
}

/// The picker/recap view of a registry entry.
///
/// Built from the entry itself rather than assembled by each caller: the
/// network flags and the type label have to agree with what was actually
/// persisted, and hand-written copies of them are how a wallet ended up
/// advertising a Liquid side it did not have.
fn summary_of(entry: &WalletEntry) -> WalletSummaryDto {
    let device_model = match &entry.profile {
        WalletProfile::HardwareWallet { device_model, .. } => Some(device_model.clone()),
        _ => None,
    };
    // Public identity straight from the descriptor, so the recap screen can
    // show which key this wallet watches without opening any wallet database.
    let key = match &entry.profile {
        WalletProfile::HardwareWallet {
            receive_descriptor, ..
        } if entry.has_bitcoin() => {
            WalletManager::pub_info_from_descriptor(receive_descriptor, &[])
        }
        _ => None,
    };
    WalletSummaryDto {
        id: entry.id.clone(),
        name: entry.name.clone(),
        wallet_type: "watch_only".to_string(),
        network: "testnet".to_string(),
        balance_sats: 0,
        tx_count: 0,
        last_sync_at: unix_now(),
        // No private key on this computer — the device holds it. Not the same
        // as view-only: a hardware wallet can spend, the device signs.
        is_watch_only: true,
        type_label: entry.profile.type_label(),
        liquid_enabled: entry.has_liquid(),
        bitcoin_enabled: entry.has_bitcoin(),
        device_model,
        master_fingerprint: key.as_ref().map(|k| k.fingerprint.clone()),
        xpub: key.as_ref().map(|k| k.xpub.clone()),
        ..Default::default()
    }
}

/// Create a watch-only wallet from descriptors.
///
/// `airgap` distinguishes the two flows that share this profile: the air-gap
/// setup (SeedSigner / Jade — signs via QR, keeps Send) and the pure
/// watch-only setup (view-only, Send hidden in the UI). A non-empty
/// `liquid_ct_desc` pairs a Liquid watch-only wallet.
///
/// All descriptors are normalized and validated **here**, before anything is
/// persisted: a bare xpub is wrapped, a multipath descriptor is split, an
/// empty `change_desc` is derived, and malformed input is rejected with a
/// descriptive error instead of being stored and failing silently at the
/// next open (which surfaced as a wrong balance).
pub fn create_watch_only_wallet(
    state: &mut AppFfiState,
    name: &str,
    recv_desc: &str,
    change_desc: &str,
    liquid_ct_desc: &str,
    airgap: bool,
) -> Result<WalletSummaryDto, String> {
    // See import_hw_wallet: no registry writes while the vault is locked.
    crate::handlers::vault::ensure_unlocked(state)?;
    if recv_desc.trim().is_empty() {
        return Err("Receive descriptor is required".to_string());
    }

    let (recv, derived_change) =
        templar_core::normalize_watch_only_descriptors(recv_desc).map_err(|e| e.to_string())?;
    let change = if change_desc.trim().is_empty() {
        derived_change
    } else {
        // An explicitly supplied change descriptor is normalized on its own,
        // taking the CHANGE element: a /1/* descriptor passes through as-is,
        // a multipath <0;1> input yields its /1/* branch, a bare xpub becomes
        // wpkh(key/1/*). Taking .0 here would silently store the /0/* receive
        // branch as change — address reuse.
        templar_core::normalize_watch_only_descriptors(change_desc)
            .map_err(|e| e.to_string())?
            .1
    };

    // A device that only speaks QR cannot carry Liquid: Jade's QR mode is
    // Bitcoin-only (no master blinding key export, no PSET transport), so the
    // only descriptor an air-gap flow could produce is ELIP151-blinded — funds
    // the device cannot recognise as its own, receivable and unspendable. The
    // wizard hides the field; this refuses the pairing even if it doesn't.
    if airgap && !liquid_ct_desc.trim().is_empty() {
        return Err(format!(
            "{}: An air-gap (QR) wallet is Bitcoin-only. Jade's QR mode does \
             not do Liquid — connect the Jade over USB to add a Liquid wallet.",
            templar_core::ERR_LIQUID_HW_UNSUPPORTED
        ));
    }

    let liquid_ct = if liquid_ct_desc.trim().is_empty() {
        None
    } else {
        Some(templar_core::validate_ct_descriptor(liquid_ct_desc).map_err(|e| e.to_string())?)
    };

    let device_model = if airgap { "air-gap" } else { "watch-only" };
    let profile = WalletProfile::HardwareWallet {
        device_fingerprint: "airgap".to_string(),
        device_model: device_model.to_string(),
        receive_descriptor: recv,
        change_descriptor: change,
    };

    let mut entry = WalletEntry::new(name.to_string(), String::new(), profile);
    if let Some(descriptor) = liquid_ct {
        entry = entry.with_liquid_descriptor(descriptor);
    }
    let summary = summary_of(&entry);
    state.registry.add(entry);
    state.save_registry()?;

    Ok(summary)
}

/// Connect to a Jade over USB serial and read its Liquid CT descriptor.
///
/// Returns `(descriptor, fingerprint)`. When `expect_fingerprint` is given the
/// device must match it — otherwise importing with two devices attached, or
/// after swapping one, would happily pair a Bitcoin wallet from device A with
/// a Liquid wallet from device B under one name.
///
/// This path never touches HWI, so it is also the only hardware flow that
/// works on macOS, where the sandbox forbids spawning the HWI subprocess.
#[cfg(feature = "hardware")]
fn jade_liquid_descriptor(
    network: &templar_core::LiquidNetwork,
    expect_fingerprint: Option<&str>,
) -> Result<(String, String), String> {
    let jade = templar_core::JadeLiquidSigner::connect_on(network).map_err(|e| e.to_string())?;
    let fingerprint = jade.fingerprint().map_err(|e| e.to_string())?;

    if let Some(expected) = expect_fingerprint {
        if !fingerprint.eq_ignore_ascii_case(expected.trim()) {
            return Err(format!(
                "{}: The connected Jade ({fingerprint}) is not the device this \
                 wallet was created from ({expected}). Connect the right Jade \
                 and try again.",
                templar_core::ERR_DEVICE_NOT_FOUND
            ));
        }
    }

    let descriptor = jade.ct_descriptor().map_err(|e| e.to_string())?;
    // Round-trip through the CT validator so a descriptor the wallet would
    // later refuse can never reach the registry.
    let descriptor =
        templar_core::validate_ct_descriptor(&descriptor).map_err(|e| e.to_string())?;
    Ok((descriptor, fingerprint))
}

/// Read a Jade's BIP87 key (`[fp/87'/1'/0']tpub…`) for enrolling it in a
/// Liquid multisig.
///
/// The Liquid counterpart of [`get_hw_cosigner_xpub`], and Jade-only by
/// necessity: no other USB signer can produce an Elements signature, so no
/// other device has a Liquid key worth collecting.
///
/// `expect_fingerprint` guards the same mistake the descriptor read guards —
/// with two Jades on the desk, the wizard must enrol the Bitcoin and Liquid
/// keys of *one* device, not one key from each.
#[cfg(feature = "hardware")]
pub fn get_jade_liquid_cosigner_xpub(
    network: &templar_core::LiquidNetwork,
    expect_fingerprint: Option<&str>,
) -> Result<String, String> {
    let jade = templar_core::JadeLiquidSigner::connect_on(network).map_err(|e| e.to_string())?;
    let fingerprint = jade.fingerprint().map_err(|e| e.to_string())?;
    if let Some(expected) = expect_fingerprint {
        if !fingerprint.eq_ignore_ascii_case(expected.trim()) {
            return Err(format!(
                "{}: The connected Jade ({fingerprint}) is not the device that \
                 gave the Bitcoin key ({expected}). Connect the right Jade and \
                 try again.",
                templar_core::ERR_DEVICE_NOT_FOUND
            ));
        }
    }
    jade.keyorigin_xpub_bip87().map_err(|e| e.to_string())
}

/// Serial ports that might carry a Jade — used by the UI to say "plug it in"
/// versus "found it" without opening the device.
#[cfg(feature = "hardware")]
pub fn jade_ports() -> Vec<String> {
    templar_core::JadeLiquidSigner::available_ports()
}

/// Create a **Liquid-only** wallet from a connected Jade.
///
/// The fallback for when [`import_hw_wallet`] cannot read the Bitcoin side —
/// it needs nothing but the serial port, so it works where the full pairing
/// does not. Also the honest shape for someone who wants Liquid on their Jade
/// and keeps Bitcoin elsewhere.
///
/// The resulting entry has no Bitcoin side: its descriptor slot holds a CT
/// descriptor, `WalletEntry::has_bitcoin` reports false, and the UI hides every
/// Bitcoin surface rather than offering a receive address that cannot exist.
#[cfg(feature = "hardware")]
pub fn import_jade_liquid_wallet(
    state: &mut AppFfiState,
    name: &str,
) -> Result<WalletSummaryDto, String> {
    // See import_hw_wallet: no registry writes while the vault is locked.
    crate::handlers::vault::ensure_unlocked(state)?;
    if name.trim().is_empty() {
        return Err("Wallet name is required".to_string());
    }

    let (descriptor, fingerprint) = jade_liquid_descriptor(&state.liquid_network, None)?;

    let profile = WalletProfile::HardwareWallet {
        device_fingerprint: fingerprint.clone(),
        device_model: "jade".to_string(),
        receive_descriptor: descriptor,
        change_descriptor: String::new(), // LWK multipath covers both chains
    };
    let entry =
        WalletEntry::new(name.trim().to_string(), String::new(), profile).with_liquid_enabled(true);
    let summary = WalletSummaryDto {
        network: "liquid_testnet".to_string(),
        ..summary_of(&entry)
    };
    state.registry.add(entry);
    state.save_registry()?;

    Ok(summary)
}

fn unix_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

#[cfg(test)]
mod tests {
    use super::*;

    const BTC_MULTIPATH: &str = "wpkh([f0b68896/84'/1'/0']tpubDCVwWj4hEpeWNFcWe3Eo1DrkLnPC4c2iitjw5wAuTkSZgofJbRMD4KESh1uhsqLCCjcjR36JooEFwfWf1ezwmAfjcPCxc7KNtnfBCrMPdtT/<0;1>/*)";
    const CT_DESC: &str = "ct(slip77(addfe14f6d96eb091712439190737b901b6b5558d7039ed1d0dd19a7305cb747),elwpkh([f0b68896/84'/1'/0']tpubDCVwWj4hEpeWNFcWe3Eo1DrkLnPC4c2iitjw5wAuTkSZgofJbRMD4KESh1uhsqLCCjcjR36JooEFwfWf1ezwmAfjcPCxc7KNtnfBCrMPdtT/<0;1>/*))#83yagts9";

    /// A state on its own data directory.
    ///
    /// Per-test rather than per-process, and via `new_for_test` rather than the
    /// `TEMPLAR_DATA_DIR` env override: both are process-global, so tests running
    /// in parallel used to share one directory — and one of them wiping it
    /// between another's create and save surfaced as an unrelated
    /// "No such file or directory".
    fn test_state(tag: &str) -> AppFfiState {
        let dir = std::env::temp_dir().join(format!("wallet_ffi_hw_{tag}_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        AppFfiState::new_for_test(dir)
    }

    /// Every refusal `add_liquid_to_wallet` makes before it ever touches a
    /// device. Each one is a wallet that would otherwise be able to receive
    /// Liquid funds nothing could ever spend.
    #[cfg(feature = "hardware")]
    #[test]
    fn adding_liquid_is_refused_where_no_device_could_provide_it() {
        let mut st = test_state("add_liquid_refused");

        // Air-gap: Jade's QR mode exports no blinding key, so there is nothing
        // to read even with the device in hand.
        let air = create_watch_only_wallet(&mut st, "AirGap", BTC_MULTIPATH, "", "", true)
            .expect("air-gap creation");
        let err = add_liquid_to_wallet(&mut st, &air.id).unwrap_err();
        assert!(err.starts_with("LIQUID_HW_UNSUPPORTED: "), "got: {err}");
        assert!(
            err.contains("USB"),
            "must point at the route that works: {err}"
        );

        // A wallet that already has Liquid: silently re-reading the descriptor
        // would replace a working one with whichever device is attached now.
        let both = create_watch_only_wallet(&mut st, "Both", BTC_MULTIPATH, "", CT_DESC, false)
            .expect("watch-only creation");
        let err = add_liquid_to_wallet(&mut st, &both.id).unwrap_err();
        assert!(err.contains("already has a Liquid side"), "got: {err}");

        // A device family with no Liquid in firmware.
        let ledger = WalletEntry::new(
            "Ledger".to_string(),
            String::new(),
            WalletProfile::HardwareWallet {
                device_fingerprint: "77dfbe4f".to_string(),
                device_model: "Nano S".to_string(),
                receive_descriptor: BTC_MULTIPATH.to_string(),
                change_descriptor: String::new(),
            },
        );
        let ledger_id = ledger.id.clone();
        st.registry.add(ledger);
        let err = add_liquid_to_wallet(&mut st, &ledger_id).unwrap_err();
        assert!(err.starts_with("LIQUID_HW_UNSUPPORTED: "), "got: {err}");

        let missing = add_liquid_to_wallet(&mut st, "nope").unwrap_err();
        assert!(missing.contains("Wallet not found"), "got: {missing}");
    }

    /// The summary a screen renders has to agree with what was persisted: this
    /// is the flag that decides whether a Bitcoin receive tab is offered.
    #[test]
    fn summaries_report_the_chains_the_entry_actually_has() {
        let mut st = test_state("summaries");

        let both = create_watch_only_wallet(&mut st, "Both", BTC_MULTIPATH, "", CT_DESC, false)
            .expect("watch-only creation");
        assert!(both.bitcoin_enabled);
        assert!(both.liquid_enabled);
        // Identity comes off the descriptor, with no wallet database opened.
        assert_eq!(both.master_fingerprint.as_deref(), Some("f0b68896"));

        let btc_only = create_watch_only_wallet(&mut st, "BtcOnly", BTC_MULTIPATH, "", "", false)
            .expect("watch-only creation");
        assert!(btc_only.bitcoin_enabled);
        assert!(!btc_only.liquid_enabled);

        // A Liquid-only entry, the shape the Jade Liquid dialog produces.
        let entry = WalletEntry::new(
            "JadeLiquid".to_string(),
            String::new(),
            WalletProfile::HardwareWallet {
                device_fingerprint: "09026b48".to_string(),
                device_model: "jade".to_string(),
                receive_descriptor: CT_DESC.to_string(),
                change_descriptor: String::new(),
            },
        )
        .with_liquid_enabled(true);
        let summary = summary_of(&entry);
        assert!(
            !summary.bitcoin_enabled,
            "a ct() profile has no Bitcoin side to show"
        );
        assert!(summary.liquid_enabled);
        assert_eq!(summary.master_fingerprint, None, "no Bitcoin key to report");
    }

    #[test]
    fn create_watch_only_btc_and_liquid_succeeds() {
        let mut st = test_state("btc_and_liquid");
        let r = create_watch_only_wallet(&mut st, "WoTest", BTC_MULTIPATH, "", CT_DESC, false);
        let summary = r.expect("creation should succeed");
        assert!(summary.liquid_enabled);
        let entry = st.registry.find(&summary.id).unwrap().clone();
        match &entry.profile {
            WalletProfile::HardwareWallet {
                receive_descriptor,
                change_descriptor,
                ..
            } => {
                assert!(
                    receive_descriptor.contains("/0/*"),
                    "recv: {receive_descriptor}"
                );
                assert!(
                    change_descriptor.contains("/1/*"),
                    "change: {change_descriptor}"
                );
            }
            other => panic!("unexpected profile: {other:?}"),
        }
        assert_eq!(entry.liquid.as_ref().unwrap().descriptor, CT_DESC);
    }

    /// Jade's QR mode is Bitcoin-only, so an air-gap wallet must never be
    /// paired with a Liquid descriptor — it could only be an ELIP151 one the
    /// device cannot spend from.
    #[test]
    fn create_watch_only_rejects_liquid_on_airgap() {
        let mut st = test_state("airgap_liquid");
        let before = st.registry.len();
        let r = create_watch_only_wallet(&mut st, "AirLiquid", BTC_MULTIPATH, "", CT_DESC, true);
        let err = r.unwrap_err();
        assert!(err.starts_with("LIQUID_HW_UNSUPPORTED: "), "got: {err}");
        assert_eq!(
            st.registry.len(),
            before,
            "nothing must be persisted on failure"
        );
    }

    #[test]
    fn create_watch_only_rejects_truncated_liquid() {
        let mut st = test_state("truncated_liquid");
        let truncated = &CT_DESC[62..];
        let before = st.registry.len();
        let r = create_watch_only_wallet(&mut st, "WoBad", BTC_MULTIPATH, "", truncated, false);
        let err = r.unwrap_err();
        assert!(err.contains("cut off"), "got: {err}");
        assert_eq!(
            st.registry.len(),
            before,
            "nothing must be persisted on failure"
        );
    }

    /// End-to-end derive: bare xpub → wrapped wpkh → ct(elip151,elwpkh(…)),
    /// round-tripped through the LWK parser. Regression: `wpkh` inside ct()
    /// is rejected by LWK ("Not an elements descriptor") — it must be elwpkh.
    #[test]
    fn derive_liquid_descriptor_parses_in_lwk() {
        let bare = "tpubDCVwWj4hEpeWNFcWe3Eo1DrkLnPC4c2iitjw5wAuTkSZgofJbRMD4KESh1uhsqLCCjcjR36JooEFwfWf1ezwmAfjcPCxc7KNtnfBCrMPdtT";
        let ct = derive_liquid_descriptor(bare).expect("derive should succeed");
        assert!(ct.starts_with("ct(elip151,elwpkh("), "got: {ct}");
        assert!(ct.contains("/<0;1>/*"), "got: {ct}");

        let from_desc = derive_liquid_descriptor(BTC_MULTIPATH).expect("descriptor input");
        assert!(
            from_desc.starts_with("ct(elip151,elwpkh("),
            "got: {from_desc}"
        );
    }
}
