class Env {
  Env._();

  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    // 後端網址。
//
// ⚠️ 這裡在 2026-10-13 改過。舊值
//    'https://zixi-casino-api.onrender.com/api/'
// 指向的服務已停用（實測逾時 25 秒），app 的餘額/轉帳/空投全部打不通。
// 現在指向合併後的 zixi-earth（Cloudflare Workers + D1）。
//
// 相容端點由 zixi-earth/src/dlinker.js 提供，規格見
// zixi-wallet-app/device-linker-api-integration.md。
//
// 可用編譯時參數覆寫，不必改程式碼：
//   flutter build apk --dart-define=API_BASE_URL=https://example.com/api/
defaultValue: 'https://twonline.dpdns.org/api/',
  );
}
