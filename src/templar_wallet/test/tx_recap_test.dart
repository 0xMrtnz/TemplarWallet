// TxRecapPanel: the recipient row keeps address and amount on one line where
// there is room and stacks them below 360 dp, so the highlighted address tail
// is never ellipsised away in a phone sheet.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:templar_wallet/features/send/models/tx_preview.dart';
import 'package:templar_wallet/shared/widgets/hex_text.dart';
import 'package:templar_wallet/shared/widgets/tx_recap.dart';

const _addr = 'tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx';
const _change = 'tb1qrp33g0q5c5txsp9arysrx4k6zdkfs4nce4xj0gdcccefvpysxf3q0sl5k7';

TxPreview _preview() => TxPreview(
      chain: 'bitcoin',
      recipientAddress: _addr,
      amountDisplay: '0.00010000 BTC',
      feeSats: 141,
      feeDisplay: '141 sats',
      totalDisplay: '0.00010141 BTC',
      outputs: const [
        TxIo(address: _addr, amountSats: 10000, isChange: false),
        TxIo(address: _change, amountSats: 89859, isChange: true),
      ],
    );

Widget _host(double width) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: TxRecapPanel(preview: _preview(), ticker: 'BTC'),
          ),
        ),
      ),
    );

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('wide: address and amount share a line', (tester) async {
    await tester.pumpWidget(_host(520));
    expect(tester.takeException(), isNull);
    final address = tester.getRect(find.byType(HexText).first);
    final amount = tester.getRect(find.text('0.00010000 BTC'));
    expect(amount.top, lessThan(address.bottom));
    expect(amount.left, greaterThan(address.left));
  });

  testWidgets('narrow: amount drops under the address, nothing overflows',
      (tester) async {
    await tester.pumpWidget(_host(300));
    expect(tester.takeException(), isNull);
    final address = tester.getRect(find.byType(HexText).first);
    final amount = tester.getRect(find.text('0.00010000 BTC'));
    expect(amount.top, greaterThanOrEqualTo(address.bottom));
    // Change keeps its chip and amount on one line, address beneath.
    final chip = tester.getRect(find.text('CHANGE'));
    final changeAddr = tester.getRect(find.byType(HexText).last);
    expect(changeAddr.top, greaterThanOrEqualTo(chip.bottom));
  });
}
