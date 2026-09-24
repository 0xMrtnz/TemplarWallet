// Linux-only: install the udev rules a hardware wallet needs before a
// non-root process can talk to it.
//
// Without them `hwi enumerate` comes back empty or permission-denied, which
// reads to the user as "my device is broken". HWI 3.x removed its
// `installudevrules` subcommand, so the rules are bundled as assets (see
// assets/udev/README.md) and installed here via a single pkexec call.
//
// Everything is explicit: nothing runs unless the user presses the button,
// and the privileged step is one `sh -c` with a fixed script the user's
// polkit agent shows before authorising.

import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

/// The bundled rules, in load order. Must match the probe list in
/// `src/wallet-ffi/src/handlers/hw.rs`.
const kUdevRuleFiles = <String>[
  '20-hw1.rules', // Ledger
  '51-coinkite.rules', // Coldcard
  '51-hid-digitalbitbox.rules',
  '51-trezor.rules',
  '51-usb-keepkey.rules',
  '52-hid-digitalbitbox.rules',
  '53-hid-bitbox02.rules',
  '54-hid-bitbox02.rules',
  '55-usb-jade.rules', // Blockstream Jade (serial)
];

const _rulesDir = '/etc/udev/rules.d';

class UdevInstallResult {
  const UdevInstallResult({required this.ok, required this.message});
  final bool ok;
  final String message;
}

class UdevInstaller {
  /// Whether this platform has udev at all.
  static bool get supported => Platform.isLinux;

  /// True when a privileged helper is available, i.e. the one-click install
  /// can work. Without it we fall back to printing manual commands.
  static Future<bool> hasPkexec() async {
    if (!supported) return false;
    try {
      final r = await Process.run('which', ['pkexec']);
      return r.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  /// Copy the bundled rules to a user-writable staging directory and return
  /// its path. Split out from [install] so the manual instructions can point
  /// at real files the user already has on disk.
  static Future<Directory> stageRules() async {
    final dir = await Directory.systemTemp.createTemp('templar-udev-');
    for (final name in kUdevRuleFiles) {
      final data = await rootBundle.loadString('assets/udev/$name');
      await File('${dir.path}/$name').writeAsString(data, flush: true);
    }
    return dir;
  }

  /// The exact shell commands the privileged step runs — shown to the user
  /// before they authenticate, and reused verbatim as the manual fallback so
  /// the two paths can never drift apart.
  static String manualCommands(String stagedDir) => '''
sudo cp $stagedDir/*.rules $_rulesDir/
sudo groupadd -f plugdev
sudo usermod -aG plugdev "\$USER"
sudo udevadm control --reload-rules
sudo udevadm trigger''';

  /// Install the rules with one authentication prompt. Returns a result rather
  /// than throwing: every failure here is something the user can read and act
  /// on, and a thrown exception would lose the staged-directory path they need
  /// for the manual route.
  static Future<UdevInstallResult> install() async {
    if (!supported) {
      return const UdevInstallResult(
        ok: false,
        message: 'udev rules only apply to Linux.',
      );
    }

    final Directory staged;
    try {
      staged = await stageRules();
    } catch (e) {
      return UdevInstallResult(
        ok: false,
        message: 'Could not unpack the bundled rules: $e',
      );
    }

    if (!await hasPkexec()) {
      return UdevInstallResult(
        ok: false,
        message: 'No pkexec on this system, so the rules cannot be installed '
            'automatically. Run these commands in a terminal:\n\n'
            '${manualCommands(staged.path)}\n\n'
            'Then log out and back in (group change) and replug the device.',
      );
    }

    // One privileged call does the whole job. `groupadd -f` is a no-op when the
    // group exists; adding the user to plugdev is what the GROUP="plugdev"
    // lines in the rules require, and it only takes effect on next login —
    // which is why the success message says so.
    final script = 'set -e; '
        'cp "${staged.path}"/*.rules $_rulesDir/; '
        'chmod 0644 $_rulesDir/*.rules; '
        'groupadd -f plugdev; '
        'usermod -aG plugdev "\${PKEXEC_UID:+\$(id -nu \$PKEXEC_UID)}"; '
        'udevadm control --reload-rules; '
        'udevadm trigger';

    try {
      final r = await Process.run('pkexec', ['sh', '-c', script]);
      if (r.exitCode == 0) {
        return const UdevInstallResult(
          ok: true,
          message: 'Rules installed. Unplug and replug the device. If it still '
              'is not detected, log out and back in — the plugdev group only '
              'applies to new sessions.',
        );
      }
      // 126/127 are polkit's "authentication failed / dismissed" codes.
      if (r.exitCode == 126 || r.exitCode == 127) {
        return UdevInstallResult(
          ok: false,
          message: 'Authentication was cancelled, so nothing was changed. '
              'You can also run:\n\n${manualCommands(staged.path)}',
        );
      }
      final err = (r.stderr as String).trim();
      return UdevInstallResult(
        ok: false,
        message: 'Install failed (exit ${r.exitCode}).'
            '${err.isEmpty ? '' : '\n$err'}'
            '\n\nManual alternative:\n\n${manualCommands(staged.path)}',
      );
    } on ProcessException catch (e) {
      return UdevInstallResult(
        ok: false,
        message: 'Could not launch pkexec: ${e.message}\n\n'
            'Manual alternative:\n\n${manualCommands(staged.path)}',
      );
    }
  }
}
