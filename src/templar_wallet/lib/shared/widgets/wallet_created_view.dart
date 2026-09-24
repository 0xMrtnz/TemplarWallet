import 'package:flutter/material.dart';

import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import 'hex_text.dart';
import 'hybrid_kit.dart';

/// One summary row on the wallet-created screen.
class WalletCreatedDetail {
  const WalletCreatedDetail(this.label, this.value, {this.mono = false});

  final String label;
  final String value;

  /// Render the value as colored mono hex (keys, descriptors, fingerprints).
  final bool mono;
}

/// The celebratory "wallet created" view shared by every setup flow —
/// springy check mark, sheened title, then a staggered recap of what was
/// just created (type, threshold, networks, keys). Motion primitives no-op
/// under reduced-motion settings.
class WalletCreatedView extends StatelessWidget {
  const WalletCreatedView({
    required this.walletName,
    this.subtitle,
    this.details = const [],
    super.key,
  });

  final String walletName;

  /// One line under the title, e.g. "2-of-3 multisig — 2 keys required".
  final String? subtitle;

  /// Recap rows revealed one after another.
  final List<WalletCreatedDetail> details;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: AppSpacing.xl),
            Pop(
              child: Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: s.success,
                  boxShadow: [
                    BoxShadow(
                      color: s.success.withValues(alpha: 0.35),
                      blurRadius: 28,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: const Icon(Icons.check_rounded, color: Colors.white, size: 46),
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            Reveal(
              delay: 1,
              child: GradientText(
                walletName,
                style: AppTypography.pageTitle.copyWith(fontSize: 26),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Reveal(
              delay: 2,
              child: Text(
                subtitle ?? 'Your wallet is ready.',
                textAlign: TextAlign.center,
                style: AppTypography.body.copyWith(color: s.inkSecondary),
              ),
            ),
            if (details.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.xl),
              Reveal(
                delay: 3,
                child: DataWell(
                  child: Column(
                    children: [
                      for (var i = 0; i < details.length; i++) ...[
                        if (i > 0) const SizedBox(height: AppSpacing.sm),
                        Reveal(
                          delay: 3 + i,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 110,
                                child: Text(
                                  details[i].label,
                                  style: AppTypography.caption
                                      .copyWith(color: s.inkFaint),
                                ),
                              ),
                              const SizedBox(width: AppSpacing.sm),
                              Expanded(
                                child: details[i].mono
                                    ? Align(
                                        alignment: Alignment.centerLeft,
                                        child: HexText(details[i].value,
                                            truncate: true),
                                      )
                                    : Text(
                                        details[i].value,
                                        style: AppTypography.bodySmall
                                            .copyWith(color: s.ink),
                                      ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
