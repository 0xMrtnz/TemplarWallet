import 'package:flutter/material.dart';

abstract final class AppColors {
  // Primary accent — Templar crimson, the heraldic red of the cross in the
  // brand mark. Runtime-mutable so the user-picked wallet accent flows through
  // the whole UI. Variants are derived from the base accent so a single
  // [applyAccent] call re-tints every surface that reads these getters.
  static const Color accentDefault = Color(0xFFC1121F);
  static Color _accent = accentDefault;

  static Color get accent => _accent;
  static Color get accentLight =>
      HSLColor.fromColor(_accent).withSaturation(0.85).withLightness(0.93).toColor();
  static Color get accentMuted =>
      HSLColor.fromColor(_accent).withLightness(0.70).toColor();
  static Color get accentDark =>
      HSLColor.fromColor(_accent).withLightness(0.42).toColor();

  /// Re-tint the whole app. Pass null to fall back to the brand default.
  static void applyAccent(Color? c) {
    _accent = (c ?? accentDefault).withAlpha(0xFF);
  }

  // Success / synced — green
  static const Color success = Color(0xFF16A34A);
  static const Color successLight = Color(0xFFDCFCE7);
  static const Color successMuted = Color(0xFF4ADE80);

  // Warning — yellow / orange
  static const Color warning = Color(0xFFD97706);
  static const Color warningLight = Color(0xFFFEF3C7);
  static const Color warningMuted = Color(0xFFFBBF24);

  // Danger — red. The brand accent is ALSO red, so these two are kept apart on
  // lightness, not hue: the accent is deep (L~41%) and destructive is bright
  // (L~60%). Never darken this toward the accent or a delete button becomes
  // indistinguishable from a primary one. Destructive controls should also
  // carry an icon or an explicit verb, never colour alone.
  static const Color danger = Color(0xFFEF4444);
  static const Color dangerLight = Color(0xFFFEE2E2);
  static const Color dangerMuted = Color(0xFFF87171);

  // ── Chain brand colors ────────────────────────────────────────────────────
  // Liquid — teal-green. Every Liquid asset/tag uses this.
  static const Color liquid = Color(0xFF0E8E8E);
  static const Color liquidLight = Color(0xFFDDF1F0);
  static const Color liquidMuted = Color(0xFF4DB6AC);
  static const Color liquidDark = Color(0xFF0A6E6E);

  // Bitcoin — orange. Every BTC asset/tag uses this.
  static const Color bitcoin = Color(0xFFF7931A);
  static const Color bitcoinLight = Color(0xFFFFF1DE);
  static const Color bitcoinMuted = Color(0xFFFFB74D);
  static const Color bitcoinDark = Color(0xFFB76E00);

  // Neutrals — light theme
  //
  // Neutral grey, not blush. The page is a shade of grey and cards are pure
  // white, so a panel is visible as a panel without needing a shadow; the old
  // near-white pink page left white cards floating on nothing. Borders and
  // secondary ink are two steps darker than the Tailwind defaults they came
  // from — at 14px on a bright screen the old #E5E7EB hairline and #6B7280
  // caption simply were not there.
  static const Color backgroundLight = Color(0xFFF1F3F6);
  static const Color surfaceLight = Color(0xFFFFFFFF);
  static const Color borderLight = Color(0xFFD3D8E0);
  static const Color borderMuted = Color(0xFFE6E9EE);
  static const Color textPrimary = Color(0xFF0E1116);
  static const Color textSecondary = Color(0xFF485260);
  static const Color textMuted = Color(0xFF69737F);
  static const Color tableHeader = Color(0xFFE9ECF1);

  // Neutrals — dark theme
  //
  // Black, and neutral. The wallet's ground is #000 — not a dark crimson —
  // so the crimson accent is the only red on screen and reads as signal
  // instead of wallpaper. Surfaces step up in near-neutral greys.
  static const Color backgroundDark = Color(0xFF000000);
  static const Color surfaceDark = Color(0xFF0E0E11);
  static const Color surfaceDark2 = Color(0xFF17171B);
  static const Color borderDark = Color(0xFF2A2A30);
  static const Color textPrimaryDark = Color(0xFFF9FAFB);
  static const Color textSecondaryDark = Color(0xFFA3A9B4);
  static const Color textMutedDark = Color(0xFF767C86);
  static const Color tableHeaderDark = Color(0xFF131317);

  // Sidebar
  static const Color sidebarBg = Color(0xFF08080A);
  static const Color sidebarBorder = Color(0xFF232329);
  static Color get sidebarActiveItem => _accent;
  static Color get sidebarActiveItemBg =>
      HSLColor.fromColor(_accent).withSaturation(0.55).withLightness(0.27).toColor();
  static const Color sidebarText = Color(0xFF9CA3AF);
  static const Color sidebarTextActive = Color(0xFFFFFFFF);

  // Code / descriptor boxes
  static const Color codeBoxBg = Color(0xFFEDF0F4);
  static const Color codeBoxBgDark = Color(0xFF121216);
  static const Color codeBoxBorder = Color(0xFFCBD2DC);
  static const Color codeBoxBorderDark = Color(0xFF2E2E35);

  // Glassmorphism surfaces
  static const Color glassDark = Color(0x1AFFFFFF);   // 10% white
  static const Color glassLight = Color(0xB3FFFFFF);  // 70% white
  static const Color glassBorderDark = Color(0x33FFFFFF);   // 20% white
  static const Color glassBorderLight = Color(0x80FFFFFF);  // 50% white

  // Gradient stops for the hero background — black in dark, neutral in light.
  static const List<Color> heroBgGradientDark = [
    Color(0xFF000000),
    Color(0xFF060608),
    Color(0xFF0B0B0E),
  ];
  static const List<Color> heroBgGradientLight = [
    Color(0xFFE9ECF1),
    Color(0xFFF4F6F8),
    Color(0xFFFFFFFF),
  ];
}
