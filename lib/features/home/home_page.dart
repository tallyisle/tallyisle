import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/app_settings_rules.dart';
import '../../domain/rules/asset_overview.dart';
import '../../domain/rules/income_expense.dart';
import '../books/book_switcher_modal.dart';
import '../budget/budget_providers.dart' show budgetOffsetProvider;
import '../budget/budget_widgets.dart';
import '../common/catalog_icons.dart';
import '../common/common.dart';
import '../records/record_labels.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  bool _pickingBook = false;

  @override
  Widget build(BuildContext context) {
    final book = ref.watch(currentBookProvider);
    return Scaffold(
      appBar: AppBar(
        title: InkWell(
          key: const Key('book-picker'),
          borderRadius: BorderRadius.circular(8),
          onTap: _pickBook,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    book.value?.name ?? '帐屿',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Icon(Icons.arrow_drop_down),
              ],
            ),
          ),
        ),
        actions: [
          IconButton(
            key: const Key('home-calendar-button'),
            tooltip: '日历',
            icon: const Icon(Icons.calendar_month),
            onPressed: () => context.push('/calendar'),
          ),
          IconButton(
            key: const Key('home-search-button'),
            tooltip: '搜索',
            icon: const Icon(Icons.search),
            onPressed: () => context.push('/search'),
          ),
        ],
      ),
      body: const _HomeBody(),
    );
  }

  Future<void> _pickBook() async {
    if (_pickingBook) return;
    _pickingBook = true;
    try {
      await showBookSwitcher(context, ref);
    } finally {
      _pickingBook = false;
    }
  }
}

class _HomeBody extends ConsumerWidget {
  const _HomeBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final period = ref.watch(currentPeriodProvider);
    final summary = ref.watch(periodSummaryProvider);
    final records = ref.watch(periodRecordsProvider);
    final bookId = ref.watch(currentBookIdProvider).value;
    final categories = bookId == null
        ? const <RecordCategory>[]
        : ref.watch(categoriesProvider(bookId)).value ?? const [];
    final assets = ref.watch(assetsProvider).value ?? const <Asset>[];
    final settings =
        ref.watch(appSettingsProvider).value ?? AppSettings.defaults;
    final assetOverview = ref.watch(assetOverviewProvider).value;
    final offset = ref.read(periodOffsetProvider.notifier);

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                IconButton(
                  tooltip: '上一期',
                  onPressed: offset.previous,
                  icon: const Icon(Icons.chevron_left),
                ),
                Expanded(
                  child: Center(
                    child: Text(
                      period.value == null
                          ? ''
                          : '${period.value!.year}年${period.value!.month}月',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '下一期',
                  onPressed: offset.next,
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
          ),
        ),
        if (settings.showHomeAssetSummaryBanner)
          SliverToBoxAdapter(
            child: _HomeAssetSummaryBanner(
              overview: assetOverview,
              onTap: () => context.go('/assets'),
            ),
          ),
        SliverToBoxAdapter(
          child: _SummaryCard(summary.value ?? IncomeExpense.zero),
        ),
        if (settings.showHomeBudgetCard && ref.watch(periodOffsetProvider) == 0)
          SliverToBoxAdapter(
            child: BudgetSummaryCard(
              fixedOffset: 0,
              hideWhenEmpty: true,
              onTap: () {
                ref.read(budgetOffsetProvider.notifier).reset();
                context.push('/budget');
              },
            ),
          ),
        ...switch (records) {
          AsyncData(:final value) when value.isEmpty => [
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: Text('本期暂无账单')),
            ),
          ],
          AsyncData(:final value) => [
            SliverList.list(
              children: _grouped(context, value, categories, assets),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 96)),
          ],
          AsyncError(:final error) => [
            SliverFillRemaining(child: ErrorView(error)),
          ],
          _ => [const SliverFillRemaining(child: Loading())],
        },
      ],
    );
  }

  List<Widget> _grouped(
    BuildContext context,
    List<LedgerRecord> records,
    List<RecordCategory> categories,
    List<Asset> assets,
  ) {
    final widgets = <Widget>[];
    String? day;
    for (final r in records) {
      final time = DateTime.fromMillisecondsSinceEpoch(r.recordTime);
      final key = formatDate(time);
      if (key != day) {
        day = key;
        widgets.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(key, style: Theme.of(context).textTheme.labelLarge),
          ),
        );
      }
      final label = recordLabel(r, categories, assets);
      final cat = r.recordCatId == noRef
          ? null
          : categories.where((c) => c.id == r.recordCatId).firstOrNull;
      final parentCat = (cat != null && cat.parentCatId != noRef)
          ? categories.where((c) => c.id == cat.parentCatId).firstOrNull
          : null;
      final catDisplayName = cat == null
          ? null
          : (parentCat != null ? '${parentCat.name} · ${cat.name}' : cat.name);
      final catColor =
          (cat?.colorFill != null && cat!.colorFill!.trim().isNotEmpty)
          ? cat.colorFill
          : parentCat?.colorFill;
      widgets.add(
        _HomeRecordTile(
          record: r,
          label: label,
          categoryName: catDisplayName,
          categoryIcon: cat?.icon,
          parentCategoryIcon: parentCat?.icon,
          categoryColor: catColor,
        ),
      );
    }
    return widgets;
  }
}

class _HomeRecordTile extends ConsumerWidget {
  const _HomeRecordTile({
    required this.record,
    required this.label,
    this.categoryName,
    this.categoryIcon,
    this.parentCategoryIcon,
    this.categoryColor,
  });

  final LedgerRecord record;
  final RecordLabel label;
  final String? categoryName;
  final String? categoryIcon;
  final String? parentCategoryIcon;
  final String? categoryColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tags =
        ref.watch(recordTagsProvider(record.recordId)).value ?? const <Tag>[];
    final theme = Theme.of(context);
    final isRefund =
        (record.type == RecordType.expense ||
            record.type == RecordType.income) &&
        record.moneyMinor < BigInt.zero;

    Widget? subtitle;
    if (label.subtitle.isNotEmpty && tags.isEmpty) {
      subtitle = Text(label.subtitle);
    } else if (label.subtitle.isNotEmpty || tags.isNotEmpty) {
      subtitle = Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (label.subtitle.isNotEmpty) Text(label.subtitle),
          for (final t in tags)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer.withValues(
                  alpha: 0.7,
                ),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '#${t.name}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
            ),
        ],
      );
    }

    return ListTile(
      key: Key('record-${record.recordId}'),
      leading: RecordTypeIconAvatar(
        recordType: record.type,
        subType: record.subType,
        isRefund: isRefund,
        categoryName: categoryName,
        categoryIcon: categoryIcon,
        parentCategoryIcon: parentCategoryIcon,
        categoryColor: categoryColor,
      ),
      title: Text(label.title),
      subtitle: subtitle,
      trailing: Text(
        label.amount,
        style: TextStyle(
          color: record.type == RecordType.income
              ? (theme.brightness == Brightness.dark
                    ? Colors.green.shade300
                    : Colors.green.shade700)
              : null,
          fontWeight: FontWeight.w600,
        ),
      ),
      onTap: () => context.push('/record/${record.recordId}'),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard(this.s);
  final IncomeExpense s;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget cell(String label, BigInt v, Key key) => Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Column(
          children: [
            Text(label, style: theme.textTheme.labelMedium),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                formatMinor(v),
                key: key,
                maxLines: 1,
                softWrap: false,
                style: theme.textTheme.titleMedium,
              ),
            ),
          ],
        ),
      ),
    );
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Row(
          children: [
            cell('结余', s.balance, const Key('sum-balance')),
            cell('支出', s.expense, const Key('sum-expense')),
            cell('收入', s.income, const Key('sum-income')),
          ],
        ),
      ),
    );
  }
}

class _HomeAssetSummaryBanner extends StatelessWidget {
  const _HomeAssetSummaryBanner({required this.overview, required this.onTap});

  final AssetOverview? overview;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final net = overview?.netAsset ?? BigInt.zero;
    final totalAsset = overview?.totalAsset ?? BigInt.zero;
    final totalLiability = overview?.totalLiabilities ?? BigInt.zero;

    return Card(
      key: const Key('home-asset-summary-banner'),
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(
                Icons.account_balance_wallet_outlined,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '净资产 ¥${formatMinor(net)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  '资产 ¥${formatMinor(totalAsset)} · 负债 ¥${formatMinor(totalLiability)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
