//! Reading and writing the two descriptor shapes this wallet creates.
//!
//! Hardware devices don't take a descriptor string: they take a *policy* —
//! a template plus a key list. So the native drivers need to pull our
//! descriptors apart, and put equivalent ones back together.
//!
//! Deliberately not a general descriptor parser. It recognises exactly what
//! this wallet builds — `wpkh(...)` from `hw_descriptors_by_fingerprint` and
//! `wsh(sortedmulti(k, ...))` from `MultisigSetupInfo` — and returns `None`
//! for everything else, so an unexpected descriptor becomes "not recognised"
//! instead of a plausible-looking misparse handed to a signing device.

/// One cosigner key as it appears inside a descriptor.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DescriptorKey {
    /// `[fingerprint/derivation]xpub`, without the trailing `/0/*`.
    pub keyorigin: String,
    /// Lowercase master fingerprint, or empty when the descriptor omits it.
    pub fingerprint: String,
}

/// A descriptor this wallet understands.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedDescriptor {
    /// `None` for single-sig, `Some(k)` for `sortedmulti(k, ...)`.
    pub threshold: Option<usize>,
    pub keys: Vec<DescriptorKey>,
}

/// Build the `(receive, change)` pair for a BIP84 single-sig account, in the
/// exact form HWI's `getdescriptors` used to return — including the
/// unhardened `/0/*` and `/1/*` tails BDK expects.
///
/// No checksum: BDK computes and appends its own, and a wrong one is a hard
/// error rather than a warning.
pub fn wpkh_pair(fingerprint: &str, xpub: &str) -> (String, String) {
    let fp = fingerprint.to_lowercase();
    (
        format!("wpkh([{fp}/84'/1'/0']{xpub}/0/*)"),
        format!("wpkh([{fp}/84'/1'/0']{xpub}/1/*)"),
    )
}

/// Parse one of our descriptors, or `None` if it isn't one.
pub fn parse(desc: &str) -> Option<ParsedDescriptor> {
    let body = desc.split('#').next()?.trim();

    if let Some(inner) = strip_call(body, "wpkh") {
        let key = parse_key(inner)?;
        return Some(ParsedDescriptor {
            threshold: None,
            keys: vec![key],
        });
    }

    let wsh = strip_call(body, "wsh")?;
    let multi = strip_call(wsh, "sortedmulti").or_else(|| strip_call(wsh, "multi"))?;
    let mut parts = split_top_level(multi);
    if parts.len() < 2 {
        return None;
    }
    let threshold: usize = parts.remove(0).trim().parse().ok()?;
    if threshold == 0 || threshold > parts.len() {
        return None;
    }
    let keys = parts
        .iter()
        .map(|p| parse_key(p.trim()))
        .collect::<Option<Vec<_>>>()?;
    Some(ParsedDescriptor {
        threshold: Some(threshold),
        keys,
    })
}

/// `name(<inner>)` → `<inner>`, matching the closing parenthesis rather than
/// the last one in the string.
fn strip_call<'a>(s: &'a str, name: &str) -> Option<&'a str> {
    let rest = s.strip_prefix(name)?.strip_prefix('(')?;
    let mut depth = 1usize;
    for (i, c) in rest.char_indices() {
        match c {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if depth == 0 {
                    // Anything after the matching ')' means this call is nested
                    // inside something we don't model.
                    return if rest[i + 1..].trim().is_empty() {
                        Some(&rest[..i])
                    } else {
                        None
                    };
                }
            }
            _ => {}
        }
    }
    None
}

/// Split on commas that are not inside brackets or parentheses.
fn split_top_level(s: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut depth = 0usize;
    let mut current = String::new();
    for c in s.chars() {
        match c {
            '(' | '[' => {
                depth += 1;
                current.push(c);
            }
            ')' | ']' => {
                depth = depth.saturating_sub(1);
                current.push(c);
            }
            ',' if depth == 0 => out.push(std::mem::take(&mut current)),
            _ => current.push(c),
        }
    }
    if !current.trim().is_empty() {
        out.push(current);
    }
    out
}

/// `[fp/84'/1'/0']tpub…/0/*` → keyorigin without the derivation tail.
fn parse_key(s: &str) -> Option<DescriptorKey> {
    let s = s.trim();

    // Split into the optional "[origin]" prefix and the key that follows it.
    let (origin, rest) = match s.strip_prefix('[') {
        Some(after_bracket) => {
            let close = after_bracket.find(']')?;
            // 1 for '[', close for the contents, 1 for ']'.
            s.split_at(close + 2)
        }
        None => ("", s),
    };

    let fingerprint = if origin.is_empty() {
        String::new()
    } else {
        let fp = origin[1..origin.len() - 1]
            .split('/')
            .next()?
            .to_lowercase();
        // A fingerprint is 8 hex characters; anything else here means we are
        // not looking at what we think we are.
        if fp.len() != 8 || !fp.chars().all(|c| c.is_ascii_hexdigit()) {
            return None;
        }
        fp
    };

    // Everything before the first '/' is the key; the rest is the derivation
    // tail (`/0/*`, `/<0;1>/*`) which the device's policy template supplies.
    let xpub = rest.split('/').next().filter(|x| !x.is_empty())?;
    // Devices take public keys. A private key here means a signing
    // descriptor reached a driver — refuse it rather than carry it along.
    if !(xpub.starts_with("tpub") || xpub.starts_with("xpub")) {
        return None;
    }

    Some(DescriptorKey {
        keyorigin: format!("{origin}{xpub}"),
        fingerprint,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A signing descriptor must never reach a driver, and nothing parsed
    /// from one may carry the private key onward.
    #[test]
    fn private_keys_are_not_parsed() {
        let desc = "wsh(sortedmulti(2,[f0b68896/48'/1'/0'/2']tprv8ZgxMBicQKsPdSecretSecretSecret/0/*,[aabbccdd/48'/1'/0'/2']tpubDCVwWj4hEpeWNFcWe3Eo1DrkLnPC4c2iitjw5wAuTkSZgofJbRMD4KESh1uhsqLCCjcjR36JooEFwfWf1ezwmAfjcPCxc7KNtnfBCrMPdtT/0/*))";
        assert!(parse(desc).is_none());
    }

    #[test]
    fn wpkh_pair_matches_the_hwi_shape() {
        let (recv, change) = wpkh_pair("AABBCCDD", "tpubDCxyz");
        assert_eq!(recv, "wpkh([aabbccdd/84'/1'/0']tpubDCxyz/0/*)");
        assert_eq!(change, "wpkh([aabbccdd/84'/1'/0']tpubDCxyz/1/*)");
    }

    #[test]
    fn parses_singlesig() {
        let d = parse("wpkh([aabbccdd/84'/1'/0']tpubDCxyz/0/*)#checksum").unwrap();
        assert_eq!(d.threshold, None);
        assert_eq!(d.keys.len(), 1);
        assert_eq!(d.keys[0].keyorigin, "[aabbccdd/84'/1'/0']tpubDCxyz");
        assert_eq!(d.keys[0].fingerprint, "aabbccdd");
    }

    #[test]
    fn parses_multisig_and_keeps_key_order() {
        // Order matters: the device's policy commits to the key list as given,
        // and `sortedmulti` sorts at script level, not at policy level.
        let d = parse(
            "wsh(sortedmulti(2,[aabbccdd/48'/1'/0'/2']tpubA/0/*,\
             [11223344/48'/1'/0'/2']tpubB/0/*,[55667788/48'/1'/0'/2']tpubC/0/*))",
        )
        .unwrap();
        assert_eq!(d.threshold, Some(2));
        assert_eq!(d.keys.len(), 3);
        assert_eq!(d.keys[0].keyorigin, "[aabbccdd/48'/1'/0'/2']tpubA");
        assert_eq!(d.keys[2].fingerprint, "55667788");
    }

    /// The multipath form LWK-style descriptors use must lose its tail too,
    /// or the device gets a key with a range in it.
    #[test]
    fn strips_a_multipath_tail() {
        let d = parse("wpkh([aabbccdd/84'/1'/0']tpubDCxyz/<0;1>/*)").unwrap();
        assert_eq!(d.keys[0].keyorigin, "[aabbccdd/84'/1'/0']tpubDCxyz");
    }

    /// Anything outside the two shapes we build must be refused rather than
    /// half-understood — a signing device is the wrong place to guess.
    #[test]
    fn refuses_shapes_we_do_not_build() {
        assert!(parse("tr([aabbccdd/86'/1'/0']tpubDCxyz/0/*)").is_none());
        assert!(parse("sh(wpkh([aabbccdd/49'/1'/0']tpubDCxyz/0/*))").is_none());
        assert!(parse("wsh(and_v(v:pk(A),older(144)))").is_none());
        // Threshold larger than the key count is not a multisig we can sign.
        assert!(parse("wsh(sortedmulti(4,[aabbccdd/48'/1'/0'/2']tpubA/0/*))").is_none());
    }

    #[test]
    fn refuses_a_bad_fingerprint() {
        assert!(parse("wpkh([zzzz/84'/1'/0']tpubDCxyz/0/*)").is_none());
    }
}
