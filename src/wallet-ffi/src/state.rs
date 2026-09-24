//! Global in-process application state shared across all FFI calls.
//! Protected by a Mutex — only one operation at a time (BDK RefCell constraint).

use std::collections::BTreeSet;
use std::path::PathBuf;

/// On-disk name of the wallet data directory under the app data root.
const CURRENT_DATA_DIR: &str = "templar_wallet";

/// File the desktop installer drops beside the executable to record the
/// wallet-data folder the user picked in the setup wizard. Plain `key=value`
/// lines, `#` comments; only `data_dir` is read.
const INSTALL_CONF_FILE: &str = "install.conf";

use templar_core::registry::vault_is_initialized;
use templar_core::{
    AppConfig, AssetInfo, AssetRegistry, CoinChain, LiquidNetwork, LiquidWalletManager, Vault,
    WalletManager, WalletRegistry,
};

/// Outcome of the last sync attempt for one chain. The UI must never claim
/// "synced" when it isn't, so the truth is recorded per chain instead of one
/// global success flag.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ChainSyncOutcome {
    /// The chain synced successfully.
    Ok,
    /// The wallet has no side on this chain — nothing to sync.
    Skipped,
    /// The sync was attempted and failed (reason attached).
    Error(String),
}

impl ChainSyncOutcome {
    /// Wire string crossing the FFI: `"ok"` | `"skipped"` | `"error: <reason>"`.
    pub fn to_wire(&self) -> String {
        match self {
            ChainSyncOutcome::Ok => "ok".to_string(),
            ChainSyncOutcome::Skipped => "skipped".to_string(),
            ChainSyncOutcome::Error(e) => format!("error: {e}"),
        }
    }
}

pub struct AppFfiState {
    pub data_dir: PathBuf,
    /// The data folder the *config* knows about: the persisted or default
    /// one, never a `TEMPLAR_DATA_DIR` override. Anything that rewrites the
    /// config must carry this, or a run against a temporary folder (the
    /// protocol's e2e harness) leaks that folder into the user's real config and
    /// the next normal launch opens the wrong vault.
    pub persisted_data_dir: PathBuf,
    pub registry: WalletRegistry,
    pub asset_registry: AssetRegistry,
    /// Liquid network every Liquid wallet is opened on: testnet, or a local
    /// Elements regtest. Persisted in `AppConfig`; `TEMPLAR_LIQUID_NETWORK`
    /// overrides it for the process lifetime (`liquid_network_env_locked`).
    /// Switching closes the open wallet — a wallet opened on one network
    /// must never be driven against the other's chain.
    pub liquid_network: LiquidNetwork,
    /// True when the network came from the environment and the setting
    /// screen must not offer to change it.
    pub liquid_network_env_locked: bool,
    /// Where the app config (`AppConfig`) is persisted. The real `~/.config`
    /// path in a normal run; a file inside the data dir under a
    /// `TEMPLAR_DATA_DIR` override or in the contract tests, so an ephemeral
    /// session never touches the user's real config.
    pub config_path: PathBuf,
    pub active_wallet_id: Option<String>,
    pub bitcoin: Option<WalletManager>,
    pub liquid: Option<LiquidWalletManager>,
    /// Per-chain result of the last `sync_wallet` call for the active wallet.
    /// `None` = never synced since this wallet was opened (cleared on
    /// `open_wallet`). `get_dashboard` derives its `sync_state` from these.
    pub last_sync_btc: Option<ChainSyncOutcome>,
    pub last_sync_liquid: Option<ChainSyncOutcome>,
    /// Unix seconds of the last completed `sync_wallet` call.
    pub last_sync_at: Option<u64>,
    /// Unlocked at-rest encryption key (C1). `None` = no vault set up, or the
    /// vault is set up but still locked. While a vault is initialized and
    /// locked, secret operations fail until `unlock_vault` succeeds.
    pub vault: Option<Vault>,
    /// Fatal condition detected at init (another instance holds the data dir,
    /// or the registry is corrupt). While set, every FFI call fails with this
    /// message instead of pretending the wallet list is empty — and no save
    /// can overwrite the data on disk.
    pub startup_error: Option<String>,
    /// Consecutive wrong app-password attempts on the *verify* path (the gate
    /// in front of seed reveals). Argon2id already makes each guess expensive,
    /// but the reveal gate can be hammered by a local script in a way the
    /// startup unlock screen cannot, so failures also cost wall-clock time.
    /// Reset on success. See `handlers::vault::verify`.
    pub verify_failures: u32,
    /// When set, `verify` refuses outright until this instant.
    pub verify_lockout_until: Option<std::time::Instant>,
    /// Exclusive advisory lock on `<data_dir>/app.lock`, held for the process
    /// lifetime. Two instances sharing one data dir would silently overwrite
    /// each other's registry (last writer wins = deleted wallets).
    _instance_lock: Option<std::fs::File>,
}

/// The wallet-data folder the desktop installer recorded beside the
/// executable, if it wrote one.
///
/// Used only as the *first-run default*. `wallet_set_data_dir`, the
/// `TEMPLAR_DATA_DIR` family of env overrides and an already-saved
/// [`AppConfig`] all take precedence, so a reinstall can never redirect an
/// existing user away from the wallets they already have.
fn installer_data_dir_default() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let conf = exe.parent()?.join(INSTALL_CONF_FILE);
    let raw = std::fs::read_to_string(&conf).ok()?;
    let dir = parse_install_conf_data_dir(&raw)?;
    eprintln!("[wallet-ffi] install-time data dir → {dir:?} (from {conf:?})");
    Some(dir)
}

fn parse_install_conf_data_dir(raw: &str) -> Option<PathBuf> {
    parse_install_conf_data_dir_with(raw, |name| std::env::var(name).ok())
}

/// Reads the `data_dir` key out of an `install.conf`. Blank lines and `#` /
/// `;` comments are skipped, the value may be quoted, and `%NAME%` references
/// are expanded through [`lookup`].
fn parse_install_conf_data_dir_with(
    raw: &str,
    lookup: impl Fn(&str) -> Option<String>,
) -> Option<PathBuf> {
    let value = raw.lines().find_map(|line| {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') || line.starts_with(';') {
            return None;
        }
        let (key, value) = line.split_once('=')?;
        key.trim()
            .eq_ignore_ascii_case("data_dir")
            .then(|| value.trim().trim_matches('"'))
    })?;
    let expanded = expand_env_refs_with(value, lookup);
    (!expanded.trim().is_empty()).then(|| PathBuf::from(expanded))
}

/// Expands Windows-style `%NAME%` environment references; `%%` is a literal
/// percent sign.
///
/// The Windows installer deliberately writes `%APPDATA%\templar_wallet`
/// unexpanded: one per-machine install then still gives every Windows account
/// its own private wallet folder, instead of pointing them all at the
/// installing user's profile.
fn expand_env_refs_with(raw: &str, lookup: impl Fn(&str) -> Option<String>) -> String {
    let mut out = String::with_capacity(raw.len());
    let mut rest = raw;
    while let Some(start) = rest.find('%') {
        out.push_str(&rest[..start]);
        let after = &rest[start + 1..];
        match after.find('%') {
            Some(0) => {
                out.push('%');
                rest = &after[1..];
            }
            Some(end) => {
                let name = &after[..end];
                match lookup(name) {
                    Some(v) => out.push_str(&v),
                    // An unset name stays visible rather than collapsing to
                    // nothing: a path that silently lost a component would
                    // create the wallet folder somewhere else entirely.
                    None => {
                        out.push('%');
                        out.push_str(name);
                        out.push('%');
                    }
                }
                rest = &after[end + 1..];
            }
            None => {
                out.push('%');
                out.push_str(after);
                rest = "";
            }
        }
    }
    out.push_str(rest);
    out
}

impl AppFfiState {
    pub fn new() -> Self {
        // TEMPLAR_DATA_DIR overrides the data directory. Each running
        // instance with a distinct value gets its own registry + sled dbs, so
        // several can run at once without fighting over sled's single-process
        // lock. Unset = default behavior.
        // A directory injected by the host through `wallet_set_data_dir`
        // (Android: the app-private support dir) wins over the environment.
        let env_override = crate::data_dir_override()
            .map(|p| p.to_string_lossy().into_owned())
            .or_else(|| std::env::var("TEMPLAR_DATA_DIR").ok())
            .filter(|d| !d.trim().is_empty());
        // Under an override, EVERY persisted path (data dir and config alike)
        // stays inside the override dir. An ephemeral session — the protocol's
        // e2e harness — therefore never writes its scratch folder or its
        // regtest setting into the user's real ~/.config, which is what used to
        // redirect the next normal launch to the wrong (empty) vault.
        let (data_dir, persisted_data_dir, config_path) = match env_override {
            Some(dir) => {
                let p = PathBuf::from(dir);
                std::fs::create_dir_all(&p).ok();
                eprintln!("[wallet-ffi] data dir override → {:?}", p);
                let cp = p.join("templar_wallet.json");
                (p.clone(), p, cp)
            }
            None => {
                // First run after a fresh install has no config yet, so the
                // folder chosen in the setup wizard supplies the default. A
                // config that already exists always wins: reinstalling must
                // never point an existing user at an empty data folder.
                let saved = AppConfig::load();
                let installed = installer_data_dir_default();
                let adopted_install_default = saved.is_none() && installed.is_some();
                let cfg = saved.unwrap_or_else(|| AppConfig {
                    data_dir: installed.unwrap_or_else(|| {
                        dirs_next::data_dir()
                            .unwrap_or_else(|| PathBuf::from("."))
                            .join(CURRENT_DATA_DIR)
                    }),
                    last_wallet_id: None,
                    liquid_network: None,
                });
                // Written back on the first run of an install that named its
                // own folder — after which the app no longer depends on the
                // file surviving beside the exe.
                if adopted_install_default {
                    let _ = cfg.save();
                }
                let dir = cfg.data_dir;
                (dir.clone(), dir, AppConfig::config_path())
            }
        };
        // Liquid network: the environment wins (a dev running against a
        // regtest node), then the setting saved in *this session's* config
        // (the override dir's own under a scratch run), then testnet.
        let saved_network = AppConfig::load_from(&config_path).and_then(|c| c.liquid_network);
        let (liquid_network, liquid_network_env_locked) = match LiquidNetwork::from_env_override() {
            Ok(Some(n)) => {
                eprintln!("[wallet-ffi] TEMPLAR_LIQUID_NETWORK override → {n}");
                (n, true)
            }
            Ok(None) => (saved_network.unwrap_or_default(), false),
            Err(e) => {
                eprintln!("[wallet-ffi] {e}; using the saved Liquid network");
                (saved_network.unwrap_or_default(), false)
            }
        };
        // HWI needs the venv's `hwi` binary (and, for the Linux pyenv setup, its
        // shared libs) findable. When launched from Flutter the process inherits
        // no venv activation, so resolve per-platform once and hand the result
        // to templar-core, which applies it to each spawned `hwi` process.
        #[cfg(feature = "hardware")]
        Self::setup_hwi_env(&data_dir);
        // One process per data dir: an exclusive advisory lock held for the
        // app's lifetime. Without it, a second instance keeps its own copy of
        // the registry in memory and each save overwrites the other's wallets.
        let mut startup_error = None;
        let instance_lock = match Self::acquire_instance_lock(&data_dir) {
            Ok(f) => Some(f),
            Err(msg) => {
                eprintln!("[wallet-ffi] {msg}");
                startup_error = Some(msg);
                None
            }
        };

        // If at-rest encryption is set up, the registry stays sealed on disk and
        // must not be read until the user unlocks. Start empty + locked; a
        // successful `unlock_vault` populates it. Otherwise load plaintext
        // (legacy installs that haven't migrated yet). A corrupt registry is a
        // fatal startup error — showing it as "no wallets" would let the next
        // save destroy every stored seed.
        let registry = if startup_error.is_some() {
            WalletRegistry::default()
        } else if vault_is_initialized(&data_dir) {
            eprintln!("[wallet-ffi] Vault initialized — registry locked until unlock");
            WalletRegistry::default()
        } else {
            match WalletRegistry::load_checked(&data_dir) {
                Ok(reg) => reg,
                Err(e) => {
                    let msg = format!(
                        "Wallet storage could not be read: {e}. Nothing was deleted — \
                         the damaged file was preserved in the data folder."
                    );
                    eprintln!("[wallet-ffi] {msg}");
                    startup_error = Some(msg);
                    WalletRegistry::default()
                }
            }
        };
        let asset_registry = Self::asset_registry_for(&liquid_network);

        eprintln!(
            "[wallet-ffi] Initialized. data_dir={:?}, wallets={}, liquid={}",
            data_dir,
            registry.len(),
            liquid_network
        );

        Self {
            data_dir,
            persisted_data_dir,
            registry,
            asset_registry,
            liquid_network,
            liquid_network_env_locked,
            config_path,
            active_wallet_id: None,
            bitcoin: None,
            liquid: None,
            last_sync_btc: None,
            last_sync_liquid: None,
            last_sync_at: None,
            vault: None,
            startup_error,
            verify_failures: 0,
            verify_lockout_until: None,
            _instance_lock: instance_lock,
        }
    }

    /// Takes the per-data-dir exclusive lock, or explains who has it.
    fn acquire_instance_lock(data_dir: &std::path::Path) -> Result<std::fs::File, String> {
        use fs2::FileExt;
        std::fs::create_dir_all(data_dir)
            .map_err(|e| format!("Cannot create data directory {data_dir:?}: {e}"))?;
        let lock_path = data_dir.join("app.lock");
        let file = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(&lock_path)
            .map_err(|e| format!("Cannot open {lock_path:?}: {e}"))?;
        file.try_lock_exclusive().map_err(|_| {
            "Another Templar Wallet instance is already using this wallet data. \
             Close the other window and reopen the app."
                .to_string()
        })?;
        Ok(file)
    }

    /// Loads the registry, decrypting when a vault is unlocked (C1). Fails if a
    /// vault is initialized but still locked.
    pub fn load_registry(&self) -> Result<WalletRegistry, String> {
        WalletRegistry::load_with_vault(&self.data_dir, self.vault.as_ref())
            .map_err(|e| e.to_string())
    }

    /// Persists the registry, encrypting when a vault is unlocked (C1).
    pub fn save_registry(&self) -> Result<(), String> {
        self.registry
            .save_with_vault(&self.data_dir, self.vault.as_ref())
            .map_err(|e| e.to_string())
    }

    /// The open wallet's frozen coins on `chain` — empty when no wallet is
    /// open. Handed to every builder and checked before every signature.
    pub fn frozen_on(&self, chain: CoinChain) -> BTreeSet<String> {
        self.active_wallet_id
            .as_deref()
            .and_then(|id| self.registry.find(id))
            .map(|e| e.frozen.on(chain).clone())
            .unwrap_or_default()
    }

    /// The asset registry for a network: the testnet defaults, plus the
    /// regtest policy asset labelled as L-BTC when on regtest (its id is
    /// node-specific, so the static table cannot know it).
    pub fn asset_registry_for(network: &LiquidNetwork) -> AssetRegistry {
        let mut registry = AssetRegistry::with_defaults();
        if network.is_regtest() {
            registry.register(AssetInfo {
                asset_id: network.policy_asset_hex(),
                ticker: "L-BTC".to_string(),
                name: "Liquid Bitcoin (regtest)".to_string(),
                precision: 8,
            });
        }
        registry
    }

    /// L-BTC asset id (hex) of the active Liquid network.
    pub fn policy_asset_hex(&self) -> String {
        self.liquid_network.policy_asset_hex()
    }

    /// Whether `asset_id` is the active network's L-BTC.
    pub fn is_policy_asset(&self, asset_id: &str) -> bool {
        self.liquid_network.is_policy_asset(asset_id)
    }

    /// Refuses `what` on a regtest, where it cannot exist (the public asset
    /// registry, the public order book, the peg provider).
    pub fn require_liquid_testnet(&self, what: &str) -> Result<(), String> {
        if self.liquid_network.is_regtest() {
            return Err(format!(
                "{what} is not available on Liquid regtest. Switch the Liquid network \
                 to testnet in Settings to use it."
            ));
        }
        Ok(())
    }

    /// Switches the Liquid network: persists it, closes whatever wallet is
    /// open (its Liquid side was built on the old network) and resets the
    /// asset registry. The caller reopens and re-syncs the wallet.
    pub fn set_liquid_network(&mut self, network: LiquidNetwork) -> Result<(), String> {
        if self.liquid_network_env_locked {
            return Err(format!(
                "The Liquid network is fixed by {} for this session; unset it to \
                 change the setting.",
                templar_core::liquid::network::ENV_NETWORK
            ));
        }
        // Persist first: a switch that only lived in memory would silently
        // revert on the next launch, with the wallet then syncing the other
        // chain again.
        // No config yet: seed it with the folder the config *should* name,
        // not the live one — under a TEMPLAR_DATA_DIR override the live one
        // is a scratch folder that must never be persisted.
        let mut cfg = AppConfig::load_from(&self.config_path).unwrap_or_else(|| AppConfig {
            data_dir: self.persisted_data_dir.clone(),
            last_wallet_id: None,
            liquid_network: None,
        });
        cfg.liquid_network = if network.is_regtest() {
            Some(network.clone())
        } else {
            None
        };
        cfg.save_to(&self.config_path)
            .map_err(|e| format!("Could not save the network setting: {e}"))?;

        if network != self.liquid_network {
            self.close_active_wallet();
        }
        self.liquid_network = network;
        self.asset_registry = Self::asset_registry_for(&self.liquid_network);
        eprintln!("[wallet-ffi] Liquid network → {}", self.liquid_network);
        Ok(())
    }

    /// Drops the open wallet managers and the per-wallet state that belongs
    /// to them. The registry (the wallet list) stays.
    pub fn close_active_wallet(&mut self) {
        self.bitcoin = None;
        self.liquid = None;
        self.active_wallet_id = None;
        self.last_sync_btc = None;
        self.last_sync_liquid = None;
        self.last_sync_at = None;
        self.asset_registry.clear_local_metadata();
    }

    /// Test-only constructor: binds the state to an explicit data directory,
    /// skipping the saved config, the `TEMPLAR_DATA_DIR` env override and the
    /// HWI env setup — all process-global, so per-test env
    /// mutation would race under the parallel test runner. Lock acquisition
    /// and registry loading behave exactly like `new()`.
    #[cfg(test)]
    pub(crate) fn new_for_test(data_dir: PathBuf) -> Self {
        let mut startup_error = None;
        let instance_lock = match Self::acquire_instance_lock(&data_dir) {
            Ok(f) => Some(f),
            Err(msg) => {
                startup_error = Some(msg);
                None
            }
        };
        let registry = if startup_error.is_some() || vault_is_initialized(&data_dir) {
            WalletRegistry::default()
        } else {
            match WalletRegistry::load_checked(&data_dir) {
                Ok(reg) => reg,
                Err(e) => {
                    startup_error = Some(format!(
                        "Wallet storage could not be read: {e}. Nothing was deleted — \
                         the damaged file was preserved in the data folder."
                    ));
                    WalletRegistry::default()
                }
            }
        };
        Self {
            config_path: data_dir.join("templar_wallet.json"),
            persisted_data_dir: data_dir.clone(),
            data_dir,
            registry,
            asset_registry: AssetRegistry::with_defaults(),
            liquid_network: LiquidNetwork::testnet(),
            liquid_network_env_locked: false,
            active_wallet_id: None,
            bitcoin: None,
            liquid: None,
            last_sync_btc: None,
            last_sync_liquid: None,
            last_sync_at: None,
            vault: None,
            startup_error,
            verify_failures: 0,
            verify_lockout_until: None,
            _instance_lock: instance_lock,
        }
    }

    /// Resolve the HWI toolchain for the current platform and hand it to
    /// templar-core, which applies it per spawned `hwi` process. The process
    /// environment is never mutated: `std::env::set_var` is undefined behavior
    /// on glibc once other threads exist, and Flutter's engine threads are
    /// running long before this code does. Resolution order:
    ///   1. `TEMPLAR_HWI_BIN` env override — respected as-is (consumed directly
    ///      by templar-core's binary lookup).
    ///   2. App-managed standalone binary at `<data_dir>/hwi/` (auto-downloaded
    ///      by the UI from bitcoin-core/HWI releases — identical on every OS).
    ///   3. App-managed venv at `<data_dir>/venv` (scripts/setup_hwi_macos.sh).
    ///   4. Nothing found — no override installed; `hwi` is looked up on PATH.
    #[cfg(feature = "hardware")]
    fn setup_hwi_env(data_dir: &std::path::Path) {
        use templar_core::bitcoin::hardware::{set_hwi_env, HwiEnv};

        if std::env::var("TEMPLAR_HWI_BIN").is_ok_and(|s| !s.trim().is_empty()) {
            eprintln!("[wallet-ffi] HWI: using TEMPLAR_HWI_BIN override");
            return;
        }

        // Platform venv layout: POSIX puts executables in bin/, Windows in Scripts\.
        let (bin_subdir, hwi_exe) = if cfg!(windows) {
            ("Scripts", "hwi.exe")
        } else {
            ("bin", "hwi")
        };

        // Standalone binary (self-contained, no venv/PYTHONPATH needed).
        let standalone = data_dir.join("hwi").join(hwi_exe);
        if standalone.is_file() {
            eprintln!(
                "[wallet-ffi] HWI: standalone binary {}",
                standalone.display()
            );
            set_hwi_env(HwiEnv {
                bin: standalone,
                ..Default::default()
            });
            return;
        }

        let venv = data_dir.join("venv");
        if !venv.join(bin_subdir).join(hwi_exe).exists() {
            eprintln!("[wallet-ffi] HWI: no venv found — relying on `hwi` in PATH");
            return;
        };

        let venv_bin = venv.join(bin_subdir);
        let hwi_bin = venv_bin.join(hwi_exe);

        // PYTHONPATH → venv site-packages, so hwilib imports resolve when the
        // shim runs. Layout differs per platform; only pass what actually exists.
        // POSIX: venv/lib/python3.X/site-packages   Windows: venv\Lib\site-packages
        let site_packages = if cfg!(windows) {
            let p = venv.join("Lib").join("site-packages");
            p.exists().then_some(p)
        } else {
            std::fs::read_dir(venv.join("lib"))
                .ok()
                .and_then(|rd| {
                    rd.filter_map(|e| e.ok()).map(|e| e.path()).find(|p| {
                        p.file_name()
                            .map(|n| n.to_string_lossy().starts_with("python3"))
                            .unwrap_or(false)
                    })
                })
                .map(|p| p.join("site-packages"))
                .filter(|p| p.exists())
        };

        eprintln!(
            "[wallet-ffi] HWI env ready: bin={} site_packages={}",
            hwi_bin.display(),
            site_packages
                .as_ref()
                .map(|p| p.display().to_string())
                .unwrap_or_else(|| "(none)".into()),
        );
        set_hwi_env(HwiEnv {
            bin: hwi_bin,
            path_prepend: Some(venv_bin),
            pythonpath_prepend: site_packages,
        });
    }
}

#[cfg(test)]
mod install_conf_tests {
    use super::*;

    fn no_env(_: &str) -> Option<String> {
        None
    }

    #[test]
    fn reads_data_dir_key() {
        let conf = "# written by the setup wizard\ndata_dir=D:\\Wallets\\Templar\n";
        assert_eq!(
            parse_install_conf_data_dir_with(conf, no_env),
            Some(PathBuf::from("D:\\Wallets\\Templar"))
        );
    }

    #[test]
    fn ignores_comments_blank_lines_and_other_keys() {
        let conf = "\n; a comment\n# another\nversion=0.1.0\n  data_dir = \"C:\\Templar\"  \n";
        assert_eq!(
            parse_install_conf_data_dir_with(conf, no_env),
            Some(PathBuf::from("C:\\Templar"))
        );
    }

    #[test]
    fn missing_or_empty_data_dir_is_none() {
        assert_eq!(parse_install_conf_data_dir_with("", no_env), None);
        assert_eq!(
            parse_install_conf_data_dir_with("version=1\n", no_env),
            None
        );
        assert_eq!(
            parse_install_conf_data_dir_with("data_dir=\n", no_env),
            None
        );
        assert_eq!(
            parse_install_conf_data_dir_with("data_dir=\"\"\n", no_env),
            None
        );
    }

    #[test]
    fn expands_env_references_per_user() {
        let conf = "data_dir=%APPDATA%\\templar_wallet\n";
        let lookup =
            |n: &str| (n == "APPDATA").then(|| "C:\\Users\\ada\\AppData\\Roaming".to_string());
        assert_eq!(
            parse_install_conf_data_dir_with(conf, lookup),
            Some(PathBuf::from(
                "C:\\Users\\ada\\AppData\\Roaming\\templar_wallet"
            ))
        );
    }

    #[test]
    fn unset_reference_is_left_visible_not_dropped() {
        assert_eq!(
            expand_env_refs_with("%NOPE%\\wallet", no_env),
            "%NOPE%\\wallet"
        );
    }

    #[test]
    fn double_percent_is_a_literal_and_a_lone_one_survives() {
        assert_eq!(expand_env_refs_with("100%% done", no_env), "100% done");
        assert_eq!(expand_env_refs_with("50% off", no_env), "50% off");
        assert_eq!(expand_env_refs_with("plain\\path", no_env), "plain\\path");
    }
}
