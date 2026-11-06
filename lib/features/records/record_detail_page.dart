import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../domain/ledger/record_extra.dart';
import '../../domain/ledger/record_relations.dart';
import '../../domain/model/codes.dart';
import '../../core/money.dart';
import '../common/common.dart';
import 'record_editor_page.dart' show parseAmount, amountInputFormatters;
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

  Future<void> _addLink(LedgerRecord r, {required bool refund}) async {
    final assets = (ref.read(assetsProvider).value ?? const <Asset>[])
        .where((a) => a.status != AssetStatus.settled)
        .toList();
    final input = await showDialog<(Money, int)>(
      context: context,
      builder: (_) => _LinkDialog(
        title: refund ? '添加退款' : '登记报销款',
        assets: assets,
        initialAsset: refund
            ? (r.type == RecordType.reimbursable ? r.fromAssetId : r.assetId)
            : noRef,
      ),
    );
    if (input == null || !mounted) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final service = await ref.read(ledgerServiceProvider.future);
      final (amount, assetId) = input;
      final payload = [refund, r.recordId, amount.toJson(), assetId];
      final now = DateTime.now().millisecondsSinceEpoch;
      if (refund) {
        await service.addRefund(
          commandId: ids.forPayload(payload),
          originId: r.recordId,
          amount: amount,
          assetId: assetId,
          recordTime: now,
        );
      } else {
        await service.addReimbursement(
          commandId: ids.forPayload(payload),
          originId: r.recordId,
          amount: amount,
          assetId: assetId,
          recordTime: now,
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = safeMessage(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _settleAdvance(LedgerRecord r) async {
    final assets = (ref.read(assetsProvider).value ?? const <Asset>[])
        .where((a) => a.status != AssetStatus.settled)
        .toList();
    final input = await showDialog<(Money, int, bool)>(
      context: context,
      builder: (_) => _SettleAdvanceDialog(
        isIncome: r.type == RecordType.advanceIncome,
        defaultAmount: formatMinor(r.moneyMinor),
        assets: assets,
        initialAsset: r.assetId,
      ),
    );
    if (input == null || !mounted) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final service = await ref.read(ledgerServiceProvider.future);
      final (amount, assetId, finish) = input;
      final settledId = await service.settleAdvance(
        commandId: ids.forPayload([
          'settle-advance',
          r.recordId,
          amount.toJson(),
          assetId,
          finish,
        ]),
        originId: r.recordId,
        amount: amount,
        assetId: assetId,
        recordTime: DateTime.now().millisecondsSinceEpoch,
        finish: finish,
      );
      if (mounted) await context.push('/record/$settledId');
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
    final tags =
        ref.watch(recordTagsProvider(widget.recordId)).value ?? const [];
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
        final rel = RecordRelations.parse(r.relInfo);
        final childOf = rel.refunds?.originId ?? rel.reimbursements?.originId;
        final isChild = childOf != null && childOf.isNotEmpty;
        final isAdvance =
            r.type == RecordType.advanceIncome ||
            r.type == RecordType.advanceExpense;
        final advanceSettled =
            isAdvance && RecordExtra.parse(r.extraInfo).advance != null;
        final editable =
            !isChild &&
            !advanceSettled &&
            const {
              RecordType.expense,
              RecordType.income,
              RecordType.transfer,
              RecordType.reimbursable,
              RecordType.advanceIncome,
              RecordType.advanceExpense,
            }.contains(r.type);
        final refundable =
            !isChild &&
            r.moneyMinor > BigInt.zero &&
            const {
              RecordType.expense,
              RecordType.income,
              RecordType.reimbursable,
            }.contains(r.type);
        final refunded = (rel.refunds?.children ?? const <LinkedBill>[]).fold(
          BigInt.zero,
          (s, c) => s + c.amount,
        );
        final reimbursed =
            (rel.reimbursements?.children ?? const <LinkedBill>[]).fold(
              BigInt.zero,
              (s, c) => s + c.amount,
            );
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
                trailing: Text(
                  assetName(
                    assets,
                    r.type == RecordType.reimbursable ||
                            r.type == RecordType.balanceAdjust
                        ? r.fromAssetId
                        : r.assetId,
                  ),
                ),
              ),
            ListTile(
              title: const Text('时间'),
              trailing: Text(
                formatDateTime(
                  DateTime.fromMillisecondsSinceEpoch(r.recordTime),
                ),
              ),
            ),
            if (isAdvance)
              ListTile(
                title: const Text('状态'),
                trailing: Text(advanceSettled ? '已结算' : '待结算（暂不计入收支与余额）'),
              ),
            if (tags.isNotEmpty)
              ListTile(
                title: const Text('标签'),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [for (final t in tags) Chip(label: Text(t.name))],
                  ),
                ),
              ),
            if (r.remark.isNotEmpty)
              ListTile(title: const Text('备注'), subtitle: Text(r.remark)),
            if (r.excludeExIn) const ListTile(title: Text('不计入收支')),
            if (r.excludeBudget) const ListTile(title: Text('不计入预算')),
            if (refunded > BigInt.zero)
              ListTile(
                title: const Text('已退款'),
                trailing: Text(
                  formatMinor(refunded),
                  key: const Key('refunded'),
                ),
              ),
            if (r.type == RecordType.reimbursable)
              ListTile(
                title: const Text('已报销'),
                subtitle: Text(
                  '待报销 ${formatMinor((r.moneyMinor - refunded - reimbursed) < BigInt.zero ? BigInt.zero : r.moneyMinor - refunded - reimbursed)}',
                ),
                trailing: Text(
                  formatMinor(reimbursed),
                  key: const Key('reimbursed'),
                ),
              ),
            if (isChild)
              OutlinedButton(
                onPressed: () => context.push('/record/$childOf'),
                child: const Text('查看原账单'),
              ),
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
              if (isAdvance && !advanceSettled)
                FilledButton.tonal(
                  key: const Key('settle-advance'),
                  onPressed: busy ? null : () => _settleAdvance(r),
                  child: const Text('结算转为正式账单'),
                ),
              if (refundable)
                OutlinedButton(
                  key: const Key('add-refund'),
                  onPressed: busy ? null : () => _addLink(r, refund: true),
                  child: const Text('退款'),
                ),
              if (r.type == RecordType.reimbursable)
                OutlinedButton(
                  key: const Key('add-reimbursement'),
                  onPressed: busy ? null : () => _addLink(r, refund: false),
                  child: const Text('登记报销款'),
                ),
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

class _LinkDialog extends StatefulWidget {
  const _LinkDialog({
    required this.title,
    required this.assets,
    required this.initialAsset,
  });
  final String title;
  final List<Asset> assets;
  final int initialAsset;
  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  final amount = TextEditingController();
  late int assetId = widget.assets.any((a) => a.id == widget.initialAsset)
      ? widget.initialAsset
      : noRef;
  String? error;

  @override
  void dispose() {
    amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          key: const Key('link-amount'),
          controller: amount,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: amountInputFormatters,
          decoration: InputDecoration(
            labelText: '金额',
            prefixText: '¥ ',
            errorText: error,
          ),
        ),
        DropdownButtonFormField<int>(
          initialValue: assetId,
          decoration: const InputDecoration(labelText: '入账账户'),
          items: [
            const DropdownMenuItem(value: noRef, child: Text('不选账户')),
            for (final a in widget.assets)
              DropdownMenuItem(value: a.id, child: Text(a.name)),
          ],
          onChanged: (v) => setState(() => assetId = v ?? noRef),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const Key('link-save'),
        onPressed: () {
          try {
            final money = parseAmount(amount.text);
            if (money.units <= BigInt.zero) {
              setState(() => error = '金额须大于 0');
              return;
            }
            Navigator.pop(context, (money, assetId));
          } catch (e) {
            setState(() => error = safeMessage(e));
          }
        },
        child: const Text('保存'),
      ),
    ],
  );
}

class _SettleAdvanceDialog extends StatefulWidget {
  const _SettleAdvanceDialog({
    required this.isIncome,
    required this.defaultAmount,
    required this.assets,
    required this.initialAsset,
  });
  final bool isIncome;
  final String defaultAmount;
  final List<Asset> assets;
  final int initialAsset;
  @override
  State<_SettleAdvanceDialog> createState() => _SettleAdvanceDialogState();
}

class _SettleAdvanceDialogState extends State<_SettleAdvanceDialog> {
  late final amount = TextEditingController(text: widget.defaultAmount);
  late int assetId = widget.assets.any((a) => a.id == widget.initialAsset)
      ? widget.initialAsset
      : noRef;
  bool finish = true;
  String? error;

  @override
  void dispose() {
    amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.isIncome ? '结算预收款' : '结算预支款'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          key: const Key('settle-amount'),
          controller: amount,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: amountInputFormatters,
          decoration: InputDecoration(
            labelText: '实际结算金额',
            prefixText: '¥ ',
            errorText: error,
          ),
        ),
        DropdownButtonFormField<int>(
          initialValue: assetId,
          decoration: InputDecoration(
            labelText: widget.isIncome ? '收款账户' : '扣款账户',
          ),
          items: [
            const DropdownMenuItem(value: noRef, child: Text('不选账户')),
            for (final a in widget.assets)
              DropdownMenuItem(value: a.id, child: Text(a.name)),
          ],
          onChanged: (v) => setState(() => assetId = v ?? noRef),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('结清本笔预收/预支'),
          subtitle: const Text('取消勾选则按部分结算保留剩余待结金额'),
          value: finish,
          onChanged: (v) => setState(() => finish = v ?? true),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const Key('settle-save'),
        onPressed: () {
          try {
            final money = parseAmount(amount.text);
            if (money.units <= BigInt.zero) {
              setState(() => error = '结算金额须大于 0');
              return;
            }
            Navigator.pop(context, (money, assetId, finish));
          } catch (e) {
            setState(() => error = safeMessage(e));
          }
        },
        child: const Text('确认结算'),
      ),
    ],
  );
}
