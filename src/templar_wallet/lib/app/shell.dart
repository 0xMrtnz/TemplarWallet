import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'app_state.dart';
import 'back_handler.dart';
import 'routes.dart';
import '../bridge/bridge_provider.dart';
import '../dev/shot_mode.dart';
import '../bridge/wallet_bridge.dart';
import '../theme/app_colors.dart';
import '../theme/app_motion.dart';
import '../theme/app_scheme.dart';
import '../shared/widgets/app_logo.dart';
import '../shared/widgets/carousel_nav.dart';
import '../shared/widgets/segmented_switch.dart';
import '../shared/widgets/wallet_plate.dart';
import '../features/wallet_picker/wallet_flags.dart';
import '../features/vault/lock_action.dart';
import '../theme/app_spacing.dart';
import '../theme/app_typography.dart';

/// LiquiDEX swaps are backed by the real v0 engine: live order-book browse,
/// offline+deep verify, and make/take signing on Liquid testnet.
const bool kSwapFeatureEnabled = true;

// ── Theme-adaptive sidebar color palette (resolved from AppScheme) ────────────

class _SC {
  _SC(this.scheme);
  final AppScheme scheme;

  bool get dark => scheme.isDark;
  Color get bg => dark ? const Color(0xFF08080A) : const Color(0xFFECEFF3);
  Color get border => scheme.edge;
  Color get text => scheme.inkSecondary;
  Color get textActive => scheme.ink;
  Color get activeItemBg => scheme.accentSoft;
  Color get sectionLabel => scheme.inkFaint;
  Color get divider => scheme.edge;
}

// ── Shell ─────────────────────────────────────────────────────────────────────

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.child, required this.currentPath});
  final Widget child;
  final String currentPath;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  bool _expanded = true;

  void _toggle() => setState(() => _expanded = !_expanded);

  @override
  Widget build(BuildContext context) {
    // Phones and tablets get the header + carousel shell; the desktop
    // sidebar below is untouched.
    if (Platform.isAndroid || Platform.isIOS) {
      return MobileShell(currentPath: widget.currentPath, child: widget.child);
    }

    final sc = _SC(AppScheme.of(context));

    return Scaffold(
      body: Row(
        children: [
          RepaintBoundary(
            child: AnimatedContainer(
              duration: AppMotion.of(context, AppMotion.standard),
              curve: AppMotion.settle,
              width: _expanded
                  ? AppSpacing.sidebarWidth
                  : AppSpacing.sidebarWidthCollapsed,
              clipBehavior: Clip.hardEdge,
              decoration: BoxDecoration(
                color: sc.bg,
                border: Border(right: BorderSide(color: sc.border)),
              ),
              child: _Sidebar(
                currentPath: widget.currentPath,
                expanded: _expanded,
                onToggle: _toggle,
                sc: sc,
              ),
            ),
          ),
          // No VerticalDivider — border is on the AnimatedContainer itself.
          Expanded(
            child: RepaintBoundary(
              child: _BadgedContent(child: widget.child),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Page content ──────────────────────────────────────────────────────────────

/// The routed page, with the mock-data and regtest strips stacked above it
/// whenever they apply. Shared by the desktop and mobile shells.
class _BadgedContent extends StatelessWidget {
  const _BadgedContent({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Selector<AppState, bool>(
      selector: (_, s) => s.isLiquidRegtest,
      builder: (context, isRegtest, child) {
        // kShotMode: documentation screenshots run on the mock bridge on
        // purpose, and the strip would be in every picture (see
        // lib/dev/shot_mode.dart). Never false in a shipped build.
        final showMock = isMockBridge && !kShotMode;
        if (!showMock && !isRegtest) return child!;
        return Column(
          children: [
            if (showMock) const _MockDataBadge(),
            if (isRegtest) const _RegtestBadge(),
            Expanded(child: child!),
          ],
        );
      },
      child: child,
    );
  }
}

// ── Mobile shell ──────────────────────────────────────────────────────────────

/// The phone shell: a thin header (wallet, sync), the page, and the bottom
/// carousel in place of the sidebar. Lock and theme live in Settings here.
///
/// Also owns the Android back button for everything inside the shell. A
/// screen may claim it through [BackHandler] (the Send wizard steps back);
/// otherwise back leaves a sub-page for its parent ([mobileParentRouteFor]),
/// leaves a carousel page for the Dashboard, and leaves the app from the
/// Dashboard. The `PopScope` sits on the shell route itself — the page the
/// root navigator shows — because every in-shell navigation is a `go`, so
/// the nested navigator never has anything to pop and go_router hands the
/// press to the root navigator's top route.
class MobileShell extends StatefulWidget {
  const MobileShell({
    super.key,
    required this.child,
    required this.currentPath,
  });
  final Widget child;
  final String currentPath;

  @override
  State<MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends State<MobileShell> {
  /// The page's outermost vertical scrollable, as last reported by its
  /// notifications, so a tap on the centred nav icon can bring it back to
  /// the top. Forgotten when the page changes.
  BuildContext? _scrollContext;

  bool get _onDashboard => widget.currentPath == AppRoutes.dashboard;

  @override
  void didUpdateWidget(MobileShell old) {
    super.didUpdateWidget(old);
    if (old.currentPath != widget.currentPath) _scrollContext = null;
  }

  bool _onScrollNotification(Notification n) {
    if (n is ScrollNotification) {
      if (n.depth == 0 && n.metrics.axis == Axis.vertical) {
        _scrollContext = n.context;
      }
    } else if (n is ScrollMetricsNotification) {
      if (n.depth == 0 && n.metrics.axis == Axis.vertical) {
        _scrollContext = n.context;
      }
    }
    return false;
  }

  void _scrollToTop() {
    final ctx = _scrollContext;
    if (ctx == null || !ctx.mounted) return;
    final position = ctx.findAncestorStateOfType<ScrollableState>()?.position;
    if (position == null || !position.hasPixels) return;
    final top = position.minScrollExtent;
    if (position.pixels <= top) return;
    if (AppMotion.reduced(context)) {
      position.jumpTo(top);
    } else {
      position.animateTo(
        top,
        duration: AppMotion.emphasized,
        curve: AppMotion.settle,
      );
    }
  }

  /// One step up: a screen with its own notion of back (the Send wizard)
  /// goes first, then the sub-page's parent, then the Dashboard. Shared by
  /// the system back and the header's arrow so the two never disagree.
  void _goBack() {
    if (BackHandler.instance.dispatch()) return;
    if (_onDashboard) return;
    context.go(mobileParentRouteFor(widget.currentPath) ?? AppRoutes.dashboard);
  }

  void _onPop(bool didPop, Object? result) {
    if (didPop) return;
    _goBack();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final dark = s.isDark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      // Transparent bars, icons following the theme — edge-to-edge itself
      // is switched on in main.dart.
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
        statusBarBrightness: dark ? Brightness.dark : Brightness.light,
        systemStatusBarContrastEnforced: false,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
        systemNavigationBarIconBrightness: dark
            ? Brightness.light
            : Brightness.dark,
        systemNavigationBarContrastEnforced: false,
      ),
      child: ListenableBuilder(
        listenable: BackHandler.instance,
        builder: (context, child) => PopScope(
          canPop: _onDashboard && !BackHandler.instance.hasHandlers,
          onPopInvokedWithResult: _onPop,
          child: child!,
        ),
        child: Scaffold(
          backgroundColor: s.canvas,
          body: Column(
            children: [
              _MobileHeader(
                currentPath: widget.currentPath,
                onBack: _goBack,
              ),
              // The Liquid hub: Assets, LiquiDEX and Peg share one carousel
              // slot and are told apart by this strip.
              if (isLiquidHubRoute(widget.currentPath))
                _LiquidHubTabs(currentPath: widget.currentPath),
              Expanded(
                // The header took the status-bar inset; the page must not
                // take it again. The bottom inset is already removed by the
                // Scaffold for a body above a bottomNavigationBar.
                child: Builder(
                  builder: (context) => MediaQuery.removePadding(
                    context: context,
                    removeTop: true,
                    child: NotificationListener<Notification>(
                      onNotification: _onScrollNotification,
                      child: RepaintBoundary(
                        child: _BadgedContent(child: widget.child),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          // In the Scaffold's own slot rather than at the foot of the
          // Column: the keyboard then covers the bar and the page above it
          // resizes, instead of the bar riding up on top of the keyboard.
          bottomNavigationBar: Selector<AppState, bool>(
            selector: (_, st) => st.activeWalletLiquid,
            builder: (context, liquid, _) {
              return CarouselNav(
                items: mobileNavItems(liquid: liquid),
                currentRoute: mobileNavRouteFor(widget.currentPath),
                onSelect: (route) => context.go(route),
                onCenterTap: _scrollToTop,
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The carousel entries: the five places a wallet is *browsed* from. The
/// bar used to carry ten; Send and Receive now live on the Dashboard hero
/// (where the balance they act on is), Wallet Info sits inside Settings,
/// and LiquiDEX and Peg share the Liquid slot as tabs. Only the Liquid slot
/// is gated — a Bitcoin-only wallet has nothing to put behind it.
List<CarouselNavItem> mobileNavItems({required bool liquid}) {
  return [
    const CarouselNavItem(
      id: 'dashboard',
      label: 'Dashboard',
      route: AppRoutes.dashboard,
      icon: Icons.home_outlined,
      activeIcon: Icons.home,
    ),
    const CarouselNavItem(
      id: 'history',
      label: 'Activity',
      route: AppRoutes.history,
      icon: Icons.history_outlined,
      activeIcon: Icons.history,
    ),
    const CarouselNavItem(
      id: 'utxos',
      label: 'UTXOs',
      route: AppRoutes.utxos,
      icon: Icons.account_balance_wallet_outlined,
      activeIcon: Icons.account_balance_wallet,
    ),
    if (liquid)
      const CarouselNavItem(
        id: 'liquid',
        label: 'Liquid',
        route: AppRoutes.liquid,
        icon: Icons.water_outlined,
        activeIcon: Icons.water,
        group: CarouselNavGroup.liquid,
      ),
    const CarouselNavItem(
      id: 'settings',
      label: 'Settings',
      route: AppRoutes.settings,
      icon: Icons.settings_outlined,
      activeIcon: Icons.settings,
      group: CarouselNavGroup.system,
    ),
  ];
}

// ── Mobile route map ──────────────────────────────────────────────────────────
//
// Every in-shell route is either a carousel page or a sub-page of one. The
// three functions below are the whole map: which slot a path keeps centred,
// where its back arrow goes, and what the header calls it.

/// Assets, LiquiDEX and Peg: one carousel slot, a tab strip under the header.
bool isLiquidHubRoute(String path) =>
    path == AppRoutes.liquid || path == AppRoutes.swap || path == AppRoutes.peg;

bool _isLiquidSubScreen(String path) =>
    path == AppRoutes.issueAsset ||
    path == AppRoutes.reissueAsset ||
    path == AppRoutes.burnAsset ||
    path == AppRoutes.assetOperations;

bool _isSettingsSection(String path) =>
    path != AppRoutes.settings && path.startsWith('${AppRoutes.settings}/');

/// The carousel item a path belongs to. A sub-page keeps its parent's slot
/// centred, so the bar always says where the user came from.
String mobileNavRouteFor(String path) {
  if (path == AppRoutes.send ||
      path == AppRoutes.receive ||
      path == AppRoutes.receiveAddresses) {
    return AppRoutes.dashboard;
  }
  if (isLiquidHubRoute(path) || _isLiquidSubScreen(path)) {
    return AppRoutes.liquid;
  }
  if (path == AppRoutes.walletInfo || _isSettingsSection(path)) {
    return AppRoutes.settings;
  }
  return path;
}

/// Where the header's arrow and the system back lead from [path]; null on a
/// carousel page, where back means "to the Dashboard" (the shell's default).
String? mobileParentRouteFor(String path) {
  if (path == AppRoutes.send || path == AppRoutes.receive) {
    return AppRoutes.dashboard;
  }
  if (path == AppRoutes.receiveAddresses) return AppRoutes.receive;
  if (_isLiquidSubScreen(path)) return AppRoutes.liquid;
  if (path == AppRoutes.walletInfo || _isSettingsSection(path)) {
    return AppRoutes.settings;
  }
  return null;
}

/// The header title of a sub-page; null on a carousel page, where the
/// header shows the wallet instead.
String? mobileSubPageTitle(String path) => switch (path) {
  AppRoutes.send => 'Send',
  AppRoutes.receive => 'Receive',
  AppRoutes.receiveAddresses => 'All addresses',
  AppRoutes.walletInfo => 'Wallet info',
  AppRoutes.settingsNetwork => 'Nodes & explorers',
  AppRoutes.settingsProtocol => 'Templar Protocol',
  AppRoutes.settingsSecurity => 'Vault & backup',
  AppRoutes.settingsAppearance => 'Theme & units',
  AppRoutes.settingsAbout => 'About',
  AppRoutes.issueAsset => 'Issue asset',
  AppRoutes.reissueAsset => 'Reissue',
  AppRoutes.burnAsset => 'Burn',
  AppRoutes.assetOperations => 'Asset operations',
  _ => null,
};

// ── Liquid hub tabs ───────────────────────────────────────────────────────────

/// Assets · LiquiDEX · Peg under the header, in Liquid teal. Each tab is a
/// route, so the strip is only a switch: the three screens are untouched and
/// the carousel keeps Liquid centred through all of them. Peg needs a
/// Bitcoin side to peg out to; on a Liquid-only wallet the segment stays in
/// place, dimmed, and says why when tapped.
class _LiquidHubTabs extends StatelessWidget {
  const _LiquidHubTabs({required this.currentPath});
  final String currentPath;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final bitcoin = context.select<AppState, bool>(
      (st) => st.activeWalletBitcoin,
    );
    final tint = s.liquid;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: s.edge)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.sm,
          AppSpacing.lg,
          AppSpacing.sm,
        ),
        child: SegmentedSwitch<String>(
          dense: true,
          expand: true,
          selected: currentPath,
          onChanged: (route) {
            if (route != currentPath) context.go(route);
          },
          options: [
            SegOption(
              value: AppRoutes.liquid,
              label: 'Assets',
              icon: Icons.water_drop_outlined,
              color: tint,
            ),
            if (kSwapFeatureEnabled)
              SegOption(
                value: AppRoutes.swap,
                label: 'LiquiDEX',
                icon: Icons.swap_horiz,
                color: tint,
              ),
            SegOption(
              value: AppRoutes.peg,
              label: 'Peg',
              icon: Icons.swap_vert_outlined,
              color: tint,
              enabled: bitcoin,
              tooltip: bitcoin
                  ? null
                  : 'Peg needs a Bitcoin side — this wallet is Liquid-only.',
            ),
          ],
        ),
      ),
    );
  }
}

// ── Mobile header ─────────────────────────────────────────────────────────────

/// Largest text scale the header honours: past it the two-line wallet
/// block would push the strip well beyond its 48-dp row.
const double _headerMaxTextScale = 1.3;

/// Height of the header's content row under the status bar: one 48-dp
/// touch row plus 2 dp above and below, ~52 dp in all.
const double _headerRowHeight = AppLayout.minTouchTarget;
const double _headerVerticalPad = 2;

/// Wallet plate, name and kind on the left (tap: the wallet list), the sync
/// pill on the right. Sits under the status bar by its own SafeArea and is
/// the only thing that takes that inset — the page below strips it again.
///
/// On a sub-page (Send, Receive, a Settings section, Wallet info) the left
/// half is a back arrow and the page's name instead: the carousel below
/// still shows the parent, so the wallet is one tap away and the header can
/// spend its width on where the user is and how to leave.
///
/// Kept to one 48-dp row (~52 dp with its pads) so that, with the carousel,
/// chrome stays well under a fifth of a phone screen. Both controls fill the
/// row, so the whole strip is tappable.
class _MobileHeader extends StatelessWidget {
  const _MobileHeader({required this.currentPath, required this.onBack});

  final String currentPath;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final subTitle = mobileSubPageTitle(currentPath);
    return Selector<AppState, (String?, String?, String?, bool, bool)>(
      selector: (_, st) => (
        st.activeWalletId,
        st.activeWalletName,
        st.activeWalletType,
        st.activeWalletBitcoin,
        st.activeWalletLiquid,
      ),
      builder: (context, wallet, _) {
        final (walletId, walletName, walletType, bitcoin, liquid) = wallet;
        return DecoratedBox(
          // The bottom hairline separates the strip from the page — the
          // carousel has the same edge on top — so the header reads as
          // chrome instead of merging with the first card.
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: s.edge)),
          ),
          child: SafeArea(
            bottom: false,
            child: MediaQuery.withClampedTextScaling(
              maxScaleFactor: _headerMaxTextScale,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  _headerVerticalPad,
                  AppSpacing.lg,
                  _headerVerticalPad,
                ),
                // The row is given its height here: as a plain Column child
                // it has no bounded height of its own, and a stretched Row
                // with unbounded height cannot lay out at all. Both halves
                // then fill the 48 dp, so the whole strip is tappable.
                child: SizedBox(
                  height: _headerRowHeight,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: subTitle != null
                            ? _BackButton(title: subTitle, onTap: onBack)
                            : _WalletButton(
                                walletId: walletId,
                                walletName: walletName,
                                subtitle: _walletSubtitle(
                                  walletType,
                                  bitcoin: bitcoin,
                                  liquid: liquid,
                                ),
                                kindIcon: WalletFlags.kindIconForLabel(
                                  walletType,
                                ),
                              ),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      const _SyncPill(),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The header's left half: plate, wallet name and kind, one 48-dp target
/// that opens the wallet list.
/// "Singlesig · Bitcoin + Liquid" — what kind of wallet this is and what it
/// holds, on the one line under its name. Null before a wallet is open.
String? _walletSubtitle(
  String? type, {
  required bool bitcoin,
  required bool liquid,
}) {
  final chains = bitcoin && liquid
      ? 'Bitcoin + Liquid'
      : liquid
          ? 'Liquid'
          : bitcoin
              ? 'Bitcoin'
              : null;
  final parts = <String>[?type, ?chains];
  return parts.isEmpty ? null : parts.join(' · ');
}

class _WalletButton extends StatelessWidget {
  const _WalletButton({
    required this.walletId,
    required this.walletName,
    required this.subtitle,
    required this.kindIcon,
  });

  final String? walletId;
  final String? walletName;
  final String? subtitle;
  final IconData kindIcon;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final type = subtitle;
    return Semantics(
      button: true,
      hint: 'Opens the wallet list',
      child: InkWell(
        onTap: () => context.go(AppRoutes.walletPicker),
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: _headerRowHeight),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.xs,
              0,
              AppSpacing.sm,
              0,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                WalletPlate(
                  icon: walletId != null
                      ? kindIcon
                      : Icons.account_balance_wallet_outlined,
                  size: 30,
                  shadow: false,
                ),
                const SizedBox(width: AppSpacing.sm + 2),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        walletId != null ? (walletName ?? '…') : 'Open wallet…',
                        style: AppTypography.sectionTitle.copyWith(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          height: 1.15,
                          color: s.ink,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (type != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Row(
                            children: [
                              Flexible(
                                child: Text(
                                  type,
                                  style: AppTypography.caption.copyWith(
                                    fontSize: 11,
                                    height: 1.2,
                                    color: s.inkFaint,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: AppSpacing.xs),
                              // A picker chevron — not the swap glyph the
                              // carousel already uses for LiquiDEX.
                              Icon(
                                Icons.unfold_more,
                                size: 16,
                                color: s.inkFaint,
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The header's left half on a sub-page: an arrow and the page's name, one
/// 48-dp target. Tapping it is the system back — the Send wizard steps back
/// a page before the screen is left, exactly as the hardware button does.
class _BackButton extends StatelessWidget {
  const _BackButton({required this.title, required this.onTap});

  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return Semantics(
      button: true,
      label: 'Back',
      hint: 'Leaves $title',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: _headerRowHeight),
          child: Padding(
            padding: const EdgeInsets.only(right: AppSpacing.sm),
            child: Row(
              children: [
                SizedBox(
                  width: AppLayout.minTouchTarget - AppSpacing.sm,
                  child: Center(
                    child: Icon(
                      Icons.arrow_back_rounded,
                      size: 24,
                      color: s.ink,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    title,
                    style: AppTypography.sectionTitle.copyWith(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      height: 1.15,
                      color: s.ink,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Sync state as a pill: a dot and a short word. Tap to sync. Runs the
/// first sync on mount when auto-sync is on, exactly as the desktop footer.
///
/// The pill itself is visually compact (~26 dp); its hit box is the full
/// 48-dp header row, so the one control a user taps repeatedly is never
/// under the touch minimum.
class _SyncPill extends StatefulWidget {
  const _SyncPill();

  @override
  State<_SyncPill> createState() => _SyncPillState();
}

class _SyncPillState extends State<_SyncPill> {
  final _bridge = walletBridge;

  @override
  void initState() {
    super.initState();
    scheduleAutoSync(context, _bridge);
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return Selector<AppState, (SyncState, String?)>(
      selector: (_, st) => (st.syncState, st.syncDetail),
      builder: (context, data, _) {
        final (syncState, syncDetail) = data;
        final isSyncing = syncState == SyncState.syncing;
        final (dotColor, label) = syncStatusPresentation(
          syncState,
          syncDetail,
          compact: true,
        );
        final dot = SizedBox(
          width: 10,
          height: 10,
          child: Center(
            child: isSyncing
                ? const SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      color: AppColors.warning,
                    ),
                  )
                : DecoratedBox(
                    decoration: BoxDecoration(
                      color: dotColor,
                      shape: BoxShape.circle,
                      boxShadow: syncState == SyncState.synced
                          ? [
                              BoxShadow(
                                color: dotColor.withValues(alpha: 0.7),
                                blurRadius: 8,
                              ),
                            ]
                          : null,
                    ),
                    child: const SizedBox(width: 8, height: 8),
                  ),
          ),
        );
        final pill = Container(
          constraints: const BoxConstraints(minWidth: AppLayout.minTouchTarget),
          padding: const EdgeInsets.fromLTRB(8, 5, 9, 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: s.edge),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              dot,
              const SizedBox(width: 7),
              Text(
                label,
                style: AppTypography.label.copyWith(
                  fontSize: 12,
                  color: s.inkSecondary,
                ),
              ),
            ],
          ),
        );
        return Semantics(
          button: true,
          label: isSyncing ? 'Syncing' : 'Sync now. $label',
          excludeSemantics: true,
          onTap: isSyncing
              ? null
              : () => syncActiveWallet(context.read<AppState>(), _bridge),
          child: SizedBox(
            height: _headerRowHeight,
            child: InkWell(
              onTap: isSyncing
                  ? null
                  : () => syncActiveWallet(context.read<AppState>(), _bridge),
              borderRadius: BorderRadius.circular(_headerRowHeight / 2),
              child: Center(child: pill),
            ),
          ),
        );
      },
    );
  }
}

// ── Mock-data badge ───────────────────────────────────────────────────────────

/// Unmissable strip shown whenever the UI runs on the mock bridge (debug
/// fallback after a failed native load): everything on screen is fake data.
class _MockDataBadge extends StatelessWidget {
  const _MockDataBadge();

  @override
  Widget build(BuildContext context) {
    return const _BadgeStrip(
      color: AppColors.danger,
      textColor: Colors.white,
      text: 'MOCK DATA — wallet engine not loaded',
      phoneText: 'MOCK DATA — engine not loaded',
    );
  }
}

/// One line of bold small caps on a coloured ground, full width. On a phone
/// the copy is the shorter [phoneText], padded at the sides and never
/// wrapped, so the strip is one compact line on every screen width; on
/// desktop the strip is exactly what it always was.
class _BadgeStrip extends StatelessWidget {
  const _BadgeStrip({
    required this.color,
    required this.textColor,
    required this.text,
    required this.phoneText,
  });

  final Color color;
  final Color textColor;
  final String text;
  final String phoneText;

  @override
  Widget build(BuildContext context) {
    final phone = AppSpacing.isPhone(context);
    return Container(
      width: double.infinity,
      color: color,
      padding: EdgeInsets.symmetric(
        vertical: AppSpacing.xs,
        horizontal: phone ? AppSpacing.lg : 0,
      ),
      child: Text(
        phone ? phoneText : text,
        textAlign: TextAlign.center,
        maxLines: phone ? 1 : null,
        overflow: phone ? TextOverflow.ellipsis : null,
        style: TextStyle(
          color: textColor,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// Strip shown while Liquid runs against a local regtest node. Regtest coins
/// are free and the chain is private, so nothing on screen is the public
/// testnet — the strip says so once, on every screen.
class _RegtestBadge extends StatelessWidget {
  const _RegtestBadge();

  @override
  Widget build(BuildContext context) {
    return const _BadgeStrip(
      color: AppColors.warning,
      textColor: Colors.black,
      text: 'LIQUID REGTEST — local elementsd, not the public testnet',
      phoneText: 'LIQUID REGTEST — local node, not testnet',
    );
  }
}

// ── Sidebar ───────────────────────────────────────────────────────────────────

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.currentPath,
    required this.expanded,
    required this.onToggle,
    required this.sc,
  });
  final String currentPath;
  final bool expanded;
  final VoidCallback onToggle;
  final _SC sc;

  /// A settings section route (`/settings/security`) lights the Settings
  /// entry: on desktop the section is a pane inside that one page.
  bool _isActive(String route) =>
      currentPath == route ||
      (route == AppRoutes.settings && _isSettingsSection(currentPath)) ||
      (route == AppRoutes.receive &&
          currentPath == AppRoutes.receiveAddresses);

  @override
  Widget build(BuildContext context) {
    // Only show the Liquid section when the active wallet has Liquid enabled.
    final appState = context.watch<AppState>();
    final showLiquid = appState.activeWalletLiquid;
    // Pure watch-only wallets cannot sign anything — no Send at all.
    final showSend = !appState.isActiveWalletWatchOnly;
    // A peg moves value between the two chains, so it needs both sides. A
    // Liquid-only wallet has no Bitcoin address to peg out to.
    final showPeg = showLiquid && appState.activeWalletBitcoin;
    final group = _groupOf(currentPath);
    return Column(
      children: [
        _SidebarHeader(expanded: expanded, onToggle: onToggle, sc: sc),
        Divider(color: sc.divider, height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            children: [
              _section('WALLET', active: group == _NavGroup.wallet),
              _item(
                AppRoutes.dashboard,
                'Dashboard',
                Icons.home_outlined,
                Icons.home,
              ),
              if (showSend)
                _item(AppRoutes.send, 'Send', Icons.send_outlined, Icons.send),
              _item(
                AppRoutes.receive,
                'Receive',
                Icons.call_received_outlined,
                Icons.call_received,
              ),
              _item(
                AppRoutes.history,
                'Activity',
                Icons.history_outlined,
                Icons.history,
              ),
              _item(
                AppRoutes.utxos,
                'UTXOs',
                Icons.account_balance_wallet_outlined,
                Icons.account_balance_wallet,
              ),
              if (showLiquid) ...[
                _section('LIQUID', active: group == _NavGroup.liquid),
                _item(
                  AppRoutes.liquid,
                  'Liquid',
                  Icons.water_outlined,
                  Icons.water,
                ),
                if (kSwapFeatureEnabled)
                  // Named for the protocol it actually speaks. "Swap" is
                  // reserved for the future Boltz-style Bitcoin <> Liquid <>
                  // Lightning section, which is a different thing entirely.
                  _item(
                    AppRoutes.swap,
                    'LiquiDEX',
                    Icons.swap_horiz,
                    Icons.swap_horiz,
                  ),
                if (showPeg)
                  _item(
                    AppRoutes.peg,
                    'Peg',
                    Icons.swap_vert_outlined,
                    Icons.swap_vert,
                  ),
              ],
              _section('SYSTEM', active: group == _NavGroup.system),
              _item(
                AppRoutes.walletInfo,
                'Wallet Info',
                Icons.info_outline,
                Icons.info,
              ),
              _item(
                AppRoutes.settings,
                'Settings',
                Icons.settings_outlined,
                Icons.settings,
              ),
            ],
          ),
        ),
        Divider(color: sc.divider, height: 1),
        _SidebarFooter(expanded: expanded, sc: sc),
      ],
    );
  }

  static _NavGroup _groupOf(String path) {
    if (path == AppRoutes.liquid ||
        path == AppRoutes.swap ||
        path == AppRoutes.peg) {
      return _NavGroup.liquid;
    }
    if (path == AppRoutes.walletInfo ||
        path == AppRoutes.settings ||
        _isSettingsSection(path)) {
      return _NavGroup.system;
    }
    return _NavGroup.wallet;
  }

  Widget _section(String label, {required bool active}) => _SidebarSection(
    label: label,
    expanded: expanded,
    active: active,
    sc: sc,
  );

  Widget _item(
    String route,
    String label,
    IconData icon,
    IconData activeIcon,
  ) => _SidebarItem(
    route: route,
    label: label,
    icon: icon,
    activeIcon: activeIcon,
    isActive: _isActive(route),
    expanded: expanded,
    sc: sc,
  );
}

// ── Header ────────────────────────────────────────────────────────────────────

class _SidebarHeader extends StatelessWidget {
  const _SidebarHeader({
    required this.expanded,
    required this.onToggle,
    required this.sc,
  });
  final bool expanded;
  final VoidCallback onToggle;
  final _SC sc;

  static const Widget _logo = AppLogo(size: 28, radius: AppSpacing.radiusSm);

  @override
  Widget build(BuildContext context) {
    return Selector<AppState, (String?, String?, String?)>(
      selector: (_, s) =>
          (s.activeWalletId, s.activeWalletName, s.activeWalletType),
      builder: (context, wallet, _) {
        final (walletId, walletName, walletType) = wallet;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top bar: logo (only expanded) + title + chevron.
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Row(
                children: [
                  if (expanded) ...[
                    _logo,
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      // No network line here. It said "Testnet" on every
                      // screen of a testnet-only build, which is wallpaper —
                      // the badge on Home carries that fact once, where it is
                      // read.
                      child: Text(
                        'Templar Wallet',
                        style: TextStyle(
                          color: sc.textActive,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                  // When collapsed, center the chevron.
                  if (!expanded) const Spacer(),
                  _CollapseButton(
                    expanded: expanded,
                    onToggle: onToggle,
                    sc: sc,
                  ),
                  if (!expanded) const Spacer(),
                ],
              ),
            ),
            // Wallet selector row.
            if (expanded)
              _WalletRow(
                walletId: walletId,
                walletName: walletName,
                walletType: walletType,
                sc: sc,
              )
            else if (walletId != null)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: Center(
                  child: _SidebarTooltip(
                    message: walletName ?? 'Wallet',
                    child: InkWell(
                      onTap: () => context.go(AppRoutes.walletPicker),
                      borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                      child: WalletPlate(
                        icon: WalletFlags.kindIconForLabel(walletType),
                        size: 28,
                        shadow: false,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

}

class _CollapseButton extends StatelessWidget {
  const _CollapseButton({
    required this.expanded,
    required this.onToggle,
    required this.sc,
  });
  final bool expanded;
  final VoidCallback onToggle;
  final _SC sc;

  @override
  Widget build(BuildContext context) {
    return _SidebarTooltip(
      message: expanded ? 'Collapse' : 'Expand',
      child: InkWell(
        onTap: onToggle,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: AnimatedRotation(
            turns: expanded ? 0 : 0.5,
            duration: const Duration(milliseconds: 200),
            child: Icon(Icons.chevron_left, size: 16, color: sc.text),
          ),
        ),
      ),
    );
  }
}

class _WalletRow extends StatelessWidget {
  const _WalletRow({
    required this.walletId,
    required this.walletName,
    required this.walletType,
    required this.sc,
  });
  final String? walletId;
  final String? walletName;
  final String? walletType;
  final _SC sc;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.sm,
        0,
        AppSpacing.sm,
        AppSpacing.sm,
      ),
      child: InkWell(
        onTap: () => context.go(AppRoutes.walletPicker),
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.sm,
          ),
          child: walletId != null
              ? Row(
                  children: [
                    WalletPlate(
                      icon: WalletFlags.kindIconForLabel(walletType),
                      size: 26,
                      shadow: false,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            walletName ?? '…',
                            style: TextStyle(
                              color: sc.textActive,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (walletType != null)
                            Text(
                              walletType!,
                              style: TextStyle(color: sc.text, fontSize: 10),
                            ),
                        ],
                      ),
                    ),
                    Icon(Icons.swap_horiz, size: 13, color: sc.text),
                  ],
                )
              : Row(
                  children: [
                    Icon(
                      Icons.account_balance_wallet_outlined,
                      size: 15,
                      color: sc.text,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        'Open wallet…',
                        style: TextStyle(color: sc.text, fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(Icons.chevron_right, size: 13, color: sc.text),
                  ],
                ),
        ),
      ),
    );
  }

}

// ── Section label ─────────────────────────────────────────────────────────────

/// Which block of the nav a route belongs to. Only used to mark the separator
/// above the group the user is currently inside.
enum _NavGroup { wallet, liquid, system }

/// A group separator: the label, then a hairline running to the sidebar edge.
///
/// The label on its own was doing two jobs badly — naming the group and
/// dividing it — and at the sidebar's type size it read as one more quiet
/// item rather than a break. The rule does the dividing, so the label can go
/// back to only naming. The group holding the current page picks up an accent
/// tick and a brighter rule, which means the sidebar answers "where am I"
/// twice: once at the item, once at the section.
class _SidebarSection extends StatelessWidget {
  const _SidebarSection({
    required this.label,
    required this.expanded,
    required this.active,
    required this.sc,
  });
  final String label;
  final bool expanded;
  final bool active;
  final _SC sc;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);

    // Collapsed there is no room for a label, and a full-width rule under a
    // 56px strip reads as a border. A short centred rule keeps the rhythm.
    if (!expanded) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Center(
          child: Container(
            width: 16,
            height: 1,
            color: active ? s.accent : sc.divider,
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      child: Row(
        children: [
          if (active) ...[
            Container(
              width: 2,
              height: 9,
              decoration: BoxDecoration(
                color: s.accent,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
            const SizedBox(width: AppSpacing.xs),
          ],
          Text(
            label,
            style: AppTypography.navSection.copyWith(
              color: active ? s.ink : sc.sectionLabel,
              fontWeight: active ? FontWeight.w700 : null,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Container(
              height: 1,
              color: active
                  ? s.accent.withValues(alpha: 0.35)
                  : sc.divider,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Nav item ──────────────────────────────────────────────────────────────────

/// A sidebar entry, built as the same object as a home gallery card: rounded
/// rect, hairline border, translucent card surface, and the accent used only to
/// mark state — never as decoration.
///
/// Hover mirrors the wallet cards exactly (surface steps up, border firms) so
/// the two screens feel like one material. Active adds the red rule, which on
/// the home screen means "the one you are pointing at" and here means "the one
/// you are on".
class _SidebarItem extends StatefulWidget {
  const _SidebarItem({
    required this.route,
    required this.label,
    required this.icon,
    required this.activeIcon,
    required this.isActive,
    required this.expanded,
    required this.sc,
  });

  final String route;
  final String label;
  final IconData icon;
  final IconData activeIcon;
  final bool isActive;
  final bool expanded;
  final _SC sc;

  static const double _iconSlot = 18.0;

  @override
  State<_SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<_SidebarItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final motion = AppMotion.of(context, AppMotion.quick);
    final active = widget.isActive;
    final lit = active || _hover;

    final iconColor = active
        ? s.accent
        : _hover
            ? s.ink
            : widget.sc.text;
    final textColor = lit ? s.ink : widget.sc.text;

    final item = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 2,
      ),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: () => context.go(widget.route),
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: motion,
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm + 2),
            decoration: BoxDecoration(
              color: lit ? s.cardHover : s.cardBase,
              borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
              border: Border.all(color: lit ? s.edgeStrong : s.edge),
            ),
            child: Row(
              children: [
                // Fixed-width icon slot — never moves regardless of expand state.
                SizedBox(
                  width: _SidebarItem._iconSlot,
                  child: Icon(
                    active ? widget.activeIcon : widget.icon,
                    size: _SidebarItem._iconSlot,
                    color: iconColor,
                  ),
                ),
                if (widget.expanded) ...[
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: AnimatedDefaultTextStyle(
                      duration: motion,
                      style: AppTypography.navItem.copyWith(
                        color: textColor,
                        fontWeight:
                            active ? FontWeight.w600 : FontWeight.w500,
                      ),
                      child: Text(
                        widget.label,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  // The red rule, same marker the wallet cards use. It grows in
                  // rather than appearing, so switching pages reads as motion.
                  AnimatedContainer(
                    duration: motion,
                    curve: AppMotion.settle,
                    width: active ? 18 : 0,
                    height: 2,
                    decoration: BoxDecoration(
                      color: s.accent,
                      borderRadius: BorderRadius.circular(1),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );

    if (widget.expanded) return item;
    return _SidebarTooltip(message: widget.label, child: item);
  }
}

// ── Tooltip helper ────────────────────────────────────────────────────────────

class _SidebarTooltip extends StatelessWidget {
  const _SidebarTooltip({required this.message, required this.child});
  final String message;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: message,
      preferBelow: false,
      verticalOffset: 0,
      decoration: BoxDecoration(
        color: AppColors.surfaceDark2,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        border: Border.all(color: AppColors.borderDark),
      ),
      textStyle: const TextStyle(
        color: Colors.white,
        fontSize: 12,
        fontWeight: FontWeight.w500,
      ),
      child: child,
    );
  }
}

// ── Sync (shared by the desktop footer and the mobile header) ────────────────

/// Run a full sync of the active wallet and fold the outcome into
/// [AppState]: synced only when every present chain is ok, a partial failure
/// shows as a warning naming the chain, all-failed shows as an error.
Future<void> syncActiveWallet(AppState appState, WalletBridge bridge) async {
  final walletId = appState.activeWalletId;
  if (walletId == null) return;
  appState.setSyncState(SyncState.syncing);
  final sw = Stopwatch()..start();
  try {
    final outcomes = await bridge.syncWallet(walletId);
    sw.stop();
    debugPrint('[sync] done in ${sw.elapsedMilliseconds}ms — $outcomes');
    appState.applySyncOutcomes(outcomes);
  } catch (e) {
    sw.stop();
    debugPrint('[sync] failed after ${sw.elapsedMilliseconds}ms: $e');
    appState.setSyncState(SyncState.error);
    // Screens reload on syncVersion changes; bump even on failure so a
    // dashboard that mounted mid-sync (its _load early-returns while
    // syncing) still gets a chance to render the cached/offline data
    // instead of staying on the shimmer.
    appState.bumpSync();
  }
}

/// Start the first sync once the shell is up, if the user left auto-sync on.
void scheduleAutoSync(BuildContext context, WalletBridge bridge) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!context.mounted) return;
    final appState = context.read<AppState>();
    if (appState.autoSync && appState.activeWalletId != null) {
      syncActiveWallet(appState, bridge);
    }
  });
}

/// Dot colour and label for a sync state. The footer shows the chain detail
/// of a partial or failed sync; [compact] is the header's short form.
(Color, String) syncStatusPresentation(
  SyncState state,
  String? detail, {
  bool compact = false,
}) =>
    switch (state) {
      SyncState.synced => (AppColors.success, 'Synced'),
      SyncState.syncing => (AppColors.warning, 'Syncing…'),
      SyncState.warning => (
          AppColors.warning,
          compact ? 'Partial' : (detail ?? 'Partial sync'),
        ),
      SyncState.error => (
          AppColors.danger,
          compact ? 'Sync error' : (detail ?? 'Sync Error'),
        ),
      SyncState.idle => (AppColors.textMuted, 'Idle'),
    };

// ── Footer ────────────────────────────────────────────────────────────────────

class _SidebarFooter extends StatefulWidget {
  const _SidebarFooter({required this.expanded, required this.sc});
  final bool expanded;
  final _SC sc;

  @override
  State<_SidebarFooter> createState() => _SidebarFooterState();
}

class _SidebarFooterState extends State<_SidebarFooter> {
  final _bridge = walletBridge;

  /// Whether a Lock control belongs here at all. There is nothing to lock
  /// until a vault exists, and offering the button anyway would surface an
  /// engine error as the answer to a click.
  bool _vaultUnlocked = false;

  @override
  void initState() {
    super.initState();
    _refreshVault();
    scheduleAutoSync(context, _bridge);
  }

  Future<void> _refreshVault() async {
    try {
      final v = await _bridge.vaultStatus();
      if (mounted) {
        setState(() => _vaultUnlocked = v.initialized && v.unlocked);
      }
    } catch (_) {
      // No status, no button — never guess that storage is unlocked.
    }
  }

  Future<void> _lock() async {
    await lockVaultAndPrompt(context);
    if (mounted) _refreshVault();
  }

  Future<void> _sync() => syncActiveWallet(context.read<AppState>(), _bridge);

  @override
  Widget build(BuildContext context) {
    return Selector<AppState, (SyncState, String?, ThemeMode)>(
      selector: (_, s) => (s.syncState, s.syncDetail, s.themeMode),
      builder: (context, data, _) {
        final (syncState, syncDetail, themeMode) = data;
        final isSyncing = syncState == SyncState.syncing;
        final (dotColor, statusLabel) =
            syncStatusPresentation(syncState, syncDetail);

        final sc = widget.sc;

        final syncDot = SizedBox(
          width: 18,
          height: 18,
          child: Center(
            child: isSyncing
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      color: AppColors.warning,
                    ),
                  )
                : Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: dotColor,
                      shape: BoxShape.circle,
                    ),
                  ),
          ),
        );

        final themeDark = themeMode == ThemeMode.dark;

        // Collapsed: the three controls stack, still as buttons. The old
        // footer drew a bare 10px dot and a bare icon with no bounds, so
        // neither looked pressable and the two ran together.
        if (!widget.expanded) {
          return Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: AppSpacing.sm,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _FooterButton(
                  tooltip: statusLabel,
                  onTap: isSyncing ? null : _sync,
                  sc: sc,
                  child: syncDot,
                ),
                const SizedBox(height: AppSpacing.sm),
                _FooterButton(
                  tooltip: themeDark ? 'Light mode' : 'Dark mode',
                  onTap: context.read<AppState>().toggleTheme,
                  sc: sc,
                  child: Icon(
                    themeDark
                        ? Icons.light_mode_outlined
                        : Icons.dark_mode_outlined,
                    size: 17,
                    color: sc.text,
                  ),
                ),
                if (_vaultUnlocked) ...[
                  const SizedBox(height: AppSpacing.sm),
                  _FooterButton(
                    tooltip: 'Lock wallet storage',
                    onTap: _lock,
                    sc: sc,
                    child: Icon(Icons.lock_outline, size: 17, color: sc.text),
                  ),
                ],
              ],
            ),
          );
        }

        // Expanded: status on its own line, controls on theirs. Sharing one
        // row meant the sync state and the buttons competed for 220px and the
        // buttons lost.
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.sm,
            AppSpacing.md,
            AppSpacing.md,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 10,
                    height: 10,
                    child: Center(
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: dotColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      statusLabel,
                      style: AppTypography.caption.copyWith(color: sc.text),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  Expanded(
                    child: _FooterButton(
                      tooltip: isSyncing ? 'Syncing…' : 'Sync now',
                      onTap: isSyncing ? null : _sync,
                      sc: sc,
                      expand: true,
                      child: isSyncing
                          ? const SizedBox(
                              width: 15,
                              height: 15,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.6,
                                color: AppColors.warning,
                              ),
                            )
                          : Icon(Icons.sync, size: 17, color: sc.text),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: _FooterButton(
                      tooltip: themeDark ? 'Light mode' : 'Dark mode',
                      onTap: context.read<AppState>().toggleTheme,
                      sc: sc,
                      expand: true,
                      child: Icon(
                        themeDark
                            ? Icons.light_mode_outlined
                            : Icons.dark_mode_outlined,
                        size: 17,
                        color: sc.text,
                      ),
                    ),
                  ),
                  if (_vaultUnlocked) ...[
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: _FooterButton(
                        tooltip: 'Lock wallet storage',
                        onTap: _lock,
                        sc: sc,
                        expand: true,
                        child: Icon(Icons.lock_outline,
                            size: 17, color: sc.text),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// One footer control. A bounded, bordered target — the same surface grammar
/// as a nav item, so it reads as something you press.
class _FooterButton extends StatefulWidget {
  const _FooterButton({
    required this.tooltip,
    required this.onTap,
    required this.child,
    required this.sc,
    this.expand = false,
  });

  final String tooltip;
  final VoidCallback? onTap;
  final Widget child;
  final _SC sc;

  /// Fill the width given by the parent (the expanded footer lays the three
  /// controls out as equal columns).
  final bool expand;

  @override
  State<_FooterButton> createState() => _FooterButtonState();
}

class _FooterButtonState extends State<_FooterButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final enabled = widget.onTap != null;
    final lit = _hover && enabled;
    return _SidebarTooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor:
            enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: AppMotion.of(context, AppMotion.quick),
            width: widget.expand ? null : 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: lit ? s.cardHover : s.cardBase,
              borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
              border: Border.all(color: lit ? s.edgeStrong : s.edge),
            ),
            child: Opacity(opacity: enabled ? 1 : 0.45, child: widget.child),
          ),
        ),
      ),
    );
  }
}
