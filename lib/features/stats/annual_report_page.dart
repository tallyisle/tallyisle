import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/rules/annual_report.dart';
import '../common/common.dart';
import 'annual_report_providers.dart';

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
  late int _selectedYear;
  late bool _allBooks;
  int _activeTab = 0; // 0: 年度账单, 1: 年度报告
  bool _sortDescending = false; // 月份表排序

  @override
  void initState() {
    super.initState();
    _selectedYear = widget.initialYear ?? DateTime.now().year;
    _allBooks = false;
  }

  @override
  Widget build(BuildContext context) {
    final currentBook = ref.watch(currentBookProvider).value;
    final currentBookId = currentBook?.id;
    final startDay = currentBook?.startDay ?? 1;

    final targetBookId = _allBooks ? null : currentBookId;

    final availableYearsAsync = ref.watch(
      annualAvailableYearsProvider(targetBookId),
    );
    final availableYears = availableYearsAsync.value ?? [_selectedYear];

    final reportAsync = ref.watch(
      annualReportDataProvider((
        year: _selectedYear,
        bookId: targetBookId,
        startDay: startDay,
      )),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('年度统计'),
        actions: [
          FilterChip(
            key: const Key('annual-report-book-filter-chip'),
            selected: _allBooks,
            label: Text(_allBooks ? '全部账本' : (currentBook?.name ?? '当前账本')),
            onSelected: (selected) {
              setState(() => _allBooks = selected);
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          // Year Picker & Tab Switcher Bar
          _buildTopControls(availableYears),
          const Divider(height: 1),

          // Content Area
          Expanded(
            child: reportAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (err, _) => ErrorView(err),
              data: (report) {
                return _activeTab == 0
                    ? _YearlyBillView(
                        key: const Key('annual-report-bill-view'),
                        data: report,
                        sortDescending: _sortDescending,
                        onToggleSort: () {
                          setState(() => _sortDescending = !_sortDescending);
                        },
                      )
                    : _AnnualReportHighlightView(
                        key: const Key('annual-report-highlight-view'),
                        data: report,
                        onRecordTap: widget.onRecordTap,
                      );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopControls(List<int> availableYears) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: [
          // Year Selector Row
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                key: const Key('annual-report-prev-year-button'),
                icon: const Icon(Icons.chevron_left),
                tooltip: '上一年',
                onPressed: () {
                  setState(() => _selectedYear -= 1);
                },
              ),
              InkWell(
                key: const Key('annual-report-year-picker-button'),
                borderRadius: BorderRadius.circular(8),
                onTap: () => _showYearPickerDialog(availableYears),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      Text(
                        '$_selectedYear年',
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
                  setState(() => _selectedYear += 1);
                },
              ),
            ],
          ),
          const SizedBox(height: 6),

          // Segmented Tab Switch: 年度账单 vs 年度报告
          SegmentedButton<int>(
            key: const Key('annual-report-segmented-tabs'),
            segments: const [
              ButtonSegment<int>(
                value: 0,
                label: Text('年度账单'),
                icon: Icon(Icons.table_chart_outlined),
              ),
              ButtonSegment<int>(
                value: 1,
                label: Text('年度报告'),
                icon: Icon(Icons.auto_awesome_outlined),
              ),
            ],
            selected: {_activeTab},
            onSelectionChanged: (set) {
              setState(() => _activeTab = set.first);
            },
          ),
        ],
      ),
    );
  }

  void _showYearPickerDialog(List<int> availableYears) {
    showDialog<int>(
      context: context,
      builder: (ctx) {
        final sortedYears = {...availableYears, _selectedYear}.toList()
          ..sort((a, b) => b.compareTo(a));
        return SimpleDialog(
          title: const Text('选择年份'),
          children: sortedYears.map((y) {
            final isSelected = y == _selectedYear;
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
        setState(() => _selectedYear = picked);
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
    final sortedMonths = sortDescending
        ? data.monthlySummaries.reversed.toList()
        : data.monthlySummaries;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Annual Summary Header Card
        Card(
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _buildSummaryItem(
                      label: '总结余',
                      amount: data.totalBalance,
                      color: data.totalBalance >= BigInt.zero
                          ? Colors.teal
                          : Colors.red,
                      isBold: true,
                    ),
                    _buildSummaryItem(
                      label: '总支出',
                      amount: data.totalExpense,
                      color: Colors.red.shade700,
                    ),
                    _buildSummaryItem(
                      label: '总收入',
                      amount: data.totalIncome,
                      color: Colors.green.shade700,
                    ),
                  ],
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Divider(height: 1),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _buildSubSummaryItem('月均结余', data.averageMonthSurplus),
                    _buildSubSummaryItem('月均支出', data.averageMonthExpense),
                    _buildSubSummaryItem('月均收入', data.averageMonthIncome),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // 12-Month CustomPaint Trend Chart Card
        Card(
          elevation: 1,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '12个月收支趋势对比',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Row(
                      children: [
                        _buildLegend(Colors.green.shade600, '收入'),
                        const SizedBox(width: 12),
                        _buildLegend(Colors.red.shade600, '支出'),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                SizedBox(
                  height: 170,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: _AnnualTrendBarChartPainter(
                      months: data.monthlySummaries,
                      incomeColor: Colors.green.shade600,
                      expenseColor: Colors.red.shade600,
                      gridColor: theme.dividerColor,
                      labelColor:
                          theme.textTheme.bodySmall?.color ?? Colors.grey,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // 12-Month Detailed Table Card
        Card(
          elevation: 1,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '月度收支明细表',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    TextButton.icon(
                      key: const Key('annual-report-toggle-sort-button'),
                      onPressed: onToggleSort,
                      icon: Icon(
                        sortDescending
                            ? Icons.arrow_downward
                            : Icons.arrow_upward,
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
                          child: Text(
                            '${m.month}月',
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontWeight: FontWeight.w500),
                          ),
                        ),
                        Expanded(
                          flex: 3,
                          child: Text(
                            m.income > BigInt.zero
                                ? '+¥${formatMinor(m.income)}'
                                : '-',
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              color: m.income > BigInt.zero
                                  ? Colors.green.shade700
                                  : theme.disabledColor,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 3,
                          child: Text(
                            m.expense > BigInt.zero
                                ? '-¥${formatMinor(m.expense)}'
                                : '-',
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              color: m.expense > BigInt.zero
                                  ? Colors.red.shade700
                                  : theme.disabledColor,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 3,
                          child: Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: Text(
                              m.balance == BigInt.zero
                                  ? '¥0.00'
                                  : (m.balance < BigInt.zero
                                        ? '-¥${formatMinor(m.balance.abs())}'
                                        : '+¥${formatMinor(m.balance)}'),
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: m.balance > BigInt.zero
                                    ? Colors.teal
                                    : (m.balance < BigInt.zero
                                          ? Colors.red.shade700
                                          : null),
                                fontSize: 13,
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
        ),
      ],
    );
  }

  Widget _buildSummaryItem({
    required String label,
    required BigInt amount,
    required Color color,
    bool isBold = false,
  }) {
    return Column(
      children: [
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 4),
        Text(
          amount.isNegative
              ? '-¥${formatMinor(amount.abs())}'
              : '¥${formatMinor(amount)}',
          style: TextStyle(
            fontSize: isBold ? 18 : 16,
            fontWeight: isBold ? FontWeight.bold : FontWeight.w600,
            color: color,
          ),
        ),
      ],
    );
  }

  Widget _buildSubSummaryItem(String label, BigInt amount) {
    return Column(
      children: [
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        const SizedBox(height: 2),
        Text(
          amount.isNegative
              ? '-¥${formatMinor(amount.abs())}'
              : '¥${formatMinor(amount)}',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }

  Widget _buildLegend(Color color, String text) {
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
        Text(text, style: const TextStyle(fontSize: 12, color: Colors.grey)),
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
    final hasRecords = data.totalBillCount > 0;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Card 1: 年度记账回顾
        Card(
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.auto_stories,
                      color: theme.colorScheme.primary,
                      size: 24,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${data.year} 年度记账回顾',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  hasRecords
                      ? '这一年，你坚持记录了 ${data.activeDays} 天的生活。'
                      : '这一年暂无记账数据。',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _buildMetricBox(
                      icon: Icons.receipt_long,
                      title: '记账总笔数',
                      value: '${data.totalBillCount} 笔',
                    ),
                    _buildMetricBox(
                      icon: Icons.savings_outlined,
                      title: '年度储蓄率',
                      value: '${(data.savingsRate * 100).toStringAsFixed(1)}%',
                    ),
                    _buildMetricBox(
                      icon: Icons.calendar_today,
                      title: '活跃记账天',
                      value: '${data.activeDays} 天',
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
                      color: theme.colorScheme.primaryContainer.withValues(
                        alpha: 0.4,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.star, color: Colors.amber, size: 18),
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
        ),
        const SizedBox(height: 16),

        // Card 2: 消费之最与峰值月份
        Card(
          elevation: 1,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.emoji_events_outlined,
                      color: Colors.amber,
                      size: 24,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '收支之最',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
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
                        color: Colors.red.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          CircleAvatar(
                            backgroundColor: Colors.red.shade100,
                            child: Icon(
                              Icons.arrow_downward,
                              color: Colors.red.shade700,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  '单笔最高支出',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  data.maxExpenseRecord!.categoryName,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 15,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Text(
                            '-¥${formatMinor(data.maxExpenseRecord!.amount)}',
                            style: TextStyle(
                              color: Colors.red.shade700,
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
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
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        CircleAvatar(
                          backgroundColor: Colors.green.shade100,
                          child: Icon(
                            Icons.arrow_upward,
                            color: Colors.green.shade700,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '单笔最高收入',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                data.maxIncomeRecord!.categoryName,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          '+¥${formatMinor(data.maxIncomeRecord!.amount)}',
                          style: TextStyle(
                            color: Colors.green.shade700,
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ],
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
                        color: Colors.red.shade700,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildMonthPeakTile(
                        title: '收入最多月',
                        month: data.maxIncomeMonth,
                        amount: data.maxIncomeMonthAmount,
                        color: Colors.green.shade700,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // Card 3: 年度支出构成 Top 榜
        Card(
          elevation: 1,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.pie_chart_outline,
                          color: Colors.teal,
                          size: 24,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '年度支出构成 Top 榜',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (data.topExpenseCategories.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Center(
                      child: Text(
                        '暂无支出分类数据',
                        style: TextStyle(color: Colors.grey),
                      ),
                    ),
                  )
                else
                  ...data.topExpenseCategories.take(5).map((cat) {
                    final rank = data.topExpenseCategories.indexOf(cat) + 1;
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
                                  color: rank <= 3
                                      ? Colors.amber.shade700
                                      : Colors.grey.shade400,
                                  shape: BoxShape.circle,
                                ),
                                child: Text(
                                  '$rank',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  cat.categoryName,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              Text(
                                '${(cat.ratio * 100).toStringAsFixed(1)}%',
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: Colors.grey,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Text(
                                '¥${formatMinor(cat.amount)}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          LinearProgressIndicator(
                            value: cat.ratio.clamp(0.0, 1.0),
                            backgroundColor: theme.dividerColor.withValues(
                              alpha: 0.3,
                            ),
                            color: rank == 1
                                ? Colors.amber.shade700
                                : theme.colorScheme.primary,
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
        ),
        const SizedBox(height: 16),

        // Card 4: 账户与优惠
        Card(
          elevation: 1,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.account_balance_wallet_outlined,
                      color: Colors.indigo,
                      size: 24,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '账户与优惠',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (data.mostUsedAsset != null)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const CircleAvatar(
                      backgroundColor: Colors.indigoAccent,
                      child: Icon(
                        Icons.credit_card,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                    title: Text('最常用账户：${data.mostUsedAsset!.assetName}'),
                    subtitle: Text(
                      '记账 ${data.mostUsedAsset!.count} 笔，占全部记录的 ${(data.mostUsedAsset!.ratio * 100).toStringAsFixed(1)}%',
                    ),
                  ),
                if (data.totalDiscount > BigInt.zero)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const CircleAvatar(
                      backgroundColor: Colors.deepOrangeAccent,
                      child: Icon(
                        Icons.local_offer,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                    title: const Text('全年优惠立减'),
                    subtitle: Text('共计省下 ¥${formatMinor(data.totalDiscount)}'),
                  ),
                if (data.mostUsedAsset == null &&
                    data.totalDiscount == BigInt.zero)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      '暂无账户与优惠统计',
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // Card 5: 年度结语卡
        Card(
          elevation: 1,
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.format_quote, color: Colors.amber, size: 32),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '年度寄语',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
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
        ),
      ],
    );
  }

  Widget _buildMetricBox({
    required IconData icon,
    required String title,
    required String value,
  }) {
    return Column(
      children: [
        Icon(icon, size: 22, color: Colors.grey.shade600),
        const SizedBox(height: 6),
        Text(title, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }

  Widget _buildMonthPeakTile({
    required String title,
    required int? month,
    required BigInt amount,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 4),
          Text(
            month != null ? '$month月' : '-',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 2),
          Text(
            amount > BigInt.zero ? '¥${formatMinor(amount)}' : '-',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: color,
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
    final report = reportAsync.value;

    final totalExpense = report?.totalExpense ?? BigInt.zero;
    final totalIncome = report?.totalIncome ?? BigInt.zero;
    final totalBalance = report?.totalBalance ?? BigInt.zero;

    return Card(
      key: const Key('annual-report-overview-card'),
      elevation: 1,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header Row
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      Icons.insights,
                      size: 20,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '$year年度统计',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '查看年度账单与报告 >',
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // 3 Metric columns: 支出 / 收入 / 结余
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildMetricCol(
                    '支出',
                    '-¥${formatMinor(totalExpense)}',
                    Colors.red.shade700,
                  ),
                  _buildMetricCol(
                    '收入',
                    '+¥${formatMinor(totalIncome)}',
                    Colors.green.shade700,
                  ),
                  _buildMetricCol(
                    '结余',
                    totalBalance == BigInt.zero
                        ? '¥0.00'
                        : (totalBalance.isNegative
                              ? '-¥${formatMinor(totalBalance.abs())}'
                              : '+¥${formatMinor(totalBalance)}'),
                    totalBalance >= BigInt.zero
                        ? Colors.teal
                        : Colors.red.shade700,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMetricCol(String label, String amountStr, Color color) {
    return Column(
      children: [
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 4),
        Text(
          amountStr,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ],
    );
  }
}
