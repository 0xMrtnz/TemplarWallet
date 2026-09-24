class HwDevice {
  const HwDevice({
    required this.model,
    required this.fingerprint,
    required this.path,
  });

  final String model;
  final String fingerprint;
  final String path;

  factory HwDevice.fromJson(Map<String, dynamic> j) => HwDevice(
        model: j['model'] as String? ?? '',
        fingerprint: j['fingerprint'] as String? ?? '',
        path: j['path'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'model': model,
        'fingerprint': fingerprint,
        'path': path,
      };
}
