// Activity row helpers on the Transaction model: the two abbreviated txid
// forms (desktop 8…8, phone 6…6) and the direction label the phone row shows.

import 'package:flutter_test/flutter_test.dart';
import 'package:templar_wallet/features/history/models/transaction.dart';

Transaction tx({
  String txid =
      'abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890',
  TxDirection direction = TxDirection.incoming,
}) =>
    Transaction(
      txid: txid,
      direction: direction,
      chain: TxChain.bitcoin,
      amount: '+0.005 BTC',
      ticker: 'BTC',
      timestamp: DateTime(2026, 9, 1),
      confirmations: 6,
    );

void main() {
  test('shortTxid keeps eight characters each side', () {
    expect(tx().shortTxid, 'abcdef12…34567890');
  });

  test('shortTxidCompact keeps six characters each side', () {
    expect(tx().shortTxidCompact, 'abcdef…567890');
  });

  test('shortTxidCompact leaves a short id alone', () {
    expect(tx(txid: 'pending-1').shortTxidCompact, 'pending-1');
  });

  test('directionLabel names all three directions', () {
    expect(tx(direction: TxDirection.incoming).directionLabel, 'Received');
    expect(tx(direction: TxDirection.outgoing).directionLabel, 'Sent');
    expect(tx(direction: TxDirection.self).directionLabel, 'Self-transfer');
  });
}
