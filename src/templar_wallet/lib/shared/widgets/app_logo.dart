import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';

/// App brand mark — the Templar cross on the dark brand squircle.
///
/// Renders `assets/images/templar-wallet-logo.png`, falling back to an
/// accent-tinted hexagon if the asset is ever missing so the app still builds.
///
/// Both that PNG and the platform app icons are BUILD PRODUCTS of
/// `assets/brand/templar-icon.svg` — edit the SVG, then run
/// `./scripts/generate_icons.sh`. Do not hand-edit the rasters.
/// `assets/images/templar-cross.svg` is the bare mark (no squircle) for places
/// that need the cross on its own.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 40, this.radius});

  final double size;
  final double? radius;

  @override
  Widget build(BuildContext context) {
    final r = radius ?? size * 0.25;
    // No ClipRRect: the PNG carries its own squircle with transparent corners,
    // and clipping it again shaved a second, tighter radius off the artwork.
    return Image.asset(
      'assets/images/templar-wallet-logo.png',
      width: size,
      height: size,
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) => _fallback(r),
    );
  }

  Widget _fallback(double r) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.accent, AppColors.accentDark],
        ),
        borderRadius: BorderRadius.circular(r),
      ),
      child: Icon(Icons.hexagon, color: Colors.white, size: size * 0.58),
    );
  }
}
