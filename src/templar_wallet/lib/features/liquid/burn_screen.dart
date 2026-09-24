import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../app/app_state.dart';
import '../../app/routes.dart';
import '../../bridge/bridge_provider.dart';
import '../../features/dashboard/models/dashboard_data.dart';
import '../../services/asset_registry_service.dart';
import '../../shared/widgets/banners.dart';
import '../../shared/widgets/buttons.dart';
import '../../shared/widgets/cards.dart';
import '../../shared/widgets/code_box.dart';
import '../../shared/widgets/hybrid_kit.dart';
import '../../shared/widgets/page_header.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';

class BurnScreen extends StatefulWidget {
  const BurnScreen({super.key});

  @override
  State<BurnScreen> createState() => _BurnScreenState();
}

class _BurnScreenState extends State<BurnScreen> {
  final _bridge = walletBridge;

  List<AssetBalance> _liquidAssets = [];
  AssetBalance? _selectedAsset;
  bool _loadingAssets = true;

  final _amountController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _submitting = false;
  String? _error;
  String? _resultTxid;

  // Confirmation uses the display ticker: on-chain tickers can be raw hex ids,
  // which the user only ever sees resolved through the registry.
  String get _confirmTicker => _selectedAsset == null
      ? ''
      : AssetRegistryService.instance.displayTicker(_selectedAsset!);

  bool get _confirmed =>
      _confirmTicker.isNotEmpty &&
      _confirmController.text.trim() == _confirmTicker;

  @override
  void initState() {
    super.initState();
    _amountController.addListener(() => setState(() {}));
    _confirmController.addListener(() => setState(() {}));
    _loadAssets();
  }

  Future<void> _loadAssets() async {
    final walletId = context.read<AppState>().activeWalletId ?? 'wallet-1';
    try {
      final data = await _bridge.getWalletSummary(walletId);
      final liquid = data.assets.where((a) => a.ticker != 'BTC' && a.ticker != 'LBTC').toList();
      if (mounted) {
        setState(() {
          _liquidAssets = liquid;
          _selectedAsset = liquid.isNotEmpty ? liquid.first : null;
          _loadingAssets = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loadingAssets = false);
    }
  }

  Future<void> _onBurn() async {
    final asset = _selectedAsset;
    if (asset == null) return;
    if (!_confirmed) return;
    final amount = int.tryParse(_amountController.text.trim());
    if (amount == null || amount <= 0) {
      setState(() => _error = 'Enter an amount greater than 0.');
      return;
    }
    if (amount > asset.amount) {
      setState(() => _error =
          'Amount exceeds current holdings (${asset.amount} base units).');
      return;
    }

    setState(() { _error = null; _submitting = true; });

    try {
      final walletId = context.read<AppState>().activeWalletId ?? 'wallet-1';
      final txid = await _bridge.burnAsset(
        walletId: walletId,
        assetId: asset.assetId,
        amountSats: amount,
      );
      if (mounted) setState(() { _resultTxid = txid; _submitting = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _submitting = false; });
    }
  }

  @override
  void dispose() {
    _amountController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PageBackground.flat(child: _resultTxid != null ? _buildResult() : _buildForm()),
    );
  }

  Widget _buildForm() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          padding: EdgeInsets.all(AppSpacing.pagePadding(context)),
          children: [
            PageHeader(
              title: 'Burn Asset',
              subtitle: 'Permanently destroy token supply',
              actions: [
                GhostButton(
                    label: 'Back to Liquid',
                    onPressed: () => context.go(AppRoutes.liquid))
              ],
            ),
            const DangerBanner(
              title: 'This action is irreversible',
              message:
                  'Burned tokens are permanently destroyed. The total supply will be permanently reduced. This cannot be undone.',
            ),
            const SizedBox(height: AppSpacing.xl),
            if (_loadingAssets)
              const Center(child: CircularProgressIndicator())
            else ...[
              FormCard(
                title: 'Asset',
                child: _liquidAssets.isEmpty
                    ? Text('No burnable assets found.',
                        style: AppTypography.caption)
                    : DropdownButtonFormField<String>(
                        initialValue: _selectedAsset?.assetId,
                        items: _liquidAssets
                            .map((a) => DropdownMenuItem(
                                  value: a.assetId,
                                  child: Text(
                                      '${AssetRegistryService.instance.displayTicker(a)} — ${AssetRegistryService.instance.displayName(a)}'),
                                ))
                            .toList(),
                        onChanged: (v) => setState(() {
                          _selectedAsset = _liquidAssets
                              .firstWhere((a) => a.assetId == v);
                          _confirmController.clear();
                        }),
                        decoration:
                            const InputDecoration(hintText: 'Select asset'),
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
                title: 'Amount to burn',
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _amountController,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly
                        ],
                        decoration: const InputDecoration(
                          labelText: 'Amount to burn (base units)',
                        ),
                      ),
                    ),
                    if (_selectedAsset != null) ...[
                      const SizedBox(width: AppSpacing.md),
                      TextButton(
                        onPressed: () => setState(() =>
                            _amountController.text =
                                '${_selectedAsset!.amount}'),
                        child: const Text('Burn all'),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              FormCard(
                title: 'Confirm destruction',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Type "$_confirmTicker" to confirm',
                      style: AppTypography.body,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    TextField(
                      controller: _confirmController,
                      decoration: InputDecoration(
                        hintText: _confirmTicker,
                        focusedBorder: OutlineInputBorder(
                          borderRadius:
                              BorderRadius.circular(AppSpacing.radiusSm),
                          borderSide: BorderSide(
                            color: _confirmed
                                ? AppColors.danger
                                : AppColors.liquid,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: AppSpacing.md),
                DangerBanner(message: _error!),
              ],
              const SizedBox(height: AppSpacing.xl),
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
                DangerButton(
                  label: 'Burn tokens',
                  icon: Icons.local_fire_department,
                  isFullWidth: true,
                  onPressed: _confirmed && _liquidAssets.isNotEmpty
                      ? _onBurn
                      : null,
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildResult() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          padding: EdgeInsets.all(AppSpacing.pagePadding(context)),
          children: [
            PageHeader(
              title: 'Burned',
              subtitle: 'Tokens destroyed on-chain',
              actions: [
                GhostButton(
                    label: 'Back to Liquid',
                    onPressed: () => context.go(AppRoutes.liquid))
              ],
            ),
            const InfoBanner(message: 'Burn transaction broadcast on-chain.'),
            const SizedBox(height: AppSpacing.xl),
            SectionCard(
              title: 'Result',
              child: CodeBox(label: 'TxID', value: _resultTxid!),
            ),
            const SizedBox(height: AppSpacing.xl),
            PrimaryButton(
              label: 'Done',
              isFullWidth: true,
              onPressed: () => context.go(AppRoutes.liquid),
            ),
          ],
        ),
      ),
    );
  }
}
