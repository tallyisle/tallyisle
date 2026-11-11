import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/rules/budget_rules.dart';
import '../common/common.dart';
import 'budget_providers.dart';

/// Overview card displayed on Home or Statistics page.
class BudgetSummaryCard extends ConsumerStatefulWidget {
  const BudgetSummaryCard({super.key, this.onTap});

  final VoidCallback? onTap;

  @override
  ConsumerState<BudgetSummaryCard> createState() => _BudgetSummaryCardState();
}

class _BudgetSummaryCardState extends ConsumerState<BudgetSummaryCard> {
  var _autoCarryoverChecked = false;

  void _checkAutoCarryover(WidgetRef ref) {
    if (_autoCarryoverChecked) return;
    final bookAsync = ref.read(currentBookProvider);
    final modeAsync = ref.read(budgetModeProvider);
    final periodAsync = ref.read(budgetPeriodProvider);

    if (bookAsync.hasValue &&
        bookAsync.value != null &&
        modeAsync.hasValue &&
        periodAsync.hasValue) {
      _autoCarryoverChecked = true;
      final book = bookAsync.value!;
      final mode = modeAsync.value!;
      final period = periodAsync.value!;
      final service = ref.read(budgetServiceProvider).value;
      if (service != null) {
        service.ensureAutoCarryoverIfNeeded(
          commandId:
              'auto-carryover-${book.id}-${mode.value}-${period.monthlySection}',
          bookId: book.id,
          mode: mode,
          currentPeriod: period,
          startDay: book.startDay,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(budgetOverviewProvider, (_, next) {
      if (next.hasValue) {
        _checkAutoCarryover(ref);
      }
    });

    final overviewAsync = ref.watch(budgetOverviewProvider);

    return overviewAsync.when(
      loading: () => const Card(
        key: Key('budget_summary_card'),
        margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Center(
            child: SizedBox(
              height: 24,
              width: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      ),
      error: (e, _) => Card(
        key: const Key('budget_summary_card'),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('加载预算失败: ${safeMessage(e)}'),
        ),
      ),
      data: (overview) {
        final totalBudget = overview.totalBudget;
        final totalUsage = overview.totalUsage;

        if (totalBudget == null || totalUsage == null) {
          // No budget set for current period
          return Card(
            key: const Key('budget_summary_card'),
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: widget.onTap,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const Icon(
                      Icons.pie_chart_outline,
                      color: Colors.blueGrey,
                      size: 32,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            overview.mode == BudgetMode.yearly
                                ? '${overview.period.year}年预算'
                                : '${overview.period.year}年${overview.period.month}月预算',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            '未设置当期预算',
                            key: Key('budget_empty_prompt'),
                            style: TextStyle(color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                    FilledButton.tonal(
                      onPressed: widget.onTap,
                      child: const Text('去设置'),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        final isOverspent = totalUsage.isOverspent;
        final percent = totalUsage.percent;
        final progress = (percent / 100.0).clamp(0.0, 1.0);

        return Card(
          key: const Key('budget_summary_card'),
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        overview.mode == BudgetMode.yearly
                            ? '${overview.period.year}年总预算'
                            : '${overview.period.year}年${overview.period.month}月总预算',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        '¥${formatMinor(totalBudget.amountMinor)}',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      key: const Key('budget_progress_bar'),
                      value: progress,
                      minHeight: 8,
                      backgroundColor: Colors.grey.withAlpha(50),
                      valueColor: AlwaysStoppedAnimation<Color>(
                        isOverspent
                            ? Colors.red
                            : Theme.of(context).primaryColor,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '已用: ¥${formatMinor(totalUsage.displayUsedMinor)}',
                        key: const Key('budget_used_text'),
                        style: const TextStyle(
                          fontSize: 13,
                          color: Colors.grey,
                        ),
                      ),
                      Text(
                        '${percent.toStringAsFixed(1)}%',
                        key: const Key('budget_percent_text'),
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: isOverspent ? Colors.red : null,
                        ),
                      ),
                      Text(
                        isOverspent
                            ? '超支: ¥${formatMinor(-totalUsage.remainingMinor)}'
                            : '剩余: ¥${formatMinor(totalUsage.remainingMinor)}',
                        key: const Key('budget_remaining_text'),
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: isOverspent ? Colors.red : Colors.green[700],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Real-time budget hint displayed in the record editor above the keyboard (F-006 R2, R4, R6).
class RecordBudgetHintBar extends ConsumerWidget {
  const RecordBudgetHintBar({
    super.key,
    required this.bookId,
    required this.recordTime,
    required this.categoryId,
    required this.excludeBudget,
  });

  final int bookId;
  final int recordTime;
  final int categoryId;
  final bool excludeBudget;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (excludeBudget || categoryId <= 0) {
      return const SizedBox.shrink();
    }

    final query = RecordBudgetHintQuery(
      bookId: bookId,
      recordTime: recordTime,
      categoryId: categoryId,
    );

    final hintAsync = ref.watch(recordBudgetHintProvider(query));

    return hintAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (usage) {
        if (usage == null) return const SizedBox.shrink();

        final isSaving = usage.budgetType == BudgetTypeCode.savingCategory;
        final isTotal = usage.budgetType == BudgetTypeCode.total;
        final label = isTotal ? '总预算' : (isSaving ? '储蓄目标' : '分类预算');

        final String text;
        final Color textColor;

        if (isSaving) {
          text =
              '$label: 目标 ¥${formatMinor(usage.amountMinor)}，已存 ¥${formatMinor(usage.displayUsedMinor)}，待存 ¥${formatMinor(usage.remainingMinor)}';
          textColor = Colors.teal[800]!;
        } else if (usage.isOverspent) {
          text =
              '$label: 已超支 ¥${formatMinor(-usage.remainingMinor)} (${usage.percent.toStringAsFixed(1)}%)';
          textColor = Colors.red[800]!;
        } else {
          text =
              '$label: 剩余 ¥${formatMinor(usage.remainingMinor)} (${usage.percent.toStringAsFixed(1)}%)';
          textColor = Colors.green[800]!;
        }

        return Container(
          key: const Key('record_budget_hint_bar'),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          color: usage.isOverspent
              ? Colors.red.withAlpha(25)
              : (isSaving
                    ? Colors.teal.withAlpha(25)
                    : Colors.blueGrey.withAlpha(25)),
          child: Row(
            children: [
              Icon(
                usage.isOverspent
                    ? Icons.warning_amber_rounded
                    : Icons.pie_chart_outline,
                size: 16,
                color: textColor,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(
                    fontSize: 12,
                    color: textColor,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
