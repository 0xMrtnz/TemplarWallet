import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../app/app_state.dart';
import '../../app/routes.dart';
import '../../bridge/bridge_provider.dart';
import '../../services/issued_asset_store.dart';
import '../../shared/widgets/buttons.dart';
import '../../shared/widgets/cards.dart';
import '../../shared/widgets/hybrid_kit.dart';
import '../../shared/widgets/list_rows.dart';
import '../../shared/widgets/page_header.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';

class AssetOperationsScreen extends StatefulWidget {
  const AssetOperationsScreen({super.key});

  @override
  State<AssetOperationsScreen> createState() => _AssetOperationsScreenState();
}

class _AssetOperationsScreenState extends State<AssetOperationsScreen> {
  final _bridge = walletBridge;

  /// Issued assets whose registry submission is still pending and which carry
  /// enough persisted contract data (name/ticker/precision/domain) to retry.
  List<IssuedAssetEntry> _unregistered = [];

  /// Asset ID currently being submitted to the registry, if any.
  String? _registering;

  @override
  void initState() {
    super.initState();
    _loadUnregistered();
  }

  Future<void> _loadUnregistered() async {
    final walletId = context.read<AppState>().activeWalletId ?? 'wallet-1';
    final issued = await IssuedAssetStore.instance.getIssuedAssets(walletId);
    if (mounted) {
      setState(() {
        _unregistered =
            issued.values.where((e) => e.canReregister).toList();
      });
    }
  }

  Future<void> _onRegister(IssuedAssetEntry entry) async {
    final walletId = context.read<AppState>().activeWalletId ?? 'wallet-1';
    setState(() => _registering = entry.assetId);
    bool ok = false;
    String? failure;
    try {
      // The FFI rebuilds the contract from these fields, validates it against
      // the on-chain issuance, and re-submits it to the registry.
      ok = await _bridge.reregisterAsset(
        walletId: walletId,
        assetId: entry.assetId,
        name: entry.name,
        ticker: entry.ticker,
        precision: entry.precision,
        domain: entry.domain,
      );
    } catch (e) {
      failure = e.toString();
    }
    if (ok) {
      await IssuedAssetStore.instance.markRegistered(walletId, entry.assetId);
    }
    if (!mounted) return;
    setState(() {
      _registering = null;
      if (ok) {
        _unregistered.removeWhere((e) => e.assetId == entry.assetId);
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok
            ? '${entry.ticker} registered successfully!'
            : failure != null
                ? 'Registration error: $failure'
                : 'Registration failed — ensure the domain proof file on '
                    '${entry.domain} is live, then try again.'),
        backgroundColor: ok ? AppColors.success : AppColors.danger,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    // On a phone the two SectionCards below would each wrap cards in a card:
    // the page draws the group label itself and the rows carry their own one
    // card, so only one border is ever crossed.
    final phone = AppLayout.isPhone(context);
    return Scaffold(
      body: PageBackground.flat(child: ListView(
        padding: EdgeInsets.all(AppSpacing.pagePadding(context)),
        children: [
          const PageHeader(
            title: 'Asset Operations',
            subtitle: 'Issue, reissue, or burn Liquid assets',
          ),
          if (phone) ...[
            const ListSectionLabel(label: 'Manage assets'),
            const AssetOpsRows(),
          ] else
            SectionCard(
              title: 'Manage Assets',
              child: Column(
                children: [
                  _OperationCard(
                    icon: Icons.add_circle_outline,
                    title: 'Issue Asset',
                    description: 'Create a new Liquid asset with custom parameters.',
                    color: AppColors.liquid,
                    onTap: () => context.go(AppRoutes.issueAsset),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _OperationCard(
                    icon: Icons.refresh,
                    title: 'Reissue',
                    description: 'Mint additional supply of an existing asset you control.',
                    color: AppColors.success,
                    onTap: () => context.go(AppRoutes.reissueAsset),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _OperationCard(
                    icon: Icons.local_fire_department_outlined,
                    title: 'Burn',
                    description: 'Permanently destroy asset supply. This is irreversible.',
                    color: AppColors.danger,
                    onTap: () => context.go(AppRoutes.burnAsset),
                  ),
                ],
              ),
            ),
          if (_unregistered.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xl),
            if (phone) ...[
              const ListSectionLabel(label: 'Asset registry'),
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                child: Text(
                  'Assets issued from this wallet that are not yet in the '
                  'Liquid asset registry. Make sure the domain proof file is '
                  'live before registering.',
                  style:
                      AppTypography.caption.copyWith(color: s.inkSecondary),
                ),
              ),
              for (final entry in _unregistered) ...[
                if (entry != _unregistered.first)
                  const SizedBox(height: AppSpacing.md),
                _RegistryRow(
                  entry: entry,
                  busy: _registering == entry.assetId,
                  // Serialize submissions — one at a time.
                  onRegister:
                      _registering == null ? () => _onRegister(entry) : null,
                ),
              ],
            ] else
              SectionCard(
                title: 'Asset Registry',
                subtitle:
                    'Assets issued from this wallet that are not yet in the '
                    'Liquid asset registry. Make sure the domain proof file is '
                    'live before registering.',
                child: Column(
                  children: [
                    for (final entry in _unregistered) ...[
                      if (entry != _unregistered.first)
                        const SizedBox(height: AppSpacing.md),
                      _RegistryRow(
                        entry: entry,
                        busy: _registering == entry.assetId,
                        // Serialize submissions — one at a time.
                        onRegister:
                            _registering == null ? () => _onRegister(entry) : null,
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ],
      )),
    );
  }
}

/// The three Liquid asset operations as phone rows.
///
/// Phone only, and shared by both entry points (this screen and the Liquid
/// hub) so Issue/Reissue/Burn is literally the same object wherever it is
/// reached. The two screens' desktop `_OperationCard` slabs are deliberately
/// NOT merged — they differ in tile size, radius, surface token and title
/// style — so only the phone grammar lives here.
class AssetOpsRows extends StatelessWidget {
  const AssetOpsRows({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return ListCard(
      children: [
        ListRow(
          icon: Icons.add_circle_outline,
          tint: s.liquid,
          title: 'Issue Asset',
          // ListRow's subtitle is one ellipsised line, so the desktop
          // sentence is trimmed to fit rather than cut mid-word.
          subtitle: 'Create a new Liquid asset',
          chevron: true,
          onTap: () => context.go(AppRoutes.issueAsset),
        ),
        ListRow(
          icon: Icons.refresh,
          tint: s.success,
          title: 'Reissue',
          subtitle: 'Mint more of an asset you control',
          chevron: true,
          onTap: () => context.go(AppRoutes.reissueAsset),
        ),
        ListRow(
          icon: Icons.local_fire_department_outlined,
          tint: s.danger,
          title: 'Burn',
          subtitle: 'Destroy supply — irreversible',
          chevron: true,
          onTap: () => context.go(AppRoutes.burnAsset),
        ),
      ],
    );
  }
}

class _RegistryRow extends StatelessWidget {
  const _RegistryRow({
    required this.entry,
    required this.busy,
    required this.onRegister,
  });

  final IssuedAssetEntry entry;
  final bool busy;
  final VoidCallback? onRegister;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (AppLayout.isPhone(context)) {
      final s = AppScheme.of(context);
      // Stack instead of squeeze: 'Register in asset registry' plus its glyph
      // wants ~200 dp of a ~350 dp row, and because the button is
      // intrinsically sized it is the asset's name that gets ellipsised away,
      // not the button. The action keeps a real 54 dp button — this submits
      // to a network service, so it has to look like something you press.
      return Container(
        padding: const EdgeInsets.all(AppSpacing.cardPaddingSmall),
        decoration: BoxDecoration(
          color: s.panel,
          borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
          border: Border.all(color: s.edge),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ListIconTile(icon: Icons.public, tint: s.liquid),
                const SizedBox(width: kListGap),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${entry.ticker} — ${entry.name}',
                        style: AppTypography.sectionTitleOf(context),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      // One line, one fact: the domain is what decides
                      // whether registration will succeed, so the truncated
                      // asset ID gives up its half of this line.
                      Text(
                        entry.domain,
                        style: AppTypography.caption
                            .copyWith(color: s.inkSecondary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            if (busy)
              const Center(
                child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else
              SecondaryButton(
                // The section prose above already says these are registry
                // submissions, so the label can be the verb alone.
                label: 'Register',
                icon: Icons.public,
                isFullWidth: true,
                onPressed: onRegister,
              ),
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.all(AppSpacing.cardPadding),
      decoration: BoxDecoration(
        color: isDark ? AppColors.surfaceDark2 : AppColors.backgroundLight,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(
            color: isDark ? AppColors.borderDark : AppColors.borderLight),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${entry.ticker} — ${entry.name}',
                    style: AppTypography.sectionTitle),
                const SizedBox(height: 2),
                Text(
                  entry.assetId.length > 16
                      ? '${entry.assetId.substring(0, 16)}…  ·  ${entry.domain}'
                      : '${entry.assetId}  ·  ${entry.domain}',
                  style: AppTypography.caption,
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.lg),
          if (busy)
            const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2))
          else
            SecondaryButton(
              label: 'Register in asset registry',
              icon: Icons.public,
              onPressed: onRegister,
            ),
        ],
      ),
    );
  }
}

class _OperationCard extends StatelessWidget {
  const _OperationCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String description;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.cardPadding),
        decoration: BoxDecoration(
          color: isDark ? AppColors.surfaceDark2 : AppColors.backgroundLight,
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          border: Border.all(
              color: isDark ? AppColors.borderDark : AppColors.borderLight),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: color.withAlpha(38),
                borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
              ),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(width: AppSpacing.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AppTypography.sectionTitle),
                  const SizedBox(height: 2),
                  Text(description, style: AppTypography.caption),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              color: isDark ? AppColors.textSecondaryDark : AppColors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}
