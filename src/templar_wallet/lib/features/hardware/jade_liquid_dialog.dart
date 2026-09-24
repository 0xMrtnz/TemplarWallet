// Create a Liquid-only wallet from a connected Blockstream Jade.
//
// This flow never touches HWI — it talks to the Jade over USB serial from
// inside the app — so it is the one hardware setup that works on every
// platform, macOS sandbox included.

import 'package:flutter/material.dart';

import '../../bridge/bridge_provider.dart';
import '../../shared/widgets/banners.dart';
import '../../shared/widgets/buttons.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import '../wallet_picker/models/wallet_summary.dart';
import 'hw_error.dart';

/// Returns the created wallet, or null if the user backed out.
Future<WalletSummary?> showJadeLiquidSetupDialog(BuildContext context) {
  return showDialog<WalletSummary>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _JadeLiquidDialog(),
  );
}

class _JadeLiquidDialog extends StatefulWidget {
  const _JadeLiquidDialog();

  @override
  State<_JadeLiquidDialog> createState() => _JadeLiquidDialogState();
}

class _JadeLiquidDialogState extends State<_JadeLiquidDialog> {
  final _name = TextEditingController(text: 'Jade Liquid');
  bool _busy = false;
  String? _error;

  /// Null while probing. Empty means no Jade-capable serial port is present.
  List<String>? _ports;

  @override
  void initState() {
    super.initState();
    _probe();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _probe() async {
    try {
      final ports = await walletBridge.jadePorts();
      if (mounted) setState(() => _ports = ports);
    } catch (_) {
      if (mounted) setState(() => _ports = const []);
    }
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Give the wallet a name.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final wallet = await walletBridge.importJadeLiquidWallet(name);
      if (mounted) Navigator.of(context).pop(wallet);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = friendlyHwError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ports = _ports;
    final found = ports != null && ports.isNotEmpty;

    return AlertDialog(
      title: const Text('Liquid wallet on your Jade'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'The wallet\'s confidential descriptor is read from the Jade '
              'itself, so the device can spend from it. Connect the Jade over '
              'USB, unlock it with your PIN, and close Blockstream Green — '
              'only one app can hold the serial port at a time.',
              style: AppTypography.bodySmall,
            ),
            const SizedBox(height: AppSpacing.lg),
            if (ports == null)
              Row(
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Text('Looking for a Jade…', style: AppTypography.caption),
                ],
              )
            else if (found)
              Row(
                children: [
                  const Icon(Icons.check_circle_outline,
                      size: 16, color: AppColors.success),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text('Found on ${ports.first}',
                        style: AppTypography.monoSmall,
                        overflow: TextOverflow.ellipsis),
                  ),
                ],
              )
            else
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'No Jade detected on a serial port yet — you can still '
                      'continue; it will be checked again when you create.',
                      style: AppTypography.caption,
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      setState(() => _ports = null);
                      _probe();
                    },
                    child: const Text('Rescan'),
                  ),
                ],
              ),
            const SizedBox(height: AppSpacing.lg),
            TextField(
              controller: _name,
              enabled: !_busy,
              decoration: const InputDecoration(labelText: 'Wallet name'),
            ),
            if (_busy) ...[
              const SizedBox(height: AppSpacing.lg),
              const LinearProgressIndicator(),
              const SizedBox(height: AppSpacing.sm),
              Text('Unlock the Jade and confirm on its screen…',
                  style: AppTypography.caption),
            ],
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.lg),
              WarningBanner(title: 'Could not set up', message: _error!),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        PrimaryButton(
          label: _busy ? 'Connecting…' : 'Connect Jade',
          icon: Icons.usb_rounded,
          onPressed: _busy ? null : _create,
        ),
      ],
    );
  }
}
