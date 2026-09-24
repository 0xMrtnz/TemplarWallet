//! Watch-only Bitcoin wallet from xpub or descriptor.
//!
//! Creates a BDK wallet without signing capability — can sync, display
//! balance, generate addresses, and inspect transactions, but cannot sign.
//!
//! Used for hardware wallet users who want to monitor their wallet
//! without connecting the device.

use bdk::bitcoin::Network;
use bdk::database::MemoryDatabase;
use bdk::wallet::AddressIndex;
use bdk::Wallet;

use crate::error::{BitcoinError, HardwareError, TemplarError};

/// Derive a Liquid CT descriptor from a Bitcoin `wpkh(...)` receive descriptor.
///
/// Takes `wpkh([fp/path]xpub/0/*)#checksum` and produces
/// `ct(elip151,elwpkh([fp/path]xpub/<0;1>/*))` suitable for LWK.
///
/// ELIP151 derives the blinding key deterministically from the signing key,
/// so no master secret is needed — works for any watch-only or hardware key.
/// Pure string work: available on every platform, including builds without
/// the `hardware` feature (the USB path re-exports it as
/// `WalletManager::hw_liquid_descriptor`).
pub fn liquid_descriptor_from_wpkh(btc_recv_desc: &str) -> Result<String, TemplarError> {
    // Strip checksum (#xxxxxxxx) if present.
    let base = btc_recv_desc
        .split('#')
        .next()
        .unwrap_or(btc_recv_desc)
        .trim();

    // Validate it looks like a wpkh descriptor.
    if !base.starts_with("wpkh(") {
        return Err(HardwareError::ConnectionFailed(format!(
            "Expected wpkh(...) descriptor, got: {base}"
        ))
        .into());
    }

    // Strip outer wpkh( ... )
    let inner = base
        .strip_prefix("wpkh(")
        .and_then(|s| s.strip_suffix(')'))
        .ok_or_else(|| HardwareError::ConnectionFailed("Malformed wpkh descriptor".into()))?;

    // Replace the receive-only path derivation index with the multipath range.
    // hwi gives /0/* for receive; Liquid descriptors need /<0;1>/*.
    let multipath = if inner.contains("/0/*)") {
        inner.replace("/0/*)", "/<0;1>/*)")
    } else if inner.contains("/0/*") {
        inner.replace("/0/*", "/<0;1>/*")
    } else {
        // Already multipath or unusual format — use as-is.
        inner.to_string()
    };

    // LWK only parses ELEMENTS descriptors inside ct(): the inner script
    // must be `elwpkh`, not `wpkh` (WolletDescriptor rejects the latter
    // with "Not an elements descriptor").
    Ok(format!("ct(elip151,elwpkh({multipath}))"))
}

/// Normalizes raw watch-only input into a `(receive, change)` descriptor pair
/// that BDK 0.30 accepts, then validates the pair against a throwaway
/// in-memory wallet so malformed input fails at creation time — not silently
/// at the next open.
///
/// Accepted inputs:
/// - bare extended public key (`tpub…`, SLIP-132 `vpub…`/`upub…` converted),
///   optionally with a `[fingerprint/path]` origin — wrapped as native SegWit
///   `wpkh(key/0/*)` + `wpkh(key/1/*)`
/// - BIP-389 multipath descriptor (`…/<0;1>/*`) — split into receive/change
/// - single-path descriptor (`…/0/*`) — change derived by flipping to `/1/*`
/// - any of the above with a `#checksum` suffix (stripped; it would no longer
///   match the rewritten string, and BDK recomputes it anyway)
///
/// A single-path descriptor already at `/1/*` has nothing to flip, so both
/// elements are the input itself. Callers normalizing an explicitly supplied
/// change descriptor must therefore take the change element: it passes `/1/*`
/// input through, splits multipath to its `/1/*` branch, and wraps a bare key
/// as `wpkh(key/1/*)`.
pub fn normalize_watch_only_descriptors(raw: &str) -> Result<(String, String), TemplarError> {
    // Collapse paste artifacts (newlines, spaces) — descriptors never
    // legitimately contain whitespace.
    let input: String = raw.split_whitespace().collect();
    if input.is_empty() {
        return Err(BitcoinError::InvalidDescriptor("Empty descriptor".into()).into());
    }
    // A watch-only wallet must hold no key. BDK would happily open a tprv
    // descriptor, and the profile would then carry a private key on disk
    // outside the vault under a label that promises the opposite.
    if contains_private_key(input.split('#').next().unwrap_or(&input)) {
        return Err(BitcoinError::InvalidDescriptor(
            "That descriptor contains a private key (tprv/xprv). A watch-only wallet takes \
             the public descriptor — export it from the wallet that holds the key."
                .into(),
        )
        .into());
    }

    let (recv, change) = if !input.contains('(') {
        wrap_bare_key(&input)?
    } else {
        let desc = verify_checksum(&input)?;
        if let Some(pair) = split_multipath(&desc) {
            pair
        } else if desc.contains("/0/*") {
            (desc.clone(), desc.replace("/0/*", "/1/*"))
        } else if desc.contains("/0h/*") {
            (desc.clone(), desc.replace("/0h/*", "/1h/*"))
        } else if desc.contains("/0'/*") {
            (desc.clone(), desc.replace("/0'/*", "/1'/*"))
        } else {
            (desc.clone(), desc)
        }
    };

    // One throwaway parse catches everything BDK would otherwise reject at
    // open time (bad keys, wrong network, unsupported script types, …).
    Wallet::new(
        recv.as_str(),
        Some(change.as_str()),
        Network::Testnet,
        MemoryDatabase::new(),
    )
    .map_err(|e| BitcoinError::InvalidDescriptor(format!("Invalid Bitcoin descriptor: {e}")))?;

    Ok((recv, change))
}

/// Strips a `#checksum` suffix, verifying it first when one is present: a
/// descriptor that lost or gained a character in transit (the field failure
/// that started this module) then fails here with a plain message instead
/// of quietly becoming a different wallet.
fn verify_checksum(input: &str) -> Result<String, TemplarError> {
    let Some((body, sum)) = input.split_once('#') else {
        return Ok(input.to_string());
    };
    let expected = bdk::descriptor::checksum::calc_checksum(body).map_err(|e| {
        BitcoinError::InvalidDescriptor(format!("Cannot compute descriptor checksum: {e}"))
    })?;
    if !sum.eq_ignore_ascii_case(&expected) {
        return Err(BitcoinError::InvalidDescriptor(
            "The descriptor's checksum does not match its text — it was altered or truncated \
             along the way. Copy it again from the source."
                .into(),
        )
        .into());
    }
    Ok(body.to_string())
}

/// True when any base58 token in the text is an extended *private* key.
fn contains_private_key(input: &str) -> bool {
    const BASE58: &str = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
    input
        .split(|c: char| !BASE58.contains(c))
        .any(|token| token.starts_with("tprv") || token.starts_with("xprv"))
}

/// Wraps a bare extended public key (optionally `[origin]`-prefixed) into
/// native-SegWit receive/change descriptors. Converts SLIP-132 testnet
/// version bytes (vpub/upub) to tpub; rejects mainnet keys outright.
fn wrap_bare_key(input: &str) -> Result<(String, String), TemplarError> {
    let (origin, key_part) = match (input.starts_with('['), input.find(']')) {
        (true, Some(i)) => (&input[..=i], &input[i + 1..]),
        _ => ("", input),
    };
    // Drop any derivation steps the user left on the key (e.g. `tpub…/0/*`);
    // the wrapper adds the standard /0/* and /1/* paths itself.
    let key = key_part.split('/').next().unwrap_or(key_part);
    let key = convert_to_tpub(key)?;
    Ok((
        format!("wpkh({origin}{key}/0/*)"),
        format!("wpkh({origin}{key}/1/*)"),
    ))
}

/// Re-encodes SLIP-132 testnet keys (vpub/upub, upper- or lower-case first
/// letter) to standard tpub version bytes. tpub passes through unchanged;
/// mainnet keys (xpub/ypub/zpub) are rejected — this build is testnet-only.
pub(crate) fn convert_to_tpub(key: &str) -> Result<String, TemplarError> {
    const TPUB: [u8; 4] = [0x04, 0x35, 0x87, 0xCF];
    let invalid =
        |m: &str| -> TemplarError { BitcoinError::InvalidDescriptor(m.to_string()).into() };

    let mut raw = bs58::decode(key)
        .with_check(None)
        .into_vec()
        .map_err(|_| invalid("Not a valid extended public key or descriptor"))?;
    if raw.len() != 78 {
        return Err(invalid("Not a valid extended public key or descriptor"));
    }
    match &raw[0..4] {
        v if *v == TPUB => {}
        // Vpub / vpub (BIP84 testnet) and Upub / upub (BIP49 testnet)
        [0x04, 0x5F, 0x1C, 0xF6]
        | [0x02, 0x57, 0x54, 0x83]
        | [0x04, 0x4A, 0x52, 0x62]
        | [0x02, 0x42, 0x89, 0xEF] => raw[0..4].copy_from_slice(&TPUB),
        // xpub / ypub / zpub and their SLIP-132 variants
        [0x04, 0x88, 0xB2, 0x1E]
        | [0x04, 0x9D, 0x7C, 0xB2]
        | [0x04, 0xB2, 0x47, 0x46]
        | [0x02, 0x95, 0xB4, 0x3F]
        | [0x02, 0xAA, 0x7E, 0xD3] => {
            return Err(invalid(
                "Mainnet extended key — this wallet is testnet-only",
            ))
        }
        _ => return Err(invalid("Unrecognized extended key version bytes")),
    }
    Ok(bs58::encode(raw).with_check().into_string())
}

/// Splits a BIP-389 multipath descriptor into (receive, change): every
/// `<a;b>` group contributes `a` to the receive path and `b` to the change
/// path. Returns `None` when there is no well-formed multipath group — the
/// caller falls through and final validation reports the parse error.
fn split_multipath(desc: &str) -> Option<(String, String)> {
    if !desc.contains('<') {
        return None;
    }
    let valid_step = |s: &str| {
        !s.is_empty()
            && s.chars()
                .all(|c| c.is_ascii_digit() || c == 'h' || c == '\'')
    };

    let mut recv = String::with_capacity(desc.len());
    let mut change = String::with_capacity(desc.len());
    let mut rest = desc;
    while let Some(start) = rest.find('<') {
        let end = rest[start..].find('>')? + start;
        let (a, b) = rest[start + 1..end].split_once(';')?;
        if !valid_step(a) || !valid_step(b) {
            return None;
        }
        recv.push_str(&rest[..start]);
        recv.push_str(a);
        change.push_str(&rest[..start]);
        change.push_str(b);
        rest = &rest[end + 1..];
    }
    recv.push_str(rest);
    change.push_str(rest);
    Some((recv, change))
}

/// Creates a watch-only BDK wallet from a receive descriptor.
///
/// The descriptor should include key origins, e.g.:
/// `wpkh([fingerprint/84'/1'/0']tpub.../0/*)`
///
/// # Arguments
/// * `data_dir` - Path to the sled database directory
/// * `receive_descriptor` - BIP-compatible receive descriptor
/// * `change_descriptor` - Optional change descriptor (if None, uses receive)
///
/// # Returns
/// A BDK `Wallet` that can sync and display but not sign.
pub fn create_watch_only_wallet(
    data_dir: &std::path::Path,
    receive_descriptor: &str,
    change_descriptor: Option<&str>,
) -> Result<Wallet<sled::Tree>, TemplarError> {
    let network = Network::Testnet;
    let db = sled::open(data_dir.join("bdk_watchonly_db"))
        .map_err(|e| BitcoinError::InvalidDescriptor(format!("Database open failed: {e}")))?;
    let tree = db
        .open_tree("watchonly")
        .map_err(|e| BitcoinError::InvalidDescriptor(format!("Database tree failed: {e}")))?;

    let wallet = Wallet::new(receive_descriptor, change_descriptor, network, tree)
        .map_err(|e| BitcoinError::InvalidDescriptor(format!("Watch-only wallet failed: {e}")))?;

    Ok(wallet)
}

/// Returns the receive address (last unused — see
/// `WalletManager::get_new_address` for why not `New`).
pub fn get_address(wallet: &Wallet<sled::Tree>) -> Result<String, TemplarError> {
    let addr = wallet
        .get_address(AddressIndex::LastUnused)
        .map_err(|e| BitcoinError::InvalidDescriptor(format!("Address failed: {e}")))?;
    Ok(addr.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    // A structurally valid testnet tpub (public key material, testnet only).
    const TPUB: &str = "tpubDCVwWj4hEpeWNFcWe3Eo1DrkLnPC4c2iitjw5wAuTkSZgofJbRMD4KESh1uhsqLCCjcjR36JooEFwfWf1ezwmAfjcPCxc7KNtnfBCrMPdtT";

    #[test]
    fn private_key_descriptors_are_not_watch_only() {
        let err = normalize_watch_only_descriptors(
            "wpkh([f0b68896/84'/1'/0']tprv8ZgxMBicQKsPdSecret/0/*)",
        )
        .unwrap_err()
        .to_string();
        assert!(err.contains("private key"), "got: {err}");
    }

    #[test]
    fn a_wrong_checksum_is_refused() {
        let body = format!("wpkh({TPUB}/0/*)");
        let good = bdk::descriptor::checksum::calc_checksum(&body).unwrap();
        assert!(normalize_watch_only_descriptors(&format!("{body}#{good}")).is_ok());
        let bad = if good.starts_with('q') {
            "pqqqqqqq"
        } else {
            "qqqqqqqq"
        };
        let err = normalize_watch_only_descriptors(&format!("{body}#{bad}"))
            .unwrap_err()
            .to_string();
        assert!(err.contains("checksum"), "got: {err}");
    }

    #[test]
    fn create_watch_only_with_invalid_descriptor_fails() {
        let tmpdir = std::env::temp_dir().join(format!("templar_wo_test_{}", std::process::id()));
        let result = create_watch_only_wallet(&tmpdir, "invalid_descriptor", None);
        assert!(result.is_err());
        let _ = std::fs::remove_dir_all(&tmpdir);
    }

    #[test]
    fn normalize_bare_tpub_wraps_wpkh() {
        let (recv, change) = normalize_watch_only_descriptors(TPUB).unwrap();
        assert_eq!(recv, format!("wpkh({TPUB}/0/*)"));
        assert_eq!(change, format!("wpkh({TPUB}/1/*)"));
    }

    #[test]
    fn normalize_bare_vpub_converts_to_tpub() {
        let vpub = crate::derivation::xpub_to_vpub_testnet(TPUB).unwrap();
        let (recv, _) = normalize_watch_only_descriptors(&vpub).unwrap();
        assert_eq!(recv, format!("wpkh({TPUB}/0/*)"));
    }

    #[test]
    fn normalize_origin_prefixed_bare_key() {
        let input = format!("[f0b68896/84'/1'/0']{TPUB}");
        let (recv, change) = normalize_watch_only_descriptors(&input).unwrap();
        assert_eq!(recv, format!("wpkh([f0b68896/84'/1'/0']{TPUB}/0/*)"));
        assert_eq!(change, format!("wpkh([f0b68896/84'/1'/0']{TPUB}/1/*)"));
    }

    #[test]
    fn normalize_multipath_splits_and_strips_checksum() {
        let body = format!("wpkh([f0b68896/84'/1'/0']{TPUB}/<0;1>/*)");
        let input = format!(
            "{body}#{}",
            bdk::descriptor::checksum::calc_checksum(&body).unwrap()
        );
        let (recv, change) = normalize_watch_only_descriptors(&input).unwrap();
        assert_eq!(recv, format!("wpkh([f0b68896/84'/1'/0']{TPUB}/0/*)"));
        assert_eq!(change, format!("wpkh([f0b68896/84'/1'/0']{TPUB}/1/*)"));
    }

    #[test]
    fn normalize_single_path_flips_change_and_strips_checksum() {
        let body = format!("wpkh({TPUB}/0/*)");
        let input = format!(
            "{body}#{}",
            bdk::descriptor::checksum::calc_checksum(&body).unwrap()
        );
        let (recv, change) = normalize_watch_only_descriptors(&input).unwrap();
        assert_eq!(recv, format!("wpkh({TPUB}/0/*)"));
        assert_eq!(change, format!("wpkh({TPUB}/1/*)"));
    }

    #[test]
    fn normalize_input_at_change_path_passes_through() {
        // An explicit change descriptor (…/1/*) has no /0/* to flip: both
        // elements are the input itself, so the change element is unchanged.
        // BDK 0.30 accepts identical receive/change pairs, so validation holds.
        let input = format!("wpkh([f0b68896/84'/1'/0']{TPUB}/1/*)");
        let (recv, change) = normalize_watch_only_descriptors(&input).unwrap();
        assert_eq!(recv, input);
        assert_eq!(change, input);
    }

    #[test]
    fn normalize_collapses_pasted_whitespace() {
        let input = format!("wpkh(\n  {TPUB}/0/*\n)");
        let (recv, _) = normalize_watch_only_descriptors(&input).unwrap();
        assert_eq!(recv, format!("wpkh({TPUB}/0/*)"));
    }

    #[test]
    fn normalize_rejects_mainnet_xpub() {
        // Same key material re-encoded with mainnet version bytes.
        let mut raw = bs58::decode(TPUB).with_check(None).into_vec().unwrap();
        raw[0..4].copy_from_slice(&[0x04, 0x88, 0xB2, 0x1E]);
        let xpub = bs58::encode(raw).with_check().into_string();
        let err = normalize_watch_only_descriptors(&xpub).unwrap_err();
        assert!(err.to_string().contains("testnet"), "got: {err}");
    }

    #[test]
    fn normalize_rejects_truncated_descriptor() {
        // The exact failure shape from the field: descriptor missing its start.
        let input = format!("19a7305cb747),elwpkh({TPUB}/<0;1>/*)#83yagts9");
        assert!(normalize_watch_only_descriptors(&input).is_err());
    }

    #[test]
    fn normalize_rejects_garbage() {
        assert!(normalize_watch_only_descriptors("not a key").is_err());
        assert!(normalize_watch_only_descriptors("").is_err());
    }
}
