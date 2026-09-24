// Co-signing with a USB hardware wallet, from a hand-off sheet.
//
// Two dialogs in a row, each with one job. The connect gate finds the device
// and, because the next step is an approval on the device's own screen,
// waits for the user to press "Sign on device" rather than closing on its
// own the moment something is plugged in. The signing dialog then runs the
// device round-trip and hands the signed transaction back — the sheet that
// called takes it in exactly as it takes a pasted copy, so the quorum chart
// moves the same way for a device as for a co-signer across the room.

import 'package:flutter/material.dart';

import '../create_wallet/models/hw_device.dart';
import 'hw_error.dart';
import 'ledger_connect_dialog.dart';
import 'ledger_signing_dialog.dart';

/// Connect a device, then sign with it. Returns the signed transaction
/// (base64 PSBT or PSET), or null when the user backed out of either step;
/// a device failure is shown in the signing dialog with Retry, and comes back
/// as null only once the user gives up on it.
///
/// [expectedFingerprints] restricts the gate to the wallet's own hardware
/// keys — any of them; null accepts whatever device answers. [sign] is given
/// the connected device and does the chain-specific call.
Future<String?> runUsbCosign(
  BuildContext context, {
  required Set<String>? expectedFingerprints,
  required Future<String> Function(HwDevice device) sign,
  String title = 'Connect your hardware wallet',
}) async {
  final device = await showHwDevicePickerDialog(
    context,
    expectedFingerprints:
        (expectedFingerprints?.isEmpty ?? true) ? null : expectedFingerprints,
    title: title,
    confirmLabel: 'Sign on device',
  );
  if (device == null || !context.mounted) return null;
  return showLedgerSigningDialog(
    context,
    task: () => sign(device),
    signOnly: true,
    formatError: (raw) => friendlyHwError(raw),
  );
}
