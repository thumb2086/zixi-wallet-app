import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pointycastle/export.dart' hide Padding, State;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:web3dart/crypto.dart' as web3crypto;
import 'package:web3dart/web3dart.dart';
import 'update_service.dart';

enum AppLanguage { system, zhTw, zhCn, en }

extension AppLanguageTag on AppLanguage {
  String get tag {
    switch (this) {
      case AppLanguage.system:
        return 'system';
      case AppLanguage.zhTw:
        return 'zh-TW';
      case AppLanguage.zhCn:
        return 'zh-CN';
      case AppLanguage.en:
        return 'en';
    }
  }

  static AppLanguage fromTag(String tag) {
    switch (tag) {
      case 'zh-TW':
        return AppLanguage.zhTw;
      case 'zh-CN':
        return AppLanguage.zhCn;
      case 'en':
        return AppLanguage.en;
      default:
        return AppLanguage.system;
    }
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DeviceLinkerApp());
  unawaited(NotificationService.instance.initialize());
}

class DeviceLinkerApp extends StatefulWidget {
  const DeviceLinkerApp({super.key});

  @override
  State<DeviceLinkerApp> createState() => _DeviceLinkerAppState();
}

class _DeviceLinkerAppState extends State<DeviceLinkerApp> {
  AppLanguage _language = AppLanguage.system;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final language = await AppStorage.getLanguage();
    if (!mounted) return;
    setState(() {
      _language = language;
      _ready = true;
    });
  }

  Future<void> _onLanguageChanged(AppLanguage language) async {
    await AppStorage.setLanguage(language);
    if (!mounted) return;
    setState(() {
      _language = language;
    });
  }

  Locale? get _locale {
    switch (_language) {
      case AppLanguage.system:
        return null;
      case AppLanguage.zhTw:
        return const Locale('zh', 'TW');
      case AppLanguage.zhCn:
        return const Locale('zh', 'CN');
      case AppLanguage.en:
        return const Locale('en');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const MaterialApp(
        home: Scaffold(
          body: Center(
            child: CircularProgressIndicator(),
          ),
        ),
      );
    }

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'D-Linker',
      locale: _locale,
      supportedLocales: const [
        Locale('en'),
        Locale('zh', 'TW'),
        Locale('zh', 'CN'),
      ],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: DashboardScreen(
        language: _language,
        onLanguageChanged: _onLanguageChanged,
      ),
    );
  }
}

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

class AppToken {
  const AppToken({
    required this.id,
    required this.address,
    required this.symbol,
    required this.nameEn,
    required this.nameZhTw,
    required this.nameZhCn,
  });

  final String id;
  final String address;
  final String symbol;
  final String nameEn;
  final String nameZhTw;
  final String nameZhCn;

  static const List<AppToken> supported = [
    AppToken(
      id: 'zhixi',
      address: '0xe3d9af5f15857cb01e0614fa281fcc3256f62050',
      symbol: 'ZHIXI',
      nameEn: 'Zhixi Coin',
      nameZhTw: '子熙幣',
      nameZhCn: '子熙币',
    ),
    AppToken(
      id: 'yjc',
      address: '0x82D6aDB17d58820324D86B378775350D03a071AE',
      symbol: 'YJC',
      nameEn: 'YouJian Coin',
      nameZhTw: '佑戩幣',
      nameZhCn: '佑戩币',
    ),
  ];

  String displayName(BuildContext context) {
    final locale = Localizations.localeOf(context);
    if (locale.languageCode == 'zh' && locale.countryCode?.toUpperCase() == 'TW') {
      return nameZhTw;
    }
    if (locale.languageCode == 'zh') {
      return nameZhCn;
    }
    return nameEn;
  }
}

class _DashboardScreenState extends State<DashboardScreen> {
  static final Uri _casinoUri = Uri.parse('https://zixi-casino.vercel.app/');

  final DLinkerApi _api = DLinkerApi();
  final KeyService _keyService = KeyService();
  final ContactRepository _contactRepository = ContactRepository();
  final GithubUpdateService _updateService = GithubUpdateService();

  StreamSubscription<Uri>? _deepLinkSubscription;
  StreamSubscription<String>? _deepLinkStringSubscription;
  Timer? _balanceTimer;
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
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await NotificationService.instance.requestPermissions();

    await _keyService.ensureKeyPair();
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
      _autoUpdateCheckEnabled = autoUpdateCheckEnabled;
    });

    await _syncBalances(notifyIfIncreased: false);

    _balanceTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      _syncBalances();
    });

    await _setupDeepLinks();
    _scheduleUpdateCheck();
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
    // Keep compatibility across app_links versions and desktop/mobile differences.
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
    final isDuplicate = _lastHandledDeepLink == data &&
        _lastHandledDeepLinkAt != null &&
        now.difference(_lastHandledDeepLinkAt!) < const Duration(seconds: 2);
    if (isDuplicate) return;

    _lastHandledDeepLink = data;
    _lastHandledDeepLinkAt = now;
    await _handlePayload(data);
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
      debugPrint('Balance sync failed: $e');
    } finally {
      _isSyncingBalance = false;
    }
  }

  Future<void> _requestAirdrop() async {
    if (_walletAddress.isEmpty) return;
    await _runWithLoading(() async {
      try {
        await _withRetriedSession((sessionId) {
          // Airdrop backend only credits ZHIXI regardless of which token the
          // user has selected. Explicitly pin the token so we never appear to
          // send an airdrop for YJC (which the backend would reject anyway).
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
      final input = await _showAddressInputDialog(isMigration: isMigration);
      if (!mounted || input == null) return;

      switch (input.action) {
        case AddressInputAction.confirm:
          destinationAddress = input.value.trim();
          break;
        case AddressInputAction.scan:
          final raw = await _showScannerDialog();
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

    final amount = await _showTransferDialog(
      toAddress: destinationAddress,
      isMigration: isMigration,
      presetAmount: isMigration ? _selectedBalance : '10',
    );

    if (!mounted || amount == null || amount.trim().isEmpty) return;

    await _runWithLoading(() async {
      try {
        final cleanTo = destinationAddress.trim().toLowerCase().replaceFirst(RegExp(r'^0x'), '');
        var normalizedAmount = amount.trim();
        if (normalizedAmount.endsWith('.0')) {
          normalizedAmount = normalizedAmount.substring(0, normalizedAmount.length - 2);
        }

        final signature = await _keyService.signData('transfer:$cleanTo:$normalizedAmount');
        final publicKey = await _keyService.getPublicKeySpkiBase64();

        await _withRetriedSession((sessionId) {
          return _api.transfer(
            sessionId: sessionId,
            from: _walletAddress,
            to: destinationAddress.trim().toLowerCase(),
            amount: normalizedAmount,
            signature: signature,
            publicKey: publicKey,
            tokenAddress: _selectedToken.address,
            token: _selectedToken.id,
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
    final raw = await _showScannerDialog();
    if (!mounted || raw == null || raw.trim().isEmpty) return;
    await _handlePayload(raw);
  }

  Future<String?> _showScannerDialog() {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ScannerDialog(
        scannerSupported: _scannerSupported,
      ),
    );
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

  Future<AddressInputResult?> _showAddressInputDialog({required bool isMigration}) {
    final controller = TextEditingController();
    return showDialog<AddressInputResult>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(T.of(context, isMigration ? 'migration' : 'manual_address_input')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              decoration: InputDecoration(
                labelText: T.of(context, 'address_placeholder'),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop(
                        const AddressInputResult(action: AddressInputAction.contacts, value: ''),
                      );
                    },
                    icon: const Icon(Icons.contacts),
                    label: Text(T.of(context, 'contacts')),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop(
                        const AddressInputResult(action: AddressInputAction.scan, value: ''),
                      );
                    },
                    icon: const Icon(Icons.qr_code_scanner),
                    label: Text(T.of(context, 'scan')),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(T.of(context, 'cancel')),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop(
                AddressInputResult(action: AddressInputAction.confirm, value: controller.text),
              );
            },
            child: Text(T.of(context, 'confirm')),
          ),
        ],
      ),
    );
  }

  Future<String?> _showTransferDialog({
    required String toAddress,
    required bool isMigration,
    required String presetAmount,
  }) {
    final controller = TextEditingController(text: presetAmount);

    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(
          isMigration
              ? T.of(context, 'migration_title')
              : T.of(context, 'send_symbol', [_selectedToken.displayName(context)]),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(T.of(context, 'to_address', [toAddress]), style: const TextStyle(fontSize: 12)),
            if (isMigration) ...[
              const SizedBox(height: 8),
              Text(T.of(context, 'migration_desc'), style: const TextStyle(fontSize: 12)),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              readOnly: isMigration,
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
            child: Text(T.of(context, isMigration ? 'migration_confirm' : 'confirm_send')),
          ),
        ],
      ),
    );
  }

  Future<void> _openSettingsDialog() async {
    bool autoUpdateEnabled = _autoUpdateCheckEnabled;

    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(T.of(context, 'settings')),
        content: StatefulBuilder(
          builder: (dialogContext, setDialogState) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(T.of(context, 'auto_update_check')),
                value: autoUpdateEnabled,
                onChanged: (enabled) async {
                  setDialogState(() {
                    autoUpdateEnabled = enabled;
                  });
                  await AppStorage.setAutoUpdateCheckEnabled(enabled);
                  if (!mounted) return;
                  setState(() {
                    _autoUpdateCheckEnabled = enabled;
                  });
                },
              ),
              _languageTile(AppLanguage.system, T.of(context, 'lang_auto')),
              _languageTile(AppLanguage.zhTw, T.of(context, 'lang_zh_tw')),
              _languageTile(AppLanguage.zhCn, T.of(context, 'lang_zh_cn')),
              _languageTile(AppLanguage.en, T.of(context, 'lang_en')),
            ],
          ),
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

  Widget _languageTile(AppLanguage language, String label) {
    final isSelected = widget.language == language;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      leading: Icon(
        isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
      ),
      onTap: () async {
        if (isSelected) {
          Navigator.of(context).pop();
          return;
        }
        await widget.onLanguageChanged(language);
        if (mounted) {
          Navigator.of(context).pop();
        }
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
    return DLinkerApi.isValidSessionId(value) ? value : null;
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
            title: Text(T.of(context, 'auth_confirm_title')),
            content: Text(
              T.of(context, 'auth_confirm_desc', [sessionId, _walletAddress]),
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
        final pubKey = await _keyService.getPublicKeySpkiBase64();
        await _api.sendAuth(sessionId: sessionId, address: _walletAddress, publicKey: pubKey);
        _activeSessionId = sessionId;
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
        final signature = await _keyService.signData('coinflip:${bet.side}:${bet.amount}');
        final pubKey = await _keyService.getPublicKeySpkiBase64();
        await _withRetriedSession((sessionId) {
          return _api.sendCoinFlip(
            gameId: bet.gameId,
            address: _walletAddress,
            sessionId: sessionId,
            side: bet.side,
            amount: bet.amount,
            signature: signature,
            publicKey: pubKey,
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
      if (DLinkerApi.isValidSessionId(cached) && await _api.isSessionAuthorized(cached)) {
        return cached;
      }
      await _clearActiveSession();
    } else if (forceRefresh && _activeSessionId.isNotEmpty) {
      await _clearActiveSession();
    }

    if (_walletAddress.isEmpty) {
      throw Exception('Session required');
    }

    final created = await _api.createPendingAuthSession();
    final sessionId = (created['sessionId'] ?? '').toString().trim();
    if (!DLinkerApi.isValidSessionId(sessionId)) {
      throw Exception('Unable to create session');
    }

    final pubKey = await _keyService.getPublicKeySpkiBase64();
    await _api.sendAuth(
      sessionId: sessionId,
      address: _walletAddress,
      publicKey: pubKey,
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
                          AssetCard(
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
                              ActionButton(
                                icon: Icons.account_balance_wallet,
                                label: T.of(context, 'receive'),
                                onTap: _showReceiveDialog,
                              ),
                              ActionButton(
                                icon: Icons.qr_code_scanner,
                                label: T.of(context, 'wallet_auth'),
                                onTap: _openGeneralScanner,
                              ),
                              ActionButton(
                                icon: Icons.send,
                                label: T.of(context, 'transfer'),
                                onTap: () => _openTransferFlow(isMigration: false),
                              ),
                              ActionButton(
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
                          NavigationCard(
                            title: T.of(context, 'transaction_history'),
                            icon: Icons.history,
                            onTap: _openHistory,
                          ),
                          const SizedBox(height: 12),
                          NavigationCard(
                            title: T.of(context, 'casino'),
                            icon: Icons.casino,
                            onTap: _openCasino,
                          ),
                          const SizedBox(height: 12),
                          NavigationCard(
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

class ActionButton extends StatelessWidget {
  const ActionButton({
    super.key,
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

class AssetCard extends StatelessWidget {
  const AssetCard({
    super.key,
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

class NavigationCard extends StatelessWidget {
  const NavigationCard({
    super.key,
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

class ScannerDialog extends StatefulWidget {
  const ScannerDialog({
    super.key,
    required this.scannerSupported,
  });

  final bool scannerSupported;

  @override
  State<ScannerDialog> createState() => _ScannerDialogState();
}

class _ScannerDialogState extends State<ScannerDialog> {
  final MobileScannerController _controller = MobileScannerController();
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _emit(String value) {
    if (_handled || value.trim().isEmpty) return;
    _handled = true;
    Navigator.of(context).pop(value.trim());
  }

  Future<void> _openManualInputDialog() async {
    final controller = TextEditingController();
    final manual = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(T.of(context, 'manual_code_entry')),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            labelText: T.of(context, 'manual_code_hint'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(T.of(context, 'cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: Text(T.of(context, 'confirm')),
          ),
        ],
      ),
    );

    if (!mounted || manual == null || manual.isEmpty) return;
    _emit(manual);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: SizedBox(
        width: 420,
        height: 470,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 6, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      T.of(context, 'scan'),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Expanded(
              child: widget.scannerSupported
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: MobileScanner(
                          controller: _controller,
                          onDetect: (capture) {
                            if (capture.barcodes.isEmpty) return;
                            final raw = capture.barcodes.first.rawValue;
                            if (raw == null) return;
                            _emit(raw);
                          },
                        ),
                      ),
                    )
                  : Center(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(
                          T.of(context, 'camera_permission_required'),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _openManualInputDialog,
                      child: Text(T.of(context, 'manual_code_entry')),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(T.of(context, 'close')),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}


class HistoryScreen extends StatefulWidget {
  const HistoryScreen({
    super.key,
    required this.api,
    required this.keyService,
    required this.symbol,
    required this.token,
  });

  final DLinkerApi api;
  final KeyService keyService;
  final String symbol;
  final String token;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final ScrollController _scrollController = ScrollController();

  String _walletAddress = '';
  List<HistoryItem> _history = const [];
  int _nextPage = 1;
  bool _hasMore = true;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _init();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final address = await widget.keyService.getWalletAddress();
    if (!mounted) return;
    setState(() {
      _walletAddress = address;
      _history = [];
      _nextPage = 1;
      _hasMore = true;
    });
    await _loadNextPage();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final threshold = _scrollController.position.maxScrollExtent - 320;
    if (_scrollController.position.pixels >= threshold) {
      _loadNextPage();
    }
  }

  Future<void> _loadNextPage() async {
    if (_loading || !_hasMore || _walletAddress.isEmpty) return;

    setState(() {
      _loading = true;
    });

    try {
      final response = await widget.api.getHistory(
        walletAddress: _walletAddress,
        page: _nextPage,
        limit: 20,
        token: widget.token,
      );

      if (!mounted) return;
      setState(() {
        _history = [..._history, ...response.history];
        _nextPage = _nextPage + 1;
        _hasMore = response.hasMore;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(T.of(context, 'failure_message', [e.toString()]))),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() {
      _history = [];
      _nextPage = 1;
      _hasMore = true;
    });
    await _loadNextPage();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(T.of(context, 'transaction_history')),
        actions: [
          IconButton(
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _history.isEmpty && !_loading
          ? Center(
              child: Text(
                T.of(context, 'tx_no_history'),
                style: TextStyle(color: Theme.of(context).colorScheme.outline),
              ),
            )
          : ListView.separated(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              itemBuilder: (context, index) {
                if (index >= _history.length) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }

                final item = _history[index];
                final isSend = _isOutgoingHistoryType(item.type);

                return Row(
                  children: [
                    CircleAvatar(
                      backgroundColor: isSend
                          ? Colors.red.withValues(alpha: 0.12)
                          : Colors.green.withValues(alpha: 0.12),
                      child: Icon(
                        isSend ? Icons.north_east : Icons.south_west,
                        color: isSend ? Colors.red : Colors.green,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isSend ? T.of(context, 'tx_send') : T.of(context, 'tx_receive'),
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            item.counterParty,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                          Text(
                            item.date,
                            style: const TextStyle(fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      '${isSend ? '-' : '+'} ${item.amount} ${widget.symbol}',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: isSend ? null : Colors.green,
                      ),
                    ),
                  ],
                );
              },
              separatorBuilder: (_, __) => const Divider(height: 24),
              itemCount: _history.length + (_loading ? 1 : 0),
            ),
    );
  }

  bool _isOutgoingHistoryType(String type) {
    switch (type.toLowerCase()) {
      case 'send':
      case 'transfer_out':
      case 'withdrawal':
      case 'bet':
        return true;
      default:
        return false;
    }
  }
}

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({
    super.key,
    required this.selectionMode,
    required this.repository,
  });

  final bool selectionMode;
  final ContactRepository repository;

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  List<ContactModel> _contacts = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final contacts = await widget.repository.getAll();
    if (!mounted) return;
    setState(() {
      _contacts = contacts;
      _loading = false;
    });
  }

  Future<void> _addContact() async {
    final nameController = TextEditingController();
    final addressController = TextEditingController();

    final save = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: Text(T.of(context, 'add_contact')),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: InputDecoration(labelText: T.of(context, 'contact_name')),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: addressController,
                  decoration: InputDecoration(labelText: T.of(context, 'wallet_address')),
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
                child: Text(T.of(context, 'confirm')),
              ),
            ],
          ),
        ) ??
        false;

    if (!save) return;

    final name = nameController.text.trim();
    final address = addressController.text.trim();
    if (name.isEmpty || address.isEmpty) return;

    await widget.repository.add(name: name, address: address);
    await _load();
  }

  Future<void> _deleteContact(ContactModel contact) async {
    await widget.repository.delete(contact.id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.selectionMode ? T.of(context, 'select_contact') : T.of(context, 'contacts'),
        ),
        actions: [
          IconButton(
            onPressed: _addContact,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _contacts.isEmpty
              ? Center(
                  child: Text(
                    T.of(context, 'no_contacts'),
                    style: TextStyle(color: Theme.of(context).colorScheme.outline),
                  ),
                )
              : ListView.separated(
                  itemCount: _contacts.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final contact = _contacts[index];
                    return ListTile(
                      title: Text(contact.name),
                      subtitle: Text(
                        contact.address,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: widget.selectionMode
                          ? null
                          : IconButton(
                              onPressed: () => _deleteContact(contact),
                              icon: const Icon(Icons.delete, color: Colors.red),
                            ),
                      onTap: () async {
                        if (widget.selectionMode) {
                          Navigator.of(context).pop(contact.address);
                          return;
                        }

                        await Clipboard.setData(ClipboardData(text: contact.address));
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(T.of(context, 'copy_success'))),
                        );
                      },
                    );
                  },
                ),
    );
  }
}

class ContactModel {
  const ContactModel({
    required this.id,
    required this.name,
    required this.address,
  });

  final int id;
  final String name;
  final String address;

  ContactModel copyWith({int? id, String? name, String? address}) {
    return ContactModel(
      id: id ?? this.id,
      name: name ?? this.name,
      address: address ?? this.address,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'address': address,
    };
  }

  factory ContactModel.fromJson(Map<String, dynamic> json) {
    return ContactModel(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: (json['name'] ?? '').toString(),
      address: (json['address'] ?? '').toString(),
    );
  }
}

class ContactRepository {
  static const String _key = 'contacts';

  Future<List<ContactModel>> getAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];

    final decoded = jsonDecode(raw);
    if (decoded is! List) return [];

    final contacts = decoded
        .whereType<Map>()
        .map((e) => ContactModel.fromJson(Map<String, dynamic>.from(e)))
        .toList();

    contacts.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return contacts;
  }

  Future<void> add({required String name, required String address}) async {
    final contacts = await getAll();
    final nextId = contacts.isEmpty
        ? 1
        : contacts.map((e) => e.id).reduce(max) + 1;

    final updated = [
      ...contacts,
      ContactModel(id: nextId, name: name, address: address),
    ];

    await _save(updated);
  }

  Future<void> delete(int id) async {
    final contacts = await getAll();
    final updated = contacts.where((c) => c.id != id).toList();
    await _save(updated);
  }

  Future<void> _save(List<ContactModel> contacts) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(contacts.map((e) => e.toJson()).toList());
    await prefs.setString(_key, encoded);
  }
}

class DLinkerApi {
  static const String _baseUrl = 'https://zixi-casino-api.onrender.com/api/';
  static const int _defaultAuthTtlSeconds = 600;
  static const int _maxPublicKeyLength = 1024;

  static final RegExp _sessionIdPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{7,127}$');
  static final RegExp _addressPattern = RegExp(r'^0x[a-fA-F0-9]{40}$');

  final http.Client _client = http.Client();
  String? _cachedAppVersion;

  static bool isValidSessionId(String value) {
    final clean = value.trim();
    if (clean.isEmpty || clean.length > 128) return false;
    if (_addressPattern.hasMatch(clean)) return false;
    return _sessionIdPattern.hasMatch(clean);
  }

  Future<Map<String, dynamic>> createPendingAuthSession({int ttlSeconds = _defaultAuthTtlSeconds}) async {
    final json = await _post('v1/auth/create-session', {});
    return _unwrapData(json, fallbackError: 'Create session failed');
  }

  Future<Map<String, dynamic>> getAuthStatus({required String sessionId}) {
    return _get('v1/auth/status', queryParameters: {
      'sessionId': _normalizeSessionId(sessionId),
    });
  }

  Future<void> sendAuth({
    required String sessionId,
    required String address,
    required String publicKey,
  }) async {
    debugPrint('[sendAuth] sessionId=$sessionId address=$address');
    final authContext = await _buildAuthContext();
    final json = await _post('user.js', {
      'action': 'authorize',
      'sessionId': _normalizeSessionId(sessionId),
      'address': _normalizeAddress(address),
      'publicKey': _normalizePublicKey(publicKey),
      ...authContext,
    });

    debugPrint('[sendAuth] response=$json');
    if (json['success'] == true) return;
    throw Exception((json['error'] ?? 'Auth failed').toString());
  }

  Future<void> sendCoinFlip({
    required String gameId,
    required String address,
    required String sessionId,
    required String side,
    required String amount,
    required String signature,
    required String publicKey,
  }) async {
    _normalizeAddress(address);
    _normalizePublicKey(publicKey);
    if (signature.trim().isEmpty) {
      throw Exception('Missing signature');
    }
    final normalizedSessionId = _normalizeSessionId(sessionId);
    final normalizedGameId = gameId.trim().toLowerCase();
    final json = await _post('v1/games/$normalizedGameId/play', {
      'sessionId': normalizedSessionId,
      'betAmount': double.parse(amount),
      'selection': side.trim().toLowerCase(),
      'token': 'zhixi',
    });

    _unwrapData(json, fallbackError: 'Bet failed');
  }

  Future<String> requestAirdrop({
    required String sessionId,
    required String address,
    required String tokenAddress,
    String token = 'zhixi',
  }) async {
    _normalizeAddress(address);
    _normalizeAddress(tokenAddress);
    final json = await _post('v1/wallet/airdrop', {
      'sessionId': _normalizeSessionId(sessionId),
    });
    final data = _unwrapData(json, fallbackError: 'Airdrop failed');

    return (data['txHash'] ?? data['reward'] ?? 'Success').toString();
  }

  Future<Map<String, dynamic>> getWalletSummary({
    required String sessionId,
  }) async {
    final json = await _get('v1/wallet/summary', queryParameters: {
      'sessionId': _normalizeSessionId(sessionId),
    });

    return _unwrapData(json, fallbackError: 'Wallet summary failed');
  }

  String balanceFromWalletSummary(Map<String, dynamic> walletSummary, String token) {
    final summaryRaw = walletSummary['summary'];
    final summary = summaryRaw is Map ? Map<String, dynamic>.from(summaryRaw) : walletSummary;
    final balancesRaw = summary['balances'];
    final balances = balancesRaw is Map ? Map<String, dynamic>.from(balancesRaw) : const <String, dynamic>{};
    final symbol = token == 'yjc' ? 'YJC' : 'ZXC';

    return (balances[symbol] ?? balances[symbol.toLowerCase()] ?? '0').toString();
  }

  Future<String> syncBalance(
    String walletAddress, {
    required String tokenAddress,
    String token = 'zhixi',
  }) async {
    _normalizeAddress(walletAddress);
    _normalizeAddress(tokenAddress);
    final sessionId = await AppStorage.getActiveSessionId();
    if (!isValidSessionId(sessionId)) {
      throw Exception('Session required for balance fetch');
    }
    final summary = await getWalletSummary(sessionId: sessionId);
    return balanceFromWalletSummary(summary, token);
  }

  Future<String> transfer({
    required String sessionId,
    required String from,
    required String to,
    required String amount,
    required String signature,
    required String publicKey,
    required String tokenAddress,
    String token = 'zhixi',
  }) async {
    _normalizeAddress(from);
    _normalizePublicKey(publicKey);
    _normalizeAddress(tokenAddress);
    if (signature.trim().isEmpty) {
      throw Exception('Missing signature');
    }
    final json = await _post('v1/wallet/transfer', {
      'sessionId': _normalizeSessionId(sessionId),
      'to': _normalizeAddress(to),
      'amount': amount,
      'token': token,
    });
    final data = _unwrapData(json, fallbackError: 'Transfer failed');

    return (data['txHash'] ?? '').toString();
  }

  Future<HistoryResponse> getHistory({
    required String walletAddress,
    required int page,
    int limit = 20,
    String token = 'zhixi',
  }) async {
    _normalizeAddress(walletAddress);
    final sessionId = await AppStorage.getActiveSessionId();
    if (!isValidSessionId(sessionId)) {
      throw Exception('Session required for history');
    }

    final json = await getWalletSummary(sessionId: sessionId);
    final summaryRaw = json['summary'];
    final summary = summaryRaw is Map ? Map<String, dynamic>.from(summaryRaw) : json;
    final listRaw = summary['recentTransactions'];
    final expectedToken = token == 'yjc' ? 'YJC' : 'ZXC';

    final history = <HistoryItem>[];
    if (listRaw is List) {
      for (final item in listRaw) {
        Map<String, dynamic>? mapped;
        if (item is Map<String, dynamic>) {
          mapped = item;
        } else if (item is Map) {
          mapped = Map<String, dynamic>.from(item);
        }
        if (mapped == null) continue;
        final itemToken = (mapped['token'] ?? expectedToken).toString().toUpperCase();
        if (itemToken == expectedToken) {
          history.add(HistoryItem.fromJson(mapped));
        }
      }
    }

    return HistoryResponse(
      page: page,
      hasMore: false,
      history: page == 1 ? history.take(limit).toList() : const <HistoryItem>[],
    );
  }

  Future<bool> isSessionAuthorized(String sessionId) async {
    try {
      final json = await getAuthStatus(sessionId: sessionId);
      final data = json['data'] is Map ? Map<String, dynamic>.from(json['data']) : json;
      final status = (data['status'] ?? '').toString().toLowerCase();
      return json['success'] == true && status == 'authorized';
    } catch (_) {
      return false;
    }
  }

  bool isSessionExpiredError(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('session expired') ||
        message.contains('missing from address') ||
        message.contains('missing address');
  }


  Future<Map<String, dynamic>> _get(
    String endpoint, {
    Map<String, String>? queryParameters,
  }) async {
    final uri = Uri.parse('$_baseUrl$endpoint');
    final url = queryParameters == null ? uri : uri.replace(queryParameters: queryParameters);

    final response = await _client
        .get(
          url,
          headers: {
            'Accept': 'application/json',
            'User-Agent': 'D-Linker-Flutter-App',
          },
        )
        .timeout(const Duration(seconds: 30));

    return _parseResponse(response);
  }

  Future<Map<String, dynamic>> _post(String endpoint, Map<String, dynamic> body) async {
    final url = Uri.parse('$_baseUrl$endpoint');

    final response = await _client
        .post(
          url,
          headers: {
            'Content-Type': 'application/json; charset=utf-8',
            'User-Agent': 'D-Linker-Flutter-App',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 30));

    return _parseResponse(response);
  }

  Map<String, dynamic> _parseResponse(http.Response response) {
    final data = response.body;

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('HTTP ${response.statusCode}: $data');
    }

    final decoded = jsonDecode(data);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }

    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }

    throw Exception('Invalid JSON response');
  }

  Map<String, dynamic> _unwrapData(
    Map<String, dynamic> json, {
    required String fallbackError,
  }) {
    if (json['success'] == false) {
      final failedData = json['data'];
      if (failedData is Map && failedData['error'] != null) {
        throw Exception(_formatApiError(failedData['error'], fallbackError));
      }
      throw Exception(_formatApiError(json['error'], fallbackError));
    }

    final data = json.containsKey('data') ? json['data'] : json;
    if (data is Map<String, dynamic>) {
      final nestedError = data['error'];
      if (nestedError != null) {
        throw Exception(_formatApiError(nestedError, fallbackError));
      }
      return data;
    }
    if (data is Map) {
      final mapped = Map<String, dynamic>.from(data);
      final nestedError = mapped['error'];
      if (nestedError != null) {
        throw Exception(_formatApiError(nestedError, fallbackError));
      }
      return mapped;
    }

    if (json['error'] != null) {
      throw Exception(_formatApiError(json['error'], fallbackError));
    }

    return {'value': data};
  }

  String _formatApiError(Object? error, String fallback) {
    if (error is Map) {
      final message = error['message'] ?? error['error'] ?? error['code'];
      if (message != null && message.toString().trim().isNotEmpty) {
        return message.toString();
      }
    }
    if (error != null && error.toString().trim().isNotEmpty) {
      return error.toString();
    }
    return fallback;
  }

  Future<Map<String, String>> _buildAuthContext() async {
    final platform = _resolvePlatform();
    final appVersion = await _getAppVersion();
    return {
      'platform': platform,
      'clientType': _resolveClientType(platform),
      'deviceId': await AppStorage.getDeviceId(),
      'appVersion': appVersion,
    };
  }

  Future<String> _getAppVersion() async {
    if (_cachedAppVersion != null && _cachedAppVersion!.isNotEmpty) {
      return _cachedAppVersion!;
    }

    try {
      final info = await PackageInfo.fromPlatform();
      final version = info.version.trim();
      final build = info.buildNumber.trim();
      if (version.isNotEmpty && build.isNotEmpty) {
        _cachedAppVersion = '$version+$build';
      } else if (version.isNotEmpty) {
        _cachedAppVersion = version;
      }
    } catch (_) {
      _cachedAppVersion = null;
    }

    return _cachedAppVersion ?? 'unknown';
  }

  String _resolvePlatform() {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.linux:
        return 'linux';
      case TargetPlatform.fuchsia:
        return 'fuchsia';
    }
  }

  String _resolveClientType(String platform) {
    switch (platform) {
      case 'android':
      case 'ios':
        return 'mobile';
      case 'web':
        return 'web';
      case 'macos':
      case 'windows':
      case 'linux':
        return 'desktop';
      default:
        return 'unknown';
    }
  }

  String _normalizeSessionId(String raw) {
    final sessionId = raw.trim();
    if (!isValidSessionId(sessionId)) {
      throw Exception('Invalid sessionId format');
    }
    return sessionId;
  }

  String _normalizePublicKey(String raw) {
    final value = raw.trim();
    if (value.isEmpty) {
      throw Exception('Missing publicKey');
    }
    if (value.length > _maxPublicKeyLength) {
      throw Exception('publicKey exceeds max length');
    }
    return value;
  }

  String _normalizeAddress(String raw) {
    final value = raw.trim();
    if (value.isEmpty) {
      throw Exception('Missing address');
    }
    try {
      return EthereumAddress.fromHex(value).hexEip55.toLowerCase();
    } catch (_) {
      throw Exception('Invalid address format');
    }
  }
}

class HistoryItem {
  const HistoryItem({
    required this.type,
    required this.amount,
    required this.counterParty,
    required this.timestamp,
    required this.date,
    required this.txHash,
    required this.blockNumber,
  });

  final String type;
  final String amount;
  final String counterParty;
  final int timestamp;
  final String date;
  final String txHash;
  final String blockNumber;

  factory HistoryItem.fromJson(Map<String, dynamic> json) {
    final createdAt = (json['date'] ?? json['createdAt'] ?? '').toString();
    final parsedDate = DateTime.tryParse(createdAt);

    return HistoryItem(
      type: (json['type'] ?? 'unknown').toString(),
      amount: (json['amount'] ?? '0').toString(),
      counterParty: (json['counterParty'] ?? json['counterparty'] ?? '0x...').toString(),
      timestamp: (json['timestamp'] as num?)?.toInt() ?? parsedDate?.millisecondsSinceEpoch ?? 0,
      date: createdAt,
      txHash: (json['txHash'] ?? json['id'] ?? '').toString(),
      blockNumber: (json['blockNumber'] ?? '').toString(),
    );
  }
}

class HistoryResponse {
  const HistoryResponse({
    required this.page,
    required this.hasMore,
    required this.history,
  });

  final int page;
  final bool hasMore;
  final List<HistoryItem> history;
}

class KeyService {
  static const String _privateKeyStorageKey = 'dlinker_private_key_hex_v1';

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  final ECDomainParameters _domain = ECDomainParameters('secp256k1');

  Future<void> ensureKeyPair() async {
    final existing = await _readPrivateKeyHex();
    if (existing != null && existing.isNotEmpty) return;

    final privateScalar = _generatePrivateScalar();
    final privateHex = privateScalar.toRadixString(16).padLeft(64, '0');
    await _writePrivateKeyHex(privateHex);
  }

  Future<String> getWalletAddress() async {
    final privateKey = await _getPrivateScalar();
    final point = (_domain.G * privateKey)!;
    final x = _bigIntTo32Bytes(point.x!.toBigInteger()!);
    final y = _bigIntTo32Bytes(point.y!.toBigInteger()!);

    final noPrefix = Uint8List.fromList([...x, ...y]);
    final hash = web3crypto.keccak256(noPrefix);
    final addressBytes = Uint8List.fromList(hash.sublist(hash.length - 20));
    final raw = web3crypto.bytesToHex(addressBytes, include0x: true);

    return EthereumAddress.fromHex(raw).hexEip55;
  }

  Future<String> getPublicKeySpkiBase64() async {
    final privateKey = await _getPrivateScalar();
    final point = (_domain.G * privateKey)!;

    final x = _bigIntTo32Bytes(point.x!.toBigInteger()!);
    final y = _bigIntTo32Bytes(point.y!.toBigInteger()!);
    final uncompressed = Uint8List.fromList([0x04, ...x, ...y]);

    final header = Uint8List.fromList([
      0x30,
      0x56,
      0x30,
      0x10,
      0x06,
      0x07,
      0x2A,
      0x86,
      0x48,
      0xCE,
      0x3D,
      0x02,
      0x01,
      0x06,
      0x05,
      0x2B,
      0x81,
      0x04,
      0x00,
      0x0A,
      0x03,
      0x42,
      0x00,
    ]);

    final spki = Uint8List.fromList([...header, ...uncompressed]);
    return base64Encode(spki);
  }

  Future<String> signData(String data) async {
    final privateScalar = await _getPrivateScalar();
    final privateKey = ECPrivateKey(privateScalar, _domain);

    final digest = SHA256Digest().process(Uint8List.fromList(utf8.encode(data)));

    final signer = ECDSASigner(null, HMac(SHA256Digest(), 64));
    signer.init(true, PrivateKeyParameter<ECPrivateKey>(privateKey));

    final signature = signer.generateSignature(digest) as ECSignature;

    var s = signature.s;
    final halfN = _domain.n >> 1;
    if (s > halfN) {
      s = _domain.n - s;
    }

    final der = _encodeDerSequence([
      _encodeDerInteger(signature.r),
      _encodeDerInteger(s),
    ]);

    return base64Encode(der);
  }

  Future<BigInt> _getPrivateScalar() async {
    await ensureKeyPair();
    final hex = await _readPrivateKeyHex();
    if (hex == null || hex.isEmpty) {
      throw Exception('Missing private key');
    }
    return BigInt.parse(hex, radix: 16);
  }

  BigInt _generatePrivateScalar() {
    final random = Random.secure();

    while (true) {
      final bytes = Uint8List(32);
      for (var i = 0; i < bytes.length; i++) {
        bytes[i] = random.nextInt(256);
      }
      final value = _bytesToBigInt(bytes);
      if (value > BigInt.zero && value < _domain.n) {
        return value;
      }
    }
  }

  Future<String?> _readPrivateKeyHex() async {
    try {
      return await _secureStorage.read(key: _privateKeyStorageKey);
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_privateKeyStorageKey);
    }
  }

  Future<void> _writePrivateKeyHex(String value) async {
    try {
      await _secureStorage.write(key: _privateKeyStorageKey, value: value);
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_privateKeyStorageKey, value);
    }
  }

  Uint8List _bigIntTo32Bytes(BigInt value) {
    final bytes = _bigIntToBytes(value);
    if (bytes.length == 32) return bytes;
    if (bytes.length > 32) {
      return Uint8List.fromList(bytes.sublist(bytes.length - 32));
    }
    return Uint8List.fromList(List<int>.filled(32 - bytes.length, 0) + bytes);
  }

  Uint8List _bigIntToBytes(BigInt number) {
    final hex = number.toRadixString(16);
    final padded = hex.length.isOdd ? '0$hex' : hex;
    final result = Uint8List(padded.length ~/ 2);
    for (var i = 0; i < result.length; i++) {
      final start = i * 2;
      result[i] = int.parse(padded.substring(start, start + 2), radix: 16);
    }
    return result;
  }

  BigInt _bytesToBigInt(Uint8List bytes) {
    var result = BigInt.zero;
    for (final b in bytes) {
      result = (result << 8) | BigInt.from(b);
    }
    return result;
  }

  Uint8List _encodeDerInteger(BigInt value) {
    var bytes = _bigIntToBytes(value);
    if (bytes.isEmpty) {
      bytes = Uint8List.fromList([0]);
    }

    if (bytes.first & 0x80 != 0) {
      bytes = Uint8List.fromList([0, ...bytes]);
    }

    return Uint8List.fromList([
      0x02,
      ..._encodeDerLength(bytes.length),
      ...bytes,
    ]);
  }

  Uint8List _encodeDerSequence(List<Uint8List> items) {
    final content = Uint8List.fromList(items.expand((e) => e).toList());
    return Uint8List.fromList([
      0x30,
      ..._encodeDerLength(content.length),
      ...content,
    ]);
  }

  Uint8List _encodeDerLength(int length) {
    if (length < 128) {
      return Uint8List.fromList([length]);
    }

    final bytes = <int>[];
    var value = length;
    while (value > 0) {
      bytes.insert(0, value & 0xFF);
      value >>= 8;
    }

    return Uint8List.fromList([0x80 | bytes.length, ...bytes]);
  }
}

class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;

    try {
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      const darwin = DarwinInitializationSettings();
      const settings = InitializationSettings(
        android: android,
        iOS: darwin,
        macOS: darwin,
      );

      await _plugin.initialize(settings);
      _initialized = true;
    } catch (e) {
      debugPrint('Notification initialize skipped: $e');
    }
  }

  Future<void> requestPermissions() async {
    if (kIsWeb) return;

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        break;
      default:
        return;
    }

    await initialize();

    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();

    await _plugin
        .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, badge: true, sound: true);

    await _plugin
        .resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, badge: true, sound: true);
  }

  Future<void> showBalanceNotification({required double amount, required double total}) async {
    if (kIsWeb) return;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        break;
      default:
        return;
    }

    await initialize();

    const android = AndroidNotificationDetails(
      'balance_alerts',
      'Balance Alerts',
      channelDescription: 'Notify when account balance increases',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
    );

    const details = NotificationDetails(
      android: android,
      iOS: DarwinNotificationDetails(),
      macOS: DarwinNotificationDetails(),
    );

    final id = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    const title = 'Token Deposit';
    final body =
        'Received ${amount.toStringAsFixed(2)} tokens. Current balance: ${total.toStringAsFixed(2)}';

    await _plugin.show(id, title, body, details);
  }
}

class AppStorage {
  static const String _languageKey = 'app_language';
  static const String _lastBalanceKeyPrefix = 'last_known_balance_';
  static const String _deviceIdKey = 'device_id';
  static const String _activeSessionIdKey = 'active_session_id';
  static const String _autoUpdateCheckEnabledKey = 'auto_update_check_enabled';

  static Future<AppLanguage> getLanguage() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_languageKey) ?? 'system';
    return AppLanguageTag.fromTag(raw);
  }

  static Future<void> setLanguage(AppLanguage language) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_languageKey, language.tag);
  }

  static Future<Map<String, double>> getLastKnownBalances() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      for (final token in AppToken.supported)
        token.id: double.tryParse(
              prefs.getString('$_lastBalanceKeyPrefix${token.id}') ?? '0.0',
            ) ??
            0.0,
    };
  }

  static Future<void> setLastKnownBalance(String tokenId, String balance) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_lastBalanceKeyPrefix$tokenId', balance);
  }

  static Future<String> getDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_deviceIdKey);
    if (existing != null && existing.isNotEmpty) return existing;

    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    final generated = 'dlinker_${base64UrlEncode(bytes).replaceAll('=', '')}';

    await prefs.setString(_deviceIdKey, generated);
    return generated;
  }

  static Future<String> getActiveSessionId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_activeSessionIdKey) ?? '';
  }

  static Future<void> setActiveSessionId(String sessionId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeSessionIdKey, sessionId.trim());
  }

  static Future<void> clearActiveSessionId() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_activeSessionIdKey);
  }

  static Future<bool> getAutoUpdateCheckEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoUpdateCheckEnabledKey) ?? true;
  }

  static Future<void> setAutoUpdateCheckEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoUpdateCheckEnabledKey, enabled);
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

enum AddressInputAction { confirm, scan, contacts }

class AddressInputResult {
  const AddressInputResult({
    required this.action,
    required this.value,
  });

  final AddressInputAction action;
  final String value;
}

class T {
  static final Map<String, Map<String, String>> _values = {
    'en': {
      'token_symbol': 'ZHIXI',
      'loading': 'Loading...',
      'app_dashboard_title': 'D-Linker Dashboard',
      'my_assets': 'My Assets',
      'balance_format': '{1} {2}',
      'device_wallet_address': 'Device Wallet Address',
      'copy_success': 'Copied successfully',
      'receive': 'Receive',
      'wallet_auth': 'Wallet Auth',
      'scan': 'Scan',
      'transfer': 'Transfer',
      'migration': 'Device Migration',
      'request_test_coins': 'Get Test Coins ({1})',
      'airdrop_request_sent': 'Airdrop request sent',
      'failure_message': 'Failure: {1}',
      'update_available': 'Update Available',
      'update_desc': 'A new version ({1}) is available.',
      'update_later': 'Later',
      'update_now': 'Update Now',
      'update_open_failed': 'Unable to open update page',
      'auto_update_check': 'Auto Check Updates',
      'session_required': 'Please complete Wallet Auth first',
      'casino': 'Casino',
      'manual_address_input': 'Enter Address Manually',
      'address_placeholder': '0x...',
      'cancel': 'Cancel',
      'confirm': 'Confirm',
      'send_symbol': 'Send {1}',
      'to_address': 'To: {1}',
      'amount': 'Amount',
      'confirm_send': 'Confirm Send',
      'transfer_success': 'Transfer successful!',
      'receive_address': 'Receive Address',
      'close': 'Close',
      'camera_permission_required': 'Camera permission is required',
      'migration_title': 'Full Device Migration',
      'migration_desc':
          'Private key cannot be exported from hardware security module. Transfer all assets to the new device address.',
      'migration_confirm': 'Confirm Transfer All Balance',
      'settings': 'Settings',
      'lang_auto': 'System Default',
      'lang_zh_tw': 'Traditional Chinese',
      'lang_zh_cn': 'Simplified Chinese',
      'lang_en': 'English',
      'transaction_history': 'Transaction History',
      'tx_send': 'Send',
      'tx_receive': 'Receive',
      'tx_no_history': 'No transaction history yet',
      'auth_confirm_title': 'Wallet Auth Request',
      'auth_confirm_desc':
          'The web app requests wallet linking.\n\nSession ID: {1}\nAddress: {2}',
      'auth_confirm_button': 'Authorize',
      'auth_success_return': 'Authorization complete. You can return to web.',
      'manual_code_entry': 'Manual Code',
      'manual_code_hint': 'Paste session_xxx or dlinker:login:xxx',
      'manual_code_error': 'Invalid authorization code format',
      'bet_confirm_title': 'Bet Signature Request',
      'bet_confirm_desc': 'Game: {1}\nSide: {2}\nAmount: {3} {4}',
      'bet_confirm_button': 'Sign & Submit Bet',
      'bet_success': 'Bet request submitted',
      'contacts': 'Contacts',
      'select_contact': 'Select Contact',
      'no_contacts': 'No contacts yet',
      'add_contact': 'Add Contact',
      'contact_name': 'Name',
      'wallet_address': 'Wallet Address',
    },
    'zh_TW': {
      'token_symbol': '子熙幣',
      'loading': '載入中...',
      'app_dashboard_title': 'D-Linker 儀表板',
      'my_assets': '我的資產',
      'balance_format': '{1} {2}',
      'device_wallet_address': '設備錢包地址',
      'copy_success': '複製成功',
      'receive': '收款',
      'wallet_auth': '錢包授權',
      'scan': '掃描',
      'transfer': '轉帳',
      'migration': '設備轉移',
      'request_test_coins': '領取測試幣（{1}）',
      'airdrop_request_sent': '入金請求已送出',
      'failure_message': '失敗: {1}',
      'update_available': '有新版本可更新',
      'update_desc': '偵測到新版本（{1}），請更新。',
      'update_later': '稍後',
      'update_now': '立即更新',
      'update_open_failed': '無法開啟更新頁面',
      'auto_update_check': '自動檢查更新',
      'session_required': '請先完成錢包授權',
      'casino': '賭場',
      'manual_address_input': '手動輸入地址',
      'address_placeholder': '0x...',
      'cancel': '取消',
      'confirm': '確定',
      'send_symbol': '發送 {1}',
      'to_address': '至: {1}',
      'amount': '金額',
      'confirm_send': '確認發送',
      'transfer_success': '轉帳成功！',
      'receive_address': '收款地址',
      'close': '關閉',
      'camera_permission_required': '請授予相機權限',
      'migration_title': '全額設備轉移',
      'migration_desc': '請將所有資產轉移至新設備地址。',
      'migration_confirm': '確認轉移全部餘額',
      'settings': '設定',
      'lang_auto': '跟隨系統',
      'lang_zh_tw': '繁體中文',
      'lang_zh_cn': '簡體中文',
      'lang_en': 'English',
      'transaction_history': '交易紀錄',
      'tx_send': '轉出',
      'tx_receive': '轉入',
      'tx_no_history': '目前尚無交易紀錄',
      'auth_confirm_title': '授權登入請求',
      'auth_confirm_desc': '網頁端請求連結您的錢包。\n\nSession ID: {1}\n地址: {2}',
      'auth_confirm_button': '確認授權',
      'auth_success_return': '授權成功，可返回網頁',
      'manual_code_entry': '輸入授權碼',
      'manual_code_hint': '貼上 session_xxx 或 dlinker:login:xxx',
      'manual_code_error': '授權碼格式錯誤',
      'bet_confirm_title': '下注簽名請求',
      'bet_confirm_desc': '遊戲: {1}\n選擇: {2}\n金額: {3} {4}',
      'bet_confirm_button': '確認下注並簽名',
      'bet_success': '下注請求已送出',
      'contacts': '通訊錄',
      'select_contact': '選擇聯絡人',
      'no_contacts': '目前尚無聯絡人',
      'add_contact': '新增聯絡人',
      'contact_name': '姓名',
      'wallet_address': '錢包地址',
    },
    'zh_CN': {
      'token_symbol': '子熙币',
      'loading': '加载中...',
      'app_dashboard_title': 'D-Linker 仪表板',
      'my_assets': '我的资产',
      'balance_format': '{1} {2}',
      'device_wallet_address': '设备钱包地址',
      'copy_success': '复制成功',
      'receive': '收款',
      'wallet_auth': '钱包授权',
      'scan': '扫描',
      'transfer': '转账',
      'migration': '设备转移',
      'request_test_coins': '领取测试币（{1}）',
      'airdrop_request_sent': '入金请求已发送',
      'failure_message': '失败: {1}',
      'update_available': '有新版本可更新',
      'update_desc': '检测到新版本（{1}），请更新。',
      'update_later': '稍后',
      'update_now': '立即更新',
      'update_open_failed': '无法打开更新页面',
      'auto_update_check': '自动检查更新',
      'session_required': '请先完成钱包授权',
      'casino': '赌场',
      'manual_address_input': '手动输入地址',
      'address_placeholder': '0x...',
      'cancel': '取消',
      'confirm': '确定',
      'send_symbol': '发送 {1}',
      'to_address': '至: {1}',
      'amount': '金额',
      'confirm_send': '确认发送',
      'transfer_success': '转账成功！',
      'receive_address': '收款地址',
      'close': '关闭',
      'camera_permission_required': '请授予相机权限',
      'migration_title': '全额设备转移',
      'migration_desc': '请将所有资产转移至新设备地址。',
      'migration_confirm': '确认转移全部余额',
      'settings': '设置',
      'lang_auto': '跟随系统',
      'lang_zh_tw': '繁体中文',
      'lang_zh_cn': '简体中文',
      'lang_en': 'English',
      'transaction_history': '交易纪录',
      'tx_send': '转出',
      'tx_receive': '转入',
      'tx_no_history': '目前尚无交易纪录',
      'auth_confirm_title': '授权登录请求',
      'auth_confirm_desc': '网页端请求链接您的钱包。\n\nSession ID: {1}\n地址: {2}',
      'auth_confirm_button': '确认授权',
      'auth_success_return': '授权成功，可返回网页',
      'manual_code_entry': '输入授权码',
      'manual_code_hint': '粘贴 session_xxx 或 dlinker:login:xxx',
      'manual_code_error': '授权码格式错误',
      'bet_confirm_title': '下注签名请求',
      'bet_confirm_desc': '游戏: {1}\n选择: {2}\n金额: {3} {4}',
      'bet_confirm_button': '确认下注并签名',
      'bet_success': '下注请求已发送',
      'contacts': '通讯录',
      'select_contact': '选择联系人',
      'no_contacts': '目前尚无联系人',
      'add_contact': '新增联系人',
      'contact_name': '姓名',
      'wallet_address': '钱包地址',
    },
  };

  static String of(BuildContext context, String key, [List<String> args = const []]) {
    final locale = Localizations.localeOf(context);
    final localeCode = _localeCode(locale);
    final template = _values[localeCode]?[key] ?? _values['en']?[key] ?? key;

    var result = template;
    for (var i = 0; i < args.length; i++) {
      result = result.replaceAll('{${i + 1}}', args[i]);
    }
    return result;
  }

  static String _localeCode(Locale locale) {
    if (locale.languageCode == 'zh') {
      final country = (locale.countryCode ?? '').toUpperCase();
      final script = (locale.scriptCode ?? '').toLowerCase();
      if (country == 'CN' || script == 'hans') {
        return 'zh_CN';
      }
      return 'zh_TW';
    }
    return 'en';
  }
}
