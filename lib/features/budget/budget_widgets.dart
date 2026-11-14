import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/rules/billing_period.dart';
import '../../domain/rules/budget_rules.dart';
import '../common/common.dart';
import 'budget_providers.dart';

/// Overview card displayed on Home, Statistics, or Budget management page.
class BudgetSummaryCard extends ConsumerStatefulWidget {
  const BudgetSummaryCard({
    super.key,
    this.onTap,
    this.hideWhenEmpty = false,
    this.enablePeriodControls = false,
    this.fixedOffset,
  });

  final VoidCallback? onTap;
  final bool hideWhenEmpty;
  final bool enablePeriodControls;
  final int? fixedOffset;

  @override
  ConsumerState<BudgetSummaryCard> createState() => _BudgetSummaryCardState();
}

class _BudgetSummaryCardState extends ConsumerState<BudgetSummaryCard> {
  final Set<String> _checkedCarryoverKeys = <String>{};
  BudgetOverview? _cachedOverview;
  int? _cachedBookId;

  void _checkAutoCarryover(WidgetRef ref, int effectiveOffset) {
    if (effectiveOffset != 0) return;
    final book = ref.read(currentBookProvider).value;
    final mode = ref.read(budgetModeProvider).value;
    final period = ref.read(budgetPeriodForOffsetProvider(0)).value;
    final service = ref.read(budgetServiceProvider).value;

    if (book != null && mode != null && period != null && service != null) {
      final section = mode.sectionFor(period);
      final key = '${book.id}-${mode.value}-$section';
      if (!_checkedCarryoverKeys.add(key)) return;
      unawaited(
        service.ensureAutoCarryoverIfNeeded(
          commandId: 'auto-carryover-$key',
          bookId: book.id,
          mode: mode,
          currentPeriod: period,
          startDay: book.startDay,
        ),
      );
    }
  }

  BillingPeriod _previewPeriodForOffset({
    required BudgetMode mode,
    required int startDay,
    required int offset,
  }) {
    final now = DateTime.now();
    if (mode == BudgetMode.yearly) {
      final currentYearPeriod = BillingPeriod.containingYear(now, startDay);
      return BillingPeriod.year(currentYearPeriod.year + offset, startDay);
    }
    final currentMonthPeriod = BillingPeriod.containing(now, startDay);
    return BillingPeriod.starting(
      currentMonthPeriod.year,
      currentMonthPeriod.month + offset,
      startDay,
    );
  }

  Widget _buildInlinePeriodTitle(
    BuildContext context, {
    required String titleText,
    required BudgetMode mode,
    required int effectiveOffset,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final resetLabel = mode == BudgetMode.yearly ? '回今年' : '回本月';

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 28,
          height: 28,
          child: IconButton(
            key: const Key('budget_card_period_prev'),
            tooltip: '上一期',
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            iconSize: 20,
            icon: const Icon(Icons.chevron_left_rounded),
            onPressed: () => ref.read(budgetOffsetProvider.notifier).previous(),
          ),
        ),
        Flexible(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Text(
              titleText,
              key: const Key('budget_card_period_label'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        SizedBox(
          width: 28,
          height: 28,
          child: IconButton(
            key: const Key('budget_card_period_next'),
            tooltip: '下一期',
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            iconSize: 20,
            icon: const Icon(Icons.chevron_right_rounded),
            onPressed: () => ref.read(budgetOffsetProvider.notifier).next(),
          ),
        ),
        if (effectiveOffset != 0) ...[
          const SizedBox(width: 4),
          Material(
            color: scheme.primaryContainer.withValues(alpha: 0.75),
            borderRadius: BorderRadius.circular(999),
            child: InkWell(
              key: const Key('budget_card_period_reset'),
              borderRadius: BorderRadius.circular(999),
              onTap: () => ref.read(budgetOffsetProvider.notifier).reset(),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                child: Text(
                  resetLabel,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final int effectiveOffset =
        widget.fixedOffset ?? ref.watch<int>(budgetOffsetProvider);
    final book = ref.watch(currentBookProvider).value;
    final bookId = book?.id;
    if (_cachedBookId != bookId) {
      _cachedBookId = bookId;
      _cachedOverview = null;
    }

    final targetProvider = budgetOverviewForOffsetProvider(effectiveOffset);
    ref.listen(targetProvider, (_, next) {
      if (next.hasValue) {
        _checkAutoCarryover(ref, effectiveOffset);
      }
    });

    final overviewAsync = ref.watch(targetProvider);
    if (overviewAsync.hasValue) {
      _cachedOverview = overviewAsync.value;
      if (effectiveOffset == 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _checkAutoCarryover(ref, effectiveOffset);
          }
        });
      }
    }

    if (overviewAsync.hasError && _cachedOverview == null) {
      return widget.hideWhenEmpty
          ? const SizedBox.shrink()
          : Card(
              key: const Key('budget_summary_card'),
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text('加载预算失败: ${safeMessage(overviewAsync.error!)}'),
              ),
            );
    }

    final overview = overviewAsync.value ?? _cachedOverview;
    if (overview == null) {
      return widget.hideWhenEmpty
          ? const SizedBox.shrink()
          : const Card(
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
            );
    }

    final displayMode = ref.watch(budgetModeProvider).value ?? overview.mode;
    final displayPeriod = overviewAsync.hasValue
        ? overview.period
        : _previewPeriodForOffset(
            mode: displayMode,
            startDay: book?.startDay ?? 1,
            offset: effectiveOffset,
          );

    final totalBudget = overview.totalBudget;
    final totalUsage = overview.totalUsage;

    if (totalBudget == null || totalUsage == null) {
      if (widget.hideWhenEmpty) return const SizedBox.shrink();
      final emptyTitle = displayMode == BudgetMode.yearly
          ? '${displayPeriod.year}年预算'
          : '${displayPeriod.year}年${displayPeriod.month}月预算';

      if (widget.enablePeriodControls) {
        final theme = Theme.of(context);
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
                    children: [
                      Expanded(
                        child: _buildInlinePeriodTitle(
                          context,
                          titleText: emptyTitle,
                          mode: displayMode,
                          effectiveOffset: effectiveOffset,
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.tonal(
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: widget.onTap,
                        child: const Text('去设置'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(
                        Icons.pie_chart_outline,
                        color: theme.colorScheme.onSurfaceVariant,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        effectiveOffset == 0 ? '未设置当期预算' : '该期未设置预算',
                        key: const Key('budget_empty_prompt'),
                        style: TextStyle(
                          fontSize: 13,
                          color: theme.colorScheme.onSurfaceVariant,
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

      // No budget set for selected period (standard non-stepping card)
      return Card(
        key: const Key('budget_summary_card'),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
                        emptyTitle,
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
    final populatedTitle = displayMode == BudgetMode.yearly
        ? '${displayPeriod.year}年总预算'
        : '${displayPeriod.year}年${displayPeriod.month}月总预算';

    return Card(
      key: const Key('budget_summary_card'),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
                  if (widget.enablePeriodControls)
                    Expanded(
                      child: _buildInlinePeriodTitle(
                        context,
                        titleText: populatedTitle,
                        mode: displayMode,
                        effectiveOffset: effectiveOffset,
                      ),
                    )
                  else
                    Flexible(
                      child: Text(
                        populatedTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  const SizedBox(width: 8),
                  Text(
                    '¥${formatMinor(totalBudget.amountMinor)}',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
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
                    isOverspent ? Colors.red : Theme.of(context).primaryColor,
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
                    style: const TextStyle(fontSize: 13, color: Colors.grey),
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
