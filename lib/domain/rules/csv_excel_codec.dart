import 'dart:convert';
import 'dart:io' show ZLibCodec, zlib;
import 'dart:math' as math;
import 'dart:typed_data';

import '../../core/failure.dart';

/// Strict 6 MiB upload cap (`0x600000` = 6,291,456 bytes, `docs/modules/csv-excel.md` §2.2).
const int maxImportFileBytes = 6 * 1024 * 1024;

/// Actionable guidance when a bank/web HTML table is disguised with `.xls` extension (§6.1).
const String htmlDisguisedExcelGuidance =
    '该文件为网页伪装表格，请用 Excel 打开后另存为标准 .xlsx 格式再导入';

enum CsvTextEncoding { utf8Bom, utf8, gbk, utf16le }

final class DecodedCsvText {
  const DecodedCsvText({required this.text, required this.encoding});

  final String text;
  final CsvTextEncoding encoding;
}

final class TableSheet {
  const TableSheet({
    required this.sheetNo,
    required this.name,
    required this.rows,
  });

  /// 1-based worksheet index.
  final int sheetNo;
  final String name;
  final List<List<String>> rows;
}

final class DecodedSpreadsheet {
  const DecodedSpreadsheet({
    required this.extension,
    required this.sheets,
    this.textEncoding,
    this.delimiter,
  });

  final String extension;
  final List<TableSheet> sheets;
  final CsvTextEncoding? textEncoding;
  final String? delimiter;
}

/// Entry point for reading `.csv`, `.xlsx`, and `.xls` files into trimmed string matrices.
DecodedSpreadsheet decodeSpreadsheetFile({
  required String fileName,
  required Uint8List bytes,
}) {
  if (bytes.length > maxImportFileBytes) {
    throw const Failure(FailureCode.validation, '文件大小不能超过6M');
  }
  if (bytes.isEmpty) {
    throw const Failure(FailureCode.validation, '文件内容为空');
  }

  final ext = _extractExtension(fileName);
  if (ext != 'csv' && ext != 'xlsx' && ext != 'xls') {
    throw const Failure(FailureCode.validation, '不支持的文件格式，仅支持 .csv、.xlsx、.xls');
  }

  _guardHtmlDisguisedTable(bytes, ext);

  switch (ext) {
    case 'csv':
      final decoded = decodeSmartText(bytes);
      final delimiter = detectCsvDelimiter(decoded.text);
      final rows = parseDelimitedTable(decoded.text, delimiter: delimiter);
      return DecodedSpreadsheet(
        extension: 'csv',
        textEncoding: decoded.encoding,
        delimiter: delimiter,
        sheets: [TableSheet(sheetNo: 1, name: 'Sheet1', rows: rows)],
      );
    case 'xlsx':
      return DecodedSpreadsheet(
        extension: 'xlsx',
        sheets: parseXlsxBytes(bytes),
      );
    case 'xls':
      return DecodedSpreadsheet(extension: 'xls', sheets: parseXlsBytes(bytes));
    default:
      throw const Failure(FailureCode.validation, '不支持的文件格式');
  }
}

String _extractExtension(String fileName) {
  final trimmed = fileName.trim();
  final slashIdx = math.max(
    trimmed.lastIndexOf('/'),
    trimmed.lastIndexOf(r'\'),
  );
  final base = slashIdx >= 0 ? trimmed.substring(slashIdx + 1) : trimmed;
  final dotIdx = base.lastIndexOf('.');
  if (dotIdx < 0 || dotIdx == base.length - 1) return 'csv';
  return base.substring(dotIdx + 1).trim().toLowerCase();
}

void _guardHtmlDisguisedTable(Uint8List bytes, String ext) {
  // Real ZIP (.xlsx) magic: 50 4B 03 04
  if (bytes.length >= 4 &&
      bytes[0] == 0x50 &&
      bytes[1] == 0x4B &&
      bytes[2] == 0x03 &&
      bytes[3] == 0x04) {
    return;
  }
  // Real OLE2 (.xls) magic: D0 CF 11 E0 A1 B1 1A E1
  if (_hasOle2Magic(bytes)) {
    return;
  }

  final previewLen = math.min(bytes.length, 1024);
  final asciiBuf = StringBuffer();
  for (var i = 0; i < previewLen; i++) {
    final b = bytes[i];
    if (b >= 0x20 && b <= 0x7E) {
      asciiBuf.writeCharCode(b);
    } else if (b == 0x09 || b == 0x0A || b == 0x0D) {
      asciiBuf.write(' ');
    }
  }
  final snippet = asciiBuf.toString().trimLeft().toLowerCase();
  final hasHtmlTable =
      snippet.startsWith('<html') ||
      snippet.startsWith('<!doctype html') ||
      snippet.startsWith('<table') ||
      (snippet.contains('<html') && snippet.contains('<table')) ||
      (ext == 'xls' &&
          (snippet.contains('<table') ||
              snippet.startsWith('<?xml') ||
              snippet.startsWith('<workbook') ||
              snippet.startsWith('<ss:workbook')));
  if (hasHtmlTable) {
    throw const Failure(FailureCode.validation, htmlDisguisedExcelGuidance);
  }
}

bool _hasOle2Magic(Uint8List bytes) =>
    bytes.length >= 8 &&
    bytes[0] == 0xD0 &&
    bytes[1] == 0xCF &&
    bytes[2] == 0x11 &&
    bytes[3] == 0xE0 &&
    bytes[4] == 0xA1 &&
    bytes[5] == 0xB1 &&
    bytes[6] == 0x1A &&
    bytes[7] == 0xE1;

// ---------------------------------------------------------------------------
// Smart Text Encoding Probe (R1 / DR-IMP-01) & Pure-Dart Full GBK Codec
// ---------------------------------------------------------------------------

/// Probes encoding in strict order:
/// 1. UTF-8 with BOM (`EF BB BF`)
/// 2. Strict UTF-8 (without BOM — fixing `DR-IMP-01` where BOM-less Chinese UTF-8
///    headers were misdecoded as GBK mojibake)
/// 3. Strict GBK (full CP936/GBK 21,791-character table)
/// 4. UTF-16LE (with or without `FF FE` BOM)
DecodedCsvText decodeSmartText(Uint8List bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    final body = Uint8List.sublistView(bytes, 3);
    if (!body.contains(0)) {
      try {
        final text = const Utf8Decoder(allowMalformed: false).convert(body);
        return DecodedCsvText(text: text, encoding: CsvTextEncoding.utf8Bom);
      } on FormatException {
        // Fall through if bytes after EF BB BF are not valid UTF-8.
      }
    }
  }

  final hasUtf16Bom =
      bytes.length >= 2 &&
      ((bytes[0] == 0xFF && bytes[1] == 0xFE) ||
          (bytes[0] == 0xFE && bytes[1] == 0xFF));

  if (!hasUtf16Bom && !bytes.contains(0)) {
    try {
      final text = const Utf8Decoder(allowMalformed: false).convert(bytes);
      return DecodedCsvText(text: text, encoding: CsvTextEncoding.utf8);
    } on FormatException {
      // Fall back to strict GBK.
    }

    try {
      final text = GbkCodec.decode(bytes, allowMalformed: false);
      return DecodedCsvText(text: text, encoding: CsvTextEncoding.gbk);
    } on FormatException {
      // Fall back to UTF-16LE.
    }
  }

  return DecodedCsvText(
    text: _decodeUtf16LeStrict(bytes),
    encoding: CsvTextEncoding.utf16le,
  );
}

String _decodeUtf16LeStrict(Uint8List bytes) {
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    throw const Failure(
      FailureCode.validation,
      '暂不支持 UTF-16BE 编码，请另存为 UTF-8 或 GBK 格式后再导入',
    );
  }
  var offset = 0;
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    offset = 2;
  }
  final rem = bytes.length - offset;
  if (rem < 0 || rem.isOdd) {
    throw const Failure(
      FailureCode.validation,
      '文件编码无法识别，请另存为 UTF-8 或 GBK 格式的 CSV',
    );
  }
  final units = Uint16List(rem ~/ 2);
  for (var i = 0; i < units.length; i++) {
    final lo = bytes[offset + i * 2];
    final hi = bytes[offset + i * 2 + 1];
    units[i] = lo | (hi << 8);
  }
  // Validate surrogate pairs and reject NUL-heavy garbage.
  for (var i = 0; i < units.length; i++) {
    final u = units[i];
    if (u == 0) {
      throw const Failure(
        FailureCode.validation,
        '文件编码无法识别，请另存为 UTF-8 或 GBK 格式的 CSV',
      );
    }
    if (u >= 0xD800 && u <= 0xDBFF) {
      if (i + 1 >= units.length ||
          units[i + 1] < 0xDC00 ||
          units[i + 1] > 0xDFFF) {
        throw const Failure(
          FailureCode.validation,
          '文件编码无法识别，请另存为 UTF-8 或 GBK 格式的 CSV',
        );
      }
      i++;
    } else if (u >= 0xDC00 && u <= 0xDFFF) {
      throw const Failure(
        FailureCode.validation,
        '文件编码无法识别，请另存为 UTF-8 或 GBK 格式的 CSV',
      );
    }
  }
  return String.fromCharCodes(units);
}

/// Offline pure-Dart GBK codec covering all 21,791 standard GBK characters.
abstract final class GbkCodec {
  static Uint16List? _decodeTable;
  static Map<int, int>? _encodeTable;

  static void _ensureInitialized() {
    if (_decodeTable != null && _encodeTable != null) return;
    final raw = zlib.decode(base64Decode(_gbkDeltaZlibB64));
    final decode = Uint16List(23940);
    final encode = <int, int>{};
    var prev = 0;
    for (var i = 0; i < 23940; i++) {
      final delta = raw[i * 2] | (raw[i * 2 + 1] << 8);
      if (delta == 0) continue;
      prev = (prev + delta) & 0xFFFF;
      decode[i] = prev;
      encode.putIfAbsent(prev, () {
        final lead = 0x81 + (i ~/ 190);
        final rem = i % 190;
        final trail = rem < 0x3F ? 0x40 + rem : 0x41 + rem;
        return (lead << 8) | trail;
      });
    }
    _decodeTable = decode;
    _encodeTable = encode;
  }

  /// Decodes [bytes] using strict GBK rules unless [allowMalformed] is true.
  static String decode(List<int> bytes, {bool allowMalformed = false}) {
    _ensureInitialized();
    final table = _decodeTable!;
    final sb = StringBuffer();
    var i = 0;
    while (i < bytes.length) {
      final b1 = bytes[i] & 0xFF;
      if (b1 < 0x80) {
        if (!allowMalformed && b1 == 0) {
          throw const FormatException('Unexpected NUL byte in GBK text');
        }
        sb.writeCharCode(b1);
        i++;
        continue;
      }
      if (b1 >= 0x81 && b1 <= 0xFE) {
        if (i + 1 >= bytes.length) {
          if (!allowMalformed) {
            throw const FormatException('Truncated GBK double-byte sequence');
          }
          sb.writeCharCode(0xFFFD);
          break;
        }
        final b2 = bytes[i + 1] & 0xFF;
        if (b2 >= 0x40 && b2 <= 0xFE && b2 != 0x7F) {
          final trailOffset = b2 < 0x7F ? b2 - 0x40 : b2 - 0x41;
          final idx = (b1 - 0x81) * 190 + trailOffset;
          final cp = table[idx];
          if (cp != 0) {
            sb.writeCharCode(cp);
            i += 2;
            continue;
          }
        }
        if (!allowMalformed) {
          throw const FormatException('Invalid GBK byte pair');
        }
        sb.writeCharCode(0xFFFD);
        i += (b2 < 0x80) ? 1 : 2;
        continue;
      }
      if (!allowMalformed) {
        throw const FormatException('Invalid GBK byte');
      }
      sb.writeCharCode(0xFFFD);
      i++;
    }
    return sb.toString();
  }

  /// Encodes [text] into GBK bytes; non-GBK code points fall back to `'?'`.
  static Uint8List encode(String text) {
    _ensureInitialized();
    final map = _encodeTable!;
    final out = BytesBuilder(copy: false);
    for (final rune in text.runes) {
      if (rune < 0x80) {
        out.addByte(rune);
        continue;
      }
      // Halfwidth yen U+00A5 maps cleanly to GBK fullwidth ￥ (0xA3 0xA4).
      if (rune == 0x00A5) {
        out.addByte(0xA3);
        out.addByte(0xA4);
        continue;
      }
      final pair = map[rune];
      if (pair != null) {
        out.addByte((pair >> 8) & 0xFF);
        out.addByte(pair & 0xFF);
      } else {
        out.addByte(0x3F); // '?'
      }
    }
    return out.takeBytes();
  }
}

// ---------------------------------------------------------------------------
// RFC 4180 CSV / TSV Delimiter Detection, Parser, and Escaper (R2, R8)
// ---------------------------------------------------------------------------

/// Inspects up to the first 15 physical lines; picks `'\t'` if tabs outnumber commas.
String detectCsvDelimiter(String text) {
  var tabCount = 0;
  var commaCount = 0;
  var lines = 0;
  var inQuotes = false;
  for (var i = 0; i < text.length && lines < 15; i++) {
    final c = text.codeUnitAt(i);
    if (c == 0x22) {
      inQuotes = !inQuotes;
    } else if (!inQuotes && c == 0x09) {
      tabCount++;
    } else if (!inQuotes && c == 0x2C) {
      commaCount++;
    } else if (!inQuotes && (c == 0x0A || c == 0x0D)) {
      if (c == 0x0D && i + 1 < text.length && text.codeUnitAt(i + 1) == 0x0A) {
        i++;
      }
      lines++;
    }
  }
  return tabCount > commaCount ? '\t' : ',';
}

/// Parses RFC 4180 delimited text (supporting multiline quoted fields and `""`
/// escapes) and trims leading/trailing whitespace on every cell (R2).
List<List<String>> parseDelimitedTable(String text, {String? delimiter}) {
  if (text.isEmpty) return const [];
  final sep = (delimiter ?? detectCsvDelimiter(text)).codeUnitAt(0);
  // Strip leading UTF-8 BOM char if caller passed a String with U+FEFF.
  var start = 0;
  if (text.codeUnitAt(0) == 0xFEFF) start = 1;

  final rows = <List<String>>[];
  var row = <String>[];
  final cell = StringBuffer();
  var inQuotes = false;
  var cellStartedQuoted = false;

  for (var i = start; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (inQuotes) {
      if (c == 0x22) {
        if (i + 1 < text.length && text.codeUnitAt(i + 1) == 0x22) {
          cell.writeCharCode(0x22);
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        cell.writeCharCode(c);
      }
      continue;
    }

    if (c == 0x22 && cell.toString().trim().isEmpty && !cellStartedQuoted) {
      cell.clear();
      inQuotes = true;
      cellStartedQuoted = true;
      continue;
    }

    if (c == sep) {
      row.add(cell.toString().trim());
      cell.clear();
      cellStartedQuoted = false;
      continue;
    }

    if (c == 0x0D || c == 0x0A) {
      if (c == 0x0D && i + 1 < text.length && text.codeUnitAt(i + 1) == 0x0A) {
        i++;
      }
      row.add(cell.toString().trim());
      rows.add(row);
      row = <String>[];
      cell.clear();
      cellStartedQuoted = false;
      continue;
    }

    cell.writeCharCode(c);
  }

  if (row.isNotEmpty || cell.isNotEmpty || cellStartedQuoted) {
    row.add(cell.toString().trim());
    rows.add(row);
  }

  return rows;
}

/// Escapes a single CSV field strictly per RFC 4180 (R8 / `DR-IMP-08`).
String escapeCsvField(String value) {
  if (value.contains(',') ||
      value.contains('"') ||
      value.contains('\n') ||
      value.contains('\r')) {
    return '"${value.replaceAll('"', '""')}"';
  }
  return value;
}

/// Serializes rows to RFC 4180 CSV text (`\r\n` row terminator).
String encodeCsvText(List<List<String>> rows) {
  final sb = StringBuffer();
  for (var i = 0; i < rows.length; i++) {
    final row = rows[i];
    for (var j = 0; j < row.length; j++) {
      if (j > 0) sb.write(',');
      sb.write(escapeCsvField(row[j]));
    }
    sb.write('\r\n');
  }
  return sb.toString();
}

/// Encodes rows to UTF-8 with BOM (`EF BB BF`, default) or GBK without BOM (R8).
Uint8List encodeCsvBytes(List<List<String>> rows, {bool utf8WithBom = true}) {
  final text = encodeCsvText(rows);
  if (utf8WithBom) {
    final body = utf8.encode(text);
    final out = Uint8List(3 + body.length);
    out[0] = 0xEF;
    out[1] = 0xBB;
    out[2] = 0xBF;
    out.setRange(3, out.length, body);
    return out;
  }
  return GbkCodec.encode(text);
}

// ---------------------------------------------------------------------------
// Self-Contained Pure-Dart .xlsx Reader (ZIP + OOXML XML, EX-07 cell trim)
// ---------------------------------------------------------------------------

const int _maxUncompressedExcelBytes = 32 * 1024 * 1024;

List<TableSheet> parseXlsxBytes(Uint8List bytes) {
  final archive = _readZipEntries(bytes);
  if (archive.isEmpty) {
    throw const Failure(FailureCode.validation, '无法读取 .xlsx 工作簿内容');
  }

  final sharedStringsXml = archive['xl/sharedStrings.xml'];
  final sharedStrings = sharedStringsXml == null
      ? const <String>[]
      : _parseSharedStrings(
          utf8.decode(sharedStringsXml, allowMalformed: true),
        );

  final stylesXml = archive['xl/styles.xml'];
  final dateStyles = stylesXml == null
      ? const <int>{}
      : _parseDateStyleIndices(utf8.decode(stylesXml, allowMalformed: true));

  final date1904 =
      archive['xl/workbook.xml'] != null &&
      _isWorkbookDate1904(
        utf8.decode(archive['xl/workbook.xml']!, allowMalformed: true),
      );

  final orderedSheets = _resolveWorkbookSheets(archive);
  if (orderedSheets.isEmpty) {
    throw const Failure(FailureCode.validation, '.xlsx 文件中未找到工作表');
  }

  final sheets = <TableSheet>[];
  for (var i = 0; i < orderedSheets.length; i++) {
    final (name, path) = orderedSheets[i];
    final sheetBytes = archive[path];
    if (sheetBytes == null) continue;
    final xml = utf8.decode(sheetBytes, allowMalformed: true);
    final rows = _parseWorksheetXml(
      xml,
      sharedStrings: sharedStrings,
      dateStyles: dateStyles,
      date1904: date1904,
    );
    sheets.add(TableSheet(sheetNo: i + 1, name: name, rows: rows));
  }
  return sheets;
}

Map<String, Uint8List> _readZipEntries(Uint8List bytes) {
  if (bytes.length < 22) {
    throw const Failure(FailureCode.validation, '无效的 .xlsx 压缩容器');
  }
  final bd = ByteData.sublistView(bytes);
  final minEocdPos = math.max(0, bytes.length - 65557);
  var eocdPos = -1;
  for (var p = bytes.length - 22; p >= minEocdPos; p--) {
    if (bd.getUint32(p, Endian.little) == 0x06054b50) {
      eocdPos = p;
      break;
    }
  }
  if (eocdPos < 0) {
    throw const Failure(FailureCode.validation, '无效的 .xlsx 文件（缺少 ZIP 目录尾）');
  }

  final totalEntries = bd.getUint16(eocdPos + 10, Endian.little);
  final cdSize = bd.getUint32(eocdPos + 12, Endian.little);
  final cdOffset = bd.getUint32(eocdPos + 16, Endian.little);
  if (cdOffset + cdSize > eocdPos) {
    throw const Failure(FailureCode.validation, '.xlsx 压缩目录已损坏');
  }

  final entries = <String, Uint8List>{};
  final rawInflate = ZLibCodec(raw: true);
  var totalUncompressed = 0;
  var ptr = cdOffset;

  for (var i = 0; i < totalEntries && ptr + 46 <= eocdPos; i++) {
    final sig = bd.getUint32(ptr, Endian.little);
    if (sig != 0x02014b50) {
      throw const Failure(FailureCode.validation, '.xlsx 压缩目录条目损坏');
    }
    final flags = bd.getUint16(ptr + 8, Endian.little);
    if ((flags & 0x01) != 0) {
      throw const Failure(FailureCode.validation, '暂不支持带密码加密的 .xlsx 文件');
    }
    final method = bd.getUint16(ptr + 10, Endian.little);
    final compSize = bd.getUint32(ptr + 20, Endian.little);
    final uncompSize = bd.getUint32(ptr + 24, Endian.little);
    final nameLen = bd.getUint16(ptr + 28, Endian.little);
    final extraLen = bd.getUint16(ptr + 30, Endian.little);
    final commentLen = bd.getUint16(ptr + 32, Endian.little);
    final localOffset = bd.getUint32(ptr + 42, Endian.little);

    if (ptr + 46 + nameLen > eocdPos) {
      throw const Failure(FailureCode.validation, '.xlsx 条目名称超出边界');
    }
    final rawName = utf8.decode(
      Uint8List.sublistView(bytes, ptr + 46, ptr + 46 + nameLen),
      allowMalformed: true,
    );
    ptr += 46 + nameLen + extraLen + commentLen;

    // Normalize archive path and skip directories / non-xl resources if huge.
    final normName = rawName
        .replaceAll(r'\', '/')
        .replaceFirst(RegExp(r'^/+'), '');
    if (normName.isEmpty || normName.endsWith('/') || normName.contains('..')) {
      continue;
    }

    totalUncompressed += uncompSize;
    if (totalUncompressed > _maxUncompressedExcelBytes) {
      throw const Failure(FailureCode.validation, '.xlsx 解压体积超出安全上限');
    }

    if (localOffset + 30 > bytes.length ||
        bd.getUint32(localOffset, Endian.little) != 0x04034b50) {
      throw const Failure(FailureCode.validation, '.xlsx 本地文件头损坏');
    }
    final localNameLen = bd.getUint16(localOffset + 26, Endian.little);
    final localExtraLen = bd.getUint16(localOffset + 28, Endian.little);
    final dataStart = localOffset + 30 + localNameLen + localExtraLen;
    final dataEnd = dataStart + compSize;
    if (dataStart < 0 || dataEnd > bytes.length) {
      throw const Failure(FailureCode.validation, '.xlsx 压缩数据越界');
    }

    final slice = Uint8List.sublistView(bytes, dataStart, dataEnd);
    if (method == 0) {
      entries[normName] = Uint8List.fromList(slice);
    } else if (method == 8) {
      try {
        final inflated = rawInflate.decode(slice);
        if (inflated.length > _maxUncompressedExcelBytes) {
          throw const Failure(FailureCode.validation, '.xlsx 解压体积超出安全上限');
        }
        entries[normName] = Uint8List.fromList(inflated);
      } catch (e) {
        if (e is Failure) rethrow;
        throw const Failure(FailureCode.validation, '.xlsx 压缩流损坏');
      }
    } else {
      throw Failure(FailureCode.validation, '.xlsx 使用了不支持的压缩算法 ($method)');
    }
  }
  return entries;
}

List<(String, String)> _resolveWorkbookSheets(Map<String, Uint8List> archive) {
  final wbBytes = archive['xl/workbook.xml'];
  final relsBytes = archive['xl/_rels/workbook.xml.rels'];
  if (wbBytes != null && relsBytes != null) {
    final wbXml = utf8.decode(wbBytes, allowMalformed: true);
    final relsXml = utf8.decode(relsBytes, allowMalformed: true);

    final relTargets = <String, String>{};
    final relTagRe = RegExp(r'<(?:\w+:)?Relationship\b([^>]*)/?>');
    for (final m in relTagRe.allMatches(relsXml)) {
      final attrs = m.group(1) ?? '';
      final id = _xmlAttr(attrs, 'Id');
      final target = _xmlAttr(attrs, 'Target');
      if (id != null && target != null) {
        var clean = target.replaceAll(r'\', '/');
        if (clean.startsWith('/')) {
          clean = clean.substring(1);
        } else if (!clean.startsWith('xl/')) {
          clean = 'xl/$clean';
        }
        relTargets[id] = clean;
      }
    }

    final sheets = <(String, String)>[];
    final sheetTagRe = RegExp(r'<(?:\w+:)?sheet\b([^>]*)/?>');
    for (final m in sheetTagRe.allMatches(wbXml)) {
      final attrs = m.group(1) ?? '';
      final name = _unescapeXml(_xmlAttr(attrs, 'name') ?? 'Sheet');
      final rId = _xmlAttr(attrs, 'r:id') ?? _xmlAttr(attrs, 'id');
      final target = rId == null ? null : relTargets[rId];
      if (target != null && archive.containsKey(target)) {
        sheets.add((name, target));
      }
    }
    if (sheets.isNotEmpty) return sheets;
  }

  final fallbackKeys =
      archive.keys
          .where((k) => RegExp(r'^xl/worksheets/sheet\d+\.xml$').hasMatch(k))
          .toList()
        ..sort((a, b) {
          final na =
              int.tryParse(RegExp(r'\d+').firstMatch(a)?.group(0) ?? '0') ?? 0;
          final nb =
              int.tryParse(RegExp(r'\d+').firstMatch(b)?.group(0) ?? '0') ?? 0;
          return na.compareTo(nb);
        });
  return [
    for (var i = 0; i < fallbackKeys.length; i++)
      ('Sheet${i + 1}', fallbackKeys[i]),
  ];
}

bool _isWorkbookDate1904(String wbXml) {
  final m = RegExp(r'<(?:\w+:)?workbookPr\b([^>]*)/?>').firstMatch(wbXml);
  if (m == null) return false;
  final v = _xmlAttr(m.group(1) ?? '', 'date1904')?.toLowerCase();
  return v == '1' || v == 'true';
}

List<String> _parseSharedStrings(String xml) {
  final result = <String>[];
  final siRe = RegExp(r'<(?:\w+:)?si\b[^>]*>([\s\S]*?)</(?:\w+:)?si>');
  final rPhRe = RegExp(r'<(?:\w+:)?rPh\b[^>]*>[\s\S]*?</(?:\w+:)?rPh>');
  final tRe = RegExp(r'<(?:\w+:)?t\b[^>]*>([\s\S]*?)</(?:\w+:)?t>');
  for (final m in siRe.allMatches(xml)) {
    final body = (m.group(1) ?? '').replaceAll(rPhRe, '');
    final sb = StringBuffer();
    for (final tm in tRe.allMatches(body)) {
      sb.write(_unescapeXml(tm.group(1) ?? ''));
    }
    result.add(sb.toString());
  }
  return result;
}

Set<int> _parseDateStyleIndices(String xml) {
  final customFmts = <int, String>{};
  final numFmtRe = RegExp(r'<(?:\w+:)?numFmt\b([^>]*)/?>');
  for (final m in numFmtRe.allMatches(xml)) {
    final attrs = m.group(1) ?? '';
    final id = int.tryParse(_xmlAttr(attrs, 'numFmtId') ?? '');
    final code = _xmlAttr(attrs, 'formatCode');
    if (id != null && code != null) {
      customFmts[id] = _unescapeXml(code);
    }
  }

  final cellXfsMatch = RegExp(
    r'<(?:\w+:)?cellXfs\b[^>]*>([\s\S]*?)</(?:\w+:)?cellXfs>',
  ).firstMatch(xml);
  if (cellXfsMatch == null) return const {};

  final dateStyles = <int>{};
  final xfRe = RegExp(r'<(?:\w+:)?xf\b([^>]*)(?:/>|>[\s\S]*?</(?:\w+:)?xf>)');
  var idx = 0;
  for (final m in xfRe.allMatches(cellXfsMatch.group(1) ?? '')) {
    final attrs = m.group(1) ?? '';
    final fmtId = int.tryParse(_xmlAttr(attrs, 'numFmtId') ?? '0') ?? 0;
    if (_isExcelDateNumFmt(fmtId, customFmts[fmtId])) {
      dateStyles.add(idx);
    }
    idx++;
  }
  return dateStyles;
}

bool _isExcelDateNumFmt(int fmtId, String? formatCode) {
  if ((fmtId >= 14 && fmtId <= 22) ||
      (fmtId >= 27 && fmtId <= 36) ||
      (fmtId >= 45 && fmtId <= 47) ||
      (fmtId >= 50 && fmtId <= 58)) {
    return true;
  }
  if (formatCode == null || formatCode.trim().isEmpty) return false;
  var cleaned = formatCode
      .replaceAll(RegExp(r'"[^"]*"'), '')
      .replaceAll(RegExp(r'\\?.', dotAll: true), '');
  // Re-clean properly: remove quoted strings, escaped single chars, and [Color]/[$-locale] tags.
  cleaned = formatCode
      .replaceAll(RegExp(r'"[^"]*"'), '')
      .replaceAll(RegExp(r'\\.'), '')
      .replaceAllMapped(RegExp(r'\[([^\]]*)\]'), (m) {
        final inner = (m.group(1) ?? '').toLowerCase();
        return (inner.startsWith('h') ||
                inner.startsWith('m') ||
                inner.startsWith('s'))
            ? inner
            : '';
      })
      .toLowerCase();
  if (cleaned.contains('general')) return false;
  // Must contain date/time tokens and no #/0 numeric placeholders mixed unless elapsed.
  final hasDateToken = RegExp(r'[ymdhs]').hasMatch(cleaned);
  final hasNumPlaceholder = RegExp(r'[0#?]').hasMatch(cleaned);
  return hasDateToken && !hasNumPlaceholder;
}

List<List<String>> _parseWorksheetXml(
  String xml, {
  required List<String> sharedStrings,
  required Set<int> dateStyles,
  required bool date1904,
}) {
  final rowMap = <int, List<String>>{};
  var minRow = 1 << 30;
  var maxRow = 0;
  var autoRow = 0;

  final rowRe = RegExp(
    r'<(?:\w+:)?row\b([^>]*?)(?:/>|>([\s\S]*?)</(?:\w+:)?row>)',
  );
  final cellRe = RegExp(
    r'<(?:\w+:)?c\b([^>]*?)(?:/>|>([\s\S]*?)</(?:\w+:)?c>)',
  );
  final vRe = RegExp(r'<(?:\w+:)?v\b[^>]*>([\s\S]*?)</(?:\w+:)?v>');
  final tRe = RegExp(r'<(?:\w+:)?t\b[^>]*>([\s\S]*?)</(?:\w+:)?t>');

  for (final rm in rowRe.allMatches(xml)) {
    autoRow++;
    final rowAttrs = rm.group(1) ?? '';
    final rowBody = rm.group(2);
    final rowNum = int.tryParse(_xmlAttr(rowAttrs, 'r') ?? '') ?? autoRow;
    if (rowNum < minRow) minRow = rowNum;
    if (rowNum > maxRow) maxRow = rowNum;
    if (rowBody == null || rowBody.isEmpty) {
      rowMap[rowNum] = const [];
      continue;
    }

    final cellsByCol = <int, String>{};
    var nextCol = 0;
    var maxCol = -1;
    for (final cm in cellRe.allMatches(rowBody)) {
      final cAttrs = cm.group(1) ?? '';
      final cBody = cm.group(2) ?? '';
      final ref = _xmlAttr(cAttrs, 'r');
      final colIdx = ref == null ? nextCol : (_colIndexFromRef(ref) ?? nextCol);
      nextCol = colIdx + 1;
      if (colIdx > maxCol) maxCol = colIdx;

      final cellType = _xmlAttr(cAttrs, 't') ?? '';
      final styleIdx = int.tryParse(_xmlAttr(cAttrs, 's') ?? '');
      var value = '';

      if (cellType == 's') {
        final vText = _unescapeXml(
          vRe.firstMatch(cBody)?.group(1) ?? '',
        ).trim();
        final sIdx = int.tryParse(vText);
        if (sIdx != null && sIdx >= 0 && sIdx < sharedStrings.length) {
          value = sharedStrings[sIdx];
        }
      } else if (cellType == 'inlineStr') {
        final sb = StringBuffer();
        for (final tm in tRe.allMatches(cBody)) {
          sb.write(_unescapeXml(tm.group(1) ?? ''));
        }
        value = sb.toString();
      } else if (cellType == 'str') {
        value = _unescapeXml(vRe.firstMatch(cBody)?.group(1) ?? '');
      } else if (cellType == 'b') {
        final vText = (vRe.firstMatch(cBody)?.group(1) ?? '').trim();
        value = vText == '1' ? '1' : '0';
      } else if (cellType == 'e') {
        value = '';
      } else {
        final rawV = _unescapeXml(vRe.firstMatch(cBody)?.group(1) ?? '').trim();
        if (rawV.isNotEmpty) {
          if (styleIdx != null && dateStyles.contains(styleIdx)) {
            final serial = double.tryParse(rawV);
            value = serial == null
                ? rawV
                : _formatExcelSerialDate(serial, date1904: date1904);
          } else {
            value = _normalizeExcelNumericText(rawV);
          }
        }
      }

      // Unified cell trim (R2 / EX-07 / DR-IMP-07).
      cellsByCol[colIdx] = value.trim();
    }

    if (maxCol < 0) {
      rowMap[rowNum] = const [];
    } else {
      rowMap[rowNum] = [for (var c = 0; c <= maxCol; c++) cellsByCol[c] ?? ''];
    }
  }

  if (maxRow == 0 || minRow > maxRow) return const [];
  return [for (var r = minRow; r <= maxRow; r++) rowMap[r] ?? const <String>[]];
}

int? _colIndexFromRef(String ref) {
  var col = 0;
  var hasLetters = false;
  for (var i = 0; i < ref.length; i++) {
    final c = ref.codeUnitAt(i);
    if (c >= 0x41 && c <= 0x5A) {
      col = col * 26 + (c - 0x41 + 1);
      hasLetters = true;
    } else if (c >= 0x61 && c <= 0x7A) {
      col = col * 26 + (c - 0x61 + 1);
      hasLetters = true;
    } else {
      break;
    }
  }
  return hasLetters ? col - 1 : null;
}

String _normalizeExcelNumericText(String raw) {
  // Strip redundant trailing ".0" on whole integers while keeping exact decimals
  // and scientific notation untouched for BigInt/DecimalValue parsing.
  if (RegExp(r'^-?\d+\.0+$').hasMatch(raw)) {
    return raw.substring(0, raw.indexOf('.'));
  }
  return raw;
}

String _formatExcelSerialDate(double serial, {required bool date1904}) {
  // Excel 1900 system: serial 1 = 1900-01-01, with phantom 1900-02-29 at serial 60.
  // Excel 1904 system: serial 0 = 1904-01-01.
  double adjustedDays = serial;
  DateTime epoch;
  if (date1904) {
    epoch = DateTime.utc(1904, 1, 1);
  } else {
    epoch = DateTime.utc(1899, 12, 31);
    if (adjustedDays >= 60) {
      adjustedDays -= 1;
    }
  }
  final totalMillis = (adjustedDays * 86400000.0).round();
  final utc = epoch.add(Duration(milliseconds: totalMillis));
  String two(int n) => n.toString().padLeft(2, '0');
  return '${utc.year}-${two(utc.month)}-${two(utc.day)} '
      '${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)}';
}

String? _xmlAttr(String attrs, String name) {
  final re = RegExp(
    '(?:^|\\s)${RegExp.escape(name)}\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\')',
  );
  final m = re.firstMatch(attrs);
  return m?.group(1) ?? m?.group(2);
}

String _unescapeXml(String input) {
  if (!input.contains('&') && !input.contains('_x')) return input;
  var s = input.replaceAllMapped(
    RegExp(r'_x([0-9a-fA-F]{4})_'),
    (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
  );
  s = s.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);|&#(\d+);'), (m) {
    final cp = m.group(1) != null
        ? int.tryParse(m.group(1)!, radix: 16)
        : int.tryParse(m.group(2)!);
    return cp == null ? m.group(0)! : String.fromCharCode(cp);
  });
  return s
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');
}

// ---------------------------------------------------------------------------
// Self-Contained Pure-Dart BIFF8 / OLE2 .xls Reader (R2: no #.### truncation!)
// ---------------------------------------------------------------------------

List<TableSheet> parseXlsBytes(Uint8List bytes) {
  if (!_hasOle2Magic(bytes)) {
    throw const Failure(
      FailureCode.validation,
      '无法识别的 .xls 文件格式，请用 Excel 打开后另存为标准 .xlsx 格式再导入',
    );
  }
  final workbookStream = _extractOle2WorkbookStream(bytes);
  return _parseBiff8Workbook(workbookStream);
}

Uint8List _extractOle2WorkbookStream(Uint8List bytes) {
  if (bytes.length < 512) {
    throw const Failure(FailureCode.validation, '.xls OLE2 文件头不完整');
  }
  final bd = ByteData.sublistView(bytes);
  final sectorShift = bd.getUint16(0x1E, Endian.little);
  final miniSectorShift = bd.getUint16(0x20, Endian.little);
  if (sectorShift < 7 ||
      sectorShift > 16 ||
      miniSectorShift < 4 ||
      miniSectorShift > sectorShift) {
    throw const Failure(FailureCode.validation, '.xls 扇区参数无效');
  }
  final sectorSize = 1 << sectorShift;
  final miniSectorSize = 1 << miniSectorShift;

  final numFatSectors = bd.getUint32(0x2C, Endian.little);
  final firstDirSector = bd.getUint32(0x30, Endian.little);
  final miniCutoff = bd.getUint32(0x38, Endian.little);
  final firstMiniFatSector = bd.getUint32(0x3C, Endian.little);
  final numMiniFatSectors = bd.getUint32(0x40, Endian.little);
  var difatSector = bd.getUint32(0x44, Endian.little);
  final numDifatSectors = bd.getUint32(0x48, Endian.little);

  int sectorOffset(int secId) => 512 + secId * sectorSize;

  final fatSectorIds = <int>[];
  for (var i = 0; i < 109 && fatSectorIds.length < numFatSectors; i++) {
    final sid = bd.getUint32(0x4C + i * 4, Endian.little);
    if (sid < 0xFFFFFFFC) fatSectorIds.add(sid);
  }
  final entriesPerSector = sectorSize ~/ 4;
  for (
    var d = 0;
    d < numDifatSectors &&
        difatSector < 0xFFFFFFFC &&
        fatSectorIds.length < numFatSectors;
    d++
  ) {
    final off = sectorOffset(difatSector);
    if (off < 0 || off + sectorSize > bytes.length) break;
    for (
      var j = 0;
      j < entriesPerSector - 1 && fatSectorIds.length < numFatSectors;
      j++
    ) {
      final sid = bd.getUint32(off + j * 4, Endian.little);
      if (sid < 0xFFFFFFFC) fatSectorIds.add(sid);
    }
    difatSector = bd.getUint32(off + (entriesPerSector - 1) * 4, Endian.little);
  }

  final fat = <int>[];
  for (final sid in fatSectorIds) {
    final off = sectorOffset(sid);
    if (off < 0 || off + sectorSize > bytes.length) continue;
    for (var j = 0; j < entriesPerSector; j++) {
      fat.add(bd.getUint32(off + j * 4, Endian.little));
    }
  }

  Uint8List readSectorChain(int startSector, [int? exactLength]) {
    final out = BytesBuilder(copy: false);
    var sid = startSector;
    var steps = 0;
    final maxSteps = fat.length + 1;
    while (sid < 0xFFFFFFFC && sid < fat.length && steps < maxSteps) {
      final off = sectorOffset(sid);
      if (off < 0 || off + sectorSize > bytes.length) break;
      out.add(Uint8List.sublistView(bytes, off, off + sectorSize));
      if (exactLength != null && out.length >= exactLength) break;
      sid = fat[sid];
      steps++;
    }
    final all = out.takeBytes();
    if (exactLength != null && all.length > exactLength) {
      return Uint8List.sublistView(all, 0, exactLength);
    }
    return all;
  }

  final dirBytes = readSectorChain(firstDirSector);
  if (dirBytes.length < 128) {
    throw const Failure(FailureCode.validation, '.xls 目录流为空');
  }
  final dirBd = ByteData.sublistView(dirBytes);

  int? rootStartSector;
  int rootSize = 0;
  int? wbStartSector;
  int wbSize = 0;

  for (var pos = 0; pos + 128 <= dirBytes.length; pos += 128) {
    final nameBytesLen = dirBd.getUint16(pos + 0x40, Endian.little);
    final objType = dirBytes[pos + 0x42];
    if (objType == 0 || nameBytesLen < 2 || nameBytesLen > 64) continue;
    final charCount = (nameBytesLen ~/ 2) - 1;
    final units = Uint16List(charCount);
    for (var k = 0; k < charCount; k++) {
      units[k] = dirBd.getUint16(pos + k * 2, Endian.little);
    }
    final name = String.fromCharCodes(units).trim().toLowerCase();
    final startSec = dirBd.getUint32(pos + 0x74, Endian.little);
    final streamSize = dirBd.getUint32(pos + 0x78, Endian.little);

    if (objType == 5) {
      rootStartSector = startSec;
      rootSize = streamSize;
    } else if (objType == 2 && (name == 'workbook' || name == 'book')) {
      wbStartSector = startSec;
      wbSize = streamSize;
    }
  }

  if (wbStartSector == null || wbSize <= 0) {
    throw const Failure(FailureCode.validation, '.xls 中未找到 Workbook 工作簿流');
  }
  if (wbSize > _maxUncompressedExcelBytes) {
    throw const Failure(FailureCode.validation, '.xls 工作簿体积超出安全上限');
  }

  if (wbSize >= miniCutoff) {
    return readSectorChain(wbStartSector, wbSize);
  }

  if (rootStartSector == null) {
    throw const Failure(FailureCode.validation, '.xls 缺少 Root Entry 迷你流');
  }
  final miniStream = readSectorChain(rootStartSector, rootSize);
  final miniFatBytes = numMiniFatSectors == 0
      ? Uint8List(0)
      : readSectorChain(firstMiniFatSector);
  final miniFatBd = ByteData.sublistView(miniFatBytes);
  final miniFatCount = miniFatBytes.length ~/ 4;

  final out = BytesBuilder(copy: false);
  var msid = wbStartSector;
  var steps = 0;
  while (msid < 0xFFFFFFFC &&
      out.length < wbSize &&
      steps <= miniFatCount + 1) {
    final mOff = msid * miniSectorSize;
    if (mOff < 0 || mOff >= miniStream.length) break;
    final end = math.min(mOff + miniSectorSize, miniStream.length);
    out.add(Uint8List.sublistView(miniStream, mOff, end));
    if (msid >= miniFatCount) break;
    msid = miniFatBd.getUint32(msid * 4, Endian.little);
    steps++;
  }
  final result = out.takeBytes();
  return result.length > wbSize
      ? Uint8List.sublistView(result, 0, wbSize)
      : result;
}

List<TableSheet> _parseBiff8Workbook(Uint8List stream) {
  final bd = ByteData.sublistView(stream);
  final formats = <int, String>{};
  final xfFmtIds = <int>[];
  final boundSheets = <(String, int)>[];
  var sst = const <String>[];
  var date1904 = false;

  // Pass 1: Workbook Globals (BOF .. first EOF).
  var pos = 0;
  var inGlobals = false;
  while (pos + 4 <= stream.length) {
    final recType = bd.getUint16(pos, Endian.little);
    final recLen = bd.getUint16(pos + 2, Endian.little);
    final dataStart = pos + 4;
    final dataEnd = dataStart + recLen;
    if (dataEnd > stream.length) break;

    if (recType == 0x0809 && recLen >= 4) {
      final substreamType = bd.getUint16(dataStart + 2, Endian.little);
      if (substreamType == 0x0005) {
        inGlobals = true;
      } else if (inGlobals) {
        break;
      }
    } else if (inGlobals && recType == 0x000A) {
      break;
    } else if (inGlobals) {
      switch (recType) {
        case 0x0022: // DATEMODE
          if (recLen >= 2) {
            date1904 = bd.getUint16(dataStart, Endian.little) == 1;
          }
        case 0x0085: // BOUNDSHEET
          if (recLen >= 8) {
            final sheetBof = bd.getUint32(dataStart, Endian.little);
            final grbit = stream[dataStart + 4];
            if (grbit == 0) {
              // Worksheet (0 = worksheet; skip charts/macros).
              final cch = stream[dataStart + 6];
              final name = _readBiff8ShortString(stream, dataStart + 7, cch);
              boundSheets.add((name, sheetBof));
            }
          }
        case 0x041E: // FORMAT
          if (recLen >= 5) {
            final fmtIdx = bd.getUint16(dataStart, Endian.little);
            final fmtStr = _readBiff8UnicodeStringSimple(
              stream,
              dataStart + 2,
              dataEnd,
            );
            formats[fmtIdx] = fmtStr;
          }
        case 0x00E0: // XF
          if (recLen >= 4) {
            xfFmtIds.add(bd.getUint16(dataStart + 2, Endian.little));
          }
        case 0x00FC: // SST (with optional CONTINUE 0x003C records)
          final chunks = <Uint8List>[
            Uint8List.sublistView(stream, dataStart, dataEnd),
          ];
          var nextPos = dataEnd;
          while (nextPos + 4 <= stream.length &&
              bd.getUint16(nextPos, Endian.little) == 0x003C) {
            final contLen = bd.getUint16(nextPos + 2, Endian.little);
            if (nextPos + 4 + contLen > stream.length) break;
            chunks.add(
              Uint8List.sublistView(stream, nextPos + 4, nextPos + 4 + contLen),
            );
            nextPos += 4 + contLen;
          }
          sst = _parseBiff8Sst(chunks);
          pos = nextPos;
          continue;
      }
    }
    pos = dataEnd;
  }

  final dateXfs = <int>{};
  for (var i = 0; i < xfFmtIds.length; i++) {
    final fmtId = xfFmtIds[i];
    if (_isExcelDateNumFmt(fmtId, formats[fmtId])) {
      dateXfs.add(i);
    }
  }

  final sheets = <TableSheet>[];
  for (var i = 0; i < boundSheets.length; i++) {
    final (name, bofOffset) = boundSheets[i];
    final rows = _parseBiff8Worksheet(
      stream,
      bofOffset,
      sst: sst,
      dateXfs: dateXfs,
      date1904: date1904,
    );
    sheets.add(TableSheet(sheetNo: i + 1, name: name, rows: rows));
  }
  return sheets;
}

List<List<String>> _parseBiff8Worksheet(
  Uint8List stream,
  int startOffset, {
  required List<String> sst,
  required Set<int> dateXfs,
  required bool date1904,
}) {
  if (startOffset < 0 || startOffset + 4 > stream.length) return const [];
  final bd = ByteData.sublistView(stream);
  final cells = <int, Map<int, String>>{};
  var maxRow = -1;
  var pos = startOffset;
  var started = false;
  (int, int)? pendingStringFormulaCell;

  void putCell(int r, int c, String val) {
    if (r < 0 || c < 0) return;
    if (r > maxRow) maxRow = r;
    (cells[r] ??= <int, String>{})[c] = val.trim();
  }

  String formatNum(double v, int xf) {
    if (dateXfs.contains(xf)) {
      return _formatExcelSerialDate(v, date1904: date1904);
    }
    if (v.isNaN || v.isInfinite) return '';
    final raw = v.toString();
    return _normalizeExcelNumericText(raw);
  }

  while (pos + 4 <= stream.length) {
    final recType = bd.getUint16(pos, Endian.little);
    final recLen = bd.getUint16(pos + 2, Endian.little);
    final dStart = pos + 4;
    final dEnd = dStart + recLen;
    if (dEnd > stream.length) break;

    if (recType == 0x0809) {
      if (started) {
        // Nested chart/object BOF: skip until matching EOF.
        var depth = 1;
        var p2 = dEnd;
        while (p2 + 4 <= stream.length && depth > 0) {
          final rt2 = bd.getUint16(p2, Endian.little);
          final rl2 = bd.getUint16(p2 + 2, Endian.little);
          if (rt2 == 0x0809) depth++;
          if (rt2 == 0x000A) depth--;
          p2 += 4 + rl2;
        }
        pos = p2;
        continue;
      }
      started = true;
      pos = dEnd;
      continue;
    }
    if (!started) {
      pos = dEnd;
      continue;
    }
    if (recType == 0x000A) break; // Worksheet EOF

    switch (recType) {
      case 0x00FD: // LABELSST
        pendingStringFormulaCell = null;
        if (recLen >= 10) {
          final r = bd.getUint16(dStart, Endian.little);
          final c = bd.getUint16(dStart + 2, Endian.little);
          final sstIdx = bd.getUint32(dStart + 6, Endian.little);
          if (sstIdx >= 0 && sstIdx < sst.length) {
            putCell(r, c, sst[sstIdx]);
          }
        }
      case 0x0204: // LABEL
        pendingStringFormulaCell = null;
        if (recLen >= 8) {
          final r = bd.getUint16(dStart, Endian.little);
          final c = bd.getUint16(dStart + 2, Endian.little);
          final s = _readBiff8UnicodeStringSimple(stream, dStart + 6, dEnd);
          putCell(r, c, s);
        }
      case 0x0203: // NUMBER
        pendingStringFormulaCell = null;
        if (recLen >= 14) {
          final r = bd.getUint16(dStart, Endian.little);
          final c = bd.getUint16(dStart + 2, Endian.little);
          final xf = bd.getUint16(dStart + 4, Endian.little);
          final v = bd.getFloat64(dStart + 6, Endian.little);
          putCell(r, c, formatNum(v, xf));
        }
      case 0x027E: // RK
        pendingStringFormulaCell = null;
        if (recLen >= 10) {
          final r = bd.getUint16(dStart, Endian.little);
          final c = bd.getUint16(dStart + 2, Endian.little);
          final xf = bd.getUint16(dStart + 4, Endian.little);
          final rk = bd.getUint32(dStart + 6, Endian.little);
          putCell(r, c, _formatRkValue(rk, xf, dateXfs, date1904));
        }
      case 0x00BD: // MULRK
        pendingStringFormulaCell = null;
        if (recLen >= 6) {
          final r = bd.getUint16(dStart, Endian.little);
          final firstCol = bd.getUint16(dStart + 2, Endian.little);
          final lastCol = bd.getUint16(dEnd - 2, Endian.little);
          var off = dStart + 4;
          for (var c = firstCol; c <= lastCol && off + 6 <= dEnd - 2; c++) {
            final xf = bd.getUint16(off, Endian.little);
            final rk = bd.getUint32(off + 2, Endian.little);
            putCell(r, c, _formatRkValue(rk, xf, dateXfs, date1904));
            off += 6;
          }
        }
      case 0x0006: // FORMULA
        pendingStringFormulaCell = null;
        if (recLen >= 14) {
          final r = bd.getUint16(dStart, Endian.little);
          final c = bd.getUint16(dStart + 2, Endian.little);
          final xf = bd.getUint16(dStart + 4, Endian.little);
          if (stream[dStart + 12] == 0xFF && stream[dStart + 13] == 0xFF) {
            final resType = stream[dStart + 6];
            if (resType == 0) {
              pendingStringFormulaCell = (r, c);
            } else if (resType == 1) {
              putCell(r, c, stream[dStart + 8] != 0 ? '1' : '0');
            } else {
              putCell(r, c, '');
            }
          } else {
            final v = bd.getFloat64(dStart + 6, Endian.little);
            putCell(r, c, formatNum(v, xf));
          }
        }
      case 0x0207: // STRING (formula cached text)
        if (pendingStringFormulaCell != null && recLen >= 3) {
          final (r, c) = pendingStringFormulaCell;
          final s = _readBiff8UnicodeStringSimple(stream, dStart, dEnd);
          putCell(r, c, s);
          pendingStringFormulaCell = null;
        }
      case 0x0205: // BOOLERR
        pendingStringFormulaCell = null;
        if (recLen >= 8) {
          final r = bd.getUint16(dStart, Endian.little);
          final c = bd.getUint16(dStart + 2, Endian.little);
          final isErr = stream[dStart + 7] != 0;
          putCell(r, c, isErr ? '' : (stream[dStart + 6] != 0 ? '1' : '0'));
        }
    }
    pos = dEnd;
  }

  if (maxRow < 0) return const [];
  final rows = <List<String>>[];
  for (var r = 0; r <= maxRow; r++) {
    final rowMap = cells[r];
    if (rowMap == null || rowMap.isEmpty) {
      rows.add(const []);
      continue;
    }
    var maxCol = -1;
    for (final c in rowMap.keys) {
      if (c > maxCol) maxCol = c;
    }
    rows.add([for (var c = 0; c <= maxCol; c++) rowMap[c] ?? '']);
  }
  return rows;
}

String _formatRkValue(int rk, int xf, Set<int> dateXfs, bool date1904) {
  final div100 = (rk & 0x01) != 0;
  final isInt = (rk & 0x02) != 0;
  if (isInt && !dateXfs.contains(xf)) {
    final signed30 = rk.toSigned(32) >> 2;
    if (!div100) return signed30.toString();
    final sign = signed30 < 0 ? '-' : '';
    final absVal = signed30.abs();
    final whole = absVal ~/ 100;
    final frac = absVal % 100;
    if (frac == 0) return '$sign$whole';
    final fracStr = frac
        .toString()
        .padLeft(2, '0')
        .replaceFirst(RegExp(r'0+$'), '');
    return '$sign$whole.$fracStr';
  }
  double val;
  if (isInt) {
    val = (rk.toSigned(32) >> 2).toDouble();
  } else {
    final tmp = ByteData(8);
    tmp.setUint32(0, 0, Endian.little);
    tmp.setUint32(4, rk & 0xFFFFFFFC, Endian.little);
    val = tmp.getFloat64(0, Endian.little);
  }
  if (div100) val /= 100.0;
  if (dateXfs.contains(xf)) {
    return _formatExcelSerialDate(val, date1904: date1904);
  }
  return _normalizeExcelNumericText(val.toString());
}

String _readBiff8ShortString(Uint8List stream, int offset, int cch) {
  if (offset >= stream.length || cch <= 0) return '';
  final flags = stream[offset];
  final utf16 = (flags & 0x01) != 0;
  var p = offset + 1;
  final sb = StringBuffer();
  for (var i = 0; i < cch; i++) {
    if (utf16) {
      if (p + 2 > stream.length) break;
      sb.writeCharCode(stream[p] | (stream[p + 1] << 8));
      p += 2;
    } else {
      if (p >= stream.length) break;
      sb.writeCharCode(stream[p]);
      p += 1;
    }
  }
  return sb.toString();
}

String _readBiff8UnicodeStringSimple(Uint8List stream, int offset, int end) {
  if (offset + 3 > end) return '';
  final bd = ByteData.sublistView(stream);
  final cch = bd.getUint16(offset, Endian.little);
  final flags = stream[offset + 2];
  var p = offset + 3;
  if ((flags & 0x08) != 0) {
    if (p + 2 > end) return '';
    p += 2;
  }
  if ((flags & 0x04) != 0) {
    if (p + 4 > end) return '';
    p += 4;
  }
  final utf16 = (flags & 0x01) != 0;
  final sb = StringBuffer();
  for (var i = 0; i < cch; i++) {
    if (utf16) {
      if (p + 2 > end) break;
      sb.writeCharCode(stream[p] | (stream[p + 1] << 8));
      p += 2;
    } else {
      if (p >= end) break;
      sb.writeCharCode(stream[p]);
      p += 1;
    }
  }
  return sb.toString();
}

List<String> _parseBiff8Sst(List<Uint8List> chunks) {
  if (chunks.isEmpty || chunks.first.length < 8) return const [];
  final firstBd = ByteData.sublistView(chunks.first);
  final uniqueCount = firstBd.getUint32(4, Endian.little);
  if (uniqueCount <= 0) return const [];

  var chunkIdx = 0;
  var pos = 8;

  bool ensureBytes(int n) {
    while (chunkIdx < chunks.length && pos >= chunks[chunkIdx].length) {
      chunkIdx++;
      pos = 0;
    }
    return chunkIdx < chunks.length && pos + n <= chunks[chunkIdx].length;
  }

  int readU8() {
    ensureBytes(1);
    return chunks[chunkIdx][pos++];
  }

  int readU16() {
    final lo = readU8();
    final hi = readU8();
    return lo | (hi << 8);
  }

  int readU32() {
    final b0 = readU8();
    final b1 = readU8();
    final b2 = readU8();
    final b3 = readU8();
    return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24);
  }

  void skipBytes(int count) {
    var rem = count;
    while (rem > 0 && chunkIdx < chunks.length) {
      final avail = chunks[chunkIdx].length - pos;
      if (avail <= 0) {
        chunkIdx++;
        pos = 0;
        continue;
      }
      final take = math.min(rem, avail);
      pos += take;
      rem -= take;
    }
  }

  final out = <String>[];
  for (var s = 0; s < uniqueCount; s++) {
    if (!ensureBytes(3)) break;
    final cch = readU16();
    final flags = readU8();
    var utf16 = (flags & 0x01) != 0;
    final hasExt = (flags & 0x04) != 0;
    final hasRich = (flags & 0x08) != 0;
    final richRuns = hasRich ? readU16() : 0;
    final extLen = hasExt ? readU32() : 0;

    final sb = StringBuffer();
    for (var i = 0; i < cch; i++) {
      if (chunkIdx < chunks.length && pos >= chunks[chunkIdx].length) {
        chunkIdx++;
        pos = 0;
        if (chunkIdx >= chunks.length || chunks[chunkIdx].isEmpty) break;
        // CONTINUE record starts with a 1-byte compression flag for split strings!
        final contFlag = chunks[chunkIdx][pos++];
        utf16 = (contFlag & 0x01) != 0;
      }
      if (utf16) {
        final lo = readU8();
        final hi = readU8();
        sb.writeCharCode(lo | (hi << 8));
      } else {
        sb.writeCharCode(readU8());
      }
    }
    if (richRuns > 0) skipBytes(richRuns * 4);
    if (extLen > 0) skipBytes(extLen);
    out.add(sb.toString());
  }
  return out;
}

const _gbkDeltaZlibB64 =
    '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';
