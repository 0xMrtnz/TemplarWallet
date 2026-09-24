// Privacy mask — one switch that blanks every coin amount and fiat value on
// screen, for using the wallet in public.
//
// It is a *display* mask and nothing more: the amounts are still loaded, still
// used for fee maths, still exported. Anything that hides real numbers has to
// be obviously reversible, so the control is a single eye that shows its state
// (open = visible, struck-through = hidden) and lives next to the balance it
// covers rather than buried in Settings.
//
// It covers HOLDINGS — what you own: the net-worth hero, asset cards, coin
// amounts, activity rows. It deliberately does NOT cover the amount you are
// composing or about to sign (send wizard, swap legs, PSBT/PSET review). Those
// numbers are the thing being authorised; a wallet that lets you sign "••••••"
// has traded a shoulder-surfing risk for a spend-the-wrong-amount one.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/app_state.dart';
import '../../theme/app_motion.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';

/// The stand-in for a masked number. Bullets, not a fixed-width blur: it reads
/// as "withheld" at a glance and never suggests a real digit count.
const String kMaskedAmount = '••••••';

/// True when the privacy mask is on. Subscribes the caller to changes.
bool balancesHidden(BuildContext context) =>
    context.select<AppState, bool>((s) => s.balancesHidden);

/// [text] as it should be rendered right now — the value, or bullets while the
/// mask is on. Use for every amount, balance and fiat figure.
String maskAmount(BuildContext context, String text) =>
    balancesHidden(context) ? kMaskedAmount : text;

/// Nullable variant: a null value stays null (nothing to draw either way).
String? maskAmountOrNull(BuildContext context, String? text) =>
    text == null ? null : maskAmount(context, text);

/// A masked amount as a widget.
///
/// Prefer this over `Text(maskAmount(context, …))`: the lookup happens in this
/// widget's own `build`, so it is safe inside `AnimatedBuilder`/`LayoutBuilder`
/// callbacks, where calling `context.select` against the enclosing element
/// throws ("Tried to use `context.select` outside of the `build` method").
class Amount extends StatelessWidget {
  const Amount(
    this.text, {
    super.key,
    this.style,
    this.overflow,
    this.maxLines,
    this.textAlign,
  });

  final String text;
  final TextStyle? style;
  final TextOverflow? overflow;
  final int? maxLines;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) => Text(
    maskAmount(context, text),
    style: style,
    overflow: overflow,
    maxLines: maxLines,
    textAlign: textAlign,
  );
}

/// The eye. Open when amounts are visible, struck through when they are
/// hidden — the icon always shows the *current* state, not the action, so the
/// screen can be read at a glance.
///
/// On a phone the hit area is a 48 dp square around a slightly larger glyph;
/// on desktop it stays the 4 dp-padded icon it always was.
class PrivacyToggle extends StatelessWidget {
  const PrivacyToggle({super.key, this.size = 18, this.color});

  final double size;

  /// Overrides the resolved ink colour (e.g. on a tinted hero).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final hidden = balancesHidden(context);
    final tint = color ?? (hidden ? s.accent : s.inkSecondary);
    final phone = AppLayout.isPhone(context);

    final icon = AnimatedSwitcher(
      duration: AppMotion.of(context, AppMotion.quick),
      transitionBuilder: (child, anim) =>
          FadeTransition(opacity: anim, child: child),
      child: Icon(
        hidden ? Icons.visibility_off_outlined : Icons.visibility_outlined,
        key: ValueKey(hidden),
        size: phone ? math.max(size, 22) : size,
        color: tint,
      ),
    );

    return Tooltip(
      message: hidden ? 'Show amounts' : 'Hide amounts',
      child: InkWell(
        onTap: () => context.read<AppState>().toggleBalancesHidden(),
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        child: phone
            ? SizedBox.square(
                dimension: AppLayout.minTouchTarget,
                child: Center(child: icon),
              )
            : Padding(
                padding: const EdgeInsets.all(AppSpacing.xs),
                child: icon,
              ),
      ),
    );
  }
}
