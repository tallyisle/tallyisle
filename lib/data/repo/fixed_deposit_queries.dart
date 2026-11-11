import 'package:drift/drift.dart';

import '../../domain/ledger/record_extra.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/asset_overview.dart';
import '../../domain/rules/currency_rates.dart';
import '../../domain/rules/fixed_deposit.dart';
import '../db/database.dart';

/// Resolved deposit item paired with its host [asset] and original array [index].
final class FixedDepositEntry {
  const FixedDepositEntry({
    required this.asset,
    required this.index,
    required this.item,
    this.fromAssetName,
    required this.incomeRecordExists,
    this.settledBaseMinor,
  });

  final Asset asset;

  /// Index inside `asset.fixed_deposit_info` before UI sorting.
  final int index;
  final FixedDepositItem item;
  final String? fromAssetName;
  final bool incomeRecordExists;
  final BigInt? settledBaseMinor;

  String get effectiveCurrency =>
      normalizeCurrency(item.currency) ??
      normalizeCurrency(asset.currency) ??
      baseCurrency;
}

/// Read-side projection for the Fixed Deposit Management screen (`FixedDepositPage`).
final class FixedDepositOverview {
  const FixedDepositOverview({
    required this.entries,
    required this.header,
    required this.eligibleAssets,
  });

  final List<FixedDepositEntry> entries;
  final FixedDepositHeaderSummary header;
  final List<Asset> eligibleAssets;
}

/// Read queries for fixed deposits (F-027, ADR-014).
final class FixedDepositQueries {
  FixedDepositQueries(this.db);
  final AppDatabase db;

  /// Eligible active accounts (`status == 0 && type != 6 && type != 4`),
  /// including `isEffectiveAsset == 0` accounts (`SQL-FD-01` + `ASYM-FD-06`).
  Stream<List<Asset>> watchEligibleAssets() =>
      (db.select(db.assets)
            ..where(
              (t) =>
                  t.status.equals(AssetStatus.active) &
                  t.type.equals(AssetType.credit).not() &
                  t.type.equals(AssetType.debt).not(),
            )
            ..orderBy([
              (t) => OrderingTerm.asc(t.sort),
              (t) => OrderingTerm.asc(t.id),
            ]))
          .watch();

  Future<List<Asset>> getEligibleAssets() =>
      (db.select(db.assets)
            ..where(
              (t) =>
                  t.status.equals(AssetStatus.active) &
                  t.type.equals(AssetType.credit).not() &
                  t.type.equals(AssetType.debt).not(),
            )
            ..orderBy([
              (t) => OrderingTerm.asc(t.sort),
              (t) => OrderingTerm.asc(t.id),
            ]))
          .get();

  /// Cross-book live record lookup (`SQL-FD-04`).
  Future<LedgerRecord?> getLiveRecord(String recordId) => (db.select(
    db.records,
  )..where((t) => t.recordId.equals(recordId))).getSingleOrNull();

  /// Reactive stream of sorted fixed deposits and top 3-metric header summary.
  /// If [assetId] is provided, filters to that account while still enforcing
  /// the uniform active eligibility gate (`ASYM-FD-06`).
  Stream<FixedDepositOverview> watchOverview({int? assetId}) => db
      .customSelect(
        'SELECT 1',
        readsFrom: {db.assets, db.records, db.currencies},
      )
      .watch()
      .asyncMap((_) => getOverview(assetId: assetId));

  Future<FixedDepositOverview> getOverview({int? assetId}) async {
    final allAssets =
        await (db.select(db.assets)..orderBy([
              (t) => OrderingTerm.asc(t.sort),
              (t) => OrderingTerm.asc(t.id),
            ]))
            .get();

    final assetById = <int, Asset>{for (final a in allAssets) a.id: a};
    final eligibleAssets = [
      for (final a in allAssets)
        if (isFixedDepositEligibleAccount(type: a.type, status: a.status)) a,
    ];

    final targetAssets = assetId == null
        ? eligibleAssets
        : [
            for (final a in eligibleAssets)
              if (a.id == assetId) a,
          ];

    final currencyRows = await db.select(db.currencies).get();
    final rates = RateTable({
      baseCurrency: '1',
      for (final c in currencyRows)
        if (c.enable) c.code: c.rateToAnchor,
    });

    final rawItems = <(Asset, int, FixedDepositItem)>[];
    final incomeIds = <String>{};
    for (final asset in targetAssets) {
      if (asset.fixedDepositInfo == null ||
          asset.fixedDepositInfo!.trim().isEmpty) {
        continue;
      }
      final decoded = decodeFixedDepositList(asset.fixedDepositInfo);
      for (var i = 0; i < decoded.length; i++) {
        final item = decoded[i];
        rawItems.add((asset, i, item));
        if (item.incomeRecordId != null &&
            item.incomeRecordId!.trim().isNotEmpty) {
          incomeIds.add(item.incomeRecordId!);
        }
      }
    }

    final liveIncomeRecords = <String, LedgerRecord>{};
    if (incomeIds.isNotEmpty) {
      final rows = await (db.select(
        db.records,
      )..where((t) => t.recordId.isIn(incomeIds.toList()))).get();
      for (final r in rows) {
        liveIncomeRecords[r.recordId] = r;
      }
    }

    final settledRecordBaseMinors = <String, BigInt>{};
    final unsortedEntries = <FixedDepositEntry>[];

    for (final (asset, index, item) in rawItems) {
      final incId = item.incomeRecordId;
      final liveRec = incId == null ? null : liveIncomeRecords[incId];
      BigInt? settledBase;
      if (liveRec != null && incId != null) {
        settledBase = _recordBaseMinor(liveRec, asset, rates);
        settledRecordBaseMinors[incId] = settledBase;
      }
      final fromAsset = item.fromAssetId == noRef
          ? null
          : assetById[item.fromAssetId];

      unsortedEntries.add(
        FixedDepositEntry(
          asset: asset,
          index: index,
          item: item,
          fromAssetName: fromAsset?.name,
          incomeRecordExists: liveRec != null,
          settledBaseMinor: settledBase,
        ),
      );
    }

    final sortedEntries = sortFixedDeposits<FixedDepositEntry>(
      unsortedEntries,
      itemOf: (e) => e.item,
      tieBreaker: (a, b) {
        final byAsset = a.asset.id.compareTo(b.asset.id);
        return byAsset != 0 ? byAsset : a.index.compareTo(b.index);
      },
    );

    final header = computeDepositHeaderSummary(
      sortedEntries.map((e) => e.item),
      rates,
      settledRecordBaseMinors: settledRecordBaseMinors,
    );

    return FixedDepositOverview(
      entries: sortedEntries,
      header: header,
      eligibleAssets: eligibleAssets,
    );
  }

  /// Resolves the actual base-currency minor amount of a settled income record
  /// (`ASYM-FD-05`).
  BigInt _recordBaseMinor(
    LedgerRecord record,
    Asset hostAsset,
    RateTable rates,
  ) {
    final curr = RecordExtra.parse(record.extraInfo).currency;
    if (curr != null && curr.isValid) {
      if (normalizeCurrency(curr.baseCode) == rates.base &&
          curr.baseAmount != null) {
        return curr.baseAmount!;
      }
      if (normalizeCurrency(curr.assetCode) == rates.base &&
          curr.assetNet != null) {
        return curr.assetNet!;
      }
      if (normalizeCurrency(curr.sourceCode) == rates.base) {
        return curr.sourceGross;
      }
      return headerConvertMinorToBase(
        record.moneyMinor,
        curr.assetCode ?? hostAsset.currency,
        rates,
      );
    }
    return headerConvertMinorToBase(
      record.moneyMinor,
      hostAsset.currency,
      rates,
    );
  }
}
