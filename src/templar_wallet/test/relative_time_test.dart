// The one-line age that rides inside an activity subtitle.

import 'package:flutter_test/flutter_test.dart';
import 'package:templar_wallet/shared/relative_time.dart';

void main() {
  final now = DateTime(2026, 9, 6, 12, 0);

  test('under a minute is "just now"', () {
    expect(relativeTimeShort(now.subtract(const Duration(seconds: 5)), now: now),
        'just now');
    expect(relativeTimeShort(now.subtract(const Duration(seconds: 59)), now: now),
        'just now');
  });

  test('minutes, then hours, then days', () {
    expect(relativeTimeShort(now.subtract(const Duration(minutes: 12)), now: now),
        '12 min ago');
    expect(relativeTimeShort(now.subtract(const Duration(hours: 2)), now: now),
        '2h ago');
    expect(relativeTimeShort(now.subtract(const Duration(days: 3)), now: now),
        '3d ago');
  });

  test('a week out becomes a date, a year out gains the year', () {
    expect(relativeTimeShort(DateTime(2026, 8, 20), now: now), '20 Aug');
    expect(relativeTimeShort(DateTime(2024, 1, 9), now: now), '9 Jan 2024');
  });

  test('a timestamp from the future reads as now, never as a negative age', () {
    expect(relativeTimeShort(now.add(const Duration(minutes: 3)), now: now),
        'just now');
  });
}
