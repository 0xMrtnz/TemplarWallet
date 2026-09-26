/// Settings › Templar Protocol — everything the connector does, in one page.
///
/// Before this, the wallet's half of Templar Protocol was invisible: a paste box
/// buried in Network & Sync, and no way to see which sites hold a watch-only
/// view or what was signed for them. The cards read top to bottom as the
/// question a user actually has: am I ready, how do I open a request, who is
/// connected, what did I sign, which wallet answers, and what is this.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/routes.dart';
import '../../bridge/bridge_provider.dart';
import '../../bridge/wallet_bridge.dart';
import '../../services/protocol_store.dart';
import '../../shared/relative_time.dart';
import '../../shared/widgets/banners.dart';
import '../../shared/widgets/buttons.dart';
import '../../shared/widgets/cards.dart';
import '../../shared/widgets/glass_dialog.dart';
import '../../shared/widgets/hybrid_kit.dart';
import '../../shared/widgets/page_header.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import '../protocol/models/protocol_link.dart';
import '../protocol/models/protocol_records.dart';
import '../protocol/models/protocol_wallet_fit.dart';
import '../protocol/protocol_paste_card.dart';
import '../wallet_picker/models/wallet_summary.dart';
import 'liquid_network_switch.dart';

/// Where the connector is written down, for anyone who wants the protocol.
const String kProtocolGuideUrl =
    'https://github.com/0xB4LdW1n/TemplarWallet/blob/main/docs/guides/PROTOCOL_CONNECTOR.md';

class ProtocolSection extends StatefulWidget {
  const ProtocolSection({super.key, this.bridge});

  /// Injectable for tests, like [WalletInfoScreen]; the app passes nothing
  /// and gets the process-wide bridge.
  final WalletBridge? bridge;

  @override
  State<ProtocolSection> createState() => _ProtocolSectionState();
}

class _ProtocolSectionState extends State<ProtocolSection> {
  WalletBridge get _bridge => widget.bridge ?? walletBridge;

  LiquidNetworkInfo? _info;
  List<ProtocolConnectedSite> _sites = const [];
  List<ProtocolSignRecord> _history = const [];
  List<WalletSummary> _wallets = const [];
  String? _preferredId;

  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    LiquidNetworkInfo? info;
    String? error;
    try {
      info = await _bridge.getLiquidNetwork();
    } catch (e) {
      error = liquidNetworkErrorText(e);
    }
    List<WalletSummary> wallets = const [];
    try {
      wallets = await _bridge.listWallets();
    } catch (_) {
      // No wallet list, no preference picker — never a broken page.
    }
    final store = ProtocolStore.instance;
    final sites = await store.sites();
    final history = await store.history();
    final preferred = await store.preferredWalletId();
    if (!mounted) return;
    setState(() {
      _info = info;
      _error = error;
      _wallets = wallets;
      _sites = sites;
      _history = history;
      _preferredId = preferred;
      _loading = false;
    });
  }

  // ── Actions ─────────────────────────────────────────────────────────────────

  /// The other network: the card offers the one move that exists.
  String? get _otherNetwork => switch (_info?.shortName) {
        'testnet' => 'regtest',
        'regtest' => 'testnet',
        _ => null,
      };

  Future<void> _changeNetwork() async {
    final info = _info;
    final target = _otherNetwork;
    if (info == null || target == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final done = await switchLiquidNetwork(
        context,
        target: target,
        // Regtest keeps the id the engine already knows, else the stock one.
        // The editable field lives in Network & Sync, one tap away.
        policyAsset: info.policyAsset.isNotEmpty && info.isRegtest
            ? info.policyAsset
            : info.regtestDefaultPolicyAsset,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        if (done != null) _info = done.info;
      });
      if (done != null && done.walletClosed && mounted) {
        context.go(AppRoutes.walletPicker);
      }
    } on LiquidNetworkSwitchError catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    }
  }

  void _openLink(String link) {
    context.go('${AppRoutes.protocol}?link=${Uri.encodeComponent(link)}');
  }

  Future<void> _forget(ProtocolConnectedSite site) async {
    final ok = await showAppDialog<bool>(
      context,
      builder: (ctx) => GlassDialog(
        title: 'Forget ${site.site}?',
        icon: Icons.link_off,
        actions: [
          SecondaryButton(label: 'Cancel', onPressed: () => Navigator.pop(ctx, false)),
          PrimaryButton(label: 'Forget', onPressed: () => Navigator.pop(ctx, true)),
        ],
        child: Text(
          'This removes the record from this device only. ${site.site} keeps '
          'the watch-only descriptor of "${site.walletName}" — it can still '
          'see that wallet\'s Liquid balance and history — until you remove '
          'the wallet on the site itself. Nothing here can revoke it.',
          style: AppTypography.body,
        ),
      ),
    );
    if (ok != true) return;
    await ProtocolStore.instance.forgetSite(site.key);
    final sites = await ProtocolStore.instance.sites();
    if (mounted) setState(() => _sites = sites);
  }

  Future<void> _clearHistory() async {
    final ok = await showAppDialog<bool>(
      context,
      builder: (ctx) => GlassDialog(
        title: 'Clear signing history?',
        icon: Icons.delete_outline,
        actions: [
          SecondaryButton(label: 'Cancel', onPressed: () => Navigator.pop(ctx, false)),
          PrimaryButton(label: 'Clear', onPressed: () => Navigator.pop(ctx, true)),
        ],
        child: Text(
          'Removes this device\'s list of signing requests. The loans and the '
          'transactions themselves are unaffected — they live on the chain and '
          'on the site.',
          style: AppTypography.body,
        ),
      ),
    );
    if (ok != true) return;
    await ProtocolStore.instance.clearHistory();
    if (mounted) setState(() => _history = const []);
  }

  Future<void> _setPreferred(String? id) async {
    await ProtocolStore.instance.setPreferredWalletId(id);
    if (mounted) setState(() => _preferredId = id);
  }

  // ── UI ──────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final phone = AppLayout.isPhone(context);
    if (_loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.xl),
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!phone) const PageHeader(title: 'Templar Protocol'),
        _status(),
        const SizedBox(height: AppSpacing.lg),
        ProtocolPasteCard(
          title: 'Open a request',
          subtitle: 'A Templar Protocol site normally opens Templar by itself when you '
              'click its link. This is the fallback: paste the templar:// link, or '
              'scan the QR the loan page shows.',
          onOpen: _openLink,
        ),
        const SizedBox(height: AppSpacing.lg),
        _connectedSites(),
        const SizedBox(height: AppSpacing.lg),
        _signingHistory(),
        const SizedBox(height: AppSpacing.lg),
        _preferences(),
        const SizedBox(height: AppSpacing.lg),
        _howItWorks(),
      ],
    );
  }

  Widget _status() {
    final s = AppScheme.of(context);
    final phone = AppLayout.isPhone(context);
    final info = _info;
    final locked = info?.envLocked ?? false;
    final target = _otherNetwork;
    return FormCard(
      title: 'Status',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_error != null) ...[
            DangerBanner(message: _error!),
            const SizedBox(height: AppSpacing.lg),
          ],
          if (info == null)
            Text(
              'The wallet engine did not answer, so there is nothing to be '
              'ready for yet.',
              style: AppTypography.caption.copyWith(color: s.inkSecondary),
            )
          else ...[
            Row(
              children: [
                Icon(Icons.check_circle_outline, size: 18, color: s.liquid),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    'Ready for ${protocolNetworkLabel(info.network)}'
                    '${info.isRegtest ? ' · policy asset ${protocolShortAsset(info.policyAsset)}' : ''}',
                    style: AppTypography.body.copyWith(color: s.ink),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Requests from a site on another chain are refused, and the '
              'screen offers the switch. Chain: ${info.backendDescription}.',
              style: AppTypography.caption.copyWith(color: s.inkSecondary),
            ),
            const SizedBox(height: AppSpacing.lg),
            if (locked)
              const InfoBanner(
                message: 'TEMPLAR_LIQUID_NETWORK fixes the network for this run '
                    'of the app. Unset the variable to change it here.',
              )
            else if (target != null) ...[
              SecondaryButton(
                key: const Key('protocol-change-network'),
                label: 'Change network',
                icon: Icons.swap_horiz,
                isLoading: _busy,
                isFullWidth: phone,
                onPressed: _busy ? null : _changeNetwork,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Switches to Liquid $target and closes the open wallet. To pick '
                'another regtest asset id, use Network & Sync.',
                style: AppTypography.caption.copyWith(color: s.inkFaint),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _connectedSites() {
    final s = AppScheme.of(context);
    return FormCard(
      title: 'Connected sites',
      subtitle: 'Sites holding a watch-only view of one of your wallets. They '
          'can see that wallet\'s Liquid balance and history and build loan '
          'transactions for it; they cannot spend.',
      child: _sites.isEmpty
          ? Text(
              'No site has been connected from this device.',
              style: AppTypography.caption.copyWith(color: s.inkSecondary),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < _sites.length; i++) ...[
                  if (i > 0) const Divider(height: AppSpacing.lg),
                  _SiteRow(site: _sites[i], onForget: () => _forget(_sites[i])),
                ],
              ],
            ),
    );
  }

  Widget _signingHistory() {
    final s = AppScheme.of(context);
    return FormCard(
      title: 'Signing history',
      subtitle: 'The last ${ProtocolStore.historyLimit} requests answered from '
          'this device. What was signed is not kept here — no transaction, no '
          'amounts — only that it happened and how it ended.',
      trailing: _history.isEmpty
          ? null
          : GhostButton(
              key: const Key('protocol-clear-history'),
              label: 'Clear history',
              onPressed: _clearHistory,
            ),
      child: _history.isEmpty
          ? Text(
              'Nothing signed yet.',
              style: AppTypography.caption.copyWith(color: s.inkSecondary),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < _history.length; i++) ...[
                  if (i > 0) const Divider(height: AppSpacing.lg),
                  _HistoryRow(record: _history[i]),
                ],
              ],
            ),
    );
  }

  Widget _preferences() {
    final s = AppScheme.of(context);
    final usable =
        _wallets.where((w) => protocolWalletFits(w, connect: true)).toList();
    return FormCard(
      title: 'Preferred wallet for Templar Protocol requests',
      subtitle: 'The wallet a signing request is answered with, and the one '
          'offered first when a site asks to connect. Every request still asks '
          'for your app password and the confirmation — this only saves the '
          'picking.',
      child: usable.isEmpty
          ? Text(
              'No wallet qualifies yet: Templar Protocol needs a software wallet with '
              'Liquid enabled.',
              style: AppTypography.caption.copyWith(color: s.inkSecondary),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _PreferenceRow(
                  label: 'No preference',
                  detail: 'Ask every time, or use the open wallet',
                  selected: _preferredId == null,
                  onTap: () => _setPreferred(null),
                ),
                for (final w in usable)
                  _PreferenceRow(
                    label: w.name,
                    detail: '${w.displayType} · ${w.networksLabel}'
                        '${w.masterFingerprint != null ? ' · ${w.masterFingerprint}' : ''}',
                    selected: _preferredId == w.id,
                    onTap: () => _setPreferred(w.id),
                  ),
              ],
            ),
    );
  }

  Widget _howItWorks() {
    final s = AppScheme.of(context);
    return FormCard(
      title: 'How it works',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _Step(
            n: 1,
            title: 'Connect shares a view, never a key',
            body: 'The site receives the watch-only descriptor of the wallet you '
                'pick, its loan escrow key and one receive address. No secret '
                'leaves this device.',
          ),
          const SizedBox(height: AppSpacing.md),
          const _Step(
            n: 2,
            title: 'Sign shows both readings',
            body: 'A signing request puts the site\'s summary next to the '
                'wallet\'s own reading of the transaction. You sign after '
                'comparing them; the signature goes to the site, which '
                'broadcasts once every party has signed. Templar never '
                'broadcasts a loan transaction and never stores its PSET.',
          ),
          const SizedBox(height: AppSpacing.md),
          const _Step(
            n: 3,
            title: 'The escrow key is its own account',
            body: 'It lives at m/2121\'/1\'/0\', below your seed and apart from '
                'the keys that hold your coins, so a loan contract can never '
                'name a spending key of yours.',
          ),
          const SizedBox(height: AppSpacing.lg),
          HoverRow(
            onTap: () => launchUrl(Uri.parse(kProtocolGuideUrl),
                mode: LaunchMode.externalApplication),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              child: Row(
                children: [
                  Icon(Icons.menu_book_outlined, size: 18, color: s.inkSecondary),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Text(
                      'docs/guides/PROTOCOL_CONNECTOR.md',
                      style: AppTypography.body.copyWith(color: s.accent),
                    ),
                  ),
                  const Icon(Icons.open_in_new, size: 16),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Rows ──────────────────────────────────────────────────────────────────────

class _SiteRow extends StatelessWidget {
  const _SiteRow({required this.site, required this.onForget});
  final ProtocolConnectedSite site;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final phone = AppLayout.isPhone(context);
    final shared = [
      if (site.sharedDescriptor) 'watch-only descriptor',
      if (site.escrowFingerprint.isNotEmpty)
        'escrow key ${site.escrowFingerprint}',
      if (site.receiveAddress.isNotEmpty) 'one receive address',
    ].join(' · ');

    final head = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(site.site, style: AppTypography.body),
              const SizedBox(height: 2),
              Text(
                '${site.origin} · ${protocolNetworkLabel(site.network)}',
                style: AppTypography.caption.copyWith(color: s.inkSecondary),
              ),
            ],
          ),
        ),
        if (!phone)
          GhostButton(
            label: 'Forget',
            icon: Icons.link_off,
            onPressed: onForget,
          ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        head,
        const SizedBox(height: AppSpacing.sm),
        KvRow(label: 'Wallet', value: site.walletName, labelWidth: 96),
        KvRow(
          label: 'Connected',
          value: relativeTimeShort(site.connectedAt.toLocal()),
          labelWidth: 96,
        ),
        if (shared.isNotEmpty)
          KvRow(label: 'Shared', value: shared, labelWidth: 96),
        if (site.receiveAddress.isNotEmpty)
          KvRow(label: 'Address', value: site.receiveAddress, labelWidth: 96),
        if (phone) ...[
          const SizedBox(height: AppSpacing.sm),
          SecondaryButton(
            label: 'Forget',
            icon: Icons.link_off,
            isFullWidth: true,
            onPressed: onForget,
          ),
        ],
      ],
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.record});
  final ProtocolSignRecord record;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final colour = switch (record.outcome) {
      ProtocolSignOutcome.signed => s.liquid,
      ProtocolSignOutcome.refused => s.inkFaint,
      ProtocolSignOutcome.expired => s.inkFaint,
      ProtocolSignOutcome.failed => s.danger,
    };
    final title = [
      if (record.loanRef.isNotEmpty) record.loanRef,
      if (record.action.isNotEmpty) _actionLabel(record.action),
    ].join(' · ');

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title.isEmpty ? 'Signing request' : title,
                style: AppTypography.body,
              ),
              const SizedBox(height: 2),
              Text(
                '${record.site}'
                '${record.walletName.isNotEmpty ? ' · ${record.walletName}' : ''}'
                ' · ${relativeTimeShort(record.at.toLocal())}',
                style: AppTypography.caption.copyWith(color: s.inkSecondary),
              ),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        TagChip(label: record.outcome.label, color: colour),
      ],
    );
  }

  static String _actionLabel(String action) => switch (action) {
        'origination' => 'Loan origination',
        'repayment' => 'Repayment',
        'installment' => 'Installment',
        'default' => 'Default settlement',
        'liquidation' => 'Liquidation',
        'swap' => 'Swap',
        final other => other,
      };
}

class _PreferenceRow extends StatelessWidget {
  const _PreferenceRow({
    required this.label,
    required this.detail,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final String detail;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return HoverRow(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Row(
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 18,
              color: selected ? s.accent : s.inkFaint,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: AppTypography.body),
                  Text(detail,
                      style: AppTypography.caption
                          .copyWith(color: s.inkSecondary)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.n, required this.title, required this.body});
  final int n;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: s.accent.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Text('$n',
              style: AppTypography.caption.copyWith(
                color: s.accent,
                fontWeight: FontWeight.w700,
              )),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AppTypography.body),
              const SizedBox(height: 2),
              Text(body,
                  style: AppTypography.caption.copyWith(color: s.inkSecondary)),
            ],
          ),
        ),
      ],
    );
  }
}
