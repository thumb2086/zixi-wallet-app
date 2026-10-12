require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

/**
 * @type import('hardhat/config').HardhatUserConfig
 *
 * ── 2026-10-13：鏈從 Base Sepolia 改成 Ethereum Sepolia ──
 *
 * 原因：合約地址兩邊本來就相同，但**鏈不同會讓簽出來的交易驗不過**。
 *
 *   這裡（原本）  Base Sepolia  chainId 84532   sepolia.base.org
 *   zixi-earth    Ethereum Sepolia  chainId 11155111   ← 實際在跑的那條
 *
 * 對齊到 Sepolia 的依據來自設定檔，不是記憶：
 * zixi-earth/wrangler.jsonc 的 `CHAIN_ID: "11155111"`。
 * （同一個專案裡三份設定寫了三個不同的鏈，是 AGENTS.md 記過的坑，
 *   所以這裡是讀出來的不是手打的。）
 *
 * 環境變數名也一併改了（BASE_SEPOLIA_RPC_URL → SEPOLIA_RPC_URL）。
 * 留著舊名會讓人以為還在用 Base Sepolia —— 而錯誤的鏈不會報錯，
 * 只會得到一個永遠查不到交易的鏈上環境。
 */
module.exports = {
  solidity: "0.8.20",
  networks: {
    // Ethereum Sepolia（與 zixi-earth 的 CHAIN_ID 11155111 對齊）
    sepolia: {
      url: process.env.SEPOLIA_RPC_URL || "https://rpc.sepolia.org",
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
    },
  },
  // 如果你需要驗證合約
  etherscan: {
    apiKey: {
      sepolia: process.env.SEPOLIASCAN_API_KEY || "",
    },
    customChains: [
      {
        network: "sepolia",
        chainId: 11155111,
        urls: {
          apiURL: "https://api-sepolia.etherscan.io/api",
          browserURL: "https://sepolia.etherscan.io",
        },
      },
    ],
  },
};