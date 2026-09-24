//! DTO types that cross the FFI boundary as JSON.
//! Must stay in sync with Flutter model classes.

// Hardware-only DTOs have no reader without the `hardware` feature.
#![cfg_attr(not(feature = "hardware"), allow(dead_code))]

use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Debug)]
pub struct TxPreviewDto {
    /// "bitcoin" | "liquid"
    pub chain: String,
    pub recipient_address: String,
    pub amount_display: String,
    pub fee_sats: i64,
    pub fee_display: String,
    pub total_display: String,
    /// Requested fee rate in sat/vB (0 for Liquid flat-fee sends).
    #[serde(default)]
    pub fee_rate: f64,
    /// Estimated virtual size of the signed transaction in vbytes.
    #[serde(default)]
    pub vsize_est: i64,
    /// Concrete coins the transaction will spend.
    #[serde(default)]
    pub inputs: Vec<TxIoDto>,
    /// All outputs including change (flagged via `is_change`).
    #[serde(default)]
    pub outputs: Vec<TxIoDto>,
}

/// One input or output of a previewed transaction, for the review diagram.
#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct TxIoDto {
    /// "txid:vout" for inputs; None for outputs.
    pub outpoint: Option<String>,
    pub address: String,
    pub amount_sats: i64,
    /// Output pays back to this wallet (change).
    pub is_change: bool,
    /// Liquid asset ID hex (None for Bitcoin).
    #[serde(default)]
    pub asset_id: Option<String>,
    /// Ticker for display ("L-BTC", token ticker); None for Bitcoin.
    #[serde(default)]
    pub ticker: Option<String>,
    /// Pre-formatted amount honoring the asset's precision.
    #[serde(default)]
    pub amount_display: Option<String>,
}

#[derive(Serialize, Deserialize, Debug)]
pub struct IssueResultDto {
    pub asset_id: String,
    pub token_id: Option<String>,
    pub txid: String,
    pub registry_registered: bool,
    /// URL where the domain proof file must be placed.
    pub proof_url: String,
    /// Content of the proof file (single line, plain text).
    pub proof_content: String,
}

#[derive(Deserialize, Debug)]
pub struct PreviewTxParams {
    pub wallet_id: String,
    #[serde(default)]
    pub address: String,
    #[serde(default)]
    pub amount_sats: i64,
    /// "BTC" → bitcoin chain; anything else = Liquid asset_id
    pub asset_id: String,
    /// sat/vB, used for BTC only
    pub fee_rate: f32,
    /// Multi-output form. When present, overrides `address`/`amount_sats`.
    #[serde(default)]
    pub outputs: Option<Vec<TxOutputSpec>>,
    /// Manual coin control: outpoints ("txid:vout") to spend. None = auto.
    #[serde(default)]
    pub utxos: Option<Vec<String>>,
}

/// One recipient of a transaction (multi-output sends).
#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct TxOutputSpec {
    pub address: String,
    pub amount_sats: i64,
    /// Per-output Liquid asset ID. None inherits the transaction-level
    /// `asset_id` (and is ignored on the Bitcoin chain).
    #[serde(default)]
    pub asset_id: Option<String>,
    /// Send the maximum available amount to this output. Bitcoin: drains the
    /// selected coins (or the whole wallet) minus fee. Liquid tokens: the full
    /// asset balance. L-BTC: balance minus fee. At most one output may set it.
    #[serde(default)]
    pub send_max: bool,
}

#[derive(Deserialize, Debug)]
pub struct SendTxParams {
    pub wallet_id: String,
    #[serde(default)]
    pub address: String,
    #[serde(default)]
    pub amount_sats: i64,
    pub asset_id: String,
    pub fee_rate: f32,
    #[serde(default)]
    pub outputs: Option<Vec<TxOutputSpec>>,
    #[serde(default)]
    pub utxos: Option<Vec<String>>,
}

#[derive(Deserialize, Debug)]
pub struct IssueAssetParams {
    pub wallet_id: String,
    pub name: String,
    pub ticker: String,
    pub precision: u8,
    pub domain: String,
    pub amount_sats: i64,
    pub reissuance_tokens: i64,
}

#[derive(Deserialize, Debug)]
pub struct ReissueAssetParams {
    pub wallet_id: String,
    pub asset_id: String,
    pub amount_sats: i64,
}

#[derive(Deserialize, Debug)]
pub struct BurnAssetParams {
    pub wallet_id: String,
    pub asset_id: String,
    pub amount_sats: i64,
}

#[derive(Deserialize, Debug)]
pub struct ReregisterAssetParams {
    pub wallet_id: String,
    pub asset_id: String,
    pub name: String,
    pub ticker: String,
    pub precision: u8,
    pub domain: String,
}

#[derive(Serialize, Deserialize, Debug)]
pub struct WalletSummaryDto {
    pub id: String,
    pub name: String,
    /// "singlesig" | "multisig" | "watch_only" | "policy"
    pub wallet_type: String,
    /// "testnet" | "mainnet"
    pub network: String,
    pub balance_sats: i64,
    pub tx_count: usize,
    /// Unix seconds
    pub last_sync_at: i64,
    pub is_watch_only: bool,
    pub type_label: String,
    /// Whether this wallet has a paired Liquid wallet enabled.
    pub liquid_enabled: bool,
    /// Whether this wallet has a Bitcoin side at all.
    ///
    /// False for a Liquid-only hardware entry. The UI needs it to hide the
    /// Bitcoin surfaces rather than offer a receive address that can only come
    /// back as "Bitcoin wallet not open".
    #[serde(default = "yes")]
    pub bitcoin_enabled: bool,
    /// Device model for hardware wallets ("Blockstream Jade", "Nano S",
    /// "air-gap"), so the picker can badge *which* kind of device this is.
    #[serde(default)]
    pub device_model: Option<String>,
    /// Public identity for the wallet picker — read straight from the registry
    /// (no wallet is opened): master fingerprint and the account xpub.
    #[serde(default)]
    pub master_fingerprint: Option<String>,
    #[serde(default)]
    pub xpub: Option<String>,
    /// Multisig threshold, for the picker's "2-of-3" label.
    #[serde(default)]
    pub required_sigs: Option<usize>,
    #[serde(default)]
    pub total_signers: Option<usize>,
}

/// Serde default for `bitcoin_enabled`: a wallet has Bitcoin unless it says
/// otherwise, which is the safe direction for older payloads.
fn yes() -> bool {
    true
}

/// Hand-written rather than derived so `..Default::default()` fills
/// `bitcoin_enabled` with `true`. Derived, every construction site that forgot
/// the field would silently produce a wallet with its Bitcoin side hidden.
impl Default for WalletSummaryDto {
    fn default() -> Self {
        Self {
            id: String::new(),
            name: String::new(),
            wallet_type: String::new(),
            network: String::new(),
            balance_sats: 0,
            tx_count: 0,
            last_sync_at: 0,
            is_watch_only: false,
            type_label: String::new(),
            liquid_enabled: false,
            bitcoin_enabled: true,
            device_model: None,
            master_fingerprint: None,
            xpub: None,
            required_sigs: None,
            total_signers: None,
        }
    }
}

#[derive(Serialize, Deserialize, Debug)]
pub struct AssetBalanceDto {
    pub asset_id: String,
    pub ticker: String,
    pub name: String,
    pub amount: i64,
    pub display_amount: String,
    pub fiat_estimate: Option<String>,
    pub status: String,
    pub utxo_count: usize,
    pub is_native: bool,
}

#[derive(Serialize, Deserialize, Debug)]
pub struct RecentActivityDto {
    pub txid: String,
    /// "incoming" | "outgoing" | "self"
    pub direction: String,
    /// "bitcoin" | "liquid" — Home splits recent activity per chain, and the
    /// ticker alone cannot carry that (a third-party Liquid token's ticker
    /// says nothing about which chain it lives on).
    pub chain: String,
    pub amount: String,
    pub ticker: String,
    pub timestamp: i64,
    pub confirmations: u32,
    pub note: Option<String>,
    pub counterparty: Option<String>,
}

#[derive(Serialize, Deserialize, Debug)]
pub struct DashboardDto {
    pub wallet_id: String,
    pub wallet_name: String,
    pub total_balance_display: String,
    pub sync_state: String,
    pub assets: Vec<AssetBalanceDto>,
    pub recent_activity: Vec<RecentActivityDto>,
    /// `liquid-testnet` | `liquid-regtest` — the network the Liquid side of
    /// this wallet is open on.
    #[serde(default)]
    pub liquid_network: String,
}

/// The active Liquid network and how the chain is reached.
#[derive(Serialize, Deserialize, Debug)]
pub struct LiquidNetworkDto {
    /// `liquid-testnet` | `liquid-regtest`.
    pub network: String,
    /// `testnet` | `regtest`.
    pub short_name: String,
    /// L-BTC asset id (hex) on this network.
    pub policy_asset: String,
    /// `electrum` | `elements_rpc`.
    pub backend: String,
    /// Backend endpoint without credentials, e.g.
    /// `electrum ssl://host:port` or `elements-rpc http://127.0.0.1:18884`.
    pub backend_description: String,
    /// True when `TEMPLAR_LIQUID_NETWORK` fixes the network for this run.
    pub env_locked: bool,
    /// Stock regtest policy asset, for the settings form's default.
    pub regtest_default_policy_asset: String,
}

#[derive(Deserialize, Debug)]
pub struct SetLiquidNetworkParams {
    /// `testnet` | `regtest` (long forms accepted).
    pub network: String,
    /// Regtest only; empty = the stock `liquidregtest` policy asset.
    #[serde(default)]
    pub policy_asset: Option<String>,
}

#[derive(Serialize, Deserialize, Debug)]
pub struct AddressInfoDto {
    pub address: String,
    pub index: u32,
    pub asset: String,
    pub label: Option<String>,
    pub received_sats: i64,
    pub derivation_path: Option<String>,
}

#[derive(Serialize, Deserialize, Debug)]
pub struct TransactionDto {
    pub txid: String,
    /// "incoming" | "outgoing" | "self"
    pub direction: String,
    /// "bitcoin" | "liquid"
    pub chain: String,
    pub amount: String,
    pub ticker: String,
    pub timestamp: i64,
    pub confirmations: u32,
    pub fee: Option<String>,
    pub note: Option<String>,
    pub counterparty: Option<String>,
    pub fiat_estimate: Option<String>,
}

#[derive(Serialize, Deserialize, Debug)]
pub struct UtxoDto {
    pub outpoint: String,
    pub amount: i64,
    pub display_amount: String,
    pub confirmations: u32,
    /// "available" | "frozen" | "dusty" | "unconfirmed"
    pub state: String,
    pub label: Option<String>,
    pub address: Option<String>,
    /// Ticker symbol, e.g. "BTC", "LBTC", or custom asset ticker
    pub ticker: Option<String>,
    /// Liquid asset ID hex (None for Bitcoin UTXOs)
    pub asset_id: Option<String>,
}

#[derive(Serialize, Deserialize, Debug)]
pub struct WalletInfoDto {
    pub id: String,
    pub name: String,
    pub network: String,
    pub master_fingerprint: String,
    pub derivation_path: String,
    pub script_type: String,
    pub xpub: String,
    pub receive_descriptor: String,
    pub change_descriptor: String,
    pub multipath_descriptor: Option<String>,
    pub liquid_descriptor: Option<String>,
    pub master_blinding_key: Option<String>,
    pub has_seed: bool,
    pub has_passphrase: bool,
    pub last_backup_at: Option<i64>,
    /// Cosigner xpubs in `[fingerprint/path]xpub` format (multisig only)
    pub cosigner_keys: Vec<String>,
    /// Signatures this wallet needs (the M of M-of-N). None for singlesig.
    /// Spelled out rather than parsed back out of `script_type`, which is a
    /// display string.
    #[serde(default)]
    pub required_sigs: Option<u32>,
    /// Fingerprints of the cosigner keys this app can sign with, so a roster
    /// can mark which of them lives on this device.
    #[serde(default)]
    pub local_fingerprints: Vec<String>,
    /// `liquid-testnet` | `liquid-regtest`.
    #[serde(default)]
    pub liquid_network: String,
}

/// Per-chain result of `sync_wallet`. Each field is `"ok"`, `"skipped"`
/// (wallet has no side on that chain), or `"error: <reason>"`. The call as a
/// whole only fails when the wallet itself could not be opened.
#[derive(Serialize, Deserialize, Debug)]
pub struct SyncOutcomeDto {
    pub btc: String,
    pub liquid: String,
}

/// Result of pairing a hardware wallet: the one wallet that was created, plus
/// everything the recap screen shows to prove the pairing actually worked.
///
/// One wallet, not two: a device that holds both chains is a single wallet with
/// a Bitcoin and a Liquid side, exactly like a software wallet. The earlier
/// shape created a second `"<name> (Liquid)"` entry whose Bitcoin descriptor
/// slot held a CT descriptor — a wallet whose every Bitcoin screen could only
/// error.
#[derive(Serialize, Deserialize, Debug)]
pub struct HwImportResultDto {
    pub wallet: WalletSummaryDto,
    /// Master fingerprint of the device both sides were read from.
    pub fingerprint: String,
    /// Model as the device reports it.
    pub device_model: String,
    /// The Bitcoin receive descriptor stored for this wallet.
    pub bitcoin_descriptor: String,
    /// The Liquid CT descriptor, when a Liquid side was created.
    pub liquid_descriptor: Option<String>,
    /// Why Liquid is missing, when it was asked for and could not be paired.
    /// Set together with `liquid_descriptor: None` — the Bitcoin wallet still
    /// exists, and the recap says which half is missing and why.
    pub liquid_error: Option<String>,
    /// Whether Liquid was requested at all, so the recap can tell "you asked
    /// for Bitcoin only" apart from "Liquid failed".
    pub liquid_requested: bool,
}

// Params structs for incoming calls

#[derive(Deserialize, Debug)]
pub struct OpenWalletParams {
    pub wallet_id: String,
}

#[derive(Deserialize, Debug)]
pub struct WalletIdParams {
    pub wallet_id: String,
}

#[derive(Deserialize, Debug)]
pub struct CreateMultisigParams {
    pub name: String,
    pub required_sigs: usize,
    pub total_signers: usize,
    /// Cosigner keys in `[fingerprint/path]xpub` format (no wildcard suffix).
    pub cosigner_xpubs: Vec<String>,
    /// Legacy single local signing key — superseded by `local_mnemonics`.
    #[serde(default)]
    pub local_mnemonic: Option<String>,
    /// Mnemonics of every key this device signs with; each must correspond
    /// to one of the xpubs. Empty/None = watch-only coordinator.
    #[serde(default)]
    pub local_mnemonics: Option<Vec<String>>,
    /// BIP87 cosigner keys (`[fp/87h/1h/0h]tpub…`) for the Liquid side, in the
    /// same order as `cosigner_xpubs`. Empty = Bitcoin-only wallet. Liquid
    /// derives from a different account than Bitcoin, so these are collected
    /// alongside — one cannot be computed from the other.
    #[serde(default)]
    pub liquid_xpubs: Vec<String>,
    /// How many of the cosigner keys can actually produce an Elements
    /// signature (keys held in this app, plus Jades). Below the threshold the
    /// Liquid side is refused, because its funds would be unspendable. `None`
    /// skips the check — the caller is asserting it already did it.
    #[serde(default)]
    pub liquid_capable_keys: Option<usize>,
}

#[derive(Deserialize, Debug)]
pub struct DeriveCosignerXpubParams {
    /// Space-separated BIP39 mnemonic phrase.
    pub mnemonic: String,
}

#[derive(Deserialize, Debug)]
pub struct GenerateAddressParams {
    pub wallet_id: String,
    pub asset: String,
    /// True = advance the derivation index ("New address" button). False (the
    /// default) = the current, last-unused address.
    #[serde(default)]
    pub fresh: bool,
}

#[derive(Deserialize, Debug)]
pub struct ListActivityParams {
    pub wallet_id: String,
}

#[derive(Deserialize, Debug)]
pub struct ListUtxosParams {
    pub wallet_id: String,
    pub chain: String,
}

/// Freezes (`frozen: true`) or unfreezes coins of one wallet on one chain.
#[derive(Deserialize, Debug)]
pub struct SetUtxosFrozenParams {
    pub wallet_id: String,
    /// "BTC" | "Liquid"
    pub chain: String,
    /// Each formatted "txid:vout".
    pub outpoints: Vec<String>,
    pub frozen: bool,
}

// ── PSBT DTOs ─────────────────────────────────────────────────────────────────

#[derive(Serialize, Deserialize, Debug)]
pub struct PsbtInputDto {
    pub outpoint: String,
    /// `None` when the PSBT gives no usable previous-output data — shown as
    /// "unknown", never as 0.
    pub amount_sats: Option<i64>,
    pub display_amount: String,
    /// `"ok"` | `"missing"` | `"conflicting"` (see `templar_core::UtxoStatus`).
    pub utxo_status: String,
    /// `None` when no wallet was open to judge.
    pub is_mine: Option<bool>,
}

#[derive(Serialize, Deserialize, Debug)]
pub struct PsbtOutputDto {
    pub address: String,
    pub amount_sats: i64,
    pub display_amount: String,
    pub is_mine: Option<bool>,
}

#[derive(Serialize, Deserialize, Debug)]
pub struct PsbtSignerDto {
    pub fingerprint: String,
    pub has_signed: bool,
}

#[derive(Serialize, Deserialize, Debug)]
pub struct PsbtInspectionDto {
    pub inputs: Vec<PsbtInputDto>,
    pub outputs: Vec<PsbtOutputDto>,
    /// `None` when any input amount is unknown.
    pub fee_sats: Option<i64>,
    pub fee_display: String,
    pub sigs_present: usize,
    pub sigs_required: Option<usize>,
    pub signers: Vec<PsbtSignerDto>,
    pub policy_hint: String,
    pub raw_psbt: String,
    /// Every input already finalized by some signer.
    pub finalized: bool,
    /// Worst input `utxo_status`; anything but `"ok"` is refused at signing.
    pub utxo_check: String,
    /// Whether the `is_mine` flags mean anything (a wallet was open).
    pub ownership_known: bool,
}

#[derive(Deserialize, Debug)]
pub struct InspectPsbtParams {
    pub psbt_base64: String,
}

/// `combine_psbts`: signed copies of one transaction, the one being handed
/// out first. Wallet-independent, unlike its PSET twin.
#[derive(Deserialize, Debug)]
pub struct CombinePsbtsParams {
    pub psbts: Vec<String>,
}

#[derive(Deserialize, Debug)]
pub struct SignPsbtParams {
    pub wallet_id: String,
    pub psbt_base64: String,
}

#[derive(Deserialize, Debug)]
pub struct BuildUnsignedPsbtParams {
    pub wallet_id: String,
    #[serde(default)]
    pub address: String,
    #[serde(default)]
    pub amount_sats: i64,
    /// Bitcoin-only path — defaults to empty (= BTC) for older callers, and is
    /// rejected by `ensure_bitcoin_asset` when a Liquid asset is passed.
    #[serde(default)]
    pub asset_id: String,
    pub fee_rate: f32,
    #[serde(default)]
    pub outputs: Option<Vec<TxOutputSpec>>,
    #[serde(default)]
    pub utxos: Option<Vec<String>>,
}

#[derive(Deserialize, Debug)]
pub struct BroadcastSignedPsbtParams {
    pub wallet_id: String,
    pub psbt_base64: String,
}

/// One output of a PSET, decoded for review before signing.
#[derive(Serialize, Deserialize, Debug)]
pub struct PsetRecipientDto {
    /// Confidential address, when the script could be decoded.
    pub address: Option<String>,
    pub asset_id: Option<String>,
    /// Resolved ticker (`L-BTC`, a token symbol) when the asset is known.
    pub ticker: Option<String>,
    pub amount_sats: Option<i64>,
    /// Amount formatted with the asset's precision.
    pub display_amount: Option<String>,
    /// The PSET's amount/asset for this output could not be verified against
    /// its commitments; `amount_sats` and `asset_id` are then `None`.
    pub unverified: bool,
}

/// A decoded PSET: what it pays, what it costs, and who still has to sign.
/// One PSET input from the wallet's side (see `PsetInputInfo`).
#[derive(Serialize, Deserialize, Debug)]
pub struct PsetInputDto {
    pub index: u32,
    pub outpoint: String,
    pub is_ours: bool,
    pub script_type: String,
    pub witness_script: Option<String>,
    pub witness_script_asm: Option<String>,
    pub asset_id: Option<String>,
    pub ticker: Option<String>,
    pub amount_sats: Option<i64>,
    pub display_amount: Option<String>,
    pub key_fingerprints: Vec<String>,
    pub signed_by: Vec<String>,
    /// `k` of a `k-of-n` multisig witness script, when the input is one.
    #[serde(default)]
    pub threshold: Option<u32>,
    /// Neither the wallet nor a blind proof vouches for this coin's amount.
    pub unverified: bool,
}

/// One PSET output, classified (`own` | `escrow` | `external` | `fee`).
#[derive(Serialize, Deserialize, Debug)]
pub struct PsetOutputDto {
    pub index: u32,
    pub kind: String,
    pub script_type: String,
    pub address: Option<String>,
    pub asset_id: Option<String>,
    pub ticker: Option<String>,
    pub amount_sats: Option<i64>,
    pub display_amount: Option<String>,
    /// See [`PsetRecipientDto::unverified`].
    pub unverified: bool,
}

#[derive(Serialize, Deserialize, Debug)]
pub struct PsetInspectionDto {
    /// `liquid-testnet` | `liquid-regtest` — the wallet's network. A PSET
    /// carrying another network's assets is refused before this is built.
    #[serde(default)]
    pub network: String,
    pub fee_sats: i64,
    pub fee_display: String,
    pub recipients: Vec<PsetRecipientDto>,
    /// Every input, with whether it asks for this wallet's signature.
    #[serde(default)]
    pub inputs: Vec<PsetInputDto>,
    /// Every output, classified from the wallet's side.
    #[serde(default)]
    pub outputs: Vec<PsetOutputDto>,
    /// Signatures on the least-signed input — the count that must reach
    /// `sigs_needed`.
    pub sigs_have: u32,
    pub sigs_needed: u32,
    pub signers_present: Vec<String>,
    /// Every key that has not signed. On an M-of-N wallet the N-M keys that
    /// never sign stay listed here, so this is "who could still sign".
    pub signers_missing: Vec<String>,
    pub can_finalize: bool,
    pub raw_pset: String,
    /// Some non-fee output claims an amount or asset its commitment does not
    /// prove. Signing is refused while this is true.
    pub has_unverified_outputs: bool,
    /// What this wallet gains (positive) or pays (negative) per asset id,
    /// from LWK's own unblinding — the one figure a PSET cannot misstate.
    pub net_change: std::collections::BTreeMap<String, i64>,
}

#[derive(Deserialize, Debug)]
pub struct PsetParams {
    pub wallet_id: String,
    pub pset_base64: String,
}

#[derive(Deserialize, Debug)]
pub struct CombinePsetsParams {
    pub wallet_id: String,
    /// Signed copies of the same transaction, including the original.
    pub psets: Vec<String>,
}

#[derive(Deserialize, Debug)]
pub struct GenerateMnemonicParams {
    pub word_count: usize,
}

#[derive(Deserialize, Debug)]
pub struct CreateWalletParams {
    pub name: String,
    /// Space-separated BIP39 mnemonic phrase.
    pub mnemonic: String,
    /// Whether to enable a paired Liquid wallet. Defaults to false (Bitcoin only).
    #[serde(default)]
    pub liquid: bool,
}

#[derive(Deserialize, Debug)]
pub struct ConsolidateUtxosParams {
    pub wallet_id: String,
    /// Outpoints to consolidate, each formatted "txid:vout".
    pub outpoints: Vec<String>,
    /// "BTC" | "liquid" — only "BTC" is currently supported.
    pub chain: String,
    pub fee_rate: f32,
}

#[derive(Deserialize, Debug)]
pub struct HwFingerprintParams {
    pub fingerprint: String,
}

/// Create a Liquid-only wallet from a connected Blockstream Jade.
#[derive(Deserialize, Debug)]
pub struct ImportJadeLiquidParams {
    pub name: String,
}

/// Sign an arbitrary PSBT with a connected USB device — the multisig
/// co-signing path, independent of which wallet is open.
#[derive(Deserialize, Debug)]
pub struct SignPsbtHwParams {
    pub fingerprint: String,
    pub psbt_base64: String,
}

#[derive(Deserialize, Debug)]
pub struct DeriveLiquidDescriptorParams {
    /// Bare xpub/tpub or a wpkh(...) Bitcoin descriptor.
    pub btc_desc: String,
}

#[derive(Deserialize, Debug)]
pub struct SetHwiPathParams {
    pub path: String,
}

#[derive(Deserialize, Debug)]
pub struct ImportHwWalletParams {
    pub name: String,
    pub fingerprint: String,
    /// If true, also create a paired Liquid watch-only wallet.
    #[serde(default)]
    pub liquid: bool,
}

#[derive(Deserialize, Debug)]
pub struct CreateWatchOnlyParams {
    pub name: String,
    pub recv_desc: String,
    #[serde(default)]
    pub change_desc: String,
    /// Optional Liquid CT descriptor — pairs a Liquid watch-only wallet.
    #[serde(default)]
    pub liquid_ct_desc: String,
    /// True when created from the air-gap flow (signs via QR); false for a
    /// pure watch-only wallet (no spending at all).
    #[serde(default)]
    pub airgap: bool,
}

#[derive(Deserialize, Debug)]
pub struct RenameWalletParams {
    pub wallet_id: String,
    pub new_name: String,
}

#[derive(Deserialize, Debug)]
pub struct DeleteWalletParams {
    pub wallet_id: String,
}

#[derive(Deserialize, Debug)]
pub struct VerifyHwAddressParams {
    pub wallet_id: String,
}

#[derive(Deserialize, Debug)]
pub struct VerifyBackupParams {
    pub wallet_id: String,
    /// The phrase the user typed off their paper backup. Never logged, never
    /// stored — derived from, compared, dropped.
    pub mnemonic: String,
}

#[derive(Debug, Deserialize)]
pub struct VaultPassphraseParams {
    pub passphrase: String,
}

/// `unlock_vault_with_key`: the vault key a previous `export_vault_key` handed
/// out, as it comes back from the platform keystore — 64 hex characters.
/// No `Debug`: this *is* the key, and must never reach a log line.
#[derive(Deserialize)]
pub struct VaultKeyParams {
    pub key_hex: String,
}

#[derive(Deserialize, Debug)]
pub struct UrPsbtEncodeParams {
    pub psbt_base64: String,
    /// Bytes per QR fragment; smaller = denser animation, easier scanning.
    #[serde(default = "default_fragment_len")]
    pub max_fragment_len: usize,
}

fn default_fragment_len() -> usize {
    100
}

/// `ur_pset_encode`: a Liquid PSET as animated `ur:bytes` frames — Templar's
/// own QR transport for one, since the UR registry has no PSET type.
#[derive(Deserialize, Debug)]
pub struct UrPsetEncodeParams {
    pub pset_base64: String,
    #[serde(default = "default_fragment_len")]
    pub max_fragment_len: usize,
}

#[derive(Deserialize, Debug)]
pub struct ValidateCosignerKeyParams {
    /// Whatever is in the field: a bare keyorigin key, a scanned descriptor,
    /// a Coldcard/Jade export with `h` for hardened steps.
    pub key: String,
    /// Check it as the Liquid (BIP87) key rather than the Bitcoin (BIP48) one.
    #[serde(default)]
    pub liquid: bool,
}

#[derive(Deserialize, Debug)]
pub struct UrDecodePartsParams {
    /// Every QR payload scanned so far, in any order (fountain-coded).
    pub parts: Vec<String>,
}
