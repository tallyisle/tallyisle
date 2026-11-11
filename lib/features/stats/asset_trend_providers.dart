import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../data/repo/asset_trend_queries.dart';
import '../../domain/rules/asset_overview.dart';
import '../../domain/rules/asset_trend.dart';

final assetTrendQueriesProvider = FutureProvider<AssetTrendQueries>((
  ref,
) async {
  final db = await ref.watch(databaseProvider.future);
  return AssetTrendQueries(db);
});

final trendAccountsProvider = StreamProvider<List<TrendAccount>>((ref) async* {
  final q = await ref.watch(assetTrendQueriesProvider.future);
  yield* q.watchAccounts();
});

final trendBooksProvider = StreamProvider<List<AccountBook>>((ref) async* {
  final q = await ref.watch(assetTrendQueriesProvider.future);
  yield* q.watchBooks();
});

final trendBookStartDaysProvider = StreamProvider<Map<int, int>>((ref) async* {
  final q = await ref.watch(assetTrendQueriesProvider.future);
  yield* q.watchBookStartDays();
});

final trendRateTableProvider = StreamProvider<RateTable>((ref) async* {
  final q = await ref.watch(assetTrendQueriesProvider.future);
  yield* q.watchRateTable();
});

final trendRecordsProvider = StreamProvider<List<TrendRecord>>((ref) async* {
  final q = await ref.watch(assetTrendQueriesProvider.future);
  yield* q.watchTrendRecords();
});

final trendModePreferenceProvider = StreamProvider<String>((ref) async* {
  final q = await ref.watch(assetTrendQueriesProvider.future);
  yield* q.watchAssetTrendMode();
});

/// Target account filter scope notifier.
final class TrendFilterNotifier extends Notifier<AssetTrendFilter> {
  @override
  AssetTrendFilter build() => const AssetTrendFilter.allEffective();
  void setFilter(AssetTrendFilter f) => state = f;
}

final trendFilterProvider =
    NotifierProvider<TrendFilterNotifier, AssetTrendFilter>(
      TrendFilterNotifier.new,
    );

/// Perspective switch notifier.
final class TrendPerspectiveNotifier extends Notifier<AssetTrendPerspective> {
  @override
  AssetTrendPerspective build() => AssetTrendPerspective.netWorth;
  void setPerspective(AssetTrendPerspective p) => state = p;
}

final trendPerspectiveProvider =
    NotifierProvider<TrendPerspectiveNotifier, AssetTrendPerspective>(
      TrendPerspectiveNotifier.new,
    );

/// Selected year notifier (null means "所有时间").
final class TrendSelectedYearNotifier extends Notifier<int?> {
  @override
  int? build() => DateTime.now().year;
  void setYear(int? y) => state = y;
}

final trendSelectedYearProvider =
    NotifierProvider<TrendSelectedYearNotifier, int?>(
      TrendSelectedYearNotifier.new,
    );

/// Switch for single foreign currency accounts (true = original, false = base currency).
final class TrendUseOriginalCurrencyNotifier extends Notifier<bool> {
  @override
  bool build() => false;
  void setUseOriginalCurrency(bool v) => state = v;
  void toggle() => state = !state;
}

final trendUseOriginalCurrencyProvider =
    NotifierProvider<TrendUseOriginalCurrencyNotifier, bool>(
      TrendUseOriginalCurrencyNotifier.new,
    );

/// Real-time asset and liability distribution calculation (Card 1).
final assetDistributionProvider = Provider<AssetDistributionResult?>((ref) {
  final accounts = ref.watch(trendAccountsProvider).value;
  final rates = ref.watch(trendRateTableProvider).value;
  if (accounts == null || rates == null) return null;
  return computeAssetDistribution(accounts, rates);
});

/// Monthly asset trend result calculation (Card 2 & Card 3).
final assetTrendResultProvider = Provider<AssetTrendResult?>((ref) {
  final accounts = ref.watch(trendAccountsProvider).value;
  final records = ref.watch(trendRecordsProvider).value;
  final rates = ref.watch(trendRateTableProvider).value;
  final startDays = ref.watch(trendBookStartDaysProvider).value ?? const {};
  final filter = ref.watch(trendFilterProvider);
  final perspective = ref.watch(trendPerspectiveProvider);
  final selectedYear = ref.watch(trendSelectedYearProvider);
  final useOriginal = ref.watch(trendUseOriginalCurrencyProvider);

  if (accounts == null || records == null || rates == null) return null;

  return computeAssetTrend(
    accounts: accounts,
    records: records,
    rates: rates,
    filter: filter,
    perspective: perspective,
    selectedYear: selectedYear,
    useOriginalCurrency: useOriginal,
    bookStartDays: startDays,
  );
});
