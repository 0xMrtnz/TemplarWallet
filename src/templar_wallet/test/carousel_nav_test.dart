// The mobile carousel's interaction model, exercised without a device: side
// tap jumps, centre tap scrolls, a cancelled drag never selects, a rested
// finger carries no flick, an outside route change moves the bar silently,
// and a gating change keeps the current item.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:templar_wallet/app/app_state.dart';
import 'package:templar_wallet/shared/widgets/carousel_nav.dart';

const _all = [
  CarouselNavItem(
    id: 'dashboard',
    label: 'Dashboard',
    route: '/dashboard',
    icon: Icons.home_outlined,
    activeIcon: Icons.home,
  ),
  CarouselNavItem(
    id: 'send',
    label: 'Send',
    route: '/send',
    icon: Icons.send_outlined,
    activeIcon: Icons.send,
  ),
  CarouselNavItem(
    id: 'receive',
    label: 'Receive',
    route: '/receive',
    icon: Icons.call_received_outlined,
    activeIcon: Icons.call_received,
  ),
  CarouselNavItem(
    id: 'settings',
    label: 'Settings',
    route: '/settings',
    icon: Icons.settings_outlined,
    activeIcon: Icons.settings,
    group: CarouselNavGroup.system,
  ),
];

Widget _host({
  required List<CarouselNavItem> items,
  required String route,
  required ValueChanged<String> onSelect,
  VoidCallback? onCenterTap,
}) {
  return ChangeNotifierProvider(
    create: (_) => AppState(),
    child: MaterialApp(
      home: Scaffold(
        body: const SizedBox.expand(),
        bottomNavigationBar: CarouselNav(
          items: items,
          currentRoute: route,
          onSelect: onSelect,
          onCenterTap: onCenterTap,
        ),
      ),
    ),
  );
}

// The default 800x600 test surface: slot spacing = clamp(800 * .27, 84, 118)
// = 118, bar top = 600 - CarouselNav.height (no system inset in tests), icon
// row centre = top + 6 (top pad) + 28 (half the 56-dp slot row).
const double _centreX = 400;
const double _slot = 118;
const double _rowY = 600 - CarouselNav.height + 6 + 28;

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  testWidgets('labels only the centred item', (tester) async {
    await tester.pumpWidget(_host(items: _all, route: '/send', onSelect: (_) {}));
    expect(find.text('Send'), findsOneWidget);
    expect(find.text('Dashboard'), findsNothing);
    expect(find.text('Receive'), findsNothing);
  });

  testWidgets('a tap on a side icon jumps there and selects it', (tester) async {
    final selected = <String>[];
    await tester.pumpWidget(_host(items: _all, route: '/send', onSelect: selected.add));
    await tester.tapAt(const Offset(_centreX + _slot, _rowY));
    await tester.pumpAndSettle();
    expect(selected, ['/receive']);
    expect(find.text('Receive'), findsOneWidget);
  });

  testWidgets('a tap on the far left wraps round the circle', (tester) async {
    final selected = <String>[];
    await tester.pumpWidget(_host(items: _all, route: '/dashboard', onSelect: selected.add));
    await tester.tapAt(const Offset(_centreX - _slot, _rowY));
    await tester.pumpAndSettle();
    expect(selected, ['/settings']);
  });

  testWidgets('a tap on the centre icon scrolls to top, never selects', (tester) async {
    final selected = <String>[];
    var centreTaps = 0;
    await tester.pumpWidget(_host(
      items: _all,
      route: '/send',
      onSelect: selected.add,
      onCenterTap: () => centreTaps++,
    ));
    await tester.tapAt(const Offset(_centreX, _rowY));
    await tester.pumpAndSettle();
    expect(centreTaps, 1);
    expect(selected, isEmpty);
    expect(find.text('Send'), findsOneWidget);
  });

  testWidgets('a rested finger snaps to the nearest slot without a flick', (tester) async {
    final selected = <String>[];
    await tester.pumpWidget(_host(items: _all, route: '/dashboard', onSelect: selected.add));
    final g = await tester.startGesture(const Offset(_centreX, _rowY));
    await g.moveBy(const Offset(-_slot * 0.6, 0));
    await tester.pump();
    // Real time must pass: the idle-velocity reset reads a wall clock.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await g.up();
    await tester.pumpAndSettle();
    expect(selected, ['/send']);
    expect(find.text('Send'), findsOneWidget);
  });

  testWidgets('a cancelled drag settles back and selects nothing', (tester) async {
    final selected = <String>[];
    await tester.pumpWidget(_host(items: _all, route: '/dashboard', onSelect: selected.add));
    final g = await tester.startGesture(const Offset(_centreX, _rowY));
    await g.moveBy(const Offset(-_slot * 0.2, 0));
    await tester.pump();
    // A little real time, then more travel: the finger now has a speed that
    // would flick the bar a slot on if the cancel were taken as a release —
    // which is what the drag recognizer does once it has accepted a drag.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 8)),
    );
    await g.moveBy(const Offset(-_slot * 0.1, 0));
    await tester.pump();
    await g.cancel();
    await tester.pumpAndSettle();
    expect(selected, isEmpty);
    expect(find.text('Dashboard'), findsOneWidget);
  });

  testWidgets('an outside route change moves the bar without selecting', (tester) async {
    final selected = <String>[];
    await tester.pumpWidget(_host(items: _all, route: '/dashboard', onSelect: selected.add));
    await tester.pumpWidget(_host(items: _all, route: '/receive', onSelect: selected.add));
    await tester.pumpAndSettle();
    expect(selected, isEmpty);
    expect(find.text('Receive'), findsOneWidget);
  });

  testWidgets('a gating change keeps the current item', (tester) async {
    final selected = <String>[];
    await tester.pumpWidget(_host(items: _all, route: '/receive', onSelect: selected.add));
    final withoutSend = _all.where((it) => it.id != 'send').toList();
    await tester.pumpWidget(_host(items: withoutSend, route: '/receive', onSelect: selected.add));
    await tester.pumpAndSettle();
    expect(selected, isEmpty);
    expect(find.text('Receive'), findsOneWidget);
  });
}
