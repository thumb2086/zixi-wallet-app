# Device-Linker API Integration

> 此 API 由 [zixi-casino](https://github.com/thumb2086/zixi-casino) 的 `apps/api/` 提供。
> Base URL: `https://zixi-casino.vercel.app/api/`

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
