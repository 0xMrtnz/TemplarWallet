import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import 'buttons.dart';
import 'glass_dialog.dart';
import 'hex_text.dart';

/// Longest value a single QR holds: byte mode at version 40, low error
/// correction. A descriptor, an xpub or a fingerprint is nowhere near it; a
/// signed PSBT is, and gets the animated UR codes instead.
const int kQrMaxChars = 2900;

/// Opens [value] as a QR — a dialog on desktop, a sheet on a phone — with the
/// value printed under the code so what is scanned can be read too.
Future<void> showValueQr(
  BuildContext context, {
  required String title,
  required String value,
  String? caption,
}) {
  return showAppDialog<void>(
    context,
    builder: (ctx) => ValueQrDialog(title: title, value: value, caption: caption),
  );
}

/// The body [showValueQr] opens. Keyed by its payload so a test can read
/// back what a camera would (the package keeps `data` private).
class ValueQrDialog extends StatelessWidget {
  const ValueQrDialog({
    super.key,
    required this.title,
    required this.value,
    this.caption,
  });

  final String title;
  final String value;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final phone = AppLayout.isPhone(context);
    final tooLong = value.length > kQrMaxChars;
    final side = phone ? AppLayout.qrSide(context, max: 300) : 300.0;
    return AppDialog(
      title: Text(title),
      scrollable: true,
      content: SizedBox(
        width: phone ? double.infinity : 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (tooLong)
              Text(
                'Too long for a single QR code (${value.length} characters). '
                'Copy it instead.',
                style: AppTypography.bodySmall.copyWith(color: s.inkSecondary),
                textAlign: TextAlign.center,
              )
            else
              Container(
                padding: const EdgeInsets.all(AppSpacing.lg),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                ),
                child: SizedBox.square(
                  dimension: side,
                  child: QrImageView(
                    key: ValueKey<String>(value),
                    data: value,
                    version: QrVersions.auto,
                    size: side,
                    padding: EdgeInsets.zero,
                    semanticsLabel: '$title QR code',
                  ),
                ),
              ),
            const SizedBox(height: AppSpacing.md),
            SelectableText(
              value,
              style: AppTypography.monoSmall.copyWith(color: s.inkSecondary),
              textAlign: TextAlign.center,
              maxLines: 4,
            ),
            if (caption case final c?) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                c,
                style: AppTypography.caption.copyWith(color: s.inkSecondary),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (phone)
          PrimaryButton(
            label: 'Close',
            onPressed: () => Navigator.of(context).pop(),
          )
        else
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
      ],
    );
  }
}

/// The QR glyph beside a copy glyph: same size, same ink, same hit area, so
/// the two read as one pair of ways to hand a value over.
class _QrGlyphButton extends StatelessWidget {
  const _QrGlyphButton({
    required this.title,
    required this.value,
    required this.color,
    required this.phone,
    this.size = 16,
    this.dense = false,
  });

  final String title;
  final String value;
  final Color color;
  final bool phone;
  final double size;

  /// Desktop CopyRow's 4 dp-padded glyph rather than an IconButton.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    void open() => showValueQr(context, title: title, value: value);
    if (dense && !phone) {
      return InkWell(
        onTap: open,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        child: Tooltip(
          message: 'Show QR',
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xs),
            child: Icon(Icons.qr_code_2_rounded, size: size, color: color),
          ),
        ),
      );
    }
    return IconButton(
      icon: Icon(Icons.qr_code_2_rounded, size: size, color: color),
      onPressed: open,
      tooltip: 'Show QR',
      visualDensity: phone ? VisualDensity.standard : VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: phone
          ? const BoxConstraints(
              minWidth: AppLayout.minTouchTarget,
              minHeight: AppLayout.minTouchTarget,
            )
          : const BoxConstraints(),
    );
  }
}

/// A boxed, selectable, copyable monospace value (descriptor, txid, PSBT).
///
/// Desktop: the value is clipped at [maxLines] with a compact copy glyph.
/// Phone: the copy control is a 48 dp button, and when the value does not fit
/// [maxLines] a "Show all" toggle appears under it — a descriptor the user
/// cannot read to the end is one they cannot verify before copying.
class CodeBox extends StatefulWidget {
  const CodeBox({
    super.key,
    required this.value,
    this.label,
    this.maxLines = 4,
    this.showQr = false,
  });

  final String value;
  final String? label;
  final int maxLines;

  /// A QR glyph beside the copy glyph, opening [showValueQr]. Off by
  /// default: a PSBT or a whole descriptor bundle is too long for one code
  /// and has its own animated route.
  final bool showQr;

  @override
  State<CodeBox> createState() => _CodeBoxState();
}

class _CodeBoxState extends State<CodeBox> {
  bool _copied = false;
  bool _expanded = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.value));
    setState(() => _copied = true);
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final phone = AppLayout.isPhone(context);
    final s = AppScheme.of(context);
    final secondary =
        isDark ? AppColors.textSecondaryDark : AppColors.textSecondary;
    final textStyle = AppTypography.monoSmall.copyWith(
      color: isDark ? AppColors.textPrimaryDark : AppColors.textPrimary,
    );

    final copyButton = IconButton(
      icon: Icon(
        _copied ? Icons.check : Icons.copy,
        size: phone ? 20 : 16,
        color: _copied ? AppColors.success : secondary,
      ),
      onPressed: _copy,
      tooltip: _copied ? 'Copied!' : 'Copy',
      visualDensity: phone ? VisualDensity.standard : VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: phone
          ? const BoxConstraints(
              minWidth: AppLayout.minTouchTarget,
              minHeight: AppLayout.minTouchTarget,
            )
          : const BoxConstraints(),
    );

    final Widget text;
    if (phone) {
      text = LayoutBuilder(
        builder: (ctx, c) {
          // Does the value fit the cap? Measured, not guessed, so the toggle
          // only appears when something is actually hidden.
          final painter = TextPainter(
            text: TextSpan(text: widget.value, style: textStyle),
            textDirection: TextDirection.ltr,
            textScaler: MediaQuery.textScalerOf(ctx),
            maxLines: widget.maxLines,
          )..layout(maxWidth: c.maxWidth);
          final overflows = painter.didExceedMaxLines;
          painter.dispose();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(
                widget.value,
                style: textStyle,
                maxLines: _expanded ? null : widget.maxLines,
              ),
              if (overflows)
                InkWell(
                  onTap: () => setState(() => _expanded = !_expanded),
                  borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                  child: SizedBox(
                    height: AppLayout.minTouchTarget,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        _expanded ? 'Show less' : 'Show all',
                        style: AppTypography.label
                            .copyWith(color: AppColors.accent),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      );
    } else {
      text = SelectableText(
        widget.value,
        style: textStyle,
        maxLines: widget.maxLines,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.label != null)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: phone
                // The same uppercase micro-label the Dashboard and Settings
                // put over a card, so a descriptor is captioned like
                // everything else on the screen.
                ? Text(
                    widget.label!.toUpperCase(),
                    style: AppTypography.navSection.copyWith(
                      letterSpacing: 1.3,
                      color: s.inkFaint,
                    ),
                  )
                : Text(
                    widget.label!,
                    style: AppTypography.label.copyWith(color: secondary),
                  ),
          ),
        Container(
          width: double.infinity,
          padding: phone
              ? const EdgeInsets.fromLTRB(
                  AppSpacing.md, AppSpacing.md, AppSpacing.xs, AppSpacing.md)
              : const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            // A phone reads a descriptor out of the same inset grey a field
            // is made of; the desktop keeps its own code-box surface.
            color: phone
                ? s.panelInset
                : (isDark ? AppColors.codeBoxBgDark : AppColors.codeBoxBg),
            borderRadius: BorderRadius.circular(
              phone ? AppSpacing.radiusLg : AppSpacing.radiusSm,
            ),
            border: phone
                ? null
                : Border.all(
                    color: isDark
                        ? AppColors.codeBoxBorderDark
                        : AppColors.codeBoxBorder,
                  ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: text),
              // Stacked on a phone, side by side on desktop: two 48 dp
              // buttons in a row would eat a quarter of a 360 dp box.
              if (!widget.showQr)
                copyButton
              else if (phone)
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    copyButton,
                    _QrGlyphButton(
                      title: widget.label ?? 'QR code',
                      value: widget.value,
                      color: secondary,
                      phone: true,
                      size: 20,
                    ),
                  ],
                )
              else ...[
                copyButton,
                _QrGlyphButton(
                  title: widget.label ?? 'QR code',
                  value: widget.value,
                  color: secondary,
                  phone: false,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Label / value / copy glyph on one line.
///
/// Desktop keeps the 160 dp label column. On a phone the label sits above
/// the value, the value wraps across the full width (or, with [singleLine],
/// collapses in the middle to fit one line) and the copy control is a 48 dp
/// button.
class CopyRow extends StatefulWidget {
  const CopyRow({
    super.key,
    required this.label,
    required this.value,
    this.mono = true,
    this.singleLine = false,
    this.showQr = false,
  });

  final String label;
  final String value;
  final bool mono;

  /// A QR glyph beside the copy glyph, opening [showValueQr].
  final bool showQr;

  /// Phone only: keep the value on one line, middle-ellipsised to the width,
  /// instead of wrapping. Desktop already ellipsises at the end.
  final bool singleLine;

  @override
  State<CopyRow> createState() => _CopyRowState();
}

class _CopyRowState extends State<CopyRow> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.value));
    setState(() => _copied = true);
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final labelStyle = AppTypography.bodySmall.copyWith(
      color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondary,
    );
    final valueStyle =
        widget.mono ? AppTypography.monoSmall : AppTypography.bodySmall;
    final iconColor = _copied
        ? AppColors.success
        : (isDark ? AppColors.textSecondaryDark : AppColors.textMuted);

    if (AppLayout.isPhone(context)) {
      final s = AppScheme.of(context);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.label.toUpperCase(),
              style: AppTypography.navSection
                  .copyWith(letterSpacing: 1.3, color: s.inkFaint),
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                Expanded(
                  child: widget.singleLine
                      ? MiddleEllipsisText(widget.value, style: valueStyle)
                      : Text(
                          widget.value,
                          style: valueStyle,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                        ),
                ),
                const SizedBox(width: AppSpacing.sm),
                IconButton(
                  onPressed: _copy,
                  tooltip: _copied ? 'Copied!' : 'Copy',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: AppLayout.minTouchTarget,
                    minHeight: AppLayout.minTouchTarget,
                  ),
                  icon: Icon(
                    _copied ? Icons.check : Icons.copy,
                    size: 18,
                    color: iconColor,
                  ),
                ),
                if (widget.showQr)
                  _QrGlyphButton(
                    title: widget.label,
                    value: widget.value,
                    color: isDark
                        ? AppColors.textSecondaryDark
                        : AppColors.textMuted,
                    phone: true,
                    size: 18,
                  ),
              ],
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        children: [
          SizedBox(
            width: 160,
            child: Text(widget.label, style: labelStyle),
          ),
          Expanded(
            child: Text(
              widget.value,
              style: valueStyle,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          InkWell(
            onTap: _copy,
            borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.xs),
              child: Icon(
                _copied ? Icons.check : Icons.copy,
                size: 14,
                color: iconColor,
              ),
            ),
          ),
          if (widget.showQr)
            _QrGlyphButton(
              title: widget.label,
              value: widget.value,
              color: isDark ? AppColors.textSecondaryDark : AppColors.textMuted,
              phone: false,
              size: 14,
              dense: true,
            ),
        ],
      ),
    );
  }
}
