//! Application configuration — global settings stored in `~/.config/templar_wallet.json`.

use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;

use crate::error::{StorageError, TemplarError};
use crate::liquid::network::LiquidNetwork;

/// Global application config, stored separately from wallet data.
///
/// Contains the pointer to the data directory, the last opened wallet ID and
/// the selected Liquid network.
#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct AppConfig {
    /// Base data directory (e.g. `~/.local/share/templar_wallet`).
    pub data_dir: PathBuf,
    /// ID of the last opened wallet (for auto-reopen).
    pub last_wallet_id: Option<String>,
    /// Liquid network the app runs on. `None` = testnet (the default, and
    /// what every config written before the setting existed means).
    /// `TEMPLAR_LIQUID_NETWORK` overrides it at runtime without touching it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub liquid_network: Option<LiquidNetwork>,
}

impl AppConfig {
    /// Loads the config from `~/.config/templar_wallet.json`.
    pub fn load() -> Option<Self> {
        Self::load_from(&Self::config_path())
    }

    /// Loads the config at `path`.
    pub fn load_from(path: &std::path::Path) -> Option<Self> {
        let content = fs::read_to_string(path).ok()?;
        serde_json::from_str(&content).ok()
    }

    /// Saves the config to `~/.config/templar_wallet.json`.
    pub fn save(&self) -> Result<(), TemplarError> {
        self.save_to(&Self::config_path())
    }

    /// Saves the config to `path` (directories created as needed).
    pub fn save_to(&self, path: &std::path::Path) -> Result<(), TemplarError> {
        if let Some(p) = path.parent() {
            fs::create_dir_all(p).map_err(StorageError::IoError)?;
        }
        let json = serde_json::to_string_pretty(self)
            .map_err(|e| StorageError::SerializationFailed(e.to_string()))?;
        fs::write(path, json).map_err(StorageError::IoError)?;
        Ok(())
    }

    /// Returns the config file path: `~/.config/templar_wallet.json`.
    pub fn config_path() -> PathBuf {
        dirs_next::config_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("templar_wallet.json")
    }

    /// The persisted Liquid network, testnet when unset.
    pub fn liquid_network(&self) -> LiquidNetwork {
        self.liquid_network.clone().unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn app_config_serialization_roundtrip() {
        let config = AppConfig {
            data_dir: PathBuf::from("/tmp/templar_test"),
            last_wallet_id: Some("wallet-123".into()),
            liquid_network: None,
        };
        let json = serde_json::to_string(&config).unwrap();
        let parsed: AppConfig = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.data_dir, PathBuf::from("/tmp/templar_test"));
        assert_eq!(parsed.last_wallet_id.as_deref(), Some("wallet-123"));
    }

    #[test]
    fn app_config_serialization_no_wallet_id() {
        let config = AppConfig {
            data_dir: PathBuf::from("/tmp/test"),
            last_wallet_id: None,
            liquid_network: None,
        };
        let json = serde_json::to_string(&config).unwrap();
        let parsed: AppConfig = serde_json::from_str(&json).unwrap();
        assert!(parsed.last_wallet_id.is_none());
    }

    #[test]
    fn liquid_network_defaults_to_testnet_and_round_trips() {
        // A config written before the setting existed.
        let old: AppConfig =
            serde_json::from_str(r#"{"data_dir":"/tmp/x","last_wallet_id":null}"#).unwrap();
        assert_eq!(old.liquid_network(), LiquidNetwork::testnet());
        // Unset stays absent on disk, so older builds keep parsing the file.
        assert!(!serde_json::to_string(&old)
            .unwrap()
            .contains("liquid_network"));

        let cfg = AppConfig {
            data_dir: PathBuf::from("/tmp/x"),
            last_wallet_id: None,
            liquid_network: Some(LiquidNetwork::regtest_default()),
        };
        let json = serde_json::to_string(&cfg).unwrap();
        assert!(json.contains("liquid-regtest"), "{json}");
        let back: AppConfig = serde_json::from_str(&json).unwrap();
        assert_eq!(back.liquid_network(), LiquidNetwork::regtest_default());
    }

    #[test]
    fn config_path_is_not_empty() {
        let path = AppConfig::config_path();
        assert!(!path.as_os_str().is_empty());
        assert!(path.to_string_lossy().contains("templar_wallet"));
    }

    #[test]
    fn app_config_save_and_load_tempdir() {
        // Save to a temp dir and verify roundtrip
        let tmpdir =
            std::env::temp_dir().join(format!("templar_config_test_{}", std::process::id()));
        let _ = std::fs::create_dir_all(&tmpdir);
        let config = AppConfig {
            data_dir: tmpdir.clone(),
            last_wallet_id: Some("test-id".into()),
            liquid_network: None,
        };
        // We can't override config_path easily, but we can test serialization
        let json = serde_json::to_string_pretty(&config).unwrap();
        let path = tmpdir.join("config_test.json");
        std::fs::write(&path, &json).unwrap();
        let loaded: AppConfig =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(loaded.data_dir, tmpdir);
        assert_eq!(loaded.last_wallet_id.as_deref(), Some("test-id"));
        let _ = std::fs::remove_dir_all(&tmpdir);
    }
}
