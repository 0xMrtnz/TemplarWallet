// Naming one co-signer: a name, a glyph and a colour.
//
// One editor, two callers — the creation wizard, where the wallet does not
// exist yet and the label is held in memory, and Appearance, where it is
// written straight to the store. Neither knows about the other, so the widget
// takes a label in and hands one back.

import 'package:flutter/material.dart';

import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import '../models/cosigner_label.dart';
import 'buttons.dart';
import 'glass_dialog.dart';
import 'list_rows.dart';

/// Opens the editor for [label]. Returns the edited label, or null if
/// dismissed.
///
/// [subtitle] says which key is being named — a fingerprint and path, or the
/// source it came from — because "Key 2" alone is not enough to know which
/// device is being described.
Future<CosignerLabel?> showCosignerLabelEditor(
  BuildContext context, {
  required CosignerLabel label,
  required int index,
  String? subtitle,
}) {
  return showAppDialog<CosignerLabel>(
    context,
    builder: (_) => _CosignerLabelDialog(
      label: label,
      index: index,
      subtitle: subtitle,
    ),
  );
}

class _CosignerLabelDialog extends StatefulWidget {
  const _CosignerLabelDialog({
    required this.label,
    required this.index,
    this.subtitle,
  });

  final CosignerLabel label;
  final int index;
  final String? subtitle;

  @override
  State<_CosignerLabelDialog> createState() => _CosignerLabelDialogState();
}

class _CosignerLabelDialogState extends State<_CosignerLabelDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.label.name ?? '');
  late String? _iconId = widget.label.iconId;
  late int? _color = widget.label.colorValue;

  /// Starts at what the label already implies, so an old label whose USB
  /// icon has been standing in for the flag shows the switch on.
  late bool _hardware = widget.label.isHardware;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final accent = _color == null ? s.accent : Color(_color!);
    return AppDialog(
      title: Text('Name key ${widget.index + 1}'),
      scrollable: true,
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.subtitle case final sub?) ...[
              Text(sub,
                  style:
                      AppTypography.caption.copyWith(color: s.inkSecondary)),
              const SizedBox(height: AppSpacing.md),
            ],
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.14),
                    shape: BoxShape.circle,
                    border: Border.all(color: accent),
                  ),
                  child: Icon(
                    cosignerIcons[_iconId] ?? defaultCosignerIcon,
                    color: accent,
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: TextField(
                    controller: _name,
                    autofocus: true,
                    maxLength: 40,
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      hintText: 'Jade in the safe, Anna’s phone…',
                      counterText: '',
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            const ListSectionLabel(label: 'Icon'),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                for (final entry in cosignerIcons.entries)
                  _Swatch(
                    selected: _iconId == entry.key,
                    color: accent,
                    onTap: () => setState(
                        () => _iconId = _iconId == entry.key ? null : entry.key),
                    child: Icon(entry.value, size: 18),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            const ListSectionLabel(label: 'Colour'),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                for (final value in cosignerColors)
                  _Swatch(
                    selected: _color == value,
                    color: Color(value),
                    onTap: () =>
                        setState(() => _color = _color == value ? null : value),
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        color: Color(value),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            const ListSectionLabel(label: 'Signs on'),
            const SizedBox(height: AppSpacing.sm),
            // The one label field that changes what the app offers: a key
            // flagged as hardware makes the co-signing sheet show "Sign with
            // USB hardware wallet" while its signature is missing.
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md, vertical: AppSpacing.sm),
              decoration: BoxDecoration(
                color: s.panelInset,
                borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                border: Border.all(color: s.edge),
              ),
              child: Row(
                children: [
                  Icon(Icons.usb_rounded,
                      size: 18, color: _hardware ? accent : s.inkSecondary),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('USB hardware wallet',
                            style: AppTypography.body
                                .copyWith(fontWeight: FontWeight.w600)),
                        Text(
                          'A Ledger or Jade plugged into this computer. '
                          'Co-signing then offers “Sign with USB hardware '
                          'wallet” for this key.',
                          style: AppTypography.caption
                              .copyWith(color: s.inkSecondary),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  ListSwitch(
                    value: _hardware,
                    onChanged: (v) => setState(() => _hardware = v),
                    semanticLabel: 'Signs on a USB hardware wallet',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        SecondaryButton(
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
        ),
        PrimaryButton(label: 'Save', onPressed: _submit),
      ],
    );
  }

  void _submit() {
    // The flag is only written down once somebody has actually said: a label
    // that was merely inferring from its icon keeps inferring, so changing
    // the icon later still changes the answer.
    final explicit = widget.label.hardware != null ||
        _hardware != widget.label.isHardware;
    Navigator.of(context).pop(CosignerLabel(
      id: widget.label.id,
      name: _name.text.trim().isEmpty ? null : _name.text.trim(),
      iconId: _iconId,
      colorValue: _color,
      hardware: explicit ? _hardware : null,
    ));
  }
}

/// One tappable choice in the icon or colour row.
class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.selected,
    required this.color,
    required this.onTap,
    required this.child,
  });

  final bool selected;
  final Color color;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.16) : s.panelInset,
          borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
          border: Border.all(
            color: selected ? color : s.edge,
            width: selected ? 2 : 1,
          ),
        ),
        child: Center(
          child: IconTheme(
            data: IconThemeData(color: selected ? color : s.inkSecondary),
            child: child,
          ),
        ),
      ),
    );
  }
}
