/// A consolidation that has been broadcast but is not yet confirmed.
///
/// While one of these is live the coins it spends are hidden from the UTXO
/// views and replaced by a single grey placeholder, so the wallet shows the
/// shape the user just asked for instead of the coins they already spent. The
/// placeholder is dropped once the resulting output lands with a confirmation.
class PendingConsolidation {
  const PendingConsolidation({
    required this.txid,
    required this.walletId,
    required this.chain,
    required this.inputs,
    required this.amount,
    required this.displayAmount,
    required this.ticker,
    required this.startedAt,
  });

  /// Transaction that spends [inputs] into one output.
  final String txid;

  final String walletId;

  /// 'BTC' or 'Liquid' — the views are per-chain, and a pending consolidation
  /// must not leak across the chain switcher.
  final String chain;

  /// Outpoints being spent. These are hidden from the view while pending.
  final List<String> inputs;

  /// Sum of the inputs. The real output is this minus the fee; it is shown as
  /// an approximation because the exact figure is not known until it confirms.
  final int amount;

  final String displayAmount;
  final String? ticker;
  final DateTime startedAt;

  /// How many coins are being merged.
  int get count => inputs.length;

  /// The chain in the wire spelling the activity feeds use. [chain] is the
  /// UTXO screen's own switcher value ('BTC' / 'Liquid'); Activity and Home
  /// speak 'bitcoin' / 'liquid'.
  String get chainKey => chain == 'Liquid' ? 'liquid' : 'bitcoin';

  /// What the row says it is. Without this a consolidation reads as a payment
  /// to a stranger — it is a self-transfer, and saying so is the whole point.
  String get activityNote =>
      'Consolidating $count coins into one';

  /// True once [other] is the confirmed output of this consolidation.
  bool isSettledBy(String outpoint) => outpoint.startsWith('$txid:');

  /// Give up after a day. A replaced or dropped transaction must not leave a
  /// grey block wedged over the real coins forever — better to show the truth
  /// from the node than a placeholder that will never resolve.
  bool get isStale =>
      DateTime.now().difference(startedAt) > const Duration(hours: 24);

  Map<String, dynamic> toJson() => {
        'txid': txid,
        'wallet_id': walletId,
        'chain': chain,
        'inputs': inputs,
        'amount': amount,
        'display_amount': displayAmount,
        'ticker': ticker,
        'started_at': startedAt.toIso8601String(),
      };

  static PendingConsolidation? fromJson(Map<String, dynamic> j) {
    final txid = j['txid'];
    final walletId = j['wallet_id'];
    final startedAt = DateTime.tryParse(j['started_at'] as String? ?? '');
    if (txid is! String || walletId is! String || startedAt == null) return null;
    return PendingConsolidation(
      txid: txid,
      walletId: walletId,
      chain: j['chain'] as String? ?? 'BTC',
      inputs: (j['inputs'] as List?)?.whereType<String>().toList() ?? const [],
      amount: (j['amount'] as num?)?.toInt() ?? 0,
      displayAmount: j['display_amount'] as String? ?? '',
      ticker: j['ticker'] as String?,
      startedAt: startedAt,
    );
  }
}
