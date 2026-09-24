import 'package:flutter/material.dart';

import '../../shared/widgets/buttons.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';

/// The explicit-consent step of a Templar Protocol request.
///
/// A signature (or a share of wallet keys) only leaves the wallet after the
/// user has ticked the statement *and* pressed the button — two deliberate
/// acts, so a stray click on a freshly opened window cannot sign a loan.
/// The button stays disabled until the box is ticked; [onConfirm] fires at
/// most once per press. The app-password gate comes after this, in the
/// screen.
class ProtocolConfirmGate extends StatefulWidget {
  const ProtocolConfirmGate({
    super.key,
    required this.statement,
    required this.buttonLabel,
    required this.onConfirm,
    this.busy = false,
    this.enabled = true,
    this.icon = Icons.draw_outlined,
  });

  /// What the user asserts by ticking the box.
  final String statement;
  final String buttonLabel;
  final VoidCallback onConfirm;

  /// A request is in flight: everything is frozen.
  final bool busy;

  /// False when there is nothing to confirm (e.g. no input of ours to sign).
  final bool enabled;
  final IconData icon;

  @override
  State<ProtocolConfirmGate> createState() => _ProtocolConfirmGateState();
}

class _ProtocolConfirmGateState extends State<ProtocolConfirmGate> {
  bool _checked = false;

  @override
  Widget build(BuildContext context) {
    final canConfirm = widget.enabled && _checked && !widget.busy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Own Material: the page paints its background with a ColoredBox,
        // and a ListTile needs a Material ancestor of its own to draw on.
        Material(
          type: MaterialType.transparency,
          child: CheckboxListTile(
            key: const Key('protocol-confirm-checkbox'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            activeColor: AppColors.accent,
            value: _checked,
            onChanged: widget.enabled && !widget.busy
                ? (v) => setState(() => _checked = v ?? false)
                : null,
            title: Text(widget.statement, style: AppTypography.body),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        PrimaryButton(
          key: const Key('protocol-confirm-button'),
          label: widget.buttonLabel,
          icon: widget.icon,
          isLoading: widget.busy,
          isFullWidth: true,
          onPressed: canConfirm ? widget.onConfirm : null,
        ),
      ],
    );
  }
}
