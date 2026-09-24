/// One recipient of a transaction being composed (multi-output sends).
class TxOutputSpec {
  const TxOutputSpec({
    required this.address,
    required this.amountSats,
    this.assetId,
    this.sendMax = false,
  });

  final String address;
  final int amountSats;

  /// Per-output Liquid asset ID. Null inherits the transaction-level asset
  /// (ignored on Bitcoin).
  final String? assetId;

  /// Send the maximum available amount to this output. Bitcoin/L-BTC:
  /// balance minus fee (resolved by the backend); Liquid tokens: full asset
  /// balance. At most one output per transaction may set it.
  final bool sendMax;

  Map<String, dynamic> toJson() => {
        'address': address,
        'amount_sats': amountSats,
        if (assetId != null) 'asset_id': assetId,
        if (sendMax) 'send_max': true,
      };
}

/// One input or output of a previewed transaction, for the review diagram.
class TxIo {
  const TxIo({
    this.outpoint,
    required this.address,
    required this.amountSats,
    required this.isChange,
    this.assetId,
    this.ticker,
    this.amountDisplay,
  });

  /// "txid:vout" for inputs; null for outputs.
  final String? outpoint;
  final String address;
  final int amountSats;

  /// Output pays back to this wallet (change).
  final bool isChange;

  /// Liquid asset ID hex (null for Bitcoin).
  final String? assetId;

  /// Display ticker ("L-BTC", token ticker); null for Bitcoin.
  final String? ticker;

  /// Pre-formatted amount honoring the asset's precision (Liquid only).
  final String? amountDisplay;

  factory TxIo.fromJson(Map<String, dynamic> json) => TxIo(
        outpoint: json['outpoint'] as String?,
        address: (json['address'] as String?) ?? '',
        amountSats: (json['amount_sats'] as num?)?.toInt() ?? 0,
        isChange: (json['is_change'] as bool?) ?? false,
        assetId: json['asset_id'] as String?,
        ticker: json['ticker'] as String?,
        amountDisplay: json['amount_display'] as String?,
      );
}

class TxPreview {
  const TxPreview({
    required this.chain,
    required this.recipientAddress,
    required this.amountDisplay,
    required this.feeSats,
    required this.feeDisplay,
    required this.totalDisplay,
    this.feeRate = 0,
    this.vsizeEst = 0,
    this.inputs = const [],
    this.outputs = const [],
  });

  final String chain;
  final String recipientAddress;
  final String amountDisplay;
  final int feeSats;
  final String feeDisplay;
  final String totalDisplay;

  /// Requested fee rate in sat/vB (0 for Liquid flat-fee sends).
  final double feeRate;

  /// Estimated virtual size of the signed transaction in vbytes.
  final int vsizeEst;

  /// Concrete coins the transaction will spend (empty on Liquid — inputs
  /// stay auto-selected and blinded).
  final List<TxIo> inputs;

  /// All outputs including change (flagged via [TxIo.isChange]).
  final List<TxIo> outputs;
}
