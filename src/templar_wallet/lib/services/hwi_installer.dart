// Automatic installer for the HWI (Hardware Wallet Interface) toolkit.
//
// Downloads the official standalone binary from bitcoin-core/HWI GitHub
// releases — the SAME mechanism on macOS, Windows, and Linux (only the asset
// name differs per OS/arch). The binary is verified against the release's
// SHA256SUMS, extracted into `<dataDir>/hwi/`, and activated in the running
// backend via `setHwiPath` (no restart needed). On the next launch the Rust
// side finds it by itself (`<data_dir>/hwi/` is a resolution candidate).

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../bridge/wallet_bridge.dart';

/// Progress phases surfaced to the install UI.
enum HwiInstallPhase { resolving, downloading, verifying, extracting, activating }

/// Metadata of the release asset that matches this machine.
class HwiReleaseInfo {
  const HwiReleaseInfo({
    required this.version,
    required this.assetName,
    required this.assetUrl,
    required this.sizeBytes,
    required this.sumsUrl,
  });

  final String version;
  final String assetName;
  final String assetUrl;
  final int sizeBytes;

  /// URL of the SHA256SUMS.txt.asc asset (clear-signed checksum list).
  final String? sumsUrl;

  String get sizeDisplay {
    final mb = sizeBytes / (1024 * 1024);
    return '${mb.toStringAsFixed(mb >= 20 ? 0 : 1)} MB';
  }
}

class HwiInstaller {
  HwiInstaller({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const _releaseApi =
      'https://api.github.com/repos/bitcoin-core/HWI/releases/latest';

  /// Asset name fragment for this OS + architecture, e.g. "mac-arm64".
  /// Same resolution logic everywhere — only the fragment differs.
  static String platformTag() {
    final v = Platform.version.toLowerCase();
    final isArm = v.contains('arm64') || v.contains('aarch64');
    if (Platform.isMacOS) return isArm ? 'mac-arm64' : 'mac-x86_64';
    if (Platform.isLinux) return isArm ? 'linux-aarch64' : 'linux-x86_64';
    if (Platform.isWindows) return 'windows-x86_64';
    throw UnsupportedError('No HWI build for ${Platform.operatingSystem}');
  }

  /// Query GitHub for the latest release and pick this machine's asset.
  Future<HwiReleaseInfo> resolveLatest() async {
    final resp = await _client.get(
      Uri.parse(_releaseApi),
      headers: {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'templar-wallet',
      },
    ).timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) {
      throw Exception('GitHub API error ${resp.statusCode} — check your connection');
    }
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    final version = (json['tag_name'] as String?) ?? 'unknown';
    final assets = (json['assets'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>();

    final tag = platformTag();
    final asset = assets.firstWhere(
      (a) => (a['name'] as String? ?? '').contains(tag),
      orElse: () => throw Exception('No HWI $version build for $tag'),
    );
    final sums = assets.where((a) =>
        (a['name'] as String? ?? '').toUpperCase().startsWith('SHA256SUMS'));

    return HwiReleaseInfo(
      version: version,
      assetName: asset['name'] as String,
      assetUrl: asset['browser_download_url'] as String,
      sizeBytes: (asset['size'] as num?)?.toInt() ?? 0,
      sumsUrl: sums.isEmpty
          ? null
          : sums.first['browser_download_url'] as String,
    );
  }

  /// Download, verify, extract, and activate HWI. Returns the binary path.
  ///
  /// [onProgress] gets the current phase plus download progress in 0..1
  /// (only meaningful during [HwiInstallPhase.downloading]).
  Future<String> install({
    required WalletBridge bridge,
    HwiReleaseInfo? release,
    void Function(HwiInstallPhase phase, double progress)? onProgress,
  }) async {
    onProgress?.call(HwiInstallPhase.resolving, 0);
    release ??= await resolveLatest();

    // Stream the download so big assets (up to ~90 MB on Linux) show progress.
    onProgress?.call(HwiInstallPhase.downloading, 0);
    final req = http.Request('GET', Uri.parse(release.assetUrl))
      ..headers['User-Agent'] = 'templar-wallet';
    final streamed =
        await _client.send(req).timeout(const Duration(seconds: 30));
    if (streamed.statusCode != 200) {
      throw Exception('Download failed (HTTP ${streamed.statusCode})');
    }
    final total = streamed.contentLength ?? release.sizeBytes;
    final bytes = <int>[];
    // Per-chunk timeout: a stalled connection must error out, not hang the
    // install dialog forever.
    await for (final chunk in streamed.stream
        .timeout(const Duration(seconds: 60))) {
      bytes.addAll(chunk);
      if (total > 0) {
        onProgress?.call(HwiInstallPhase.downloading, bytes.length / total);
      }
    }

    onProgress?.call(HwiInstallPhase.verifying, 1);
    await _verifySha256(release, bytes);

    onProgress?.call(HwiInstallPhase.extracting, 1);
    final exeName = Platform.isWindows ? 'hwi.exe' : 'hwi';
    final exeBytes = _extractBinary(release.assetName, bytes, exeName);

    final dataDir = await bridge.getDataDir();
    final outDir = Directory('$dataDir${Platform.pathSeparator}hwi');
    await outDir.create(recursive: true);
    final outPath = '${outDir.path}${Platform.pathSeparator}$exeName';
    await File(outPath).writeAsBytes(exeBytes, flush: true);
    if (!Platform.isWindows) {
      await Process.run('chmod', ['+x', outPath]);
    }
    // macOS quarantine is stripped by the backend inside `setHwiPath` below,
    // via removexattr(2). Not done here: /usr/bin/xattr is itself a script,
    // and shelling out to it fails in exactly the sandboxed environment that
    // needs the attribute gone.

    onProgress?.call(HwiInstallPhase.activating, 1);
    await bridge.setHwiPath(outPath);
    return outPath;
  }

  /// Check the archive hash against the release's SHA256SUMS list.
  /// The `.asc` file is a clear-signed text: checksum lines survive as
  /// `<hex>  <filename>` between the PGP armor blocks.
  Future<void> _verifySha256(HwiReleaseInfo release, List<int> bytes) async {
    final sumsUrl = release.sumsUrl;
    if (sumsUrl == null) {
      throw Exception('Release has no SHA256SUMS — refusing to install');
    }
    final resp = await _client
        .get(Uri.parse(sumsUrl), headers: {'User-Agent': 'templar-wallet'})
        .timeout(const Duration(seconds: 20));
    if (resp.statusCode != 200) {
      throw Exception('Could not fetch SHA256SUMS (HTTP ${resp.statusCode})');
    }
    String? expected;
    for (final line in resp.body.split('\n')) {
      final t = line.trim();
      if (t.endsWith(release.assetName)) {
        expected = t.split(RegExp(r'\s+')).first.toLowerCase();
        break;
      }
    }
    if (expected == null || expected.length != 64) {
      throw Exception('No checksum for ${release.assetName} in SHA256SUMS');
    }
    final actual = sha256.convert(bytes).toString();
    if (actual != expected) {
      throw Exception(
          'Checksum mismatch for ${release.assetName} — download corrupted or tampered');
    }
  }

  /// Pull the `hwi` executable out of the release archive
  /// (tar.gz on POSIX, zip on Windows).
  List<int> _extractBinary(String assetName, List<int> bytes, String exeName) {
    final Archive archive;
    if (assetName.endsWith('.tar.gz') || assetName.endsWith('.tgz')) {
      archive = TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes));
    } else if (assetName.endsWith('.zip')) {
      archive = ZipDecoder().decodeBytes(bytes);
    } else {
      throw Exception('Unknown archive format: $assetName');
    }
    for (final f in archive) {
      final base = f.name.split('/').last.split('\\').last;
      if (f.isFile && base == exeName) {
        return f.content as List<int>;
      }
    }
    throw Exception('$exeName not found inside $assetName');
  }
}
