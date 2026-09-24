//! At-rest encryption control (security report C1).
//!
//! Exposes vault lifecycle over the FFI: check status, first-time setup
//! (migrates any existing plaintext registry into the encrypted store), unlock
//! with the passphrase, and lock. While a vault is initialized but locked, the
//! registry is empty in memory and secret operations fail until `unlock`.
//!
//! Routes: `vault_status`, `setup_vault`, `unlock_vault`, `lock_vault`,
//! `verify_vault_passphrase`, plus the stored-key pair behind the mobile
//! biometric unlock — `export_vault_key` hands the unlocked key to the app
//! (which keeps it in the platform keystore) and `unlock_vault_with_key`
//! opens the vault from it again without the passphrase or Argon2id.

use std::fmt::Write as _;

use templar_core::error::{TemplarError, VaultError};
use templar_core::registry::{load_vault_header, save_vault_header, vault_is_initialized};
use templar_core::{Vault, WalletRegistry};
use zeroize::Zeroizing;

use crate::state::AppFfiState;

/// Reports whether encryption is set up and, if so, whether it is unlocked.
/// `state` distinguishes the three cases for the UI: "none" (no vault set up),
/// "locked" (vault exists, passphrase not entered), "unlocked".
pub fn status(state: &AppFfiState) -> serde_json::Value {
    let initialized = vault_is_initialized(&state.data_dir);
    let unlocked = state.vault.is_some();
    serde_json::json!({
        "initialized": initialized,
        "unlocked": unlocked,
        "needs_migration": needs_migration(state),
        "plaintext_seed_wallets": plaintext_seed_wallets(state),
        "state": match (initialized, unlocked) {
            (false, _) => "none",
            (true, false) => "locked",
            (true, true) => "unlocked",
        },
    })
}

/// How many wallets currently keep a recovery phrase in the *plaintext*
/// registry on this device.
///
/// Non-zero only on an install that predates the mandatory-encryption rule:
/// `require_encryption_for_seed` blocks new seeds, but it is a create-time
/// check and does nothing about phrases already written. Zero once a vault
/// exists, because `setup` migrates and shreds them.
pub fn plaintext_seed_wallets(state: &AppFfiState) -> usize {
    if vault_is_initialized(&state.data_dir) {
        return 0;
    }
    state
        .registry
        .wallets
        .iter()
        .filter(|w| w.profile.is_software())
        .count()
}

/// True when this device is holding recovery phrases in cleartext and the user
/// must be made to set an app password before going any further. The UI gate
/// is not dismissible: leaving it open is the same as shipping the seeds
/// unencrypted, which is the condition the whole vault exists to remove.
pub fn needs_migration(state: &AppFfiState) -> bool {
    plaintext_seed_wallets(state) > 0
}

/// Fails when this device would end up holding a recovery phrase in plaintext
/// (security report A2).
///
/// At-rest encryption is opt-in, and a checkbox a tester skips is not a
/// security model: without a vault, `registry.json` holds every mnemonic in
/// cleartext for any local process to read, and `ensure_unlocked` degrades to a
/// no-op that leaves the whole key-export surface open. Wallet types that keep
/// no key here (hardware, air-gap, watch-only) may still run unencrypted — the
/// wizard makes that distinction in its copy.
///
/// This is the backend half of the rule, so it also covers the entry points
/// that bypass the wizard (the Restore-wallet screen, the direct
/// `/create-wallet` route).
pub fn require_encryption_for_seed(state: &AppFfiState) -> Result<(), String> {
    if !vault_is_initialized(&state.data_dir) {
        return Err(
            "Set an app password first — Templar will not store a recovery \
                    phrase on this computer unencrypted (Settings → Security)."
                .into(),
        );
    }
    Ok(())
}

/// Fails when a vault is initialized but not yet unlocked.
///
/// Every handler that reads a stored secret or persists the registry must call
/// this first: while locked the in-memory registry is empty, and saving it
/// would write a plaintext `registry.json` next to `registry.enc` — the next
/// unlock silently shadows that file, so the new wallet vanishes while its
/// seed stays in cleartext on disk.
pub fn ensure_unlocked(state: &AppFfiState) -> Result<(), String> {
    if vault_is_initialized(&state.data_dir) && state.vault.is_none() {
        return Err("Vault is locked — unlock with your passphrase first".into());
    }
    Ok(())
}

/// First-time setup: derive a vault key from `passphrase`, migrate any existing
/// plaintext registry into the encrypted store, and leave the vault unlocked.
pub fn setup(state: &mut AppFfiState, passphrase: &str) -> Result<(), String> {
    if vault_is_initialized(&state.data_dir) {
        return Err("A vault is already set up on this device. Use unlock instead.".into());
    }

    // Pull in any wallets that were stored in plaintext before migration so they
    // survive the switch to encryption.
    let existing = WalletRegistry::load(&state.data_dir);

    let (vault, header) = Vault::create(passphrase).map_err(|e| e.to_string())?;
    // Header first: it carries the Argon2 salt, and sealing the registry before
    // that salt is durable would leave `registry.enc` with no way to derive its
    // key again — every wallet lost. The reverse failure is recoverable, so it
    // is the one to take, and the rollback below undoes it.
    save_vault_header(&state.data_dir, &header).map_err(|e| e.to_string())?;
    // Writing the sealed registry also shreds every plaintext artifact (A1).
    if let Err(e) = existing.save_with_vault(&state.data_dir, Some(&vault)) {
        // Leave the install exactly as it was: with a header but no sealed
        // registry, plaintext saves are refused and the app is stuck read-only.
        let _ = std::fs::remove_file(templar_core::registry::vault_header_path(&state.data_dir));
        return Err(format!("Encryption setup failed, nothing was changed: {e}"));
    }

    state.registry = existing;
    state.vault = Some(vault);
    // `save_with_vault` shreds registry.json, its .bak, any stale .tmp and every
    // corrupt-<ts> quarantine (A1) — a migrating install must not keep a
    // readable copy of the seeds it was just told are now encrypted.
    let leftovers: Vec<_> = std::fs::read_dir(&state.data_dir)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.file_name().to_string_lossy().to_string())
        .filter(|n| n.starts_with("registry") && !n.starts_with("registry.enc"))
        .collect();
    if leftovers.is_empty() {
        eprintln!("[wallet-ffi] Vault created — registry encrypted, no plaintext left behind");
    } else {
        eprintln!("[wallet-ffi] Vault created but plaintext survived: {leftovers:?}");
    }
    Ok(())
}

/// Unlock an existing vault and load the encrypted registry into memory.
pub fn unlock(state: &mut AppFfiState, passphrase: &str) -> Result<(), String> {
    let header = load_vault_header(&state.data_dir).ok_or("No vault is set up on this device")?;
    let vault = Vault::unlock(passphrase, &header).map_err(|e| e.to_string())?;
    finish_unlock(state, vault)
}

/// Unlock an existing vault from a key a previous session handed out with
/// [`export_key`] — the mobile biometric path, where the platform keystore
/// releases the key after a fingerprint/face check and the passphrase (and
/// its Argon2id stretch) is skipped.
///
/// Malformed input is reported as such; a well-formed key that does not open
/// this vault (it was re-created after the key was stored) fails with a
/// "does not match" error. Either way the session is untouched and the UI
/// falls back to the passphrase screen.
pub fn unlock_with_key(state: &mut AppFfiState, key_hex: String) -> Result<(), String> {
    // Own the hex in zeroized storage for as long as it is needed here.
    let key_hex = Zeroizing::new(key_hex);
    let header = load_vault_header(&state.data_dir).ok_or("No vault is set up on this device")?;
    let key = key_from_hex(&key_hex)?;
    let vault = match Vault::unlock_with_key(&header, &key) {
        Ok(vault) => vault,
        Err(TemplarError::Vault(VaultError::WrongPassphrase)) => {
            return Err(
                "The stored vault key does not match this vault — unlock with your passphrase"
                    .into(),
            );
        }
        Err(e) => return Err(e.to_string()),
    };
    finish_unlock(state, vault)
}

/// Everything an unlock does once the key has been proven — one function for
/// both the passphrase and the stored-key path, so the two cannot drift: load
/// the sealed registry with the fresh key and only then install both in the
/// session. A registry that fails to load leaves the session locked.
fn finish_unlock(state: &mut AppFfiState, vault: Vault) -> Result<(), String> {
    let registry = WalletRegistry::load_with_vault(&state.data_dir, Some(&vault))
        .map_err(|e| e.to_string())?;
    state.registry = registry;
    state.vault = Some(vault);
    Ok(())
}

/// The unlocked vault key as 64 lowercase hex characters, for the app to
/// keep in the platform keystore behind a biometric prompt.
///
/// Requires an initialized *and unlocked* vault: the key exists nowhere else,
/// so there is nothing to export before setup or while locked. The returned
/// string is zeroized on drop; the JSON response carrying it is wiped by
/// `wallet_free_string` like every other response.
pub fn export_key(state: &AppFfiState) -> Result<Zeroizing<String>, String> {
    if !vault_is_initialized(&state.data_dir) {
        return Err("No vault is set up on this device".into());
    }
    let vault = state
        .vault
        .as_ref()
        .ok_or("Vault is locked — unlock with your passphrase before exporting its key")?;
    Ok(key_to_hex(&vault.export_key()))
}

/// Hex-encodes a vault key into zeroized storage. The buffer is sized up
/// front so no un-wiped reallocation copy is left behind.
fn key_to_hex(key: &[u8; 32]) -> Zeroizing<String> {
    let mut hex = Zeroizing::new(String::with_capacity(key.len() * 2));
    for byte in key {
        // Writing into a `String` cannot fail.
        let _ = write!(hex, "{byte:02x}");
    }
    hex
}

/// Parses the 64-hex-character form `export_key` produces (either case) back
/// into zeroized key storage. Wrong length and non-hex input are reported
/// separately so a corrupt keystore entry reads as what it is, not as a
/// mismatched key.
fn key_from_hex(key_hex: &str) -> Result<Zeroizing<[u8; 32]>, String> {
    let bytes = key_hex.as_bytes();
    if bytes.len() != 64 {
        return Err(format!(
            "Vault key must be 64 hex characters (32 bytes), got {}",
            bytes.len()
        ));
    }
    let mut key = Zeroizing::new([0u8; 32]);
    for (slot, pair) in key.iter_mut().zip(bytes.chunks_exact(2)) {
        *slot = (hex_nibble(pair[0])? << 4) | hex_nibble(pair[1])?;
    }
    Ok(key)
}

fn hex_nibble(c: u8) -> Result<u8, String> {
    match c {
        b'0'..=b'9' => Ok(c - b'0'),
        b'a'..=b'f' => Ok(c - b'a' + 10),
        b'A'..=b'F' => Ok(c - b'A' + 10),
        _ => Err("Vault key is not valid hex".into()),
    }
}

/// Check a passphrase without changing any state — the gate in front of every
/// seed reveal (report item N3).
///
/// Deriving the key and dropping it is the *only* honest check: the stored
/// verifier is sealed with that key, so there is nothing cheaper to compare
/// against, and a cheap comparison would be a second, weaker secret.
///
/// Guessing is throttled on top of Argon2id's own cost. Argon2 alone bounds an
/// attacker who has stolen the file, but this path is reachable by anything
/// scripting the running app, where ~1 guess/second would still be far too
/// many: 5 wrong tries lock the gate for 60 seconds.
pub fn verify(state: &mut AppFfiState, passphrase: &str) -> Result<(), String> {
    const MAX_TRIES: u32 = 5;
    const LOCKOUT: std::time::Duration = std::time::Duration::from_secs(60);

    if let Some(until) = state.verify_lockout_until {
        let now = std::time::Instant::now();
        if now < until {
            let secs = (until - now).as_secs() + 1;
            return Err(format!("Too many wrong attempts — try again in {secs}s"));
        }
        state.verify_lockout_until = None;
        state.verify_failures = 0;
    }

    let header = load_vault_header(&state.data_dir).ok_or("No vault is set up on this device")?;
    match Vault::unlock(passphrase, &header) {
        Ok(_vault) => {
            // Dropped here on purpose: this call proves the passphrase, it does
            // not grant a session. `state.vault` is untouched either way.
            state.verify_failures = 0;
            Ok(())
        }
        Err(_) => {
            state.verify_failures += 1;
            if state.verify_failures >= MAX_TRIES {
                state.verify_lockout_until = Some(std::time::Instant::now() + LOCKOUT);
                state.verify_failures = 0;
                return Err("Too many wrong attempts — locked for 60s".into());
            }
            let left = MAX_TRIES - state.verify_failures;
            Err(format!("Wrong app password — {left} attempts left"))
        }
    }
}

/// Prove a stored vault key without changing any state — the biometric
/// counterpart of [`verify`], behind the Touch ID confirmation gates.
///
/// The platform keystore only releases the key after a biometric check, so a
/// key that opens this vault is proof that the person at the machine is the
/// one who enrolled. Nothing is unlocked and nothing is cached: the key is
/// derived-against and dropped exactly as [`verify`] does with a passphrase.
/// No guess throttle — a wrong key can only come from a keystore that no
/// longer matches this vault, and the UI switches the feature off on it.
pub fn verify_key(state: &AppFfiState, key_hex: String) -> Result<(), String> {
    let key_hex = Zeroizing::new(key_hex);
    let header = load_vault_header(&state.data_dir).ok_or("No vault is set up on this device")?;
    let key = key_from_hex(&key_hex)?;
    match Vault::unlock_with_key(&header, &key) {
        // Dropped on purpose: proven, not granted. `state.vault` is untouched.
        Ok(_vault) => Ok(()),
        Err(TemplarError::Vault(VaultError::WrongPassphrase)) => Err(
            "The stored vault key does not match this vault — confirm with your passphrase".into(),
        ),
        Err(e) => Err(e.to_string()),
    }
}

/// Lock the vault: drop the in-memory key and every decrypted secret, and close
/// any open wallet. The next secret operation requires a fresh unlock.
pub fn lock(state: &mut AppFfiState) {
    state.vault = None; // Zeroizes the key on drop.
    state.registry = WalletRegistry::default();
    state.active_wallet_id = None;
    state.bitcoin = None;
    state.liquid = None;
}
