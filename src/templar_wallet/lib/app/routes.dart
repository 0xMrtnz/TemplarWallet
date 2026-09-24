abstract final class AppRoutes {
  static const String walletPicker = '/';
  static const String welcome = '/welcome';
  static const String dashboard = '/dashboard';
  static const String send = '/send';
  static const String receive = '/receive';
  /// Every address a chain has handed out, with what each received. Receive
  /// shows the last eight and sends the rest here (`?asset=BTC|LBTC`).
  static const String receiveAddresses = '/receive/addresses';
  static const String history = '/history';
  static const String utxos = '/utxos';
  static const String walletInfo = '/wallet-info';
  static const String cosign = '/cosign';
  static const String liquid = '/liquid';
  static const String swap = '/swap';
  static const String peg = '/peg';
  static const String issueAsset = '/liquid/issue';
  static const String reissueAsset = '/liquid/reissue';
  static const String burnAsset = '/liquid/burn';
  static const String assetOperations = '/asset-ops';
  static const String settings = '/settings';
  /// Settings sections as routes of their own. On a phone the settings root
  /// is a list and each section is a sub-page the header's back arrow (and
  /// the system back) returns from; on desktop they open the two-pane
  /// settings on that section.
  static const String settingsNetwork = '/settings/network';
  static const String settingsSecurity = '/settings/security';
  static const String settingsAppearance = '/settings/appearance';
  static const String settingsAbout = '/settings/about';
  /// Templar Protocol: readiness, the paste box, connected sites, what was
  /// signed, and the wallet that answers.
  static const String settingsProtocol = '/settings/protocol';
  /// `templar://` request handler (Templar Protocol connect / sign). Outside the
  /// wallet shell: a link may arrive before any wallet is open.
  static const String protocol = '/protocol';
  static const String walletType = '/wallet-type';
  static const String createWallet = '/create-wallet';
  static const String hardwareSetup = '/setup/hardware';
  static const String airgapSetup = '/setup/airgap';
  static const String multisigSetup = '/setup/multisig';
  static const String watchOnlySetup = '/setup/watch-only';
  static const String importWallet = '/import-wallet';
  static const String designSystem = '/dev/design';
}

// Navigation group definitions for the sidebar.
class NavSection {
  const NavSection({required this.label, required this.items});
  final String label;
  final List<NavItem> items;
}

class NavItem {
  const NavItem({required this.route, required this.labelKey, required this.icon});
  final String route;
  final String labelKey;
  final Object icon;
}
