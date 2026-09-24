// Decode contract for BalanceHistory.fromJson — the exact shape wallet-ffi's
// BalanceHistoryDto serializes (see src/wallet-ffi/src/handlers/history.rs,
// asserted from the Rust side by `wire_shape_matches_contract_keys`).
//
// The fixtures below are the degenerate payloads the handler really produces:
// an empty history with a live balance, a single point, and a single-chain
// wallet. Each one drives a different branch of the Home portfolio chart.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:templar_wallet/features/dashboard/models/balance_history.dart';

Map<String, dynamic> decode(String raw) =>
    jsonDecode(raw) as Map<String, dynamic>;

void main() {
  test('decodes a two-chain history as serialized by wallet-ffi', () {
    final h = BalanceHistory.fromJson(decode('''
      {
        "points": [
          {"ts": 1700000000, "btc_sats": 100000, "lbtc_sats": 0},
          {"ts": 1700086400, "btc_sats": 100000, "lbtc_sats": 5000}
        ],
        "btc_sats": 100000,
        "lbtc_sats": 5000,
        "has_bitcoin": true,
        "has_liquid": true
      }
    '''));

    expect(h.points.length, 2);
    expect(h.btcSats, 100000);
    expect(h.lbtcSats, 5000);
    expect(h.totalSats, 105000);
    expect(h.hasBitcoin, isTrue);
    expect(h.hasLiquid, isTrue);

    // `ts` is unix SECONDS on the wire; the model must widen it to millis.
    expect(h.points.first.time,
        DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000));
    expect(h.points.last.totalSats, 105000);

    // Ascending, and the last point agrees with the live balance — the two
    // invariants the chart's window/carry logic relies on.
    expect(h.points.first.time.isBefore(h.points.last.time), isTrue);
    expect(h.points.last.totalSats, h.totalSats);
  });

  test('empty history still carries the live balance', () {
    // The handler emits this for a wallet whose tx listing failed or whose
    // transactions all net to zero. The chart must draw a flat line here, not
    // an empty state, so the balances have to survive the decode.
    final h = BalanceHistory.fromJson(decode('''
      {"points": [], "btc_sats": 1234567, "lbtc_sats": 0,
       "has_bitcoin": true, "has_liquid": false}
    '''));

    expect(h.points, isEmpty);
    expect(h.totalSats, 1234567);
    expect(h.hasBitcoin, isTrue);
    expect(h.hasLiquid, isFalse);
  });

  test('single point and single chain decode', () {
    final h = BalanceHistory.fromJson(decode('''
      {"points": [{"ts": 1700000000, "btc_sats": 0, "lbtc_sats": 42}],
       "btc_sats": 0, "lbtc_sats": 42,
       "has_bitcoin": false, "has_liquid": true}
    '''));

    expect(h.points.length, 1);
    expect(h.hasBitcoin, isFalse);
    // A Liquid-only wallet: the chart hides the chain filter and the default
    // "All" total must still be the L-BTC balance.
    expect(h.totalSats, 42);
  });

  test('is null-tolerant on every field', () {
    final h = BalanceHistory.fromJson(decode('{}'));
    expect(h.points, isEmpty);
    expect(h.totalSats, 0);
    expect(h.hasBitcoin, isFalse);
    expect(h.hasLiquid, isFalse);

    final p = BalanceHistoryPoint.fromJson(decode('{}'));
    expect(p.totalSats, 0);
    expect(p.time.millisecondsSinceEpoch, 0);
  });

  test('tolerates a negative or absent balance without throwing', () {
    // The handler floors at 0, but the model must not depend on that.
    final h = BalanceHistory.fromJson(decode('''
      {"points": [{"ts": 0, "btc_sats": -1}],
       "btc_sats": -1, "has_liquid": true}
    '''));
    expect(h.points.single.lbtcSats, 0);
    expect(h.lbtcSats, 0);
    expect(h.hasLiquid, isTrue);
  });
}
