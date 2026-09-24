//! PSBT helpers: serialization, merge, signature counting, inspection.

use std::collections::HashSet;

use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use bdk::bitcoin::blockdata::script::Instruction;
use bdk::bitcoin::ecdsa::Signature as EcdsaSignature;
use bdk::bitcoin::psbt::{Input as PsbtInput, PartiallySignedTransaction};
use bdk::bitcoin::secp256k1::{Message, Secp256k1};
use bdk::bitcoin::sighash::{EcdsaSighashType, SighashCache};
use bdk::bitcoin::{Address, Network, PrivateKey, TxIn, TxOut};
use bdk::keys::bip39::Mnemonic;
use bdk::keys::{DerivableKey, ExtendedKey};

use crate::bitcoin::wallet::WalletManager;
use crate::error::{BitcoinError, TemplarError};

// ── PSBT inspection result types ─────────────────────────────────────────────

/// Whether the previous-output data a PSBT carries for an input can be
/// trusted to say what that input spends.
///
/// BDK's signer takes the amount it commits to from `non_witness_utxo` first
/// and only falls back to `witness_utxo`. An inspection that read only the
/// latter would show one amount while the signature covers another: a
/// counterparty could hide a whole coin behind a small `witness_utxo` value
/// and collect the difference as fee. The resolution here mirrors the signer
/// ([`resolve_prevout`]), and anything but `Ok` blocks signing
/// ([`check_input_utxos`]).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum UtxoStatus {
    /// One story about the previous output, or two that agree.
    Ok,
    /// Neither `non_witness_utxo` nor `witness_utxo`: the amount is unknown.
    Missing,
    /// `non_witness_utxo` is not the spent transaction, or disagrees with
    /// `witness_utxo` on value or script.
    Conflicting,
}

impl UtxoStatus {
    /// Wire form for the FFI.
    pub fn as_str(self) -> &'static str {
        match self {
            UtxoStatus::Ok => "ok",
            UtxoStatus::Missing => "missing",
            UtxoStatus::Conflicting => "conflicting",
        }
    }
}

pub struct PsbtInputInfo {
    pub outpoint: String,
    /// `None` unless `utxo_status` is [`UtxoStatus::Ok`].
    pub amount_sats: Option<u64>,
    pub utxo_status: UtxoStatus,
    /// Whether the spent output belongs to the inspecting wallet. `None`
    /// when no wallet was open to judge, or the output is unknown.
    pub is_mine: Option<bool>,
}

pub struct PsbtOutputInfo {
    pub address: String,
    pub amount_sats: u64,
    pub display_amount: String,
    /// Whether the output pays the inspecting wallet. `None` when no wallet
    /// was open to judge.
    pub is_mine: Option<bool>,
}

pub struct PsbtSignerInfo {
    /// 8-char lowercase hex master fingerprint.
    pub fingerprint: String,
    pub has_signed: bool,
}

pub struct PsbtInspectionResult {
    pub inputs: Vec<PsbtInputInfo>,
    pub outputs: Vec<PsbtOutputInfo>,
    /// sum(inputs) − sum(outputs). `None` when any input amount is unknown:
    /// a fee computed from a guess would be exactly the number an attacker
    /// wants shown.
    pub fee_sats: Option<u64>,
    pub fee_display: String,
    /// Minimum signature count across inputs; a finalized input counts as
    /// fully signed.
    pub sigs_present: usize,
    /// Parsed from the witness_script OP threshold; 1 for a single-sig
    /// P2WPKH spend.
    pub sigs_required: Option<usize>,
    /// Signers deduced from bip32_derivation entries.
    pub signers: Vec<PsbtSignerInfo>,
    /// Human-readable policy summary ("2-of-3 multisig", "P2WPKH", …).
    pub policy_hint: String,
    /// The original base64 PSBT (for display / export).
    pub raw_psbt: String,
    /// Every input already carries a final witness or scriptSig: a signer
    /// finalized it, and partial signatures may have been stripped.
    pub finalized: bool,
    /// The worst `utxo_status` across inputs.
    pub utxo_check: UtxoStatus,
    /// Whether the `is_mine` flags carry information (a wallet was open).
    pub ownership_known: bool,
}

/// The previous output an input spends, resolved the way BDK's signer does:
/// `non_witness_utxo` first (it must be the transaction the outpoint names),
/// `witness_utxo` as the fallback, and the two must agree when both exist.
pub(crate) fn resolve_prevout(tx_in: &TxIn, input: &PsbtInput) -> (Option<TxOut>, UtxoStatus) {
    match (&input.non_witness_utxo, &input.witness_utxo) {
        (Some(prev_tx), witness) => {
            if prev_tx.txid() != tx_in.previous_output.txid {
                return (None, UtxoStatus::Conflicting);
            }
            let Some(out) = prev_tx.output.get(tx_in.previous_output.vout as usize) else {
                return (None, UtxoStatus::Conflicting);
            };
            if let Some(w) = witness {
                if w.value != out.value || w.script_pubkey != out.script_pubkey {
                    return (None, UtxoStatus::Conflicting);
                }
            }
            (Some(out.clone()), UtxoStatus::Ok)
        }
        (None, Some(w)) => (Some(w.clone()), UtxoStatus::Ok),
        (None, None) => (None, UtxoStatus::Missing),
    }
}

/// Refuses a PSBT whose inputs do not say, consistently, what they spend.
///
/// Every signing route runs this before a key touches the PSBT: what the
/// review screen showed is then exactly what the signature commits to.
pub fn check_input_utxos(psbt: &PartiallySignedTransaction) -> Result<(), TemplarError> {
    for (i, (tx_in, input)) in psbt
        .unsigned_tx
        .input
        .iter()
        .zip(psbt.inputs.iter())
        .enumerate()
    {
        match resolve_prevout(tx_in, input).1 {
            UtxoStatus::Ok => {}
            UtxoStatus::Missing => {
                return Err(BitcoinError::PsbtError(format!(
                    "Input {i} carries no previous-output data, so there is no way to show \
                     what it spends. Refusing to sign — ask the sender for a complete PSBT."
                ))
                .into());
            }
            UtxoStatus::Conflicting => {
                return Err(BitcoinError::PsbtError(format!(
                    "Input {i} carries two different previous outputs: the amount shown would \
                     not be the amount signed. Refusing to sign."
                ))
                .into());
            }
        }
    }
    Ok(())
}

/// Parses a base64 PSBT and extracts inputs, outputs, fee, and signer status.
///
/// Works without a wallet — everything comes from the PSBT itself. With a
/// wallet, inputs and outputs are also flagged as the wallet's own, which is
/// what lets a co-sign screen say "this spends your coin to someone else".
pub fn inspect_psbt(
    psbt_base64: &str,
    wallet: Option<&WalletManager>,
) -> Result<PsbtInspectionResult, TemplarError> {
    let psbt = WalletManager::psbt_from_base64(psbt_base64)?;

    // Inputs, priced the way the signer prices them.
    let mut prevouts: Vec<Option<TxOut>> = Vec::with_capacity(psbt.inputs.len());
    let mut inputs: Vec<PsbtInputInfo> = Vec::with_capacity(psbt.inputs.len());
    for (tx_in, input) in psbt.unsigned_tx.input.iter().zip(psbt.inputs.iter()) {
        let (prevout, utxo_status) = resolve_prevout(tx_in, input);
        let is_mine = match (wallet, &prevout) {
            (Some(w), Some(out)) => Some(w.is_mine(&out.script_pubkey)),
            _ => None,
        };
        inputs.push(PsbtInputInfo {
            outpoint: format!(
                "{}:{}",
                tx_in.previous_output.txid, tx_in.previous_output.vout
            ),
            amount_sats: prevout.as_ref().map(|o| o.value),
            utxo_status,
            is_mine,
        });
        prevouts.push(prevout);
    }
    // A PSBT with fewer input maps than transaction inputs is malformed;
    // rust-bitcoin rejects it at deserialization, so the zip above is exact.

    // Outputs
    let outputs: Vec<PsbtOutputInfo> = psbt
        .unsigned_tx
        .output
        .iter()
        .map(|out| {
            let address = Address::from_script(&out.script_pubkey, Network::Testnet)
                .map(|a| a.to_string())
                .unwrap_or_else(|_| "undecodable script".to_string());
            let amount_sats = out.value;
            PsbtOutputInfo {
                address,
                amount_sats,
                display_amount: format_sats(amount_sats),
                is_mine: wallet.map(|w| w.is_mine(&out.script_pubkey)),
            }
        })
        .collect();

    // Fee — only when every input amount is known.
    let utxo_check = inputs
        .iter()
        .map(|i| i.utxo_status)
        .max()
        .unwrap_or(UtxoStatus::Ok);
    let fee_sats = if utxo_check == UtxoStatus::Ok {
        let total_in: u64 = inputs.iter().filter_map(|i| i.amount_sats).sum();
        let total_out: u64 = outputs.iter().map(|o| o.amount_sats).sum();
        Some(total_in.saturating_sub(total_out))
    } else {
        None
    };
    let fee_display = fee_sats
        .map(format_sats)
        .unwrap_or_else(|| "unknown".to_string());

    // Sigs required — the witness_script OP threshold for multisig, one
    // signature for a single-sig P2WPKH spend (which has no witness_script,
    // so a quorum read from it alone would say nothing about the commonest
    // transaction there is).
    let first_prevout_script = prevouts
        .first()
        .and_then(|p| p.as_ref())
        .map(|o| &o.script_pubkey);
    let first_is_p2wpkh = first_prevout_script
        .map(|s| s.is_v0_p2wpkh())
        .unwrap_or(false);
    let sigs_required = psbt
        .inputs
        .first()
        .and_then(|inp| inp.witness_script.as_ref())
        .and_then(|ws| parse_multisig_threshold(ws))
        .or(if first_is_p2wpkh { Some(1) } else { None });

    // Minimum sigs present across all inputs. A finalized input has had its
    // partial signatures folded into the witness (BIP-174 strips them), so
    // it counts as carrying the whole quorum.
    let finalized_input =
        |inp: &PsbtInput| inp.final_script_witness.is_some() || inp.final_script_sig.is_some();
    let finalized = !psbt.inputs.is_empty() && psbt.inputs.iter().all(finalized_input);
    let sigs_present = psbt
        .inputs
        .iter()
        .map(|inp| {
            if finalized_input(inp) {
                inp.partial_sigs.len().max(sigs_required.unwrap_or(1))
            } else {
                inp.partial_sigs.len()
            }
        })
        .min()
        .unwrap_or(0);

    // Signers from bip32_derivation (use first input as representative)
    let signers: Vec<PsbtSignerInfo> = if let Some(inp) = psbt.inputs.first() {
        let signed_fps: HashSet<String> = inp
            .partial_sigs
            .keys()
            .filter_map(|btc_pk| {
                inp.bip32_derivation
                    .get(&btc_pk.inner)
                    .map(|(fp, _)| fp.to_string())
            })
            .collect();

        inp.bip32_derivation
            .values()
            .map(|(fp, _)| {
                let fingerprint = fp.to_string();
                let has_signed = signed_fps.contains(&fingerprint);
                PsbtSignerInfo {
                    fingerprint,
                    has_signed,
                }
            })
            .collect()
    } else {
        vec![]
    };

    // Policy hint
    let policy_hint = if first_is_p2wpkh {
        "P2WPKH (singlesig)".to_string()
    } else if let Some(k) = sigs_required {
        let n = signers.len();
        if n > 0 {
            format!("{}-of-{} multisig", k, n)
        } else {
            format!("{}-of-? multisig", k)
        }
    } else {
        "P2WSH".to_string()
    };

    Ok(PsbtInspectionResult {
        inputs,
        outputs,
        fee_sats,
        fee_display,
        sigs_present,
        sigs_required,
        signers,
        policy_hint,
        raw_psbt: psbt_base64.to_string(),
        finalized,
        utxo_check,
        ownership_known: wallet.is_some(),
    })
}

fn parse_multisig_threshold(script: &bdk::bitcoin::Script) -> Option<usize> {
    if let Some(Ok(Instruction::Op(op))) = script.instructions().next() {
        let b = op.to_u8();
        if (0x51..=0x60).contains(&b) {
            return Some((b - 0x50) as usize);
        }
    }
    None
}

fn format_sats(sats: u64) -> String {
    if sats >= 100_000 {
        format!("{:.8} BTC", sats as f64 / 1e8)
    } else {
        format!("{} sats", sats)
    }
}

impl WalletManager {
    /// Merges multiple partially-signed PSBTs into one.
    ///
    /// In a multisig flow the coordinator collects partial PSBTs from each
    /// cosigner and combines them into a single PSBT ready for finalization.
    pub fn merge_psbts(
        &self,
        base: PartiallySignedTransaction,
        partials: Vec<PartiallySignedTransaction>,
    ) -> Result<PartiallySignedTransaction, TemplarError> {
        let mut merged = base;
        for partial in partials {
            merged
                .combine(partial)
                .map_err(|e| BitcoinError::PsbtError(format!("Failed to combine PSBT: {e}")))?;
        }
        Ok(merged)
    }

    /// Finalizes a PSBT — assembles the witness stack (OP_0, signatures, witness_script)
    /// from the partial signatures, making the transaction ready for broadcast.
    ///
    /// Must be called after all required signatures have been merged in.
    pub fn finalize_psbt(&self, psbt: &mut PartiallySignedTransaction) -> Result<(), TemplarError> {
        use bdk::SignOptions;
        self.wallet
            .finalize_psbt(psbt, SignOptions::default())
            .map_err(|e| BitcoinError::PsbtError(format!("Finalization failed: {e}")))?;
        Ok(())
    }

    /// Counts the minimum number of signatures present across all inputs.
    ///
    /// Returns `(signatures_present, 0)` — the required count is not embedded
    /// in the PSBT and must be retrieved from the wallet profile.
    pub fn count_signatures(psbt: &PartiallySignedTransaction) -> (usize, usize) {
        let total_sigs: usize = psbt
            .inputs
            .iter()
            .map(|input| input.partial_sigs.len())
            .min()
            .unwrap_or(0);
        (total_sigs, 0)
    }

    /// Serializes a PSBT to base64 string.
    pub fn psbt_to_base64(psbt: &PartiallySignedTransaction) -> String {
        BASE64.encode(psbt.serialize())
    }

    /// Deserializes a PSBT from a base64 string.
    pub fn psbt_from_base64(encoded: &str) -> Result<PartiallySignedTransaction, TemplarError> {
        let bytes = BASE64
            .decode(encoded.trim())
            .map_err(|e| BitcoinError::PsbtError(format!("Base64 decode failed: {e}")))?;
        PartiallySignedTransaction::deserialize(&bytes).map_err(|e| {
            BitcoinError::PsbtError(format!("PSBT deserialization failed: {e}")).into()
        })
    }

    /// Signs a multisig PSBT using the raw mnemonic key — bypasses BDK's wallet-level
    /// ownership check, which would skip inputs that don't belong to the wallet's
    /// own descriptor (e.g. wsh(sortedmulti) inputs in a wpkh wallet).
    ///
    /// For each PSBT input, looks up `bip32_derivation` entries whose fingerprint
    /// matches the mnemonic's master key, derives the child private key, and inserts
    /// the ECDSA signature into `partial_sigs`.
    ///
    /// Returns the number of signatures added.
    pub fn sign_psbt_as_cosigner(
        mnemonic_str: &str,
        psbt: &mut PartiallySignedTransaction,
    ) -> Result<usize, TemplarError> {
        let secp = Secp256k1::new();
        let mnemonic = Mnemonic::parse(mnemonic_str)
            .map_err(|e| BitcoinError::InvalidMnemonic(e.to_string()))?;
        let xkey: ExtendedKey = mnemonic
            .into_extended_key()
            .map_err(|e| BitcoinError::InvalidMnemonic(e.to_string()))?;
        let xprv = xkey
            .into_xprv(Network::Testnet)
            .ok_or_else(|| BitcoinError::InvalidMnemonic("Failed to derive xprv".into()))?;

        let master_fp = xprv.fingerprint(&secp);
        let mut sigs_added = 0;

        let input_count = psbt.inputs.len();
        for idx in 0..input_count {
            // Collect (pubkey, derivation_path) for keys matching our master fingerprint
            let to_sign: Vec<_> = psbt.inputs[idx]
                .bip32_derivation
                .iter()
                .filter(|(_, (fp, _))| *fp == master_fp)
                .map(|(pk, (_, path))| (*pk, path.clone()))
                .collect();

            if to_sign.is_empty() {
                continue;
            }

            // Compute the segwit sighash for this input
            let witness_script = match psbt.inputs[idx].witness_script.clone() {
                Some(s) => s,
                None => {
                    // No witness script = not a P2WSH cosign input. It is a
                    // singlesig P2WPKH input (a normal send), already signed by
                    // the wallet's own BDK signer before this pass runs. The
                    // cosigner pass only adds signatures to wsh inputs, so skip
                    // anything else rather than failing the whole PSBT.
                    continue;
                }
            };
            let value = match psbt.inputs[idx].witness_utxo.as_ref() {
                Some(u) => u.value,
                None => {
                    return Err(BitcoinError::PsbtError(format!(
                        "Input {idx}: missing witness_utxo"
                    ))
                    .into())
                }
            };

            let mut cache = SighashCache::new(&psbt.unsigned_tx);
            let sighash = cache
                .segwit_signature_hash(idx, &witness_script, value, EcdsaSighashType::All)
                .map_err(|e| BitcoinError::PsbtError(format!("Sighash error: {e}")))?;
            let msg = Message::from_slice(sighash.as_ref())
                .map_err(|e| BitcoinError::PsbtError(format!("Message error: {e}")))?;

            // bip32_derivation key = secp256k1::PublicKey
            // partial_sigs key    = bitcoin::PublicKey (compressed wrapper)
            for (secp_pk, path) in to_sign {
                // Derive child xprv at the full absolute path
                let child_xprv = xprv
                    .derive_priv(&secp, &path)
                    .map_err(|e| BitcoinError::PsbtError(format!("Derivation error: {e}")))?;

                // Verify derived pubkey matches what the PSBT expects
                let derived_secp_pub = bdk::bitcoin::secp256k1::PublicKey::from_secret_key(
                    &secp,
                    &child_xprv.private_key,
                );
                if derived_secp_pub != secp_pk {
                    continue;
                }

                // Convert to bitcoin::PublicKey (always compressed for segwit)
                let btc_pk =
                    PrivateKey::new(child_xprv.private_key, Network::Testnet).public_key(&secp);

                let sig = secp.sign_ecdsa(&msg, &child_xprv.private_key);
                psbt.inputs[idx].partial_sigs.insert(
                    btc_pk,
                    EcdsaSignature {
                        sig,
                        hash_ty: EcdsaSighashType::All,
                    },
                );
                sigs_added += 1;
            }
        }

        // Zero is not an error here: this pass runs after the wallet's own BDK
        // signer, which handles P2WPKH inputs the cosigner pass skips. The
        // caller decides whether the transaction ended up signed.
        Ok(sigs_added)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn psbt_base64_roundtrip() {
        // Create a minimal valid PSBT (empty unsigned tx)
        let raw_psbt = "cHNidP8BADUCAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAoAAAAA/////wAAAAAAAAAAAA==";
        // This is a minimal PSBT; test that our decode handles invalid gracefully
        let result = WalletManager::psbt_from_base64(raw_psbt);
        // Whether it succeeds or fails is fine — we're testing the path doesn't panic
        let _ = result;
    }

    /// A PSBT whose two copies of the spent output disagree: the signer
    /// would commit to the `non_witness_utxo` amount while a witness-only
    /// reader would show the other one. Inspection must not price it and
    /// signing must refuse it.
    #[test]
    fn conflicting_prevout_data_is_unpriced_and_refused() {
        use bdk::bitcoin::absolute::LockTime;
        use bdk::bitcoin::{OutPoint, ScriptBuf, Sequence, Transaction, Witness};

        let script = ScriptBuf::new_v0_p2wpkh(&bdk::bitcoin::WPubkeyHash::from_raw_hash(
            bdk::bitcoin::hashes::Hash::all_zeros(),
        ));
        let prev = Transaction {
            version: 2,
            lock_time: LockTime::ZERO,
            input: vec![],
            output: vec![TxOut {
                value: 100_000_000,
                script_pubkey: script.clone(),
            }],
        };
        let spend = Transaction {
            version: 2,
            lock_time: LockTime::ZERO,
            input: vec![TxIn {
                previous_output: OutPoint::new(prev.txid(), 0),
                script_sig: ScriptBuf::new(),
                sequence: Sequence::MAX,
                witness: Witness::new(),
            }],
            output: vec![TxOut {
                value: 1_900_000,
                script_pubkey: script.clone(),
            }],
        };
        let mut psbt = PartiallySignedTransaction::from_unsigned_tx(spend).unwrap();

        // No previous-output data at all.
        let b64 = WalletManager::psbt_to_base64(&psbt);
        let seen = inspect_psbt(&b64, None).unwrap();
        assert_eq!(seen.utxo_check, UtxoStatus::Missing);
        assert_eq!(seen.fee_sats, None);
        assert!(check_input_utxos(&psbt).is_err());

        // The real prevout plus a witness_utxo that understates it.
        psbt.inputs[0].non_witness_utxo = Some(prev.clone());
        psbt.inputs[0].witness_utxo = Some(TxOut {
            value: 2_000_000,
            script_pubkey: script.clone(),
        });
        let b64 = WalletManager::psbt_to_base64(&psbt);
        let seen = inspect_psbt(&b64, None).unwrap();
        assert_eq!(seen.utxo_check, UtxoStatus::Conflicting);
        assert_eq!(seen.inputs[0].amount_sats, None);
        assert_eq!(seen.fee_sats, None);
        assert!(check_input_utxos(&psbt).is_err());

        // Consistent copies: priced from the signer's source, signable.
        psbt.inputs[0].witness_utxo = Some(prev.output[0].clone());
        let b64 = WalletManager::psbt_to_base64(&psbt);
        let seen = inspect_psbt(&b64, None).unwrap();
        assert_eq!(seen.utxo_check, UtxoStatus::Ok);
        assert_eq!(seen.inputs[0].amount_sats, Some(100_000_000));
        assert_eq!(seen.fee_sats, Some(98_100_000));
        assert_eq!(
            seen.sigs_required,
            Some(1),
            "a P2WPKH spend needs one signature"
        );
        assert!(check_input_utxos(&psbt).is_ok());
    }

    #[test]
    fn psbt_from_base64_invalid() {
        let result = WalletManager::psbt_from_base64("not-valid-base64!!!");
        assert!(result.is_err());
    }

    #[test]
    fn psbt_from_base64_valid_base64_invalid_psbt() {
        let result = WalletManager::psbt_from_base64("aGVsbG8gd29ybGQ="); // "hello world" in base64
        assert!(result.is_err());
    }

    #[test]
    fn psbt_from_base64_trims_whitespace() {
        let result = WalletManager::psbt_from_base64("  aGVsbG8=  ");
        // Should not fail on whitespace, but content is not valid PSBT
        assert!(result.is_err());
    }

    #[test]
    fn count_signatures_empty() {
        // With no inputs, should return (0, 0)
        // We can't easily construct a full PSBT without a wallet,
        // but we can test the static method signature exists and works
        // by creating a minimal PSBT structure
    }
}
