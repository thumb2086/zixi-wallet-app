# D-Linker 技術架構（Flutter）

## 1. 身分與金鑰層 (Identity & Key Management)
- **演算法**: `secp256k1`
- **私鑰來源**: App 首次啟動時以安全亂數產生
- **儲存策略**: 優先使用 `flutter_secure_storage`，失敗時回退到本地儲存
- **地址推導**: 由公鑰計算 Keccak-256，取後 20 bytes 形成 EVM 地址

## 2. 應用層 (Flutter App)
- **平台**: Flutter（Android / iOS / Web / Linux / Windows）
- **核心功能**: 錢包地址生成、餘額同步、轉帳、搬家轉移、QR 掃描、深連結授權
- **語系**: 系統語言 / zh-TW / zh-CN / en

## 3. 中繼服務層 (Relay Service)
- **平台**: REST Backend API
  - 原先：Vercel + Node.js（`zixi-casino`）—— ⛔ 已停用，2026-10-13 實測逾時／404
  - **現在：`zixi-earth`（Cloudflare Workers + D1）** —— 已於 2026-10-13 重新打通
    - 相容層：`zixi-earth/src/dlinker.js`
    - 網址：`https://twonline.dpdns.org/api/`（`flutter_app/lib/config/env.dart`）
    - 已實作 9 個端點（auth×2、authorize、summary、transfer、airdrop、
      coinflip、market/me），其中 coinflip 與 market/me 是**委派**給既有的 handler。
      `market/action` 只支援 `bank_deposit` 與 `borrow`，其餘回 501。
- **流程**:
  1. Flutter App 送出簽名請求
  2. 後台驗證授權參數（含 `sessionId`、地址正規化、公鑰長度限制）
  3. 廣播交易到 EVM 測試鏈
  4. 回傳授權/交易狀態給多平台客戶端（Flutter / Web / Desktop）

> **授權與轉帳都必須附簽章。**
> 舊的 `zixi-casino` 兩處都沒驗簽章，等於任何人都能冒用他人的鏈上地址
> 並轉走對方餘額。新實作強制驗簽，且還原出的地址必須等於宣告的地址。

## 4. 區塊鏈層 (Blockchain)
- **Network**: **Ethereum Sepolia（chainId 11155111）**
  - 2026-10-13 從 Base Sepolia（84532）改過，理由是與 `zixi-earth` 的
    `CHAIN_ID: "11155111"` 對齊 —— **合約地址本來就相同，但鏈不同會讓簽出的交易驗不過**
  - 環境變數同步改名：`SEPOLIA_RPC_URL`、`SEPOLIASCAN_API_KEY`
  - 指令：`npx hardhat run scripts/... --network sepolia`
- **Asset**: ERC-20
  - ZHIXI (ZXC) `0xe3d9af5f15857cb01e0614fa281fcc3256f62050`
  - YJC `0x82D6aDB17d58820324D86B378775350D03a071AE`
- **目標**: 透明、可驗證、不可竄改的交易帳本
