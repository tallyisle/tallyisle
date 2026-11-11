import 'package:drift/drift.dart';

import '../../domain/rules/savings_plan.dart';
import '../db/database.dart';

/// Read-only reactive queries for Savings Plans (F-012, ADR-014).
///
/// Per DR-SP-01 (`NP-SP-02`), savings plans are global across all account books;
/// `money_save_plan.book_id` only governs which book receives generated transfer bills.
final class SavingsQueries {
  SavingsQueries(this.db);
  final AppDatabase db;

  SimpleSelectStatement<$MoneySavePlansTable, MoneySavePlan> _plansSelect({
    int? status,
  }) {
    final q = db.select(db.moneySavePlans);
    if (status != null) {
      q.where((t) => t.status.equals(status));
    }
    q.orderBy([
      (t) => OrderingTerm.asc(t.sort),
      (t) => OrderingTerm.desc(t.createDate),
      (t) => OrderingTerm.desc(t.id),
    ]);
    return q;
  }

  /// Watches all plans, optionally filtered by [status] (`0` active, `1` archived).
  Stream<List<MoneySavePlan>> watchPlans({int? status}) =>
      _plansSelect(status: status).watch();

  /// One-shot fetch of plans, optionally filtered by [status].
  Future<List<MoneySavePlan>> getPlans({int? status}) =>
      _plansSelect(status: status).get();

  /// Top active plan ordered by `sort ASC` (`SQL-SP-02`).
  Stream<MoneySavePlan?> watchTopActivePlan() =>
      (db.select(db.moneySavePlans)
            ..where((t) => t.status.equals(SavingsPlanStatus.active))
            ..orderBy([
              (t) => OrderingTerm.asc(t.sort),
              (t) => OrderingTerm.desc(t.createDate),
              (t) => OrderingTerm.desc(t.id),
            ])
            ..limit(1))
          .watchSingleOrNull();

  /// Watches a single plan by [planId] (`SQL-SP-03`).
  Stream<MoneySavePlan?> watchPlan(int planId) => (db.select(
    db.moneySavePlans,
  )..where((t) => t.id.equals(planId))).watchSingleOrNull();

  /// One-shot fetch of a single plan by [planId].
  Future<MoneySavePlan?> getPlan(int planId) => (db.select(
    db.moneySavePlans,
  )..where((t) => t.id.equals(planId))).getSingleOrNull();

  SimpleSelectStatement<$MoneySavePlanRecordsTable, MoneySavePlanRecord>
  _recordsSelect(int planId) => db.select(db.moneySavePlanRecords)
    ..where((t) => t.planId.equals(planId))
    ..orderBy([
      (t) => OrderingTerm.desc(t.recordDate),
      (t) => OrderingTerm.desc(t.id),
    ]);

  /// Watches deposit check-in records for [planId] ordered newest-first (`SQL-SP-04`).
  Stream<List<MoneySavePlanRecord>> watchPlanRecords(int planId) =>
      _recordsSelect(planId).watch();

  /// One-shot fetch of deposit check-in records for [planId] ordered newest-first.
  Future<List<MoneySavePlanRecord>> getPlanRecords(int planId) =>
      _recordsSelect(planId).get();

  /// Watches which linked `record_id`s from [planId]'s deposit records still exist
  /// as live rows in `record` (handling external bill deletion cleanly, NP-SP-03).
  Stream<Set<String>> watchLiveTransferIdsForPlan(int planId) {
    final sql = db.customSelect(
      'SELECT r.record_id AS rid '
      'FROM record r '
      'INNER JOIN money_save_plan_record m ON m.record_id = r.record_id '
      'WHERE m.plan_id = ?',
      variables: [Variable.withInt(planId)],
      readsFrom: {db.records, db.moneySavePlanRecords},
    );
    return sql.watch().map(
      (rows) => {for (final r in rows) r.read<String>('rid')},
    );
  }

  /// One-shot lookup of live `record_id`s among [recordIds].
  Future<Set<String>> getLiveRecordIds(Iterable<String> recordIds) async {
    final ids = recordIds.where((id) => id.isNotEmpty).toSet();
    if (ids.isEmpty) return const {};
    final rows = await (db.select(
      db.records,
    )..where((t) => t.recordId.isIn(ids))).get();
    return {for (final r in rows) r.recordId};
  }
}
