import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:templar_wallet/features/protocol/protocol_confirm_gate.dart';

void main() {
  setUpAll(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  Widget host(Widget child) => MaterialApp(
        home: Scaffold(body: SizedBox(width: 600, child: child)),
      );

  testWidgets('signing button stays disabled until the statement is ticked',
      (tester) async {
    var confirmed = 0;
    await tester.pumpWidget(host(ProtocolConfirmGate(
      statement: 'I compared both views',
      buttonLabel: 'Sign and send',
      onConfirm: () => confirmed++,
    )));

    // Pressing the button before ticking does nothing.
    await tester.tap(find.byKey(const Key('protocol-confirm-button')));
    await tester.pump();
    expect(confirmed, 0);

    await tester.tap(find.byKey(const Key('protocol-confirm-checkbox')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('protocol-confirm-button')));
    await tester.pump();
    expect(confirmed, 1);

    // Unticking disables it again.
    await tester.tap(find.byKey(const Key('protocol-confirm-checkbox')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('protocol-confirm-button')));
    await tester.pump();
    expect(confirmed, 1);
  });

  testWidgets('a disabled gate never confirms', (tester) async {
    var confirmed = 0;
    await tester.pumpWidget(host(ProtocolConfirmGate(
      statement: 'Nothing to sign',
      buttonLabel: 'Sign and send',
      enabled: false,
      onConfirm: () => confirmed++,
    )));
    await tester.tap(find.byKey(const Key('protocol-confirm-checkbox')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('protocol-confirm-button')));
    await tester.pump();
    expect(confirmed, 0);
  });

  testWidgets('busy freezes the gate', (tester) async {
    var confirmed = 0;
    await tester.pumpWidget(host(ProtocolConfirmGate(
      statement: 'I compared both views',
      buttonLabel: 'Sign and send',
      busy: true,
      onConfirm: () => confirmed++,
    )));
    await tester.tap(find.byKey(const Key('protocol-confirm-checkbox')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('protocol-confirm-button')));
    await tester.pump();
    expect(confirmed, 0);
  });
}
