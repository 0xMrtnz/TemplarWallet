// What a co-signer is called in this app, and how it is drawn.
//
// A multisig key identifies itself as `[f0b68896/48'/1'/0'/2']tpub…`, which
// says nothing about whose key it is or where it lives. The label is the part
// a person can actually use: "Jade in the safe", "Anna's phone", "office
// laptop". It is presentation only — never part of a descriptor, never sent
// anywhere — so it can be changed at any time without touching the wallet.

import 'package:flutter/material.dart';

/// One co-signer's name, glyph and colour.
@immutable
class CosignerLabel {
  const CosignerLabel({
    required this.id,
    this.name,
    this.iconId,
    this.colorValue,
    this.hardware,
  });

  /// Which co-signer this describes — see [cosignerId]. Stable across renames
  /// and across a descriptor rebuild, which preserves fingerprints.
  final String id;

  /// What the user called it. Null or empty falls back to "Key N".
  final String? name;

  /// Key into [cosignerIcons]. Unknown or null ids draw [defaultCosignerIcon],
  /// so a catalogue entry can be retired without breaking stored labels.
  final String? iconId;

  /// ARGB value from [cosignerColors]. Null takes the wallet's accent.
  final int? colorValue;

  /// This key signs on a USB hardware wallet — a Ledger, a Jade. Decides
  /// whether a hand-off sheet offers "Sign with USB hardware wallet".
  ///
  /// Null means nobody said: see [isHardware] for what is assumed then. The
  /// wizard sets it for a key read over USB; the label editor lets the user
  /// set or clear it for any key.
  final bool? hardware;

  IconData get icon => cosignerIcons[iconId] ?? defaultCosignerIcon;

  /// Whether to treat this key as living on a USB device. An explicit answer
  /// wins; without one, a key wearing the USB stick or the Jade shield — the
  /// icons the wizard hands to keys it read over USB — counts as hardware, so
  /// wallets labelled before the flag existed keep working.
  bool get isHardware => hardware ?? (iconId == 'usb' || iconId == 'shield');

  Color? get color => colorValue == null ? null : Color(colorValue!);

  /// The name to show, given the co-signer's position in the wallet.
  String displayName(int index) {
    final n = name?.trim() ?? '';
    return n.isEmpty ? 'Key ${index + 1}' : n;
  }

  bool get isEmpty =>
      (name?.trim().isEmpty ?? true) &&
      iconId == null &&
      colorValue == null &&
      hardware == null;

  CosignerLabel copyWith({
    Object? name = _sentinel,
    Object? iconId = _sentinel,
    Object? colorValue = _sentinel,
    Object? hardware = _sentinel,
  }) =>
      CosignerLabel(
        id: id,
        name: name == _sentinel ? this.name : name as String?,
        iconId: iconId == _sentinel ? this.iconId : iconId as String?,
        colorValue:
            colorValue == _sentinel ? this.colorValue : colorValue as int?,
        hardware: hardware == _sentinel ? this.hardware : hardware as bool?,
      );

  Map<String, dynamic> toJson() => {
        if (name != null && name!.trim().isNotEmpty) 'name': name!.trim(),
        if (iconId != null) 'icon': iconId,
        if (colorValue != null) 'color': colorValue,
        if (hardware != null) 'hw': hardware,
      };

  factory CosignerLabel.fromJson(String id, Map<String, dynamic> j) =>
      CosignerLabel(
        id: id,
        name: j['name'] as String?,
        iconId: j['icon'] as String?,
        colorValue: j['color'] as int?,
        hardware: j['hw'] as bool?,
      );

  static const _sentinel = Object();
}

/// Identifies a co-signer for labelling purposes.
///
/// The master fingerprint, which is what a signing device knows itself by and
/// what survives the descriptor being rebuilt from the keys. Two accounts of
/// one seed can share a fingerprint, so the position is appended when the
/// wallet actually contains a repeat — a label would otherwise follow both.
String cosignerId(List<String> cosignerKeys, int index) {
  final fp = fingerprintOf(cosignerKeys[index]);
  if (fp.isEmpty) return 'i$index';
  final repeats = cosignerKeys.where((k) => fingerprintOf(k) == fp).length;
  return repeats > 1 ? '$fp:$index' : fp;
}

/// The `f0b68896` out of `[f0b68896/48'/1'/0'/2']tpub…`. Empty when the key
/// carries no origin — impossible for a wallet built after the keys were
/// checked, but old wallets predate that.
String fingerprintOf(String cosignerKey) {
  final open = cosignerKey.indexOf('[');
  if (open < 0) return '';
  final end = cosignerKey.indexOf(']', open);
  if (end < 0) return '';
  return cosignerKey.substring(open + 1, end).split('/').first.toLowerCase();
}

/// The account path out of a keyorigin key, without the leading `m/`.
String pathOf(String cosignerKey) {
  final open = cosignerKey.indexOf('[');
  final end = cosignerKey.indexOf(']', open + 1);
  if (open < 0 || end < 0) return '';
  final origin = cosignerKey.substring(open + 1, end);
  final slash = origin.indexOf('/');
  return slash < 0 ? '' : origin.substring(slash + 1);
}

/// Glyphs a co-signer can be given.
///
/// Deliberately small and concrete: every entry answers "where does this key
/// live", which is the thing a person needs to tell two keys apart under
/// pressure. Ids are stored, so entries may be added but never renamed.
const Map<String, IconData> cosignerIcons = {
  'shield': Icons.shield_outlined,
  'phone': Icons.smartphone_rounded,
  'laptop': Icons.laptop_mac_rounded,
  'desktop': Icons.desktop_windows_rounded,
  'usb': Icons.usb_rounded,
  'qr': Icons.qr_code_2_rounded,
  'key': Icons.vpn_key_rounded,
  'safe': Icons.lock_rounded,
  'bank': Icons.account_balance_rounded,
  'home': Icons.home_rounded,
  'work': Icons.work_outline_rounded,
  'person': Icons.person_outline_rounded,
  'group': Icons.groups_rounded,
  'star': Icons.star_outline_rounded,
  'paper': Icons.description_outlined,
  'cloud': Icons.cloud_outlined,
};

/// Drawn for a co-signer with no icon of its own, and for an id that is no
/// longer in the catalogue.
const IconData defaultCosignerIcon = Icons.vpn_key_rounded;

/// Colours a co-signer can be given. Chosen to stay legible on both the light
/// and the dark surface, and to be distinguishable from each other at the
/// 28 dp the ring draws them at.
const List<int> cosignerColors = [
  0xFFB3261E, // crimson — the app's own accent family
  0xFFD97706, // amber
  0xFF15803D, // green
  0xFF0E7490, // teal
  0xFF1D4ED8, // blue
  0xFF6D28D9, // violet
  0xFFBE185D, // magenta
  0xFF57534E, // stone
];

/// The icon a key's source suggests, so a slot starts with something better
/// than the default before anyone types a name.
String? suggestedIconFor({
  required bool fromDevice,
  required bool fromAppWallet,
  required bool isLocalSeed,
  String? deviceModel,
}) {
  if (fromDevice) {
    final model = (deviceModel ?? '').toLowerCase();
    if (model.contains('jade')) return 'shield';
    return 'usb';
  }
  if (fromAppWallet) return 'desktop';
  if (isLocalSeed) return 'key';
  return null;
}
