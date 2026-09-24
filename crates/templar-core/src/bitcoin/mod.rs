//! Bitcoin wallet engine — BDK 0.30 singlesig, multisig, hardware, and Miniscript wallets.

#[cfg(feature = "hardware")]
pub mod device;
#[cfg(feature = "hardware")]
pub mod hardware;
pub mod multisig;
pub mod psbt;
pub mod wallet;
pub mod watch_only;
