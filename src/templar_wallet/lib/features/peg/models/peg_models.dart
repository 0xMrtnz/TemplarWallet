/// A quote from the peg provider for moving [amountSats] between chains.
///
/// Direction is `"in"` (BTC → L-BTC) or `"out"` (L-BTC → BTC). All amounts are
/// in satoshis. [simulated] is always true while the provider is the built-in
/// mock — the UI labels every quote and order accordingly.
class PegQuote {
  const PegQuote({
    required this.direction,
    required this.amountSats,
    required this.rate,
    required this.serviceFeeSats,
    required this.networkFeeSats,
    required this.receiveSats,
    required this.minSats,
    required this.maxSats,
    required this.etaMinutes,
    required this.simulated,
  });

  final String direction;
  final int amountSats;
  final double rate;
  final int serviceFeeSats;
  final int networkFeeSats;

  /// What lands at the payout address after all fees.
  final int receiveSats;
  final int minSats;
  final int maxSats;
  final int etaMinutes;
  final bool simulated;

  factory PegQuote.fromJson(Map<String, dynamic> j) => PegQuote(
        direction: j['direction'] as String? ?? 'in',
        amountSats: (j['amount_sats'] as num?)?.toInt() ?? 0,
        rate: (j['rate'] as num?)?.toDouble() ?? 1.0,
        serviceFeeSats: (j['service_fee_sats'] as num?)?.toInt() ?? 0,
        networkFeeSats: (j['network_fee_sats'] as num?)?.toInt() ?? 0,
        receiveSats: (j['receive_sats'] as num?)?.toInt() ?? 0,
        minSats: (j['min_sats'] as num?)?.toInt() ?? 0,
        maxSats: (j['max_sats'] as num?)?.toInt() ?? 0,
        etaMinutes: (j['eta_minutes'] as num?)?.toInt() ?? 0,
        simulated: j['simulated'] as bool? ?? true,
      );
}

/// One entry of a peg order's status history: which [status] was entered and
/// when ([at], unix seconds).
class PegStatusEntry {
  const PegStatusEntry({required this.status, required this.at});

  final String status;
  final int at;

  factory PegStatusEntry.fromJson(Map<String, dynamic> j) => PegStatusEntry(
        status: j['status'] as String? ?? '',
        at: (j['at'] as num?)?.toInt() ?? 0,
      );
}

/// A peg-in/peg-out order tracked by the provider.
///
/// Lifecycle: `awaiting_deposit → deposit_seen → confirming → settling →
/// completed`, with a `cancelled` branch available only from
/// `awaiting_deposit`.
class PegOrder {
  const PegOrder({
    required this.orderId,
    required this.walletId,
    required this.direction,
    required this.status,
    required this.depositAddress,
    required this.depositExpectedSats,
    required this.payoutAddress,
    required this.payoutExpectedSats,
    required this.createdAt,
    required this.updatedAt,
    required this.etaMinutes,
    this.txidDeposit,
    this.txidPayout,
    required this.simulated,
    required this.statusHistory,
  });

  final String orderId;
  final String walletId;

  /// `"in"` = BTC → L-BTC, `"out"` = L-BTC → BTC.
  final String direction;
  final String status;

  /// Where the user must send the deposit (SIMULATED address for now).
  final String depositAddress;
  final int depositExpectedSats;
  final String payoutAddress;
  final int payoutExpectedSats;

  /// Unix seconds.
  final int createdAt;
  final int updatedAt;
  final int etaMinutes;
  final String? txidDeposit;
  final String? txidPayout;
  final bool simulated;
  final List<PegStatusEntry> statusHistory;

  bool get isPegIn => direction == 'in';
  bool get awaitingDeposit => status == 'awaiting_deposit';

  /// Terminal orders never change again — polling skips them.
  bool get isTerminal => status == 'completed' || status == 'cancelled';

  factory PegOrder.fromJson(Map<String, dynamic> j) => PegOrder(
        orderId: j['order_id'] as String? ?? '',
        walletId: j['wallet_id'] as String? ?? '',
        direction: j['direction'] as String? ?? 'in',
        status: j['status'] as String? ?? '',
        depositAddress: j['deposit_address'] as String? ?? '',
        depositExpectedSats:
            (j['deposit_expected_sats'] as num?)?.toInt() ?? 0,
        payoutAddress: j['payout_address'] as String? ?? '',
        payoutExpectedSats: (j['payout_expected_sats'] as num?)?.toInt() ?? 0,
        createdAt: (j['created_at'] as num?)?.toInt() ?? 0,
        updatedAt: (j['updated_at'] as num?)?.toInt() ?? 0,
        etaMinutes: (j['eta_minutes'] as num?)?.toInt() ?? 0,
        txidDeposit: j['txid_deposit'] as String?,
        txidPayout: j['txid_payout'] as String?,
        simulated: j['simulated'] as bool? ?? true,
        statusHistory: (j['status_history'] as List?)
                ?.whereType<Map<String, dynamic>>()
                .map(PegStatusEntry.fromJson)
                .toList() ??
            const [],
      );
}
