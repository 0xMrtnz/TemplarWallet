import '../../wallet_picker/models/wallet_summary.dart';

/// Whether a wallet can answer a Templar Protocol request, and why not when it cannot.
///
/// One rule, two readers: the request screen filters the chooser with it, and
/// Settings › Templar Protocol offers the same wallets as the preferred one. A
/// second copy of the rule would eventually offer a wallet the request screen
/// refuses.
///
/// Connect needs the escrow key at `m/2121'/1'/0'`, which only a software
/// seed derives today; signing also accepts a Jade, which can sign a PSET
/// whose inputs name its own key.
bool protocolWalletFits(WalletSummary w, {required bool connect}) {
  if (!w.liquidEnabled || w.isViewOnlyWallet || w.isAirgapWallet) return false;
  if (w.type != WalletType.singlesig) return false;
  if (w.isHardwareWallet) {
    final jade = (w.deviceModel ?? '').toLowerCase().contains('jade');
    return !connect && jade;
  }
  return true;
}
