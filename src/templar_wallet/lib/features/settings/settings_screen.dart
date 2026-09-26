import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../app/app_state.dart';
import '../../app/app_version.dart';
import '../../app/routes.dart';
import '../../bridge/bridge_provider.dart';
import '../../bridge/wallet_bridge.dart';
import '../vault/lock_action.dart';
import '../vault/vault_setup_sheet.dart';
import '../../services/auto_lock.dart';
import '../../services/biometric_unlock_service.dart';
import '../../services/price_service.dart';
import '../../services/protocol_store.dart';
import '../../services/cosigner_label_store.dart';
import '../../services/wallet_customization_store.dart';
import '../../shared/widgets/banners.dart';
import '../../shared/widgets/buttons.dart';
import '../../shared/widgets/cards.dart';
import '../../shared/widgets/code_box.dart';
import '../../shared/widgets/cosigner_label_editor.dart';
import '../../shared/widgets/cosigner_ring.dart';
import '../../shared/widgets/glass_dialog.dart';
import '../../shared/widgets/list_rows.dart';
import '../../shared/widgets/page_header.dart';
import '../../shared/widgets/segmented_switch.dart';
import 'backup_verify_section.dart';
import 'biometric_unlock_tile.dart';
import 'liquid_network_switch.dart';
import 'protocol_section.dart';
import 'seed_phrase_section.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import 'package:url_launcher/url_launcher.dart';

/// A settings section. Each is a route of its own (see [AppRoutes]): on a
/// phone that is what makes a section a sub-page, with the shell's back
/// arrow and the system back both returning to the settings list.
enum SettingsSection {
  network('Network & Sync', Icons.wifi_outlined, AppRoutes.settingsNetwork),
  protocol('Templar Protocol', Icons.link_outlined, AppRoutes.settingsProtocol),
  security('Security', Icons.lock_outline, AppRoutes.settingsSecurity),
  appearance(
    'Appearance',
    Icons.palette_outlined,
    AppRoutes.settingsAppearance,
  ),
  about('About', Icons.info_outline, AppRoutes.settingsAbout);

  const SettingsSection(this.label, this.icon, this.route);

  final String label;
  final IconData icon;
  final String route;
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.section});

  /// The section to open. Null shows the settings list on a phone and the
  /// first section on desktop.
  final SettingsSection? section;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  /// Desktop: the pane on show. The menu switches it locally; a section
  /// route only picks the one to start on.
  late SettingsSection _section = widget.section ?? SettingsSection.network;

  @override
  void didUpdateWidget(SettingsScreen old) {
    super.didUpdateWidget(old);
    final next = widget.section;
    if (next != null && next != old.section) _section = next;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Phones: the settings root is a list of sections (one row each, icon
    // plate, name, what is inside), and a section is a page of its own under
    // the shell's "‹ Section" header. Desktop keeps its two panes whatever
    // the window size.
    if (AppLayout.isPhone(context)) {
      final section = widget.section;
      if (section == null) return const _SettingsHome();
      final p = AppSpacing.pagePadding(context);
      // No Scaffold of its own: MobileShell supplies the Scaffold, the
      // background and the SafeArea (a nested Scaffold would show every
      // SnackBar twice).
      return ColoredBox(
        color: isDark ? AppColors.backgroundDark : AppColors.backgroundLight,
        child: ListView(
          // Foot room: the last thing on a section page (the danger card,
          // the source-code row) otherwise ends flush against the system
          // navigation bar, with nothing to say the page stopped.
          padding: EdgeInsets.fromLTRB(p, p, p, p + AppSpacing.xxl),
          children: [_contentOf(section)],
        ),
      );
    }
    return Scaffold(
      backgroundColor: isDark ? AppColors.backgroundDark : AppColors.backgroundLight,
      body: Row(
        children: [
          // Subsection menu
          SizedBox(
            width: 200,
            child: Container(
              color: isDark ? AppColors.surfaceDark : AppColors.surfaceLight,
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.lg),
                    child: Text('Settings', style: AppTypography.sectionTitle),
                  ),
                  for (final s in SettingsSection.values)
                    _sectionTile(s, isDark),
                ],
              ),
            ),
          ),
          const VerticalDivider(width: 1),
          // Content
          Expanded(
            child: ListView(
              padding: EdgeInsets.all(AppSpacing.pagePadding(context)),
              children: [_contentOf(_section)],
            ),
          ),
        ],
      ),
    );
  }

  /// One entry of the desktop menu column.
  Widget _sectionTile(SettingsSection s, bool isDark) {
    final isActive = s == _section;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: InkWell(
        onTap: () => setState(() => _section = s),
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
          decoration: BoxDecoration(
            color: isActive
                ? AppColors.accent.withValues(
                    alpha: isDark ? 0.16 : 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
          ),
          child: Row(
            children: [
              Icon(s.icon, size: 16, color: isActive ? AppColors.accent : null),
              const SizedBox(width: AppSpacing.sm),
              Text(s.label, style: AppTypography.navItem.copyWith(
                color: isActive ? AppColors.accent : null,
                fontWeight: isActive ? FontWeight.w600 : null,
              )),
            ],
          ),
        ),
      ),
    );
  }

  Widget _contentOf(SettingsSection section) => switch (section) {
        SettingsSection.network => _NetworkSection(),
        SettingsSection.protocol => const ProtocolSection(),
        SettingsSection.security => _SecuritySection(),
        SettingsSection.appearance => _AppearanceSection(),
        SettingsSection.about => _AboutSection(),
      };
}

// ── Phone: the settings list ──────────────────────────────────────────────────
//
// Groups, not one long card. Each group is a subject — what protects the
// wallet, how it looks, what it talks to — and inside it the switches a user
// actually flips sit inline, while the rows that need a whole page carry a
// chevron to one. Wallet info is the first row: it is the wallet's public
// face and used to cost a carousel slot of its own.

class _SettingsHome extends StatefulWidget {
  const _SettingsHome();

  @override
  State<_SettingsHome> createState() => _SettingsHomeState();
}

class _SettingsHomeState extends State<_SettingsHome> {
  /// Whether a Lock row belongs here: there is nothing to lock until a vault
  /// exists and is open.
  bool _vaultUnlocked = false;

  /// Whether this device has a fingerprint sensor at all. Asked here rather
  /// than inside the row so the card never loses a row after it is drawn.
  bool _hasBiometrics = false;

  /// How many sites hold a watch-only view, for the Templar Protocol row's subtitle.
  /// Null until read — the row then states the network alone rather than
  /// claiming "no site connected" before looking.
  int? _protocolSites;

  @override
  void initState() {
    super.initState();
    _refreshVault();
    _refreshBiometrics();
    _refreshProtocol();
  }

  Future<void> _refreshProtocol() async {
    final sites = await ProtocolStore.instance.sites();
    if (mounted) setState(() => _protocolSites = sites.length);
  }

  /// "Liquid regtest · 2 sites connected" — what the section would say.
  String _protocolSubtitle(AppState st) {
    final net = st.liquidNetwork?.shortName ?? 'testnet';
    final n = _protocolSites;
    if (n == null) return 'Liquid $net';
    if (n == 0) return 'Liquid $net · no site connected';
    return 'Liquid $net · $n site${n == 1 ? '' : 's'} connected';
  }

  Future<void> _refreshVault() async {
    try {
      final v = await walletBridge.vaultStatus();
      if (mounted) {
        setState(() => _vaultUnlocked = v.initialized && v.unlocked);
      }
    } catch (_) {
      // No status, no row — never guess that storage is unlocked.
    }
  }

  Future<void> _refreshBiometrics() async {
    if (!BiometricUnlockService.platformSupported) return;
    try {
      final a = await BiometricUnlockService.instance.availability();
      if (mounted) {
        setState(() =>
            _hasBiometrics = a != BiometricAvailability.unavailable);
      }
    } catch (_) {
      // No sensor answer, no row.
    }
  }

  Future<void> _lock() async {
    await lockVaultAndPrompt(context);
    if (mounted) _refreshVault();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final st = context.watch<AppState>();
    final theme = switch (st.themeMode) {
      ThemeMode.dark => 'Dark',
      ThemeMode.light => 'Light',
      ThemeMode.system => 'System',
    };
    final liquidNet = st.liquidNetwork?.shortName ?? 'testnet';

    return ColoredBox(
      color: s.canvas,
      child: ListView(
        padding: EdgeInsets.all(AppSpacing.pagePadding(context)),
        children: [
          const PageHeader(
            title: 'Settings',
            subtitle: 'Security, appearance, network',
          ),
          const ListSectionLabel(label: 'Wallet'),
          ListCard(
            children: [
              ListRow(
                icon: Icons.key_rounded,
                tint: s.accent,
                title: 'Wallet info',
                subtitle: 'Keys, descriptors, export',
                chevron: true,
                onTap: () => context.go(AppRoutes.walletInfo),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          const ListSectionLabel(label: 'Security'),
          ListCard(
            children: [
              if (_hasBiometrics) const BiometricUnlockTile(compact: true),
              const AutoLockRow(),
              ListRow(
                icon: Icons.lock_rounded,
                tint: s.success,
                title: 'Vault & backup',
                subtitle: 'Passphrase, backup check, seed',
                chevron: true,
                onTap: () => context.go(SettingsSection.security.route),
              ),
              if (_vaultUnlocked)
                ListRow(
                  icon: Icons.lock_clock_rounded,
                  tint: s.success,
                  title: 'Lock now',
                  subtitle: 'Ask for the passphrase again',
                  onTap: _lock,
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          const ListSectionLabel(label: 'Appearance'),
          ListCard(
            children: [
              ListRow(
                icon: Icons.palette_rounded,
                tint: s.bitcoin,
                title: 'Theme & units',
                subtitle: '$theme · ${st.fiatCurrency} · '
                    '${st.useSats ? 'sats' : 'BTC'}',
                chevron: true,
                onTap: () => context.go(SettingsSection.appearance.route),
              ),
              ListRow(
                icon: Icons.blur_on_rounded,
                tint: s.bitcoin,
                title: 'Reduce effects',
                subtitle: 'Solid panels, no blur',
                trailing: ListSwitch(
                  value: st.reduceEffects,
                  onChanged: st.setReduceEffects,
                  semanticLabel: 'Reduce effects',
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          const ListSectionLabel(label: 'Network'),
          ListCard(
            children: [
              ListRow(
                icon: Icons.wifi_rounded,
                tint: s.liquid,
                title: 'Nodes & explorers',
                subtitle: 'Liquid $liquidNet · Bitcoin Electrum',
                chevron: true,
                onTap: () => context.go(SettingsSection.network.route),
              ),
              ListRow(
                icon: Icons.link_rounded,
                tint: s.liquid,
                title: 'Templar Protocol',
                subtitle: _protocolSubtitle(st),
                chevron: true,
                onTap: () => context.go(SettingsSection.protocol.route),
              ),
              ListRow(
                icon: Icons.sync_rounded,
                tint: s.liquid,
                title: 'Auto-sync',
                subtitle: 'Sync this wallet when the app opens',
                trailing: ListSwitch(
                  value: st.autoSync,
                  onChanged: st.setAutoSync,
                  semanticLabel: 'Auto-sync on startup',
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          const ListSectionLabel(label: 'About'),
          ListCard(
            children: [
              ListRow(
                icon: Icons.info_rounded,
                tint: s.inkSecondary,
                title: 'Templar Wallet',
                subtitle: 'v$kAppVersion · Testnet',
                chevron: true,
                onTap: () => context.go(SettingsSection.about.route),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The footnote under a phone list group — the paragraph a one-line [ListRow]
/// subtitle cannot hold, and the reason a group can become rows at all.
///
/// Lives here (and, in copy, in the two section widgets) because it belongs
/// in list_rows.dart, which is owned elsewhere this pass.
class _SettingsNote extends StatelessWidget {
  const _SettingsNote({required this.text, this.color});
  final String text;

  /// Overrides the ink where the note is a state and not a description.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, AppSpacing.sm, 2, 0),
      child: Text(
        text,
        style: AppTypography.caption.copyWith(
          fontSize: 12.5,
          color: color ?? s.inkSecondary,
          height: 1.35,
        ),
      ),
    );
  }
}

// ── Danger zone ───────────────────────────────────────────────────────────────
//
// Last thing on the page, and the only red surface in Settings. Deleting a
// wallet is the one action here that can lose money, so it does not share a
// card with anything else and it does not look like the rest of the app.

class _DangerZone extends StatelessWidget {
  const _DangerZone({required this.onDelete});
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final phone = AppLayout.isPhone(context);
    return Container(
      width: double.infinity,
      // A phone gives back the 8 dp of inset it cannot spare on a 347 dp
      // column, and takes the phone card corner so this reads as the same
      // material as the list cards above it — only red.
      padding: EdgeInsets.all(phone ? AppSpacing.lg : AppSpacing.xl),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: s.isDark ? 0.09 : 0.05),
        borderRadius: BorderRadius.circular(
          phone ? AppSpacing.radiusLg : AppSpacing.radiusMd,
        ),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.warning_amber_rounded,
                  color: AppColors.danger, size: 20),
              const SizedBox(width: AppSpacing.sm),
              Text(
                'DANGER ZONE',
                style: AppTypography.navSection.copyWith(
                  color: AppColors.danger,
                  letterSpacing: 1.4,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            'Delete this wallet',
            style: AppTypography.sectionTitle.copyWith(color: AppColors.danger),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Removes the wallet and its keys from this app. There is no undo '
            'and no copy anywhere else. If you do not hold a written backup of '
            'the recovery phrase, every coin in it becomes unspendable — by '
            'you and by everyone.',
            style: AppTypography.bodySmall.copyWith(color: s.inkSecondary),
          ),
          const SizedBox(height: AppSpacing.lg),
          // Phone: the shared DangerButton is this same red slab at the
          // phone's 54 dp / radius 16, full width so the one irreversible
          // action on the page is one unmissable bar. Desktop keeps its own
          // inline Material button, verbatim.
          if (phone)
            DangerButton(
              label: 'Delete wallet',
              icon: Icons.delete_forever_outlined,
              onPressed: onDelete,
              isFullWidth: true,
            )
          else
            FilledButton.icon(
              onPressed: onDelete,
              icon: const Icon(Icons.delete_forever_outlined, size: 18),
              label: const Text('Delete wallet'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.danger,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.xl,
                  vertical: AppSpacing.md,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The confirmation itself: a forced pause, then a typed phrase.
///
/// A checkbox and an OK button can both be cleared by muscle memory, and the
/// old dialog could be dismissed in two clicks from a screen the user was only
/// browsing. Two gates fix that, and they fix different halves of the problem:
/// the countdown buys time to actually read the warning, and typing
/// "confirm delete" makes the confirmation impossible to hit by accident.
class _DeleteWalletDialog extends StatefulWidget {
  const _DeleteWalletDialog({required this.walletName});
  final String walletName;

  @override
  State<_DeleteWalletDialog> createState() => _DeleteWalletDialogState();
}

class _DeleteWalletDialogState extends State<_DeleteWalletDialog> {
  static const String _phrase = 'confirm delete';
  static const int _waitSeconds = 5;

  final _ctrl = TextEditingController();
  Timer? _tick;
  int _remaining = _waitSeconds;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() => _remaining--);
      if (_remaining <= 0) t.cancel();
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  bool get _waiting => _remaining > 0;

  bool get _phraseOk =>
      _ctrl.text.trim().toLowerCase() == _phrase;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final phone = AppLayout.isPhone(context);
    return AppDialog(
      title: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: AppColors.danger),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              'Delete "${widget.walletName}"?',
              style: AppTypography.sectionTitle.copyWith(color: AppColors.danger),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: AppLayout.isPhone(context) ? double.infinity : 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: AppColors.danger.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                border: Border.all(
                    color: AppColors.danger.withValues(alpha: 0.45)),
              ),
              child: Text(
                'This deletes the only copy of this wallet on this '
                '${Platform.isAndroid ? 'device' : 'computer'}. '
                'Without a written backup of the recovery phrase, the funds '
                'are gone permanently — nobody, including Templar, can bring '
                'them back.',
                style: AppTypography.body.copyWith(
                  color: AppColors.danger,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            // The pause. A draining bar reads as "wait", where a plain
            // disabled button reads as "broken".
            if (_waiting) ...[
              Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      value: (_waitSeconds - _remaining) / _waitSeconds,
                      color: AppColors.danger,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Text(
                      'Read the warning. You can confirm in $_remaining second'
                      '${_remaining == 1 ? '' : 's'}.',
                      style:
                          AppTypography.bodySmall.copyWith(color: s.inkSecondary),
                    ),
                  ),
                ],
              ),
            ] else ...[
              Text(
                'Type $_phrase to confirm.',
                style: AppTypography.bodySmall.copyWith(color: s.ink),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _ctrl,
                autofocus: true,
                autocorrect: false,
                enableSuggestions: false,
                style: AppTypography.mono.copyWith(color: s.ink),
                decoration: InputDecoration(
                  hintText: _phrase,
                  hintStyle: AppTypography.mono.copyWith(color: s.inkFaint),
                  // The red ring IS the warning here, so it stays on a phone
                  // — but at the phone field's own radius and hairline, or it
                  // fights the 14-radius fill the theme paints underneath.
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(
                        phone ? AppSpacing.radiusLg : AppSpacing.radiusSm),
                    borderSide: BorderSide(
                        color: AppColors.danger.withValues(alpha: 0.45)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(
                        phone ? AppSpacing.radiusLg : AppSpacing.radiusSm),
                    borderSide: BorderSide(
                        color: AppColors.danger, width: phone ? 1.5 : 2),
                  ),
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) {
                  if (_phraseOk) Navigator.of(context).pop(true);
                },
              ),
            ],
          ],
        ),
      ),
      // In a sheet the actions land in an end-aligned Wrap: full width, they
      // stack as two bars instead of two right-hugging chips.
      actions: phone
          ? [
              GhostButton(
                label: 'Cancel',
                onPressed: () => Navigator.of(context).pop(false),
                isFullWidth: true,
              ),
              DangerButton(
                label: 'Delete wallet',
                onPressed: (!_waiting && _phraseOk)
                    ? () => Navigator.of(context).pop(true)
                    : null,
                isFullWidth: true,
              ),
            ]
          : [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: (!_waiting && _phraseOk)
                    ? () => Navigator.of(context).pop(true)
                    : null,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.danger,
                  disabledBackgroundColor:
                      AppColors.danger.withValues(alpha: 0.25),
                  foregroundColor: Colors.white,
                ),
                child: const Text('Delete wallet'),
              ),
            ],
    );
  }
}

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog();
  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _ctrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final p = _ctrl.text;
    final c = _confirmCtrl.text;
    if (p.isNotEmpty && p != c) {
      setState(() => _error = 'Passwords do not match');
      return;
    }
    Navigator.of(context).pop(p); // empty string = remove password
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final phone = AppLayout.isPhone(context);
    return GlassDialog(
      title: 'Wallet password',
      icon: Icons.lock_outline,
      actions: phone
          ? [
              GhostButton(
                label: 'Cancel',
                onPressed: () => Navigator.of(context).pop(),
                isFullWidth: true,
              ),
              PrimaryButton(
                label: 'Set',
                onPressed: _submit,
                isFullWidth: true,
              ),
            ]
          : [
              TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
              FilledButton(onPressed: _submit, child: const Text('Set')),
            ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // caption hard-codes a light-mode ink; on the phone's dark panel it
          // is barely there, so the phone arm takes the scheme's own.
          Text('Leave blank to remove the password.',
              style: AppTypography.caption
                  .copyWith(color: phone ? s.inkSecondary : null)),
          const SizedBox(height: AppSpacing.md),
          GlassPasswordField(controller: _ctrl, label: 'New password'),
          const SizedBox(height: AppSpacing.md),
          GlassPasswordField(
            controller: _confirmCtrl,
            label: 'Confirm password',
            errorText: _error,
            onSubmitted: _submit,
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
        ],
      ),
    );
  }
}

class _NetworkSection extends StatefulWidget {
  @override
  State<_NetworkSection> createState() => _NetworkSectionState();
}

class _NetworkSectionState extends State<_NetworkSection> {
  late TextEditingController _btcExplorer;
  late TextEditingController _liquidExplorer;

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    _btcExplorer = TextEditingController(text: state.btcExplorerUrl);
    _liquidExplorer = TextEditingController(text: state.liquidExplorerUrl);
  }

  @override
  void dispose() {
    _btcExplorer.dispose();
    _liquidExplorer.dispose();
    super.dispose();
  }

  void _saveExplorers() {
    final state = context.read<AppState>();
    state.setBtcExplorerUrl(_btcExplorer.text.trim());
    state.setLiquidExplorerUrl(_liquidExplorer.text.trim());
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Explorer URLs saved'), duration: Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final phone = AppLayout.isPhone(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!phone) const PageHeader(title: 'Network & Sync'),
        // The phone settings root already carries this exact switch as a
        // list row, one tap away — drawing it here too puts the same control
        // on screen twice in two different shapes.
        if (!phone) ...[
          Consumer<AppState>(
            builder: (context, state, _) => FormCard(
              title: 'Sync',
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Auto-sync on startup'),
                subtitle: Text(
                  'Automatically sync the active wallet when the app opens.',
                  style: AppTypography.caption,
                ),
                value: state.autoSync,
                onChanged: state.setAutoSync,
                activeThumbColor: AppColors.accent,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
        ],
        const _LiquidNetworkCard(),
        const SizedBox(height: AppSpacing.lg),
        Consumer<AppState>(
          builder: (context, state, _) => FormCard(
            title: 'Nodes',
            subtitle: 'Bitcoin is fixed in this build. Liquid follows the network '
                'above; override the endpoints with TEMPLAR_LIQUID_ELECTRUM_URL '
                'or TEMPLAR_ELEMENTS_RPC_URL.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CopyRow(
                    label: 'Bitcoin Electrum',
                    value: 'ssl://electrum.blockstream.info:60002'),
                const Divider(height: 1),
                CopyRow(
                  label: 'Liquid chain',
                  value: state.liquidNetwork?.backendDescription ??
                      'electrum ssl://elements-testnet.blockstream.info:50002',
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        FormCard(
          title: 'Block Explorers',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Used for "View on Explorer" links in transaction history.',
                  style: AppTypography.caption
                      .copyWith(color: phone ? s.inkSecondary : null)),
              const SizedBox(height: AppSpacing.lg),
              TextField(
                controller: _btcExplorer,
                decoration: InputDecoration(
                  labelText: 'Bitcoin Explorer',
                  hintText: 'https://mempool.space/testnet',
                  // A 16 px glyph drawn for a 40 dp desktop field reads as
                  // debris inside the phone's 56 dp filled box, and costs it
                  // 40 dp of a 347 dp line the label already names.
                  prefixIcon: phone
                      ? null
                      : const Icon(Icons.explore_outlined, size: 16),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              TextField(
                controller: _liquidExplorer,
                decoration: InputDecoration(
                  labelText: 'Liquid Explorer',
                  hintText: 'https://blockstream.info/liquidtestnet',
                  prefixIcon: phone
                      ? null
                      : const Icon(Icons.explore_outlined, size: 16),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              PrimaryButton(
                label: 'Save',
                icon: Icons.save_outlined,
                onPressed: _saveExplorers,
                isFullWidth: phone,
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        FormCard(
          title: 'Templar Protocol',
          subtitle: 'Templar Protocol sites hand loan requests to this wallet through '
              'templar:// links, on the Liquid network set above. The paste box, '
              'the connected sites and what was signed live in their own '
              'section.',
          child: SecondaryButton(
            label: 'Open Templar Protocol',
            icon: Icons.link,
            onPressed: () => context.go(AppRoutes.settingsProtocol),
            isFullWidth: phone,
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        const InfoBanner(message: 'Tor support is coming soon and is not yet implemented.'),
      ],
    );
  }
}

/// Liquid network selector: the public testnet or a local Elements regtest
/// (what the Templar Protocol runs locally). Switching closes the open wallet
/// on the engine side, so the card sends the user back to the picker.
class _LiquidNetworkCard extends StatefulWidget {
  const _LiquidNetworkCard();

  @override
  State<_LiquidNetworkCard> createState() => _LiquidNetworkCardState();
}

class _LiquidNetworkCardState extends State<_LiquidNetworkCard> {
  LiquidNetworkInfo? _info;
  String? _error;
  bool _busy = false;
  String _choice = 'testnet';
  final _policyAsset = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _policyAsset.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final info = await walletBridge.getLiquidNetwork();
      if (!mounted) return;
      context.read<AppState>().setLiquidNetworkInfo(info);
      setState(() {
        _info = info;
        _error = null;
        _choice = info.shortName;
        _policyAsset.text =
            info.isRegtest ? info.policyAsset : info.regtestDefaultPolicyAsset;
      });
    } catch (e) {
      if (mounted) setState(() => _error = liquidNetworkErrorText(e));
    }
  }

  /// Whether the form differs from what the engine is on.
  bool get _dirty {
    final info = _info;
    if (info == null) return false;
    if (_choice != info.shortName) return true;
    return _choice == 'regtest' &&
        _policyAsset.text.trim().toLowerCase() != info.policyAsset.toLowerCase();
  }

  Future<void> _apply() async {
    final info = _info;
    if (info == null || !_dirty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // The confirmation, the switch and the closing of the open wallet are
      // shared with the Templar Protocol request screen (liquid_network_switch.dart).
      final done = await switchLiquidNetwork(
        context,
        target: _choice,
        policyAsset: _policyAsset.text,
      );
      if (!mounted) return;
      if (done == null) {
        setState(() => _busy = false);
        return;
      }
      setState(() {
        _info = done.info;
        _busy = false;
      });
      // The shell must not keep showing the other network's balances.
      if (done.walletClosed) context.go(AppRoutes.walletPicker);
    } on LiquidNetworkSwitchError catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final phone = AppLayout.isPhone(context);
    final info = _info;
    final locked = info?.envLocked ?? false;
    return FormCard(
      title: 'Liquid network',
      subtitle: 'Testnet is the public Liquid test network. Regtest is a local '
          'elementsd (what the Templar Protocol runs locally): instant blocks, free coins.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_error != null) ...[
            DangerBanner(message: _error!),
            const SizedBox(height: AppSpacing.lg),
          ],
          if (info == null && _error == null)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(AppSpacing.lg),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          if (info != null) ...[
            Text(
              'Now: ${info.shortName} · ${info.backendDescription}',
              style: AppTypography.caption
                  .copyWith(color: phone ? s.inkSecondary : null),
            ),
            const SizedBox(height: AppSpacing.md),
            if (locked)
              const InfoBanner(
                message: 'Fixed by TEMPLAR_LIQUID_NETWORK for this session. '
                    'Unset the variable to change it here.',
              )
            else ...[
              SegmentedSwitch<String>(
                options: const [
                  SegOption(value: 'testnet', label: 'Testnet', icon: Icons.public),
                  SegOption(value: 'regtest', label: 'Regtest', icon: Icons.dns_outlined),
                ],
                selected: _choice,
                onChanged: _busy ? (_) {} : (v) => setState(() => _choice = v),
                // A ~200 dp track floating in a full-width card is the
                // clearest tell of a shrunken desktop form; on a phone the
                // choice spans the card it belongs to.
                expand: phone,
              ),
              if (_choice == 'regtest') ...[
                const SizedBox(height: AppSpacing.lg),
                TextField(
                  controller: _policyAsset,
                  enabled: !_busy,
                  onChanged: (_) => setState(() {}),
                  style: AppTypography.mono,
                  decoration: InputDecoration(
                    labelText: 'Regtest L-BTC asset id',
                    hintText: info.regtestDefaultPolicyAsset,
                    helperText: 'Policy asset of your node. The stock liquidregtest id '
                        'is prefilled; elements-cli dumpassetlabels prints yours.',
                    // 64 hex characters in mono on a 347 dp line need every
                    // pixel; the desktop's 16 px tag glyph stays there.
                    prefixIcon:
                        phone ? null : const Icon(Icons.tag, size: 16),
                  ),
                ),
              ],
              if (_dirty) ...[
                const SizedBox(height: AppSpacing.lg),
                const WarningBanner(
                  message: 'Switching closes the open wallet. Reopen it and sync — '
                      'until then no Liquid balance is shown for the new network.',
                ),
              ],
              const SizedBox(height: AppSpacing.lg),
              PrimaryButton(
                label: 'Apply',
                icon: Icons.swap_horiz,
                isLoading: _busy,
                onPressed: _dirty && !_busy ? _apply : null,
                isFullWidth: phone,
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _SecuritySection extends StatefulWidget {
  @override
  State<_SecuritySection> createState() => _SecuritySectionState();
}

class _SecuritySectionState extends State<_SecuritySection> {
  WalletCustomization? _custom;
  VaultStatus? _vault;
  String _dataDir = '';
  String? _dataDirError;

  /// True when the active wallet stores a seed on this device (software only).
  bool _hasSeed = false;

  @override
  void initState() {
    super.initState();
    _load();
    _loadVault();
    _checkSeed();
    _resolveDir();
  }

  Future<void> _checkSeed() async {
    final walletId = context.read<AppState>().activeWalletId;
    if (walletId == null) return;
    try {
      final info = await walletBridge.getWalletInfo(walletId);
      if (mounted) setState(() => _hasSeed = info.hasSeed);
    } catch (_) {
      // No seed card when the wallet can't be inspected.
    }
  }

  Future<void> _resolveDir() async {
    try {
      // The engine is the source of truth for where wallet data lives
      // (state.rs resolves it via dirs-next). Reconstructing the path on the
      // Dart side drifted from it on Windows, so always ask the engine.
      final dir = await walletBridge.getDataDir();
      if (mounted) setState(() => _dataDir = dir);
    } catch (e) {
      if (mounted) {
        setState(() => _dataDirError =
            'Could not read the data directory from the wallet engine: $e');
      }
    }
  }

  Future<void> _openDir() async {
    if (_dataDir.isEmpty) return;
    // file:// URI — Linux (xdg-open), macOS (Finder), Windows (Explorer).
    final uri = Uri.file(_dataDir);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _deleteWallet() async {
    final appState = context.read<AppState>();
    final walletId = appState.activeWalletId;
    if (walletId == null) return;
    final name = appState.activeWalletName ?? 'this wallet';

    final confirmed = await showAppDialog<bool>(context,
      barrierDismissible: false,
      builder: (_) => _DeleteWalletDialog(walletName: name),
    );
    if (confirmed != true || !mounted) return;

    try {
      await walletBridge.deleteWallet(walletId);
      await WalletCustomizationStore.instance.delete(walletId);
      // The names go with the wallet — a new wallet must never inherit
      // a deleted one's labels through a recycled id.
      await CosignerLabelStore.instance.delete(walletId);
      // Same reason: the connected-site records name a wallet id, and a
      // recycled one must not inherit a deleted wallet's connections.
      await ProtocolStore.instance.forgetWallet(walletId);
      if (!mounted) return;
      appState.setActiveWallet(null);
      // Picker redirects to the welcome screen when no wallets remain.
      context.go(AppRoutes.walletPicker);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not delete wallet: $e'),
            backgroundColor: AppColors.danger,
          ),
        );
      }
    }
  }

  Future<void> _load() async {
    final walletId = context.read<AppState>().activeWalletId;
    if (walletId == null) return;
    final c = await WalletCustomizationStore.instance.load(walletId);
    if (mounted) setState(() => _custom = c);
  }

  Future<void> _loadVault() async {
    try {
      final v = await walletBridge.vaultStatus();
      if (mounted) setState(() => _vault = v);
    } catch (_) {
      // Card shows an unavailable hint when the status can't be read.
    }
  }

  Future<void> _setupVault() async {
    final done = await showAppDialog<bool>(context,
      builder: (_) => const VaultSetupSheet(),
    );
    if (done != true || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Wallet storage is now encrypted'),
      duration: Duration(seconds: 2),
    ));
    await _loadVault();
  }

  Future<void> _lockNow() async {
    await lockVaultAndPrompt(context);
    if (mounted) _loadVault();
  }

  void _pushUnlock() {
    pushVaultUnlock(context, onUnlocked: () {
      if (mounted) _loadVault();
    });
  }

  Widget get _vaultCard {
    final vault = _vault;
    final String statusText;
    final Widget? action;
    // The phone draws the same four states as one row: the glyph already on
    // the button for that state, a one-line reading of it, and the tap that
    // acts on it. Nothing new is invented — only re-arranged.
    final IconData rowIcon;
    final String rowState;
    final VoidCallback? rowTap;
    if (vault == null) {
      statusText = 'Encryption status unavailable.';
      action = null;
      rowIcon = Icons.help_outline;
      rowState = 'Status unavailable';
      rowTap = null;
    } else if (!vault.initialized) {
      statusText =
          'Wallet seeds are currently stored unencrypted on this '
          '${Platform.isAndroid ? 'device' : 'computer'}. '
          'Set a passphrase to encrypt them at rest. You will be asked for it '
          'every time the app starts. If you lose the passphrase, the wallets '
          'in this app cannot be recovered without their seed-phrase backups.\n\n'
          'Until you do, Templar will not create or restore a wallet whose '
          'recovery phrase would be kept here.';
      action = PrimaryButton(
        label: 'Set passphrase',
        icon: Icons.shield_outlined,
        onPressed: _setupVault,
      );
      rowIcon = Icons.shield_outlined;
      rowState = 'Not encrypted — set a passphrase';
      rowTap = _setupVault;
    } else if (vault.unlocked) {
      statusText =
          'Wallet storage is encrypted at rest. The vault is unlocked for '
          'this session.';
      action = SecondaryButton(
        label: 'Lock now',
        icon: Icons.lock_outline,
        onPressed: _lockNow,
      );
      rowIcon = Icons.lock_outline;
      rowState = 'Encrypted · unlocked this session';
      rowTap = _lockNow;
    } else {
      statusText = 'Wallet storage is encrypted and locked.';
      action = PrimaryButton(
        label: 'Unlock',
        icon: Icons.lock_open_outlined,
        onPressed: _pushUnlock,
      );
      rowIcon = Icons.lock_open_outlined;
      rowState = 'Encrypted · locked';
      rowTap = _pushUnlock;
    }
    if (AppLayout.isPhone(context)) {
      final s = AppScheme.of(context);
      final tint = vault == null
          ? s.inkFaint
          : vault.initialized
              ? s.success
              : s.warning;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ListSectionLabel(label: 'Encryption'),
          ListCard(
            children: [
              ListRow(
                icon: rowIcon,
                tint: tint,
                title: 'Wallet storage',
                subtitle: rowState,
                subtitleColor: tint,
                chevron: rowTap != null,
                onTap: rowTap,
              ),
            ],
          ),
          // The full warning is what tells the user what is at stake; a row
          // subtitle is one line, so it goes under the group.
          _SettingsNote(text: statusText),
        ],
      );
    }
    return SectionCard(
      title: 'Encrypt wallet storage',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(statusText, style: AppTypography.caption),
          if (action != null) ...[
            const SizedBox(height: AppSpacing.lg),
            action,
          ],
        ],
      ),
    );
  }

  Future<void> _setPassword() async {
    final walletId = context.read<AppState>().activeWalletId;
    if (walletId == null || _custom == null) return;
    final result = await showAppDialog<String>(context,
      builder: (_) => const _PasswordDialog(),
    );
    if (result == null || !mounted) return;
    final hash = result.isEmpty ? null : WalletCustomizationStore.hashPassword(result);
    final updated = _custom!.copyWith(passwordHash: hash);
    await WalletCustomizationStore.instance.save(updated);
    if (mounted) {
      setState(() => _custom = updated);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(hash == null ? 'Password removed' : 'Password set'),
        duration: const Duration(seconds: 2),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final walletId = context.watch<AppState>().activeWalletId;
    final s = AppScheme.of(context);
    final phone = AppLayout.isPhone(context);
    // Security and Advanced used to be two menu entries, which split one
    // subject in half: the vault passphrase lived in one and the seed it
    // protects in the other. They are the same conversation, so they are one
    // page now, ordered from "protects everything" down to "destroys
    // everything".
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!phone) const PageHeader(title: 'Security'),
        _vaultCard,
        // Fingerprint (Touch ID on a Mac) in place of the passphrase at
        // launch. The card brings its own top spacing so it can vanish on
        // devices without a sensor without leaving a double gap.
        //
        // On a phone the settings root already shows the compact skin of this
        // very tile, so drawing the full card here put the same switch on
        // screen twice, one tap apart.
        if (BiometricUnlockService.platformSupported && !phone)
          const BiometricUnlockTile(),
        if (!phone) ...[
          const SizedBox(height: AppSpacing.lg),
          const ListCard(children: [AutoLockRow()]),
        ],
        const SizedBox(height: AppSpacing.lg),
        // Verifying a paper backup needs no secret and applies to every wallet
        // type — including the hardware and air-gap ones the seed tools below
        // can never touch.
        if (walletId != null) ...[
          BackupVerifyCard(walletId: walletId),
          const SizedBox(height: AppSpacing.lg),
        ],
        // Seed tools — software wallets only; HW/air-gap keep keys off-device.
        if (walletId != null && _hasSeed) ...[
          SeedPhraseCard(walletId: walletId),
          const SizedBox(height: AppSpacing.lg),
        ],
        if (walletId == null || _custom == null)
          const SectionCard(
            title: 'Wallet password',
            child: InfoBanner(
                message: 'No wallet open. Open a wallet from the wallet picker first.'),
          )
        // A state and one way into it — the phone's list grammar, with the
        // button's own glyph on the row and its sentence under the group.
        else if (phone)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const ListSectionLabel(label: 'Wallet password'),
              ListCard(
                children: [
                  ListRow(
                    icon: Icons.lock_outline,
                    tint: _custom!.passwordHash != null ? s.success : s.inkFaint,
                    title: 'Password',
                    subtitle:
                        _custom!.passwordHash != null ? 'Set' : 'Not set',
                    subtitleColor:
                        _custom!.passwordHash != null ? s.success : null,
                    chevron: true,
                    onTap: _setPassword,
                  ),
                ],
              ),
              _SettingsNote(
                text: _custom!.passwordHash != null
                    ? 'Entering this wallet requires the password.'
                    : 'Anyone with access to the app can open this wallet.',
              ),
            ],
          )
        else
          SectionCard(
            title: 'Wallet password',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _custom!.passwordHash != null
                      ? 'Password is set. Entering this wallet requires the password.'
                      : 'No password set. Anyone with access to the app can open this wallet.',
                  style: AppTypography.caption,
                ),
                const SizedBox(height: AppSpacing.lg),
                SecondaryButton(
                  label: _custom!.passwordHash != null
                      ? 'Change / remove password'
                      : 'Set password',
                  icon: Icons.lock_outline,
                  onPressed: _setPassword,
                ),
              ],
            ),
          ),
        const SizedBox(height: AppSpacing.lg),
        SectionCard(
          title: 'Storage',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Phone: CopyRow is the same label-over-value pair, but with
              // the path collapsed to one line and a 48 dp copy button — the
              // only way to get the path off an Android device, where the
              // "Open directory" button below never appears.
              if (phone && _dataDirError == null)
                CopyRow(
                  label: 'Wallet data directory',
                  value: _dataDir.isEmpty ? '…' : _dataDir,
                  singleLine: true,
                )
              else ...[
                Text('Wallet data directory', style: AppTypography.label),
                const SizedBox(height: AppSpacing.xs),
                if (_dataDirError != null)
                  Text(_dataDirError!,
                      style: AppTypography.caption
                          .copyWith(color: AppColors.danger))
                else
                  SelectableText(_dataDir.isEmpty ? '…' : _dataDir,
                      style: AppTypography.mono),
              ],
              // No file manager handles a file:// directory on Android.
              if (!Platform.isAndroid) ...[
                const SizedBox(height: AppSpacing.md),
                SecondaryButton(
                    label: 'Open directory',
                    icon: Icons.folder_open_outlined,
                    onPressed: _dataDir.isEmpty ? null : _openDir),
              ],
            ],
          ),
        ),
        if (walletId != null) ...[
          const SizedBox(height: AppSpacing.xxl),
          _DangerZone(onDelete: _deleteWallet),
        ],
      ],
    );
  }
}

class _AppearanceSection extends StatefulWidget {
  @override
  State<_AppearanceSection> createState() => _AppearanceSectionState();
}

class _AppearanceSectionState extends State<_AppearanceSection> {
  final _bridge = walletBridge;
  WalletCustomization? _custom;
  final _nameCtrl = TextEditingController();
  bool _saving = false;
  String? _saveError;

  /// The active wallet's co-signers, when it has more than one key. Loaded
  /// here so Appearance can rename them — the same place the wallet's own
  /// name and colour are set.
  List<CosignerEntry> _cosigners = const [];

  @override
  void initState() {
    super.initState();
    _load();
    _loadCosigners();
  }

  /// Keys plus labels. A singlesig wallet has none and the card stays away.
  Future<void> _loadCosigners() async {
    final walletId = context.read<AppState>().activeWalletId;
    if (walletId == null) return;
    try {
      final info = await _bridge.getWalletInfo(walletId);
      if (info.cosignerKeys.length < 2) return;
      final labels = await CosignerLabelStore.instance.load(walletId);
      if (!mounted) return;
      setState(() {
        _cosigners = resolveCosigners(
          cosignerKeys: info.cosignerKeys,
          labels: labels,
          localFingerprints: info.localFingerprints,
        );
        _requiredSigs = info.requiredSigs;
      });
    } catch (_) {
      // A wallet that will not open has bigger problems than its labels.
    }
  }

  int? _requiredSigs;

  Future<void> _editCosigner(CosignerEntry entry) async {
    final walletId = context.read<AppState>().activeWalletId;
    if (walletId == null) return;
    final edited = await showCosignerLabelEditor(
      context,
      label: entry.label,
      index: entry.index,
      subtitle: entry.fingerprint.isEmpty
          ? null
          : '${entry.fingerprint} · m/${entry.path}',
    );
    if (edited == null) return;
    await CosignerLabelStore.instance.saveOne(walletId, edited);
    await _loadCosigners();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final walletId = context.read<AppState>().activeWalletId;
    if (walletId == null) return;
    final c = await WalletCustomizationStore.instance.load(walletId);
    if (mounted) {
      setState(() {
        _custom = c;
        _nameCtrl.text = c.nameOverride ?? context.read<AppState>().activeWalletName ?? '';
      });
    }
  }

  Future<void> _saveName() async {
    final walletId = context.read<AppState>().activeWalletId;
    if (walletId == null || _custom == null) return;
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    setState(() { _saving = true; _saveError = null; });
    try {
      await _bridge.renameWallet(walletId, name);
      final updated = _custom!.copyWith(nameOverride: name);
      await WalletCustomizationStore.instance.save(updated);
      if (mounted) {
        context.read<AppState>().setActiveWallet(walletId, name: name, type: context.read<AppState>().activeWalletType);
        setState(() { _custom = updated; _saving = false; });
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Name saved'), duration: Duration(seconds: 2)));
      }
    } catch (e) {
      if (mounted) setState(() { _saving = false; _saveError = e.toString(); });
    }
  }

  Future<void> _saveColor(Color color) async {
    final walletId = context.read<AppState>().activeWalletId;
    if (walletId == null || _custom == null) return;
    final updated = _custom!.copyWith(accentColor: color.toARGB32());
    await WalletCustomizationStore.instance.save(updated);
    if (mounted) {
      // Re-tint the whole app immediately.
      context.read<AppState>().setAccent(color);
      setState(() => _custom = updated);
    }
  }

  /// Renaming the wallet's co-signers.
  ///
  /// Lives beside the wallet's own name and colour because it is the same
  /// kind of setting: local, cosmetic, and changeable at any time. The keys
  /// themselves are on Wallet info, where they cannot be edited by accident.
  Widget get _cosignerLabelsCard => FormCard(
        title: 'Cosigner labels',
        subtitle: _requiredSigs == null
            ? 'Name each key of this shared wallet.'
            : 'Name each key of this $_requiredSigs-of-${_cosigners.length} '
                'wallet. Names are kept on this device only.',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final entry in _cosigners)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: InkWell(
                  onTap: () => _editCosigner(entry),
                  borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        vertical: AppSpacing.sm, horizontal: AppSpacing.sm),
                    child: Row(
                      children: [
                        Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: (entry.label.color ?? AppColors.accent)
                                .withValues(alpha: 0.14),
                            shape: BoxShape.circle,
                            border: Border.all(
                                color: entry.label.color ?? AppColors.accent),
                          ),
                          child: Icon(entry.label.icon,
                              size: 16,
                              color: entry.label.color ?? AppColors.accent),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(entry.name,
                                  style: AppTypography.body.copyWith(
                                      fontWeight: FontWeight.w600)),
                              Text(
                                entry.isLocal
                                    ? '${entry.fingerprint} · this device'
                                    : entry.fingerprint,
                                style: AppTypography.caption,
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.edit_outlined, size: 16),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      );

  Widget get _walletCustomizationCard => FormCard(
        title: 'Customize active wallet',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Name
            Text('Display name', style: AppTypography.label),
            const SizedBox(height: AppSpacing.sm),
            // Phone: a 54 dp Save slab beside the field leaves the name about
            // 190 dp of a 347 dp line, so the two stack instead and each
            // takes the whole width.
            if (AppLayout.isPhone(context)) ...[
              TextField(
                controller: _nameCtrl,
                decoration: const InputDecoration(hintText: 'Wallet name'),
              ),
              const SizedBox(height: AppSpacing.md),
              PrimaryButton(
                label: _saving ? 'Saving…' : 'Save',
                icon: Icons.save_outlined,
                onPressed: _saving ? null : _saveName,
                isFullWidth: true,
              ),
            ] else
              Row(
                children: [
                  Expanded(child: TextField(controller: _nameCtrl, decoration: const InputDecoration(hintText: 'Wallet name'))),
                  const SizedBox(width: AppSpacing.sm),
                  PrimaryButton(
                    label: _saving ? 'Saving…' : 'Save',
                    icon: Icons.save_outlined,
                    onPressed: _saving ? null : _saveName,
                  ),
                ],
              ),
            if (_saveError != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(_saveError!, style: AppTypography.caption.copyWith(color: AppColors.danger)),
            ],
            const Divider(height: AppSpacing.xxl),

            // Accent color — this IS the wallet's identity on the home
            // gallery and in the sidebar, so it gets a line explaining that.
            Text('Accent color', style: AppTypography.label),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Tints this wallet everywhere: its mark on the home gallery, '
              'the sidebar, and every accent inside it.',
              style: AppTypography.caption,
            ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: WalletCustomizationStore.palette.map((color) {
                final selected = _custom!.accentColor == color.toARGB32();
                return InkWell(
                  onTap: () => _saveColor(color),
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    width: AppLayout.isPhone(context) ? 44 : 36,
                    height: AppLayout.isPhone(context) ? 44 : 36,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected ? Colors.white : Colors.transparent,
                        width: 3,
                      ),
                      boxShadow: selected ? [BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 8)] : null,
                    ),
                    child: selected ? const Icon(Icons.check, color: Colors.white, size: 16) : null,
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final hasWallet =
        context.watch<AppState>().activeWalletId != null && _custom != null;
    return Consumer<AppState>(
      builder: (context, state, _) {
        final phone = AppLayout.isPhone(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!phone) const PageHeader(title: 'Appearance'),
            if (hasWallet) ...[
              _walletCustomizationCard,
              const SizedBox(height: AppSpacing.lg),
            ],
            if (_cosigners.length > 1) ...[
              _cosignerLabelsCard,
              const SizedBox(height: AppSpacing.lg),
            ],
            FormCard(
              title: 'Currency & Units',
              subtitle: 'How balances and value estimates are displayed.',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Fiat currency', style: AppTypography.label),
                  const SizedBox(height: AppSpacing.sm),
                  DropdownButtonFormField<String>(
                    initialValue: state.fiatCurrency,
                    items: [
                      for (final e in PriceService.currencySymbols.entries)
                        DropdownMenuItem(
                          value: e.key,
                          child: Text('${e.key}  (${e.value.trim()})'),
                        ),
                    ],
                    onChanged: (v) { if (v != null) state.setFiatCurrency(v); },
                    decoration: InputDecoration(
                      // 16 px inside a 56 dp filled field reads as debris.
                      prefixIcon: phone
                          ? null
                          : const Icon(Icons.attach_money, size: 16),
                    ),
                  ),
                  const Divider(height: AppSpacing.xxl),
                  Text('Bitcoin unit', style: AppTypography.label),
                  const SizedBox(height: AppSpacing.sm),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Display amounts in sats'),
                    subtitle: Text(
                      state.useSats
                          ? 'Showing sats (1 BTC = 100,000,000 sats).'
                          : 'Showing BTC.',
                      style: AppTypography.caption,
                    ),
                    value: state.useSats,
                    onChanged: (v) => state.setBitcoinUnit(v ? 'sat' : 'btc'),
                    activeThumbColor: AppColors.accent,
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            FormCard(
              title: 'Theme',
              // Phone: one full-width track — the same control the network
              // card two pages away uses — instead of three stacked radio
              // rows and ~90 dp of a page the user is scrolling. Labels only:
              // the desktop radios carry no glyphs, so none are invented.
              child: phone
                  ? SegmentedSwitch<ThemeMode>(
                      expand: true,
                      options: const [
                        SegOption(value: ThemeMode.dark, label: 'Dark'),
                        SegOption(value: ThemeMode.light, label: 'Light'),
                        SegOption(value: ThemeMode.system, label: 'System'),
                      ],
                      selected: state.themeMode,
                      onChanged: state.setThemeMode,
                    )
                  : RadioGroup<ThemeMode>(
                      groupValue: state.themeMode,
                      onChanged: (v) {
                        if (v != null) state.setThemeMode(v);
                      },
                      child: const Column(
                        children: [
                          RadioListTile<ThemeMode>(
                            title: Text('Dark'),
                            value: ThemeMode.dark,
                            contentPadding: EdgeInsets.zero,
                          ),
                          RadioListTile<ThemeMode>(
                            title: Text('Light'),
                            value: ThemeMode.light,
                            contentPadding: EdgeInsets.zero,
                          ),
                          RadioListTile<ThemeMode>(
                            title: Text('System'),
                            value: ThemeMode.system,
                            contentPadding: EdgeInsets.zero,
                          ),
                        ],
                      ),
                    ),
            ),
            // The phone settings root already carries "Reduce effects" as a
            // list row; the same switch twice, in two shapes, is worse than
            // one of them living a tap away.
            if (!phone) ...[
              const SizedBox(height: AppSpacing.lg),
              FormCard(
                title: 'Effects',
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Reduce visual effects'),
                  subtitle: Text(
                    'Disables frosted-glass blur and heavy effects for better '
                    'performance on low-end hardware.',
                    style: AppTypography.caption,
                  ),
                  value: state.reduceEffects,
                  onChanged: state.setReduceEffects,
                  activeThumbColor: AppColors.accent,
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _AboutSection extends StatefulWidget {
  @override
  State<_AboutSection> createState() => _AboutSectionState();
}

class _AboutSectionState extends State<_AboutSection> {
  /// wallet-ffi crate version reported by the engine; null while loading.
  String? _engineVersion;

  /// The version handshake failed — the dylib did not answer.
  bool _engineUnreachable = false;

  @override
  void initState() {
    super.initState();
    _loadEngineVersion();
  }

  Future<void> _loadEngineVersion() async {
    try {
      final v = await walletBridge.getVersion();
      if (mounted) setState(() => _engineVersion = v);
    } catch (_) {
      if (mounted) setState(() => _engineUnreachable = true);
    }
  }

  Future<void> _openSource() async {
    final uri = Uri.parse('https://github.com/0xB4LdW1n/TemplarWallet');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  /// The engine line, in both skins' words.
  String get _engineLine => _engineUnreachable
      ? 'Engine unreachable — the native wallet library did not respond. '
          'Wallet operations will not work.'
      : 'Engine (wallet-ffi): '
          '${_engineVersion != null ? 'v$_engineVersion' : '…'}';

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    // Phone: two facts and one link, which is a list — the same two rows the
    // settings root draws About with, and the same two glyphs already used
    // here (info for the app, code for the repository).
    if (AppLayout.isPhone(context)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ListSectionLabel(label: 'App'),
          ListCard(
            children: [
              ListRow(
                icon: Icons.info_rounded,
                tint: s.inkSecondary,
                title: 'Templar Wallet',
                subtitle: 'v$kAppVersion · Testnet',
              ),
              ListRow(
                icon: Icons.code,
                tint: s.inkSecondary,
                title: 'Source code',
                subtitle: 'github.com/0xB4LdW1n/TemplarWallet',
                chevron: true,
                onTap: _openSource,
              ),
            ],
          ),
          _SettingsNote(
            text: _engineLine,
            color: _engineUnreachable ? s.danger : null,
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const PageHeader(title: 'About'),
        SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Templar Wallet', style: AppTypography.sectionTitle),
              const SizedBox(height: AppSpacing.xs),
              Text('v$kAppVersion — Testnet', style: AppTypography.caption),
              const SizedBox(height: AppSpacing.xs),
              if (_engineUnreachable)
                Text(
                  'Engine unreachable — the native wallet library did not '
                  'respond. Wallet operations will not work.',
                  style: AppTypography.caption.copyWith(color: AppColors.danger),
                )
              else
                Text(
                  'Engine (wallet-ffi): ${_engineVersion != null ? 'v$_engineVersion' : '…'}',
                  style: AppTypography.caption,
                ),
              const SizedBox(height: AppSpacing.xl),
              GhostButton(
                  label: 'Source code',
                  icon: Icons.code,
                  onPressed: _openSource),
            ],
          ),
        ),
      ],
    );
  }
}
