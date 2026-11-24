import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/adaptive.dart';
import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/billing_period.dart';
import '../../domain/rules/category_stats.dart';
import '../common/catalog_icons.dart';
import '../common/common.dart';
import '../common/desktop_modal_page.dart';
import '../common/year_month_picker_dialog.dart';
import '../records/record_detail_page.dart';
import 'category_stats_providers.dart';

/// Main category statistics page (F-008 / SCR-005, original `/anz/ADAct`).
class CategoryStatsPage extends ConsumerStatefulWidget {
  const CategoryStatsPage({super.key});

  @override
  ConsumerState<CategoryStatsPage> createState() => _CategoryStatsPageState();
}

class _CategoryStatsPageState extends ConsumerState<CategoryStatsPage> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ref.read(categoryStatsRangeKindProvider) == StatRangeKind.custom) {
        ref
            .read(categoryStatsRangeKindProvider.notifier)
            .setRangeKind(StatRangeKind.month);
      }
      if (ref.read(categoryStatsOffsetProvider) != 0) {
        ref.read(categoryStatsOffsetProvider.notifier).reset();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final dimension = ref.watch(categoryStatsDimensionProvider);
    final rangeKind = ref.watch(categoryStatsRangeKindProvider);
    final isFlatten = ref.watch(categoryStatsFlattenProvider);
    final smoothing = ref.watch(categoryStatsOutlierSmoothingProvider);
    final periodAsync = ref.watch(categoryStatsActivePeriodProvider);
    final resultAsync = ref.watch(categoryStatsResultProvider);

    final theme = Theme.of(context);
    final isDesktop = DesktopAdaptive.isDesktop(context);
    final isExpandedDesktop = DesktopAdaptive.isExpandedDesktop(context);

    final dimensionSwitch = SegmentedButton<StatDimension>(
      key: const Key('stat-dimension-switch'),
      showSelectedIcon: false,
      style: const ButtonStyle(
        visualDensity: VisualDensity.compact,
        padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      segments: const [
        ButtonSegment(
          value: StatDimension.expense,
          label: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text('支出', maxLines: 1, softWrap: false),
          ),
          icon: Icon(Icons.arrow_upward, size: 18),
        ),
        ButtonSegment(
          value: StatDimension.income,
          label: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text('收入', maxLines: 1, softWrap: false),
          ),
          icon: Icon(Icons.arrow_downward, size: 18),
        ),
      ],
      selected: {dimension},
      onSelectionChanged: (set) {
        if (set.isNotEmpty) {
          ref
              .read(categoryStatsDimensionProvider.notifier)
              .setDimension(set.first);
        }
      },
    );

    final headerSummaryWidget = resultAsync.when(
      data: (res) => _HeaderSummaryCard(result: res),
      loading: () => const Card(
        child: SizedBox(
          height: 100,
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
      error: (e, _) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('加载统计失败: $e'),
        ),
      ),
    );

    final trendChartWidget = resultAsync.when(
      data: (res) => _TrendChartCard(
        buckets: res.trendBuckets,
        smoothing: smoothing,
        dimension: dimension,
      ),
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
    );

    final rankingsWidget = resultAsync.when(
      data: (res) => _CategoryRankingsCard(result: res, isFlatten: isFlatten),
      loading: () => const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: CircularProgressIndicator(),
        ),
      ),
      error: (e, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('加载分类排行失败: $e'),
        ),
      ),
    );

    return Scaffold(
      key: _scaffoldKey,
      drawerEdgeDragWidth: 0,
      endDrawerEnableOpenDragGesture: false,
      appBar: AppBar(
        title: const Text('分类统计'),
        actions: [
          IconButton(
            key: const Key('category-stats-iqr-toggle'),
            tooltip: smoothing == OutlierSmoothing.none
                ? '开启异常峰值平滑 (Tukey IQR)'
                : '关闭异常峰值平滑',
            icon: Icon(
              smoothing == OutlierSmoothing.none
                  ? Icons.auto_graph_outlined
                  : Icons.auto_graph,
              color: smoothing != OutlierSmoothing.none
                  ? theme.colorScheme.primary
                  : null,
            ),
            onPressed: () {
              ref.read(categoryStatsOutlierSmoothingProvider.notifier).toggle();
            },
          ),
          IconButton(
            key: const Key('category-stats-filter-button'),
            tooltip: '多维筛选',
            icon: const Icon(Icons.tune),
            onPressed: () => _openFilterDrawer(context),
          ),
        ],
      ),
      endDrawer: const _CategoryStatsFilterDrawer(),
      body: isExpandedDesktop
          ? Column(
              children: [
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1440),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          SizedBox(width: 210, child: dimensionSwitch),
                          const SizedBox(width: 20),
                          Expanded(
                            child: _PeriodNavigationBar(
                              rangeKind: rangeKind,
                              periodAsync: periodAsync,
                              compactDesktop: true,
                            ),
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
                      constraints: const BoxConstraints(maxWidth: 1440),
                      child: Row(
                        key: const Key('category-stats-desktop-split'),
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            flex: 46,
                            child: ListView(
                              key: const Key('category-stats-left-pane'),
                              padding: const EdgeInsets.fromLTRB(
                                20,
                                14,
                                10,
                                24,
                              ),
                              children: [
                                Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    headerSummaryWidget,
                                    const SizedBox(height: 16),
                                    resultAsync.when(
                                      data: (res) => _CategoryDonutChartCard(
                                        key: const Key(
                                          'category-stats-donut-card',
                                        ),
                                        result: res,
                                        isFlatten: isFlatten,
                                      ),
                                      loading: () => const SizedBox.shrink(),
                                      error: (_, _) => const SizedBox.shrink(),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 16),
                                trendChartWidget,
                              ],
                            ),
                          ),
                          const VerticalDivider(width: 1),
                          Expanded(
                            flex: 54,
                            child: ListView(
                              key: const Key('category-stats-right-pane'),
                              padding: const EdgeInsets.fromLTRB(
                                10,
                                14,
                                20,
                                24,
                              ),
                              children: [rankingsWidget],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            )
          : () {
              final stackedList = ListView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 1. Dimension Switch: Expense / Income
                      SizedBox(width: double.infinity, child: dimensionSwitch),
                      const SizedBox(height: 12),

                      // 2. Period Navigation Bar
                      _PeriodNavigationBar(
                        rangeKind: rangeKind,
                        periodAsync: periodAsync,
                      ),
                      const SizedBox(height: 12),

                      // 3. Header Summary Card
                      headerSummaryWidget,
                    ],
                  ),
                  const SizedBox(height: 16),

                  // 4. Trend Line Chart
                  trendChartWidget,
                  const SizedBox(height: 16),

                  // 5. Category Rankings Card
                  rankingsWidget,
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

  void _openFilterDrawer(BuildContext context) {
    _scaffoldKey.currentState?.openEndDrawer();
  }
}

/// Period navigation bar with Month/Year/Custom switches and previous/next buttons.
class _PeriodNavigationBar extends ConsumerWidget {
  const _PeriodNavigationBar({
    required this.rangeKind,
    required this.periodAsync,
    this.compactDesktop = false,
  });

  final StatRangeKind rangeKind;
  final AsyncValue<BillingPeriod> periodAsync;
  final bool compactDesktop;

  Future<void> _onTapPeriodLabel(
    BuildContext context,
    WidgetRef ref,
    int startDay,
  ) async {
    final now = DateTime.now();
    if (rangeKind == StatRangeKind.custom) {
      final current = periodAsync.value;
      final picked = await showDateRangePicker(
        context: context,
        firstDate: DateTime(2000),
        lastDate: DateTime(2100),
        initialDateRange: current != null
            ? DateTimeRange(start: current.start, end: current.end)
            : DateTimeRange(
                start: now.subtract(const Duration(days: 30)),
                end: now,
              ),
      );
      if (picked != null && context.mounted) {
        ref
            .read(categoryStatsCustomRangeProvider.notifier)
            .setRange(picked.start, picked.end);
      }
      return;
    }

    if (rangeKind == StatRangeKind.year) {
      final activeYearPeriod = BillingPeriod.containingYear(now, startDay);
      final current = periodAsync.value ?? activeYearPeriod;
      final pickedYear = await showYearOnlyPickerDialog(
        context,
        initialYear: current.year,
        currentYear: activeYearPeriod.year,
      );
      if (pickedYear == null || !context.mounted) return;
      final curYear = BillingPeriod.containingYear(
        DateTime.now(),
        startDay,
      ).year;
      ref
          .read(categoryStatsOffsetProvider.notifier)
          .setOffset(pickedYear - curYear);
      return;
    }

    final activeMonthPeriod = BillingPeriod.containing(now, startDay);
    final current = periodAsync.value ?? activeMonthPeriod;
    final picked = await showYearMonthPickerDialog(
      context,
      initialYear: current.year,
      initialMonth: current.month,
      currentYear: activeMonthPeriod.year,
      currentMonth: activeMonthPeriod.month,
    );
    if (picked == null || !context.mounted) return;
    final nowPeriod = BillingPeriod.containing(DateTime.now(), startDay);
    final newOffset =
        (picked.year - nowPeriod.year) * 12 + (picked.month - nowPeriod.month);
    ref.read(categoryStatsOffsetProvider.notifier).setOffset(newOffset);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final offset = ref.watch(categoryStatsOffsetProvider);
    final startDay = ref.watch(currentBookProvider).value?.startDay ?? 1;

    String label = '加载中…';
    periodAsync.whenData((p) {
      if (rangeKind == StatRangeKind.month) {
        label = '${p.year}年${p.month}月';
      } else if (rangeKind == StatRangeKind.year) {
        label = '${p.year}年';
      } else {
        label =
            '${formatDate(p.start)} ~ ${formatDate(p.end)} (${p.totalDays}天)';
      }
    });

    final granularityChips = Wrap(
      spacing: 8,
      runSpacing: 4,
      alignment: WrapAlignment.center,
      children: [
        ChoiceChip(
          key: const Key('period-kind-month'),
          label: const Text('按月'),
          selected: rangeKind == StatRangeKind.month,
          onSelected: (selected) {
            if (selected) {
              ref
                  .read(categoryStatsRangeKindProvider.notifier)
                  .setRangeKind(StatRangeKind.month);
              ref.read(categoryStatsOffsetProvider.notifier).reset();
            }
          },
        ),
        ChoiceChip(
          key: const Key('period-kind-year'),
          label: const Text('按年'),
          selected: rangeKind == StatRangeKind.year,
          onSelected: (selected) {
            if (selected) {
              ref
                  .read(categoryStatsRangeKindProvider.notifier)
                  .setRangeKind(StatRangeKind.year);
              ref.read(categoryStatsOffsetProvider.notifier).reset();
            }
          },
        ),
        ChoiceChip(
          key: const Key('period-kind-custom'),
          label: const Text('自定义'),
          selected: rangeKind == StatRangeKind.custom,
          onSelected: (selected) async {
            if (selected) {
              final now = DateTime.now();
              final picked = await showDateRangePicker(
                context: context,
                firstDate: DateTime(2000),
                lastDate: DateTime(2100),
                initialDateRange: DateTimeRange(
                  start: now.subtract(const Duration(days: 30)),
                  end: now,
                ),
              );
              if (picked != null && context.mounted) {
                ref
                    .read(categoryStatsRangeKindProvider.notifier)
                    .setRangeKind(StatRangeKind.custom);
                ref
                    .read(categoryStatsCustomRangeProvider.notifier)
                    .setRange(picked.start, picked.end);
              }
            }
          },
        ),
      ],
    );

    final showResetPill = rangeKind != StatRangeKind.custom && offset != 0;

    final periodSwitcherRow = Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        IconButton(
          key: const Key('period-prev-button'),
          tooltip: '上一周期',
          icon: const Icon(Icons.chevron_left),
          onPressed: rangeKind == StatRangeKind.custom
              ? null
              : () {
                  ref.read(categoryStatsOffsetProvider.notifier).previous();
                },
        ),
        Expanded(
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: InkWell(
                    key: const Key('category-stats-period-picker-trigger'),
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => _onTapPeriodLabel(context, ref, startDay),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 4,
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          label,
                          maxLines: 1,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (showResetPill) ...[
                  const SizedBox(width: 6),
                  PeriodResetPill(
                    key: const Key('category-stats-period-reset'),
                    label: rangeKind == StatRangeKind.year ? '回本年' : '回本月',
                    onTap: () =>
                        ref.read(categoryStatsOffsetProvider.notifier).reset(),
                  ),
                ],
              ],
            ),
          ),
        ),
        IconButton(
          key: const Key('period-next-button'),
          tooltip: '下一周期',
          icon: const Icon(Icons.chevron_right),
          onPressed: rangeKind == StatRangeKind.custom
              ? null
              : () {
                  ref.read(categoryStatsOffsetProvider.notifier).next();
                },
        ),
      ],
    );

    if (compactDesktop) {
      return Row(
        children: [
          granularityChips,
          const SizedBox(width: 16),
          Expanded(child: periodSwitcherRow),
        ],
      );
    }

    return Column(
      children: [
        granularityChips,
        const SizedBox(height: 8),
        periodSwitcherRow,
      ],
    );
  }
}

/// Header summary card showing Total, Daily Average, Count, and Trend.
class _HeaderSummaryCard extends StatelessWidget {
  const _HeaderSummaryCard({required this.result});

  final CategoryStatsResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final isExpense = result.dimension == StatDimension.expense;

    final String growthText;
    final Color? growthColor;
    if (result.growthBasisPoints != null) {
      final bp = result.growthBasisPoints!;
      if (bp > 0) {
        growthText = '+${(bp / 100.0).toStringAsFixed(1)}%';
        growthColor = isDark ? Colors.red.shade300 : Colors.red.shade700;
      } else if (bp < 0) {
        growthText = '${(bp / 100.0).toStringAsFixed(1)}%';
        growthColor = isDark ? Colors.green.shade300 : Colors.green.shade700;
      } else {
        growthText = '0.0%';
        growthColor = theme.colorScheme.onSurfaceVariant;
      }
    } else {
      growthText = '--';
      growthColor = null;
    }

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isExpense ? '总支出' : '总收入',
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
                          '¥${formatMinor(result.headerTotalMinor)}',
                          key: const Key('header-total-amount'),
                          maxLines: 1,
                          style: theme.textTheme.headlineMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: isExpense
                                ? theme.colorScheme.error
                                : theme.colorScheme.primary,
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
                      Text(
                        '环比变化',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Text(
                          growthText,
                          key: const Key('header-growth-text'),
                          maxLines: 1,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: growthColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            Row(
              children: [
                Expanded(
                  child: Column(
                    children: [
                      Text(
                        '日均金额',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 2),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          '¥${formatMinor(result.dailyAverageMinor)}',
                          key: const Key('header-daily-average'),
                          maxLines: 1,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    children: [
                      Text(
                        '交易笔数',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 2),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          '${result.headerCount} 笔',
                          key: const Key('header-total-count'),
                          maxLines: 1,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    children: [
                      Text(
                        '已过天数',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 2),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          '${result.elapsedDays} 天',
                          maxLines: 1,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Donut proportion chart card rendered on desktop widescreen left pane.
class _CategoryDonutChartCard extends ConsumerWidget {
  const _CategoryDonutChartCard({
    super.key,
    required this.result,
    required this.isFlatten,
  });

  final CategoryStatsResult result;
  final bool isFlatten;

  static const _fallbackPalette = <Color>[
    Color(0xFF3F51B5),
    Color(0xFF009688),
    Color(0xFFFF9800),
    Color(0xFFE91E63),
    Color(0xFF2196F3),
    Color(0xFF8BC34A),
    Color(0xFF9C27B0),
    Color(0xFF795548),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isExpense = result.dimension == StatDimension.expense;
    final catType = isExpense ? RecordType.expense : RecordType.income;
    final bookId = ref.watch(currentBookIdProvider).value ?? 1;
    final categories =
        ref.watch(categoriesProvider(bookId)).value ?? const <RecordCategory>[];
    final catById = <int, RecordCategory>{for (final c in categories) c.id: c};

    final rows = isFlatten ? result.flattenRows : result.firstLevelRows;
    final slices = <_CategoryDonutSlice>[];
    var totalSliceMinor = BigInt.zero;

    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      if (r.moneyMinor <= BigInt.zero) continue;
      final dbCat = catById[r.categoryId];
      final parentCat = (dbCat != null && dbCat.parentCatId != noRef)
          ? catById[dbCat.parentCatId]
          : (r.parentCatId != -1 ? catById[r.parentCatId] : null);
      final catIcon = (dbCat?.icon != null && dbCat!.icon.trim().isNotEmpty)
          ? dbCat.icon
          : (r.icon.isNotEmpty ? r.icon : null);
      final catColor =
          (dbCat?.colorFill != null && dbCat!.colorFill!.trim().isNotEmpty)
          ? dbCat.colorFill
          : parentCat?.colorFill;
      var color = resolveCategoryVisual(
        iconKey: catIcon,
        parentIconKey: parentCat?.icon,
        colorHex: catColor,
        name: r.name,
        type: catType,
      ).color;
      if (slices.isNotEmpty && slices.last.color == color) {
        color = _fallbackPalette[i % _fallbackPalette.length];
      }
      totalSliceMinor += r.moneyMinor;
      slices.add(
        _CategoryDonutSlice(
          name: r.name,
          moneyMinor: r.moneyMinor,
          ratioText: r.ratioText,
          color: color,
        ),
      );
    }

    final uncat = result.uncategorizedRow;
    if (!isFlatten &&
        uncat != null &&
        uncat.count > 0 &&
        uncat.moneyMinor > BigInt.zero) {
      totalSliceMinor += uncat.moneyMinor;
      slices.add(
        _CategoryDonutSlice(
          name: uncat.name,
          moneyMinor: uncat.moneyMinor,
          ratioText: uncat.ratioText,
          color: theme.colorScheme.outline,
        ),
      );
    }

    final donutBox = SizedBox(
      width: 152,
      height: 152,
      child: CustomPaint(
        painter: _CategoryDonutPainter(
          slices: slices,
          totalSliceMinor: totalSliceMinor,
          centerLabel: isExpense ? '总支出' : '总收入',
          centerAmountText: '¥${formatMinor(result.headerTotalMinor)}',
          textColor: theme.colorScheme.onSurface,
          trackColor: theme.colorScheme.surfaceContainerHighest,
        ),
      ),
    );

    final topLegend = slices.take(5).toList();

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '分类占比分布',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            if (slices.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 20),
                child: Center(
                  child: Text(
                    '暂无分类占比数据',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              )
            else
              LayoutBuilder(
                builder: (context, constraints) {
                  final legendColumn = Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final s in topLegend)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Container(
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(
                                  color: s.color,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  '${s.name} · ${s.ratioText}',
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
                      if (slices.length > topLegend.length)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            '其余 ${slices.length - topLegend.length} 项见右侧列表',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  );

                  if (constraints.maxWidth >= 340) {
                    return Row(
                      children: [
                        donutBox,
                        const SizedBox(width: 16),
                        Expanded(child: legendColumn),
                      ],
                    );
                  }
                  return Column(
                    children: [
                      Center(child: donutBox),
                      const SizedBox(height: 12),
                      legendColumn,
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

class _CategoryDonutSlice {
  const _CategoryDonutSlice({
    required this.name,
    required this.moneyMinor,
    required this.ratioText,
    required this.color,
  });

  final String name;
  final BigInt moneyMinor;
  final String ratioText;
  final Color color;
}

class _CategoryDonutPainter extends CustomPainter {
  const _CategoryDonutPainter({
    required this.slices,
    required this.totalSliceMinor,
    required this.centerLabel,
    required this.centerAmountText,
    required this.textColor,
    required this.trackColor,
  });

  final List<_CategoryDonutSlice> slices;
  final BigInt totalSliceMinor;
  final String centerLabel;
  final String centerAmountText;
  final Color textColor;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 12;
    const strokeWidth = 22.0;

    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..color = trackColor;
    canvas.drawCircle(center, radius, trackPaint);

    if (slices.isNotEmpty && totalSliceMinor > BigInt.zero) {
      if (slices.length == 1) {
        final singlePaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..color = slices.first.color;
        canvas.drawCircle(center, radius, singlePaint);
      } else {
        var startAngle = -math.pi / 2;
        var consumedBp = 0;
        for (var i = 0; i < slices.length; i++) {
          final slice = slices[i];
          final bp = i == slices.length - 1
              ? (10000 - consumedBp).clamp(0, 10000)
              : ((slice.moneyMinor * BigInt.from(10000)) ~/ totalSliceMinor)
                    .toInt()
                    .clamp(0, 10000);
          consumedBp += bp;
          if (bp <= 0) continue;
          final sweepAngle = 2 * math.pi * (bp / 10000.0);
          final arcPaint = Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = strokeWidth
            ..color = slice.color;
          canvas.drawArc(
            Rect.fromCircle(center: center, radius: radius),
            startAngle,
            sweepAngle,
            false,
            arcPaint,
          );
          startAngle += sweepAngle;
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
            text: centerAmountText,
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
    )..layout(maxWidth: math.max(40, size.width - 56));

    tp.paint(
      canvas,
      Offset(center.dx - tp.width / 2, center.dy - tp.height / 2),
    );
  }

  @override
  bool shouldRepaint(covariant _CategoryDonutPainter oldDelegate) {
    return oldDelegate.slices != slices ||
        oldDelegate.totalSliceMinor != totalSliceMinor ||
        oldDelegate.centerAmountText != centerAmountText ||
        oldDelegate.textColor != textColor;
  }
}

/// Trend line chart card rendered using Flutter's native [CustomPaint].
class _TrendChartCard extends StatefulWidget {
  const _TrendChartCard({
    required this.buckets,
    required this.smoothing,
    required this.dimension,
  });

  final List<TrendBucket> buckets;
  final OutlierSmoothing smoothing;
  final StatDimension dimension;

  @override
  State<_TrendChartCard> createState() => _TrendChartCardState();
}

class _TrendChartCardState extends State<_TrendChartCard> {
  int? _hoveredIndex;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isExpense = widget.dimension == StatDimension.expense;
    final chartColor = isExpense
        ? theme.colorScheme.error
        : theme.colorScheme.primary;

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(
                    '收支趋势',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (widget.smoothing != OutlierSmoothing.none) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        'IQR 平滑已开启',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 160,
              child: MouseRegion(
                onHover: (e) {
                  if (DesktopAdaptive.isDesktop(context)) {
                    _handleTouch(e.localPosition);
                  }
                },
                onExit: (_) {
                  if (DesktopAdaptive.isDesktop(context) &&
                      _hoveredIndex != null) {
                    setState(() => _hoveredIndex = null);
                  }
                },
                child: GestureDetector(
                  onPanDown: (d) => _handleTouch(d.localPosition),
                  onPanUpdate: (d) => _handleTouch(d.localPosition),
                  onPanEnd: (_) => setState(() => _hoveredIndex = null),
                  onTapUp: (_) => setState(() => _hoveredIndex = null),
                  child: CustomPaint(
                    size: Size.infinite,
                    painter: _TrendChartPainter(
                      buckets: widget.buckets,
                      hoveredIndex: _hoveredIndex,
                      chartColor: chartColor,
                      theme: theme,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _handleTouch(Offset localPosition) {
    if (widget.buckets.isEmpty) return;
    const paddingLeft = 32.0;
    const paddingRight = 16.0;
    final chartWidth = context.size?.width ?? 300.0;
    final usableWidth = chartWidth - paddingLeft - paddingRight;
    if (usableWidth <= 0) return;

    final x = (localPosition.dx - paddingLeft).clamp(0.0, usableWidth);
    final count = widget.buckets.length;
    if (count <= 1) {
      setState(() => _hoveredIndex = 0);
      return;
    }

    final step = usableWidth / (count - 1);
    final index = (x / step).round().clamp(0, count - 1);
    setState(() => _hoveredIndex = index);
  }
}

/// CustomPainter for the trend line chart.
class _TrendChartPainter extends CustomPainter {
  _TrendChartPainter({
    required this.buckets,
    required this.hoveredIndex,
    required this.chartColor,
    required this.theme,
  });

  final List<TrendBucket> buckets;
  final int? hoveredIndex;
  final Color chartColor;
  final ThemeData theme;

  @override
  void paint(Canvas canvas, Size size) {
    const paddingLeft = 32.0;
    const paddingRight = 16.0;
    const paddingTop = 24.0;
    const paddingBottom = 24.0;

    final w = size.width - paddingLeft - paddingRight;
    final h = size.height - paddingTop - paddingBottom;
    if (w <= 0 || h <= 0 || buckets.isEmpty) return;

    // Determine max value for vertical scaling
    var maxVal = BigInt.zero;
    for (final b in buckets) {
      if (b.displayMinor > maxVal) maxVal = b.displayMinor;
    }
    if (maxVal == BigInt.zero) maxVal = BigInt.from(100);

    final double maxValDouble = maxVal.toDouble();

    // Draw baseline / gridlines
    final gridPaint = Paint()
      ..color = theme.dividerColor.withValues(alpha: 0.4)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(paddingLeft, size.height - paddingBottom),
      Offset(size.width - paddingRight, size.height - paddingBottom),
      gridPaint,
    );

    final n = buckets.length;
    final stepX = n > 1 ? w / (n - 1) : 0.0;

    final points = <Offset>[];
    for (var i = 0; i < n; i++) {
      final x = paddingLeft + (n > 1 ? i * stepX : w / 2);
      final valRatio = (buckets[i].displayMinor.toDouble() / maxValDouble)
          .clamp(0.0, 1.0);
      final y = size.height - paddingBottom - valRatio * h;
      points.add(Offset(x, y));
    }

    // Draw filled area beneath curve
    final fillPath = Path()
      ..moveTo(points.first.dx, size.height - paddingBottom);
    for (final p in points) {
      fillPath.lineTo(p.dx, p.dy);
    }
    fillPath.lineTo(points.last.dx, size.height - paddingBottom);
    fillPath.close();

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          chartColor.withValues(alpha: 0.3),
          chartColor.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height))
      ..style = PaintingStyle.fill;
    canvas.drawPath(fillPath, fillPaint);

    // Draw line
    final linePath = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length; i++) {
      linePath.lineTo(points[i].dx, points[i].dy);
    }
    final linePaint = Paint()
      ..color = chartColor
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(linePath, linePaint);

    // Draw dots and outlier markers
    final dotPaint = Paint()..color = chartColor;
    final outlierColor = theme.brightness == Brightness.dark
        ? Colors.amber.shade400
        : Colors.amber.shade800;
    final outlierDotPaint = Paint()
      ..color = outlierColor
      ..style = PaintingStyle.fill;

    for (var i = 0; i < n; i++) {
      final p = points[i];
      if (buckets[i].isOutlier) {
        canvas.drawCircle(p, 5.0, outlierDotPaint);
        canvas.drawCircle(
          p,
          7.0,
          Paint()
            ..color = outlierColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      } else if (n <= 15) {
        canvas.drawCircle(p, 3.5, dotPaint);
      }
    }

    // Draw touch highlight cursor and tooltip bubble
    if (hoveredIndex != null &&
        hoveredIndex! >= 0 &&
        hoveredIndex! < points.length) {
      final hp = points[hoveredIndex!];
      final bucket = buckets[hoveredIndex!];

      // Vertical guide line
      final cursorPaint = Paint()
        ..color = theme.colorScheme.onSurface.withValues(alpha: 0.3)
        ..strokeWidth = 1.5;
      canvas.drawLine(
        Offset(hp.dx, paddingTop),
        Offset(hp.dx, size.height - paddingBottom),
        cursorPaint,
      );

      // Highlight circle
      canvas.drawCircle(hp, 6.0, Paint()..color = theme.colorScheme.surface);
      canvas.drawCircle(
        hp,
        6.0,
        Paint()
          ..color = chartColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );

      // Tooltip Bubble
      final textSpan = TextSpan(
        children: [
          TextSpan(
            text: '${bucket.label}\n',
            style: theme.textTheme.labelSmall?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.normal,
            ),
          ),
          TextSpan(
            text: '¥${formatMinor(bucket.actualMinor)}',
            style: theme.textTheme.labelMedium?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (bucket.isOutlier)
            const TextSpan(
              text: ' (已截顶)',
              style: TextStyle(color: Colors.amberAccent, fontSize: 10),
            ),
        ],
      );

      final tp = TextPainter(
        text: textSpan,
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout();

      final bubbleWidth = tp.width + 16;
      final bubbleHeight = tp.height + 8;
      var bx = hp.dx - bubbleWidth / 2;
      var by = hp.dy - bubbleHeight - 10;

      // Clamp bubble inside chart boundaries
      if (bx < 4) bx = 4;
      if (bx + bubbleWidth > size.width - 4) bx = size.width - bubbleWidth - 4;
      if (by < 4) by = hp.dy + 10; // Flip below if off top

      final bubbleRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(bx, by, bubbleWidth, bubbleHeight),
        const Radius.circular(8),
      );

      canvas.drawRRect(
        bubbleRect,
        Paint()..color = Colors.black.withValues(alpha: 0.8),
      );
      tp.paint(canvas, Offset(bx + 8, by + 4));
    }
  }

  @override
  bool shouldRepaint(covariant _TrendChartPainter oldDelegate) {
    return oldDelegate.buckets != buckets ||
        oldDelegate.hoveredIndex != hoveredIndex ||
        oldDelegate.chartColor != chartColor ||
        oldDelegate.theme.brightness != theme.brightness;
  }
}

/// Category rankings card supporting First-level Rollup & Second-level Flatten (F01).
class _CategoryRankingsCard extends ConsumerWidget {
  const _CategoryRankingsCard({required this.result, required this.isFlatten});

  final CategoryStatsResult result;
  final bool isFlatten;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final rows = isFlatten ? result.flattenRows : result.firstLevelRows;
    final bookId = ref.watch(currentBookIdProvider).value ?? 1;
    final categories =
        ref.watch(categoriesProvider(bookId)).value ?? const <RecordCategory>[];
    final catById = <int, RecordCategory>{for (final c in categories) c.id: c};
    final catType = result.dimension == StatDimension.income
        ? RecordType.income
        : RecordType.expense;

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(
                    '分类排行榜',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SegmentedButton<bool>(
                  key: const Key('category-view-mode-switch'),
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
                        child: Text('一级汇总', maxLines: 1, softWrap: false),
                      ),
                    ),
                    ButtonSegment(
                      value: true,
                      label: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text('二级平铺', maxLines: 1, softWrap: false),
                      ),
                    ),
                  ],
                  selected: {isFlatten},
                  onSelectionChanged: (set) {
                    if (set.isNotEmpty) {
                      ref
                          .read(categoryStatsFlattenProvider.notifier)
                          .setFlatten(set.first);
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),

            if (isFlatten)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  '平铺保留分母: ¥${formatMinor(result.flattenDenominatorMinor)} (F01)',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),

            const Divider(height: 16),

            if (rows.isEmpty && result.uncategorizedRow == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(child: Text('当前周期暂无相关分类账单')),
              )
            else ...[
              for (final row in rows)
                _CategoryRowWidget(
                  row: row,
                  isFlatten: isFlatten,
                  categoryType: catType,
                  categoriesById: catById,
                  onTap: () => _openDrilldown(context, row, catById),
                ),

              // Uncategorized fallback closing row (ASYM-CAT-01)
              if (result.uncategorizedRow != null &&
                  result.uncategorizedRow!.count > 0) ...[
                const Divider(height: 12),
                _UncategorizedRowWidget(
                  uncategorized: result.uncategorizedRow!,
                  onTap: () => _openUncategorizedDrilldown(context, catById),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  void _openDrilldown(
    BuildContext context,
    CategoryRowItem row,
    Map<int, RecordCategory> catById,
  ) {
    if (GoRouter.maybeOf(context) != null &&
        ModalRoute.of(context)?.settings is Page) {
      try {
        context.push('/stats/category/${row.categoryId}');
        return;
      } catch (_) {}
    }
    pushDesktopModalOrMaterialRoute<void>(
      context,
      maxWidth: 860,
      maxHeight: 720,
      barrierDismissible: true,
      child: CategoryDrilldownPage(
        categoryId: row.categoryId,
        categoryName: row.name,
        categoryIcon: row.icon,
        isDirectChild: row.isDirectChild,
        isFirstLevel: row.isFirstLevel,
        rowItem: row,
        result: result,
        categoriesById: catById,
      ),
    );
  }

  void _openUncategorizedDrilldown(
    BuildContext context,
    Map<int, RecordCategory> catById,
  ) {
    if (GoRouter.maybeOf(context) != null &&
        ModalRoute.of(context)?.settings is Page) {
      try {
        context.push('/stats/category/-1');
        return;
      } catch (_) {}
    }
    final uncat = result.uncategorizedRow!;
    pushDesktopModalOrMaterialRoute<void>(
      context,
      maxWidth: 860,
      maxHeight: 720,
      barrierDismissible: true,
      child: CategoryDrilldownPage(
        categoryId: -1,
        categoryName: uncat.name,
        isFirstLevel: true,
        uncategorizedRow: uncat,
        result: result,
        categoriesById: catById,
      ),
    );
  }
}

/// A single category row in the rankings card.
class _CategoryRowWidget extends StatefulWidget {
  const _CategoryRowWidget({
    required this.row,
    required this.isFlatten,
    required this.categoryType,
    required this.categoriesById,
    required this.onTap,
  });

  final CategoryRowItem row;
  final bool isFlatten;
  final int categoryType;
  final Map<int, RecordCategory> categoriesById;
  final VoidCallback onTap;

  @override
  State<_CategoryRowWidget> createState() => _CategoryRowWidgetState();
}

class _CategoryRowWidgetState extends State<_CategoryRowWidget> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final row = widget.row;
    final hasChildren = !widget.isFlatten && row.children.isNotEmpty;
    final dbCat = widget.categoriesById[row.categoryId];
    final parentCat = (dbCat != null && dbCat.parentCatId != noRef)
        ? widget.categoriesById[dbCat.parentCatId]
        : (row.parentCatId != -1
              ? widget.categoriesById[row.parentCatId]
              : null);
    final catIcon = (dbCat?.icon != null && dbCat!.icon.trim().isNotEmpty)
        ? dbCat.icon
        : (row.icon.isNotEmpty ? row.icon : null);
    final catColor =
        (dbCat?.colorFill != null && dbCat!.colorFill!.trim().isNotEmpty)
        ? dbCat.colorFill
        : parentCat?.colorFill;
    final visual = resolveCategoryVisual(
      iconKey: catIcon,
      parentIconKey: parentCat?.icon,
      colorHex: catColor,
      name: row.name,
      type: widget.categoryType,
    );

    return Column(
      children: [
        InkWell(
          key: Key('category-row-${row.categoryId}'),
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                // Icon Avatar
                CategoryIconAvatar(
                  iconKey: catIcon,
                  parentIconKey: parentCat?.icon,
                  colorHex: catColor,
                  name: row.name,
                  type: widget.categoryType,
                  size: 36,
                ),
                const SizedBox(width: 12),

                // Name and Count
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              row.name,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (row.isDirectChild)
                            Container(
                              margin: const EdgeInsets.only(left: 4),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.secondaryContainer,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                '直属',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSecondaryContainer,
                                  fontSize: 10,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${row.count} 笔',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(width: 8),

                // Amount and Ratio
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 120),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Text(
                          '¥${formatMinor(row.moneyMinor)}',
                          maxLines: 1,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      row.ratioText,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),

                // Expand Icon for first level categories
                if (hasChildren)
                  IconButton(
                    icon: Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                    ),
                    onPressed: () => setState(() => _expanded = !_expanded),
                  )
                else
                  const SizedBox(width: 8),
              ],
            ),
          ),
        ),

        // Progress bar
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: (row.ratioBasisPoints / 10000.0).clamp(0.01, 1.0),
            minHeight: 4,
            color: visual.color,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
        ),

        // Expanded subcategories
        if (hasChildren && _expanded)
          Padding(
            padding: const EdgeInsets.only(left: 44, top: 8, bottom: 8),
            child: Column(
              children: [
                for (final child in row.children)
                  Builder(
                    builder: (context) {
                      final childDb = widget.categoriesById[child.categoryId];
                      final childIcon =
                          (childDb?.icon != null &&
                              childDb!.icon.trim().isNotEmpty)
                          ? childDb.icon
                          : (child.icon.isNotEmpty ? child.icon : null);
                      final childColor =
                          (childDb?.colorFill != null &&
                              childDb!.colorFill!.trim().isNotEmpty)
                          ? childDb.colorFill
                          : catColor;
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Flexible(
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  CategoryIconAvatar(
                                    iconKey: childIcon,
                                    parentIconKey: catIcon,
                                    colorHex: childColor,
                                    name: child.name,
                                    type: widget.categoryType,
                                    size: 22,
                                  ),
                                  const SizedBox(width: 6),
                                  Flexible(
                                    child: Text(
                                      child.name,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            fontWeight: child.isDirectChild
                                                ? FontWeight.bold
                                                : FontWeight.normal,
                                          ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    '${child.count}笔',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 136),
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerRight,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      '¥${formatMinor(child.moneyMinor)}',
                                      maxLines: 1,
                                      style: theme.textTheme.bodySmall,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      child.ratioText,
                                      maxLines: 1,
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: theme.colorScheme.primary,
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Fallback closing widget for uncategorized bills (ASYM-CAT-01).
class _UncategorizedRowWidget extends StatelessWidget {
  const _UncategorizedRowWidget({
    required this.uncategorized,
    required this.onTap,
  });

  final UncategorizedRowItem uncategorized;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      key: const Key('category-row-uncategorized'),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.3,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              foregroundColor: theme.colorScheme.onSurfaceVariant,
              child: const Icon(Icons.help_outline, size: 16),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          uncategorized.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '兜底闭合',
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontSize: 9,
                            color: theme.colorScheme.onSecondaryContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                  Text(
                    '${uncategorized.count} 笔',
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
                  constraints: const BoxConstraints(maxWidth: 120),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Text(
                      '¥${formatMinor(uncategorized.moneyMinor)}',
                      maxLines: 1,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 120),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Text(
                      '头卡占比 ${uncategorized.ratioText}',
                      maxLines: 1,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
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
      ),
    );
  }
}

/// Filter drawer supporting multi-dimensional selection.
class _CategoryStatsFilterDrawer extends ConsumerStatefulWidget {
  const _CategoryStatsFilterDrawer();

  @override
  ConsumerState<_CategoryStatsFilterDrawer> createState() =>
      _CategoryStatsFilterDrawerState();
}

class _CategoryStatsFilterDrawerState
    extends ConsumerState<_CategoryStatsFilterDrawer> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final config = ref.watch(categoryStatsFilterConfigProvider);
    final booksAsync = ref.watch(booksProvider);
    final assetsAsync = ref.watch(assetsProvider);
    final tagsAsync = ref.watch(activeTagsProvider);

    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('多维筛选', style: theme.textTheme.titleLarge),
                  TextButton(
                    onPressed: () {
                      ref
                          .read(categoryStatsFilterConfigProvider.notifier)
                          .reset();
                    },
                    child: const Text('重置'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // Include Exclude Budget switch
                  SwitchListTile(
                    key: const Key('filter-include-exclude-budget-switch'),
                    contentPadding: DesktopAdaptive.isDesktop(context)
                        ? EdgeInsets.zero
                        : null,
                    title: const Text('包含不计入预算账单'),
                    subtitle: const Text('默认包含；取消则剔除已标记排除的账单'),
                    value: config.includeExcludeBudget,
                    onChanged: (val) {
                      ref
                          .read(categoryStatsFilterConfigProvider.notifier)
                          .update(config.copyWith(includeExcludeBudget: val));
                    },
                  ),
                  const Divider(height: 24),

                  // Books filter
                  Text('账本选择', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  booksAsync.when(
                    data: (books) => Wrap(
                      spacing: 8,
                      children: [
                        for (final b in books)
                          FilterChip(
                            label: Text(b.name),
                            selected:
                                config.selectedBookIds?.contains(b.id) ?? false,
                            onSelected: (selected) {
                              final current = List<int>.from(
                                config.selectedBookIds ?? [],
                              );
                              if (selected) {
                                current.add(b.id);
                              } else {
                                current.remove(b.id);
                              }
                              ref
                                  .read(
                                    categoryStatsFilterConfigProvider.notifier,
                                  )
                                  .update(
                                    config.copyWith(
                                      selectedBookIds: current.isEmpty
                                          ? null
                                          : current,
                                      clearBookIds: current.isEmpty,
                                    ),
                                  );
                            },
                          ),
                      ],
                    ),
                    loading: () => const LinearProgressIndicator(),
                    error: (_, _) => const Text('加载账本失败'),
                  ),
                  const Divider(height: 24),

                  // Assets filter
                  Text('账户选择', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  assetsAsync.when(
                    data: (assets) => Wrap(
                      spacing: 8,
                      children: [
                        for (final a in assets)
                          FilterChip(
                            label: Text(a.name),
                            selected:
                                config.selectedAssetIds?.contains(a.id) ??
                                false,
                            onSelected: (selected) {
                              final current = Set<int>.from(
                                config.selectedAssetIds ?? {},
                              );
                              if (selected) {
                                current.add(a.id);
                              } else {
                                current.remove(a.id);
                              }
                              ref
                                  .read(
                                    categoryStatsFilterConfigProvider.notifier,
                                  )
                                  .update(
                                    config.copyWith(
                                      selectedAssetIds: current.isEmpty
                                          ? null
                                          : current,
                                      clearAssetIds: current.isEmpty,
                                    ),
                                  );
                            },
                          ),
                      ],
                    ),
                    loading: () => const LinearProgressIndicator(),
                    error: (_, _) => const Text('加载账户失败'),
                  ),
                  const Divider(height: 24),

                  // Tags filter
                  Text('标签选择', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  tagsAsync.when(
                    data: (tags) => Wrap(
                      spacing: 8,
                      children: [
                        for (final t in tags)
                          FilterChip(
                            label: Text(t.name),
                            selected:
                                config.selectedTagIds?.contains(t.tagId) ??
                                false,
                            onSelected: (selected) {
                              final current = Set<String>.from(
                                config.selectedTagIds ?? {},
                              );
                              if (selected) {
                                current.add(t.tagId);
                              } else {
                                current.remove(t.tagId);
                              }
                              ref
                                  .read(
                                    categoryStatsFilterConfigProvider.notifier,
                                  )
                                  .update(
                                    config.copyWith(
                                      selectedTagIds: current.isEmpty
                                          ? null
                                          : current,
                                      clearTagIds: current.isEmpty,
                                    ),
                                  );
                            },
                          ),
                      ],
                    ),
                    loading: () => const LinearProgressIndicator(),
                    error: (_, _) => const Text('加载标签失败'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('完成筛选'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Category Drilldown Page (F-030 / SCR-017, original `/anz/CAAct`).
class CategoryDrilldownPage extends StatefulWidget {
  const CategoryDrilldownPage({
    super.key,
    required this.categoryId,
    required this.categoryName,
    this.categoryIcon = '',
    this.isDirectChild = false,
    this.isFirstLevel = true,
    this.rowItem,
    this.uncategorizedRow,
    required this.result,
    this.categoriesById = const <int, RecordCategory>{},
  });

  final int categoryId;
  final String categoryName;
  final String categoryIcon;
  final bool isDirectChild;
  final bool isFirstLevel;
  final CategoryRowItem? rowItem;
  final UncategorizedRowItem? uncategorizedRow;
  final CategoryStatsResult result;
  final Map<int, RecordCategory> categoriesById;

  @override
  State<CategoryDrilldownPage> createState() => _CategoryDrilldownPageState();
}

class _CategoryDrilldownPageState extends State<CategoryDrilldownPage> {
  bool _sortByAmount = false; // false = 按时间, true = 按金额

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUncat = widget.categoryId == -1;
    final catType = widget.result.dimension == StatDimension.income
        ? RecordType.income
        : RecordType.expense;
    final headerDbCat = isUncat
        ? null
        : widget.categoriesById[widget.categoryId];
    final headerParentCat =
        (headerDbCat != null && headerDbCat.parentCatId != noRef)
        ? widget.categoriesById[headerDbCat.parentCatId]
        : null;
    final headerIcon =
        (headerDbCat?.icon != null && headerDbCat!.icon.trim().isNotEmpty)
        ? headerDbCat.icon
        : (widget.categoryIcon.isNotEmpty ? widget.categoryIcon : null);
    final headerColor =
        (headerDbCat?.colorFill != null &&
            headerDbCat!.colorFill!.trim().isNotEmpty)
        ? headerDbCat.colorFill
        : headerParentCat?.colorFill;

    final BigInt totalAmount = isUncat
        ? (widget.uncategorizedRow?.moneyMinor ?? BigInt.zero)
        : (widget.rowItem?.moneyMinor ?? BigInt.zero);

    final int count = isUncat
        ? (widget.uncategorizedRow?.count ?? 0)
        : (widget.rowItem?.count ?? 0);

    final String ratioText = isUncat
        ? (widget.uncategorizedRow?.ratioText ?? '--')
        : (widget.rowItem?.ratioText ?? '--');

    final rawBills = isUncat
        ? (widget.uncategorizedRow?.bills ?? <CategoryBill>[])
        : (widget.rowItem?.bills ?? <CategoryBill>[]);

    final bills = List<CategoryBill>.from(rawBills);
    if (_sortByAmount) {
      bills.sort((a, b) => b.netMinor.compareTo(a.netMinor));
    } else {
      bills.sort((a, b) => b.recordTime.compareTo(a.recordTime));
    }

    final isExpandedDesktop = DesktopAdaptive.isExpandedDesktop(context);

    final summaryCard = Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            if (!isUncat) ...[
              CategoryIconAvatar(
                iconKey: headerIcon,
                parentIconKey: headerParentCat?.icon,
                colorHex: headerColor,
                name: widget.categoryName,
                type: catType,
                size: 42,
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '该分类总额',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '¥${formatMinor(totalAmount)}',
                      maxLines: 1,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: widget.result.dimension == StatDimension.expense
                            ? theme.colorScheme.error
                            : theme.colorScheme.primary,
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
                      '占比 $ratioText',
                      maxLines: 1,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$count 笔账单',
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

    final hasSubcategories =
        !isUncat &&
        widget.rowItem != null &&
        widget.rowItem!.children.isNotEmpty;

    final subcategoryCard = hasSubcategories
        ? Card(
            elevation: 2,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '子分类构成',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (final child in widget.rowItem!.children)
                    Builder(
                      builder: (context) {
                        final childDb = widget.categoriesById[child.categoryId];
                        final childIcon =
                            (childDb?.icon != null &&
                                childDb!.icon.trim().isNotEmpty)
                            ? childDb.icon
                            : (child.icon.isNotEmpty ? child.icon : null);
                        final childColor =
                            (childDb?.colorFill != null &&
                                childDb!.colorFill!.trim().isNotEmpty)
                            ? childDb.colorFill
                            : headerColor;
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Flexible(
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    CategoryIconAvatar(
                                      iconKey: childIcon,
                                      parentIconKey: headerIcon,
                                      colorHex: childColor,
                                      name: child.name,
                                      type: catType,
                                      size: 22,
                                    ),
                                    const SizedBox(width: 8),
                                    Flexible(
                                      child: Text(
                                        child.name,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 140,
                                ),
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerRight,
                                  child: Text(
                                    '¥${formatMinor(child.moneyMinor)} (${child.ratioText})',
                                    maxLines: 1,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
          )
        : null;

    final billListHeader = Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Text(
            '包含账单明细 ($count 笔)',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        const SizedBox(width: 8),
        SegmentedButton<bool>(
          key: const Key('drilldown-sort-switch'),
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
                child: Text('按时间', maxLines: 1, softWrap: false),
              ),
            ),
            ButtonSegment(
              value: true,
              label: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text('按金额', maxLines: 1, softWrap: false),
              ),
            ),
          ],
          selected: {_sortByAmount},
          onSelectionChanged: (set) {
            if (set.isNotEmpty) {
              setState(() => _sortByAmount = set.first);
            }
          },
        ),
      ],
    );

    Widget buildBillCard(CategoryBill bill) {
      final entry = bill.entry;
      final billCat = entry.recordCatId == noRef
          ? null
          : widget.categoriesById[entry.recordCatId];
      final billParentCat = (billCat != null && billCat.parentCatId != noRef)
          ? widget.categoriesById[billCat.parentCatId]
          : null;
      final billCatName = billCat != null
          ? (billParentCat != null
                ? '${billParentCat.name} · ${billCat.name}'
                : billCat.name)
          : (isUncat ? null : widget.categoryName);
      final billColor =
          (billCat?.colorFill != null && billCat!.colorFill!.trim().isNotEmpty)
          ? billCat.colorFill
          : (billParentCat?.colorFill ?? headerColor);
      final isRefund =
          (entry.type == RecordType.expense ||
              entry.type == RecordType.income) &&
          entry.moneyMinor < BigInt.zero;
      return Card(
        margin: const EdgeInsets.symmetric(vertical: 4),
        child: ListTile(
          key: Key('drilldown-bill-${bill.recordId}'),
          leading: RecordTypeIconAvatar(
            recordType: entry.type,
            subType: entry.subType,
            isRefund: isRefund,
            categoryName: billCatName,
            categoryIcon: billCat?.icon ?? headerIcon,
            parentCategoryIcon: billParentCat?.icon,
            categoryColor: billColor,
          ),
          title: Text(
            bill.remark.isNotEmpty ? bill.remark : widget.categoryName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            formatDateTime(
              DateTime.fromMillisecondsSinceEpoch(bill.recordTime),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Text(
                '¥${formatMinor(bill.netMinor)}',
                maxLines: 1,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: widget.result.dimension == StatDimension.expense
                      ? theme.colorScheme.error
                      : theme.colorScheme.primary,
                ),
              ),
            ),
          ),
          onTap: () {
            if (GoRouter.maybeOf(context) != null &&
                ModalRoute.of(context)?.settings is Page) {
              try {
                context.push('/record/${bill.recordId}');
                return;
              } catch (_) {}
            }
            pushDesktopModalOrMaterialRoute<void>(
              context,
              maxWidth: 560,
              maxHeight: 740,
              barrierDismissible: true,
              child: RecordDetailPage(recordId: bill.recordId),
            );
          },
        ),
      );
    }

    final isDesktop = DesktopAdaptive.isDesktop(context);
    final isPopupModal = isDesktop && ModalRoute.of(context) is PopupRoute;
    final stackedDrilldownList = ListView(
      padding: const EdgeInsets.all(16),
      children: [
        summaryCard,
        const SizedBox(height: 16),
        if (subcategoryCard != null) ...[
          subcategoryCard,
          const SizedBox(height: 16),
        ],
        billListHeader,
        const SizedBox(height: 8),
        if (bills.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Center(child: Text('无明细账单')),
          )
        else
          for (final bill in bills) buildBillCard(bill),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        leading: isPopupModal ? const CloseButton() : null,
        title: Text(widget.categoryName),
      ),
      body: isExpandedDesktop
          ? Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1360),
                child: Row(
                  key: const Key('category-drilldown-desktop-split'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      flex: 42,
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(20, 16, 12, 24),
                        children: [
                          summaryCard,
                          if (subcategoryCard != null) ...[
                            const SizedBox(height: 16),
                            subcategoryCard,
                          ],
                        ],
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(
                      flex: 58,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 20, 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            billListHeader,
                            const SizedBox(height: 8),
                            Expanded(
                              child: bills.isEmpty
                                  ? const Center(child: Text('无明细账单'))
                                  : ListView.builder(
                                      itemCount: bills.length,
                                      itemBuilder: (context, index) =>
                                          buildBillCard(bills[index]),
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : (isDesktop
                ? Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: stackedDrilldownList,
                    ),
                  )
                : stackedDrilldownList),
    );
  }
}

/// Lightweight overview card for embedding in the Stats Tab overview.
class CategoryStatsOverviewCard extends ConsumerWidget {
  const CategoryStatsOverviewCard({
    super.key,
    this.onOpenDetail,
    this.onTapCategory,
  });

  final VoidCallback? onOpenDetail;
  final void Function(CategoryRowItem row)? onTapCategory;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final resultAsync = ref.watch(statsHubCategoryOverviewProvider);
    final bookId = ref.watch(currentBookIdProvider).value ?? 1;
    final categories =
        ref.watch(categoriesProvider(bookId)).value ?? const <RecordCategory>[];
    final catById = <int, RecordCategory>{for (final c in categories) c.id: c};

    return Card(
      elevation: 1,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: resultAsync.when(
          data: (result) {
            final top5 = result.firstLevelRows.take(5).toList();
            final catType = result.dimension == StatDimension.income
                ? RecordType.income
                : RecordType.expense;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(
                      child: Text(
                        '当月分类排行 Top 5',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: onOpenDetail,
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('查看完整分析'),
                          Icon(Icons.chevron_right, size: 16),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (top5.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Center(child: Text('本月暂无分类支出')),
                  )
                else
                  for (final row in top5)
                    Builder(
                      builder: (context) {
                        final dbCat = catById[row.categoryId];
                        final parentCat =
                            (dbCat != null && dbCat.parentCatId != noRef)
                            ? catById[dbCat.parentCatId]
                            : null;
                        final catIcon =
                            (dbCat?.icon != null &&
                                dbCat!.icon.trim().isNotEmpty)
                            ? dbCat.icon
                            : (row.icon.isNotEmpty ? row.icon : null);
                        final catColor =
                            (dbCat?.colorFill != null &&
                                dbCat!.colorFill!.trim().isNotEmpty)
                            ? dbCat.colorFill
                            : parentCat?.colorFill;
                        final visual = resolveCategoryVisual(
                          iconKey: catIcon,
                          parentIconKey: parentCat?.icon,
                          colorHex: catColor,
                          name: row.name,
                          type: catType,
                        );
                        return InkWell(
                          onTap: () => onTapCategory?.call(row),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Column(
                              children: [
                                Row(
                                  children: [
                                    CategoryIconAvatar(
                                      iconKey: catIcon,
                                      parentIconKey: parentCat?.icon,
                                      colorHex: catColor,
                                      name: row.name,
                                      type: catType,
                                      size: 26,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        row.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxWidth: 148,
                                      ),
                                      child: FittedBox(
                                        fit: BoxFit.scaleDown,
                                        alignment: Alignment.centerRight,
                                        child: Text(
                                          '¥${formatMinor(row.moneyMinor)} (${row.ratioText})',
                                          maxLines: 1,
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
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
                                    value: (row.ratioBasisPoints / 10000.0)
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
                          ),
                        );
                      },
                    ),
              ],
            );
          },
          loading: () => const SizedBox(
            height: 120,
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => Padding(
            padding: const EdgeInsets.all(16),
            child: Text('加载分类概览失败: $e'),
          ),
        ),
      ),
    );
  }
}
