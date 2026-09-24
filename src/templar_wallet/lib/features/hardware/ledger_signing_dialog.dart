import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';

/// Phases of a hardware signing round-trip.
///
/// When a [verifyTask] is supplied the flow starts at [verifying] (device shows
/// the wallet address) → [verifyConfirm] (user confirms it matches) → [signing].
/// Without it, the flow starts directly at [signing].
enum _SignPhase { verifying, verifyConfirm, signing, broadcasting, done, error }

/// Run [task] (build + sign on device + broadcast) behind an animated Ledger
/// dialog. Resolves with the txid on success, or null if the user cancelled.
///
/// If [verifyTask] is given, the dialog first asks the device to display a wallet
/// address and waits for the user to confirm it matches the device screen before
/// signing — a guard that the connected device really controls this wallet.
///
/// [formatError] turns a raw error string into user-facing guidance.
///
/// [signOnly] is the co-signing shape: [task] adds one signature and hands
/// the signed transaction back, nothing is broadcast, and the dialog's words
/// say so — "Signature added", not "Transaction sent".
Future<String?> showLedgerSigningDialog(
  BuildContext context, {
  required Future<String> Function() task,
  Future<String> Function()? verifyTask,
  String Function(String raw)? formatError,
  bool signOnly = false,
}) {
  return showDialog<String?>(
    context: context,
    barrierDismissible: false,
    builder: (_) => LedgerSigningDialog(
      task: task,
      verifyTask: verifyTask,
      formatError: formatError,
      signOnly: signOnly,
    ),
  );
}

class LedgerSigningDialog extends StatefulWidget {
  const LedgerSigningDialog({
    super.key,
    required this.task,
    this.verifyTask,
    this.formatError,
    this.signOnly = false,
  });

  final Future<String> Function() task;
  final Future<String> Function()? verifyTask;
  final String Function(String raw)? formatError;

  /// The task signs and returns the transaction; there is no broadcast leg.
  final bool signOnly;

  @override
  State<LedgerSigningDialog> createState() => _LedgerSigningDialogState();
}

class _LedgerSigningDialogState extends State<LedgerSigningDialog>
    with TickerProviderStateMixin {
  late final AnimationController _pulse;
  late final AnimationController _shake;

  _SignPhase _phase = _SignPhase.signing;
  String? _txid;
  String? _error;
  String? _verifyAddress;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
    _shake = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    if (widget.verifyTask != null) {
      _startVerify();
    } else {
      _run();
    }
  }

  /// Ask the device to display a wallet address, then pause for the user to
  /// confirm it matches the device screen before signing.
  Future<void> _startVerify() async {
    setState(() {
      _phase = _SignPhase.verifying;
      _error = null;
    });
    _pulse.repeat();
    try {
      final addr = await widget.verifyTask!();
      if (!mounted) return;
      _pulse.stop();
      setState(() {
        _phase = _SignPhase.verifyConfirm;
        _verifyAddress = addr;
      });
    } catch (e) {
      if (!mounted) return;
      _pulse.stop();
      setState(() {
        _phase = _SignPhase.error;
        _error = widget.formatError?.call(e.toString()) ?? e.toString();
      });
      _shake.forward(from: 0);
    }
  }

  Future<void> _run() async {
    setState(() {
      _phase = _SignPhase.signing;
      _error = null;
    });
    _pulse.repeat();
    try {
      final txid = await widget.task();
      if (!mounted) return;
      if (!widget.signOnly) {
        // Brief broadcasting beat so the success feels sequenced, not instant.
        setState(() => _phase = _SignPhase.broadcasting);
        _pulse.stop();
        await Future.delayed(const Duration(milliseconds: 600));
        if (!mounted) return;
      }
      _pulse.stop();
      setState(() {
        _phase = _SignPhase.done;
        _txid = txid;
      });
      // Hold the green tick briefly, then hand the result back to the caller
      // (the txid and its success screen, or the signed transaction for the
      // quorum chart to take in).
      await Future.delayed(
          Duration(milliseconds: widget.signOnly ? 700 : 1000));
      if (mounted) Navigator.of(context).pop(_txid);
    } catch (e) {
      if (!mounted) return;
      _pulse.stop();
      final raw = e.toString();
      setState(() {
        _phase = _SignPhase.error;
        _error = widget.formatError?.call(raw) ?? raw;
      });
      _shake.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    _shake.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_title),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: AppSpacing.md),
            _LedgerGraphic(
              pulse: _pulse,
              shake: _shake,
              phase: _phase,
            ),
            const SizedBox(height: AppSpacing.xl),
            Text(
              _message,
              textAlign: TextAlign.center,
              style: AppTypography.body,
            ),
            if (_phase == _SignPhase.signing ||
                _phase == _SignPhase.verifying) ...[
              const SizedBox(height: AppSpacing.md),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Text('Do not disconnect the device.',
                      style: AppTypography.caption
                          .copyWith(color: AppColors.warning)),
                ],
              ),
            ],
            if (_phase == _SignPhase.verifyConfirm &&
                _verifyAddress != null) ...[
              const SizedBox(height: AppSpacing.md),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: AppColors.codeBoxBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.codeBoxBorder),
                ),
                child: SelectableText(
                  _verifyAddress!,
                  textAlign: TextAlign.center,
                  style: AppTypography.mono,
                ),
              ),
            ],
            if (_phase == _SignPhase.error && _error != null) ...[
              const SizedBox(height: AppSpacing.md),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style:
                    AppTypography.caption.copyWith(color: AppColors.danger),
              ),
            ],
          ],
        ),
      ),
      actions: _actions,
    );
  }

  String get _title => switch (_phase) {
        _SignPhase.verifying => 'Check your Ledger',
        _SignPhase.verifyConfirm => 'Verify the address',
        _SignPhase.signing =>
          widget.signOnly ? 'Confirm on your device' : 'Confirm on your Ledger',
        _SignPhase.broadcasting => 'Broadcasting…',
        _SignPhase.done => widget.signOnly ? 'Signature added' : 'Transaction sent',
        _SignPhase.error => 'Signing failed',
      };

  String get _message => switch (_phase) {
        _SignPhase.verifying =>
          'Your device is displaying a wallet address. Confirm it on screen.',
        _SignPhase.verifyConfirm =>
          'Does this address exactly match the one shown on your Ledger?',
        _SignPhase.signing => widget.signOnly
            ? 'Check the amounts and addresses on the device screen, then '
                'approve. A Ledger may first ask you to register the wallet '
                'policy — approve that too.'
            : 'Check the amount and address on the device screen, then press '
                'both buttons to approve.',
        _SignPhase.broadcasting => 'Submitting the signed transaction…',
        _SignPhase.done => widget.signOnly
            ? 'The device signed. Its signature is being added to the '
                'transaction.'
            : 'Your transaction was broadcast successfully.',
        _SignPhase.error => 'The device did not complete signing.',
      };

  List<Widget>? get _actions => switch (_phase) {
        _SignPhase.verifying ||
        _SignPhase.signing ||
        _SignPhase.broadcasting ||
        _SignPhase.done =>
          null,
        _SignPhase.verifyConfirm => [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: _run,
              child: const Text('It matches — sign'),
            ),
          ],
        _SignPhase.error => [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: widget.verifyTask != null ? _startVerify : _run,
              child: const Text('Retry'),
            ),
          ],
      };
}

/// Stylised Ledger Nano: a body with a screen and two side buttons that pulse
/// while waiting, flips to a green tick on success / red on error.
class _LedgerGraphic extends StatelessWidget {
  const _LedgerGraphic({
    required this.pulse,
    required this.shake,
    required this.phase,
  });

  final AnimationController pulse;
  final AnimationController shake;
  final _SignPhase phase;

  @override
  Widget build(BuildContext context) {
    final isDone = phase == _SignPhase.done;
    final isError = phase == _SignPhase.error;

    if (isDone) {
      return _Badge(
        bg: AppColors.successLight,
        fg: AppColors.success,
        icon: Icons.check_rounded,
      );
    }

    final body = AnimatedBuilder(
      animation: Listenable.merge([pulse, shake]),
      builder: (_, _) {
        final t = pulse.value;
        final glow = (0.4 + 0.6 * (0.5 + 0.5 * _sin(t))).clamp(0.0, 1.0);
        final dx = isError ? _shakeOffset(shake.value) : 0.0;
        final accent = isError ? AppColors.danger : AppColors.accent;
        return Transform.translate(
          offset: Offset(dx, 0),
          child: SizedBox(
            width: 150,
            height: 64,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Device body with a screen.
                Container(
                  width: 110,
                  height: 48,
                  decoration: BoxDecoration(
                    color: const Color(0xFF2B2F36),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  alignment: Alignment.center,
                  child: Container(
                    width: 78,
                    height: 26,
                    decoration: BoxDecoration(
                      color: Colors.black,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: accent.withValues(
                            alpha: isError ? 0.9 : glow),
                        width: 1.5,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      isError ? Icons.close_rounded : Icons.check_rounded,
                      size: 16,
                      color: accent.withValues(
                          alpha: isError ? 1.0 : glow),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                // Two side buttons that pulse.
                Column(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _button(accent, isError ? 1.0 : glow),
                    const SizedBox(height: 6),
                    _button(accent, isError ? 1.0 : glow),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
    return body;
  }

  Widget _button(Color color, double glow) {
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.15 + 0.55 * glow),
        border: Border.all(color: color, width: 1.5),
      ),
    );
  }

  // Cheap sine without importing dart:math at call sites.
  double _sin(double t) {
    // t in [0,1] → approximate one full sine cycle.
    const twoPi = 6.283185307179586;
    final x = t * twoPi;
    // Bhaskara I approximation, good enough for a glow.
    final xn = x % twoPi;
    final s = xn <= 3.141592653589793
        ? _bhaskara(xn)
        : -_bhaskara(xn - 3.141592653589793);
    return s;
  }

  double _bhaskara(double x) {
    const pi = 3.141592653589793;
    return (16 * x * (pi - x)) / (5 * pi * pi - 4 * x * (pi - x));
  }

  double _shakeOffset(double v) {
    // Damped left-right shake over the controller's run.
    final decay = (1 - v);
    return _sin(v * 3) * 8 * decay;
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.bg, required this.fg, required this.icon});
  final Color bg;
  final Color fg;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.6, end: 1),
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOutBack,
      builder: (_, scale, _) => Transform.scale(
        scale: scale,
        child: Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
          child: Icon(icon, color: fg, size: 36),
        ),
      ),
    );
  }
}
