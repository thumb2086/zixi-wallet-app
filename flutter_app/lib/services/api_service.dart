import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:web3dart/web3dart.dart';

import '../config/env.dart';
import '../models/history_item.dart';
import 'storage_service.dart';

class ApiService {
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

  /// 授權訊息的**唯一來源**。
  ///
  /// 為什麼要放在這裡：伺服器端（zixi-earth/src/dlinker.js）會用同一個字串
  /// 還原簽名者地址，兩邊差一個字元或大小寫，驗證就會失敗，而且症狀是
  /// 「SIGNER_MISMATCH」—— 看起來像簽章壞了，實際上是字串不一致。
  /// 這個字串**只有這一個定義**，呼叫端一律呼叫它，不要自己拼。
  ///
  /// 綁定 sessionId 是刻意的：沒有它，簽出來的授權可以被跨 session 重放。
  ///
  /// ⚠️ 這是**實例**方法不是 static —— 因為它呼叫 `_normalizeAddress`
  /// （那也是實例方法）。寫成 static 會得到編譯錯誤
  /// "Instance members can't be accessed from a static method"。
  String authMessage(String sessionId, String address) {
    final normalized = _normalizeAddress(address);
    return 'dlinker-auth:$sessionId:${normalized.substring(2)}';
  }

  /// 送出硬體授權。
  ///
  /// ⚠️ [sign] 是必要的，不是可選的。
  /// 舊的 zixi-casino 後端在這裡**沒有驗任何簽章**，只要宣告一個地址就綁定了 ——
  /// 等於任何人都能冒用他人的鏈上地址並轉走對方的餘額。
  /// zixi-earth 的實作強制要求簽章，且比對還原出的地址與宣告地址是否相同。
  /// 所以這個簽名不能省，也不能改成「有才送」。
  Future<void> sendAuth({
    required String sessionId,
    required String address,
    required String publicKey,
    required Future<String> Function(String message) sign,
  }) async {
    final normalizedSessionId = _normalizeSessionId(sessionId);
    final normalizedAddress = _normalizeAddress(address);
    debugPrint('[sendAuth] sessionId=$normalizedSessionId address=$normalizedAddress');
    final authContext = await _buildAuthContext();
    final message = authMessage(normalizedSessionId, normalizedAddress);
    final signature = await sign(message);
    final json = await _post('user.js', {
      'action': 'authorize',
      'sessionId': normalizedSessionId,
      'address': normalizedAddress,
      'publicKey': _normalizePublicKey(publicKey),
      'signature': signature,
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
      // ⚠️ signedAmount 不可省略（2026-10-13 加）。
      //
      // 簽章簽在 `coinflip:<side>:<amount>:<token>` 上，其中 amount 是
      // **使用者輸入的原始字串**（BetRequest.amount 是 String）。
      // 但 betAmount 送出去是 double.parse() 之後的數字。
      //
      //   使用者輸入 "25.50" → 簽在 "25.50"
      //                      → 送出 25.5
      //                      → 伺服器重建出 "25.5" → 驗證失敗
      //
      // 而且這個失敗會在使用者**輸了錢之後**才浮現（因為下注要先扣款），
      // 症狀是「錢扣了但回錯誤」。所以原始字串必須一起送。
      'signedAmount': amount,
      'selection': side.trim().toLowerCase(),
      'token': 'zhixi',
      'signature': signature,
      'publicKey': publicKey,
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
      'signature': signature,
      'publicKey': publicKey,
    });
    final data = _unwrapData(json, fallbackError: 'Transfer failed');

    return (data['txHash'] ?? '').toString();
  }

  Future<String> convert({
    required String sessionId,
    required String address,
    required String zxcAmount,
    required String signature,
    required String publicKey,
  }) async {
    _normalizeAddress(address);
    _normalizePublicKey(publicKey);
    if (signature.trim().isEmpty) {
      throw Exception('Missing signature');
    }
    final json = await _post('v1/wallet/convert', {
      'sessionId': _normalizeSessionId(sessionId),
      'address': _normalizeAddress(address),
      'zxcAmount': zxcAmount,
      'signature': signature,
      'publicKey': publicKey,
    });
    final data = _unwrapData(json, fallbackError: 'Convert failed');
    return (data['txHash'] ?? data['reward'] ?? '').toString();
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

    final allHistory = <HistoryItem>[];
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
          allHistory.add(HistoryItem.fromJson(mapped));
        }
      }
    }

    final offset = (page - 1) * limit;
    final pageItems = allHistory.length > offset
        ? allHistory.sublist(offset, offset + limit > allHistory.length ? allHistory.length : offset + limit)
        : <HistoryItem>[];

    return HistoryResponse(
      page: page,
      hasMore: offset + limit < allHistory.length,
      history: pageItems,
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
    final uri = Uri.parse('${Env.apiBaseUrl}$endpoint');
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
    final url = Uri.parse('${Env.apiBaseUrl}$endpoint');

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
