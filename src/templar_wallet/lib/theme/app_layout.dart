import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';

/// Where the app runs and how much room a screen has.
///
/// The desktop runners floor their windows at 1024 px, so on macOS, Linux and
/// Windows every predicate here is a constant and the desktop layouts are
/// untouched; only Android and iOS ever answer "phone". Screens branch on
/// [isPhone] for the single-column, stacked, sheet-instead-of-dialog layouts.
abstract final class AppLayout {
  /// Width below which a window is a phone (Material's "compact" class).
  static const double phoneMaxWidth = 600;

  /// Width below which a window is a small tablet ("medium" class).
  static const double tabletMaxWidth = 905;

  /// Smallest thing a finger can hit reliably, per side.
  static const double minTouchTarget = 48;

  /// Android or iOS: the mobile shell, touch input, no hover.
  static final bool isMobilePlatform = Platform.isAndroid || Platform.isIOS;

  /// A phone-sized window on a mobile platform. Also true on a tablet held
  /// narrow enough; false on every desktop window by construction.
  static bool isPhone(BuildContext context) =>
      isMobilePlatform && MediaQuery.sizeOf(context).width < phoneMaxWidth;

  /// A phone-sized window on any platform — for the rare widget that should
  /// also stack in a narrow desktop pane. Prefer [isPhone] for everything
  /// that must leave the desktop alone.
  static bool isCompact(BuildContext context) =>
      MediaQuery.sizeOf(context).width < phoneMaxWidth;

  /// Longest side of a QR code that fits a phone comfortably: the content
  /// column, capped so a big module count still scans at arm's length.
  static double qrSide(BuildContext context, {double max = 280}) {
    final w = MediaQuery.sizeOf(context).width;
    return (w - 2 * _pagePaddingFor(w) - 2 * 20).clamp(160.0, max);
  }

  static double _pagePaddingFor(double width) {
    if (width < phoneMaxWidth) return 16;
    if (width < tabletMaxWidth) return 24;
    return 32;
  }
}
