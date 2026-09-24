import 'package:flutter_test/flutter_test.dart';
import 'package:templar_wallet/services/auto_lock.dart';

void main() {
  final t0 = DateTime(2026, 9, 14, 12);

  test('locks once the chosen time away has passed', () {
    expect(AutoLockPolicy.due(since: t0, now: t0.add(const Duration(seconds: 59)), seconds: 60), isFalse);
    expect(AutoLockPolicy.due(since: t0, now: t0.add(const Duration(seconds: 60)), seconds: 60), isTrue);
  });

  test('"Immediately" locks on any return, "Never" never does', () {
    expect(AutoLockPolicy.due(since: t0, now: t0, seconds: 0), isTrue);
    expect(
      AutoLockPolicy.due(since: t0, now: t0.add(const Duration(days: 30)), seconds: AutoLockPolicy.never),
      isFalse,
    );
  });

  test('every offered choice has a label', () {
    expect(AutoLockPolicy.choices.map(AutoLockPolicy.label), [
      'Immediately',
      'After 1 minute',
      'After 5 minutes',
      'After 15 minutes',
      'Never',
    ]);
  });
}
