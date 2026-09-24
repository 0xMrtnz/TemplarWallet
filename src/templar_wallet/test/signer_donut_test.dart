// SignerDonut — the signature-quorum ring shown when a PSBT is inspected.
//
// The counts it draws come straight off an untrusted blob, so the degenerate
// shapes are the point of this file: no signers at all, more signatures than
// slots, a quorum larger than the ring.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:templar_wallet/shared/widgets/signer_donut.dart';

Widget host(Widget child, {bool dark = false, bool reduceMotion = false}) {
  return MaterialApp(
    theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: Scaffold(body: Center(child: child)),
    ),
  );
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  testWidgets('reads signed over total', (t) async {
    await t.pumpWidget(host(const SignerDonut(signed: 2, total: 3, requiredCount: 2)));
    await t.pumpAndSettle();
    expect(find.text('2/3'), findsOneWidget);
    expect(find.text('signed'), findsOneWidget);
  });

  testWidgets('announces the quorum to screen readers', (t) async {
    final handle = t.ensureSemantics();
    await t.pumpWidget(host(const SignerDonut(signed: 1, total: 3, requiredCount: 2)));
    await t.pumpAndSettle();
    expect(
      find.bySemanticsLabel(
          '1 of 3 signers have signed; 2 signatures required'),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('singular quorum wording', (t) async {
    final handle = t.ensureSemantics();
    await t.pumpWidget(host(const SignerDonut(signed: 0, total: 2, requiredCount: 1)));
    await t.pumpAndSettle();
    expect(
      find.bySemanticsLabel('0 of 2 signers have signed; 1 signature required'),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('no threshold: the ring still reports itself', (t) async {
    final handle = t.ensureSemantics();
    await t.pumpWidget(host(const SignerDonut(signed: 1, total: 2)));
    await t.pumpAndSettle();
    expect(find.bySemanticsLabel('1 of 2 signers have signed'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('no signers draws nothing and does not divide by zero', (t) async {
    await t.pumpWidget(host(const SignerDonut(signed: 0, total: 0)));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.text('0/0'), findsNothing);
    expect(find.text('signed'), findsNothing);
  });

  testWidgets('a signature the inspection could not place is clamped', (t) async {
    // sigsPresent can exceed the attributed slots; the ring must not overflow.
    await t.pumpWidget(host(const SignerDonut(signed: 5, total: 2, requiredCount: 2)));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.text('2/2'), findsOneWidget);
  });

  testWidgets('a quorum bigger than the ring paints anyway', (t) async {
    await t.pumpWidget(host(const SignerDonut(signed: 0, total: 2, requiredCount: 9)));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.text('0/2'), findsOneWidget);
  });

  testWidgets('single signer ring paints without a seam', (t) async {
    await t.pumpWidget(host(const SignerDonut(signed: 1, total: 1, requiredCount: 1)));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.text('1/1'), findsOneWidget);
  });

  testWidgets('lands filled under reduced motion, without animating', (t) async {
    await t.pumpWidget(host(
      const SignerDonut(signed: 2, total: 3, requiredCount: 2),
      reduceMotion: true,
    ));
    // No settle: the value must already be final on the first frame.
    await t.pump();
    expect(find.text('2/3'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('dark theme paints', (t) async {
    await t.pumpWidget(host(
      const SignerDonut(signed: 3, total: 3, requiredCount: 2),
      dark: true,
    ));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.text('3/3'), findsOneWidget);
  });

  // ── SignerChart: the donut plus the legend and the quorum line ──────────

  testWidgets('chart legends the slots and states the quorum', (t) async {
    await t.pumpWidget(host(
      const SignerChart(signed: 1, total: 3, requiredCount: 2, collected: 1),
    ));
    await t.pumpAndSettle();
    expect(find.text('1/3'), findsOneWidget);
    expect(find.text('Signed (1)'), findsOneWidget);
    expect(find.text('Not signed (2)'), findsOneWidget);
    expect(
      find.text('3 signers on this transaction · 1 of 2 required '
          'signatures collected'),
      findsOneWidget,
    );
  });

  testWidgets('chart reports the collected count, not the filled slots',
      (t) async {
    // A signature the inspection could not attribute to a named signer: the
    // ring shows the slots it can prove, the line reports what was counted.
    await t.pumpWidget(host(
      const SignerChart(signed: 1, total: 3, requiredCount: 2, collected: 2),
    ));
    await t.pumpAndSettle();
    expect(find.text('1/3'), findsOneWidget);
    expect(find.text('Signed (1)'), findsOneWidget);
    expect(
      find.text('3 signers on this transaction · 2 of 2 required '
          'signatures collected'),
      findsOneWidget,
    );
  });

  testWidgets('a caption replaces the signer wording for a slot ring',
      (t) async {
    // The multisig hand-off sheets draw required-signature slots when the
    // PSBT names no signers — calling those "signers" would be a claim the
    // engine never made.
    await t.pumpWidget(host(const SignerChart(
      signed: 1,
      total: 2,
      requiredCount: 2,
      collected: 1,
      caption: '1 of 2 required signatures collected',
    )));
    await t.pumpAndSettle();
    expect(find.text('1 of 2 required signatures collected'), findsOneWidget);
    expect(find.textContaining('signers on this transaction'), findsNothing);
  });

  testWidgets('chart with no quorum in the policy still counts', (t) async {
    await t.pumpWidget(host(const SignerChart(signed: 1, total: 3)));
    await t.pumpAndSettle();
    expect(
      find.text('3 signers on this transaction · 1 signature collected'),
      findsOneWidget,
    );
  });
}
