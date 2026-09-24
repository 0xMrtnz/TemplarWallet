import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_scheme.dart';
import '../../theme/app_typography.dart';

/// `first…last` with the middle collapsed — the app's standard `12…8` shape
/// by default. Returns [value] unchanged when it is not long enough to need
/// collapsing.
String middleEllipsis(String value, {int head = 12, int tail = 8}) {
  if (value.length <= head + tail + 1) return value;
  return '${value.substring(0, head)}…${value.substring(value.length - tail)}';
}

/// Collapse [value] to at most [maxChars] characters, head-heavy (roughly
/// 60/40) so the first characters — the address type, the txid prefix — stay
/// readable. Never shows fewer than four characters at either end.
String fitMiddleEllipsis(String value, int maxChars) {
  if (value.length <= maxChars) return value;
  final keep = maxChars - 1; // the ellipsis itself
  if (keep < 8) return middleEllipsis(value, head: 4, tail: 4);
  final tail = math.max(4, (keep * 0.4).floor());
  return middleEllipsis(value, head: keep - tail, tail: tail);
}

/// Number of characters of [style] that fit in [maxWidth]. Measured on a
/// digit, so it is exact for the app's monospace faces and a fair estimate
/// for anything else — pair with an ellipsis overflow as the backstop.
int charsThatFit(BuildContext context, TextStyle style, double maxWidth) {
  const sample = '0000000000';
  final painter = TextPainter(
    text: TextSpan(text: sample, style: style),
    textDirection: TextDirection.ltr,
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final perChar = painter.width / sample.length;
  painter.dispose();
  // A zero-width glyph only happens before a font resolves; "everything
  // fits" is the harmless answer for that one frame.
  if (perChar <= 0) return 1 << 20;
  return (maxWidth / perChar).floor();
}

/// A single line that never wraps or overflows: the value is collapsed in the
/// *middle* to whatever fits the available width, so both ends of an address
/// or txid stay visible. Plain ink — use [HexText] for the highlighted ends.
///
/// Falls back to the standard `12…8` form when the width is unbounded.
class MiddleEllipsisText extends StatelessWidget {
  const MiddleEllipsisText(
    this.value, {
    super.key,
    this.style,
    this.textAlign,
  });

  final String value;
  final TextStyle? style;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final base = style ?? AppTypography.monoSmall;
    return LayoutBuilder(
      builder: (ctx, c) {
        final shown = c.hasBoundedWidth
            ? fitMiddleEllipsis(value, charsThatFit(ctx, base, c.maxWidth))
            : middleEllipsis(value);
        return Text(
          shown,
          style: base,
          textAlign: textAlign,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
        );
      },
    );
  }
}

/// Sparrow-style rendering of addresses / txids / outpoints: the first and
/// last four characters are highlighted in two distinct colors so endpoints
/// can be spot-checked at a glance, the middle stays dimmed.
///
/// With [truncate] the middle collapses to `first12…last8` (matching the
/// truncation already used across the app); with [fit] it collapses to
/// exactly what the available width holds, so a ~120 dp phone cell still
/// shows both ends. The head/tail highlights always cover the visible first
/// and last four characters.
class HexText extends StatelessWidget {
  const HexText(
    this.value, {
    super.key,
    this.truncate = false,
    this.fit = false,
    this.style,
    this.color,
    this.selectable = false,
  });

  final String value;

  /// Collapse the middle to `first12…last8` when the value is long.
  final bool truncate;

  /// Collapse the middle to whatever fits on one line of the available width
  /// (measured, so nothing is ever cut by the trailing ellipsis). Implies a
  /// single line; needs a bounded width, otherwise behaves like [truncate].
  final bool fit;

  /// Base style; defaults to [AppTypography.monoSmall].
  final TextStyle? style;

  /// Ink for the dimmed middle; defaults to the scheme's secondary ink.
  final Color? color;

  /// Render as [SelectableText] (copies the FULL value even when truncated
  /// is shown — selection covers only what is displayed, so prefer a copy
  /// button next to it for the full string).
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final base = (style ?? AppTypography.monoSmall).copyWith(
      color: color ?? s.inkSecondary,
    );

    if (fit) {
      return LayoutBuilder(
        builder: (ctx, c) => _render(
          s,
          base,
          c.hasBoundedWidth
              ? fitMiddleEllipsis(value, charsThatFit(ctx, base, c.maxWidth))
              : middleEllipsis(value),
        ),
      );
    }

    final shown = (truncate && value.length > 22)
        ? middleEllipsis(value)
        : value;
    return _render(s, base, shown);
  }

  Widget _render(AppScheme s, TextStyle base, String shown) {
    final headStyle = base.copyWith(color: s.accent, fontWeight: FontWeight.w600);
    final tailStyle = base.copyWith(color: s.bitcoin, fontWeight: FontWeight.w600);

    // Too short to decompose — plain text.
    if (shown.length <= 8) {
      return Text(shown, style: base);
    }

    final span = TextSpan(children: [
      TextSpan(text: shown.substring(0, 4), style: headStyle),
      TextSpan(text: shown.substring(4, shown.length - 4), style: base),
      TextSpan(text: shown.substring(shown.length - 4), style: tailStyle),
    ]);

    return selectable
        ? SelectableText.rich(span, maxLines: 1)
        : Text.rich(span, maxLines: 1, overflow: TextOverflow.ellipsis);
  }
}
