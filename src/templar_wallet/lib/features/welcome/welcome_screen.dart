import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../app/app_state.dart';
import '../../app/routes.dart';
import '../../shared/widgets/app_logo.dart';
import '../../shared/widgets/hybrid_kit.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_motion.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    // The entry screens always show the brand accent. Defer past the current
    // build so notifyListeners doesn't fire mid-build.
    final app = context.read<AppState>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) app.setAccent(null);
    });

    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );

    if (app.firstRunSeen) {
      // Seen before: skip the staged reveal, render the screen immediately.
      _c.value = 1.0;
    } else {
      _c.forward();
      app.markFirstRunSeen();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // OS reduced motion: skip the choreography, land on the final frame.
    if (AppMotion.reduced(context) && _c.isAnimating) {
      _c.stop();
      _c.value = 1.0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Animation<double> _fade(double begin, double end) => CurvedAnimation(
        parent: _c,
        curve: Interval(begin, end, curve: Curves.easeOut),
      );

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final logoIn = CurvedAnimation(
      parent: _c,
      curve: const Interval(0.0, 0.55, curve: Curves.easeOutBack),
    );
    final bodyIn = _fade(0.45, 1.0);

    return Scaffold(
      body: PageBackground(
        // Edge-to-edge on mobile: inert on desktop.
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Padding(
                padding: EdgeInsets.all(AppLayout.isPhone(context)
                    ? AppSpacing.xl
                    : AppSpacing.xxxl),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Logo — scales + fades in.
                    ScaleTransition(
                      scale: Tween(begin: 0.4, end: 1.0).animate(logoIn),
                      child: FadeTransition(
                        opacity: _fade(0.0, 0.45),
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(24),
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.accent.withValues(alpha: 0.45),
                                blurRadius: 36,
                                spreadRadius: 2,
                              ),
                            ],
                          ),
                          child: const AppLogo(size: 88, radius: 24),
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    FadeTransition(
                      opacity: bodyIn,
                      child: _GradientTitle('Templar Wallet'),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    FadeTransition(
                      opacity: bodyIn,
                      child: Column(
                        children: [
                          Text(
                            'Bitcoin & Liquid Network custody\nwith Miniscript spending policies',
                            textAlign: TextAlign.center,
                            style: AppTypography.body.copyWith(
                              color: isDark
                                  ? AppColors.textSecondaryDark
                                  : AppColors.textSecondary,
                            ),
                          ),
                          const SizedBox(height: AppSpacing.xxxl),
                          ...[
                            (Icons.security, 'Singlesig, multisig, Miniscript policies'),
                            (Icons.water_drop_outlined, 'Bitcoin + Liquid Network assets'),
                            (Icons.key_outlined, 'Software & hardware wallet support'),
                          ].map((item) => Padding(
                                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 30,
                                      height: 30,
                                      alignment: Alignment.center,
                                      decoration: BoxDecoration(
                                        color: AppColors.accentLight,
                                        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                                      ),
                                      child: Icon(item.$1, size: 16, color: AppColors.accent),
                                    ),
                                    const SizedBox(width: AppSpacing.md),
                                    Expanded(child: Text(item.$2, style: AppTypography.body)),
                                  ],
                                ),
                              )),
                          const SizedBox(height: AppSpacing.xxxl),
                          // Wizard entry: create or restore.
                          SizedBox(
                            width: double.infinity,
                            child: _GradientButton(
                              label: 'Create new wallet',
                              icon: Icons.add,
                              onPressed: () => context.go(AppRoutes.walletType),
                            ),
                          ),
                          const SizedBox(height: AppSpacing.md),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: () => context.go(AppRoutes.importWallet),
                              icon: const Icon(Icons.restore, size: 18),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
                              ),
                              label: const Text(
                                'Restore an existing wallet',
                                style: TextStyle(fontSize: 16),
                              ),
                            ),
                          ),
                          const SizedBox(height: AppSpacing.xl),
                          Text(
                            'Testnet only · No mainnet funds',
                            style: AppTypography.caption.copyWith(color: AppColors.textMuted),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            )),
          ),
        ),
      ),
    );
  }
}

/// Title rendered with the accent gradient — emotional brand moment.
class _GradientTitle extends StatelessWidget {
  const _GradientTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (rect) => LinearGradient(
        colors: [AppColors.accent, AppColors.accentMuted],
      ).createShader(rect),
      child: Text(
        text,
        style: AppTypography.pageTitle.copyWith(color: Colors.white),
      ),
    );
  }
}

/// Primary call-to-action with an accent gradient fill.
class _GradientButton extends StatelessWidget {
  const _GradientButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });
  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [AppColors.accent, AppColors.accentDark],
        ),
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        boxShadow: [
          BoxShadow(
            color: AppColors.accent.withValues(alpha: 0.35),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: FilledButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        style: FilledButton.styleFrom(
          backgroundColor: Colors.transparent,
          foregroundColor: Colors.white,
          shadowColor: Colors.transparent,
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
        ),
        label: Text(
          label,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
