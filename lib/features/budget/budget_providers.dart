import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/budget/budget_service.dart';
import '../../data/db/database.dart';
import '../../data/repo/budget_queries.dart';
import '../../data/repo/ledger_queries.dart' show statEntryOf;
import '../../domain/rules/app_settings_rules.dart';
import '../../domain/rules/billing_period.dart';
import '../../domain/rules/budget_rules.dart';

final budgetServiceProvider = FutureProvider<BudgetService>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return BudgetService(db);
});

final budgetQueriesProvider = FutureProvider<BudgetQueries>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return BudgetQueries(db);
});

final budgetModeProvider = StreamProvider<BudgetMode>((ref) async* {
  final q = await ref.watch(budgetQueriesProvider.future);
  final bookId = await ref.watch(currentBookIdProvider.future);
  yield* q.watchBudgetMode(bookId);
});

/// The period offset from the active period (0 = current, -1 = previous, +1 = next).
final class BudgetOffsetNotifier extends Notifier<int> {
  @override
  int build() => 0;
  void previous() => state = state - 1;
  void next() => state = state + 1;
  void reset() => state = 0;
  void setOffset(int offset) => state = offset;
}

final budgetOffsetProvider = NotifierProvider<BudgetOffsetNotifier, int>(
  BudgetOffsetNotifier.new,
);

final budgetPeriodForOffsetProvider = FutureProvider.family<BillingPeriod, int>(
  (ref, offset) async {
    final book = await ref.watch(currentBookProvider.future);
    final startDay = book?.startDay ?? 1;
    final mode = await ref.watch(budgetModeProvider.future);
    final now = DateTime.now();
    if (mode == BudgetMode.yearly) {
      final currentYearPeriod = BillingPeriod.containingYear(now, startDay);
      return BillingPeriod.year(currentYearPeriod.year + offset, startDay);
    } else {
      final currentMonthPeriod = BillingPeriod.containing(now, startDay);
      return BillingPeriod.starting(
        currentMonthPeriod.year,
        currentMonthPeriod.month + offset,
        startDay,
      );
    }
  },
);

final budgetPeriodProvider = FutureProvider<BillingPeriod>((ref) async {
  final offset = ref.watch(budgetOffsetProvider);
  return ref.watch(budgetPeriodForOffsetProvider(offset).future);
});

final budgetSectionForOffsetProvider = FutureProvider.family<String, int>((
  ref,
  offset,
) async {
  final mode = await ref.watch(budgetModeProvider.future);
  final period = await ref.watch(budgetPeriodForOffsetProvider(offset).future);
  return mode.sectionFor(period);
});

final budgetSectionProvider = FutureProvider<String>((ref) async {
  final offset = ref.watch(budgetOffsetProvider);
  return ref.watch(budgetSectionForOffsetProvider(offset).future);
});

final budgetsForOffsetProvider = StreamProvider.family<List<Budget>, int>((
  ref,
  offset,
) async* {
  final q = await ref.watch(budgetQueriesProvider.future);
  final bookId = await ref.watch(currentBookIdProvider.future);
  final section = await ref.watch(
    budgetSectionForOffsetProvider(offset).future,
  );
  yield* q.watchBudgets(bookId, section);
});

final currentBudgetsProvider = StreamProvider<List<Budget>>((ref) async* {
  final q = await ref.watch(budgetQueriesProvider.future);
  final bookId = await ref.watch(currentBookIdProvider.future);
  final section = await ref.watch(budgetSectionProvider.future);
  yield* q.watchBudgets(bookId, section);
});

final budgetPeriodRecordsForOffsetProvider =
    StreamProvider.family<List<LedgerRecord>, int>((ref, offset) async* {
      final q = await ref.watch(budgetQueriesProvider.future);
      final bookId = await ref.watch(currentBookIdProvider.future);
      final period = await ref.watch(
        budgetPeriodForOffsetProvider(offset).future,
      );
      yield* q.watchBudgetPeriodRecords(bookId, period.startMs, period.endMs);
    });

final budgetPeriodRecordsProvider = StreamProvider<List<LedgerRecord>>((
  ref,
) async* {
  final q = await ref.watch(budgetQueriesProvider.future);
  final bookId = await ref.watch(currentBookIdProvider.future);
  final period = await ref.watch(budgetPeriodProvider.future);
  yield* q.watchBudgetPeriodRecords(bookId, period.startMs, period.endMs);
});

/// Detailed information for a category budget row.
final class CategoryBudgetDetail {
  const CategoryBudgetDetail({
    required this.budget,
    required this.category,
    required this.usage,
    this.parentCategory,
  });

  final Budget budget;
  final RecordCategory category;
  final BudgetUsage usage;
  final RecordCategory? parentCategory;
}

/// Overview of all budgets and usages for the selected period.
final class BudgetOverview {
  const BudgetOverview({
    required this.mode,
    required this.period,
    required this.section,
    this.totalBudget,
    this.totalUsage,
    required this.expenseCategoryBudgets,
    required this.savingCategoryBudgets,
  });

  final BudgetMode mode;
  final BillingPeriod period;
  final String section;
  final Budget? totalBudget;
  final BudgetUsage? totalUsage;
  final List<CategoryBudgetDetail> expenseCategoryBudgets;
  final List<CategoryBudgetDetail> savingCategoryBudgets;
}

final budgetOverviewForOffsetProvider =
    FutureProvider.family<BudgetOverview, int>((ref, offset) async {
      final mode = await ref.watch(budgetModeProvider.future);
      final period = await ref.watch(
        budgetPeriodForOffsetProvider(offset).future,
      );
      final section = await ref.watch(
        budgetSectionForOffsetProvider(offset).future,
      );
      final bookId = await ref.watch(currentBookIdProvider.future);
      final budgets = await ref.watch(budgetsForOffsetProvider(offset).future);
      final records = await ref.watch(
        budgetPeriodRecordsForOffsetProvider(offset).future,
      );
      final categories = await ref.watch(categoriesProvider(bookId).future);

      final categoryNodeList = categories
          .map(
            (c) => BudgetCategoryNode(
              id: c.id,
              name: c.name,
              icon: c.icon,
              type: c.type,
              parentCatId: c.parentCatId,
            ),
          )
          .toList();

      final categoryMap = {for (final c in categories) c.id: c};

      final inputs = records
          .map(
            (r) => BudgetRecordInput(
              recordId: r.recordId,
              recordCatId: r.recordCatId,
              entry: statEntryOf(r),
            ),
          )
          .toList();

      // 1. Total budget
      final totalBudget = budgets
          .where(
            (b) => b.budgetType == BudgetTypeCode.total && b.recordCatId == -1,
          )
          .firstOrNull;

      final totalUsage = totalBudget != null
          ? computeTotalBudgetUsage(
              amountMinor: totalBudget.amountMinor,
              budgetId: totalBudget.id,
              records: inputs,
            )
          : null;

      // 2. Expense category budgets
      final expenseCategoryBudgets = <CategoryBudgetDetail>[];
      final savingCategoryBudgets = <CategoryBudgetDetail>[];

      for (final b in budgets) {
        if (b.budgetType == BudgetTypeCode.expenseCategory) {
          final cat = categoryMap[b.recordCatId];
          if (cat != null) {
            final node = BudgetCategoryNode(
              id: cat.id,
              name: cat.name,
              icon: cat.icon,
              type: cat.type,
              parentCatId: cat.parentCatId,
            );
            final usage = computeCategoryBudgetUsage(
              category: node,
              allCategories: categoryNodeList,
              amountMinor: b.amountMinor,
              budgetId: b.id,
              budgetType: b.budgetType,
              records: inputs,
            );
            expenseCategoryBudgets.add(
              CategoryBudgetDetail(
                budget: b,
                category: cat,
                usage: usage,
                parentCategory: cat.parentCatId != -1
                    ? categoryMap[cat.parentCatId]
                    : null,
              ),
            );
          }
        } else if (b.budgetType == BudgetTypeCode.savingCategory) {
          final cat = categoryMap[b.recordCatId];
          if (cat != null) {
            final node = BudgetCategoryNode(
              id: cat.id,
              name: cat.name,
              icon: cat.icon,
              type: cat.type,
              parentCatId: cat.parentCatId,
            );
            final usage = computeCategoryBudgetUsage(
              category: node,
              allCategories: categoryNodeList,
              amountMinor: b.amountMinor,
              budgetId: b.id,
              budgetType: b.budgetType,
              records: inputs,
            );
            savingCategoryBudgets.add(
              CategoryBudgetDetail(
                budget: b,
                category: cat,
                usage: usage,
                parentCategory: cat.parentCatId != -1
                    ? categoryMap[cat.parentCatId]
                    : null,
              ),
            );
          }
        }
      }

      return BudgetOverview(
        mode: mode,
        period: period,
        section: section,
        totalBudget: totalBudget,
        totalUsage: totalUsage,
        expenseCategoryBudgets: expenseCategoryBudgets,
        savingCategoryBudgets: savingCategoryBudgets,
      );
    });

final budgetOverviewProvider = FutureProvider<BudgetOverview>((ref) async {
  final offset = ref.watch(budgetOffsetProvider);
  return ref.watch(budgetOverviewForOffsetProvider(offset).future);
});

/// Query parameter for real-time record budget hint resolution.
final class RecordBudgetHintQuery {
  const RecordBudgetHintQuery({
    required this.bookId,
    required this.recordTime,
    required this.categoryId,
  });

  final int bookId;
  final int recordTime;
  final int categoryId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RecordBudgetHintQuery &&
          runtimeType == other.runtimeType &&
          bookId == other.bookId &&
          recordTime == other.recordTime &&
          categoryId == other.categoryId;

  @override
  int get hashCode => Object.hash(bookId, recordTime, categoryId);
}

/// Resolved real-time budget hint paired with the budget period mode it came from.
final class ResolvedRecordBudgetHint {
  const ResolvedRecordBudgetHint({required this.mode, required this.usage});

  final BudgetMode mode;
  final BudgetUsage usage;
}

final _budgetBookCategoriesProvider =
    StreamProvider.family<List<RecordCategory>, int>((ref, bookId) async* {
      final q = await ref.watch(budgetQueriesProvider.future);
      yield* q.watchBookCategories(bookId);
    });

final _budgetsBySectionProvider =
    StreamProvider.family<List<Budget>, ({int bookId, String section})>((
      ref,
      key,
    ) async* {
      final q = await ref.watch(budgetQueriesProvider.future);
      yield* q.watchBudgets(key.bookId, key.section);
    });

final _budgetPeriodRecordsByRangeProvider =
    StreamProvider.family<
      List<LedgerRecord>,
      ({int bookId, int startMs, int endMs})
    >((ref, key) async* {
      final q = await ref.watch(budgetQueriesProvider.future);
      yield* q.watchBudgetPeriodRecords(key.bookId, key.startMs, key.endMs);
    });

final resolvedRecordBudgetHintProvider =
    FutureProvider.family<ResolvedRecordBudgetHint?, RecordBudgetHintQuery>((
      ref,
      query,
    ) async {
      if (query.categoryId <= 0) return null;

      void listenForUpdates<T>(StreamProvider<T> provider) {
        ref.listen<AsyncValue<T>>(provider, (prev, next) {
          if (prev?.hasValue == true && next.hasValue) {
            ref.invalidateSelf();
          }
        });
      }

      listenForUpdates(appSettingsProvider);
      final settings =
          ref.read(appSettingsProvider).value ??
          await (await ref.watch(
            appSettingsServiceProvider.future,
          )).getSettings();
      if (!settings.showRecordBudgetHint) return null;

      final db = await ref.watch(databaseProvider.future);
      final q = await ref.watch(budgetQueriesProvider.future);

      listenForUpdates(booksProvider);
      final books =
          ref.read(booksProvider).value ??
          await db.select(db.accountBooks).get();
      final bookRow = books.where((b) => b.id == query.bookId).firstOrNull;
      final startDay = bookRow?.startDay ?? 1;

      final categoriesProviderForBook = _budgetBookCategoriesProvider(
        query.bookId,
      );
      listenForUpdates(categoriesProviderForBook);
      final categories =
          ref.read(categoriesProviderForBook).value ??
          await q.getBookCategories(query.bookId);
      final categoryNodes = categories
          .map(
            (c) => BudgetCategoryNode(
              id: c.id,
              name: c.name,
              icon: c.icon,
              type: c.type,
              parentCatId: c.parentCatId,
            ),
          )
          .toList();
      final categoryMap = {for (final c in categoryNodes) c.id: c};

      final recordDate = DateTime.fromMillisecondsSinceEpoch(query.recordTime);

      Future<BudgetUsage?> resolveForMode(BudgetMode mode) async {
        final period = mode == BudgetMode.yearly
            ? BillingPeriod.containingYear(recordDate, startDay)
            : BillingPeriod.containing(recordDate, startDay);
        final section = mode.sectionFor(period);

        final budgetsProviderForSection = _budgetsBySectionProvider((
          bookId: query.bookId,
          section: section,
        ));
        listenForUpdates(budgetsProviderForSection);
        final budgets =
            ref.read(budgetsProviderForSection).value ??
            await q.getBudgets(query.bookId, section);
        if (budgets.isEmpty) return null;

        final recordsProviderForRange = _budgetPeriodRecordsByRangeProvider((
          bookId: query.bookId,
          startMs: period.startMs,
          endMs: period.endMs,
        ));
        listenForUpdates(recordsProviderForRange);
        final records =
            ref.read(recordsProviderForRange).value ??
            await q.getBudgetPeriodRecords(
              query.bookId,
              period.startMs,
              period.endMs,
            );

        final inputs = records
            .map(
              (r) => BudgetRecordInput(
                recordId: r.recordId,
                recordCatId: r.recordCatId,
                entry: statEntryOf(r),
              ),
            )
            .toList();

        BudgetUsage? totalUsage;
        final totalBudget = budgets
            .where(
              (b) =>
                  b.budgetType == BudgetTypeCode.total && b.recordCatId == -1,
            )
            .firstOrNull;
        if (totalBudget != null) {
          totalUsage = computeTotalBudgetUsage(
            amountMinor: totalBudget.amountMinor,
            budgetId: totalBudget.id,
            records: inputs,
          );
        }

        final categoryBudgets = <int, BudgetUsage>{};
        for (final b in budgets) {
          if (b.budgetType == BudgetTypeCode.expenseCategory ||
              b.budgetType == BudgetTypeCode.savingCategory) {
            final node = categoryMap[b.recordCatId];
            if (node != null) {
              categoryBudgets[b.recordCatId] = computeCategoryBudgetUsage(
                category: node,
                allCategories: categoryNodes,
                amountMinor: b.amountMinor,
                budgetId: b.id,
                budgetType: b.budgetType,
                records: inputs,
              );
            }
          }
        }

        return resolveRecordBudgetHint(
          selectedCatId: query.categoryId,
          categoryMap: categoryMap,
          categoryBudgets: categoryBudgets,
          totalBudget: totalUsage,
        );
      }

      switch (settings.recordBudgetHintMode) {
        case RecordBudgetHintMode.monthly:
          final usage = await resolveForMode(BudgetMode.monthly);
          return usage == null
              ? null
              : ResolvedRecordBudgetHint(
                  mode: BudgetMode.monthly,
                  usage: usage,
                );
        case RecordBudgetHintMode.yearly:
          final usage = await resolveForMode(BudgetMode.yearly);
          return usage == null
              ? null
              : ResolvedRecordBudgetHint(mode: BudgetMode.yearly, usage: usage);
        case RecordBudgetHintMode.auto:
          final monthlyUsage = await resolveForMode(BudgetMode.monthly);
          if (monthlyUsage != null) {
            return ResolvedRecordBudgetHint(
              mode: BudgetMode.monthly,
              usage: monthlyUsage,
            );
          }
          final yearlyUsage = await resolveForMode(BudgetMode.yearly);
          return yearlyUsage == null
              ? null
              : ResolvedRecordBudgetHint(
                  mode: BudgetMode.yearly,
                  usage: yearlyUsage,
                );
      }
    });

final recordBudgetHintProvider =
    FutureProvider.family<BudgetUsage?, RecordBudgetHintQuery>((
      ref,
      query,
    ) async {
      final resolved = await ref.watch(
        resolvedRecordBudgetHintProvider(query).future,
      );
      return resolved?.usage;
    });
