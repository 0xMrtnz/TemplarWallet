import 'package:flutter/material.dart';

import '../../features/send/models/tx_preview.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import 'hex_text.dart';
import 'hybrid_kit.dart';

/// Everything a transaction does, in one panel: each recipient with its
/// amount (and asset, on Liquid), the change, the fee and the total.
///
/// Shown twice in the send flow — once to confirm before signing, once after
/// the broadcast — so both read exactly the same.
class TxRecapPanel extends StatelessWidget {
  const TxRecapPanel({
    required this.preview,
    required this.ticker,
    super.key,
  });

  final TxPreview preview;

  /// Transaction-level ticker, used when an output carries no asset of its own.
  final String ticker;

  /// Below this body width the address and its amount go on separate lines.
  /// A `first12…last8` HexText next to a `0.00010000 BTC` amount needs about
  /// 270 dp; anything narrower would ellipsise the address tail — the part
  /// the user is asked to check. Desktop dialogs give the body 430+ dp, so
  /// the row layout there is untouched.
  static const double _stackBelow = 360;

  bool get isLiquid => preview.chain == 'liquid';

  String amountOf(TxIo o) {
    if (o.amountDisplay != null) return o.amountDisplay!;
    if (isLiquid) return '${o.amountSats} ${o.ticker ?? ticker}';
    return '${(o.amountSats / 1e8).toStringAsFixed(8)} $ticker';
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final phone = AppLayout.isPhone(context);
    final recipients = preview.outputs.where((o) => !o.isChange).toList();
    final change = preview.outputs.where((o) => o.isChange).toList();

    final amountStyle = AppTypography.monoSmall
        .copyWith(color: s.ink, fontWeight: FontWeight.w600);
    final changeStyle = AppTypography.monoSmall.copyWith(color: s.inkSecondary);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RailPanel(
          title: recipients.length == 1
              ? 'Recipient'
              : 'Recipients (${recipients.length})',
          rail: isLiquid ? s.liquid : s.bitcoin,
          padding: phone
              ? const EdgeInsets.all(AppSpacing.cardPaddingSmall)
              : null,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final stacked = phone || constraints.maxWidth < _stackBelow;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < recipients.length; i++) ...[
                    if (i > 0) const SizedBox(height: AppSpacing.sm),
                    if (stacked)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          HexText(recipients[i].address, truncate: true),
                          const SizedBox(height: 2),
                          Text(amountOf(recipients[i]),
                              style: amountStyle,
                              textAlign: TextAlign.right),
                        ],
                      )
                    else
                      Row(
                        children: [
                          Expanded(
                              child: HexText(recipients[i].address,
                                  truncate: true)),
                          const SizedBox(width: AppSpacing.md),
                          Text(amountOf(recipients[i]), style: amountStyle),
                        ],
                      ),
                  ],
                  for (final c in change) ...[
                    const SizedBox(height: AppSpacing.sm),
                    if (stacked)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              TagChip(label: 'CHANGE', color: s.inkSecondary),
                              const Spacer(),
                              Text(amountOf(c), style: changeStyle),
                            ],
                          ),
                          const SizedBox(height: 2),
                          HexText(c.address, truncate: true),
                        ],
                      )
                    else
                      Row(
                        children: [
                          TagChip(label: 'CHANGE', color: s.inkSecondary),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(child: HexText(c.address, truncate: true)),
                          Text(amountOf(c), style: changeStyle),
                        ],
                      ),
                  ],
                ],
              );
            },
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        DataWell(
          child: Column(
            children: [
              TxKvLine(label: 'Fee', value: preview.feeDisplay),
              const SizedBox(height: AppSpacing.xs),
              TxKvLine(label: 'Total spend', value: preview.totalDisplay),
            ],
          ),
        ),
      ],
    );
  }
}

/// Right-aligned label/value line used inside the recap.
class TxKvLine extends StatelessWidget {
  const TxKvLine({required this.label, required this.value, super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final valueStyle = AppTypography.monoSmall
        .copyWith(color: s.ink, fontWeight: FontWeight.w600);
    final labelStyle = AppTypography.caption.copyWith(color: s.inkFaint);
    final phone = AppLayout.isPhone(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // Same rule as the recipient rows: on a phone, or in a body narrower
        // than a desktop dialog gives, the value wraps (never overflows)
        // when a Liquid amount with a long ticker does not fit. Desktop
        // dialogs are wider than the threshold, so their row is unchanged.
        if (phone || constraints.maxWidth < TxRecapPanel._stackBelow) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: labelStyle),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(value,
                    textAlign: TextAlign.right, style: valueStyle),
              ),
            ],
          );
        }
        return Row(
          children: [
            Text(label, style: labelStyle),
            const Spacer(),
            Text(value, style: valueStyle),
          ],
        );
      },
    );
  }
}
