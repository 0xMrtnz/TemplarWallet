//! Liquid asset registry — known asset metadata for display and formatting.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::Path;

/// L-BTC asset ID on Liquid testnet.
pub const LBTC_ASSET_ID: &str = "144c654344aa716d6f3abcc1ca90e5641e4e2a7f633bc09fe3baf64585819a49";
/// L-USDT asset ID on Liquid testnet.
pub const LUSDT_ASSET_ID: &str = "b612eb46313a2cd6ebabd8b7a8eed5696e29898b87a43bff41c94f51acef9d73";

/// Result of an asset issuance or reissuance transaction.
#[derive(Debug, Clone)]
pub struct IssuanceResult {
    pub asset_id: String,
    pub token_id: Option<String>,
    pub txid: String,
    /// Whether the asset contract was successfully submitted to the Liquid registry.
    pub registry_registered: bool,
}

/// Local metadata for an asset issued or tracked by this wallet.
///
/// Stored in-memory with highest priority over registry lookups.
/// `is_reissuance_token` marks the secondary token created alongside an issuance.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AssetMetadata {
    pub asset_id: String,
    pub name: String,
    pub ticker: Option<String>,
    pub precision: u8,
    pub domain: Option<String>,
    pub is_reissuance_token: bool,
    pub parent_asset_id: Option<String>,
}

/// Tracking info for an asset issued by this wallet.
#[derive(Debug, Clone)]
pub struct IssuedAssetInfo {
    pub asset_id: String,
    pub token_id: Option<String>,
    pub name: String,
    pub ticker: String,
    pub precision: u8,
    pub initial_supply: u64,
    pub total_issued: u64,
    pub total_burned: u64,
}

impl IssuedAssetInfo {
    pub fn circulating(&self) -> u64 {
        self.total_issued.saturating_sub(self.total_burned)
    }
}

/// Metadata for a Liquid asset.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AssetInfo {
    pub asset_id: String,
    pub ticker: String,
    pub name: String,
    pub precision: u8,
}

impl AssetInfo {
    /// Formats a satoshi amount with the correct number of decimal places.
    pub fn format_amount(&self, satoshi: u64) -> String {
        let divisor = 10u64.pow(self.precision as u32);
        let whole = satoshi / divisor;
        let frac = satoshi % divisor;
        format!(
            "{}.{:0>width$}",
            whole,
            frac,
            width = self.precision as usize
        )
    }
}

/// Registry of known Liquid assets with their metadata.
///
/// Provides ticker resolution, amount formatting, and dynamic registration.
/// Local metadata (from issuances performed by this wallet) has highest priority
/// over the static known-assets map.
#[derive(Debug, Clone)]
pub struct AssetRegistry {
    assets: HashMap<String, AssetInfo>,
    pub issued: Vec<IssuedAssetInfo>,
    /// In-memory local metadata for assets issued by this wallet session.
    /// Checked before `assets` in all resolution paths.
    pub local_metadata: HashMap<String, AssetMetadata>,
}

impl AssetRegistry {
    /// Creates a registry pre-loaded with L-BTC and L-USDT (testnet).
    pub fn with_defaults() -> Self {
        let mut assets = HashMap::new();
        assets.insert(
            LBTC_ASSET_ID.to_string(),
            AssetInfo {
                asset_id: LBTC_ASSET_ID.to_string(),
                ticker: "L-BTC".to_string(),
                name: "Liquid Bitcoin".to_string(),
                precision: 8,
            },
        );
        assets.insert(
            LUSDT_ASSET_ID.to_string(),
            AssetInfo {
                asset_id: LUSDT_ASSET_ID.to_string(),
                ticker: "L-USDT".to_string(),
                name: "Liquid Tether USD".to_string(),
                precision: 8,
            },
        );
        Self {
            assets,
            issued: Vec::new(),
            local_metadata: HashMap::new(),
        }
    }

    /// Stores local metadata for an asset. Local metadata has priority over the
    /// known-assets map in all resolution paths.
    pub fn add_local_metadata(&mut self, meta: AssetMetadata) {
        eprintln!(
            "[Registry] Saving local metadata: asset={} name={} ticker={:?} is_reissuance={}",
            meta.asset_id, meta.name, meta.ticker, meta.is_reissuance_token
        );
        self.local_metadata.insert(meta.asset_id.clone(), meta);
    }

    /// Returns local metadata for an asset, if any.
    pub fn get_local_metadata(&self, asset_id: &str) -> Option<&AssetMetadata> {
        self.local_metadata.get(asset_id)
    }

    /// Clears all per-wallet local metadata. Call when switching wallets.
    pub fn clear_local_metadata(&mut self) {
        self.local_metadata.clear();
        self.issued.clear();
    }

    /// Registers a new asset or updates an existing one in the known-assets map.
    pub fn register(&mut self, info: AssetInfo) {
        self.assets.insert(info.asset_id.clone(), info);
    }

    /// Looks up asset info by ID (known-assets map only; does not check local_metadata).
    pub fn get(&self, asset_id: &str) -> Option<&AssetInfo> {
        self.assets.get(asset_id)
    }

    /// Resolves asset metadata, always returning a valid `AssetInfo`.
    ///
    /// Priority:
    /// 1. Local metadata (from this wallet's issuances)
    /// 2. Known assets (L-BTC, L-USDT, and any registered)
    /// 3. Fallback: ticker = first 8 hex chars, precision = 8
    pub fn resolve(&self, asset_id: &str) -> AssetInfo {
        // 1 — Local metadata has highest priority
        if let Some(meta) = self.local_metadata.get(asset_id) {
            let ticker = meta
                .ticker
                .clone()
                .unwrap_or_else(|| asset_id[..8.min(asset_id.len())].to_string());
            return AssetInfo {
                asset_id: asset_id.to_string(),
                ticker,
                name: meta.name.clone(),
                precision: meta.precision,
            };
        }
        // 2 — Known assets map
        if let Some(info) = self.assets.get(asset_id) {
            return info.clone();
        }
        // 3 — Synthesise fallback
        let short_len = 8.min(asset_id.len());
        let short = &asset_id[..short_len];
        AssetInfo {
            asset_id: asset_id.to_string(),
            ticker: short.to_string(),
            name: format!("Unknown ({})", short),
            precision: 8,
        }
    }

    /// Formats a satoshi amount for the given asset, using 8 decimals as fallback.
    pub fn format_amount(&self, satoshi: u64, asset_id: &str) -> String {
        // Check local_metadata first for precision
        if let Some(meta) = self.local_metadata.get(asset_id) {
            let divisor = 10u64.pow(meta.precision as u32);
            let whole = satoshi / divisor;
            let frac = satoshi % divisor;
            return format!(
                "{}.{:0>width$}",
                whole,
                frac,
                width = meta.precision as usize
            );
        }
        match self.assets.get(asset_id) {
            Some(info) => info.format_amount(satoshi),
            None => {
                let btc = satoshi as f64 / 1e8;
                format!("{:.8}", btc)
            }
        }
    }

    /// Formats `amount` for `asset_id` using the registry, falling back to
    /// 8-decimal formatting for unknown assets.
    pub fn format_amount_with_fallback(&self, asset_id: &str, amount: u64) -> String {
        self.format_amount(amount, asset_id)
    }

    /// Returns the ticker for an asset, checking local_metadata first.
    pub fn ticker<'a>(&'a self, asset_id: &'a str) -> &'a str {
        if let Some(meta) = self.local_metadata.get(asset_id) {
            if let Some(t) = &meta.ticker {
                return t.as_str();
            }
        }
        self.assets
            .get(asset_id)
            .map(|a| a.ticker.as_str())
            .unwrap_or(&asset_id[..8.min(asset_id.len())])
    }

    /// Returns the inner HashMap (for iteration/compatibility).
    pub fn as_map(&self) -> &HashMap<String, AssetInfo> {
        &self.assets
    }

    /// Finds an issued asset by ID.
    pub fn find_issued(&self, asset_id: &str) -> Option<&IssuedAssetInfo> {
        self.issued.iter().find(|i| i.asset_id == asset_id)
    }

    /// Finds an issued asset by ID (mutable).
    pub fn find_issued_mut(&mut self, asset_id: &str) -> Option<&mut IssuedAssetInfo> {
        self.issued.iter_mut().find(|i| i.asset_id == asset_id)
    }

    /// Registers a newly issued asset (adds to both known-assets map and issued list).
    pub fn register_issuance(&mut self, info: IssuedAssetInfo) {
        self.register(AssetInfo {
            asset_id: info.asset_id.clone(),
            ticker: info.ticker.clone(),
            name: info.name.clone(),
            precision: info.precision,
        });
        // Also store as local metadata so resolve() returns correct data
        self.add_local_metadata(AssetMetadata {
            asset_id: info.asset_id.clone(),
            name: info.name.clone(),
            ticker: Some(info.ticker.clone()),
            precision: info.precision,
            domain: None,
            is_reissuance_token: false,
            parent_asset_id: None,
        });
        self.issued.push(info);
    }
}

/// Persistent snapshot of the asset registry — local metadata + last known balances.
///
/// Saved to `{data_dir}/assets.json` on every successful Liquid sync so that
/// balances and asset names are visible immediately on next app launch without
/// requiring a full re-sync.
#[derive(Serialize, Deserialize, Default)]
pub struct CachedAssets {
    /// All non-default asset metadata (issuances, received tokens, registry fetches).
    pub local_metadata: Vec<AssetMetadata>,
    /// Last known balance per asset_id (satoshis).
    pub last_balance: HashMap<String, u64>,
}

impl AssetRegistry {
    /// Saves local metadata and last-known balance to a JSON file.
    /// Only writes when there is something non-trivial to persist.
    pub fn save_to_file(
        &self,
        path: &Path,
        balance: Option<&HashMap<String, u64>>,
    ) -> std::io::Result<()> {
        let cached = CachedAssets {
            local_metadata: self.local_metadata.values().cloned().collect(),
            last_balance: balance.cloned().unwrap_or_default(),
        };
        let json = serde_json::to_string_pretty(&cached).map_err(std::io::Error::other)?;
        std::fs::write(path, json)
    }

    /// Loads a cached registry from a JSON file.
    ///
    /// Returns `(registry, last_balance)`. The registry has `with_defaults()` pre-applied;
    /// the caller is responsible for applying `last_balance` to `LiquidState`.
    pub fn load_from_file(path: &Path) -> (Self, HashMap<String, u64>) {
        let mut registry = Self::with_defaults();
        if let Ok(json) = std::fs::read_to_string(path) {
            if let Ok(cached) = serde_json::from_str::<CachedAssets>(&json) {
                for meta in cached.local_metadata {
                    let ticker = meta
                        .ticker
                        .clone()
                        .unwrap_or_else(|| meta.asset_id[..8.min(meta.asset_id.len())].to_string());
                    registry.assets.insert(
                        meta.asset_id.clone(),
                        AssetInfo {
                            asset_id: meta.asset_id.clone(),
                            ticker,
                            name: meta.name.clone(),
                            precision: meta.precision,
                        },
                    );
                    registry.local_metadata.insert(meta.asset_id.clone(), meta);
                }
                return (registry, cached.last_balance);
            }
        }
        (registry, HashMap::new())
    }
}

/// Creates a HashMap of known assets (backward-compatible convenience function).
pub fn known_assets() -> HashMap<String, AssetInfo> {
    AssetRegistry::with_defaults().assets
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn asset_info_format_amount_8_decimals() {
        let info = AssetInfo {
            asset_id: "test".into(),
            ticker: "TST".into(),
            name: "Test".into(),
            precision: 8,
        };
        assert_eq!(info.format_amount(100_000_000), "1.00000000");
        assert_eq!(info.format_amount(50_000), "0.00050000");
        assert_eq!(info.format_amount(0), "0.00000000");
    }

    #[test]
    fn asset_info_format_amount_2_decimals() {
        let info = AssetInfo {
            asset_id: "usd".into(),
            ticker: "USD".into(),
            name: "Dollar".into(),
            precision: 2,
        };
        assert_eq!(info.format_amount(1050), "10.50");
        assert_eq!(info.format_amount(1), "0.01");
    }

    #[test]
    fn registry_defaults_has_lbtc_and_lusdt() {
        let reg = AssetRegistry::with_defaults();
        assert!(reg.get(LBTC_ASSET_ID).is_some());
        assert!(reg.get(LUSDT_ASSET_ID).is_some());
        assert_eq!(reg.ticker(LBTC_ASSET_ID), "L-BTC");
        assert_eq!(reg.ticker(LUSDT_ASSET_ID), "L-USDT");
    }

    #[test]
    fn registry_unknown_asset_fallback() {
        let reg = AssetRegistry::with_defaults();
        let unknown = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
        assert_eq!(reg.ticker(unknown), "abcdef01");
        let formatted = reg.format_amount(100_000_000, unknown);
        assert_eq!(formatted, "1.00000000");
    }

    #[test]
    fn registry_register_custom_asset() {
        let mut reg = AssetRegistry::with_defaults();
        let custom_id = "deadbeef".to_string();
        reg.register(AssetInfo {
            asset_id: custom_id.clone(),
            ticker: "CUSTOM".into(),
            name: "Custom Token".into(),
            precision: 6,
        });
        assert_eq!(reg.ticker(&custom_id), "CUSTOM");
        assert_eq!(reg.format_amount(1_000_000, &custom_id), "1.000000");
    }

    #[test]
    fn known_assets_convenience() {
        let map = known_assets();
        assert!(map.contains_key(LBTC_ASSET_ID));
        assert!(map.contains_key(LUSDT_ASSET_ID));
    }

    #[test]
    fn resolve_known_returns_registered_info() {
        let reg = AssetRegistry::with_defaults();
        let info = reg.resolve(LBTC_ASSET_ID);
        assert_eq!(info.ticker, "L-BTC");
        assert_eq!(info.precision, 8);
        assert_eq!(info.asset_id, LBTC_ASSET_ID);
    }

    #[test]
    fn resolve_unknown_synthesises_fallback() {
        let reg = AssetRegistry::with_defaults();
        let unknown = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
        let info = reg.resolve(unknown);
        assert_eq!(info.asset_id, unknown);
        assert_eq!(info.ticker, "abcdef01");
        assert_eq!(info.name, "Unknown (abcdef01)");
        assert_eq!(info.precision, 8);
        assert_eq!(info.format_amount(100_000_000), "1.00000000");
    }

    #[test]
    fn resolve_short_asset_id_does_not_panic() {
        let reg = AssetRegistry::with_defaults();
        let info = reg.resolve("abc");
        assert_eq!(info.ticker, "abc");
    }

    #[test]
    fn format_amount_with_fallback_known_and_unknown() {
        let reg = AssetRegistry::with_defaults();
        assert_eq!(
            reg.format_amount_with_fallback(LBTC_ASSET_ID, 100_000_000),
            "1.00000000"
        );
        let unknown = "deadbeef".repeat(8);
        assert_eq!(
            reg.format_amount_with_fallback(&unknown, 50_000),
            "0.00050000"
        );
    }

    #[test]
    fn local_metadata_has_priority_over_known_assets() {
        let mut reg = AssetRegistry::with_defaults();
        // Override L-BTC ticker with a custom local metadata entry
        reg.add_local_metadata(AssetMetadata {
            asset_id: LBTC_ASSET_ID.to_string(),
            name: "Custom BTC".into(),
            ticker: Some("CBTC".into()),
            precision: 8,
            domain: None,
            is_reissuance_token: false,
            parent_asset_id: None,
        });
        assert_eq!(reg.ticker(LBTC_ASSET_ID), "CBTC");
        let info = reg.resolve(LBTC_ASSET_ID);
        assert_eq!(info.name, "Custom BTC");
    }

    #[test]
    fn reissuance_token_flag_in_local_metadata() {
        let mut reg = AssetRegistry::with_defaults();
        let token_id = "aaabbbcccdddeeef".to_string();
        reg.add_local_metadata(AssetMetadata {
            asset_id: token_id.clone(),
            name: "MyToken Reissuance Token".into(),
            ticker: Some("MTK-RT".into()),
            precision: 0,
            domain: Some("example.com".into()),
            is_reissuance_token: true,
            parent_asset_id: Some("parentasset".into()),
        });
        let meta = reg.get_local_metadata(&token_id).unwrap();
        assert!(meta.is_reissuance_token);
        assert_eq!(meta.parent_asset_id.as_deref(), Some("parentasset"));
        let info = reg.resolve(&token_id);
        assert_eq!(info.ticker, "MTK-RT");
        assert_eq!(info.precision, 0);
    }
}
