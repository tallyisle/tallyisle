import 'package:drift/drift.dart';

import '../../domain/model/codes.dart';
import '../../domain/rules/installment_rules.dart';
import '../db/database.dart';

/// Enriched view model of an [Installment] with computed schedule and progress.
final class InstallmentSummaryView {
  const InstallmentSummaryView({
    required this.installment,
    required this.schedule,
    required this.progress,
    required this.extra,
  });

  factory InstallmentSummaryView.fromRow(Installment row) {
    final credited = parseCreditedPeriods(row.credited, maxPeriod: row.periods);
    final schedule = buildInstallmentSchedule(
      installmentId: row.id,
      principalMinor: row.principalMinor,
      periods: row.periods,
      chargeMinor: row.chargeMinor,
      chargeWay: row.chargeWay,
      calWay: row.calWay,
      remainderIn: row.remainderIn,
      startDateMs: row.startDate,
      creditedPeriods: credited,
    );
    final progress = computeInstallmentProgress(
      schedule: schedule,
      principalMinor: row.principalMinor,
      chargeMinor: row.chargeMinor,
      startDateMs: row.startDate,
      currentNextPeriod: row.nextPeriod,
    );
    return InstallmentSummaryView(
      installment: row,
      schedule: schedule,
      progress: progress,
      extra: InstallmentExtra.parse(row.exi),
    );
  }

  final Installment installment;
  final List<InstallmentPeriodItem> schedule;
  final InstallmentProgress progress;
  final InstallmentExtra extra;

  bool get isFinished => progress.isFinished;
}

/// Aggregate totals for an installment list tab (`进行中` or `已完结`).
final class InstallmentTabTotals {
  const InstallmentTabTotals({
    required this.count,
    required this.totalPrincipalMinor,
    required this.totalChargeMinor,
    required this.remainingPrincipalMinor,
    required this.remainingFeeMinor,
  });

  factory InstallmentTabTotals.fromItems(
    Iterable<InstallmentSummaryView> items,
  ) {
    var count = 0;
    var totalPrincipal = BigInt.zero;
    var totalCharge = BigInt.zero;
    var remPrincipal = BigInt.zero;
    var remFee = BigInt.zero;
    for (final item in items) {
      count++;
      totalPrincipal += item.installment.principalMinor;
      totalCharge += item.installment.chargeMinor;
      remPrincipal += item.progress.remainingPrincipalMinor;
      remFee += item.progress.remainingFeeMinor;
    }
    return InstallmentTabTotals(
      count: count,
      totalPrincipalMinor: totalPrincipal,
      totalChargeMinor: totalCharge,
      remainingPrincipalMinor: remPrincipal,
      remainingFeeMinor: remFee,
    );
  }

  final int count;
  final BigInt totalPrincipalMinor;
  final BigInt totalChargeMinor;
  final BigInt remainingPrincipalMinor;
  final BigInt remainingFeeMinor;

  BigInt get remainingTotalMinor => remainingPrincipalMinor + remainingFeeMinor;
}

/// Full detail view combining schedule, progress, and live posted records.
final class InstallmentDetailView {
  const InstallmentDetailView({
    required this.summary,
    required this.recordsByPeriod,
    required this.allRecords,
  });

  factory InstallmentDetailView.compose(
    Installment row,
    Iterable<LedgerRecord> candidateRecords,
  ) {
    final summary = InstallmentSummaryView.fromRow(row);
    final byPeriod = <int, List<LedgerRecord>>{};
    final matched = <LedgerRecord>[];

    for (final r in candidateRecords) {
      final parsed = parseInstallmentRecordKey(r.installment);
      if (parsed == null || parsed.installmentId != row.id) continue;
      matched.add(r);
      byPeriod.putIfAbsent(parsed.period, () => <LedgerRecord>[]).add(r);
    }

    for (final list in byPeriod.values) {
      list.sort((a, b) {
        final aFee = a.type == RecordType.fee ? 1 : 0;
        final bFee = b.type == RecordType.fee ? 1 : 0;
        if (aFee != bFee) return aFee.compareTo(bFee);
        return b.recordTime.compareTo(a.recordTime);
      });
    }

    return InstallmentDetailView(
      summary: summary,
      recordsByPeriod: Map<int, List<LedgerRecord>>.unmodifiable({
        for (final e in byPeriod.entries)
          e.key: List<LedgerRecord>.unmodifiable(e.value),
      }),
      allRecords: List<LedgerRecord>.unmodifiable(matched),
    );
  }

  final InstallmentSummaryView summary;
  final Map<int, List<LedgerRecord>> recordsByPeriod;
  final List<LedgerRecord> allRecords;

  List<LedgerRecord> recordsForPeriod(int period) =>
      recordsByPeriod[period] ?? const <LedgerRecord>[];
}

/// Read-only queries for installments (F-010, ADR-014).
/// Strictly side-effect free (fixes original `02zb` query-time deletion hazard).
final class InstallmentQueries {
  InstallmentQueries(this.db);
  final AppDatabase db;

  Stream<List<Installment>> watchInstallments({int? bookId}) {
    final query = db.select(db.installments);
    if (bookId != null) {
      query.where((t) => t.bookId.equals(bookId));
    }
    query.orderBy([
      (t) => OrderingTerm.desc(t.createDate),
      (t) => OrderingTerm.desc(t.id),
    ]);
    return query.watch();
  }

  Stream<List<InstallmentSummaryView>> watchActiveInstallments({int? bookId}) =>
      watchInstallments(bookId: bookId).map((rows) {
        final active = [
          for (final r in rows) InstallmentSummaryView.fromRow(r),
        ].where((v) => !v.isFinished).toList();
        active.sort((a, b) {
          final cmp = a.progress.nextPeriodDateMs.compareTo(
            b.progress.nextPeriodDateMs,
          );
          if (cmp != 0) return cmp;
          return b.installment.id.compareTo(a.installment.id);
        });
        return List<InstallmentSummaryView>.unmodifiable(active);
      });

  Stream<List<InstallmentSummaryView>> watchFinishedInstallments({
    int? bookId,
  }) => watchInstallments(bookId: bookId).map((rows) {
    final finished = [
      for (final r in rows) InstallmentSummaryView.fromRow(r),
    ].where((v) => v.isFinished).toList();
    finished.sort((a, b) {
      final cmp = b.installment.createDate.compareTo(a.installment.createDate);
      if (cmp != 0) return cmp;
      return b.installment.id.compareTo(a.installment.id);
    });
    return List<InstallmentSummaryView>.unmodifiable(finished);
  });

  Stream<Installment?> watchInstallment(int id) => (db.select(
    db.installments,
  )..where((t) => t.id.equals(id))).watchSingleOrNull();

  Future<Installment?> getInstallment(int id) => (db.select(
    db.installments,
  )..where((t) => t.id.equals(id))).getSingleOrNull();

  /// Watches live `record` rows linked to [installmentId] (`"<id>-<period>"`).
  Stream<List<LedgerRecord>> watchRecordsForInstallment(int installmentId) {
    final query = db.select(db.records)
      ..where((t) => t.installment.like('$installmentId-%'))
      ..orderBy([
        (t) => OrderingTerm.desc(t.recordTime),
        (t) => OrderingTerm.desc(t.createDate),
        (t) => OrderingTerm.desc(t.recordId),
      ]);
    return query.watch().map(
      (rows) => List<LedgerRecord>.unmodifiable([
        for (final r in rows)
          if (parseInstallmentRecordKey(r.installment)?.installmentId ==
              installmentId)
            r,
      ]),
    );
  }

  Future<InstallmentDetailView?> getInstallmentDetail(int installmentId) async {
    final row = await getInstallment(installmentId);
    if (row == null) return null;
    final candidates =
        await (db.select(db.records)
              ..where((t) => t.installment.like('$installmentId-%'))
              ..orderBy([
                (t) => OrderingTerm.desc(t.recordTime),
                (t) => OrderingTerm.desc(t.createDate),
                (t) => OrderingTerm.desc(t.recordId),
              ]))
            .get();
    return InstallmentDetailView.compose(row, candidates);
  }
}
