import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'app_colors.dart';
import 'app_layout.dart';

// Primary font : IBM Plex Sans  — body, labels, numbers, buttons
// Display font : Nunito         — headlines and key titles
// Mono font    : IBM Plex Mono  — descriptors, txids, fingerprints

abstract final class AppTypography {
  // ---------------------------------------------------------------------------
  // Balance / large numeric display
  // ---------------------------------------------------------------------------

  /// Hero balance (dashboard) — Nunito rounds the numbers beautifully.
  static TextStyle get balanceHero => GoogleFonts.nunito(
        fontSize: 44,
        fontWeight: FontWeight.w700,
        letterSpacing: -1.0,
        height: 1.1,
      );

  static TextStyle get balanceLarge => GoogleFonts.nunito(
        fontSize: 32,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
        height: 1.2,
      );

  /// Secondary / asset balances — IBM Plex Sans for digit clarity.
  static TextStyle get balanceMedium => GoogleFonts.ibmPlexSans(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.3,
      );

  // ---------------------------------------------------------------------------
  // Page titles & section headers — Nunito for warmth
  // ---------------------------------------------------------------------------

  static TextStyle get pageTitle => GoogleFonts.nunito(
        fontSize: 26,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
        height: 1.2,
      );

  /// Gallery display headline — the home screen's voice. Large and tightly
  /// tracked: negative letter-spacing is what makes a headline read as a
  /// framed label rather than as UI text.
  static TextStyle get displayTitle => GoogleFonts.nunito(
        fontSize: 34,
        fontWeight: FontWeight.w800,
        letterSpacing: -1.2,
        height: 1.1,
      );

  /// A single exhibit's headline — one wallet's name on the index.
  static TextStyle get galleryTitle => GoogleFonts.nunito(
        fontSize: 23,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.7,
        height: 1.15,
      );

  /// Small wide-tracked eyebrow above a gallery section.
  static TextStyle get gallerySection => GoogleFonts.ibmPlexSans(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.6,
      );

  static TextStyle get sectionTitle => GoogleFonts.nunito(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.1,
        height: 1.3,
      );

  // ---------------------------------------------------------------------------
  // Body / subtitles — IBM Plex Sans
  // ---------------------------------------------------------------------------

  static TextStyle get bodyLarge => GoogleFonts.ibmPlexSans(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        height: 1.55,
      );

  static TextStyle get body => GoogleFonts.ibmPlexSans(
        fontSize: 15,
        fontWeight: FontWeight.w400,
        height: 1.55,
      );

  static TextStyle get bodySmall => GoogleFonts.ibmPlexSans(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        height: 1.45,
      );

  static TextStyle get caption => GoogleFonts.ibmPlexSans(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        height: 1.45,
        color: AppColors.textSecondary,
      );

  static TextStyle get label => GoogleFonts.ibmPlexSans(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.2,
      );

  // ---------------------------------------------------------------------------
  // Sidebar navigation
  // ---------------------------------------------------------------------------

  static TextStyle get navItem => GoogleFonts.ibmPlexSans(
        fontSize: 14,
        fontWeight: FontWeight.w500,
      );

  static TextStyle get navSection => GoogleFonts.ibmPlexSans(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.0,
      );

  // ---------------------------------------------------------------------------
  // Monospaced — descriptors, fingerprints, txids
  // ---------------------------------------------------------------------------

  static TextStyle get mono => GoogleFonts.ibmPlexMono(
        fontSize: 13,
        fontWeight: FontWeight.w400,
        height: 1.6,
        letterSpacing: 0.2,
      );

  static TextStyle get monoSmall => GoogleFonts.ibmPlexMono(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        height: 1.5,
        letterSpacing: 0.1,
      );

  static TextStyle get monoLarge => GoogleFonts.ibmPlexMono(
        fontSize: 15,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.3,
      );

  // ---------------------------------------------------------------------------
  // Numeric — tabular figures so columns of amounts/fees align.
  // Use for any number that sits in a table, list, or summary row.
  // ---------------------------------------------------------------------------

  static const List<FontFeature> _tabular = [FontFeature.tabularFigures()];

  static TextStyle get numeric => GoogleFonts.ibmPlexSans(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        fontFeatures: _tabular,
        letterSpacing: 0,
      );

  static TextStyle get numericSmall => GoogleFonts.ibmPlexSans(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        fontFeatures: _tabular,
        letterSpacing: 0,
      );

  static TextStyle get numericLarge => GoogleFonts.ibmPlexSans(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        fontFeatures: _tabular,
        letterSpacing: -0.3,
      );

  // ---------------------------------------------------------------------------
  // Wizard / onboarding
  // ---------------------------------------------------------------------------

  static TextStyle get stepIndicator => GoogleFonts.ibmPlexSans(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.4,
      );

  // ---------------------------------------------------------------------------
  // Phone-scaled variants. The large styles above were drawn for a >= 1024 px
  // window; on a phone ([AppLayout.isPhone]) the same voice at a size that
  // leaves room for content. Desktop callers get the plain getter unchanged,
  // so switching a call site to the *Of form never moves a desktop pixel.
  // ---------------------------------------------------------------------------

  static TextStyle balanceHeroOf(BuildContext context) =>
      AppLayout.isPhone(context)
          ? balanceHero.copyWith(fontSize: 36, letterSpacing: -0.8)
          : balanceHero;

  static TextStyle balanceLargeOf(BuildContext context) =>
      AppLayout.isPhone(context)
          ? balanceLarge.copyWith(fontSize: 26, letterSpacing: -0.4)
          : balanceLarge;

  static TextStyle balanceMediumOf(BuildContext context) =>
      AppLayout.isPhone(context)
          ? balanceMedium.copyWith(fontSize: 19)
          : balanceMedium;

  static TextStyle pageTitleOf(BuildContext context) =>
      AppLayout.isPhone(context)
          ? pageTitle.copyWith(fontSize: 22, letterSpacing: -0.2)
          : pageTitle;

  static TextStyle displayTitleOf(BuildContext context) =>
      AppLayout.isPhone(context)
          ? displayTitle.copyWith(fontSize: 28, letterSpacing: -0.9)
          : displayTitle;

  static TextStyle galleryTitleOf(BuildContext context) =>
      AppLayout.isPhone(context)
          ? galleryTitle.copyWith(fontSize: 19, letterSpacing: -0.5)
          : galleryTitle;

  static TextStyle sectionTitleOf(BuildContext context) =>
      AppLayout.isPhone(context)
          ? sectionTitle.copyWith(fontSize: 16)
          : sectionTitle;

  static TextStyle numericLargeOf(BuildContext context) =>
      AppLayout.isPhone(context)
          ? numericLarge.copyWith(fontSize: 19)
          : numericLarge;
}
