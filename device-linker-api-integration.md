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
  "token": "zhixi"
}
```
Signature message: `transfer:<to_without_0x_lowercase>:<amount>`

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
  "selection": "heads",
  "token": "zhixi"
}
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
