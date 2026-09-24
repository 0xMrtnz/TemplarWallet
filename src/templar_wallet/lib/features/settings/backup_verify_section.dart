// Settings → Security → Recovery phrase backup.
//
// The user types the phrase off their paper and the engine derives public keys
// from it and compares them with this wallet's own. See `handlers/backup.rs`
// for why re-entry replaced the old random-word quiz; the short version is that
// a quiz cannot catch a transposed word, cannot catch a phrase belonging to a
// different wallet, and cannot run at all for hardware or air-gap wallets —
// which is exactly where an unverified backup is unrecoverable.

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../bridge/bridge_provider.dart';
import '../../bridge/wallet_bridge.dart';
import '../../shared/widgets/buttons.dart';
import '../../shared/widgets/cards.dart';
import '../../shared/widgets/glass_dialog.dart';
import '../../shared/widgets/list_rows.dart';
import '../../shared/widgets/segmented_switch.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';

/// When each wallet's paper backup last checked out.
///
/// Deliberately *not* in the encrypted registry: a date is not a secret, and
/// putting it there would mean the reminder can only be read after unlocking.
/// A wrong or missing date can only ever cause an extra check.
class BackupVerifiedStore {
  BackupVerifiedStore._();
  static final instance = BackupVerifiedStore._();

  String _key(String walletId) => 'backup_verified_$walletId';

  Future<DateTime?> lastVerified(String walletId) async {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(_key(walletId));
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<void> markVerified(String walletId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_key(walletId), DateTime.now().millisecondsSinceEpoch);
  }
}

class BackupVerifyCard extends StatefulWidget {
  const BackupVerifyCard({super.key, required this.walletId});
  final String walletId;

  @override
  State<BackupVerifyCard> createState() => _BackupVerifyCardState();
}

class _BackupVerifyCardState extends State<BackupVerifyCard> {
  DateTime? _lastVerified;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant BackupVerifyCard old) {
    super.didUpdateWidget(old);
    if (old.walletId != widget.walletId) _load();
  }

  Future<void> _load() async {
    final at = await BackupVerifiedStore.instance.lastVerified(widget.walletId);
    if (mounted) setState(() => _lastVerified = at);
  }

  Future<void> _verify() async {
    final ok = await showAppDialog<bool>(context,
      builder: (_) => _ReEntryDialog(walletId: widget.walletId),
    );
    if (ok == true) {
      await BackupVerifiedStore.instance.markVerified(widget.walletId);
      if (mounted) await _load();
    }
  }

  /// Rough age, in the units people actually think in about backups.
  String _ago(DateTime t) {
    final d = DateTime.now().difference(t).inDays;
    if (d <= 0) return 'today';
    if (d == 1) return 'yesterday';
    if (d < 30) return '$d days ago';
    final months = (d / 30).round();
    if (months < 12) return '$months month${months == 1 ? '' : 's'} ago';
    final years = (d / 365).round();
    return '$years year${years == 1 ? '' : 's'} ago';
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final last = _lastVerified;
    // Six months: long enough not to nag, short enough that a backup lost in a
    // move is found before it is needed.
    final stale =
        last != null &&
        DateTime.now().difference(last) > const Duration(days: 182);

    // The three states, once: both skins draw the same glyph and the same
    // tint for the same fact.
    final icon = last == null
        ? Icons.help_outline_rounded
        : stale
        ? Icons.schedule_rounded
        : Icons.verified_user_outlined;
    final tint = last == null
        ? s.inkFaint
        : stale
        ? s.warning
        : s.success;

    if (AppLayout.isPhone(context)) {
      // A state and one way into it — which is exactly a list row, and is how
      // the settings root next door draws the same kind of thing. The
      // paragraph moves under the group: a row subtitle is one line, and on a
      // 347 dp column that is about thirty characters.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ListSectionLabel(label: 'Backup check'),
          ListCard(
            children: [
              ListRow(
                icon: icon,
                tint: tint,
                title: 'Recovery phrase backup',
                subtitle: last == null
                    ? 'Never verified'
                    : stale
                    ? 'Verified ${_ago(last)} — check again'
                    : 'Verified ${_ago(last)}',
                subtitleColor: tint,
                chevron: true,
                onTap: _verify,
              ),
            ],
          ),
          const _SectionNote(
            text:
                'Type your written phrase back in and Templar checks that it '
                'really restores this wallet. Nothing is revealed — the words '
                'you type are turned into public keys and compared with this '
                "wallet's own, so a wrong or out-of-order word simply fails.",
          ),
        ],
      );
    }

    return SectionCard(
      title: 'Recovery phrase backup',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Type your written phrase back in and Templar checks that it '
            'really restores this wallet. Nothing is revealed — the words you '
            'type are turned into public keys and compared with this wallet\'s '
            'own, so a wrong or out-of-order word simply fails.',
            style: AppTypography.caption,
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Icon(icon, size: 16, color: tint),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  last == null
                      // "computer" is wrong on a phone, and the codebase
                      // already knows the difference elsewhere.
                      ? 'Never verified on this '
                          '${Platform.isAndroid ? 'device' : 'computer'}.'
                      : stale
                      ? 'Last verified ${_ago(last)} — worth checking again.'
                      : 'Backup verified ${_ago(last)}.',
                  style: AppTypography.bodySmall.copyWith(
                    color: last == null ? s.inkSecondary : tint,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          SecondaryButton(
            label: 'Verify backup',
            icon: Icons.fact_check_outlined,
            onPressed: _verify,
          ),
        ],
      ),
    );
  }
}

/// The footnote under a phone list group — the paragraph a one-line [ListRow]
/// subtitle cannot hold. A copy of the one in settings_screen.dart: it belongs
/// in list_rows.dart, which is owned elsewhere this pass.
class _SectionNote extends StatelessWidget {
  const _SectionNote({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, AppSpacing.sm, 2, 0),
      child: Text(
        text,
        style: AppTypography.caption.copyWith(
          fontSize: 12.5,
          color: s.inkSecondary,
          height: 1.35,
        ),
      ),
    );
  }
}

// ── Re-entry dialog ───────────────────────────────────────────────────────────

class _ReEntryDialog extends StatefulWidget {
  const _ReEntryDialog({required this.walletId});
  final String walletId;

  @override
  State<_ReEntryDialog> createState() => _ReEntryDialogState();
}

class _ReEntryDialogState extends State<_ReEntryDialog> {
  /// 12 or 24. Not derivable from the wallet — a hardware wallet's word count
  /// never crosses the USB link — so the user says which they wrote down.
  int _wordCount = 12;
  late List<TextEditingController> _ctrls = _makeCtrls(12);
  BackupVerification? _result;
  bool _checking = false;
  String? _error;

  /// Guards the re-entrant write in [_spread] — filling the other boxes fires
  /// their listeners, which would try to spread again.
  bool _spreading = false;

  List<TextEditingController> _makeCtrls(int n) => List.generate(n, (i) {
    final c = TextEditingController();
    // Listener, not `onChanged`: a paste from a password manager, an undo, or
    // a macOS autofill all move the controller without going through the
    // field's onChanged, and the Check button's enabled state has to follow
    // the actual contents.
    c.addListener(() => _onFieldChanged(i, c));
    return c;
  });

  void _onFieldChanged(int i, TextEditingController c) {
    if (_spreading || !mounted) return;
    if (c.text.trim().contains(RegExp(r'\s'))) {
      _spread(i, c.text);
      return;
    }
    setState(() {
      _result = null;
      _error = null;
    });
  }

  @override
  void dispose() {
    for (final c in _ctrls) {
      c.dispose();
    }
    super.dispose();
  }

  void _setWordCount(int n) {
    if (n == _wordCount) return;
    final old = _ctrls;
    setState(() {
      _wordCount = n;
      _ctrls = _makeCtrls(n);
      _result = null;
    });
    for (final c in old) {
      c.dispose();
    }
  }

  /// Pasting the whole phrase into any box spreads it across the grid — people
  /// keep backups in password managers, and retyping 24 words by hand to check
  /// a backup is how a check gets skipped.
  void _spread(int index, String text) {
    // ignore: parameter_assignments — a longer phrase resets the grid to box 1.
    final words = text
        .split(RegExp(r'[^A-Za-z]+'))
        .where((w) => w.isNotEmpty)
        .map((w) => w.toLowerCase())
        .toList();
    if (words.length < 2) return;
    if (words.length > _wordCount &&
        (words.length == 12 || words.length == 24)) {
      _setWordCount(words.length);
      index = 0;
    }
    _spreading = true;
    for (var i = 0; i + index < _ctrls.length && i < words.length; i++) {
      _ctrls[i + index].text = words[i];
    }
    _spreading = false;
    setState(() {
      _result = null;
      _error = null;
    });
  }

  String get _phrase => _ctrls.map((c) => c.text.trim()).join(' ').trim();

  bool get _complete => _ctrls.every((c) => c.text.trim().isNotEmpty);

  Future<void> _check() async {
    if (!_complete || _checking) return;
    setState(() {
      _checking = true;
      _error = null;
      _result = null;
    });
    try {
      final r = await walletBridge.verifyBackup(widget.walletId, _phrase);
      if (mounted) {
        setState(() {
          _result = r;
          _checking = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _checking = false;
          _error = e
              .toString()
              .replaceFirst('Exception: ', '')
              .replaceFirst('wallet-ffi: ', '');
        });
      }
    }
  }

  /// One numbered box of the grid.
  ///
  /// The number lives outside the field, not as `prefixText`: Flutter hides a
  /// prefix until the field has focus or content, so an empty grid showed no
  /// positions at all — the one thing the user is checking against paper.
  Widget _wordCell(int i, AppScheme s, bool phone) => Row(
        children: [
          SizedBox(
            width: 22,
            child: Text(
              '${i + 1}.',
              textAlign: TextAlign.right,
              style: AppTypography.caption.copyWith(color: s.inkFaint),
            ),
          ),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: TextField(
              controller: _ctrls[i],
              autofocus: i == 0,
              autocorrect: false,
              enableSuggestions: false,
              style: AppTypography.mono,
              // isDense shrinks the box below the phone field's own height —
              // and 24 of them are the whole task on this screen.
              decoration: phone
                  ? const InputDecoration()
                  : const InputDecoration(isDense: true),
              textInputAction:
                  i == _wordCount - 1 ? TextInputAction.done : TextInputAction.next,
              onSubmitted: (_) {
                if (i == _wordCount - 1) _check();
              },
            ),
          ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final phone = AppLayout.isPhone(context);
    final r = _result;

    return GlassDialog(
      title: 'Verify your backup',
      icon: Icons.fact_check_outlined,
      // In a sheet the actions land in an end-aligned Wrap: full width, they
      // stack as bars instead of two right-hugging chips. PrimaryButton draws
      // this same 16 px spinner when isLoading, so the branch collapses.
      actions: phone
          ? [
              GhostButton(
                label: r?.matched == true ? 'Done' : 'Cancel',
                onPressed: () => Navigator.of(context).pop(r?.matched == true),
                isFullWidth: true,
              ),
              if (r?.matched != true)
                PrimaryButton(
                  label: 'Check backup',
                  isLoading: _checking,
                  onPressed: _complete && !_checking ? _check : null,
                  isFullWidth: true,
                ),
            ]
          : [
              TextButton(
                onPressed: () => Navigator.of(context).pop(r?.matched == true),
                child: Text(r?.matched == true ? 'Done' : 'Cancel'),
              ),
              if (r?.matched != true)
                FilledButton(
                  onPressed: _complete && !_checking ? _check : null,
                  child: _checking
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Check backup'),
                ),
            ],
      child: SizedBox(
        width: AppLayout.isPhone(context) ? double.infinity : 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Type the phrase exactly as you wrote it down, in order.',
              style: AppTypography.caption
                  .copyWith(color: phone ? s.inkSecondary : null),
            ),
            const SizedBox(height: AppSpacing.md),
            // Phone: the same track the Liquid network card uses two pages
            // away, rather than Material's own chip fill and radius, which
            // match nothing else here.
            if (phone) ...[
              const ListSectionLabel(label: 'Words'),
              SegmentedSwitch<int>(
                expand: true,
                options: const [
                  SegOption(value: 12, label: '12'),
                  SegOption(value: 24, label: '24'),
                ],
                selected: _wordCount,
                onChanged: _setWordCount,
              ),
            ] else
              Row(
                children: [
                  Text('Words:', style: AppTypography.caption),
                  const SizedBox(width: AppSpacing.sm),
                  for (final n in const [12, 24]) ...[
                    ChoiceChip(
                      label: Text('$n'),
                      selected: _wordCount == n,
                      onSelected: (_) => _setWordCount(n),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                  ],
                ],
              ),
            const SizedBox(height: AppSpacing.md),
            // Phone: no inner scroller and no 320 dp window. The sheet this
            // dialog becomes already scrolls (AppSheet caps itself at 90% of
            // the screen), and two scrollables inside one another fight for
            // the same drag. The cells divide the width instead of taking a
            // fixed 155, so the two columns align with the sheet's edges.
            if (phone)
              LayoutBuilder(
                builder: (context, c) {
                  // Floored: two cells plus the gap must never round up past
                  // the line, or the grid collapses to one column.
                  final cell = ((c.maxWidth - AppSpacing.sm) / 2).floorToDouble();
                  return Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    children: [
                      for (var i = 0; i < _wordCount; i++)
                        SizedBox(width: cell, child: _wordCell(i, s, phone)),
                    ],
                  );
                },
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    children: [
                      for (var i = 0; i < _wordCount; i++)
                        SizedBox(width: 155, child: _wordCell(i, s, phone)),
                    ],
                  ),
                ),
              ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.md),
              Text(
                _error!,
                style: AppTypography.bodySmall.copyWith(color: s.danger),
              ),
            ],
            if (r != null) ...[
              const SizedBox(height: AppSpacing.md),
              _ResultBanner(result: r),
            ],
          ],
        ),
      ),
    );
  }
}

class _ResultBanner extends StatelessWidget {
  const _ResultBanner({required this.result});
  final BackupVerification result;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final ok = result.matched;
    final color = ok ? s.success : s.danger;

    final String headline;
    final String detail;
    if (ok) {
      headline = 'Backup verified';
      detail = 'This phrase restores this wallet. Put it back somewhere safe.';
    } else {
      switch (result.reason) {
        case 'checksum':
          headline = 'Not a valid recovery phrase';
          detail =
              'One or more words are wrong, missing, or in the wrong '
              'order. Every word is checked against the BIP39 list and the '
              'phrase carries its own checksum, so this fails before any key '
              'is derived. Check your paper against it word by word.';
        case 'no_reference':
          headline = 'Cannot verify this wallet';
          detail =
              'This wallet records no extended public key to compare a '
              'phrase against, so there is nothing to check it with.';
        default:
          headline = 'This is a different wallet';
          detail =
              'The phrase is valid, but it belongs to another wallet — '
              'it derives fingerprint ${result.derivedFingerprint}, and this '
              'wallet is ${result.expectedFingerprint}. If your device adds a '
              'BIP39 passphrase to the seed, the words alone will never match '
              'here.';
      }
    }

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            ok ? Icons.verified_rounded : Icons.error_outline_rounded,
            size: 18,
            color: color,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  headline,
                  style: AppTypography.bodySmall.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: AppTypography.caption.copyWith(color: s.inkSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
