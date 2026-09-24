// Every address a chain of this wallet has handed out, with what each one
// received. Receive shows the newest eight; the rest live here, so the page
// that exists to hand over ONE address never turns into a ledger.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/app_state.dart';
import '../../app/routes.dart';
import '../../bridge/bridge_provider.dart';
import '../../bridge/wallet_bridge.dart';
import '../../services/price_service.dart';
import '../../shared/widgets/buttons.dart';
import '../../shared/widgets/hybrid_kit.dart';
import '../../shared/widgets/list_rows.dart';
import '../../shared/widgets/page_header.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import 'models/address_info.dart';

class ReceiveAddressesScreen extends StatefulWidget {
  const ReceiveAddressesScreen({super.key, required this.asset, this.bridge});

  /// `BTC` or `LBTC` — the chain whose addresses are listed.
  final String asset;

  /// Test seam, as on [ReceiveScreen]: null in the app.
  final WalletBridge? bridge;

  @override
  State<ReceiveAddressesScreen> createState() => _ReceiveAddressesScreenState();
}

class _ReceiveAddressesScreenState extends State<ReceiveAddressesScreen> {
  late final WalletBridge _bridge = widget.bridge ?? walletBridge;

  /// Newest first: the current unused address leads, then every previous
  /// one by descending index — the ones most likely still in use on top.
  List<AddressInfo> _all = const [];
  AddressInfo? _current;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final walletId = context.read<AppState>().activeWalletId ?? 'wallet-1';
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // `fresh: false` re-reads the current unused address; nothing is
      // derived by opening this page.
      final current =
          await _bridge.generateReceiveAddress(walletId, widget.asset);
      final previous =
          await _bridge.listPreviousAddresses(walletId, widget.asset);
      if (!mounted) return;
      final sorted = [...previous]..sort((a, b) => b.index.compareTo(a.index));
      setState(() {
        _current = current;
        _all = [current, ...sorted.where((a) => a.address != current.address)];
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _plainError(e.toString());
      });
    }
  }

  String get _chainName => widget.asset == 'BTC' ? 'Bitcoin' : 'Liquid';

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final phone = AppLayout.isPhone(context);
    final funded = _all.where((a) => a.receivedSats > 0).toList();
    final totalSats = funded.fold<int>(0, (sum, a) => sum + a.receivedSats);
    final useSats = context.select<AppState, bool>((st) => st.useSats);
    final coin = widget.asset == 'BTC' ? 'BTC' : 'L-BTC';

    return Scaffold(
      body: PageBackground.flat(
        child: ListView(
          padding: EdgeInsets.all(AppSpacing.pagePadding(context)),
          children: [
            // The phone shell's header already says "‹ All addresses"; the
            // desktop page names itself and offers the way back.
            if (!phone)
              PageHeader(
                title: 'All addresses',
                subtitle: '$_chainName · every address this wallet has '
                    'handed out, newest first',
                actions: [
                  SecondaryButton(
                    label: 'Back to Receive',
                    icon: Icons.arrow_back,
                    onPressed: () => context.go(AppRoutes.receive),
                  ),
                ],
              ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(top: AppSpacing.xxl),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              Center(
                child: Column(
                  children: [
                    const Icon(Icons.error_outline,
                        size: 40, color: AppColors.danger),
                    const SizedBox(height: AppSpacing.md),
                    SelectableText(_error!,
                        style: AppTypography.caption,
                        textAlign: TextAlign.center),
                    const SizedBox(height: AppSpacing.md),
                    SecondaryButton(
                      label: 'Retry',
                      icon: Icons.refresh,
                      onPressed: _load,
                    ),
                  ],
                ),
              )
            else ...[
              // What the list adds up to, before the list.
              ListSectionLabel(label: '$_chainName addresses'),
              ListCard(
                children: [
                  ListRow(
                    icon: Icons.format_list_numbered_rounded,
                    tint: s.inkSecondary,
                    title: '${_all.length} '
                        'address${_all.length == 1 ? '' : 'es'}',
                    subtitle: '${funded.length} funded · '
                        '${_all.length - funded.length} never used',
                  ),
                  ListRow(
                    icon: Icons.south_west_rounded,
                    tint: s.success,
                    title: 'Received in total',
                    subtitle: PriceService.instance.fiatDisplay(totalSats) ==
                            null
                        ? null
                        : '≈ ${PriceService.instance.fiatDisplay(totalSats)}',
                    trailing: ListAmount(
                      value: _amountValue(totalSats, useSats, coin),
                      unit: _amountUnit(useSats, coin),
                      maxWidth: 160,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xl),
              const ListSectionLabel(label: 'Newest first'),
              ListCard(
                children: [
                  for (final a in _all)
                    _AddressEntry(
                      info: a,
                      isCurrent: a.address == _current?.address,
                      useSats: useSats,
                      coin: coin,
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _amountValue(int sats, bool useSats, String coin) {
    final text = PriceService.formatUnit(sats, sat: useSats, coin: coin);
    // "1,234 sats" / "0.00001234 BTC" → the figure alone; the unit is
    // drawn quietly beside it.
    final space = text.lastIndexOf(' ');
    return space < 0 ? text : text.substring(0, space);
  }

  static String _amountUnit(bool useSats, String coin) =>
      useSats ? 'sats' : coin;
}

/// One address as a list row on both platforms: index and label lead, the
/// derivation path says where it came from, the right column says what it
/// received. Tapping copies the address.
class _AddressEntry extends StatefulWidget {
  const _AddressEntry({
    required this.info,
    required this.isCurrent,
    required this.useSats,
    required this.coin,
  });

  final AddressInfo info;
  final bool isCurrent;
  final bool useSats;
  final String coin;

  @override
  State<_AddressEntry> createState() => _AddressEntryState();
}

class _AddressEntryState extends State<_AddressEntry> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.info.address));
    if (!mounted) return;
    if (AppLayout.isPhone(context)) {
      HapticFeedback.lightImpact();
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('Address copied'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ));
    }
    setState(() => _copied = true);
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final a = widget.info;
    final phone = AppLayout.isPhone(context);
    final funded = a.receivedSats > 0;
    final label = a.label;
    final head = '#${a.index}';
    final title = widget.isCurrent
        ? (label == null ? '$head · current' : '$head · $label · current')
        : (label == null ? head : '$head · $label');
    final path = a.derivationPath;

    // The row grammar carries a one-line subtitle; the address itself is the
    // thing to read, so it gets its own line under the row on both
    // platforms — whole on a desktop, shortened on a phone.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListRow(
          icon: widget.isCurrent
              ? Icons.qr_code_2_rounded
              : Icons.south_west_rounded,
          tint: widget.isCurrent
              ? s.accent
              : funded
                  ? s.success
                  : s.inkFaint,
          title: title,
          subtitle: path ??
              (widget.isCurrent ? 'Shown on Receive' : 'Previous address'),
          trailing: funded
              ? ListAmount(
                  value: _ReceiveAddressesScreenState._amountValue(
                      a.receivedSats, widget.useSats, widget.coin),
                  unit: _ReceiveAddressesScreenState._amountUnit(
                      widget.useSats, widget.coin),
                  maxWidth: 140,
                )
              : Icon(_copied ? Icons.check : Icons.copy,
                  size: 18, color: _copied ? s.success : s.inkFaint),
          onTap: _copy,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
              kListTextInset, 0, kListPad, AppSpacing.md),
          child: SelectableText(
            phone ? _shortAddress(a.address) : a.address,
            style: AppTypography.monoSmall.copyWith(color: s.inkSecondary),
            onTap: _copy,
          ),
        ),
      ],
    );
  }
}

/// Middle-ellipsised address for a phone line; short strings pass through.
String _shortAddress(String address, {int head = 14, int tail = 10}) {
  if (address.length <= head + tail + 1) return address;
  return '${address.substring(0, head)}…${address.substring(address.length - tail)}';
}

String _plainError(String raw) {
  var msg = raw.trim();
  for (final prefix in const ['Exception: ', 'wallet-ffi: ']) {
    if (msg.startsWith(prefix)) msg = msg.substring(prefix.length).trim();
  }
  return msg;
}

