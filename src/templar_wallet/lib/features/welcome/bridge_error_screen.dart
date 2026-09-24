import 'dart:io';

import 'package:flutter/material.dart';
import '../../shared/widgets/buttons.dart';
import '../../shared/widgets/code_box.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/hybrid_kit.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';

/// Fatal startup screen: the native wallet engine (wallet-ffi library) could
/// not be loaded. Shown in non-debug builds instead of the app — without the
/// engine there is no real wallet data, and falling back to mock data would
/// show phantom wallets and addresses nobody controls.
class BridgeErrorScreen extends StatelessWidget {
  const BridgeErrorScreen({super.key, required this.error});

  /// The load failure — includes the underlying dlopen error and every
  /// candidate path the loader tried.
  final Object error;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final secondary =
        isDark ? AppColors.textSecondaryDark : AppColors.textSecondary;

    return Scaffold(
      body: PageBackground(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.xxxl),
              child: GlassCard(
                tint: AppColors.danger,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: AppColors.danger.withValues(alpha: 0.15),
                            borderRadius:
                                BorderRadius.circular(AppSpacing.radiusSm),
                          ),
                          child: const Icon(Icons.link_off,
                              size: 22, color: AppColors.danger),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: Text(
                            'The wallet engine could not be loaded',
                            style: AppTypography.sectionTitle,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    Text(
                      'Templar Wallet could not start its native wallet engine, '
                      'so it cannot show or manage any wallets. Your wallet '
                      'files on disk are untouched.',
                      style: AppTypography.body.copyWith(color: secondary),
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    CodeBox(
                      label: 'Error details',
                      value: '$error',
                      maxLines: 16,
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    Text('What you can do', style: AppTypography.label),
                    const SizedBox(height: AppSpacing.sm),
                    _step('Reinstall Templar Wallet — the engine library may be '
                        'missing or damaged.'),
                    _step('If the problem persists, report the issue and '
                        'include the error details above (use the copy '
                        'button).'),
                    const SizedBox(height: AppSpacing.xl),
                    Align(
                      alignment: Alignment.centerRight,
                      child: SecondaryButton(
                        label: 'Quit',
                        icon: Icons.close,
                        onPressed: () => exit(1),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _step(String text) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 3),
              child: Icon(Icons.chevron_right,
                  size: 14, color: AppColors.textMuted),
            ),
            const SizedBox(width: AppSpacing.xs),
            Expanded(child: Text(text, style: AppTypography.bodySmall)),
          ],
        ),
      );
}
