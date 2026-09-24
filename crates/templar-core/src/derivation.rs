//! Key derivation utilities: SLIP-0077 blinding keys, xpub encoding, Liquid descriptor derivation.

use bdk::bitcoin::bip32::{DerivationPath, ExtendedPrivKey, ExtendedPubKey};
use bdk::bitcoin::secp256k1::Secp256k1;
use bdk::bitcoin::Network;
use bdk::keys::bip39::Mnemonic;
use bdk::keys::{DerivableKey, ExtendedKey};
use std::str::FromStr;

use crate::error::{BitcoinError, TemplarError};

/// Everything needed to construct a Liquid CT descriptor.
///
/// Derived from the Bitcoin wallet's mnemonic. Encapsulates the Liquid xpub,
/// fingerprint, and SLIP-0077 blinding key without exposing the raw seed to the GUI.
#[derive(Clone, Debug)]
pub struct LiquidDerivationInfo {
    /// xpub at Liquid path m/84'/1776'/0' (Liquid network ID = 1776).
    pub xpub_liquid: String,
    /// Master fingerprint (same as Bitcoin wallet — same seed).
    pub fingerprint: String,
    /// SLIP-0077 master blinding key (32 bytes, hex-encoded).
    pub blinding_key_hex: String,
    /// Complete CT descriptor ready for LWK:
    /// `ct(slip77(KEY), elwpkh([FP/84'/1776'/0']XPUB/<0;1>/*))`
    pub ct_descriptor: String,
}

/// Exportable public wallet info (xpub, zpub, descriptor).
#[derive(Clone, Debug)]
pub struct WalletPubInfo {
    /// xpub BIP84 — tpub on testnet (Sparrow, Electrum).
    pub xpub: String,
    /// Vpub testnet — version bytes 0x045F1CF6 (BlueWallet, Electrum SegWit).
    /// None for HW wallets and multisig (we don't have the private bytes to re-encode).
    pub zpub: Option<String>,
    /// Receive descriptor with `[fingerprint/path]xpub.../0/*`.
    pub receive_descriptor: String,
    /// Master fingerprint (8-char hex, e.g. "a1b2c3d4").
    pub fingerprint: String,
    /// Derivation path (e.g. "m/84'/1'/0'").
    pub derivation_path: String,
    /// For multisig: all cosigner xpubs in `[fp/path]xpub` format.
    pub cosigner_xpubs: Vec<String>,
}

/// Computes the SLIP-0077 master blinding key from BIP39 seed bytes.
///
/// Spec: `HMAC-SHA512(key = "Symmetric key seed", data = seed_bytes)`
/// → first 32 bytes = master blinding key (hex-encoded).
///
/// Deterministic from seed — same seed always produces the same blinding key.
/// Compatible with Jade, Blockstream Green, Sparrow + Liquid plugin.
pub fn slip77_blinding_key(seed: &[u8]) -> String {
    use bdk::bitcoin::hashes::{hmac, sha512, Hash, HashEngine};
    let label = b"Symmetric key seed";
    let mut engine = hmac::HmacEngine::<sha512::Hash>::new(label);
    engine.input(seed);
    let result = hmac::Hmac::<sha512::Hash>::from_engine(engine);
    let bytes = result.as_byte_array();
    hex::encode(&bytes[..32])
}

/// Converts a base58 xpub to Vpub testnet encoding (version bytes 0x045F1CF6).
pub fn xpub_to_vpub_testnet(xpub_b58: &str) -> Option<String> {
    let mut raw = bs58::decode(xpub_b58).with_check(None).into_vec().ok()?;
    if raw.len() < 4 {
        return None;
    }
    raw[0] = 0x04;
    raw[1] = 0x5F;
    raw[2] = 0x1C;
    raw[3] = 0xF6;
    Some(bs58::encode(raw).with_check().into_string())
}

/// Formats an HWI fingerprint as a hex string.
pub fn hwi_fingerprint_to_hex(fp: impl std::fmt::Display) -> String {
    format!("{}", fp)
}

/// Validates a BIP39 mnemonic (wordlist + checksum) without deriving or
/// returning any key material. Returns `Ok(())` only for a well-formed phrase.
pub fn validate_mnemonic(mnemonic_str: &str) -> Result<(), TemplarError> {
    Mnemonic::parse(mnemonic_str)
        .map(|_| ())
        .map_err(|e| BitcoinError::InvalidMnemonic(e.to_string()).into())
}

/// True for characters in the Base58 alphabet (excludes `0 O I l`).
fn is_base58_char(c: char) -> bool {
    c.is_ascii_alphanumeric() && !matches!(c, '0' | 'O' | 'I' | 'l')
}

/// Returns a copy of `descriptor` with every embedded extended *private* key
/// (`xprv…`/`tprv…`) replaced by its corresponding extended *public* key
/// (`xpub…`/`tpub…`). Key-origin prefixes (`[fp/path]`) and child suffixes
/// (`/0/*`, `/<0;1>/*`) are preserved, so the result is a valid watch-only
/// descriptor.
///
/// This guarantees a *signing* descriptor never leaves the core as a
/// "shareable" descriptor (see N1 in securityReport.md). Any token that does
/// not parse as a real extended private key is left untouched — the function
/// never panics and never invents keys. A descriptor with no private material
/// is returned unchanged.
pub fn public_descriptor(descriptor: &str) -> String {
    let secp = Secp256k1::new();
    let chars: Vec<char> = descriptor.chars().collect();
    let mut out = String::with_capacity(descriptor.len());
    let mut i = 0;
    while i < chars.len() {
        let is_priv_marker = i + 4 <= chars.len() && {
            let p: String = chars[i..i + 4].iter().collect();
            p == "xprv" || p == "tprv"
        };
        if is_priv_marker {
            // Consume the maximal Base58 run starting at the marker.
            let start = i;
            let mut j = i;
            while j < chars.len() && is_base58_char(chars[j]) {
                j += 1;
            }
            let token: String = chars[start..j].iter().collect();
            match ExtendedPrivKey::from_str(&token) {
                Ok(xprv) => out.push_str(&ExtendedPubKey::from_priv(&secp, &xprv).to_string()),
                Err(_) => out.push_str(&token), // not a real key — leave as-is
            }
            i = j;
        } else {
            out.push(chars[i]);
            i += 1;
        }
    }
    out
}

/// Generates a fresh BIP39 mnemonic phrase from cryptographically secure random entropy.
///
/// `word_count` must be 12 (128-bit entropy) or 24 (256-bit entropy).
pub fn generate_mnemonic_phrase(word_count: usize) -> Result<String, TemplarError> {
    let entropy_len = match word_count {
        12 => 16,
        24 => 32,
        _ => {
            return Err(BitcoinError::InvalidMnemonic(format!(
                "word count must be 12 or 24, got {}",
                word_count
            ))
            .into())
        }
    };
    let mut entropy = vec![0u8; entropy_len];
    getrandom::getrandom(&mut entropy)
        .map_err(|e| BitcoinError::InvalidMnemonic(format!("entropy generation: {e}")))?;
    let mnemonic = Mnemonic::from_entropy(&entropy)
        .map_err(|e| BitcoinError::InvalidMnemonic(e.to_string()))?;
    Ok(mnemonic.to_string())
}

/// Derives the BIP48 native-SegWit cosigner xpub for multisig setup.
///
/// Standalone function — does not require a `WalletManager`.
/// Path is m/48'/1'/0'/2' (testnet, P2WSH). Returns the keyorigin format
/// `[fingerprint/48'/1'/0'/2']tpub...` expected by `MultisigSetupInfo`,
/// compatible with Sparrow/Coldcard cosigner exports.
pub fn keyorigin_xpub_bip48(mnemonic_str: &str) -> Result<String, TemplarError> {
    let network = Network::Testnet;
    let secp = Secp256k1::new();

    let mnemonic =
        Mnemonic::parse(mnemonic_str).map_err(|e| BitcoinError::InvalidMnemonic(e.to_string()))?;
    let xkey: ExtendedKey = mnemonic
        .into_extended_key()
        .map_err(|e| BitcoinError::InvalidMnemonic(format!("ExtendedKey failed: {e}")))?;
    let xprv_root = xkey
        .into_xprv(network)
        .ok_or_else(|| BitcoinError::InvalidMnemonic("Failed to derive xprv root".into()))?;

    let master_fp = format!("{}", xprv_root.fingerprint(&secp));

    let path = DerivationPath::from_str("m/48'/1'/0'/2'")
        .map_err(|e| BitcoinError::InvalidDescriptor(format!("DerivationPath: {e}")))?;
    let xprv_ms = xprv_root
        .derive_priv(&secp, &path)
        .map_err(|e| BitcoinError::InvalidDescriptor(format!("BIP48 derivation failed: {e}")))?;
    let xpub_ms = ExtendedPubKey::from_priv(&secp, &xprv_ms);

    Ok(format!("[{}/48'/1'/0'/2']{}", master_fp, xpub_ms))
}

/// Derives the BIP84 account key of a software wallet: `(fingerprint, xpub)`
/// at m/84'/1'/0' (testnet native SegWit).
///
/// Standalone and cheap — used to show a wallet's public identity in the
/// picker without opening (and locking) its BDK database.
pub fn account_xpub_bip84(mnemonic_str: &str) -> Result<(String, String), TemplarError> {
    let network = Network::Testnet;
    let secp = Secp256k1::new();

    let mnemonic =
        Mnemonic::parse(mnemonic_str).map_err(|e| BitcoinError::InvalidMnemonic(e.to_string()))?;
    let xkey: ExtendedKey = mnemonic
        .into_extended_key()
        .map_err(|e| BitcoinError::InvalidMnemonic(format!("ExtendedKey failed: {e}")))?;
    let xprv_root = xkey
        .into_xprv(network)
        .ok_or_else(|| BitcoinError::InvalidMnemonic("Failed to derive xprv root".into()))?;

    let master_fp = format!("{}", xprv_root.fingerprint(&secp));

    let path = DerivationPath::from_str("m/84'/1'/0'")
        .map_err(|e| BitcoinError::InvalidDescriptor(format!("DerivationPath: {e}")))?;
    let xprv_acct = xprv_root
        .derive_priv(&secp, &path)
        .map_err(|e| BitcoinError::InvalidDescriptor(format!("BIP84 derivation failed: {e}")))?;
    let xpub_acct = ExtendedPubKey::from_priv(&secp, &xprv_acct);

    Ok((master_fp, xpub_acct.to_string()))
}

/// Returns the wallet's master extended private key (xprv/tprv) as a string.
///
/// This is the *raw private key* of an HD wallet — whoever holds it can spend
/// every coin derived from it. Standalone function; does not require a
/// `WalletManager`. Testnet => the string is `tprv…`.
pub fn master_xprv(mnemonic_str: &str) -> Result<String, TemplarError> {
    let network = Network::Testnet;
    let mnemonic =
        Mnemonic::parse(mnemonic_str).map_err(|e| BitcoinError::InvalidMnemonic(e.to_string()))?;
    let xkey: ExtendedKey = mnemonic
        .into_extended_key()
        .map_err(|e| BitcoinError::InvalidMnemonic(format!("ExtendedKey failed: {e}")))?;
    let xprv_root = xkey
        .into_xprv(network)
        .ok_or_else(|| BitcoinError::InvalidMnemonic("Failed to derive xprv root".into()))?;
    Ok(xprv_root.to_string())
}

/// Derives the Liquid CT descriptor from a BIP39 mnemonic.
///
/// Standalone function — does not require a `WalletManager`.
/// Steps:
/// 1. Derives xprv root from mnemonic
/// 2. Derives xpub at m/84'/1776'/0' (Liquid path)
/// 3. Computes SLIP-0077 blinding key from seed
/// 4. Assembles CT descriptor: `ct(slip77(KEY), elwpkh([FP/84'/1776'/0']XPUB/<0;1>/*))`
pub fn derive_liquid_descriptor(mnemonic_str: &str) -> Result<LiquidDerivationInfo, TemplarError> {
    let network = Network::Testnet;
    let secp = Secp256k1::new();

    let mnemonic =
        Mnemonic::parse(mnemonic_str).map_err(|e| BitcoinError::InvalidMnemonic(e.to_string()))?;
    let xkey: ExtendedKey = mnemonic
        .clone()
        .into_extended_key()
        .map_err(|e| BitcoinError::InvalidMnemonic(format!("ExtendedKey failed: {e}")))?;
    let xprv_root = xkey
        .into_xprv(network)
        .ok_or_else(|| BitcoinError::InvalidMnemonic("Failed to derive xprv root".into()))?;

    let master_fp = format!("{}", xprv_root.fingerprint(&secp));

    let liquid_path = DerivationPath::from_str("m/84'/1776'/0'")
        .map_err(|e| BitcoinError::InvalidDescriptor(format!("DerivationPath: {e}")))?;
    let xprv_liquid = xprv_root
        .derive_priv(&secp, &liquid_path)
        .map_err(|e| BitcoinError::InvalidDescriptor(format!("Liquid derivation failed: {e}")))?;
    let xpub_liquid = ExtendedPubKey::from_priv(&secp, &xprv_liquid);

    let seed_bytes = mnemonic.to_seed("");
    let blinding_hex = slip77_blinding_key(&seed_bytes);

    let ct_descriptor = format!(
        "ct(slip77({blinding}),elwpkh([{fp}/84'/1776'/0']{xpub}/<0;1>/*))",
        blinding = blinding_hex,
        fp = master_fp,
        xpub = xpub_liquid,
    );

    Ok(LiquidDerivationInfo {
        xpub_liquid: xpub_liquid.to_string(),
        fingerprint: master_fp,
        blinding_key_hex: blinding_hex,
        ct_descriptor,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEST_MNEMONIC: &str =
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

    #[test]
    fn validate_mnemonic_accepts_valid_and_rejects_garbage() {
        assert!(validate_mnemonic(TEST_MNEMONIC).is_ok());
        assert!(validate_mnemonic("not a real mnemonic phrase at all here now").is_err());
        // Valid words but wrong checksum must be rejected.
        assert!(validate_mnemonic(
            "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon"
        )
        .is_err());
    }

    #[test]
    fn public_descriptor_strips_embedded_xprv() {
        // Derive the wallet's master tprv and embed it in a wsh(multi(...)) the
        // way a signing multisig descriptor does.
        let tprv = master_xprv(TEST_MNEMONIC).unwrap();
        assert!(tprv.starts_with("tprv"));
        let signing = format!("wsh(multi(2,[00000000/48'/1'/0'/2']{tprv}/0/*,tpubOTHER/0/*))");

        let public = public_descriptor(&signing);

        // No private material may survive.
        assert!(!public.contains("tprv"), "tprv leaked: {public}");
        assert!(!public.contains("xprv"));
        // The origin prefix and child suffix are preserved.
        assert!(public.contains("[00000000/48'/1'/0'/2']"));
        assert!(public.contains("/0/*"));
        // The other (already-public) key is untouched.
        assert!(public.contains("tpubOTHER"));
    }

    #[test]
    fn public_descriptor_leaves_public_descriptor_unchanged() {
        let desc = "wpkh([aabbccdd/84'/1'/0']tpubDEADBEEF/0/*)#abc123";
        assert_eq!(public_descriptor(desc), desc);
    }

    #[test]
    fn slip77_blinding_key_deterministic() {
        let mnemonic = Mnemonic::parse(TEST_MNEMONIC).unwrap();
        let seed = mnemonic.to_seed("");
        let key1 = slip77_blinding_key(&seed);
        let key2 = slip77_blinding_key(&seed);
        assert_eq!(key1, key2);
        assert_eq!(key1.len(), 64); // 32 bytes = 64 hex chars
    }

    #[test]
    fn slip77_different_seeds_different_keys() {
        let m1 = Mnemonic::parse(TEST_MNEMONIC).unwrap();
        let m2 = Mnemonic::parse("zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong").unwrap();
        let k1 = slip77_blinding_key(&m1.to_seed(""));
        let k2 = slip77_blinding_key(&m2.to_seed(""));
        assert_ne!(k1, k2);
    }

    #[test]
    fn xpub_to_vpub_roundtrip() {
        // Derive a real tpub first
        let mnemonic = Mnemonic::parse(TEST_MNEMONIC).unwrap();
        let xkey: ExtendedKey = mnemonic.into_extended_key().unwrap();
        let xprv = xkey.into_xprv(Network::Testnet).unwrap();
        let secp = Secp256k1::new();
        let path = DerivationPath::from_str("m/84'/1'/0'").unwrap();
        let derived = xprv.derive_priv(&secp, &path).unwrap();
        let xpub = ExtendedPubKey::from_priv(&secp, &derived);
        let tpub_str = xpub.to_string();

        let vpub = xpub_to_vpub_testnet(&tpub_str);
        assert!(vpub.is_some());
        let vpub = vpub.unwrap();
        // Vpub starts with specific version bytes
        assert!(vpub.starts_with("Vpub") || vpub.starts_with("vpub"));
    }

    #[test]
    fn xpub_to_vpub_invalid_input() {
        assert!(xpub_to_vpub_testnet("not-a-valid-xpub").is_none());
        assert!(xpub_to_vpub_testnet("").is_none());
    }

    #[test]
    fn derive_liquid_descriptor_structure() {
        let info = derive_liquid_descriptor(TEST_MNEMONIC).unwrap();

        // CT descriptor must have the right structure
        assert!(info.ct_descriptor.starts_with("ct(slip77("));
        assert!(info.ct_descriptor.contains("elwpkh("));
        assert!(info.ct_descriptor.contains("/<0;1>/*"));
        assert!(info.ct_descriptor.contains("/84'/1776'/0'"));

        // Blinding key is 64 hex chars
        assert_eq!(info.blinding_key_hex.len(), 64);

        // Fingerprint is 8 hex chars
        assert_eq!(info.fingerprint.len(), 8);

        // xpub is a valid tpub
        assert!(info.xpub_liquid.starts_with("tpub"));
    }

    #[test]
    fn derive_liquid_descriptor_deterministic() {
        let info1 = derive_liquid_descriptor(TEST_MNEMONIC).unwrap();
        let info2 = derive_liquid_descriptor(TEST_MNEMONIC).unwrap();
        assert_eq!(info1.ct_descriptor, info2.ct_descriptor);
        assert_eq!(info1.blinding_key_hex, info2.blinding_key_hex);
        assert_eq!(info1.fingerprint, info2.fingerprint);
    }

    #[test]
    fn derive_liquid_descriptor_invalid_mnemonic() {
        assert!(derive_liquid_descriptor("not a valid mnemonic").is_err());
    }
}
