import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import '../../core/aes_cipher.dart';
import '../../core/failure.dart';
import '../../core/money.dart';

/// Standard 7-byte `.penny` header: `"YYBK\x02\x01\x01"` (`59 59 42 4B 02 01 01`).
final Uint8List pennyMagicHeader = Uint8List.fromList(const <int>[
  0x59,
  0x59,
  0x42,
  0x4B,
  0x02,
  0x01,
  0x01,
]);

/// Fixed 32-byte UTF-8 AES-256 key used by original `.penny` / `.yy` backups.
const String pennyAesKeyString = 'aB3x9ZqW7eR4tY8uI1oP6lK2jH5gF0dS';

/// Fixed 32-byte UTF-8 key bytes.
final Uint8List pennyAesKeyBytes = Uint8List.fromList(
  utf8.encode(pennyAesKeyString),
);

/// Fixed 16-zero-byte CBC IV used by original `.penny` / `.yy` backups.
final Uint8List pennyAesIvBytes = Uint8List(16);

/// All 20 root list keys serialized in an original `.penny` JSON payload.
const List<String> penny20RootListKeys = <String>[
  'books',
  'categories',
  'assets',
  'records',
  'budgets',
  'importPlatforms',
  'installments',
  'periods',
  'reminders',
  'tags',
  'tagRefs',
  'templates',
  'bankCards',
  'wishes',
  'remarks',
  'moneySavePlans',
  'moneySavePlanRecords',
  'assetBookRefs',
  'statStory',
  'autoBillMaps',
];

/// Envelope variant detected when decoding a `.penny` / `.yy` backup.
enum PennyEnvelopeFormat {
  standardYybk,
  legacyBase64Gzip,
  legacyBase64InnerBase64Gzip,
  legacyBase64PlainJson,
}

/// Decoded UTF-8 JSON payload and detected envelope format.
final class DecodedPennyPayload {
  const DecodedPennyPayload({required this.jsonText, required this.format});

  final String jsonText;
  final PennyEnvelopeFormat format;
}

/// Decrypts and decompresses an original `.penny` / `.yy` backup file (`R1`).
///
/// - Standard format: 7-byte header `59 59 42 4B 02 01 01` + AES-256-CBC/PKCS#7
///   ciphertext + GZIP-compressed UTF-8 JSON.
/// - Legacy fallback (only when first 4 bytes != `"YYBK"`): outer Base64 ->
///   AES-256-CBC/PKCS#7 -> GZIP (or inner Base64 -> GZIP / plain JSON).
DecodedPennyPayload decodePennyBytes(
  Uint8List bytes, {
  Uint8List? keyOverride,
  Uint8List? ivOverride,
}) {
  if (bytes.isEmpty) {
    throw const Failure(FailureCode.corruptData, '备份文件为空或已损坏');
  }
  final key = keyOverride ?? pennyAesKeyBytes;
  final iv = ivOverride ?? pennyAesIvBytes;

  final hasYybkPrefix =
      bytes.length >= 4 &&
      bytes[0] == 0x59 &&
      bytes[1] == 0x59 &&
      bytes[2] == 0x42 &&
      bytes[3] == 0x4B;

  if (hasYybkPrefix) {
    if (bytes.length <= pennyMagicHeader.length ||
        bytes[4] != 0x02 ||
        bytes[5] != 0x01 ||
        bytes[6] != 0x01) {
      throw const Failure(FailureCode.corruptData, '备份文件头版本不支持或已截断');
    }
    final ciphertext = Uint8List.sublistView(bytes, pennyMagicHeader.length);
    final decrypted = _decryptAesCbc(ciphertext, key: key, iv: iv);
    if (!_hasGzipMagic(decrypted)) {
      throw const Failure(FailureCode.corruptData, '备份文件解压失败，缺少 GZIP 头');
    }
    final jsonText = _gunzipUtf8(decrypted);
    return DecodedPennyPayload(
      jsonText: jsonText,
      format: PennyEnvelopeFormat.standardYybk,
    );
  }

  // Legacy fallback: outer Base64 -> AES-256-CBC/PKCS#7.
  final outerCiphertext = _tryDecodeBase64Bytes(bytes);
  if (outerCiphertext == null || outerCiphertext.isEmpty) {
    throw const Failure(FailureCode.corruptData, '无法识别的备份文件格式或文件已损坏');
  }
  final decrypted = _decryptAesCbc(outerCiphertext, key: key, iv: iv);
  if (_hasGzipMagic(decrypted)) {
    return DecodedPennyPayload(
      jsonText: _gunzipUtf8(decrypted),
      format: PennyEnvelopeFormat.legacyBase64Gzip,
    );
  }

  final String outerText;
  try {
    outerText = utf8.decode(decrypted, allowMalformed: false).trim();
  } on FormatException {
    throw const Failure(FailureCode.corruptData, '备份文件解密载荷已损坏');
  }
  if (outerText.startsWith('{')) {
    return DecodedPennyPayload(
      jsonText: outerText,
      format: PennyEnvelopeFormat.legacyBase64PlainJson,
    );
  }

  final innerDecoded = _tryDecodeBase64String(outerText);
  if (innerDecoded != null && innerDecoded.isNotEmpty) {
    if (_hasGzipMagic(innerDecoded)) {
      return DecodedPennyPayload(
        jsonText: _gunzipUtf8(innerDecoded),
        format: PennyEnvelopeFormat.legacyBase64InnerBase64Gzip,
      );
    }
    try {
      final innerText = utf8.decode(innerDecoded, allowMalformed: false).trim();
      if (innerText.startsWith('{')) {
        return DecodedPennyPayload(
          jsonText: innerText,
          format: PennyEnvelopeFormat.legacyBase64PlainJson,
        );
      }
    } on FormatException {
      // Fall through to uniform corruptData error below.
    }
  }

  throw const Failure(FailureCode.corruptData, '备份文件格式过旧或数据已损坏');
}

/// Builds an authentic encrypted `.penny` (or legacy Base64 `.yy`) byte buffer
/// for golden-vector, service, and widget tests.
///
/// [jsonOrText] may be a raw JSON [String] (preserving exact decimal lexemes)
/// or a JSON-encodable `Map<String, Object?>`.
Uint8List encodePennyForTest(
  Object jsonOrText, {
  bool legacyBase64 = false,
  bool innerBase64 = false,
  Uint8List? keyOverride,
  Uint8List? ivOverride,
}) {
  final String jsonText;
  if (jsonOrText is String) {
    jsonText = jsonOrText;
  } else if (jsonOrText is Map) {
    jsonText = encodeLosslessJson(jsonOrText);
  } else {
    throw ArgumentError.value(
      jsonOrText,
      'jsonOrText',
      'Must be a JSON String or Map',
    );
  }

  final compressed = Uint8List.fromList(gzip.encode(utf8.encode(jsonText)));
  final Uint8List plaintext;
  if (legacyBase64 && innerBase64) {
    plaintext = Uint8List.fromList(utf8.encode(base64.encode(compressed)));
  } else {
    plaintext = compressed;
  }

  final encrypted = aesCbcEncryptPkcs7(
    key: keyOverride ?? pennyAesKeyBytes,
    iv: ivOverride ?? pennyAesIvBytes,
    plaintext: plaintext,
  );

  if (legacyBase64) {
    return Uint8List.fromList(utf8.encode(base64.encode(encrypted)));
  }

  final out = Uint8List(pennyMagicHeader.length + encrypted.length);
  out.setRange(0, pennyMagicHeader.length, pennyMagicHeader);
  out.setRange(pennyMagicHeader.length, out.length, encrypted);
  return out;
}

Uint8List _decryptAesCbc(
  Uint8List ciphertext, {
  required Uint8List key,
  required Uint8List iv,
}) {
  try {
    return aesCbcDecryptPkcs7(key: key, iv: iv, ciphertext: ciphertext);
  } on FormatException {
    throw const Failure(FailureCode.corruptData, '备份文件解密失败，密钥不匹配或文件已损坏');
  } on ArgumentError {
    throw const Failure(FailureCode.corruptData, '备份解密参数无效');
  }
}

bool _hasGzipMagic(Uint8List bytes) =>
    bytes.length >= 2 && bytes[0] == 0x1F && bytes[1] == 0x8B;

String _gunzipUtf8(Uint8List compressed) {
  final List<int> raw;
  try {
    raw = gzip.decode(compressed);
  } catch (_) {
    throw const Failure(FailureCode.corruptData, '备份压缩包解压失败，文件已损坏');
  }
  try {
    return utf8.decode(raw, allowMalformed: false);
  } on FormatException {
    throw const Failure(FailureCode.corruptData, '备份文本编码损坏');
  }
}

Uint8List? _tryDecodeBase64Bytes(Uint8List rawBytes) {
  final String text;
  try {
    text = utf8.decode(rawBytes, allowMalformed: false);
  } on FormatException {
    return null;
  }
  return _tryDecodeBase64String(text);
}

Uint8List? _tryDecodeBase64String(String rawText) {
  final compact = rawText.replaceAll(RegExp(r'\s+'), '');
  if (compact.isEmpty) return null;
  final normalized = compact.replaceAll('-', '+').replaceAll('_', '/');
  final rem = normalized.length % 4;
  if (rem == 1) return null;
  final padded = rem == 0
      ? normalized
      : normalized.padRight(normalized.length + (4 - rem), '=');
  try {
    return base64.decode(padded);
  } on FormatException {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Lossless RFC 8259 JSON Lexeme Reader & Writer (ZERO IEEE-754 double usage)
// ---------------------------------------------------------------------------

/// Raw JSON numeric token preserving exact decimal characters without touching
/// IEEE-754 floating point.
final class JsonNumber {
  const JsonNumber(this.lexeme);

  final String lexeme;

  @override
  bool operator ==(Object other) =>
      other is JsonNumber && other.lexeme == lexeme;

  @override
  int get hashCode => lexeme.hashCode;

  @override
  String toString() => lexeme;
}

/// Parses [source] into `Map<String, Object?>`, `List<Object?>`, `String`,
/// `bool`, `int` (for exact 64-bit integer tokens), `JsonNumber` (for decimals,
/// scientific notation, or >64-bit integers), and `null`.
Object? parseLosslessJson(String source) {
  final reader = _LosslessJsonReader(source);
  final value = reader.readRoot();
  return value;
}

/// Serializes a lossless JSON tree back to compact RFC 8259 JSON text,
/// emitting [JsonNumber] lexemes verbatim.
String encodeLosslessJson(Object? value) {
  final buffer = StringBuffer();
  _writeLosslessJson(buffer, value);
  return buffer.toString();
}

void _writeLosslessJson(StringBuffer out, Object? value) {
  if (value == null) {
    out.write('null');
  } else if (value is bool) {
    out.write(value ? 'true' : 'false');
  } else if (value is int || value is BigInt) {
    out.write(value.toString());
  } else if (value is JsonNumber) {
    out.write(value.lexeme);
  } else if (value is String) {
    out.write(jsonEncode(value));
  } else if (value is List) {
    out.write('[');
    for (var i = 0; i < value.length; i++) {
      if (i > 0) out.write(',');
      _writeLosslessJson(out, value[i]);
    }
    out.write(']');
  } else if (value is Map) {
    out.write('{');
    var first = true;
    for (final entry in value.entries) {
      if (!first) out.write(',');
      first = false;
      out.write(jsonEncode(entry.key.toString()));
      out.write(':');
      _writeLosslessJson(out, entry.value);
    }
    out.write('}');
  } else {
    out.write(jsonEncode(value));
  }
}

final class _LosslessJsonReader {
  _LosslessJsonReader(this._src) : _len = _src.length;

  final String _src;
  final int _len;
  int _pos = 0;

  Object? readRoot() {
    _skipWs();
    if (_pos >= _len) {
      throw const FormatException('Empty JSON input');
    }
    final root = _readValue();
    _skipWs();
    if (_pos != _len) {
      throw FormatException('Unexpected trailing character at $_pos');
    }
    return root;
  }

  void _skipWs() {
    while (_pos < _len) {
      final c = _src.codeUnitAt(_pos);
      if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) {
        _pos++;
      } else {
        break;
      }
    }
  }

  Object? _readValue() {
    _skipWs();
    if (_pos >= _len) {
      throw const FormatException('Unexpected end of JSON');
    }
    final c = _src.codeUnitAt(_pos);
    return switch (c) {
      0x7B => _readObject(), // '{'
      0x5B => _readArray(), // '['
      0x22 => _readString(), // '"'
      0x74 => _readLiteral('true', true), // 't'
      0x66 => _readLiteral('false', false), // 'f'
      0x6E => _readLiteral('null', null), // 'n'
      _ => _readNumber(),
    };
  }

  Map<String, Object?> _readObject() {
    _pos++; // '{'
    _skipWs();
    final map = <String, Object?>{};
    if (_pos < _len && _src.codeUnitAt(_pos) == 0x7D) {
      _pos++;
      return map;
    }
    while (true) {
      _skipWs();
      if (_pos >= _len || _src.codeUnitAt(_pos) != 0x22) {
        throw FormatException('Expected string key at $_pos');
      }
      final key = _readString();
      _skipWs();
      if (_pos >= _len || _src.codeUnitAt(_pos) != 0x3A) {
        throw FormatException('Expected ":" at $_pos');
      }
      _pos++; // ':'
      final val = _readValue();
      map[key] = val;
      _skipWs();
      if (_pos >= _len) {
        throw const FormatException('Unterminated JSON object');
      }
      final sep = _src.codeUnitAt(_pos);
      if (sep == 0x7D) {
        _pos++;
        return map;
      }
      if (sep != 0x2C) {
        throw FormatException('Expected "," or "}" at $_pos');
      }
      _pos++; // ','
    }
  }

  List<Object?> _readArray() {
    _pos++; // '['
    _skipWs();
    final list = <Object?>[];
    if (_pos < _len && _src.codeUnitAt(_pos) == 0x5D) {
      _pos++;
      return list;
    }
    while (true) {
      list.add(_readValue());
      _skipWs();
      if (_pos >= _len) {
        throw const FormatException('Unterminated JSON array');
      }
      final sep = _src.codeUnitAt(_pos);
      if (sep == 0x5D) {
        _pos++;
        return list;
      }
      if (sep != 0x2C) {
        throw FormatException('Expected "," or "]" at $_pos');
      }
      _pos++; // ','
    }
  }

  String _readString() {
    _pos++; // opening '"'
    final start = _pos;
    var hasEscape = false;
    while (_pos < _len) {
      final c = _src.codeUnitAt(_pos);
      if (c == 0x22) {
        final rawSlice = _src.substring(start, _pos);
        _pos++;
        if (!hasEscape) return rawSlice;
        return _unescapeString(rawSlice);
      }
      if (c == 0x5C) {
        hasEscape = true;
        _pos += 2;
        continue;
      }
      if (c < 0x20) {
        throw FormatException('Unescaped control character in string at $_pos');
      }
      _pos++;
    }
    throw const FormatException('Unterminated JSON string');
  }

  String _unescapeString(String escaped) {
    final sb = StringBuffer();
    var i = 0;
    while (i < escaped.length) {
      final c = escaped.codeUnitAt(i);
      if (c != 0x5C) {
        sb.writeCharCode(c);
        i++;
        continue;
      }
      i++;
      if (i >= escaped.length) {
        throw const FormatException('Dangling escape in JSON string');
      }
      final esc = escaped.codeUnitAt(i);
      i++;
      switch (esc) {
        case 0x22:
          sb.write('"');
        case 0x5C:
          sb.write(r'\');
        case 0x2F:
          sb.write('/');
        case 0x62:
          sb.write('\b');
        case 0x66:
          sb.write('\f');
        case 0x6E:
          sb.write('\n');
        case 0x72:
          sb.write('\r');
        case 0x74:
          sb.write('\t');
        case 0x75:
          if (i + 4 > escaped.length) {
            throw const FormatException('Invalid unicode escape');
          }
          final unit = int.parse(escaped.substring(i, i + 4), radix: 16);
          i += 4;
          sb.writeCharCode(unit);
        default:
          throw FormatException('Invalid escape \\${String.fromCharCode(esc)}');
      }
    }
    return sb.toString();
  }

  Object? _readLiteral(String expected, Object? result) {
    if (_src.startsWith(expected, _pos)) {
      _pos += expected.length;
      return result;
    }
    throw FormatException('Invalid JSON literal at $_pos');
  }

  Object _readNumber() {
    final start = _pos;
    var isDecimalOrExp = false;

    if (_pos < _len && _src.codeUnitAt(_pos) == 0x2D) {
      _pos++;
    }
    if (_pos >= _len) {
      throw FormatException('Invalid number at $start');
    }
    final firstDigit = _src.codeUnitAt(_pos);
    if (firstDigit == 0x30) {
      _pos++;
    } else if (firstDigit >= 0x31 && firstDigit <= 0x39) {
      _pos++;
      while (_pos < _len && _isDigit(_src.codeUnitAt(_pos))) {
        _pos++;
      }
    } else {
      throw FormatException('Invalid number at $start');
    }

    if (_pos < _len && _src.codeUnitAt(_pos) == 0x2E) {
      isDecimalOrExp = true;
      _pos++;
      if (_pos >= _len || !_isDigit(_src.codeUnitAt(_pos))) {
        throw FormatException('Invalid fraction in number at $start');
      }
      while (_pos < _len && _isDigit(_src.codeUnitAt(_pos))) {
        _pos++;
      }
    }

    if (_pos < _len) {
      final e = _src.codeUnitAt(_pos);
      if (e == 0x65 || e == 0x45) {
        isDecimalOrExp = true;
        _pos++;
        if (_pos < _len) {
          final sign = _src.codeUnitAt(_pos);
          if (sign == 0x2B || sign == 0x2D) _pos++;
        }
        if (_pos >= _len || !_isDigit(_src.codeUnitAt(_pos))) {
          throw FormatException('Invalid exponent in number at $start');
        }
        while (_pos < _len && _isDigit(_src.codeUnitAt(_pos))) {
          _pos++;
        }
      }
    }

    final lexeme = _src.substring(start, _pos);
    if (!isDecimalOrExp) {
      final asInt = int.tryParse(lexeme);
      if (asInt != null && !(lexeme.startsWith('-0'))) {
        return asInt;
      }
    }
    return JsonNumber(lexeme);
  }

  static bool _isDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;
}

// ---------------------------------------------------------------------------
// Exact Decimal -> int64 Minor-Unit Conversion & Embedded JSON Cleaners
// ---------------------------------------------------------------------------

final RegExp _decimalOrSciPattern = RegExp(
  r'^([+-]?)(?:([0-9]+)(?:\.([0-9]*))?|\.([0-9]+))(?:[eE]([+-]?[0-9]+))?$',
);

/// Parses a decimal or scientific-notation lexeme into an exact [DecimalValue]
/// without IEEE-754 floating-point intermediate values.
DecimalValue parsePennyDecimalLexeme(String rawLexeme) {
  final trimmed = rawLexeme.trim();
  final match = _decimalOrSciPattern.firstMatch(trimmed);
  if (match == null) {
    throw Failure(FailureCode.corruptData, '金额格式非法: $rawLexeme');
  }
  final negative = match.group(1) == '-';
  final intPart = match.group(2) ?? '0';
  final fracPart = match.group(3) ?? match.group(4) ?? '';
  final expText = match.group(5);
  final exp = expText == null ? 0 : int.parse(expText);

  final digits = '$intPart$fracPart';
  var coeff = BigInt.parse(negative ? '-$digits' : digits);
  if (coeff == BigInt.zero) {
    return DecimalValue(BigInt.zero, 0);
  }

  var scale = fracPart.length - exp;
  if (scale < 0) {
    final shift = -scale;
    if (shift > 30) {
      throw const Failure(FailureCode.validation, '金额超出可存储范围');
    }
    coeff *= powerOfTen(shift);
    scale = 0;
  } else if (scale > 30) {
    final extra = scale - 30;
    coeff = divideRounded(
      coeff,
      BigInt.from(10).pow(extra),
      RoundingMode.halfUp,
    );
    scale = 30;
  }
  return DecimalValue(coeff, scale);
}

/// Converts a raw decimal lexeme (in major currency units, e.g. `"1234.56"` or
/// `"12.345"`) to validated signed `int64` minor units (`123456`, `1235`) using
/// `HALF_UP` rounding.
BigInt decimalLexemeToMinor(String lexeme) {
  final decimal = parsePennyDecimalLexeme(lexeme);
  final minorUnits = decimal.unitsAt(
    Money.ledgerScale,
    rounding: RoundingMode.halfUp,
  );
  return Money.minor(minorUnits).storageMinor;
}

/// Converts a `.penny` major-unit field ([int], [BigInt], [JsonNumber], or
/// [String]) to `int64` minor units (`HALF_UP`).
BigInt pennyMajorToMinor(
  Object? raw, {
  BigInt? defaultMinor,
  String fieldName = 'money',
}) {
  if (raw == null) {
    if (defaultMinor != null) return defaultMinor;
    throw Failure(FailureCode.corruptData, '缺少金额字段 $fieldName');
  }
  if (raw is int) {
    return Money.minor(BigInt.from(raw) * BigInt.from(100)).storageMinor;
  }
  if (raw is BigInt) {
    return Money.minor(raw * BigInt.from(100)).storageMinor;
  }
  if (raw is JsonNumber) {
    return decimalLexemeToMinor(raw.lexeme);
  }
  if (raw is String) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      if (defaultMinor != null) return defaultMinor;
      throw Failure(FailureCode.corruptData, '空金额字段 $fieldName');
    }
    return decimalLexemeToMinor(trimmed);
  }
  throw Failure(FailureCode.corruptData, '非法金额字段 $fieldName');
}

/// Nullable variant of [pennyMajorToMinor].
BigInt? pennyNullableMajorToMinor(Object? raw, {String fieldName = 'money'}) {
  if (raw == null) return null;
  if (raw is String && raw.trim().isEmpty) return null;
  return pennyMajorToMinor(raw, fieldName: fieldName);
}

/// Converts an embedded JSON money value:
/// - JSON numbers (`int`, `JsonNumber`, `BigInt`) and decimal/scientific strings
///   are major-unit values from original Gson -> converted `HALF_UP` to minor
///   string.
/// - Pure integer strings (`"12345"`) are already minor-unit strings ->
///   validated and preserved as `"12345"`.
String? _embeddedMoneyToMinorString(Object? raw) {
  if (raw == null) return null;
  if (raw is int) {
    return Money.minor(
      BigInt.from(raw) * BigInt.from(100),
    ).storageMinor.toString();
  }
  if (raw is BigInt) {
    return Money.minor(raw * BigInt.from(100)).storageMinor.toString();
  }
  if (raw is JsonNumber) {
    return decimalLexemeToMinor(raw.lexeme).toString();
  }
  if (raw is String) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    if (RegExp(r'^-?[0-9]+$').hasMatch(trimmed)) {
      return Money.minor(BigInt.parse(trimmed)).storageMinor.toString();
    }
    return decimalLexemeToMinor(trimmed).toString();
  }
  throw const Failure(FailureCode.corruptData, '内嵌金额字段格式损坏');
}

void _convertMapMoneyKeys(Map<String, Object?> map, List<String> keys) {
  for (final key in keys) {
    if (!map.containsKey(key)) continue;
    final val = map[key];
    if (val == null) continue;
    final converted = _embeddedMoneyToMinorString(val);
    if (converted != null) {
      map[key] = converted;
    }
  }
}

Map<String, Object?>? _decodeEmbeddedMap(Object? raw, String label) {
  if (raw == null) return null;
  if (raw is Map) {
    return <String, Object?>{
      for (final e in raw.entries) e.key.toString(): e.value,
    };
  }
  if (raw is String) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final Object? parsed;
    try {
      parsed = parseLosslessJson(trimmed);
    } on FormatException {
      throw Failure(FailureCode.corruptData, '$label JSON 格式损坏');
    }
    if (parsed == null) return null;
    if (parsed is! Map<String, Object?>) {
      throw Failure(FailureCode.corruptData, '$label 须为 JSON 对象');
    }
    return parsed;
  }
  throw Failure(FailureCode.corruptData, '$label 字段类型非法');
}

/// Converts embedded REAL amounts in `record.extra_info`:
/// - `curr`: `sm`, `am`, `bm`, `dam`, `dbm`, `sd`, `ad` -> minor-unit strings
/// - `adbi`: `advanceMoney`, `advanceDiffMoney` -> minor-unit strings
/// - `adv`: scalar number -> minor-unit string, or Map (`advanceMoney`,
///   `advanceDiffMoney`, `money`, `m`, `diff` -> minor-unit strings)
/// - legacy flat root `advanceMoney`, `advanceDiffMoney` -> minor-unit strings
String? convertRecordExtraJson(Object? raw) {
  final map = _decodeEmbeddedMap(raw, 'record.extra_info');
  if (map == null) return null;

  final curr = map['curr'];
  if (curr is Map) {
    final currMap = <String, Object?>{
      for (final e in curr.entries) e.key.toString(): e.value,
    };
    _convertMapMoneyKeys(currMap, const <String>[
      'sm',
      'am',
      'bm',
      'dam',
      'dbm',
      'sd',
      'ad',
    ]);
    map['curr'] = currMap;
  }

  final adbi = map['adbi'];
  if (adbi is Map) {
    final adbiMap = <String, Object?>{
      for (final e in adbi.entries) e.key.toString(): e.value,
    };
    _convertMapMoneyKeys(adbiMap, const <String>[
      'advanceMoney',
      'advanceDiffMoney',
    ]);
    map['adbi'] = adbiMap;
  }

  final adv = map['adv'];
  if (adv is Map) {
    final advMap = <String, Object?>{
      for (final e in adv.entries) e.key.toString(): e.value,
    };
    _convertMapMoneyKeys(advMap, const <String>[
      'advanceMoney',
      'advanceDiffMoney',
      'money',
      'm',
      'diff',
    ]);
    map['adv'] = advMap;
  } else if (adv is int || adv is JsonNumber || adv is BigInt) {
    map['adv'] = _embeddedMoneyToMinorString(adv);
  }

  _convertMapMoneyKeys(map, const <String>['advanceMoney', 'advanceDiffMoney']);

  return encodeLosslessJson(map);
}

/// Converts embedded REAL amounts in `record.rel_info`:
/// - `lrefundi.rfbinfo[*]`: `lbm`, `am`, `bm` -> minor-unit strings
/// - `lreimbursei.ribinfo[*]`: `lbm`, `am`, `bm` -> minor-unit strings
/// - `ltfeei.tfbinfo`: `lbm`, `am`, `bm` -> minor-unit strings
String? convertRecordRelJson(Object? raw) {
  final map = _decodeEmbeddedMap(raw, 'record.rel_info');
  if (map == null) return null;

  void convertLinkBlock(String blockKey, String listKey) {
    final block = map[blockKey];
    if (block is! Map) return;
    final blockMap = <String, Object?>{
      for (final e in block.entries) e.key.toString(): e.value,
    };
    final list = blockMap[listKey];
    if (list is List) {
      blockMap[listKey] = <Object?>[
        for (final item in list)
          if (item is Map) _convertLinkedBillMap(item) else item,
      ];
    }
    map[blockKey] = blockMap;
  }

  convertLinkBlock('lrefundi', 'rfbinfo');
  convertLinkBlock('lreimbursei', 'ribinfo');

  final ltfeei = map['ltfeei'];
  if (ltfeei is Map) {
    final feeMap = <String, Object?>{
      for (final e in ltfeei.entries) e.key.toString(): e.value,
    };
    final tfbinfo = feeMap['tfbinfo'];
    if (tfbinfo is Map) {
      feeMap['tfbinfo'] = _convertLinkedBillMap(tfbinfo);
    }
    map['ltfeei'] = feeMap;
  }

  return encodeLosslessJson(map);
}

Map<String, Object?> _convertLinkedBillMap(Map<dynamic, dynamic> raw) {
  final m = <String, Object?>{
    for (final e in raw.entries) e.key.toString(): e.value,
  };
  _convertMapMoneyKeys(m, const <String>['lbm', 'am', 'bm']);
  return m;
}

/// Converts embedded REAL amounts in `asset.credit_info`:
/// - `inst[*]`: `b`, `i` -> minor-unit strings
/// - `installment`: legacy scalar -> minor-unit string
String? convertAssetCreditJson(Object? raw) {
  final map = _decodeEmbeddedMap(raw, 'asset.credit_info');
  if (map == null) return null;

  final inst = map['inst'];
  if (inst is List) {
    map['inst'] = <Object?>[
      for (final item in inst)
        if (item is Map)
          () {
            final itemMap = <String, Object?>{
              for (final e in item.entries) e.key.toString(): e.value,
            };
            _convertMapMoneyKeys(itemMap, const <String>['b', 'i']);
            return itemMap;
          }()
        else
          item,
    ];
  }

  _convertMapMoneyKeys(map, const <String>['installment']);
  return encodeLosslessJson(map);
}

/// Converts embedded REAL amounts in `asset.extra_info`:
/// - `temp_amt[*]`: `m` -> minor-unit string
String? convertAssetExtraJson(Object? raw) {
  final map = _decodeEmbeddedMap(raw, 'asset.extra_info');
  if (map == null) return null;

  final tempAmt = map['temp_amt'];
  if (tempAmt is List) {
    map['temp_amt'] = <Object?>[
      for (final item in tempAmt)
        if (item is Map)
          () {
            final itemMap = <String, Object?>{
              for (final e in item.entries) e.key.toString(): e.value,
            };
            _convertMapMoneyKeys(itemMap, const <String>['m']);
            return itemMap;
          }()
        else
          item,
    ];
  }

  return encodeLosslessJson(map);
}

/// Converts embedded REAL amounts in `asset.loan_info`:
/// - `totalDebtMoney` -> minor-unit string
/// - `sb` -> minor-unit string
/// - `cp[*]`: `pb`, `tp` -> minor-unit strings
String? convertAssetLoanJson(Object? raw) {
  final map = _decodeEmbeddedMap(raw, 'asset.loan_info');
  if (map == null) return null;

  _convertMapMoneyKeys(map, const <String>['totalDebtMoney', 'sb']);

  final cp = map['cp'];
  if (cp is List) {
    map['cp'] = <Object?>[
      for (final item in cp)
        if (item is Map)
          () {
            final itemMap = <String, Object?>{
              for (final e in item.entries) e.key.toString(): e.value,
            };
            _convertMapMoneyKeys(itemMap, const <String>['pb', 'tp']);
            return itemMap;
          }()
        else
          item,
    ];
  }

  return encodeLosslessJson(map);
}

/// Converts embedded REAL amounts in `asset.fixed_deposit_info` (JSON array):
/// - `money` -> `money_minor`
/// - `expected_income` -> `expected_income_minor`
/// - `am` -> `am_minor`
/// - `bm` -> `bm_minor`
/// - `annual_rate` -> exact decimal string (without multiplying by 100)
String? convertAssetFixedDepositJson(Object? raw) {
  if (raw == null) return null;
  final List<Object?> list;
  if (raw is List) {
    list = List<Object?>.from(raw);
  } else if (raw is String) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final Object? parsed;
    try {
      parsed = parseLosslessJson(trimmed);
    } on FormatException {
      throw const Failure(FailureCode.corruptData, '定期存款 JSON 格式损坏');
    }
    if (parsed == null) return null;
    if (parsed is! List<Object?>) {
      throw const Failure(FailureCode.corruptData, '定期存款字段须为 JSON 数组');
    }
    list = parsed;
  } else {
    throw const Failure(FailureCode.corruptData, '定期存款字段类型非法');
  }

  final convertedList = <Object?>[];
  for (final item in list) {
    if (item is! Map) {
      throw const Failure(FailureCode.corruptData, '定期存款条目格式损坏');
    }
    final m = <String, Object?>{
      for (final e in item.entries) e.key.toString(): e.value,
    };

    void migrateDepositMoney(
      String majorKey,
      String minorKey, {
      required BigInt defaultMinor,
    }) {
      if (m[minorKey] != null) {
        final existing = m[minorKey];
        if (existing is String &&
            RegExp(r'^-?[0-9]+$').hasMatch(existing.trim())) {
          m[minorKey] = Money.minor(
            BigInt.parse(existing.trim()),
          ).storageMinor.toString();
        } else {
          m[minorKey] = pennyMajorToMinor(
            existing,
            defaultMinor: defaultMinor,
            fieldName: minorKey,
          ).toString();
        }
      } else if (m[majorKey] != null) {
        m[minorKey] = pennyMajorToMinor(
          m[majorKey],
          defaultMinor: defaultMinor,
          fieldName: majorKey,
        ).toString();
      } else {
        m[minorKey] = defaultMinor.toString();
      }
      m.remove(majorKey);
    }

    migrateDepositMoney('money', 'money_minor', defaultMinor: BigInt.zero);
    migrateDepositMoney(
      'expected_income',
      'expected_income_minor',
      defaultMinor: BigInt.zero,
    );
    migrateDepositMoney('am', 'am_minor', defaultMinor: BigInt.zero);
    migrateDepositMoney('bm', 'bm_minor', defaultMinor: BigInt.zero);

    final rate = m['annual_rate'];
    if (rate is JsonNumber) {
      final dec = parsePennyDecimalLexeme(rate.lexeme);
      m['annual_rate'] = _formatExactDecimal(dec);
    } else if (rate is int) {
      m['annual_rate'] = rate.toString();
    } else if (rate is String) {
      final trimmed = rate.trim();
      if (trimmed.isNotEmpty) {
        final dec = parsePennyDecimalLexeme(trimmed);
        m['annual_rate'] = _formatExactDecimal(dec);
      }
    }

    convertedList.add(m);
  }
  return encodeLosslessJson(convertedList);
}

String _formatExactDecimal(DecimalValue value) {
  if (value.scale == 0) return value.coefficient.toString();
  final neg = value.coefficient.isNegative;
  final digits = value.coefficient.abs().toString().padLeft(
    value.scale + 1,
    '0',
  );
  final head = digits.substring(0, digits.length - value.scale);
  final tail = digits.substring(digits.length - value.scale);
  var out = '${neg ? '-' : ''}$head.$tail';
  out = out.replaceFirst(RegExp(r'0+$'), '');
  if (out.endsWith('.')) out = out.substring(0, out.length - 1);
  if (out == '-0') out = '0';
  return out;
}

/// Converts embedded `base` REAL amount in `budget.extra_info`.
String? convertBudgetExtraJson(Object? raw) {
  final map = _decodeEmbeddedMap(raw, 'budget.extra_info');
  if (map == null) return null;
  _convertMapMoneyKeys(map, const <String>['base']);
  return encodeLosslessJson(map);
}

/// Converts optional embedded settlement amounts in `installment.exi`.
String? convertInstallmentExtraJson(Object? raw) {
  final map = _decodeEmbeddedMap(raw, 'installment.exi');
  if (map == null) return null;
  _convertMapMoneyKeys(map, const <String>[
    'settled_principal',
    'settled_fee',
    'waived_fee',
  ]);
  return encodeLosslessJson(map);
}

String? _passthroughJsonOrText(Object? raw, String label) {
  if (raw == null) return null;
  if (raw is String) {
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : raw;
  }
  if (raw is Map || raw is List) {
    return encodeLosslessJson(raw);
  }
  throw Failure(FailureCode.corruptData, '$label 字段格式非法');
}

// ---------------------------------------------------------------------------
// 20-Table Staged Domain Models & Staging Pipeline (R2, R3, R6, §6.2)
// ---------------------------------------------------------------------------

final class StagedAccountBook {
  const StagedAccountBook({
    required this.id,
    required this.type,
    required this.name,
    required this.cover,
    required this.sort,
    required this.status,
    required this.startDay,
    required this.createDate,
    required this.displayWay,
    this.extraInfo,
  });

  final int id;
  final int type;
  final String name;
  final String cover;
  final int sort;
  final int status;
  final int startDay;
  final int createDate;
  final int displayWay;
  final String? extraInfo;
}

final class StagedRecordCategory {
  const StagedRecordCategory({
    this.id,
    required this.name,
    required this.icon,
    required this.type,
    required this.sort,
    required this.parentCatId,
    this.colorFill,
    required this.platformId,
    required this.accountBookId,
    required this.isHide,
    this.extraInfo,
  });

  final int? id;
  final String name;
  final String icon;
  final int type;
  final int sort;
  final int parentCatId;
  final String? colorFill;
  final int platformId;
  final int accountBookId;
  final bool isHide;
  final String? extraInfo;
}

final class StagedAsset {
  const StagedAsset({
    this.id,
    required this.name,
    required this.balanceMinor,
    required this.type,
    required this.subType,
    required this.createDate,
    required this.sort,
    required this.icon,
    this.remark,
    required this.initMoneyMinor,
    required this.isDefault,
    required this.isEffectiveAsset,
    required this.usedTimes,
    this.color,
    required this.status,
    this.extraInfo,
    this.loanInfo,
    this.creditInfo,
    this.fixedDepositInfo,
    this.groupName,
    this.currency,
  });

  final int? id;
  final String name;
  final BigInt balanceMinor;
  final int type;
  final int subType;
  final int createDate;
  final int sort;
  final String icon;
  final String? remark;
  final BigInt initMoneyMinor;
  final bool isDefault;
  final int isEffectiveAsset;
  final int usedTimes;
  final String? color;
  final int status;
  final String? extraInfo;
  final String? loanInfo;
  final String? creditInfo;
  final String? fixedDepositInfo;
  final String? groupName;
  final String? currency;
}

final class StagedRecord {
  const StagedRecord({
    required this.recordId,
    required this.type,
    required this.subType,
    required this.moneyMinor,
    required this.remark,
    required this.recordTime,
    required this.recordCatId,
    required this.assetId,
    required this.fromAssetId,
    required this.toAssetId,
    required this.accountBookId,
    required this.excludeBudget,
    required this.excludeExIn,
    required this.platformId,
    required this.periodId,
    this.installment,
    this.images,
    this.relInfo,
    this.discountMinor,
    this.extraInfo,
    this.createDate,
  });

  final String recordId;
  final int type;
  final int subType;
  final BigInt moneyMinor;
  final String remark;
  final int recordTime;
  final int recordCatId;
  final int assetId;
  final int fromAssetId;
  final int toAssetId;
  final int accountBookId;
  final bool excludeBudget;
  final bool excludeExIn;
  final int platformId;
  final int periodId;
  final String? installment;
  final String? images;
  final String? relInfo;
  final BigInt? discountMinor;
  final String? extraInfo;
  final int? createDate;
}

final class StagedBudget {
  const StagedBudget({
    required this.id,
    required this.budgetType,
    required this.recordCatId,
    required this.amountMinor,
    required this.bookId,
    required this.section,
    required this.sort,
    required this.createDate,
    this.remark,
    this.extraInfo,
  });

  final int id;
  final int budgetType;
  final int recordCatId;
  final BigInt amountMinor;
  final int bookId;
  final String section;
  final int sort;
  final int createDate;
  final String? remark;
  final String? extraInfo;
}

final class StagedImportPlatform {
  const StagedImportPlatform({
    this.id,
    required this.platform,
    required this.importRecordCount,
    required this.importCategoryCount,
    required this.importTime,
    required this.hidden,
  });

  final int? id;
  final String platform;
  final int importRecordCount;
  final int importCategoryCount;
  final int importTime;
  final bool hidden;
}

final class StagedInstallment {
  const StagedInstallment({
    this.id,
    required this.name,
    required this.catId,
    required this.principalMinor,
    required this.periods,
    required this.chargeMinor,
    required this.chargeWay,
    required this.remainderIn,
    required this.calWay,
    required this.startDate,
    required this.assetId,
    required this.nextPeriod,
    required this.nextPeriodDate,
    this.credited,
    required this.bookId,
    required this.excludeBudget,
    required this.excludeExIn,
    required this.createDate,
    this.tags,
    this.images,
    this.exi,
  });

  final int? id;
  final String name;
  final int catId;
  final BigInt principalMinor;
  final int periods;
  final BigInt chargeMinor;
  final int chargeWay;
  final int remainderIn;
  final int calWay;
  final int startDate;
  final int assetId;
  final int nextPeriod;
  final int nextPeriodDate;
  final String? credited;
  final int bookId;
  final bool excludeBudget;
  final bool excludeExIn;
  final int createDate;
  final String? tags;
  final String? images;
  final String? exi;
}

final class StagedRecordPeriod {
  const StagedRecordPeriod({
    this.id,
    required this.recordType,
    required this.moneyMinor,
    required this.feeMinor,
    required this.remark,
    required this.catId,
    required this.assetId,
    required this.assetId2,
    required this.bookId,
    this.images,
    required this.state,
    this.time,
    required this.excludeBudget,
    required this.excludeExIn,
    required this.periodType,
    required this.periodTypeDate,
    required this.periodStartDate,
    required this.periodEndDate,
    required this.frequency,
    required this.lastAddDate,
    required this.periodAddTimes,
    required this.createTime,
    this.tags,
    this.exi,
  });

  final int? id;
  final int recordType;
  final BigInt moneyMinor;
  final BigInt feeMinor;
  final String remark;
  final int catId;
  final int assetId;
  final int assetId2;
  final int bookId;
  final String? images;
  final int state;
  final String? time;
  final bool excludeBudget;
  final bool excludeExIn;
  final int periodType;
  final String periodTypeDate;
  final int periodStartDate;
  final int periodEndDate;
  final int frequency;
  final int lastAddDate;
  final int periodAddTimes;
  final int createTime;
  final String? tags;
  final String? exi;
}

final class StagedReminderEvent {
  const StagedReminderEvent({
    this.id,
    required this.reminderTime,
    this.reminderTip,
  });

  final int? id;
  final int reminderTime;
  final String? reminderTip;
}

final class StagedTag {
  const StagedTag({
    required this.tagId,
    required this.name,
    required this.sort,
    required this.hidden,
    this.parentTagId,
    required this.parent,
    this.color,
    this.extraInfo,
  });

  final String tagId;
  final String name;
  final int sort;
  final bool hidden;
  final String? parentTagId;
  final int parent;
  final String? color;
  final String? extraInfo;
}

final class StagedTagRecord {
  const StagedTagRecord({required this.tagId, required this.recordId});

  final String tagId;
  final String recordId;
}

final class StagedRecordTemplate {
  const StagedRecordTemplate({
    required this.id,
    required this.type,
    this.remark,
    required this.moneyMinor,
    required this.feeMinor,
    this.recordCatId,
    required this.assetId,
    required this.assetId2,
    required this.sort,
    required this.autoSave,
    required this.bookId,
    required this.excludeBudget,
    required this.excludeExIn,
    required this.createDate,
    this.tags,
    this.exi,
  });

  final int id;
  final int type;
  final String? remark;
  final BigInt moneyMinor;
  final BigInt feeMinor;
  final int? recordCatId;
  final int assetId;
  final int assetId2;
  final int sort;
  final bool autoSave;
  final int bookId;
  final bool excludeBudget;
  final bool excludeExIn;
  final int createDate;
  final String? tags;
  final String? exi;
}

final class StagedBankCard {
  const StagedBankCard({
    this.id,
    required this.cardType,
    required this.cardName,
    required this.cardNo,
    required this.cardOwner,
    required this.remark,
    this.cardColor,
    required this.sort,
    required this.createDate,
    required this.cardAssetId,
  });

  final int? id;
  final int cardType;
  final String cardName;
  final String cardNo;
  final String cardOwner;
  final String remark;
  final String? cardColor;
  final int sort;
  final int createDate;
  final int cardAssetId;
}

final class StagedWish {
  const StagedWish({
    required this.id,
    required this.content,
    required this.valueMinor,
    required this.createDate,
    required this.isRealized,
    required this.realizedDate,
    required this.sort,
    this.icon,
    required this.targetDate,
  });

  final String id;
  final String content;
  final BigInt valueMinor;
  final int createDate;
  final bool isRealized;
  final int realizedDate;
  final int sort;
  final String? icon;
  final int targetDate;
}

final class StagedRemark {
  const StagedRemark({
    this.id,
    required this.content,
    required this.recordCatId,
    required this.usedTimes,
  });

  final int? id;
  final String content;
  final int recordCatId;
  final int usedTimes;
}

final class StagedMoneySavePlan {
  const StagedMoneySavePlan({
    required this.id,
    required this.name,
    required this.remark,
    required this.planType,
    required this.cycleType,
    required this.startDate,
    required this.endDate,
    required this.planMoneyMinor,
    required this.savedMoneyMinor,
    required this.autoPlan,
    required this.fromAssetId,
    required this.toAssetId,
    required this.bookId,
    required this.startMoneyMinor,
    required this.incrementalMinor,
    required this.status,
    required this.createDate,
    required this.sort,
    required this.nextSaveDate,
    required this.bbzDailyTimes,
    this.icon,
    this.extraInfo,
  });

  final int id;
  final String name;
  final String remark;
  final int planType;
  final int cycleType;
  final int startDate;
  final int endDate;
  final BigInt planMoneyMinor;
  final BigInt savedMoneyMinor;
  final bool autoPlan;
  final int fromAssetId;
  final int toAssetId;
  final int bookId;
  final BigInt startMoneyMinor;
  final BigInt incrementalMinor;
  final int status;
  final int createDate;
  final int sort;
  final int nextSaveDate;
  final int bbzDailyTimes;
  final String? icon;
  final String? extraInfo;
}

final class StagedMoneySavePlanRecord {
  const StagedMoneySavePlanRecord({
    required this.id,
    required this.planId,
    required this.remark,
    required this.fromAssetId,
    required this.toAssetId,
    required this.recordDate,
    required this.recordMoneyMinor,
    this.recordId,
  });

  final int id;
  final int planId;
  final String remark;
  final int fromAssetId;
  final int toAssetId;
  final int recordDate;
  final BigInt recordMoneyMinor;
  final String? recordId;
}

final class StagedAssetBook {
  const StagedAssetBook({required this.assetId, required this.bookId});

  final int assetId;
  final int bookId;
}

final class StagedStatStory {
  const StagedStatStory({
    required this.id,
    required this.story,
    required this.bookId,
    required this.sdate,
    required this.edate,
    this.dsection,
  });

  final String id;
  final String story;
  final int bookId;
  final int sdate;
  final int edate;
  final String? dsection;
}

final class StagedAutoMap {
  const StagedAutoMap({this.id, required this.key, this.mapInfo, this.draft});

  final int? id;
  final String key;
  final String? mapInfo;
  final String? draft;
}

/// Summary of a parsed `.penny` / `.yy` backup shown in the preview dialog.
final class PennyBackupPreview {
  const PennyBackupPreview({
    required this.fileName,
    required this.appVersion,
    required this.envelopeFormat,
    required this.bookCount,
    required this.categoryCount,
    required this.assetCount,
    required this.recordCount,
    required this.budgetCount,
    required this.importPlatformCount,
    required this.installmentCount,
    required this.periodCount,
    required this.reminderCount,
    required this.tagCount,
    required this.tagRefCount,
    required this.templateCount,
    required this.bankCardCount,
    required this.wishCount,
    required this.remarkCount,
    required this.savingsPlanCount,
    required this.savingsPlanRecordCount,
    required this.assetBookRefCount,
    required this.statStoryCount,
    required this.autoBillMapCount,
    required this.filteredTombstoneCount,
    required this.targetBookId,
    required this.targetBookName,
  });

  final String fileName;
  final String appVersion;
  final PennyEnvelopeFormat envelopeFormat;
  final int bookCount;
  final int categoryCount;
  final int assetCount;
  final int recordCount;
  final int budgetCount;
  final int importPlatformCount;
  final int installmentCount;
  final int periodCount;
  final int reminderCount;
  final int tagCount;
  final int tagRefCount;
  final int templateCount;
  final int bankCardCount;
  final int wishCount;
  final int remarkCount;
  final int savingsPlanCount;
  final int savingsPlanRecordCount;
  final int assetBookRefCount;
  final int statStoryCount;
  final int autoBillMapCount;
  final int filteredTombstoneCount;
  final int targetBookId;
  final String targetBookName;

  int get totalPlanCount =>
      budgetCount + installmentCount + periodCount + savingsPlanCount;

  int get totalActiveRows =>
      bookCount +
      categoryCount +
      assetCount +
      recordCount +
      budgetCount +
      importPlatformCount +
      installmentCount +
      periodCount +
      reminderCount +
      tagCount +
      tagRefCount +
      templateCount +
      bankCardCount +
      wishCount +
      remarkCount +
      savingsPlanCount +
      savingsPlanRecordCount +
      assetBookRefCount +
      statStoryCount +
      autoBillMapCount;
}

/// Validated, cleaned in-memory staging model for all 20 `.penny` lists.
final class StagedPennyBackup {
  const StagedPennyBackup({
    required this.preview,
    required this.books,
    required this.categories,
    required this.assets,
    required this.records,
    required this.budgets,
    required this.importPlatforms,
    required this.installments,
    required this.periods,
    required this.reminders,
    required this.tags,
    required this.tagRefs,
    required this.templates,
    required this.bankCards,
    required this.wishes,
    required this.remarks,
    required this.moneySavePlans,
    required this.moneySavePlanRecords,
    required this.assetBookRefs,
    required this.statStory,
    required this.autoBillMaps,
    required this.targetBookId,
    required this.targetBookName,
    required this.synthesizedDefaultBook,
  });

  final PennyBackupPreview preview;
  final List<StagedAccountBook> books;
  final List<StagedRecordCategory> categories;
  final List<StagedAsset> assets;
  final List<StagedRecord> records;
  final List<StagedBudget> budgets;
  final List<StagedImportPlatform> importPlatforms;
  final List<StagedInstallment> installments;
  final List<StagedRecordPeriod> periods;
  final List<StagedReminderEvent> reminders;
  final List<StagedTag> tags;
  final List<StagedTagRecord> tagRefs;
  final List<StagedRecordTemplate> templates;
  final List<StagedBankCard> bankCards;
  final List<StagedWish> wishes;
  final List<StagedRemark> remarks;
  final List<StagedMoneySavePlan> moneySavePlans;
  final List<StagedMoneySavePlanRecord> moneySavePlanRecords;
  final List<StagedAssetBook> assetBookRefs;
  final List<StagedStatStory> statStory;
  final List<StagedAutoMap> autoBillMaps;
  final int targetBookId;
  final String targetBookName;
  final bool synthesizedDefaultBook;
}

/// Extracts original app version string (e.g. `'8.6.0'`) from a `.penny` / `.yy`
/// filename when present.
String? extractPennyVersionFromFileName(String fileName) {
  final base = fileName.split(RegExp(r'[/\\]')).last;
  final match = RegExp(r'[vV]?(\d+\.\d+\.\d+(?:\.\d+)?)').firstMatch(base);
  return match?.group(1);
}

/// Selects the active book ID after restore (`import-original-backup.md` §6.2):
/// prefers `id == 1`; otherwise selects the first book ordered by `(sort, id)`.
int resolvePennyTargetBookId(Iterable<StagedAccountBook> books) {
  final list = books.toList();
  if (list.isEmpty) return 1;
  for (final b in list) {
    if (b.id == 1) return 1;
  }
  list.sort((a, b) {
    final cmp = a.sort.compareTo(b.sort);
    return cmp != 0 ? cmp : a.id.compareTo(b.id);
  });
  return list.first.id;
}

/// Decrypts, parses, validates, filters `sstatus == 4` tombstones (`R3`),
/// rejects empty payloads (`R2` / `DR-BK-07`), and converts all amounts to
/// `int64` minor units (`ADR-011`).
StagedPennyBackup stagePennyBackup({
  required Uint8List bytes,
  String fileName = 'backup.penny',
  int fallbackNowMs = 0,
}) {
  final decoded = decodePennyBytes(bytes);
  return stagePennyJsonText(
    decoded.jsonText,
    fileName: fileName,
    envelopeFormat: decoded.format,
    fallbackNowMs: fallbackNowMs,
  );
}

/// Stages a decrypted `.penny` UTF-8 JSON document into [StagedPennyBackup].
StagedPennyBackup stagePennyJsonText(
  String jsonText, {
  String fileName = 'backup.penny',
  PennyEnvelopeFormat envelopeFormat = PennyEnvelopeFormat.standardYybk,
  int fallbackNowMs = 0,
}) {
  final Object? rootObj;
  try {
    rootObj = parseLosslessJson(jsonText);
  } on FormatException {
    throw const Failure(FailureCode.corruptData, '备份 JSON 结构已损坏');
  }
  if (rootObj is! Map<String, Object?>) {
    throw const Failure(FailureCode.corruptData, '备份根结构须为 JSON 对象');
  }
  final Map<String, Object?> rootMap = rootObj;
  if (rootMap.isEmpty) {
    throw const Failure(FailureCode.validation, '备份文件为空，已拒绝恢复以保护本地数据');
  }

  var hasAnyNonEmptyRawList = false;
  for (final key in penny20RootListKeys) {
    final val = rootMap[key];
    if (val == null) continue;
    if (val is! List) {
      throw Failure(FailureCode.corruptData, '备份列表字段 $key 格式非法');
    }
    if (val.isNotEmpty) {
      hasAnyNonEmptyRawList = true;
    }
  }
  if (!hasAnyNonEmptyRawList) {
    throw const Failure(FailureCode.validation, '备份文件不包含任何有效数据，已拒绝恢复以保护本地数据');
  }

  var filteredTombstones = 0;

  List<Map<String, Object?>> cleanRows(String listKey) {
    final rawList = rootMap[listKey];
    if (rawList == null) return const <Map<String, Object?>>[];
    if (rawList is! List) {
      throw Failure(FailureCode.corruptData, '备份列表字段 $listKey 格式非法');
    }
    final cleaned = <Map<String, Object?>>[];
    for (final item in rawList) {
      if (item == null) continue;
      if (item is! Map) {
        throw Failure(FailureCode.corruptData, '备份列表 $listKey 中存在损坏条目');
      }
      final sstatus = _optInt(item, const <String>['sstatus']);
      if (sstatus == 4) {
        filteredTombstones++;
        continue;
      }
      final map = <String, Object?>{};
      for (final entry in item.entries) {
        final k = entry.key.toString();
        // Strip cloud-sync metadata & Room surrogate _id (R3, ADR-013).
        if (k == 'uid' ||
            k == 'sync_time' ||
            k == 'sstime' ||
            k == 'sstatus' ||
            k == '_id') {
          continue;
        }
        map[k] = entry.value;
      }
      cleaned.add(map);
    }
    return cleaned;
  }

  // 1. books (account_book) - deduplicate by business key `id`
  final rawBooks = cleanRows('books');
  final bookById = <int, StagedAccountBook>{};
  for (final m in rawBooks) {
    final id = _reqInt(m, const <String>['id'], 'books.id');
    final name = _optString(m, const <String>['name']) ?? '日常账本';
    bookById[id] = StagedAccountBook(
      id: id,
      type: _optInt(m, const <String>['type']) ?? 1,
      name: name.isEmpty ? '日常账本' : name,
      cover: _optString(m, const <String>['cover']) ?? '',
      sort: _optInt(m, const <String>['sort']) ?? 1,
      status: _optInt(m, const <String>['status']) ?? 0,
      startDay:
          _optInt(m, const <String>['dstart', 'start_day', 'startDay']) ?? 1,
      createDate:
          _optInt(m, const <String>['cdate', 'create_date', 'createDate']) ??
          fallbackNowMs,
      displayWay:
          _optInt(m, const <String>['dway', 'display_way', 'displayWay']) ?? 0,
      extraInfo: _passthroughJsonOrText(
        _firstPresent(m, const <String>['extra_info', 'extraInfo', 'extra']),
        'books.extra_info',
      ),
    );
  }
  final books = bookById.values.toList();

  // 2. categories (record_category)
  final categories = <StagedRecordCategory>[
    for (final m in cleanRows('categories'))
      StagedRecordCategory(
        id: _optInt(m, const <String>['id']),
        name: _reqString(m, const <String>['name'], 'categories.name'),
        icon: _optString(m, const <String>['icon']) ?? '',
        type: _reqInt(m, const <String>['type'], 'categories.type'),
        sort: _optInt(m, const <String>['sort']) ?? 0,
        parentCatId:
            _optInt(m, const <String>[
              'parent',
              'parent_cat_id',
              'parentCatId',
            ]) ??
            -1,
        colorFill: _optNullableString(m, const <String>[
          'color',
          'color_fill',
          'colorFill',
        ]),
        platformId:
            _optInt(m, const <String>[
              'DD0O0oO0o0OOo',
              'plat',
              'platform_id',
              'platformId',
            ]) ??
            -1,
        accountBookId:
            _optInt(m, const <String>[
              'book',
              'account_book_id',
              'accountBookId',
            ]) ??
            1,
        isHide:
            _optBool(m, const <String>['hide', 'is_hide', 'isHide']) ?? false,
        extraInfo: _passthroughJsonOrText(
          _firstPresent(m, const <String>['extra_info', 'extraInfo', 'extra']),
          'categories.extra_info',
        ),
      ),
  ];

  // 3. assets (asset)
  final assets = <StagedAsset>[
    for (final m in cleanRows('assets'))
      () {
        final assetType = _reqInt(m, const <String>['type'], 'assets.type');
        return StagedAsset(
          id: _optInt(m, const <String>['id']),
          name: _reqString(m, const <String>['name'], 'assets.name'),
          balanceMinor: pennyMajorToMinor(
            _firstPresent(m, const <String>['bal', 'balance']),
            defaultMinor: BigInt.zero,
            fieldName: 'assets.balance',
          ),
          type: assetType,
          subType:
              _optInt(m, const <String>['subt', 'sub_type', 'subType']) ?? -1,
          createDate:
              _optInt(m, const <String>[
                'cdate',
                'create_date',
                'createDate',
              ]) ??
              fallbackNowMs,
          sort: _optInt(m, const <String>['sort']) ?? 0,
          icon: _optString(m, const <String>['icon']) ?? '',
          remark: _optNullableString(m, const <String>['remark']),
          initMoneyMinor: pennyMajorToMinor(
            _firstPresent(m, const <String>[
              'initm',
              'init_money',
              'initMoney',
            ]),
            defaultMinor: BigInt.zero,
            fieldName: 'assets.init_money',
          ),
          isDefault:
              _optBool(m, const <String>[
                'default',
                'is_default',
                'isDefault',
              ]) ??
              false,
          isEffectiveAsset: _parseEffectiveAsset(
            _firstPresent(m, const <String>[
              'effect',
              'is_effective_asset',
              'isEffectiveAsset',
            ]),
            assetType: assetType,
          ),
          usedTimes:
              _optInt(m, const <String>[
                'usetime',
                'used_times',
                'usedTimes',
              ]) ??
              0,
          color: _optNullableString(m, const <String>['color']),
          status: _optInt(m, const <String>['status']) ?? 0,
          extraInfo: convertAssetExtraJson(
            _firstPresent(m, const <String>[
              'extra',
              'extra_info',
              'extraInfo',
            ]),
          ),
          loanInfo: convertAssetLoanJson(
            _firstPresent(m, const <String>['loan', 'loan_info', 'loanInfo']),
          ),
          creditInfo: convertAssetCreditJson(
            _firstPresent(m, const <String>[
              'credit',
              'credit_info',
              'creditInfo',
            ]),
          ),
          fixedDepositInfo: convertAssetFixedDepositJson(
            _firstPresent(m, const <String>[
              'fixeddeposit',
              'fixed_deposit_info',
              'fixedDepositInfo',
            ]),
          ),
          groupName: _optNullableString(m, const <String>[
            'groupname',
            'group_name',
            'groupName',
          ]),
          currency: _normalizeAssetCurrency(m['currency']),
        );
      }(),
  ];

  // 4. records (record)
  final records = <StagedRecord>[
    for (final m in cleanRows('records'))
      StagedRecord(
        recordId: _reqIdString(m, const <String>[
          'id',
          'record_id',
          'recordId',
        ], 'records.id'),
        type: _reqInt(m, const <String>['type'], 'records.type'),
        subType:
            _optInt(m, const <String>['subt', 'sub_type', 'subType']) ?? -1,
        moneyMinor: pennyMajorToMinor(
          m['money'],
          defaultMinor: BigInt.zero,
          fieldName: 'records.money',
        ),
        remark: _optString(m, const <String>['remark']) ?? '',
        recordTime: _reqInt(m, const <String>[
          'time',
          'record_time',
          'recordTime',
        ], 'records.time'),
        recordCatId:
            _optInt(m, const <String>['cat', 'record_cat_id', 'recordCatId']) ??
            -1,
        assetId:
            _optInt(m, const <String>['asset', 'asset_id', 'assetId']) ?? -1,
        fromAssetId:
            _optInt(m, const <String>[
              'froma',
              'from_asset_id',
              'fromAssetId',
            ]) ??
            -1,
        toAssetId:
            _optInt(m, const <String>['toa', 'to_asset_id', 'toAssetId']) ?? -1,
        accountBookId:
            _optInt(m, const <String>[
              'book',
              'account_book_id',
              'accountBookId',
            ]) ??
            1,
        excludeBudget:
            _optBool(m, const <String>[
              'exbud',
              'exclude_budget',
              'excludeBudget',
            ]) ??
            false,
        excludeExIn:
            _optBool(m, const <String>[
              'exexin',
              'exclude_ex_in',
              'excludeExIn',
            ]) ??
            false,
        platformId:
            _optInt(m, const <String>['plat', 'platform_id', 'platformId']) ??
            -1,
        periodId:
            _optInt(m, const <String>['period', 'period_id', 'periodId']) ?? -1,
        installment: _optNullableString(m, const <String>[
          'instal',
          'installment',
        ]),
        images: _parseStringOrListCsv(
          _firstPresent(m, const <String>['img', 'images']),
        ),
        relInfo: convertRecordRelJson(
          _firstPresent(m, const <String>['rel', 'rel_info', 'relInfo']),
        ),
        discountMinor: pennyNullableMajorToMinor(
          m['discount'],
          fieldName: 'records.discount',
        ),
        extraInfo: convertRecordExtraJson(
          _firstPresent(m, const <String>['extra', 'extra_info', 'extraInfo']),
        ),
        createDate: _optInt(m, const <String>[
          'cdt',
          'create_date',
          'createDate',
        ]),
      ),
  ];

  // 5. budgets (budget)
  final budgets = <StagedBudget>[
    for (final m in cleanRows('budgets'))
      StagedBudget(
        id: _reqInt(m, const <String>['id'], 'budgets.id'),
        budgetType: _reqInt(m, const <String>[
          'type',
          'budget_type',
          'budgetType',
        ], 'budgets.type'),
        recordCatId:
            _optInt(m, const <String>['cat', 'record_cat_id', 'recordCatId']) ??
            -1,
        amountMinor: pennyMajorToMinor(
          m['amount'],
          defaultMinor: BigInt.zero,
          fieldName: 'budgets.amount',
        ),
        bookId: _optInt(m, const <String>['book', 'book_id', 'bookId']) ?? 1,
        section: _reqString(m, const <String>[
          'sect',
          'section',
        ], 'budgets.section'),
        sort: _optInt(m, const <String>['sort']) ?? 0,
        createDate:
            _optInt(m, const <String>['cdate', 'create_date', 'createDate']) ??
            fallbackNowMs,
        remark: _optNullableString(m, const <String>['remark']),
        extraInfo: convertBudgetExtraJson(
          _firstPresent(m, const <String>['extra_info', 'extraInfo', 'extra']),
        ),
      ),
  ];

  // 6. importPlatforms (import_platform)
  final importPlatforms = <StagedImportPlatform>[
    for (final m in cleanRows('importPlatforms'))
      StagedImportPlatform(
        id: _optInt(m, const <String>['id']),
        platform: _reqString(m, const <String>[
          'plat',
          'platform',
        ], 'importPlatforms.platform'),
        importRecordCount:
            _optInt(m, const <String>[
              'recordc',
              'import_record_count',
              'importRecordCount',
            ]) ??
            0,
        importCategoryCount:
            _optInt(m, const <String>[
              'catc',
              'import_category_count',
              'importCategoryCount',
            ]) ??
            0,
        importTime:
            _optInt(m, const <String>['time', 'import_time', 'importTime']) ??
            fallbackNowMs,
        hidden: _optBool(m, const <String>['hidden']) ?? false,
      ),
  ];

  // 7. installments (installment)
  final installments = <StagedInstallment>[
    for (final m in cleanRows('installments'))
      StagedInstallment(
        id: _optInt(m, const <String>['id']),
        name: _reqString(m, const <String>['name'], 'installments.name'),
        catId: _optInt(m, const <String>['cat', 'cat_id', 'catId']) ?? -1,
        principalMinor: pennyMajorToMinor(
          _firstPresent(m, const <String>[
            'prin',
            'principal_money',
            'principalMoney',
          ]),
          defaultMinor: BigInt.zero,
          fieldName: 'installments.principal_money',
        ),
        periods: _reqInt(m, const <String>['periods'], 'installments.periods'),
        chargeMinor: pennyMajorToMinor(
          m['charge'],
          defaultMinor: BigInt.zero,
          fieldName: 'installments.charge',
        ),
        chargeWay:
            _optInt(m, const <String>[
              'chargeway',
              'charge_way',
              'chargeWay',
            ]) ??
            0,
        remainderIn:
            _optInt(m, const <String>[
              'remin',
              'remainder_in',
              'remainderIn',
            ]) ??
            0,
        calWay: _optInt(m, const <String>['calway', 'cal_way', 'calWay']) ?? 2,
        startDate:
            _optInt(m, const <String>['sdate', 'start_date', 'startDate']) ??
            fallbackNowMs,
        assetId:
            _optInt(m, const <String>['asset', 'asset_id', 'assetId']) ?? -1,
        nextPeriod:
            _optInt(m, const <String>['np', 'next_period', 'nextPeriod']) ?? 1,
        nextPeriodDate:
            _optInt(m, const <String>[
              'npdate',
              'next_period_date',
              'nextPeriodDate',
            ]) ??
            0,
        credited: _parseCreditedJson(m['credited']),
        bookId: _optInt(m, const <String>['book', 'book_id', 'bookId']) ?? 1,
        excludeBudget:
            _optBool(m, const <String>[
              'exbud',
              'exclude_budget',
              'excludeBudget',
            ]) ??
            false,
        excludeExIn:
            _optBool(m, const <String>[
              'exexin',
              'exclude_ex_in',
              'excludeExIn',
            ]) ??
            false,
        createDate:
            _optInt(m, const <String>['cdate', 'create_date', 'createDate']) ??
            fallbackNowMs,
        tags: _parseStringOrListCsv(m['tags']),
        images: _parseStringOrListCsv(
          _firstPresent(m, const <String>['img', 'images']),
        ),
        exi: convertInstallmentExtraJson(m['exi']),
      ),
  ];

  // 8. periods (record_period)
  final periods = <StagedRecordPeriod>[
    for (final m in cleanRows('periods'))
      StagedRecordPeriod(
        id: _optInt(m, const <String>['id']),
        recordType: _reqInt(m, const <String>[
          'type',
          'record_type',
          'recordType',
        ], 'periods.type'),
        moneyMinor: pennyMajorToMinor(
          m['money'],
          defaultMinor: BigInt.zero,
          fieldName: 'periods.money',
        ),
        feeMinor: pennyMajorToMinor(
          m['fee'],
          defaultMinor: BigInt.zero,
          fieldName: 'periods.fee',
        ),
        remark: _optString(m, const <String>['remark']) ?? '',
        catId: _optInt(m, const <String>['cat', 'cat_id', 'catId']) ?? -1,
        assetId:
            _optInt(m, const <String>['asset', 'asset_id', 'assetId']) ?? -1,
        assetId2:
            _optInt(m, const <String>['asset2', 'asset_id2', 'assetId2']) ?? -1,
        bookId: _optInt(m, const <String>['book', 'book_id', 'bookId']) ?? 1,
        images: _parseStringOrListCsv(
          _firstPresent(m, const <String>['img', 'images']),
        ),
        state: _optInt(m, const <String>['state']) ?? 0,
        time: _optNullableString(m, const <String>['time']),
        excludeBudget:
            _optBool(m, const <String>[
              'exbud',
              'exclude_budget',
              'excludeBudget',
            ]) ??
            false,
        excludeExIn:
            _optBool(m, const <String>[
              'exexin',
              'exclude_ex_in',
              'excludeExIn',
            ]) ??
            false,
        periodType: _reqInt(m, const <String>[
          'ptype',
          'period_type',
          'periodType',
        ], 'periods.ptype'),
        periodTypeDate: _parsePeriodTypeDateJson(
          _firstPresent(m, const <String>[
            'ptypedate',
            'period_type_date',
            'periodTypeDate',
          ]),
        ),
        periodStartDate:
            _optInt(m, const <String>[
              'startdate',
              'period_start_date',
              'periodStartDate',
            ]) ??
            fallbackNowMs,
        periodEndDate:
            _optInt(m, const <String>[
              'enddate',
              'period_end_date',
              'periodEndDate',
            ]) ??
            -1,
        frequency: _optInt(m, const <String>['freq', 'frequency']) ?? 1,
        lastAddDate:
            _optInt(m, const <String>[
              'lastadd',
              'last_add_date',
              'lastAddDate',
            ]) ??
            -1,
        periodAddTimes:
            _optInt(m, const <String>[
              'addtimes',
              'period_add_times',
              'periodAddTimes',
            ]) ??
            0,
        createTime:
            _optInt(m, const <String>['ctime', 'create_time', 'createTime']) ??
            fallbackNowMs,
        tags: _parseStringOrListCsv(m['tags']),
        exi: _passthroughJsonOrText(m['exi'], 'periods.exi'),
      ),
  ];

  // 9. reminders (reminder_event)
  final reminders = <StagedReminderEvent>[
    for (final m in cleanRows('reminders'))
      StagedReminderEvent(
        id: _optInt(m, const <String>['id']),
        reminderTime: _reqInt(m, const <String>[
          'time',
          'reminder_time',
          'reminderTime',
        ], 'reminders.time'),
        reminderTip: _optPreserveEmptyString(m, const <String>[
          'tip',
          'reminder_tip',
          'reminderTip',
        ]),
      ),
  ];

  // 10. tags (tag)
  // Note: in original Gson Tag entity, @SerializedName("parent") maps to
  // `parent_tag_id` (String?), while @SerializedName("isparent") maps to
  // `parent` (Boolean -> 0/1 INTEGER). Support both Gson and SQLite keys.
  final tags = <StagedTag>[
    for (final m in cleanRows('tags'))
      () {
        String? parentTagId = _optNullableString(m, const <String>[
          'parent_tag_id',
          'parentTagId',
        ]);
        int isParentFlag = 0;
        final rawIsparent = m['isparent'];
        if (rawIsparent != null) {
          isParentFlag = (_asBool(rawIsparent) ?? false) ? 1 : 0;
        }
        final rawParent = m['parent'];
        if (rawParent is String) {
          parentTagId ??= rawParent.trim().isEmpty ? null : rawParent.trim();
        } else if (rawParent is bool && rawIsparent == null) {
          isParentFlag = rawParent ? 1 : 0;
        } else if (rawParent is int && rawIsparent == null) {
          isParentFlag = rawParent;
        }
        return StagedTag(
          tagId: _reqIdString(m, const <String>[
            'id',
            'tag_id',
            'tagId',
          ], 'tags.id'),
          name: _reqString(m, const <String>['name'], 'tags.name'),
          sort: _optInt(m, const <String>['sort']) ?? 0,
          hidden: _optBool(m, const <String>['hidden']) ?? false,
          parentTagId: parentTagId,
          parent: isParentFlag,
          color: _optNullableString(m, const <String>['color']),
          extraInfo: _passthroughJsonOrText(
            _firstPresent(m, const <String>[
              'extra_info',
              'extraInfo',
              'extra',
            ]),
            'tags.extra_info',
          ),
        );
      }(),
  ];

  // 11. tagRefs (tag_record) - deduplicate composite PK (tagId, recordId)
  final tagRefSet = <(String, String)>{};
  final tagRefs = <StagedTagRecord>[];
  for (final m in cleanRows('tagRefs')) {
    final tid = _reqIdString(m, const <String>[
      'tid',
      'tag_id',
      'tagId',
    ], 'tagRefs.tid');
    final rid = _reqIdString(m, const <String>[
      'rid',
      'record_id',
      'recordId',
    ], 'tagRefs.rid');
    if (tagRefSet.add((tid, rid))) {
      tagRefs.add(StagedTagRecord(tagId: tid, recordId: rid));
    }
  }

  // 12. templates (record_template)
  final templates = <StagedRecordTemplate>[
    for (final m in cleanRows('templates'))
      StagedRecordTemplate(
        id: _reqInt(m, const <String>['id'], 'templates.id'),
        type: _reqInt(m, const <String>['type'], 'templates.type'),
        remark: _optNullableString(m, const <String>['remark']),
        moneyMinor: pennyMajorToMinor(
          m['money'],
          defaultMinor: BigInt.zero,
          fieldName: 'templates.money',
        ),
        feeMinor: pennyMajorToMinor(
          m['fee'],
          defaultMinor: BigInt.zero,
          fieldName: 'templates.fee',
        ),
        recordCatId: _optInt(m, const <String>[
          'cat',
          'record_cat_id',
          'recordCatId',
        ]),
        assetId:
            _optInt(m, const <String>['asset', 'asset_id', 'assetId']) ?? -1,
        assetId2:
            _optInt(m, const <String>['asset2', 'asset_id2', 'assetId2']) ?? -1,
        sort: _optInt(m, const <String>['sort']) ?? 0,
        autoSave:
            _optBool(m, const <String>['autosave', 'auto_save', 'autoSave']) ??
            false,
        bookId: _optInt(m, const <String>['book', 'book_id', 'bookId']) ?? 1,
        excludeBudget:
            _optBool(m, const <String>[
              'exbud',
              'exclude_budget',
              'excludeBudget',
            ]) ??
            false,
        excludeExIn:
            _optBool(m, const <String>[
              'exexin',
              'exclude_ex_in',
              'excludeExIn',
            ]) ??
            false,
        createDate:
            _optInt(m, const <String>['cdate', 'create_date', 'createDate']) ??
            fallbackNowMs,
        tags: _parseStringOrListCsv(m['tags']),
        exi: _passthroughJsonOrText(m['exi'], 'templates.exi'),
      ),
  ];

  // 13. bankCards (bank_card)
  final bankCards = <StagedBankCard>[
    for (final m in cleanRows('bankCards'))
      StagedBankCard(
        id: _optInt(m, const <String>['id']),
        cardType:
            _optInt(m, const <String>['type', 'card_type', 'cardType']) ?? 0,
        cardName:
            _optString(m, const <String>['name', 'card_name', 'cardName']) ??
            '',
        cardNo: _optString(m, const <String>['no', 'card_no', 'cardNo']) ?? '',
        cardOwner:
            _optString(m, const <String>['owner', 'card_owner', 'cardOwner']) ??
            '',
        remark: _optString(m, const <String>['remark']) ?? '',
        cardColor: _optNullableString(m, const <String>[
          'color',
          'card_color',
          'cardColor',
        ]),
        sort: _optInt(m, const <String>['sort']) ?? -1,
        createDate:
            _optInt(m, const <String>['cdate', 'create_date', 'createDate']) ??
            fallbackNowMs,
        cardAssetId:
            _optInt(m, const <String>[
              'card_asset_id',
              'cardAssetId',
              'asset',
            ]) ??
            -1,
      ),
  ];

  // 14. wishes (wish)
  final wishes = <StagedWish>[
    for (final m in cleanRows('wishes'))
      StagedWish(
        id: _reqIdString(m, const <String>['id'], 'wishes.id'),
        content: _optString(m, const <String>['content']) ?? '',
        valueMinor: pennyMajorToMinor(
          m['value'],
          defaultMinor: BigInt.zero,
          fieldName: 'wishes.value',
        ),
        createDate:
            _optInt(m, const <String>['cdate', 'create_date', 'createDate']) ??
            fallbackNowMs,
        isRealized:
            _optBool(m, const <String>[
              'realized',
              'is_realized',
              'isRealized',
            ]) ??
            false,
        realizedDate:
            _optInt(m, const <String>[
              'rdate',
              'realized_date',
              'realizedDate',
            ]) ??
            0,
        sort: _optInt(m, const <String>['sort']) ?? 0,
        icon: _optNullableString(m, const <String>['icon']),
        targetDate:
            _optInt(m, const <String>['tdate', 'target_date', 'targetDate']) ??
            0,
      ),
  ];

  // 15. remarks (remark) - unconditionally imported (R6)
  final remarks = <StagedRemark>[
    for (final m in cleanRows('remarks'))
      StagedRemark(
        id: _optInt(m, const <String>['id']),
        content: _reqString(m, const <String>['content'], 'remarks.content'),
        recordCatId:
            _optInt(m, const <String>['record_cat_id', 'recordCatId', 'cat']) ??
            -1,
        usedTimes:
            _optInt(m, const <String>['used_times', 'usedTimes', 'usetime']) ??
            0,
      ),
  ];

  // 16. moneySavePlans (money_save_plan)
  final moneySavePlans = <StagedMoneySavePlan>[
    for (final m in cleanRows('moneySavePlans'))
      StagedMoneySavePlan(
        id: _reqInt(m, const <String>['id'], 'moneySavePlans.id'),
        name: _reqString(m, const <String>['name'], 'moneySavePlans.name'),
        remark: _optString(m, const <String>['remark']) ?? '',
        planType: _reqInt(m, const <String>[
          'plan_type',
          'planType',
          'type',
        ], 'moneySavePlans.plan_type'),
        cycleType: _optInt(m, const <String>['cycle_type', 'cycleType']) ?? -1,
        startDate:
            _optInt(m, const <String>['start_date', 'startDate']) ??
            fallbackNowMs,
        endDate: _optInt(m, const <String>['end_date', 'endDate']) ?? 0,
        planMoneyMinor: pennyMajorToMinor(
          _firstPresent(m, const <String>['plan_money', 'planMoney']),
          defaultMinor: BigInt.zero,
          fieldName: 'moneySavePlans.plan_money',
        ),
        savedMoneyMinor: pennyMajorToMinor(
          _firstPresent(m, const <String>['saved_money', 'savedMoney']),
          defaultMinor: BigInt.zero,
          fieldName: 'moneySavePlans.saved_money',
        ),
        autoPlan: _optBool(m, const <String>['auto_plan', 'autoPlan']) ?? false,
        fromAssetId:
            _optInt(m, const <String>['from_asset_id', 'fromAssetId']) ?? -1,
        toAssetId: _optInt(m, const <String>['to_asset_id', 'toAssetId']) ?? -1,
        bookId: _optInt(m, const <String>['book_id', 'bookId', 'book']) ?? -1,
        startMoneyMinor: pennyMajorToMinor(
          _firstPresent(m, const <String>['start_money', 'startMoney']),
          defaultMinor: BigInt.zero,
          fieldName: 'moneySavePlans.start_money',
        ),
        incrementalMinor: pennyMajorToMinor(
          m['incremental'],
          defaultMinor: BigInt.zero,
          fieldName: 'moneySavePlans.incremental',
        ),
        status: _optInt(m, const <String>['status']) ?? 0,
        createDate:
            _optInt(m, const <String>['create_date', 'createDate']) ??
            fallbackNowMs,
        sort: _optInt(m, const <String>['sort']) ?? 0,
        nextSaveDate:
            _optInt(m, const <String>['next_save_date', 'nextSaveDate']) ?? 0,
        bbzDailyTimes:
            _optInt(m, const <String>['bbz_daily_times', 'bbzDailyTimes']) ?? 0,
        icon: _optNullableString(m, const <String>['icon']),
        extraInfo: _passthroughJsonOrText(
          _firstPresent(m, const <String>['extra_info', 'extraInfo', 'extra']),
          'moneySavePlans.extra_info',
        ),
      ),
  ];

  // 17. moneySavePlanRecords (money_save_plan_record)
  final moneySavePlanRecords = <StagedMoneySavePlanRecord>[
    for (final m in cleanRows('moneySavePlanRecords'))
      StagedMoneySavePlanRecord(
        id: _reqInt(m, const <String>['id'], 'moneySavePlanRecords.id'),
        planId: _reqInt(m, const <String>[
          'plan_id',
          'planId',
        ], 'moneySavePlanRecords.plan_id'),
        remark: _optString(m, const <String>['remark']) ?? '',
        fromAssetId:
            _optInt(m, const <String>['from_asset_id', 'fromAssetId']) ?? -1,
        toAssetId: _optInt(m, const <String>['to_asset_id', 'toAssetId']) ?? -1,
        recordDate: _reqInt(m, const <String>[
          'record_date',
          'recordDate',
        ], 'moneySavePlanRecords.record_date'),
        recordMoneyMinor: pennyMajorToMinor(
          _firstPresent(m, const <String>['record_money', 'recordMoney']),
          defaultMinor: BigInt.zero,
          fieldName: 'moneySavePlanRecords.record_money',
        ),
        recordId: _optNullableIdString(m, const <String>[
          'record_id',
          'recordId',
        ]),
      ),
  ];

  // 18. assetBookRefs (asset_book) - deduplicate composite PK (assetId, bookId)
  final assetBookSet = <(int, int)>{};
  final assetBookRefs = <StagedAssetBook>[];
  for (final m in cleanRows('assetBookRefs')) {
    final aid = _reqInt(m, const <String>[
      'aid',
      'asset_id',
      'assetId',
    ], 'assetBookRefs.aid');
    final bid = _reqInt(m, const <String>[
      'bid',
      'book_id',
      'bookId',
    ], 'assetBookRefs.bid');
    if (assetBookSet.add((aid, bid))) {
      assetBookRefs.add(StagedAssetBook(assetId: aid, bookId: bid));
    }
  }

  // 19. statStory (stat_story) - note singular root key `statStory`
  final statStory = <StagedStatStory>[
    for (final m in cleanRows('statStory'))
      StagedStatStory(
        id: _reqIdString(m, const <String>['id'], 'statStory.id'),
        story: _optString(m, const <String>['story']) ?? '',
        bookId: _optInt(m, const <String>['book_id', 'bookId', 'book']) ?? 1,
        sdate: _optInt(m, const <String>['sdate']) ?? 0,
        edate: _optInt(m, const <String>['edate']) ?? 0,
        dsection: _optNullableString(m, const <String>['dsection']),
      ),
  ];

  // 20. autoBillMaps (auto_map)
  final autoBillMaps = <StagedAutoMap>[
    for (final m in cleanRows('autoBillMaps'))
      StagedAutoMap(
        id: _optInt(m, const <String>['id']),
        key: _reqString(m, const <String>['key'], 'autoBillMaps.key'),
        mapInfo: _passthroughJsonOrText(
          _firstPresent(m, const <String>['map_info', 'mapInfo']),
          'autoBillMaps.map_info',
        ),
        draft: _passthroughJsonOrText(m['draft'], 'autoBillMaps.draft'),
      ),
  ];

  final activeBeforeFallbackBook =
      books.length +
      categories.length +
      assets.length +
      records.length +
      budgets.length +
      importPlatforms.length +
      installments.length +
      periods.length +
      reminders.length +
      tags.length +
      tagRefs.length +
      templates.length +
      bankCards.length +
      wishes.length +
      remarks.length +
      moneySavePlans.length +
      moneySavePlanRecords.length +
      assetBookRefs.length +
      statStory.length +
      autoBillMaps.length;

  if (activeBeforeFallbackBook == 0) {
    throw const Failure(
      FailureCode.validation,
      '备份文件中没有可恢复的有效数据（全部为已删除墓碑记录），已拒绝恢复以保护本地数据',
    );
  }

  var synthesizedDefaultBook = false;
  if (books.isEmpty) {
    synthesizedDefaultBook = true;
    books.add(
      StagedAccountBook(
        id: 1,
        type: 1,
        name: '日常账本',
        cover: '',
        sort: 1,
        status: 0,
        startDay: 1,
        createDate: fallbackNowMs,
        displayWay: 0,
      ),
    );
  }

  final targetBookId = resolvePennyTargetBookId(books);
  final targetBook = books.firstWhere(
    (b) => b.id == targetBookId,
    orElse: () => books.first,
  );

  final rootVersion = _optNullableString(rootObj, const <String>[
    'version',
    'appVersion',
    'app_version',
  ]);
  final appVersion =
      rootVersion ?? extractPennyVersionFromFileName(fileName) ?? '原版备份';

  final preview = PennyBackupPreview(
    fileName: fileName,
    appVersion: appVersion,
    envelopeFormat: envelopeFormat,
    bookCount: books.length,
    categoryCount: categories.length,
    assetCount: assets.length,
    recordCount: records.length,
    budgetCount: budgets.length,
    importPlatformCount: importPlatforms.length,
    installmentCount: installments.length,
    periodCount: periods.length,
    reminderCount: reminders.length,
    tagCount: tags.length,
    tagRefCount: tagRefs.length,
    templateCount: templates.length,
    bankCardCount: bankCards.length,
    wishCount: wishes.length,
    remarkCount: remarks.length,
    savingsPlanCount: moneySavePlans.length,
    savingsPlanRecordCount: moneySavePlanRecords.length,
    assetBookRefCount: assetBookRefs.length,
    statStoryCount: statStory.length,
    autoBillMapCount: autoBillMaps.length,
    filteredTombstoneCount: filteredTombstones,
    targetBookId: targetBookId,
    targetBookName: targetBook.name,
  );

  return StagedPennyBackup(
    preview: preview,
    books: books,
    categories: categories,
    assets: assets,
    records: records,
    budgets: budgets,
    importPlatforms: importPlatforms,
    installments: installments,
    periods: periods,
    reminders: reminders,
    tags: tags,
    tagRefs: tagRefs,
    templates: templates,
    bankCards: bankCards,
    wishes: wishes,
    remarks: remarks,
    moneySavePlans: moneySavePlans,
    moneySavePlanRecords: moneySavePlanRecords,
    assetBookRefs: assetBookRefs,
    statStory: statStory,
    autoBillMaps: autoBillMaps,
    targetBookId: targetBookId,
    targetBookName: targetBook.name,
    synthesizedDefaultBook: synthesizedDefaultBook,
  );
}

// ---------------------------------------------------------------------------
// Primitive Field Extraction Helpers
// ---------------------------------------------------------------------------

Object? _firstPresent(Map<dynamic, dynamic> map, List<String> keys) {
  for (final k in keys) {
    final v = map[k];
    if (v != null) return v;
  }
  return null;
}

int? _asInt(Object? v, String label) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is JsonNumber) {
    final dec = parsePennyDecimalLexeme(v.lexeme);
    if (dec.scale == 0) {
      return int.tryParse(dec.coefficient.toString()) ??
          (throw Failure(FailureCode.corruptData, '整数字段超出范围: $label'));
    }
    final BigInt units;
    try {
      units = dec.unitsAt(0, rounding: null);
    } on Failure {
      throw Failure(FailureCode.corruptData, '整数字段包含小数部分: $label');
    }
    return int.tryParse(units.toString()) ??
        (throw Failure(FailureCode.corruptData, '整数字段超出范围: $label'));
  }
  if (v is String) {
    final trimmed = v.trim();
    if (trimmed.isEmpty) return null;
    final parsed = int.tryParse(trimmed);
    if (parsed != null) return parsed;
  }
  throw Failure(FailureCode.corruptData, '整数字段格式非法: $label');
}

int? _optInt(Map<dynamic, dynamic> map, List<String> keys) {
  final raw = _firstPresent(map, keys);
  if (raw == null) return null;
  return _asInt(raw, keys.first);
}

int _reqInt(Map<dynamic, dynamic> map, List<String> keys, String label) {
  final val = _asInt(_firstPresent(map, keys), label);
  if (val == null) {
    throw Failure(FailureCode.corruptData, '缺少必填整数字段: $label');
  }
  return val;
}

bool? _asBool(Object? v) {
  if (v == null) return null;
  if (v is bool) return v;
  if (v is int) return v != 0;
  if (v is String) {
    final lower = v.trim().toLowerCase();
    if (lower == 'true' || lower == '1') return true;
    if (lower == 'false' || lower == '0') return false;
  }
  throw const Failure(FailureCode.corruptData, '布尔字段格式非法');
}

bool? _optBool(Map<dynamic, dynamic> map, List<String> keys) =>
    _asBool(_firstPresent(map, keys));

String? _optString(Map<dynamic, dynamic> map, List<String> keys) {
  final raw = _firstPresent(map, keys);
  if (raw == null) return null;
  if (raw is String) return raw;
  if (raw is int || raw is JsonNumber || raw is bool) return raw.toString();
  throw Failure(FailureCode.corruptData, '文本字段格式非法: ${keys.first}');
}

String? _optNullableString(Map<dynamic, dynamic> map, List<String> keys) {
  final s = _optString(map, keys);
  if (s == null) return null;
  final trimmed = s.trim();
  return trimmed.isEmpty ? null : s;
}

String? _optPreserveEmptyString(Map<dynamic, dynamic> map, List<String> keys) =>
    _optString(map, keys);

String _reqString(Map<dynamic, dynamic> map, List<String> keys, String label) {
  final s = _optString(map, keys);
  if (s == null) {
    throw Failure(FailureCode.corruptData, '缺少必填文本字段: $label');
  }
  return s;
}

String _reqIdString(
  Map<dynamic, dynamic> map,
  List<String> keys,
  String label,
) {
  final raw = _firstPresent(map, keys);
  if (raw == null) {
    throw Failure(FailureCode.corruptData, '缺少必填标识字段: $label');
  }
  final s = raw.toString().trim();
  if (s.isEmpty) {
    throw Failure(FailureCode.corruptData, '标识字段为空: $label');
  }
  return s;
}

String? _optNullableIdString(Map<dynamic, dynamic> map, List<String> keys) {
  final raw = _firstPresent(map, keys);
  if (raw == null) return null;
  final s = raw.toString().trim();
  return s.isEmpty ? null : s;
}

int _parseEffectiveAsset(Object? raw, {required int assetType}) {
  if (raw == null) {
    // Debt (type == 4) polarity is inverted: 0 = counted in net worth.
    return assetType == 4 ? 0 : 1;
  }
  if (raw is int) return raw;
  if (raw is bool) return raw ? 1 : 0;
  if (raw is String) {
    final trimmed = raw.trim().toLowerCase();
    if (trimmed == 'true') return 1;
    if (trimmed == 'false') return 0;
    final parsed = int.tryParse(trimmed);
    if (parsed != null) return parsed;
  }
  throw const Failure(FailureCode.corruptData, '账户净资产标志字段损坏');
}

String? _normalizeAssetCurrency(Object? raw) {
  if (raw == null) return null;
  if (raw is! String) {
    throw const Failure(FailureCode.corruptData, '账户币种字段格式非法');
  }
  final trimmed = raw.trim().toUpperCase();
  return trimmed.isEmpty ? null : trimmed;
}

String? _parseStringOrListCsv(Object? raw) {
  if (raw == null) return null;
  if (raw is String) {
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  if (raw is List) {
    final items = <String>[];
    for (final e in raw) {
      if (e == null) continue;
      if (e is String) {
        final t = e.trim();
        if (t.isNotEmpty) items.add(t);
      } else if (e is Map) {
        final candidate = _optNullableString(e, const <String>[
          'fname',
          'fileName',
          'file_name',
          'path',
          'localPath',
          'name',
          'url',
          'uri',
        ]);
        if (candidate != null) {
          items.add(candidate);
        } else if (!e.containsKey('fname')) {
          items.add(encodeLosslessJson(e));
        }
      } else {
        final t = e.toString().trim();
        if (t.isNotEmpty) items.add(t);
      }
    }
    return items.isEmpty ? null : items.join(',');
  }
  throw const Failure(FailureCode.corruptData, '列表文本字段格式非法');
}

String? _parseCreditedJson(Object? raw) {
  if (raw == null) return null;
  if (raw is String) {
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  if (raw is List) {
    final ints = <int>[
      for (final item in raw)
        if (item != null) _asInt(item, 'installments.credited')!,
    ];
    return jsonEncode(ints);
  }
  throw const Failure(FailureCode.corruptData, '分期已入账字段格式非法');
}

String _parsePeriodTypeDateJson(Object? raw) {
  if (raw == null) return '[]';
  if (raw is String) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '[]';
    if (trimmed.startsWith('[')) return trimmed;
    final parts = [
      for (final p in trimmed.split(','))
        if (p.trim().isNotEmpty) p.trim(),
    ];
    return jsonEncode(parts);
  }
  if (raw is List) {
    final tokens = <String>[
      for (final e in raw)
        if (e != null && e.toString().trim().isNotEmpty) e.toString().trim(),
    ];
    return jsonEncode(tokens);
  }
  throw const Failure(FailureCode.corruptData, '周期日期字段格式非法');
}
