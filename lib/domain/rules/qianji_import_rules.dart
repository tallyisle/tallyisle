import 'dart:typed_data';

import '../../core/failure.dart';
import '../model/codes.dart';
import 'csv_excel_codec.dart';
import 'csv_excel_rules.dart';

/// Canonical 19-column header exported by 钱迹 (`qianji-4.5.5.apk` `Bill.getCsvTitle`).
const List<String> qianjiHeader19 = [
  'ID',
  '时间',
  '账本',
  '分类',
  '二级分类',
  '类型',
  '金额',
  '币种',
  '账户1',
  '账户2',
  '备注',
  '已报销',
  '手续费',
  '优惠券',
  '记账者',
  '账单标记',
  '标签',
  '账单图片',
  '关联账单',
];

const String qianjiPlatformName = '钱迹';

final class QianjiHeaderBinding {
  const QianjiHeaderBinding({
    required this.headerRowIndex,
    this.idCol,
    required this.timeCol,
    this.bookCol,
    required this.cat1Col,
    this.cat2Col,
    required this.typeCol,
    required this.moneyCol,
    this.currencyCol,
    this.account1Col,
    this.account2Col,
    this.remarkCol,
    this.reimbursedCol,
    this.feeCol,
    this.couponCol,
    this.authorCol,
    this.flagCol,
    this.tagCol,
    this.imageCol,
    this.sourceIdCol,
  });

  final int headerRowIndex;
  final int? idCol;
  final int timeCol;
  final int? bookCol;
  final int cat1Col;
  final int? cat2Col;
  final int typeCol;
  final int moneyCol;
  final int? currencyCol;
  final int? account1Col;
  final int? account2Col;
  final int? remarkCol;
  final int? reimbursedCol;
  final int? feeCol;
  final int? couponCol;
  final int? authorCol;
  final int? flagCol;
  final int? tagCol;
  final int? imageCol;
  final int? sourceIdCol;

  bool get hasBookColumn => bookCol != null;
  bool get hasCurrencyColumn => currencyCol != null;
}

/// Attempts to match a 钱迹 CSV/XLSX header (19-col v4.5.5 or legacy v1–v6).
QianjiHeaderBinding? tryMatchQianjiSheetHeader(List<List<String>> rows) {
  final limit = rows.length < 8 ? rows.length : 8;
  for (var r = 0; r < limit; r++) {
    final cols = [for (final c in rows[r]) c.trim()];
    if (cols.every((c) => c.isEmpty)) continue;

    final timeCol = _indexOfAnyCol(cols, const ['时间', 'Time']);
    final cat1Col = _indexOfAnyCol(cols, const ['分类', 'Category']);
    final typeCol = _indexOfAnyCol(cols, const ['类型', 'Type']);
    final moneyCol = _indexOfAnyCol(cols, const ['金额', 'Amount']);
    if (timeCol < 0 || cat1Col < 0 || typeCol < 0 || moneyCol < 0) {
      continue;
    }

    final idCol = _indexOfAnyCol(cols, const ['ID', 'id', '账单ID']);
    final acc1Col = _indexOfAnyCol(cols, const [
      '账户1',
      '资产',
      '账户',
      'Account 1',
      'Account1',
    ]);
    final acc2Col = _indexOfAnyCol(cols, const [
      '账户2',
      '目标账户',
      'Account 2',
      'Account2',
    ]);
    final reimbCol = _indexOfAnyCol(cols, const ['已报销', 'Reimbursed']);
    final couponCol = _indexOfAnyCol(cols, const ['优惠券', 'Coupon']);
    final flagCol = _indexOfAnyCol(cols, const ['账单标记', 'Flag', 'BillFlag']);

    // Require at least one Qianji-identifying column alongside `时间,分类,类型,金额`.
    final hasQianjiSignature =
        cols.contains('账户1') ||
        idCol >= 0 ||
        reimbCol >= 0 ||
        couponCol >= 0 ||
        flagCol >= 0 ||
        cols.contains('Time');
    if (!hasQianjiSignature) continue;

    return QianjiHeaderBinding(
      headerRowIndex: r,
      idCol: idCol >= 0 ? idCol : null,
      timeCol: timeCol,
      bookCol: _optCol(cols, const ['账本', 'Book']),
      cat1Col: cat1Col,
      cat2Col: _optCol(cols, const ['二级分类', '子分类', 'Subcategory']),
      typeCol: typeCol,
      moneyCol: moneyCol,
      currencyCol: _optCol(cols, const ['币种', 'Currency']),
      account1Col: acc1Col >= 0 ? acc1Col : null,
      account2Col: acc2Col >= 0 ? acc2Col : null,
      remarkCol: _optCol(cols, const ['备注', 'Remark', 'Note']),
      reimbursedCol: reimbCol >= 0 ? reimbCol : null,
      feeCol: _optCol(cols, const ['手续费', 'Fee']),
      couponCol: couponCol >= 0 ? couponCol : null,
      authorCol: _optCol(cols, const ['记账者', 'Author', 'User']),
      flagCol: flagCol >= 0 ? flagCol : null,
      tagCol: _optCol(cols, const ['标签', 'Tags', 'Tag']),
      imageCol: _optCol(cols, const ['账单图片', '图片', 'Images']),
      sourceIdCol: _optCol(cols, const ['关联账单', 'SourceId', '关联ID']),
    );
  }
  return null;
}

/// Parses and validates all matching 钱迹 sheets from [spreadsheet].
SpreadsheetImportAnalysis analyzeQianjiSpreadsheetImport({
  required DecodedSpreadsheet spreadsheet,
  required Iterable<ImportAccountRef> existingAccounts,
  Map<int, Map<int, List<Uint8List>>> xlsxEmbeddedImagesBySheet = const {},
  Uint8List? Function(String rawRef)? bundleImageResolver,
  bool? allowUnknownTransferAccounts,
}) {
  final allowUnknown = allowUnknownTransferAccounts ?? true;
  final accountLookup = ImportAccountLookup(existingAccounts);

  QianjiHeaderBinding? primaryBinding;
  final validRows = <ValidImportRow>[];
  final failRows = <ImportFailItem>[];
  final unknownAssetsSet = <String>{};
  final lockedFormats = <int, String>{};
  var emptyRowCount = 0;
  var mergedChildRowCount = 0;

  for (final sheet in spreadsheet.sheets) {
    if (sheet.rows.every((r) => r.every((c) => c.trim().isEmpty))) continue;
    final binding = tryMatchQianjiSheetHeader(sheet.rows);
    if (binding == null) continue;
    primaryBinding ??= binding;

    final sheetImages =
        xlsxEmbeddedImagesBySheet[sheet.sheetNo] ??
        const <int, List<Uint8List>>{};
    final rawEntries = <_QianjiRawEntry>[];
    String? firstPattern;

    for (
      var rIdx = binding.headerRowIndex + 1;
      rIdx < sheet.rows.length;
      rIdx++
    ) {
      final row = sheet.rows[rIdx];
      final rowNo = rIdx + 1;
      if (row.every((c) => c.trim().isEmpty)) {
        emptyRowCount++;
        continue;
      }

      String cell(int? col) =>
          (col == null || col < 0 || col >= row.length) ? '' : row[col].trim();

      final rawRowText = row.join(',');
      final rawTime = cell(binding.timeCol);
      final parsedDate = parseFlexibleImportDateTime(rawTime);
      if (parsedDate == null) {
        failRows.add(
          ImportFailItem(
            sheetNo: sheet.sheetNo,
            rowNo: rowNo,
            reason: '无法识别的日期：${rawTime.isEmpty ? 'null' : rawTime}',
            rawRow: rawRowText,
          ),
        );
        continue;
      }
      firstPattern ??= parsedDate.pattern;

      final embedded = <Uint8List>[...?sheetImages[rIdx]];
      final rawImageCell = cell(binding.imageCol);
      final imageResult = resolveImportCellImages(
        rawCell: rawImageCell,
        preExtracted: embedded,
        bundleResolver: bundleImageResolver,
      );

      rawEntries.add(
        _QianjiRawEntry(
          sheetNo: sheet.sheetNo,
          rowNo: rowNo,
          rawRowText: rawRowText,
          id: cell(binding.idCol),
          recordTimeMs: parsedDate.epochMs,
          bookName: cell(binding.bookCol),
          cat1: cell(binding.cat1Col),
          cat2: cell(binding.cat2Col),
          rawType: cell(binding.typeCol),
          rawMoney: cell(binding.moneyCol),
          rawCurrency: cell(binding.currencyCol),
          account1: cell(binding.account1Col),
          account2: cell(binding.account2Col),
          remark: cell(binding.remarkCol),
          hasBx: _isTruthyQianjiReimbursed(cell(binding.reimbursedCol)),
          rawFee: cell(binding.feeCol),
          rawCoupon: cell(binding.couponCol),
          billFlag: cell(binding.flagCol),
          tags: parseQianjiTags(cell(binding.tagCol)),
          imageNames: imageResult.fileNames,
          imageBytes: imageResult.imageBytes,
          sourceId: cell(binding.sourceIdCol),
          isJsonMode: false,
        ),
      );
    }

    if (firstPattern != null) {
      lockedFormats[sheet.sheetNo] = firstPattern;
    }

    final resolved = _resolveQianjiEntries(
      entries: rawEntries,
      accountLookup: accountLookup,
      allowUnknownAccounts: allowUnknown,
      unknownAssetsOut: unknownAssetsSet,
      failRowsOut: failRows,
    );
    validRows.addAll(resolved.validRows);
    mergedChildRowCount += resolved.mergedChildCount;
  }

  if (primaryBinding == null) {
    throw const Failure(FailureCode.validation, '未识别到有效的钱迹账单表头');
  }

  return SpreadsheetImportAnalysis(
    platformName: qianjiPlatformName,
    hasBookColumn: primaryBinding.hasBookColumn,
    hasCurrencyColumn: primaryBinding.hasCurrencyColumn,
    validRows: validRows,
    failRows: failRows,
    emptyRowCount: emptyRowCount,
    unknownAssets: unknownAssetsSet.toList(growable: false),
    lockedDateFormats: lockedFormats,
    textEncoding: spreadsheet.textEncoding,
    defaultAutoCreateAccounts: true,
    mergedChildRowCount: mergedChildRowCount,
  );
}

/// Parses and validates a 钱迹 JSON export (`Bill.toExportJson`) using an exact
/// decimal-preserving JSON parser (ZERO `double` math!).
SpreadsheetImportAnalysis analyzeQianjiJsonImport({
  required String jsonText,
  required Iterable<ImportAccountRef> existingAccounts,
  CsvTextEncoding? textEncoding,
  Uint8List? Function(String rawRef)? bundleImageResolver,
  bool? allowUnknownTransferAccounts,
}) {
  final root = _ExactJsonParser.parse(jsonText);
  final List<Object?> items;
  if (root is List<Object?>) {
    items = root;
  } else if (root is Map<String, Object?>) {
    final nested =
        root['bills'] ?? root['data'] ?? root['records'] ?? root['list'];
    if (nested is List<Object?>) {
      items = nested;
    } else {
      throw const Failure(FailureCode.validation, '钱迹 JSON 根结构须为账单数组');
    }
  } else {
    throw const Failure(FailureCode.validation, '钱迹 JSON 格式无效');
  }

  final allowUnknown = allowUnknownTransferAccounts ?? true;
  final accountLookup = ImportAccountLookup(existingAccounts);
  final rawEntries = <_QianjiRawEntry>[];
  final failRows = <ImportFailItem>[];
  final unknownAssetsSet = <String>{};
  var emptyRowCount = 0;
  var hasBookField = false;
  var hasCurrencyField = false;
  String? firstPattern;

  for (var i = 0; i < items.length; i++) {
    final rowNo = i + 1;
    final item = items[i];
    if (item == null) {
      emptyRowCount++;
      continue;
    }
    if (item is! Map<String, Object?>) {
      failRows.add(
        ImportFailItem(
          sheetNo: 1,
          rowNo: rowNo,
          reason: 'JSON 条目不是有效对象',
          rawRow: '$item',
        ),
      );
      continue;
    }
    if (item.isEmpty) {
      emptyRowCount++;
      continue;
    }

    // Verify at least one recognizable Qianji bill key exists on the first item.
    if (i == 0 &&
        !item.containsKey('money') &&
        !item.containsKey('type') &&
        !item.containsKey('date') &&
        !item.containsKey('timeInSec')) {
      throw const Failure(FailureCode.validation, '不支持的 JSON 账单格式（未识别到钱迹字段）');
    }

    final rawSummary = _summarizeJsonItem(item);
    final rawDateVal =
        item['date'] ?? item['time'] ?? item['timeInSec'] ?? item['createtime'];
    final parsedDate = _parseJsonDate(rawDateVal);
    if (parsedDate == null) {
      failRows.add(
        ImportFailItem(
          sheetNo: 1,
          rowNo: rowNo,
          reason:
              '无法识别的日期：${_asRawText(rawDateVal).isEmpty ? 'null' : _asRawText(rawDateVal)}',
          rawRow: rawSummary,
        ),
      );
      continue;
    }
    firstPattern ??= parsedDate.pattern;

    final bookName = _firstNonEmptyString([
      item['book'],
      item['bookname'],
      item['bookName'],
    ]);
    if (bookName.isNotEmpty) hasBookField = true;

    final rawCurrency = _firstNonEmptyString([
      item['currency'],
      item['currencyCode'],
    ]);
    if (rawCurrency.isNotEmpty) hasCurrencyField = true;

    final (cat1, cat2) = _extractJsonCategories(item);
    final rawType = _extractJsonTypeString(item['type']);
    final rawMoney = _asExactDecimalText(item['money']);
    final rawFee = _asExactDecimalText(item['fee']);
    final rawCoupon = _asExactDecimalText(item['coupon']);

    final assetStr = _resolveQianjiJsonAccount(item['asset'], null);
    final fromStr = _resolveQianjiJsonAccount(item['from'], item['fromact']);
    final targetStr = _resolveQianjiJsonAccount(
      item['target'],
      item['targetact'],
    );

    final tags = _extractJsonTags(
      item['tags'] ?? item['tag'] ?? item['tagList'],
    );
    final rawImageTokens = _extractJsonImages(item['images']);
    final imageResult = resolveImportCellImages(
      rawCell: rawImageTokens.join(','),
      preExtracted: const [],
      bundleResolver: bundleImageResolver,
    );

    final idStr = _firstNonEmptyString([
      _asRawText(item['key']),
      _asRawText(item['id']),
      _asRawText(item['billid']),
      _asRawText(item['_id']),
    ]);
    final sourceIdStr = _firstNonEmptyString([
      _asRawText(item['sourceid']),
      _asRawText(item['sourceId']),
    ]);

    rawEntries.add(
      _QianjiRawEntry(
        sheetNo: 1,
        rowNo: rowNo,
        rawRowText: rawSummary,
        id: idStr,
        recordTimeMs: parsedDate.epochMs,
        bookName: bookName,
        cat1: cat1,
        cat2: cat2,
        rawType: rawType,
        rawMoney: rawMoney,
        rawCurrency: rawCurrency,
        account1: fromStr.isNotEmpty ? fromStr : assetStr,
        account2: targetStr,
        jsonAsset: assetStr,
        jsonFrom: fromStr,
        jsonTarget: targetStr,
        remark: _asRawText(item['remark']),
        hasBx: _isTruthyJsonHasBx(item['hasbx']),
        rawFee: rawFee,
        rawCoupon: rawCoupon,
        billFlag: _asRawText(item['billflag']),
        tags: tags,
        imageNames: imageResult.fileNames,
        imageBytes: imageResult.imageBytes,
        sourceId: sourceIdStr,
        isJsonMode: true,
      ),
    );
  }

  final resolved = _resolveQianjiEntries(
    entries: rawEntries,
    accountLookup: accountLookup,
    allowUnknownAccounts: allowUnknown,
    unknownAssetsOut: unknownAssetsSet,
    failRowsOut: failRows,
  );

  return SpreadsheetImportAnalysis(
    platformName: qianjiPlatformName,
    hasBookColumn: hasBookField,
    hasCurrencyColumn: hasCurrencyField,
    validRows: resolved.validRows,
    failRows: failRows,
    emptyRowCount: emptyRowCount,
    unknownAssets: unknownAssetsSet.toList(growable: false),
    lockedDateFormats: {if (firstPattern != null) 1: firstPattern},
    textEncoding: textEncoding,
    defaultAutoCreateAccounts: true,
    mergedChildRowCount: resolved.mergedChildCount,
  );
}

// ---------------------------------------------------------------------------
// Internal Qianji Two-Pass Semantic Resolver
// ---------------------------------------------------------------------------

enum _QianjiKind {
  expense,
  income,
  transfer,
  reimbursable,
  reimburseReceipt,
  refund,
  debtBorrowIn,
  debtLendOut,
  debtRepay,
  debtCollect,
  debtInterestExpense,
  debtInterestIncome,
}

final class _QianjiRawEntry {
  const _QianjiRawEntry({
    required this.sheetNo,
    required this.rowNo,
    required this.rawRowText,
    required this.id,
    required this.recordTimeMs,
    required this.bookName,
    required this.cat1,
    required this.cat2,
    required this.rawType,
    required this.rawMoney,
    required this.rawCurrency,
    required this.account1,
    required this.account2,
    this.jsonAsset = '',
    this.jsonFrom = '',
    this.jsonTarget = '',
    required this.remark,
    required this.hasBx,
    required this.rawFee,
    required this.rawCoupon,
    required this.billFlag,
    required this.tags,
    required this.imageNames,
    required this.imageBytes,
    required this.sourceId,
    required this.isJsonMode,
  });

  final int sheetNo;
  final int rowNo;
  final String rawRowText;
  final String id;
  final int recordTimeMs;
  final String bookName;
  final String cat1;
  final String cat2;
  final String rawType;
  final String rawMoney;
  final String rawCurrency;
  final String account1;
  final String account2;
  final String jsonAsset;
  final String jsonFrom;
  final String jsonTarget;
  final String remark;
  final bool hasBx;
  final String rawFee;
  final String rawCoupon;
  final String billFlag;
  final List<String> tags;
  final List<String> imageNames;
  final List<Uint8List> imageBytes;
  final String sourceId;
  final bool isJsonMode;
}

final class _PreparedQianjiItem {
  _PreparedQianjiItem({
    required this.entry,
    required this.kind,
    required this.typeSuffixCategory,
    required this.amountMinor,
    required this.feeMinor,
    required this.discountMinor,
    required this.currencyCode,
    required this.excludeExIn,
    required this.excludeBudget,
    required this.normalizedId,
    required this.normalizedSourceId,
  });

  final _QianjiRawEntry entry;
  final _QianjiKind kind;
  final String typeSuffixCategory;
  final BigInt amountMinor;
  final BigInt feeMinor;
  final BigInt? discountMinor;
  final String? currencyCode;
  final bool excludeExIn;
  final bool excludeBudget;
  final String normalizedId;
  final String normalizedSourceId;

  final List<ImportReimburseChildSpec> reimburseChildren = [];
  final List<ImportRefundChildSpec> refundChildren = [];
  bool consumedAsChild = false;
}

({List<ValidImportRow> validRows, int mergedChildCount}) _resolveQianjiEntries({
  required List<_QianjiRawEntry> entries,
  required ImportAccountLookup accountLookup,
  required bool allowUnknownAccounts,
  required Set<String> unknownAssetsOut,
  required List<ImportFailItem> failRowsOut,
}) {
  final prepared = <_PreparedQianjiItem>[];
  final byId = <String, _PreparedQianjiItem>{};

  // Pass 1: Validate types, amounts, fees, coupons, flags, and index potential parents by ID.
  for (final e in entries) {
    final classified = _classifyQianjiType(e.rawType);
    if (classified == null) {
      failRowsOut.add(
        ImportFailItem(
          sheetNo: e.sheetNo,
          rowNo: e.rowNo,
          reason: '不支持的钱迹账单类型：${e.rawType}',
          rawRow: e.rawRowText,
        ),
      );
      continue;
    }
    final (kind, suffixCat) = classified;

    final parsedMoney = parseImportAmountMinor(e.rawMoney);
    if (parsedMoney == null) {
      failRowsOut.add(
        ImportFailItem(
          sheetNo: e.sheetNo,
          rowNo: e.rowNo,
          reason: '无法识别的账单金额',
          rawRow: e.rawRowText,
        ),
      );
      continue;
    }
    final magMinor = parsedMoney.abs();
    if ((kind == _QianjiKind.transfer ||
            kind == _QianjiKind.reimburseReceipt ||
            kind == _QianjiKind.refund ||
            _isDebtKind(kind)) &&
        magMinor <= BigInt.zero) {
      failRowsOut.add(
        ImportFailItem(
          sheetNo: e.sheetNo,
          rowNo: e.rowNo,
          reason: '无法识别的账单金额',
          rawRow: e.rawRowText,
        ),
      );
      continue;
    }

    var feeMinor = BigInt.zero;
    if (e.rawFee.isNotEmpty) {
      final parsedFee = parseImportAmountMinor(e.rawFee);
      if (parsedFee == null || parsedFee.isNegative) {
        failRowsOut.add(
          ImportFailItem(
            sheetNo: e.sheetNo,
            rowNo: e.rowNo,
            reason: parsedFee == null ? '无法识别的手续费金额' : '转账手续费不能小于0',
            rawRow: e.rawRowText,
          ),
        );
        continue;
      }
      if (kind == _QianjiKind.transfer && parsedFee > BigInt.zero) {
        feeMinor = parsedFee;
      }
    }

    BigInt? discountMinor;
    if (e.rawCoupon.isNotEmpty) {
      final parsedCoupon = parseImportAmountMinor(e.rawCoupon);
      if (parsedCoupon == null || parsedCoupon.isNegative) {
        failRowsOut.add(
          ImportFailItem(
            sheetNo: e.sheetNo,
            rowNo: e.rowNo,
            reason: parsedCoupon == null ? '无法识别的优惠金额' : '支出账单优惠不合法，优惠金额不能小于0',
            rawRow: e.rawRowText,
          ),
        );
        continue;
      }
      if ((kind == _QianjiKind.expense || kind == _QianjiKind.income) &&
          !parsedMoney.isNegative &&
          parsedCoupon > BigInt.zero) {
        discountMinor = parsedCoupon;
      }
    }

    final (exclExIn, exclBudget) = parseQianjiBillFlags(e.billFlag);
    final currencyCode = normalizeImportCurrencyCode(e.rawCurrency);
    final normId = _normalizeQianjiBillKey(e.id);
    final normSrc = _normalizeQianjiBillKey(e.sourceId);

    final item = _PreparedQianjiItem(
      entry: e,
      kind: kind,
      typeSuffixCategory: suffixCat,
      amountMinor: kind == _QianjiKind.expense && parsedMoney.isNegative
          ? parsedMoney
          : magMinor,
      feeMinor: feeMinor,
      discountMinor: discountMinor,
      currencyCode: currencyCode,
      excludeExIn: exclExIn,
      excludeBudget: exclBudget,
      normalizedId: normId,
      normalizedSourceId: normSrc,
    );
    prepared.add(item);
    if (normId.isNotEmpty &&
        (kind == _QianjiKind.reimbursable ||
            kind == _QianjiKind.expense ||
            kind == _QianjiKind.income)) {
      byId.putIfAbsent(normId, () => item);
    }
  }

  // Pass 2A: Link `报销记录` and `退款` rows to matching parent bills when `sourceid`/`关联账单` matches.
  var mergedChildCount = 0;
  for (final item in prepared) {
    if (item.kind == _QianjiKind.reimburseReceipt &&
        item.normalizedSourceId.isNotEmpty) {
      final parent = byId[item.normalizedSourceId];
      if (parent != null && parent.kind == _QianjiKind.reimbursable) {
        final childAcc = _singleQianjiAccount(item.entry);
        if (childAcc.isNotEmpty &&
            accountLookup.findFunding(childAcc) == null) {
          unknownAssetsOut.add(childAcc);
        }
        parent.reimburseChildren.add(
          ImportReimburseChildSpec(
            recordTime: item.entry.recordTimeMs,
            moneyMinor: item.amountMinor.abs(),
            assetName: childAcc,
            currencyCode: item.currencyCode,
            remark: truncateRunes(item.entry.remark, 200),
            tags: item.entry.tags,
            images: item.entry.imageNames,
            embeddedImageBytes: item.entry.imageBytes,
          ),
        );
        item.consumedAsChild = true;
        mergedChildCount++;
      }
    } else if (item.kind == _QianjiKind.refund &&
        item.normalizedSourceId.isNotEmpty) {
      final parent = byId[item.normalizedSourceId];
      if (parent != null &&
          (parent.kind == _QianjiKind.expense ||
              parent.kind == _QianjiKind.reimbursable ||
              parent.kind == _QianjiKind.income)) {
        final childAcc = _singleQianjiAccount(item.entry);
        if (childAcc.isNotEmpty &&
            accountLookup.findFunding(childAcc) == null) {
          unknownAssetsOut.add(childAcc);
        }
        parent.refundChildren.add(
          ImportRefundChildSpec(
            recordTime: item.entry.recordTimeMs,
            moneyMinor: item.amountMinor.abs(),
            assetName: childAcc,
            currencyCode: item.currencyCode,
            remark: truncateRunes(item.entry.remark, 200),
            tags: item.entry.tags,
            images: item.entry.imageNames,
            embeddedImageBytes: item.entry.imageBytes,
          ),
        );
        item.consumedAsChild = true;
        mergedChildCount++;
      }
    }
  }

  // Pass 2B: Emit ValidImportRow for all non-consumed items (and auto-generate `type=15`
  // when a `报销` row has `已报销 == '是'` / `hasbx == 1` without explicit `报销记录` rows).
  final validRows = <ValidImportRow>[];

  for (final item in prepared) {
    if (item.consumedAsChild) continue;
    final e = item.entry;
    final bookName = truncateRunes(e.bookName, 30);
    final remark = truncateRunes(e.remark, 200);

    if (item.kind == _QianjiKind.transfer) {
      final (fromName, toName) = _pairQianjiAccounts(e);
      if (fromName.isEmpty || toName.isEmpty) {
        failRowsOut.add(
          ImportFailItem(
            sheetNo: e.sheetNo,
            rowNo: e.rowNo,
            reason: '转账账单账户不完整：「$fromName -> $toName」',
            rawRow: e.rawRowText,
          ),
        );
        continue;
      }
      if (fromName == toName) {
        failRowsOut.add(
          ImportFailItem(
            sheetNo: e.sheetNo,
            rowNo: e.rowNo,
            reason: '转账转出与转入账户不能相同：「$fromName」',
            rawRow: e.rawRowText,
          ),
        );
        continue;
      }
      final fromAcc = accountLookup.findFunding(fromName);
      final toAcc = accountLookup.findFunding(toName);
      if (!allowUnknownAccounts && (fromAcc == null || toAcc == null)) {
        failRowsOut.add(
          ImportFailItem(
            sheetNo: e.sheetNo,
            rowNo: e.rowNo,
            reason: '转账账单账户不完整，建议开启自动创建缺失账户或先创建账户「$fromName, $toName」',
            rawRow: e.rawRowText,
          ),
        );
        continue;
      }
      if (fromAcc == null) unknownAssetsOut.add(fromName);
      if (toAcc == null) unknownAssetsOut.add(toName);

      validRows.add(
        ValidImportRow(
          sheetNo: e.sheetNo,
          rowNo: e.rowNo,
          recordTime: e.recordTimeMs,
          type: RecordType.transfer,
          moneyMinor: item.amountMinor,
          parentCategoryName: '',
          assetName: fromName,
          toAssetName: toName,
          resolvedFromAssetId: fromAcc?.id ?? noRef,
          resolvedToAssetId: toAcc?.id ?? noRef,
          bookName: bookName,
          currencyCode: item.currencyCode,
          remark: remark,
          tags: e.tags,
          images: e.imageNames,
          embeddedImageBytes: e.imageBytes,
          feeMinor: item.feeMinor,
          excludeBudget: item.excludeBudget,
          excludeExIn: item.excludeExIn,
          sourceRecordKey: item.normalizedId.isEmpty ? null : item.normalizedId,
        ),
      );
      continue;
    }

    if (_isDebtKind(item.kind)) {
      final debtResolved = _resolveQianjiDebtSlots(item.kind, e, accountLookup);
      final matchedDebt = accountLookup.findDebt(
        debtResolved.debtName,
        debtResolved.debtSubType,
      );
      final matchedFunding = debtResolved.fundingName.isEmpty
          ? null
          : accountLookup.findFunding(debtResolved.fundingName);

      if (!allowUnknownAccounts && matchedDebt == null) {
        failRowsOut.add(
          ImportFailItem(
            sheetNo: e.sheetNo,
            rowNo: e.rowNo,
            reason: '借贷对象「${debtResolved.debtName}」不存在，请开启「自动创建缺失账户」或先创建该借贷项目',
            rawRow: e.rawRowText,
          ),
        );
        continue;
      }
      if (matchedDebt == null) unknownAssetsOut.add(debtResolved.debtName);
      if (debtResolved.fundingName.isNotEmpty && matchedFunding == null) {
        unknownAssetsOut.add(debtResolved.fundingName);
      }

      final fundingId = matchedFunding?.id ?? noRef;
      final debtId = matchedDebt?.id ?? noRef;
      final isIncomingFunding =
          debtResolved.recordType == RecordType.borrowIn ||
          debtResolved.recordType == RecordType.collect ||
          (debtResolved.recordType == RecordType.debtInterest &&
              debtResolved.subType == RecordDirection.income);

      validRows.add(
        ValidImportRow(
          sheetNo: e.sheetNo,
          rowNo: e.rowNo,
          recordTime: e.recordTimeMs,
          type: debtResolved.recordType,
          subType: debtResolved.subType,
          moneyMinor: item.amountMinor,
          parentCategoryName: '',
          assetName: debtResolved.fundingName,
          debtName: debtResolved.debtName,
          debtSubType: debtResolved.debtSubType,
          resolvedFromAssetId: isIncomingFunding ? debtId : fundingId,
          resolvedToAssetId: isIncomingFunding ? fundingId : debtId,
          bookName: bookName,
          currencyCode: item.currencyCode,
          remark: remark,
          tags: e.tags,
          images: e.imageNames,
          embeddedImageBytes: e.imageBytes,
          excludeBudget: item.excludeBudget,
          excludeExIn: item.excludeExIn,
          sourceRecordKey: item.normalizedId.isEmpty ? null : item.normalizedId,
        ),
      );
      continue;
    }

    // Non-transfer, non-debt: expense, income, reimbursable, standalone refund, standalone reimburseReceipt.
    final int recordType;
    final BigInt moneyMinor;
    final String fallbackCat;

    switch (item.kind) {
      case _QianjiKind.expense:
        recordType = RecordType.expense;
        moneyMinor = item.amountMinor;
        fallbackCat = '其他';
      case _QianjiKind.income:
        recordType = RecordType.income;
        moneyMinor = item.amountMinor;
        fallbackCat = '其他';
      case _QianjiKind.reimbursable:
        recordType = RecordType.reimbursable;
        moneyMinor = item.amountMinor;
        fallbackCat = item.typeSuffixCategory.isNotEmpty
            ? item.typeSuffixCategory
            : '报销';
      case _QianjiKind.reimburseReceipt:
        // Standalone `报销记录` whose parent was not in this export file: import as income so no funds are lost.
        recordType = RecordType.income;
        moneyMinor = item.amountMinor.abs();
        fallbackCat = '报销款';
      case _QianjiKind.refund:
        // Standalone `退款` without a matching parent in this file: negative expense.
        recordType = RecordType.expense;
        moneyMinor = -item.amountMinor.abs();
        fallbackCat = item.typeSuffixCategory.isNotEmpty
            ? item.typeSuffixCategory
            : '退款';
      default:
        continue;
    }

    var cat1 = e.cat1.trim();
    var cat2 = e.cat2.trim();
    if (cat1.isEmpty && cat2.isNotEmpty) {
      cat1 = cat2;
      cat2 = '';
    }
    if (cat1.isEmpty) {
      cat1 = item.typeSuffixCategory.isNotEmpty
          ? item.typeSuffixCategory
          : fallbackCat;
    }
    cat1 = truncateRunes(cat1, 16);
    cat2 = truncateRunes(cat2, 16);

    final fundingName = _singleQianjiAccount(e);
    final matchedFunding = fundingName.isEmpty
        ? null
        : accountLookup.findFunding(fundingName);
    if (fundingName.isNotEmpty && matchedFunding == null) {
      unknownAssetsOut.add(fundingName);
    }

    final reimbChildren = <ImportReimburseChildSpec>[...item.reimburseChildren];
    if (recordType == RecordType.reimbursable &&
        reimbChildren.isEmpty &&
        e.hasBx &&
        moneyMinor > BigInt.zero) {
      reimbChildren.add(
        ImportReimburseChildSpec(
          recordTime: e.recordTimeMs + 1,
          moneyMinor: moneyMinor,
          assetName: fundingName,
          currencyCode: item.currencyCode,
          remark: remark,
          tags: e.tags,
        ),
      );
    }
    reimbChildren.sort((a, b) => a.recordTime.compareTo(b.recordTime));

    final refundChildren = <ImportRefundChildSpec>[...item.refundChildren]
      ..sort((a, b) => a.recordTime.compareTo(b.recordTime));

    final effectiveDiscountMinor =
        (recordType == RecordType.expense || recordType == RecordType.income) &&
            !moneyMinor.isNegative &&
            item.discountMinor != null &&
            item.discountMinor! > BigInt.zero
        ? item.discountMinor
        : null;

    validRows.add(
      ValidImportRow(
        sheetNo: e.sheetNo,
        rowNo: e.rowNo,
        recordTime: e.recordTimeMs,
        type: recordType,
        moneyMinor: moneyMinor,
        parentCategoryName: cat1,
        subCategoryName: cat2,
        assetName: fundingName,
        resolvedAssetId: recordType == RecordType.reimbursable
            ? noRef
            : (matchedFunding?.id ?? noRef),
        resolvedFromAssetId: recordType == RecordType.reimbursable
            ? (matchedFunding?.id ?? noRef)
            : noRef,
        bookName: bookName,
        currencyCode: item.currencyCode,
        remark: remark,
        tags: e.tags,
        images: e.imageNames,
        embeddedImageBytes: e.imageBytes,
        discountMinor: effectiveDiscountMinor,
        excludeBudget: item.excludeBudget,
        excludeExIn: item.excludeExIn,
        reimburseChildren: reimbChildren,
        refundChildren: refundChildren,
        sourceRecordKey: item.normalizedId.isEmpty ? null : item.normalizedId,
      ),
    );
  }

  return (validRows: validRows, mergedChildCount: mergedChildCount);
}

bool _isDebtKind(_QianjiKind kind) => switch (kind) {
  _QianjiKind.debtBorrowIn ||
  _QianjiKind.debtLendOut ||
  _QianjiKind.debtRepay ||
  _QianjiKind.debtCollect ||
  _QianjiKind.debtInterestExpense ||
  _QianjiKind.debtInterestIncome => true,
  _ => false,
};

({
  int recordType,
  int subType,
  int debtSubType,
  String debtName,
  String fundingName,
})
_resolveQianjiDebtSlots(
  _QianjiKind kind,
  _QianjiRawEntry e,
  ImportAccountLookup lookup,
) {
  final (rawFirst, rawSecond) = _pairQianjiAccounts(e);

  switch (kind) {
    case _QianjiKind.debtBorrowIn:
      // Qianji `借入`: `账户1`/`asset` = creditor (debt), `账户2`/`target` = receiving funding account.
      String debtName;
      String fundingName;
      if (rawFirst.isNotEmpty && rawSecond.isNotEmpty) {
        debtName = rawFirst;
        fundingName = rawSecond;
      } else if (rawFirst.isNotEmpty) {
        if (lookup.findFunding(rawFirst) != null &&
            lookup.findDebt(rawFirst, AssetType.debtBorrow) == null) {
          debtName = '默认借入';
          fundingName = rawFirst;
        } else {
          debtName = rawFirst;
          fundingName = '';
        }
      } else if (rawSecond.isNotEmpty) {
        debtName = '默认借入';
        fundingName = rawSecond;
      } else {
        debtName = '默认借入';
        fundingName = '';
      }
      return (
        recordType: RecordType.borrowIn,
        subType: RecordDirection.none,
        debtSubType: AssetType.debtBorrow,
        debtName: debtName,
        fundingName: fundingName,
      );

    case _QianjiKind.debtCollect:
      // Qianji `债务-收款`/`收款`: `账户1`/`asset` = debtor (debt), `账户2`/`target` = receiving funding account.
      String debtName;
      String fundingName;
      if (rawFirst.isNotEmpty && rawSecond.isNotEmpty) {
        debtName = rawFirst;
        fundingName = rawSecond;
      } else if (rawFirst.isNotEmpty) {
        if (lookup.findFunding(rawFirst) != null &&
            lookup.findDebt(rawFirst, AssetType.debtLend) == null) {
          debtName = '默认借出';
          fundingName = rawFirst;
        } else {
          debtName = rawFirst;
          fundingName = '';
        }
      } else if (rawSecond.isNotEmpty) {
        debtName = '默认借出';
        fundingName = rawSecond;
      } else {
        debtName = '默认借出';
        fundingName = '';
      }
      return (
        recordType: RecordType.collect,
        subType: RecordDirection.none,
        debtSubType: AssetType.debtLend,
        debtName: debtName,
        fundingName: fundingName,
      );

    case _QianjiKind.debtLendOut:
      // Qianji `借出`: `账户1`/`from` = paying funding account, `账户2`/`target` = debtor (debt).
      String fundingName;
      String debtName;
      if (rawFirst.isNotEmpty && rawSecond.isNotEmpty) {
        fundingName = rawFirst;
        debtName = rawSecond;
      } else if (rawSecond.isNotEmpty) {
        fundingName = '';
        debtName = rawSecond;
      } else if (rawFirst.isNotEmpty) {
        if (lookup.findDebt(rawFirst, AssetType.debtLend) != null ||
            lookup.findFunding(rawFirst) == null) {
          fundingName = '';
          debtName = rawFirst;
        } else {
          fundingName = rawFirst;
          debtName = '默认借出';
        }
      } else {
        fundingName = '';
        debtName = '默认借出';
      }
      return (
        recordType: RecordType.lendOut,
        subType: RecordDirection.none,
        debtSubType: AssetType.debtLend,
        debtName: debtName,
        fundingName: fundingName,
      );

    case _QianjiKind.debtRepay:
      // Qianji `债务-还款`: `账户1`/`from` = paying funding account, `账户2`/`target` = creditor (debt).
      String fundingName;
      String debtName;
      if (rawFirst.isNotEmpty && rawSecond.isNotEmpty) {
        fundingName = rawFirst;
        debtName = rawSecond;
      } else if (rawSecond.isNotEmpty) {
        fundingName = '';
        debtName = rawSecond;
      } else if (rawFirst.isNotEmpty) {
        if (lookup.findDebt(rawFirst, AssetType.debtBorrow) != null ||
            lookup.findFunding(rawFirst) == null) {
          fundingName = '';
          debtName = rawFirst;
        } else {
          fundingName = rawFirst;
          debtName = '默认借入';
        }
      } else {
        fundingName = '';
        debtName = '默认借入';
      }
      return (
        recordType: RecordType.repay,
        subType: RecordDirection.none,
        debtSubType: AssetType.debtBorrow,
        debtName: debtName,
        fundingName: fundingName,
      );

    case _QianjiKind.debtInterestExpense:
      final fundingName = rawFirst;
      final debtName = rawSecond.isNotEmpty ? rawSecond : '默认借入';
      return (
        recordType: RecordType.debtInterest,
        subType: RecordDirection.expense,
        debtSubType: AssetType.debtBorrow,
        debtName: debtName,
        fundingName: fundingName,
      );

    case _QianjiKind.debtInterestIncome:
      final String debtName;
      final String fundingName;
      if (rawFirst.isNotEmpty && rawSecond.isNotEmpty) {
        debtName = rawFirst;
        fundingName = rawSecond;
      } else if (rawSecond.isNotEmpty) {
        debtName = '默认借出';
        fundingName = rawSecond;
      } else if (rawFirst.isNotEmpty) {
        if (lookup.findDebt(rawFirst, AssetType.debtLend) != null) {
          debtName = rawFirst;
          fundingName = '';
        } else {
          debtName = '默认借出';
          fundingName = rawFirst;
        }
      } else {
        debtName = '默认借出';
        fundingName = '';
      }
      return (
        recordType: RecordType.debtInterest,
        subType: RecordDirection.income,
        debtSubType: AssetType.debtLend,
        debtName: debtName,
        fundingName: fundingName,
      );

    default:
      throw StateError('Not a debt kind: $kind');
  }
}

(_QianjiKind, String)? _classifyQianjiType(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return null;

  // Handle `退款·餐饮` / `报销·差旅` compound labels.
  if (t.startsWith('退款·') || t.startsWith('退款-')) {
    return (_QianjiKind.refund, t.substring(3).trim());
  }
  if (t.startsWith('报销·') || t.startsWith('报销-')) {
    return (_QianjiKind.reimbursable, t.substring(3).trim());
  }
  if (t.startsWith('报销记录') || t.toLowerCase().startsWith('reimburse record')) {
    return (_QianjiKind.reimburseReceipt, '');
  }

  final lower = t.toLowerCase();
  return switch (lower) {
    '支出' || 'spend' || 'expense' => (_QianjiKind.expense, ''),
    '收入' || 'income' => (_QianjiKind.income, ''),
    '转账' ||
    'transfer' ||
    '还款' ||
    '信用卡还款' ||
    'repayment' ||
    'credit repayment' => (_QianjiKind.transfer, ''),
    '报销' || 'reimburse' => (_QianjiKind.reimbursable, ''),
    '报销款' => (_QianjiKind.reimburseReceipt, ''),
    '退款' || 'refund' => (_QianjiKind.refund, ''),
    '债务-借入' || '借入' || 'debt' || 'borrow in' => (_QianjiKind.debtBorrowIn, ''),
    '债务-借出' ||
    '借出' ||
    'lent out' ||
    'lend out' => (_QianjiKind.debtLendOut, ''),
    '债务-还款' || 'debt repayment' => (_QianjiKind.debtRepay, ''),
    '债务-收款' ||
    '收款' ||
    'debt collection' ||
    'collect' => (_QianjiKind.debtCollect, ''),
    '债务-利息支出' ||
    '利息支出' ||
    'debt interest spend' => (_QianjiKind.debtInterestExpense, ''),
    '债务-利息收入' ||
    '利息收入' ||
    'debt interest income' => (_QianjiKind.debtInterestIncome, ''),
    _ => null,
  };
}

String _singleQianjiAccount(_QianjiRawEntry e) {
  if (e.isJsonMode) {
    if (e.jsonAsset.isNotEmpty) return _stripArrowSingle(e.jsonAsset);
    if (e.jsonFrom.isNotEmpty) return _stripArrowSingle(e.jsonFrom);
    if (e.jsonTarget.isNotEmpty) return _stripArrowSingle(e.jsonTarget);
  }
  if (e.account1.isNotEmpty) return _stripArrowSingle(e.account1);
  if (e.account2.isNotEmpty) return _stripArrowSingle(e.account2);
  return '';
}

String _stripArrowSingle(String s) {
  final idx = s.indexOf('->');
  if (idx < 0) return s.trim();
  final left = s.substring(0, idx).trim();
  final right = s.substring(idx + 2).trim();
  return left.isNotEmpty ? left : right;
}

(String, String) _pairQianjiAccounts(_QianjiRawEntry e) {
  var a1 = e.isJsonMode
      ? (e.jsonFrom.isNotEmpty ? e.jsonFrom : e.jsonAsset)
      : e.account1;
  var a2 = e.isJsonMode ? e.jsonTarget : e.account2;
  a1 = a1.trim();
  a2 = a2.trim();
  if (a2.isEmpty && a1.contains('->')) {
    final idx = a1.indexOf('->');
    final left = a1.substring(0, idx).trim();
    final right = a1.substring(idx + 2).trim();
    a1 = left;
    a2 = right;
  }
  return (a1, a2);
}

String _normalizeQianjiBillKey(String raw) {
  var s = raw.trim();
  if (s.isEmpty || s == '0' || s == '-1' || s.toLowerCase() == 'null') {
    return '';
  }
  // Qianji `Bill.wrapBillId` sometimes wraps IDs with `#` or `key=` prefixes.
  while (s.startsWith('#') || s.startsWith("'")) {
    s = s.substring(1).trim();
  }
  return s;
}

/// Parses Qianji `账单标记` / `billflag` into `(excludeExIn, excludeBudget)`.
(bool, bool) parseQianjiBillFlags(String raw) {
  final s = raw.trim().toLowerCase();
  if (s.isEmpty) return (false, false);
  if (s == 'nc&nb' ||
      s == 'nb&nc' ||
      s == '不计收支&预算' ||
      s == '不计入收支&预算' ||
      s == '不计收支和预算' ||
      s == 'not in statistics&budgets' ||
      s == 'not in budgets&statistics') {
    return (true, true);
  }
  final exclExIn =
      s.contains('nc') ||
      s.contains('不计收支') ||
      s.contains('不计入收支') ||
      s.contains('not in statistics');
  final exclBudget =
      s.contains('nb') ||
      s.contains('不计预算') ||
      s.contains('不计入预算') ||
      s.contains('not in budgets');
  return (exclExIn, exclBudget);
}

/// Splits Qianji tags by `#` and `,` / `，` / `;` (up to 8 unique 20-char tags).
List<String> parseQianjiTags(String raw) {
  if (raw.trim().isEmpty) return const [];
  final result = <String>[];
  final seen = <String>{};
  for (final part in raw.split(RegExp(r'[#,，;；]+'))) {
    final t = truncateRunes(part.trim(), 20);
    if (t.isEmpty) continue;
    if (seen.add(t)) {
      result.add(t);
      if (result.length >= 8) break;
    }
  }
  return result;
}

bool _isTruthyQianjiReimbursed(String raw) {
  final s = raw.trim().toLowerCase();
  return s == '是' ||
      s == '已报销' ||
      s == '1' ||
      s == 'true' ||
      s == 'yes' ||
      s == 'reimbursed';
}

bool _isTruthyJsonHasBx(Object? v) {
  if (v is bool) return v;
  if (v is _JsonNumber) return v.raw == '1';
  if (v is String) return _isTruthyQianjiReimbursed(v);
  return false;
}

int _indexOfAnyCol(List<String> cols, List<String> candidates) {
  for (final c in candidates) {
    final idx = cols.indexOf(c);
    if (idx >= 0) return idx;
  }
  return -1;
}

int? _optCol(List<String> cols, List<String> candidates) {
  final idx = _indexOfAnyCol(cols, candidates);
  return idx >= 0 ? idx : null;
}

// ---------------------------------------------------------------------------
// Qianji JSON Field Helpers & Exact-Number RFC 8259 Parser (ZERO `double`!)
// ---------------------------------------------------------------------------

final class _JsonNumber {
  const _JsonNumber(this.raw);
  final String raw;

  @override
  String toString() => raw;
}

String _asRawText(Object? v) => switch (v) {
  null => '',
  String s => s.trim(),
  _JsonNumber n => n.raw,
  bool b => b ? 'true' : 'false',
  _ => '$v',
};

String _asExactDecimalText(Object? v) => switch (v) {
  null => '',
  _JsonNumber n => n.raw,
  String s => s.trim(),
  _ => '',
};

String _firstNonEmptyString(List<Object?> candidates) {
  for (final c in candidates) {
    final s = _asRawText(c);
    if (s.isNotEmpty && s.toLowerCase() != 'null') return s;
  }
  return '';
}

String _resolveQianjiJsonAccount(Object? rawVal, Object? fallbackName) {
  final fb = _asRawText(fallbackName);
  if (fb.isNotEmpty && fb != '0' && fb != '-1' && fb.toLowerCase() != 'null') {
    return fb;
  }
  if (rawVal == null) return '';
  if (rawVal is String) {
    final s = rawVal.trim();
    if (s.isEmpty || s == '0' || s == '-1' || s.toLowerCase() == 'null') {
      return '';
    }
    return s;
  }
  if (rawVal is _JsonNumber) {
    final parsed = BigInt.tryParse(rawVal.raw);
    if (parsed == null || parsed == BigInt.zero || parsed == -BigInt.one) {
      return '';
    }
    return '钱迹账户#${rawVal.raw}';
  }
  if (rawVal is Map<String, Object?>) {
    final name = _firstNonEmptyString([rawVal['name'], rawVal['title']]);
    if (name.isNotEmpty) return name;
    return _resolveQianjiJsonAccount(rawVal['id'], null);
  }
  return '';
}

(String, String) _extractJsonCategories(Map<String, Object?> item) {
  var cat1 = '';
  var cat2 = _firstNonEmptyString([
    item['subCategory'],
    item['subcategory'],
    item['sub_category'],
  ]);
  final rawCat = item['category'];
  if (rawCat is String) {
    cat1 = rawCat.trim();
  } else if (rawCat is Map<String, Object?>) {
    cat1 = _firstNonEmptyString([rawCat['name'], rawCat['cname']]);
  }
  if (cat2.isEmpty && cat1.contains(' / ')) {
    final parts = cat1.split(' / ');
    cat1 = parts.first.trim();
    cat2 = parts.sublist(1).join(' / ').trim();
  }
  return (cat1, cat2);
}

String _extractJsonTypeString(Object? rawType) {
  if (rawType is String) return rawType.trim();
  if (rawType is _JsonNumber) {
    final code = int.tryParse(rawType.raw);
    return switch (code) {
      0 => '支出',
      1 => '收入',
      2 => '转账',
      3 => '还款',
      4 => '债务-收款',
      5 => '报销',
      6 => '债务-借入',
      7 => '债务-借出',
      8 => '报销记录',
      9 => '债务-还款',
      10 => '债务-利息支出',
      11 => '债务-利息收入',
      12 || 13 => '退款',
      _ => rawType.raw,
    };
  }
  return '';
}

({int epochMs, String pattern})? _parseJsonDate(Object? rawDateVal) {
  if (rawDateVal is _JsonNumber) {
    final n = int.tryParse(rawDateVal.raw);
    if (n == null || n <= 0) return null;
    // Distinguish epoch seconds (10 digits) vs epoch milliseconds (13 digits).
    final ms = n < 100000000000 ? n * 1000 : n;
    return (epochMs: ms, pattern: 'epoch');
  }
  final s = _asRawText(rawDateVal);
  if (s.isEmpty) return null;
  if (RegExp(r'^\d{10,13}$').hasMatch(s)) {
    final n = int.tryParse(s);
    if (n != null && n > 0) {
      final ms = s.length <= 10 ? n * 1000 : n;
      return (epochMs: ms, pattern: 'epoch');
    }
  }
  return parseFlexibleImportDateTime(s);
}

List<String> _extractJsonTags(Object? rawTags) {
  if (rawTags == null) return const [];
  if (rawTags is String) return parseQianjiTags(rawTags);
  if (rawTags is List<Object?>) {
    final joined = <String>[];
    for (final elem in rawTags) {
      if (elem is String) {
        joined.add(elem);
      } else if (elem is Map<String, Object?>) {
        final n = _asRawText(elem['name']);
        if (n.isNotEmpty) joined.add(n);
      }
    }
    return parseQianjiTags(joined.join(','));
  }
  return const [];
}

List<String> _extractJsonImages(Object? rawImages) {
  if (rawImages == null) return const [];
  if (rawImages is String) {
    return [
      for (final p in rawImages.split(RegExp(r'[,;\n]+')))
        if (p.trim().isNotEmpty) p.trim(),
    ];
  }
  if (rawImages is List<Object?>) {
    final out = <String>[];
    for (final item in rawImages) {
      if (item is String && item.trim().isNotEmpty) {
        out.add(item.trim());
      } else if (item is Map<String, Object?>) {
        final u = _firstNonEmptyString([
          item['url'],
          item['path'],
          item['name'],
          item['fname'],
        ]);
        if (u.isNotEmpty) out.add(u);
      }
    }
    return out;
  }
  return const [];
}

String _summarizeJsonItem(Map<String, Object?> item) {
  final k = _asRawText(item['key'] ?? item['id']);
  final d = _asRawText(item['date']);
  final t = _asRawText(item['type']);
  final m = _asRawText(item['money']);
  return 'key=$k,date=$d,type=$t,money=$m';
}

final class _ExactJsonParser {
  _ExactJsonParser(this.src);

  final String src;
  int _pos = 0;

  static Object? parse(String text) {
    var start = 0;
    if (text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF) start = 1;
    final p = _ExactJsonParser(start == 0 ? text : text.substring(start));
    p._skipWs();
    if (p._pos >= p.src.length) {
      throw const Failure(FailureCode.validation, '文件内容为空');
    }
    final value = p._readValue();
    p._skipWs();
    if (p._pos != p.src.length) {
      throw const Failure(FailureCode.validation, 'JSON 文件末尾存在多余字符');
    }
    return value;
  }

  void _skipWs() {
    while (_pos < src.length) {
      final c = src.codeUnitAt(_pos);
      if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) {
        _pos++;
      } else {
        break;
      }
    }
  }

  Object? _readValue() {
    _skipWs();
    if (_pos >= src.length) {
      throw const Failure(FailureCode.validation, 'JSON 格式不完整');
    }
    final c = src.codeUnitAt(_pos);
    return switch (c) {
      0x7B => _readObject(), // {
      0x5B => _readArray(), // [
      0x22 => _readString(), // "
      0x74 => _readLiteral('true', true),
      0x66 => _readLiteral('false', false),
      0x6E => _readLiteral('null', null),
      _ when c == 0x2D || (c >= 0x30 && c <= 0x39) => _readNumber(),
      _ => throw const Failure(FailureCode.validation, 'JSON 语法错误'),
    };
  }

  Map<String, Object?> _readObject() {
    _pos++; // {
    _skipWs();
    final map = <String, Object?>{};
    if (_pos < src.length && src.codeUnitAt(_pos) == 0x7D) {
      _pos++;
      return map;
    }
    while (true) {
      _skipWs();
      if (_pos >= src.length || src.codeUnitAt(_pos) != 0x22) {
        throw const Failure(FailureCode.validation, 'JSON 对象键名须为字符串');
      }
      final key = _readString();
      _skipWs();
      if (_pos >= src.length || src.codeUnitAt(_pos) != 0x3A) {
        throw const Failure(FailureCode.validation, 'JSON 对象缺少冒号');
      }
      _pos++; // :
      final val = _readValue();
      map[key] = val;
      _skipWs();
      if (_pos >= src.length) {
        throw const Failure(FailureCode.validation, 'JSON 对象未闭合');
      }
      final sep = src.codeUnitAt(_pos);
      if (sep == 0x7D) {
        _pos++;
        return map;
      }
      if (sep != 0x2C) {
        throw const Failure(FailureCode.validation, 'JSON 对象属性分隔符错误');
      }
      _pos++; // ,
    }
  }

  List<Object?> _readArray() {
    _pos++; // [
    _skipWs();
    final list = <Object?>[];
    if (_pos < src.length && src.codeUnitAt(_pos) == 0x5D) {
      _pos++;
      return list;
    }
    while (true) {
      list.add(_readValue());
      _skipWs();
      if (_pos >= src.length) {
        throw const Failure(FailureCode.validation, 'JSON 数组未闭合');
      }
      final sep = src.codeUnitAt(_pos);
      if (sep == 0x5D) {
        _pos++;
        return list;
      }
      if (sep != 0x2C) {
        throw const Failure(FailureCode.validation, 'JSON 数组元素分隔符错误');
      }
      _pos++; // ,
    }
  }

  String _readString() {
    _pos++; // opening "
    final sb = StringBuffer();
    while (_pos < src.length) {
      final c = src.codeUnitAt(_pos++);
      if (c == 0x22) return sb.toString();
      if (c < 0x20) {
        throw const Failure(FailureCode.validation, 'JSON 字符串包含未转义控制字符');
      }
      if (c != 0x5C) {
        sb.writeCharCode(c);
        continue;
      }
      if (_pos >= src.length) {
        throw const Failure(FailureCode.validation, 'JSON 转义序列不完整');
      }
      final esc = src.codeUnitAt(_pos++);
      switch (esc) {
        case 0x22:
          sb.writeCharCode(0x22);
        case 0x5C:
          sb.writeCharCode(0x5C);
        case 0x2F:
          sb.writeCharCode(0x2F);
        case 0x62:
          sb.writeCharCode(0x08);
        case 0x66:
          sb.writeCharCode(0x0C);
        case 0x6E:
          sb.writeCharCode(0x0A);
        case 0x72:
          sb.writeCharCode(0x0D);
        case 0x74:
          sb.writeCharCode(0x09);
        case 0x75:
          if (_pos + 4 > src.length) {
            throw const Failure(FailureCode.validation, 'JSON Unicode 转义不完整');
          }
          final hex = src.substring(_pos, _pos + 4);
          final unit = int.tryParse(hex, radix: 16);
          if (unit == null) {
            throw const Failure(FailureCode.validation, 'JSON Unicode 转义无效');
          }
          _pos += 4;
          sb.writeCharCode(unit);
        default:
          throw const Failure(FailureCode.validation, 'JSON 包含非法转义字符');
      }
    }
    throw const Failure(FailureCode.validation, 'JSON 字符串未闭合');
  }

  Object? _readLiteral(String word, Object? result) {
    if (src.startsWith(word, _pos)) {
      _pos += word.length;
      return result;
    }
    throw const Failure(FailureCode.validation, 'JSON 字面量无效');
  }

  _JsonNumber _readNumber() {
    final start = _pos;
    if (src.codeUnitAt(_pos) == 0x2D) _pos++;
    if (_pos >= src.length) {
      throw const Failure(FailureCode.validation, 'JSON 数字不完整');
    }
    final first = src.codeUnitAt(_pos);
    if (first == 0x30) {
      _pos++;
    } else if (first >= 0x31 && first <= 0x39) {
      while (_pos < src.length &&
          src.codeUnitAt(_pos) >= 0x30 &&
          src.codeUnitAt(_pos) <= 0x39) {
        _pos++;
      }
    } else {
      throw const Failure(FailureCode.validation, 'JSON 数字格式错误');
    }

    if (_pos < src.length && src.codeUnitAt(_pos) == 0x2E) {
      _pos++;
      final fracStart = _pos;
      while (_pos < src.length &&
          src.codeUnitAt(_pos) >= 0x30 &&
          src.codeUnitAt(_pos) <= 0x39) {
        _pos++;
      }
      if (_pos == fracStart) {
        throw const Failure(FailureCode.validation, 'JSON 小数位缺失');
      }
    }

    if (_pos < src.length &&
        (src.codeUnitAt(_pos) == 0x65 || src.codeUnitAt(_pos) == 0x45)) {
      _pos++;
      if (_pos < src.length &&
          (src.codeUnitAt(_pos) == 0x2B || src.codeUnitAt(_pos) == 0x2D)) {
        _pos++;
      }
      final expStart = _pos;
      while (_pos < src.length &&
          src.codeUnitAt(_pos) >= 0x30 &&
          src.codeUnitAt(_pos) <= 0x39) {
        _pos++;
      }
      if (_pos == expStart) {
        throw const Failure(FailureCode.validation, 'JSON 科学计数法指数缺失');
      }
    }
    return _JsonNumber(src.substring(start, _pos));
  }
}
