// Real FFI bridge — calls into libwallet_ffi.so via dart:ffi.
// Replaces MockWalletBridge once the cdylib is bundled with the app.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../features/create_wallet/models/hw_device.dart';
import '../features/create_wallet/models/hw_import_result.dart';
import '../features/create_wallet/models/native_device.dart';
import '../features/dashboard/models/balance_history.dart';
import '../features/dashboard/models/dashboard_data.dart';
import '../features/history/models/transaction.dart';
import '../features/receive/models/address_info.dart';
import '../features/utxos/models/utxo.dart';
import '../features/wallet_info/models/wallet_info.dart';
import '../features/wallet_picker/models/wallet_summary.dart';
import '../features/liquid/models/issue_result.dart';
import '../features/swap/models/swap_offer.dart';
import '../features/peg/models/peg_models.dart';
import '../features/send/models/tx_preview.dart';
import '../features/psbt/models/psbt_inspection.dart';
import '../features/psbt/models/pset_inspection.dart';
import 'wallet_bridge.dart';

// ── Native function typedefs ──────────────────────────────────────────────────

typedef _WalletCallNative = Pointer<Utf8> Function(
  Pointer<Utf8> method,
  Pointer<Utf8> params,
);

typedef _WalletFreeNative = Void Function(Pointer<Utf8> ptr);

typedef _SetDataDirNative = Int32 Function(Pointer<Utf8> path);

// ── Library loading ───────────────────────────────────────────────────────────

DynamicLibrary _loadLib() {
  if (Platform.isAndroid) {
    // The APK carries libwallet_ffi.so under jniLibs/<abi>/ and the Android
    // linker resolves it by soname — no path probing.
    return DynamicLibrary.open('libwallet_ffi.so');
  }
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final cwd = Directory.current.path;

  final String soname;
  final List<String> candidates;
  if (Platform.isLinux) {
    soname = 'libwallet_ffi.so';
    candidates = [
      // Bundled next to the executable.
      '$exeDir/lib/$soname',
      '$exeDir/$soname',
      // Dev fallback: workspace target directory
      '$cwd/../../../target/release/$soname',
    ];
  } else if (Platform.isMacOS) {
    soname = 'libwallet_ffi.dylib';
    candidates = [
      // Bundled inside .app/Contents/Frameworks/
      '$exeDir/../Frameworks/$soname',
      // Next to the debug executable
      '$exeDir/$soname',
      // Dev: workspace target/release (cwd = src/templar_wallet → repo root = ../../)
      '$cwd/../../target/release/$soname',
      '$cwd/../../../target/release/$soname',
      // Dev: workspace target/debug
      '$cwd/../../target/debug/$soname',
      '$cwd/../../../target/debug/$soname',
    ];
  } else if (Platform.isWindows) {
    soname = 'wallet_ffi.dll';
    candidates = [
      // Bundled next to the executable (windows/CMakeLists.txt install step).
      '$exeDir/$soname',
      '$exeDir/lib/$soname',
      '$cwd/$soname',
      // Dev: workspace target dirs (cwd = src/templar_wallet → repo root)
      '$cwd/../../target/release/$soname',
      '$cwd/../../../target/release/$soname',
      '$cwd/../../target/debug/$soname',
      '$cwd/../../../target/debug/$soname',
    ];
  } else {
    throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
  }

  for (final path in candidates) {
    if (File(path).existsSync()) return DynamicLibrary.open(path);
  }
  // Last resort: let the OS loader search its default paths.
  try {
    return DynamicLibrary.open(soname);
  } catch (e) {
    // Include every tried path so the fatal error screen is actionable.
    throw StateError(
      'Could not load the native wallet library ($soname).\n'
      'Underlying error: $e\n'
      'Paths tried:\n  ${candidates.join('\n  ')}\n  '
      '$soname (OS default search paths)',
    );
  }
}

// ── FfiWalletBridge ───────────────────────────────────────────────────────────

class FfiWalletBridge implements WalletBridge {
  FfiWalletBridge() {
    // Load and resolve symbols eagerly so construction fails fast when the
    // library is missing or broken. Calls re-resolve in their own isolate.
    final lib = _loadLib();
    lib.lookupFunction<_WalletCallNative, _WalletCallNative>('wallet_call');
    lib.lookupFunction<_WalletFreeNative, void Function(Pointer<Utf8>)>(
      'wallet_free_string',
    );
  }

  /// Point the engine at [path] before its first call. Android in practice:
  /// the platform has no XDG data dir and Dart cannot set environment
  /// variables, so main.dart passes `getApplicationSupportDirectory()` here.
  /// Returns the native status code (0 = ok, 3 = too late: the engine had
  /// already started and kept its own choice).
  static int setDataDir(String path) {
    final lib = _loadLib();
    final setDir =
        lib.lookupFunction<_SetDataDirNative, int Function(Pointer<Utf8>)>(
      'wallet_set_data_dir',
    );
    final p = path.toNativeUtf8();
    try {
      return setDir(p);
    } finally {
      calloc.free(p);
    }
  }

  // ── Core dispatch ───────────────────────────────────────────────────────────

  // Runs the FFI call in a background isolate so the main thread never blocks.
  // Both isolates share the same Rust STATE Mutex — calls are serialized there.
  static Future<Map<String, dynamic>> _callBg(
    String method,
    String paramsJson,
  ) =>
      Isolate.run(() {
        final lib = _loadLib();
        final call = lib.lookupFunction<_WalletCallNative, _WalletCallNative>(
          'wallet_call',
        );
        final free = lib.lookupFunction<
            _WalletFreeNative,
            void Function(Pointer<Utf8>)>('wallet_free_string');

        final methodPtr = method.toNativeUtf8();
        final paramsPtr = paramsJson.toNativeUtf8();
        Pointer<Utf8> resultPtr;
        try {
          resultPtr = call(methodPtr, paramsPtr);
        } finally {
          calloc.free(methodPtr);
          calloc.free(paramsPtr);
        }
        final json = resultPtr.toDartString();
        free(resultPtr);
        return jsonDecode(json) as Map<String, dynamic>;
      });

  Future<dynamic> _ok(String method, Map<String, dynamic> params) async {
    final result = await _callBg(method, jsonEncode(params));
    if (result.containsKey('err')) {
      throw Exception('wallet-ffi: ${result['err']}');
    }
    return result['ok'];
  }

  // ── WalletBridge implementation ─────────────────────────────────────────────

  @override
  Future<List<String>> generateMnemonic(int wordCount) async {
    final raw = await _ok('generate_mnemonic', {'word_count': wordCount}) as List<dynamic>;
    return raw.cast<String>();
  }

  @override
  Future<String> createWallet(String name, List<String> mnemonic, {bool liquid = false}) async {
    final raw = await _ok('create_wallet', {
      'name': name,
      'mnemonic': mnemonic.join(' '),
      'liquid': liquid,
    }) as Map<String, dynamic>;
    return raw['id'] as String;
  }

  @override
  Future<List<WalletSummary>> listWallets() async {
    final raw = await _ok('list_wallets', {}) as List<dynamic>;
    return raw.map((e) => WalletSummary.fromJson(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<void> openWallet(String walletId) async {
    await _ok('open_wallet', {'wallet_id': walletId});
  }

  @override
  Future<DashboardData> getWalletSummary(String walletId) async {
    final raw = await _ok('get_wallet_summary', {'wallet_id': walletId}) as Map<String, dynamic>;
    return _dashboardFromJson(raw);
  }

  @override
  Future<AddressInfo> generateReceiveAddress(String walletId, String asset,
      {bool fresh = false}) async {
    final raw = await _ok('generate_receive_address', {
      'wallet_id': walletId,
      'asset': asset,
      if (fresh) 'fresh': true,
    }) as Map<String, dynamic>;
    return _addressInfoFromJson(raw);
  }

  @override
  Future<List<AddressInfo>> listPreviousAddresses(String walletId, String asset) async {
    final raw = await _ok('list_previous_addresses', {
      'wallet_id': walletId,
      'asset': asset,
    }) as List<dynamic>;
    return raw.map((e) => _addressInfoFromJson(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<List<Transaction>> listActivity(
    String walletId, {
    String? chain,
    String? asset,
  }) async {
    final raw = await _ok('list_activity', {'wallet_id': walletId}) as List<dynamic>;
    return raw.map((e) => _transactionFromJson(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<List<Utxo>> listUtxos(String walletId, String chain) async {
    final raw = await _ok('list_utxos', {
      'wallet_id': walletId,
      'chain': chain,
    }) as List<dynamic>;
    return raw.map((e) => _utxoFromJson(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<void> setUtxosFrozen({
    required String walletId,
    required String chain,
    required List<String> outpoints,
    required bool frozen,
  }) async {
    await _ok('set_utxos_frozen', {
      'wallet_id': walletId,
      'chain': chain,
      'outpoints': outpoints,
      'frozen': frozen,
    });
  }

  @override
  Future<WalletInfo> getWalletInfo(String walletId) async {
    final raw = await _ok('get_wallet_info', {'wallet_id': walletId}) as Map<String, dynamic>;
    return _walletInfoFromJson(raw);
  }

  @override
  Future<BalanceHistory> getBalanceHistory(String walletId) async {
    final raw = await _ok('get_balance_history', {'wallet_id': walletId})
        as Map<String, dynamic>;
    return BalanceHistory.fromJson(raw);
  }

  @override
  Future<Map<String, String>> syncWallet(String walletId) async {
    final raw =
        await _ok('sync_wallet', {'wallet_id': walletId}) as Map<String, dynamic>;
    return raw.map((k, v) => MapEntry(k, v.toString()));
  }

  @override
  Future<TxPreview> previewTransaction({
    required String walletId,
    required List<TxOutputSpec> outputs,
    required String assetId,
    required double feeRate,
    List<String>? utxos,
  }) async {
    final raw = await _ok('preview_transaction', {
      'wallet_id': walletId,
      'outputs': outputs.map((o) => o.toJson()).toList(),
      'asset_id': assetId,
      'fee_rate': feeRate,
      'utxos': ?utxos,
    }) as Map<String, dynamic>;
    return _txPreviewFromJson(raw);
  }

  @override
  Future<String> sendTransaction({
    required String walletId,
    required List<TxOutputSpec> outputs,
    required String assetId,
    required double feeRate,
    List<String>? utxos,
  }) async {
    final raw = await _ok('send_transaction', {
      'wallet_id': walletId,
      'outputs': outputs.map((o) => o.toJson()).toList(),
      'asset_id': assetId,
      'fee_rate': feeRate,
      'utxos': ?utxos,
    });
    // A multisig send that still needs external co-signatures comes back as a
    // JSON object {partial_psbt, sigs_have, sigs_needed} instead of a txid
    // string. Re-encode it so WalletBridge's String contract holds — a txid
    // never starts with '{', so the send screen can tell the two apart.
    if (raw is Map<String, dynamic>) return jsonEncode(raw);
    return raw as String;
  }

  @override
  Future<List<HwDevice>> enumerateHwDevices() async {
    final raw = await _ok('enumerate_hw_devices', {}) as List<dynamic>;
    return raw.map((e) => HwDevice.fromJson(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<List<String>> jadePorts() async {
    final raw = await _ok('jade_ports', {}) as List<dynamic>;
    return raw.cast<String>();
  }

  @override
  Future<WalletSummary> importJadeLiquidWallet(String name) async {
    final raw = await _ok('import_jade_liquid_wallet', {'name': name})
        as Map<String, dynamic>;
    return WalletSummary.fromJson(raw);
  }

  @override
  Future<List<NativeDevice>> enumerateNativeDevices() async {
    final raw = await _ok('enumerate_native_devices', {}) as List<dynamic>;
    return raw
        .map((e) => NativeDevice.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<HwImportResult> importHwWallet(String name, String fingerprint, {bool liquid = false}) async {
    final raw = await _ok('import_hw_wallet', {
      'name': name,
      'fingerprint': fingerprint,
      'liquid': liquid,
    }) as Map<String, dynamic>;
    return HwImportResult.fromJson(raw);
  }

  @override
  Future<WalletSummary> addLiquidToWallet(String walletId) async {
    final raw = await _ok('add_liquid_to_wallet', {'wallet_id': walletId})
        as Map<String, dynamic>;
    return WalletSummary.fromJson(raw);
  }

  @override
  Future<WalletSummary> createWatchOnlyWallet(
      String name, String recvDesc, String changeDesc,
      {String? liquidCtDescriptor, bool airgap = false}) async {
    final raw = await _ok('create_watch_only_wallet', {
      'name': name,
      'recv_desc': recvDesc,
      'change_desc': changeDesc,
      'liquid_ct_desc': liquidCtDescriptor ?? '',
      'airgap': airgap,
    }) as Map<String, dynamic>;
    return WalletSummary.fromJson(raw);
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
    final raw = await _ok('create_multisig_wallet', {
      'name': name,
      'required_sigs': requiredSigs,
      'total_signers': totalSigners,
      'cosigner_xpubs': cosignerXpubs,
      'local_mnemonic': localMnemonic,
      'local_mnemonics': ?localMnemonics,
      'liquid_xpubs': liquidXpubs,
      'liquid_capable_keys': ?liquidCapableKeys,
    }) as Map<String, dynamic>;
    return WalletSummary.fromJson(raw);
  }

  @override
  Future<String> getHwCosignerXpub(String fingerprint) async {
    return await _ok('get_hw_cosigner_xpub', {'fingerprint': fingerprint})
        as String;
  }

  @override
  Future<String> getJadeLiquidCosignerXpub({String? expectFingerprint}) async {
    return await _ok('get_jade_liquid_cosigner_xpub', {
      'fingerprint': expectFingerprint ?? '',
    }) as String;
  }

  @override
  Future<String> deriveLiquidDescriptor(String btcDescriptor) async {
    return await _ok('derive_liquid_descriptor', {'btc_desc': btcDescriptor})
        as String;
  }

  @override
  Future<HwiStatus> hwiStatus() async {
    final raw = await _ok('hwi_status', {}) as Map<String, dynamic>;
    return HwiStatus.fromJson(raw);
  }

  @override
  Future<void> setHwiPath(String path) async {
    await _ok('set_hwi_path', {'path': path});
  }

  @override
  Future<String> getDataDir() async {
    return await _ok('get_data_dir', {}) as String;
  }

  @override
  Future<String> getVersion() async {
    return await _ok('version', {}) as String;
  }

  @override
  Future<String> deriveCosignerXpub(List<String> mnemonic) async {
    return await _ok('derive_cosigner_xpub', {
      'mnemonic': mnemonic.join(' '),
    }) as String;
  }

  @override
  Future<String> getCosignerXpub(String walletId) async {
    return await _ok('get_cosigner_xpub', {'wallet_id': walletId}) as String;
  }

  @override
  Future<String> deriveLiquidCosignerXpub(List<String> mnemonic) async {
    return await _ok('derive_liquid_cosigner_xpub', {
      'mnemonic': mnemonic.join(' '),
    }) as String;
  }

  @override
  Future<String> getLiquidCosignerXpub(String walletId) async {
    return await _ok('get_liquid_cosigner_xpub', {'wallet_id': walletId})
        as String;
  }

  @override
  Future<WalletSummary> repairMultisigWallet(String walletId) async {
    final raw = await _ok('repair_multisig_wallet', {'wallet_id': walletId})
        as Map<String, dynamic>;
    return WalletSummary.fromJson(raw);
  }

  @override
  Future<CosignerKeyInfo> validateCosignerKey(String key,
      {bool liquid = false}) async {
    final raw = await _ok('validate_cosigner_key', {
      'key': key,
      'liquid': liquid,
    }) as Map<String, dynamic>;
    return CosignerKeyInfo.fromJson(raw);
  }

  @override
  Future<List<String>> getMnemonic(String walletId) async {
    final raw = await _ok('get_mnemonic', {'wallet_id': walletId}) as List<dynamic>;
    return raw.cast<String>();
  }

  @override
  Future<String> getPrivateKey(String walletId) async {
    return await _ok('get_private_key', {'wallet_id': walletId}) as String;
  }

  @override
  Future<PsbtInspection> inspectPsbt(String psbtBase64) async {
    final raw = await _ok('inspect_psbt', {'psbt_base64': psbtBase64}) as Map<String, dynamic>;
    return _psbtInspectionFromJson(raw);
  }

  @override
  Future<String> signPsbt(String walletId, String psbtBase64) async {
    return await _ok('sign_psbt', {
      'wallet_id': walletId,
      'psbt_base64': psbtBase64,
    }) as String;
  }

  @override
  Future<String> sendTransactionHw({
    required String walletId,
    required List<TxOutputSpec> outputs,
    required String assetId,
    required double feeRate,
    List<String>? utxos,
  }) async {
    return await _ok('send_transaction_hw', {
      'wallet_id': walletId,
      'outputs': outputs.map((o) => o.toJson()).toList(),
      'asset_id': assetId,
      'fee_rate': feeRate,
      'utxos': ?utxos,
    }) as String;
  }

  @override
  Future<String> buildUnsignedPsbt({
    required String walletId,
    required List<TxOutputSpec> outputs,
    required double feeRate,
    String assetId = 'BTC',
    List<String>? utxos,
  }) async {
    return await _ok('build_unsigned_psbt', {
      'wallet_id': walletId,
      'outputs': outputs.map((o) => o.toJson()).toList(),
      'asset_id': assetId,
      'fee_rate': feeRate,
      'utxos': ?utxos,
    }) as String;
  }

  @override
  Future<String> signPsbtHw(String fingerprint, String psbtBase64) async {
    return await _ok('sign_psbt_hw', {
      'fingerprint': fingerprint,
      'psbt_base64': psbtBase64,
    }) as String;
  }

  @override
  Future<String> combinePsbts(List<String> psbtsBase64) async =>
      await _ok('combine_psbts', {'psbts': psbtsBase64}) as String;

  @override
  Future<PsetInspection> inspectPset(String walletId, String psetBase64) async {
    final raw = await _ok('inspect_pset', {
      'wallet_id': walletId,
      'pset_base64': psetBase64,
    }) as Map<String, dynamic>;
    return PsetInspection.fromJson(raw);
  }

  @override
  Future<String> signPset(String walletId, String psetBase64) async {
    return await _ok('sign_pset', {
      'wallet_id': walletId,
      'pset_base64': psetBase64,
    }) as String;
  }

  @override
  Future<String> signPsetHw(String walletId, String psetBase64) async {
    return await _ok('sign_pset_hw', {
      'wallet_id': walletId,
      'pset_base64': psetBase64,
    }) as String;
  }

  @override
  Future<String> combinePsets(String walletId, List<String> psetsBase64) async {
    return await _ok('combine_psets', {
      'wallet_id': walletId,
      'psets': psetsBase64,
    }) as String;
  }

  @override
  Future<String> broadcastPset(String walletId, String psetBase64) async {
    return await _ok('broadcast_pset', {
      'wallet_id': walletId,
      'pset_base64': psetBase64,
    }) as String;
  }

  @override
  Future<String> signTransactionHw({
    required String walletId,
    required List<TxOutputSpec> outputs,
    required String assetId,
    required double feeRate,
    List<String>? utxos,
  }) async {
    return await _ok('sign_transaction_hw', {
      'wallet_id': walletId,
      'outputs': outputs.map((o) => o.toJson()).toList(),
      'asset_id': assetId,
      'fee_rate': feeRate,
      'utxos': ?utxos,
    }) as String;
  }

  @override
  Future<String> broadcastSignedPsbt({
    required String walletId,
    required String psbtBase64,
  }) async {
    return await _ok('broadcast_signed_psbt', {
      'wallet_id': walletId,
      'psbt_base64': psbtBase64,
    }) as String;
  }

  @override
  Future<String> consolidateUtxos({
    required String walletId,
    required List<String> outpoints,
    required String chain,
    required double feeRate,
  }) async {
    return await _ok('consolidate_utxos', {
      'wallet_id': walletId,
      'outpoints': outpoints,
      'chain': chain,
      'fee_rate': feeRate,
    }) as String;
  }

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
    final raw = await _ok('issue_asset', {
      'wallet_id': walletId,
      'name': name,
      'ticker': ticker,
      'precision': precision,
      'domain': domain,
      'amount_sats': amountSats,
      'reissuance_tokens': reissuanceTokens,
    }) as Map<String, dynamic>;
    return _issueResultFromJson(raw);
  }

  @override
  Future<IssueResult> reissueAsset({
    required String walletId,
    required String assetId,
    required int amountSats,
  }) async {
    final raw = await _ok('reissue_asset', {
      'wallet_id': walletId,
      'asset_id': assetId,
      'amount_sats': amountSats,
    }) as Map<String, dynamic>;
    return _issueResultFromJson(raw);
  }

  @override
  Future<String> burnAsset({
    required String walletId,
    required String assetId,
    required int amountSats,
  }) async {
    return await _ok('burn_asset', {
      'wallet_id': walletId,
      'asset_id': assetId,
      'amount_sats': amountSats,
    }) as String;
  }

  @override
  Future<List<SwapOffer>> listSwaps({bool includeUnavailable = false}) async {
    final raw = await _ok('list_swaps', {
      'include_unavailable': includeUnavailable,
    }) as List<dynamic>;
    return raw.map((e) => SwapOffer.fromJson(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<SwapAnalysis> swapVerify(String proposalJson, {bool deep = false}) async {
    final raw = await _ok('swap_verify', {
      'proposal_json': proposalJson,
      'deep': deep,
    }) as Map<String, dynamic>;
    return SwapAnalysis.fromJson(raw);
  }

  @override
  Future<SwapTakePreview> swapTakePreview(String walletId, String proposalJson,
      {double? feeRate}) async {
    final raw = await _ok('swap_take_preview', {
      'wallet_id': walletId,
      'proposal_json': proposalJson,
      'fee_rate': ?feeRate,
    }) as Map<String, dynamic>;
    return SwapTakePreview.fromJson(raw);
  }

  @override
  Future<String> swapTake(String walletId, String proposalJson,
      {double? feeRate}) async {
    return await _ok('swap_take', {
      'wallet_id': walletId,
      'proposal_json': proposalJson,
      'fee_rate': ?feeRate,
    }) as String;
  }

  @override
  Future<MyOffer> swapMake(String walletId, String utxo, String wantAssetId,
      int wantAmountSats) async {
    final raw = await _ok('swap_make', {
      'wallet_id': walletId,
      'utxo': utxo,
      'want_asset_id': wantAssetId,
      'want_amount_sats': wantAmountSats,
    }) as Map<String, dynamic>;
    return MyOffer.fromJson(raw);
  }

  @override
  Future<String> swapMakePrepare(String walletId, String assetId, int amountSats,
      {double? feeRate}) async {
    return await _ok('swap_make_prepare', {
      'wallet_id': walletId,
      'asset_id': assetId,
      'amount_sats': amountSats,
      'fee_rate': ?feeRate,
    }) as String;
  }

  @override
  Future<List<MyOffer>> listMyOffers(String walletId) async {
    final raw = await _ok('list_my_offers', {'wallet_id': walletId}) as List<dynamic>;
    return raw.map((e) => MyOffer.fromJson(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<String> swapCancel(String walletId, String offerId) async {
    return await _ok('swap_cancel', {
      'wallet_id': walletId,
      'offer_id': offerId,
    }) as String;
  }

  @override
  Future<PegQuote> pegQuote(String direction, int amountSats) async {
    final raw = await _ok('peg_quote', {
      'direction': direction,
      'amount_sats': amountSats,
    }) as Map<String, dynamic>;
    return PegQuote.fromJson(raw);
  }

  @override
  Future<PegOrder> pegStart(String walletId, String direction, int amountSats,
      String payoutAddress) async {
    final raw = await _ok('peg_start', {
      'wallet_id': walletId,
      'direction': direction,
      'amount_sats': amountSats,
      'payout_address': payoutAddress,
    }) as Map<String, dynamic>;
    return PegOrder.fromJson(raw);
  }

  @override
  Future<PegOrder> pegStatus(String orderId) async {
    final raw = await _ok('peg_status', {'order_id': orderId}) as Map<String, dynamic>;
    return PegOrder.fromJson(raw);
  }

  @override
  Future<List<PegOrder>> pegList(String walletId) async {
    final raw = await _ok('peg_list', {'wallet_id': walletId}) as List<dynamic>;
    return raw.map((e) => PegOrder.fromJson(e as Map<String, dynamic>)).toList();
  }

  @override
  Future<PegOrder> pegCancel(String orderId) async {
    final raw = await _ok('peg_cancel', {'order_id': orderId}) as Map<String, dynamic>;
    return PegOrder.fromJson(raw);
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
    final raw = await _ok('reregister_asset', {
      'wallet_id': walletId,
      'asset_id': assetId,
      'name': name,
      'ticker': ticker,
      'precision': precision,
      'domain': domain,
    }) as Map<String, dynamic>;
    return raw['registered'] as bool? ?? false;
  }

  @override
  Future<String> verifyHwAddress(String walletId) async {
    return await _ok('verify_hw_address', {'wallet_id': walletId}) as String;
  }

  @override
  Future<void> renameWallet(String walletId, String newName) async {
    await _ok('rename_wallet', {'wallet_id': walletId, 'new_name': newName});
  }

  @override
  Future<void> deleteWallet(String walletId) async {
    await _ok('delete_wallet', {'wallet_id': walletId});
  }

  @override
  Future<String> buildConsolidationPsbt({
    required String walletId,
    required List<String> outpoints,
    required String chain,
    required double feeRate,
  }) async {
    return await _ok('build_consolidation_psbt', {
      'wallet_id': walletId,
      'outpoints': outpoints,
      'chain': chain,
      'fee_rate': feeRate,
    }) as String;
  }

  @override
  Future<void> enableLiquid(String walletId) async {
    await _ok('enable_liquid', {'wallet_id': walletId});
  }

  @override
  Future<LiquidNetworkInfo> getLiquidNetwork() async {
    final raw = await _ok('get_liquid_network', {}) as Map<String, dynamic>;
    return LiquidNetworkInfo.fromJson(raw);
  }

  @override
  Future<LiquidNetworkInfo> setLiquidNetwork(String network, {String? policyAsset}) async {
    final raw = await _ok('set_liquid_network', {
      'network': network,
      if (policyAsset != null && policyAsset.trim().isNotEmpty)
        'policy_asset': policyAsset.trim(),
    }) as Map<String, dynamic>;
    return LiquidNetworkInfo.fromJson(raw);
  }

  @override
  Future<String> getProtocolEscrowXpub(String walletId) async =>
      await _ok('get_protocol_escrow_xpub', {'wallet_id': walletId}) as String;

  @override
  Future<VaultStatus> vaultStatus() async {
    final raw = await _ok('vault_status', {}) as Map<String, dynamic>;
    return VaultStatus(
      initialized: raw['initialized'] as bool? ?? false,
      unlocked: raw['unlocked'] as bool? ?? false,
      plaintextSeedWallets: raw['plaintext_seed_wallets'] as int? ?? 0,
    );
  }

  @override
  Future<void> setupVault(String passphrase) async {
    await _ok('setup_vault', {'passphrase': passphrase});
  }

  @override
  Future<void> unlockVault(String passphrase) async {
    await _ok('unlock_vault', {'passphrase': passphrase});
  }

  @override
  Future<void> lockVault() async {
    await _ok('lock_vault', {});
  }

  @override
  Future<String> exportVaultKey() async {
    final raw = await _ok('export_vault_key', {}) as Map<String, dynamic>;
    return raw['key_hex'] as String;
  }

  @override
  Future<void> unlockVaultWithKey(String keyHex) async {
    await _ok('unlock_vault_with_key', {'key_hex': keyHex});
  }

  @override
  Future<void> verifyVaultPassphrase(String passphrase) async {
    await _ok('verify_vault_passphrase', {'passphrase': passphrase});
  }

  @override
  Future<void> verifyVaultKey(String keyHex) async {
    await _ok('verify_vault_key', {'key_hex': keyHex});
  }

  @override
  Future<BackupVerification> verifyBackup(String walletId, String mnemonic) async {
    final raw = await _ok('verify_backup', {
      'wallet_id': walletId,
      'mnemonic': mnemonic,
    }) as Map<String, dynamic>;
    return BackupVerification.fromJson(raw);
  }

  @override
  Future<List<String>> urPsbtEncode(String psbtBase64, {int maxFragmentLen = 100}) async {
    final raw = await _ok('ur_psbt_encode', {
      'psbt_base64': psbtBase64,
      'max_fragment_len': maxFragmentLen,
    }) as List<dynamic>;
    return raw.cast<String>();
  }

  @override
  Future<List<String>> urPsetEncode(String psetBase64, {int maxFragmentLen = 100}) async {
    final raw = await _ok('ur_pset_encode', {
      'pset_base64': psetBase64,
      'max_fragment_len': maxFragmentLen,
    }) as List<dynamic>;
    return raw.cast<String>();
  }

  @override
  Future<UrDecodeResult> urDecodeParts(List<String> parts) async {
    final raw = await _ok('ur_decode_parts', {'parts': parts}) as Map<String, dynamic>;
    return UrDecodeResult.fromJson(raw);
  }

  // ── JSON → model mappers ────────────────────────────────────────────────────

  static DashboardData _dashboardFromJson(Map<String, dynamic> j) {
    final assets = (j['assets'] as List<dynamic>? ?? [])
        .map((e) => _assetBalanceFromJson(e as Map<String, dynamic>))
        .toList();
    final activity = (j['recent_activity'] as List<dynamic>? ?? [])
        .map((e) => _recentActivityFromJson(e as Map<String, dynamic>))
        .toList();
    return DashboardData(
      walletId: j['wallet_id'] as String,
      walletName: j['wallet_name'] as String,
      totalBalanceDisplay: j['total_balance_display'] as String? ?? '0 BTC',
      assets: assets,
      recentActivity: activity,
      syncState: j['sync_state'] as String? ?? 'synced',
      liquidNetwork: j['liquid_network'] as String? ?? 'liquid-testnet',
    );
  }

  static AssetBalance _assetBalanceFromJson(Map<String, dynamic> j) => AssetBalance(
        assetId: j['asset_id'] as String? ?? j['ticker'] as String,
        ticker: j['ticker'] as String,
        name: j['name'] as String,
        amount: j['amount'] as int? ?? 0,
        displayAmount: j['display_amount'] as String? ?? '0',
        fiatEstimate: j['fiat_estimate'] as String?,
        status: j['status'] as String? ?? 'synced',
        utxoCount: j['utxo_count'] as int? ?? 0,
        isNative: j['is_native'] as bool? ?? false,
      );

  static RecentActivityItem _recentActivityFromJson(Map<String, dynamic> j) {
    final ts = j['timestamp'] as int? ?? 0;
    return RecentActivityItem(
      txid: j['txid'] as String,
      direction: j['direction'] as String? ?? 'outgoing',
      chain: j['chain'] as String? ?? 'bitcoin',
      amount: j['amount'] as String? ?? '0',
      ticker: j['ticker'] as String? ?? 'BTC',
      timestamp: DateTime.fromMillisecondsSinceEpoch(ts * 1000),
      confirmations: j['confirmations'] as int? ?? 0,
      note: j['note'] as String?,
      counterparty: j['counterparty'] as String?,
    );
  }

  static AddressInfo _addressInfoFromJson(Map<String, dynamic> j) => AddressInfo(
        address: j['address'] as String,
        index: j['index'] as int? ?? 0,
        asset: j['asset'] as String? ?? 'BTC',
        label: j['label'] as String?,
        receivedSats: j['received_sats'] as int? ?? 0,
        derivationPath: j['derivation_path'] as String?,
      );

  static Transaction _transactionFromJson(Map<String, dynamic> j) {
    final dir = (j['direction'] as String?) == 'incoming'
        ? TxDirection.incoming
        : TxDirection.outgoing;
    final chain = (j['chain'] as String?) == 'liquid' ? TxChain.liquid : TxChain.bitcoin;
    final ts = j['timestamp'] as int? ?? 0;
    return Transaction(
      txid: j['txid'] as String,
      direction: dir,
      chain: chain,
      amount: j['amount'] as String? ?? '0',
      ticker: j['ticker'] as String? ?? 'BTC',
      timestamp: DateTime.fromMillisecondsSinceEpoch(ts * 1000),
      confirmations: j['confirmations'] as int? ?? 0,
      fee: j['fee'] as String?,
      note: j['note'] as String?,
      counterparty: j['counterparty'] as String?,
      fiatEstimate: j['fiat_estimate'] as String?,
    );
  }

  static Utxo _utxoFromJson(Map<String, dynamic> j) {
    final stateStr = j['state'] as String? ?? 'available';
    final state = switch (stateStr) {
      'frozen' => UtxoState.frozen,
      'dusty' => UtxoState.dusty,
      'unconfirmed' => UtxoState.unconfirmed,
      _ => UtxoState.available,
    };
    return Utxo(
      outpoint: j['outpoint'] as String,
      amount: j['amount'] as int? ?? 0,
      displayAmount: j['display_amount'] as String? ?? '0',
      confirmations: j['confirmations'] as int? ?? 0,
      state: state,
      label: j['label'] as String?,
      address: j['address'] as String?,
      ticker: j['ticker'] as String?,
      assetId: j['asset_id'] as String?,
    );
  }

  static WalletInfo _walletInfoFromJson(Map<String, dynamic> j) {
    final backupTs = j['last_backup_at'] as int?;
    return WalletInfo(
      id: j['id'] as String,
      name: j['name'] as String,
      network: j['network'] as String? ?? 'Testnet',
      masterFingerprint: j['master_fingerprint'] as String? ?? '',
      derivationPath: j['derivation_path'] as String? ?? '',
      scriptType: j['script_type'] as String? ?? '',
      xpub: j['xpub'] as String? ?? '',
      receiveDescriptor: j['receive_descriptor'] as String? ?? '',
      changeDescriptor: j['change_descriptor'] as String? ?? '',
      multipathDescriptor: j['multipath_descriptor'] as String?,
      liquidDescriptor: j['liquid_descriptor'] as String?,
      masterBlindingKey: j['master_blinding_key'] as String?,
      hasSeed: j['has_seed'] as bool? ?? false,
      hasPassphrase: j['has_passphrase'] as bool? ?? false,
      lastBackupAt: backupTs != null
          ? DateTime.fromMillisecondsSinceEpoch(backupTs * 1000)
          : null,
      cosignerKeys: (j['cosigner_keys'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      requiredSigs: (j['required_sigs'] as num?)?.toInt(),
      localFingerprints: (j['local_fingerprints'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      liquidNetwork: j['liquid_network'] as String? ?? 'liquid-testnet',
    );
  }

  static TxPreview _txPreviewFromJson(Map<String, dynamic> j) => TxPreview(
        chain: j['chain'] as String? ?? 'bitcoin',
        recipientAddress: j['recipient_address'] as String? ?? '',
        amountDisplay: j['amount_display'] as String? ?? '0',
        feeSats: j['fee_sats'] as int? ?? 0,
        feeDisplay: j['fee_display'] as String? ?? '0 sats',
        totalDisplay: j['total_display'] as String? ?? '0',
        feeRate: (j['fee_rate'] as num?)?.toDouble() ?? 0,
        vsizeEst: (j['vsize_est'] as num?)?.toInt() ?? 0,
        inputs: (j['inputs'] as List<dynamic>? ?? [])
            .map((e) => TxIo.fromJson(e as Map<String, dynamic>))
            .toList(),
        outputs: (j['outputs'] as List<dynamic>? ?? [])
            .map((e) => TxIo.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  static PsbtInspection _psbtInspectionFromJson(Map<String, dynamic> j) => PsbtInspection(
        inputs: (j['inputs'] as List<dynamic>? ?? [])
            .map((e) => _psbtInputFromJson(e as Map<String, dynamic>))
            .toList(),
        outputs: (j['outputs'] as List<dynamic>? ?? [])
            .map((e) => _psbtOutputFromJson(e as Map<String, dynamic>))
            .toList(),
        // A null fee is a fee the engine could not compute (an input's
        // amount is unknown); it stays null so the UI prints "unknown"
        // rather than a number nobody measured.
        feeSats: j['fee_sats'] as int?,
        feeDisplay: j['fee_display'] as String? ??
            (j['fee_sats'] == null ? 'unknown' : '${j['fee_sats']} sats'),
        sigsPresent: j['sigs_present'] as int? ?? 0,
        sigsRequired: j['sigs_required'] as int?,
        signers: (j['signers'] as List<dynamic>? ?? [])
            .map((e) => _psbtSignerFromJson(e as Map<String, dynamic>))
            .toList(),
        policyHint: j['policy_hint'] as String? ?? '',
        rawPsbt: j['raw_psbt'] as String? ?? '',
        finalized: j['finalized'] as bool? ?? false,
        utxoCheck: PsbtUtxoStatus.fromWire(j['utxo_check'] as String?) ??
            PsbtUtxoStatus.ok,
        ownershipKnown: j['ownership_known'] as bool? ?? false,
      );

  static PsbtInput _psbtInputFromJson(Map<String, dynamic> j) {
    final amount = j['amount_sats'] as int?;
    return PsbtInput(
      outpoint: j['outpoint'] as String,
      amountSats: amount,
      displayAmount: j['display_amount'] as String? ??
          (amount == null ? 'unknown' : '$amount sats'),
      // An engine that reports no status but no amount either is describing
      // a missing previous output in the contract's own terms.
      utxoStatus: PsbtUtxoStatus.fromWire(j['utxo_status'] as String?) ??
          (amount == null ? PsbtUtxoStatus.missing : PsbtUtxoStatus.ok),
      isMine: j['is_mine'] as bool?,
    );
  }

  static PsbtOutput _psbtOutputFromJson(Map<String, dynamic> j) => PsbtOutput(
        address: j['address'] as String,
        amountSats: j['amount_sats'] as int? ?? 0,
        displayAmount: j['display_amount'] as String? ?? '0',
        isMine: j['is_mine'] as bool?,
      );

  static PsbtSigner _psbtSignerFromJson(Map<String, dynamic> j) => PsbtSigner(
        fingerprint: j['fingerprint'] as String,
        hasSigned: j['has_signed'] as bool? ?? false,
      );

  static IssueResult _issueResultFromJson(Map<String, dynamic> j) => IssueResult(
        assetId: j['asset_id'] as String,
        tokenId: j['token_id'] as String?,
        txid: j['txid'] as String,
        registryRegistered: j['registry_registered'] as bool? ?? false,
        proofUrl: j['proof_url'] as String? ?? '',
        proofContent: j['proof_content'] as String? ?? '',
      );
}
