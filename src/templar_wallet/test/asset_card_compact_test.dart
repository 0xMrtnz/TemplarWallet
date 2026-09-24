// The compact (phone) asset row must never overflow: a long amount ellipsises
// and the name stays on the row. Runs on the host, so `compact: true` is
// passed explicitly rather than derived from the platform.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:templar_wallet/app/app_state.dart';
import 'package:templar_wallet/features/dashboard/models/dashboard_data.dart';
import 'package:templar_wallet/shared/widgets/asset_card.dart';

Widget host(Widget child, {double width = 379}) => MaterialApp(
      home: ChangeNotifierProvider<AppState>(
        create: (_) => AppState(),
        child: Scaffold(
          body: Center(
            child: SizedBox(width: width, child: child),
          ),
        ),
      ),
    );

const _asset = AssetBalance(
  assetId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  ticker: 'USDT',
  name: 'PEGx USDt Testnet with a deliberately long display name',
  amount: 123456789012,
  displayAmount: '1,234,567,890.12345678 USDT',
  utxoCount: 3,
);

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  testWidgets('compact row fits a phone column with a long amount', (t) async {
    await t.pumpWidget(host(GroupedAssetCard(
      group: const AssetGroup(main: _asset),
      isHidden: false,
      compact: true,
      onTap: () {},
    )));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.textContaining('PEGx USDt'), findsOneWidget);
    expect(find.text('1,234,567,890.12345678 USDT'), findsOneWidget);
    // One row, not the grid tile's stacked card.
    final h = t.getSize(find.byType(GroupedAssetCard)).height;
    expect(h, lessThan(90), reason: 'compact row should be ~60 dp, was $h');
  });

  testWidgets('compact row survives a 320-dp column', (t) async {
    await t.pumpWidget(host(
      GroupedAssetCard(
        group: const AssetGroup(main: _asset, reissuanceToken: _asset),
        isHidden: true,
        compact: true,
        onTap: null,
      ),
      width: 320,
    ));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });

  testWidgets('grid tile is unchanged by the flag default', (t) async {
    await t.pumpWidget(host(
      const GroupedAssetCard(
        group: AssetGroup(main: _asset),
        isHidden: false,
        onTap: null,
      ),
      width: 190,
    ));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.text('3 UTXOs'), findsOneWidget);
  });
}
