//! Typed error hierarchy for Templar Wallet.
//!
//! All public functions in templar-core return `Result<T, TemplarError>`.
//! The desktop frontend can convert these to `anyhow::Error` at the boundary.

use thiserror::Error;

/// Top-level error type for templar-core.
#[derive(Debug, Error)]
pub enum TemplarError {
    #[error(transparent)]
    Bitcoin(#[from] BitcoinError),

    #[error(transparent)]
    Liquid(#[from] LiquidError),

    #[error(transparent)]
    Storage(#[from] StorageError),

    #[error(transparent)]
    Hardware(#[from] HardwareError),

    #[error(transparent)]
    Policy(#[from] PolicyError),

    #[error(transparent)]
    Vault(#[from] VaultError),
}

/// At-rest encryption / vault errors (C1).
#[derive(Debug, Error)]
pub enum VaultError {
    #[error("Encryption failed: {0}")]
    EncryptionFailed(String),

    #[error("Decryption failed: {0}")]
    DecryptionFailed(String),

    #[error("Key derivation failed: {0}")]
    KeyDerivation(String),

    #[error("Wrong passphrase")]
    WrongPassphrase,

    #[error("Vault is locked — unlock with your passphrase first")]
    Locked,

    #[error("A vault already exists on this device")]
    AlreadyExists,

    #[error("Corrupt vault data: {0}")]
    Corrupt(String),
}

/// Bitcoin wallet errors (BDK 0.30).
#[derive(Debug, Error)]
pub enum BitcoinError {
    #[error("Invalid mnemonic: {0}")]
    InvalidMnemonic(String),

    #[error("Sync failed: {0}")]
    SyncFailed(String),

    #[error("Transaction build failed: {0}")]
    TxBuildFailed(String),

    #[error("Invalid descriptor: {0}")]
    InvalidDescriptor(String),

    #[error("PSBT error: {0}")]
    PsbtError(String),

    #[error("Signing failed: {0}")]
    SigningFailed(String),

    #[error("Broadcast failed: {0}")]
    BroadcastFailed(String),

    #[error("Wallet not available")]
    WalletNotAvailable,

    #[error("BDK panicked: {0}")]
    Panicked(String),

    #[error("Coin {0} is frozen. Unfreeze it on the UTXOs screen to spend it.")]
    FrozenCoin(String),
}

/// Liquid wallet errors (LWK 0.9).
#[derive(Debug, Error)]
pub enum LiquidError {
    #[error("Invalid descriptor: {0}")]
    InvalidDescriptor(String),

    #[error("Sync failed: {0}")]
    SyncFailed(String),

    #[error("PSET build failed: {0}")]
    PsetBuildFailed(String),

    #[error("PSET inspection failed: {0}")]
    PsetInspectionFailed(String),

    #[error("Signing failed: {0}")]
    SigningFailed(String),

    #[error("Finalization failed: {0}")]
    FinalizationFailed(String),

    #[error("Broadcast failed: {0}")]
    BroadcastFailed(String),

    #[error("Issuance failed: {0}")]
    IssuanceFailed(String),

    #[error("Reissuance failed: {0}")]
    ReissuanceFailed(String),

    #[error("Burn failed: {0}")]
    BurnFailed(String),

    /// The operation is not available in this build (e.g. Liquid signing on a
    /// hardware wallet). Distinct from a failure: retrying never helps.
    #[error("Unsupported: {0}")]
    Unsupported(String),

    /// A network name, policy asset or address that does not fit the
    /// selected Liquid network (testnet vs. regtest).
    #[error("Invalid Liquid network: {0}")]
    InvalidNetwork(String),

    /// Something that only exists on one network was asked for on another
    /// (the public asset registry or order book on a local regtest, a PSET
    /// carrying another chain's assets). Retrying never helps.
    #[error("Not available on {network}: {what}")]
    UnavailableOnNetwork { network: String, what: String },

    /// The wallet and the chain backend disagree on the network — the wallet
    /// has to be reopened after a network switch.
    #[error("Network mismatch: {0}")]
    NetworkMismatch(String),

    #[error("Coin {0} is frozen. Unfreeze it on the UTXOs screen to spend it.")]
    FrozenCoin(String),

    /// LWK 0.9 picks the inputs itself whenever a payment moves an asset
    /// other than L-BTC, so there a frozen coin cannot be left out — only
    /// refused.
    #[error(
        "This transaction would spend frozen coin {0}. A Liquid transaction that moves \
         an asset other than L-BTC cannot leave coins out yet: unfreeze it on the \
         UTXOs screen to send this."
    )]
    FrozenCoinUnavoidable(String),
}

/// Storage / persistence errors.
#[derive(Debug, Error)]
pub enum StorageError {
    #[error("I/O error: {0}")]
    IoError(#[from] std::io::Error),

    #[error("Serialization failed: {0}")]
    SerializationFailed(String),

    #[error("Registry corrupted: {0}")]
    RegistryCorrupted(String),
}

/// Hardware wallet errors (HWI).
#[derive(Debug, Error)]
pub enum HardwareError {
    #[error("Device not found")]
    DeviceNotFound,

    #[error("Connection failed: {0}")]
    ConnectionFailed(String),

    #[error("Signing failed: {0}")]
    SigningFailed(String),
}

/// Miniscript policy errors.
#[derive(Debug, Error)]
pub enum PolicyError {
    #[error("Invalid policy: {0}")]
    InvalidPolicy(String),

    #[error("Unsupported: {0}")]
    Unsupported(String),

    #[error("Compilation failed: {0}")]
    CompilationFailed(String),
}

/// Convenience alias for templar-core results.
pub type TemplarResult<T> = std::result::Result<T, TemplarError>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn templar_error_from_bitcoin_error() {
        let err: TemplarError = BitcoinError::WalletNotAvailable.into();
        assert!(matches!(err, TemplarError::Bitcoin(_)));
        assert!(err.to_string().contains("not available"));
    }

    #[test]
    fn templar_error_from_liquid_error() {
        let err: TemplarError = LiquidError::SyncFailed("timeout".into()).into();
        assert!(matches!(err, TemplarError::Liquid(_)));
        assert!(err.to_string().contains("timeout"));
    }

    #[test]
    fn templar_error_from_storage_error() {
        let io_err = std::io::Error::new(std::io::ErrorKind::NotFound, "file gone");
        let err: TemplarError = StorageError::IoError(io_err).into();
        assert!(matches!(err, TemplarError::Storage(_)));
    }

    #[test]
    fn templar_error_from_hardware_error() {
        let err: TemplarError = HardwareError::DeviceNotFound.into();
        assert!(matches!(err, TemplarError::Hardware(_)));
        assert!(err.to_string().contains("not found"));
    }

    #[test]
    fn templar_error_from_policy_error() {
        let err: TemplarError = PolicyError::CompilationFailed("bad script".into()).into();
        assert!(matches!(err, TemplarError::Policy(_)));
        assert!(err.to_string().contains("bad script"));
    }

    #[test]
    fn bitcoin_error_variants_display() {
        assert!(BitcoinError::InvalidMnemonic("bad".into())
            .to_string()
            .contains("bad"));
        assert!(BitcoinError::Panicked("RefCell".into())
            .to_string()
            .contains("RefCell"));
        assert!(BitcoinError::BroadcastFailed("net".into())
            .to_string()
            .contains("net"));
    }

    #[test]
    fn liquid_error_variants_display() {
        assert!(LiquidError::PsetBuildFailed("x".into())
            .to_string()
            .contains("x"));
        assert!(LiquidError::FinalizationFailed("y".into())
            .to_string()
            .contains("y"));
        assert!(LiquidError::PsetInspectionFailed("z".into())
            .to_string()
            .contains("z"));
    }

    #[test]
    fn storage_error_from_io_error() {
        let io_err = std::io::Error::new(std::io::ErrorKind::PermissionDenied, "denied");
        let storage_err = StorageError::from(io_err);
        assert!(matches!(storage_err, StorageError::IoError(_)));
        assert!(storage_err.to_string().contains("denied"));
    }

    #[test]
    fn templar_result_alias_works() {
        let ok: TemplarResult<u32> = Ok(42);
        assert!(matches!(ok, Ok(42)));
        let err: TemplarResult<u32> = Err(TemplarError::from(BitcoinError::WalletNotAvailable));
        assert!(err.is_err());
    }
}
