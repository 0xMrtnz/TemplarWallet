// Linux: one-click fix for "the OS won't let us open the device".
//
// This is the counterpart of [HwiInstallCard]. HWI being installed is only
// half of what a Linux user needs — without udev rules the toolkit runs fine
// and simply reports no devices, which is indistinguishable from a broken
// cable unless the app says so.

import 'package:flutter/material.dart';

import '../../services/udev_installer.dart';
import '../../shared/widgets/banners.dart';
import '../../shared/widgets/buttons.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';

class DevicePermissionCard extends StatefulWidget {
  const DevicePermissionCard({
    required this.onFixed,
    this.detail,
    super.key,
  });

  /// Called after the rules were installed, so the host can rescan.
  final VoidCallback onFixed;

  /// The backend's own words about the failure, when this card is shown in
  /// response to a specific error rather than a proactive check.
  final String? detail;

  @override
  State<DevicePermissionCard> createState() => _DevicePermissionCardState();
}

class _DevicePermissionCardState extends State<DevicePermissionCard> {
  bool _running = false;
  String? _error;
  String? _success;

  Future<void> _fix() async {
    setState(() {
      _running = true;
      _error = null;
      _success = null;
    });
    final result = await UdevInstaller.install();
    if (!mounted) return;
    setState(() {
      _running = false;
      if (result.ok) {
        _success = result.message;
      } else {
        _error = result.message;
      }
    });
    if (result.ok) widget.onFixed();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

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
              const Icon(Icons.usb_off_rounded,
                  color: AppColors.warning, size: 22),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text('Device permissions needed',
                    style: AppTypography.sectionTitle),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            'On Linux, a normal user cannot talk to a hardware wallet until '
            'udev rules grant access to it. Templar ships the official rules '
            'from the HWI project and can install them for you — you will be '
            'asked for your password once.',
            style: AppTypography.bodySmall.copyWith(
              color:
                  isDark ? AppColors.textSecondaryDark : AppColors.textSecondary,
            ),
          ),
          if (widget.detail != null && widget.detail!.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              widget.detail!,
              style: AppTypography.caption,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          if (_running) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: AppSpacing.sm),
            Text('Waiting for authentication…', style: AppTypography.caption),
          ] else
            Row(
              children: [
                PrimaryButton(
                  label: 'Fix device permissions',
                  icon: Icons.admin_panel_settings_outlined,
                  onPressed: _fix,
                ),
              ],
            ),
          if (_success != null) ...[
            const SizedBox(height: AppSpacing.md),
            InfoBanner(title: 'Permissions installed', message: _success!),
          ],
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.md),
            const WarningBanner(
              title: 'Could not install rules',
              message: 'Details and a manual alternative below.',
            ),
            const SizedBox(height: AppSpacing.sm),
            // Selectable: the fallback is a block of shell commands the user
            // has to copy into a terminal, so it must not be plain Text.
            SelectableText(_error!, style: AppTypography.monoSmall),
          ],
        ],
      ),
    );
  }
}
