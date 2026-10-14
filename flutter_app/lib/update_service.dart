import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'l10n/translation.dart';

/// 檢查更新的結果。
///
/// ★ 為什麼需要這個 enum（2026-10-14）
///
///   原本 `checkForUpdates` 回 `Future<void>`，失敗時只 `debugPrint`。
///   於是三種完全不同的情況看起來一模一樣：
///     · 已經是最新版（正常）
///     · GitHub 回 429/403 限流
///     · 網路斷了
///   使用者與呼叫端都無法區分 —— 而「限流」是會**持續**的狀態，
///   一旦撞到就再也收不到更新通知，而且沒有任何提示。
///   這是最難查的一種失效：沒有錯誤、沒有崩潰，只是「從此沒更新了」。
enum UpdateCheckResult {
  /// 已經是最新版，或被節流擋下（未發出網路請求）。
  upToDate,

  /// 有新版本（已彈出對話框）。
  updateAvailable,

  /// 查得到但被限流（未認證的額度是 60 次/小時/每個 IP）。
  rateLimited,

  /// 網路或其他錯誤。
  failed,
}

class GithubUpdateService {
  static const String _owner = 'thumb2086';
  static const String _repo = 'zixi-wallet-app';
  static const String _apiUrl =
      'https://api.github.com/repos/$_owner/$_repo/releases/latest';
  static const String _releasesUrl = 'https://github.com/$_owner/$_repo/releases';
  static const String _latestReleaseUrl = '$_releasesUrl/latest';

  /// 兩次自動檢查的最小間隔。
  ///
  /// ★ 為什麼需要節流（2026-10-14）
  ///
  ///   原本每次進 dashboard 都打一次 GitHub API（`dashboard_screen.dart`
  ///   的 `_scheduleUpdateCheck()` 在每次 `_load()` 尾端被呼叫）。
  ///   而這個端點是**未認證**的，額度是 60 次/小時/**每個 IP** ——
  ///   同一個 NAT 下的多台裝置會共用這個額度。
  ///
  ///   撞到限流之後，原作的處理是 `if (response.statusCode != 200) return;`
  ///   —— 靜默返回。之後每次啟動都再撞一次、使用者永遠不會再收到
  ///   更新通知、也沒有任何提示。
  static const Duration throttleInterval = Duration(hours: 6);

  /// 撞到限流後的退避時間（比正常節流長，避免持續撞牆）。
  static const Duration rateLimitBackoff = Duration(hours: 12);

  /// 下次允許檢查的時間點（epoch 毫秒）。0 = 尚未檢查過。
  static int _nextCheckAtMs = 0;

  /// 檢查是否有新版本。
  ///
  /// [force] = true 時跳過節流（給設定頁的「立即檢查」用）。
  /// 回傳 [UpdateCheckResult] 讓呼叫端能區分「沒更新」與「查不到」。
  Future<UpdateCheckResult> checkForUpdates(
    BuildContext context, {
    required String title,
    required String descriptionTemplate,
    required String laterLabel,
    required String nowLabel,
    required String openFailedMessage,
    bool force = false,
  }) async {
    if (!force) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now < _nextCheckAtMs) {
        debugPrint('Update check skipped (throttled until $_nextCheckAtMs)');
        return UpdateCheckResult.upToDate;
      }
    }

    http.Response response;
    try {
      response = await http.get(
        Uri.parse(_apiUrl),
        headers: const {
          // 明確宣告要 JSON，否則 GitHub 可能依 Accept 走別的格式
          'Accept': 'application/vnd.github+json',
        },
      );
    } catch (e) {
      // ★ 網路錯誤也要記入節流 —— 離線時重試是沒有意義的，
      //   而原本的寫法會讓每次啟動都重試一次。
      _scheduleNextCheck(throttleInterval);
      debugPrint('Update check network failure: $e');
      return UpdateCheckResult.failed;
    }

    // ★ 限流要與其他錯誤分開處理 —— 兩者的退避時間不同。
    //   GitHub 在額度用盡時回 429，403 也可能出現同義情況。
    if (response.statusCode == 429 || response.statusCode == 403) {
      final resetMs = _rateLimitResetMs(response.headers['x-ratelimit-reset']);
      _scheduleNextCheck(rateLimitBackoff, resetMs);
      debugPrint('Update check rate limited (HTTP ${response.statusCode}), '
          'next attempt at $_nextCheckAtMs');
      if (!context.mounted) return UpdateCheckResult.rateLimited;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(T.of(context, 'update_rate_limited'))),
      );
      return UpdateCheckResult.rateLimited;
    }

    if (response.statusCode != 200) {
      _scheduleNextCheck(throttleInterval);
      debugPrint('Update check unexpected HTTP ${response.statusCode}');
      return UpdateCheckResult.failed;
    }

    _scheduleNextCheck(throttleInterval);

    Map<String, dynamic> data;
    try {
      data = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('Update check JSON parse failure: $e');
      return UpdateCheckResult.failed;
    }

    final String latestTagName = (data['tag_name'] ?? '').toString();
    final String htmlUrl = (data['html_url'] ?? '').toString().trim();
    final String releaseUrl = htmlUrl.isNotEmpty ? htmlUrl : _latestReleaseUrl;
    if (latestTagName.isEmpty) return UpdateCheckResult.upToDate;

    final packageInfo = await PackageInfo.fromPlatform();
    final String currentVersion = packageInfo.version;

    if (!_isUpdateAvailable(currentVersion, latestTagName)) {
      return UpdateCheckResult.upToDate;
    }
    if (!context.mounted) return UpdateCheckResult.updateAvailable;

    final description = descriptionTemplate.replaceAll('{1}', latestTagName);
    _showUpdateDialog(
      context,
      title: title,
      description: description,
      laterLabel: laterLabel,
      nowLabel: nowLabel,
      url: releaseUrl,
      openFailedMessage: openFailedMessage,
    );
    return UpdateCheckResult.updateAvailable;
  }

  /// 排定下次可檢查的時間。[resetMs] 若有效（比現在更晚）則以它為準。
  static void _scheduleNextCheck(Duration interval, [int? resetMs]) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final fallback = now + interval.inMilliseconds;
    _nextCheckAtMs = (resetMs != null && resetMs > now) ? resetMs : fallback;
  }

  static int _rateLimitResetMs(String? header) {
    if (header == null) return 0;
    final secs = int.tryParse(header);
    if (secs == null || secs <= 0) return 0;
    return secs * 1000;
  }

  /// 測試用：清掉節流狀態。
  @visibleForTesting
  static void resetThrottleForTest() {
    _nextCheckAtMs = 0;
  }

  /// 測試用：目前排定的下次檢查時間。
  @visibleForTesting
  static int nextCheckAtForTest() => _nextCheckAtMs;

  /// 比較兩個 semver 字串，回傳 true 表示 [latest] 比 [current] 新。
  ///
  /// 抽成 static + visibleForTesting 的理由：這是「要不要提示使用者」
  /// 的唯一判準，卻是 private 實例方法 —— 沒有辦法測。
  /// 而它有幾個容易出錯的地方：`v` 前綴、長度不一的版號字串、
  /// 非數字段落。全部都要有測試釘住。
  @visibleForTesting
  static bool isUpdateAvailable(String current, String latest) {
    // Basic semver comparison
    // Normalizing: remove 'v' prefix if present
    String cleanCurrent = current.startsWith('v') ? current.substring(1) : current;
    String cleanLatest = latest.startsWith('v') ? latest.substring(1) : latest;

    List<int> currentParts =
        cleanCurrent.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    List<int> latestParts =
        cleanLatest.split('.').map((e) => int.tryParse(e) ?? 0).toList();

    // Pad with zeros if necessary
    while (currentParts.length < 3) {
      currentParts.add(0);
    }
    while (latestParts.length < 3) {
      latestParts.add(0);
    }

    for (int i = 0; i < 3; i++) {
      if (latestParts[i] > currentParts[i]) return true;
      if (latestParts[i] < currentParts[i]) return false;
    }

    return false;
  }

  bool _isUpdateAvailable(String current, String latest) =>
      isUpdateAvailable(current, latest);

  void _showUpdateDialog(
    BuildContext context, {
    required String title,
    required String description,
    required String laterLabel,
    required String nowLabel,
    required String url,
    required String openFailedMessage,
  }) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(description),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(laterLabel),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              await _openUpdatePage(context, url, openFailedMessage);
            },
            child: Text(nowLabel),
          ),
        ],
      ),
    );
  }

  Future<void> _openUpdatePage(
    BuildContext context,
    String url,
    String openFailedMessage,
  ) async {
    final candidates = <Uri>[
      Uri.parse(url),
      Uri.parse(_latestReleaseUrl),
      Uri.parse(_releasesUrl),
    ];

    for (final uri in candidates) {
      try {
        if (await launchUrl(uri, mode: LaunchMode.externalApplication)) {
          return;
        }
      } catch (e) {
        debugPrint('External update launch failed for $uri: $e');
      }
    }

    for (final uri in candidates) {
      try {
        if (await launchUrl(uri, mode: LaunchMode.platformDefault)) {
          return;
        }
      } catch (e) {
        debugPrint('Fallback update launch failed for $uri: $e');
      }
    }

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(openFailedMessage)),
    );
  }
}