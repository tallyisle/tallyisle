import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../domain/rules/category_stats.dart';
import '../budget/budget_widgets.dart';
import '../common/common.dart';
import 'annual_report_page.dart';
import 'asset_trend_page.dart';
import 'category_stats_page.dart';
import 'category_stats_providers.dart';

/// Unified bottom "统计" Tab (mirrors original `AnalyzeFragment`, F-006 / F-008 / F-030).
///
/// Vertically stacks:
/// 1. Annual report overview card -> `/stats/annual`
/// 2. Current period category stats overview card -> `/stats/category` & `/stats/category/:id`
/// 3. Current period budget summary card -> `/budget`
/// 4. Real-time asset overview & trend card -> `/stats/trend`
class StatsPage extends ConsumerWidget {
  const StatsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final book = ref.watch(currentBookProvider);

    return Scaffold(
      key: const Key('stats-hub-page'),
      appBar: AppBar(
        title: InkWell(
          key: const Key('stats-book-switcher'),
          onTap: () => _pickBook(context, ref),
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

  Future<void> _pickBook(BuildContext context, WidgetRef ref) async {
    final books = await ref.read(booksProvider.future);
    if (!context.mounted) return;
    final current = ref.read(currentBookIdProvider).value;
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final b in books)
              ListTile(
                title: Text(b.name),
                trailing: b.id == current ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, b.id),
              ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('管理账本…'),
              onTap: () {
                Navigator.pop(context);
                context.push('/books');
              },
            ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await (await ref.read(queriesProvider.future)).setCurrentBook(picked);
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
        );
      },
    );
  }
}
