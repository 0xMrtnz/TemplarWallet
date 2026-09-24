import '../../wallet_picker/models/wallet_summary.dart';

/// What came back from pairing a hardware wallet: the one wallet that was
/// created, plus what the recap screen needs to show the pairing really worked.
///
/// One wallet, not two. A device that holds Bitcoin and Liquid is a single
/// wallet with two sides, the same shape a software wallet has. Earlier builds
/// created a second `"<name> (Liquid)"` wallet whose Bitcoin descriptor slot
/// held a Liquid one — a card that looked like a Bitcoin wallet and failed on
/// every Bitcoin screen.
class HwImportResult {
  const HwImportResult({
    required this.wallet,
    required this.fingerprint,
    required this.deviceModel,
    required this.bitcoinDescriptor,
    this.liquidDescriptor,
    this.liquidError,
    this.liquidRequested = false,
  });

  final WalletSummary wallet;

  /// Master fingerprint of the device both sides were read from.
  final String fingerprint;

  /// Model as the device reports it.
  final String deviceModel;

  /// The Bitcoin receive descriptor stored for this wallet.
  final String bitcoinDescriptor;

  /// The Liquid CT descriptor, when a Liquid side was paired.
  final String? liquidDescriptor;

  /// Why Liquid is missing, when it was asked for and could not be paired. The
  /// Bitcoin wallet exists either way — this says which half is missing.
  final String? liquidError;

  /// Whether Liquid was asked for at all, so "you chose Bitcoin only" reads
  /// differently from "Liquid failed".
  final bool liquidRequested;

  bool get hasLiquid => liquidDescriptor != null;

  /// Everything asked for came back.
  bool get isComplete => !liquidRequested || hasLiquid;

  factory HwImportResult.fromJson(Map<String, dynamic> j) => HwImportResult(
        wallet: WalletSummary.fromJson(j['wallet'] as Map<String, dynamic>),
        fingerprint: j['fingerprint'] as String? ?? '',
        deviceModel: j['device_model'] as String? ?? '',
        bitcoinDescriptor: j['bitcoin_descriptor'] as String? ?? '',
        liquidDescriptor: j['liquid_descriptor'] as String?,
        liquidError: j['liquid_error'] as String?,
        liquidRequested: j['liquid_requested'] as bool? ?? false,
      );
}
