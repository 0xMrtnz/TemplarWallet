// Payment links: what a Receive QR carries once an amount is asked for, and
// what a Send field must make of one. Pure text either way — the round trip
// is the whole contract, so it is pinned here rather than in a widget test.
import 'package:flutter_test/flutter_test.dart';
import 'package:templar_wallet/shared/payment_uri.dart';

void main() {
  group('build', () {
    test('bare address when nothing is asked for', () {
      expect(
        PaymentUri.build(address: 'tb1qexample', asset: 'BTC'),
        'bitcoin:tb1qexample',
      );
    });

    test('amount is decimal coin without trailing zeros', () {
      expect(
        PaymentUri.build(
            address: 'tb1qexample', asset: 'BTC', amountSats: 100000),
        'bitcoin:tb1qexample?amount=0.001',
      );
      expect(
        PaymentUri.build(
            address: 'tb1qexample', asset: 'BTC', amountSats: 100000000),
        'bitcoin:tb1qexample?amount=1',
      );
      expect(
        PaymentUri.build(address: 'tb1qexample', asset: 'BTC', amountSats: 1),
        'bitcoin:tb1qexample?amount=0.00000001',
      );
    });

    test('Liquid gets its own scheme', () {
      expect(
        PaymentUri.build(address: 'tlq1qexample', asset: 'LBTC'),
        'liquidtestnet:tlq1qexample',
      );
    });

    test('a note is percent-encoded, never form-encoded', () {
      final uri = PaymentUri.build(
        address: 'tb1qexample',
        asset: 'BTC',
        amountSats: 100000,
        label: 'Invoice 12 & co',
      );
      expect(uri, 'bitcoin:tb1qexample?amount=0.001&label=Invoice%2012%20%26%20co');
      expect(uri, isNot(contains('+')));
    });

    test('a note alone still makes a link', () {
      expect(
        PaymentUri.build(address: 'tb1qexample', asset: 'BTC', label: 'Rent'),
        'bitcoin:tb1qexample?label=Rent',
      );
    });

    test('an empty or zero request adds no query', () {
      expect(
        PaymentUri.build(
            address: 'tb1qexample', asset: 'BTC', amountSats: 0, label: '   '),
        'bitcoin:tb1qexample',
      );
    });
  });

  group('isPaymentUri', () {
    test('knows the two schemes, case-insensitively', () {
      expect(PaymentUri.isPaymentUri('bitcoin:tb1qexample'), isTrue);
      expect(PaymentUri.isPaymentUri('BITCOIN:TB1QEXAMPLE'), isTrue);
      expect(PaymentUri.isPaymentUri('liquidtestnet:tlq1qexample'), isTrue);
    });

    test('a bare address is not one', () {
      expect(PaymentUri.isPaymentUri('tb1qexample'), isFalse);
      expect(PaymentUri.isPaymentUri(''), isFalse);
      expect(PaymentUri.isPaymentUri('https://example.com'), isFalse);
      expect(PaymentUri.isPaymentUri(':nothing'), isFalse);
    });
  });

  group('parse', () {
    test('round-trips what build wrote', () {
      final uri = PaymentUri.build(
        address: 'tb1qexample',
        asset: 'BTC',
        amountSats: 123456,
        label: 'Invoice 12 & co',
      );
      final req = PaymentUri.parse(uri)!;
      expect(req.address, 'tb1qexample');
      expect(req.amountSats, 123456);
      expect(req.label, 'Invoice 12 & co');
    });

    test('null for anything that is not a payment link', () {
      expect(PaymentUri.parse('tb1qexample'), isNull);
      expect(PaymentUri.parse('  '), isNull);
      expect(PaymentUri.parse('bitcoin:'), isNull);
    });

    test('surrounding whitespace is trimmed', () {
      final req = PaymentUri.parse('  bitcoin:tb1qexample?amount=0.5  ')!;
      expect(req.address, 'tb1qexample');
      expect(req.amountSats, 50000000);
    });

    test('an address with no query parses to an address', () {
      final req = PaymentUri.parse('bitcoin:tb1qexample')!;
      expect(req.address, 'tb1qexample');
      expect(req.amountSats, isNull);
      expect(req.label, isNull);
    });

    test('an amount that is not a number is dropped, the address survives',
        () {
      final req = PaymentUri.parse('bitcoin:tb1qexample?amount=abc')!;
      expect(req.address, 'tb1qexample');
      expect(req.amountSats, isNull);
    });

    test('a zero amount counts as no amount', () {
      final req = PaymentUri.parse('bitcoin:tb1qexample?amount=0')!;
      expect(req.amountSats, isNull);
    });

    test('unknown parameters are ignored', () {
      final req = PaymentUri.parse(
          'bitcoin:tb1qexample?amount=0.001&message=hi&req-future=x')!;
      expect(req.address, 'tb1qexample');
      expect(req.amountSats, 100000);
      expect(req.label, isNull);
    });

    test('a broken escape leaves the address readable', () {
      final req = PaymentUri.parse('bitcoin:tb1qexample?label=%zz')!;
      expect(req.address, 'tb1qexample');
      expect(req.amountSats, isNull);
    });

    test('Liquid links parse the same way', () {
      final req =
          PaymentUri.parse('liquidtestnet:tlq1qexample?amount=0.002')!;
      expect(req.address, 'tlq1qexample');
      expect(req.amountSats, 200000);
    });
  });
}
