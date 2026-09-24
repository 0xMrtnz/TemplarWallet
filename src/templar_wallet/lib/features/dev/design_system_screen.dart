import 'package:flutter/material.dart';
import '../../shared/widgets/badges.dart';
import '../../shared/widgets/banners.dart';
import '../../shared/widgets/buttons.dart';
import '../../shared/widgets/cards.dart';
import '../../shared/widgets/code_box.dart';
import '../../shared/widgets/page_header.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';

class DesignSystemScreen extends StatelessWidget {
  const DesignSystemScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark ? AppColors.backgroundDark : AppColors.backgroundLight,
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        children: [
          const PageHeader(title: 'Design System', subtitle: 'Visual QA preview'),
          // Typography
          _Section(title: 'Typography', children: [
            Text('Balance Hero', style: AppTypography.balanceHero),
            Text('Balance Large', style: AppTypography.balanceLarge),
            Text('Balance Medium', style: AppTypography.balanceMedium),
            Text('Page Title', style: AppTypography.pageTitle),
            Text('Section Title', style: AppTypography.sectionTitle),
            Text('Body Large', style: AppTypography.bodyLarge),
            Text('Body', style: AppTypography.body),
            Text('Body Small', style: AppTypography.bodySmall),
            Text('Caption', style: AppTypography.caption),
            Text('Label', style: AppTypography.label),
            Text('Mono — deadbeef/84h/1h/0h', style: AppTypography.mono),
          ]),
          const SizedBox(height: AppSpacing.xl),
          // Colors
          _Section(title: 'Colors', children: [
            _ColorRow(name: 'Accent', color: AppColors.accent),
            _ColorRow(name: 'Success', color: AppColors.success),
            _ColorRow(name: 'Warning', color: AppColors.warning),
            _ColorRow(name: 'Danger', color: AppColors.danger),
            _ColorRow(name: 'Text primary', color: AppColors.textPrimary),
            _ColorRow(name: 'Text secondary', color: AppColors.textSecondary),
          ]),
          const SizedBox(height: AppSpacing.xl),
          // Buttons
          _Section(title: 'Buttons', children: [
            Wrap(
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.md,
              children: [
                PrimaryButton(label: 'Primary', onPressed: () {}),
                SecondaryButton(label: 'Secondary', onPressed: () {}),
                DangerButton(label: 'Danger', onPressed: () {}),
                GhostButton(label: 'Ghost', onPressed: () {}),
                PrimaryButton(label: 'Loading', isLoading: true, onPressed: null),
                PrimaryButton(label: 'With icon', icon: Icons.send, onPressed: () {}),
              ],
            ),
          ]),
          const SizedBox(height: AppSpacing.xl),
          // Badges
          _Section(title: 'Badges & Chips', children: [
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: const [
                StatusBadge(label: 'Synced', variant: BadgeVariant.success, dot: true),
                StatusBadge(label: 'Warning', variant: BadgeVariant.warning),
                StatusBadge(label: 'Danger', variant: BadgeVariant.danger),
                StatusBadge(label: 'Accent', variant: BadgeVariant.accent),
                StatusBadge(label: 'Neutral', variant: BadgeVariant.neutral),
                AssetBadge(ticker: 'BTC', isNative: true),
                AssetBadge(ticker: 'USDT'),
                AssetChip(ticker: 'BTC', amount: '0.012 BTC'),
                AssetChip(ticker: 'USDT', amount: '100 USDT', isSelected: true),
              ],
            ),
          ]),
          const SizedBox(height: AppSpacing.xl),
          // Banners
          _Section(title: 'Banners', children: const [
            InfoBanner(title: 'Info', message: 'This is an informational banner with a title.'),
            SizedBox(height: AppSpacing.md),
            WarningBanner(message: 'This is a warning banner without a title.'),
            SizedBox(height: AppSpacing.md),
            DangerBanner(title: 'Danger', message: 'This is a danger banner for irreversible actions.'),
          ]),
          const SizedBox(height: AppSpacing.xl),
          // Cards
          _Section(title: 'Cards', children: [
            FormCard(
              title: 'Form card',
              subtitle: 'With a subtitle',
              child: Text('Form card content goes here.', style: AppTypography.body),
            ),
            const SizedBox(height: AppSpacing.lg),
            SummaryCard(
              title: 'Summary card',
              rows: const [
                (label: 'Label one', value: 'Value one', isMono: false),
                (label: 'Label two', value: 'deadbeef1234', isMono: true),
                (label: 'Label three', value: 'Long value here', isMono: false),
              ],
            ),
          ]),
          const SizedBox(height: AppSpacing.xl),
          // Code box & copy row
          _Section(title: 'Code box & Copy row', children: const [
            CodeBox(label: 'Descriptor', value: 'wpkh([deadbeef/84h/1h/0h]tpubDC7KMhGhFE2MhAJXrWMxumRnpFDqgtQQiQSFLGCaAk5CW8BQBuNr7PKRqNGV1ZB6qKP3zERkHV7DGUzPMDQc2y4kF7K8UrHeRfFXWkHPPjE/0/*)'),
            SizedBox(height: AppSpacing.lg),
            CopyRow(label: 'Master fingerprint', value: 'deadbeef'),
            Divider(height: 1),
            CopyRow(label: 'Wallet name', value: 'Primary', mono: false),
          ]),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.cardPadding),
      decoration: BoxDecoration(
        color: isDark ? AppColors.surfaceDark : AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: isDark ? AppColors.borderDark : AppColors.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: AppTypography.sectionTitle),
          const SizedBox(height: AppSpacing.lg),
          const Divider(height: 1),
          const SizedBox(height: AppSpacing.lg),
          ...children,
        ],
      ),
    );
  }
}

class _ColorRow extends StatelessWidget {
  const _ColorRow({required this.name, required this.color});
  final String name;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        children: [
          Container(width: 32, height: 32, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(AppSpacing.radiusSm))),
          const SizedBox(width: AppSpacing.md),
          Text(name, style: AppTypography.body),
          const SizedBox(width: AppSpacing.md),
          Text('#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}', style: AppTypography.mono),
        ],
      ),
    );
  }
}
