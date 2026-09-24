import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';

class _Banner extends StatelessWidget {
  const _Banner({
    required this.message,
    required this.bg,
    required this.border,
    required this.icon,
    required this.iconColor,
    this.title,
    this.action,
    this.copyable = false,
  });

  final String message;
  final Color bg;
  final Color border;
  final IconData icon;
  final Color iconColor;
  final String? title;
  final Widget? action;
  final bool copyable;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: iconColor),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title != null) ...[
                  Text(title!, style: AppTypography.label.copyWith(color: iconColor, fontWeight: FontWeight.w700)),
                  const SizedBox(height: AppSpacing.xs),
                ],
                Builder(builder: (ctx) {
                  final isDark = Theme.of(ctx).brightness == Brightness.dark;
                  return Text(
                    message,
                    style: AppTypography.bodySmall.copyWith(
                      color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimary,
                    ),
                  );
                }),
                if (action != null) ...[
                  const SizedBox(height: AppSpacing.sm),
                  action!,
                ],
              ],
            ),
          ),
          if (copyable) ...[
            const SizedBox(width: AppSpacing.sm),
            _CopyButton(text: message, color: iconColor),
          ],
        ],
      ),
    );
  }
}

/// Copies the banner text. A 4 dp-padded glyph on desktop; on a phone the
/// same glyph centred in a 48 dp square so the error can actually be grabbed.
class _CopyButton extends StatefulWidget {
  const _CopyButton({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    setState(() => _copied = true);
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final phone = AppLayout.isPhone(context);
    final icon = Icon(
      _copied ? Icons.check : Icons.copy_outlined,
      size: phone ? 18 : 15,
      color: widget.color,
    );
    return Tooltip(
      message: _copied ? 'Copied!' : 'Copy error',
      child: InkWell(
        onTap: _copy,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        child: phone
            ? SizedBox.square(
                dimension: AppLayout.minTouchTarget,
                child: Center(child: icon),
              )
            : Padding(padding: const EdgeInsets.all(4), child: icon),
      ),
    );
  }
}

class InfoBanner extends StatelessWidget {
  const InfoBanner({super.key, required this.message, this.title, this.action});
  final String message;
  final String? title;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return _Banner(
      message: message,
      title: title,
      action: action,
      bg: isDark
          ? AppColors.accentMuted.withValues(alpha: 0.14)
          : AppColors.accentLight,
      border: isDark
          ? AppColors.accentMuted.withValues(alpha: 0.40)
          : AppColors.accentMuted,
      icon: Icons.info_outline,
      iconColor: isDark ? AppColors.accentMuted : AppColors.accentDark,
    );
  }
}

class WarningBanner extends StatelessWidget {
  const WarningBanner({super.key, required this.message, this.title, this.action});
  final String message;
  final String? title;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return _Banner(
      message: message,
      title: title,
      action: action,
      bg: isDark
          ? AppColors.warningMuted.withValues(alpha: 0.14)
          : AppColors.warningLight,
      border: isDark
          ? AppColors.warningMuted.withValues(alpha: 0.40)
          : AppColors.warningMuted,
      icon: Icons.warning_amber_outlined,
      iconColor: isDark ? AppColors.warningMuted : AppColors.warning,
    );
  }
}

class DangerBanner extends StatelessWidget {
  const DangerBanner({super.key, required this.message, this.title, this.action});
  final String message;
  final String? title;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return _Banner(
      message: message,
      title: title,
      action: action,
      bg: isDark
          ? AppColors.dangerMuted.withValues(alpha: 0.14)
          : AppColors.dangerLight,
      border: isDark
          ? AppColors.dangerMuted.withValues(alpha: 0.40)
          : AppColors.dangerMuted,
      icon: Icons.dangerous_outlined,
      iconColor: isDark ? AppColors.dangerMuted : AppColors.danger,
      copyable: true,
    );
  }
}
