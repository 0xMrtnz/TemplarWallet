import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Opens this app's page in the system Settings — the only place a camera
/// permission denied with "don't ask again" can be granted. Android only;
/// elsewhere it returns false and the caller keeps its written directions.
abstract final class AppSettingsLauncher {
  static const _channel = MethodChannel('dev.templarwallet/system');

  static bool get supported => Platform.isAndroid;

  static Future<bool> open() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('openAppSettings') ?? false;
    } catch (e) {
      debugPrint('AppSettingsLauncher: $e');
      return false;
    }
  }
}
