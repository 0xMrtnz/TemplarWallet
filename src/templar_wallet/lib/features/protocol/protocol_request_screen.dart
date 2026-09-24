import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_state.dart';
import '../../app/routes.dart';
import '../../bridge/bridge_provider.dart';
import '../../bridge/wallet_bridge.dart';
import '../../shared/widgets/app_password_gate.dart';
import '../../shared/widgets/banners.dart';
import '../../shared/widgets/buttons.dart';
import '../../shared/widgets/cards.dart';
import '../../shared/widgets/code_box.dart';
import '../../shared/widgets/hybrid_kit.dart';
import '../../shared/widgets/page_header.dart';
import '../../services/protocol_store.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_scheme.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import '../psbt/models/pset_inspection.dart';
import '../settings/liquid_network_switch.dart';
import '../vault/lock_action.dart';
import '../wallet_picker/models/wallet_summary.dart';
import 'models/protocol_link.dart';
import 'models/protocol_records.dart';
import 'models/protocol_wallet_fit.dart';
import 'protocol_confirm_gate.dart';
import 'protocol_paste_card.dart';
import 'protocol_network_mismatch_card.dart';

/// Handles a `templar://connect` or `templar://sign` request from a Templar Protocol
/// site (docs/connector-protocol.md §3–§4 in the Templar Protocol repository).
///
/// Lives outside the wallet shell so a link can be answered before any
/// wallet is open: the screen asks for one when needed, and for the vault
/// passphrase when storage is locked. It fetches the request, validates it
/// (network, origin, transport, expiry), shows what will leave the wallet
/// next to what the site claims, and only after an explicit confirmation
/// plus the app password does it sign and POST the answer. The PSET is
/// never stored and never broadcast from here — the site combines and
/// broadcasts (it is the facilitator, not the custodian).
class ProtocolRequestScreen extends StatefulWidget {
  const ProtocolRequestScreen({super.key, this.rawLink});

  /// The `templar://…` link as delivered by the OS, or null to show a paste
  /// box (manual testing without a registered URL handler).
  final String? rawLink;

  @override
  State<ProtocolRequestScreen> createState() => _ProtocolRequestScreenState();
}

enum _Phase { paste, loading, locked, error, mismatch, chooseWallet, review, done }

class _ProtocolRequestScreenState extends State<ProtocolRequestScreen> {
  final _bridge = walletBridge;

  _Phase _phase = _Phase.loading;
  String? _error;

  /// The link this run is answering. Not `widget.rawLink`: a pasted link has
  /// none, and after a network switch the request is fetched again — both
  /// need the text that actually started the run.
  String? _raw;
  ProtocolLink? _link;
  ProtocolRequest? _request;

  /// Set when the site and the wallet are not on the same chain. Carries
  /// both sides, so the card can offer the switch.
  ProtocolNetworkMismatch? _mismatch;

  /// The engine's Liquid state, read on every run: what the wallet signs on,
  /// whether the network is locked by the environment, and the stock regtest
  /// asset id the mismatch card prefills.
  LiquidNetworkInfo? _netInfo;

  /// Wallet the request is answered with. Chosen here, not assumed: a link
  /// may arrive with another wallet open, or none.
  WalletSummary? _wallet;
  List<WalletSummary> _wallets = const [];

  /// The wallet Settings › Templar Protocol names, when it can answer this
  /// request. Shown first in the chooser; it never removes the choice.
  String? _preferredWalletId;

  // Connect: what will be shared.
  String? _ctDescriptor;
  String? _escrowXpub;
  String? _receiveAddress;

  // Sign: the wallet's own reading of the PSET.
  PsetInspection? _inspection;

  bool _busy = false;
  String? _nextUrl;

  @override
  void initState() {
    super.initState();
    final raw = widget.rawLink;
    if (raw == null || raw.trim().isEmpty) {
      _phase = _Phase.paste;
    } else {
      _start(raw);
    }
  }

  @override
  void didUpdateWidget(covariant ProtocolRequestScreen old) {
    super.didUpdateWidget(old);
    // Belt and braces with the router's key: never keep answering an old
    // request when a new link is handed to this element.
    if (old.rawLink != widget.rawLink && widget.rawLink != null) {
      _start(widget.rawLink!);
    }
  }


  static String _clean(Object e) => e
      .toString()
      .replaceFirst('Exception: ', '')
      .replaceFirst('wallet-ffi: ', '');

  void _fail(Object e) {
    if (!mounted) return;
    setState(() {
      _phase = _Phase.error;
      _busy = false;
      _error = _clean(e);
    });
  }

  // ── Fetch + validate ───────────────────────────────────────────────────────

  Future<void> _start(String raw) async {
    debugPrint('[protocol] request: ${raw.split('&nonce=').first}');
    setState(() {
      _raw = raw;
      _phase = _Phase.loading;
      _error = null;
      _request = null;
      _mismatch = null;
      _inspection = null;
      _nextUrl = null;
      // A switch closed whatever was open; and a second link is a second
      // decision, not a continuation of the first.
      _wallet = null;
      _ctDescriptor = null;
      _escrowXpub = null;
      _receiveAddress = null;
    });
    ProtocolRequest? fetched;
    try {
      final link = ProtocolLink.parse(raw);
      _link = link;

      // Locked storage: nothing can be read or signed. Ask, then resume.
      final vault = await _bridge.vaultStatus();
      if (vault.initialized && !vault.unlocked) {
        if (mounted) setState(() => _phase = _Phase.locked);
        return;
      }

      final request = fetched = await _fetch(link);
      final info = await _network();
      validateProtocolRequest(
        link,
        request,
        activeNetwork: info.network,
        activePolicyAsset: info.isRegtest ? info.policyAsset : null,
      );
      if (!mounted) return;
      setState(() => _request = request);
      await _pickWallet();
    } on ProtocolNetworkMismatch catch (e) {
      // Not a dead end: the wallet can usually be moved to the site's chain
      // from here, so this gets a card of its own.
      if (!mounted) return;
      setState(() {
        _phase = _Phase.mismatch;
        _busy = false;
        _error = null;
        _mismatch = e;
      });
    } on ProtocolLinkError catch (e) {
      // A signing request that died before it could be answered is still
      // part of the user's history: without it the loan page says "waiting
      // for your signature" and the wallet says nothing at all.
      if (fetched != null &&
          _link?.action == ProtocolAction.sign &&
          !fetched.expiresAtTime.isAfter(DateTime.now().toUtc())) {
        await _record(fetched, ProtocolSignOutcome.expired);
      }
      _fail(e);
    } catch (e) {
      _fail(e);
    }
  }

  /// Moves the wallet to the site's chain, then answers the request again.
  ///
  /// The switch itself is the one Settings runs (liquid_network_switch.dart):
  /// same confirmation, same closing of the open wallet. What is added here
  /// is the retry — the point of the card is that the user does not have to
  /// come back with the link a second time.
  Future<void> _switchNetwork(String? policyAsset) async {
    final m = _mismatch;
    final target = m?.targetShortName;
    final raw = _raw;
    if (m == null || target == null || raw == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final done = await switchLiquidNetwork(
        context,
        target: target,
        policyAsset: policyAsset,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      if (done == null) return; // Cancelled at the dialog.
      setState(() => _netInfo = done.info);
      await _start(raw);
    } on LiquidNetworkSwitchError catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    }
  }

  Future<ProtocolRequest> _fetch(ProtocolLink link) async {
    final http.Response resp;
    try {
      resp = await http
          .get(link.url, headers: const {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw ProtocolLinkError('${link.url.host} did not answer within 15 seconds.');
    } catch (e) {
      throw ProtocolLinkError('Could not reach ${link.url.host}: ${_clean(e)}');
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw ProtocolLinkError(
          '${link.url.host} answered HTTP ${resp.statusCode} for this request. '
          'It may have expired or been used already.');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(resp.bodyBytes));
    } catch (_) {
      throw const ProtocolLinkError('The site did not answer with JSON.');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const ProtocolLinkError('The site did not answer with a request object.');
    }
    return ProtocolRequest.fromJson(decoded);
  }

  /// Always asks the engine: the network is what the wallet will actually
  /// sign on, and a cached value could lag a switch made elsewhere.
  Future<LiquidNetworkInfo> _network() async {
    final info = await _bridge.getLiquidNetwork();
    if (mounted) {
      context.read<AppState>().setLiquidNetworkInfo(info);
      setState(() => _netInfo = info);
    }
    return info;
  }

  // ── Wallet choice ──────────────────────────────────────────────────────────

  bool get _isConnect => _link?.action == ProtocolAction.connect;

  /// Wallets that can answer this request — the same rule Settings offers
  /// the preferred wallet from (models/protocol_wallet_fit.dart).
  bool _eligible(WalletSummary w) => protocolWalletFits(w, connect: _isConnect);

  Future<void> _pickWallet() async {
    final wallets = await _bridge.listWallets();
    final preferredId = await ProtocolStore.instance.preferredWalletId();
    if (!mounted) return;
    final appState = context.read<AppState>();
    final activeId = appState.activeWalletId;
    final active = wallets.where((w) => w.id == activeId).firstOrNull;
    final preferred = wallets.where((w) => w.id == preferredId).firstOrNull;
    setState(() {
      _wallets = wallets;
      _preferredWalletId = preferred != null && _eligible(preferred)
          ? preferred.id
          : null;
    });
    // A sign request is answered without asking: by the wallet named in
    // Settings › Templar Protocol if there is one, else by the open wallet when
    // it qualifies. Connect always shows the choice — it decides which wallet
    // the site will know from now on.
    if (!_isConnect) {
      final signer = (preferred != null && _eligible(preferred))
          ? preferred
          : (active != null && _eligible(active) ? active : null);
      if (signer != null) {
        await _useWallet(signer);
        return;
      }
    }
    if (mounted) setState(() => _phase = _Phase.chooseWallet);
  }

  Future<void> _useWallet(WalletSummary w) async {
    setState(() {
      _phase = _Phase.loading;
      _wallet = w;
    });
    try {
      final appState = context.read<AppState>();
      if (appState.activeWalletId != w.id) {
        await _bridge.openWallet(w.id);
        if (!mounted) return;
        appState.setActiveWallet(
          w.id,
          name: w.name,
          type: w.displayType,
          liquid: w.liquidEnabled,
          bitcoin: w.bitcoinEnabled,
        );
      }
      if (_isConnect) {
        await _prepareConnect(w);
      } else {
        await _prepareSign(w);
      }
    } catch (e) {
      _fail(e);
    }
  }

  Future<void> _prepareConnect(WalletSummary w) async {
    final info = await _bridge.getWalletInfo(w.id);
    final desc = info.liquidDescriptor;
    if (desc == null || desc.isEmpty) {
      throw ProtocolLinkError(
          '"${w.name}" has no Liquid descriptor. Enable Liquid on it first.');
    }
    final xpub = await _bridge.getProtocolEscrowXpub(w.id);
    final addr = await _bridge.generateReceiveAddress(w.id, 'LBTC');
    if (!mounted) return;
    setState(() {
      _ctDescriptor = desc;
      _escrowXpub = xpub;
      _receiveAddress = addr.address;
      _phase = _Phase.review;
    });
  }

  Future<void> _prepareSign(WalletSummary w) async {
    final pset = _request!.pset!;
    // The engine refuses a PSET carrying another network's assets here,
    // independently of what the site claimed in `network`.
    final inspection = await _bridge.inspectPset(w.id, pset);
    if (!mounted) return;
    setState(() {
      _inspection = inspection;
      _phase = _Phase.review;
    });
  }

  // ── Answer ─────────────────────────────────────────────────────────────────

  Future<void> _confirmConnect() async {
    final w = _wallet!;
    final req = _request!;
    final ok = await showSpendPasswordGate(
      context,
      title: 'Share this wallet with ${req.site}?',
      confirmLabel: 'Share',
      message: 'Templar will send ${req.site} the watch-only descriptor of '
          '"${w.name}" (it can then see this wallet\'s Liquid balance and '
          'history), its loan escrow key, and a receive address. No secret '
          'leaves this computer.',
    );
    if (!ok || !mounted) return;
    final accepted = await _post({
      'version': 1,
      'nonce': req.nonce,
      'network': req.network,
      'ct_descriptor': _ctDescriptor,
      'escrow_xpub': _escrowXpub,
      'receive_address': _receiveAddress,
      'wallet_name': 'Templar — ${w.name}',
      'signer': w.isHardwareWallet ? 'jade' : 'software',
    });
    // Only once the site has taken it: a refused callback shared nothing.
    if (accepted) await _recordConnect();
  }

  /// Remembers that this site now holds a watch-only view of this wallet.
  /// What is kept is deliberately thin — see protocol_records.dart.
  Future<void> _recordConnect() async {
    final w = _wallet;
    final req = _request;
    if (w == null || req == null) return;
    await ProtocolStore.instance.recordConnect(ProtocolConnectedSite(
      site: req.site,
      origin: _link?.url.origin ?? '',
      network: req.network,
      walletId: w.id,
      walletName: w.name,
      connectedAt: DateTime.now().toUtc(),
      escrowFingerprint: protocolKeyFingerprint(_escrowXpub),
      receiveAddress: _receiveAddress ?? '',
    ));
  }

  /// Remembers how a signing request ended.
  Future<void> _record(ProtocolRequest req, ProtocolSignOutcome outcome) async {
    await ProtocolStore.instance.recordSign(ProtocolSignRecord(
      site: req.site,
      origin: _link?.url.origin ?? '',
      walletName: _wallet?.name ?? '',
      at: DateTime.now().toUtc(),
      outcome: outcome,
      loanRef: req.loanRef ?? '',
      action: req.action ?? '',
    ));
  }

  Future<void> _confirmSign() async {
    final w = _wallet!;
    final req = _request!;
    final ok = await showSpendPasswordGate(
      context,
      title: 'Sign for ${req.site}?',
      message: 'Templar is about to sign this ${req.actionLabel.toLowerCase()} '
          'with the key of "${w.name}" and send the signature to ${req.site}. '
          'The site broadcasts once every party has signed; nothing is '
          'broadcast from here.',
    );
    if (!ok) {
      await _record(req, ProtocolSignOutcome.refused);
      return;
    }
    if (!mounted) return;
    setState(() => _busy = true);
    final String signed;
    try {
      signed = w.isHardwareWallet
          ? await _bridge.signPsetHw(w.id, req.pset!)
          : await _bridge.signPset(w.id, req.pset!);
    } catch (e) {
      await _record(req, ProtocolSignOutcome.failed);
      _fail(ProtocolLinkError('Signing failed: ${_clean(e)}'));
      return;
    }
    if (!mounted) return;
    final accepted = await _post({
      'version': 1,
      'id': req.id,
      'nonce': req.nonce,
      'pset': signed,
    });
    await _record(
        req, accepted ? ProtocolSignOutcome.signed : ProtocolSignOutcome.failed);
  }

  /// Sends the answer. Returns whether the site accepted it; a refusal has
  /// already been shown by then.
  Future<bool> _post(Map<String, dynamic> body) async {
    final req = _request!;
    setState(() => _busy = true);
    try {
      final http.Response resp;
      try {
        resp = await http
            .post(
              req.callback,
              headers: const {
                'Content-Type': 'application/json',
                'Accept': 'application/json',
              },
              body: jsonEncode(body),
            )
            .timeout(const Duration(seconds: 20));
      } on TimeoutException {
        throw ProtocolLinkError(
            '${req.callback.host} did not accept the answer within 20 seconds. '
            'Nothing was broadcast; you can retry from the site.');
      } catch (e) {
        throw ProtocolLinkError('Could not reach ${req.callback.host}: ${_clean(e)}');
      }
      Map<String, dynamic> reply = const {};
      try {
        final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
        if (decoded is Map<String, dynamic>) reply = decoded;
      } catch (_) {}
      final accepted = resp.statusCode >= 200 &&
          resp.statusCode < 300 &&
          (reply['ok'] == true || reply.isEmpty);
      if (!accepted) {
        final why = (reply['error'] as String?)?.trim();
        throw ProtocolLinkError(
            '${req.site} rejected the answer (HTTP ${resp.statusCode})'
            '${why != null && why.isNotEmpty ? ': $why' : '.'}');
      }
      if (!mounted) return true;
      setState(() {
        _busy = false;
        _nextUrl = reply['next'] as String?;
        _phase = _Phase.done;
      });
      return true;
    } on ProtocolLinkError catch (e) {
      _fail(e);
      return false;
    } catch (e) {
      _fail(e);
      return false;
    }
  }

  Future<void> _openNext() async {
    final next = _nextUrl;
    if (next == null) return;
    final uri = Uri.tryParse(next);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// The browser, at the site's root — where the user clicks "Connect" or
  /// opens the loan again. Offered after a refusal, because a request that
  /// died (an expired token, a token already used by the run before a
  /// network switch) is restarted there, not here.
  Future<void> _openSite() async {
    final link = _link;
    if (link == null) return;
    await launchUrl(Uri.parse(link.url.origin),
        mode: LaunchMode.externalApplication);
  }

  /// Settings › Network & Sync. It lives inside the wallet shell, so with no
  /// wallet open the router would bounce to the picker without a word —
  /// say so instead of appearing to ignore the tap.
  void _openNetworkSettings() {
    if (context.read<AppState>().activeWalletId != null) {
      context.go(AppRoutes.settingsNetwork);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Open a wallet first, then Settings › Network & Sync.'),
        duration: Duration(seconds: 5),
      ),
    );
    context.go(AppRoutes.walletPicker);
  }

  void _leave() {
    final hasWallet = context.read<AppState>().activeWalletId != null;
    context.go(hasWallet ? AppRoutes.dashboard : AppRoutes.walletPicker);
  }

  // ── UI ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final req = _request;
    final title = switch (_link?.action) {
      ProtocolAction.connect => 'Connect wallet',
      ProtocolAction.sign => req?.actionLabel ?? 'Sign request',
      null => 'Templar Protocol',
    };
    final subtitle = req != null
        ? '${req.site} · ${protocolNetworkLabel(req.network)}'
        : 'A site is asking this wallet to take part in a loan.';

    return Scaffold(
      body: PageBackground.flat(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 980),
            child: ListView(
              padding: EdgeInsets.all(AppSpacing.pagePadding(context)),
              children: [
                PageHeader(
                  title: title,
                  subtitle: subtitle,
                  actions: [
                    GhostButton(
                      label: _phase == _Phase.done ? 'Close' : 'Cancel',
                      icon: Icons.close,
                      onPressed: _busy ? null : _leave,
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.lg),
                _body(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _body() => switch (_phase) {
        _Phase.paste => ProtocolPasteCard(onOpen: _start),
        _Phase.loading => Center(
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.pagePadding(context)),
              child: const CircularProgressIndicator(),
            ),
          ),
        _Phase.locked => _LockedCard(onUnlock: () {
            pushVaultUnlock(context, onUnlocked: () {
              if (mounted && _raw != null) _start(_raw!);
            });
          }),
        _Phase.error => _ErrorCard(
            message: _error ?? 'Something went wrong.',
            onRetry: _raw == null ? null : () => _start(_raw!),
            onOpenSite: _link == null ? null : _openSite,
            siteName: _request?.site ?? _link?.url.host,
          ),
        _Phase.mismatch => ProtocolNetworkMismatchCard(
            mismatch: _mismatch!,
            info: _netInfo,
            busy: _busy,
            onSwitch: _switchNetwork,
            onOpenSettings: _openNetworkSettings,
          ),
        _Phase.chooseWallet => _WalletChoice(
            wallets: _wallets,
            eligible: _eligible,
            connect: _isConnect,
            preferredWalletId: _preferredWalletId,
            onPick: _useWallet,
          ),
        _Phase.review => _isConnect ? _connectReview() : _signReview(),
        _Phase.done => _DoneCard(
            site: _request!.site,
            connect: _isConnect,
            next: _nextUrl,
            onOpen: _openNext,
            onClose: _leave,
          ),
      };

  Widget _connectReview() {
    final req = _request!;
    final w = _wallet!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InfoBanner(
          title: 'What ${req.site} will receive',
          message: 'A watch-only view of "${w.name}" on ${protocolNetworkLabel(req.network)}: '
              'the site can see this wallet\'s Liquid balance and history and '
              'build loan transactions for it. It cannot spend. The escrow key '
              'is a separate account below your seed, used only inside loan '
              'contracts.',
        ),
        const SizedBox(height: AppSpacing.lg),
        FormCard(
          title: 'Shared with ${req.site}',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CopyRow(label: 'Wallet', value: 'Templar — ${w.name}', mono: false),
              const Divider(height: 1),
              CopyRow(label: 'Signer', value: w.isHardwareWallet ? 'jade' : 'software', mono: false),
              const Divider(height: 1),
              CopyRow(label: 'Network', value: protocolNetworkLabel(req.network), mono: false),
              const Divider(height: 1),
              CopyRow(label: 'Receive address', value: _receiveAddress ?? ''),
              const SizedBox(height: AppSpacing.lg),
              CodeBox(label: 'Liquid CT descriptor (watch-only)', value: _ctDescriptor ?? ''),
              const SizedBox(height: AppSpacing.lg),
              CodeBox(label: 'Escrow key (m/2121\'/1\'/0\')', value: _escrowXpub ?? ''),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        FormCard(
          title: 'Sent to',
          child: CopyRow(label: 'Callback', value: req.callback.toString()),
        ),
        const SizedBox(height: AppSpacing.xl),
        if (_error != null) ...[
          DangerBanner(message: _error!),
          const SizedBox(height: AppSpacing.lg),
        ],
        ProtocolConfirmGate(
          statement: 'I want ${req.site} to watch "${w.name}" and to use its escrow key in my loans.',
          buttonLabel: 'Share with ${req.site}',
          icon: Icons.link,
          busy: _busy,
          onConfirm: _confirmConnect,
        ),
      ],
    );
  }

  Widget _signReview() {
    final req = _request!;
    final w = _wallet!;
    final i = _inspection!;
    final ours = i.ourInputs;
    final s = AppScheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (ours.isEmpty)
          const WarningBanner(
            title: 'Nothing here is for this wallet to sign',
            message: 'None of the inputs names a key of the open wallet. Either '
                'the site sent this request to the wrong wallet, or the wallet '
                'that took part in the loan is a different one. Open that wallet '
                'and try the link again.',
          )
        else
          InfoBanner(
            title: 'Compare both sides before signing',
            message: 'Left is what ${req.site} says this transaction does. Right is '
                'what the wallet reads from the transaction itself. Sign only if '
                'they agree — the site cannot change what the wallet sees.',
          ),
        const SizedBox(height: AppSpacing.lg),
        LayoutBuilder(builder: (context, c) {
          final wide = c.maxWidth >= 760;
          final site = _SiteSummaryPanel(request: req);
          final wallet = _WalletViewPanel(inspection: i, walletName: w.name);
          if (wide) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: site),
                const SizedBox(width: AppSpacing.lg),
                Expanded(child: wallet),
              ],
            );
          }
          return Column(children: [site, const SizedBox(height: AppSpacing.lg), wallet]);
        }),
        const SizedBox(height: AppSpacing.lg),
        SummaryCard(
          title: 'Request',
          rows: [
            (label: 'Site', value: req.site, isMono: false),
            (label: 'Action', value: req.actionLabel, isMono: false),
            if (req.loanRef != null && req.loanRef!.isNotEmpty)
              (label: 'Loan', value: req.loanRef!, isMono: true),
            (label: 'Request id', value: req.id ?? '', isMono: true),
            (label: 'Network', value: protocolNetworkLabel(req.network), isMono: false),
            (label: 'Wallet', value: w.name, isMono: false),
            (label: 'Callback', value: req.callback.toString(), isMono: true),
            (label: 'Expires', value: req.expiresAtTime.toLocal().toString(), isMono: false),
          ],
        ),
        if (req.escrow != null && req.escrow!.address.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.lg),
          FormCard(
            title: 'Escrow contract named by the site',
            subtitle: 'Shown as the site describes it. The wallet\'s view on the '
                'right is what actually gets signed.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CopyRow(label: 'Address', value: req.escrow!.address),
                if (req.escrow!.descriptor.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.md),
                  CodeBox(label: 'Descriptor', value: req.escrow!.descriptor),
                ],
              ],
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.xl),
        if (_error != null) ...[
          DangerBanner(message: _error!),
          const SizedBox(height: AppSpacing.lg),
        ],
        Text(
          'The signature is sent to ${req.site} only. Nothing is broadcast by this wallet, '
          'and the transaction is not kept once this screen closes.',
          style: AppTypography.caption.copyWith(color: s.inkSecondary),
        ),
        const SizedBox(height: AppSpacing.md),
        ProtocolConfirmGate(
          statement: 'I compared the site\'s summary with the wallet\'s reading and they describe the same transaction.',
          buttonLabel: 'Sign and send to ${req.site}',
          busy: _busy,
          enabled: ours.isNotEmpty,
          onConfirm: _confirmSign,
        ),
      ],
    );
  }
}

// ── Pieces ────────────────────────────────────────────────────────────────────

class _LockedCard extends StatelessWidget {
  const _LockedCard({required this.onUnlock});
  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) {
    return FormCard(
      title: 'Wallet storage is locked',
      subtitle: 'Enter your app passphrase to read the request and choose a wallet.',
      child: PrimaryButton(label: 'Unlock', icon: Icons.lock_open_outlined, onPressed: onUnlock),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({
    required this.message,
    this.onRetry,
    this.onOpenSite,
    this.siteName,
  });
  final String message;
  final VoidCallback? onRetry;

  /// Opens the site in the browser. A refused request is often one the site
  /// must hand out again — a token is single use, and the one fetched before
  /// a network switch is spent — so "Try again" alone can only fail twice.
  final VoidCallback? onOpenSite;
  final String? siteName;

  @override
  Widget build(BuildContext context) {
    final phone = AppLayout.isPhone(context);
    final buttons = <Widget>[
      if (onOpenSite != null)
        PrimaryButton(
          label: siteName == null ? 'Open the site' : 'Open $siteName',
          icon: Icons.open_in_new,
          onPressed: onOpenSite,
          isFullWidth: phone,
        ),
      if (onRetry != null)
        SecondaryButton(
          label: 'Try again',
          icon: Icons.refresh,
          onPressed: onRetry,
          isFullWidth: phone,
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DangerBanner(title: 'Request refused', message: message),
        if (buttons.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.lg),
          if (phone)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final b in buttons) ...[
                  b,
                  if (b != buttons.last) const SizedBox(height: AppSpacing.md),
                ],
              ],
            )
          else
            Row(
              children: [
                for (final b in buttons) ...[
                  b,
                  if (b != buttons.last) const SizedBox(width: AppSpacing.md),
                ],
              ],
            ),
        ],
      ],
    );
  }
}

class _WalletChoice extends StatelessWidget {
  const _WalletChoice({
    required this.wallets,
    required this.eligible,
    required this.connect,
    required this.onPick,
    this.preferredWalletId,
  });
  final List<WalletSummary> wallets;
  final bool Function(WalletSummary) eligible;
  final bool connect;
  final void Function(WalletSummary) onPick;

  /// Settings › Templar Protocol's choice, when it can answer this request.
  final String? preferredWalletId;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    // The preferred wallet leads the list; the others keep their order.
    final usable = wallets.where(eligible).toList()
      ..sort((a, b) {
        if (a.id == preferredWalletId) return -1;
        if (b.id == preferredWalletId) return 1;
        return 0;
      });
    final others = wallets.where((w) => !eligible(w)).toList();
    return FormCard(
      title: connect ? 'Which wallet should the site know?' : 'Which wallet signs?',
      subtitle: connect
          ? 'A software wallet with Liquid enabled. Its escrow key is derived from the seed; devices are not supported for loans yet.'
          : 'A Liquid wallet whose key took part in this loan.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (usable.isEmpty)
            const WarningBanner(
              message: 'No wallet qualifies. Create or restore a software wallet with '
                  'Liquid enabled, then open the link again.',
            ),
          for (final w in usable)
            HoverRow(
              onTap: () => onPick(w),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                child: Row(
                  children: [
                    Icon(Icons.account_balance_wallet_outlined, size: 18, color: s.liquid),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(w.name, style: AppTypography.body),
                          Text('${w.displayType} · ${w.networksLabel}'
                              '${w.masterFingerprint != null ? ' · ${w.masterFingerprint}' : ''}',
                              style: AppTypography.caption.copyWith(color: s.inkSecondary)),
                        ],
                      ),
                    ),
                    if (w.id == preferredWalletId) ...[
                      TagChip(label: 'Preferred', color: s.liquid),
                      const SizedBox(width: AppSpacing.sm),
                    ],
                    const Icon(Icons.chevron_right, size: 18),
                  ],
                ),
              ),
            ),
          if (others.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            Text(
              'Not usable here: ${others.map((w) => w.name).join(', ')} '
              '(${connect ? 'no Liquid side, view-only, multisig or device wallets' : 'no Liquid side, view-only or non-Jade device wallets'}).',
              style: AppTypography.caption.copyWith(color: s.inkFaint),
            ),
          ],
        ],
      ),
    );
  }
}

class _SiteSummaryPanel extends StatelessWidget {
  const _SiteSummaryPanel({required this.request});
  final ProtocolRequest request;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final summary = request.summary;
    return RailPanel(
      title: 'What ${request.site} says',
      rail: s.accent,
      child: summary == null || summary.lines.isEmpty
          ? Text('The site sent no summary.',
              style: AppTypography.caption.copyWith(color: s.inkSecondary))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (summary.role.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: TagChip(label: 'Your role: ${summary.role}', color: s.accent),
                  ),
                for (final line in summary.lines)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: KvRow(label: line.label, value: line.amount, labelWidth: 140),
                  ),
              ],
            ),
    );
  }
}

class _WalletViewPanel extends StatelessWidget {
  const _WalletViewPanel({required this.inspection, required this.walletName});
  final PsetInspection inspection;
  final String walletName;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    final i = inspection;
    return RailPanel(
      title: 'What "$walletName" reads',
      rail: s.liquid,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Inputs (${i.inputs.length})', style: AppTypography.sectionTitle),
          const SizedBox(height: AppSpacing.sm),
          for (final inp in i.inputs)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: DataWell(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        TagChip(
                          label: inp.isOurs
                              ? (inp.isScriptHash ? 'escrow · your key' : 'your coin')
                              : (inp.isScriptHash ? 'contract · not yours' : 'not yours'),
                          color: inp.isOurs ? s.liquid : s.inkFaint,
                        ),
                        const Spacer(),
                        Text(
                          inp.displayAmount ??
                              (inp.ticker != null ? 'blinded (${inp.ticker})' : 'blinded'),
                          style: AppTypography.numericSmall.copyWith(
                            fontWeight: FontWeight.w700,
                            color: s.ink,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    KvRow(label: 'Outpoint', value: inp.outpoint),
                    if (inp.keyFingerprints.isNotEmpty)
                      KvRow(label: 'Keys', value: inp.keyFingerprints.join(', ')),
                    if (inp.signedBy.isNotEmpty)
                      KvRow(label: 'Signed by', value: inp.signedBy.join(', ')),
                  ],
                ),
              ),
            ),
          const SizedBox(height: AppSpacing.md),
          Text('Outputs (${i.outputs.length})', style: AppTypography.sectionTitle),
          const SizedBox(height: AppSpacing.sm),
          for (final out in i.outputs)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: DataWell(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        TagChip(
                          label: out.kindLabel,
                          color: out.isOwn
                              ? s.liquid
                              : out.isEscrow
                                  ? s.accent
                                  : out.isFee
                                      ? s.inkFaint
                                      : AppColors.warning,
                        ),
                        const Spacer(),
                        Text(
                          out.displayAmount ??
                              (out.ticker != null ? 'blinded (${out.ticker})' : 'blinded'),
                          style: AppTypography.numericSmall.copyWith(
                            fontWeight: FontWeight.w700,
                            color: s.ink,
                          ),
                        ),
                      ],
                    ),
                    if (out.address != null) ...[
                      const SizedBox(height: AppSpacing.xs),
                      KvRow(label: 'Address', value: out.address!),
                    ],
                  ],
                ),
              ),
            ),
          const SizedBox(height: AppSpacing.md),
          KvRow(label: 'Fee', value: i.feeDisplay),
          KvRow(label: 'Network', value: protocolNetworkLabel(i.network)),
          KvRow(
            label: 'Signatures',
            value: '${i.sigsHave} of ${i.sigsNeeded} on the least-signed input',
          ),
        ],
      ),
    );
  }
}

class _DoneCard extends StatelessWidget {
  const _DoneCard({
    required this.site,
    required this.connect,
    required this.next,
    required this.onOpen,
    required this.onClose,
  });
  final String site;
  final bool connect;
  final String? next;
  final VoidCallback onOpen;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final s = AppScheme.of(context);
    return FormCard(
      title: connect ? 'Wallet connected' : 'Signature sent',
      subtitle: connect
          ? '$site now watches this wallet and holds its escrow key. Every signing step for your loans will open here.'
          : '$site received the signature. It broadcasts once every party has signed; check the loan page for the transaction id.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.check_circle_outline, color: AppColors.success, size: 22),
              const SizedBox(width: AppSpacing.sm),
              Text('Done', style: AppTypography.sectionTitle.copyWith(color: s.ink)),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              if (next != null) ...[
                PrimaryButton(label: 'Open in browser', icon: Icons.open_in_new, onPressed: onOpen),
                const SizedBox(width: AppSpacing.md),
              ],
              SecondaryButton(label: 'Back to wallet', onPressed: onClose),
            ],
          ),
        ],
      ),
    );
  }
}
