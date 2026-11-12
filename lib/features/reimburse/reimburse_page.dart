import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart' show ledgerServiceProvider;
import '../../core/failure.dart';
import '../../core/money.dart';
import '../../data/db/database.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/reimburse_overview.dart';
import '../common/catalog_icons.dart';
import '../common/common.dart';
import 'reimburse_providers.dart';

final _maxReimburseAmount = Money.parse('88888888888.00');

final _amountInputFormatters = <TextInputFormatter>[
  FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
];

Money _parsePositiveAmount(String rawText) {
  final t = rawText.trim();
  if (t.isEmpty) {
    throw const Failure(FailureCode.validation, '请输入报销金额');
  }
  final normalized = t.endsWith('.') ? t.substring(0, t.length - 1) : t;
  if (normalized.isEmpty || normalized == '.') {
    throw const Failure(FailureCode.validation, '请输入有效报销金额');
  }
  final money = Money.parse(
    normalized.startsWith('.') ? '0$normalized' : normalized,
  );
  if (money.units <= BigInt.zero) {
    throw const Failure(FailureCode.validation, '报销金额须大于 0');
  }
  if (money.units > _maxReimburseAmount.units) {
    throw const Failure(FailureCode.validation, '金额不能超过 88888888888.00');
  }
  return money;
}

Money? _tryParsePositiveAmount(String rawText) {
  try {
    return _parsePositiveAmount(rawText);
  } on Object {
    return null;
  }
}

int _composeRecordTimeMs(DateTime selectedDate, DateTime now) {
  final isSameDay =
      selectedDate.year == now.year &&
      selectedDate.month == now.month &&
      selectedDate.day == now.day;
  if (isSameDay) {
    return now.millisecondsSinceEpoch;
  }
  return DateTime(
    selectedDate.year,
    selectedDate.month,
    selectedDate.day,
    now.hour,
    now.minute,
    now.second,
    now.millisecond,
  ).millisecondsSinceEpoch;
}

/// Dedicated Reimbursement Management Center (`报销管理`, `F-013`).
class ReimbursePage extends ConsumerStatefulWidget {
  const ReimbursePage({super.key, this.onRecordTap});

  final ValueChanged<String>? onRecordTap;

  @override
  ConsumerState<ReimbursePage> createState() => _ReimbursePageState();
}

class _ReimbursePageState extends ConsumerState<ReimbursePage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final Set<String> _selectedIds = <String>{};
  bool _batchMode = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this)
      ..addListener(_handleTabChange);
  }

  void _handleTabChange() {
    if (!mounted) return;
    setState(() {
      if (_tabController.index != 0 && _batchMode) {
        _batchMode = false;
        _selectedIds.clear();
      }
    });
  }

  @override
  void dispose() {
    _tabController
      ..removeListener(_handleTabChange)
      ..dispose();
    super.dispose();
  }

  void _handleRecordTap(String recordId) {
    if (widget.onRecordTap != null) {
      widget.onRecordTap!(recordId);
      return;
    }
    if (GoRouter.maybeOf(context) != null) {
      unawaited(context.push('/record/$recordId'));
    }
  }

  void _openNewReimbursable() {
    if (GoRouter.maybeOf(context) != null) {
      unawaited(context.push('/record/new?type=${RecordType.reimbursable}'));
    }
  }

  void _toggleScope() {
    ref.read(reimburseScopeAllBooksProvider.notifier).toggle();
    setState(_selectedIds.clear);
  }

  void _toggleBatchMode() {
    setState(() {
      _batchMode = !_batchMode;
      _selectedIds.clear();
    });
  }

  void _toggleSelectOne(String recordId) {
    setState(() {
      if (!_selectedIds.remove(recordId)) {
        _selectedIds.add(recordId);
      }
    });
  }

  void _toggleSelectAll(List<ReimburseBillRowView> pendingRows) {
    final allIds = pendingRows.map((r) => r.item.recordId).toSet();
    final isAllSelected =
        allIds.isNotEmpty && allIds.every(_selectedIds.contains);
    setState(() {
      if (isAllSelected) {
        _selectedIds.removeAll(allIds);
      } else {
        _selectedIds
          ..clear()
          ..addAll(allIds);
      }
    });
  }

  Future<void> _openSingleReimburse(
    ReimburseBillRowView row,
    ReimburseViewData view,
  ) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _SingleReimburseSheet(
        row: row,
        eligibleAssets: view.eligibleReceivingAssets,
        defaultAssetId: view.defaultReceivingAssetId,
      ),
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已登记报销收款')));
    }
  }

  Future<void> _openBatchReimburse(
    List<ReimburseBillRowView> selectedRows,
    ReimburseViewData view,
  ) async {
    if (selectedRows.isEmpty) return;
    final batchTotalMinor = selectedRows.fold<BigInt>(
      BigInt.zero,
      (sum, r) => sum + r.item.remainingMinor,
    );
    final count = selectedRows.length;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => _BatchReimburseSheet(
        rows: selectedRows,
        eligibleAssets: view.eligibleReceivingAssets,
        defaultAssetId: view.defaultReceivingAssetId,
        currencySymbol: view.baseCurrencySymbol,
      ),
    );
    if (saved == true && mounted) {
      setState(() {
        _batchMode = false;
        _selectedIds.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已合并报销 $count 笔，共 ${view.baseCurrencySymbol}${formatMinor(batchTotalMinor)}',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final allBooks = ref.watch(reimburseScopeAllBooksProvider);
    final viewAsync = ref.watch(reimburseViewProvider);
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('报销管理'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: ActionChip(
              key: const Key('reimburse-scope-toggle'),
              visualDensity: VisualDensity.compact,
              avatar: Icon(
                allBooks ? Icons.library_books_rounded : Icons.book_outlined,
                size: 16,
                color: allBooks
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant,
              ),
              backgroundColor: allBooks
                  ? colorScheme.primaryContainer.withValues(alpha: 0.65)
                  : colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
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
                  color: allBooks ? colorScheme.primary : colorScheme.onSurface,
                ),
              ),
              onPressed: _toggleScope,
            ),
          ),
          IconButton(
            key: const Key('reimburse-add-btn'),
            tooltip: '记一笔报销',
            icon: const Icon(Icons.add_rounded),
            onPressed: _openNewReimbursable,
          ),
        ],
      ),
      body: asyncBody(viewAsync, (view) {
        final pendingIds = view.pendingRows.map((r) => r.item.recordId).toSet();
        final activeSelectedRows = view.pendingRows
            .where((r) => _selectedIds.contains(r.item.recordId))
            .toList();
        final showBatchBar =
            _batchMode &&
            _tabController.index == 0 &&
            view.pendingRows.isNotEmpty;

        // Keep selection set pruned to live pending items.
        final hasStaleSelection = _selectedIds.any(
          (id) => !pendingIds.contains(id),
        );
        if (hasStaleSelection) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            setState(() {
              _selectedIds.removeWhere((id) => !pendingIds.contains(id));
            });
          });
        }

        return Column(
          children: [
            _SummaryDashboardCard(view: view),
            Material(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: TabBar(
                controller: _tabController,
                tabs: [
                  Tab(
                    key: const Key('reimburse-tab-pending'),
                    text: '待报销 (${view.overview.pendingItems.length})',
                  ),
                  Tab(
                    key: const Key('reimburse-tab-settled'),
                    text: '已报销 (${view.overview.settledItems.length})',
                  ),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildPendingTab(context, view),
                  _buildSettledTab(context, view),
                ],
              ),
            ),
            if (showBatchBar)
              _BatchBottomActionBar(
                selectedRows: activeSelectedRows,
                currencySymbol: view.baseCurrencySymbol,
                onSubmit: activeSelectedRows.isEmpty
                    ? null
                    : () => _openBatchReimburse(activeSelectedRows, view),
              ),
          ],
        );
      }),
    );
  }

  Widget _buildPendingTab(BuildContext context, ReimburseViewData view) {
    final rows = view.pendingRows;
    if (rows.isEmpty) {
      return _EmptyReimburseState(
        icon: Icons.receipt_long_outlined,
        title: '暂无待报销账单',
        subtitle: view.allBooksScope
            ? '所有账本下均无待报销支出，垫付费用后可在此统一跟进回款'
            : '当前账本暂无待报销支出，可点击下方按钮记一笔报销账单',
        onAddPressed: _openNewReimbursable,
      );
    }

    final allSelected = rows.every(
      (r) => _selectedIds.contains(r.item.recordId),
    );
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 12, 4),
          child: Row(
            children: [
              if (_batchMode)
                TextButton.icon(
                  key: const Key('reimburse-batch-select-all'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  onPressed: () => _toggleSelectAll(rows),
                  icon: Icon(
                    allSelected
                        ? Icons.deselect_rounded
                        : Icons.select_all_rounded,
                    size: 18,
                  ),
                  label: Text(allSelected ? '取消全选' : '全选'),
                )
              else
                Expanded(
                  child: Text(
                    '点击单笔查看详情，或点右侧「报销」快速入账',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              if (_batchMode) const Spacer(),
              TextButton.icon(
                key: const Key('reimburse-batch-toggle'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                onPressed: _toggleBatchMode,
                icon: Icon(
                  _batchMode
                      ? Icons.close_rounded
                      : Icons.checklist_rtl_rounded,
                  size: 18,
                ),
                label: Text(_batchMode ? '退出批量' : '批量选择'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
            itemCount: rows.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final row = rows[index];
              final isSelected = _selectedIds.contains(row.item.recordId);
              return _PendingBillCard(
                row: row,
                showBookName: view.allBooksScope,
                batchMode: _batchMode,
                selected: isSelected,
                onRowTap: () {
                  if (_batchMode) {
                    _toggleSelectOne(row.item.recordId);
                  } else {
                    _handleRecordTap(row.item.recordId);
                  }
                },
                onToggleSelect: () => _toggleSelectOne(row.item.recordId),
                onReimburseTap: () => _openSingleReimburse(row, view),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSettledTab(BuildContext context, ReimburseViewData view) {
    final rows = view.settledRows;
    if (rows.isEmpty) {
      return _EmptyReimburseState(
        icon: Icons.task_alt_rounded,
        title: '暂无已报销账单',
        subtitle: '完成报销入账的记录会归档到这里，方便随时核对收款凭证',
        onAddPressed: _openNewReimbursable,
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
      itemCount: rows.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final row = rows[index];
        return _SettledBillCard(
          row: row,
          showBookName: view.allBooksScope,
          onTap: () => _handleRecordTap(row.item.recordId),
        );
      },
    );
  }
}

class _SummaryDashboardCard extends StatelessWidget {
  const _SummaryDashboardCard({required this.view});

  final ReimburseViewData view;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final sym = view.baseCurrencySymbol;
    final overview = view.overview;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            cs.primaryContainer.withValues(alpha: 0.72),
            cs.secondaryContainer.withValues(alpha: 0.45),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.primary.withValues(alpha: 0.16)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '待报销总额',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: cs.surface.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  view.allBooksScope ? '全部账本' : view.currentBookName,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '$sym${formatMinor(overview.pendingTotalMinor)}',
            key: const Key('reimburse-pending-total'),
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: cs.onSurface,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _SummaryMetricTile(
                  label: '待报销笔数',
                  valueKey: const Key('reimburse-pending-count'),
                  value: '${overview.pendingItems.length} 笔',
                ),
              ),
              Container(
                width: 1,
                height: 28,
                color: cs.outlineVariant.withValues(alpha: 0.5),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 14),
                  child: _SummaryMetricTile(
                    label: '累计已报销',
                    valueKey: const Key('reimburse-settled-total'),
                    value: '$sym${formatMinor(overview.reimbursedTotalMinor)}',
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SummaryMetricTile extends StatelessWidget {
  const _SummaryMetricTile({
    required this.label,
    required this.valueKey,
    required this.value,
  });

  final String label;
  final Key valueKey;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: cs.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          key: valueKey,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: cs.onSurface,
          ),
        ),
      ],
    );
  }
}

class _PendingBillCard extends StatelessWidget {
  const _PendingBillCard({
    required this.row,
    required this.showBookName,
    required this.batchMode,
    required this.selected,
    required this.onRowTap,
    required this.onToggleSelect,
    required this.onReimburseTap,
  });

  final ReimburseBillRowView row;
  final bool showBookName;
  final bool batchMode;
  final bool selected;
  final VoidCallback onRowTap;
  final VoidCallback onToggleSelect;
  final VoidCallback onReimburseTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final item = row.item;
    final sym = row.currencySymbol;
    final dt = DateTime.fromMillisecondsSinceEpoch(item.recordTime);
    final subtitleParts = <String>[
      formatDate(dt),
      row.categoryDisplayName,
      row.fundingAccountName,
      if (showBookName) row.bookName,
    ];

    return Material(
      color: selected
          ? cs.primaryContainer.withValues(alpha: 0.35)
          : cs.surfaceContainerLow,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onRowTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(
            children: [
              if (batchMode) ...[
                SizedBox(
                  width: 32,
                  height: 32,
                  child: Checkbox(
                    key: Key('reimburse-select-${item.recordId}'),
                    value: selected,
                    visualDensity: VisualDensity.compact,
                    onChanged: (_) => onToggleSelect(),
                  ),
                ),
                const SizedBox(width: 6),
              ],
              CategoryIconAvatar(
                iconKey: row.categoryIconKey,
                parentIconKey: row.parentCategoryIconKey,
                colorHex: row.categoryColorHex,
                name: row.categoryDisplayName,
                type: RecordType.expense,
                size: batchMode ? 36 : 40,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      row.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitleParts.join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    if (item.isPartial) ...[
                      const SizedBox(height: 5),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: cs.tertiaryContainer.withValues(alpha: 0.7),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '已报 $sym${formatMinor(item.reimbursedMinor)}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: cs.onTertiaryContainer,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '待报 $sym${formatMinor(item.remainingMinor)}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: cs.primary,
                    ),
                  ),
                  if (item.isPartial)
                    Text(
                      '垫付 $sym${formatMinor(item.originMinor)}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
              if (!batchMode) ...[
                const SizedBox(width: 8),
                FilledButton.tonal(
                  key: Key('reimburse-action-${item.recordId}'),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    minimumSize: const Size(52, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: onReimburseTap,
                  child: const Text('报销'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SettledBillCard extends StatelessWidget {
  const _SettledBillCard({
    required this.row,
    required this.showBookName,
    required this.onTap,
  });

  final ReimburseBillRowView row;
  final bool showBookName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final item = row.item;
    final sym = row.currencySymbol;
    final dt = DateTime.fromMillisecondsSinceEpoch(item.recordTime);
    final receiptCount = item.receiptIds.length;
    final subtitleParts = <String>[
      formatDate(dt),
      row.categoryDisplayName,
      row.fundingAccountName,
      if (showBookName) row.bookName,
      if (receiptCount > 0) '$receiptCount 笔收款',
    ];
    const settledGreen = Color(0xFF2E7D32);

    return Material(
      color: cs.surfaceContainerLow,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(
            children: [
              CategoryIconAvatar(
                iconKey: row.categoryIconKey,
                parentIconKey: row.parentCategoryIconKey,
                colorHex: row.categoryColorHex,
                name: row.categoryDisplayName,
                type: RecordType.expense,
                size: 40,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      row.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitleParts.join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: settledGreen.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            '已报销',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: settledGreen,
                            ),
                          ),
                        ),
                        if (item.overageMinor > BigInt.zero)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: cs.primaryContainer.withValues(alpha: 0.7),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '+$sym${formatMinor(item.overageMinor)} 差额',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: cs.primary,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$sym${formatMinor(item.reimbursedMinor)}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: settledGreen,
                    ),
                  ),
                  if (item.overageMinor > BigInt.zero)
                    Text(
                      '垫付 $sym${formatMinor(item.originMinor)}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: cs.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BatchBottomActionBar extends StatelessWidget {
  const _BatchBottomActionBar({
    required this.selectedRows,
    required this.currencySymbol,
    required this.onSubmit,
  });

  final List<ReimburseBillRowView> selectedRows;
  final String currencySymbol;
  final VoidCallback? onSubmit;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final totalMinor = selectedRows.fold<BigInt>(
      BigInt.zero,
      (sum, r) => sum + r.item.remainingMinor,
    );

    return Material(
      color: cs.surfaceContainer,
      elevation: 3,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '已选 ${selectedRows.length} 笔 · 合计 $currencySymbol${formatMinor(totalMinor)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                key: const Key('reimburse-batch-submit'),
                onPressed: onSubmit,
                child: const Text('合并报销'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyReimburseState extends StatelessWidget {
  const _EmptyReimburseState({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onAddPressed,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onAddPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 68,
              height: 68,
              decoration: BoxDecoration(
                color: cs.primaryContainer.withValues(alpha: 0.45),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 34, color: cs.primary),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 18),
            FilledButton.tonalIcon(
              key: const Key('reimburse-empty-add'),
              onPressed: onAddPressed,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('记一笔待报销支出'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SingleReimburseSheet extends ConsumerStatefulWidget {
  const _SingleReimburseSheet({
    required this.row,
    required this.eligibleAssets,
    required this.defaultAssetId,
  });

  final ReimburseBillRowView row;
  final List<Asset> eligibleAssets;
  final int defaultAssetId;

  @override
  ConsumerState<_SingleReimburseSheet> createState() =>
      _SingleReimburseSheetState();
}

class _SingleReimburseSheetState extends ConsumerState<_SingleReimburseSheet> {
  final _ids = CommandIds();
  late final TextEditingController _amountCtrl;
  final _remarkCtrl = TextEditingController();
  late int _selectedAssetId;
  DateTime _selectedDate = DateTime.now();
  bool _submitting = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _amountCtrl = TextEditingController(
      text: Money.minor(widget.row.item.remainingMinor).decimal,
    )..addListener(() => setState(() => _errorText = null));
    _selectedAssetId =
        widget.eligibleAssets.any((a) => a.id == widget.defaultAssetId)
        ? widget.defaultAssetId
        : noRef;
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _remarkCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year + 5, 12, 31),
    );
    if (picked != null && mounted) {
      setState(() => _selectedDate = picked);
    }
  }

  Future<void> _submit() async {
    final Money amount;
    try {
      amount = _parsePositiveAmount(_amountCtrl.text);
    } catch (e) {
      setState(() => _errorText = safeMessage(e));
      return;
    }

    setState(() {
      _submitting = true;
      _errorText = null;
    });

    try {
      final service = await ref.read(ledgerServiceProvider.future);
      final now = DateTime.now();
      final recordTimeMs = _composeRecordTimeMs(_selectedDate, now);
      final remark = _remarkCtrl.text.trim();
      final cmdId = _ids.forPayload([
        'single-reimburse',
        widget.row.item.recordId,
        amount.toJson(),
        _selectedAssetId,
        formatDate(_selectedDate),
        remark,
      ]);
      await service.addReimbursement(
        commandId: cmdId,
        originId: widget.row.item.recordId,
        amount: amount,
        assetId: _selectedAssetId,
        recordTime: recordTimeMs,
        remark: remark,
      );
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _errorText = safeMessage(e));
      }
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final item = widget.row.item;
    final sym = widget.row.currencySymbol;
    final parsedInput = _tryParsePositiveAmount(_amountCtrl.text);
    final preview = parsedInput == null
        ? null
        : computeReimbursePreview(
            originMinor: item.originMinor,
            alreadyReimbursedMinor: item.reimbursedMinor,
            inputMinor: parsedInput.units,
            currencySymbol: sym,
          );

    final Color previewColor = switch (preview?.kind) {
      ReimbursePreviewKind.full => const Color(0xFF2E7D32),
      ReimbursePreviewKind.overage => cs.primary,
      ReimbursePreviewKind.partial || null => cs.onSurfaceVariant,
    };

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '登记报销款',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${widget.row.title} · 待报 $sym${formatMinor(item.remainingMinor)}'
              '${item.isPartial ? '（原垫付 $sym${formatMinor(item.originMinor)}）' : ''}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              key: const Key('reimburse-dialog-amount'),
              controller: _amountCtrl,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: _amountInputFormatters,
              decoration: InputDecoration(
                labelText: '报销金额',
                prefixText: '$sym ',
                border: const OutlineInputBorder(),
                helperText: preview?.hintText,
                helperStyle: TextStyle(
                  color: previewColor,
                  fontWeight: FontWeight.w600,
                ),
                errorText: _errorText,
              ),
            ),
            const SizedBox(height: 12),
            _AccountDropdownField(
              fieldKey: const Key('reimburse-dialog-account'),
              labelText: '收款账户',
              assets: widget.eligibleAssets,
              selectedAssetId: _selectedAssetId,
              onChanged: _submitting
                  ? null
                  : (v) => setState(() => _selectedAssetId = v ?? noRef),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('reimburse-dialog-date'),
                    onPressed: _submitting ? null : _pickDate,
                    icon: const Icon(Icons.calendar_today_rounded, size: 16),
                    label: Text('收款日期 ${formatDate(_selectedDate)}'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('reimburse-dialog-remark'),
              controller: _remarkCtrl,
              decoration: const InputDecoration(
                labelText: '备注（选填）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _submitting
                      ? null
                      : () => Navigator.of(context).pop(false),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const Key('reimburse-dialog-confirm'),
                  onPressed: _submitting ? null : _submit,
                  child: Text(_submitting ? '提交中…' : '确认报销'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _BatchReimburseSheet extends ConsumerStatefulWidget {
  const _BatchReimburseSheet({
    required this.rows,
    required this.eligibleAssets,
    required this.defaultAssetId,
    required this.currencySymbol,
  });

  final List<ReimburseBillRowView> rows;
  final List<Asset> eligibleAssets;
  final int defaultAssetId;
  final String currencySymbol;

  @override
  ConsumerState<_BatchReimburseSheet> createState() =>
      _BatchReimburseSheetState();
}

class _BatchReimburseSheetState extends ConsumerState<_BatchReimburseSheet> {
  final _ids = CommandIds();
  final _remarkCtrl = TextEditingController();
  late int _selectedAssetId;
  DateTime _selectedDate = DateTime.now();
  bool _submitting = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _selectedAssetId =
        widget.eligibleAssets.any((a) => a.id == widget.defaultAssetId)
        ? widget.defaultAssetId
        : noRef;
  }

  @override
  void dispose() {
    _remarkCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year + 5, 12, 31),
    );
    if (picked != null && mounted) {
      setState(() => _selectedDate = picked);
    }
  }

  Future<void> _submitBatch() async {
    setState(() {
      _submitting = true;
      _errorText = null;
    });

    try {
      final service = await ref.read(ledgerServiceProvider.future);
      final now = DateTime.now();
      final recordTimeMs = _composeRecordTimeMs(_selectedDate, now);
      final remark = _remarkCtrl.text.trim();
      final sessionKey = _ids.forPayload([
        'batch-session',
        [for (final r in widget.rows) r.item.recordId],
        _selectedAssetId,
        formatDate(_selectedDate),
        remark,
      ]);

      for (var i = 0; i < widget.rows.length; i++) {
        final item = widget.rows[i].item;
        if (item.remainingMinor <= BigInt.zero) continue;
        final perBillCmd = '$sessionKey-$i';
        await service.addReimbursement(
          commandId: perBillCmd,
          originId: item.recordId,
          amount: Money.minor(item.remainingMinor),
          assetId: _selectedAssetId,
          recordTime: recordTimeMs,
          remark: remark,
        );
      }

      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _errorText = safeMessage(e));
      }
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final totalMinor = widget.rows.fold<BigInt>(
      BigInt.zero,
      (sum, r) => sum + r.item.remainingMinor,
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '合并报销（${widget.rows.length} 笔）',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '按各笔剩余待报金额全额结清，合计入账 '
              '${widget.currencySymbol}${formatMinor(totalMinor)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            _AccountDropdownField(
              fieldKey: const Key('reimburse-batch-account'),
              labelText: '收款账户',
              assets: widget.eligibleAssets,
              selectedAssetId: _selectedAssetId,
              onChanged: _submitting
                  ? null
                  : (v) => setState(() => _selectedAssetId = v ?? noRef),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const Key('reimburse-batch-date'),
              onPressed: _submitting ? null : _pickDate,
              icon: const Icon(Icons.calendar_today_rounded, size: 16),
              label: Text('收款日期 ${formatDate(_selectedDate)}'),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('reimburse-batch-remark'),
              controller: _remarkCtrl,
              decoration: const InputDecoration(
                labelText: '统一备注（选填）',
                border: OutlineInputBorder(),
              ),
            ),
            if (_errorText != null) ...[
              const SizedBox(height: 10),
              Text(
                _errorText!,
                style: TextStyle(color: cs.error, fontSize: 13),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _submitting
                      ? null
                      : () => Navigator.of(context).pop(false),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const Key('reimburse-batch-confirm'),
                  onPressed: _submitting ? null : _submitBatch,
                  child: Text(_submitting ? '合并报销中…' : '确认合并报销'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AccountDropdownField extends StatelessWidget {
  const _AccountDropdownField({
    required this.fieldKey,
    required this.labelText,
    required this.assets,
    required this.selectedAssetId,
    required this.onChanged,
  });

  final Key fieldKey;
  final String labelText;
  final List<Asset> assets;
  final int selectedAssetId;
  final ValueChanged<int?>? onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<int>(
      key: fieldKey,
      initialValue: selectedAssetId,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: labelText,
        border: const OutlineInputBorder(),
      ),
      items: [
        for (final a in assets)
          DropdownMenuItem<int>(
            value: a.id,
            child: Row(
              children: [
                AssetIconAvatar(
                  iconKey: a.icon,
                  colorHex: a.color,
                  name: a.name,
                  assetType: a.type,
                  subType: a.subType,
                  size: 24,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    a.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        const DropdownMenuItem<int>(value: noRef, child: Text('不选账户')),
      ],
      onChanged: onChanged,
    );
  }
}
