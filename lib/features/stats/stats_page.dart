import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../domain/rules/category_stats.dart';
import '../../domain/rules/tag_stats.dart';
import '../budget/budget_widgets.dart';
import '../common/common.dart';
import 'annual_report_page.dart';
import 'asset_trend_page.dart';
import 'category_stats_page.dart';
import 'category_stats_providers.dart';
import 'tag_stats_page.dart' show TagColorDot, parseTagColor;
import 'tag_stats_providers.dart' show statsHubTagRankingsProvider;

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

  @override
  Widget build(BuildContext context) {
    final book = ref.watch(currentBookProvider);

    return Scaffold(
      key: const Key('stats-hub-page'),
      appBar: AppBar(
        title: InkWell(
          key: const Key('stats-book-switcher'),
          onTap: _pickBook,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(book.value?.name ?? '统计'),
              const Icon(Icons.arrow_drop_down),
            ],
          ),
        ),
        actions: [
          IconButton(
            key: const Key('stats-budget-action'),
            tooltip: '预算管理',
            icon: const Icon(Icons.savings_outlined),
            onPressed: () => context.push('/budget'),
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
      body: ListView(
        key: const Key('stats-hub-list'),
        padding: const EdgeInsets.only(top: 4, bottom: 32),
        children: [
          AnnualReportOverviewCard(onTap: () => context.push('/stats/annual')),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: CategoryStatsOverviewCard(
              key: const Key('stats-category-overview-card'),
              onOpenDetail: () => context.push('/stats/category'),
              onTapCategory: (row) =>
                  context.push('/stats/category/${row.categoryId}'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: _TagStatsOverviewCard(
              key: const Key('stats-tag-overview-card'),
              onOpenAll: () => context.push('/stats/tags'),
              onTapTag: (item) => context.push('/stats/tag/${item.tagId}'),
            ),
          ),
          BudgetSummaryCard(onTap: () => context.push('/budget')),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: AssetTrendOverviewCard(
              onTap: () => context.push('/stats/trend'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickBook() async {
    if (_pickingBook) return;
    _pickingBook = true;
    try {
      final db = await ref.read(databaseProvider.future);
      final books =
          await (db.select(db.accountBooks)..orderBy([
                (t) => OrderingTerm.asc(t.sort),
                (t) => OrderingTerm.asc(t.id),
              ]))
              .get();
      final pref = await (db.select(
        db.preferences,
      )..where((t) => t.key.equals('current_book_id'))).getSingleOrNull();
      final current =
          int.tryParse(pref?.value ?? '') ??
          (books.isNotEmpty ? books.first.id : 1);

      if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? true)) return;

      final picked = await showModalBottomSheet<int>(
        context: context,
        builder: (sheetCtx) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final b in books)
                ListTile(
                  title: Text(b.name),
                  trailing: b.id == current ? const Icon(Icons.check) : null,
                  onTap: () => Navigator.pop(sheetCtx, b.id),
                ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: const Text('管理账本…'),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  context.push('/books');
                },
              ),
            ],
          ),
        ),
      );
      if (picked == null || !mounted) return;
      await db
          .into(db.preferences)
          .insertOnConflictUpdate(
            PreferencesCompanion.insert(
              key: 'current_book_id',
              value: '$picked',
            ),
          );
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
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: rankingsAsync.when(
          loading: () => Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '标签统计',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
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
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  TextButton(
                    key: const Key('stats-tag-all-rankings-btn'),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
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
                    Text(
                      '标签统计 Top 5',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    TextButton(
                      key: const Key('stats-tag-all-rankings-btn'),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
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
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              Text(
                                '¥${formatMinor(item.moneyMinor)} (${item.ratioText})',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontWeight: FontWeight.w600,
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

        CategoryRowItem? matched;
        for (final r in result.firstLevelRows) {
          if (r.categoryId == categoryId) {
            matched = r;
            break;
          }
          for (final child in r.children) {
            if (child.categoryId == categoryId) {
              matched = child;
              break;
            }
          }
          if (matched != null) break;
        }
        matched ??= result.flattenRows
            .where((r) => r.categoryId == categoryId)
            .firstOrNull;

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
