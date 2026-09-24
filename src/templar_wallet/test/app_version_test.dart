// About's version string is a constant; this keeps it equal to pubspec.yaml,
// which is what every build and release artifact is named after.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:templar_wallet/app/app_version.dart';

void main() {
  test('kAppVersion matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final line = RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(pubspec);
    expect(line, isNotNull, reason: 'pubspec.yaml has no version line');
    final version = line!.group(1)!.split('+').first;
    expect(kAppVersion, version);
  });
}
