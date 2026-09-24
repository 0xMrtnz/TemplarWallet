// Dart side of the hardware-wallet FFI seam.
//
// The Rust counterpart lives in `src/wallet-ffi/src/contract_tests.rs`
// (`hwi_status_matches_dart_decode_shape`) and asserts the keys this file
// decodes. Together they pin both ends of the boundary: a rename on either
// side fails a test instead of silently disabling a remedy in the UI.

import 'package:flutter_test/flutter_test.dart';
import 'package:templar_wallet/bridge/wallet_bridge.dart';
import 'package:templar_wallet/features/create_wallet/models/native_device.dart';
import 'package:templar_wallet/features/hardware/hw_error.dart';

void main() {
  group('NativeDevice', () {
    test('decodes the backend shape', () {
      final d = NativeDevice.fromJson(const {
        'family': 'ledger',
        'model': 'Nano S Plus',
        'transport': 'hid',
        'path': 'DevSrvsID:4295091200',
        'vendor_id': 0x2c97,
        'product_id': 0x5011,
        'serial_number': null,
      });
      expect(d.family, 'ledger');
      expect(d.transport, 'hid');
      expect(d.serialNumber, isNull);
    });

    // The form users see in system USB listings and paste into bug reports;
    // it has to stay zero-padded lowercase hex to be greppable.
    test('formats the USB id the way the OS does', () {
      const ledger = NativeDevice(
        family: 'ledger',
        model: 'Nano S Plus',
        transport: 'hid',
        path: '',
        vendorId: 0x2c97,
        productId: 0x5011,
      );
      expect(ledger.usbId, '2c97:5011');

      const jade = NativeDevice(
        family: 'jade',
        model: 'Jade',
        transport: 'serial',
        path: '/dev/cu.usbserial-10',
        vendorId: 0x10c4,
        productId: 0x00ea,
      );
      expect(jade.usbId, '10c4:00ea', reason: 'must zero-pad to four digits');
    });
  });

  group('HwiStatus.fromJson', () {
    test('decodes a fully populated status', () {
      final s = HwiStatus.fromJson(const {
        'resolved_bin': '/data/hwi/hwi',
        'version': '3.2.0',
        'platform': 'linux',
        'udev_rules_installed': true,
        'liquid_hw_signing': false,
      });
      expect(s.installed, isTrue);
      expect(s.version, '3.2.0');
      expect(s.platform, 'linux');
      expect(s.needsUdevRules, isFalse);
      expect(s.liquidHwSigning, isFalse);
    });

    test('no binary means "show the install card"', () {
      final s = HwiStatus.fromJson(const {
        'resolved_bin': null,
        'version': null,
        'platform': 'windows',
        'udev_rules_installed': null,
      });
      expect(s.installed, isFalse);
      // Not Linux: udev is not a concept, so the fix must not be offered.
      expect(s.needsUdevRules, isFalse);
    });

    test('an empty resolved_bin counts as not installed', () {
      final s = HwiStatus.fromJson(const {'resolved_bin': ''});
      expect(s.installed, isFalse);
    });

    // The distinction that matters: "rules are missing" (offer the fix) versus
    // "udev does not apply here" (say nothing). Collapsing null into false
    // would nag every macOS and Windows user.
    test('only a positive false triggers the udev remedy', () {
      expect(
        HwiStatus.fromJson(const {'udev_rules_installed': false}).needsUdevRules,
        isTrue,
      );
      expect(
        HwiStatus.fromJson(const {'udev_rules_installed': null}).needsUdevRules,
        isFalse,
      );
      expect(HwiStatus.fromJson(const {}).needsUdevRules, isFalse);
    });
  });

  group('classifyHwError', () {
    test('recognises every tag the backend emits, through the FFI wrapper', () {
      final cases = <String, HwErrorKind>{
        'HWI_MISSING: not installed': HwErrorKind.hwiMissing,
        'HWI_PERMISSION: udev rules missing': HwErrorKind.permission,
        'DEVICE_NOT_READY: device is locked': HwErrorKind.deviceNotReady,
        'DEVICE_NOT_FOUND: reconnect and try again': HwErrorKind.deviceNotFound,
        'SIGNING_FAILED: the device did not sign': HwErrorKind.signingRefused,
        'LIQUID_HW_UNSUPPORTED: watch-only': HwErrorKind.liquidUnsupported,
      };
      cases.forEach((raw, kind) {
        expect(classifyHwError('Exception: wallet-ffi: $raw').kind, kind,
            reason: raw);
      });
    });

    test('strips the tag and the FFI wrapper from the displayed message', () {
      final f = classifyHwError(
          'Exception: wallet-ffi: DEVICE_NOT_READY: Open the Bitcoin app');
      expect(f.message, 'Open the Bitcoin app');
      expect(f.message, isNot(contains('DEVICE_NOT_READY')));
      expect(f.message, isNot(contains('wallet-ffi')));
    });

    test('a missing toolkit routes to the in-app installer', () {
      expect(classifyHwError('HWI_MISSING: gone').remedy, HwRemedy.installHwi);
      // Untagged form from an older backend must still reach the installer —
      // otherwise a fixable state reads as a dead end.
      expect(
        classifyHwError('Exception: Could not run hwi (/x/hwi): No such file')
            .remedy,
        HwRemedy.installHwi,
      );
    });

    test('unknown errors are passed through verbatim, not swallowed', () {
      final f = classifyHwError('Exception: wallet-ffi: something odd happened');
      expect(f.kind, HwErrorKind.unknown);
      expect(f.message, 'something odd happened');
      expect(f.remedy, HwRemedy.none);
    });

    test('a Liquid refusal offers no remedy — retrying cannot help', () {
      final f = classifyHwError('LIQUID_HW_UNSUPPORTED: watch-only only');
      expect(f.remedy, HwRemedy.none);
    });

    test('every kind has a non-empty title', () {
      for (final kind in HwErrorKind.values) {
        expect(hwErrorTitle(kind), isNotEmpty, reason: '$kind');
      }
    });
  });
}
