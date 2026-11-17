import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/adaptive.dart';
import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../domain/rules/category_stats.dart';
import '../../domain/rules/tag_stats.dart';
import '../books/book_switcher_modal.dart';
import '../budget/budget_providers.dart' show budgetOffsetProvider;
import '../budget/budget_widgets.dart';
import '../common/common.dart';
import 'annual_report_page.dart';
import 'asset_trend_page.dart';
import 'category_stats_page.dart';
import 'category_stats_providers.dart';
import 'tag_stats_page.dart' show TagColorDot, parseTagColor;
import 'tag_stats_providers.dart'
    show statsHubTagRankingsProvider, tagRankingsOffsetProvider;

/// Unified bottom "统计" Tab (mirrors original `AnalyzeFragment`, F-006 / F-008 / F-030).
///
/// Vertically stacks:
/// 1. Annual report overview card -> `/stats/annual`
/// 2. Current period category stats overview card -> `/stats/category` & `/stats/category/:id`
/// 3. Current period tag stats overview card -> `/stats/tags` & `/stats/tag/:id`
/// 4. Current period budget summary card -> `/budget`
/// 5. Real-time asset overview & trend card -> `/stats/trend`
class StatsPage extends ConsumerStatefulWidget {
  const StatsPage({super.key});

  @override
  ConsumerState<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends ConsumerState<StatsPage> {
  bool _pickingBook = false;
  bool? _lastTickerEnabled;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final tickerEnabled = TickerMode.valuesOf(context).enabled;
    final shouldReset =
        _lastTickerEnabled == null ||
        (_lastTickerEnabled == false && tickerEnabled);
    _lastTickerEnabled = tickerEnabled;
    if (shouldReset && tickerEnabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !TickerMode.valuesOf(context).enabled) return;
        if (ref.read(budgetOffsetProvider) != 0) {
          ref.read(budgetOffsetProvider.notifier).reset();
        }
      });
    }
  }

  Future<void> _openBudgetPage({required int initialOffset}) async {
    ref.read(budgetOffsetProvider.notifier).setOffset(initialOffset);
    await context.push(
      initialOffset == 0 ? '/budget' : '/budget?initialOffset=$initialOffset',
    );
    if (mounted && ref.read(budgetOffsetProvider) != 0) {
      ref.read(budgetOffsetProvider.notifier).reset();
    }
  }

  void _openCategoryStatsDetail() {
    if (ref.read(categoryStatsRangeKindProvider) == StatRangeKind.custom) {
      ref
          .read(categoryStatsRangeKindProvider.notifier)
          .setRangeKind(StatRangeKind.month);
    }
    if (ref.read(categoryStatsOffsetProvider) != 0) {
      ref.read(categoryStatsOffsetProvider.notifier).reset();
    }
    context.push('/stats/category');
  }

  void _openCategoryDrilldownFromHub(CategoryRowItem row) {
    if (ref.read(categoryStatsRangeKindProvider) != StatRangeKind.month) {
      ref
          .read(categoryStatsRangeKindProvider.notifier)
          .setRangeKind(StatRangeKind.month);
    }
    if (ref.read(categoryStatsOffsetProvider) != 0) {
      ref.read(categoryStatsOffsetProvider.notifier).reset();
    }
    ref.read(categoryStatsFilterConfigProvider.notifier).reset();
    context.push('/stats/category/${row.categoryId}');
  }

  void _openTagRankings() {
    if (ref.read(tagRankingsOffsetProvider) != 0) {
      ref.read(tagRankingsOffsetProvider.notifier).reset();
    }
    context.push('/stats/tags');
  }

  @override
  Widget build(BuildContext context) {
    final book = ref.watch(currentBookProvider);
    final isDesktop = DesktopAdaptive.isDesktop(context);
    final isExpandedDesktop = DesktopAdaptive.isExpandedDesktop(context);

    final annualCard = AnnualReportOverviewCard(
      onTap: () => context.push('/stats/annual'),
    );
    final categoryCard = CategoryStatsOverviewCard(
      key: const Key('stats-category-overview-card'),
      onOpenDetail: _openCategoryStatsDetail,
      onTapCategory: _openCategoryDrilldownFromHub,
    );
    final tagCard = _TagStatsOverviewCard(
      key: const Key('stats-tag-overview-card'),
      onOpenAll: _openTagRankings,
      onTapTag: (item) => context.push('/stats/tag/${item.tagId}'),
    );
    final budgetCard = BudgetSummaryCard(
      enablePeriodControls: true,
      onTap: () =>
          _openBudgetPage(initialOffset: ref.read(budgetOffsetProvider)),
    );
    final trendCard = AssetTrendOverviewCard(
      onTap: () => context.push('/stats/trend'),
    );

    final stackedList = ListView(
      key: const Key('stats-hub-list'),
      padding: const EdgeInsets.only(top: 6, bottom: 32),
      children: [
        annualCard,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: categoryCard,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: tagCard,
        ),
        budgetCard,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: trendCard,
        ),
      ],
    );

    final bookTitleRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            book.value?.name ?? '统计',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const Icon(Icons.arrow_drop_down),
      ],
    );

    return Scaffold(
      key: const Key('stats-hub-page'),
      appBar: AppBar(
        title: InkWell(
          key: const Key('stats-book-switcher'),
          borderRadius: isDesktop ? BorderRadius.circular(8) : null,
          onTap: _pickBook,
          child: isDesktop
              ? Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  child: bookTitleRow,
                )
              : bookTitleRow,
        ),
        actions: [
          IconButton(
            key: const Key('stats-budget-action'),
            tooltip: '预算管理',
            icon: const Icon(Icons.savings_outlined),
            onPressed: () => _openBudgetPage(initialOffset: 0),
          ),
          IconButton(
            key: const Key('stats-annual-action'),
            tooltip: '年度统计',
            icon: const Icon(Icons.insights),
            onPressed: () => context.push('/stats/annual'),
          ),
          IconButton(
            key: const Key('stats-stories-action'),
            tooltip: '统计故事',
            icon: const Icon(Icons.auto_stories_outlined),
            onPressed: () => context.push('/stat-stories'),
          ),
        ],
      ),
      body: isExpandedDesktop
          ? SingleChildScrollView(
              key: const Key('stats-hub-list'),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
              child: Center(
                child: ConstrainedBox(
                  key: const Key('stats-desktop-grid'),
                  constraints: const BoxConstraints(maxWidth: 1360),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: annualCard),
                          Expanded(child: budgetCard),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 6,
                              ),
                              child: categoryCard,
                            ),
                          ),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 6,
                              ),
                              child: tagCard,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 6,
                        ),
                        child: trendCard,
                      ),
                    ],
                  ),
                ),
              ),
            )
          : (isDesktop
                ? Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: stackedList,
                    ),
                  )
                : stackedList),
    );
  }

  Future<void> _pickBook() async {
    if (_pickingBook) return;
    _pickingBook = true;
    try {
      await showBookSwitcher(context, ref, mobileManageLabel: '管理账本…');
    } finally {
      _pickingBook = false;
    }
  }
}

class _TagStatsOverviewCard extends ConsumerWidget {
  const _TagStatsOverviewCard({
    super.key,
    required this.onOpenAll,
    required this.onTapTag,
  });

  final VoidCallback onOpenAll;
  final void Function(TagRankingItem item) onTapTag;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final rankingsAsync = ref.watch(statsHubTagRankingsProvider);

    return Card(
      elevation: 1,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: rankingsAsync.when(
          loading: () => Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  '标签统计',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ],
          ),
          error: (e, _) => Text('加载标签统计失败: $e'),
          data: (rankings) {
            final top5 = rankings.items.take(5).toList();
            final isExpense = rankings.bucket == StatBucket.expense;

            if (top5.isEmpty) {
              return Row(
                children: [
                  Text(
                    '标签统计',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      isExpense ? '当期暂无标签支出' : '当期暂无标签收入',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  TextButton(
                    key: const Key('stats-tag-all-rankings-btn'),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: onOpenAll,
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('全部排行'),
                        Icon(Icons.chevron_right, size: 16),
                      ],
                    ),
                  ),
                ],
              );
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(
                      child: Text(
                        '标签统计 Top 5',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    TextButton(
                      key: const Key('stats-tag-all-rankings-btn'),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: onOpenAll,
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('全部排行'),
                          Icon(Icons.chevron_right, size: 16),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                for (final item in top5)
                  InkWell(
                    key: Key('stats-tag-row-${item.tagId}'),
                    onTap: () => onTapTag(item),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              TagColorDot(colorHex: item.color, size: 8),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  '#${item.name} (${item.count} 笔)',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 8),
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 150,
                                ),
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerRight,
                                  child: Text(
                                    '¥${formatMinor(item.moneyMinor)} (${item.ratioText})',
                                    maxLines: 1,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: (item.ratioBasisPoints / 10000.0).clamp(
                                0.01,
                                1.0,
                              ),
                              minHeight: 4,
                              backgroundColor:
                                  theme.colorScheme.surfaceContainerHighest,
                              color:
                                  parseTagColor(item.color) ??
                                  (isExpense
                                      ? theme.colorScheme.error
                                      : theme.colorScheme.primary),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Route-addressable wrapper for `/stats/category/:id` that resolves the active
/// [CategoryStatsResult] from providers and renders [CategoryDrilldownPage].
class CategoryRouteDrilldownPage extends ConsumerWidget {
  const CategoryRouteDrilldownPage({super.key, required this.categoryId});

  final int categoryId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final resultAsync = ref.watch(categoryStatsResultProvider);
    final isFlatten = ref.watch(categoryStatsFlattenProvider);
    final bookId = ref.watch(currentBookIdProvider).value ?? 1;
    final categories =
        ref.watch(categoriesProvider(bookId)).value ?? const <RecordCategory>[];
    final catById = <int, RecordCategory>{for (final c in categories) c.id: c};
    return resultAsync.when(
      loading: () => Scaffold(
        appBar: AppBar(title: const Text('分类明细')),
        body: const Loading(),
      ),
      error: (err, _) => Scaffold(
        appBar: AppBar(title: const Text('分类明细')),
        body: ErrorView(err),
      ),
      data: (result) {
        if (categoryId == -1) {
          final uncat = result.uncategorizedRow;
          return CategoryDrilldownPage(
            categoryId: -1,
            categoryName: uncat?.name ?? '未分类',
            uncategorizedRow: uncat,
            result: result,
            categoriesById: catById,
          );
        }

        CategoryRowItem? findInFirstLevel() {
          for (final r in result.firstLevelRows) {
            if (r.categoryId == categoryId) {
              return r;
            }
            for (final child in r.children) {
              if (child.categoryId == categoryId) {
                return child;
              }
            }
          }
          return null;
        }

        final matched = isFlatten
            ? (result.flattenRows
                      .where((r) => r.categoryId == categoryId)
                      .firstOrNull ??
                  findInFirstLevel())
            : (findInFirstLevel() ??
                  result.flattenRows
                      .where((r) => r.categoryId == categoryId)
                      .firstOrNull);

        return CategoryDrilldownPage(
          categoryId: categoryId,
          categoryName: matched?.name ?? '分类明细',
          categoryIcon: matched?.icon ?? '',
          isDirectChild: matched?.isDirectChild ?? false,
          isFirstLevel: matched?.isFirstLevel ?? true,
          rowItem: matched,
          result: result,
          categoriesById: catById,
        );
      },
    );
  }
}
