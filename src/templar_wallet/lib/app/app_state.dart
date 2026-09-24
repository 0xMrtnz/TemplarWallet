import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../bridge/wallet_bridge.dart';
import '../features/dashboard/models/dashboard_data.dart';
import '../features/history/models/transaction.dart';
import '../services/price_service.dart';
import '../theme/app_colors.dart';

enum SyncState { idle, syncing, synced, warning, error }

class AppState extends ChangeNotifier {
  ThemeMode _themeMode = ThemeMode.dark;
  ThemeMode get themeMode => _themeMode;

  /// Current global accent color. Driven by the active wallet's customization
  /// (or the brand default when no wallet is open). Re-tints the whole UI.
  Color _accent = AppColors.accentDefault;
  Color get accent => _accent;

  void setAccent(Color? color) {
    final next = color ?? AppColors.accentDefault;
    AppColors.applyAccent(next);
    _accent = AppColors.accent;
    notifyListeners();
  }

  /// True once the one-time welcome animation has been shown.
  bool _firstRunSeen = false;
  bool get firstRunSeen => _firstRunSeen;

  Future<void> markFirstRunSeen() async {
    if (_firstRunSeen) return;
    _firstRunSeen = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kFirstRunSeen, true);
  }

  String? _activeWalletId;
  String? get activeWalletId => _activeWalletId;

  String? _activeWalletName;
  String? get activeWalletName => _activeWalletName;

  String? _activeWalletType;
  String? get activeWalletType => _activeWalletType;

  /// True when the active wallet has a paired Liquid wallet enabled. Drives
  /// whether the Liquid section is shown in the sidebar.
  bool _activeWalletLiquid = false;
  bool get activeWalletLiquid => _activeWalletLiquid;

  /// True when the active wallet has a Bitcoin side at all.
  ///
  /// False for a Liquid-only wallet — a Jade paired for Liquid alone. Its
  /// Bitcoin screens have no wallet behind them, and asking for a Bitcoin
  /// receive address on one comes back as "Bitcoin wallet not open". Hidden
  /// rather than shown-and-failing.
  bool _activeWalletBitcoin = true;
  bool get activeWalletBitcoin => _activeWalletBitcoin;

  /// True when a hardware wallet was opened without its device connected
  /// (watch-only mode: balance + receive only, signing disabled).
  bool _hwWatchOnly = false;
  bool get hwWatchOnly => _hwWatchOnly;

  /// True when the active wallet is a USB hardware wallet (`Hardware (fp)`).
  bool get isActiveWalletHardware {
    final t = _activeWalletType ?? '';
    return t.startsWith('Hardware (') || t.toLowerCase().contains('hardware');
  }

  /// True when the active wallet is a pure watch-only wallet — view only,
  /// no way to sign at all, so Send is hidden entirely. Exact match: the
  /// air-gap label ("Air-gap watch-only") also contains "watch-only" but that
  /// wallet signs via QR and keeps Send.
  bool get isActiveWalletWatchOnly =>
      (_activeWalletType ?? '').toLowerCase() == 'watch-only';

  /// Flip the watch-only flag for the active hardware wallet (e.g. after the
  /// user connects the device from within the wallet).
  void setHwWatchOnly(bool value) {
    if (_hwWatchOnly == value) return;
    _hwWatchOnly = value;
    notifyListeners();
  }

  /// The Liquid network the engine runs on, read at startup and after every
  /// switch. Null until the first read (or when the bridge is unavailable).
  LiquidNetworkInfo? _liquidNetwork;
  LiquidNetworkInfo? get liquidNetwork => _liquidNetwork;

  /// True when Liquid runs against a local regtest node. Drives the regtest
  /// strip in the shell and the wording of network-specific screens.
  bool get isLiquidRegtest => _liquidNetwork?.isRegtest ?? false;

  void setLiquidNetworkInfo(LiquidNetworkInfo? info) {
    _liquidNetwork = info;
    notifyListeners();
  }

  SyncState _syncState = SyncState.idle;
  SyncState get syncState => _syncState;

  /// Optional footer label detail for the current sync state — e.g. which
  /// chain failed on a partial sync. Null = use the generic label.
  String? _syncDetail;
  String? get syncDetail => _syncDetail;

  int _syncVersion = 0;
  int get syncVersion => _syncVersion;

  // Screen data cache — populated by screens, read by screens on repeat visits.
  // No notifyListeners: screens manage their own setState.
  DashboardData? cachedDashboard;
  List<Transaction>? cachedTransactions;

  static const _kReduceEffects = 'pref_reduce_effects';
  static const _kBtcExplorer = 'pref_btc_explorer';
  static const _kLiquidExplorer = 'pref_liquid_explorer';
  static const _kAutoSync = 'pref_auto_sync';
  static const _kFirstRunSeen = 'pref_first_run_seen';
  static const _kFiatCurrency = 'pref_fiat_currency';
  static const _kBitcoinUnit = 'pref_bitcoin_unit';
  static const _kBalancesHidden = 'pref_balances_hidden';
  static const _kBtcExplorerDefault = 'https://mempool.space/testnet';
  static const _kLiquidExplorerDefault = 'https://blockstream.info/liquidtestnet';

  /// Fiat currency used for value estimates (ISO code, e.g. 'USD', 'EUR').
  String _fiatCurrency = 'USD';
  String get fiatCurrency => _fiatCurrency;

  /// Bitcoin denomination for on-screen amounts: 'btc' or 'sat'.
  String _bitcoinUnit = 'btc';
  String get bitcoinUnit => _bitcoinUnit;
  bool get useSats => _bitcoinUnit == 'sat';

  /// Privacy mode — every coin amount and fiat value on screen is replaced by
  /// dots. Purely a display mask: nothing about the wallet changes, so it is
  /// safe to persist and safe to flip at any time.
  bool _balancesHidden = false;
  bool get balancesHidden => _balancesHidden;

  Future<void> setBalancesHidden(bool value) async {
    if (_balancesHidden == value) return;
    _balancesHidden = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kBalancesHidden, value);
  }

  Future<void> toggleBalancesHidden() => setBalancesHidden(!_balancesHidden);

  String _btcExplorerUrl = _kBtcExplorerDefault;
  String get btcExplorerUrl => _btcExplorerUrl;

  String _liquidExplorerUrl = _kLiquidExplorerDefault;
  String get liquidExplorerUrl => _liquidExplorerUrl;

  /// 'en' or 'it'

  bool _autoSync = true;
  bool get autoSync => _autoSync;

  /// "Reduce effects" — disables GPU-expensive visuals (frosted blur) for
  /// low-power hardware. Distinct from the OS reduced-motion setting, which
  /// AppMotion handles separately.
  bool _reduceEffects = false;
  bool get reduceEffects => _reduceEffects;

  Future<void> setReduceEffects(bool value) async {
    _reduceEffects = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kReduceEffects, value);
  }

  Future<void> loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    _btcExplorerUrl = prefs.getString(_kBtcExplorer) ?? _kBtcExplorerDefault;
    _liquidExplorerUrl = prefs.getString(_kLiquidExplorer) ?? _kLiquidExplorerDefault;
    // One-time migration: earlier builds saved mainnet explorer URLs. This build
    // is testnet-locked, so rewrite the stale defaults to their testnet paths.
    if (_btcExplorerUrl == 'https://mempool.space') {
      _btcExplorerUrl = _kBtcExplorerDefault;
      await prefs.setString(_kBtcExplorer, _btcExplorerUrl);
    }
    if (_liquidExplorerUrl == 'https://blockstream.info/liquid') {
      _liquidExplorerUrl = _kLiquidExplorerDefault;
      await prefs.setString(_kLiquidExplorer, _liquidExplorerUrl);
    }
    _autoSync = prefs.getBool(_kAutoSync) ?? true;
    _reduceEffects = prefs.getBool(_kReduceEffects) ?? false;
    _firstRunSeen = prefs.getBool(_kFirstRunSeen) ?? false;
    _fiatCurrency = prefs.getString(_kFiatCurrency) ?? 'USD';
    _bitcoinUnit = prefs.getString(_kBitcoinUnit) ?? 'btc';
    _balancesHidden = prefs.getBool(_kBalancesHidden) ?? false;
    // Keep the price feed aligned with the saved currency.
    PriceService.instance.setCurrency(_fiatCurrency);
    notifyListeners();
  }

  Future<void> setFiatCurrency(String code) async {
    if (_fiatCurrency == code) return;
    _fiatCurrency = code;
    PriceService.instance.setCurrency(code);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kFiatCurrency, code);
  }

  Future<void> setBitcoinUnit(String unit) async {
    if (_bitcoinUnit == unit) return;
    _bitcoinUnit = unit;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kBitcoinUnit, unit);
  }

  Future<void> setAutoSync(bool value) async {
    _autoSync = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoSync, value);
  }

  Future<void> setBtcExplorerUrl(String url) async {
    _btcExplorerUrl = url;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kBtcExplorer, url);
  }

  Future<void> setLiquidExplorerUrl(String url) async {
    _liquidExplorerUrl = url;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLiquidExplorer, url);
  }

  void setThemeMode(ThemeMode mode) {
    _themeMode = mode;
    notifyListeners();
  }

  void toggleTheme() {
    _themeMode = _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    notifyListeners();
  }

  void setActiveWallet(String? id,
      {String? name,
      String? type,
      bool hwWatchOnly = false,
      bool liquid = false,
      bool bitcoin = true}) {
    if (_activeWalletId != id) {
      cachedDashboard = null;
      cachedTransactions = null;
    }
    _activeWalletId = id;
    _activeWalletName = name;
    _activeWalletType = type;
    _hwWatchOnly = hwWatchOnly;
    _activeWalletLiquid = liquid;
    _activeWalletBitcoin = bitcoin;
    notifyListeners();
  }

  void setSyncState(SyncState state, {String? detail}) {
    _syncState = state;
    _syncDetail = detail;
    notifyListeners();
  }

  /// Digest the per-chain outcome map from [WalletBridge.syncWallet] —
  /// `{'btc': 'ok'|'skipped'|'error: …', 'liquid': …}` — into the footer
  /// state: synced only when every present chain is ok, warning when some
  /// (not all) failed, error when every attempted chain failed. Bumps the
  /// sync version either way so screens refresh. Shared by the shell footer
  /// and the post-broadcast background sync.
  void applySyncOutcomes(Map<String, String> outcomes) {
    final attempted =
        outcomes.entries.where((e) => e.value != 'skipped').toList();
    final failed = attempted.where((e) => e.value != 'ok').toList();
    if (failed.isEmpty) {
      setSyncState(SyncState.synced);
    } else {
      final detail =
          failed.map((e) => '${_chainLabel(e.key)} sync failed').join(', ');
      setSyncState(
        failed.length < attempted.length ? SyncState.warning : SyncState.error,
        detail: detail,
      );
    }
    bumpSync();
  }

  static String _chainLabel(String key) => switch (key) {
        'btc' => 'Bitcoin',
        'liquid' => 'Liquid',
        _ => key,
      };

  void bumpSync() {
    _syncVersion++;
    notifyListeners();
  }
}
