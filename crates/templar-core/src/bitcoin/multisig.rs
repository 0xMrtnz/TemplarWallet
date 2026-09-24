//! Multisig setup: collects cosigner xpubs and builds descriptors.

use bdk::bitcoin::Network;
use bdk::database::MemoryDatabase;
use bdk::Wallet;

use crate::error::{BitcoinError, TemplarError};

/// Intermediate data during multisig wallet setup.
///
/// Collects cosigner xpubs progressively and builds
/// `wsh(sortedmulti(...))` descriptors when complete.
#[derive(Clone, Debug, Default)]
pub struct MultisigSetupInfo {
    pub name: String,
    pub required_sigs: usize,
    pub total_signers: usize,
    /// Collected xpubs in `[fp/path]xpub` format — without wildcard suffix.
    pub xpubs: Vec<String>,
    /// Local fingerprint — the key this app will use to sign.
    pub local_fp: Option<String>,
}

impl MultisigSetupInfo {
    pub fn new(name: &str, required: usize, total: usize) -> Self {
        Self {
            name: name.to_string(),
            required_sigs: required,
            total_signers: total,
            xpubs: Vec::new(),
            local_fp: None,
        }
    }

    /// Returns true if all xpubs have been collected and the threshold is valid.
    pub fn is_complete(&self) -> bool {
        self.xpubs.len() == self.total_signers
            && self.required_sigs >= 1
            && self.required_sigs <= self.total_signers
    }

    /// Builds `wsh(sortedmulti(...))` descriptors for BDK.
    ///
    /// Returns `(receive_descriptor, change_descriptor)`.
    /// `sortedmulti` reorders keys per BIP67 — compatible with Sparrow/Coldcard.
    pub fn build_descriptors(&self) -> Result<(String, String), TemplarError> {
        if !self.is_complete() {
            return Err(BitcoinError::InvalidDescriptor(format!(
                "Incomplete setup: {} xpubs out of {} required",
                self.xpubs.len(),
                self.total_signers
            ))
            .into());
        }

        let keys_recv: String = self
            .xpubs
            .iter()
            .map(|xpub| format!("{}/0/*", xpub))
            .collect::<Vec<_>>()
            .join(",");
        let keys_change: String = self
            .xpubs
            .iter()
            .map(|xpub| format!("{}/1/*", xpub))
            .collect::<Vec<_>>()
            .join(",");

        let recv = format!("wsh(sortedmulti({},{}))", self.required_sigs, keys_recv);
        let change = format!("wsh(sortedmulti({},{}))", self.required_sigs, keys_change);
        Ok((recv, change))
    }
}

// ── Cosigner keys ────────────────────────────────────────────────────────────

/// Base58 alphabet — used to cut an extended key out of whatever wrapper it
/// arrived in without pulling in a regex crate.
const BASE58: &str = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

/// Which account a cosigner key belongs to. Bitcoin and Liquid live on
/// different paths and neither key can be computed from the other, so one
/// pasted into the wrong field builds a wallet nobody can sign.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CosignerRole {
    /// Bitcoin, BIP48 P2WSH: `m/48'/1'/0'/2'`.
    Bitcoin,
    /// Liquid, BIP87: `m/87'/1'/0'`.
    Liquid,
}

impl CosignerRole {
    /// The path this build derives for its own keys, and expects from others.
    ///
    /// Written with the same hardened marker the rest of that chain's stack
    /// uses, because these strings are compared literally: BDK and
    /// `keyorigin_xpub_bip48` produce `'`, LWK and Jade produce `h`, and a key
    /// normalized into the other style stops matching the local seed it
    /// belongs to.
    pub fn expected_path(self) -> &'static str {
        match self {
            Self::Bitcoin => "48'/1'/0'/2'",
            Self::Liquid => "87h/1h/0h",
        }
    }

    /// How this chain's tooling writes a hardened step.
    fn hardened_marker(self) -> &'static str {
        match self {
            Self::Bitcoin => "'",
            Self::Liquid => "h",
        }
    }

    fn label(self) -> &'static str {
        match self {
            Self::Bitcoin => "Bitcoin",
            Self::Liquid => "Liquid",
        }
    }
}

/// A cosigner key after normalization, with everything the UI needs to show
/// the user what they actually handed over.
#[derive(Debug, Clone, serde::Serialize)]
pub struct CosignerKeyInfo {
    /// `[fingerprint/path]tpub…` — exactly the form [`MultisigSetupInfo`]
    /// wants: no wrapper, no wildcard, hardened steps as `'`.
    pub normalized: String,
    /// Master fingerprint, lower-case hex.
    pub fingerprint: String,
    /// Origin path without the leading `m/`.
    pub path: String,
    /// Set when the key parses but is probably not the key the user meant.
    /// Not fatal — the wallet builds — but the wizard says so out loud,
    /// because neither end can detect it once funds are in.
    pub warning: Option<String>,
}

/// Turns whatever a co-signer sent into the `[fingerprint/path]tpub…` form the
/// descriptor builder needs, or explains exactly what is wrong with it.
///
/// Accepts, because these are all things real devices and apps export:
/// - the canonical `[fp/48'/1'/0'/2']tpub…`
/// - `h` for hardened steps (Jade, Coldcard) and a `#checksum` suffix
/// - a single-key descriptor wrapper — `wpkh([fp/…]tpub…/<0;1>/*)` is what a
///   scanned `ur:crypto-account` decodes to
/// - SLIP-132 testnet version bytes (vpub/upub), re-encoded as tpub
///
/// Rejects a whole multisig descriptor, a key with no origin (nothing could
/// ever be matched to a signing device), a bad fingerprint, a mainnet path,
/// and anything that is not an extended public key.
pub fn normalize_cosigner_key(
    raw: &str,
    role: CosignerRole,
) -> Result<CosignerKeyInfo, TemplarError> {
    let err = |m: String| -> TemplarError { BitcoinError::InvalidDescriptor(m).into() };

    // Descriptors never legitimately contain whitespace; a pasted key often
    // arrives wrapped across lines.
    let input: String = raw.split_whitespace().collect();
    if input.is_empty() {
        return Err(err("No key".into()));
    }
    let input = input.split('#').next().unwrap_or(&input).to_string();

    if input.contains("multi(") {
        return Err(err(format!(
            "That is a whole multisig descriptor, not one cosigner key. Paste the \
             single key it belongs to, in the form [fingerprint/{}]tpub…",
            role.expected_path()
        )));
    }

    // Everything before `[` is a wrapper (`wpkh(`, `wsh(`, …) and is dropped
    // with it; what follows the `]` is the key plus any derivation suffix.
    let (origin, after) = match (input.find('['), input.find(']')) {
        (Some(a), Some(b)) if b > a + 1 => {
            (input[a + 1..b].to_string(), input[b + 1..].to_string())
        }
        _ => {
            return Err(err(format!(
                "This key has no origin. A cosigner key must carry the fingerprint and \
                 the path it was derived at — [fingerprint/{}]tpub… — or no signing \
                 device can ever be matched to it.",
                role.expected_path()
            )))
        }
    };

    // A wrapper with no origin would leave `wpkh(` glued to the key; every
    // letter of it is a valid base58 character, so cut at the last `(`.
    let tail = after.rsplit('(').next().unwrap_or(&after);
    let key: String = tail.chars().take_while(|c| BASE58.contains(*c)).collect();
    if key.is_empty() {
        return Err(err(
            "No extended public key after the [fingerprint/path] origin".into(),
        ));
    }
    let key = crate::bitcoin::watch_only::convert_to_tpub(&key)?;

    let (fp, path) = match origin.split_once('/') {
        Some((f, p)) => (
            f.to_ascii_lowercase(),
            // Devices disagree on `'` vs `h`; settle on whatever the rest of
            // this chain's stack writes, so the string compares equal to a
            // locally derived key.
            p.replace(['h', 'H', '\''], role.hardened_marker()),
        ),
        None => (origin.to_ascii_lowercase(), String::new()),
    };
    if fp.len() != 8 || !fp.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err(err(format!(
            "\"{fp}\" is not a master fingerprint — that is 8 hexadecimal characters, \
             e.g. [f0b68896/{}]tpub…",
            role.expected_path()
        )));
    }
    if path.is_empty() {
        return Err(err(format!(
            "The origin has a fingerprint but no derivation path. It must read \
             [{fp}/{}].",
            role.expected_path()
        )));
    }

    // Coin type is the only thing that gives a mainnet key away: a scanned
    // `ur:crypto-account` is re-encoded as a tpub whatever it came from, so
    // the version bytes have already stopped telling the truth by this point.
    let steps: Vec<&str> = path.split('/').collect();
    if let Some(coin) = steps.get(1) {
        if !matches!(*coin, "1'" | "1h" | "1") {
            return Err(err(format!(
                "Derivation path m/{path} is a mainnet path (coin type {coin}). This \
                 build is testnet-only — export the key from a testnet wallet."
            )));
        }
    }

    // The key must actually sit at the path the origin claims: a well-formed
    // tpub copied from another export (an account key, or the master) would
    // build a wallet every coordinator agrees on — and that the co-signer's
    // device can never sign for, because it derives a different key at that
    // path. Depth and the last child number are the two things an xpub
    // records about where it came from.
    check_key_matches_origin(&key, &steps, &fp).map_err(err)?;

    let expected = role.expected_path();
    let warning = if path == expected {
        None
    } else {
        Some(match steps.first().copied() {
            Some("84'") | Some("49'") | Some("44'") => format!(
                "m/{path} is a single-sig account key, not the {} multisig key \
                 (m/{expected}). The wallet would build and then be unspendable.",
                role.label()
            ),
            _ => format!(
                "Unusual path m/{path} — a {} cosigner here is normally at m/{expected}. \
                 Make sure the device really derived this one.",
                role.label()
            ),
        })
    };

    Ok(CosignerKeyInfo {
        normalized: format!("[{fp}/{path}]{key}"),
        fingerprint: fp,
        path,
        warning,
    })
}

/// Rejects an extended key whose recorded depth or child number does not
/// match the origin path it is pasted with.
fn check_key_matches_origin(key: &str, steps: &[&str], fp: &str) -> Result<(), String> {
    use bdk::bitcoin::bip32::ExtendedPubKey;
    use std::str::FromStr;

    let xpub = ExtendedPubKey::from_str(key)
        .map_err(|e| format!("Not a valid extended public key: {e}"))?;
    let path = steps.join("/");
    if xpub.depth as usize != steps.len() {
        return Err(format!(
            "This key was derived {} levels deep, but the origin says m/{path} ({} levels). \
             It is a different key than the path claims — export the key at m/{path} \
             again, with its origin.",
            xpub.depth,
            steps.len()
        ));
    }
    let last = steps
        .last()
        .ok_or_else(|| "The origin has no derivation path".to_string())?;
    let expected = parse_child_number(last)
        .ok_or_else(|| format!("\"{last}\" is not a valid derivation step"))?;
    if xpub.child_number != expected {
        return Err(format!(
            "This key's last derivation step is {}, but the origin says {last} \
             (m/{path}). It is a different key than the path claims.",
            xpub.child_number
        ));
    }
    // A depth-1 key's parent is the master itself; any other parent
    // fingerprint means the origin fingerprint is not this key's master.
    if xpub.depth == 1 && xpub.parent_fingerprint.to_string() != fp {
        return Err(format!(
            "This key's parent fingerprint ({}) is not the master fingerprint in its origin ({fp}).",
            xpub.parent_fingerprint
        ));
    }
    Ok(())
}

/// `2'`, `2h`, `2H` or `2` → a BIP-32 child number.
fn parse_child_number(step: &str) -> Option<bdk::bitcoin::bip32::ChildNumber> {
    use bdk::bitcoin::bip32::ChildNumber;
    let (digits, hardened) = match step.strip_suffix(['\'', 'h', 'H']) {
        Some(d) => (d, true),
        None => (step, false),
    };
    let index: u32 = digits.parse().ok()?;
    if hardened {
        ChildNumber::from_hardened_idx(index).ok()
    } else {
        ChildNumber::from_normal_idx(index).ok()
    }
}

/// Parses a finished descriptor pair exactly the way opening the wallet will.
///
/// Wallet creation used to persist whatever string it built and only discover
/// a bad key at the next open — leaving a registry entry that could never be
/// opened again. Call this before anything is written.
pub fn validate_descriptor_pair(recv: &str, change: &str) -> Result<(), TemplarError> {
    Wallet::new(recv, Some(change), Network::Testnet, MemoryDatabase::new())
        .map(|_| ())
        .map_err(|e| {
            BitcoinError::InvalidDescriptor(format!("Multisig descriptor rejected: {e}")).into()
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    // A real testnet BIP48 key: the fixture the rest of the suite uses.
    const TPUB: &str = "tpubDCVwWj4hEpeWNFcWe3Eo1DrkLnPC4c2iitjw5wAuTkSZgofJbRMD4KESh1uhsqLCCjcjR36JooEFwfWf1ezwmAfjcPCxc7KNtnfBCrMPdtT";

    /// A key really derived at m/48'/1'/0'/2' (depth 4, child 2'), so its
    /// origin is true. `TPUB` sits at depth 3 with child 0' — a BIP84/87
    /// account key.
    fn tpub48() -> String {
        use bdk::bitcoin::bip32::{DerivationPath, ExtendedPrivKey, ExtendedPubKey};
        use bdk::bitcoin::secp256k1::Secp256k1;
        use std::str::FromStr;
        let secp = Secp256k1::new();
        let master = ExtendedPrivKey::new_master(Network::Testnet, &[7u8; 32]).unwrap();
        let path = DerivationPath::from_str("m/48'/1'/0'/2'").unwrap();
        ExtendedPubKey::from_priv(&secp, &master.derive_priv(&secp, &path).unwrap()).to_string()
    }

    fn canonical() -> String {
        format!("[f0b68896/48'/1'/0'/2']{}", tpub48())
    }

    #[test]
    fn key_that_is_not_at_its_origin_path_is_rejected() {
        // The depth-3 account key pasted with a 4-level multisig origin: every
        // coordinator would agree on the wallet, and the device would never
        // sign for it.
        let wrong = format!("[f0b68896/48'/1'/0'/2']{TPUB}");
        let e = normalize_cosigner_key(&wrong, CosignerRole::Bitcoin).unwrap_err();
        assert!(e.to_string().contains("levels deep"), "{e}");
        // Right depth, wrong last step (0' where the origin says 1').
        let e = normalize_cosigner_key(
            &format!("[f0b68896/84'/1'/1']{TPUB}"),
            CosignerRole::Bitcoin,
        )
        .unwrap_err();
        assert!(e.to_string().contains("last derivation step"), "{e}");
    }

    #[test]
    fn canonical_cosigner_key_passes_through() {
        let info = normalize_cosigner_key(&canonical(), CosignerRole::Bitcoin).unwrap();
        assert_eq!(info.normalized, canonical());
        assert_eq!(info.fingerprint, "f0b68896");
        assert_eq!(info.path, "48'/1'/0'/2'");
        assert!(info.warning.is_none());
    }

    #[test]
    fn scanned_crypto_account_descriptor_is_reduced_to_the_key() {
        // Exactly what decode_ur_parts hands back for a Jade xpub QR — the
        // string that used to be pasted whole into the wizard and produce an
        // unopenable wallet.
        let scanned = format!("wpkh([f0b68896/48'/1'/0'/2']{}/<0;1>/*)", tpub48());
        let info = normalize_cosigner_key(&scanned, CosignerRole::Bitcoin).unwrap();
        assert_eq!(info.normalized, canonical());
        assert!(info.warning.is_none());
    }

    #[test]
    fn hardened_h_and_checksum_are_accepted() {
        let jade = format!("[F0B68896/48h/1h/0h/2h]{}#abcdefgh", tpub48());
        let info = normalize_cosigner_key(&jade, CosignerRole::Bitcoin).unwrap();
        assert_eq!(info.normalized, canonical());
    }

    #[test]
    fn key_without_origin_is_rejected() {
        let e = normalize_cosigner_key(TPUB, CosignerRole::Bitcoin).unwrap_err();
        assert!(e.to_string().contains("no origin"), "{e}");
    }

    #[test]
    fn whole_wallet_descriptor_is_rejected() {
        let desc = format!("wsh(sortedmulti(2,[f0b68896/48'/1'/0'/2']{TPUB}/0/*,[aabbccdd/48'/1'/0'/2']{TPUB}/0/*))");
        let e = normalize_cosigner_key(&desc, CosignerRole::Bitcoin).unwrap_err();
        assert!(e.to_string().contains("whole multisig descriptor"), "{e}");
    }

    #[test]
    fn mainnet_path_is_rejected_even_though_the_key_says_tpub() {
        // A mainnet device's crypto-account is re-encoded as a tpub by the QR
        // decoder, so only the coin type gives it away.
        let mainnet = format!("[f0b68896/48'/0'/0'/2']{TPUB}");
        let e = normalize_cosigner_key(&mainnet, CosignerRole::Bitcoin).unwrap_err();
        assert!(e.to_string().contains("mainnet path"), "{e}");
    }

    #[test]
    fn bad_fingerprint_is_rejected() {
        let e = normalize_cosigner_key(&format!("[zzz/48'/1'/0'/2']{TPUB}"), CosignerRole::Bitcoin)
            .unwrap_err();
        assert!(e.to_string().contains("master fingerprint"), "{e}");
    }

    #[test]
    fn singlesig_account_key_warns_but_is_allowed() {
        let bip84 = format!("[f0b68896/84'/1'/0']{TPUB}");
        let info = normalize_cosigner_key(&bip84, CosignerRole::Bitcoin).unwrap();
        assert_eq!(info.normalized, bip84);
        assert!(info.warning.unwrap().contains("single-sig account key"));
    }

    #[test]
    fn liquid_role_expects_bip87_in_lwk_notation() {
        // Typed with `'`, stored with `h`: LWK and Jade write it that way and
        // the strings are compared literally against a locally derived key.
        let bip87 = format!("[f0b68896/87'/1'/0']{TPUB}");
        let info = normalize_cosigner_key(&bip87, CosignerRole::Liquid).unwrap();
        assert_eq!(info.normalized, format!("[f0b68896/87h/1h/0h]{TPUB}"));
        assert!(info.warning.is_none());
        // The Bitcoin key in the Liquid field is the mistake this catches.
        let bip48 = normalize_cosigner_key(&canonical(), CosignerRole::Liquid).unwrap();
        assert!(bip48.warning.is_some());
    }

    #[test]
    fn wallet_info_cosigner_keys_paste_into_the_wizard_unchanged() {
        // Wallet info's "Use this wallet as a cosigner" card shows exactly
        // these two strings (get_cosigner_xpub / get_liquid_cosigner_xpub).
        // Pasted into the wizard's two fields they must pass its key check
        // untouched and without a warning: a rewrite would mean the key a
        // co-signer copied is not the key the wallet is built with, and a
        // Liquid key that stops matching its local seed cannot sign.
        const MNEMONIC: &str = "abandon abandon abandon abandon abandon abandon abandon \
                                abandon abandon abandon abandon about";

        let btc = crate::derivation::keyorigin_xpub_bip48(MNEMONIC).unwrap();
        let info = normalize_cosigner_key(&btc, CosignerRole::Bitcoin).unwrap();
        assert_eq!(info.normalized, btc);
        assert_eq!(info.path, "48'/1'/0'/2'");
        assert!(info.warning.is_none(), "{:?}", info.warning);

        let liquid =
            crate::liquid::multisig::LiquidMultisigSetup::derive_xpub_from_mnemonic(MNEMONIC)
                .unwrap();
        let info = normalize_cosigner_key(&liquid, CosignerRole::Liquid).unwrap();
        assert_eq!(info.normalized, liquid);
        assert_eq!(info.path, "87h/1h/0h");
        assert!(info.warning.is_none(), "{:?}", info.warning);

        // Both come from the same seed, and each in the other's field warns.
        assert_eq!(btc[1..9], liquid[1..9]);
        let swapped = normalize_cosigner_key(&btc, CosignerRole::Liquid).unwrap();
        assert!(swapped.warning.is_some());
        let swapped = normalize_cosigner_key(&liquid, CosignerRole::Bitcoin).unwrap();
        assert!(swapped.warning.is_some());
    }

    #[test]
    fn descriptor_pair_validation_catches_a_key_the_builder_would_swallow() {
        let mut setup = MultisigSetupInfo::new("Broken", 2, 2);
        // The pre-fix wizard put a whole descriptor in the key slot.
        setup
            .xpubs
            .push(format!("wpkh([f0b68896/48'/1'/0'/2']{TPUB}/<0;1>/*)"));
        setup.xpubs.push(format!("[aabbccdd/48'/1'/0'/2']{TPUB}"));
        let (recv, change) = setup.build_descriptors().unwrap();
        assert!(validate_descriptor_pair(&recv, &change).is_err());

        setup.xpubs[0] = canonical();
        let (recv, change) = setup.build_descriptors().unwrap();
        validate_descriptor_pair(&recv, &change).expect("clean keys must parse");
    }

    #[test]
    fn multisig_setup_new() {
        let setup = MultisigSetupInfo::new("Treasury", 2, 3);
        assert_eq!(setup.name, "Treasury");
        assert_eq!(setup.required_sigs, 2);
        assert_eq!(setup.total_signers, 3);
        assert!(setup.xpubs.is_empty());
        assert!(!setup.is_complete());
    }

    #[test]
    fn multisig_setup_incomplete() {
        let mut setup = MultisigSetupInfo::new("Test", 2, 3);
        setup.xpubs.push("[fp/84'/1'/0']tpubA".into());
        setup.xpubs.push("[fp/84'/1'/0']tpubB".into());
        assert!(!setup.is_complete()); // need 3, have 2
    }

    #[test]
    fn multisig_setup_complete() {
        let mut setup = MultisigSetupInfo::new("Test", 2, 3);
        setup.xpubs.push("xpubA".into());
        setup.xpubs.push("xpubB".into());
        setup.xpubs.push("xpubC".into());
        assert!(setup.is_complete());
    }

    #[test]
    fn multisig_setup_invalid_threshold() {
        let mut setup = MultisigSetupInfo::new("Test", 0, 3);
        setup.xpubs = vec!["a".into(), "b".into(), "c".into()];
        assert!(!setup.is_complete()); // threshold 0 is invalid

        let mut setup2 = MultisigSetupInfo::new("Test", 4, 3);
        setup2.xpubs = vec!["a".into(), "b".into(), "c".into()];
        assert!(!setup2.is_complete()); // threshold > total
    }

    #[test]
    fn build_descriptors_incomplete_fails() {
        let setup = MultisigSetupInfo::new("Test", 2, 3);
        assert!(setup.build_descriptors().is_err());
    }

    #[test]
    fn build_descriptors_format() {
        let mut setup = MultisigSetupInfo::new("Test", 2, 3);
        setup.xpubs = vec![
            "[fp1/84'/1'/0']tpubA".into(),
            "[fp2/84'/1'/0']tpubB".into(),
            "[fp3/84'/1'/0']tpubC".into(),
        ];
        let (recv, change) = setup.build_descriptors().unwrap();
        assert!(recv.starts_with("wsh(sortedmulti(2,"));
        assert!(recv.contains("/0/*"));
        assert!(change.starts_with("wsh(sortedmulti(2,"));
        assert!(change.contains("/1/*"));
    }

    #[test]
    fn multisig_setup_default() {
        let setup = MultisigSetupInfo::default();
        assert_eq!(setup.required_sigs, 0);
        assert_eq!(setup.total_signers, 0);
        assert!(setup.name.is_empty());
    }
}
