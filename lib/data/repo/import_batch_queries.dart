import 'package:drift/drift.dart';

import '../../domain/model/codes.dart';
import '../db/database.dart';

/// Summary of one `import_platform` batch combined with its live record counts.
final class ImportBatchSummary {
  const ImportBatchSummary({
    required this.batch,
    required this.liveBillCount,
    required this.liveTotalRowCount,
  });

  final ImportPlatform batch;

  /// Live primary bills (`type != 12` fee child) still present in `record`.
  final int liveBillCount;

  /// Total live rows in `record` with `platform_id == batch.id` (including `type=12` fee children).
  final int liveTotalRowCount;
}

/// Enriched view of a single imported bill for batch drill-down (`/bkp/RLAct`).
final class BatchRecordItem {
  const BatchRecordItem({
    required this.record,
    this.bookName,
    this.categoryName,
    this.assetName,
    this.fromAssetName,
    this.toAssetName,
  });

  final LedgerRecord record;
  final String? bookName;
  final String? categoryName;
  final String? assetName;
  final String? fromAssetName;
  final String? toAssetName;
}

/// Reactive read queries for import batches and batch drill-down (`ADR-014`).
final class ImportBatchQueries {
  ImportBatchQueries(this.db);
  final AppDatabase db;

  /// Watches visible (`hidden == false`) or hidden (`hidden == true`) batches,
  /// newest `import_time` first.
  Stream<List<ImportBatchSummary>> watchBatches({required bool hidden}) => db
      .customSelect(
        'SELECT ip.*, '
        'COALESCE(SUM(CASE WHEN r.record_id IS NOT NULL AND r.type != ?2 THEN 1 ELSE 0 END), 0) AS live_bills, '
        'COALESCE(COUNT(r.record_id), 0) AS live_rows '
        'FROM import_platform ip '
        'LEFT JOIN record r ON r.platform_id = ip.id '
        'WHERE ip.hidden = ?1 '
        'GROUP BY ip.id '
        'ORDER BY ip.import_time DESC, ip.id DESC',
        variables: [
          Variable.withBool(hidden),
          Variable.withInt(RecordType.fee),
        ],
        readsFrom: {db.importPlatforms, db.records},
      )
      .watch()
      .map(
        (rows) => [
          for (final row in rows)
            ImportBatchSummary(
              batch: db.importPlatforms.map(row.data),
              liveBillCount: row.read<int>('live_bills'),
              liveTotalRowCount: row.read<int>('live_rows'),
            ),
        ],
      );

  Future<ImportPlatform?> getBatch(int batchId) => (db.select(
    db.importPlatforms,
  )..where((t) => t.id.equals(batchId))).getSingleOrNull();

  Stream<ImportPlatform?> watchBatch(int batchId) => (db.select(
    db.importPlatforms,
  )..where((t) => t.id.equals(batchId))).watchSingleOrNull();

  /// Watches all live records belonging to [batchId] across books (`/bkp/RLAct`).
  Stream<List<BatchRecordItem>> watchBatchRecords(int batchId) => db
      .customSelect(
        'SELECT r.*, '
        'b.name AS book_name, '
        'c.name AS cat_name, '
        'a1.name AS asset_name, '
        'a2.name AS from_asset_name, '
        'a3.name AS to_asset_name '
        'FROM record r '
        'LEFT JOIN account_book b ON r.account_book_id = b.id '
        'LEFT JOIN record_category c ON r.record_cat_id = c.id '
        'LEFT JOIN asset a1 ON r.asset_id = a1.id '
        'LEFT JOIN asset a2 ON r.from_asset_id = a2.id '
        'LEFT JOIN asset a3 ON r.to_asset_id = a3.id '
        'WHERE r.platform_id = ?1 '
        'ORDER BY r.record_time DESC, r.create_date DESC, r.record_id DESC',
        variables: [Variable.withInt(batchId)],
        readsFrom: {
          db.records,
          db.accountBooks,
          db.recordCategories,
          db.assets,
        },
      )
      .watch()
      .map(
        (rows) => [
          for (final row in rows)
            BatchRecordItem(
              record: db.records.map(row.data),
              bookName: row.read<String?>('book_name'),
              categoryName: row.read<String?>('cat_name'),
              assetName: row.read<String?>('asset_name'),
              fromAssetName: row.read<String?>('from_asset_name'),
              toAssetName: row.read<String?>('to_asset_name'),
            ),
        ],
      );
}
