// 比較 web3dart 的 signPersonalMessage（棄用）與 signPersonalMessageToUint8List
// 產生的位元組是否相同。
//
// 為什麼要測：伺服器端（zixi-earth/src/dlinker.js）的驗證是照著
// signPersonalMessage 的實際輸出建起來的，而且線上實測通過。
// 如果換成新 API 產生的位元組不同，伺服器驗證會整個失效 ——
// 而症狀是 SIGNER_MISMATCH，很難聯想到是換函式造成的。
//
// ⚠️ 兩個方法都是 **async**（回 Future<Uint8List>），一定要 await。
import 'dart:convert';
import 'dart:typed_data';
import 'package:web3dart/web3dart.dart';

Future<void> main() async {
  // 固定的測試私鑰（只在測試用，不要拿去做任何其他事）
  const privHex = '0x4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318';
  final key = EthPrivateKey.fromHex(privHex);

  final msg = utf8.encode('dlinker-auth:sess_abc:4c0883a69102937d6231471b5dbb6204fe5129617');

  // 這裡刻意呼叫棄用的 API —— 目的就是要確認它和新 API 產生的位元組相同。
  // ignore: deprecated_member_use
  final old = await key.signPersonalMessage(msg);
  final neu = await key.signPersonalMessageToUint8List(msg);

  print('  signPersonalMessage            → ${old.length} bytes  ${_hex(old).substring(0, 26)}…');
  print('  signPersonalMessageToUint8List → ${neu.length} bytes  ${_hex(neu).substring(0, 26)}…');
  print('');
  print('  位元組完全相同？ ${_hex(old) == _hex(neu)}');

  if (_hex(old) != _hex(neu)) {
    print('');
    print('  ⚠️ 不同！差異：');
    final n = old.length < neu.length ? old.length : neu.length;
    for (var i = 0; i < n; i++) {
      if (old[i] != neu[i]) {
        print('     第 $i byte: old=${old[i]} neu=${neu[i]}');
      }
    }
    print('  舊長度 ${old.length}，新長度 ${neu.length}');
  }

  // 伺服器端期望的格式：65 bytes，最後一 byte 是 recovery id（27/28）
  print('');
  print('  ── 伺服器端需要的格式檢查 ──');
  for (final e in {'舊': old, '新': neu}.entries) {
    final ok = e.value.length == 65 && (e.value[64] == 27 || e.value[64] == 28);
    print('  ${e.key}：65 bytes 且 v∈{27,28} → ${ok ? "✓" : "✗ (長度 ${e.value.length}, v=${e.value.length > 64 ? e.value[64] : "無"})"}');
  }
}

String _hex(Uint8List b) =>
    '0x' + b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();