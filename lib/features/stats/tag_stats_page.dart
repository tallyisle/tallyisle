import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/db/database.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/billing_period.dart';
import '../../domain/rules/tag_stats.dart';
import '../common/catalog_icons.dart';
import '../common/common.dart';
import '../records/record_labels.dart';
import 'tag_stats_providers.dart';

/// Parses a stored tag color string into a Flutter [Color], or `null` if default.
Color? parseTagColor(String? raw) {
  final argb = parseTagColorArgb(raw);
  return argb == null ? null : Color(argb);
}

/// Tag color dot widget.
class TagColorDot extends StatelessWidget {
  const TagColorDot({super.key, this.colorHex, this.size = 10});

  final String? colorHex;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = parseTagColor(colorHex) ?? Theme.of(context).colorScheme.primary;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: c, shape: BoxShape.circle),
    );
  }
}

/// Tag Rankings Page (`/stats/tags`).
class TagRankingsPage extends ConsumerWidget {
  const TagRankingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(tagRankingsPeriodModeProvider);
    final bucket = ref.watch(tagRankingsBucketProvider);
    final rollup = ref.watch(tagRankingsRollupProvider);
    final viewAsync = ref.watch(tagRankingsViewProvider);
    final theme = Theme.of(context);

    return Scaffold(
      key: const Key('tag-rankings-page'),
      appBar: AppBar(
        title: const Text('标签统计'),
        actions: [
          IconButton(
            key: const Key('tag-rankings-open-tags-btn'),
            tooltip: '标签管理',
            icon: const Icon(Icons.label_outline),
            onPressed: () => context.push('/tags'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        children: [
          // 1. Period Mode Selector (全部 | 按月 | 按年) + Prev/Next navigation
          _TagPeriodSelectorBar(
            keyPrefix: 'tag-rankings',
            mode: mode,
            period: viewAsync.value?.period,
            onModeChanged: (m) {
              ref.read(tagRankingsPeriodModeProvider.notifier).setMode(m);
              ref.read(tagRankingsOffsetProvider.notifier).reset();
            },
            onPrevious: () =>
                ref.read(tagRankingsOffsetProvider.notifier).previous(),
            onNext: () => ref.read(tagRankingsOffsetProvider.notifier).next(),
          ),
          const SizedBox(height: 12),

          // 2. Bucket Switch (支出 | 收入)
          SegmentedButton<StatBucket>(
            key: const Key('tag-rankings-bucket-switch'),
            segments: const [
              ButtonSegment(
                value: StatBucket.expense,
                label: Text('支出'),
                icon: Icon(Icons.arrow_upward),
              ),
              ButtonSegment(
                value: StatBucket.income,
                label: Text('收入'),
                icon: Icon(Icons.arrow_downward),
              ),
            ],
            selected: {bucket},
            onSelectionChanged: (s) {
              if (s.isNotEmpty) {
                ref.read(tagRankingsBucketProvider.notifier).setBucket(s.first);
              }
            },
          ),
          const SizedBox(height: 12),

          // 3. Summary & Ranked List
          viewAsync.when(
            loading: () =>
                const Padding(padding: EdgeInsets.all(32), child: Loading()),
            error: (e, _) => ErrorView(e),
            data: (view) {
              final rankings = view.rankings;
              final isExpense = rankings.bucket == StatBucket.expense;
              final accentColor = isExpense
                  ? theme.colorScheme.error
                  : theme.colorScheme.primary;

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Summary Header Card
                  Card(
                    elevation: 1,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                isExpense ? '标签总支出（去重）' : '标签总收入（去重）',
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '¥${formatMinor(rankings.totalMinor)}',
                                key: const Key('tag-rankings-total-amount'),
                                style: theme.textTheme.headlineSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: accentColor,
                                ),
                              ),
                            ],
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                '${rankings.totalBillCount} 笔关联账单',
                                key: const Key('tag-rankings-total-count'),
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${rankings.items.length} 个活跃标签',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  if (view.hasTagGroups)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '标签排行榜',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          SegmentedButton<bool>(
                            key: const Key('tag-rankings-rollup-switch'),
                            style: const ButtonStyle(
                              visualDensity: VisualDensity.compact,
                            ),
                            segments: const [
                              ButtonSegment(value: false, label: Text('按标签')),
                              ButtonSegment(value: true, label: Text('按标签组')),
                            ],
                            selected: {rollup},
                            onSelectionChanged: (s) {
                              if (s.isNotEmpty) {
                                ref
                                    .read(tagRankingsRollupProvider.notifier)
                                    .setRollup(s.first);
                              }
                            },
                          ),
                        ],
                      ),
                    ),

                  if (rankings.items.isEmpty)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 32,
                        ),
                        child: Column(
                          children: [
                            Icon(
                              Icons.label_off_outlined,
                              size: 40,
                              color: theme.colorScheme.outline,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              view.hasAnyTags
                                  ? '当前周期暂无带标签的${isExpense ? '支出' : '收入'}账单'
                                  : '还没有创建任何标签',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 16),
                            OutlinedButton.icon(
                              key: const Key('tag-rankings-manage-tags-btn'),
                              icon: const Icon(Icons.label_outline, size: 18),
                              label: const Text('去管理标签'),
                              onPressed: () => context.push('/tags'),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    Card(
                      elevation: 1,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        child: Column(
                          children: [
                            for (var i = 0; i < rankings.items.length; i++) ...[
                              if (i > 0) const Divider(height: 1),
                              _TagRankingRow(
                                item: rankings.items[i],
                                fallbackBarColor: accentColor,
                                onTap: () => context.push(
                                  '/stats/tag/${rankings.items[i].tagId}',
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _TagRankingRow extends StatelessWidget {
  const _TagRankingRow({
    required this.item,
    required this.fallbackBarColor,
    required this.onTap,
  });

  final TagRankingItem item;
  final Color fallbackBarColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tagColor = parseTagColor(item.color);
    final barColor = tagColor ?? fallbackBarColor;

    return InkWell(
      key: Key('tag-ranking-row-${item.tagId}'),
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        child: Column(
          children: [
            Row(
              children: [
                TagColorDot(colorHex: item.color, size: 10),
                const SizedBox(width: 8),
                Expanded(
                  child: Wrap(
                    spacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        '#${item.name}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (item.isGroup)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.secondaryContainer,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '标签组',
                            style: TextStyle(
                              fontSize: 10,
                              color: theme.colorScheme.onSecondaryContainer,
                            ),
                          ),
                        )
                      else if (item.parentName != null)
                        Text(
                          '(${item.parentName})',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      Text(
                        '${item.count} 笔',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '¥${formatMinor(item.moneyMinor)}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      item.ratioText,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: theme.colorScheme.outline,
                ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: (item.ratioBasisPoints / 10000.0).clamp(0.01, 1.0),
                minHeight: 5,
                color: barColor,
                backgroundColor: barColor.withValues(alpha: 0.14),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Tag Detail & Associated Bills Page (`/stats/tag/:id`).
class TagDetailStatsPage extends ConsumerStatefulWidget {
  const TagDetailStatsPage({super.key, required this.tagId});

  final String tagId;

  @override
  ConsumerState<TagDetailStatsPage> createState() => _TagDetailStatsPageState();
}

class _TagDetailStatsPageState extends ConsumerState<TagDetailStatsPage> {
  TagStatsPeriodMode _periodMode = TagStatsPeriodMode.all;
  int _periodOffset = 0;
  StatBucket _catBucket = StatBucket.expense;
  bool _userPickedCatBucket = false;
  bool _categoryExpanded = true;

  @override
  Widget build(BuildContext context) {
    final query = (
      tagId: widget.tagId,
      mode: _periodMode,
      offset: _periodOffset,
    );
    final viewAsync = ref.watch(tagDetailViewProvider(query));
    final theme = Theme.of(context);

    return Scaffold(
      key: const Key('tag-detail-stats-page'),
      appBar: AppBar(
        title: viewAsync.maybeWhen(
          data: (d) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TagColorDot(colorHex: d.stats.tag.color, size: 12),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  '#${d.stats.tag.name}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          orElse: () => const Text('标签统计详情'),
        ),
      ),
      body: viewAsync.when(
        loading: () => const Loading(),
        error: (e, _) => ErrorView(e),
        data: (data) {
          final stats = data.stats;
          final effectiveCatBucket = _userPickedCatBucket
              ? _catBucket
              : (stats.totalExpense == BigInt.zero &&
                        stats.totalIncome > BigInt.zero
                    ? StatBucket.income
                    : StatBucket.expense);
          final catRows = effectiveCatBucket == StatBucket.expense
              ? stats.expenseCategories
              : stats.incomeCategories;
          final catById = <int, RecordCategory>{
            for (final c in data.categories) c.id: c,
          };

          return ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            children: [
              // Group or parent badge banner
              if (stats.isGroup)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '标签组 · 含 ${stats.childTags.length} 个子标签',
                          key: const Key('tag-detail-group-badge'),
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: theme.colorScheme.onSecondaryContainer,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              else if (stats.parentTag != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: ActionChip(
                      key: Key(
                        'tag-detail-parent-chip-${stats.parentTag!.tagId}',
                      ),
                      visualDensity: VisualDensity.compact,
                      avatar: TagColorDot(
                        colorHex: stats.parentTag!.color,
                        size: 8,
                      ),
                      label: Text('所属标签组：#${stats.parentTag!.name}'),
                      onPressed: () =>
                          context.push('/stats/tag/${stats.parentTag!.tagId}'),
                    ),
                  ),
                ),

              // 1. Period Selector (全部 | 按月 | 按年, defaults to 全部)
              _TagPeriodSelectorBar(
                keyPrefix: 'tag-detail',
                mode: _periodMode,
                period: data.period,
                onModeChanged: (m) => setState(() {
                  _periodMode = m;
                  _periodOffset = 0;
                }),
                onPrevious: () => setState(() => _periodOffset--),
                onNext: () => setState(() => _periodOffset++),
              ),
              const SizedBox(height: 12),

              // 2. Summary Card: 总支出, 总收入, 结余, 关联账单数
              Card(
                key: const Key('tag-detail-summary-card'),
                elevation: 1,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: _MetricTile(
                              label: '总支出',
                              value: '¥${formatMinor(stats.totalExpense)}',
                              valueKey: const Key('tag-detail-total-expense'),
                              valueColor: theme.colorScheme.error,
                            ),
                          ),
                          Expanded(
                            child: _MetricTile(
                              label: '总收入',
                              value: '¥${formatMinor(stats.totalIncome)}',
                              valueKey: const Key('tag-detail-total-income'),
                              valueColor: Colors.green.shade700,
                            ),
                          ),
                        ],
                      ),
                      const Divider(height: 20),
                      Row(
                        children: [
                          Expanded(
                            child: _MetricTile(
                              label: '结余',
                              value:
                                  '${stats.netBalance.isNegative ? '-¥' : '¥'}${formatMinor(stats.netBalance.abs())}',
                              valueKey: const Key('tag-detail-net-balance'),
                            ),
                          ),
                          Expanded(
                            child: _MetricTile(
                              label: '关联账单数',
                              value: '${stats.billCount} 笔',
                              valueKey: const Key('tag-detail-bill-count'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // 3. Child-tag Breakdown Chips (if parent tag group with children)
              if (stats.isGroup && stats.childBreakdowns.isNotEmpty) ...[
                Card(
                  key: const Key('tag-detail-children-section'),
                  elevation: 1,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '子标签构成',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final child in stats.childBreakdowns)
                              _ChildTagBreakdownChip(
                                item: child,
                                onTap: child.isDirectOnGroup
                                    ? null
                                    : () => context.push(
                                        '/stats/tag/${child.tagId}',
                                      ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],

              // 4. Collapsible Category Breakdown Section (支出构成 / 收入构成)
              if (stats.expenseCategories.isNotEmpty ||
                  stats.incomeCategories.isNotEmpty) ...[
                Card(
                  key: const Key('tag-detail-category-section'),
                  elevation: 1,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '分类构成',
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            SegmentedButton<StatBucket>(
                              key: const Key('tag-detail-cat-bucket-switch'),
                              style: const ButtonStyle(
                                visualDensity: VisualDensity.compact,
                              ),
                              segments: const [
                                ButtonSegment(
                                  value: StatBucket.expense,
                                  label: Text('支出构成'),
                                ),
                                ButtonSegment(
                                  value: StatBucket.income,
                                  label: Text('收入构成'),
                                ),
                              ],
                              selected: {effectiveCatBucket},
                              onSelectionChanged: (s) {
                                if (s.isNotEmpty) {
                                  setState(() {
                                    _userPickedCatBucket = true;
                                    _catBucket = s.first;
                                  });
                                }
                              },
                            ),
                            IconButton(
                              key: const Key('tag-detail-cat-expand-btn'),
                              visualDensity: VisualDensity.compact,
                              icon: Icon(
                                _categoryExpanded
                                    ? Icons.expand_less
                                    : Icons.expand_more,
                              ),
                              tooltip: _categoryExpanded ? '收起分类构成' : '展开分类构成',
                              onPressed: () => setState(
                                () => _categoryExpanded = !_categoryExpanded,
                              ),
                            ),
                          ],
                        ),
                        if (_categoryExpanded) ...[
                          const SizedBox(height: 6),
                          if (catRows.isEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: Center(
                                child: Text(
                                  effectiveCatBucket == StatBucket.expense
                                      ? '无支出分类构成'
                                      : '无收入分类构成',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            )
                          else
                            for (final cat in catRows)
                              Builder(
                                builder: (context) {
                                  final dbCat = cat.categoryId == noRef
                                      ? null
                                      : catById[cat.categoryId];
                                  final parentCat =
                                      (dbCat != null &&
                                          dbCat.parentCatId != noRef)
                                      ? catById[dbCat.parentCatId]
                                      : null;
                                  final catIcon =
                                      (dbCat?.icon != null &&
                                          dbCat!.icon.trim().isNotEmpty)
                                      ? dbCat.icon
                                      : (cat.icon.isNotEmpty ? cat.icon : null);
                                  final catColor =
                                      (dbCat?.colorFill != null &&
                                          dbCat!.colorFill!.trim().isNotEmpty)
                                      ? dbCat.colorFill
                                      : parentCat?.colorFill;
                                  final catType =
                                      effectiveCatBucket == StatBucket.income
                                      ? RecordType.income
                                      : RecordType.expense;
                                  final visual = resolveCategoryVisual(
                                    iconKey: catIcon,
                                    parentIconKey: parentCat?.icon,
                                    colorHex: catColor,
                                    name: cat.name,
                                    type: catType,
                                  );
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 5,
                                    ),
                                    child: Column(
                                      children: [
                                        Row(
                                          children: [
                                            CategoryIconAvatar(
                                              iconKey: catIcon,
                                              parentIconKey: parentCat?.icon,
                                              colorHex: catColor,
                                              name: cat.name,
                                              type: catType,
                                              size: 26,
                                            ),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                '${cat.name} (${cat.count} 笔)',
                                                style:
                                                    theme.textTheme.bodyMedium,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Text(
                                              '¥${formatMinor(cat.moneyMinor)} (${cat.ratioText})',
                                              style: theme.textTheme.bodySmall
                                                  ?.copyWith(
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 4),
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(
                                            2,
                                          ),
                                          child: LinearProgressIndicator(
                                            value:
                                                (cat.ratioBasisPoints / 10000.0)
                                                    .clamp(0.01, 1.0),
                                            minHeight: 4,
                                            color: visual.color,
                                            backgroundColor: visual.color
                                                .withValues(alpha: 0.14),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],

              // 5. Associated Bills List grouped by YYYY-MM-DD
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  '关联账单明细 (${data.matchingRecords.length} 笔)',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (data.matchingRecords.isEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 32,
                    ),
                    child: Center(
                      child: Text(
                        _periodMode == TagStatsPeriodMode.all
                            ? '该标签下暂无关联账单'
                            : '当前所选周期暂无关联账单，可切换至“全部”查看历史账单',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                )
              else
                ..._buildGroupedBillList(context, data),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _buildGroupedBillList(
    BuildContext context,
    TagDetailViewData data,
  ) {
    final theme = Theme.of(context);
    final widgets = <Widget>[];
    String? currentDay;

    for (final r in data.matchingRecords) {
      final dt = DateTime.fromMillisecondsSinceEpoch(r.recordTime);
      final dayKey = formatDate(dt);
      if (dayKey != currentDay) {
        currentDay = dayKey;
        widgets.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
            child: Text(
              dayKey,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        );
      }

      final label = recordLabel(r, data.categories, data.assets);
      final cat = r.recordCatId == noRef
          ? null
          : data.categories.where((c) => c.id == r.recordCatId).firstOrNull;
      final parentCat = (cat != null && cat.parentCatId != noRef)
          ? data.categories.where((c) => c.id == cat.parentCatId).firstOrNull
          : null;
      final catDisplayName = cat == null
          ? null
          : (parentCat != null ? '${parentCat.name} · ${cat.name}' : cat.name);
      final catColor =
          (cat?.colorFill != null && cat!.colorFill!.trim().isNotEmpty)
          ? cat.colorFill
          : parentCat?.colorFill;
      final isRefund =
          (r.type == RecordType.expense || r.type == RecordType.income) &&
          r.moneyMinor < BigInt.zero;
      final attachedTags = data.recordTags[r.recordId] ?? const <Tag>[];
      final otherTags = attachedTags
          .where((t) => t.tagId != widget.tagId)
          .map((t) => '#${t.name}')
          .toList();

      final subtitleParts = <String>[
        if (label.subtitle.isNotEmpty) label.subtitle,
        if (otherTags.isNotEmpty) otherTags.join(' '),
      ];

      widgets.add(
        Card(
          margin: const EdgeInsets.symmetric(vertical: 3),
          child: ListTile(
            key: Key('tag-detail-bill-${r.recordId}'),
            leading: RecordTypeIconAvatar(
              recordType: r.type,
              subType: r.subType,
              isRefund: isRefund,
              categoryName: catDisplayName,
              categoryIcon: cat?.icon,
              parentCategoryIcon: parentCat?.icon,
              categoryColor: catColor,
            ),
            title: Text(label.title),
            subtitle: subtitleParts.isEmpty
                ? null
                : Text(subtitleParts.join(' · ')),
            trailing: Text(
              label.amount,
              style: TextStyle(
                color: r.type == RecordType.income
                    ? Colors.green.shade700
                    : null,
                fontWeight: FontWeight.w600,
              ),
            ),
            onTap: () => context.push('/record/${r.recordId}'),
          ),
        ),
      );
    }

    return widgets;
  }
}

class _TagPeriodSelectorBar extends StatelessWidget {
  const _TagPeriodSelectorBar({
    required this.keyPrefix,
    required this.mode,
    required this.period,
    required this.onModeChanged,
    required this.onPrevious,
    required this.onNext,
  });

  final String keyPrefix;
  final TagStatsPeriodMode mode;
  final BillingPeriod? period;
  final ValueChanged<TagStatsPeriodMode> onModeChanged;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = formatTagStatsPeriodLabel(mode, period);

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ChoiceChip(
              key: Key('$keyPrefix-mode-all'),
              label: const Text('全部'),
              selected: mode == TagStatsPeriodMode.all,
              onSelected: (sel) {
                if (sel) onModeChanged(TagStatsPeriodMode.all);
              },
            ),
            const SizedBox(width: 8),
            ChoiceChip(
              key: Key('$keyPrefix-mode-month'),
              label: const Text('按月'),
              selected: mode == TagStatsPeriodMode.month,
              onSelected: (sel) {
                if (sel) onModeChanged(TagStatsPeriodMode.month);
              },
            ),
            const SizedBox(width: 8),
            ChoiceChip(
              key: Key('$keyPrefix-mode-year'),
              label: const Text('按年'),
              selected: mode == TagStatsPeriodMode.year,
              onSelected: (sel) {
                if (sel) onModeChanged(TagStatsPeriodMode.year);
              },
            ),
          ],
        ),
        if (mode != TagStatsPeriodMode.all) ...[
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                key: Key('$keyPrefix-prev-period'),
                tooltip: '上一周期',
                icon: const Icon(Icons.chevron_left),
                onPressed: onPrevious,
              ),
              Text(
                label,
                key: Key('$keyPrefix-period-label'),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              IconButton(
                key: Key('$keyPrefix-next-period'),
                tooltip: '下一周期',
                icon: const Icon(Icons.chevron_right),
                onPressed: onNext,
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.label,
    required this.value,
    this.valueKey,
    this.valueColor,
  });

  final String label;
  final String value;
  final Key? valueKey;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          key: valueKey,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: valueColor,
          ),
        ),
      ],
    );
  }
}

class _ChildTagBreakdownChip extends StatelessWidget {
  const _ChildTagBreakdownChip({required this.item, this.onTap});

  final TagChildBreakdownItem item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tint = parseTagColor(item.color);
    final amountParts = <String>[];
    if (item.expenseMinor > BigInt.zero) {
      amountParts.add('-¥${formatMinor(item.expenseMinor)}');
    }
    if (item.incomeMinor > BigInt.zero) {
      amountParts.add('+¥${formatMinor(item.incomeMinor)}');
    }
    final amountLabel = amountParts.isEmpty ? '¥0.00' : amountParts.join(' ');

    return ActionChip(
      key: Key('tag-detail-child-${item.tagId}'),
      avatar: TagColorDot(colorHex: item.color, size: 8),
      backgroundColor: tint?.withValues(alpha: 0.12),
      side: tint == null
          ? null
          : BorderSide(color: tint.withValues(alpha: 0.4)),
      label: Text('#${item.name} · ${item.billCount} 笔 · $amountLabel'),
      onPressed: onTap,
    );
  }
}
