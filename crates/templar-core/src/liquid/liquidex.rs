//! LiquiDEX v0 swap engine — proposal parse/serialize, verification, make, take, cancel.
//!
//! A LiquiDEX v0 proposal is a partially-signed Elements transaction with
//! exactly one input and one output:
//!
//! * the **maker** spends one of their UTXOs (the asset they offer) and signs
//!   it with `SIGHASH_SINGLE | SIGHASH_ANYONECANPAY` (0x83);
//! * output 0 is a **confidential** output paying the maker the asset/amount
//!   they want, blinded to one of their own addresses;
//! * the proposal JSON reveals the blinders (asset/amount blinding factors)
//!   of both the spent prevout and the new output so a taker can verify the
//!   commitments and re-balance the transaction.
//!
//! Wire format (snake_case, blinders hex-reversed vs byte serialization —
//! the Elements Core display convention, which `elements`'
//! [`AssetBlindingFactor`]/[`ValueBlindingFactor`] `FromStr`/`Display` already
//! implement):
//!
//! ```json
//! {"version":0,"tx":"<hex>",
//!  "inputs":[{"asset":"..","asset_blinder":"..","amount_blinder":"..","amount":1000}],
//!  "outputs":[{"asset":"..","asset_blinder":"..","amount_blinder":"..","amount":1000}]}
//! ```
//!
//! The maker cannot produce a valid surjection proof for output 0 (its asset
//! is not among the maker's inputs), so v0 proposals carry an *empty* output
//! witness; the taker rebuilds both the surjection proof (over the full final
//! input set — which by construction contains the wanted asset, supplied by
//! the taker) and the rangeproof from the revealed blinders.
//!
//! Network access happens **only** inside deep verification, take, broadcast
//! and unspent-check paths — never in constructors or offline verification.

use std::collections::{BTreeSet, HashMap};
use std::str::FromStr;

use lwk_wollet::{
    elements::{
        confidential::{Asset, AssetBlindingFactor, Nonce, Value, ValueBlindingFactor},
        encode::serialize_hex,
        script::Instruction,
        secp256k1_zkp::{
            self, ecdsa, All, Generator, Message, Secp256k1, SecretKey, SurjectionProof,
        },
        sighash::SighashCache,
        Address, AddressParams, AssetId, EcdsaSighashType, LockTime, OutPoint, RangeProofMessage,
        Script, Sequence, SurjectionInput, Transaction, TxIn, TxInWitness, TxOut, TxOutSecrets,
        TxOutWitness, Txid,
    },
    Chain, WalletTxOut,
};
use rand::{CryptoRng, RngCore};
use serde::{Deserialize, Serialize};

use crate::error::{LiquidError, TemplarError};
use crate::liquid::chain::LiquidChain;
use crate::liquid::network::LiquidNetwork;
use crate::liquid::wallet::LiquidWalletManager;

type PublicKey = lwk_wollet::bitcoin::PublicKey;
type DerivationPath = lwk_wollet::bitcoin::bip32::DerivationPath;

/// Result of resolving the signing key material for a wallet UTXO.
type KeyResult = Result<(SecretKey, PublicKey), TemplarError>;

/// L-BTC asset id on Liquid **testnet** (display hex).
pub const LBTC_TESTNET_ASSET_ID: &str =
    "144c654344aa716d6f3abcc1ca90e5641e4e2a7f633bc09fe3baf64585819a49";

/// L-BTC asset id on Liquid **mainnet** (display hex).
pub const LBTC_MAINNET_ASSET_ID: &str =
    "6f0279e9ed041c3d710a9f57d0c02928416460c4b722ae3457a11eec381c526d";

/// Default fee rate in sat/kvB (0.1 sat/vB — the Liquid minimum relay rate).
const DEFAULT_FEE_RATE_KVB: f32 = 100.0;
/// Upper bound on the taker fee rate (sat/kvB). 10 sat/vB is already generous
/// on Liquid; anything above is a unit mistake, not intent.
const MAX_FEE_RATE_KVB: f32 = 10_000.0;

/// Validate a wire-provided fee rate: default, floor to the relay minimum,
/// refuse non-finite or absurd values (they would otherwise burn wallet L-BTC
/// as fee, or overflow the u64 fee math on Infinity).
fn sanitize_fee_rate(fee_rate: Option<f32>) -> Result<f32, TemplarError> {
    let rate = fee_rate.unwrap_or(DEFAULT_FEE_RATE_KVB);
    if !rate.is_finite() || rate > MAX_FEE_RATE_KVB {
        return Err(LiquidError::PsetBuildFailed(format!(
            "fee rate {rate} sat/kvB is not in (0, {MAX_FEE_RATE_KVB}]"
        ))
        .into());
    }
    Ok(rate.max(DEFAULT_FEE_RATE_KVB))
}

/// Sequence used for new inputs (`0xFFFFFFFE`, matches published proposals).
const INPUT_SEQUENCE: u32 = 0xFFFF_FFFE;

// ---------------------------------------------------------------------------
// Wire types
// ---------------------------------------------------------------------------

/// One leg of a LiquiDEX proposal: an unblinded prevout or output.
///
/// `asset` is the asset id in display hex; the two blinders are hex strings
/// in the Elements Core **reversed** display convention.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LiquidexLeg {
    pub asset: String,
    pub asset_blinder: String,
    pub amount_blinder: String,
    pub amount: u64,
}

/// A LiquiDEX v0 proposal as found on the wire (e.g. liquidex.it book rows).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LiquidexProposal {
    pub version: u32,
    /// Hex-serialized Elements transaction (1 input, 1 confidential output,
    /// input signed `SIGHASH_SINGLE | SIGHASH_ANYONECANPAY`).
    pub tx: String,
    pub inputs: Vec<LiquidexLeg>,
    pub outputs: Vec<LiquidexLeg>,
}

impl LiquidexProposal {
    /// Parses a proposal from its wire JSON.
    pub fn from_json(json: &str) -> Result<Self, TemplarError> {
        serde_json::from_str(json).map_err(|e| {
            TemplarError::from(LiquidError::PsetBuildFailed(format!(
                "LiquiDEX proposal parse: {e}"
            )))
        })
    }

    /// Serializes the proposal back to wire JSON (snake_case, blinders in
    /// the reversed display convention — unchanged from what was parsed).
    pub fn to_json(&self) -> Result<String, TemplarError> {
        serde_json::to_string(self).map_err(|e| {
            TemplarError::from(LiquidError::PsetBuildFailed(format!(
                "LiquiDEX proposal serialize: {e}"
            )))
        })
    }

    /// Decodes the embedded transaction.
    pub fn transaction(&self) -> Result<Transaction, TemplarError> {
        let bytes = hex::decode(self.tx.trim()).map_err(|e| {
            TemplarError::from(LiquidError::PsetBuildFailed(format!(
                "proposal tx hex: {e}"
            )))
        })?;
        lwk_wollet::elements::encode::deserialize(&bytes).map_err(|e| {
            TemplarError::from(LiquidError::PsetBuildFailed(format!(
                "proposal tx decode: {e}"
            )))
        })
    }

    /// Unblinded secrets of the maker's spent prevout (input leg 0).
    pub fn input_secrets(&self) -> Result<TxOutSecrets, TemplarError> {
        let leg = self.inputs.first().ok_or_else(|| {
            TemplarError::from(LiquidError::PsetBuildFailed(
                "proposal has no input leg".into(),
            ))
        })?;
        leg_to_secrets(leg)
    }

    /// Unblinded secrets of the maker's new output (output leg 0).
    pub fn output_secrets(&self) -> Result<TxOutSecrets, TemplarError> {
        let leg = self.outputs.first().ok_or_else(|| {
            TemplarError::from(LiquidError::PsetBuildFailed(
                "proposal has no output leg".into(),
            ))
        })?;
        leg_to_secrets(leg)
    }
}

/// Parses a wire leg into elements `TxOutSecrets`.
///
/// `AssetBlindingFactor::from_str` / `ValueBlindingFactor::from_str` consume
/// the reversed display-hex convention (and `to_string` produces it), so the
/// byte-order flip happens exactly once in each direction.
fn leg_to_secrets(leg: &LiquidexLeg) -> Result<TxOutSecrets, TemplarError> {
    let asset = AssetId::from_str(&leg.asset)
        .map_err(|e| LiquidError::PsetBuildFailed(format!("leg asset id: {e}")))?;
    let asset_bf = AssetBlindingFactor::from_str(&leg.asset_blinder)
        .map_err(|e| LiquidError::PsetBuildFailed(format!("leg asset blinder: {e}")))?;
    let value_bf = ValueBlindingFactor::from_str(&leg.amount_blinder)
        .map_err(|e| LiquidError::PsetBuildFailed(format!("leg amount blinder: {e}")))?;
    Ok(TxOutSecrets::new(asset, asset_bf, leg.amount, value_bf))
}

/// Serializes elements `TxOutSecrets` into a wire leg (reversed display hex).
fn secrets_to_leg(s: &TxOutSecrets) -> LiquidexLeg {
    LiquidexLeg {
        asset: s.asset.to_string(),
        asset_blinder: s.asset_bf.to_string(),
        amount_blinder: s.value_bf.to_string(),
        amount: s.value,
    }
}

// ---------------------------------------------------------------------------
// Verification result types
// ---------------------------------------------------------------------------

/// Which Liquid network a proposal appears to belong to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SwapNetwork {
    Testnet,
    Mainnet,
    /// A local Elements regtest — only ever detected when the wallet itself
    /// runs on regtest, since the regtest policy asset is node-specific.
    Regtest,
    Unknown,
}

impl SwapNetwork {
    pub fn as_str(&self) -> &'static str {
        match self {
            SwapNetwork::Testnet => "testnet",
            SwapNetwork::Mainnet => "mainnet",
            SwapNetwork::Regtest => "regtest",
            SwapNetwork::Unknown => "unknown",
        }
    }

    /// The classification of the wallet's own network — what a proposal has
    /// to be detected as before it is takeable.
    pub fn of(network: &LiquidNetwork) -> Self {
        if network.is_regtest() {
            SwapNetwork::Regtest
        } else {
            SwapNetwork::Testnet
        }
    }
}

/// An asset/amount pair as seen from the taker's perspective.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SwapLeg {
    pub asset_id: String,
    pub amount_sats: u64,
}

/// One verification check. `ok == None` means the check was not run
/// (e.g. it needs chain access and only offline verification was requested).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VerifyCheck {
    pub name: String,
    pub ok: Option<bool>,
    pub note: Option<String>,
}

/// Full verification report for a proposal.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VerifyResult {
    /// True when no executed check failed and all offline checks passed.
    pub valid: bool,
    /// structure, sighash_single_acp, output_commitments,
    /// input_commitments, input_unspent, signature (in this order).
    pub checks: Vec<VerifyCheck>,
    /// What the maker gives away (their input leg — what the taker receives).
    pub maker_offers: SwapLeg,
    /// What the maker asks for (their output leg — what the taker pays).
    pub maker_wants: SwapLeg,
    pub network: SwapNetwork,
    pub takeable: bool,
    pub take_block_reason: Option<String>,
}

// ---------------------------------------------------------------------------
// Commitment helpers
// ---------------------------------------------------------------------------

/// Recomputes the (asset, value) commitments for revealed secrets.
///
/// A component with a zero blinding factor is treated as explicit — that is
/// what unblinded wallet prevouts look like in `TxOutSecrets`.
fn commitments_for(secp: &Secp256k1<All>, s: &TxOutSecrets) -> (Asset, Value) {
    let asset = if s.asset_bf == AssetBlindingFactor::zero() {
        Asset::Explicit(s.asset)
    } else {
        Asset::new_confidential(secp, s.asset, s.asset_bf)
    };
    let value =
        if s.value_bf == ValueBlindingFactor::zero() && s.asset_bf == AssetBlindingFactor::zero() {
            Value::Explicit(s.value)
        } else {
            let gen = Generator::new_blinded(secp, s.asset.into_tag(), s.asset_bf.into_inner());
            Value::new_confidential(secp, s.value, gen, s.value_bf)
        };
    (asset, value)
}

/// Reconstructs a prevout `TxOut` (commitments only) from revealed secrets.
/// Enough for sighash values and `verify_tx_amt_proofs` spent-utxo input.
fn prevout_from_secrets(secp: &Secp256k1<All>, s: &TxOutSecrets, spk: &Script) -> TxOut {
    let (asset, value) = commitments_for(secp, s);
    TxOut {
        asset,
        value,
        nonce: Nonce::Null,
        script_pubkey: spk.clone(),
        witness: TxOutWitness::default(),
    }
}

/// The BIP143-style script code for a P2WPKH spend (a P2PKH script).
fn p2wpkh_script_code(pk: &PublicKey) -> Script {
    Address::p2pkh(pk, None, &AddressParams::LIQUID_TESTNET).script_pubkey()
}

/// The P2WPKH script pubkey for a compressed public key.
fn p2wpkh_script_pubkey(pk: &PublicKey) -> Script {
    Address::p2wpkh(pk, None, &AddressParams::LIQUID_TESTNET).script_pubkey()
}

// ---------------------------------------------------------------------------
// Offline + deep verification
// ---------------------------------------------------------------------------

/// Offline network heuristic: match leg asset ids against known L-BTC ids.
/// Mainnet takes priority: a proposal touching mainnet L-BTC on either leg is
/// mainnet no matter what else it claims. The regtest policy asset is only
/// recognised when `local` is a regtest, because it is node-specific.
fn detect_network_on(proposal: &LiquidexProposal, local: &LiquidNetwork) -> SwapNetwork {
    let mut network = SwapNetwork::Unknown;
    for leg in proposal.inputs.iter().chain(proposal.outputs.iter()) {
        if leg.asset == LBTC_MAINNET_ASSET_ID {
            return SwapNetwork::Mainnet;
        }
        if leg.asset == LBTC_TESTNET_ASSET_ID {
            network = SwapNetwork::Testnet;
        } else if local.is_regtest() && local.is_policy_asset(&leg.asset) {
            network = SwapNetwork::Regtest;
        }
    }
    network
}

/// [`detect_network_on`] for a testnet wallet.
#[cfg(test)]
fn detect_network(proposal: &LiquidexProposal) -> SwapNetwork {
    detect_network_on(proposal, &LiquidNetwork::testnet())
}

/// Structure check: version 0, arrays of length 1, decodable 1-in/1-out tx,
/// no issuance, witness signature present, confidential output, amounts > 0.
fn check_structure(proposal: &LiquidexProposal) -> Result<Transaction, String> {
    if proposal.version != 0 {
        return Err(format!("unsupported proposal version {}", proposal.version));
    }
    if proposal.inputs.len() != 1 {
        return Err(format!(
            "expected exactly 1 input leg, found {}",
            proposal.inputs.len()
        ));
    }
    if proposal.outputs.len() != 1 {
        return Err(format!(
            "expected exactly 1 output leg, found {}",
            proposal.outputs.len()
        ));
    }
    let tx = proposal.transaction().map_err(|e| e.to_string())?;
    if tx.input.len() != 1 || tx.output.len() != 1 {
        return Err(format!(
            "expected a 1-in/1-out transaction, found {}-in/{}-out",
            tx.input.len(),
            tx.output.len()
        ));
    }
    if tx.input[0].has_issuance() {
        return Err("proposal input carries an asset issuance".into());
    }
    let witness = &tx.input[0].witness.script_witness;
    // Exactly 2 items — p2wpkh (and the p2sh-p2wpkh inner program) requires
    // [sig, pubkey]; extra junk items would make the final tx consensus-invalid
    // while remaining txid-invisible.
    if witness.len() != 2 || witness[0].is_empty() {
        return Err("proposal input witness is not [signature, pubkey]".into());
    }
    if witness[1].len() != 33 {
        return Err("proposal input witness pubkey is not a 33-byte compressed key".into());
    }
    let out = &tx.output[0];
    if out.is_fee() {
        return Err("proposal output is a fee output".into());
    }
    if !out.asset.is_confidential() || !out.value.is_confidential() {
        return Err("proposal output is not confidential".into());
    }
    if proposal.inputs[0].amount == 0 || proposal.outputs[0].amount == 0 {
        return Err("proposal legs must have non-zero amounts".into());
    }
    // MAX_MONEY bound (21M * 10^8): attacker-chosen huge amounts otherwise
    // reach u64 arithmetic in the take builder and can overflow.
    const MAX_MONEY: u64 = 21_000_000 * 100_000_000;
    if proposal.inputs[0].amount > MAX_MONEY || proposal.outputs[0].amount > MAX_MONEY {
        return Err("proposal leg amount exceeds MAX_MONEY".into());
    }
    // NOTE: mainnet proposals stay structurally valid on purpose — the book is
    // a mainnet source and its rows must verify to be displayable. Mainnet is
    // blocked from *taking* by detect_network (mainnet wins over testnet) plus
    // the non-downgrading network pin in verify_proposal.
    leg_to_secrets(&proposal.inputs[0]).map_err(|e| e.to_string())?;
    leg_to_secrets(&proposal.outputs[0]).map_err(|e| e.to_string())?;
    Ok(tx)
}

/// Sighash check: the witness signature must end with byte `0x83`
/// (`SIGHASH_SINGLE | SIGHASH_ANYONECANPAY`).
fn check_sighash_byte(tx: &Transaction) -> Result<(), String> {
    let sig = &tx.input[0].witness.script_witness[0];
    match sig.last() {
        Some(0x83) => Ok(()),
        Some(other) => Err(format!(
            "maker signature sighash byte is 0x{other:02x}, expected 0x83 \
             (SIGHASH_SINGLE|ANYONECANPAY)"
        )),
        None => Err("maker signature is empty".into()),
    }
}

/// Output-commitment check: recompute the asset and value commitments of
/// output 0 from the revealed blinders and compare with the transaction.
fn check_output_commitments(
    secp: &Secp256k1<All>,
    tx: &Transaction,
    proposal: &LiquidexProposal,
) -> Result<(), String> {
    let secrets = proposal.output_secrets().map_err(|e| e.to_string())?;
    let (asset, value) = commitments_for(secp, &secrets);
    let out = &tx.output[0];
    if out.asset != asset {
        return Err("output asset commitment does not match revealed blinders".into());
    }
    if out.value != value {
        return Err("output value commitment does not match revealed blinders".into());
    }
    Ok(())
}

/// Verifies the maker's `SIGHASH_SINGLE|ANYONECANPAY` ECDSA signature on
/// input 0 of `tx` against `prevout`. Supports P2WPKH and P2SH-P2WPKH.
///
/// Because the sighash with ANYONECANPAY covers only input 0 and SINGLE
/// covers only output 0 (plus version/locktime), the same signature stays
/// valid on the final taker-extended transaction.
fn verify_maker_signature(
    secp: &Secp256k1<All>,
    tx: &Transaction,
    prevout: &TxOut,
) -> Result<(), String> {
    let witness = &tx.input[0].witness.script_witness;
    if witness.len() != 2 {
        return Err("input witness is not [signature, pubkey]".into());
    }
    let sig_bytes = &witness[0];
    let pk = PublicKey::from_slice(&witness[1]).map_err(|e| format!("witness pubkey: {e}"))?;

    let spk = &prevout.script_pubkey;
    if spk.is_v0_p2wpkh() {
        if *spk != p2wpkh_script_pubkey(&pk) {
            return Err("witness pubkey does not match the P2WPKH prevout".into());
        }
    } else if spk.is_p2sh() {
        let redeem = single_push_script(&tx.input[0].script_sig)
            .ok_or("P2SH scriptSig is not a single redeem-script push")?;
        if Address::p2sh(&redeem, None, &AddressParams::LIQUID_TESTNET).script_pubkey() != *spk {
            return Err("redeem script does not match the P2SH prevout".into());
        }
        if !redeem.is_v0_p2wpkh() || redeem != p2wpkh_script_pubkey(&pk) {
            return Err("P2SH redeem script is not the P2WPKH of the witness pubkey".into());
        }
    } else {
        return Err("unsupported prevout script type (only p2wpkh / p2sh-p2wpkh)".into());
    }

    let (der, sighash_byte) = sig_bytes
        .split_last()
        .map(|(last, rest)| (rest, *last))
        .ok_or("empty signature")?;
    if sighash_byte != 0x83 {
        return Err(format!("sighash byte 0x{sighash_byte:02x} != 0x83"));
    }
    let sig = ecdsa::Signature::from_der(der).map_err(|e| format!("signature DER: {e}"))?;

    let script_code = p2wpkh_script_code(&pk);
    let mut cache = SighashCache::new(tx);
    let sighash = cache.segwitv0_sighash(
        0,
        &script_code,
        prevout.value,
        EcdsaSighashType::SinglePlusAnyoneCanPay,
    );
    let msg = Message::from_digest_slice(&sighash[..]).map_err(|e| format!("sighash msg: {e}"))?;
    secp.verify_ecdsa(&msg, &sig, &pk.inner)
        .map_err(|e| format!("signature verification failed: {e}"))
}

/// Extracts the single pushed script from a scriptSig (P2SH redeem).
fn single_push_script(script_sig: &Script) -> Option<Script> {
    let mut instructions = script_sig.instructions();
    let first = instructions.next()?.ok()?;
    if instructions.next().is_some() {
        return None;
    }
    match first {
        Instruction::PushBytes(bytes) => Some(Script::from(bytes.to_vec())),
        _ => None,
    }
}

/// Verifies a LiquiDEX v0 proposal against the network the environment
/// selects (`TEMPLAR_LIQUID_NETWORK`, default testnet). See
/// [`verify_proposal_on`].
pub fn verify_proposal(
    proposal: &LiquidexProposal,
    deep: bool,
) -> Result<VerifyResult, TemplarError> {
    verify_proposal_on(proposal, deep, &LiquidNetwork::from_env())
}

/// Verifies a LiquiDEX v0 proposal from the point of view of a wallet on
/// `local`.
///
/// Offline checks (always run): structure, maker sighash byte (0x83) and
/// output-commitment recomputation from the revealed blinders.
///
/// With `deep == true` the maker prevout is fetched from `local`'s chain
/// backend (Electrum on testnet, `elementsd` RPC on regtest — see
/// [`LiquidChain::from_env`]) and three more checks run: input-commitment
/// recomputation, full ECDSA signature verification and an unspent check on
/// the offered UTXO. A prevout found on that chain pins `network` to it; a
/// missing prevout leaves the deep checks unresolved and the proposal
/// non-takeable.
///
/// Only chain connection failures produce an `Err`; verification failures
/// are reported inside the returned [`VerifyResult`].
pub fn verify_proposal_on(
    proposal: &LiquidexProposal,
    deep: bool,
    local: &LiquidNetwork,
) -> Result<VerifyResult, TemplarError> {
    let secp = Secp256k1::new();
    let mut checks: Vec<VerifyCheck> = Vec::with_capacity(6);
    let here = SwapNetwork::of(local);
    let mut network = detect_network_on(proposal, local);

    let structure = check_structure(proposal);
    let tx = match &structure {
        Ok(tx) => Some(tx.clone()),
        Err(_) => None,
    };
    push_check(
        &mut checks,
        "structure",
        Some(structure.as_ref().map(|_| ()).map_err(|e| e.clone())),
    );

    let sighash_res = tx.as_ref().map(check_sighash_byte);
    push_check(&mut checks, "sighash_single_acp", sighash_res);

    let commitments_res = tx
        .as_ref()
        .map(|tx| check_output_commitments(&secp, tx, proposal));
    push_check(&mut checks, "output_commitments", commitments_res);

    // Deep (chain) checks.
    let mut deep_results: [Option<Result<(), String>>; 3] = [None, None, None];
    let mut deep_note: Option<String> = None;
    if deep {
        if let Some(tx) = &tx {
            let chain = LiquidChain::from_env(local)?;
            let outpoint = tx.input[0].previous_output;
            match chain.fetch_transaction(&outpoint.txid)? {
                Some(prev_tx) => {
                    // Prevout found on the local chain. Never downgrade a
                    // Mainnet classification though — a mainnet proposal must
                    // not become takeable just because the configured
                    // endpoint happens to know the txid (e.g.
                    // TEMPLAR_LIQUID_ELECTRUM_URL pointed at mainnet).
                    if network != SwapNetwork::Mainnet {
                        network = here;
                    }
                    match prev_tx.output.get(outpoint.vout as usize) {
                        Some(prevout) => {
                            deep_results[0] =
                                Some(check_input_commitments(&secp, proposal, prevout));
                            deep_results[1] = Some(
                                chain
                                    .utxo_unspent(&prevout.script_pubkey, &outpoint)?
                                    .then_some(())
                                    .ok_or_else(|| "offered UTXO is already spent".to_string()),
                            );
                            deep_results[2] = Some(verify_maker_signature(&secp, tx, prevout));
                        }
                        None => {
                            let err = format!(
                                "prevout index {} out of range (tx has {} outputs)",
                                outpoint.vout,
                                prev_tx.output.len()
                            );
                            deep_results = [
                                Some(Err(err.clone())),
                                Some(Err(err.clone())),
                                Some(Err(err)),
                            ];
                        }
                    }
                }
                None => {
                    if network == here {
                        network = SwapNetwork::Unknown;
                    }
                    deep_note = Some(format!("offered UTXO not found on {local}"));
                }
            }
        } else {
            deep_note = Some("skipped: transaction could not be decoded".to_string());
        }
    } else {
        deep_note = Some("needs chain access".to_string());
    }

    let [input_commitments, input_unspent, signature] = deep_results;
    push_check_or_note(
        &mut checks,
        "input_commitments",
        input_commitments,
        &deep_note,
    );
    push_check_or_note(&mut checks, "input_unspent", input_unspent, &deep_note);
    push_check_or_note(&mut checks, "signature", signature, &deep_note);

    let offline_ok = checks.iter().take(3).all(|c| c.ok == Some(true));
    let any_failed = checks.iter().any(|c| c.ok == Some(false));
    let deep_all_ok = checks.iter().skip(3).all(|c| c.ok == Some(true));
    let valid = offline_ok && !any_failed;

    let (takeable, take_block_reason) = if !valid {
        (false, Some("proposal failed verification".to_string()))
    } else if network == SwapNetwork::Mainnet {
        (
            false,
            Some(format!(
                "Order is on Liquid mainnet — this wallet runs on {} and never signs mainnet.",
                local.short_name()
            )),
        )
    } else if !deep {
        (
            false,
            Some("deep (chain) verification required before taking".to_string()),
        )
    } else if network != here {
        (
            false,
            Some(format!("offered UTXO was not found on {local}")),
        )
    } else if !deep_all_ok {
        (false, Some("chain checks did not all pass".to_string()))
    } else {
        (true, None)
    };

    let maker_offers = proposal
        .inputs
        .first()
        .map(|l| SwapLeg {
            asset_id: l.asset.clone(),
            amount_sats: l.amount,
        })
        .unwrap_or(SwapLeg {
            asset_id: String::new(),
            amount_sats: 0,
        });
    let maker_wants = proposal
        .outputs
        .first()
        .map(|l| SwapLeg {
            asset_id: l.asset.clone(),
            amount_sats: l.amount,
        })
        .unwrap_or(SwapLeg {
            asset_id: String::new(),
            amount_sats: 0,
        });

    Ok(VerifyResult {
        valid,
        checks,
        maker_offers,
        maker_wants,
        network,
        takeable,
        take_block_reason,
    })
}

fn push_check(checks: &mut Vec<VerifyCheck>, name: &str, result: Option<Result<(), String>>) {
    let (ok, note) = match result {
        Some(Ok(())) => (Some(true), None),
        Some(Err(e)) => (Some(false), Some(e)),
        None => (None, Some("skipped: structure check failed".to_string())),
    };
    checks.push(VerifyCheck {
        name: name.to_string(),
        ok,
        note,
    });
}

fn push_check_or_note(
    checks: &mut Vec<VerifyCheck>,
    name: &str,
    result: Option<Result<(), String>>,
    fallback_note: &Option<String>,
) {
    match result {
        Some(res) => push_check(checks, name, Some(res)),
        None => checks.push(VerifyCheck {
            name: name.to_string(),
            ok: None,
            note: fallback_note.clone(),
        }),
    }
}

/// Input-commitment check: the revealed input blinders must reproduce the
/// on-chain prevout commitments (or its explicit values).
fn check_input_commitments(
    secp: &Secp256k1<All>,
    proposal: &LiquidexProposal,
    prevout: &TxOut,
) -> Result<(), String> {
    let secrets = proposal.input_secrets().map_err(|e| e.to_string())?;
    // Each component checked independently — Liquid allows mixed
    // explicit/confidential prevouts (e.g. explicit asset + blinded value).
    if prevout.asset.is_confidential() {
        if prevout.asset != Asset::new_confidential(secp, secrets.asset, secrets.asset_bf) {
            return Err("prevout asset commitment does not match revealed blinders".into());
        }
    } else {
        if prevout.asset.explicit() != Some(secrets.asset) {
            return Err("explicit prevout asset does not match input leg".into());
        }
        if secrets.asset_bf != AssetBlindingFactor::zero() {
            return Err("explicit prevout asset but non-zero asset blinder in input leg".into());
        }
    }
    if prevout.value.is_confidential() {
        let gen = Generator::new_blinded(
            secp,
            secrets.asset.into_tag(),
            secrets.asset_bf.into_inner(),
        );
        if prevout.value != Value::new_confidential(secp, secrets.value, gen, secrets.value_bf) {
            return Err("prevout value commitment does not match revealed blinders".into());
        }
    } else {
        if prevout.value.explicit() != Some(secrets.value) {
            return Err("explicit prevout value does not match input leg".into());
        }
        if secrets.value_bf != ValueBlindingFactor::zero() {
            return Err("explicit prevout value but non-zero value blinder in input leg".into());
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Chain paths (network access)
// ---------------------------------------------------------------------------

/// Deep check for offer-status refresh on the environment's network
/// (`TEMPLAR_LIQUID_NETWORK`, default testnet). See
/// [`proposal_utxo_unspent_on`].
pub fn proposal_utxo_unspent(proposal: &LiquidexProposal) -> Result<Option<bool>, TemplarError> {
    proposal_utxo_unspent_on(proposal, &LiquidNetwork::from_env())
}

/// Deep check for offer-status refresh: is the proposal's offered UTXO still
/// unspent on `local`?
///
/// Returns `Ok(None)` when the prevout transaction is unknown to the chain
/// backend (foreign network), `Ok(Some(bool))` otherwise. Network path.
pub fn proposal_utxo_unspent_on(
    proposal: &LiquidexProposal,
    local: &LiquidNetwork,
) -> Result<Option<bool>, TemplarError> {
    let tx = proposal.transaction()?;
    let outpoint = tx.input.first().map(|i| i.previous_output).ok_or_else(|| {
        TemplarError::from(LiquidError::PsetBuildFailed("proposal has no input".into()))
    })?;
    let chain = LiquidChain::from_env(local)?;
    match chain.fetch_transaction(&outpoint.txid)? {
        None => Ok(None),
        Some(prev_tx) => match prev_tx.output.get(outpoint.vout as usize) {
            None => Ok(None),
            Some(prevout) => Ok(Some(chain.utxo_unspent(&prevout.script_pubkey, &outpoint)?)),
        },
    }
}

/// Broadcasts a fully-signed Elements transaction on the environment's
/// network (`TEMPLAR_LIQUID_NETWORK`, default testnet). See
/// [`broadcast_transaction_on`].
pub fn broadcast_transaction(tx: &Transaction) -> Result<String, TemplarError> {
    broadcast_transaction_on(tx, &LiquidNetwork::from_env())
}

/// Broadcasts a fully-signed Elements transaction through `local`'s chain
/// backend. Returns the txid. Network path.
pub fn broadcast_transaction_on(
    tx: &Transaction,
    local: &LiquidNetwork,
) -> Result<String, TemplarError> {
    LiquidChain::from_env(local)?.broadcast(tx)?;
    Ok(tx.txid().to_string())
}

// ---------------------------------------------------------------------------
// Key derivation (wpkh slip77 singlesig wallets)
// ---------------------------------------------------------------------------

/// Extracts the key-origin derivation path (e.g. `84'/1'/0'`) from a CT
/// descriptor string like `ct(slip77(..),elwpkh([fp/84'/1'/0']tpub../<0;1>/*))`.
fn descriptor_origin_path(descriptor: &str) -> Option<String> {
    let start = descriptor.find('[')?;
    let end = descriptor[start..].find(']')? + start;
    let origin = &descriptor[start + 1..end];
    let slash = origin.find('/')?;
    let path = &origin[slash + 1..];
    if path.is_empty() {
        None
    } else {
        Some(path.to_string())
    }
}

/// Derives the signing key for a wallet UTXO of a wpkh singlesig wallet at
/// `<origin>/<chain>/<wildcard_index>` and proves it by rebuilding the
/// UTXO's script pubkey.
fn derive_utxo_key(
    secp: &Secp256k1<All>,
    manager: &LiquidWalletManager,
    utxo: &WalletTxOut,
) -> Result<(SecretKey, PublicKey), TemplarError> {
    let signer = manager.signer.as_ref().ok_or_else(|| {
        TemplarError::from(LiquidError::SigningFailed(
            "Watch-only wallet cannot sign".into(),
        ))
    })?;
    let chain = match utxo.ext_int {
        Chain::Internal => 1u32,
        _ => 0u32,
    };
    let mut candidates = Vec::new();
    if let Some(origin) = descriptor_origin_path(&manager.descriptor) {
        candidates.push(format!("m/{origin}/{chain}/{}", utxo.wildcard_index));
    }
    candidates.push(format!("m/{chain}/{}", utxo.wildcard_index));

    for path_str in candidates {
        let path = DerivationPath::from_str(&path_str)
            .map_err(|e| LiquidError::SigningFailed(format!("derivation path: {e}")))?;
        let xprv = signer
            .derive_xprv(&path)
            .map_err(|e| LiquidError::SigningFailed(format!("derive_xprv: {e}")))?;
        let sk = xprv.private_key;
        let pk = PublicKey::new(sk.public_key(secp));
        if p2wpkh_script_pubkey(&pk) == utxo.script_pubkey {
            return Ok((sk, pk));
        }
    }
    Err(LiquidError::SigningFailed(format!(
        "cannot derive signing key for UTXO {} (not a wpkh singlesig output of this wallet)",
        utxo.outpoint
    ))
    .into())
}

/// Parses a `"txid:vout"` string.
fn parse_outpoint(s: &str) -> Result<OutPoint, TemplarError> {
    let (txid_s, vout_s) = s.split_once(':').ok_or_else(|| {
        TemplarError::from(LiquidError::PsetBuildFailed(format!(
            "invalid utxo '{s}' (expected txid:vout)"
        )))
    })?;
    let txid = Txid::from_str(txid_s.trim())
        .map_err(|e| LiquidError::PsetBuildFailed(format!("invalid txid: {e}")))?;
    let vout: u32 = vout_s
        .trim()
        .parse()
        .map_err(|e| LiquidError::PsetBuildFailed(format!("invalid vout: {e}")))?;
    Ok(OutPoint::new(txid, vout))
}

// ---------------------------------------------------------------------------
// Make
// ---------------------------------------------------------------------------

/// Builds and signs a LiquiDEX v0 proposal offering the full amount of one
/// wallet UTXO (`"txid:vout"`) in exchange for `want_amount_sats` of
/// `want_asset_id`, paid to a fresh confidential address of this wallet.
///
/// Fully offline: no network access (the caller is expected to have synced).
pub fn make_proposal(
    manager: &LiquidWalletManager,
    utxo: &str,
    want_asset_id: &str,
    want_amount_sats: u64,
) -> Result<LiquidexProposal, TemplarError> {
    let outpoint = parse_outpoint(utxo)?;
    if want_asset_id == LBTC_MAINNET_ASSET_ID {
        return Err(LiquidError::PsetBuildFailed(
            "want asset is mainnet L-BTC — it cannot be received on Liquid testnet".into(),
        )
        .into());
    }
    let want_asset = AssetId::from_str(want_asset_id)
        .map_err(|e| LiquidError::PsetBuildFailed(format!("want asset id: {e}")))?;
    let utxos = manager
        .wollet
        .utxos()
        .map_err(|e| LiquidError::PsetBuildFailed(format!("utxos: {e}")))?;
    let wallet_utxo = utxos
        .iter()
        .find(|u| u.outpoint == outpoint && !u.is_spent)
        .ok_or_else(|| {
            TemplarError::from(LiquidError::PsetBuildFailed(format!(
                "UTXO {utxo} not found in wallet (already spent?)"
            )))
        })?;

    let secp = Secp256k1::new();
    let (sk, pk) = derive_utxo_key(&secp, manager, wallet_utxo)?;
    let receive = manager
        .wollet
        .address(None)
        .map_err(|e| LiquidError::PsetBuildFailed(format!("address: {e}")))?
        .address()
        .clone();

    let mut rng = rand::thread_rng();
    make_proposal_core(
        &mut rng,
        &secp,
        wallet_utxo,
        &sk,
        &pk,
        &receive,
        want_asset,
        want_amount_sats,
    )
}

/// Offline core of [`make_proposal`], parameterized for testability.
#[allow(clippy::too_many_arguments)]
fn make_proposal_core<R: RngCore + CryptoRng>(
    rng: &mut R,
    secp: &Secp256k1<All>,
    utxo: &WalletTxOut,
    sk: &SecretKey,
    pk: &PublicKey,
    receive_address: &Address,
    want_asset: AssetId,
    want_amount: u64,
) -> Result<LiquidexProposal, TemplarError> {
    if want_amount == 0 {
        return Err(LiquidError::PsetBuildFailed("want amount must be > 0".into()).into());
    }
    if p2wpkh_script_pubkey(pk) != utxo.script_pubkey {
        return Err(LiquidError::SigningFailed(
            "signing key does not match the UTXO script pubkey".into(),
        )
        .into());
    }
    let blinding_pk = receive_address.blinding_pubkey.ok_or_else(|| {
        TemplarError::from(LiquidError::PsetBuildFailed(
            "receive address must be confidential".into(),
        ))
    })?;

    // Blind the wanted output manually. The surjection proof CANNOT be built
    // (the wanted asset is not among this tx's inputs) — v0 proposals carry
    // an empty output witness; the taker rebuilds the proofs.
    let out_abf = AssetBlindingFactor::new(rng);
    let out_vbf = ValueBlindingFactor::new(rng);
    let out_secrets = TxOutSecrets::new(want_asset, out_abf, want_amount, out_vbf);
    let asset_commitment = Asset::new_confidential(secp, want_asset, out_abf);
    let asset_gen = Generator::new_blinded(secp, want_asset.into_tag(), out_abf.into_inner());
    let value_commitment = Value::new_confidential(secp, want_amount, asset_gen, out_vbf);
    let ephemeral_sk = SecretKey::new(rng);
    let (nonce, _shared) = Nonce::with_ephemeral_sk(secp, ephemeral_sk, &blinding_pk);

    let mut tx = Transaction {
        version: 2,
        lock_time: LockTime::ZERO,
        input: vec![TxIn {
            previous_output: utxo.outpoint,
            is_pegin: false,
            script_sig: Script::new(),
            sequence: Sequence::from_consensus(INPUT_SEQUENCE),
            asset_issuance: Default::default(),
            witness: TxInWitness::default(),
        }],
        output: vec![TxOut {
            asset: asset_commitment,
            value: value_commitment,
            nonce,
            script_pubkey: receive_address.script_pubkey(),
            witness: TxOutWitness::default(),
        }],
    };

    // Sign the input SIGHASH_SINGLE | SIGHASH_ANYONECANPAY.
    let (_, prevout_value) = commitments_for(secp, &utxo.unblinded);
    let script_code = p2wpkh_script_code(pk);
    let sighash = SighashCache::new(&tx).segwitv0_sighash(
        0,
        &script_code,
        prevout_value,
        EcdsaSighashType::SinglePlusAnyoneCanPay,
    );
    let msg = Message::from_digest_slice(&sighash[..])
        .map_err(|e| LiquidError::SigningFailed(format!("sighash message: {e}")))?;
    let mut sig = secp.sign_ecdsa(&msg, sk).serialize_der().to_vec();
    sig.push(0x83);
    tx.input[0].witness.script_witness = vec![sig, pk.to_bytes()];

    Ok(LiquidexProposal {
        version: 0,
        tx: serialize_hex(&tx),
        inputs: vec![secrets_to_leg(&utxo.unblinded)],
        outputs: vec![secrets_to_leg(&out_secrets)],
    })
}

// ---------------------------------------------------------------------------
// Take
// ---------------------------------------------------------------------------

/// Fee/change summary of a built taker transaction plus the verification
/// report that authorized it.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TakePreview {
    /// The maker-offered leg the taker receives.
    pub you_receive: SwapLeg,
    /// The maker-wanted leg the taker pays.
    pub you_pay: SwapLeg,
    pub fee_sats: u64,
    /// Change outputs back to the taker's wallet.
    pub change: Vec<SwapLeg>,
    pub analysis: VerifyResult,
}

/// A fully-built taker transaction, ready to broadcast.
#[derive(Debug, Clone)]
pub struct TakeResult {
    pub tx: Transaction,
    pub txid: String,
    pub preview: TakePreview,
}

/// Deep-verifies and takes a proposal: keeps the maker's input/output at
/// index 0, adds taker inputs supplying the wanted asset plus L-BTC for the
/// fee, an output to the taker of the offered asset, change outputs and an
/// explicit fee output (last); blinds so the transaction balances *including*
/// the maker's revealed blinders; rebuilds the maker output's rangeproof and
/// surjection proof over the full final input set; signs taker inputs
/// `SIGHASH_ALL`; self-checks with `verify_tx_amt_proofs`.
///
/// `fee_rate` is sat/kvB (default 100 = 0.1 sat/vB). Refuses proposals that
/// are not takeable on the wallet's own network (testnet or regtest — read
/// from the wallet, so a regtest wallet takes regtest offers and pays the
/// fee in its own policy asset). Does **not** broadcast — pass the returned
/// transaction to [`broadcast_transaction_on`].
pub fn take_proposal(
    manager: &LiquidWalletManager,
    proposal: &LiquidexProposal,
    fee_rate: Option<f32>,
) -> Result<TakeResult, TemplarError> {
    take_proposal_excluding(manager, proposal, fee_rate, &BTreeSet::new())
}

/// [`take_proposal`] that never spends the `frozen` outpoints (`txid:vout`):
/// they are dropped from the coins the taker side selects from.
pub fn take_proposal_excluding(
    manager: &LiquidWalletManager,
    proposal: &LiquidexProposal,
    fee_rate: Option<f32>,
    frozen: &BTreeSet<String>,
) -> Result<TakeResult, TemplarError> {
    let local = manager.network()?;
    let analysis = verify_proposal_on(proposal, true, &local)?;
    if !analysis.takeable {
        let reason = analysis
            .take_block_reason
            .clone()
            .unwrap_or_else(|| "proposal is not takeable".to_string());
        return Err(LiquidError::PsetBuildFailed(reason).into());
    }

    let utxos: Vec<WalletTxOut> = manager
        .wollet
        .utxos()
        .map_err(|e| LiquidError::PsetBuildFailed(format!("utxos: {e}")))?
        .into_iter()
        .filter(|u| !frozen.contains(&u.outpoint.to_string()))
        .collect();
    let policy_asset = manager.policy_asset();
    let secp = Secp256k1::new();
    let mut rng = rand::thread_rng();

    // Fresh addresses, slot-stable across fee iterations: slot 0 = external
    // receive address, slots 1.. = internal (change) addresses.
    let ext_index = manager
        .wollet
        .address(None)
        .map_err(|e| LiquidError::PsetBuildFailed(format!("address: {e}")))?
        .index();
    let int_index = manager
        .wollet
        .change(None)
        .map_err(|e| LiquidError::PsetBuildFailed(format!("change address: {e}")))?
        .index();
    let wollet = &manager.wollet;
    let mut cache: HashMap<usize, Address> = HashMap::new();
    let mut next_addr = |slot: usize| -> Result<Address, TemplarError> {
        if let Some(a) = cache.get(&slot) {
            return Ok(a.clone());
        }
        let addr = if slot == 0 {
            wollet
                .address(Some(ext_index))
                .map_err(|e| {
                    TemplarError::from(LiquidError::PsetBuildFailed(format!("address: {e}")))
                })?
                .address()
                .clone()
        } else {
            wollet
                .change(Some(int_index + (slot as u32 - 1)))
                .map_err(|e| {
                    TemplarError::from(LiquidError::PsetBuildFailed(format!("change: {e}")))
                })?
                .address()
                .clone()
        };
        cache.insert(slot, addr.clone());
        Ok(addr)
    };
    let key_for = |utxo: &WalletTxOut| derive_utxo_key(&secp, manager, utxo);

    let build = build_take_tx_core(
        &mut rng,
        &secp,
        proposal,
        &utxos,
        policy_asset,
        sanitize_fee_rate(fee_rate)?,
        &mut next_addr,
        &key_for,
    )?;

    let txid = build.tx.txid().to_string();
    Ok(TakeResult {
        preview: TakePreview {
            you_receive: build.you_receive,
            you_pay: build.you_pay,
            fee_sats: build.fee_sats,
            change: build.change,
            analysis,
        },
        txid,
        tx: build.tx,
    })
}

/// Deep-verifies and builds the real taker transaction to report the honest
/// fee and change legs, without broadcasting. Network path (deep verify).
pub fn take_preview(
    manager: &LiquidWalletManager,
    proposal: &LiquidexProposal,
    fee_rate: Option<f32>,
) -> Result<TakePreview, TemplarError> {
    Ok(take_proposal(manager, proposal, fee_rate)?.preview)
}

/// [`take_preview`] over the same coins [`take_proposal_excluding`] spends.
pub fn take_preview_excluding(
    manager: &LiquidWalletManager,
    proposal: &LiquidexProposal,
    fee_rate: Option<f32>,
    frozen: &BTreeSet<String>,
) -> Result<TakePreview, TemplarError> {
    Ok(take_proposal_excluding(manager, proposal, fee_rate, frozen)?.preview)
}

#[derive(Debug)]
struct TakeBuild {
    tx: Transaction,
    fee_sats: u64,
    you_receive: SwapLeg,
    you_pay: SwapLeg,
    change: Vec<SwapLeg>,
}

fn fee_for_vsize(vsize: usize, rate_kvb: f32) -> u64 {
    (((vsize as f64) * (rate_kvb as f64) / 1000.0).ceil() as u64).max(1)
}

/// Offline core of the taker build, parameterized for testability.
/// Performs blinding, proof rebuilding, signing, fee convergence and the
/// `verify_tx_amt_proofs` self-check. No network access.
#[allow(clippy::too_many_arguments)]
fn build_take_tx_core<R: RngCore + CryptoRng>(
    rng: &mut R,
    secp: &Secp256k1<All>,
    proposal: &LiquidexProposal,
    own_utxos: &[WalletTxOut],
    policy_asset: AssetId,
    fee_rate_kvb: f32,
    next_addr: &mut dyn FnMut(usize) -> Result<Address, TemplarError>,
    key_for: &dyn Fn(&WalletTxOut) -> KeyResult,
) -> Result<TakeBuild, TemplarError> {
    let maker_tx = proposal.transaction()?;
    let maker_in_secrets = proposal.input_secrets()?;
    let maker_out_secrets = proposal.output_secrets()?;
    let offered_asset = maker_in_secrets.asset;
    let offered_amount = maker_in_secrets.value;
    let wanted_asset = maker_out_secrets.asset;
    let wanted_amount = maker_out_secrets.value;
    if offered_asset == wanted_asset {
        return Err(
            LiquidError::PsetBuildFailed("maker offers and wants the same asset".into()).into(),
        );
    }
    let maker_outpoint = maker_tx.input[0].previous_output;

    let candidates: Vec<&WalletTxOut> = own_utxos
        .iter()
        .filter(|u| !u.is_spent && u.outpoint != maker_outpoint)
        .collect();

    let mut fee: u64 = 250;
    let mut last_err = None;
    for _ in 0..8 {
        let built = build_take_once(
            rng,
            secp,
            &maker_tx,
            &maker_in_secrets,
            &maker_out_secrets,
            &candidates,
            policy_asset,
            fee,
            next_addr,
            key_for,
        )?;
        let needed = fee_for_vsize(built.tx.vsize(), fee_rate_kvb);
        if needed <= fee && fee - needed <= 10 {
            // Converged (allow a few sats of rangeproof-size jitter).
            self_check_amounts(secp, &built, &maker_in_secrets)?;
            return Ok(TakeBuild {
                tx: built.tx,
                fee_sats: fee,
                you_receive: SwapLeg {
                    asset_id: offered_asset.to_string(),
                    amount_sats: offered_amount,
                },
                you_pay: SwapLeg {
                    asset_id: wanted_asset.to_string(),
                    amount_sats: wanted_amount,
                },
                change: built.change,
            });
        }
        last_err = Some(format!("fee {fee} sats, needed {needed} sats"));
        fee = needed;
    }
    Err(LiquidError::PsetBuildFailed(format!(
        "fee estimation did not converge ({})",
        last_err.unwrap_or_default()
    ))
    .into())
}

struct TakeSingleBuild {
    tx: Transaction,
    change: Vec<SwapLeg>,
    own_selected: Vec<WalletTxOut>,
}

/// Greedy largest-first selection of `asset` UTXOs totaling >= `target`.
fn select_utxos<'a>(
    candidates: &[&'a WalletTxOut],
    asset: AssetId,
    target: u64,
) -> Result<(Vec<&'a WalletTxOut>, u64), TemplarError> {
    let mut pool: Vec<&WalletTxOut> = candidates
        .iter()
        .copied()
        .filter(|u| u.unblinded.asset == asset)
        .collect();
    pool.sort_by_key(|u| std::cmp::Reverse(u.unblinded.value));
    let mut total = 0u64;
    let mut picked = Vec::new();
    for utxo in pool {
        if total >= target {
            break;
        }
        total += utxo.unblinded.value;
        picked.push(utxo);
    }
    if total < target {
        return Err(LiquidError::PsetBuildFailed(format!(
            "insufficient balance of asset {asset}: need {target} sats, have {total} sats"
        ))
        .into());
    }
    Ok((picked, total))
}

/// One full build at a fixed fee: select, blind, rebuild maker proofs, sign.
#[allow(clippy::too_many_arguments)]
fn build_take_once<R: RngCore + CryptoRng>(
    rng: &mut R,
    secp: &Secp256k1<All>,
    maker_tx: &Transaction,
    maker_in_secrets: &TxOutSecrets,
    maker_out_secrets: &TxOutSecrets,
    candidates: &[&WalletTxOut],
    policy_asset: AssetId,
    fee: u64,
    next_addr: &mut dyn FnMut(usize) -> Result<Address, TemplarError>,
    key_for: &dyn Fn(&WalletTxOut) -> KeyResult,
) -> Result<TakeSingleBuild, TemplarError> {
    let offered_asset = maker_in_secrets.asset;
    let offered_amount = maker_in_secrets.value;
    let wanted_asset = maker_out_secrets.asset;
    let wanted_amount = maker_out_secrets.value;

    // --- coin selection ---------------------------------------------------
    let mut selected: Vec<&WalletTxOut> = Vec::new();
    let mut change_specs: Vec<(u64, AssetId)> = Vec::new(); // (amount, asset)
    if wanted_asset == policy_asset {
        let target = wanted_amount
            .checked_add(fee)
            .ok_or_else(|| LiquidError::PsetBuildFailed("wanted amount + fee overflows".into()))?;
        let (picked, total) = select_utxos(candidates, policy_asset, target)?;
        selected.extend(picked);
        let change = total - wanted_amount - fee;
        if change > 0 {
            change_specs.push((change, policy_asset));
        }
    } else {
        let (picked_w, total_w) = select_utxos(candidates, wanted_asset, wanted_amount)?;
        selected.extend(picked_w);
        let change_w = total_w - wanted_amount;
        if change_w > 0 {
            change_specs.push((change_w, wanted_asset));
        }
        let (picked_l, total_l) = select_utxos(candidates, policy_asset, fee)?;
        selected.extend(picked_l);
        let change_l = total_l - fee;
        if change_l > 0 {
            change_specs.push((change_l, policy_asset));
        }
    }

    // Input order: maker at 0, then taker inputs. All secrets in that order.
    let mut in_secrets: Vec<TxOutSecrets> = vec![*maker_in_secrets];
    in_secrets.extend(selected.iter().map(|u| u.unblinded));

    // --- outputs ----------------------------------------------------------
    // [0] maker output (kept, proofs rebuilt below)
    // [1] taker receive of the offered asset
    // [2..] change outputs
    // [last] explicit fee output
    let mut blinded_specs: Vec<(u64, AssetId, Address)> =
        vec![(offered_amount, offered_asset, next_addr(0)?)];
    for (slot, (amount, asset)) in change_specs.iter().enumerate() {
        blinded_specs.push((*amount, *asset, next_addr(slot + 1)?));
    }
    let change_legs: Vec<SwapLeg> = change_specs
        .iter()
        .map(|(amount, asset)| SwapLeg {
            asset_id: asset.to_string(),
            amount_sats: *amount,
        })
        .collect();

    let fee_secrets = TxOutSecrets::new(
        policy_asset,
        AssetBlindingFactor::zero(),
        fee,
        ValueBlindingFactor::zero(),
    );

    let mut blinded_outs: Vec<TxOut> = Vec::new();
    let mut nonlast_secrets: Vec<TxOutSecrets> = Vec::new();
    let last = blinded_specs.len() - 1;
    for (amount, asset, address) in blinded_specs.iter().take(last) {
        let (txout, abf, vbf, _eph) = TxOut::new_not_last_confidential(
            rng,
            secp,
            *amount,
            address.clone(),
            *asset,
            &in_secrets,
        )
        .map_err(|e| LiquidError::PsetBuildFailed(format!("blind output: {e}")))?;
        nonlast_secrets.push(TxOutSecrets::new(*asset, abf, *amount, vbf));
        blinded_outs.push(txout);
    }
    // Last blinded output: its value blinding factor closes the balance
    // equation over ALL inputs and outputs, including the maker's revealed
    // blinders and the explicit fee output.
    {
        let (amount, asset, address) = &blinded_specs[last];
        let blinder = address.blinding_pubkey.ok_or_else(|| {
            TemplarError::from(LiquidError::PsetBuildFailed(
                "change address must be confidential".into(),
            ))
        })?;
        let mut output_secrets: Vec<&TxOutSecrets> = vec![maker_out_secrets];
        output_secrets.extend(nonlast_secrets.iter());
        output_secrets.push(&fee_secrets);
        let (txout, _abf, _vbf, _eph) = TxOut::new_last_confidential(
            rng,
            secp,
            *amount,
            *asset,
            address.script_pubkey(),
            blinder,
            &in_secrets,
            &output_secrets,
        )
        .map_err(|e| LiquidError::PsetBuildFailed(format!("blind last output: {e}")))?;
        blinded_outs.push(txout);
    }

    // --- rebuild the maker output's proofs over the final input set -------
    let mut maker_out = maker_tx.output[0].clone();
    let targets: Vec<(Generator, secp256k1_zkp::Tag, secp256k1_zkp::Tweak)> = in_secrets
        .iter()
        .map(|s| {
            SurjectionInput::from(*s)
                .surjection_target(secp)
                .map_err(|e| LiquidError::PsetBuildFailed(format!("surjection input: {e}")))
        })
        .collect::<Result<_, _>>()?;
    let surjection_proof = SurjectionProof::new(
        secp,
        rng,
        wanted_asset.into_tag(),
        maker_out_secrets.asset_bf.into_inner(),
        &targets,
    )
    .map_err(|e| LiquidError::PsetBuildFailed(format!("maker surjection proof: {e}")))?;
    let msg = RangeProofMessage {
        asset: wanted_asset,
        bf: maker_out_secrets.asset_bf,
    };
    let (value_commitment, rangeproof) = Value::Explicit(wanted_amount)
        .blind_with_shared_secret(
            secp,
            maker_out_secrets.value_bf,
            SecretKey::new(rng),
            &maker_out.script_pubkey,
            &msg,
        )
        .map_err(|e| LiquidError::PsetBuildFailed(format!("maker rangeproof: {e}")))?;
    if value_commitment != maker_out.value {
        return Err(LiquidError::PsetBuildFailed(
            "maker output commitment does not match revealed blinders".into(),
        )
        .into());
    }
    maker_out.witness = TxOutWitness {
        surjection_proof: Some(Box::new(surjection_proof)),
        rangeproof: Some(Box::new(rangeproof)),
    };

    // --- assemble ---------------------------------------------------------
    // Version and locktime are covered by the maker's signature: keep them.
    let mut outputs = vec![maker_out];
    outputs.extend(blinded_outs);
    outputs.push(TxOut::new_fee(fee, policy_asset));
    let mut inputs = vec![maker_tx.input[0].clone()];
    for utxo in &selected {
        inputs.push(TxIn {
            previous_output: utxo.outpoint,
            is_pegin: false,
            script_sig: Script::new(),
            sequence: Sequence::from_consensus(INPUT_SEQUENCE),
            asset_issuance: Default::default(),
            witness: TxInWitness::default(),
        });
    }
    let mut tx = Transaction {
        version: maker_tx.version,
        lock_time: maker_tx.lock_time,
        input: inputs,
        output: outputs,
    };

    // --- sign taker inputs SIGHASH_ALL ------------------------------------
    let mut witnesses: Vec<(usize, Vec<Vec<u8>>)> = Vec::new();
    {
        let mut cache = SighashCache::new(&tx);
        for (offset, utxo) in selected.iter().enumerate() {
            let index = offset + 1;
            let (sk, pk) = key_for(utxo)?;
            if p2wpkh_script_pubkey(&pk) != utxo.script_pubkey {
                return Err(LiquidError::SigningFailed(
                    "derived key does not match input script pubkey".into(),
                )
                .into());
            }
            let (_, value) = commitments_for(secp, &utxo.unblinded);
            let sighash = cache.segwitv0_sighash(
                index,
                &p2wpkh_script_code(&pk),
                value,
                EcdsaSighashType::All,
            );
            let msg = Message::from_digest_slice(&sighash[..])
                .map_err(|e| LiquidError::SigningFailed(format!("sighash message: {e}")))?;
            let mut sig = secp.sign_ecdsa(&msg, &sk).serialize_der().to_vec();
            sig.push(EcdsaSighashType::All as u8);
            witnesses.push((index, vec![sig, pk.to_bytes()]));
        }
    }
    for (index, witness) in witnesses {
        tx.input[index].witness.script_witness = witness;
    }

    Ok(TakeSingleBuild {
        tx,
        change: change_legs,
        own_selected: selected.into_iter().cloned().collect(),
    })
}

/// Self-check: the final transaction must satisfy the confidential
/// balance equation and all range/surjection proofs against its prevouts.
fn self_check_amounts(
    secp: &Secp256k1<All>,
    built: &TakeSingleBuild,
    maker_in_secrets: &TxOutSecrets,
) -> Result<(), TemplarError> {
    // Prevout commitments recomputed from secrets: deep verification has
    // already proven the maker's leg matches the on-chain prevout. The
    // maker prevout's script pubkey is unused by the amount/proof check.
    let mut spent: Vec<TxOut> = vec![prevout_from_secrets(secp, maker_in_secrets, &Script::new())];
    for utxo in &built.own_selected {
        spent.push(prevout_from_secrets(
            secp,
            &utxo.unblinded,
            &utxo.script_pubkey,
        ));
    }
    built.tx.verify_tx_amt_proofs(secp, &spent).map_err(|e| {
        TemplarError::from(LiquidError::PsetBuildFailed(format!(
            "self-check failed (verify_tx_amt_proofs): {e}"
        )))
    })
}

// ---------------------------------------------------------------------------
// Cancel
// ---------------------------------------------------------------------------

/// Builds a fully-signed cancel transaction: a self-spend of the offered
/// UTXO (`"txid:vout"`), which double-spends the proposal's input and thereby
/// invalidates the offer. Offline — broadcast with [`broadcast_transaction_on`].
pub fn build_cancel_tx(
    manager: &LiquidWalletManager,
    utxo: &str,
) -> Result<Transaction, TemplarError> {
    let outpoint = parse_outpoint(utxo)?;
    let utxos = manager
        .wollet
        .utxos()
        .map_err(|e| LiquidError::PsetBuildFailed(format!("utxos: {e}")))?;
    let target = utxos
        .iter()
        .find(|u| u.outpoint == outpoint && !u.is_spent)
        .ok_or_else(|| {
            TemplarError::from(LiquidError::PsetBuildFailed(format!(
                "UTXO {utxo} not found in wallet (already spent?)"
            )))
        })?;
    let policy_asset = manager.policy_asset();
    let self_address = manager
        .wollet
        .address(None)
        .map_err(|e| LiquidError::PsetBuildFailed(format!("address: {e}")))?
        .address()
        .clone();

    let mut builder = manager.wollet.tx_builder();
    if target.unblinded.asset == policy_asset {
        builder = builder
            .set_wallet_utxos(vec![outpoint])
            .drain_lbtc_wallet()
            .drain_lbtc_to(self_address);
    } else {
        // Spend the offered token UTXO fully to ourselves; allow L-BTC
        // UTXOs to fund the fee.
        let mut allowed: Vec<OutPoint> = vec![outpoint];
        allowed.extend(
            utxos
                .iter()
                .filter(|u| !u.is_spent && u.unblinded.asset == policy_asset)
                .map(|u| u.outpoint),
        );
        builder = builder.set_wallet_utxos(allowed).add_validated_recipient(
            lwk_wollet::Recipient::from_address(
                target.unblinded.value,
                &self_address,
                target.unblinded.asset,
            ),
        );
    }
    let mut pset = builder
        .finish()
        .map_err(|e| LiquidError::PsetBuildFailed(format!("cancel tx build: {e}")))?;
    let signatures = manager.sign(&mut pset)?;
    if signatures == 0 {
        return Err(LiquidError::SigningFailed("no signatures added".into()).into());
    }
    manager.finalize(&mut pset)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use lwk_wollet::elements::hashes::{sha256d, Hash};

    /// Real mainnet proposal, id 9 from the liquidex.it book
    /// (DBEER 1000 sats → 1000 sats L-BTC).
    const FIXTURE_9: &str = r#"{"version":0,"tx":"02000000010162457676604122dc2c3ab6b9ac5a787411cc90f07edd8651c656fd5ed5dfd45c000000001716001461362b692acf41e26c88c58abcd633cbbe06f420feffffff010b90f4a0ea769100ad4200aabb115f6ead24ba5180eea84f231f3c51c047f02f57092c307774be067befd563d6eb23ca185f963e22f9e96b3f224e94d28ed3cd2fd2020ea96dbab999be940e62be9ff1d8525f354730a3546d71a70696e1f40082996c17a914ea94f77a850e4b018d67c8c4ba087977ec63e1db8700000000000002473044022053a7107a113adffe78e556aa5fa0391b3a2301277630d77febd5398f7a834d520220484feb14c5b0b313759b79501a36d471985b5fe33a346cbcd3d059a0d32214a283210247fa74dbe2fe4f4d0d8e5cc16573f097cb9909670eedd733b50f37e343c9b08a000000","inputs":[{"asset":"002452cb8f56a0a5628240edfb3d1e966c9b1959adcfb95b5726e5e9688611bf","asset_blinder":"10abf182945667b6aae98a79535b91f2343eb6a920d8d99d3de06fa024e38c77","amount_blinder":"6cce12bfa4cd11818de662104e61f6be53275e21c343e984bb06c6749669ad2f","amount":1000}],"outputs":[{"asset":"6f0279e9ed041c3d710a9f57d0c02928416460c4b722ae3457a11eec381c526d","asset_blinder":"e8bfdc63d9750f16a2934b42466c1bfd171e5f3bcd8eafcd9e3ef954cf8a6d58","amount_blinder":"8e2d5cb748d14d5edb06643da6b05208671fbca875682a67690e3436d3ceb22a","amount":1000}]}"#;

    /// Real mainnet proposal, id 12 from the liquidex.it book
    /// (SCAM 100 sats → 10000 sats L-BTC).
    const FIXTURE_12: &str = r#"{"version":0,"tx":"020000000101369cad9338ac2e18a578f776017c033a94a2de1f9c99c7f1dc104c808de119320100000017160014faa46a00f7c1da2b2849d8da527d75ac2eaa02ecfeffffff010a69a83c9812cc5db6f17705bec234c7f2db944fb97a2d505218ee95ba0fcbf3d2084d57fa29588eafcaeba6406ac5cf30fbf61b45b82f62b6e38c3fcb9a7afabcd6020e007f598d79146add5278b9c8682937cb39cb30472810044e0a16b5072ed5d417a914b6b3813b25aa72c568bd3bc9ce1598f628aa3c3d8700000000000002473044022040be95060db855044daa5de5d1a779159d8f572b4bfd2cc081669cc336401708022018070ceebc77c72164c2228cafd40601253b776df08d813c057fcbe4defdf718832103d5cd246942cec54a46855481f587b11c87fb2acbc3694c85811c3b9f477b00ea000000","inputs":[{"asset":"123465c803ae336c62180e52d94ee80d80828db54df9bedbb9860060f49de2eb","asset_blinder":"278a034a31a45006592a95f165c3a7265e342b16428c24b95e2cfecbf2b0f3e2","amount_blinder":"954b1aff411fb09d26d8c144077598bb9b4ee5d64582abbe882917a5bca98ebb","amount":100}],"outputs":[{"asset":"6f0279e9ed041c3d710a9f57d0c02928416460c4b722ae3457a11eec381c526d","asset_blinder":"c07137aeeda9aca3567b6aa506c773dd524b959fe4d4e3f245380f7c3158452a","amount_blinder":"1f478cd6bc57051f3783a847669600b60ac4db70f1967211dfba7f3b6c0c3a5d","amount":10000}]}"#;

    fn check(result: &VerifyResult, name: &str) -> Option<bool> {
        result
            .checks
            .iter()
            .find(|c| c.name == name)
            .unwrap_or_else(|| panic!("missing check {name}"))
            .ok
    }

    // -- wire conventions ---------------------------------------------------

    #[test]
    fn blinder_hex_is_reversed_vs_byte_serialization() {
        // Elements Core displays blinding factors byte-reversed. Prove that
        // our parse path (FromStr) consumes the display convention: the
        // internal bytes must equal the reversed raw hex decode.
        let display_hex = "10abf182945667b6aae98a79535b91f2343eb6a920d8d99d3de06fa024e38c77";
        let parsed = AssetBlindingFactor::from_str(display_hex).unwrap();
        let mut raw = hex::decode(display_hex).unwrap();
        raw.reverse();
        assert_eq!(parsed.into_inner().as_ref(), raw.as_slice());
        // ...and that serialization restores the display hex unchanged.
        assert_eq!(parsed.to_string(), display_hex);

        let vbf = ValueBlindingFactor::from_str(display_hex).unwrap();
        assert_eq!(vbf.into_inner().as_ref(), raw.as_slice());
        assert_eq!(vbf.to_string(), display_hex);
    }

    #[test]
    fn proposal_round_trip_parse_serialize() {
        for fixture in [FIXTURE_9, FIXTURE_12] {
            let parsed = LiquidexProposal::from_json(fixture).unwrap();
            let json = parsed.to_json().unwrap();
            let reparsed = LiquidexProposal::from_json(&json).unwrap();
            assert_eq!(parsed, reparsed);
            // Blinder strings must survive the round trip byte-for-byte
            // (reversal applied once per direction).
            let original: serde_json::Value = serde_json::from_str(fixture).unwrap();
            let restored: serde_json::Value = serde_json::from_str(&json).unwrap();
            assert_eq!(original, restored);
        }
    }

    #[test]
    fn leg_secrets_round_trip_through_elements_types() {
        let proposal = LiquidexProposal::from_json(FIXTURE_9).unwrap();
        let secrets = proposal.input_secrets().unwrap();
        let leg = secrets_to_leg(&secrets);
        assert_eq!(leg, proposal.inputs[0]);
        let secrets_out = proposal.output_secrets().unwrap();
        let leg_out = secrets_to_leg(&secrets_out);
        assert_eq!(leg_out, proposal.outputs[0]);
    }

    // -- offline verification on real mainnet data --------------------------

    #[test]
    fn fixture_9_offline_verify_passes() {
        let proposal = LiquidexProposal::from_json(FIXTURE_9).unwrap();
        let result = verify_proposal(&proposal, false).unwrap();
        assert_eq!(check(&result, "structure"), Some(true));
        assert_eq!(check(&result, "sighash_single_acp"), Some(true));
        assert_eq!(check(&result, "output_commitments"), Some(true));
        assert_eq!(check(&result, "input_commitments"), None);
        assert_eq!(check(&result, "input_unspent"), None);
        assert_eq!(check(&result, "signature"), None);
        assert!(result.valid);
        assert_eq!(result.network, SwapNetwork::Mainnet);
        assert!(!result.takeable);
        assert!(result.take_block_reason.is_some());
        assert_eq!(result.maker_offers.amount_sats, 1000);
        assert_eq!(result.maker_wants.amount_sats, 1000);
        assert_eq!(result.maker_wants.asset_id, LBTC_MAINNET_ASSET_ID);
    }

    #[test]
    fn fixture_12_offline_verify_passes() {
        let proposal = LiquidexProposal::from_json(FIXTURE_12).unwrap();
        let result = verify_proposal(&proposal, false).unwrap();
        assert_eq!(check(&result, "structure"), Some(true));
        assert_eq!(check(&result, "sighash_single_acp"), Some(true));
        assert_eq!(check(&result, "output_commitments"), Some(true));
        assert!(result.valid);
        assert_eq!(result.network, SwapNetwork::Mainnet);
        assert!(!result.takeable);
        assert_eq!(result.maker_offers.amount_sats, 100);
        assert_eq!(result.maker_wants.amount_sats, 10000);
    }

    #[test]
    fn tampered_amount_fails_output_commitments() {
        let mut proposal = LiquidexProposal::from_json(FIXTURE_9).unwrap();
        proposal.outputs[0].amount += 1;
        let result = verify_proposal(&proposal, false).unwrap();
        assert_eq!(check(&result, "output_commitments"), Some(false));
        assert!(!result.valid);
        assert!(!result.takeable);
    }

    #[test]
    fn tampered_blinder_fails_output_commitments() {
        let mut proposal = LiquidexProposal::from_json(FIXTURE_9).unwrap();
        // Flip the first byte of the displayed asset blinder.
        let mut blinder = proposal.outputs[0].asset_blinder.clone();
        blinder.replace_range(0..2, if &blinder[0..2] == "00" { "01" } else { "00" });
        proposal.outputs[0].asset_blinder = blinder;
        let result = verify_proposal(&proposal, false).unwrap();
        assert_eq!(check(&result, "output_commitments"), Some(false));
        assert!(!result.valid);
    }

    #[test]
    fn structure_rejects_amount_above_max_money() {
        let mut proposal = LiquidexProposal::from_json(FIXTURE_9).unwrap();
        proposal.outputs[0].amount = u64::MAX - 200;
        let result = verify_proposal(&proposal, false).unwrap();
        assert_eq!(check(&result, "structure"), Some(false));
        assert!(!result.valid);
        assert!(!result.takeable);
    }

    #[test]
    fn structure_rejects_extra_witness_items() {
        let proposal = LiquidexProposal::from_json(FIXTURE_9).unwrap();
        let mut tx = proposal.transaction().unwrap();
        // Junk third item: txid-invisible, but consensus-invalid for p2wpkh.
        tx.input[0].witness.script_witness.push(vec![0x00]);
        let tampered = LiquidexProposal {
            tx: serialize_hex(&tx),
            ..proposal
        };
        let result = verify_proposal(&tampered, false).unwrap();
        assert_eq!(check(&result, "structure"), Some(false));
        assert!(!result.valid);
    }

    #[test]
    fn mainnet_leg_wins_over_testnet_leg() {
        // A proposal offering testnet L-BTC while wanting mainnet L-BTC must
        // classify as mainnet, not testnet — otherwise it looks takeable.
        let mut proposal = LiquidexProposal::from_json(FIXTURE_9).unwrap();
        proposal.inputs[0].asset = LBTC_TESTNET_ASSET_ID.to_string();
        proposal.outputs[0].asset = LBTC_MAINNET_ASSET_ID.to_string();
        assert_eq!(detect_network(&proposal), SwapNetwork::Mainnet);
    }

    #[test]
    fn fee_rate_is_bounded() {
        assert!(sanitize_fee_rate(Some(f32::INFINITY)).is_err());
        assert!(sanitize_fee_rate(Some(f32::NAN)).is_err());
        assert!(sanitize_fee_rate(Some(1e9)).is_err());
        // Below the relay floor is lifted to it; sane rates pass through.
        assert_eq!(sanitize_fee_rate(Some(1.0)).unwrap(), DEFAULT_FEE_RATE_KVB);
        assert_eq!(sanitize_fee_rate(None).unwrap(), DEFAULT_FEE_RATE_KVB);
        assert_eq!(sanitize_fee_rate(Some(500.0)).unwrap(), 500.0);
    }

    #[test]
    fn structure_rejects_bad_version_and_arrays() {
        let mut proposal = LiquidexProposal::from_json(FIXTURE_9).unwrap();
        proposal.version = 1;
        let result = verify_proposal(&proposal, false).unwrap();
        assert_eq!(check(&result, "structure"), Some(false));
        assert!(!result.valid);

        let mut proposal = LiquidexProposal::from_json(FIXTURE_9).unwrap();
        proposal.inputs.push(proposal.inputs[0].clone());
        let result = verify_proposal(&proposal, false).unwrap();
        assert_eq!(check(&result, "structure"), Some(false));
    }

    #[test]
    fn network_heuristic_detects_testnet_mainnet_unknown() {
        let mut proposal = LiquidexProposal::from_json(FIXTURE_9).unwrap();
        assert_eq!(detect_network(&proposal), SwapNetwork::Mainnet);
        proposal.outputs[0].asset = LBTC_TESTNET_ASSET_ID.to_string();
        assert_eq!(detect_network(&proposal), SwapNetwork::Testnet);
        proposal.outputs[0].asset = proposal.inputs[0].asset.clone();
        assert_eq!(detect_network(&proposal), SwapNetwork::Unknown);
    }

    #[test]
    fn regtest_policy_asset_is_only_recognised_on_a_regtest_wallet() {
        let regtest = LiquidNetwork::regtest_default();
        let mut proposal = LiquidexProposal::from_json(FIXTURE_9).unwrap();
        proposal.inputs[0].asset = "aa".repeat(32);
        proposal.outputs[0].asset = regtest.policy_asset_hex();
        // A testnet wallet has no idea what that asset is.
        assert_eq!(detect_network(&proposal), SwapNetwork::Unknown);
        assert_eq!(detect_network_on(&proposal, &regtest), SwapNetwork::Regtest);
        // Mainnet still wins on either.
        proposal.inputs[0].asset = LBTC_MAINNET_ASSET_ID.to_string();
        assert_eq!(detect_network_on(&proposal, &regtest), SwapNetwork::Mainnet);
        assert_eq!(SwapNetwork::of(&regtest), SwapNetwork::Regtest);
        assert_eq!(
            SwapNetwork::of(&LiquidNetwork::testnet()),
            SwapNetwork::Testnet
        );
    }

    #[test]
    fn mainnet_offer_is_refused_with_the_local_network_named() {
        let proposal = LiquidexProposal::from_json(FIXTURE_9).unwrap();
        let result =
            verify_proposal_on(&proposal, false, &LiquidNetwork::regtest_default()).unwrap();
        assert_eq!(result.network, SwapNetwork::Mainnet);
        assert!(!result.takeable);
        let reason = result.take_block_reason.unwrap();
        assert!(reason.contains("regtest"), "{reason}");
    }

    // -- synthetic make → verify → take round trip (fully offline) ----------

    struct SynthWallet {
        utxos: Vec<WalletTxOut>,
        keys: Vec<(SecretKey, PublicKey)>,
    }

    impl SynthWallet {
        fn key_for(&self, utxo: &WalletTxOut) -> Result<(SecretKey, PublicKey), TemplarError> {
            for (i, u) in self.utxos.iter().enumerate() {
                if u.outpoint == utxo.outpoint {
                    return Ok(self.keys[i]);
                }
            }
            Err(LiquidError::SigningFailed("unknown synthetic utxo".into()).into())
        }
    }

    fn synth_txid(tag: &[u8]) -> Txid {
        Txid::from_raw_hash(sha256d::Hash::hash(tag))
    }

    fn synth_asset(tag: &[u8]) -> AssetId {
        AssetId::from_slice(sha256d::Hash::hash(tag).as_byte_array()).unwrap()
    }

    fn synth_address<R: RngCore + CryptoRng>(rng: &mut R, secp: &Secp256k1<All>) -> Address {
        let spend_pk = PublicKey::new(SecretKey::new(rng).public_key(secp));
        let blind_pk = SecretKey::new(rng).public_key(secp);
        Address::p2wpkh(&spend_pk, Some(blind_pk), &AddressParams::LIQUID_TESTNET)
    }

    fn synth_utxo<R: RngCore + CryptoRng>(
        rng: &mut R,
        secp: &Secp256k1<All>,
        asset: AssetId,
        value: u64,
        vout: u32,
        tag: &[u8],
    ) -> (WalletTxOut, (SecretKey, PublicKey)) {
        let sk = SecretKey::new(rng);
        let pk = PublicKey::new(sk.public_key(secp));
        let script_pubkey = p2wpkh_script_pubkey(&pk);
        let unblinded = TxOutSecrets::new(
            asset,
            AssetBlindingFactor::new(rng),
            value,
            ValueBlindingFactor::new(rng),
        );
        let blind_pk = SecretKey::new(rng).public_key(secp);
        let address = Address::p2wpkh(&pk, Some(blind_pk), &AddressParams::LIQUID_TESTNET);
        let utxo = WalletTxOut {
            outpoint: OutPoint::new(synth_txid(tag), vout),
            script_pubkey,
            height: None,
            unblinded,
            wildcard_index: 0,
            ext_int: Chain::External,
            is_spent: false,
            address,
        };
        (utxo, (sk, pk))
    }

    #[test]
    fn make_offline_roundtrip_verifies() {
        let secp = Secp256k1::new();
        let mut rng = rand::thread_rng();
        let asset_a = synth_asset(b"asset-a");
        let asset_w = synth_asset(b"asset-w");

        let (utxo, (sk, pk)) = synth_utxo(&mut rng, &secp, asset_a, 5000, 0, b"maker-prev");
        let receive = synth_address(&mut rng, &secp);
        let proposal =
            make_proposal_core(&mut rng, &secp, &utxo, &sk, &pk, &receive, asset_w, 700).unwrap();

        // Wire round trip.
        let json = proposal.to_json().unwrap();
        let reparsed = LiquidexProposal::from_json(&json).unwrap();
        assert_eq!(proposal, reparsed);

        // Offline verification must pass all three offline checks.
        let result = verify_proposal(&reparsed, false).unwrap();
        assert_eq!(check(&result, "structure"), Some(true));
        assert_eq!(check(&result, "sighash_single_acp"), Some(true));
        assert_eq!(check(&result, "output_commitments"), Some(true));
        assert!(result.valid);
        assert_eq!(result.network, SwapNetwork::Unknown);
        assert_eq!(result.maker_offers.amount_sats, 5000);
        assert_eq!(result.maker_wants.amount_sats, 700);

        // The maker signature must verify against the (synthetic) prevout —
        // this exercises the same code path deep verification uses on chain
        // data, proving the signature itself and not just the 0x83 byte.
        let tx = reparsed.transaction().unwrap();
        let prevout = prevout_from_secrets(&secp, &utxo.unblinded, &utxo.script_pubkey);
        verify_maker_signature(&secp, &tx, &prevout).unwrap();
    }

    #[test]
    fn take_offline_roundtrip_balances_and_proves() {
        let secp = Secp256k1::new();
        let mut rng = rand::thread_rng();
        let policy = AssetId::from_str(LBTC_TESTNET_ASSET_ID).unwrap();
        let asset_a = synth_asset(b"take-asset-a"); // maker offers A
        let asset_w = synth_asset(b"take-asset-w"); // maker wants W

        // Maker: offers 5000 of A, wants 700 of W.
        let (maker_utxo, (maker_sk, maker_pk)) =
            synth_utxo(&mut rng, &secp, asset_a, 5000, 1, b"take-maker-prev");
        let maker_receive = synth_address(&mut rng, &secp);
        let proposal = make_proposal_core(
            &mut rng,
            &secp,
            &maker_utxo,
            &maker_sk,
            &maker_pk,
            &maker_receive,
            asset_w,
            700,
        )
        .unwrap();

        // Taker wallet: 1000 of W (change expected) and 10000 L-BTC for fee.
        let (utxo_w, key_w) = synth_utxo(&mut rng, &secp, asset_w, 1000, 0, b"taker-w");
        let (utxo_l, key_l) = synth_utxo(&mut rng, &secp, policy, 10_000, 3, b"taker-l");
        let taker = SynthWallet {
            utxos: vec![utxo_w.clone(), utxo_l.clone()],
            keys: vec![key_w, key_l],
        };

        let mut addr_cache: HashMap<usize, Address> = HashMap::new();
        let mut rng_addr = rand::thread_rng();
        let secp_addr = Secp256k1::new();
        let mut next_addr = |slot: usize| -> Result<Address, TemplarError> {
            Ok(addr_cache
                .entry(slot)
                .or_insert_with(|| synth_address(&mut rng_addr, &secp_addr))
                .clone())
        };
        let key_for = |utxo: &WalletTxOut| -> Result<(SecretKey, PublicKey), TemplarError> {
            taker.key_for(utxo)
        };

        let build = build_take_tx_core(
            &mut rng,
            &secp,
            &proposal,
            &taker.utxos,
            policy,
            100.0,
            &mut next_addr,
            &key_for,
        )
        .unwrap();

        // Structure: maker in/out at 0; receive + W change + L-BTC change +
        // fee outputs; fee last and explicit.
        assert_eq!(build.tx.input.len(), 3);
        assert_eq!(
            build.tx.input[0].previous_output, maker_utxo.outpoint,
            "maker input must stay at index 0"
        );
        assert_eq!(build.tx.output.len(), 5);
        assert!(build.tx.output.last().unwrap().is_fee());
        assert_eq!(
            build.tx.output.last().unwrap().value.explicit().unwrap(),
            build.fee_sats
        );
        assert_eq!(build.you_receive.amount_sats, 5000);
        assert_eq!(build.you_receive.asset_id, asset_a.to_string());
        assert_eq!(build.you_pay.amount_sats, 700);
        assert_eq!(build.you_pay.asset_id, asset_w.to_string());
        assert_eq!(build.change.len(), 2);
        assert_eq!(build.change[0].amount_sats, 300); // 1000 W - 700 W
        assert_eq!(build.change[1].amount_sats, 10_000 - build.fee_sats);

        // The maker's SIGHASH_SINGLE|ANYONECANPAY signature must still be
        // valid on the extended transaction.
        let maker_prevout =
            prevout_from_secrets(&secp, &maker_utxo.unblinded, &maker_utxo.script_pubkey);
        verify_maker_signature(&secp, &build.tx, &maker_prevout).unwrap();

        // Full independent re-check of the balance equation and all
        // range/surjection proofs (the core already self-checked; assert
        // again here explicitly against the reconstructed prevouts).
        let spent = vec![
            maker_prevout,
            prevout_from_secrets(&secp, &utxo_w.unblinded, &utxo_w.script_pubkey),
            prevout_from_secrets(&secp, &utxo_l.unblinded, &utxo_l.script_pubkey),
        ];
        build.tx.verify_tx_amt_proofs(&secp, &spent).unwrap();

        // Maker output witness was rebuilt.
        assert!(build.tx.output[0].witness.rangeproof.is_some());
        assert!(build.tx.output[0].witness.surjection_proof.is_some());
    }

    #[test]
    fn take_insufficient_balance_errors() {
        let secp = Secp256k1::new();
        let mut rng = rand::thread_rng();
        let policy = AssetId::from_str(LBTC_TESTNET_ASSET_ID).unwrap();
        let asset_a = synth_asset(b"poor-asset-a");
        let asset_w = synth_asset(b"poor-asset-w");

        let (maker_utxo, (maker_sk, maker_pk)) =
            synth_utxo(&mut rng, &secp, asset_a, 5000, 1, b"poor-maker-prev");
        let maker_receive = synth_address(&mut rng, &secp);
        let proposal = make_proposal_core(
            &mut rng,
            &secp,
            &maker_utxo,
            &maker_sk,
            &maker_pk,
            &maker_receive,
            asset_w,
            700,
        )
        .unwrap();

        // Taker has L-BTC but none of the wanted asset.
        let (utxo_l, key_l) = synth_utxo(&mut rng, &secp, policy, 10_000, 3, b"poor-taker-l");
        let taker = SynthWallet {
            utxos: vec![utxo_l],
            keys: vec![key_l],
        };
        let mut next_addr = {
            let mut rng2 = rand::thread_rng();
            let secp2 = Secp256k1::new();
            move |_slot: usize| -> Result<Address, TemplarError> {
                Ok(synth_address(&mut rng2, &secp2))
            }
        };
        let key_for = |utxo: &WalletTxOut| -> Result<(SecretKey, PublicKey), TemplarError> {
            taker.key_for(utxo)
        };
        let err = build_take_tx_core(
            &mut rng,
            &secp,
            &proposal,
            &taker.utxos,
            policy,
            100.0,
            &mut next_addr,
            &key_for,
        )
        .unwrap_err();
        assert!(err.to_string().contains("insufficient balance"));
    }

    #[test]
    fn descriptor_origin_path_extraction() {
        assert_eq!(
            descriptor_origin_path(
                "ct(slip77(ab),elwpkh([73c5da0a/84'/1'/0']tpubD6NzV/<0;1>/*))#q"
            ),
            Some("84'/1'/0'".to_string())
        );
        assert_eq!(
            descriptor_origin_path("ct(slip77(ab),elwpkh([73c5da0a/84h/1h/0h]tpub/<0;1>/*))"),
            Some("84h/1h/0h".to_string())
        );
        assert_eq!(
            descriptor_origin_path("ct(slip77(ab),elwpkh(tpub/<0;1>/*))"),
            None
        );
    }

    #[test]
    fn parse_outpoint_accepts_txid_vout() {
        let op =
            parse_outpoint("5cd4dfd55efd56c65186dd7ef090cc1174785aacb9b63a2cdc22416076764562:0")
                .unwrap();
        assert_eq!(op.vout, 0);
        assert!(parse_outpoint("nonsense").is_err());
        assert!(parse_outpoint("abcd:x").is_err());
    }
}
