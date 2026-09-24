//! Policy validation and spending path analysis.
//!
//! Validates that a `PolicyFragment` is well-formed and enumerates
//! all possible spending paths with human-readable descriptions.

use crate::error::TemplarError;
use crate::policy::fragments::{blocks_to_human, PolicyFragment};

/// A single spending path through the policy tree.
#[derive(Debug, Clone)]
pub struct SpendingPath {
    /// Human-readable description of this path.
    pub description: String,
    /// Number of keys required to satisfy this path.
    pub keys_needed: usize,
    /// Relative timelock in blocks (0 = no timelock).
    pub timelock_blocks: u32,
    /// Whether this path requires a hashlock preimage.
    pub has_hashlock: bool,
}

/// Result of policy validation.
#[derive(Debug, Clone)]
pub struct ValidationResult {
    /// Whether the policy is valid.
    pub is_valid: bool,
    /// List of issues found (empty if valid).
    pub issues: Vec<String>,
    /// Warnings (policy is valid but has potential problems).
    pub warnings: Vec<String>,
    /// Enumerated spending paths.
    pub spending_paths: Vec<SpendingPath>,
}

/// Validates policy fragments and enumerates spending paths.
pub struct PolicyValidator;

impl PolicyValidator {
    /// Validates a policy fragment for correctness.
    pub fn validate(fragment: &PolicyFragment) -> Result<ValidationResult, TemplarError> {
        let mut issues = Vec::new();
        let mut warnings = Vec::new();

        Self::check_fragment(fragment, &mut issues, &mut warnings);
        let spending_paths = Self::enumerate_paths(fragment);

        if spending_paths.is_empty() {
            issues.push("No spending path exists".into());
        }

        Ok(ValidationResult {
            is_valid: issues.is_empty(),
            issues,
            warnings,
            spending_paths,
        })
    }

    /// Recursively checks a fragment for issues.
    fn check_fragment(
        fragment: &PolicyFragment,
        issues: &mut Vec<String>,
        warnings: &mut Vec<String>,
    ) {
        match fragment {
            PolicyFragment::Key { .. } => {}

            PolicyFragment::Multi { threshold, keys } => {
                if keys.is_empty() {
                    issues.push("Multisig has no keys".into());
                }
                if *threshold == 0 {
                    issues.push("Multisig threshold must be at least 1".into());
                }
                if *threshold > keys.len() {
                    issues.push(format!(
                        "Multisig threshold ({}) exceeds number of keys ({})",
                        threshold,
                        keys.len()
                    ));
                }
            }

            PolicyFragment::RelativeTimelock { blocks, .. } => {
                if *blocks == 0 {
                    issues.push("Relative timelock must be positive".into());
                }
                // BIP-68 keeps 16 bits for the value: consensus masks a larger
                // number, so 70 000 blocks would silently lock for 4 464.
                if *blocks > 65_535 {
                    issues.push(format!(
                        "Relative timelock of {} blocks exceeds the 65535-block maximum \
                         (BIP-68) — it would silently wrap to {} blocks",
                        blocks,
                        blocks & 0xFFFF
                    ));
                } else if *blocks > 52_560 {
                    // ~1 year = 52560 blocks
                    warnings.push(format!(
                        "Relative timelock of {} blocks ({}) exceeds 1 year",
                        blocks,
                        blocks_to_human(*blocks)
                    ));
                }
            }

            PolicyFragment::AbsoluteTimelock {
                value,
                is_timestamp,
                ..
            } => {
                if *value == 0 {
                    issues.push("Absolute timelock must be positive".into());
                }
                if *is_timestamp && *value < 500_000_000 {
                    issues.push("Timestamp-based timelock must be >= 500000000 (BIP-65)".into());
                }
                if !is_timestamp && *value >= 500_000_000 {
                    issues.push("Height-based timelock must be < 500000000 (BIP-65)".into());
                }
            }

            PolicyFragment::Hashlock { hash_hex, .. } => {
                if hash_hex.is_empty() {
                    issues.push("Hashlock hash is empty".into());
                }
            }

            PolicyFragment::And(left, right) => {
                Self::check_fragment(left, issues, warnings);
                Self::check_fragment(right, issues, warnings);
            }

            PolicyFragment::Or(left, right) => {
                Self::check_fragment(left, issues, warnings);
                Self::check_fragment(right, issues, warnings);
            }

            PolicyFragment::AndOr {
                condition,
                if_true,
                if_false,
            } => {
                Self::check_fragment(condition, issues, warnings);
                Self::check_fragment(if_true, issues, warnings);
                Self::check_fragment(if_false, issues, warnings);
            }

            PolicyFragment::Threshold {
                threshold,
                conditions,
            } => {
                if conditions.is_empty() {
                    issues.push("Threshold has no conditions".into());
                }
                if *threshold == 0 {
                    issues.push("Threshold must be at least 1".into());
                }
                if *threshold > conditions.len() {
                    issues.push(format!(
                        "Threshold ({}) exceeds number of conditions ({})",
                        threshold,
                        conditions.len()
                    ));
                }
                for cond in conditions {
                    Self::check_fragment(cond, issues, warnings);
                }
            }
        }
    }

    /// Enumerates all possible spending paths through the policy.
    pub fn enumerate_paths(fragment: &PolicyFragment) -> Vec<SpendingPath> {
        match fragment {
            PolicyFragment::Key { label, .. } => vec![SpendingPath {
                description: format!("Sign with {}", label),
                keys_needed: 1,
                timelock_blocks: 0,
                has_hashlock: false,
            }],

            PolicyFragment::Multi { threshold, keys } => vec![SpendingPath {
                description: format!("{}-of-{} multisig", threshold, keys.len()),
                keys_needed: *threshold,
                timelock_blocks: 0,
                has_hashlock: false,
            }],

            PolicyFragment::RelativeTimelock { blocks, .. } => vec![SpendingPath {
                description: format!("Wait {} ({})", blocks_to_human(*blocks), blocks),
                keys_needed: 0,
                timelock_blocks: *blocks,
                has_hashlock: false,
            }],

            PolicyFragment::AbsoluteTimelock {
                human_label, value, ..
            } => vec![SpendingPath {
                description: format!("After {} ({})", human_label, value),
                keys_needed: 0,
                timelock_blocks: 0, // absolute, not relative
                has_hashlock: false,
            }],

            PolicyFragment::Hashlock { hash_type, .. } => vec![SpendingPath {
                description: format!("Reveal {} preimage", hash_type.miniscript_name()),
                keys_needed: 0,
                timelock_blocks: 0,
                has_hashlock: true,
            }],

            PolicyFragment::And(left, right) => {
                let left_paths = Self::enumerate_paths(left);
                let right_paths = Self::enumerate_paths(right);
                // AND: every left path combined with every right path
                let mut paths = Vec::new();
                for lp in &left_paths {
                    for rp in &right_paths {
                        paths.push(SpendingPath {
                            description: format!("{} AND {}", lp.description, rp.description),
                            keys_needed: lp.keys_needed + rp.keys_needed,
                            timelock_blocks: lp.timelock_blocks.max(rp.timelock_blocks),
                            has_hashlock: lp.has_hashlock || rp.has_hashlock,
                        });
                    }
                }
                paths
            }

            PolicyFragment::Or(left, right) => {
                let mut paths = Self::enumerate_paths(left);
                let right_paths = Self::enumerate_paths(right);
                // OR: all paths from both branches
                for mut rp in right_paths {
                    rp.description = format!("{} (alternative)", rp.description);
                    paths.push(rp);
                }
                paths
            }

            PolicyFragment::AndOr {
                condition,
                if_true,
                if_false,
            } => {
                let cond_paths = Self::enumerate_paths(condition);
                let true_paths = Self::enumerate_paths(if_true);
                let false_paths = Self::enumerate_paths(if_false);

                let mut paths = Vec::new();
                // If condition met: condition + if_true
                for cp in &cond_paths {
                    for tp in &true_paths {
                        paths.push(SpendingPath {
                            description: format!("If {} then {}", cp.description, tp.description),
                            keys_needed: cp.keys_needed + tp.keys_needed,
                            timelock_blocks: cp.timelock_blocks.max(tp.timelock_blocks),
                            has_hashlock: cp.has_hashlock || tp.has_hashlock,
                        });
                    }
                }
                // If condition not met: if_false
                for fp in false_paths {
                    paths.push(SpendingPath {
                        description: format!("Otherwise: {}", fp.description),
                        keys_needed: fp.keys_needed,
                        timelock_blocks: fp.timelock_blocks,
                        has_hashlock: fp.has_hashlock,
                    });
                }
                paths
            }

            PolicyFragment::Threshold {
                threshold,
                conditions,
            } => {
                // Simplified: show one path with the threshold
                vec![SpendingPath {
                    description: format!(
                        "{}-of-{} conditions satisfied",
                        threshold,
                        conditions.len()
                    ),
                    keys_needed: *threshold,
                    timelock_blocks: 0,
                    has_hashlock: false,
                }]
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::policy::fragments::PolicyKey;

    fn test_key(idx: usize) -> PolicyKey {
        PolicyKey::Software {
            mnemonic_index: idx,
        }
    }

    #[test]
    fn validate_single_key() {
        let frag = PolicyFragment::Key {
            label: "Alice".into(),
            key: test_key(0),
        };
        let result = PolicyValidator::validate(&frag).unwrap();
        assert!(result.is_valid);
        assert_eq!(result.spending_paths.len(), 1);
        assert_eq!(result.spending_paths[0].keys_needed, 1);
    }

    #[test]
    fn validate_multisig_valid() {
        let frag = PolicyFragment::Multi {
            threshold: 2,
            keys: vec![test_key(0), test_key(1), test_key(2)],
        };
        let result = PolicyValidator::validate(&frag).unwrap();
        assert!(result.is_valid);
        assert_eq!(result.spending_paths[0].keys_needed, 2);
    }

    #[test]
    fn validate_multisig_threshold_exceeds_keys() {
        let frag = PolicyFragment::Multi {
            threshold: 5,
            keys: vec![test_key(0), test_key(1)],
        };
        let result = PolicyValidator::validate(&frag).unwrap();
        assert!(!result.is_valid);
        assert!(result.issues.iter().any(|i| i.contains("exceeds")));
    }

    #[test]
    fn validate_multisig_zero_threshold() {
        let frag = PolicyFragment::Multi {
            threshold: 0,
            keys: vec![test_key(0)],
        };
        let result = PolicyValidator::validate(&frag).unwrap();
        assert!(!result.is_valid);
    }

    #[test]
    fn validate_timelock_zero() {
        let frag = PolicyFragment::RelativeTimelock {
            blocks: 0,
            human_label: "zero".into(),
        };
        let result = PolicyValidator::validate(&frag).unwrap();
        assert!(!result.is_valid);
    }

    #[test]
    fn validate_timelock_over_bip68_max_is_invalid_and_over_a_year_warns() {
        // BIP-68 keeps 16 bits: 200 000 blocks would wrap to 3 392.
        let frag = PolicyFragment::RelativeTimelock {
            blocks: 200_000,
            human_label: "long".into(),
        };
        let result = PolicyValidator::validate(&frag).unwrap();
        assert!(!result.is_valid);
        let frag = PolicyFragment::RelativeTimelock {
            blocks: 60_000,
            human_label: "long".into(),
        };
        let result = PolicyValidator::validate(&frag).unwrap();
        assert!(result.is_valid);
        assert!(!result.warnings.is_empty());
    }

    #[test]
    fn validate_or_produces_two_paths() {
        let frag = PolicyFragment::Or(
            Box::new(PolicyFragment::Key {
                label: "Alice".into(),
                key: test_key(0),
            }),
            Box::new(PolicyFragment::Key {
                label: "Bob".into(),
                key: test_key(1),
            }),
        );
        let result = PolicyValidator::validate(&frag).unwrap();
        assert!(result.is_valid);
        assert_eq!(result.spending_paths.len(), 2);
    }

    #[test]
    fn validate_and_combines_paths() {
        let frag = PolicyFragment::And(
            Box::new(PolicyFragment::Key {
                label: "Alice".into(),
                key: test_key(0),
            }),
            Box::new(PolicyFragment::RelativeTimelock {
                blocks: 144,
                human_label: "~1 day".into(),
            }),
        );
        let result = PolicyValidator::validate(&frag).unwrap();
        assert!(result.is_valid);
        assert_eq!(result.spending_paths.len(), 1);
        assert_eq!(result.spending_paths[0].keys_needed, 1);
        assert_eq!(result.spending_paths[0].timelock_blocks, 144);
    }

    #[test]
    fn validate_recovery_template_pattern() {
        // or_d(pk(primary), and_v(v:pk(recovery), older(delay)))
        let frag = PolicyFragment::Or(
            Box::new(PolicyFragment::Key {
                label: "Primary".into(),
                key: test_key(0),
            }),
            Box::new(PolicyFragment::And(
                Box::new(PolicyFragment::Key {
                    label: "Recovery".into(),
                    key: test_key(1),
                }),
                Box::new(PolicyFragment::RelativeTimelock {
                    blocks: 12960,
                    human_label: "~90 days".into(),
                }),
            )),
        );
        let result = PolicyValidator::validate(&frag).unwrap();
        assert!(result.is_valid);
        assert_eq!(result.spending_paths.len(), 2);
        // Primary path: 1 key, no timelock
        assert_eq!(result.spending_paths[0].keys_needed, 1);
        assert_eq!(result.spending_paths[0].timelock_blocks, 0);
        // Recovery path: 1 key + timelock
        assert_eq!(result.spending_paths[1].keys_needed, 1);
        assert_eq!(result.spending_paths[1].timelock_blocks, 12960);
    }
}
