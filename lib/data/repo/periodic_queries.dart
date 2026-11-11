import 'package:drift/drift.dart';

import '../../domain/rules/periodic_records.dart';
import '../db/database.dart';

/// Counts of periodic rules per `PeriodState` tab (`0`, `1`, `2`).
final class PeriodStateCounts {
  const PeriodStateCounts({
    required this.active,
    required this.ended,
    required this.paused,
  });

  final int active;
  final int ended;
  final int paused;
}

/// Read-only queries for periodic bookkeeping rules and generated history (F-009, ADR-014).
final class PeriodicQueries {
  PeriodicQueries(this.db);
  final AppDatabase db;

  SimpleSelectStatement<$RecordPeriodsTable, RecordPeriod> _byStateQuery(
    int state, {
    int? bookId,
  }) {
    final query = db.select(db.recordPeriods)
      ..where(
        (t) =>
            t.state.equals(state) &
            (bookId == null ? const Constant(true) : t.bookId.equals(bookId)),
      );
    if (state == PeriodState.ended) {
      query.orderBy([
        (t) => OrderingTerm.desc(t.lastAddDate),
        (t) => OrderingTerm.desc(t.createTime),
        (t) => OrderingTerm.desc(t.id),
      ]);
    } else {
      query.orderBy([
        (t) => OrderingTerm.desc(t.createTime),
        (t) => OrderingTerm.desc(t.id),
      ]);
    }
    return query;
  }

  /// Watches periodic rules in `[state]` (`0` 进行中, `1` 已结束, `2` 已停用).
  Stream<List<RecordPeriod>> watchPeriodsByState(int state, {int? bookId}) =>
      _byStateQuery(state, bookId: bookId).watch();

  /// One-shot fetch of periodic rules in `[state]`.
  Future<List<RecordPeriod>> getPeriodsByState(int state, {int? bookId}) =>
      _byStateQuery(state, bookId: bookId).get();

  /// Watches rule counts across all 3 tabs.
  Stream<PeriodStateCounts> watchStateCounts({int? bookId}) {
    final query = db.select(db.recordPeriods)
      ..where(
        (t) => bookId == null ? const Constant(true) : t.bookId.equals(bookId),
      );
    return query.watch().map((rows) {
      var active = 0;
      var ended = 0;
      var paused = 0;
      for (final r in rows) {
        if (r.state == PeriodState.active) {
          active++;
        } else if (r.state == PeriodState.ended) {
          ended++;
        } else if (r.state == PeriodState.paused) {
          paused++;
        }
      }
      return PeriodStateCounts(active: active, ended: ended, paused: paused);
    });
  }

  /// Watches a single `RecordPeriod` by `[id]`.
  Stream<RecordPeriod?> watchPeriod(int id) => (db.select(
    db.recordPeriods,
  )..where((t) => t.id.equals(id))).watchSingleOrNull();

  /// Fetches a single `RecordPeriod` by `[id]`.
  Future<RecordPeriod?> getPeriod(int id) => (db.select(
    db.recordPeriods,
  )..where((t) => t.id.equals(id))).getSingleOrNull();

  SimpleSelectStatement<$RecordsTable, LedgerRecord> _historyQuery(
    int periodId,
  ) => db.select(db.records)
    ..where((t) => t.periodId.equals(periodId))
    ..orderBy([
      (t) => OrderingTerm.desc(t.recordTime),
      (t) => OrderingTerm.desc(t.createDate),
      (t) => OrderingTerm.desc(t.recordId),
    ]);

  /// Watches all generated bills (`record.period_id == periodId`), including
  /// transfer fee children (`type = 12`, ASYM-PB-05), newest first.
  /// Remains intact even after the originating `record_period` row is deleted.
  Stream<List<LedgerRecord>> watchHistoryRecords(int periodId) =>
      _historyQuery(periodId).watch();

  /// One-shot fetch of generated bills for `[periodId]`.
  Future<List<LedgerRecord>> getHistoryRecords(int periodId) =>
      _historyQuery(periodId).get();

  /// Watches categories across all books so cross-book periodic rules resolve labels cleanly.
  Stream<List<RecordCategory>> watchAllCategories() =>
      (db.select(db.recordCategories)..orderBy([
            (t) => OrderingTerm.asc(t.accountBookId),
            (t) => OrderingTerm.asc(t.sort),
            (t) => OrderingTerm.asc(t.id),
          ]))
          .watch();
}
