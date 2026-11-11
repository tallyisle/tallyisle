import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
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
import '../../domain/rules/asset_overview.dart' show normalizeCurrency;
import '../../domain/rules/currency_rates.dart';
import '../attachments/attachment_providers.dart';
import '../automation/automation_providers.dart'
    show widgetSnapshotServiceProvider;
import '../budget/budget_widgets.dart';
import '../common/common.dart';
import '../receipt/diy_toolbar_settings_page.dart';
import '../receipt/receipt_diy_providers.dart';
import '../receipt/record_receipt_dialog.dart' show BillLocationEditorDialog;
import '../templates/template_providers.dart';
import '../templates/templates_page.dart'
    show FrequentRemarkChips, TemplatePrefill, TemplateQuickBar;

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
  const RecordEditorPage({
    super.key,
    this.recordId,
    this.initialType,
    this.initialCategory,
    this.initialTemplateId,
    this.initialAsset,
    this.initialFrom,
    this.initialTo,
    this.initialAmount,
    this.initialRemark,
  });
  final String? recordId;
  final int? initialType;
  final int? initialCategory;
  final int? initialTemplateId;

  /// Prefill for new bills (e.g. "还款" from a credit card opens a transfer).
  final int? initialAsset;
  final int? initialFrom;
  final int? initialTo;
  final String? initialAmount;
  final String? initialRemark;
  @override
  ConsumerState<RecordEditorPage> createState() => _RecordEditorPageState();
}

class _RecordEditorPageState extends ConsumerState<RecordEditorPage> {
  final amount = TextEditingController();
  final converted = TextEditingController();
  final discount = TextEditingController();
  final fee = TextEditingController();
  final remark = TextEditingController();
  final ids = CommandIds();
  final imageIds = CommandIds();
  final remarkIds = CommandIds();

  int type = RecordType.expense;
  int? categoryId;
  int? parentCatId;
  Set<String> selectedTagIds = {};
  List<String> imageNames = const <String>[];
  BillLocationInfo? location;
  int assetId = noRef, fromAssetId = noRef, toAssetId = noRef;

  /// Currency the amount is entered in; null = the account currency.
  String? sourceCurrency;

  /// The user typed the converted amount themselves (stop auto-filling).
  bool convertedEdited = false;
  bool feeFromTarget = false;
  bool excludeBudget = false, excludeExIn = false;
  DateTime time = DateTime.now();
  LedgerRecord? original;
  bool loading = true, busy = false;
  String? error;

  bool get editing => widget.recordId != null;

  String _currencyOf(int id) {
    if (id == noRef) return baseCurrency;
    final assets = ref.read(assetsProvider).value ?? const <Asset>[];
    final a = assets.where((x) => x.id == id).firstOrNull;
    return normalizeCurrency(a?.currency) ?? baseCurrency;
  }

  /// (entered currency, booked currency) for the current form.
  (String, String) _currencies() {
    if (type == RecordType.transfer) {
      return (_currencyOf(fromAssetId), _currencyOf(toAssetId));
    }
    final ac = _currencyOf(assetId);
    return (sourceCurrency ?? ac, ac);
  }

  /// Fills [converted] from the manual rates unless the user edited it.
  void _autoConvert() {
    if (convertedEdited) return;
    final (sc, ac) = _currencies();
    if (sc == ac) {
      converted.text = '';
      return;
    }
    final rates = ref.read(rateTableProvider).value;
    final text = amount.text.trim();
    if (rates == null || text.isEmpty) {
      converted.text = '';
      return;
    }
    try {
      final minor = parseAmount(text).storageMinor;
      converted.text = formatMinor(rates.convert(minor, sc, ac));
    } on Failure {
      converted.text = '';
    }
  }

  void _applyTemplatePrefill(TemplatePrefill prefill) {
    setState(() {
      type = prefill.type;
      categoryId = prefill.categoryId;
      parentCatId = prefill.parentCategoryId;
      assetId = prefill.assetId;
      fromAssetId = prefill.fromAssetId;
      toAssetId = prefill.toAssetId;
      amount.text = prefill.amountText;
      fee.text = prefill.feeText;
      feeFromTarget = prefill.feeFromTarget;
      remark.text = prefill.remark;
      excludeBudget = prefill.excludeBudget;
      excludeExIn = prefill.excludeExIn;
      selectedTagIds = prefill.tagIds.toSet();
      sourceCurrency = prefill.sourceCurrency;
      convertedEdited = false;
      _autoConvert();
    });
  }

  Future<void> _pickLocation() async {
    final res = await showDialog<BillLocationInfo>(
      context: context,
      builder: (_) => BillLocationEditorDialog(initial: location),
    );
    if (res == null || !mounted) return;
    setState(() => location = res.isEmpty ? null : res);
  }

  @override
  void initState() {
    super.initState();
    type = widget.initialType ?? RecordType.expense;
    categoryId = widget.initialCategory;
    assetId = widget.initialAsset ?? noRef;
    fromAssetId = widget.initialFrom ?? noRef;
    toAssetId = widget.initialTo ?? noRef;
    if (widget.initialAmount != null) amount.text = widget.initialAmount!;
    if (widget.initialRemark != null) remark.text = widget.initialRemark!;
    _load();
  }

  Future<void> _load() async {
    try {
      if (editing) {
        final q = await ref.read(queriesProvider.future);
        final r = await ref.read(recordProvider(widget.recordId!).future);
        if (r == null) throw const Failure(FailureCode.conflict, '账单不存在或已删除');
        if (!const {
          RecordType.expense,
          RecordType.income,
          RecordType.transfer,
          RecordType.reimbursable,
          RecordType.advanceIncome,
          RecordType.advanceExpense,
        }.contains(r.type)) {
          throw const Failure(
            FailureCode.validation,
            '该类型账单不支持在此编辑，请前往对应功能模块管理',
          );
        }
        final feeRow = await q.feeChildOf(r.recordId);
        original = r;
        type = r.type;
        categoryId = r.recordCatId == noRef ? null : r.recordCatId;
        assetId = r.type == RecordType.reimbursable ? r.fromAssetId : r.assetId;
        fromAssetId = r.fromAssetId;
        toAssetId = r.toAssetId;
        amount.text = formatMinor(r.moneyMinor);
        if (r.discountMinor != null && r.discountMinor! > BigInt.zero) {
          discount.text = formatMinor(r.discountMinor!);
        }
        remark.text = r.remark;
        excludeBudget = r.excludeBudget;
        excludeExIn = r.excludeExIn;
        time = DateTime.fromMillisecondsSinceEpoch(r.recordTime);
        try {
          imageNames = parseRecordImages(r.images);
        } on Failure {
          imageNames = const <String>[];
        }
        final parsedExtra = RecordExtra.parse(r.extraInfo);
        try {
          location = parsedExtra.location;
        } on Failure {
          location = null;
        }
        final snap = parsedExtra.currency;
        if (snap != null && snap.isValid && snap.assetNet != null) {
          final sc = normalizeCurrency(snap.sourceCode) ?? baseCurrency;
          final ac = normalizeCurrency(snap.assetCode) ?? baseCurrency;
          if (r.type == RecordType.transfer) {
            if (sc != ac) {
              converted.text = formatMinor(snap.assetNet!);
              convertedEdited = true;
            }
          } else if (sc != ac) {
            sourceCurrency = sc;
            amount.text = formatMinor(snap.sourceGross);
            converted.text = formatMinor(snap.assetNet!);
            convertedEdited = true;
          }
        }
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
      } else if (widget.initialTemplateId != null) {
        final tplSvc = await ref.read(templateRemarkServiceProvider.future);
        final prefill = await tplSvc.buildTemplatePrefill(
          widget.initialTemplateId!,
        );
        if (mounted) _applyTemplatePrefill(prefill);
      }
    } catch (e) {
      error = safeMessage(e);
    }
    if (mounted) setState(() => loading = false);
  }

  @override
  void dispose() {
    amount.dispose();
    converted.dispose();
    discount.dispose();
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
        if (type == RecordType.reimbursable ||
            type == RecordType.advanceIncome ||
            type == RecordType.advanceExpense) {
          if (money.units <= BigInt.zero) {
            throw const Failure(FailureCode.validation, '金额须大于 0');
          }
        } else if (money.isZero) {
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
      final extra = RecordExtra.parse(keepOldExtra?.extraInfo);
      extra.location = location;
      final parsedDiscount =
          (type == RecordType.expense || type == RecordType.income) &&
              discount.text.trim().isNotEmpty
          ? parseAmount(discount.text)
          : null;
      final effectiveDiscount = parsedDiscount != null && !parsedDiscount.isZero
          ? parsedDiscount
          : null;
      // Multi-currency (ledger-catalog §4 `curr`): `money` is the booked amount
      // (account currency) for bills and the source amount for transfers.
      final (sc, ac) = _currencies();
      var booked = money;
      if (sc != ac) {
        final rates = await ref.read(rateTableProvider.future);
        final text = converted.text.trim();
        final target = text.isEmpty
            ? Money.minor(rates.convert(money.storageMinor, sc, ac))
            : parseAmount(text);
        if (!money.isZero && target.units <= BigInt.zero) {
          throw const Failure(FailureCode.validation, '折算金额须大于 0');
        }
        if (type != RecordType.transfer) booked = target;
        extra.currency = billSnapshot(
          source: sc,
          sourceMinor: money.storageMinor,
          account: ac,
          assetMinor: target.storageMinor,
          rates: rates,
        );
      } else if (sc != baseCurrency) {
        final rates = await ref.read(rateTableProvider.future);
        extra.currency = billSnapshot(
          source: sc,
          sourceMinor: money.storageMinor,
          account: ac,
          assetMinor: money.storageMinor,
          rates: rates,
        );
      } else {
        extra.currency = null;
      }
      final draft = RecordDraft(
        type: type,
        money: booked,
        bookId: bookId,
        recordTime: time.millisecondsSinceEpoch,
        categoryId: type == RecordType.transfer ? noRef : categoryId!,
        assetId:
            (type == RecordType.transfer || type == RecordType.reimbursable)
            ? noRef
            : assetId,
        fromAssetId: type == RecordType.transfer
            ? fromAssetId
            : (type == RecordType.reimbursable ? assetId : noRef),
        toAssetId: type == RecordType.transfer ? toAssetId : noRef,
        remark: remark.text.trim(),
        excludeBudget: excludeBudget,
        excludeExIn: excludeExIn,
        discount: effectiveDiscount,
        extra: extra,
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
      List<String> oldImages = const <String>[];
      if (old != null) {
        try {
          oldImages = parseRecordImages(old.images);
        } on Failure {
          oldImages = const <String>[];
        }
      }
      if (imageNames.isNotEmpty || oldImages.isNotEmpty) {
        final attSvc = await ref.read(billAttachmentServiceProvider.future);
        await attSvc.setRecordImages(
          commandId: imageIds.forPayload(['editor-images', id, imageNames]),
          recordId: id,
          imageNames: imageNames,
        );
      }
      if (type != RecordType.transfer && draft.remark.isNotEmpty) {
        try {
          final remarkSvc = await ref.read(
            templateRemarkServiceProvider.future,
          );
          await remarkSvc.recordRemarkUsage(
            commandId: remarkIds.forPayload([
              'editor-remark-usage',
              id,
              draft.categoryId,
              draft.remark,
            ]),
            recordCatId: draft.categoryId,
            content: draft.remark,
          );
          if (mounted) {
            ref.invalidate(remarksForCategoryProvider(draft.categoryId));
            ref.invalidate(allRemarksProvider);
          }
        } catch (_) {
          // Non-blocking frequent-remark counter update.
        }
      }
      try {
        final widgetSvc = await ref.read(widgetSnapshotServiceProvider.future);
        await widgetSvc.syncToPlatform();
      } catch (_) {
        // Non-blocking desktop widget refresh.
      }
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
        .where(
          (a) => a.status != AssetStatus.settled && a.type != AssetType.debt,
        )
        .toList();
    final tags = (ref.watch(activeTagsProvider).value ?? const <Tag>[])
        .where((t) => t.parent != 1)
        .toList();
    final currencies =
        [...(ref.watch(currenciesProvider).value ?? const <Currency>[])]..sort(
          (a, b) => a.code == b.code
              ? 0
              : a.code == baseCurrency
              ? -1
              : b.code == baseCurrency
              ? 1
              : a.code.compareTo(b.code),
        );
    ref.watch(rateTableProvider);
    final diyConfig =
        ref.watch(diyToolbarConfigProvider).value ??
        DiyToolbarConfig.defaults();

    return PopScope(
      canPop: !busy,
      child: Scaffold(
        appBar: AppBar(
          title: Text(editing ? '编辑账单' : '记一笔'),
          actions: [
            if (!editing && diyConfig.isEnabled(DiyToolbarAction.templates))
              IconButton(
                key: const Key('editor-templates-btn'),
                tooltip: '账单模板',
                icon: const Icon(Icons.bookmarks_outlined),
                onPressed: busy
                    ? null
                    : () {
                        if (GoRouter.maybeOf(context) != null) {
                          context.push('/templates');
                        }
                      },
              ),
            IconButton(
              key: const Key('editor-diy-toolbar-btn'),
              tooltip: '记账工具栏自定义',
              icon: const Icon(Icons.tune),
              onPressed: busy
                  ? null
                  : () {
                      if (GoRouter.maybeOf(context) != null) {
                        context.push('/settings/diy-toolbar');
                      } else {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const DiyToolbarSettingsPage(),
                          ),
                        );
                      }
                    },
            ),
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (bookId != null &&
                  categoryId != null &&
                  (type == RecordType.expense ||
                      type == RecordType.income ||
                      type == RecordType.reimbursable))
                RecordBudgetHintBar(
                  bookId: bookId,
                  recordTime: time.millisecondsSinceEpoch,
                  categoryId: categoryId!,
                  excludeBudget: excludeBudget,
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton(
                  key: const Key('save'),
                  onPressed: busy || loading || (editing && original == null)
                      ? null
                      : _submit,
                  child: Text(busy ? '保存中…' : '保存'),
                ),
              ),
            ],
          ),
        ),
        body: loading
            ? const Loading()
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: ListView(
                    scrollCacheExtent: const ScrollCacheExtent.pixels(800),
                    padding: const EdgeInsets.all(16),
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final (value, label) in const [
                            (RecordType.expense, '支出'),
                            (RecordType.income, '收入'),
                            (RecordType.transfer, '转账'),
                            (RecordType.reimbursable, '报销'),
                            (RecordType.advanceExpense, '预支'),
                            (RecordType.advanceIncome, '预收'),
                          ])
                            ChoiceChip(
                              key: Key('type-$value'),
                              label: Text(label),
                              selected: type == value,
                              onSelected: busy || editing
                                  ? null
                                  : (_) => setState(() {
                                      type = value;
                                      categoryId = null;
                                      parentCatId = null;
                                    }),
                            ),
                        ],
                      ),
                      if (!editing &&
                          bookId != null &&
                          diyConfig.isEnabled(DiyToolbarAction.templates)) ...[
                        const SizedBox(height: 8),
                        TemplateQuickBar(
                          bookId: bookId,
                          recordType: type,
                          enabled: !busy,
                          recordTimeMs: time.millisecondsSinceEpoch,
                          onPrefill: _applyTemplatePrefill,
                          onInstantSaved: (savedId) {
                            if (!mounted) return;
                            if (GoRouter.maybeOf(context) != null &&
                                context.canPop()) {
                              context.pop(savedId);
                            } else if (GoRouter.maybeOf(context) != null) {
                              context.go('/');
                            }
                          },
                        ),
                      ],
                      const SizedBox(height: 16),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: TextField(
                              key: const Key('amount'),
                              controller: amount,
                              enabled: !busy,
                              autofocus: !editing,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              inputFormatters: amountInputFormatters,
                              style: Theme.of(context).textTheme.headlineSmall,
                              onChanged: (_) => setState(_autoConvert),
                              decoration: InputDecoration(
                                labelText: '金额',
                                prefixText: '${_currencies().$1} ',
                                border: const OutlineInputBorder(),
                              ),
                            ),
                          ),
                          if (type != RecordType.transfer &&
                              currencies.length > 1 &&
                              (diyConfig.isEnabled(DiyToolbarAction.currency) ||
                                  sourceCurrency != null)) ...[
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 112,
                              child: DropdownButtonFormField<String>(
                                key: ValueKey(
                                  'source-currency-${_currencies().$2}',
                                ),
                                initialValue: _currencies().$1,
                                decoration: const InputDecoration(
                                  labelText: '币种',
                                  border: OutlineInputBorder(),
                                ),
                                items: [
                                  for (final c in currencies)
                                    DropdownMenuItem(
                                      value: c.code,
                                      child: Text(c.code),
                                    ),
                                ],
                                onChanged: busy
                                    ? null
                                    : (v) => setState(() {
                                        sourceCurrency = v;
                                        convertedEdited = false;
                                        _autoConvert();
                                      }),
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (_currencies().$1 != _currencies().$2) ...[
                        const SizedBox(height: 12),
                        TextField(
                          key: const Key('converted'),
                          controller: converted,
                          enabled: !busy,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          inputFormatters: amountInputFormatters,
                          onChanged: (_) => convertedEdited = true,
                          decoration: InputDecoration(
                            labelText: type == RecordType.transfer
                                ? '转入金额（${_currencies().$2}）'
                                : '折合账户金额（${_currencies().$2}）',
                            prefixText: '${_currencies().$2} ',
                            helperText: '按“币种与汇率”中的汇率自动折算，可改成实际金额',
                          ),
                        ),
                      ],
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
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          labelText: '备注',
                          suffixIcon:
                              type != RecordType.transfer &&
                                  GoRouter.maybeOf(context) != null
                              ? IconButton(
                                  key: const Key('editor-remarks-btn'),
                                  tooltip: '常用备注管理',
                                  icon: const Icon(
                                    Icons.comment_outlined,
                                    size: 20,
                                  ),
                                  onPressed: busy
                                      ? null
                                      : () => context.push(
                                          categoryId == null
                                              ? '/remarks'
                                              : '/remarks?categoryId=$categoryId',
                                        ),
                                )
                              : null,
                        ),
                      ),
                      if (type != RecordType.transfer && categoryId != null)
                        FrequentRemarkChips(
                          categoryId: categoryId!,
                          selectedRemark: remark.text,
                          enabled: !busy,
                          onSelectRemark: (value) =>
                              setState(() => remark.text = value),
                        ),
                      if (type != RecordType.transfer) ...[
                        if (diyConfig.isEnabled(DiyToolbarAction.excludeExIn) ||
                            excludeExIn)
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('不计入收支'),
                            value: excludeExIn,
                            onChanged: busy
                                ? null
                                : (v) => setState(() => excludeExIn = v),
                          ),
                        if (diyConfig.isEnabled(
                              DiyToolbarAction.excludeBudget,
                            ) ||
                            excludeBudget)
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('不计入预算'),
                            value: excludeBudget,
                            onChanged: busy
                                ? null
                                : (v) => setState(() => excludeBudget = v),
                          ),
                      ],
                      if (tags.isNotEmpty &&
                          (diyConfig.isEnabled(DiyToolbarAction.tags) ||
                              selectedTagIds.isNotEmpty)) ...[
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
                      if ((type == RecordType.expense ||
                              type == RecordType.income) &&
                          (diyConfig.isEnabled(DiyToolbarAction.discount) ||
                              discount.text.trim().isNotEmpty)) ...[
                        const SizedBox(height: 12),
                        TextField(
                          key: const Key('discount'),
                          controller: discount,
                          enabled: !busy,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          inputFormatters: amountInputFormatters,
                          decoration: InputDecoration(
                            labelText: '优惠金额（可选）',
                            prefixText: '${_currencies().$2} ',
                          ),
                        ),
                      ],
                      if (diyConfig.isEnabled(DiyToolbarAction.location) ||
                          (location != null && !location!.isEmpty))
                        ListTile(
                          key: const Key('record-location-tile'),
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.place_outlined),
                          title: Text(
                            location == null || location!.isEmpty
                                ? '添加消费地点（可选）'
                                : location!.displayLabel,
                          ),
                          subtitle: location?.detailAddress != null
                              ? Text(location!.detailAddress!)
                              : null,
                          trailing: const Icon(Icons.chevron_right),
                          onTap: busy ? null : _pickLocation,
                        ),
                      if (diyConfig.isEnabled(DiyToolbarAction.images) ||
                          imageNames.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        BillAttachmentStrip(
                          key: const Key('record-attachment-strip'),
                          imageNames: imageNames,
                          readOnly: busy,
                          onChanged: (next) =>
                              setState(() => imageNames = next),
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
    final wantCatType =
        (type == RecordType.income || type == RecordType.advanceIncome)
        ? RecordType.income
        : RecordType.expense;
    final topCats = all
        .where(
          (c) => c.type == wantCatType && !c.isHide && c.parentCatId == noRef,
        )
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
        initialValue: assets.any((a) => a.id == assetId) ? assetId : noRef,
        decoration: const InputDecoration(labelText: '账户'),
        items: [
          const DropdownMenuItem(value: noRef, child: Text('不选账户')),
          for (final a in assets)
            DropdownMenuItem(value: a.id, child: Text(a.name)),
        ],
        onChanged: busy
            ? null
            : (v) => setState(() {
                assetId = v ?? noRef;
                _autoConvert();
              }),
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
      initialValue: assets.any((a) => a.id == value) ? value : null,
      decoration: InputDecoration(labelText: label),
      items: [
        for (final a in assets)
          DropdownMenuItem(value: a.id, child: Text(a.name)),
      ],
      onChanged: busy
          ? null
          : (v) => setState(() {
              set(v ?? noRef);
              convertedEdited = false;
              _autoConvert();
            }),
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
