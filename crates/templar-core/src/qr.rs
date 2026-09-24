//! BC-UR v2 (BCR-2020-005) codecs for air-gapped QR flows.
//!
//! Four jobs:
//! - `psbt_to_ur_parts` — PSBT → animated `ur:crypto-psbt` fragments for
//!   display as a cycling QR (Jade / SeedSigner / Keystone scan these).
//! - `pset_to_ur_parts` — Liquid PSET → animated `ur:bytes` fragments. The
//!   registry has no PSET type and no signer reads one over QR, so the raw
//!   bytes travel in the generic byte-string UR and are told apart from a
//!   text payload by their `pset\xff` magic. Templar to Templar only.
//! - `decode_ur_parts` — scanned UR fragments (any order, fountain-coded)
//!   → back into a PSBT, a PSET, or an imported account descriptor.
//! - `ur:crypto-account` / `ur:crypto-hdkey` (BCR-2020-015 / -007) → a
//!   watch-only descriptor string, so a signer's xpub QR can create a wallet.
//!
//! Everything is testnet-only, matching the rest of the app: hdkeys are
//! re-encoded as `tpub`, and mainnet keys are rejected downstream by
//! `normalize_watch_only_descriptors`.

use ciborium::value::Value;

use crate::error::{BitcoinError, TemplarError};

/// Outcome of feeding scanned UR fragments to the decoder.
#[derive(Debug, Clone, serde::Serialize)]
pub struct UrDecodeResult {
    /// 0.0–1.0 best-effort progress estimate (fountain decoding is not linear).
    pub progress: f64,
    /// True when the payload is fully reassembled.
    pub complete: bool,
    /// `"psbt"`, `"pset"`, `"descriptor"`, or `""` while incomplete.
    pub kind: String,
    /// Base64 PSBT when `kind == "psbt"`.
    pub psbt_base64: Option<String>,
    /// Base64 PSET when `kind == "pset"`.
    pub pset_base64: Option<String>,
    /// Watch-only descriptor when `kind == "descriptor"`.
    pub descriptor: Option<String>,
    /// The same key as `descriptor`, reduced to `[fingerprint/path]tpub…`,
    /// when the payload carried one. A multisig cosigner slot needs this and
    /// not the descriptor: `build_descriptors` appends its own derivation,
    /// so a `wpkh(...)` wrapper there produces a wallet that cannot open.
    pub keyorigin: Option<String>,
}

impl UrDecodeResult {
    fn incomplete(progress: f64) -> Self {
        Self {
            progress,
            complete: false,
            kind: String::new(),
            psbt_base64: None,
            pset_base64: None,
            descriptor: None,
            keyorigin: None,
        }
    }

    fn psbt(base64: String) -> Self {
        Self {
            progress: 1.0,
            complete: true,
            kind: "psbt".into(),
            psbt_base64: Some(base64),
            pset_base64: None,
            descriptor: None,
            keyorigin: None,
        }
    }

    fn pset(base64: String) -> Self {
        Self {
            progress: 1.0,
            complete: true,
            kind: "pset".into(),
            psbt_base64: None,
            pset_base64: Some(base64),
            descriptor: None,
            keyorigin: None,
        }
    }

    fn descriptor(descriptor: String, keyorigin: Option<String>) -> Self {
        Self {
            progress: 1.0,
            complete: true,
            kind: "descriptor".into(),
            psbt_base64: None,
            pset_base64: None,
            descriptor: Some(descriptor),
            keyorigin,
        }
    }
}

/// Serialization magic of a PSBT (BIP174) and of an Elements PSET.
const PSBT_MAGIC: &[u8] = b"psbt\xff";
const PSET_MAGIC: &[u8] = b"pset\xff";

/// The same two magics as they appear at the head of a base64 text.
const PSBT_B64_HEAD: &str = "cHNidP";
const PSET_B64_HEAD: &str = "cHNldP";

fn encode_b64(bytes: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

fn decode_b64(text: &str, what: &str) -> Result<Vec<u8>, TemplarError> {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD
        .decode(text.trim())
        .map_err(|e| BitcoinError::PsbtError(format!("{what} base64 decode: {e}")).into())
}

// ── Encode: PSBT / PSET → animated UR parts ──────────────────────────────────

/// Encodes a base64 PSBT into a full cycle of `ur:crypto-psbt` fragments.
///
/// The returned list contains every pure fragment plus one extra fountain
/// cycle for redundancy; the UI loops over it (~5–8 fps). Small payloads that
/// fit one QR return a single part.
pub fn psbt_to_ur_parts(
    psbt_base64: &str,
    max_fragment_len: usize,
) -> Result<Vec<String>, TemplarError> {
    let psbt_bytes = decode_b64(psbt_base64, "PSBT")?;
    bytes_to_ur_parts(&psbt_bytes, max_fragment_len, "crypto-psbt")
}

/// Encodes a base64 PSET into a full cycle of `ur:bytes` fragments.
///
/// No registry type exists for an Elements PSET and no hardware signer reads
/// one over QR (Jade's QR mode is Bitcoin-only), so the raw serialized PSET
/// travels in the generic byte-string UR; [`decode_ur_parts`] recognises it
/// by its `pset\xff` magic. The consumer is another Templar — a co-signer's
/// phone across the table scanning the coordinator's animation.
pub fn pset_to_ur_parts(
    pset_base64: &str,
    max_fragment_len: usize,
) -> Result<Vec<String>, TemplarError> {
    let pset_bytes = decode_b64(pset_base64, "PSET")?;
    if !pset_bytes.starts_with(PSET_MAGIC) {
        return Err(BitcoinError::PsbtError(
            "Not a PSET: the payload does not start with the pset magic bytes".into(),
        )
        .into());
    }
    bytes_to_ur_parts(&pset_bytes, max_fragment_len, "bytes")
}

/// The payload wrapped in a CBOR byte string — what both `crypto-psbt` and
/// `bytes` carry — fountain-encoded into a part sequence the UI can loop.
fn bytes_to_ur_parts(
    payload: &[u8],
    max_fragment_len: usize,
    ur_type: &str,
) -> Result<Vec<String>, TemplarError> {
    let mut cbor = Vec::new();
    ciborium::into_writer(&Value::Bytes(payload.to_vec()), &mut cbor)
        .map_err(|e| BitcoinError::PsbtError(format!("CBOR encode: {e}")))?;

    let max_len = max_fragment_len.clamp(30, 500);
    let mut encoder = ur::Encoder::new(&cbor, max_len, ur_type)
        .map_err(|e| BitcoinError::PsbtError(format!("UR encode: {e}")))?;

    // fragment_count() pure parts + one extra fountain round; looping the same
    // pre-generated sequence is indistinguishable from a live encoder to the
    // scanning device.
    let parts_needed = encoder.fragment_count() * 2;
    let mut parts = Vec::with_capacity(parts_needed);
    for _ in 0..parts_needed {
        parts.push(
            encoder
                .next_part()
                .map_err(|e| BitcoinError::PsbtError(format!("UR part: {e}")))?,
        );
    }
    Ok(parts)
}

// ── Decode: scanned parts → PSBT / PSET / descriptor ─────────────────────────

/// Reassembles scanned UR fragments (stateless: pass every part collected so
/// far on each call — n is tiny, rebuilding the decoder is cheap).
///
/// Also accepts a single non-UR text payload: a bare base64 PSBT or PSET is
/// recognised by the base64 of its magic and returned as such; anything else
/// (a QR that just contains a descriptor or xpub) comes back as
/// `kind: "descriptor"` untouched, and validation happens in the existing
/// import normalizer.
pub fn decode_ur_parts(parts: &[String]) -> Result<UrDecodeResult, TemplarError> {
    let invalid = |m: String| -> TemplarError { BitcoinError::PsbtError(m).into() };

    let first = parts
        .iter()
        .find(|p| !p.trim().is_empty())
        .ok_or_else(|| invalid("No QR data".into()))?
        .trim();

    // Plain-text QR (Specter-style descriptor export, bare xpub, a base64
    // transaction as Templar's own text export shows it, …).
    if !first.to_lowercase().starts_with("ur:") {
        if first.starts_with(PSET_B64_HEAD) {
            return Ok(UrDecodeResult::pset(first.to_string()));
        }
        if first.starts_with(PSBT_B64_HEAD) {
            return Ok(UrDecodeResult::psbt(first.to_string()));
        }
        return Ok(UrDecodeResult::descriptor(first.to_string(), None));
    }

    let ur_type = first
        .split('/')
        .next()
        .and_then(|head| head.split(':').nth(1))
        .unwrap_or("")
        .to_lowercase();

    // Single-part URs ("ur:type/payload") have no sequence segment; the
    // multi-part Decoder rejects them, so try a direct decode first.
    let message: Vec<u8> = if parts.len() == 1 && single_part(first) {
        let (_kind, payload) =
            ur::decode(&first.to_lowercase()).map_err(|e| invalid(format!("UR decode: {e:?}")))?;
        payload
    } else {
        let mut decoder = ur::Decoder::default();
        let mut received = 0usize;
        for p in parts {
            let p = p.trim().to_lowercase();
            if p.is_empty() {
                continue;
            }
            // Individual bad frames (mis-scans) are skipped, not fatal.
            if decoder.receive(&p).is_ok() {
                received += 1;
            }
        }
        if !decoder.complete() {
            // Rough progress: fountain decoding needs ~fragment_count distinct
            // parts; derive the target from the sequence header "N-M".
            let target = first
                .split('/')
                .nth(1)
                .and_then(|s| s.split('-').nth(1))
                .and_then(|s| s.parse::<usize>().ok())
                .unwrap_or(received.max(1));
            return Ok(UrDecodeResult::incomplete(
                (received as f64 / target.max(1) as f64).min(0.95),
            ));
        }
        decoder
            .message()
            .map_err(|e| invalid(format!("UR message: {e:?}")))?
            .ok_or_else(|| invalid("UR decoder returned no message".into()))?
    };

    /// The CBOR byte string every payload type here wraps.
    fn byte_string(message: &[u8], label: &str) -> Result<Vec<u8>, TemplarError> {
        let value: Value = ciborium::from_reader(message)
            .map_err(|e| BitcoinError::PsbtError(format!("{label} CBOR: {e}")))?;
        match value {
            Value::Bytes(raw) => Ok(raw),
            _ => {
                Err(BitcoinError::PsbtError(format!("{label} payload is not a byte string")).into())
            }
        }
    }

    match ur_type.as_str() {
        "crypto-psbt" | "psbt" => {
            let psbt = byte_string(&message, "crypto-psbt")?;
            Ok(UrDecodeResult::psbt(encode_b64(&psbt)))
        }
        "crypto-account" | "crypto-hdkey" => {
            let (keyorigin, descriptor) = account_cbor_to_descriptor(&message)?;
            Ok(UrDecodeResult::descriptor(descriptor, Some(keyorigin)))
        }
        // A generic byte string. Templar's own PSET transport (the registry
        // has no type for one), and from a Jade a few text exports (multisig
        // registration files, wallet descriptors) wrapped untyped. The magic
        // bytes say which; anything else that is text is a descriptor.
        "bytes" => {
            let raw = byte_string(&message, "ur:bytes")?;
            if raw.starts_with(PSET_MAGIC) {
                return Ok(UrDecodeResult::pset(encode_b64(&raw)));
            }
            if raw.starts_with(PSBT_MAGIC) {
                return Ok(UrDecodeResult::psbt(encode_b64(&raw)));
            }
            let text = String::from_utf8(raw)
                .map_err(|_| invalid("ur:bytes payload is not text".into()))?;
            Ok(UrDecodeResult::descriptor(text.trim().to_string(), None))
        }
        // The QR a Jade shows while it is still locked. Naming the UR type
        // alone sent people hunting for a Templar bug; the device is simply
        // at an earlier step than the one they think they are on.
        "jade-pin" => Err(invalid(
            "This is the Jade's PIN-unlock QR, not a key — the device is still \
             locked. Unlock it first (QR PIN Unlock with the Blockstream \
             companion page, or a SeedQR), then Options → Wallet → Export Xpub."
                .into(),
        )),
        other if other.starts_with("jade-") => Err(invalid(format!(
            "This QR is part of a Jade device flow (ur:{other}), not a key or a \
             transaction. Finish that flow on the Jade first."
        ))),
        other => Err(invalid(format!(
            "Unsupported QR type \"ur:{other}\". This scanner reads a transaction \
             (ur:crypto-psbt, or a Liquid PSET as ur:bytes) or an account key \
             (ur:crypto-account / ur:crypto-hdkey)."
        ))),
    }
}

fn single_part(part: &str) -> bool {
    // "ur:type/seq/payload" (3 segments) is multi-part; "ur:type/payload" is single.
    part.splitn(3, '/').count() < 3
}

// ── crypto-account / crypto-hdkey → descriptor ───────────────────────────────

/// Extracted fields of a BCR-2020-007 `crypto-hdkey`.
#[derive(Debug, Default, Clone)]
struct HdKey {
    key_data: Vec<u8>,             // 33-byte compressed pubkey
    chain_code: Vec<u8>,           // 32 bytes
    origin_path: Vec<(u32, bool)>, // (index, hardened)
    source_fingerprint: Option<u32>,
    parent_fingerprint: Option<u32>,
    depth: Option<u8>,
}

/// Parses a `crypto-account` (map with output descriptors) or a bare
/// `crypto-hdkey` payload and returns `(keyorigin, descriptor)`: the key as
/// `[fp/84'/1'/0']tpub…`, and the same key as a native-segwit multipath
/// descriptor `wpkh([fp/84'/1'/0']tpub…/<0;1>/*)`.
///
/// Both forms are needed. A watch-only import wants the descriptor; a multisig
/// cosigner slot wants the bare key, because the multisig builder appends its
/// own derivation and would otherwise nest one descriptor inside another.
///
/// Tolerant by design: rather than model the whole registry, walk the CBOR
/// for the first tag-303 (crypto-hdkey) map — inside a wpkh (tag 404) output
/// when one exists — and rebuild the xpub from its fields.
fn account_cbor_to_descriptor(cbor: &[u8]) -> Result<(String, String), TemplarError> {
    let invalid = |m: &str| -> TemplarError {
        BitcoinError::PsbtError(format!("crypto-account: {m}")).into()
    };

    let root: Value =
        ciborium::from_reader(cbor).map_err(|_| invalid("payload is not valid CBOR"))?;

    // Master fingerprint from the account map (key 1), when present.
    let mut account_fp: Option<u32> = None;
    if let Value::Map(entries) = &root {
        for (k, v) in entries {
            if matches!(k, Value::Integer(i) if i128::from(*i) == 1) {
                account_fp = value_to_u32(v);
            }
        }
    }

    // Prefer an hdkey nested inside a wpkh output (tag 404); fall back to the
    // first hdkey found anywhere (bare crypto-hdkey payloads, other scripts).
    let hdkey_value = find_tagged(&root, 404)
        .and_then(|inner| find_tagged(inner, 303).or(Some(inner)))
        .or_else(|| find_tagged(&root, 303))
        .or_else(|| {
            // A bare crypto-hdkey UR has the map at top level, untagged.
            matches!(root, Value::Map(_)).then_some(&root)
        })
        .ok_or_else(|| invalid("no hdkey found"))?;

    let hd = parse_hdkey_map(hdkey_value).ok_or_else(|| invalid("malformed hdkey"))?;
    if hd.key_data.len() != 33 || hd.chain_code.len() != 32 {
        return Err(invalid("hdkey missing 33-byte key or 32-byte chain code"));
    }

    // Rebuild the serialized extended key. Testnet-only app → tpub version.
    let depth = hd.depth.unwrap_or(hd.origin_path.len() as u8);
    let parent_fp = hd.parent_fingerprint.unwrap_or(0);
    let child = hd
        .origin_path
        .last()
        .map(|(i, h)| if *h { 0x8000_0000 | *i } else { *i })
        .unwrap_or(0);

    let mut raw = Vec::with_capacity(78);
    raw.extend_from_slice(&[0x04, 0x35, 0x87, 0xCF]); // tpub
    raw.push(depth);
    raw.extend_from_slice(&parent_fp.to_be_bytes());
    raw.extend_from_slice(&child.to_be_bytes());
    raw.extend_from_slice(&hd.chain_code);
    raw.extend_from_slice(&hd.key_data);
    let tpub = bs58::encode(raw).with_check().into_string();

    let fp = hd
        .source_fingerprint
        .or(account_fp)
        .map(|f| format!("{:08x}", f))
        .unwrap_or_else(|| "00000000".to_string());
    let path = hd
        .origin_path
        .iter()
        .map(|(i, h)| format!("{}{}", i, if *h { "'" } else { "" }))
        .collect::<Vec<_>>()
        .join("/");
    let origin = if path.is_empty() {
        format!("[{fp}]")
    } else {
        format!("[{fp}/{path}]")
    };

    Ok((
        format!("{origin}{tpub}"),
        format!("wpkh({origin}{tpub}/<0;1>/*)"),
    ))
}

/// Depth-first search for the first value wrapped in CBOR tag `tag`.
fn find_tagged(v: &Value, tag: u64) -> Option<&Value> {
    match v {
        Value::Tag(t, inner) => {
            if *t == tag {
                Some(inner)
            } else {
                find_tagged(inner, tag)
            }
        }
        Value::Array(items) => items.iter().find_map(|i| find_tagged(i, tag)),
        Value::Map(entries) => entries.iter().find_map(|(_, val)| find_tagged(val, tag)),
        _ => None,
    }
}

/// Reads the hdkey fields out of a (possibly tagged) CBOR map.
fn parse_hdkey_map(v: &Value) -> Option<HdKey> {
    let v = match v {
        Value::Tag(_, inner) => inner,
        other => other,
    };
    let Value::Map(entries) = v else { return None };

    let mut hd = HdKey::default();
    for (k, val) in entries {
        let Value::Integer(k) = k else { continue };
        match i128::from(*k) {
            3 => {
                if let Value::Bytes(b) = val {
                    hd.key_data = b.clone();
                }
            }
            4 => {
                if let Value::Bytes(b) = val {
                    hd.chain_code = b.clone();
                }
            }
            6 => parse_keypath(val, &mut hd),
            8 => hd.parent_fingerprint = value_to_u32(val),
            _ => {}
        }
    }
    (!hd.key_data.is_empty()).then_some(hd)
}

/// BCR-2020-007 crypto-keypath (tag 304): {1: [idx, hardened, …], 2: source fp, 3: depth}.
fn parse_keypath(v: &Value, hd: &mut HdKey) {
    let v = match v {
        Value::Tag(_, inner) => inner,
        other => other,
    };
    let Value::Map(entries) = v else { return };
    for (k, val) in entries {
        let Value::Integer(k) = k else { continue };
        match i128::from(*k) {
            1 => {
                if let Value::Array(items) = val {
                    let mut i = 0;
                    while i + 1 < items.len() {
                        let idx = value_to_u32(&items[i]);
                        let hardened = matches!(items[i + 1], Value::Bool(b) if b);
                        if let Some(idx) = idx {
                            hd.origin_path.push((idx, hardened));
                        }
                        i += 2;
                    }
                }
            }
            2 => hd.source_fingerprint = value_to_u32(val),
            3 => hd.depth = value_to_u32(val).map(|d| d as u8),
            _ => {}
        }
    }
}

fn value_to_u32(v: &Value) -> Option<u32> {
    match v {
        Value::Integer(i) => u32::try_from(i128::from(*i)).ok(),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Tiny but structurally valid PSBT (magic + separator + empty maps).
    const TEST_PSBT_B64: &str = "cHNidP8BAAoCAAAAAAAAAAAAAAAA";

    #[test]
    fn psbt_ur_roundtrip_single_part() {
        let parts = psbt_to_ur_parts(TEST_PSBT_B64, 500).unwrap();
        assert!(!parts.is_empty());
        assert!(parts[0].starts_with("ur:crypto-psbt/"));
        let out = decode_ur_parts(&parts[..1]).unwrap();
        assert!(out.complete);
        assert_eq!(out.kind, "psbt");
        assert_eq!(out.psbt_base64.unwrap(), TEST_PSBT_B64);
    }

    #[test]
    fn psbt_ur_roundtrip_multipart_fountain() {
        // Force fragmentation with a big payload and a tiny fragment size.
        use base64::Engine;
        let big = base64::engine::general_purpose::STANDARD.encode(vec![0xAB; 900]);
        let parts = psbt_to_ur_parts(&big, 50).unwrap();
        assert!(parts.len() > 4, "expected multipart, got {}", parts.len());

        // Feed parts progressively; must complete within the generated cycle.
        let mut fed: Vec<String> = Vec::new();
        let mut done = None;
        for p in &parts {
            fed.push(p.clone());
            let r = decode_ur_parts(&fed).unwrap();
            if r.complete {
                done = Some(r);
                break;
            }
        }
        let done = done.expect("decoder never completed");
        assert_eq!(done.kind, "psbt");
        assert_eq!(done.psbt_base64.unwrap(), big);
    }

    #[test]
    fn decode_progress_reported_before_complete() {
        use base64::Engine;
        let big = base64::engine::general_purpose::STANDARD.encode(vec![0x77; 600]);
        let parts = psbt_to_ur_parts(&big, 50).unwrap();
        let r = decode_ur_parts(&parts[..1]).unwrap();
        assert!(!r.complete);
        assert!(r.progress > 0.0 && r.progress < 1.0);
    }

    #[test]
    fn plain_text_qr_passes_through_as_descriptor() {
        let desc = "wpkh([f0b68896/84'/1'/0']tpubDCVwWj4hEpeWNFcWe3Eo1DrkLnPC4c2iitjw5wAuTkSZgofJbRMD4KESh1uhsqLCCjcjR36JooEFwfWf1ezwmAfjcPCxc7KNtnfBCrMPdtT/<0;1>/*)".to_string();
        let out = decode_ur_parts(std::slice::from_ref(&desc)).unwrap();
        assert!(out.complete);
        assert_eq!(out.kind, "descriptor");
        assert_eq!(out.descriptor.unwrap(), desc);
    }

    /// Builds a spec-shaped crypto-account payload from a real tpub's fields
    /// and checks the parser reconstructs the same key and origin.
    #[test]
    fn crypto_account_to_descriptor() {
        const TPUB: &str = "tpubDCVwWj4hEpeWNFcWe3Eo1DrkLnPC4c2iitjw5wAuTkSZgofJbRMD4KESh1uhsqLCCjcjR36JooEFwfWf1ezwmAfjcPCxc7KNtnfBCrMPdtT";
        let raw = bs58::decode(TPUB).with_check(None).into_vec().unwrap();
        let (depth, parent_fp) = (raw[4], u32::from_be_bytes(raw[5..9].try_into().unwrap()));
        let chain_code = raw[13..45].to_vec();
        let key_data = raw[45..78].to_vec();
        let master_fp: u32 = 0xf0b68896;

        let keypath = Value::Tag(
            304,
            Box::new(Value::Map(vec![
                (
                    Value::Integer(1.into()),
                    Value::Array(vec![
                        Value::Integer(84.into()),
                        Value::Bool(true),
                        Value::Integer(1.into()),
                        Value::Bool(true),
                        Value::Integer(0.into()),
                        Value::Bool(true),
                    ]),
                ),
                (Value::Integer(2.into()), Value::Integer(master_fp.into())),
                (Value::Integer(3.into()), Value::Integer(depth.into())),
            ])),
        );
        let hdkey = Value::Tag(
            303,
            Box::new(Value::Map(vec![
                (Value::Integer(3.into()), Value::Bytes(key_data)),
                (Value::Integer(4.into()), Value::Bytes(chain_code)),
                (Value::Integer(6.into()), keypath),
                (Value::Integer(8.into()), Value::Integer(parent_fp.into())),
            ])),
        );
        let account = Value::Map(vec![
            (Value::Integer(1.into()), Value::Integer(master_fp.into())),
            (
                Value::Integer(2.into()),
                Value::Array(vec![Value::Tag(404, Box::new(hdkey))]),
            ),
        ]);
        let mut cbor = Vec::new();
        ciborium::into_writer(&account, &mut cbor).unwrap();

        let (keyorigin, desc) = account_cbor_to_descriptor(&cbor).unwrap();
        assert_eq!(desc, format!("wpkh([f0b68896/84'/1'/0']{TPUB}/<0;1>/*)"));
        assert_eq!(keyorigin, format!("[f0b68896/84'/1'/0']{TPUB}"));

        // And the whole thing survives the UR transport + import normalizer.
        let mut encoder = ur::Encoder::new(&cbor, 100, "crypto-account").unwrap();
        let n = encoder.fragment_count() * 2;
        let parts: Vec<String> = (0..n).map(|_| encoder.next_part().unwrap()).collect();
        let out = decode_ur_parts(&parts).unwrap();
        assert!(out.complete);
        let normalized =
            crate::bitcoin::watch_only::normalize_watch_only_descriptors(&out.descriptor.unwrap())
                .unwrap();
        assert!(normalized.0.contains(TPUB));
        assert!(normalized.0.ends_with("/0/*)"));

        // The cosigner path: the scan must yield a bare key the multisig
        // builder can use, not the descriptor it also returns.
        let keyorigin = out.keyorigin.expect("crypto-account carries a keyorigin");
        assert_eq!(keyorigin, format!("[f0b68896/84'/1'/0']{TPUB}"));
        assert!(!keyorigin.contains("wpkh("));
    }

    #[test]
    fn locked_jade_pin_qr_says_what_to_do() {
        let payload = b"not a key, a pin handshake".to_vec();
        let mut cbor = Vec::new();
        ciborium::into_writer(&Value::Bytes(payload), &mut cbor).unwrap();
        let mut encoder = ur::Encoder::new(&cbor, 100, "jade-pin").unwrap();
        let parts: Vec<String> = (0..encoder.fragment_count() * 2)
            .map(|_| encoder.next_part().unwrap())
            .collect();

        let e = decode_ur_parts(&parts).unwrap_err().to_string();
        assert!(e.contains("still locked"), "{e}");
        assert!(e.contains("Export Xpub"), "{e}");
        assert!(!e.contains("crypto-psbt"), "no jargon-only message: {e}");
    }

    #[test]
    fn ur_bytes_payload_comes_back_as_text() {
        let text = "wsh(sortedmulti(2,[f0b68896/48'/1'/0'/2']tpubA/0/*))";
        let mut cbor = Vec::new();
        ciborium::into_writer(&Value::Bytes(text.as_bytes().to_vec()), &mut cbor).unwrap();
        let mut encoder = ur::Encoder::new(&cbor, 100, "bytes").unwrap();
        let parts: Vec<String> = (0..encoder.fragment_count() * 2)
            .map(|_| encoder.next_part().unwrap())
            .collect();

        let out = decode_ur_parts(&parts).unwrap();
        assert_eq!(out.kind, "descriptor");
        assert_eq!(out.descriptor.unwrap(), text);
    }

    // Structurally a PSET as far as the magic goes: `pset\xff` + padding.
    fn pset_like(len: usize) -> String {
        let mut raw = PSET_MAGIC.to_vec();
        raw.extend(std::iter::repeat_n(0x5A, len));
        encode_b64(&raw)
    }

    #[test]
    fn pset_ur_roundtrip_single_part() {
        let pset = pset_like(8);
        let parts = pset_to_ur_parts(&pset, 500).unwrap();
        assert_eq!(parts.len(), 2, "one pure part + one fountain round");
        assert!(parts[0].starts_with("ur:bytes/"), "{}", parts[0]);
        let out = decode_ur_parts(&parts[..1]).unwrap();
        assert!(out.complete);
        assert_eq!(out.kind, "pset");
        assert_eq!(out.pset_base64.unwrap(), pset);
        assert!(out.psbt_base64.is_none());
        assert!(out.descriptor.is_none());
    }

    #[test]
    fn pset_ur_roundtrip_multipart_fountain() {
        let pset = pset_like(900);
        let parts = pset_to_ur_parts(&pset, 50).unwrap();
        assert!(parts.len() > 4, "expected multipart, got {}", parts.len());
        let mut fed: Vec<String> = Vec::new();
        let mut done = None;
        for p in &parts {
            fed.push(p.clone());
            let r = decode_ur_parts(&fed).unwrap();
            if r.complete {
                done = Some(r);
                break;
            }
        }
        let done = done.expect("decoder never completed");
        assert_eq!(done.kind, "pset");
        assert_eq!(done.pset_base64.unwrap(), pset);
    }

    #[test]
    fn pset_encoder_refuses_a_psbt() {
        let e = pset_to_ur_parts(TEST_PSBT_B64, 100)
            .unwrap_err()
            .to_string();
        assert!(e.contains("Not a PSET"), "{e}");
    }

    #[test]
    fn ur_bytes_carrying_a_psbt_is_sniffed_as_one() {
        use base64::Engine;
        let raw = base64::engine::general_purpose::STANDARD
            .decode(TEST_PSBT_B64)
            .unwrap();
        let parts = bytes_to_ur_parts(&raw, 100, "bytes").unwrap();
        let out = decode_ur_parts(&parts).unwrap();
        assert_eq!(out.kind, "psbt");
        assert_eq!(out.psbt_base64.unwrap(), TEST_PSBT_B64);
    }

    #[test]
    fn plain_text_base64_transactions_are_typed_by_their_magic() {
        let pset = pset_like(4);
        let out = decode_ur_parts(std::slice::from_ref(&pset)).unwrap();
        assert_eq!(out.kind, "pset");
        assert_eq!(out.pset_base64.unwrap(), pset);

        let out = decode_ur_parts(&[TEST_PSBT_B64.to_string()]).unwrap();
        assert_eq!(out.kind, "psbt");
        assert_eq!(out.psbt_base64.unwrap(), TEST_PSBT_B64);
    }
}
