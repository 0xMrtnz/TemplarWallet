// Maker side of a LiquiDEX v0 swap: pick ONE Liquid coin to offer (v0 always
// offers the whole coin), choose what you want in return, review, sign and
// publish the proposal.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../app/app_state.dart';
import '../../bridge/bridge_provider.dart';
import '../../features/dashboard/models/dashboard_data.dart';
import '../../features/utxos/models/utxo.dart';
import '../../services/asset_registry_service.dart';
import '../../shared/widgets/asset_logo.dart';
import '../../shared/widgets/banners.dart';
import '../../shared/widgets/buttons.dart';
import '../../shared/widgets/cards.dart';
import '../../shared/widgets/code_box.dart';
import '../../shared/widgets/hybrid_kit.dart';
import '../../shared/widgets/step_flow_scaffold.dart';
import '../../shared/widgets/utxo_views.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import 'models/swap_offer.dart';
import 'take_flow.dart' show swapError;
import '../../shared/widgets/glass_dialog.dart';

/// Push the make-offer wizard. Resolves to the created [MyOffer], or null
/// when the user backed out.
Future<MyOffer?> openMakeOfferFlow(BuildContext context) {
  // Root navigator on a phone: the wizard must cover the shell (header and
  // carousel), not render inside the shell's page slot.
  return Navigator.of(context, rootNavigator: AppLayout.isPhone(context))
      .push<MyOffer>(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => const MakeOfferFlowScreen(),
  ));
}

class MakeOfferFlowScreen extends StatefulWidget {
  const MakeOfferFlowScreen({super.key});

  @override
  State<MakeOfferFlowScreen> createState() => _MakeOfferFlowScreenState();
}

class _MakeOfferFlowScreenState extends State<MakeOfferFlowScreen> {
  final _bridge = walletBridge;

  /// 0 = Offer (pick coin), 1 = Want, 2 = Review & publish.
  int _step = 0;
  String? _error;

  // Step 1: offer.
  List<Utxo> _utxos = [];
  bool _loadingUtxos = true;
  bool _exactCoinOpen = false;
  final _exactAmountCtrl = TextEditingController();
  String? _exactAssetId;
  bool _preparing = false;

  /// Set after `swap_make_prepare` broadcast, cleared once coins reload.
  bool _coinCreated = false;

  // Step 2: want.
  List<AssetBalance> _assets = [];
  String? _wantAssetId;
  final _customAssetCtrl = TextEditingController();
  final _wantAmountCtrl = TextEditingController();
  static const _customAssetKey = '__custom__';

  // Step 3: publish.
  bool _publishing = false;

  String? get _walletId => context.read<AppState>().activeWalletId;

  @override
  void initState() {
    super.initState();
    _loadUtxos();
    _loadAssets();
  }

  @override
  void dispose() {
    _exactAmountCtrl.dispose();
    _customAssetCtrl.dispose();
    _wantAmountCtrl.dispose();
    super.dispose();
  }

  // ── data ────────────────────────────────────────────────────────────────────

  Future<void> _loadUtxos() async {
    final walletId = _walletId;
    if (walletId == null) return;
    setState(() => _loadingUtxos = true);
    try {
      final all = await _bridge.listUtxos(walletId, 'Liquid');
      // Spendable coins, including unconfirmed ones — the "create exact coin"
      // self-send lands as unconfirmed and must show up here right away (LWK
      // can spend unconfirmed outputs).
      final spendable = all
          .where((u) =>
              u.state == UtxoState.available ||
              u.state == UtxoState.dusty ||
              u.state == UtxoState.unconfirmed)
          .toList();
      if (!mounted) return;
      setState(() {
        _utxos = spendable;
        _loadingUtxos = false;
        _coinCreated = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingUtxos = false;
        _error = swapError(e);
      });
    }
  }

  Future<void> _loadAssets() async {
    final walletId = _walletId;
    if (walletId == null) return;
    try {
      final data = await _bridge.getWalletSummary(walletId);
      if (!mounted) return;
      setState(() {
        // Liquid assets only — L-BTC first, then tokens.
        _assets = [
          ...data.assets.where((a) => a.ticker == 'LBTC'),
          ...data.assets
              .where((a) => a.ticker != 'BTC' && a.ticker != 'LBTC'),
        ];
      });
    } catch (_) {
      // Free-form asset id entry still works without the summary.
    }
  }

  // ── derived ─────────────────────────────────────────────────────────────────

  Utxo? get _selectedUtxo => _utxos.where((u) => u.isSelected).firstOrNull;

  bool get _wantIsCustom => _wantAssetId == _customAssetKey;

  AssetBalance? get _wantAsset => _wantIsCustom
      ? null
      : _assets.where((a) => a.assetId == _wantAssetId).firstOrNull;

  String get _wantAssetIdResolved =>
      _wantIsCustom ? _customAssetCtrl.text.trim() : (_wantAssetId ?? '');

  String get _wantTicker {
    final a = _wantAsset;
    if (a == null) return 'units';
    return a.ticker == 'LBTC'
        ? 'L-BTC'
        : AssetRegistryService.instance.displayTicker(a);
  }

  bool get _wantIsLbtc => _wantAsset?.ticker == 'LBTC';

  /// L-BTC entered in BTC (8 decimals); tokens and raw asset ids in base units.
  int? get _wantAmountSats {
    final v = double.tryParse(_wantAmountCtrl.text.trim());
    // isFinite: tryParse accepts "NaN"/"Infinity", and .round() throws on them.
    if (v == null || !v.isFinite || v <= 0) return null;
    return _wantIsLbtc ? (v * 1e8).round() : v.round();
  }

  String get _wantAmountDisplay {
    final sats = _wantAmountSats ?? 0;
    return _wantIsLbtc
        ? '${(sats / 1e8).toStringAsFixed(8)} L-BTC'
        : '$sats $_wantTicker';
  }

  bool get _canContinue => switch (_step) {
        0 => _selectedUtxo != null,
        1 => _wantAssetIdResolved.length == 64 && _wantAmountSats != null,
        _ => !_publishing,
      };

  // ── actions ─────────────────────────────────────────────────────────────────

  void _toggleUtxo(int i) {
    setState(() {
      final turnOn = !_utxos[i].isSelected;
      // Single-select: the v0 proposal spends exactly one coin.
      for (var n = 0; n < _utxos.length; n++) {
        _utxos[n] = _utxos[n].copyWith(isSelected: n == i && turnOn);
      }
    });
  }

  Future<void> _createExactCoin() async {
    final walletId = _walletId;
    final assetId = _exactAssetId;
    if (walletId == null || assetId == null) return;
    final asset = _assets.where((a) => a.assetId == assetId).firstOrNull;
    final isLbtc = asset?.ticker == 'LBTC';
    final v = double.tryParse(_exactAmountCtrl.text.trim());
    if (v == null || !v.isFinite || v <= 0) {
      setState(() => _error = 'Enter a valid amount for the new coin.');
      return;
    }
    final sats = isLbtc ? (v * 1e8).round() : v.round();

    setState(() {
      _preparing = true;
      _error = null;
    });
    try {
      await _bridge.swapMakePrepare(walletId, assetId, sats);
      if (!mounted) return;
      setState(() {
        _preparing = false;
        _coinCreated = true;
        _exactCoinOpen = false;
        _exactAmountCtrl.clear();
      });
      // The new coin only appears after a sync — run it now so the picker
      // refreshes without the user leaving the wizard.
      final appState = context.read<AppState>();
      appState.setSyncState(SyncState.syncing);
      try {
        final outcomes = await _bridge.syncWallet(walletId);
        appState.applySyncOutcomes(outcomes);
      } catch (e) {
        debugPrint('[swap] post-prepare sync failed: $e');
        appState.setSyncState(SyncState.error);
        appState.bumpSync();
      }
      if (mounted) await _loadUtxos();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _preparing = false;
        _error = swapError(e);
      });
    }
  }

  Future<void> _publish() async {
    final walletId = _walletId;
    final utxo = _selectedUtxo;
    final wantAssetId = _wantAssetIdResolved;
    final wantSats = _wantAmountSats;
    if (walletId == null || utxo == null || wantSats == null) return;

    setState(() {
      _publishing = true;
      _error = null;
    });
    try {
      final offer =
          await _bridge.swapMake(walletId, utxo.outpoint, wantAssetId, wantSats);
      if (!mounted) return;
      setState(() => _publishing = false);
      await showAppDialog<void>(context,
        barrierDismissible: false,
        builder: (_) => _OfferCreatedDialog(offer: offer),
      );
      if (mounted) Navigator.of(context).pop(offer);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _publishing = false;
        _error = swapError(e);
      });
    }
  }

  // ── build ───────────────────────────────────────────────────────────────────

  static const _titles = ['Offer', 'Want', 'Review & publish'];
  static const _subtitles = [
    'Pick the coin you are offering',
    'What do you want in return?',
    'Sign the proposal and share it',
  ];

  @override
  Widget build(BuildContext context) {
    return StepFlowScaffold(
      currentStep: _step + 1,
      totalSteps: 3,
      title: 'Make offer — ${_titles[_step]}',
      subtitle: _subtitles[_step],
      maxWidth: 760,
      onBack: _step == 0
          ? null
          : () => setState(() {
                _step -= 1;
                _error = null;
              }),
      onCancel: _publishing ? null : () => Navigator.of(context).pop(),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ...switch (_step) {
            0 => _offerStep(),
            1 => _wantStep(),
            _ => _reviewStep(),
          },
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.lg),
            DangerBanner(message: _error!),
          ],
        ],
      ),
      actions: Row(
        children: [
          GhostButton(
            label: 'Cancel',
            onPressed: _publishing ? null : () => Navigator.of(context).pop(),
          ),
          const Spacer(),
          if (_step < 2)
            PrimaryButton(
              label: 'Continue',
              icon: Icons.arrow_forward,
              onPressed: _canContinue
                  ? () => setState(() {
                        _step += 1;
                        _error = null;
                      })
                  : null,
            )
          else
            PrimaryButton(
              label: _publishing ? 'Signing…' : 'Sign & create offer',
              icon: Icons.storefront_outlined,
              onPressed: _canContinue ? _publish : null,
            ),
        ],
      ),
    );
  }

  // ── Step 1: offer ───────────────────────────────────────────────────────────

  List<Widget> _offerStep() {
    final s = AppScheme.of(context);
    return [
      const InfoBanner(
        message: 'LiquiDEX v0 offers the whole coin — the selected UTXO\'s '
            'full amount is what the taker receives. Pick exactly one coin.',
      ),
      const SizedBox(height: AppSpacing.lg),
      FormCard(
        title: 'Your Liquid coins',
        subtitle: 'Tap the coin to offer',
        child: _loadingUtxos
            ? const Padding(
                padding: EdgeInsets.all(AppSpacing.xl),
                child: Center(child: CircularProgressIndicator()),
              )
            : _utxos.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: Text('No spendable Liquid coins found.',
                        style: AppTypography.caption),
                  )
                // Pending stays pickable here: LWK spends unconfirmed
                // outputs, and the exact coin just created is one.
                : UtxoPicker(
                    utxos: _utxos,
                    onToggle: _toggleUtxo,
                    allowPending: true,
                  ),
      ),
      if (_coinCreated) ...[
        const SizedBox(height: AppSpacing.md),
        const InfoBanner(
          message: 'Coin created — once the sync finishes it appears above; '
              'pick it to offer the exact amount.',
        ),
      ],
      const SizedBox(height: AppSpacing.lg),
      // Escape hatch: v0 cannot offer part of a coin, so mint an exact one.
      Row(
        children: [
          Expanded(
            child: Text(
              'Want to offer a different amount than any coin you hold?',
              style: AppTypography.caption.copyWith(color: s.inkSecondary),
            ),
          ),
          GhostButton(
            label: _exactCoinOpen ? 'Hide' : 'Create exact coin',
            icon: Icons.call_split,
            onPressed: _preparing
                ? null
                : () => setState(() => _exactCoinOpen = !_exactCoinOpen),
          ),
        ],
      ),
      if (_exactCoinOpen) ...[
        const SizedBox(height: AppSpacing.sm),
        FormCard(
          title: 'Create exact coin',
          subtitle: 'A self-send that splits off a coin of exactly this '
              'amount (a small network fee applies)',
          child: Column(
            children: [
              DropdownButtonFormField<String>(
                initialValue: _exactAssetId,
                decoration: const InputDecoration(labelText: 'Asset'),
                items: [
                  for (final a in _assets)
                    DropdownMenuItem(
                      value: a.assetId,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AssetLogo(ticker: a.ticker, size: 18),
                          const SizedBox(width: AppSpacing.sm),
                          Text(a.ticker == 'LBTC'
                              ? 'L-BTC'
                              : AssetRegistryService.instance
                                  .displayTicker(a)),
                          const SizedBox(width: AppSpacing.sm),
                          Text(a.displayAmount, style: AppTypography.caption),
                        ],
                      ),
                    ),
                ],
                onChanged: (id) => setState(() => _exactAssetId = id),
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: _exactAmountCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                style: AppTypography.numeric,
                decoration: InputDecoration(
                  labelText: 'Amount',
                  hintText: _assets
                              .where((a) => a.assetId == _exactAssetId)
                              .firstOrNull
                              ?.ticker ==
                          'LBTC'
                      ? '0.00000000'
                      : '0',
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: AppSpacing.md),
              Align(
                alignment: Alignment.centerRight,
                child: PrimaryButton(
                  label: _preparing ? 'Creating…' : 'Create coin',
                  icon: Icons.add_circle_outline,
                  onPressed: (_exactAssetId != null &&
                          _exactAmountCtrl.text.trim().isNotEmpty &&
                          !_preparing)
                      ? _createExactCoin
                      : null,
                ),
              ),
            ],
          ),
        ),
      ],
    ];
  }

  // ── Step 2: want ────────────────────────────────────────────────────────────

  List<Widget> _wantStep() {
    final s = AppScheme.of(context);
    return [
      FormCard(
        title: 'Asset you want',
        subtitle: 'One of this wallet\'s known assets, or any asset id',
        child: Column(
          children: [
            DropdownButtonFormField<String>(
              initialValue: _wantAssetId,
              decoration: const InputDecoration(labelText: 'Asset'),
              items: [
                for (final a in _assets)
                  DropdownMenuItem(
                    value: a.assetId,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AssetLogo(ticker: a.ticker, size: 18),
                        const SizedBox(width: AppSpacing.sm),
                        Text(a.ticker == 'LBTC'
                            ? 'L-BTC'
                            : AssetRegistryService.instance.displayTicker(a)),
                      ],
                    ),
                  ),
                const DropdownMenuItem(
                  value: _customAssetKey,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.edit_outlined, size: 16),
                      SizedBox(width: AppSpacing.sm),
                      Text('Other asset id…'),
                    ],
                  ),
                ),
              ],
              onChanged: (id) => setState(() {
                _wantAssetId = id;
                _wantAmountCtrl.clear();
              }),
            ),
            if (_wantIsCustom) ...[
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: _customAssetCtrl,
                style: AppTypography.mono,
                decoration: const InputDecoration(
                  labelText: 'Asset id',
                  hintText: '64-character hex asset id',
                ),
                onChanged: (_) => setState(() {}),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _wantAmountCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              style: AppTypography.numeric,
              decoration: InputDecoration(
                labelText: 'Amount',
                hintText: _wantIsLbtc ? '0.00000000' : '0',
                suffixText: _wantTicker,
              ),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
      ),
      const SizedBox(height: AppSpacing.md),
      Text(
        _wantIsLbtc
            ? 'L-BTC amounts are entered in L-BTC (8 decimals).'
            : 'Token amounts are entered in base units (satoshi-like).',
        style: AppTypography.caption.copyWith(color: s.inkSecondary),
      ),
      if (_wantAssetIdResolved.isNotEmpty &&
          _wantAssetIdResolved.length != 64) ...[
        const SizedBox(height: AppSpacing.md),
        const WarningBanner(
          message: 'A Liquid asset id is 64 hex characters — check the id.',
        ),
      ],
    ];
  }

  // ── Step 3: review ──────────────────────────────────────────────────────────

  List<Widget> _reviewStep() {
    final s = AppScheme.of(context);
    final utxo = _selectedUtxo;
    if (utxo == null) return [const SizedBox.shrink()];
    return [
      RailPanel(
        title: 'Your offer',
        rail: s.liquid,
        child: Column(
          children: [
            Row(
              children: [
                AssetLogo(ticker: utxo.ticker ?? 'LBTC', size: 22),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text('You offer (whole coin)',
                      style:
                          AppTypography.body.copyWith(color: s.inkSecondary)),
                ),
                Text(
                  utxo.displayAmount,
                  style: AppTypography.numericLarge
                      .copyWith(fontSize: 18, color: AppColors.accent),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                AssetLogo(ticker: _wantAsset?.ticker ?? '?', size: 22),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text('You want',
                      style:
                          AppTypography.body.copyWith(color: s.inkSecondary)),
                ),
                Text(_wantAmountDisplay,
                    style: AppTypography.numericSmall.copyWith(color: s.ink)),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: AppSpacing.md),
      DataWell(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            KvRow(label: 'Coin', value: utxo.outpoint),
            KvRow(label: 'Want asset', value: _wantAssetIdResolved),
          ],
        ),
      ),
      const SizedBox(height: AppSpacing.lg),
      const InfoBanner(
        message: 'Signing creates a standing proposal: it stays valid until '
            'you spend (or cancel) the offered coin, and anyone holding it '
            'can complete the swap at these exact terms. No fee is paid now — '
            'the taker pays the network fee.',
      ),
    ];
  }
}

// ── Offer created dialog ──────────────────────────────────────────────────────

class _OfferCreatedDialog extends StatelessWidget {
  const _OfferCreatedDialog({required this.offer});

  final MyOffer offer;

  /// QR only for compact proposals — beyond this the QR is unscannable.
  static const _qrMaxLen = 1200;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return AppDialog(
      title: Row(
        children: [
          Icon(Icons.storefront_outlined, color: AppColors.accent, size: 20),
          const SizedBox(width: AppSpacing.sm),
          const Text('Offer created'),
        ],
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${offer.offers.displayAmount} ${offer.offers.ticker} → '
                '${offer.wants.displayAmount} ${offer.wants.ticker}',
                textAlign: TextAlign.center,
                style: AppTypography.numericSmall
                    .copyWith(color: s.ink, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: AppSpacing.md),
              CodeBox(value: offer.proposalJson, label: 'Proposal (v0)'),
              if (offer.proposalJson.length < _qrMaxLen) ...[
                const SizedBox(height: AppSpacing.md),
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius:
                          BorderRadius.circular(AppSpacing.radiusSm),
                    ),
                    child: QrImageView(
                      data: offer.proposalJson,
                      version: QrVersions.auto,
                      size: 220,
                      backgroundColor: Colors.white,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.md),
              Text(
                'Share this proposal; it stays valid until you spend the '
                'coin. To publish it on liquidex.it, copy the proposal and '
                'paste it at liquidex.it/proposal.',
                style: AppTypography.caption.copyWith(color: s.inkSecondary),
              ),
            ],
          ),
        ),
      ),
      actions: [
        PrimaryButton(
          label: 'Done',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}
