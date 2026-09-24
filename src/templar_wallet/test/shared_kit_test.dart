// Shared-kit leaf widgets: the width-safety guarantees every screen relies
// on. Phone-only metrics key off dart:io's Platform and cannot be exercised
// here; these cover the ungated behaviour that must hold on every platform.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:templar_wallet/shared/widgets/badges.dart';
import 'package:templar_wallet/shared/widgets/buttons.dart';
import 'package:templar_wallet/shared/widgets/hex_text.dart';
import 'package:templar_wallet/theme/app_theme.dart';

Widget _host(Widget child) => MaterialApp(
  theme: AppTheme.dark(),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  group('middle ellipsis', () {
    const txid =
        'abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890';

    test('standard form keeps 12 and 8', () {
      expect(middleEllipsis(txid), 'abcdef123456…34567890');
      expect(middleEllipsis('short'), 'short');
    });

    test('fit never exceeds the budget and keeps both ends', () {
      for (final budget in [8, 12, 21, 40, 64, 80]) {
        final out = fitMiddleEllipsis(txid, budget);
        expect(out.length, lessThanOrEqualTo(budget < 9 ? 9 : budget),
            reason: 'budget $budget');
        expect(out, startsWith('abcd'));
        expect(out, endsWith('7890'));
      }
      expect(fitMiddleEllipsis(txid, 64), txid);
    });
  });

  testWidgets('StatusBadge shrinks its label instead of overflowing',
      (tester) async {
    await tester.pumpWidget(_host(
      const SizedBox(
        width: 40,
        child: Row(
          children: [
            Flexible(
              child: StatusBadge(
                label: 'A very long status label',
                variant: BadgeVariant.success,
              ),
            ),
          ],
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(StatusBadge)).width,
        lessThanOrEqualTo(40));
  });

  testWidgets('PrimaryButton ellipsises an icon+label in a narrow host',
      (tester) async {
    await tester.pumpWidget(_host(
      SizedBox(
        width: 90,
        child: PrimaryButton(
          label: 'Copy address to clipboard',
          icon: Icons.copy,
          isFullWidth: true,
          onPressed: () {},
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(find.text('Copy address to clipboard'), findsOneWidget);
  });

  testWidgets('SecondaryButton keeps a long label inside its tile',
      (tester) async {
    await tester.pumpWidget(_host(
      SizedBox(
        width: 100,
        child: SecondaryButton(
          label: 'Share the signed transaction file',
          icon: Icons.share,
          isFullWidth: true,
          onPressed: () {},
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
  });

  testWidgets('HexText.fit collapses to the available width', (tester) async {
    const txid =
        'abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890';
    await tester.pumpWidget(_host(
      const SizedBox(width: 120, child: HexText(txid, fit: true)),
    ));
    expect(tester.takeException(), isNull);
    final rich = tester.widget<Text>(find.byType(Text));
    final shown = rich.textSpan!.toPlainText();
    expect(shown, startsWith('abcd'));
    expect(shown, endsWith('7890'));
    expect(shown, contains('…'));
    expect(shown.length, lessThan(txid.length));
  });
}
