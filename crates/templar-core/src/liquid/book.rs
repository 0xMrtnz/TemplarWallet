//! liquidex.it order-book client — read-only fetch and parse of `/api/book`.
//!
//! The book is a JSON map keyed by offer id; each entry embeds the raw
//! LiquiDEX v0 proposal string plus display legs (what the maker offers and
//! wants). This module only fetches and parses — proposal verification and
//! the make/take engine live in `liquid::liquidex`.
//!
//! No network access happens outside [`fetch_book`]; parsing is pure so the
//! wire format is unit-testable offline.

use std::collections::BTreeMap;
use std::time::Duration;

use serde::Deserialize;
use thiserror::Error;

/// Default public order book (mainnet, read-only browsing).
pub const DEFAULT_BOOK_URL: &str = "https://liquidex.it/api/book";

/// Errors from fetching or decoding the order book.
#[derive(Debug, Error)]
pub enum BookError {
    #[error("Order book request failed: {0}")]
    Network(String),

    #[error("Order book returned HTTP {0}")]
    Http(u16),

    #[error("Order book response could not be parsed: {0}")]
    Parse(String),
}

/// One display leg of a book entry (maker's input or output side).
#[derive(Debug, Clone, PartialEq)]
pub struct BookLeg {
    /// Asset id (hex).
    pub asset: String,
    /// Display name, e.g. `"DBEER - Dex Beer (liquid.beer)"`.
    pub name: String,
    /// Human display amount as published, e.g. `"10.00"`.
    pub amount: String,
    /// Amount in satoshi-precision units.
    pub sats: u64,
}

impl BookLeg {
    /// Ticker derived from the display name: first `" - "`-separated token,
    /// trimmed. Falls back to the first 8 hex chars of the asset id when the
    /// name is empty (the book's names are free text and mainnet assets are
    /// not in the testnet `AssetRegistry`).
    pub fn ticker(&self) -> String {
        let first = self.name.split(" - ").next().map(str::trim).unwrap_or("");
        if !first.is_empty() {
            return first.to_string();
        }
        self.asset.chars().take(8).collect()
    }
}

/// One offer as published in the book.
#[derive(Debug, Clone, PartialEq)]
pub struct BookEntry {
    pub id: u64,
    /// Whether the offer is still takeable according to the book operator.
    pub available: bool,
    /// RFC-1123 timestamp string, as published (e.g. `"Wed, 09 Jun 2021 16:37:38 GMT"`).
    pub creation_timestamp: String,
    /// Book-computed price ratio (input sats / output sats).
    pub ratio: f64,
    /// LiquiDEX proposal version (0 for everything on liquidex.it today).
    pub version: u32,
    /// Raw embedded LiquiDEX v0 proposal JSON (the book's `json` field),
    /// passed through verbatim for the verify/take engine.
    pub proposal_json: String,
    /// What the maker spends (= what the taker receives).
    pub inputs: Vec<BookLeg>,
    /// What the maker wants (= what the taker pays).
    pub outputs: Vec<BookLeg>,
}

/// Fetches and parses the order book at `url` (10 s timeout).
///
/// The caller decides the URL — `TEMPLAR_SWAP_BOOK_URL` override and the
/// `?all` suffix for unavailable offers are the FFI layer's concern.
pub fn fetch_book(url: &str) -> Result<Vec<BookEntry>, BookError> {
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()
        .map_err(|e| BookError::Network(e.to_string()))?;
    let resp = client
        .get(url)
        .send()
        .map_err(|e| BookError::Network(e.to_string()))?;
    let status = resp.status();
    if !status.is_success() {
        return Err(BookError::Http(status.as_u16()));
    }
    let body = resp.text().map_err(|e| BookError::Network(e.to_string()))?;
    parse_book(&body)
}

/// Parses the raw `/api/book` JSON (a map keyed by offer id) into entries
/// sorted by ascending id.
pub fn parse_book(raw: &str) -> Result<Vec<BookEntry>, BookError> {
    let map: BTreeMap<String, RawEntry> =
        serde_json::from_str(raw).map_err(|e| BookError::Parse(e.to_string()))?;
    let mut entries: Vec<BookEntry> = map.into_values().map(BookEntry::from_raw).collect();
    entries.sort_by_key(|e| e.id);
    Ok(entries)
}

impl BookEntry {
    fn from_raw(raw: RawEntry) -> Self {
        BookEntry {
            id: raw.id,
            available: raw.available.truthy(),
            creation_timestamp: raw.creation_timestamp,
            ratio: raw.ratio,
            version: raw.version,
            proposal_json: raw.json,
            inputs: raw.input.into_iter().map(BookLeg::from_raw).collect(),
            outputs: raw.output.into_iter().map(BookLeg::from_raw).collect(),
        }
    }
}

impl BookLeg {
    fn from_raw(raw: RawLeg) -> Self {
        BookLeg {
            asset: raw.asset,
            name: raw.name,
            amount: raw.amount.display(),
            sats: raw.sats.as_u64(),
        }
    }
}

// ── Wire format ──────────────────────────────────────────────────────────────
// The live API serializes numbers inconsistently (`sats` as strings,
// `available` as 0/1); every field is optional-with-default so one malformed
// entry cannot take down the whole book.

#[derive(Deserialize)]
struct RawEntry {
    #[serde(default)]
    id: u64,
    #[serde(default)]
    available: Flag,
    #[serde(default)]
    creation_timestamp: String,
    #[serde(default)]
    ratio: f64,
    #[serde(default)]
    version: u32,
    #[serde(default)]
    json: String,
    #[serde(default)]
    input: Vec<RawLeg>,
    #[serde(default)]
    output: Vec<RawLeg>,
}

#[derive(Deserialize)]
struct RawLeg {
    #[serde(default)]
    amount: Loose,
    #[serde(default)]
    asset: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    sats: Loose,
}

/// `0`/`1` today; tolerate a plain bool if the API ever changes.
#[derive(Deserialize)]
#[serde(untagged)]
enum Flag {
    Num(i64),
    Bool(bool),
}

impl Flag {
    fn truthy(&self) -> bool {
        match self {
            Flag::Num(n) => *n != 0,
            Flag::Bool(b) => *b,
        }
    }
}

impl Default for Flag {
    fn default() -> Self {
        Flag::Num(0)
    }
}

/// A value the API serializes as either a JSON number or a numeric string.
#[derive(Deserialize)]
#[serde(untagged)]
enum Loose {
    Uint(u64),
    Float(f64),
    Text(String),
}

impl Loose {
    fn as_u64(&self) -> u64 {
        match self {
            Loose::Uint(n) => *n,
            Loose::Float(f) => *f as u64,
            Loose::Text(s) => s.trim().parse().unwrap_or(0),
        }
    }

    fn display(&self) -> String {
        match self {
            Loose::Uint(n) => n.to_string(),
            Loose::Float(f) => f.to_string(),
            Loose::Text(s) => s.trim().to_string(),
        }
    }
}

impl Default for Loose {
    fn default() -> Self {
        Loose::Text(String::new())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Trimmed live capture of `https://liquidex.it/api/book` (entries 9 and
    /// 10, `qr` field dropped). Entry 10's embedded proposal ends in a
    /// literal `\r\n` exactly as served — keep it, it exercises tolerance.
    const FIXTURE: &str = r#"{"10": {"available": 1, "creation_timestamp": "Tue, 15 Jun 2021 18:39:17 GMT", "id": 10, "input": [{"amount": "0.50", "asset": "007d5786a087a588d898101193a81502c4a90dbaaa381d0886b9094490c40043", "name": "BLA - Blanche pint (liquid.beer)", "sats": "50", "url": "https://blockstream.info/liquid"}], "json": "{\"version\":0,\"tx\":\"0200000001018c854e7947d7b217c212fe303c59c48ec5bd3d912d93bf431545d3a4ccfa83400000000017160014d475f708a1ac5f6f0059c6cfdc5281ce32c6afe0feffffff010a3ba5ad74e6a5564c2fe01832c70b4ba335320137a2cc805030019c26027c524a085bc00cc2f8158ad0522717be02e820893a298a90e1a9ecfd663b0c668164ba790281ddf8237face29df64db2277995cd15b3a29ba7f78e97af93abf6a54082f21217a9140a9bfee67d5cd588db243ba4b46b9a5e642b74d88700000000000002483045022100c6f351690abb1a8d67188104b509c2e71f9830bb00f733aca1a2d5e17df08388022022aaf42ae372f60b664be54bf12b3e076fe5b1a757f33326c464e3b9c41c8c528321023b8410c49299514688ec90fd445208cc3aa07ee22420267f23c5c37529feb169000000\",\"inputs\":[{\"asset\":\"007d5786a087a588d898101193a81502c4a90dbaaa381d0886b9094490c40043\",\"asset_blinder\":\"abf52059c3df230ddef4965bfafbf6c62e467959d2e3d9c616a59da0d977c430\",\"amount_blinder\":\"87677cc1f6cb913a91846a069f30f883175c71e1a78bf08b4ddd157914703c2a\",\"amount\":50}],\"outputs\":[{\"asset\":\"beebee1a548fbb20280e539b697de076d87859a25c2983ebc55f2d8bec40abc3\",\"asset_blinder\":\"dcc1f1139633722240eddf372b00d7ad2dd3ea4603f11bbb8edcda0a4d6bc03b\",\"amount_blinder\":\"ab1eb686049ca93198c6107ee99e36a7de91ed77a80f2afd10fe720b8c5ff38b\",\"amount\":500}]}\r\n", "output": [{"amount": "5.00", "asset": "beebee1a548fbb20280e539b697de076d87859a25c2983ebc55f2d8bec40abc3", "name": "IPA - IPA pint - liquid.beer (liquid.beer)", "sats": "500", "url": "https://blockstream.info/liquid"}], "ratio": 10.0, "version": 0}, "9": {"available": 1, "creation_timestamp": "Wed, 09 Jun 2021 16:37:38 GMT", "id": 9, "input": [{"amount": "10.00", "asset": "002452cb8f56a0a5628240edfb3d1e966c9b1959adcfb95b5726e5e9688611bf", "name": "DBEER - Dex Beer (liquid.beer)", "sats": "1000", "url": "https://blockstream.info/liquid"}], "json": "{\"version\":0,\"tx\":\"02000000010162457676604122dc2c3ab6b9ac5a787411cc90f07edd8651c656fd5ed5dfd45c000000001716001461362b692acf41e26c88c58abcd633cbbe06f420feffffff010b90f4a0ea769100ad4200aabb115f6ead24ba5180eea84f231f3c51c047f02f57092c307774be067befd563d6eb23ca185f963e22f9e96b3f224e94d28ed3cd2fd2020ea96dbab999be940e62be9ff1d8525f354730a3546d71a70696e1f40082996c17a914ea94f77a850e4b018d67c8c4ba087977ec63e1db8700000000000002473044022053a7107a113adffe78e556aa5fa0391b3a2301277630d77febd5398f7a834d520220484feb14c5b0b313759b79501a36d471985b5fe33a346cbcd3d059a0d32214a283210247fa74dbe2fe4f4d0d8e5cc16573f097cb9909670eedd733b50f37e343c9b08a000000\",\"inputs\":[{\"asset\":\"002452cb8f56a0a5628240edfb3d1e966c9b1959adcfb95b5726e5e9688611bf\",\"asset_blinder\":\"10abf182945667b6aae98a79535b91f2343eb6a920d8d99d3de06fa024e38c77\",\"amount_blinder\":\"6cce12bfa4cd11818de662104e61f6be53275e21c343e984bb06c6749669ad2f\",\"amount\":1000}],\"outputs\":[{\"asset\":\"6f0279e9ed041c3d710a9f57d0c02928416460c4b722ae3457a11eec381c526d\",\"asset_blinder\":\"e8bfdc63d9750f16a2934b42466c1bfd171e5f3bcd8eafcd9e3ef954cf8a6d58\",\"amount_blinder\":\"8e2d5cb748d14d5edb06643da6b05208671fbca875682a67690e3436d3ceb22a\",\"amount\":1000}]}", "output": [{"amount": "0.00001000", "asset": "6f0279e9ed041c3d710a9f57d0c02928416460c4b722ae3457a11eec381c526d", "name": "L-BTC - Liquid Bitcoin ()", "sats": "1000", "url": "https://blockstream.info/liquid"}], "ratio": 1.0000000000000002e-06, "version": 0}}"#;

    const MAINNET_LBTC: &str = "6f0279e9ed041c3d710a9f57d0c02928416460c4b722ae3457a11eec381c526d";

    #[test]
    fn parses_live_fixture() {
        let entries = parse_book(FIXTURE).expect("fixture must parse");
        assert_eq!(entries.len(), 2);
        // Sorted by numeric id, not by string key ("10" < "9" lexically).
        assert_eq!(entries[0].id, 9);
        assert_eq!(entries[1].id, 10);

        let e9 = &entries[0];
        assert!(e9.available);
        assert_eq!(e9.version, 0);
        assert_eq!(e9.creation_timestamp, "Wed, 09 Jun 2021 16:37:38 GMT");
        assert!((e9.ratio - 1.0e-6).abs() < 1e-12);
        assert_eq!(e9.inputs.len(), 1);
        assert_eq!(e9.outputs.len(), 1);
        assert_eq!(e9.inputs[0].ticker(), "DBEER");
        assert_eq!(e9.inputs[0].sats, 1000);
        assert_eq!(e9.inputs[0].amount, "10.00");
        assert_eq!(e9.outputs[0].ticker(), "L-BTC");
        assert_eq!(e9.outputs[0].asset, MAINNET_LBTC);
        assert_eq!(e9.outputs[0].sats, 1000);

        let e10 = &entries[1];
        assert!(e10.available);
        assert_eq!(e10.inputs[0].ticker(), "BLA");
        assert_eq!(e10.inputs[0].sats, 50);
        // Name with several " - " separators still yields the first token.
        assert_eq!(
            e10.outputs[0].name,
            "IPA - IPA pint - liquid.beer (liquid.beer)"
        );
        assert_eq!(e10.outputs[0].ticker(), "IPA");
        assert_eq!(e10.outputs[0].sats, 500);
    }

    #[test]
    fn embedded_proposal_is_valid_v0_json() {
        let entries = parse_book(FIXTURE).unwrap();
        for entry in &entries {
            let v: serde_json::Value =
                serde_json::from_str(&entry.proposal_json).expect("proposal must be JSON");
            assert_eq!(v["version"], 0);
            assert!(v["tx"].as_str().is_some_and(|tx| !tx.is_empty()));
            assert_eq!(v["inputs"].as_array().unwrap().len(), 1);
            assert_eq!(v["outputs"].as_array().unwrap().len(), 1);
        }
        // Maker of entry 9 spends the DBEER prevout embedded in the proposal.
        let v9: serde_json::Value = serde_json::from_str(&entries[0].proposal_json).unwrap();
        assert_eq!(v9["inputs"][0]["asset"], entries[0].inputs[0].asset);
    }

    #[test]
    fn ticker_falls_back_to_asset_prefix() {
        let leg = BookLeg {
            asset: MAINNET_LBTC.into(),
            name: String::new(),
            amount: "1".into(),
            sats: 1,
        };
        assert_eq!(leg.ticker(), "6f0279e9");
        // Whitespace-only first token falls back too.
        let leg = BookLeg {
            name: "   ".into(),
            ..leg
        };
        assert_eq!(leg.ticker(), "6f0279e9");
    }

    #[test]
    fn tolerates_numeric_fields_and_missing_legs() {
        let raw = r#"{
            "1":{"id":1,"available":0,"creation_timestamp":"x","ratio":0.5,"version":0,
                 "json":"{}",
                 "input":[{"amount":2.5,"asset":"abcdef0123456789","name":"","sats":250}],
                 "output":[{"amount":3,"asset":"ff","name":"T - Token","sats":"100"}]},
            "2":{"id":2}
        }"#;
        let entries = parse_book(raw).unwrap();
        assert_eq!(entries.len(), 2);
        let e1 = &entries[0];
        assert!(!e1.available);
        assert_eq!(e1.inputs[0].sats, 250);
        assert_eq!(e1.inputs[0].amount, "2.5");
        assert_eq!(e1.inputs[0].ticker(), "abcdef01");
        assert_eq!(e1.outputs[0].sats, 100);
        assert_eq!(e1.outputs[0].amount, "3");
        assert_eq!(e1.outputs[0].ticker(), "T");
        // Entry with only an id: every field defaults instead of failing.
        let e2 = &entries[1];
        assert!(!e2.available);
        assert!(e2.inputs.is_empty() && e2.outputs.is_empty());
        assert!(e2.proposal_json.is_empty());
    }

    #[test]
    fn parse_error_is_reported_clearly() {
        let err = parse_book("this is not json").unwrap_err();
        assert!(matches!(err, BookError::Parse(_)));
        assert!(err.to_string().contains("could not be parsed"));
    }

    #[test]
    fn empty_book_is_ok() {
        assert!(parse_book("{}").unwrap().is_empty());
    }
}
