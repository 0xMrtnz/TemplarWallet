// TEMPORARY — deleted after the run. Degenerate-input smoke test for ValueChart.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:templar_wallet/app/app_state.dart';
import 'package:templar_wallet/shared/widgets/value_chart.dart';

Widget host(Widget child, {Size size = const Size(400, 132), bool dark = false}) {
  return MaterialApp(
    theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
    home: ChangeNotifierProvider<AppState>(
      create: (_) => AppState(),
      child: Scaffold(
        body: Center(
          child: SizedBox(width: size.width, height: size.height, child: child),
        ),
      ),
    ),
  );
}

List<ChartPoint> series(List<double> vs, {Duration step = const Duration(days: 1)}) {
  final t0 = DateTime(2026, 1, 1);
  return [
    for (var i = 0; i < vs.length; i++) ChartPoint(t0.add(step * i), vs[i]),
  ];
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  testWidgets('empty', (t) async {
    await t.pumpWidget(host(ValueChart(
      points: const [],
      formatValue: (v) => '$v',
      emptyMessage: 'Not enough history yet',
    )));
    await t.pumpAndSettle();
    expect(find.text('Not enough history yet'), findsOneWidget);
  });

  testWidgets('empty without message', (t) async {
    await t.pumpWidget(host(ValueChart(points: const [], formatValue: (v) => '$v')));
    await t.pumpAndSettle();
  });

  testWidgets('single point', (t) async {
    await t.pumpWidget(host(ValueChart(points: series([5]), formatValue: (v) => '$v')));
    await t.pumpAndSettle();
  });

  testWidgets('all equal values', (t) async {
    await t.pumpWidget(host(ValueChart(
      points: series([7, 7, 7, 7]),
      formatValue: (v) => '$v',
    )));
    await t.pumpAndSettle();
  });

  testWidgets('zero width', (t) async {
    await t.pumpWidget(host(
      ValueChart(points: series([1, 2, 3]), formatValue: (v) => '$v'),
      size: const Size(0, 132),
    ));
    await t.pumpAndSettle();
  });

  testWidgets('zero height', (t) async {
    await t.pumpWidget(host(
      ValueChart(points: series([1, 2, 3]), formatValue: (v) => '$v', height: 0),
      size: const Size(300, 0),
    ));
    await t.pumpAndSettle();
  });

  testWidgets('non-finite values survive', (t) async {
    await t.pumpWidget(host(ValueChart(
      points: series([double.nan, 2, double.infinity, 4]),
      formatValue: (v) => '$v',
    )));
    await t.pumpAndSettle();
  });

  testWidgets('duplicate timestamps', (t) async {
    final t0 = DateTime(2026, 1, 1);
    await t.pumpWidget(host(ValueChart(
      points: [ChartPoint(t0, 1), ChartPoint(t0, 2), ChartPoint(t0, 3)],
      formatValue: (v) => '$v',
    )));
    await t.pumpAndSettle();
  });

  testWidgets('large series down-samples and paints', (t) async {
    await t.pumpWidget(host(ValueChart(
      points: series(List<double>.generate(5000, (i) => (i % 97) * 3.0),
          step: const Duration(minutes: 7)),
      formatValue: (v) => '$v',
    )));
    await t.pumpAndSettle();
  });

  testWidgets('hover drives cursor chip, dark theme', (t) async {
    await t.pumpWidget(host(
      ValueChart(
        points: series(List<double>.generate(40, (i) => 100.0 + i * i)),
        formatValue: (v) => '\$${v.toStringAsFixed(2)}',
      ),
      dark: true,
    ));
    await t.pumpAndSettle();

    final g = await t.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: Offset.zero);
    addTearDown(g.removePointer);
    final box = t.getRect(find.byType(ValueChart));
    // Sweep across, including the far right where the chip must flip side.
    dynamic painterNow() {
      final cp = t.widgetList<CustomPaint>(find.descendant(
          of: find.byType(ValueChart), matching: find.byType(CustomPaint)));
      return cp.last.painter;
    }

    await g.moveTo(t.getCenter(find.byType(ValueChart)));
    await t.pumpAndSettle();

    final seen = <int>{};
    for (final f in [0.02, 0.1, 0.25, 0.5, 0.75, 0.9, 0.97, 0.999]) {
      final x = box.left + box.width * f;
      await g.moveTo(Offset(x, box.center.dy));
      await t.pumpAndSettle();
      final c = painterNow().cursor as int?;
      expect(c, isNotNull, reason: 'hover at f=$f produced no cursor');
      seen.add(c!);
      expect(painterNow().cursorValue, isNotNull);
      expect(painterNow().cursorStamp, isNotNull);
    }
    await g.moveTo(const Offset(2000, 2000));
    await t.pumpAndSettle();
    expect(seen.length, greaterThan(5), reason: 'cursor did not track x');
    expect(painterNow().cursor, isNull, reason: 'cursor must clear on exit');
  });

  testWidgets('horizontal drag drives cursor and clears', (t) async {
    await t.pumpWidget(host(ValueChart(
      points: series(List<double>.generate(30, (i) => 50.0 - i)),
      formatValue: (v) => '${v.toStringAsFixed(0)} sats',
    )));
    await t.pumpAndSettle();
    final box = t.getRect(find.byType(ValueChart));
    final g = await t.startGesture(Offset(box.left + 10, box.center.dy));
    await g.moveBy(const Offset(120, 0));
    await t.pumpAndSettle();
    await g.moveBy(const Offset(200, 0));
    await t.pumpAndSettle();
    await g.up();
    await t.pumpAndSettle();
  });

  testWidgets('points identity change restarts sweep', (t) async {
    await t.pumpWidget(host(ValueChart(points: series([1, 2, 3]), formatValue: (v) => '$v')));
    await t.pump(const Duration(milliseconds: 100));
    await t.pumpWidget(host(ValueChart(
      points: series([9, 4, 6, 2, 8]),
      formatValue: (v) => '$v',
    )));
    await t.pumpAndSettle();
  });

  testWidgets('reduced motion skips sweep', (t) async {
    await t.pumpWidget(MediaQuery(
      data: const MediaQueryData(disableAnimations: true),
      child: host(ValueChart(points: series([1, 5, 3]), formatValue: (v) => '$v')),
    ));
    await t.pump();
    await t.pumpAndSettle();
  });
}
