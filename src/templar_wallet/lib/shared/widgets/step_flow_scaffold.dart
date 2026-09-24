import 'package:flutter/material.dart';

import '../../theme/app_spacing.dart';
import 'hybrid_kit.dart';
import 'step_header.dart';

/// The one wizard shell every multi-step flow uses: fixed [StepHeader] on
/// top, scrollable body, pinned action row at the bottom. Standardizing on
/// this keeps back/cancel behavior and scrolling identical across the
/// create-wallet, hardware, air-gap, multisig, and watch-only flows.
class StepFlowScaffold extends StatelessWidget {
  const StepFlowScaffold({
    required this.currentStep,
    required this.totalSteps,
    required this.title,
    required this.body,
    this.subtitle,
    this.onBack,
    this.onCancel,
    this.actions,
    this.banner,
    this.headerVariants,
    this.maxWidth = 640,
    super.key,
  });

  final int currentStep;
  final int totalSteps;
  final String title;
  final String? subtitle;

  /// Back arrow in the header. Every step except the first should provide
  /// one (the first typically backs out to the wizard via [onCancel]).
  final VoidCallback? onBack;

  /// "Cancel" text button in the header — exits the whole flow.
  final VoidCallback? onCancel;

  /// Step content. Wrapped in a [SingleChildScrollView]: the body scrolls,
  /// header and actions stay fixed.
  final Widget body;

  /// Bottom action row (Back / Continue buttons). Kept out of the scroll
  /// area so it is always reachable.
  final Widget? actions;

  /// Optional banner pinned between header and body (info/warning).
  final Widget? banner;

  /// Every title/subtitle this flow can show — see [StepHeader.variants].
  /// Passing them keeps the header (and so the body under it) at one height
  /// for the whole flow instead of jumping when a subtitle wraps.
  final List<StepHeaderVariant>? headerVariants;

  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    // Android back: the wizard's own back, else its cancel — never the app
    // exit that a sole root route would otherwise get (typed input lost).
    final handler = onBack ?? onCancel;
    // A phone trades the desktop's generous gaps for content room and gives
    // the pinned action row a full touch-target height.
    final phone = AppLayout.isPhone(context);
    final gap = phone ? AppSpacing.lg : AppSpacing.xl;
    return PopScope(
      canPop: handler == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) handler!();
      },
      child: Scaffold(
        body: PageBackground.flat(
          // Edge-to-edge on mobile: header and action row stay clear of the
          // status bar and the gesture area. Inert on desktop.
          child: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth),
                child: Padding(
                  padding: EdgeInsets.all(AppSpacing.pagePadding(context)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      StepHeader(
                        currentStep: currentStep,
                        totalSteps: totalSteps,
                        title: title,
                        subtitle: subtitle,
                        onBack: onBack,
                        onCancel: onCancel,
                        variants: headerVariants,
                      ),
                      if (banner != null) ...[
                        const SizedBox(height: AppSpacing.lg),
                        banner!,
                      ],
                      SizedBox(height: gap),
                      Expanded(
                        child: SingleChildScrollView(
                          // Room under the last field so it can scroll clear
                          // of the pinned actions while the keyboard is up.
                          padding: phone
                              ? const EdgeInsets.only(bottom: AppSpacing.sm)
                              : EdgeInsets.zero,
                          child: body,
                        ),
                      ),
                      if (actions != null) ...[
                        SizedBox(height: gap),
                        if (phone)
                          ConstrainedBox(
                            constraints: const BoxConstraints(
                              minHeight: AppLayout.minTouchTarget,
                            ),
                            child: actions!,
                          )
                        else
                          actions!,
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
