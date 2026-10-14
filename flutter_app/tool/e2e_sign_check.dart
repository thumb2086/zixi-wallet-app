// 端到端：Dart（app 的真實簽章路徑）簽 → 線上伺服器驗。
//
// 這是整條鏈路的最後一塊拼圖：
//   Flutter（web3dart 簽）→ 網路 → zixi-earth（@noble 驗）
//
// 之前的測試各自驗一半：
//   · tests/dlinker.test.mjs 用 Node 簽、Node 驗
//   · tool/cmp_sig.dart 確認兩個 web3dart API 位元組相同
// 但**沒有人驗過 Dart 簽的能不能被伺服器接受** —— 而那正是實際會發生的事。
//
// API 用法刻意照抄 app 的 key_service.dart（不要自己猜 web3dart 的 API）。
import 'dart:convert';
import 'dart:io';

import 'package:web3dart/crypto.dart' as web3crypto;
import 'package:web3dart/web3dart.dart';

const base = 'https://twonline.dpdns.org';

Future<String> post(String path, String body) async {
  final c = HttpClient();
  try {
    final req = await c.postUrl(Uri.parse('$base$path'));
    req.headers.contentType = ContentType('application', 'utf-8');
    req.write(body);
    final resp = await req.close();
    return await resp.transform(utf8.decoder).join();
  } finally {
    c.close();
  }
}

Future<void> main() async {
  const privHex = '0x4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318';
  final key = EthPrivateKey.fromHex(privHex);

  // 地址：跟 _normalizeAddress 一樣的正規化（小寫 0x 開頭）
  final address = key.address.hexEip55.toLowerCase();

  // ① 跟線上要 session
  final r0 = jsonDecode(await post('/api/v1/auth/create-session', '{}')) as Map<String, dynamic>;
  final sid = (r0['data'] as Map<String, dynamic>)['sessionId'] as String;

  // ② 用 app 實際的簽章路徑（key_service.dart 的 signData）
  final message = 'dlinker-auth:$sid:${address.substring(2)}';
  final sig = await key.signPersonalMessageToUint8List(utf8.encode(message));
  final sigHex = web3crypto.bytesToHex(sig, include0x: true);

  print('  sessionId : $sid');
  print('  address   : $address');
  print('  message   : $message');
  print('  signature : ${sigHex.substring(0, 34)}…  (${sig.length} bytes)');

  // ③ 送出 authorize
  final raw = await post('/api/user.js', jsonEncode({
    'action': 'authorize',
    'sessionId': sid,
    'address': address,
    'signature': sigHex,
  }));
  final body = jsonDecode(raw) as Map<String, dynamic>;

  print('');
  print('  伺服器回應 : ${raw.length > 200 ? raw.substring(0, 200) : raw}');
  final ok = body['success'] == true;
  print('');
  print(ok
      ? '  ✓ Dart 簽的簽章被伺服器接受 —— 整條鏈路通了'
      : '  ★ 被拒絕：${body['error']}');
  print('  測試地址（測完要刪）: $address');
  exit(ok ? 0 : 1);
}