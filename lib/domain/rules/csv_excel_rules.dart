import 'dart:math' as math;
import 'dart:typed_data';

import '../../core/failure.dart';
import '../../core/money.dart';
import '../model/codes.dart';
import 'asset_overview.dart' show normalizeCurrency;
import 'csv_excel_codec.dart';

/// 15-column header for standard CSV export (with currency column, §2.2 / R8).
const List<String> csvExportHeader15 = [
  '日期',
  '类型',
  '账本',
  '一级分类',
  '二级分类',
  '金额',
  '币种',
  '账户',
  '账户2',
  '备注',
  '标签',
  '手续费',
  '优惠',
  '不计预算',
  '不计收支',
];

/// 14-column header for standard CSV export (without currency column, §2.2 / R8).
const List<String> csvExportHeader14 = [
  '日期',
  '类型',
  '账本',
  '一级分类',
  '二级分类',
  '金额',
  '账户',
  '账户2',
  '备注',
  '标签',
  '手续费',
  '优惠',
  '不计预算',
  '不计收支',
];

/// 13-column header for Official `模板 v3` (§2.2).
const List<String> officialTemplateV3Header = [
  '日期',
  '类型',
  '分类',
  '金额',
  '账户',
  '账户2',
  '备注',
  '账单图片',
  '标签',
  '手续费',
  '优惠',
  '不计预算',
  '不计收支',
];

/// Generates offline UTF-8+BOM `template3.csv` bytes for users (P-03).
Uint8List generateOfficialTemplateV3Bytes() => encodeCsvBytes(const [
  officialTemplateV3Header,
  [
    '2026-03-15 12:30',
    '支出',
    '餐饮',
    '35.00',
    '现金',
    '',
    '工作午餐',
    '',
    '日常,午餐',
    '',
    '2.00',
    '',
    '',
  ],
  [
    '2026-03-15 18:00',
    '收入',
    '工资',
    '8000.00',
    '储蓄卡',
    '',
    '月度薪资',
    '',
    '',
    '',
    '',
    '',
    '',
  ],
  [
    '2026-03-16 09:00',
    '转账',
    '',
    '1000.00',
    '储蓄卡',
    '现金',
    '提现备用',
    '',
    '',
    '1.50',
    '',
    '',
    '',
  ],
]);

// ---------------------------------------------------------------------------
// Date Format Locking (R3: 10 patterns, locked per sheet on first valid row)
// ---------------------------------------------------------------------------

enum ImportDatePattern {
  dashDateTimeSec('yyyy-MM-dd HH:mm:ss'),
  dashDateTimeMin('yyyy-MM-dd HH:mm'),
  dashDate('yyyy-MM-dd'),
  slashDateTimeSec('yyyy/MM/dd HH:mm:ss'),
  slashDateTimeMin('yyyy/MM/dd HH:mm'),
  slashDate('yyyy/MM/dd'),
  dotDateTimeSec('yyyy.MM.dd HH:mm:ss'),
  dotDateTimeMin('yyyy.MM.dd HH:mm'),
  dotDate('yyyy.MM.dd'),
  usDashDate('MM-dd-yyyy');

  const ImportDatePattern(this.pattern);
  final String pattern;
}

/// Locks a single [ImportDatePattern] per worksheet on the first valid date row
/// and validates subsequent rows strictly against that locked pattern (R3).
final class SheetDateParser {
  ImportDatePattern? _locked;

  ImportDatePattern? get lockedPattern => _locked;

  int? parseAndLock(String raw) => parseMs(raw);

  int? parseMs(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;

    if (_locked == null) {
      for (final candidate in ImportDatePattern.values) {
        final ms = _tryMatch(s, candidate, allowMinuteFallbackFromSec: false);
        if (ms != null) {
          _locked = candidate;
          return ms;
        }
      }
      return null;
    }

    // R3: If locked to a minute format (`HH:mm`), an input carrying `:ss` with
    // the same date separator normalizes to the locked minute precision (`:00`);
    // if locked to `:ss`, exact seconds are preserved; separator/type mismatches fail.
    return _tryMatch(s, _locked!, allowMinuteFallbackFromSec: true);
  }

  static int? _tryMatch(
    String s,
    ImportDatePattern fmt, {
    required bool allowMinuteFallbackFromSec,
  }) {
    switch (fmt) {
      case ImportDatePattern.dashDateTimeSec:
        return _parseYmdHms(s, '-', requireSec: true, keepSec: true);
      case ImportDatePattern.dashDateTimeMin:
        return _parseYmdHm(
          s,
          '-',
          allowOptionalSec: allowMinuteFallbackFromSec,
        );
      case ImportDatePattern.dashDate:
        return _parseYmdOnly(s, '-');
      case ImportDatePattern.slashDateTimeSec:
        return _parseYmdHms(s, '/', requireSec: true, keepSec: true);
      case ImportDatePattern.slashDateTimeMin:
        return _parseYmdHm(
          s,
          '/',
          allowOptionalSec: allowMinuteFallbackFromSec,
        );
      case ImportDatePattern.slashDate:
        return _parseYmdOnly(s, '/');
      case ImportDatePattern.dotDateTimeSec:
        return _parseYmdHms(s, '.', requireSec: true, keepSec: true);
      case ImportDatePattern.dotDateTimeMin:
        return _parseYmdHm(
          s,
          '.',
          allowOptionalSec: allowMinuteFallbackFromSec,
        );
      case ImportDatePattern.dotDate:
        return _parseYmdOnly(s, '.');
      case ImportDatePattern.usDashDate:
        return _parseMdyOnly(s);
    }
  }

  static int? _parseYmdHms(
    String s,
    String sep, {
    required bool requireSec,
    required bool keepSec,
  }) {
    final esc = RegExp.escape(sep);
    final re = RegExp(
      '^(\\d{4})$esc(\\d{1,2})$esc(\\d{1,2})\\s+(\\d{1,2}):(\\d{1,2}):(\\d{1,2})\$',
    );
    final m = re.firstMatch(s);
    if (m == null) {
      return requireSec ? null : _parseYmdHm(s, sep, allowOptionalSec: false);
    }
    return _buildLocalEpochMs(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
      int.parse(m.group(4)!),
      int.parse(m.group(5)!),
      keepSec ? int.parse(m.group(6)!) : 0,
    );
  }

  static int? _parseYmdHm(
    String s,
    String sep, {
    required bool allowOptionalSec,
  }) {
    final esc = RegExp.escape(sep);
    final re = allowOptionalSec
        ? RegExp(
            '^(\\d{4})$esc(\\d{1,2})$esc(\\d{1,2})\\s+(\\d{1,2}):(\\d{1,2})(?::(\\d{1,2}))?\$',
          )
        : RegExp(
            '^(\\d{4})$esc(\\d{1,2})$esc(\\d{1,2})\\s+(\\d{1,2}):(\\d{1,2})\$',
          );
    final m = re.firstMatch(s);
    if (m == null) return null;
    if (m.groupCount >= 6 && m.group(6) != null) {
      final sec = int.parse(m.group(6)!);
      if (sec < 0 || sec > 59) return null;
    }
    return _buildLocalEpochMs(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
      int.parse(m.group(4)!),
      int.parse(m.group(5)!),
      0,
    );
  }

  static int? _parseYmdOnly(String s, String sep) {
    final esc = RegExp.escape(sep);
    final m = RegExp('^(\\d{4})$esc(\\d{1,2})$esc(\\d{1,2})\$').firstMatch(s);
    if (m == null) return null;
    return _buildLocalEpochMs(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
      0,
      0,
      0,
    );
  }

  static int? _parseMdyOnly(String s) {
    final m = RegExp(r'^(\d{1,2})-(\d{1,2})-(\d{4})$').firstMatch(s);
    if (m == null) return null;
    return _buildLocalEpochMs(
      int.parse(m.group(3)!),
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      0,
      0,
      0,
    );
  }

  static int? _buildLocalEpochMs(
    int year,
    int month,
    int day,
    int hour,
    int minute,
    int second,
  ) {
    if (year < 1900 || year > 9999) return null;
    if (month < 1 || month > 12) return null;
    final maxDay = _daysInMonth(year, month);
    if (day < 1 || day > maxDay) return null;
    if (hour < 0 || hour > 23) return null;
    if (minute < 0 || minute > 59) return null;
    if (second < 0 || second > 59) return null;
    return DateTime(
      year,
      month,
      day,
      hour,
      minute,
      second,
    ).millisecondsSinceEpoch;
  }

  static int _daysInMonth(int year, int month) {
    if (month == 2) {
      final leap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0);
      return leap ? 29 : 28;
    }
    const thirty = {4, 6, 9, 11};
    return thirty.contains(month) ? 30 : 31;
  }
}

// ---------------------------------------------------------------------------
// Exact Decimal Amount Parser (R2: HALF_UP to minor units, ZERO double math!)
// ---------------------------------------------------------------------------

/// Strips `,`, `¥`, `￥`, `$`, `元`, `金额` and whitespace, then parses exact
/// decimal or scientific notation to `int64` minor units using `HALF_UP`.
BigInt? parseImportAmountMinor(String raw) {
  var cleaned = raw
      .replaceAll(',', '')
      .replaceAll('\u00A5', '') // ¥
      .replaceAll('\uFFE5', '') // ￥
      .replaceAll(r'$', '')
      .replaceAll('金额', '')
      .replaceAll('元', '')
      .replaceAll(RegExp(r'\s+'), '')
      .trim();
  if (cleaned.startsWith('+')) {
    cleaned = cleaned.substring(1);
  }
  if (cleaned.isEmpty) return null;

  final m = RegExp(
    r'^(-?)(\d+)(?:\.(\d+))?(?:[eE]([+-]?\d+))?$',
  ).firstMatch(cleaned);
  if (m == null) return null;

  final sign = m.group(1) == '-' ? -BigInt.one : BigInt.one;
  final intPart = m.group(2)!;
  final fracPart = m.group(3) ?? '';
  final expStr = m.group(4);
  final exp = expStr == null ? 0 : int.tryParse(expStr);
  if (exp == null || exp.abs() > 20) return null;

  final coeff = BigInt.parse('$intPart$fracPart') * sign;
  final effectiveScale = fracPart.length - exp;

  try {
    BigInt minor;
    if (effectiveScale <= Money.ledgerScale) {
      final shift = Money.ledgerScale - effectiveScale;
      if (shift > 30) return null;
      minor = coeff * powerOfTen(shift);
    } else {
      final drop = effectiveScale - Money.ledgerScale;
      final denom = drop <= 30 ? powerOfTen(drop) : BigInt.from(10).pow(drop);
      minor = divideRounded(coeff, denom, RoundingMode.halfUp);
    }
    return Money.minor(minor).storageMinor;
  } on Failure {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Platform Converters & Row Validation (R2..R4, §2.2, §6.2, §6.3)
// ---------------------------------------------------------------------------

final class ImportAccountRef {
  const ImportAccountRef({required this.id, required this.name, this.currency});

  final int id;
  final String name;
  final String? currency;
}

final class ValidImportRow {
  ValidImportRow({
    required this.sheetNo,
    required this.rowNo,
    required this.recordTime,
    required this.type,
    required this.moneyMinor,
    required this.parentCategoryName,
    this.subCategoryName = '',
    this.assetName = '',
    this.toAssetName = '',
    this.resolvedAssetId = noRef,
    this.resolvedFromAssetId = noRef,
    this.resolvedToAssetId = noRef,
    this.bookName = '',
    this.currencyCode,
    this.remark = '',
    this.tags = const [],
    this.images = const [],
    BigInt? feeMinor,
    this.discountMinor,
    this.excludeBudget = false,
    this.excludeExIn = false,
  }) : feeMinor = feeMinor ?? BigInt.zero;

  final int sheetNo;
  final int rowNo;
  final int recordTime;
  final int type;
  final BigInt moneyMinor;
  final String parentCategoryName;
  final String subCategoryName;
  final String assetName;
  final String toAssetName;
  final int resolvedAssetId;
  final int resolvedFromAssetId;
  final int resolvedToAssetId;

  int get assetId => resolvedAssetId;
  int get fromAssetId => resolvedFromAssetId;
  int get toAssetId => resolvedToAssetId;
  final String bookName;
  final String? currencyCode;
  final String remark;
  final List<String> tags;
  final List<String> images;
  final BigInt feeMinor;
  final BigInt? discountMinor;
  final bool excludeBudget;
  final bool excludeExIn;
}

final class ImportFailItem {
  const ImportFailItem({
    required this.sheetNo,
    required this.rowNo,
    required this.reason,
    required this.rawRow,
  });

  final int sheetNo;
  final int rowNo;
  final String reason;
  final String rawRow;
}

final class SpreadsheetImportAnalysis {
  const SpreadsheetImportAnalysis({
    required this.platformName,
    required this.hasBookColumn,
    required this.hasCurrencyColumn,
    required this.validRows,
    required this.failRows,
    required this.emptyRowCount,
    required this.unknownAssets,
    required this.lockedDateFormats,
    this.textEncoding,
  });

  final String platformName;
  final bool hasBookColumn;
  final bool hasCurrencyColumn;
  final List<ValidImportRow> validRows;
  final List<ImportFailItem> failRows;
  final int emptyRowCount;
  final List<String> unknownAssets;
  final Map<int, String> lockedDateFormats;
  final CsvTextEncoding? textEncoding;

  /// `import_record_count` stored in `import_platform`: valid + bad rows, excluding empty rows (§2.1).
  int get totalRecordCount => validRows.length + failRows.length;
}

final class _ResolvedSheetBinding {
  const _ResolvedSheetBinding({
    required this.platformName,
    required this.headerRowIndex,
    required this.supportedTypes,
    required this.fallbackCategory,
    required this.dateCols,
    required this.typeCol,
    required this.cat1Col,
    this.cat2Col,
    required this.moneyCol,
    this.assetCol,
    this.toAssetCol,
    required this.remarkCols,
    this.bookCol,
    this.currencyCol,
    this.imageCol,
    this.tagCol,
    this.feeCol,
    this.discountCol,
    this.excludeBudgetCol,
    this.excludeExInCol,
    this.slashIsEmpty = false,
  });

  final String platformName;
  final int headerRowIndex;
  final List<String> supportedTypes;
  final String fallbackCategory;
  final List<int> dateCols;
  final int typeCol;
  final int cat1Col;
  final int? cat2Col;
  final int moneyCol;
  final int? assetCol;
  final int? toAssetCol;
  final List<int> remarkCols;
  final int? bookCol;
  final int? currencyCol;
  final int? imageCol;
  final int? tagCol;
  final int? feeCol;
  final int? discountCol;
  final int? excludeBudgetCol;
  final int? excludeExInCol;
  final bool slashIsEmpty;

  bool get hasBookColumn => bookCol != null;
  bool get hasCurrencyColumn => currencyCol != null;
}

/// Analyzes decoded spreadsheet sheets against built-in platform converters and
/// validates rows against [existingAccounts].
SpreadsheetImportAnalysis analyzeSpreadsheetImport({
  required DecodedSpreadsheet spreadsheet,
  required Iterable<ImportAccountRef> existingAccounts,
}) {
  final accountsByName = <String, ImportAccountRef>{};
  for (final a in existingAccounts) {
    final trimmed = a.name.trim();
    if (trimmed.isNotEmpty) {
      accountsByName.putIfAbsent(trimmed, () => a);
    }
  }

  _ResolvedSheetBinding? primaryBinding;
  final validRows = <ValidImportRow>[];
  final failRows = <ImportFailItem>[];
  final unknownAssetsSet = <String>{};
  final lockedFormats = <int, String>{};
  var emptyRowCount = 0;

  for (final sheet in spreadsheet.sheets) {
    if (_isSheetCompletelyEmpty(sheet.rows)) continue;

    final binding = _matchSheetConverter(sheet.rows);
    if (binding == null) {
      if (primaryBinding == null) continue;
      // Non-empty secondary sheet that doesn't match a known converter is skipped
      // if primary sheet already matched (e.g. Excel instructions/summary sheet).
      continue;
    }
    primaryBinding ??= binding;

    final dateParser = SheetDateParser();
    for (
      var rIdx = binding.headerRowIndex + 1;
      rIdx < sheet.rows.length;
      rIdx++
    ) {
      final row = sheet.rows[rIdx];
      final rowNo = rIdx + 1; // 1-based row number within worksheet

      if (_isRowAllEmpty(row)) {
        emptyRowCount++;
        continue;
      }

      String cell(int? col) {
        if (col == null || col < 0 || col >= row.length) return '';
        final v = row[col].trim();
        if (binding.slashIsEmpty && v == '/') return '';
        return v;
      }

      final rawCsv = row.join(',');

      // 1. Bill type check
      final rawType = cell(binding.typeCol);
      if (!binding.supportedTypes.contains(rawType)) {
        failRows.add(
          ImportFailItem(
            sheetNo: sheet.sheetNo,
            rowNo: rowNo,
            reason:
                '不支持的账单类型：$rawType，仅支持「${binding.supportedTypes.join('、')}」',
            rawRow: rawCsv,
          ),
        );
        continue;
      }
      final recordType = switch (rawType) {
        '支出' => RecordType.expense,
        '收入' => RecordType.income,
        '转账' || '还款' => RecordType.transfer,
        _ => noRef,
      };

      // 2. Date check (locks on first valid row of this sheet)
      var rawDate = '';
      for (final dc in binding.dateCols) {
        final candidate = cell(dc);
        if (candidate.isNotEmpty) {
          rawDate = candidate;
          break;
        }
      }
      final recordTimeMs = dateParser.parseMs(rawDate);
      if (recordTimeMs == null) {
        failRows.add(
          ImportFailItem(
            sheetNo: sheet.sheetNo,
            rowNo: rowNo,
            reason: '无法识别的日期：${rawDate.isEmpty ? 'null' : rawDate}',
            rawRow: rawCsv,
          ),
        );
        continue;
      }
      if (dateParser.lockedPattern != null) {
        lockedFormats[sheet.sheetNo] = dateParser.lockedPattern!.pattern;
      }

      // 3. Amount check
      final rawMoney = cell(binding.moneyCol);
      final moneyMinor = parseImportAmountMinor(rawMoney);
      if (moneyMinor == null ||
          moneyMinor.isNegative ||
          (recordType == RecordType.transfer && moneyMinor <= BigInt.zero)) {
        failRows.add(
          ImportFailItem(
            sheetNo: sheet.sheetNo,
            rowNo: rowNo,
            reason: '无法识别的账单金额',
            rawRow: rawCsv,
          ),
        );
        continue;
      }

      // 4. Category check (non-transfer requires category or converter fallback; 16-char cap)
      var cat1 = cell(binding.cat1Col);
      var cat2 = cell(binding.cat2Col);
      if (recordType != RecordType.transfer) {
        if (cat1.isEmpty && cat2.isNotEmpty) {
          cat1 = cat2;
          cat2 = '';
        }
        if (cat1.isEmpty) {
          cat1 = binding.fallbackCategory;
        }
        if (cat1.isEmpty) {
          failRows.add(
            ImportFailItem(
              sheetNo: sheet.sheetNo,
              rowNo: rowNo,
              reason: '无法识别的分类名称：',
              rawRow: rawCsv,
            ),
          );
          continue;
        }
        cat1 = truncateRunes(cat1, 16);
        cat2 = truncateRunes(cat2, 16);
      } else {
        cat1 = '';
        cat2 = '';
      }

      // 5. Account / Transfer check (R4)
      final asset1Name = cell(binding.assetCol);
      final asset2Name = cell(binding.toAssetCol);
      var resolvedAssetId = noRef;
      var resolvedFromId = noRef;
      var resolvedToId = noRef;

      if (recordType == RecordType.transfer) {
        if (asset1Name.isNotEmpty && asset1Name == asset2Name) {
          failRows.add(
            ImportFailItem(
              sheetNo: sheet.sheetNo,
              rowNo: rowNo,
              reason: '转账转出与转入账户不能相同：「$asset1Name」',
              rawRow: rawCsv,
            ),
          );
          continue;
        }
        final fromAcc = asset1Name.isEmpty ? null : accountsByName[asset1Name];
        final toAcc = asset2Name.isEmpty ? null : accountsByName[asset2Name];
        if (fromAcc == null || toAcc == null) {
          failRows.add(
            ImportFailItem(
              sheetNo: sheet.sheetNo,
              rowNo: rowNo,
              reason:
                  '转账账单账户不完整，建议导入前先在App内创建账户「$asset1Name, $asset2Name」即可识别此转账',
              rawRow: rawCsv,
            ),
          );
          continue;
        }
        resolvedFromId = fromAcc.id;
        resolvedToId = toAcc.id;
      } else if (asset1Name.isNotEmpty) {
        final matched = accountsByName[asset1Name];
        if (matched != null) {
          resolvedAssetId = matched.id;
        } else {
          unknownAssetsSet.add(asset1Name);
          resolvedAssetId = noRef;
        }
      }

      // 6. Optional discount & fee validation (`模板 v3` / 14-col / 15-col)
      BigInt? discountMinor;
      final rawDiscount = cell(binding.discountCol);
      if (rawDiscount.isNotEmpty) {
        final parsedDiscount = parseImportAmountMinor(rawDiscount);
        if (parsedDiscount == null) {
          failRows.add(
            ImportFailItem(
              sheetNo: sheet.sheetNo,
              rowNo: rowNo,
              reason: '无法识别的优惠金额',
              rawRow: rawCsv,
            ),
          );
          continue;
        }
        if (parsedDiscount.isNegative) {
          failRows.add(
            ImportFailItem(
              sheetNo: sheet.sheetNo,
              rowNo: rowNo,
              reason: '支出账单优惠不合法，优惠金额不能小于0',
              rawRow: rawCsv,
            ),
          );
          continue;
        }
        if (recordType == RecordType.expense && parsedDiscount > BigInt.zero) {
          discountMinor = parsedDiscount;
        }
      }

      var feeMinor = BigInt.zero;
      final rawFee = cell(binding.feeCol);
      if (rawFee.isNotEmpty) {
        final parsedFee = parseImportAmountMinor(rawFee);
        if (parsedFee == null) {
          failRows.add(
            ImportFailItem(
              sheetNo: sheet.sheetNo,
              rowNo: rowNo,
              reason: '无法识别的手续费金额',
              rawRow: rawCsv,
            ),
          );
          continue;
        }
        if (parsedFee.isNegative) {
          failRows.add(
            ImportFailItem(
              sheetNo: sheet.sheetNo,
              rowNo: rowNo,
              reason: '转账手续费不能小于0',
              rawRow: rawCsv,
            ),
          );
          continue;
        }
        if (recordType == RecordType.transfer && parsedFee > BigInt.zero) {
          feeMinor = parsedFee;
        }
      }

      // 7. Remark (200-char cap), Tags (strip '#', max 8), Images (max 3), Booleans
      final remarkParts = <String>[];
      for (final rc in binding.remarkCols) {
        final part = cell(rc);
        if (part.isNotEmpty) remarkParts.add(part);
      }
      final remark = truncateRunes(remarkParts.join(' - '), 200);

      final tags = _parseImportTags(cell(binding.tagCol));
      final images = _parseImportImages(cell(binding.imageCol));
      final excludeBudget = _parseImportBool(cell(binding.excludeBudgetCol));
      final excludeExIn = _parseImportBool(cell(binding.excludeExInCol));
      final bookName = truncateRunes(cell(binding.bookCol), 30);
      final currencyCode = normalizeCurrency(cell(binding.currencyCol));

      validRows.add(
        ValidImportRow(
          sheetNo: sheet.sheetNo,
          rowNo: rowNo,
          recordTime: recordTimeMs,
          type: recordType,
          moneyMinor: moneyMinor,
          parentCategoryName: cat1,
          subCategoryName: cat2,
          assetName: asset1Name,
          toAssetName: asset2Name,
          resolvedAssetId: resolvedAssetId,
          resolvedFromAssetId: resolvedFromId,
          resolvedToAssetId: resolvedToId,
          bookName: bookName,
          currencyCode: currencyCode,
          remark: remark,
          tags: tags,
          images: images,
          feeMinor: feeMinor,
          discountMinor: discountMinor,
          excludeBudget: excludeBudget,
          excludeExIn: excludeExIn,
        ),
      );
    }
  }

  if (primaryBinding == null) {
    throw const Failure(
      FailureCode.validation,
      '不支持的平台或表头格式，请使用官方模板（v1~v3）、本应用导出 CSV、微信或支付宝账单',
    );
  }

  return SpreadsheetImportAnalysis(
    platformName: primaryBinding.platformName,
    hasBookColumn: primaryBinding.hasBookColumn,
    hasCurrencyColumn: primaryBinding.hasCurrencyColumn,
    validRows: validRows,
    failRows: failRows,
    emptyRowCount: emptyRowCount,
    unknownAssets: unknownAssetsSet.toList(growable: false),
    lockedDateFormats: lockedFormats,
    textEncoding: spreadsheet.textEncoding,
  );
}

bool _isRowAllEmpty(List<String> row) {
  for (final c in row) {
    if (c.trim().isNotEmpty) return false;
  }
  return true;
}

bool _isSheetCompletelyEmpty(List<List<String>> rows) {
  for (final r in rows) {
    if (!_isRowAllEmpty(r)) return false;
  }
  return true;
}

List<String> _trimmedNonTrailingEmpty(List<String> row) {
  var end = row.length;
  while (end > 0 && row[end - 1].trim().isEmpty) {
    end--;
  }
  return [for (var i = 0; i < end; i++) row[i].trim()];
}

_ResolvedSheetBinding? _matchSheetConverter(List<List<String>> rows) {
  if (rows.isEmpty) return null;

  // Scan row 0 (or first non-empty row if leading blank row) for Official Templates & 14/15-col CSV.
  var firstNonEmptyIdx = -1;
  for (var i = 0; i < rows.length; i++) {
    if (!_isRowAllEmpty(rows[i])) {
      firstNonEmptyIdx = i;
      break;
    }
  }
  if (firstNonEmptyIdx < 0) return null;

  final topCols = _trimmedNonTrailingEmpty(rows[firstNonEmptyIdx]);
  final topJoined = topCols.join(',');

  // 15-col Standard CSV
  if (_startsWithColumns(topCols, csvExportHeader15)) {
    return _ResolvedSheetBinding(
      platformName: '标准账单 v2',
      headerRowIndex: firstNonEmptyIdx,
      supportedTypes: const ['收入', '支出', '转账', '还款'],
      fallbackCategory: '',
      dateCols: const [0],
      typeCol: 1,
      bookCol: 2,
      cat1Col: 3,
      cat2Col: 4,
      moneyCol: 5,
      currencyCol: 6,
      assetCol: 7,
      toAssetCol: 8,
      remarkCols: const [9],
      tagCol: 10,
      feeCol: 11,
      discountCol: 12,
      excludeBudgetCol: 13,
      excludeExInCol: 14,
    );
  }

  // 14-col Standard CSV (without currency column)
  if (_startsWithColumns(topCols, csvExportHeader14)) {
    return _ResolvedSheetBinding(
      platformName: '标准账单 v2（无币种列）',
      headerRowIndex: firstNonEmptyIdx,
      supportedTypes: const ['收入', '支出', '转账', '还款'],
      fallbackCategory: '',
      dateCols: const [0],
      typeCol: 1,
      bookCol: 2,
      cat1Col: 3,
      cat2Col: 4,
      moneyCol: 5,
      assetCol: 6,
      toAssetCol: 7,
      remarkCols: const [8],
      tagCol: 9,
      feeCol: 10,
      discountCol: 11,
      excludeBudgetCol: 12,
      excludeExInCol: 13,
    );
  }

  // Official Template v3 (13 cols) — checked before v2 & v1 since prefix overlaps!
  if (_startsWithColumns(topCols, officialTemplateV3Header)) {
    return _ResolvedSheetBinding(
      platformName: '模板 v3',
      headerRowIndex: firstNonEmptyIdx,
      supportedTypes: const ['收入', '支出', '转账', '还款'],
      fallbackCategory: '',
      dateCols: const [0],
      typeCol: 1,
      cat1Col: 2,
      moneyCol: 3,
      assetCol: 4,
      toAssetCol: 5,
      remarkCols: const [6],
      imageCol: 7,
      tagCol: 8,
      feeCol: 9,
      discountCol: 10,
      excludeBudgetCol: 11,
      excludeExInCol: 12,
    );
  }

  // Official Template v2 (8 cols)
  const tplV2 = ['日期', '类型', '分类', '金额', '账户', '账户2', '备注', '账单图片'];
  if (_startsWithColumns(topCols, tplV2)) {
    return _ResolvedSheetBinding(
      platformName: '模板 v2',
      headerRowIndex: firstNonEmptyIdx,
      supportedTypes: const ['收入', '支出', '转账', '还款'],
      fallbackCategory: '',
      dateCols: const [0],
      typeCol: 1,
      cat1Col: 2,
      moneyCol: 3,
      assetCol: 4,
      toAssetCol: 5,
      remarkCols: const [6],
      imageCol: 7,
    );
  }

  // Official Template v1 (7 cols) — note: does NOT support 消费 or 还款 (`02zp` §3.2)
  const tplV1 = ['日期', '类型', '分类', '金额', '账户', '账户2', '备注'];
  if (_startsWithColumns(topCols, tplV1) ||
      topJoined.startsWith('日期,类型,分类,金额,账户,账户2,备注')) {
    return _ResolvedSheetBinding(
      platformName: '模板 v1',
      headerRowIndex: firstNonEmptyIdx,
      supportedTypes: const ['收入', '支出', '转账'],
      fallbackCategory: '',
      dateCols: const [0],
      typeCol: 1,
      cat1Col: 2,
      moneyCol: 3,
      assetCol: 4,
      toAssetCol: 5,
      remarkCols: const [6],
    );
  }

  // Scan rows 0..35 for WeChat (`微信支付账单明细`) and Alipay (`支付宝交易明细` Mobile / PC).
  final maxHeaderScan = math.min(rows.length, 36);
  var preambleText = '';
  for (var r = 0; r < maxHeaderScan; r++) {
    final cols = _trimmedNonTrailingEmpty(rows[r]);
    if (cols.isEmpty) continue;

    // WeChat (`微信账单`): `交易时间,交易类型,交易对方,商品,收/支,金额(元),支付方式,...`
    final wxBinding = _tryMatchWeChatHeader(cols, r, preambleText);
    if (wxBinding != null) return wxBinding;

    // Alipay (`支付宝账单`): Mobile v1/v2 & PC
    final aliBinding = _tryMatchAlipayHeader(cols, r, preambleText);
    if (aliBinding != null) return aliBinding;

    preambleText = '$preambleText\n${cols.join(',')}';
  }

  return null;
}

bool _startsWithColumns(List<String> actual, List<String> expected) {
  if (actual.length < expected.length) return false;
  for (var i = 0; i < expected.length; i++) {
    if (actual[i] != expected[i]) return false;
  }
  return true;
}

_ResolvedSheetBinding? _tryMatchWeChatHeader(
  List<String> cols,
  int headerIdx,
  String preamble,
) {
  final idxTime = cols.indexOf('交易时间');
  final idxCat = cols.indexOf('交易类型');
  final idxPeer = cols.indexOf('交易对方');
  final idxGoods = cols.indexOf('商品');
  final idxDir = cols.indexOf('收/支');
  final idxMoney = _indexOfAny(cols, const ['金额(元)', '金额（元）', '金额']);
  if (idxTime >= 0 &&
      idxCat >= 0 &&
      idxPeer >= 0 &&
      idxGoods >= 0 &&
      idxDir >= 0 &&
      idxMoney >= 0) {
    final idxPay = _indexOfAny(cols, const ['支付方式', '收/付款方式']);
    final idxRemark = cols.indexOf('备注');
    return _ResolvedSheetBinding(
      platformName: '微信账单',
      headerRowIndex: headerIdx,
      supportedTypes: const ['收入', '支出', '转账'],
      fallbackCategory: '导入账单',
      dateCols: [idxTime],
      typeCol: idxDir,
      cat1Col: idxCat,
      moneyCol: idxMoney,
      assetCol: idxPay >= 0 ? idxPay : null,
      remarkCols: [idxPeer, idxGoods, if (idxRemark >= 0) idxRemark],
      slashIsEmpty: true,
    );
  }
  return null;
}

_ResolvedSheetBinding? _tryMatchAlipayHeader(
  List<String> cols,
  int headerIdx,
  String preamble,
) {
  final idxDir = cols.indexOf('收/支');
  final idxMoney = _indexOfAny(cols, const ['金额', '金额（元）', '金额(元)']);
  if (idxDir < 0 || idxMoney < 0) return null;

  // Alipay Mobile v1/v2 (`交易时间`, `交易分类`, `商品说明`, `收/付款方式`)
  final idxTime = cols.indexOf('交易时间');
  final idxCat = cols.indexOf('交易分类');
  final idxGoodsDesc = _indexOfAny(cols, const ['商品说明', '商品名称']);
  if (idxTime >= 0 &&
      (idxCat >= 0 || (preamble.contains('支付宝') && idxGoodsDesc >= 0))) {
    final idxPeer = cols.indexOf('交易对方');
    final idxPay = _indexOfAny(cols, const ['收/付款方式', '支付方式']);
    final idxRemark = cols.indexOf('备注');
    return _ResolvedSheetBinding(
      platformName: '支付宝账单',
      headerRowIndex: headerIdx,
      supportedTypes: const ['收入', '支出', '转账'],
      fallbackCategory: '导入账单',
      dateCols: [idxTime],
      typeCol: idxDir,
      cat1Col: idxCat >= 0 ? idxCat : idxGoodsDesc,
      moneyCol: idxMoney,
      assetCol: idxPay >= 0 ? idxPay : null,
      remarkCols: [
        if (idxPeer >= 0) idxPeer,
        if (idxGoodsDesc >= 0) idxGoodsDesc,
        if (idxRemark >= 0) idxRemark,
      ],
      slashIsEmpty: true,
    );
  }

  // Alipay PC (`交易创建时间`, `付款时间`, `类型`, `交易对方`, `商品名称`, `金额（元）`, `收/支`)
  final idxCreateTime = cols.indexOf('交易创建时间');
  final idxPayTime = cols.indexOf('付款时间');
  final idxPcType = cols.indexOf('类型');
  if (idxCreateTime >= 0 && idxPcType >= 0 && idxGoodsDesc >= 0) {
    final idxPeer = cols.indexOf('交易对方');
    final idxRemark = cols.indexOf('备注');
    return _ResolvedSheetBinding(
      platformName: '支付宝账单',
      headerRowIndex: headerIdx,
      supportedTypes: const ['收入', '支出', '转账'],
      fallbackCategory: '导入账单',
      dateCols: [idxCreateTime, if (idxPayTime >= 0) idxPayTime],
      typeCol: idxDir,
      cat1Col: idxPcType,
      moneyCol: idxMoney,
      remarkCols: [
        if (idxPeer >= 0) idxPeer,
        idxGoodsDesc,
        if (idxRemark >= 0) idxRemark,
      ],
      slashIsEmpty: true,
    );
  }

  return null;
}

int _indexOfAny(List<String> cols, List<String> candidates) {
  for (final c in candidates) {
    final idx = cols.indexOf(c);
    if (idx >= 0) return idx;
  }
  return -1;
}

List<String> _parseImportTags(String raw) {
  if (raw.isEmpty) return const [];
  final result = <String>[];
  final seen = <String>{};
  for (final part in raw.split(',')) {
    var t = part.trim();
    while (t.startsWith('#')) {
      t = t.substring(1).trim();
    }
    if (t.isEmpty) continue;
    t = truncateRunes(t, 20);
    if (seen.add(t)) {
      result.add(t);
      if (result.length >= 8) break;
    }
  }
  return result;
}

List<String> _parseImportImages(String raw) {
  if (raw.isEmpty) return const [];
  final result = <String>[];
  for (final part in raw.split(',')) {
    final p = part.trim();
    if (p.isEmpty) continue;
    result.add(p);
    if (result.length >= 3) break;
  }
  return result;
}

/// Truncates [text] to at most [maxRunes] Unicode scalar values without splitting surrogates.
String truncateRunes(String text, int maxRunes) {
  if (maxRunes <= 0 || text.isEmpty) return '';
  if (text.length <= maxRunes) return text;
  final runes = text.runes;
  if (runes.length <= maxRunes) return text;
  return String.fromCharCodes(runes.take(maxRunes));
}

// ---------------------------------------------------------------------------
// RFC 4180 CSV Export Row Builder (R8 / DR-IMP-08)
// ---------------------------------------------------------------------------

final class CsvExportRowInput {
  CsvExportRowInput({
    required this.recordTimeMs,
    required this.type,
    required this.bookName,
    required this.moneyMinor,
    this.parentCategoryName = '',
    this.subCategoryName = '',
    this.currencyCode = 'CNY',
    this.accountName = '',
    this.targetAccountName = '',
    this.remark = '',
    this.tags = const [],
    BigInt? feeMinor,
    this.discountMinor,
    this.excludeBudget = false,
    this.excludeExIn = false,
  }) : feeMinor = feeMinor ?? BigInt.zero;

  final int recordTimeMs;
  final int type;
  final String bookName;
  final BigInt moneyMinor;
  final String parentCategoryName;
  final String subCategoryName;
  final String currencyCode;
  final String accountName;
  final String targetAccountName;
  final String remark;
  final List<String> tags;
  final BigInt feeMinor;
  final BigInt? discountMinor;
  final bool excludeBudget;
  final bool excludeExIn;
}

bool _parseImportBool(String raw) {
  final s = raw.trim().toLowerCase();
  return s == '1' || s == '是' || s == 'true' || s == 'yes' || s == 'y';
}

/// Formats epoch ms in local time as `yyyy-MM-dd HH:mm:ss` so every exported
/// row shares a uniform second-precision pattern for lossless round-trip import.
String formatExportTimestamp(int epochMs) {
  final dt = DateTime.fromMillisecondsSinceEpoch(epochMs);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
      '${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
}

/// Builds RFC 4180 table rows (including header) for 15-col or 14-col CSV export.
List<List<String>> buildCsvExportRows(
  Iterable<CsvExportRowInput> items, {
  bool includeCurrency = true,
}) {
  final rows = <List<String>>[
    includeCurrency ? csvExportHeader15 : csvExportHeader14,
  ];
  for (final item in items) {
    final typeLabel = switch (item.type) {
      RecordType.expense => '支出',
      RecordType.income => '收入',
      RecordType.transfer => '转账',
      _ => RecordType.names[item.type] ?? '支出',
    };
    final moneyStr = Money.minor(item.moneyMinor).decimal;
    final feeStr =
        item.type == RecordType.transfer && item.feeMinor > BigInt.zero
        ? Money.minor(item.feeMinor).decimal
        : '';
    final discountStr =
        item.discountMinor != null && item.discountMinor! > BigInt.zero
        ? Money.minor(item.discountMinor!).decimal
        : '';
    final tagsStr = item.tags.join(',');
    final curr = normalizeCurrency(item.currencyCode) ?? 'CNY';

    rows.add([
      formatExportTimestamp(item.recordTimeMs),
      typeLabel,
      item.bookName,
      item.type == RecordType.transfer ? '' : item.parentCategoryName,
      item.type == RecordType.transfer ? '' : item.subCategoryName,
      moneyStr,
      if (includeCurrency) curr,
      item.accountName,
      item.type == RecordType.transfer ? item.targetAccountName : '',
      item.remark,
      tagsStr,
      feeStr,
      discountStr,
      item.excludeBudget ? '1' : '',
      item.excludeExIn ? '1' : '',
    ]);
  }
  return rows;
}
