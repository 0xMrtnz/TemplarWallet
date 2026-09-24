// Minimal widget smoke test: real shared widgets render without a bridge.
// Deliberately does NOT pump TemplarWalletApp — the full app constructs the
// FFI bridge, which cannot load the native library inside `flutter test`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:templar_wallet/shared/widgets/badges.dart';

void main() {
  setUpAll(() {
    // No network in tests: fall back to bundled/system fonts.
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('StatusBadge renders its label', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: StatusBadge(label: 'Synced', variant: BadgeVariant.success),
        ),
      ),
    );
    expect(find.text('Synced'), findsOneWidget);
  });

  testWidgets('AssetBadge upper-cases the ticker', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: AssetBadge(ticker: 'lbtc')),
      ),
    );
    expect(find.text('LBTC'), findsOneWidget);
  });
}
