/// Native-coin balance at one moment in time — the cumulative total *after*
/// the transaction that happened at [time]. Only BTC and L-BTC are tracked:
/// other Liquid assets have no price feed, exactly like the net-worth headline.
class BalanceHistoryPoint {
  const BalanceHistoryPoint({
    required this.time,
    required this.btcSats,
    required this.lbtcSats,
  });

  final DateTime time;
  final int btcSats;
  final int lbtcSats;

  int get totalSats => btcSats + lbtcSats;

  factory BalanceHistoryPoint.fromJson(Map<String, dynamic> j) =>
      BalanceHistoryPoint(
        time: DateTime.fromMillisecondsSinceEpoch(
            ((j['ts'] as num?)?.toInt() ?? 0) * 1000),
        btcSats: (j['btc_sats'] as num?)?.toInt() ?? 0,
        lbtcSats: (j['lbtc_sats'] as num?)?.toInt() ?? 0,
      );
}

/// Balance history of a wallet, reconstructed from its transaction history.
///
/// [points] is ascending by time and ends at the wallet's real current balance
/// ([btcSats] / [lbtcSats]); it is empty for a wallet with no transactions.
/// [hasBitcoin] / [hasLiquid] report which chains this wallet actually has, so
/// the UI can hide a chain filter that would only ever show a flat zero line.
class BalanceHistory {
  const BalanceHistory({
    required this.points,
    required this.btcSats,
    required this.lbtcSats,
    required this.hasBitcoin,
    required this.hasLiquid,
  });

  final List<BalanceHistoryPoint> points;
  final int btcSats;
  final int lbtcSats;
  final bool hasBitcoin;
  final bool hasLiquid;

  int get totalSats => btcSats + lbtcSats;

  factory BalanceHistory.fromJson(Map<String, dynamic> j) => BalanceHistory(
        points: [
          for (final p in (j['points'] as List<dynamic>? ?? []))
            BalanceHistoryPoint.fromJson(p as Map<String, dynamic>),
        ],
        btcSats: (j['btc_sats'] as num?)?.toInt() ?? 0,
        lbtcSats: (j['lbtc_sats'] as num?)?.toInt() ?? 0,
        hasBitcoin: j['has_bitcoin'] as bool? ?? false,
        hasLiquid: j['has_liquid'] as bool? ?? false,
      );
}
