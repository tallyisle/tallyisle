import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../domain/rules/billing_period.dart';
import '../../domain/rules/budget_rules.dart';
import '../backup/backup_providers.dart';
import '../common/common.dart';
import 'budget_providers.dart';

/// Borderless tonal fill shared by every 16dp card on budget / stats pages.
Color tonalCardColor(BuildContext context) {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  return theme.brightness == Brightness.dark
      ? scheme.surfaceContainerLow
      : Color.lerp(scheme.surfaceContainerLow, scheme.surfaceContainer, 0.55)!;
}

/// Fill for a 12dp nested sub-block placed inside a [tonalCardColor] card.
Color tonalNestedColor(BuildContext context) {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  return theme.brightness == Brightness.dark
      ? scheme.surfaceContainerHigh.withValues(alpha: 0.65)
      : scheme.surfaceContainerHighest.withValues(alpha: 0.45);
}

/// Overview card displayed on Home, Statistics, or Budget management page.
class BudgetSummaryCard extends ConsumerStatefulWidget {
  const BudgetSummaryCard({
    super.key,
    this.onTap,
    this.hideWhenEmpty = false,
    this.enablePeriodControls = false,
    this.fixedOffset,
    this.margin,
    this.color,
  });

  final VoidCallback? onTap;
  final bool hideWhenEmpty;
  final bool enablePeriodControls;
  final int? fixedOffset;

  /// Outer margin of the card. Defaults to the 16px page gutter; pass
  /// [EdgeInsets.zero] when the parent already supplies horizontal padding.
  final EdgeInsetsGeometry? margin;

  /// Optional fill override (e.g. a nested tonal block inside a section card).
  final Color? color;

  @override
  ConsumerState<BudgetSummaryCard> createState() => _BudgetSummaryCardState();
}

class _BudgetSummaryCardState extends ConsumerState<BudgetSummaryCard> {
  final Set<String> _checkedCarryoverKeys = <String>{};
  BudgetOverview? _cachedOverview;
  int? _cachedBookId;

  void _checkAutoCarryover(WidgetRef ref, int effectiveOffset) {
    if (effectiveOffset != 0) return;
    if (ref.read(initialStartupSyncPendingProvider) ||
        (ref.read(cloudSyncInProgressProvider).value ?? false)) {
      return;
    }
    final bookAsync = ref.read(currentBookProvider);
    final modeAsync = ref.read(budgetModeProvider);
    final serviceAsync = ref.read(budgetServiceProvider);
    if (bookAsync.isLoading || modeAsync.isLoading || serviceAsync.isLoading) {
      return;
    }
    final book = bookAsync.value;
    final mode = modeAsync.value;
    final service = serviceAsync.value;

    if (book != null && mode != null && service != null) {
      final now = DateTime.now();
      final period = mode == BudgetMode.yearly
          ? BillingPeriod.containingYear(now, book.startDay)
          : BillingPeriod.containing(now, book.startDay);
      final section = mode.sectionFor(period);
      final key = '${book.id}-${mode.value}-$section';
      if (!_checkedCarryoverKeys.add(key)) return;
      final backupSvc = ref.read(tallyBackupServiceProvider).value;
      unawaited(
        backupSvc != null
            ? backupSvc.runInSilentMaintenanceScope(
                () => service.ensureAutoCarryoverIfNeeded(
                  commandId: 'auto-carryover-$key',
                  bookId: book.id,
                  mode: mode,
                  currentPeriod: period,
                  startDay: book.startDay,
                ),
              )
            : service.ensureAutoCarryoverIfNeeded(
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
                  maxLines: 1,
                  softWrap: false,
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
      if (next.hasValue && !next.isLoading) {
        _checkAutoCarryover(ref, effectiveOffset);
      }
    });
    ref.listen<bool>(initialStartupSyncPendingProvider, (prev, next) {
      if (prev == true && !next && mounted) {
        _checkAutoCarryover(ref, effectiveOffset);
      }
    });
    ref.listen<AsyncValue<bool>>(cloudSyncInProgressProvider, (_, next) {
      if (next.value == false && mounted) {
        _checkAutoCarryover(ref, effectiveOffset);
      }
    });

    final overviewAsync = ref.watch(targetProvider);
    if (overviewAsync.hasValue) {
      _cachedOverview = overviewAsync.value;
      if (effectiveOffset == 0 && !overviewAsync.isLoading) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _checkAutoCarryover(ref, effectiveOffset);
          }
        });
      }
    }

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final cardMargin =
        widget.margin ??
        const EdgeInsets.symmetric(horizontal: 16, vertical: 6);
    final cardColor =
        widget.color ??
        (isDark
            ? scheme.surfaceContainerLow
            : Color.lerp(
                scheme.surfaceContainerLow,
                scheme.surfaceContainer,
                0.55,
              )!);

    if (overviewAsync.hasError && _cachedOverview == null) {
      return widget.hideWhenEmpty
          ? const SizedBox.shrink()
          : Card(
              key: const Key('budget_summary_card'),
              elevation: 0,
              surfaceTintColor: Colors.transparent,
              clipBehavior: Clip.antiAlias,
              color: cardColor,
              margin: cardMargin,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
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
          : Card(
              key: const Key('budget_summary_card'),
              elevation: 0,
              surfaceTintColor: Colors.transparent,
              clipBehavior: Clip.antiAlias,
              color: cardColor,
              margin: cardMargin,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Padding(
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
        return Card(
          key: const Key('budget_summary_card'),
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          clipBehavior: Clip.antiAlias,
          color: cardColor,
          margin: cardMargin,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
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
                      TallySoftButton(
                        compact: true,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        onPressed: widget.onTap,
                        child: const FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text('去设置', maxLines: 1, softWrap: false),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(
                        Icons.pie_chart_outline,
                        color: scheme.onSurfaceVariant,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          effectiveOffset == 0 ? '未设置当期预算' : '该期未设置预算',
                          key: const Key('budget_empty_prompt'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: scheme.onSurfaceVariant,
                          ),
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
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        color: cardColor,
        margin: cardMargin,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(
                  Icons.pie_chart_outline,
                  color: scheme.onSurfaceVariant,
                  size: 32,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        emptyTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '未设置当期预算',
                        key: const Key('budget_empty_prompt'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                TallySoftButton(
                  compact: true,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  onPressed: widget.onTap,
                  child: const FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text('去设置', maxLines: 1, softWrap: false),
                  ),
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
    final semanticRed = isDark ? Colors.red.shade300 : Colors.red.shade700;
    final semanticGreen = isDark
        ? Colors.green.shade300
        : Colors.green.shade700;

    return Card(
      key: const Key('budget_summary_card'),
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      color: cardColor,
      margin: cardMargin,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
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
                    Expanded(
                      child: Text(
                        populatedTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 128),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Text(
                        '¥${formatMinor(totalBudget.amountMinor)}',
                        maxLines: 1,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
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
                  backgroundColor: scheme.surfaceContainerHighest,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    isOverspent ? scheme.error : scheme.primary,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          '已用: ¥${formatMinor(totalUsage.displayUsedMinor)}',
                          key: const Key('budget_used_text'),
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 13,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      '${percent.toStringAsFixed(1)}%',
                      key: const Key('budget_percent_text'),
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: isOverspent ? semanticRed : scheme.onSurface,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          isOverspent
                              ? '超支: ¥${formatMinor(-totalUsage.remainingMinor)}'
                              : '剩余: ¥${formatMinor(totalUsage.remainingMinor)}',
                          key: const Key('budget_remaining_text'),
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: isOverspent ? semanticRed : semanticGreen,
                          ),
                        ),
                      ),
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

    final hintAsync = ref.watch(resolvedRecordBudgetHintProvider(query));

    return hintAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (resolved) {
        if (resolved == null) return const SizedBox.shrink();
        final usage = resolved.usage;

        final isDark = Theme.of(context).brightness == Brightness.dark;
        final bgAlpha = isDark ? 45 : 25;
        final isSaving = usage.budgetType == BudgetTypeCode.savingCategory;
        final isTotal = usage.budgetType == BudgetTypeCode.total;
        final periodPrefix = resolved.mode == BudgetMode.yearly ? '年' : '月';
        final label = isTotal
            ? '${periodPrefix}总预算'
            : (isSaving ? '${periodPrefix}储蓄目标' : '${periodPrefix}分类预算');

        final String text;
        final Color textColor;
        final Color bgColor;

        if (isSaving) {
          text =
              '$label: 目标 ¥${formatMinor(usage.amountMinor)}，已存 ¥${formatMinor(usage.displayUsedMinor)}，待存 ¥${formatMinor(usage.remainingMinor)}';
          textColor = isDark ? Colors.teal.shade200 : Colors.teal.shade800;
          bgColor = Colors.teal.withAlpha(bgAlpha);
        } else if (usage.isOverspent) {
          text =
              '$label: 已超支 ¥${formatMinor(-usage.remainingMinor)} (${usage.percent.toStringAsFixed(1)}%)';
          textColor = isDark ? Colors.red.shade300 : Colors.red.shade800;
          bgColor = Colors.red.withAlpha(bgAlpha);
        } else {
          text =
              '$label: 剩余 ¥${formatMinor(usage.remainingMinor)} (${usage.percent.toStringAsFixed(1)}%)';
          textColor = isDark ? Colors.green.shade300 : Colors.green.shade800;
          bgColor = Colors.green.withAlpha(bgAlpha);
        }

        return Container(
          key: const Key('record_budget_hint_bar'),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          color: bgColor,
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
                  maxLines: 1,
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
