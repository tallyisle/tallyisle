import 'package:drift/drift.dart';

import '../db/database.dart';

/// Read side queries for account books, categories, and tags (F-003, F-005, F-018).
final class CatalogQueries {
  CatalogQueries(this.db);
  final AppDatabase db;

  // ---------------------------------------------------------------------------
  // Books (F-003)
  // ---------------------------------------------------------------------------

  Stream<int> watchCurrentBookId() =>
      (db.select(db.preferences)..where((t) => t.key.equals('current_book_id')))
          .watchSingleOrNull()
          .map((p) => int.tryParse(p?.value ?? '') ?? 1);

  Stream<List<AccountBook>> watchBooks() =>
      (db.select(db.accountBooks)..orderBy([
            (t) => OrderingTerm.asc(t.sort),
            (t) => OrderingTerm.asc(t.id),
          ]))
          .watch();

  Stream<AccountBook?> watchBook(int id) => (db.select(
    db.accountBooks,
  )..where((t) => t.id.equals(id))).watchSingleOrNull();

  Future<int> countRecordsInBook(int bookId) async {
    final row = await db
        .customSelect(
          'SELECT COUNT(*) AS c FROM record WHERE account_book_id = ?',
          variables: [Variable.withInt(bookId)],
        )
        .getSingle();
    return (row.data['c'] as int?) ?? 0;
  }

  // ---------------------------------------------------------------------------
  // Categories (F-005)
  // ---------------------------------------------------------------------------

  Stream<List<RecordCategory>> watchCategories(int bookId) =>
      (db.select(db.recordCategories)
            ..where((t) => t.accountBookId.equals(bookId))
            ..orderBy([
              (t) => OrderingTerm.asc(t.sort),
              (t) => OrderingTerm.asc(t.id),
            ]))
          .watch();

  Stream<List<RecordCategory>> watchActiveCategories(int bookId) =>
      (db.select(db.recordCategories)
            ..where(
              (t) => t.accountBookId.equals(bookId) & t.isHide.equals(false),
            )
            ..orderBy([
              (t) => OrderingTerm.asc(t.sort),
              (t) => OrderingTerm.asc(t.id),
            ]))
          .watch();

  Future<int> countRecordsInCategory(int categoryId) async {
    final cat = await (db.select(
      db.recordCategories,
    )..where((t) => t.id.equals(categoryId))).getSingleOrNull();
    if (cat == null) return 0;

    final List<int> ids;
    if (cat.parentCatId == -1) {
      final subs = await (db.select(
        db.recordCategories,
      )..where((t) => t.parentCatId.equals(categoryId))).get();
      ids = [categoryId, ...subs.map((s) => s.id)];
    } else {
      ids = [categoryId];
    }

    final row = await db
        .customSelect(
          'SELECT COUNT(*) AS c FROM record WHERE record_cat_id IN (${ids.join(',')})',
        )
        .getSingle();
    return (row.data['c'] as int?) ?? 0;
  }

  // ---------------------------------------------------------------------------
  // Tags (F-018)
  // ---------------------------------------------------------------------------

  Stream<List<Tag>> watchTags() =>
      (db.select(db.tags)..orderBy([
            (t) => OrderingTerm.asc(t.sort),
            (t) => OrderingTerm.asc(t.name),
          ]))
          .watch();

  Stream<List<Tag>> watchActiveTags() =>
      (db.select(db.tags)
            ..where((t) => t.hidden.equals(false))
            ..orderBy([
              (t) => OrderingTerm.asc(t.sort),
              (t) => OrderingTerm.asc(t.name),
            ]))
          .watch();

  Future<List<String>> getTagIdsForRecord(String recordId) async {
    final rows = await (db.select(
      db.tagRecords,
    )..where((t) => t.recordId.equals(recordId))).get();
    return rows.map((r) => r.tagId).toList();
  }

  Stream<List<Tag>> watchTagsForRecord(String recordId) {
    final query =
        db.select(db.tagRecords).join([
            innerJoin(db.tags, db.tags.tagId.equalsExp(db.tagRecords.tagId)),
          ])
          ..where(db.tagRecords.recordId.equals(recordId))
          ..orderBy([OrderingTerm.asc(db.tags.sort)]);
    return query.watch().map(
      (rows) => rows.map((r) => r.readTable(db.tags)).toList(),
    );
  }
}
