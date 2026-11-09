import 'package:drift/drift.dart';

import '../../domain/model/codes.dart';
import '../db/database.dart';

/// Read queries for credit card accounts, statements, and shared groups (F-028).
final class CreditQueries {
  CreditQueries(this.db);
  final AppDatabase db;

  /// Stream of all records touching the card across all books (docs/modules/credit-account.md R3).
  ///
  /// Matching criteria: `asset_id = id OR from_asset_id = id OR to_asset_id = id`.
  /// Preserves all books, exclude_ex_in, and exclude_budget flags.
  /// Ordered newest first: record_time DESC, create_date DESC, record_id DESC.
  Stream<List<LedgerRecord>> watchCardRecords(int cardId) {
    final query = db.select(db.records)
      ..where(
        (t) =>
            t.assetId.equals(cardId) |
            t.fromAssetId.equals(cardId) |
            t.toAssetId.equals(cardId),
      )
      ..orderBy([
        (t) => OrderingTerm.desc(t.recordTime),
        (t) => OrderingTerm.desc(t.createDate),
        (t) => OrderingTerm.desc(t.recordId),
      ]);
    return query.watch();
  }

  /// Stream of all credit cards (`type == AssetType.credit`).
  Stream<List<Asset>> watchCreditCards() {
    return (db.select(db.assets)
          ..where((t) => t.type.equals(AssetType.credit))
          ..orderBy([
            (t) => OrderingTerm.asc(t.sort),
            (t) => OrderingTerm.asc(t.id),
          ]))
        .watch();
  }
}
