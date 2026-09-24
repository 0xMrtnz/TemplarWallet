import 'package:flutter/material.dart';

import 'ur_qr.dart';

/// Camera-scan icon for any text field that takes an address, xpub, or
/// descriptor. Opens the shared UR/plain-QR scanner and writes the decoded
/// payload into [controller]. One widget, used next to every such field so
/// the whole app scans the same way.
class ScanIconButton extends StatelessWidget {
  const ScanIconButton({
    required this.controller,
    this.title,
    this.tooltip = 'Scan QR',
    this.onScanned,
    this.expectsKey = false,
    super.key,
  });

  final TextEditingController controller;

  /// Scanner dialog title, e.g. "Scan recipient address".
  final String? title;
  final String tooltip;

  /// Called after the controller has been filled (host usually setState()s).
  final void Function(String value)? onScanned;

  /// This field holds a single account key, not a whole descriptor — a
  /// multisig cosigner slot. An air-gapped device's `ur:crypto-account` QR
  /// decodes to both forms; the field gets `[fingerprint/path]tpub…`, because
  /// the descriptor form nests inside the wallet's own and cannot be opened.
  final bool expectsKey;

  @override
  Widget build(BuildContext context) {
    // No camera plugin on this desktop: render nothing rather than a button
    // that can only open an apology. Every field that hosts this widget also
    // has a Paste control right beside it, so the flow stays complete.
    if (!cameraScanSupported) return const SizedBox.shrink();
    return IconButton(
      tooltip: tooltip,
      icon: const Icon(Icons.qr_code_scanner),
      onPressed: () async {
        final outcome = await showUrScannerDialog(
          context,
          expectPsbt: false,
          title: title,
        );
        // Plain-text QRs (addresses, xpubs) come back as `descriptor`;
        // a BC-UR wallet export also lands there.
        final value = (expectsKey ? outcome?.keyorigin : null) ??
            outcome?.descriptor ??
            outcome?.psbtBase64;
        if (value == null || value.isEmpty) return;
        controller.text = value.trim();
        onScanned?.call(controller.text);
      },
    );
  }
}
