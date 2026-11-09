import 'package:drift/drift.dart';

import '../db/database.dart';

/// Data access queries for account bill list and reconciliation mode
/// (F-026 / docs/modules/reconciliation.md).
final class AssetFlowQueries {
  AssetFlowQueries(this.db);
  final AppDatabase db;

  /// All records associated with [assetId] across all books (R1), ordered
  /// newest first (`record_time DESC, record_id DESC`).
  ///
  /// Re-emits whenever either `record` or `asset` changes (R7).
  Stream<List<LedgerRecord>> watchAssetRecords(int assetId) {
    return db
        .customSelect(
          'SELECT * FROM record '
          'WHERE asset_id = ? OR from_asset_id = ? OR to_asset_id = ? '
          'ORDER BY record_time DESC, record_id DESC',
          variables: [
            Variable.withInt(assetId),
            Variable.withInt(assetId),
            Variable.withInt(assetId),
          ],
          readsFrom: {db.records, db.assets},
        )
        .watch()
        .map((rows) => rows.map((row) => db.records.map(row.data)).toList());
  }

  /// All categories across all books, ordered by sort and id.
  Stream<List<RecordCategory>> watchAllCategories() =>
      (db.select(db.recordCategories)..orderBy([
            (t) => OrderingTerm.asc(t.sort),
            (t) => OrderingTerm.asc(t.id),
          ]))
          .watch();
}
