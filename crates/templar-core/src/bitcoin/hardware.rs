//! Hardware wallet support: native in-process drivers, with HWI behind them.
//!
//! All public functions are **blocking** — call from a background thread or Dart isolate.
//!
//! # Two paths, one API
//!
//! Every entry point here tries the [native device layer](super::device) first
//! and falls back to the `hwi` CLI:
//!
//! * **Native** — Ledger over USB HID, Jade over USB serial, both in this
//!   process. No subprocess, no Python, and the only thing that works inside
//!   the macOS App Sandbox (it denies `execve` of a downloaded binary outright,
//!   and hangs one shipped in the bundle).
//! * **HWI** — Trezor, Coldcard, KeepKey and anything else, on Windows and
//!   Linux. Not reachable on macOS at all; [`hwi_usable`] is the one place
//!   that knows, so the fallback is skipped there instead of failing slowly.
//!
//! The split is by *device family*, not by platform: a Ledger takes the same
//! native path on all three operating systems, so a bug found on one is a bug
//! found on all of them, and the platforms cannot quietly diverge.

use bdk::bitcoin::psbt::PartiallySignedTransaction;
use bdk::bitcoin::Network;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::process::Command;
use std::sync::RwLock;

use crate::bitcoin::wallet::WalletManager;
use crate::error::{BitcoinError, HardwareError, TemplarError};

/// Resolved HWI toolchain, installed by the embedder (wallet-ffi) instead of
/// mutating the process environment: `std::env::set_var` is undefined
/// behavior on glibc once other threads exist, and Flutter's engine threads
/// are running long before the FFI initializes. The prepend fields are
/// applied per spawned `hwi` process only — the parent environment is never
/// touched.
#[derive(Debug, Clone, Default)]
pub struct HwiEnv {
    /// Absolute path of the `hwi` executable.
    pub bin: PathBuf,
    /// Venv bin dir to prepend to the child's PATH so the hwi shim's own
    /// tooling resolves.
    pub path_prepend: Option<PathBuf>,
    /// site-packages dir to prepend to the child's PYTHONPATH so hwilib
    /// imports resolve when the shim runs.
    pub pythonpath_prepend: Option<PathBuf>,
}

/// Process-wide HWI toolchain override. An `RwLock`, not a `OnceCell`: the
/// user can install a fresh standalone binary from the UI mid-session, which
/// replaces the toolchain resolved at startup.
static HWI_ENV: RwLock<Option<HwiEnv>> = RwLock::new(None);

/// Install (or replace) the resolved HWI toolchain used by every subsequent
/// `hwi` invocation. Thread-safe; never touches the process environment.
pub fn set_hwi_env(env: HwiEnv) {
    clear_quarantine(&env.bin);
    *HWI_ENV.write().unwrap_or_else(|e| e.into_inner()) = Some(env);
}

/// Strip `com.apple.quarantine` from a binary we are about to execute.
///
/// macOS tags anything an app downloads with that attribute, and Gatekeeper
/// then refuses to exec it — which surfaces as "could not run hwi" *right
/// after* a successful install, the most confusing possible outcome. Doing it
/// here rather than in Dart is deliberate: `/usr/bin/xattr` is a Python script
/// and shelling out to it fails in exactly the environments that need this.
///
/// Best-effort and silent: no attribute, no permission, or a non-macOS host
/// are all fine.
#[cfg(target_os = "macos")]
fn clear_quarantine(path: &std::path::Path) {
    use std::os::raw::{c_char, c_int};
    extern "C" {
        fn removexattr(path: *const c_char, name: *const c_char, options: c_int) -> c_int;
    }
    if path.as_os_str().is_empty() {
        return;
    }
    let Ok(path_c) = std::ffi::CString::new(path.as_os_str().as_encoded_bytes()) else {
        return;
    };
    // SAFETY: both pointers are NUL-terminated C strings that outlive the call,
    // and removexattr only reads them.
    unsafe {
        removexattr(path_c.as_ptr(), c"com.apple.quarantine".as_ptr(), 0);
    }
}

#[cfg(not(target_os = "macos"))]
fn clear_quarantine(_path: &std::path::Path) {}

/// The currently installed HWI toolchain override, if any.
pub fn hwi_env() -> Option<HwiEnv> {
    HWI_ENV.read().unwrap_or_else(|e| e.into_inner()).clone()
}

/// Serializable summary of a connected hardware device.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HwDeviceInfo {
    pub model: String,
    pub fingerprint: String,
    pub path: String,
}

/// Everything one device hands over for a pairing, read in a single session.
///
/// One session matters: a Jade prompts for its PIN on every connection and only
/// one program can hold its serial port, so reading the Bitcoin descriptors and
/// the Liquid one through separate connections meant two prompts and a race the
/// second connection could lose. Both sides of a wallet now come from the same
/// unlocked device, which is also what makes `fingerprint` trustworthy as the
/// single identity for both.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HwPairing {
    /// Master fingerprint, lower-case hex. The wallet's device binding.
    pub fingerprint: String,
    /// Model as the device reports it ("Blockstream Jade", "Nano S").
    pub model: String,
    pub receive_descriptor: String,
    pub change_descriptor: String,
    /// Liquid CT descriptor, when Liquid was asked for and the device has it.
    pub liquid_ct_descriptor: Option<String>,
    /// Why the Liquid side is missing, when it was asked for and could not be
    /// read. Carried instead of failing the whole pairing: a working Bitcoin
    /// wallet plus a stated reason beats no wallet at all, and the recap screen
    /// shows the user exactly which half is missing.
    pub liquid_error: Option<String>,
}

impl HwPairing {
    /// Whether both requested sides came back.
    pub fn is_complete(&self) -> bool {
        self.liquid_error.is_none()
    }
}

// ── Stable error kinds ────────────────────────────────────────────────────────
//
// Every hardware error string starts with one of these prefixes followed by
// ": ". The UI branches on the prefix instead of sniffing free text, so the
// same wording can be adapted per platform without breaking the logic — and
// so a message change never silently turns a fixable state ("HWI missing",
// which has an in-app installer) into a dead end.

/// The `hwi` executable could not be found or could not be spawned.
pub const ERR_HWI_MISSING: &str = "HWI_MISSING";
/// The OS refused access to the device — Linux udev rules, or the macOS
/// sandbox missing a device entitlement.
pub const ERR_HWI_PERMISSION: &str = "HWI_PERMISSION";
/// A device is attached but not usable yet: locked, wrong app open, busy.
pub const ERR_DEVICE_NOT_READY: &str = "DEVICE_NOT_READY";
/// No device matching the requested fingerprint is attached.
pub const ERR_DEVICE_NOT_FOUND: &str = "DEVICE_NOT_FOUND";
/// The device was reached but refused or failed to sign.
pub const ERR_SIGNING: &str = "SIGNING_FAILED";

fn tagged(kind: &str, msg: impl std::fmt::Display) -> TemplarError {
    HardwareError::ConnectionFailed(format!("{kind}: {msg}")).into()
}

// ── Native / HWI routing ──────────────────────────────────────────────────────

/// Whether the HWI fallback can run on this platform at all.
///
/// False on macOS, and not as a policy choice: the App Sandbox denies `execve`
/// of a binary in the app's data container (EPERM), and a copy inside the
/// bundle execs but then hangs in HWI's PyInstaller bootloader — measured at
/// no completion after four minutes, against 6.5 s unsandboxed. Trying anyway
/// costs the user a long wait before the same failure, so callers skip
/// straight to the native path and say plainly when a family has no driver.
pub const fn hwi_usable() -> bool {
    !cfg!(target_os = "macos")
}

/// Names of the device families this build drives natively, for UI copy.
pub fn native_family_names() -> Vec<&'static str> {
    use super::device::DeviceFamily::*;
    [
        Ledger,
        Trezor,
        Coldcard,
        KeepKey,
        BitBox02,
        DigitalBitbox,
        Jade,
    ]
    .into_iter()
    .filter(|f| f.is_drivable())
    .map(|f| f.label())
    .collect()
}

/// Open the device with this fingerprint natively, if it is one we can drive.
///
/// `None` means "not a native device" — the caller falls back to HWI. An
/// attached-but-unhappy device is an error, not a `None`: falling back to HWI
/// for a locked Ledger would replace an accurate "unlock it" with a slow
/// "no devices found".
fn native_for(
    fingerprint: &str,
) -> Result<Option<(super::device::NativeDeviceInfo, super::device::Device)>, TemplarError> {
    use super::device::DeviceError;
    match super::device::open_by_fingerprint(fingerprint) {
        Ok(found) => Ok(Some(found)),
        // No native device answered to this fingerprint. Where HWI can run,
        // that is simply "not ours" and the subprocess takes over.
        Err(DeviceError::NotFound { .. } | DeviceError::Unsupported { .. }) if hwi_usable() => {
            Ok(None)
        }
        // Where it cannot, there is no second path, and saying so beats
        // letting the caller fail later on a missing binary — which reads as
        // "install HWI" and would send the user after a fix that cannot work.
        Err(DeviceError::NotFound { .. } | DeviceError::Unsupported { .. }) => Err(tagged(
            ERR_DEVICE_NOT_FOUND,
            format!(
                "No device this app can drive is connected. Directly supported here: {}. \
                 Other makes need a helper process that macOS will not let this app start — \
                 use one of those over USB, or sign air-gapped by QR.",
                native_family_names().join(", ")
            ),
        )),
        Err(e) => Err(e.into()),
    }
}

// ── HWI subprocess helpers ────────────────────────────────────────────────────

/// Locate the hwi binary, platform-agnostic. Resolution order:
///   1. Embedder override installed via [`set_hwi_env`] (wallet-ffi resolves
///      the toolchain once at startup, or when the UI installs a binary).
///   2. `TEMPLAR_HWI_BIN` — manual user override via the environment.
///   3. Known venv locations relative to $HOME (legacy dev layouts).
///   4. `hwi` found on PATH (Windows: `hwi.exe`).
///
/// Returns `None` when nothing resolves, so callers can raise
/// [`ERR_HWI_MISSING`] — which the UI answers with the in-app installer —
/// instead of spawning a bare `hwi` that fails with a raw OS error.
///
/// This is the single source of truth: both the subprocess runner and the
/// status probe the UI polls go through it, so "what the status says" and
/// "what actually runs" can never drift apart.
pub fn resolve_hwi_bin() -> Option<PathBuf> {
    if let Some(env) = hwi_env() {
        if env.bin.exists() {
            return Some(env.bin);
        }
    }
    if let Ok(bin) = std::env::var("TEMPLAR_HWI_BIN") {
        let bin = bin.trim().to_string();
        if !bin.is_empty() && std::path::Path::new(&bin).exists() {
            return Some(PathBuf::from(bin));
        }
    }
    // PATH scan, done here rather than by handing the OS a bare "hwi": we need
    // to know whether it exists to distinguish "not installed" from "failed".
    let exe = if cfg!(windows) { "hwi.exe" } else { "hwi" };
    std::env::var_os("PATH").and_then(|paths| {
        std::env::split_paths(&paths)
            .map(|dir| dir.join(exe))
            .find(|p| p.is_file())
    })
}

/// `hwi --version` output (e.g. `"3.2.0"`), or None when hwi is unavailable.
/// Purely diagnostic — shown in the UI and worth quoting in bug reports.
pub fn hwi_version() -> Option<String> {
    let bin = resolve_hwi_bin()?;
    let mut cmd = Command::new(&bin);
    cmd.arg("--version");
    apply_hwi_env(&mut cmd);
    let out = cmd.output().ok()?;
    let text = String::from_utf8_lossy(&out.stdout);
    let text = if text.trim().is_empty() {
        String::from_utf8_lossy(&out.stderr).to_string()
    } else {
        text.to_string()
    };
    text.split_whitespace().last().map(|s| s.to_string())
}

/// Apply the embedder-resolved toolchain paths to a child process only (never
/// via `set_var` — see [`HwiEnv`]). A dir already present in the inherited
/// value is not prepended again.
fn apply_hwi_env(cmd: &mut Command) {
    let Some(env) = hwi_env() else { return };
    let sep = if cfg!(windows) { ";" } else { ":" };
    let prepends = [
        ("PATH", env.path_prepend),
        ("PYTHONPATH", env.pythonpath_prepend),
    ];
    for (key, dir) in prepends {
        let Some(dir) = dir else { continue };
        let dir_s = dir.to_string_lossy().to_string();
        let current = std::env::var(key).unwrap_or_default();
        if current.contains(&dir_s) {
            continue;
        }
        let value = if current.is_empty() {
            dir_s
        } else {
            format!("{dir_s}{sep}{current}")
        };
        cmd.env(key, value);
    }
}

/// Platform-specific tail for a permission failure. The remedy genuinely
/// differs per OS, and a generic "access denied" leaves the user stuck.
fn permission_hint() -> &'static str {
    if cfg!(target_os = "linux") {
        "Linux needs udev rules before a non-root user can talk to the device. \
         Install them from the hardware setup screen (\"Fix device permissions\"), \
         then unplug and replug the device."
    } else if cfg!(target_os = "macos") {
        "macOS denied access to the device. Unplug and replug it, and make sure \
         no other wallet app (Ledger Live, Blockstream Green) is holding it."
    } else {
        "Windows denied access to the device. Unplug and replug it, close any \
         other wallet app using it, and for a Ledger make sure no other process \
         holds the HID handle."
    }
}

/// True when an HWI device-level error means "the OS won't let us in".
/// HWI reports this as code -16 (NEED_TO_BE_ROOT); the text match catches
/// transports that surface the OS error directly instead.
fn is_permission_error(code: Option<i64>, text: &str) -> bool {
    if code == Some(-16) {
        return true;
    }
    let t = text.to_lowercase();
    t.contains("permission")
        || t.contains("access denied")
        || t.contains("udev")
        || t.contains("must be root")
        || t.contains("operation not permitted")
}

/// Run hwi with the given args and return the parsed JSON output.
///
/// Every failure exits through a tagged error ([`ERR_HWI_MISSING`] and
/// friends) so the UI can offer the right remedy on every platform.
fn hwi_json(args: &[&str]) -> Result<serde_json::Value, TemplarError> {
    let bin = resolve_hwi_bin().ok_or_else(|| {
        tagged(
            ERR_HWI_MISSING,
            "The HWI toolkit is not installed. Install it from the hardware \
             setup screen, or point TEMPLAR_HWI_BIN at an `hwi` binary.",
        )
    })?;
    eprintln!("[hw] {} {}", bin.display(), args.join(" "));

    let mut cmd = Command::new(&bin);
    cmd.args(args);
    apply_hwi_env(&mut cmd);
    // Windows: `Command` spawning a console binary from a GUI app flashes a
    // console window on every HWI call. CREATE_NO_WINDOW suppresses it.
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    let out = cmd.output().map_err(|e| {
        // Spawn failed: the file is there (resolve_hwi_bin checked) but cannot
        // run — a broken/partial install, or a binary for the wrong arch.
        tagged(
            ERR_HWI_MISSING,
            format!(
                "Could not run hwi ({}): {e}. Reinstall the HWI toolkit from \
                 the hardware setup screen.",
                bin.display()
            ),
        )
    })?;

    let stdout = std::str::from_utf8(&out.stdout).unwrap_or("").trim();
    let stderr = std::str::from_utf8(&out.stderr).unwrap_or("").trim();

    if !stderr.is_empty() {
        eprintln!("[hw] hwi stderr: {stderr}");
    }
    if stdout.is_empty() {
        // No stdout at all is an hwi-level failure, not a device one. A
        // permission problem can land here on some transports.
        if is_permission_error(None, stderr) {
            return Err(tagged(
                ERR_HWI_PERMISSION,
                format!("{}\n\nhwi said: {stderr}", permission_hint()),
            ));
        }
        return Err(tagged(
            ERR_DEVICE_NOT_READY,
            format!(
                "hwi returned no output (exit {}). stderr: {stderr}",
                out.status
            ),
        ));
    }

    let json: serde_json::Value = serde_json::from_str(stdout).map_err(|e| {
        tagged(
            ERR_DEVICE_NOT_READY,
            format!("hwi output not valid JSON: {e}\noutput: {stdout}"),
        )
    })?;

    // A single-object response carrying "error" is how hwi reports a failed
    // command (as opposed to `enumerate`, which returns an array). Classify it
    // here so every caller — sign, displayaddress, getxpub — gets the same
    // actionable message instead of an unhandled "no psbt field".
    if let Some(err) = json.get("error").and_then(|e| e.as_str()) {
        let code = json.get("code").and_then(|c| c.as_i64());
        if is_permission_error(code, err) {
            return Err(tagged(
                ERR_HWI_PERMISSION,
                format!("{}\n\nhwi said: {err}", permission_hint()),
            ));
        }
        return Err(tagged(ERR_DEVICE_NOT_READY, err));
    }

    Ok(json)
}

/// From an HWI descriptor array, return the native segwit `wpkh(...)` descriptor.
/// `wpkh(` is unambiguous: `pkh(` (legacy), `sh(wpkh(` (nested) and `tr(` (taproot)
/// all start with a different prefix.
fn pick_wpkh(arr: &serde_json::Value) -> Option<String> {
    arr.as_array()?
        .iter()
        .filter_map(|v| v.as_str())
        .find(|d| d.trim_start().starts_with("wpkh("))
        .map(|s| s.to_string())
}

// ── WalletManager impl ────────────────────────────────────────────────────────

impl WalletManager {
    // ── Enumerate ─────────────────────────────────────────────────────────────

    /// List all connected USB hardware wallets, from both paths.
    ///
    /// Native devices are asked directly; anything else is left to HWI where
    /// HWI can run. The two never report the same device twice — the families
    /// are disjoint by construction ([`DeviceFamily::is_drivable`]).
    ///
    /// A native device that is attached but not talking is reported as an
    /// error only when *nothing* was found: with a working Jade next to a
    /// locked Ledger, the Jade is the answer and the Ledger is noise.
    ///
    /// [`DeviceFamily::is_drivable`]: super::device::DeviceFamily::is_drivable
    pub fn enumerate_hw_devices() -> Result<Vec<HwDeviceInfo>, TemplarError> {
        let (native, native_errors, attached) = super::device::enumerate_drivable();
        let mut devices: Vec<HwDeviceInfo> = native
            .into_iter()
            .map(|(info, fingerprint)| HwDeviceInfo {
                model: info.model,
                fingerprint,
                path: info.path,
            })
            .collect();

        // Only pay for a subprocess when a family that needs one is attached.
        // Read from the same scan that produced the native list: a second
        // enumeration could see a different bus, and then the error message
        // would describe devices that are no longer the ones we tried.
        let needs_hwi = attached.iter().any(|d| !d.family.is_drivable());

        // Ask HWI when a family that needs it is attached — and also when our
        // own scan came up empty. The USB id table only knows the models it
        // lists, so a device it does not recognise (a new Trezor revision, a
        // DIY board) would otherwise be invisible on the two platforms where
        // HWI is exactly the catch-all for that case. Never on macOS, where the
        // subprocess cannot run, and never when a native device already
        // answered — that is the common path and it must stay subprocess-free.
        if hwi_usable() && (needs_hwi || devices.is_empty()) {
            match Self::enumerate_hwi_devices() {
                Ok(mut found) => devices.append(&mut found),
                // Speculative sweep: nothing on the bus was recognised, so this
                // was a long shot. Reporting its failure would turn "nothing is
                // plugged in" into "install HWI", which sends the user after a
                // fix for a problem they do not have.
                Err(e) if !needs_hwi => {
                    eprintln!("[hw] speculative HWI sweep found nothing: {e}");
                }
                // Native devices already answered: an HWI failure on top of
                // that is not the user's problem right now.
                Err(e) if !devices.is_empty() => {
                    eprintln!("[hw] native devices found; ignoring HWI error: {e}");
                }
                Err(e) => return Err(e),
            }
        }

        // Second line of defence against listing one device twice. The
        // transports dedupe their own device nodes, but a device reachable both
        // natively and through HWI, or a bus that reports it twice, would still
        // arrive here as two entries with one fingerprint — and the picker
        // would ask the user to choose between a device and itself.
        // `retain`, not `dedup_by`: the latter only drops *adjacent* duplicates,
        // and the two halves of this list are appended, not interleaved.
        let mut seen: Vec<String> = Vec::new();
        devices.retain(|d| {
            let fp = d.fingerprint.to_lowercase();
            if seen.contains(&fp) {
                eprintln!("[hw] dropping duplicate listing of device {fp}");
                false
            } else {
                seen.push(fp);
                true
            }
        });

        if devices.is_empty() {
            if !native_errors.is_empty() {
                return Err(tagged(
                    ERR_DEVICE_NOT_READY,
                    format!(
                        "A device was detected but is not ready: {}",
                        native_errors.join("; ")
                    ),
                ));
            }
            if needs_hwi && !hwi_usable() {
                return Err(tagged(
                    ERR_DEVICE_NOT_READY,
                    format!(
                        "The attached device needs a helper process that macOS will not let \
                         this app start. Devices driven directly: {}. Use one of those over \
                         USB, or sign air-gapped by QR.",
                        native_family_names().join(", ")
                    ),
                ));
            }
        }
        Ok(devices)
    }

    /// The HWI half of [`Self::enumerate_hw_devices`].
    fn enumerate_hwi_devices() -> Result<Vec<HwDeviceInfo>, TemplarError> {
        let json = hwi_json(&["enumerate"])?;
        let arr = json.as_array().ok_or_else(|| {
            tagged(
                ERR_DEVICE_NOT_READY,
                "hwi enumerate did not return an array",
            )
        })?;

        // HWI reports a device that errored (locked, wrong app open, missing
        // udev rule on Linux) as an entry carrying an "error" field and no
        // fingerprint. Dropping those silently turns every such condition
        // into an unexplained "no devices found".
        let mut devices = Vec::new();
        let mut errors = Vec::new();
        let mut permission_denied = false;
        for d in arr {
            match (d["model"].as_str(), d["fingerprint"].as_str()) {
                (Some(model), Some(fp)) => devices.push(HwDeviceInfo {
                    model: model.to_string(),
                    fingerprint: fp.to_string(),
                    path: d["path"].as_str().unwrap_or("").to_string(),
                }),
                _ => {
                    let model = d["model"].as_str().unwrap_or("unknown device");
                    let err = d["error"].as_str().unwrap_or("no fingerprint reported");
                    let code = d["code"].as_i64();
                    if is_permission_error(code, err) {
                        permission_denied = true;
                    }
                    errors.push(format!("{model}: {err}"));
                }
            }
        }

        eprintln!(
            "[hw] {} device(s) found, {} errored",
            devices.len(),
            errors.len()
        );
        for e in &errors {
            eprintln!("[hw] device error: {e}");
        }
        if devices.is_empty() && !errors.is_empty() {
            // Permission wins over "not ready": on Linux this is the single
            // most common first-run failure and it has a concrete fix the UI
            // can offer, whereas "not ready" only tells the user to fiddle.
            let kind = if permission_denied {
                ERR_HWI_PERMISSION
            } else {
                ERR_DEVICE_NOT_READY
            };
            let detail = errors.join("; ");
            let message = if permission_denied {
                format!("{}\n\nhwi said: {detail}", permission_hint())
            } else {
                format!("A device was detected but is not ready: {detail}")
            };
            return Err(tagged(kind, message));
        }
        Ok(devices)
    }

    /// Alias kept for egui code paths.
    pub fn list_hardware_wallets() -> Result<Vec<HwDeviceInfo>, TemplarError> {
        Self::enumerate_hw_devices()
    }

    // ── Descriptors ───────────────────────────────────────────────────────────

    /// Read descriptors from the device identified by `fingerprint`.
    ///
    /// Returns `(recv_desc, change_desc, fingerprint, model)`.
    pub fn hw_descriptors_by_fingerprint(
        fingerprint: &str,
    ) -> Result<(String, String, String, String), TemplarError> {
        if let Some((info, device)) = native_for(fingerprint)? {
            let (recv, change) = device.wpkh_descriptors()?;
            return Ok((recv, change, fingerprint.to_lowercase(), info.model));
        }

        let devices = Self::enumerate_hw_devices()?;
        let device = devices
            .iter()
            .find(|d| d.fingerprint.eq_ignore_ascii_case(fingerprint))
            .ok_or_else(|| {
                tagged(
                    ERR_DEVICE_NOT_FOUND,
                    format!("Device {fingerprint} not found. Reconnect and try again."),
                )
            })?;

        let json = hwi_json(&["-f", fingerprint, "--chain", "test", "getdescriptors"])?;

        // HWI `getdescriptors` returns one descriptor per address type, ordered
        // LEGACY (pkh), WIT (wpkh), SH_WIT (sh(wpkh)), TAP (tr). Taking element [0]
        // would give the LEGACY P2PKH descriptor, which the rest of the wallet does
        // not support (finalize, Liquid ELIP151 derivation, the m/84'/1'/0' UI all
        // assume native segwit). Explicitly pick the wpkh(...) descriptor.
        let recv = pick_wpkh(&json["receive"]).ok_or_else(|| {
            tagged(
                ERR_DEVICE_NOT_READY,
                "Device did not return a native segwit (wpkh) descriptor",
            )
        })?;

        let change = pick_wpkh(&json["internal"]).ok_or_else(|| {
            tagged(
                ERR_DEVICE_NOT_READY,
                "Device did not return a native segwit (wpkh) change descriptor",
            )
        })?;

        Ok((
            recv,
            change,
            device.fingerprint.clone(),
            device.model.clone(),
        ))
    }

    /// Read everything a pairing needs from one device, in one session.
    ///
    /// `want_liquid` asks for the Liquid CT descriptor as well; it is only ever
    /// satisfied by a Jade, and a refusal lands in
    /// [`HwPairing::liquid_error`] rather than failing the Bitcoin side with it.
    ///
    /// Prefer this over calling [`Self::hw_descriptors_by_fingerprint`] and the
    /// Liquid connect separately: each connection to a Jade costs a PIN entry
    /// and takes exclusive hold of its serial port.
    pub fn hw_pairing(fingerprint: &str, want_liquid: bool) -> Result<HwPairing, TemplarError> {
        if let Some((info, device)) = native_for(fingerprint)? {
            let (receive_descriptor, change_descriptor) = device.wpkh_descriptors()?;
            let mut liquid_ct_descriptor = None;
            let mut liquid_error = None;
            if want_liquid {
                // Same open handle: no second PIN, no second port claim.
                match device.ct_descriptor() {
                    Ok(desc) => liquid_ct_descriptor = Some(desc),
                    Err(e) => liquid_error = Some(e.to_string()),
                }
            }
            return Ok(HwPairing {
                fingerprint: fingerprint.to_lowercase(),
                model: info.model,
                receive_descriptor,
                change_descriptor,
                liquid_ct_descriptor,
                liquid_error,
            });
        }

        // HWI device: Bitcoin only, and that is a firmware fact rather than a
        // gap in this build — every family behind HWI is Bitcoin-only.
        let (receive_descriptor, change_descriptor, fp, model) =
            Self::hw_descriptors_by_fingerprint(fingerprint)?;
        Ok(HwPairing {
            fingerprint: fp,
            model,
            receive_descriptor,
            change_descriptor,
            liquid_ct_descriptor: None,
            liquid_error: want_liquid.then(|| {
                format!(
                    "{}: {}",
                    crate::liquid::hardware::ERR_LIQUID_HW_UNSUPPORTED,
                    crate::liquid::hardware::liquid_hw_unsupported_reason()
                )
            }),
        })
    }

    /// The Liquid CT descriptor of a connected device, without touching the
    /// Bitcoin side. For adding Liquid to a wallet that was paired Bitcoin-only.
    ///
    /// The device must be the one the wallet belongs to: `fingerprint` is
    /// matched by [`native_for`], so a second Jade on the desk cannot lend its
    /// Liquid descriptor to another device's wallet.
    pub fn hw_liquid_ct_descriptor(fingerprint: &str) -> Result<String, TemplarError> {
        let Some((_, device)) = native_for(fingerprint)? else {
            return Err(tagged(
                crate::liquid::hardware::ERR_LIQUID_HW_UNSUPPORTED,
                crate::liquid::hardware::liquid_hw_unsupported_reason(),
            ));
        };
        Ok(device.ct_descriptor()?)
    }

    /// Fetch the BIP48 P2WSH cosigner xpub (testnet: `m/48'/1'/0'/2'`) from a
    /// connected USB device, in the `[fingerprint/48'/1'/0'/2']tpub…` keyorigin
    /// form that `MultisigSetupInfo` expects — the same shape
    /// `keyorigin_xpub_bip48` produces for software keys.
    pub fn hw_cosigner_xpub(fingerprint: &str) -> Result<String, TemplarError> {
        if let Some((_, device)) = native_for(fingerprint)? {
            return Ok(device.cosigner_xpub()?);
        }
        // h-notation avoids apostrophes in the CLI arg; HWI accepts both.
        let json = hwi_json(&[
            "-f",
            fingerprint,
            "--chain",
            "test",
            "getxpub",
            "m/48h/1h/0h/2h",
        ])?;
        let xpub = json["xpub"]
            .as_str()
            .ok_or_else(|| tagged(ERR_DEVICE_NOT_READY, "hwi getxpub: no xpub field"))?;
        Ok(format!(
            "[{}/48'/1'/0'/2']{}",
            fingerprint.to_lowercase(),
            xpub
        ))
    }

    // ── Create wallet from hardware device ────────────────────────────────────

    /// Import a hardware wallet: fetch its descriptors, open a BDK watch-only wallet.
    pub fn from_hardware_wallet(
        data_dir: &std::path::Path,
        device: &HwDeviceInfo,
    ) -> Result<Self, TemplarError> {
        use bdk::Wallet;

        let (recv_desc, change_desc, fp_str, model_str) =
            Self::hw_descriptors_by_fingerprint(&device.fingerprint)?;

        let db = sled::open(data_dir.join("bdk_hw_db"))
            .map_err(|e| BitcoinError::InvalidDescriptor(format!("DB open: {e}")))?;
        let tree = db
            .open_tree(&fp_str)
            .map_err(|e| BitcoinError::InvalidDescriptor(format!("DB tree: {e}")))?;

        let wallet = Wallet::new(&recv_desc, Some(&change_desc), Network::Testnet, tree)
            .map_err(|e| BitcoinError::InvalidDescriptor(e.to_string()))?;

        let pub_info = Self::pub_info_from_descriptor(&recv_desc, &[]);
        eprintln!("[hw] imported {model_str} [{fp_str}]");

        Ok(Self {
            wallet,
            receive_descriptor: Some(recv_desc),
            pub_info,
            is_multisig: false,
        })
    }

    // ── Sign ──────────────────────────────────────────────────────────────────

    /// Sign a PSBT using the hardware wallet identified by `device.fingerprint`.
    /// Returns `true` if any new signatures were added.
    pub fn sign_with_hardware_wallet(
        &self,
        psbt: &mut PartiallySignedTransaction,
        device: &HwDeviceInfo,
    ) -> Result<bool, TemplarError> {
        let psbt_b64 = Self::psbt_to_base64(psbt);
        // This wallet knows its own descriptor — pass it, so a Ledger can
        // rebuild the right policy instead of assuming single-sig.
        let signed_b64 = Self::sign_psbt_with_hw_desc(
            &device.fingerprint,
            &psbt_b64,
            self.receive_descriptor.as_deref(),
        )?;

        let signed = Self::psbt_from_base64(&signed_b64)
            .map_err(|e| tagged(ERR_SIGNING, format!("PSBT deserialize: {e}")))?;

        let sigs_before: usize = psbt.inputs.iter().map(|i| i.partial_sigs.len()).sum();
        *psbt = signed;
        let sigs_after: usize = psbt.inputs.iter().map(|i| i.partial_sigs.len()).sum();

        Ok(sigs_after > sigs_before)
    }

    // ── Verify address on device ──────────────────────────────────────────────

    /// Ask the device to display address at `index` for confirmation.
    pub fn verify_address_on_device(
        &self,
        device: &HwDeviceInfo,
        address_index: u32,
    ) -> Result<String, TemplarError> {
        let recv_desc = self
            .receive_descriptor
            .as_deref()
            .map(crate::derivation::public_descriptor)
            .ok_or_else(|| tagged(ERR_DEVICE_NOT_READY, "No descriptor"))?;
        let recv_desc = recv_desc.as_str();

        if let Some((_, dev)) = native_for(&device.fingerprint)? {
            return Ok(dev.display_address(recv_desc, address_index)?);
        }

        // Substitute `/*` with the concrete index to get a descriptor for one address.
        let base = recv_desc.split('#').next().unwrap_or(recv_desc).trim();
        let indexed = base
            .replace("/0/*)", &format!("/0/{address_index})"))
            .replace("/0/*", &format!("/0/{address_index}"))
            .replace("/*)", &format!("/{address_index})"))
            .replace("/*", &format!("/{address_index}"));

        let json = hwi_json(&[
            "-f",
            &device.fingerprint,
            "--chain",
            "test",
            "displayaddress",
            "--desc",
            &indexed,
        ])?;

        json["address"]
            .as_str()
            .map(|s| s.to_string())
            .ok_or_else(|| tagged(ERR_DEVICE_NOT_READY, "hwi displayaddress: no address field"))
    }

    // ── PSBT sign via subprocess (standalone, no WalletManager needed) ────────

    /// Sign a PSBT (base64) using the device identified by `fingerprint`.
    ///
    /// Refuses to return a PSBT the device did not actually add a signature to.
    /// HWI answers `{"psbt": "…", "signed": false}` when the user rejects on
    /// screen or the device holds no key for these inputs; passing that back
    /// unchecked surfaced later as an opaque finalize/broadcast failure, which
    /// reads like a network fault rather than "you declined on the device".
    pub fn sign_psbt_with_hw(fingerprint: &str, psbt_b64: &str) -> Result<String, TemplarError> {
        Self::sign_psbt_with_hw_desc(fingerprint, psbt_b64, None)
    }

    /// [`Self::sign_psbt_with_hw`], told which wallet the PSBT belongs to.
    ///
    /// A Ledger signs under a *wallet policy*, and for multisig that policy
    /// can only be rebuilt from the wallet's descriptor — the PSBT carries
    /// public keys and origins, not the cosigners' xpubs. Callers that know
    /// the wallet pass its receive descriptor; the rest get single-sig, which
    /// the device derives from its own key. Jade and HWI ignore the argument.
    pub fn sign_psbt_with_hw_desc(
        fingerprint: &str,
        psbt_b64: &str,
        descriptor: Option<&str>,
    ) -> Result<String, TemplarError> {
        if let Some((_, device)) = native_for(fingerprint)? {
            // Empty string = "single-sig, from your own key": the drivers
            // treat an unparseable descriptor as unsupported, and a missing
            // one must not read as one.
            let desc = descriptor.unwrap_or("").trim();
            let desc = if desc.is_empty() {
                let (recv, _) = device.wpkh_descriptors()?;
                recv
            } else {
                // Defence in depth: whatever a caller passes, a device only
                // ever sees public keys.
                crate::derivation::public_descriptor(desc)
            };
            return Ok(device.sign_psbt(&desc, psbt_b64)?);
        }

        // --chain test: testnet PSBT, else the device rejects with a network mismatch.
        let json = hwi_json(&["-f", fingerprint, "--chain", "test", "signtx", psbt_b64])?;
        let signed_b64 = json["psbt"]
            .as_str()
            .ok_or_else(|| tagged(ERR_SIGNING, "hwi signtx: no psbt field"))?
            .to_string();

        // Explicit `signed: false` from HWI is authoritative.
        if json["signed"].as_bool() == Some(false) {
            return Err(tagged(
                ERR_SIGNING,
                "The device did not sign this transaction. Approve it on the \
                 device screen, and check the wallet belongs to this device.",
            ));
        }

        // Older HWI versions omit the flag — compare signature counts instead.
        let before = Self::count_partial_sigs(psbt_b64);
        let after = Self::count_partial_sigs(&signed_b64);
        if let (Some(before), Some(after)) = (before, after) {
            if after <= before {
                return Err(tagged(
                    ERR_SIGNING,
                    "The device returned the transaction without adding a \
                     signature. Approve it on the device screen, and check the \
                     wallet belongs to this device.",
                ));
            }
        }
        Ok(signed_b64)
    }

    /// Total `partial_sigs` across all inputs, or None if the PSBT won't parse.
    fn count_partial_sigs(psbt_b64: &str) -> Option<usize> {
        Self::psbt_from_base64(psbt_b64)
            .ok()
            .map(|p| p.inputs.iter().map(|i| i.partial_sigs.len()).sum())
    }

    // ── Liquid descriptor derivation ──────────────────────────────────────────

    /// Derive a Liquid ELIP151 CT descriptor from a Bitcoin receive descriptor.
    ///
    /// Takes `wpkh([fp/path]xpub/0/*)#checksum` and produces
    /// `ct(elip151,wpkh([fp/path]xpub/<0;1>/*))` suitable for LWK.
    ///
    /// ELIP151 derives the blinding key deterministically from the signing key,
    /// so no master secret is needed — works with any hardware wallet.
    pub fn hw_liquid_descriptor(btc_recv_desc: &str) -> Result<String, TemplarError> {
        crate::bitcoin::watch_only::liquid_descriptor_from_wpkh(btc_recv_desc)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// HWI reports "you don't have permission to touch this device" either as
    /// code -16 (NEED_TO_BE_ROOT) or as free text from the transport. Both
    /// must route to the udev remedy — a miss here shows the user "device not
    /// ready", which sends them fiddling with cables instead of pressing the
    /// one button that fixes it.
    #[test]
    fn permission_errors_are_recognised() {
        assert!(is_permission_error(Some(-16), "anything"));
        assert!(is_permission_error(None, "Permission denied"));
        assert!(is_permission_error(None, "PermissionError: [Errno 13]"));
        assert!(is_permission_error(None, "Access denied to the device"));
        assert!(is_permission_error(
            None,
            "you must be root or install udev rules"
        ));
        assert!(is_permission_error(None, "Operation not permitted"));
    }

    /// Ordinary device states must NOT be mistaken for permission problems —
    /// offering to install udev rules for a locked device is noise.
    #[test]
    fn ordinary_device_states_are_not_permission_errors() {
        assert!(!is_permission_error(Some(-12), "Device is not ready"));
        assert!(!is_permission_error(None, "Device is locked"));
        assert!(!is_permission_error(None, "Bitcoin app is not open"));
        assert!(!is_permission_error(None, "Device busy"));
    }

    /// Every tagged error must carry its prefix followed by ": ", because the
    /// UI splits on exactly that to recover the human-readable part.
    #[test]
    fn tagged_errors_carry_a_parseable_prefix() {
        for (kind, expected) in [
            (ERR_HWI_MISSING, "HWI_MISSING"),
            (ERR_HWI_PERMISSION, "HWI_PERMISSION"),
            (ERR_DEVICE_NOT_READY, "DEVICE_NOT_READY"),
            (ERR_DEVICE_NOT_FOUND, "DEVICE_NOT_FOUND"),
            (ERR_SIGNING, "SIGNING_FAILED"),
        ] {
            assert_eq!(kind, expected);
            let msg = tagged(kind, "something went wrong").to_string();
            assert!(
                msg.contains(&format!("{expected}: something went wrong")),
                "got: {msg}"
            );
        }
    }

    /// The permission hint has to name a remedy, not just restate the failure.
    #[test]
    fn permission_hint_is_actionable() {
        let hint = permission_hint();
        assert!(!hint.is_empty());
        if cfg!(target_os = "linux") {
            assert!(hint.contains("udev"), "got: {hint}");
        } else {
            assert!(hint.to_lowercase().contains("replug"), "got: {hint}");
        }
    }

    /// Signature counting underpins the "did the device actually sign?" check.
    /// An unparseable PSBT must yield None so the caller falls back to HWI's
    /// own `signed` flag rather than wrongly claiming nothing was signed.
    #[test]
    fn partial_sig_count_handles_garbage() {
        assert_eq!(WalletManager::count_partial_sigs("not base64 at all"), None);
        // Structurally valid, zero signatures.
        assert_eq!(
            WalletManager::count_partial_sigs("cHNidP8BAAoCAAAAAAAAAAAAAAAA"),
            Some(0)
        );
    }
}

#[cfg(test)]
mod routing_tests {
    use super::*;

    /// The HWI fallback is unreachable inside the macOS App Sandbox — measured,
    /// see the module docs. Callers branch on this to skip a subprocess that
    /// would only fail slowly, so it must track the platform exactly.
    #[test]
    fn hwi_is_usable_everywhere_except_macos() {
        assert_eq!(hwi_usable(), !cfg!(target_os = "macos"));
    }

    /// The UI names these devices in the copy that explains why others are
    /// missing. An empty list would produce "Directly supported here: ." and
    /// leave the user with no route at all.
    #[test]
    fn native_families_are_named_for_the_ui() {
        let names = native_family_names();
        assert!(names.contains(&"Ledger"), "{names:?}");
        assert!(names.contains(&"Blockstream Jade"), "{names:?}");
        assert!(!names.is_empty());
    }

    /// With nothing plugged in there is no native device to route to, and the
    /// answer must be "not ours" rather than an error — otherwise every
    /// HWI-only device on Windows and Linux would fail before reaching HWI.
    #[test]
    fn an_absent_device_falls_through_to_hwi_where_hwi_can_run() {
        // Only meaningful with an empty bus. Routing asks every attached device
        // for its fingerprint, which means *opening* it — and a locked Jade
        // then waits up to 90 s for a PIN nobody is going to type on a
        // developer's desk, so with hardware attached this test would report a
        // timeout as a routing bug.
        if super::super::device::enumerate_native()
            .unwrap_or_default()
            .iter()
            .any(|d| d.family.is_drivable())
        {
            eprintln!("skipped: a drivable device is attached");
            return;
        }
        let result = native_for("00000000");
        if hwi_usable() {
            assert!(matches!(result, Ok(None)), "should fall through to HWI");
        } else {
            // On macOS there is no second path, so the user is told directly.
            let err = result.err().expect("macOS has no fallback").to_string();
            assert!(err.contains(ERR_DEVICE_NOT_FOUND), "{err}");
            assert!(
                err.contains("Ledger"),
                "must name a device that works: {err}"
            );
        }
    }
}
