import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:web3dart/web3dart.dart';

import '../l10n/translation.dart';
import '../models/token.dart';
import '../repository/contact_repository.dart';
import '../services/api_service.dart';
import '../services/key_service.dart';
import '../services/notification_service.dart';
import '../services/storage_service.dart';
import '../update_service.dart';
import 'contacts_screen.dart';
import 'dialogs/pin_dialog.dart';
import 'dialogs/scanner_dialog.dart';
import 'dialogs/settings_dialog.dart';
import 'dialogs/transfer_dialog.dart';
import 'history_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({
    super.key,
    required this.language,
    required this.onLanguageChanged,
  });

  final AppLanguage language;
  final Future<void> Function(AppLanguage language) onLanguageChanged;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  static final Uri _casinoUri = Uri.parse('https://zixi-casino.vercel.app/');

  final ApiService _api = ApiService();
  final KeyService _keyService = KeyService();
  final ContactRepository _contactRepository = ContactRepository();
  final GithubUpdateService _updateService = GithubUpdateService();

  StreamSubscription<Uri>? _deepLinkSubscription;
  StreamSubscription<String>? _deepLinkStringSubscription;
  Timer? _balanceTimer;
  Timer? _pinTimeoutTimer;
  String? _lastHandledDeepLink;
  DateTime? _lastHandledDeepLinkAt;

  String _walletAddress = '';
  late AppToken _selectedToken = AppToken.supported.first;
  Map<String, String> _balances = {
    for (final token in AppToken.supported) token.id: '0.00',
  };
  Map<String, double> _lastKnownBalances = {
    for (final token in AppToken.supported) token.id: 0.0,
  };
  bool _isLoading = false;
  bool _isSyncingBalance = false;
  DateTime? _lastBalanceSyncAt;
  static const Duration _balanceCacheTtl = Duration(seconds: 60);
  String _activeSessionId = '';
  bool _autoUpdateCheckEnabled = true;

  String? _pendingAuthSessionId;
  BetRequest? _pendingBet;
  bool _isPromptOpen = false;
  bool _hasEverAuthorized = false;
  int _deepLinkFailureCount = 0;
  DateTime? _deepLinkCooldownUntil;

  bool get _scannerSupported {
    if (kIsWeb) return true;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return true;
      default:
        return false;
    }
  }

  String get _selectedBalance => _balances[_selectedToken.id] ?? '0.00';

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _deepLinkSubscription?.cancel();
    _deepLinkStringSubscription?.cancel();
    _balanceTimer?.cancel();
    _pinTimeoutTimer?.cancel();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await NotificationService.instance.requestPermissions();

    await _ensureKeys();
    final address = await _keyService.getWalletAddress();
    final lastBalances = await AppStorage.getLastKnownBalances();
    final activeSessionId = await AppStorage.getActiveSessionId();
    final autoUpdateCheckEnabled = await AppStorage.getAutoUpdateCheckEnabled();

    if (!mounted) return;
    setState(() {
      _walletAddress = address;
      _lastKnownBalances = {
        for (final token in AppToken.supported) token.id: lastBalances[token.id] ?? 0.0,
      };
      _activeSessionId = activeSessionId;
      _hasEverAuthorized = activeSessionId.isNotEmpty;
      _autoUpdateCheckEnabled = autoUpdateCheckEnabled;
    });

    await _syncBalances(notifyIfIncreased: false);

    _balanceTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      _syncBalances();
    });

    await _setupDeepLinks();
    _scheduleUpdateCheck();
  }

  Future<void> _ensureKeys() async {
    try {
      await _keyService.ensureKeyPair();
    } on PinRequiredException {
      if (!mounted) return;
      final pin = await showPinSetupDialog(context);
      if (pin == null || !mounted) {
        throw Exception('PIN setup cancelled');
      }
      await _keyService.ensureKeyPair(pin: pin);
      _startPinTimeout();
    }
  }

  void _startPinTimeout() {
    _pinTimeoutTimer?.cancel();
    _pinTimeoutTimer = Timer(const Duration(minutes: 5), () {
      _keyService.lock();
    });
  }

  Future<TResult> _withPinUnlock<TResult>(Future<TResult> Function() task) async {
    try {
      return await task();
    } on PinRequiredException {
      if (!mounted) rethrow;
      final pin = await showPinUnlockDialog(context);
      if (pin == null || !mounted) throw Exception('PIN unlock cancelled');
      await _keyService.unlockWithPin(pin);
      _startPinTimeout();
      return await task();
    }
  }

  void _scheduleUpdateCheck() {
    if (!_autoUpdateCheckEnabled) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        _updateService.checkForUpdates(
          context,
          title: T.of(context, 'update_available'),
          descriptionTemplate: T.of(context, 'update_desc'),
          laterLabel: T.of(context, 'update_later'),
          nowLabel: T.of(context, 'update_now'),
          openFailedMessage: T.of(context, 'update_open_failed'),
        ),
      );
    });
  }

  Future<void> _setupDeepLinks() async {
    try {
      final links = AppLinks();
      final initial = await _resolveInitialDeepLink(links);
      await _handleIncomingDeepLink(initial);

      _deepLinkSubscription = links.uriLinkStream.listen(
        (uri) => _handleIncomingDeepLink(uri.toString()),
        onError: (Object error) {
          debugPrint('Deep link uri stream failed: $error');
        },
      );

      _deepLinkStringSubscription = links.stringLinkStream.listen(
        (raw) => _handleIncomingDeepLink(raw),
        onError: (Object error) {
          debugPrint('Deep link string stream failed: $error');
        },
      );
    } catch (e) {
      debugPrint('Deep link init failed: $e');
    }
  }

  Future<String?> _resolveInitialDeepLink(AppLinks links) async {
    final dynamic any = links;
    try {
      final dynamic value = await any.getInitialLinkString();
      final link = value?.toString().trim() ?? '';
      if (link.isNotEmpty && link != 'null') return link;
    } catch (e) {
      debugPrint('Deep link getInitialLinkString unavailable: $e');
    }

    try {
      final dynamic value = await any.getInitialLink();
      final link = value?.toString().trim() ?? '';
      if (link.isNotEmpty && link != 'null') return link;
    } catch (e) {
      debugPrint('Deep link getInitialLink unavailable: $e');
    }

    try {
      final dynamic value = await any.getLatestLinkString();
      final link = value?.toString().trim() ?? '';
      if (link.isNotEmpty && link != 'null') return link;
    } catch (e) {
      debugPrint('Deep link getLatestLinkString unavailable: $e');
    }

    try {
      final dynamic value = await any.getLatestLink();
      final link = value?.toString().trim() ?? '';
      if (link.isNotEmpty && link != 'null') return link;
    } catch (e) {
      debugPrint('Deep link getLatestLink unavailable: $e');
    }

    return null;
  }

  Future<void> _handleIncomingDeepLink(String? raw) async {
    final data = raw?.trim() ?? '';
    if (data.isEmpty || data == 'null') return;

    final now = DateTime.now();

    // Rate limit: max 5 attempts per 30 seconds
    if (_deepLinkCooldownUntil != null && now.isBefore(_deepLinkCooldownUntil!)) {
      debugPrint('Deep link ignored: rate limited');
      return;
    }

    // Dedup same link within 5 seconds
    final isDuplicate = _lastHandledDeepLink == data &&
        _lastHandledDeepLinkAt != null &&
        now.difference(_lastHandledDeepLinkAt!) < const Duration(seconds: 5);
    if (isDuplicate) return;

    _lastHandledDeepLink = data;
    _lastHandledDeepLinkAt = now;

    // Parse and validate before accepting
    final sessionId = _extractSessionId(data);
    if (sessionId != null) {
      _deepLinkFailureCount = 0;
      await _handlePayload(data);
      return;
    }

    // Not a recognized deep link format
    _deepLinkFailureCount++;
    if (_deepLinkFailureCount >= 5) {
      _deepLinkCooldownUntil = now.add(const Duration(seconds: 30));
      _deepLinkFailureCount = 0;
      debugPrint('Deep link rate limit triggered');
    }
  }

  Future<void> _runWithLoading(Future<void> Function() task) async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
    });
    try {
      await task();
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _syncBalances({bool notifyIfIncreased = true, bool forceRefresh = false}) async {
    if (_walletAddress.isEmpty || _isSyncingBalance) return;

    if (!forceRefresh && _lastBalanceSyncAt != null &&
        DateTime.now().difference(_lastBalanceSyncAt!) < _balanceCacheTtl) {
      return;
    }

    _isSyncingBalance = true;

    try {
      final sessionId = await _ensureActiveSessionIdInternal(forceRefresh: false);
      final summary = await _api.getWalletSummary(sessionId: sessionId);
      final nextBalances = <String, String>{};
      final nextKnownBalances = <String, double>{};

      for (final token in AppToken.supported) {
        final previousBalance = _lastKnownBalances[token.id] ?? 0.0;
        final nextBalance = _api.balanceFromWalletSummary(summary, token.id);
        final next = double.tryParse(nextBalance) ?? 0.0;
        final shouldNotify = notifyIfIncreased && next > previousBalance;

        nextBalances[token.id] = nextBalance;
        nextKnownBalances[token.id] = next;
        await AppStorage.setLastKnownBalance(token.id, nextBalance);

        if (shouldNotify) {
          try {
            await NotificationService.instance.showBalanceNotification(
              amount: next - previousBalance,
              total: next,
            );
          } catch (e) {
            debugPrint('Balance notification failed: $e');
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _balances = {
          ..._balances,
          ...nextBalances,
        };
        _lastKnownBalances = {
          ..._lastKnownBalances,
          ...nextKnownBalances,
        };
      });
      _lastBalanceSyncAt = DateTime.now();
    } catch (e) {
      if (e is SessionRequiredException) {
        debugPrint('Balance sync skipped: no authorized session');
      } else {
        debugPrint('Balance sync failed: $e');
      }
    } finally {
      _isSyncingBalance = false;
    }
  }

  Future<void> _requestAirdrop() async {
    if (_walletAddress.isEmpty) return;
    await _runWithLoading(() async {
      try {
        await _withRetriedSession((sessionId) {
          return _api.requestAirdrop(
            sessionId: sessionId,
            address: _walletAddress,
            tokenAddress: AppToken.supported.first.address,
            token: AppToken.supported.first.id,
          );
        });
        if (!mounted) return;
        _showSnack(T.of(context, 'airdrop_request_sent'));
        await Future<void>.delayed(const Duration(seconds: 2));
        await _syncBalances(forceRefresh: true);
      } catch (e) {
        if (!mounted) return;
        _showSnack(T.of(context, 'failure_message', [e.toString()]));
      }
    });
  }

  Future<void> _openConvertFlow() async {
    if (_walletAddress.isEmpty) return;
    final controller = TextEditingController();
    final zxcAmount = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(T.of(context, 'convert')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(T.of(context, 'convert_desc', [_selectedBalance])),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: T.of(context, 'amount'),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(T.of(context, 'cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: Text(T.of(context, 'convert_confirm')),
          ),
        ],
      ),
    );
    if (!mounted || zxcAmount == null || zxcAmount.isEmpty) return;

    await _runWithLoading(() async {
      try {
        final signature = await _withPinUnlock(
          () => _keyService.signData('convert:$zxcAmount:zhixi'),
        );
        final pubKey = await _withPinUnlock(
          () => _keyService.getPublicKeySpkiBase64(),
        );
        await _withRetriedSession((sessionId) {
          return _api.convert(
            sessionId: sessionId,
            address: _walletAddress,
            zxcAmount: zxcAmount,
            signature: signature,
            publicKey: pubKey,
          );
        });
        if (!mounted) return;
        _showSnack(T.of(context, 'convert_success'));
        await Future<void>.delayed(const Duration(seconds: 2));
        await _syncBalances(forceRefresh: true);
      } catch (e) {
        if (!mounted) return;
        _showSnack(T.of(context, 'failure_message', [e.toString()]));
      }
    });
  }

  Future<void> _openHistory() async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => HistoryScreen(
          api: _api,
          keyService: _keyService,
          symbol: _selectedToken.displayName(context),
          token: _selectedToken.id,
        ),
      ),
    );
  }

  Future<void> _openContacts() async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ContactsScreen(
          selectionMode: false,
          repository: _contactRepository,
        ),
      ),
    );
  }

  Future<void> _openCasino() async {
    try {
      final launched = await launchUrl(_casinoUri);
      if (launched) return;
      throw Exception('Unable to open casino');
    } catch (e) {
      if (!mounted) return;
      _showSnack(T.of(context, 'failure_message', [e.toString()]));
    }
  }

  Future<String?> _pickAddressFromContacts() async {
    if (!mounted) return null;
    return Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => ContactsScreen(
          selectionMode: true,
          repository: _contactRepository,
        ),
      ),
    );
  }

  Future<void> _openTransferFlow({
    required bool isMigration,
    String initialAddress = '',
  }) async {
    String destinationAddress = initialAddress.trim();

    while (destinationAddress.isEmpty) {
      final input = await showAddressInputDialog(context, isMigration: isMigration);
      if (!mounted || input == null) return;

      switch (input.action) {
        case AddressInputAction.confirm:
          destinationAddress = input.value.trim();
          break;
        case AddressInputAction.scan:
          final raw = await showDialog<String>(
            context: context,
            barrierDismissible: false,
            builder: (_) => ScannerDialog(
              scannerSupported: _scannerSupported,
            ),
          );
          if (!mounted || raw == null || raw.trim().isEmpty) return;
          final scannedAddress = _extractAddress(raw);
          if (scannedAddress != null) {
            destinationAddress = scannedAddress;
          } else {
            await _handlePayload(raw);
            return;
          }
          break;
        case AddressInputAction.contacts:
          final selected = await _pickAddressFromContacts();
          if (selected == null || selected.trim().isEmpty) return;
          destinationAddress = selected.trim();
          break;
      }
    }

    final amount = await showTransferDialog(
      context,
      toAddress: destinationAddress,
      isMigration: isMigration,
      presetAmount: isMigration ? _selectedBalance : '10',
      tokenDisplayName: _selectedToken.displayName(context),
    );

    if (!mounted || amount == null || amount.trim().isEmpty) return;

    await _runWithLoading(() async {
      try {
        // 簽章訊息交給 _api.transferMessage 組（單一來源，見 api_service.dart）。
        // 這裡**不要**自己拼字串 —— 之前就是這裡拼錯才導致簽章對不上。
        var normalizedAmount = amount.trim();
        if (normalizedAmount.endsWith('.0')) {
          normalizedAmount = normalizedAmount.substring(0, normalizedAmount.length - 2);
        }

        final publicKey = await _keyService.getPublicKeySpkiBase64();

        // ★ 2026-10-15：簽章訊息加入一次性 nonce（server 防重放）
        //
        // ★ 為什麼簽章放在回呼「內」
        //   nonce 綁在 session 上。若在回呼外簽，session 過期而
        //   _withRetriedSession 換新 session 重試時，那個簽章對的是
        //   舊 session 的 nonce → server 判 NONCE_REPLAY，整筆失敗。
        //   放在回呼內 = 每次嘗試都用「當下這個 session」的 nonce。
        await _withRetriedSession((sessionId) async {
          final nonce = await _api.nonceFor(sessionId) ?? '';
          final signature = await _keyService.signData(
            _api.transferMessage(
              nonce: nonce,
              to: destinationAddress,
              amount: normalizedAmount,
              tokenId: _selectedToken.id,
            ),
          );
          return _api.transfer(
            sessionId: sessionId,
            from: _walletAddress,
            to: destinationAddress.trim().toLowerCase(),
            amount: normalizedAmount,
            signature: signature,
            publicKey: publicKey,
            tokenAddress: _selectedToken.address,
            token: _selectedToken.id,
            nonce: nonce,
          );
        });

        if (!mounted) return;
        _showSnack(T.of(context, 'transfer_success'));
        await Future<void>.delayed(const Duration(seconds: 2));
        await _syncBalances(forceRefresh: true);
      } catch (e) {
        if (!mounted) return;
        _showSnack(T.of(context, 'failure_message', [e.toString()]));
      }
    });
  }

  Future<void> _openGeneralScanner() async {
    final raw = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ScannerDialog(
        scannerSupported: _scannerSupported,
      ),
    );
    if (!mounted || raw == null || raw.trim().isEmpty) return;
    await _handlePayload(raw);
  }

  Future<void> _showReceiveDialog() async {
    if (_walletAddress.isEmpty) return;
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(T.of(context, 'receive_address')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QrImageView(
              data: _walletAddress,
              version: QrVersions.auto,
              size: 220,
            ),
            const SizedBox(height: 12),
            SelectableText(
              _walletAddress,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(T.of(context, 'close')),
          ),
        ],
      ),
    );
  }

  Future<void> _openSettingsDialog() async {
    await showSettingsDialog(
      context,
      initialAutoUpdateEnabled: _autoUpdateCheckEnabled,
      currentLanguage: widget.language,
      onLanguageChanged: widget.onLanguageChanged,
      onAutoUpdateChanged: (enabled) {
        if (!mounted) return;
        setState(() {
          _autoUpdateCheckEnabled = enabled;
        });
      },
    );
  }

  Future<void> _handlePayload(String? raw) async {
    debugPrint('[handlePayload] raw=$raw');
    if (raw == null || raw.trim().isEmpty) return;

    final data = raw.trim();
    final sessionId = _extractSessionId(data);
    if (sessionId != null) {
      _queueAuthPrompt(sessionId);
      return;
    }

    final bet = _extractBetRequest(data);
    if (bet != null) {
      _queueBetPrompt(bet);
      return;
    }

    final address = _extractAddress(data);
    if (address != null) {
      await _openTransferFlow(isMigration: false, initialAddress: address);
      return;
    }

    if (!mounted) return;
    _showSnack(T.of(context, 'manual_code_error'));
  }

  String? _extractSessionId(String raw) {
    final value = raw.trim();

    final direct = _validateSessionCandidate(value);
    if (direct != null) return direct;

    const prefix1 = 'dlinker:login:';
    if (value.toLowerCase().startsWith(prefix1)) {
      final session = value.substring(prefix1.length).trim();
      return _validateSessionCandidate(session);
    }

    const prefix2 = 'dlinker://login/';
    if (value.toLowerCase().startsWith(prefix2)) {
      final session = value.substring(prefix2.length).trim();
      return _validateSessionCandidate(session);
    }

    final parsed = Uri.tryParse(value);
    if (parsed != null) {
      final querySession = _validateSessionCandidate(parsed.queryParameters['sessionId']);
      if (querySession != null) return querySession;

      if (parsed.pathSegments.length >= 2) {
        final marker = parsed.pathSegments[parsed.pathSegments.length - 2].toLowerCase();
        if (marker == 'login') {
          final segment = _validateSessionCandidate(parsed.pathSegments.last);
          if (segment != null) return segment;
        }
      }
    }

    return null;
  }

  String? _validateSessionCandidate(String? raw) {
    if (raw == null) return null;
    final value = raw.trim();
    if (value.isEmpty) return null;
    return ApiService.isValidSessionId(value) ? value : null;
  }

  BetRequest? _extractBetRequest(String raw) {
    final data = raw.trim();
    if (!data.toLowerCase().startsWith('dlinker:coinflip:')) return null;

    final parts = data.split(':');
    if (parts.length < 5) return null;

    return BetRequest(gameId: parts[2], side: parts[3], amount: parts[4]);
  }

  String? _extractAddress(String raw) {
    final direct = RegExp(r'0x[a-fA-F0-9]{40}').firstMatch(raw);
    if (direct != null) {
      final address = direct.group(0)!;
      return EthereumAddress.fromHex(address).hexEip55;
    }

    if (raw.length >= 42) {
      final tail = raw.substring(raw.length - 42);
      if (RegExp(r'0x[a-fA-F0-9]{40}').hasMatch(tail)) {
        return EthereumAddress.fromHex(tail).hexEip55;
      }
    }

    return null;
  }

  void _queueAuthPrompt(String sessionId) {
    _pendingAuthSessionId = sessionId;
    _drainPromptQueue();
  }

  void _queueBetPrompt(BetRequest request) {
    _pendingBet = request;
    _drainPromptQueue();
  }

  void _drainPromptQueue() {
    if (!mounted || _isPromptOpen) return;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || _isPromptOpen) return;

      if (_pendingAuthSessionId != null) {
        final sid = _pendingAuthSessionId!;
        _pendingAuthSessionId = null;
        _isPromptOpen = true;
        await _showAuthDialog(sid);
        _isPromptOpen = false;
        _drainPromptQueue();
        return;
      }

      if (_pendingBet != null) {
        final bet = _pendingBet!;
        _pendingBet = null;
        _isPromptOpen = true;
        await _showBetDialog(bet);
        _isPromptOpen = false;
        _drainPromptQueue();
      }
    });
  }

  Future<void> _showAuthDialog(String sessionId) async {
    if (!mounted) return;
    final approved = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: Row(
              children: [
                const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 24),
                const SizedBox(width: 8),
                Expanded(child: Text(T.of(context, 'auth_confirm_title'))),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(T.of(context, 'auth_confirm_desc', [sessionId, _walletAddress])),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline, size: 16, color: Colors.orange),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          T.of(context, 'auth_external_warning'),
                          style: const TextStyle(fontSize: 12, color: Colors.orange),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(T.of(context, 'cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(T.of(context, 'auth_confirm_button')),
              ),
            ],
          ),
        ) ??
        false;

    if (!approved || !mounted) return;

    await _runWithLoading(() async {
      try {
        final pubKey = await _withPinUnlock(() => _keyService.getPublicKeySpkiBase64());
        // 簽名必須和 publicKey 走同一個 PIN 解鎖時機，
        // 否則會出現「已解鎖但簽章那一步又被擋一次」的二次提示。
        await _api.sendAuth(
          sessionId: sessionId,
          address: _walletAddress,
          publicKey: pubKey,
          sign: (m) => _withPinUnlock(() => _keyService.signData(m)),
        );
        _activeSessionId = sessionId;
        _hasEverAuthorized = true;
        await AppStorage.setActiveSessionId(sessionId);
        if (!mounted) return;
        _showSnack(T.of(context, 'auth_success_return'));
      } catch (e) {
        if (!mounted) return;
        _showSnack(T.of(context, 'failure_message', [e.toString()]));
      }
    });
  }

  Future<void> _showBetDialog(BetRequest bet) async {
    if (!mounted) return;
    final approved = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: Text(T.of(context, 'bet_confirm_title')),
            content: Text(
              T.of(context, 'bet_confirm_desc', [
                'Coin Flip',
                bet.side,
                bet.amount,
                _selectedToken.displayName(context),
              ]),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(T.of(context, 'cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(T.of(context, 'bet_confirm_button')),
              ),
            ],
          ),
        ) ??
        false;

    if (!approved || !mounted) return;

    await _runWithLoading(() async {
      try {
        final pubKey = await _withPinUnlock(() => _keyService.getPublicKeySpkiBase64());
        // ★ 2026-10-15：簽章加入一次性 nonce，並移入回呼內（理由同 transfer）
        await _withRetriedSession((sessionId) async {
          final nonce = await _api.nonceFor(sessionId) ?? '';
          final signature = await _withPinUnlock(
            () => _keyService.signData(
              _api.coinFlipMessage(
                nonce: nonce,
                selection: bet.side,
                amount: bet.amount,
                tokenId: _selectedToken.id,
              ),
            ),
          );
          return _api.sendCoinFlip(
            gameId: bet.gameId,
            address: _walletAddress,
            sessionId: sessionId,
            side: bet.side,
            amount: bet.amount,
            signature: signature,
            publicKey: pubKey,
            nonce: nonce,
            // ★ 必須和簽章訊息同一個 token（原本這裡沒傳，預設 'zhixi'，
            //   而簽章用 _selectedToken.id → 選 YJC 下注時對不上 → 401）
            token: _selectedToken.id,
          );
        });
        if (!mounted) return;
        _showSnack(T.of(context, 'bet_success'));
        await Future<void>.delayed(const Duration(seconds: 2));
        await _syncBalances();
      } catch (e) {
        if (!mounted) return;
        _showSnack(T.of(context, 'failure_message', [e.toString()]));
      }
    });
  }

  Future<TResult> _withRetriedSession<TResult>(
    Future<TResult> Function(String sessionId) action,
  ) async {
    var sessionId = await _ensureActiveSessionIdInternal(forceRefresh: false);
    try {
      return await action(sessionId);
    } catch (error) {
      if (!_api.isSessionExpiredError(error)) rethrow;
      sessionId = await _ensureActiveSessionIdInternal(forceRefresh: true);
      return action(sessionId);
    }
  }

  Future<void> _clearActiveSession() async {
    _activeSessionId = '';
    await AppStorage.clearActiveSessionId();
  }

  Future<String> _ensureActiveSessionIdInternal({required bool forceRefresh}) async {
    if (!forceRefresh && _activeSessionId.isEmpty) {
      final persisted = await AppStorage.getActiveSessionId();
      if (persisted.trim().isNotEmpty) {
        _activeSessionId = persisted.trim();
      }
    }

    if (!forceRefresh && _activeSessionId.isNotEmpty) {
      final cached = _activeSessionId.trim();
      if (ApiService.isValidSessionId(cached) && await _api.isSessionAuthorized(cached)) {
        return cached;
      }
      await _clearActiveSession();
    } else if (forceRefresh && _activeSessionId.isNotEmpty) {
      await _clearActiveSession();
    }

    if (_walletAddress.isEmpty) {
      throw Exception('Session required');
    }

    // Only auto-renew if user has explicitly authorized at least once
    if (!_hasEverAuthorized) {
      throw SessionRequiredException();
    }

    final created = await _api.createPendingAuthSession();
    final sessionId = (created['sessionId'] ?? '').toString().trim();
    if (!ApiService.isValidSessionId(sessionId)) {
      throw Exception('Unable to create session');
    }

    final pubKey = await _withPinUnlock(() => _keyService.getPublicKeySpkiBase64());
    await _api.sendAuth(
      sessionId: sessionId,
      address: _walletAddress,
      publicKey: pubKey,
      sign: (m) => _withPinUnlock(() => _keyService.signData(m)),
    );

    _activeSessionId = sessionId;
    await AppStorage.setActiveSessionId(sessionId);
    return sessionId;
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokenSymbol = _selectedToken.displayName(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(T.of(context, 'app_dashboard_title')),
        actions: [
          IconButton(
            onPressed: () {
              _runWithLoading(() async {
                await _syncBalances();
              });
            },
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            onPressed: _openSettingsDialog,
            icon: const Icon(Icons.settings),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_isLoading) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: _walletAddress.isEmpty
                  ? Center(child: Text(T.of(context, 'loading')))
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _AssetCard(
                            balance: _selectedBalance,
                            address: _walletAddress,
                            symbol: tokenSymbol,
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final token in AppToken.supported)
                                ChoiceChip(
                                  label: Text(token.displayName(context)),
                                  selected: token.id == _selectedToken.id,
                                  onSelected: (selected) {
                                    if (!selected) return;
                                    setState(() {
                                      _selectedToken = token;
                                    });
                                  },
                                ),
                            ],
                          ),
                          const SizedBox(height: 24),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              _ActionButton(
                                icon: Icons.account_balance_wallet,
                                label: T.of(context, 'receive'),
                                onTap: _showReceiveDialog,
                              ),
                              _ActionButton(
                                icon: Icons.qr_code_scanner,
                                label: T.of(context, 'wallet_auth'),
                                onTap: _openGeneralScanner,
                              ),
                              _ActionButton(
                                icon: Icons.send,
                                label: T.of(context, 'transfer'),
                                onTap: () => _openTransferFlow(isMigration: false),
                              ),
                              _ActionButton(
                                icon: Icons.swap_horiz,
                                label: T.of(context, 'convert'),
                                onTap: _openConvertFlow,
                              ),
                              _ActionButton(
                                icon: Icons.swap_horiz,
                                label: T.of(context, 'migration'),
                                onTap: () => _openTransferFlow(isMigration: true),
                              ),
                            ],
                          ),
                          const SizedBox(height: 24),
                          if (_selectedToken.id == 'zhixi')
                            FilledButton(
                              onPressed: _isLoading ? null : _requestAirdrop,
                              style: FilledButton.styleFrom(
                                minimumSize: const Size.fromHeight(52),
                              ),
                              child: Text(T.of(context, 'request_test_coins', [tokenSymbol])),
                            ),
                          const SizedBox(height: 20),
                          _NavigationCard(
                            title: T.of(context, 'transaction_history'),
                            icon: Icons.history,
                            onTap: _openHistory,
                          ),
                          const SizedBox(height: 12),
                          _NavigationCard(
                            title: T.of(context, 'casino'),
                            icon: Icons.casino,
                            onTap: _openCasino,
                          ),
                          const SizedBox(height: 12),
                          _NavigationCard(
                            title: T.of(context, 'contacts'),
                            icon: Icons.contact_page,
                            onTap: _openContacts,
                          ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class BetRequest {
  const BetRequest({
    required this.gameId,
    required this.side,
    required this.amount,
  });

  final String gameId;
  final String side;
  final String amount;
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        FilledButton.tonal(
          onPressed: onTap,
          style: FilledButton.styleFrom(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            minimumSize: const Size(64, 56),
            padding: EdgeInsets.zero,
          ),
          child: Icon(icon, size: 24),
        ),
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(fontSize: 11)),
      ],
    );
  }
}

class _AssetCard extends StatelessWidget {
  const _AssetCard({
    required this.balance,
    required this.address,
    required this.symbol,
  });

  final String balance;
  final String address;
  final String symbol;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              T.of(context, 'my_assets'),
              style: TextStyle(
                color: Theme.of(context).colorScheme.onPrimaryContainer.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              T.of(context, 'balance_format', [balance, symbol]),
              style: const TextStyle(fontSize: 30, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 18),
            Text(
              T.of(context, 'device_wallet_address'),
              style: TextStyle(
                color: Theme.of(context).colorScheme.onPrimaryContainer.withValues(alpha: 0.7),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Text(
                    address,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
                IconButton(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: address));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(T.of(context, 'copy_success'))),
                      );
                    }
                  },
                  icon: const Icon(Icons.copy, size: 18),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _NavigationCard extends StatelessWidget {
  const _NavigationCard({
    required this.title,
    required this.icon,
    required this.onTap,
  });

  final String title;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          child: Row(
            children: [
              Icon(icon),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
              const Icon(Icons.arrow_forward_ios, size: 16),
            ],
          ),
        ),
      ),
    );
  }
}

class SessionRequiredException implements Exception {
  final String message;
  SessionRequiredException([this.message = '請掃碼授權以繼續']);

  @override
  String toString() => message;
}
