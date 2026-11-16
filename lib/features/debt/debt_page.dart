import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/adaptive.dart';
import '../../domain/model/codes.dart';
import '../common/common.dart';
import '../common/desktop_modal_page.dart';
import 'debt_detail_page.dart';
import 'debt_editor_page.dart';
import 'debt_providers.dart';

/// Main Debt Management page (`F-011` / original `DebtManageActivity`).
class DebtPage extends ConsumerWidget {
  const DebtPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDesktop = DesktopAdaptive.isDesktop(context);
    final allBooks = ref.watch(debtAllBooksScopeProvider);
    final selectedStatus = ref.watch(debtStatusTabProvider);
    final viewAsync = ref.watch(debtListViewProvider);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      key: const Key('debt_page'),
      appBar: AppBar(
        title: const Text('借贷管理'),
        actions: [
          Padding(
            padding: EdgeInsets.only(right: isDesktop ? 8 : 12),
            child: Center(
              child: ActionChip(
                key: const Key('debt_scope_toggle'),
                visualDensity: isDesktop ? null : VisualDensity.compact,
                avatar: Icon(
                  allBooks ? Icons.library_books_rounded : Icons.book_outlined,
                  size: 16,
                  color: allBooks
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant,
                ),
                backgroundColor: allBooks
                    ? colorScheme.primaryContainer.withValues(alpha: 0.65)
                    : colorScheme.surfaceContainerHighest.withValues(
                        alpha: 0.55,
                      ),
                side: BorderSide(
                  color: allBooks
                      ? colorScheme.primary.withValues(alpha: 0.35)
                      : colorScheme.outlineVariant.withValues(alpha: 0.5),
                ),
                label: Text(
                  allBooks ? '全部账本' : '当前账本',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: allBooks
                        ? colorScheme.primary
                        : colorScheme.onSurface,
                  ),
                ),
                onPressed: () =>
                    ref.read(debtAllBooksScopeProvider.notifier).toggle(),
              ),
            ),
          ),
          if (isDesktop)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton.tonalIcon(
                key: const Key('add_debt_button'),
                onPressed: () async {
                  await pushDesktopModalOrMaterialRoute<bool>(
                    context,
                    child: const DebtEditorPage(),
                  );
                },
                icon: const Icon(Icons.add, size: 18),
                label: const Text('新建借贷'),
              ),
            ),
        ],
      ),
      body: asyncBody(viewAsync, (view) {
        final activeTab = selectedStatus == AssetStatus.settled
            ? AssetStatus.settled
            : AssetStatus.active;
        final items = activeTab == AssetStatus.settled
            ? view.settledItems
            : view.activeItems;

        final list = ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              key: const Key('debt_summary_card'),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: 16,
                  horizontal: 12,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: _SummaryCell(
                        label: '借出应收',
                        value: formatMinor(view.summary.totalReceivableMinor),
                        valueKey: const Key('debt_total_receivable'),
                      ),
                    ),
                    Expanded(
                      child: _SummaryCell(
                        label: '借入应付',
                        value: formatMinor(view.summary.totalPayableMinor),
                        valueKey: const Key('debt_total_payable'),
                      ),
                    ),
                    Expanded(
                      child: _SummaryCell(
                        label: '净债权',
                        value: formatMinor(view.summary.netReceivableMinor),
                        valueKey: const Key('debt_net_receivable'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<int>(
                key: const Key('debt_state_tabs'),
                showSelectedIcon: false,
                style: isDesktop
                    ? const ButtonStyle(
                        padding: WidgetStatePropertyAll(
                          EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        ),
                      )
                    : const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                        padding: WidgetStatePropertyAll(
                          EdgeInsets.symmetric(horizontal: 10),
                        ),
                      ),
                segments: [
                  ButtonSegment<int>(
                    value: AssetStatus.active,
                    label: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        '进行中 (${view.activeItems.length})',
                        key: const Key('debt_tab_active'),
                        maxLines: 1,
                        softWrap: false,
                      ),
                    ),
                  ),
                  ButtonSegment<int>(
                    value: AssetStatus.settled,
                    label: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        '已结清 (${view.settledItems.length})',
                        key: const Key('debt_tab_settled'),
                        maxLines: 1,
                        softWrap: false,
                      ),
                    ),
                  ),
                ],
                selected: {activeTab},
                onSelectionChanged: (selection) => ref
                    .read(debtStatusTabProvider.notifier)
                    .select(selection.first),
              ),
            ),
            const SizedBox(height: 12),
            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 48),
                child: Center(
                  child: Text(
                    activeTab == AssetStatus.settled
                        ? '暂无已结清的借贷项目'
                        : isDesktop
                        ? '暂无进行中的借贷项目，点击右上角“新建借贷”添加'
                        : '暂无进行中的借贷项目，点击右下角新建',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              )
            else
              for (final item in items) _DebtItemCard(item: item),
            SizedBox(height: isDesktop ? 24 : 80),
          ],
        );
        if (!isDesktop) return list;
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: list,
          ),
        );
      }),
      floatingActionButton: isDesktop
          ? null
          : FloatingActionButton.extended(
              key: const Key('add_debt_button'),
              heroTag: 'fab-debt',
              onPressed: () async {
                await pushDesktopModalOrMaterialRoute<bool>(
                  context,
                  child: const DebtEditorPage(),
                );
              },
              icon: const Icon(Icons.add),
              label: const Text('新建借贷'),
            ),
    );
  }
}

class _SummaryCell extends StatelessWidget {
  const _SummaryCell({
    required this.label,
    required this.value,
    required this.valueKey,
  });

  final String label;
  final String value;
  final Key valueKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        children: [
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              key: valueKey,
              maxLines: 1,
              softWrap: false,
              style: theme.textTheme.titleMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class _DebtItemCard extends StatelessWidget {
  const _DebtItemCard({required this.item});

  final DebtListItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final debt = item.debt;
    final isBorrow = debt.subType == AssetType.debtBorrow;
    final dueText = item.loanInfo.endDate != noRef && item.loanInfo.endDate > 0
        ? '到期 ${formatDate(DateTime.fromMillisecondsSinceEpoch(item.loanInfo.endDate))}'
        : null;

    return Card(
      key: Key('debt_item_${debt.id}'),
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () async {
          await pushDesktopModalOrMaterialRoute<bool>(
            context,
            child: DebtDetailPage(debtId: debt.id),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    isBorrow ? Icons.call_received : Icons.call_made,
                    size: 18,
                    color: isBorrow
                        ? colorScheme.tertiary
                        : colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(debt.name, style: theme.textTheme.titleMedium),
                  ),
                  Text(
                    formatMinor(item.remainingPrincipalMinor),
                    key: Key('debt_item_balance_${debt.id}'),
                    style: theme.textTheme.titleMedium,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      [
                        isBorrow ? '借入' : '借出',
                        '总额 ${formatMinor(item.totalPrincipalMinor)}',
                        if (debt.currency != null) debt.currency!,
                        if (!item.countedInNetWorth) '不计入资产',
                        ?dueText,
                      ].join(' · '),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '进度 ${item.progressLabel}',
                    key: Key('debt_item_progress_${debt.id}'),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
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
