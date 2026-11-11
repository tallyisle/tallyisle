import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/failure.dart';
import '../../core/money.dart';
import '../../domain/ledger/effects.dart';
import '../../domain/ledger/record_extra.dart';
import '../../domain/ledger/record_relations.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/asset_overview.dart'
    show RateTable, normalizeCurrency;
import '../../domain/rules/csv_excel_codec.dart';
import '../../domain/rules/csv_excel_rules.dart';
import '../db/database.dart';
import '../db/failures.dart';
import '../db/seed.dart';
import '../ledger/ledger_service.dart' show factsOf;

const _uuid = Uuid();

final class CsvImportPreview {
  const CsvImportPreview({
    required this.fileName,
    required this.analysis,
    required this.possibleDuplicateCount,
  });

  final String fileName;
  final SpreadsheetImportAnalysis analysis;

  /// Non-blocking duplicate hint count (R4: consecutive imports are allowed).
  final int possibleDuplicateCount;

  String get platformName => analysis.platformName;
  List<ValidImportRow> get validRows => analysis.validRows;
  List<ImportFailItem> get failRows => analysis.failRows;
  int get emptyRowCount => analysis.emptyRowCount;
  List<String> get unknownAssets => analysis.unknownAssets;
  bool get hasBookColumn => analysis.hasBookColumn;
  bool get hasCurrencyColumn => analysis.hasCurrencyColumn;
  int get totalRecordCount => analysis.totalRecordCount;
}

final class CsvImportCommitResult {
  const CsvImportCommitResult({
    required this.batchId,
    required this.importedBillCount,
    required this.createdCategoryCount,
    required this.createdBookCount,
  });

  final int batchId;
  final int importedBillCount;
  final int createdCategoryCount;
  final int createdBookCount;

  Map<String, Object> toJson() => {
    'batchId': batchId,
    'importedBillCount': importedBillCount,
    'createdCategoryCount': createdCategoryCount,
    'createdBookCount': createdBookCount,
  };

  factory CsvImportCommitResult.fromJson(Map<String, Object?> json) =>
      CsvImportCommitResult(
        batchId: json['batchId'] as int,
        importedBillCount: json['importedBillCount'] as int,
        createdCategoryCount: json['createdCategoryCount'] as int,
        createdBookCount: json['createdBookCount'] as int,
      );
}

final class CsvExportResult {
  const CsvExportResult({
    required this.suggestedFileName,
    required this.bytes,
    required this.exportedCount,
  });

  final String suggestedFileName;
  final Uint8List bytes;
  final int exportedCount;
}

/// Transactional service for CSV / Excel import, batch undo/visibility, and
/// RFC 4180 CSV export (`F-019`, `F-022`, `ADR-009`, `ADR-012`).
final class CsvExcelService {
  CsvExcelService(this.db);
  final AppDatabase db;

  int _now() => db.nowMs();

  Future<T> _command<T>(
    String commandId,
    List<Object?> payload,
    Future<String> Function() body,
    T Function(String resultId) decodeResult,
  ) async {
    if (commandId.isEmpty || commandId.length > 128) {
      throw const Failure(FailureCode.validation, '提交标识无效');
    }
    final hash = sha256.convert(utf8.encode(jsonEncode(payload))).toString();
    return guardDatabase(
      () => db.transaction(() async {
        final previous = await (db.select(
          db.writeCommands,
        )..where((t) => t.commandId.equals(commandId))).getSingleOrNull();
        if (previous != null) {
          if (previous.payloadHash != hash) {
            throw const Failure(FailureCode.conflict, '同一提交标识的内容发生变化');
          }
          return decodeResult(previous.resultId);
        }
        final encoded = await body();
        await db
            .into(db.writeCommands)
            .insert(
              WriteCommandsCompanion.insert(
                commandId: commandId,
                payloadHash: hash,
                resultId: encoded,
                committedAt: _now(),
              ),
            );
        return decodeResult(encoded);
      }),
    );
  }

  /// Parses `.csv` / `.xlsx` / `.xls` bytes, matches converter, validates rows
  /// against existing funding accounts, and computes non-blocking duplicate hints.
  Future<CsvImportPreview> previewImport({
    required String fileName,
    required Uint8List bytes,
    int? targetBookId,
  }) async {
    final decoded = decodeSpreadsheetFile(fileName: fileName, bytes: bytes);
    final fundingAssets = await guardDatabase(
      () => (db.select(
        db.assets,
      )..where((t) => t.type.equals(AssetType.debt).not())).get(),
    );
    final analysis = analyzeSpreadsheetImport(
      spreadsheet: decoded,
      existingAccounts: [
        for (final a in fundingAssets)
          ImportAccountRef(id: a.id, name: a.name, currency: a.currency),
      ],
    );

    var duplicateCount = 0;
    if (analysis.validRows.isNotEmpty) {
      var minTime = analysis.validRows.first.recordTime;
      var maxTime = minTime;
      for (final r in analysis.validRows) {
        if (r.recordTime < minTime) minTime = r.recordTime;
        if (r.recordTime > maxTime) maxTime = r.recordTime;
      }
      final existingRows = await guardDatabase(() {
        final q = db.select(db.records)
          ..where(
            (t) =>
                t.recordTime.isBetweenValues(minTime, maxTime) &
                (targetBookId == null
                    ? const Constant(true)
                    : t.accountBookId.equals(targetBookId)),
          );
        return q.get();
      });
      if (existingRows.isNotEmpty) {
        final keys = <(int, int, BigInt)>{
          for (final er in existingRows)
            (er.recordTime, er.type, er.moneyMinor),
        };
        for (final vr in analysis.validRows) {
          if (keys.contains((vr.recordTime, vr.type, vr.moneyMinor))) {
            duplicateCount++;
          }
        }
      }
    }

    return CsvImportPreview(
      fileName: fileName,
      analysis: analysis,
      possibleDuplicateCount: duplicateCount,
    );
  }

  /// Commits validated [preview] rows atomically in a single transaction:
  /// - Optionally restores/creates missing books from 14/15-col `账本` column (§6.2)
  /// - Auto-creates missing categories (counting `import_category_count`) & tags
  /// - Inserts `import_platform` batch header
  /// - Writes parent records + `type=12` transfer fee children BOTH bound to
  ///   `platform_id = batch.id` (`ASYM-02` fix!)
  /// - Records `CurrencySnapshot` for foreign/cross-currency bills (`ASYM-03` fix!)
  /// - Updates `asset.balance_minor` incrementally via `netEffects` (`ADR-012`)
  Future<CsvImportCommitResult> commitImport({
    required String commandId,
    required CsvImportPreview preview,
    required int selectedBookId,
    bool restoreFileBooks = false,
  }) => _command(
    commandId,
    [
      'csv-commit-import-v1',
      preview.fileName,
      preview.platformName,
      preview.totalRecordCount,
      preview.validRows.length,
      selectedBookId,
      restoreFileBooks,
      if (preview.validRows.isNotEmpty) ...[
        preview.validRows.first.recordTime,
        preview.validRows.first.moneyMinor.toString(),
        preview.validRows.last.recordTime,
        preview.validRows.last.moneyMinor.toString(),
      ],
    ],
    () async {
      if (preview.validRows.isEmpty) {
        throw const Failure(FailureCode.validation, '没有可导入的有效账单记录');
      }

      final now = _now();
      final allBooks = await db.select(db.accountBooks).get();
      final booksById = <int, AccountBook>{for (final b in allBooks) b.id: b};
      final booksByName = <String, int>{
        for (final b in allBooks) b.name.trim(): b.id,
      };
      if (!booksById.containsKey(selectedBookId)) {
        throw const Failure(FailureCode.validation, '目标账本不存在');
      }

      // 1. Resolve target books (auto-creating missing books when `restoreFileBooks` is enabled).
      var maxBookId = 0;
      var maxBookSort = 0;
      for (final b in allBooks) {
        if (b.id > maxBookId) maxBookId = b.id;
        if (b.sort > maxBookSort) maxBookSort = b.sort;
      }
      var createdBookCount = 0;
      final useFileBooks = restoreFileBooks && preview.hasBookColumn;
      final involvedBookIds = <int>{selectedBookId};

      if (useFileBooks) {
        for (final r in preview.validRows) {
          final bName = r.bookName.trim();
          if (bName.isEmpty) continue;
          var bId = booksByName[bName];
          if (bId == null) {
            bId = ++maxBookId;
            final bSort = ++maxBookSort;
            await db
                .into(db.accountBooks)
                .insert(
                  AccountBooksCompanion.insert(
                    id: Value(bId),
                    name: bName,
                    startDay: const Value(1),
                    sort: Value(bSort),
                    createDate: now,
                  ),
                );
            var presetSort = 0;
            for (final (cType, names) in [
              (0, presetExpenseCategories),
              (1, presetIncomeCategories),
            ]) {
              for (final presetName in names) {
                await db
                    .into(db.recordCategories)
                    .insert(
                      RecordCategoriesCompanion.insert(
                        name: presetName,
                        type: cType,
                        sort: Value(presetSort++),
                        accountBookId: bId,
                        parentCatId: const Value(noRef),
                      ),
                    );
              }
            }
            booksByName[bName] = bId;
            createdBookCount++;
          }
          involvedBookIds.add(bId);
        }
      }

      // 2. Load & auto-create categories per target book (`import_category_count`).
      final existingCats = await (db.select(
        db.recordCategories,
      )..where((t) => t.accountBookId.isIn(involvedBookIds.toList()))).get();

      final topLevelCats = <(int, int, String), int>{};
      final subCats = <(int, int, int, String), int>{};
      final anyCats = <(int, int, String), int>{};
      final maxCatSort = <(int, int, int), int>{};

      for (final c in existingCats) {
        final trimmed = c.name.trim();
        final sortKey = (c.accountBookId, c.parentCatId, c.type);
        final curMax = maxCatSort[sortKey] ?? -1;
        if (c.sort > curMax) maxCatSort[sortKey] = c.sort;
        if (c.parentCatId == noRef) {
          topLevelCats.putIfAbsent((
            c.accountBookId,
            c.type,
            trimmed,
          ), () => c.id);
          anyCats[(c.accountBookId, c.type, trimmed)] = c.id;
        } else {
          subCats.putIfAbsent((
            c.accountBookId,
            c.type,
            c.parentCatId,
            trimmed,
          ), () => c.id);
          anyCats.putIfAbsent((c.accountBookId, c.type, trimmed), () => c.id);
        }
      }

      var createdCategoryCount = 0;

      Future<int> ensureCategory({
        required int bookId,
        required int catType,
        required String cat1,
        required String cat2,
      }) async {
        if (cat2.isEmpty) {
          final existingId =
              topLevelCats[(bookId, catType, cat1)] ??
              anyCats[(bookId, catType, cat1)];
          if (existingId != null) return existingId;

          final sortKey = (bookId, noRef, catType);
          final nextSort = (maxCatSort[sortKey] ?? -1) + 1;
          maxCatSort[sortKey] = nextSort;
          final newId = await db
              .into(db.recordCategories)
              .insert(
                RecordCategoriesCompanion.insert(
                  name: cat1,
                  type: catType,
                  sort: Value(nextSort),
                  parentCatId: const Value(noRef),
                  platformId: const Value(noRef),
                  accountBookId: bookId,
                ),
              );
          topLevelCats[(bookId, catType, cat1)] = newId;
          anyCats[(bookId, catType, cat1)] = newId;
          createdCategoryCount++;
          return newId;
        }

        // Two-level category (`一级分类` + `二级分类`)
        var parentId = topLevelCats[(bookId, catType, cat1)];
        if (parentId == null) {
          final pSortKey = (bookId, noRef, catType);
          final pSort = (maxCatSort[pSortKey] ?? -1) + 1;
          maxCatSort[pSortKey] = pSort;
          parentId = await db
              .into(db.recordCategories)
              .insert(
                RecordCategoriesCompanion.insert(
                  name: cat1,
                  type: catType,
                  sort: Value(pSort),
                  parentCatId: const Value(noRef),
                  platformId: const Value(noRef),
                  accountBookId: bookId,
                ),
              );
          topLevelCats[(bookId, catType, cat1)] = parentId;
          anyCats[(bookId, catType, cat1)] = parentId;
          createdCategoryCount++;
        }

        var childId = subCats[(bookId, catType, parentId, cat2)];
        if (childId == null) {
          final cSortKey = (bookId, parentId, catType);
          final cSort = (maxCatSort[cSortKey] ?? -1) + 1;
          maxCatSort[cSortKey] = cSort;
          childId = await db
              .into(db.recordCategories)
              .insert(
                RecordCategoriesCompanion.insert(
                  name: cat2,
                  type: catType,
                  sort: Value(cSort),
                  parentCatId: Value(parentId),
                  platformId: const Value(noRef),
                  accountBookId: bookId,
                ),
              );
          subCats[(bookId, catType, parentId, cat2)] = childId;
          anyCats.putIfAbsent((bookId, catType, cat2), () => childId!);
          createdCategoryCount++;
        }
        return childId;
      }

      // Pre-resolve categories for all valid rows so `createdCategoryCount` is
      // finalized before inserting the `import_platform` batch header!
      final rowBookIds = <int>[];
      final rowCatIds = <int>[];
      for (final r in preview.validRows) {
        final bId = (useFileBooks && r.bookName.trim().isNotEmpty)
            ? (booksByName[r.bookName.trim()] ?? selectedBookId)
            : selectedBookId;
        rowBookIds.add(bId);
        if (r.type == RecordType.transfer) {
          rowCatIds.add(noRef);
        } else {
          final catType = r.type == RecordType.income ? 1 : 0;
          final cId = await ensureCategory(
            bookId: bId,
            catType: catType,
            cat1: r.parentCategoryName,
            cat2: r.subCategoryName,
          );
          rowCatIds.add(cId);
        }
      }

      // 3. Auto-create missing tags (`tag`).
      final neededTagNames = <String>{
        for (final r in preview.validRows) ...r.tags,
      };
      final tagsByName = <String, String>{};
      if (neededTagNames.isNotEmpty) {
        final existingTags = await (db.select(
          db.tags,
        )..where((t) => t.parent.equals(0))).get();
        var maxTagSort = 0;
        for (final t in existingTags) {
          tagsByName.putIfAbsent(t.name.trim(), () => t.tagId);
          if (t.sort > maxTagSort) maxTagSort = t.sort;
        }
        for (final tName in neededTagNames) {
          if (!tagsByName.containsKey(tName)) {
            final newTagId = _uuid.v4();
            await db
                .into(db.tags)
                .insert(
                  TagsCompanion.insert(
                    tagId: newTagId,
                    name: tName,
                    sort: Value(++maxTagSort),
                    hidden: const Value(false),
                    parent: const Value(0),
                  ),
                );
            tagsByName[tName] = newTagId;
          }
        }
      }

      // 4. Insert `import_platform` batch header.
      final batchId = await db
          .into(db.importPlatforms)
          .insert(
            ImportPlatformsCompanion.insert(
              platform: preview.platformName,
              importRecordCount: preview.totalRecordCount,
              importCategoryCount: createdCategoryCount,
              importTime: now,
              hidden: const Value(false),
            ),
          );

      // 5. Load live funding accounts & FX rates inside transaction.
      final liveFundingAssets = await (db.select(
        db.assets,
      )..where((t) => t.type.equals(AssetType.debt).not())).get();
      final assetsByName = <String, Asset>{};
      for (final a in liveFundingAssets) {
        assetsByName.putIfAbsent(a.name.trim(), () => a);
      }

      final currencyRows = await db.select(db.currencies).get();
      final rateMap = <String, String>{
        'CNY': '1',
        for (final c in currencyRows) c.code: c.rateToAnchor,
      };
      final rates = RateTable(rateMap);

      // 6. Construct main records, fee children (`ASYM-02`), tag links, & FX snapshots (`ASYM-03`).
      final allFacts = <EntryFacts>[];
      final recordCompanions = <RecordsCompanion>[];
      final tagCompanions = <TagRecordsCompanion>[];

      for (var i = 0; i < preview.validRows.length; i++) {
        final r = preview.validRows[i];
        final targetBookId = rowBookIds[i];
        final catId = rowCatIds[i];

        final extra = RecordExtra();
        final relations = RecordRelations();
        var assetId = noRef;
        var fromAssetId = noRef;
        var toAssetId = noRef;
        var storedMoneyMinor = r.moneyMinor;
        var feeSourceCurrency = rates.base;

        if (r.type == RecordType.transfer) {
          final fromAsset = assetsByName[r.assetName];
          final toAsset = assetsByName[r.toAssetName];
          if (fromAsset == null ||
              toAsset == null ||
              fromAsset.id == toAsset.id) {
            throw Failure(
              FailureCode.validation,
              '转账账户不存在或不能同名：「${r.assetName} -> ${r.toAssetName}」',
            );
          }
          fromAssetId = fromAsset.id;
          toAssetId = toAsset.id;
          final srcCode = normalizeCurrency(fromAsset.currency) ?? rates.base;
          final dstCode = normalizeCurrency(toAsset.currency) ?? rates.base;
          feeSourceCurrency = srcCode;

          if (srcCode != dstCode) {
            final missing = <String>{};
            final convertedMinor = rates.convert(
              r.moneyMinor,
              srcCode,
              dstCode,
              missing: missing,
            );
            if (missing.isNotEmpty) {
              throw Failure(
                FailureCode.validation,
                '缺少跨币种转账所需汇率（${missing.join(', ')}），请先维护汇率后再导入',
              );
            }
            final baseMinor = rates.convert(r.moneyMinor, srcCode, rates.base);
            extra.currency = CurrencySnapshot(
              sourceCode: srcCode,
              sourceGross: r.moneyMinor,
              assetCode: dstCode,
              assetNet: convertedMinor,
              baseCode: rates.base,
              baseAmount: baseMinor,
            );
          } else if (srcCode != rates.base) {
            final missing = <String>{};
            final baseMinor = rates.convert(
              r.moneyMinor,
              srcCode,
              rates.base,
              missing: missing,
            );
            extra.currency = CurrencySnapshot(
              sourceCode: srcCode,
              sourceGross: r.moneyMinor,
              assetCode: dstCode,
              assetNet: r.moneyMinor,
              baseCode: missing.isEmpty ? rates.base : null,
              baseAmount: missing.isEmpty ? baseMinor : null,
            );
          }
        } else {
          final matchedAsset = r.assetName.isEmpty
              ? null
              : assetsByName[r.assetName];
          assetId = matchedAsset?.id ?? noRef;
          final assetCurr = normalizeCurrency(matchedAsset?.currency);
          final rowCurr = normalizeCurrency(r.currencyCode);
          final srcCurr = rowCurr ?? assetCurr ?? rates.base;
          final dstCurr = assetCurr ?? srcCurr;

          if (srcCurr != dstCurr) {
            final missing = <String>{};
            final convertedNet = rates.convert(
              r.moneyMinor,
              srcCurr,
              dstCurr,
              missing: missing,
            );
            if (missing.isNotEmpty) {
              throw Failure(
                FailureCode.validation,
                '缺少外币账单折算汇率（${missing.join(', ')}），请先维护汇率后再导入',
              );
            }
            final baseMinor = rates.convert(r.moneyMinor, srcCurr, rates.base);
            storedMoneyMinor = convertedNet;
            extra.currency = CurrencySnapshot(
              sourceCode: srcCurr,
              sourceGross: r.moneyMinor + (r.discountMinor ?? BigInt.zero),
              assetCode: dstCurr,
              assetNet: convertedNet,
              baseCode: rates.base,
              baseAmount: baseMinor,
            );
          } else if (srcCurr != rates.base) {
            final missing = <String>{};
            final baseMinor = rates.convert(
              r.moneyMinor,
              srcCurr,
              rates.base,
              missing: missing,
            );
            extra.currency = CurrencySnapshot(
              sourceCode: srcCurr,
              sourceGross: r.moneyMinor + (r.discountMinor ?? BigInt.zero),
              assetCode: matchedAsset != null ? dstCurr : null,
              assetNet: matchedAsset != null ? r.moneyMinor : null,
              baseCode: missing.isEmpty ? rates.base : null,
              baseAmount: missing.isEmpty ? baseMinor : null,
            );
          }
        }

        final hasFee =
            r.type == RecordType.transfer && r.feeMinor > BigInt.zero;
        if (hasFee) {
          relations.transferFee = const TransferFeeLink(feeFromTarget: false);
        }

        final mainId = _uuid.v4();
        final mainCompanion = RecordsCompanion(
          recordId: Value(mainId),
          type: Value(r.type),
          subType: const Value(RecordDirection.none),
          moneyMinor: Value(storedMoneyMinor),
          remark: Value(r.remark),
          recordTime: Value(r.recordTime),
          recordCatId: Value(catId),
          assetId: Value(assetId),
          fromAssetId: Value(fromAssetId),
          toAssetId: Value(toAssetId),
          accountBookId: Value(targetBookId),
          excludeBudget: Value(r.excludeBudget),
          excludeExIn: Value(r.excludeExIn),
          platformId: Value(batchId),
          periodId: const Value(noRef),
          images: Value(r.images.isEmpty ? null : r.images.join(',')),
          discountMinor: Value(r.discountMinor),
          extraInfo: Value(extra.encode()),
          relInfo: Value(relations.encode()),
          createDate: Value(now),
        );
        recordCompanions.add(mainCompanion);
        allFacts.add(
          EntryFacts(
            type: r.type,
            subType: RecordDirection.none,
            moneyMinor: storedMoneyMinor,
            assetId: assetId,
            fromAssetId: fromAssetId,
            toAssetId: toAssetId,
            currency: extra.currency,
          ),
        );

        for (final tName in r.tags) {
          final tid = tagsByName[tName];
          if (tid != null) {
            tagCompanions.add(
              TagRecordsCompanion.insert(tagId: tid, recordId: mainId),
            );
          }
        }

        // R5 / ASYM-02: Transfer fee child (`type = 12`, `record_time = parent + 1ms`)
        // MUST bind `platformId = batchId` so batch undo deletes & refunds it!
        if (hasFee) {
          final feeId = _uuid.v4();
          final feeRel = RecordRelations()
            ..transferFee = TransferFeeLink(
              feeFromTarget: false,
              parentId: mainId,
            );
          final feeExtra = RecordExtra();
          if (feeSourceCurrency != rates.base) {
            final missing = <String>{};
            final feeBase = rates.convert(
              r.feeMinor,
              feeSourceCurrency,
              rates.base,
              missing: missing,
            );
            feeExtra.currency = CurrencySnapshot(
              sourceCode: feeSourceCurrency,
              sourceGross: r.feeMinor,
              assetCode: feeSourceCurrency,
              assetNet: r.feeMinor,
              baseCode: missing.isEmpty ? rates.base : null,
              baseAmount: missing.isEmpty ? feeBase : null,
            );
          }
          final feeCompanion = RecordsCompanion(
            recordId: Value(feeId),
            type: const Value(RecordType.fee),
            subType: const Value(RecordDirection.expense),
            moneyMinor: Value(r.feeMinor),
            remark: Value(r.remark),
            recordTime: Value(r.recordTime + 1),
            recordCatId: const Value(noRef),
            assetId: Value(fromAssetId),
            fromAssetId: const Value(noRef),
            toAssetId: const Value(noRef),
            accountBookId: Value(targetBookId),
            excludeBudget: Value(r.excludeBudget),
            excludeExIn: Value(r.excludeExIn),
            platformId: Value(batchId),
            periodId: const Value(noRef),
            extraInfo: Value(feeExtra.encode()),
            relInfo: Value(feeRel.encode()),
            createDate: Value(now),
          );
          recordCompanions.add(feeCompanion);
          allFacts.add(
            EntryFacts(
              type: RecordType.fee,
              subType: RecordDirection.expense,
              moneyMinor: r.feeMinor,
              assetId: fromAssetId,
              currency: feeExtra.currency,
            ),
          );
          for (final tName in r.tags) {
            final tid = tagsByName[tName];
            if (tid != null) {
              tagCompanions.add(
                TagRecordsCompanion.insert(tagId: tid, recordId: feeId),
              );
            }
          }
        }
      }

      // 7. Atomically apply account balance deltas & persist rows.
      await _applyNet(netEffects(after: allFacts));
      await _touchAssets(allFacts);

      await db.batch((b) {
        b.insertAll(db.records, recordCompanions);
        if (tagCompanions.isNotEmpty) {
          b.insertAll(
            db.tagRecords,
            tagCompanions,
            mode: InsertMode.insertOrIgnore,
          );
        }
      });

      final commitResult = CsvImportCommitResult(
        batchId: batchId,
        importedBillCount: preview.validRows.length,
        createdCategoryCount: createdCategoryCount,
        createdBookCount: createdBookCount,
      );
      return jsonEncode(commitResult.toJson());
    },
    (encoded) => CsvImportCommitResult.fromJson(
      jsonDecode(encoded) as Map<String, Object?>,
    ),
  );

  /// Undoes an import batch atomically (R7):
  /// - Selects ONLY live existing records for [batchId] (`ASYM-01`: already-deleted
  ///   bills are never double-refunded!)
  /// - Reverses balances symmetrically via `netEffects(before: ...)` including
  ///   `type = 12` fee children (`ASYM-02`) and FX `CurrencySnapshot` (`ASYM-03`)
  /// - Physically deletes `tag_record`, `record`, and `import_platform` in one transaction
  /// - Preserves manual `platform_id = -1` bills, other batches, and created categories/tags
  Future<void> undoBatch({
    required String commandId,
    required int batchId,
  }) => _command(commandId, ['csv-undo-batch-v1', batchId], () async {
    final batch = await (db.select(
      db.importPlatforms,
    )..where((t) => t.id.equals(batchId))).getSingleOrNull();
    if (batch == null) {
      throw const Failure(FailureCode.validation, '导入批次不存在或已撤销');
    }

    final batchRows = await (db.select(
      db.records,
    )..where((t) => t.platformId.equals(batchId))).get();

    final rowsById = <String, LedgerRecord>{
      for (final r in batchRows) r.recordId: r,
    };

    // Also sweep any live fee child or refund/reimbursement child linked to
    // a batch record whose `platform_id` might be `-1` after post-import edits.
    final transferIds = <String>[
      for (final r in batchRows)
        if (r.type == RecordType.transfer) r.recordId,
    ];
    for (final chunk in _chunks(transferIds, 400)) {
      final placeholders = List.filled(chunk.length, '?').join(',');
      final extraFees = await db
          .customSelect(
            'SELECT * FROM record WHERE type = ? '
            "AND json_extract(rel_info, '\$.ltfeei.tfobid') IN ($placeholders)",
            variables: [
              Variable.withInt(RecordType.fee),
              for (final id in chunk) Variable.withString(id),
            ],
          )
          .get();
      for (final row in extraFees) {
        final rec = db.records.map(row.data);
        rowsById.putIfAbsent(rec.recordId, () => rec);
      }
    }

    final linkedChildIds = <String>[];
    for (final r in batchRows) {
      final rel = RecordRelations.parse(r.relInfo);
      for (final c in rel.refunds?.children ?? const <LinkedBill>[]) {
        if (!rowsById.containsKey(c.billId)) linkedChildIds.add(c.billId);
      }
      for (final c in rel.reimbursements?.children ?? const <LinkedBill>[]) {
        if (!rowsById.containsKey(c.billId)) linkedChildIds.add(c.billId);
      }
    }
    for (final chunk in _chunks(linkedChildIds, 400)) {
      final children = await (db.select(
        db.records,
      )..where((t) => t.recordId.isIn(chunk))).get();
      for (final c in children) {
        rowsById.putIfAbsent(c.recordId, () => c);
      }
    }

    final allRowsToReverse = rowsById.values.toList(growable: false);
    if (allRowsToReverse.isNotEmpty) {
      await _applyNet(netEffects(before: allRowsToReverse.map(factsOf)));
      final allIds = [for (final r in allRowsToReverse) r.recordId];
      for (final chunk in _chunks(allIds, 400)) {
        await (db.delete(
          db.tagRecords,
        )..where((t) => t.recordId.isIn(chunk))).go();
        await (db.delete(
          db.records,
        )..where((t) => t.recordId.isIn(chunk))).go();
      }
    }

    await (db.delete(
      db.importPlatforms,
    )..where((t) => t.id.equals(batchId))).go();
    return '$batchId';
  }, (_) {});

  /// Moves a batch into or out of the hidden list (`import_platform.hidden`).
  Future<void> setBatchHidden({
    required String commandId,
    required int batchId,
    required bool hidden,
  }) => _command(
    commandId,
    ['csv-set-batch-hidden-v1', batchId, hidden],
    () async {
      final existing = await (db.select(
        db.importPlatforms,
      )..where((t) => t.id.equals(batchId))).getSingleOrNull();
      if (existing == null) {
        throw const Failure(FailureCode.validation, '导入批次不存在');
      }
      await (db.update(db.importPlatforms)..where((t) => t.id.equals(batchId)))
          .write(ImportPlatformsCompanion(hidden: Value(hidden)));
      return '$batchId';
    },
    (_) {},
  );

  /// Exports bills (`type IN (0, 1, 2)`) matching optional [bookId] and
  /// `[startMs, endMs]` as RFC 4180 CSV in UTF-8+BOM (default) or GBK (R8).
  Future<CsvExportResult> exportCsv({
    int? bookId,
    int? startMs,
    int? endMs,
    bool includeCurrency = true,
    bool utf8WithBom = true,
  }) async {
    if (startMs != null && endMs != null && startMs > endMs) {
      throw const Failure(FailureCode.validation, '开始时间不能晚于结束时间');
    }

    return guardDatabase(() async {
      final query = db.select(db.records)
        ..where((t) {
          Expression<bool> cond = t.type.isIn(const [
            RecordType.expense,
            RecordType.income,
            RecordType.transfer,
          ]);
          if (bookId != null && bookId != noRef) {
            cond = cond & t.accountBookId.equals(bookId);
          }
          if (startMs != null) {
            cond = cond & t.recordTime.isBiggerOrEqualValue(startMs);
          }
          if (endMs != null) {
            cond = cond & t.recordTime.isSmallerOrEqualValue(endMs);
          }
          return cond;
        })
        ..orderBy([
          (t) => OrderingTerm.desc(t.recordTime),
          (t) => OrderingTerm.desc(t.createDate),
          (t) => OrderingTerm.desc(t.recordId),
        ]);

      final records = await query.get();
      final books = await db.select(db.accountBooks).get();
      final categories = await db.select(db.recordCategories).get();
      final assets = await db.select(db.assets).get();
      final tags = await db.select(db.tags).get();

      final booksById = <int, AccountBook>{for (final b in books) b.id: b};
      final catsById = <int, RecordCategory>{
        for (final c in categories) c.id: c,
      };
      final assetsById = <int, Asset>{for (final a in assets) a.id: a};
      final tagNamesById = <String, String>{
        for (final t in tags) t.tagId: t.name,
      };

      // Load tag links & transfer fee children for the selected records.
      final tagsByRecordId = <String, List<String>>{};
      final feeByParentId = <String, BigInt>{};

      final recIds = [for (final r in records) r.recordId];
      for (final chunk in _chunks(recIds, 400)) {
        final trRows = await (db.select(
          db.tagRecords,
        )..where((t) => t.recordId.isIn(chunk))).get();
        for (final tr in trRows) {
          final name = tagNamesById[tr.tagId];
          if (name != null && name.isNotEmpty) {
            (tagsByRecordId[tr.recordId] ??= <String>[]).add(name);
          }
        }
      }

      final transferIds = [
        for (final r in records)
          if (r.type == RecordType.transfer) r.recordId,
      ];
      for (final chunk in _chunks(transferIds, 400)) {
        final placeholders = List.filled(chunk.length, '?').join(',');
        final feeRows = await db
            .customSelect(
              'SELECT money_minor, '
              "json_extract(rel_info, '\$.ltfeei.tfobid') AS parent_id "
              'FROM record WHERE type = ? '
              "AND json_extract(rel_info, '\$.ltfeei.tfobid') IN ($placeholders)",
              variables: [
                Variable.withInt(RecordType.fee),
                for (final id in chunk) Variable.withString(id),
              ],
            )
            .get();
        for (final row in feeRows) {
          final parentId = row.read<String?>('parent_id');
          final feeMinor = row.read<BigInt>('money_minor');
          if (parentId != null && feeMinor > BigInt.zero) {
            feeByParentId[parentId] = feeMinor;
          }
        }
      }

      final exportInputs = <CsvExportRowInput>[];
      for (final r in records) {
        final bookName = booksById[r.accountBookId]?.name ?? '';
        var parentCat = '';
        var subCat = '';
        if (r.type != RecordType.transfer && r.recordCatId != noRef) {
          final cat = catsById[r.recordCatId];
          if (cat != null) {
            if (cat.parentCatId == noRef) {
              parentCat = cat.name;
            } else {
              final parent = catsById[cat.parentCatId];
              if (parent != null) {
                parentCat = parent.name;
                subCat = cat.name;
              } else {
                parentCat = cat.name;
              }
            }
          }
        }

        final extra = RecordExtra.parse(r.extraInfo);
        final currSnap = extra.currency;
        String currencyCode;
        var exportMoneyMinor = r.moneyMinor;
        if (r.type == RecordType.transfer) {
          currencyCode =
              currSnap?.sourceCode ??
              normalizeCurrency(assetsById[r.fromAssetId]?.currency) ??
              'CNY';
        } else {
          currencyCode =
              currSnap?.sourceCode ??
              normalizeCurrency(assetsById[r.assetId]?.currency) ??
              'CNY';
          if (currSnap != null &&
              currSnap.isValid &&
              currSnap.assetCode != null &&
              currSnap.sourceCode != currSnap.assetCode) {
            // Restore original source-currency net amount when bill was cross-currency converted.
            exportMoneyMinor =
                currSnap.sourceGross - (r.discountMinor ?? BigInt.zero);
          }
        }

        final acc1 = r.type == RecordType.transfer
            ? (assetsById[r.fromAssetId]?.name ?? '')
            : (assetsById[r.assetId]?.name ?? '');
        final acc2 = r.type == RecordType.transfer
            ? (assetsById[r.toAssetId]?.name ?? '')
            : '';

        exportInputs.add(
          CsvExportRowInput(
            recordTimeMs: r.recordTime,
            type: r.type,
            bookName: bookName,
            parentCategoryName: parentCat,
            subCategoryName: subCat,
            moneyMinor: exportMoneyMinor,
            currencyCode: currencyCode,
            accountName: acc1,
            targetAccountName: acc2,
            remark: r.remark,
            tags: tagsByRecordId[r.recordId] ?? const [],
            feeMinor: feeByParentId[r.recordId] ?? BigInt.zero,
            discountMinor: r.discountMinor,
            excludeBudget: r.excludeBudget,
            excludeExIn: r.excludeExIn,
          ),
        );
      }

      final rows = buildCsvExportRows(
        exportInputs,
        includeCurrency: includeCurrency,
      );
      final bytes = encodeCsvBytes(rows, utf8WithBom: utf8WithBom);

      final nowDt = DateTime.fromMillisecondsSinceEpoch(_now());
      String two(int v) => v.toString().padLeft(2, '0');
      final stamp =
          '${nowDt.year}-${two(nowDt.month)}-${two(nowDt.day)}-'
          '${two(nowDt.hour)}${two(nowDt.minute)}${two(nowDt.second)}';

      return CsvExportResult(
        suggestedFileName: 'TallyIsle_export_$stamp.csv',
        bytes: bytes,
        exportedCount: exportInputs.length,
      );
    });
  }

  Future<void> _applyNet(Map<int, BigInt> net) async {
    for (final entry in net.entries) {
      final asset = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(entry.key))).getSingleOrNull();
      if (asset == null || asset.type == AssetType.debt) continue;
      final balance = Money.minor(asset.balanceMinor + entry.value);
      await (db.update(db.assets)..where((t) => t.id.equals(entry.key))).write(
        AssetsCompanion(balanceMinor: Value(balance.storageMinor)),
      );
    }
  }

  Future<void> _touchAssets(Iterable<EntryFacts> facts) async {
    final counts = <int, int>{};
    for (final f in facts) {
      for (final id in [f.assetId, f.fromAssetId, f.toAssetId]) {
        if (id != noRef) {
          counts[id] = (counts[id] ?? 0) + 1;
        }
      }
    }
    for (final entry in counts.entries) {
      await db.customUpdate(
        'UPDATE asset SET used_times = used_times + ?1 WHERE id = ?2',
        variables: [Variable.withInt(entry.value), Variable.withInt(entry.key)],
        updates: {db.assets},
      );
    }
  }

  static Iterable<List<T>> _chunks<T>(List<T> items, int size) sync* {
    for (var i = 0; i < items.length; i += size) {
      final end = i + size < items.length ? i + size : items.length;
      yield items.sublist(i, end);
    }
  }
}
