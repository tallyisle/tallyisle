import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/db/database.dart';
import '../../domain/ledger/asset_json.dart';
import '../../domain/rules/credit_cycle.dart';
import '../common/common.dart';
import 'asset_detail_page.dart';
import 'credit_providers.dart';

String _formatShortDate(DateTime d) => '${two(d.month)}-${two(d.day)}';

/// Prominent banner for the earliest issued unpaid/overdue credit statement
/// (docs/modules/credit-account.md R5). Rendered right beneath the compact
/// header card when present, and takes zero space otherwise.
class CreditPendingBanner extends StatelessWidget {
  const CreditPendingBanner({
    super.key,
    required this.asset,
    required this.banner,
    this.onRepay,
  });

  final Asset asset;
  final CreditPendingBannerInfo banner;
  final ValueChanged<BigInt>? onRepay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isOverdue = banner.isOverdue;
    final bgColor = isOverdue
        ? theme.colorScheme.errorContainer
        : theme.colorScheme.secondaryContainer;
    final fgColor = isOverdue
        ? theme.colorScheme.onErrorContainer
        : theme.colorScheme.onSecondaryContainer;

    return Card(
      key: const Key('credit-pending-banner'),
      color: bgColor,
      elevation: 0,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(
              isOverdue ? Icons.warning_rounded : Icons.notifications_active,
              size: 20,
              color: fgColor,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '第 ${banner.period.periodIndex} 期账单待还 ${formatMinor(banner.remainingAmount)}',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: fgColor,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (isOverdue)
                    Text(
                      '已逾期 ${banner.overdueDays} 天',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: fgColor,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              key: const Key('credit-banner-repay'),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              onPressed: () {
                if (onRepay != null) {
                  onRepay!(banner.remainingAmount);
                } else {
                  context.push(repayRoute(asset, banner.remainingAmount));
                }
              },
              child: const Text('立即还款'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Credit statement cycles tab content on the account detail page
/// (F-028 / docs/modules/credit-account.md).
///
/// Features:
/// - Year switcher with quick return to current year.
/// - Default folding of unstarted future empty periods so active unissued and
///   latest issued statements appear immediately at the top.
/// - Adaptive 2-column grid on wide viewports (`>= 540px`) and 1-column stack
///   on phones / narrow windows.
/// - Tapping any statement card filters the account's flow list to that cycle.
class CreditSection extends ConsumerStatefulWidget {
  const CreditSection({
    super.key,
    required this.asset,
    this.selectedPeriod,
    this.onSelectPeriod,
    this.onConfigureTap,
    this.onRepayAmount,
  });

  final Asset asset;
  final CreditStatementPeriod? selectedPeriod;
  final ValueChanged<CreditStatementPeriod>? onSelectPeriod;
  final VoidCallback? onConfigureTap;
  final ValueChanged<BigInt>? onRepayAmount;

  @override
  ConsumerState<CreditSection> createState() => _CreditSectionState();
}

class _CreditSectionState extends ConsumerState<CreditSection> {
  bool _showFutureEmpty = false;

  @override
  void didUpdateWidget(covariant CreditSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.id != widget.asset.id) {
      _showFutureEmpty = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final asset = widget.asset;
    final info = CreditInfo.parse(asset.creditInfo);
    if (!info.configured) {
      return Card(
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Icon(Icons.info_outline),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '尚未配置账单日与还款日，请编辑卡片补充信息。',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                key: const Key('credit-configure-btn'),
                onPressed:
                    widget.onConfigureTap ??
                    () => context.push('/assets/${asset.id}/edit'),
                child: const Text('去配置'),
              ),
            ],
          ),
        ),
      );
    }

    final statementsAsync = ref.watch(creditStatementsProvider(asset));
    final selectedYear = ref.watch(creditSelectedYearProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _YearSwitcher(
            selectedYear: selectedYear,
            showFilterHint: widget.onSelectPeriod != null,
          ),
          const SizedBox(height: 6),
          statementsAsync.when(
            data: (statements) {
              if (statements.isEmpty) {
                return const Card(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: Text('本年度暂无账单数据')),
                  ),
                );
              }

              final filtered = filterVisibleCreditStatements(
                statements: statements,
                today: DateTime.now(),
                includeFutureEmpty: _showFutureEmpty,
              );
              final visible = filtered.visible;
              final futureEmptyCount = filtered.futureEmptyCount;

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (visible.isEmpty)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Center(
                          child: Text(
                            '本年度 $futureEmptyCount 期账单尚未开始',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
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
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 4,
                                  ),
                                  child: _StatementCard(
                                    asset: asset,
                                    item: item,
                                    selected: _isSamePeriod(
                                      widget.selectedPeriod,
                                      item.period,
                                    ),
                                    onTap: widget.onSelectPeriod == null
                                        ? null
                                        : () => widget.onSelectPeriod!(
                                            item.period,
                                          ),
                                    onRepayAmount: widget.onRepayAmount,
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
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Expanded(
                                      child: _StatementCard(
                                        asset: asset,
                                        item: leftItem,
                                        selected: _isSamePeriod(
                                          widget.selectedPeriod,
                                          leftItem.period,
                                        ),
                                        onTap: widget.onSelectPeriod == null
                                            ? null
                                            : () => widget.onSelectPeriod!(
                                                leftItem.period,
                                              ),
                                        onRepayAmount: widget.onRepayAmount,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: rightItem == null
                                          ? const SizedBox.shrink()
                                          : _StatementCard(
                                              asset: asset,
                                              item: rightItem,
                                              selected: _isSamePeriod(
                                                widget.selectedPeriod,
                                                rightItem.period,
                                              ),
                                              onTap:
                                                  widget.onSelectPeriod == null
                                                  ? null
                                                  : () =>
                                                        widget.onSelectPeriod!(
                                                          rightItem.period,
                                                        ),
                                              onRepayAmount:
                                                  widget.onRepayAmount,
                                            ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        }
                        return Column(
                          key: const Key('credit-statements-two-column-grid'),
                          children: rows,
                        );
                      },
                    ),
                  if (futureEmptyCount > 0) ...[
                    const SizedBox(height: 6),
                    Center(
                      child: TextButton.icon(
                        key: const Key('credit-toggle-future-periods'),
                        onPressed: () => setState(
                          () => _showFutureEmpty = !_showFutureEmpty,
                        ),
                        icon: Icon(
                          _showFutureEmpty
                              ? Icons.expand_less_rounded
                              : Icons.expand_more_rounded,
                          size: 18,
                        ),
                        label: Text(
                          _showFutureEmpty
                              ? '收起 $futureEmptyCount 期未开始空白账单'
                              : '展开其余 $futureEmptyCount 期未开始账单',
                        ),
                      ),
                    ),
                  ],
                ],
              );
            },
            loading: () => const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(),
              ),
            ),
            error: (e, _) => Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text('账单加载出错: ${safeMessage(e)}'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static bool _isSamePeriod(
    CreditStatementPeriod? a,
    CreditStatementPeriod b,
  ) => a != null && a.year == b.year && a.periodIndex == b.periodIndex;
}

class _YearSwitcher extends ConsumerWidget {
  const _YearSwitcher({
    required this.selectedYear,
    this.showFilterHint = false,
  });

  final int selectedYear;
  final bool showFilterHint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final currentYear = DateTime.now().year;
    return LayoutBuilder(
      builder: (context, constraints) {
        final canShowHint = showFilterHint && constraints.maxWidth >= 420;
        return Row(
          children: [
            IconButton(
              key: const Key('credit-year-prev'),
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.chevron_left),
              tooltip: '上一年度',
              onPressed: () =>
                  ref.read(creditSelectedYearProvider.notifier).previous(),
            ),
            Text(
              '$selectedYear 年',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            IconButton(
              key: const Key('credit-year-next'),
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.chevron_right),
              tooltip: '下一年度',
              onPressed: () =>
                  ref.read(creditSelectedYearProvider.notifier).next(),
            ),
            if (selectedYear != currentYear) ...[
              const SizedBox(width: 4),
              TextButton(
                key: const Key('credit-year-reset'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                onPressed: () =>
                    ref.read(creditSelectedYearProvider.notifier).reset(),
                child: const Text('回今年'),
              ),
            ],
            const Spacer(),
            if (canShowHint)
              Flexible(
                child: Text(
                  '点击卡片可看当期流水',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _StatementCard extends StatelessWidget {
  const _StatementCard({
    required this.asset,
    required this.item,
    this.selected = false,
    this.onTap,
    this.onRepayAmount,
  });

  final Asset asset;
  final CreditStatementItem item;
  final bool selected;
  final VoidCallback? onTap;
  final ValueChanged<BigInt>? onRepayAmount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final p = item.period;

    return Card(
      key: Key('credit-statement-card-${p.year}-${p.periodIndex}'),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: selected
            ? BorderSide(color: scheme.primary, width: 1.4)
            : BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.35)),
      ),
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
                      '第 ${p.periodIndex} 期账单',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: item.isIssued
                          ? scheme.primaryContainer
                          : scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      item.isIssued ? '已出账' : '未出账',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: item.isIssued
                            ? scheme.onPrimaryContainer
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const Spacer(),
                  if (item.isPaidOff)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.tertiaryContainer,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '已还清',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onTertiaryContainer,
                        ),
                      ),
                    )
                  else if (item.isIssued && item.remainingAmount > BigInt.zero)
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: () {
                        if (onRepayAmount != null) {
                          onRepayAmount!(item.remainingAmount);
                        } else {
                          context.push(repayRoute(asset, item.remainingAmount));
                        }
                      },
                      child: const Text('还款'),
                    )
                  else if (onTap != null)
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: scheme.outline,
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${formatDate(p.start)} 至 ${formatDate(p.end)}'
                ' · 出账 ${_formatShortDate(p.statementDate)}'
                ' · 还款 ${_formatShortDate(p.dueDate)}'
                '${item.billCount > 0 ? ' · ${item.billCount}笔' : ''}',
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
                    child: _StatementMetricCell(
                      label: '账单金额',
                      value: formatMinor(item.statementAmount),
                      bold: true,
                      footnote: item.installmentAmount > BigInt.zero
                          ? '含分期 ${formatMinor(item.installmentAmount)}'
                          : null,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _StatementMetricCell(
                      label: '已还金额',
                      value: formatMinor(item.repaidAmount),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _StatementMetricCell(
                      label: '剩余待还',
                      value: formatMinor(item.remainingAmount),
                      bold: item.remainingAmount > BigInt.zero,
                      valueColor: item.remainingAmount > BigInt.zero
                          ? scheme.error
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

class _StatementMetricCell extends StatelessWidget {
  const _StatementMetricCell({
    required this.label,
    required this.value,
    this.bold = false,
    this.valueColor,
    this.footnote,
  });

  final String label;
  final String value;
  final bool bold;
  final Color? valueColor;
  final String? footnote;

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
        if (footnote != null)
          Text(
            footnote!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.secondary,
            ),
          ),
      ],
    );
  }
}
