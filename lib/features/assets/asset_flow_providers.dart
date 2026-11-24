import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../data/repo/asset_flow_queries.dart';
import '../../domain/ledger/record_extra.dart';
import '../../domain/rules/reconciliation.dart';

final assetFlowQueriesProvider = FutureProvider<AssetFlowQueries>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return AssetFlowQueries(db);
});

/// All records involving [assetId] across all books, ordered newest-first.
final assetRecordsProvider = StreamProvider.family<List<LedgerRecord>, int>((
  ref,
  assetId,
) async* {
  final q = await ref.watch(assetFlowQueriesProvider.future);
  yield* q.watchAssetRecords(assetId);
});

/// All categories across all books for label resolution.
final crossBookCategoriesProvider = StreamProvider<List<RecordCategory>>((
  ref,
) async* {
  final q = await ref.watch(assetFlowQueriesProvider.future);
  yield* q.watchAllCategories();
});

/// Converts a Drift [LedgerRecord] into a domain [ReconRecord].
ReconRecord reconRecordOf(LedgerRecord r) => ReconRecord(
  id: r.recordId,
  type: r.type,
  subType: r.subType,
  moneyMinor: r.moneyMinor,
  discountMinor: r.discountMinor,
  recordTime: r.recordTime,
  assetId: r.assetId,
  fromAssetId: r.fromAssetId,
  toAssetId: r.toAssetId,
  currency: RecordExtra.parse(r.extraInfo).currency,
);

/// Balance immediately after each record for [assetId], computed backward
/// from the current asset balance.
final reconciliationBalancesProvider =
    Provider.family<Map<String, BigInt>, int>((ref, assetId) {
      final asset = ref.watch(assetProvider(assetId)).value;
      final records =
          ref.watch(assetRecordsProvider(assetId)).value ?? const [];
      if (asset == null) return const {};
      return computeReconciliationBalances(
        currentBalance: asset.balanceMinor,
        accountId: asset.id,
        accountCurrency: asset.currency,
        records: records.map(reconRecordOf).toList(),
      );
    });

/// Records for [assetId] grouped by calendar month with inflow/outflow totals.
final assetMonthGroupsProvider =
    Provider.family<List<MonthFlowGroup<LedgerRecord>>, int>((ref, assetId) {
      final asset = ref.watch(assetProvider(assetId)).value;
      final records =
          ref.watch(assetRecordsProvider(assetId)).value ?? const [];
      if (asset == null) return const [];
      return groupRecordsByMonth<LedgerRecord>(
        records: records,
        getRecordTime: (r) => r.recordTime,
        getDelta: (r) => recordForwardDelta(
          record: reconRecordOf(r),
          accountId: asset.id,
          accountCurrency: asset.currency,
        ),
      );
    });

/// Selected statement year for fund account monthly statement views.
final class FundSelectedYearNotifier extends Notifier<int> {
  @override
  int build() => DateTime.now().year;
  void setYear(int y) => state = y;
  void previous() => state = state - 1;
  void next() => state = state + 1;
  void reset() => state = DateTime.now().year;
}

final fundSelectedYearProvider =
    NotifierProvider<FundSelectedYearNotifier, int>(
      FundSelectedYearNotifier.new,
    );

/// Natural-month statements (`12..1`, newest-first) for fund account [assetId]
/// in [fundSelectedYearProvider].
final fundMonthlyStatementsProvider =
    Provider.family<List<FundMonthlyStatementItem>, int>((ref, assetId) {
      final asset =
          ref.watch(assetProvider(assetId)).value ??
          ref
              .watch(assetsProvider)
              .value
              ?.where((x) => x.id == assetId)
              .firstOrNull;
      final records =
          ref.watch(assetRecordsProvider(assetId)).value ?? const [];
      final selectedYear = ref.watch(fundSelectedYearProvider);
      if (asset == null) return const [];
      return calculateFundMonthlyStatements(
        currentBalance: asset.balanceMinor,
        accountId: asset.id,
        accountCurrency: asset.currency,
        records: records.map(reconRecordOf).toList(),
        selectedYear: selectedYear,
        today: DateTime.now(),
      );
    });
