//! At-rest secret encryption (security report C1).
//!
//! The wallet registry (`registry.json`) holds BIP39 mnemonics and, for
//! multisig/policy wallets, signing descriptors that embed an xprv. In plain
//! text these are readable by any other local process, backup, or a stolen
//! disk. This module encrypts them at rest.
//!
//! Design:
//!   - The user's **passphrase** is stretched with **Argon2id** (memory-hard)
//!     over a random per-vault salt into a 32-byte key.
//!   - Secrets are sealed with **XChaCha20-Poly1305** (AEAD): confidentiality +
//!     tamper detection. Each seal uses a fresh random 24-byte nonce.
//!   - The derived key lives only in memory, wrapped in `Zeroizing` so it is
//!     wiped on drop. It is never written to disk.
//!   - A small known-plaintext **verifier** is sealed in the on-disk header so
//!     a wrong passphrase is rejected up front (instead of surfacing as a
//!     corrupt-registry error later).
//!
//! The salt and verifier are NOT secret and are persisted in `vault.json`
//! (see `VaultHeader`). Only the passphrase-derived key can open the secrets.
//!
//! An unlocked vault can hand out a copy of that key ([`Vault::export_key`])
//! for a caller that keeps it in a platform keystore — a mobile biometric
//! unlock — and open again from it later ([`Vault::unlock_with_key`]) without
//! the passphrase or the Argon2id stretch. The key is still checked against
//! the verifier, so a stale copy is rejected the way a wrong passphrase is.

use argon2::Argon2;
use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{Key, XChaCha20Poly1305, XNonce};
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

use crate::error::{TemplarError, VaultError};

/// On-disk format version for sealed data.
const SEAL_VERSION: u8 = 1;

/// On-disk vault-header version. v1 did not record the KDF parameters; v2 does
/// (see [`KdfParams`]).
const HEADER_VERSION: u8 = 2;

/// Argon2id salt length in bytes.
const SALT_LEN: usize = 16;

/// XChaCha20-Poly1305 nonce length in bytes.
const NONCE_LEN: usize = 24;

/// Known plaintext sealed into the header to verify the passphrase on unlock.
const VERIFIER_PLAINTEXT: &str = "templar-vault-verifier-v1";

/// Shortest passphrase a new vault accepts, in characters.
///
/// `setup_vault` is reachable without the wizard that enforces this in the
/// UI, and a one-character passphrase turns the 256 MiB Argon2id vault into
/// something a local attacker grinds in a hundred guesses. Enforced at
/// creation only: an existing vault opens with whatever it was created with.
pub const MIN_PASSPHRASE_CHARS: usize = 8;

/// Argon2id cost parameters, recorded in the vault header (security report A5).
///
/// Two reasons they are not left to `Argon2::default()`:
///
///   * The library default (m = 19 MiB, t = 2) is the OWASP *minimum*, tuned
///     for web-login latency. A vault file is ground offline by whoever steals
///     the disk, with no latency budget at all — memory hardness is the only
///     thing making that grind expensive.
///   * If the parameters are not on disk, raising them later silently breaks
///     every existing vault: the derived key changes and the unlock surfaces as
///     "wrong passphrase", with no way back.
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct KdfParams {
    /// Memory cost, in KiB.
    pub m: u32,
    /// Time cost (iterations).
    pub t: u32,
    /// Parallelism (lanes).
    pub p: u32,
}

impl KdfParams {
    /// What new vaults are created with: 256 MiB, 4 passes, 1 lane. Measured at
    /// ~0.5 s in a release build on an M-series laptop (see
    /// `measure_current_kdf_cost`), which is the latency budget for a screen
    /// shown once at startup — and 256 MiB of memory per guess is what makes a
    /// stolen `vault.json` expensive to grind in parallel.
    pub const CURRENT: Self = Self {
        m: 262_144,
        t: 4,
        p: 1,
    };

    /// `Argon2::default()` — the only thing a v1 header (no recorded
    /// parameters) can have been written with.
    pub const LEGACY: Self = Self {
        m: 19_456,
        t: 2,
        p: 1,
    };

    /// Deliberately cheap parameters for tests and fixtures. Never for a real
    /// vault: 8 MiB / 1 pass is a few milliseconds per guess.
    pub const FAST_FOR_TESTS: Self = Self {
        m: 8_192,
        t: 1,
        p: 1,
    };

    /// serde fallback for headers written before the parameters were recorded.
    fn legacy() -> Self {
        Self::LEGACY
    }
}

impl Default for KdfParams {
    fn default() -> Self {
        Self::CURRENT
    }
}

// New vaults must never be created with the library default: the memory
// hardness is what makes a stolen `vault.json` expensive to grind. Checked at
// compile time, so a careless edit to `CURRENT` fails the build rather than a
// test someone might skip.
const _: () = assert!(KdfParams::CURRENT.m >= 65_536, "at least 64 MiB");
const _: () = assert!(KdfParams::CURRENT.t >= 3);
const _: () = assert!(KdfParams::CURRENT.p >= 1);

/// A single secret encrypted at rest. Safe to embed in JSON on disk.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct SealedSecret {
    /// Format version.
    pub v: u8,
    /// XChaCha20-Poly1305 nonce (24 bytes), hex.
    pub nonce: String,
    /// Ciphertext including the 16-byte Poly1305 tag, hex.
    pub ct: String,
}

/// Persisted, non-secret vault parameters. Lives in `<data_dir>/vault.json`.
///
/// Holds only public material: the KDF salt and a sealed verifier. Reading it
/// reveals nothing about the secrets without the passphrase.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct VaultHeader {
    /// Format version.
    pub v: u8,
    /// Argon2id salt (16 bytes), hex.
    pub salt: String,
    /// Sealed known-plaintext used to check the passphrase on unlock.
    pub verifier: SealedSecret,
    /// Cost parameters this vault's key was derived with. Missing in v1
    /// headers, which were all written with [`KdfParams::LEGACY`].
    #[serde(default = "KdfParams::legacy")]
    pub kdf: KdfParams,
}

/// An unlocked vault key held in memory. Zeroized on drop.
///
/// Construct with [`Vault::create`] (first setup), [`Vault::unlock`]
/// (subsequent opens) or [`Vault::unlock_with_key`] (from a key a previous
/// session exported with [`Vault::export_key`]). Use [`Vault::seal`] /
/// [`Vault::open`] to encrypt and decrypt individual secrets.
pub struct Vault {
    key: Zeroizing<[u8; 32]>,
}

impl Vault {
    /// Derives the 32-byte vault key from a passphrase and salt via Argon2id,
    /// with explicit cost parameters (never the library default — see
    /// [`KdfParams`]).
    fn derive_key(
        passphrase: &str,
        salt: &[u8],
        kdf: KdfParams,
    ) -> Result<Zeroizing<[u8; 32]>, TemplarError> {
        let params = argon2::Params::new(kdf.m, kdf.t, kdf.p, Some(32))
            .map_err(|e| VaultError::KeyDerivation(format!("bad KDF parameters: {e}")))?;
        let argon = Argon2::new(argon2::Algorithm::Argon2id, argon2::Version::V0x13, params);
        let mut key = Zeroizing::new([0u8; 32]);
        argon
            .hash_password_into(passphrase.as_bytes(), salt, key.as_mut())
            .map_err(|e| VaultError::KeyDerivation(e.to_string()))?;
        Ok(key)
    }

    /// Creates a brand-new vault from a passphrase.
    ///
    /// Generates a random salt, derives the key, and produces the `VaultHeader`
    /// (salt + sealed verifier) the caller must persist. Returns the live
    /// `Vault` so the caller can immediately seal existing secrets.
    pub fn create(passphrase: &str) -> Result<(Vault, VaultHeader), TemplarError> {
        Self::create_with_params(passphrase, KdfParams::CURRENT)
    }

    /// [`Vault::create`] with explicit cost parameters. Production always takes
    /// [`KdfParams::CURRENT`]; this exists for tests and for raising the cost
    /// later without breaking vaults created today.
    pub fn create_with_params(
        passphrase: &str,
        kdf: KdfParams,
    ) -> Result<(Vault, VaultHeader), TemplarError> {
        if passphrase.chars().count() < MIN_PASSPHRASE_CHARS {
            return Err(VaultError::KeyDerivation(format!(
                "passphrase must be at least {MIN_PASSPHRASE_CHARS} characters"
            ))
            .into());
        }
        let mut salt = [0u8; SALT_LEN];
        getrandom::getrandom(&mut salt)
            .map_err(|e| VaultError::KeyDerivation(format!("salt: {e}")))?;
        let key = Self::derive_key(passphrase, &salt, kdf)?;
        let vault = Vault { key };
        let verifier = vault.seal(VERIFIER_PLAINTEXT)?;
        let header = VaultHeader {
            v: HEADER_VERSION,
            salt: hex::encode(salt),
            verifier,
            kdf,
        };
        Ok((vault, header))
    }

    /// Unlocks an existing vault, verifying the passphrase against the header.
    ///
    /// Returns [`VaultError::WrongPassphrase`] if the passphrase does not
    /// decrypt the verifier — callers should surface this and let the user
    /// retry, ideally rate-limited.
    pub fn unlock(passphrase: &str, header: &VaultHeader) -> Result<Vault, TemplarError> {
        let salt =
            hex::decode(&header.salt).map_err(|e| VaultError::Corrupt(format!("salt hex: {e}")))?;
        // The parameters the vault was *created* with, not today's defaults:
        // deriving with anything else yields a different key, which would
        // surface to the user as a wrong passphrase they cannot fix.
        let key = Self::derive_key(passphrase, &salt, header.kdf)?;
        Self::check_verifier(Vault { key }, header)
    }

    /// Unlocks an existing vault from a key a previous session exported with
    /// [`Vault::export_key`], skipping Argon2id entirely (the mobile
    /// biometric-unlock path: the platform keystore holds the key).
    ///
    /// The key is checked against the header's sealed verifier exactly as a
    /// passphrase-derived key is. A key that does not open it — typically the
    /// vault was re-created after the key was stored — yields
    /// [`VaultError::WrongPassphrase`], the same failure class as a wrong
    /// passphrase, so callers can fall back to asking for one; the FFI layer
    /// words it as "the stored key does not match this vault".
    pub fn unlock_with_key(header: &VaultHeader, key: &[u8; 32]) -> Result<Vault, TemplarError> {
        // Copy straight into zeroized storage: no plain `[u8; 32]` temporary
        // is left behind on the stack.
        let mut own = Zeroizing::new([0u8; 32]);
        own.copy_from_slice(key);
        Self::check_verifier(Vault { key: own }, header)
    }

    /// Proves `vault`'s key opens `header` before handing the vault out — the
    /// one gate both unlock paths go through, so they cannot drift.
    fn check_verifier(vault: Vault, header: &VaultHeader) -> Result<Vault, TemplarError> {
        // A wrong key makes the AEAD tag check fail → treat as wrong passphrase.
        match vault.open(&header.verifier) {
            Ok(pt) if pt.as_str() == VERIFIER_PLAINTEXT => Ok(vault),
            Ok(_) => Err(VaultError::Corrupt("verifier mismatch".into()).into()),
            Err(_) => Err(VaultError::WrongPassphrase.into()),
        }
    }

    /// A copy of the unlocked key, for a caller that stores it in a platform
    /// keystore so later opens can go through [`Vault::unlock_with_key`]
    /// instead of the passphrase.
    ///
    /// Only an unlocked `Vault` can hand this out: there is no way to hold
    /// one without the passphrase or a key that already opens the verifier,
    /// so a locked or absent vault has nothing to export by construction.
    /// The copy is zeroized on drop like the original; keeping it anywhere
    /// less protected than the vault itself is the caller's decision.
    pub fn export_key(&self) -> Zeroizing<[u8; 32]> {
        let mut out = Zeroizing::new([0u8; 32]);
        out.copy_from_slice(self.key.as_ref());
        out
    }

    /// Encrypts a UTF-8 secret with a fresh random nonce.
    pub fn seal(&self, plaintext: &str) -> Result<SealedSecret, TemplarError> {
        let cipher = XChaCha20Poly1305::new(Key::from_slice(self.key.as_ref()));
        let mut nonce = [0u8; NONCE_LEN];
        getrandom::getrandom(&mut nonce)
            .map_err(|e| VaultError::EncryptionFailed(format!("nonce: {e}")))?;
        let ct = cipher
            .encrypt(XNonce::from_slice(&nonce), plaintext.as_bytes())
            .map_err(|e| VaultError::EncryptionFailed(e.to_string()))?;
        Ok(SealedSecret {
            v: SEAL_VERSION,
            nonce: hex::encode(nonce),
            ct: hex::encode(ct),
        })
    }

    /// Decrypts a sealed secret. The returned string is zeroized on drop.
    ///
    /// Returns [`VaultError::DecryptionFailed`] if the ciphertext was tampered
    /// with or the key is wrong (the Poly1305 tag will not verify).
    pub fn open(&self, sealed: &SealedSecret) -> Result<Zeroizing<String>, TemplarError> {
        let cipher = XChaCha20Poly1305::new(Key::from_slice(self.key.as_ref()));
        let nonce = hex::decode(&sealed.nonce)
            .map_err(|e| VaultError::Corrupt(format!("nonce hex: {e}")))?;
        if nonce.len() != NONCE_LEN {
            return Err(VaultError::Corrupt("bad nonce length".into()).into());
        }
        let ct = hex::decode(&sealed.ct)
            .map_err(|e| VaultError::Corrupt(format!("ciphertext hex: {e}")))?;
        let pt = cipher
            .decrypt(XNonce::from_slice(&nonce), ct.as_ref())
            .map_err(|e| VaultError::DecryptionFailed(e.to_string()))?;
        let s = String::from_utf8(pt).map_err(|e| VaultError::Corrupt(format!("utf8: {e}")))?;
        Ok(Zeroizing::new(s))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn seal_open_round_trip() {
        let (vault, _header) =
            Vault::create_with_params("correct horse battery staple", KdfParams::FAST_FOR_TESTS)
                .unwrap();
        let secret = "abandon abandon abandon about";
        let sealed = vault.seal(secret).unwrap();
        // Ciphertext must not contain the plaintext.
        assert!(!sealed.ct.contains(&hex::encode(secret)));
        let opened = vault.open(&sealed).unwrap();
        assert_eq!(opened.as_str(), secret);
    }

    #[test]
    fn unlock_with_correct_passphrase() {
        let (_v, header) =
            Vault::create_with_params("s3kret pass", KdfParams::FAST_FOR_TESTS).unwrap();
        assert!(Vault::unlock("s3kret pass", &header).is_ok());
    }

    #[test]
    fn unlock_with_wrong_passphrase_rejected() {
        let (_v, header) =
            Vault::create_with_params("s3kret pass", KdfParams::FAST_FOR_TESTS).unwrap();
        // `Vault` intentionally has no `Debug` (it holds the key), so avoid
        // `unwrap_err` and match on the result directly.
        let result = Vault::unlock("wrong pass", &header);
        assert!(matches!(
            result,
            Err(TemplarError::Vault(VaultError::WrongPassphrase))
        ));
    }

    #[test]
    fn secret_sealed_under_one_key_opaque_to_another() {
        let (v1, _h1) =
            Vault::create_with_params("passphrase one", KdfParams::FAST_FOR_TESTS).unwrap();
        let (v2, _h2) =
            Vault::create_with_params("passphrase two", KdfParams::FAST_FOR_TESTS).unwrap();
        let sealed = v1.seal("top secret").unwrap();
        // A different vault key must fail the AEAD tag check, not return garbage.
        assert!(v2.open(&sealed).is_err());
    }

    #[test]
    fn distinct_nonces_across_seals() {
        let (vault, _h) =
            Vault::create_with_params("pw-for-tests", KdfParams::FAST_FOR_TESTS).unwrap();
        let a = vault.seal("same plaintext").unwrap();
        let b = vault.seal("same plaintext").unwrap();
        // Random nonce per seal → different nonce and different ciphertext.
        assert_ne!(a.nonce, b.nonce);
        assert_ne!(a.ct, b.ct);
    }

    #[test]
    fn tampered_ciphertext_rejected() {
        let (vault, _h) =
            Vault::create_with_params("pw-for-tests", KdfParams::FAST_FOR_TESTS).unwrap();
        let mut sealed = vault.seal("secret").unwrap();
        // Flip the last ciphertext byte.
        let mut bytes = hex::decode(&sealed.ct).unwrap();
        let last = bytes.len() - 1;
        bytes[last] ^= 0xff;
        sealed.ct = hex::encode(bytes);
        assert!(vault.open(&sealed).is_err());
    }

    /// The length rule the wizard enforces has to hold in the engine too:
    /// `setup_vault` is callable without the wizard.
    #[test]
    fn short_passphrases_rejected() {
        assert!(Vault::create("").is_err());
        assert!(Vault::create_with_params("1234567", KdfParams::FAST_FOR_TESTS).is_err());
        // Characters, not bytes: eight multi-byte characters are eight.
        assert!(Vault::create_with_params("ééééééé", KdfParams::FAST_FOR_TESTS).is_err());
        assert!(Vault::create_with_params("12345678", KdfParams::FAST_FOR_TESTS).is_ok());
        assert!(Vault::create_with_params("éééééééé", KdfParams::FAST_FOR_TESTS).is_ok());
        // Only creation is policed — an old vault must keep opening whatever
        // it was created with.
        let (_v, mut header) =
            Vault::create_with_params("12345678", KdfParams::FAST_FOR_TESTS).unwrap();
        let (_v2, short) = {
            // Build a header for a short passphrase the way a pre-rule build
            // would have: derive directly, bypassing the length gate.
            let salt = hex::decode(&header.salt).unwrap();
            let key = Vault::derive_key("pw", &salt, KdfParams::FAST_FOR_TESTS).unwrap();
            let vault = Vault { key };
            let verifier = vault.seal(VERIFIER_PLAINTEXT).unwrap();
            header.verifier = verifier;
            (vault, header.clone())
        };
        assert!(Vault::unlock("pw", &short).is_ok());
    }

    /// Biometric unlock: the key an unlocked vault exports opens the same
    /// vault again without the passphrase, and reads what it sealed. There is
    /// no `export_key` on a locked or absent vault to test — a `Vault` only
    /// exists once the verifier has been opened.
    #[test]
    fn exported_key_unlocks_without_the_passphrase_and_opens_secrets() {
        let (vault, header) =
            Vault::create_with_params("s3kret pass", KdfParams::FAST_FOR_TESTS).unwrap();
        let sealed = vault.seal("abandon abandon abandon about").unwrap();
        let key = vault.export_key();
        drop(vault);

        let reopened = Vault::unlock_with_key(&header, &key).unwrap();
        assert_eq!(
            reopened.open(&sealed).unwrap().as_str(),
            "abandon abandon abandon about"
        );
        // And what the reopened vault seals is readable by a passphrase
        // unlock: it is the same key, not a parallel one.
        let again = reopened.seal("later secret").unwrap();
        let by_passphrase = Vault::unlock("s3kret pass", &header).unwrap();
        assert_eq!(by_passphrase.open(&again).unwrap().as_str(), "later secret");
        // The key is the passphrase-derived one, whichever way it was reached.
        assert_eq!(*by_passphrase.export_key(), *reopened.export_key());
    }

    #[test]
    fn unlock_with_a_random_key_rejected() {
        let (_v, header) =
            Vault::create_with_params("s3kret pass", KdfParams::FAST_FOR_TESTS).unwrap();
        let mut random = Zeroizing::new([0u8; 32]);
        getrandom::getrandom(random.as_mut()).unwrap();
        let result = Vault::unlock_with_key(&header, &random);
        // Same failure class as a wrong passphrase, so the caller's fallback
        // (ask for the passphrase) is the same.
        assert!(matches!(
            result,
            Err(TemplarError::Vault(VaultError::WrongPassphrase))
        ));
        // A key from a *different* vault is just as wrong.
        let (other, _h) =
            Vault::create_with_params("s3kret pass", KdfParams::FAST_FOR_TESTS).unwrap();
        assert!(matches!(
            Vault::unlock_with_key(&header, &other.export_key()),
            Err(TemplarError::Vault(VaultError::WrongPassphrase))
        ));
    }

    /// The exported copy is independent of the vault it came from and wiped
    /// on drop — `Zeroizing` is the type, not a plain array.
    #[test]
    fn export_key_is_a_zeroizing_copy() {
        let (vault, _h) =
            Vault::create_with_params("pw-for-tests", KdfParams::FAST_FOR_TESTS).unwrap();
        let a: Zeroizing<[u8; 32]> = vault.export_key();
        let b = vault.export_key();
        assert_eq!(*a, *b);
        assert_ne!(*a, [0u8; 32], "a real key, not the zeroized placeholder");
    }

    /// A5 — the parameters travel with the vault, so a future cost bump does
    /// not lock anybody out of the vault they already have.
    #[test]
    fn header_records_the_parameters_and_unlock_uses_them() {
        let (_v, header) =
            Vault::create_with_params("pw-for-tests", KdfParams::FAST_FOR_TESTS).unwrap();
        assert_eq!(header.kdf, KdfParams::FAST_FOR_TESTS);
        assert_eq!(header.v, HEADER_VERSION);
        // Unlock derives with the header's parameters, not today's default —
        // deriving with CURRENT here would yield a different key.
        assert!(Vault::unlock("pw-for-tests", &header).is_ok());
    }

    /// A v1 header has no `kdf` field; it can only have been written with the
    /// old library default, and must keep opening.
    #[test]
    fn v1_header_without_parameters_reads_as_legacy() {
        let json = r#"{"v":1,"salt":"00112233445566778899aabbccddeeff",
                       "verifier":{"v":1,"nonce":"ab","ct":"cd"}}"#;
        let header: VaultHeader = serde_json::from_str(json).unwrap();
        assert_eq!(header.kdf, KdfParams::LEGACY);
    }

    /// Not a correctness test — prints the real cost of the shipping
    /// parameters so a regression in either direction is visible.
    #[test]
    #[ignore = "timing, run explicitly"]
    fn measure_current_kdf_cost() {
        let t0 = std::time::Instant::now();
        let (_v, header) = Vault::create("measure me").unwrap();
        let create = t0.elapsed();
        let t1 = std::time::Instant::now();
        Vault::unlock("measure me", &header).unwrap();
        eprintln!(
            "Argon2id m={} KiB t={} p={} — create {:?}, unlock {:?}",
            header.kdf.m,
            header.kdf.t,
            header.kdf.p,
            create,
            t1.elapsed()
        );
    }

    /// New vaults must not be created with the library default (the cost
    /// floor itself is a compile-time assertion next to `KdfParams`).
    #[test]
    fn new_vaults_use_the_hardened_parameters() {
        assert_eq!(KdfParams::default(), KdfParams::CURRENT);
        assert_ne!(KdfParams::CURRENT, KdfParams::LEGACY);
    }
}
