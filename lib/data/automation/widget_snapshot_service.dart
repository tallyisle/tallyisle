import 'package:drift/drift.dart';

import '../../domain/model/codes.dart';
import '../../domain/rules/billing_period.dart';
import '../../domain/rules/income_expense.dart';
import '../../platform/app_widgets.dart';
import '../../platform/files.dart';
import '../db/database.dart';
import '../db/failures.dart';
import '../repo/ledger_queries.dart' show statEntryOf;

/// Computes exact `BigInt` period/today/budget snapshots and synchronizes them to
/// Android home-screen `AppWidgetProvider`s (`F-034`, `ADR-008`, `ADR-011`).
final class WidgetSnapshotService {
  WidgetSnapshotService(this.db, {AppWidgetBridge? bridge})
    : _bridge = bridge ?? createAppWidgetBridge();

  final AppDatabase db;
  final AppWidgetBridge _bridge;

  Capability get capability => _bridge.capability;

  /// Computes the live widget snapshot for `current_book_id` as of [now].
  Future<WidgetSnapshotPayload> computeCurrentSnapshot({DateTime? now}) =>
      guardDatabase(() async {
        final moment = (now ?? DateTime.fromMillisecondsSinceEpoch(db.nowMs()))
            .toLocal();

        final pref = await (db.select(
          db.preferences,
        )..where((t) => t.key.equals('current_book_id'))).getSingleOrNull();
        final currentBookId = int.tryParse(pref?.value ?? '') ?? 1;

        final book =
            await (db.select(
              db.accountBooks,
            )..where((t) => t.id.equals(currentBookId))).getSingleOrNull() ??
            await (db.select(db.accountBooks)
                  ..orderBy([(t) => OrderingTerm.asc(t.id)])
                  ..limit(1))
                .getSingleOrNull();

        if (book == null) {
          return WidgetSnapshotPayload.empty(
            updatedAtMs: moment.millisecondsSinceEpoch,
          );
        }

        final period = BillingPeriod.containing(moment, book.startDay);
        final periodRecords =
            await (db.select(db.records)..where(
                  (t) =>
                      t.accountBookId.equals(book.id) &
                      t.recordTime.isBetweenValues(
                        period.startMs,
                        period.endMs,
                      ) &
                      t.type.equals(RecordType.reimburseReceipt).not() &
                      t.type.equals(RecordType.balanceAdjust).not(),
                ))
                .get();

        final periodSummary = aggregateIncomeExpense(
          periodRecords.map(statEntryOf),
          scope: StatScope.home,
        );

        final todayStart = DateTime(moment.year, moment.month, moment.day);
        final todayEnd = DateTime(
          moment.year,
          moment.month,
          moment.day + 1,
        ).subtract(const Duration(milliseconds: 1));
        final todayStartMs = todayStart.millisecondsSinceEpoch;
        final todayEndMs = todayEnd.millisecondsSinceEpoch;

        final List<LedgerRecord> todayRecords;
        if (todayStartMs >= period.startMs && todayEndMs <= period.endMs) {
          todayRecords = periodRecords
              .where(
                (r) =>
                    r.recordTime >= todayStartMs && r.recordTime <= todayEndMs,
              )
              .toList(growable: false);
        } else {
          todayRecords =
              await (db.select(db.records)..where(
                    (t) =>
                        t.accountBookId.equals(book.id) &
                        t.recordTime.isBetweenValues(todayStartMs, todayEndMs) &
                        t.type.equals(RecordType.reimburseReceipt).not() &
                        t.type.equals(RecordType.balanceAdjust).not(),
                  ))
                  .get();
        }
        final todaySummary = aggregateIncomeExpense(
          todayRecords.map(statEntryOf),
          scope: StatScope.home,
        );

        final totalBudget =
            await (db.select(db.budgets)
                  ..where(
                    (t) =>
                        t.bookId.equals(book.id) &
                        t.budgetType.equals(0) &
                        t.recordCatId.equals(noRef) &
                        t.section.equals(period.monthlySection),
                  )
                  ..limit(1))
                .getSingleOrNull();

        BigInt? budgetRemainingMinor;
        if (totalBudget != null && totalBudget.amountMinor > BigInt.zero) {
          final budgetUsed = aggregateIncomeExpense(
            periodRecords.map(statEntryOf),
            scope: StatScope.budget,
          ).expense;
          budgetRemainingMinor = totalBudget.amountMinor - budgetUsed;
        }

        final periodLabel = book.startDay == 1
            ? '${period.year}年${period.month}月'
            : '${period.month}月账期';

        return WidgetSnapshotPayload(
          bookName: book.name,
          periodLabel: periodLabel,
          expenseMinor: periodSummary.expense,
          incomeMinor: periodSummary.income,
          balanceMinor: periodSummary.balance,
          todayExpenseMinor: todaySummary.expense,
          budgetRemainingMinor: budgetRemainingMinor,
          updatedAtMs: moment.millisecondsSinceEpoch,
        );
      });

  /// Computes the latest snapshot from SQLite and pushes it to Android `AppWidgetManager`.
  Future<(WidgetSnapshotPayload, Map<DesktopWidgetKind, int>)> syncToPlatform({
    DateTime? now,
  }) async {
    final snapshot = await computeCurrentSnapshot(now: now);
    final counts = await _bridge.updateSnapshot(snapshot);
    return (snapshot, counts);
  }

  /// Queries placed instance counts per [DesktopWidgetKind].
  Future<Map<DesktopWidgetKind, int>> getActiveWidgetCounts() =>
      _bridge.getActiveWidgetCounts();

  /// Syncs fresh data first, then requests Android 8.0+ widget pinning for [kind].
  Future<bool> requestPinWidget(DesktopWidgetKind kind, {DateTime? now}) async {
    await syncToPlatform(now: now);
    return _bridge.requestPinWidget(kind);
  }
}
