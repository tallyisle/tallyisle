import 'dart:convert';
import 'dart:io' show ZLibCodec;
import 'dart:typed_data';

import 'failure.dart';

/// Standard ZIP compression methods supported by TallyIsle `.tally` archives.
enum ZipCompressionMethod {
  stored(0),
  deflate(8);

  const ZipCompressionMethod(this.code);
  final int code;

  static ZipCompressionMethod fromCode(int code) => switch (code) {
    0 => ZipCompressionMethod.stored,
    8 => ZipCompressionMethod.deflate,
    _ => throw Failure(FailureCode.corruptData, '不支持的 ZIP 压缩算法（code=$code）'),
  };
}

/// A single file entry inside a standard ZIP archive.
final class ZipEntry {
  ZipEntry({
    required this.name,
    required List<int> bytes,
    this.method = ZipCompressionMethod.deflate,
    DateTime? modifiedAt,
  }) : bytes = bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
       modifiedAt =
           modifiedAt ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true) {
    validateZipEntryPath(name);
  }

  final String name;
  final Uint8List bytes;
  final ZipCompressionMethod method;
  final DateTime modifiedAt;

  int get crc => crc32(bytes);
}

/// Decoded standard ZIP archive container.
final class ZipArchive {
  ZipArchive(Iterable<ZipEntry> entries)
    : entries = List<ZipEntry>.unmodifiable(entries),
      _byName = {for (final e in entries) e.name: e};

  final List<ZipEntry> entries;
  final Map<String, ZipEntry> _byName;

  ZipEntry? operator [](String name) => _byName[name];

  bool contains(String name) => _byName.containsKey(name);

  static const int _localHeaderSig = 0x04034b50;
  static const int _centralHeaderSig = 0x02014b50;
  static const int _eocdSig = 0x06054b50;
  static const int _utf8Flag = 0x0800;
  static const int _encryptedFlag = 0x0001;
  static const int _dataDescriptorFlag = 0x0008;
  static const int _version20 = 20;

  /// Encodes [entries] into a standard PKWARE ZIP byte buffer with UTF-8 file
  /// names (`0x0800`) and IEEE 802.3 CRC-32 checksums.
  static Uint8List encode(
    Iterable<ZipEntry> entries, {
    DateTime? defaultModifiedAt,
  }) {
    final seenNames = <String>{};
    final out = BytesBuilder(copy: false);
    final centralDir = BytesBuilder(copy: false);
    var localOffset = 0;
    var count = 0;

    for (final entry in entries) {
      final cleanName = validateZipEntryPath(entry.name);
      if (!seenNames.add(cleanName)) {
        throw Failure(FailureCode.validation, 'ZIP 包含重复文件路径：$cleanName');
      }
      final nameBytes = Uint8List.fromList(utf8.encode(cleanName));
      if (nameBytes.length > 0xFFFF) {
        throw const Failure(FailureCode.validation, 'ZIP 文件名过长');
      }

      final uncompressed = entry.bytes;
      final effectiveMethod = uncompressed.isEmpty
          ? ZipCompressionMethod.stored
          : entry.method;
      final Uint8List compressed = switch (effectiveMethod) {
        ZipCompressionMethod.stored => uncompressed,
        ZipCompressionMethod.deflate => Uint8List.fromList(
          ZLibCodec(raw: true).encode(uncompressed),
        ),
      };

      if (uncompressed.length > 0xFFFFFFFF || compressed.length > 0xFFFFFFFF) {
        throw const Failure(FailureCode.validation, '单个文件体积超出标准 ZIP32 上限');
      }
      if (localOffset > 0xFFFFFFFF) {
        throw const Failure(FailureCode.validation, '压缩包偏移超出标准 ZIP32 上限');
      }

      final crc = crc32(uncompressed);
      final modWhen =
          entry.modifiedAt.millisecondsSinceEpoch == 0 &&
              defaultModifiedAt != null
          ? defaultModifiedAt
          : entry.modifiedAt;
      final (dosTime, dosDate) = _encodeDosDateTime(modWhen);

      final localHeader = ByteData(30)
        ..setUint32(0, _localHeaderSig, Endian.little)
        ..setUint16(4, _version20, Endian.little)
        ..setUint16(6, _utf8Flag, Endian.little)
        ..setUint16(8, effectiveMethod.code, Endian.little)
        ..setUint16(10, dosTime, Endian.little)
        ..setUint16(12, dosDate, Endian.little)
        ..setUint32(14, crc, Endian.little)
        ..setUint32(18, compressed.length, Endian.little)
        ..setUint32(22, uncompressed.length, Endian.little)
        ..setUint16(26, nameBytes.length, Endian.little)
        ..setUint16(28, 0, Endian.little);

      out
        ..add(localHeader.buffer.asUint8List())
        ..add(nameBytes)
        ..add(compressed);

      final centralHeader = ByteData(46)
        ..setUint32(0, _centralHeaderSig, Endian.little)
        ..setUint16(4, _version20, Endian.little)
        ..setUint16(6, _version20, Endian.little)
        ..setUint16(8, _utf8Flag, Endian.little)
        ..setUint16(10, effectiveMethod.code, Endian.little)
        ..setUint16(12, dosTime, Endian.little)
        ..setUint16(14, dosDate, Endian.little)
        ..setUint32(16, crc, Endian.little)
        ..setUint32(20, compressed.length, Endian.little)
        ..setUint32(24, uncompressed.length, Endian.little)
        ..setUint16(28, nameBytes.length, Endian.little)
        ..setUint16(30, 0, Endian.little)
        ..setUint16(32, 0, Endian.little)
        ..setUint16(34, 0, Endian.little)
        ..setUint16(36, 0, Endian.little)
        ..setUint32(38, 0, Endian.little)
        ..setUint32(42, localOffset, Endian.little);

      centralDir
        ..add(centralHeader.buffer.asUint8List())
        ..add(nameBytes);

      localOffset += 30 + nameBytes.length + compressed.length;
      count++;
    }

    if (count > 0xFFFF) {
      throw const Failure(FailureCode.validation, 'ZIP 条目数超出标准 ZIP32 上限');
    }

    final cdBytes = centralDir.takeBytes();
    final eocd = ByteData(22)
      ..setUint32(0, _eocdSig, Endian.little)
      ..setUint16(4, 0, Endian.little)
      ..setUint16(6, 0, Endian.little)
      ..setUint16(8, count, Endian.little)
      ..setUint16(10, count, Endian.little)
      ..setUint32(12, cdBytes.length, Endian.little)
      ..setUint32(16, localOffset, Endian.little)
      ..setUint16(20, 0, Endian.little);

    out
      ..add(cdBytes)
      ..add(eocd.buffer.asUint8List());
    return out.takeBytes();
  }

  /// Decodes a standard ZIP archive, validating path safety (zip-slip guard)
  /// and verifying uncompressed size and IEEE 802.3 CRC-32 for every entry.
  static ZipArchive decode(Uint8List archiveBytes) {
    if (archiveBytes.length < 22) {
      throw const Failure(FailureCode.corruptData, '备份文件不是有效的 ZIP 压缩包');
    }
    final data = ByteData.sublistView(archiveBytes);
    final eocdOffset = _findEndOfCentralDirectory(archiveBytes, data);

    final diskNum = data.getUint16(eocdOffset + 4, Endian.little);
    final cdDisk = data.getUint16(eocdOffset + 6, Endian.little);
    if (diskNum != 0 || cdDisk != 0) {
      throw const Failure(FailureCode.corruptData, '不支持分卷 ZIP 压缩包');
    }

    final totalEntries = data.getUint16(eocdOffset + 10, Endian.little);
    final cdSize = data.getUint32(eocdOffset + 12, Endian.little);
    final cdOffset = data.getUint32(eocdOffset + 16, Endian.little);
    if (cdOffset + cdSize > eocdOffset) {
      throw const Failure(FailureCode.corruptData, 'ZIP 中央目录边界损坏');
    }

    final entries = <ZipEntry>[];
    final seenNames = <String>{};
    var cursor = cdOffset;
    final cdEnd = cdOffset + cdSize;

    for (var i = 0; i < totalEntries; i++) {
      if (cursor + 46 > cdEnd) {
        throw const Failure(FailureCode.corruptData, 'ZIP 中央目录条目截断');
      }
      final sig = data.getUint32(cursor, Endian.little);
      if (sig != _centralHeaderSig) {
        throw const Failure(FailureCode.corruptData, 'ZIP 中央目录签名损坏');
      }

      final flags = data.getUint16(cursor + 8, Endian.little);
      if ((flags & _encryptedFlag) != 0) {
        throw const Failure(FailureCode.corruptData, '不支持加密的 ZIP 备份包');
      }

      final methodCode = data.getUint16(cursor + 10, Endian.little);
      final modTime = data.getUint16(cursor + 12, Endian.little);
      final modDate = data.getUint16(cursor + 14, Endian.little);
      final expectedCrc = data.getUint32(cursor + 16, Endian.little);
      final compressedSize = data.getUint32(cursor + 20, Endian.little);
      final uncompressedSize = data.getUint32(cursor + 24, Endian.little);
      final nameLen = data.getUint16(cursor + 28, Endian.little);
      final extraLen = data.getUint16(cursor + 30, Endian.little);
      final commentLen = data.getUint16(cursor + 32, Endian.little);
      final localHeaderOffset = data.getUint32(cursor + 42, Endian.little);

      final headerEnd = cursor + 46 + nameLen + extraLen + commentLen;
      if (headerEnd > cdEnd) {
        throw const Failure(FailureCode.corruptData, 'ZIP 中央目录元数据越界');
      }

      final nameBytes = Uint8List.sublistView(
        archiveBytes,
        cursor + 46,
        cursor + 46 + nameLen,
      );
      final rawName = _decodeEntryName(
        nameBytes,
        isUtf8: (flags & _utf8Flag) != 0,
      );
      cursor = headerEnd;

      if (rawName.endsWith('/')) {
        final dirCheck = rawName.substring(0, rawName.length - 1);
        if (dirCheck.isNotEmpty) {
          validateZipEntryPath(dirCheck);
        }
        continue;
      }

      final safeName = validateZipEntryPath(rawName);
      if (!seenNames.add(safeName)) {
        throw Failure(FailureCode.corruptData, 'ZIP 包含重复文件条目：$safeName');
      }

      final method = ZipCompressionMethod.fromCode(methodCode);

      if (localHeaderOffset + 30 > cdOffset) {
        throw const Failure(FailureCode.corruptData, 'ZIP 本地文件头偏移越界');
      }
      final localSig = data.getUint32(localHeaderOffset, Endian.little);
      if (localSig != _localHeaderSig) {
        throw const Failure(FailureCode.corruptData, 'ZIP 本地文件头签名损坏');
      }
      final localFlags = data.getUint16(localHeaderOffset + 6, Endian.little);
      if ((localFlags & _encryptedFlag) != 0) {
        throw const Failure(FailureCode.corruptData, '不支持加密的 ZIP 备份包');
      }
      // Note: Even if bit 3 (_dataDescriptorFlag) was set in local header by
      // an external archiver, Central Directory carries the authoritative
      // CRC-32, compressedSize, and uncompressedSize.
      final _ = localFlags & _dataDescriptorFlag;

      final localNameLen = data.getUint16(
        localHeaderOffset + 26,
        Endian.little,
      );
      final localExtraLen = data.getUint16(
        localHeaderOffset + 28,
        Endian.little,
      );
      final dataStart = localHeaderOffset + 30 + localNameLen + localExtraLen;
      final dataEnd = dataStart + compressedSize;
      if (dataStart < 0 || dataEnd > cdOffset) {
        throw const Failure(FailureCode.corruptData, 'ZIP 压缩数据区越界');
      }

      final compressedSlice = Uint8List.sublistView(
        archiveBytes,
        dataStart,
        dataEnd,
      );
      final Uint8List uncompressed;
      try {
        uncompressed = switch (method) {
          ZipCompressionMethod.stored => Uint8List.fromList(compressedSlice),
          ZipCompressionMethod.deflate => Uint8List.fromList(
            ZLibCodec(raw: true).decode(compressedSlice),
          ),
        };
      } catch (_) {
        throw Failure(FailureCode.corruptData, '解压文件失败：$safeName');
      }

      if (uncompressed.length != uncompressedSize) {
        throw Failure(FailureCode.corruptData, '文件长度校验失败：$safeName');
      }
      final actualCrc = crc32(uncompressed);
      if (actualCrc != expectedCrc) {
        throw Failure(FailureCode.corruptData, '文件 CRC-32 校验失败：$safeName');
      }

      entries.add(
        ZipEntry(
          name: safeName,
          bytes: uncompressed,
          method: method,
          modifiedAt: _decodeDosDateTime(modTime, modDate),
        ),
      );
    }

    return ZipArchive(entries);
  }

  static int _findEndOfCentralDirectory(Uint8List bytes, ByteData data) {
    final minOffset = bytes.length > 22 + 0xFFFF
        ? bytes.length - 22 - 0xFFFF
        : 0;
    for (var pos = bytes.length - 22; pos >= minOffset; pos--) {
      if (data.getUint32(pos, Endian.little) == _eocdSig) {
        final commentLen = data.getUint16(pos + 20, Endian.little);
        if (pos + 22 + commentLen == bytes.length) {
          return pos;
        }
      }
    }
    throw const Failure(FailureCode.corruptData, '未找到有效的 ZIP 结尾目录记录（EOCD）');
  }

  static String _decodeEntryName(Uint8List bytes, {required bool isUtf8}) {
    try {
      return utf8.decode(bytes, allowMalformed: !isUtf8);
    } on FormatException {
      throw const Failure(FailureCode.corruptData, 'ZIP 文件名 UTF-8 编码损坏');
    }
  }

  static (int, int) _encodeDosDateTime(DateTime dt) {
    final utc = dt.toUtc();
    if (utc.year < 1980) {
      return (0, (1 << 5) | 1);
    }
    final year = (utc.year - 1980).clamp(0, 127);
    final dosDate = (year << 9) | (utc.month << 5) | utc.day;
    final dosTime = (utc.hour << 11) | (utc.minute << 5) | (utc.second ~/ 2);
    return (dosTime, dosDate);
  }

  static DateTime _decodeDosDateTime(int dosTime, int dosDate) {
    final year = ((dosDate >> 9) & 0x7F) + 1980;
    final month = ((dosDate >> 5) & 0x0F).clamp(1, 12);
    final day = (dosDate & 0x1F).clamp(1, 31);
    final hour = ((dosTime >> 11) & 0x1F).clamp(0, 23);
    final minute = ((dosTime >> 5) & 0x3F).clamp(0, 59);
    final second = ((dosTime & 0x1F) * 2).clamp(0, 59);
    return DateTime.utc(year, month, day, hour, minute, second);
  }
}

/// Rejects absolute paths, Windows drive letters, backslashes, NUL bytes, empty
/// segments, and `.` / `..` traversal components (zip-slip defense).
String validateZipEntryPath(String rawPath) {
  if (rawPath.isEmpty) {
    throw const Failure(FailureCode.corruptData, 'ZIP 条目路径不能为空');
  }
  if (rawPath.contains('\x00') || rawPath.contains(r'\')) {
    throw Failure(FailureCode.corruptData, '拒绝不安全的 ZIP 路径：$rawPath');
  }
  if (rawPath.startsWith('/') || RegExp(r'^[a-zA-Z]:').hasMatch(rawPath)) {
    throw Failure(FailureCode.corruptData, '拒绝绝对路径 ZIP 条目：$rawPath');
  }
  final segments = rawPath.split('/');
  for (final seg in segments) {
    if (seg.isEmpty || seg == '.' || seg == '..') {
      throw Failure(FailureCode.corruptData, '拒绝包含路径穿越的 ZIP 条目：$rawPath');
    }
  }
  return rawPath;
}

final Uint32List _crc32Table = (() {
  final table = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      if ((c & 1) != 0) {
        c = 0xEDB88320 ^ (c >>> 1);
      } else {
        c = c >>> 1;
      }
    }
    table[i] = c;
  }
  return table;
})();

/// Computes the exact unsigned 32-bit IEEE 802.3 CRC-32 checksum of [bytes].
int crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (var i = 0; i < bytes.length; i++) {
    crc = _crc32Table[(crc ^ (bytes[i] & 0xFF)) & 0xFF] ^ (crc >>> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
