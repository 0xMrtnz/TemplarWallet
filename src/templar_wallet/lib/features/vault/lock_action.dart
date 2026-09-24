import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/app_state.dart';
import '../../app/routes.dart';
import '../../bridge/bridge_provider.dart';
import '../../theme/app_colors.dart';
import '../settings/seed_phrase_section.dart';
import 'vault_unlock_screen.dart';

/// Lock the vault and put the unlock screen in front of the user.
///
/// Lives here rather than in Settings because there are now two ways to
/// invoke it — the Security page and the sidebar footer — and the two must
/// leave the app in exactly the same state. Locking drops the in-memory key,
/// closes the open wallet, and invalidates the seed-reveal grace: a user who
/// locks is saying "stop trusting this machine", and a 60-second window that
/// outlived that would quietly contradict them.
///
/// [onUnlocked] runs once the vault is open again — for a screen that stays
/// underneath the unlock and needs to know (the picker's lock button).
Future<void> lockVaultAndPrompt(BuildContext context,
    {VoidCallback? onUnlocked}) async {
  final appState = context.read<AppState>();
  try {
    await walletBridge.lockVault();
    SeedRevealGate.reset();
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Could not lock: $e'),
        backgroundColor: AppColors.danger,
      ));
    }
    return;
  }
  if (!context.mounted) return;
  appState.setActiveWallet(null);
  pushVaultUnlock(context, onUnlocked: onUnlocked);
}

/// Full-screen unlock, the same screen the startup gate uses. Not dismissible
/// — while locked there is no wallet data behind it to go back to.
void pushVaultUnlock(BuildContext context, {VoidCallback? onUnlocked}) {
  Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (routeContext) => PopScope(
        canPop: false,
        child: VaultUnlockScreen(
          onUnlocked: () {
            Navigator.of(routeContext).pop();
            onUnlocked?.call();
            if (context.mounted) {
              // The active wallet was closed by the lock — back to the picker.
              context.go(AppRoutes.walletPicker);
            }
          },
        ),
      ),
    ),
  );
}
