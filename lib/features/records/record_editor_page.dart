import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/failure.dart';
import '../../core/money.dart';
import '../../data/db/database.dart';
import '../../data/ledger/ledger_service.dart';
import '../../domain/ledger/record_extra.dart';
import '../../domain/ledger/record_relations.dart';
import '../../domain/model/codes.dart';
import '../common/common.dart';

/// Original keyboard upper bound (ledger-catalog §5).
final maxAmount = Money.parse('88888888888.00');

final amountInputFormatters = <TextInputFormatter>[
  FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
];

Money parseAmount(String text) {
  final t = text.trim();
  if (t.isEmpty) return Money.zero();
  final normalized = t.endsWith('.') ? t.substring(0, t.length - 1) : t;
  final money = Money.parse(
    normalized.startsWith('.') ? '0$normalized' : normalized,
  );
  if (money.units > maxAmount.units) {
    throw const Failure(FailureCode.validation, '金额不能超过 88888888888.00');
  }
  return money;
}

class RecordEditorPage extends ConsumerStatefulWidget {
  const RecordEditorPage({super.key, this.recordId, this.initialType});
  final String? recordId;
  final int? initialType;
  @override
  ConsumerState<RecordEditorPage> createState() => _RecordEditorPageState();
}

class _RecordEditorPageState extends ConsumerState<RecordEditorPage> {
  final amount = TextEditingController();
  final fee = TextEditingController();
  final remark = TextEditingController();
  final ids = CommandIds();

  int type = RecordType.expense;
  int? categoryId;
  int? parentCatId;
  Set<String> selectedTagIds = {};
  int assetId = noRef, fromAssetId = noRef, toAssetId = noRef;
  bool feeFromTarget = false;
  bool excludeBudget = false, excludeExIn = false;
  DateTime time = DateTime.now();
  LedgerRecord? original;
  bool loading = true, busy = false;
  String? error;

  bool get editing => widget.recordId != null;

  @override
  void initState() {
    super.initState();
    type = widget.initialType ?? RecordType.expense;
    _load();
  }

  Future<void> _load() async {
    try {
      if (editing) {
        final q = await ref.read(queriesProvider.future);
        final r = await ref.read(recordProvider(widget.recordId!).future);
        if (r == null) throw const Failure(FailureCode.conflict, '账单不存在或已删除');
        final feeRow = await q.feeChildOf(r.recordId);
        original = r;
        type = r.type;
        categoryId = r.recordCatId == noRef ? null : r.recordCatId;
        assetId = r.assetId;
        fromAssetId = r.fromAssetId;
        toAssetId = r.toAssetId;
        amount.text = formatMinor(r.moneyMinor);
        remark.text = r.remark;
        excludeBudget = r.excludeBudget;
        excludeExIn = r.excludeExIn;
        time = DateTime.fromMillisecondsSinceEpoch(r.recordTime);
        if (feeRow != null) {
          fee.text = formatMinor(feeRow.moneyMinor);
          feeFromTarget =
              RecordRelations.parse(r.relInfo).transferFee?.feeFromTarget ??
              false;
          // The parent may have been shifted by -1 ms at midnight.
          if (feeRow.recordTime == r.recordTime + 1) {
            time = DateTime.fromMillisecondsSinceEpoch(r.recordTime);
          } else {
            time = DateTime.fromMillisecondsSinceEpoch(feeRow.recordTime);
          }
        }
        final cq = await ref.read(catalogQueriesProvider.future);
        final tagIds = await cq.getTagIdsForRecord(r.recordId);
        selectedTagIds = tagIds.toSet();
      }
    } catch (e) {
      error = safeMessage(e);
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  void dispose() {
    amount.dispose();
    fee.dispose();
    remark.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final old = original;
      final int bookId = old != null
          ? old.accountBookId
          : await ref.read(currentBookIdProvider.future);
      final money = parseAmount(amount.text);
      if (type == RecordType.transfer) {
        if (money.units <= BigInt.zero) {
          throw const Failure(FailureCode.validation, '转账金额须大于 0');
        }
      } else {
        if (categoryId == null) {
          throw const Failure(FailureCode.validation, '请选择分类');
        }
        if (money.isZero) {
          if (!mounted) return;
          final ok = await confirm(
            context,
            title: '金额为 0',
            message: '确定保存一笔 0.00 的账单吗？',
          );
          if (!ok || !mounted) return;
        }
      }
      final keepOldExtra = original != null && original!.type == type
          ? original
          : null;
      final draft = RecordDraft(
        type: type,
        money: money,
        bookId: bookId,
        recordTime: time.millisecondsSinceEpoch,
        categoryId: type == RecordType.transfer ? noRef : categoryId!,
        assetId: type == RecordType.transfer ? noRef : assetId,
        fromAssetId: type == RecordType.transfer ? fromAssetId : noRef,
        toAssetId: type == RecordType.transfer ? toAssetId : noRef,
        remark: remark.text.trim(),
        excludeBudget: excludeBudget,
        excludeExIn: excludeExIn,
        extra: RecordExtra.parse(keepOldExtra?.extraInfo),
        relations: RecordRelations.parse(keepOldExtra?.relInfo),
        fee: type == RecordType.transfer ? parseAmount(fee.text) : null,
        feeFromTarget: feeFromTarget,
        tagIds: selectedTagIds.toList(),
      );
      final service = await ref.read(ledgerServiceProvider.future);
      final id = await service.saveRecord(
        commandId: ids.forPayload([widget.recordId, ...draft.payload]),
        recordId: widget.recordId,
        draft: draft,
      );
      if (!mounted) return;
      if (context.canPop()) {
        context.pop(id);
      } else {
        context.go('/');
      }
    } catch (e) {
      if (mounted) setState(() => error = safeMessage(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _pickTime() async {
    final date = await showDatePicker(
      context: context,
      initialDate: time,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (date == null || !mounted) return;
    final clock = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(time),
    );
    if (!mounted) return;
    setState(() {
      time = DateTime(
        date.year,
        date.month,
        date.day,
        clock?.hour ?? time.hour,
        clock?.minute ?? time.minute,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final bookId =
        original?.accountBookId ?? ref.watch(currentBookIdProvider).value;
    final categories = bookId == null
        ? const <RecordCategory>[]
        : ref.watch(categoriesProvider(bookId)).value ?? const [];
    final assets = (ref.watch(assetsProvider).value ?? const <Asset>[])
        .where((a) => a.status != AssetStatus.settled)
        .toList();
    final tags = (ref.watch(activeTagsProvider).value ?? const <Tag>[])
        .where((t) => t.parent != 1)
        .toList();

    return PopScope(
      canPop: !busy,
      child: Scaffold(
        appBar: AppBar(title: Text(editing ? '编辑账单' : '记一笔')),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: FilledButton(
              key: const Key('save'),
              onPressed: busy || loading ? null : _submit,
              child: Text(busy ? '保存中…' : '保存'),
            ),
          ),
        ),
        body: loading
            ? const Loading()
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      SegmentedButton<int>(
                        segments: const [
                          ButtonSegment(
                            value: RecordType.expense,
                            label: Text('支出'),
                          ),
                          ButtonSegment(
                            value: RecordType.income,
                            label: Text('收入'),
                          ),
                          ButtonSegment(
                            value: RecordType.transfer,
                            label: Text('转账'),
                          ),
                        ],
                        selected: {type},
                        onSelectionChanged: busy || editing
                            ? null
                            : (s) => setState(() {
                                type = s.first;
                                categoryId = null;
                                parentCatId = null;
                              }),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        key: const Key('amount'),
                        controller: amount,
                        enabled: !busy,
                        autofocus: !editing,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: amountInputFormatters,
                        style: Theme.of(context).textTheme.headlineSmall,
                        decoration: const InputDecoration(
                          labelText: '金额',
                          prefixText: '¥ ',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (type == RecordType.transfer)
                        ..._transferFields(assets)
                      else
                        ..._categoryFields(categories, assets),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.schedule),
                        title: Text(formatDateTime(time)),
                        onTap: busy ? null : _pickTime,
                      ),
                      TextField(
                        key: const Key('remark'),
                        controller: remark,
                        enabled: !busy,
                        maxLength: 200,
                        decoration: const InputDecoration(labelText: '备注'),
                      ),
                      if (type != RecordType.transfer) ...[
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('不计入收支'),
                          value: excludeExIn,
                          onChanged: busy
                              ? null
                              : (v) => setState(() => excludeExIn = v),
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('不计入预算'),
                          value: excludeBudget,
                          onChanged: busy
                              ? null
                              : (v) => setState(() => excludeBudget = v),
                        ),
                      ],
                      if (tags.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          '标签',
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final t in tags)
                              FilterChip(
                                key: Key('tag-${t.name}'),
                                label: Text(t.name),
                                selected: selectedTagIds.contains(t.tagId),
                                onSelected: busy
                                    ? null
                                    : (sel) => setState(() {
                                        if (sel) {
                                          selectedTagIds.add(t.tagId);
                                        } else {
                                          selectedTagIds.remove(t.tagId);
                                        }
                                      }),
                              ),
                          ],
                        ),
                      ],
                      if (error != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                            error!,
                            key: const Key('form-error'),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }

  List<Widget> _categoryFields(List<RecordCategory> all, List<Asset> assets) {
    if (categoryId != null && parentCatId == null) {
      final chosen = all.where((c) => c.id == categoryId).firstOrNull;
      if (chosen != null) {
        if (chosen.parentCatId == noRef || chosen.parentCatId == -1) {
          parentCatId = chosen.id;
        } else {
          parentCatId = chosen.parentCatId;
        }
      }
    }
    final topCats = all
        .where((c) => c.type == type && !c.isHide && c.parentCatId == noRef)
        .toList();
    final subCats = parentCatId == null
        ? const <RecordCategory>[]
        : all.where((c) => c.parentCatId == parentCatId && !c.isHide).toList();

    return [
      Text('分类', style: Theme.of(context).textTheme.labelLarge),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final c in topCats)
            ChoiceChip(
              key: Key('cat-${c.name}'),
              label: Text(c.name),
              selected: parentCatId == c.id,
              onSelected: busy
                  ? null
                  : (_) => setState(() {
                      parentCatId = c.id;
                      categoryId = c.id;
                    }),
            ),
        ],
      ),
      if (subCats.isNotEmpty) ...[
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              key: const Key('subcat-all'),
              label: const Text('全部'),
              selected: categoryId == parentCatId,
              onSelected: busy
                  ? null
                  : (_) => setState(() => categoryId = parentCatId),
            ),
            for (final s in subCats)
              ChoiceChip(
                key: Key('cat-${s.name}'),
                label: Text(s.name),
                selected: categoryId == s.id,
                onSelected: busy
                    ? null
                    : (_) => setState(() => categoryId = s.id),
              ),
          ],
        ),
      ],
      const SizedBox(height: 16),
      DropdownButtonFormField<int>(
        key: const Key('asset'),
        initialValue: assetId,
        decoration: const InputDecoration(labelText: '账户'),
        items: [
          const DropdownMenuItem(value: noRef, child: Text('不选账户')),
          for (final a in assets)
            DropdownMenuItem(value: a.id, child: Text(a.name)),
        ],
        onChanged: busy ? null : (v) => setState(() => assetId = v ?? noRef),
      ),
    ];
  }

  List<Widget> _transferFields(List<Asset> assets) {
    DropdownButtonFormField<int> picker(
      String label,
      int value,
      ValueChanged<int> set,
      Key key,
    ) => DropdownButtonFormField<int>(
      key: key,
      initialValue: value == noRef ? null : value,
      decoration: InputDecoration(labelText: label),
      items: [
        for (final a in assets)
          DropdownMenuItem(value: a.id, child: Text(a.name)),
      ],
      onChanged: busy ? null : (v) => setState(() => set(v ?? noRef)),
    );
    return [
      if (assets.length < 2)
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text('转账至少需要两个账户，请先在“资产”页添加账户。'),
        ),
      picker('转出账户', fromAssetId, (v) => fromAssetId = v, const Key('from')),
      picker('转入账户', toAssetId, (v) => toAssetId = v, const Key('to')),
      const SizedBox(height: 12),
      TextField(
        key: const Key('fee'),
        controller: fee,
        enabled: !busy,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: amountInputFormatters,
        decoration: const InputDecoration(
          labelText: '手续费（可选）',
          prefixText: '¥ ',
        ),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('手续费由转入账户承担'),
        value: feeFromTarget,
        onChanged: busy ? null : (v) => setState(() => feeFromTarget = v),
      ),
    ];
  }
}
