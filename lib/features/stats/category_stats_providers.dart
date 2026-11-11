import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../data/repo/category_stats_queries.dart';
import '../../domain/rules/billing_period.dart';
import '../../domain/rules/category_stats.dart';

/// Database queries for category statistics.
final categoryStatsQueriesProvider = FutureProvider<CategoryStatsQueries>((
  ref,
) async {
  final db = await ref.watch(databaseProvider.future);
  return CategoryStatsQueries(db);
});

/// Dimension notifier (Expense / Income).
final class CategoryStatsDimensionNotifier extends Notifier<StatDimension> {
  @override
  StatDimension build() => StatDimension.expense;
  void setDimension(StatDimension dim) => state = dim;
  void toggle() => state = state == StatDimension.expense
      ? StatDimension.income
      : StatDimension.expense;
}

final categoryStatsDimensionProvider =
    NotifierProvider<CategoryStatsDimensionNotifier, StatDimension>(
      CategoryStatsDimensionNotifier.new,
    );

/// Granularity notifier (Month / Year / Custom).
final class CategoryStatsRangeKindNotifier extends Notifier<StatRangeKind> {
  @override
  StatRangeKind build() => StatRangeKind.month;
  void setRangeKind(StatRangeKind kind) => state = kind;
}

final categoryStatsRangeKindProvider =
    NotifierProvider<CategoryStatsRangeKindNotifier, StatRangeKind>(
      CategoryStatsRangeKindNotifier.new,
    );

/// Period offset from current month or year.
final class CategoryStatsOffsetNotifier extends Notifier<int> {
  @override
  int build() => 0;
  void previous() => state = state - 1;
  void next() => state = state + 1;
  void reset() => state = 0;
  void setOffset(int offset) => state = offset;
}

final categoryStatsOffsetProvider =
    NotifierProvider<CategoryStatsOffsetNotifier, int>(
      CategoryStatsOffsetNotifier.new,
    );

/// Custom date range selection.
final class CategoryStatsCustomRangeNotifier
    extends Notifier<(DateTime, DateTime)?> {
  @override
  (DateTime, DateTime)? build() => null;
  void setRange(DateTime start, DateTime end) => state = (start, end);
  void clear() => state = null;
}

final categoryStatsCustomRangeProvider =
    NotifierProvider<CategoryStatsCustomRangeNotifier, (DateTime, DateTime)?>(
      CategoryStatsCustomRangeNotifier.new,
    );

/// View mode notifier: false = 一级汇总, true = 二级平铺 (F01).
final class CategoryStatsFlattenNotifier extends Notifier<bool> {
  @override
  bool build() => false;
  void toggle() => state = !state;
  void setFlatten(bool flatten) => state = flatten;
}

final categoryStatsFlattenProvider =
    NotifierProvider<CategoryStatsFlattenNotifier, bool>(
      CategoryStatsFlattenNotifier.new,
    );

/// Outlier smoothing mode (Tukey IQR).
final class CategoryStatsOutlierSmoothingNotifier
    extends Notifier<OutlierSmoothing> {
  @override
  OutlierSmoothing build() => OutlierSmoothing.none;
  void setMode(OutlierSmoothing mode) => state = mode;
  void toggle() => state = state == OutlierSmoothing.none
      ? OutlierSmoothing.primary
      : OutlierSmoothing.none;
}

final categoryStatsOutlierSmoothingProvider =
    NotifierProvider<CategoryStatsOutlierSmoothingNotifier, OutlierSmoothing>(
      CategoryStatsOutlierSmoothingNotifier.new,
    );

/// Extra filter criteria (books, accounts, categories, tags, budget flag).
final class FilterConfigState {
  const FilterConfigState({
    this.selectedBookIds,
    this.selectedCategoryIds,
    this.categoryFilterMode = CategoryFilterMode.includeSelected,
    this.selectedAssetIds,
    this.selectedTagIds,
    this.includeExcludeBudget = true,
  });

  final List<int>? selectedBookIds;
  final Set<int>? selectedCategoryIds;
  final CategoryFilterMode categoryFilterMode;
  final Set<int>? selectedAssetIds;
  final Set<String>? selectedTagIds;
  final bool includeExcludeBudget;

  FilterConfigState copyWith({
    List<int>? selectedBookIds,
    bool clearBookIds = false,
    Set<int>? selectedCategoryIds,
    bool clearCategoryIds = false,
    CategoryFilterMode? categoryFilterMode,
    Set<int>? selectedAssetIds,
    bool clearAssetIds = false,
    Set<String>? selectedTagIds,
    bool clearTagIds = false,
    bool? includeExcludeBudget,
  }) {
    return FilterConfigState(
      selectedBookIds: clearBookIds
          ? null
          : (selectedBookIds ?? this.selectedBookIds),
      selectedCategoryIds: clearCategoryIds
          ? null
          : (selectedCategoryIds ?? this.selectedCategoryIds),
      categoryFilterMode: categoryFilterMode ?? this.categoryFilterMode,
      selectedAssetIds: clearAssetIds
          ? null
          : (selectedAssetIds ?? this.selectedAssetIds),
      selectedTagIds: clearTagIds
          ? null
          : (selectedTagIds ?? this.selectedTagIds),
      includeExcludeBudget: includeExcludeBudget ?? this.includeExcludeBudget,
    );
  }
}

final class CategoryStatsFilterConfigNotifier
    extends Notifier<FilterConfigState> {
  @override
  FilterConfigState build() => const FilterConfigState();

  void update(FilterConfigState newState) => state = newState;
  void reset() => state = const FilterConfigState();

  void toggleIncludeExcludeBudget() =>
      state = state.copyWith(includeExcludeBudget: !state.includeExcludeBudget);
}

final categoryStatsFilterConfigProvider =
    NotifierProvider<CategoryStatsFilterConfigNotifier, FilterConfigState>(
      CategoryStatsFilterConfigNotifier.new,
    );

/// Active billing period for the current range kind and offset.
final categoryStatsActivePeriodProvider = FutureProvider<BillingPeriod>((
  ref,
) async {
  final book = await ref.watch(currentBookProvider.future);
  final startDay = book?.startDay ?? 1;
  final rangeKind = ref.watch(categoryStatsRangeKindProvider);
  final offset = ref.watch(categoryStatsOffsetProvider);
  final customRange = ref.watch(categoryStatsCustomRangeProvider);

  final now = DateTime.now();

  switch (rangeKind) {
    case StatRangeKind.month:
      final currentMonthPeriod = BillingPeriod.containing(now, startDay);
      return BillingPeriod.starting(
        currentMonthPeriod.year,
        currentMonthPeriod.month + offset,
        startDay,
      );
    case StatRangeKind.year:
      final currentYearPeriod = BillingPeriod.containingYear(now, startDay);
      return BillingPeriod.year(currentYearPeriod.year + offset, startDay);
    case StatRangeKind.custom:
      if (customRange != null) {
        return BillingPeriod.custom(customRange.$1, customRange.$2);
      }
      return BillingPeriod.containing(now, startDay);
  }
});

/// Combined [AnalyzeFilter] for current query.
final categoryStatsAnalyzeFilterProvider = FutureProvider<AnalyzeFilter>((
  ref,
) async {
  final currentBookId = await ref.watch(currentBookIdProvider.future);
  final period = await ref.watch(categoryStatsActivePeriodProvider.future);
  final dimension = ref.watch(categoryStatsDimensionProvider);
  final rangeKind = ref.watch(categoryStatsRangeKindProvider);
  final smoothing = ref.watch(categoryStatsOutlierSmoothingProvider);
  final config = ref.watch(categoryStatsFilterConfigProvider);

  final bookIds = config.selectedBookIds ?? [currentBookId];

  return AnalyzeFilter(
    bookIds: bookIds,
    startMs: period.startMs,
    endMs: period.endMs,
    categoryIds: config.selectedCategoryIds,
    categoryFilterMode: config.categoryFilterMode,
    assetIds: config.selectedAssetIds,
    tagIds: config.selectedTagIds,
    includeExcludeBudget: config.includeExcludeBudget,
    dimension: dimension,
    rangeKind: rangeKind,
    outlierSmoothing: smoothing,
  );
});

/// Previous comparable period for period-over-period comparison.
final categoryStatsPreviousPeriodProvider = FutureProvider<BillingPeriod>((
  ref,
) async {
  final period = await ref.watch(categoryStatsActivePeriodProvider.future);
  final book = await ref.watch(currentBookProvider.future);
  final startDay = book?.startDay ?? 1;
  final rangeKind = ref.watch(categoryStatsRangeKindProvider);

  switch (rangeKind) {
    case StatRangeKind.month:
      return period.previous(startDay);
    case StatRangeKind.year:
      return period.previousYear(startDay);
    case StatRangeKind.custom:
      final duration = period.end.difference(period.start);
      final prevEnd = period.start.subtract(const Duration(milliseconds: 1));
      final prevStart = prevEnd.subtract(duration);
      return BillingPeriod.custom(prevStart, prevEnd);
  }
});

/// Stream of current records matching [categoryStatsAnalyzeFilterProvider].
final categoryStatsRecordsProvider = StreamProvider<List<LedgerRecord>>((
  ref,
) async* {
  final q = await ref.watch(categoryStatsQueriesProvider.future);
  final filter = await ref.watch(categoryStatsAnalyzeFilterProvider.future);
  yield* q.watchRecords(filter);
});

/// Stream of previous period records for period-over-period comparison.
final categoryStatsPreviousPeriodRecordsProvider =
    StreamProvider<List<LedgerRecord>>((ref) async* {
      final q = await ref.watch(categoryStatsQueriesProvider.future);
      final currentFilter = await ref.watch(
        categoryStatsAnalyzeFilterProvider.future,
      );
      final prevPeriod = await ref.watch(
        categoryStatsPreviousPeriodProvider.future,
      );

      final prevFilter = currentFilter.copyWith(
        startMs: prevPeriod.startMs,
        endMs: prevPeriod.endMs,
      );
      yield* q.watchRecords(prevFilter);
    });

/// Stream of categories for the selected book IDs.
final categoryStatsCategoriesProvider = StreamProvider<Map<int, CategoryMeta>>((
  ref,
) async* {
  final q = await ref.watch(categoryStatsQueriesProvider.future);
  final filter = await ref.watch(categoryStatsAnalyzeFilterProvider.future);

  yield* q.watchCategories(filter.bookIds).map((list) {
    final map = <int, CategoryMeta>{};
    for (final c in list) {
      map[c.id] = categoryMetaOf(c);
    }
    return map;
  });
});

/// Complete aggregated category statistics result.
final categoryStatsResultProvider = Provider<AsyncValue<CategoryStatsResult>>((
  ref,
) {
  final filterAsync = ref.watch(categoryStatsAnalyzeFilterProvider);
  final periodAsync = ref.watch(categoryStatsActivePeriodProvider);
  final recordsAsync = ref.watch(categoryStatsRecordsProvider);
  final prevRecordsAsync = ref.watch(
    categoryStatsPreviousPeriodRecordsProvider,
  );
  final categoriesAsync = ref.watch(categoryStatsCategoriesProvider);

  if (filterAsync.isLoading ||
      periodAsync.isLoading ||
      recordsAsync.isLoading ||
      categoriesAsync.isLoading) {
    return const AsyncValue.loading();
  }

  if (filterAsync.hasError) {
    return AsyncValue.error(filterAsync.error!, filterAsync.stackTrace!);
  }
  if (periodAsync.hasError) {
    return AsyncValue.error(periodAsync.error!, periodAsync.stackTrace!);
  }
  if (recordsAsync.hasError) {
    return AsyncValue.error(recordsAsync.error!, recordsAsync.stackTrace!);
  }
  if (categoriesAsync.hasError) {
    return AsyncValue.error(
      categoriesAsync.error!,
      categoriesAsync.stackTrace!,
    );
  }

  final filter = filterAsync.value!;
  final period = periodAsync.value!;
  final records = recordsAsync.value!;
  final categories = categoriesAsync.value!;
  final prevRecords = prevRecordsAsync.value ?? const [];

  final entries = records.map((r) => categoryStatEntryOf(r)).toList();
  final prevEntries = prevRecords.map((r) => categoryStatEntryOf(r)).toList();

  final result = aggregateCategoryStats(
    entries: entries,
    categories: categories,
    period: period,
    dimension: filter.dimension,
    rangeKind: filter.rangeKind,
    includeExcludeBudget: filter.includeExcludeBudget,
    outlierSmoothing: filter.outlierSmoothing,
    lastPeriodEntries: prevEntries,
  );

  return AsyncValue.data(result);
});
