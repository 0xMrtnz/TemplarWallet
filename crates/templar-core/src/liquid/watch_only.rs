//! Watch-only Liquid wallet from CT descriptor.
//!
//! Provides a convenience constructor that delegates to
//! `LiquidWalletManager::watch_only()`. Watch-only wallets can
//! sync, display balances, generate addresses, and inspect PSETs,
//! but cannot sign transactions.

use crate::error::{LiquidError, TemplarError};
use crate::liquid::wallet::LiquidWalletManager;

/// Cleans and validates a CT descriptor for watch-only import, returning the
/// canonical string to persist.
///
/// Strips paste artifacts (whitespace/newlines) and fails fast with a
/// descriptive error when LWK cannot parse the descriptor. Without this
/// check a malformed descriptor is stored as-is and only discovered — and
/// silently swallowed — when the wallet is next opened, which surfaces as a
/// zero Liquid balance with no error.
pub fn validate_ct_descriptor(raw: &str) -> Result<String, TemplarError> {
    let input: String = raw.split_whitespace().collect();
    if input.is_empty() {
        return Err(LiquidError::InvalidDescriptor("Empty Liquid descriptor".into()).into());
    }
    if !input.starts_with("ct(") {
        return Err(LiquidError::InvalidDescriptor(
            "Liquid descriptor must be confidential — expected ct(<blinding-key>,el…(…)). \
             Check that the beginning of the descriptor was not cut off when copying."
                .into(),
        )
        .into());
    }
    input.parse::<lwk_wollet::WolletDescriptor>().map_err(|e| {
        LiquidError::InvalidDescriptor(format!("Invalid Liquid CT descriptor: {e}"))
    })?;
    Ok(input)
}

/// Creates a watch-only Liquid wallet from a CT descriptor string.
///
/// The descriptor should be a full CT descriptor, e.g.:
/// `ct(slip77(KEY),elwpkh([fp/path]xpub/<0;1>/*))`
///
/// Watch-only wallets can:
/// - Sync with the Electrum server
/// - Display balances and transaction history
/// - Generate receive addresses
/// - Inspect PSETs (show fee, recipients, signer status)
///
/// Watch-only wallets cannot:
/// - Sign transactions (will return an error)
pub fn create_watch_only(descriptor: &str) -> Result<LiquidWalletManager, TemplarError> {
    LiquidWalletManager::watch_only(descriptor)
}

#[cfg(test)]
mod tests {
    use super::*;

    const CT_DESC: &str = "ct(slip77(addfe14f6d96eb091712439190737b901b6b5558d7039ed1d0dd19a7305cb747),elwpkh([f0b68896/84'/1'/0']tpubDCVwWj4hEpeWNFcWe3Eo1DrkLnPC4c2iitjw5wAuTkSZgofJbRMD4KESh1uhsqLCCjcjR36JooEFwfWf1ezwmAfjcPCxc7KNtnfBCrMPdtT/<0;1>/*))#83yagts9";

    #[test]
    fn validate_accepts_full_ct_descriptor() {
        let cleaned = validate_ct_descriptor(CT_DESC).unwrap();
        assert_eq!(cleaned, CT_DESC);
    }

    #[test]
    fn validate_collapses_pasted_whitespace() {
        let with_newline = CT_DESC.replace("),elwpkh", "),\n  elwpkh");
        assert_eq!(validate_ct_descriptor(&with_newline).unwrap(), CT_DESC);
    }

    #[test]
    fn validate_rejects_truncated_descriptor() {
        // The exact failure shape from the field: the leading `ct(slip77(…`
        // was cut off during a manual copy.
        let truncated = &CT_DESC[62..];
        let err = validate_ct_descriptor(truncated).unwrap_err();
        assert!(err.to_string().contains("cut off"), "got: {err}");
    }

    #[test]
    fn validate_rejects_non_ct_and_garbage() {
        assert!(validate_ct_descriptor("elwpkh(tpubDCVwWj4hEpeW/<0;1>/*)").is_err());
        assert!(validate_ct_descriptor("ct(slip77(zz),elwpkh(bad))").is_err());
        assert!(validate_ct_descriptor("").is_err());
    }
}
