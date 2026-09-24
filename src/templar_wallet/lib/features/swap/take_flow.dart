// Taker side of a LiquiDEX v0 swap: verify a proposal (deep, against testnet
// Electrum), preview the real transaction economics, then sign & broadcast.
//
// Entry points:
//  - [openTakeFlow] — from a takeable order-book row (proposal already known).
//  - [showImportProposalDialog] — paste / file / camera-QR import, returning
//    the proposal JSON for [openTakeFlow].

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_state.dart';
import '../../bridge/bridge_provider.dart';
import '../../shared/widgets/asset_logo.dart';
import '../../shared/widgets/banners.dart';
import '../../shared/widgets/buttons.dart';
import '../../shared/widgets/code_box.dart';
import '../../shared/widgets/hybrid_kit.dart';
import '../../shared/widgets/step_flow_scaffold.dart';
import '../../shared/widgets/ur_qr.dart'
    show cameraScanSupported, showUrScannerDialog;
import '../../theme/app_colors.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../services/file_export.dart';
import '../../theme/app_typography.dart';
import 'models/swap_offer.dart';
import '../../shared/widgets/glass_dialog.dart';

/// Strip the FFI error prefix for display.
String swapError(Object e) =>
    e.toString().replaceFirst('Exception: wallet-ffi: ', '');

/// Push the take flow for [proposalJson]. Resolves to the broadcast txid, or
/// null when the user backed out.
Future<String?> openTakeFlow(BuildContext context,
    {required String proposalJson}) {
  // Root navigator on a phone: the flow must cover the shell chrome.
  return Navigator.of(context, rootNavigator: AppLayout.isPhone(context))
      .push<String>(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => TakeFlowScreen(proposalJson: proposalJson),
  ));
}

// ── Import proposal dialog (paste / file / scan) ──────────────────────────────

/// Collect a LiquiDEX proposal from paste, a `.json`/`.txt` file, or a camera
/// QR. Returns the raw proposal JSON, or null when dismissed. Content is only
/// sanity-checked here — the take flow's verify step does the real validation.
Future<String?> showImportProposalDialog(BuildContext context) {
  return showAppDialog<String>(context,
    builder: (_) => const _ImportProposalDialog(),
  );
}

class _ImportProposalDialog extends StatefulWidget {
  const _ImportProposalDialog();

  @override
  State<_ImportProposalDialog> createState() => _ImportProposalDialogState();
}

class _ImportProposalDialogState extends State<_ImportProposalDialog> {
  final _pasteCtrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pasteCtrl.dispose();
    super.dispose();
  }

  void _submit(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    try {
      final j = jsonDecode(trimmed);
      if (j is! Map<String, dynamic> || !j.containsKey('tx')) {
        setState(() =>
            _error = 'Not a LiquiDEX proposal (expected JSON with a "tx" field).');
        return;
      }
    } catch (_) {
      setState(() => _error = 'Not valid JSON.');
      return;
    }
    Navigator.of(context).pop(trimmed);
  }

  Future<void> _pickFile() async {
    try {
      // Android has no MIME mapping for a proposal file: any file, then the
      // JSON sanity check in _submit.
      final file = await FileExport.pickFile(
        label: 'Proposal',
        extensions: const ['json', 'txt'],
        uniformTypeIdentifiers: const ['public.text', 'public.data'],
      );
      if (file == null) return;
      final text = await file.readAsString();
      if (mounted) _submit(text);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not read file: $e');
    }
  }

  Future<void> _scanQr() async {
    // expectPsbt:false — a plain-text QR payload comes back as `descriptor`.
    final outcome = await showUrScannerDialog(
      context,
      expectPsbt: false,
      title: 'Scan proposal QR code',
    );
    final text = outcome?.descriptor ?? outcome?.psbtBase64;
    if (text == null || text.trim().isEmpty || !mounted) return;
    _submit(text);
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return AppDialog(
      title: const Text('Import swap proposal'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null) ...[
              DangerBanner(message: _error!),
              const SizedBox(height: AppSpacing.md),
            ],
            TextField(
              controller: _pasteCtrl,
              maxLines: 6,
              style: AppTypography.monoSmall,
              decoration: const InputDecoration(
                hintText: 'Paste the LiquiDEX v0 proposal JSON here…',
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                SecondaryButton(
                  label: 'From file',
                  icon: Icons.folder_open,
                  onPressed: _pickFile,
                ),
                if (cameraScanSupported) ...[
                  const SizedBox(width: AppSpacing.sm),
                  SecondaryButton(
                    label: 'Scan QR',
                    icon: Icons.qr_code_scanner,
                    onPressed: _scanQr,
                  ),
                ],
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'The proposal is verified against Liquid testnet on the next '
              'step — nothing is signed yet.',
              style: AppTypography.caption.copyWith(color: s.inkSecondary),
            ),
          ],
        ),
      ),
      actions: [
        GhostButton(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
        PrimaryButton(
          label: 'Verify proposal',
          icon: Icons.arrow_forward,
          onPressed: () => _submit(_pasteCtrl.text),
        ),
      ],
    );
  }
}

// ── Take flow screen ──────────────────────────────────────────────────────────

class TakeFlowScreen extends StatefulWidget {
  const TakeFlowScreen({super.key, required this.proposalJson});

  final String proposalJson;

  @override
  State<TakeFlowScreen> createState() => _TakeFlowScreenState();
}

class _TakeFlowScreenState extends State<TakeFlowScreen> {
  final _bridge = walletBridge;

  /// 0 = verify, 1 = preview. The confirm step is a dialog on top of preview.
  int _step = 0;

  SwapAnalysis? _analysis;
  bool _verifying = true;

  SwapTakePreview? _preview;
  bool _previewing = false;

  bool _taking = false;
  String? _error;

  String? get _walletId => context.read<AppState>().activeWalletId;

  @override
  void initState() {
    super.initState();
    _verify();
  }

  Future<void> _verify() async {
    setState(() {
      _verifying = true;
      _error = null;
    });
    try {
      final analysis =
          await _bridge.swapVerify(widget.proposalJson, deep: true);
      if (!mounted) return;
      setState(() {
        _analysis = analysis;
        _verifying = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _verifying = false;
        _error = swapError(e);
      });
    }
  }

  Future<void> _loadPreview() async {
    final walletId = _walletId;
    if (walletId == null) {
      setState(() => _error = 'No wallet is open.');
      return;
    }
    setState(() {
      _step = 1;
      _previewing = true;
      _preview = null;
      _error = null;
    });
    try {
      final preview =
          await _bridge.swapTakePreview(walletId, widget.proposalJson);
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _previewing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _previewing = false;
        _error = swapError(e);
      });
    }
  }

  Future<void> _confirmAndTake() async {
    final preview = _preview;
    final walletId = _walletId;
    if (preview == null || walletId == null) return;

    final confirmed = await showAppDialog<bool>(context,
          barrierDismissible: false,
          builder: (ctx) => _TakeConfirmDialog(preview: preview),
        ) ??
        false;
    if (!confirmed || !mounted) return;

    setState(() {
      _taking = true;
      _error = null;
    });
    try {
      final txid = await _bridge.swapTake(walletId, widget.proposalJson);
      if (!mounted) return;
      setState(() => _taking = false);

      // The wallet is stale the instant the swap broadcasts — same
      // post-broadcast background sync as the send flow.
      final appState = context.read<AppState>();
      appState.setSyncState(SyncState.syncing);
      unawaited(_bridge
          .syncWallet(walletId)
          .then(appState.applySyncOutcomes)
          .catchError((Object e) {
        debugPrint('[swap] post-take sync failed: $e');
        appState.setSyncState(SyncState.error);
        appState.bumpSync();
      }));

      await showSwapSuccessDialog(
        context,
        txid: txid,
        youReceive: preview.youReceive,
        youPay: preview.youPay,
        feeDisplay: preview.feeDisplay,
      );
      if (mounted) Navigator.of(context).pop(txid);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _taking = false;
        _error = swapError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final onVerify = _step == 0;
    return StepFlowScaffold(
      currentStep: _step + 1,
      totalSteps: 2,
      title: 'Take swap',
      subtitle: onVerify
          ? 'Verify the maker\'s proposal before committing anything'
          : 'Exactly what this swap does to your wallet',
      maxWidth: 760,
      onBack: onVerify
          ? null
          : () => setState(() {
                _step = 0;
                _error = null;
              }),
      onCancel: _taking ? null : () => Navigator.of(context).pop(),
      body: onVerify ? _verifyBody() : _previewBody(),
      actions: _actions(),
    );
  }

  Widget _actions() {
    final analysis = _analysis;
    final onVerify = _step == 0;
    return Row(
      children: [
        GhostButton(
          label: 'Cancel',
          onPressed: _taking ? null : () => Navigator.of(context).pop(),
        ),
        const Spacer(),
        if (onVerify)
          PrimaryButton(
            label: 'Continue',
            icon: Icons.arrow_forward,
            onPressed: (analysis != null && analysis.takeable && !_verifying)
                ? _loadPreview
                : null,
          )
        else
          PrimaryButton(
            label: _taking ? 'Broadcasting…' : 'Take swap',
            icon: Icons.swap_horiz,
            onPressed:
                (_preview != null && !_previewing && !_taking) ? _confirmAndTake : null,
          ),
      ],
    );
  }

  // ── Step 1: verify ──────────────────────────────────────────────────────────

  Widget _verifyBody() {
    final s = AppScheme.of(context);
    if (_verifying) {
      return Padding(
        padding: EdgeInsets.all(AppSpacing.pagePadding(context)),
        child: Column(
          children: [
            const Center(child: CircularProgressIndicator()),
            const SizedBox(height: AppSpacing.md),
            Center(
              child: Text('Verifying proposal against Liquid testnet…',
                  style:
                      AppTypography.caption.copyWith(color: s.inkSecondary)),
            ),
          ],
        ),
      );
    }
    final analysis = _analysis;
    if (analysis == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DangerBanner(message: _error ?? 'Verification failed.'),
          const SizedBox(height: AppSpacing.lg),
          Align(
            alignment: Alignment.centerLeft,
            child: SecondaryButton(
                label: 'Retry', icon: Icons.refresh, onPressed: _verify),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!analysis.takeable) ...[
          DangerBanner(
            title: 'This order cannot be taken',
            message: analysis.takeBlockReason ??
                'The proposal did not pass verification.',
          ),
          const SizedBox(height: AppSpacing.lg),
        ],
        RailPanel(
          title: 'Maker\'s terms',
          rail: s.liquid,
          child: Column(
            children: [
              _legRow('Maker offers (you receive)', analysis.makerOffers,
                  emphasize: true),
              const SizedBox(height: AppSpacing.sm),
              _legRow('Maker wants (you pay)', analysis.makerWants),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  Text('Network',
                      style: AppTypography.caption
                          .copyWith(color: s.inkSecondary)),
                  const Spacer(),
                  TagChip(
                    label: analysis.network,
                    color: analysis.network == 'testnet'
                        ? s.success
                        : s.testnet,
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        RailPanel(
          title: 'Verification checks',
          rail: analysis.valid ? s.success : AppColors.warning,
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (var i = 0; i < analysis.checks.length; i++)
                _checkRow(analysis.checks[i], i.isOdd),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Text(
          'Nothing has been signed. "Continue" builds a preview of the '
          'complete taker transaction so you can inspect the fee and change.',
          style: AppTypography.caption.copyWith(color: s.inkSecondary),
        ),
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.lg),
          DangerBanner(message: _error!),
        ],
      ],
    );
  }

  Widget _checkRow(SwapCheck c, bool zebra) {
    final s = AppScheme.of(context);
    final (icon, color, fallbackNote) = switch (c.ok) {
      true => (Icons.check_circle_outline, s.success, null),
      false => (Icons.warning_amber_rounded, AppColors.warning, 'failed'),
      null => (Icons.hourglass_empty, s.inkFaint, 'not checked'),
    };
    final note = c.note ?? fallbackNote;
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      color: zebra ? s.zebra : Colors.transparent,
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(c.displayName,
                style: AppTypography.bodySmall.copyWith(color: s.ink)),
          ),
          if (note != null)
            Text(note,
                style: AppTypography.caption.copyWith(color: s.inkSecondary)),
        ],
      ),
    );
  }

  // ── Step 2: preview ─────────────────────────────────────────────────────────

  Widget _previewBody() {
    final s = AppScheme.of(context);
    if (_previewing) {
      return Padding(
        padding: EdgeInsets.all(AppSpacing.pagePadding(context)),
        child: Column(
          children: [
            const Center(child: CircularProgressIndicator()),
            const SizedBox(height: AppSpacing.md),
            Center(
              child: Text('Building the taker transaction…',
                  style:
                      AppTypography.caption.copyWith(color: s.inkSecondary)),
            ),
          ],
        ),
      );
    }
    final preview = _preview;
    if (preview == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DangerBanner(message: _error ?? 'Could not build the preview.'),
          const SizedBox(height: AppSpacing.lg),
          Align(
            alignment: Alignment.centerLeft,
            child: SecondaryButton(
                label: 'Retry', icon: Icons.refresh, onPressed: _loadPreview),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RailPanel(
          title: 'Swap recap',
          rail: s.liquid,
          child: Column(
            children: [
              _legRow('You receive', preview.youReceive, emphasize: true),
              const SizedBox(height: AppSpacing.sm),
              _legRow('You pay', preview.youPay),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        DataWell(
          child: Column(
            children: [
              _kvLine('Network fee (paid by you)', preview.feeDisplay),
              for (final c in preview.change) ...[
                const SizedBox(height: AppSpacing.xs),
                _kvLine('Change (back to you)',
                    '${c.displayAmount} ${c.ticker}'),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Text(
          'These numbers come from the real transaction this wallet built — '
          '"Take swap" opens a final confirmation; nothing is signed until '
          'you confirm there.',
          style: AppTypography.caption.copyWith(color: s.inkSecondary),
        ),
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.lg),
          DangerBanner(message: _error!),
        ],
      ],
    );
  }

  Widget _legRow(String label, SwapLeg leg, {bool emphasize = false}) {
    final s = AppScheme.of(context);
    return Row(
      children: [
        AssetLogo(ticker: leg.ticker, size: 22),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(label,
              style: AppTypography.body.copyWith(color: s.inkSecondary)),
        ),
        Text(
          '${leg.displayAmount} ${leg.ticker}',
          style: emphasize
              ? AppTypography.numericLarge
                  .copyWith(fontSize: 18, color: AppColors.accent)
              : AppTypography.numericSmall.copyWith(color: s.ink),
        ),
      ],
    );
  }

  Widget _kvLine(String label, String value) {
    final s = AppScheme.of(context);
    return Row(
      children: [
        Text(label, style: AppTypography.caption.copyWith(color: s.inkFaint)),
        const Spacer(),
        Text(value,
            style: AppTypography.monoSmall
                .copyWith(color: s.ink, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

// ── Confirm dialog ────────────────────────────────────────────────────────────

class _TakeConfirmDialog extends StatelessWidget {
  const _TakeConfirmDialog({required this.preview});

  final SwapTakePreview preview;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return AppDialog(
      title: Row(
        children: [
          Icon(Icons.swap_horiz, color: AppColors.accent, size: 20),
          const SizedBox(width: AppSpacing.sm),
          const Text('Confirm swap'),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DataWell(
              child: Column(
                children: [
                  _line(context, 'You receive',
                      '${preview.youReceive.displayAmount} ${preview.youReceive.ticker}'),
                  const SizedBox(height: AppSpacing.xs),
                  _line(context, 'You pay',
                      '${preview.youPay.displayAmount} ${preview.youPay.ticker}'),
                  const SizedBox(height: AppSpacing.xs),
                  _line(context, 'Fee', preview.feeDisplay),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              'Your inputs are signed and the complete swap transaction is '
              'broadcast to Liquid testnet immediately. Atomic: either the '
              'whole swap settles, or nothing moves.',
              style: AppTypography.caption.copyWith(color: s.inkSecondary),
            ),
          ],
        ),
      ),
      actions: [
        GhostButton(
            label: 'Back', onPressed: () => Navigator.of(context).pop(false)),
        PrimaryButton(
          label: 'Sign & broadcast swap',
          icon: Icons.send_rounded,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
  }

  Widget _line(BuildContext context, String label, String value) {
    final s = AppScheme.of(context);
    return Row(
      children: [
        Text(label, style: AppTypography.caption.copyWith(color: s.inkFaint)),
        const Spacer(),
        Text(value,
            style: AppTypography.monoSmall
                .copyWith(color: s.ink, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

// ── Success dialog ────────────────────────────────────────────────────────────

/// Post-broadcast recap, mirroring [showTxSuccessDialog]'s look for swaps.
Future<void> showSwapSuccessDialog(
  BuildContext context, {
  required String txid,
  required SwapLeg youReceive,
  required SwapLeg youPay,
  required String feeDisplay,
}) {
  return showAppDialog<void>(context,
    barrierDismissible: false,
    builder: (_) => _SwapSuccessDialog(
      txid: txid,
      youReceive: youReceive,
      youPay: youPay,
      feeDisplay: feeDisplay,
    ),
  );
}

class _SwapSuccessDialog extends StatelessWidget {
  const _SwapSuccessDialog({
    required this.txid,
    required this.youReceive,
    required this.youPay,
    required this.feeDisplay,
  });

  final String txid;
  final SwapLeg youReceive;
  final SwapLeg youPay;
  final String feeDisplay;

  Future<void> _openExplorer(BuildContext context) async {
    final base = context.read<AppState>().liquidExplorerUrl;
    final trimmed =
        base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final uri = Uri.parse('$trimmed/tx/$txid');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return AppDialog(
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Pop(
                child: Center(
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: s.success,
                      boxShadow: [
                        BoxShadow(
                          color: s.success.withValues(alpha: 0.3),
                          blurRadius: 22,
                        ),
                      ],
                    ),
                    child: const Icon(Icons.swap_horiz_rounded,
                        color: Colors.white, size: 32),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Reveal(
                delay: 1,
                child: Text('Swap broadcast',
                    textAlign: TextAlign.center,
                    style: AppTypography.pageTitle),
              ),
              const SizedBox(height: AppSpacing.xs),
              Reveal(
                delay: 2,
                child: Text(
                  'The atomic swap was signed and sent to the Liquid testnet.',
                  textAlign: TextAlign.center,
                  style:
                      AppTypography.bodySmall.copyWith(color: s.inkSecondary),
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              Reveal(
                delay: 3,
                child: DataWell(
                  child: Column(
                    children: [
                      _line(context, 'You receive',
                          '${youReceive.displayAmount} ${youReceive.ticker}'),
                      const SizedBox(height: AppSpacing.xs),
                      _line(context, 'You pay',
                          '${youPay.displayAmount} ${youPay.ticker}'),
                      const SizedBox(height: AppSpacing.xs),
                      _line(context, 'Fee', feeDisplay),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Reveal(delay: 5, child: CodeBox(value: txid, label: 'TxID')),
            ],
          ),
        ),
      ),
      actions: [
        SecondaryButton(
          label: 'View on explorer',
          icon: Icons.open_in_new_rounded,
          onPressed: () => _openExplorer(context),
        ),
        PrimaryButton(
          label: 'Done',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }

  Widget _line(BuildContext context, String label, String value) {
    final s = AppScheme.of(context);
    return Row(
      children: [
        Text(label, style: AppTypography.caption.copyWith(color: s.inkFaint)),
        const Spacer(),
        Text(value,
            style: AppTypography.monoSmall
                .copyWith(color: s.ink, fontWeight: FontWeight.w600)),
      ],
    );
  }
}
