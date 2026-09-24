// The last step of a hardware pairing: what was actually created, checked.
//
// A wallet built from a device is the one setup where "it seemed to work" is
// not good enough. The device holds the keys, so a wallet whose descriptor came
// from somewhere else is a wallet that can receive funds and never spend them —
// and nothing on a dashboard would show it. This screen states, per network,
// what exists and where it came from, and marks the checks that passed.
//
// It also has to be honest when half the pairing failed: a Jade that gave up
// its Bitcoin descriptors but not its Liquid one leaves a real, usable Bitcoin
// wallet, and saying so beats both a green tick and an error page.

import 'package:flutter/material.dart';

import '../../shared/widgets/badges.dart';
import '../../shared/widgets/buttons.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';

/// One network's outcome in the recap.
class PairingNetwork {
  const PairingNetwork({
    required this.name,
    required this.icon,
    required this.color,
    required this.ok,
    required this.detail,
    this.descriptor,
    this.action,
    this.actionLabel,
    this.busy = false,
  });

  final String name;
  final IconData icon;
  final Color color;

  /// Whether this side of the wallet exists and is usable.
  final bool ok;

  /// One line on what it is, or why it is missing.
  final String detail;

  /// The descriptor stored for this side, shown so the user can compare it with
  /// their device or keep it as a backup.
  final String? descriptor;

  /// Offered when a side is missing and there is something to press — "retry
  /// Liquid", typically.
  final VoidCallback? action;
  final String? actionLabel;
  final bool busy;
}

/// A named check that was performed, and its result.
class PairingCheck {
  const PairingCheck({required this.label, required this.passed, this.detail});
  final String label;
  final bool passed;
  final String? detail;
}

class PairingRecapView extends StatelessWidget {
  const PairingRecapView({
    super.key,
    required this.walletName,
    required this.deviceLabel,
    required this.fingerprint,
    required this.networks,
    required this.checks,
    this.footnote,
  });

  final String walletName;

  /// "Blockstream Jade over USB", "SeedSigner (air-gap, QR)".
  final String deviceLabel;

  /// Master fingerprint the wallet is bound to. Empty hides the chip.
  final String fingerprint;

  final List<PairingNetwork> networks;
  final List<PairingCheck> checks;

  /// Extra line under the checks — what happens at signing time, typically.
  final String? footnote;

  bool get _allOk => networks.every((n) => n.ok) && checks.every((c) => c.passed);

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    // A plain Column, not a scroll view: every caller places this inside
    // StepFlowScaffold, which already scrolls its body. A second viewport there
    // gets unbounded height and throws.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
          // Headline: green only when everything asked for is there.
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: (_allOk ? s.success : s.warning).withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  _allOk ? Icons.check_rounded : Icons.warning_amber_rounded,
                  color: _allOk ? s.success : s.warning,
                  size: 26,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _allOk ? 'Pairing complete' : 'Paired, with one part missing',
                      style: AppTypography.pageTitle.copyWith(fontSize: 20),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$walletName · $deviceLabel',
                      style: AppTypography.bodySmall
                          .copyWith(color: s.inkSecondary),
                    ),
                  ],
                ),
              ),
              if (fingerprint.isNotEmpty)
                StatusBadge(
                  label: fingerprint,
                  variant: BadgeVariant.accent,
                  icon: Icons.fingerprint,
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.xl),
          for (final n in networks) ...[
            _NetworkResultCard(network: n),
            const SizedBox(height: AppSpacing.md),
          ],
          if (checks.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              'CHECKS',
              style: AppTypography.label
                  .copyWith(color: s.inkFaint, letterSpacing: 1.2),
            ),
            const SizedBox(height: AppSpacing.sm),
            for (final c in checks)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      c.passed ? Icons.check_circle : Icons.cancel,
                      size: 16,
                      color: c.passed ? s.success : s.danger,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          text: c.label,
                          style: AppTypography.bodySmall
                              .copyWith(color: s.inkSecondary),
                          children: [
                            if (c.detail != null)
                              TextSpan(
                                text: '  ${c.detail}',
                                style: AppTypography.monoSmall
                                    .copyWith(color: s.inkFaint),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
          if (footnote != null) ...[
            const SizedBox(height: AppSpacing.lg),
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: s.surfaceRaised,
                borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline_rounded, size: 16, color: s.inkFaint),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      footnote!,
                      style: AppTypography.bodySmall
                          .copyWith(color: s.inkSecondary),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

class _NetworkResultCard extends StatelessWidget {
  const _NetworkResultCard({required this.network});
  final PairingNetwork network;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final n = network;
    final tint = n.ok ? n.color : s.warning;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.cardPadding),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: s.isDark ? 0.10 : 0.06),
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: tint.withValues(alpha: 0.65)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(n.icon, color: tint, size: 20),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(n.name, style: AppTypography.sectionTitle),
                    const SizedBox(height: 2),
                    Text(
                      n.detail,
                      style: AppTypography.bodySmall
                          .copyWith(color: s.inkSecondary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Icon(
                n.ok ? Icons.check_circle : Icons.remove_circle_outline,
                color: tint,
                size: 20,
              ),
            ],
          ),
          if (n.descriptor != null) ...[
            const SizedBox(height: AppSpacing.md),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppSpacing.sm),
              decoration: BoxDecoration(
                color: s.surfaceSolid,
                borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                border: Border.all(color: s.edge),
              ),
              child: SelectableText(
                n.descriptor!,
                style: AppTypography.monoSmall.copyWith(color: s.inkSecondary),
                maxLines: 3,
              ),
            ),
          ],
          if (n.action != null && n.actionLabel != null) ...[
            const SizedBox(height: AppSpacing.md),
            Align(
              alignment: Alignment.centerLeft,
              child: SecondaryButton(
                label: n.busy ? 'Working…' : n.actionLabel!,
                icon: Icons.refresh_rounded,
                onPressed: n.busy ? null : n.action,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
