//! Native, in-process hardware wallet device access.
//!
//! # Why this exists
//!
//! Everything device-related used to go through the `hwi` CLI as a child
//! process. That cannot work on macOS: the App Sandbox denies `execve` of a
//! binary in the app's data container outright (EPERM, with or without the
//! quarantine attribute), and a copy placed inside the `.app` bundle execs but
//! then hangs indefinitely — HWI's PyInstaller bootloader unpacks itself and
//! forks, which the sandbox does not survive. Measured on macOS 15: 6.5 s for
//! `hwi enumerate` unsandboxed, versus no completion at all after four minutes
//! inside the sandbox.
//!
//! Talking to the device from our own process removes the subprocess entirely,
//! which is the only shape that works under the sandbox — and it removes the
//! HWI install step from every platform along the way.
//!
//! # Scope of this module today
//!
//! Enumeration is complete and cross-platform. Ledger and Jade are driven
//! end to end — fingerprint, account xpubs, PSBT signing, on-device address
//! display. The remaining families (Trezor, Coldcard, KeepKey, BitBox) are
//! detected but not driven, and still go through HWI where HWI can run.
//!
//! Detection alone still earns its place for those: on macOS the difference
//! between "no devices found" and "your Trezor is connected, but this build
//! cannot talk to it here" is the difference between a user debugging their
//! cable and a user reading a known limitation.
//!
//! Enumeration itself talks to nothing — it reads USB descriptors the OS has
//! already cached, so it is fast, safe to call repeatedly, and cannot put a
//! device into a bad state. Opening a device ([`open_by_fingerprint`]) does
//! talk to it, and for a Jade will prompt for the PIN.
//!
//! # What each family uses
//!
//! | Family | Transport | Driver |
//! |---|---|---|
//! | Ledger | USB HID | [`ledger`] — Ledger's own client over our framing |
//! | Jade | USB serial | [`jade_btc`] — Jade's CBOR over `lwk_jade` |
//! | Trezor, Coldcard, KeepKey, BitBox | — | detection only; still HWI |
//!
//! The families without a native driver keep working through HWI on Windows
//! and Linux and are refused with an explicit reason on macOS, where HWI
//! cannot run at all. [`is_drivable`] is the single place that says which is
//! which, so the UI, the router in `hardware.rs` and the docs cannot drift
//! apart.

pub mod descriptor;
mod hid;
mod jade_btc;
mod ledger;

use serde::{Deserialize, Serialize};

use crate::error::{HardwareError, TemplarError};

/// Which vendor's protocol a device speaks. The protocol, not the model:
/// every Ledger model shares one APDU dialect, every Jade one CBOR dialect.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DeviceFamily {
    Ledger,
    Trezor,
    Coldcard,
    KeepKey,
    BitBox02,
    DigitalBitbox,
    Jade,
}

impl DeviceFamily {
    /// Whether this build can hold a conversation with the family, as opposed
    /// to merely seeing it on the bus.
    ///
    /// The distinction is the whole reason this module exists: a device we can
    /// see but not drive deserves "your Ledger is connected, but…" rather than
    /// "no devices found", and on macOS — where the HWI fallback cannot run —
    /// it decides whether the wallet can be created at all.
    pub fn is_drivable(self) -> bool {
        matches!(self, DeviceFamily::Ledger | DeviceFamily::Jade)
    }

    /// Display name used in the UI when the exact model is unknown.
    pub fn label(self) -> &'static str {
        match self {
            DeviceFamily::Ledger => "Ledger",
            DeviceFamily::Trezor => "Trezor",
            DeviceFamily::Coldcard => "Coldcard",
            DeviceFamily::KeepKey => "KeepKey",
            DeviceFamily::BitBox02 => "BitBox02",
            DeviceFamily::DigitalBitbox => "Digital Bitbox",
            DeviceFamily::Jade => "Blockstream Jade",
        }
    }
}

/// How we would reach the device.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Transport {
    /// USB HID — Ledger, Trezor One, Coldcard, KeepKey, BitBox02.
    Hid,
    /// USB CDC serial — Jade.
    Serial,
}

/// A device the OS can see, before any conversation with it.
///
/// Deliberately without a master fingerprint: obtaining one means asking the
/// device for an extended public key, which needs the per-family protocol.
/// Leaving the field out is better than inventing a placeholder that the
/// wallet-matching logic would then compare against.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NativeDeviceInfo {
    pub family: DeviceFamily,
    /// Best-effort model name from the USB product string, else the family label.
    pub model: String,
    pub transport: Transport,
    /// HID path or serial port name — stable enough to reopen within a session.
    pub path: String,
    pub vendor_id: u16,
    pub product_id: u16,
    /// USB serial number when the OS exposes one. Not a wallet identifier.
    pub serial_number: Option<String>,
    /// Whether this build can talk to the device, not merely see it.
    ///
    /// Serialised so the UI reads the answer instead of re-deriving it from
    /// the family name — the list of families with a native driver changes,
    /// and a copy of it in Dart would go stale silently.
    pub drivable: bool,
}

/// What went wrong while talking to a device.
///
/// Split by *what the user should do next*, not by where in the stack the
/// failure happened: "you declined on the device" and "the Bitcoin app isn't
/// open" have nothing in common from the user's side, and collapsing both into
/// one signing error is what made the old subprocess path so hard to act on.
#[derive(Debug, Clone)]
pub enum DeviceError {
    /// The device is attached but not in a state where it can answer —
    /// locked, wrong app open, or busy in another program.
    NotReady { device: String, detail: String },
    /// The user pressed reject on the device.
    Declined { device: String },
    /// The device answered, but the request is outside what this build
    /// supports (Taproot script paths, an unregistered multisig policy).
    Unsupported { device: String, detail: String },
    /// The conversation went off the rails — a malformed answer, a bad PSBT.
    Protocol { device: String, detail: String },
    /// The device signed nothing: it holds no key for these inputs.
    NoSignature { device: String },
    /// No attached device reports this fingerprint.
    NotFound { fingerprint: String },
}

impl std::fmt::Display for DeviceError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DeviceError::NotReady { device, detail } => {
                write!(f, "{device} is not ready: {detail}")
            }
            DeviceError::Declined { device } => write!(
                f,
                "The transaction was rejected on the {device}. Nothing was signed."
            ),
            DeviceError::Unsupported { device, detail } => {
                write!(f, "{device}: {detail}")
            }
            DeviceError::Protocol { device, detail } => {
                write!(f, "{device} answered unexpectedly: {detail}")
            }
            DeviceError::NoSignature { device } => write!(
                f,
                "The {device} added no signature — it holds no key for this wallet's inputs."
            ),
            DeviceError::NotFound { fingerprint } => write!(
                f,
                "No connected device reports fingerprint {fingerprint}. Reconnect it and try again."
            ),
        }
    }
}

impl From<DeviceError> for TemplarError {
    /// Keeps the `TAG: message` convention the Flutter side already
    /// classifies on (`hw_error.dart`), so native failures land in the same
    /// buckets — and the same fix-it cards — as the HWI ones did.
    fn from(e: DeviceError) -> TemplarError {
        let tag = match e {
            DeviceError::NotFound { .. } => super::hardware::ERR_DEVICE_NOT_FOUND,
            DeviceError::NotReady { .. } => super::hardware::ERR_DEVICE_NOT_READY,
            DeviceError::Declined { .. }
            | DeviceError::NoSignature { .. }
            | DeviceError::Unsupported { .. }
            | DeviceError::Protocol { .. } => super::hardware::ERR_SIGNING,
        };
        HardwareError::ConnectionFailed(format!("{tag}: {e}")).into()
    }
}

/// An open, drivable device. The variants differ in transport and dialect;
/// everything above this enum works in descriptors, PSBTs and fingerprints.
pub enum Device {
    Ledger(ledger::Ledger),
    Jade(jade_btc::JadeBitcoin),
}

impl Device {
    /// Open the device described by `info`, or report why it can't be driven.
    pub fn open(info: &NativeDeviceInfo) -> Result<Self, DeviceError> {
        match info.family {
            DeviceFamily::Ledger => ledger::Ledger::open(&info.path).map(Device::Ledger),
            DeviceFamily::Jade => jade_btc::JadeBitcoin::open(&info.path).map(Device::Jade),
            other => Err(DeviceError::Unsupported {
                device: other.label().to_string(),
                detail: "this build has no native driver for it yet".into(),
            }),
        }
    }

    pub fn fingerprint(&self) -> Result<String, DeviceError> {
        let fp = match self {
            Device::Ledger(d) => d.fingerprint()?,
            Device::Jade(d) => d.fingerprint()?,
        };
        Ok(fp.to_string().to_lowercase())
    }

    /// `(receive, change)` for the BIP84 single-sig account.
    pub fn wpkh_descriptors(&self) -> Result<(String, String), DeviceError> {
        match self {
            Device::Ledger(d) => d.wpkh_descriptors(),
            Device::Jade(d) => d.wpkh_descriptors(),
        }
    }

    /// The Liquid CT descriptor, for the one family that has Liquid in
    /// firmware. Every other device is refused rather than given an ELIP151
    /// descriptor it could receive to but never spend from.
    pub fn ct_descriptor(&self) -> Result<String, DeviceError> {
        match self {
            Device::Jade(d) => d.ct_descriptor(),
            Device::Ledger(_) => Err(DeviceError::Unsupported {
                device: "Ledger".into(),
                detail: crate::liquid::hardware::liquid_hw_unsupported_reason().into(),
            }),
        }
    }

    /// BIP48 cosigner key, `[fingerprint/48'/1'/0'/2']tpub…`.
    pub fn cosigner_xpub(&self) -> Result<String, DeviceError> {
        match self {
            Device::Ledger(d) => d.cosigner_xpub(),
            Device::Jade(d) => d.cosigner_xpub(),
        }
    }

    pub fn display_address(&self, descriptor: &str, index: u32) -> Result<String, DeviceError> {
        match self {
            Device::Ledger(d) => d.display_address(descriptor, index),
            Device::Jade(d) => d.display_address(descriptor, index),
        }
    }

    /// Sign a base64 PSBT, returning the updated one.
    ///
    /// `descriptor` is the wallet's receive descriptor. A Ledger needs it to
    /// rebuild the policy it signs under; a Jade reads everything it needs
    /// from the PSBT itself.
    pub fn sign_psbt(&self, descriptor: &str, psbt_b64: &str) -> Result<String, DeviceError> {
        match self {
            Device::Ledger(d) => d.sign_psbt(descriptor, psbt_b64),
            Device::Jade(d) => {
                let _ = descriptor;
                d.sign_psbt(psbt_b64)
            }
        }
    }
}

/// Attached devices this build can drive, each paired with its fingerprint.
///
/// Reading a fingerprint means opening the device, so this is the expensive
/// enumeration — and on a Jade it prompts for the PIN. Errors are returned
/// alongside the successes rather than replacing them: one locked Ledger must
/// not hide the Jade sitting next to it.
/// Also returns everything the bus showed, drivable or not, so the caller can
/// decide whether an HWI fallback is even worth spawning without re-scanning —
/// a second scan could see a different bus, and the message would then talk
/// about devices we never tried.
#[allow(clippy::type_complexity)]
pub fn enumerate_drivable() -> (
    Vec<(NativeDeviceInfo, String)>,
    Vec<String>,
    Vec<NativeDeviceInfo>,
) {
    let attached = enumerate_native().unwrap_or_default();
    let mut found = Vec::new();
    let mut errors = Vec::new();
    for info in attached.iter().filter(|d| d.family.is_drivable()) {
        match Device::open(info).and_then(|d| d.fingerprint()) {
            Ok(fp) => found.push((info.clone(), fp)),
            Err(e) => errors.push(format!("{}: {e}", info.model)),
        }
    }
    (found, errors, attached)
}

/// Open the attached device whose master fingerprint matches.
///
/// Fingerprint rather than USB path on purpose: a path changes when the cable
/// moves to another port, while the fingerprint is what the wallet was created
/// against, so this cannot silently open a *different* device that happens to
/// be plugged into the same socket.
pub fn open_by_fingerprint(fingerprint: &str) -> Result<(NativeDeviceInfo, Device), DeviceError> {
    let want = fingerprint.to_lowercase();
    let mut last_error = None;
    for info in enumerate_native().unwrap_or_default() {
        if !info.family.is_drivable() {
            continue;
        }
        let device = match Device::open(&info) {
            Ok(d) => d,
            Err(e) => {
                last_error = Some(e);
                continue;
            }
        };
        match device.fingerprint() {
            Ok(fp) if fp == want => return Ok((info, device)),
            Ok(_) => {}
            Err(e) => last_error = Some(e),
        }
    }
    // A device that was there but wouldn't talk is a better answer than "not
    // found": the fix is to unlock it, not to hunt for a missing wallet.
    Err(last_error.unwrap_or(DeviceError::NotFound { fingerprint: want }))
}

/// USB vendor IDs we recognise, with the transport each uses.
///
/// Sourced from the udev rules this repo bundles for Linux
/// (`src/templar_wallet/assets/udev/`), which come from the HWI project — so the
/// three places that need to agree about what a hardware wallet looks like
/// (Linux permissions, native enumeration, the docs) agree by construction.
const KNOWN_VENDORS: &[(u16, DeviceFamily, Transport)] = &[
    // Ledger: one vendor id across Nano S / S Plus / X / Stax / Flex.
    (0x2c97, DeviceFamily::Ledger, Transport::Hid),
    // Ledger HW.1 / original Nano — pre-2c97 vendor id.
    (0x2581, DeviceFamily::Ledger, Transport::Hid),
    (0x534c, DeviceFamily::Trezor, Transport::Hid), // Trezor One
    (0x1209, DeviceFamily::Trezor, Transport::Hid), // Trezor T (WebUSB/HID)
    (0xd13e, DeviceFamily::Coldcard, Transport::Hid),
    (0x2b24, DeviceFamily::KeepKey, Transport::Hid),
    (0x03eb, DeviceFamily::BitBox02, Transport::Hid),
];

/// USB IDs of the serial bridges Jade ships with. Unlike the HID table this
/// must match on the *pair*: 10c4:ea60 is a generic CP210x found in countless
/// unrelated adapters, so matching the vendor alone would label a USB-to-TTL
/// cable as a hardware wallet.
const JADE_SERIAL_IDS: &[(u16, u16)] = &[
    (0x10c4, 0xea60), // CP2104 — Jade v1
    (0x1a86, 0x55d4), // CH9102 — Jade v1.1
    (0x303a, 0x4001), // ESP32-S3 native USB — Jade Plus
];

/// Classify a HID device by its USB vendor id.
fn hid_family(vendor_id: u16) -> Option<DeviceFamily> {
    KNOWN_VENDORS
        .iter()
        .find(|(vid, _, transport)| *vid == vendor_id && *transport == Transport::Hid)
        .map(|(_, family, _)| *family)
}

/// Whether a HID interface's usage page could be the wallet one.
///
/// One physical device publishes several HID interfaces: a Ledger exposes
/// keyboard emulation and a U2F/FIDO interface alongside the wallet channel.
/// Listing all of them would show the same Ledger three times, and connecting
/// to the wrong one would simply never answer.
///
/// The wallet channel always lives on a vendor-defined page (0xFF00–0xFFFF;
/// Ledger uses 0xFFA0). A reported page of 0 means the platform did not parse
/// the report descriptor — Linux hidraw commonly does this — and must be
/// allowed through, or Linux would see no devices at all.
fn is_wallet_usage_page(usage_page: u16) -> bool {
    usage_page == 0 || usage_page >= 0xFF00
}

/// True when a serial port's USB ids belong to a Jade.
fn is_jade_serial(vendor_id: u16, product_id: u16) -> bool {
    JADE_SERIAL_IDS
        .iter()
        .any(|(vid, pid)| *vid == vendor_id && *pid == product_id)
}

/// Every hardware wallet the OS currently exposes, across both transports.
///
/// A failure on one transport does not hide the other: a machine with no
/// serial ports must still list its Ledger, and a Linux box whose hidraw nodes
/// are root-only must still list its Jade. Both errors are reported only when
/// *neither* transport produced anything.
pub fn enumerate_native() -> Result<Vec<NativeDeviceInfo>, TemplarError> {
    let mut devices = Vec::new();
    let mut errors = Vec::new();

    match enumerate_hid() {
        Ok(mut found) => devices.append(&mut found),
        Err(e) => errors.push(format!("HID: {e}")),
    }
    match enumerate_serial() {
        Ok(mut found) => devices.append(&mut found),
        Err(e) => errors.push(format!("serial: {e}")),
    }

    if devices.is_empty() && !errors.is_empty() {
        return Err(HardwareError::ConnectionFailed(format!(
            "{}: could not scan for devices — {}",
            super::hardware::ERR_DEVICE_NOT_READY,
            errors.join("; ")
        ))
        .into());
    }
    Ok(devices)
}

/// How many HID devices the OS exposes to us in total, wallet or not.
///
/// A support diagnostic, and the answer to a question enumeration alone cannot
/// settle: an empty device list means "no wallet attached" only if we can see
/// *anything* at all. Zero here on a laptop — which always has at least a
/// keyboard and trackpad on the HID bus — means the platform is denying HID
/// access, and no amount of unplugging and replugging will help.
pub fn hid_device_count() -> usize {
    hid::enumerate().map(|(_, total)| total).unwrap_or(0)
}

fn enumerate_hid() -> Result<Vec<NativeDeviceInfo>, String> {
    let (entries, _total) = hid::enumerate()?;
    let mut out: Vec<NativeDeviceInfo> = Vec::new();
    for info in entries {
        let Some(family) = hid_family(info.vendor_id) else {
            continue;
        };
        if !is_wallet_usage_page(info.usage_page) {
            continue;
        }
        // Same physical device seen twice through different report paths.
        if out.iter().any(|d| d.path == info.path) {
            continue;
        }
        out.push(NativeDeviceInfo {
            family,
            model: info
                .product
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| family.label().to_string()),
            transport: Transport::Hid,
            path: info.path,
            vendor_id: info.vendor_id,
            product_id: info.product_id,
            serial_number: info.serial_number,
            drivable: family.is_drivable(),
        });
    }
    Ok(out)
}

fn enumerate_serial() -> Result<Vec<NativeDeviceInfo>, String> {
    let ports = serialport::available_ports().map_err(|e| e.to_string())?;
    let mut out: Vec<NativeDeviceInfo> = Vec::new();
    for port in ports {
        let serialport::SerialPortType::UsbPort(usb) = &port.port_type else {
            continue;
        };
        if !is_jade_serial(usb.vid, usb.pid) {
            continue;
        }
        let info = NativeDeviceInfo {
            family: DeviceFamily::Jade,
            model: usb
                .product
                .clone()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| DeviceFamily::Jade.label().to_string()),
            transport: Transport::Serial,
            path: port.port_name.clone(),
            vendor_id: usb.vid,
            product_id: usb.pid,
            serial_number: usb.serial_number.clone(),
            drivable: DeviceFamily::Jade.is_drivable(),
        };

        // One physical Jade, several device nodes: macOS publishes every serial
        // port twice, as /dev/cu.<name> and /dev/tty.<name>. Keeping both
        // listed the same Jade twice in the picker *and* made
        // `enumerate_drivable` open it twice — two PIN prompts, and the second
        // open fighting the first for the port.
        match out
            .iter()
            .position(|seen| serial_node_key(&seen.path) == serial_node_key(&info.path))
        {
            Some(i) => {
                if prefer_serial_path(&info.path, &out[i].path) {
                    out[i] = info;
                }
            }
            None => out.push(info),
        }
    }
    Ok(out)
}

/// Identity of the physical port behind a device node, so the several nodes an
/// OS publishes for one port collapse to a single entry.
///
/// Keyed on the node name with the macOS `cu.`/`tty.` prefix removed rather
/// than on the USB ids: a Jade may report no USB serial number, and keying on
/// vendor/product alone would merge two Jades attached at once into one.
/// Linux node names (`ttyACM0`) carry no dot and pass through untouched.
fn serial_node_key(path: &str) -> String {
    let node = path.rsplit('/').next().unwrap_or(path);
    let node = node
        .strip_prefix("cu.")
        .or_else(|| node.strip_prefix("tty."))
        .unwrap_or(node);
    node.to_ascii_lowercase()
}

/// Whether `candidate` is the better node to talk to than `current`.
///
/// On macOS the call-out device (`cu.`) is the one to use: opening the dial-in
/// node (`tty.`) blocks until carrier detect, which on a Jade means it never
/// returns.
fn prefer_serial_path(candidate: &str, current: &str) -> bool {
    let is_callout = |p: &str| p.rsplit('/').next().unwrap_or(p).starts_with("cu.");
    is_callout(candidate) && !is_callout(current)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ledger_vendor_ids_are_recognised() {
        assert_eq!(hid_family(0x2c97), Some(DeviceFamily::Ledger));
        assert_eq!(hid_family(0x2581), Some(DeviceFamily::Ledger));
    }

    #[test]
    fn unknown_vendors_are_ignored() {
        // Apple keyboards, mice, YubiKeys — none of these are wallets.
        assert_eq!(hid_family(0x05ac), None);
        assert_eq!(hid_family(0x1050), None);
        assert_eq!(hid_family(0x0000), None);
    }

    /// Jade must match on the vendor *and* product id: its serial bridges are
    /// generic parts. Treating any CP210x as a wallet would put a USB-to-TTL
    /// cable in the device picker.
    #[test]
    fn jade_matches_only_on_the_full_usb_id_pair() {
        assert!(is_jade_serial(0x10c4, 0xea60));
        assert!(is_jade_serial(0x1a86, 0x55d4));
        assert!(is_jade_serial(0x303a, 0x4001));
        // Right vendor, wrong product — a different CP210x board.
        assert!(!is_jade_serial(0x10c4, 0x0000));
        assert!(!is_jade_serial(0x1a86, 0x7523)); // CH340, a common TTL cable
    }

    /// Jade is serial-only; its ids must not leak into the HID table, or a
    /// serial bridge would be offered as a HID device we cannot open.
    #[test]
    fn jade_is_not_in_the_hid_table() {
        for (vid, _) in JADE_SERIAL_IDS {
            assert_eq!(hid_family(*vid), None, "vendor {vid:#06x}");
        }
    }

    /// One Ledger publishes a keyboard interface (usage page 0x01) and a
    /// U2F/FIDO one (0xF1D0) beside the wallet channel. Accepting those would
    /// list the same device three times and let the user pick a channel that
    /// never answers.
    #[test]
    fn only_vendor_usage_pages_count_as_the_wallet_interface() {
        assert!(is_wallet_usage_page(0xFFA0)); // Ledger wallet channel
        assert!(is_wallet_usage_page(0xFF00)); // other vendor-defined pages
                                               // Unparsed descriptor (Linux hidraw) — must pass, or Linux sees nothing.
        assert!(is_wallet_usage_page(0));

        assert!(!is_wallet_usage_page(0x01)); // generic desktop / keyboard
        assert!(!is_wallet_usage_page(0x07)); // keyboard page
        assert!(!is_wallet_usage_page(0x0C)); // consumer control
        assert!(!is_wallet_usage_page(0xF1D0)); // FIDO/U2F
    }

    /// The families with a native driver are exactly the ones `Device::open`
    /// can build. A family marked drivable without a driver would be routed
    /// away from HWI and then refused — worse than never having claimed it.
    #[test]
    fn drivable_families_are_the_ones_with_a_driver() {
        use DeviceFamily::*;
        assert!(Ledger.is_drivable());
        assert!(Jade.is_drivable());
        for family in [Trezor, Coldcard, KeepKey, BitBox02, DigitalBitbox] {
            assert!(!family.is_drivable(), "{}", family.label());
            // And opening one must say so rather than half-succeeding.
            let info = NativeDeviceInfo {
                family,
                model: family.label().to_string(),
                transport: Transport::Hid,
                path: "/dev/null".into(),
                vendor_id: 0,
                product_id: 0,
                serial_number: None,
                drivable: false,
            };
            assert!(matches!(
                Device::open(&info),
                Err(DeviceError::Unsupported { .. })
            ));
        }
    }

    /// macOS publishes one serial port as two nodes. They must collapse to one
    /// device, or the picker lists the same Jade twice and enumeration opens it
    /// twice — two PIN prompts for one device.
    #[test]
    fn macos_callout_and_dialin_nodes_are_the_same_device() {
        assert_eq!(
            serial_node_key("/dev/cu.usbmodem1234561"),
            serial_node_key("/dev/tty.usbmodem1234561")
        );
        // Two Jades attached at once are still two devices.
        assert_ne!(
            serial_node_key("/dev/cu.usbmodem1234561"),
            serial_node_key("/dev/cu.usbmodem14201")
        );
        // Linux node names carry no cu./tty. prefix and must survive intact.
        assert_eq!(serial_node_key("/dev/ttyACM0"), "ttyacm0");
        assert_ne!(
            serial_node_key("/dev/ttyACM0"),
            serial_node_key("/dev/ttyACM1")
        );
        // Windows COM ports have no directory part.
        assert_eq!(serial_node_key("COM7"), "com7");
    }

    /// Of the two macOS nodes, the call-out one is the one to keep: opening the
    /// dial-in node waits for carrier detect and never returns on a Jade.
    #[test]
    fn the_callout_node_wins() {
        assert!(prefer_serial_path(
            "/dev/cu.usbmodem1234561",
            "/dev/tty.usbmodem1234561"
        ));
        assert!(!prefer_serial_path(
            "/dev/tty.usbmodem1234561",
            "/dev/cu.usbmodem1234561"
        ));
        // No preference between identical shapes — first seen stays.
        assert!(!prefer_serial_path("/dev/ttyACM0", "/dev/ttyACM0"));
    }

    /// Whatever the OS reports, one physical port must appear once.
    #[test]
    fn serial_enumeration_lists_each_port_once() {
        let Ok(devices) = enumerate_serial() else {
            return; // no serial subsystem on this machine
        };
        let mut keys: Vec<String> = devices.iter().map(|d| serial_node_key(&d.path)).collect();
        let before = keys.len();
        keys.sort();
        keys.dedup();
        assert_eq!(before, keys.len(), "duplicate serial nodes: {devices:?}");
    }

    /// Enumerating drivable devices must never panic on a machine with none
    /// attached — the UI calls it on a poll timer.
    #[test]
    fn drivable_enumeration_is_safe_with_no_device_attached() {
        // With hardware on the desk this opens it, and a locked Jade holds the
        // call for its full 90 s PIN window — a real device belongs in the
        // manual test plan (docs/HARDWARE_TESTING.md), not in a unit run.
        if enumerate_native()
            .unwrap_or_default()
            .iter()
            .any(|d| d.family.is_drivable())
        {
            eprintln!("skipped: a drivable device is attached");
            return;
        }
        let (found, _errors, _attached) = enumerate_drivable();
        for (info, fingerprint) in found {
            assert!(info.family.is_drivable());
            assert_eq!(fingerprint.len(), 8, "fingerprints are 8 hex characters");
        }
    }

    /// Enumeration must survive being called from a different thread each
    /// time. This is a crash regression, not a style preference: `hidapi`'s
    /// macOS backend binds its IOHIDManager to whichever thread called
    /// `hid_init`, and enumerating from another one aborts the process with
    /// SIGTRAP. Flutter's FFI calls arrive on whatever isolate thread is free,
    /// so without the owner thread in `hid.rs` the app dies on the second
    /// device-list poll.
    #[test]
    fn enumeration_survives_calls_from_many_threads() {
        for _ in 0..4 {
            std::thread::spawn(|| {
                let _ = enumerate_native();
                let _ = hid_device_count();
            })
            .join()
            .expect("enumeration must not abort the process");
        }
    }

    /// Enumeration must never panic or block on a machine with no wallet
    /// attached — it runs on a UI poll timer.
    #[test]
    fn enumeration_is_safe_with_no_device_attached() {
        match enumerate_native() {
            Ok(devices) => {
                for d in devices {
                    assert!(!d.path.is_empty());
                }
            }
            // A CI box with no HID subsystem at all is a legitimate outcome.
            Err(e) => assert!(e.to_string().contains("could not scan")),
        }
    }
}
