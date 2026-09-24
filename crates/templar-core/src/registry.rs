//! Wallet registry — persistent storage for wallet entries and profiles.

use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

use crate::error::{StorageError, TemplarError, VaultError};
use crate::frozen::FrozenCoins;
use crate::liquid::assets::AssetMetadata;
use crate::vault::{SealedSecret, Vault, VaultHeader};

/// Encrypted registry file (whole `WalletRegistry` JSON sealed with the vault key).
const ENCRYPTED_REGISTRY_FILE: &str = "registry.enc";
/// Vault header (Argon2 salt + passphrase verifier). Non-secret.
const VAULT_HEADER_FILE: &str = "vault.json";

/// Path to the vault header for a data dir.
pub fn vault_header_path(data_dir: &Path) -> PathBuf {
    data_dir.join(VAULT_HEADER_FILE)
}

/// Appends a suffix to a file *name*: `registry.json` → `registry.json.bak`.
///
/// Deliberately not `Path::with_extension`, which *replaces* the extension:
/// there `registry.json` and `registry.enc` both mapped to `registry.bak`, so
/// the sealed registry's backup and the plaintext one shared a name that said
/// nothing about which of the two it held (A1).
fn sidecar(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.file_name().unwrap_or_default().to_os_string();
    name.push(suffix);
    path.with_file_name(name)
}

/// `<path>.bak` — previous generation, kept next to the file.
fn backup_path(path: &Path) -> PathBuf {
    sidecar(path, ".bak")
}

/// `<path>.tmp` — staging file an atomic write renames into place.
fn tmp_path(path: &Path) -> PathBuf {
    sidecar(path, ".tmp")
}

/// Creates (truncating) a file only its owner can read (A3).
///
/// These files hold seeds; the default `0644` lets any other local user or
/// unsandboxed process read them. On unix the mode is set *at creation*, so
/// the file never exists world-readable, not even briefly. Windows has no mode
/// bits: [`harden_dir`] sets an inheritable owner-only ACL on the data
/// directory and [`harden_file`] tightens the file after the rename.
fn create_private(path: &Path) -> Result<fs::File, TemplarError> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(path)
            .map_err(|e| StorageError::IoError(e).into())
    }
    #[cfg(not(unix))]
    {
        fs::File::create(path).map_err(|e| StorageError::IoError(e).into())
    }
}

/// Windows has no mode bits: drop inherited ACEs and grant the current user
/// alone. Best effort — `icacls` ships with every supported Windows.
#[cfg(windows)]
fn windows_acl(path: &Path, rights: &str) {
    let Ok(user) = std::env::var("USERNAME") else {
        return;
    };
    if user.is_empty() {
        return;
    }
    let _ = std::process::Command::new("icacls")
        .arg(path)
        .arg("/inheritance:r")
        .arg("/grant:r")
        .arg(format!("{user}:{rights}"))
        .arg("/Q")
        .output();
}

/// Restricts an existing file to its owner (A3). Best effort: a permission
/// failure must never fail a save that already wrote the bytes.
pub(crate) fn harden_file(path: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o600));
    }
    #[cfg(windows)]
    windows_acl(path, "F");
    #[cfg(not(any(unix, windows)))]
    let _ = path;
}

/// Restricts the data directory to its owner and — on Windows — makes that the
/// default for everything created inside it from now on.
pub fn harden_dir(dir: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(dir, fs::Permissions::from_mode(0o700));
    }
    #[cfg(windows)]
    {
        // One `icacls` spawn per process: the inheritable ACE it sets covers
        // every file created in the directory afterwards.
        static ONCE: std::sync::Once = std::sync::Once::new();
        ONCE.call_once(|| windows_acl(dir, "(OI)(CI)F"));
    }
    #[cfg(not(any(unix, windows)))]
    let _ = dir;
}

/// Creates the data directory if missing and locks it down to the owner.
pub(crate) fn ensure_data_dir(dir: &Path) -> Result<(), TemplarError> {
    fs::create_dir_all(dir).map_err(StorageError::IoError)?;
    harden_dir(dir);
    Ok(())
}

/// Writes a file atomically: tmp file in the same directory, fsync, rename
/// over the target. A crash or power loss mid-write leaves the previous
/// version intact — these files hold wallet seeds, a torn write must never
/// be possible. The file is owner-only from the moment it exists (A3).
pub fn atomic_write(path: &Path, contents: &str) -> Result<(), TemplarError> {
    use std::io::Write;
    let tmp = tmp_path(path);
    {
        let mut f = create_private(&tmp)?;
        f.write_all(contents.as_bytes())
            .map_err(StorageError::IoError)?;
        f.sync_all().map_err(StorageError::IoError)?;
    }
    fs::rename(&tmp, path).map_err(StorageError::IoError)?;
    // The rename carries the temp file's mode on unix; on Windows the ACL has
    // to be re-applied to the final name. Also fixes files written before this
    // change, which are still 0644 on disk.
    harden_file(path);
    // Persist the rename itself (POSIX). Directories can't be fsynced on
    // Windows; the rename is already atomic there.
    #[cfg(unix)]
    if let Some(dir) = path.parent() {
        if let Ok(d) = fs::File::open(dir) {
            let _ = d.sync_all();
        }
    }
    Ok(())
}

/// Copies the current version of `path` to `<path>.bak` before it gets
/// overwritten, so one known-good generation always survives a bad save.
fn backup_previous(path: &Path) {
    if path.exists() {
        let bak = backup_path(path);
        if fs::copy(path, &bak).is_ok() {
            // The copy inherits nothing from the source: harden it explicitly,
            // it holds exactly the same secrets.
            harden_file(&bak);
        }
    }
}

/// Overwrites a file's bytes with zeros, flushes them to the device, then
/// unlinks it.
///
/// Best effort by nature: on an SSD, a journalling or copy-on-write
/// filesystem, or a Time Machine/VSS snapshot, the old blocks can survive
/// where no path reaches them. This removes the *reachable* copy — it is not a
/// guarantee against forensic recovery, and the UI must not claim otherwise.
fn shred_file(path: &Path) -> Result<(), std::io::Error> {
    use std::io::Write;
    if let Ok(meta) = fs::metadata(path) {
        if meta.is_file() {
            let mut f = fs::OpenOptions::new().write(true).open(path)?;
            let zeros = [0u8; 8192];
            let mut left = meta.len() as usize;
            while left > 0 {
                let n = left.min(zeros.len());
                f.write_all(&zeros[..n])?;
                left -= n;
            }
            f.sync_all()?;
        }
    }
    fs::remove_file(path)
}

/// Removes every readable copy of the registry once it has been sealed (A1).
///
/// `registry.json` was never the only plaintext on disk: every save left a
/// `.bak` beside it, an interrupted one could leave a `.tmp`, and an
/// unparseable file was quarantined as `registry.json.corrupt-<ts>`. Sealing
/// the vault used to delete `registry.json` alone, so a complete plaintext
/// registry — every mnemonic in it — stayed next to the encrypted one
/// indefinitely, and the user was told their seeds were now encrypted.
///
/// Anything under `registry.enc*` is the sealed side and is left alone.
/// Returns the paths removed, for logging and tests.
pub fn purge_plaintext_registry_artifacts(data_dir: &Path) -> Vec<PathBuf> {
    let mut removed = Vec::new();
    let Ok(entries) = fs::read_dir(data_dir) else {
        return removed;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if !name.starts_with("registry") || name.starts_with("registry.enc") {
            continue;
        }
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        match shred_file(&path) {
            Ok(()) => removed.push(path),
            Err(e) => eprintln!("[registry] could NOT remove plaintext {path:?}: {e}"),
        }
    }
    removed
}

/// Moves an unparseable file aside (never deletes it) so a later save cannot
/// destroy the bytes a user might still recover seeds from.
fn quarantine_corrupt(path: &Path) {
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let target = sidecar(path, &format!(".corrupt-{ts}"));
    match fs::rename(path, &target) {
        Ok(()) => eprintln!(
            "[registry] CORRUPT file preserved at {:?} — refusing to treat it as empty",
            target
        ),
        Err(e) => eprintln!(
            "[registry] failed to quarantine corrupt file {:?}: {e}",
            path
        ),
    }
}

/// True when at-rest encryption has been set up for this data dir (C1).
///
/// When this is true, secrets live only in `registry.enc` and the registry can
/// be loaded only after unlocking with the passphrase.
pub fn vault_is_initialized(data_dir: &Path) -> bool {
    vault_header_path(data_dir).exists()
}

/// Loads the vault header, if present.
pub fn load_vault_header(data_dir: &Path) -> Option<VaultHeader> {
    let path = vault_header_path(data_dir);
    let raw = fs::read_to_string(path).ok()?;
    serde_json::from_str(&raw).ok()
}

/// Persists the vault header (salt + verifier). Overwrites any existing header.
pub fn save_vault_header(data_dir: &Path, header: &VaultHeader) -> Result<(), TemplarError> {
    ensure_data_dir(data_dir)?;
    let json = serde_json::to_string_pretty(header)
        .map_err(|e| StorageError::SerializationFailed(e.to_string()))?;
    atomic_write(&vault_header_path(data_dir), &json)
}

/// Technical profile describing how a wallet is constructed.
#[derive(Serialize, Deserialize, Debug, Clone)]
pub enum WalletProfile {
    /// Software wallet with a BIP39 mnemonic.
    Software { mnemonic: String },
    /// Hardware wallet imported via HWI.
    HardwareWallet {
        device_fingerprint: String,
        device_model: String,
        receive_descriptor: String,
        change_descriptor: String,
    },
    /// Multisig wallet with `wsh(sortedmulti(...))` descriptor.
    Multisig {
        name: String,
        required_sigs: usize,
        total_signers: usize,
        cosigner_xpubs: Vec<String>,
        receive_descriptor: String,
        change_descriptor: String,
        /// First local signing key (kept for registry backward compatibility;
        /// mirrors `local_fingerprints[0]`).
        local_fingerprint: Option<String>,
        /// Every local signing key. The descriptor embeds one xprv per entry,
        /// so a single sign pass signs with all of them. Empty = watch-only
        /// coordinator (pre-multikey registries load with the default).
        #[serde(default)]
        local_fingerprints: Vec<String>,
        /// BIP39 seeds behind `local_fingerprints`, same order. Only the
        /// Liquid side needs them: LWK's `SwSigner` matches on the *master*
        /// fingerprint and derives the whole origin path itself, so the
        /// account-level xprv embedded in the Bitcoin descriptor cannot sign a
        /// PSET. Empty on Bitcoin-only multisigs and on registries written
        /// before Liquid multisig existed, which is why the Liquid side is
        /// only ever offered on wallets created with it.
        ///
        /// Sealed at rest by the vault, exactly like `Software { mnemonic }`.
        #[serde(default)]
        local_mnemonics: Vec<String>,
    },
    /// Miniscript policy wallet with complex spending conditions.
    ///
    /// Created via the policy engine (templates or custom builder).
    /// Descriptors are `wsh(miniscript)` validated by BDK 0.30.
    Policy {
        /// Template used to create this policy (e.g. "Inheritance", "Recovery").
        template_name: String,
        /// Human-readable labels for each key slot.
        key_labels: Vec<String>,
        /// Compiled receive descriptor: `wsh(...)`.
        receive_descriptor: String,
        /// Compiled change descriptor: `wsh(...)`.
        change_descriptor: String,
        /// Human-readable spending path descriptions.
        spending_paths: Vec<String>,
        /// Local signing key fingerprint (if software key participates).
        local_fingerprint: Option<String>,
    },
}

impl WalletProfile {
    /// ASCII icon for the wallet type — does not require emoji fonts.
    pub fn ascii_icon(&self) -> &'static str {
        match self {
            WalletProfile::Software { .. } => "[B]",
            WalletProfile::HardwareWallet { .. } => "[H]",
            WalletProfile::Multisig { .. } => "[M]",
            WalletProfile::Policy { .. } => "[P]",
        }
    }

    /// Short human-readable type label.
    pub fn type_label(&self) -> String {
        match self {
            WalletProfile::Software { .. } => "Software".to_string(),
            WalletProfile::HardwareWallet {
                device_fingerprint,
                device_model,
                ..
            } => {
                if device_model == "watch-only" {
                    // Pure watch-only wallet — view-only, cannot sign at all.
                    "Watch-only".to_string()
                } else if device_fingerprint == "airgap" || device_model == "air-gap" {
                    "Air-gap watch-only".to_string()
                } else {
                    format!("Hardware ({})", device_fingerprint)
                }
            }
            WalletProfile::Multisig { .. } => "Multisig".to_string(),
            WalletProfile::Policy { template_name, .. } => {
                format!("Policy ({})", template_name)
            }
        }
    }

    /// Returns true if this is a software (mnemonic-based) wallet.
    pub fn is_software(&self) -> bool {
        matches!(self, WalletProfile::Software { .. })
    }
    /// Returns true if this is a hardware wallet.
    pub fn is_hardware(&self) -> bool {
        matches!(self, WalletProfile::HardwareWallet { .. })
    }
    /// Returns true if this is a multisig wallet.
    pub fn is_multisig(&self) -> bool {
        matches!(self, WalletProfile::Multisig { .. })
    }
    /// Returns true if this is a Miniscript policy wallet.
    pub fn is_policy(&self) -> bool {
        matches!(self, WalletProfile::Policy { .. })
    }

    /// Whether this wallet type supports QR-based signing (air-gap).
    pub fn supports_qr_signing(&self) -> bool {
        match self {
            WalletProfile::HardwareWallet { device_model, .. } => {
                matches!(device_model.as_str(), "coldcard" | "seedsigner" | "jade")
            }
            WalletProfile::Multisig { .. } | WalletProfile::Policy { .. } => true,
            _ => false,
        }
    }

    /// Unique key for the sled database.
    pub fn db_key(&self) -> String {
        match self {
            WalletProfile::Software { .. } => "software".to_string(),
            WalletProfile::HardwareWallet {
                device_fingerprint, ..
            } => format!("hw_{}", device_fingerprint),
            WalletProfile::Multisig {
                name,
                required_sigs,
                total_signers,
                ..
            } => {
                let safe: String = name
                    .chars()
                    .map(|c| if c.is_alphanumeric() { c } else { '_' })
                    .collect();
                format!("multisig_{}_{}_{}", required_sigs, total_signers, safe)
            }
            WalletProfile::Policy {
                template_name,
                local_fingerprint,
                ..
            } => {
                let safe: String = template_name
                    .chars()
                    .map(|c| if c.is_alphanumeric() { c } else { '_' })
                    .collect();
                let fp = local_fingerprint.as_deref().unwrap_or("watch");
                format!("policy_{}_{}", safe, fp)
            }
        }
    }

    /// Alias for `db_key()` — backward compatibility.
    pub fn key(&self) -> String {
        self.db_key()
    }

    /// Human-readable display name for the wallet.
    pub fn display_name(&self) -> String {
        match self {
            WalletProfile::Software { .. } => "Software Wallet".to_string(),
            WalletProfile::HardwareWallet {
                device_model,
                device_fingerprint,
                ..
            } => format!(
                "{} [{}]",
                device_model,
                &device_fingerprint[..4.min(device_fingerprint.len())]
            ),
            WalletProfile::Multisig {
                name,
                required_sigs,
                total_signers,
                ..
            } => format!("{} ({}-of-{})", name, required_sigs, total_signers),
            WalletProfile::Policy { template_name, .. } => {
                format!("Policy: {}", template_name)
            }
        }
    }
}

/// Configuration for a linked Liquid wallet.
///
/// Derived automatically from the same seed as the Bitcoin wallet.
/// Stored inside `WalletEntry` for 1:1 Bitcoin ↔ Liquid linking.
#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct LiquidWalletConfig {
    /// Complete CT descriptor: `ct(slip77(key), elwpkh([fp/84'/1776'/0']xpub/<0;1>/*))`.
    pub descriptor: String,
    /// Whether the Liquid wallet has been synced at least once.
    pub ever_synced: bool,
    /// Persisted asset metadata for tokens issued or tracked by this wallet.
    ///
    /// Loaded into `AssetRegistry.local_metadata` on startup so ticker and
    /// precision survive application restarts.
    #[serde(default)]
    pub asset_metadata: Vec<AssetMetadata>,
}

/// A wallet entry in the registry.
///
/// Each wallet has a unique ID, user-assigned name, optional password
/// (empty = no lock), and a technical profile.
#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct WalletEntry {
    /// Unique short ID (8 hex chars).
    pub id: String,
    /// User-assigned name, e.g. "Alice Main", "Cold Storage".
    pub name: String,
    /// Plain-text password. Empty = no lock.
    /// Note: UI-only protection — files are not encrypted.
    pub password: String,
    /// Technical profile for the Bitcoin wallet.
    pub profile: WalletProfile,
    /// Linked Liquid wallet (derived from the same seed, path m/84'/1776'/0').
    /// None = Liquid wallet not yet created for this Bitcoin wallet.
    #[serde(default)]
    pub liquid: Option<LiquidWalletConfig>,
    /// Whether the user chose to enable the Liquid Network for this wallet.
    ///
    /// `false` (default) = Bitcoin-only: Liquid UI is hidden entirely.
    /// `true`            = Bitcoin + Liquid: Liquid tab and setup are visible.
    /// Existing wallets loaded from disk default to `false`; they can opt in
    /// via the "Enable Liquid" button in Wallet Info.
    #[serde(default)]
    pub liquid_enabled: bool,
    /// Coins the user froze on the UTXO screen. Nothing this wallet builds
    /// or signs may spend them (see [`crate::frozen`]).
    #[serde(default, skip_serializing_if = "FrozenCoins::is_empty")]
    pub frozen: FrozenCoins,
}

impl WalletEntry {
    /// Creates a new entry with a random ID.
    pub fn new(name: String, password: String, profile: WalletProfile) -> Self {
        let id = Self::generate_id();
        Self {
            id,
            name,
            password,
            profile,
            liquid: None,
            liquid_enabled: false,
            frozen: FrozenCoins::default(),
        }
    }

    /// Builder: sets `liquid_enabled` and returns `self`.
    pub fn with_liquid_enabled(mut self, enabled: bool) -> Self {
        self.liquid_enabled = enabled;
        self
    }

    /// Builder: attaches a Liquid CT descriptor, marking the wallet Liquid-enabled.
    ///
    /// The descriptor belongs here, on the entry, not in the profile's Bitcoin
    /// descriptor slot: an entry whose `receive_descriptor` is a `ct(...)` has
    /// no Bitcoin side at all, and every Bitcoin screen on it can only fail
    /// (see [`Self::has_bitcoin`]).
    pub fn with_liquid_descriptor(mut self, descriptor: String) -> Self {
        self.liquid = Some(LiquidWalletConfig {
            descriptor,
            ever_synced: false,
            asset_metadata: Vec::new(),
        });
        self.liquid_enabled = true;
        self
    }

    /// Whether this wallet has a Bitcoin side.
    ///
    /// False only for the Liquid-only hardware entries older builds produced,
    /// which stored a Liquid CT descriptor in the profile's Bitcoin descriptor
    /// slot. Opening one leaves no Bitcoin wallet behind, so anything Bitcoin
    /// asked of it — a receive address, a balance — can only answer "Bitcoin
    /// wallet not open". The UI reads this and hides those surfaces instead.
    pub fn has_bitcoin(&self) -> bool {
        match &self.profile {
            WalletProfile::HardwareWallet {
                receive_descriptor, ..
            } => !is_ct_descriptor(receive_descriptor),
            _ => true,
        }
    }

    /// Whether this wallet has a Liquid side, from either shape: a Liquid
    /// config on the entry, or a legacy Liquid-only hardware profile.
    pub fn has_liquid(&self) -> bool {
        if self.liquid.is_some() || self.liquid_enabled {
            return true;
        }
        matches!(
            &self.profile,
            WalletProfile::HardwareWallet {
                receive_descriptor, ..
            } if is_ct_descriptor(receive_descriptor)
        )
    }

    /// The Liquid descriptor this entry would open, from either shape.
    pub fn liquid_descriptor(&self) -> Option<&str> {
        if let Some(cfg) = &self.liquid {
            return Some(&cfg.descriptor);
        }
        match &self.profile {
            WalletProfile::HardwareWallet {
                receive_descriptor, ..
            } if is_ct_descriptor(receive_descriptor) => Some(receive_descriptor),
            _ => None,
        }
    }

    fn generate_id() -> String {
        let mut bytes = [0u8; 4];
        let _ = getrandom::getrandom(&mut bytes);
        hex::encode(bytes)
    }

    /// Returns true if no password is set.
    pub fn is_unlocked_without_password(&self) -> bool {
        self.password.is_empty()
    }

    /// Checks the password. Empty password accepts any input (including empty).
    pub fn check_password(&self, input: &str) -> bool {
        self.password.is_empty() || self.password == input
    }
}

/// Whether a descriptor is an Elements confidential one — `ct(...)`.
///
/// The one test that separates a Liquid descriptor from a Bitcoin one, in a
/// single place: it decides which manager a wallet opens with, and a second
/// copy of the rule is how a wallet ends up opened as the wrong chain.
pub fn is_ct_descriptor(descriptor: &str) -> bool {
    descriptor.trim_start().starts_with("ct(")
}

/// Registry of all wallets in the application.
///
/// Persisted to `<data_dir>/registry.json`.
#[derive(Serialize, Deserialize, Debug, Clone, Default)]
pub struct WalletRegistry {
    pub wallets: Vec<WalletEntry>,
}

impl WalletRegistry {
    /// Loads the registry from `<data_dir>/registry.json` (plaintext, legacy).
    ///
    /// Prefer [`WalletRegistry::load_with_vault`], which transparently handles
    /// the encrypted-at-rest case (C1). This remains for the no-vault path and
    /// for tests.
    pub fn load(data_dir: &Path) -> Self {
        Self::load_checked(data_dir).unwrap_or_default()
    }

    /// Like [`WalletRegistry::load`], but a corrupt file is an error, not an
    /// empty registry. Missing file → `Ok(empty)` (fresh install). Corrupt
    /// file → quarantined on disk (`registry.json.corrupt-<ts>`), then tries
    /// `registry.json.bak` (previous good save) before giving up.
    ///
    /// The distinction is fund-critical: treating corrupt-as-empty means the
    /// next save permanently overwrites every stored seed.
    pub fn load_checked(data_dir: &Path) -> Result<Self, TemplarError> {
        let path = data_dir.join("registry.json");
        if !path.exists() {
            return Ok(Self::default());
        }
        let raw = fs::read_to_string(&path).map_err(StorageError::IoError)?;
        match serde_json::from_str(&raw) {
            Ok(reg) => Ok(reg),
            Err(e) => {
                quarantine_corrupt(&path);
                // `registry.json.bak` since A1; `registry.bak` is what installs
                // written before that name change still have on disk.
                for bak in [backup_path(&path), path.with_extension("bak")] {
                    if !bak.exists() {
                        continue;
                    }
                    if let Ok(reg) =
                        serde_json::from_str::<Self>(&fs::read_to_string(&bak).unwrap_or_default())
                    {
                        eprintln!("[registry] recovered from {:?}", bak.file_name());
                        return Ok(reg);
                    }
                }
                Err(StorageError::SerializationFailed(format!(
                    "registry.json is corrupt ({e}); the damaged file was preserved next to it"
                ))
                .into())
            }
        }
    }

    /// Saves the registry to `<data_dir>/registry.json` (plaintext, legacy).
    ///
    /// Prefer [`WalletRegistry::save_with_vault`]. Callers that already hold a
    /// vault MUST use the vault-aware variant so secrets are never written in
    /// plain text.
    pub fn save(&self, data_dir: &Path) -> Result<(), TemplarError> {
        // Once a vault exists there is no legitimate plaintext save: the next
        // unlock reads `registry.enc` and silently shadows this file, so the
        // wallet written here disappears while its seed stays readable on disk.
        if vault_is_initialized(data_dir) {
            return Err(VaultError::Locked.into());
        }
        ensure_data_dir(data_dir)?;
        let json = serde_json::to_string_pretty(self)
            .map_err(|e| StorageError::SerializationFailed(e.to_string()))?;
        let path = data_dir.join("registry.json");
        backup_previous(&path);
        atomic_write(&path, &json)
    }

    /// Loads the registry, decrypting `registry.enc` when a vault is set up (C1).
    ///
    /// - If encryption is initialized (`vault.json` present) there must be an
    ///   unlocked `vault`; otherwise this returns [`VaultError::Locked`].
    /// - If encryption is not set up, falls back to the plaintext registry
    ///   (legacy behavior) so existing installs keep working until they migrate.
    pub fn load_with_vault(data_dir: &Path, vault: Option<&Vault>) -> Result<Self, TemplarError> {
        let enc_path = data_dir.join(ENCRYPTED_REGISTRY_FILE);
        if enc_path.exists() {
            let vault = vault.ok_or(VaultError::Locked)?;
            let raw = fs::read_to_string(&enc_path).map_err(StorageError::IoError)?;
            let sealed: SealedSecret = serde_json::from_str(&raw)
                .map_err(|e| VaultError::Corrupt(format!("registry.enc: {e}")))?;
            let plaintext = vault.open(&sealed)?;
            let registry = serde_json::from_str(plaintext.as_str())
                .map_err(|e| VaultError::Corrupt(format!("registry json: {e}")))?;
            return Ok(registry);
        }
        // No encrypted registry — legacy plaintext (or fresh install).
        // Corrupt plaintext must surface as an error here too, never as an
        // empty registry a later save would overwrite.
        Self::load_checked(data_dir)
    }

    /// Saves the registry, encrypting to `registry.enc` when a vault is present.
    ///
    /// With a vault: the whole registry JSON is sealed and any stale plaintext
    /// `registry.json` is removed so secrets never linger unencrypted. Without a
    /// vault: writes plaintext (legacy) — only used before the user sets a
    /// passphrase.
    pub fn save_with_vault(
        &self,
        data_dir: &Path,
        vault: Option<&Vault>,
    ) -> Result<(), TemplarError> {
        let Some(vault) = vault else {
            // `save(..)` refuses when a vault exists — never silently downgrade
            // an encrypted install back to plaintext (A2).
            return self.save(data_dir);
        };
        ensure_data_dir(data_dir)?;
        let json = serde_json::to_string(self)
            .map_err(|e| StorageError::SerializationFailed(e.to_string()))?;
        let sealed = vault.seal(&json)?;
        let sealed_json = serde_json::to_string_pretty(&sealed)
            .map_err(|e| StorageError::SerializationFailed(e.to_string()))?;
        let enc = data_dir.join(ENCRYPTED_REGISTRY_FILE);
        backup_previous(&enc);
        atomic_write(&enc, &sealed_json)?;
        // Only now that the sealed copy is on disk: shred every plaintext
        // artifact — registry.json, its .bak, a stale .tmp, any corrupt-<ts>
        // quarantine (A1). Doing it before the write would risk losing the
        // registry entirely if the seal failed.
        for removed in purge_plaintext_registry_artifacts(data_dir) {
            eprintln!(
                "[registry] plaintext artifact shredded: {:?}",
                removed.file_name()
            );
        }
        // The legacy profile store is a separate file this app no longer
        // writes, but old installs may still have one — and it holds mnemonics.
        let legacy_profiles = data_dir.join("profiles.json");
        if legacy_profiles.exists() {
            eprintln!(
                "[registry] WARNING: legacy {:?} is still on disk in plaintext and is NOT \
                 covered by the vault — delete it once its wallets are in the registry",
                legacy_profiles
            );
        }
        Ok(())
    }

    /// Adds a wallet entry to the registry.
    pub fn add(&mut self, entry: WalletEntry) {
        self.wallets.push(entry);
    }

    /// Finds a wallet by its unique ID.
    pub fn find(&self, id: &str) -> Option<&WalletEntry> {
        self.wallets.iter().find(|w| w.id == id)
    }

    /// Finds a mutable wallet by its unique ID.
    pub fn find_mut(&mut self, id: &str) -> Option<&mut WalletEntry> {
        self.wallets.iter_mut().find(|w| w.id == id)
    }

    /// Removes a wallet by ID.
    pub fn remove(&mut self, id: &str) {
        self.wallets.retain(|w| w.id != id);
    }

    /// Returns true if the registry contains no wallets.
    pub fn is_empty(&self) -> bool {
        self.wallets.is_empty()
    }

    /// Returns the number of wallets in the registry.
    pub fn len(&self) -> usize {
        self.wallets.len()
    }
}

/// Legacy profile store — backward compatibility with the old profile system.
#[derive(Serialize, Deserialize, Debug, Clone, Default)]
pub struct ProfileStore {
    pub profiles: Vec<WalletProfile>,
}

impl ProfileStore {
    pub fn load(data_dir: &Path) -> Self {
        let path = data_dir.join("profiles.json");
        if !path.exists() {
            return Self::default();
        }
        serde_json::from_str(&fs::read_to_string(path).unwrap_or_default()).unwrap_or_default()
    }

    pub fn save(&self, data_dir: &Path) -> Result<(), TemplarError> {
        let json = serde_json::to_string_pretty(self)
            .map_err(|e| StorageError::SerializationFailed(e.to_string()))?;
        ensure_data_dir(data_dir)?;
        atomic_write(&data_dir.join("profiles.json"), &json)
    }

    /// Inserts or updates a profile by its key.
    pub fn upsert(&mut self, profile: WalletProfile) {
        let key = profile.key();
        match self.profiles.iter_mut().find(|p| p.key() == key) {
            Some(e) => *e = profile,
            None => self.profiles.push(profile),
        }
    }

    /// Finds a profile by its key string.
    pub fn find(&self, key: &str) -> Option<&WalletProfile> {
        self.profiles.iter().find(|p| p.key() == key)
    }

    /// Returns true if no profiles are stored.
    pub fn is_empty(&self) -> bool {
        self.profiles.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn temp_dir(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("templar_reg_{}_{}", tag, std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    const BTC_DESC: &str = "wpkh([f0b68896/84'/1'/0']tpubDCVwWj4hEpeWNFcWe3Eo1DrkLnPC4c2iitjw5wAuTkSZgofJbRMD4KESh1uhsqLCCjcjR36JooEFwfWf1ezwmAfjcPCxc7KNtnfBCrMPdtT/0/*)";
    const CT_DESC: &str = "ct(slip77(addfe14f6d96eb091712439190737b901b6b5558d7039ed1d0dd19a7305cb747),elwpkh([f0b68896/84'/1'/0']tpub/<0;1>/*))";

    fn hw_entry(receive: &str) -> WalletEntry {
        WalletEntry::new(
            "HW".to_string(),
            String::new(),
            WalletProfile::HardwareWallet {
                device_fingerprint: "f0b68896".to_string(),
                device_model: "Blockstream Jade".to_string(),
                receive_descriptor: receive.to_string(),
                change_descriptor: String::new(),
            },
        )
    }

    /// Which chains an entry has decides which screens the UI offers. Getting
    /// this wrong is what produced a Bitcoin receive tab on a Liquid-only
    /// wallet, whose only possible answer was "Bitcoin wallet not open".
    #[test]
    fn a_liquid_only_entry_reports_no_bitcoin_side() {
        let liquid_only = hw_entry(CT_DESC);
        assert!(!liquid_only.has_bitcoin());
        assert!(
            liquid_only.has_liquid(),
            "a ct() profile *is* the Liquid side"
        );
        assert_eq!(liquid_only.liquid_descriptor(), Some(CT_DESC));

        let btc_only = hw_entry(BTC_DESC);
        assert!(btc_only.has_bitcoin());
        assert!(!btc_only.has_liquid());
        assert_eq!(btc_only.liquid_descriptor(), None);
    }

    /// One device, one wallet, both chains — the shape a Jade pairing produces.
    #[test]
    fn attaching_a_liquid_descriptor_keeps_the_bitcoin_side() {
        let entry = hw_entry(BTC_DESC).with_liquid_descriptor(CT_DESC.to_string());
        assert!(entry.has_bitcoin(), "the Bitcoin descriptor is untouched");
        assert!(entry.has_liquid());
        assert!(entry.liquid_enabled, "must survive a save/load round trip");
        assert_eq!(entry.liquid_descriptor(), Some(CT_DESC));
    }

    #[test]
    fn only_elements_descriptors_count_as_confidential() {
        assert!(is_ct_descriptor(CT_DESC));
        assert!(is_ct_descriptor("  ct(elip151,elwpkh(x))"));
        assert!(!is_ct_descriptor(BTC_DESC));
        // A Bitcoin descriptor that merely mentions the letters must not match.
        assert!(!is_ct_descriptor(
            "wpkh([f0b68896/84'/1'/0']tpub/0/*)#ct1234"
        ));
        assert!(!is_ct_descriptor(""));
    }

    #[test]
    fn corrupt_registry_is_error_not_empty_and_bytes_survive() {
        let dir = temp_dir("corrupt");
        fs::write(dir.join("registry.json"), "{ this is not json").unwrap();
        let res = WalletRegistry::load_checked(&dir);
        assert!(res.is_err(), "corrupt file must not load as empty registry");
        // Bytes preserved in a quarantine file, original gone.
        let quarantined: Vec<_> = fs::read_dir(&dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().contains("corrupt-"))
            .collect();
        assert_eq!(quarantined.len(), 1, "corrupt bytes must be preserved");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn corrupt_registry_recovers_from_bak() {
        let dir = temp_dir("bak");
        let mut reg = WalletRegistry::default();
        reg.add(WalletEntry::new(
            "Wallet One".into(),
            String::new(),
            software_profile(),
        ));
        reg.save(&dir).unwrap();
        reg.add(WalletEntry::new(
            "Wallet Two".into(),
            String::new(),
            software_profile(),
        ));
        reg.save(&dir).unwrap(); // .bak now holds the one-wallet version
        fs::write(dir.join("registry.json"), "garbage").unwrap();
        let recovered = WalletRegistry::load_checked(&dir).expect("bak should recover");
        assert_eq!(recovered.len(), 1);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn save_is_atomic_and_keeps_backup() {
        let dir = temp_dir("atomic");
        let mut reg = WalletRegistry::default();
        reg.add(WalletEntry::new(
            "Wallet One".into(),
            String::new(),
            software_profile(),
        ));
        reg.save(&dir).unwrap();
        reg.add(WalletEntry::new(
            "Wallet Two".into(),
            String::new(),
            software_profile(),
        ));
        reg.save(&dir).unwrap();
        assert!(dir.join("registry.json").exists());
        assert!(
            dir.join("registry.json.bak").exists(),
            "previous generation kept"
        );
        assert!(!dir.join("registry.json.tmp").exists(), "no tmp litter");
        let bak: WalletRegistry =
            serde_json::from_str(&fs::read_to_string(dir.join("registry.json.bak")).unwrap())
                .unwrap();
        assert_eq!(bak.len(), 1);
        let _ = fs::remove_dir_all(&dir);
    }

    /// A1 — the whole point of the vault is that no readable copy is left.
    #[test]
    fn sealing_the_vault_shreds_every_plaintext_artifact() {
        use crate::vault::Vault;
        let dir = temp_dir("purge");
        let mut reg = WalletRegistry::default();
        reg.add(WalletEntry::new(
            "SW".into(),
            String::new(),
            software_profile(),
        ));
        // Two plaintext saves: registry.json + registry.json.bak. Plus the
        // artifacts an interrupted save or a corrupt file leaves behind, and
        // the pre-A1 backup name an existing install still has on disk.
        reg.save(&dir).unwrap();
        reg.save(&dir).unwrap();
        let plaintext = fs::read_to_string(dir.join("registry.json")).unwrap();
        fs::write(dir.join("registry.bak"), &plaintext).unwrap();
        fs::write(dir.join("registry.json.tmp"), &plaintext).unwrap();
        fs::write(dir.join("registry.json.corrupt-1700000000"), &plaintext).unwrap();

        let (vault, header) =
            Vault::create_with_params("test passphrase", crate::vault::KdfParams::FAST_FOR_TESTS)
                .unwrap();
        save_vault_header(&dir, &header).unwrap();
        reg.save_with_vault(&dir, Some(&vault)).unwrap();

        assert!(dir.join(ENCRYPTED_REGISTRY_FILE).exists());
        for leftover in fs::read_dir(&dir).unwrap().filter_map(|e| e.ok()) {
            let name = leftover.file_name().to_string_lossy().to_string();
            let body = fs::read_to_string(leftover.path()).unwrap_or_default();
            assert!(
                !body.contains("abandon"),
                "{name} still holds the mnemonic in plaintext"
            );
        }
        assert!(!dir.join("registry.json").exists());
        assert!(!dir.join("registry.bak").exists());
        assert!(!dir.join("registry.json.bak").exists());
        assert!(!dir.join("registry.json.corrupt-1700000000").exists());
        let _ = fs::remove_dir_all(&dir);
    }

    /// A2 — an encrypted install must never fall back to a plaintext save.
    #[test]
    fn plaintext_save_refused_once_a_vault_exists() {
        use crate::vault::Vault;
        let dir = temp_dir("nofallback");
        let mut reg = WalletRegistry::default();
        reg.add(WalletEntry::new(
            "SW".into(),
            String::new(),
            software_profile(),
        ));
        let (_vault, header) =
            Vault::create_with_params("test passphrase", crate::vault::KdfParams::FAST_FOR_TESTS)
                .unwrap();
        save_vault_header(&dir, &header).unwrap();

        assert!(reg.save(&dir).is_err(), "plaintext save must be refused");
        assert!(
            reg.save_with_vault(&dir, None).is_err(),
            "a locked save must not downgrade to plaintext"
        );
        assert!(!dir.join("registry.json").exists());
        let _ = fs::remove_dir_all(&dir);
    }

    /// A3 — secret files must not be world-readable.
    #[cfg(unix)]
    #[test]
    fn secret_files_are_owner_only() {
        use crate::vault::Vault;
        use std::os::unix::fs::PermissionsExt;
        let dir = temp_dir("perms");
        let mut reg = WalletRegistry::default();
        reg.add(WalletEntry::new(
            "SW".into(),
            String::new(),
            software_profile(),
        ));
        reg.save(&dir).unwrap();
        reg.save(&dir).unwrap(); // second save creates the .bak

        let mode = |p: PathBuf| fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(dir.join("registry.json")), 0o600);
        assert_eq!(mode(dir.join("registry.json.bak")), 0o600);
        assert_eq!(
            fs::metadata(&dir).unwrap().permissions().mode() & 0o777,
            0o700,
            "the data dir itself must not be listable by others"
        );

        let (vault, header) =
            Vault::create_with_params("test passphrase", crate::vault::KdfParams::FAST_FOR_TESTS)
                .unwrap();
        save_vault_header(&dir, &header).unwrap();
        reg.save_with_vault(&dir, Some(&vault)).unwrap();
        assert_eq!(mode(dir.join(ENCRYPTED_REGISTRY_FILE)), 0o600);
        assert_eq!(mode(vault_header_path(&dir)), 0o600);
        let _ = fs::remove_dir_all(&dir);
    }

    fn software_profile() -> WalletProfile {
        WalletProfile::Software {
            mnemonic: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about".into(),
        }
    }

    fn hw_profile() -> WalletProfile {
        WalletProfile::HardwareWallet {
            device_fingerprint: "a1b2c3d4".into(),
            device_model: "ledger".into(),
            receive_descriptor: "wpkh([a1b2c3d4/84'/1'/0']tpub.../0/*)".into(),
            change_descriptor: "wpkh([a1b2c3d4/84'/1'/0']tpub.../1/*)".into(),
        }
    }

    fn multisig_profile() -> WalletProfile {
        WalletProfile::Multisig {
            name: "Team Vault".into(),
            required_sigs: 2,
            total_signers: 3,
            cosigner_xpubs: vec!["xpub1".into(), "xpub2".into(), "xpub3".into()],
            receive_descriptor: "wsh(sortedmulti(2,...))".into(),
            change_descriptor: "wsh(sortedmulti(2,...))".into(),
            local_fingerprint: Some("aabbccdd".into()),
            local_fingerprints: vec!["aabbccdd".into()],
            local_mnemonics: Vec::new(),
        }
    }

    fn policy_profile() -> WalletProfile {
        WalletProfile::Policy {
            template_name: "Recovery".into(),
            key_labels: vec!["Primary Key".into(), "Recovery Key (delayed)".into()],
            receive_descriptor: "wsh(or_d(pk(A/0/*),and_v(v:pk(B/0/*),older(12960))))".into(),
            change_descriptor: "wsh(or_d(pk(A/1/*),and_v(v:pk(B/1/*),older(12960))))".into(),
            spending_paths: vec![
                "Sign with Primary".into(),
                "Sign with Recovery AND Wait ~90 days (alternative)".into(),
            ],
            local_fingerprint: Some("11223344".into()),
        }
    }

    #[test]
    fn wallet_profile_type_labels() {
        assert_eq!(software_profile().type_label(), "Software");
        assert_eq!(hw_profile().type_label(), "Hardware (a1b2c3d4)");
        assert_eq!(multisig_profile().type_label(), "Multisig");
        assert_eq!(policy_profile().type_label(), "Policy (Recovery)");
    }

    #[test]
    fn wallet_profile_ascii_icons() {
        assert_eq!(software_profile().ascii_icon(), "[B]");
        assert_eq!(hw_profile().ascii_icon(), "[H]");
        assert_eq!(multisig_profile().ascii_icon(), "[M]");
        assert_eq!(policy_profile().ascii_icon(), "[P]");
    }

    #[test]
    fn wallet_profile_predicates() {
        assert!(software_profile().is_software());
        assert!(!software_profile().is_hardware());
        assert!(hw_profile().is_hardware());
        assert!(multisig_profile().is_multisig());
        assert!(policy_profile().is_policy());
        assert!(!policy_profile().is_multisig());
    }

    #[test]
    fn wallet_profile_db_keys_unique() {
        let sw_key = software_profile().db_key();
        let hw_key = hw_profile().db_key();
        let ms_key = multisig_profile().db_key();
        let pol_key = policy_profile().db_key();
        assert_eq!(sw_key, "software");
        assert!(hw_key.starts_with("hw_"));
        assert!(ms_key.starts_with("multisig_"));
        assert!(pol_key.starts_with("policy_"));
        // All different
        assert_ne!(sw_key, hw_key);
        assert_ne!(hw_key, ms_key);
        assert_ne!(ms_key, pol_key);
    }

    #[test]
    fn wallet_profile_display_names() {
        assert_eq!(software_profile().display_name(), "Software Wallet");
        assert_eq!(hw_profile().display_name(), "ledger [a1b2]");
        assert_eq!(multisig_profile().display_name(), "Team Vault (2-of-3)");
        assert_eq!(policy_profile().display_name(), "Policy: Recovery");
    }

    #[test]
    fn qr_signing_support() {
        assert!(!software_profile().supports_qr_signing());
        // ledger doesn't support QR
        assert!(!hw_profile().supports_qr_signing());
        // multisig always supports QR
        assert!(multisig_profile().supports_qr_signing());
        // policy supports QR
        assert!(policy_profile().supports_qr_signing());
        // coldcard supports QR
        let coldcard = WalletProfile::HardwareWallet {
            device_fingerprint: "11223344".into(),
            device_model: "coldcard".into(),
            receive_descriptor: String::new(),
            change_descriptor: String::new(),
        };
        assert!(coldcard.supports_qr_signing());
    }

    #[test]
    fn wallet_entry_password() {
        let entry = WalletEntry::new("Test".into(), "secret".into(), software_profile());
        assert!(!entry.is_unlocked_without_password());
        assert!(entry.check_password("secret"));
        assert!(!entry.check_password("wrong"));

        let nopass = WalletEntry::new("Open".into(), String::new(), software_profile());
        assert!(nopass.is_unlocked_without_password());
        assert!(nopass.check_password("")); // any input accepted
        assert!(nopass.check_password("anything"));
    }

    #[test]
    fn wallet_entry_has_random_id() {
        let a = WalletEntry::new("A".into(), String::new(), software_profile());
        let b = WalletEntry::new("B".into(), String::new(), software_profile());
        assert_eq!(a.id.len(), 8); // 4 bytes = 8 hex chars
        assert_ne!(a.id, b.id);
    }

    #[test]
    fn registry_crud() {
        let mut reg = WalletRegistry::default();
        assert!(reg.is_empty());

        let entry = WalletEntry::new("Test".into(), String::new(), software_profile());
        let id = entry.id.clone();
        reg.add(entry);

        assert_eq!(reg.len(), 1);
        assert!(reg.find(&id).is_some());
        assert_eq!(reg.find(&id).unwrap().name, "Test");

        reg.find_mut(&id).unwrap().name = "Renamed".into();
        assert_eq!(reg.find(&id).unwrap().name, "Renamed");

        reg.remove(&id);
        assert!(reg.is_empty());
    }

    #[test]
    fn registry_roundtrip_json() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path();

        let mut reg = WalletRegistry::default();
        reg.add(WalletEntry::new(
            "SW".into(),
            "pw".into(),
            software_profile(),
        ));
        reg.add(WalletEntry::new("HW".into(), String::new(), hw_profile()));
        reg.add(WalletEntry::new(
            "MS".into(),
            String::new(),
            multisig_profile(),
        ));
        reg.add(WalletEntry::new(
            "POL".into(),
            String::new(),
            policy_profile(),
        ));
        reg.save(dir).unwrap();

        let loaded = WalletRegistry::load(dir);
        assert_eq!(loaded.len(), 4);
        assert_eq!(loaded.wallets[0].name, "SW");
        assert_eq!(loaded.wallets[1].name, "HW");
        assert_eq!(loaded.wallets[2].name, "MS");
        assert_eq!(loaded.wallets[3].name, "POL");
        assert!(loaded.wallets[3].profile.is_policy());

        // Verify liquid config round-trips
        let mut reg2 = loaded;
        let id = reg2.wallets[0].id.clone();
        reg2.find_mut(&id).unwrap().liquid = Some(LiquidWalletConfig {
            descriptor: "ct(slip77(abc),elwpkh(...))".into(),
            ever_synced: true,
            asset_metadata: Vec::new(),
        });
        reg2.save(dir).unwrap();

        let loaded2 = WalletRegistry::load(dir);
        let liq = loaded2.find(&id).unwrap().liquid.as_ref().unwrap();
        assert!(liq.ever_synced);
        assert!(liq.descriptor.contains("slip77"));
    }

    #[test]
    fn registry_load_missing_file() {
        let tmp = tempfile::tempdir().unwrap();
        let reg = WalletRegistry::load(tmp.path());
        assert!(reg.is_empty());
    }

    #[test]
    fn encrypted_registry_round_trip() {
        use crate::vault::Vault;
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path();

        let mut reg = WalletRegistry::default();
        reg.add(WalletEntry::new(
            "SW".into(),
            String::new(),
            software_profile(),
        ));

        let (vault, header) =
            Vault::create_with_params("test passphrase", crate::vault::KdfParams::FAST_FOR_TESTS)
                .unwrap();
        save_vault_header(dir, &header).unwrap();
        reg.save_with_vault(dir, Some(&vault)).unwrap();

        // Encrypted file is written; no plaintext registry.json remains.
        assert!(dir.join(ENCRYPTED_REGISTRY_FILE).exists());
        assert!(!dir.join("registry.json").exists());
        assert!(vault_is_initialized(dir));

        // The mnemonic must not be recoverable from the ciphertext on disk.
        let enc = fs::read_to_string(dir.join(ENCRYPTED_REGISTRY_FILE)).unwrap();
        assert!(!enc.contains("abandon"));

        // A locked load (no key) is refused, not silently empty.
        assert!(WalletRegistry::load_with_vault(dir, None).is_err());

        // Unlocking round-trips the data.
        let loaded = WalletRegistry::load_with_vault(dir, Some(&vault)).unwrap();
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded.wallets[0].name, "SW");

        // A different passphrase cannot open the vault.
        assert!(Vault::unlock("wrong passphrase", &header).is_err());
    }
}

/// Legacy wallet data — backward compatibility with `wallet_data.json`.
#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct WalletData {
    pub profile: WalletProfile,
}

impl WalletData {
    /// Loads from `<data_dir>/wallet_data.json`, supporting both old and new formats.
    pub fn load(data_dir: &Path) -> Option<Self> {
        let path = data_dir.join("wallet_data.json");
        if !path.exists() {
            return None;
        }
        let content = fs::read_to_string(&path).ok()?;
        if let Ok(d) = serde_json::from_str::<Self>(&content) {
            return Some(d);
        }
        #[derive(Deserialize)]
        struct Old {
            mnemonic: String,
        }
        if let Ok(o) = serde_json::from_str::<Old>(&content) {
            return Some(WalletData {
                profile: WalletProfile::Software {
                    mnemonic: o.mnemonic,
                },
            });
        }
        None
    }

    /// Saves to `<data_dir>/wallet_data.json`.
    pub fn save(&self, data_dir: &Path) -> Result<(), TemplarError> {
        let json = serde_json::to_string_pretty(self)
            .map_err(|e| StorageError::SerializationFailed(e.to_string()))?;
        atomic_write(&data_dir.join("wallet_data.json"), &json)
    }
}
