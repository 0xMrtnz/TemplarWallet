//! Miniscript building blocks — the atomic pieces that compose spending policies.
//!
//! A `PolicyFragment` represents a node in the policy tree. The compiler
//! (`engine.rs`) recursively converts fragments into Miniscript strings
//! wrapped in `wsh(...)`.

use serde::{Deserialize, Serialize};

/// Identifies a key participant in a spending policy.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum PolicyKey {
    /// Software key from a BIP39 mnemonic managed by this wallet.
    Software {
        /// Index into the key list (0-based).
        mnemonic_index: usize,
    },
    /// Hardware wallet key identified by fingerprint and xpub.
    Hardware {
        fingerprint: String,
        xpub: String,
        derivation_path: String,
    },
    /// External key provided as a descriptor key string (e.g. `[fp/path]xpub`).
    External { descriptor_key: String },
}

impl PolicyKey {
    /// Returns a human-readable label for this key.
    pub fn label(&self) -> String {
        match self {
            PolicyKey::Software { mnemonic_index } => format!("Software Key #{}", mnemonic_index),
            PolicyKey::Hardware { fingerprint, .. } => format!("HW [{}]", fingerprint),
            PolicyKey::External { descriptor_key } => {
                if descriptor_key.len() > 20 {
                    format!("External [{}...]", &descriptor_key[..16])
                } else {
                    format!("External [{}]", descriptor_key)
                }
            }
        }
    }
}

/// Hash function type for hashlock conditions.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum HashType {
    Sha256,
    Hash256,
    Ripemd160,
    Hash160,
}

impl HashType {
    /// Returns the Miniscript function name for this hash type.
    pub fn miniscript_name(&self) -> &'static str {
        match self {
            HashType::Sha256 => "sha256",
            HashType::Hash256 => "hash256",
            HashType::Ripemd160 => "ripemd160",
            HashType::Hash160 => "hash160",
        }
    }
}

/// A node in the spending policy tree.
///
/// Fragments are composed recursively to express complex spending conditions.
/// The compiler converts these into Miniscript descriptor strings.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum PolicyFragment {
    /// Single key: `pk(KEY)`
    Key { label: String, key: PolicyKey },

    /// k-of-n multisig: `multi(k, KEY1, KEY2, ...)`
    Multi {
        threshold: usize,
        keys: Vec<PolicyKey>,
    },

    /// Relative timelock: `older(N)` — N blocks after UTXO confirmation.
    RelativeTimelock { blocks: u32, human_label: String },

    /// Absolute timelock: `after(N)` — block height or UNIX timestamp.
    AbsoluteTimelock {
        value: u32,
        is_timestamp: bool,
        human_label: String,
    },

    /// Hashlock: `sha256(H)` / `hash256(H)` / `ripemd160(H)` / `hash160(H)`
    Hashlock {
        hash_type: HashType,
        hash_hex: String,
    },

    /// Both conditions must be satisfied: `and_v(v:A, B)`
    And(Box<PolicyFragment>, Box<PolicyFragment>),

    /// Either condition suffices: `or_d(A, B)` or `or_i(A, B)`
    Or(Box<PolicyFragment>, Box<PolicyFragment>),

    /// If-then-else: `andor(COND, IF_TRUE, IF_FALSE)`
    AndOr {
        condition: Box<PolicyFragment>,
        if_true: Box<PolicyFragment>,
        if_false: Box<PolicyFragment>,
    },

    /// k-of-n threshold over mixed conditions: `thresh(k, SUB1, SUB2, ...)`
    Threshold {
        threshold: usize,
        conditions: Vec<PolicyFragment>,
    },
}

/// Converts a block count to a human-readable duration string.
///
/// Assumes ~10 minutes per block (Bitcoin average).
pub fn blocks_to_human(blocks: u32) -> String {
    let minutes = blocks as u64 * 10;
    let hours = minutes / 60;
    let days = hours / 24;
    let months = days / 30;
    let years = days / 365;

    if years > 0 {
        if years == 1 {
            "~1 year".to_string()
        } else {
            format!("~{} years", years)
        }
    } else if months > 0 {
        if months == 1 {
            "~1 month".to_string()
        } else {
            format!("~{} months", months)
        }
    } else if days > 0 {
        if days == 1 {
            "~1 day".to_string()
        } else {
            format!("~{} days", days)
        }
    } else if hours > 0 {
        if hours == 1 {
            "~1 hour".to_string()
        } else {
            format!("~{} hours", hours)
        }
    } else {
        format!("~{} minutes", minutes)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blocks_to_human_minutes() {
        assert_eq!(blocks_to_human(3), "~30 minutes");
    }

    #[test]
    fn blocks_to_human_hours() {
        assert_eq!(blocks_to_human(6), "~1 hour");
        assert_eq!(blocks_to_human(18), "~3 hours");
    }

    #[test]
    fn blocks_to_human_days() {
        assert_eq!(blocks_to_human(144), "~1 day");
        assert_eq!(blocks_to_human(432), "~3 days");
    }

    #[test]
    fn blocks_to_human_months() {
        assert_eq!(blocks_to_human(4320), "~1 month");
        assert_eq!(blocks_to_human(26280), "~6 months");
    }

    #[test]
    fn blocks_to_human_years() {
        assert_eq!(blocks_to_human(52560), "~1 year");
        assert_eq!(blocks_to_human(105120), "~2 years");
    }

    #[test]
    fn hash_type_miniscript_names() {
        assert_eq!(HashType::Sha256.miniscript_name(), "sha256");
        assert_eq!(HashType::Hash256.miniscript_name(), "hash256");
        assert_eq!(HashType::Ripemd160.miniscript_name(), "ripemd160");
        assert_eq!(HashType::Hash160.miniscript_name(), "hash160");
    }

    #[test]
    fn policy_key_labels() {
        let sw = PolicyKey::Software { mnemonic_index: 0 };
        assert_eq!(sw.label(), "Software Key #0");

        let hw = PolicyKey::Hardware {
            fingerprint: "abcd1234".into(),
            xpub: "tpub...".into(),
            derivation_path: "84'/1'/0'".into(),
        };
        assert_eq!(hw.label(), "HW [abcd1234]");

        let ext = PolicyKey::External {
            descriptor_key: "short".into(),
        };
        assert_eq!(ext.label(), "External [short]");

        let ext_long = PolicyKey::External {
            descriptor_key: "a]very_long_descriptor_key_string".into(),
        };
        assert!(ext_long.label().contains("..."));
    }
}
