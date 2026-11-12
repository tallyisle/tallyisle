import 'package:drift/drift.dart';

import '../../domain/ledger/record_extra.dart';
import '../../domain/ledger/record_relations.dart';
import '../../domain/model/codes.dart';
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

  Future<int> getCurrentBookId() async {
    final p = await (db.select(
      db.preferences,
    )..where((t) => t.key.equals('current_book_id'))).getSingleOrNull();
    final parsed = int.tryParse(p?.value ?? '');
    if (parsed != null) return parsed;
    final books = await getBooks();
    return books.isNotEmpty ? books.first.id : 1;
  }

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

  Future<List<AccountBook>> getBooks() =>
      (db.select(db.accountBooks)..orderBy([
            (t) => OrderingTerm.asc(t.sort),
            (t) => OrderingTerm.asc(t.id),
          ]))
          .get();

  Stream<AccountBook?> watchBook(int id) => (db.select(
    db.accountBooks,
  )..where((t) => t.id.equals(id))).watchSingleOrNull();

  Future<AccountBook?> getBook(int id) => (db.select(
    db.accountBooks,
  )..where((t) => t.id.equals(id))).getSingleOrNull();

  Stream<List<Asset>> watchAssets() =>
      (db.select(db.assets)..orderBy([
            (t) => OrderingTerm.asc(t.sort),
            (t) => OrderingTerm.asc(t.id),
          ]))
          .watch();

  Future<List<Asset>> getAssets({bool includeArchived = true}) {
    final query = db.select(db.assets);
    if (!includeArchived) {
      query.where((t) => t.status.equals(AssetStatus.active));
    }
    query.orderBy([
      (t) => OrderingTerm.asc(t.sort),
      (t) => OrderingTerm.asc(t.id),
    ]);
    return query.get();
  }

  Stream<List<AssetBook>> watchAssetBooks() => db.select(db.assetBooks).watch();

  Future<List<AssetBook>> getAssetBooks() => db.select(db.assetBooks).get();

  Stream<Asset?> watchAsset(int id) =>
      (db.select(db.assets)..where((t) => t.id.equals(id))).watchSingleOrNull();

  Future<Asset?> getAsset(int id) =>
      (db.select(db.assets)..where((t) => t.id.equals(id))).getSingleOrNull();

  Stream<List<Currency>> watchCurrencies() => db.select(db.currencies).watch();

  Future<List<Currency>> getCurrencies() => db.select(db.currencies).get();

  Stream<List<RecordCategory>> watchCategories(int bookId) =>
      (db.select(db.recordCategories)
            ..where((t) => t.accountBookId.equals(bookId))
            ..orderBy([
              (t) => OrderingTerm.asc(t.sort),
              (t) => OrderingTerm.asc(t.id),
            ]))
          .watch();

  Future<List<RecordCategory>> getCategories(int bookId) =>
      (db.select(db.recordCategories)
            ..where((t) => t.accountBookId.equals(bookId))
            ..orderBy([
              (t) => OrderingTerm.asc(t.sort),
              (t) => OrderingTerm.asc(t.id),
            ]))
          .get();

  SimpleSelectStatement<$RecordsTable, LedgerRecord> _recordsQuery(
    int bookId,
    int startMs,
    int endMs, {
    bool includeBalanceAdjust = false,
  }) {
    return db.select(db.records)
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
  }

  /// Bills of a book in [startMs, endMs] (closed), newest first, stable order.
  Stream<List<LedgerRecord>> watchRecords(
    int bookId,
    int startMs,
    int endMs, {
    bool includeBalanceAdjust = false,
  }) => _recordsQuery(
    bookId,
    startMs,
    endMs,
    includeBalanceAdjust: includeBalanceAdjust,
  ).watch();

  Future<List<LedgerRecord>> getRecords(
    int bookId,
    int startMs,
    int endMs, {
    bool includeBalanceAdjust = false,
  }) => _recordsQuery(
    bookId,
    startMs,
    endMs,
    includeBalanceAdjust: includeBalanceAdjust,
  ).get();

  Stream<LedgerRecord?> watchRecord(String id) => (db.select(
    db.records,
  )..where((t) => t.recordId.equals(id))).watchSingleOrNull();

  Future<LedgerRecord?> getRecord(String id) => (db.select(
    db.records,
  )..where((t) => t.recordId.equals(id))).getSingleOrNull();

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
