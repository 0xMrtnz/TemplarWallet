//! Blockstream Jade, Bitcoin side, over USB serial in-process.
//!
//! Jade already signs *Liquid* here through `lwk_jade`, on macOS included —
//! that path proved the transport works inside the App Sandbox where the HWI
//! subprocess cannot. This module reuses exactly that transport and adds the
//! Bitcoin half of Jade's CBOR dialect on top of it.
//!
//! # Why `generic()`
//!
//! `lwk_jade` models the Liquid requests as typed calls and stops there —
//! reasonably, since it is a Liquid library. It also exposes
//! [`lwk_jade::Jade::generic`], the raw `(method, CBOR params)` escape hatch
//! its own pinserver handshake is built on. Going through it means the
//! framing, request/response correlation, serial reconnect and PIN unlock all
//! stay Blockstream's code; only the four Bitcoin message bodies are ours.
//!
//! # Session network
//!
//! The device is unlocked as `testnet-liquid` and then asked for `testnet`
//! material. Jade pins a keychain to a network *family* (main vs test), not to
//! a single chain, so one unlocked session serves both — which is what makes a
//! Jade able to hold the Bitcoin and Liquid sides of the same wallet.
//!
//! # Signing sequence
//!
//! Jade's `sign_tx` is a conversation, and the order is part of the protocol:
//!
//! 1. `sign_tx` — the unsigned transaction, and how many inputs will follow.
//! 2. `tx_input` — **exactly once per input, in order**. Inputs this device
//!    cannot sign are still sent, without a derivation path, so the count and
//!    the ordering hold.
//! 3. `get_signature` — once per input we did send a path for, in the same
//!    order, each returning one DER signature.

use std::collections::BTreeMap;

use bitcoin_032::bip32::{DerivationPath, Fingerprint};
use bitcoin_032::consensus::encode::serialize;
use bitcoin_032::hashes::{sha256, Hash};
use bitcoin_032::psbt::Psbt;
use bitcoin_032::{ecdsa, PublicKey, ScriptBuf};
use serde_cbor::Value as Cbor;

use super::{descriptor, DeviceError};

/// Jade's name for Bitcoin testnet. Templar is testnet-only (see CLAUDE.md);
/// when mainnet lands this becomes a parameter, not a second code path.
const NETWORK: &str = "testnet";

/// SIGHASH_ALL — the only sighash this wallet builds.
const SIGHASH_ALL: u8 = 1;

/// BIP84 single-sig account, as child numbers: `m/84'/1'/0'`.
const ACCOUNT_PATH: [u32; 3] = [84 + HARDENED, 1 + HARDENED, HARDENED];

/// BIP48 P2WSH multisig account: `m/48'/1'/0'/2'`.
const MULTISIG_PATH: [u32; 4] = [48 + HARDENED, 1 + HARDENED, HARDENED, 2 + HARDENED];

const HARDENED: u32 = 0x8000_0000;

pub struct JadeBitcoin {
    jade: lwk_jade::Jade,
}

impl JadeBitcoin {
    /// Open and unlock the Jade on a serial port.
    ///
    /// Unlocking prompts for the PIN on the device and talks to Blockstream's
    /// blind PIN server, so it needs the network — the same requirement the
    /// Liquid path already has.
    pub fn open(port: &str) -> Result<Self, DeviceError> {
        let jade = lwk_jade::Jade::from_serial(lwk_jade::Network::TestnetLiquid, port, None)
            .map_err(|e| DeviceError::NotReady {
                device: "Jade".into(),
                detail: format!("serial port {port}: {e}"),
            })?;
        jade.unlock().map_err(|e| DeviceError::NotReady {
            device: "Jade".into(),
            detail: format!("could not unlock: {e}. Enter the PIN on the device."),
        })?;
        Ok(Self { jade })
    }

    fn call(&self, method: &str, params: Cbor) -> Result<Cbor, DeviceError> {
        self.jade
            .generic(method.to_string(), params)
            .map_err(|e| map_jade_error(method, e))
    }

    /// Master fingerprint, from the Bitcoin-side master xpub.
    pub fn fingerprint(&self) -> Result<Fingerprint, DeviceError> {
        let xpub = self.xpub(&[])?;
        Ok(xpub.fingerprint())
    }

    fn xpub(&self, path: &[u32]) -> Result<bitcoin_032::bip32::Xpub, DeviceError> {
        let params = cbor_map([
            ("network", Cbor::Text(NETWORK.into())),
            (
                "path",
                Cbor::Array(path.iter().map(|p| Cbor::Integer(*p as i128)).collect()),
            ),
        ]);
        let value = self.call("get_xpub", params)?;
        let Cbor::Text(text) = value else {
            return Err(DeviceError::Protocol {
                device: "Jade".into(),
                detail: "get_xpub did not return a string".into(),
            });
        };
        text.parse().map_err(|e| DeviceError::Protocol {
            device: "Jade".into(),
            detail: format!("get_xpub returned an unreadable key: {e}"),
        })
    }

    /// `(receive, change)` descriptors for the BIP84 single-sig account, in
    /// the same shape every other import path produces.
    pub fn wpkh_descriptors(&self) -> Result<(String, String), DeviceError> {
        let fp = self.fingerprint()?;
        let xpub = self.xpub(&ACCOUNT_PATH)?;
        Ok(descriptor::wpkh_pair(&fp.to_string(), &xpub.to_string()))
    }

    /// The Liquid confidential descriptor for the same seed:
    /// `ct(slip77(<device key>),elwpkh([fp/84h/1h/0h]xpub/<0;1>/*))`.
    ///
    /// Here rather than only in `liquid::hardware` because pairing a Jade wants
    /// both sides of the wallet, and this handle is already open and unlocked.
    /// Reading it through a second connection meant a second PIN prompt and two
    /// processes contending for one serial port — the Bitcoin half used to lose
    /// that race, which is what left a Jade wallet with a Liquid side and no
    /// Bitcoin one.
    ///
    /// The blinding key is read from the device (SLIP-0077), never derived:
    /// see the module docs in `liquid::hardware` for why an ELIP151 key here
    /// would build a wallet the Jade cannot spend from.
    pub fn ct_descriptor(&self) -> Result<String, DeviceError> {
        lwk_common::singlesig_desc(
            &self.jade,
            lwk_common::Singlesig::Wpkh,
            lwk_common::DescriptorBlindingKey::Slip77,
            // Testnet: coin type 1. `true` would build a mainnet descriptor.
            false,
        )
        .map_err(|detail| DeviceError::NotReady {
            device: "Jade".into(),
            detail: format!("Liquid descriptor from device: {detail}"),
        })
    }

    /// BIP48 cosigner key in `[fingerprint/48'/1'/0'/2']tpub…` form.
    pub fn cosigner_xpub(&self) -> Result<String, DeviceError> {
        let fp = self.fingerprint()?;
        let xpub = self.xpub(&MULTISIG_PATH)?;
        Ok(format!(
            "[{}/48'/1'/0'/2']{}",
            fp.to_string().to_lowercase(),
            xpub
        ))
    }

    /// Show a receive address on the device screen.
    pub fn display_address(&self, desc: &str, index: u32) -> Result<String, DeviceError> {
        let parsed = descriptor::parse(desc).ok_or_else(|| DeviceError::Unsupported {
            device: "Jade".into(),
            detail: format!("descriptor not recognised: {desc}"),
        })?;
        if parsed.threshold.is_some() {
            // Jade shows a multisig address only for a policy registered on
            // the device. Registration is a separate flow we don't run yet, so
            // say so rather than showing a single-sig address that belongs to
            // a different wallet entirely.
            return Err(DeviceError::Unsupported {
                device: "Jade".into(),
                detail: "showing a multisig address needs the wallet registered on the Jade first"
                    .into(),
            });
        }
        let mut path = ACCOUNT_PATH.to_vec();
        path.push(0);
        path.push(index);
        let params = cbor_map([
            ("network", Cbor::Text(NETWORK.into())),
            ("variant", Cbor::Text("wpkh(k)".into())),
            (
                "path",
                Cbor::Array(path.iter().map(|p| Cbor::Integer(*p as i128)).collect()),
            ),
        ]);
        match self.call("get_receive_address", params)? {
            Cbor::Text(address) => Ok(address),
            _ => Err(DeviceError::Protocol {
                device: "Jade".into(),
                detail: "get_receive_address did not return an address".into(),
            }),
        }
    }

    /// Sign every input this device holds a key for.
    pub fn sign_psbt(&self, psbt_b64: &str) -> Result<String, DeviceError> {
        let mut psbt: Psbt = psbt_b64.parse().map_err(|e| DeviceError::Protocol {
            device: "Jade".into(),
            detail: format!("PSBT does not parse: {e}"),
        })?;
        let fingerprint = self.fingerprint()?;

        // Work out, up front, which inputs we can sign and with which key —
        // the device expects one message per input and no backtracking.
        let plan = sign_plan(&psbt, fingerprint)?;
        if plan.iter().all(|s| s.is_none()) {
            return Err(DeviceError::NoSignature {
                device: "Jade".into(),
            });
        }

        let started = self.call(
            "sign_tx",
            cbor_map([
                ("network", Cbor::Text(NETWORK.into())),
                ("txn", Cbor::Bytes(serialize(&psbt.unsigned_tx))),
                ("num_inputs", Cbor::Integer(psbt.inputs.len() as i128)),
                ("use_ae_signatures", Cbor::Bool(true)),
            ]),
        )?;
        if started != Cbor::Bool(true) {
            return Err(DeviceError::Protocol {
                device: "Jade".into(),
                detail: "the device refused to start signing".into(),
            });
        }

        // Anti-exfil entropy: fresh per signing session, and its hash is
        // committed to before the device produces a nonce. We do not yet
        // verify the returned commitment (neither does lwk's Liquid path), so
        // this does not *prove* the nonce is honest — but random entropy costs
        // nothing and a constant would hand the device a predictable nonce.
        let mut entropy = [0u8; 32];
        getrandom::getrandom(&mut entropy).map_err(|e| DeviceError::Protocol {
            device: "Jade".into(),
            detail: format!("no system entropy: {e}"),
        })?;
        let commitment = sha256::Hash::hash(&entropy).to_byte_array().to_vec();

        // One `tx_input` per input, in order, signable or not.
        for step in &plan {
            let params = match step {
                Some(step) => cbor_map([
                    ("is_witness", Cbor::Bool(true)),
                    ("script", Cbor::Bytes(step.script_code.to_bytes())),
                    ("satoshi", Cbor::Integer(step.value as i128)),
                    (
                        "path",
                        Cbor::Array(
                            path_to_vec(&step.path)
                                .iter()
                                .map(|p| Cbor::Integer(*p as i128))
                                .collect(),
                        ),
                    ),
                    ("sighash", Cbor::Integer(SIGHASH_ALL as i128)),
                    ("ae_host_commitment", Cbor::Bytes(commitment.clone())),
                ]),
                // No path: "this input is not mine". The message is still
                // required — Jade counts them against `num_inputs`.
                None => cbor_map([("is_witness", Cbor::Bool(true))]),
            };
            self.call("tx_input", params)?;
        }

        // One `get_signature` per input we claimed, in the same order.
        let mut added = 0usize;
        for (index, step) in plan.iter().enumerate() {
            let Some(step) = step else { continue };
            let value = self.call(
                "get_signature",
                cbor_map([("ae_host_entropy", Cbor::Bytes(entropy.to_vec()))]),
            )?;
            let Cbor::Bytes(der) = value else {
                return Err(DeviceError::Protocol {
                    device: "Jade".into(),
                    detail: format!("no signature returned for input {index}"),
                });
            };
            if der.is_empty() {
                return Err(DeviceError::Declined {
                    device: "Jade".into(),
                });
            }
            let signature =
                ecdsa::Signature::from_slice(&der).map_err(|e| DeviceError::Protocol {
                    device: "Jade".into(),
                    detail: format!("unreadable signature for input {index}: {e}"),
                })?;
            psbt.inputs[index]
                .partial_sigs
                .insert(step.public_key, signature);
            added += 1;
        }

        if added == 0 {
            return Err(DeviceError::NoSignature {
                device: "Jade".into(),
            });
        }
        Ok(psbt.to_string())
    }
}

/// What one signable input needs from the device.
struct InputStep {
    public_key: PublicKey,
    path: DerivationPath,
    script_code: ScriptBuf,
    value: u64,
}

/// Decide, per input, whether this device can sign it and how.
///
/// Returns one entry per PSBT input — `None` where the device holds no key —
/// so the caller can keep the device's one-message-per-input contract without
/// a second pass over the PSBT.
fn sign_plan(psbt: &Psbt, fingerprint: Fingerprint) -> Result<Vec<Option<InputStep>>, DeviceError> {
    let mut plan = Vec::with_capacity(psbt.inputs.len());
    for (i, input) in psbt.inputs.iter().enumerate() {
        let mine = input
            .bip32_derivation
            .iter()
            .find(|(_, (fp, _))| *fp == fingerprint);
        let Some((public_key, (_, path))) = mine else {
            plan.push(None);
            continue;
        };

        let Some(utxo) = input.witness_utxo.as_ref() else {
            // Legacy (non-witness) inputs need the whole previous transaction
            // sent to the device. This wallet only ever builds native segwit,
            // so refuse rather than carry a path that cannot be exercised.
            return Err(DeviceError::Unsupported {
                device: "Jade".into(),
                detail: format!("input {i} is not native segwit"),
            });
        };

        let spk = &utxo.script_pubkey;
        let script_code = if spk.is_p2wpkh() {
            // BIP143 turns the p2wpkh output into its p2pkh script code.
            let hash = &spk.as_bytes()[2..22];
            let mut s = Vec::with_capacity(25);
            s.extend_from_slice(&[0x76, 0xa9, 0x14]);
            s.extend_from_slice(hash);
            s.extend_from_slice(&[0x88, 0xac]);
            ScriptBuf::from_bytes(s)
        } else if spk.is_p2wsh() {
            input
                .witness_script
                .clone()
                .ok_or_else(|| DeviceError::Protocol {
                    device: "Jade".into(),
                    detail: format!("input {i} is p2wsh but the PSBT carries no witness script"),
                })?
        } else {
            return Err(DeviceError::Unsupported {
                device: "Jade".into(),
                detail: format!("input {i} has an unsupported script type"),
            });
        };

        plan.push(Some(InputStep {
            public_key: PublicKey::new(*public_key),
            path: path.clone(),
            script_code,
            value: utxo.value.to_sat(),
        }));
    }
    Ok(plan)
}

fn path_to_vec(path: &DerivationPath) -> Vec<u32> {
    path.into_iter().map(|c| u32::from(*c)).collect()
}

fn cbor_map<const N: usize>(entries: [(&str, Cbor); N]) -> Cbor {
    let mut map = BTreeMap::new();
    for (k, v) in entries {
        map.insert(Cbor::Text(k.to_string()), v);
    }
    Cbor::Map(map)
}

/// Jade reports a user rejection as an error, not as an empty result, so it
/// has to be recognised here or "you pressed reject" surfaces as a protocol
/// fault the user cannot act on.
fn map_jade_error(method: &str, e: lwk_jade::Error) -> DeviceError {
    let text = e.to_string();
    let lower = text.to_lowercase();
    if lower.contains("denied") || lower.contains("rejected") || lower.contains("user declined") {
        return DeviceError::Declined {
            device: "Jade".into(),
        };
    }
    if lower.contains("timeout") || lower.contains("timed out") {
        return DeviceError::NotReady {
            device: "Jade".into(),
            detail: "the device stopped answering. Unlock it and try again.".into(),
        };
    }
    DeviceError::Protocol {
        device: "Jade".into(),
        detail: format!("{method}: {text}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use bitcoin_032::bip32::ChildNumber;
    use bitcoin_032::{
        absolute::LockTime, transaction::Version, Amount, OutPoint, Sequence, Transaction, TxIn,
        TxOut, Witness,
    };
    use std::str::FromStr;

    const PUBKEY: &str = "02c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5";

    fn psbt_with(inputs: usize) -> Psbt {
        let tx = Transaction {
            version: Version::TWO,
            lock_time: LockTime::ZERO,
            input: (0..inputs)
                .map(|_| TxIn {
                    previous_output: OutPoint::null(),
                    script_sig: ScriptBuf::new(),
                    sequence: Sequence::MAX,
                    witness: Witness::new(),
                })
                .collect(),
            output: vec![TxOut {
                value: Amount::from_sat(500),
                script_pubkey: ScriptBuf::new(),
            }],
        };
        Psbt::from_unsigned_tx(tx).expect("unsigned tx")
    }

    /// Fill input `index` as a native-segwit UTXO owned by `fingerprint`.
    fn own_input(psbt: &mut Psbt, index: usize, fingerprint: Fingerprint) -> PublicKey {
        let key = PublicKey::from_str(PUBKEY).expect("test pubkey");
        let spk = ScriptBuf::new_p2wpkh(&key.wpubkey_hash().expect("compressed"));
        psbt.inputs[index].witness_utxo = Some(TxOut {
            value: Amount::from_sat(1_000),
            script_pubkey: spk,
        });
        let path = DerivationPath::from(vec![
            ChildNumber::from_normal_idx(0).unwrap(),
            ChildNumber::from_normal_idx(7).unwrap(),
        ]);
        psbt.inputs[index]
            .bip32_derivation
            .insert(key.inner, (fingerprint, path));
        key
    }

    /// Jade counts `tx_input` messages against `num_inputs`, so an input the
    /// device cannot sign still needs a slot. Returning a compacted list of
    /// only-ours would desynchronise every later input in a mixed transaction
    /// — and the signatures would land on the wrong inputs.
    #[test]
    fn every_input_gets_a_slot_even_when_not_ours() {
        let mine = Fingerprint::from([0xaa, 0xbb, 0xcc, 0xdd]);
        let mut psbt = psbt_with(3);
        own_input(&mut psbt, 1, mine);

        let plan = sign_plan(&psbt, mine).expect("plan");
        assert_eq!(plan.len(), 3, "one entry per input");
        assert!(plan[0].is_none());
        assert!(plan[1].is_some(), "the input we own must be signable");
        assert!(plan[2].is_none());
    }

    /// A key belonging to another cosigner must not be claimed as ours: the
    /// device would be asked to sign with a path it does not hold.
    #[test]
    fn another_signers_input_is_not_claimed() {
        let mine = Fingerprint::from([0xaa, 0xbb, 0xcc, 0xdd]);
        let theirs = Fingerprint::from([0x11, 0x22, 0x33, 0x44]);
        let mut psbt = psbt_with(1);
        own_input(&mut psbt, 0, theirs);

        let plan = sign_plan(&psbt, mine).expect("plan");
        assert!(plan[0].is_none());
    }

    /// BIP143 signs a p2wpkh input against its *p2pkh* script code. Sending
    /// the witness program instead produces a valid-looking signature over the
    /// wrong sighash, which only fails at broadcast.
    #[test]
    fn p2wpkh_script_code_is_the_p2pkh_form() {
        let mine = Fingerprint::from([0xaa, 0xbb, 0xcc, 0xdd]);
        let mut psbt = psbt_with(1);
        let key = own_input(&mut psbt, 0, mine);

        let plan = sign_plan(&psbt, mine).expect("plan");
        let step = plan[0].as_ref().expect("ours");
        let code = step.script_code.to_bytes();
        assert_eq!(code.len(), 25);
        assert_eq!(&code[..3], &[0x76, 0xa9, 0x14]); // OP_DUP OP_HASH160 <20>
        assert_eq!(&code[23..], &[0x88, 0xac]); // OP_EQUALVERIFY OP_CHECKSIG
        assert_eq!(
            &code[3..23],
            &key.wpubkey_hash().expect("compressed")[..],
            "script code must commit to the same key hash as the output"
        );
        assert_eq!(step.value, 1_000);
    }

    /// Without a witness UTXO the device would have to be sent the whole
    /// previous transaction. This wallet never builds such inputs, so refusing
    /// beats sending a `satoshi` field we would have to invent.
    #[test]
    fn a_legacy_input_is_refused_rather_than_guessed() {
        let mine = Fingerprint::from([0xaa, 0xbb, 0xcc, 0xdd]);
        let mut psbt = psbt_with(1);
        let key = PublicKey::from_str(PUBKEY).expect("test pubkey");
        psbt.inputs[0]
            .bip32_derivation
            .insert(key.inner, (mine, DerivationPath::from(vec![])));
        assert!(matches!(
            sign_plan(&psbt, mine),
            Err(DeviceError::Unsupported { .. })
        ));
    }

    #[test]
    fn derivation_paths_serialise_as_hardened_child_numbers() {
        let path = DerivationPath::from_str("m/84h/1h/0h/0/5").expect("path");
        assert_eq!(
            path_to_vec(&path),
            vec![84 + HARDENED, 1 + HARDENED, HARDENED, 0, 5]
        );
    }
}
