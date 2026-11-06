import 'package:drift/drift.dart';

import '../../domain/ledger/record_extra.dart';
import '../../domain/ledger/record_relations.dart';
import '../../domain/rules/income_expense.dart';
import '../db/database.dart';

/// Read side: each page watches only the tables/rows it needs (ADR-014).
final class LedgerQueries {
  LedgerQueries(this.db);
  final AppDatabase db;

  Stream<int> watchCurrentBookId() =>
      (db.select(db.preferences)..where((t) => t.key.equals('current_book_id')))
          .watchSingleOrNull()
          .map((p) => int.tryParse(p?.value ?? '') ?? 1);

  Future<void> setCurrentBook(int bookId) => db
      .into(db.preferences)
      .insertOnConflictUpdate(
        PreferencesCompanion.insert(key: 'current_book_id', value: '$bookId'),
      );

  Stream<List<AccountBook>> watchBooks() =>
      (db.select(db.accountBooks)..orderBy([
            (t) => OrderingTerm.asc(t.sort),
            (t) => OrderingTerm.asc(t.id),
          ]))
          .watch();

  Stream<AccountBook?> watchBook(int id) => (db.select(
    db.accountBooks,
  )..where((t) => t.id.equals(id))).watchSingleOrNull();

  Stream<List<Asset>> watchAssets() =>
      (db.select(db.assets)..orderBy([
            (t) => OrderingTerm.asc(t.sort),
            (t) => OrderingTerm.asc(t.id),
          ]))
          .watch();

  Stream<List<RecordCategory>> watchCategories(int bookId) =>
      (db.select(db.recordCategories)
            ..where((t) => t.accountBookId.equals(bookId))
            ..orderBy([
              (t) => OrderingTerm.asc(t.sort),
              (t) => OrderingTerm.asc(t.id),
            ]))
          .watch();

  /// Bills of a book in [startMs, endMs] (closed), newest first, stable order.
  Stream<List<LedgerRecord>> watchRecords(
    int bookId,
    int startMs,
    int endMs, {
    bool includeBalanceAdjust = false,
  }) {
    final query = db.select(db.records)
      ..where(
        (t) =>
            t.accountBookId.equals(bookId) &
            t.recordTime.isBetweenValues(startMs, endMs) &
            t.type.equals(15).not() &
            (includeBalanceAdjust
                ? const Constant(true)
                : t.type.equals(4).not()),
      )
      ..orderBy([
        (t) => OrderingTerm.desc(t.recordTime),
        (t) => OrderingTerm.desc(t.createDate),
        (t) => OrderingTerm.desc(t.recordId),
      ]);
    return query.watch();
  }

  Stream<LedgerRecord?> watchRecord(String id) => (db.select(
    db.records,
  )..where((t) => t.recordId.equals(id))).watchSingleOrNull();

  Future<LedgerRecord?> feeChildOf(String parentId) async {
    final rows = await db
        .customSelect(
          "SELECT * FROM record WHERE type = 12 "
          "AND json_extract(rel_info, '\$.ltfeei.tfobid') = ?",
          variables: [Variable.withString(parentId)],
          readsFrom: {db.records},
        )
        .get();
    if (rows.isEmpty) return null;
    return db.records.map(rows.first.data);
  }
}

StatEntry statEntryOf(LedgerRecord r) => StatEntry(
  type: r.type,
  subType: r.subType,
  moneyMinor: r.moneyMinor,
  discountMinor: r.discountMinor,
  currency: RecordExtra.parse(r.extraInfo).currency,
  relations: RecordRelations.parse(r.relInfo),
  excludeExIn: r.excludeExIn,
  excludeBudget: r.excludeBudget,
);
