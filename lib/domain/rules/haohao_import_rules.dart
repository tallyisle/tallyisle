import 'dart:typed_data';

import '../../core/failure.dart';
import '../../core/money.dart';
import '../ledger/record_extra.dart';
import '../model/codes.dart';
import 'currency_rates.dart' show baseCurrency, rateToAnchorFromPrice;
import 'csv_excel_codec.dart';
import 'csv_excel_rules.dart';

/// Canonical 30-column header exported by 好好记账 (`haohaojizhang-1.22.5.apk` `XlsBillAttributeEnums`).
const List<String> haohaoHeader30 = [
  '日期',
  '金额',
  '账本',
  '类型',
  '分类',
  '子分类',
  '备注',
  '标签',
  '账户',
  '转入账户',
  '债务人',
  '转账手续费',
  '是否为报销',
  '账单状态',
  '报销金额',
  '报销日期',
  '退款金额',
  '退款日期',
  '原价',
  '不计入预算',
  '不计入收支',
  '账单图片',
  '原始金额',
  '币种',
  '本位币',
  '汇率',
  '转入金额',
  '转入币种',
  '转入本位币',
  '转入汇率',
];

const String haohaoPlatformName = '好好记账';

const Set<String> _haohaoDistinctiveColumns = {
  '子分类',
  '转入账户',
  '债务人',
  '转账手续费',
  '是否为报销',
  '账单状态',
  '报销金额',
  '报销日期',
  '退款金额',
  '退款日期',
  '原价',
  '不计入预算',
  '不计入收支',
  '原始金额',
  '本位币',
  '转入金额',
  '转入币种',
  '转入本位币',
  '转入汇率',
};

final class HaohaoHeaderBinding {
  const HaohaoHeaderBinding({
    required this.headerRowIndex,
    required this.dateCol,
    required this.moneyCol,
    this.bookCol,
    required this.typeCol,
    required this.cat1Col,
    this.cat2Col,
    this.remarkCol,
    this.tagCol,
    this.accountCol,
    this.toAccountCol,
    this.debtorCol,
    this.feeCol,
    this.isReimburseCol,
    this.statusCol,
    this.reimburseMoneyCol,
    this.reimburseDateCol,
    this.refundMoneyCol,
    this.refundDateCol,
    this.originalPriceCol,
    this.excludeBudgetCol,
    this.excludeExInCol,
    this.imageCol,
    this.origMoneyCol,
    this.currencyCol,
    this.baseCurrencyCol,
    this.rateCol,
    this.toMoneyCol,
    this.toCurrencyCol,
    this.toBaseCurrencyCol,
    this.toRateCol,
  });

  final int headerRowIndex;
  final int dateCol;
  final int moneyCol;
  final int? bookCol;
  final int typeCol;
  final int cat1Col;
  final int? cat2Col;
  final int? remarkCol;
  final int? tagCol;
  final int? accountCol;
  final int? toAccountCol;
  final int? debtorCol;
  final int? feeCol;
  final int? isReimburseCol;
  final int? statusCol;
  final int? reimburseMoneyCol;
  final int? reimburseDateCol;
  final int? refundMoneyCol;
  final int? refundDateCol;
  final int? originalPriceCol;
  final int? excludeBudgetCol;
  final int? excludeExInCol;
  final int? imageCol;
  final int? origMoneyCol;
  final int? currencyCol;
  final int? baseCurrencyCol;
  final int? rateCol;
  final int? toMoneyCol;
  final int? toCurrencyCol;
  final int? toBaseCurrencyCol;
  final int? toRateCol;

  bool get hasBookColumn => bookCol != null;
  bool get hasCurrencyColumn =>
      currencyCol != null || toCurrencyCol != null || origMoneyCol != null;
}

/// Attempts to match a 好好记账 30-column header or custom column subset
/// containing the 4 required columns (`日期`, `金额`, `类型`, `分类`) plus
/// Haohao-specific column ordering/attributes.
HaohaoHeaderBinding? tryMatchHaohaoSheetHeader(List<List<String>> rows) {
  final limit = rows.length < 8 ? rows.length : 8;
  for (var r = 0; r < limit; r++) {
    final cols = [for (final c in rows[r]) c.trim()];
    if (cols.every((c) => c.isEmpty)) continue;

    final dateCol = cols.indexOf('日期');
    final moneyCol = cols.indexOf('金额');
    final typeCol = cols.indexOf('类型');
    final cat1Col = cols.indexOf('分类');
    if (dateCol < 0 || moneyCol < 0 || typeCol < 0 || cat1Col < 0) {
      continue;
    }

    // Do not collide with Official Templates v1–v3 (`日期,类型,分类,金额,账户,账户2,...`).
    if (cols.contains('账户2') || cols.contains('一级分类')) {
      continue;
    }

    final startsWithDateMoney = dateCol == 0 && moneyCol == 1;
    final hasDistinctiveCol = cols.any(_haohaoDistinctiveColumns.contains);
    if (!startsWithDateMoney && !hasDistinctiveCol) {
      continue;
    }

    int? opt(String name) {
      final idx = cols.indexOf(name);
      return idx >= 0 ? idx : null;
    }

    return HaohaoHeaderBinding(
      headerRowIndex: r,
      dateCol: dateCol,
      moneyCol: moneyCol,
      bookCol: opt('账本'),
      typeCol: typeCol,
      cat1Col: cat1Col,
      cat2Col: opt('子分类'),
      remarkCol: opt('备注'),
      tagCol: opt('标签'),
      accountCol: opt('账户'),
      toAccountCol: opt('转入账户'),
      debtorCol: opt('债务人'),
      feeCol: opt('转账手续费'),
      isReimburseCol: opt('是否为报销'),
      statusCol: opt('账单状态'),
      reimburseMoneyCol: opt('报销金额'),
      reimburseDateCol: opt('报销日期'),
      refundMoneyCol: opt('退款金额'),
      refundDateCol: opt('退款日期'),
      originalPriceCol: opt('原价'),
      excludeBudgetCol: opt('不计入预算'),
      excludeExInCol: opt('不计入收支'),
      imageCol: opt('账单图片'),
      origMoneyCol: opt('原始金额'),
      currencyCol: opt('币种'),
      baseCurrencyCol: opt('本位币'),
      rateCol: opt('汇率'),
      toMoneyCol: opt('转入金额'),
      toCurrencyCol: opt('转入币种'),
      toBaseCurrencyCol: opt('转入本位币'),
      toRateCol: opt('转入汇率'),
    );
  }
  return null;
}

/// Splits Haohao tags by whitespace and commas (`#` stripped, max 8 unique 20-char tags).
List<String> parseHaohaoTags(String raw) {
  if (raw.trim().isEmpty) return const [];
  final result = <String>[];
  final seen = <String>{};
  for (final part in raw.split(RegExp(r'[\s,，;；#]+'))) {
    final t = truncateRunes(part.trim(), 20);
    if (t.isEmpty) continue;
    if (seen.add(t)) {
      result.add(t);
      if (result.length >= 8) break;
    }
  }
  return result;
}

/// Parses and validates all matching 好好记账 sheets from [spreadsheet].
SpreadsheetImportAnalysis analyzeHaohaoSpreadsheetImport({
  required DecodedSpreadsheet spreadsheet,
  required Iterable<ImportAccountRef> existingAccounts,
  Map<int, Map<int, List<Uint8List>>> xlsxEmbeddedImagesBySheet = const {},
  Uint8List? Function(String rawRef)? bundleImageResolver,
  bool? allowUnknownTransferAccounts,
}) {
  final allowUnknown = allowUnknownTransferAccounts ?? true;
  final accountLookup = ImportAccountLookup(existingAccounts);

  HaohaoHeaderBinding? primaryBinding;
  final validRows = <ValidImportRow>[];
  final failRows = <ImportFailItem>[];
  final unknownAssetsSet = <String>{};
  final lockedFormats = <int, String>{};
  var emptyRowCount = 0;

  for (final sheet in spreadsheet.sheets) {
    if (sheet.rows.every((r) => r.every((c) => c.trim().isEmpty))) continue;
    final binding = tryMatchHaohaoSheetHeader(sheet.rows);
    if (binding == null) continue;
    primaryBinding ??= binding;

    final sheetImages =
        xlsxEmbeddedImagesBySheet[sheet.sheetNo] ??
        const <int, List<Uint8List>>{};
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
      final rawDate = cell(binding.dateCol);
      final parsedDate = parseFlexibleImportDateTime(rawDate);
      if (parsedDate == null) {
        failRows.add(
          ImportFailItem(
            sheetNo: sheet.sheetNo,
            rowNo: rowNo,
            reason: '无法识别的日期：${rawDate.isEmpty ? 'null' : rawDate}',
            rawRow: rawRowText,
          ),
        );
        continue;
      }
      firstPattern ??= parsedDate.pattern;
      final recordTimeMs = parsedDate.epochMs;

      final rawMoney = cell(binding.moneyCol);
      final parsedMoney = parseImportAmountMinor(rawMoney);
      if (parsedMoney == null) {
        failRows.add(
          ImportFailItem(
            sheetNo: sheet.sheetNo,
            rowNo: rowNo,
            reason: '无法识别的账单金额',
            rawRow: rawRowText,
          ),
        );
        continue;
      }

      final rawType = cell(binding.typeCol);
      var cat1 = cell(binding.cat1Col);
      var cat2 = cell(binding.cat2Col);
      var account = cell(binding.accountCol);
      var toAccount = cell(binding.toAccountCol);
      if (toAccount.isEmpty && account.contains('->')) {
        final idx = account.indexOf('->');
        toAccount = account.substring(idx + 2).trim();
        account = account.substring(0, idx).trim();
      }
      final debtor = cell(binding.debtorCol);
      final bookName = truncateRunes(cell(binding.bookCol), 30);
      final remark = truncateRunes(cell(binding.remarkCol), 200);
      final tags = parseHaohaoTags(cell(binding.tagCol));
      final excludeBudget = _parseHaohaoBool(cell(binding.excludeBudgetCol));
      final excludeExIn = _parseHaohaoBool(cell(binding.excludeExInCol));

      final imageResult = resolveImportCellImages(
        rawCell: cell(binding.imageCol),
        preExtracted: sheetImages[rIdx] ?? const [],
        bundleResolver: bundleImageResolver,
      );

      // Parse optional fee, original price -> discount, reimburse, refund, and FX columns.
      var feeMinor = BigInt.zero;
      final rawFee = cell(binding.feeCol);
      if (rawFee.isNotEmpty) {
        final pf = parseImportAmountMinor(rawFee);
        if (pf == null || pf.isNegative) {
          failRows.add(
            ImportFailItem(
              sheetNo: sheet.sheetNo,
              rowNo: rowNo,
              reason: pf == null ? '无法识别的手续费金额' : '转账手续费不能小于0',
              rawRow: rawRowText,
            ),
          );
          continue;
        }
        feeMinor = pf;
      }

      BigInt? discountMinor;
      final rawOrigPrice = cell(binding.originalPriceCol);
      if (rawOrigPrice.isNotEmpty) {
        final origPriceMinor = parseImportAmountMinor(rawOrigPrice);
        if (origPriceMinor == null || origPriceMinor.isNegative) {
          failRows.add(
            ImportFailItem(
              sheetNo: sheet.sheetNo,
              rowNo: rowNo,
              reason: '无法识别的原价金额',
              rawRow: rawRowText,
            ),
          );
          continue;
        }
        if (origPriceMinor > parsedMoney.abs()) {
          discountMinor = origPriceMinor - parsedMoney.abs();
        }
      }

      BigInt? reimburseMinor;
      final rawReimbMoney = cell(binding.reimburseMoneyCol);
      if (rawReimbMoney.isNotEmpty) {
        final pr = parseImportAmountMinor(rawReimbMoney);
        if (pr == null || pr.isNegative) {
          failRows.add(
            ImportFailItem(
              sheetNo: sheet.sheetNo,
              rowNo: rowNo,
              reason: '无法识别的报销金额',
              rawRow: rawRowText,
            ),
          );
          continue;
        }
        if (pr > BigInt.zero) reimburseMinor = pr;
      }
      final rawReimbDate = cell(binding.reimburseDateCol);
      final reimbDateMs = rawReimbDate.isEmpty
          ? null
          : parseFlexibleImportDateTime(rawReimbDate)?.epochMs;

      BigInt? refundMinor;
      final rawRefundMoney = cell(binding.refundMoneyCol);
      if (rawRefundMoney.isNotEmpty) {
        final prf = parseImportAmountMinor(rawRefundMoney);
        if (prf == null || prf.isNegative) {
          failRows.add(
            ImportFailItem(
              sheetNo: sheet.sheetNo,
              rowNo: rowNo,
              reason: '无法识别的退款金额',
              rawRow: rawRowText,
            ),
          );
          continue;
        }
        if (prf > BigInt.zero) refundMinor = prf;
      }
      final rawRefundDate = cell(binding.refundDateCol);
      final refundDateMs = rawRefundDate.isEmpty
          ? null
          : parseFlexibleImportDateTime(rawRefundDate)?.epochMs;

      // FX columns
      final rawOrigMoney = cell(binding.origMoneyCol);
      final origMinor = rawOrigMoney.isEmpty
          ? null
          : parseImportAmountMinor(rawOrigMoney)?.abs();
      final srcCurr = normalizeImportCurrencyCode(cell(binding.currencyCol));
      final baseCurr = normalizeImportCurrencyCode(
        cell(binding.baseCurrencyCol),
      );
      final rawRate = cell(binding.rateCol);

      final rawToMoney = cell(binding.toMoneyCol);
      final toMinor = rawToMoney.isEmpty
          ? null
          : parseImportAmountMinor(rawToMoney)?.abs();
      final toCurr = normalizeImportCurrencyCode(cell(binding.toCurrencyCol));
      final toBaseCurr = normalizeImportCurrencyCode(
        cell(binding.toBaseCurrencyCol),
      );
      final rawToRate = cell(binding.toRateCol);

      final explicitRates = <String, String>{};
      _tryCollectAnchorRate(explicitRates, srcCurr, baseCurr, rawRate);
      _tryCollectAnchorRate(explicitRates, toCurr, toBaseCurr, rawToRate);

      // 1. Check Debt routing first (`债务人` + `借入/借出/收款/还款` or `债务` type).
      final debtSpec = _matchHaohaoDebt(
        rawType: rawType,
        cat1: cat1,
        cat2: cat2,
        debtor: debtor,
        account: account,
        toAccount: toAccount,
      );
      if (debtSpec != null) {
        if (parsedMoney.abs() <= BigInt.zero) {
          failRows.add(
            ImportFailItem(
              sheetNo: sheet.sheetNo,
              rowNo: rowNo,
              reason: '无法识别的账单金额',
              rawRow: rawRowText,
            ),
          );
          continue;
        }
        final matchedDebt = accountLookup.findDebt(
          debtSpec.debtName,
          debtSpec.debtSubType,
        );
        final matchedFunding = debtSpec.fundingName.isEmpty
            ? null
            : accountLookup.findFunding(debtSpec.fundingName);
        if (!allowUnknown && matchedDebt == null) {
          failRows.add(
            ImportFailItem(
              sheetNo: sheet.sheetNo,
              rowNo: rowNo,
              reason: '借贷对象「${debtSpec.debtName}」不存在，请开启「自动创建缺失账户」或先创建该借贷项目',
              rawRow: rawRowText,
            ),
          );
          continue;
        }
        if (matchedDebt == null) unknownAssetsSet.add(debtSpec.debtName);
        if (debtSpec.fundingName.isNotEmpty && matchedFunding == null) {
          unknownAssetsSet.add(debtSpec.fundingName);
        }

        final fx = _buildHaohaoNonTransferFx(
          moneyMinor: parsedMoney.abs(),
          origMinor: origMinor,
          srcCurr: srcCurr,
          baseCurr: baseCurr,
          rawRate: rawRate,
          discountMinor: null,
          matchedAccountCurrency: _resolvedRefCurrency(matchedFunding),
        );

        final fundingId = matchedFunding?.id ?? noRef;
        final debtId = matchedDebt?.id ?? noRef;
        final isIncoming =
            debtSpec.recordType == RecordType.borrowIn ||
            debtSpec.recordType == RecordType.collect ||
            (debtSpec.recordType == RecordType.debtInterest &&
                debtSpec.subType == RecordDirection.income);

        validRows.add(
          ValidImportRow(
            sheetNo: sheet.sheetNo,
            rowNo: rowNo,
            recordTime: recordTimeMs,
            type: debtSpec.recordType,
            subType: debtSpec.subType,
            moneyMinor: fx.storedMoneyMinor,
            parentCategoryName: '',
            assetName: debtSpec.fundingName,
            debtName: debtSpec.debtName,
            debtSubType: debtSpec.debtSubType,
            resolvedFromAssetId: isIncoming ? debtId : fundingId,
            resolvedToAssetId: isIncoming ? fundingId : debtId,
            bookName: bookName,
            currencyCode: fx.accountCurrencyCode ?? srcCurr,
            explicitCurrencySnapshot: fx.snapshot,
            explicitRateToAnchor: explicitRates.isEmpty ? null : explicitRates,
            remark: remark,
            tags: tags,
            images: imageResult.fileNames,
            embeddedImageBytes: imageResult.imageBytes,
            excludeBudget: excludeBudget,
            excludeExIn: excludeExIn,
          ),
        );
        continue;
      }

      // 2. Check Transfer routing (`转账` / `还款` / `取钱` / `存钱`).
      if (_isHaohaoTransferType(rawType)) {
        final outMinor = (origMinor ?? parsedMoney.abs());
        if (outMinor <= BigInt.zero) {
          failRows.add(
            ImportFailItem(
              sheetNo: sheet.sheetNo,
              rowNo: rowNo,
              reason: '无法识别的账单金额',
              rawRow: rawRowText,
            ),
          );
          continue;
        }
        if (account.isEmpty || toAccount.isEmpty) {
          failRows.add(
            ImportFailItem(
              sheetNo: sheet.sheetNo,
              rowNo: rowNo,
              reason: '转账账单账户不完整：「$account -> $toAccount」',
              rawRow: rawRowText,
            ),
          );
          continue;
        }
        if (account == toAccount) {
          failRows.add(
            ImportFailItem(
              sheetNo: sheet.sheetNo,
              rowNo: rowNo,
              reason: '转账转出与转入账户不能相同：「$account」',
              rawRow: rawRowText,
            ),
          );
          continue;
        }
        final fromAcc = accountLookup.findFunding(account);
        final toAcc = accountLookup.findFunding(toAccount);
        if (!allowUnknown && (fromAcc == null || toAcc == null)) {
          failRows.add(
            ImportFailItem(
              sheetNo: sheet.sheetNo,
              rowNo: rowNo,
              reason: '转账账单账户不完整，建议开启自动创建缺失账户或先创建账户「$account, $toAccount」',
              rawRow: rawRowText,
            ),
          );
          continue;
        }
        if (fromAcc == null) unknownAssetsSet.add(account);
        if (toAcc == null) unknownAssetsSet.add(toAccount);

        final transferSnap = _buildHaohaoTransferSnapshot(
          moneyMinor: parsedMoney.abs(),
          origMinor: origMinor,
          srcCurr: srcCurr ?? _resolvedRefCurrency(fromAcc),
          baseCurr: baseCurr ?? toBaseCurr,
          rawRate: rawRate,
          toMinor: toMinor,
          toCurr: toCurr ?? _resolvedRefCurrency(toAcc),
          rawToRate: rawToRate,
        );

        validRows.add(
          ValidImportRow(
            sheetNo: sheet.sheetNo,
            rowNo: rowNo,
            recordTime: recordTimeMs,
            type: RecordType.transfer,
            moneyMinor: transferSnap.outgoingMinor,
            parentCategoryName: '',
            assetName: account,
            toAssetName: toAccount,
            resolvedFromAssetId: fromAcc?.id ?? noRef,
            resolvedToAssetId: toAcc?.id ?? noRef,
            bookName: bookName,
            currencyCode: srcCurr,
            targetCurrencyCode: toCurr,
            targetMoneyMinor: transferSnap.incomingMinor,
            explicitCurrencySnapshot: transferSnap.snapshot,
            explicitRateToAnchor: explicitRates.isEmpty ? null : explicitRates,
            remark: remark,
            tags: tags,
            images: imageResult.fileNames,
            embeddedImageBytes: imageResult.imageBytes,
            feeMinor: feeMinor,
            excludeBudget: excludeBudget,
            excludeExIn: excludeExIn,
          ),
        );
        continue;
      }

      // 3. Expense / Income / Reimbursable / Standalone Refund.
      final rawIsReimb = cell(binding.isReimburseCol);
      final rawStatus = cell(binding.statusCol);
      final isReimbursable =
          rawType == '报销' ||
          (rawType == '支出' &&
              (_isHaohaoReimbursableFlag(rawIsReimb) ||
                  rawStatus.contains('报销') ||
                  reimburseMinor != null));

      final int recordType;
      var signedMoney = parsedMoney.abs();
      String fallbackCat = '';

      if (isReimbursable) {
        recordType = RecordType.reimbursable;
        fallbackCat = '报销';
      } else if (rawType == '支出') {
        recordType = RecordType.expense;
        if (parsedMoney.isNegative) signedMoney = parsedMoney;
      } else if (rawType == '收入') {
        recordType = RecordType.income;
      } else if (rawType == '退款') {
        recordType = RecordType.expense;
        signedMoney = -parsedMoney.abs();
        fallbackCat = '退款';
      } else {
        failRows.add(
          ImportFailItem(
            sheetNo: sheet.sheetNo,
            rowNo: rowNo,
            reason: '不支持的账单类型：$rawType',
            rawRow: rawRowText,
          ),
        );
        continue;
      }

      if (cat1.isEmpty && cat2.isNotEmpty) {
        cat1 = cat2;
        cat2 = '';
      }
      if (cat1.isEmpty) cat1 = fallbackCat;
      if (cat1.isEmpty) {
        failRows.add(
          ImportFailItem(
            sheetNo: sheet.sheetNo,
            rowNo: rowNo,
            reason: '无法识别的分类名称：',
            rawRow: rawRowText,
          ),
        );
        continue;
      }
      cat1 = truncateRunes(cat1, 16);
      cat2 = truncateRunes(cat2, 16);

      final matchedFunding = account.isEmpty
          ? null
          : accountLookup.findFunding(account);
      if (account.isNotEmpty && matchedFunding == null) {
        unknownAssetsSet.add(account);
      }

      // L-01: Discount applies strictly to non-negative expense & income bills.
      final allowedDiscount =
          (recordType == RecordType.expense ||
                  recordType == RecordType.income) &&
              !signedMoney.isNegative
          ? discountMinor
          : null;

      final fx = _buildHaohaoNonTransferFx(
        moneyMinor: signedMoney,
        origMinor: origMinor,
        srcCurr: srcCurr,
        baseCurr: baseCurr,
        rawRate: rawRate,
        discountMinor: allowedDiscount,
        matchedAccountCurrency: _resolvedRefCurrency(matchedFunding),
      );

      final reimbChildren = <ImportReimburseChildSpec>[];
      if (recordType == RecordType.reimbursable) {
        final effectiveReimb =
            reimburseMinor ??
            (rawStatus == '已报销' && fx.storedMoneyMinor > BigInt.zero
                ? fx.storedMoneyMinor
                : null);
        if (effectiveReimb != null && effectiveReimb > BigInt.zero) {
          final childTime = (reimbDateMs != null && reimbDateMs > recordTimeMs)
              ? reimbDateMs
              : recordTimeMs + 1;
          reimbChildren.add(
            ImportReimburseChildSpec(
              recordTime: childTime,
              moneyMinor: effectiveReimb,
              assetName: account,
              currencyCode: fx.accountCurrencyCode,
              remark: remark,
              tags: tags,
            ),
          );
        }
      }

      final refundChildren = <ImportRefundChildSpec>[];
      if (refundMinor != null && refundMinor > BigInt.zero && rawType != '退款') {
        final childTime = (refundDateMs != null && refundDateMs > recordTimeMs)
            ? refundDateMs
            : recordTimeMs + 1;
        refundChildren.add(
          ImportRefundChildSpec(
            recordTime: childTime,
            moneyMinor: refundMinor,
            assetName: account,
            currencyCode: fx.accountCurrencyCode,
            remark: remark,
            tags: tags,
          ),
        );
      }

      validRows.add(
        ValidImportRow(
          sheetNo: sheet.sheetNo,
          rowNo: rowNo,
          recordTime: recordTimeMs,
          type: recordType,
          moneyMinor: fx.storedMoneyMinor,
          parentCategoryName: cat1,
          subCategoryName: cat2,
          assetName: account,
          resolvedAssetId: recordType == RecordType.reimbursable
              ? noRef
              : (matchedFunding?.id ?? noRef),
          resolvedFromAssetId: recordType == RecordType.reimbursable
              ? (matchedFunding?.id ?? noRef)
              : noRef,
          bookName: bookName,
          currencyCode: fx.accountCurrencyCode ?? srcCurr,
          explicitCurrencySnapshot: fx.snapshot,
          explicitRateToAnchor: explicitRates.isEmpty ? null : explicitRates,
          remark: remark,
          tags: tags,
          images: imageResult.fileNames,
          embeddedImageBytes: imageResult.imageBytes,
          discountMinor: fx.sourceDiscountMinor,
          excludeBudget: excludeBudget,
          excludeExIn: excludeExIn,
          reimburseChildren: reimbChildren,
          refundChildren: refundChildren,
        ),
      );
    }

    if (firstPattern != null) {
      lockedFormats[sheet.sheetNo] = firstPattern;
    }
  }

  if (primaryBinding == null) {
    throw const Failure(FailureCode.validation, '未识别到有效的好好记账表头');
  }

  return SpreadsheetImportAnalysis(
    platformName: haohaoPlatformName,
    hasBookColumn: primaryBinding.hasBookColumn,
    hasCurrencyColumn: primaryBinding.hasCurrencyColumn,
    validRows: validRows,
    failRows: failRows,
    emptyRowCount: emptyRowCount,
    unknownAssets: unknownAssetsSet.toList(growable: false),
    lockedDateFormats: lockedFormats,
    textEncoding: spreadsheet.textEncoding,
    defaultAutoCreateAccounts: true,
  );
}

String? _resolvedRefCurrency(ImportAccountRef? acc) => acc == null
    ? null
    : (normalizeImportCurrencyCode(acc.currency) ?? baseCurrency);

bool _parseHaohaoBool(String raw) {
  final s = raw.trim().toLowerCase();
  return s == '是' ||
      s == '1' ||
      s == 'true' ||
      s == 'yes' ||
      s == 'y' ||
      s == '不计入预算' ||
      s == '不计预算' ||
      s == '不计入收支' ||
      s == '不计收支';
}

bool _isHaohaoReimbursableFlag(String raw) {
  final s = raw.trim().toLowerCase();
  return s == '是' ||
      s == '报销' ||
      s == '可报销' ||
      s == '待报销' ||
      s == '已报销' ||
      s == '1' ||
      s == 'true' ||
      s == 'yes';
}

bool _isHaohaoTransferType(String rawType) => switch (rawType.trim()) {
  '转账' || '还款' || '信用卡还款' || '取钱' || '存钱' => true,
  _ => false,
};

({
  int recordType,
  int subType,
  int debtSubType,
  String debtName,
  String fundingName,
})?
_matchHaohaoDebt({
  required String rawType,
  required String cat1,
  required String cat2,
  required String debtor,
  required String account,
  required String toAccount,
}) {
  final t = rawType.trim();
  String? action;

  if (t == '借入' ||
      t == '债务-借入' ||
      t == '借出' ||
      t == '债务-借出' ||
      t == '收款' ||
      t == '债务-收款' ||
      t == '债务-还款' ||
      t == '利息支出' ||
      t == '债务-利息支出' ||
      t == '利息收入' ||
      t == '债务-利息收入') {
    action = t.replaceFirst('债务-', '');
  } else if (t == '债务' || t == '借贷') {
    for (final candidate in [cat2, cat1]) {
      final c = candidate.trim().replaceFirst('债务-', '');
      if (const {'借入', '借出', '收款', '还款', '利息支出', '利息收入'}.contains(c)) {
        action = c;
        break;
      }
    }
    action ??= '借入';
  } else if (t == '还款' && debtor.isNotEmpty) {
    action = '还款';
  } else if (debtor.isNotEmpty) {
    for (final candidate in [cat2, cat1]) {
      final c = candidate.trim().replaceFirst('债务-', '');
      if (const {'借入', '借出', '收款', '还款', '利息支出', '利息收入'}.contains(c)) {
        action = c;
        break;
      }
    }
  }

  if (action == null) return null;

  final (recType, subType, debtSub) = switch (action) {
    '借入' => (RecordType.borrowIn, RecordDirection.none, AssetType.debtBorrow),
    '借出' => (RecordType.lendOut, RecordDirection.none, AssetType.debtLend),
    '还款' => (RecordType.repay, RecordDirection.none, AssetType.debtBorrow),
    '收款' => (RecordType.collect, RecordDirection.none, AssetType.debtLend),
    '利息支出' => (
      RecordType.debtInterest,
      RecordDirection.expense,
      AssetType.debtBorrow,
    ),
    '利息收入' => (
      RecordType.debtInterest,
      RecordDirection.income,
      AssetType.debtLend,
    ),
    _ => (RecordType.borrowIn, RecordDirection.none, AssetType.debtBorrow),
  };

  final fallbackDebt = debtSub == AssetType.debtBorrow ? '默认借入' : '默认借出';
  final resolvedDebt = debtor.isNotEmpty
      ? debtor
      : (toAccount.isNotEmpty ? toAccount : fallbackDebt);
  final resolvedFunding = account.isNotEmpty
      ? account
      : (debtor.isNotEmpty ? toAccount : '');

  return (
    recordType: recType,
    subType: subType,
    debtSubType: debtSub,
    debtName: resolvedDebt,
    fundingName: resolvedFunding,
  );
}

void _tryCollectAnchorRate(
  Map<String, String> out,
  String? curr,
  String? baseCurr,
  String rawRate,
) {
  if (curr == null || curr == baseCurrency || rawRate.trim().isEmpty) return;
  final b = baseCurr ?? baseCurrency;
  if (b != baseCurrency) return;
  try {
    out.putIfAbsent(curr, () => rateToAnchorFromPrice(rawRate));
  } on Failure {
    // Ignore non-positive or malformed rate hints.
  }
}

BigInt? _multiplyMinorByPrice(BigInt minor, String rawRate) {
  final trimmed = rawRate.trim();
  if (trimmed.isEmpty) return null;
  try {
    final dec = DecimalValue.parse(trimmed);
    if (dec.coefficient <= BigInt.zero) return null;
    return divideRounded(
      minor * dec.coefficient,
      powerOfTen(dec.scale),
      RoundingMode.halfUp,
    );
  } on Failure {
    return null;
  }
}

BigInt? _divideMinorByPrice(BigInt minor, String rawRate) {
  final trimmed = rawRate.trim();
  if (trimmed.isEmpty) return null;
  try {
    final dec = DecimalValue.parse(trimmed);
    if (dec.coefficient <= BigInt.zero) return null;
    return divideRounded(
      minor * powerOfTen(dec.scale),
      dec.coefficient,
      RoundingMode.halfUp,
    );
  } on Failure {
    return null;
  }
}

({
  BigInt storedMoneyMinor,
  BigInt? sourceDiscountMinor,
  String? accountCurrencyCode,
  CurrencySnapshot? snapshot,
})
_buildHaohaoNonTransferFx({
  required BigInt moneyMinor,
  required BigInt? origMinor,
  required String? srcCurr,
  required String? baseCurr,
  required String rawRate,
  required BigInt? discountMinor,
  required String? matchedAccountCurrency,
}) {
  final sign = moneyMinor.isNegative ? -BigInt.one : BigInt.one;
  final absMoney = moneyMinor.abs();
  final sc = srcCurr;
  final bc = baseCurr ?? baseCurrency;
  final matchedAccCurr = normalizeImportCurrencyCode(matchedAccountCurrency);
  final cleanDisc =
      (!sign.isNegative && discountMinor != null && discountMinor > BigInt.zero)
      ? discountMinor
      : null;

  if ((sc == null || sc == baseCurrency) &&
      (matchedAccCurr == null || matchedAccCurr == baseCurrency) &&
      origMinor == null) {
    return (
      storedMoneyMinor: moneyMinor,
      sourceDiscountMinor: cleanDisc,
      accountCurrencyCode: matchedAccCurr ?? sc,
      snapshot: null,
    );
  }

  final effectiveSc = sc ?? matchedAccCurr ?? baseCurrency;
  final srcNet = origMinor ?? absMoney;

  // Determine the settling account's currency:
  // - If an existing account is matched, use its currency.
  // - Else if `origMinor != null && origMinor != absMoney && effectiveSc != bc`,
  //   Haohao converted `原始金额` (`effectiveSc`) into `金额` (`bc` account)!
  // - Otherwise the account itself is denominated in `effectiveSc`.
  final String ac;
  if (matchedAccCurr != null) {
    ac = matchedAccCurr;
  } else if (origMinor != null && origMinor != absMoney && effectiveSc != bc) {
    ac = bc;
  } else {
    ac = effectiveSc;
  }

  // Convert Haohao `原价 - 金额` discount (`cleanDisc`) into `effectiveSc` minor units
  // when `原价`/`金额` were denominated in `bc` while `原始金额` was in `effectiveSc`.
  BigInt? srcDiscMinor;
  BigInt? assetDiscMinor;
  BigInt? baseDiscMinor;
  if (cleanDisc != null) {
    if (effectiveSc != bc && origMinor != null) {
      final convertedSrcDisc =
          _divideMinorByPrice(cleanDisc, rawRate) ??
          (absMoney > BigInt.zero
              ? divideRounded(cleanDisc * srcNet, absMoney, RoundingMode.halfUp)
              : cleanDisc);
      srcDiscMinor = convertedSrcDisc > BigInt.zero ? convertedSrcDisc : null;
      baseDiscMinor = cleanDisc;
      assetDiscMinor = ac == bc
          ? cleanDisc
          : (ac == effectiveSc ? srcDiscMinor : null);
    } else {
      srcDiscMinor = cleanDisc;
      baseDiscMinor = bc == effectiveSc
          ? cleanDisc
          : _multiplyMinorByPrice(cleanDisc, rawRate);
      assetDiscMinor = ac == effectiveSc
          ? cleanDisc
          : (ac == bc ? baseDiscMinor : null);
    }
  }

  final BigInt assetNetAbs;
  if (ac == effectiveSc) {
    assetNetAbs = srcNet;
  } else if (ac == bc && absMoney != srcNet) {
    assetNetAbs = absMoney;
  } else {
    assetNetAbs = _multiplyMinorByPrice(srcNet, rawRate) ?? absMoney;
  }

  final BigInt baseAbs;
  if (bc == ac) {
    baseAbs = assetNetAbs;
  } else if (bc == effectiveSc) {
    baseAbs = srcNet;
  } else {
    baseAbs = _multiplyMinorByPrice(srcNet, rawRate) ?? absMoney;
  }

  if (effectiveSc == baseCurrency && ac == baseCurrency && bc == baseCurrency) {
    return (
      storedMoneyMinor: assetNetAbs * sign,
      sourceDiscountMinor: srcDiscMinor,
      accountCurrencyCode: ac,
      snapshot: null,
    );
  }

  final srcGrossSigned = sign.isNegative
      ? -srcNet
      : (srcNet + (srcDiscMinor ?? BigInt.zero));
  final assetNetSigned = assetNetAbs * sign;
  final baseSigned = baseAbs * sign;

  return (
    storedMoneyMinor: assetNetSigned,
    sourceDiscountMinor: srcDiscMinor,
    accountCurrencyCode: ac,
    snapshot: CurrencySnapshot(
      sourceCode: effectiveSc,
      sourceGross: srcGrossSigned,
      assetCode: ac,
      assetNet: assetNetSigned,
      baseCode: bc,
      baseAmount: baseSigned,
      assetDiscount: assetDiscMinor != null && assetDiscMinor > BigInt.zero
          ? assetDiscMinor
          : null,
      baseDiscount: baseDiscMinor != null && baseDiscMinor > BigInt.zero
          ? baseDiscMinor
          : null,
    ),
  );
}

({BigInt outgoingMinor, BigInt incomingMinor, CurrencySnapshot? snapshot})
_buildHaohaoTransferSnapshot({
  required BigInt moneyMinor,
  required BigInt? origMinor,
  required String? srcCurr,
  required String? baseCurr,
  required String rawRate,
  required BigInt? toMinor,
  required String? toCurr,
  required String rawToRate,
}) {
  final sc = srcCurr ?? baseCurrency;
  final ac = toCurr ?? sc;
  final bc = baseCurr ?? baseCurrency;
  final outMinor = origMinor ?? moneyMinor;
  final inMinor = toMinor ?? (ac == bc ? moneyMinor : outMinor);

  if (sc == baseCurrency && ac == baseCurrency && outMinor == inMinor) {
    return (outgoingMinor: outMinor, incomingMinor: inMinor, snapshot: null);
  }

  final BigInt baseMinor;
  if (sc == bc) {
    baseMinor = outMinor;
  } else if (ac == bc) {
    baseMinor = inMinor;
  } else {
    baseMinor =
        _multiplyMinorByPrice(outMinor, rawRate) ??
        _multiplyMinorByPrice(inMinor, rawToRate) ??
        moneyMinor;
  }

  return (
    outgoingMinor: outMinor,
    incomingMinor: inMinor,
    snapshot: CurrencySnapshot(
      sourceCode: sc,
      sourceGross: outMinor,
      assetCode: ac,
      assetNet: inMinor,
      baseCode: bc,
      baseAmount: baseMinor,
    ),
  );
}
