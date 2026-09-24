import 'package:flutter/material.dart';

import '../../features/send/models/tx_preview.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import 'buttons.dart';
import 'glass_dialog.dart';
import 'hybrid_kit.dart';
import 'tx_recap.dart';

/// Last stop before anything is signed: a full summary of the transaction —
/// every recipient, the change, the fee, the total, and how it will be signed.
///
/// Returns true when the user confirms. The caller then runs its signing path
/// (software key, hardware device, or air-gap QR) and shows the success recap.
Future<bool> showTxConfirmDialog(
  BuildContext context, {
  required TxPreview preview,
  required String ticker,
  required String signLabel,
  required String signHint,
}) async {
  // Dialog on desktop, bottom sheet on a phone; neither dismisses on an
  // outside tap — leaving a confirmation is an explicit Back.
  final ok = await showAppDialog<bool>(
    context,
    barrierDismissible: false,
    builder: (_) => _TxConfirmDialog(
      preview: preview,
      ticker: ticker,
      signLabel: signLabel,
      signHint: signHint,
    ),
  );
  return ok ?? false;
}

class _TxConfirmDialog extends StatelessWidget {
  const _TxConfirmDialog({
    required this.preview,
    required this.ticker,
    required this.signLabel,
    required this.signHint,
  });

  final TxPreview preview;
  final String ticker;

  /// Primary button text — differs per signing path ("Sign & send",
  /// "Sign on device", "Export PSBT").
  final String signLabel;

  /// One line telling the user what happens when they confirm.
  final String signHint;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final isLiquid = preview.chain == 'liquid';
    final phone = AppLayout.isPhone(context);
    final badge = phone ? 48.0 : 56.0;

    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            width: badge,
            height: badge,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: s.accentSoft,
              border: Border.all(color: s.accent, width: 1.5),
            ),
            child: Icon(Icons.fact_check_outlined,
                color: s.accent, size: phone ? 24 : 28),
          ),
        ),
        SizedBox(height: phone ? AppSpacing.md : AppSpacing.lg),
        Text(
          'Confirm this transaction',
          textAlign: TextAlign.center,
          style: AppTypography.pageTitleOf(context),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'Nothing has been signed yet. Check every line — a sent '
          'transaction cannot be recalled.',
          textAlign: TextAlign.center,
          style: AppTypography.bodySmall.copyWith(color: s.inkSecondary),
        ),
        SizedBox(height: phone ? AppSpacing.lg : AppSpacing.xl),
        TxRecapPanel(preview: preview, ticker: ticker),
        const SizedBox(height: AppSpacing.md),
        Row(
          // The hint wraps to two or three lines in the narrow column; keep
          // the chip on the first of them.
          crossAxisAlignment:
              phone ? CrossAxisAlignment.start : CrossAxisAlignment.center,
          children: [
            TagChip(
              label: isLiquid ? 'LIQUID TESTNET' : 'BITCOIN TESTNET',
              color: isLiquid ? s.liquid : s.bitcoin,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                signHint,
                style: AppTypography.caption.copyWith(color: s.inkSecondary),
              ),
            ),
          ],
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
                  label: signLabel,
                  icon: Icons.check_rounded,
                  isFullWidth: true,
                  onPressed: () => Navigator.of(context).pop(true),
                ),
                const SizedBox(height: AppSpacing.sm),
                SecondaryButton(
                  label: 'Back',
                  isFullWidth: true,
                  onPressed: () => Navigator.of(context).pop(false),
                ),
              ],
            ),
          ]
        : <Widget>[
            GhostButton(
              label: 'Back',
              onPressed: () => Navigator.of(context).pop(false),
            ),
            PrimaryButton(
              label: signLabel,
              icon: Icons.check_rounded,
              onPressed: () => Navigator.of(context).pop(true),
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
