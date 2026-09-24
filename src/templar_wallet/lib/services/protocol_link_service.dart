import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

/// Receives `templar://` links from the OS (the link that launched the app,
/// and links arriving while it runs) and hands them to the app once it is
/// ready to act on them.
///
/// Links can arrive before the wallet storage is unlocked or the PIN is
/// entered; [arm] is called by the app root only once the router is live,
/// and whatever came in before is delivered then. Only the latest pending
/// link is kept — a burst of clicks is one request, not several.
class ProtocolLinkService {
  ProtocolLinkService._();
  static final ProtocolLinkService instance = ProtocolLinkService._();

  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _sub;
  bool _started = false;
  Uri? _pending;
  void Function(Uri link)? _handler;

  /// Last link delivered and when, to fold the initial-link + stream
  /// duplicate some platforms produce into one delivery.
  String? _lastDelivered;
  DateTime? _lastDeliveredAt;

  /// Starts listening. Safe to call more than once.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) _receive(initial);
    } catch (e) {
      debugPrint('[protocol] initial link: $e');
    }
    _sub = _appLinks.uriLinkStream.listen(
      _receive,
      onError: (Object e) => debugPrint('[protocol] link stream: $e'),
    );
  }

  /// Registers the handler and flushes a link that arrived earlier.
  void arm(void Function(Uri link) handler) {
    _handler = handler;
    final pending = _pending;
    _pending = null;
    if (pending != null) handler(pending);
  }

  void disarm() {
    _handler = null;
  }

  /// Feeds a link as if the OS delivered it (a pasted link, or a test).
  void inject(Uri link) => _receive(link);

  void _receive(Uri uri) {
    if (uri.scheme.toLowerCase() != 'templar') return;
    final text = uri.toString();
    final now = DateTime.now();
    if (_lastDelivered == text &&
        _lastDeliveredAt != null &&
        now.difference(_lastDeliveredAt!) < const Duration(seconds: 3)) {
      return;
    }
    _lastDelivered = text;
    _lastDeliveredAt = now;
    final handler = _handler;
    if (handler != null) {
      handler(uri);
    } else {
      _pending = uri;
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    _started = false;
  }
}
