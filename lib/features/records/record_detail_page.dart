import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../domain/ledger/record_relations.dart';
import '../../domain/model/codes.dart';
import '../common/common.dart';
import 'record_labels.dart';

class RecordDetailPage extends ConsumerStatefulWidget {
  const RecordDetailPage({super.key, required this.recordId});
  final String recordId;
  @override
  ConsumerState<RecordDetailPage> createState() => _RecordDetailPageState();
}

class _RecordDetailPageState extends ConsumerState<RecordDetailPage> {
  final ids = CommandIds();
  bool busy = false;
  String? error;

  Future<void> _delete(LedgerRecord r) async {
    final ok = await confirm(
      context,
      title: '删除这笔账单？',
      message: r.type == RecordType.transfer
          ? '转账及其手续费会一并删除，账户余额会恢复。'
          : '删除后账户余额会恢复。',
      ok: '删除',
    );
    if (!ok || !mounted) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final service = await ref.read(ledgerServiceProvider.future);
      await service.deleteRecord(
        commandId: ids.forPayload(['delete', r.recordId]),
        recordId: r.recordId,
      );
      if (mounted) context.pop();
    } catch (e) {
      if (mounted) setState(() => error = safeMessage(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final record = ref.watch(recordProvider(widget.recordId));
    final assets = ref.watch(assetsProvider).value ?? const <Asset>[];
    return Scaffold(
      appBar: AppBar(title: const Text('账单详情')),
      body: asyncBody(record, (r) {
        if (r == null) return const Center(child: Text('账单不存在或已删除'));
        final categories =
            ref.watch(categoriesProvider(r.accountBookId)).value ?? const [];
        final label = recordLabel(r, categories, assets);
        final feeParent = r.type == RecordType.fee
            ? RecordRelations.parse(r.relInfo).transferFee?.parentId
            : null;
        final generated = feeParent != null && feeParent.isNotEmpty;
        final editable = const {
          RecordType.expense,
          RecordType.income,
          RecordType.transfer,
        }.contains(r.type);
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(RecordType.names[r.type] ?? '账单'),
            Text(
              label.amount,
              key: const Key('detail-amount'),
              style: Theme.of(context).textTheme.displaySmall,
            ),
            const SizedBox(height: 16),
            ListTile(title: const Text('分类/说明'), trailing: Text(label.title)),
            if (r.type == RecordType.transfer) ...[
              ListTile(
                title: const Text('转出'),
                trailing: Text(assetName(assets, r.fromAssetId)),
              ),
              ListTile(
                title: const Text('转入'),
                trailing: Text(assetName(assets, r.toAssetId)),
              ),
            ] else
              ListTile(
                title: const Text('账户'),
                trailing: Text(assetName(assets, r.assetId)),
              ),
            ListTile(
              title: const Text('时间'),
              trailing: Text(
                formatDateTime(
                  DateTime.fromMillisecondsSinceEpoch(r.recordTime),
                ),
              ),
            ),
            if (r.remark.isNotEmpty)
              ListTile(title: const Text('备注'), subtitle: Text(r.remark)),
            if (r.excludeExIn) const ListTile(title: Text('不计入收支')),
            if (r.excludeBudget) const ListTile(title: Text('不计入预算')),
            if (error != null)
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            const SizedBox(height: 16),
            if (generated)
              OutlinedButton(
                onPressed: () => context.pushReplacement('/record/$feeParent'),
                child: const Text('这是转账手续费，查看所属转账'),
              )
            else ...[
              if (editable)
                FilledButton(
                  key: const Key('edit'),
                  onPressed: busy
                      ? null
                      : () => context.push('/record/${r.recordId}/edit'),
                  child: const Text('编辑'),
                ),
              TextButton(
                key: const Key('delete'),
                onPressed: busy ? null : () => _delete(r),
                child: Text(busy ? '删除中…' : '删除'),
              ),
            ],
          ],
        );
      }),
    );
  }
}
