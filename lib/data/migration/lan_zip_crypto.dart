import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../core/failure.dart';

/// SQLite 3 file header magic (`"SQLite format 3\x00"`, 16 bytes).
const List<int> sqlite3HeaderMagic = <int>[
  0x53, 0x51, 0x4c, 0x69, 0x74, 0x65, 0x20, 0x66, // "SQLite f"
  0x6f, 0x72, 0x6d, 0x61, 0x74, 0x20, 0x33, 0x00, // "ormat 3\0"
];

/// Outcome of extracting a SQLite `.db` payload from a LAN `.zip` or bare `.db`.
sealed class LanExtractionResult {
  const LanExtractionResult();
}

/// Successfully extracted a valid SQLite 3 database byte buffer.
final class LanExtractionSuccess extends LanExtractionResult {
  const LanExtractionSuccess({
    required this.dbBytes,
    required this.entryName,
    required this.wasEncrypted,
  });

  final Uint8List dbBytes;
  final String entryName;
  final bool wasEncrypted;
}

/// Encrypted archive detected and no password was supplied yet.
final class LanExtractionPasswordRequired extends LanExtractionResult {
  const LanExtractionPasswordRequired({required this.entryName});

  final String entryName;
}

/// Encrypted archive rejected the supplied password (2-byte verifier or 10-byte HMAC-SHA1-80 failed).
final class LanExtractionWrongPassword extends LanExtractionResult {
  const LanExtractionWrongPassword({
    required this.entryName,
    required this.verifierMatched,
  });

  final String entryName;

  /// `false` when the fast 2-byte password verifier rejected the password;
  /// `true` when the 2-byte verifier matched (or collided) and the 10-byte
  /// `HMAC-SHA1-80` authentication tag rejected tampered/wrong ciphertext.
  final bool verifierMatched;
}

/// Checks whether [bytes] begins with the 16-byte `"SQLite format 3\x00"` header.
bool hasSqlite3Magic(Uint8List bytes) {
  if (bytes.length < sqlite3HeaderMagic.length) return false;
  for (var i = 0; i < sqlite3HeaderMagic.length; i++) {
    if (bytes[i] != sqlite3HeaderMagic[i]) return false;
  }
  return true;
}

/// Extracts the target SQLite database from either a bare `.db` file or a
/// LAN `ServerBackup.zip` archive (supporting plain STORED/DEFLATE, Zip4j
/// WinZip AE-1/AE-2 `AES-128/192/256-CTR` + `PBKDF2-HMAC-SHA1` + `HMAC-SHA1-80`,
/// and legacy ZipCrypto).
LanExtractionResult extractLanSqliteBytes({
  required Uint8List bytes,
  String fileName = 'ServerBackup.zip',
  String? password,
}) {
  if (bytes.isEmpty) {
    throw const Failure(FailureCode.validation, '备份文件为空，无法恢复');
  }

  // 1. Bare SQLite `.db` file
  if (hasSqlite3Magic(bytes)) {
    return LanExtractionSuccess(
      dbBytes: bytes,
      entryName: fileName,
      wasEncrypted: false,
    );
  }

  // 2. Must be a ZIP archive
  if (bytes.length < 22 ||
      bytes[0] != 0x50 ||
      bytes[1] != 0x4b ||
      (bytes[2] != 0x03 && bytes[2] != 0x05)) {
    throw const Failure(
      FailureCode.corruptData,
      '无法识别备份文件格式，请选择局域网 .zip 备份包或 .db 数据库文件',
    );
  }

  final entries = _parseCentralDirectory(bytes);
  final target = _selectSqliteEntry(entries);
  if (target == null) {
    throw const Failure(FailureCode.corruptData, '备份压缩包内未找到 SQLite 数据库文件');
  }

  return _extractZipEntry(bytes, target, password: password);
}

// ============================================================================
// ZIP Central Directory & Entry Extraction (WinZip AE-1 / AE-2 + Plain + ZipCrypto)
// ============================================================================

const int _sigLocalFileHeader = 0x04034b50;
const int _sigCentralDirHeader = 0x02014b50;
const int _sigEndOfCentralDir = 0x06054b50;
const int _winZipAeExtraHeaderId = 0x9901;
const int _winZipAeCompressionMethod = 99;

final class _AeExtraInfo {
  const _AeExtraInfo({
    required this.vendorVersion,
    required this.strength,
    required this.actualCompressionMethod,
  });

  /// `1` = AE-1 (retains CRC-32), `2` = AE-2 (sets CRC-32 to 0).
  final int vendorVersion;

  /// `1` = AES-128, `2` = AES-192, `3` = AES-256.
  final int strength;

  /// `0` = STORED, `8` = DEFLATE.
  final int actualCompressionMethod;

  int get keyLength => switch (strength) {
    1 => 16,
    2 => 24,
    3 => 32,
    _ => throw const Failure(FailureCode.corruptData, '不支持的 WinZip AES 密钥强度'),
  };

  int get saltLength => switch (strength) {
    1 => 8,
    2 => 12,
    3 => 16,
    _ => throw const Failure(FailureCode.corruptData, '不支持的 WinZip AES 盐长度'),
  };
}

final class _ZipEntryMeta {
  const _ZipEntryMeta({
    required this.name,
    required this.gpBitFlag,
    required this.compressionMethod,
    required this.lastModTime,
    required this.crc32,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.localHeaderOffset,
    required this.cdExtra,
  });

  final String name;
  final int gpBitFlag;
  final int compressionMethod;
  final int lastModTime;
  final int crc32;
  final int compressedSize;
  final int uncompressedSize;
  final int localHeaderOffset;
  final Uint8List cdExtra;

  bool get isEncrypted =>
      (gpBitFlag & 0x01) != 0 ||
      compressionMethod == _winZipAeCompressionMethod;
}

List<_ZipEntryMeta> _parseCentralDirectory(Uint8List bytes) {
  final view = ByteData.sublistView(bytes);
  final minEocdOffset = max(0, bytes.length - 22 - 0xffff);
  var eocdOffset = -1;
  for (var pos = bytes.length - 22; pos >= minEocdOffset; pos--) {
    if (view.getUint32(pos, Endian.little) == _sigEndOfCentralDir) {
      final commentLen = view.getUint16(pos + 20, Endian.little);
      if (pos + 22 + commentLen <= bytes.length) {
        eocdOffset = pos;
        break;
      }
    }
  }
  if (eocdOffset < 0) {
    throw const Failure(FailureCode.corruptData, 'ZIP 归档目录结尾损坏');
  }

  final totalEntries = view.getUint16(eocdOffset + 10, Endian.little);
  final cdSize = view.getUint32(eocdOffset + 12, Endian.little);
  final cdOffset = view.getUint32(eocdOffset + 16, Endian.little);
  if (cdOffset + cdSize > eocdOffset) {
    throw const Failure(FailureCode.corruptData, 'ZIP 中央目录偏移超出文件范围');
  }

  final entries = <_ZipEntryMeta>[];
  var cursor = cdOffset;
  for (var i = 0; i < totalEntries; i++) {
    if (cursor + 46 > eocdOffset ||
        view.getUint32(cursor, Endian.little) != _sigCentralDirHeader) {
      throw const Failure(FailureCode.corruptData, 'ZIP 中央目录条目头损坏');
    }
    final gpBitFlag = view.getUint16(cursor + 8, Endian.little);
    final compressionMethod = view.getUint16(cursor + 10, Endian.little);
    final lastModTime = view.getUint16(cursor + 12, Endian.little);
    final crc32 = view.getUint32(cursor + 16, Endian.little);
    final compressedSize = view.getUint32(cursor + 20, Endian.little);
    final uncompressedSize = view.getUint32(cursor + 24, Endian.little);
    final nameLen = view.getUint16(cursor + 28, Endian.little);
    final extraLen = view.getUint16(cursor + 30, Endian.little);
    final commentLen = view.getUint16(cursor + 32, Endian.little);
    final localHeaderOffset = view.getUint32(cursor + 42, Endian.little);

    final nextCursor = cursor + 46 + nameLen + extraLen + commentLen;
    if (nextCursor > eocdOffset) {
      throw const Failure(FailureCode.corruptData, 'ZIP 中央目录变长字段越界');
    }

    final rawName = utf8.decode(
      Uint8List.sublistView(bytes, cursor + 46, cursor + 46 + nameLen),
      allowMalformed: true,
    );
    final safeName = _sanitizeArchiveEntryPath(rawName);
    final cdExtra = Uint8List.sublistView(
      bytes,
      cursor + 46 + nameLen,
      cursor + 46 + nameLen + extraLen,
    );

    if (safeName.isNotEmpty && !safeName.endsWith('/')) {
      entries.add(
        _ZipEntryMeta(
          name: safeName,
          gpBitFlag: gpBitFlag,
          compressionMethod: compressionMethod,
          lastModTime: lastModTime,
          crc32: crc32,
          compressedSize: compressedSize,
          uncompressedSize: uncompressedSize,
          localHeaderOffset: localHeaderOffset,
          cdExtra: cdExtra,
        ),
      );
    }
    cursor = nextCursor;
  }
  return entries;
}

String _sanitizeArchiveEntryPath(String rawName) {
  if (rawName.contains('\u0000')) {
    throw const Failure(FailureCode.corruptData, 'ZIP 条目路径包含非法空字节');
  }
  final normalized = rawName.replaceAll(r'\', '/');
  final segments = normalized.split('/');
  final clean = <String>[];
  for (final seg in segments) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      throw const Failure(FailureCode.corruptData, '检测到不安全的归档路径穿越');
    }
    clean.add(seg);
  }
  final joined = clean.join('/');
  return normalized.endsWith('/') && joined.isNotEmpty ? '$joined/' : joined;
}

_ZipEntryMeta? _selectSqliteEntry(List<_ZipEntryMeta> entries) {
  final candidates = <_ZipEntryMeta>[];
  for (final entry in entries) {
    final lower = entry.name.toLowerCase();
    if (lower.startsWith('__macosx/') || lower.endsWith('/.ds_store')) continue;
    if (lower == '.ds_store') continue;
    if (lower.endsWith('-wal') ||
        lower.endsWith('-shm') ||
        lower.endsWith('-journal') ||
        lower.endsWith('.crc')) {
      continue;
    }
    candidates.add(entry);
  }
  if (candidates.isEmpty) return null;

  int depthOf(_ZipEntryMeta e) => '/'.allMatches(e.name).length;
  String baseNameLower(_ZipEntryMeta e) {
    final idx = e.name.lastIndexOf('/');
    return (idx >= 0 ? e.name.substring(idx + 1) : e.name).toLowerCase();
  }

  // 1. Prefer canonical `yiyujizhang.db` (shallowest path first).
  final exactMatches = [
    for (final c in candidates)
      if (baseNameLower(c) == 'yiyujizhang.db') c,
  ]..sort((a, b) => depthOf(a).compareTo(depthOf(b)));
  if (exactMatches.isNotEmpty) return exactMatches.first;

  // 2. Any `.db` / `.sqlite` / `.sqlite3` file recursively (shallowest first).
  final extMatches = [
    for (final c in candidates)
      if (baseNameLower(c).endsWith('.db') ||
          baseNameLower(c).endsWith('.sqlite') ||
          baseNameLower(c).endsWith('.sqlite3'))
        c,
  ]..sort((a, b) => depthOf(a).compareTo(depthOf(b)));
  if (extMatches.isNotEmpty) return extMatches.first;

  return null;
}

LanExtractionResult _extractZipEntry(
  Uint8List archiveBytes,
  _ZipEntryMeta entry, {
  String? password,
}) {
  final view = ByteData.sublistView(archiveBytes);
  final lhOffset = entry.localHeaderOffset;
  if (lhOffset + 30 > archiveBytes.length ||
      view.getUint32(lhOffset, Endian.little) != _sigLocalFileHeader) {
    throw const Failure(FailureCode.corruptData, 'ZIP 局部文件头损坏');
  }
  final localNameLen = view.getUint16(lhOffset + 26, Endian.little);
  final localExtraLen = view.getUint16(lhOffset + 28, Endian.little);
  final dataStart = lhOffset + 30 + localNameLen + localExtraLen;
  final dataEnd = dataStart + entry.compressedSize;
  if (dataStart < 0 || dataEnd > archiveBytes.length) {
    throw const Failure(FailureCode.corruptData, 'ZIP 压缩数据范围越界');
  }

  final localExtra = Uint8List.sublistView(
    archiveBytes,
    lhOffset + 30 + localNameLen,
    dataStart,
  );
  final payload = Uint8List.sublistView(archiveBytes, dataStart, dataEnd);

  if (!entry.isEncrypted) {
    final plain = _decompressZipPayload(
      payload,
      method: entry.compressionMethod,
      expectedUncompressedSize: entry.uncompressedSize,
    );
    final actualCrc = computeCrc32(plain);
    if (actualCrc != entry.crc32) {
      throw const Failure(FailureCode.corruptData, 'ZIP 数据库条目 CRC32 校验失败');
    }
    if (!hasSqlite3Magic(plain)) {
      throw const Failure(FailureCode.corruptData, '解压出的文件不是合法的 SQLite 3 数据库');
    }
    return LanExtractionSuccess(
      dbBytes: plain,
      entryName: entry.name,
      wasEncrypted: false,
    );
  }

  if (password == null || password.isEmpty) {
    return LanExtractionPasswordRequired(entryName: entry.name);
  }

  if (entry.compressionMethod == _winZipAeCompressionMethod) {
    final ae =
        _parseWinZipAeExtra(entry.cdExtra) ?? _parseWinZipAeExtra(localExtra);
    if (ae == null) {
      throw const Failure(
        FailureCode.corruptData,
        'ZIP 缺少 WinZip AE (0x9901) 加密扩展头',
      );
    }
    return _decryptWinZipAeEntry(entry, ae, payload, password);
  }

  // Fallback support for legacy PKWARE ZipCrypto if encountered.
  return _decryptLegacyZipCryptoEntry(entry, payload, password);
}

_AeExtraInfo? _parseWinZipAeExtra(Uint8List extraBytes) {
  if (extraBytes.length < 11) return null;
  final view = ByteData.sublistView(extraBytes);
  var offset = 0;
  while (offset + 4 <= extraBytes.length) {
    final headerId = view.getUint16(offset, Endian.little);
    final dataSize = view.getUint16(offset + 2, Endian.little);
    final fieldStart = offset + 4;
    final fieldEnd = fieldStart + dataSize;
    if (fieldEnd > extraBytes.length) break;
    if (headerId == _winZipAeExtraHeaderId && dataSize >= 7) {
      final vendorVersion = view.getUint16(fieldStart, Endian.little);
      final v0 = extraBytes[fieldStart + 2];
      final v1 = extraBytes[fieldStart + 3];
      if ((vendorVersion != 1 && vendorVersion != 2) ||
          v0 != 0x41 ||
          v1 != 0x45) {
        throw const Failure(FailureCode.corruptData, '不支持的 WinZip AE 版本标识');
      }
      final strength = extraBytes[fieldStart + 4];
      final actualMethod = view.getUint16(fieldStart + 5, Endian.little);
      return _AeExtraInfo(
        vendorVersion: vendorVersion,
        strength: strength,
        actualCompressionMethod: actualMethod,
      );
    }
    offset = fieldEnd;
  }
  return null;
}

LanExtractionResult _decryptWinZipAeEntry(
  _ZipEntryMeta entry,
  _AeExtraInfo ae,
  Uint8List payload,
  String password,
) {
  final saltLen = ae.saltLength;
  final keyLen = ae.keyLength;
  final overhead = saltLen + 2 + 10;
  if (payload.length < overhead) {
    throw const Failure(FailureCode.corruptData, '加密 ZIP 数据长度不足');
  }

  final cipherLen = payload.length - overhead;
  final salt = Uint8List.sublistView(payload, 0, saltLen);
  final pwdCheck = Uint8List.sublistView(payload, saltLen, saltLen + 2);
  final ciphertext = Uint8List.sublistView(
    payload,
    saltLen + 2,
    saltLen + 2 + cipherLen,
  );
  final authCode = Uint8List.sublistView(
    payload,
    saltLen + 2 + cipherLen,
    payload.length,
  );

  final dk = pbkdf2HmacSha1(
    passwordBytes: Uint8List.fromList(utf8.encode(password)),
    salt: salt,
    iterations: 1000,
    derivedKeyLength: 2 * keyLen + 2,
  );
  final aesKey = Uint8List.sublistView(dk, 0, keyLen);
  final hmacKey = Uint8List.sublistView(dk, keyLen, 2 * keyLen);
  final pwdVerifier = Uint8List.sublistView(dk, 2 * keyLen, 2 * keyLen + 2);

  final verifierOk = _constantTimeEquals(pwdVerifier, pwdCheck);
  final digestBytes = Hmac(sha1, hmacKey).convert(ciphertext).bytes;
  final expectedMac = Uint8List.fromList(digestBytes.sublist(0, 10));
  final macOk = _constantTimeEquals(expectedMac, authCode);

  if (!verifierOk || !macOk) {
    return LanExtractionWrongPassword(
      entryName: entry.name,
      verifierMatched: verifierOk,
    );
  }

  final compressedPlain = aesCtrWinZip(aesKey: aesKey, input: ciphertext);
  final uncompressed = _decompressZipPayload(
    compressedPlain,
    method: ae.actualCompressionMethod,
    expectedUncompressedSize: entry.uncompressedSize,
  );

  if (ae.vendorVersion == 1) {
    final actualCrc = computeCrc32(uncompressed);
    if (actualCrc != entry.crc32) {
      throw const Failure(FailureCode.corruptData, 'AE-1 解密后 CRC32 校验失败');
    }
  }

  if (!hasSqlite3Magic(uncompressed)) {
    throw const Failure(FailureCode.corruptData, '解密出的文件不是合法的 SQLite 3 数据库');
  }

  return LanExtractionSuccess(
    dbBytes: uncompressed,
    entryName: entry.name,
    wasEncrypted: true,
  );
}

LanExtractionResult _decryptLegacyZipCryptoEntry(
  _ZipEntryMeta entry,
  Uint8List payload,
  String password,
) {
  if (payload.length < 12) {
    throw const Failure(FailureCode.corruptData, '传统加密 ZIP 头长度不足');
  }
  final stream = _ZipCryptoState()..initPassword(utf8.encode(password));
  final header = Uint8List(12);
  for (var i = 0; i < 12; i++) {
    final plainByte = payload[i] ^ stream.decryptByte();
    stream.updateKeys(plainByte);
    header[i] = plainByte;
  }
  final expectedCheckByte = (entry.gpBitFlag & 0x08) != 0
      ? ((entry.lastModTime >> 8) & 0xff)
      : ((entry.crc32 >> 24) & 0xff);
  if (header[11] != expectedCheckByte) {
    return LanExtractionWrongPassword(
      entryName: entry.name,
      verifierMatched: false,
    );
  }

  final cipherBodyLen = payload.length - 12;
  final compressedPlain = Uint8List(cipherBodyLen);
  for (var i = 0; i < cipherBodyLen; i++) {
    final plainByte = payload[12 + i] ^ stream.decryptByte();
    stream.updateKeys(plainByte);
    compressedPlain[i] = plainByte;
  }

  final Uint8List uncompressed;
  try {
    uncompressed = _decompressZipPayload(
      compressedPlain,
      method: entry.compressionMethod,
      expectedUncompressedSize: entry.uncompressedSize,
    );
  } on Failure {
    return LanExtractionWrongPassword(
      entryName: entry.name,
      verifierMatched: true,
    );
  }
  if (computeCrc32(uncompressed) != entry.crc32) {
    return LanExtractionWrongPassword(
      entryName: entry.name,
      verifierMatched: true,
    );
  }
  if (!hasSqlite3Magic(uncompressed)) {
    throw const Failure(FailureCode.corruptData, '解密出的文件不是合法的 SQLite 3 数据库');
  }
  return LanExtractionSuccess(
    dbBytes: uncompressed,
    entryName: entry.name,
    wasEncrypted: true,
  );
}

Uint8List _decompressZipPayload(
  Uint8List compressed, {
  required int method,
  required int expectedUncompressedSize,
}) {
  final Uint8List out;
  if (method == 0) {
    out = Uint8List.fromList(compressed);
  } else if (method == 8) {
    try {
      out = Uint8List.fromList(ZLibCodec(raw: true).decode(compressed));
    } catch (_) {
      throw const Failure(FailureCode.corruptData, 'ZIP DEFLATE 数据流解压失败');
    }
  } else {
    throw Failure(FailureCode.unsupportedCapability, '不支持的 ZIP 压缩算法: $method');
  }
  if (expectedUncompressedSize > 0 && out.length != expectedUncompressedSize) {
    throw const Failure(FailureCode.corruptData, 'ZIP 解压后大小与归档记录不一致');
  }
  return out;
}

bool _constantTimeEquals(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

// ============================================================================
// Cryptographic Primitives: PBKDF2-HMAC-SHA1, FIPS-197 AES-128/192/256,
// WinZip 1-Based Little-Endian AES-CTR, and IEEE 802.3 CRC-32
// ============================================================================

/// RFC 2898 `PBKDF2-HMAC-SHA1`.
Uint8List pbkdf2HmacSha1({
  required Uint8List passwordBytes,
  required Uint8List salt,
  required int iterations,
  required int derivedKeyLength,
}) {
  if (iterations < 1 || derivedKeyLength < 1) {
    throw ArgumentError('Invalid PBKDF2 parameters');
  }
  final hmac = Hmac(sha1, passwordBytes);
  const hLen = 20;
  final blockCount = (derivedKeyLength + hLen - 1) ~/ hLen;
  final out = Uint8List(derivedKeyLength);
  final saltWithIndex = Uint8List(salt.length + 4)
    ..setRange(0, salt.length, salt);

  var outOffset = 0;
  for (var blockIndex = 1; blockIndex <= blockCount; blockIndex++) {
    saltWithIndex[salt.length] = (blockIndex >> 24) & 0xff;
    saltWithIndex[salt.length + 1] = (blockIndex >> 16) & 0xff;
    saltWithIndex[salt.length + 2] = (blockIndex >> 8) & 0xff;
    saltWithIndex[salt.length + 3] = blockIndex & 0xff;

    var u = Uint8List.fromList(hmac.convert(saltWithIndex).bytes);
    final t = Uint8List.fromList(u);
    for (var iter = 1; iter < iterations; iter++) {
      u = Uint8List.fromList(hmac.convert(u).bytes);
      for (var k = 0; k < hLen; k++) {
        t[k] ^= u[k];
      }
    }
    final copyLen = min(hLen, derivedKeyLength - outOffset);
    out.setRange(outOffset, outOffset + copyLen, t);
    outOffset += copyLen;
  }
  return out;
}

/// WinZip AE / Zip4j `AES-CTR` stream cipher:
/// 16-byte counter block with 1-based little-endian 64-bit block counter in
/// `counterBlock[0..7]` and zeros in `counterBlock[8..15]`.
Uint8List aesCtrWinZip({required Uint8List aesKey, required Uint8List input}) {
  final cipher = AesBlockCipher(aesKey);
  final out = Uint8List(input.length);
  final counterBlock = Uint8List(16);
  final keystream = Uint8List(16);

  var blockIndex = 0;
  for (var offset = 0; offset < input.length; offset += 16) {
    var counter = blockIndex + 1;
    for (var j = 0; j < 8; j++) {
      counterBlock[j] = counter & 0xff;
      counter >>= 8;
    }
    for (var j = 8; j < 16; j++) {
      counterBlock[j] = 0;
    }
    cipher.encryptBlockInto(counterBlock, keystream);
    final chunkLen = min(16, input.length - offset);
    for (var i = 0; i < chunkLen; i++) {
      out[offset + i] = input[offset + i] ^ keystream[i];
    }
    blockIndex++;
  }
  return out;
}

/// Pure-Dart FIPS-197 AES-128 / AES-192 / AES-256 forward block cipher.
final class AesBlockCipher {
  AesBlockCipher(Uint8List key)
    : _rounds = switch (key.length) {
        16 => 10,
        24 => 12,
        32 => 14,
        _ => throw ArgumentError('Invalid AES key length: ${key.length}'),
      },
      _roundKeys = _expandKey(key);

  final int _rounds;
  final Uint32List _roundKeys;

  static final Uint8List _sbox = _buildSbox();

  static int _gfMul(int a, int b) {
    var res = 0;
    var aa = a & 0xff;
    var bb = b & 0xff;
    for (var i = 0; i < 8; i++) {
      if ((bb & 1) != 0) res ^= aa;
      final hi = aa & 0x80;
      aa = (aa << 1) & 0xff;
      if (hi != 0) aa ^= 0x1b;
      bb >>= 1;
    }
    return res;
  }

  static Uint8List _buildSbox() {
    final table = Uint8List(256);
    table[0] = 0x63;
    for (var x = 1; x < 256; x++) {
      var inv = 1;
      for (var y = 1; y < 256; y++) {
        if (_gfMul(x, y) == 1) {
          inv = y;
          break;
        }
      }
      int rotl8(int v, int shift) => ((v << shift) | (v >> (8 - shift))) & 0xff;
      table[x] =
          (inv ^
              rotl8(inv, 1) ^
              rotl8(inv, 2) ^
              rotl8(inv, 3) ^
              rotl8(inv, 4) ^
              0x63) &
          0xff;
    }
    return table;
  }

  static int _subWord(int w) =>
      ((_sbox[(w >>> 24) & 0xff] << 24) |
          (_sbox[(w >>> 16) & 0xff] << 16) |
          (_sbox[(w >>> 8) & 0xff] << 8) |
          _sbox[w & 0xff]) &
      0xffffffff;

  static int _rotWord(int w) => (((w << 8) & 0xffffffff) | ((w >>> 24) & 0xff));

  static Uint32List _expandKey(Uint8List key) {
    final nk = key.length ~/ 4;
    final nr = nk + 6;
    final totalWords = 4 * (nr + 1);
    final w = Uint32List(totalWords);

    for (var i = 0; i < nk; i++) {
      w[i] =
          ((key[4 * i] << 24) |
              (key[4 * i + 1] << 16) |
              (key[4 * i + 2] << 8) |
              key[4 * i + 3]) &
          0xffffffff;
    }

    var rcon = 0x01;
    for (var i = nk; i < totalWords; i++) {
      var temp = w[i - 1];
      if (i % nk == 0) {
        temp = _subWord(_rotWord(temp)) ^ ((rcon << 24) & 0xffffffff);
        rcon = _gfMul(rcon, 0x02);
      } else if (nk > 6 && i % nk == 4) {
        temp = _subWord(temp);
      }
      w[i] = (w[i - nk] ^ temp) & 0xffffffff;
    }
    return w;
  }

  /// Encrypts a 16-byte [input] block and returns a new 16-byte [Uint8List].
  Uint8List encryptBlock(Uint8List input) {
    if (input.length != 16) {
      throw ArgumentError('AES block must be 16 bytes');
    }
    final out = Uint8List(16);
    encryptBlockInto(input, out);
    return out;
  }

  /// Encrypts 16 bytes from [input] into [out].
  void encryptBlockInto(Uint8List input, Uint8List out) {
    var s0 = input[0], s1 = input[1], s2 = input[2], s3 = input[3];
    var s4 = input[4], s5 = input[5], s6 = input[6], s7 = input[7];
    var s8 = input[8], s9 = input[9], s10 = input[10], s11 = input[11];
    var s12 = input[12], s13 = input[13], s14 = input[14], s15 = input[15];

    void addRoundKey(int round) {
      final base = round * 4;
      final k0 = _roundKeys[base];
      final k1 = _roundKeys[base + 1];
      final k2 = _roundKeys[base + 2];
      final k3 = _roundKeys[base + 3];
      s0 ^= (k0 >>> 24) & 0xff;
      s1 ^= (k0 >>> 16) & 0xff;
      s2 ^= (k0 >>> 8) & 0xff;
      s3 ^= k0 & 0xff;
      s4 ^= (k1 >>> 24) & 0xff;
      s5 ^= (k1 >>> 16) & 0xff;
      s6 ^= (k1 >>> 8) & 0xff;
      s7 ^= k1 & 0xff;
      s8 ^= (k2 >>> 24) & 0xff;
      s9 ^= (k2 >>> 16) & 0xff;
      s10 ^= (k2 >>> 8) & 0xff;
      s11 ^= k2 & 0xff;
      s12 ^= (k3 >>> 24) & 0xff;
      s13 ^= (k3 >>> 16) & 0xff;
      s14 ^= (k3 >>> 8) & 0xff;
      s15 ^= k3 & 0xff;
    }

    int xtime(int x) => ((x << 1) ^ ((x & 0x80) != 0 ? 0x1b : 0)) & 0xff;

    addRoundKey(0);

    for (var round = 1; round < _rounds; round++) {
      // SubBytes + ShiftRows combined
      final t0 = _sbox[s0];
      final t1 = _sbox[s5];
      final t2 = _sbox[s10];
      final t3 = _sbox[s15];
      final t4 = _sbox[s4];
      final t5 = _sbox[s9];
      final t6 = _sbox[s14];
      final t7 = _sbox[s3];
      final t8 = _sbox[s8];
      final t9 = _sbox[s13];
      final t10 = _sbox[s2];
      final t11 = _sbox[s7];
      final t12 = _sbox[s12];
      final t13 = _sbox[s1];
      final t14 = _sbox[s6];
      final t15 = _sbox[s11];

      // MixColumns
      final c0 = t0 ^ t1 ^ t2 ^ t3;
      s0 = t0 ^ c0 ^ xtime(t0 ^ t1);
      s1 = t1 ^ c0 ^ xtime(t1 ^ t2);
      s2 = t2 ^ c0 ^ xtime(t2 ^ t3);
      s3 = t3 ^ c0 ^ xtime(t3 ^ t0);

      final c1 = t4 ^ t5 ^ t6 ^ t7;
      s4 = t4 ^ c1 ^ xtime(t4 ^ t5);
      s5 = t5 ^ c1 ^ xtime(t5 ^ t6);
      s6 = t6 ^ c1 ^ xtime(t6 ^ t7);
      s7 = t7 ^ c1 ^ xtime(t7 ^ t4);

      final c2 = t8 ^ t9 ^ t10 ^ t11;
      s8 = t8 ^ c2 ^ xtime(t8 ^ t9);
      s9 = t9 ^ c2 ^ xtime(t9 ^ t10);
      s10 = t10 ^ c2 ^ xtime(t10 ^ t11);
      s11 = t11 ^ c2 ^ xtime(t11 ^ t8);

      final c3 = t12 ^ t13 ^ t14 ^ t15;
      s12 = t12 ^ c3 ^ xtime(t12 ^ t13);
      s13 = t13 ^ c3 ^ xtime(t13 ^ t14);
      s14 = t14 ^ c3 ^ xtime(t14 ^ t15);
      s15 = t15 ^ c3 ^ xtime(t15 ^ t12);

      addRoundKey(round);
    }

    // Final round (SubBytes + ShiftRows + AddRoundKey, no MixColumns)
    final f0 = _sbox[s0];
    final f1 = _sbox[s5];
    final f2 = _sbox[s10];
    final f3 = _sbox[s15];
    final f4 = _sbox[s4];
    final f5 = _sbox[s9];
    final f6 = _sbox[s14];
    final f7 = _sbox[s3];
    final f8 = _sbox[s8];
    final f9 = _sbox[s13];
    final f10 = _sbox[s2];
    final f11 = _sbox[s7];
    final f12 = _sbox[s12];
    final f13 = _sbox[s1];
    final f14 = _sbox[s6];
    final f15 = _sbox[s11];

    s0 = f0;
    s1 = f1;
    s2 = f2;
    s3 = f3;
    s4 = f4;
    s5 = f5;
    s6 = f6;
    s7 = f7;
    s8 = f8;
    s9 = f9;
    s10 = f10;
    s11 = f11;
    s12 = f12;
    s13 = f13;
    s14 = f14;
    s15 = f15;

    addRoundKey(_rounds);

    out[0] = s0;
    out[1] = s1;
    out[2] = s2;
    out[3] = s3;
    out[4] = s4;
    out[5] = s5;
    out[6] = s6;
    out[7] = s7;
    out[8] = s8;
    out[9] = s9;
    out[10] = s10;
    out[11] = s11;
    out[12] = s12;
    out[13] = s13;
    out[14] = s14;
    out[15] = s15;
  }
}

final Uint32List _crc32Table = () {
  final table = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
    }
    table[i] = c & 0xffffffff;
  }
  return table;
}();

/// Computes standard IEEE 802.3 CRC-32 (`uint32`).
int computeCrc32(Uint8List data) {
  var crc = 0xffffffff;
  for (var i = 0; i < data.length; i++) {
    crc = _crc32Table[(crc ^ data[i]) & 0xff] ^ (crc >>> 8);
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

final class _ZipCryptoState {
  int _k0 = 0x12345678;
  int _k1 = 0x23456789;
  int _k2 = 0x34567890;

  void initPassword(List<int> passwordBytes) {
    for (final b in passwordBytes) {
      updateKeys(b & 0xff);
    }
  }

  void updateKeys(int byte) {
    _k0 = (_crc32Table[(_k0 ^ byte) & 0xff] ^ (_k0 >>> 8)) & 0xffffffff;
    _k1 = ((_k1 + (_k0 & 0xff)) & 0xffffffff);
    _k1 = ((_k1 * 134775813 + 1) & 0xffffffff);
    _k2 =
        (_crc32Table[(_k2 ^ ((_k1 >>> 24) & 0xff)) & 0xff] ^ (_k2 >>> 8)) &
        0xffffffff;
  }

  int decryptByte() {
    final temp = (_k2 | 2) & 0xffff;
    return ((temp * (temp ^ 1)) >>> 8) & 0xff;
  }
}

// ============================================================================
// Zip4j-Compatible WinZip AE-2 / Unencrypted Archive Builder (For Tests & Tools)
// ============================================================================

/// Entry specification for [buildLanZipArchive].
final class LanZipInputEntry {
  const LanZipInputEntry({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

/// Builds a standard PKZIP or Zip4j-compatible WinZip AE-2 (`AES-256-CTR`,
/// `PBKDF2-HMAC-SHA1` 1000 iterations, `HMAC-SHA1-80`, `0x9901` extra header)
/// archive from [entries].
Uint8List buildLanZipArchive(
  List<LanZipInputEntry> entries, {
  String? password,
  bool compress = true,
  Uint8List? deterministicSalt16,
}) {
  final localOut = BytesBuilder(copy: false);
  final cdOut = BytesBuilder(copy: false);
  final rng = Random.secure();

  for (final item in entries) {
    final nameBytes = Uint8List.fromList(utf8.encode(item.name));
    final uncompressed = item.bytes;
    final actualMethod = compress ? 8 : 0;
    final compressedRaw = compress
        ? Uint8List.fromList(ZLibCodec(raw: true).encode(uncompressed))
        : Uint8List.fromList(uncompressed);

    final bool encrypted = password != null && password.isNotEmpty;
    final int gpBitFlag;
    final int storedMethod;
    final int crc32;
    final Uint8List extraField;
    final Uint8List storedPayload;

    if (!encrypted) {
      gpBitFlag = 0x0800; // UTF-8 filename flag
      storedMethod = actualMethod;
      crc32 = computeCrc32(uncompressed);
      extraField = Uint8List(0);
      storedPayload = compressedRaw;
    } else {
      gpBitFlag = 0x0801; // UTF-8 + encrypted flag
      storedMethod = _winZipAeCompressionMethod;
      crc32 = 0; // AE-2 sets CRC-32 to 0 per WinZip specification

      final extraData = ByteData(11)
        ..setUint16(0, _winZipAeExtraHeaderId, Endian.little)
        ..setUint16(2, 7, Endian.little)
        ..setUint16(4, 2, Endian.little) // AE-2
        ..setUint8(6, 0x41) // 'A'
        ..setUint8(7, 0x45) // 'E'
        ..setUint8(8, 3) // AES-256 (32-byte key, 16-byte salt)
        ..setUint16(9, actualMethod, Endian.little);
      extraField = extraData.buffer.asUint8List();

      final salt =
          deterministicSalt16 ??
          Uint8List.fromList(List<int>.generate(16, (_) => rng.nextInt(256)));
      if (salt.length != 16) {
        throw ArgumentError('AES-256 salt must be 16 bytes');
      }
      final dk = pbkdf2HmacSha1(
        passwordBytes: Uint8List.fromList(utf8.encode(password)),
        salt: salt,
        iterations: 1000,
        derivedKeyLength: 66,
      );
      final aesKey = Uint8List.sublistView(dk, 0, 32);
      final hmacKey = Uint8List.sublistView(dk, 32, 64);
      final pwdVerifier = Uint8List.sublistView(dk, 64, 66);

      final ciphertext = aesCtrWinZip(aesKey: aesKey, input: compressedRaw);
      final macFull = Hmac(sha1, hmacKey).convert(ciphertext).bytes;
      final authCode = Uint8List.fromList(macFull.sublist(0, 10));

      final payloadBuilder = BytesBuilder(copy: false)
        ..add(salt)
        ..add(pwdVerifier)
        ..add(ciphertext)
        ..add(authCode);
      storedPayload = payloadBuilder.toBytes();
    }

    final localHeaderOffset = localOut.length;

    final lh = ByteData(30)
      ..setUint32(0, _sigLocalFileHeader, Endian.little)
      ..setUint16(4, encrypted ? 51 : 20, Endian.little)
      ..setUint16(6, gpBitFlag, Endian.little)
      ..setUint16(8, storedMethod, Endian.little)
      ..setUint16(10, 0, Endian.little)
      ..setUint16(12, 0x21, Endian.little)
      ..setUint32(14, crc32, Endian.little)
      ..setUint32(18, storedPayload.length, Endian.little)
      ..setUint32(22, uncompressed.length, Endian.little)
      ..setUint16(26, nameBytes.length, Endian.little)
      ..setUint16(28, extraField.length, Endian.little);
    localOut
      ..add(lh.buffer.asUint8List())
      ..add(nameBytes)
      ..add(extraField)
      ..add(storedPayload);

    final cd = ByteData(46)
      ..setUint32(0, _sigCentralDirHeader, Endian.little)
      ..setUint16(4, encrypted ? 51 : 20, Endian.little)
      ..setUint16(6, encrypted ? 51 : 20, Endian.little)
      ..setUint16(8, gpBitFlag, Endian.little)
      ..setUint16(10, storedMethod, Endian.little)
      ..setUint16(12, 0, Endian.little)
      ..setUint16(14, 0x21, Endian.little)
      ..setUint32(16, crc32, Endian.little)
      ..setUint32(20, storedPayload.length, Endian.little)
      ..setUint32(24, uncompressed.length, Endian.little)
      ..setUint16(28, nameBytes.length, Endian.little)
      ..setUint16(30, extraField.length, Endian.little)
      ..setUint16(32, 0, Endian.little)
      ..setUint16(34, 0, Endian.little)
      ..setUint16(36, 0, Endian.little)
      ..setUint32(38, 0, Endian.little)
      ..setUint32(42, localHeaderOffset, Endian.little);
    cdOut
      ..add(cd.buffer.asUint8List())
      ..add(nameBytes)
      ..add(extraField);
  }

  final cdOffset = localOut.length;
  final cdBytes = cdOut.toBytes();
  final eocd = ByteData(22)
    ..setUint32(0, _sigEndOfCentralDir, Endian.little)
    ..setUint16(4, 0, Endian.little)
    ..setUint16(6, 0, Endian.little)
    ..setUint16(8, entries.length, Endian.little)
    ..setUint16(10, entries.length, Endian.little)
    ..setUint32(12, cdBytes.length, Endian.little)
    ..setUint32(16, cdOffset, Endian.little)
    ..setUint16(20, 0, Endian.little);

  return (BytesBuilder(copy: false)
        ..add(localOut.toBytes())
        ..add(cdBytes)
        ..add(eocd.buffer.asUint8List()))
      .toBytes();
}
