//! Predefined spending policy templates.
//!
//! Each template produces a `PolicyFragment` tree that the compiler
//! converts into a BDK-compatible Miniscript descriptor.

use serde::{Deserialize, Serialize};

use crate::error::{PolicyError, TemplarError};
use crate::policy::fragments::{blocks_to_human, PolicyFragment, PolicyKey};

/// Predefined policy templates covering common custody patterns.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum PolicyTemplate {
    /// Single key — standard wpkh wallet.
    SingleSig,

    /// k-of-n multisig — `wsh(sortedmulti(k, ...))`.
    Multisig { threshold: usize, total: usize },

    /// Inheritance: immediate multisig OR backup key after delay.
    ///
    /// `or_d(multi(M, keys...), and_v(v:pk(backup), older(delay)))`
    /// Default: 2-of-3 + backup after 26280 blocks (~6 months).
    Inheritance {
        /// Threshold for the immediate multisig path.
        threshold: usize,
        /// Delay in blocks before the backup key can spend.
        delay_blocks: u32,
    },

    /// Corporate treasury: daily operations + high-value override + emergency.
    ///
    /// `and_v(or_c(pk(HSM), or_i(v:pk(CFO), v:older(delay))), multi(2, leads...))`
    /// Default: 2-of-3 leads + HSM daily, CFO high value, leads-only after 1008 blocks (~7 days).
    CorporateTreasury {
        /// Number of lead signers required.
        lead_threshold: usize,
        /// Delay in blocks before leads can spend without HSM/CFO.
        delay_blocks: u32,
    },

    /// Emergency recovery: primary key OR recovery key after delay.
    ///
    /// `or_d(pk(primary), and_v(v:pk(recovery), older(delay)))`
    /// Default: primary immediate, recovery after 12960 blocks (~90 days).
    Recovery {
        /// Delay in blocks before recovery key activates.
        delay_blocks: u32,
    },

    /// Custom policy — user builds from scratch.
    Custom,
}

impl PolicyTemplate {
    /// Converts this template to a `PolicyFragment` using the provided keys.
    ///
    /// Key ordering varies by template — see `key_labels()` for the expected order.
    pub fn to_fragment(&self, keys: &[PolicyKey]) -> Result<PolicyFragment, TemplarError> {
        let required = self.required_keys();
        if keys.len() < required {
            return Err(PolicyError::InvalidPolicy(format!(
                "Template requires {} keys, got {}",
                required,
                keys.len()
            ))
            .into());
        }

        match self {
            PolicyTemplate::SingleSig => Ok(PolicyFragment::Key {
                label: "Primary".into(),
                key: keys[0].clone(),
            }),

            PolicyTemplate::Multisig { threshold, total } => {
                if keys.len() < *total {
                    return Err(PolicyError::InvalidPolicy(format!(
                        "Multisig {}-of-{} requires {} keys, got {}",
                        threshold,
                        total,
                        total,
                        keys.len()
                    ))
                    .into());
                }
                Ok(PolicyFragment::Multi {
                    threshold: *threshold,
                    keys: keys[..*total].to_vec(),
                })
            }

            PolicyTemplate::Inheritance {
                threshold,
                delay_blocks,
            } => {
                // Keys: [0..threshold+1) = main signers, last = backup
                let main_count = keys.len() - 1;
                let main_keys = keys[..main_count].to_vec();
                let backup_key = keys[main_count].clone();

                let immediate = PolicyFragment::Multi {
                    threshold: *threshold,
                    keys: main_keys,
                };
                let delayed = PolicyFragment::And(
                    Box::new(PolicyFragment::Key {
                        label: "Backup".into(),
                        key: backup_key,
                    }),
                    Box::new(PolicyFragment::RelativeTimelock {
                        blocks: *delay_blocks,
                        human_label: blocks_to_human(*delay_blocks),
                    }),
                );
                Ok(PolicyFragment::Or(Box::new(immediate), Box::new(delayed)))
            }

            PolicyTemplate::CorporateTreasury {
                lead_threshold,
                delay_blocks,
            } => {
                // Keys: [0] = HSM, [1] = CFO, [2..] = leads
                let hsm_key = keys[0].clone();
                let cfo_key = keys[1].clone();
                let lead_keys = keys[2..].to_vec();

                // or_c(pk(HSM), or_i(v:pk(CFO), v:older(delay)))
                let auth = PolicyFragment::Or(
                    Box::new(PolicyFragment::Key {
                        label: "HSM".into(),
                        key: hsm_key,
                    }),
                    Box::new(PolicyFragment::Or(
                        Box::new(PolicyFragment::Key {
                            label: "CFO".into(),
                            key: cfo_key,
                        }),
                        Box::new(PolicyFragment::RelativeTimelock {
                            blocks: *delay_blocks,
                            human_label: blocks_to_human(*delay_blocks),
                        }),
                    )),
                );

                // and_v(auth, multi(lead_threshold, leads...))
                let leads = PolicyFragment::Multi {
                    threshold: *lead_threshold,
                    keys: lead_keys,
                };

                Ok(PolicyFragment::And(Box::new(auth), Box::new(leads)))
            }

            PolicyTemplate::Recovery { delay_blocks } => {
                // Keys: [0] = primary, [1] = recovery
                let primary = PolicyFragment::Key {
                    label: "Primary".into(),
                    key: keys[0].clone(),
                };
                let recovery = PolicyFragment::And(
                    Box::new(PolicyFragment::Key {
                        label: "Recovery".into(),
                        key: keys[1].clone(),
                    }),
                    Box::new(PolicyFragment::RelativeTimelock {
                        blocks: *delay_blocks,
                        human_label: blocks_to_human(*delay_blocks),
                    }),
                );
                Ok(PolicyFragment::Or(Box::new(primary), Box::new(recovery)))
            }

            PolicyTemplate::Custom => Err(PolicyError::InvalidPolicy(
                "Custom template requires a pre-built fragment".into(),
            )
            .into()),
        }
    }

    /// Human-readable description of this template.
    pub fn description(&self) -> &str {
        match self {
            PolicyTemplate::SingleSig => "Standard single-key wallet (wpkh)",
            PolicyTemplate::Multisig { .. } => "Multi-signature wallet (k-of-n)",
            PolicyTemplate::Inheritance { .. } => {
                "Inheritance: immediate multisig OR backup key after time delay"
            }
            PolicyTemplate::CorporateTreasury { .. } => {
                "Corporate treasury: HSM + leads daily, CFO for high value, leads-only after delay"
            }
            PolicyTemplate::Recovery { .. } => {
                "Emergency recovery: primary key OR recovery key after time delay"
            }
            PolicyTemplate::Custom => "Custom policy built from scratch",
        }
    }

    /// Number of keys required for this template.
    pub fn required_keys(&self) -> usize {
        match self {
            PolicyTemplate::SingleSig => 1,
            PolicyTemplate::Multisig { total, .. } => *total,
            // Inheritance: threshold main keys + 1 backup
            PolicyTemplate::Inheritance { threshold, .. } => threshold + 2,
            // Treasury: HSM + CFO + leads (minimum 3 leads for 2-of-3)
            PolicyTemplate::CorporateTreasury { lead_threshold, .. } => 2 + lead_threshold + 1,
            PolicyTemplate::Recovery { .. } => 2,
            PolicyTemplate::Custom => 0,
        }
    }

    /// Labels for each key slot, describing the role of each key.
    pub fn key_labels(&self) -> Vec<String> {
        match self {
            PolicyTemplate::SingleSig => vec!["Primary Key".into()],
            PolicyTemplate::Multisig { total, .. } => {
                (1..=*total).map(|i| format!("Signer {}", i)).collect()
            }
            PolicyTemplate::Inheritance { threshold, .. } => {
                let mut labels: Vec<String> = (1..=*threshold + 1)
                    .map(|i| format!("Main Signer {}", i))
                    .collect();
                labels.push("Backup Key (delayed)".into());
                labels
            }
            PolicyTemplate::CorporateTreasury { lead_threshold, .. } => {
                let mut labels = vec!["HSM Key".into(), "CFO Key".into()];
                for i in 1..=*lead_threshold + 1 {
                    labels.push(format!("Lead {}", i));
                }
                labels
            }
            PolicyTemplate::Recovery { .. } => {
                vec!["Primary Key".into(), "Recovery Key (delayed)".into()]
            }
            PolicyTemplate::Custom => vec![],
        }
    }

    /// Returns default template instances for common use cases.
    pub fn default_inheritance() -> Self {
        PolicyTemplate::Inheritance {
            threshold: 2,
            delay_blocks: 26280, // ~6 months
        }
    }

    pub fn default_treasury() -> Self {
        PolicyTemplate::CorporateTreasury {
            lead_threshold: 2,
            delay_blocks: 1008, // ~7 days
        }
    }

    pub fn default_recovery() -> Self {
        PolicyTemplate::Recovery {
            delay_blocks: 12960, // ~90 days
        }
    }
}
