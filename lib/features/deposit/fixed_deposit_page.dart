import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/database.dart';
import '../../data/repo/fixed_deposit_queries.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/fixed_deposit.dart';
import '../common/common.dart';
import '../records/record_detail_page.dart';
import 'fixed_deposit_editor_page.dart';
import 'fixed_deposit_providers.dart';

/// Fixed Deposit Management screen (`FixedDepositManageActivity` / `/bkp/FDMAct`, F-027).
class FixedDepositPage extends ConsumerStatefulWidget {
  const FixedDepositPage({super.key, this.initialAssetId, this.onRecordTap});

  /// Optional host account filter (`null` = global view across all eligible active accounts).
  final int? initialAssetId;

  /// Optional callback invoked when tapping a settled deposit's income bill chip.
  final void Function(String recordId)? onRecordTap;

  @override
  ConsumerState<FixedDepositPage> createState() => _FixedDepositPageState();
}

class _FixedDepositPageState extends ConsumerState<FixedDepositPage> {
  final _ids = CommandIds();
  int? _selectedAssetId;
  bool _settling = false;

  @override
  void initState() {
    super.initState();
    _selectedAssetId = widget.initialAssetId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_triggerSettle());
    });
  }

  Future<void> _triggerSettle() async {
    if (!mounted || _settling) return;
    setState(() => _settling = true);
    try {
      final service = await ref.read(fixedDepositServiceProvider.future);
      final count = await service.settleDueDeposits(assetId: _selectedAssetId);
      if (count > 0 && mounted) {
        ref.invalidate(fixedDepositOverviewProvider);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
      }
    } finally {
      if (mounted) setState(() => _settling = false);
    }
  }

  Future<void> _openCreate() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            FixedDepositEditorPage(initialAssetId: _selectedAssetId),
      ),
    );
    if (mounted) {
      ref.invalidate(fixedDepositOverviewProvider);
      unawaited(_triggerSettle());
    }
  }

  Future<void> _openEdit(FixedDepositEntry entry) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => FixedDepositEditorPage(
          assetId: entry.asset.id,
          depositIndex: entry.index,
        ),
      ),
    );
    if (mounted) {
      ref.invalidate(fixedDepositOverviewProvider);
      unawaited(_triggerSettle());
    }
  }

  Future<void> _deleteDeposit(FixedDepositEntry entry) async {
    final ok = await confirm(
      context,
      title: '删除这笔定期存款？',
      message: '关联的未删除转账或收益流水将一并撤销并安全回冲余额。',
      ok: '删除',
    );
    if (!ok || !mounted) return;
    try {
      final service = await ref.read(fixedDepositServiceProvider.future);
      await service.deleteDeposit(
        commandId: _ids.forPayload([
          'delete-deposit',
          entry.asset.id,
          entry.index,
          entry.item.depositDate,
        ]),
        assetId: entry.asset.id,
        index: entry.index,
      );
      if (mounted) {
        ref.invalidate(fixedDepositOverviewProvider);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
      }
    }
  }

  Future<void> _onTapIncomeChip(FixedDepositEntry entry) async {
    final recId = entry.item.incomeRecordId;
    if (!entry.item.isSettled || recId == null || recId.isEmpty) return;
    try {
      final queries = await ref.read(fixedDepositQueriesProvider.future);
      final live = await queries.getLiveRecord(recId);
      if (!mounted) return;
      if (live == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('账单已不存在')));
        return;
      }
      if (widget.onRecordTap != null) {
        widget.onRecordTap!(recId);
      } else {
        await Navigator.of(context).push<void>(
          MaterialPageRoute(builder: (_) => RecordDetailPage(recordId: recId)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final overviewAsync = ref.watch(
      fixedDepositOverviewProvider(_selectedAssetId),
    );

    return Scaffold(
      key: const Key('fixed_deposit_page'),
      appBar: AppBar(
        title: const Text('定期存款'),
        actions: [
          IconButton(
            key: const Key('deposit_refresh_button'),
            tooltip: '结算并刷新',
            onPressed: _settling ? null : _triggerSettle,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('add_deposit_fab'),
        onPressed: _openCreate,
        icon: const Icon(Icons.add),
        label: const Text('新建定存'),
      ),
      body: asyncBody(
        overviewAsync,
        (overview) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
              children: [
                if (overview.eligibleAssets.isNotEmpty)
                  _AssetFilterBar(
                    eligibleAssets: overview.eligibleAssets,
                    selectedAssetId: _selectedAssetId,
                    onChanged: (nextId) {
                      setState(() => _selectedAssetId = nextId);
                      unawaited(_triggerSettle());
                    },
                  ),
                const SizedBox(height: 8),
                _DepositSummaryCard(header: overview.header),
                const SizedBox(height: 16),
                if (overview.entries.isEmpty)
                  const _EmptyDepositView()
                else
                  for (final entry in overview.entries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _DepositEntryCard(
                        entry: entry,
                        onEdit: () => _openEdit(entry),
                        onDelete: () => _deleteDeposit(entry),
                        onTapIncomeChip: () => _onTapIncomeChip(entry),
                      ),
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AssetFilterBar extends StatelessWidget {
  const _AssetFilterBar({
    required this.eligibleAssets,
    required this.selectedAssetId,
    required this.onChanged,
  });

  final List<Asset> eligibleAssets;
  final int? selectedAssetId;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    final validSelected =
        selectedAssetId != null &&
            eligibleAssets.any((a) => a.id == selectedAssetId)
        ? selectedAssetId!
        : noRef;
    return InputDecorator(
      decoration: const InputDecoration(
        labelText: '筛选账户',
        isDense: true,
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          key: const Key('deposit_asset_filter'),
          value: validSelected,
          isExpanded: true,
          isDense: true,
          items: [
            const DropdownMenuItem(value: noRef, child: Text('全部合格账户')),
            for (final a in eligibleAssets)
              DropdownMenuItem(value: a.id, child: Text(a.name)),
          ],
          onChanged: (v) => onChanged(v == null || v == noRef ? null : v),
        ),
      ),
    );
  }
}

class _DepositSummaryCard extends StatelessWidget {
  const _DepositSummaryCard({required this.header});

  final FixedDepositHeaderSummary header;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: const Key('deposit_summary_card'),
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: _MetricColumn(
                label: '累计定存本金',
                valueKey: const Key('deposit_total_principal'),
                valueText: '¥${formatMinor(header.totalPrincipalMinor)}',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            Expanded(
              child: _MetricColumn(
                label: '待收利息收益',
                valueKey: const Key('deposit_pending_income'),
                valueText: '¥${formatMinor(header.pendingIncomeMinor)}',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
            Expanded(
              child: _MetricColumn(
                label: '已获结清收益',
                valueKey: const Key('deposit_settled_income'),
                valueText: '¥${formatMinor(header.settledIncomeMinor)}',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.tertiary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricColumn extends StatelessWidget {
  const _MetricColumn({
    required this.label,
    required this.valueKey,
    required this.valueText,
    this.style,
  });

  final String label;
  final Key valueKey;
  final String valueText;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 6),
      Text(valueText, key: valueKey, style: style),
    ],
  );
}

class _EmptyDepositView extends StatelessWidget {
  const _EmptyDepositView();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 48),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.savings_outlined,
          size: 48,
          color: Theme.of(context).colorScheme.outline,
        ),
        const SizedBox(height: 12),
        Text('暂无定期存款记录', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          '点击右下角“新建定存”登记本金与利率，到期自动结算收益',
          style: Theme.of(context).textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
      ],
    ),
  );
}

class _DepositEntryCard extends StatelessWidget {
  const _DepositEntryCard({
    required this.entry,
    required this.onEdit,
    required this.onDelete,
    required this.onTapIncomeChip,
  });

  final FixedDepositEntry entry;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onTapIncomeChip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = entry.item;
    final curr = entry.effectiveCurrency;
    final currPrefix = curr == 'CNY' ? '¥' : '$curr ';
    final periodLabel = item.periodUnit == DepositPeriodUnit.month
        ? '${item.periodCount}个月'
        : '${item.periodCount}年';
    final depositDateText = formatDate(
      DateTime.fromMillisecondsSinceEpoch(item.depositDate),
    );
    final dueDateText = formatDate(
      DateTime.fromMillisecondsSinceEpoch(item.dueDate),
    );
    final statusLabel = item.isSettled ? '已结束' : '进行中';

    return Card(
      key: Key('deposit_card_${entry.asset.id}_${entry.index}'),
      child: InkWell(
        onTap: onEdit,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      entry.asset.name,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: item.isSettled
                          ? theme.colorScheme.surfaceContainerHighest
                          : theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      statusLabel,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: item.isSettled
                            ? theme.colorScheme.onSurfaceVariant
                            : theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                  IconButton(
                    key: Key('deposit_edit_${entry.asset.id}_${entry.index}'),
                    tooltip: '编辑',
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    onPressed: onEdit,
                  ),
                  IconButton(
                    key: Key('deposit_delete_${entry.asset.id}_${entry.index}'),
                    tooltip: '删除',
                    icon: const Icon(Icons.delete_outline, size: 20),
                    onPressed: onDelete,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '本金 $currPrefix${formatMinor(item.moneyMinor)}',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  ActionChip(
                    key: Key(
                      'deposit_income_chip_${entry.asset.id}_${entry.index}',
                    ),
                    label: Text(
                      item.isSettled
                          ? '已结收益 $currPrefix${formatMinor(item.expectedIncomeMinor)}'
                          : '预期收益 $currPrefix${formatMinor(item.expectedIncomeMinor)}',
                    ),
                    onPressed: item.isSettled ? onTapIncomeChip : null,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '年化 ${annualRateToPercentString(item.annualRate)}% · 存期 $periodLabel · $depositDateText 至 $dueDateText',
                style: theme.textTheme.bodySmall,
              ),
              if (entry.fromAssetName != null) ...[
                const SizedBox(height: 4),
                Text(
                  '转出账户：${entry.fromAssetName}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
              if (item.remark.trim().isNotEmpty) ...[
                const SizedBox(height: 4),
                Text('备注：${item.remark}', style: theme.textTheme.bodySmall),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
