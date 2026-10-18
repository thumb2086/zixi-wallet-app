import 'package:device_linker_flutter/services/api_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// 規格來源（唯一權威）：zixi-earth/src/dlinker.js
///   auth    : dlinker-auth:<sessionId>:<address 去掉 0x，小寫>
///   transfer: transfer:<nonce>:<to 去掉 0x>:<amount 字面>:<tokenId 小寫>
///   coinflip: coinflip:<nonce>:<selection 小寫>:<signedAmount 字面>:<tokenId 小寫>
///
/// 伺服器用收到的欄位組出訊息後才驗簽。
/// App 端簽的字串若與伺服器組的不一致 → 401 INVALID_SIGNATURE（使用者完全無法下注）。
void main() {
  final api = ApiService();

  // ⚠️ 這必須是**合法 EIP-55 checksum** 的地址。
  //   web3dart 的 EthereumAddress.fromHex 會驗 checksum，混合大小寫寫錯
  //   會直接丟「Invalid address format」—— 那會讓本檔案測的是
  //   「web3dart 會不會拒絕」，而不是「訊息格式對不對」。
  //   （0xAbC…001 的正確 checksum 是 0xABC…001。）
  const addr = '0xABC0000000000000000000000000000000000001';
  const addrLowerNo0x = 'abc0000000000000000000000000000000000001';

  group('authMessage（dlinker.js:351）', () {
    test('去掉 0x 並轉小寫', () {
      expect(api.authMessage('sid-12345678', addr),
          'dlinker-auth:sid-12345678:$addrLowerNo0x');
    });

    test('本來就小寫的地址不會被改壞', () {
      expect(api.authMessage('sid-12345678', addr.toLowerCase()),
          'dlinker-auth:sid-12345678:$addrLowerNo0x');
    });
  });

  group('transferMessage（dlinker.js:450）', () {
    test('nonce 進第二段，tokenId 進第五段', () {
      expect(
        api.transferMessage(
          nonce: 'N1',
          to: addr,
          amount: '25',
          tokenId: 'zhixi',
        ),
        'transfer:N1:$addrLowerNo0x:25:zhixi',
      );
    });

    test('tokenId 大寫會被正規化，與伺服器 body.token 一致', () {
      expect(
        api.transferMessage(
          nonce: 'N1',
          to: addr,
          amount: '25',
          tokenId: 'YJC',
        ),
        'transfer:N1:$addrLowerNo0x:25:yjc',
      );
    });
  });

  group('coinFlipMessage（dlinker.js:564）', () {
    test('selection 轉小寫（伺服器用 body.selection.toLowerCase()）', () {
      expect(
        api.coinFlipMessage(
          nonce: 'N1',
          selection: 'Heads',
          amount: '10',
          tokenId: 'zhixi',
        ),
        'coinflip:N1:heads:10:zhixi',
      );
    });
  });

  // 這是本次修掉的真實 bug：signData 簽的是 _selectedToken.id，
  // 但送出去的 body.token 寫死 'zhixi'。選 YJC 下注 → 簽章對不上 → 401。
  group('coinFlipPayload 的 token 必須與簽章訊息一致', () {
    test('選 YJC 時，payload.token 與訊息尾段都是 yjc', () {
      const tokenId = 'YJC';
      final payload = api.coinFlipPayload(
        sessionId: 'sid-12345678',
        selection: 'Heads',
        amount: '10',
        signature: '0xdeadbeef',
        publicKey: 'AAAA',
        nonce: 'N1',
        tokenId: tokenId,
      );
      final message = api.coinFlipMessage(
        nonce: 'N1',
        selection: 'Heads',
        amount: '10',
        tokenId: tokenId,
      );

      expect(payload['token'], 'yjc');
      expect(message.endsWith(':yjc'), isTrue,
          reason: '伺服器用 body.token 組訊息，簽章必須用同一個 token');
    });

    test('signedAmount 原樣帶上（不可被 double 轉型改寫）', () {
      final payload = api.coinFlipPayload(
        sessionId: 'sid-12345678',
        selection: 'tails',
        amount: '25.50',
        signature: '0xdeadbeef',
        publicKey: 'AAAA',
        nonce: 'N1',
        tokenId: 'zhixi',
      );
      expect(payload['signedAmount'], '25.50');
      expect(payload['selection'], 'tails');
      expect(payload['betAmount'], 25.5);
    });
  });
}