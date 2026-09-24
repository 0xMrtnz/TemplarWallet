import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';

/// One step's header text, used to reserve the header's height up front.
/// See [StepHeader.variants].
class StepHeaderVariant {
  const StepHeaderVariant(this.title, [this.subtitle]);
  final String title;
  final String? subtitle;
}

class StepHeader extends StatelessWidget {
  const StepHeader({
    super.key,
    required this.currentStep,
    required this.totalSteps,
    required this.title,
    this.subtitle,
    this.onBack,
    this.onCancel,
    this.variants,
  });

  final int currentStep;
  final int totalSteps;
  final String title;
  final String? subtitle;
  final VoidCallback? onBack;
  final VoidCallback? onCancel;

  /// Every title/subtitle pair this flow can show. Given them, the header
  /// reserves the height of its tallest step, so a two-line subtitle on step 3
  /// does not push the body — and the back arrow — down the screen when the
  /// user arrives from a one-line step 2. Null keeps the old behaviour:
  /// the header is exactly as tall as the text it holds.
  final List<StepHeaderVariant>? variants;

  @override
  Widget build(BuildContext context) {
    // A phone keeps the same header a size down: 22 dp title, full-size
    // touch targets on Back / Cancel and a tighter gap above the progress
    // bar. Desktop metrics are untouched.
    final phone = AppLayout.isPhone(context);
    final titleStyle = AppTypography.pageTitleOf(context);
    final subtitleStyle = _subtitleStyle(context, phone);
    final indicatorStyle =
        AppTypography.stepIndicator.copyWith(color: AppColors.accent);
    // Read here, never inside the LayoutBuilder below: its builder runs during
    // layout, and an inherited dependency registered from there is re-checked
    // in the same phase — when the keyboard closes and MediaQuery changes
    // mid-layout, that marks this element dirty while it is being laid out and
    // the whole step fails to size (the body scroll view is left unlaid-out).
    final measure = _TextMeasure(
      scaler: MediaQuery.textScalerOf(context),
      ambient: DefaultTextStyle.of(context).style,
      direction: Directionality.of(context),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            // The slot is always there, whether or not there is a Back to
            // press: rendering it only from step 2 on slid the whole title
            // block sideways every time the user advanced, and moved the
            // arrow out from under a thumb that was already on its way.
            _BackSlot(onBack: onBack, phone: phone),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final block = Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Step $currentStep of $totalSteps',
                          style: indicatorStyle),
                      const SizedBox(height: AppSpacing.xs),
                      Text(title, style: titleStyle),
                      if (subtitle != null)
                        Padding(
                          padding: const EdgeInsets.only(top: AppSpacing.xs),
                          child: Text(subtitle!, style: subtitleStyle),
                        ),
                    ],
                  );
                  final reserved = _reservedHeight(
                    measure,
                    constraints.maxWidth,
                    indicatorStyle,
                    titleStyle,
                    subtitleStyle,
                  );
                  if (reserved == null) return block;
                  return ConstrainedBox(
                    constraints: BoxConstraints(minHeight: reserved),
                    child: block,
                  );
                },
              ),
            ),
            if (onCancel != null)
              TextButton(
                onPressed: onCancel,
                style: phone
                    ? TextButton.styleFrom(
                        minimumSize: const Size(
                          AppLayout.minTouchTarget,
                          AppLayout.minTouchTarget,
                        ),
                      )
                    : null,
                child: const Text('Cancel'),
              ),
          ],
        ),
        SizedBox(height: phone ? AppSpacing.md : AppSpacing.lg),
        _StepProgress(current: currentStep, total: totalSteps),
      ],
    );
  }

  static TextStyle _subtitleStyle(BuildContext context, bool phone) =>
      (phone ? AppTypography.bodySmall : AppTypography.body).copyWith(
        color: Theme.of(context).brightness == Brightness.dark
            ? AppColors.textSecondaryDark
            : AppColors.textSecondary,
      );

  /// The height of the tallest [variants] entry at this width, or null when
  /// the flow did not declare its steps.
  double? _reservedHeight(
    _TextMeasure measure,
    double width,
    TextStyle indicatorStyle,
    TextStyle titleStyle,
    TextStyle subtitleStyle,
  ) {
    final vs = variants;
    if (vs == null || vs.isEmpty || !width.isFinite || width <= 0) return null;
    // The counter is one line on every step; measured rather than assumed so
    // a text-scale setting moves the reservation with it.
    final indicator = measure.height(
      'Step $currentStep of $totalSteps',
      indicatorStyle,
      width,
    );
    var tallest = 0.0;
    for (final v in vs) {
      var h = indicator +
          AppSpacing.xs +
          measure.height(v.title, titleStyle, width);
      final s = v.subtitle;
      if (s != null && s.isNotEmpty) {
        h += AppSpacing.xs + measure.height(s, subtitleStyle, width);
      }
      tallest = math.max(tallest, h);
    }
    return tallest;
  }
}

/// Text metrics captured outside the layout phase — see [StepHeader.build].
class _TextMeasure {
  const _TextMeasure({
    required this.scaler,
    required this.ambient,
    required this.direction,
  });

  final TextScaler scaler;

  /// The ambient [DefaultTextStyle], merged in exactly as a [Text] merges it:
  /// measuring the bare style misses the theme's line height and under-
  /// reserves by a few pixels a line.
  final TextStyle ambient;
  final TextDirection direction;

  double height(String text, TextStyle style, double width) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: ambient.merge(style)),
      textDirection: direction,
      textScaler: scaler,
    )..layout(maxWidth: width);
    return painter.height;
  }
}

/// The back arrow's fixed slot: the button when there is somewhere to go
/// back to, an inert copy of it — same metrics, invisible — when there is not.
class _BackSlot extends StatelessWidget {
  const _BackSlot({required this.onBack, required this.phone});

  final VoidCallback? onBack;
  final bool phone;

  @override
  Widget build(BuildContext context) {
    final button = IconButton(
      onPressed: onBack,
      icon: const Icon(Icons.arrow_back),
      visualDensity: phone ? VisualDensity.standard : VisualDensity.compact,
      constraints: phone
          ? const BoxConstraints(
              minWidth: AppLayout.minTouchTarget,
              minHeight: AppLayout.minTouchTarget,
            )
          : null,
    );
    if (onBack != null) return button;
    return ExcludeSemantics(
      child: IgnorePointer(child: Opacity(opacity: 0, child: button)),
    );
  }
}

/// One short bar per step: filled behind you, muted on the step you are on,
/// hairline ahead. Nothing here reads inherited state inside a layout-phase
/// builder — see the note in [StepHeader.build].
class _StepProgress extends StatelessWidget {
  const _StepProgress({required this.current, required this.total});
  final int current;
  final int total;

  @override
  Widget build(BuildContext context) {
    final rest = Theme.of(context).brightness == Brightness.dark
        ? AppColors.borderDark
        : AppColors.borderLight;
    return Row(
      children: List.generate(total, (i) {
        final done = i < current;
        final here = i == current - 1;
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(right: i < total - 1 ? AppSpacing.xs : 0),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              height: 4,
              decoration: BoxDecoration(
                color: done
                    ? AppColors.accent
                    : here
                        ? AppColors.accentMuted
                        : rest,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        );
      }),
    );
  }
}

/// A desktop pointer gets the wallet tile's answer (design.md): the surface
/// steps up one, the hairline firms, the icon flashes crimson, and the cursor
/// says it can be clicked. Nothing on the phone changes — it ripples.
class SelectableOptionCard extends StatefulWidget {
  const SelectableOptionCard({
    super.key,
    required this.title,
    required this.description,
    required this.isSelected,
    this.onTap,
    this.badge,
    this.icon,
  });

  final String title;
  final String description;
  final bool isSelected;
  final VoidCallback? onTap;
  final String? badge;
  final IconData? icon;

  @override
  State<SelectableOptionCard> createState() => _SelectableOptionCardState();
}

class _SelectableOptionCardState extends State<SelectableOptionCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final phone = AppLayout.isPhone(context);
    final s = AppScheme.of(context);
    final title = widget.title;
    final description = widget.description;
    final isSelected = widget.isSelected;
    final onTap = widget.onTap;
    final badge = widget.badge;
    final icon = widget.icon;
    final active = !phone && onTap != null && _hover && !isSelected;
    final card = AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: EdgeInsets.all(
          phone ? AppSpacing.cardPaddingSmall : AppSpacing.cardPadding),
      decoration: BoxDecoration(
        color: isSelected
            ? (isDark ? AppColors.sidebarActiveItemBg : AppColors.accentLight)
            : active
                ? (isDark ? AppColors.surfaceDark2 : AppColors.surfaceLight)
                : (isDark ? AppColors.surfaceDark : AppColors.surfaceLight),
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(
          color: isSelected
              ? AppColors.accent
              : active
                  ? s.edgeStrong
                  : (isDark ? AppColors.borderDark : AppColors.borderLight),
          width: isSelected ? 2 : 1,
        ),
      ),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(
              icon,
              size: 24,
              color: isSelected || active
                  ? AppColors.accent
                  : (isDark ? AppColors.textSecondaryDark : AppColors.textSecondary),
            ),
            const SizedBox(width: AppSpacing.lg),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The title is Flexible so a long one wraps under the badge
                // instead of pushing past the card edge — layout-neutral
                // wherever it already fit on one line.
                Row(
                  children: [
                    Flexible(
                      child: Text(title, style: AppTypography.sectionTitle),
                    ),
                    if (badge != null) ...[
                      const SizedBox(width: AppSpacing.sm),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.warningLight,
                          borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                        ),
                        child: Text(badge, style: AppTypography.label.copyWith(color: AppColors.warning)),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(description, style: AppTypography.bodySmall.copyWith(
                  color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondary,
                )),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.lg),
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isSelected ? AppColors.accent : Colors.transparent,
              border: Border.all(
                color: isSelected ? AppColors.accent : (isDark ? AppColors.borderDark : AppColors.borderLight),
                width: 2,
              ),
            ),
            child: isSelected
                ? const Icon(Icons.check, size: 12, color: Colors.white)
                : null,
          ),
        ],
      ),
    );
    if (!phone) {
      return MouseRegion(
        cursor: onTap != null
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(onTap: onTap, child: card),
      );
    }
    // Touch gets a ripple; the desktop cursor/colour change stays as is.
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        child: card,
      ),
    );
  }
}
