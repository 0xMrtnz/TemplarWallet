import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class WalletCustomization {
  final String walletId;
  final String? nameOverride;
  final int? accentColor; // ARGB int
  final String? passwordHash; // SHA-256 hex of user password; null = no lock

  const WalletCustomization({
    required this.walletId,
    this.nameOverride,
    this.accentColor,
    this.passwordHash,
  });

  WalletCustomization copyWith({
    String? nameOverride,
    int? accentColor,
    Object? passwordHash = _sentinel,
  }) =>
      WalletCustomization(
        walletId: walletId,
        nameOverride: nameOverride ?? this.nameOverride,
        accentColor: accentColor ?? this.accentColor,
        passwordHash: passwordHash == _sentinel
            ? this.passwordHash
            : passwordHash as String?,
      );

  static const _sentinel = Object();
}

class WalletCustomizationStore {
  static final WalletCustomizationStore instance = WalletCustomizationStore._();
  WalletCustomizationStore._();

  static const _prefix = 'wallet_custom_v1_';

  Future<WalletCustomization> load(String walletId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_prefix$walletId');
    if (raw == null) return WalletCustomization(walletId: walletId);
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return WalletCustomization(
      walletId: walletId,
      nameOverride: m['name'] as String?,
      accentColor: m['color'] as int?,
      passwordHash: m['password_hash'] as String?,
    );
  }

  Future<void> save(WalletCustomization c) async {
    final prefs = await SharedPreferences.getInstance();
    final m = <String, dynamic>{};
    if (c.nameOverride != null) m['name'] = c.nameOverride;
    if (c.accentColor != null) m['color'] = c.accentColor;
    if (c.passwordHash != null) m['password_hash'] = c.passwordHash;
    await prefs.setString('$_prefix${c.walletId}', jsonEncode(m));
  }

  Future<void> delete(String walletId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_prefix$walletId');
  }

  /// Returns the SHA-256 hex hash of [password].
  static String hashPassword(String password) =>
      sha256.convert(utf8.encode(password)).toString();

  /// True when [input] matches the stored hash.
  static bool verifyPassword(String input, String storedHash) =>
      hashPassword(input) == storedHash;

  // ── Palette of accent colors users can pick from ──────────────────────────

  static const List<Color> palette = [
    Color(0xFFC1121F), // Templar crimson (brand default)
    Color(0xFF3B82F6), // Blue
    Color(0xFF10B981), // Emerald
    Color(0xFFF59E0B), // Amber
    Color(0xFF6C63FF), // Indigo
    Color(0xFF8B5CF6), // Violet
    Color(0xFFEC4899), // Pink
    Color(0xFF06B6D4), // Cyan
    Color(0xFF84CC16), // Lime
    Color(0xFFF97316), // Orange
  ];
}
