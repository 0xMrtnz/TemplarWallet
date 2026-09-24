//! Frozen coins — outpoints the user took out of circulation on the UTXO
//! screen.
//!
//! The list lives on the wallet's registry entry, so it is sealed with the
//! vault like everything else there, and it is enforced by the engine, not
//! by the screens: every transaction this wallet builds leaves frozen coins
//! out, and a PSBT or PSET that spends one is refused before it is signed.
//! A coin stays frozen until the user unfreezes it; the list is never pruned
//! behind their back (a wallet that has not synced yet would otherwise look
//! like it spent everything).

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

/// Which chain a frozen outpoint belongs to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CoinChain {
    Bitcoin,
    Liquid,
}

impl CoinChain {
    /// The chain names the app passes over FFI: `"BTC"` (or `"Bitcoin"`)
    /// and `"Liquid"`, in any case.
    pub fn parse(name: &str) -> Option<Self> {
        match name.to_ascii_lowercase().as_str() {
            "btc" | "bitcoin" => Some(Self::Bitcoin),
            "liquid" | "lbtc" | "l-btc" => Some(Self::Liquid),
            _ => None,
        }
    }
}

/// The frozen outpoints of one wallet, one set per chain, each entry in the
/// canonical `txid:vout` form (lowercase hex txid, decimal vout).
#[derive(Serialize, Deserialize, Debug, Clone, Default, PartialEq, Eq)]
pub struct FrozenCoins {
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    pub bitcoin: BTreeSet<String>,
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    pub liquid: BTreeSet<String>,
}

impl FrozenCoins {
    pub fn is_empty(&self) -> bool {
        self.bitcoin.is_empty() && self.liquid.is_empty()
    }

    /// The frozen set of `chain`.
    pub fn on(&self, chain: CoinChain) -> &BTreeSet<String> {
        match chain {
            CoinChain::Bitcoin => &self.bitcoin,
            CoinChain::Liquid => &self.liquid,
        }
    }

    /// Freezes (or unfreezes) `outpoints` on `chain`. Every outpoint is
    /// validated first, so a malformed one changes nothing.
    pub fn set(
        &mut self,
        chain: CoinChain,
        outpoints: &[String],
        frozen: bool,
    ) -> Result<(), String> {
        let canonical = outpoints
            .iter()
            .map(|op| canonical_outpoint(op).ok_or_else(|| format!("Invalid outpoint: {op}")))
            .collect::<Result<Vec<_>, _>>()?;
        let set = match chain {
            CoinChain::Bitcoin => &mut self.bitcoin,
            CoinChain::Liquid => &mut self.liquid,
        };
        for op in canonical {
            if frozen {
                set.insert(op);
            } else {
                set.remove(&op);
            }
        }
        Ok(())
    }
}

/// `txid:vout` in the form both BDK and LWK print an outpoint in, or `None`
/// when `raw` is not an outpoint at all.
pub fn canonical_outpoint(raw: &str) -> Option<String> {
    let (txid, vout) = raw.trim().rsplit_once(':')?;
    if txid.len() != 64 || !txid.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    let vout: u32 = vout.parse().ok()?;
    Some(format!("{}:{vout}", txid.to_ascii_lowercase()))
}

/// The first of `spent` (outpoints in `txid:vout` form) that is frozen.
pub fn first_frozen<I, S>(spent: I, frozen: &BTreeSet<String>) -> Option<String>
where
    I: IntoIterator<Item = S>,
    S: AsRef<str>,
{
    if frozen.is_empty() {
        return None;
    }
    spent
        .into_iter()
        .filter_map(|op| canonical_outpoint(op.as_ref()))
        .find(|op| frozen.contains(op))
}

#[cfg(test)]
mod tests {
    use super::*;

    const TXID: &str = "4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b";

    #[test]
    fn outpoints_are_stored_in_one_canonical_form() {
        let upper = format!("{}:1", TXID.to_ascii_uppercase());
        assert_eq!(canonical_outpoint(&upper), Some(format!("{TXID}:1")));
        assert_eq!(
            canonical_outpoint(&format!(" {TXID}:01 ")),
            Some(format!("{TXID}:1"))
        );
        assert_eq!(canonical_outpoint("nope"), None);
        assert_eq!(canonical_outpoint(&format!("{TXID}:x")), None);
        assert_eq!(canonical_outpoint("abcd:0"), None);
    }

    #[test]
    fn freezing_and_unfreezing_is_per_chain() {
        let mut coins = FrozenCoins::default();
        let op = format!("{TXID}:0");
        coins
            .set(CoinChain::Bitcoin, std::slice::from_ref(&op), true)
            .unwrap();
        assert!(coins.on(CoinChain::Bitcoin).contains(&op));
        assert!(coins.on(CoinChain::Liquid).is_empty());
        coins
            .set(CoinChain::Bitcoin, std::slice::from_ref(&op), false)
            .unwrap();
        assert!(coins.is_empty());
    }

    #[test]
    fn a_malformed_outpoint_changes_nothing() {
        let mut coins = FrozenCoins::default();
        let good = format!("{TXID}:0");
        let err = coins
            .set(CoinChain::Liquid, &[good, "garbage".into()], true)
            .unwrap_err();
        assert!(err.contains("garbage"), "{err}");
        assert!(coins.is_empty());
    }

    #[test]
    fn first_frozen_finds_the_spent_frozen_coin() {
        let mut coins = FrozenCoins::default();
        coins
            .set(CoinChain::Bitcoin, &[format!("{TXID}:2")], true)
            .unwrap();
        let spent = [
            format!("{TXID}:0"),
            format!("{}:2", TXID.to_ascii_uppercase()),
        ];
        assert_eq!(
            first_frozen(&spent, coins.on(CoinChain::Bitcoin)),
            Some(format!("{TXID}:2"))
        );
        assert_eq!(
            first_frozen(&spent[..1], coins.on(CoinChain::Bitcoin)),
            None
        );
    }

    #[test]
    fn an_old_registry_entry_without_the_field_still_loads() {
        let coins: FrozenCoins = serde_json::from_str("{}").unwrap();
        assert!(coins.is_empty());
        // Nothing frozen serializes to nothing, so untouched entries keep
        // their exact bytes.
        assert_eq!(serde_json::to_string(&coins).unwrap(), "{}");
    }
}
