# Device-Linker

Device-Linker 是一個以 Flutter 為核心的多平台錢包應用專案，搭配 REST 後台 API 與 EVM 鏈上合約，提供裝置導向的地址管理、授權、簽名與轉帳流程。

## ✅ 後端已重新打通（2026-10-13）

舊後端 `zixi-casino-api.onrender.com`（逾時 25 秒）與
`zixi-casino.vercel.app`（404）都已停用，
**現在改為連線到合併後的 `zixi-earth`**。

相容層在 `../zixi-earth/src/dlinker.js`，**9 個端點全部實作**
（`market/action` 只支援 `bank_deposit` 與 `borrow`）：

| 端點 | 狀態 |
|---|---|
| `POST /api/v1/auth/create-session` | ✅ |
| `GET /api/v1/auth/status` | ✅ |
| `POST /api/user.js`（authorize）| ✅ 強制驗簽章 |
| `GET /api/v1/wallet/summary` | ✅ |
| `POST /api/v1/wallet/transfer` | ✅ 強制驗簽章 |
| `POST /api/v1/wallet/airdrop` | ✅ 有冷卻 |
| `POST /api/v1/games/coinflip/play` | ✅ 委派給既有的 `/api/games/coinflip` |
| `GET /api/v1/market/me` | ✅ 委派給 `/api/market/mine` |
| `POST /api/v1/market/action` | ⚠ 只支援 `bank_deposit`、`borrow` |

**授權訊息格式**（app 與伺服器必須逐字一致，差一個字元就 SIGNER_MISMATCH）：

```
dlinker-auth:<sessionId>:<address 去掉 0x，小寫>
```

格式定義在 `ApiService.authMessage()` —— **只有這一個定義**，不要在別處拼字串。

> **注意**：規格文件 `device-linker-api-integration.md` 已經過時，
> 它完全沒寫簽名機制，而且 transfer 訊息寫 3 段、實際簽 4 段（多一個 tokenId）。
> **以程式碼為準，不要以文件為準。**

鏈也已統一：Ethereum Sepolia（11155111），與 `zixi-earth` 一致。

## Repo 狀態
- 已完成從舊版 Android Kotlin 專案遷移到 Flutter-first 架構。
- 舊 Android 原生模組與根目錄 Gradle 工程已移除。
- `flutter_app/lib/main.dart` 已拆分（不再是 single-file app）。

## 目錄結構
- `flutter_app/`: Flutter 應用程式（主要前端）
  - `lib/views/`（8 個畫面）、`lib/services/`（api / key / storage / notification）、
    `lib/models/`、`lib/config/env.dart`（後端網址）、`lib/l10n/`
- `blockchain/`: 合約與鏈上腳本
- `.github/workflows/`: CI/CD 流程

## 技術棧
- Flutter / Dart
- REST API（**目標：zixi-earth，Cloudflare Workers**）
- EVM 測試鏈
- ERC-20 合約

## ⚠️ 中文路徑會讓 flutter analyze 崩潰

這個 repo 現在位於 `大拇哥實驗室\地球在線合併\`（含中文），
在這個路徑下 `flutter analyze` 會讓 analysis server 直接崩掉：

```
FormatException: Unterminated string (at character 587)
...0%88%E4%BD%B5/zixi-wallet-app/flutter_app/
```

**錯誤訊息裡只有被截斷的中文編碼，完全看不出是路徑問題** ——
第一次遇到時我以為是環境沒裝 SDK。

⚠️ 這跟 wrangler 在中文路徑會 native crash（`0xC0000409`）是**同一類問題、
不同症狀**。`zixi-earth` 為此用 ASCII staging 部署，Flutter 這裡要手動處理：

```powershell
# 複製到 ASCII 路徑再分析
robocopy "<repo>\flutter_app" "$env:TEMP\opencode\fa-analyze" /E /XD build .dart_tool
cd "$env:TEMP\opencode\fa-analyze"
flutter pub get
flutter analyze     # → No issues found!
flutter test        # → All tests passed!
```

`flutter pub get` 本身在中文路徑下可以跑，壞的是 analysis server。

### 兩個驗證簽章格式的工具

| 工具 | 用途 |
|---|---|
| `tool/cmp_sig.dart` | 確認 web3dart 的 `signPersonalMessage`（棄用）與 `signPersonalMessageToUint8List` 產生的位元組**完全相同** —— 換 API 之前的安全前提 |
| `tool/e2e_sign_check.dart` | **端到端**：Dart 簽 → 線上伺服器驗。實測通過 |

`flutter analyze` 現況：**No issues found**（CI 要求零警告）。

---

## 快速開始

### 1) Flutter App
```bash
cd flutter_app
flutter create . --project-name device_linker_flutter --org com.devicelinker --platforms=android,ios,web,linux,windows
flutter pub get
flutter analyze
flutter test
flutter run
```

### iOS 實機安裝注意
- 本 repo 預設不提交 `flutter_app/ios/`，需先生成平台殼層。
- 可執行 `flutter_app/scripts/bootstrap_ios.sh` 一次完成 iOS 初始化與 release build（no-codesign）。
- 要安裝到 iPhone，仍需在 macOS + Xcode 進行簽名與匯出 `.ipa`（設定 Team / Provisioning Profile）。

### 2) Backend API

**後端網址在 `flutter_app/lib/config/env.dart`**（不是 `main.dart`），且可用
`--dart-define=API_BASE_URL=...` 在編譯時覆寫：

```dart
static const String apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'https://zixi-casino-api.onrender.com/api/',   // ⛔ 已失效
);
```

新站（`zixi-earth`）需要提供的相容端點 — 規格在 `device-linker-api-integration.md`：

| Method | Path | 用途 |
|---|---|---|
| `POST` | `/api/v1/auth/create-session` | 建立待授權 session |
| `GET` | `/api/v1/auth/status?sessionId=` | 輪詢授權狀態 |
| `POST` | `/api/user.js` (action: authorize) | 裝置授權（legacy）|
| `GET` | `/api/v1/wallet/summary?sessionId=` | 餘額 + 近期交易 |
| `POST` | `/api/v1/wallet/transfer` | 轉帳 |
| `POST` | `/api/v1/wallet/airdrop` | 測試幣空投 |
| `POST` | `/api/v1/games/coinflip/play` | 猜硬幣 |
| `GET` | `/api/v1/market/me?sessionId=` | 市場帳戶快照 |
| `POST` | `/api/v1/market/action` | 市場操作 |

**合約地址與新站相同，可直接沿用：**
ZXC `0xe3d9af5f15857cb01e0614fa281fcc3256f62050` ·
YJC `0x82D6aDB17d58820324D86B378775350D03a071AE`

**⚠️ 鏈要統一**：`blockchain/` 目前是 Base Sepolia（84532），
而新站是 Sepolia（11155111）。已決定統一到 Sepolia，**尚未動手**。

## 開發流程建議
1. 先在 `flutter_app` 完成 UI 與簽名/交易流程。
2. 若 API 規格變更，同步更新 `flutter_app/lib/services/api_service.dart`。
3. 若合約介面變更，同步更新 `blockchain/` 與前後端呼叫參數。

## CI/CD
- `flutter-multiplatform-build.yml`: Flutter 多平台建置與釋出流程
- iOS 會輸出 `flutter-ios-unsigned.ipa`（未簽名），可供後續 Apple 簽名或第三方重簽工具使用

## 遷移備註
- 本 repo 目前不包含 Flutter 自動產生的平台殼層目錄（如 `flutter_app/android`、`flutter_app/ios`）。
- 需要時可透過 `flutter create . --platforms=...` 重新生成。

## 授權
本專案授權方式請依組織政策或另行補上 LICENSE 檔案。
