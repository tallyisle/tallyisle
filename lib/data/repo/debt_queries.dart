import 'package:drift/drift.dart';

import '../../domain/model/codes.dart';
import '../db/database.dart';
import '../db/seed.dart';

/// Read-only queries for F-011 Debt Management (`ADR-014`).
final class DebtQueries {
  DebtQueries(this.db);
  final AppDatabase db;

  /// Watches debt accounts (`asset.type == 4`) scoped by [bookId] (`CE-DM-06`):
  /// - `bookId == null` (all-books view): returns all debts.
  /// - `bookId == defaultBookId`: returns debts bound to `defaultBookId` plus
  ///   any legacy unbound debts (no `asset_book` rows).
  /// - `bookId != defaultBookId`: returns ONLY debts explicitly bound to
  ///   `bookId` (unbound debts do not leak into other single books).
  Stream<List<Asset>> watchDebts({int? bookId}) {
    if (bookId == null) {
      return db
          .customSelect(
            'SELECT * FROM asset WHERE type = ? '
            'ORDER BY sort ASC, create_date DESC, id DESC',
            variables: [Variable.withInt(AssetType.debt)],
            readsFrom: {db.assets, db.assetBooks},
          )
          .watch()
          .map((rows) => [for (final r in rows) db.assets.map(r.data)]);
    }

    if (bookId == defaultBookId) {
      return db
          .customSelect(
            'SELECT * FROM asset WHERE type = ? '
            'AND (id IN (SELECT asset_id FROM asset_book WHERE book_id = ?) '
            'OR id NOT IN (SELECT asset_id FROM asset_book)) '
            'ORDER BY sort ASC, create_date DESC, id DESC',
            variables: [
              Variable.withInt(AssetType.debt),
              Variable.withInt(bookId),
            ],
            readsFrom: {db.assets, db.assetBooks},
          )
          .watch()
          .map((rows) => [for (final r in rows) db.assets.map(r.data)]);
    }

    return db
        .customSelect(
          'SELECT * FROM asset WHERE type = ? '
          'AND id IN (SELECT asset_id FROM asset_book WHERE book_id = ?) '
          'ORDER BY sort ASC, create_date DESC, id DESC',
          variables: [
            Variable.withInt(AssetType.debt),
            Variable.withInt(bookId),
          ],
          readsFrom: {db.assets, db.assetBooks},
        )
        .watch()
        .map((rows) => [for (final r in rows) db.assets.map(r.data)]);
  }

  /// Watches a single debt account (`type == 4`) by [debtId].
  Stream<Asset?> watchDebt(int debtId) =>
      (db.select(db.assets)
            ..where((t) => t.id.equals(debtId) & t.type.equals(AssetType.debt)))
          .watchSingleOrNull();

  /// Watches book IDs bound to [debtId] in `asset_book`.
  Stream<List<int>> watchDebtBookIds(int debtId) =>
      (db.select(db.assetBooks)
            ..where((t) => t.assetId.equals(debtId))
            ..orderBy([(t) => OrderingTerm.asc(t.bookId)]))
          .watch()
          .map((rows) => [for (final r in rows) r.bookId]);

  /// Watches all debt records (`type IN (5, 6, 7, 8, 10)`) associated with
  /// [debtId] across all books (`SQL-DM-03`), newest first (`+2ms` interest
  /// strictly precedes `+1ms` principal of the same operation).
  Stream<List<LedgerRecord>> watchDebtRecords(int debtId) => db
      .customSelect(
        'SELECT * FROM record '
        'WHERE (from_asset_id = ?1 OR to_asset_id = ?1 OR asset_id = ?1) '
        'AND type IN (5, 6, 7, 8, 10) '
        'ORDER BY record_time DESC, create_date DESC, record_id DESC',
        variables: [Variable.withInt(debtId)],
        readsFrom: {db.records, db.assets},
      )
      .watch()
      .map((rows) => [for (final r in rows) db.records.map(r.data)]);

  /// Watches active non-debt accounts eligible as funding accounts.
  Stream<List<Asset>> watchFundingAccounts() =>
      (db.select(db.assets)
            ..where(
              (t) =>
                  t.type.equals(AssetType.debt).not() &
                  t.status.equals(AssetStatus.active),
            )
            ..orderBy([
              (t) => OrderingTerm.asc(t.sort),
              (t) => OrderingTerm.asc(t.id),
            ]))
          .watch();
}
