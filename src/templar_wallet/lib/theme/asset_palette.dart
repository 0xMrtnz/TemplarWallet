import 'package:flutter/material.dart';
import 'app_colors.dart';

/// Brand palette per asset chain. BTC → orange, everything Liquid → green.
/// Central source of truth so badges, logos and cards stay consistent.
class AssetPalette {
  const AssetPalette({
    required this.base,
    required this.light,
    required this.muted,
    required this.dark,
  });

  final Color base;
  final Color light;
  final Color muted;
  final Color dark;

  static const bitcoin = AssetPalette(
    base: AppColors.bitcoin,
    light: AppColors.bitcoinLight,
    muted: AppColors.bitcoinMuted,
    dark: AppColors.bitcoinDark,
  );

  static const liquid = AssetPalette(
    base: AppColors.liquid,
    light: AppColors.liquidLight,
    muted: AppColors.liquidMuted,
    dark: AppColors.liquidDark,
  );

  /// On-chain BTC is the only orange asset; LBTC and every token are Liquid.
  static bool isBitcoin(String ticker) => ticker.toUpperCase() == 'BTC';

  static AssetPalette forTicker(String ticker) =>
      isBitcoin(ticker) ? bitcoin : liquid;
}
