import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/adaptive.dart';
import '../../app/providers.dart';
import '../../domain/rules/annual_report.dart';
import '../common/common.dart';
import '../common/desktop_modal_page.dart';
import '../records/record_detail_page.dart';
import 'annual_report_providers.dart';

/// Active year notifier for [AnnualReportPage] (`/stats/annual`), synced with
/// desktop global period shortcuts (`[` / `]` / `Alt+←/→` / `T`).
final class AnnualReportYearNotifier extends Notifier<int> {
  @override
  int build() => DateTime.now().year;

  void previous() => state = state - 1;
  void next() => state = state + 1;
  void reset() => state = DateTime.now().year;
  void setYear(int year) => state = year;
}

final annualReportYearProvider =
    NotifierProvider<AnnualReportYearNotifier, int>(
      AnnualReportYearNotifier.new,
    );

/// Full page for Annual Bill and Annual Report (F-030).
class AnnualReportPage extends ConsumerStatefulWidget {
  const AnnualReportPage({
    super.key,
    this.initialYear,
    this.initialBookId,
    this.onRecordTap,
  });

  final int? initialYear;
  final int? initialBookId;
  final void Function(String recordId)? onRecordTap;

  @override
  ConsumerState<AnnualReportPage> createState() => _AnnualReportPageState();
}

class _AnnualReportPageState extends ConsumerState<AnnualReportPage> {
  late bool _allBooks;
  bool _yearSynced = false;
  int _activeTab = 0; // 0: 年度账单, 1: 年度报告
  bool _sortDescending = false; // 月份表排序
  late final PageController _tabPageController;

  @override
  void initState() {
    super.initState();
    _allBooks = false;
    _tabPageController = PageController(initialPage: _activeTab);
    _scheduleYearInit();
  }

  @override
  void didUpdateWidget(covariant AnnualReportPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialYear != widget.initialYear) {
      _yearSynced = false;
      _scheduleYearInit();
    }
  }

  void _scheduleYearInit() {
    final targetYear = widget.initialYear ?? DateTime.now().year;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_yearSynced) {
        ref.read(annualReportYearProvider.notifier).setYear(targetYear);
        setState(() => _yearSynced = true);
      }
    });
  }

  int _effectiveYear(int watchedYear) =>
      _yearSynced ? watchedYear : (widget.initialYear ?? DateTime.now().year);

  void _setSelectedYear(int year) {
    if (!_yearSynced) {
      setState(() => _yearSynced = true);
    }
    ref.read(annualReportYearProvider.notifier).setYear(year);
  }

  @override
  void dispose() {
    _tabPageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final watchedYear = ref.watch(annualReportYearProvider);
    final selectedYear = _effectiveYear(watchedYear);
    final currentBook = ref.watch(currentBookProvider).value;
    final currentBookId = currentBook?.id;
    final startDay = currentBook?.startDay ?? 1;

    final targetBookId = _allBooks ? null : currentBookId;

    final availableYearsAsync = ref.watch(
      annualAvailableYearsProvider(targetBookId),
    );
    final availableYears = availableYearsAsync.value ?? [selectedYear];

    final reportAsync = ref.watch(
      annualReportDataProvider((
        year: selectedYear,
        bookId: targetBookId,
        startDay: startDay,
      )),
    );

    void handleRecordTap(String recordId) {
      if (widget.onRecordTap != null) {
        widget.onRecordTap!(recordId);
        return;
      }
      if (GoRouter.maybeOf(context) != null &&
          ModalRoute.of(context)?.settings is Page) {
        try {
          context.push('/record/$recordId');
          return;
        } catch (_) {}
      }
      pushDesktopModalOrMaterialRoute<void>(
        context,
        maxWidth: 560,
        maxHeight: 740,
        barrierDismissible: true,
        child: RecordDetailPage(recordId: recordId),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('年度统计', maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: FilterChip(
              key: const Key('annual-report-book-filter-chip'),
              visualDensity: VisualDensity.compact,
              selected: _allBooks,
              label: Text(
                _allBooks ? '全部账本' : (currentBook?.name ?? '当前账本'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onSelected: (selected) {
                setState(() => _allBooks = selected);
              },
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          // Year Picker & Tab Switcher Bar
          _buildTopControls(availableYears, selectedYear),
          const Divider(height: 1),

          // Content Area: Synced 2-page PageView (年度账单 ⇄ 年度报告)
          Expanded(
            child: PageView(
              key: const Key('annual-report-tab-pageview'),
              controller: _tabPageController,
              scrollBehavior: ScrollConfiguration.of(context).copyWith(
                dragDevices: const <PointerDeviceKind>{
                  PointerDeviceKind.touch,
                  PointerDeviceKind.mouse,
                  PointerDeviceKind.trackpad,
                  PointerDeviceKind.stylus,
                  PointerDeviceKind.invertedStylus,
                },
              ),
              onPageChanged: (index) {
                if (_activeTab != index) {
                  setState(() => _activeTab = index);
                }
              },
              children: [
                reportAsync.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (err, _) => ErrorView(err),
                  data: (report) => _YearlyBillView(
                    key: const Key('annual-report-bill-view'),
                    data: report,
                    sortDescending: _sortDescending,
                    onToggleSort: () {
                      setState(() => _sortDescending = !_sortDescending);
                    },
                  ),
                ),
                reportAsync.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (err, _) => ErrorView(err),
                  data: (report) => _AnnualReportHighlightView(
                    key: const Key('annual-report-highlight-view'),
                    data: report,
                    onRecordTap: handleRecordTap,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopControls(List<int> availableYears, int selectedYear) {
    final isExpandedDesktop = DesktopAdaptive.isExpandedDesktop(context);

    final yearSelectorRow = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          key: const Key('annual-report-prev-year-button'),
          icon: const Icon(Icons.chevron_left),
          tooltip: '上一年',
          onPressed: () {
            _setSelectedYear(selectedYear - 1);
          },
        ),
        InkWell(
          key: const Key('annual-report-year-picker-button'),
          borderRadius: BorderRadius.circular(8),
          onTap: () => _showYearPickerDialog(availableYears, selectedYear),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                Text(
                  '$selectedYear年',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Icon(Icons.arrow_drop_down),
              ],
            ),
          ),
        ),
        IconButton(
          key: const Key('annual-report-next-year-button'),
          icon: const Icon(Icons.chevron_right),
          tooltip: '下一年',
          onPressed: () {
            _setSelectedYear(selectedYear + 1);
          },
        ),
      ],
    );

    final segmentedTabs = SegmentedButton<int>(
      key: const Key('annual-report-segmented-tabs'),
      showSelectedIcon: false,
      style: const ButtonStyle(
        visualDensity: VisualDensity.compact,
        padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      segments: const [
        ButtonSegment<int>(
          value: 0,
          label: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text('年度账单', maxLines: 1, softWrap: false),
          ),
          icon: Icon(Icons.table_chart_outlined, size: 18),
        ),
        ButtonSegment<int>(
          value: 1,
          label: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text('年度报告', maxLines: 1, softWrap: false),
          ),
          icon: Icon(Icons.auto_awesome_outlined, size: 18),
        ),
      ],
      selected: {_activeTab},
      onSelectionChanged: (set) {
        final target = set.first;
        if (target == _activeTab) return;
        setState(() => _activeTab = target);
        if (_tabPageController.hasClients) {
          _tabPageController.jumpToPage(target);
        }
      },
    );

    if (isExpandedDesktop) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1400),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              children: [
                yearSelectorRow,
                const Spacer(),
                SizedBox(width: 280, child: segmentedTabs),
              ],
            ),
          ),
        ),
      );
    }

    final stackedControls = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: [
          Center(child: yearSelectorRow),
          const SizedBox(height: 6),
          SizedBox(width: double.infinity, child: segmentedTabs),
        ],
      ),
    );
    if (!DesktopAdaptive.isDesktop(context)) {
      return stackedControls;
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: stackedControls,
      ),
    );
  }

  void _showYearPickerDialog(List<int> availableYears, int selectedYear) {
    showDialog<int>(
      context: context,
      builder: (ctx) {
        final sortedYears = {...availableYears, selectedYear}.toList()
          ..sort((a, b) => b.compareTo(a));
        return SimpleDialog(
          title: const Text('选择年份'),
          children: sortedYears.map((y) {
            final isSelected = y == selectedYear;
            return SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, y),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '$y年',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: isSelected
                            ? FontWeight.bold
                            : FontWeight.normal,
                        color: isSelected
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                    ),
                    if (isSelected)
                      Icon(
                        Icons.check,
                        color: Theme.of(context).colorScheme.primary,
                        size: 20,
                      ),
                  ],
                ),
              ),
            );
          }).toList(),
        );
      },
    ).then((picked) {
      if (picked != null) {
        _setSelectedYear(picked);
      }
    });
  }
}

/// View 1: 年度账单（收支头卡、12个月收支图表、12个月收支明细表）.
class _YearlyBillView extends StatelessWidget {
  const _YearlyBillView({
    super.key,
    required this.data,
    required this.sortDescending,
    required this.onToggleSort,
  });

  final AnnualReportResult data;
  final bool sortDescending;
  final VoidCallback onToggleSort;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final expenseColor = isDark ? Colors.red.shade300 : Colors.red.shade700;
    final incomeColor = isDark ? Colors.green.shade300 : Colors.green.shade700;
    final positiveBalanceColor = isDark
        ? Colors.teal.shade300
        : Colors.teal.shade700;
    final chartIncomeColor = isDark
        ? Colors.green.shade400
        : Colors.green.shade600;
    final chartExpenseColor = isDark
        ? Colors.red.shade400
        : Colors.red.shade600;
    final mutedColor = theme.colorScheme.onSurfaceVariant;
    final sortedMonths = sortDescending
        ? data.monthlySummaries.reversed.toList()
        : data.monthlySummaries;
    final isExpandedDesktop = DesktopAdaptive.isExpandedDesktop(context);

    final summaryCard = Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: _buildSummaryItem(
                    label: '总结余',
                    amount: data.totalBalance,
                    color: data.totalBalance >= BigInt.zero
                        ? positiveBalanceColor
                        : expenseColor,
                    mutedColor: mutedColor,
                    isBold: true,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildSummaryItem(
                    label: '总支出',
                    amount: data.totalExpense,
                    color: expenseColor,
                    mutedColor: mutedColor,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildSummaryItem(
                    label: '总收入',
                    amount: data.totalIncome,
                    color: incomeColor,
                    mutedColor: mutedColor,
                  ),
                ),
              ],
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Divider(height: 1),
            ),
            Row(
              children: [
                Expanded(
                  child: _buildSubSummaryItem(
                    '月均结余',
                    data.averageMonthSurplus,
                    mutedColor,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildSubSummaryItem(
                    '月均支出',
                    data.averageMonthExpense,
                    mutedColor,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildSubSummaryItem(
                    '月均收入',
                    data.averageMonthIncome,
                    mutedColor,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    final trendBarCard = Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
                    '12个月收支趋势对比',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildLegend(chartIncomeColor, '收入', mutedColor),
                    const SizedBox(width: 12),
                    _buildLegend(chartExpenseColor, '支出', mutedColor),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: isExpandedDesktop ? 210 : 170,
              width: double.infinity,
              child: CustomPaint(
                painter: _AnnualTrendBarChartPainter(
                  months: data.monthlySummaries,
                  incomeColor: chartIncomeColor,
                  expenseColor: chartExpenseColor,
                  gridColor: theme.dividerColor,
                  labelColor: mutedColor,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    final monthlyTableCard = Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
                    '月度收支明细表',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                TextButton.icon(
                  key: const Key('annual-report-toggle-sort-button'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: onToggleSort,
                  icon: Icon(
                    sortDescending ? Icons.arrow_downward : Icons.arrow_upward,
                    size: 16,
                  ),
                  label: Text(sortDescending ? '12月至1月' : '1月至12月'),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Table Header
            Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: Text(
                      '月份',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(
                      '收入',
                      textAlign: TextAlign.right,
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(
                      '支出',
                      textAlign: TextAlign.right,
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: Text(
                        '结余',
                        textAlign: TextAlign.right,
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),

            // Month Rows
            ...sortedMonths.map((m) {
              return Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: theme.dividerColor.withValues(alpha: 0.3),
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          '${m.month}月',
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      flex: 3,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Text(
                          m.income > BigInt.zero
                              ? '+¥${formatMinor(m.income)}'
                              : '-',
                          textAlign: TextAlign.right,
                          maxLines: 1,
                          style: TextStyle(
                            color: m.income > BigInt.zero
                                ? incomeColor
                                : theme.disabledColor,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      flex: 3,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Text(
                          m.expense > BigInt.zero
                              ? '-¥${formatMinor(m.expense)}'
                              : '-',
                          textAlign: TextAlign.right,
                          maxLines: 1,
                          style: TextStyle(
                            color: m.expense > BigInt.zero
                                ? expenseColor
                                : theme.disabledColor,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      flex: 3,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerRight,
                          child: Text(
                            m.balance == BigInt.zero
                                ? '¥0.00'
                                : (m.balance < BigInt.zero
                                      ? '-¥${formatMinor(m.balance.abs())}'
                                      : '+¥${formatMinor(m.balance)}'),
                            textAlign: TextAlign.right,
                            maxLines: 1,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: m.balance > BigInt.zero
                                  ? positiveBalanceColor
                                  : (m.balance < BigInt.zero
                                        ? expenseColor
                                        : null),
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );

    if (isExpandedDesktop) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1400),
          child: Row(
            key: const Key('annual-bill-desktop-split'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 46,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 12, 24),
                  children: [
                    summaryCard,
                    const SizedBox(height: 16),
                    trendBarCard,
                  ],
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                flex: 54,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 16, 20, 24),
                  children: [monthlyTableCard],
                ),
              ),
            ],
          ),
        ),
      );
    }

    final stackedBillList = ListView(
      padding: const EdgeInsets.all(16),
      children: [
        summaryCard,
        const SizedBox(height: 16),
        trendBarCard,
        const SizedBox(height: 16),
        monthlyTableCard,
      ],
    );
    if (!DesktopAdaptive.isDesktop(context)) {
      return stackedBillList;
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: stackedBillList,
      ),
    );
  }

  Widget _buildSummaryItem({
    required String label,
    required BigInt amount,
    required Color color,
    required Color mutedColor,
    bool isBold = false,
  }) {
    return Column(
      children: [
        Text(
          label,
          maxLines: 1,
          style: TextStyle(fontSize: 12, color: mutedColor),
        ),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            amount.isNegative
                ? '-¥${formatMinor(amount.abs())}'
                : '¥${formatMinor(amount)}',
            maxLines: 1,
            style: TextStyle(
              fontSize: isBold ? 18 : 16,
              fontWeight: isBold ? FontWeight.bold : FontWeight.w600,
              color: color,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSubSummaryItem(String label, BigInt amount, Color mutedColor) {
    return Column(
      children: [
        Text(
          label,
          maxLines: 1,
          style: TextStyle(fontSize: 11, color: mutedColor),
        ),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            amount.isNegative
                ? '-¥${formatMinor(amount.abs())}'
                : '¥${formatMinor(amount)}',
            maxLines: 1,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
        ),
      ],
    );
  }

  Widget _buildLegend(Color color, String text, Color mutedColor) {
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 4),
        Text(text, style: TextStyle(fontSize: 12, color: mutedColor)),
      ],
    );
  }
}

/// View 2: 年度报告（记账天数、单笔最大、峰值月份、分类排行、账户与结语）.
class _AnnualReportHighlightView extends StatelessWidget {
  const _AnnualReportHighlightView({
    super.key,
    required this.data,
    this.onRecordTap,
  });

  final AnnualReportResult data;
  final void Function(String recordId)? onRecordTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final expenseColor = isDark ? Colors.red.shade300 : Colors.red.shade700;
    final incomeColor = isDark ? Colors.green.shade300 : Colors.green.shade700;
    final positiveBalanceColor = isDark
        ? Colors.teal.shade300
        : Colors.teal.shade700;
    final amberAccent = isDark ? Colors.amber.shade300 : Colors.amber.shade700;
    final mutedColor = scheme.onSurfaceVariant;
    final hasRecords = data.totalBillCount > 0;
    final isExpandedDesktop = DesktopAdaptive.isExpandedDesktop(context);

    // Card 1: 年度记账回顾
    final reviewCard = Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.auto_stories, color: scheme.primary, size: 24),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    '${data.year} 年度记账回顾',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              hasRecords ? '这一年，你坚持记录了 ${data.activeDays} 天的生活。' : '这一年暂无记账数据。',
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _buildMetricBox(
                    icon: Icons.receipt_long,
                    title: '记账总笔数',
                    value: '${data.totalBillCount} 笔',
                    mutedColor: mutedColor,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildMetricBox(
                    icon: Icons.savings_outlined,
                    title: '年度储蓄率',
                    value: '${(data.savingsRate * 100).toStringAsFixed(1)}%',
                    mutedColor: mutedColor,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildMetricBox(
                    icon: Icons.calendar_today,
                    title: '活跃记账天',
                    value: '${data.activeDays} 天',
                    mutedColor: mutedColor,
                  ),
                ),
              ],
            ),
            if (data.maxBillDayDate != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.star, color: amberAccent, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '最忙碌的一天：${data.maxBillDayDate}，共记录了 ${data.maxBillDayCount} 笔账单',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );

    // Card 2: 消费之最与峰值月份
    final peaksCard = Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.emoji_events_outlined, color: amberAccent, size: 24),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    '收支之最',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Max Expense Record
            if (data.maxExpenseRecord != null) ...[
              InkWell(
                key: const Key('annual-report-max-expense-record-tile'),
                borderRadius: BorderRadius.circular(8),
                onTap: () => onRecordTap?.call(data.maxExpenseRecord!.id),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: isDark ? 0.10 : 0.05),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      CircleAvatar(
                        backgroundColor: Colors.red.withValues(
                          alpha: isDark ? 0.20 : 0.14,
                        ),
                        child: Icon(Icons.arrow_downward, color: expenseColor),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '单笔最高支出',
                              style: TextStyle(fontSize: 12, color: mutedColor),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              data.maxExpenseRecord!.categoryName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 132),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerRight,
                          child: Text(
                            '-¥${formatMinor(data.maxExpenseRecord!.amount)}',
                            maxLines: 1,
                            style: TextStyle(
                              color: expenseColor,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],

            // Max Income Record
            if (data.maxIncomeRecord != null) ...[
              InkWell(
                key: const Key('annual-report-max-income-record-tile'),
                borderRadius: BorderRadius.circular(8),
                onTap: () => onRecordTap?.call(data.maxIncomeRecord!.id),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: isDark ? 0.10 : 0.05),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      CircleAvatar(
                        backgroundColor: Colors.green.withValues(
                          alpha: isDark ? 0.20 : 0.14,
                        ),
                        child: Icon(Icons.arrow_upward, color: incomeColor),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '单笔最高收入',
                              style: TextStyle(fontSize: 12, color: mutedColor),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              data.maxIncomeRecord!.categoryName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 132),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerRight,
                          child: Text(
                            '+¥${formatMinor(data.maxIncomeRecord!.amount)}',
                            maxLines: 1,
                            style: TextStyle(
                              color: incomeColor,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],

            // Peak Months
            Row(
              children: [
                Expanded(
                  child: _buildMonthPeakTile(
                    title: '支出最多月',
                    month: data.maxExpenseMonth,
                    amount: data.maxExpenseMonthAmount,
                    color: expenseColor,
                    mutedColor: mutedColor,
                    isDark: isDark,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildMonthPeakTile(
                    title: '收入最多月',
                    month: data.maxIncomeMonth,
                    amount: data.maxIncomeMonthAmount,
                    color: incomeColor,
                    mutedColor: mutedColor,
                    isDark: isDark,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    // Card 3: 年度支出构成 Top 榜
    final topCategoryCard = Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.pie_chart_outline,
                  color: positiveBalanceColor,
                  size: 24,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    '年度支出构成 Top 榜',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (data.topExpenseCategories.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Center(
                  child: Text('暂无支出分类数据', style: TextStyle(color: mutedColor)),
                ),
              )
            else
              ...data.topExpenseCategories.take(5).map((cat) {
                final rank = data.topExpenseCategories.indexOf(cat) + 1;
                final isTop3 = rank <= 3;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 22,
                            height: 22,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: isTop3
                                  ? amberAccent
                                  : scheme.surfaceContainerHighest,
                              shape: BoxShape.circle,
                            ),
                            child: Text(
                              '$rank',
                              style: TextStyle(
                                color: isTop3
                                    ? Colors.black87
                                    : scheme.onSurfaceVariant,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              cat.categoryName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${(cat.ratio * 100).toStringAsFixed(1)}%',
                            style: TextStyle(fontSize: 13, color: mutedColor),
                          ),
                          const SizedBox(width: 10),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 120),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerRight,
                              child: Text(
                                '¥${formatMinor(cat.amount)}',
                                maxLines: 1,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      LinearProgressIndicator(
                        value: cat.ratio.clamp(0.0, 1.0),
                        backgroundColor: scheme.surfaceContainerHighest,
                        color: rank == 1 ? amberAccent : scheme.primary,
                        borderRadius: BorderRadius.circular(4),
                        minHeight: 6,
                      ),
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );

    // Card 4: 账户与优惠
    final assetDiscountCard = Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.account_balance_wallet_outlined,
                  color: scheme.primary,
                  size: 24,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    '账户与优惠',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (data.mostUsedAsset != null)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(
                  backgroundColor: scheme.primaryContainer,
                  foregroundColor: scheme.onPrimaryContainer,
                  child: const Icon(Icons.credit_card, size: 20),
                ),
                title: Text(
                  '最常用账户：${data.mostUsedAsset!.assetName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '记账 ${data.mostUsedAsset!.count} 笔，占全部记录的 ${(data.mostUsedAsset!.ratio * 100).toStringAsFixed(1)}%',
                ),
              ),
            if (data.totalDiscount > BigInt.zero)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(
                  backgroundColor: scheme.tertiaryContainer,
                  foregroundColor: scheme.onTertiaryContainer,
                  child: const Icon(Icons.local_offer, size: 20),
                ),
                title: const Text('全年优惠立减'),
                subtitle: Text('共计省下 ¥${formatMinor(data.totalDiscount)}'),
              ),
            if (data.mostUsedAsset == null && data.totalDiscount == BigInt.zero)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text('暂无账户与优惠统计', style: TextStyle(color: mutedColor)),
              ),
          ],
        ),
      ),
    );

    // Card 5: 年度结语卡
    final closingQuoteCard = Card(
      elevation: 1,
      color: scheme.primaryContainer.withValues(alpha: 0.3),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.format_quote, color: amberAccent, size: 32),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '年度寄语',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    hasRecords
                        ? '点滴汇聚成海，每一笔收支都是生活的真实印记。${data.year}年你用心管理财务，新的一年继续保持良好记账习惯！'
                        : '${data.year}年尚无有效记账数据，期待新的一年与你一起记录每一份精彩！',
                    style: const TextStyle(fontSize: 14, height: 1.4),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    if (isExpandedDesktop) {
      return ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        children: [
          Center(
            child: ConstrainedBox(
              key: const Key('annual-report-desktop-grid'),
              constraints: const BoxConstraints(maxWidth: 1360),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: reviewCard),
                      const SizedBox(width: 16),
                      Expanded(child: peaksCard),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: topCategoryCard),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            assetDiscountCard,
                            const SizedBox(height: 16),
                            closingQuoteCard,
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    final stackedReportList = ListView(
      padding: const EdgeInsets.all(16),
      children: [
        reviewCard,
        const SizedBox(height: 16),
        peaksCard,
        const SizedBox(height: 16),
        topCategoryCard,
        const SizedBox(height: 16),
        assetDiscountCard,
        const SizedBox(height: 16),
        closingQuoteCard,
      ],
    );
    if (!DesktopAdaptive.isDesktop(context)) {
      return stackedReportList;
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: stackedReportList,
      ),
    );
  }

  Widget _buildMetricBox({
    required IconData icon,
    required String title,
    required String value,
    required Color mutedColor,
  }) {
    return Column(
      children: [
        Icon(icon, size: 22, color: mutedColor),
        const SizedBox(height: 6),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            title,
            maxLines: 1,
            style: TextStyle(fontSize: 12, color: mutedColor),
          ),
        ),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            value,
            maxLines: 1,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }

  Widget _buildMonthPeakTile({
    required String title,
    required int? month,
    required BigInt amount,
    required Color color,
    required Color mutedColor,
    required bool isDark,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: isDark ? 0.12 : 0.06),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: mutedColor),
          ),
          const SizedBox(height: 4),
          Text(
            month != null ? '$month月' : '-',
            maxLines: 1,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              amount > BigInt.zero ? '¥${formatMinor(amount)}' : '-',
              maxLines: 1,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 12-Month CustomPaint Bar Chart Painter.
class _AnnualTrendBarChartPainter extends CustomPainter {
  _AnnualTrendBarChartPainter({
    required this.months,
    required this.incomeColor,
    required this.expenseColor,
    required this.gridColor,
    required this.labelColor,
  });

  final List<MonthlyBucketSummary> months;
  final Color incomeColor;
  final Color expenseColor;
  final Color gridColor;
  final Color labelColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (months.isEmpty) return;

    final bottomPadding = 24.0;
    final topPadding = 10.0;
    final chartHeight = size.height - bottomPadding - topPadding;
    final chartWidth = size.width;

    // Find max value across all months
    var maxVal = BigInt.zero;
    for (final m in months) {
      if (m.income > maxVal) maxVal = m.income;
      if (m.expense > maxVal) maxVal = m.expense;
    }
    final maxDouble = maxVal > BigInt.zero ? maxVal.toDouble() : 10000.0;

    // Grid lines (0, 50%, 100%)
    final gridPaint = Paint()
      ..color = gridColor.withValues(alpha: 0.3)
      ..strokeWidth = 1.0;

    canvas.drawLine(
      Offset(0, topPadding),
      Offset(chartWidth, topPadding),
      gridPaint,
    );
    canvas.drawLine(
      Offset(0, topPadding + chartHeight / 2),
      Offset(chartWidth, topPadding + chartHeight / 2),
      gridPaint,
    );
    canvas.drawLine(
      Offset(0, topPadding + chartHeight),
      Offset(chartWidth, topPadding + chartHeight),
      gridPaint,
    );

    // Draw bars for 12 months
    final monthWidth = chartWidth / 12;
    final barWidth = (monthWidth - 6) / 2;

    final incomePaint = Paint()..color = incomeColor;
    final expensePaint = Paint()..color = expenseColor;

    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    );

    for (var i = 0; i < months.length && i < 12; i++) {
      final m = months[i];
      final monthCenterX = i * monthWidth + monthWidth / 2;

      // Income bar
      final incomeH = (m.income.toDouble() / maxDouble) * chartHeight;
      if (incomeH > 0) {
        final left = monthCenterX - barWidth - 1;
        final top = topPadding + chartHeight - incomeH;
        final rect = RRect.fromRectAndRadius(
          Rect.fromLTWH(left, top, barWidth, incomeH),
          const Radius.circular(2),
        );
        canvas.drawRRect(rect, incomePaint);
      }

      // Expense bar
      final expenseH = (m.expense.toDouble() / maxDouble) * chartHeight;
      if (expenseH > 0) {
        final left = monthCenterX + 1;
        final top = topPadding + chartHeight - expenseH;
        final rect = RRect.fromRectAndRadius(
          Rect.fromLTWH(left, top, barWidth, expenseH),
          const Radius.circular(2),
        );
        canvas.drawRRect(rect, expensePaint);
      }

      // Month label below
      textPainter.text = TextSpan(
        text: '${m.month}',
        style: TextStyle(color: labelColor, fontSize: 10),
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(
          monthCenterX - textPainter.width / 2,
          size.height - bottomPadding + 6,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _AnnualTrendBarChartPainter oldDelegate) {
    return oldDelegate.months != months ||
        oldDelegate.incomeColor != incomeColor ||
        oldDelegate.expenseColor != expenseColor;
  }
}

/// Lightweight overview card designed to be embedded in the bottom "统计" Tab (AnalyzeFragment).
class AnnualReportOverviewCard extends ConsumerWidget {
  const AnnualReportOverviewCard({super.key, this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentBook = ref.watch(currentBookProvider).value;
    final currentBookId = currentBook?.id;
    final startDay = currentBook?.startDay ?? 1;
    final year = DateTime.now().year;

    final reportAsync = ref.watch(
      annualReportDataProvider((
        year: year,
        bookId: currentBookId,
        startDay: startDay,
      )),
    );

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final expenseColor = isDark ? Colors.red.shade300 : Colors.red.shade700;
    final incomeColor = isDark ? Colors.green.shade300 : Colors.green.shade700;
    final positiveBalanceColor = isDark
        ? Colors.teal.shade300
        : Colors.teal.shade700;
    final mutedColor = theme.colorScheme.onSurfaceVariant;
    final report = reportAsync.value;

    final totalExpense = report?.totalExpense ?? BigInt.zero;
    final totalIncome = report?.totalIncome ?? BigInt.zero;
    final totalBalance = report?.totalBalance ?? BigInt.zero;

    return Card(
      key: const Key('annual-report-overview-card'),
      elevation: 1,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header Row
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary.withValues(
                              alpha: 0.12,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            Icons.insights,
                            size: 20,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              '$year年度统计',
                              maxLines: 1,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Text(
                        '查看年度账单与报告 >',
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // 3 Metric columns: 支出 / 收入 / 结余
              Row(
                children: [
                  Expanded(
                    child: _buildMetricCol(
                      '支出',
                      '-¥${formatMinor(totalExpense)}',
                      expenseColor,
                      mutedColor,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildMetricCol(
                      '收入',
                      '+¥${formatMinor(totalIncome)}',
                      incomeColor,
                      mutedColor,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildMetricCol(
                      '结余',
                      totalBalance == BigInt.zero
                          ? '¥0.00'
                          : (totalBalance.isNegative
                                ? '-¥${formatMinor(totalBalance.abs())}'
                                : '+¥${formatMinor(totalBalance)}'),
                      totalBalance >= BigInt.zero
                          ? positiveBalanceColor
                          : expenseColor,
                      mutedColor,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMetricCol(
    String label,
    String amountStr,
    Color color,
    Color mutedColor,
  ) {
    return Column(
      children: [
        Text(
          label,
          maxLines: 1,
          style: TextStyle(fontSize: 12, color: mutedColor),
        ),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            amountStr,
            maxLines: 1,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ),
      ],
    );
  }
}
