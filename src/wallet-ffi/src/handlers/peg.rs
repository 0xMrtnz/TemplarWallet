//! Simulated peg-in / peg-out provider.
//!
//! Full peg UX against a mock backend: quotes, orders, and a time-driven
//! status lifecycle. Every DTO carries `"simulated": true` and the deposit
//! addresses are obviously-fake constants — no real funds ever move. A real
//! provider integration will replace this module behind the same commands.
//!
//! Orders persist to `<data_dir>/peg_orders.json` (plain JSON, no secrets)
//! with the same atomic temp+fsync+rename pattern as the wallet registry.

use std::fs;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::state::AppFfiState;

const STORE_FILE: &str = "peg_orders.json";

const MIN_SATS: u64 = 10_000;
const MAX_SATS: u64 = 2_100_000_000;
/// Service fee is 0.1% with a 100-sat floor.
const SERVICE_FEE_FLOOR_SATS: u64 = 100;
const NETWORK_FEE_SATS: u64 = 250;
const ETA_MINUTES: u32 = 2;

// Deposit addresses are well-formed-looking but intentionally invalid
// (bech32 checksum cannot pass) so nothing can be sent to them by accident.
// The UI additionally labels them SIMULATED.
const DEPOSIT_ADDR_IN: &str = "tb1qfakepegfakepegfakepegfakepegfakepegqqq";
const DEPOSIT_ADDR_OUT: &str =
    "tlq1qqfakepegfakepegfakepegfakepegfakepegfakepegfakepegfakepegfakepegfakepegqq";

/// Mock lifecycle: seconds elapsed since `created_at` → status reached.
/// `deposit_seen` also sets the fake deposit txid, `completed` the payout txid.
const LIFECYCLE: [(u64, &str); 4] = [
    (20, "deposit_seen"),
    (50, "confirming"),
    (80, "settling"),
    (110, "completed"),
];

// ── DTOs (wire shapes fixed by the FFI contract) ─────────────────────────────

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct PegQuoteDto {
    pub direction: String,
    pub amount_sats: u64,
    pub rate: f64,
    pub service_fee_sats: u64,
    pub network_fee_sats: u64,
    pub receive_sats: u64,
    pub min_sats: u64,
    pub max_sats: u64,
    pub eta_minutes: u32,
    pub simulated: bool,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct PegStatusEntryDto {
    pub status: String,
    /// Unix seconds of the transition.
    pub at: u64,
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct PegOrderDto {
    pub order_id: String,
    pub wallet_id: String,
    /// "in" (BTC → L-BTC) or "out" (L-BTC → BTC).
    pub direction: String,
    /// "awaiting_deposit" | "deposit_seen" | "confirming" | "settling"
    /// | "completed" | "cancelled".
    pub status: String,
    pub deposit_address: String,
    pub deposit_expected_sats: u64,
    pub payout_address: String,
    pub payout_expected_sats: u64,
    pub created_at: u64,
    pub updated_at: u64,
    pub eta_minutes: u32,
    pub txid_deposit: Option<String>,
    pub txid_payout: Option<String>,
    pub simulated: bool,
    pub status_history: Vec<PegStatusEntryDto>,
}

// ── Params (deserialized by dispatch.rs; exported for R3) ────────────────────

#[derive(Deserialize, Debug)]
pub struct PegQuoteParams {
    /// "in" | "out"
    pub direction: String,
    pub amount_sats: u64,
}

#[derive(Deserialize, Debug)]
pub struct PegStartParams {
    pub wallet_id: String,
    pub direction: String,
    pub amount_sats: u64,
    pub payout_address: String,
}

/// Shared by `peg_status` and `peg_cancel`.
#[derive(Deserialize, Debug)]
pub struct PegOrderIdParams {
    pub order_id: String,
}

#[derive(Deserialize, Debug)]
pub struct PegListParams {
    pub wallet_id: String,
}

// ── Handlers ─────────────────────────────────────────────────────────────────

/// Quote a peg without creating an order. Stateless.
pub fn quote(direction: &str, amount_sats: u64) -> Result<PegQuoteDto, String> {
    let direction = normalize_direction(direction)?;
    if amount_sats < MIN_SATS {
        return Err(format!("Amount is below the minimum of {MIN_SATS} sats"));
    }
    if amount_sats > MAX_SATS {
        return Err(format!("Amount is above the maximum of {MAX_SATS} sats"));
    }
    let service_fee_sats = (amount_sats / 1000).max(SERVICE_FEE_FLOOR_SATS);
    // MIN_SATS keeps this subtraction from underflowing.
    let receive_sats = amount_sats - service_fee_sats - NETWORK_FEE_SATS;
    Ok(PegQuoteDto {
        direction: direction.to_string(),
        amount_sats,
        rate: 1.0,
        service_fee_sats,
        network_fee_sats: NETWORK_FEE_SATS,
        receive_sats,
        min_sats: MIN_SATS,
        max_sats: MAX_SATS,
        eta_minutes: ETA_MINUTES,
        simulated: true,
    })
}

/// Create a new simulated peg order in `awaiting_deposit`.
pub fn start(
    state: &mut AppFfiState,
    wallet_id: &str,
    direction: &str,
    amount_sats: u64,
    payout_address: &str,
) -> Result<PegOrderDto, String> {
    let quote = quote(direction, amount_sats)?;
    if state.registry.find(wallet_id).is_none() {
        return Err(format!("Unknown wallet id: {wallet_id}"));
    }
    let payout_address = payout_address.trim();
    if payout_address.is_empty() {
        return Err("Payout address is required".to_string());
    }

    let mut store = load_store(&state.data_dir)?;
    let now = now_secs();
    let deposit_address = if quote.direction == "in" {
        DEPOSIT_ADDR_IN
    } else {
        DEPOSIT_ADDR_OUT
    };
    let order = PegOrderDto {
        order_id: new_order_id(&store),
        wallet_id: wallet_id.to_string(),
        direction: quote.direction.clone(),
        status: "awaiting_deposit".to_string(),
        deposit_address: deposit_address.to_string(),
        deposit_expected_sats: amount_sats,
        payout_address: payout_address.to_string(),
        payout_expected_sats: quote.receive_sats,
        created_at: now,
        updated_at: now,
        eta_minutes: ETA_MINUTES,
        txid_deposit: None,
        txid_payout: None,
        simulated: true,
        status_history: vec![PegStatusEntryDto {
            status: "awaiting_deposit".to_string(),
            at: now,
        }],
    };
    store.orders.push(order.clone());
    save_store(&state.data_dir, &store)?;
    Ok(order)
}

/// Current state of one order, advancing the mock lifecycle first.
pub fn status(state: &mut AppFfiState, order_id: &str) -> Result<PegOrderDto, String> {
    let mut store = load_store(&state.data_dir)?;
    let now = now_secs();
    let order = find_order(&mut store, order_id)?;
    let changed = advance(order, now);
    let dto = order.clone();
    if changed {
        save_store(&state.data_dir, &store)?;
    }
    Ok(dto)
}

/// All orders for a wallet, newest first, each advanced before returning.
pub fn list(state: &mut AppFfiState, wallet_id: &str) -> Result<Vec<PegOrderDto>, String> {
    let mut store = load_store(&state.data_dir)?;
    let now = now_secs();
    let mut changed = false;
    for order in store.orders.iter_mut().filter(|o| o.wallet_id == wallet_id) {
        changed |= advance(order, now);
    }
    if changed {
        save_store(&state.data_dir, &store)?;
    }
    let mut out: Vec<PegOrderDto> = store
        .orders
        .into_iter()
        .filter(|o| o.wallet_id == wallet_id)
        .collect();
    out.sort_by_key(|o| std::cmp::Reverse(o.created_at));
    Ok(out)
}

/// Cancel an order — only allowed while still awaiting the deposit.
pub fn cancel(state: &mut AppFfiState, order_id: &str) -> Result<PegOrderDto, String> {
    let mut store = load_store(&state.data_dir)?;
    let now = now_secs();
    let order = find_order(&mut store, order_id)?;
    // Advance first: an order whose (simulated) deposit already appeared can
    // no longer be cancelled, even if the UI hasn't polled recently.
    advance(order, now);
    if order.status != "awaiting_deposit" {
        return Err(format!(
            "Order can no longer be cancelled (status: {})",
            order.status
        ));
    }
    order.status = "cancelled".to_string();
    order.updated_at = now;
    order.status_history.push(PegStatusEntryDto {
        status: "cancelled".to_string(),
        at: now,
    });
    let dto = order.clone();
    save_store(&state.data_dir, &store)?;
    Ok(dto)
}

// ── Lifecycle ────────────────────────────────────────────────────────────────

fn normalize_direction(direction: &str) -> Result<&'static str, String> {
    match direction {
        "in" => Ok("in"),
        "out" => Ok("out"),
        other => Err(format!(
            "Unknown peg direction '{other}' — expected \"in\" or \"out\""
        )),
    }
}

/// Applies every lifecycle transition the elapsed time has reached. Returns
/// true when the order changed. Terminal states never advance.
fn advance(order: &mut PegOrderDto, now: u64) -> bool {
    if order.status == "cancelled" || order.status == "completed" {
        return false;
    }
    let elapsed = now.saturating_sub(order.created_at);
    let mut changed = false;
    for (at_secs, status) in LIFECYCLE {
        if elapsed < at_secs {
            break;
        }
        if order.status_history.iter().any(|h| h.status == status) {
            continue;
        }
        // The simulated transition happened at created_at + threshold, not at
        // poll time — history stays truthful under sparse polling.
        let at = order.created_at + at_secs;
        order.status = status.to_string();
        order.updated_at = at;
        order.status_history.push(PegStatusEntryDto {
            status: status.to_string(),
            at,
        });
        match status {
            "deposit_seen" => order.txid_deposit = Some(fake_txid(&order.order_id, "deposit")),
            "completed" => order.txid_payout = Some(fake_txid(&order.order_id, "payout")),
            _ => {}
        }
        changed = true;
    }
    changed
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// FNV-1a 64-bit — stable across platforms and Rust versions, unlike
/// `DefaultHasher`, so fake txids survive app upgrades.
fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for &b in bytes {
        hash ^= u64::from(b);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

/// Deterministic 64-hex fake txid derived from the order id and its role
/// ("deposit" / "payout") — repolling always shows the same txids.
fn fake_txid(order_id: &str, role: &str) -> String {
    (0..4)
        .map(|i| {
            format!(
                "{:016x}",
                fnv1a64(format!("{order_id}:{role}:{i}").as_bytes())
            )
        })
        .collect()
}

/// `pg_<8hex>` id, unique within the store. Seeded from wall clock + pid —
/// mock orders need uniqueness, not unpredictability.
fn new_order_id(store: &PegStore) -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let pid = std::process::id();
    let mut salt = 0u64;
    loop {
        let h = fnv1a64(format!("{nanos}:{pid}:{salt}").as_bytes());
        let id = format!("pg_{:08x}", (h as u32) ^ ((h >> 32) as u32));
        if !store.orders.iter().any(|o| o.order_id == id) {
            return id;
        }
        salt += 1;
    }
}

// ── Persistence ──────────────────────────────────────────────────────────────

#[derive(Serialize, Deserialize, Debug, Default)]
struct PegStore {
    orders: Vec<PegOrderDto>,
}

fn store_path(data_dir: &Path) -> std::path::PathBuf {
    data_dir.join(STORE_FILE)
}

fn load_store(data_dir: &Path) -> Result<PegStore, String> {
    let path = store_path(data_dir);
    if !path.exists() {
        return Ok(PegStore::default());
    }
    let raw = fs::read_to_string(&path).map_err(|e| format!("Cannot read {STORE_FILE}: {e}"))?;
    serde_json::from_str(&raw).map_err(|e| {
        format!("{STORE_FILE} is corrupt: {e}. Delete the file to reset simulated peg orders.")
    })
}

fn save_store(data_dir: &Path, store: &PegStore) -> Result<(), String> {
    fs::create_dir_all(data_dir).map_err(|e| format!("Cannot create data dir: {e}"))?;
    let json = serde_json::to_string_pretty(store)
        .map_err(|e| format!("Cannot serialize peg orders: {e}"))?;
    atomic_write(&store_path(data_dir), &json)
}

/// Atomic write (temp file + fsync + rename) through templar-core's helper, which
/// also creates the file owner-only (A3) — these stores sit in the same
/// directory as the registry and used to land as `0644`.
fn atomic_write(path: &Path, contents: &str) -> Result<(), String> {
    templar_core::registry::atomic_write(path, contents).map_err(|e| e.to_string())
}

fn find_order<'a>(store: &'a mut PegStore, order_id: &str) -> Result<&'a mut PegOrderDto, String> {
    store
        .orders
        .iter_mut()
        .find(|o| o.order_id == order_id)
        .ok_or_else(|| format!("Unknown peg order: {order_id}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use templar_core::registry::{WalletEntry, WalletProfile};

    fn test_state(tag: &str) -> AppFfiState {
        let dir = std::env::temp_dir().join(format!("templar_peg_{}_{}", tag, std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        AppFfiState::new_for_test(dir)
    }

    fn add_wallet(state: &mut AppFfiState) -> String {
        let entry = WalletEntry::new(
            "Peg Test".into(),
            String::new(),
            WalletProfile::Software {
                mnemonic: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about".into(),
            },
        );
        let id = entry.id.clone();
        state.registry.add(entry);
        id
    }

    fn sample_order(state: &mut AppFfiState) -> PegOrderDto {
        let wallet_id = add_wallet(state);
        start(state, &wallet_id, "in", 100_000, "tlq1qqpayout").unwrap()
    }

    #[test]
    fn quote_matches_contract_sample() {
        let q = quote("in", 100_000).unwrap();
        assert_eq!(q.direction, "in");
        assert_eq!(q.service_fee_sats, 100);
        assert_eq!(q.network_fee_sats, 250);
        assert_eq!(q.receive_sats, 99_650);
        assert_eq!(q.min_sats, 10_000);
        assert_eq!(q.max_sats, 2_100_000_000);
        assert_eq!(q.eta_minutes, 2);
        assert!(q.simulated);
        // 0.1% dominates the floor for large amounts.
        assert_eq!(quote("out", 1_000_000).unwrap().service_fee_sats, 1_000);
    }

    #[test]
    fn quote_rejects_out_of_range_and_bad_direction() {
        assert!(quote("in", 9_999).unwrap_err().contains("minimum"));
        assert!(quote("in", 2_100_000_001).unwrap_err().contains("maximum"));
        assert!(quote("sideways", 100_000)
            .unwrap_err()
            .contains("direction"));
    }

    #[test]
    fn start_creates_persisted_awaiting_order() {
        let mut state = test_state("start");
        let order = sample_order(&mut state);
        assert!(order.order_id.starts_with("pg_"));
        assert_eq!(order.order_id.len(), 11);
        assert_eq!(order.status, "awaiting_deposit");
        assert_eq!(order.deposit_address, DEPOSIT_ADDR_IN);
        assert_eq!(order.deposit_expected_sats, 100_000);
        assert_eq!(order.payout_expected_sats, 99_650);
        assert!(order.simulated);
        assert_eq!(order.status_history.len(), 1);
        assert!(order.txid_deposit.is_none() && order.txid_payout.is_none());

        // Persisted atomically: file exists, no tmp litter.
        assert!(state.data_dir.join(STORE_FILE).exists());
        assert!(!state.data_dir.join("peg_orders.tmp").exists());
        let reloaded = load_store(&state.data_dir).unwrap();
        assert_eq!(reloaded.orders.len(), 1);
        assert_eq!(reloaded.orders[0].order_id, order.order_id);
    }

    #[test]
    fn start_requires_known_wallet_and_payout_address() {
        let mut state = test_state("start_checks");
        assert!(start(&mut state, "nope", "in", 100_000, "addr")
            .unwrap_err()
            .contains("Unknown wallet"));
        let wallet_id = add_wallet(&mut state);
        assert!(start(&mut state, &wallet_id, "in", 100_000, "   ")
            .unwrap_err()
            .contains("Payout address"));
        // Out direction gets the Liquid-side deposit constant.
        let order = start(&mut state, &wallet_id, "out", 50_000, "tb1qpayout").unwrap();
        assert_eq!(order.deposit_address, DEPOSIT_ADDR_OUT);
    }

    #[test]
    fn lifecycle_advances_by_elapsed_time() {
        let mut state = test_state("lifecycle");
        let mut order = sample_order(&mut state);
        let t0 = order.created_at;

        assert!(!advance(&mut order, t0 + 10));
        assert_eq!(order.status, "awaiting_deposit");

        assert!(advance(&mut order, t0 + 25));
        assert_eq!(order.status, "deposit_seen");
        let dep = order.txid_deposit.clone().expect("deposit txid set");
        assert_eq!(dep.len(), 64);
        assert!(dep.chars().all(|c| c.is_ascii_hexdigit()));
        assert_eq!(order.updated_at, t0 + 20);

        assert!(advance(&mut order, t0 + 60));
        assert_eq!(order.status, "confirming");

        // A sparse poll far in the future lands on completed with the full
        // history recorded at the simulated transition times.
        assert!(advance(&mut order, t0 + 500));
        assert_eq!(order.status, "completed");
        let statuses: Vec<&str> = order
            .status_history
            .iter()
            .map(|h| h.status.as_str())
            .collect();
        assert_eq!(
            statuses,
            [
                "awaiting_deposit",
                "deposit_seen",
                "confirming",
                "settling",
                "completed"
            ]
        );
        assert_eq!(order.status_history[3].at, t0 + 80);
        let pay = order.txid_payout.clone().expect("payout txid set");
        assert_ne!(pay, dep);
        // Terminal: never advances again.
        assert!(!advance(&mut order, t0 + 1_000));
    }

    #[test]
    fn fake_txids_are_deterministic() {
        assert_eq!(
            fake_txid("pg_00000001", "deposit"),
            fake_txid("pg_00000001", "deposit")
        );
        assert_ne!(
            fake_txid("pg_00000001", "deposit"),
            fake_txid("pg_00000001", "payout")
        );
        assert_ne!(
            fake_txid("pg_00000001", "deposit"),
            fake_txid("pg_00000002", "deposit")
        );
    }

    #[test]
    fn status_persists_advanced_state() {
        let mut state = test_state("status");
        let order = sample_order(&mut state);
        // Backdate the stored order so status() crosses two thresholds.
        let mut store = load_store(&state.data_dir).unwrap();
        store.orders[0].created_at -= 55;
        store.orders[0].status_history[0].at -= 55;
        save_store(&state.data_dir, &store).unwrap();

        let seen = status(&mut state, &order.order_id).unwrap();
        assert_eq!(seen.status, "confirming");
        // The advance was persisted, not just returned.
        let reloaded = load_store(&state.data_dir).unwrap();
        assert_eq!(reloaded.orders[0].status, "confirming");
        assert_eq!(reloaded.orders[0].status_history.len(), 3);

        assert!(status(&mut state, "pg_missing")
            .unwrap_err()
            .contains("Unknown peg order"));
    }

    #[test]
    fn list_returns_own_orders_newest_first() {
        let mut state = test_state("list");
        let wallet_id = add_wallet(&mut state);
        let other_id = add_wallet(&mut state);
        let first = start(&mut state, &wallet_id, "in", 100_000, "a1").unwrap();
        let second = start(&mut state, &wallet_id, "out", 20_000, "a2").unwrap();
        start(&mut state, &other_id, "in", 30_000, "a3").unwrap();

        // Make the first order strictly older so the ordering is observable.
        let mut store = load_store(&state.data_dir).unwrap();
        store
            .orders
            .iter_mut()
            .find(|o| o.order_id == first.order_id)
            .unwrap()
            .created_at -= 5;
        save_store(&state.data_dir, &store).unwrap();

        let listed = list(&mut state, &wallet_id).unwrap();
        assert_eq!(listed.len(), 2);
        assert_eq!(listed[0].order_id, second.order_id);
        assert_eq!(listed[1].order_id, first.order_id);
        assert!(list(&mut state, &other_id).unwrap().len() == 1);
        assert!(list(&mut state, "unknown").unwrap().is_empty());
    }

    #[test]
    fn cancel_only_while_awaiting_deposit() {
        let mut state = test_state("cancel");
        let order = sample_order(&mut state);
        let cancelled = cancel(&mut state, &order.order_id).unwrap();
        assert_eq!(cancelled.status, "cancelled");
        assert_eq!(cancelled.status_history.last().unwrap().status, "cancelled");
        // Terminal in both directions: no re-cancel, no further advance.
        assert!(cancel(&mut state, &order.order_id)
            .unwrap_err()
            .contains("no longer"));
        let mut stored = load_store(&state.data_dir).unwrap();
        assert!(!advance(&mut stored.orders[0], now_secs() + 10_000));

        // An order whose deposit already appeared cannot be cancelled.
        let late = sample_order(&mut state);
        let mut store = load_store(&state.data_dir).unwrap();
        store
            .orders
            .iter_mut()
            .find(|o| o.order_id == late.order_id)
            .unwrap()
            .created_at -= 30;
        save_store(&state.data_dir, &store).unwrap();
        let err = cancel(&mut state, &late.order_id).unwrap_err();
        assert!(err.contains("deposit_seen"), "unexpected error: {err}");
    }

    #[test]
    fn wire_shape_matches_contract_keys() {
        let mut state = test_state("wire");
        let order = sample_order(&mut state);
        let v = serde_json::to_value(&order).unwrap();
        for key in [
            "order_id",
            "wallet_id",
            "direction",
            "status",
            "deposit_address",
            "deposit_expected_sats",
            "payout_address",
            "payout_expected_sats",
            "created_at",
            "updated_at",
            "eta_minutes",
            "txid_deposit",
            "txid_payout",
            "simulated",
            "status_history",
        ] {
            assert!(v.get(key).is_some(), "missing key {key}");
        }
        assert_eq!(v["simulated"], true);
        assert!(v["txid_deposit"].is_null());
        assert_eq!(v["status_history"][0]["status"], "awaiting_deposit");
        assert!(v["status_history"][0]["at"].is_u64());

        let q = serde_json::to_value(quote("in", 100_000).unwrap()).unwrap();
        for key in [
            "direction",
            "amount_sats",
            "rate",
            "service_fee_sats",
            "network_fee_sats",
            "receive_sats",
            "min_sats",
            "max_sats",
            "eta_minutes",
            "simulated",
        ] {
            assert!(q.get(key).is_some(), "missing key {key}");
        }
    }

    #[test]
    fn corrupt_store_is_a_clear_error() {
        let mut state = test_state("corrupt");
        fs::write(state.data_dir.join(STORE_FILE), "{ not json").unwrap();
        let err = list(&mut state, "any").unwrap_err();
        assert!(err.contains("corrupt"));
    }
}
