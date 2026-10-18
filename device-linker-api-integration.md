# Device-Linker API Integration

> ## ⚠️ 狀態：規格有效，但提供它的服務已經沒了（2026-10-13 實測）
>
> ```text
> zixi-casino.vercel.app         → HTTP 404
> zixi-casino-api.onrender.com   → 逾時 25 秒
> ```
>
> **這份文件現在的用途是「合約」而不是「說明書」** ——
> `zixi-earth` 要補上這 9 個端點才能讓 app 重新可用。
>
> - **要照著抄的原始實作**：`../zixi-casino/apps/api/src/routes/legacy/user-legacy.ts`、
>   `../zixi-casino/apps/api/src/routes/v1/auth.ts`、`wallet-legacy.ts`
> - **目標後端**：`zixi-earth`（Cloudflare Workers + D1，不是 Vercel + Neon PG）
> - **回應格式必須維持** `{ success, data, error, requestId, timestamp }`，
>   因為 app 在解析它
> - **新端點放在哪**：建議新開 `zixi-earth/src/dlinker.js`，
>   從 `zixi-earth/src/index.js` 掛載
>
> ### 卡住的地方：認證
>
> app 用 `sessionId`（Device-Linker 硬體授權握手後取得），
> 而 `zixi-earth` **只有 Google／Discord OAuth**，沒有 session 概念、沒有硬體授權端點。
>
> 簽章裝置做不了 OAuth，所以要重新打通必須**新增一套 session 機制**
> （D1 存 session + 用 `personal_sign` 驗證裝置持有該地址的私鑰）。
>
> ### 鏈要統一
>
> `zixi-earth` 是 Sepolia（11155111）；`blockchain/` 是 Base Sepolia（84532）。
> 已決定統一到 Sepolia，尚未動手。合約地址兩邊相同，可直接沿用。

---

> 原始說明（服務由 [zixi-casino](https://github.com/thumb2086/zixi-casino) 的 `apps/api/` 提供）：
> Base URL: `https://zixi-casino.vercel.app/api/` —— **⛔ 已失效**

## Endpoints used by Device-Linker Flutter App

| Method | Path | Wallet Method | Status |
|--------|------|---------------|--------|
| `POST` | `/api/v1/auth/create-session` | `createPendingAuthSession` | ✅ V1 |
| `GET` | `/api/v1/auth/status?sessionId=` | `getAuthStatus` | ✅ V1 |
| `POST` | `/api/user.js` (action: authorize) | `sendAuth` | ⚠️ Legacy (no V1 equiv) |
| `GET` | `/api/v1/wallet/summary?sessionId=` | `getWalletSummary` | ✅ V1 |
| `POST` | `/api/v1/wallet/transfer` | `transfer` | ✅ V1 |
| `POST` | `/api/v1/wallet/airdrop` | `requestAirdrop` | ✅ V1 |
| `POST` | `/api/v1/games/coinflip/play` | `sendCoinFlip` | ✅ V1 |
| `GET` | `/api/v1/market/me?sessionId=` | `getMarketAccount` | ✅ V1 |
| `POST` | `/api/v1/market/action` | `sendMarketSimAction` | ✅ V1 |

## Auth Flow

### 1) Create pending session
`POST /api/v1/auth/create-session`
```json
{}
```
Response:
```json
{ "success": true, "data": { "sessionId": "sess_xxx", "deepLink": "dlinker://login/sess_xxx", "legacyDeepLink": "dlinker:login:sess_xxx" } }
```

### 2) Poll authorization status
`GET /api/v1/auth/status?sessionId=sess_xxx`
Response:
```json
{ "success": true, "data": { "status": "pending|authorized|expired", "address": "0x...", "publicKey": "..." } }
```

### 3) Authorize session (from Device-Linker app)
`POST /api/user.js`
```json
{
  "action": "authorize",
  "sessionId": "sess_xxx",
  "address": "0x...",
  "publicKey": "<base64-spki>",
  "platform": "android",
  "clientType": "mobile",
  "deviceId": "dlinker_xxx",
  "appVersion": "1.0.0+1"
}
```
> Legacy endpoint — no V1 equivalent yet.

## Wallet

### Get wallet summary
`GET /api/v1/wallet/summary?sessionId=sess_xxx`
```json
{
  "success": true,
  "data": {
    "summary": {
      "balances": { "ZXC": "0", "YJC": "0" },
      "recentTransactions": []
    }
  }
}
```

### Transfer
`POST /api/v1/wallet/transfer`
```json
{
  "sessionId": "sess_xxx",
  "to": "0x...",
  "amount": "10",
  "signedAmount": "10",
  "token": "zhixi",
  "nonce": "<server-issued nonce>",
  "signature": "0x...",
  "publicKey": "0x..."
}
```

Signature message (`ApiService.transferMessage()`, server `dlinker.js:450`) — **5 段**:

```text
transfer:<nonce>:<to 去掉 0x 的小寫>:<amount 字面>:<tokenId>
```

⚠️ **兩個容易簽不過的地方**

| 陷阱 | 說明 |
|---|---|
| `amount` 必須是**字面字串** | 使用者輸入 `"25.50"` → 伺服器用同一個字串驗簽。轉成數字 `25.5` 就對不上。伺服器另外檢查這個字串的數值是否等於實際轉帳金額（`AMOUNT_SIGNING_MISMATCH`）。`signedAmount` 欄位不可省略。 |
| `nonce` 是**強制**的 | 伺服器會拒絕沒有 nonce 的請求（`NONCE_REQUIRED`）。 |

### Airdrop
`POST /api/v1/wallet/airdrop`
```json
{ "sessionId": "sess_xxx" }
```

## Coinflip

`POST /api/v1/games/coinflip/play`
```json
{
  "sessionId": "sess_xxx",
  "betAmount": 10,
  "signedAmount": "10",
  "selection": "heads",
  "token": "zhixi",
  "nonce": "<server-issued nonce>",
  "signature": "0x...",
  "publicKey": "0x..."
}
```

Signature message (`ApiService.coinFlipMessage()`, server `dlinker.js:564`) — **5 段**:

```text
coinflip:<nonce>:<selection 小寫>:<signedAmount 字面>:<tokenId>
```

⚠️ **`token` 必須和簽進去的是同一個。** 伺服器是用 `body.token` 組成驗簽訊息的，
所以送 `zhixi` 卻簽 `yjc` 會得到 `SIGNER_MISMATCH` → 401。

`ApiService.coinFlipPayload()` 把 payload 與簽章訊息綁在同一個 `tokenId` 上，
結構上不可能再不一致 —— 這是 2026-10-18 修掉的 bug。

## ★ 簽章的三個坑（照文件寫一定會錯）

| 問題 | 真相 |
|---|---|
| 位元組順序 | web3dart `r‖s‖v`(v∈{27,28})；noble v2 `v‖r‖s`(v∈{0,1,2,3})，**v 在第一個 byte** |
| `.recoverPublicKey()` 回傳 | 是 **Point 不是 bytes**，`.slice()` 會得到 `p.slice is not a function`（要用 `point.toBytes(false)`） |
| `prehash: true` | 是「用 **sha256**」；以太庭要 keccak256，必須 `prehash: false`，verify 也要一起傳 |

`dlinker.js` 沒有使用 `verify()`，而是自寫 `personalHash`
（`keccak_256` + `\x19Ethereum Signed Message:\n` 前綴）。

## ★ 驗證方法（2026-10-18 實測）

不要只讀程式碼就下結論。實際做法：

1. 用 Dart/web3dart 簽出真實的三種訊息（auth / transfer / coinflip）
2. 把簽名交給 `zixi-earth/src/dlinker.js` 裡**真正的** `recoverAddress()` 還原
3. 確認還原出的地址與錢包地址一致
4. 竄改金額（簽 `25.50` 但伺服器要 `25.51`）確認會被偵測

實測結果：三種訊息都是 65 bytes、v ∈ {27,28}，全部還原成功；竄改金額會得到不同地址。

## ★ 這份文件的地位

**以 `ApiService` 的程式碼為準，不要照這份文件改。**

`ApiService` 是簽章訊息的**單一來源**（`authMessage` / `transferMessage` /
`coinFlipMessage` / `coinFlipPayload` 四個方法，全部集中在一處）。

本文件 2026-10-13 初版**沒有寫任何簽章機制**，transfer 訊息寫成 3 段，
實際是 5 段（含 nonce 與 tokenId）—— 照著它改會得到 401。
```

## Market Sim

### Get account snapshot
`GET /api/v1/market/me?sessionId=sess_xxx`

### Market action (deposit/withdraw/trade)
`POST /api/v1/market/action`
```json
{ "type": "bank_deposit", "sessionId": "sess_xxx", "amount": 100 }
```

Actions: `bank_deposit`, `bank_withdraw`, `buy_stock`, `sell_stock`, `borrow`, `repay`, `open_futures`, `close_futures`

## Token IDs

| Token | Symbol | Contract (Base Sepolia) |
|-------|--------|------------------------|
| `zhixi` | ZXC | `0xe3d9af5f15857cb01e0614fa281fcc3256f62050` |
| `yjc` | YJC | `0x82D6aDB17d58820324D86B378775350D03a071AE` |

## Deep Link Protocol

- Login: `dlinker:login:<sessionId>` or `dlinker://login/<sessionId>`
- Coinflip: `dlinker:coinflip:<gameId>:<side>:<amount>`
