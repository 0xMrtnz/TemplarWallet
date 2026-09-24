import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'app_colors.dart';
import 'app_motion.dart';
import 'app_scheme.dart';
import 'app_spacing.dart';

abstract final class AppTheme {
  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  // ── The phone overlay ─────────────────────────────────────────────────────
  //
  // [_build] is context-free — one ThemeData for every platform — so the
  // phone's controls are laid over the resolved theme instead, from
  // `MaterialApp(builder: AppTheme.phoneBuilder)`. Every route, dialog and
  // sheet is a descendant of what the builder wraps, so one wiring line
  // reaches every field and every raw Material button in the app. Off a
  // phone it returns the child untouched, so desktop renders exactly the
  // theme above.

  /// Wire as `MaterialApp(builder: AppTheme.phoneBuilder)`.
  static Widget phoneBuilder(BuildContext context, Widget? child) {
    final c = child ?? const SizedBox.shrink();
    if (!AppLayout.isPhone(context)) return c;
    return Theme(data: _phone(context), child: c);
  }

  static OutlineInputBorder _phoneField(BorderSide side) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
        borderSide: side,
      );

  static ThemeData _phone(BuildContext context) {
    final base = Theme.of(context);
    final s = AppScheme.of(context);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppSpacing.radiusPhoneControl),
    );
    const tall = Size(64.0, AppSpacing.phoneControlHeight);
    return base.copyWith(
      // Fields: filled grey, no border at rest, an accent ring on focus.
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: s.panelInset,
        constraints:
            const BoxConstraints(minHeight: AppSpacing.phoneFieldHeight),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.lg,
        ),
        border: _phoneField(BorderSide.none),
        enabledBorder: _phoneField(BorderSide.none),
        disabledBorder: _phoneField(BorderSide.none),
        focusedBorder: _phoneField(BorderSide(color: s.accent, width: 1.5)),
        errorBorder: _phoneField(BorderSide(color: s.danger, width: 1.5)),
        focusedErrorBorder:
            _phoneField(BorderSide(color: s.danger, width: 1.5)),
        hintStyle: base.inputDecorationTheme.hintStyle
            ?.copyWith(color: s.inkFaint),
      ),
      // The raw Material buttons a dialog draws take the same slab as the
      // design-system ones, so an action never sits 6 dp shorter than its
      // neighbour.
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: (base.elevatedButtonTheme.style ?? const ButtonStyle()).copyWith(
          minimumSize: const WidgetStatePropertyAll(tall),
          shape: WidgetStatePropertyAll(shape),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: (base.filledButtonTheme.style ?? const ButtonStyle()).copyWith(
          minimumSize: const WidgetStatePropertyAll(tall),
          shape: WidgetStatePropertyAll(shape),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: (base.textButtonTheme.style ?? const ButtonStyle()).copyWith(
          minimumSize: const WidgetStatePropertyAll(tall),
          shape: WidgetStatePropertyAll(shape),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: (base.outlinedButtonTheme.style ?? const ButtonStyle()).copyWith(
          minimumSize: const WidgetStatePropertyAll(tall),
          shape: WidgetStatePropertyAll(shape),
        ),
      ),
    );
  }

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;

    final colorScheme = isDark
        ? ColorScheme.dark(
            primary: AppColors.accent,
            onPrimary: Colors.white,
            secondary: AppColors.accentMuted,
            surface: AppColors.surfaceDark,
            onSurface: AppColors.textPrimaryDark,
            error: AppColors.danger,
          )
        : ColorScheme.light(
            primary: AppColors.accent,
            onPrimary: Colors.white,
            secondary: AppColors.accentMuted,
            surface: AppColors.surfaceLight,
            onSurface: AppColors.textPrimary,
            error: AppColors.danger,
          );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      // Pages fade in, fast, on every desktop — never slide in from the side.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.macOS: FadePageTransitionsBuilder(),
          TargetPlatform.windows: FadePageTransitionsBuilder(),
          TargetPlatform.linux: FadePageTransitionsBuilder(),
          TargetPlatform.android: FadePageTransitionsBuilder(),
          TargetPlatform.iOS: FadePageTransitionsBuilder(),
          TargetPlatform.fuchsia: FadePageTransitionsBuilder(),
        },
      ),
      // IBM Plex Sans as the default font for all Material widgets
      fontFamily: GoogleFonts.ibmPlexSans().fontFamily,
      textTheme: GoogleFonts.ibmPlexSansTextTheme(
        brightness == Brightness.dark
            ? ThemeData.dark().textTheme
            : ThemeData.light().textTheme,
      ),
      scaffoldBackgroundColor:
          isDark ? AppColors.backgroundDark : AppColors.backgroundLight,
      cardTheme: CardThemeData(
        color: isDark ? AppColors.surfaceDark : AppColors.surfaceLight,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          side: BorderSide(
            color: isDark ? AppColors.borderDark : AppColors.borderLight,
          ),
        ),
        margin: EdgeInsets.zero,
      ),
      dividerTheme: DividerThemeData(
        color: isDark ? AppColors.borderDark : AppColors.borderLight,
        thickness: 1,
        space: 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor:
            isDark ? AppColors.surfaceDark2 : AppColors.backgroundLight,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
          borderSide: BorderSide(
            color: isDark ? AppColors.borderDark : AppColors.borderLight,
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
          borderSide: BorderSide(
            color: isDark ? AppColors.borderDark : AppColors.borderLight,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
          borderSide: BorderSide(color: AppColors.accent, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.accent,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xl,
            vertical: AppSpacing.md,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
          ),
          textStyle: GoogleFonts.ibmPlexSans(
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.accent,
          side: BorderSide(color: AppColors.accent),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.xl,
            vertical: AppSpacing.md,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
          ),
          textStyle: GoogleFonts.ibmPlexSans(
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      // Hover on chrome. Material washes an onSurface disc under a hovered
      // IconButton and a pill under a TextButton — grey plates, the one hover
      // in the app that is not the tile grammar (design.md: chrome recedes;
      // a tile's hover steps its surface up and flashes its icon crimson).
      // So: an icon button flashes its glyph and draws nothing; a text button
      // takes the ghost tile's resting surface, squared off like the tiles.
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) return null;
            if (states.contains(WidgetState.hovered) ||
                states.contains(WidgetState.pressed)) {
              return AppColors.accent;
            }
            return null;
          }),
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.accent,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.sm,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          ),
          textStyle: GoogleFonts.ibmPlexSans(
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ).copyWith(
          overlayColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.hovered) ||
                states.contains(WidgetState.pressed)) {
              // The wallet tile's resting surface (AppScheme.cardBase), in
              // the two brightnesses this context-free theme can name.
              return isDark
                  ? Colors.white.withValues(alpha: 0.075)
                  : Colors.black.withValues(alpha: 0.05);
            }
            return Colors.transparent;
          }),
        ),
      ),
    );
  }
}
