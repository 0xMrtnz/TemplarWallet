import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';

/// Renders a circular logo for a given asset ticker.
///   BTC          → orange circle with ₿  (on-chain Bitcoin)
///   LBTC / L-BTC → teal circle with ₿    (Liquid Bitcoin — pegged, so ₿ in teal)
///   other tokens → teal circle with the Liquid water-drop logo
/// A reissuance token reuses its parent's logo wrapped in a dashed outline ring.
class AssetLogo extends StatelessWidget {
  const AssetLogo({
    super.key,
    required this.ticker,
    this.size = 36,
    this.isReissuanceToken = false,
  });

  final String ticker;
  final double size;

  /// When true, draws the parent logo inside a dashed ring to signal a
  /// derived (reissuance) token. Pass the *parent* ticker as [ticker].
  final bool isReissuanceToken;

  @override
  Widget build(BuildContext context) {
    if (!isReissuanceToken) return _logo(size);

    // Dashed ring around a slightly inset parent logo.
    final inner = size * 0.72;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _DashedRingPainter(color: AppColors.liquid),
        child: Center(child: _logo(inner)),
      ),
    );
  }

  Widget _logo(double s) {
    final t = ticker.toUpperCase();
    if (t == 'BTC') {
      // On-chain Bitcoin → orange bitcoin logo.
      return _circle(s, AppColors.bitcoin, child: _btcSymbol(s));
    }
    if (t == 'LBTC' || t == 'L-BTC') {
      // Liquid Bitcoin is pegged to BTC → bitcoin logo, but tinted teal.
      return _circle(s, AppColors.liquid, child: _btcSymbol(s));
    }
    // Every other Liquid token → liquid teal logo (water drop).
    return _circle(s, AppColors.liquid,
        child: Icon(Icons.water_drop, size: s * 0.46, color: Colors.white));
  }

  static Widget _circle(double size, Color bg, {required Widget child}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      child: Center(child: child),
    );
  }

  static Widget _btcSymbol(double size) {
    return Text(
      '₿',
      style: TextStyle(
        fontSize: size * 0.52,
        fontWeight: FontWeight.w900,
        color: Colors.white,
        height: 1,
      ),
    );
  }
}

/// Paints a dashed circular ring (used to mark reissuance-token logos).
class _DashedRingPainter extends CustomPainter {
  _DashedRingPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;

    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - paint.strokeWidth;
    const dashCount = 14;
    const gapFraction = 0.45; // portion of each segment that is a gap
    final sweep = (2 * 3.1415926535) / dashCount;
    for (var i = 0; i < dashCount; i++) {
      final start = i * sweep;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        start,
        sweep * (1 - gapFraction),
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_DashedRingPainter old) => old.color != color;
}

/// Wallet-type icon used in the wallet picker grid.
class WalletTypeIcon extends StatelessWidget {
  const WalletTypeIcon({super.key, required this.type, this.size = 40});

  final String type;
  final double size;

  @override
  Widget build(BuildContext context) {
    final (icon, bg, fg) = switch (type.toLowerCase()) {
      'multisig' => (Icons.group_outlined, AppColors.accentLight, AppColors.accentDark),
      'watch-only' || 'watchonly' || 'watch_only' => (Icons.visibility_outlined, const Color(0xFFE8EAF6), const Color(0xFF5C6BC0)),
      _ => (Icons.key_outlined, AppColors.accentLight, AppColors.accentDark),
    };
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(size * 0.28)),
      child: Center(child: Icon(icon, size: size * 0.52, color: fg)),
    );
  }
}
