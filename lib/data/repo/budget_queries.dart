import 'package:drift/drift.dart';

import '../../domain/model/codes.dart';
import '../../domain/rules/budget_rules.dart';
import '../db/database.dart';

/// Read-only queries for budgets and budget calculations (ADR-014).
final class BudgetQueries {
  BudgetQueries(this.db);
  final AppDatabase db;

  Stream<BudgetMode> watchBudgetMode(int bookId) {
    return (db.select(db.preferences)
          ..where((t) => t.key.equals('budget_mode_$bookId')))
        .watchSingleOrNull()
        .map(
          (p) => BudgetMode.fromInt(p == null ? 0 : int.tryParse(p.value) ?? 0),
        );
  }

  Future<BudgetMode> getBudgetMode(int bookId) async {
    final p = await (db.select(
      db.preferences,
    )..where((t) => t.key.equals('budget_mode_$bookId'))).getSingleOrNull();
    return BudgetMode.fromInt(p == null ? 0 : int.tryParse(p.value) ?? 0);
  }

  Stream<List<Budget>> watchBudgets(int bookId, String section) {
    return (db.select(db.budgets)
          ..where((t) => t.bookId.equals(bookId) & t.section.equals(section))
          ..orderBy([
            (t) => OrderingTerm(expression: t.budgetType),
            (t) => OrderingTerm(expression: t.sort),
            (t) => OrderingTerm(expression: t.id),
          ]))
        .watch();
  }

  Future<List<Budget>> getBudgets(int bookId, String section) {
    return (db.select(db.budgets)
          ..where((t) => t.bookId.equals(bookId) & t.section.equals(section))
          ..orderBy([
            (t) => OrderingTerm(expression: t.budgetType),
            (t) => OrderingTerm(expression: t.sort),
            (t) => OrderingTerm(expression: t.id),
          ]))
        .get();
  }

  /// Period bills excluding balance adjustment (type 4) and reimbursement receipt (type 15).
  Stream<List<LedgerRecord>> watchBudgetPeriodRecords(
    int bookId,
    int startMs,
    int endMs,
  ) {
    return (db.select(db.records)
          ..where(
            (t) =>
                t.accountBookId.equals(bookId) &
                t.recordTime.isBiggerOrEqualValue(startMs) &
                t.recordTime.isSmallerOrEqualValue(endMs) &
                t.type.isNotIn([
                  RecordType.balanceAdjust,
                  RecordType.reimburseReceipt,
                ]),
          )
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.recordTime, mode: OrderingMode.desc),
          ]))
        .watch();
  }

  Future<List<LedgerRecord>> getBudgetPeriodRecords(
    int bookId,
    int startMs,
    int endMs,
  ) {
    return (db.select(db.records)
          ..where(
            (t) =>
                t.accountBookId.equals(bookId) &
                t.recordTime.isBiggerOrEqualValue(startMs) &
                t.recordTime.isSmallerOrEqualValue(endMs) &
                t.type.isNotIn([
                  RecordType.balanceAdjust,
                  RecordType.reimburseReceipt,
                ]),
          )
          ..orderBy([
            (t) =>
                OrderingTerm(expression: t.recordTime, mode: OrderingMode.desc),
          ]))
        .get();
  }

  Stream<List<RecordCategory>> watchBookCategories(int bookId) {
    return (db.select(db.recordCategories)
          ..where((t) => t.accountBookId.equals(bookId))
          ..orderBy([
            (t) => OrderingTerm(expression: t.sort),
            (t) => OrderingTerm(expression: t.id),
          ]))
        .watch();
  }

  Future<List<RecordCategory>> getBookCategories(int bookId) {
    return (db.select(db.recordCategories)
          ..where((t) => t.accountBookId.equals(bookId))
          ..orderBy([
            (t) => OrderingTerm(expression: t.sort),
            (t) => OrderingTerm(expression: t.id),
          ]))
        .get();
  }
}
