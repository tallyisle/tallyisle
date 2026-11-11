import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../domain/model/codes.dart';
import '../../data/repo/import_batch_queries.dart';
import '../common/common.dart';
import 'csv_transfer_providers.dart';

const _uuid = Uuid();

class ImportBatchesPage extends ConsumerStatefulWidget {
  const ImportBatchesPage({super.key});

  @override
  ConsumerState<ImportBatchesPage> createState() => _ImportBatchesPageState();
}

class _ImportBatchesPageState extends ConsumerState<ImportBatchesPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  int? _busyBatchId;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _toggleHidden(ImportBatchSummary summary) async {
    if (_busyBatchId != null) return;
    final batch = summary.batch;
    final nextHidden = !batch.hidden;
    setState(() => _busyBatchId = batch.id);
    try {
      final service = await ref.read(csvExcelServiceProvider.future);
      await service.setBatchHidden(
        commandId: _uuid.v4(),
        batchId: batch.id,
        hidden: nextHidden,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(nextHidden ? '已移入隐藏记录' : '已恢复到导入记录')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    } finally {
      if (mounted) setState(() => _busyBatchId = null);
    }
  }

  Future<void> _confirmAndUndo(ImportBatchSummary summary) async {
    if (_busyBatchId != null) return;
    final batch = summary.batch;
    final ok = await _showUndoConfirmDialog(
      context,
      platformName: batch.platform,
      liveBillCount: summary.liveBillCount,
    );
    if (!ok || !mounted) return;

    setState(() => _busyBatchId = batch.id);
    try {
      final service = await ref.read(csvExcelServiceProvider.future);
      await service.undoBatch(commandId: _uuid.v4(), batchId: batch.id);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已撤销导入批次并回退账户余额')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    } finally {
      if (mounted) setState(() => _busyBatchId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final visibleAsync = ref.watch(visibleImportBatchesProvider);
    final hiddenAsync = ref.watch(hiddenImportBatchesProvider);

    return Scaffold(
      key: const Key('import_batches_page'),
      appBar: AppBar(
        title: const Text('导入记录管理'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(key: Key('visible_batches_tab'), text: '导入记录'),
            Tab(key: Key('hidden_batches_tab'), text: '已隐藏'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          asyncBody(
            visibleAsync,
            (items) => _BatchListView(
              items: items,
              emptyText: '暂无导入批次记录',
              busyBatchId: _busyBatchId,
              onToggleHidden: _toggleHidden,
              onUndo: _confirmAndUndo,
            ),
          ),
          asyncBody(
            hiddenAsync,
            (items) => _BatchListView(
              items: items,
              emptyText: '暂无已隐藏的导入批次',
              busyBatchId: _busyBatchId,
              onToggleHidden: _toggleHidden,
              onUndo: _confirmAndUndo,
            ),
          ),
        ],
      ),
    );
  }
}

class _BatchListView extends StatelessWidget {
  const _BatchListView({
    required this.items,
    required this.emptyText,
    required this.busyBatchId,
    required this.onToggleHidden,
    required this.onUndo,
  });

  final List<ImportBatchSummary> items;
  final String emptyText;
  final int? busyBatchId;
  final ValueChanged<ImportBatchSummary> onToggleHidden;
  final ValueChanged<ImportBatchSummary> onUndo;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(emptyText),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final summary = items[index];
        final batch = summary.batch;
        final isBusy = busyBatchId == batch.id;
        final importedAt = DateTime.fromMillisecondsSinceEpoch(
          batch.importTime,
        );

        return Card(
          key: Key('import_batch_card_${batch.id}'),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: isBusy
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ImportBatchDetailPage(batchId: batch.id),
                    ),
                  ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          batch.platform,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      Text(
                        formatDateTime(importedAt),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '共识别 ${batch.importRecordCount} 行 · '
                    '现存 ${summary.liveBillCount} 笔账单 · '
                    '新建分类 ${batch.importCategoryCount} 个',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton.icon(
                        key: Key('toggle_hide_batch_${batch.id}'),
                        onPressed: isBusy
                            ? null
                            : () => onToggleHidden(summary),
                        icon: Icon(
                          batch.hidden
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          size: 18,
                        ),
                        label: Text(batch.hidden ? '取消隐藏' : '隐藏批次'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        key: Key('undo_batch_button_${batch.id}'),
                        onPressed: isBusy ? null : () => onUndo(summary),
                        icon: const Icon(Icons.undo, size: 18),
                        label: const Text('撤销批次'),
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

class ImportBatchDetailPage extends ConsumerStatefulWidget {
  const ImportBatchDetailPage({required this.batchId, super.key});

  final int batchId;

  @override
  ConsumerState<ImportBatchDetailPage> createState() =>
      _ImportBatchDetailPageState();
}

class _ImportBatchDetailPageState extends ConsumerState<ImportBatchDetailPage> {
  bool _busy = false;

  Future<void> _undoFromDetail(String platformName, int liveCount) async {
    if (_busy) return;
    final ok = await _showUndoConfirmDialog(
      context,
      platformName: platformName,
      liveBillCount: liveCount,
    );
    if (!ok || !mounted) return;

    setState(() => _busy = true);
    try {
      final service = await ref.read(csvExcelServiceProvider.future);
      await service.undoBatch(commandId: _uuid.v4(), batchId: widget.batchId);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已撤销导入批次并回退账户余额')));
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final batchAsync = ref.watch(importBatchProvider(widget.batchId));
    final recordsAsync = ref.watch(importBatchRecordsProvider(widget.batchId));

    final batch = batchAsync.value;
    final livePrimaryCount =
        recordsAsync.value
            ?.where((e) => e.record.type != RecordType.fee)
            .length ??
        0;

    return Scaffold(
      key: const Key('import_batch_detail_page'),
      appBar: AppBar(
        title: Text(batch == null ? '批次账单明细' : '${batch.platform} 明细'),
        actions: [
          if (batch != null)
            TextButton(
              key: const Key('detail_undo_batch_button'),
              onPressed: _busy
                  ? null
                  : () => _undoFromDetail(batch.platform, livePrimaryCount),
              child: const Text('撤销批次'),
            ),
        ],
      ),
      body: asyncBody(recordsAsync, (records) {
        if (records.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('该批次下已无现存账单记录'),
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: records.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final item = records[index];
            final r = item.record;
            final dt = DateTime.fromMillisecondsSinceEpoch(r.recordTime);
            final title = _recordTitle(item);
            final accountSummary = _accountSummary(item);
            final bookLabel = item.bookName ?? '默认账本';

            return ListTile(
              key: Key('batch_record_tile_${r.recordId}'),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 4,
              ),
              title: Text(title),
              subtitle: Text(
                '$bookLabel · $accountSummary · ${formatDateTime(dt)}'
                '${r.remark.isEmpty ? '' : '\n${r.remark}'}',
              ),
              trailing: Text(
                '${_amountPrefix(r.type)}${formatMinor(r.moneyMinor)}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            );
          },
        );
      }),
    );
  }

  static String _recordTitle(BatchRecordItem item) {
    final r = item.record;
    return switch (r.type) {
      RecordType.expense => '支出 · ${item.categoryName ?? '未分类'}',
      RecordType.income => '收入 · ${item.categoryName ?? '未分类'}',
      RecordType.transfer => '转账',
      RecordType.fee => '手续费',
      _ => '账单 · ${item.categoryName ?? ''}',
    };
  }

  static String _accountSummary(BatchRecordItem item) {
    final r = item.record;
    if (r.type == RecordType.transfer) {
      final from = item.fromAssetName ?? '未指定账户';
      final to = item.toAssetName ?? '未指定账户';
      return '$from -> $to';
    }
    return item.assetName ?? '不选账户';
  }

  static String _amountPrefix(int type) => switch (type) {
    RecordType.income => '+',
    RecordType.expense || RecordType.fee => '-',
    _ => '',
  };
}

Future<bool> _showUndoConfirmDialog(
  BuildContext context, {
  required String platformName,
  required int liveBillCount,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('确认撤销导入批次？'),
        content: Text(
          '将删除「$platformName」批次现存的 $liveBillCount 笔账单（含关联手续费）'
          '并对称回退对应账户余额。导入时新建的分类、标签及账本将予以保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('confirm_undo_batch_button'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('确认撤销'),
          ),
        ],
      ),
    ) ==
    true;
