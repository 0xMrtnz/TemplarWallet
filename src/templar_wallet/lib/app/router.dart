import 'package:flutter/foundation.dart' show kDebugMode, ValueKey;
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'app_state.dart';
import 'routes.dart';
import 'shell.dart';
import '../features/wallet_picker/wallet_picker_screen.dart';
import '../features/dashboard/dashboard_screen.dart';
import '../features/send/send_screen.dart';
import '../features/receive/receive_addresses_screen.dart';
import '../features/receive/receive_screen.dart';
import '../features/history/history_screen.dart';
import '../features/utxos/utxo_screen.dart';
import '../features/wallet_info/wallet_info_screen.dart';
import '../features/liquid/liquid_screen.dart';
import '../features/swap/swap_screen.dart';
import '../features/peg/peg_screen.dart';
import '../features/liquid/issue_screen.dart';
import '../features/liquid/reissue_screen.dart';
import '../features/liquid/burn_screen.dart';
import '../features/liquid/asset_operations_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/protocol/protocol_request_screen.dart';
import '../features/create_wallet/airgap_setup_screen.dart';
import '../features/create_wallet/create_wallet_screen.dart';
import '../features/create_wallet/hardware_setup_screen.dart';
import '../features/create_wallet/multisig_setup_screen.dart';
import '../features/create_wallet/watch_only_setup_screen.dart';
import '../features/create_wallet/wallet_type_screen.dart';
import '../features/import_wallet/import_wallet_screen.dart';
import '../features/welcome/welcome_screen.dart';
import '../features/dev/design_system_screen.dart';

final appRouter = GoRouter(
  initialLocation: AppRoutes.walletPicker,
  routes: [
    GoRoute(
      path: AppRoutes.walletPicker,
      builder: (_, _) => const WalletPickerScreen(),
    ),
    GoRoute(
      path: AppRoutes.welcome,
      builder: (_, _) => const WelcomeScreen(),
    ),
    GoRoute(
      path: AppRoutes.walletType,
      builder: (_, _) => const WalletTypeScreen(),
    ),
    GoRoute(
      path: AppRoutes.createWallet,
      builder: (_, _) => const CreateWalletScreen(),
    ),
    GoRoute(
      path: AppRoutes.hardwareSetup,
      builder: (_, _) => const HardwareSetupScreen(),
    ),
    GoRoute(
      path: AppRoutes.airgapSetup,
      builder: (_, _) => const AirgapSetupScreen(),
    ),
    GoRoute(
      path: AppRoutes.multisigSetup,
      builder: (_, _) => const MultisigSetupScreen(),
    ),
    GoRoute(
      path: AppRoutes.watchOnlySetup,
      builder: (_, _) => const WatchOnlySetupScreen(),
    ),
    GoRoute(
      path: AppRoutes.importWallet,
      builder: (_, _) => const ImportWalletScreen(),
    ),
    // templar:// deep links (Templar Protocol). Top-level on purpose: the screen
    // itself asks for a wallet or the vault passphrase when needed.
    GoRoute(
      path: AppRoutes.protocol,
      // Keyed by the link: a second link arriving while the screen is up
      // must start a fresh request, not update the finished one in place.
      builder: (_, s) {
        final link = s.uri.queryParameters['link'];
        return ProtocolRequestScreen(key: ValueKey(link ?? ''), rawLink: link);
      },
    ),
    ShellRoute(
      // Redirect to wallet picker if no wallet is active.
      redirect: (context, state) {
        final appState = context.read<AppState>();
        if (appState.activeWalletId == null) {
          return AppRoutes.walletPicker;
        }
        return null;
      },
      builder: (context, state, child) =>
          AppShell(currentPath: state.uri.path, child: child),
      routes: [
        GoRoute(path: AppRoutes.dashboard, builder: (_, _) => const DashboardScreen()),
        GoRoute(
          path: AppRoutes.send,
          // Pure watch-only wallets cannot sign — Send is removed entirely,
          // including direct navigation.
          redirect: (context, state) =>
              context.read<AppState>().isActiveWalletWatchOnly
                  ? AppRoutes.dashboard
                  : null,
          builder: (_, s) => SendScreen(
            startInCosign: s.uri.queryParameters['mode'] == 'cosign',
          ),
        ),
        GoRoute(path: AppRoutes.receive, builder: (_, _) => const ReceiveScreen()),
        GoRoute(
          path: AppRoutes.receiveAddresses,
          builder: (_, s) => ReceiveAddressesScreen(
            asset: s.uri.queryParameters['asset'] == 'LBTC' ? 'LBTC' : 'BTC',
          ),
        ),
        GoRoute(path: AppRoutes.history, builder: (_, _) => const HistoryScreen()),
        GoRoute(path: AppRoutes.utxos, builder: (_, _) => const UtxoScreen()),
        GoRoute(path: AppRoutes.walletInfo, builder: (_, _) => const WalletInfoScreen()),
        // Legacy deep link — co-sign now lives inside the Send screen.
        GoRoute(
          path: AppRoutes.cosign,
          redirect: (_, _) => '${AppRoutes.send}?mode=cosign',
        ),
        GoRoute(path: AppRoutes.liquid, builder: (_, _) => const LiquidScreen()),
        GoRoute(
          path: AppRoutes.swap,
          // Liquid-only feature — block direct navigation from BTC-only
          // wallets, mirroring the Send watch-only redirect.
          redirect: (context, state) =>
              context.read<AppState>().activeWalletLiquid
                  ? null
                  : AppRoutes.dashboard,
          builder: (_, _) => const SwapScreen(),
        ),
        GoRoute(
          path: AppRoutes.peg,
          redirect: (context, state) =>
              context.read<AppState>().activeWalletLiquid
                  ? null
                  : AppRoutes.dashboard,
          builder: (_, _) => const PegScreen(),
        ),
        GoRoute(path: AppRoutes.issueAsset, builder: (_, _) => const IssueScreen()),
        GoRoute(path: AppRoutes.reissueAsset, builder: (_, _) => const ReissueScreen()),
        GoRoute(path: AppRoutes.burnAsset, builder: (_, _) => const BurnScreen()),
        GoRoute(path: AppRoutes.assetOperations, builder: (_, _) => const AssetOperationsScreen()),
        GoRoute(path: AppRoutes.settings, builder: (_, _) => const SettingsScreen()),
        GoRoute(
          path: AppRoutes.settingsNetwork,
          builder: (_, _) =>
              const SettingsScreen(section: SettingsSection.network),
        ),
        GoRoute(
          path: AppRoutes.settingsSecurity,
          builder: (_, _) =>
              const SettingsScreen(section: SettingsSection.security),
        ),
        GoRoute(
          path: AppRoutes.settingsAppearance,
          builder: (_, _) =>
              const SettingsScreen(section: SettingsSection.appearance),
        ),
        GoRoute(
          path: AppRoutes.settingsProtocol,
          builder: (_, _) =>
              const SettingsScreen(section: SettingsSection.protocol),
        ),
        GoRoute(
          path: AppRoutes.settingsAbout,
          builder: (_, _) =>
              const SettingsScreen(section: SettingsSection.about),
        ),
        if (kDebugMode)
          GoRoute(
              path: AppRoutes.designSystem,
              builder: (_, _) => const DesignSystemScreen()),
      ],
    ),
  ],
);
