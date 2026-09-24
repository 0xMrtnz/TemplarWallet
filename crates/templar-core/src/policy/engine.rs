//! Policy → Miniscript descriptor compiler.
//!
//! Converts a `PolicyFragment` tree into a pair of `wsh(...)` descriptors
//! (receive + change) that BDK 0.30 can parse and use.

use bdk::bitcoin::secp256k1::Secp256k1;

use crate::error::{PolicyError, TemplarError};
use crate::policy::fragments::{PolicyFragment, PolicyKey};

/// Resolves `PolicyKey` values into descriptor key strings.
///
/// Each key becomes `[fp/path]xpub` for external/hardware keys,
/// or a test key for software keys (resolved at wallet creation time).
pub struct PolicyKeyResolver {
    /// Resolved key strings in order, e.g. `[fingerprint/84'/1'/0']tpub.../0/*`
    keys: Vec<String>,
}

impl PolicyKeyResolver {
    /// Creates a resolver from a list of descriptor key strings.
    ///
    /// Each string should be a BIP32 key origin + xpub without the wildcard suffix,
    /// e.g. `[abcd1234/84'/1'/0']tpubDEF...`
    /// The compiler appends `/<0;1>/*` for multipath or `/0/*`, `/1/*` for split descriptors.
    pub fn new(keys: Vec<String>) -> Self {
        Self { keys }
    }

    /// Resolves a `PolicyKey` to its descriptor key string (without wildcard).
    pub fn resolve(&self, key: &PolicyKey) -> Result<String, TemplarError> {
        match key {
            PolicyKey::Software { mnemonic_index } => {
                self.keys.get(*mnemonic_index).cloned().ok_or_else(|| {
                    PolicyError::InvalidPolicy(format!(
                        "Software key index {} out of range (have {} keys)",
                        mnemonic_index,
                        self.keys.len()
                    ))
                    .into()
                })
            }
            PolicyKey::Hardware {
                fingerprint,
                xpub,
                derivation_path,
            } => Ok(format!("[{}/{}]{}", fingerprint, derivation_path, xpub)),
            PolicyKey::External { descriptor_key } => Ok(descriptor_key.clone()),
        }
    }

    /// Resolves a key with a specific derivation suffix (e.g. `/0/*` or `/1/*`).
    fn resolve_with_suffix(&self, key: &PolicyKey, suffix: &str) -> Result<String, TemplarError> {
        let base = self.resolve(key)?;
        Ok(format!("{}{}", base, suffix))
    }
}

/// Compiles a `PolicyFragment` into a pair of `wsh(...)` descriptors.
pub struct PolicyCompiler;

impl PolicyCompiler {
    /// Compiles a policy fragment into receive and change descriptors.
    ///
    /// Returns `(receive_descriptor, change_descriptor)`.
    /// Both are validated by parsing with BDK 0.30 — if BDK rejects it,
    /// returns `PolicyError::CompilationFailed`.
    pub fn compile(
        fragment: &PolicyFragment,
        resolver: &PolicyKeyResolver,
    ) -> Result<(String, String), TemplarError> {
        let recv_inner = Self::compile_fragment(fragment, resolver, "/0/*")?;
        let change_inner = Self::compile_fragment(fragment, resolver, "/1/*")?;

        let recv_desc = format!("wsh({})", recv_inner);
        let change_desc = format!("wsh({})", change_inner);

        // Validate with BDK 0.30
        let secp = Secp256k1::new();
        bdk::descriptor::Descriptor::<bdk::descriptor::DescriptorPublicKey>::parse_descriptor(
            &secp, &recv_desc,
        )
        .map_err(|e| {
            PolicyError::CompilationFailed(format!(
                "BDK rejected receive descriptor: {e}\nDescriptor: {recv_desc}"
            ))
        })?;
        bdk::descriptor::Descriptor::<bdk::descriptor::DescriptorPublicKey>::parse_descriptor(
            &secp,
            &change_desc,
        )
        .map_err(|e| {
            PolicyError::CompilationFailed(format!(
                "BDK rejected change descriptor: {e}\nDescriptor: {change_desc}"
            ))
        })?;

        Ok((recv_desc, change_desc))
    }

    /// Compiles a single-key policy into `wpkh(...)` descriptors (not wsh).
    ///
    /// Used for SingleSig template which produces standard wpkh, not wsh(pk(...)).
    pub fn compile_singlesig(
        key: &PolicyKey,
        resolver: &PolicyKeyResolver,
    ) -> Result<(String, String), TemplarError> {
        let recv_key = resolver.resolve_with_suffix(key, "/0/*")?;
        let change_key = resolver.resolve_with_suffix(key, "/1/*")?;

        let recv_desc = format!("wpkh({})", recv_key);
        let change_desc = format!("wpkh({})", change_key);

        let secp = Secp256k1::new();
        bdk::descriptor::Descriptor::<bdk::descriptor::DescriptorPublicKey>::parse_descriptor(
            &secp, &recv_desc,
        )
        .map_err(|e| {
            PolicyError::CompilationFailed(format!("BDK rejected wpkh descriptor: {e}"))
        })?;

        Ok((recv_desc, change_desc))
    }

    /// Compiles a multisig policy into `wsh(sortedmulti(...))` descriptors.
    ///
    /// Uses `sortedmulti` for BIP67 key ordering (Sparrow/Coldcard compatible).
    pub fn compile_multisig(
        threshold: usize,
        keys: &[PolicyKey],
        resolver: &PolicyKeyResolver,
    ) -> Result<(String, String), TemplarError> {
        let recv_keys: Vec<String> = keys
            .iter()
            .map(|k| resolver.resolve_with_suffix(k, "/0/*"))
            .collect::<Result<_, _>>()?;
        let change_keys: Vec<String> = keys
            .iter()
            .map(|k| resolver.resolve_with_suffix(k, "/1/*"))
            .collect::<Result<_, _>>()?;

        let recv_desc = format!("wsh(sortedmulti({},{}))", threshold, recv_keys.join(","));
        let change_desc = format!("wsh(sortedmulti({},{}))", threshold, change_keys.join(","));

        let secp = Secp256k1::new();
        bdk::descriptor::Descriptor::<bdk::descriptor::DescriptorPublicKey>::parse_descriptor(
            &secp, &recv_desc,
        )
        .map_err(|e| {
            PolicyError::CompilationFailed(format!("BDK rejected multisig descriptor: {e}"))
        })?;

        Ok((recv_desc, change_desc))
    }

    /// Recursively compiles a fragment into a Miniscript expression string.
    fn compile_fragment(
        fragment: &PolicyFragment,
        resolver: &PolicyKeyResolver,
        key_suffix: &str,
    ) -> Result<String, TemplarError> {
        match fragment {
            PolicyFragment::Key { key, .. } => {
                let k = resolver.resolve_with_suffix(key, key_suffix)?;
                Ok(format!("pk({})", k))
            }

            PolicyFragment::Multi { threshold, keys } => {
                let key_strs: Vec<String> = keys
                    .iter()
                    .map(|k| resolver.resolve_with_suffix(k, key_suffix))
                    .collect::<Result<_, _>>()?;
                Ok(format!("multi({},{})", threshold, key_strs.join(",")))
            }

            PolicyFragment::RelativeTimelock { blocks, .. } => Ok(format!("older({})", blocks)),

            PolicyFragment::AbsoluteTimelock { value, .. } => Ok(format!("after({})", value)),

            PolicyFragment::Hashlock {
                hash_type,
                hash_hex,
            } => Ok(format!("{}({})", hash_type.miniscript_name(), hash_hex)),

            PolicyFragment::And(left, right) => {
                let l = Self::compile_fragment(left, resolver, key_suffix)?;
                let r = Self::compile_fragment(right, resolver, key_suffix)?;
                Ok(format!("and_v(v:{},{})", l, r))
            }

            PolicyFragment::Or(left, right) => {
                let l = Self::compile_fragment(left, resolver, key_suffix)?;
                let r = Self::compile_fragment(right, resolver, key_suffix)?;
                Ok(format!("or_d({},{})", l, r))
            }

            PolicyFragment::AndOr {
                condition,
                if_true,
                if_false,
            } => {
                let c = Self::compile_fragment(condition, resolver, key_suffix)?;
                let t = Self::compile_fragment(if_true, resolver, key_suffix)?;
                let f = Self::compile_fragment(if_false, resolver, key_suffix)?;
                Ok(format!("andor({},{},{})", c, t, f))
            }

            PolicyFragment::Threshold {
                threshold,
                conditions,
            } => {
                let subs: Vec<String> = conditions
                    .iter()
                    .enumerate()
                    .map(|(i, c)| {
                        let inner = Self::compile_fragment(c, resolver, key_suffix)?;
                        // First sub has no wrapper, subsequent get s: prefix
                        if i == 0 {
                            Ok(inner)
                        } else {
                            Ok(format!("s:{}", inner))
                        }
                    })
                    .collect::<Result<_, TemplarError>>()?;
                Ok(format!("thresh({},{})", threshold, subs.join(",")))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::policy::fragments::PolicyFragment;
    use crate::policy::templates::PolicyTemplate;
    use bdk::bitcoin::bip32::{DerivationPath, ExtendedPubKey};
    use bdk::bitcoin::Network;
    use bdk::keys::bip39::Mnemonic;
    use bdk::keys::{DerivableKey, ExtendedKey};
    use std::str::FromStr;

    fn sw_key(idx: usize) -> PolicyKey {
        PolicyKey::Software {
            mnemonic_index: idx,
        }
    }

    /// Test mnemonics — each produces a distinct key.
    const MNEMONICS: &[&str] = &[
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
        "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong",
        "letter advice cage absurd amount doctor acoustic avoid letter advice cage above",
        "ozone drill grab fiber curtain grace pudding thank cruise elder eight picnic",
        "void come effort suffer camp survey warrior heavy shoot primary clutch crush open amazing screen patrol group space point ten exist slush involve unfold",
    ];

    /// Derives a valid testnet tpub with key origin from a test mnemonic.
    fn make_tpub(idx: usize) -> String {
        let secp = Secp256k1::new();
        let mnemonic = Mnemonic::parse(MNEMONICS[idx]).unwrap();
        let xkey: ExtendedKey = mnemonic.into_extended_key().unwrap();
        let xprv = xkey.into_xprv(Network::Testnet).unwrap();
        let fp = xprv.fingerprint(&secp);
        let path = DerivationPath::from_str("m/84'/1'/0'").unwrap();
        let derived = xprv.derive_priv(&secp, &path).unwrap();
        let xpub = ExtendedPubKey::from_priv(&secp, &derived);
        format!("[{}/84'/1'/0']{}", fp, xpub)
    }

    fn resolver_n(n: usize) -> PolicyKeyResolver {
        let keys: Vec<String> = (0..n).map(make_tpub).collect();
        PolicyKeyResolver::new(keys)
    }

    #[test]
    fn compile_singlesig() {
        let resolver = resolver_n(1);
        let (recv, change) = PolicyCompiler::compile_singlesig(&sw_key(0), &resolver).unwrap();
        assert!(recv.starts_with("wpkh("));
        assert!(change.starts_with("wpkh("));
        assert!(recv.contains("/0/*"));
        assert!(change.contains("/1/*"));
    }

    #[test]
    fn compile_multisig_2of3() {
        let resolver = resolver_n(3);
        let keys = vec![sw_key(0), sw_key(1), sw_key(2)];
        let (recv, change) = PolicyCompiler::compile_multisig(2, &keys, &resolver).unwrap();
        assert!(recv.starts_with("wsh(sortedmulti(2,"));
        assert!(change.starts_with("wsh(sortedmulti(2,"));
    }

    #[test]
    fn compile_recovery_template() {
        let resolver = resolver_n(2);
        let template = PolicyTemplate::default_recovery();
        let keys = vec![sw_key(0), sw_key(1)];
        let fragment = template.to_fragment(&keys).unwrap();
        let (recv, change) = PolicyCompiler::compile(&fragment, &resolver).unwrap();
        assert!(recv.starts_with("wsh("));
        assert!(change.starts_with("wsh("));
        assert!(recv.contains("or_d("));
        assert!(recv.contains("older(12960)"));
    }

    #[test]
    fn compile_inheritance_template() {
        let resolver = resolver_n(4);
        let template = PolicyTemplate::default_inheritance();
        // default_inheritance: threshold=2, required_keys = threshold+2 = 4
        let keys = vec![sw_key(0), sw_key(1), sw_key(2), sw_key(3)];
        let fragment = template.to_fragment(&keys).unwrap();
        let (recv, _change) = PolicyCompiler::compile(&fragment, &resolver).unwrap();
        assert!(recv.starts_with("wsh("));
        assert!(recv.contains("older(26280)"));
    }

    #[test]
    fn compile_treasury_template() {
        // default_treasury: lead_threshold=2, delay=1008
        // Keys: [0]=HSM, [1]=CFO, [2..4]=leads (lead_threshold+1 = 3 leads)
        // required_keys = 2 + lead_threshold + 1 = 5
        let resolver = resolver_n(5);
        let template = PolicyTemplate::default_treasury();
        let keys = vec![sw_key(0), sw_key(1), sw_key(2), sw_key(3), sw_key(4)];
        let fragment = template.to_fragment(&keys).unwrap();
        let (recv, change) = PolicyCompiler::compile(&fragment, &resolver).unwrap();
        assert!(recv.starts_with("wsh("));
        assert!(change.starts_with("wsh("));
        // Should contain the delay and multi
        assert!(recv.contains("older(1008)"));
        assert!(recv.contains("multi(2,"));
    }

    #[test]
    fn compile_key_index_out_of_range() {
        let resolver = resolver_n(1);
        let frag = PolicyFragment::Key {
            label: "Missing".into(),
            key: sw_key(5),
        };
        let result = PolicyCompiler::compile(&frag, &resolver);
        assert!(result.is_err());
    }

    #[test]
    fn template_insufficient_keys() {
        let template = PolicyTemplate::Recovery { delay_blocks: 144 };
        let keys = vec![sw_key(0)]; // needs 2
        let result = template.to_fragment(&keys);
        assert!(result.is_err());
    }

    #[test]
    fn template_key_labels_match_required() {
        let templates: Vec<PolicyTemplate> = vec![
            PolicyTemplate::SingleSig,
            PolicyTemplate::Multisig {
                threshold: 2,
                total: 3,
            },
            PolicyTemplate::default_inheritance(),
            PolicyTemplate::default_treasury(),
            PolicyTemplate::default_recovery(),
        ];
        for t in &templates {
            assert_eq!(
                t.key_labels().len(),
                t.required_keys(),
                "key_labels count mismatch for {:?}",
                t
            );
        }
    }

    #[test]
    fn resolver_hardware_key() {
        let tpub_str = make_tpub(1);
        // Extract just the xpub part (after the ] in key origin)
        let xpub_part = tpub_str.split(']').nth(1).unwrap();
        let key = PolicyKey::Hardware {
            fingerprint: "aabbccdd".into(),
            xpub: xpub_part.into(),
            derivation_path: "84'/1'/0'".into(),
        };
        let resolver = PolicyKeyResolver::new(vec![]);
        let resolved = resolver.resolve(&key).unwrap();
        assert!(resolved.starts_with("[aabbccdd/84'/1'/0']"));
        assert!(resolved.contains("tpub"));
    }

    #[test]
    fn resolver_external_key() {
        let key = PolicyKey::External {
            descriptor_key: "some_descriptor_key".into(),
        };
        let resolver = PolicyKeyResolver::new(vec![]);
        let resolved = resolver.resolve(&key).unwrap();
        assert_eq!(resolved, "some_descriptor_key");
    }
}
