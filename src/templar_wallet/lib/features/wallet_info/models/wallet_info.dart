class WalletInfo {
  const WalletInfo({
    required this.id,
    required this.name,
    required this.network,
    required this.masterFingerprint,
    required this.derivationPath,
    required this.scriptType,
    required this.xpub,
    required this.receiveDescriptor,
    required this.changeDescriptor,
    this.multipathDescriptor,
    this.liquidDescriptor,
    this.masterBlindingKey,
    this.hasSeed = true,
    this.hasPassphrase = false,
    this.lastBackupAt,
    this.cosignerKeys = const [],
    this.requiredSigs,
    this.localFingerprints = const [],
    this.liquidNetwork = 'liquid-testnet',
  });

  final String id;
  final String name;
  final String network;
  final String masterFingerprint;
  final String derivationPath;
  final String scriptType;
  final String xpub;
  final String receiveDescriptor;
  final String changeDescriptor;
  final String? multipathDescriptor;
  final String? liquidDescriptor;
  final String? masterBlindingKey;
  final bool hasSeed;
  final bool hasPassphrase;
  final DateTime? lastBackupAt;
  /// Cosigner keys in `[fingerprint/path]xpub` format (empty for singlesig)
  final List<String> cosignerKeys;

  /// Signatures this wallet needs — the M of M-of-N. Null for singlesig.
  final int? requiredSigs;

  /// Fingerprints of the cosigner keys this app can sign with, so a roster can
  /// mark which key lives on this device.
  final List<String> localFingerprints;

  /// `liquid-testnet` | `liquid-regtest`.
  final String liquidNetwork;
}
