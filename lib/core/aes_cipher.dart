import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Pure-Dart FIPS-197 AES-128 / AES-192 / AES-256 block cipher, CBC-PKCS#7,
/// CTR stream transform, and RFC 2898 PBKDF2-HMAC-SHA1 key derivation.
final class AesBlockCipher {
  factory AesBlockCipher(Uint8List key) {
    final int nk;
    final int nr;
    switch (key.length) {
      case 16:
        nk = 4;
        nr = 10;
      case 24:
        nk = 6;
        nr = 12;
      case 32:
        nk = 8;
        nr = 14;
      default:
        throw ArgumentError.value(
          key.length,
          'key.length',
          'AES key length must be 16, 24, or 32 bytes',
        );
    }
    return AesBlockCipher._(nr, _expandKey(key, nk, nr));
  }

  const AesBlockCipher._(this._rounds, this._roundKeys);

  static const int blockSize = 16;

  final int _rounds;
  final Uint8List _roundKeys;

  /// Encrypts one 16-byte block from [input] starting at [inputOffset].
  Uint8List encryptBlock(
    Uint8List input, [
    int inputOffset = 0,
    Uint8List? output,
    int outputOffset = 0,
  ]) {
    RangeError.checkValidRange(
      inputOffset,
      inputOffset + blockSize,
      input.length,
    );
    final out = output ?? Uint8List(blockSize);
    RangeError.checkValidRange(
      outputOffset,
      outputOffset + blockSize,
      out.length,
    );

    final s = Uint8List(blockSize);
    for (var i = 0; i < blockSize; i++) {
      s[i] = input[inputOffset + i] ^ _roundKeys[i];
    }

    for (var round = 1; round < _rounds; round++) {
      _subBytes(s);
      _shiftRows(s);
      _mixColumns(s);
      _addRoundKey(s, round * blockSize);
    }

    _subBytes(s);
    _shiftRows(s);
    _addRoundKey(s, _rounds * blockSize);

    for (var i = 0; i < blockSize; i++) {
      out[outputOffset + i] = s[i];
    }
    return out;
  }

  /// Decrypts one 16-byte block from [input] starting at [inputOffset].
  Uint8List decryptBlock(
    Uint8List input, [
    int inputOffset = 0,
    Uint8List? output,
    int outputOffset = 0,
  ]) {
    RangeError.checkValidRange(
      inputOffset,
      inputOffset + blockSize,
      input.length,
    );
    final out = output ?? Uint8List(blockSize);
    RangeError.checkValidRange(
      outputOffset,
      outputOffset + blockSize,
      out.length,
    );

    final s = Uint8List(blockSize);
    final lastKeyOffset = _rounds * blockSize;
    for (var i = 0; i < blockSize; i++) {
      s[i] = input[inputOffset + i] ^ _roundKeys[lastKeyOffset + i];
    }

    for (var round = _rounds - 1; round >= 1; round--) {
      _invShiftRows(s);
      _invSubBytes(s);
      _addRoundKey(s, round * blockSize);
      _invMixColumns(s);
    }

    _invShiftRows(s);
    _invSubBytes(s);
    _addRoundKey(s, 0);

    for (var i = 0; i < blockSize; i++) {
      out[outputOffset + i] = s[i];
    }
    return out;
  }

  void _addRoundKey(Uint8List s, int keyOffset) {
    for (var i = 0; i < blockSize; i++) {
      s[i] ^= _roundKeys[keyOffset + i];
    }
  }

  static void _subBytes(Uint8List s) {
    for (var i = 0; i < blockSize; i++) {
      s[i] = _sbox[s[i]];
    }
  }

  static void _invSubBytes(Uint8List s) {
    for (var i = 0; i < blockSize; i++) {
      s[i] = _invSbox[s[i]];
    }
  }

  static void _shiftRows(Uint8List s) {
    // Row 1: left shift by 1
    final t1 = s[1];
    s[1] = s[5];
    s[5] = s[9];
    s[9] = s[13];
    s[13] = t1;

    // Row 2: left shift by 2
    final t2a = s[2];
    final t2b = s[6];
    s[2] = s[10];
    s[6] = s[14];
    s[10] = t2a;
    s[14] = t2b;

    // Row 3: left shift by 3 (== right shift by 1)
    final t3 = s[15];
    s[15] = s[11];
    s[11] = s[7];
    s[7] = s[3];
    s[3] = t3;
  }

  static void _invShiftRows(Uint8List s) {
    // Row 1: right shift by 1
    final t1 = s[13];
    s[13] = s[9];
    s[9] = s[5];
    s[5] = s[1];
    s[1] = t1;

    // Row 2: right shift by 2
    final t2a = s[2];
    final t2b = s[6];
    s[2] = s[10];
    s[6] = s[14];
    s[10] = t2a;
    s[14] = t2b;

    // Row 3: right shift by 3 (== left shift by 1)
    final t3 = s[3];
    s[3] = s[7];
    s[7] = s[11];
    s[11] = s[15];
    s[15] = t3;
  }

  static int _xtime(int x) => ((x << 1) ^ (((x >> 7) & 1) * 0x1b)) & 0xff;

  static int _gfMul(int a, int b) {
    var p = 0;
    var aa = a & 0xff;
    var bb = b & 0xff;
    for (var i = 0; i < 8; i++) {
      if ((bb & 1) != 0) p ^= aa;
      aa = _xtime(aa);
      bb >>= 1;
    }
    return p & 0xff;
  }

  static void _mixColumns(Uint8List s) {
    for (var c = 0; c < 16; c += 4) {
      final a0 = s[c];
      final a1 = s[c + 1];
      final a2 = s[c + 2];
      final a3 = s[c + 3];
      final t = a0 ^ a1 ^ a2 ^ a3;
      s[c] = a0 ^ t ^ _xtime(a0 ^ a1);
      s[c + 1] = a1 ^ t ^ _xtime(a1 ^ a2);
      s[c + 2] = a2 ^ t ^ _xtime(a2 ^ a3);
      s[c + 3] = a3 ^ t ^ _xtime(a3 ^ a0);
    }
  }

  static void _invMixColumns(Uint8List s) {
    for (var c = 0; c < 16; c += 4) {
      final a0 = s[c];
      final a1 = s[c + 1];
      final a2 = s[c + 2];
      final a3 = s[c + 3];
      s[c] =
          _gfMul(a0, 0x0e) ^
          _gfMul(a1, 0x0b) ^
          _gfMul(a2, 0x0d) ^
          _gfMul(a3, 0x09);
      s[c + 1] =
          _gfMul(a0, 0x09) ^
          _gfMul(a1, 0x0e) ^
          _gfMul(a2, 0x0b) ^
          _gfMul(a3, 0x0d);
      s[c + 2] =
          _gfMul(a0, 0x0d) ^
          _gfMul(a1, 0x09) ^
          _gfMul(a2, 0x0e) ^
          _gfMul(a3, 0x0b);
      s[c + 3] =
          _gfMul(a0, 0x0b) ^
          _gfMul(a1, 0x0d) ^
          _gfMul(a2, 0x09) ^
          _gfMul(a3, 0x0e);
    }
  }

  static Uint8List _expandKey(Uint8List key, int nk, int nr) {
    final totalWords = 4 * (nr + 1);
    final w = Uint8List(totalWords * 4);
    w.setRange(0, key.length, key);

    for (var i = nk; i < totalWords; i++) {
      final prevOff = (i - 1) * 4;
      var t0 = w[prevOff];
      var t1 = w[prevOff + 1];
      var t2 = w[prevOff + 2];
      var t3 = w[prevOff + 3];

      if (i % nk == 0) {
        final rot0 = t1;
        final rot1 = t2;
        final rot2 = t3;
        final rot3 = t0;
        t0 = _sbox[rot0] ^ _rcon[i ~/ nk];
        t1 = _sbox[rot1];
        t2 = _sbox[rot2];
        t3 = _sbox[rot3];
      } else if (nk > 6 && i % nk == 4) {
        t0 = _sbox[t0];
        t1 = _sbox[t1];
        t2 = _sbox[t2];
        t3 = _sbox[t3];
      }

      final baseOff = (i - nk) * 4;
      final dstOff = i * 4;
      w[dstOff] = w[baseOff] ^ t0;
      w[dstOff + 1] = w[baseOff + 1] ^ t1;
      w[dstOff + 2] = w[baseOff + 2] ^ t2;
      w[dstOff + 3] = w[baseOff + 3] ^ t3;
    }
    return w;
  }

  static const List<int> _rcon = <int>[
    0x00,
    0x01,
    0x02,
    0x04,
    0x08,
    0x10,
    0x20,
    0x40,
    0x80,
    0x1b,
    0x36,
  ];

  static const List<int> _sbox = <int>[
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b,
    0xfe, 0xd7, 0xab, 0x76, //
    0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf,
    0x9c, 0xa4, 0x72, 0xc0, //
    0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1,
    0x71, 0xd8, 0x31, 0x15, //
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2,
    0xeb, 0x27, 0xb2, 0x75, //
    0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3,
    0x29, 0xe3, 0x2f, 0x84, //
    0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39,
    0x4a, 0x4c, 0x58, 0xcf, //
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f,
    0x50, 0x3c, 0x9f, 0xa8, //
    0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21,
    0x10, 0xff, 0xf3, 0xd2, //
    0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d,
    0x64, 0x5d, 0x19, 0x73, //
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14,
    0xde, 0x5e, 0x0b, 0xdb, //
    0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62,
    0x91, 0x95, 0xe4, 0x79, //
    0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea,
    0x65, 0x7a, 0xae, 0x08, //
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f,
    0x4b, 0xbd, 0x8b, 0x8a, //
    0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9,
    0x86, 0xc1, 0x1d, 0x9e, //
    0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9,
    0xce, 0x55, 0x28, 0xdf, //
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f,
    0xb0, 0x54, 0xbb, 0x16, //
  ];

  static final Uint8List _invSbox = () {
    final inv = Uint8List(256);
    for (var i = 0; i < 256; i++) {
      inv[_sbox[i]] = i;
    }
    return inv;
  }();
}

/// Encrypts [plaintext] using AES-CBC with PKCS#7 (PKCS#5) padding.
Uint8List aesCbcEncryptPkcs7({
  required Uint8List key,
  required Uint8List iv,
  required Uint8List plaintext,
}) {
  if (iv.length != AesBlockCipher.blockSize) {
    throw ArgumentError.value(
      iv.length,
      'iv.length',
      'AES IV must be 16 bytes',
    );
  }
  final cipher = AesBlockCipher(key);
  final padLen =
      AesBlockCipher.blockSize - (plaintext.length % AesBlockCipher.blockSize);
  final totalLen = plaintext.length + padLen;
  final padded = Uint8List(totalLen);
  padded.setRange(0, plaintext.length, plaintext);
  padded.fillRange(plaintext.length, totalLen, padLen);

  final out = Uint8List(totalLen);
  final block = Uint8List(AesBlockCipher.blockSize);
  var prev = iv;
  var prevOffset = 0;

  for (var offset = 0; offset < totalLen; offset += AesBlockCipher.blockSize) {
    for (var i = 0; i < AesBlockCipher.blockSize; i++) {
      block[i] = padded[offset + i] ^ prev[prevOffset + i];
    }
    cipher.encryptBlock(block, 0, out, offset);
    prev = out;
    prevOffset = offset;
  }
  return out;
}

/// Decrypts [ciphertext] using AES-CBC and strips/validates PKCS#7 padding.
///
/// Throws [FormatException] when [ciphertext] is empty, not a multiple of
/// 16 bytes, or fails PKCS#7 padding validation.
Uint8List aesCbcDecryptPkcs7({
  required Uint8List key,
  required Uint8List iv,
  required Uint8List ciphertext,
}) {
  if (iv.length != AesBlockCipher.blockSize) {
    throw ArgumentError.value(
      iv.length,
      'iv.length',
      'AES IV must be 16 bytes',
    );
  }
  if (ciphertext.isEmpty || ciphertext.length % AesBlockCipher.blockSize != 0) {
    throw const FormatException(
      'AES-CBC ciphertext must be a non-empty multiple of 16 bytes',
    );
  }

  final cipher = AesBlockCipher(key);
  final plain = Uint8List(ciphertext.length);
  final decryptedBlock = Uint8List(AesBlockCipher.blockSize);
  var prev = iv;
  var prevOffset = 0;

  for (
    var offset = 0;
    offset < ciphertext.length;
    offset += AesBlockCipher.blockSize
  ) {
    cipher.decryptBlock(ciphertext, offset, decryptedBlock, 0);
    for (var i = 0; i < AesBlockCipher.blockSize; i++) {
      plain[offset + i] = decryptedBlock[i] ^ prev[prevOffset + i];
    }
    prev = ciphertext;
    prevOffset = offset;
  }

  final padLen = plain[plain.length - 1];
  if (padLen < 1 ||
      padLen > AesBlockCipher.blockSize ||
      padLen > plain.length) {
    throw const FormatException('Invalid PKCS#7 padding length');
  }
  var diff = 0;
  for (var i = plain.length - padLen; i < plain.length; i++) {
    diff |= plain[i] ^ padLen;
  }
  if (diff != 0) {
    throw const FormatException('Invalid PKCS#7 padding bytes');
  }
  return Uint8List.fromList(plain.sublist(0, plain.length - padLen));
}

/// Applies AES-CTR keystream XOR to [input] (symmetric for encrypt & decrypt).
///
/// - When [iv] is provided (16 bytes), starts from [iv] and increments the
///   counter in big-endian order by default (NIST SP 800-38A) or little-endian
///   order when [littleEndianCounter] is `true`.
/// - When [iv] is omitted, initializes a 16-byte counter block with
///   [initialCounter] (default `1` for WinZip AE-1/AE-2) in little-endian
///   order when [littleEndianCounter] is `true`, or big-endian otherwise.
Uint8List aesCtrTransform({
  required Uint8List key,
  required Uint8List input,
  Uint8List? iv,
  int initialCounter = 1,
  bool littleEndianCounter = false,
}) {
  final cipher = AesBlockCipher(key);
  final counterBlock = Uint8List(AesBlockCipher.blockSize);
  if (iv != null) {
    if (iv.length != AesBlockCipher.blockSize) {
      throw ArgumentError.value(
        iv.length,
        'iv.length',
        'AES-CTR counter block must be 16 bytes',
      );
    }
    counterBlock.setRange(0, AesBlockCipher.blockSize, iv);
  } else {
    var c = initialCounter;
    if (littleEndianCounter) {
      for (var i = 0; i < 8 && c != 0; i++) {
        counterBlock[i] = c & 0xff;
        c >>>= 8;
      }
    } else {
      for (var i = 15; i >= 8 && c != 0; i--) {
        counterBlock[i] = c & 0xff;
        c >>>= 8;
      }
    }
  }

  final out = Uint8List(input.length);
  final keystream = Uint8List(AesBlockCipher.blockSize);

  for (
    var offset = 0;
    offset < input.length;
    offset += AesBlockCipher.blockSize
  ) {
    cipher.encryptBlock(counterBlock, 0, keystream, 0);
    final chunkEnd = offset + AesBlockCipher.blockSize <= input.length
        ? offset + AesBlockCipher.blockSize
        : input.length;
    for (var i = offset; i < chunkEnd; i++) {
      out[i] = input[i] ^ keystream[i - offset];
    }
    if (littleEndianCounter) {
      _incrementLittleEndian(counterBlock);
    } else {
      _incrementBigEndian(counterBlock);
    }
  }
  return out;
}

void _incrementBigEndian(Uint8List counter) {
  for (var i = counter.length - 1; i >= 0; i--) {
    final next = (counter[i] + 1) & 0xff;
    counter[i] = next;
    if (next != 0) break;
  }
}

void _incrementLittleEndian(Uint8List counter) {
  for (var i = 0; i < counter.length; i++) {
    final next = (counter[i] + 1) & 0xff;
    counter[i] = next;
    if (next != 0) break;
  }
}

/// Derives [derivedKeyLength] bytes using RFC 2898 PBKDF2-HMAC-SHA1.
Uint8List pbkdf2HmacSha1({
  required List<int> password,
  required List<int> salt,
  required int iterations,
  required int derivedKeyLength,
}) {
  if (iterations < 1) {
    throw ArgumentError.value(iterations, 'iterations', 'Must be >= 1');
  }
  if (derivedKeyLength < 1) {
    throw ArgumentError.value(
      derivedKeyLength,
      'derivedKeyLength',
      'Must be >= 1',
    );
  }

  const hashLen = 20; // SHA-1 digest size in bytes
  final hmac = Hmac(sha1, password);
  final blockCount = (derivedKeyLength + hashLen - 1) ~/ hashLen;
  final derived = Uint8List(derivedKeyLength);
  final saltPlusIndex = Uint8List(salt.length + 4);
  saltPlusIndex.setRange(0, salt.length, salt);

  var outOffset = 0;
  for (var blockIndex = 1; blockIndex <= blockCount; blockIndex++) {
    saltPlusIndex[salt.length] = (blockIndex >>> 24) & 0xff;
    saltPlusIndex[salt.length + 1] = (blockIndex >>> 16) & 0xff;
    saltPlusIndex[salt.length + 2] = (blockIndex >>> 8) & 0xff;
    saltPlusIndex[salt.length + 3] = blockIndex & 0xff;

    var u = Uint8List.fromList(hmac.convert(saltPlusIndex).bytes);
    final t = Uint8List.fromList(u);

    for (var iter = 1; iter < iterations; iter++) {
      u = Uint8List.fromList(hmac.convert(u).bytes);
      for (var j = 0; j < hashLen; j++) {
        t[j] ^= u[j];
      }
    }

    final copyLen = outOffset + hashLen <= derivedKeyLength
        ? hashLen
        : derivedKeyLength - outOffset;
    derived.setRange(outOffset, outOffset + copyLen, t);
    outOffset += copyLen;
  }
  return derived;
}
