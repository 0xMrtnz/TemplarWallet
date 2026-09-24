import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Keeps seed words and private keys out of screenshots and the recents
/// thumbnail on Android (`FLAG_SECURE` on the activity window). A no-op on
/// every other platform. Reference counted: nested secure screens release
/// the flag only when the last one goes.
abstract final class ScreenSecurity {
  static const _channel = MethodChannel('dev.templarwallet/screen');
  static int _holders = 0;

  static Future<void> _apply(bool on) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('setSecure', {'on': on});
    } catch (e) {
      debugPrint('ScreenSecurity: $e');
    }
  }

  static Future<void> acquire() async {
    _holders++;
    if (_holders == 1) await _apply(true);
  }

  static Future<void> release() async {
    if (_holders == 0) return;
    _holders--;
    if (_holders == 0) await _apply(false);
  }
}

/// Wrap the subtree that shows secret material; the window is secure for as
/// long as it is mounted.
class SecureScreen extends StatefulWidget {
  const SecureScreen({super.key, required this.child});
  final Widget child;

  @override
  State<SecureScreen> createState() => _SecureScreenState();
}

class _SecureScreenState extends State<SecureScreen> {
  @override
  void initState() {
    super.initState();
    ScreenSecurity.acquire();
  }

  @override
  void dispose() {
    ScreenSecurity.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
