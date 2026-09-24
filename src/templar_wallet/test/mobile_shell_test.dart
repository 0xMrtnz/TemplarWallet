// The phone shell's chrome, laid out on a Pixel 6 class surface without a
// device: the header takes the status bar once and stays one 48-dp row, the
// sync pill's hit box spans that row, the carousel sits on the bottom inset
// at its documented height, and nothing in the tree throws.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:templar_wallet/app/app_state.dart';
import 'package:templar_wallet/app/shell.dart';
import 'package:templar_wallet/shared/widgets/carousel_nav.dart';

const double _width = 411;
const double _height = 914;
const double _statusBar = 24;
const double _gestureInset = 24;

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('mobile shell chrome lays out on a 411x914 phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(_width, _height);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(
      top: _statusBar,
      bottom: _gestureInset,
    );
    tester.view.viewPadding = const FakeViewPadding(
      top: _statusBar,
      bottom: _gestureInset,
    );
    addTearDown(tester.view.reset);

    const pageKey = Key('page');
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppState(),
        child: const MaterialApp(
          home: MobileShell(
            currentPath: '/dashboard',
            child: SizedBox.expand(key: pageKey),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);

    // Header: the status bar plus one 48-dp row with 2 dp above and below.
    final header = tester.getRect(find.byType(SafeArea).first);
    expect(header.top, 0);
    expect(header.height, _statusBar + 2 + 48 + 2);

    // Both header controls fill the row: the wallet button and the sync
    // pill's InkWell are each 48 dp tall.
    final wallet = tester.getSize(
      find.ancestor(
        of: find.text('Open wallet…'),
        matching: find.byType(InkWell),
      ),
    );
    expect(wallet.height, 48);
    final pill = tester.getSize(
      find.ancestor(of: find.text('Idle'), matching: find.byType(InkWell)),
    );
    expect(pill.height, 48);

    // The page starts right under the header (whose hairline is painted
    // inside its own last dp) and never takes the status bar again. Tests
    // run on the mock bridge, so its 40-dp MOCK DATA strip sits in between —
    // one strip at most.
    final pageTop = tester.getTopLeft(find.byKey(pageKey)).dy;
    expect(pageTop, greaterThanOrEqualTo(header.bottom));
    expect(pageTop, lessThanOrEqualTo(header.bottom + 40));

    // Carousel: its documented inset-aware height, flush with the bottom.
    final bar = tester.getRect(find.byType(CarouselNav));
    expect(bar.bottom, _height);
    expect(bar.height, CarouselNav.heightFor(_gestureInset));
    expect(bar.height, lessThanOrEqualTo(110));
  });
}
