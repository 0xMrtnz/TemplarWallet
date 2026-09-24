import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../app/app_state.dart';
import '../../app/routes.dart';
import '../../bridge/bridge_provider.dart';
import '../../features/dashboard/models/dashboard_data.dart';
import '../../features/liquid/models/issue_result.dart';
import '../../services/asset_registry_service.dart';
import '../../services/issued_asset_store.dart';
import '../../shared/widgets/banners.dart';
import '../../shared/widgets/buttons.dart';
import '../../shared/widgets/cards.dart';
import '../../shared/widgets/code_box.dart';
import '../../shared/widgets/hybrid_kit.dart';
import '../../shared/widgets/page_header.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';

class ReissueScreen extends StatefulWidget {
  const ReissueScreen({super.key});

  @override
  State<ReissueScreen> createState() => _ReissueScreenState();
}

class _ReissueScreenState extends State<ReissueScreen> {
  final _bridge = walletBridge;

  List<AssetBalance> _reissuableAssets = [];
  /// Asset IDs whose reissuance token was recorded at issuance on this
  /// device. Assets outside this set may still be reissuable (wallet restored
  /// elsewhere, token received by transfer) — the store is device-local, so
  /// it annotates rather than gates.
  Set<String> _tokenRecorded = {};
  AssetBalance? _selectedAsset;
  bool _loadingAssets = true;

  final _amountController = TextEditingController();
  bool _reviewing = false;
  bool _submitting = false;
  String? _error;
  /// Raw bridge error kept as secondary detail when [_error] holds a
  /// human-readable translation of it.
  String? _errorDetail;
  IssueResult? _result;

  @override
  void initState() {
    super.initState();
    _loadAssets();
  }

  Future<void> _loadAssets() async {
    final walletId = context.read<AppState>().activeWalletId ?? 'wallet-1';
    try {
      // Reissuing needs the asset's reissuance token. The store only knows
      // about assets issued on THIS device, so use it to rank and annotate —
      // not to gate: a restored wallet or a transferred-in token would
      // otherwise be locked out.
      final issued = await IssuedAssetStore.instance.getIssuedAssets(walletId);
      final recorded =
          issued.values.where((e) => e.tokenId != null).toList();
      final recordedIds = {for (final e in recorded) e.assetId};

      List<AssetBalance> balances = [];
      try {
        final data = await _bridge.getWalletSummary(walletId);
        balances = data.assets;
      } catch (_) {
        // Offline/holdings unavailable — the recorded list still works.
      }

      final reissuable = <AssetBalance>[
        // Assets issued here with a token — shown first.
        for (final entry in recorded)
          balances.firstWhere(
            (a) => a.assetId == entry.assetId,
            orElse: () => AssetBalance(
              assetId: entry.assetId,
              ticker: entry.ticker,
              name: entry.name,
              amount: 0,
              displayAmount: '0',
            ),
          ),
        // Other held Liquid assets — reissuable only if this wallet holds
        // their token; attempting without it fails cleanly at signing.
        ...balances.where((a) =>
            a.ticker != 'BTC' &&
            a.ticker != 'LBTC' &&
            !recordedIds.contains(a.assetId)),
      ];
      if (mounted) {
        setState(() {
          _reissuableAssets = reissuable;
          _tokenRecorded = recordedIds;
          _selectedAsset = reissuable.isNotEmpty ? reissuable.first : null;
          _loadingAssets = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loadingAssets = false);
    }
  }

  void _onReview() {
    final asset = _selectedAsset;
    if (asset == null) {
      setState(() => _error = 'Select an asset.');
      return;
    }
    final amount = int.tryParse(_amountController.text.trim());
    if (amount == null || amount <= 0) {
      setState(() => _error = 'Enter an amount greater than 0.');
      return;
    }
    setState(() {
      _error = null;
      _errorDetail = null;
      _reviewing = true;
    });
  }

  /// Translates known LWK reissuance failures into a human sentence, or
  /// returns null when the raw error should be shown as-is.
  ///
  /// "Missing issuance" — this wallet has never seen the asset's issuance tx,
  /// so it cannot hold its reissuance token. "Insufficient funds" during a
  /// reissue whose token was not recorded at issuance on this device almost
  /// always means the token UTXO is absent (LWK raises the same error when it
  /// fails to find a token input to spend).
  String? _friendlyReissueError(String raw, String assetId) {
    final lower = raw.toLowerCase();
    final tokenMissing = lower.contains('missing issuance') ||
        (lower.contains('insufficient funds') &&
            !_tokenRecorded.contains(assetId));
    if (tokenMissing) {
      return 'This wallet does not hold the reissuance token for this asset '
          '— it cannot mint more supply.';
    }
    return null;
  }

  Future<void> _onConfirmReissue() async {
    final asset = _selectedAsset;
    if (asset == null) return;
    final amount = int.tryParse(_amountController.text.trim()) ?? 0;
    if (amount <= 0) return;

    setState(() { _error = null; _errorDetail = null; _submitting = true; });

    try {
      final walletId = context.read<AppState>().activeWalletId ?? 'wallet-1';
      final result = await _bridge.reissueAsset(
        walletId: walletId,
        assetId: asset.assetId,
        amountSats: amount,
      );
      if (mounted) setState(() { _result = result; _submitting = false; });
    } catch (e) {
      final raw = e.toString();
      final friendly = _friendlyReissueError(raw, asset.assetId);
      if (mounted) {
        setState(() {
          _error = friendly ?? raw;
          _errorDetail = friendly != null ? raw : null;
          _submitting = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PageBackground.flat(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: _result != null
                ? _buildResult()
                : _reviewing
                    ? _buildReview()
                    : _buildForm(),
          ),
        ),
      ),
    );
  }

  Widget _buildForm() {
    return ListView(
      padding: EdgeInsets.all(AppSpacing.pagePadding(context)),
      children: [
        PageHeader(
          title: 'Reissue',
          subtitle: 'Mint additional supply of an existing asset',
          actions: [
            GhostButton(
                label: 'Back to Liquid',
                onPressed: () => context.go(AppRoutes.liquid))
          ],
        ),
        const InfoBanner(
            message:
                'Reissuing requires holding the asset\'s reissuance token. '
                'Assets issued from this wallet with a token are listed first.'),
        const SizedBox(height: AppSpacing.xl),
        if (_loadingAssets)
          const Center(child: CircularProgressIndicator())
        else if (_reissuableAssets.isEmpty)
          const InfoBanner(
            title: 'No reissuable assets',
            message:
                'This wallet holds no Liquid assets that could be reissued. Issue an asset with "Create reissuance token" enabled to be able to mint more supply later.',
          )
        else ...[
          FormCard(
            title: 'Asset',
            child: DropdownButtonFormField<String>(
              initialValue: _selectedAsset?.assetId,
              // Phone only: the selected label fills the field and a long
              // asset name ellipsises. Unbounded, "USDt — PEGx USDt Testnet
              // (token not verified)" painted 54 px past the right edge of a
              // phone. The desktop field is wide enough and keeps its arrow
              // beside the text.
              isExpanded: AppLayout.isPhone(context),
              items: _reissuableAssets
                  .map((a) => DropdownMenuItem(
                        value: a.assetId,
                        child: Text(
                          '${AssetRegistryService.instance.displayTicker(a)} — ${AssetRegistryService.instance.displayName(a)}'
                          '${_tokenRecorded.contains(a.assetId) ? '' : '  (token not verified)'}',
                          maxLines: AppLayout.isPhone(context) ? 1 : null,
                          overflow: AppLayout.isPhone(context)
                              ? TextOverflow.ellipsis
                              : null,
                        ),
                      ))
                  .toList(),
              onChanged: (v) => setState(() {
                _selectedAsset =
                    _reissuableAssets.firstWhere((a) => a.assetId == v);
              }),
              decoration: const InputDecoration(hintText: 'Select asset'),
            ),
          ),
          if (_selectedAsset != null) ...[
            const SizedBox(height: AppSpacing.lg),
            SummaryCard(
              rows: [
                (
                  label: 'Current holdings',
                  value: _selectedAsset!.displayAmount,
                  isMono: false
                ),
                (
                  label: 'Base units',
                  value: '${_selectedAsset!.amount}',
                  isMono: true
                ),
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          FormCard(
            title: 'Additional amount',
            child: TextField(
              controller: _amountController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: 'Amount to mint (base units)',
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.md),
            DangerBanner(message: _error!),
          ],
          const SizedBox(height: AppSpacing.xl),
          PrimaryButton(
            label: 'Review reissuance',
            isFullWidth: true,
            onPressed: _onReview,
          ),
        ],
      ],
    );
  }

  Widget _buildReview() {
    final asset = _selectedAsset!;
    final amount = _amountController.text.trim();
    return ListView(
      padding: EdgeInsets.all(AppSpacing.pagePadding(context)),
      children: [
        PageHeader(
          title: 'Confirm Reissuance',
          subtitle: 'Review the details before broadcasting',
          actions: [
            GhostButton(
                label: 'Back to Liquid',
                onPressed: () => context.go(AppRoutes.liquid))
          ],
        ),
        const WarningBanner(
          title: 'Supply increase',
          message:
              'Confirming will mint additional units on-chain and permanently increase the total supply of this asset.',
        ),
        if (!_tokenRecorded.contains(asset.assetId)) ...[
          const SizedBox(height: AppSpacing.md),
          const InfoBanner(
            message:
                'This wallet has no record of holding the reissuance token for '
                'this asset. If the token is not in this wallet, signing will '
                'fail — no funds are at risk.',
          ),
        ],
        const SizedBox(height: AppSpacing.xl),
        SummaryCard(
          title: 'Reissuance summary',
          rows: [
            (label: 'Operation', value: 'Reissue', isMono: false),
            (
              label: 'Asset',
              value:
                  '${AssetRegistryService.instance.displayTicker(asset)} — ${AssetRegistryService.instance.displayName(asset)}',
              isMono: false
            ),
            (label: 'Asset ID', value: asset.assetId, isMono: true),
            (label: 'Amount to mint', value: '$amount base units', isMono: false),
            (
              label: 'Resulting action',
              value: 'Total supply increases by $amount base units',
              isMono: false
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: AppSpacing.md),
          DangerBanner(
            message: _error!,
            action: _errorDetail == null
                ? null
                : Text(_errorDetail!, style: AppTypography.caption),
          ),
        ],
        const SizedBox(height: AppSpacing.xl),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            GhostButton(
              label: 'Back',
              onPressed: () => setState(() => _reviewing = false),
            ),
            const SizedBox(width: AppSpacing.md),
            if (_submitting)
              Row(children: [
                const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: AppSpacing.md),
                Text('Broadcasting…', style: AppTypography.caption),
              ])
            else
              PrimaryButton(
                label: 'Confirm & Reissue',
                onPressed: _onConfirmReissue,
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildResult() {
    final result = _result!;
    return ListView(
      padding: EdgeInsets.all(AppSpacing.pagePadding(context)),
      children: [
        PageHeader(
          title: 'Reissued',
          subtitle: 'Additional supply minted successfully',
          actions: [
            GhostButton(
                label: 'Back to Liquid',
                onPressed: () => context.go(AppRoutes.liquid))
          ],
        ),
        const InfoBanner(message: 'Reissuance transaction broadcast on-chain.'),
        const SizedBox(height: AppSpacing.xl),
        SectionCard(
          title: 'Result',
          child: Column(
            children: [
              CodeBox(label: 'Asset ID', value: result.assetId),
              const SizedBox(height: AppSpacing.lg),
              CodeBox(label: 'TxID', value: result.txid),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        PrimaryButton(
          label: 'Done',
          isFullWidth: true,
          onPressed: () => context.go(AppRoutes.liquid),
        ),
      ],
    );
  }
}
