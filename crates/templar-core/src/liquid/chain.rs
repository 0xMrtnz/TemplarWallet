//! Chain access for Liquid behind one handle: an Electrum server (the public
//! testnet, or a local electrs) or `elementsd` JSON-RPC (a local regtest).
//! Both drive LWK's `BlockchainBackend` scan, so the same `Wollet` code
//! syncs on either.
//!
//! ## Why an RPC block indexer
//!
//! LWK 0.9 ships an `ElementsRpcClient`, but it only knows `scantxoutset`
//! (confirmed UTXOs, no history, no mempool) and does not implement
//! [`BlockchainBackend`]. A regtest chain is tiny, so [`ElementsRpcBackend`]
//! simply walks every block once (`getblock <hash> 0`), keeps an in-memory
//! `script → [txid]` index plus the mempool (`getrawmempool`), and answers
//! the backend calls from it. No electrs, no Esplora, one `elementsd`.
//! Reorgs (`invalidateblock` during a demo) are detected through the block
//! hashes and handled by re-indexing from scratch.
//!
//! The node must run with `-txindex=1` (the protocol's regtest node does) so
//! unindexed parents of mempool transactions can be fetched by txid.
//!
//! ## Offline-first
//!
//! Building a [`LiquidChain`] contacts nothing: an Electrum client is opened
//! per call and an RPC client is only a URL plus credentials. Wallet
//! constructors never touch this module — only sync and broadcast paths do.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, OnceLock};

use electrum_client::ElectrumApi;
use lwk_wollet::bitcoincore_rpc::{Auth, Client, RpcApi};
use lwk_wollet::clients::blocking::BlockchainBackend;
use lwk_wollet::elements::hashes::{sha256, Hash};
use lwk_wollet::elements::hex::{FromHex, ToHex};
use lwk_wollet::elements::{
    encode, Block, BlockHash, BlockHeader, OutPoint, Script, Transaction, Txid,
};
use lwk_wollet::{
    ElectrumClient, ElectrumOptions, ElectrumUrl, Error as LwkError, History, Wollet,
};
use serde::{Deserialize, Serialize};

use crate::error::{LiquidError, TemplarError};
use crate::liquid::network::{env_non_empty, LiquidNetwork};

/// Electrum server for Liquid testnet (default; override with
/// `TEMPLAR_LIQUID_ELECTRUM_URL` for outages or self-hosted servers).
pub const LIQUID_ELECTRUM_URL: &str = "elements-testnet.blockstream.info:50002";

/// `elementsd` JSON-RPC endpoint of the Templar Protocol's local regtest
/// node; the default for the RPC backend.
pub const DEFAULT_ELEMENTS_RPC_URL: &str = "http://127.0.0.1:18884";
/// Default RPC credentials of that node.
pub const DEFAULT_ELEMENTS_RPC_USER: &str = "templar";
pub const DEFAULT_ELEMENTS_RPC_PASS: &str = "templar";

/// `electrum` | `elements_rpc` (also `elements-rpc`, `rpc`).
pub const ENV_BACKEND: &str = "TEMPLAR_LIQUID_BACKEND";
/// Electrum `host:port`.
pub const ENV_ELECTRUM_URL: &str = "TEMPLAR_LIQUID_ELECTRUM_URL";
/// `0`/`false` = plaintext Electrum (a local electrs), default TLS.
pub const ENV_ELECTRUM_TLS: &str = "TEMPLAR_LIQUID_ELECTRUM_TLS";
pub const ENV_RPC_URL: &str = "TEMPLAR_ELEMENTS_RPC_URL";
pub const ENV_RPC_USER: &str = "TEMPLAR_ELEMENTS_RPC_USER";
pub const ENV_RPC_PASS: &str = "TEMPLAR_ELEMENTS_RPC_PASS";

/// Socket timeout for Electrum. LWK's `ElectrumClient::new` defaults to
/// `timeout: None` — a stalled server then blocks forever, and since every
/// FFI call serializes on one mutex, the whole app wedges until force-quit.
const ELECTRUM_TIMEOUT_SECS: u8 = 8;

/// Where the wallet reads and writes the Liquid chain.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum LiquidBackend {
    /// An Electrum server (`host:port`), TLS by default.
    Electrum {
        url: String,
        tls: bool,
        validate_domain: bool,
    },
    /// An `elementsd` JSON-RPC endpoint with user/password auth.
    ElementsRpc {
        url: String,
        user: String,
        /// Never logged — see [`LiquidBackend::describe`].
        pass: String,
    },
}

/// The configured Liquid Electrum endpoint: env override or the default.
pub fn liquid_electrum_endpoint() -> String {
    env_non_empty(ENV_ELECTRUM_URL).unwrap_or_else(|| LIQUID_ELECTRUM_URL.to_string())
}

impl LiquidBackend {
    /// Blockstream's public Liquid testnet Electrum (env override honored).
    pub fn testnet_default() -> Self {
        LiquidBackend::Electrum {
            url: liquid_electrum_endpoint(),
            tls: electrum_tls_from_env(),
            validate_domain: true,
        }
    }

    /// The protocol's local regtest node (env overrides honored).
    pub fn regtest_default() -> Self {
        LiquidBackend::ElementsRpc {
            url: env_non_empty(ENV_RPC_URL).unwrap_or_else(|| DEFAULT_ELEMENTS_RPC_URL.to_string()),
            user: env_non_empty(ENV_RPC_USER)
                .unwrap_or_else(|| DEFAULT_ELEMENTS_RPC_USER.to_string()),
            pass: env_non_empty(ENV_RPC_PASS)
                .unwrap_or_else(|| DEFAULT_ELEMENTS_RPC_PASS.to_string()),
        }
    }

    /// The backend for `network`: `TEMPLAR_LIQUID_BACKEND` when set, else
    /// Electrum on testnet and `elementsd` RPC on regtest. Bad values are
    /// reported rather than silently defaulted.
    pub fn from_env(network: &LiquidNetwork) -> Result<Self, TemplarError> {
        match env_non_empty(ENV_BACKEND).as_deref() {
            None => Ok(Self::default_for(network)),
            Some(v) => match v.to_ascii_lowercase().as_str() {
                "electrum" => Ok(Self::testnet_default()),
                "elements_rpc" | "elements-rpc" | "rpc" => Ok(Self::regtest_default()),
                other => Err(LiquidError::InvalidNetwork(format!(
                    "{ENV_BACKEND}={other:?} (expected electrum or elements_rpc)"
                ))
                .into()),
            },
        }
    }

    /// The natural backend of a network when nothing is configured.
    pub fn default_for(network: &LiquidNetwork) -> Self {
        if network.is_regtest() {
            Self::regtest_default()
        } else {
            Self::testnet_default()
        }
    }

    /// Wire name: `electrum` | `elements_rpc`.
    pub fn kind(&self) -> &'static str {
        match self {
            LiquidBackend::Electrum { .. } => "electrum",
            LiquidBackend::ElementsRpc { .. } => "elements_rpc",
        }
    }

    /// Human description without credentials.
    pub fn describe(&self) -> String {
        match self {
            LiquidBackend::Electrum { url, tls, .. } => {
                format!("electrum {}{url}", if *tls { "ssl://" } else { "tcp://" })
            }
            LiquidBackend::ElementsRpc { url, .. } => format!("elements-rpc {url}"),
        }
    }
}

fn electrum_tls_from_env() -> bool {
    !matches!(
        env_non_empty(ENV_ELECTRUM_TLS).as_deref(),
        Some("0") | Some("false") | Some("no") | Some("off")
    )
}

fn sync_err(ctx: &str, e: impl std::fmt::Display) -> TemplarError {
    LiquidError::SyncFailed(format!("{ctx}: {e}")).into()
}

fn generic(ctx: &str, e: impl std::fmt::Display) -> LwkError {
    LwkError::Generic(format!("{ctx}: {e}"))
}

// ---------------------------------------------------------------------------
// elementsd RPC backend
// ---------------------------------------------------------------------------

#[derive(Default)]
struct Index {
    /// Block hash by height (`hashes[h]`), so `hashes.len()` = indexed tip + 1.
    hashes: Vec<BlockHash>,
    headers: HashMap<u32, BlockHeader>,
    txs: HashMap<Txid, Transaction>,
    /// Confirmation height; `0` = mempool.
    tx_height: HashMap<Txid, u32>,
    /// Transactions touching a script (outputs paid to it, inputs spent from
    /// it), in discovery order, without duplicates.
    script_history: HashMap<Script, Vec<Txid>>,
    mempool: HashSet<Txid>,
}

impl Index {
    fn indexed_height(&self) -> Option<u32> {
        self.hashes.len().checked_sub(1).map(|h| h as u32)
    }

    fn touch(&mut self, script: Script, txid: Txid) {
        let list = self.script_history.entry(script).or_default();
        if !list.contains(&txid) {
            list.push(txid);
        }
    }

    fn forget(&mut self, txid: &Txid) {
        self.tx_height.remove(txid);
        self.txs.remove(txid);
        for list in self.script_history.values_mut() {
            list.retain(|t| t != txid);
        }
    }
}

/// [`BlockchainBackend`] over `elementsd` JSON-RPC (see module docs).
pub struct ElementsRpcBackend {
    client: Client,
    url: String,
    auth: Auth,
    index: Mutex<Index>,
}

impl ElementsRpcBackend {
    pub fn new(url: &str, user: &str, pass: &str) -> Result<Self, TemplarError> {
        let auth = Auth::UserPass(user.to_string(), pass.to_string());
        let url = url.trim_end_matches('/').to_string();
        let client =
            Client::new(&url, auth.clone()).map_err(|e| sync_err("elements rpc client", e))?;
        Ok(Self {
            client,
            url,
            auth,
            index: Mutex::new(Index::default()),
        })
    }

    /// Raw JSON-RPC passthrough on the node (diagnostics, test tooling).
    pub fn call_json(
        &self,
        method: &str,
        args: &[serde_json::Value],
    ) -> Result<serde_json::Value, TemplarError> {
        self.call(method, args).map_err(|e| sync_err(method, e))
    }

    /// Raw JSON-RPC passthrough on one of the node's wallets
    /// (`/wallet/<name>`) — how a regtest faucet or miner is driven.
    pub fn wallet_call_json(
        &self,
        wallet: &str,
        method: &str,
        args: &[serde_json::Value],
    ) -> Result<serde_json::Value, TemplarError> {
        let client = Client::new(&format!("{}/wallet/{wallet}", self.url), self.auth.clone())
            .map_err(|e| sync_err("elements wallet rpc client", e))?;
        client
            .call(method, args)
            .map_err(|e| sync_err(&format!("{wallet}: {method}"), e))
    }

    fn call<T: for<'de> Deserialize<'de>>(
        &self,
        method: &str,
        args: &[serde_json::Value],
    ) -> Result<T, LwkError> {
        self.client
            .call(method, args)
            .map_err(|e| generic(method, e))
    }

    /// `getblockcount`.
    pub fn block_count(&self) -> Result<u32, LwkError> {
        let n: u64 = self.call("getblockcount", &[])?;
        Ok(n as u32)
    }

    fn block_hash(&self, height: u32) -> Result<BlockHash, LwkError> {
        let s: String = self.call("getblockhash", &[height.into()])?;
        s.parse().map_err(|e| generic("getblockhash", e))
    }

    fn block(&self, hash: &BlockHash) -> Result<Block, LwkError> {
        let hex: String = self.call("getblock", &[hash.to_string().into(), 0.into()])?;
        let bytes = Vec::<u8>::from_hex(&hex).map_err(|e| generic("getblock hex", e))?;
        encode::deserialize(&bytes).map_err(|e| generic("getblock decode", e))
    }

    fn raw_transaction(&self, txid: &Txid) -> Result<Transaction, LwkError> {
        let hex: String = self
            .call(
                "getrawtransaction",
                &[txid.to_string().into(), false.into()],
            )
            .map_err(|e| generic(&format!("tx {txid}"), e))?;
        let bytes = Vec::<u8>::from_hex(&hex).map_err(|e| generic("getrawtransaction hex", e))?;
        encode::deserialize(&bytes).map_err(|e| generic("getrawtransaction decode", e))
    }

    /// `getrawtransaction`, `None` when the node does not know the txid
    /// (foreign chain, or pruned). Needs `-txindex=1` for anything outside
    /// the mempool and the node's own wallet.
    pub fn transaction(&self, txid: &Txid) -> Result<Option<Transaction>, TemplarError> {
        match self.raw_transaction(txid) {
            Ok(tx) => Ok(Some(tx)),
            Err(LwkError::Generic(msg))
                if msg.contains("No such mempool")
                    || msg.contains("not found")
                    || msg.contains("-5") =>
            {
                Ok(None)
            }
            Err(e) => Err(sync_err("getrawtransaction", e)),
        }
    }

    /// `gettxout` including the mempool: `true` while the output is unspent.
    pub fn txout_unspent(&self, outpoint: &OutPoint) -> Result<bool, TemplarError> {
        let v: serde_json::Value = self
            .call(
                "gettxout",
                &[
                    outpoint.txid.to_string().into(),
                    outpoint.vout.into(),
                    true.into(),
                ],
            )
            .map_err(|e| sync_err("gettxout", e))?;
        Ok(!v.is_null())
    }

    /// Records one transaction at `height` (0 = mempool) in the index.
    fn index_tx(&self, index: &mut Index, tx: Transaction, height: u32) -> Result<(), LwkError> {
        let txid = tx.txid();
        for out in &tx.output {
            if out.script_pubkey.is_empty() {
                continue; // fee output
            }
            index.touch(out.script_pubkey.clone(), txid);
        }
        for input in &tx.input {
            if input.is_pegin || input.previous_output.is_null() {
                continue;
            }
            let prev_txid = input.previous_output.txid;
            let prev_vout = input.previous_output.vout as usize;
            let spk = match index.txs.get(&prev_txid) {
                Some(prev) => prev.output.get(prev_vout).map(|o| o.script_pubkey.clone()),
                None => {
                    // Parent not seen yet (mempool ordering): fetch through
                    // txindex and cache it. A parent the node itself cannot
                    // serve is a synthetic prevout — the genesis free-coins
                    // issuance spends one — and no wallet script can own it.
                    match self.raw_transaction(&prev_txid) {
                        Ok(prev) => {
                            let spk = prev.output.get(prev_vout).map(|o| o.script_pubkey.clone());
                            index.txs.insert(prev_txid, prev);
                            spk
                        }
                        Err(_) if height == 0 => None,
                        Err(e) => return Err(e),
                    }
                }
            };
            if let Some(spk) = spk {
                if !spk.is_empty() {
                    index.touch(spk, txid);
                }
            }
        }
        index.tx_height.insert(txid, height);
        index.txs.insert(txid, tx);
        Ok(())
    }

    /// Brings the index up to the node's tip and mempool.
    fn refresh(&self) -> Result<(), LwkError> {
        let mut index = self.index.lock().unwrap_or_else(|e| e.into_inner());
        let tip = self.block_count()?;

        // Reorg check: the hash we hold for our indexed tip must still be the
        // node's hash at that height (also covers a shrunk chain). Otherwise
        // start over — regtest chains are small; correctness beats cleverness.
        if let Some(h) = index.indexed_height() {
            let still_there = h <= tip && self.block_hash(h)? == index.hashes[h as usize];
            if !still_there {
                *index = Index::default();
            }
        }

        let mut height = index.indexed_height().map(|h| h + 1).unwrap_or(0);
        while height <= tip {
            let hash = self.block_hash(height)?;
            let block = self.block(&hash)?;
            if height > 0 && block.header.prev_blockhash != index.hashes[height as usize - 1] {
                // The chain moved under us mid-walk: restart from genesis.
                *index = Index::default();
                height = 0;
                continue;
            }
            index.headers.insert(height, block.header.clone());
            index.hashes.push(hash);
            for tx in block.txdata {
                let txid = tx.txid();
                index.mempool.remove(&txid);
                self.index_tx(&mut index, tx, height)?;
            }
            height += 1;
        }

        // Mempool: add newcomers, drop what vanished without confirming.
        let now: Vec<String> = self.call("getrawmempool", &[])?;
        let now: HashSet<Txid> = now.iter().filter_map(|s| s.parse().ok()).collect();
        let gone: Vec<Txid> = index.mempool.difference(&now).cloned().collect();
        for txid in gone {
            if index.tx_height.get(&txid) == Some(&0) {
                index.forget(&txid);
            }
            index.mempool.remove(&txid);
        }
        let new: Vec<Txid> = now
            .iter()
            .filter(|t| !index.mempool.contains(*t) && !index.tx_height.contains_key(*t))
            .cloned()
            .collect();
        for txid in new {
            let tx = self.raw_transaction(&txid)?;
            self.index_tx(&mut index, tx, 0)?;
            index.mempool.insert(txid);
        }
        Ok(())
    }
}

impl BlockchainBackend for ElementsRpcBackend {
    fn tip(&mut self) -> Result<BlockHeader, LwkError> {
        self.refresh()?;
        let index = self.index.lock().unwrap_or_else(|e| e.into_inner());
        let h = index
            .indexed_height()
            .ok_or_else(|| LwkError::Generic("empty chain".into()))?;
        index
            .headers
            .get(&h)
            .cloned()
            .ok_or_else(|| LwkError::Generic("tip header missing".into()))
    }

    fn broadcast(&self, tx: &Transaction) -> Result<Txid, LwkError> {
        let hex = encode::serialize(tx).to_hex();
        let txid: String = self.call("sendrawtransaction", &[hex.into()])?;
        txid.parse().map_err(|e| generic("sendrawtransaction", e))
    }

    fn get_transactions(&self, txids: &[Txid]) -> Result<Vec<Transaction>, LwkError> {
        let index = self.index.lock().unwrap_or_else(|e| e.into_inner());
        let mut out = Vec::with_capacity(txids.len());
        for txid in txids {
            match index.txs.get(txid) {
                Some(tx) => out.push(tx.clone()),
                None => out.push(self.raw_transaction(txid)?),
            }
        }
        Ok(out)
    }

    fn get_headers(
        &self,
        heights: &[u32],
        _height_blockhash: &HashMap<u32, BlockHash>,
    ) -> Result<Vec<BlockHeader>, LwkError> {
        let index = self.index.lock().unwrap_or_else(|e| e.into_inner());
        let mut out = Vec::with_capacity(heights.len());
        for h in heights {
            match index.headers.get(h) {
                Some(header) => out.push(header.clone()),
                None => {
                    let hash = self.block_hash(*h)?;
                    out.push(self.block(&hash)?.header);
                }
            }
        }
        Ok(out)
    }

    fn get_scripts_history(&self, scripts: &[&Script]) -> Result<Vec<Vec<History>>, LwkError> {
        self.refresh()?;
        let index = self.index.lock().unwrap_or_else(|e| e.into_inner());
        let mut out = Vec::with_capacity(scripts.len());
        for script in scripts {
            let mut hist = Vec::new();
            if let Some(txids) = index.script_history.get(*script) {
                for txid in txids {
                    let height = *index.tx_height.get(txid).unwrap_or(&0);
                    let (block_hash, block_timestamp) = if height > 0 {
                        (
                            index.hashes.get(height as usize).cloned(),
                            index.headers.get(&height).map(|h| h.time),
                        )
                    } else {
                        (None, None)
                    };
                    hist.push(History {
                        txid: *txid,
                        height: height as i32,
                        block_hash,
                        block_timestamp,
                    });
                }
            }
            out.push(hist);
        }
        Ok(out)
    }
}

/// Process-wide cache of RPC backends keyed by endpoint, so the block index
/// survives between syncs instead of being rebuilt on every call. A cache of
/// connections, not a setting: nothing here decides which network is active.
fn shared_rpc_backend(
    url: &str,
    user: &str,
    pass: &str,
) -> Result<Arc<Mutex<ElementsRpcBackend>>, TemplarError> {
    type Key = (String, String, String);
    type Cache = Mutex<HashMap<Key, Arc<Mutex<ElementsRpcBackend>>>>;
    static CACHE: OnceLock<Cache> = OnceLock::new();
    let cache = CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    let key = (url.to_string(), user.to_string(), pass.to_string());
    let mut map = cache.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(b) = map.get(&key) {
        return Ok(b.clone());
    }
    let backend = Arc::new(Mutex::new(ElementsRpcBackend::new(url, user, pass)?));
    map.insert(key, backend.clone());
    Ok(backend)
}

// ---------------------------------------------------------------------------
// Chain facade
// ---------------------------------------------------------------------------

/// One handle for every chain read/write of a Liquid wallet on one network.
pub struct LiquidChain {
    network: LiquidNetwork,
    backend: LiquidBackend,
    rpc: Option<Arc<Mutex<ElementsRpcBackend>>>,
}

/// Concrete backend passed to [`LiquidChain::with_backend`] closures —
/// `BlockchainBackend` has generic methods, so it is not object safe.
enum Backend<'a> {
    Rpc(std::sync::MutexGuard<'a, ElementsRpcBackend>),
    Electrum(Box<ElectrumClient>),
}

impl LiquidChain {
    /// Prepares the chain handle. Offline: nothing is contacted until a
    /// method is called.
    pub fn new(network: LiquidNetwork, backend: LiquidBackend) -> Result<Self, TemplarError> {
        let rpc = match &backend {
            LiquidBackend::ElementsRpc { url, user, pass } => {
                Some(shared_rpc_backend(url, user, pass)?)
            }
            LiquidBackend::Electrum { .. } => None,
        };
        Ok(Self {
            network,
            backend,
            rpc,
        })
    }

    /// The chain for `network` with the backend the environment selects
    /// (see [`LiquidBackend::from_env`]).
    pub fn from_env(network: &LiquidNetwork) -> Result<Self, TemplarError> {
        let backend = LiquidBackend::from_env(network)?;
        Self::new(network.clone(), backend)
    }

    pub fn network(&self) -> &LiquidNetwork {
        &self.network
    }

    pub fn backend(&self) -> &LiquidBackend {
        &self.backend
    }

    pub fn describe(&self) -> String {
        format!("{} via {}", self.network, self.backend.describe())
    }

    fn electrum_url(&self) -> Result<ElectrumUrl, TemplarError> {
        let LiquidBackend::Electrum {
            url,
            tls,
            validate_domain,
        } = &self.backend
        else {
            return Err(sync_err("electrum", "not an electrum backend"));
        };
        ElectrumUrl::new(url, *tls, *validate_domain).map_err(|e| sync_err("electrum url", e))
    }

    fn electrum(&self) -> Result<ElectrumClient, TemplarError> {
        let url = self.electrum_url()?;
        ElectrumClient::with_options(
            &url,
            ElectrumOptions {
                timeout: Some(ELECTRUM_TIMEOUT_SECS),
            },
        )
        .map_err(|e| sync_err("Electrum connection failed", e))
    }

    /// Raw Electrum client for the JSON-RPC calls LWK's wrapper does not
    /// expose (`transaction.get`, `scripthash.listunspent`).
    fn raw_electrum(&self) -> Result<electrum_client::Client, TemplarError> {
        let LiquidBackend::Electrum {
            url,
            tls,
            validate_domain,
        } = &self.backend
        else {
            return Err(sync_err("electrum", "not an electrum backend"));
        };
        let url = if url.contains("://") {
            url.clone()
        } else if *tls {
            format!("ssl://{url}")
        } else {
            format!("tcp://{url}")
        };
        let config = electrum_client::ConfigBuilder::new()
            .timeout(Some(ELECTRUM_TIMEOUT_SECS))
            .validate_domain(*validate_domain)
            .build();
        electrum_client::Client::from_config(&url, config)
            .map_err(|e| sync_err("Electrum connection failed", e))
    }

    fn with_backend<T>(
        &self,
        f: impl FnOnce(Backend<'_>) -> Result<T, TemplarError>,
    ) -> Result<T, TemplarError> {
        match &self.rpc {
            Some(rpc) => f(Backend::Rpc(rpc.lock().unwrap_or_else(|e| e.into_inner()))),
            None => f(Backend::Electrum(Box::new(self.electrum()?))),
        }
    }

    /// Refuses to drive a wallet that was opened on another network — the
    /// symptom of a network switch without a wallet reopen, which would
    /// otherwise scan the wrong chain and report a wrong balance.
    fn check_wollet_network(&self, wollet: &Wollet) -> Result<(), TemplarError> {
        if wollet.network() != self.network.elements() {
            return Err(LiquidError::NetworkMismatch(format!(
                "wallet is open on {} but the chain backend is {} — reopen the wallet",
                wollet.network().as_str(),
                self.network
            ))
            .into());
        }
        Ok(())
    }

    /// Current tip height.
    pub fn tip_height(&self) -> Result<u32, TemplarError> {
        self.with_backend(|b| match b {
            Backend::Rpc(mut rpc) => Ok(rpc.tip().map_err(|e| sync_err("tip", e))?.height),
            Backend::Electrum(mut c) => Ok(c.tip().map_err(|e| sync_err("tip", e))?.height),
        })
    }

    /// Full scan + apply: brings `wollet` up to date with the chain.
    pub fn sync(&self, wollet: &mut Wollet) -> Result<(), TemplarError> {
        self.sync_to_index(wollet, 0)
    }

    /// Like [`LiquidChain::sync`] but scans at least up to derivation
    /// `index` — what a contract wallet needs when its coins sit at a fixed
    /// index rather than the next unused one.
    pub fn sync_to_index(&self, wollet: &mut Wollet, index: u32) -> Result<(), TemplarError> {
        self.check_wollet_network(wollet)?;
        let update = self.with_backend(|b| match b {
            Backend::Rpc(mut rpc) => rpc
                .full_scan_to_index(wollet, index)
                .map_err(|e| sync_err("scan", e)),
            Backend::Electrum(mut c) => c
                .full_scan_to_index(wollet, index)
                .map_err(|e| sync_err("scan", e)),
        })?;
        if let Some(update) = update {
            wollet
                .apply_update(update)
                .map_err(|e| sync_err("apply update", e))?;
        }
        Ok(())
    }

    /// Broadcasts a finalized transaction; returns the txid.
    pub fn broadcast(&self, tx: &Transaction) -> Result<Txid, TemplarError> {
        self.with_backend(|b| {
            match b {
                Backend::Rpc(rpc) => rpc.broadcast(tx),
                Backend::Electrum(c) => c.broadcast(tx),
            }
            .map_err(|e| LiquidError::BroadcastFailed(format!("Broadcast: {e}")).into())
        })
    }

    /// Fetches a transaction by txid. `Ok(None)` when the backend does not
    /// know it (typically: it belongs to another chain).
    pub fn fetch_transaction(&self, txid: &Txid) -> Result<Option<Transaction>, TemplarError> {
        if let Some(rpc) = &self.rpc {
            return rpc
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .transaction(txid);
        }
        let client = self.raw_electrum()?;
        match client.raw_call(
            "blockchain.transaction.get",
            vec![electrum_client::Param::String(txid.to_string())],
        ) {
            Ok(value) => {
                let hex_str = value
                    .as_str()
                    .ok_or_else(|| sync_err("transaction.get", "unexpected response"))?;
                let bytes = hex::decode(hex_str).map_err(|e| sync_err("transaction.get hex", e))?;
                let tx = encode::deserialize(&bytes)
                    .map_err(|e| sync_err("transaction.get decode", e))?;
                Ok(Some(tx))
            }
            // Electrum returns a protocol error for unknown transactions;
            // treat any RPC-level error as "not found on this chain".
            Err(electrum_client::Error::Protocol(_)) => Ok(None),
            Err(e) => {
                let msg = e.to_string();
                if msg.contains("missing transaction") || msg.contains("No such") {
                    Ok(None)
                } else {
                    Err(sync_err("transaction.get", e))
                }
            }
        }
    }

    /// Whether `outpoint` (paying `script_pubkey`) is still unspent.
    pub fn utxo_unspent(
        &self,
        script_pubkey: &Script,
        outpoint: &OutPoint,
    ) -> Result<bool, TemplarError> {
        if let Some(rpc) = &self.rpc {
            return rpc
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .txout_unspent(outpoint);
        }
        // scripthash = sha256(spk), byte-reversed — the Electrum convention.
        let mut hash = sha256::Hash::hash(script_pubkey.as_bytes()).to_byte_array();
        hash.reverse();
        let client = self.raw_electrum()?;
        let value = client
            .raw_call(
                "blockchain.scripthash.listunspent",
                vec![electrum_client::Param::String(hex::encode(hash))],
            )
            .map_err(|e| sync_err("listunspent", e))?;
        let items = value.as_array().cloned().unwrap_or_default();
        let txid = outpoint.txid.to_string();
        Ok(items.iter().any(|item| {
            item.get("tx_hash").and_then(|v| v.as_str()) == Some(txid.as_str())
                && item.get("tx_pos").and_then(|v| v.as_u64()) == Some(outpoint.vout as u64)
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backends_describe_and_default_by_network() {
        assert!(LiquidBackend::testnet_default()
            .describe()
            .starts_with("electrum "));
        assert_eq!(LiquidBackend::testnet_default().kind(), "electrum");
        assert!(LiquidBackend::regtest_default()
            .describe()
            .starts_with("elements-rpc http://"));
        assert!(matches!(
            LiquidBackend::default_for(&LiquidNetwork::regtest_default()),
            LiquidBackend::ElementsRpc { .. }
        ));
        assert!(matches!(
            LiquidBackend::default_for(&LiquidNetwork::testnet()),
            LiquidBackend::Electrum { .. }
        ));
        // Credentials never appear in the description.
        let d = LiquidBackend::ElementsRpc {
            url: "http://h:1".into(),
            user: "u".into(),
            pass: "hunter2".into(),
        }
        .describe();
        assert!(!d.contains("hunter2"));
    }

    /// Construction is offline for both backends.
    #[test]
    fn chain_new_is_offline() {
        let c = LiquidChain::new(
            LiquidNetwork::regtest_default(),
            LiquidBackend::ElementsRpc {
                url: "http://127.0.0.1:1".into(),
                user: "u".into(),
                pass: "p".into(),
            },
        )
        .unwrap();
        assert!(c.rpc.is_some());
        let c =
            LiquidChain::new(LiquidNetwork::testnet(), LiquidBackend::testnet_default()).unwrap();
        assert!(c.rpc.is_none());
        assert!(c.describe().starts_with("liquid-testnet via electrum"));
    }

    #[test]
    fn sync_refuses_a_wallet_from_another_network() {
        let desc: lwk_wollet::WolletDescriptor = "ct(slip77(addfe14f6d96eb091712439190737b901b6b5558d7039ed1d0dd19a7305cb747),elwpkh([f0b68896/84'/1'/0']tpubDCVwWj4hEpeWNFcWe3Eo1DrkLnPC4c2iitjw5wAuTkSZgofJbRMD4KESh1uhsqLCCjcjR36JooEFwfWf1ezwmAfjcPCxc7KNtnfBCrMPdtT/<0;1>/*))".parse().unwrap();
        let mut wollet =
            Wollet::without_persist(lwk_wollet::ElementsNetwork::LiquidTestnet, desc).unwrap();
        let chain = LiquidChain::new(
            LiquidNetwork::regtest_default(),
            LiquidBackend::ElementsRpc {
                url: "http://127.0.0.1:1".into(),
                user: "u".into(),
                pass: "p".into(),
            },
        )
        .unwrap();
        let err = chain.sync(&mut wollet).unwrap_err().to_string();
        assert!(err.contains("Network mismatch"), "{err}");
    }

    #[test]
    fn index_tracks_scripts_without_duplicates() {
        let mut index = Index::default();
        let s = Script::from(vec![0x51]);
        let t: Txid = "1111111111111111111111111111111111111111111111111111111111111111"
            .parse()
            .unwrap();
        index.touch(s.clone(), t);
        index.touch(s.clone(), t);
        assert_eq!(index.script_history[&s].len(), 1);
        index.tx_height.insert(t, 0);
        index.forget(&t);
        assert!(index.script_history[&s].is_empty());
        assert!(index.indexed_height().is_none());
    }
}
