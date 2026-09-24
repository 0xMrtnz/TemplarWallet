import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_state.dart';
import '../../features/send/models/tx_preview.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import 'buttons.dart';
import 'code_box.dart';
import 'glass_dialog.dart';
import 'hybrid_kit.dart';
import 'tx_recap.dart';

/// Post-broadcast confirmation: instead of a bare txid, recap everything
/// that was just signed and sent — every recipient with its amount (and
/// asset, on Liquid), the fee, the total, and the txid with copy + explorer.
/// Shared by the software, hardware, and air-gap send paths.
Future<void> showTxSuccessDialog(
  BuildContext context, {
  required String txid,
  required TxPreview preview,
  required String ticker,
}) {
  // Dialog on desktop, bottom sheet on a phone. Not dismissible from
  // outside: the txid is the one thing the user must not lose by accident.
  return showAppDialog<void>(
    context,
    barrierDismissible: false,
    builder: (_) => _TxSuccessDialog(txid: txid, preview: preview, ticker: ticker),
  );
}

class _TxSuccessDialog extends StatelessWidget {
  const _TxSuccessDialog({
    required this.txid,
    required this.preview,
    required this.ticker,
  });

  final String txid;
  final TxPreview preview;
  final String ticker;

  bool get _isLiquid => preview.chain == 'liquid';

  Future<void> _openExplorer(BuildContext context) async {
    final app = context.read<AppState>();
    final base = _isLiquid ? app.liquidExplorerUrl : app.btcExplorerUrl;
    final trimmed = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final uri = Uri.parse('$trimmed/tx/$txid');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final phone = AppLayout.isPhone(context);
    final badge = phone ? 56.0 : 64.0;

    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Pop(
          child: Center(
            child: Container(
              width: badge,
              height: badge,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: s.success,
                boxShadow: [
                  BoxShadow(
                    color: s.success.withValues(alpha: 0.3),
                    blurRadius: 22,
                  ),
                ],
              ),
              child: Icon(Icons.check_rounded,
                  color: Colors.white, size: phone ? 30 : 34),
            ),
          ),
        ),
        SizedBox(height: phone ? AppSpacing.md : AppSpacing.lg),
        Reveal(
          delay: 1,
          child: Text(
            'Transaction sent',
            textAlign: TextAlign.center,
            style: AppTypography.pageTitleOf(context),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Reveal(
          delay: 2,
          child: Text(
            'Broadcast to the ${_isLiquid ? 'Liquid' : 'Bitcoin'} testnet.',
            textAlign: TextAlign.center,
            style: AppTypography.bodySmall.copyWith(color: s.inkSecondary),
          ),
        ),
        SizedBox(height: phone ? AppSpacing.lg : AppSpacing.xl),
        Reveal(
          delay: 3,
          child: TxRecapPanel(preview: preview, ticker: ticker),
        ),
        const SizedBox(height: AppSpacing.md),
        Reveal(
          delay: 5,
          child: CodeBox(value: txid, label: 'TxID'),
        ),
      ],
    );

    final actions = phone
        ? <Widget>[
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                PrimaryButton(
                  label: 'Done',
                  isFullWidth: true,
                  onPressed: () => Navigator.of(context).pop(),
                ),
                const SizedBox(height: AppSpacing.sm),
                SecondaryButton(
                  label: 'View on explorer',
                  icon: Icons.open_in_new_rounded,
                  isFullWidth: true,
                  onPressed: () => _openExplorer(context),
                ),
              ],
            ),
          ]
        : <Widget>[
            SecondaryButton(
              label: 'View on explorer',
              icon: Icons.open_in_new_rounded,
              onPressed: () => _openExplorer(context),
            ),
            PrimaryButton(
              label: 'Done',
              onPressed: () => Navigator.of(context).pop(),
            ),
          ];

    return AppDialog(
      // The sheet scrolls its own content; the desktop dialog needs a width
      // and a scroll view of its own.
      content: phone
          ? body
          : SizedBox(
              width: 520,
              child: SingleChildScrollView(child: body),
            ),
      actions: actions,
    );
  }
}
