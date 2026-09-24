//! Hermetic contract tests for the JSON FFI surface.
//!
//! These drive `dispatch::dispatch()` — the same router the C `wallet_call`
//! entry point uses — against a throwaway data directory per test, fully
//! offline (nothing here calls `sync_wallet` or touches an Electrum server).
//!
//! The key assertions mirror the exact JSON keys the Dart decode sites read
//! (`src/templar_wallet/lib/bridge/ffi_wallet_bridge.dart` and the model
//! `fromJson` factories), so a shape drift on either side of the boundary
//! fails here before it ships — a decode-shape bug already shipped once
//! (commit 0b75bd9).

use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};

use crate::dispatch::dispatch;
use crate::state::AppFfiState;

/// Standard BIP39 test vector. Master fingerprint: 73c5da0a.
const MNEMONIC: &str = "abandon abandon abandon abandon abandon abandon abandon \
                        abandon abandon abandon abandon about";

static DIR_SEQ: AtomicU32 = AtomicU32::new(0);

/// Per-test state bound to a unique temp data dir. `AppFfiState` takes an
/// exclusive per-data-dir file lock, so unique dirs keep the parallel test
/// runner from colliding; the dir is removed (best-effort) on drop.
struct TestEnv {
    state: AppFfiState,
    dir: PathBuf,
}

impl TestEnv {
    fn new() -> Self {
        let mut env = Self::new_without_vault();
        // Production never stores a seed without a vault (A2), so neither does
        // the harness: `create_wallet` is refused on an unencrypted install.
        // Built directly with cheap KDF parameters — going through
        // `vault::setup` would spend 64 MiB and half a second of Argon2 per
        // test for no extra coverage.
        if env.state.startup_error.is_none() {
            let (vault, header) = templar_core::Vault::create_with_params(
                "contract-test-passphrase",
                templar_core::KdfParams::FAST_FOR_TESTS,
            )
            .expect("test vault");
            templar_core::registry::save_vault_header(&env.dir, &header)
                .expect("test vault header");
            env.state
                .registry
                .save_with_vault(&env.dir, Some(&vault))
                .expect("seal test registry");
            env.state.vault = Some(vault);
        }
        env
    }

    /// A fresh install with no vault at all — what the app sees before the
    /// user has ever set an app password.
    fn new_without_vault() -> Self {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .subsec_nanos();
        let dir = std::env::temp_dir().join(format!(
            "templar-ffi-contract-{}-{}-{}",
            std::process::id(),
            DIR_SEQ.fetch_add(1, Ordering::Relaxed),
            nanos,
        ));
        std::fs::create_dir_all(&dir).expect("create test data dir");
        let state = AppFfiState::new_for_test(dir.clone());
        Self { state, dir }
    }

    /// Raw dispatch — returns the full `{"ok": ...}` / `{"err": ...}` envelope.
    fn call(&mut self, method: &str, params: Value) -> Value {
        dispatch(&mut self.state, method, &params)
    }

    /// Dispatch that must succeed; returns the `ok` payload.
    fn ok(&mut self, method: &str, params: Value) -> Value {
        let resp = self.call(method, params);
        assert!(
            resp.get("err").is_none(),
            "{method} unexpectedly failed: {resp}"
        );
        resp.get("ok")
            .cloned()
            .unwrap_or_else(|| panic!("{method} response has neither ok nor err: {resp}"))
    }

    /// Dispatch that must fail; returns the `err` message.
    fn err(&mut self, method: &str, params: Value) -> String {
        let resp = self.call(method, params);
        assert!(
            resp.get("ok").is_none(),
            "{method} unexpectedly succeeded: {resp}"
        );
        resp["err"]
            .as_str()
            .unwrap_or_else(|| panic!("{method} err is not a string: {resp}"))
            .to_string()
    }

    /// Creates a Bitcoin-only software wallet from the test mnemonic and
    /// returns its id.
    fn create_test_wallet(&mut self) -> String {
        let created = self.ok(
            "create_wallet",
            json!({ "name": "Contract Test", "mnemonic": MNEMONIC, "liquid": false }),
        );
        created["id"]
            .as_str()
            .expect("create_wallet ok payload must carry a string id")
            .to_string()
    }
}

impl Drop for TestEnv {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// Every listed key must be present on the object (value may be null — the
/// Dart mappers handle null, but a *missing* key means the shapes diverged).
fn assert_keys(context: &str, obj: &Value, keys: &[&str]) {
    let map = obj
        .as_object()
        .unwrap_or_else(|| panic!("{context}: expected a JSON object, got {obj}"));
    for key in keys {
        assert!(
            map.contains_key(*key),
            "{context}: missing key {key:?} in {obj}"
        );
    }
}

// ── Registry ─────────────────────────────────────────────────────────────────

#[test]
fn generate_mnemonic_word_counts() {
    let mut env = TestEnv::new();
    for count in [12usize, 24] {
        let words = env.ok("generate_mnemonic", json!({ "word_count": count }));
        let words = words.as_array().expect("generate_mnemonic returns a list");
        assert_eq!(words.len(), count, "wrong word count");
        assert!(
            words
                .iter()
                .all(|w| w.as_str().is_some_and(|s| !s.is_empty())),
            "every word must be a non-empty string: {words:?}"
        );
    }
}

#[test]
fn create_wallet_then_list_wallets_roundtrip() {
    let mut env = TestEnv::new();
    let id = env.create_test_wallet();
    assert!(!id.is_empty());

    let listed = env.ok("list_wallets", json!({}));
    let listed = listed.as_array().expect("list_wallets returns a list");
    assert_eq!(listed.len(), 1, "exactly the created wallet: {listed:?}");

    let w = &listed[0];
    // Exact keys WalletSummary.fromJson reads (wallet_summary.dart).
    assert_keys(
        "list_wallets[0]",
        w,
        &[
            "id",
            "name",
            "wallet_type",
            "network",
            "balance_sats",
            "tx_count",
            "last_sync_at",
            "is_watch_only",
            "type_label",
            "liquid_enabled",
            "master_fingerprint",
            "xpub",
            "required_sigs",
            "total_signers",
        ],
    );
    assert_eq!(w["id"], json!(id));
    assert_eq!(w["name"], json!("Contract Test"));
    assert_eq!(w["wallet_type"], json!("singlesig"));
    assert_eq!(w["network"], json!("testnet"));
    assert_eq!(w["is_watch_only"], json!(false));
    assert_eq!(w["liquid_enabled"], json!(false));
    assert_eq!(w["master_fingerprint"], json!("73c5da0a"));
    assert!(
        w["xpub"].as_str().unwrap_or("").starts_with("tpub"),
        "testnet account xpub expected: {}",
        w["xpub"]
    );
}

#[test]
fn create_wallet_rejects_invalid_mnemonic() {
    let mut env = TestEnv::new();
    let err = env.err(
        "create_wallet",
        json!({ "name": "Broken", "mnemonic": "not a valid seed phrase at all", "liquid": false }),
    );
    assert!(!err.is_empty());
    // A rejected create must not leave an orphan registry entry (N2).
    let listed = env.ok("list_wallets", json!({}));
    assert_eq!(listed.as_array().map(Vec::len), Some(0));
}

// ── Wallet lifecycle + addresses (offline) ───────────────────────────────────

#[test]
fn open_wallet_and_generate_receive_address_offline() {
    let mut env = TestEnv::new();
    let id = env.create_test_wallet();

    let opened = env.ok("open_wallet", json!({ "wallet_id": id }));
    assert!(opened.is_null(), "open_wallet returns null, got {opened}");

    let first = env.ok(
        "generate_receive_address",
        json!({ "wallet_id": id, "asset": "BTC" }),
    );
    // Exact keys _addressInfoFromJson reads (ffi_wallet_bridge.dart).
    assert_keys(
        "generate_receive_address",
        &first,
        &[
            "address",
            "index",
            "asset",
            "label",
            "received_sats",
            "derivation_path",
        ],
    );
    let first_addr = first["address"].as_str().unwrap_or("");
    assert!(
        first_addr.starts_with("tb1"),
        "testnet bech32 address expected: {first_addr:?}"
    );
    assert_eq!(first["asset"], json!("BTC"));
    let first_index = first["index"].as_u64().expect("index is a number");

    // `fresh` must advance the derivation index even though the current
    // address was never used (commit f88de7b behavior).
    let fresh = env.ok(
        "generate_receive_address",
        json!({ "wallet_id": id, "asset": "BTC", "fresh": true }),
    );
    let fresh_addr = fresh["address"].as_str().unwrap_or("");
    assert!(fresh_addr.starts_with("tb1"));
    assert_ne!(fresh_addr, first_addr, "fresh must hand out a new address");
    assert!(
        fresh["index"].as_u64().expect("index is a number") > first_index,
        "fresh must advance the index: first={first}, fresh={fresh}"
    );
}

#[test]
fn open_wallet_unknown_id_errs() {
    let mut env = TestEnv::new();
    let err = env.err("open_wallet", json!({ "wallet_id": "no-such-wallet" }));
    assert!(
        err.contains("not found") || err.contains("Wallet"),
        "unexpected message: {err}"
    );
}

// ── Wallet info ──────────────────────────────────────────────────────────────

#[test]
fn get_wallet_info_exposes_public_identity_for_software_wallet() {
    let mut env = TestEnv::new();
    let id = env.create_test_wallet();
    let info = env.ok("get_wallet_info", json!({ "wallet_id": id }));

    // Exact keys _walletInfoFromJson reads (ffi_wallet_bridge.dart).
    assert_keys(
        "get_wallet_info",
        &info,
        &[
            "id",
            "name",
            "network",
            "master_fingerprint",
            "derivation_path",
            "script_type",
            "xpub",
            "receive_descriptor",
            "change_descriptor",
            "multipath_descriptor",
            "liquid_descriptor",
            "master_blinding_key",
            "has_seed",
            "has_passphrase",
            "last_backup_at",
            "cosigner_keys",
        ],
    );
    assert_eq!(info["id"], json!(id));
    assert_eq!(info["master_fingerprint"], json!("73c5da0a"));
    assert!(info["xpub"].as_str().unwrap_or("").starts_with("tpub"));
    assert_eq!(info["has_seed"], json!(true));

    let recv = info["receive_descriptor"].as_str().unwrap_or("");
    assert!(recv.contains("wpkh("), "descriptor expected: {recv:?}");
    // N1 guarantee: never expose a signing descriptor across the FFI.
    for field in ["receive_descriptor", "change_descriptor"] {
        let desc = info[field].as_str().unwrap_or("");
        assert!(
            !desc.contains("tprv") && !desc.contains("xprv"),
            "{field} leaks a private key: {desc}"
        );
    }
}

// ── Dashboard ────────────────────────────────────────────────────────────────

#[test]
fn get_wallet_summary_matches_dart_decode_shape() {
    let mut env = TestEnv::new();
    let id = env.create_test_wallet();
    let dash = env.ok("get_wallet_summary", json!({ "wallet_id": id }));

    // Exact keys _dashboardFromJson reads (ffi_wallet_bridge.dart).
    assert_keys(
        "get_wallet_summary",
        &dash,
        &[
            "wallet_id",
            "wallet_name",
            "total_balance_display",
            "sync_state",
            "assets",
            "recent_activity",
        ],
    );
    assert_eq!(dash["wallet_id"], json!(id));
    assert_eq!(dash["wallet_name"], json!("Contract Test"));
    assert!(!dash["sync_state"].as_str().unwrap_or("").is_empty());
    assert!(dash["recent_activity"].is_array());

    let assets = dash["assets"].as_array().expect("assets is a list");
    assert!(!assets.is_empty(), "BTC asset always present");
    // Exact keys _assetBalanceFromJson reads.
    assert_keys(
        "assets[0]",
        &assets[0],
        &[
            "asset_id",
            "ticker",
            "name",
            "amount",
            "display_amount",
            "fiat_estimate",
            "status",
            "utxo_count",
            "is_native",
        ],
    );
    assert_eq!(assets[0]["ticker"], json!("BTC"));
    assert_eq!(assets[0]["amount"], json!(0), "fresh wallet holds nothing");
}

// ── Version handshake ────────────────────────────────────────────────────────

#[test]
fn version_reports_the_crate_version() {
    let mut env = TestEnv::new();
    let v = env.ok("version", json!({}));
    assert_eq!(v, json!(env!("CARGO_PKG_VERSION")));
}

#[test]
fn version_survives_a_startup_error() {
    // The About screen must distinguish "engine loaded but init failed" from
    // "dylib unreachable" — version answers even under a fatal init condition.
    let mut env = TestEnv::new();
    env.state.startup_error = Some("test-injected corruption".to_string());
    let v = env.ok("version", json!({}));
    assert_eq!(v, json!(env!("CARGO_PKG_VERSION")));
}

// ── Error paths ──────────────────────────────────────────────────────────────

#[test]
fn unknown_method_is_an_error() {
    let mut env = TestEnv::new();
    let err = env.err("definitely_not_a_method", json!({}));
    assert!(err.contains("Unknown method"), "unexpected message: {err}");
}

#[test]
fn inspect_psbt_rejects_garbage() {
    let mut env = TestEnv::new();
    env.err("inspect_psbt", json!({ "psbt_base64": "not a psbt" }));
}

#[test]
fn startup_error_fails_every_method_with_its_message() {
    let mut env = TestEnv::new();
    let msg = "Wallet storage could not be read: test-injected corruption.";
    env.state.startup_error = Some(msg.to_string());

    for (method, params) in [
        ("list_wallets", json!({})),
        ("generate_mnemonic", json!({ "word_count": 12 })),
        (
            "create_wallet",
            json!({ "name": "X", "mnemonic": MNEMONIC }),
        ),
        ("get_wallet_summary", json!({ "wallet_id": "any" })),
    ] {
        let err = env.err(method, params);
        assert_eq!(err, msg, "{method} must propagate the startup error");
    }
}

/// Backup verification is the safety net behind every "write these words
/// down" screen, so the four outcomes it can report are pinned here: the right
/// phrase passes, a different valid phrase fails, a transposed word fails, and
/// the wire shape stays what the Dart side decodes.
#[test]
fn verify_backup_accepts_only_this_wallets_phrase() {
    let mut env = TestEnv::new();
    let id = env.create_test_wallet();

    let good = env.ok(
        "verify_backup",
        json!({ "wallet_id": &id, "mnemonic": MNEMONIC }),
    );
    assert_eq!(
        good["matched"],
        json!(true),
        "own phrase must verify: {good}"
    );
    assert_eq!(good["reason"], json!("ok"));
    assert_eq!(good["fingerprint_match"], json!(true));
    for key in [
        "matched",
        "reason",
        "derived_fingerprint",
        "expected_fingerprint",
        "fingerprint_match",
    ] {
        assert!(good.get(key).is_some(), "verify_backup must carry {key}");
    }

    // A valid phrase for some *other* wallet: checksum passes, keys do not.
    let other = "legal winner thank year wave sausage worth useful legal winner                  thank yellow";
    let wrong = env.ok(
        "verify_backup",
        json!({ "wallet_id": &id, "mnemonic": other }),
    );
    assert_eq!(wrong["matched"], json!(false), "foreign phrase must fail");
    assert_eq!(wrong["reason"], json!("mismatch"));
    assert_ne!(
        wrong["derived_fingerprint"], wrong["expected_fingerprint"],
        "a failure must report which wallet the paper actually is"
    );

    // The failure a quiz cannot catch: right words, wrong order.
    let transposed = "abandon abandon abandon abandon abandon abandon abandon                       abandon abandon abandon about abandon";
    let swapped = env.ok(
        "verify_backup",
        json!({ "wallet_id": &id, "mnemonic": transposed }),
    );
    assert_eq!(swapped["matched"], json!(false), "word order must matter");

    // Formatting noise from a notes app is not a backup failure.
    let messy = format!(
        "  1. {}  ",
        MNEMONIC.split_whitespace().collect::<Vec<_>>().join("\n")
    );
    let tidy = env.ok(
        "verify_backup",
        json!({ "wallet_id": &id, "mnemonic": messy }),
    );
    assert_eq!(
        tidy["matched"],
        json!(true),
        "line breaks must not fail: {tidy}"
    );
}

/// The reveal gate proves the app password without handing out a session, and
/// throttles guessing on top of Argon2id's own cost.
#[test]
fn verify_vault_passphrase_checks_without_unlocking() {
    let mut env = TestEnv::new();
    // The harness builds its vault directly, so `state.vault` is already set;
    // drop it to model the real "vault exists, gate is closed" case.
    env.state.vault = None;

    let err = env.err(
        "verify_vault_passphrase",
        json!({ "passphrase": "not the passphrase" }),
    );
    assert!(
        err.contains("Wrong app password"),
        "unexpected error: {err}"
    );
    assert!(
        env.state.vault.is_none(),
        "a failed check must not touch the session"
    );

    env.ok(
        "verify_vault_passphrase",
        json!({ "passphrase": "contract-test-passphrase" }),
    );
    assert!(
        env.state.vault.is_none(),
        "verifying proves the password, it must not unlock the vault"
    );
    assert_eq!(env.state.verify_failures, 0, "success resets the counter");
}

/// The Touch ID confirmation gate proves the keystore's copy of the vault key
/// the way the reveal gate proves the passphrase: without opening a session.
#[test]
fn verify_vault_key_checks_without_unlocking() {
    let mut env = TestEnv::new();
    let key_hex = env.ok("export_vault_key", json!({}))["key_hex"]
        .as_str()
        .expect("key_hex")
        .to_string();
    env.ok("lock_vault", json!({}));
    assert!(env.state.vault.is_none());

    // The right key proves itself and grants nothing.
    let resp = env.call("verify_vault_key", json!({ "key_hex": key_hex }));
    assert_eq!(resp, json!({ "ok": null }), "{resp}");
    assert!(
        env.state.vault.is_none(),
        "verifying proves the key, it must not unlock the vault"
    );
    assert_eq!(env.ok("vault_status", json!({}))["state"], json!("locked"));

    // A key from another vault reads as a mismatch, so the UI can switch the
    // feature off rather than retry forever.
    let wrong = "ff".repeat(32);
    let err = env.err("verify_vault_key", json!({ "key_hex": wrong }));
    assert!(err.contains("does not match"), "unexpected error: {err}");
    assert!(env.state.vault.is_none());

    // Garbage is garbage, not a mismatch.
    let err = env.err("verify_vault_key", json!({ "key_hex": "zz" }));
    assert!(err.contains("hex"), "unexpected error: {err}");
    assert!(!err.contains("does not match"), "unexpected error: {err}");
}

/// A2's blind spot: the create-time refusal does nothing about phrases already
/// written by an older build, so the status call has to report them.
#[test]
fn vault_status_reports_plaintext_seeds_needing_migration() {
    let mut env = TestEnv::new();
    let status = env.ok("vault_status", json!({}));
    for key in [
        "initialized",
        "unlocked",
        "needs_migration",
        "plaintext_seed_wallets",
        "state",
    ] {
        assert!(status.get(key).is_some(), "vault_status must carry {key}");
    }
    // This env has a vault, so nothing is in the clear.
    assert_eq!(status["needs_migration"], json!(false));
    assert_eq!(status["plaintext_seed_wallets"], json!(0));
}

/// The key behind the biometric unlock exists only inside an unlocked vault:
/// nothing to export before setup, nothing while locked.
#[test]
fn export_vault_key_needs_a_set_up_and_unlocked_vault() {
    let mut fresh = TestEnv::new_without_vault();
    let err = fresh.err("export_vault_key", json!({}));
    assert!(err.contains("No vault"), "unexpected error: {err}");

    let mut env = TestEnv::new();
    env.ok("lock_vault", json!({}));
    let err = env.err("export_vault_key", json!({}));
    assert!(err.contains("locked"), "unexpected error: {err}");
    assert!(
        env.state.vault.is_none(),
        "a refused export must not unlock"
    );
}

/// Biometric unlock end to end: the key exported from an unlocked session
/// opens the vault again after a lock, with the same post-unlock state as a
/// passphrase unlock — wallets listed, status unlocked, same `null` payload.
#[test]
fn stored_key_unlocks_the_vault_without_the_passphrase() {
    let mut env = TestEnv::new();
    let id = env.create_test_wallet();

    let exported = env.ok("export_vault_key", json!({}));
    let key_hex = exported["key_hex"]
        .as_str()
        .expect("export_vault_key ok payload must carry a string key_hex")
        .to_string();
    assert_eq!(key_hex.len(), 64, "32 bytes of hex: {key_hex}");
    assert!(
        key_hex
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase()),
        "lowercase hex: {key_hex}"
    );
    // The same session hands out the same key every time.
    assert_eq!(
        env.ok("export_vault_key", json!({}))["key_hex"],
        json!(key_hex)
    );

    env.ok("lock_vault", json!({}));
    assert!(env.state.vault.is_none());
    assert_eq!(env.ok("vault_status", json!({}))["unlocked"], json!(false));
    env.err("list_wallets", json!({}));

    // Same envelope as `unlock_vault`: `{"ok": null}`.
    let resp = env.call("unlock_vault_with_key", json!({ "key_hex": key_hex }));
    assert_eq!(resp, json!({ "ok": null }), "{resp}");
    assert!(env.state.vault.is_some());
    let status = env.ok("vault_status", json!({}));
    assert_eq!(status["unlocked"], json!(true), "{status}");
    assert_eq!(status["state"], json!("unlocked"), "{status}");
    let wallets = env.ok("list_wallets", json!({}));
    assert_eq!(
        wallets[0]["id"],
        json!(id),
        "the sealed registry is back: {wallets}"
    );

    // The keystore may round-trip the case; both must open.
    env.ok("lock_vault", json!({}));
    env.ok(
        "unlock_vault_with_key",
        json!({ "key_hex": key_hex.to_uppercase() }),
    );

    // The exported key *is* the passphrase-derived one: a passphrase unlock
    // exports the same bytes, so the keystore copy stays valid across both.
    env.ok("lock_vault", json!({}));
    env.ok(
        "unlock_vault",
        json!({ "passphrase": "contract-test-passphrase" }),
    );
    assert_eq!(
        env.ok("export_vault_key", json!({}))["key_hex"],
        json!(key_hex)
    );
}

/// A well-formed key from some other vault (or a vault re-created since the
/// key was stored) is refused with a "does not match" error, and the session
/// stays locked so the UI falls back to the passphrase screen.
#[test]
fn wrong_stored_key_is_rejected_and_leaves_the_vault_locked() {
    let mut env = TestEnv::new();
    env.ok("lock_vault", json!({}));

    let wrong = "ff".repeat(32);
    let err = env.err("unlock_vault_with_key", json!({ "key_hex": wrong }));
    assert!(err.contains("does not match"), "unexpected error: {err}");
    assert!(env.state.vault.is_none(), "a rejected key must not unlock");
    let status = env.ok("vault_status", json!({}));
    assert_eq!(status["unlocked"], json!(false), "{status}");
    assert_eq!(status["state"], json!("locked"), "{status}");
    env.err("list_wallets", json!({}));
}

/// Garbage from the keystore is reported as garbage — never as a mismatched
/// key, and never as a successful unlock.
#[test]
fn malformed_stored_key_is_rejected() {
    let mut env = TestEnv::new();
    env.ok("lock_vault", json!({}));

    let missing = env.err("unlock_vault_with_key", json!({}));
    assert!(missing.contains("key_hex"), "unexpected error: {missing}");

    for bad in [
        String::new(),
        "abc".into(),
        "00".repeat(31),
        "00".repeat(33),
        "zz".repeat(32),
        "0".repeat(63) + "g",
    ] {
        let err = env.err("unlock_vault_with_key", json!({ "key_hex": bad }));
        assert!(err.contains("hex"), "{bad:?}: unexpected error: {err}");
        assert!(
            !err.contains("does not match"),
            "{bad:?}: malformed input is not a mismatch: {err}"
        );
        assert!(env.state.vault.is_none(), "{bad:?} must not unlock");
    }
    assert_eq!(env.ok("vault_status", json!({}))["state"], json!("locked"));
}

/// A2 — no vault, no seed on disk. The wizard makes the password step
/// mandatory, but Restore-wallet and the direct `/create-wallet` route do not
/// go through the wizard, so the refusal lives here.
#[test]
fn creating_a_seed_wallet_without_a_vault_is_refused() {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .subsec_nanos();
    let dir = std::env::temp_dir().join(format!(
        "templar-ffi-novault-{}-{}-{}",
        std::process::id(),
        DIR_SEQ.fetch_add(1, Ordering::Relaxed),
        nanos,
    ));
    std::fs::create_dir_all(&dir).expect("create test data dir");
    let mut state = AppFfiState::new_for_test(dir.clone());

    let resp = dispatch(
        &mut state,
        "create_wallet",
        &json!({ "name": "Plaintext", "mnemonic": MNEMONIC, "liquid": false }),
    );
    let err = resp["err"].as_str().expect("must be refused, not created");
    assert!(
        err.contains("app password"),
        "the error must tell the user what to do: {err}"
    );
    assert!(
        !dir.join("registry.json").exists(),
        "nothing may be persisted in plaintext"
    );

    // With encryption set up, the same call succeeds and the seed only ever
    // reaches disk sealed.
    crate::handlers::vault::setup(&mut state, "contract-test-passphrase").unwrap();
    let resp = dispatch(
        &mut state,
        "create_wallet",
        &json!({ "name": "Sealed", "mnemonic": MNEMONIC, "liquid": false }),
    );
    assert!(
        resp.get("ok").is_some(),
        "with a vault it must succeed: {resp}"
    );
    assert!(!dir.join("registry.json").exists());
    let sealed = std::fs::read_to_string(dir.join("registry.enc")).unwrap();
    assert!(!sealed.contains("abandon"));

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn second_instance_on_same_data_dir_gets_startup_error() {
    let mut env = TestEnv::new();
    assert!(env.state.startup_error.is_none());

    // A second state on the same dir must fail to take the instance lock…
    let mut second = AppFfiState::new_for_test(env.dir.clone());
    let msg = second
        .startup_error
        .clone()
        .expect("second instance must record a startup error");
    assert!(
        msg.contains("Another Templar Wallet instance"),
        "unexpected message: {msg}"
    );
    // …and every call through it must surface that error.
    let resp = dispatch(&mut second, "list_wallets", &json!({}));
    assert_eq!(resp["err"], json!(msg));

    // The first instance keeps working.
    env.ok("list_wallets", json!({}));
}

// ── Hardware wallet surface ───────────────────────────────────────────────────

/// `hwi_status` feeds `HwiStatus.fromJson` in
/// `lib/bridge/wallet_bridge.dart`, which decides between "show the install
/// card", "offer the udev fix", and "let the user scan". Every key it reads
/// must be present with the right JSON type, whether or not HWI is installed
/// on the machine running the tests.
#[cfg(feature = "hardware")]
#[test]
fn hwi_status_matches_dart_decode_shape() {
    let mut env = TestEnv::new();
    let v = env.ok("hwi_status", json!({}));
    assert_eq!(v["hardware_supported"], json!(true), "{v}");

    // resolved_bin: string or null — null is the install-card cue.
    assert!(v.get("resolved_bin").is_some(), "missing resolved_bin: {v}");
    assert!(
        v["resolved_bin"].is_string() || v["resolved_bin"].is_null(),
        "resolved_bin must be string|null: {v}"
    );
    assert!(v.get("version").is_some(), "missing version: {v}");
    assert!(
        v["version"].is_string() || v["version"].is_null(),
        "version must be string|null: {v}"
    );
    assert!(v["platform"].is_string(), "platform must be a string: {v}");
    // udev_rules_installed: bool on Linux, null elsewhere — Dart reads it as
    // `bool?` and treats null as "not applicable", never as "missing".
    assert!(
        v["udev_rules_installed"].is_boolean() || v["udev_rules_installed"].is_null(),
        "udev_rules_installed must be bool|null: {v}"
    );
    if cfg!(target_os = "linux") {
        assert!(
            v["udev_rules_installed"].is_boolean(),
            "linux must report: {v}"
        );
    } else {
        assert!(
            v["udev_rules_installed"].is_null(),
            "non-linux must be null: {v}"
        );
    }
    // True since Jade support landed. It is a build capability flag, not a
    // per-device one — the UI still has to check that *this* device is a Jade,
    // because no other hardware wallet can sign Liquid.
    assert_eq!(v["liquid_hw_signing"], json!(true), "{v}");

    // The UI decides whether to show the "some devices don't work here" card
    // from these two, rather than from the platform tag. A missing field would
    // make Dart fall back to its defaults and quietly claim full support.
    let families = v["native_families"]
        .as_array()
        .unwrap_or_else(|| panic!("native_families must be an array: {v}"));
    let families: Vec<&str> = families.iter().filter_map(|f| f.as_str()).collect();
    assert!(
        families.contains(&"Ledger") && families.contains(&"Blockstream Jade"),
        "both native drivers must be advertised: {families:?}"
    );
    assert!(
        v["hwi_usable"].is_boolean(),
        "hwi_usable must be a bool: {v}"
    );
    // The HWI subprocess cannot run inside the macOS App Sandbox — measured,
    // see bitcoin/device/mod.rs. Everywhere else it is the fallback for the
    // families without a native driver.
    assert_eq!(v["hwi_usable"], json!(!cfg!(target_os = "macos")), "{v}");
}

/// A Liquid asset must never reach the hardware or air-gap signing paths:
/// both build a Bitcoin PSBT, so "send L-BTC" would silently become "send
/// BTC". The rejection carries the stable tag the Dart classifier keys on.
#[cfg(feature = "hardware")]
#[test]
fn hardware_send_paths_reject_liquid_assets() {
    let lbtc = "144c654344aa716d6f3abcc1ca90e5641e4e2a7f633bc09fe3baf64585819a49";
    for method in [
        "send_transaction_hw",
        "sign_transaction_hw",
        "build_unsigned_psbt",
    ] {
        let mut env = TestEnv::new();
        let err = env.err(
            method,
            json!({
                "wallet_id": "does-not-matter",
                "asset_id": lbtc,
                "fee_rate": 3.0,
                "outputs": [{"address": "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx", "amount_sats": 1000}],
            }),
        );
        assert!(
            err.starts_with("LIQUID_HW_UNSUPPORTED: ") || err.contains("not found"),
            "{method} must reject the asset (or fail earlier on the wallet \
             lookup), got: {err}"
        );
    }
}

/// The multisig co-signing entry point exists and validates its input before
/// touching a device. Without it, a hardware key enrolled in a multisig could
/// contribute an xpub and then never be asked to sign.
#[cfg(feature = "hardware")]
#[test]
fn sign_psbt_hw_is_routed_and_validates_input() {
    let mut env = TestEnv::new();
    let err = env.err(
        "sign_psbt_hw",
        json!({"fingerprint": "f0b68896", "psbt_base64": "   "}),
    );
    assert!(err.contains("No PSBT"), "got: {err}");

    // Unknown method would say so — proving the arm is wired.
    let resp = env.call("sign_psbt_hw", json!({"fingerprint": "f0b68896"}));
    let err = resp["err"].as_str().unwrap_or_default();
    assert!(
        !err.contains("Unknown method"),
        "sign_psbt_hw is not routed: {err}"
    );
}

/// `enumerate_native_devices` backs the "your device is connected, this build
/// just cannot talk to it yet" message, so it must answer with a list — never
/// an error — on a machine with nothing plugged in. An error there would put
/// a scary banner in front of every user who has no device attached.
#[cfg(feature = "hardware")]
#[test]
fn native_device_enumeration_is_always_a_list() {
    let mut env = TestEnv::new();
    let v = env.ok("enumerate_native_devices", json!({}));
    let list = v.as_array().unwrap_or_else(|| panic!("not an array: {v}"));
    // Every entry must carry the keys `NativeDevice.fromJson` reads.
    for d in list {
        for key in [
            "family",
            "model",
            "transport",
            "path",
            "vendor_id",
            "product_id",
            // Whether the device can be driven, not just seen. Absent, Dart
            // defaults it to false and marks a working Ledger unusable.
            "drivable",
        ] {
            assert!(d.get(key).is_some(), "missing {key}: {d}");
        }
        assert!(d["vendor_id"].is_number(), "vendor_id must be numeric: {d}");
        assert!(d["drivable"].is_boolean(), "drivable must be a bool: {d}");
        assert!(
            d["transport"] == json!("hid") || d["transport"] == json!("serial"),
            "unexpected transport: {d}"
        );
    }
}

/// A Liquid wallet may only ever be paired with a Jade. Every other USB signer
/// is Bitcoin-only in firmware, so pairing one would create a wallet that can
/// receive funds no signature can ever move. The wizard blocks it; this checks
/// the backend blocks it too, since the wizard is not the only caller.
#[cfg(feature = "hardware")]
#[test]
fn liquid_pairing_is_refused_for_non_jade_devices() {
    // Pairing opens whatever is attached to ask for its fingerprint, and a
    // locked Jade holds that call for its full 90 s PIN window. With hardware
    // on the desk this is a manual test (docs/HARDWARE_TESTING.md), not a
    // routing check.
    if templar_core::enumerate_native()
        .unwrap_or_default()
        .iter()
        .any(|d| d.drivable)
    {
        eprintln!("skipped: a drivable device is attached");
        return;
    }
    let mut env = TestEnv::new();
    // No device attached, so this cannot reach the device layer — but the
    // request must not be accepted on its way there either.
    let err = env.err(
        "import_hw_wallet",
        json!({"name": "LedgerLiquid", "fingerprint": "f0b68896", "liquid": true}),
    );
    assert!(
        !err.is_empty() && !err.contains("Unknown method"),
        "import_hw_wallet is not routed: {err}"
    );
}

/// The Jade-only Liquid import must validate its input before reaching for a
/// device — a blank name should not make the user unlock their Jade first.
#[cfg(feature = "hardware")]
#[test]
fn jade_liquid_import_validates_before_touching_the_device() {
    let mut env = TestEnv::new();
    let err = env.err("import_jade_liquid_wallet", json!({"name": "   "}));
    assert!(err.contains("name is required"), "got: {err}");
}

/// Listing Jade serial ports must be safe and side-effect free with nothing
/// attached: the wizard calls it to decide between "plug in your Jade" and
/// "found it", and it must never open the port.
#[cfg(feature = "hardware")]
#[test]
fn jade_port_listing_is_always_a_list() {
    let mut env = TestEnv::new();
    let v = env.ok("jade_ports", json!({}));
    assert!(v.is_array(), "not an array: {v}");
}

// ── Liquid multisig ──────────────────────────────────────────────────────────

/// Second BIP39 test vector, so a multisig can be built from two distinct
/// seeds without touching a device.
const MNEMONIC_B: &str = "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong";

/// Third BIP39 test vector — a key that belongs to nobody in the wallet, for
/// the cases that need a *wrong* key rather than a repeated one.
const MNEMONIC_C: &str =
    "legal winner thank year wave sausage worth useful legal winner thank yellow";

/// Collect one cosigner's pair of keys: BIP48 for Bitcoin, BIP87 for Liquid.
/// Two accounts on one seed — neither is derivable from the other, which is
/// the whole reason the wizard asks for both.
fn cosigner_keys(env: &mut TestEnv, mnemonic: &str) -> (String, String) {
    let btc = env.ok("derive_cosigner_xpub", json!({"mnemonic": mnemonic}));
    let liquid = env.ok("derive_liquid_cosigner_xpub", json!({"mnemonic": mnemonic}));
    (
        btc.as_str().expect("btc xpub is a string").to_string(),
        liquid
            .as_str()
            .expect("liquid xpub is a string")
            .to_string(),
    )
}

/// The two key exports are distinct accounts and carry the paths their chains
/// expect. A silent fallback to one shared key would put the same public keys
/// on both chains — spendable, but it links the wallets forever.
#[test]
fn bitcoin_and_liquid_cosigner_keys_are_separate_accounts() {
    let mut env = TestEnv::new();
    let (btc, liquid) = cosigner_keys(&mut env, MNEMONIC);
    assert!(
        btc.contains("/48'/1'/0'/2']") || btc.contains("/48h/1h/0h/2h]"),
        "btc: {btc}"
    );
    assert!(
        liquid.contains("/87'/1'/0']") || liquid.contains("/87h/1h/0h]"),
        "liquid: {liquid}"
    );
    assert_ne!(btc, liquid);
}

/// The wallet the wizard produces: one entry, both chains, Liquid advertised
/// to the UI through the same flag every other wallet type uses.
#[test]
fn liquid_multisig_wallet_is_created_with_both_chains() {
    let mut env = TestEnv::new();
    let (btc_a, liq_a) = cosigner_keys(&mut env, MNEMONIC);
    let (btc_b, liq_b) = cosigner_keys(&mut env, MNEMONIC_B);

    let summary = env.ok(
        "create_multisig_wallet",
        json!({
            "name": "Treasury",
            "required_sigs": 2,
            "total_signers": 2,
            "cosigner_xpubs": [btc_a, btc_b],
            "local_mnemonics": [MNEMONIC, MNEMONIC_B],
            "liquid_xpubs": [liq_a, liq_b],
            "liquid_capable_keys": 2,
        }),
    );
    assert_eq!(summary["wallet_type"], "multisig");
    assert_eq!(summary["liquid_enabled"], true);
    assert_eq!(summary["is_watch_only"], false);

    // The picker reads the same flags from the registry, not from this reply.
    let wallets = env.ok("list_wallets", json!({}));
    let row = &wallets.as_array().expect("array")[0];
    assert_eq!(row["liquid_enabled"], true);
    assert_eq!(row["bitcoin_enabled"], true);
    assert_eq!(row["required_sigs"], 2);
    assert_eq!(row["total_signers"], 2);
}

/// Omitting the Liquid keys leaves a Bitcoin-only multisig — the pre-existing
/// behaviour, and what the wizard sends when the user picks "Bitcoin only".
#[test]
fn multisig_without_liquid_keys_stays_bitcoin_only() {
    let mut env = TestEnv::new();
    let (btc_a, _) = cosigner_keys(&mut env, MNEMONIC);
    let (btc_b, _) = cosigner_keys(&mut env, MNEMONIC_B);
    let summary = env.ok(
        "create_multisig_wallet",
        json!({
            "name": "BtcOnly",
            "required_sigs": 2,
            "total_signers": 2,
            "cosigner_xpubs": [btc_a, btc_b],
            "local_mnemonics": [MNEMONIC],
        }),
    );
    assert_eq!(summary["liquid_enabled"], false);
}

/// The fund trap: fewer Liquid-capable keys than the threshold means funds
/// could arrive and never leave. Refused at creation, before any address is
/// handed out.
#[test]
fn liquid_multisig_is_refused_when_too_few_keys_can_sign_liquid() {
    let mut env = TestEnv::new();
    let (btc_a, liq_a) = cosigner_keys(&mut env, MNEMONIC);
    let (btc_b, liq_b) = cosigner_keys(&mut env, MNEMONIC_B);
    let err = env.err(
        "create_multisig_wallet",
        json!({
            "name": "Trap",
            "required_sigs": 2,
            "total_signers": 2,
            "cosigner_xpubs": [btc_a, btc_b],
            "local_mnemonics": [MNEMONIC],
            "liquid_xpubs": [liq_a, liq_b],
            // e.g. the second key lives on a Ledger: Bitcoin-only in firmware.
            "liquid_capable_keys": 1,
        }),
    );
    assert!(err.contains("could never be spent"), "got: {err}");
    // Nothing may be left behind by a refused creation.
    assert!(env
        .ok("list_wallets", json!({}))
        .as_array()
        .unwrap()
        .is_empty());
}

/// One BIP87 key per cosigner, or none at all. A short list means the wizard
/// dropped a key, and building a smaller Liquid quorum than the Bitcoin one
/// would silently weaken the wallet.
#[test]
fn liquid_multisig_requires_one_liquid_key_per_cosigner() {
    let mut env = TestEnv::new();
    let (btc_a, liq_a) = cosigner_keys(&mut env, MNEMONIC);
    let (btc_b, _) = cosigner_keys(&mut env, MNEMONIC_B);
    let err = env.err(
        "create_multisig_wallet",
        json!({
            "name": "Short",
            "required_sigs": 2,
            "total_signers": 2,
            "cosigner_xpubs": [btc_a, btc_b],
            "local_mnemonics": [MNEMONIC],
            "liquid_xpubs": [liq_a],
            "liquid_capable_keys": 2,
        }),
    );
    assert!(err.contains("one BIP87 key per cosigner"), "got: {err}");
}

/// A local seed whose Liquid key is missing from the descriptor would leave
/// the app unable to sign on Liquid while looking like a co-signer. Caught at
/// creation, where the fix is obvious (keys pasted out of order).
#[test]
fn liquid_multisig_rejects_a_local_key_absent_from_the_liquid_list() {
    let mut env = TestEnv::new();
    let (btc_a, liq_a) = cosigner_keys(&mut env, MNEMONIC);
    let (btc_b, _liq_b) = cosigner_keys(&mut env, MNEMONIC_B);
    let (_btc_c, liq_c) = cosigner_keys(&mut env, MNEMONIC_C);
    let err = env.err(
        "create_multisig_wallet",
        json!({
            "name": "Mismatch",
            "required_sigs": 2,
            "total_signers": 2,
            "cosigner_xpubs": [btc_a, btc_b],
            // B signs locally, but the Liquid list carries a stranger's key
            // where B's belongs — keys pasted out of order, or the wrong
            // export copied in.
            "local_mnemonics": [MNEMONIC_B],
            "liquid_xpubs": [liq_a, liq_c],
            "liquid_capable_keys": 2,
        }),
    );
    assert!(err.contains("no matching BIP87 key"), "got: {err}");
}

/// The same key twice is not a 2-of-2: the threshold it enforces is really 1.
/// Cheap to do by accident when keys are collected one card at a time.
#[test]
fn multisig_rejects_the_same_cosigner_key_twice() {
    let mut env = TestEnv::new();
    let (btc_a, _) = cosigner_keys(&mut env, MNEMONIC);
    let err = env.err(
        "create_multisig_wallet",
        json!({
            "name": "Doubled",
            "required_sigs": 2,
            "total_signers": 2,
            "cosigner_xpubs": [btc_a.clone(), btc_a],
            "local_mnemonics": [MNEMONIC],
        }),
    );
    assert!(err.contains("same key as key 1"), "got: {err}");
}

/// The bug this whole guard exists for: a cosigner key scanned from an
/// air-gapped device arrives as a whole `wpkh(...)` descriptor, and the
/// multisig builder used to nest it inside `sortedmulti` and persist the
/// result. Creation reported success; every later open died on
/// "Miniscript error: expected )" and the wallet could not be removed from
/// the sidebar. It must now be reduced to its key and open normally.
#[test]
fn scanned_descriptor_key_is_reduced_and_the_wallet_opens() {
    let mut env = TestEnv::new();
    let (btc_a, _) = cosigner_keys(&mut env, MNEMONIC);
    let (btc_b, _) = cosigner_keys(&mut env, MNEMONIC_B);
    // What decode_ur_parts hands back for a Jade "Export Xpub" QR.
    let scanned = format!("wpkh({}/<0;1>/*)", btc_b);

    let summary = env.ok(
        "create_multisig_wallet",
        json!({
            "name": "Scanned",
            "required_sigs": 2,
            "total_signers": 2,
            "cosigner_xpubs": [btc_a, scanned],
            "local_mnemonics": [MNEMONIC],
        }),
    );
    let id = summary["id"].as_str().expect("wallet id").to_string();

    env.ok("open_wallet", json!({ "wallet_id": id }));
    let addr = env.ok(
        "generate_receive_address",
        json!({ "wallet_id": id, "asset": "BTC" }),
    );
    assert!(
        addr["address"].as_str().unwrap_or("").starts_with("tb1"),
        "wallet must open and derive: {addr}"
    );
}

/// A key that cannot be used must be refused while the wizard is still on
/// screen, never written to the registry. The wallet list is the one place
/// with no repair path.
#[test]
fn unusable_cosigner_key_never_reaches_the_registry() {
    let mut env = TestEnv::new();
    let (btc_a, _) = cosigner_keys(&mut env, MNEMONIC);
    let before = env.ok("list_wallets", json!({}));
    let err = env.err(
        "create_multisig_wallet",
        json!({
            "name": "Garbage",
            "required_sigs": 2,
            "total_signers": 2,
            "cosigner_xpubs": [btc_a, "not-a-key-at-all"],
            "local_mnemonics": [MNEMONIC],
        }),
    );
    assert!(err.starts_with("Key 2:"), "must name the key: {err}");
    let after = env.ok("list_wallets", json!({}));
    assert_eq!(
        before.as_array().map(|a| a.len()),
        after.as_array().map(|a| a.len()),
        "a refused wallet must leave nothing behind"
    );
}

/// The rescue path for a wallet already broken this way, reproduced exactly:
/// a registry entry whose descriptors nest a scanned key's `wpkh(...)` inside
/// `sortedmulti`. It cannot be opened, so nothing in the app can act on it —
/// and re-collecting the keys means going back to every device. Repair must
/// rebuild it from the keys it already stores and give back the *same* wallet.
#[test]
fn a_wallet_broken_by_a_scanned_key_can_be_repaired_in_place() {
    use templar_core::WalletProfile;

    let mut env = TestEnv::new();
    let (btc_a, _) = cosigner_keys(&mut env, MNEMONIC);
    let (btc_b, _) = cosigner_keys(&mut env, MNEMONIC_B);

    // A watch-only coordinator: every key came from somewhere else, which is
    // how an air-gapped multisig is collected in the first place.
    let summary = env.ok(
        "create_multisig_wallet",
        json!({
            "name": "Rescue",
            "required_sigs": 2,
            "total_signers": 2,
            "cosigner_xpubs": [btc_a.clone(), btc_b.clone()],
            "local_mnemonics": [],
        }),
    );
    let id = summary["id"].as_str().expect("wallet id").to_string();

    env.ok("open_wallet", json!({ "wallet_id": id }));
    let before = env.ok(
        "generate_receive_address",
        json!({ "wallet_id": id, "asset": "BTC" }),
    )["address"]
        .as_str()
        .unwrap_or_default()
        .to_string();
    assert!(!before.is_empty());

    // Put the entry back into the state the old code produced.
    let scanned = format!("wpkh({btc_b}/<0;1>/*)");
    {
        let entry = env.state.registry.find_mut(&id).expect("entry");
        let WalletProfile::Multisig {
            cosigner_xpubs,
            receive_descriptor,
            change_descriptor,
            ..
        } = &mut entry.profile
        else {
            panic!("multisig expected")
        };
        *cosigner_xpubs = vec![btc_a.clone(), scanned.clone()];
        *receive_descriptor = format!("wsh(sortedmulti(2,{btc_a}/0/*,{scanned}/0/*))");
        *change_descriptor = format!("wsh(sortedmulti(2,{btc_a}/1/*,{scanned}/1/*))");
    }
    env.state.save_registry().expect("save broken registry");
    env.state.bitcoin = None;
    env.state.active_wallet_id = None;

    let err = env.err("open_wallet", json!({ "wallet_id": id }));
    assert!(err.contains("descriptor"), "must fail to open: {err}");

    env.ok("repair_multisig_wallet", json!({ "wallet_id": id }));
    env.ok("open_wallet", json!({ "wallet_id": id }));
    let after = env.ok(
        "generate_receive_address",
        json!({ "wallet_id": id, "asset": "BTC" }),
    )["address"]
        .as_str()
        .unwrap_or_default()
        .to_string();
    assert_eq!(after, before, "repair must give back the same wallet");
}

/// Repair is not a button to press on any wallet that will not open: when the
/// descriptors are fine, it says so instead of rewriting them.
#[test]
fn repair_refuses_a_wallet_with_nothing_wrong() {
    let mut env = TestEnv::new();
    let (btc_a, _) = cosigner_keys(&mut env, MNEMONIC);
    let (btc_b, _) = cosigner_keys(&mut env, MNEMONIC_B);
    let summary = env.ok(
        "create_multisig_wallet",
        json!({
            "name": "Healthy",
            "required_sigs": 2,
            "total_signers": 2,
            "cosigner_xpubs": [btc_a, btc_b],
            "local_mnemonics": [MNEMONIC],
        }),
    );
    let id = summary["id"].as_str().expect("wallet id");
    let err = env.err("repair_multisig_wallet", json!({ "wallet_id": id }));
    assert!(err.contains("nothing to repair"), "got: {err}");
}

/// The wizard's live check: same rules as creation, reported per field.
#[test]
fn cosigner_key_validation_reports_path_and_fingerprint() {
    let mut env = TestEnv::new();
    let (btc_a, liq_a) = cosigner_keys(&mut env, MNEMONIC);

    let info = env.ok("validate_cosigner_key", json!({ "key": btc_a }));
    assert_eq!(info["path"].as_str(), Some("48'/1'/0'/2'"));
    assert_eq!(info["fingerprint"].as_str().map(|s| s.len()), Some(8));
    assert!(info["warning"].is_null(), "clean key must not warn: {info}");

    let info = env.ok(
        "validate_cosigner_key",
        json!({ "key": liq_a, "liquid": true }),
    );
    assert_eq!(info["path"].as_str(), Some("87h/1h/0h"));

    // A key whose origin lies about where it was derived: the BIP48 key
    // relabelled as a single-sig account. Every coordinator would agree on
    // the wallet and the device would never sign for it, so it is refused.
    // (A real single-sig account key at its true path still only warns —
    // `multisig::tests::singlesig_account_key_warns_but_is_allowed`.)
    let relabelled = btc_a.replace("48'/1'/0'/2'", "84'/1'/0'");
    let err = env.err("validate_cosigner_key", json!({ "key": relabelled }));
    assert!(err.contains("levels deep"), "got: {err}");

    // And a mainnet key, which a tpub re-encode would otherwise hide.
    let mainnet = btc_a.replace("48'/1'/0'/2'", "48'/0'/0'/2'");
    let err = env.err("validate_cosigner_key", json!({ "key": mainnet }));
    assert!(err.contains("mainnet path"), "got: {err}");
}

/// The end-to-end offline proof: a Liquid multisig wallet opens on both chains
/// and hands out addresses on each. This is what catches a CT descriptor that
/// the registry accepted but LWK cannot actually open — the failure that would
/// otherwise surface only after the wizard claimed success.
#[test]
fn liquid_multisig_opens_and_derives_on_both_chains() {
    let mut env = TestEnv::new();
    let (btc_a, liq_a) = cosigner_keys(&mut env, MNEMONIC);
    let (btc_b, liq_b) = cosigner_keys(&mut env, MNEMONIC_B);

    let summary = env.ok(
        "create_multisig_wallet",
        json!({
            "name": "BothChains",
            "required_sigs": 2,
            "total_signers": 2,
            "cosigner_xpubs": [btc_a, btc_b],
            "local_mnemonics": [MNEMONIC],
            "liquid_xpubs": [liq_a, liq_b],
            "liquid_capable_keys": 2,
        }),
    );
    let id = summary["id"].as_str().expect("wallet id").to_string();

    env.ok("open_wallet", json!({ "wallet_id": id }));

    let btc = env.ok(
        "generate_receive_address",
        json!({ "wallet_id": id, "asset": "BTC" }),
    );
    let btc_addr = btc["address"].as_str().unwrap_or("");
    assert!(
        btc_addr.starts_with("tb1"),
        "P2WSH testnet address expected: {btc_addr:?}"
    );

    let liquid = env.ok(
        "generate_receive_address",
        json!({ "wallet_id": id, "asset": "LBTC" }),
    );
    let liquid_addr = liquid["address"].as_str().unwrap_or("");
    assert!(
        !liquid_addr.is_empty() && liquid_addr != btc_addr,
        "confidential Liquid address expected: {liquid_addr:?}"
    );

    // The descriptor every co-signer arrives at on their own: a SLIP77
    // blinding key derived from the keys (ELIP151, written as the raw bytes a
    // Jade registers — never the `elip151` keyword the device cannot take)
    // over a sortedmulti, so the key order does not matter either.
    let info = env.ok("get_wallet_info", json!({ "wallet_id": id }));
    let desc = info["liquid_descriptor"].as_str().unwrap_or("");
    assert!(desc.starts_with("ct(slip77("), "got: {desc}");
    assert!(desc.contains("elwsh(sortedmulti(2,"), "got: {desc}");
    assert!(!desc.contains("elip151"), "got: {desc}");
    // The Bitcoin side keeps its own account, and never leaks a private key.
    assert_eq!(info["derivation_path"], json!("m/48'/1'/0'/2'"));
    assert!(!info["receive_descriptor"]
        .as_str()
        .unwrap_or("")
        .contains("tprv"));
}

/// The wizard's default name is "My Multisig Wallet", so two multisigs with
/// the same name and threshold are the normal case. Their BDK databases used
/// to be keyed by that name: the second wallet opened the first one's
/// directory and BDK refused it — "Descriptor checksum mismatch" at every
/// open, an entry with nothing to repair.
#[test]
fn two_multisigs_with_the_same_name_open_independently() {
    let mut env = TestEnv::new();
    let (a, _) = cosigner_keys(&mut env, MNEMONIC);
    let (b, _) = cosigner_keys(&mut env, MNEMONIC_B);
    let (c, _) = cosigner_keys(&mut env, MNEMONIC_C);
    fn create(env: &mut TestEnv, keys: [&str; 2]) -> String {
        let summary = env.ok(
            "create_multisig_wallet",
            json!({
                "name": "My Multisig Wallet",
                "required_sigs": 2,
                "total_signers": 2,
                "cosigner_xpubs": keys,
                "local_mnemonics": [MNEMONIC],
            }),
        );
        summary["id"].as_str().expect("wallet id").to_string()
    }
    fn address(env: &mut TestEnv, id: &str) -> String {
        env.ok("open_wallet", json!({ "wallet_id": id }));
        let out = env.ok(
            "generate_receive_address",
            json!({ "wallet_id": id, "asset": "BTC" }),
        );
        out["address"].as_str().unwrap_or("").to_string()
    }
    let first = create(&mut env, [&a, &b]);
    let second = create(&mut env, [&a, &c]);

    let first_addr = address(&mut env, &first);
    let second_addr = address(&mut env, &second);
    assert!(first_addr.starts_with("tb1"), "{first_addr:?}");
    assert_ne!(first_addr, second_addr, "two wallets, two address sets");

    // Deleting one must not take the other's database with it.
    env.ok("delete_wallet", json!({ "wallet_id": first }));
    assert_eq!(address(&mut env, &second), second_addr);
}

/// Two apps build one 2-of-2 from the same two BIP87 keys, in opposite order,
/// and it is the same wallet — same descriptor, same address. That is what
/// makes the co-signing round trip possible at all: with a random blinding
/// key (the old scheme) each copy was a different Liquid wallet.
#[test]
fn liquid_multisig_rebuilt_from_the_same_keys_is_the_same_wallet() {
    let mut a = TestEnv::new();
    let mut b = TestEnv::new();
    let (btc_a, liq_a) = cosigner_keys(&mut a, MNEMONIC);
    let (btc_b, liq_b) = cosigner_keys(&mut a, MNEMONIC_B);
    let wa = shared_liquid_multisig(&mut a, [&btc_a, &btc_b], [&liq_a, &liq_b], MNEMONIC);
    let wb = shared_liquid_multisig(&mut b, [&btc_b, &btc_a], [&liq_b, &liq_a], MNEMONIC_B);
    a.ok("open_wallet", json!({ "wallet_id": wa }));
    b.ok("open_wallet", json!({ "wallet_id": wb }));

    let ia = a.ok("get_wallet_info", json!({ "wallet_id": wa }));
    let ib = b.ok("get_wallet_info", json!({ "wallet_id": wb }));
    // Byte-identical on Liquid, blinding key included. (The Bitcoin
    // descriptor's text keeps the typed key order — BDK's sortedmulti sorts
    // inside the script — so it is compared by the addresses below.)
    assert_eq!(ia["liquid_descriptor"], ib["liquid_descriptor"]);
    for asset in ["BTC", "LBTC"] {
        let addr = |env: &mut TestEnv, id: &str| {
            env.ok(
                "generate_receive_address",
                json!({ "wallet_id": id, "asset": asset }),
            )["address"]
                .as_str()
                .unwrap()
                .to_string()
        };
        assert_eq!(addr(&mut a, &wa), addr(&mut b, &wb), "{asset}");
    }
}

/// One co-signer's copy of a shared 2-of-2: the multisig built from both
/// keys on both chains, holding `local` as its own seed.
fn shared_liquid_multisig(
    env: &mut TestEnv,
    btc: [&str; 2],
    liq: [&str; 2],
    local: &str,
) -> String {
    let summary = env.ok(
        "create_multisig_wallet",
        json!({
            "name": "Shared",
            "required_sigs": 2,
            "total_signers": 2,
            "cosigner_xpubs": btc,
            "local_mnemonics": [local],
            "liquid_xpubs": liq,
            "liquid_capable_keys": 2,
        }),
    );
    summary["id"].as_str().expect("wallet id").to_string()
}

/// The whole Liquid multisig round trip, on the Templar Protocol's local
/// regtest node: A funds the shared wallet and starts a spend, B co-signs it from
/// its own copy of the wallet, A finalizes and broadcasts. Every step is the
/// same engine call the app makes.
#[test]
#[ignore = "needs the protocol's regtest elementsd at 127.0.0.1:18884"]
fn liquid_multisig_round_trip_on_regtest() {
    use crate::state::ChainSyncOutcome;
    let rpc = templar_core::ElementsRpcBackend::new("http://127.0.0.1:18884", "templar", "templar")
        .expect("rpc client");
    let mut a = TestEnv::new();
    let mut b = TestEnv::new();
    a.ok("set_liquid_network", json!({ "network": "regtest" }));
    b.ok("set_liquid_network", json!({ "network": "regtest" }));
    let policy = a.ok("get_liquid_network", json!({}))["policy_asset"]
        .as_str()
        .unwrap()
        .to_string();

    let (btc_a, liq_a) = cosigner_keys(&mut a, MNEMONIC);
    let (btc_b, liq_b) = cosigner_keys(&mut a, MNEMONIC_B);
    let wa = shared_liquid_multisig(&mut a, [&btc_a, &btc_b], [&liq_a, &liq_b], MNEMONIC);
    let wb = shared_liquid_multisig(&mut b, [&btc_b, &btc_a], [&liq_b, &liq_a], MNEMONIC_B);
    a.ok("open_wallet", json!({ "wallet_id": wa }));
    b.ok("open_wallet", json!({ "wallet_id": wb }));

    // Fund A's copy; B's copy must see the coin too.
    let addr = a.ok(
        "generate_receive_address",
        json!({ "wallet_id": wa, "asset": "LBTC" }),
    )["address"]
        .as_str()
        .unwrap()
        .to_string();
    rpc.wallet_call_json("ops", "sendtoaddress", &[json!(addr), json!(0.001)])
        .expect("fund the shared wallet");
    let miner = rpc
        .wallet_call_json("ops", "getnewaddress", &[])
        .expect("miner address");
    rpc.call_json("generatetoaddress", &[json!(1), miner])
        .expect("mine a block");
    for env in [&mut a, &mut b] {
        let outcome = crate::handlers::wallet_ops::sync_liquid(&mut env.state);
        assert!(matches!(outcome, ChainSyncOutcome::Ok), "{outcome:?}");
    }

    // A starts the spend: its one key signs, the PSET comes back short.
    let dest = rpc
        .wallet_call_json("ops", "getnewaddress", &[])
        .expect("destination")
        .as_str()
        .unwrap()
        .to_string();
    let sent = a.ok(
        "send_transaction",
        json!({
            "wallet_id": wa,
            "outputs": [{ "address": dest, "amount_sats": 50_000 }],
            "asset_id": policy,
            "fee_rate": 0.1,
        }),
    );
    assert_eq!(sent["sigs_have"], json!(1), "{sent}");
    assert_eq!(sent["sigs_needed"], json!(2), "{sent}");
    assert_eq!(sent["chain"], json!("liquid"), "{sent}");
    let partial = sent["partial_pset"].as_str().unwrap().to_string();

    // B reads it as its own wallet's transaction — amounts in the clear —
    // and adds the second signature.
    let seen = b.ok(
        "inspect_pset",
        json!({ "wallet_id": wb, "pset_base64": partial }),
    );
    assert_eq!(seen["sigs_have"], json!(1), "{seen}");
    assert_eq!(seen["sigs_needed"], json!(2), "{seen}");
    assert_eq!(seen["can_finalize"], json!(false), "{seen}");
    assert_eq!(seen["inputs"][0]["is_ours"], json!(true), "{seen}");
    assert_eq!(seen["inputs"][0]["threshold"], json!(2), "{seen}");
    let paid: Vec<i64> = seen["recipients"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|r| r["amount_sats"].as_i64())
        .collect();
    assert!(paid.contains(&50_000), "B must read the amount: {seen}");
    let signed = b.ok(
        "sign_pset",
        json!({ "wallet_id": wb, "pset_base64": partial }),
    );
    let signed = signed.as_str().unwrap().to_string();
    let after = b.ok(
        "inspect_pset",
        json!({ "wallet_id": wb, "pset_base64": signed }),
    );
    assert_eq!(after["sigs_have"], json!(2), "{after}");
    assert_eq!(after["can_finalize"], json!(true), "{after}");

    // A gets it back and broadcasts.
    let txid = a.ok(
        "broadcast_pset",
        json!({ "wallet_id": wa, "pset_base64": signed }),
    );
    assert_eq!(txid.as_str().map(str::len), Some(64), "{txid}");
}

/// The PSET co-signing ops are routed and validate their input before doing
/// anything expensive. Without this, a renamed method would fail at the worst
/// possible moment — with a half-signed transaction in hand.
#[test]
fn pset_cosign_methods_are_routed_and_reject_garbage() {
    let mut env = TestEnv::new();
    let id = env.create_test_wallet();
    for method in [
        "inspect_pset",
        "sign_pset",
        "sign_pset_hw",
        "broadcast_pset",
    ] {
        let err = env.err(
            method,
            json!({ "wallet_id": id, "pset_base64": "not-a-pset" }),
        );
        assert!(
            !err.contains("Unknown method"),
            "{method} is not routed: {err}"
        );
    }
    let err = env.err(
        "combine_psets",
        json!({ "wallet_id": id, "psets": ["only-one"] }),
    );
    assert!(err.contains("at least two"), "got: {err}");
}

/// A coordinator folds a co-signer's copy into the one it hands out. Two
/// copies of one transaction combine; a different transaction is refused
/// with the reason; a single copy is not a combine.
#[test]
fn combine_psbts_merges_signed_copies_and_refuses_strangers() {
    let mut env = TestEnv::new();
    let err = env.err("combine_psbts", json!({ "psbts": ["only-one"] }));
    assert!(err.contains("at least two"), "got: {err}");

    let err = env.err(
        "combine_psbts",
        json!({ "psbts": ["not-a-psbt", "not-a-psbt-either"] }),
    );
    assert!(!err.contains("Unknown method"), "not routed: {err}");

    // Two different unsigned transactions: refused, naming the copy.
    // (Any two structurally valid PSBTs with different unsigned txs.)
    let a = "cHNidP8BAFICAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD/////AQAAAAAAAAAAFgAUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    let b = "cHNidP8BAFICAAAAAQEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD/////AQAAAAAAAAAAFgAUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    // A copy combined with itself is itself.
    let same = env.ok("combine_psbts", json!({ "psbts": [a, a] }));
    assert_eq!(same, json!(a));
    let err = env.err("combine_psbts", json!({ "psbts": [a, b] }));
    assert!(
        err.contains("not a signed copy of this transaction"),
        "got: {err}"
    );
}

// ── Frozen coins ─────────────────────────────────────────────────────────────

/// The prevout of the zero-input PSBT used by the combine test below.
const ZERO_OUTPOINT: &str = "0000000000000000000000000000000000000000000000000000000000000000:0";
const ZERO_INPUT_PSBT: &str = "cHNidP8BAFICAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD/////AQAAAAAAAAAAFgAUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";

#[test]
fn frozen_coins_persist_on_the_sealed_registry_entry() {
    let mut env = TestEnv::new();
    let id = env.create_test_wallet();
    let freeze = |frozen: bool| json!({ "wallet_id": id, "chain": "BTC", "outpoints": [ZERO_OUTPOINT], "frozen": frozen });

    assert!(env.ok("set_utxos_frozen", freeze(true)).is_null());
    // Read back from disk, through the vault: the list is part of the
    // sealed registry, not a side file.
    let reloaded = env.state.load_registry().expect("reload registry");
    let entry = reloaded.find(&id).expect("entry");
    assert!(
        entry.frozen.bitcoin.contains(ZERO_OUTPOINT),
        "{:?}",
        entry.frozen
    );
    assert!(entry.frozen.liquid.is_empty(), "chains are kept apart");

    env.ok("set_utxos_frozen", freeze(false));
    let reloaded = env.state.load_registry().expect("reload registry");
    assert!(reloaded.find(&id).expect("entry").frozen.is_empty());
}

#[test]
fn set_utxos_frozen_rejects_what_it_cannot_store() {
    let mut env = TestEnv::new();
    let id = env.create_test_wallet();
    let err = env.err(
        "set_utxos_frozen",
        json!({ "wallet_id": id, "chain": "Doge", "outpoints": [ZERO_OUTPOINT], "frozen": true }),
    );
    assert!(err.contains("Unknown chain"), "got: {err}");
    let err = env.err(
        "set_utxos_frozen",
        json!({ "wallet_id": id, "chain": "Liquid", "outpoints": ["nope"], "frozen": true }),
    );
    assert!(err.contains("Invalid outpoint"), "got: {err}");
    let err = env.err(
        "set_utxos_frozen",
        json!({ "wallet_id": "nope", "chain": "BTC", "outpoints": [ZERO_OUTPOINT], "frozen": true }),
    );
    assert!(err.contains("Wallet not found"), "got: {err}");
}

#[test]
fn a_frozen_coin_is_refused_by_coin_control_and_by_the_signer() {
    let mut env = TestEnv::new();
    let id = env.create_test_wallet();
    env.ok("open_wallet", json!({ "wallet_id": id }));
    env.ok(
        "set_utxos_frozen",
        json!({ "wallet_id": id, "chain": "BTC", "outpoints": [ZERO_OUTPOINT], "frozen": true }),
    );

    // Picked by hand: refused before BDK is even asked.
    let err = env.err(
        "preview_transaction",
        json!({
            "wallet_id": id,
            "address": "tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx",
            "amount_sats": 10_000,
            "asset_id": "BTC",
            "fee_rate": 2.0,
            "utxos": [ZERO_OUTPOINT],
        }),
    );
    assert!(err.contains("is frozen"), "got: {err}");

    // Built elsewhere and handed over for a signature: refused too.
    let err = env.err(
        "sign_psbt",
        json!({ "wallet_id": id, "psbt_base64": ZERO_INPUT_PSBT }),
    );
    assert!(err.contains("is frozen"), "got: {err}");
}

// ── Liquid network selection (testnet / regtest) ─────────────────────────────

#[test]
fn liquid_network_defaults_to_testnet_and_matches_dart_decode_shape() {
    let mut env = TestEnv::new();
    let info = env.ok("get_liquid_network", json!({}));
    // Exact keys LiquidNetworkInfo.fromJson reads (ffi_wallet_bridge.dart).
    assert_keys(
        "get_liquid_network",
        &info,
        &[
            "network",
            "short_name",
            "policy_asset",
            "backend",
            "backend_description",
            "env_locked",
            "regtest_default_policy_asset",
        ],
    );
    assert_eq!(info["network"], json!("liquid-testnet"));
    assert_eq!(info["short_name"], json!("testnet"));
    assert_eq!(
        info["policy_asset"],
        json!(templar_core::TESTNET_POLICY_ASSET)
    );
    assert_eq!(info["env_locked"], json!(false));
    assert_eq!(
        info["regtest_default_policy_asset"],
        json!(templar_core::REGTEST_DEFAULT_POLICY_ASSET)
    );
    // The description never leaks RPC credentials.
    let desc = info["backend_description"].as_str().unwrap_or("");
    assert!(!desc.contains("templar:templar"), "{desc}");
}

#[test]
fn switching_to_regtest_closes_the_wallet_and_reopens_it_there() {
    let mut env = TestEnv::new();
    let created = env.ok(
        "create_wallet",
        json!({ "name": "Regtest Test", "mnemonic": MNEMONIC, "liquid": true }),
    );
    let id = created["id"].as_str().unwrap().to_string();

    // Testnet first: the wallet reports it and hands out tlq1 addresses.
    let info = env.ok("get_wallet_info", json!({ "wallet_id": id }));
    assert_eq!(info["liquid_network"], json!("liquid-testnet"));
    let addr = env.ok(
        "generate_receive_address",
        json!({ "wallet_id": id, "asset": "LBTC" }),
    );
    let testnet_addr = addr["address"].as_str().unwrap_or("").to_string();
    assert!(testnet_addr.starts_with("tlq1"), "got {testnet_addr}");
    assert_eq!(env.state.active_wallet_id.as_deref(), Some(id.as_str()));

    // Switch. The open wallet is closed: its Liquid side was built on the
    // other network.
    let switched = env.ok("set_liquid_network", json!({ "network": "regtest" }));
    assert_eq!(switched["network"], json!("liquid-regtest"));
    assert_eq!(
        switched["policy_asset"],
        json!(templar_core::REGTEST_DEFAULT_POLICY_ASSET)
    );
    assert_eq!(switched["backend"], json!("elements_rpc"));
    assert!(
        env.state.active_wallet_id.is_none(),
        "switch must close the wallet"
    );

    // The setting is persisted — under the test dir, never in ~/.config.
    let cfg = std::fs::read_to_string(env.dir.join("templar_wallet.json")).unwrap();
    assert!(cfg.contains("liquid-regtest"), "{cfg}");

    // Reopened lazily on the next call, on regtest: el1 addresses, the
    // regtest policy asset as L-BTC on the dashboard.
    let info = env.ok("get_wallet_info", json!({ "wallet_id": id }));
    assert_eq!(info["liquid_network"], json!("liquid-regtest"));
    let addr = env.ok(
        "generate_receive_address",
        json!({ "wallet_id": id, "asset": "LBTC" }),
    );
    let regtest_addr = addr["address"].as_str().unwrap_or("").to_string();
    assert!(regtest_addr.starts_with("el1"), "got {regtest_addr}");
    assert_ne!(regtest_addr, testnet_addr);

    let dash = env.ok("get_wallet_summary", json!({ "wallet_id": id }));
    assert_eq!(dash["liquid_network"], json!("liquid-regtest"));
    let lbtc = dash["assets"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| a["ticker"] == json!("LBTC"))
        .expect("an L-BTC row");
    assert_eq!(
        lbtc["asset_id"],
        json!(templar_core::REGTEST_DEFAULT_POLICY_ASSET)
    );

    // And back: testnet again, config entry gone (absent = testnet).
    env.ok("set_liquid_network", json!({ "network": "testnet" }));
    let info = env.ok("get_wallet_info", json!({ "wallet_id": id }));
    assert_eq!(info["liquid_network"], json!("liquid-testnet"));
    let cfg = std::fs::read_to_string(env.dir.join("templar_wallet.json")).unwrap();
    assert!(!cfg.contains("liquid_network"), "{cfg}");
}

#[test]
fn set_liquid_network_rejects_bad_values() {
    let mut env = TestEnv::new();
    let err = env.err("set_liquid_network", json!({ "network": "mainnet" }));
    assert!(err.contains("unknown Liquid network"), "{err}");
    let err = env.err(
        "set_liquid_network",
        json!({ "network": "regtest", "policy_asset": "not-hex" }),
    );
    assert!(err.contains("policy asset"), "{err}");
    // Nothing changed.
    let info = env.ok("get_liquid_network", json!({}));
    assert_eq!(info["network"], json!("liquid-testnet"));

    // A custom regtest policy asset is honoured.
    let custom = "aa".repeat(32);
    let switched = env.ok(
        "set_liquid_network",
        json!({ "network": "liquid-regtest", "policy_asset": custom }),
    );
    assert_eq!(switched["policy_asset"], json!(custom));
}

#[test]
fn regtest_refuses_the_public_services_with_a_clear_error() {
    let mut env = TestEnv::new();
    let id = env.create_test_wallet();
    env.ok("set_liquid_network", json!({ "network": "regtest" }));

    let err = env.err(
        "peg_quote",
        json!({ "direction": "in", "amount_sats": 100_000 }),
    );
    assert!(err.contains("not available on Liquid regtest"), "{err}");
    let err = env.err("peg_list", json!({ "wallet_id": id }));
    assert!(err.contains("not available on Liquid regtest"), "{err}");
    let err = env.err("list_swaps", json!({ "include_unavailable": false }));
    assert!(err.contains("not available on Liquid regtest"), "{err}");
    let err = env.err(
        "reregister_asset",
        json!({
            "wallet_id": id, "asset_id": "aa".repeat(32), "name": "X",
            "ticker": "X", "precision": 8, "domain": "example.com"
        }),
    );
    assert!(err.contains("not available on Liquid regtest"), "{err}");
}

/// The whole regtest path the app takes, against the Templar Protocol's local node:
/// open a wallet on regtest, get funded by the node's `ops` wallet, sync
/// through `elementsd` RPC, see the balance, send, see it move.
///
/// Needs the protocol's regtest node running (see the Templar Protocol
/// repository); run with `cargo test -p wallet-ffi -- --ignored regtest_node`.
#[test]
#[ignore = "needs the Templar Protocol's regtest elementsd on 127.0.0.1:18884"]
fn regtest_node_sync_and_send_end_to_end() {
    let rpc = templar_core::ElementsRpcBackend::new(
        templar_core::DEFAULT_ELEMENTS_RPC_URL,
        templar_core::DEFAULT_ELEMENTS_RPC_USER,
        templar_core::DEFAULT_ELEMENTS_RPC_PASS,
    )
    .expect("rpc client");
    let ops = |method: &str, args: &[Value]| {
        rpc.wallet_call_json("ops", method, args)
            .unwrap_or_else(|e| panic!("ops {method}: {e}"))
    };
    let mine = || {
        let addr = ops("getnewaddress", &[]);
        ops("generatetoaddress", &[json!(1), addr]);
    };
    let lbtc_of = |dash: &Value| -> i64 {
        dash["assets"]
            .as_array()
            .unwrap()
            .iter()
            .find(|a| a["ticker"] == json!("LBTC"))
            .expect("L-BTC row")["amount"]
            .as_i64()
            .unwrap()
    };

    let mut env = TestEnv::new();
    env.ok("set_liquid_network", json!({ "network": "regtest" }));
    // A fresh seed so the balance starts at zero.
    let words = env.ok("generate_mnemonic", json!({ "word_count": 12 }));
    let mnemonic = words
        .as_array()
        .unwrap()
        .iter()
        .map(|w| w.as_str().unwrap())
        .collect::<Vec<_>>()
        .join(" ");
    let created = env.ok(
        "create_wallet",
        json!({ "name": "Regtest E2E", "mnemonic": mnemonic, "liquid": true }),
    );
    let id = created["id"].as_str().unwrap().to_string();

    let addr = env.ok(
        "generate_receive_address",
        json!({ "wallet_id": id, "asset": "LBTC" }),
    );
    let addr = addr["address"].as_str().unwrap().to_string();
    assert!(
        addr.starts_with("el1"),
        "regtest address expected, got {addr}"
    );

    // Fund from the node's own wallet and confirm.
    ops("sendtoaddress", &[json!(addr), json!("0.5")]);
    mine();

    let outcome = env.ok("sync_wallet", json!({ "wallet_id": id }));
    assert_eq!(outcome["liquid"], json!("ok"), "sync: {outcome}");
    let dash = env.ok("get_wallet_summary", json!({ "wallet_id": id }));
    assert_eq!(dash["liquid_network"], json!("liquid-regtest"));
    assert_eq!(lbtc_of(&dash), 50_000_000, "{dash}");

    // Spend: 10 000 sats to a fresh address of our own.
    let dest = env.ok(
        "generate_receive_address",
        json!({ "wallet_id": id, "asset": "LBTC", "fresh": true }),
    );
    let dest = dest["address"].as_str().unwrap().to_string();
    let sent = env.ok(
        "send_transaction",
        json!({
            "wallet_id": id,
            "asset_id": templar_core::REGTEST_DEFAULT_POLICY_ASSET,
            "fee_rate": 0.1,
            "outputs": [{ "address": dest, "amount_sats": 10_000 }],
        }),
    );
    let txid = sent.as_str().expect("txid string");
    assert_eq!(txid.len(), 64, "txid: {txid}");

    mine();
    let outcome = env.ok("sync_wallet", json!({ "wallet_id": id }));
    assert_eq!(outcome["liquid"], json!("ok"), "sync: {outcome}");
    let dash = env.ok("get_wallet_summary", json!({ "wallet_id": id }));
    let after = lbtc_of(&dash);
    // Self-send: only the fee leaves the wallet.
    assert!(
        after < 50_000_000 && after > 49_990_000,
        "balance after send: {after}"
    );
    let activity = dash["recent_activity"].as_array().unwrap();
    assert!(
        activity.iter().any(|a| a["txid"] == json!(txid)),
        "sent tx must show in recent activity: {activity:?}"
    );
}

// ── Templar Protocol connector ─────────────────────────────────────

/// A testnet PSET spending a fake Templar Protocol escrow whose contract names the
/// test mnemonic's `2121'` key (borrower) and a second key (lender): one
/// external payout, one fee output. Generated by templar-core's
/// `liquid::protocol::tests::print_escrow_fixture`.
const ESCROW_FIXTURE: &str = "cHNldP8BAgQCAAAAAQQBAQEFAQIB+wQCAAAAAAEBTgFJmoGFRfa645/AO2N/Kk4eZOWQysG8Om9tcapEQ2VMFAEAAAAAAA9CQAAiACCgE5MA82qHuUPx4nzHNwjxWCSc8+rg4rQ5CNB5Vs74AAEFclIhAhdnH707KagoCN5XkC2n+EOOzDitCmvJT01Ihb6KrdQaIQNjxKZ9muqLcb6BIp5cvl1jHmT6QMHHAlKIgyIYaGd7QlKuc2QhA2PEpn2a6otxvoEinly+XWMeZPpAwccCUoiDIhhoZ3tCrQOg8BmxaCIGAhdnH707KagoCN5XkC2n+EOOzDitCmvJT01Ihb6KrdQaGHPF2gpJCACAAQAAgAAAAIAAAAAABwAAACIGA2PEpn2a6otxvoEinly+XWMeZPpAwccCUoiDIhhoZ3tCGD9jWmNJCACAAQAAgAAAAIAAAAAABwAAAAEOICIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiAQ8EAAAAAAf8BHBzZXQRCEBCDwAAAAAAB/wEcHNldBMgSZqBhUX2uuOfwDtjfypOHmTlkMrBvDpvbXGqRENlTBQAAQMITEAPAAAAAAAH/ARwc2V0AiBJmoGFRfa645/AO2N/Kk4eZOWQysG8Om9tcapEQ2VMFAEEFgAUAQIDBAUGBwgJCgsMDQ4PEBESExQAAQMI9AEAAAAAAAAH/ARwc2V0AiBJmoGFRfa645/AO2N/Kk4eZOWQysG8Om9tcapEQ2VMFAEEAAA=";

#[test]
fn get_protocol_escrow_xpub_has_the_protocol_shape() {
    let mut env = TestEnv::new();
    let id = env.create_test_wallet();
    let xpub = env.ok("get_protocol_escrow_xpub", json!({ "wallet_id": id }));
    let xpub = xpub.as_str().expect("keyorigin xpub string");
    assert!(
        xpub.starts_with("[73c5da0a/2121h/1h/0h]tpub"),
        "docs/connector-protocol.md §2 shape expected, got {xpub}"
    );
    // The same value the core derives directly.
    assert_eq!(
        xpub,
        templar_core::escrow_xpub_from_mnemonic(MNEMONIC).unwrap()
    );

    // A watch-only wallet has no seed to derive the account from.
    let (fp, account) = templar_core::account_xpub_bip84(MNEMONIC).unwrap();
    let wo = env.ok(
        "create_watch_only_wallet",
        json!({
            "name": "Watch",
            "recv_desc": format!("wpkh([{fp}/84'/1'/0']{account}/0/*)"),
            "change_desc": format!("wpkh([{fp}/84'/1'/0']{account}/1/*)"),
        }),
    );
    let wo_id = wo["id"].as_str().unwrap().to_string();
    let err = env.err("get_protocol_escrow_xpub", json!({ "wallet_id": wo_id }));
    assert!(err.contains("software wallet"), "{err}");
    let err = env.err("get_protocol_escrow_xpub", json!({ "wallet_id": "nope" }));
    assert!(err.contains("not found"), "{err}");
}

#[test]
fn inspect_pset_describes_a_protocol_escrow_spend() {
    let mut env = TestEnv::new();
    let created = env.ok(
        "create_wallet",
        json!({ "name": "Borrower", "mnemonic": MNEMONIC, "liquid": true }),
    );
    let id = created["id"].as_str().unwrap().to_string();

    let d = env.ok(
        "inspect_pset",
        json!({ "wallet_id": id, "pset_base64": ESCROW_FIXTURE }),
    );
    // Exact keys PsetInspection.fromJson reads (pset_inspection.dart).
    assert_keys(
        "inspect_pset",
        &d,
        &[
            "network",
            "fee_sats",
            "fee_display",
            "recipients",
            "inputs",
            "outputs",
            "sigs_have",
            "sigs_needed",
            "signers_present",
            "signers_missing",
            "can_finalize",
            "raw_pset",
        ],
    );
    assert_eq!(d["network"], json!("liquid-testnet"));
    assert_eq!(d["fee_sats"], json!(500));

    let inputs = d["inputs"].as_array().unwrap();
    assert_eq!(inputs.len(), 1);
    assert_keys(
        "inputs[0]",
        &inputs[0],
        &[
            "index",
            "outpoint",
            "is_ours",
            "script_type",
            "witness_script",
            "witness_script_asm",
            "asset_id",
            "ticker",
            "amount_sats",
            "display_amount",
            "key_fingerprints",
            "signed_by",
        ],
    );
    assert_eq!(
        inputs[0]["is_ours"],
        json!(true),
        "our 2121' key is in the escrow"
    );
    assert_eq!(inputs[0]["script_type"], json!("p2wsh"));
    assert!(inputs[0]["witness_script"].is_string());
    assert!(inputs[0]["witness_script_asm"]
        .as_str()
        .unwrap()
        .contains("OP_CHECKMULTISIG"));
    assert_eq!(inputs[0]["amount_sats"], json!(1_000_000));
    assert_eq!(inputs[0]["ticker"], json!("L-BTC"));
    assert!(inputs[0]["key_fingerprints"]
        .as_array()
        .unwrap()
        .contains(&json!("73c5da0a")));
    assert_eq!(inputs[0]["signed_by"], json!([]));

    let outputs = d["outputs"].as_array().unwrap();
    assert_keys(
        "outputs[0]",
        &outputs[0],
        &[
            "index",
            "kind",
            "script_type",
            "address",
            "asset_id",
            "ticker",
            "amount_sats",
            "display_amount",
        ],
    );
    let kinds: Vec<&str> = outputs
        .iter()
        .map(|o| o["kind"].as_str().unwrap())
        .collect();
    assert_eq!(kinds, ["external", "fee"]);
    assert_eq!(outputs[0]["amount_sats"], json!(999_500));
    assert_eq!(d["recipients"].as_array().unwrap().len(), 1);

    // Signing through the same route the co-sign screen and the templar://
    // handler use adds the borrower's escrow signature.
    let signed = env.ok(
        "sign_pset",
        json!({ "wallet_id": id, "pset_base64": ESCROW_FIXTURE }),
    );
    let signed = signed.as_str().unwrap().to_string();
    let after = env.ok(
        "inspect_pset",
        json!({ "wallet_id": id, "pset_base64": signed }),
    );
    assert_eq!(after["inputs"][0]["signed_by"], json!(["73c5da0a"]));
    assert_eq!(after["sigs_have"], json!(1));

    // On regtest the same PSET is refused: it carries testnet L-BTC.
    env.ok("set_liquid_network", json!({ "network": "regtest" }));
    let err = env.err(
        "inspect_pset",
        json!({ "wallet_id": id, "pset_base64": ESCROW_FIXTURE }),
    );
    assert!(err.contains("Network mismatch"), "{err}");
    assert!(err.contains("Liquid testnet"), "{err}");
}

/// Without the `hardware` feature (the Android build) the hardware routes stay
/// in the contract: `hwi_status` says so explicitly, and every USB entry point
/// answers with the stable `HW_UNSUPPORTED` tag — never "Unknown method".
#[cfg(not(feature = "hardware"))]
#[test]
fn hardware_routes_answer_unsupported_without_the_feature() {
    let mut env = TestEnv::new();
    let v = env.ok("hwi_status", json!({}));
    assert_eq!(v["hardware_supported"], json!(false), "{v}");
    assert_eq!(v["hwi_usable"], json!(false), "{v}");
    assert_eq!(v["liquid_hw_signing"], json!(false), "{v}");
    assert_eq!(v["hid_device_count"], json!(0), "{v}");
    assert_eq!(v["native_families"], json!([]), "{v}");
    assert!(v["platform"].is_string(), "{v}");
    assert!(v["resolved_bin"].is_null(), "{v}");
    for method in [
        "enumerate_hw_devices",
        "enumerate_native_devices",
        "jade_ports",
        "import_hw_wallet",
        "sign_psbt_hw",
        "verify_hw_address",
        "set_hwi_path",
        "add_liquid_to_wallet",
    ] {
        let err = env.err(method, json!({}));
        assert!(err.starts_with("HW_UNSUPPORTED: "), "{method}: {err}");
    }
    // The pure descriptor helper is not hardware and must keep working.
    let ct = env.ok(
        "derive_liquid_descriptor",
        json!({ "btc_desc": "tpubDCVwWj4hEpeWNFcWe3Eo1DrkLnPC4c2iitjw5wAuTkSZgofJbRMD4KESh1uhsqLCCjcjR36JooEFwfWf1ezwmAfjcPCxc7KNtnfBCrMPdtT" }),
    );
    assert!(
        ct.as_str().unwrap_or("").starts_with("ct(elip151,elwpkh("),
        "{ct}"
    );
}
