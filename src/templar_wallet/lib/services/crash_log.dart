import 'dart:io';

import 'package:flutter/foundation.dart';

/// Last-resort persistent logging. A crash on a tester's machine (especially
/// Windows, where nothing captures stderr) must leave an artifact we can ask
/// for — otherwise "the app closed by itself" is the whole bug report.
///
/// Writes to `<data dir>/templar_wallet/logs/templar.log`, rotating once at 1 MB
/// (`templar.log.1`). Never throws: logging must not be able to break the app.
class CrashLog {
  CrashLog._();
  static final CrashLog instance = CrashLog._();

  static const _maxBytes = 1024 * 1024;
  File? _file;

  /// [dataDir] overrides the platform default — Android passes its
  /// app-private support dir, which no environment variable can name.
  Future<void> init({String? dataDir}) async {
    try {
      final base = dataDir ?? _defaultDataDir();
      if (base == null) return;
      final dir = Directory('$base/logs');
      await dir.create(recursive: true);
      final f = File('${dir.path}/templar.log');
      if (await f.exists() && (await f.length()) > _maxBytes) {
        final old = File('${dir.path}/templar.log.1');
        if (await old.exists()) await old.delete();
        await f.rename(old.path);
      }
      _file = File('${dir.path}/templar.log');
      write('app start ${DateTime.now().toIso8601String()} '
          '(${Platform.operatingSystem} ${Platform.operatingSystemVersion})');
    } catch (_) {
      // Logging is best-effort by design.
    }
  }

  /// Mirrors the Rust side's data-dir resolution (state.rs): platform data
  /// dir + `templar_wallet`, overridable via TEMPLAR_DATA_DIR.
  String? _defaultDataDir() {
    final env = Platform.environment['TEMPLAR_DATA_DIR'];
    if (env != null && env.trim().isNotEmpty) return env;
    final home = Platform.environment['HOME'];
    if (Platform.isMacOS && home != null) {
      return '$home/Library/Application Support/templar_wallet';
    }
    if (Platform.isLinux && home != null) {
      final xdg = Platform.environment['XDG_DATA_HOME'];
      final base = (xdg != null && xdg.isNotEmpty) ? xdg : '$home/.local/share';
      return '$base/templar_wallet';
    }
    if (Platform.isWindows) {
      final roaming = Platform.environment['APPDATA'];
      if (roaming != null) return '$roaming\\templar_wallet';
    }
    return null;
  }

  void write(String line) {
    try {
      _file?.writeAsStringSync(
        '[${DateTime.now().toIso8601String()}] $line\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {}
  }

  void error(Object error, StackTrace? stack) {
    write('ERROR: $error');
    if (stack != null) write(stack.toString());
    if (kDebugMode) debugPrint('CrashLog: $error');
  }
}
