import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/model/codes.dart';
import '../common/common.dart';
import 'debt_detail_page.dart';
import 'debt_editor_page.dart';
import 'debt_providers.dart';

/// Main Debt Management page (`F-011` / original `DebtManageActivity`).
class DebtPage extends ConsumerWidget {
  const DebtPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allBooks = ref.watch(debtAllBooksScopeProvider);
    final selectedStatus = ref.watch(debtStatusTabProvider);
    final viewAsync = ref.watch(debtListViewProvider);
    final theme = Theme.of(context);

    return Scaffold(
      key: const Key('debt_page'),
      appBar: AppBar(
        title: const Text('借贷管理'),
        actions: [
          TextButton.icon(
            key: const Key('debt_scope_toggle'),
            onPressed: () =>
                ref.read(debtAllBooksScopeProvider.notifier).toggle(),
            icon: Icon(
              allBooks ? Icons.library_books : Icons.book_outlined,
              size: 18,
            ),
            label: Text(allBooks ? '全部账本' : '当前账本'),
          ),
        ],
      ),
      body: asyncBody(viewAsync, (view) {
        final items = selectedStatus == AssetStatus.settled
            ? view.settledItems
            : view.activeItems;

        return ListView(
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
            Row(
              children: [
                Expanded(
                  child: ChoiceChip(
                    key: const Key('debt_tab_active'),
                    label: Center(
                      child: Text('进行中 (${view.activeItems.length})'),
                    ),
                    selected: selectedStatus == AssetStatus.active,
                    onSelected: (_) => ref
                        .read(debtStatusTabProvider.notifier)
                        .select(AssetStatus.active),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ChoiceChip(
                    key: const Key('debt_tab_settled'),
                    label: Center(
                      child: Text('已结清 (${view.settledItems.length})'),
                    ),
                    selected: selectedStatus == AssetStatus.settled,
                    onSelected: (_) => ref
                        .read(debtStatusTabProvider.notifier)
                        .select(AssetStatus.settled),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 48),
                child: Center(
                  child: Text(
                    selectedStatus == AssetStatus.settled
                        ? '暂无已结清的借贷项目'
                        : '暂无进行中的借贷项目，点击右下角新建',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              )
            else
              for (final item in items) _DebtItemCard(item: item),
            const SizedBox(height: 80),
          ],
        );
      }),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('add_debt_button'),
        heroTag: 'fab-debt',
        onPressed: () async {
          await Navigator.of(context).push<bool>(
            MaterialPageRoute(builder: (_) => const DebtEditorPage()),
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
    return Column(
      children: [
        Text(label, style: theme.textTheme.labelMedium),
        const SizedBox(height: 4),
        Text(value, key: valueKey, style: theme.textTheme.titleMedium),
      ],
    );
  }
}

class _DebtItemCard extends StatelessWidget {
  const _DebtItemCard({required this.item});

  final DebtListItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
          await Navigator.of(context).push<bool>(
            MaterialPageRoute(builder: (_) => DebtDetailPage(debtId: debt.id)),
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
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  Text(
                    '进度 ${item.progressLabel}',
                    key: Key('debt_item_progress_${debt.id}'),
                    style: theme.textTheme.labelMedium,
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
