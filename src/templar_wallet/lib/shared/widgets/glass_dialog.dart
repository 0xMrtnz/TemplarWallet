import 'dart:ui';

import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';

/// Frosted "liquid glass" dialog shell — blurred backdrop + translucent
/// surface + a hairline accent border and a soft glow. Drop-in replacement for
/// [AlertDialog] on password / unlock prompts.
///
/// The tint is a *hint*, not a wash. It used to blend 24% of the accent into
/// the surface, which on a black page turned every dialog into a solid block of
/// brand colour with the form fields floating inside it — and made the accent
/// mean "dialog" instead of "this is the thing to look at". The colour now
/// lives on the border, the glow and the icon; the surface stays neutral so the
/// content on it is the loudest thing in the frame.
class GlassDialog extends StatelessWidget {
  const GlassDialog({
    super.key,
    required this.title,
    required this.child,
    required this.actions,
    this.icon,
    this.accent,
    this.width = 380,
  });

  final String title;
  final Widget child;
  final List<Widget> actions;
  final IconData? icon;

  /// Tint for the gradient, border and glow. Defaults to the app accent.
  final Color? accent;
  final double width;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tint = accent ?? AppColors.accent;

    // Translucent base so the blurred backdrop bleeds through, then the tint is
    // blended in for the glassy chain/accent feel.
    // Dark dialogs sit on a black page, so the surface has to be near-opaque
    // or the text behind it reads straight through the blur.
    final base = isDark
        ? [const Color(0xF01A1A1F), const Color(0xF0121216)]
        : [const Color(0xFAFFFFFF), const Color(0xF0FFFFFF)];
    final colors = [
      Color.alphaBlend(tint.withValues(alpha: isDark ? 0.05 : 0.03), base[0]),
      Color.alphaBlend(tint.withValues(alpha: isDark ? 0.02 : 0.015), base[1]),
    ];

    if (_rendersAsSheet(context)) {
      // Opened through showAppDialog this is a bottom sheet: full width,
      // rounded top, no blur (a BackdropFilter over a whole phone frame is
      // the single most expensive thing a low-end GPU can be asked for).
      return AppSheet(
        icon: icon,
        accent: tint,
        title: Text(title),
        actions: actions,
        child: child,
      );
    }
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(AppSpacing.xl),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppSpacing.radiusXl),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: Container(
            width: width,
            padding: const EdgeInsets.all(AppSpacing.xl),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: colors,
              ),
              borderRadius: BorderRadius.circular(AppSpacing.radiusXl),
              border: Border.all(
                color: tint.withValues(alpha: isDark ? 0.45 : 0.35),
              ),
              boxShadow: [
                BoxShadow(
                  color: tint.withValues(alpha: isDark ? 0.18 : 0.12),
                  blurRadius: 40,
                  spreadRadius: -8,
                  offset: const Offset(0, 12),
                ),
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.55 : 0.14),
                  blurRadius: 34,
                  offset: const Offset(0, 14),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (icon != null) ...[
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              tint,
                              Color.alphaBlend(
                                  Colors.white.withValues(alpha: 0.30), tint),
                            ],
                          ),
                          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                        ),
                        child: Icon(icon, color: Colors.white, size: 20),
                      ),
                      const SizedBox(width: AppSpacing.md),
                    ],
                    Expanded(
                      child: Text(title, style: AppTypography.sectionTitle),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.lg),
                child,
                const SizedBox(height: AppSpacing.xl),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    for (var i = 0; i < actions.length; i++) ...[
                      if (i > 0) const SizedBox(width: AppSpacing.sm),
                      actions[i],
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Password input styled for [GlassDialog]: translucent fill + show/hide toggle.
class GlassPasswordField extends StatefulWidget {
  const GlassPasswordField({
    super.key,
    required this.controller,
    this.label = 'Password',
    this.autofocus = false,
    this.errorText,
    this.onSubmitted,
    this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final bool autofocus;
  final String? errorText;
  final VoidCallback? onSubmitted;
  final ValueChanged<String>? onChanged;

  @override
  State<GlassPasswordField> createState() => _GlassPasswordFieldState();
}

class _GlassPasswordFieldState extends State<GlassPasswordField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final phone = AppLayout.isPhone(context);
    final s = AppScheme.of(context);
    return TextField(
      controller: widget.controller,
      obscureText: _obscure,
      autofocus: widget.autofocus,
      onSubmitted: (_) => widget.onSubmitted?.call(),
      onChanged: widget.onChanged,
      decoration: InputDecoration(
        labelText: widget.label,
        errorText: widget.errorText,
        errorMaxLines: 3,
        filled: true,
        // A hard-coded fill would beat the phone's InputDecorationTheme, so
        // this one field would stay glass while every other went grey.
        fillColor: phone
            ? s.panelInset
            : (isDark
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.white.withValues(alpha: 0.55)),
        suffixIcon: IconButton(
          icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility,
              size: 18),
          onPressed: () => setState(() => _obscure = !_obscure),
          tooltip: _obscure ? 'Show' : 'Hide',
        ),
      ),
    );
  }
}


// ── Adaptive dialog / sheet ───────────────────────────────────────────────────

/// True when the widget at [context] should draw itself as a bottom-sheet
/// body: a phone AND a route that actually anchors to the bottom (the one
/// [showAppDialog] opens). A GlassDialog/AppDialog that some caller still
/// opens through plain `showDialog` keeps its dialog frame — a sheet body
/// inside a dialog route would be laid out as a full-height panel pinned to
/// the top of the screen.
bool _rendersAsSheet(BuildContext context) =>
    AppLayout.isPhone(context) && ModalRoute.of(context) is ModalBottomSheetRoute;

/// Opens a dialog the way the window expects: [showDialog] on desktop, a
/// modal bottom sheet on a phone ([AppLayout.isPhone]). Use it in place of
/// every `showDialog` call; the builder's widget should be a [GlassDialog] or
/// an [AppDialog] — both render themselves as a sheet body on a phone. The
/// sheet rises above the keyboard and respects the bottom inset.
Future<T?> showAppDialog<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  bool useRootNavigator = true,
  RouteSettings? routeSettings,
}) {
  if (!AppLayout.isPhone(context)) {
    return showDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      useRootNavigator: useRootNavigator,
      routeSettings: routeSettings,
      builder: builder,
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    useRootNavigator: useRootNavigator,
    routeSettings: routeSettings,
    isDismissible: barrierDismissible,
    enableDrag: barrierDismissible,
    backgroundColor: Colors.transparent,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: builder(ctx),
    ),
  );
}

/// [AlertDialog] on desktop, [AppSheet] on a phone — the same `title`,
/// `content`, `actions` API, so converting a call site is a class rename
/// plus `showDialog` → [showAppDialog]. Desktop output is byte-for-byte the
/// AlertDialog it replaces.
class AppDialog extends StatelessWidget {
  const AppDialog({
    super.key,
    this.title,
    this.content,
    this.actions,
    this.icon,
    this.scrollable = false,
    this.contentPadding,
    this.actionsAlignment,
    this.shape,
    this.backgroundColor,
    this.titleTextStyle,
    this.contentTextStyle,
  });

  final Widget? title;
  final Widget? content;
  final List<Widget>? actions;
  final Widget? icon;
  final bool scrollable;
  final EdgeInsetsGeometry? contentPadding;
  final MainAxisAlignment? actionsAlignment;
  final ShapeBorder? shape;
  final Color? backgroundColor;
  final TextStyle? titleTextStyle;
  final TextStyle? contentTextStyle;

  @override
  Widget build(BuildContext context) {
    if (!_rendersAsSheet(context)) {
      return AlertDialog(
        title: title,
        content: content,
        actions: actions,
        icon: icon,
        scrollable: scrollable,
        contentPadding: contentPadding,
        actionsAlignment: actionsAlignment,
        shape: shape,
        backgroundColor: backgroundColor,
        titleTextStyle: titleTextStyle,
        contentTextStyle: contentTextStyle,
      );
    }
    return AppSheet(
      title: title,
      leading: icon,
      actions: actions ?? const [],
      child: content ?? const SizedBox.shrink(),
    );
  }
}

/// Bottom-sheet body used on phones wherever desktop shows a dialog: a
/// grab handle, an optional icon/title row, the content in its own scroll
/// view (capped at 90% of the screen so the handle stays reachable) and the
/// actions wrapped at the foot so three buttons never overflow.
///
/// Pair with `showModalBottomSheet(isScrollControlled: true,
/// backgroundColor: Colors.transparent, useSafeArea: true)` — or simply
/// [showAppDialog], which does exactly that on a phone.
class AppSheet extends StatelessWidget {
  const AppSheet({
    super.key,
    required this.child,
    this.title,
    this.icon,
    this.leading,
    this.actions = const [],
    this.accent,
    this.padding = const EdgeInsets.fromLTRB(
      AppSpacing.lg,
      AppSpacing.sm,
      AppSpacing.lg,
      AppSpacing.lg,
    ),
  });

  final Widget child;
  final Widget? title;

  /// Tinted square icon, as on [GlassDialog]. [leading] wins when both are
  /// given (it is the AlertDialog `icon` slot, any widget).
  final IconData? icon;
  final Widget? leading;
  final List<Widget> actions;
  final Color? accent;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final tint = accent ?? s.accent;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.9;
    Widget? head;
    if (title != null || icon != null || leading != null) {
      head = Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.xs,
          AppSpacing.lg,
          AppSpacing.sm,
        ),
        child: Row(
          children: [
            if (leading != null) ...[
              IconTheme.merge(
                data: IconThemeData(color: tint, size: 24),
                child: leading!,
              ),
              const SizedBox(width: AppSpacing.md),
            ] else if (icon != null) ...[
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      tint,
                      Color.alphaBlend(
                          Colors.white.withValues(alpha: 0.30), tint),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                ),
                child: Icon(icon, color: Colors.white, size: 18),
              ),
              const SizedBox(width: AppSpacing.md),
            ],
            if (title != null)
              Expanded(
                child: DefaultTextStyle.merge(
                  style: AppTypography.sectionTitle.copyWith(color: s.ink),
                  child: title!,
                ),
              ),
          ],
        ),
      );
    }
    return SafeArea(
      top: false,
      child: Container(
        width: double.infinity,
        constraints: BoxConstraints(maxHeight: maxHeight),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: s.canvas,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppSpacing.radiusXl),
          ),
          border: Border.all(color: s.edge),
          boxShadow: s.panelShadow,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(
                  top: AppSpacing.sm,
                  bottom: AppSpacing.sm,
                ),
                decoration: BoxDecoration(
                  color: s.edgeStrong,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            ?head,
            Flexible(
              child: SingleChildScrollView(
                padding: padding,
                child: DefaultTextStyle.merge(
                  style: AppTypography.body.copyWith(color: s.inkSecondary),
                  child: child,
                ),
              ),
            ),
            if (actions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  0,
                  AppSpacing.lg,
                  AppSpacing.lg,
                ),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: actions,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
