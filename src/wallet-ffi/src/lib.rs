//! C FFI entry points for the Templar Wallet Flutter app.
//!
//! Exposes three functions:
//!   - `wallet_call(method, params_json) -> json_result`  — main dispatch
//!   - `wallet_free_string(ptr)` — free a string returned by wallet_call
//!   - `wallet_set_data_dir(path)` — optional, before the first call: where
//!     the engine keeps its files (Android has no default location)
//!
//! All communication is JSON strings. Responses are either:
//!   `{"ok": <value>}` or `{"err": "<message>"}`.

mod dispatch;
mod handlers;
mod state;
mod types;

#[cfg(test)]
mod contract_tests;

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use zeroize::Zeroize;

use once_cell::sync::{Lazy, OnceCell};

use state::AppFfiState;

static STATE: Lazy<Mutex<AppFfiState>> = Lazy::new(|| Mutex::new(AppFfiState::new()));

/// Data directory chosen by the host app before the first `wallet_call`,
/// consulted ahead of the `TEMPLAR_DATA_DIR` env override in
/// [`AppFfiState::new`]. Android is the reason it exists: the platform has no
/// XDG data dir (`dirs_next::data_dir()` is `None`), Dart cannot set
/// environment variables, and `std::env::set_var` is undefined behavior once
/// Flutter's engine threads are running.
static DATA_DIR_OVERRIDE: OnceCell<PathBuf> = OnceCell::new();

pub(crate) fn data_dir_override() -> Option<&'static Path> {
    DATA_DIR_OVERRIDE.get().map(PathBuf::as_path)
}

/// Point the engine at a data directory. Must run before the first
/// `wallet_call`; the host passes its app-private storage path (Android:
/// `getApplicationSupportDirectory()`). Config, registry, vault and the sled
/// databases all live under it.
///
/// Returns 0 on success, 1 for a null or non-UTF-8 string, 2 for an empty
/// path, 3 when it is too late (the engine already initialized, or a
/// different directory was set earlier) — the path is then ignored.
///
/// # Safety
/// `path` must be a valid null-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn wallet_set_data_dir(path: *const c_char) -> i32 {
    if path.is_null() {
        return 1;
    }
    let dir = match CStr::from_ptr(path).to_str() {
        Ok(s) => s.trim(),
        Err(_) => return 1,
    };
    if dir.is_empty() {
        return 2;
    }
    if Lazy::get(&STATE).is_some() {
        return 3;
    }
    match DATA_DIR_OVERRIDE.set(PathBuf::from(dir)) {
        Ok(()) => 0,
        Err(_) if data_dir_override() == Some(Path::new(dir)) => 0,
        Err(_) => 3,
    }
}

/// Call a wallet method.
///
/// # Safety
/// `method` and `params` must be valid null-terminated UTF-8 strings.
/// The returned pointer must be freed with `wallet_free_string`.
#[no_mangle]
pub unsafe extern "C" fn wallet_call(method: *const c_char, params: *const c_char) -> *mut c_char {
    let method_str = match CStr::from_ptr(method).to_str() {
        Ok(s) => s,
        Err(_) => return error_cstring("invalid method string"),
    };

    let params_str = match CStr::from_ptr(params).to_str() {
        Ok(s) => s,
        Err(_) => return error_cstring("invalid params string"),
    };

    let params_val: serde_json::Value = match serde_json::from_str(params_str) {
        Ok(v) => v,
        Err(e) => {
            return error_cstring(&format!("params parse error: {}", e));
        }
    };

    // A panic must not unwind across the C boundary — that aborts the whole
    // app. Catch it and surface it as a normal error; recover a poisoned lock
    // (the state may be mid-mutation, but every handler validates before it
    // persists, so continuing beats killing the process).
    let response = std::panic::catch_unwind(|| match STATE.lock() {
        Ok(mut state) => dispatch::dispatch(&mut state, method_str, &params_val),
        Err(poisoned) => {
            let mut state = poisoned.into_inner();
            dispatch::dispatch(&mut state, method_str, &params_val)
        }
    })
    .unwrap_or_else(|panic| {
        let msg = panic
            .downcast_ref::<&str>()
            .map(|s| s.to_string())
            .or_else(|| panic.downcast_ref::<String>().cloned())
            .unwrap_or_else(|| "unknown panic".to_string());
        serde_json::json!({ "err": format!("internal error ({method_str}): {msg}") })
    });

    let mut response = response;
    let mut params_val = params_val;
    // Serialize straight into a buffer with room for the trailing NUL so
    // CString::new does not reallocate (and leave an unwiped copy behind).
    let mut json =
        serde_json::to_vec(&response).unwrap_or_else(|_| br#"{"err":"serialize fail"}"#.to_vec());
    json.reserve_exact(1);
    // The Value trees are the longest-lived copies of anything secret a
    // response or a request carried (mnemonics, xprvs, the vault key hex):
    // wipe every string in them before they drop.
    zeroize_json_strings(&mut response);
    zeroize_json_strings(&mut params_val);

    CString::new(json)
        .unwrap_or_else(|_| CString::new(r#"{"err":"nul in response"}"#).unwrap())
        .into_raw()
}

/// Overwrite every string in a JSON tree in place (arrays and objects
/// recursively). Numbers and booleans carry nothing secret in this API.
fn zeroize_json_strings(v: &mut serde_json::Value) {
    match v {
        serde_json::Value::String(s) => s.zeroize(),
        serde_json::Value::Array(a) => a.iter_mut().for_each(zeroize_json_strings),
        serde_json::Value::Object(m) => m.values_mut().for_each(zeroize_json_strings),
        _ => {}
    }
}

/// Free a string previously returned by `wallet_call`.
///
/// The buffer is overwritten before it is released. Some responses carry a
/// mnemonic or an xprv, and a plain free leaves that plaintext sitting in the
/// freed allocation until the allocator happens to reuse it — where a core
/// dump, a swapped page or a heap scan can still read it. Wiping every
/// response costs a memset and removes the need to know which ones were
/// secret.
///
/// # Safety
/// `ptr` must have been returned by `wallet_call` and not already freed.
#[no_mangle]
pub unsafe extern "C" fn wallet_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        let mut bytes = CString::from_raw(ptr).into_bytes();
        bytes.zeroize();
    }
}

fn error_cstring(msg: &str) -> *mut c_char {
    let json = serde_json::json!({ "err": msg }).to_string();
    CString::new(json)
        .unwrap_or_else(|_| CString::new(r#"{"err":"err"}"#).unwrap())
        .into_raw()
}
