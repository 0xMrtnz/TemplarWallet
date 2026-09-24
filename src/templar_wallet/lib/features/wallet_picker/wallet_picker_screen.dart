import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../app/routes.dart';
import '../../app/app_state.dart';
import '../../bridge/bridge_provider.dart';
import '../../services/wallet_customization_store.dart';
import '../../shared/widgets/app_logo.dart';
import '../../shared/widgets/buttons.dart';
import '../../shared/widgets/glass_card.dart';
import '../../shared/widgets/glass_dialog.dart';
import '../../shared/widgets/wallet_plate.dart';
import '../hardware/ledger_connect_dialog.dart';
import '../vault/lock_action.dart';
import '../../shared/widgets/hybrid_kit.dart';
import '../../theme/app_motion.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import 'models/wallet_summary.dart';
import 'wallet_flags.dart';

/// Horizontal margin shared by the page header and every index row, so the
/// headline and the wallet names hang off exactly one line.
const EdgeInsets _gutter = EdgeInsets.symmetric(horizontal: AppSpacing.xxl);

/// The gutter for the window at hand: the page padding on a phone (16 dp,
/// like every in-wallet screen), the desktop gutter everywhere else.
EdgeInsets _gutterOf(BuildContext context) => AppLayout.isPhone(context)
    ? const EdgeInsets.symmetric(horizontal: AppSpacing.lg)
    : _gutter;

class WalletPickerScreen extends StatefulWidget {
  const WalletPickerScreen({super.key});

  @override
  State<WalletPickerScreen> createState() => _WalletPickerScreenState();
}

class _WalletPickerScreenState extends State<WalletPickerScreen> {
  final _bridge = walletBridge;
  final _searchController = TextEditingController();
  List<WalletSummary> _wallets = [];
  bool _loading = true;
  String? _error;
  String _query = '';

  /// Storage is open — the header offers to lock it. Never guessed: no
  /// status, no button.
  bool _vaultUnlocked = false;

  @override
  void initState() {
    super.initState();
    _load();
    _refreshVault();
  }

  Future<void> _refreshVault() async {
    try {
      final v = await _bridge.vaultStatus();
      if (mounted) {
        setState(() => _vaultUnlocked = v.initialized && v.unlocked);
      }
    } catch (_) {
      if (mounted) setState(() => _vaultUnlocked = false);
    }
  }

  Future<void> _lock() async {
    await lockVaultAndPrompt(context, onUnlocked: () {
      if (mounted) _refreshVault();
    });
    if (mounted) _refreshVault();
  }

  Future<void> _load() async {
    // This is the app's entry screen: a bridge failure here (instance lock
    // held, unreadable registry) must surface its message, not spin forever.
    final List<WalletSummary> wallets;
    try {
      wallets = await _bridge.listWallets();
    } catch (e) {
      if (mounted) {
        setState(() { _loading = false; _error = e.toString(); });
      }
      return;
    }
    if (!mounted) return;
    // Entry screen always shows the brand accent, not the last wallet's tint.
    context.read<AppState>().setAccent(null);
    if (wallets.isEmpty) {
      context.go(AppRoutes.welcome);
      return;
    }
    setState(() { _wallets = wallets; _loading = false; _error = null; });
  }

  List<WalletSummary> get _filtered => _wallets.where((w) =>
      w.name.toLowerCase().contains(_query.toLowerCase())).toList();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    // Search is chrome. It only earns its place once the list is long enough
    // that scanning it by eye stops working.
    final showSearch = _wallets.length > 6;

    final phone = AppLayout.isPhone(context);
    return Scaffold(
      body: PageBackground(
        // Edge-to-edge on mobile: inert on desktop.
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 980),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(height: phone ? AppSpacing.md : AppSpacing.xxl),
                  // Brand line — deliberately small. The wall label is not the
                  // exhibit; the wallets are.
                  Padding(
                    padding: _gutterOf(context),
                    child: Row(
                      children: [
                        const AppLogo(size: 32),
                        const SizedBox(width: AppSpacing.md),
                        Text(
                          'Templar Wallet',
                          style: AppTypography.gallerySection
                              .copyWith(color: s.inkSecondary),
                        ),
                        const Spacer(),
                        // Desktop only: on a phone the lock lives in
                        // Settings, next to the same switch that opens it.
                        if (_vaultUnlocked && !phone) ...[
                          _LockButton(onTap: _lock),
                          const SizedBox(width: AppSpacing.xs),
                        ],
                        const _ThemeToggle(),
                      ],
                    ),
                  ),
                  SizedBox(height: phone ? AppSpacing.lg : AppSpacing.xxxl),
                  Padding(
                    padding: _gutterOf(context),
                    child: LayoutBuilder(
                      builder: (context, c) {
                        final titleBlock = Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Your Wallets',
                              style: AppTypography.displayTitleOf(context)
                                  .copyWith(color: s.ink),
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            Text(
                              'Select a wallet to open',
                              style: AppTypography.body
                                  .copyWith(color: s.inkSecondary),
                            ),
                          ],
                        );
                        final actions = [
                          SecondaryButton(
                            label: 'Restore',
                            icon: Icons.restore,
                            isFullWidth: phone,
                            onPressed: () =>
                                context.go(AppRoutes.importWallet),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          AccentButton(
                            label: 'New Wallet',
                            icon: Icons.add,
                            isFullWidth: phone,
                            onPressed: () => context.go(AppRoutes.walletType),
                          ),
                        ];
                        // Phone widths: the two buttons would squeeze the
                        // display title into a column of letters — stack.
                        // On a phone they share the row in two equal halves.
                        if (c.maxWidth < 560) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              titleBlock,
                              const SizedBox(height: AppSpacing.lg),
                              phone
                                  ? Row(children: [
                                      Expanded(child: actions[0]),
                                      actions[1],
                                      Expanded(child: actions[2]),
                                    ])
                                  : Row(children: actions),
                            ],
                          );
                        }
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [Expanded(child: titleBlock), ...actions],
                        );
                      },
                    ),
                  ),
                  if (showSearch) ...[
                    const SizedBox(height: AppSpacing.xl),
                    Padding(
                      padding: _gutterOf(context),
                      child: TextField(
                        controller: _searchController,
                        decoration: const InputDecoration(
                          hintText: 'Search wallets…',
                          prefixIcon: Icon(Icons.search, size: 18),
                        ),
                        onChanged: (v) => setState(() => _query = v),
                      ),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.xl),
                  Expanded(
                    child: _loading
                        ? const Center(child: CircularProgressIndicator())
                        : _error != null
                            ? _LoadError(
                                message: _error!,
                                onRetry: () {
                                  setState(() {
                                    _loading = true;
                                    _error = null;
                                  });
                                  _load();
                                },
                              )
                            : _WalletGallery(
                                wallets: _filtered,
                                query: _query,
                                onSelect: _openWallet,
                              ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openWallet(WalletSummary wallet) async {
    // Load customization to check for password gate
    final custom = await WalletCustomizationStore.instance.load(wallet.id);
    if (!mounted) return;

    if (custom.passwordHash != null) {
      final ok = await _showPasswordPrompt(custom.passwordHash!);
      if (!ok || !mounted) return;
    }

    final displayName = custom.nameOverride ?? wallet.name;

    // Apply the wallet's personal accent across the whole app.
    if (mounted) {
      context.read<AppState>().setAccent(
            custom.accentColor != null ? Color(custom.accentColor!) : null,
          );
    }

    // For USB hardware wallets, ask intent first: connect the device now, or
    // open watch-only (balance + receive only). "Connect" runs the scan wizard.
    var hwWatchOnly = false;
    if (wallet.isHardwareWallet) {
      final choice = await showHwOpenChoiceDialog(context, walletName: displayName);
      if (!mounted) return;
      switch (choice) {
        case HwOpenChoice.cancelled:
          return;
        case HwOpenChoice.watchOnly:
          hwWatchOnly = true;
        case HwOpenChoice.connect:
          final result = await showLedgerConnectDialog(
            context,
            expectedFingerprint: fingerprintFromTypeLabel(wallet.typeLabel),
          );
          if (!mounted) return;
          switch (result) {
            case LedgerConnectResult.cancelled:
              return;
            case LedgerConnectResult.watchOnly:
              hwWatchOnly = true;
            case LedgerConnectResult.connected:
              hwWatchOnly = false;
          }
      }
    }
    context.read<AppState>().setActiveWallet(
          wallet.id,
          name: displayName,
          type: wallet.displayType,
          hwWatchOnly: hwWatchOnly,
          liquid: wallet.liquidEnabled,
          bitcoin: wallet.bitcoinEnabled,
        );
    if (mounted) context.go(AppRoutes.dashboard);
  }

  Future<bool> _showPasswordPrompt(String storedHash) async {
    return await showAppDialog<bool>(context,
          barrierDismissible: false,
          builder: (_) => _WalletPasswordDialog(storedHash: storedHash),
        ) ??
        false;
  }
}

// ── Load failure ──────────────────────────────────────────────────────────────
// Startup errors ("Another Templar Wallet instance is already running…",
// "Wallet storage could not be read: …") are actionable sentences — show them
// in full so the user knows what to fix before retrying.

class _LoadError extends StatelessWidget {
  const _LoadError({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: GlassCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, size: 40, color: s.danger),
              const SizedBox(height: AppSpacing.md),
              Text('Could not load your wallets',
                  style: AppTypography.sectionTitle),
              const SizedBox(height: AppSpacing.sm),
              Text(
                message,
                style: AppTypography.bodySmall.copyWith(color: s.inkSecondary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.lg),
              PrimaryButton(
                label: 'Retry',
                isFullWidth: AppLayout.isPhone(context),
                onPressed: onRetry,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── The gallery ───────────────────────────────────────────────────────────────
//
// Museum tiles, not UI cards. The old cards carried a border, a shadow, a
// coloured edge and a fill each — four pieces of chrome competing with the only
// thing that matters, which wallet this is. Here the tile is a bare canvas, the
// only shadow in the whole screen is the one under the plate (product imagery
// resting on a surface), and the accent is reserved for the tile under the
// pointer.

class _WalletGallery extends StatelessWidget {
  const _WalletGallery({
    required this.wallets,
    required this.query,
    required this.onSelect,
  });

  final List<WalletSummary> wallets;
  final String query;
  final void Function(WalletSummary) onSelect;

  /// Widest a card may get before another column is added.
  static const double _maxCard = 264;

  /// Gutter between cards. They are separate objects on the wall, not one
  /// continuous surface, so the gap has to read clearly.
  static const double _gap = AppSpacing.lg;

  @override
  Widget build(BuildContext context) {
    if (wallets.isEmpty) return _NoMatches(query: query);
    if (AppLayout.isPhone(context)) {
      // One wallet per row: a two-column grid at 379 dp gives 165 dp tiles
      // that cannot hold a plate, a two-line name and the fact line.
      return ListView.separated(
        padding: _gutterOf(context) +
            const EdgeInsets.only(bottom: AppSpacing.xxl),
        itemCount: wallets.length,
        separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.md),
        itemBuilder: (context, i) => _WalletRow(
          wallet: wallets[i],
          position: i + 1,
          onTap: () => onSelect(wallets[i]),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, c) {
        // Column count is computed here rather than left to
        // SliverGridDelegateWithMaxCrossAxisExtent because the checkerboard
        // needs to know which column a card is in. Width available to the
        // cards themselves excludes the page gutter the grid pads by.
        final usable = c.maxWidth - _gutter.horizontal;
        final columns =
            ((usable + _gap) / (_maxCard + _gap)).ceil().clamp(1, 4);
        return GridView.builder(
          padding: _gutter + const EdgeInsets.only(bottom: AppSpacing.xxl),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: _gap,
            mainAxisSpacing: _gap,
            // Square, near enough to read as one. The 5% of extra height is
            // headroom for a two-line name: at four columns a card is only
            // ~217px wide, and a dead-square card overflowed by 18px the
            // moment "My Multisig Wallet" wrapped.
            childAspectRatio: 0.95,
          ),
          itemCount: wallets.length,
          itemBuilder: (context, i) => _WalletTile(
            wallet: wallets[i],
            position: i + 1,
            onTap: () => onSelect(wallets[i]),
          ),
        );
      },
    );
  }
}

class _NoMatches extends StatelessWidget {
  const _NoMatches({required this.query});
  final String query;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return Padding(
      padding: _gutterOf(context),
      child: Align(
        alignment: Alignment.topLeft,
        child: Text(
          'No wallet matches “$query”.',
          style: AppTypography.body.copyWith(color: s.inkSecondary),
        ),
      ),
    );
  }
}

/// The phone exhibit: plate, name and facts on one row, a chevron at the
/// end, press feedback instead of hover. Same customization source as the
/// desktop tile.
class _WalletRow extends StatefulWidget {
  const _WalletRow({
    required this.wallet,
    required this.position,
    required this.onTap,
  });

  final WalletSummary wallet;
  final int position;
  final VoidCallback onTap;

  @override
  State<_WalletRow> createState() => _WalletRowState();
}

class _WalletRowState extends State<_WalletRow> {
  WalletCustomization? _custom;
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    WalletCustomizationStore.instance.load(widget.wallet.id).then((c) {
      if (mounted) setState(() => _custom = c);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final name = _custom?.nameOverride ?? widget.wallet.name;
    final tint = _custom?.accentColor != null
        ? Color(_custom!.accentColor!)
        : s.accent;
    final locked = _custom?.passwordHash != null;
    final motion = AppMotion.of(context, AppMotion.quick);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: widget.onTap,
        onHighlightChanged: (v) => setState(() => _pressed = v),
        borderRadius: BorderRadius.circular(AppSpacing.radiusXl),
        child: AnimatedContainer(
          duration: motion,
          decoration: BoxDecoration(
            color: _pressed ? s.cardHover : s.cardBase,
            borderRadius: BorderRadius.circular(AppSpacing.radiusXl),
            border: Border.all(color: _pressed ? s.edgeStrong : s.edge),
          ),
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.sm,
            AppSpacing.md,
          ),
          child: Row(
            children: [
              WalletPlate(
                icon: WalletFlags.kindIcon(widget.wallet),
                tint: tint,
                raised: _pressed,
                size: 44,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          widget.position.toString().padLeft(2, '0'),
                          style: AppTypography.monoSmall.copyWith(
                            color: _pressed ? tint : s.inkFaint,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(
                            name,
                            style: AppTypography.galleryTitleOf(context)
                                .copyWith(color: s.ink, height: 1.12),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (locked)
                          Padding(
                            padding: const EdgeInsets.only(left: AppSpacing.sm),
                            child: Icon(Icons.lock_outline_rounded,
                                size: 15, color: s.inkFaint),
                          ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    WalletFlags(wallet: widget.wallet, stacked: false),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              Icon(Icons.chevron_right_rounded, color: s.inkFaint),
            ],
          ),
        ),
      ),
    );
  }
}

/// One exhibit. Plate on a canvas, headline under it, one line of facts.
class _WalletTile extends StatefulWidget {
  const _WalletTile({
    required this.wallet,
    required this.position,
    required this.onTap,
  });

  final WalletSummary wallet;
  final int position;
  final VoidCallback onTap;

  @override
  State<_WalletTile> createState() => _WalletTileState();
}

class _WalletTileState extends State<_WalletTile> {
  WalletCustomization? _custom;
  bool _hover = false;

  @override
  void initState() {
    super.initState();
    WalletCustomizationStore.instance.load(widget.wallet.id).then((c) {
      if (mounted) setState(() => _custom = c);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final name = _custom?.nameOverride ?? widget.wallet.name;
    // The wallet's own colour, or the brand accent when it has never been
    // re-tinted. Colour is the whole identity here now — the emoji badge that
    // used to sit on the plate said nothing about the wallet, and two wallets
    // with the same emoji were indistinguishable at a glance.
    final tint = _custom?.accentColor != null
        ? Color(_custom!.accentColor!)
        : s.accent;
    final locked = _custom?.passwordHash != null;
    final motion = AppMotion.of(context, AppMotion.quick);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: motion,
          decoration: BoxDecoration(
            color: _hover ? s.cardHover : s.cardBase,
            borderRadius: BorderRadius.circular(AppSpacing.radiusXl),
            // A hairline, and only a hairline. The card must never cast a
            // shadow — the plate inside it is the one thing on this screen
            // that does.
            border: Border.all(
              color: _hover ? s.edgeStrong : s.edge,
            ),
          ),
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  WalletPlate(
                    icon: WalletFlags.kindIcon(widget.wallet),
                    tint: tint,
                    raised: _hover,
                  ),
                  const Spacer(),
                  if (locked)
                    Tooltip(
                      message: 'Password protected',
                      child: Icon(Icons.lock_outline_rounded,
                          size: 15, color: s.inkFaint),
                    ),
                ],
              ),
              const Spacer(),
              // Index number — quiet, and the second thing that goes red.
              AnimatedDefaultTextStyle(
                duration: motion,
                style: AppTypography.monoSmall.copyWith(
                  color: _hover ? tint : s.inkFaint,
                  fontWeight: FontWeight.w600,
                ),
                child: Text(widget.position.toString().padLeft(2, '0')),
              ),
              const SizedBox(height: 2),
              // Two lines, not one: a square card is ~180px of text width and
              // "My Multisig Wallet" ellipsed to "My Multisig W…". The block
              // is bottom-anchored, so a second line grows up into the
              // whitespace and the fact lines stay on one baseline across the
              // row.
              Text(
                name,
                style: AppTypography.galleryTitle
                    .copyWith(color: s.ink, height: 1.12),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: AppSpacing.sm),
              // The one red rule: it grows in under the headline on hover and
              // is the whole hover affordance, no fill or border change needed.
              AnimatedContainer(
                duration: motion,
                curve: AppMotion.settle,
                height: 2,
                width: _hover ? 34 : 0,
                color: tint,
              ),
              const SizedBox(height: AppSpacing.sm),
              WalletFlags(wallet: widget.wallet, stacked: true),
            ],
          ),
        ),
      ),
    );
  }
}

/// Lock wallet storage from the picker — the same action as the sidebar
/// footer's lock, for the moment before any wallet is open. Sits beside the
/// theme toggle and takes its shape.
class _LockButton extends StatelessWidget {
  const _LockButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return Tooltip(
      message: 'Lock wallet storage',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: Icon(Icons.lock_outline, size: 18, color: s.inkSecondary),
        ),
      ),
    );
  }
}

/// Small dark/light toggle, same affordance as the one in the wallet shell.
class _ThemeToggle extends StatelessWidget {
  const _ThemeToggle();

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final dark = context.select<AppState, ThemeMode>((st) => st.themeMode) ==
        ThemeMode.dark;
    return Tooltip(
      message: dark ? 'Light mode' : 'Dark mode',
      child: InkWell(
        onTap: context.read<AppState>().toggleTheme,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        // 18 dp of glyph inside 8 dp of padding is a 34 dp target — under
        // the 48 dp floor, and this is the only control in the picker's
        // header. Grow the hit area on a phone; the glyph, its size and its
        // colour stay exactly as they are, and desktop keeps its 8 dp box.
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: AppLayout.isPhone(context) ? AppLayout.minTouchTarget : 0,
            minHeight:
                AppLayout.isPhone(context) ? AppLayout.minTouchTarget : 0,
          ),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.sm),
            child: Icon(
              dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
              size: 18,
              color: s.inkSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class _WalletPasswordDialog extends StatefulWidget {
  const _WalletPasswordDialog({required this.storedHash});
  final String storedHash;

  @override
  State<_WalletPasswordDialog> createState() => _WalletPasswordDialogState();
}

class _WalletPasswordDialogState extends State<_WalletPasswordDialog> {
  final _ctrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (WalletCustomizationStore.verifyPassword(_ctrl.text, widget.storedHash)) {
      Navigator.of(context).pop(true);
    } else {
      setState(() => _error = 'Incorrect password');
    }
  }

  @override
  Widget build(BuildContext context) {
    return GlassDialog(
      title: 'Wallet locked',
      icon: Icons.lock_outline,
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Unlock')),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Enter the password to open this wallet.', style: AppTypography.caption),
          const SizedBox(height: AppSpacing.md),
          GlassPasswordField(
            controller: _ctrl,
            autofocus: true,
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
