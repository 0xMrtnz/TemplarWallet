import 'package:flutter/material.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';

/// Card inset for the window at hand: the desktop 20 dp, or the tighter
/// 14 dp on a phone where every card spends its width on padding twice.
double _cardPad(BuildContext context) => AppLayout.isPhone(context)
    ? AppSpacing.cardPaddingSmall
    : AppSpacing.cardPadding;

/// Card corner for the window at hand: the desktop 10, or the softer 14 on a
/// phone, where the cards sit beside 16-radius filled controls.
double _cardRadius(BuildContext context) =>
    AppLayout.isPhone(context) ? AppSpacing.radiusLg : AppSpacing.radiusMd;

/// Gap between a card's title block and its divider.
double _headerGap(BuildContext context) =>
    AppLayout.isPhone(context) ? AppSpacing.md : AppSpacing.lg;

class FormCard extends StatelessWidget {
  const FormCard({
    super.key,
    required this.child,
    this.title,
    this.subtitle,
    this.padding,
    this.trailing,
  });

  final Widget child;
  final String? title;
  final String? subtitle;
  final EdgeInsetsGeometry? padding;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final pad = _cardPad(context);
    return Container(
      decoration: BoxDecoration(
        color: s.surfaceGlass,
        borderRadius: BorderRadius.circular(_cardRadius(context)),
        border: Border.all(color: s.edge),
        boxShadow: s.panelShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null)
            Padding(
              padding: EdgeInsets.fromLTRB(pad, pad, pad, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title!,
                            style: AppTypography.sectionTitleOf(context)
                                .copyWith(color: s.ink)),
                        if (subtitle != null)
                          Padding(
                            padding: const EdgeInsets.only(top: AppSpacing.xs),
                            child: Text(
                              subtitle!,
                              style: AppTypography.caption
                                  .copyWith(color: s.inkSecondary),
                            ),
                          ),
                      ],
                    ),
                  ),
                  ?trailing,
                ],
              ),
            ),
          if (title != null)
            Padding(
              padding: EdgeInsets.only(top: _headerGap(context)),
              child: Divider(height: 1, color: s.edge),
            ),
          Padding(
            padding: padding ?? EdgeInsets.all(pad),
            child: child,
          ),
        ],
      ),
    );
  }
}

class SummaryCard extends StatelessWidget {
  const SummaryCard({
    super.key,
    required this.rows,
    this.title,
  });

  final List<({String label, String value, bool isMono})> rows;
  final String? title;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final phone = AppLayout.isPhone(context);
    final pad = _cardPad(context);
    return Container(
      decoration: BoxDecoration(
        color: s.surfaceGlass,
        borderRadius: BorderRadius.circular(_cardRadius(context)),
        border: Border.all(color: s.edge),
        boxShadow: s.panelShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null)
            Padding(
              padding: EdgeInsets.fromLTRB(pad, pad, pad, 0),
              child: Text(title!,
                  style: AppTypography.sectionTitleOf(context)
                      .copyWith(color: s.ink)),
            ),
          ...rows.asMap().entries.map((entry) {
            final isLast = entry.key == rows.length - 1;
            final row = entry.value;
            final labelText = Text(
              row.label,
              style: AppTypography.bodySmall.copyWith(color: s.inkSecondary),
            );
            final valueStyle =
                (row.isMono ? AppTypography.monoSmall : AppTypography.numericSmall)
                    .copyWith(color: s.ink);

            final Widget body;
            if (phone && row.isMono && row.value.length > 24) {
              // A txid / address / descriptor right-aligned beside a label
              // wraps into a ragged column; stacked it reads as one block.
              body = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  labelText,
                  const SizedBox(height: 2),
                  SelectableText(row.value, style: valueStyle),
                ],
              );
            } else if (phone) {
              body = Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: labelText),
                  const SizedBox(width: AppSpacing.sm),
                  Flexible(
                    flex: 2,
                    child: Text(
                      row.value,
                      style: valueStyle,
                      textAlign: TextAlign.end,
                    ),
                  ),
                ],
              );
            } else {
              body = Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 160, child: labelText),
                  Expanded(
                    child: Text(
                      row.value,
                      style: valueStyle,
                      textAlign: TextAlign.end,
                    ),
                  ),
                ],
              );
            }

            return Column(
              children: [
                if (entry.key == 0 && title != null)
                  Divider(height: _headerGap(context), color: s.edge),
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: pad,
                    vertical: phone ? AppSpacing.sm + 2 : AppSpacing.md,
                  ),
                  child: body,
                ),
                if (!isLast) Divider(height: 1, color: s.edge),
              ],
            );
          }),
        ],
      ),
    );
  }
}

class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.child,
    this.title,
    this.subtitle,
    this.action,
    this.padding,
    this.color,
  });

  final Widget child;
  final String? title;
  final String? subtitle;
  final Widget? action;
  final EdgeInsetsGeometry? padding;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final pad = _cardPad(context);
    return Container(
      decoration: BoxDecoration(
        color: color ?? s.surfaceGlass,
        borderRadius: BorderRadius.circular(_cardRadius(context)),
        border: Border.all(color: s.edge),
        boxShadow: s.panelShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null || action != null)
            Padding(
              padding: EdgeInsets.fromLTRB(pad, pad, pad, 0),
              child: Row(
                children: [
                  if (title != null)
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title!,
                              style: AppTypography.sectionTitleOf(context)
                                  .copyWith(color: s.ink)),
                          if (subtitle != null)
                            Padding(
                              padding: const EdgeInsets.only(top: AppSpacing.xs),
                              child: Text(subtitle!,
                                  style: AppTypography.caption
                                      .copyWith(color: s.inkSecondary)),
                            ),
                        ],
                      ),
                    ),
                  ?action,
                ],
              ),
            ),
          if (title != null || action != null)
            Padding(
              padding: EdgeInsets.only(top: _headerGap(context)),
              child: Divider(height: 1, color: s.edge),
            ),
          Padding(
            padding: padding ?? EdgeInsets.all(pad),
            child: child,
          ),
        ],
      ),
    );
  }
}
