//! Shared types used across Bitcoin and Liquid wallets.
//!
//! These types provide a unified interface for the UI layer,
//! abstracting over BDK and LWK specifics.

use serde::{Deserialize, Serialize};

/// Network the wallet operates on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Network {
    BitcoinTestnet,
    LiquidTestnet,
    /// A local Elements regtest (see [`crate::LiquidNetwork`]).
    LiquidRegtest,
}

impl Network {
    /// The Liquid side of a [`crate::LiquidNetwork`].
    pub fn from_liquid(network: &crate::LiquidNetwork) -> Self {
        if network.is_regtest() {
            Network::LiquidRegtest
        } else {
            Network::LiquidTestnet
        }
    }

    pub fn is_liquid(&self) -> bool {
        matches!(self, Network::LiquidTestnet | Network::LiquidRegtest)
    }
}

/// Sync status for a wallet.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SyncStatus {
    /// Never synced.
    NotSynced,
    /// Sync in progress.
    Syncing,
    /// Synced successfully. Contains the block height at sync time.
    Synced { tip_height: u32 },
    /// Sync failed with an error message.
    Failed { error: String },
}

impl SyncStatus {
    /// Returns true if the wallet has been synced at least once.
    pub fn is_synced(&self) -> bool {
        matches!(self, SyncStatus::Synced { .. })
    }

    /// Returns true if a sync is currently in progress.
    pub fn is_syncing(&self) -> bool {
        matches!(self, SyncStatus::Syncing)
    }
}

/// Unified transaction info for display in the UI.
///
/// Works for both Bitcoin (from `bdk::TransactionDetails`) and
/// Liquid (from `LiquidTx`) transactions.
#[derive(Debug, Clone)]
pub struct TxInfo {
    /// Transaction ID (hex).
    pub txid: String,
    /// Net amount change in satoshis (positive = received, negative = sent).
    /// For Liquid, this is the L-BTC delta only.
    pub amount_sat: i64,
    /// Fee in satoshis.
    pub fee_sat: u64,
    /// Block height (None = unconfirmed).
    pub block_height: Option<u32>,
    /// Timestamp as UNIX epoch seconds (None = unconfirmed or unavailable).
    pub timestamp: Option<u64>,
    /// Which network this transaction belongs to.
    pub network: Network,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sync_status_predicates() {
        assert!(!SyncStatus::NotSynced.is_synced());
        assert!(!SyncStatus::NotSynced.is_syncing());
        assert!(SyncStatus::Syncing.is_syncing());
        assert!(!SyncStatus::Syncing.is_synced());
        assert!(SyncStatus::Synced { tip_height: 100 }.is_synced());
        assert!(!SyncStatus::Failed {
            error: "err".into()
        }
        .is_synced());
    }

    #[test]
    fn tx_info_construction() {
        let tx = TxInfo {
            txid: "abc123".into(),
            amount_sat: -50_000,
            fee_sat: 250,
            block_height: Some(200_000),
            timestamp: Some(1700000000),
            network: Network::BitcoinTestnet,
        };
        assert_eq!(tx.amount_sat, -50_000);
        assert_eq!(tx.network, Network::BitcoinTestnet);
        assert!(!tx.network.is_liquid());
        assert_eq!(
            Network::from_liquid(&crate::LiquidNetwork::regtest_default()),
            Network::LiquidRegtest
        );
        assert!(Network::LiquidRegtest.is_liquid());
    }
}
