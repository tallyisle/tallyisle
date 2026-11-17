import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/adaptive.dart';
import '../../data/db/database.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/billing_period.dart';
import '../../domain/rules/tag_stats.dart';
import '../common/catalog_icons.dart';
import '../common/common.dart';
import '../common/desktop_modal_page.dart';
import '../records/record_detail_page.dart';
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
class TagRankingsPage extends ConsumerStatefulWidget {
  const TagRankingsPage({super.key});

  @override
  ConsumerState<TagRankingsPage> createState() => _TagRankingsPageState();
}

class _TagRankingsPageState extends ConsumerState<TagRankingsPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ref.read(tagRankingsOffsetProvider) != 0) {
        ref.read(tagRankingsOffsetProvider.notifier).reset();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(tagRankingsPeriodModeProvider);
    final bucket = ref.watch(tagRankingsBucketProvider);
    final rollup = ref.watch(tagRankingsRollupProvider);
    final viewAsync = ref.watch(tagRankingsViewProvider);
    final theme = Theme.of(context);
    final isDesktop = DesktopAdaptive.isDesktop(context);
    final isExpandedDesktop = DesktopAdaptive.isExpandedDesktop(context);
    final isPopupModal = isDesktop && ModalRoute.of(context) is PopupRoute;

    final bucketSwitch = SegmentedButton<StatBucket>(
      key: const Key('tag-rankings-bucket-switch'),
      showSelectedIcon: false,
      style: const ButtonStyle(
        visualDensity: VisualDensity.compact,
        padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      segments: const [
        ButtonSegment(
          value: StatBucket.expense,
          label: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text('支出', maxLines: 1, softWrap: false),
          ),
          icon: Icon(Icons.arrow_upward, size: 18),
        ),
        ButtonSegment(
          value: StatBucket.income,
          label: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text('收入', maxLines: 1, softWrap: false),
          ),
          icon: Icon(Icons.arrow_downward, size: 18),
        ),
      ],
      selected: {bucket},
      onSelectionChanged: (s) {
        if (s.isNotEmpty) {
          ref.read(tagRankingsBucketProvider.notifier).setBucket(s.first);
        }
      },
    );

    Widget buildPeriodBar({bool compactDesktop = false}) {
      return _TagPeriodSelectorBar(
        keyPrefix: 'tag-rankings',
        mode: mode,
        period: viewAsync.value?.period,
        compactDesktop: compactDesktop,
        onModeChanged: (m) {
          ref.read(tagRankingsPeriodModeProvider.notifier).setMode(m);
          ref.read(tagRankingsOffsetProvider.notifier).reset();
        },
        onPrevious: () =>
            ref.read(tagRankingsOffsetProvider.notifier).previous(),
        onNext: () => ref.read(tagRankingsOffsetProvider.notifier).next(),
      );
    }

    Widget buildSummaryCard(TagRankingsResult rankings, Color accentColor) {
      final isExpense = rankings.bucket == StatBucket.expense;
      return Card(
        elevation: 1,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isExpense ? '标签总支出（去重）' : '标签总收入（去重）',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 4),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '¥${formatMinor(rankings.totalMinor)}',
                        key: const Key('tag-rankings-total-amount'),
                        maxLines: 1,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: accentColor,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Text(
                        '${rankings.totalBillCount} 笔关联账单',
                        key: const Key('tag-rankings-total-count'),
                        maxLines: 1,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${rankings.items.length} 个活跃标签',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    Widget buildRollupHeader(TagRankingsViewData view) {
      if (!view.hasTagGroups) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Text(
                '标签排行榜',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 8),
            SegmentedButton<bool>(
              key: const Key('tag-rankings-rollup-switch'),
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                padding: WidgetStatePropertyAll(
                  EdgeInsets.symmetric(horizontal: 10),
                ),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              segments: const [
                ButtonSegment(
                  value: false,
                  label: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text('按标签', maxLines: 1, softWrap: false),
                  ),
                ),
                ButtonSegment(
                  value: true,
                  label: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text('按标签组', maxLines: 1, softWrap: false),
                  ),
                ),
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
      );
    }

    Widget buildRankingsCardOrEmpty(
      TagRankingsViewData view,
      Color accentColor,
    ) {
      final rankings = view.rankings;
      final isExpense = rankings.bucket == StatBucket.expense;
      if (rankings.items.isEmpty) {
        return Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
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
        );
      }
      return Card(
        elevation: 1,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            children: [
              for (var i = 0; i < rankings.items.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                _TagRankingRow(
                  item: rankings.items[i],
                  fallbackBarColor: accentColor,
                  onTap: () {
                    final targetTagId = rankings.items[i].tagId;
                    if (GoRouter.maybeOf(context) != null &&
                        ModalRoute.of(context)?.settings is Page) {
                      context.push('/stats/tag/$targetTagId');
                    } else {
                      pushDesktopModalOrMaterialRoute<void>(
                        context,
                        maxWidth: 860,
                        maxHeight: 720,
                        barrierDismissible: true,
                        child: TagDetailStatsPage(tagId: targetTagId),
                      );
                    }
                  },
                ),
              ],
            ],
          ),
        ),
      );
    }

    return Scaffold(
      key: const Key('tag-rankings-page'),
      appBar: AppBar(
        leading: isPopupModal ? const CloseButton() : null,
        title: const Text('标签统计'),
        actions: [
          IconButton(
            key: const Key('tag-rankings-open-tags-btn'),
            tooltip: '标签管理',
            icon: const Icon(Icons.label_outline),
            onPressed: () {
              if (isPopupModal) {
                Navigator.of(context).maybePop();
              } else {
                context.push('/tags');
              }
            },
          ),
        ],
      ),
      body: isExpandedDesktop
          ? Column(
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1360),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          SizedBox(width: 210, child: bucketSwitch),
                          const SizedBox(width: 20),
                          Expanded(child: buildPeriodBar(compactDesktop: true)),
                        ],
                      ),
                    ),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: viewAsync.when(
                    loading: () => const Center(child: Loading()),
                    error: (e, _) => ErrorView(e),
                    data: (view) {
                      final rankings = view.rankings;
                      final isExpense = rankings.bucket == StatBucket.expense;
                      final accentColor = isExpense
                          ? theme.colorScheme.error
                          : theme.colorScheme.primary;
                      return Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 1360),
                          child: Row(
                            key: const Key('tag-rankings-desktop-split'),
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                flex: 44,
                                child: ListView(
                                  padding: const EdgeInsets.fromLTRB(
                                    20,
                                    14,
                                    12,
                                    24,
                                  ),
                                  children: [
                                    buildSummaryCard(rankings, accentColor),
                                    const SizedBox(height: 14),
                                    _TagProportionOverviewCard(
                                      rankings: rankings,
                                      fallbackColor: accentColor,
                                    ),
                                  ],
                                ),
                              ),
                              const VerticalDivider(width: 1),
                              Expanded(
                                flex: 56,
                                child: ListView(
                                  padding: const EdgeInsets.fromLTRB(
                                    12,
                                    14,
                                    20,
                                    24,
                                  ),
                                  children: [
                                    if (view.hasTagGroups)
                                      buildRollupHeader(view)
                                    else
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: 8,
                                        ),
                                        child: Text(
                                          '标签排行榜',
                                          style: theme.textTheme.titleMedium
                                              ?.copyWith(
                                                fontWeight: FontWeight.bold,
                                              ),
                                        ),
                                      ),
                                    buildRankingsCardOrEmpty(view, accentColor),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            )
          : () {
              final stackedList = ListView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                children: [
                  // 1. Period Mode Selector (全部 | 按月 | 按年) + Prev/Next navigation
                  buildPeriodBar(),
                  const SizedBox(height: 12),

                  // 2. Bucket Switch (支出 | 收入)
                  SizedBox(width: double.infinity, child: bucketSwitch),
                  const SizedBox(height: 12),

                  // 3. Summary & Ranked List
                  viewAsync.when(
                    loading: () => const Padding(
                      padding: EdgeInsets.all(32),
                      child: Loading(),
                    ),
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
                          buildSummaryCard(rankings, accentColor),
                          const SizedBox(height: 12),
                          buildRollupHeader(view),
                          buildRankingsCardOrEmpty(view, accentColor),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 24),
                ],
              );
              if (!isDesktop) return stackedList;
              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: stackedList,
                ),
              );
            }(),
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
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 128),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Text(
                          '¥${formatMinor(item.moneyMinor)}',
                          maxLines: 1,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
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
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
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
    final isDesktop = DesktopAdaptive.isDesktop(context);
    final isPopupModal = isDesktop && ModalRoute.of(context) is PopupRoute;

    void openSiblingTag(String targetTagId) {
      if (GoRouter.maybeOf(context) != null &&
          ModalRoute.of(context)?.settings is Page) {
        context.push('/stats/tag/$targetTagId');
      } else {
        pushDesktopModalOrMaterialRoute<void>(
          context,
          maxWidth: 860,
          maxHeight: 720,
          barrierDismissible: true,
          child: TagDetailStatsPage(tagId: targetTagId),
        );
      }
    }

    return Scaffold(
      key: const Key('tag-detail-stats-page'),
      appBar: AppBar(
        leading: isPopupModal ? const CloseButton() : null,
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
          final isDark = theme.brightness == Brightness.dark;
          final isExpandedDesktop = DesktopAdaptive.isExpandedDesktop(context);
          final semanticIncomeColor = isDark
              ? Colors.green.shade300
              : Colors.green.shade700;
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

          Widget? groupOrParentBadge;
          if (stats.isGroup) {
            groupOrParentBadge = Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '标签组 · 含 ${stats.childTags.length} 个子标签',
                key: const Key('tag-detail-group-badge'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSecondaryContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
            );
          } else if (stats.parentTag != null) {
            groupOrParentBadge = ActionChip(
              key: Key('tag-detail-parent-chip-${stats.parentTag!.tagId}'),
              visualDensity: VisualDensity.compact,
              avatar: TagColorDot(colorHex: stats.parentTag!.color, size: 8),
              label: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: (MediaQuery.sizeOf(context).width - 96).clamp(
                    140.0,
                    320.0,
                  ),
                ),
                child: Text(
                  '所属标签组：#${stats.parentTag!.name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              onPressed: () => openSiblingTag(stats.parentTag!.tagId),
            );
          }

          Widget buildPeriodSelector({bool compactDesktop = false}) {
            return _TagPeriodSelectorBar(
              keyPrefix: 'tag-detail',
              mode: _periodMode,
              period: data.period,
              compactDesktop: compactDesktop,
              onModeChanged: (m) => setState(() {
                _periodMode = m;
                _periodOffset = 0;
              }),
              onPrevious: () => setState(() => _periodOffset--),
              onNext: () => setState(() => _periodOffset++),
            );
          }

          final summaryCard = Card(
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
                      const SizedBox(width: 12),
                      Expanded(
                        child: _MetricTile(
                          label: '总收入',
                          value: '¥${formatMinor(stats.totalIncome)}',
                          valueKey: const Key('tag-detail-total-income'),
                          valueColor: semanticIncomeColor,
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
                      const SizedBox(width: 12),
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
          );

          final childrenCard =
              (stats.isGroup && stats.childBreakdowns.isNotEmpty)
              ? Card(
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
                                    : () => openSiblingTag(child.tagId),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                )
              : null;

          final categoryCard =
              (stats.expenseCategories.isNotEmpty ||
                  stats.incomeCategories.isNotEmpty)
              ? Card(
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
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    '分类构成',
                                    maxLines: 1,
                                    softWrap: false,
                                    style: theme.textTheme.titleSmall?.copyWith(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            SegmentedButton<StatBucket>(
                              key: const Key('tag-detail-cat-bucket-switch'),
                              showSelectedIcon: false,
                              style: const ButtonStyle(
                                visualDensity: VisualDensity.compact,
                                padding: WidgetStatePropertyAll(
                                  EdgeInsets.symmetric(horizontal: 8),
                                ),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              segments: const [
                                ButtonSegment(
                                  value: StatBucket.expense,
                                  label: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      '支出构成',
                                      maxLines: 1,
                                      softWrap: false,
                                    ),
                                  ),
                                ),
                                ButtonSegment(
                                  value: StatBucket.income,
                                  label: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      '收入构成',
                                      maxLines: 1,
                                      softWrap: false,
                                    ),
                                  ),
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
                            const SizedBox(width: 4),
                            IconButton(
                              key: const Key('tag-detail-cat-expand-btn'),
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 32,
                                minHeight: 32,
                              ),
                              style: IconButton.styleFrom(
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
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
                                            ConstrainedBox(
                                              constraints: const BoxConstraints(
                                                maxWidth: 140,
                                              ),
                                              child: FittedBox(
                                                fit: BoxFit.scaleDown,
                                                alignment:
                                                    Alignment.centerRight,
                                                child: Text(
                                                  '¥${formatMinor(cat.moneyMinor)} (${cat.ratioText})',
                                                  maxLines: 1,
                                                  style: theme
                                                      .textTheme
                                                      .bodySmall
                                                      ?.copyWith(
                                                        fontWeight:
                                                            FontWeight.w600,
                                                      ),
                                                ),
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
                                            backgroundColor: theme
                                                .colorScheme
                                                .surfaceContainerHighest,
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
                )
              : null;

          final billsSectionWidgets = <Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                '关联账单明细 (${data.matchingRecords.length} 笔)',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
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
          ];

          if (isExpandedDesktop) {
            return Column(
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1360),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          if (groupOrParentBadge != null) ...[
                            Flexible(child: groupOrParentBadge),
                            const SizedBox(width: 16),
                          ],
                          Expanded(
                            child: buildPeriodSelector(compactDesktop: true),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1360),
                      child: Row(
                        key: const Key('tag-detail-desktop-split'),
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            flex: 45,
                            child: ListView(
                              padding: const EdgeInsets.fromLTRB(
                                20,
                                14,
                                12,
                                24,
                              ),
                              children: [
                                summaryCard,
                                if (childrenCard != null) ...[
                                  const SizedBox(height: 12),
                                  childrenCard,
                                ],
                                if (categoryCard != null) ...[
                                  const SizedBox(height: 12),
                                  categoryCard,
                                ],
                              ],
                            ),
                          ),
                          const VerticalDivider(width: 1),
                          Expanded(
                            flex: 55,
                            child: ListView(
                              padding: const EdgeInsets.fromLTRB(
                                12,
                                14,
                                20,
                                24,
                              ),
                              children: billsSectionWidgets,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            );
          }

          final stackedDetailList = ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            children: [
              // Group or parent badge banner
              if (stats.isGroup)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(children: [Flexible(child: groupOrParentBadge!)]),
                )
              else if (stats.parentTag != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: groupOrParentBadge,
                  ),
                ),

              // 1. Period Selector (全部 | 按月 | 按年, defaults to 全部)
              buildPeriodSelector(),
              const SizedBox(height: 12),

              // 2. Summary Card: 总支出, 总收入, 结余, 关联账单数
              summaryCard,
              const SizedBox(height: 12),

              // 3. Child-tag Breakdown Chips (if parent tag group with children)
              if (childrenCard != null) ...[
                childrenCard,
                const SizedBox(height: 12),
              ],

              // 4. Collapsible Category Breakdown Section (支出构成 / 收入构成)
              if (categoryCard != null) ...[
                categoryCard,
                const SizedBox(height: 12),
              ],

              // 5. Associated Bills List grouped by YYYY-MM-DD
              ...billsSectionWidgets,
              const SizedBox(height: 24),
            ],
          );

          if (!isDesktop) return stackedDetailList;
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: stackedDetailList,
            ),
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
    final isDark = theme.brightness == Brightness.dark;
    final incomeColor = isDark ? Colors.green.shade300 : Colors.green.shade700;
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
                color: theme.colorScheme.onSurfaceVariant,
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
            title: Text(
              label.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: subtitleParts.isEmpty
                ? null
                : Text(
                    subtitleParts.join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
            trailing: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 120),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Text(
                  label.amount,
                  maxLines: 1,
                  style: TextStyle(
                    color: r.type == RecordType.income ? incomeColor : null,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            onTap: () {
              if (GoRouter.maybeOf(context) != null &&
                  ModalRoute.of(context)?.settings is Page) {
                try {
                  context.push('/record/${r.recordId}');
                  return;
                } catch (_) {}
              }
              pushDesktopModalOrMaterialRoute<void>(
                context,
                maxWidth: 560,
                maxHeight: 740,
                barrierDismissible: true,
                child: RecordDetailPage(recordId: r.recordId),
              );
            },
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
    this.compactDesktop = false,
  });

  final String keyPrefix;
  final TagStatsPeriodMode mode;
  final BillingPeriod? period;
  final ValueChanged<TagStatsPeriodMode> onModeChanged;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final bool compactDesktop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = formatTagStatsPeriodLabel(mode, period);

    final modeChips = Wrap(
      spacing: 8,
      runSpacing: 4,
      alignment: WrapAlignment.center,
      children: [
        ChoiceChip(
          key: Key('$keyPrefix-mode-all'),
          label: const Text('全部'),
          selected: mode == TagStatsPeriodMode.all,
          onSelected: (sel) {
            if (sel) onModeChanged(TagStatsPeriodMode.all);
          },
        ),
        ChoiceChip(
          key: Key('$keyPrefix-mode-month'),
          label: const Text('按月'),
          selected: mode == TagStatsPeriodMode.month,
          onSelected: (sel) {
            if (sel) onModeChanged(TagStatsPeriodMode.month);
          },
        ),
        ChoiceChip(
          key: Key('$keyPrefix-mode-year'),
          label: const Text('按年'),
          selected: mode == TagStatsPeriodMode.year,
          onSelected: (sel) {
            if (sel) onModeChanged(TagStatsPeriodMode.year);
          },
        ),
      ],
    );

    final periodNavRow = mode != TagStatsPeriodMode.all
        ? Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                key: Key('$keyPrefix-prev-period'),
                tooltip: '上一周期',
                icon: const Icon(Icons.chevron_left),
                onPressed: onPrevious,
              ),
              Expanded(
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      label,
                      key: Key('$keyPrefix-period-label'),
                      maxLines: 1,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
              IconButton(
                key: Key('$keyPrefix-next-period'),
                tooltip: '下一周期',
                icon: const Icon(Icons.chevron_right),
                onPressed: onNext,
              ),
            ],
          )
        : null;

    if (compactDesktop) {
      return Row(
        children: [
          modeChips,
          if (periodNavRow != null) ...[
            const SizedBox(width: 16),
            Expanded(child: periodNavRow),
          ] else
            const Spacer(),
        ],
      );
    }

    return Column(
      children: [
        modeChips,
        if (periodNavRow != null) ...[const SizedBox(height: 4), periodNavRow],
      ],
    );
  }
}

class _TagProportionOverviewCard extends StatelessWidget {
  const _TagProportionOverviewCard({
    required this.rankings,
    required this.fallbackColor,
  });

  final TagRankingsResult rankings;
  final Color fallbackColor;

  static const _palette = <Color>[
    Color(0xFF1E88E5),
    Color(0xFFE53935),
    Color(0xFF43A047),
    Color(0xFF8E24AA),
    Color(0xFFFB8C00),
    Color(0xFF00ACC1),
    Color(0xFF5E35B1),
    Color(0xFF6D4C41),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isExpense = rankings.bucket == StatBucket.expense;
    final items = rankings.items
        .where((e) => e.moneyMinor > BigInt.zero)
        .toList();
    var totalSliceMinor = BigInt.zero;
    for (final item in items) {
      totalSliceMinor += item.moneyMinor;
    }

    final colors = <Color>[
      for (var i = 0; i < items.length; i++)
        parseTagColor(items[i].color) ?? _palette[i % _palette.length],
    ];

    final donut = SizedBox(
      width: 148,
      height: 148,
      child: CustomPaint(
        painter: _TagDonutPainter(
          items: items,
          colors: colors,
          totalSliceMinor: totalSliceMinor,
          centerLabel: isExpense ? '总支出' : '总收入',
          centerAmount: '¥${formatMinor(rankings.totalMinor)}',
          textColor: theme.colorScheme.onSurface,
          trackColor: theme.colorScheme.surfaceContainerHighest,
        ),
      ),
    );

    final top5 = items.take(5).toList();

    return Card(
      key: const Key('tag-rankings-donut-card'),
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '标签占比概览',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Center(
                  child: Text(
                    '暂无活跃标签占比数据',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              )
            else
              LayoutBuilder(
                builder: (context, constraints) {
                  final legend = Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < top5.length; i++)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Container(
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(
                                  color: colors[i],
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  '#${top5[i].name} · ${top5[i].ratioText}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  );
                  if (constraints.maxWidth >= 330) {
                    return Row(
                      children: [
                        donut,
                        const SizedBox(width: 16),
                        Expanded(child: legend),
                      ],
                    );
                  }
                  return Column(
                    children: [
                      Center(child: donut),
                      const SizedBox(height: 12),
                      legend,
                    ],
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _TagDonutPainter extends CustomPainter {
  const _TagDonutPainter({
    required this.items,
    required this.colors,
    required this.totalSliceMinor,
    required this.centerLabel,
    required this.centerAmount,
    required this.textColor,
    required this.trackColor,
  });

  final List<TagRankingItem> items;
  final List<Color> colors;
  final BigInt totalSliceMinor;
  final String centerLabel;
  final String centerAmount;
  final Color textColor;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 12;
    const strokeWidth = 20.0;

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..color = trackColor,
    );

    if (items.isNotEmpty && totalSliceMinor > BigInt.zero) {
      if (items.length == 1) {
        canvas.drawCircle(
          center,
          radius,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = strokeWidth
            ..color = colors.first,
        );
      } else {
        var startAngle = -math.pi / 2;
        var consumedBp = 0;
        for (var i = 0; i < items.length; i++) {
          final bp = i == items.length - 1
              ? (10000 - consumedBp).clamp(0, 10000)
              : ((items[i].moneyMinor * BigInt.from(10000)) ~/ totalSliceMinor)
                    .toInt()
                    .clamp(0, 10000);
          consumedBp += bp;
          if (bp <= 0) continue;
          final sweep = 2 * math.pi * (bp / 10000.0);
          canvas.drawArc(
            Rect.fromCircle(center: center, radius: radius),
            startAngle,
            sweep,
            false,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = strokeWidth
              ..color = colors[i],
          );
          startAngle += sweep;
        }
      }
    }

    final tp = TextPainter(
      text: TextSpan(
        children: [
          TextSpan(
            text: '$centerLabel\n',
            style: TextStyle(
              color: textColor.withValues(alpha: 0.7),
              fontSize: 11,
            ),
          ),
          TextSpan(
            text: centerAmount,
            style: TextStyle(
              color: textColor,
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: math.max(40, size.width - 52));

    tp.paint(
      canvas,
      Offset(center.dx - tp.width / 2, center.dy - tp.height / 2),
    );
  }

  @override
  bool shouldRepaint(covariant _TagDonutPainter oldDelegate) {
    return oldDelegate.items != items ||
        oldDelegate.centerAmount != centerAmount ||
        oldDelegate.textColor != textColor;
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
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            key: valueKey,
            maxLines: 1,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: valueColor,
            ),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
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
      backgroundColor: tint?.withValues(alpha: isDark ? 0.20 : 0.12),
      side: tint == null
          ? null
          : BorderSide(color: tint.withValues(alpha: 0.45)),
      label: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: (MediaQuery.sizeOf(context).width - 104).clamp(
            140.0,
            320.0,
          ),
        ),
        child: Text(
          '#${item.name} · ${item.billCount} 笔 · $amountLabel',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      onPressed: onTap,
    );
  }
}
