import 'dart:convert';
import 'dart:math' as math;

import 'wallet_bridge.dart';
import '../features/create_wallet/models/hw_device.dart';
import '../features/create_wallet/models/hw_import_result.dart';
import '../features/create_wallet/models/native_device.dart';
import '../features/psbt/models/psbt_inspection.dart';
import '../features/psbt/models/pset_inspection.dart';
import '../features/wallet_picker/models/wallet_summary.dart';
import '../features/dashboard/models/balance_history.dart';
import '../features/dashboard/models/dashboard_data.dart';
import '../features/receive/models/address_info.dart';
import '../features/history/models/transaction.dart';
import '../features/utxos/models/utxo.dart';
import '../features/wallet_info/models/wallet_info.dart';
import '../features/send/models/tx_preview.dart';
import '../features/liquid/models/issue_result.dart';
import '../features/swap/models/swap_offer.dart';
import '../features/peg/models/peg_models.dart';

class MockWalletBridge implements WalletBridge {
  @override
  Future<List<String>> generateMnemonic(int wordCount) async {
    await Future.delayed(const Duration(milliseconds: 200));
    const words = ['abandon', 'ability', 'able', 'about', 'above', 'absent',
      'absorb', 'abstract', 'absurd', 'abuse', 'access', 'accident',
      'account', 'accuse', 'achieve', 'acid', 'acoustic', 'acquire',
      'across', 'act', 'action', 'actor', 'actress', 'actual'];
    return words.sublist(0, wordCount);
  }

  @override
  Future<String> createWallet(String name, List<String> mnemonic, {bool liquid = false}) async {
    await Future.delayed(const Duration(milliseconds: 300));
    return 'mock-wallet-${DateTime.now().millisecondsSinceEpoch}';
  }

  @override
  Future<List<WalletSummary>> listWallets() async {
    await Future.delayed(const Duration(milliseconds: 400));
    return [
      WalletSummary(
        id: 'wallet-1',
        name: 'Primary',
        type: WalletType.singlesig,
        network: WalletNetwork.testnet,
        liquidEnabled: true,
        balanceSats: 1234567,
        txCount: 42,
        lastSyncAt: DateTime.now().subtract(const Duration(minutes: 3)),
      ),
      WalletSummary(
        id: 'wallet-2',
        name: 'Treasury 2-of-3',
        type: WalletType.multisig,
        network: WalletNetwork.testnet,
        balanceSats: 50000000,
        txCount: 8,
        lastSyncAt: DateTime.now().subtract(const Duration(hours: 1)),
      ),
      WalletSummary(
        id: 'wallet-3',
        name: 'Cold Storage',
        type: WalletType.watchOnly,
        network: WalletNetwork.testnet,
        balanceSats: 250000000,
        txCount: 5,
        lastSyncAt: DateTime.now().subtract(const Duration(days: 1)),
        isWatchOnly: true,
      ),
    ];
  }

  @override
  Future<void> openWallet(String walletId) async {
    await Future.delayed(const Duration(milliseconds: 200));
  }

  @override
  Future<DashboardData> getWalletSummary(String walletId) async {
    await Future.delayed(const Duration(milliseconds: 500));
    return DashboardData(
      walletId: walletId,
      walletName: 'Primary',
      totalBalanceDisplay: '0.01234567 BTC',
      syncState: 'synced',
      assets: const [
        AssetBalance(
          assetId: 'BTC',
          ticker: 'BTC',
          name: 'Bitcoin',
          amount: 1234567,
          displayAmount: '0.01234567 BTC',
          fiatEstimate: '\$1,200.00',
          status: 'synced',
          utxoCount: 3,
          isNative: true,
        ),
        AssetBalance(
          assetId: '144c654344aa716d6f3abcc1ca90e5641e4e2a7f633bc09fe3baf64585819a49',
          ticker: 'LBTC',
          name: 'Liquid Bitcoin',
          amount: 500000,
          displayAmount: '0.00500000 LBTC',
          fiatEstimate: '\$485.00',
          status: 'synced',
          utxoCount: 1,
          isNative: false,
        ),
        AssetBalance(
          assetId: 'b612eb46313a2cd6ebabd8b7a8eed5696e29898b87a43bff41c94f51acef9d73',
          ticker: 'USDT',
          name: 'Tether USD (Liquid)',
          amount: 100000000,
          displayAmount: '100.00 USDT',
          fiatEstimate: '\$100.00',
          status: 'third-party',
          utxoCount: 1,
          isNative: false,
        ),
      ],
      recentActivity: [
        RecentActivityItem(
          txid: 'abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890',
          direction: 'incoming',
          chain: 'bitcoin',
          amount: '+0.005 BTC',
          ticker: 'BTC',
          timestamp: DateTime.now().subtract(const Duration(hours: 2)),
          confirmations: 6,
          counterparty: 'tb1q…4x2p',
        ),
        RecentActivityItem(
          txid: '1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef',
          direction: 'outgoing',
          chain: 'bitcoin',
          amount: '-0.001 BTC',
          ticker: 'BTC',
          timestamp: DateTime.now().subtract(const Duration(days: 1)),
          confirmations: 144,
          note: 'Coffee',
        ),
        RecentActivityItem(
          txid: 'fedcba0987654321fedcba0987654321fedcba0987654321fedcba0987654321',
          direction: 'incoming',
          chain: 'liquid',
          amount: '+100 USDT',
          ticker: 'USDT',
          timestamp: DateTime.now().subtract(const Duration(days: 3)),
          confirmations: 500,
        ),
      ],
    );
  }

  /// Mock index advances with [fresh], mirroring the real derivation.
  int _mockAddressIndex = 5;

  @override
  Future<AddressInfo> generateReceiveAddress(String walletId, String asset,
      {bool fresh = false}) async {
    await Future.delayed(const Duration(milliseconds: 300));
    final isLiquid = asset == 'LBTC' || asset == 'L-BTC' || asset == 'liquid';
    if (isLiquid) {
      // Confidential Liquid testnet address (blech32, tlq1 HRP).
      return const AddressInfo(
        address:
            'tlq1qqw3z9v9y6qd4t0h3z8m6a4v9k2p5r8s7c6x4d2f9g0h1j3k5l7m9n1p3q5r7t9v2x4z6b8d0f',
        index: 5,
        asset: 'LBTC',
        derivationPath: "m/84'/1'/0'/0/5",
      );
    }
    if (fresh) _mockAddressIndex++;
    final i = _mockAddressIndex;
    return AddressInfo(
      address: 'tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjz${i.toString().padLeft(2, '0')}',
      index: i,
      asset: 'BTC',
      derivationPath: "m/84'/1'/0'/0/$i",
    );
  }

  @override
  Future<List<AddressInfo>> listPreviousAddresses(String walletId, String asset) async {
    await Future.delayed(const Duration(milliseconds: 300));
    return [
      AddressInfo(
        address: 'tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx',
        index: 4,
        asset: asset,
        label: 'Payment from Alice',
        receivedSats: 500000,
      ),
      AddressInfo(
        address: 'tb1qrp33g0q5c5txsp9arfj2k5eer7t5d5uu9r6zx3',
        index: 3,
        asset: asset,
        receivedSats: 0,
      ),
      AddressInfo(
        address: 'tb1q6rfmyvrl56kkxsmfkm2y4z4rkxkqgz4k3j5x7',
        index: 2,
        asset: asset,
        label: 'Faucet',
        receivedSats: 1234567,
      ),
    ];
  }

  @override
  Future<List<Transaction>> listActivity(String walletId, {String? chain, String? asset}) async {
    await Future.delayed(const Duration(milliseconds: 400));
    return [
      Transaction(
        txid: 'abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890',
        direction: TxDirection.incoming,
        chain: TxChain.bitcoin,
        amount: '+0.005 BTC',
        ticker: 'BTC',
        timestamp: DateTime.now().subtract(const Duration(hours: 2)),
        confirmations: 6,
        counterparty: 'tb1q…4x2p',
        fee: '280 sats',
        fiatEstimate: '+\$485.00',
      ),
      Transaction(
        txid: '1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef',
        direction: TxDirection.outgoing,
        chain: TxChain.bitcoin,
        amount: '-0.001 BTC',
        ticker: 'BTC',
        timestamp: DateTime.now().subtract(const Duration(days: 1)),
        confirmations: 144,
        note: 'Coffee',
        fee: '192 sats',
        fiatEstimate: '-\$97.00',
      ),
      Transaction(
        txid: 'fedcba0987654321fedcba0987654321fedcba0987654321fedcba0987654321',
        direction: TxDirection.incoming,
        chain: TxChain.liquid,
        amount: '+100 USDT',
        ticker: 'USDT',
        timestamp: DateTime.now().subtract(const Duration(days: 3)),
        confirmations: 500,
        fee: '100 sats',
      ),
    ];
  }

  /// Coins frozen in this session — the engine keeps them on the registry
  /// entry; the mock only needs them to survive a reload of the screen.
  final Set<String> _frozen = {};

  @override
  Future<void> setUtxosFrozen({
    required String walletId,
    required String chain,
    required List<String> outpoints,
    required bool frozen,
  }) async {
    await Future.delayed(const Duration(milliseconds: 150));
    frozen ? _frozen.addAll(outpoints) : _frozen.removeAll(outpoints);
  }

  @override
  Future<List<Utxo>> listUtxos(String walletId, String chain) async {
    await Future.delayed(const Duration(milliseconds: 300));
    return [
      for (final u in _mockUtxos)
        _frozen.contains(u.outpoint) ? u.copyWith(state: UtxoState.frozen) : u,
    ];
  }

  static const List<Utxo> _mockUtxos = [
    Utxo(
      outpoint: 'abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890:0',
      amount: 900000,
      displayAmount: '0.009 BTC',
      confirmations: 6,
      state: UtxoState.available,
      address: 'tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx',
    ),
    Utxo(
      outpoint: '1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef:1',
      amount: 334567,
      displayAmount: '0.00334567 BTC',
      confirmations: 144,
      state: UtxoState.available,
      label: 'Change',
      address: 'tb1qrp33g0q5c5txsp9arfj2k5eer7t5d5uu9r6zx3',
    ),
    Utxo(
      outpoint: 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef:0',
      amount: 546,
      displayAmount: '546 sats',
      confirmations: 12,
      state: UtxoState.dusty,
      address: 'tb1q6rfmyvrl56kkxsmfkm2y4z4rkxkqgz4k3j5x7',
    ),
    // A payment still in the mempool: the grey provisional note, so the
    // pending shape can be checked without waiting on a faucet.
    Utxo(
      outpoint: 'cafebabecafebabecafebabecafebabecafebabecafebabecafebabecafebabe:1',
      amount: 150000,
      displayAmount: '0.0015 BTC',
      confirmations: 0,
      state: UtxoState.unconfirmed,
      address: 'tb1qw508d6qejxtdg4y5r3zarvary0c5xw7kxpjzsx',
    ),
  ];

  @override
  Future<WalletInfo> getWalletInfo(String walletId) async {
    await Future.delayed(const Duration(milliseconds: 300));
    // "Treasury 2-of-3" is the mock's multisig, and the only wallet here with
    // co-signers to draw. Without them the key ring has nothing to show in
    // mock mode, which is where the phone layouts are checked.
    if (walletId == 'wallet-2') {
      const keys = [
        "[73c5da0a/48'/1'/0'/2']tpubDErWN5qfdLwYE1DbaXTdCsD3fnRDpMkgYPFTa5RmwDNXhtcH2GDsyzhF1JzMxCq2ceZ4qniA9r4qCcHXnPtQKvKk3jUYSxUwiUJHqvvJcW6",
        "[f0b68896/48'/1'/0'/2']tpubDCVwWj4hEpeWNFcWe3Eo1DrkLnPC4c2iitjw5wAuTkSZgofJbRMD4KESh1uhsqLCCjcjR36JooEFwfWf1ezwmAfjcPCxc7KNtnfBCrMPdtT",
        "[a1b2c3d4/48'/1'/0'/2']tpubDDsVS9pMxpJcpFR7WhWpKrML6UyuMqZjKZMdUYYPnJPPTNVmuBKvHzHfCMDzcBWmQVLBGZWaLNqYYYUYrDaLbUJPTGdVWKKqnnEXrDJKcJc",
      ];
      return WalletInfo(
        id: walletId,
        name: 'Treasury 2-of-3',
        network: 'Testnet',
        masterFingerprint: '73c5da0a',
        derivationPath: "m/48'/1'/0'/2'",
        scriptType: 'P2WSH 2-of-3 Multisig',
        xpub: '',
        receiveDescriptor: 'wsh(sortedmulti(2,${keys.join('/0/*,')}/0/*))',
        changeDescriptor: 'wsh(sortedmulti(2,${keys.join('/1/*,')}/1/*))',
        cosignerKeys: keys,
        requiredSigs: 2,
        localFingerprints: const ['73c5da0a'],
        hasSeed: false,
      );
    }
    return WalletInfo(
      id: walletId,
      name: 'Primary',
      network: 'Testnet',
      masterFingerprint: 'deadbeef',
      derivationPath: "m/84'/1'/0'",
      scriptType: 'P2WPKH (Native SegWit)',
      xpub: 'tpubDC7KMhGhFE2MhAJXrWMxumRnpFDqgtQQiQSFLGCaAk5CW8BQBuNr7PKRqNGV1ZB6qKP3zERkHV7DGUzPMDQc2y4kF7K8UrHeRfFXWkHPPjE',
      receiveDescriptor: 'wpkh([deadbeef/84h/1h/0h]tpubDC7KMhGhFE2MhAJXrWMxumRnpFDqgtQQiQSFLGCaAk5CW8BQBuNr7PKRqNGV1ZB6qKP3zERkHV7DGUzPMDQc2y4kF7K8UrHeRfFXWkHPPjE/0/*)',
      changeDescriptor: 'wpkh([deadbeef/84h/1h/0h]tpubDC7KMhGhFE2MhAJXrWMxumRnpFDqgtQQiQSFLGCaAk5CW8BQBuNr7PKRqNGV1ZB6qKP3zERkHV7DGUzPMDQc2y4kF7K8UrHeRfFXWkHPPjE/1/*)',
      multipathDescriptor: 'wpkh([deadbeef/84h/1h/0h]tpubDC7KMhGhFE2MhAJXrWMxumRnpFDqgtQQiQSFLGCaAk5CW8BQBuNr7PKRqNGV1ZB6qKP3zERkHV7DGUzPMDQc2y4kF7K8UrHeRfFXWkHPPjE/<0;1>/*)',
      hasSeed: true,
      hasPassphrase: false,
      lastBackupAt: DateTime.now().subtract(const Duration(days: 5)),
    );
  }

  @override
  Future<BalanceHistory> getBalanceHistory(String walletId) async {
    await Future.delayed(const Duration(milliseconds: 250));
    // 60 days of daily points: a gently rising random walk with a few step
    // deposits, scaled so the last point lands exactly on the mock balances
    // reported by getWalletSummary.
    const days = 60;
    const btcNow = 1234567;
    const lbtcNow = 500000;
    final btcWalk = _mockWalk(walletId.hashCode ^ 0xB7C, days + 1, const [11, 29, 47]);
    final lbtcWalk = _mockWalk(walletId.hashCode ^ 0x1B7C, days + 1, const [19, 44]);
    final now = DateTime.now();
    return BalanceHistory(
      points: [
        for (var i = 0; i <= days; i++)
          BalanceHistoryPoint(
            time: now.subtract(Duration(hours: (days - i) * 24 + (i % 7) * 2)),
            btcSats: (btcNow * btcWalk[i] / btcWalk.last).round(),
            lbtcSats: (lbtcNow * lbtcWalk[i] / lbtcWalk.last).round(),
          ),
      ],
      btcSats: btcNow,
      lbtcSats: lbtcNow,
      hasBitcoin: true,
      hasLiquid: true,
    );
  }

  /// Multiplicative random walk with a slight upward bias, jumped at [steps]
  /// to mimic deposits. Seeded so a wallet's chart is stable across reloads.
  static List<double> _mockWalk(int seed, int n, List<int> steps) {
    final rng = math.Random(seed);
    final out = <double>[];
    var v = 1.0;
    for (var i = 0; i < n; i++) {
      v *= 1 + (rng.nextDouble() - 0.42) * 0.06;
      if (steps.contains(i)) v *= 1.22;
      out.add(v);
    }
    return out;
  }

  @override
  Future<Map<String, String>> syncWallet(String walletId) async {
    await Future.delayed(const Duration(seconds: 2));
    return {'btc': 'ok', 'liquid': 'ok'};
  }

  @override
  Future<TxPreview> previewTransaction({
    required String walletId,
    required List<TxOutputSpec> outputs,
    required String assetId,
    required double feeRate,
    List<String>? utxos,
  }) async {
    await Future.delayed(const Duration(milliseconds: 500));
    final amountSats = outputs.fold(0, (s, o) => s + o.amountSats);
    final address = outputs.isNotEmpty ? outputs.first.address : '';
    final fee = (feeRate * 150).round();
    final inputs = utxos != null && utxos.isNotEmpty
        ? [
            for (final op in utxos)
              TxIo(
                outpoint: op,
                address: 'tb1qmockinput${op.hashCode.abs() % 10000}',
                amountSats: amountSats + fee,
                isChange: false,
              ),
          ]
        : [
            TxIo(
              outpoint:
                  'aaaa1111bbbb2222cccc3333dddd4444eeee5555ffff6666aaaa7777bbbb8888:0',
              address: 'tb1qmockautoselected0000',
              amountSats: amountSats + fee + 25000,
              isChange: false,
            ),
          ];
    final inTotal = inputs.fold(0, (s, i) => s + i.amountSats);
    final change = inTotal - amountSats - fee;
    return TxPreview(
      chain: assetId == 'BTC' ? 'bitcoin' : 'liquid',
      recipientAddress: address,
      amountDisplay: assetId == 'BTC'
          ? '${(amountSats / 1e8).toStringAsFixed(8)} BTC'
          : '$amountSats sats',
      feeSats: fee,
      feeDisplay: '$fee sats (${feeRate.toStringAsFixed(1)} sat/vB)',
      totalDisplay: assetId == 'BTC'
          ? '${((amountSats + fee) / 1e8).toStringAsFixed(8)} BTC'
          : '${amountSats + fee} sats total',
      feeRate: feeRate,
      vsizeEst: 150,
      inputs: inputs,
      outputs: [
        for (final o in outputs)
          TxIo(address: o.address, amountSats: o.amountSats, isChange: false),
        if (change > 0)
          TxIo(
            address: 'tb1qmockchangeaddr9999',
            amountSats: change,
            isChange: true,
          ),
      ],
    );
  }

  @override
  Future<String> sendTransaction({
    required String walletId,
    required List<TxOutputSpec> outputs,
    required String assetId,
    required double feeRate,
    List<String>? utxos,
  }) async {
    await Future.delayed(const Duration(seconds: 2));
    // A multisig wallet cannot finish alone: the engine answers with a JSON
    // object carrying the partial PSBT instead of a txid, and the Send screen
    // opens its co-signature sheet on it. Mirrored here so that sheet — and
    // its quorum chart — is reachable on mock data.
    if (_isMultisigWallet(walletId)) {
      return jsonEncode({
        'partial_psbt': '$_mockPsbtBody$_mockSigMarker',
        'sigs_have': 1,
        'sigs_needed': 2,
      });
    }
    return 'mock_txid_${DateTime.now().millisecondsSinceEpoch}';
  }

  /// Body of every mock PSBT. Signatures are appended as [_mockSigMarker]s,
  /// so pasting a "signed" copy back moves the quorum chart the way a real
  /// one does.
  static const _mockPsbtBody = 'cHNidP8BAH0mock';
  static const _mockSigMarker = '~sig';

  /// The mock's own multisig wallets: the seeded Treasury, and anything the
  /// multisig wizard created in this session.
  bool _isMultisigWallet(String walletId) =>
      walletId == 'wallet-2' || walletId.startsWith('ms_');

  @override
  Future<IssueResult> issueAsset({
    required String walletId,
    required String name,
    required String ticker,
    required int precision,
    required String domain,
    required int amountSats,
    required int reissuanceTokens,
  }) async {
    await Future.delayed(const Duration(seconds: 2));
    const assetId = 'abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234';
    return IssueResult(
      assetId: assetId,
      tokenId: reissuanceTokens > 0
          ? 'efgh5678efgh5678efgh5678efgh5678efgh5678efgh5678efgh5678efgh5678'
          : null,
      txid: 'mock_issue_txid_${DateTime.now().millisecondsSinceEpoch}',
      registryRegistered: false,
      proofUrl: 'https://$domain/.well-known/liquid-asset-proof-$assetId',
      proofContent:
          'Authorize linking the domain name $domain to the Liquid asset $assetId',
    );
  }

  @override
  Future<IssueResult> reissueAsset({
    required String walletId,
    required String assetId,
    required int amountSats,
  }) async {
    await Future.delayed(const Duration(seconds: 2));
    return IssueResult(
      assetId: assetId,
      txid: 'mock_reissue_txid_${DateTime.now().millisecondsSinceEpoch}',
      registryRegistered: false,
      proofUrl: '',
      proofContent: '',
    );
  }

  @override
  Future<String> burnAsset({
    required String walletId,
    required String assetId,
    required int amountSats,
  }) async {
    await Future.delayed(const Duration(seconds: 2));
    return 'mock_burn_txid_${DateTime.now().millisecondsSinceEpoch}';
  }

  // ── LiquiDEX swaps (mock) ─────────────────────────────────────────────────
  //
  // New-feature models (SwapAnalysis, MyOffer, Peg*) are built via fromJson
  // with contract-shaped snake_case maps, mirroring what wallet-ffi returns.

  static const _lbtcTestnet =
      '144c654344aa716d6f3abcc1ca90e5641e4e2a7f633bc09fe3baf64585819a49';
  static const _lbtcMainnet =
      '6f0279e9ed041c3d710a9f57d0c02928416460c4b722ae3457a11eec381c526d';
  static const _usdtTestnet =
      'b612eb46313a2cd6ebabd8b7a8eed5696e29898b87a43bff41c94f51acef9d73';
  static const _dbeerMainnet =
      '002452cb8f56a0a5628240edfb3d1e966c9b1959adcfb95b5726e5e9688611bf';

  static final _testnetProposalJson =
      '{"version":0,"tx":"0200000001016d0ck00000000000000000000000000000000000'
      '000000000000000000000000000000000ffffffff","inputs":[{"asset":'
      '"$_usdtTestnet","asset_blinder":"11${'0' * 62}","amount_blinder":'
      '"22${'0' * 62}","amount":500000000}],"outputs":[{"asset":"$_lbtcTestnet",'
      '"asset_blinder":"33${'0' * 62}","amount_blinder":"44${'0' * 62}",'
      '"amount":5000}]}';

  static Map<String, dynamic> _leg(
    String assetId,
    String ticker,
    int amountSats,
    String displayAmount,
  ) =>
      {
        'asset_id': assetId,
        'ticker': ticker,
        'amount_sats': amountSats,
        'display_amount': displayAmount,
      };

  static Map<String, dynamic> _cannedAnalysisJson({required bool deep}) {
    final chainOk = deep ? true : null;
    final chainNote = deep ? null : 'needs chain access';
    return {
      'valid': true,
      'checks': [
        {'name': 'structure', 'ok': true, 'note': null},
        {'name': 'sighash_single_acp', 'ok': true, 'note': null},
        {'name': 'output_commitments', 'ok': true, 'note': null},
        {'name': 'input_commitments', 'ok': chainOk, 'note': chainNote},
        {'name': 'input_unspent', 'ok': chainOk, 'note': chainNote},
        {'name': 'signature', 'ok': chainOk, 'note': chainNote},
      ],
      'maker_offers': _leg(_usdtTestnet, 'USDT', 500000000, '5.00'),
      'maker_wants': _leg(_lbtcTestnet, 'L-BTC', 5000, '0.00005000'),
      'network': 'testnet',
      // The engine only grants takeability after deep (chain) verification.
      'takeable': deep,
      'take_block_reason':
          deep ? null : 'deep (chain) verification required before taking',
    };
  }

  @override
  Future<List<SwapOffer>> listSwaps({bool includeUnavailable = false}) async {
    await Future.delayed(const Duration(milliseconds: 400));
    final offers = [
      SwapOffer.fromJson({
        'id': 101,
        'available': true,
        'receive': _leg(_usdtTestnet, 'USDT', 500000000, '5.00'),
        'pay': _leg(_lbtcTestnet, 'L-BTC', 5000, '0.00005000'),
        'price': 0.00001,
        'price_display': '0.00001000 L-BTC/USDT',
        'created': 'Mon, 03 Aug 2026 10:15:00 GMT',
        'verified': true,
        'verify_note': null,
        'proposal_json': _testnetProposalJson,
        'network': 'testnet',
        'takeable': true,
        'kind': 'swap',
      }),
      SwapOffer.fromJson({
        'id': 13,
        'available': true,
        'receive': _leg(_dbeerMainnet, 'DBEER', 1000, '10.00'),
        'pay': _leg(_lbtcMainnet, 'L-BTC', 1000, '0.00001000'),
        'price': 1.0,
        'price_display': '1.00000000 L-BTC/DBEER',
        'created': 'Wed, 09 Jun 2021 16:37:38 GMT',
        'verified': true,
        'verify_note': null,
        'proposal_json': '{"version":0,"tx":"0200…mock","inputs":[],"outputs":[]}',
        'network': 'mainnet',
        'takeable': false,
        'kind': 'swap',
      }),
      SwapOffer.fromJson({
        'id': 12,
        'available': false,
        'receive': _leg(_lbtcMainnet, 'L-BTC', 50000, '0.00050000'),
        'pay': _leg(_dbeerMainnet, 'DBEER', 5200, '52.00'),
        'price': 9.6,
        'price_display': '9.60 DBEER/L-BTC',
        'created': 'Sun, 14 Jun 2026 09:30:00 GMT',
        'verified': true,
        'verify_note': null,
        'proposal_json': '{"version":0,"tx":"0200…mock2","inputs":[],"outputs":[]}',
        'network': 'mainnet',
        'takeable': false,
        'kind': 'swap',
      }),
    ];
    return includeUnavailable
        ? offers
        : offers.where((o) => o.available).toList();
  }

  @override
  Future<SwapAnalysis> swapVerify(String proposalJson, {bool deep = false}) async {
    await Future.delayed(Duration(milliseconds: deep ? 900 : 250));
    return SwapAnalysis.fromJson(_cannedAnalysisJson(deep: deep));
  }

  @override
  Future<SwapTakePreview> swapTakePreview(String walletId, String proposalJson,
      {double? feeRate}) async {
    await Future.delayed(const Duration(milliseconds: 900));
    return SwapTakePreview.fromJson({
      'you_receive': _leg(_usdtTestnet, 'USDT', 500000000, '5.00'),
      'you_pay': _leg(_lbtcTestnet, 'L-BTC', 5000, '0.00005000'),
      'fee_sats': 273,
      'fee_display': '273 sats',
      'change': [
        _leg(_lbtcTestnet, 'L-BTC', 94727, '0.00094727'),
      ],
      'analysis': _cannedAnalysisJson(deep: true),
    });
  }

  @override
  Future<String> swapTake(String walletId, String proposalJson,
      {double? feeRate}) async {
    await Future.delayed(const Duration(seconds: 1));
    return 'mock_swap_txid_${DateTime.now().millisecondsSinceEpoch}';
  }

  static String _hex8() =>
      (DateTime.now().microsecondsSinceEpoch & 0xffffffff)
          .toRadixString(16)
          .padLeft(8, '0');

  static int _nowSecs() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  final List<Map<String, dynamic>> _myOffers = [
    {
      'offer_id': 'of_a1b2c3d4',
      'kind': 'swap',
      'status': 'open',
      'created_at': _nowSecs() - 10800,
      'offers': _leg(_lbtcTestnet, 'L-BTC', 25000, '0.00025000'),
      'wants': _leg(_usdtTestnet, 'USDT', 2500000000, '25.00'),
      'proposal_json': _testnetProposalJson,
      'utxo':
          'aaaa1111bbbb2222cccc3333dddd4444eeee5555ffff6666aaaa7777bbbb8888:1',
    },
  ];

  @override
  Future<MyOffer> swapMake(String walletId, String utxo, String wantAssetId,
      int wantAmountSats) async {
    await Future.delayed(const Duration(milliseconds: 700));
    final wantTicker = wantAssetId == _lbtcTestnet ? 'L-BTC' : 'USDT';
    final wantDisplay = wantAssetId == _lbtcTestnet
        ? (wantAmountSats / 1e8).toStringAsFixed(8)
        : (wantAmountSats / 1e8).toStringAsFixed(2);
    final offer = {
      'offer_id': 'of_${_hex8()}',
      'kind': 'swap',
      'status': 'open',
      'created_at': _nowSecs(),
      'offers': _leg(_lbtcTestnet, 'L-BTC', 10000, '0.00010000'),
      'wants': _leg(wantAssetId, wantTicker, wantAmountSats, wantDisplay),
      'proposal_json': _testnetProposalJson,
      'utxo': utxo,
    };
    _myOffers.insert(0, offer);
    return MyOffer.fromJson(offer);
  }

  @override
  Future<String> swapMakePrepare(String walletId, String assetId, int amountSats,
      {double? feeRate}) async {
    await Future.delayed(const Duration(seconds: 1));
    return 'mock_prepare_txid_${DateTime.now().millisecondsSinceEpoch}';
  }

  @override
  Future<List<MyOffer>> listMyOffers(String walletId) async {
    await Future.delayed(const Duration(milliseconds: 300));
    return _myOffers.map(MyOffer.fromJson).toList();
  }

  @override
  Future<String> swapCancel(String walletId, String offerId) async {
    await Future.delayed(const Duration(milliseconds: 600));
    final offer = _myOffers.firstWhere(
      (o) => o['offer_id'] == offerId,
      orElse: () => throw Exception('wallet-ffi: unknown offer $offerId'),
    );
    if (offer['status'] != 'open') {
      throw Exception('wallet-ffi: offer is not open');
    }
    offer['status'] = 'cancelled';
    return 'mock_cancel_txid_${DateTime.now().millisecondsSinceEpoch}';
  }

  // ── Peg (mock, simulated provider) ────────────────────────────────────────

  static const int _pegMinSats = 10000;
  static const int _pegMaxSats = 2100000000;
  // Clearly fake but well-formed deposit addresses; the UI labels them SIMULATED.
  static const _pegInDepositAddr =
      'tb1qsimulatedpegdeposit0demo0nly00000000000';
  static const _pegOutDepositAddr =
      'tlq1qqsimulatedpegdeposit0demo0nly00000000000000000000000000000';

  final Map<String, Map<String, dynamic>> _pegOrders = {};

  static (int service, int network, int receive) _pegFees(int amountSats) {
    // Integer division to match the Rust provider's 0.1% floor exactly.
    final service = math.max(100, amountSats ~/ 1000);
    const network = 250;
    return (service, network, amountSats - service - network);
  }

  @override
  Future<PegQuote> pegQuote(String direction, int amountSats) async {
    await Future.delayed(const Duration(milliseconds: 250));
    if (amountSats < _pegMinSats) {
      throw Exception('wallet-ffi: amount below minimum of $_pegMinSats sats');
    }
    if (amountSats > _pegMaxSats) {
      throw Exception('wallet-ffi: amount above maximum of $_pegMaxSats sats');
    }
    final (service, network, receive) = _pegFees(amountSats);
    return PegQuote.fromJson({
      'direction': direction,
      'amount_sats': amountSats,
      'rate': 1.0,
      'service_fee_sats': service,
      'network_fee_sats': network,
      'receive_sats': receive,
      'min_sats': _pegMinSats,
      'max_sats': _pegMaxSats,
      'eta_minutes': 2,
      'simulated': true,
    });
  }

  @override
  Future<PegOrder> pegStart(String walletId, String direction, int amountSats,
      String payoutAddress) async {
    await Future.delayed(const Duration(milliseconds: 500));
    // Same limit checks the Rust provider applies via quote().
    if (amountSats < _pegMinSats) {
      throw Exception('wallet-ffi: amount below minimum of $_pegMinSats sats');
    }
    if (amountSats > _pegMaxSats) {
      throw Exception('wallet-ffi: amount above maximum of $_pegMaxSats sats');
    }
    final (_, _, receive) = _pegFees(amountSats);
    final now = _nowSecs();
    final orderId = 'pg_${_hex8()}';
    final order = <String, dynamic>{
      'order_id': orderId,
      'wallet_id': walletId,
      'direction': direction,
      'status': 'awaiting_deposit',
      'deposit_address':
          direction == 'in' ? _pegInDepositAddr : _pegOutDepositAddr,
      'deposit_expected_sats': amountSats,
      'payout_address': payoutAddress,
      'payout_expected_sats': receive,
      'created_at': now,
      'updated_at': now,
      'eta_minutes': 2,
      'txid_deposit': null,
      'txid_payout': null,
      'simulated': true,
      'status_history': <Map<String, dynamic>>[
        {'status': 'awaiting_deposit', 'at': now},
      ],
    };
    _pegOrders[orderId] = order;
    return PegOrder.fromJson(order);
  }

  // Mock lifecycle: elapsed seconds since created_at drive the transitions.
  static const _pegStages = [
    (20, 'deposit_seen'),
    (50, 'confirming'),
    (80, 'settling'),
    (110, 'completed'),
  ];

  void _advancePegOrder(Map<String, dynamic> order) {
    final status = order['status'] as String;
    if (status == 'cancelled' || status == 'completed') return;
    final created = order['created_at'] as int;
    final elapsed = _nowSecs() - created;
    final history =
        (order['status_history'] as List).cast<Map<String, dynamic>>();
    for (final (threshold, stage) in _pegStages) {
      if (elapsed < threshold) break;
      if (history.any((h) => h['status'] == stage)) continue;
      history.add({'status': stage, 'at': created + threshold});
      order['status'] = stage;
      order['updated_at'] = created + threshold;
      if (stage == 'deposit_seen') {
        order['txid_deposit'] =
            'mock_peg_deposit_txid_${order['order_id']}';
      } else if (stage == 'completed') {
        order['txid_payout'] = 'mock_peg_payout_txid_${order['order_id']}';
      }
    }
  }

  @override
  Future<PegOrder> pegStatus(String orderId) async {
    await Future.delayed(const Duration(milliseconds: 200));
    final order = _pegOrders[orderId];
    if (order == null) throw Exception('wallet-ffi: unknown peg order $orderId');
    _advancePegOrder(order);
    return PegOrder.fromJson(order);
  }

  @override
  Future<List<PegOrder>> pegList(String walletId) async {
    await Future.delayed(const Duration(milliseconds: 300));
    final orders = _pegOrders.values
        .where((o) => o['wallet_id'] == walletId)
        .toList()
      ..sort((a, b) => (b['created_at'] as int).compareTo(a['created_at'] as int));
    for (final o in orders) {
      _advancePegOrder(o);
    }
    return orders.map(PegOrder.fromJson).toList();
  }

  @override
  Future<PegOrder> pegCancel(String orderId) async {
    await Future.delayed(const Duration(milliseconds: 400));
    final order = _pegOrders[orderId];
    if (order == null) throw Exception('wallet-ffi: unknown peg order $orderId');
    _advancePegOrder(order);
    if (order['status'] != 'awaiting_deposit') {
      throw Exception(
          'wallet-ffi: order can only be cancelled while awaiting deposit');
    }
    final now = _nowSecs();
    order['status'] = 'cancelled';
    order['updated_at'] = now;
    (order['status_history'] as List)
        .cast<Map<String, dynamic>>()
        .add({'status': 'cancelled', 'at': now});
    return PegOrder.fromJson(order);
  }

  @override
  Future<bool> reregisterAsset({
    required String walletId,
    required String assetId,
    required String name,
    required String ticker,
    required int precision,
    required String domain,
  }) async {
    await Future.delayed(const Duration(seconds: 1));
    return false;
  }

  @override
  Future<List<HwDevice>> enumerateHwDevices() async {
    await Future.delayed(const Duration(seconds: 2));
    return [
      const HwDevice(model: 'Ledger Nano S', fingerprint: 'deadbeef', path: 'hid:/0001:0002:00'),
    ];
  }

  @override
  Future<List<String>> jadePorts() async => const ['/dev/cu.usbserial-mock'];

  @override
  Future<WalletSummary> importJadeLiquidWallet(String name) async {
    await Future.delayed(const Duration(seconds: 2));
    return WalletSummary(
      id: 'mock-jade-liquid-${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      type: WalletType.watchOnly,
      network: WalletNetwork.testnet,
      balanceSats: 0,
      txCount: 0,
      lastSyncAt: DateTime.now(),
      isWatchOnly: true,
      typeLabel: 'Hardware (deadbeef)',
      liquidEnabled: true,
    );
  }

  @override
  Future<List<NativeDevice>> enumerateNativeDevices() async {
    await Future.delayed(const Duration(milliseconds: 300));
    return const [
      NativeDevice(
        family: 'ledger',
        model: 'Nano S Plus',
        transport: 'hid',
        path: 'hid:/0001:0002:00',
        vendorId: 0x2c97,
        productId: 0x5011,
      ),
    ];
  }

  @override
  Future<HwImportResult> importHwWallet(String name, String fingerprint, {bool liquid = false}) async {
    await Future.delayed(const Duration(seconds: 2));
    final wallet = WalletSummary(
      id: 'hw_${fingerprint.substring(0, 6)}',
      name: name,
      type: WalletType.watchOnly,
      network: WalletNetwork.testnet,
      balanceSats: 0,
      txCount: 0,
      lastSyncAt: DateTime.now(),
      isWatchOnly: true,
      typeLabel: 'Hardware ($fingerprint)',
      liquidEnabled: liquid,
      deviceModel: 'Blockstream Jade',
    );
    return HwImportResult(
      wallet: wallet,
      fingerprint: fingerprint,
      deviceModel: 'Blockstream Jade',
      bitcoinDescriptor:
          "wpkh([$fingerprint/84'/1'/0']tpubDMockReceiveDescriptorForUiWork/0/*)",
      liquidDescriptor:
          liquid ? 'ct(slip77(mock),elwpkh([$fingerprint/84h/1h/0h]tpubDMock/<0;1>/*))' : null,
      liquidRequested: liquid,
    );
  }

  @override
  Future<WalletSummary> addLiquidToWallet(String walletId) async {
    await Future.delayed(const Duration(seconds: 1));
    return WalletSummary(
      id: walletId,
      name: 'Mock hardware wallet',
      type: WalletType.watchOnly,
      network: WalletNetwork.testnet,
      balanceSats: 0,
      txCount: 0,
      lastSyncAt: DateTime.now(),
      isWatchOnly: true,
      typeLabel: 'Hardware (deadbeef)',
      liquidEnabled: true,
      deviceModel: 'Blockstream Jade',
    );
  }

  @override
  Future<WalletSummary> createWatchOnlyWallet(
      String name, String recvDesc, String changeDesc,
      {String? liquidCtDescriptor, bool airgap = false}) async {
    await Future.delayed(const Duration(milliseconds: 500));
    final liquid = liquidCtDescriptor != null && liquidCtDescriptor.trim().isNotEmpty;
    return WalletSummary(
      id: 'watch_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      type: WalletType.watchOnly,
      network: WalletNetwork.testnet,
      balanceSats: 0,
      txCount: 0,
      lastSyncAt: DateTime.now(),
      isWatchOnly: true,
      typeLabel: airgap ? 'Air-gap watch-only' : 'Watch-only',
      liquidEnabled: liquid,
    );
  }

  @override
  Future<WalletSummary> createMultisigWallet({
    required String name,
    required int requiredSigs,
    required int totalSigners,
    required List<String> cosignerXpubs,
    String? localMnemonic,
    List<String>? localMnemonics,
    List<String> liquidXpubs = const [],
    int? liquidCapableKeys,
  }) async {
    await Future.delayed(const Duration(milliseconds: 600));
    return WalletSummary(
      id: 'ms_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      type: WalletType.multisig,
      network: WalletNetwork.testnet,
      balanceSats: 0,
      txCount: 0,
      lastSyncAt: DateTime.now(),
      typeLabel: 'Multisig $requiredSigs-of-$totalSigners',
      liquidEnabled: liquidXpubs.isNotEmpty,
    );
  }

  @override
  Future<String> getHwCosignerXpub(String fingerprint) async {
    await Future.delayed(const Duration(milliseconds: 400));
    return "[$fingerprint/48'/1'/0'/2']tpubDMockHw${fingerprint.hashCode.toRadixString(16)}";
  }

  @override
  Future<String> getJadeLiquidCosignerXpub({String? expectFingerprint}) async {
    await Future.delayed(const Duration(milliseconds: 400));
    final fp = expectFingerprint?.isNotEmpty == true
        ? expectFingerprint!
        : 'jade0000';
    return "[$fp/87'/1'/0']tpubDMockJadeLiquid${fp.hashCode.toRadixString(16)}";
  }

  @override
  Future<String> deriveLiquidDescriptor(String btcDescriptor) async {
    await Future.delayed(const Duration(milliseconds: 200));
    final key = btcDescriptor.contains('(')
        ? btcDescriptor.substring(
            btcDescriptor.indexOf('(') + 1, btcDescriptor.lastIndexOf(')'))
        : "[00000000/84'/1'/0']$btcDescriptor/<0;1>/*";
    return 'ct(elip151,wpkh($key))';
  }

  @override
  Future<HwiStatus> hwiStatus() async => const HwiStatus(
        resolvedBin: '/mock/data/hwi/hwi',
        version: '3.2.0',
        platform: 'mock',
        udevRulesInstalled: null,
      );

  @override
  Future<void> setHwiPath(String path) async {}

  @override
  Future<String> getDataDir() async => '/mock/data';

  @override
  Future<String> getVersion() async => '0.0.0-mock';

  @override
  Future<String> deriveCosignerXpub(List<String> mnemonic) async {
    await Future.delayed(const Duration(milliseconds: 200));
    final tag = mnemonic.first.substring(0, 2);
    return "[${tag}adbeef/48'/1'/0'/2']tpubDMock${mnemonic.hashCode.toRadixString(16)}";
  }

  @override
  Future<String> getCosignerXpub(String walletId) async {
    await Future.delayed(const Duration(milliseconds: 200));
    return "[cafebabe/48'/1'/0'/2']tpubDMockFromWallet$walletId";
  }

  @override
  Future<String> deriveLiquidCosignerXpub(List<String> mnemonic) async {
    await Future.delayed(const Duration(milliseconds: 200));
    return "[${mnemonic.join().hashCode.toRadixString(16).padLeft(8, '0')}"
        "/87'/1'/0']tpubDMockLiquidCosigner";
  }

  @override
  Future<String> getLiquidCosignerXpub(String walletId) async {
    await Future.delayed(const Duration(milliseconds: 200));
    return "[cafebabe/87'/1'/0']tpubDMockLiquidFromWallet$walletId";
  }

  @override
  Future<WalletSummary> repairMultisigWallet(String walletId) async {
    await Future.delayed(const Duration(milliseconds: 120));
    throw Exception('wallet-ffi: "$walletId" has nothing to repair.');
  }

  /// Mirrors the engine closely enough for the wizard's field states to be
  /// exercised without the dylib: reduces a scanned descriptor to its key,
  /// refuses a key with no origin, warns on a singlesig account path.
  @override
  Future<CosignerKeyInfo> validateCosignerKey(String key,
      {bool liquid = false}) async {
    await Future.delayed(const Duration(milliseconds: 60));
    final compact = key.replaceAll(RegExp(r'\s'), '').split('#').first;
    final open = compact.indexOf('[');
    final close = compact.indexOf(']');
    if (open < 0 || close < open + 2) {
      throw Exception('wallet-ffi: This key has no origin. A cosigner key must '
          'carry the fingerprint and the path it was derived at.');
    }
    final origin = compact.substring(open + 1, close);
    final marker = liquid ? 'h' : "'";
    final parts = origin.split('/');
    final fingerprint = parts.first.toLowerCase();
    final path = parts
        .skip(1)
        .map((p) => p.replaceAll(RegExp("[hH']"), marker))
        .join('/');
    final tail = compact.substring(close + 1).split('(').last;
    final xpub = RegExp(r'^[1-9A-HJ-NP-Za-km-z]+').stringMatch(tail) ?? '';
    final expected = liquid ? '87h/1h/0h' : "48'/1'/0'/2'";
    return CosignerKeyInfo(
      normalized: '[$fingerprint/$path]$xpub',
      fingerprint: fingerprint,
      path: path,
      warning: path == expected
          ? null
          : 'm/$path is not the usual cosigner path (m/$expected).',
    );
  }

  @override
  Future<List<String>> getMnemonic(String walletId) async {
    await Future.delayed(const Duration(milliseconds: 200));
    return const [
      'abandon', 'ability', 'able', 'about', 'above', 'absent',
      'absorb', 'abstract', 'absurd', 'abuse', 'access', 'accident',
    ];
  }

  @override
  Future<String> getPrivateKey(String walletId) async {
    await Future.delayed(const Duration(milliseconds: 200));
    // Fake testnet master xprv so the reveal UI works in mock mode.
    return 'tprv8ZgxMBicQKsPeMockRootKeyForUiTesting'
        '$walletId'
        'aXyZ1234567890abcdefGHIJKLMNOPqrstuvwxyz';
  }

  @override
  Future<PsbtInspection> inspectPsbt(String psbtBase64) async {
    await Future.delayed(const Duration(milliseconds: 400));
    // Count the signatures the blob actually carries, so a copy coming back
    // from a co-signer reads as one more signature than the copy that went
    // out — the whole point of the chart on the co-signature sheet.
    const fingerprints = ['deadbeef', 'cafebabe'];
    final signed = _mockSigMarker.allMatches(psbtBase64).length
        .clamp(0, fingerprints.length);
    // The shape a current engine answers with a wallet open: every input
    // priced and owned, the recipient not ours, the change ours — so the
    // co-sign screen's ownership banner and its YOURS chips are exercised on
    // fake data too.
    return PsbtInspection(
      inputs: const [
        PsbtInput(
          outpoint: 'abcdef1234:0',
          amountSats: 1234567,
          displayAmount: '0.01234567 BTC',
          utxoStatus: PsbtUtxoStatus.ok,
          isMine: true,
        ),
      ],
      outputs: const [
        PsbtOutput(
          address: 'tb1qmockrecipient…',
          amountSats: 100000,
          displayAmount: '100000 sats',
          isMine: false,
        ),
        PsbtOutput(
          address: 'tb1qmockchange…',
          amountSats: 1133007,
          displayAmount: '0.01133007 BTC',
          isMine: true,
        ),
      ],
      feeSats: 1560,
      feeDisplay: '1560 sats',
      sigsPresent: signed,
      sigsRequired: 2,
      signers: [
        for (var i = 0; i < fingerprints.length; i++)
          PsbtSigner(fingerprint: fingerprints[i], hasSigned: i < signed),
      ],
      policyHint: '2-of-2 multisig',
      rawPsbt: psbtBase64,
      finalized: false,
      utxoCheck: PsbtUtxoStatus.ok,
      ownershipKnown: true,
    );
  }

  @override
  Future<String> signPsbt(String walletId, String psbtBase64) async {
    await Future.delayed(const Duration(milliseconds: 300));
    return '$psbtBase64$_mockSigMarker';
  }

  @override
  Future<String> sendTransactionHw({
    required String walletId,
    required List<TxOutputSpec> outputs,
    required String assetId,
    required double feeRate,
    List<String>? utxos,
  }) async {
    await Future.delayed(const Duration(seconds: 3));
    return 'mock_hw_txid_${DateTime.now().millisecondsSinceEpoch}';
  }

  @override
  Future<String> signPsbtHw(String fingerprint, String psbtBase64) async {
    await Future.delayed(const Duration(seconds: 2));
    return psbtBase64;
  }

  @override
  Future<String> combinePsbts(List<String> psbtsBase64) async {
    if (psbtsBase64.length < 2) {
      throw Exception('wallet-ffi: Combining needs at least two copies');
    }
    // Mock PSBTs carry no real signatures: the longest copy stands in for
    // the merged one.
    return psbtsBase64.reduce((a, b) => b.length > a.length ? b : a);
  }

  @override
  Future<PsetInspection> inspectPset(String walletId, String psetBase64) async {
    await Future.delayed(const Duration(milliseconds: 400));
    return PsetInspection(
      feeSats: 250,
      feeDisplay: '250 sats',
      recipients: const [
        PsetRecipient(
          address: 'tlq1qqmockrecipient…',
          assetId:
              '144c654344aa716d6f3abcc1ca90e5641e4e2a7f633bc09fe3baf64585819a49',
          ticker: 'L-BTC',
          amountSats: 100000,
          displayAmount: '0.00100000 L-BTC',
        ),
      ],
      sigsHave: 1,
      sigsNeeded: 2,
      signersPresent: const ['cafebabe'],
      signersMissing: const ['deadbeef'],
      canFinalize: false,
      rawPset: psetBase64,
    );
  }

  @override
  Future<String> signPset(String walletId, String psetBase64) async {
    await Future.delayed(const Duration(milliseconds: 500));
    return psetBase64;
  }

  @override
  Future<String> signPsetHw(String walletId, String psetBase64) async {
    await Future.delayed(const Duration(seconds: 2));
    return psetBase64;
  }

  @override
  Future<String> combinePsets(String walletId, List<String> psetsBase64) async {
    await Future.delayed(const Duration(milliseconds: 300));
    return psetsBase64.first;
  }

  @override
  Future<String> broadcastPset(String walletId, String psetBase64) async {
    await Future.delayed(const Duration(milliseconds: 800));
    return 'mock_liquid_txid_${DateTime.now().millisecondsSinceEpoch}';
  }

  @override
  Future<String> signTransactionHw({
    required String walletId,
    required List<TxOutputSpec> outputs,
    required String assetId,
    required double feeRate,
    List<String>? utxos,
  }) async {
    await Future.delayed(const Duration(seconds: 3));
    return 'cHNidP8BAHUCAAAAASaBcTce3/KF6Tet7qSze3gADAVmy7OtZGQXE8pn/xMAAAAAAAD+////AtPf9QUAAAAAGXapFNDFmQPFusKGh2DpD9UhpGZap2UgiKwA8gUqAQAAACJRIGDYV0EaKVNO0V02YSEVfx7T/9lJAAAAAA==MOCKSIGNED';
  }

  @override
  Future<String> buildUnsignedPsbt({
    required String walletId,
    required List<TxOutputSpec> outputs,
    required double feeRate,
    String assetId = 'BTC',
    List<String>? utxos,
  }) async {
    await Future.delayed(const Duration(milliseconds: 400));
    return 'cHNidP8BAHUCAAAAASaBcTce3/KF6Tet7qSze3gADAVmy7OtZGQXE8pn/xMAAAAAAAD+////AtPf9QUAAAAAGXapFNDFmQPFusKGh2DpD9UhpGZap2UgiKwA8gUqAQAAACJRIGDYV0EaKVNO0V02YSEVfx7T/9lJAAAAAA==MOCK';
  }

  @override
  Future<String> broadcastSignedPsbt({
    required String walletId,
    required String psbtBase64,
  }) async {
    await Future.delayed(const Duration(milliseconds: 500));
    return 'mock_airgap_txid_${DateTime.now().millisecondsSinceEpoch}';
  }

  @override
  Future<String> verifyHwAddress(String walletId) async {
    await Future.delayed(const Duration(seconds: 2));
    return 'tb1qmock_hw_verified_address_0000000000000';
  }

  @override
  Future<String> consolidateUtxos({
    required String walletId,
    required List<String> outpoints,
    required String chain,
    required double feeRate,
  }) async {
    await Future.delayed(const Duration(milliseconds: 800));
    return 'mock_consolidate_txid_${DateTime.now().millisecondsSinceEpoch}';
  }

  @override
  Future<void> renameWallet(String walletId, String newName) async {
    await Future.delayed(const Duration(milliseconds: 200));
  }

  @override
  Future<void> deleteWallet(String walletId) async {
    await Future.delayed(const Duration(milliseconds: 200));
  }

  @override
  Future<String> buildConsolidationPsbt({
    required String walletId,
    required List<String> outpoints,
    required String chain,
    required double feeRate,
  }) async {
    await Future.delayed(const Duration(milliseconds: 400));
    return 'cHNidP8BAHECAAAAAWNvbnNvbGlkYXRlbW9jaw==';
  }

  @override
  Future<void> enableLiquid(String walletId) async {
    await Future.delayed(const Duration(milliseconds: 200));
  }

  // ── Vault (C1) — in-memory only; no real encryption in mock mode ────────────
  bool _vaultInitialized = false;
  bool _vaultUnlocked = false;

  String _liquidNetwork = 'testnet';
  String _liquidPolicyAsset =
      '144c654344aa716d6f3abcc1ca90e5641e4e2a7f633bc09fe3baf64585819a49';

  LiquidNetworkInfo _liquidNetworkInfo() => LiquidNetworkInfo(
        network: 'liquid-$_liquidNetwork',
        shortName: _liquidNetwork,
        policyAsset: _liquidPolicyAsset,
        backend: _liquidNetwork == 'regtest' ? 'elements_rpc' : 'electrum',
        backendDescription: _liquidNetwork == 'regtest'
            ? 'elements-rpc http://127.0.0.1:18884'
            : 'electrum ssl://elements-testnet.blockstream.info:50002',
        regtestDefaultPolicyAsset:
            '5ac9f65c0efcc4775e0baec4ec03abdde22473cd3cf33c0419ca290e0751b225',
      );

  @override
  Future<LiquidNetworkInfo> getLiquidNetwork() async => _liquidNetworkInfo();

  @override
  Future<LiquidNetworkInfo> setLiquidNetwork(String network, {String? policyAsset}) async {
    await Future.delayed(const Duration(milliseconds: 200));
    final name = network.replaceFirst('liquid-', '');
    if (name != 'testnet' && name != 'regtest') {
      throw Exception('wallet-ffi: unknown Liquid network "$network"');
    }
    _liquidNetwork = name;
    _liquidPolicyAsset = name == 'regtest'
        ? ((policyAsset ?? '').trim().isEmpty
            ? '5ac9f65c0efcc4775e0baec4ec03abdde22473cd3cf33c0419ca290e0751b225'
            : policyAsset!.trim())
        : '144c654344aa716d6f3abcc1ca90e5641e4e2a7f633bc09fe3baf64585819a49';
    return _liquidNetworkInfo();
  }

  @override
  Future<String> getProtocolEscrowXpub(String walletId) async {
    await Future.delayed(const Duration(milliseconds: 150));
    return '[deadbeef/2121h/1h/0h]tpubDCMockEscrowKey1111111111111111111111111111111111111111111111111111111111111111111111111111111111111';
  }

  @override
  Future<VaultStatus> vaultStatus() async =>
      VaultStatus(initialized: _vaultInitialized, unlocked: _vaultUnlocked);

  /// Stand-in for the engine's vault key: 32 random bytes as hex, fresh on
  /// every [setupVault] so a re-created vault rejects an old exported key the
  /// same way the real engine does ("does not match").
  String _vaultKeyHex = '';

  static String _randomKeyHex() {
    final rnd = math.Random.secure();
    final sb = StringBuffer();
    for (var i = 0; i < 32; i++) {
      sb.write(rnd.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  @override
  Future<void> setupVault(String passphrase) async {
    _vaultInitialized = true;
    _vaultUnlocked = true;
    _vaultKeyHex = _randomKeyHex();
  }

  @override
  Future<void> unlockVault(String passphrase) async {
    _vaultUnlocked = true;
  }

  @override
  Future<void> lockVault() async {
    _vaultUnlocked = false;
  }

  @override
  Future<String> exportVaultKey() async {
    if (!_vaultInitialized) throw Exception('wallet-ffi: no vault is set up');
    if (!_vaultUnlocked) throw Exception('wallet-ffi: vault is locked');
    return _vaultKeyHex;
  }

  @override
  Future<void> unlockVaultWithKey(String keyHex) async {
    if (!_vaultInitialized) throw Exception('wallet-ffi: no vault is set up');
    if (!RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(keyHex)) {
      throw Exception('wallet-ffi: invalid key: expected 64 hex characters');
    }
    if (keyHex.toLowerCase() != _vaultKeyHex) {
      throw Exception('wallet-ffi: key does not match this vault');
    }
    _vaultUnlocked = true;
  }

  @override
  Future<void> verifyVaultPassphrase(String passphrase) async {
    if (passphrase.isEmpty) throw Exception('Wrong app password');
  }

  @override
  Future<void> verifyVaultKey(String keyHex) async {
    if (!_vaultInitialized) throw Exception('wallet-ffi: no vault is set up');
    if (keyHex.length != 64) {
      throw Exception('wallet-ffi: Vault key must be 64 hex characters');
    }
    if (keyHex.toLowerCase() != _vaultKeyHex) {
      throw Exception('wallet-ffi: key does not match this vault');
    }
  }

  @override
  Future<BackupVerification> verifyBackup(String walletId, String mnemonic) async {
    await Future.delayed(const Duration(milliseconds: 200));
    final matched = mnemonic.trim().split(RegExp(r'\s+')).length >= 12;
    return BackupVerification(
      matched: matched,
      reason: matched ? 'ok' : 'checksum',
      derivedFingerprint: matched ? 'f0b68896' : '',
      expectedFingerprint: 'f0b68896',
      fingerprintMatch: matched,
    );
  }

  @override
  Future<List<String>> urPsbtEncode(String psbtBase64, {int maxFragmentLen = 100}) async {
    await Future.delayed(const Duration(milliseconds: 80));
    return ['ur:crypto-psbt/mock-part-1', 'ur:crypto-psbt/mock-part-2'];
  }

  @override
  Future<List<String>> urPsetEncode(String psetBase64, {int maxFragmentLen = 100}) async {
    await Future.delayed(const Duration(milliseconds: 80));
    return ['ur:bytes/mock-part-1', 'ur:bytes/mock-part-2'];
  }

  @override
  Future<UrDecodeResult> urDecodeParts(List<String> parts) async {
    await Future.delayed(const Duration(milliseconds: 80));
    return const UrDecodeResult(
      progress: 1.0,
      complete: true,
      kind: 'psbt',
      psbtBase64: 'cHNidP8BAAoCAAAAAAAAAAAAAAAA',
    );
  }
}
