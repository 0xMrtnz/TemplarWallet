// The phone shell's route map and the header it drives: which carousel slot a
// path keeps centred, where its back arrow goes, and what the header calls
// it — plus the header itself switching between the wallet and "‹ Title".

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:templar_wallet/app/app_state.dart';
import 'package:templar_wallet/app/routes.dart';
import 'package:templar_wallet/app/shell.dart';
import 'package:templar_wallet/shared/widgets/carousel_nav.dart';

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  group('carousel items', () {
    test('a Bitcoin-only wallet browses four places', () {
      final ids = mobileNavItems(liquid: false).map((i) => i.id).toList();
      expect(ids, ['dashboard', 'history', 'utxos', 'settings']);
    });

    test('a Liquid wallet adds the Liquid hub and nothing else', () {
      final ids = mobileNavItems(liquid: true).map((i) => i.id).toList();
      expect(ids, ['dashboard', 'history', 'utxos', 'liquid', 'settings']);
    });
  });

  group('mobileNavRouteFor', () {
    test('a carousel page is its own slot', () {
      for (final r in [
        AppRoutes.dashboard,
        AppRoutes.history,
        AppRoutes.utxos,
        AppRoutes.liquid,
        AppRoutes.settings,
      ]) {
        expect(mobileNavRouteFor(r), r);
      }
    });

    test('Send and Receive keep the Dashboard centred', () {
      expect(mobileNavRouteFor(AppRoutes.send), AppRoutes.dashboard);
      expect(mobileNavRouteFor(AppRoutes.receive), AppRoutes.dashboard);
      expect(
        mobileNavRouteFor(AppRoutes.receiveAddresses),
        AppRoutes.dashboard,
      );
    });

    test('the Liquid hub tabs and sub-screens keep Liquid centred', () {
      for (final r in [
        AppRoutes.swap,
        AppRoutes.peg,
        AppRoutes.issueAsset,
        AppRoutes.reissueAsset,
        AppRoutes.burnAsset,
        AppRoutes.assetOperations,
      ]) {
        expect(mobileNavRouteFor(r), AppRoutes.liquid, reason: r);
      }
    });

    test('Wallet info and the settings sections keep Settings centred', () {
      for (final r in [
        AppRoutes.walletInfo,
        AppRoutes.settingsNetwork,
        AppRoutes.settingsProtocol,
        AppRoutes.settingsSecurity,
        AppRoutes.settingsAppearance,
        AppRoutes.settingsAbout,
      ]) {
        expect(mobileNavRouteFor(r), AppRoutes.settings, reason: r);
      }
    });
  });

  group('mobileParentRouteFor', () {
    test('a carousel page and a hub tab have no parent (back = Dashboard)', () {
      for (final r in [
        AppRoutes.dashboard,
        AppRoutes.history,
        AppRoutes.utxos,
        AppRoutes.liquid,
        AppRoutes.swap,
        AppRoutes.peg,
        AppRoutes.settings,
      ]) {
        expect(mobileParentRouteFor(r), isNull, reason: r);
      }
    });

    test('sub-pages return to the page they were opened from', () {
      expect(mobileParentRouteFor(AppRoutes.send), AppRoutes.dashboard);
      expect(mobileParentRouteFor(AppRoutes.receive), AppRoutes.dashboard);
      expect(
        mobileParentRouteFor(AppRoutes.receiveAddresses),
        AppRoutes.receive,
      );
      expect(mobileParentRouteFor(AppRoutes.walletInfo), AppRoutes.settings);
      expect(
        mobileParentRouteFor(AppRoutes.settingsSecurity),
        AppRoutes.settings,
      );
      expect(mobileParentRouteFor(AppRoutes.issueAsset), AppRoutes.liquid);
    });
  });

  group('mobileSubPageTitle', () {
    test('names every sub-page and no carousel page', () {
      expect(mobileSubPageTitle(AppRoutes.send), 'Send');
      expect(mobileSubPageTitle(AppRoutes.receive), 'Receive');
      expect(mobileSubPageTitle(AppRoutes.receiveAddresses), 'All addresses');
      expect(mobileSubPageTitle(AppRoutes.walletInfo), 'Wallet info');
      expect(mobileSubPageTitle(AppRoutes.settingsSecurity), 'Vault & backup');
      expect(mobileSubPageTitle(AppRoutes.settingsProtocol), 'Templar Protocol');
      expect(mobileSubPageTitle(AppRoutes.dashboard), isNull);
      expect(mobileSubPageTitle(AppRoutes.settings), isNull);
      expect(mobileSubPageTitle(AppRoutes.swap), isNull);
    });

    test('every route with a parent has a title, and vice versa', () {
      for (final r in [
        AppRoutes.send,
        AppRoutes.receive,
        AppRoutes.walletInfo,
        AppRoutes.settingsNetwork,
        AppRoutes.settingsSecurity,
        AppRoutes.settingsAppearance,
        AppRoutes.settingsAbout,
        AppRoutes.issueAsset,
        AppRoutes.reissueAsset,
        AppRoutes.burnAsset,
        AppRoutes.assetOperations,
      ]) {
        expect(mobileParentRouteFor(r), isNotNull, reason: r);
        expect(mobileSubPageTitle(r), isNotNull, reason: r);
      }
    });
  });

  group('MobileShell header', () {
    Future<void> pump(WidgetTester tester, String path) async {
      tester.view.physicalSize = const Size(411, 914);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider(
          create: (_) => AppState(),
          child: MaterialApp(
            home: MobileShell(currentPath: path, child: const SizedBox()),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('a carousel page shows the wallet, not an arrow', (
      tester,
    ) async {
      await pump(tester, AppRoutes.dashboard);
      expect(find.text('Open wallet…'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back_rounded), findsNothing);
      expect(find.byType(CarouselNav), findsOneWidget);
    });

    testWidgets('a sub-page shows "‹ Title" and keeps the carousel', (
      tester,
    ) async {
      await pump(tester, AppRoutes.send);
      expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);
      expect(find.text('Send'), findsOneWidget);
      expect(find.text('Open wallet…'), findsNothing);
      // The bar stays, centred on the parent.
      expect(find.byType(CarouselNav), findsOneWidget);
      expect(find.text('Dashboard'), findsOneWidget);
      // The arrow is a full-height header target.
      final arrow = tester.getSize(
        find.ancestor(
          of: find.byIcon(Icons.arrow_back_rounded),
          matching: find.byType(InkWell),
        ).first,
      );
      expect(arrow.height, greaterThanOrEqualTo(48));
    });

    testWidgets('the Liquid hub gets its tab strip, sub-screens do not', (
      tester,
    ) async {
      await pump(tester, AppRoutes.swap);
      expect(find.text('Assets'), findsOneWidget);
      expect(find.text('LiquiDEX'), findsOneWidget);
      expect(find.text('Peg'), findsOneWidget);

      await pump(tester, AppRoutes.issueAsset);
      expect(find.text('Assets'), findsNothing);
      expect(find.text('Issue asset'), findsOneWidget);
    });
  });
}
