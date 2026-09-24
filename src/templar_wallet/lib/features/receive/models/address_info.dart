class AddressInfo {
  const AddressInfo({
    required this.address,
    required this.index,
    required this.asset,
    this.label,
    this.receivedSats = 0,
    this.derivationPath,
  });

  final String address;
  final int index;
  final String asset;
  final String? label;
  final int receivedSats;
  final String? derivationPath;
}
