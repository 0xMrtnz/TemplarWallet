import 'package:flutter_test/flutter_test.dart';
import 'package:templar_wallet/features/utxos/models/pending_consolidation.dart';

PendingConsolidation make({
  String txid = 'aa11bb22cc33dd44',
  List<String> inputs = const ['x:0', 'y:1'],
  DateTime? startedAt,
}) =>
    PendingConsolidation(
      txid: txid,
      walletId: 'w1',
      chain: 'BTC',
      inputs: inputs,
      amount: 120000,
      displayAmount: '120000 sats',
      ticker: 'BTC',
      startedAt: startedAt ?? DateTime.now(),
    );

void main() {
  group('isSettledBy', () {
    test('matches an output of this transaction', () {
      expect(make().isSettledBy('aa11bb22cc33dd44:0'), isTrue);
      expect(make().isSettledBy('aa11bb22cc33dd44:7'), isTrue);
    });

    test('does not match a txid that merely starts the same', () {
      // The colon is load-bearing: without it a consolidation would consider
      // itself settled by an unrelated coin whose txid shares a prefix, and
      // the placeholder would vanish while the merge was still in flight.
      expect(make().isSettledBy('aa11bb22cc33dd4499:0'), isFalse);
    });

    test('does not match an unrelated coin', () {
      expect(make().isSettledBy('ffffffff:0'), isFalse);
    });
  });

  group('isStale', () {
    test('a fresh consolidation is not stale', () {
      expect(make().isStale, isFalse);
    });

    test('gives up after a day so a dropped tx cannot wedge the view', () {
      final old = make(
        startedAt: DateTime.now().subtract(const Duration(hours: 25)),
      );
      expect(old.isStale, isTrue);
    });
  });

  test('count reports how many coins are merging', () {
    expect(make(inputs: const ['a:0', 'b:1', 'c:2']).count, 3);
  });

  group('json', () {
    test('round-trips', () {
      final before = make();
      final after = PendingConsolidation.fromJson(before.toJson())!;
      expect(after.txid, before.txid);
      expect(after.walletId, before.walletId);
      expect(after.chain, before.chain);
      expect(after.inputs, before.inputs);
      expect(after.amount, before.amount);
      expect(after.displayAmount, before.displayAmount);
      expect(after.ticker, before.ticker);
      expect(
        after.startedAt.toIso8601String(),
        before.startedAt.toIso8601String(),
      );
    });

    test('rejects entries missing the fields it is keyed on', () {
      // A malformed row must be skipped, not crash the UTXO screen on load.
      expect(PendingConsolidation.fromJson({'txid': 'a'}), isNull);
      expect(
        PendingConsolidation.fromJson({'txid': 'a', 'wallet_id': 'w1'}),
        isNull,
      );
      expect(
        PendingConsolidation.fromJson(
          {'txid': 'a', 'wallet_id': 'w1', 'started_at': 'not-a-date'},
        ),
        isNull,
      );
    });

    test('tolerates a row written without the optional fields', () {
      final p = PendingConsolidation.fromJson({
        'txid': 'a',
        'wallet_id': 'w1',
        'started_at': DateTime.now().toIso8601String(),
      });
      expect(p, isNotNull);
      expect(p!.inputs, isEmpty);
      expect(p.chain, 'BTC');
      expect(p.ticker, isNull);
    });
  });
}
