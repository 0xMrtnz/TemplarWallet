import 'package:flutter/material.dart';

import '../../theme/app_motion.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';

/// A wallet's mark: its kind icon, in the wallet's own colour, on a plate.
///
/// This replaced the initial-letter avatar the shell used to draw. A letter
/// carries no information the wallet name next to it doesn't already carry,
/// and two wallets starting with the same letter drew the identical badge.
/// The icon says what kind of wallet it is and the tint says which one — and
/// because the same widget is used in the home gallery and in the sidebar,
/// the wallet you picked on the wall is visibly the wallet you are now in.
class WalletPlate extends StatelessWidget {
  const WalletPlate({
    super.key,
    required this.icon,
    this.tint,
    this.size = 56,
    this.raised = false,
    this.shadow = true,
  });

  final IconData icon;

  /// The wallet's accent. Null falls back to the app accent, which is the
  /// wallet's own colour once one is open (AppState re-tints on open).
  final Color? tint;

  final double size;

  /// Lifted by 2px — the hover state in the gallery.
  final bool raised;

  /// The gallery plate is the one shadow on that screen; the sidebar copy
  /// carries none. On a phone the plate is always flat: a blur-12 shadow
  /// per gallery card on every scroll frame is a cost with no payoff on a
  /// small screen, and the port flattens decorative effects there.
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final color = tint ?? s.accent;
    final drawShadow = shadow && !AppLayout.isPhone(context);
    return AnimatedContainer(
      duration: AppMotion.of(context, AppMotion.quick),
      curve: AppMotion.settle,
      width: size,
      height: size,
      transform: Matrix4.translationValues(0, raised ? -2 : 0, 0),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: s.surfaceSolid,
        borderRadius: BorderRadius.circular(
          size >= 40 ? AppSpacing.radiusLg : AppSpacing.radiusSm,
        ),
        border: Border.all(
          color: raised ? color.withValues(alpha: 0.55) : s.edge,
        ),
        boxShadow: drawShadow
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: s.isDark ? 0.45 : 0.13),
                  blurRadius: raised ? 20 : 12,
                  offset: Offset(0, raised ? 9 : 5),
                ),
              ]
            : null,
      ),
      child: Icon(icon, size: size * 0.45, color: color),
    );
  }
}
