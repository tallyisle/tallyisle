import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../data/tools/template_remark_service.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/asset_overview.dart' show normalizeCurrency;
import '../../domain/rules/currency_rates.dart' show baseCurrency;
import '../../domain/rules/template_card_rules.dart';
import '../common/common.dart';
import 'remarks_page.dart';
import 'template_providers.dart';

final _decimalFormatters = <TextInputFormatter>[
  FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
];

/// Create / edit page for `RecordTemplate` (`F-016`).
class TemplateEditorPage extends ConsumerStatefulWidget {
  const TemplateEditorPage({
    super.key,
    this.templateId,
    this.initialBookId,
    this.initialType,
  });

  final int? templateId;
  final int? initialBookId;
  final int? initialType;

  @override
  ConsumerState<TemplateEditorPage> createState() => _TemplateEditorPageState();
}

class _TemplateEditorPageState extends ConsumerState<TemplateEditorPage> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _amountController = TextEditingController();
  final TextEditingController _feeController = TextEditingController();
  final TextEditingController _remarkController = TextEditingController();
  final CommandIds _ids = CommandIds();

  int _type = RecordType.expense;
  int? _bookId;
  int? _categoryId;
  int? _parentCatId;
  int _assetId = noRef;
  int _fromAssetId = noRef;
  int _toAssetId = noRef;
  String? _sourceCurrency;
  bool _feeFromTarget = false;
  bool _excludeBudget = false;
  bool _excludeExIn = false;
  bool _autoSave = false;
  Set<String> _selectedTagIds = <String>{};

  bool _loading = true;
  bool _busy = false;
  String? _error;

  bool get _editing => widget.templateId != null;

  @override
  void initState() {
    super.initState();
    _type = widget.initialType ?? RecordType.expense;
    _bookId = widget.initialBookId;
    _load();
  }

  Future<void> _load() async {
    try {
      final defaultBookId = await ref.read(currentBookIdProvider.future);
      if (_editing) {
        final svc = await ref.read(templateRemarkServiceProvider.future);
        final row = await svc.getTemplate(widget.templateId!);
        if (row == null) {
          _error = '账单模板不存在或已删除';
        } else {
          final extra = TemplateExtra.parse(row.exi);
          _type = row.type;
          _bookId = row.bookId;
          _nameController.text = extra.name ?? '';
          _amountController.text = row.moneyMinor > BigInt.zero
              ? formatMinor(row.moneyMinor)
              : '';
          _feeController.text = row.feeMinor > BigInt.zero
              ? formatMinor(row.feeMinor)
              : '';
          _remarkController.text = row.remark ?? '';
          _feeFromTarget = extra.feeFromTarget;
          _sourceCurrency = extra.sourceCurrency;
          _excludeBudget = row.excludeBudget;
          _excludeExIn = row.excludeExIn;
          _autoSave = row.autoSave;
          _selectedTagIds = parseTemplateTagsCsv(row.tags).toSet();
          if (row.type == RecordType.transfer) {
            _fromAssetId = row.assetId;
            _toAssetId = row.assetId2;
          } else {
            _categoryId = (row.recordCatId == null || row.recordCatId == noRef)
                ? null
                : row.recordCatId;
            _assetId = row.assetId;
          }
        }
      } else {
        _bookId ??= defaultBookId;
      }
    } catch (e) {
      _error = safeMessage(e);
    }
    if (mounted) {
      setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _amountController.dispose();
    _feeController.dispose();
    _remarkController.dispose();
    super.dispose();
  }

  String _accountCurrency(List<Asset> assets, int id) {
    if (id == noRef) return baseCurrency;
    final found = assets.where((a) => a.id == id).firstOrNull;
    return normalizeCurrency(found?.currency) ?? baseCurrency;
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final int resolvedBookId =
          _bookId ?? await ref.read(currentBookIdProvider.future);
      final money = parseTemplateMoneyText(_amountController.text);
      final fee = _type == RecordType.transfer
          ? parseTemplateMoneyText(_feeController.text)
          : null;

      final draft = TemplateDraft(
        type: _type,
        money: money,
        bookId: resolvedBookId,
        name: _nameController.text,
        fee: fee,
        feeFromTarget: _feeFromTarget,
        categoryId: _type == RecordType.transfer ? null : _categoryId,
        assetId: _type == RecordType.transfer ? _fromAssetId : _assetId,
        assetId2: _type == RecordType.transfer ? _toAssetId : noRef,
        remark: _remarkController.text,
        autoSave: _autoSave,
        excludeBudget: _excludeBudget,
        excludeExIn: _excludeExIn,
        tagIds: _selectedTagIds.toList(growable: false),
        sourceCurrency: _type == RecordType.transfer ? null : _sourceCurrency,
      );

      final svc = await ref.read(templateRemarkServiceProvider.future);
      final savedId = await svc.saveTemplate(
        commandId: _ids.forPayload(<Object?>[
          widget.templateId,
          ...draft.payload,
        ]),
        templateId: widget.templateId,
        draft: draft,
      );
      if (!mounted) return;
      Navigator.of(context).maybePop(savedId);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = safeMessage(e));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final books = ref.watch(booksProvider).value ?? const <AccountBook>[];
    final currentBookId = ref.watch(currentBookIdProvider).value;
    final effectiveBookId =
        (_bookId != null && books.any((b) => b.id == _bookId))
        ? _bookId
        : (currentBookId ?? (books.isEmpty ? null : books.first.id));

    final categories = effectiveBookId == null
        ? const <RecordCategory>[]
        : (ref.watch(categoriesProvider(effectiveBookId)).value ??
              const <RecordCategory>[]);
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

    final accountCurr = _type == RecordType.transfer
        ? _accountCurrency(assets, _fromAssetId)
        : _accountCurrency(assets, _assetId);
    final enteredCurr = _type == RecordType.transfer
        ? accountCurr
        : (_sourceCurrency ?? accountCurr);

    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        key: const Key('template_editor_page'),
        appBar: AppBar(title: Text(_editing ? '编辑模板' : '新建模板')),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: FilledButton(
              key: const Key('save_template_button'),
              onPressed: _busy || _loading ? null : _submit,
              child: Text(_busy ? '保存中…' : '保存模板'),
            ),
          ),
        ),
        body: _loading
            ? const Loading()
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final (value, label) in const <(int, String)>[
                            (RecordType.expense, '支出'),
                            (RecordType.income, '收入'),
                            (RecordType.transfer, '转账'),
                            (RecordType.reimbursable, '报销'),
                            (RecordType.advanceExpense, '预支'),
                            (RecordType.advanceIncome, '预收'),
                          ])
                            ChoiceChip(
                              key: Key('template_type_$value'),
                              label: Text(label),
                              selected: _type == value,
                              onSelected: _busy
                                  ? null
                                  : (_) => setState(() {
                                      _type = value;
                                      _categoryId = null;
                                      _parentCatId = null;
                                    }),
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        key: const Key('template_name_input'),
                        controller: _nameController,
                        enabled: !_busy,
                        maxLength: maxTemplateNameLength,
                        decoration: const InputDecoration(
                          labelText: '模板名称（可选，如：早餐地铁）',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      if (books.isNotEmpty && effectiveBookId != null) ...[
                        const SizedBox(height: 8),
                        _ControlledDropdown<int>(
                          fieldKey: const Key('template_book_dropdown'),
                          label: '所属账本',
                          enabled: !_busy,
                          value: effectiveBookId,
                          items: [
                            for (final b in books)
                              DropdownMenuItem<int>(
                                value: b.id,
                                child: Text(b.name),
                              ),
                          ],
                          onChanged: (v) {
                            if (v == null) return;
                            setState(() {
                              _bookId = v;
                              _categoryId = null;
                              _parentCatId = null;
                            });
                          },
                        ),
                      ],
                      const SizedBox(height: 16),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: TextField(
                              key: const Key('template_amount_input'),
                              controller: _amountController,
                              enabled: !_busy,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              inputFormatters: _decimalFormatters,
                              decoration: InputDecoration(
                                labelText: '预设金额',
                                prefixText: '$enteredCurr ',
                                border: const OutlineInputBorder(),
                              ),
                            ),
                          ),
                          if (_type != RecordType.transfer &&
                              currencies.length > 1) ...[
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 120,
                              child: _ControlledDropdown<String>(
                                fieldKey: const Key(
                                  'template_currency_dropdown',
                                ),
                                label: '币种',
                                enabled: !_busy,
                                value:
                                    currencies.any((c) => c.code == enteredCurr)
                                    ? enteredCurr
                                    : currencies.first.code,
                                items: [
                                  for (final c in currencies)
                                    DropdownMenuItem<String>(
                                      value: c.code,
                                      child: Text(c.code),
                                    ),
                                ],
                                onChanged: (v) =>
                                    setState(() => _sourceCurrency = v),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (_type == RecordType.transfer)
                        ..._buildTransferFields(assets)
                      else
                        ..._buildCategoryAndAssetFields(categories, assets),
                      const SizedBox(height: 16),
                      TextField(
                        key: const Key('template_remark_input'),
                        controller: _remarkController,
                        enabled: !_busy,
                        maxLength: 200,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          labelText: '预设备注',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      if (_type != RecordType.transfer)
                        FrequentRemarkChips(
                          categoryId: _categoryId ?? noRef,
                          selectedRemark: _remarkController.text,
                          enabled: !_busy,
                          onSelectRemark: (text) => setState(() {
                            _remarkController.text = text;
                          }),
                        ),
                      const SizedBox(height: 8),
                      SwitchListTile(
                        key: const Key('template_autosave_tile'),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('点击模板直接生成账单（秒记）'),
                        subtitle: const Text('开启后点击快捷模板立即入账；关闭则仅预填记账表单'),
                        value: _autoSave,
                        onChanged: _busy
                            ? null
                            : (v) => setState(() => _autoSave = v),
                      ),
                      if (_type != RecordType.transfer) ...[
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('不计入收支'),
                          value: _excludeExIn,
                          onChanged: _busy
                              ? null
                              : (v) => setState(() => _excludeExIn = v),
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('不计入预算'),
                          value: _excludeBudget,
                          onChanged: _busy
                              ? null
                              : (v) => setState(() => _excludeBudget = v),
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
                                key: Key('template_tag_${t.tagId}'),
                                label: Text(t.name),
                                selected: _selectedTagIds.contains(t.tagId),
                                onSelected: _busy
                                    ? null
                                    : (sel) => setState(() {
                                        if (sel) {
                                          _selectedTagIds.add(t.tagId);
                                        } else {
                                          _selectedTagIds.remove(t.tagId);
                                        }
                                      }),
                              ),
                          ],
                        ),
                      ],
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            _error!,
                            key: const Key('template_form_error'),
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

  List<Widget> _buildCategoryAndAssetFields(
    List<RecordCategory> all,
    List<Asset> assets,
  ) {
    final wantType = templateCategoryTypeFor(_type) ?? RecordType.expense;
    if (_categoryId != null && _parentCatId == null) {
      final chosen = all.where((c) => c.id == _categoryId).firstOrNull;
      if (chosen != null && !chosen.isHide && chosen.type == wantType) {
        _parentCatId = chosen.parentCatId == noRef
            ? chosen.id
            : chosen.parentCatId;
      } else {
        _categoryId = null;
      }
    }
    final topCats = all
        .where((c) => c.type == wantType && !c.isHide && c.parentCatId == noRef)
        .toList();
    final subCats = _parentCatId == null
        ? const <RecordCategory>[]
        : all.where((c) => c.parentCatId == _parentCatId && !c.isHide).toList();

    final controlledAsset = assets.any((a) => a.id == _assetId)
        ? _assetId
        : noRef;

    return [
      Text('分类', style: Theme.of(context).textTheme.labelLarge),
      const SizedBox(height: 8),
      if (topCats.isEmpty)
        const Text('当前账本暂无可用分类')
      else
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final c in topCats)
              ChoiceChip(
                key: Key('template_cat_${c.name}'),
                label: Text(c.name),
                selected: _parentCatId == c.id,
                onSelected: _busy
                    ? null
                    : (_) => setState(() {
                        _parentCatId = c.id;
                        _categoryId = c.id;
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
              key: const Key('template_subcat_all'),
              label: const Text('全部'),
              selected: _categoryId == _parentCatId,
              onSelected: _busy
                  ? null
                  : (_) => setState(() => _categoryId = _parentCatId),
            ),
            for (final s in subCats)
              ChoiceChip(
                key: Key('template_cat_${s.name}'),
                label: Text(s.name),
                selected: _categoryId == s.id,
                onSelected: _busy
                    ? null
                    : (_) => setState(() => _categoryId = s.id),
              ),
          ],
        ),
      ],
      const SizedBox(height: 16),
      _ControlledDropdown<int>(
        fieldKey: const Key('template_asset_dropdown'),
        label: '关联账户',
        enabled: !_busy,
        value: controlledAsset,
        items: [
          const DropdownMenuItem<int>(value: noRef, child: Text('不选账户')),
          for (final a in assets)
            DropdownMenuItem<int>(value: a.id, child: Text(a.name)),
        ],
        onChanged: (v) => setState(() => _assetId = v ?? noRef),
      ),
    ];
  }

  List<Widget> _buildTransferFields(List<Asset> assets) {
    final validFrom = assets.any((a) => a.id == _fromAssetId)
        ? _fromAssetId
        : noRef;
    final validTo = assets.any((a) => a.id == _toAssetId) ? _toAssetId : noRef;

    return [
      _ControlledDropdown<int>(
        fieldKey: const Key('template_from_asset_dropdown'),
        label: '转出账户',
        enabled: !_busy,
        value: validFrom,
        items: [
          const DropdownMenuItem<int>(value: noRef, child: Text('请选择转出账户')),
          for (final a in assets)
            DropdownMenuItem<int>(value: a.id, child: Text(a.name)),
        ],
        onChanged: (v) => setState(() => _fromAssetId = v ?? noRef),
      ),
      const SizedBox(height: 12),
      _ControlledDropdown<int>(
        fieldKey: const Key('template_to_asset_dropdown'),
        label: '转入账户',
        enabled: !_busy,
        value: validTo,
        items: [
          const DropdownMenuItem<int>(value: noRef, child: Text('请选择转入账户')),
          for (final a in assets)
            DropdownMenuItem<int>(value: a.id, child: Text(a.name)),
        ],
        onChanged: (v) => setState(() => _toAssetId = v ?? noRef),
      ),
      const SizedBox(height: 12),
      TextField(
        key: const Key('template_fee_input'),
        controller: _feeController,
        enabled: !_busy,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: _decimalFormatters,
        decoration: const InputDecoration(
          labelText: '手续费（可选）',
          prefixText: '¥ ',
          border: OutlineInputBorder(),
        ),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('手续费由转入账户承担'),
        value: _feeFromTarget,
        onChanged: _busy ? null : (v) => setState(() => _feeFromTarget = v),
      ),
    ];
  }
}

class _ControlledDropdown<T> extends StatelessWidget {
  const _ControlledDropdown({
    required this.fieldKey,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    required this.enabled,
  });

  final Key fieldKey;
  final String label;
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) => InputDecorator(
    decoration: InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    ),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<T>(
        key: fieldKey,
        isExpanded: true,
        isDense: true,
        value: value,
        items: items,
        onChanged: enabled ? onChanged : null,
      ),
    ),
  );
}
