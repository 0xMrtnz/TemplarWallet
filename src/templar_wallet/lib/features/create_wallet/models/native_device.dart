// A hardware wallet the OS can see, read straight from USB descriptors by the
// Rust side — no `hwi` subprocess involved.
//
// Distinct from [HwDevice] on purpose: that one carries a master fingerprint,
// which identifies *which wallet* a device holds and can only be learned by
// asking the device over its own protocol. A NativeDevice answers the strictly
// weaker question "is something plugged in, and what is it?" — enough to tell
// a user with a connected Ledger apart from a user with a dead cable.

class NativeDevice {
  const NativeDevice({
    required this.family,
    required this.model,
    required this.transport,
    required this.path,
    required this.vendorId,
    required this.productId,
    this.serialNumber,
    this.drivable = false,
  });

  /// Protocol family: "ledger", "trezor", "coldcard", "keep_key",
  /// "bit_box02", "digital_bitbox", "jade".
  final String family;

  /// USB product string when the OS exposes one, else the family's name.
  final String model;

  /// "hid" or "serial".
  final String transport;

  final String path;
  final int vendorId;
  final int productId;
  final String? serialNumber;

  /// Whether this build can talk to the device, not merely see it. Decided by
  /// the backend (`DeviceFamily::is_drivable`) so the two cannot disagree.
  final bool drivable;

  /// `2c97:1015`, the form users find in system USB listings and bug reports.
  String get usbId =>
      '${vendorId.toRadixString(16).padLeft(4, '0')}:'
      '${productId.toRadixString(16).padLeft(4, '0')}';

  factory NativeDevice.fromJson(Map<String, dynamic> j) => NativeDevice(
        family: j['family'] as String? ?? '',
        model: j['model'] as String? ?? '',
        transport: j['transport'] as String? ?? '',
        path: j['path'] as String? ?? '',
        vendorId: (j['vendor_id'] as num?)?.toInt() ?? 0,
        productId: (j['product_id'] as num?)?.toInt() ?? 0,
        serialNumber: j['serial_number'] as String?,
        drivable: j['drivable'] as bool? ?? false,
      );
}
