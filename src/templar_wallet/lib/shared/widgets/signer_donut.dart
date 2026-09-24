// Signer donut — how many of a transaction's signers have signed it, and
// the SignerChart block (donut + legend + quorum line) built on top of it.
//
// Pure presentation: it takes counts — or named slots — in and draws them.
// One arc segment per signer, grey while that signature is missing and
// coloured once it has been imported, so a PSBT coming back from a co-signer
// visibly gains a wedge. With named slots the wedge takes the co-signer's own
// colour, the one chosen for it in the wallet's key labels, so the ring here
// and the Keys ring on the dashboard mean the same thing by the same colour.
// The quorum only changes the colour of unnamed wedges — a marker for it on
// the ring landed in a seam and read as a scratch, so the threshold is stated
// in words beside the chart instead.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_motion.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';

/// One signer of a transaction, as the chart draws it.
///
/// [id] is the master fingerprint the transaction names; the rest is what
/// the wallet's labels say about it, when they say anything. A slot with no
/// [name] is shown by its fingerprint.
@immutable
class SignerSlot {
  const SignerSlot({
    required this.id,
    required this.signed,
    this.name,
    this.color,
    this.isHardware = false,
    this.isLocal = false,
  });

  final String id;
  final bool signed;
  final String? name;
  final Color? color;

  /// This key signs on a USB device — the hand-off sheet offers it.
  final bool isHardware;

  /// This app holds the key.
  final bool isLocal;

  String get label => (name?.trim().isNotEmpty ?? false) ? name!.trim() : id;
}

/// Ring of [total] signer slots, [signed] of them filled.
///
/// [requiredCount] is the quorum: reaching it turns the filled slots from the
/// in-progress accent to the success colour, and it is what the ring reports
/// to a screen reader. The centre reads `signed/total`.
///
/// With [slots] the ring is drawn in their order and each filled wedge takes
/// its slot's colour; [signed] and [total] are then read off the slots.
class SignerDonut extends StatefulWidget {
  const SignerDonut({
    super.key,
    required this.signed,
    required this.total,
    this.requiredCount,
    this.size = 78,
    this.slots,
  });

  /// Signatures already collected. Clamped into `0..total` — a PSBT can carry
  /// a signature from a key the inspection could not attribute to a slot.
  final int signed;

  /// Signer slots the transaction knows about. Zero draws nothing.
  final int total;

  /// Signatures needed to finalize, when the policy says. A 2-of-3 is done
  /// before the ring is full, so this — not [total] — decides the colour.
  final int? requiredCount;

  final double size;

  /// The signers by name and colour, when the wallet knows them.
  final List<SignerSlot>? slots;

  @override
  State<SignerDonut> createState() => _SignerDonutState();
}

class _SignerDonutState extends State<SignerDonut>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: AppMotion.emphasized,
  );

  /// Which wedges are being swept in right now — the ones that were not
  /// filled a moment ago. Everything else is drawn already full.
  Set<int> _arriving = const {};
  late List<bool> _filled = _filledNow();

  List<bool> _filledNow() {
    final slots = widget.slots;
    if (slots != null && slots.isNotEmpty) {
      return [for (final s in slots) s.signed];
    }
    final filled = widget.signed.clamp(0, widget.total);
    return [for (var i = 0; i < widget.total; i++) i < filled];
  }

  @override
  void initState() {
    super.initState();
    // First paint: sweep every filled wedge in, so a chart that opens on a
    // partially signed transaction still reads as "these have arrived".
    _arriving = {
      for (var i = 0; i < _filled.length; i++)
        if (_filled[i]) i,
    };
    _sweep.forward(from: 0);
  }

  @override
  void didUpdateWidget(SignerDonut old) {
    super.didUpdateWidget(old);
    final next = _filledNow();
    final arriving = <int>{
      for (var i = 0; i < next.length; i++)
        if (next[i] && !(i < _filled.length && _filled[i])) i,
    };
    _filled = next;
    if (arriving.isNotEmpty) {
      _arriving = arriving;
      _sweep.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  bool get _complete {
    final r = widget.requiredCount;
    return r != null && r > 0 && _filled.where((f) => f).length >= r;
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final total = _filled.length;
    if (total <= 0) return SizedBox(width: widget.size, height: widget.size);

    final filled = _filled.where((f) => f).length;
    final r = widget.requiredCount;
    final label = r != null
        ? '$filled of $total signers have signed; '
            '$r signature${r == 1 ? '' : 's'} required'
        : '$filled of $total signers have signed';

    // The sweep animates so an imported signature reads as an arrival rather
    // than as a redraw. Under reduced motion it lands already filled.
    final reduced = AppMotion.of(context, AppMotion.emphasized) == Duration.zero;
    final defaultColor = _complete ? s.success : s.accent;
    final slots = widget.slots;
    final colors = [
      for (var i = 0; i < total; i++)
        (slots != null && i < slots.length ? slots[i].color : null) ??
            defaultColor,
    ];

    return Semantics(
      // One node carrying the whole reading. The centre text is the same
      // numbers in a shorter form, so it is excluded rather than announced
      // twice in a row.
      container: true,
      excludeSemantics: true,
      label: label,
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: AnimatedBuilder(
          animation: _sweep,
          builder: (context, _) {
            final t = reduced
                ? 1.0
                : AppMotion.settle.transform(_sweep.value.clamp(0.0, 1.0));
            return CustomPaint(
              painter: _SignerDonutPainter(
                fills: [
                  for (var i = 0; i < total; i++)
                    !_filled[i]
                        ? 0.0
                        : _arriving.contains(i)
                            ? t
                            : 1.0,
                ],
                colors: colors,
                pendingColor: s.edgeStrong,
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '$filled/$total',
                      style: AppTypography.numericSmall.copyWith(
                        color: s.ink,
                        fontWeight: FontWeight.w700,
                        height: 1.1,
                      ),
                    ),
                    Text(
                      'signed',
                      style: AppTypography.caption.copyWith(
                        color: s.inkFaint,
                        fontSize: 9.5,
                        height: 1.1,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SignerDonutPainter extends CustomPainter {
  const _SignerDonutPainter({
    required this.fills,
    required this.colors,
    required this.pendingColor,
  });

  /// How much of each slot is filled: 0 while pending, fractional while the
  /// arriving signature sweeps in, 1 once it has.
  final List<double> fills;

  /// The colour each slot fills with.
  final List<Color> colors;
  final Color pendingColor;

  /// Seam between two slots, as a multiple of the stroke width. Round caps
  /// grow each arc by half a stroke at both ends, so a seam narrower than the
  /// stroke closes up and the slots read as one unbroken ring.
  static const _seamStrokes = 1.7;

  /// Ceiling on that seam, as a fraction of one slot — a ring with many
  /// signers must not be all gap.
  static const _maxSeamFraction = 0.45;

  @override
  void paint(Canvas canvas, Size size) {
    final total = fills.length;
    if (total == 0) return;
    final stroke = size.shortestSide * 0.115;
    final rect = Rect.fromCircle(
      center: Offset(size.width / 2, size.height / 2),
      radius: (size.shortestSide - stroke) / 2,
    );
    // 12 o'clock, clockwise — the direction a progress ring is read in.
    const start = -math.pi / 2;
    final slot = (2 * math.pi) / total;
    // A single-signer ring has no seam to draw, so it stays closed.
    final gap = total == 1
        ? 0.0
        : math.min(stroke * _seamStrokes / (rect.width / 2), slot * _maxSeamFraction);

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = total == 1 ? StrokeCap.butt : StrokeCap.round;

    for (var i = 0; i < total; i++) {
      final from = start + i * slot + gap / 2;
      final sweep = slot - gap;
      canvas.drawArc(rect, from, sweep, false, paint..color = pendingColor);

      // Partial fill while the sweep runs, so the arriving signature grows
      // into its slot instead of blinking on.
      final fill = fills[i].clamp(0.0, 1.0);
      if (fill > 0) {
        canvas.drawArc(
          rect,
          from,
          sweep * fill,
          false,
          paint..color = colors[i],
        );
      }
    }
  }

  @override
  bool shouldRepaint(_SignerDonutPainter old) =>
      !_listEq(old.fills, fills) ||
      !_listEq(old.colors, colors) ||
      old.pendingColor != pendingColor;

  static bool _listEq<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// The donut, its legend and the quorum line — the whole "who has signed and
/// how many are left" block.
///
/// Lives here rather than on the co-sign page because three surfaces show it
/// now: that page, and the two multisig hand-off sheets where a returning
/// PSBT/PSET is pasted in. They must never disagree about what a quorum
/// looks like.
///
/// [signed] and [total] are slots on the ring. [collected] is what the
/// inspection actually reports, which can exceed [signed] when a signature
/// could not be attributed to a named signer — it is the number the quorum
/// line prints, never invented from the ring.
///
/// With [slots] the legend names each signer — its label's name and colour,
/// "this device" where the key lives here — with Signed or Waiting beside
/// it, in place of the two summary rows.
class SignerChart extends StatelessWidget {
  const SignerChart({
    super.key,
    required this.signed,
    required this.total,
    this.requiredCount,
    this.collected,
    this.caption,
    this.donutSize = 78,
    this.slots,
  });

  final int signed;
  final int total;
  final int? requiredCount;
  final int? collected;

  /// Replaces the default "N signers on this transaction · …" line, for a
  /// ring whose slots are required signatures rather than named signers.
  final String? caption;

  final double donutSize;

  /// The signers by name and colour, when the wallet knows them.
  final List<SignerSlot>? slots;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final slots = this.slots;
    final named = slots != null && slots.isNotEmpty;
    final ringSigned = named ? slots.where((x) => x.signed).length : signed;
    final ringTotal = named ? slots.length : total;
    final present = collected ?? ringSigned;
    final pending = ringTotal - ringSigned;
    final r = requiredCount;
    final complete = r != null && present >= r;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SignerDonut(
          signed: ringSigned,
          total: ringTotal,
          requiredCount: requiredCount,
          size: donutSize,
          slots: slots,
        ),
        const SizedBox(width: AppSpacing.lg),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (named)
                for (var i = 0; i < slots.length; i++) ...[
                  if (i > 0) const SizedBox(height: AppSpacing.xs),
                  _SlotRow(
                    slot: slots[i],
                    fallbackColor: complete ? s.success : s.accent,
                  ),
                ]
              else ...[
                _LegendRow(
                  color: complete ? s.success : s.accent,
                  label: 'Signed',
                  count: ringSigned,
                ),
                const SizedBox(height: AppSpacing.xs),
                _LegendRow(
                  color: s.edgeStrong,
                  label: 'Not signed',
                  count: pending,
                ),
              ],
              const SizedBox(height: AppSpacing.sm),
              Text(
                caption ??
                    (r != null
                        ? '$ringTotal signer${ringTotal == 1 ? '' : 's'} on '
                            'this transaction · $present of $r required '
                            'signature${r == 1 ? '' : 's'} collected'
                        : '$ringTotal signer${ringTotal == 1 ? '' : 's'} on '
                            'this transaction · $present signature'
                            '${present == 1 ? '' : 's'} collected'),
                style: AppTypography.caption.copyWith(color: s.inkSecondary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _LegendRow extends StatelessWidget {
  const _LegendRow({
    required this.color,
    required this.label,
    required this.count,
  });
  final Color color;
  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return Row(
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: AppSpacing.sm),
        Text('$label ($count)',
            style: AppTypography.bodySmall.copyWith(color: s.ink)),
      ],
    );
  }
}

/// One named signer in the legend: its colour, its name, and whether its
/// signature has arrived. The status flips with a small pop, so a signature
/// that has just been collected is seen landing on the person it came from.
class _SlotRow extends StatelessWidget {
  const _SlotRow({required this.slot, required this.fallbackColor});

  final SignerSlot slot;

  /// Colour for a signer whose label has none.
  final Color fallbackColor;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final color = slot.color ?? fallbackColor;
    final motion = AppMotion.of(context, AppMotion.emphasized);
    return Row(
      children: [
        AnimatedSwitcher(
          duration: motion,
          switchInCurve: AppMotion.spring,
          transitionBuilder: (child, anim) =>
              ScaleTransition(scale: anim, child: child),
          child: slot.signed
              ? Icon(Icons.check_circle_rounded,
                  key: const ValueKey('signed'), size: 14, color: color)
              : Container(
                  key: const ValueKey('pending'),
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: color.withValues(alpha: 0.7), width: 1.5),
                  ),
                ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            slot.isLocal ? '${slot.label} · this device' : slot.label,
            style: AppTypography.bodySmall.copyWith(
              color: slot.signed ? s.ink : s.inkSecondary,
              fontWeight: slot.signed ? FontWeight.w600 : FontWeight.w400,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (slot.isHardware) ...[
          const SizedBox(width: AppSpacing.xs),
          Icon(Icons.usb_rounded, size: 13, color: s.inkFaint),
        ],
        const SizedBox(width: AppSpacing.sm),
        Text(
          slot.signed ? 'Signed' : 'Waiting',
          style: AppTypography.caption.copyWith(
            color: slot.signed ? color : s.inkFaint,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
