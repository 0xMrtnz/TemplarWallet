// The Android system back, inside the wallet shell.
//
// Every in-shell navigation is a `context.go` — no route is ever pushed — so
// the platform back button reaches the shell route with nothing to pop. The
// shell answers it (see MobileShell): back inside a section returns to the
// Dashboard, back on the Dashboard leaves the app. A screen with its own
// notion of "back" — the Send wizard stepping to the previous page — claims
// the press first by registering a handler here.

import 'dart:async';

import 'package:flutter/foundation.dart';

/// Returns true when the press was consumed.
typedef BackHandlerCallback = bool Function();

/// Registry of screens that want first refusal on the system back.
///
/// Listeners (the shell's `PopScope`) are told when the set of handlers
/// changes, a microtask later — screens register from `initState`, which
/// runs in the middle of a build, and an ancestor may not be marked dirty
/// from there.
class BackHandler extends ChangeNotifier {
  BackHandler._();

  static final BackHandler instance = BackHandler._();

  final List<BackHandlerCallback> _handlers = <BackHandlerCallback>[];
  bool _notifyQueued = false;

  /// Whether any screen currently claims the back press.
  bool get hasHandlers => _handlers.isNotEmpty;

  /// Register [handler]. The most recently registered handler is asked first.
  void push(BackHandlerCallback handler) {
    _handlers.add(handler);
    _queueNotify();
  }

  /// Unregister [handler]. Safe to call for a handler that is not registered.
  void remove(BackHandlerCallback handler) {
    if (_handlers.remove(handler)) _queueNotify();
  }

  /// Offer the press to the handlers, newest first. True when one took it.
  bool dispatch() {
    for (final handler in _handlers.reversed.toList(growable: false)) {
      if (handler()) return true;
    }
    return false;
  }

  void _queueNotify() {
    if (_notifyQueued) return;
    _notifyQueued = true;
    scheduleMicrotask(() {
      _notifyQueued = false;
      notifyListeners();
    });
  }
}
