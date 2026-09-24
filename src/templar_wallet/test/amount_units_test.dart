// The Send screen's amount arithmetic: coin and fiat text in, satoshis out,
// and the ⇅ conversion that re-expresses a typed figure in the other unit.

import 'package:flutter_test/flutter_test.dart';
import 'package:templar_wallet/shared/amount_units.dart';

void main() {
  group('parseDecimal', () {
    test('accepts a decimal comma as well as a point', () {
      expect(AmountUnits.parseDecimal('0.001'), 0.001);
      expect(AmountUnits.parseDecimal('0,001'), 0.001);
      expect(AmountUnits.parseDecimal(' 12,5 '), 12.5);
    });

    test('rejects empty, negative and non-numeric text', () {
      expect(AmountUnits.parseDecimal(''), isNull);
      expect(AmountUnits.parseDecimal('   '), isNull);
      expect(AmountUnits.parseDecimal('-1'), isNull);
      expect(AmountUnits.parseDecimal('abc'), isNull);
      expect(AmountUnits.parseDecimal('1.2.3'), isNull);
    });
  });

  group('satsFromCoin', () {
    test('converts BTC with eight decimals to sats', () {
      expect(AmountUnits.satsFromCoin('1'), 100000000);
      expect(AmountUnits.satsFromCoin('0.00012345'), 12345);
      expect(AmountUnits.satsFromCoin('0,1'), 10000000);
    });

    test('rounds sub-satoshi noise away', () {
      expect(AmountUnits.satsFromCoin('0.000000016'), 2);
      expect(AmountUnits.satsFromCoin('0.000000004'), 0);
    });
  });

  group('satsFromFiat', () {
    test('divides by the spot price', () {
      // 100 EUR at 50,000 EUR/BTC = 0.002 BTC = 200,000 sats.
      expect(AmountUnits.satsFromFiat('100', 50000), 200000);
      expect(AmountUnits.satsFromFiat('98,40', 50000), 196800);
    });

    test('is null without a price', () {
      expect(AmountUnits.satsFromFiat('100', 0), isNull);
      expect(AmountUnits.satsFromFiat('100', -1), isNull);
    });
  });

  group('text', () {
    test('coinText is the field figure with eight decimals', () {
      expect(AmountUnits.coinText(200000), '0.00200000');
      expect(AmountUnits.coinText(0), '0.00000000');
    });

    test('fiatText is the field figure with two decimals', () {
      expect(AmountUnits.fiatText(200000, 50000), '100.00');
      expect(AmountUnits.fiatText(196800, 50000), '98.40');
    });
  });

  group('convert', () {
    test('round-trips an amount through the other unit', () {
      final fiat = AmountUnits.convert('0.002', toFiat: true, btcPrice: 50000);
      expect(fiat, '100.00');
      final coin = AmountUnits.convert(fiat!, toFiat: false, btcPrice: 50000);
      expect(coin, '0.00200000');
    });

    test('keeps an empty field empty', () {
      expect(AmountUnits.convert('', toFiat: true, btcPrice: 50000), '');
      expect(AmountUnits.convert('  ', toFiat: false, btcPrice: 50000), '');
    });

    test('leaves unparsable text and priceless flips to the caller', () {
      expect(AmountUnits.convert('abc', toFiat: true, btcPrice: 50000), isNull);
      expect(AmountUnits.convert('1', toFiat: true, btcPrice: 0), isNull);
    });
  });
}
