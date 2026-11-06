import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/calendar.dart';
import '../../domain/rules/income_expense.dart';
import '../common/common.dart';
import '../records/record_labels.dart';

class CalendarPage extends ConsumerStatefulWidget {
  const CalendarPage({super.key});

  @override
  ConsumerState<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends ConsumerState<CalendarPage> {
  int _selectedDay = DateTime.now().day;

  Set<int> _getRepaymentDays(int year, int month, List<Asset> assets) {
    final days = <int>{};
    for (final a in assets) {
      if (a.type == AssetType.credit && a.status == 0) {
        final day =
            parseRepaymentDay(a.creditInfo, year, month) ??
            parseRepaymentDay(a.extraInfo, year, month);
        if (day != null) days.add(day);
      }
    }
    return days;
  }

  void _resetToToday() {
    ref.read(calendarMonthOffsetProvider.notifier).reset();
    setState(() => _selectedDay = DateTime.now().day);
  }

  @override
  Widget build(BuildContext context) {
    final month = ref.watch(calendarCurrentMonthProvider);
    final summariesAsync = ref.watch(calendarDailySummariesProvider);
    final monthSummaryAsync = ref.watch(calendarMonthSummaryProvider);
    final bookId = ref.watch(currentBookIdProvider).value ?? 1;
    final categories = ref.watch(categoriesProvider(bookId)).value ?? const [];
    final assets = ref.watch(assetsProvider).value ?? const <Asset>[];

    final clampedSelectedDay = _selectedDay.clamp(1, month.daysInMonth);
    if (clampedSelectedDay != _selectedDay) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _selectedDay = clampedSelectedDay);
      });
    }

    final repaymentDays = _getRepaymentDays(month.year, month.month, assets);

    return Scaffold(
      appBar: AppBar(
        title: const Text('日历视图'),
        actions: [
          TextButton(
            key: const Key('calendar-today-button'),
            onPressed: _resetToToday,
            child: const Text('今天'),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildMonthSwitcher(context, month),
          _buildMonthSummaryCard(context, monthSummaryAsync),
          _buildWeekdayHeader(context),
          summariesAsync.when(
            data: (dailyMap) => _buildCalendarGrid(
              context,
              month,
              dailyMap,
              repaymentDays,
              clampedSelectedDay,
            ),
            loading: () => const SizedBox(
              height: 240,
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (err, _) => SizedBox(height: 240, child: ErrorView(err)),
          ),
          const Divider(height: 1),
          _buildSelectedDayHeader(
            context,
            month,
            summariesAsync,
            clampedSelectedDay,
          ),
          Expanded(
            child: _buildSelectedDayRecords(
              context,
              summariesAsync,
              clampedSelectedDay,
              categories,
              assets,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMonthSwitcher(BuildContext context, CalendarMonth month) {
    final offsetNotifier = ref.read(calendarMonthOffsetProvider.notifier);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          IconButton(
            key: const Key('calendar-prev-month'),
            tooltip: '上个月',
            icon: const Icon(Icons.chevron_left),
            onPressed: offsetNotifier.previous,
          ),
          Expanded(
            child: Center(
              child: Text(
                '${month.year}年${month.month}月',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
          ),
          IconButton(
            key: const Key('calendar-next-month'),
            tooltip: '下个月',
            icon: const Icon(Icons.chevron_right),
            onPressed: offsetNotifier.next,
          ),
        ],
      ),
    );
  }

  Widget _buildMonthSummaryCard(
    BuildContext context,
    AsyncValue<IncomeExpense> summaryAsync,
  ) {
    final theme = Theme.of(context);
    final summary = summaryAsync.value ?? IncomeExpense.zero;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _summaryItem(
            '结余',
            formatMinor(summary.balance),
            theme.textTheme.bodyMedium?.color,
          ),
          _summaryItem('支出', formatMinor(summary.expense), Colors.red.shade700),
          _summaryItem(
            '收入',
            formatMinor(summary.income),
            Colors.green.shade700,
          ),
        ],
      ),
    );
  }

  Widget _summaryItem(String label, String value, Color? color) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        const SizedBox(height: 2),
        Text(
          '¥$value',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ],
    );
  }

  Widget _buildWeekdayHeader(BuildContext context) {
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          for (var i = 0; i < 7; i++)
            Expanded(
              child: Center(
                child: Text(
                  weekdays[i],
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: i >= 5
                        ? Colors.orange.shade800
                        : Colors.grey.shade700,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCalendarGrid(
    BuildContext context,
    CalendarMonth month,
    Map<int, CalendarDailySummary<LedgerRecord>> dailyMap,
    Set<int> repaymentDays,
    int selectedDay,
  ) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final isCurrentMonth = now.year == month.year && now.month == month.month;

    // ISO 8601: Monday=1 .. Sunday=7. Leading blanks count:
    final leadingBlanks = (month.firstWeekday - 1) % 7;
    final totalCells = leadingBlanks + month.daysInMonth;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: GridView.builder(
        key: const Key('calendar-grid'),
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 7,
          childAspectRatio: 0.95,
        ),
        itemCount: totalCells,
        itemBuilder: (context, index) {
          if (index < leadingBlanks) {
            return const SizedBox();
          }
          final day = index - leadingBlanks + 1;
          final isSelected = day == selectedDay;
          final isToday = isCurrentMonth && day == now.day;
          final hasRepayBadge = repaymentDays.contains(day);
          final summary = dailyMap[day];

          return InkWell(
            key: Key('calendar-cell-$day'),
            onTap: () => setState(() => _selectedDay = day),
            borderRadius: BorderRadius.circular(8),
            child: Container(
              margin: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: isSelected
                    ? theme.colorScheme.primaryContainer
                    : (isToday
                          ? theme.colorScheme.primary.withValues(alpha: 0.08)
                          : null),
                borderRadius: BorderRadius.circular(8),
                border: isSelected
                    ? Border.all(color: theme.colorScheme.primary, width: 1.5)
                    : (isToday
                          ? Border.all(
                              color: theme.colorScheme.primary.withValues(
                                alpha: 0.5,
                              ),
                            )
                          : null),
              ),
              child: Stack(
                children: [
                  // Repayment badge ("还")
                  if (hasRepayBadge)
                    Positioned(
                      top: 1,
                      right: 2,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 2,
                          vertical: 0.5,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.red.shade600,
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: const Text(
                          '还',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 8,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  // Day content (detailed view: day number + daily amounts)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 2,
                      vertical: 2,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '$day',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: isToday || isSelected
                                ? FontWeight.bold
                                : FontWeight.normal,
                            color: isSelected
                                ? theme.colorScheme.onPrimaryContainer
                                : null,
                          ),
                        ),
                        const SizedBox(height: 1),
                        // Detailed view: expense
                        if (summary != null &&
                            summary.incomeExpense.expense != BigInt.zero)
                          Text(
                            '-${formatMinor(summary.incomeExpense.expense)}',
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 9,
                              color: Colors.red.shade700,
                              fontWeight: FontWeight.w500,
                            ),
                          )
                        // Detailed view: income
                        else if (summary != null &&
                            summary.incomeExpense.income != BigInt.zero)
                          Text(
                            '+${formatMinor(summary.incomeExpense.income)}',
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 9,
                              color: Colors.green.shade700,
                              fontWeight: FontWeight.w500,
                            ),
                          )
                        // Records present but amounts net to 0 (e.g. transfers, excludeExIn)
                        else if (summary != null && summary.hasRecords)
                          Center(
                            child: Container(
                              width: 4,
                              height: 4,
                              decoration: BoxDecoration(
                                color: Colors.grey.shade400,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSelectedDayHeader(
    BuildContext context,
    CalendarMonth month,
    AsyncValue<Map<int, CalendarDailySummary<LedgerRecord>>> summariesAsync,
    int selectedDay,
  ) {
    final theme = Theme.of(context);
    final dayDt = DateTime(month.year, month.month, selectedDay);
    const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    final weekdayName = weekdays[(dayDt.weekday - 1) % 7];

    final summary =
        summariesAsync.value?[selectedDay]?.incomeExpense ?? IncomeExpense.zero;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
      child: Row(
        children: [
          Text(
            '${month.month}月$selectedDay日 $weekdayName',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const Spacer(),
          if (summary.expense != BigInt.zero) ...[
            Text(
              '支出 ¥${formatMinor(summary.expense)}',
              style: TextStyle(fontSize: 12, color: Colors.red.shade700),
            ),
            const SizedBox(width: 8),
          ],
          if (summary.income != BigInt.zero)
            Text(
              '收入 ¥${formatMinor(summary.income)}',
              style: TextStyle(fontSize: 12, color: Colors.green.shade700),
            ),
        ],
      ),
    );
  }

  Widget _buildSelectedDayRecords(
    BuildContext context,
    AsyncValue<Map<int, CalendarDailySummary<LedgerRecord>>> summariesAsync,
    int selectedDay,
    List<RecordCategory> categories,
    List<Asset> assets,
  ) {
    return summariesAsync.when(
      data: (dailyMap) {
        final records = dailyMap[selectedDay]?.records ?? const [];
        if (records.isEmpty) {
          return const Center(child: Text('当日无账单'));
        }
        return ListView.builder(
          key: Key('calendar-day-records-$selectedDay'),
          itemCount: records.length,
          itemBuilder: (context, index) {
            final r = records[index];
            final label = recordLabel(r, categories, assets);
            return ListTile(
              key: Key('calendar-record-${r.recordId}'),
              leading: CircleAvatar(child: Text(label.title.characters.first)),
              title: Text(label.title),
              subtitle: label.subtitle.isEmpty ? null : Text(label.subtitle),
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
            );
          },
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => ErrorView(err),
    );
  }
}
