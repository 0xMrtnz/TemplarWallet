//! Blockstream Jade — Liquid support over USB serial.
//!
//! Jade is the only hardware wallet with Liquid in firmware. Every other USB
//! signer (Ledger, Trezor, Coldcard, KeepKey) is Bitcoin-only and always will
//! be: an Elements signature hash commits to 33-byte value and asset
//! *commitments* where Bitcoin's BIP143 commits to an 8-byte amount, so a
//! Bitcoin signer cannot produce the preimage even in principle. There is no
//! derivation trick around that, which is why this module is Jade-only and
//! why the wizard refuses to pair a Liquid wallet with anything else.
//!
//! # The blinding key is the part that must be right
//!
//! A Liquid wallet is `ct(<blinding key>, elwpkh(<signing key>))`. Both halves
//! must match the device. Jade derives its blinding key as SLIP-0077 from its
//! seed, so the descriptor must carry `slip77(<key read from the device>)`.
//!
//! An ELIP151 blinding key — derived from the descriptor, no device needed —
//! produces a wallet that looks perfect right up until you try to spend: the
//! app can derive addresses and unblind incoming funds because it owns that
//! key, but Jade cannot recognise the outputs as its own and will not sign.
//! Funds would land in a wallet the device cannot empty. ELIP151 is fine for
//! watch-only wallets that no device will ever sign; it is wrong here, and
//! [`ct_descriptor`](JadeLiquidSigner::ct_descriptor) reads the real key off
//! the device instead.
//!
//! # Transport
//!
//! In-process serial via `lwk_jade`, Blockstream's own implementation of the
//! Jade CBOR protocol. No subprocess, so this works under the macOS App
//! Sandbox where the HWI-based Bitcoin path cannot run at all.

#[cfg(feature = "hardware")]
use std::time::Duration;

#[cfg(feature = "hardware")]
use lwk_common::{singlesig_desc, Bip, DescriptorBlindingKey, Signer, Singlesig};
#[cfg(feature = "hardware")]
use lwk_jade::register_multisig::{JadeDescriptor, RegisterMultisigParams};
#[cfg(feature = "hardware")]
use lwk_jade::{Jade, Network as JadeNetwork};
#[cfg(feature = "hardware")]
use lwk_wollet::elements::pset::PartiallySignedTransaction;
#[cfg(feature = "hardware")]
use lwk_wollet::elements_miniscript::{ConfidentialDescriptor, DescriptorPublicKey};

#[cfg(feature = "hardware")]
use crate::bitcoin::hardware::{ERR_DEVICE_NOT_FOUND, ERR_DEVICE_NOT_READY, ERR_SIGNING};
#[cfg(feature = "hardware")]
use crate::error::{LiquidError, TemplarError};

#[cfg(feature = "hardware")]
use crate::liquid::network::LiquidNetwork;

/// Jade waits for the user to approve on screen, so the timeout has to cover
/// a human reading a transaction — not a wire round trip.
#[cfg(feature = "hardware")]
const IO_TIMEOUT: Duration = Duration::from_secs(90);

#[cfg(feature = "hardware")]
fn tagged(kind: &str, msg: impl std::fmt::Display) -> TemplarError {
    LiquidError::SigningFailed(format!("{kind}: {msg}")).into()
}

/// A connected, unlocked Jade, ready to answer for Liquid.
#[cfg(feature = "hardware")]
pub struct JadeLiquidSigner {
    jade: Jade,
    port: String,
    /// Test networks only (`TestnetLiquid` / `LocaltestLiquid`), matching
    /// the rest of the app. Sending mainnet here would make Jade derive
    /// mainnet keys and sign mainnet transactions.
    network: JadeNetwork,
}

#[cfg(feature = "hardware")]
impl JadeLiquidSigner {
    /// Serial ports that could carry a Jade.
    ///
    /// Deliberately delegated to `lwk_jade`: its id list includes the generic
    /// USB-serial bridges used by DIY Jade builds, which a stricter list would
    /// exclude. A match here means "worth probing", not "is a Jade" — the
    /// difference is settled by [`connect_port`](Self::connect_port), which
    /// actually talks to it.
    pub fn available_ports() -> Vec<String> {
        Jade::available_ports_with_jade()
            .into_iter()
            .map(|p| p.port_name)
            .collect()
    }

    /// Connect to the first Jade found and unlock it, on the network the
    /// environment selects (`TEMPLAR_LIQUID_NETWORK`, default testnet).
    pub fn connect() -> Result<Self, TemplarError> {
        Self::connect_on(&LiquidNetwork::from_env())
    }

    /// Connect to the first Jade found and unlock it for `network`.
    pub fn connect_on(network: &LiquidNetwork) -> Result<Self, TemplarError> {
        let ports = Self::available_ports();
        if ports.is_empty() {
            return Err(tagged(
                ERR_DEVICE_NOT_FOUND,
                "No Jade found. Connect it over USB, unlock it with your PIN, \
                 and close Blockstream Green — only one app can hold the \
                 serial port.",
            ));
        }
        // Report the last failure rather than a generic one: with several
        // serial devices attached, which port failed and why is the whole
        // diagnostic.
        let mut last_err = None;
        for port in &ports {
            match Self::connect_port_on(network, port) {
                Ok(signer) => return Ok(signer),
                Err(e) => last_err = Some(e),
            }
        }
        Err(last_err.unwrap_or_else(|| tagged(ERR_DEVICE_NOT_FOUND, "No Jade responded")))
    }

    /// Connect to a specific serial port and unlock the device on it, on the
    /// network the environment selects.
    pub fn connect_port(port: &str) -> Result<Self, TemplarError> {
        Self::connect_port_on(&LiquidNetwork::from_env(), port)
    }

    /// Connect to a specific serial port and unlock the device on it for
    /// `network`.
    pub fn connect_port_on(network: &LiquidNetwork, port: &str) -> Result<Self, TemplarError> {
        let network = network.jade_network();
        let jade = Jade::from_serial(network, port, Some(IO_TIMEOUT))
            .map_err(|e| tagged(ERR_DEVICE_NOT_READY, format!("{port}: {e}")))?;

        // Unlock drives the PIN entry on the device and relays the blind
        // pinserver exchange over the network, so it needs both the user and
        // an internet connection. Everything below would otherwise fail with
        // a much less obvious error.
        jade.unlock().map_err(|e| {
            tagged(
                ERR_DEVICE_NOT_READY,
                format!(
                    "Could not unlock the Jade on {port}: {e}. Enter your PIN on \
                     the device; unlocking also needs an internet connection."
                ),
            )
        })?;

        Ok(Self {
            jade,
            port: port.to_string(),
            network,
        })
    }

    /// The serial port this signer is bound to.
    pub fn port(&self) -> &str {
        &self.port
    }

    /// Master key fingerprint, lower-case hex — the same identifier the
    /// Bitcoin side uses to bind a wallet to a device.
    pub fn fingerprint(&self) -> Result<String, TemplarError> {
        self.jade
            .fingerprint()
            .map(|f| f.to_string().to_lowercase())
            .map_err(|e| tagged(ERR_DEVICE_NOT_READY, e))
    }

    /// The wallet's confidential descriptor:
    /// `ct(slip77(<device key>),elwpkh([fp/84h/1h/0h]xpub/<0;1>/*))#checksum`.
    ///
    /// Both halves come from the device, which is the point — see the module
    /// docs on why an ELIP151 blinding key here would create a wallet Jade
    /// cannot spend from.
    pub fn ct_descriptor(&self) -> Result<String, TemplarError> {
        singlesig_desc(
            &self.jade,
            Singlesig::Wpkh,
            DescriptorBlindingKey::Slip77,
            // Testnet: coin type 1. `true` here would build an m/84h/1776h/0h
            // mainnet descriptor.
            false,
        )
        .map_err(|e| tagged(ERR_DEVICE_NOT_READY, format!("descriptor from device: {e}")))
    }

    /// Ask the device to sign a PSET. Returns the number of signatures added.
    ///
    /// Zero is an error, not a quiet no-op: it means the user declined on
    /// screen, or the wallet does not belong to this device. Letting it
    /// through surfaces later as an opaque finalize failure that reads like a
    /// network fault.
    pub fn sign_pset(&self, pset: &mut PartiallySignedTransaction) -> Result<u32, TemplarError> {
        let added = Signer::sign(&self.jade, pset)
            .map_err(|e| tagged(ERR_SIGNING, format!("Jade refused to sign: {e}")))?;
        if added == 0 {
            return Err(tagged(
                ERR_SIGNING,
                "The Jade did not add any signature. Approve the transaction on \
                 the device, and check this wallet belongs to it.",
            ));
        }
        Ok(added)
    }

    /// The device's BIP87 cosigner key: `[fp/87h/1h/0h]tpub…`.
    ///
    /// This is the Liquid half of a multisig enrolment. The Bitcoin half comes
    /// from BIP48 (`m/48'/1'/0'/2'`) and is read by the Bitcoin driver — two
    /// accounts, one seed, so nothing on the Liquid side can be derived from
    /// the Bitcoin xpub and both must be read from the device.
    pub fn keyorigin_xpub_bip87(&self) -> Result<String, TemplarError> {
        Signer::keyorigin_xpub(&self.jade, Bip::Bip87, false)
            .map_err(|e| tagged(ERR_DEVICE_NOT_READY, format!("BIP87 xpub from device: {e}")))
    }

    /// Teach the device a multisig wallet, so it will sign for it.
    ///
    /// Jade refuses to sign an input it cannot attribute to a wallet it knows:
    /// without this call every multisig signature request comes back as a
    /// refusal. Registration is stored on the device under `name` (16 chars
    /// max — build it with
    /// [`LiquidMultisigSetup::jade_multisig_name`](crate::LiquidMultisigSetup::jade_multisig_name))
    /// and needs on-screen confirmation once per device.
    ///
    /// The blinding key travels inside the registration, which is why a
    /// coordinator-generated random SLIP77 key is correct here — the opposite
    /// of the singlesig rule in the module docs, where the key must be read
    /// *from* the device. ELIP151 is still refused: the registration format
    /// carries 32 raw SLIP77 bytes and has nowhere to put a descriptor-derived
    /// key.
    ///
    /// Re-registering the same name and descriptor is harmless, so callers can
    /// simply do it before every signature rather than tracking device state.
    pub fn register_multisig(&self, name: &str, ct_descriptor: &str) -> Result<(), TemplarError> {
        let conf_desc: ConfidentialDescriptor<DescriptorPublicKey> = ct_descriptor
            .parse()
            .map_err(|e| LiquidError::InvalidDescriptor(format!("Not a CT descriptor: {e}")))?;
        let descriptor = JadeDescriptor::try_from(&conf_desc).map_err(|e| {
            LiquidError::InvalidDescriptor(format!(
                "Jade cannot represent this wallet: {e}. It registers \
                 ct(slip77(...),elwsh(multi(k,...))) only — no ELIP151 blinding \
                 key and no Miniscript policy."
            ))
        })?;
        let registered = self
            .jade
            .register_multisig(RegisterMultisigParams {
                network: self.network,
                multisig_name: name.to_string(),
                descriptor,
            })
            .map_err(|e| tagged(ERR_DEVICE_NOT_READY, format!("register multisig: {e}")))?;
        if !registered {
            return Err(tagged(
                ERR_DEVICE_NOT_READY,
                "The Jade declined the wallet registration. Confirm it on the \
                 device screen, then try again.",
            ));
        }
        Ok(())
    }

    /// Register the wallet if needed, then sign. The registration is what
    /// makes a multisig signature possible at all, so the two belong together
    /// — a caller that forgets the first step gets an opaque refusal.
    pub fn sign_multisig_pset(
        &self,
        name: &str,
        ct_descriptor: &str,
        pset: &mut PartiallySignedTransaction,
    ) -> Result<u32, TemplarError> {
        self.register_multisig(name, ct_descriptor)?;
        self.sign_pset(pset)
    }

    /// SLIP-0077 master blinding key, hex. Exposed for diagnostics and for
    /// rebuilding a descriptor by hand; normal callers want
    /// [`ct_descriptor`](Self::ct_descriptor).
    pub fn master_blinding_key(&self) -> Result<String, TemplarError> {
        self.jade
            .slip77_master_blinding_key()
            .map(|k| k.to_string())
            .map_err(|e| tagged(ERR_DEVICE_NOT_READY, e))
    }
}

/// Whether this build can sign Liquid transactions on a hardware device.
/// True wherever the `hardware` feature is on (Jade only; see
/// [`liquid_hw_unsupported_reason`]), false on Android, which ships without
/// the USB stack.
pub const LIQUID_HW_SIGNING_SUPPORTED: bool = cfg!(feature = "hardware");

/// Stable prefix for the blocked-spend error, matching the tagging scheme in
/// `bitcoin::hardware` so the UI classifies every hardware error the same way.
pub const ERR_LIQUID_HW_UNSUPPORTED: &str = "LIQUID_HW_UNSUPPORTED";

/// Shown when a Liquid spend is attempted on a device that cannot do it.
pub fn liquid_hw_unsupported_reason() -> &'static str {
    "Liquid is only supported on a Blockstream Jade. Ledger, Trezor, Coldcard \
     and KeepKey are Bitcoin-only devices — their firmware cannot produce an \
     Elements signature, so a Liquid wallet paired with one could receive \
     funds it could never spend."
}

/// True when a device model string identifies a Jade.
///
/// The single place that decides whether Liquid is on the table for a device,
/// so the wizard, the import path and the send flow cannot disagree. HWI
/// reports Jade as `jade`; the native enumerator uses the USB product string,
/// which is typically "Jade" or "Blockstream Jade".
pub fn is_jade_model(model: &str) -> bool {
    model.to_lowercase().contains("jade")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn jade_models_are_recognised_case_insensitively() {
        assert!(is_jade_model("jade"));
        assert!(is_jade_model("Jade"));
        assert!(is_jade_model("Blockstream Jade"));
        assert!(is_jade_model("JADE v1.1"));
    }

    /// Everything that is not a Jade must be Bitcoin-only. A false positive
    /// here would offer Liquid on a device that can never sign it.
    #[test]
    fn other_devices_are_never_treated_as_jade() {
        for model in [
            "ledger_nano_s",
            "Ledger Nano X",
            "trezor_1",
            "Trezor Model T",
            "coldcard",
            "keepkey",
            "bitbox02",
            "",
        ] {
            assert!(!is_jade_model(model), "{model}");
        }
    }

    /// Enumerating ports must be safe with nothing attached — it runs behind
    /// a UI button and on the wizard's device step.
    #[cfg(feature = "hardware")]
    #[test]
    fn listing_ports_is_safe_with_no_device() {
        let _ = JadeLiquidSigner::available_ports();
    }

    /// Connecting with no Jade attached must fail with the tagged
    /// device-not-found error the UI knows how to explain, not a panic or a
    /// raw serial error.
    #[cfg(feature = "hardware")]
    #[test]
    fn connect_without_a_device_is_a_clean_tagged_error() {
        if !JadeLiquidSigner::available_ports().is_empty() {
            // A developer machine with a serial adapter plugged in; the error
            // path under test is the empty-port one.
            return;
        }
        let err = match JadeLiquidSigner::connect() {
            Ok(_) => panic!("connected with no device attached"),
            Err(e) => e.to_string(),
        };
        assert!(err.contains(ERR_DEVICE_NOT_FOUND), "got: {err}");
        assert!(err.contains("No Jade found"), "got: {err}");
    }
}
