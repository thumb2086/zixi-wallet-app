import 'package:device_linker_flutter/update_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// 自動更新的邏輯測試。
///
/// ★ 為什麼這些要測（2026-10-14）
///
///   `isUpdateAvailable` 是「要不要提示使用者升級」的唯一判準，
///   原本是 private 實例方法 —— 沒有辦法測。
///   它有三個容易出錯的地方，剛好都是實際發生過的：
///     · `v` 前綴 —— GitHub 的 tag 是 "v2.5.3"，而
///       PackageInfo.version 是 "2.5.2"（沒有 v）。兩邊格式不一致。
///     · 長度不一的版號 —— "2.5" vs "2.5.3"
///     · 非數字段落 —— 不該讓它變成 NaN 然後比較全 false
///
///   節流狀態是 static，所以測試之間要用 resetThrottleForTest() 隔離。
///   ★ 這是刻意的取捨：static 讓跨 isolate 的多個畫面共用一份節流狀態
///     （這正是我們要的），代價是測試必須手動重置。
void main() {
  group('isUpdateAvailable — semver 比較', () {
    test('相同版本 → 不是新版本', () {
      expect(GithubUpdateService.isUpdateAvailable('2.5.2', '2.5.2'), isFalse);
    });

    test('小版本較新 → 是新版本', () {
      expect(GithubUpdateService.isUpdateAvailable('2.5.2', '2.5.3'), isTrue);
    });

    test('次版本較新 → 是新版本', () {
      expect(GithubUpdateService.isUpdateAvailable('2.5.2', '2.6.0'), isTrue);
    });

    test('主版本較新 → 是新版本', () {
      expect(GithubUpdateService.isUpdateAvailable('2.5.2', '3.0.0'), isTrue);
    });

    test('遠端較舊 → 不是新版本（降級不提示）', () {
      expect(GithubUpdateService.isUpdateAvailable('2.5.2', '2.5.1'), isFalse);
      expect(GithubUpdateService.isUpdateAvailable('3.0.0', '2.9.9'), isFalse);
    });

    test('★ GitHub 的 tag 有 v 前綴，本地版本沒有', () {
      // 這是最容易漏的一組：實際情況一定是 current 無 v、latest 有 v
      expect(GithubUpdateService.isUpdateAvailable('2.5.2', 'v2.5.3'), isTrue);
      expect(GithubUpdateService.isUpdateAvailable('2.5.3', 'v2.5.3'), isFalse);
      expect(GithubUpdateService.isUpdateAvailable('v2.5.2', '2.5.3'), isTrue);
      expect(GithubUpdateService.isUpdateAvailable('v2.5.3', 'v2.5.3'), isFalse);
    });

    test('★ 版號長度不一致要用 0 補齊', () {
      expect(GithubUpdateService.isUpdateAvailable('2.5', '2.5.0'), isFalse);
      expect(GithubUpdateService.isUpdateAvailable('2.5', '2.5.1'), isTrue);
      expect(GithubUpdateService.isUpdateAvailable('2', '2.0.1'), isTrue);
    });

    test('★ 非數字段落不能變成 NaN 後靜默比較失敗', () {
      // 補零規則應該讓 '2.5.x' 仍能與 '2.5.3' 比較
      expect(GithubUpdateService.isUpdateAvailable('2.5.2', '2.5.x'), isFalse);
      // 壞掉的 tag 不該讓 App 認為「有更新」而瘋狂提示
      expect(GithubUpdateService.isUpdateAvailable('2.5.2', ''), isFalse);
      expect(GithubUpdateService.isUpdateAvailable('', ''), isFalse);
    });

    test('★ 跨 9→10 的進位（字串比較會錯的那種）', () {
      expect(GithubUpdateService.isUpdateAvailable('2.9.9', '2.10.0'), isTrue);
      expect(GithubUpdateService.isUpdateAvailable('2.10.0', '2.9.9'), isFalse);
    });
  });

  group('節流狀態', () {
    setUp(GithubUpdateService.resetThrottleForTest);
    tearDown(GithubUpdateService.resetThrottleForTest);

    test('初始狀態：沒有排定的檢查時間', () {
      expect(GithubUpdateService.nextCheckAtForTest(), 0);
    });

    test('resetThrottleForTest 會清掉狀態', () {
      // 先讓某次呼叫排定未來時間，再確認 reset 能清掉
      GithubUpdateService.isUpdateAvailable('1.0.0', '2.0.0');
      expect(GithubUpdateService.resetThrottleForTest, isNotNull);
      expect(GithubUpdateService.nextCheckAtForTest(), 0);
    });
  });
}