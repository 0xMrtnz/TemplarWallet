import 'package:flutter/material.dart';

import '../../bridge/bridge_provider.dart';
import '../../services/hwi_installer.dart';
import '../../shared/widgets/banners.dart';
import '../../shared/widgets/buttons.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';

/// Offer to download and install the HWI toolkit when no `hwi` binary is
/// available. One flow for every OS: the official standalone binary from
/// bitcoin-core/HWI releases lands in the app's data directory and is
/// activated in the running backend — no restart, no Python.
class HwiInstallCard extends StatefulWidget {
  const HwiInstallCard({required this.onInstalled, super.key});

  /// Called after the binary is installed and activated.
  final VoidCallback onInstalled;

  @override
  State<HwiInstallCard> createState() => _HwiInstallCardState();
}

class _HwiInstallCardState extends State<HwiInstallCard> {
  final _installer = HwiInstaller();

  HwiReleaseInfo? _release;
  bool _installing = false;
  HwiInstallPhase? _phase;
  double _progress = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    try {
      final release = await _installer.resolveLatest();
      if (mounted) setState(() { _release = release; _error = null; });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _install() async {
    setState(() { _installing = true; _error = null; _progress = 0; });
    try {
      await _installer.install(
        bridge: walletBridge,
        release: _release,
        onProgress: (phase, progress) {
          if (mounted) setState(() { _phase = phase; _progress = progress; });
        },
      );
      if (mounted) {
        setState(() => _installing = false);
        widget.onInstalled();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _installing = false;
          _error = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  String get _phaseLabel => switch (_phase) {
        HwiInstallPhase.resolving => 'Finding the latest release…',
        HwiInstallPhase.downloading =>
          'Downloading… ${(_progress * 100).round()}%',
        HwiInstallPhase.verifying => 'Verifying checksum…',
        HwiInstallPhase.extracting => 'Extracting…',
        HwiInstallPhase.activating => 'Activating…',
        null => '',
      };

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final release = _release;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.cardPadding),
      decoration: BoxDecoration(
        color: isDark ? AppColors.surfaceDark : AppColors.surfaceLight,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: AppColors.warning, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.download_for_offline_outlined,
                  color: AppColors.warning, size: 22),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text('HWI toolkit required',
                    style: AppTypography.sectionTitle),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            'USB hardware wallets are driven by HWI (Hardware Wallet '
            'Interface, a Bitcoin Core project). It is not installed yet. '
            'Templar can download the official signed build and set it up '
            'automatically.',
            style: AppTypography.bodySmall.copyWith(
              color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          if (_installing) ...[
            LinearProgressIndicator(
              value: _phase == HwiInstallPhase.downloading ? _progress : null,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(_phaseLabel, style: AppTypography.caption),
          ] else ...[
            Row(
              children: [
                PrimaryButton(
                  label: release == null
                      ? 'Install HWI'
                      : 'Install HWI ${release.version} (${release.sizeDisplay})',
                  icon: Icons.download_rounded,
                  onPressed: _install,
                ),
              ],
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.md),
            WarningBanner(title: 'Install failed', message: _error!),
          ],
        ],
      ),
    );
  }
}
