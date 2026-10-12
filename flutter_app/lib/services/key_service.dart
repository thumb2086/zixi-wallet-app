import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart' hide Padding, State;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web3dart/crypto.dart' as web3crypto;
import 'package:web3dart/web3dart.dart';

class PinRequiredException implements Exception {
  PinRequiredException([this.message = 'PIN required to unlock private key']);

  final String message;

  @override
  String toString() => message;
}

class PinIncorrectException implements Exception {
  PinIncorrectException([this.message = 'Incorrect PIN']);

  final String message;

  @override
  String toString() => message;
}

class KeyService {
  static const String _privateKeyStorageKey = 'dlinker_private_key_hex_v1';
  static const String _encryptedKeyPrefKey = 'dlinker_encrypted_private_key';
  static const String _encryptedKeySaltPrefKey = 'dlinker_encrypted_salt';
  static const String _encryptedKeyNoncePrefKey = 'dlinker_encrypted_nonce';

  static const int _pbkdf2Iterations = 120000;
  static const int _saltLength = 32;
  static const int _nonceLength = 12;

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  final ECDomainParameters _domain = ECDomainParameters('secp256k1');

  String? _decryptedPrivateKeyHex;
  DateTime? _unlockedAt;
  static const Duration _pinCacheDuration = Duration(minutes: 5);

  bool get isUnlocked =>
      _decryptedPrivateKeyHex != null &&
      _unlockedAt != null &&
      DateTime.now().difference(_unlockedAt!) < _pinCacheDuration;

  void lock() {
    _decryptedPrivateKeyHex = null;
    _unlockedAt = null;
  }

  Future<void> ensureKeyPair({String? pin}) async {
    final existing = await _readPrivateKeyHex(pin: pin);
    if (existing != null && existing.isNotEmpty) return;

    final privateScalar = _generatePrivateScalar();
    final privateHex = privateScalar.toRadixString(16).padLeft(64, '0');
    await _writePrivateKeyHex(privateHex, pin: pin);
  }

  Future<String> getWalletAddress({String? pin}) async {
    final privateKey = await _getPrivateScalar(pin: pin);
    final point = (_domain.G * privateKey)!;
    final x = _bigIntTo32Bytes(point.x!.toBigInteger()!);
    final y = _bigIntTo32Bytes(point.y!.toBigInteger()!);

    final noPrefix = Uint8List.fromList([...x, ...y]);
    final hash = web3crypto.keccak256(noPrefix);
    final addressBytes = Uint8List.fromList(hash.sublist(hash.length - 20));
    final raw = web3crypto.bytesToHex(addressBytes, include0x: true);

    return EthereumAddress.fromHex(raw).hexEip55;
  }

  Future<String> getPublicKeySpkiBase64({String? pin}) async {
    final privateKey = await _getPrivateScalar(pin: pin);
    final point = (_domain.G * privateKey)!;

    final x = _bigIntTo32Bytes(point.x!.toBigInteger()!);
    final y = _bigIntTo32Bytes(point.y!.toBigInteger()!);
    final uncompressed = Uint8List.fromList([0x04, ...x, ...y]);

    final header = Uint8List.fromList([
      0x30,
      0x56,
      0x30,
      0x10,
      0x06,
      0x07,
      0x2A,
      0x86,
      0x48,
      0xCE,
      0x3D,
      0x02,
      0x01,
      0x06,
      0x05,
      0x2B,
      0x81,
      0x04,
      0x00,
      0x0A,
      0x03,
      0x42,
      0x00,
    ]);

    final spki = Uint8List.fromList([...header, ...uncompressed]);
    return base64Encode(spki);
  }

  Future<void> unlockWithPin(String pin) async {
    final hex = await _readEncryptedFromPrefs(pin);
    if (hex == null) {
      throw PinIncorrectException();
    }
    _decryptedPrivateKeyHex = hex;
    _unlockedAt = DateTime.now();
  }

  Future<String> signData(String data, {String? pin}) async {
    final hex = await _getPrivateKeyHex(pin: pin);
    final ethPrivateKey = EthPrivateKey.fromHex(hex);
    // 2026-10-13：從 signPersonalMessage 換成 signPersonalMessageToUint8List。
    // 前者在 web3dart 2.7.3 已標記 deprecated，而 flutter analyze 擋 CI。
    //
    // ★ 換之前有實測確認兩者產生的位元組**完全相同**
    //   （見 tool/cmp_sig.dart：65 bytes、r‖s‖v、v∈{27,28}，逐位元組相同）。
    //   伺服器端（zixi-earth/src/dlinker.js）的驗證是照這個格式寫的，
    //   所以這不是「順手 modernize」—— 是動到安全驗證的基礎，
    //   沒有證明就不能換。
    final sigBytes = await ethPrivateKey.signPersonalMessageToUint8List(utf8.encode(data));
    return web3crypto.bytesToHex(sigBytes, include0x: true);
  }

  Future<String> _getPrivateKeyHex({String? pin}) async {
    await ensureKeyPair(pin: pin);
    final hex = await _readPrivateKeyHex(pin: pin);
    if (hex == null || hex.isEmpty) {
      throw Exception('Missing private key');
    }
    return hex;
  }

  Future<BigInt> _getPrivateScalar({String? pin}) async {
    await ensureKeyPair(pin: pin);
    final hex = await _readPrivateKeyHex(pin: pin);
    if (hex == null || hex.isEmpty) {
      throw Exception('Missing private key');
    }
    return BigInt.parse(hex, radix: 16);
  }

  BigInt _generatePrivateScalar() {
    final random = Random.secure();

    while (true) {
      final bytes = Uint8List(32);
      for (var i = 0; i < bytes.length; i++) {
        bytes[i] = random.nextInt(256);
      }
      final value = _bytesToBigInt(bytes);
      if (value > BigInt.zero && value < _domain.n) {
        return value;
      }
    }
  }

  Future<String?> _readPrivateKeyHex({String? pin}) async {
    if (isUnlocked) return _decryptedPrivateKeyHex;

    try {
      final fromSecure = await _secureStorage.read(key: _privateKeyStorageKey);
      if (fromSecure != null && fromSecure.isNotEmpty) {
        return fromSecure;
      }
    } catch (_) {
      // Secure storage unavailable, fall through to PIN-based decryption
    }

    if (pin != null) {
      final fromEncrypted = await _readEncryptedFromPrefs(pin);
      if (fromEncrypted != null) {
        _decryptedPrivateKeyHex = fromEncrypted;
        _unlockedAt = DateTime.now();
        return fromEncrypted;
      }
    }

    final hasEncrypted = await _hasEncryptedInPrefs();
    if (hasEncrypted) {
      if (pin == null) throw PinRequiredException();
      throw PinIncorrectException();
    }

    return null;
  }

  Future<bool> _hasEncryptedInPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final cipher = prefs.getString(_encryptedKeyPrefKey);
    return cipher != null && cipher.isNotEmpty;
  }

  Future<String?> _readEncryptedFromPrefs(String pin) async {
    final prefs = await SharedPreferences.getInstance();
    final cipherB64 = prefs.getString(_encryptedKeyPrefKey);
    final saltB64 = prefs.getString(_encryptedKeySaltPrefKey);
    final nonceB64 = prefs.getString(_encryptedKeyNoncePrefKey);

    if (cipherB64 == null || saltB64 == null || nonceB64 == null) return null;

    try {
      final salt = base64Decode(saltB64);
      final nonce = base64Decode(nonceB64);
      final ciphertext = base64Decode(cipherB64);

      final key = _deriveKey(pin, salt);
      final decrypted = _aesGcmDecrypt(ciphertext, key, nonce);
      return utf8.decode(decrypted);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writePrivateKeyHex(String value, {String? pin}) async {
    try {
      await _secureStorage.write(key: _privateKeyStorageKey, value: value);
      return;
    } catch (_) {
      // Secure storage unavailable
    }

    if (pin == null) {
      throw PinRequiredException();
    }

    await _writeEncryptedToPrefs(value, pin);
  }

  Future<void> _writeEncryptedToPrefs(String hex, String pin) async {
    final random = Random.secure();
    final salt = Uint8List(_saltLength);
    for (var i = 0; i < _saltLength; i++) {
      salt[i] = random.nextInt(256);
    }

    final nonce = Uint8List(_nonceLength);
    for (var i = 0; i < _nonceLength; i++) {
      nonce[i] = random.nextInt(256);
    }

    final key = _deriveKey(pin, salt);
    final plaintext = utf8.encode(hex);
    final ciphertext = _aesGcmEncrypt(Uint8List.fromList(plaintext), key, nonce);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_encryptedKeyPrefKey, base64Encode(ciphertext));
    await prefs.setString(_encryptedKeySaltPrefKey, base64Encode(salt));
    await prefs.setString(_encryptedKeyNoncePrefKey, base64Encode(nonce));
  }

  Uint8List _deriveKey(String pin, Uint8List salt) {
    final password = Uint8List.fromList(utf8.encode(pin));
    final hmac = HMac(SHA256Digest(), 64);
    final block1 = _pbkdf2Block(hmac, password, salt, _pbkdf2Iterations, 1);
    return Uint8List.fromList(block1.sublist(0, 32));
  }

  Uint8List _pbkdf2Block(HMac hmac, Uint8List password, Uint8List salt, int iterations, int blockIndex) {
    final block = _int32Bytes(blockIndex);

    Uint8List u = Uint8List(salt.length + block.length);
    u.setRange(0, salt.length, salt);
    u.setRange(salt.length, u.length, block);

    hmac.init(KeyParameter(password));
    u = _hmacDigest(hmac, u);
    Uint8List result = Uint8List.fromList(u);

    for (var i = 1; i < iterations; i++) {
      hmac.init(KeyParameter(password));
      u = _hmacDigest(hmac, u);
      for (var j = 0; j < result.length; j++) {
        result[j] ^= u[j];
      }
    }

    return result;
  }

  Uint8List _hmacDigest(HMac hmac, Uint8List data) {
    hmac.update(data, 0, data.length);
    final out = Uint8List(hmac.macSize);
    hmac.doFinal(out, 0);
    return out;
  }

  Uint8List _int32Bytes(int value) {
    return Uint8List.fromList([
      (value >> 24) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    ]);
  }

  Uint8List _aesGcmEncrypt(Uint8List plaintext, Uint8List key, Uint8List nonce) {
    final cipher = GCMBlockCipher(AESEngine());
    cipher.init(
      true,
      AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)),
    );

    final output = Uint8List(cipher.getOutputSize(plaintext.length));
    final len1 = cipher.processBytes(plaintext, 0, plaintext.length, output, 0);
    cipher.doFinal(output, len1);
    return output;
  }

  Uint8List _aesGcmDecrypt(Uint8List ciphertext, Uint8List key, Uint8List nonce) {
    final cipher = GCMBlockCipher(AESEngine());
    cipher.init(
      false,
      AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)),
    );

    final output = Uint8List(cipher.getOutputSize(ciphertext.length));
    final len1 = cipher.processBytes(ciphertext, 0, ciphertext.length, output, 0);
    cipher.doFinal(output, len1);
    return output;
  }

  Uint8List _bigIntTo32Bytes(BigInt value) {
    final bytes = _bigIntToBytes(value);
    if (bytes.length == 32) return bytes;
    if (bytes.length > 32) {
      return Uint8List.fromList(bytes.sublist(bytes.length - 32));
    }
    return Uint8List.fromList(List<int>.filled(32 - bytes.length, 0) + bytes);
  }

  Uint8List _bigIntToBytes(BigInt number) {
    final hex = number.toRadixString(16);
    final padded = hex.length.isOdd ? '0$hex' : hex;
    final result = Uint8List(padded.length ~/ 2);
    for (var i = 0; i < result.length; i++) {
      final start = i * 2;
      result[i] = int.parse(padded.substring(start, start + 2), radix: 16);
    }
    return result;
  }

  BigInt _bytesToBigInt(Uint8List bytes) {
    var result = BigInt.zero;
    for (final b in bytes) {
      result = (result << 8) | BigInt.from(b);
    }
    return result;
  }

}
