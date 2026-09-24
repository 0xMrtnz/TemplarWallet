//! Which Liquid network the wallet runs on: the public testnet or a local
//! Elements regtest (`elementsd -chain=liquidregtest`).
//!
//! Mainnet is deliberately absent — this wallet has no mainnet spending path.
//!
//! The value is a plain setting: templar-core never keeps a process-wide
//! "current network". Callers pass it explicitly (the `*_on` constructors of
//! [`crate::LiquidWalletManager`], `verify_proposal_on`, …) or fall back to
//! [`LiquidNetwork::from_env`], which reads `TEMPLAR_LIQUID_NETWORK` and
//! defaults to testnet — so existing callers that never mention a network
//! keep their testnet behaviour unchanged.

use std::fmt;

use lwk_wollet::elements::{Address, AddressParams, AssetId};
use lwk_wollet::ElementsNetwork;
use serde::{Deserialize, Serialize};

use crate::error::{LiquidError, TemplarError};

/// L-BTC asset id on Liquid testnet (the policy asset).
pub const TESTNET_POLICY_ASSET: &str =
    "144c654344aa716d6f3abcc1ca90e5641e4e2a7f633bc09fe3baf64585819a49";

/// Policy asset of a stock `elementsd -chain=liquidregtest` node — the kind
/// the Templar Protocol runs locally.
pub const REGTEST_DEFAULT_POLICY_ASSET: &str =
    "5ac9f65c0efcc4775e0baec4ec03abdde22473cd3cf33c0419ca290e0751b225";

/// Environment override for the network: `testnet` | `regtest`
/// (`liquid-testnet` / `liquid-regtest` also accepted).
pub const ENV_NETWORK: &str = "TEMPLAR_LIQUID_NETWORK";
/// Environment override for the regtest policy asset id (hex).
pub const ENV_REGTEST_POLICY_ASSET: &str = "TEMPLAR_LIQUID_REGTEST_POLICY_ASSET";

/// The Liquid network a wallet, PSET or swap lives on.
///
/// Serialized in the same tagged form the Templar Protocol's connector uses
/// (`{"kind":"liquid-regtest","policy_asset":"…"}`), so the two sides can
/// exchange the value verbatim.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum LiquidNetwork {
    /// Public Liquid testnet (Blockstream Electrum, faucets, ~1 min blocks).
    #[default]
    LiquidTestnet,
    /// A local Elements regtest chain. Its policy asset depends on the
    /// node's genesis block, so it travels with the variant.
    LiquidRegtest { policy_asset: String },
}

impl LiquidNetwork {
    /// Public Liquid testnet.
    pub const fn testnet() -> Self {
        LiquidNetwork::LiquidTestnet
    }

    /// Regtest with the stock `liquidregtest` policy asset.
    pub fn regtest_default() -> Self {
        LiquidNetwork::LiquidRegtest {
            policy_asset: REGTEST_DEFAULT_POLICY_ASSET.to_string(),
        }
    }

    /// Regtest with an explicit policy asset (validated).
    pub fn regtest(policy_asset: &str) -> Result<Self, TemplarError> {
        let policy_asset = policy_asset.trim();
        if policy_asset.is_empty() {
            return Ok(Self::regtest_default());
        }
        policy_asset.parse::<AssetId>().map_err(|e| {
            LiquidError::InvalidNetwork(format!("regtest policy asset {policy_asset:?}: {e}"))
        })?;
        Ok(LiquidNetwork::LiquidRegtest {
            policy_asset: policy_asset.to_string(),
        })
    }

    /// Parses `testnet` / `liquid-testnet` / `regtest` / `liquid-regtest`.
    /// `regtest_policy_asset` only applies to regtest (empty = stock id).
    pub fn parse(name: &str, regtest_policy_asset: Option<&str>) -> Result<Self, TemplarError> {
        match name.trim().to_ascii_lowercase().as_str() {
            "liquid-testnet" | "testnet" => Ok(Self::testnet()),
            "liquid-regtest" | "regtest" => Self::regtest(regtest_policy_asset.unwrap_or("")),
            other => Err(LiquidError::InvalidNetwork(format!(
                "unknown Liquid network {other:?} (expected testnet or regtest)"
            ))
            .into()),
        }
    }

    /// The network named by the environment (`TEMPLAR_LIQUID_NETWORK`,
    /// optionally `TEMPLAR_LIQUID_REGTEST_POLICY_ASSET`), or `None` when the
    /// variable is unset or empty. An unparsable value is reported, not
    /// silently ignored: a typo must not quietly land the user on testnet.
    pub fn from_env_override() -> Result<Option<Self>, TemplarError> {
        let Some(name) = env_non_empty(ENV_NETWORK) else {
            return Ok(None);
        };
        let policy = env_non_empty(ENV_REGTEST_POLICY_ASSET);
        Self::parse(&name, policy.as_deref()).map(Some)
    }

    /// The environment's network, or testnet. Bad values fall back to
    /// testnet with a log line — this is the compatibility default used by
    /// the constructors that take no network argument.
    pub fn from_env() -> Self {
        match Self::from_env_override() {
            Ok(Some(n)) => n,
            Ok(None) => Self::testnet(),
            Err(e) => {
                eprintln!("[liquid] {ENV_NETWORK}: {e}; using testnet");
                Self::testnet()
            }
        }
    }

    /// Canonical name, the value exchanged in the connector protocol:
    /// `liquid-testnet` | `liquid-regtest`.
    pub fn name(&self) -> &'static str {
        match self {
            LiquidNetwork::LiquidTestnet => "liquid-testnet",
            LiquidNetwork::LiquidRegtest { .. } => "liquid-regtest",
        }
    }

    /// Short human label: `testnet` | `regtest`.
    pub fn short_name(&self) -> &'static str {
        match self {
            LiquidNetwork::LiquidTestnet => "testnet",
            LiquidNetwork::LiquidRegtest { .. } => "regtest",
        }
    }

    pub fn is_regtest(&self) -> bool {
        matches!(self, LiquidNetwork::LiquidRegtest { .. })
    }

    /// The LWK network value.
    pub fn elements(&self) -> ElementsNetwork {
        match self {
            LiquidNetwork::LiquidTestnet => ElementsNetwork::LiquidTestnet,
            LiquidNetwork::LiquidRegtest { policy_asset } => ElementsNetwork::ElementsRegtest {
                policy_asset: policy_asset
                    .parse()
                    .expect("policy asset validated at construction"),
            },
        }
    }

    /// Maps an LWK network back. Mainnet has no counterpart here.
    pub fn from_elements(network: ElementsNetwork) -> Result<Self, TemplarError> {
        match network {
            ElementsNetwork::LiquidTestnet => Ok(Self::testnet()),
            ElementsNetwork::ElementsRegtest { policy_asset } => Ok(LiquidNetwork::LiquidRegtest {
                policy_asset: policy_asset.to_string(),
            }),
            ElementsNetwork::Liquid => Err(LiquidError::InvalidNetwork(
                "Liquid mainnet is not supported by this wallet".into(),
            )
            .into()),
        }
    }

    /// L-BTC asset id of this network.
    pub fn policy_asset(&self) -> AssetId {
        self.elements().policy_asset()
    }

    /// L-BTC asset id, hex.
    pub fn policy_asset_hex(&self) -> String {
        match self {
            LiquidNetwork::LiquidTestnet => TESTNET_POLICY_ASSET.to_string(),
            LiquidNetwork::LiquidRegtest { policy_asset } => policy_asset.clone(),
        }
    }

    /// Whether `asset_id` (hex) is this network's L-BTC.
    pub fn is_policy_asset(&self, asset_id: &str) -> bool {
        asset_id.eq_ignore_ascii_case(&self.policy_asset_hex())
    }

    pub fn address_params(&self) -> &'static AddressParams {
        self.elements().address_params()
    }

    /// Parses an address and checks it belongs to this network.
    pub fn parse_address(&self, s: &str) -> Result<Address, TemplarError> {
        Address::parse_with_params(s.trim(), self.address_params()).map_err(|e| {
            LiquidError::InvalidNetwork(format!(
                "{s:?} is not a {} address: {e}",
                self.short_name()
            ))
            .into()
        })
    }

    /// Ticker of the policy asset for display.
    pub fn policy_ticker(&self) -> &'static str {
        match self {
            LiquidNetwork::LiquidTestnet => "tL-BTC",
            LiquidNetwork::LiquidRegtest { .. } => "rL-BTC",
        }
    }

    /// The Jade firmware's name for this network.
    #[cfg(feature = "hardware")]
    pub fn jade_network(&self) -> lwk_jade::Network {
        match self {
            LiquidNetwork::LiquidTestnet => lwk_jade::Network::TestnetLiquid,
            LiquidNetwork::LiquidRegtest { .. } => lwk_jade::Network::LocaltestLiquid,
        }
    }
}

impl fmt::Display for LiquidNetwork {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.name())
    }
}

/// A non-empty, trimmed environment variable.
pub(crate) fn env_non_empty(name: &str) -> Option<String> {
    std::env::var(name)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_names_and_defaults() {
        assert_eq!(
            LiquidNetwork::parse("testnet", None).unwrap(),
            LiquidNetwork::testnet()
        );
        assert_eq!(
            LiquidNetwork::parse("Liquid-Regtest", None).unwrap(),
            LiquidNetwork::regtest_default()
        );
        let custom = LiquidNetwork::parse("regtest", Some(TESTNET_POLICY_ASSET)).unwrap();
        assert_eq!(custom.policy_asset_hex(), TESTNET_POLICY_ASSET);
        assert!(LiquidNetwork::parse("mainnet", None).is_err());
        assert!(LiquidNetwork::parse("liquid", None).is_err());
        assert!(LiquidNetwork::parse("regtest", Some("zz")).is_err());
        // Empty policy asset means "the stock one".
        assert_eq!(
            LiquidNetwork::parse("regtest", Some("  ")).unwrap(),
            LiquidNetwork::regtest_default()
        );
    }

    #[test]
    fn network_facts() {
        let t = LiquidNetwork::testnet();
        assert_eq!(t.name(), "liquid-testnet");
        assert_eq!(t.policy_asset().to_string(), TESTNET_POLICY_ASSET);
        assert!(t.is_policy_asset(&TESTNET_POLICY_ASSET.to_uppercase()));
        assert!(!t.is_regtest());
        assert_eq!(t.elements(), ElementsNetwork::LiquidTestnet);
        assert_eq!(t.elements().as_str(), "liquid-testnet");
        assert!(t
            .parse_address("tlq1qq2xvpcvfup5j8zscjq05u2wxxjcyewk7979f3mmz5l7uw5pqmx6xf5xy50hsn6vhkm5euwt72x878eq6zxx2z58hd7zrsg9qn")
            .is_ok());

        let r = LiquidNetwork::regtest_default();
        assert_eq!(r.name(), "liquid-regtest");
        assert!(r.is_regtest());
        assert_eq!(r.policy_asset().to_string(), REGTEST_DEFAULT_POLICY_ASSET);
        assert_eq!(r.elements(), ElementsNetwork::default_regtest());
        assert_eq!(r.elements().as_str(), "liquid-regtest");
        // A testnet address is not a regtest address.
        assert!(r
            .parse_address("tlq1qq2xvpcvfup5j8zscjq05u2wxxjcyewk7979f3mmz5l7uw5pqmx6xf5xy50hsn6vhkm5euwt72x878eq6zxx2z58hd7zrsg9qn")
            .is_err());
        #[cfg(feature = "hardware")]
        assert_eq!(r.jade_network(), lwk_jade::Network::LocaltestLiquid);
    }

    #[test]
    fn elements_round_trip_refuses_mainnet() {
        for n in [LiquidNetwork::testnet(), LiquidNetwork::regtest_default()] {
            assert_eq!(LiquidNetwork::from_elements(n.elements()).unwrap(), n);
        }
        assert!(LiquidNetwork::from_elements(ElementsNetwork::Liquid).is_err());
    }

    #[test]
    fn serde_is_tagged_like_the_protocol() {
        let r = LiquidNetwork::regtest_default();
        let json = serde_json::to_string(&r).unwrap();
        assert!(json.contains("\"kind\":\"liquid-regtest\""), "{json}");
        assert_eq!(serde_json::from_str::<LiquidNetwork>(&json).unwrap(), r);
        assert_eq!(
            serde_json::to_string(&LiquidNetwork::testnet()).unwrap(),
            r#"{"kind":"liquid-testnet"}"#
        );
    }
}
