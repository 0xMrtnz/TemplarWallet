// The list of connected hardware wallets, as its own block.
//
// # Why this is separate from the warnings around it
//
// The USB step used to render prerequisites, platform limits, permission fixes
// and the device list as one column of cards, and the same device could appear
// twice: once in the "connected and recognised" list inside a warning card, and
// again in the scan results below it. Which row to click was a guess.
//
// Here the devices are one section with one row per physical device, and every
// warning lives outside it.
//
// # Two questions, two costs
//
// *What is plugged in?* is answered by reading USB descriptors the OS already
// cached: instant, safe to repeat, and it never touches the device. That runs on
// a timer so the section reacts to a cable being connected.
//
// *Which wallet does it hold?* means opening the device and asking for a key —
// which prompts for the PIN on a Jade and takes exclusive hold of its port. That
// only ever happens when the user asks for it.
//
// So a row starts as "Jade — connected" and becomes "Jade — a1b2c3d4" after
// identification. Rows are keyed by the USB path, which is also what the
// backend reports for a natively-driven device, so the two answers land on the
// same row instead of producing two.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../bridge/bridge_provider.dart';
import '../../shared/widgets/badges.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import '../create_wallet/models/hw_device.dart';
import '../create_wallet/models/native_device.dart';
import 'hw_error.dart';
import 'hw_platform.dart';

/// One physical device, with whatever is known about it so far.
class DeviceRow {
  const DeviceRow({
    required this.model,
    required this.transport,
    required this.path,
    required this.drivable,
    this.family = '',
    this.usbId,
    this.device,
  });

  final String model;

  /// "hid" or "serial".
  final String transport;
  final String path;

  /// Whether a **native** driver exists for this family (Ledger, Jade).
  ///
  /// Not the same as usable: see [usable]. A Trezor is not drivable and is
  /// perfectly usable on Windows and Linux, through the HWI helper.
  final bool drivable;

  /// Protocol family as the backend names it ("jade", "ledger", …). Empty when
  /// the row came from a scan result, which reports a model rather than a family.
  final String family;
  final String? usbId;

  /// Set once the device has been opened and its master fingerprint read.
  /// Until then the row is a detection, not a wallet.
  final HwDevice? device;

  bool get isIdentified => device != null;
  String? get fingerprint => device?.fingerprint;

  /// Whether this device can be paired **here**, by either route: a native
  /// driver, or the HWI helper where it can run.
  ///
  /// The two are not the same, and conflating them greys out every Trezor,
  /// Coldcard, KeepKey and BitBox on Windows and Linux — where they work fine.
  /// Only macOS, which cannot start the helper at all, is left with the
  /// native families.
  bool get usable => drivable || hwiFallbackUsable;

  /// Whether this device can hold a Liquid wallet. Jade only — every other
  /// family is Bitcoin-only in firmware, so a Liquid wallet paired with one
  /// could receive funds it could never spend.
  bool get supportsLiquid {
    final haystack = '$family $model'.toLowerCase();
    return haystack.contains('jade');
  }
}

/// Fold the cheap detection list and the identified-device list into one row
/// per physical device.
///
/// A natively driven device reports the same USB path in both answers, which is
/// what keeps it to a single row. A device reached through the HWI helper has a
/// path of its own shape and no detection entry to merge with, so it is
/// appended — still once.
List<DeviceRow> mergeDeviceRows({
  required List<NativeDevice> detected,
  required List<HwDevice> identified,
}) {
  final byPath = {for (final d in identified) d.path: d};
  final claimed = <String>{};

  final rows = <DeviceRow>[
    for (final d in detected)
      DeviceRow(
        model: d.model,
        transport: d.transport,
        path: d.path,
        drivable: d.drivable,
        family: d.family,
        usbId: d.usbId,
        device: () {
          final match = byPath[d.path];
          if (match != null) claimed.add(match.path);
          return match;
        }(),
      ),
  ];

  for (final d in identified) {
    if (claimed.contains(d.path)) continue;
    // Same device on a different path shape (HWI reports its own): match on
    // the fingerprint so it cannot be listed a second time.
    if (rows.any((r) => r.fingerprint == d.fingerprint)) continue;
    rows.add(DeviceRow(
      model: d.model,
      transport: d.path.startsWith('/dev/') ? 'serial' : 'hid',
      path: d.path,
      drivable: true,
      device: d,
    ));
  }
  return rows;
}

class DeviceListSection extends StatefulWidget {
  const DeviceListSection({
    super.key,
    required this.selected,
    required this.onSelect,
    required this.liquidWanted,
    this.onFailure,
  });

  /// Currently chosen device, by fingerprint.
  final HwDevice? selected;
  final void Function(HwDevice) onSelect;

  /// Whether the wizard asked for Liquid — drives the per-row capability chip,
  /// so a Bitcoin-only device is called out before it is chosen rather than
  /// after.
  final bool liquidWanted;

  /// Failures that have a fix elsewhere on the screen (install HWI, repair
  /// permissions) are handed up instead of shown here.
  final void Function(HwFailure)? onFailure;

  @override
  State<DeviceListSection> createState() => _DeviceListSectionState();
}

class _DeviceListSectionState extends State<DeviceListSection> {
  final _bridge = walletBridge;

  List<NativeDevice> _detected = const [];
  List<HwDevice> _identified = const [];
  Timer? _detectTimer;
  bool _identifying = false;
  bool _detectedOnce = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _detect();
    // Detection reads cached USB descriptors — no device is opened, so this can
    // run on a timer without prompting anyone for a PIN.
    _detectTimer = Timer.periodic(const Duration(seconds: 3), (_) => _detect());
  }

  @override
  void dispose() {
    _detectTimer?.cancel();
    super.dispose();
  }

  Future<void> _detect() async {
    try {
      final devices = await _bridge.enumerateNativeDevices();
      if (!mounted) return;
      setState(() {
        _detected = devices;
        _detectedOnce = true;
      });
    } catch (_) {
      // Detection is the cheap half and never the whole answer — a failure
      // here must not blank the rows already on screen.
      if (mounted) setState(() => _detectedOnce = true);
    }
  }

  /// Open the attached devices and read their fingerprints. This is the step
  /// that prompts for the PIN on a Jade, so it only runs when asked.
  Future<void> _identify() async {
    setState(() {
      _identifying = true;
      _error = null;
    });
    try {
      final devices = await _bridge.enumerateHwDevices();
      if (!mounted) return;
      setState(() {
        _identified = devices;
        _identifying = false;
      });
      // One device and nothing chosen yet: choosing it for the user is safe
      // and saves a click. With two attached, the choice is theirs.
      if (devices.length == 1 && widget.selected == null) {
        widget.onSelect(devices.first);
      }
    } catch (e) {
      if (!mounted) return;
      final failure = classifyHwError(e);
      setState(() {
        _identifying = false;
        // Anything with a fix card of its own is handed up; what is left is a
        // message about this device, and belongs next to the device.
        _error = (failure.isHwiMissing || failure.isPermission)
            ? null
            : failure.message;
      });
      if (failure.isHwiMissing || failure.isPermission) {
        widget.onFailure?.call(failure);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final rows = mergeDeviceRows(detected: _detected, identified: _identified);
    final anyUnidentified = rows.any((r) => r.usable && !r.isIdentified);
    // Where the HWI helper runs, it is also the catch-all for a device our own
    // USB table does not recognise — so identification stays offered even when
    // detection found nothing, or a brand-new model could never be paired.
    final canIdentify = rows.any((r) => r.usable) || hwiFallbackUsable;

    return Container(
      decoration: BoxDecoration(
        color: s.surfaceSolid,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: s.edge),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header strip — title, count, and the one button that talks to the
          // devices.
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.cardPadding,
              vertical: AppSpacing.md,
            ),
            decoration: BoxDecoration(
              color: s.surfaceRaised,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(AppSpacing.radiusMd),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.usb_rounded, size: 18, color: s.inkSecondary),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    rows.isEmpty
                        ? 'Connected devices'
                        : 'Connected devices · ${rows.length}',
                    style: AppTypography.sectionTitle,
                  ),
                ),
                if (_identifying)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  TextButton.icon(
                    onPressed: canIdentify ? _identify : _detect,
                    icon: Icon(
                      anyUnidentified ? Icons.fingerprint : Icons.refresh_rounded,
                      size: 16,
                    ),
                    label: Text(anyUnidentified ? 'Identify' : 'Rescan'),
                  ),
              ],
            ),
          ),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.all(AppSpacing.cardPadding),
              child: Row(
                children: [
                  Icon(Icons.usb_off_rounded, size: 18, color: s.inkFaint),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Text(
                      _detectedOnce
                          ? 'Nothing connected yet. Plug in your device with '
                              'its cable — this list updates on its own.'
                          : 'Looking for devices…',
                      style: AppTypography.bodySmall
                          .copyWith(color: s.inkSecondary),
                    ),
                  ),
                ],
              ),
            )
          else
            for (final row in rows)
              _DeviceRowTile(
                row: row,
                isSelected: row.fingerprint != null &&
                    row.fingerprint == widget.selected?.fingerprint,
                liquidWanted: widget.liquidWanted,
                busy: _identifying,
                onTap: () {
                  final device = row.device;
                  if (device != null) {
                    widget.onSelect(device);
                  } else if (row.usable && !_identifying) {
                    _identify();
                  }
                },
              ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.cardPadding,
                0,
                AppSpacing.cardPadding,
                AppSpacing.cardPadding,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline_rounded, size: 16, color: s.danger),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      _error!,
                      style: AppTypography.bodySmall.copyWith(color: s.danger),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _DeviceRowTile extends StatelessWidget {
  const _DeviceRowTile({
    required this.row,
    required this.isSelected,
    required this.liquidWanted,
    required this.busy,
    required this.onTap,
  });

  final DeviceRow row;
  final bool isSelected;
  final bool liquidWanted;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final usable = row.usable;

    return InkWell(
      onTap: usable && !busy ? onTap : null,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.cardPadding),
        decoration: BoxDecoration(
          color: isSelected ? s.accentSoft : Colors.transparent,
          border: Border(top: BorderSide(color: s.edge)),
        ),
        child: Row(
          children: [
            // Selection affordance: a real radio for the devices that can be
            // chosen, an icon for the ones that cannot.
            if (usable)
              Icon(
                isSelected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 20,
                color: isSelected ? s.accent : s.inkFaint,
              )
            else
              Icon(Icons.block_rounded, size: 20, color: s.inkFaint),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          row.model,
                          style: AppTypography.sectionTitle.copyWith(
                            color: usable ? s.ink : s.inkFaint,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      if (row.isIdentified)
                        const StatusBadge(
                          label: 'ready',
                          variant: BadgeVariant.success,
                          dot: true,
                        )
                      else if (usable)
                        const StatusBadge(
                          label: 'connected',
                          variant: BadgeVariant.neutral,
                          dot: true,
                        )
                      else
                        const StatusBadge(
                          label: 'not usable here',
                          variant: BadgeVariant.warning,
                        ),
                      const SizedBox(width: AppSpacing.xs),
                      // What this device can hold, said before it is chosen.
                      if (usable)
                        StatusBadge(
                          label: row.supportsLiquid ? 'BTC + Liquid' : 'BTC only',
                          variant: row.supportsLiquid
                              ? BadgeVariant.accent
                              : (liquidWanted
                                  ? BadgeVariant.warning
                                  : BadgeVariant.neutral),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _subtitle(),
                    style: AppTypography.monoSmall.copyWith(color: s.inkFaint),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _subtitle() {
    final parts = <String>[];
    if (row.isIdentified) {
      parts.add('fingerprint ${row.fingerprint}');
    } else if (row.usable) {
      // Worth naming the slower route, because it is the one that asks for an
      // install and takes seconds rather than milliseconds.
      parts.add(row.drivable ? 'tap to identify' : 'tap to identify via HWI');
    } else {
      parts.add('needs the HWI helper — $hwiUnavailableHere');
    }
    if (row.usbId != null) parts.add(row.usbId!);
    parts.add(row.transport);
    return parts.join('  ·  ');
  }
}
