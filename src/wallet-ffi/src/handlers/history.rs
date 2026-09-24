//! Balance history — the native-coin (BTC + L-BTC) balance curve behind the
//! Home portfolio chart.
//!
//! There is no stored balance timeline in either engine, so the series is
//! reconstructed by walking the wallet's transaction history. Two rules make
//! the result trustworthy rather than merely plausible:
//!   - the walk starts from `current - sum(deltas)`, so a truncated history
//!     (pruned cache, gap-limit miss) still lands on the real balance;
//!   - the final point is pinned to the wallet's live balance, which is the
//!     only number the user can verify elsewhere in the app.

use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::state::AppFfiState;

// ── DTOs (wire shapes fixed by the FFI contract) ─────────────────────────────

/// Cumulative native-coin balance *after* one transaction event.
#[derive(Serialize, Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
pub struct HistoryPointDto {
    /// Unix seconds.
    pub ts: i64,
    pub btc_sats: i64,
    pub lbtc_sats: i64,
}

#[derive(Serialize, Debug, Clone)]
pub struct BalanceHistoryDto {
    /// Ascending by `ts`, one point per distinct timestamp.
    pub points: Vec<HistoryPointDto>,
    /// Current balances — the values the last point is pinned to.
    pub btc_sats: i64,
    pub lbtc_sats: i64,
    /// Whether that chain exists on this wallet (the UI hides the chain
    /// filter for an absent chain).
    pub has_bitcoin: bool,
    pub has_liquid: bool,
}

// ── Params (deserialized by dispatch.rs) ─────────────────────────────────────

#[derive(Deserialize, Debug)]
pub struct BalanceHistoryParams {
    pub wallet_id: String,
}

/// One transaction's effect on the two native balances.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BalanceEvent {
    /// Unix seconds; `0` for an unconfirmed tx (both engines report no time).
    pub ts: i64,
    pub btc_delta: i64,
    pub lbtc_delta: i64,
}

// ── Handler ──────────────────────────────────────────────────────────────────

pub fn get_balance_history(state: &AppFfiState) -> Result<BalanceHistoryDto, String> {
    let mut events: Vec<BalanceEvent> = Vec::new();
    let mut current_btc: i64 = 0;
    let mut current_lbtc: i64 = 0;

    if let Some(btc) = &state.bitcoin {
        // A failed balance read is fatal here: the whole series is anchored to
        // this number, and defaulting to 0 would draw a chart that ends at zero.
        let bal = btc.get_balance().map_err(|e| e.to_string())?;
        current_btc = (bal.confirmed + bal.untrusted_pending + bal.trusted_pending) as i64;
        // A failed tx listing is not fatal: the base absorbs the missing
        // deltas, so the wallet shows a flat line at its real balance.
        if let Ok(txs) = btc.list_transactions() {
            for tx in txs {
                let delta = tx.received as i64 - tx.sent as i64;
                if delta == 0 {
                    continue;
                }
                events.push(BalanceEvent {
                    ts: tx
                        .confirmation_time
                        .as_ref()
                        .map(|c| c.timestamp as i64)
                        .unwrap_or(0),
                    btc_delta: delta,
                    lbtc_delta: 0,
                });
            }
        }
    }

    if let Some(liq) = &state.liquid {
        let bal = liq.get_balance().map_err(|e| e.to_string())?;
        current_lbtc = bal.lbtc() as i64;
        if let Ok(txs) = liq.list_transactions() {
            for tx in txs {
                // Native coin only — other Liquid assets have no price feed
                // and are excluded from the net-worth headline too.
                let delta = tx.balance.get(bal.policy_asset_id()).copied().unwrap_or(0);
                if delta == 0 {
                    continue;
                }
                events.push(BalanceEvent {
                    ts: tx.timestamp.map(|t| t as i64).unwrap_or(0),
                    btc_delta: 0,
                    lbtc_delta: delta,
                });
            }
        }
    }

    Ok(BalanceHistoryDto {
        points: build_points(events, current_btc, current_lbtc, now_unix()),
        btc_sats: current_btc.max(0),
        lbtc_sats: current_lbtc.max(0),
        has_bitcoin: state.bitcoin.is_some(),
        has_liquid: state.liquid.is_some(),
    })
}

// ── Reconstruction (pure) ────────────────────────────────────────────────────

/// Walks `events` into a cumulative, ascending, gap-free-per-second series.
///
/// `now` replaces a zero timestamp: unconfirmed transactions carry no time in
/// either engine, and epoch 0 would drag the whole series back to 1970.
pub fn build_points(
    mut events: Vec<BalanceEvent>,
    current_btc: i64,
    current_lbtc: i64,
    now: i64,
) -> Vec<HistoryPointDto> {
    if events.is_empty() {
        return Vec::new();
    }
    for e in &mut events {
        if e.ts <= 0 {
            e.ts = now;
        }
    }
    events.sort_by_key(|e| e.ts);

    let sum_btc = events
        .iter()
        .map(|e| e.btc_delta)
        .fold(0i64, i64::saturating_add);
    let sum_lbtc = events
        .iter()
        .map(|e| e.lbtc_delta)
        .fold(0i64, i64::saturating_add);
    let mut btc = current_btc.saturating_sub(sum_btc);
    let mut lbtc = current_lbtc.saturating_sub(sum_lbtc);

    let mut points: Vec<HistoryPointDto> = Vec::with_capacity(events.len());
    for e in events {
        btc = btc.saturating_add(e.btc_delta);
        lbtc = lbtc.saturating_add(e.lbtc_delta);
        // The running totals stay unclamped so the walk still reconciles; only
        // what is published is floored, since a negative balance is nonsense.
        let point = HistoryPointDto {
            ts: e.ts,
            btc_sats: btc.max(0),
            lbtc_sats: lbtc.max(0),
        };
        match points.last_mut() {
            Some(last) if last.ts == e.ts => *last = point,
            _ => points.push(point),
        }
    }

    // The live balance is the truth; the walk is only as good as the history it
    // was fed. Pin the endpoint so the chart always agrees with the headline.
    if let Some(last) = points.last_mut() {
        last.btc_sats = current_btc.max(0);
        last.lbtc_sats = current_lbtc.max(0);
    }
    points
}

fn now_unix() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ev(ts: i64, btc: i64, lbtc: i64) -> BalanceEvent {
        BalanceEvent {
            ts,
            btc_delta: btc,
            lbtc_delta: lbtc,
        }
    }

    const NOW: i64 = 1_800_000_000;

    #[test]
    fn empty_history_yields_no_points() {
        assert!(build_points(Vec::new(), 12_345, 0, NOW).is_empty());
    }

    #[test]
    fn single_tx_lands_on_current_balance() {
        let pts = build_points(vec![ev(1_700_000_000, 50_000, 0)], 50_000, 0, NOW);
        assert_eq!(
            pts,
            vec![HistoryPointDto {
                ts: 1_700_000_000,
                btc_sats: 50_000,
                lbtc_sats: 0,
            }]
        );
    }

    #[test]
    fn out_of_order_events_are_sorted_and_accumulated() {
        let pts = build_points(
            vec![ev(300, -20_000, 0), ev(100, 100_000, 0), ev(200, 0, 7_000)],
            80_000,
            7_000,
            NOW,
        );
        let ts: Vec<i64> = pts.iter().map(|p| p.ts).collect();
        assert_eq!(ts, vec![100, 200, 300]);
        assert_eq!(pts[0].btc_sats, 100_000);
        assert_eq!(pts[1].btc_sats, 100_000);
        assert_eq!(pts[1].lbtc_sats, 7_000);
        assert_eq!(pts[2].btc_sats, 80_000);
    }

    #[test]
    fn same_second_events_merge_into_one_point() {
        let pts = build_points(
            vec![ev(500, 30_000, 0), ev(500, 0, 4_000), ev(900, 10_000, 0)],
            40_000,
            4_000,
            NOW,
        );
        assert_eq!(pts.len(), 2);
        assert_eq!(pts[0].ts, 500);
        assert_eq!(pts[0].btc_sats, 30_000);
        assert_eq!(pts[0].lbtc_sats, 4_000);
        assert_eq!(pts[1].btc_sats, 40_000);
    }

    #[test]
    fn base_reconciles_when_deltas_do_not_sum_to_current() {
        // Only the most recent tx survived in the history, but the wallet holds
        // 1_000_000 sats: the walk must start at the missing 900_000.
        let pts = build_points(vec![ev(1_000, 100_000, 0)], 1_000_000, 0, NOW);
        assert_eq!(pts.len(), 1);
        assert_eq!(pts[0].btc_sats, 1_000_000);

        let pts = build_points(
            vec![ev(1_000, 100_000, 0), ev(2_000, -50_000, 0)],
            1_000_000,
            0,
            NOW,
        );
        assert_eq!(pts[0].btc_sats, 1_050_000);
        assert_eq!(pts[1].btc_sats, 1_000_000);
    }

    #[test]
    fn zero_timestamp_maps_to_now_not_epoch() {
        let pts = build_points(
            vec![ev(1_000, 100_000, 0), ev(0, 25_000, 0)],
            125_000,
            0,
            NOW,
        );
        assert_eq!(pts.len(), 2);
        assert_eq!(pts[1].ts, NOW);
        assert_eq!(pts[1].btc_sats, 125_000);
    }

    /// The Dart side decodes these exact keys in
    /// `features/dashboard/models/balance_history.dart`; renaming one here
    /// silently degrades the chart to zeros rather than failing loudly.
    #[test]
    fn wire_shape_matches_contract_keys() {
        let dto = BalanceHistoryDto {
            points: build_points(vec![ev(1_700_000_000, 50_000, 2_000)], 50_000, 2_000, NOW),
            btc_sats: 50_000,
            lbtc_sats: 2_000,
            has_bitcoin: true,
            has_liquid: false,
        };
        let v = serde_json::to_value(&dto).unwrap();
        for key in [
            "points",
            "btc_sats",
            "lbtc_sats",
            "has_bitcoin",
            "has_liquid",
        ] {
            assert!(v.get(key).is_some(), "missing key {key}");
        }
        // Dart reads `ts` as unix *seconds* and multiplies by 1000.
        for key in ["ts", "btc_sats", "lbtc_sats"] {
            assert!(v["points"][0].get(key).is_some(), "missing point key {key}");
            assert!(v["points"][0][key].is_i64(), "point key {key} not an int");
        }
        assert_eq!(v["points"][0]["ts"], 1_700_000_000i64);
        assert_eq!(v["has_bitcoin"], true);
        assert_eq!(v["has_liquid"], false);

        // Empty history still reports the live balances (contract §1).
        let empty = BalanceHistoryDto {
            points: build_points(Vec::new(), 7, 9, NOW),
            btc_sats: 7,
            lbtc_sats: 9,
            has_bitcoin: true,
            has_liquid: true,
        };
        let v = serde_json::to_value(&empty).unwrap();
        assert_eq!(v["points"].as_array().unwrap().len(), 0);
        assert_eq!(v["btc_sats"], 7);
    }

    #[test]
    fn running_totals_never_go_negative() {
        // A partial history whose deltas exceed the balance would otherwise dip
        // below zero mid-walk.
        let pts = build_points(vec![ev(100, -80_000, 0), ev(200, 10_000, 0)], 0, 0, NOW);
        assert!(pts.iter().all(|p| p.btc_sats >= 0 && p.lbtc_sats >= 0));
        assert_eq!(pts.last().unwrap().btc_sats, 0);
    }
}
