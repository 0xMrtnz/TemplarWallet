// The coin details sheet — what the "i" on every UTXO opens.
//
// A dialog on desktop, a bottom sheet on a phone (showAppDialog), holding
// everything the row or note could not: the whole outpoint, the address it
// sits on, the asset id, the confirmation count, and the rule that put it
// in its tier — plus the one way out to a block explorer and, on the coin
// screen, the switch that freezes the coin.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_state.dart';
import '../../features/utxos/models/utxo.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import 'buttons.dart';
import 'code_box.dart';
import 'glass_dialog.dart';
import 'privacy.dart';
import 'utxo_views.dart';

/// Opens the details sheet for [utxo]. [share] is its slice of the asset's
/// holdings and [tier] the note size that follows from it — both are passed
/// in rather than recomputed so the sheet says exactly what the row said.
/// With [onToggleFrozen] the sheet offers Freeze / Unfreeze; it closes
/// itself before calling it.
Future<void> showUtxoDetails(
  BuildContext context, {
  required Utxo utxo,
  required double share,
  required BanknoteTier tier,
  VoidCallback? onToggleFrozen,
}) {
  // Read the explorer bases here, on the caller's tree: the dialog route
  // sits under the root navigator and may not see the same providers.
  String btcBase = 'https://mempool.space/testnet';
  String liquidBase = 'https://blockstream.info/liquidtestnet';
  try {
    final st = context.read<AppState>();
    btcBase = st.btcExplorerUrl;
    liquidBase = st.liquidExplorerUrl;
  } on ProviderNotFoundException {
    // A bare test host without AppState: the defaults above still make a
    // valid link.
  }
  return showAppDialog<void>(
    context,
    builder: (ctx) => UtxoDetailsDialog(
      utxo: utxo,
      share: share,
      tier: tier,
      explorerBase: utxo.assetId == null ? btcBase : liquidBase,
      // A coin still in the mempool cannot be picked, so it cannot be
      // frozen either.
      onToggleFrozen: utxo.isPending ? null : onToggleFrozen,
    ),
  );
}

class UtxoDetailsDialog extends StatelessWidget {
  const UtxoDetailsDialog({
    super.key,
    required this.utxo,
    required this.share,
    required this.tier,
    required this.explorerBase,
    this.onToggleFrozen,
  });

  final Utxo utxo;
  final double share;
  final BanknoteTier tier;

  /// Freezes or unfreezes the coin; null hides the button.
  final VoidCallback? onToggleFrozen;

  /// The block explorer for this coin's chain, without a trailing slash.
  final String explorerBase;

  String get _explorerUrl {
    final base = explorerBase.endsWith('/')
        ? explorerBase.substring(0, explorerBase.length - 1)
        : explorerBase;
    return '$base/tx/${utxo.txid}';
  }

  Future<void> _openExplorer(BuildContext context) async {
    final url = _explorerUrl;
    // launchUrl answers false (or throws on some OEM builds and restricted
    // work profiles) when nothing can take an https VIEW intent; a silent
    // no-op there reads as a dead button, so the link goes to the clipboard
    // with a word about it.
    var opened = false;
    try {
      opened = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      opened = false;
    }
    if (opened || !context.mounted) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(
      content: Text("Couldn't open a browser — explorer link copied"),
    ));
  }

  String get _stateText => switch (utxo.state) {
        UtxoState.available => 'Available',
        UtxoState.frozen => 'Frozen',
        UtxoState.dusty => 'Dust',
        UtxoState.unconfirmed => 'Pending',
      };

  String get _confirmationsText {
    if (utxo.isPending || utxo.confirmations == 0) {
      return 'In the mempool, not in a block yet';
    }
    return utxo.confirmations == 1
        ? '1 confirmation'
        : '${utxo.confirmations} confirmations';
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final phone = AppLayout.isPhone(context);
    final pending = utxo.isPending;
    final base = pending ? s.inkFaint : tier.base(s.isDark);
    final stateBadge = utxoStateBadge(utxo.state);
    final assetName = utxo.ticker ?? 'BTC';
    final caption = AppTypography.caption.copyWith(color: s.inkSecondary);
    final micro = AppTypography.navSection.copyWith(
      color: s.inkFaint,
      letterSpacing: 1.2,
    );

    Widget fact(String label, Widget value) => Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label.toUpperCase(), style: micro),
              const SizedBox(height: 3),
              value,
            ],
          ),
        );

    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The money first: the amount at hero size, its tier and share
        // right under it, then the bar that draws the share.
        Amount(
          utxo.displayAmount,
          style: AppTypography.numericLargeOf(context).copyWith(
            color: pending ? s.inkSecondary : s.ink,
            fontWeight: FontWeight.w800,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: AppSpacing.xs),
        Row(
          children: [
            if (pending) ...[
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(base),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  'Incoming · ${utxoShareText(share)} of your $assetName once '
                  'it confirms',
                  style: caption,
                ),
              ),
            ] else
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: tier.label,
                        style: TextStyle(
                          color: base,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.0,
                        ),
                      ),
                      TextSpan(
                        text: ' · ${utxoShareText(share)} of your $assetName',
                        style: TextStyle(
                          color: s.inkSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  style: AppTypography.bodySmall,
                ),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        ShareMeter(share: share, color: base, height: 5),
        if (!pending) ...[
          const SizedBox(height: AppSpacing.xs + 2),
          Text(tier.rule, style: caption),
        ],
        const SizedBox(height: AppSpacing.lg),
        Divider(height: 1, color: s.edge),
        const SizedBox(height: AppSpacing.lg),
        Row(
          children: [
            Expanded(
              child: fact(
                'State',
                stateBadge == null
                    ? Text(_stateText,
                        style: AppTypography.bodySmall.copyWith(color: s.ink))
                    : Align(
                        alignment: Alignment.centerLeft,
                        child: utxoStateChip(stateBadge),
                      ),
              ),
            ),
            Expanded(
              flex: 2,
              child: fact(
                'Confirmations',
                Text(
                  _confirmationsText,
                  style: AppTypography.bodySmall.copyWith(
                    color: pending ? s.warning : s.ink,
                  ),
                ),
              ),
            ),
          ],
        ),
        if (utxo.isFrozen)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            child: Text(
              'Frozen: this wallet will not spend it — not in a payment, not '
              'in MAX, not in a consolidation — until you unfreeze it.',
              style: caption,
            ),
          ),
        if (utxo.label case final label?)
          fact(
            'Label',
            Text(label, style: AppTypography.bodySmall.copyWith(color: s.ink)),
          ),
        CodeBox(label: 'Outpoint', value: utxo.outpoint, maxLines: 3),
        if (utxo.address case final address?) ...[
          const SizedBox(height: AppSpacing.md),
          CodeBox(label: 'Address', value: address, maxLines: 3),
        ],
        if (utxo.assetId case final assetId?) ...[
          const SizedBox(height: AppSpacing.md),
          CodeBox(label: 'Asset ID', value: assetId, maxLines: 3),
        ],
      ],
    );

    return AppDialog(
      title: const Text('Coin details'),
      scrollable: true,
      content: SizedBox(
        width: phone ? double.infinity : 440,
        child: content,
      ),
      actions: [
        if (onToggleFrozen case final toggle?)
          if (phone)
            SecondaryButton(
              label: utxo.isFrozen ? 'Unfreeze' : 'Freeze',
              icon: kFrozenIcon,
              onPressed: () {
                Navigator.of(context).pop();
                toggle();
              },
            )
          else
            GhostButton(
              label: utxo.isFrozen ? 'Unfreeze' : 'Freeze',
              icon: kFrozenIcon,
              onPressed: () {
                Navigator.of(context).pop();
                toggle();
              },
            ),
        if (phone)
          SecondaryButton(
            label: 'Open in explorer',
            icon: Icons.open_in_new_rounded,
            onPressed: () => _openExplorer(context),
          )
        else
          GhostButton(
            label: 'Open in explorer',
            icon: Icons.open_in_new_rounded,
            onPressed: () => _openExplorer(context),
          ),
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
