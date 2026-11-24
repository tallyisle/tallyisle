import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../core/failure.dart';
import '../../core/money.dart';
import '../../domain/ledger/asset_json.dart';
import '../../domain/ledger/effects.dart';
import '../../domain/ledger/record_extra.dart';
import '../../domain/ledger/record_relations.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/asset_overview.dart'
    show RateTable, normalizeCurrency;
import '../../domain/rules/bank_icon_catalog.dart';
import '../../domain/rules/csv_excel_codec.dart';
import '../../domain/rules/csv_excel_rules.dart';
import '../../domain/rules/currency_rates.dart'
    show baseCurrency, defaultCurrencySymbol, findWorldCurrency;
import '../../domain/rules/debt_rules.dart';
import '../../domain/rules/qianji_import_rules.dart';
import '../db/database.dart';
import '../db/failures.dart';
import '../db/seed.dart';
import '../ledger/ledger_service.dart' show factsOf;
import '../tools/bill_attachment_service.dart';

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
  bool get defaultAutoCreateAccounts => analysis.defaultAutoCreateAccounts;
  int get totalRecordCount => analysis.totalRecordCount;
}

final class CsvImportCommitResult {
  const CsvImportCommitResult({
    required this.batchId,
    required this.importedBillCount,
    required this.createdCategoryCount,
    required this.createdBookCount,
    this.createdAccountCount = 0,
  });

  final int batchId;
  final int importedBillCount;
  final int createdCategoryCount;
  final int createdBookCount;
  final int createdAccountCount;

  Map<String, Object> toJson() => {
    'batchId': batchId,
    'importedBillCount': importedBillCount,
    'createdCategoryCount': createdCategoryCount,
    'createdBookCount': createdBookCount,
    'createdAccountCount': createdAccountCount,
  };

  factory CsvImportCommitResult.fromJson(Map<String, Object?> json) =>
      CsvImportCommitResult(
        batchId: json['batchId'] as int,
        importedBillCount: json['importedBillCount'] as int,
        createdCategoryCount: json['createdCategoryCount'] as int,
        createdBookCount: json['createdBookCount'] as int,
        createdAccountCount: (json['createdAccountCount'] as int?) ?? 0,
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

/// Transactional service for CSV / Excel / JSON / ZIP import, batch undo/visibility,
/// and RFC 4180 CSV export (`F-019`, `F-022`, `ADR-009`, `ADR-012`).
final class CsvExcelService {
  CsvExcelService(
    this.db, {
    Future<Directory> Function()? attachmentsDirectoryProvider,
  }) : _attachmentService = BillAttachmentService(
         db,
         attachmentsDirectoryProvider: attachmentsDirectoryProvider,
       ),
       _attachmentsDirProvider =
           attachmentsDirectoryProvider ??
           BillAttachmentService.defaultAttachmentsDirectory;

  final AppDatabase db;
  final BillAttachmentService _attachmentService;
  final Future<Directory> Function() _attachmentsDirProvider;

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

  /// Parses `.csv` / `.xlsx` / `.xls` / `.json` / `.zip` bytes, matches converter,
  /// validates rows against existing accounts, and computes non-blocking duplicate hints.
  Future<CsvImportPreview> previewImport({
    required String fileName,
    required Uint8List bytes,
    int? targetBookId,
    bool? autoCreateMissingAccounts,
  }) async {
    guardImportFileBytes(bytes);

    final ext = extractFileExtension(fileName);
    if (!const {'csv', 'xlsx', 'xls', 'json', 'zip'}.contains(ext)) {
      throw const Failure(
        FailureCode.validation,
        '不支持的文件格式，仅支持 .csv、.xlsx、.xls、.json、.zip',
      );
    }

    final allAssets = await guardDatabase(() => db.select(db.assets).get());
    final existingAccountRefs = [
      for (final a in allAssets)
        ImportAccountRef(
          id: a.id,
          name: a.name,
          currency: a.currency,
          type: a.type,
          subType: a.subType,
        ),
    ];

    final SpreadsheetImportAnalysis analysis;
    switch (ext) {
      case 'json':
        final decodedText = decodeSmartText(bytes);
        analysis = analyzeQianjiJsonImport(
          jsonText: decodedText.text,
          existingAccounts: existingAccountRefs,
          textEncoding: decodedText.encoding,
          allowUnknownTransferAccounts: autoCreateMissingAccounts,
        );
      case 'zip':
        final bundle = extractZipSpreadsheetBundle(bytes);
        if (bundle.tableExtension == 'json') {
          final decodedText = decodeSmartText(bundle.tableBytes);
          analysis = analyzeQianjiJsonImport(
            jsonText: decodedText.text,
            existingAccounts: existingAccountRefs,
            textEncoding: decodedText.encoding,
            bundleImageResolver: bundle.resolveImage,
            allowUnknownTransferAccounts: autoCreateMissingAccounts,
          );
        } else {
          final decoded = decodeSpreadsheetFile(
            fileName: bundle.tableFileName,
            bytes: bundle.tableBytes,
          );
          final xlsxImages = bundle.tableExtension == 'xlsx'
              ? extractXlsxEmbeddedImagesBySheetAndRow(bundle.tableBytes)
              : const <int, Map<int, List<Uint8List>>>{};
          analysis = analyzeSpreadsheetImport(
            spreadsheet: decoded,
            existingAccounts: existingAccountRefs,
            xlsxEmbeddedImagesBySheet: xlsxImages,
            bundleImageResolver: bundle.resolveImage,
            allowUnknownTransferAccounts: autoCreateMissingAccounts,
          );
        }
      case 'xlsx':
        final decoded = decodeSpreadsheetFile(fileName: fileName, bytes: bytes);
        final xlsxImages = extractXlsxEmbeddedImagesBySheetAndRow(bytes);
        analysis = analyzeSpreadsheetImport(
          spreadsheet: decoded,
          existingAccounts: existingAccountRefs,
          xlsxEmbeddedImagesBySheet: xlsxImages,
          allowUnknownTransferAccounts: autoCreateMissingAccounts,
        );
      default:
        final decoded = decodeSpreadsheetFile(fileName: fileName, bytes: bytes);
        analysis = analyzeSpreadsheetImport(
          spreadsheet: decoded,
          existingAccounts: existingAccountRefs,
          allowUnknownTransferAccounts: autoCreateMissingAccounts,
        );
    }

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
  /// - Optionally restores/creates missing books from `账本` column
  /// - Optionally auto-creates missing funding/credit/debt accounts (`autoCreateMissingAccounts`)
  /// - Saves embedded `.xlsx`/`.zip` images via [BillAttachmentService.saveImageBytes]
  /// - Writes parent records + `type=12` fee children + `type=15` reimburseReceipt children
  ///   + negative refund children (`lrefundi`), ALL bound to `platform_id = batch.id`
  /// - Updates `asset.balance_minor` incrementally via `netEffects` and recomputes debt `LoanInfo`
  Future<CsvImportCommitResult> commitImport({
    required String commandId,
    required CsvImportPreview preview,
    required int selectedBookId,
    bool restoreFileBooks = false,
    bool? autoCreateMissingAccounts,
  }) {
    final effectiveAutoCreate =
        autoCreateMissingAccounts ?? preview.defaultAutoCreateAccounts;
    return _command(
      commandId,
      [
        'csv-commit-import-v2',
        preview.fileName,
        preview.platformName,
        preview.totalRecordCount,
        preview.validRows.length,
        selectedBookId,
        restoreFileBooks,
        effectiveAutoCreate,
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

        final rowBookIds = <int>[];
        final rowCatIds = <int>[];
        for (final r in preview.validRows) {
          final bId = (useFileBooks && r.bookName.trim().isNotEmpty)
              ? (booksByName[r.bookName.trim()] ?? selectedBookId)
              : selectedBookId;
          rowBookIds.add(bId);
          if (_isCategorylessType(r.type)) {
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

        // 3. Auto-create missing tags (`tag`), including tags on child specs.
        final neededTagNames = <String>{
          for (final r in preview.validRows) ...[
            ...r.tags,
            for (final c in r.reimburseChildren) ...c.tags,
            for (final c in r.refundChildren) ...c.tags,
          ],
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

        // 5. Load live accounts & FX rates, seeding explicit file rates if missing.
        final currencyRows = await db.select(db.currencies).get();
        final rateMap = <String, String>{
          baseCurrency: '1',
          for (final c in currencyRows)
            if (normalizeCurrency(c.code) != null)
              normalizeCurrency(c.code)!: c.rateToAnchor,
        };
        for (final r in preview.validRows) {
          final explicit = r.explicitRateToAnchor;
          if (explicit == null) continue;
          for (final entry in explicit.entries) {
            final code = normalizeCurrency(entry.key);
            if (code == null ||
                code == baseCurrency ||
                rateMap.containsKey(code)) {
              continue;
            }
            rateMap[code] = entry.value;
            final worldSpec = findWorldCurrency(code);
            await db
                .into(db.currencies)
                .insert(
                  CurrenciesCompanion.insert(
                    code: code,
                    name: worldSpec?.name ?? code,
                    symbol: defaultCurrencySymbol(code),
                    rateToAnchor: entry.value,
                    anchorCode: baseCurrency,
                    rateRefreshTime: Value(now),
                    enable: const Value(true),
                  ),
                  mode: InsertMode.insertOrIgnore,
                );
          }
        }
        final rates = RateTable(rateMap);

        final allLiveAssets = await db.select(db.assets).get();
        final fundingByName = <String, Asset>{};
        final debtByName = <String, Asset>{};
        final debtByNameAndSub = <(String, int), Asset>{};
        var maxAssetSort = 0;
        var minDebtSort = 0;
        for (final a in allLiveAssets) {
          if (a.sort > maxAssetSort) maxAssetSort = a.sort;
          if (a.sort < minDebtSort) minDebtSort = a.sort;
          final trimmed = a.name.trim();
          if (trimmed.isEmpty) continue;
          if (a.type == AssetType.debt) {
            debtByName.putIfAbsent(trimmed, () => a);
            debtByNameAndSub.putIfAbsent((trimmed, a.subType), () => a);
          } else {
            fundingByName.putIfAbsent(trimmed, () => a);
          }
        }

        // Pre-infer foreign currency for missing funding/debt accounts across the batch.
        final inferredFundingCurrencies = _inferNewAccountCurrencies(
          preview.validRows,
        );
        final debtMinTimeByKey = <(String, int), int>{};
        final debtBooksByKey = <(String, int), Set<int>>{};
        final debtCurrencyByKey = <(String, int), String?>{};

        for (var i = 0; i < preview.validRows.length; i++) {
          final r = preview.validRows[i];
          if (!_isDebtRecordType(r.type) || r.debtName.trim().isEmpty) continue;
          final dKey = (r.debtName.trim(), r.debtSubType);
          final prevMin = debtMinTimeByKey[dKey];
          if (prevMin == null || r.recordTime < prevMin) {
            debtMinTimeByKey[dKey] = r.recordTime;
          }
          (debtBooksByKey[dKey] ??= <int>{}).add(rowBookIds[i]);
          final rowCurr =
              normalizeCurrency(r.explicitCurrencySnapshot?.sourceCode) ??
              normalizeCurrency(r.currencyCode);
          if (rowCurr != null && rowCurr != baseCurrency) {
            debtCurrencyByKey.putIfAbsent(dKey, () => rowCurr);
          }
        }

        var createdAccountCount = 0;
        final newlyCreatedDebtIds = <int>{};
        final affectedDebtIds = <int>{};

        Future<Asset> ensureFundingAccount(String rawName) async {
          final name = truncateRunes(rawName.trim(), 50);
          final existing = fundingByName[name];
          if (existing != null) return existing;

          final assetType = _inferAutoCreatedFundingType(name);
          final instMatch = matchReviewedInstitution(
            name,
            assetType: assetType,
          );
          final iconKey =
              instMatch?.iconKey ??
              (assetType == AssetType.credit
                  ? 'builtin:type.credit_card'
                  : (name.contains('现金')
                        ? 'builtin:type.cash'
                        : 'builtin:type.other_account'));
          final colorHex =
              instMatch?.colorHex ??
              (assetType == AssetType.credit ? '#9C27B0' : null);
          final inferredCurr = inferredFundingCurrencies[name];
          final storedCurr =
              (inferredCurr != null && inferredCurr != baseCurrency)
              ? inferredCurr
              : null;

          final newId = await db
              .into(db.assets)
              .insert(
                AssetsCompanion.insert(
                  name: name,
                  balanceMinor: BigInt.zero,
                  initMoneyMinor: BigInt.zero,
                  type: assetType,
                  subType: const Value(noRef),
                  createDate: now,
                  sort: Value(++maxAssetSort),
                  icon: Value(iconKey),
                  color: Value(colorHex),
                  isEffectiveAsset: const Value(1),
                  status: const Value(AssetStatus.active),
                  creditInfo: Value(
                    assetType == AssetType.credit
                        ? CreditInfo().encode()
                        : null,
                  ),
                  currency: Value(storedCurr),
                ),
              );
          final created = await (db.select(
            db.assets,
          )..where((t) => t.id.equals(newId))).getSingle();
          fundingByName[name] = created;
          createdAccountCount++;
          return created;
        }

        Future<Asset?> resolveFundingOrNull(String rawName) async {
          final name = rawName.trim();
          if (name.isEmpty) return null;
          final existing =
              fundingByName[name] ?? fundingByName[truncateRunes(name, 50)];
          if (existing != null) return existing;
          if (!effectiveAutoCreate) return null;
          return ensureFundingAccount(name);
        }

        Future<Asset> resolveDebtAccount(
          String rawName,
          int debtSubType,
          int rowBookId,
          int rowTimeMs,
        ) async {
          final name = truncateRunes(rawName.trim(), 50);
          final sub = debtSubType == AssetType.debtLend
              ? AssetType.debtLend
              : AssetType.debtBorrow;
          final existing = debtByNameAndSub[(name, sub)] ?? debtByName[name];
          if (existing != null) {
            affectedDebtIds.add(existing.id);
            final existingBindings = await (db.select(
              db.assetBooks,
            )..where((t) => t.assetId.equals(existing.id))).get();
            if (existingBindings.isNotEmpty &&
                !existingBindings.any((b) => b.bookId == rowBookId)) {
              await db
                  .into(db.assetBooks)
                  .insertOnConflictUpdate(
                    AssetBooksCompanion.insert(
                      assetId: existing.id,
                      bookId: rowBookId,
                    ),
                  );
            }
            return existing;
          }

          if (!effectiveAutoCreate) {
            throw Failure(
              FailureCode.validation,
              '借贷对象「$name」不存在，请开启「自动创建缺失账户」或先创建该借贷项目',
            );
          }

          final dKey = (rawName.trim(), debtSubType);
          final minTime = debtMinTimeByKey[dKey] ?? rowTimeMs;
          final books = debtBooksByKey[dKey] ?? {rowBookId};
          final dCurr = debtCurrencyByKey[dKey];
          final initialLoan = LoanInfo(
            schemaVersion: 2,
            startDate: minTime,
            endDate: noRef,
            totalDebtMoneyMinor: BigInt.zero,
            manualSettled: false,
            positionsUpdatedAtMs: now,
          );

          final newId = await db
              .into(db.assets)
              .insert(
                AssetsCompanion.insert(
                  name: name,
                  balanceMinor: BigInt.zero,
                  initMoneyMinor: BigInt.zero,
                  type: AssetType.debt,
                  subType: Value(sub),
                  createDate: now,
                  sort: Value(--minDebtSort),
                  status: const Value(AssetStatus.active),
                  isEffectiveAsset: Value(
                    debtEffectiveAssetFlag(countedInNetWorth: true),
                  ),
                  currency: Value(dCurr),
                  loanInfo: Value(initialLoan.encode()),
                ),
              );
          for (final bId in books) {
            await db
                .into(db.assetBooks)
                .insertOnConflictUpdate(
                  AssetBooksCompanion.insert(assetId: newId, bookId: bId),
                );
          }
          final created = await (db.select(
            db.assets,
          )..where((t) => t.id.equals(newId))).getSingle();
          debtByNameAndSub[(name, sub)] = created;
          debtByName.putIfAbsent(name, () => created);
          newlyCreatedDebtIds.add(newId);
          affectedDebtIds.add(newId);
          createdAccountCount++;
          return created;
        }

        Future<String?> persistRowImages(
          List<String> fileNames,
          List<Uint8List> embeddedBytes,
        ) async {
          if (fileNames.isEmpty && embeddedBytes.isEmpty) return null;
          final finalNames = <String>[];
          final seen = <String>{};
          for (final bytes in embeddedBytes) {
            if (bytes.isEmpty) continue;
            final saved = await _attachmentService.saveImageBytes(bytes: bytes);
            if (seen.add(saved)) {
              finalNames.add(saved);
              if (finalNames.length >= maxBillImages) break;
            }
          }
          if (finalNames.length < maxBillImages) {
            for (final rawName in fileNames) {
              try {
                final safe = validateAttachmentFileName(rawName);
                if (seen.add(safe)) {
                  finalNames.add(safe);
                  if (finalNames.length >= maxBillImages) break;
                }
              } on Failure {
                // Skip invalid non-local filenames.
              }
            }
          }
          return encodeRecordImages(finalNames);
        }

        // 6. Construct main records, fee children (`type=12`), reimburseReceipt children (`type=15`),
        //    and negative refund children (`lrefundi`), ALL bound to `platformId = batchId`.
        final allFacts = <EntryFacts>[];
        final recordCompanions = <RecordsCompanion>[];
        final tagCompanions = <TagRecordsCompanion>[];

        void addTagsFor(String recId, List<String> tagNames) {
          for (final tName in tagNames) {
            final tid = tagsByName[tName];
            if (tid != null) {
              tagCompanions.add(
                TagRecordsCompanion.insert(tagId: tid, recordId: recId),
              );
            }
          }
        }

        for (var i = 0; i < preview.validRows.length; i++) {
          final r = preview.validRows[i];
          final targetBookId = rowBookIds[i];
          final catId = rowCatIds[i];

          final extra = RecordExtra();
          final relations = RecordRelations();
          var assetId = noRef;
          var fromAssetId = noRef;
          var toAssetId = noRef;
          var storedSubType = r.subType;
          var storedMoneyMinor = r.moneyMinor;
          // L-01: Discount applies strictly to non-negative expense & income bills.
          final effectiveDiscountMinor =
              (r.type == RecordType.expense || r.type == RecordType.income) &&
                  !r.moneyMinor.isNegative &&
                  r.discountMinor != null &&
                  r.discountMinor! > BigInt.zero
              ? r.discountMinor
              : null;
          var feeSourceCurrency = rates.base;
          var isCreditRepayTransfer = false;
          var parentAccountCurrency = rates.base;

          if (r.type == RecordType.transfer) {
            final fromAsset = await resolveFundingOrNull(r.assetName);
            final toAsset = await resolveFundingOrNull(r.toAssetName);
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
            isCreditRepayTransfer = toAsset.type == AssetType.credit;

            final srcCode = normalizeCurrency(fromAsset.currency) ?? rates.base;
            final dstCode = normalizeCurrency(toAsset.currency) ?? rates.base;
            feeSourceCurrency = srcCode;
            parentAccountCurrency = srcCode;

            if (r.explicitCurrencySnapshot != null &&
                r.explicitCurrencySnapshot!.isValid) {
              extra.currency = r.explicitCurrencySnapshot;
              storedMoneyMinor = r.explicitCurrencySnapshot!.sourceGross;
            } else if (srcCode != dstCode) {
              final BigInt convertedMinor;
              if (r.targetMoneyMinor != null &&
                  r.targetMoneyMinor! > BigInt.zero) {
                convertedMinor = r.targetMoneyMinor!;
              } else {
                final missing = <String>{};
                convertedMinor = rates.convert(
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
              }
              final baseMinor = srcCode == rates.base
                  ? r.moneyMinor
                  : dstCode == rates.base
                  ? convertedMinor
                  : rates.convert(r.moneyMinor, srcCode, rates.base);
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
          } else if (_isDebtRecordType(r.type)) {
            final debtAsset = await resolveDebtAccount(
              r.debtName,
              r.debtSubType,
              targetBookId,
              r.recordTime,
            );
            final fundingAsset = await resolveFundingOrNull(r.assetName);
            final fundingId = fundingAsset?.id ?? noRef;

            if (r.type == RecordType.debtInterest) {
              final spec = buildInterestRecordSpec(
                debtSubType: debtAsset.subType,
                debtId: debtAsset.id,
                fundingAssetId: fundingId,
                interestExcludeBudget: r.excludeBudget,
              );
              storedSubType = spec.subType;
              fromAssetId = spec.fromAssetId;
              toAssetId = spec.toAssetId;
            } else {
              final isRepay =
                  r.type == RecordType.repay || r.type == RecordType.collect;
              final spec = buildPrincipalRecordSpec(
                debtSubType: debtAsset.subType,
                debtId: debtAsset.id,
                fundingAssetId: fundingId,
                isRepayment: isRepay,
              );
              storedSubType = spec.subType;
              fromAssetId = spec.fromAssetId;
              toAssetId = spec.toAssetId;
            }

            final debtCurr = _assetCurrencyOrNull(debtAsset)!;
            final fundCurr = _assetCurrencyOrNull(fundingAsset);
            final rowCurr = normalizeCurrency(r.currencyCode);
            final srcCurr = rowCurr ?? debtCurr;
            final dstCurr = fundCurr ?? srcCurr;
            parentAccountCurrency = dstCurr;

            if (r.explicitCurrencySnapshot != null &&
                r.explicitCurrencySnapshot!.isValid) {
              extra.currency = r.explicitCurrencySnapshot;
              storedMoneyMinor =
                  r.explicitCurrencySnapshot!.assetNet ?? r.moneyMinor;
            } else if (srcCurr != dstCurr) {
              final missing = <String>{};
              final converted = rates.convert(
                r.moneyMinor,
                srcCurr,
                dstCurr,
                missing: missing,
              );
              if (missing.isNotEmpty) {
                throw Failure(
                  FailureCode.validation,
                  '缺少外币借贷折算汇率（${missing.join(', ')}），请先维护汇率后再导入',
                );
              }
              final baseMinor = rates.convert(
                r.moneyMinor,
                srcCurr,
                rates.base,
              );
              storedMoneyMinor = converted;
              extra.currency = CurrencySnapshot(
                sourceCode: srcCurr,
                sourceGross: r.moneyMinor,
                assetCode: dstCurr,
                assetNet: converted,
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
                sourceGross: r.moneyMinor,
                assetCode: dstCurr,
                assetNet: r.moneyMinor,
                baseCode: missing.isEmpty ? rates.base : null,
                baseAmount: missing.isEmpty ? baseMinor : null,
              );
            }
          } else {
            // `expense (0)`, `income (1)`, `reimbursable (3)`
            final matchedAsset = await resolveFundingOrNull(r.assetName);
            if (r.type == RecordType.reimbursable) {
              // CRITICAL: `RecordType.reimbursable (3)` deducts from `fromAssetId` (`effects.dart:80`).
              assetId = noRef;
              fromAssetId = matchedAsset?.id ?? noRef;
            } else {
              assetId = matchedAsset?.id ?? noRef;
            }

            final assetCurr = _assetCurrencyOrNull(matchedAsset);
            final rowCurr = normalizeCurrency(r.currencyCode);
            final srcCurr = rowCurr ?? assetCurr ?? rates.base;
            final dstCurr = assetCurr ?? srcCurr;
            parentAccountCurrency = dstCurr;

            if (r.explicitCurrencySnapshot != null &&
                r.explicitCurrencySnapshot!.isValid) {
              extra.currency = r.explicitCurrencySnapshot;
            } else {
              final sign = r.moneyMinor.isNegative ? -BigInt.one : BigInt.one;
              final absMoney = r.moneyMinor.abs();
              final disc = effectiveDiscountMinor ?? BigInt.zero;

              if (srcCurr != dstCurr) {
                final missing = <String>{};
                final convertedNet = rates.convert(
                  absMoney,
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
                final baseMinor = rates.convert(absMoney, srcCurr, rates.base);
                storedMoneyMinor = convertedNet * sign;
                extra.currency = CurrencySnapshot(
                  sourceCode: srcCurr,
                  sourceGross: sign.isNegative ? -absMoney : (absMoney + disc),
                  assetCode: dstCurr,
                  assetNet: convertedNet * sign,
                  baseCode: rates.base,
                  baseAmount: baseMinor * sign,
                );
              } else if (srcCurr != rates.base) {
                final missing = <String>{};
                final baseMinor = rates.convert(
                  absMoney,
                  srcCurr,
                  rates.base,
                  missing: missing,
                );
                extra.currency = CurrencySnapshot(
                  sourceCode: srcCurr,
                  sourceGross: sign.isNegative ? -absMoney : (absMoney + disc),
                  assetCode: matchedAsset != null ? dstCurr : null,
                  assetNet: matchedAsset != null ? r.moneyMinor : null,
                  baseCode: missing.isEmpty ? rates.base : null,
                  baseAmount: missing.isEmpty ? baseMinor * sign : null,
                );
              }
            }
          }

          final hasFee =
              r.type == RecordType.transfer && r.feeMinor > BigInt.zero;
          if (hasFee) {
            relations.transferFee = TransferFeeLink(
              feeFromTarget: false,
              repay: isCreditRepayTransfer,
            );
          }

          final mainId = _uuid.v4();
          final mainImagesEncoded = await persistRowImages(
            r.images,
            r.embeddedImageBytes,
          );

          // Pre-build linked reimbursement receipt (`type=15`) & negative refund (`lrefundi`) children
          // so parent `rel_info` carries their `LinkedBill` entries in a single batch insert!
          final childCompanions = <RecordsCompanion>[];
          final childFacts = <EntryFacts>[];

          if (r.type == RecordType.reimbursable &&
              r.reimburseChildren.isNotEmpty) {
            final reimbLinks = <LinkedBill>[];
            var minNextMs = r.recordTime + 1;
            for (final child in r.reimburseChildren) {
              if (child.moneyMinor <= BigInt.zero) continue;
              final effAssetName = child.assetName.isNotEmpty
                  ? child.assetName
                  : r.assetName;
              final childAsset = await resolveFundingOrNull(effAssetName);
              final childAssetId = childAsset?.id ?? noRef;
              final childAssetCurr = _assetCurrencyOrNull(childAsset);
              final childSrcCurr =
                  normalizeCurrency(child.currencyCode) ??
                  childAssetCurr ??
                  parentAccountCurrency;
              final childAccCurr = childAssetCurr ?? childSrcCurr;

              var storedChildMoney = child.moneyMinor;
              CurrencySnapshot? childSnap;
              if (childSrcCurr != childAccCurr) {
                final missing = <String>{};
                storedChildMoney = rates.convert(
                  child.moneyMinor,
                  childSrcCurr,
                  childAccCurr,
                  missing: missing,
                );
                if (missing.isNotEmpty) {
                  throw Failure(
                    FailureCode.validation,
                    '缺少外币报销收款折算汇率（${missing.join(', ')}），请先维护汇率后再导入',
                  );
                }
                final cBase = rates.convert(
                  child.moneyMinor,
                  childSrcCurr,
                  rates.base,
                );
                childSnap = CurrencySnapshot(
                  sourceCode: childSrcCurr,
                  sourceGross: child.moneyMinor,
                  assetCode: childAccCurr,
                  assetNet: storedChildMoney,
                  baseCode: rates.base,
                  baseAmount: cBase,
                );
              } else if (childAccCurr != rates.base) {
                final missing = <String>{};
                final cBase = rates.convert(
                  child.moneyMinor,
                  childAccCurr,
                  rates.base,
                  missing: missing,
                );
                childSnap = CurrencySnapshot(
                  sourceCode: childAccCurr,
                  sourceGross: child.moneyMinor,
                  assetCode: childAsset != null ? childAccCurr : null,
                  assetNet: childAsset != null ? storedChildMoney : null,
                  baseCode: missing.isEmpty ? rates.base : null,
                  baseAmount: missing.isEmpty ? cBase : null,
                );
              }

              final childTime = child.recordTime < minNextMs
                  ? minNextMs
                  : child.recordTime;
              minNextMs = childTime + 1;
              final childId = _uuid.v4();
              final childImages = await persistRowImages(
                child.images,
                child.embeddedImageBytes,
              );
              final childExtra = RecordExtra()..currency = childSnap;
              final childRel = RecordRelations()
                ..reimbursements = BillLinks(originId: mainId);

              childCompanions.add(
                RecordsCompanion(
                  recordId: Value(childId),
                  type: const Value(RecordType.reimburseReceipt),
                  subType: const Value(RecordDirection.income),
                  moneyMinor: Value(storedChildMoney),
                  remark: Value(
                    child.remark.isNotEmpty ? child.remark : r.remark,
                  ),
                  recordTime: Value(childTime),
                  recordCatId: Value(catId),
                  assetId: Value(childAssetId),
                  fromAssetId: const Value(noRef),
                  toAssetId: const Value(noRef),
                  accountBookId: Value(targetBookId),
                  excludeBudget: Value(r.excludeBudget),
                  excludeExIn: Value(r.excludeExIn),
                  platformId: Value(batchId),
                  periodId: const Value(noRef),
                  images: Value(childImages),
                  extraInfo: Value(childExtra.encode()),
                  relInfo: Value(childRel.encode()),
                  createDate: Value(now),
                ),
              );
              childFacts.add(
                EntryFacts(
                  type: RecordType.reimburseReceipt,
                  subType: RecordDirection.income,
                  moneyMinor: storedChildMoney,
                  assetId: childAssetId,
                  currency: childSnap,
                ),
              );
              addTagsFor(childId, child.tags.isNotEmpty ? child.tags : r.tags);
              reimbLinks.add(
                LinkedBill(
                  billId: childId,
                  amount: storedChildMoney,
                  assetCode: childSnap?.assetCode,
                  assetAmount: childSnap?.assetNet,
                  baseCode: childSnap?.baseCode,
                  baseAmount: childSnap?.baseAmount,
                ),
              );
            }
            if (reimbLinks.isNotEmpty) {
              relations.reimbursements = BillLinks(children: reimbLinks);
            }
          }

          if ((r.type == RecordType.expense ||
                  r.type == RecordType.income ||
                  r.type == RecordType.reimbursable) &&
              r.refundChildren.isNotEmpty) {
            final refundLinks = <LinkedBill>[];
            var minNextMs = r.recordTime + 1;
            final childType = r.type == RecordType.income
                ? RecordType.income
                : RecordType.expense;

            for (final child in r.refundChildren) {
              final refundMag = child.moneyMinor.abs();
              if (refundMag <= BigInt.zero) continue;
              final effAssetName = child.assetName.isNotEmpty
                  ? child.assetName
                  : r.assetName;
              final childAsset = await resolveFundingOrNull(effAssetName);
              final childAssetId = childAsset?.id ?? noRef;
              final childAssetCurr = _assetCurrencyOrNull(childAsset);
              final childSrcCurr =
                  normalizeCurrency(child.currencyCode) ??
                  childAssetCurr ??
                  parentAccountCurrency;
              final childAccCurr = childAssetCurr ?? childSrcCurr;

              var storedRefundMag = refundMag;
              CurrencySnapshot? childSnap;
              if (childSrcCurr != childAccCurr) {
                final missing = <String>{};
                storedRefundMag = rates.convert(
                  refundMag,
                  childSrcCurr,
                  childAccCurr,
                  missing: missing,
                );
                if (missing.isNotEmpty) {
                  throw Failure(
                    FailureCode.validation,
                    '缺少外币退款折算汇率（${missing.join(', ')}），请先维护汇率后再导入',
                  );
                }
                final cBase = rates.convert(
                  refundMag,
                  childSrcCurr,
                  rates.base,
                );
                childSnap = CurrencySnapshot(
                  sourceCode: childSrcCurr,
                  sourceGross: -refundMag,
                  assetCode: childAccCurr,
                  assetNet: -storedRefundMag,
                  baseCode: rates.base,
                  baseAmount: -cBase,
                );
              } else if (childAccCurr != rates.base) {
                final missing = <String>{};
                final cBase = rates.convert(
                  refundMag,
                  childAccCurr,
                  rates.base,
                  missing: missing,
                );
                childSnap = CurrencySnapshot(
                  sourceCode: childAccCurr,
                  sourceGross: -refundMag,
                  assetCode: childAsset != null ? childAccCurr : null,
                  assetNet: childAsset != null ? -storedRefundMag : null,
                  baseCode: missing.isEmpty ? rates.base : null,
                  baseAmount: missing.isEmpty ? -cBase : null,
                );
              }

              final childTime = child.recordTime < minNextMs
                  ? minNextMs
                  : child.recordTime;
              minNextMs = childTime + 1;
              final childId = _uuid.v4();
              final childImages = await persistRowImages(
                child.images,
                child.embeddedImageBytes,
              );
              final childExtra = RecordExtra()..currency = childSnap;
              final childRel = RecordRelations()
                ..refunds = BillLinks(originId: mainId);

              childCompanions.add(
                RecordsCompanion(
                  recordId: Value(childId),
                  type: Value(childType),
                  subType: const Value(RecordDirection.none),
                  moneyMinor: Value(-storedRefundMag),
                  remark: Value(
                    child.remark.isNotEmpty ? child.remark : r.remark,
                  ),
                  recordTime: Value(childTime),
                  recordCatId: Value(catId),
                  assetId: Value(childAssetId),
                  fromAssetId: const Value(noRef),
                  toAssetId: const Value(noRef),
                  accountBookId: Value(targetBookId),
                  excludeBudget: Value(r.excludeBudget),
                  excludeExIn: Value(r.excludeExIn),
                  platformId: Value(batchId),
                  periodId: const Value(noRef),
                  images: Value(childImages),
                  extraInfo: Value(childExtra.encode()),
                  relInfo: Value(childRel.encode()),
                  createDate: Value(now),
                ),
              );
              childFacts.add(
                EntryFacts(
                  type: childType,
                  subType: RecordDirection.none,
                  moneyMinor: -storedRefundMag,
                  assetId: childAssetId,
                  currency: childSnap,
                ),
              );
              addTagsFor(childId, child.tags.isNotEmpty ? child.tags : r.tags);
              refundLinks.add(
                LinkedBill(
                  billId: childId,
                  amount: storedRefundMag,
                  assetCode: childSnap?.assetCode,
                  assetAmount: childSnap?.assetNet?.abs(),
                  baseCode: childSnap?.baseCode,
                  baseAmount: childSnap?.baseAmount?.abs(),
                ),
              );
            }
            if (refundLinks.isNotEmpty) {
              relations.refunds = BillLinks(children: refundLinks);
            }
          }

          final mainCompanion = RecordsCompanion(
            recordId: Value(mainId),
            type: Value(r.type),
            subType: Value(storedSubType),
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
            images: Value(mainImagesEncoded),
            discountMinor: Value(effectiveDiscountMinor),
            extraInfo: Value(extra.encode()),
            relInfo: Value(relations.encode()),
            createDate: Value(now),
          );
          recordCompanions.add(mainCompanion);
          allFacts.add(
            EntryFacts(
              type: r.type,
              subType: storedSubType,
              moneyMinor: storedMoneyMinor,
              assetId: assetId,
              fromAssetId: fromAssetId,
              toAssetId: toAssetId,
              currency: extra.currency,
            ),
          );
          addTagsFor(mainId, r.tags);

          recordCompanions.addAll(childCompanions);
          allFacts.addAll(childFacts);

          // Transfer fee child (`type = 12`, `record_time = parent + 1ms`) bound to `platformId = batchId`.
          if (hasFee) {
            final feeId = _uuid.v4();
            final feeRel = RecordRelations()
              ..transferFee = TransferFeeLink(
                feeFromTarget: false,
                repay: isCreditRepayTransfer,
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
            addTagsFor(feeId, r.tags);
          }
        }

        // 7. Atomically apply account balance deltas, persist rows, and recompute affected debts.
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

        for (final debtId in affectedDebtIds) {
          await _recomputeDebtAccount(
            debtId,
            rates: rates,
            nowMs: now,
            updateInitMoney: newlyCreatedDebtIds.contains(debtId),
          );
        }

        final commitResult = CsvImportCommitResult(
          batchId: batchId,
          importedBillCount:
              preview.validRows.length + preview.analysis.mergedChildRowCount,
          createdCategoryCount: createdCategoryCount,
          createdBookCount: createdBookCount,
          createdAccountCount: createdAccountCount,
        );
        return jsonEncode(commitResult.toJson());
      },
      (encoded) => CsvImportCommitResult.fromJson(
        jsonDecode(encoded) as Map<String, Object?>,
      ),
    );
  }

  /// Undoes an import batch atomically (R7):
  /// - Selects ONLY live existing records for [batchId] (`ASYM-01`) + linked children (`type=12`, `type=15`, refund)
  /// - Reverses balances symmetrically via `netEffects(before: ...)`
  /// - Physically deletes `tag_record`, `record`, and `import_platform` in one transaction
  /// - Recomputes `LoanInfo` / `balanceMinor` / `status` for any affected debt projects
  /// - Removes unreferenced attachment files created by the batch from `<support>/attachments/`
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

    // Sweep any live fee child or refund/reimbursement child linked to a batch record.
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
    final candidateAttachments = collectReferencedAttachmentNames([
      for (final r in allRowsToReverse) r.images,
    ]);
    final candidateDebtAssetIds = <int>{};
    for (final r in allRowsToReverse) {
      if (_isDebtRecordType(r.type)) {
        if (r.fromAssetId != noRef) candidateDebtAssetIds.add(r.fromAssetId);
        if (r.toAssetId != noRef) candidateDebtAssetIds.add(r.toAssetId);
      }
    }

    if (allRowsToReverse.isNotEmpty) {
      // Unlink from any surviving parent outside this batch before deleting.
      for (final r in allRowsToReverse) {
        final rel = RecordRelations.parse(r.relInfo);
        final rfOrigin = rel.refunds?.originId;
        if (rfOrigin != null &&
            rfOrigin.isNotEmpty &&
            !rowsById.containsKey(rfOrigin)) {
          await _unlinkChildFromSurvivingParent(
            parentId: rfOrigin,
            childId: r.recordId,
            isRefund: true,
          );
        }
        final riOrigin = rel.reimbursements?.originId;
        if (riOrigin != null &&
            riOrigin.isNotEmpty &&
            !rowsById.containsKey(riOrigin)) {
          await _unlinkChildFromSurvivingParent(
            parentId: riOrigin,
            childId: r.recordId,
            isRefund: false,
          );
        }
      }

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

    if (candidateDebtAssetIds.isNotEmpty) {
      final currencyRows = await db.select(db.currencies).get();
      final rates = RateTable({
        baseCurrency: '1',
        for (final c in currencyRows) c.code: c.rateToAnchor,
      });
      final now = _now();
      for (final assetId in candidateDebtAssetIds) {
        final asset = await (db.select(
          db.assets,
        )..where((t) => t.id.equals(assetId))).getSingleOrNull();
        if (asset != null && asset.type == AssetType.debt) {
          await _recomputeDebtAccount(
            asset.id,
            rates: rates,
            nowMs: now,
            allowReopen: true,
          );
        }
      }
    }

    if (candidateAttachments.isNotEmpty) {
      await _deleteUnreferencedBatchAttachments(candidateAttachments);
    }

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

  Future<void> _recomputeDebtAccount(
    int debtId, {
    required RateTable rates,
    required int nowMs,
    bool allowReopen = false,
    bool updateInitMoney = false,
  }) async {
    final debt = await (db.select(
      db.assets,
    )..where((t) => t.id.equals(debtId))).getSingleOrNull();
    if (debt == null || debt.type != AssetType.debt) return;

    final rows = await db
        .customSelect(
          'SELECT * FROM record '
          'WHERE (from_asset_id = ?1 OR to_asset_id = ?1) '
          'AND type IN (5, 6, 7, 8) '
          'ORDER BY record_time ASC, create_date ASC, record_id ASC',
          variables: [Variable.withInt(debtId)],
        )
        .get();
    final entries = [
      for (final row in rows)
        () {
          final rec = db.records.map(row.data);
          return DebtRecordEntry(
            recordId: rec.recordId,
            type: rec.type,
            subType: rec.subType,
            moneyMinor: rec.moneyMinor,
            recordTime: rec.recordTime,
            currency: RecordExtra.parse(rec.extraInfo).currency,
          );
        }(),
    ];

    final currentInfo = LoanInfo.parse(debt.loanInfo);
    final result = recomputeDebtPrincipal(
      debtSubType: debt.subType,
      currentStatus: debt.status,
      currentLoanInfo: currentInfo,
      records: entries,
      debtCurrency: debt.currency,
      rates: rates,
      allowReopen: allowReopen,
      nowMs: nowMs,
    );

    await (db.update(db.assets)..where((t) => t.id.equals(debtId))).write(
      AssetsCompanion(
        balanceMinor: Value(result.balanceMinor),
        initMoneyMinor: updateInitMoney
            ? Value(result.totalPrincipalMinor)
            : const Value.absent(),
        status: Value(result.status),
        loanInfo: Value(result.loanInfo.encode()),
      ),
    );
  }

  Future<void> _unlinkChildFromSurvivingParent({
    required String parentId,
    required String childId,
    required bool isRefund,
  }) async {
    final parent = await (db.select(
      db.records,
    )..where((t) => t.recordId.equals(parentId))).getSingleOrNull();
    if (parent == null) return;
    final rel = RecordRelations.parse(parent.relInfo);
    if (isRefund) {
      final cur = rel.refunds;
      if (cur == null) return;
      rel.refunds = BillLinks(
        children: [
          for (final c in cur.children)
            if (c.billId != childId) c,
        ],
        originId: cur.originId,
      );
    } else {
      final cur = rel.reimbursements;
      if (cur == null) return;
      rel.reimbursements = BillLinks(
        children: [
          for (final c in cur.children)
            if (c.billId != childId) c,
        ],
        originId: cur.originId,
      );
    }
    await (db.update(db.records)..where((t) => t.recordId.equals(parentId)))
        .write(RecordsCompanion(relInfo: Value(rel.encode())));
  }

  Future<void> _deleteUnreferencedBatchAttachments(
    Set<String> candidateNames,
  ) async {
    final recRows = await db
        .customSelect(
          "SELECT images FROM record WHERE images IS NOT NULL AND TRIM(images) != ''",
        )
        .get();
    final periodRows = await db
        .customSelect(
          "SELECT images FROM record_period WHERE images IS NOT NULL AND TRIM(images) != ''",
        )
        .get();
    final instRows = await db
        .customSelect(
          "SELECT images FROM installment WHERE images IS NOT NULL AND TRIM(images) != ''",
        )
        .get();
    final stillReferenced = collectReferencedAttachmentNames([
      for (final r in recRows) r.read<String?>('images'),
      for (final r in periodRows) r.read<String?>('images'),
      for (final r in instRows) r.read<String?>('images'),
    ]);

    final dir = await _attachmentsDirProvider();
    if (!await dir.exists()) return;
    final canonicalRoot = p.normalize(dir.absolute.path);

    for (final name in candidateNames) {
      if (stillReferenced.contains(name)) continue;
      try {
        final safe = validateAttachmentFileName(name);
        final filePath = p.normalize(p.join(canonicalRoot, safe));
        if (p.dirname(filePath) != canonicalRoot) continue;
        final file = File(filePath);
        if (await file.exists()) {
          await file.delete();
        }
      } on Object {
        // Ignore individual filesystem cleanup errors after DB commit.
      }
    }
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

  static String? _assetCurrencyOrNull(Asset? asset) => asset == null
      ? null
      : (normalizeCurrency(asset.currency) ?? baseCurrency);

  static bool _isDebtRecordType(int type) =>
      type == RecordType.borrowIn ||
      type == RecordType.lendOut ||
      type == RecordType.repay ||
      type == RecordType.collect ||
      type == RecordType.debtInterest;

  static bool _isCategorylessType(int type) =>
      type == RecordType.transfer || _isDebtRecordType(type);

  static int _inferAutoCreatedFundingType(String name) {
    final lower = name.toLowerCase();
    if (name.contains('信用卡') ||
        name.contains('贷记卡') ||
        name.contains('花呗') ||
        name.contains('白条') ||
        name.contains('信用付') ||
        name.contains('月付') ||
        lower.contains('credit card') ||
        lower.contains('huabei') ||
        lower.contains('baitiao')) {
      return AssetType.credit;
    }
    return AssetType.normal;
  }

  static Map<String, String> _inferNewAccountCurrencies(
    List<ValidImportRow> rows,
  ) {
    final seenByAcc = <String, Set<String>>{};
    void observe(String rawName, String? rawCurr) {
      final name = truncateRunes(rawName.trim(), 50);
      final code = normalizeCurrency(rawCurr);
      if (name.isEmpty || code == null) return;
      (seenByAcc[name] ??= <String>{}).add(code);
    }

    for (final r in rows) {
      if (r.type == RecordType.transfer) {
        observe(
          r.assetName,
          r.explicitCurrencySnapshot?.sourceCode ?? r.currencyCode,
        );
        observe(
          r.toAssetName,
          r.explicitCurrencySnapshot?.assetCode ??
              r.targetCurrencyCode ??
              r.currencyCode,
        );
      } else {
        observe(
          r.assetName,
          r.explicitCurrencySnapshot?.assetCode ?? r.currencyCode,
        );
        for (final c in r.reimburseChildren) {
          observe(c.assetName, c.currencyCode);
        }
        for (final c in r.refundChildren) {
          observe(c.assetName, c.currencyCode);
        }
      }
    }

    final resolved = <String, String>{};
    for (final entry in seenByAcc.entries) {
      if (entry.value.length == 1) {
        resolved[entry.key] = entry.value.first;
      }
    }
    return resolved;
  }

  static Iterable<List<T>> _chunks<T>(List<T> items, int size) sync* {
    for (var i = 0; i < items.length; i += size) {
      final end = i + size < items.length ? i + size : items.length;
      yield items.sublist(i, end);
    }
  }
}
