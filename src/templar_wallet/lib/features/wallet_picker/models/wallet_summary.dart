enum WalletType { singlesig, multisig, watchOnly }

enum WalletNetwork { testnet, mainnet, regtest }

class WalletSummary {
  const WalletSummary({
    required this.id,
    required this.name,
    required this.type,
    required this.network,
    required this.balanceSats,
    required this.txCount,
    required this.lastSyncAt,
    this.isWatchOnly = false,
    this.typeLabel = '',
    this.liquidEnabled = false,
    this.bitcoinEnabled = true,
    this.deviceModel,
    this.masterFingerprint,
    this.xpub,
    this.requiredSigs,
    this.totalSigners,
  });

  final String id;
  final String name;
  final WalletType type;
  final WalletNetwork network;
  final int balanceSats;
  final int txCount;
  final DateTime lastSyncAt;
  final bool isWatchOnly;

  /// Backend type label: "Software", "Hardware (fp)", "Air-gap watch-only", "Multisig", etc.
  final String typeLabel;

  /// Whether this wallet has a paired Liquid wallet enabled.
  final bool liquidEnabled;

  /// Whether this wallet has a Bitcoin side. False for a Liquid-only wallet,
  /// whose Bitcoin screens have no wallet behind them.
  final bool bitcoinEnabled;

  /// Device model for hardware wallets — "Blockstream Jade", "Nano S",
  /// "air-gap", "watch-only". Drives the device badge on the card.
  final String? deviceModel;

  /// Public identity, read from the registry without opening the wallet.
  final String? masterFingerprint;

  /// Account xpub (null for multisig — it has no single key).
  final String? xpub;

  /// Multisig threshold, for the "2-of-3" label.
  final int? requiredSigs;
  final int? totalSigners;

  /// Threshold label when this is a multisig ("2-of-3"), else null.
  String? get thresholdLabel => (requiredSigs != null && totalSigners != null)
      ? '$requiredSigs-of-$totalSigners'
      : null;

  bool get isHardwareWallet =>
      typeLabel.startsWith('Hardware (') ||
      (typeLabel.toLowerCase().contains('hardware'));

  bool get isAirgapWallet =>
      typeLabel.toLowerCase().contains('air-gap') ||
      typeLabel.toLowerCase().contains('airgap');

  /// View-only: no way to sign at all, so Send is hidden. Exact match — the
  /// air-gap label also contains "watch-only" but that wallet signs by QR.
  bool get isViewOnlyWallet => typeLabel.toLowerCase() == 'watch-only';

  /// Which chains this wallet can actually work with, as a short label:
  /// "BTC + Liquid", "BTC only", "Liquid only".
  String get networksLabel {
    if (bitcoinEnabled && liquidEnabled) return 'BTC + Liquid';
    if (liquidEnabled) return 'Liquid only';
    return 'BTC only';
  }

  /// How this wallet holds its keys, in one word for the card: the device
  /// family where a device is involved, else the wallet structure. Null when
  /// nothing more specific than the type label is known.
  String? get keyOriginLabel {
    if (isAirgapWallet) return 'Air-gap';
    if (isViewOnlyWallet) return 'Watch-only';
    if (type == WalletType.multisig) return thresholdLabel ?? 'Multisig';
    if (isHardwareWallet) {
      final model = (deviceModel ?? '').toLowerCase();
      if (model.contains('jade')) return 'Jade USB';
      if (model.contains('ledger') || model.contains('nano')) return 'Ledger USB';
      return 'USB device';
    }
    return 'Software';
  }

  String get displayType => typeLabel.isNotEmpty
      ? typeLabel
      : switch (type) {
          WalletType.singlesig => 'Singlesig',
          WalletType.multisig => 'Multisig',
          WalletType.watchOnly => 'Watch-only',
        };

  factory WalletSummary.fromJson(Map<String, dynamic> j) => WalletSummary(
        id: j['id'] as String,
        name: j['name'] as String,
        type: _typeFromString(j['wallet_type'] as String? ?? ''),
        network: WalletNetwork.testnet,
        balanceSats: j['balance_sats'] as int? ?? 0,
        txCount: j['tx_count'] as int? ?? 0,
        lastSyncAt: DateTime.fromMillisecondsSinceEpoch(
            ((j['last_sync_at'] as int? ?? 0) * 1000)),
        isWatchOnly: j['is_watch_only'] as bool? ?? false,
        typeLabel: j['type_label'] as String? ?? '',
        liquidEnabled: j['liquid_enabled'] as bool? ?? false,
        // Absent means "has Bitcoin": every wallet shape but the Liquid-only
        // one does, and older payloads carried no flag at all.
        bitcoinEnabled: j['bitcoin_enabled'] as bool? ?? true,
        deviceModel: j['device_model'] as String?,
        masterFingerprint: j['master_fingerprint'] as String?,
        xpub: j['xpub'] as String?,
        requiredSigs: (j['required_sigs'] as num?)?.toInt(),
        totalSigners: (j['total_signers'] as num?)?.toInt(),
      );

  static WalletType _typeFromString(String s) => switch (s) {
        'multisig' => WalletType.multisig,
        'watch_only' => WalletType.watchOnly,
        _ => WalletType.singlesig,
      };
}
