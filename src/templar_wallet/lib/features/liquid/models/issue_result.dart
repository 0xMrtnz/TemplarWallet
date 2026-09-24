class IssueResult {
  const IssueResult({
    required this.assetId,
    this.tokenId,
    required this.txid,
    required this.registryRegistered,
    required this.proofUrl,
    required this.proofContent,
  });

  final String assetId;
  final String? tokenId;
  final String txid;
  final bool registryRegistered;
  final String proofUrl;
  final String proofContent;
}
