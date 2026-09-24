import 'package:flutter/material.dart';

import 'app_colors.dart';

/// Resolved color scheme — the hybrid design language (Obsidian glass shell ×
/// Instrument data grammar), resolved once per build via [AppScheme.of].
///
/// Screens read `final s = AppScheme.of(context);` instead of branching on
/// `Theme.of(context).brightness` at every call site. Accent-derived values
/// route through the runtime-mutable [AppColors.accent] family, so per-wallet
/// re-tinting keeps working (never use these in const contexts).
class AppScheme {
  const AppScheme._(this.isDark);
  final bool isDark;

  static AppScheme of(BuildContext context) =>
      AppScheme._(Theme.of(context).brightness == Brightness.dark);

  // ── Backdrop ────────────────────────────────────────────────────────────────
  /// Page gradient for the entry screens ONLY (home picker, welcome). Every
  /// surface inside an open wallet is flat — see `PageBackground.flat`.
  ///
  /// Neutral, not accent-derived. The ground used to be a wash of the brand
  /// crimson, which meant the app's one signal colour was also its wallpaper —
  /// nothing could stand out against it, and every wallet the user re-tinted
  /// repainted the whole room. Dark is black with a two-step lift for depth;
  /// light is grey to white. Brand now lives only where it means something:
  /// the mark, the accent rule, the active state.
  List<Color> get bgGradient => isDark
      ? const [Color(0xFF000000), Color(0xFF060608), Color(0xFF0B0B0E)]
      : const [Color(0xFFE9ECF1), Color(0xFFF4F6F8), Color(0xFFFFFFFF)];

  /// Flat page fill used everywhere inside a wallet.
  Color get canvas =>
      isDark ? AppColors.backgroundDark : AppColors.backgroundLight;

  // ── Cards ──────────────────────────────────────────────────────────────────
  // Two steps of the SAME translucent surface, shared by the home gallery and
  // the sidebar so both read as one material. Never gradients: the brand
  // gradient has to keep showing through, and an opaque fill would chop it
  // into blocks.
  //
  // There is deliberately no alternating tone. A checkerboard made half the
  // cards look disabled next to the other half.

  Color get cardBase => isDark
      ? Colors.white.withValues(alpha: 0.075)
      : Colors.white.withValues(alpha: 0.88);

  /// The card under the pointer — the same surface, one step firmer.
  Color get cardHover => isDark
      ? Colors.white.withValues(alpha: 0.14)
      : Colors.white.withValues(alpha: 1.0);

  /// Soft accent bloom behind the backdrop (decorative only). Kept faint —
  /// the ground is black now, and a bloom that reads as a colour would put the
  /// brand wash straight back.
  Color get bloom => AppColors.accent.withValues(alpha: isDark ? 0.07 : 0.06);

  // ── Surfaces ────────────────────────────────────────────────────────────────
  /// Translucent panel fill — page gradient bleeds through (glass shell).
  Color get surfaceGlass =>
      isDark ? const Color(0x1CFFFFFF) : const Color(0xF2FFFFFF);

  /// Specular top-edge gradient stops for glass panels.
  List<Color> get specular => isDark
      ? const [Color(0x17FFFFFF), Color(0x05FFFFFF)]
      : const [Color(0xBFFFFFFF), Color(0x66FFFFFF)];

  /// Data well — high-opacity backing behind critical data (guardrail: WCAG AA
  /// for addresses/amounts/descriptors). Never make this translucent.
  Color get surfaceSolid =>
      isDark ? const Color(0xF50E0E11) : const Color(0xFFFFFFFF);

  /// Raised strips: panel headers, table heads.
  Color get surfaceRaised =>
      isDark ? const Color(0xFF1B1B21) : const Color(0xFFEAEDF2);

  /// Zebra row tint inside panels/tables.
  Color get zebra => isDark ? const Color(0x14FFFFFF) : const Color(0xFFF4F6F9);

  // ── Panels on a flat ground (phone) ────────────────────────────────────────
  //
  // Inside a wallet on a phone every surface sits on the flat [canvas], so a
  // translucent fill has nothing to let through and a gradient over one hides
  // it: a `BoxDecoration` paints its gradient *instead of* its colour, which
  // is how the hero ended up near-black on a black ground. These are the
  // composited results — two steps and no more (see design.md).

  /// The card: [surfaceGlass] already resolved against the page.
  Color get panel => Color.alphaBlend(surfaceGlass, canvas);

  /// One step above [panel] — the tile an icon sits on inside a card, the
  /// well behind a figure. Never a third step.
  Color get panelInset =>
      isDark ? const Color(0xFF26262C) : const Color(0xFFEBEEF3);

  /// The one tone BELOW [panel]: the phone's navigation bar. Chrome recedes
  /// (design.md), so the bar sits under the cards rather than over them —
  /// and it is a surface, not a hole: on an OLED ground a translucent black
  /// bar left the icons floating with nothing under them.
  Color get chrome =>
      isDark ? const Color(0xFF121216) : const Color(0xFFF7F8FA);

  /// Hover row tint (Instrument grammar).
  Color get hover => AppColors.accent.withValues(alpha: isDark ? 0.09 : 0.07);

  // Dark-mode note: every surface and stroke above sits one step brighter
  // than it did. On an OLED-black ground a 5%-white card and a 14%-white
  // hairline were within a hair of the page itself — panels had no visible
  // edge, table rules disappeared, and the whole shell read as one flat black
  // sheet. Light mode is unchanged; it never had the problem.

  // ── Strokes ─────────────────────────────────────────────────────────────────
  // Hairlines carry the whole layout in light mode — every panel edge, table
  // rule and quiet button outline is one of these. The previous blush pair
  // (#F0E2E3 / #E6C9CB) was under a 1.2:1 ratio against white and vanished on
  // a bright screen, so they are neutral and two steps darker now.
  Color get edge => isDark ? const Color(0x33FFFFFF) : const Color(0xFFD5DAE2);
  Color get edgeBright =>
      isDark ? const Color(0x5CFFFFFF) : const Color(0xFFFFFFFF);
  Color get edgeStrong =>
      isDark ? const Color(0xFF4A4A54) : const Color(0xFFB3BBC7);

  // ── Ink ─────────────────────────────────────────────────────────────────────
  // Light-mode ink is darker across the board: #6E5A5C secondary text on a
  // near-white card was ~4.0:1 and #9C8A8C captions ~2.6:1 — under AA for body
  // copy. These clear AA (>=4.5:1) for secondary and land close to it for the
  // faint tier, which is only ever used for non-essential labels.
  Color get ink => isDark ? const Color(0xFFF6F7F9) : const Color(0xFF0E1116);
  Color get inkSecondary =>
      isDark ? const Color(0xFFB6BCC6) : const Color(0xFF454E5B);
  Color get inkFaint =>
      isDark ? const Color(0xFF8B929D) : const Color(0xFF69737F);

  // ── Status / network / chain (theme-stable, re-exported for one-stop use) ──
  // Light-mode status colours are darkened from the raw brand values: the
  // #EF4444 danger and #16A34A success read fine as fills but fail as text on
  // white, and status here is often a caption.
  Color get success => isDark ? const Color(0xFF3DD68C) : const Color(0xFF15803D);
  Color get warning => isDark ? const Color(0xFFE5B454) : const Color(0xFFB45309);
  Color get danger => isDark ? const Color(0xFFF06A6A) : const Color(0xFFD32020);
  Color get testnet => isDark ? const Color(0xFFE5B454) : const Color(0xFFB45309);
  Color get bitcoin => AppColors.bitcoin;
  Color get liquid => isDark ? const Color(0xFF35B8B0) : AppColors.liquid;

  // ── Accent (runtime-mutable — never const) ─────────────────────────────────
  Color get accent => AppColors.accent;
  Color get accentSoft => AppColors.accent.withValues(alpha: isDark ? 0.16 : 0.12);
  Color get accentGlow => AppColors.accent.withValues(alpha: isDark ? 0.32 : 0.22);

  // ── Shadows ─────────────────────────────────────────────────────────────────
  List<BoxShadow> get panelShadow => [
        BoxShadow(
          color: Colors.black.withValues(alpha: isDark ? 0.55 : 0.10),
          blurRadius: 22,
          offset: const Offset(0, 9),
        ),
      ];
}
