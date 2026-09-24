import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';

import 'app_layout.dart';

export 'app_layout.dart';

abstract final class AppSpacing {
  static const double xs = 4.0;
  static const double sm = 8.0;
  static const double md = 12.0;
  static const double lg = 16.0;
  static const double xl = 24.0;
  static const double xxl = 32.0;
  static const double xxxl = 48.0;
  static const double huge = 64.0;

  // Card / container padding
  static const double cardPadding = 20.0;
  static const double cardPaddingSmall = 14.0;

  // Border radius
  static const double radiusSm = 6.0;
  static const double radiusMd = 10.0;
  static const double radiusLg = 14.0;
  static const double radiusXl = 20.0;

  // Phone control metrics (owner's spec, 2026-09-06). Nothing on a desktop
  // path reads these: there the controls keep radiusSm/radiusMd and their
  // own heights.
  /// A filled phone button.
  static const double phoneControlHeight = 54.0;

  /// A phone text field. Above [AppLayout.minTouchTarget] by design.
  static const double phoneFieldHeight = 56.0;

  /// The corner of a filled phone control. Fields use [radiusLg] (14).
  static const double radiusPhoneControl = 16.0;

  // Sidebar
  static const double sidebarWidth = 220.0;
  static const double sidebarWidthCollapsed = 60.0;

  /// Page padding for the window at hand: [lg] on a phone (under 600 dp),
  /// [xl] on a small tablet (under 905 dp), the desktop [xxl] above that.
  /// Phone predicate — see [AppLayout.isPhone]; re-exported here so a screen
  /// that already imports the spacing tokens needs nothing else.
  static bool isPhone(BuildContext context) => AppLayout.isPhone(context);

  static double pagePadding(BuildContext context) {
    // Desktop windows are floored at 1024 px by every runner, so the answer
    // is a constant there — and skipping MediaQuery avoids rebuilding every
    // screen on each window-resize frame.
    if (!Platform.isAndroid && !Platform.isIOS) return xxl;
    final width = MediaQuery.sizeOf(context).width;
    if (width < 600) return lg;
    if (width < 905) return xl;
    return xxl;
  }
}
