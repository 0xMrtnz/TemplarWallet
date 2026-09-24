//! USB HID access: one owner thread, plus Ledger's APDU-over-HID framing.
//!
//! # The owner thread
//!
//! Every `hidapi` call in this process happens on a single thread created on
//! first use. That is not tidiness — it is the only arrangement that does not
//! crash. On macOS, `hid_init()` builds an IOHIDManager bound to the calling
//! thread's run loop, and:
//!
//!   * enumerating from a *different* thread afterwards aborts the process
//!     (SIGTRAP), and Flutter's FFI calls arrive on whichever isolate thread
//!     is free;
//!   * building a fresh `HidApi` per call cycles `hid_init`/`hid_exit` and
//!     aborts on the second one, which the two-second device-list poll reaches
//!     within seconds.
//!
//! `HidDevice` is also `!Send`, so an open handle cannot be moved off that
//! thread either. Hence the worker: callers post jobs and wait for the answer,
//! and no HID pointer ever leaves the thread that made it.
//!
//! # Framing
//!
//! This is the only piece of the Ledger stack written here. Everything above
//! it — the Bitcoin app's commands, the merkleized-PSBT protocol, signature
//! parsing — comes from Ledger's own `ledger_bitcoin_client`. The split is
//! deliberate: the framing is a dozen lines of packet assembly that anyone can
//! verify against the spec, while the protocol above it is precisely the part
//! no wallet should re-derive by hand.
//!
//! `ledger-transport-hid` would provide this layer, but it depends on hidapi
//! with the `linux-static-hidraw` feature. Cargo unifies features across the
//! graph, so taking that crate would silently switch the HID backend for the
//! whole workspace on Linux. Fifteen lines is a smaller price than an
//! unrequested backend change on a platform where devices already work.
//!
//! # Wire format
//!
//! Every packet is exactly 64 bytes:
//!
//! ```text
//! byte 0..2   channel  (any 16-bit value, echoed back by the device)
//! byte 2      tag      (0x05 = APDU)
//! byte 3..5   sequence (big-endian, starts at 0, increments per packet)
//! byte 5..    payload  (the first packet prefixes a 16-bit big-endian length)
//! ```
//!
//! The reassembled response is the APDU answer followed by a two-byte status
//! word, and the declared length covers both.

use std::collections::HashMap;
use std::sync::mpsc::{channel, Sender};
use std::sync::OnceLock;
use std::time::Duration;

use hidapi::{HidApi, HidDevice};

/// Fixed HID report size for every Ledger model.
const PACKET_LEN: usize = 64;

/// Arbitrary but conventional channel id; the device echoes whatever we send.
const CHANNEL: u16 = 0x0101;

/// Tag identifying an APDU frame (as opposed to ping / firmware frames).
const TAG_APDU: u8 = 0x05;

/// How long to wait for one 64-byte packet.
///
/// Generous on purpose: the packet that carries the answer to `sign_psbt`
/// only arrives once the user has read the amounts on the device and pressed
/// approve. A short timeout here doesn't fail fast, it fails *wrongly* —
/// reporting a dead device while the user is still reading the screen.
const READ_TIMEOUT: Duration = Duration::from_secs(120);

/// Errors from the transport itself. Protocol-level errors (a device refusing
/// a command, a user declining) surface through the client above.
#[derive(Debug)]
pub enum HidError {
    /// The device could not be opened — unplugged, or claimed by another app.
    Open(String),
    Write(String),
    /// No packet arrived within [`READ_TIMEOUT`].
    Timeout,
    /// A packet arrived that does not fit the framing above.
    Protocol(String),
    /// The HID owner thread is gone, so no device call can be served.
    WorkerGone,
}

impl std::fmt::Display for HidError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            HidError::Open(e) => write!(f, "could not open the device: {e}"),
            HidError::Write(e) => write!(f, "could not write to the device: {e}"),
            HidError::Timeout => write!(
                f,
                "the device did not answer. Unlock it and open the Bitcoin app."
            ),
            HidError::Protocol(e) => write!(f, "unexpected answer from the device: {e}"),
            HidError::WorkerGone => write!(f, "USB access is no longer available in this session"),
        }
    }
}

/// One HID device as the OS describes it, copied out of `hidapi`'s own structs
/// so the result can cross the channel back to the caller's thread.
#[derive(Debug, Clone)]
pub struct HidEntry {
    pub vendor_id: u16,
    pub product_id: u16,
    pub usage_page: u16,
    pub path: String,
    pub product: Option<String>,
    pub serial_number: Option<String>,
}

/// Handle to an open device, valid only while the owner thread holds it.
type DeviceId = u64;

enum Job {
    /// Every HID device on the bus, and the total count (a support diagnostic:
    /// zero on a laptop means the OS is denying HID access outright).
    Enumerate(Sender<Result<(Vec<HidEntry>, usize), String>>),
    Open(String, Sender<Result<DeviceId, String>>),
    Exchange {
        id: DeviceId,
        apdu: Vec<u8>,
        reply: Sender<Result<(u16, Vec<u8>), HidError>>,
    },
    Close(DeviceId),
}

/// The channel into the owner thread, started on first use.
///
/// `Err` when `hid_init()` itself failed — cached, because retrying it would
/// mean a second `hid_init` on a different thread, which is the crash this
/// whole arrangement exists to avoid.
static WORKER: OnceLock<Result<Sender<Job>, String>> = OnceLock::new();

fn worker() -> Result<&'static Sender<Job>, String> {
    WORKER
        .get_or_init(|| {
            let (tx, rx) = channel::<Job>();
            let (ready_tx, ready_rx) = channel::<Result<(), String>>();
            std::thread::Builder::new()
                .name("templar-hid".into())
                .spawn(move || {
                    let api = match HidApi::new() {
                        Ok(api) => {
                            let _ = ready_tx.send(Ok(()));
                            api
                        }
                        Err(e) => {
                            let _ = ready_tx.send(Err(e.to_string()));
                            return;
                        }
                    };
                    run(api, rx);
                })
                .map_err(|e| format!("could not start the USB thread: {e}"))?;
            // Wait for hid_init before handing out the sender: a caller that
            // posted a job to a thread that then failed to initialise would
            // block until the sender dropped, which reads as a hung device.
            match ready_rx.recv() {
                Ok(Ok(())) => Ok(tx),
                Ok(Err(e)) => Err(e),
                Err(_) => Err("the USB thread stopped before starting".into()),
            }
        })
        .as_ref()
        .map_err(|e| e.clone())
}

/// The owner thread's loop. Owns the `HidApi` and every open `HidDevice`;
/// neither ever leaves this function's stack.
fn run(mut api: HidApi, rx: std::sync::mpsc::Receiver<Job>) {
    let mut devices: HashMap<DeviceId, HidDevice> = HashMap::new();
    let mut next_id: DeviceId = 1;

    while let Ok(job) = rx.recv() {
        match job {
            Job::Enumerate(reply) => {
                let result = api.refresh_devices().map_err(|e| e.to_string()).map(|_| {
                    let list: Vec<HidEntry> = api
                        .device_list()
                        .map(|d| HidEntry {
                            vendor_id: d.vendor_id(),
                            product_id: d.product_id(),
                            usage_page: d.usage_page(),
                            path: d.path().to_string_lossy().to_string(),
                            product: d.product_string().map(|s| s.trim().to_string()),
                            serial_number: d.serial_number().map(|s| s.to_string()),
                        })
                        .collect();
                    let total = list.len();
                    (list, total)
                });
                let _ = reply.send(result);
            }
            Job::Open(path, reply) => {
                let result = std::ffi::CString::new(path)
                    .map_err(|_| "path contains a NUL byte".to_string())
                    .and_then(|c| api.open_path(&c).map_err(|e| e.to_string()))
                    .map(|device| {
                        let id = next_id;
                        next_id += 1;
                        devices.insert(id, device);
                        id
                    });
                let _ = reply.send(result);
            }
            Job::Exchange { id, apdu, reply } => {
                let result = match devices.get(&id) {
                    Some(device) => exchange_on(device, &apdu),
                    None => Err(HidError::Open("the device was closed".into())),
                };
                let _ = reply.send(result);
            }
            Job::Close(id) => {
                devices.remove(&id);
            }
        }
    }
}

/// Post a job and wait for its answer.
fn ask<T>(make: impl FnOnce(Sender<T>) -> Job) -> Result<T, HidError> {
    let tx = worker().map_err(HidError::Open)?;
    let (reply_tx, reply_rx) = channel::<T>();
    tx.send(make(reply_tx)).map_err(|_| HidError::WorkerGone)?;
    reply_rx.recv().map_err(|_| HidError::WorkerGone)
}

/// Every HID device the OS exposes, read on the owner thread.
pub fn enumerate() -> Result<(Vec<HidEntry>, usize), String> {
    match ask(Job::Enumerate) {
        Ok(inner) => inner,
        Err(e) => Err(e.to_string()),
    }
}

/// An open HID connection to a Ledger, framing APDUs in both directions.
///
/// The handle is just an id: the device itself lives on the owner thread, so
/// this struct is `Send` and can sit inside a signing call on any thread.
pub struct LedgerHidTransport {
    id: DeviceId,
}

impl LedgerHidTransport {
    /// Open the device at an enumerated HID path.
    pub fn open(path: &str) -> Result<Self, HidError> {
        let id = ask(|reply| Job::Open(path.to_string(), reply))?.map_err(HidError::Open)?;
        Ok(Self { id })
    }

    /// Send one APDU and collect the answer, without the status word.
    ///
    /// Returns `(status_word, payload)`; the caller decides what a non-OK
    /// status means for the command it sent.
    pub fn exchange(&self, apdu: &[u8]) -> Result<(u16, Vec<u8>), HidError> {
        let id = self.id;
        let apdu = apdu.to_vec();
        ask(|reply| Job::Exchange { id, apdu, reply })?
    }
}

impl Drop for LedgerHidTransport {
    fn drop(&mut self) {
        // Best-effort: if the worker is gone the handle died with it.
        if let Ok(tx) = worker() {
            let _ = tx.send(Job::Close(self.id));
        }
    }
}

/// One request/response round on an open device. Runs on the owner thread.
fn exchange_on(device: &HidDevice, apdu: &[u8]) -> Result<(u16, Vec<u8>), HidError> {
    for packet in frames_for(apdu) {
        device
            .write(&packet)
            .map_err(|e| HidError::Write(e.to_string()))?;
    }

    let mut buf = [0u8; PACKET_LEN];
    let mut assembler = FrameAssembler::default();
    let mut answer = loop {
        let read = device
            .read_timeout(&mut buf, READ_TIMEOUT.as_millis() as i32)
            .map_err(|e| HidError::Protocol(e.to_string()))?;
        if read == 0 {
            return Err(HidError::Timeout);
        }
        if let Some(done) = assembler.push(&buf[..read])? {
            break done;
        }
    };

    if answer.len() < 2 {
        return Err(HidError::Protocol(format!(
            "answer of {} byte(s) carries no status word",
            answer.len()
        )));
    }
    let sw_lo = answer.pop().expect("length checked above") as u16;
    let sw_hi = answer.pop().expect("length checked above") as u16;
    Ok(((sw_hi << 8) | sw_lo, answer))
}

/// Split an APDU into the 64-byte packets to write, each already carrying the
/// leading report-id byte hidapi expects.
fn frames_for(apdu: &[u8]) -> Vec<Vec<u8>> {
    let mut packets = Vec::new();
    let mut offset = 0usize;
    let mut seq: u16 = 0;

    // A loop rather than a chunk iterator: a zero-length APDU still needs its
    // one header packet, and chunking an empty slice yields nothing at all.
    loop {
        let mut packet = Vec::with_capacity(PACKET_LEN + 1);
        // hidapi takes the report id as byte 0 on every platform; Ledger
        // devices use the single unnumbered report, so it is always 0.
        packet.push(0x00);
        packet.extend_from_slice(&CHANNEL.to_be_bytes());
        packet.push(TAG_APDU);
        packet.extend_from_slice(&seq.to_be_bytes());
        if seq == 0 {
            packet.extend_from_slice(&(apdu.len() as u16).to_be_bytes());
        }

        let room = PACKET_LEN + 1 - packet.len();
        let end = (offset + room).min(apdu.len());
        packet.extend_from_slice(&apdu[offset..end]);
        packet.resize(PACKET_LEN + 1, 0);
        packets.push(packet);

        offset = end;
        seq += 1;
        if offset >= apdu.len() {
            return packets;
        }
    }
}

/// Reassembles an answer from the packets as they arrive.
///
/// Separate from the read loop so the framing rules can be exercised without a
/// device: the sequence check in particular is the one that turns "two replies
/// interleaved on the same handle" into an error instead of a spliced answer.
#[derive(Default)]
struct FrameAssembler {
    out: Vec<u8>,
    expected: Option<usize>,
    seq: u16,
}

impl FrameAssembler {
    /// Feed one packet. `Some(payload)` once the declared length is complete.
    fn push(&mut self, packet: &[u8]) -> Result<Option<Vec<u8>>, HidError> {
        if packet.len() < 5 {
            return Err(HidError::Protocol(format!(
                "short packet ({} bytes)",
                packet.len()
            )));
        }
        if packet[2] != TAG_APDU {
            return Err(HidError::Protocol(format!(
                "unknown tag {:#04x}",
                packet[2]
            )));
        }
        let got_seq = u16::from_be_bytes([packet[3], packet[4]]);
        if got_seq != self.seq {
            return Err(HidError::Protocol(format!(
                "packet out of order (expected {}, got {got_seq})",
                self.seq
            )));
        }

        let mut at = 5usize;
        if self.expected.is_none() {
            if packet.len() < 7 {
                return Err(HidError::Protocol("first packet has no length".into()));
            }
            self.expected = Some(u16::from_be_bytes([packet[5], packet[6]]) as usize);
            at = 7;
        }
        let want = self.expected.expect("set above");
        let take = (want - self.out.len()).min(packet.len() - at);
        self.out.extend_from_slice(&packet[at..at + take]);
        self.seq += 1;
        if self.out.len() >= want {
            return Ok(Some(std::mem::take(&mut self.out)));
        }
        Ok(None)
    }
}

/// Adapter making our framing usable as `ledger_bitcoin_client`'s transport.
pub struct LedgerTransport(pub LedgerHidTransport);

impl ledger_bitcoin_client::client::Transport for LedgerTransport {
    type Error = HidError;

    fn exchange(
        &self,
        command: &ledger_bitcoin_client::apdu::APDUCommand,
    ) -> Result<(ledger_bitcoin_client::apdu::StatusWord, Vec<u8>), Self::Error> {
        let (sw, data) = self.0.exchange(&command.encode())?;
        // An unmapped status word is not an error *here*: the client maps
        // Unknown onto its own device-error type together with the command
        // that produced it, which is a far better message than a bare number.
        let status = ledger_bitcoin_client::apdu::StatusWord::try_from(sw)
            .unwrap_or(ledger_bitcoin_client::apdu::StatusWord::Unknown);
        Ok((status, data))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every packet is exactly 65 bytes on the wire (64 + report id), and only
    /// the first carries the length. A device reading a short final packet
    /// would wait forever for the rest.
    #[test]
    fn frames_are_padded_and_only_the_first_declares_the_length() {
        let apdu = vec![0xABu8; 100];
        let packets = frames_for(&apdu);
        assert_eq!(packets.len(), 2, "100 bytes needs a second packet");
        for p in &packets {
            assert_eq!(p.len(), PACKET_LEN + 1);
            assert_eq!(p[0], 0x00, "report id");
            assert_eq!(&p[1..3], &CHANNEL.to_be_bytes());
            assert_eq!(p[3], TAG_APDU);
        }
        assert_eq!(
            &packets[0][4..6],
            &0u16.to_be_bytes(),
            "first sequence is 0"
        );
        assert_eq!(&packets[0][6..8], &100u16.to_be_bytes(), "declared length");
        assert_eq!(
            &packets[1][4..6],
            &1u16.to_be_bytes(),
            "sequence increments"
        );
        // 57 payload bytes in the header packet, 43 in the next.
        assert_eq!(&packets[0][8..65], &apdu[..57]);
        assert_eq!(&packets[1][6..49], &apdu[57..]);
    }

    /// An empty APDU is still one packet. Emitting none would leave the device
    /// waiting and the read timing out 120 seconds later.
    #[test]
    fn an_empty_apdu_still_produces_one_packet() {
        let packets = frames_for(&[]);
        assert_eq!(packets.len(), 1);
        assert_eq!(&packets[0][6..8], &0u16.to_be_bytes());
    }

    fn reply(payload: &[u8]) -> Vec<Vec<u8>> {
        // Build device-shaped packets: same framing, minus the report id.
        frames_for(payload)
            .into_iter()
            .map(|p| p[1..].to_vec())
            .collect()
    }

    #[test]
    fn assembles_a_multi_packet_answer() {
        let payload: Vec<u8> = (0..200u32).map(|i| i as u8).collect();
        let mut asm = FrameAssembler::default();
        let packets = reply(&payload);
        assert!(packets.len() > 1, "test needs a split answer");
        let mut got = None;
        for p in packets {
            if let Some(done) = asm.push(&p).expect("valid frame") {
                got = Some(done);
            }
        }
        assert_eq!(got.as_deref(), Some(&payload[..]));
    }

    /// Two answers interleaved on one handle would otherwise splice into a
    /// single plausible-looking payload — and this transport carries
    /// signatures.
    #[test]
    fn a_packet_out_of_order_is_an_error() {
        let payload: Vec<u8> = (0..200u32).map(|i| i as u8).collect();
        let packets = reply(&payload);
        let mut asm = FrameAssembler::default();
        asm.push(&packets[0]).expect("first packet");
        // Skip ahead: feed the first packet again instead of the second.
        assert!(matches!(asm.push(&packets[0]), Err(HidError::Protocol(_))));
    }

    #[test]
    fn a_foreign_tag_is_rejected() {
        let mut packet = reply(&[1, 2, 3]).remove(0);
        packet[2] = 0x01; // ping frame, not an APDU
        let mut asm = FrameAssembler::default();
        assert!(matches!(asm.push(&packet), Err(HidError::Protocol(_))));
    }
}
