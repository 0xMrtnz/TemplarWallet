import 'package:flutter/material.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';

class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
  });

  final String title;
  final String? subtitle;

  /// Right-aligned on the title row. The chain switch goes here on per-chain
  /// screens, as the last item: one row, no leftover space.
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    // A phone gets the same header a size down and a tighter foot: the title
    // is a label there, not the loudest thing on a 379 dp column.
    final phone = AppLayout.isPhone(context);
    final titleBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: AppTypography.pageTitleOf(context)),
        if (subtitle != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: Text(
              subtitle!,
              style: (phone ? AppTypography.bodySmall : AppTypography.body)
                  .copyWith(
                color: Theme.of(context).brightness == Brightness.dark
                    ? const Color(0xFF9CA3AF)
                    : const Color(0xFF6B7280),
              ),
            ),
          ),
      ],
    );
    final actionRow = actions.isEmpty
        ? null
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: actions
                .map((a) => Padding(
                      padding: const EdgeInsets.only(left: AppSpacing.sm),
                      child: a,
                    ))
                .toList(),
          );

    return Padding(
      padding: EdgeInsets.only(bottom: phone ? AppSpacing.lg : AppSpacing.xl),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Phone widths: the chain switch and the other actions would leave
          // the title a few dozen pixels, so they move under it instead.
          // A single small action (the privacy eye, one icon button) stays
          // on the title row even on a phone; only a real toolbar stacks.
          final stacked = actionRow != null &&
              constraints.maxWidth < 520 &&
              actions.length > 1;
          if (stacked) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                titleBlock,
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.md),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: actionRow,
                  ),
                ),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: titleBlock),
              ?actionRow,
            ],
          );
        },
      ),
    );
  }
}
