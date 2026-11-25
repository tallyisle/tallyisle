import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/database.dart';
import '../../domain/rules/reconciliation.dart';
import '../common/common.dart';
import 'asset_flow_providers.dart';

Color _tonalCardColor(ThemeData theme) {
  final scheme = theme.colorScheme;
  return theme.brightness == Brightness.dark
      ? scheme.surfaceContainerLow
      : Color.lerp(scheme.surfaceContainerLow, scheme.surfaceContainer, 0.55)!;
}

/// Natural-month statement summary tab for fund accounts on the account detail
/// page (parallel to `CreditSection`).
///
/// Features:
/// - Default folding of zero-record months while always keeping the current
///   month visible at the top.
/// - Responsive 2-column grid on wide viewports (`>= 540px`) and 1-column stack
///   on phones / narrow windows.
/// - Tapping any monthly card jumps back to `流水明细` filtered to that month.
class FundMonthlySection extends ConsumerStatefulWidget {
  const FundMonthlySection({
    super.key,
    required this.asset,
    this.selectedMonth,
    this.onSelectMonth,
  });

  final Asset asset;
  final NaturalMonthPeriod? selectedMonth;
  final ValueChanged<NaturalMonthPeriod>? onSelectMonth;

  @override
  ConsumerState<FundMonthlySection> createState() => _FundMonthlySectionState();
}

class _FundMonthlySectionState extends ConsumerState<FundMonthlySection> {
  bool _showEmptyMonths = false;

  @override
  void didUpdateWidget(covariant FundMonthlySection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.id != widget.asset.id) {
      _showEmptyMonths = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final asset = widget.asset;
    final theme = Theme.of(context);
    final cardColor = _tonalCardColor(theme);
    final cardShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
    );
    final recordsAsync = ref.watch(assetRecordsProvider(asset.id));
    final statements = ref.watch(fundMonthlyStatementsProvider(asset.id));

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: recordsAsync.when(
        loading: () => const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: CircularProgressIndicator(),
          ),
        ),
        error: (e, _) => Card(
          margin: EdgeInsets.zero,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          color: cardColor,
          clipBehavior: Clip.antiAlias,
          shape: cardShape,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text('月度账单加载出错: ${safeMessage(e)}'),
          ),
        ),
        data: (_) {
          if (statements.isEmpty) {
            return Card(
              margin: EdgeInsets.zero,
              elevation: 0,
              surfaceTintColor: Colors.transparent,
              color: cardColor,
              clipBehavior: Clip.antiAlias,
              shape: cardShape,
              child: const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: Text('本年度暂无账单数据')),
              ),
            );
          }

          final filtered = filterVisibleFundMonthlyStatements(
            statements: statements,
            today: DateTime.now(),
            includeEmpty: _showEmptyMonths,
          );
          final visible = filtered.visible;
          final hiddenEmptyCount = filtered.hiddenEmptyCount;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (visible.isEmpty)
                Card(
                  margin: EdgeInsets.zero,
                  elevation: 0,
                  surfaceTintColor: Colors.transparent,
                  color: cardColor,
                  clipBehavior: Clip.antiAlias,
                  shape: cardShape,
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Center(
                      child: Text(
                        '本年度暂无流水记录（已收起 $hiddenEmptyCount 个空白月）',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                )
              else
                LayoutBuilder(
                  builder: (context, constraints) {
                    final twoColumn = constraints.maxWidth >= 540;
                    if (!twoColumn) {
                      return Column(
                        children: [
                          for (final item in visible)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: _FundMonthlyCard(
                                item: item,
                                selected: widget.selectedMonth == item.period,
                                onTap: widget.onSelectMonth == null
                                    ? null
                                    : () => widget.onSelectMonth!(item.period),
                              ),
                            ),
                        ],
                      );
                    }

                    final rows = <Widget>[];
                    for (var i = 0; i < visible.length; i += 2) {
                      final leftItem = visible[i];
                      final rightItem = i + 1 < visible.length
                          ? visible[i + 1]
                          : null;
                      rows.add(
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 5),
                          child: IntrinsicHeight(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(
                                  child: _FundMonthlyCard(
                                    item: leftItem,
                                    selected:
                                        widget.selectedMonth == leftItem.period,
                                    onTap: widget.onSelectMonth == null
                                        ? null
                                        : () => widget.onSelectMonth!(
                                            leftItem.period,
                                          ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: rightItem == null
                                      ? const SizedBox.shrink()
                                      : _FundMonthlyCard(
                                          item: rightItem,
                                          selected:
                                              widget.selectedMonth ==
                                              rightItem.period,
                                          onTap: widget.onSelectMonth == null
                                              ? null
                                              : () => widget.onSelectMonth!(
                                                  rightItem.period,
                                                ),
                                        ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }
                    return Column(
                      key: const Key('fund-statements-two-column-grid'),
                      children: rows,
                    );
                  },
                ),
              if (hiddenEmptyCount > 0) ...[
                const SizedBox(height: 6),
                Center(
                  child: TextButton.icon(
                    key: const Key('fund-toggle-empty-months'),
                    onPressed: () =>
                        setState(() => _showEmptyMonths = !_showEmptyMonths),
                    icon: Icon(
                      _showEmptyMonths
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 18,
                    ),
                    label: Text(
                      _showEmptyMonths
                          ? '收起无流水月份'
                          : '展开全年 12 个月（已收起 $hiddenEmptyCount 个空白月）',
                    ),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _FundMonthlyCard extends StatelessWidget {
  const _FundMonthlyCard({
    required this.item,
    this.selected = false,
    this.onTap,
  });

  final FundMonthlyStatementItem item;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final p = item.period;
    final net = item.netDelta;

    final String netText;
    final Color netBg;
    final Color netFg;
    if (net > BigInt.zero) {
      netText = '+${formatMinor(net)}';
      netBg = isDark
          ? Colors.green.shade900.withValues(alpha: 0.45)
          : Colors.green.shade50;
      netFg = isDark ? Colors.green.shade200 : Colors.green.shade800;
    } else if (net < BigInt.zero) {
      netText = '-${formatMinor(-net)}';
      netBg = scheme.surfaceContainerHighest;
      netFg = scheme.onSurface;
    } else {
      netText = '0.00';
      netBg = scheme.surfaceContainerHighest;
      netFg = scheme.onSurfaceVariant;
    }

    final inflowColor = item.inflow > BigInt.zero
        ? (isDark ? Colors.green.shade300 : Colors.green.shade700)
        : null;

    final baseColor = _tonalCardColor(theme);
    final fillColor = selected
        ? Color.lerp(baseColor, scheme.primaryContainer, 0.45)!
        : baseColor;

    return Card(
      key: Key('fund-statement-card-${p.year}-${p.month}'),
      margin: EdgeInsets.zero,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      color: fillColor,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      '${p.month}月账单',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  if (item.isCurrentMonth) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.primaryContainer,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '本月',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onPrimaryContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                  const Spacer(),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 120),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: netBg,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          netText,
                          maxLines: 1,
                          softWrap: false,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: netFg,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (onTap != null) ...[
                    const SizedBox(width: 4),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: scheme.outline,
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${formatDate(p.start)} 至 ${formatDate(p.end)} · ${item.recordCount} 笔',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _FundMetricCell(
                      label: '本月流入',
                      value: formatMinor(item.inflow),
                      valueColor: inflowColor,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _FundMetricCell(
                      label: '本月流出',
                      value: formatMinor(item.outflow),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _FundMetricCell(
                      label: '月末余额',
                      value: item.endingBalance == null
                          ? '—'
                          : formatMinor(item.endingBalance!),
                      bold: item.endingBalance != null,
                      valueColor: item.endingBalance == null
                          ? scheme.onSurfaceVariant
                          : null,
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

class _FundMetricCell extends StatelessWidget {
  const _FundMetricCell({
    required this.label,
    required this.value,
    this.bold = false,
    this.valueColor,
  });

  final String label;
  final String value;
  final bool bold;
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
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            maxLines: 1,
            softWrap: false,
            style: theme.textTheme.bodyLarge?.copyWith(
              fontWeight: bold ? FontWeight.bold : FontWeight.w500,
              color: valueColor,
            ),
          ),
        ),
      ],
    );
  }
}
