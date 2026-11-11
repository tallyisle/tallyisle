import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../../core/failure.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/billing_period.dart';
import '../../domain/rules/budget_rules.dart';
import '../db/database.dart';
import '../db/failures.dart';
import '../repo/ledger_queries.dart' show statEntryOf;

/// Mutating write service for budgets (F-006, ADR-009).
final class BudgetService {
  BudgetService(this.db);
  final AppDatabase db;

  int _now() => db.nowMs();

  Future<T> _command<T>(
    String commandId,
    List<Object?> payload,
    Future<String> Function() body,
    T Function(String resultId) result,
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
          return result(previous.resultId);
        }
        final id = await body();
        await db
            .into(db.writeCommands)
            .insert(
              WriteCommandsCompanion.insert(
                commandId: commandId,
                payloadHash: hash,
                resultId: id,
                committedAt: _now(),
              ),
            );
        return result(id);
      }),
    );
  }

  /// Sets the budget mode (monthly = 0, yearly = 1) for the book in `ti_preference`.
  Future<void> setBudgetMode({
    required String commandId,
    required int bookId,
    required BudgetMode mode,
  }) =>
      _command(commandId, ['budget-set-mode-v1', bookId, mode.value], () async {
        await db
            .into(db.preferences)
            .insertOnConflictUpdate(
              Preference(
                key: 'budget_mode_$bookId',
                value: mode.value.toString(),
              ),
            );
        return mode.value.toString();
      }, (id) {});

  /// Upserts book-wide total budget for [section].
  Future<int> upsertTotalBudget({
    required String commandId,
    required int bookId,
    required String section,
    required BigInt amountMinor,
    bool autoCopy = false,
    bool forward = false,
  }) {
    if (amountMinor.isNegative) {
      throw const Failure(FailureCode.validation, '预算金额不能为负');
    }
    return _command(
      commandId,
      [
        'budget-upsert-total-v1',
        bookId,
        section,
        amountMinor.toString(),
        autoCopy,
        forward,
      ],
      () async {
        final existing =
            await (db.select(db.budgets)..where(
                  (t) =>
                      t.bookId.equals(bookId) &
                      t.section.equals(section) &
                      t.budgetType.equals(BudgetTypeCode.total) &
                      t.recordCatId.equals(-1),
                ))
                .getSingleOrNull();

        final extra = BudgetExtra(
          autoCopy: autoCopy,
          forward: forward,
          baseMinor: amountMinor,
        ).toJsonString();

        if (existing != null) {
          await (db.update(
            db.budgets,
          )..where((t) => t.id.equals(existing.id))).write(
            BudgetsCompanion(
              amountMinor: Value(amountMinor),
              extraInfo: Value(extra),
            ),
          );
          return existing.id.toString();
        } else {
          final maxIdRow = await db
              .customSelect('SELECT MAX(id) AS m FROM budget')
              .getSingleOrNull();
          final newId = ((maxIdRow?.data['m'] as int?) ?? 0) + 1;

          await db
              .into(db.budgets)
              .insert(
                BudgetsCompanion.insert(
                  id: Value(newId),
                  budgetType: BudgetTypeCode.total,
                  recordCatId: -1,
                  amountMinor: amountMinor,
                  bookId: bookId,
                  section: section,
                  sort: const Value(0),
                  createDate: _now(),
                  extraInfo: Value(extra),
                ),
              );
          return newId.toString();
        }
      },
      (id) => int.parse(id),
    );
  }

  /// Upserts category budget (expense = 1, saving = 2).
  ///
  /// For expense category budgets (`budgetType == 1`), automatically triggers
  /// R7 in the same transaction: recalculates the sum of all expense category
  /// budgets for the same book and section, and auto-creates or upscales the
  /// total budget (`budget_type == 0`) and updates its `extraInfo.base`!
  Future<int> upsertCategoryBudget({
    required String commandId,
    required int bookId,
    required String section,
    required int categoryId,
    required int budgetType,
    required BigInt amountMinor,
    bool autoCopy = false,
    bool forward = false,
  }) {
    if (amountMinor.isNegative) {
      throw const Failure(FailureCode.validation, '预算金额不能为负');
    }
    return _command(
      commandId,
      [
        'budget-upsert-category-v1',
        bookId,
        section,
        categoryId,
        budgetType,
        amountMinor.toString(),
        autoCopy,
        forward,
      ],
      () async {
        final existing =
            await (db.select(db.budgets)..where(
                  (t) =>
                      t.bookId.equals(bookId) &
                      t.section.equals(section) &
                      t.budgetType.equals(budgetType) &
                      t.recordCatId.equals(categoryId),
                ))
                .getSingleOrNull();

        final extra = BudgetExtra(
          autoCopy: autoCopy,
          forward: forward,
          baseMinor: amountMinor,
        ).toJsonString();

        final int catBudgetId;
        if (existing != null) {
          await (db.update(
            db.budgets,
          )..where((t) => t.id.equals(existing.id))).write(
            BudgetsCompanion(
              amountMinor: Value(amountMinor),
              extraInfo: Value(extra),
            ),
          );
          catBudgetId = existing.id;
        } else {
          final maxIdRow = await db
              .customSelect('SELECT MAX(id) AS m FROM budget')
              .getSingleOrNull();
          catBudgetId = ((maxIdRow?.data['m'] as int?) ?? 0) + 1;

          await db
              .into(db.budgets)
              .insert(
                BudgetsCompanion.insert(
                  id: Value(catBudgetId),
                  budgetType: budgetType,
                  recordCatId: categoryId,
                  amountMinor: amountMinor,
                  bookId: bookId,
                  section: section,
                  sort: const Value(0),
                  createDate: _now(),
                  extraInfo: Value(extra),
                ),
              );
        }

        // R7: When setting expense category budget, upscale total budget if sum exceeds it
        if (budgetType == BudgetTypeCode.expenseCategory) {
          final expenseBudgets =
              await (db.select(db.budgets)..where(
                    (t) =>
                        t.bookId.equals(bookId) &
                        t.section.equals(section) &
                        t.budgetType.equals(BudgetTypeCode.expenseCategory),
                  ))
                  .get();

          final sumMinor = expenseBudgets.fold(
            BigInt.zero,
            (acc, b) => acc + b.amountMinor,
          );

          final totalBudget =
              await (db.select(db.budgets)..where(
                    (t) =>
                        t.bookId.equals(bookId) &
                        t.section.equals(section) &
                        t.budgetType.equals(BudgetTypeCode.total) &
                        t.recordCatId.equals(-1),
                  ))
                  .getSingleOrNull();

          if (totalBudget == null) {
            final maxIdRow = await db
                .customSelect('SELECT MAX(id) AS m FROM budget')
                .getSingleOrNull();
            final newTotalId = ((maxIdRow?.data['m'] as int?) ?? 0) + 1;
            final totalExtra = BudgetExtra(
              autoCopy: false,
              forward: false,
              baseMinor: sumMinor,
            ).toJsonString();

            await db
                .into(db.budgets)
                .insert(
                  BudgetsCompanion.insert(
                    id: Value(newTotalId),
                    budgetType: BudgetTypeCode.total,
                    recordCatId: -1,
                    amountMinor: sumMinor,
                    bookId: bookId,
                    section: section,
                    sort: const Value(0),
                    createDate: _now(),
                    extraInfo: Value(totalExtra),
                  ),
                );
          } else if (sumMinor > totalBudget.amountMinor) {
            final currentExtra = BudgetExtra.fromJson(
              totalBudget.extraInfo,
              fallbackAmountMinor: totalBudget.amountMinor,
            );
            final updatedExtra = BudgetExtra(
              autoCopy: currentExtra.autoCopy,
              forward: currentExtra.forward,
              baseMinor: sumMinor,
            ).toJsonString();

            await (db.update(
              db.budgets,
            )..where((t) => t.id.equals(totalBudget.id))).write(
              BudgetsCompanion(
                amountMinor: Value(sumMinor),
                extraInfo: Value(updatedExtra),
              ),
            );
          }
        }

        return catBudgetId.toString();
      },
      (id) => int.parse(id),
    );
  }

  /// Physically deletes a budget row.
  Future<void> deleteBudget({
    required String commandId,
    required int budgetId,
  }) => _command(commandId, ['budget-delete-v1', budgetId], () async {
    await (db.delete(db.budgets)..where((t) => t.id.equals(budgetId))).go();
    return budgetId.toString();
  }, (id) {});

  /// Automatically copies / carries over budgets from the previous period to
  /// [currentPeriod] when the current period has no budgets and the previous period
  /// has at least one budget with `acopy == true`.
  ///
  /// Fixes the original app's `singleOrNull` defect, allowing arbitrary numbers of
  /// category budgets and total budget to be copied/carried over simultaneously.
  Future<int> ensureAutoCarryoverIfNeeded({
    required String commandId,
    required int bookId,
    required BudgetMode mode,
    required BillingPeriod currentPeriod,
    required int startDay,
  }) => _command(
    commandId,
    [
      'budget-auto-carryover-v1',
      bookId,
      mode.value,
      currentPeriod.monthlySection,
      currentPeriod.yearlySection,
      startDay,
    ],
    () async {
      final currentSection = mode == BudgetMode.yearly
          ? currentPeriod.yearlySection
          : currentPeriod.monthlySection;

      // Check if currentSection has ANY budgets
      final existingCurrent =
          await (db.select(db.budgets)..where(
                (t) =>
                    t.bookId.equals(bookId) & t.section.equals(currentSection),
              ))
              .get();
      if (existingCurrent.isNotEmpty) {
        return '0';
      }

      // Determine previous period and section
      final BillingPeriod prevPeriod = mode == BudgetMode.yearly
          ? currentPeriod.previousYear(startDay)
          : currentPeriod.previous(startDay);
      final String prevSection = mode == BudgetMode.yearly
          ? prevPeriod.yearlySection
          : prevPeriod.monthlySection;

      // Query budgets from previous period
      final prevBudgets =
          await (db.select(db.budgets)..where(
                (t) => t.bookId.equals(bookId) & t.section.equals(prevSection),
              ))
              .get();

      final copyCandidates = <Budget>[];
      for (final b in prevBudgets) {
        final extra = BudgetExtra.fromJson(
          b.extraInfo,
          fallbackAmountMinor: b.amountMinor,
        );
        if (extra.autoCopy) {
          copyCandidates.add(b);
        }
      }

      if (copyCandidates.isEmpty) {
        return '0';
      }

      final hasForward = copyCandidates.any(
        (b) => BudgetExtra.fromJson(
          b.extraInfo,
          fallbackAmountMinor: b.amountMinor,
        ).forward,
      );

      List<BudgetRecordInput> prevRecordInputs = const [];
      List<BudgetCategoryNode> allCategoryNodes = const [];

      if (hasForward) {
        final rawRecords =
            await (db.select(db.records)..where(
                  (t) =>
                      t.accountBookId.equals(bookId) &
                      t.recordTime.isBiggerOrEqualValue(prevPeriod.startMs) &
                      t.recordTime.isSmallerOrEqualValue(prevPeriod.endMs) &
                      t.type.isNotIn([
                        RecordType.balanceAdjust,
                        RecordType.reimburseReceipt,
                      ]),
                ))
                .get();

        prevRecordInputs = rawRecords
            .map(
              (r) => BudgetRecordInput(
                recordId: r.recordId,
                recordCatId: r.recordCatId,
                entry: statEntryOf(r),
              ),
            )
            .toList();

        final dbCats = await (db.select(
          db.recordCategories,
        )..where((t) => t.accountBookId.equals(bookId))).get();

        allCategoryNodes = dbCats
            .map(
              (c) => BudgetCategoryNode(
                id: c.id,
                name: c.name,
                icon: c.icon,
                type: c.type,
                parentCatId: c.parentCatId,
              ),
            )
            .toList();
      }

      final maxIdRow = await db
          .customSelect('SELECT MAX(id) AS m FROM budget')
          .getSingleOrNull();
      var nextId = ((maxIdRow?.data['m'] as int?) ?? 0) + 1;

      var copiedCount = 0;
      for (final b in copyCandidates) {
        final extra = BudgetExtra.fromJson(
          b.extraInfo,
          fallbackAmountMinor: b.amountMinor,
        );
        final BigInt newAmount;
        if (!extra.forward) {
          newAmount = extra.baseMinor;
        } else {
          final BigInt rawPrevUsed;
          if (b.budgetType == BudgetTypeCode.total) {
            final usage = computeTotalBudgetUsage(
              amountMinor: b.amountMinor,
              records: prevRecordInputs,
            );
            rawPrevUsed = usage.rawUsedMinor;
          } else {
            final catNode = allCategoryNodes.firstWhere(
              (c) => c.id == b.recordCatId,
              orElse: () => BudgetCategoryNode(
                id: b.recordCatId,
                name: '',
                type: b.budgetType == BudgetTypeCode.savingCategory ? 1 : 0,
              ),
            );
            final usage = computeCategoryBudgetUsage(
              category: catNode,
              allCategories: allCategoryNodes,
              amountMinor: b.amountMinor,
              budgetType: b.budgetType,
              records: prevRecordInputs,
            );
            rawPrevUsed = usage.rawUsedMinor;
          }
          newAmount = computeNextPeriodCarryover(
            baseAmountMinor: extra.baseMinor,
            prevAmountMinor: b.amountMinor,
            rawPrevUsedMinor: rawPrevUsed,
            forward: true,
          );
        }

        final newExtra = BudgetExtra(
          autoCopy: true,
          forward: extra.forward,
          baseMinor: extra.baseMinor,
        ).toJsonString();

        await db
            .into(db.budgets)
            .insert(
              BudgetsCompanion.insert(
                id: Value(nextId),
                budgetType: b.budgetType,
                recordCatId: b.recordCatId,
                amountMinor: newAmount,
                bookId: bookId,
                section: currentSection,
                sort: Value(b.sort),
                createDate: _now(),
                remark: Value(b.remark),
                extraInfo: Value(newExtra),
              ),
            );
        nextId++;
        copiedCount++;
      }

      // Check R7 after all copied
      final expenseBudgets =
          await (db.select(db.budgets)..where(
                (t) =>
                    t.bookId.equals(bookId) &
                    t.section.equals(currentSection) &
                    t.budgetType.equals(BudgetTypeCode.expenseCategory),
              ))
              .get();
      if (expenseBudgets.isNotEmpty) {
        final sumMinor = expenseBudgets.fold(
          BigInt.zero,
          (acc, b) => acc + b.amountMinor,
        );
        final totalBudget =
            await (db.select(db.budgets)..where(
                  (t) =>
                      t.bookId.equals(bookId) &
                      t.section.equals(currentSection) &
                      t.budgetType.equals(BudgetTypeCode.total) &
                      t.recordCatId.equals(-1),
                ))
                .getSingleOrNull();

        if (totalBudget == null) {
          final totalExtra = BudgetExtra(
            autoCopy: false,
            forward: false,
            baseMinor: sumMinor,
          ).toJsonString();

          await db
              .into(db.budgets)
              .insert(
                BudgetsCompanion.insert(
                  id: Value(nextId),
                  budgetType: BudgetTypeCode.total,
                  recordCatId: -1,
                  amountMinor: sumMinor,
                  bookId: bookId,
                  section: currentSection,
                  sort: const Value(0),
                  createDate: _now(),
                  extraInfo: Value(totalExtra),
                ),
              );
        } else if (sumMinor > totalBudget.amountMinor) {
          final currentExtra = BudgetExtra.fromJson(
            totalBudget.extraInfo,
            fallbackAmountMinor: totalBudget.amountMinor,
          );
          final updatedExtra = BudgetExtra(
            autoCopy: currentExtra.autoCopy,
            forward: currentExtra.forward,
            baseMinor: sumMinor,
          ).toJsonString();

          await (db.update(
            db.budgets,
          )..where((t) => t.id.equals(totalBudget.id))).write(
            BudgetsCompanion(
              amountMinor: Value(sumMinor),
              extraInfo: Value(updatedExtra),
            ),
          );
        }
      }

      return copiedCount.toString();
    },
    (res) => int.parse(res),
  );
}
