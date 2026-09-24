enum TxDirection { incoming, outgoing, self }

enum TxChain { bitcoin, liquid }

class Transaction {
  const Transaction({
    required this.txid,
    required this.direction,
    required this.chain,
    required this.amount,
    required this.ticker,
    required this.timestamp,
    required this.confirmations,
    this.fee,
    this.note,
    this.counterparty,
    this.fiatEstimate,
  });

  final String txid;
  final TxDirection direction;
  final TxChain chain;
  final String amount;
  final String ticker;
  final DateTime timestamp;
  final int confirmations;
  final String? fee;
  final String? note;
  final String? counterparty;
  final String? fiatEstimate;

  bool get isConfirmed => confirmations > 0;

  String get shortTxid => '${txid.substring(0, 8)}…${txid.substring(txid.length - 8)}';

  /// Six characters each side — the txid as it fits a phone row next to a
  /// chain badge and an amount column.
  String get shortTxidCompact => txid.length <= 13
      ? txid
      : '${txid.substring(0, 6)}…${txid.substring(txid.length - 6)}';

  /// 'Received' / 'Sent' / 'Self-transfer'.
  String get directionLabel => switch (direction) {
        TxDirection.incoming => 'Received',
        TxDirection.outgoing => 'Sent',
        TxDirection.self => 'Self-transfer',
      };
}
