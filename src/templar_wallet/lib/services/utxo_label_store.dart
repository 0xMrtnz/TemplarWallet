import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Persists per-outpoint UTXO labels to `<appSupport>/utxo_labels.json`.
class UtxoLabelStore {
  UtxoLabelStore._();
  static final UtxoLabelStore instance = UtxoLabelStore._();

  Map<String, String>? _cache;

  Future<File> get _file async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/utxo_labels.json');
  }

  Future<Map<String, String>> _load() async {
    if (_cache != null) return _cache!;
    try {
      final f = await _file;
      if (await f.exists()) {
        final raw = json.decode(await f.readAsString()) as Map<String, dynamic>;
        _cache = raw.map((k, v) => MapEntry(k, v as String));
      } else {
        _cache = {};
      }
    } catch (_) {
      _cache = {};
    }
    return _cache!;
  }

  Future<void> _save() async {
    final f = await _file;
    await f.writeAsString(json.encode(_cache));
  }

  Future<String?> getLabel(String outpoint) async {
    final map = await _load();
    return map[outpoint];
  }

  Future<Map<String, String>> getAllLabels() async => _load();

  Future<void> setLabel(String outpoint, String label) async {
    final map = await _load();
    if (label.isEmpty) {
      map.remove(outpoint);
    } else {
      map[outpoint] = label;
    }
    await _save();
  }

  Future<void> removeLabel(String outpoint) async {
    final map = await _load();
    map.remove(outpoint);
    await _save();
  }
}
