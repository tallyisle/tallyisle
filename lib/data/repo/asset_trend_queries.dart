import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/ledger/record_extra.dart';
import '../../domain/rules/asset_overview.dart';
import '../../domain/rules/asset_trend.dart';
import '../db/database.dart';

/// Data access queries for the asset trend module (F-030 / docs/modules/asset-trend.md).
final class AssetTrendQueries {
  AssetTrendQueries(this.db);
  final AppDatabase db;

  /// All assets across all books, mapped to [TrendAccount].
  Stream<List<TrendAccount>> watchAccounts() {
    return (db.select(db.assets)..orderBy([
          (t) => OrderingTerm.asc(t.sort),
          (t) => OrderingTerm.asc(t.id),
        ]))
        .watch()
        .map((list) => list.map(accountFromAsset).toList());
  }

  /// All account books.
  Stream<List<AccountBook>> watchBooks() =>
      (db.select(db.accountBooks)..orderBy([
            (t) => OrderingTerm.asc(t.sort),
            (t) => OrderingTerm.asc(t.id),
          ]))
          .watch();

  /// Map of `bookId -> startDay` across all account books.
  Stream<Map<int, int>> watchBookStartDays() =>
      watchBooks().map((books) => {for (final b in books) b.id: b.startDay});

  /// Exchange rate table constructed from enabled currencies.
  Stream<RateTable> watchRateTable() =>
      (db.select(
        db.currencies,
      )..where((t) => t.enable.equals(true))).watch().map(
        (list) => RateTable({for (final c in list) c.code: c.rateToAnchor}),
      );

  /// All records with positive timestamps across all books (SQL-AT-10).
  Stream<List<TrendRecord>> watchTrendRecords() {
    return (db.select(db.records)
          ..where((t) => t.recordTime.isBiggerThanValue(0))
          ..orderBy([
            (t) => OrderingTerm.desc(t.recordTime),
            (t) => OrderingTerm.desc(t.recordId),
          ]))
        .watch()
        .map((rows) => rows.map(recordFromLedger).toList());
  }

  /// Preference key `asset_trend_mode`: '0' (current year) or '1' (all time).
  Stream<String> watchAssetTrendMode() =>
      (db.select(db.preferences)
            ..where((t) => t.key.equals('asset_trend_mode')))
          .watchSingleOrNull()
          .map((p) => p?.value ?? '0');

  /// Gets preference key `asset_trend_mode` once.
  Future<String> getAssetTrendMode() async {
    final p = await (db.select(
      db.preferences,
    )..where((t) => t.key.equals('asset_trend_mode'))).getSingleOrNull();
    return p?.value ?? '0';
  }

  /// Updates preference key `asset_trend_mode`.
  Future<void> setAssetTrendMode(String mode) => db
      .into(db.preferences)
      .insertOnConflictUpdate(
        PreferencesCompanion.insert(key: 'asset_trend_mode', value: mode),
      );

  static TrendAccount accountFromAsset(Asset a) => TrendAccount(
    id: a.id,
    name: a.name,
    type: a.type,
    subType: a.subType,
    balanceMinor: a.balanceMinor,
    isEffectiveAsset: a.isEffectiveAsset,
    status: a.status,
    currency: a.currency,
    groupName: a.groupName,
    creditInfo: a.creditInfo,
  );

  static TrendRecord recordFromLedger(LedgerRecord r) {
    CurrencySnapshot? curr;
    if (r.extraInfo != null && r.extraInfo!.isNotEmpty) {
      try {
        final decoded = jsonDecode(r.extraInfo!);
        if (decoded is Map) {
          curr = CurrencySnapshot.fromJson(decoded['curr']);
        }
      } catch (_) {}
    }

    return TrendRecord(
      id: r.recordId,
      type: r.type,
      subType: r.subType,
      moneyMinor: r.moneyMinor,
      discountMinor: r.discountMinor,
      recordTime: r.recordTime,
      assetId: r.assetId,
      fromAssetId: r.fromAssetId,
      toAssetId: r.toAssetId,
      accountBookId: r.accountBookId,
      currency: curr,
    );
  }
}
