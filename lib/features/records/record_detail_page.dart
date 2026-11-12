import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/failure.dart';
import '../../core/money.dart';
import '../../data/db/database.dart';
import '../../domain/ledger/record_extra.dart';
import '../../domain/ledger/record_relations.dart';
import '../../domain/model/codes.dart';
import '../attachments/attachment_providers.dart';
import '../common/catalog_icons.dart';
import '../common/common.dart';
import '../receipt/record_receipt_dialog.dart' show showRecordReceiptDialog;
import '../stats/tag_stats_page.dart' show TagColorDot, parseTagColor;
import 'record_labels.dart';

final _maxAmount = Money.parse('88888888888.00');

final _amountInputFormatters = <TextInputFormatter>[
  FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
];

Money _parseAmount(String text) {
  final t = text.trim();
  if (t.isEmpty) return Money.zero();
  final normalized = t.endsWith('.') ? t.substring(0, t.length - 1) : t;
  final money = Money.parse(
    normalized.startsWith('.') ? '0$normalized' : normalized,
  );
  if (money.units > _maxAmount.units) {
    throw const Failure(FailureCode.validation, '金额不能超过 88888888888.00');
  }
  return money;
}

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

  Future<List<Asset>> _loadEligibleAssets() async {
    final cached = ref.read(assetsProvider).value;
    final allAssets =
        cached ??
        await () async {
          final db = await ref.read(databaseProvider.future);
          return (db.select(db.assets)..orderBy([
                (a) => OrderingTerm.asc(a.sort),
                (a) => OrderingTerm.asc(a.id),
              ]))
              .get();
        }();
    return allAssets
        .where(
          (a) => a.status != AssetStatus.settled && a.type != AssetType.debt,
        )
        .toList();
  }

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
      if (mounted) {
        if (GoRouter.maybeOf(context) != null && context.canPop()) {
          context.pop();
        } else {
          await Navigator.of(context).maybePop();
        }
      }
    } catch (e) {
      if (mounted) setState(() => error = safeMessage(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _addLink(LedgerRecord r, {required bool refund}) async {
    final assets = await _loadEligibleAssets();
    if (!mounted) return;
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
    final assets = await _loadEligibleAssets();
    if (!mounted) return;
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

  Widget _buildTagActionChip(BuildContext context, Tag t) {
    final tint = parseTagColor(t.color);
    return ActionChip(
      key: Key('detail-tag-${t.tagId}'),
      avatar: tint != null ? TagColorDot(colorHex: t.color, size: 8) : null,
      backgroundColor: tint?.withValues(alpha: 0.14),
      side: tint == null
          ? null
          : BorderSide(color: tint.withValues(alpha: 0.45)),
      label: Text(t.name),
      onPressed: () => context.push('/stats/tag/${t.tagId}'),
    );
  }

  Widget _buildAccountTrailing(List<Asset> assets, int id) {
    final asset = id == noRef
        ? null
        : assets.where((a) => a.id == id).firstOrNull;
    if (asset == null) {
      return Text(assetName(assets, id));
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 220),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AssetIconAvatar(
            iconKey: asset.icon,
            colorHex: asset.color,
            name: asset.name,
            assetType: asset.type,
            subType: asset.subType,
            size: 24,
          ),
          const SizedBox(width: 8),
          Flexible(child: Text(asset.name, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final record = ref.watch(recordProvider(widget.recordId));
    final assets = ref.watch(assetsProvider).value ?? const <Asset>[];
    final tags =
        ref.watch(recordTagsProvider(widget.recordId)).value ?? const [];
    return Scaffold(
      appBar: AppBar(
        title: const Text('账单详情'),
        actions: [
          if (record.value != null)
            IconButton(
              key: const Key('open-receipt-button'),
              tooltip: '生成小票',
              icon: const Icon(Icons.receipt_long_outlined),
              onPressed: busy
                  ? null
                  : () => showRecordReceiptDialog(
                      context,
                      recordId: record.value!.recordId,
                      initialRecord: record.value,
                    ),
            ),
        ],
      ),
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
        const specializedM4Types = {
          RecordType.borrowIn,
          RecordType.lendOut,
          RecordType.repay,
          RecordType.collect,
          RecordType.debtInterest,
          RecordType.installmentPrincipal,
          RecordType.depositInterest,
        };
        final editable =
            !isChild &&
            !advanceSettled &&
            !specializedM4Types.contains(r.type) &&
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
        final cat = r.recordCatId == noRef
            ? null
            : categories.where((c) => c.id == r.recordCatId).firstOrNull;
        final parentCat = (cat != null && cat.parentCatId != noRef)
            ? categories.where((c) => c.id == cat.parentCatId).firstOrNull
            : null;
        final catDisplayName = cat == null
            ? null
            : (parentCat != null
                  ? '${parentCat.name} · ${cat.name}'
                  : cat.name);
        final catColor =
            (cat?.colorFill != null && cat!.colorFill!.trim().isNotEmpty)
            ? cat.colorFill
            : parentCat?.colorFill;
        final isRefund =
            (r.type == RecordType.expense || r.type == RecordType.income) &&
            r.moneyMinor < BigInt.zero;

        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Row(
              children: [
                RecordTypeIconAvatar(
                  recordType: r.type,
                  subType: r.subType,
                  isRefund: isRefund,
                  categoryName: catDisplayName,
                  categoryIcon: cat?.icon,
                  parentCategoryIcon: parentCat?.icon,
                  categoryColor: catColor,
                  size: 46,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(RecordType.names[r.type] ?? '账单'),
                      Text(
                        label.amount,
                        key: const Key('detail-amount'),
                        style: Theme.of(context).textTheme.displaySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ListTile(
              title: const Text('分类/说明'),
              trailing: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RecordTypeIconAvatar(
                      recordType: r.type,
                      subType: r.subType,
                      isRefund: isRefund,
                      categoryName: catDisplayName,
                      categoryIcon: cat?.icon,
                      parentCategoryIcon: parentCat?.icon,
                      categoryColor: catColor,
                      size: 24,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(label.title, overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
              ),
            ),
            if (r.type == RecordType.transfer) ...[
              ListTile(
                title: const Text('转出'),
                trailing: _buildAccountTrailing(assets, r.fromAssetId),
              ),
              ListTile(
                title: const Text('转入'),
                trailing: _buildAccountTrailing(assets, r.toAssetId),
              ),
            ] else if (r.type == RecordType.borrowIn ||
                r.type == RecordType.collect ||
                (r.type == RecordType.debtInterest &&
                    r.subType == RecordDirection.income)) ...[
              ListTile(
                title: const Text('借贷项目'),
                trailing: _buildAccountTrailing(assets, r.fromAssetId),
              ),
              ListTile(
                title: const Text('资金账户'),
                trailing: _buildAccountTrailing(assets, r.toAssetId),
              ),
            ] else if (r.type == RecordType.lendOut ||
                r.type == RecordType.repay ||
                (r.type == RecordType.debtInterest &&
                    r.subType == RecordDirection.expense)) ...[
              ListTile(
                title: const Text('资金账户'),
                trailing: _buildAccountTrailing(assets, r.fromAssetId),
              ),
              ListTile(
                title: const Text('借贷项目'),
                trailing: _buildAccountTrailing(assets, r.toAssetId),
              ),
            ] else
              ListTile(
                title: const Text('账户'),
                trailing: _buildAccountTrailing(
                  assets,
                  r.type == RecordType.reimbursable ||
                          r.type == RecordType.balanceAdjust
                      ? r.fromAssetId
                      : r.assetId,
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
                    children: [
                      for (final t in tags) _buildTagActionChip(context, t),
                    ],
                  ),
                ),
              ),
            if (r.discountMinor != null && r.discountMinor! > BigInt.zero)
              ListTile(
                key: const Key('detail-discount-tile'),
                title: const Text('优惠'),
                trailing: Text(formatMinor(r.discountMinor!)),
              ),
            if (r.remark.isNotEmpty)
              ListTile(title: const Text('备注'), subtitle: Text(r.remark)),
            ...() {
              BillLocationInfo? loc;
              try {
                loc = RecordExtra.parse(r.extraInfo).location;
              } on Failure {
                loc = null;
              }
              List<String> attached = const <String>[];
              try {
                attached = parseRecordImages(r.images);
              } on Failure {
                attached = const <String>[];
              }
              return <Widget>[
                if (loc != null && !loc.isEmpty)
                  ListTile(
                    key: const Key('detail-location-tile'),
                    title: const Text('地点'),
                    subtitle: Text(
                      loc.detailAddress == null
                          ? loc.displayLabel
                          : '${loc.displayLabel}（${loc.detailAddress}）',
                    ),
                  ),
                if (attached.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: BillAttachmentStrip(
                      key: const Key('detail-attachment-strip'),
                      recordId: r.recordId,
                      readOnly: true,
                    ),
                  ),
              ];
            }(),
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
          inputFormatters: _amountInputFormatters,
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
            final money = _parseAmount(amount.text);
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
          inputFormatters: _amountInputFormatters,
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
            final money = _parseAmount(amount.text);
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
