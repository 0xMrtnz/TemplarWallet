//! Ledger Bitcoin app, driven in-process over USB HID.
//!
//! Replaces the `hwi ...` subprocess for Ledger devices on every platform.
//! On macOS it is the only thing that can work at all (the App Sandbox refuses
//! to exec HWI); on Windows and Linux it removes the HWI install step and a
//! process spawn per call.
//!
//! # Wallet policies
//!
//! The Bitcoin app since 2.x signs only for a *wallet policy* it has seen.
//! Single-sig `wpkh` is a "default" policy: it needs no registration and no
//! HMAC. Anything else — our `wsh(sortedmulti(...))` multisig — must be
//! registered first, which makes the device display the policy and ask the
//! user to approve it, and yields an HMAC that authorises later signing.
//!
//! We register on demand rather than persisting the HMAC. That costs one extra
//! device confirmation per signing session, and buys a registry that stores no
//! per-device authorisation blobs — nothing to migrate, nothing to invalidate
//! when a device is restored from its seed onto new hardware.

use std::str::FromStr;

use bitcoin_032::bip32::{DerivationPath, Fingerprint, Xpub};
use bitcoin_032::psbt::Psbt;
use ledger_bitcoin_client::wallet::{AddressType, Version};
use ledger_bitcoin_client::{BitcoinClient, PartialSignature, SignPsbtYieldedObject, WalletPolicy};

use super::hid::{LedgerHidTransport, LedgerTransport};
use super::{descriptor, DeviceError};

/// BIP84 account used for single-sig testnet wallets: `m/84'/1'/0'`.
const ACCOUNT_PATH: &str = "m/84h/1h/0h";

/// BIP48 script-type-2 (P2WSH) account used for multisig: `m/48'/1'/0'/2'`.
const MULTISIG_PATH: &str = "m/48h/1h/0h/2h";

pub struct Ledger {
    client: BitcoinClient<LedgerTransport>,
}

impl Ledger {
    /// Open the Ledger at an enumerated HID path.
    pub fn open(path: &str) -> Result<Self, DeviceError> {
        let transport = LedgerHidTransport::open(path).map_err(|e| DeviceError::NotReady {
            device: "Ledger".into(),
            detail: e.to_string(),
        })?;
        Ok(Self {
            client: BitcoinClient::new(LedgerTransport(transport)),
        })
    }

    /// Master key fingerprint — the wallet's identity across sessions.
    pub fn fingerprint(&self) -> Result<Fingerprint, DeviceError> {
        self.client
            .get_master_fingerprint()
            .map_err(|e| self.err(e))
    }

    /// Extended public key at `path`, without asking the user to confirm it.
    fn xpub(&self, path: &str) -> Result<Xpub, DeviceError> {
        let path = DerivationPath::from_str(path).map_err(|e| DeviceError::Protocol {
            device: "Ledger".into(),
            detail: format!("bad derivation path {path}: {e}"),
        })?;
        self.client
            .get_extended_pubkey(&path, false)
            .map_err(|e| self.err(e))
    }

    /// `(receive, change)` descriptors for the single-sig BIP84 account, in the
    /// same `wpkh([fp/84'/1'/0']tpub.../0/*)` form HWI's `getdescriptors`
    /// produced — so everything downstream (BDK, the Liquid derivation, the
    /// registry) is unaffected by which transport fetched them.
    pub fn wpkh_descriptors(&self) -> Result<(String, String), DeviceError> {
        let fp = self.fingerprint()?;
        let xpub = self.xpub(ACCOUNT_PATH)?;
        Ok(descriptor::wpkh_pair(&fp.to_string(), &xpub.to_string()))
    }

    /// BIP48 cosigner key in `[fingerprint/48'/1'/0'/2']tpub…` keyorigin form.
    pub fn cosigner_xpub(&self) -> Result<String, DeviceError> {
        let fp = self.fingerprint()?;
        let xpub = self.xpub(MULTISIG_PATH)?;
        Ok(format!(
            "[{}/48'/1'/0'/2']{}",
            fp.to_string().to_lowercase(),
            xpub
        ))
    }

    /// Show an address on the device screen so the user can compare it with
    /// the one on this computer.
    ///
    /// `descriptor` is the wallet's receive descriptor; `index` the address to
    /// display. The device re-derives the address itself, which is the whole
    /// point — an address this computer merely *claims* is yours proves
    /// nothing about the key that will be asked to spend it.
    pub fn display_address(&self, desc: &str, index: u32) -> Result<String, DeviceError> {
        let policy = self.policy_for(desc)?;
        let hmac = self.register_if_needed(&policy)?;
        let address = self
            .client
            .get_wallet_address(&policy, hmac.as_ref(), false, index, true)
            .map_err(|e| self.err(e))?;
        Ok(address.assume_checked().to_string())
    }

    /// Sign every input this device holds a key for, returning the updated
    /// PSBT in base64.
    ///
    /// `desc` is the wallet's receive descriptor, needed to build the policy
    /// the device signs under.
    pub fn sign_psbt(&self, desc: &str, psbt_b64: &str) -> Result<String, DeviceError> {
        let mut psbt = Psbt::from_str(psbt_b64).map_err(|e| DeviceError::Protocol {
            device: "Ledger".into(),
            detail: format!("PSBT does not parse: {e}"),
        })?;

        let policy = self.policy_for(desc)?;
        let hmac = self.register_if_needed(&policy)?;

        let signatures = self
            .client
            .sign_psbt(&psbt, &policy, hmac.as_ref())
            .map_err(|e| self.err(e))?;

        let mut added = 0usize;
        for (index, yielded) in signatures {
            let input = psbt
                .inputs
                .get_mut(index)
                .ok_or_else(|| DeviceError::Protocol {
                    device: "Ledger".into(),
                    detail: format!("device signed input {index}, which is not in the PSBT"),
                })?;
            match yielded {
                SignPsbtYieldedObject::Partial(PartialSignature::Sig(key, sig)) => {
                    input.partial_sigs.insert(key, sig);
                    added += 1;
                }
                SignPsbtYieldedObject::Partial(PartialSignature::TapScriptSig(..)) => {
                    // Only reachable with a tr() descriptor, which this wallet
                    // cannot build on BDK 0.30. Refusing beats dropping the
                    // signature and reporting success.
                    return Err(DeviceError::Unsupported {
                        device: "Ledger".into(),
                        detail: "Taproot script-path signing is not supported yet".into(),
                    });
                }
                // MuSig2 rounds, and anything a future app version adds. Both
                // mean the device answered something this build cannot put
                // into a PSBT — which must fail loudly, because the
                // alternative is reporting a signed transaction that isn't.
                other => {
                    return Err(DeviceError::Unsupported {
                        device: "Ledger".into(),
                        detail: format!(
                            "device returned a signature payload this wallet does not \
                             understand ({other:?})"
                        ),
                    });
                }
            }
        }

        if added == 0 {
            return Err(DeviceError::NoSignature {
                device: "Ledger".into(),
            });
        }
        Ok(psbt.to_string())
    }

    // ── Policies ─────────────────────────────────────────────────────────────

    /// Turn one of our descriptors into the policy the device signs under.
    fn policy_for(&self, desc: &str) -> Result<WalletPolicy, DeviceError> {
        policy_from_descriptor(desc)
    }

    /// Register a non-default policy, returning the HMAC that authorises it.
    /// Default (single-sig) policies need neither.
    fn register_if_needed(&self, policy: &WalletPolicy) -> Result<Option<[u8; 32]>, DeviceError> {
        if policy.threshold.is_none() {
            return Ok(None);
        }
        let (_id, hmac) = self
            .client
            .register_wallet(policy)
            .map_err(|e| self.err(e))?;
        Ok(Some(hmac))
    }

    // ── Errors ───────────────────────────────────────────────────────────────

    /// Map the client's error onto something a user can act on.
    ///
    /// The two that matter are told apart because their fixes are opposite: a
    /// declined transaction means "you pressed reject", while a bad state
    /// almost always means the Bitcoin app isn't open.
    fn err(
        &self,
        e: ledger_bitcoin_client::error::BitcoinClientError<
            <LedgerTransport as ledger_bitcoin_client::Transport>::Error,
        >,
    ) -> DeviceError {
        use ledger_bitcoin_client::apdu::StatusWord;
        use ledger_bitcoin_client::error::BitcoinClientError as E;
        match e {
            E::Device {
                status: StatusWord::Deny,
                ..
            } => DeviceError::Declined {
                device: "Ledger".into(),
            },
            E::Device {
                status:
                    StatusWord::BadState | StatusWord::ClaNotSupported | StatusWord::InsNotSupported,
                ..
            } => DeviceError::NotReady {
                device: "Ledger".into(),
                detail: "unlock the Ledger and open the Bitcoin app, then try again".into(),
            },
            E::Transport(inner) => DeviceError::NotReady {
                device: "Ledger".into(),
                detail: inner.to_string(),
            },
            other => DeviceError::Protocol {
                device: "Ledger".into(),
                detail: format!("{other:?}"),
            },
        }
    }
}

/// Build the wallet policy a descriptor corresponds to.
///
/// Free-standing so it can be checked without a device: the template and the
/// key order are what the Ledger derives addresses from, and getting either
/// wrong produces a policy for a *different* wallet — one whose addresses the
/// user would then be asked to approve.
fn policy_from_descriptor(desc: &str) -> Result<WalletPolicy, DeviceError> {
    // Neither error below echoes the descriptor or the key: a caller that
    // slipped a signing descriptor through would otherwise print its private
    // key on screen. The fingerprint is enough to tell keys apart.
    let parsed = descriptor::parse(desc).ok_or_else(|| DeviceError::Unsupported {
        device: "Ledger".into(),
        detail: "descriptor not recognised (only wpkh and wsh(sortedmulti) wallets)".into(),
    })?;

    let keys = parsed
        .keys
        .iter()
        .map(|k| {
            ledger_bitcoin_client::WalletPubKey::from_str(&k.keyorigin).map_err(|_| {
                DeviceError::Protocol {
                    device: "Ledger".into(),
                    detail: format!(
                        "cannot read the cosigner key with fingerprint {}",
                        k.fingerprint
                    ),
                }
            })
        })
        .collect::<Result<Vec<_>, _>>()?;

    match parsed.threshold {
        // Single-sig wpkh is a default policy: no name, no registration.
        None => Ok(WalletPolicy::new(
            String::new(),
            Version::V2,
            "wpkh(@0/**)".to_string(),
            keys,
        )),
        // `new_multisig`, not `new`: only it records the threshold, and the
        // threshold is what marks a policy as needing registration. Built by
        // hand the policy looks like a default one, registration is skipped,
        // and the device rejects the signature request with no useful reason.
        Some(threshold) => {
            let count = keys.len();
            WalletPolicy::new_multisig(
                // The name is shown on the device when approving, and is part
                // of what the HMAC commits to. Deriving it from the policy
                // rather than the user's wallet label keeps it stable across
                // renames and across machines.
                format!("Templar {threshold}-of-{count}"),
                Version::V2,
                AddressType::NativeSegwit,
                threshold,
                keys,
                // sortedmulti: our descriptors sort keys per BIP67, and a
                // policy using plain `multi` would derive different addresses
                // from the same keys.
                true,
            )
            .map_err(|e| DeviceError::Unsupported {
                device: "Ledger".into(),
                detail: format!("policy not supported by the device: {e:?}"),
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A real testnet account key — `WalletPubKey::from_str` validates the
    /// base58 checksum, so a placeholder would fail for the wrong reason.
    const XPUB: &str = "tpubDC5FSnBiZDMmhiuCmWAYsLwgLYrrT9rAqvTySfuCCrgsWz8wxMXUS9Tb9iVMvcRbvFcAHGkMD5Kx8koh4GquNGNTfohfk7pgjhaPCdXpoba";
    const XPUB_B: &str = "tpubDC5FSnBiZDMmhjUhJtaxuPL8A7eyNLUPF22RvefL2ADLZcQQSXS2sP1UAusXoMk5691ousYqRHnNnNjq7YunQoUcSTrqfv5bJy7J3TAQLTw";
    const XPUB_C: &str = "tpubDC5FSnBiZDMmhk4BrH1NwRiZygT6HX6be7atQdRTqTjocEfrvhLbJcZMC7Fhg74YG2RTYUMKdWEoRzfyApyfTLamD821biLVtEeCtCb8ng3";

    #[test]
    fn singlesig_uses_the_default_policy_needing_no_registration() {
        let policy =
            policy_from_descriptor(&format!("wpkh([aabbccdd/84'/1'/0']{XPUB}/0/*)")).unwrap();
        assert_eq!(policy.descriptor_template, "wpkh(@0/**)");
        assert_eq!(policy.keys.len(), 1);
        // A default policy carries no name and no threshold; either would make
        // the device demand a registration it does not need.
        assert!(policy.name.is_empty());
        assert!(policy.threshold.is_none());
    }

    #[test]
    fn multisig_template_matches_the_descriptor_it_came_from() {
        let desc = format!(
            "wsh(sortedmulti(2,[aabbccdd/48'/1'/0'/2']{XPUB}/0/*,\
             [11223344/48'/1'/0'/2']{XPUB_B}/0/*,[55667788/48'/1'/0'/2']{XPUB_C}/0/*))"
        );
        let policy = policy_from_descriptor(&desc).unwrap();
        assert_eq!(
            policy.descriptor_template,
            "wsh(sortedmulti(2,@0/**,@1/**,@2/**))"
        );
        assert_eq!(policy.keys.len(), 3);
        assert_eq!(policy.threshold, Some(2));
        // Stable across wallet renames: the name is derived from the policy,
        // and the HMAC the device returns commits to it.
        assert_eq!(policy.name, "Templar 2-of-3");
    }

    /// A descriptor shape we do not build must not be turned into a plausible
    /// policy — the device would happily derive addresses for it.
    #[test]
    fn an_unknown_descriptor_is_refused() {
        assert!(matches!(
            policy_from_descriptor("tr([aabbccdd/86'/1'/0']tpubXYZ/0/*)"),
            Err(DeviceError::Unsupported { .. })
        ));
    }
}
