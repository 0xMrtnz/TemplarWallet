//! Recovery-phrase backup verification.
//!
//! # Why re-entry and not a quiz
//!
//! The old check asked for four random word positions out of a phrase the app
//! was holding anyway. That proves the user can read a screen. It cannot catch
//! the two failures that actually lose coins — a word written in the wrong
//! position, and a phrase that was never the wallet's phrase at all — and it is
//! impossible for a hardware or air-gap wallet, where the app never sees the
//! seed and where a bad backup is unrecoverable by definition.
//!
//! So the user types the whole phrase off their paper and the engine derives
//! public keys from it and compares them with the ones this wallet already
//! uses. Properties that fall out of doing it that way:
//!
//!   * Nothing secret is revealed or returned. The comparison runs on public
//!     keys; a wrong phrase produces a wrong xpub and nothing else.
//!   * It works for every wallet type, because the reference material is the
//!     stored descriptor, not a stored seed.
//!   * A single transposed word fails, because the derived key depends on the
//!     entire phrase.
//!
//! # What "matched" means
//!
//! The phrase derives the same account key this wallet spends from — so
//! restoring from that paper reproduces this wallet. It does *not* prove the
//! paper is legible, in a safe place, or free of a BIP39 passphrase added on a
//! hardware device (that would derive a different key, and correctly fails).

use serde::Serialize;
use templar_core::{account_xpub_bip84, keyorigin_xpub_bip48, validate_mnemonic};

use crate::handlers::bitcoin::get_wallet_info;
use crate::state::AppFfiState;

#[derive(Debug, Serialize)]
pub struct VerifyBackupDto {
    /// The phrase reproduces this wallet.
    pub matched: bool,
    /// `ok` | `checksum` | `mismatch` | `no_reference`.
    pub reason: String,
    /// Master fingerprint the typed phrase derives to. Public, and the useful
    /// thing to show on a failure: it tells a user with several backups which
    /// wallet they are actually holding.
    pub derived_fingerprint: String,
    /// Master fingerprint this wallet expects (may be empty for some profiles).
    pub expected_fingerprint: String,
    /// Fingerprints agree. Reported on its own because it is 4 bytes: a match
    /// here with no key match is a collision or a different account, never
    /// grounds for calling the backup good.
    pub fingerprint_match: bool,
}

/// Normalizes user typing: BIP39 words are lowercase, single-space separated.
/// Users paste from notes apps that add line breaks, numbering and NBSPs.
fn normalize(input: &str) -> String {
    input
        .split_whitespace()
        .map(|w| {
            w.trim_matches(|c: char| !c.is_ascii_alphabetic())
                .to_ascii_lowercase()
        })
        .filter(|w| !w.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

/// Verify a typed recovery phrase against the wallet's stored public keys.
pub fn verify_backup(
    state: &AppFfiState,
    wallet_id: &str,
    mnemonic: &str,
) -> Result<VerifyBackupDto, String> {
    let info = get_wallet_info(state, wallet_id)?;
    let phrase = normalize(mnemonic);

    // A checksum failure is a verification result, not an error: it is exactly
    // what a mistyped or mis-ordered phrase looks like, and the UI should show
    // it in the same card as any other failure rather than as a crash.
    if validate_mnemonic(&phrase).is_err() {
        return Ok(VerifyBackupDto {
            matched: false,
            reason: "checksum".into(),
            derived_fingerprint: String::new(),
            expected_fingerprint: info.master_fingerprint,
            fingerprint_match: false,
        });
    }

    let (derived_fp, xpub84) = account_xpub_bip84(&phrase).map_err(|e| e.to_string())?;
    // Multisig cosigners are BIP48 keys, so a singlesig-only comparison would
    // fail every multisig wallet. Derive both accounts and accept either.
    let xpub48 = keyorigin_xpub_bip48(&phrase)
        .ok()
        .and_then(|ko| ko.rsplit(']').next().map(str::to_string))
        .unwrap_or_default();

    // Every public place this wallet's keys are recorded. Descriptors already
    // come back stripped to their public form (`public_descriptor`), so no
    // private material is read here.
    let mut reference = String::new();
    for part in [
        info.xpub.as_str(),
        info.receive_descriptor.as_str(),
        info.change_descriptor.as_str(),
        info.multipath_descriptor.as_deref().unwrap_or(""),
        info.liquid_descriptor.as_deref().unwrap_or(""),
    ] {
        reference.push_str(part);
        reference.push(' ');
    }
    for key in &info.cosigner_keys {
        reference.push_str(key);
        reference.push(' ');
    }

    let key_match = (!xpub84.is_empty() && reference.contains(&xpub84))
        || (!xpub48.is_empty() && reference.contains(&xpub48));
    let fingerprint_match = !info.master_fingerprint.is_empty()
        && info.master_fingerprint.eq_ignore_ascii_case(&derived_fp);

    // A wallet with no extended key on record anywhere (nothing to compare a
    // derivation against) must not be reported as verified on a 4-byte
    // fingerprint alone — say so instead.
    let has_reference = reference.contains("pub");
    let reason = if key_match {
        "ok"
    } else if !has_reference {
        "no_reference"
    } else {
        "mismatch"
    };

    Ok(VerifyBackupDto {
        matched: key_match,
        reason: reason.into(),
        derived_fingerprint: derived_fp,
        expected_fingerprint: info.master_fingerprint,
        fingerprint_match,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_strips_numbering_and_case() {
        assert_eq!(
            normalize("1. Bench\n2. ORDINARY\t3.runway"),
            "bench ordinary runway"
        );
    }

    #[test]
    fn normalize_collapses_padding() {
        assert_eq!(normalize("  abandon   ABANDON  "), "abandon abandon");
    }
}
