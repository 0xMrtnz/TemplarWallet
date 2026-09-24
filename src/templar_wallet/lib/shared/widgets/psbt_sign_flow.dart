import 'package:file_selector/file_selector.dart' show XTypeGroup;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../bridge/bridge_provider.dart';
import '../../bridge/wallet_bridge.dart';
import '../../features/psbt/models/psbt_inspection.dart';
import '../../services/file_export.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import 'app_password_gate.dart';
import 'buttons.dart';
import 'glass_dialog.dart';
import 'ur_qr.dart';

/// Review → sign → review → broadcast, for a transaction this app can sign
/// with its own key.
///
/// One screen shown twice. First with the **unsigned** PSBT: what it spends,
/// what it pays, the fee, and the PSBT itself as a QR — the only way forward
/// is "Sign", behind the app password. Then the same screen with the
/// **signed** PSBT and its own QR, where the only way forward is "Broadcast".
///
/// Splitting the two also makes a failed broadcast retryable: the signature is
/// held here, so a network hiccup costs a click and not another signing pass
/// over the same coins.
///
/// Returns the txid once broadcast, or null if the user backed out. The caller
/// stays responsible for what happens next (success view, pending bookkeeping).
/// What the Export menu on the sign flow offers. The QR is here rather than
/// on the face of the dialog: a software wallet signs locally and never needs
/// it, so it stays one click away for the air-gap case instead of dominating
/// the screen.
enum _ExportAction { copy, file, qr }

Future<String?> showPsbtSignFlow(
  BuildContext context, {
  required String walletId,
  required String unsignedPsbt,
  required String title,
  String? summary,
  WalletBridge? bridge,
}) {
  // Dialog on desktop, bottom sheet on a phone. Neither can be dismissed by
  // tapping outside: backing out of a signing flow is an explicit Cancel.
  return showAppDialog<String>(
    context,
    barrierDismissible: false,
    builder: (_) => _PsbtSignFlowDialog(
      walletId: walletId,
      unsignedPsbt: unsignedPsbt,
      title: title,
      summary: summary,
      bridge: bridge,
    ),
  );
}

class _PsbtSignFlowDialog extends StatefulWidget {
  const _PsbtSignFlowDialog({
    required this.walletId,
    required this.unsignedPsbt,
    required this.title,
    this.summary,
    this.bridge,
  });

  final String walletId;
  final String unsignedPsbt;
  final String title;
  final String? summary;

  /// Test seam. Null in the app, where the global engine is used.
  final WalletBridge? bridge;

  @override
  State<_PsbtSignFlowDialog> createState() => _PsbtSignFlowDialogState();
}

class _PsbtSignFlowDialogState extends State<_PsbtSignFlowDialog> {
  late final WalletBridge _bridge = widget.bridge ?? walletBridge;

  /// Null until the signing pass returns. Its presence *is* the phase.
  String? _signedPsbt;

  PsbtInspection? _inspection;
  List<String>? _urParts;
  String? _urError;
  String? _error;
  bool _busy = false;

  String get _psbt => _signedPsbt ?? widget.unsignedPsbt;
  bool get _isSigned => _signedPsbt != null;

  @override
  void initState() {
    super.initState();
    _describe();
  }

  /// Inspect and encode the PSBT currently on screen. Both are best-effort:
  /// the flow stays usable when either fails, because the transaction itself
  /// is unaffected — only the description of it is missing.
  Future<void> _describe() async {
    final psbt = _psbt;
    setState(() {
      _inspection = null;
      _urParts = null;
      _urError = null;
    });
    try {
      final inspection = await _bridge.inspectPsbt(psbt);
      if (mounted && _psbt == psbt) setState(() => _inspection = inspection);
    } catch (e) {
      if (mounted && _psbt == psbt) setState(() => _error = _clean(e));
    }
    try {
      final parts = await _bridge.urPsbtEncode(psbt);
      if (mounted && _psbt == psbt) setState(() => _urParts = parts);
    } catch (e) {
      if (mounted && _psbt == psbt) setState(() => _urError = _clean(e));
    }
  }

  static String _clean(Object e) =>
      e.toString().replaceFirst('Exception: ', '').replaceFirst('wallet-ffi: ', '');

  Future<void> _sign() async {
    final ok = await showSpendPasswordGate(
      context,
      message: 'Templar is about to sign this transaction with the key stored '
          'on this device. Nothing is broadcast yet — you review the signed '
          'transaction next.',
    );
    if (!ok || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final signed = await _bridge.signPsbt(widget.walletId, widget.unsignedPsbt);
      if (!mounted) return;
      setState(() {
        _signedPsbt = signed;
        _busy = false;
      });
      await _describe();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _clean(e);
        });
      }
    }
  }

  Future<void> _broadcast() async {
    final signed = _signedPsbt;
    if (signed == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final txid = await _bridge.broadcastSignedPsbt(
        walletId: widget.walletId,
        psbtBase64: signed,
      );
      if (mounted) Navigator.of(context).pop(txid);
    } catch (e) {
      // The signature is kept: "Broadcast" retries the network leg alone.
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _clean(e);
        });
      }
    }
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _psbt));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('PSBT copied to clipboard')),
    );
  }

  /// Show the PSBT as an animated BC-UR QR — the air-gap hand-off. Off the
  /// main screen because software wallets, which sign right here, never use it.
  void _showQr() {
    final phone = AppLayout.isPhone(context);
    // A Jade or SeedSigner camera reads the animation from arm's length: on a
    // phone the QR takes the whole column, on desktop it stays a small card.
    final side = phone ? AppLayout.qrSide(context, max: 300) : 220.0;
    final panel = _QrPanel(
      parts: _urParts,
      error: _urError,
      signed: _isSigned,
      size: side,
    );
    showAppDialog<void>(
      context,
      builder: (_) => AppDialog(
        title: Text(_isSigned ? 'Signed transaction' : 'Unsigned transaction'),
        content: phone
            ? Center(child: panel)
            : SizedBox(width: 260, child: panel),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    try {
      final result = await FileExport.saveOrShareText(
        context,
        suggestedName: _isSigned ? 'signed.psbt' : 'unsigned.psbt',
        text: _psbt,
        mimeType: 'application/octet-stream',
        acceptedTypeGroups: const [
          XTypeGroup(label: 'PSBT', extensions: ['psbt']),
        ],
        shareTitle: _isSigned ? 'Signed PSBT' : 'Unsigned PSBT',
      );
      if (result == null || !mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result == 'shared' ? 'PSBT shared' : 'Saved to $result'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Save failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final phone = AppLayout.isPhone(context);
    final i = _inspection;
    // A signed PSBT with no signature in it is the one thing that must never
    // reach the network quietly — say so and hold the button.
    final unsignedAfterSigning = _isSigned && i != null && i.sigsPresent == 0;
    // A PSBT whose inputs cannot be priced hides what the signature would
    // commit to. The engine refuses to sign it; the button is held here so
    // the refusal is never the first thing the user learns.
    final hidesSpend = i != null && !i.utxoCheckOk;
    final hiddenHow = i?.utxoCheck == PsbtUtxoStatus.conflicting
        ? 'inconsistent'
        : 'missing';

    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.summary != null) ...[
          Text(widget.summary!,
              style: AppTypography.bodySmall.copyWith(color: s.inkSecondary)),
          const SizedBox(height: AppSpacing.lg),
        ],
        Text(
          _isSigned
              ? 'Signed and ready. Nothing has reached the network yet — '
                  'check it once more, then broadcast.'
              : 'Nothing has been signed yet. Check what this spends and '
                  'where it goes; signing asks for your app password.',
          style: AppTypography.caption.copyWith(color: s.inkSecondary),
        ),
        const SizedBox(height: AppSpacing.lg),
        _details(i, s, phone),
        const SizedBox(height: AppSpacing.lg),
        if (phone) _phoneExportRow() else _desktopExportMenu(s),
        if (hidesSpend) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            'This transaction hides what it spends — do not sign. Its '
            'previous outputs are $hiddenHow, so the amount and fee on '
            'screen cannot be trusted.',
            style: AppTypography.bodySmall.copyWith(color: AppColors.danger),
          ),
        ],
        if (unsignedAfterSigning) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            'No signature was added. This wallet may need co-signers — '
            'broadcasting now would fail.',
            style: AppTypography.caption.copyWith(color: AppColors.danger),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.md),
          SelectableText(
            _error!,
            style: AppTypography.caption.copyWith(color: AppColors.danger),
          ),
        ],
      ],
    );

    final VoidCallback? primary = _busy || unsignedAfterSigning || hidesSpend
        ? null
        : (_isSigned ? _broadcast : _sign);
    final primaryLabel = _busy
        ? (_isSigned ? 'Broadcasting…' : 'Signing…')
        : (_isSigned ? 'Broadcast' : 'Sign');
    final primaryIcon = _isSigned ? Icons.send : Icons.draw_outlined;

    final actions = phone
        ? <Widget>[
            // Stacked, full width: the primary action on top where the thumb
            // lands, Cancel below it.
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                PrimaryButton(
                  label: primaryLabel,
                  icon: primaryIcon,
                  isLoading: _busy,
                  isFullWidth: true,
                  onPressed: primary,
                ),
                const SizedBox(height: AppSpacing.sm),
                SecondaryButton(
                  label: 'Cancel',
                  isFullWidth: true,
                  onPressed: _busy ? null : () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ]
        : <Widget>[
            TextButton(
              onPressed: _busy ? null : () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton.icon(
              onPressed: primary,
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent),
              icon: _busy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : Icon(primaryIcon, size: 16, color: Colors.white),
              label: Text(
                primaryLabel,
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w600),
              ),
            ),
          ];

    // The Android back gesture must not do what the disabled Cancel refuses:
    // popping mid-broadcast would drop the txid on the floor and leave the
    // caller thinking nothing was sent.
    return PopScope(
      canPop: !_busy,
      child: AppDialog(
        title: Row(
          children: [
            Expanded(child: Text(widget.title)),
            _PhaseBadge(signed: _isSigned),
          ],
        ),
        // The sheet scrolls its own content; the desktop dialog needs a width
        // and a scroll view of its own.
        content: phone
            ? body
            : SizedBox(
                width: 560,
                child: SingleChildScrollView(child: body),
              ),
        actions: actions,
      ),
    );
  }

  /// Phone: the three export routes as plain buttons, each a real touch
  /// target. A popup menu would hide the air-gap QR — the one thing an
  /// external signer needs — behind a 36 dp trigger.
  Widget _phoneExportRow() {
    final shares = FileExport.sharesInsteadOfSaves;
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [
        SecondaryButton(label: 'Copy', icon: Icons.copy, onPressed: _copy),
        SecondaryButton(
          label: shares ? 'Share' : 'Save',
          icon: shares ? Icons.ios_share : Icons.save_alt,
          onPressed: _save,
        ),
        SecondaryButton(
            label: 'QR code', icon: Icons.qr_code_2, onPressed: _showQr),
      ],
    );
  }

  Widget _desktopExportMenu(AppScheme s) {
    return Align(
      alignment: Alignment.centerLeft,
      child: PopupMenuButton<_ExportAction>(
        tooltip: 'Export this transaction',
        onSelected: (a) {
          switch (a) {
            case _ExportAction.copy:
              _copy();
            case _ExportAction.file:
              _save();
            case _ExportAction.qr:
              _showQr();
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(
            value: _ExportAction.copy,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.copy, size: 18),
              title: Text('Copy PSBT'),
            ),
          ),
          PopupMenuItem(
            value: _ExportAction.file,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.save_alt, size: 18),
              title: Text('Save as file'),
            ),
          ),
          PopupMenuItem(
            value: _ExportAction.qr,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.qr_code_2, size: 18),
              title: Text('QR code'),
              subtitle: Text('For air-gapped signing'),
            ),
          ),
        ],
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: AppSpacing.sm),
          decoration: BoxDecoration(
            border: Border.all(color: s.edge),
            borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.ios_share, size: 16, color: s.inkSecondary),
              const SizedBox(width: AppSpacing.sm),
              Text('Export',
                  style: AppTypography.bodySmall.copyWith(color: s.ink)),
              Icon(Icons.arrow_drop_down, size: 18, color: s.inkSecondary),
            ],
          ),
        ),
      ),
    );
  }

  Widget _details(PsbtInspection? i, AppScheme s, bool phone) {
    if (i == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    // One unknown input makes the total unknown: a sum over the priced ones
    // would read as the whole amount at stake, which is exactly what a PSBT
    // with a hidden input wants the user to believe.
    final priced = !i.inputs.any((x) => x.amountSats == null);
    final inTotal = priced
        ? '${i.inputs.fold<int>(0, (sum, x) => sum + x.amountSats!)} sats'
        : 'amount unknown';
    final ownLabel = Text(
      'CHANGE',
      style: AppTypography.label.copyWith(color: s.inkSecondary),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('SPENDS', style: AppTypography.navSection),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '${i.inputs.length} coin${i.inputs.length == 1 ? '' : 's'} · $inTotal',
          style: AppTypography.bodySmall
              .copyWith(color: priced ? null : AppColors.danger),
        ),
        const SizedBox(height: AppSpacing.lg),
        Text('PAYS', style: AppTypography.navSection),
        const SizedBox(height: AppSpacing.xs),
        // Own outputs are the change this wallet built into the transaction;
        // saying so leaves the recipient as the one line to check.
        ...i.outputs.map(
          (o) => Padding(
            padding: EdgeInsets.only(
                bottom: phone ? AppSpacing.sm : AppSpacing.xs),
            child: phone
                // The whole address, wrapped: the tail is the checksum, the
                // part the user is asked to check before signing, and an
                // ellipsis would remove exactly that.
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(o.address,
                          style: AppTypography.monoSmall, softWrap: true),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          if (i.ownershipKnown && o.isMine == true) ownLabel,
                          const Spacer(),
                          Text(o.displayAmount,
                              style: AppTypography.bodySmall,
                              textAlign: TextAlign.right),
                        ],
                      ),
                    ],
                  )
                : Row(
                    children: [
                      Expanded(
                        child: Text(o.address,
                            style: AppTypography.monoSmall,
                            overflow: TextOverflow.ellipsis),
                      ),
                      if (i.ownershipKnown && o.isMine == true) ...[
                        const SizedBox(width: AppSpacing.sm),
                        ownLabel,
                      ],
                      const SizedBox(width: AppSpacing.md),
                      Text(o.displayAmount, style: AppTypography.bodySmall),
                    ],
                  ),
          ),
        ),
        const Divider(height: AppSpacing.xl),
        _row('Fee', i.feeLabel, s, phone),
        _row(
          'Signatures',
          i.sigsRequired != null
              ? '${i.sigsPresent} of ${i.sigsRequired}'
              : '${i.sigsPresent}',
          s,
          phone,
        ),
        if (i.policyHint.isNotEmpty) _row('Policy', i.policyHint, s, phone),
      ],
    );
  }

  Widget _row(String label, String value, AppScheme s, bool phone) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.xs),
        child: Row(
          // Top-aligned only where the value can wrap to several lines.
          crossAxisAlignment:
              phone ? CrossAxisAlignment.start : CrossAxisAlignment.center,
          children: [
            Text(label,
                style: AppTypography.label.copyWith(color: s.inkSecondary)),
            if (phone) ...[
              // A policy hint can be a sentence; let it wrap instead of
              // ellipsising the part that says what the wallet requires.
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(value,
                    style: AppTypography.bodySmall,
                    textAlign: TextAlign.right,
                    softWrap: true),
              ),
            ] else ...[
              const Spacer(),
              Flexible(
                child: Text(value,
                    style: AppTypography.bodySmall,
                    overflow: TextOverflow.ellipsis),
              ),
            ],
          ],
        ),
      );
}

/// Which of the two passes the user is looking at. The QR alone cannot say —
/// an unsigned and a signed PSBT look identical as a block of squares.
class _PhaseBadge extends StatelessWidget {
  const _PhaseBadge({required this.signed});
  final bool signed;

  @override
  Widget build(BuildContext context) {
    final color = signed ? AppColors.success : AppColors.warning;
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(signed ? 'SIGNED' : 'UNSIGNED',
          style: AppTypography.label.copyWith(color: color)),
    );
  }
}

class _QrPanel extends StatelessWidget {
  const _QrPanel({
    required this.parts,
    required this.error,
    required this.signed,
    this.size = 220,
  });
  final List<String>? parts;
  final String? error;
  final bool signed;

  /// Side of the QR (and of the placeholder while it is being encoded).
  final double size;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    Widget body;
    if (error != null) {
      body = SizedBox(
        width: size,
        child: Text('QR unavailable: $error',
            style: AppTypography.caption.copyWith(color: AppColors.danger)),
      );
    } else if (parts == null) {
      body = SizedBox(
        width: size,
        height: size,
        child: const Center(child: CircularProgressIndicator()),
      );
    } else {
      body = UrAnimatedQr(parts: parts!, size: size);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        body,
        const SizedBox(height: AppSpacing.xs),
        Text(
          signed ? 'Signed transaction' : 'Unsigned transaction',
          style: AppTypography.caption.copyWith(color: s.inkSecondary),
        ),
      ],
    );
  }
}
