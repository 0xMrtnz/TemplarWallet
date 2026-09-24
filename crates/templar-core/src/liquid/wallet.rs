//! Liquid wallet manager using LWK (Liquid Wallet Kit) 0.9.
//!
//! Uses `Wollet::without_persist()` for in-memory wallets,
//! `Wollet::get_details()` for PSET inspection,
//! `Wollet::finalize()` for transaction finalization, and
//! `Wollet::combine()` for parallel signing assembly.
//!
//! Thread-safe — no RefCell issues like BDK.

use std::collections::{BTreeSet, HashMap};

use base64::Engine;
use lwk_common::Signer;
use lwk_signer::SwSigner;
use lwk_wollet::{
    elements::{
        encode::{Decodable, Encodable},
        Address, AssetId,
    },
    ElementsNetwork, Recipient, Wollet, WolletDescriptor,
};
use serde_json::json;
use std::path::Path;

use crate::error::{LiquidError, TemplarError};
use crate::frozen::first_frozen;
use crate::liquid::chain::LiquidChain;
use crate::liquid::network::LiquidNetwork;
use crate::liquid::pset::{PsetInputInfo, PsetOutputInfo};

/// A Partially Signed Elements Transaction — Liquid's PSBT.
///
/// Aliased here so callers can name one without taking a direct dependency on
/// LWK's module layout.
pub type Pset = lwk_wollet::elements::pset::PartiallySignedTransaction;
use crate::liquid::assets::IssuanceResult;
use crate::liquid::pset::PsetDetails;

/// Electrum server for Liquid testnet. Lives in `liquid::chain` now; kept
/// here so the historical import path keeps working.
pub use crate::liquid::chain::LIQUID_ELECTRUM_URL;

/// Multi-asset balance for a Liquid wallet.
#[derive(Debug, Clone, Default)]
pub struct LiquidBalance {
    /// Map of asset_id → amount in satoshis.
    pub assets: HashMap<String, u64>,
    /// L-BTC asset id (hex) of the network this balance was read on. Empty
    /// on a value built by hand, which then means Liquid testnet.
    pub policy_asset: String,
}

impl LiquidBalance {
    /// The L-BTC asset id this balance counts as "L-BTC".
    pub fn policy_asset_id(&self) -> &str {
        if self.policy_asset.is_empty() {
            crate::liquid::assets::LBTC_ASSET_ID
        } else {
            &self.policy_asset
        }
    }

    /// Returns the L-BTC balance in satoshis (the policy asset of the
    /// network the wallet was read on).
    pub fn lbtc(&self) -> u64 {
        *self.assets.get(self.policy_asset_id()).unwrap_or(&0)
    }

    /// Returns the L-USDT balance in satoshis.
    pub fn lusdt(&self) -> u64 {
        *self
            .assets
            .get(crate::liquid::assets::LUSDT_ASSET_ID)
            .unwrap_or(&0)
    }

    /// Returns the balance for a specific asset.
    pub fn get(&self, asset_id: &str) -> u64 {
        *self.assets.get(asset_id).unwrap_or(&0)
    }
}

/// A Liquid transaction with multi-asset balance deltas.
#[derive(Debug, Clone)]
pub struct LiquidTx {
    pub txid: String,
    /// Balance delta per asset (positive = received, negative = sent).
    pub balance: HashMap<String, i64>,
    pub fee: u64,
    pub height: Option<u32>,
    pub timestamp: Option<u64>,
}

/// Liquid wallet engine backed by LWK 0.9.
///
/// Supports singlesig and multisig with CT descriptors.
/// Signer is optional — `None` for watch-only wallets.
/// Thread-safe (no RefCell).
pub struct LiquidWalletManager {
    pub wollet: Wollet,
    pub signer: Option<SwSigner>,
    pub descriptor: String,
}

/// Returns the compressed 33-byte issuer public key from a software signer.
///
/// Used as the `issuer_pubkey` field in the Liquid asset contract.
/// The key is derived from the signer's root xpub so it is deterministic
/// and tied to the wallet's seed.
fn issuer_pubkey_bytes(signer: &SwSigner) -> Vec<u8> {
    let key = signer.xpub().public_key.serialize().to_vec();
    eprintln!(
        "[Issuance] Derived issuer pubkey (hex): {}",
        hex::encode(&key)
    );
    key
}

/// POSTs the asset contract to the Liquid testnet asset registry.
///
/// Uses LWK's own `serde_json::to_value(&contract)` so the canonical JSON
/// (alphabetical keys, hex issuer_pubkey via `serialize_with = "serde_to_hex"`)
/// is byte-for-byte identical to what LWK committed during issuance — ensuring
/// the registry's SHA256 check passes.
///
/// Best-effort: failure is logged but does not affect the on-chain issuance.
/// Returns `true` if the registry accepted the submission (HTTP 2xx).
fn register_asset_contract(asset_id: &str, contract: &lwk_wollet::Contract) -> bool {
    let contract_value = match serde_json::to_value(contract) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("[Registry] Contract serialization failed: {}", e);
            return false;
        }
    };

    let body = json!({"asset_id": asset_id, "contract": contract_value});

    let url = "https://assets-testnet.blockstream.info/";
    eprintln!(
        "[Registry] POST {} — asset_id={} name={} ticker={}",
        url, asset_id, contract.name, contract.ticker
    );
    eprintln!(
        "[Registry] Contract JSON: {}",
        serde_json::to_string(&contract_value).unwrap_or_default()
    );

    match reqwest::blocking::Client::new()
        .post(url)
        .json(&body)
        .send()
    {
        Ok(resp) if resp.status().is_success() => {
            eprintln!("[Registry] Asset {} registered successfully", asset_id);
            true
        }
        Ok(resp) => {
            let status = resp.status();
            let body_text = resp.text().unwrap_or_default();
            eprintln!(
                "[Registry] Registration failed for {}: HTTP {} — {}",
                asset_id, status, body_text
            );
            false
        }
        Err(e) => {
            eprintln!(
                "[Registry] Registration request failed for {}: {}",
                asset_id, e
            );
            false
        }
    }
}

/// Fetches an asset's registry entry from the Liquid testnet registry.
///
/// Best-effort: used after registration to verify the contract was accepted.
fn fetch_asset_contract_testnet(asset_id: &str) -> Result<serde_json::Value, String> {
    let url = format!("https://assets-testnet.blockstream.info/{}", asset_id);
    eprintln!("[Registry] Fetching asset: {}", url);
    let resp = reqwest::blocking::get(&url).map_err(|e| e.to_string())?;
    if !resp.status().is_success() {
        return Err(format!("registry fetch failed: HTTP {}", resp.status()));
    }
    resp.json::<serde_json::Value>().map_err(|e| e.to_string())
}

/// Fetches asset metadata from the Liquid testnet registry for a given asset_id.
///
/// Returns `None` if the asset is not registered, the request fails, or the
/// response is missing required fields. Always best-effort — never panics.
/// Testnet only: see [`fetch_asset_metadata_on`] for the network-aware form.
pub fn fetch_asset_metadata(asset_id: &str) -> Option<crate::liquid::assets::AssetMetadata> {
    fetch_asset_metadata_on(&LiquidNetwork::testnet(), asset_id)
}

/// [`fetch_asset_metadata`] for a given network. A local regtest has no
/// public registry, so the answer there is always `None` — without a
/// network round-trip to a server that could only describe testnet assets.
pub fn fetch_asset_metadata_on(
    network: &LiquidNetwork,
    asset_id: &str,
) -> Option<crate::liquid::assets::AssetMetadata> {
    if network.is_regtest() {
        return None;
    }
    let val = fetch_asset_contract_testnet(asset_id).ok()?;
    let name = val.get("name")?.as_str()?.to_string();
    let ticker = val
        .get("ticker")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());
    let precision = val.get("precision").and_then(|v| v.as_u64()).unwrap_or(8) as u8;
    let domain = val
        .get("entity")
        .and_then(|e| e.get("domain"))
        .and_then(|d| d.as_str())
        .map(|s| s.to_string());
    Some(crate::liquid::assets::AssetMetadata {
        asset_id: asset_id.to_string(),
        name,
        ticker,
        precision,
        domain,
        is_reissuance_token: false,
        parent_asset_id: None,
    })
}

/// A builder failure, with a hint when frozen coins are what made the
/// wallet look short: the balance still counts them, the builder does not.
fn frozen_hint(
    variant: fn(String) -> LiquidError,
    what: &str,
    e: lwk_wollet::Error,
    frozen: &BTreeSet<String>,
) -> TemplarError {
    if !frozen.is_empty() && matches!(e, lwk_wollet::Error::InsufficientFunds) {
        return variant(format!(
            "{what}: {e} — frozen coins are left out; unfreeze some on the UTXOs \
             screen to spend them"
        ))
        .into();
    }
    variant(format!("{what}: {e}")).into()
}

/// Refuses a PSET that spends a frozen coin: the check a PSET built
/// elsewhere (a cosigner, a protocol site) meets before this wallet signs
/// it, and the backstop behind every builder here. `avoidable` says
/// whether the builder could have left the coin out — it picks the message.
pub fn refuse_frozen_inputs(
    pset: &lwk_wollet::elements::pset::PartiallySignedTransaction,
    frozen: &BTreeSet<String>,
    avoidable: bool,
) -> Result<(), TemplarError> {
    let spent = pset
        .inputs()
        .iter()
        .map(|i| format!("{}:{}", i.previous_txid, i.previous_output_index));
    match first_frozen(spent, frozen) {
        Some(op) if avoidable => Err(LiquidError::FrozenCoin(op).into()),
        Some(op) => Err(LiquidError::FrozenCoinUnavoidable(op).into()),
        None => Ok(()),
    }
}

impl LiquidWalletManager {
    fn make_wollet(
        network: ElementsNetwork,
        descriptor: WolletDescriptor,
        data_dir: Option<&Path>,
    ) -> Result<Wollet, TemplarError> {
        match data_dir {
            Some(dir) => match Wollet::with_fs_persist(network, descriptor.clone(), dir) {
                Ok(w) => Ok(w),
                // The on-disk LWK cache can become inconsistent with the descriptor
                // (e.g. "Update created on a wallet with status X while current has Y"),
                // typically after a crash. The cache is a pure optimisation:
                // delete it and retry persistence once, so re-opens stay fast
                // for good instead of silently degrading to in-memory forever.
                Err(e) => {
                    eprintln!("[liquid] fs-persist load failed ({e}); clearing cache and retrying");
                    let cache = dir.join(network.as_str()).join("enc_cache");
                    let _ = std::fs::remove_dir_all(&cache);
                    match Wollet::with_fs_persist(network, descriptor.clone(), dir) {
                        Ok(w) => Ok(w),
                        Err(e2) => {
                            eprintln!(
                                "[liquid] fs-persist retry failed ({e2}); falling back to \
                                 in-memory (the wallet will re-scan)"
                            );
                            Wollet::without_persist(network, descriptor).map_err(|e| {
                                LiquidError::InvalidDescriptor(format!(
                                    "Wollet::without_persist: {e}"
                                ))
                                .into()
                            })
                        }
                    }
                }
            },
            None => Wollet::without_persist(network, descriptor).map_err(|e| {
                LiquidError::InvalidDescriptor(format!("Wollet::without_persist: {e}")).into()
            }),
        }
    }

    /// Creates a new Liquid wallet from a mnemonic and CT descriptor.
    /// Pass `data_dir` to enable incremental file-based persistence (faster re-opens).
    pub fn new(mnemonic_str: &str, ct_descriptor_str: &str) -> Result<Self, TemplarError> {
        Self::new_with_persist(mnemonic_str, ct_descriptor_str, None)
    }

    /// Like [`Self::new_with_persist_on`] on the network the environment
    /// selects (`TEMPLAR_LIQUID_NETWORK`, default testnet).
    pub fn new_with_persist(
        mnemonic_str: &str,
        ct_descriptor_str: &str,
        data_dir: Option<&Path>,
    ) -> Result<Self, TemplarError> {
        Self::new_with_persist_on(
            &LiquidNetwork::from_env(),
            mnemonic_str,
            ct_descriptor_str,
            data_dir,
        )
    }

    /// Creates a signing wallet on `network` from a mnemonic and CT
    /// descriptor. The LWK cache under `data_dir` is namespaced per network
    /// (`<data_dir>/liquid-testnet`, `<data_dir>/liquid-regtest`), so the two
    /// never share a cache.
    pub fn new_with_persist_on(
        network: &LiquidNetwork,
        mnemonic_str: &str,
        ct_descriptor_str: &str,
        data_dir: Option<&Path>,
    ) -> Result<Self, TemplarError> {
        let network = network.elements();

        let descriptor: WolletDescriptor = ct_descriptor_str
            .parse()
            .map_err(|e| LiquidError::InvalidDescriptor(format!("Parse descriptor: {e}")))?;
        let descriptor_string = descriptor.to_string();

        let signer = SwSigner::new(mnemonic_str, false)
            .map_err(|e| LiquidError::InvalidDescriptor(format!("SwSigner: {e}")))?;

        let wollet = Self::make_wollet(network, descriptor, data_dir)?;

        Ok(Self {
            wollet,
            signer: Some(signer),
            descriptor: descriptor_string,
        })
    }

    /// Creates a Liquid wallet from a mnemonic, auto-generating a WPKH SLIP77 descriptor.
    pub fn from_mnemonic(mnemonic_str: &str) -> Result<Self, TemplarError> {
        Self::from_mnemonic_with_persist(mnemonic_str, None)
    }

    /// Like [`Self::from_mnemonic_with_persist_on`] on the network the
    /// environment selects (`TEMPLAR_LIQUID_NETWORK`, default testnet).
    pub fn from_mnemonic_with_persist(
        mnemonic_str: &str,
        data_dir: Option<&Path>,
    ) -> Result<Self, TemplarError> {
        Self::from_mnemonic_with_persist_on(&LiquidNetwork::from_env(), mnemonic_str, data_dir)
    }

    /// Creates a Liquid wallet on `network` from a mnemonic, auto-generating
    /// the WPKH SLIP77 descriptor. The coin type is 1 on both testnet and
    /// regtest, so one seed yields the same descriptor on either.
    pub fn from_mnemonic_with_persist_on(
        network: &LiquidNetwork,
        mnemonic_str: &str,
        data_dir: Option<&Path>,
    ) -> Result<Self, TemplarError> {
        let desc = Self::default_ct_descriptor(mnemonic_str)?;
        Self::new_with_persist_on(network, mnemonic_str, &desc, data_dir)
    }

    /// The default single-sig CT descriptor of a mnemonic:
    /// `ct(slip77(<seed key>),elwpkh([fp/84h/1h/0h]tpub…/<0;1>/*))`.
    pub fn default_ct_descriptor(mnemonic_str: &str) -> Result<String, TemplarError> {
        use lwk_common::{DescriptorBlindingKey, Singlesig};
        let signer = SwSigner::new(mnemonic_str, false)
            .map_err(|e| LiquidError::InvalidDescriptor(format!("SwSigner: {e}")))?;
        lwk_common::singlesig_desc(
            &signer,
            Singlesig::Wpkh,
            DescriptorBlindingKey::Slip77,
            false,
        )
        .map_err(|e| LiquidError::InvalidDescriptor(format!("singlesig_desc: {e}")).into())
    }

    /// Creates a Liquid wallet from a saved CT descriptor (wallet reopen).
    pub fn from_descriptor(mnemonic_str: &str, descriptor_str: &str) -> Result<Self, TemplarError> {
        Self::new_with_persist(mnemonic_str, descriptor_str, None)
    }

    pub fn from_descriptor_with_persist(
        mnemonic_str: &str,
        descriptor_str: &str,
        data_dir: Option<&Path>,
    ) -> Result<Self, TemplarError> {
        Self::new_with_persist(mnemonic_str, descriptor_str, data_dir)
    }

    /// [`Self::from_descriptor_with_persist`] on an explicit network.
    pub fn from_descriptor_with_persist_on(
        network: &LiquidNetwork,
        mnemonic_str: &str,
        descriptor_str: &str,
        data_dir: Option<&Path>,
    ) -> Result<Self, TemplarError> {
        Self::new_with_persist_on(network, mnemonic_str, descriptor_str, data_dir)
    }

    /// Creates a watch-only Liquid wallet (no signing capability).
    pub fn watch_only(descriptor_str: &str) -> Result<Self, TemplarError> {
        Self::watch_only_with_persist(descriptor_str, None)
    }

    /// Like [`Self::watch_only_with_persist_on`] on the network the
    /// environment selects (`TEMPLAR_LIQUID_NETWORK`, default testnet).
    pub fn watch_only_with_persist(
        descriptor_str: &str,
        data_dir: Option<&Path>,
    ) -> Result<Self, TemplarError> {
        Self::watch_only_with_persist_on(&LiquidNetwork::from_env(), descriptor_str, data_dir)
    }

    /// Creates a watch-only Liquid wallet on `network`.
    pub fn watch_only_with_persist_on(
        network: &LiquidNetwork,
        descriptor_str: &str,
        data_dir: Option<&Path>,
    ) -> Result<Self, TemplarError> {
        let network = network.elements();

        let descriptor: WolletDescriptor = descriptor_str
            .parse()
            .map_err(|e| LiquidError::InvalidDescriptor(format!("Parse descriptor: {e}")))?;

        let wollet = Self::make_wollet(network, descriptor, data_dir)?;

        Ok(Self {
            wollet,
            signer: None,
            descriptor: descriptor_str.to_string(),
        })
    }

    /// Whether this wallet can sign transactions.
    pub fn can_sign(&self) -> bool {
        self.signer.is_some()
    }

    /// The network this wallet was opened on (read from the LWK wallet, so a
    /// manager built by hand reports the truth too). Mainnet is an error.
    pub fn network(&self) -> Result<LiquidNetwork, TemplarError> {
        LiquidNetwork::from_elements(self.wollet.network())
    }

    /// The LWK network value this wallet was opened on.
    pub fn elements_network(&self) -> ElementsNetwork {
        self.wollet.network()
    }

    /// L-BTC asset id of this wallet's network.
    pub fn policy_asset(&self) -> AssetId {
        self.wollet.policy_asset()
    }

    /// L-BTC asset id of this wallet's network, hex.
    pub fn policy_asset_hex(&self) -> String {
        self.wollet.policy_asset().to_string()
    }

    /// The chain backend for this wallet's network, as the environment
    /// configures it (`TEMPLAR_LIQUID_BACKEND` and friends).
    pub fn chain(&self) -> Result<LiquidChain, TemplarError> {
        LiquidChain::from_env(&self.network()?)
    }

    /// Syncs with the chain backend of this wallet's network (Electrum on
    /// testnet, `elementsd` RPC on regtest by default).
    pub fn sync(&mut self) -> Result<(), TemplarError> {
        let chain = self.chain()?;
        chain.sync(&mut self.wollet)
    }

    /// Syncs through an explicit chain handle (its network must match).
    pub fn sync_with(&mut self, chain: &LiquidChain) -> Result<(), TemplarError> {
        chain.sync(&mut self.wollet)
    }

    /// Returns the multi-asset balance.
    pub fn get_balance(&self) -> Result<LiquidBalance, TemplarError> {
        let raw = self
            .wollet
            .balance()
            .map_err(|e| LiquidError::SyncFailed(format!("Balance: {e}")))?;
        let mut bal = LiquidBalance {
            policy_asset: self.policy_asset_hex(),
            ..LiquidBalance::default()
        };
        for (asset_id, amount) in raw {
            bal.assets.insert(asset_id.to_string(), amount);
        }
        Ok(bal)
    }

    /// Generates a new confidential receive address.
    pub fn get_new_address(&self) -> Result<String, TemplarError> {
        let info = self
            .wollet
            .address(None)
            .map_err(|e| LiquidError::SyncFailed(format!("Address: {e}")))?;
        Ok(info.address().to_string())
    }

    /// Lists external receive addresses that have received at least one
    /// output (including outputs since spent).
    ///
    /// Returns `(address, derivation_index, lbtc_received_sats)` per distinct
    /// address, sorted by derivation index. `lbtc_received_sats` counts only
    /// L-BTC — an address that only ever received tokens reports 0.
    pub fn list_received_external_addresses(
        &self,
    ) -> Result<Vec<(String, u32, u64)>, TemplarError> {
        use lwk_wollet::Chain;
        let txos = self
            .wollet
            .txos()
            .map_err(|e| LiquidError::SyncFailed(format!("Txos: {e}")))?;
        let policy_asset = self.policy_asset();
        let mut by_index: std::collections::BTreeMap<u32, (String, u64)> =
            std::collections::BTreeMap::new();
        for txo in txos {
            if txo.ext_int != Chain::External {
                continue;
            }
            let entry = by_index
                .entry(txo.wildcard_index)
                .or_insert_with(|| (txo.address.to_string(), 0));
            if txo.unblinded.asset == policy_asset {
                entry.1 += txo.unblinded.value;
            }
        }
        Ok(by_index
            .into_iter()
            .map(|(index, (address, sats))| (address, index, sats))
            .collect())
    }

    /// Lists all transactions, sorted by block height (newest first).
    pub fn list_transactions(&self) -> Result<Vec<LiquidTx>, TemplarError> {
        let txs = self
            .wollet
            .transactions()
            .map_err(|e| LiquidError::SyncFailed(format!("Transactions: {e}")))?;
        let mut result: Vec<LiquidTx> = txs
            .into_iter()
            .map(|tx| {
                let balance: HashMap<String, i64> = tx
                    .balance
                    .iter()
                    .map(|(asset, amount)| (asset.to_string(), *amount))
                    .collect();
                LiquidTx {
                    txid: tx.txid.to_string(),
                    balance,
                    fee: tx.fee,
                    height: tx.height,
                    timestamp: tx.timestamp.map(|t| t as u64),
                }
            })
            .collect();
        result.sort_by(|a, b| {
            b.height
                .unwrap_or(u32::MAX)
                .cmp(&a.height.unwrap_or(u32::MAX))
        });
        Ok(result)
    }

    /// Builds an unsigned PSET (Partially Signed Elements Transaction).
    ///
    /// Supports both confidential and unconfidential recipient addresses.
    pub fn create_tx(
        &self,
        recipient: &str,
        amount: u64,
        asset_id: &str,
    ) -> Result<lwk_wollet::elements::pset::PartiallySignedTransaction, TemplarError> {
        self.create_tx_multi(
            &[(recipient.to_string(), amount, asset_id.to_string())],
            None,
            &BTreeSet::new(),
        )
    }

    /// Builds an unsigned PSET paying multiple recipients, each with its own
    /// asset — one Liquid transaction can move L-BTC and tokens together.
    /// Recipients are `(address, amount, asset_id)` triples.
    ///
    /// `drain_lbtc_to` implements "send MAX L-BTC": every L-BTC input is
    /// selected and whatever is left after the fixed recipients and the fee
    /// lands at that address (LWK `drain_lbtc_wallet` + `drain_lbtc_to`).
    ///
    /// `frozen` coins are left out when the payment moves only L-BTC. When
    /// it moves another asset, LWK 0.9 picks every input itself (and takes
    /// all L-BTC coins for the fee), so a PSET that would spend a frozen
    /// coin is refused instead.
    pub fn create_tx_multi(
        &self,
        recipients: &[(String, u64, String)],
        drain_lbtc_to: Option<&str>,
        frozen: &BTreeSet<String>,
    ) -> Result<lwk_wollet::elements::pset::PartiallySignedTransaction, TemplarError> {
        if recipients.is_empty() && drain_lbtc_to.is_none() {
            return Err(LiquidError::PsetBuildFailed("No recipients".into()).into());
        }
        // Address params follow the wallet's own network, so a testnet
        // address pasted into a regtest wallet (or the reverse) is refused
        // here instead of producing an unspendable output.
        let params = self.wollet.network().address_params();

        let policy_asset = self.wollet.policy_asset();
        let mut only_lbtc = true;
        let mut builder = self.wollet.tx_builder();
        for (recipient, amount, asset_id) in recipients {
            let address = Address::parse_with_params(recipient, params)
                .map_err(|e| LiquidError::PsetBuildFailed(format!("Invalid address: {e}")))?;
            let asset: AssetId = asset_id
                .parse()
                .map_err(|e| LiquidError::PsetBuildFailed(format!("Invalid asset: {e}")))?;
            only_lbtc &= asset == policy_asset;
            builder =
                builder.add_validated_recipient(Recipient::from_address(*amount, &address, asset));
        }
        if let Some(drain_addr) = drain_lbtc_to {
            let address = Address::parse_with_params(drain_addr, params)
                .map_err(|e| LiquidError::PsetBuildFailed(format!("Invalid drain address: {e}")))?;
            builder = builder.drain_lbtc_wallet().drain_lbtc_to(address);
        }
        if only_lbtc {
            if let Some(coins) = self.lbtc_coins_excluding(frozen)? {
                builder = builder.set_wallet_utxos(coins);
            }
        }
        let pset = builder
            .finish()
            .map_err(|e| frozen_hint(LiquidError::PsetBuildFailed, "Build PSET", e, frozen))?;
        refuse_frozen_inputs(&pset, frozen, only_lbtc)?;
        Ok(pset)
    }

    /// The wallet's L-BTC coins minus the frozen ones, for LWK's manual
    /// selection — `None` when nothing is frozen, so the builder keeps its
    /// own selection untouched.
    fn lbtc_coins_excluding(
        &self,
        frozen: &BTreeSet<String>,
    ) -> Result<Option<Vec<lwk_wollet::elements::OutPoint>>, TemplarError> {
        if frozen.is_empty() {
            return Ok(None);
        }
        let policy_asset = self.wollet.policy_asset();
        let coins = self
            .wollet
            .utxos()
            .map_err(|e| LiquidError::PsetBuildFailed(format!("utxos: {e}")))?
            .into_iter()
            .filter(|u| u.unblinded.asset == policy_asset)
            .filter(|u| !frozen.contains(&u.outpoint.to_string()))
            .map(|u| u.outpoint)
            .collect();
        Ok(Some(coins))
    }

    /// Inspects a PSET and returns structured details for display.
    ///
    /// Uses `Wollet::get_details()` to extract fee, recipients, and signer
    /// status, then adds the script view: every input with whether it asks
    /// for this wallet's signature (and its witness script when it is a
    /// P2WSH contract), every output classified as own / escrow / external /
    /// fee, and the network. A PSET whose explicit assets belong to another
    /// network is refused outright — signing it would be signing for a chain
    /// this wallet is not on.
    pub fn inspect_pset(
        &self,
        pset: &lwk_wollet::elements::pset::PartiallySignedTransaction,
    ) -> Result<PsetDetails, TemplarError> {
        let network = self.network()?;
        self.check_pset_network(pset, &network)?;
        let details = self
            .wollet
            .get_details(pset)
            .map_err(|e| LiquidError::PsetInspectionFailed(e.to_string()))?;
        crate::liquid::pset::refuse_non_testnet_paths(pset, &self.our_fingerprints())?;
        let mut details = PsetDetails::from_lwk(details);
        details.network = network.name().to_string();
        details.inputs = self.describe_inputs(pset);
        details.outputs = self.describe_outputs(pset)?;
        // LWK copied every foreign output's explicit fields unchecked; a
        // recipient row must not repeat a number the output view refused.
        for r in &mut details.recipients {
            if details
                .outputs
                .iter()
                .any(|o| o.index == r.vout && o.unverified)
            {
                r.asset = None;
                r.amount = None;
                r.unverified = true;
            }
        }
        Ok(details)
    }

    /// Refuses a PSET that carries another network's L-BTC — explicitly on
    /// an input, a prevout or an output, or as the fee asset. Assets the
    /// wallet cannot place (tokens, blinded fields) are not judged.
    fn check_pset_network(
        &self,
        pset: &lwk_wollet::elements::pset::PartiallySignedTransaction,
        network: &LiquidNetwork,
    ) -> Result<(), TemplarError> {
        use crate::liquid::liquidex::{LBTC_MAINNET_ASSET_ID, LBTC_TESTNET_ASSET_ID};
        use crate::liquid::network::REGTEST_DEFAULT_POLICY_ASSET;
        let ours = network.policy_asset();
        let foreign: Vec<(AssetId, &str)> = [
            (LBTC_MAINNET_ASSET_ID, "Liquid mainnet"),
            (LBTC_TESTNET_ASSET_ID, "Liquid testnet"),
            (REGTEST_DEFAULT_POLICY_ASSET, "Liquid regtest"),
        ]
        .into_iter()
        .filter_map(|(id, name)| id.parse::<AssetId>().ok().map(|id| (id, name)))
        .filter(|(id, _)| *id != ours)
        .collect();

        let mut explicit: Vec<AssetId> = Vec::new();
        for input in pset.inputs() {
            explicit.extend(input.asset);
            if let Some(utxo) = &input.witness_utxo {
                explicit.extend(utxo.asset.explicit());
            }
        }
        for output in pset.outputs() {
            explicit.extend(output.asset);
        }
        // A known L-BTC of another network anywhere: name it.
        for asset in &explicit {
            if let Some((_, name)) = foreign.iter().find(|(id, _)| id == asset) {
                return Err(LiquidError::NetworkMismatch(format!(
                    "this PSET carries {name} L-BTC, but the wallet is on {network}"
                ))
                .into());
            }
        }
        // The fee must be paid in this network's L-BTC — a fee in an unknown
        // asset means a chain this wallet does not know at all.
        for output in pset.outputs() {
            if output.script_pubkey.is_empty() {
                if let Some(fee_asset) = output.asset {
                    if fee_asset != ours {
                        return Err(LiquidError::NetworkMismatch(format!(
                            "the fee is paid in {fee_asset}, not this network's L-BTC — \
                             this PSET was built for another network (wallet is on {network})"
                        ))
                        .into());
                    }
                }
            }
        }
        Ok(())
    }

    /// Master fingerprints this wallet signs with: the software signer's and
    /// every key origin in the descriptor (a watch-only wallet still knows
    /// whose keys it watches).
    fn our_fingerprints(&self) -> std::collections::BTreeSet<String> {
        let mut fps: std::collections::BTreeSet<String> = self
            .wollet
            .signers()
            .iter()
            .map(|fp| fp.to_string())
            .collect();
        if let Some(signer) = &self.signer {
            fps.insert(signer.fingerprint().to_string());
        }
        fps
    }

    /// LWK's ownership rule: a derivation path's last index, applied to the
    /// wallet descriptor, reproduces the script. Plus every script the wallet
    /// has already received on, for outputs that carry no derivation.
    pub(crate) fn script_is_ours(
        &self,
        script: &lwk_wollet::elements::Script,
        bip32_derivation: &std::collections::BTreeMap<
            lwk_wollet::bitcoin::PublicKey,
            lwk_wollet::bitcoin::bip32::KeySource,
        >,
        known: &std::collections::HashSet<lwk_wollet::elements::Script>,
    ) -> bool {
        if known.contains(script) {
            return true;
        }
        let Ok(singles) = self
            .wollet
            .descriptor()
            .descriptor
            .clone()
            .into_single_descriptors()
        else {
            return false;
        };
        for (_, path) in bip32_derivation.values() {
            let Some(last) = path.into_iter().last() else {
                continue;
            };
            let index = u32::from(*last);
            for d in &singles {
                if let Ok(definite) = d.at_derivation_index(index) {
                    if &definite.script_pubkey() == script {
                        return true;
                    }
                }
            }
        }
        false
    }

    fn describe_inputs(
        &self,
        pset: &lwk_wollet::elements::pset::PartiallySignedTransaction,
    ) -> Vec<PsetInputInfo> {
        let ours = self.our_fingerprints();
        let secp = lwk_wollet::elements::secp256k1_zkp::Secp256k1::new();
        // The wallet's own coins: what it unblinded itself, not what the PSET
        // says about them.
        let own: HashMap<lwk_wollet::elements::OutPoint, (lwk_wollet::elements::AssetId, u64)> =
            self.wollet
                .txos()
                .map(|txos| {
                    txos.into_iter()
                        .map(|t| (t.outpoint, (t.unblinded.asset, t.unblinded.value)))
                        .collect()
                })
                .unwrap_or_default();
        pset.inputs()
            .iter()
            .enumerate()
            .map(|(index, input)| {
                let spk = input.witness_utxo.as_ref().map(|o| &o.script_pubkey);
                let script_type = match spk {
                    Some(s) if s.is_v0_p2wsh() => "p2wsh",
                    Some(s) if s.is_v0_p2wpkh() => "p2wpkh",
                    Some(s) if s.is_p2sh() => "p2sh",
                    Some(_) => "other",
                    None => "unknown",
                };
                let mut key_fingerprints: Vec<String> = input
                    .bip32_derivation
                    .values()
                    .map(|(fp, _)| fp.to_string())
                    .collect();
                key_fingerprints.sort();
                key_fingerprints.dedup();
                let is_ours = key_fingerprints.iter().any(|fp| ours.contains(fp));
                let mut signed_by: Vec<String> = input
                    .partial_sigs
                    .keys()
                    .filter_map(|pk| input.bip32_derivation.get(pk))
                    .map(|(fp, _)| fp.to_string())
                    .collect();
                signed_by.sort();
                signed_by.dedup();
                let outpoint = lwk_wollet::elements::OutPoint::new(
                    input.previous_txid,
                    input.previous_output_index,
                );
                let claims = own
                    .get(&outpoint)
                    .copied()
                    .or_else(|| crate::liquid::pset::verified_input_claims(&secp, input));
                let unverified = claims.is_none();
                let asset = claims.map(|(a, _)| a.to_string());
                let amount = claims.map(|(_, v)| v);
                PsetInputInfo {
                    index: index as u32,
                    outpoint: format!("{}:{}", input.previous_txid, input.previous_output_index),
                    is_ours,
                    script_type: script_type.to_string(),
                    witness_script: input
                        .witness_script
                        .as_ref()
                        .map(|s| hex::encode(s.as_bytes())),
                    witness_script_asm: input.witness_script.as_ref().map(|s| s.asm()),
                    asset,
                    amount,
                    unverified,
                    key_fingerprints,
                    signed_by,
                    threshold: input
                        .witness_script
                        .as_ref()
                        .and_then(|s| crate::liquid::pset::multisig_threshold(s.as_bytes())),
                }
            })
            .collect()
    }

    fn describe_outputs(
        &self,
        pset: &lwk_wollet::elements::pset::PartiallySignedTransaction,
    ) -> Result<Vec<PsetOutputInfo>, TemplarError> {
        let params = self.wollet.network().address_params();
        let secp = lwk_wollet::elements::secp256k1_zkp::Secp256k1::new();
        let known: std::collections::HashSet<lwk_wollet::elements::Script> = self
            .wollet
            .txos()
            .map_err(|e| LiquidError::PsetInspectionFailed(format!("txos: {e}")))?
            .into_iter()
            .map(|t| t.script_pubkey)
            .collect();
        Ok(pset
            .outputs()
            .iter()
            .enumerate()
            .map(|(index, output)| {
                let spk = &output.script_pubkey;
                let claims = crate::liquid::pset::verified_output_claims(&secp, output);
                let unverified = claims.is_none();
                let asset = claims.map(|(a, _)| a.to_string());
                let amount = claims.map(|(_, v)| v);
                if spk.is_empty() {
                    return PsetOutputInfo {
                        index: index as u32,
                        kind: "fee".to_string(),
                        script_type: "fee".to_string(),
                        address: None,
                        asset,
                        amount,
                        unverified,
                    };
                }
                let script_type = if spk.is_v0_p2wsh() {
                    "p2wsh"
                } else if spk.is_v0_p2wpkh() {
                    "p2wpkh"
                } else if spk.is_p2sh() {
                    "p2sh"
                } else {
                    "other"
                };
                let kind = if self.script_is_ours(spk, &output.bip32_derivation, &known) {
                    "own"
                } else if spk.is_v0_p2wsh() {
                    "escrow"
                } else {
                    "external"
                };
                let address =
                    Address::from_script(spk, output.blinding_key.map(|k| k.inner), params)
                        .map(|a| a.to_string());
                PsetOutputInfo {
                    index: index as u32,
                    kind: kind.to_string(),
                    script_type: script_type.to_string(),
                    address,
                    asset,
                    amount,
                    unverified,
                }
            })
            .collect())
    }

    /// Signs a PSET with the software signer.
    ///
    /// Returns an error if this is a watch-only wallet.
    pub fn sign(
        &self,
        pset: &mut lwk_wollet::elements::pset::PartiallySignedTransaction,
    ) -> Result<u32, TemplarError> {
        let signer = self
            .signer
            .as_ref()
            .ok_or_else(|| LiquidError::SigningFailed("Watch-only wallet cannot sign".into()))?;
        let sigs = signer
            .sign(pset)
            .map_err(|e| LiquidError::SigningFailed(e.to_string()))?;
        Ok(sigs)
    }

    /// Combines multiple signed PSETs into one (parallel signing assembly).
    ///
    /// Pass all signed copies (including the base). Returns the merged PSET.
    pub fn combine(
        &self,
        psets: &[lwk_wollet::elements::pset::PartiallySignedTransaction],
    ) -> Result<lwk_wollet::elements::pset::PartiallySignedTransaction, TemplarError> {
        self.wollet.combine(psets).map_err(|e| {
            TemplarError::from(LiquidError::PsetBuildFailed(format!("Combine PSETs: {e}")))
        })
    }

    /// Finalizes a PSET into a ready-to-broadcast transaction.
    ///
    /// Uses `Wollet::finalize()` which handles script satisfaction correctly.
    pub fn finalize(
        &self,
        pset: &mut lwk_wollet::elements::pset::PartiallySignedTransaction,
    ) -> Result<lwk_wollet::elements::Transaction, TemplarError> {
        self.wollet
            .finalize(pset)
            .map_err(|e| TemplarError::from(LiquidError::FinalizationFailed(e.to_string())))
    }

    /// Finalizes a PSET and broadcasts the resulting transaction.
    ///
    /// After broadcast, call `sync()` to update the wallet state.
    /// LWK 0.9 does not expose a single-tx `apply_tx()` — the `Update` struct
    /// requires fields only available via full Electrum scan.
    pub fn broadcast(
        &self,
        pset: &mut lwk_wollet::elements::pset::PartiallySignedTransaction,
    ) -> Result<String, TemplarError> {
        let tx = self.finalize(pset)?;
        self.chain()?.broadcast(&tx)?;
        Ok(tx.txid().to_string())
    }

    /// Serializes a PSET to base64 for export to co-signers.
    pub fn pset_to_base64(
        pset: &lwk_wollet::elements::pset::PartiallySignedTransaction,
    ) -> Result<String, TemplarError> {
        let mut buf = Vec::new();
        pset.consensus_encode(&mut buf)
            .map_err(|e| LiquidError::PsetBuildFailed(format!("PSET encode: {e}")))?;
        Ok(base64::engine::general_purpose::STANDARD.encode(&buf))
    }

    /// Deserializes a PSET from base64 (imported from co-signer).
    pub fn pset_from_base64(
        b64: &str,
    ) -> Result<lwk_wollet::elements::pset::PartiallySignedTransaction, TemplarError> {
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(b64.trim())
            .map_err(|e| LiquidError::PsetBuildFailed(format!("Base64 decode: {e}")))?;
        lwk_wollet::elements::pset::PartiallySignedTransaction::consensus_decode(&mut &bytes[..])
            .map_err(|e| {
                TemplarError::from(LiquidError::PsetBuildFailed(format!("PSET decode: {e}")))
            })
    }

    /// Issues a new Liquid asset.
    ///
    /// Builds a contract with the correct issuer pubkey derived from the wallet's seed,
    /// broadcasts the issuance transaction, then submits the contract to the testnet
    /// registry (best-effort — registry failure does NOT abort the issuance).
    ///
    /// Returns `IssuanceResult` with the new asset_id, optional token_id, txid, and
    /// a flag indicating whether registry registration succeeded.
    #[allow(clippy::too_many_arguments)] // the contract's fields, one by one
    pub fn issue_asset(
        &mut self,
        name: &str,
        ticker: &str,
        precision: u8,
        domain: &str,
        amount_sats: u64,
        reissuance_tokens: u64,
        frozen: &BTreeSet<String>,
    ) -> Result<IssuanceResult, TemplarError> {
        let signer = self
            .signer
            .as_ref()
            .ok_or_else(|| LiquidError::SigningFailed("Watch-only wallet cannot sign".into()))?
            .clone();

        // Derive the issuer pubkey (33 bytes compressed) from the wallet's root xpub.
        let issuer_pubkey = issuer_pubkey_bytes(&signer);

        let domain = domain.trim_end_matches('/');

        let contract = lwk_wollet::Contract {
            entity: lwk_wollet::Entity::Domain(domain.to_string()),
            issuer_pubkey,
            name: name.to_string(),
            precision,
            ticker: ticker.to_string(),
            version: 0,
        };

        // Invalid metadata would be permanently committed into the asset id and
        // rejected by the registry forever — refuse before syncing or signing.
        contract
            .validate()
            .map_err(|e| LiquidError::IssuanceFailed(format!("Invalid asset contract: {e}")))?;

        eprintln!(
            "[Issuance] Built contract: name={} ticker={} precision={} domain={}",
            contract.name, contract.ticker, contract.precision, domain
        );

        self.sync()?;

        // An issuance pays only its L-BTC fee, so the frozen coins can be
        // left out exactly.
        let mut builder = self
            .wollet
            .tx_builder()
            .issue_asset(
                amount_sats,
                None,
                reissuance_tokens,
                None,
                Some(contract.clone()),
            )
            .map_err(|e| LiquidError::IssuanceFailed(format!("Build issuance PSET: {e}")))?;
        if let Some(coins) = self.lbtc_coins_excluding(frozen)? {
            builder = builder.set_wallet_utxos(coins);
        }
        let mut pset = builder
            .finish()
            .map_err(|e| frozen_hint(LiquidError::IssuanceFailed, "Finish PSET", e, frozen))?;
        refuse_frozen_inputs(&pset, frozen, true)?;

        let sigs = signer
            .sign(&mut pset)
            .map_err(|e| LiquidError::IssuanceFailed(format!("Sign: {e}")))?;
        if sigs == 0 {
            return Err(LiquidError::SigningFailed("No signatures added".into()).into());
        }

        let tx = self
            .wollet
            .finalize(&mut pset)
            .map_err(|e| LiquidError::IssuanceFailed(format!("Finalize: {e}")))?;

        let network = self.network()?;
        self.chain()?
            .broadcast(&tx)
            .map_err(|e| LiquidError::IssuanceFailed(e.to_string()))?;

        let (asset_id, token_id) = tx.input[0].issuance_ids();
        let asset_id_str = asset_id.to_string();
        let token_id_str = if reissuance_tokens > 0 {
            Some(token_id.to_string())
        } else {
            None
        };

        eprintln!(
            "[Issuance] Broadcast success — asset_id={} token_id={:?} txid={}",
            asset_id_str,
            token_id_str,
            tx.txid()
        );

        // A local regtest has no public asset registry: the issuance is
        // complete as soon as it is on the node, and the metadata lives in
        // the wallet's own asset store instead.
        if network.is_regtest() {
            eprintln!("[Registry] Skipped: no asset registry on {network}");
            return Ok(IssuanceResult {
                asset_id: asset_id_str,
                token_id: token_id_str,
                txid: tx.txid().to_string(),
                registry_registered: false,
            });
        }

        // Registry publish — Liquid testnet requires the tx to be confirmed
        // (~1 min block time) before the registry will accept the submission.
        // We try immediately, then retry every 60 s for up to 5 more attempts
        // (total window: ~5 minutes). All attempts are best-effort and never
        // fail the on-chain issuance.
        let registry_registered = register_asset_contract(&asset_id_str, &contract);
        {
            let asset_id_retry = asset_id_str.clone();
            let contract_retry = contract.clone();
            std::thread::spawn(move || {
                for attempt in 1u32..=5 {
                    std::thread::sleep(std::time::Duration::from_secs(60));
                    eprintln!("[Registry] Retry #{} for asset {}", attempt, asset_id_retry);
                    if register_asset_contract(&asset_id_retry, &contract_retry) {
                        // Verify the entry is now visible in the registry.
                        match fetch_asset_contract_testnet(&asset_id_retry) {
                            Ok(entry) => eprintln!(
                                "[Registry] Retry #{} verify OK — name={}",
                                attempt,
                                entry.get("name").and_then(|v| v.as_str()).unwrap_or("?")
                            ),
                            Err(e) => {
                                eprintln!("[Registry] Retry #{} verify failed: {}", attempt, e)
                            }
                        }
                        break; // Registration succeeded — no more retries.
                    }
                }
            });
        }

        Ok(IssuanceResult {
            asset_id: asset_id_str,
            token_id: token_id_str,
            txid: tx.txid().to_string(),
            registry_registered,
        })
    }

    /// Reissues an existing asset (mints new units).
    ///
    /// Requires that this wallet holds the reissuance token for the given asset.
    pub fn reissue_asset(
        &mut self,
        asset_id: &str,
        amount_sats: u64,
        frozen: &BTreeSet<String>,
    ) -> Result<IssuanceResult, TemplarError> {
        let signer = self
            .signer
            .as_ref()
            .ok_or_else(|| LiquidError::SigningFailed("Watch-only wallet cannot sign".into()))?
            .clone();

        self.sync()?;

        let asset: lwk_wollet::elements::AssetId = asset_id
            .parse()
            .map_err(|e| LiquidError::ReissuanceFailed(format!("Invalid asset_id: {e}")))?;

        // The L-BTC fee coins can be chosen; the reissuance token coin is
        // LWK's pick, so a frozen token is refused rather than left out.
        let mut builder = self
            .wollet
            .tx_builder()
            .reissue_asset(asset, amount_sats, None, None)
            .map_err(|e| LiquidError::ReissuanceFailed(format!("Build reissuance PSET: {e}")))?;
        if let Some(coins) = self.lbtc_coins_excluding(frozen)? {
            builder = builder.set_wallet_utxos(coins);
        }
        let mut pset = builder
            .finish()
            .map_err(|e| frozen_hint(LiquidError::ReissuanceFailed, "Finish PSET", e, frozen))?;
        refuse_frozen_inputs(&pset, frozen, false)?;

        let sigs = signer
            .sign(&mut pset)
            .map_err(|e| LiquidError::ReissuanceFailed(format!("Sign: {e}")))?;
        if sigs == 0 {
            return Err(LiquidError::SigningFailed("No signatures added".into()).into());
        }

        let tx = self
            .wollet
            .finalize(&mut pset)
            .map_err(|e| LiquidError::ReissuanceFailed(format!("Finalize: {e}")))?;

        self.chain()?
            .broadcast(&tx)
            .map_err(|e| LiquidError::ReissuanceFailed(e.to_string()))?;

        eprintln!(
            "[Reissuance] Broadcast success — asset_id={} amount={} txid={}",
            asset_id,
            amount_sats,
            tx.txid()
        );

        Ok(IssuanceResult {
            asset_id: asset_id.to_string(),
            token_id: None,
            txid: tx.txid().to_string(),
            registry_registered: false,
        })
    }

    /// Burns units of a Liquid asset.
    ///
    /// Creates a transaction with an OP_RETURN burn output for the specified amount.
    pub fn burn_asset(
        &mut self,
        asset_id: &str,
        amount_sats: u64,
        frozen: &BTreeSet<String>,
    ) -> Result<String, TemplarError> {
        let signer = self
            .signer
            .as_ref()
            .ok_or_else(|| LiquidError::SigningFailed("Watch-only wallet cannot sign".into()))?
            .clone();

        self.sync()?;

        let asset: lwk_wollet::elements::AssetId = asset_id
            .parse()
            .map_err(|e| LiquidError::BurnFailed(format!("Invalid asset_id: {e}")))?;

        // Burning L-BTC can leave frozen coins out; burning any other asset
        // lets LWK pick that asset's coins itself, so a frozen one is refused.
        let lbtc = asset == self.wollet.policy_asset();
        let mut builder = self
            .wollet
            .tx_builder()
            .add_burn(amount_sats, asset)
            .map_err(|e| LiquidError::BurnFailed(format!("Build burn PSET: {e}")))?;
        if lbtc {
            if let Some(coins) = self.lbtc_coins_excluding(frozen)? {
                builder = builder.set_wallet_utxos(coins);
            }
        }
        let mut pset = builder
            .finish()
            .map_err(|e| frozen_hint(LiquidError::BurnFailed, "Finish PSET", e, frozen))?;
        refuse_frozen_inputs(&pset, frozen, lbtc)?;

        let sigs = signer
            .sign(&mut pset)
            .map_err(|e| LiquidError::BurnFailed(format!("Sign: {e}")))?;
        if sigs == 0 {
            return Err(LiquidError::SigningFailed("No signatures added".into()).into());
        }

        let tx = self
            .wollet
            .finalize(&mut pset)
            .map_err(|e| LiquidError::BurnFailed(format!("Finalize: {e}")))?;

        self.chain()?
            .broadcast(&tx)
            .map_err(|e| LiquidError::BurnFailed(e.to_string()))?;

        eprintln!(
            "[Burn] Broadcast success — asset_id={} amount={} txid={}",
            asset_id,
            amount_sats,
            tx.txid()
        );

        Ok(tx.txid().to_string())
    }

    /// Re-submits the asset contract to the Liquid testnet registry.
    ///
    /// Rebuilds the exact same contract (same issuer_pubkey derived from the
    /// wallet's seed) and POSTs it. Use this when the domain proof file was not
    /// yet live during the original issuance. Best-effort — never panics.
    pub fn reregister_asset(
        &self,
        asset_id: &str,
        name: &str,
        ticker: &str,
        precision: u8,
        domain: &str,
    ) -> bool {
        let signer = match self.signer.as_ref() {
            Some(s) => s,
            None => {
                eprintln!("[Registry] reregister_asset: watch-only wallet cannot sign");
                return false;
            }
        };
        if self.wollet.network() != ElementsNetwork::LiquidTestnet {
            eprintln!(
                "[Registry] reregister_asset: no asset registry on {}",
                self.wollet.network().as_str()
            );
            return false;
        }
        let issuer_pubkey = issuer_pubkey_bytes(signer);
        let domain = domain.trim_end_matches('/');
        let contract = lwk_wollet::Contract {
            entity: lwk_wollet::Entity::Domain(domain.to_string()),
            issuer_pubkey,
            name: name.to_string(),
            precision,
            ticker: ticker.to_string(),
            version: 0,
        };
        if let Err(e) = contract.validate() {
            eprintln!("[Registry] reregister_asset: invalid contract: {e}");
            return false;
        }
        register_asset_contract(asset_id, &contract)
    }

    /// Signs a PSET using a mnemonic (for co-signers who don't have the wallet open).
    pub fn sign_pset_with_mnemonic(
        pset: &mut lwk_wollet::elements::pset::PartiallySignedTransaction,
        mnemonic: &str,
    ) -> Result<u32, TemplarError> {
        let signer = SwSigner::new(mnemonic, false)
            .map_err(|e| LiquidError::SigningFailed(format!("SwSigner: {e}")))?;
        let sigs = signer
            .sign(pset)
            .map_err(|e| LiquidError::SigningFailed(e.to_string()))?;
        Ok(sigs)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEST_MNEMONIC: &str =
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

    #[test]
    fn a_pset_spending_a_frozen_coin_is_refused_with_the_right_reason() {
        use lwk_wollet::elements::pset::{Input, PartiallySignedTransaction};
        use lwk_wollet::elements::{OutPoint, Txid};
        use std::str::FromStr;

        let txid =
            Txid::from_str("4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b")
                .unwrap();
        let mut pset = PartiallySignedTransaction::new_v2();
        pset.add_input(Input::from_prevout(OutPoint::new(txid, 1)));
        let frozen: BTreeSet<String> = [format!("{txid}:1")].into();

        let err = refuse_frozen_inputs(&pset, &frozen, true)
            .unwrap_err()
            .to_string();
        assert!(err.contains("is frozen"), "{err}");
        let err = refuse_frozen_inputs(&pset, &frozen, false)
            .unwrap_err()
            .to_string();
        assert!(err.contains("cannot leave coins out"), "{err}");
        assert!(refuse_frozen_inputs(&pset, &BTreeSet::new(), false).is_ok());
        let other: BTreeSet<String> = [format!("{txid}:0")].into();
        assert!(refuse_frozen_inputs(&pset, &other, false).is_ok());
    }

    #[test]
    fn pset_base64_round_trip() {
        // Create a default (empty) PSET for round-trip test
        let pset = lwk_wollet::elements::pset::PartiallySignedTransaction::default();
        let b64 = LiquidWalletManager::pset_to_base64(&pset).unwrap();
        assert!(!b64.is_empty());
        let decoded = LiquidWalletManager::pset_from_base64(&b64).unwrap();
        // Re-encode should match
        let b64_2 = LiquidWalletManager::pset_to_base64(&decoded).unwrap();
        assert_eq!(b64, b64_2);
    }

    #[test]
    fn pset_from_base64_invalid() {
        let result = LiquidWalletManager::pset_from_base64("not-valid-base64!!!");
        assert!(result.is_err());
    }

    #[test]
    fn pset_from_base64_valid_base64_bad_pset() {
        // Valid base64 but not a PSET
        let result = LiquidWalletManager::pset_from_base64("aGVsbG8gd29ybGQ=");
        assert!(result.is_err());
    }

    #[test]
    fn sign_pset_with_mnemonic_no_match() {
        // Signing an empty PSET should add 0 signatures (no inputs to sign)
        let mut pset = lwk_wollet::elements::pset::PartiallySignedTransaction::default();
        let result = LiquidWalletManager::sign_pset_with_mnemonic(&mut pset, TEST_MNEMONIC);
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), 0);
    }

    const CT_DESC: &str = "ct(slip77(addfe14f6d96eb091712439190737b901b6b5558d7039ed1d0dd19a7305cb747),elwpkh([f0b68896/84'/1'/0']tpubDCVwWj4hEpeWNFcWe3Eo1DrkLnPC4c2iitjw5wAuTkSZgofJbRMD4KESh1uhsqLCCjcjR36JooEFwfWf1ezwmAfjcPCxc7KNtnfBCrMPdtT/<0;1>/*))";

    #[test]
    fn wallet_reports_the_network_it_was_opened_on() {
        let t = LiquidWalletManager::watch_only_with_persist_on(
            &LiquidNetwork::testnet(),
            CT_DESC,
            None,
        )
        .unwrap();
        assert_eq!(t.network().unwrap(), LiquidNetwork::testnet());
        assert_eq!(
            t.policy_asset_hex(),
            crate::liquid::network::TESTNET_POLICY_ASSET
        );
        assert!(t.get_new_address().unwrap().starts_with("tlq1"));

        let r = LiquidWalletManager::watch_only_with_persist_on(
            &LiquidNetwork::regtest_default(),
            CT_DESC,
            None,
        )
        .unwrap();
        assert_eq!(r.network().unwrap(), LiquidNetwork::regtest_default());
        assert_eq!(
            r.policy_asset_hex(),
            crate::liquid::network::REGTEST_DEFAULT_POLICY_ASSET
        );
        assert!(r.get_new_address().unwrap().starts_with("el1"));
        // The same descriptor yields the same script on both networks; only
        // the address encoding and the policy asset differ.
        assert_eq!(
            t.wollet.address(Some(0)).unwrap().address().script_pubkey(),
            r.wollet.address(Some(0)).unwrap().address().script_pubkey()
        );
    }

    #[test]
    fn same_seed_gives_same_descriptor_on_both_networks() {
        let t = LiquidWalletManager::from_mnemonic_with_persist_on(
            &LiquidNetwork::testnet(),
            TEST_MNEMONIC,
            None,
        )
        .unwrap();
        let r = LiquidWalletManager::from_mnemonic_with_persist_on(
            &LiquidNetwork::regtest_default(),
            TEST_MNEMONIC,
            None,
        )
        .unwrap();
        assert_eq!(t.descriptor, r.descriptor);
        assert!(t.descriptor.contains("/84'/1'/0'") || t.descriptor.contains("/84h/1h/0h"));
    }

    #[test]
    fn create_tx_refuses_an_address_from_another_network() {
        let r = LiquidWalletManager::watch_only_with_persist_on(
            &LiquidNetwork::regtest_default(),
            CT_DESC,
            None,
        )
        .unwrap();
        let testnet_addr = "tlq1qq2xvpcvfup5j8zscjq05u2wxxjcyewk7979f3mmz5l7uw5pqmx6xf5xy50hsn6vhkm5euwt72x878eq6zxx2z58hd7zrsg9qn";
        let err = r
            .create_tx(testnet_addr, 1000, &r.policy_asset_hex())
            .unwrap_err()
            .to_string();
        assert!(err.contains("Invalid address"), "{err}");
    }

    #[test]
    fn balance_counts_the_wallets_own_policy_asset_as_lbtc() {
        let r = LiquidWalletManager::watch_only_with_persist_on(
            &LiquidNetwork::regtest_default(),
            CT_DESC,
            None,
        )
        .unwrap();
        let bal = r.get_balance().unwrap();
        assert_eq!(
            bal.policy_asset_id(),
            crate::liquid::network::REGTEST_DEFAULT_POLICY_ASSET
        );
        assert_eq!(bal.lbtc(), 0);
        // A hand-built balance without a network still means testnet.
        let mut legacy = LiquidBalance::default();
        legacy
            .assets
            .insert(crate::liquid::assets::LBTC_ASSET_ID.to_string(), 7);
        assert_eq!(legacy.lbtc(), 7);
    }

    #[test]
    fn issuer_pubkey_is_33_bytes() {
        let signer = SwSigner::new(TEST_MNEMONIC, false).unwrap();
        let pubkey = issuer_pubkey_bytes(&signer);
        assert_eq!(pubkey.len(), 33, "compressed pubkey must be 33 bytes");
        // Must start with 02 or 03 (compressed point prefix)
        assert!(pubkey[0] == 0x02 || pubkey[0] == 0x03);
    }
}
