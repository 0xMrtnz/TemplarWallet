import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Getting a file out of, or into, the wallet on every platform.
///
/// Desktop has native save/open dialogs (file_selector). Android has no
/// "save as": file_selector_android implements only openFile/openFiles/
/// getDirectoryPath, so `getSaveLocation` throws UnimplementedError there.
/// The phone-native equivalent is the system share sheet — the user picks
/// Files, Drive, a messenger or another wallet — which is what [saveOrShare]
/// does on Android after writing the bytes to the app cache.
///
/// Importing: Android maps extensions to MIME types and has no mapping for
/// `.psbt`/`.pset`, so a picker limited to those shows nothing selectable.
/// [pickFile] therefore accepts any file on Android and leaves validation to
/// the caller (which has to parse the bytes anyway).
abstract final class FileExport {
  static bool get _usesShareSheet => Platform.isAndroid || Platform.isIOS;

  /// Saves [bytes] under [suggestedName] through the platform's native path.
  /// Returns the destination path on desktop, `'shared'` on a phone once the
  /// share sheet was actually used, or `null` when the user cancelled.
  /// Throws on I/O failure; callers surface that as they do today.
  static Future<String?> saveOrShare(
    BuildContext context, {
    required String suggestedName,
    required Uint8List bytes,
    required String mimeType,
    List<XTypeGroup> acceptedTypeGroups = const [],
    String? shareTitle,
  }) async {
    // The share sheet is anchored to the invoking widget on tablets (iPad
    // popover rule); harmless elsewhere. Read before the first await so the
    // context is not used across an async gap.
    Rect? origin;
    final box = context.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      origin = box.localToGlobal(Offset.zero) & box.size;
    }
    if (!_usesShareSheet) {
      final location = await getSaveLocation(
        suggestedName: suggestedName,
        acceptedTypeGroups: acceptedTypeGroups,
      );
      if (location == null) return null;
      await File(location.path).writeAsBytes(bytes, flush: true);
      return location.path;
    }
    final dir = await getTemporaryDirectory();
    final exportDir = Directory('${dir.path}/export');
    await exportDir.create(recursive: true);
    final file = File('${exportDir.path}/$suggestedName');
    await file.writeAsBytes(bytes, flush: true);
    final result = await SharePlus.instance.share(ShareParams(
      files: [XFile(file.path, mimeType: mimeType, name: suggestedName)],
      title: shareTitle ?? suggestedName,
      sharePositionOrigin: origin,
    ));
    return result.status == ShareResultStatus.dismissed ? null : 'shared';
  }

  /// [saveOrShare] for a text payload (PSBT base64, PSET, JSON, logs).
  static Future<String?> saveOrShareText(
    BuildContext context, {
    required String suggestedName,
    required String text,
    String mimeType = 'text/plain',
    List<XTypeGroup> acceptedTypeGroups = const [],
    String? shareTitle,
  }) =>
      saveOrShare(
        context,
        suggestedName: suggestedName,
        bytes: Uint8List.fromList(text.codeUnits),
        mimeType: mimeType,
        acceptedTypeGroups: acceptedTypeGroups,
        shareTitle: shareTitle,
      );

  /// Opens the platform file picker. Desktop filters by [extensions];
  /// Android shows every file (see the class doc) so the caller must
  /// validate the content. Returns `null` when the user cancelled.
  static Future<XFile?> pickFile({
    required String label,
    required List<String> extensions,
    List<String>? uniformTypeIdentifiers,
    List<String>? mimeTypes,
  }) {
    final groups = _usesShareSheet
        ? const <XTypeGroup>[]
        : [
            XTypeGroup(
              label: label,
              extensions: extensions,
              uniformTypeIdentifiers: uniformTypeIdentifiers,
              mimeTypes: mimeTypes,
            ),
          ];
    return openFile(acceptedTypeGroups: groups);
  }

  /// True when the platform can only share, not save to a chosen path —
  /// for button labels ("Share .psbt" instead of "Save .psbt file").
  static bool get sharesInsteadOfSaves => _usesShareSheet;
}
