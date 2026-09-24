//! LiquiDEX swap / order-book commands — FFI wiring over the templar-core
//! engine (`liquid::liquidex`) and book client (`liquid::book`).
//!
//! The book is browsed read-only (liquidex.it is mainnet); the make/take
//! engine signs and broadcasts **only on Liquid testnet** — the engine's
//! deep verification refuses anything else (`take_block_reason`).
//!
//! My-offers persist to `<data_dir>/swap_offers.json` (plain JSON, keyed per
//! wallet, no secrets) with the same atomic temp+fsync+rename pattern as the
//! wallet registry and the peg store.

use std::fs;
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use templar_core::liquid::book::{fetch_book, BookEntry, BookLeg, DEFAULT_BOOK_URL};
use templar_core::liquid::liquidex::{
    broadcast_transaction_on, proposal_utxo_unspent_on, verify_proposal_on,
};
use templar_core::{
    build_cancel_tx, first_frozen, make_proposal, take_preview_excluding, take_proposal_excluding,
    verify_proposal, AssetRegistry, CoinChain, LiquidError, LiquidexLeg, LiquidexProposal, SwapLeg,
    SwapNetwork, TakePreview, VerifyCheck, VerifyResult,
};

use crate::state::AppFfiState;

const STORE_FILE: &str = "swap_offers.json";

// ── DTOs (wire shapes fixed by the FFI contract) ─────────────────────────────

/// One asset/amount side of a swap, enriched for display.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct SwapLegDto {
    pub asset_id: String,
    pub ticker: String,
    pub amount_sats: u64,
    pub display_amount: String,
}

/// One order-book row, oriented for the taker: `receive` is the maker's
/// input leg (what the taker gets), `pay` the maker's output leg.
#[derive(Serialize, Debug, Clone)]
pub struct SwapRowDto {
    pub id: u64,
    pub available: bool,
    pub receive: SwapLegDto,
    pub pay: SwapLegDto,
    pub price: f64,
    pub price_display: String,
    pub created: String,
    /// All offline verification checks passed.
    pub verified: bool,
    /// First failing check's note (null when verified).
    pub verify_note: Option<String>,
    pub proposal_json: String,
    /// "testnet" | "mainnet" | "unknown" (offline heuristic).
    pub network: String,
    pub takeable: bool,
    /// Offer kind — only "swap" today; "loan" arrives with the lending protocol.
    pub kind: String,
}

/// `swap_verify` result: the engine's `VerifyResult` with display-enriched legs.
#[derive(Serialize, Debug, Clone)]
pub struct SwapAnalysisDto {
    pub valid: bool,
    pub checks: Vec<VerifyCheck>,
    pub maker_offers: SwapLegDto,
    pub maker_wants: SwapLegDto,
    pub network: String,
    pub takeable: bool,
    pub take_block_reason: Option<String>,
}

/// `swap_take_preview` result — honest fee/change from the real built tx.
#[derive(Serialize, Debug, Clone)]
pub struct TakePreviewDto {
    pub you_receive: SwapLegDto,
    pub you_pay: SwapLegDto,
    pub fee_sats: u64,
    pub fee_display: String,
    pub change: Vec<SwapLegDto>,
    pub analysis: SwapAnalysisDto,
}

/// One of this wallet's own published offers.
#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct MyOfferDto {
    /// `of_<8hex>`.
    pub offer_id: String,
    pub kind: String,
    /// "open" | "closed" (utxo spent by a taker) | "cancelled".
    pub status: String,
    /// Unix seconds.
    pub created_at: u64,
    /// What this wallet gives away (the offered UTXO's leg).
    pub offers: SwapLegDto,
    /// What this wallet asks for.
    pub wants: SwapLegDto,
    pub proposal_json: String,
    /// The offered prevout, `"txid:vout"`.
    pub utxo: String,
}

// ── Params (deserialized by dispatch.rs) ─────────────────────────────────────

#[derive(Deserialize, Debug)]
pub struct ListSwapsParams {
    #[serde(default)]
    pub include_unavailable: bool,
}

#[derive(Deserialize, Debug)]
pub struct SwapVerifyParams {
    pub proposal_json: String,
    #[serde(default)]
    pub deep: bool,
}

/// Shared by `swap_take_preview` and `swap_take`.
#[derive(Deserialize, Debug)]
pub struct SwapTakeParams {
    pub wallet_id: String,
    pub proposal_json: String,
    #[serde(default)]
    pub fee_rate: Option<f32>,
}

#[derive(Deserialize, Debug)]
pub struct SwapMakeParams {
    pub wallet_id: String,
    /// `"txid:vout"` of the wallet UTXO to offer (its full amount).
    pub utxo: String,
    pub want_asset_id: String,
    pub want_amount_sats: u64,
}

#[derive(Deserialize, Debug)]
pub struct SwapMakePrepareParams {
    pub wallet_id: String,
    pub asset_id: String,
    pub amount_sats: u64,
    /// Accepted for wire compatibility; the Liquid flat-fee builder that
    /// backs the self-send does not take a rate.
    #[serde(default)]
    pub fee_rate: Option<f32>,
}

#[derive(Deserialize, Debug)]
pub struct ListMyOffersParams {
    pub wallet_id: String,
}

#[derive(Deserialize, Debug)]
pub struct SwapCancelParams {
    pub wallet_id: String,
    pub offer_id: String,
}

// ── Handlers ─────────────────────────────────────────────────────────────────

/// Fetches the order book and maps each entry to a display row.
/// URL: `TEMPLAR_SWAP_BOOK_URL` env override or the liquidex.it default,
/// with `?all` appended when unavailable offers are requested too.
///
/// The book is a public (mainnet-sourced) service: on a local regtest there
/// is nothing to list, and the rows would all be untakeable anyway.
pub fn list_swaps(
    state: &AppFfiState,
    include_unavailable: bool,
) -> Result<Vec<SwapRowDto>, String> {
    state.require_liquid_testnet("The public LiquiDEX order book")?;
    let entries = fetch_book(&book_url(include_unavailable)).map_err(|e| e.to_string())?;
    Ok(rows_from_entries(&entries))
}

/// Parses and verifies a proposal (offline, or deep with chain access on the
/// active Liquid network), enriching the maker legs for display.
pub fn verify(
    state: &AppFfiState,
    proposal_json: &str,
    deep: bool,
) -> Result<SwapAnalysisDto, String> {
    let proposal = LiquidexProposal::from_json(proposal_json).map_err(|e| e.to_string())?;
    let result =
        verify_proposal_on(&proposal, deep, &state.liquid_network).map_err(|e| e.to_string())?;
    Ok(analysis_dto(&state.asset_registry, &result))
}

/// Deep-verifies and builds the real taker transaction (unsigned broadcast-
/// wise — nothing hits the chain) to report honest fee and change.
pub fn take_preview(
    state: &AppFfiState,
    proposal_json: &str,
    fee_rate: Option<f32>,
) -> Result<TakePreviewDto, String> {
    let liq = state.liquid.as_ref().ok_or("Liquid wallet not open")?;
    let proposal = LiquidexProposal::from_json(proposal_json).map_err(|e| e.to_string())?;
    let frozen = state.frozen_on(CoinChain::Liquid);
    let preview =
        take_preview_excluding(liq, &proposal, fee_rate, &frozen).map_err(|e| e.to_string())?;
    Ok(preview_dto(&state.asset_registry, &preview))
}

/// Takes a proposal: the engine deep-verifies internally and refuses
/// non-takeable orders (mainnet, failed checks) with the block reason as the
/// error; on success the signed transaction is broadcast to Liquid testnet.
pub fn take(
    state: &AppFfiState,
    proposal_json: &str,
    fee_rate: Option<f32>,
) -> Result<String, String> {
    let liq = state.liquid.as_ref().ok_or("Liquid wallet not open")?;
    let proposal = LiquidexProposal::from_json(proposal_json).map_err(|e| e.to_string())?;
    let frozen = state.frozen_on(CoinChain::Liquid);
    let result =
        take_proposal_excluding(liq, &proposal, fee_rate, &frozen).map_err(|e| e.to_string())?;
    // Backstop: the selection above already left frozen coins out, and a
    // signed swap must never reach the network if that ever changes.
    let spent = result
        .tx
        .input
        .iter()
        .map(|i| i.previous_output.to_string());
    if let Some(op) = first_frozen(spent, &frozen) {
        return Err(LiquidError::FrozenCoin(op).to_string());
    }
    broadcast_transaction_on(&result.tx, &state.liquid_network).map_err(|e| e.to_string())
}

/// Builds and signs a proposal offering one wallet UTXO's full amount, then
/// persists it to the my-offers store. Offline (broadcast happens when a
/// taker takes it).
pub fn make(
    state: &AppFfiState,
    wallet_id: &str,
    utxo: &str,
    want_asset_id: &str,
    want_amount_sats: u64,
) -> Result<MyOfferDto, String> {
    if let Some(op) = first_frozen([utxo], &state.frozen_on(CoinChain::Liquid)) {
        return Err(LiquidError::FrozenCoin(op).to_string());
    }
    let liq = state.liquid.as_ref().ok_or("Liquid wallet not open")?;
    let proposal =
        make_proposal(liq, utxo, want_asset_id, want_amount_sats).map_err(|e| e.to_string())?;
    let proposal_json = proposal.to_json().map_err(|e| e.to_string())?;
    let offers = proposal
        .inputs
        .first()
        .map(|l| liquidex_leg_dto(&state.asset_registry, l))
        .ok_or("Built proposal has no input leg")?;
    let wants = proposal
        .outputs
        .first()
        .map(|l| liquidex_leg_dto(&state.asset_registry, l))
        .ok_or("Built proposal has no output leg")?;

    let mut store = load_store(&state.data_dir)?;
    let offer = MyOfferDto {
        offer_id: new_offer_id(&store),
        kind: "swap".to_string(),
        status: "open".to_string(),
        created_at: now_secs(),
        offers,
        wants,
        proposal_json,
        utxo: utxo.to_string(),
    };
    store.offers.push(StoredOffer {
        wallet_id: wallet_id.to_string(),
        offer: offer.clone(),
    });
    save_store(&state.data_dir, &store)?;
    Ok(offer)
}

/// Exact-amount self-send: creates a UTXO of exactly `amount_sats` of
/// `asset_id` at a fresh own address, for the "offer amount X but no exact
/// coin" path. Signs and broadcasts; the UI re-syncs afterwards.
pub fn make_prepare(
    state: &mut AppFfiState,
    asset_id: &str,
    amount_sats: u64,
    _fee_rate: Option<f32>,
) -> Result<String, String> {
    if amount_sats == 0 {
        return Err("Amount must be greater than zero".to_string());
    }
    let frozen = state.frozen_on(CoinChain::Liquid);
    let liq = state.liquid.as_mut().ok_or("Liquid wallet not open")?;
    let address = liq.get_new_address().map_err(|e| e.to_string())?;
    let mut pset = liq
        .create_tx_multi(
            &[(address, amount_sats, asset_id.to_string())],
            None,
            &frozen,
        )
        .map_err(|e| e.to_string())?;
    liq.sign(&mut pset).map_err(|e| e.to_string())?;
    liq.broadcast(&mut pset).map_err(|e| e.to_string())
}

/// This wallet's offers, newest first. Open offers get a best-effort status
/// refresh: an offered UTXO seen spent on testnet closes the offer (persisted);
/// network errors and foreign-network prevouts keep the stored status.
pub fn list_my_offers(state: &AppFfiState, wallet_id: &str) -> Result<Vec<MyOfferDto>, String> {
    let mut store = load_store(&state.data_dir)?;
    let mut changed = false;
    for stored in store.offers.iter_mut().filter(|o| o.wallet_id == wallet_id) {
        if stored.offer.status != "open" {
            continue;
        }
        let Ok(proposal) = LiquidexProposal::from_json(&stored.offer.proposal_json) else {
            continue;
        };
        // Some(false) = spent → closed. Some(true) = still open.
        // None (prevout unknown to this chain) and Err (network) keep the
        // stored status — never guess an offer's fate offline.
        if let Ok(Some(false)) = proposal_utxo_unspent_on(&proposal, &state.liquid_network) {
            stored.offer.status = "closed".to_string();
            changed = true;
        }
    }
    if changed {
        save_store(&state.data_dir, &store)?;
    }
    let mut out: Vec<MyOfferDto> = store
        .offers
        .into_iter()
        .filter(|o| o.wallet_id == wallet_id)
        .map(|o| o.offer)
        .collect();
    out.sort_by_key(|o| std::cmp::Reverse(o.created_at));
    Ok(out)
}

/// Cancels an open offer by broadcasting a self-spend of the offered UTXO —
/// the double-spend invalidates the signed proposal. Marks it "cancelled".
///
/// A frozen offered coin is still cancellable on purpose: the signed offer
/// can be taken whatever this wallet thinks of the coin, and this self-spend
/// is the only thing that stops that.
pub fn cancel(state: &AppFfiState, wallet_id: &str, offer_id: &str) -> Result<String, String> {
    let liq = state.liquid.as_ref().ok_or("Liquid wallet not open")?;
    let mut store = load_store(&state.data_dir)?;
    let stored = store
        .offers
        .iter_mut()
        .find(|o| o.wallet_id == wallet_id && o.offer.offer_id == offer_id)
        .ok_or_else(|| format!("Unknown swap offer: {offer_id}"))?;
    if stored.offer.status != "open" {
        return Err(format!(
            "Offer can no longer be cancelled (status: {})",
            stored.offer.status
        ));
    }
    let tx = build_cancel_tx(liq, &stored.offer.utxo).map_err(|e| e.to_string())?;
    let txid = broadcast_transaction_on(&tx, &state.liquid_network).map_err(|e| e.to_string())?;
    stored.offer.status = "cancelled".to_string();
    save_store(&state.data_dir, &store)?;
    Ok(txid)
}

// ── Row / leg mapping ────────────────────────────────────────────────────────

fn book_url(include_unavailable: bool) -> String {
    let base = std::env::var("TEMPLAR_SWAP_BOOK_URL")
        .ok()
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| DEFAULT_BOOK_URL.to_string());
    if include_unavailable {
        format!("{base}?all")
    } else {
        base
    }
}

/// Pure mapping + ordering (available first, then id descending) — the
/// network fetch stays out so this is unit-testable.
fn rows_from_entries(entries: &[BookEntry]) -> Vec<SwapRowDto> {
    let mut rows: Vec<SwapRowDto> = entries.iter().map(book_row).collect();
    rows.sort_by(|a, b| b.available.cmp(&a.available).then(b.id.cmp(&a.id)));
    rows
}

fn book_row(entry: &BookEntry) -> SwapRowDto {
    let receive = book_leg_dto(entry.inputs.first());
    let pay = book_leg_dto(entry.outputs.first());
    // Ratio is the book's own input/output price; the display convention is
    // "<price> PAY/RECEIVE" (how much of the paid asset per received unit).
    let price_display = format!("{:.8} {}/{}", entry.ratio, pay.ticker, receive.ticker);

    // Offline verification. A proposal that does not even parse is still
    // listed — visibly unverified and never takeable.
    let (verified, verify_note, network, takeable) =
        match LiquidexProposal::from_json(&entry.proposal_json) {
            Ok(proposal) => match verify_proposal(&proposal, false) {
                Ok(res) => {
                    let note = first_failure_note(&res);
                    // Row-level takeability: only offers the offline heuristic
                    // positively places on testnet. Unknown-network rows stay
                    // non-takeable here — the book source is mainnet, and the
                    // import-proposal flow (which deep-verifies) is the path
                    // for foreign proposals. The engine re-checks at take time
                    // regardless.
                    let takeable = res.valid && res.network == SwapNetwork::Testnet;
                    (res.valid, note, res.network.as_str().to_string(), takeable)
                }
                Err(e) => (false, Some(e.to_string()), "unknown".to_string(), false),
            },
            Err(e) => (false, Some(e.to_string()), "unknown".to_string(), false),
        };

    SwapRowDto {
        id: entry.id,
        available: entry.available,
        receive,
        pay,
        price: entry.ratio,
        price_display,
        created: entry.creation_timestamp.clone(),
        verified,
        verify_note,
        proposal_json: entry.proposal_json.clone(),
        network,
        takeable,
        kind: "swap".to_string(),
    }
}

/// Note of the first failing check, if any.
fn first_failure_note(res: &VerifyResult) -> Option<String> {
    res.checks.iter().find(|c| c.ok == Some(false)).map(|c| {
        c.note
            .clone()
            .unwrap_or_else(|| format!("{} check failed", c.name))
    })
}

/// Book rows carry their own display data (mainnet assets are not in the
/// testnet `AssetRegistry`): ticker from the book's display name, amount as
/// published.
fn book_leg_dto(leg: Option<&BookLeg>) -> SwapLegDto {
    match leg {
        Some(l) => SwapLegDto {
            asset_id: l.asset.clone(),
            ticker: l.ticker(),
            amount_sats: l.sats,
            display_amount: l.amount.clone(),
        },
        None => SwapLegDto {
            asset_id: String::new(),
            ticker: String::new(),
            amount_sats: 0,
            display_amount: String::new(),
        },
    }
}

/// Enriches an engine leg through the asset registry (testnet assets resolve
/// to real tickers/precision; unknown assets fall back to the registry's
/// asset-id-prefix ticker and 8-decimal formatting).
fn registry_leg(registry: &AssetRegistry, leg: &SwapLeg) -> SwapLegDto {
    SwapLegDto {
        asset_id: leg.asset_id.clone(),
        ticker: registry.ticker(&leg.asset_id).to_string(),
        amount_sats: leg.amount_sats,
        display_amount: registry.format_amount_with_fallback(&leg.asset_id, leg.amount_sats),
    }
}

fn liquidex_leg_dto(registry: &AssetRegistry, leg: &LiquidexLeg) -> SwapLegDto {
    registry_leg(
        registry,
        &SwapLeg {
            asset_id: leg.asset.clone(),
            amount_sats: leg.amount,
        },
    )
}

fn analysis_dto(registry: &AssetRegistry, res: &VerifyResult) -> SwapAnalysisDto {
    SwapAnalysisDto {
        valid: res.valid,
        checks: res.checks.clone(),
        maker_offers: registry_leg(registry, &res.maker_offers),
        maker_wants: registry_leg(registry, &res.maker_wants),
        network: res.network.as_str().to_string(),
        takeable: res.takeable,
        take_block_reason: res.take_block_reason.clone(),
    }
}

fn preview_dto(registry: &AssetRegistry, preview: &TakePreview) -> TakePreviewDto {
    TakePreviewDto {
        you_receive: registry_leg(registry, &preview.you_receive),
        you_pay: registry_leg(registry, &preview.you_pay),
        fee_sats: preview.fee_sats,
        fee_display: format!("{} sats", preview.fee_sats),
        change: preview
            .change
            .iter()
            .map(|l| registry_leg(registry, l))
            .collect(),
        analysis: analysis_dto(registry, &preview.analysis),
    }
}

// ── Persistence ──────────────────────────────────────────────────────────────

/// One stored offer: the wire DTO plus the owning wallet (kept out of the
/// wire shape via flatten).
#[derive(Serialize, Deserialize, Debug, Clone)]
struct StoredOffer {
    wallet_id: String,
    #[serde(flatten)]
    offer: MyOfferDto,
}

#[derive(Serialize, Deserialize, Debug, Default)]
struct SwapOfferStore {
    offers: Vec<StoredOffer>,
}

fn store_path(data_dir: &Path) -> std::path::PathBuf {
    data_dir.join(STORE_FILE)
}

fn load_store(data_dir: &Path) -> Result<SwapOfferStore, String> {
    let path = store_path(data_dir);
    if !path.exists() {
        return Ok(SwapOfferStore::default());
    }
    let raw = fs::read_to_string(&path).map_err(|e| format!("Cannot read {STORE_FILE}: {e}"))?;
    serde_json::from_str(&raw).map_err(|e| {
        format!("{STORE_FILE} is corrupt: {e}. Delete the file to reset your swap offers.")
    })
}

fn save_store(data_dir: &Path, store: &SwapOfferStore) -> Result<(), String> {
    fs::create_dir_all(data_dir).map_err(|e| format!("Cannot create data dir: {e}"))?;
    let json = serde_json::to_string_pretty(store)
        .map_err(|e| format!("Cannot serialize swap offers: {e}"))?;
    atomic_write(&store_path(data_dir), &json)
}

/// Atomic write (temp file + fsync + rename) through templar-core's helper, which
/// also creates the file owner-only (A3) — these stores sit in the same
/// directory as the registry and used to land as `0644`.
fn atomic_write(path: &Path, contents: &str) -> Result<(), String> {
    templar_core::registry::atomic_write(path, contents).map_err(|e| e.to_string())
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// FNV-1a 64-bit — stable across platforms and Rust versions.
fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for &b in bytes {
        hash ^= u64::from(b);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

/// `of_<8hex>` id, unique within the store. Seeded from wall clock + pid —
/// offer ids need uniqueness, not unpredictability (the proposal itself
/// carries the cryptographic material).
fn new_offer_id(store: &SwapOfferStore) -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let pid = std::process::id();
    let mut salt = 0u64;
    loop {
        let h = fnv1a64(format!("of:{nanos}:{pid}:{salt}").as_bytes());
        let id = format!("of_{:08x}", (h as u32) ^ ((h >> 32) as u32));
        if !store.offers.iter().any(|o| o.offer.offer_id == id) {
            return id;
        }
        salt += 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Real proposal from the liquidex.it book (offer id 9, mainnet): DBEER
    /// offered for L-BTC. Offline checks pass against this genuine data.
    const PROPOSAL_ID_9: &str = r#"{"version":0,"tx":"02000000010162457676604122dc2c3ab6b9ac5a787411cc90f07edd8651c656fd5ed5dfd45c000000001716001461362b692acf41e26c88c58abcd633cbbe06f420feffffff010b90f4a0ea769100ad4200aabb115f6ead24ba5180eea84f231f3c51c047f02f57092c307774be067befd563d6eb23ca185f963e22f9e96b3f224e94d28ed3cd2fd2020ea96dbab999be940e62be9ff1d8525f354730a3546d71a70696e1f40082996c17a914ea94f77a850e4b018d67c8c4ba087977ec63e1db8700000000000002473044022053a7107a113adffe78e556aa5fa0391b3a2301277630d77febd5398f7a834d520220484feb14c5b0b313759b79501a36d471985b5fe33a346cbcd3d059a0d32214a283210247fa74dbe2fe4f4d0d8e5cc16573f097cb9909670eedd733b50f37e343c9b08a000000","inputs":[{"asset":"002452cb8f56a0a5628240edfb3d1e966c9b1959adcfb95b5726e5e9688611bf","asset_blinder":"10abf182945667b6aae98a79535b91f2343eb6a920d8d99d3de06fa024e38c77","amount_blinder":"6cce12bfa4cd11818de662104e61f6be53275e21c343e984bb06c6749669ad2f","amount":1000}],"outputs":[{"asset":"6f0279e9ed041c3d710a9f57d0c02928416460c4b722ae3457a11eec381c526d","asset_blinder":"e8bfdc63d9750f16a2934b42466c1bfd171e5f3bcd8eafcd9e3ef954cf8a6d58","amount_blinder":"8e2d5cb748d14d5edb06643da6b05208671fbca875682a67690e3436d3ceb22a","amount":1000}]}"#;

    fn fixture_entry_9() -> BookEntry {
        BookEntry {
            id: 9,
            available: true,
            creation_timestamp: "Wed, 09 Jun 2021 16:37:38 GMT".to_string(),
            ratio: 1.0,
            version: 0,
            proposal_json: PROPOSAL_ID_9.to_string(),
            inputs: vec![BookLeg {
                asset: "002452cb8f56a0a5628240edfb3d1e966c9b1959adcfb95b5726e5e9688611bf"
                    .to_string(),
                name: "DBEER - Dex Beer (liquid.beer)".to_string(),
                amount: "10.00".to_string(),
                sats: 1000,
            }],
            outputs: vec![BookLeg {
                asset: "6f0279e9ed041c3d710a9f57d0c02928416460c4b722ae3457a11eec381c526d"
                    .to_string(),
                name: "L-BTC - Liquid Bitcoin ()".to_string(),
                amount: "0.00001000".to_string(),
                sats: 1000,
            }],
        }
    }

    fn broken_entry(id: u64, available: bool) -> BookEntry {
        BookEntry {
            id,
            available,
            creation_timestamp: "Thu, 10 Jun 2021 00:00:00 GMT".to_string(),
            ratio: 2.5,
            version: 0,
            proposal_json: "{ not a proposal".to_string(),
            inputs: Vec::new(),
            outputs: Vec::new(),
        }
    }

    fn test_dir(tag: &str) -> std::path::PathBuf {
        let dir =
            std::env::temp_dir().join(format!("templar_swaps_{}_{}", tag, std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn sample_offer(id: &str, created_at: u64) -> MyOfferDto {
        MyOfferDto {
            offer_id: id.to_string(),
            kind: "swap".to_string(),
            status: "open".to_string(),
            created_at,
            offers: SwapLegDto {
                asset_id: "aa".repeat(32),
                ticker: "AAAAAAAA".to_string(),
                amount_sats: 1000,
                display_amount: "0.00001000".to_string(),
            },
            wants: SwapLegDto {
                asset_id: templar_core::LBTC_TESTNET_ASSET_ID.to_string(),
                ticker: "L-BTC".to_string(),
                amount_sats: 500,
                display_amount: "0.00000500".to_string(),
            },
            proposal_json: PROPOSAL_ID_9.to_string(),
            utxo: format!("{}:0", "cc".repeat(32)),
        }
    }

    #[test]
    fn book_row_maps_real_entry() {
        let row = book_row(&fixture_entry_9());
        assert_eq!(row.id, 9);
        assert!(row.available);
        // Taker orientation: receive = maker input, pay = maker output.
        assert_eq!(row.receive.ticker, "DBEER");
        assert_eq!(row.receive.amount_sats, 1000);
        assert_eq!(row.receive.display_amount, "10.00");
        assert_eq!(row.pay.ticker, "L-BTC");
        assert_eq!(row.pay.display_amount, "0.00001000");
        assert_eq!(row.price, 1.0);
        assert_eq!(row.price_display, "1.00000000 L-BTC/DBEER");
        assert_eq!(row.created, "Wed, 09 Jun 2021 16:37:38 GMT");
        // Real mainnet data: offline checks pass, but a mainnet order is
        // never takeable by this testnet-signing wallet.
        assert!(row.verified, "offline checks must pass on real data");
        assert!(row.verify_note.is_none());
        assert_eq!(row.network, "mainnet");
        assert!(!row.takeable);
        assert_eq!(row.kind, "swap");
        assert_eq!(row.proposal_json, PROPOSAL_ID_9);
    }

    #[test]
    fn unparseable_proposal_is_listed_but_unverified() {
        let row = book_row(&broken_entry(3, true));
        assert!(!row.verified);
        assert!(!row.takeable);
        assert!(row.verify_note.is_some());
        assert_eq!(row.network, "unknown");
        // Missing legs degrade to empty placeholders, not a panic.
        assert_eq!(row.receive.asset_id, "");
        assert_eq!(row.pay.amount_sats, 0);
    }

    #[test]
    fn rows_sort_available_first_then_id_desc() {
        let mut old_available = fixture_entry_9();
        old_available.id = 2;
        let entries = vec![
            broken_entry(7, false),
            old_available,
            fixture_entry_9(), // id 9, available
            broken_entry(11, false),
        ];
        let ids: Vec<(u64, bool)> = rows_from_entries(&entries)
            .iter()
            .map(|r| (r.id, r.available))
            .collect();
        assert_eq!(ids, vec![(9, true), (2, true), (11, false), (7, false)]);
    }

    #[test]
    fn swap_row_wire_shape_matches_contract_keys() {
        let v = serde_json::to_value(book_row(&fixture_entry_9())).unwrap();
        for key in [
            "id",
            "available",
            "receive",
            "pay",
            "price",
            "price_display",
            "created",
            "verified",
            "verify_note",
            "proposal_json",
            "network",
            "takeable",
            "kind",
        ] {
            assert!(v.get(key).is_some(), "missing key {key}");
        }
        for key in ["asset_id", "ticker", "amount_sats", "display_amount"] {
            assert!(v["receive"].get(key).is_some(), "missing leg key {key}");
        }
        assert_eq!(v["kind"], "swap");
        assert!(v["verify_note"].is_null());
    }

    #[test]
    fn analysis_enriches_legs_via_registry() {
        let registry = AssetRegistry::with_defaults();
        let proposal = LiquidexProposal::from_json(PROPOSAL_ID_9).unwrap();
        let result = verify_proposal(&proposal, false).unwrap();
        let dto = analysis_dto(&registry, &result);
        assert!(dto.valid);
        assert_eq!(dto.network, "mainnet");
        assert!(!dto.takeable);
        assert_eq!(dto.checks.len(), 6);
        // Mainnet assets are unknown to the testnet registry: prefix ticker
        // + 8-decimal fallback formatting.
        assert_eq!(dto.maker_offers.ticker, "002452cb");
        assert_eq!(dto.maker_offers.display_amount, "0.00001000");
        assert_eq!(dto.maker_offers.amount_sats, 1000);
        // A testnet L-BTC leg resolves through the registry defaults.
        let lbtc = registry_leg(
            &registry,
            &SwapLeg {
                asset_id: templar_core::LBTC_TESTNET_ASSET_ID.to_string(),
                amount_sats: 12_345,
            },
        );
        assert_eq!(lbtc.ticker, "L-BTC");
        assert_eq!(lbtc.display_amount, "0.00012345");
    }

    #[test]
    fn store_round_trips_atomically_per_wallet() {
        let dir = test_dir("roundtrip");
        // Missing file = empty store.
        assert!(load_store(&dir).unwrap().offers.is_empty());

        let mut store = SwapOfferStore::default();
        store.offers.push(StoredOffer {
            wallet_id: "w1".to_string(),
            offer: sample_offer("of_00000001", 100),
        });
        store.offers.push(StoredOffer {
            wallet_id: "w2".to_string(),
            offer: sample_offer("of_00000002", 200),
        });
        save_store(&dir, &store).unwrap();
        assert!(dir.join(STORE_FILE).exists());
        assert!(!dir.join("swap_offers.tmp").exists());

        let reloaded = load_store(&dir).unwrap();
        assert_eq!(reloaded.offers.len(), 2);
        assert_eq!(reloaded.offers[0].wallet_id, "w1");
        assert_eq!(reloaded.offers[0].offer.offer_id, "of_00000001");
        assert_eq!(reloaded.offers[0].offer.status, "open");
        assert_eq!(reloaded.offers[0].offer.offers.ticker, "AAAAAAAA");
        assert_eq!(reloaded.offers[1].offer.created_at, 200);

        // The stored record flattens the DTO next to wallet_id — the wire
        // shape (no wallet_id) survives the round-trip intact.
        let raw: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(dir.join(STORE_FILE)).unwrap()).unwrap();
        let first = &raw["offers"][0];
        for key in [
            "wallet_id",
            "offer_id",
            "kind",
            "status",
            "created_at",
            "offers",
            "wants",
            "proposal_json",
            "utxo",
        ] {
            assert!(first.get(key).is_some(), "missing stored key {key}");
        }
        let wire = serde_json::to_value(&reloaded.offers[0].offer).unwrap();
        assert!(wire.get("wallet_id").is_none());
        assert_eq!(wire["offer_id"], "of_00000001");

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn corrupt_store_is_a_clear_error() {
        let dir = test_dir("corrupt");
        fs::write(dir.join(STORE_FILE), "{ not json").unwrap();
        let err = load_store(&dir).unwrap_err();
        assert!(err.contains("corrupt"));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn offer_ids_are_unique_and_well_formed() {
        let mut store = SwapOfferStore::default();
        let id1 = new_offer_id(&store);
        assert!(id1.starts_with("of_"));
        assert_eq!(id1.len(), 11);
        assert!(id1[3..].chars().all(|c| c.is_ascii_hexdigit()));
        store.offers.push(StoredOffer {
            wallet_id: "w".to_string(),
            offer: sample_offer(&id1, 1),
        });
        let id2 = new_offer_id(&store);
        assert_ne!(id1, id2);
    }

    #[test]
    fn book_url_honors_env_and_all_suffix() {
        // Only the default path is asserted — mutating the process env in a
        // parallel test runner would race other tests.
        assert_eq!(book_url(false), DEFAULT_BOOK_URL);
        assert_eq!(book_url(true), format!("{DEFAULT_BOOK_URL}?all"));
    }
}
