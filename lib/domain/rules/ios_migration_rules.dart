import 'dart:convert';
import 'dart:typed_data';

import '../../core/failure.dart';
import '../../core/money.dart';
import 'reminder_rules.dart';

/// Standard exported `.ya2i` file name (Android -> iOS, zero legacy brand text).
const String defaultYa2iExportFileName = 'TallyIsle-Android2iOS.ya2i';

/// Historical hardcoded Zip4j password used by LAN `ServerBackup.zip` (`DR-IMP-09`).
const String historicalLanZipPassword = 'YYjz@23!';

/// Tombstone status code from original cloud-sync entities (`DR-BK-08`).
const int _tombstoneStatus = 4;

/// Canonical 19 cross-OS root list keys in `.ya2i` / `.yi2a` (`docs/modules/ios-migration.md` §2.1).
const List<String> iosMigrationListKeys = <String>[
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
];

/// Validates `.yi2a` import file extension (`docs/modules/ios-migration.md` §2.1, `EX-20`):
/// - Empty / blank extension is allowed (short-circuit pass).
/// - Non-blank extension must strictly equal lowercase `'yi2a'`.
void validateYi2aFileName(String fileName) {
  final slashIdx = fileName.lastIndexOf(RegExp(r'[/\\]'));
  final baseName = slashIdx >= 0 ? fileName.substring(slashIdx + 1) : fileName;
  final dotIdx = baseName.lastIndexOf('.');
  if (dotIdx < 0) return;
  final ext = baseName.substring(dotIdx + 1);
  if (ext.trim().isEmpty) return;
  if (ext != 'yi2a') {
    throw const Failure(FailureCode.validation, '不支持的文件格式，请选择 .yi2a 跨端迁移文件');
  }
}

/// Exact decimal literal emitted as an unquoted JSON number in `.ya2i` export
/// so `int64` minor units format to exact 2-decimal numbers without IEEE-754 `double`.
final class JsonDecimalNumber {
  const JsonDecimalNumber(this.literal);

  factory JsonDecimalNumber.fromMinor(BigInt minor) =>
      JsonDecimalNumber(Money.minor(minor).decimal);

  final String literal;

  @override
  bool operator ==(Object other) =>
      other is JsonDecimalNumber && other.literal == literal;

  @override
  int get hashCode => literal.hashCode;

  @override
  String toString() => literal;
}

/// Encodes a JSON value tree to UTF-8 text, emitting [JsonDecimalNumber] as raw
/// unquoted JSON numbers (`1234.56`) without any `double` conversion.
String encodeMigrationJson(Object? value) {
  final buffer = StringBuffer();
  _writeJsonValue(buffer, value);
  return buffer.toString();
}

void _writeJsonValue(StringBuffer out, Object? value) {
  if (value == null) {
    out.write('null');
    return;
  }
  if (value is JsonDecimalNumber) {
    out.write(value.literal);
    return;
  }
  if (value is bool) {
    out.write(value ? 'true' : 'false');
    return;
  }
  if (value is int || value is BigInt) {
    out.write(value.toString());
    return;
  }
  if (value is num) {
    if (!value.isFinite) {
      throw const Failure(FailureCode.validation, 'JSON 数值不能为 NaN 或无穷大');
    }
    out.write(value.toString());
    return;
  }
  if (value is String) {
    out.write(jsonEncode(value));
    return;
  }
  if (value is List) {
    out.write('[');
    for (var i = 0; i < value.length; i++) {
      if (i > 0) out.write(',');
      _writeJsonValue(out, value[i]);
    }
    out.write(']');
    return;
  }
  if (value is Map) {
    out.write('{');
    var first = true;
    for (final entry in value.entries) {
      if (!first) out.write(',');
      first = false;
      out.write(jsonEncode(entry.key.toString()));
      out.write(':');
      _writeJsonValue(out, entry.value);
    }
    out.write('}');
    return;
  }
  throw Failure(FailureCode.validation, '不支持的序列化类型: ${value.runtimeType}');
}

/// Lossless RFC 8259 JSON decoder that NEVER materializes IEEE-754 `double`
/// values: 64-bit JSON integers become [int], while fractional, scientific, or
/// >64-bit JSON number literals become [JsonDecimalNumber] preserving their
/// exact decimal lexeme.
Object? decodeLosslessJson(String source) {
  final parser = _LosslessJsonReader(source);
  final value = parser.readValue();
  parser.skipWhitespace();
  if (!parser.isAtEnd) {
    throw const FormatException(
      'Unexpected trailing characters after JSON value',
    );
  }
  return value;
}

final class _LosslessJsonReader {
  _LosslessJsonReader(this.src);

  final String src;
  int pos = 0;

  bool get isAtEnd => pos >= src.length;

  void skipWhitespace() {
    while (pos < src.length) {
      final cu = src.codeUnitAt(pos);
      if (cu == 0x20 || cu == 0x09 || cu == 0x0a || cu == 0x0d) {
        pos++;
      } else {
        break;
      }
    }
  }

  Object? readValue() {
    skipWhitespace();
    if (pos >= src.length) {
      throw const FormatException('Unexpected end of JSON input');
    }
    final cu = src.codeUnitAt(pos);
    switch (cu) {
      case 0x7b: // '{'
        return _readObject();
      case 0x5b: // '['
        return _readArray();
      case 0x22: // '"'
        return _readString();
      case 0x74: // 't'
        return _readLiteral('true', true);
      case 0x66: // 'f'
        return _readLiteral('false', false);
      case 0x6e: // 'n'
        return _readLiteral('null', null);
      default:
        if (cu == 0x2d || (cu >= 0x30 && cu <= 0x39)) {
          return _readNumber();
        }
        throw FormatException('Unexpected character in JSON at offset $pos');
    }
  }

  Map<String, Object?> _readObject() {
    pos++; // skip '{'
    skipWhitespace();
    final map = <String, Object?>{};
    if (pos < src.length && src.codeUnitAt(pos) == 0x7d) {
      pos++;
      return map;
    }
    while (true) {
      skipWhitespace();
      if (pos >= src.length || src.codeUnitAt(pos) != 0x22) {
        throw FormatException('Expected JSON object key string at offset $pos');
      }
      final key = _readString();
      skipWhitespace();
      if (pos >= src.length || src.codeUnitAt(pos) != 0x3a) {
        throw FormatException('Expected ":" after object key at offset $pos');
      }
      pos++;
      map[key] = readValue();
      skipWhitespace();
      if (pos >= src.length) {
        throw const FormatException('Unterminated JSON object');
      }
      final sep = src.codeUnitAt(pos);
      if (sep == 0x7d) {
        pos++;
        return map;
      }
      if (sep != 0x2c) {
        throw FormatException('Expected "," or "}" in object at offset $pos');
      }
      pos++;
    }
  }

  List<Object?> _readArray() {
    pos++; // skip '['
    skipWhitespace();
    final list = <Object?>[];
    if (pos < src.length && src.codeUnitAt(pos) == 0x5d) {
      pos++;
      return list;
    }
    while (true) {
      list.add(readValue());
      skipWhitespace();
      if (pos >= src.length) {
        throw const FormatException('Unterminated JSON array');
      }
      final sep = src.codeUnitAt(pos);
      if (sep == 0x5d) {
        pos++;
        return list;
      }
      if (sep != 0x2c) {
        throw FormatException('Expected "," or "]" in array at offset $pos');
      }
      pos++;
    }
  }

  String _readString() {
    final start = pos;
    pos++; // skip opening '"'
    var hasEscape = false;
    while (pos < src.length) {
      final cu = src.codeUnitAt(pos);
      if (cu == 0x22) {
        pos++;
        if (!hasEscape) {
          return src.substring(start + 1, pos - 1);
        }
        return jsonDecode(src.substring(start, pos)) as String;
      }
      if (cu == 0x5c) {
        hasEscape = true;
        pos += 2;
        continue;
      }
      if (cu < 0x20) {
        throw FormatException('Unescaped control character at offset $pos');
      }
      pos++;
    }
    throw const FormatException('Unterminated JSON string');
  }

  Object? _readLiteral(String word, Object? value) {
    if (pos + word.length <= src.length && src.startsWith(word, pos)) {
      pos += word.length;
      return value;
    }
    throw FormatException('Invalid JSON literal at offset $pos');
  }

  Object _readNumber() {
    final start = pos;
    var isFractionOrExp = false;
    if (src.codeUnitAt(pos) == 0x2d) {
      pos++;
      if (pos >= src.length) {
        throw const FormatException('Invalid JSON minus sign');
      }
    }
    final firstDigit = src.codeUnitAt(pos);
    if (firstDigit == 0x30) {
      pos++;
      if (pos < src.length) {
        final next = src.codeUnitAt(pos);
        if (next >= 0x30 && next <= 0x39) {
          throw FormatException('Leading zero in JSON number at offset $start');
        }
      }
    } else if (firstDigit >= 0x31 && firstDigit <= 0x39) {
      pos++;
      while (pos < src.length) {
        final cu = src.codeUnitAt(pos);
        if (cu >= 0x30 && cu <= 0x39) {
          pos++;
        } else {
          break;
        }
      }
    } else {
      throw FormatException('Expected digit in JSON number at offset $pos');
    }

    if (pos < src.length && src.codeUnitAt(pos) == 0x2e) {
      isFractionOrExp = true;
      pos++;
      if (pos >= src.length ||
          src.codeUnitAt(pos) < 0x30 ||
          src.codeUnitAt(pos) > 0x39) {
        throw FormatException('Expected digit after decimal point at $pos');
      }
      while (pos < src.length) {
        final cu = src.codeUnitAt(pos);
        if (cu >= 0x30 && cu <= 0x39) {
          pos++;
        } else {
          break;
        }
      }
    }

    if (pos < src.length) {
      final cu = src.codeUnitAt(pos);
      if (cu == 0x65 || cu == 0x45) {
        isFractionOrExp = true;
        pos++;
        if (pos < src.length &&
            (src.codeUnitAt(pos) == 0x2b || src.codeUnitAt(pos) == 0x2d)) {
          pos++;
        }
        if (pos >= src.length ||
            src.codeUnitAt(pos) < 0x30 ||
            src.codeUnitAt(pos) > 0x39) {
          throw FormatException('Expected exponent digits at offset $pos');
        }
        while (pos < src.length) {
          final ecu = src.codeUnitAt(pos);
          if (ecu >= 0x30 && ecu <= 0x39) {
            pos++;
          } else {
            break;
          }
        }
      }
    }

    final lexeme = src.substring(start, pos);
    if (!isFractionOrExp) {
      final parsedInt = int.tryParse(lexeme);
      if (parsedInt != null) return parsedInt;
    }
    return JsonDecimalNumber(lexeme);
  }
}

final RegExp _scientificDecimalPattern = RegExp(
  r'^([+-]?)(?:([0-9]+)(?:\.([0-9]*))?|\.([0-9]+))(?:[eE]([+-]?[0-9]+))?$',
);

/// Parses a major-unit decimal (`num`, `String`, `int`, `BigInt`, `DecimalValue`)
/// into exact `int64` minor units (scale 2, `HALF_UP`), with ZERO `double` math.
BigInt parseMajorToMinor(Object? raw, {String fieldName = '金额'}) {
  final dec = parseExactDecimal(raw, fieldName: fieldName);
  final minor = dec.unitsAt(Money.ledgerScale, rounding: RoundingMode.halfUp);
  return Money.minor(minor).storageMinor;
}

/// Parses an arbitrary decimal or scientific-notation number into [DecimalValue]
/// without any floating-point arithmetic.
DecimalValue parseExactDecimal(Object? raw, {String fieldName = '数值'}) {
  if (raw is JsonDecimalNumber) raw = raw.literal;
  if (raw is DecimalValue) return raw;
  if (raw is BigInt) return DecimalValue(raw, 0);
  if (raw is int) return DecimalValue(BigInt.from(raw), 0);
  final String text;
  if (raw is num) {
    if (!raw.isFinite) {
      throw Failure(FailureCode.corruptData, '$fieldName数值非法');
    }
    text = raw.toString().trim();
  } else if (raw is String) {
    text = raw.trim();
  } else {
    throw Failure(FailureCode.corruptData, '$fieldName格式无效');
  }
  if (text.isEmpty) {
    throw Failure(FailureCode.corruptData, '$fieldName不能为空');
  }
  final match = _scientificDecimalPattern.firstMatch(text);
  if (match == null) {
    throw Failure(FailureCode.corruptData, '$fieldName十进制格式损坏');
  }
  final sign = match.group(1) == '-' ? '-' : '';
  final intPart = match.group(2) ?? '0';
  final fracPart = match.group(3) ?? match.group(4) ?? '';
  final expText = match.group(5);
  final exp = expText == null ? 0 : int.parse(expText);

  final digits = '$intPart$fracPart';
  var scale = fracPart.length - exp;
  var coeff = BigInt.parse('$sign$digits');
  if (coeff == BigInt.zero) {
    return DecimalValue(BigInt.zero, scale.clamp(0, 30));
  }
  if (scale < 0) {
    final shift = -scale;
    if (shift > 30) {
      throw Failure(FailureCode.validation, '$fieldName超出可表示范围');
    }
    coeff *= powerOfTen(shift);
    scale = 0;
  } else if (scale > 30) {
    final extra = scale - 30;
    final factor = BigInt.from(10).pow(extra);
    coeff = divideRounded(coeff, factor, RoundingMode.halfUp);
    scale = 30;
  }
  return DecimalValue(coeff, scale);
}

/// Formats [DecimalValue] as a trimmed decimal string (e.g. `0.024`, `7.25`, `1`).
String formatExactDecimalString(DecimalValue value) {
  if (value.scale == 0) return value.coefficient.toString();
  final negative = value.coefficient.isNegative;
  final digits = value.coefficient.abs().toString().padLeft(
    value.scale + 1,
    '0',
  );
  final head = digits.substring(0, digits.length - value.scale);
  final tail = digits.substring(digits.length - value.scale);
  var text = '${negative ? '-' : ''}$head.$tail';
  text = text.replaceFirst(RegExp(r'0+$'), '');
  if (text.endsWith('.')) {
    text = text.substring(0, text.length - 1);
  }
  return text == '-0' ? '0' : text;
}

BigInt? _parseMinorStoredOrMajor(Object? raw, {required bool sourceIsMinor}) {
  if (raw == null) return null;
  if (raw is JsonDecimalNumber) {
    return _parseMinorStoredOrMajor(raw.literal, sourceIsMinor: sourceIsMinor);
  }
  if (sourceIsMinor) {
    if (raw is BigInt) return Money.minor(raw).storageMinor;
    if (raw is int) return Money.minor(BigInt.from(raw)).storageMinor;
    if (raw is String) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) return null;
      final parsedInt = BigInt.tryParse(trimmed);
      if (parsedInt != null) return Money.minor(parsedInt).storageMinor;
      return parseMajorToMinor(trimmed);
    }
    if (raw is num) {
      return parseMajorToMinor(raw);
    }
    throw const Failure(FailureCode.corruptData, '内嵌金额字段损坏');
  }
  if (raw is String && raw.trim().isEmpty) return null;
  return parseMajorToMinor(raw);
}

// ============================================================================
// Embedded JSON Column Converters (Import -> TallyIsle minor strings,
// Export -> Original 2-decimal JSON numbers)
// ============================================================================

/// Converts `record.extra_info` (`curr` and `adbi` / flat advance keys) from
/// original major-unit JSON numbers to TallyIsle minor-unit strings.
String? convertRecordExtraInfoOnImport(
  String? rawJson, {
  bool sourceIsMinor = false,
}) {
  if (rawJson == null || rawJson.trim().isEmpty) return rawJson;
  final map = _decodeJsonMap(rawJson, '账单附加信息');
  final curr = map['curr'];
  if (curr is Map) {
    final nextCurr = <String, Object?>{
      for (final e in curr.entries) e.key.toString(): e.value,
    };
    for (final key in const ['sm', 'am', 'bm', 'dam', 'dbm']) {
      if (nextCurr[key] != null) {
        final m = _parseMinorStoredOrMajor(
          nextCurr[key],
          sourceIsMinor: sourceIsMinor,
        );
        if (m != null) nextCurr[key] = m.toString();
      }
    }
    map['curr'] = nextCurr;
  }
  final adbi = map['adbi'];
  if (adbi is Map) {
    final nextAdbi = <String, Object?>{
      for (final e in adbi.entries) e.key.toString(): e.value,
    };
    _convertAdvanceMapToMinor(nextAdbi, sourceIsMinor: sourceIsMinor);
    map['adbi'] = nextAdbi;
  }
  _convertAdvanceMapToMinor(map, sourceIsMinor: sourceIsMinor);
  return encodeMigrationJson(map);
}

void _convertAdvanceMapToMinor(
  Map<String, Object?> target, {
  required bool sourceIsMinor,
}) {
  for (final key in const ['advanceMoney', 'advanceDiffMoney']) {
    if (target[key] != null) {
      final m = _parseMinorStoredOrMajor(
        target[key],
        sourceIsMinor: sourceIsMinor,
      );
      if (m != null) target[key] = m.toString();
    }
  }
  if (target['partialInclude'] is int) {
    target['partialInclude'] = (target['partialInclude'] as int) != 0;
  }
}

/// Converts TallyIsle `record.extra_info` back to original major-unit numbers
/// for `.ya2i` export.
String? convertRecordExtraInfoOnExport(String? storedJson) {
  if (storedJson == null || storedJson.trim().isEmpty) return storedJson;
  final map = _decodeJsonMap(storedJson, '账单附加信息');
  final curr = map['curr'];
  if (curr is Map) {
    final nextCurr = <String, Object?>{
      for (final e in curr.entries) e.key.toString(): e.value,
    };
    for (final key in const ['sm', 'am', 'bm', 'dam', 'dbm']) {
      final m = _parseMinorStoredOrMajor(nextCurr[key], sourceIsMinor: true);
      if (m != null) nextCurr[key] = JsonDecimalNumber.fromMinor(m);
    }
    map['curr'] = nextCurr;
  }
  final adbi = map['adbi'];
  if (adbi is Map) {
    final nextAdbi = <String, Object?>{
      for (final e in adbi.entries) e.key.toString(): e.value,
    };
    for (final key in const ['advanceMoney', 'advanceDiffMoney']) {
      final m = _parseMinorStoredOrMajor(nextAdbi[key], sourceIsMinor: true);
      if (m != null) nextAdbi[key] = JsonDecimalNumber.fromMinor(m);
    }
    map['adbi'] = nextAdbi;
  }
  for (final key in const ['advanceMoney', 'advanceDiffMoney']) {
    final m = _parseMinorStoredOrMajor(map[key], sourceIsMinor: true);
    if (m != null) map[key] = JsonDecimalNumber.fromMinor(m);
  }
  return encodeMigrationJson(map);
}

/// Converts `record.rel_info` (`lrefundi.rfbinfo`, `lreimbursei.ribinfo`,
/// `ltfeei.tfbinfo`) to TallyIsle minor-unit strings.
String? convertRecordRelInfoOnImport(
  String? rawJson, {
  bool sourceIsMinor = false,
}) {
  if (rawJson == null || rawJson.trim().isEmpty) return rawJson;
  final map = _decodeJsonMap(rawJson, '账单关联信息');
  for (final (blockKey, listKey) in const [
    ('lrefundi', 'rfbinfo'),
    ('lreimbursei', 'ribinfo'),
  ]) {
    final block = map[blockKey];
    if (block is Map) {
      final nextBlock = <String, Object?>{
        for (final e in block.entries) e.key.toString(): e.value,
      };
      final items = nextBlock[listKey];
      if (items is List) {
        nextBlock[listKey] = [
          for (final item in items)
            if (item is Map)
              _convertLinkedBillMapOnImport(item, sourceIsMinor: sourceIsMinor)
            else
              item,
        ];
      }
      map[blockKey] = nextBlock;
    }
  }
  final ltfeei = map['ltfeei'];
  if (ltfeei is Map) {
    final nextFee = <String, Object?>{
      for (final e in ltfeei.entries) e.key.toString(): e.value,
    };
    if (nextFee['tff'] is bool) {
      nextFee['tff'] = (nextFee['tff'] as bool) ? 1 : 0;
    }
    if (nextFee['tfrepay'] is int) {
      nextFee['tfrepay'] = (nextFee['tfrepay'] as int) != 0;
    }
    if (nextFee['tfbinfo'] is Map) {
      nextFee['tfbinfo'] = _convertLinkedBillMapOnImport(
        nextFee['tfbinfo'] as Map,
        sourceIsMinor: sourceIsMinor,
      );
    }
    map['ltfeei'] = nextFee;
  }
  return encodeMigrationJson(map);
}

Map<String, Object?> _convertLinkedBillMapOnImport(
  Map<Object?, Object?> item, {
  required bool sourceIsMinor,
}) {
  final next = <String, Object?>{
    for (final e in item.entries) e.key.toString(): e.value,
  };
  for (final key in const ['lbm', 'am', 'bm']) {
    if (next[key] != null) {
      final m = _parseMinorStoredOrMajor(
        next[key],
        sourceIsMinor: sourceIsMinor,
      );
      if (m != null) next[key] = m.toString();
    }
  }
  return next;
}

/// Converts TallyIsle `record.rel_info` back to original major-unit numbers.
String? convertRecordRelInfoOnExport(String? storedJson) {
  if (storedJson == null || storedJson.trim().isEmpty) return storedJson;
  final map = _decodeJsonMap(storedJson, '账单关联信息');
  for (final (blockKey, listKey) in const [
    ('lrefundi', 'rfbinfo'),
    ('lreimbursei', 'ribinfo'),
  ]) {
    final block = map[blockKey];
    if (block is Map) {
      final nextBlock = <String, Object?>{
        for (final e in block.entries) e.key.toString(): e.value,
      };
      final items = nextBlock[listKey];
      if (items is List) {
        nextBlock[listKey] = [
          for (final item in items)
            if (item is Map) _convertLinkedBillMapOnExport(item) else item,
        ];
      }
      map[blockKey] = nextBlock;
    }
  }
  final ltfeei = map['ltfeei'];
  if (ltfeei is Map) {
    final nextFee = <String, Object?>{
      for (final e in ltfeei.entries) e.key.toString(): e.value,
    };
    if (nextFee['tfbinfo'] is Map) {
      nextFee['tfbinfo'] = _convertLinkedBillMapOnExport(
        nextFee['tfbinfo'] as Map,
      );
    }
    map['ltfeei'] = nextFee;
  }
  return encodeMigrationJson(map);
}

Map<String, Object?> _convertLinkedBillMapOnExport(Map<Object?, Object?> item) {
  final next = <String, Object?>{
    for (final e in item.entries) e.key.toString(): e.value,
  };
  for (final key in const ['lbm', 'am', 'bm']) {
    final m = _parseMinorStoredOrMajor(next[key], sourceIsMinor: true);
    if (m != null) next[key] = JsonDecimalNumber.fromMinor(m);
  }
  return next;
}

/// Converts `asset.credit_info` (`inst[*].{b,i}` & legacy `installment`) to
/// TallyIsle minor-unit strings.
String? convertAssetCreditInfoOnImport(
  String? rawJson, {
  bool sourceIsMinor = false,
}) {
  if (rawJson == null || rawJson.trim().isEmpty) return rawJson;
  final map = _decodeJsonMap(rawJson, '信用账户信息');
  for (final boolKey in const [
    'repayment_day_after_bd',
    'bill_day_count',
    'ifc',
  ]) {
    if (map[boolKey] is int) {
      map[boolKey] = (map[boolKey] as int) != 0;
    }
  }
  final inst = map['inst'];
  if (inst is List) {
    map['inst'] = [
      for (final item in inst)
        if (item is Map)
          () {
            final next = <String, Object?>{
              for (final e in item.entries) e.key.toString(): e.value,
            };
            for (final key in const ['b', 'i']) {
              if (next[key] != null) {
                final m = _parseMinorStoredOrMajor(
                  next[key],
                  sourceIsMinor: sourceIsMinor,
                );
                if (m != null) next[key] = m.toString();
              }
            }
            for (final bk in const ['cb', 'ci']) {
              if (next[bk] is int) next[bk] = (next[bk] as int) != 0;
            }
            return next;
          }()
        else
          item,
    ];
  }
  if (map['installment'] != null) {
    final m = _parseMinorStoredOrMajor(
      map['installment'],
      sourceIsMinor: sourceIsMinor,
    );
    if (m != null) map['installment'] = m.toString();
  }
  return encodeMigrationJson(map);
}

String? convertAssetCreditInfoOnExport(String? storedJson) {
  if (storedJson == null || storedJson.trim().isEmpty) return storedJson;
  final map = _decodeJsonMap(storedJson, '信用账户信息');
  final inst = map['inst'];
  if (inst is List) {
    map['inst'] = [
      for (final item in inst)
        if (item is Map)
          () {
            final next = <String, Object?>{
              for (final e in item.entries) e.key.toString(): e.value,
            };
            for (final key in const ['b', 'i']) {
              final m = _parseMinorStoredOrMajor(
                next[key],
                sourceIsMinor: true,
              );
              if (m != null) next[key] = JsonDecimalNumber.fromMinor(m);
            }
            return next;
          }()
        else
          item,
    ];
  }
  if (map['installment'] != null) {
    final m = _parseMinorStoredOrMajor(map['installment'], sourceIsMinor: true);
    if (m != null) map['installment'] = JsonDecimalNumber.fromMinor(m);
  }
  return encodeMigrationJson(map);
}

/// Converts `asset.extra_info` (`temp_amt[*].m`, `ann_fee.{amt,fee}`) to
/// TallyIsle minor-unit strings.
String? convertAssetExtraInfoOnImport(
  String? rawJson, {
  bool sourceIsMinor = false,
}) {
  if (rawJson == null || rawJson.trim().isEmpty) return rawJson;
  final map = _decodeJsonMap(rawJson, '账户附加信息');
  final tempAmt = map['temp_amt'];
  if (tempAmt is List) {
    map['temp_amt'] = [
      for (final item in tempAmt)
        if (item is Map)
          () {
            final next = <String, Object?>{
              for (final e in item.entries) e.key.toString(): e.value,
            };
            if (next['m'] != null) {
              final m = _parseMinorStoredOrMajor(
                next['m'],
                sourceIsMinor: sourceIsMinor,
              );
              if (m != null) next['m'] = m.toString();
            }
            return next;
          }()
        else
          item,
    ];
  }
  final annFee = map['ann_fee'];
  if (annFee is Map) {
    final nextAnn = <String, Object?>{
      for (final e in annFee.entries) e.key.toString(): e.value,
    };
    for (final key in const ['amt', 'fee']) {
      if (nextAnn[key] != null) {
        final m = _parseMinorStoredOrMajor(
          nextAnn[key],
          sourceIsMinor: sourceIsMinor,
        );
        if (m != null) nextAnn[key] = m.toString();
      }
    }
    map['ann_fee'] = nextAnn;
  }
  return encodeMigrationJson(map);
}

String? convertAssetExtraInfoOnExport(String? storedJson) {
  if (storedJson == null || storedJson.trim().isEmpty) return storedJson;
  final map = _decodeJsonMap(storedJson, '账户附加信息');
  final tempAmt = map['temp_amt'];
  if (tempAmt is List) {
    map['temp_amt'] = [
      for (final item in tempAmt)
        if (item is Map)
          () {
            final next = <String, Object?>{
              for (final e in item.entries) e.key.toString(): e.value,
            };
            final m = _parseMinorStoredOrMajor(next['m'], sourceIsMinor: true);
            if (m != null) next['m'] = JsonDecimalNumber.fromMinor(m);
            return next;
          }()
        else
          item,
    ];
  }
  final annFee = map['ann_fee'];
  if (annFee is Map) {
    final nextAnn = <String, Object?>{
      for (final e in annFee.entries) e.key.toString(): e.value,
    };
    for (final key in const ['amt', 'fee']) {
      final m = _parseMinorStoredOrMajor(nextAnn[key], sourceIsMinor: true);
      if (m != null) nextAnn[key] = JsonDecimalNumber.fromMinor(m);
    }
    map['ann_fee'] = nextAnn;
  }
  return encodeMigrationJson(map);
}

/// Converts `asset.loan_info` (`totalDebtMoney`, `sb`, `cp[*].{pb,tp}`) to
/// TallyIsle minor-unit strings.
String? convertAssetLoanInfoOnImport(
  String? rawJson, {
  bool sourceIsMinor = false,
}) {
  if (rawJson == null || rawJson.trim().isEmpty) return rawJson;
  final map = _decodeJsonMap(rawJson, '借贷附加信息');
  for (final key in const ['totalDebtMoney', 'sb']) {
    if (map[key] != null) {
      final m = _parseMinorStoredOrMajor(
        map[key],
        sourceIsMinor: sourceIsMinor,
      );
      if (m != null) map[key] = m.toString();
    }
  }
  if (map['s'] is int) {
    map['s'] = (map['s'] as int) != 0;
  }
  final cp = map['cp'];
  if (cp is List) {
    map['cp'] = [
      for (final item in cp)
        if (item is Map)
          () {
            final next = <String, Object?>{
              for (final e in item.entries) e.key.toString(): e.value,
            };
            for (final key in const ['pb', 'tp']) {
              if (next[key] != null) {
                final m = _parseMinorStoredOrMajor(
                  next[key],
                  sourceIsMinor: sourceIsMinor,
                );
                if (m != null) next[key] = m.toString();
              }
            }
            return next;
          }()
        else
          item,
    ];
  }
  return encodeMigrationJson(map);
}

String? convertAssetLoanInfoOnExport(String? storedJson) {
  if (storedJson == null || storedJson.trim().isEmpty) return storedJson;
  final map = _decodeJsonMap(storedJson, '借贷附加信息');
  for (final key in const ['totalDebtMoney', 'sb']) {
    final m = _parseMinorStoredOrMajor(map[key], sourceIsMinor: true);
    if (m != null) map[key] = JsonDecimalNumber.fromMinor(m);
  }
  final cp = map['cp'];
  if (cp is List) {
    map['cp'] = [
      for (final item in cp)
        if (item is Map)
          () {
            final next = <String, Object?>{
              for (final e in item.entries) e.key.toString(): e.value,
            };
            for (final key in const ['pb', 'tp']) {
              final m = _parseMinorStoredOrMajor(
                next[key],
                sourceIsMinor: true,
              );
              if (m != null) next[key] = JsonDecimalNumber.fromMinor(m);
            }
            return next;
          }()
        else
          item,
    ];
  }
  return encodeMigrationJson(map);
}

/// Converts `asset.fixed_deposit_info` (`List<FixedDepositInfo>`) between
/// original major-unit keys (`money`, `expected_income`, `am`, `bm`) and
/// TallyIsle minor-unit keys (`money_minor`, `expected_income_minor`, `am_minor`, `bm_minor`).
String? convertAssetFixedDepositInfoOnImport(
  String? rawJson, {
  bool sourceIsMinor = false,
}) {
  if (rawJson == null || rawJson.trim().isEmpty) return rawJson;
  final Object? decoded;
  try {
    decoded = decodeLosslessJson(rawJson);
  } on FormatException {
    throw const Failure(FailureCode.corruptData, '定期存款数据格式损坏');
  }
  if (decoded is! List) {
    throw const Failure(FailureCode.corruptData, '定期存款数据格式损坏');
  }
  if (decoded.isEmpty) return null;
  final converted = <Map<String, Object?>>[];
  for (final entry in decoded) {
    if (entry is! Map) {
      throw const Failure(FailureCode.corruptData, '定期存款条目格式损坏');
    }
    final next = <String, Object?>{};
    for (final e in entry.entries) {
      next[e.key.toString()] = e.value;
    }
    BigInt resolveDepositMinor(String minorKey, String majorKey) {
      if (next[minorKey] != null) {
        return _parseMinorStoredOrMajor(next[minorKey], sourceIsMinor: true) ??
            BigInt.zero;
      }
      if (next[majorKey] != null) {
        return _parseMinorStoredOrMajor(
              next[majorKey],
              sourceIsMinor: sourceIsMinor,
            ) ??
            BigInt.zero;
      }
      return BigInt.zero;
    }

    final moneyMinor = resolveDepositMinor('money_minor', 'money');
    final expectedMinor = resolveDepositMinor(
      'expected_income_minor',
      'expected_income',
    );
    final amMinor = resolveDepositMinor('am_minor', 'am');
    final bmMinor = resolveDepositMinor('bm_minor', 'bm');
    next
      ..remove('money')
      ..remove('expected_income')
      ..remove('am')
      ..remove('bm');
    next['money_minor'] = moneyMinor.toString();
    next['expected_income_minor'] = expectedMinor.toString();
    next['am_minor'] = amMinor.toString();
    next['bm_minor'] = bmMinor.toString();

    if (next['annual_rate'] != null) {
      final rateDec = parseExactDecimal(
        next['annual_rate'],
        fieldName: '定存年利率',
      );
      next['annual_rate'] = formatExactDecimalString(rateDec);
    } else {
      next['annual_rate'] = '0';
    }
    if (next['update_asset_balance'] is int) {
      next['update_asset_balance'] = (next['update_asset_balance'] as int) != 0;
    }
    converted.add(next);
  }
  return encodeMigrationJson(converted);
}

String? convertAssetFixedDepositInfoOnExport(String? storedJson) {
  if (storedJson == null || storedJson.trim().isEmpty) return storedJson;
  final Object? decoded;
  try {
    decoded = decodeLosslessJson(storedJson);
  } on FormatException {
    throw const Failure(FailureCode.corruptData, '定期存款数据格式损坏');
  }
  if (decoded is! List) {
    throw const Failure(FailureCode.corruptData, '定期存款数据格式损坏');
  }
  if (decoded.isEmpty) return null;
  final out = <Map<String, Object?>>[];
  for (final entry in decoded) {
    if (entry is! Map) continue;
    final src = <String, Object?>{
      for (final e in entry.entries) e.key.toString(): e.value,
    };
    BigInt readDepositMinor(String minorKey, String majorKey) {
      if (src[minorKey] != null) {
        return _parseMinorStoredOrMajor(src[minorKey], sourceIsMinor: true) ??
            BigInt.zero;
      }
      if (src[majorKey] != null) {
        return _parseMinorStoredOrMajor(src[majorKey], sourceIsMinor: false) ??
            BigInt.zero;
      }
      return BigInt.zero;
    }

    final money = readDepositMinor('money_minor', 'money');
    final expected = readDepositMinor(
      'expected_income_minor',
      'expected_income',
    );
    final am = readDepositMinor('am_minor', 'am');
    final bm = readDepositMinor('bm_minor', 'bm');
    final rateText = src['annual_rate'] == null
        ? '0'
        : formatExactDecimalString(parseExactDecimal(src['annual_rate']));

    out.add({
      'money': JsonDecimalNumber.fromMinor(money),
      'from_asset_id': _asInt(src['from_asset_id'], fallback: -1),
      'update_asset_balance': _asBool(
        src['update_asset_balance'],
        fallback: false,
      ),
      'annual_rate': JsonDecimalNumber(rateText),
      'period_unit': _asInt(src['period_unit'], fallback: 2),
      'period_count': _asInt(src['period_count'], fallback: 1),
      'deposit_date': _asInt(src['deposit_date'], fallback: 0),
      'due_date': _asInt(src['due_date'], fallback: 0),
      'expected_income': JsonDecimalNumber.fromMinor(expected),
      'c': _asString(src['c'], fallback: ''),
      'ac': _asString(src['ac'], fallback: ''),
      'am': JsonDecimalNumber.fromMinor(am),
      'bc': _asString(src['bc'], fallback: ''),
      'bm': JsonDecimalNumber.fromMinor(bm),
      'remark': _asString(src['remark'], fallback: ''),
      'transfer_record_id': _asNullableString(src['transfer_record_id']),
      'income_record_id': _asNullableString(src['income_record_id']),
      'status': _asInt(src['status'], fallback: 0),
    });
  }
  return encodeMigrationJson(out);
}

/// Converts `budget.extra_info` (`base` amount) between original major decimal
/// and TallyIsle minor string.
String? convertBudgetExtraInfoOnImport(
  String? rawJson, {
  bool sourceIsMinor = false,
}) {
  if (rawJson == null || rawJson.trim().isEmpty) return rawJson;
  final map = _decodeJsonMap(rawJson, '预算附加信息');
  if (map['base'] != null) {
    final m = _parseMinorStoredOrMajor(
      map['base'],
      sourceIsMinor: sourceIsMinor,
    );
    if (m != null) map['base'] = m.toString();
  }
  for (final k in const ['acopy', 'forward']) {
    if (map[k] is int) map[k] = (map[k] as int) != 0;
  }
  return encodeMigrationJson(map);
}

String? convertBudgetExtraInfoOnExport(String? storedJson) {
  if (storedJson == null || storedJson.trim().isEmpty) return storedJson;
  final map = _decodeJsonMap(storedJson, '预算附加信息');
  if (map['base'] != null) {
    final m = _parseMinorStoredOrMajor(map['base'], sourceIsMinor: true);
    if (m != null) map['base'] = JsonDecimalNumber.fromMinor(m);
  }
  return encodeMigrationJson(map);
}

Map<String, Object?> _decodeJsonMap(String rawJson, String label) {
  final Object? decoded;
  try {
    decoded = decodeLosslessJson(rawJson);
  } on FormatException {
    throw Failure(FailureCode.corruptData, '$label JSON 格式损坏');
  }
  if (decoded is! Map) {
    throw Failure(FailureCode.corruptData, '$label JSON 顶层须为对象');
  }
  return <String, Object?>{
    for (final e in decoded.entries) e.key.toString(): e.value,
  };
}

// ============================================================================
// Pure Domain Row DTOs for the 19 Cross-OS Lists (+ optional local tables)
// ============================================================================

final class MigrationBookRow {
  const MigrationBookRow({
    required this.id,
    this.type = 1,
    required this.name,
    this.cover = '',
    this.sort = 1,
    this.status = 0,
    this.startDay = 1,
    required this.createDate,
    this.displayWay = 0,
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

final class MigrationCategoryRow {
  const MigrationCategoryRow({
    required this.id,
    required this.name,
    this.icon = '',
    required this.type,
    this.sort = 0,
    this.parentCatId = -1,
    this.colorFill,
    this.platformId = -1,
    required this.accountBookId,
    this.isHide = false,
    this.extraInfo,
  });

  final int id;
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

final class MigrationAssetRow {
  const MigrationAssetRow({
    required this.id,
    required this.name,
    required this.balanceMinor,
    required this.type,
    this.subType = -1,
    required this.createDate,
    this.sort = 0,
    this.icon = '',
    this.remark,
    required this.initMoneyMinor,
    this.isDefault = false,
    this.isEffectiveAsset = 1,
    this.usedTimes = 0,
    this.color,
    this.status = 0,
    this.extraInfo,
    this.loanInfo,
    this.creditInfo,
    this.fixedDepositInfo,
    this.groupName,
    this.currency,
  });

  final int id;
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

final class MigrationRecordRow {
  const MigrationRecordRow({
    required this.recordId,
    required this.type,
    this.subType = -1,
    required this.moneyMinor,
    this.remark = '',
    required this.recordTime,
    this.recordCatId = -1,
    this.assetId = -1,
    this.fromAssetId = -1,
    this.toAssetId = -1,
    required this.accountBookId,
    this.excludeBudget = false,
    this.excludeExIn = false,
    this.platformId = -1,
    this.periodId = -1,
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

final class MigrationBudgetRow {
  const MigrationBudgetRow({
    required this.id,
    required this.budgetType,
    this.recordCatId = -1,
    required this.amountMinor,
    required this.bookId,
    required this.section,
    this.sort = 0,
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

final class MigrationImportPlatformRow {
  const MigrationImportPlatformRow({
    required this.id,
    required this.platform,
    required this.importRecordCount,
    required this.importCategoryCount,
    required this.importTime,
    this.hidden = false,
  });

  final int id;
  final String platform;
  final int importRecordCount;
  final int importCategoryCount;
  final int importTime;
  final bool hidden;
}

final class MigrationInstallmentRow {
  const MigrationInstallmentRow({
    required this.id,
    required this.name,
    this.catId = -1,
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
    this.excludeBudget = false,
    this.excludeExIn = false,
    required this.createDate,
    this.tags,
    this.images,
    this.exi,
  });

  final int id;
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

final class MigrationPeriodRow {
  const MigrationPeriodRow({
    required this.id,
    required this.recordType,
    required this.moneyMinor,
    required this.feeMinor,
    this.remark = '',
    this.catId = -1,
    this.assetId = -1,
    this.assetId2 = -1,
    required this.bookId,
    this.images,
    this.state = 0,
    this.time,
    this.excludeBudget = false,
    this.excludeExIn = false,
    required this.periodType,
    required this.periodTypeDate,
    required this.periodStartDate,
    required this.periodEndDate,
    this.frequency = 1,
    this.lastAddDate = -1,
    this.periodAddTimes = 0,
    required this.createTime,
    this.tags,
    this.exi,
  });

  final int id;
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

final class MigrationReminderRow {
  const MigrationReminderRow({
    required this.id,
    required this.reminderTime,
    this.reminderTip,
  });

  final int id;
  final int reminderTime;
  final String? reminderTip;
}

final class MigrationTagRow {
  const MigrationTagRow({
    required this.tagId,
    required this.name,
    this.sort = 0,
    this.hidden = false,
    this.parentTagId,
    this.parent = 0,
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

final class MigrationTagRefRow {
  const MigrationTagRefRow({required this.tagId, required this.recordId});

  final String tagId;
  final String recordId;
}

final class MigrationTemplateRow {
  const MigrationTemplateRow({
    required this.id,
    required this.type,
    this.remark,
    required this.moneyMinor,
    required this.feeMinor,
    this.recordCatId,
    this.assetId = -1,
    this.assetId2 = -1,
    this.sort = 0,
    this.autoSave = false,
    required this.bookId,
    this.excludeBudget = false,
    this.excludeExIn = false,
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

final class MigrationBankCardRow {
  const MigrationBankCardRow({
    required this.id,
    required this.cardType,
    required this.cardName,
    required this.cardNo,
    required this.cardOwner,
    this.remark = '',
    this.cardColor,
    this.sort = -1,
    required this.createDate,
    this.cardAssetId = -1,
  });

  final int id;
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

final class MigrationWishRow {
  const MigrationWishRow({
    required this.id,
    required this.content,
    required this.valueMinor,
    required this.createDate,
    this.isRealized = false,
    this.realizedDate = 0,
    this.sort = 0,
    this.icon,
    this.targetDate = 0,
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

final class MigrationRemarkRow {
  const MigrationRemarkRow({
    required this.id,
    required this.content,
    required this.recordCatId,
    this.usedTimes = 0,
  });

  final int id;
  final String content;
  final int recordCatId;
  final int usedTimes;
}

final class MigrationSavingsPlanRow {
  const MigrationSavingsPlanRow({
    required this.id,
    required this.name,
    this.remark = '',
    required this.planType,
    required this.cycleType,
    required this.startDate,
    required this.endDate,
    required this.planMoneyMinor,
    required this.savedMoneyMinor,
    this.autoPlan = false,
    this.fromAssetId = -1,
    this.toAssetId = -1,
    this.bookId = -1,
    required this.startMoneyMinor,
    required this.incrementalMinor,
    this.status = 0,
    required this.createDate,
    this.sort = 0,
    required this.nextSaveDate,
    this.bbzDailyTimes = 0,
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

final class MigrationSavingsRecordRow {
  const MigrationSavingsRecordRow({
    required this.id,
    required this.planId,
    this.remark = '',
    this.fromAssetId = -1,
    this.toAssetId = -1,
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

final class MigrationAssetBookRow {
  const MigrationAssetBookRow({required this.assetId, required this.bookId});

  final int assetId;
  final int bookId;
}

final class MigrationStatStoryRow {
  const MigrationStatStoryRow({
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

final class MigrationNoteRow {
  const MigrationNoteRow({
    required this.id,
    this.title,
    required this.content,
    required this.createTime,
    required this.updateTime,
    this.trashTime = 0,
  });

  final int id;
  final String? title;
  final String content;
  final int createTime;
  final int updateTime;
  final int trashTime;
}

final class MigrationAutoMapRow {
  const MigrationAutoMapRow({
    required this.id,
    required this.key,
    this.mapInfo,
    this.draft,
  });

  final int id;
  final String key;
  final String? mapInfo;
  final String? draft;
}

final class MigrationCurrencyRow {
  const MigrationCurrencyRow({
    required this.code,
    required this.name,
    required this.symbol,
    this.type = 0,
    required this.rateToAnchor,
    required this.anchorCode,
    this.rateRefreshTime = 0,
    this.icon,
    this.enable = true,
  });

  final String code;
  final String name;
  final String symbol;
  final int type;
  final String rateToAnchor;
  final String anchorCode;
  final int rateRefreshTime;
  final String? icon;
  final bool enable;
}

/// Cleaned, preflight-verified migration payload across all 19 cross-OS tables
/// (plus optional LAN `.db` / `.ya2i` `extraNotes` rows).
final class MigrationPayload {
  const MigrationPayload({
    this.books = const [],
    this.categories = const [],
    this.assets = const [],
    this.records = const [],
    this.budgets = const [],
    this.importPlatforms = const [],
    this.installments = const [],
    this.periods = const [],
    this.reminders = const [],
    this.tags = const [],
    this.tagRefs = const [],
    this.templates = const [],
    this.bankCards = const [],
    this.wishes = const [],
    this.remarks = const [],
    this.moneySavePlans = const [],
    this.moneySavePlanRecords = const [],
    this.assetBookRefs = const [],
    this.statStory = const [],
    this.extraNotes = const [],
    this.lanNotes,
    this.lanAutoMaps,
    this.lanCurrencies,
  });

  final List<MigrationBookRow> books;
  final List<MigrationCategoryRow> categories;
  final List<MigrationAssetRow> assets;
  final List<MigrationRecordRow> records;
  final List<MigrationBudgetRow> budgets;
  final List<MigrationImportPlatformRow> importPlatforms;
  final List<MigrationInstallmentRow> installments;
  final List<MigrationPeriodRow> periods;
  final List<MigrationReminderRow> reminders;
  final List<MigrationTagRow> tags;
  final List<MigrationTagRefRow> tagRefs;
  final List<MigrationTemplateRow> templates;
  final List<MigrationBankCardRow> bankCards;
  final List<MigrationWishRow> wishes;
  final List<MigrationRemarkRow> remarks;
  final List<MigrationSavingsPlanRow> moneySavePlans;
  final List<MigrationSavingsRecordRow> moneySavePlanRecords;
  final List<MigrationAssetBookRow> assetBookRefs;
  final List<MigrationStatStoryRow> statStory;

  /// Optional exported `extraNotes` for `.ya2i` (§6.2). Never clears local `note` on `.yi2a` import (`R6`).
  final List<MigrationNoteRow> extraNotes;

  /// Optional non-empty tables read from LAN SQLite `.db` (null when absent/empty so local rows survive).
  final List<MigrationNoteRow>? lanNotes;
  final List<MigrationAutoMapRow>? lanAutoMaps;
  final List<MigrationCurrencyRow>? lanCurrencies;

  /// Total active entities across the 19 canonical cross-OS tables (`R1`).
  int get totalCrossEntityCount =>
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
      statStory.length;

  bool get isEmptyCrossPayload => totalCrossEntityCount == 0;

  /// Picks the active book ID to persist into `ti_preference.current_book_id` after import:
  /// prefers `id == 1` when present, otherwise first active book sorted by `(sort, id)`,
  /// otherwise `1` (which will be seeded if `books` is empty).
  int resolveActiveBookId() {
    if (books.isEmpty) return 1;
    for (final b in books) {
      if (b.id == 1 && b.status == 0) return 1;
    }
    for (final b in books) {
      if (b.id == 1) return 1;
    }
    final sorted = List<MigrationBookRow>.of(books)
      ..sort((a, b) {
        final s = a.sort.compareTo(b.sort);
        return s != 0 ? s : a.id.compareTo(b.id);
      });
    for (final b in sorted) {
      if (b.status == 0) return b.id;
    }
    return sorted.first.id;
  }
}

// ============================================================================
// `.yi2a` Deserializer & Preflight (`R1..R4`, `DEC-005`) + `.ya2i` Serializer
// ============================================================================

/// Parses and validates a `.yi2a` UTF-8 JSON file (`R1..R4`).
/// Throws [Failure] before any DB mutation if extension, JSON syntax, field types,
/// or non-empty preflight (`R1`) fail.
MigrationPayload parseYi2aBytes(
  Uint8List bytes, {
  String fileName = 'import.yi2a',
}) {
  validateYi2aFileName(fileName);
  if (bytes.isEmpty) {
    throw const Failure(FailureCode.validation, '迁移文件为空，已取消导入');
  }
  final String text;
  try {
    var decodedText = utf8.decode(bytes);
    if (decodedText.startsWith('\uFEFF')) {
      decodedText = decodedText.substring(1);
    }
    text = decodedText;
  } on FormatException {
    throw const Failure(FailureCode.corruptData, '迁移文件不是合法的 UTF-8 文本');
  }
  return parseYi2aJsonText(text);
}

/// Parses and validates `.yi2a` UTF-8 JSON text (`R1..R4`).
MigrationPayload parseYi2aJsonText(String jsonText) {
  final trimmed = jsonText.trim();
  if (trimmed.isEmpty) {
    throw const Failure(FailureCode.validation, '迁移文件内容为空，已拒绝导入');
  }
  final Object? root;
  try {
    root = decodeLosslessJson(trimmed);
  } on FormatException {
    throw const Failure(FailureCode.corruptData, '迁移文件 JSON 结构损坏');
  }
  if (root is! Map) {
    throw const Failure(FailureCode.corruptData, '迁移文件根结构必须为 JSON 对象');
  }

  final map = <String, Object?>{
    for (final e in root.entries) e.key.toString(): e.value,
  };

  List<Map<String, Object?>> activeMaps(String listKey) {
    final rawList = map[listKey];
    if (rawList == null) return const [];
    if (rawList is! List) {
      throw Failure(FailureCode.corruptData, '字段 $listKey 必须为数组');
    }
    final out = <Map<String, Object?>>[];
    for (final item in rawList) {
      if (item == null) continue;
      if (item is! Map) {
        throw Failure(FailureCode.corruptData, '字段 $listKey 包含非对象元素');
      }
      final m = <String, Object?>{
        for (final e in item.entries) e.key.toString(): e.value,
      };
      if (_isTombstone(m)) continue;
      out.add(m);
    }
    return out;
  }

  final books = deduplicateBooks([
    for (final m in activeMaps('books')) _parseBookFromJson(m),
  ]);
  final categories = _dedupeById([
    for (final m in activeMaps('categories')) _parseCategoryFromJson(m),
  ], (r) => r.id);
  final assets = _dedupeById([
    for (final m in activeMaps('assets')) _parseAssetFromJson(m),
  ], (r) => r.id);
  final records = _dedupeById([
    for (final m in activeMaps('records')) _parseRecordFromJson(m),
  ], (r) => r.recordId);
  final budgets = _dedupeById([
    for (final m in activeMaps('budgets')) _parseBudgetFromJson(m),
  ], (r) => r.id);
  final importPlatforms = _dedupeById([
    for (final m in activeMaps('importPlatforms'))
      _parseImportPlatformFromJson(m, strictBoolHidden: true),
  ], (r) => r.id);
  final installments = _dedupeById([
    for (final m in activeMaps('installments')) _parseInstallmentFromJson(m),
  ], (r) => r.id);
  final periods = _dedupeById([
    for (final m in activeMaps('periods')) _parsePeriodFromJson(m),
  ], (r) => r.id);
  final reminders = _dedupeById([
    for (final m in activeMaps('reminders')) _parseReminderFromJson(m),
  ], (r) => r.id);
  final tags = _dedupeById([
    for (final m in activeMaps('tags')) _parseTagFromJson(m),
  ], (r) => r.tagId);
  final tagRefs = _dedupeById([
    for (final m in activeMaps('tagRefs')) _parseTagRefFromJson(m),
  ], (r) => '${r.tagId}\u0000${r.recordId}');
  final templates = _dedupeById([
    for (final m in activeMaps('templates')) _parseTemplateFromJson(m),
  ], (r) => r.id);
  final bankCards = _dedupeById([
    for (final m in activeMaps('bankCards')) _parseBankCardFromJson(m),
  ], (r) => r.id);
  final wishes = _dedupeById([
    for (final m in activeMaps('wishes')) _parseWishFromJson(m),
  ], (r) => r.id);
  final remarks = _dedupeById([
    for (final m in activeMaps('remarks')) _parseRemarkFromJson(m),
  ], (r) => r.id);
  final moneySavePlans = _dedupeById([
    for (final m in activeMaps('moneySavePlans')) _parseSavingsPlanFromJson(m),
  ], (r) => r.id);
  final moneySavePlanRecords = _dedupeById([
    for (final m in activeMaps('moneySavePlanRecords'))
      _parseSavingsRecordFromJson(m),
  ], (r) => r.id);
  final assetBookRefs = _dedupeById([
    for (final m in activeMaps('assetBookRefs')) _parseAssetBookFromJson(m),
  ], (r) => '${r.assetId}:${r.bookId}');
  final statStory = _dedupeById([
    for (final m in activeMaps('statStory')) _parseStatStoryFromJson(m),
  ], (r) => r.id);

  final payload = MigrationPayload(
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
  );

  if (payload.isEmptyCrossPayload) {
    throw const Failure(FailureCode.validation, '迁移文件不包含有效业务数据，已拦截导入以保护本地账本');
  }
  return payload;
}

/// Deduplicates `account_book` rows by business primary key `id` (`R3` / `DEC-005`).
/// If two rows collide on `id = 1` (e.g. from an original-app multi-`uid` seed collision),
/// prefers the custom-named book over an auto-seeded `'日常账本'` duplicate.
List<MigrationBookRow> deduplicateBooks(Iterable<MigrationBookRow> rawBooks) {
  final byId = <int, MigrationBookRow>{};
  for (final book in rawBooks) {
    final existing = byId[book.id];
    if (existing == null) {
      byId[book.id] = book;
    } else if (existing.name == '日常账本' && book.name != '日常账本') {
      byId[book.id] = book;
    }
  }
  return List<MigrationBookRow>.unmodifiable(byId.values);
}

List<T> _dedupeById<T, K>(Iterable<T> items, K Function(T) keyOf) {
  final seen = <K>{};
  final out = <T>[];
  for (final item in items) {
    if (seen.add(keyOf(item))) out.add(item);
  }
  return List<T>.unmodifiable(out);
}

bool _isTombstone(Map<String, Object?> map) {
  final sstatus = map['sstatus'];
  if (sstatus == null) return false;
  if (sstatus is int) return sstatus == _tombstoneStatus;
  if (sstatus is num) return sstatus.toInt() == _tombstoneStatus;
  if (sstatus is String)
    return int.tryParse(sstatus.trim()) == _tombstoneStatus;
  return false;
}

/// Serializes [MigrationPayload] into UTF-8 `.ya2i` bytes with exact APK short keys,
/// exact 2-decimal JSON numbers (zero `double` math), and optional `extraNotes` (§6.2).
Uint8List encodeYa2iBytes(
  MigrationPayload payload, {
  bool includeExtraNotes = true,
}) {
  final text = encodeYa2iJsonText(
    payload,
    includeExtraNotes: includeExtraNotes,
  );
  return Uint8List.fromList(utf8.encode(text));
}

/// Serializes [MigrationPayload] into `.ya2i` UTF-8 JSON text.
String encodeYa2iJsonText(
  MigrationPayload payload, {
  bool includeExtraNotes = true,
}) {
  final root = <String, Object?>{
    'books': [for (final r in payload.books) _bookToJson(r)],
    'categories': [for (final r in payload.categories) _categoryToJson(r)],
    'assets': [for (final r in payload.assets) _assetToJson(r)],
    'records': [for (final r in payload.records) _recordToJson(r)],
    'budgets': [for (final r in payload.budgets) _budgetToJson(r)],
    'importPlatforms': [
      for (final r in payload.importPlatforms) _importPlatformToJson(r),
    ],
    'installments': [
      for (final r in payload.installments) _installmentToJson(r),
    ],
    'periods': [for (final r in payload.periods) _periodToJson(r)],
    'reminders': [for (final r in payload.reminders) _reminderToJson(r)],
    'tags': [for (final r in payload.tags) _tagToJson(r)],
    'tagRefs': [for (final r in payload.tagRefs) _tagRefToJson(r)],
    'templates': [for (final r in payload.templates) _templateToJson(r)],
    'bankCards': [for (final r in payload.bankCards) _bankCardToJson(r)],
    'wishes': [for (final r in payload.wishes) _wishToJson(r)],
    'remarks': [for (final r in payload.remarks) _remarkToJson(r)],
    'moneySavePlans': [
      for (final r in payload.moneySavePlans) _savingsPlanToJson(r),
    ],
    'moneySavePlanRecords': [
      for (final r in payload.moneySavePlanRecords) _savingsRecordToJson(r),
    ],
    'assetBookRefs': [
      for (final r in payload.assetBookRefs) _assetBookToJson(r),
    ],
    'statStory': [for (final r in payload.statStory) _statStoryToJson(r)],
    if (includeExtraNotes && payload.extraNotes.isNotEmpty)
      'extraNotes': [for (final n in payload.extraNotes) _noteToJson(n)],
  };
  return encodeMigrationJson(root);
}

// ============================================================================
// Entity <-> Short-Key JSON Mappers (Aligned 1:1 with APK Room/Gson Annotations)
// ============================================================================

MigrationBookRow _parseBookFromJson(Map<String, Object?> m) => MigrationBookRow(
  id: _requireInt(m, const ['id'], 'books.id'),
  type: _asInt(m['type'], fallback: 1),
  name: _requireString(m, const ['name'], 'books.name'),
  cover: _asString(m['cover'], fallback: ''),
  sort: _asInt(m['sort'], fallback: 1),
  status: _asInt(m['status'], fallback: 0),
  startDay: _asInt(m['dstart'] ?? m['start_day'], fallback: 1),
  createDate: _asInt(m['cdate'] ?? m['create_date'], fallback: 0),
  displayWay: _asInt(m['dway'] ?? m['display_way'], fallback: 0),
  extraInfo: _asNullableString(m['extra_info']),
);

Map<String, Object?> _bookToJson(MigrationBookRow r) => {
  'id': r.id,
  'type': r.type,
  'name': r.name,
  'cover': r.cover,
  'sort': r.sort,
  'status': r.status,
  'dstart': r.startDay,
  'cdate': r.createDate,
  'dway': r.displayWay,
  'extra_info': r.extraInfo,
};

MigrationCategoryRow _parseCategoryFromJson(Map<String, Object?> m) =>
    MigrationCategoryRow(
      id: _requireInt(m, const ['id'], 'categories.id'),
      name: _requireString(m, const ['name'], 'categories.name'),
      icon: _asString(m['icon'], fallback: ''),
      type: _requireInt(m, const ['type'], 'categories.type'),
      sort: _asInt(m['sort'], fallback: 0),
      parentCatId: _asInt(m['parent'] ?? m['parent_cat_id'], fallback: -1),
      colorFill: _asNullableString(m['color'] ?? m['color_fill']),
      platformId: _asInt(
        m['platform_id'] ?? m['plat'] ?? m['DD0O0oO0o0OOo'],
        fallback: -1,
      ),
      accountBookId: _asInt(m['book'] ?? m['account_book_id'], fallback: 1),
      isHide: _asBool(m['hide'] ?? m['is_hide'], fallback: false),
      extraInfo: _asNullableString(m['extra_info']),
    );

Map<String, Object?> _categoryToJson(MigrationCategoryRow r) => {
  'id': r.id,
  'name': r.name,
  'icon': r.icon,
  'type': r.type,
  'sort': r.sort,
  'parent': r.parentCatId,
  'color': r.colorFill,
  'platform_id': r.platformId,
  'book': r.accountBookId,
  'hide': r.isHide,
  'extra_info': r.extraInfo,
};

MigrationAssetRow _parseAssetFromJson(Map<String, Object?> m) {
  final balRaw = m.containsKey('bal') ? m['bal'] : m['balance'];
  if (balRaw == null) {
    throw const Failure(FailureCode.corruptData, 'assets 缺少余额字段 bal');
  }
  final initRaw = m.containsKey('initm') ? m['initm'] : m['init_money'];
  final rawEffect = m.containsKey('effect')
      ? m['effect']
      : m['is_effective_asset'];
  final int effectiveAsset = switch (rawEffect) {
    null => 1,
    bool b => b ? 1 : 0,
    int i => i != 0 ? 1 : 0,
    num n => n.toInt() != 0 ? 1 : 0,
    _ => throw const Failure(FailureCode.corruptData, 'assets.effect 类型无效'),
  };

  return MigrationAssetRow(
    id: _requireInt(m, const ['id'], 'assets.id'),
    name: _requireString(m, const ['name'], 'assets.name'),
    balanceMinor: parseMajorToMinor(balRaw, fieldName: 'assets.bal'),
    type: _asInt(m['type'], fallback: 0),
    subType: _asInt(m['subt'] ?? m['sub_type'], fallback: -1),
    createDate: _asInt(m['cdate'] ?? m['create_date'], fallback: 0),
    sort: _asInt(m['sort'], fallback: 0),
    icon: _asString(m['icon'], fallback: ''),
    remark: _asNullableString(m['remark']),
    initMoneyMinor: initRaw == null
        ? BigInt.zero
        : parseMajorToMinor(initRaw, fieldName: 'assets.initm'),
    isDefault: _asBool(m['default'] ?? m['is_default'], fallback: false),
    isEffectiveAsset: effectiveAsset,
    usedTimes: _asInt(m['usetime'] ?? m['used_times'], fallback: 0),
    color: _asNullableString(m['color']),
    status: _asInt(m['status'], fallback: 0),
    extraInfo: convertAssetExtraInfoOnImport(
      _asNullableJsonOrString(m['extra'] ?? m['extra_info']),
    ),
    loanInfo: convertAssetLoanInfoOnImport(
      _asNullableJsonOrString(m['loan'] ?? m['loan_info']),
    ),
    creditInfo: convertAssetCreditInfoOnImport(
      _asNullableJsonOrString(m['credit'] ?? m['credit_info']),
    ),
    fixedDepositInfo: convertAssetFixedDepositInfoOnImport(
      _asNullableJsonOrString(m['fixeddeposit'] ?? m['fixed_deposit_info']),
    ),
    groupName: _asNullableString(m['groupname'] ?? m['group_name']),
    currency: _asNullableString(m['currency']),
  );
}

Map<String, Object?> _assetToJson(MigrationAssetRow r) => {
  'id': r.id,
  'name': r.name,
  'bal': JsonDecimalNumber.fromMinor(r.balanceMinor),
  'type': r.type,
  'subt': r.subType,
  'cdate': r.createDate,
  'sort': r.sort,
  'icon': r.icon,
  'remark': r.remark,
  'initm': JsonDecimalNumber.fromMinor(r.initMoneyMinor),
  'default': r.isDefault,
  'effect': r.isEffectiveAsset != 0,
  'usetime': r.usedTimes,
  'color': r.color,
  'status': r.status,
  'extra': convertAssetExtraInfoOnExport(r.extraInfo),
  'loan': convertAssetLoanInfoOnExport(r.loanInfo),
  'credit': convertAssetCreditInfoOnExport(r.creditInfo),
  'fixeddeposit': convertAssetFixedDepositInfoOnExport(r.fixedDepositInfo),
  'groupname': r.groupName,
  'currency': r.currency,
};

MigrationRecordRow _parseRecordFromJson(Map<String, Object?> m) {
  final id = _requireNonEmptyString(m, const ['id'], 'records.id');
  final moneyRaw = m['money'];
  if (moneyRaw == null) {
    throw const Failure(FailureCode.corruptData, 'records 缺少金额字段 money');
  }
  final discountRaw = m['discount'];
  return MigrationRecordRow(
    recordId: id,
    type: _requireInt(m, const ['type'], 'records.type'),
    subType: _asInt(m['subt'] ?? m['sub_type'], fallback: -1),
    moneyMinor: parseMajorToMinor(moneyRaw, fieldName: 'records.money'),
    remark: _asString(m['remark'], fallback: ''),
    recordTime: _requireInt(m, const ['time'], 'records.time'),
    recordCatId: _asInt(m['cat'] ?? m['record_cat_id'], fallback: -1),
    assetId: _asInt(m['asset'] ?? m['asset_id'], fallback: -1),
    fromAssetId: _asInt(m['froma'] ?? m['from_asset_id'], fallback: -1),
    toAssetId: _asInt(m['toa'] ?? m['to_asset_id'], fallback: -1),
    accountBookId: _asInt(m['book'] ?? m['account_book_id'], fallback: 1),
    excludeBudget: _asBool(m['exbud'] ?? m['exclude_budget'], fallback: false),
    excludeExIn: _asBool(m['exexin'] ?? m['exclude_ex_in'], fallback: false),
    platformId: _asInt(m['plat'] ?? m['platform_id'], fallback: -1),
    periodId: _asInt(m['period'] ?? m['period_id'], fallback: -1),
    installment: _asNullableString(m['instal'] ?? m['installment']),
    images: _parseBillImagesToCsv(m['img'] ?? m['images']),
    relInfo: convertRecordRelInfoOnImport(
      _asNullableJsonOrString(m['rel'] ?? m['rel_info']),
    ),
    discountMinor: discountRaw == null
        ? null
        : parseMajorToMinor(discountRaw, fieldName: 'records.discount'),
    extraInfo: convertRecordExtraInfoOnImport(
      _asNullableJsonOrString(m['extra'] ?? m['extra_info']),
    ),
    createDate: m['cdt'] != null
        ? _asInt(m['cdt'])
        : (m['create_date'] != null ? _asInt(m['create_date']) : null),
  );
}

Map<String, Object?> _recordToJson(MigrationRecordRow r) => {
  'id': r.recordId,
  'type': r.type,
  'subt': r.subType,
  'money': JsonDecimalNumber.fromMinor(r.moneyMinor),
  'remark': r.remark,
  'time': r.recordTime,
  'cat': r.recordCatId,
  'asset': r.assetId,
  'froma': r.fromAssetId,
  'toa': r.toAssetId,
  'book': r.accountBookId,
  'exbud': r.excludeBudget,
  'exexin': r.excludeExIn,
  'plat': r.platformId,
  'period': r.periodId,
  'instal': r.installment,
  'img': _encodeCsvToBillImages(r.images),
  'rel': convertRecordRelInfoOnExport(r.relInfo),
  'discount': r.discountMinor == null
      ? null
      : JsonDecimalNumber.fromMinor(r.discountMinor!),
  'extra': convertRecordExtraInfoOnExport(r.extraInfo),
  'cdt': r.createDate,
};

MigrationBudgetRow _parseBudgetFromJson(Map<String, Object?> m) {
  final amountRaw = m['amount'];
  if (amountRaw == null) {
    throw const Failure(FailureCode.corruptData, 'budgets 缺少金额字段 amount');
  }
  return MigrationBudgetRow(
    id: _requireInt(m, const ['id'], 'budgets.id'),
    budgetType: _requireInt(m, const ['type', 'budget_type'], 'budgets.type'),
    recordCatId: _asInt(m['cat'] ?? m['record_cat_id'], fallback: -1),
    amountMinor: parseMajorToMinor(amountRaw, fieldName: 'budgets.amount'),
    bookId: _asInt(m['book'] ?? m['book_id'], fallback: 1),
    section: _requireString(m, const ['sect', 'section'], 'budgets.sect'),
    sort: _asInt(m['sort'], fallback: 0),
    createDate: _asInt(m['cdate'] ?? m['create_date'], fallback: 0),
    remark: _asNullableString(m['remark']),
    extraInfo: convertBudgetExtraInfoOnImport(
      _asNullableJsonOrString(m['extra_info']),
    ),
  );
}

Map<String, Object?> _budgetToJson(MigrationBudgetRow r) => {
  'id': r.id,
  'type': r.budgetType,
  'cat': r.recordCatId,
  'amount': JsonDecimalNumber.fromMinor(r.amountMinor),
  'book': r.bookId,
  'sect': r.section,
  'sort': r.sort,
  'cdate': r.createDate,
  'remark': r.remark,
  'extra_info': convertBudgetExtraInfoOnExport(r.extraInfo),
};

MigrationImportPlatformRow _parseImportPlatformFromJson(
  Map<String, Object?> m, {
  required bool strictBoolHidden,
}) {
  final rawHidden = m['hidden'];
  final bool hidden;
  if (rawHidden == null) {
    hidden = false;
  } else if (rawHidden is bool) {
    hidden = rawHidden;
  } else if (!strictBoolHidden && rawHidden is int) {
    hidden = rawHidden != 0;
  } else {
    throw const Failure(
      FailureCode.corruptData,
      'importPlatforms.hidden 必须为布尔值',
    );
  }
  return MigrationImportPlatformRow(
    id: _requireInt(m, const ['id'], 'importPlatforms.id'),
    platform: _requireString(m, const [
      'plat',
      'platform',
    ], 'importPlatforms.plat'),
    importRecordCount: _asInt(
      m['recordc'] ?? m['import_record_count'],
      fallback: 0,
    ),
    importCategoryCount: _asInt(
      m['catc'] ?? m['import_category_count'],
      fallback: 0,
    ),
    importTime: _asInt(m['time'] ?? m['import_time'], fallback: 0),
    hidden: hidden,
  );
}

Map<String, Object?> _importPlatformToJson(MigrationImportPlatformRow r) => {
  'id': r.id,
  'plat': r.platform,
  'recordc': r.importRecordCount,
  'catc': r.importCategoryCount,
  'time': r.importTime,
  'hidden': r.hidden,
};

MigrationInstallmentRow _parseInstallmentFromJson(Map<String, Object?> m) {
  final prinRaw = m.containsKey('prin') ? m['prin'] : m['principal_money'];
  if (prinRaw == null) {
    throw const Failure(FailureCode.corruptData, 'installments 缺少本金 prin');
  }
  final chargeRaw = m['charge'];
  return MigrationInstallmentRow(
    id: _requireInt(m, const ['id'], 'installments.id'),
    name: _requireString(m, const ['name'], 'installments.name'),
    catId: _asInt(m['cat'] ?? m['cat_id'], fallback: -1),
    principalMinor: parseMajorToMinor(prinRaw, fieldName: 'installments.prin'),
    periods: _requireInt(m, const ['periods'], 'installments.periods'),
    chargeMinor: chargeRaw == null
        ? BigInt.zero
        : parseMajorToMinor(chargeRaw, fieldName: 'installments.charge'),
    chargeWay: _asInt(m['chargeway'] ?? m['charge_way'], fallback: 1),
    remainderIn: _asInt(m['remin'] ?? m['remainder_in'], fallback: 0),
    calWay: _asInt(m['calway'] ?? m['cal_way'], fallback: 2),
    startDate: _asInt(m['sdate'] ?? m['start_date'], fallback: 0),
    assetId: _asInt(m['asset'] ?? m['asset_id'], fallback: -1),
    nextPeriod: _asInt(m['np'] ?? m['next_period'], fallback: 1),
    nextPeriodDate: _asInt(m['npdate'] ?? m['next_period_date'], fallback: 0),
    credited: _parseIntListToJsonText(m['credited']),
    bookId: _asInt(m['book'] ?? m['book_id'], fallback: 1),
    excludeBudget: _asBool(m['exbud'] ?? m['exclude_budget'], fallback: false),
    excludeExIn: _asBool(m['exexin'] ?? m['exclude_ex_in'], fallback: false),
    createDate: _asInt(m['cdate'] ?? m['create_date'], fallback: 0),
    tags: _parseStringListToCsv(m['tags']),
    images: _parseBillImagesToCsv(m['img'] ?? m['images']),
    exi: _asNullableJsonOrString(m['exi']),
  );
}

Map<String, Object?> _installmentToJson(MigrationInstallmentRow r) => {
  'id': r.id,
  'name': r.name,
  'cat': r.catId,
  'prin': JsonDecimalNumber.fromMinor(r.principalMinor),
  'periods': r.periods,
  'charge': JsonDecimalNumber.fromMinor(r.chargeMinor),
  'chargeway': r.chargeWay,
  'remin': r.remainderIn,
  'calway': r.calWay,
  'sdate': r.startDate,
  'asset': r.assetId,
  'np': r.nextPeriod,
  'npdate': r.nextPeriodDate,
  'credited': _decodeIntListJson(r.credited),
  'book': r.bookId,
  'exbud': r.excludeBudget,
  'exexin': r.excludeExIn,
  'cdate': r.createDate,
  'tags': _encodeCsvToStringList(r.tags),
  'img': _encodeCsvToBillImages(r.images),
  'exi': r.exi,
};

MigrationPeriodRow _parsePeriodFromJson(Map<String, Object?> m) {
  final moneyRaw = m['money'];
  if (moneyRaw == null) {
    throw const Failure(FailureCode.corruptData, 'periods 缺少金额字段 money');
  }
  final feeRaw = m['fee'];
  return MigrationPeriodRow(
    id: _requireInt(m, const ['id'], 'periods.id'),
    recordType: _requireInt(m, const ['type', 'record_type'], 'periods.type'),
    moneyMinor: parseMajorToMinor(moneyRaw, fieldName: 'periods.money'),
    feeMinor: feeRaw == null
        ? BigInt.zero
        : parseMajorToMinor(feeRaw, fieldName: 'periods.fee'),
    remark: _asString(m['remark'], fallback: ''),
    catId: _asInt(m['cat'] ?? m['cat_id'], fallback: -1),
    assetId: _asInt(m['asset'] ?? m['asset_id'], fallback: -1),
    assetId2: _asInt(m['asset2'] ?? m['asset_id2'], fallback: -1),
    bookId: _asInt(m['book'] ?? m['book_id'], fallback: 1),
    images: _parseBillImagesToCsv(m['img'] ?? m['images']),
    state: _asInt(m['state'], fallback: 0),
    time: _asNullableString(m['time']),
    excludeBudget: _asBool(m['exbud'] ?? m['exclude_budget'], fallback: false),
    excludeExIn: _asBool(m['exexin'] ?? m['exclude_ex_in'], fallback: false),
    periodType: _asInt(m['ptype'] ?? m['period_type'], fallback: 0),
    periodTypeDate: _parseStringSetToJsonText(
      m['ptypedate'] ?? m['period_type_date'],
    ),
    periodStartDate: _asInt(
      m['startdate'] ?? m['period_start_date'],
      fallback: 0,
    ),
    periodEndDate: _asInt(m['enddate'] ?? m['period_end_date'], fallback: -1),
    frequency: _asInt(m['freq'] ?? m['frequency'], fallback: 1),
    lastAddDate: _asInt(m['lastadd'] ?? m['last_add_date'], fallback: -1),
    periodAddTimes: _asInt(m['addtimes'] ?? m['period_add_times'], fallback: 0),
    createTime: _asInt(m['ctime'] ?? m['create_time'], fallback: 0),
    tags: _parseStringListToCsv(m['tags']),
    exi: _asNullableJsonOrString(m['exi']),
  );
}

Map<String, Object?> _periodToJson(MigrationPeriodRow r) => {
  'id': r.id,
  'type': r.recordType,
  'money': JsonDecimalNumber.fromMinor(r.moneyMinor),
  'fee': JsonDecimalNumber.fromMinor(r.feeMinor),
  'remark': r.remark,
  'cat': r.catId,
  'asset': r.assetId,
  'asset2': r.assetId2,
  'book': r.bookId,
  'img': _encodeCsvToBillImages(r.images),
  'state': r.state,
  'time': r.time,
  'exbud': r.excludeBudget,
  'exexin': r.excludeExIn,
  'ptype': r.periodType,
  'ptypedate': _decodeStringListJson(r.periodTypeDate),
  'startdate': r.periodStartDate,
  'enddate': r.periodEndDate,
  'freq': r.frequency,
  'lastadd': r.lastAddDate,
  'addtimes': r.periodAddTimes,
  'ctime': r.createTime,
  'tags': _encodeCsvToStringList(r.tags),
  'exi': r.exi,
};

MigrationReminderRow _parseReminderFromJson(Map<String, Object?> m) {
  final rawTime = _requireInt(m, const [
    'time',
    'reminder_time',
  ], 'reminders.time');
  final normalizedMinute = normalizeReminderMinuteOfDay(rawTime);
  final tipRaw = m.containsKey('tip') ? m['tip'] : m['reminder_tip'];
  return MigrationReminderRow(
    id: _requireInt(m, const ['id'], 'reminders.id'),
    reminderTime: normalizedMinute,
    reminderTip: tipRaw == null
        ? null
        : normalizeReminderTip(tipRaw.toString()),
  );
}

Map<String, Object?> _reminderToJson(MigrationReminderRow r) {
  final t = ReminderTime.normalizeStored(r.reminderTime);
  final legacyEpochMs = DateTime(
    2020,
    12,
    19,
    t.hour,
    t.minute,
  ).millisecondsSinceEpoch;
  return {'id': r.id, 'time': legacyEpochMs, 'tip': r.reminderTip};
}

MigrationTagRow _parseTagFromJson(Map<String, Object?> m) {
  final rawIsParent = m.containsKey('isparent') ? m['isparent'] : null;
  final int parentFlag;
  if (rawIsParent != null) {
    parentFlag = _asBool(rawIsParent, fallback: false) ? 1 : 0;
  } else if (m['parent'] is int || m['parent'] is bool) {
    parentFlag = _asBool(m['parent'], fallback: false) ? 1 : 0;
  } else {
    parentFlag = 0;
  }

  final String? parentTagId;
  if (m['parent_tag_id'] is String) {
    parentTagId = _asNullableString(m['parent_tag_id']);
  } else if (m['parent'] is String) {
    parentTagId = _asNullableString(m['parent']);
  } else {
    parentTagId = null;
  }

  return MigrationTagRow(
    tagId: _requireNonEmptyString(m, const ['id', 'tag_id'], 'tags.id'),
    name: _requireString(m, const ['name'], 'tags.name'),
    sort: _asInt(m['sort'], fallback: 0),
    hidden: _asBool(m['hidden'], fallback: false),
    parentTagId: parentTagId,
    parent: parentFlag,
    color: _asNullableString(m['color']),
    extraInfo: _asNullableJsonOrString(m['extra_info']),
  );
}

Map<String, Object?> _tagToJson(MigrationTagRow r) => {
  'id': r.tagId,
  'name': r.name,
  'sort': r.sort,
  'hidden': r.hidden,
  'parent': r.parentTagId,
  'isparent': r.parent != 0,
  'color': r.color,
  'extra_info': r.extraInfo,
};

MigrationTagRefRow _parseTagRefFromJson(Map<String, Object?> m) =>
    MigrationTagRefRow(
      tagId: _requireNonEmptyString(m, const ['tid', 'tag_id'], 'tagRefs.tid'),
      recordId: _requireNonEmptyString(m, const [
        'rid',
        'record_id',
      ], 'tagRefs.rid'),
    );

Map<String, Object?> _tagRefToJson(MigrationTagRefRow r) => {
  'tid': r.tagId,
  'rid': r.recordId,
};

MigrationTemplateRow _parseTemplateFromJson(Map<String, Object?> m) {
  final moneyRaw = m['money'];
  if (moneyRaw == null) {
    throw const Failure(FailureCode.corruptData, 'templates 缺少金额字段 money');
  }
  final feeRaw = m['fee'];
  final catRaw = m.containsKey('cat') ? m['cat'] : m['record_cat_id'];
  return MigrationTemplateRow(
    id: _requireInt(m, const ['id'], 'templates.id'),
    type: _requireInt(m, const ['type'], 'templates.type'),
    remark: _asNullableString(m['remark']),
    moneyMinor: parseMajorToMinor(moneyRaw, fieldName: 'templates.money'),
    feeMinor: feeRaw == null
        ? BigInt.zero
        : parseMajorToMinor(feeRaw, fieldName: 'templates.fee'),
    recordCatId: catRaw == null ? null : _asInt(catRaw),
    assetId: _asInt(m['asset'] ?? m['asset_id'], fallback: -1),
    assetId2: _asInt(m['asset2'] ?? m['asset_id2'], fallback: -1),
    sort: _asInt(m['sort'], fallback: 0),
    autoSave: _asBool(m['autosave'] ?? m['auto_save'], fallback: false),
    bookId: _asInt(m['book'] ?? m['book_id'], fallback: 1),
    excludeBudget: _asBool(m['exbud'] ?? m['exclude_budget'], fallback: false),
    excludeExIn: _asBool(m['exexin'] ?? m['exclude_ex_in'], fallback: false),
    createDate: _asInt(m['cdate'] ?? m['create_date'], fallback: 0),
    tags: _parseStringListToCsv(m['tags']),
    exi: convertRecordExtraInfoOnImport(_asNullableJsonOrString(m['exi'])),
  );
}

Map<String, Object?> _templateToJson(MigrationTemplateRow r) => {
  'id': r.id,
  'type': r.type,
  'remark': r.remark,
  'money': JsonDecimalNumber.fromMinor(r.moneyMinor),
  'fee': JsonDecimalNumber.fromMinor(r.feeMinor),
  'cat': r.recordCatId,
  'asset': r.assetId,
  'asset2': r.assetId2,
  'sort': r.sort,
  'autosave': r.autoSave,
  'book': r.bookId,
  'exbud': r.excludeBudget,
  'exexin': r.excludeExIn,
  'cdate': r.createDate,
  'tags': _encodeCsvToStringList(r.tags),
  'exi': convertRecordExtraInfoOnExport(r.exi),
};

MigrationBankCardRow _parseBankCardFromJson(Map<String, Object?> m) =>
    MigrationBankCardRow(
      id: _requireInt(m, const ['id'], 'bankCards.id'),
      cardType: _asInt(m['type'] ?? m['card_type'], fallback: 0),
      cardName: _requireString(m, const [
        'name',
        'card_name',
      ], 'bankCards.name'),
      cardNo: _asString(m['no'] ?? m['card_no'], fallback: ''),
      cardOwner: _asString(m['owner'] ?? m['card_owner'], fallback: ''),
      remark: _asString(m['remark'], fallback: ''),
      cardColor: _asNullableString(m['color'] ?? m['card_color']),
      sort: _asInt(m['sort'], fallback: -1),
      createDate: _asInt(m['cdate'] ?? m['create_date'], fallback: 0),
      cardAssetId: _asInt(m['card_asset_id'], fallback: -1),
    );

Map<String, Object?> _bankCardToJson(MigrationBankCardRow r) => {
  'id': r.id,
  'type': r.cardType,
  'name': r.cardName,
  'no': r.cardNo,
  'owner': r.cardOwner,
  'remark': r.remark,
  'color': r.cardColor,
  'sort': r.sort,
  'cdate': r.createDate,
  'card_asset_id': r.cardAssetId,
};

MigrationWishRow _parseWishFromJson(Map<String, Object?> m) {
  final valRaw = m['value'];
  if (valRaw == null) {
    throw const Failure(FailureCode.corruptData, 'wishes 缺少金额字段 value');
  }
  return MigrationWishRow(
    id: _requireNonEmptyString(m, const ['id'], 'wishes.id'),
    content: _requireString(m, const ['content'], 'wishes.content'),
    valueMinor: parseMajorToMinor(valRaw, fieldName: 'wishes.value'),
    createDate: _asInt(m['cdate'] ?? m['create_date'], fallback: 0),
    isRealized: _asBool(m['realized'] ?? m['is_realized'], fallback: false),
    realizedDate: _asInt(m['rdate'] ?? m['realized_date'], fallback: 0),
    sort: _asInt(m['sort'], fallback: 0),
    icon: _asNullableString(m['icon']),
    targetDate: _asInt(m['tdate'] ?? m['target_date'], fallback: 0),
  );
}

Map<String, Object?> _wishToJson(MigrationWishRow r) => {
  'id': r.id,
  'content': r.content,
  'value': JsonDecimalNumber.fromMinor(r.valueMinor),
  'cdate': r.createDate,
  'realized': r.isRealized,
  'rdate': r.realizedDate,
  'sort': r.sort,
  'icon': r.icon,
  'tdate': r.targetDate,
};

MigrationRemarkRow _parseRemarkFromJson(Map<String, Object?> m) =>
    MigrationRemarkRow(
      id: _requireInt(m, const ['id'], 'remarks.id'),
      content: _requireString(m, const ['content'], 'remarks.content'),
      recordCatId: _asInt(m['record_cat_id'] ?? m['cat'], fallback: -1),
      usedTimes: _asInt(m['used_times'], fallback: 0),
    );

Map<String, Object?> _remarkToJson(MigrationRemarkRow r) => {
  'id': r.id,
  'content': r.content,
  'record_cat_id': r.recordCatId,
  'used_times': r.usedTimes,
};

MigrationSavingsPlanRow _parseSavingsPlanFromJson(Map<String, Object?> m) {
  final planMoneyRaw = m['plan_money'];
  if (planMoneyRaw == null) {
    throw const Failure(
      FailureCode.corruptData,
      'moneySavePlans 缺少 plan_money',
    );
  }
  return MigrationSavingsPlanRow(
    id: _requireInt(m, const ['id'], 'moneySavePlans.id'),
    name: _requireString(m, const ['name'], 'moneySavePlans.name'),
    remark: _asString(m['remark'], fallback: ''),
    planType: _requireInt(m, const ['plan_type'], 'moneySavePlans.plan_type'),
    cycleType: _asInt(m['cycle_type'], fallback: -1),
    startDate: _asInt(m['start_date'], fallback: 0),
    endDate: _asInt(m['end_date'], fallback: 0),
    planMoneyMinor: parseMajorToMinor(
      planMoneyRaw,
      fieldName: 'moneySavePlans.plan_money',
    ),
    savedMoneyMinor: m['saved_money'] == null
        ? BigInt.zero
        : parseMajorToMinor(
            m['saved_money'],
            fieldName: 'moneySavePlans.saved_money',
          ),
    autoPlan: _asBool(m['auto_plan'], fallback: false),
    fromAssetId: _asInt(m['from_asset_id'], fallback: -1),
    toAssetId: _asInt(m['to_asset_id'], fallback: -1),
    bookId: _asInt(m['book_id'], fallback: -1),
    startMoneyMinor: m['start_money'] == null
        ? BigInt.zero
        : parseMajorToMinor(
            m['start_money'],
            fieldName: 'moneySavePlans.start_money',
          ),
    incrementalMinor: m['incremental'] == null
        ? BigInt.zero
        : parseMajorToMinor(
            m['incremental'],
            fieldName: 'moneySavePlans.incremental',
          ),
    status: _asInt(m['status'], fallback: 0),
    createDate: _asInt(m['create_date'], fallback: 0),
    sort: _asInt(m['sort'], fallback: 0),
    nextSaveDate: _asInt(m['next_save_date'], fallback: 0),
    bbzDailyTimes: _asInt(m['bbz_daily_times'], fallback: 0),
    icon: _asNullableString(m['icon']),
    extraInfo: _asNullableJsonOrString(m['extra_info']),
  );
}

Map<String, Object?> _savingsPlanToJson(MigrationSavingsPlanRow r) => {
  'id': r.id,
  'name': r.name,
  'remark': r.remark,
  'plan_type': r.planType,
  'cycle_type': r.cycleType,
  'start_date': r.startDate,
  'end_date': r.endDate,
  'plan_money': JsonDecimalNumber.fromMinor(r.planMoneyMinor),
  'saved_money': JsonDecimalNumber.fromMinor(r.savedMoneyMinor),
  'auto_plan': r.autoPlan,
  'from_asset_id': r.fromAssetId,
  'to_asset_id': r.toAssetId,
  'book_id': r.bookId,
  'start_money': JsonDecimalNumber.fromMinor(r.startMoneyMinor),
  'incremental': JsonDecimalNumber.fromMinor(r.incrementalMinor),
  'status': r.status,
  'create_date': r.createDate,
  'sort': r.sort,
  'next_save_date': r.nextSaveDate,
  'bbz_daily_times': r.bbzDailyTimes,
  'icon': r.icon,
  'extra_info': r.extraInfo,
};

MigrationSavingsRecordRow _parseSavingsRecordFromJson(Map<String, Object?> m) {
  final moneyRaw = m['record_money'];
  if (moneyRaw == null) {
    throw const Failure(
      FailureCode.corruptData,
      'moneySavePlanRecords 缺少 record_money',
    );
  }
  return MigrationSavingsRecordRow(
    id: _requireInt(m, const ['id'], 'moneySavePlanRecords.id'),
    planId: _requireInt(m, const ['plan_id'], 'moneySavePlanRecords.plan_id'),
    remark: _asString(m['remark'], fallback: ''),
    fromAssetId: _asInt(m['from_asset_id'], fallback: -1),
    toAssetId: _asInt(m['to_asset_id'], fallback: -1),
    recordDate: _asInt(m['record_date'], fallback: 0),
    recordMoneyMinor: parseMajorToMinor(
      moneyRaw,
      fieldName: 'moneySavePlanRecords.record_money',
    ),
    recordId: _asNullableString(m['record_id']),
  );
}

Map<String, Object?> _savingsRecordToJson(MigrationSavingsRecordRow r) => {
  'id': r.id,
  'plan_id': r.planId,
  'remark': r.remark,
  'from_asset_id': r.fromAssetId,
  'to_asset_id': r.toAssetId,
  'record_date': r.recordDate,
  'record_money': JsonDecimalNumber.fromMinor(r.recordMoneyMinor),
  'record_id': r.recordId,
};

MigrationAssetBookRow _parseAssetBookFromJson(Map<String, Object?> m) =>
    MigrationAssetBookRow(
      assetId: _requireInt(m, const ['aid', 'asset_id'], 'assetBookRefs.aid'),
      bookId: _requireInt(m, const ['bid', 'book_id'], 'assetBookRefs.bid'),
    );

Map<String, Object?> _assetBookToJson(MigrationAssetBookRow r) => {
  'aid': r.assetId,
  'bid': r.bookId,
};

MigrationStatStoryRow _parseStatStoryFromJson(Map<String, Object?> m) =>
    MigrationStatStoryRow(
      id: _requireNonEmptyString(m, const ['id'], 'statStory.id'),
      story: _requireString(m, const ['story'], 'statStory.story'),
      bookId: _requireInt(m, const ['book_id', 'book'], 'statStory.book_id'),
      sdate: _asInt(m['sdate'], fallback: 0),
      edate: _asInt(m['edate'], fallback: 0),
      dsection: _asNullableString(m['dsection']),
    );

Map<String, Object?> _statStoryToJson(MigrationStatStoryRow r) => {
  'id': r.id,
  'story': r.story,
  'book_id': r.bookId,
  'sdate': r.sdate,
  'edate': r.edate,
  'dsection': r.dsection,
};

Map<String, Object?> _noteToJson(MigrationNoteRow r) => {
  'id': r.id,
  'title': r.title,
  'content': r.content,
  'create_time': r.createTime,
  'update_time': r.updateTime,
  'trash_time': r.trashTime,
};

// ============================================================================
// Primitive & Collection Field Helpers
// ============================================================================

int _requireInt(Map<String, Object?> m, List<String> keys, String label) {
  for (final k in keys) {
    final v = m[k];
    if (v == null) continue;
    return _asInt(v, label: label);
  }
  throw Failure(FailureCode.corruptData, '缺少必填整数字段 $label');
}

String _requireString(Map<String, Object?> m, List<String> keys, String label) {
  for (final k in keys) {
    final v = m[k];
    if (v == null) continue;
    if (v is String) return v;
    throw Failure(FailureCode.corruptData, '字段 $label 必须为字符串');
  }
  throw Failure(FailureCode.corruptData, '缺少必填文本字段 $label');
}

String _requireNonEmptyString(
  Map<String, Object?> m,
  List<String> keys,
  String label,
) {
  final s = _requireString(m, keys, label);
  if (s.trim().isEmpty) {
    throw Failure(FailureCode.corruptData, '主键字段 $label 不能为空');
  }
  return s;
}

int _asInt(Object? raw, {int? fallback, String label = '整数'}) {
  if (raw == null) {
    if (fallback != null) return fallback;
    throw Failure(FailureCode.corruptData, '$label不能为空');
  }
  if (raw is int) return raw;
  if (raw is JsonDecimalNumber) {
    final dec = parseExactDecimal(raw.literal, fieldName: label);
    final units = dec.unitsAt(0);
    return Money.minor(units).storageMinor.toInt();
  }
  if (raw is num) {
    if (!raw.isFinite || raw % 1 != 0) {
      throw Failure(FailureCode.corruptData, '$label必须为整数');
    }
    return raw.toInt();
  }
  if (raw is String) {
    final parsed = int.tryParse(raw.trim());
    if (parsed != null) return parsed;
  }
  throw Failure(FailureCode.corruptData, '$label类型无效');
}

bool _asBool(Object? raw, {required bool fallback}) {
  if (raw == null) return fallback;
  if (raw is bool) return raw;
  if (raw is int) return raw != 0;
  if (raw is num) return raw.toInt() != 0;
  if (raw is String) {
    final t = raw.trim().toLowerCase();
    if (t == 'true' || t == '1') return true;
    if (t == 'false' || t == '0' || t.isEmpty) return false;
  }
  throw const Failure(FailureCode.corruptData, '布尔字段格式损坏');
}

String _asString(Object? raw, {required String fallback}) {
  if (raw == null) return fallback;
  if (raw is String) return raw;
  return raw.toString();
}

String? _asNullableString(Object? raw) {
  if (raw == null) return null;
  if (raw is String) return raw;
  return raw.toString();
}

String? _asNullableJsonOrString(Object? raw) {
  if (raw == null) return null;
  if (raw is String) return raw;
  if (raw is Map || raw is List) return encodeMigrationJson(raw);
  throw const Failure(FailureCode.corruptData, '附加 JSON 字段格式损坏');
}

String? _parseBillImagesToCsv(Object? raw) {
  if (raw == null) return null;
  if (raw is String) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.startsWith('[')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is List) return _parseBillImagesToCsv(decoded);
      } on FormatException {
        // Fall through as plain comma-joined string.
      }
    }
    return trimmed;
  }
  if (raw is List) {
    final names = <String>[];
    for (final item in raw) {
      if (item == null) continue;
      if (item is String && item.trim().isNotEmpty) {
        names.add(item.trim());
      } else if (item is Map) {
        final fname = item['fname'] ?? item['name'] ?? item['path'];
        if (fname is String && fname.trim().isNotEmpty) {
          names.add(fname.trim());
        }
      }
    }
    return names.isEmpty ? null : names.join(',');
  }
  throw const Failure(FailureCode.corruptData, '图片列表字段格式损坏');
}

List<Map<String, Object>>? _encodeCsvToBillImages(String? csv) {
  if (csv == null || csv.trim().isEmpty) return null;
  final parts = [
    for (final s in csv.split(','))
      if (s.trim().isNotEmpty) {'fname': s.trim()},
  ];
  return parts.isEmpty ? null : parts;
}

String? _parseStringListToCsv(Object? raw) {
  if (raw == null) return null;
  if (raw is String) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    if (trimmed.startsWith('[')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is List) return _parseStringListToCsv(decoded);
      } on FormatException {
        // Treat as plain CSV.
      }
    }
    return trimmed;
  }
  if (raw is List) {
    final out = <String>[];
    for (final e in raw) {
      if (e != null && e.toString().trim().isNotEmpty) {
        out.add(e.toString().trim());
      }
    }
    return out.isEmpty ? null : out.join(',');
  }
  throw const Failure(FailureCode.corruptData, '标签数组字段格式损坏');
}

List<String>? _encodeCsvToStringList(String? csv) {
  if (csv == null || csv.trim().isEmpty) return null;
  final parts = [
    for (final s in csv.split(','))
      if (s.trim().isNotEmpty) s.trim(),
  ];
  return parts.isEmpty ? null : parts;
}

String? _parseIntListToJsonText(Object? raw) {
  if (raw == null) return null;
  if (raw is String) {
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
  if (raw is List) {
    final ints = <int>[];
    for (final e in raw) {
      if (e == null) continue;
      ints.add(_asInt(e, label: 'credited'));
    }
    return jsonEncode(ints);
  }
  throw const Failure(FailureCode.corruptData, '分期期次列表格式损坏');
}

List<int>? _decodeIntListJson(String? text) {
  if (text == null || text.trim().isEmpty) return null;
  try {
    final decoded = jsonDecode(text);
    if (decoded is List) {
      return [
        for (final e in decoded)
          if (e != null) _asInt(e),
      ];
    }
  } on FormatException {
    return null;
  }
  return null;
}

String _parseStringSetToJsonText(Object? raw) {
  if (raw == null) return '[]';
  if (raw is String) {
    final trimmed = raw.trim();
    return trimmed.isEmpty ? '[]' : trimmed;
  }
  if (raw is List) {
    return jsonEncode([
      for (final e in raw)
        if (e != null) e.toString(),
    ]);
  }
  throw const Failure(FailureCode.corruptData, '周期日期集合格式损坏');
}

List<String> _decodeStringListJson(String text) {
  if (text.trim().isEmpty) return const [];
  try {
    final decoded = jsonDecode(text);
    if (decoded is List) {
      return [
        for (final e in decoded)
          if (e != null) e.toString(),
      ];
    }
  } on FormatException {
    return const [];
  }
  return const [];
}
