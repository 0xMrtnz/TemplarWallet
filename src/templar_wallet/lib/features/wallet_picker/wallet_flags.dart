// The one-line description under a wallet's name on the home index: how its
// keys are held, which chains it carries, and which key it actually is.
//
// Both questions get asked before a wallet is opened, and neither was
// answerable from the list: with three Jades and two software wallets,
// "Hardware (09026b48)" is a fingerprint, not an answer, and nothing said
// whether Liquid lived in this wallet or another one. A wrong guess costs a
// wallet open, a device unlock, and a trip back.
//
// This used to render as a row of coloured pills. Pills made three competing
// shapes out of what is really one sentence, and the accent variant put brand
// red on every single row — on the index, red means "the row you are pointing
// at" and nothing else.

import 'package:flutter/material.dart';

import '../../theme/app_scheme.dart';
import '../../theme/app_typography.dart';
import 'models/wallet_summary.dart';

class WalletFlags extends StatelessWidget {
  const WalletFlags({
    super.key,
    required this.wallet,
    this.compact = false,
    this.stacked = false,
    this.color,
  });

  final WalletSummary wallet;

  /// Drop to the single most identifying fact — for tight rows.
  final bool compact;

  /// Break the fingerprint onto its own second line. A gallery tile is only
  /// ~270px wide, and one run of "Software · BTC + Liquid · f0b68896" ellipsed
  /// the fingerprint down to "f…" — the one fact on the line you cannot guess.
  final bool stacked;

  /// Overrides the text colour.
  final Color? color;

  /// The facts, in the order they are worth reading: what holds the keys,
  /// which chains are on it, and which key it is.
  static List<String> partsOf(WalletSummary w, {bool compact = false}) {
    final parts = <String>[];
    final kind = w.keyOriginLabel;
    if (kind != null) parts.add(kind);
    if (!compact) parts.add(w.networksLabel);
    return parts;
  }

  /// Icon for the key-origin fact — the one glyph worth keeping.
  static IconData kindIcon(WalletSummary w) {
    if (w.isAirgapWallet) return Icons.qr_code_2_rounded;
    if (w.isViewOnlyWallet) return Icons.visibility_outlined;
    if (w.type == WalletType.multisig) return Icons.groups_rounded;
    if (w.isHardwareWallet) return Icons.usb_rounded;
    return Icons.vpn_key_rounded;
  }

  /// The same mapping, from the display label the shell carries.
  ///
  /// Inside an open wallet there is no [WalletSummary] — AppState keeps only
  /// the type label ("Multisig 2-of-3", "Air-gap watch-only", …) — but the
  /// sidebar has to draw the same mark the gallery drew, so it resolves the
  /// icon from that string. Air-gap is tested first: "Air-gap watch-only"
  /// contains "watch-only" and would otherwise match the wrong branch.
  static IconData kindIconForLabel(String? label) {
    final t = (label ?? '').toLowerCase();
    if (t.contains('air-gap') || t.contains('airgap')) {
      return Icons.qr_code_2_rounded;
    }
    if (t == 'watch-only' || t.contains('watch only')) {
      return Icons.visibility_outlined;
    }
    if (t.contains('multisig') || RegExp(r'\d+-of-\d+').hasMatch(t)) {
      return Icons.groups_rounded;
    }
    if (t.contains('hardware') ||
        t.contains('jade') ||
        t.contains('ledger') ||
        t.contains('usb')) {
      return Icons.usb_rounded;
    }
    return Icons.vpn_key_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final parts = partsOf(wallet, compact: compact);
    final fp = wallet.masterFingerprint;
    final ink = color ?? s.inkSecondary;
    final hasFp = fp != null && fp.isNotEmpty;

    if (stacked) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            parts.join('  ·  '),
            style: AppTypography.bodySmall.copyWith(color: ink, height: 1.35),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          // The slot is reserved even when there is no fingerprint (a
          // coordinator-built multisig has none), so headlines and fact lines
          // stay on one baseline across a row of tiles.
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              hasFp ? fp : '',
              style: AppTypography.monoSmall.copyWith(color: s.inkFaint),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    }

    return Text.rich(
      TextSpan(
        style: AppTypography.bodySmall.copyWith(color: ink, height: 1.35),
        children: [
          TextSpan(text: parts.join('  ·  ')),
          // The fingerprint stays monospaced: it is a value to compare
          // character by character, not prose.
          //
          // No fallback when it is missing. The obvious one — the threshold —
          // is ALREADY the key-origin label for a multisig, and appending it
          // here printed "2-of-3 · BTC only · 2-of-3".
          if (hasFp) ...[
            const TextSpan(text: '  ·  '),
            TextSpan(
              text: fp,
              style: AppTypography.monoSmall.copyWith(color: ink),
            ),
          ],
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
