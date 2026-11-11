import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../../core/failure.dart';
import '../../core/money.dart';
import '../../domain/rules/budget_rules.dart' show BudgetExtra, BudgetTypeCode;
import '../../domain/rules/category_transfer_rules.dart';
import '../../platform/files.dart';
import '../db/database.dart';
import '../db/failures.dart';

export '../../domain/rules/category_transfer_rules.dart';

/// Result of importing a category JSON pack or copying categories across books (F-031).
final class CategoryMergeResult {
  const CategoryMergeResult({
    required this.addedTopCount,
    required this.addedSubCount,
    required this.skippedDuplicateCount,
  });

  final int addedTopCount;
  final int addedSubCount;
  final int skippedDuplicateCount;

  int get totalAddedCount => addedTopCount + addedSubCount;

  Map<String, Object> toJson() => {
    'addedTopCount': addedTopCount,
    'addedSubCount': addedSubCount,
    'skippedDuplicateCount': skippedDuplicateCount,
  };

  factory CategoryMergeResult.fromJson(Map<String, Object?> json) =>
      CategoryMergeResult(
        addedTopCount: (json['addedTopCount'] as int?) ?? 0,
        addedSubCount: (json['addedSubCount'] as int?) ?? 0,
        skippedDuplicateCount: (json['skippedDuplicateCount'] as int?) ?? 0,
      );
}

/// Result of migrating all category references within the same book (F-031, R4).
final class CategoryMigrationResult {
  const CategoryMigrationResult({
    required this.migratedRecordCount,
    required this.migratedBudgetCount,
    required this.migratedPeriodCount,
    required this.migratedTemplateCount,
    required this.migratedInstallmentCount,
    required this.migratedRemarkCount,
    required this.deletedCategoryCount,
  });

  final int migratedRecordCount;
  final int migratedBudgetCount;
  final int migratedPeriodCount;
  final int migratedTemplateCount;
  final int migratedInstallmentCount;
  final int migratedRemarkCount;
  final int deletedCategoryCount;

  int get totalMigratedItems =>
      migratedRecordCount +
      migratedBudgetCount +
      migratedPeriodCount +
      migratedTemplateCount +
      migratedInstallmentCount +
      migratedRemarkCount;

  Map<String, Object> toJson() => {
    'migratedRecordCount': migratedRecordCount,
    'migratedBudgetCount': migratedBudgetCount,
    'migratedPeriodCount': migratedPeriodCount,
    'migratedTemplateCount': migratedTemplateCount,
    'migratedInstallmentCount': migratedInstallmentCount,
    'migratedRemarkCount': migratedRemarkCount,
    'deletedCategoryCount': deletedCategoryCount,
  };

  factory CategoryMigrationResult.fromJson(Map<String, Object?> json) =>
      CategoryMigrationResult(
        migratedRecordCount: (json['migratedRecordCount'] as int?) ?? 0,
        migratedBudgetCount: (json['migratedBudgetCount'] as int?) ?? 0,
        migratedPeriodCount: (json['migratedPeriodCount'] as int?) ?? 0,
        migratedTemplateCount: (json['migratedTemplateCount'] as int?) ?? 0,
        migratedInstallmentCount:
            (json['migratedInstallmentCount'] as int?) ?? 0,
        migratedRemarkCount: (json['migratedRemarkCount'] as int?) ?? 0,
        deletedCategoryCount: (json['deletedCategoryCount'] as int?) ?? 0,
      );
}

/// Write & export/import service for category transfer & migration (F-031, ADR-009).
final class CategoryTransferService {
  CategoryTransferService(this.db);
  final AppDatabase db;

  int _now() => db.nowMs();

  Future<T> _command<T>(
    String commandId,
    List<Object?> payload,
    Future<Map<String, Object>> Function() body,
    T Function(Map<String, Object?> json) decode,
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
          final raw = jsonDecode(previous.resultId) as Map<String, Object?>;
          return decode(raw);
        }
        final out = await body();
        final encodedResult = jsonEncode(out);
        await db
            .into(db.writeCommands)
            .insert(
              WriteCommandsCompanion.insert(
                commandId: commandId,
                payloadHash: hash,
                resultId: encodedResult,
                committedAt: _now(),
              ),
            );
        return decode(out);
      }),
    );
  }

  static ExistingCategorySnapshot _toSnapshot(RecordCategory row) =>
      ExistingCategorySnapshot(
        id: row.id,
        name: row.name,
        type: row.type,
        parentCatId: row.parentCatId,
        sort: row.sort,
        icon: row.icon,
        colorFill: row.colorFill,
        isHide: row.isHide,
        extraInfo: row.extraInfo,
        accountBookId: row.accountBookId,
      );

  Future<AccountBook> _requireBook(int bookId, String label) async {
    final book = await (db.select(
      db.accountBooks,
    )..where((t) => t.id.equals(bookId))).getSingleOrNull();
    if (book == null) {
      throw Failure(FailureCode.validation, '$label不存在');
    }
    return book;
  }

  /// Builds a portable 2-level [CategoryPack] for [bookId].
  Future<CategoryPack> buildExportPack({
    required int bookId,
    bool includeHidden = true,
  }) async {
    return guardDatabase(() async {
      final book = await _requireBook(bookId, '账本');
      final rows = await (db.select(
        db.recordCategories,
      )..where((t) => t.accountBookId.equals(bookId))).get();
      return buildCategoryPackFromRows(
        bookName: book.name,
        exportedAtMs: _now(),
        rows: rows.map(_toSnapshot),
        includeHidden: includeHidden,
      );
    });
  }

  /// Exports [bookId]'s 2-level category tree JSON to an OS save location via [FileAccess].
  Future<String> exportCategoriesToSaveLocation({
    required int bookId,
    required FileAccess fileAccess,
    bool includeHidden = true,
  }) async {
    final pack = await buildExportPack(
      bookId: bookId,
      includeHidden: includeHidden,
    );
    final fileName = formatCategoryPackFileName(
      pack.bookName,
      DateTime.fromMillisecondsSinceEpoch(pack.exportedAtMs),
    );
    await fileAccess.saveBytes(
      fileName,
      pack.encodeUtf8Bytes(),
      mimeType: 'application/json',
    );
    return fileName;
  }

  /// Shares [bookId]'s 2-level category tree JSON via [FileAccess].
  Future<String> shareCategoriesPack({
    required int bookId,
    required FileAccess fileAccess,
    bool includeHidden = true,
    String? subject,
  }) async {
    final pack = await buildExportPack(
      bookId: bookId,
      includeHidden: includeHidden,
    );
    final fileName = formatCategoryPackFileName(
      pack.bookName,
      DateTime.fromMillisecondsSinceEpoch(pack.exportedAtMs),
    );
    await fileAccess.shareBytes(
      fileName,
      pack.encodeUtf8Bytes(),
      mimeType: 'application/json',
      subject: subject ?? '帐屿分类方案（${pack.bookName}）',
    );
    return fileName;
  }

  /// Picks and parses a `.json` category pack file without mutating the database.
  Future<({String fileName, CategoryPack pack})> pickCategoryPack({
    required FileAccess fileAccess,
  }) async {
    final selected = await fileAccess.pickBytes(
      allowedExtensions: const ['json'],
    );
    final pack = CategoryPack.decodeUtf8Bytes(selected.bytes);
    return (fileName: selected.name, pack: pack);
  }

  /// Merges a parsed [CategoryPack] into [targetBookId] using duplicate-safe `(type, name)` matching.
  Future<CategoryMergeResult> importCategoryPack({
    required String commandId,
    required int targetBookId,
    required CategoryPack pack,
  }) => _command(
    commandId,
    ['cat-import-pack-v1', targetBookId, pack.toJson()],
    () async {
      await _requireBook(targetBookId, '目标账本');
      if (pack.categories.isEmpty) {
        throw const Failure(FailureCode.validation, '分类导入文件不包含有效分类');
      }
      final result = await _executeMergeInTx(
        targetBookId: targetBookId,
        incoming: pack.categories,
      );
      return result.toJson();
    },
    CategoryMergeResult.fromJson,
  );

  /// Parses [jsonText] and merges it into [targetBookId] in one idempotent transaction.
  Future<CategoryMergeResult> importCategoriesJson({
    required String commandId,
    required int targetBookId,
    required String jsonText,
  }) {
    final pack = CategoryPack.decodeJson(jsonText);
    return importCategoryPack(
      commandId: commandId,
      targetBookId: targetBookId,
      pack: pack,
    );
  }

  /// Copies 2-level categories from [sourceBookId] into [targetBookId] with
  /// duplicate-safe `(type, name)` merge (R2, R3).
  Future<CategoryMergeResult> copyCategoriesBetweenBooks({
    required String commandId,
    required int sourceBookId,
    required int targetBookId,
    Set<int>? sourceCategoryIds,
    bool includeHidden = false,
  }) {
    final sortedIds = sourceCategoryIds == null
        ? null
        : (sourceCategoryIds.toList()..sort());
    return _command(
      commandId,
      [
        'cat-copy-between-books-v1',
        sourceBookId,
        targetBookId,
        sortedIds,
        includeHidden,
      ],
      () async {
        if (sourceBookId == targetBookId) {
          throw const Failure(FailureCode.validation, '源账本与目标账本不能相同');
        }
        await _requireBook(sourceBookId, '源账本');
        await _requireBook(targetBookId, '目标账本');

        final sourceRows = await (db.select(
          db.recordCategories,
        )..where((t) => t.accountBookId.equals(sourceBookId))).get();
        final incoming = buildSelectedCategoryTree(
          sourceRows: sourceRows.map(_toSnapshot),
          selectedIds: sourceCategoryIds,
          includeHidden: includeHidden,
        );
        final result = await _executeMergeInTx(
          targetBookId: targetBookId,
          incoming: incoming,
        );
        return result.toJson();
      },
      CategoryMergeResult.fromJson,
    );
  }

  Future<CategoryMergeResult> _executeMergeInTx({
    required int targetBookId,
    required List<CategoryNode> incoming,
  }) async {
    final targetRows = await (db.select(
      db.recordCategories,
    )..where((t) => t.accountBookId.equals(targetBookId))).get();
    final plan = planCategoryMerge(
      targetExisting: targetRows.map(_toSnapshot),
      incoming: incoming,
    );

    for (final plannedTop in plan.topCategories) {
      final int parentId;
      if (plannedTop.reuseExistingId != null) {
        parentId = plannedTop.reuseExistingId!;
      } else {
        parentId = await db
            .into(db.recordCategories)
            .insert(
              RecordCategoriesCompanion.insert(
                name: plannedTop.node.name,
                icon: Value(plannedTop.node.icon),
                type: plannedTop.node.type,
                sort: Value(plannedTop.sort),
                parentCatId: const Value(-1),
                colorFill: Value(plannedTop.node.colorFill),
                accountBookId: targetBookId,
                isHide: Value(plannedTop.node.isHide),
                extraInfo: Value(plannedTop.node.extraInfo),
              ),
            );
      }
      for (final plannedSub in plannedTop.children) {
        if (plannedSub.isDuplicate) continue;
        await db
            .into(db.recordCategories)
            .insert(
              RecordCategoriesCompanion.insert(
                name: plannedSub.node.name,
                icon: Value(plannedSub.node.icon),
                type: plannedSub.node.type,
                sort: Value(plannedSub.sort),
                parentCatId: Value(parentId),
                colorFill: Value(plannedSub.node.colorFill),
                accountBookId: targetBookId,
                isHide: Value(plannedSub.node.isHide),
                extraInfo: Value(plannedSub.node.extraInfo),
              ),
            );
      }
    }

    return CategoryMergeResult(
      addedTopCount: plan.addedTopCount,
      addedSubCount: plan.addedSubCount,
      skippedDuplicateCount: plan.skippedDuplicateCount,
    );
  }

  /// Atomically migrates bills, budgets, periodic rules, templates, installments,
  /// and remarks from [sourceCategoryId] (and its subcategories when
  /// [includeSubcategories] is true) to [targetCategoryId] in the same book (R4).
  Future<CategoryMigrationResult> migrateCategoryBills({
    required String commandId,
    required int sourceCategoryId,
    required int targetCategoryId,
    bool includeSubcategories = true,
    bool deleteSourceAfterMigrate = false,
  }) => _command(
    commandId,
    [
      'cat-migrate-bills-v1',
      sourceCategoryId,
      targetCategoryId,
      includeSubcategories,
      deleteSourceAfterMigrate,
    ],
    () async {
      final sourceRow = await (db.select(
        db.recordCategories,
      )..where((t) => t.id.equals(sourceCategoryId))).getSingleOrNull();
      if (sourceRow == null) {
        throw const Failure(FailureCode.validation, '源分类不存在');
      }
      final targetRow = await (db.select(
        db.recordCategories,
      )..where((t) => t.id.equals(targetCategoryId))).getSingleOrNull();
      if (targetRow == null) {
        throw const Failure(FailureCode.validation, '目标分类不存在');
      }

      final bookId = sourceRow.accountBookId;
      final allBookRows = await (db.select(
        db.recordCategories,
      )..where((t) => t.accountBookId.equals(bookId))).get();

      final affectedIds = validateIntraBookMigration(
        source: _toSnapshot(sourceRow),
        target: _toSnapshot(targetRow),
        allBookCategories: allBookRows.map(_toSnapshot),
        includeSubcategories: includeSubcategories,
      );

      // 1. Migrate `record.record_cat_id`.
      final migratedRecords =
          await (db.update(db.records)..where(
                (t) =>
                    t.accountBookId.equals(bookId) &
                    t.recordCatId.isIn(affectedIds),
              ))
              .write(RecordsCompanion(recordCatId: Value(targetCategoryId)));

      // 2. Migrate `budget.record_cat_id` preserving `(bookId, section, budgetType, recordCatId)` uniqueness.
      final srcBudgets =
          await (db.select(db.budgets)..where(
                (t) =>
                    t.bookId.equals(bookId) & t.recordCatId.isIn(affectedIds),
              ))
              .get();
      final budgetsByGroup = <(String, int), List<Budget>>{};
      for (final b in srcBudgets) {
        budgetsByGroup.putIfAbsent((b.section, b.budgetType), () => []).add(b);
      }

      for (final entry in budgetsByGroup.entries) {
        final (section, budgetType) = entry.key;
        final groupRows = entry.value;

        // If the parent category itself had a budget in this period, its quota
        // already covered its subcategories (budget.md R4); otherwise sum child quotas.
        final parentBudget = groupRows
            .where((b) => b.recordCatId == sourceCategoryId)
            .firstOrNull;
        final BigInt primaryMinor;
        if (parentBudget != null) {
          primaryMinor = parentBudget.amountMinor;
        } else {
          var sum = Money.zero();
          for (final b in groupRows) {
            sum = sum + Money.minor(b.amountMinor);
          }
          primaryMinor = sum.storageMinor;
        }

        final existingTarget =
            await (db.select(db.budgets)..where(
                  (t) =>
                      t.bookId.equals(bookId) &
                      t.section.equals(section) &
                      t.budgetType.equals(budgetType) &
                      t.recordCatId.equals(targetCategoryId),
                ))
                .getSingleOrNull();

        if (existingTarget != null) {
          if (sourceRow.parentCatId != targetRow.id) {
            final mergedMinor =
                (Money.minor(existingTarget.amountMinor) +
                        Money.minor(primaryMinor))
                    .storageMinor;
            final prevExtra = BudgetExtra.fromJson(
              existingTarget.extraInfo,
              fallbackAmountMinor: existingTarget.amountMinor,
            );
            final nextBase =
                (Money.minor(prevExtra.baseMinor) + Money.minor(primaryMinor))
                    .storageMinor;
            final nextExtra = BudgetExtra(
              autoCopy: prevExtra.autoCopy,
              forward: prevExtra.forward,
              baseMinor: nextBase,
            ).toJsonString();
            await (db.update(
              db.budgets,
            )..where((t) => t.id.equals(existingTarget.id))).write(
              BudgetsCompanion(
                amountMinor: Value(mergedMinor),
                extraInfo: Value(nextExtra),
              ),
            );
          }
          await (db.delete(
            db.budgets,
          )..where((t) => t.id.isIn(groupRows.map((g) => g.id)))).go();
        } else {
          final keep = parentBudget ?? groupRows.first;
          final prevExtra = BudgetExtra.fromJson(
            keep.extraInfo,
            fallbackAmountMinor: keep.amountMinor,
          );
          final nextExtra = BudgetExtra(
            autoCopy: prevExtra.autoCopy,
            forward: prevExtra.forward,
            baseMinor: primaryMinor,
          ).toJsonString();
          await (db.update(
            db.budgets,
          )..where((t) => t.id.equals(keep.id))).write(
            BudgetsCompanion(
              recordCatId: Value(targetCategoryId),
              amountMinor: Value(primaryMinor),
              extraInfo: Value(nextExtra),
            ),
          );
          final extraIds = [
            for (final g in groupRows)
              if (g.id != keep.id) g.id,
          ];
          if (extraIds.isNotEmpty) {
            await (db.delete(
              db.budgets,
            )..where((t) => t.id.isIn(extraIds))).go();
          }
        }

        // Maintain budget.md R7 invariant: if expense category sum exceeds total budget, bump total budget.
        if (budgetType == BudgetTypeCode.expenseCategory) {
          final allExpenseCatBudgets =
              await (db.select(db.budgets)..where(
                    (t) =>
                        t.bookId.equals(bookId) &
                        t.section.equals(section) &
                        t.budgetType.equals(BudgetTypeCode.expenseCategory),
                  ))
                  .get();
          var catSum = Money.zero();
          for (final b in allExpenseCatBudgets) {
            catSum = catSum + Money.minor(b.amountMinor);
          }
          final totalBudgetRow =
              await (db.select(db.budgets)..where(
                    (t) =>
                        t.bookId.equals(bookId) &
                        t.section.equals(section) &
                        t.budgetType.equals(BudgetTypeCode.total) &
                        t.recordCatId.equals(-1),
                  ))
                  .getSingleOrNull();
          if (totalBudgetRow != null &&
              catSum.storageMinor > totalBudgetRow.amountMinor) {
            final tExtra = BudgetExtra.fromJson(
              totalBudgetRow.extraInfo,
              fallbackAmountMinor: totalBudgetRow.amountMinor,
            );
            await (db.update(
              db.budgets,
            )..where((t) => t.id.equals(totalBudgetRow.id))).write(
              BudgetsCompanion(
                amountMinor: Value(catSum.storageMinor),
                extraInfo: Value(
                  BudgetExtra(
                    autoCopy: tExtra.autoCopy,
                    forward: tExtra.forward,
                    baseMinor: catSum.storageMinor,
                  ).toJsonString(),
                ),
              ),
            );
          }
        }
      }

      // 3. Migrate `record_period.cat_id`.
      final migratedPeriods =
          await (db.update(db.recordPeriods)..where(
                (t) => t.bookId.equals(bookId) & t.catId.isIn(affectedIds),
              ))
              .write(RecordPeriodsCompanion(catId: Value(targetCategoryId)));

      // 4. Migrate `record_template.record_cat_id`.
      final migratedTemplates =
          await (db.update(db.recordTemplates)..where(
                (t) =>
                    t.bookId.equals(bookId) & t.recordCatId.isIn(affectedIds),
              ))
              .write(
                RecordTemplatesCompanion(recordCatId: Value(targetCategoryId)),
              );

      // 5. Migrate `installment.cat_id`.
      final migratedInstallments =
          await (db.update(db.installments)..where(
                (t) => t.bookId.equals(bookId) & t.catId.isIn(affectedIds),
              ))
              .write(InstallmentsCompanion(catId: Value(targetCategoryId)));

      // 6. Migrate `remark.record_cat_id` merging duplicate content `used_times`.
      final srcRemarks = await (db.select(
        db.remarks,
      )..where((t) => t.recordCatId.isIn(affectedIds))).get();
      final existingTargetRemarks = await (db.select(
        db.remarks,
      )..where((t) => t.recordCatId.equals(targetCategoryId))).get();
      final targetRemarksByContent = <String, Remark>{
        for (final r in existingTargetRemarks) r.content: r,
      };
      for (final srcRemark in srcRemarks) {
        final match = targetRemarksByContent[srcRemark.content];
        if (match != null) {
          final mergedUsedTimes = match.usedTimes + srcRemark.usedTimes;
          await (db.update(db.remarks)..where((t) => t.id.equals(match.id)))
              .write(RemarksCompanion(usedTimes: Value(mergedUsedTimes)));
          await (db.delete(
            db.remarks,
          )..where((t) => t.id.equals(srcRemark.id))).go();
          targetRemarksByContent[srcRemark.content] = Remark(
            id: match.id,
            content: match.content,
            recordCatId: targetCategoryId,
            usedTimes: mergedUsedTimes,
          );
        } else {
          await (db.update(db.remarks)..where((t) => t.id.equals(srcRemark.id)))
              .write(RemarksCompanion(recordCatId: Value(targetCategoryId)));
          targetRemarksByContent[srcRemark.content] = Remark(
            id: srcRemark.id,
            content: srcRemark.content,
            recordCatId: targetCategoryId,
            usedTimes: srcRemark.usedTimes,
          );
        }
      }

      var deletedCategories = 0;
      if (deleteSourceAfterMigrate) {
        deletedCategories = await (db.delete(
          db.recordCategories,
        )..where((t) => t.id.isIn(affectedIds))).go();
      }

      return CategoryMigrationResult(
        migratedRecordCount: migratedRecords,
        migratedBudgetCount: srcBudgets.length,
        migratedPeriodCount: migratedPeriods,
        migratedTemplateCount: migratedTemplates,
        migratedInstallmentCount: migratedInstallments,
        migratedRemarkCount: srcRemarks.length,
        deletedCategoryCount: deletedCategories,
      ).toJson();
    },
    CategoryMigrationResult.fromJson,
  );
}
