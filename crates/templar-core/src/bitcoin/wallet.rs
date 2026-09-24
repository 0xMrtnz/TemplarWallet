//! Bitcoin wallet manager using BDK 0.30.
//!
//! BDK 0.30 uses `RefCell` internally — it is NOT thread-safe.
//! During `sync()`, no other wallet method may be called.
//! The GUI wraps this in `Arc<Mutex<Option<WalletManager>>>`.

use bdk::bitcoin::blockdata::script::PushBytesBuf;
use bdk::bitcoin::psbt::PartiallySignedTransaction;
use bdk::bitcoin::{Address, Network, Transaction, Txid};
use bdk::blockchain::electrum::ElectrumBlockchain;
use bdk::blockchain::{Blockchain, ConfigurableBlockchain, ElectrumBlockchainConfig};
use bdk::keys::bip39::Mnemonic;
use bdk::keys::{DerivableKey, ExtendedKey};
use bdk::wallet::{AddressIndex, AddressInfo};
use bdk::KeychainKind;
use bdk::{FeeRate, SignOptions, SyncOptions, Wallet};
use std::collections::BTreeSet;
use std::path::Path;
use std::str::FromStr;

use crate::bitcoin::multisig::MultisigSetupInfo;
use crate::derivation::{xpub_to_vpub_testnet, LiquidDerivationInfo, WalletPubInfo};
use crate::error::{BitcoinError, TemplarError};
use crate::frozen::first_frozen;
use crate::registry::{ProfileStore, WalletProfile};

/// Runs a closure inside `catch_unwind` to protect against BDK 0.30 RefCell panics.
///
/// BDK 0.30 uses `RefCell` internally, which can panic on double borrow.
/// This converts panics into `BitcoinError::Panicked` instead of crashing the app.
fn catch_bdk<F, T>(f: F) -> Result<T, TemplarError>
where
    F: FnOnce() -> Result<T, TemplarError> + std::panic::UnwindSafe,
{
    match std::panic::catch_unwind(f) {
        Ok(result) => result,
        Err(panic) => {
            let msg = if let Some(s) = panic.downcast_ref::<&str>() {
                s.to_string()
            } else if let Some(s) = panic.downcast_ref::<String>() {
                s.clone()
            } else {
                "Unknown panic in BDK".to_string()
            };
            Err(BitcoinError::Panicked(msg).into())
        }
    }
}

/// One input or output of a previewed transaction, resolved to an address and
/// amount for review display before signing.
#[derive(Debug, Clone)]
pub struct TxPreviewIo {
    /// `"txid:vout"` for inputs; `None` for outputs.
    pub outpoint: Option<String>,
    pub address: String,
    pub amount_sats: u64,
    /// Output pays back to this wallet (change). Always `false` for inputs.
    pub is_change: bool,
}

/// Electrum server for Bitcoin testnet (default; override with
/// TEMPLAR_ELECTRUM_URL for outages or self-hosted servers).
const ELECTRUM_URL: &str = "ssl://electrum.blockstream.info:60002";

/// The configured Bitcoin Electrum endpoint: env override or the default.
fn electrum_endpoint() -> String {
    std::env::var("TEMPLAR_ELECTRUM_URL")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| ELECTRUM_URL.to_string())
}

fn make_electrum_blockchain() -> Result<ElectrumBlockchain, TemplarError> {
    ElectrumBlockchain::from_config(&ElectrumBlockchainConfig {
        url: electrum_endpoint(),
        socks5: None,
        retry: 3,
        timeout: Some(5),
        // Deliberately far above the BIP-44 gap limit of 20. Earlier builds
        // revealed a fresh address on every receive-screen visit, so existing
        // wallets have funds at high, sparse indexes (seen in the field: UTXOs
        // at 5, 122, 123). A freshly imported watch-only wallet rescans from
        // scratch and would stop at the first 20-address gap, silently showing
        // a partial balance. 200 covers that legacy inflation with margin.
        stop_gap: 200,
        validate_domain: true,
    })
    .map_err(|e| BitcoinError::SyncFailed(format!("Electrum connection failed: {e}")).into())
}

/// Maps a sled open failure to an actionable message. The raw sled text for a
/// held lock ("could not acquire lock") used to surface as "Invalid
/// descriptor", sending users down the wrong path entirely.
/// A multisig database that would not open, with the one case the caller can
/// act on told apart from the rest: the directory belongs to someone else —
/// another wallet's descriptor is checksummed in it, or another instance
/// holds its lock.
enum MultisigDbError {
    Foreign,
    Failed(TemplarError),
}

impl MultisigDbError {
    fn into_error(self) -> TemplarError {
        match self {
            Self::Foreign => BitcoinError::InvalidDescriptor(
                "The wallet database belongs to another wallet or is held by another \
                 running instance."
                    .into(),
            )
            .into(),
            Self::Failed(e) => e,
        }
    }
}

/// Sled could not take the directory's lock — another process has it open.
fn is_lock_error(e: &sled::Error) -> bool {
    let msg = e.to_string();
    msg.contains("could not acquire lock") || msg.contains("WouldBlock")
}

fn open_db_error(e: sled::Error) -> TemplarError {
    let msg = e.to_string();
    if is_lock_error(&e) {
        BitcoinError::InvalidDescriptor(
            "The wallet database is locked by another running instance. \
             Close other Templar Wallet windows and try again."
                .into(),
        )
        .into()
    } else {
        BitcoinError::InvalidDescriptor(format!("Database open failed: {msg}")).into()
    }
}

/// Bitcoin wallet engine backed by BDK 0.30.
///
/// Supports singlesig (wpkh), hardware wallet, and multisig (wsh(sortedmulti)) descriptors.
/// NOT thread-safe — must be protected with `Arc<Mutex<>>`.
/// Fully offline-capable: the Electrum connection is created on demand inside
/// [`Self::sync`] / [`Self::broadcast`], never at construction.
pub struct WalletManager {
    pub wallet: Wallet<sled::Tree>,
    /// Receive descriptor without checksum — used for HWI verify-on-device.
    pub receive_descriptor: Option<String>,
    /// Exportable public info (xpub, fingerprint, descriptor).
    pub pub_info: Option<WalletPubInfo>,
    /// True if this wallet uses a multisig descriptor.
    pub is_multisig: bool,
}

/// Fee rates the builder accepts, in sat/vB. 0.1 is the relay floor since
/// Bitcoin Core 30 and the lowest the send screen offers; above 1000 nothing
/// on testnet has ever needed it, and a slipped decimal point should fail
/// here rather than on chain.
const MIN_FEE_RATE_SAT_VB: f32 = 0.1;
const MAX_FEE_RATE_SAT_VB: f32 = 1000.0;

/// A fee the wallet will not pay without an explicit rebuild at a sane rate:
/// above 0.01 BTC and above a tenth of what the transaction moves. The
/// absolute floor keeps small sweeps (where the fee is a large share of a
/// tiny amount) building; the share test catches a fee-rate typo on a large
/// send. BDK 0.30 has no absurd-fee guard of its own.
const ABSURD_FEE_FLOOR_SATS: u64 = 1_000_000;

fn checked_fee_rate(fee_rate: f32) -> Result<FeeRate, TemplarError> {
    if !fee_rate.is_finite() || !(MIN_FEE_RATE_SAT_VB..=MAX_FEE_RATE_SAT_VB).contains(&fee_rate) {
        return Err(BitcoinError::TxBuildFailed(format!(
            "Fee rate {fee_rate} sat/vB is outside the accepted range \
             ({MIN_FEE_RATE_SAT_VB}–{MAX_FEE_RATE_SAT_VB} sat/vB)"
        ))
        .into());
    }
    Ok(FeeRate::from_sat_per_vb(fee_rate))
}

fn reject_absurd_fee(
    psbt: &PartiallySignedTransaction,
    fee: Option<u64>,
) -> Result<(), TemplarError> {
    let Some(fee) = fee else { return Ok(()) };
    let moved: u64 = psbt.unsigned_tx.output.iter().map(|o| o.value).sum();
    let ceiling = ABSURD_FEE_FLOOR_SATS.max(moved / 10);
    if fee > ceiling {
        return Err(BitcoinError::TxBuildFailed(format!(
            "The fee ({fee} sats) is absurdly high for a transaction moving {moved} sats — \
             check the fee rate"
        ))
        .into());
    }
    Ok(())
}

/// A builder failure, with a hint when frozen coins are what made the
/// wallet look short: the balance still counts them, the builder does not.
fn build_error(e: bdk::Error, frozen: &BTreeSet<String>) -> TemplarError {
    let msg = e.to_string();
    if !frozen.is_empty() && matches!(e, bdk::Error::InsufficientFunds { .. }) {
        return BitcoinError::TxBuildFailed(format!(
            "{msg} — frozen coins are left out; unfreeze some on the UTXOs screen \
             to spend them"
        ))
        .into();
    }
    BitcoinError::TxBuildFailed(msg).into()
}

/// Refuses a PSBT that spends a frozen coin. The builders already leave
/// frozen coins out; this is the check a PSBT built elsewhere (a cosigner,
/// a coordinator) meets before this wallet signs it.
pub fn refuse_frozen_inputs(
    psbt: &PartiallySignedTransaction,
    frozen: &BTreeSet<String>,
) -> Result<(), TemplarError> {
    let spent = psbt
        .unsigned_tx
        .input
        .iter()
        .map(|i| i.previous_output.to_string());
    match first_frozen(spent, frozen) {
        Some(op) => Err(BitcoinError::FrozenCoin(op).into()),
        None => Ok(()),
    }
}

impl WalletManager {
    /// Creates a software wallet from a BIP39 mnemonic.
    ///
    /// Each wallet gets a unique sled database keyed by the master fingerprint,
    /// preventing "descriptor checksum mismatch" when opening different wallets.
    pub fn new(data_dir: &Path, mnemonic_str: &str) -> Result<Self, TemplarError> {
        let network = Network::Testnet;
        let mnemonic = Mnemonic::parse(mnemonic_str)
            .map_err(|e| BitcoinError::InvalidMnemonic(e.to_string()))?;
        let xkey: ExtendedKey = mnemonic
            .clone()
            .into_extended_key()
            .map_err(|e| BitcoinError::InvalidMnemonic(e.to_string()))?;
        let xprv = xkey
            .into_xprv(network)
            .ok_or_else(|| BitcoinError::InvalidMnemonic("Failed to derive xprv".into()))?;

        let xprv_str = xprv.to_string();
        let descriptor = format!("wpkh({}/84'/1'/0'/0/*)", xprv_str);
        let change_descriptor = format!("wpkh({}/84'/1'/0'/1/*)", xprv_str);

        let secp = bdk::bitcoin::secp256k1::Secp256k1::new();
        let fp = format!("{}", xprv.fingerprint(&secp));
        let db_path = data_dir.join(format!("bdk_sw_{}", fp));

        let db = sled::open(&db_path).map_err(open_db_error)?;
        let database = db
            .open_tree("main")
            .map_err(|e| BitcoinError::InvalidDescriptor(format!("Database tree failed: {e}")))?;
        let wallet = Wallet::new(&descriptor, Some(&change_descriptor), network, database)
            .map_err(|e| BitcoinError::InvalidDescriptor(e.to_string()))?;

        let pub_desc_str = wallet
            .public_descriptor(KeychainKind::External)
            .map_err(|e| BitcoinError::InvalidDescriptor(e.to_string()))?
            .map(|d| d.to_string())
            .unwrap_or_default();

        let mut pub_info = Self::pub_info_from_descriptor(&pub_desc_str, &[]);
        if let Some(ref mut info) = pub_info {
            info.zpub = xpub_to_vpub_testnet(&info.xpub);
        }

        Ok(Self {
            wallet,
            receive_descriptor: None,
            pub_info,
            is_multisig: false,
        })
    }

    /// Reloads a hardware wallet from saved descriptors.
    pub fn from_hw_profile(
        data_dir: &Path,
        recv_desc: &str,
        change_desc: &str,
    ) -> Result<Self, TemplarError> {
        let db = sled::open(data_dir.join("bdk_hw_db")).map_err(open_db_error)?;
        let database = db
            .open_tree("hw_main")
            .map_err(|e| BitcoinError::InvalidDescriptor(format!("Database tree failed: {e}")))?;
        let wallet = Wallet::new(recv_desc, Some(change_desc), Network::Testnet, database)
            .map_err(|e| BitcoinError::InvalidDescriptor(e.to_string()))?;
        let pub_info = Self::pub_info_from_descriptor(recv_desc, &[]);
        Ok(Self {
            wallet,
            receive_descriptor: Some(recv_desc.to_string()),
            pub_info,
            is_multisig: false,
        })
    }

    /// The BDK database directory of a multisig wallet, under the data dir.
    ///
    /// Keyed by the wallet's registry id. It used to be keyed by the profile
    /// (`bdk_multisig_2_3_My_Multisig_Wallet` — threshold and name), which two
    /// wallets share the moment the second one keeps the wizard's default
    /// name: BDK then found the first wallet's descriptor checksum in the
    /// directory and refused the second at every open with "Descriptor
    /// checksum mismatch", an entry nothing could repair.
    pub fn multisig_db_dir(wallet_id: &str) -> String {
        format!("bdk_ms_{wallet_id}")
    }

    /// The directory a multisig wallet created before [`Self::multisig_db_dir`]
    /// existed keeps using, as long as it is really its own — see
    /// [`Self::from_multisig_profile`].
    pub fn legacy_multisig_db_dir(profile: &WalletProfile) -> String {
        format!("bdk_{}", profile.key())
    }

    /// Opens a multisig wallet from a saved `WalletProfile::Multisig`.
    ///
    /// The database lives in [`Self::multisig_db_dir`]. A wallet from before
    /// that directory existed keeps the name-keyed one it already has, but only
    /// if it is its own: when BDK finds another wallet's descriptor checksum
    /// in there (a wallet of the same name and threshold, created earlier or
    /// deleted and re-created with other keys), or another instance holds it,
    /// this wallet starts a fresh database of its own instead. The old one is
    /// only a cache of chain state, and the sync rebuilds it.
    pub fn from_multisig_profile(
        data_dir: &Path,
        profile: &WalletProfile,
        wallet_id: &str,
    ) -> Result<Self, TemplarError> {
        let (recv_desc, change_desc, cosigner_xpubs) = match profile {
            WalletProfile::Multisig {
                receive_descriptor,
                change_descriptor,
                cosigner_xpubs,
                ..
            } => (
                receive_descriptor.as_str(),
                change_descriptor.as_str(),
                cosigner_xpubs.clone(),
            ),
            _ => {
                return Err(BitcoinError::InvalidDescriptor("Not a Multisig profile".into()).into())
            }
        };

        let own = data_dir.join(Self::multisig_db_dir(wallet_id));
        let legacy = data_dir.join(Self::legacy_multisig_db_dir(profile));
        let inherited = !own.exists() && legacy.exists();
        let wallet = match Self::open_multisig_db(
            if inherited { &legacy } else { &own },
            recv_desc,
            change_desc,
        ) {
            Ok(wallet) => wallet,
            Err(MultisigDbError::Foreign) if inherited => {
                Self::open_multisig_db(&own, recv_desc, change_desc).map_err(|e| e.into_error())?
            }
            Err(e) => return Err(e.into_error()),
        };

        let pub_info = Self::pub_info_from_descriptor(recv_desc, &cosigner_xpubs);

        Ok(Self {
            wallet,
            receive_descriptor: Some(recv_desc.to_string()),
            pub_info,
            is_multisig: true,
        })
    }

    /// Opens the sled database at `path` and the wallet on top of it.
    fn open_multisig_db(
        path: &Path,
        recv_desc: &str,
        change_desc: &str,
    ) -> Result<Wallet<sled::Tree>, MultisigDbError> {
        let db = sled::open(path).map_err(|e| {
            if is_lock_error(&e) {
                MultisigDbError::Foreign
            } else {
                MultisigDbError::Failed(open_db_error(e))
            }
        })?;
        let database = db.open_tree("ms_main").map_err(|e| {
            MultisigDbError::Failed(
                BitcoinError::InvalidDescriptor(format!("Database tree failed: {e}")).into(),
            )
        })?;
        Wallet::new(recv_desc, Some(change_desc), Network::Testnet, database).map_err(|e| match e {
            bdk::Error::ChecksumMismatch => MultisigDbError::Foreign,
            e => MultisigDbError::Failed(BitcoinError::InvalidDescriptor(e.to_string()).into()),
        })
    }

    /// Opens a wallet from arbitrary descriptors (for Miniscript policies).
    ///
    /// `db_id` must be unique per wallet to avoid sled checksum mismatches.
    /// If `signing_key_desc` contains an xprv, the wallet can sign locally.
    pub fn from_descriptors(
        data_dir: &Path,
        recv_desc: &str,
        change_desc: &str,
        db_id: &str,
    ) -> Result<Self, TemplarError> {
        let db_path = data_dir.join(format!("bdk_{}", db_id));
        let db = sled::open(&db_path).map_err(open_db_error)?;
        let database = db
            .open_tree("policy_main")
            .map_err(|e| BitcoinError::InvalidDescriptor(format!("Database tree failed: {e}")))?;
        let wallet = Wallet::new(recv_desc, Some(change_desc), Network::Testnet, database)
            .map_err(|e| BitcoinError::InvalidDescriptor(e.to_string()))?;

        let pub_info = Self::pub_info_from_descriptor(recv_desc, &[]);

        Ok(Self {
            wallet,
            receive_descriptor: Some(recv_desc.to_string()),
            pub_info,
            is_multisig: false,
        })
    }

    /// Creates a multisig wallet from setup info and the local signing
    /// mnemonics (one per key this device holds).
    ///
    /// Every mnemonic's xpub in the descriptor is replaced with its xprv so a
    /// single sign pass signs with all local keys. An empty slice makes the
    /// wallet a watch-only coordinator (external signers only).
    pub fn create_multisig(
        data_dir: &Path,
        setup: &MultisigSetupInfo,
        mnemonics: &[String],
    ) -> Result<(WalletProfile, Self), TemplarError> {
        let (recv_desc, change_desc) = setup.build_descriptors()?;

        let (sign_recv, sign_change, local_fps) = if mnemonics.is_empty() {
            (recv_desc.clone(), change_desc.clone(), Vec::new())
        } else {
            Self::multisig_descriptors_with_signing_keys(
                mnemonics,
                setup,
                &recv_desc,
                &change_desc,
            )?
        };

        let profile = WalletProfile::Multisig {
            name: setup.name.clone(),
            required_sigs: setup.required_sigs,
            total_signers: setup.total_signers,
            cosigner_xpubs: setup.xpubs.clone(),
            receive_descriptor: sign_recv.clone(),
            change_descriptor: sign_change.clone(),
            local_fingerprint: local_fps.first().cloned(),
            local_fingerprints: local_fps,
            // Bitcoin-only path: the Liquid side is built by the FFI layer,
            // which is where the seeds are known.
            local_mnemonics: Vec::new(),
        };

        let mut store = ProfileStore::load(data_dir);
        store.upsert(profile.clone());
        store
            .save(data_dir)
            .map_err(|e| BitcoinError::TxBuildFailed(format!("Failed to save profile: {e}")))?;

        // This path predates the registry and has no wallet id: the profile
        // key is the only name the database can go by.
        let wm = Self::from_multisig_profile(data_dir, &profile, &profile.key())?;
        Ok((profile, wm))
    }

    // ── Core API ─────────────────────────────────────────────────────────────

    /// Syncs the wallet with the Electrum server.
    ///
    /// **Blocking** — call from a background thread.
    /// No other wallet method may be called during sync (BDK RefCell).
    /// Wrapped in `catch_unwind` to prevent RefCell panics from crashing the app.
    pub fn sync(&self) -> Result<(), TemplarError> {
        // Connect on demand: the wallet must open (and derive addresses) fully
        // offline, so the Electrum connection only exists while syncing. A
        // fresh connection per sync also survives servers dropping idle links.
        let blockchain = make_electrum_blockchain()?;
        let this = std::panic::AssertUnwindSafe(self);
        catch_bdk(move || {
            this.wallet
                .sync(&blockchain, SyncOptions::default())
                .map_err(|e| BitcoinError::SyncFailed(e.to_string()))?;
            Ok(())
        })
    }

    /// Returns the wallet balance.
    ///
    /// Wrapped in `catch_unwind` to prevent RefCell panics from crashing the app.
    pub fn get_balance(&self) -> Result<bdk::Balance, TemplarError> {
        let this = std::panic::AssertUnwindSafe(self);
        catch_bdk(move || {
            this.wallet
                .get_balance()
                .map_err(|e| BitcoinError::SyncFailed(format!("Balance failed: {e}")).into())
        })
    }

    /// Returns the receive address: the last revealed address if it is still
    /// unused, otherwise the next one.
    ///
    /// `LastUnused` (not `New`) on purpose: revealing a fresh address on every
    /// receive-screen visit permanently inflates the derivation index, and any
    /// wallet that later imports this descriptor (watch-only here, or external
    /// software with the standard gap limit of 20) stops scanning at the first
    /// unused gap and misses funds parked at high indexes.
    ///
    /// Wrapped in `catch_unwind` to prevent RefCell panics from crashing the app.
    pub fn get_new_address(&self) -> Result<AddressInfo, TemplarError> {
        let this = std::panic::AssertUnwindSafe(self);
        catch_bdk(move || {
            this.wallet
                .get_address(AddressIndex::LastUnused)
                .map_err(|e| BitcoinError::InvalidDescriptor(format!("Address failed: {e}")).into())
        })
    }

    /// Derives the *next* receive address, bumping the wallet's address index
    /// even when the current one has never been used.
    ///
    /// [`get_new_address`] returns `LastUnused`, so opening the receive screen
    /// twice shows the same address (correct: an unused address should be
    /// reused rather than burned). The "New address" button must hand out a
    /// genuinely different one, which is what `AddressIndex::New` does.
    pub fn get_fresh_address(&self) -> Result<AddressInfo, TemplarError> {
        let this = std::panic::AssertUnwindSafe(self);
        catch_bdk(move || {
            this.wallet
                .get_address(AddressIndex::New)
                .map_err(|e| BitcoinError::InvalidDescriptor(format!("Address failed: {e}")).into())
        })
    }

    /// Lists all unspent transaction outputs.
    ///
    /// Wrapped in `catch_unwind` to prevent RefCell panics from crashing the app.
    pub fn list_unspent(&self) -> Result<Vec<bdk::LocalUtxo>, TemplarError> {
        let this = std::panic::AssertUnwindSafe(self);
        catch_bdk(move || {
            this.wallet
                .list_unspent()
                .map_err(|e| BitcoinError::SyncFailed(format!("List unspent failed: {e}")).into())
        })
    }

    /// Builds an unsigned transaction (PSBT).
    ///
    /// Not wrapped in catch_unwind — requires mutable wallet builder access.
    /// The GUI ensures the Mutex is held exclusively during this call.
    pub fn create_tx(
        &self,
        recipient: &str,
        amount: u64,
        fee_rate: f32,
        op_return_msg: Option<String>,
        selected_utxos: Option<Vec<bdk::bitcoin::OutPoint>>,
    ) -> Result<PartiallySignedTransaction, TemplarError> {
        self.create_tx_multi(
            &[(recipient.to_string(), amount, false)],
            fee_rate,
            op_return_msg,
            selected_utxos.map(|v| v.iter().map(|o| o.to_string()).collect()),
            &BTreeSet::new(),
        )
    }

    /// Builds an unsigned transaction (PSBT) paying multiple recipients.
    ///
    /// Each recipient is `(address, amount_sats, send_max)`. At most one may
    /// set `send_max`: that output receives everything left after the fixed
    /// recipients and the fee (`drain_to`), so no change output is created.
    /// With manual coin selection the drain covers the selected coins;
    /// otherwise the whole wallet is swept (`drain_wallet`).
    ///
    /// When `selected_outpoints` (each `"txid:vout"`) is given, spends only
    /// those coins (`manually_selected_only`); otherwise BDK's coin selection
    /// picks inputs.
    ///
    /// `frozen` coins are never spent: BDK's selection (and MAX) leaves them
    /// out, and a manual selection that names one is refused.
    pub fn create_tx_multi(
        &self,
        recipients: &[(String, u64, bool)],
        fee_rate: f32,
        op_return_msg: Option<String>,
        selected_outpoints: Option<Vec<String>>,
        frozen: &BTreeSet<String>,
    ) -> Result<PartiallySignedTransaction, TemplarError> {
        if recipients.is_empty() {
            return Err(BitcoinError::TxBuildFailed("No recipients".into()).into());
        }

        let fee_rate = checked_fee_rate(fee_rate)?;
        let mut b = self.wallet.build_tx();
        let mut drain_script = None;
        for (recipient, amount, send_max) in recipients {
            let address = Address::from_str(recipient)
                .map_err(|e| BitcoinError::TxBuildFailed(format!("Invalid address: {e}")))?
                .require_network(Network::Testnet)
                .map_err(|e| BitcoinError::TxBuildFailed(format!("Wrong network: {e}")))?;
            if *send_max {
                if drain_script.is_some() {
                    return Err(BitcoinError::TxBuildFailed(
                        "Only one output can send the maximum".into(),
                    )
                    .into());
                }
                drain_script = Some(address.script_pubkey());
            } else {
                b.add_recipient(address.script_pubkey(), *amount);
            }
        }
        b.fee_rate(fee_rate);
        // Replaceable: a transaction that underpays can be bumped instead of
        // sitting in the mempool for days.
        b.enable_rbf();
        if let Some(msg) = op_return_msg {
            b.add_data(
                &PushBytesBuf::try_from(msg.as_bytes().to_vec())
                    .map_err(|e| BitcoinError::TxBuildFailed(format!("OP_RETURN too long: {e}")))?,
            );
        }
        let manual_selection = selected_outpoints.is_some();
        if let Some(outpoints) = selected_outpoints {
            if let Some(op) = first_frozen(&outpoints, frozen) {
                return Err(BitcoinError::FrozenCoin(op).into());
            }
            let utxos = Self::parse_outpoints(&outpoints)?;
            self.reject_spent(&utxos)?;
            b.add_utxos(&utxos)
                .map_err(|e| BitcoinError::TxBuildFailed(format!("UTXO selection failed: {e}")))?;
            b.manually_selected_only();
        } else if !frozen.is_empty() {
            let frozen: Vec<String> = frozen.iter().cloned().collect();
            b.unspendable(Self::parse_outpoints(&frozen)?);
        }
        if let Some(script) = &drain_script {
            if !manual_selection {
                b.drain_wallet();
            }
            b.drain_to(script.clone());
        }
        let (psbt, details) = b.finish().map_err(|e| build_error(e, frozen))?;
        refuse_frozen_inputs(&psbt, frozen)?;
        // BDK folds a MAX output that would end up under the dust limit into
        // the fee and reports success; the recipient the user named would
        // then silently get nothing.
        if let Some(script) = &drain_script {
            let present = psbt
                .unsigned_tx
                .output
                .iter()
                .any(|o| &o.script_pubkey == script);
            if !present {
                return Err(BitcoinError::TxBuildFailed(
                    "The MAX output would be below the dust limit once the fee is paid — \
                     nothing is left to send there"
                        .into(),
                )
                .into());
            }
        }
        reject_absurd_fee(&psbt, details.fee)?;
        Ok(psbt)
    }

    /// Whether `script` belongs to this wallet (either keychain).
    pub fn is_mine(&self, script: &bdk::bitcoin::Script) -> bool {
        self.wallet.is_mine(script).unwrap_or(false)
    }

    /// Manual coin control must not build a double-spend: BDK's builder
    /// accepts an outpoint the database already knows as spent.
    fn reject_spent(&self, outpoints: &[bdk::bitcoin::OutPoint]) -> Result<(), TemplarError> {
        for op in outpoints {
            if let Ok(Some(utxo)) = self.wallet.get_utxo(*op) {
                if utxo.is_spent {
                    return Err(
                        BitcoinError::TxBuildFailed(format!("Coin {op} is already spent")).into(),
                    );
                }
            }
        }
        Ok(())
    }

    /// Parses `"txid:vout"` strings into BDK outpoints.
    pub fn parse_outpoints(
        outpoints: &[String],
    ) -> Result<Vec<bdk::bitcoin::OutPoint>, TemplarError> {
        let mut parsed = Vec::with_capacity(outpoints.len());
        for op in outpoints {
            let (txid_str, vout_str) = op
                .rsplit_once(':')
                .ok_or_else(|| BitcoinError::TxBuildFailed(format!("Invalid outpoint: {op}")))?;
            let txid = Txid::from_str(txid_str)
                .map_err(|e| BitcoinError::TxBuildFailed(format!("Invalid txid in {op}: {e}")))?;
            let vout: u32 = vout_str
                .parse()
                .map_err(|e| BitcoinError::TxBuildFailed(format!("Invalid vout in {op}: {e}")))?;
            parsed.push(bdk::bitcoin::OutPoint { txid, vout });
        }
        Ok(parsed)
    }

    /// Extracts the concrete inputs and outputs of an unsigned PSBT for
    /// review display. Inputs carry their outpoint and previous value;
    /// outputs are flagged as change when the script belongs to this wallet
    /// *and* the user did not ask to pay it — `recipients` lists the addresses
    /// explicitly entered in the send form, so paying yourself still reads as
    /// a recipient rather than change.
    /// OP_RETURN / non-address scripts render as a readable placeholder.
    pub fn preview_psbt_io(
        &self,
        psbt: &PartiallySignedTransaction,
        recipients: &[String],
    ) -> (Vec<TxPreviewIo>, Vec<TxPreviewIo>) {
        let addr_of = |script: &bdk::bitcoin::Script| -> String {
            Address::from_script(script, Network::Testnet)
                .map(|a| a.to_string())
                .unwrap_or_else(|_| "(non-address script)".to_string())
        };

        let inputs = psbt
            .unsigned_tx
            .input
            .iter()
            .zip(psbt.inputs.iter())
            .map(|(txin, pin)| {
                // Same resolution as the signer and the inspector: a preview
                // must never quote an amount the signature will not commit to.
                let (address, amount) = crate::bitcoin::psbt::resolve_prevout(txin, pin)
                    .0
                    .map(|u| (addr_of(&u.script_pubkey), u.value))
                    .unwrap_or_else(|| ("(unknown)".to_string(), 0));
                TxPreviewIo {
                    outpoint: Some(txin.previous_output.to_string()),
                    address,
                    amount_sats: amount,
                    is_change: false,
                }
            })
            .collect();

        let outputs = psbt
            .unsigned_tx
            .output
            .iter()
            .map(|o| {
                let address = addr_of(&o.script_pubkey);
                // Paying one of your own addresses on purpose (e.g. steering a
                // MAX output back to the wallet) is a recipient, not change.
                let requested = recipients.iter().any(|r| r == &address);
                TxPreviewIo {
                    outpoint: None,
                    amount_sats: o.value,
                    is_change: !requested && self.wallet.is_mine(&o.script_pubkey).unwrap_or(false),
                    address,
                }
            })
            .collect();

        (inputs, outputs)
    }

    /// Builds an unsigned consolidation transaction: spends exactly the given
    /// UTXOs (each formatted `"txid:vout"`) and drains them (minus fee) into a
    /// single output at `recipient`.
    ///
    /// Uses `manually_selected_only` + `drain_to` so there is no change output —
    /// the whole selected value lands in one UTXO at the destination address.
    pub fn create_consolidation_tx(
        &self,
        recipient: &str,
        fee_rate: f32,
        outpoints: &[String],
        frozen: &BTreeSet<String>,
    ) -> Result<PartiallySignedTransaction, TemplarError> {
        if outpoints.len() < 2 {
            return Err(BitcoinError::TxBuildFailed(
                "Select at least 2 UTXOs to consolidate".into(),
            )
            .into());
        }
        if let Some(op) = first_frozen(outpoints, frozen) {
            return Err(BitcoinError::FrozenCoin(op).into());
        }

        let selected_utxos = Self::parse_outpoints(outpoints)?;

        let address = Address::from_str(recipient)
            .map_err(|e| BitcoinError::TxBuildFailed(format!("Invalid address: {e}")))?
            .require_network(Network::Testnet)
            .map_err(|e| BitcoinError::TxBuildFailed(format!("Wrong network: {e}")))?;

        let fee_rate = checked_fee_rate(fee_rate)?;
        self.reject_spent(&selected_utxos)?;
        let mut b = self.wallet.build_tx();
        b.add_utxos(&selected_utxos)
            .map_err(|e| BitcoinError::TxBuildFailed(format!("UTXO selection failed: {e}")))?;
        b.manually_selected_only();
        b.drain_to(address.script_pubkey());
        b.fee_rate(fee_rate);
        b.enable_rbf();
        let (psbt, details) = b
            .finish()
            .map_err(|e| BitcoinError::TxBuildFailed(e.to_string()))?;
        refuse_frozen_inputs(&psbt, frozen)?;
        reject_absurd_fee(&psbt, details.fee)?;
        Ok(psbt)
    }

    /// Signs a PSBT with the wallet's software key.
    ///
    /// Not wrapped in catch_unwind — requires mutable PSBT reference.
    /// The GUI ensures the Mutex is held exclusively during this call.
    pub fn sign(&self, psbt: &mut PartiallySignedTransaction) -> Result<bool, TemplarError> {
        self.wallet
            .sign(psbt, SignOptions::default())
            .map_err(|e| BitcoinError::SigningFailed(e.to_string()).into())
    }

    /// Signs a PSBT with the wallet's embedded key(s) WITHOUT attempting
    /// finalization.
    ///
    /// The co-sign flow needs `partial_sigs` and `witness_script` to survive
    /// the pass: BDK's finalizer strips them (per BIP-174) the moment the
    /// threshold is met, which would hide the signature count from the UI and
    /// from later signers. Finalization happens exactly once, in
    /// [`finalize_external`], right before broadcast.
    /// `trust_witness_utxo` because externally created PSBTs (Sparrow, other
    /// coordinators) often carry only the witness UTXO.
    pub fn sign_no_finalize(
        &self,
        psbt: &mut PartiallySignedTransaction,
    ) -> Result<(), TemplarError> {
        self.wallet
            .sign(
                psbt,
                SignOptions {
                    try_finalize: false,
                    trust_witness_utxo: true,
                    ..Default::default()
                },
            )
            .map(|_| ())
            .map_err(|e| BitcoinError::SigningFailed(e.to_string()).into())
    }

    /// Finalize a PSBT signed by a hardware wallet or air-gap device and extract
    /// the ready-to-broadcast transaction.
    ///
    /// BDK's `wallet.sign()` cannot finalize for watch-only wallets (no private keys
    /// to satisfy its internal miniscript checks), so we manually promote `partial_sigs`
    /// into `final_script_witness` for each P2WPKH input.  P2WSH inputs (multisig)
    /// are handled by the BDK fallback path.
    pub fn finalize_external(
        &self,
        psbt: &mut PartiallySignedTransaction,
    ) -> Result<Transaction, TemplarError> {
        // Fail fast with a clear message if the device returned no signatures at all.
        let total_sigs: usize = psbt.inputs.iter().map(|i| i.partial_sigs.len()).sum();
        let already_final = psbt
            .inputs
            .iter()
            .all(|i| i.final_script_witness.is_some() || i.final_script_sig.is_some());
        if total_sigs == 0 && !already_final {
            return Err(BitcoinError::SigningFailed(
                "No signatures in the PSBT — the hardware wallet did not sign. \
                 Check that the Bitcoin Testnet app is open on the device and try again."
                    .into(),
            )
            .into());
        }

        // If the device (via HWI) already finalized every input, trust its witness and
        // extract directly — exactly what the egui app does. Re-running BDK's
        // finalize_psbt here would rebuild the witness from the watch-only descriptor and
        // can produce a wrong pubkey ("Witness program hash mismatch") that overwrites the
        // device's correct one. Only fall through to BDK finalize when inputs are NOT yet
        // finalized (e.g. an air-gap signer that returned partial_sigs only).
        if already_final {
            return Ok(psbt.clone().extract_tx());
        }

        // Let BDK's miniscript satisfier build the final scriptSig / witness from the
        // descriptor + partial_sigs. This is correct for every script type the wallet
        // can hold (legacy P2PKH, nested P2SH-P2WPKH, native P2WPKH, P2WSH multisig),
        // unlike a hand-rolled witness which only ever works for one of them.
        let finished = self
            .wallet
            .finalize_psbt(
                psbt,
                SignOptions {
                    trust_witness_utxo: true,
                    ..Default::default()
                },
            )
            .map_err(|e| BitcoinError::SigningFailed(format!("Finalize failed: {e}")))?;

        if !finished {
            return Err(BitcoinError::SigningFailed(
                "Could not finalize the transaction — the signature does not satisfy the \
                 wallet's spending policy (wrong device, account, or descriptor)."
                    .into(),
            )
            .into());
        }

        Ok(psbt.clone().extract_tx())
    }

    /// Broadcasts a signed transaction.
    pub fn broadcast(&self, tx: Transaction) -> Result<Txid, TemplarError> {
        make_electrum_blockchain()?
            .broadcast(&tx)
            .map_err(|e| BitcoinError::BroadcastFailed(e.to_string()))?;
        Ok(tx.txid())
    }

    /// Lists all wallet transactions.
    ///
    /// Wrapped in `catch_unwind` to prevent RefCell panics from crashing the app.
    pub fn list_transactions(&self) -> Result<Vec<bdk::TransactionDetails>, TemplarError> {
        let this = std::panic::AssertUnwindSafe(self);
        catch_bdk(move || {
            this.wallet.list_transactions(false).map_err(|e| {
                BitcoinError::SyncFailed(format!("List transactions failed: {e}")).into()
            })
        })
    }

    /// Returns the current sync tip block height, or 0 if never synced.
    pub fn get_tip_height(&self) -> u32 {
        use bdk::database::Database;
        self.wallet
            .database()
            .get_sync_time()
            .ok()
            .flatten()
            .map(|st| st.block_time.height)
            .unwrap_or(0)
    }

    /// Returns all external-keychain addresses that have received funds (received_sats > 0).
    pub fn list_received_external_addresses(
        &self,
    ) -> Result<Vec<(String, u32, u64)>, TemplarError> {
        use bdk::database::Database;
        let this = std::panic::AssertUnwindSafe(self);
        catch_bdk(move || {
            let txs = this.wallet.list_transactions(true).map_err(|e| {
                TemplarError::from(BitcoinError::SyncFailed(format!(
                    "List transactions failed: {e}"
                )))
            })?;

            let mut received_per_addr: std::collections::HashMap<String, (u32, u64)> =
                std::collections::HashMap::new();

            for tx_details in &txs {
                if let Some(tx) = &tx_details.transaction {
                    for output in &tx.output {
                        if let Ok(Some((bdk::KeychainKind::External, index))) = this
                            .wallet
                            .database()
                            .get_path_from_script_pubkey(&output.script_pubkey)
                        {
                            let addr = bdk::bitcoin::Address::from_script(
                                &output.script_pubkey,
                                bdk::bitcoin::Network::Testnet,
                            )
                            .map(|a| a.to_string())
                            .unwrap_or_else(|_| format!("index-{index}"));

                            let entry = received_per_addr.entry(addr).or_insert((index, 0));
                            entry.0 = index;
                            entry.1 += output.value;
                        }
                    }
                }
            }

            let mut result: Vec<(String, u32, u64)> = received_per_addr
                .into_iter()
                .filter(|(_, (_, sats))| *sats > 0)
                .map(|(addr, (idx, sats))| (addr, idx, sats))
                .collect();
            result.sort_by_key(|(_, idx, _)| *idx);
            Ok(result)
        })
    }

    /// Derives the Liquid CT descriptor from the wallet's mnemonic.
    pub fn derive_liquid_descriptor(
        &self,
        mnemonic_str: &str,
    ) -> Result<LiquidDerivationInfo, TemplarError> {
        crate::derivation::derive_liquid_descriptor(mnemonic_str)
    }

    // ── Internal helpers ─────────────────────────────────────────────────────

    /// Extracts public info (xpub, fingerprint, path) from a descriptor string.
    pub fn pub_info_from_descriptor(
        desc: &str,
        cosigner_xpubs: &[String],
    ) -> Option<WalletPubInfo> {
        let clean = desc.split('#').next()?.trim();
        let inner = clean.split('[').nth(1)?;
        let fp = inner.split('/').next()?;
        let after = inner.split(']').nth(1)?;
        let xpub = after.split('/').next()?;
        let path_part = inner.split(']').next()?;
        let path_str = path_part
            .split_once('/')
            .map(|(_, p)| format!("m/{}", p))
            .unwrap_or_else(|| "unknown".to_string());

        Some(WalletPubInfo {
            xpub: xpub.to_string(),
            zpub: None,
            receive_descriptor: clean.to_string(),
            fingerprint: fp.to_string(),
            derivation_path: path_str,
            cosigner_xpubs: cosigner_xpubs.to_vec(),
        })
    }

    /// Replaces the local xpub in a multisig descriptor with the xprv
    /// derived from the given mnemonic, enabling software signing.
    pub fn multisig_descriptors_with_signing_key(
        mnemonic_str: &str,
        setup: &MultisigSetupInfo,
        recv_desc: &str,
        change_desc: &str,
    ) -> Result<(String, String, String), TemplarError> {
        let (r, c, fps) = Self::multisig_descriptors_with_signing_keys(
            &[mnemonic_str.to_string()],
            setup,
            recv_desc,
            change_desc,
        )?;
        Ok((r, c, fps.into_iter().next().unwrap_or_default()))
    }

    /// Replaces each matching cosigner xpub in a multisig descriptor with the
    /// xprv derived from the corresponding mnemonic. The wallet then signs
    /// with every embedded key in one pass (BDK collects all descriptor
    /// private keys into its keymap).
    ///
    /// Each xprv is derived along the keyorigin path of its cosigner entry
    /// and checked against the entry's xpub, so the signing descriptor
    /// produces exactly the addresses the co-signers compute from the xpubs.
    /// Returns the descriptors plus the fingerprints of the local keys.
    pub fn multisig_descriptors_with_signing_keys(
        mnemonics: &[String],
        setup: &MultisigSetupInfo,
        recv_desc: &str,
        change_desc: &str,
    ) -> Result<(String, String, Vec<String>), TemplarError> {
        let network = Network::Testnet;
        let secp = bdk::bitcoin::secp256k1::Secp256k1::new();

        let mut recv_sign = recv_desc.to_string();
        let mut change_sign = change_desc.to_string();
        let mut fingerprints: Vec<String> = Vec::with_capacity(mnemonics.len());

        for mnemonic_str in mnemonics {
            let mnemonic = Mnemonic::parse(mnemonic_str.trim())
                .map_err(|e| BitcoinError::InvalidMnemonic(e.to_string()))?;
            let xkey: ExtendedKey = mnemonic
                .into_extended_key()
                .map_err(|e| BitcoinError::InvalidMnemonic(e.to_string()))?;
            let master = xkey
                .into_xprv(network)
                .ok_or_else(|| BitcoinError::InvalidMnemonic("Failed to derive xprv".into()))?;
            let fp = format!("{}", master.fingerprint(&secp));

            if fingerprints.contains(&fp) {
                return Err(BitcoinError::InvalidDescriptor(format!(
                    "Duplicate local key: fingerprint {fp} appears twice"
                ))
                .into());
            }

            let local_xpub = setup
                .xpubs
                .iter()
                .find(|x| {
                    x.starts_with(&format!("[{}/", fp)) || x.starts_with(&format!("[{}]", fp))
                })
                .ok_or_else(|| {
                    BitcoinError::InvalidDescriptor(format!(
                        "No xpub found for local fingerprint {}. \
                         Make sure you added your xpub as one of the cosigners.",
                        fp
                    ))
                })?;

            // Keyorigin entry: `[fp/48'/1'/0'/2']tpub…` → origin path + xpub.
            let (origin, xpub_str) = local_xpub
                .strip_prefix('[')
                .and_then(|s| s.split_once(']'))
                .ok_or_else(|| {
                    BitcoinError::InvalidDescriptor(format!(
                        "Cosigner key is not in [fingerprint/path]xpub form: {local_xpub}"
                    ))
                })?;
            let path_str = origin
                .split_once('/')
                .map(|(_, p)| p.to_string())
                .unwrap_or_else(|| "48'/1'/0'/2'".to_string());
            let path = bdk::bitcoin::bip32::DerivationPath::from_str(&format!("m/{path_str}"))
                .map_err(|e| {
                    BitcoinError::InvalidDescriptor(format!("Bad keyorigin path {path_str}: {e}"))
                })?;

            // Derive to the keyorigin path — the embedded private key must be
            // the exact counterpart of the shared xpub or the signing wallet
            // would derive different addresses than the co-signers.
            let derived = master.derive_priv(&secp, &path).map_err(|e| {
                BitcoinError::InvalidDescriptor(format!("Derivation {path_str} failed: {e}"))
            })?;
            let derived_pub = bdk::bitcoin::bip32::ExtendedPubKey::from_priv(&secp, &derived);
            if derived_pub.to_string() != xpub_str {
                return Err(BitcoinError::InvalidDescriptor(format!(
                    "Mnemonic (fingerprint {fp}) does not match the cosigner xpub at {path_str}"
                ))
                .into());
            }

            let xprv_key = format!("[{}/{}]{}", fp, path_str, derived);
            recv_sign = recv_sign.replace(local_xpub.as_str(), &xprv_key);
            change_sign = change_sign.replace(local_xpub.as_str(), &xprv_key);
            fingerprints.push(fp);
        }

        Ok((recv_sign, change_sign, fingerprints))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // 12-word test vectors (BIP39 "abandon…about" and a second fixed phrase).
    const MN_A: &str =
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    const MN_B: &str =
        "legal winner thank year wave sausage worth useful legal winner thank yellow";

    // A third phrase, for a wallet that shares a key with another but is not
    // the same wallet.
    const MN_C: &str = "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong";

    /// A software wallet on a temporary sled tree, funded offline: one
    /// confirmed transaction paying `amounts` to its first receive addresses.
    /// Returns the manager and that transaction's id (output `i` pays
    /// `amounts[i]`).
    fn funded_wallet(amounts: &[u64]) -> (WalletManager, Txid) {
        use bdk::bitcoin::absolute::LockTime;
        use bdk::bitcoin::{OutPoint, Transaction, TxIn, TxOut};
        use bdk::database::BatchOperations;
        use bdk::{BlockTime, LocalUtxo, TransactionDetails};

        let xkey: ExtendedKey = Mnemonic::parse(MN_A).unwrap().into_extended_key().unwrap();
        let xprv = xkey.into_xprv(Network::Testnet).unwrap();
        let tree = sled::Config::new()
            .temporary(true)
            .open()
            .unwrap()
            .open_tree("funded")
            .unwrap();
        // sled handles share storage: the clone writes what the wallet reads.
        let mut db = tree.clone();
        let wallet = Wallet::new(
            &format!("wpkh({xprv}/84'/1'/0'/0/*)"),
            Some(&format!("wpkh({xprv}/84'/1'/0'/1/*)")),
            Network::Testnet,
            tree,
        )
        .unwrap();
        let output = amounts
            .iter()
            .map(|&value| TxOut {
                value,
                script_pubkey: wallet
                    .get_address(AddressIndex::New)
                    .unwrap()
                    .script_pubkey(),
            })
            .collect::<Vec<_>>();
        let funding = Transaction {
            version: 2,
            lock_time: LockTime::ZERO,
            input: vec![TxIn::default()],
            output,
        };
        let txid = funding.txid();
        db.set_tx(&TransactionDetails {
            transaction: Some(funding.clone()),
            txid,
            received: amounts.iter().sum(),
            sent: 0,
            fee: None,
            confirmation_time: Some(BlockTime {
                height: 100,
                timestamp: 1_700_000_000,
            }),
        })
        .unwrap();
        for (vout, txout) in funding.output.iter().enumerate() {
            db.set_utxo(&LocalUtxo {
                outpoint: OutPoint::new(txid, vout as u32),
                txout: txout.clone(),
                keychain: KeychainKind::External,
                is_spent: false,
            })
            .unwrap();
        }
        let manager = WalletManager {
            wallet,
            receive_descriptor: None,
            pub_info: None,
            is_multisig: false,
        };
        (manager, txid)
    }

    fn spent(psbt: &PartiallySignedTransaction) -> Vec<String> {
        psbt.unsigned_tx
            .input
            .iter()
            .map(|i| i.previous_output.to_string())
            .collect()
    }

    /// BIP173 test vector, valid on testnet.
    const PAYEE: &str = "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx";

    #[test]
    fn automatic_selection_and_max_never_spend_a_frozen_coin() {
        let (mgr, txid) = funded_wallet(&[50_000, 30_000, 20_000]);
        let whale = format!("{txid}:0");
        let frozen: BTreeSet<String> = [whale.clone()].into();

        // 40k fits in the two unfrozen coins, so the big one — the coin BDK
        // would reach for first — must stay where it is.
        let psbt = mgr
            .create_tx_multi(&[(PAYEE.into(), 40_000, false)], 1.0, None, None, &frozen)
            .unwrap();
        assert!(!spent(&psbt).contains(&whale), "{:?}", spent(&psbt));

        // MAX drains what is spendable: everything but the frozen coin.
        let psbt = mgr
            .create_tx_multi(&[(PAYEE.into(), 0, true)], 1.0, None, None, &frozen)
            .unwrap();
        let inputs = spent(&psbt);
        assert_eq!(inputs.len(), 2, "{inputs:?}");
        assert!(!inputs.contains(&whale), "{inputs:?}");
        let sent: u64 = psbt.unsigned_tx.output.iter().map(|o| o.value).sum();
        assert!(sent < 50_000 && sent > 49_000, "{sent}");

        // Nothing frozen: MAX takes all three.
        let psbt = mgr
            .create_tx_multi(
                &[(PAYEE.into(), 0, true)],
                1.0,
                None,
                None,
                &BTreeSet::new(),
            )
            .unwrap();
        assert_eq!(spent(&psbt).len(), 3);
    }

    #[test]
    fn a_payment_only_the_frozen_coin_could_cover_says_why_it_fails() {
        let (mgr, txid) = funded_wallet(&[50_000, 30_000, 20_000]);
        let frozen: BTreeSet<String> = [format!("{txid}:0")].into();

        let err = mgr
            .create_tx_multi(&[(PAYEE.into(), 60_000, false)], 1.0, None, None, &frozen)
            .unwrap_err()
            .to_string();
        assert!(err.contains("frozen coins are left out"), "{err}");
        // The same payment builds once the coin is unfrozen.
        mgr.create_tx_multi(
            &[(PAYEE.into(), 60_000, false)],
            1.0,
            None,
            None,
            &BTreeSet::new(),
        )
        .unwrap();
    }

    #[test]
    fn coin_control_and_consolidation_refuse_a_frozen_coin() {
        let (mgr, txid) = funded_wallet(&[50_000, 30_000, 20_000]);
        let frozen: BTreeSet<String> = [format!("{txid}:1")].into();
        let picked = vec![format!("{txid}:0"), format!("{txid}:1")];

        let err = mgr
            .create_tx_multi(
                &[(PAYEE.into(), 10_000, false)],
                1.0,
                None,
                Some(picked.clone()),
                &frozen,
            )
            .unwrap_err()
            .to_string();
        assert!(err.contains("is frozen"), "{err}");

        let err = mgr
            .create_consolidation_tx(PAYEE, 1.0, &picked, &frozen)
            .unwrap_err()
            .to_string();
        assert!(err.contains("is frozen"), "{err}");

        // The unfrozen pair consolidates, and the PSBT check agrees.
        let ok = vec![format!("{txid}:0"), format!("{txid}:2")];
        let psbt = mgr
            .create_consolidation_tx(PAYEE, 1.0, &ok, &frozen)
            .unwrap();
        assert!(refuse_frozen_inputs(&psbt, &frozen).is_ok());
        let err = refuse_frozen_inputs(&psbt, &[format!("{txid}:2")].into())
            .unwrap_err()
            .to_string();
        assert!(err.contains("is frozen"), "{err}");
    }

    fn setup_2of2(xpubs: Vec<String>) -> MultisigSetupInfo {
        let mut setup = MultisigSetupInfo::new("Test", 2, 2);
        setup.xpubs = xpubs;
        setup
    }

    /// A watch-only 2-of-2 profile as the registry stores it.
    fn multisig_profile(name: &str, mnemonics: [&str; 2]) -> WalletProfile {
        let xpubs: Vec<String> = mnemonics
            .iter()
            .map(|m| crate::derivation::keyorigin_xpub_bip48(m).unwrap())
            .collect();
        let mut setup = MultisigSetupInfo::new(name, 2, 2);
        setup.xpubs = xpubs.clone();
        let (recv, change) = setup.build_descriptors().unwrap();
        WalletProfile::Multisig {
            name: name.to_string(),
            required_sigs: 2,
            total_signers: 2,
            cosigner_xpubs: xpubs,
            receive_descriptor: recv,
            change_descriptor: change,
            local_fingerprint: None,
            local_fingerprints: Vec::new(),
            local_mnemonics: Vec::new(),
        }
    }

    fn fresh_dir(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("templar_{tag}_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    /// Two multisigs sharing a name and a threshold are the normal case — the
    /// wizard's default name sees to that — and each must open its own
    /// database. Keyed by name, the second one found the first one's
    /// descriptor checksum and failed every open.
    #[test]
    fn same_name_multisigs_open_separate_databases() {
        let dir = fresh_dir("ms_same_name");
        let first = multisig_profile("My Multisig Wallet", [MN_A, MN_B]);
        let second = multisig_profile("My Multisig Wallet", [MN_A, MN_C]);
        assert_eq!(
            first.key(),
            second.key(),
            "the collision this test is about"
        );

        let w1 = WalletManager::from_multisig_profile(&dir, &first, "wallet-1")
            .expect("first wallet opens");
        let w2 = WalletManager::from_multisig_profile(&dir, &second, "wallet-2")
            .expect("second wallet opens beside the first");
        assert_ne!(
            w1.get_new_address().unwrap().address,
            w2.get_new_address().unwrap().address
        );
        assert!(dir.join("bdk_ms_wallet-1").exists());
        assert!(dir.join("bdk_ms_wallet-2").exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A wallet from before databases were keyed by id keeps the directory it
    /// has; a later wallet that merely shares its name does not inherit it.
    #[test]
    fn legacy_multisig_database_stays_with_its_owner() {
        let dir = fresh_dir("ms_legacy");
        let first = multisig_profile("My Multisig Wallet", [MN_A, MN_B]);
        let second = multisig_profile("My Multisig Wallet", [MN_A, MN_C]);
        let legacy = dir.join(WalletManager::legacy_multisig_db_dir(&first));

        // Seed the name-keyed directory the way an older build did.
        {
            let (recv, change) = match &first {
                WalletProfile::Multisig {
                    receive_descriptor,
                    change_descriptor,
                    ..
                } => (receive_descriptor.clone(), change_descriptor.clone()),
                _ => unreachable!(),
            };
            let db = sled::open(&legacy).unwrap();
            let tree = db.open_tree("ms_main").unwrap();
            Wallet::new(recv.as_str(), Some(change.as_str()), Network::Testnet, tree).unwrap();
        }

        // Its owner keeps it — no new directory for wallet-1.
        let w1 = WalletManager::from_multisig_profile(&dir, &first, "wallet-1").unwrap();
        assert!(!dir.join("bdk_ms_wallet-1").exists());

        // While wallet-1 holds the lock, and again once it has let go: the
        // second wallet never touches that directory.
        let w2 = WalletManager::from_multisig_profile(&dir, &second, "wallet-2")
            .expect("locked legacy directory is not an error for another wallet");
        assert!(dir.join("bdk_ms_wallet-2").exists());
        drop(w2);
        drop(w1);
        let _ = std::fs::remove_dir_all(dir.join("bdk_ms_wallet-2"));
        WalletManager::from_multisig_profile(&dir, &second, "wallet-2")
            .expect("checksum mismatch in the legacy directory falls through");
        assert!(dir.join("bdk_ms_wallet-2").exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn wallet_opens_and_derives_addresses_without_network() {
        // Regression: constructors used to open an Electrum connection, so a
        // wallet could not even be created offline ("Bitcoin wallet not open"
        // everywhere in the alpha's offline test). Opening + address
        // derivation must stay pure sled + BIP32.
        let dir = std::env::temp_dir().join(format!("templar_offline_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let wm = WalletManager::new(&dir, MN_A).expect("offline open must succeed");
        let a0 = wm.get_new_address().expect("offline derive must succeed");
        let a1 = wm.get_fresh_address().unwrap();
        assert!(a0.address.to_string().starts_with("tb1"));
        assert_ne!(a0.address, a1.address);
        let info = wm.pub_info.as_ref().expect("pub info derived offline");
        assert!(!info.fingerprint.is_empty());
        assert!(info.xpub.starts_with("tpub"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn signing_descriptor_embeds_derived_xprv_for_each_local_key() {
        let xpub_a = crate::derivation::keyorigin_xpub_bip48(MN_A).unwrap();
        let xpub_b = crate::derivation::keyorigin_xpub_bip48(MN_B).unwrap();
        let setup = setup_2of2(vec![xpub_a.clone(), xpub_b.clone()]);
        let (recv, change) = setup.build_descriptors().unwrap();

        let (recv_sign, change_sign, fps) = WalletManager::multisig_descriptors_with_signing_keys(
            &[MN_A.to_string(), MN_B.to_string()],
            &setup,
            &recv,
            &change,
        )
        .unwrap();

        assert_eq!(fps.len(), 2);
        // Both xpubs replaced by tprvs, keyorigin path preserved.
        assert!(!recv_sign.contains(&xpub_a));
        assert!(!recv_sign.contains(&xpub_b));
        assert_eq!(recv_sign.matches("tprv").count(), 2);
        assert_eq!(recv_sign.matches("/48'/1'/0'/2']").count(), 2);
        assert_eq!(change_sign.matches("tprv").count(), 2);

        // The signing descriptor must produce the same script as the
        // xpub-only (co-signer view) descriptor — same first address.
        use bdk::bitcoin::secp256k1::Secp256k1;
        use bdk::descriptor::IntoWalletDescriptor;
        let secp = Secp256k1::new();
        let (pub_desc, _) = recv
            .as_str()
            .into_wallet_descriptor(&secp, Network::Testnet)
            .unwrap();
        let (sign_desc, _) = recv_sign
            .as_str()
            .into_wallet_descriptor(&secp, Network::Testnet)
            .unwrap();
        let spk_pub = pub_desc.at_derivation_index(0).unwrap().script_pubkey();
        let spk_sign = sign_desc.at_derivation_index(0).unwrap().script_pubkey();
        assert_eq!(
            spk_pub, spk_sign,
            "signing descriptor diverges from cosigner view"
        );
    }

    #[test]
    fn mnemonic_not_matching_any_cosigner_is_rejected() {
        let xpub_b = crate::derivation::keyorigin_xpub_bip48(MN_B).unwrap();
        // Setup contains only B's xpub, but we sign with A.
        let setup = setup_2of2(vec![xpub_b.clone(), xpub_b]);
        let (recv, change) = setup.build_descriptors().unwrap();
        let err = WalletManager::multisig_descriptors_with_signing_keys(
            &[MN_A.to_string()],
            &setup,
            &recv,
            &change,
        )
        .unwrap_err();
        assert!(err.to_string().contains("No xpub found"));
    }

    #[test]
    fn duplicate_local_mnemonic_is_rejected() {
        let xpub_a = crate::derivation::keyorigin_xpub_bip48(MN_A).unwrap();
        let xpub_b = crate::derivation::keyorigin_xpub_bip48(MN_B).unwrap();
        let setup = setup_2of2(vec![xpub_a, xpub_b]);
        let (recv, change) = setup.build_descriptors().unwrap();
        let err = WalletManager::multisig_descriptors_with_signing_keys(
            &[MN_A.to_string(), MN_A.to_string()],
            &setup,
            &recv,
            &change,
        )
        .unwrap_err();
        assert!(err.to_string().contains("Duplicate local key"));
    }

    /// Derives the pubkey + master fingerprint a cosigner contributes at the
    /// given absolute path (used to hand-build the PSBT's bip32_derivation).
    fn ms_key_at(
        mnemonic_str: &str,
        path: &str,
    ) -> (
        bdk::bitcoin::secp256k1::PublicKey,
        bdk::bitcoin::bip32::Fingerprint,
    ) {
        let secp = bdk::bitcoin::secp256k1::Secp256k1::new();
        let xkey: ExtendedKey = Mnemonic::parse(mnemonic_str)
            .unwrap()
            .into_extended_key()
            .unwrap();
        let master = xkey.into_xprv(Network::Testnet).unwrap();
        let fp = master.fingerprint(&secp);
        let child = master
            .derive_priv(
                &secp,
                &bdk::bitcoin::bip32::DerivationPath::from_str(path).unwrap(),
            )
            .unwrap();
        let pk = bdk::bitcoin::secp256k1::PublicKey::from_secret_key(&secp, &child.private_key);
        (pk, fp)
    }

    #[test]
    fn undersigned_multisig_psbt_must_not_finalize() {
        // Audit B7: send_bitcoin used to extract_tx() unconditionally, turning
        // a 1-of-2-signed multisig PSBT into a witness-less transaction that
        // Electrum rejects. sign() must report finalized=false so the send
        // path exports the partial PSBT instead of broadcasting.
        use bdk::bitcoin::absolute::LockTime;
        use bdk::bitcoin::psbt::PartiallySignedTransaction;
        use bdk::bitcoin::secp256k1::Secp256k1;
        use bdk::bitcoin::{OutPoint, Sequence, Transaction, TxIn, TxOut, Witness};
        use bdk::descriptor::IntoWalletDescriptor;

        let xpub_a = crate::derivation::keyorigin_xpub_bip48(MN_A).unwrap();
        let xpub_b = crate::derivation::keyorigin_xpub_bip48(MN_B).unwrap();
        let setup = setup_2of2(vec![xpub_a, xpub_b]);
        let (recv, change) = setup.build_descriptors().unwrap();

        // Wallet holding ONLY key A of the 2-of-2.
        let (recv_a, change_a, _) = WalletManager::multisig_descriptors_with_signing_keys(
            &[MN_A.to_string()],
            &setup,
            &recv,
            &change,
        )
        .unwrap();
        let dir = std::env::temp_dir().join(format!("templar_partial_ms_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let wm = WalletManager::from_descriptors(&dir, &recv_a, &change_a, "partial_ms").unwrap();

        // Hand-built PSBT spending a synthetic multisig UTXO at index 0.
        let secp = Secp256k1::new();
        let (pub_desc, _) = recv
            .as_str()
            .into_wallet_descriptor(&secp, Network::Testnet)
            .unwrap();
        let d0 = pub_desc.at_derivation_index(0).unwrap();
        let spk = d0.script_pubkey();
        let witness_script = d0.explicit_script().unwrap();

        let prev_tx = Transaction {
            version: 2,
            lock_time: LockTime::ZERO,
            input: vec![],
            output: vec![TxOut {
                value: 100_000,
                script_pubkey: spk.clone(),
            }],
        };
        let unsigned = Transaction {
            version: 2,
            lock_time: LockTime::ZERO,
            input: vec![TxIn {
                previous_output: OutPoint {
                    txid: prev_tx.txid(),
                    vout: 0,
                },
                script_sig: Default::default(),
                sequence: Sequence::ENABLE_RBF_NO_LOCKTIME,
                witness: Witness::default(),
            }],
            output: vec![TxOut {
                value: 90_000,
                script_pubkey: spk,
            }],
        };
        let mut psbt = PartiallySignedTransaction::from_unsigned_tx(unsigned).unwrap();
        psbt.inputs[0].witness_utxo = Some(prev_tx.output[0].clone());
        psbt.inputs[0].non_witness_utxo = Some(prev_tx);
        psbt.inputs[0].witness_script = Some(witness_script);
        for mn in [MN_A, MN_B] {
            let (pk, fp) = ms_key_at(mn, "m/48'/1'/0'/2'/0/0");
            psbt.inputs[0].bip32_derivation.insert(
                pk,
                (
                    fp,
                    bdk::bitcoin::bip32::DerivationPath::from_str("m/48'/1'/0'/2'/0/0").unwrap(),
                ),
            );
        }

        // One of two signatures: NOT finalized, and extracting anyway yields a
        // witness-less transaction — exactly what must never be broadcast.
        let finalized = wm.sign(&mut psbt).expect("partial signing must not error");
        assert!(
            !finalized,
            "1 of 2 signatures must not finalize a 2-of-2 PSBT"
        );
        assert_eq!(psbt.inputs[0].partial_sigs.len(), 1);
        assert!(psbt.clone().extract_tx().input[0].witness.is_empty());

        // A wallet holding BOTH keys completes the same PSBT.
        let (recv_ab, change_ab, _) = WalletManager::multisig_descriptors_with_signing_keys(
            &[MN_A.to_string(), MN_B.to_string()],
            &setup,
            &recv,
            &change,
        )
        .unwrap();
        let dir2 = std::env::temp_dir().join(format!("templar_full_ms_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir2);
        let wm2 = WalletManager::from_descriptors(&dir2, &recv_ab, &change_ab, "full_ms").unwrap();
        let finalized2 = wm2
            .sign(&mut psbt)
            .expect("completing signing must not error");
        assert!(finalized2, "2 of 2 signatures must finalize");
        assert!(!psbt.clone().extract_tx().input[0].witness.is_empty());

        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::remove_dir_all(&dir2);
    }

    /// Regression: a singlesig P2WPKH input carries no witness_script. The
    /// sign handler runs the cosigner pass on software wallets to pick up any
    /// foreign multisig inputs, so that pass must SKIP a P2WPKH input, not fail
    /// the whole PSBT. It used to return "missing witness_script", which broke
    /// every normal singlesig send at the signing step.
    #[test]
    fn cosigner_pass_skips_p2wpkh_inputs() {
        use bdk::bitcoin::absolute::LockTime;
        use bdk::bitcoin::psbt::PartiallySignedTransaction;
        use bdk::bitcoin::{OutPoint, Sequence, Transaction, TxIn, TxOut, Witness};

        let (pk, fp) = ms_key_at(MN_A, "m/84'/1'/0'/0/0");
        let spk = Address::p2wpkh(&bdk::bitcoin::PublicKey::new(pk), Network::Testnet)
            .unwrap()
            .script_pubkey();

        let prev = Transaction {
            version: 2,
            lock_time: LockTime::ZERO,
            input: vec![],
            output: vec![TxOut {
                value: 100_000,
                script_pubkey: spk.clone(),
            }],
        };
        let unsigned = Transaction {
            version: 2,
            lock_time: LockTime::ZERO,
            input: vec![TxIn {
                previous_output: OutPoint {
                    txid: prev.txid(),
                    vout: 0,
                },
                script_sig: Default::default(),
                sequence: Sequence::ENABLE_RBF_NO_LOCKTIME,
                witness: Witness::default(),
            }],
            output: vec![TxOut {
                value: 90_000,
                script_pubkey: spk,
            }],
        };
        let mut psbt = PartiallySignedTransaction::from_unsigned_tx(unsigned).unwrap();
        psbt.inputs[0].witness_utxo = Some(prev.output[0].clone());
        // Matching fingerprint, but no witness_script — a normal P2WPKH input.
        psbt.inputs[0].bip32_derivation.insert(
            pk,
            (
                fp,
                bdk::bitcoin::bip32::DerivationPath::from_str("m/84'/1'/0'/0/0").unwrap(),
            ),
        );

        let added = WalletManager::sign_psbt_as_cosigner(MN_A, &mut psbt)
            .expect("cosigner pass must skip a P2WPKH input, not fail on it");
        assert_eq!(added, 0, "no wsh input to cosign, so nothing is added");
    }

    #[test]
    fn catch_bdk_returns_ok_on_success() {
        let result: Result<i32, TemplarError> = catch_bdk(|| Ok(42));
        assert_eq!(result.unwrap(), 42);
    }

    #[test]
    fn catch_bdk_returns_err_on_error() {
        let result: Result<i32, TemplarError> =
            catch_bdk(|| Err(BitcoinError::WalletNotAvailable.into()));
        assert!(result.is_err());
    }

    #[test]
    fn catch_bdk_catches_str_panic() {
        let result: Result<i32, TemplarError> = catch_bdk(|| panic!("RefCell already borrowed"));
        let err = result.unwrap_err();
        assert!(err.to_string().contains("RefCell"));
    }

    #[test]
    fn catch_bdk_catches_string_panic() {
        let result: Result<i32, TemplarError> =
            catch_bdk(|| panic!("{}", "dynamic panic message".to_string()));
        let err = result.unwrap_err();
        assert!(err.to_string().contains("dynamic panic"));
    }

    #[test]
    fn catch_bdk_catches_unknown_panic() {
        let result: Result<i32, TemplarError> = catch_bdk(|| {
            std::panic::panic_any(42i32); // not a string
        });
        let err = result.unwrap_err();
        assert!(err.to_string().contains("Unknown panic"));
    }

    // Network debug probe: scan the field-test tpub and print each UTXO's
    // keychain + derivation index. Run manually:
    // cargo test -p templar-core debug_watch_only_scan -- --ignored --nocapture
    #[test]
    #[ignore]
    fn debug_watch_only_scan() {
        use bdk::database::Database;
        let tpub = "tpubDCVwWj4hEpeWNFcWe3Eo1DrkLnPC4c2iitjw5wAuTkSZgofJbRMD4KESh1uhsqLCCjcjR36JooEFwfWf1ezwmAfjcPCxc7KNtnfBCrMPdtT";
        let recv = format!("wpkh([f0b68896/84'/1'/0']{tpub}/0/*)");
        let change = format!("wpkh([f0b68896/84'/1'/0']{tpub}/1/*)");
        let dir = std::env::temp_dir().join(format!("templar_dbg_scan_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let wm = WalletManager::from_descriptors(&dir, &recv, &change, "dbgscan").unwrap();
        let shallow = ElectrumBlockchain::from_config(&ElectrumBlockchainConfig {
            url: electrum_endpoint(),
            socks5: None,
            retry: 3,
            timeout: Some(5),
            stop_gap: 20,
            validate_domain: true,
        })
        .unwrap();
        wm.wallet.sync(&shallow, SyncOptions::default()).unwrap();
        println!("after gap-20 sync: {:?}", wm.get_balance().unwrap());
        wm.sync().unwrap(); // default blockchain, stop_gap 200
        let bal = wm.get_balance().unwrap();
        println!("after gap-200 resync: {:?}", bal);
        for u in wm.wallet.list_unspent().unwrap() {
            let path = wm
                .wallet
                .database()
                .get_path_from_script_pubkey(&u.txout.script_pubkey)
                .unwrap();
            println!(
                "utxo {}:{} {} sats keychain={:?} path={:?}",
                u.outpoint.txid, u.outpoint.vout, u.txout.value, u.keychain, path
            );
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn pub_info_from_descriptor_valid() {
        let desc = "wpkh([aabbccdd/84'/1'/0']tpubDEF123/0/*)#checksum";
        let info = WalletManager::pub_info_from_descriptor(desc, &[]);
        assert!(info.is_some());
        let info = info.unwrap();
        assert_eq!(info.fingerprint, "aabbccdd");
        assert!(info.xpub.starts_with("tpubDEF123"));
    }

    #[test]
    fn pub_info_from_descriptor_no_checksum() {
        let desc = "wpkh([abcd1234/84'/1'/0']tpubXYZ/0/*)";
        let info = WalletManager::pub_info_from_descriptor(desc, &[]);
        assert!(info.is_some());
        let info = info.unwrap();
        assert_eq!(info.fingerprint, "abcd1234");
    }

    #[test]
    fn pub_info_from_descriptor_invalid() {
        let info = WalletManager::pub_info_from_descriptor("invalid", &[]);
        assert!(info.is_none());
    }

    #[test]
    fn pub_info_with_cosigner_xpubs() {
        let desc = "wsh(sortedmulti(2,[aabb/48'/1'/0'/2']tpubA/0/*,[ccdd/48'/1'/0'/2']tpubB/0/*))";
        let cosigners = vec!["tpubB".to_string()];
        let info = WalletManager::pub_info_from_descriptor(desc, &cosigners);
        assert!(info.is_some());
        let info = info.unwrap();
        assert_eq!(info.cosigner_xpubs.len(), 1);
    }
}
