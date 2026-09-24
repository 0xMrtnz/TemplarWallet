import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';

/// Translucent depth card — semi-transparent gradient surface + soft border.
/// No BackdropFilter (keeps the render thread lean); the translucency lets the
/// page gradient bleed through for a glassy feel. Pass [tint] to colour the
/// surface and border by chain (e.g. Liquid green or BTC orange).
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding,
    this.borderRadius,
    this.sigma = 0,
    this.onTap,
    this.hoverLift = false,
    this.tint,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double? borderRadius;
  final double sigma; // API compat, unused
  final VoidCallback? onTap;
  final bool hoverLift; // API compat, unused

  /// Optional chain accent. When set, blends into the gradient and border.
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final r = borderRadius ?? AppSpacing.radiusLg;

    // Semi-transparent base so the page gradient shows through.
    final baseColors = isDark
        ? [const Color(0x2EFFFFFF), const Color(0x14FFFFFF)]
        : [const Color(0xE6FFFFFF), const Color(0xB3FFFFFF)];

    final colors = tint == null
        ? baseColors
        : [
            Color.alphaBlend(
                tint!.withValues(alpha: isDark ? 0.26 : 0.16), baseColors[0]),
            Color.alphaBlend(
                tint!.withValues(alpha: isDark ? 0.10 : 0.06), baseColors[1]),
          ];

    final borderColor = tint != null
        ? tint!.withValues(alpha: isDark ? 0.45 : 0.40)
        : (isDark ? const Color(0x33FFFFFF) : const Color(0x66FFFFFF));

    final card = Container(
      padding: padding ?? const EdgeInsets.all(AppSpacing.cardPadding),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
        borderRadius: BorderRadius.circular(r),
        border: Border.all(color: borderColor),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.30 : 0.06),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );

    return onTap != null ? GestureDetector(onTap: onTap, child: card) : card;
  }
}

/// Shimmer placeholder — simple opacity pulse, no per-frame gradient repaint.
class ShimmerBox extends StatefulWidget {
  const ShimmerBox({
    super.key,
    required this.width,
    required this.height,
    this.borderRadius = 8.0,
  });
  final double width;
  final double height;
  final double borderRadius;

  @override
  State<ShimmerBox> createState() => _ShimmerBoxState();
}

class _ShimmerBoxState extends State<ShimmerBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = isDark ? AppColors.surfaceDark2 : AppColors.borderLight;
    final bright = isDark ? AppColors.borderDark : const Color(0xFFFAE2E3);

    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, _) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: Color.lerp(base, bright, _ctrl.value),
          borderRadius: BorderRadius.circular(widget.borderRadius),
        ),
      ),
    );
  }
}

/// Shimmer skeleton matching the Dashboard layout during initial load.
class DashboardShimmer extends StatelessWidget {
  const DashboardShimmer({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark ? AppColors.surfaceDark : AppColors.surfaceLight;
    final borderColor = isDark ? AppColors.borderDark : AppColors.borderLight;

    if (AppLayout.isPhone(context)) {
      // The phone dashboard: no page header, one hero, the chain panels
      // stacked full width under a 16-dp gutter.
      return Padding(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _card(cardColor, borderColor, 300, phone: true),
            const SizedBox(height: AppSpacing.lg),
            _card(cardColor, borderColor, 150, phone: true),
            const SizedBox(height: AppSpacing.lg),
            _card(cardColor, borderColor, 150, phone: true),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ShimmerBox(width: 200, height: 26),
          const SizedBox(height: 8),
          const ShimmerBox(width: 120, height: 14),
          const SizedBox(height: 32),
          _card(cardColor, borderColor, 156),
          const SizedBox(height: 24),
          const ShimmerBox(width: 60, height: 18),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _card(cardColor, borderColor, 128)),
              const SizedBox(width: 16),
              Expanded(child: _card(cardColor, borderColor, 128)),
              const SizedBox(width: 16),
              Expanded(child: _card(cardColor, borderColor, 128)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _card(Color bg, Color border, double h, {bool phone = false}) =>
      Container(
        height: h,
        width: phone ? double.infinity : null,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
          border: Border.all(color: border),
        ),
        padding: EdgeInsets.all(
            phone ? AppSpacing.cardPaddingSmall : AppSpacing.cardPadding),
        child: phone
            // Fractional widths: the placeholders must fit a 379-dp column.
            ? const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FractionallySizedBox(
                    widthFactor: 0.4,
                    child: ShimmerBox(width: double.infinity, height: 12),
                  ),
                  SizedBox(height: 12),
                  FractionallySizedBox(
                    widthFactor: 0.7,
                    child: ShimmerBox(width: double.infinity, height: 32),
                  ),
                ],
              )
            : const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ShimmerBox(width: 140, height: 12),
                  SizedBox(height: 12),
                  ShimmerBox(width: 220, height: 32),
                ],
              ),
      );
}
