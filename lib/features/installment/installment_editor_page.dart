import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../data/installment/installment_service.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/installment_rules.dart';
import '../common/common.dart';
import '../records/record_editor_page.dart'
    show amountInputFormatters, parseAmount;
import '../records/record_labels.dart' show assetName, categoryName;
import 'installment_providers.dart';

/// Create / edit page for an installment plan (F-010, original `/bkp/CreateInstAct`).
class InstallmentEditorPage extends ConsumerStatefulWidget {
  const InstallmentEditorPage({super.key, this.installmentId});

  final int? installmentId;

  @override
  ConsumerState<InstallmentEditorPage> createState() =>
      _InstallmentEditorPageState();
}

class _InstallmentEditorPageState extends ConsumerState<InstallmentEditorPage> {
  final _nameCtrl = TextEditingController();
  final _principalCtrl = TextEditingController();
  final _periodsCtrl = TextEditingController(text: '6');
  final _chargeCtrl = TextEditingController();
  final _ids = CommandIds();

  int _bookId = 1;
  bool _bookInitialized = false;
  int _catId = noRef;
  int _assetId = noRef;
  bool _assetInitialized = false;

  int _chargeWay = InstallmentChargeWay.perPeriod;
  int _calWay = InstallmentCalWay.halfUp2;
  int _remainderIn = InstallmentRemainderIn.firstPeriod;
  DateTime _startDate = _todayLocal();
  bool _catchUpDueNow = false;

  bool _principalCounted = true;
  bool _interestCounted = false;
  bool _excludeBudget = false;
  bool _excludeExIn = false;
  Set<String> _selectedTagIds = <String>{};

  Installment? _editingRow;
  bool _loadingEdit = false;
  bool _busy = false;
  String? _error;

  bool get _isEditing => widget.installmentId != null;

  static DateTime _todayLocal() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  @override
  void initState() {
    super.initState();
    _loadingEdit = true;
    if (_isEditing) {
      _loadExisting();
    } else {
      _loadCreateDefaults();
    }
  }

  Future<void> _loadCreateDefaults() async {
    try {
      final bookId = await ref.read(currentBookIdProvider.future);
      await Future.wait<Object?>([
        ref.read(booksProvider.future),
        ref.read(assetsProvider.future),
        ref.read(categoriesProvider(bookId).future),
        ref.read(tagsProvider.future),
      ]);
      if (!mounted) return;
      final allAssets = ref.read(assetsProvider).value ?? const <Asset>[];
      final usable = [
        for (final a in allAssets)
          if (a.status == AssetStatus.active && a.type != AssetType.debt) a,
      ];
      setState(() {
        _bookId = bookId;
        _bookInitialized = true;
        if (usable.isNotEmpty) {
          final creditFirst = usable
              .where((a) => a.type == AssetType.credit)
              .firstOrNull;
          _assetId = (creditFirst ?? usable.first).id;
          _assetInitialized = true;
        }
        _loadingEdit = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = safeMessage(e);
        _loadingEdit = false;
      });
    }
  }

  Future<void> _loadExisting() async {
    try {
      final q = await ref.read(installmentQueriesProvider.future);
      final row = await q.getInstallment(widget.installmentId!);
      if (!mounted) return;
      if (row == null) {
        setState(() {
          _error = '分期计划不存在或已删除';
          _loadingEdit = false;
        });
        return;
      }
      await Future.wait<Object?>([
        ref.read(booksProvider.future),
        ref.read(assetsProvider.future),
        ref.read(categoriesProvider(row.bookId).future),
        ref.read(tagsProvider.future),
      ]);
      if (!mounted) return;
      final extra = InstallmentExtra.parse(row.exi);
      setState(() {
        _editingRow = row;
        _nameCtrl.text = row.name;
        _bookId = row.bookId;
        _bookInitialized = true;
        _catId = row.catId;
        _assetId = row.assetId;
        _assetInitialized = true;
        _principalCounted = extra.principalCounted;
        _interestCounted = extra.interestCounted;
        _excludeBudget = row.excludeBudget;
        _excludeExIn = row.excludeExIn;
        _selectedTagIds = parseInstallmentTags(row.tags).toSet();
        _loadingEdit = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = safeMessage(e);
        _loadingEdit = false;
      });
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _principalCtrl.dispose();
    _periodsCtrl.dispose();
    _chargeCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickStartDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100, 12, 31),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _startDate = DateTime(picked.year, picked.month, picked.day);
    });
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final service = await ref.read(installmentServiceProvider.future);
      if (_isEditing) {
        final payload = [
          'update',
          widget.installmentId,
          _nameCtrl.text.trim(),
          _catId,
          _bookId,
          _excludeBudget,
          _excludeExIn,
          _selectedTagIds.toList()..sort(),
          _principalCounted,
          _interestCounted,
        ];
        await service.updateInstallment(
          commandId: _ids.forPayload(payload),
          installmentId: widget.installmentId!,
          name: _nameCtrl.text,
          catId: _catId,
          bookId: _bookId,
          excludeBudget: _excludeBudget,
          excludeExIn: _excludeExIn,
          tagIds: _selectedTagIds.toList()..sort(),
          principalCounted: _principalCounted,
          interestCounted: _interestCounted,
        );
        if (mounted) Navigator.of(context).pop(widget.installmentId);
      } else {
        final principal = parseAmount(_principalCtrl.text);
        final charge = parseAmount(_chargeCtrl.text);
        final periods = int.tryParse(_periodsCtrl.text.trim()) ?? 0;
        final draft = InstallmentDraft(
          name: _nameCtrl.text,
          catId: _catId,
          principal: principal,
          periods: periods,
          charge: charge,
          chargeWay: _chargeWay,
          calWay: _calWay,
          remainderIn: _remainderIn,
          startDateMs: _startDate.millisecondsSinceEpoch,
          assetId: _assetId,
          bookId: _bookId,
          excludeBudget: _excludeBudget,
          excludeExIn: _excludeExIn,
          tagIds: _selectedTagIds.toList()..sort(),
          principalCounted: _principalCounted,
          interestCounted: _interestCounted,
          catchUpDueNow: _catchUpDueNow,
        );
        final id = await service.createInstallment(
          commandId: _ids.forPayload(draft.payload),
          draft: draft,
        );
        if (mounted) Navigator.of(context).pop(id);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = safeMessage(e));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  List<InstallmentPeriodItem>? _tryBuildPreview() {
    if (_isEditing) return null;
    try {
      final principal = parseAmount(_principalCtrl.text);
      if (principal.storageMinor <= BigInt.zero) return null;
      final charge = parseAmount(_chargeCtrl.text);
      if (charge.storageMinor < BigInt.zero) return null;
      final periods = int.tryParse(_periodsCtrl.text.trim()) ?? 0;
      if (periods < 1 || periods > 360) return null;
      return buildInstallmentSchedule(
        installmentId: 0,
        principalMinor: principal.storageMinor,
        periods: periods,
        chargeMinor: charge.storageMinor,
        chargeWay: _chargeWay,
        calWay: _calWay,
        remainderIn: _remainderIn,
        startDateMs: _startDate.millisecondsSinceEpoch,
      );
    } on Object {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentBookAsync = ref.watch(currentBookIdProvider);
    if (!_bookInitialized && currentBookAsync.hasValue) {
      _bookId = currentBookAsync.value!;
      _bookInitialized = true;
    }

    final books = ref.watch(booksProvider).value ?? const <AccountBook>[];
    final allAssets = ref.watch(assetsProvider).value ?? const <Asset>[];
    final usableAssets = [
      for (final a in allAssets)
        if (a.status == AssetStatus.active && a.type != AssetType.debt) a,
    ];

    if (!_isEditing && !_assetInitialized && usableAssets.isNotEmpty) {
      final creditFirst = usableAssets
          .where((a) => a.type == AssetType.credit)
          .firstOrNull;
      _assetId = (creditFirst ?? usableAssets.first).id;
      _assetInitialized = true;
    }

    final allCategories =
        ref.watch(categoriesProvider(_bookId)).value ??
        const <RecordCategory>[];
    final expenseCategories = [
      for (final c in allCategories)
        if (c.type == RecordType.expense && (!c.isHide || c.id == _catId)) c,
    ];
    final validCatIds = <int>{noRef, for (final c in expenseCategories) c.id};
    final effectiveCatId = validCatIds.contains(_catId) ? _catId : noRef;

    final selectedAsset = allAssets.where((a) => a.id == _assetId).firstOrNull;
    final isCreditAsset = selectedAsset?.type == AssetType.credit;

    final tags = (ref.watch(tagsProvider).value ?? const <Tag>[])
        .where(
          (t) =>
              (!t.hidden || _selectedTagIds.contains(t.tagId)) && t.parent != 1,
        )
        .toList();

    final preview = _tryBuildPreview();

    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        key: const Key('installment_editor_page'),
        appBar: AppBar(title: Text(_isEditing ? '编辑分期信息' : '新建分期')),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: FilledButton(
              key: const Key('save_installment_button'),
              onPressed:
                  _busy || _loadingEdit || (_isEditing && _editingRow == null)
                  ? null
                  : _submit,
              child: Text(_busy ? '保存中…' : '保存'),
            ),
          ),
        ),
        body: _loadingEdit
            ? const Loading()
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (_error != null) ...[
                        Card(
                          color: Theme.of(context).colorScheme.errorContainer,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(
                              _error!,
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onErrorContainer,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                      TextField(
                        key: const Key('installment_name_input'),
                        controller: _nameCtrl,
                        enabled: !_busy,
                        maxLength: 50,
                        decoration: const InputDecoration(
                          labelText: '分期名称',
                          hintText: '例如：笔记本电脑、账单分期',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (_isEditing && _editingRow != null) ...[
                        _ReadonlyScheduleSummaryCard(
                          installment: _editingRow!,
                          assets: allAssets,
                        ),
                        const SizedBox(height: 16),
                      ] else if (!_isEditing) ...[
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              flex: 3,
                              child: TextField(
                                key: const Key('installment_principal_input'),
                                controller: _principalCtrl,
                                enabled: !_busy,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                inputFormatters: amountInputFormatters,
                                onChanged: (_) => setState(() {}),
                                decoration: const InputDecoration(
                                  labelText: '分期总本金',
                                  prefixText: '¥ ',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              flex: 2,
                              child: TextField(
                                key: const Key('installment_periods_input'),
                                controller: _periodsCtrl,
                                enabled: !_busy,
                                keyboardType: TextInputType.number,
                                inputFormatters: [
                                  FilteringTextInputFormatter.digitsOnly,
                                ],
                                onChanged: (_) => setState(() {}),
                                decoration: const InputDecoration(
                                  labelText: '分期期数',
                                  suffixText: '期',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          key: const Key('installment_charge_input'),
                          controller: _chargeCtrl,
                          enabled: !_busy,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          inputFormatters: amountInputFormatters,
                          onChanged: (_) => setState(() {}),
                          decoration: const InputDecoration(
                            labelText: '总手续费（选填）',
                            hintText: '0.00',
                            prefixText: '¥ ',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        _LabeledDropdown<int>(
                          fieldKey: const Key(
                            'installment_charge_way_dropdown',
                          ),
                          label: '手续费收取方式',
                          value: _chargeWay,
                          enabled: !_busy,
                          items: [
                            for (final way in [
                              InstallmentChargeWay.firstPeriod,
                              InstallmentChargeWay.perPeriod,
                              InstallmentChargeWay.lastPeriod,
                            ])
                              DropdownMenuItem(
                                value: way,
                                child: Text(InstallmentChargeWay.labelOf(way)),
                              ),
                          ],
                          onChanged: (v) {
                            if (v != null) setState(() => _chargeWay = v);
                          },
                        ),
                        const SizedBox(height: 12),
                        _LabeledDropdown<int>(
                          fieldKey: const Key('installment_cal_way_dropdown'),
                          label: '每期金额取舍方式',
                          value: _calWay,
                          enabled: !_busy,
                          items: [
                            for (final way in [
                              InstallmentCalWay.halfUp2,
                              InstallmentCalWay.floor2,
                              InstallmentCalWay.halfUp0,
                              InstallmentCalWay.floor0,
                            ])
                              DropdownMenuItem(
                                value: way,
                                child: Text(InstallmentCalWay.labelOf(way)),
                              ),
                          ],
                          onChanged: (v) {
                            if (v != null) setState(() => _calWay = v);
                          },
                        ),
                        const SizedBox(height: 12),
                        _LabeledDropdown<int>(
                          fieldKey: const Key('installment_remainder_dropdown'),
                          label: '除不尽余数归属',
                          value: _remainderIn,
                          enabled: !_busy,
                          items: [
                            for (final rem in [
                              InstallmentRemainderIn.firstPeriod,
                              InstallmentRemainderIn.lastPeriod,
                            ])
                              DropdownMenuItem(
                                value: rem,
                                child: Text(
                                  InstallmentRemainderIn.labelOf(rem),
                                ),
                              ),
                          ],
                          onChanged: (v) {
                            if (v != null) setState(() => _remainderIn = v);
                          },
                        ),
                        const SizedBox(height: 12),
                        _LabeledDropdown<int>(
                          fieldKey: const Key('installment_asset_dropdown'),
                          label: '扣款账户',
                          value: usableAssets.any((a) => a.id == _assetId)
                              ? _assetId
                              : null,
                          hint: usableAssets.isEmpty ? '暂无可用扣款账户' : '请选择扣款账户',
                          enabled: !_busy && usableAssets.isNotEmpty,
                          items: [
                            for (final a in usableAssets)
                              DropdownMenuItem(
                                value: a.id,
                                child: Text(a.name),
                              ),
                          ],
                          onChanged: (v) {
                            if (v != null) setState(() => _assetId = v);
                          },
                        ),
                        const SizedBox(height: 8),
                        ListTile(
                          key: const Key('installment_start_date_tile'),
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.event),
                          title: const Text('首期入账日期'),
                          subtitle: Text(formatDate(_startDate)),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: _busy ? null : _pickStartDate,
                        ),
                        if (!_startDate.isAfter(_todayLocal()))
                          SwitchListTile(
                            key: const Key('installment_catchup_now_switch'),
                            contentPadding: EdgeInsets.zero,
                            title: const Text('已到期期次立即自动入账'),
                            subtitle: const Text('开启后保存时自动补记首期及之前已到期账单'),
                            value: _catchUpDueNow,
                            onChanged: _busy
                                ? null
                                : (v) => setState(() => _catchUpDueNow = v),
                          ),
                        const SizedBox(height: 8),
                      ],
                      if (books.length > 1) ...[
                        _LabeledDropdown<int>(
                          fieldKey: const Key('installment_book_dropdown'),
                          label: '所属账本',
                          value: books.any((b) => b.id == _bookId)
                              ? _bookId
                              : books.first.id,
                          enabled: !_busy,
                          items: [
                            for (final b in books)
                              DropdownMenuItem(
                                value: b.id,
                                child: Text(b.name),
                              ),
                          ],
                          onChanged: (v) {
                            if (v != null && v != _bookId) {
                              setState(() {
                                _bookId = v;
                                _catId = noRef;
                              });
                            }
                          },
                        ),
                        const SizedBox(height: 12),
                      ],
                      _LabeledDropdown<int>(
                        fieldKey: const Key('installment_category_dropdown'),
                        label: '支出分类',
                        value: effectiveCatId,
                        enabled: !_busy,
                        items: [
                          const DropdownMenuItem(
                            value: noRef,
                            child: Text('不选分类（账单分期）'),
                          ),
                          for (final c in expenseCategories)
                            DropdownMenuItem(
                              value: c.id,
                              child: Text(categoryName(allCategories, c.id)),
                            ),
                        ],
                        onChanged: (v) {
                          if (v != null) setState(() => _catId = v);
                        },
                      ),
                      if (isCreditAsset) ...[
                        const SizedBox(height: 12),
                        Card(
                          key: const Key('installment_credit_options_card'),
                          margin: EdgeInsets.zero,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 4,
                            ),
                            child: Column(
                              children: [
                                SwitchListTile(
                                  key: const Key('installment_cb_switch'),
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('未入账本金占用信用额度'),
                                  subtitle: const Text('计入信用卡待还总负债与已用额度'),
                                  value: _principalCounted,
                                  onChanged: _busy
                                      ? null
                                      : (v) => setState(
                                          () => _principalCounted = v,
                                        ),
                                ),
                                SwitchListTile(
                                  key: const Key('installment_ci_switch'),
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('未入账手续费占用信用额度'),
                                  subtitle: const Text('开启后未入账手续费一并计入待还负债'),
                                  value: _interestCounted,
                                  onChanged: _busy
                                      ? null
                                      : (v) => setState(
                                          () => _interestCounted = v,
                                        ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      SwitchListTile(
                        key: const Key('installment_exclude_budget_switch'),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('不计入预算'),
                        value: _excludeBudget,
                        onChanged: _busy
                            ? null
                            : (v) => setState(() => _excludeBudget = v),
                      ),
                      SwitchListTile(
                        key: const Key('installment_exclude_exin_switch'),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('不计入收支统计'),
                        value: _excludeExIn,
                        onChanged: _busy
                            ? null
                            : (v) => setState(() => _excludeExIn = v),
                      ),
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
                                key: Key('installment_tag_${t.tagId}'),
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
                      if (preview != null && preview.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        _SchedulePreviewCard(schedule: preview),
                      ],
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}

class _LabeledDropdown<T> extends StatelessWidget {
  const _LabeledDropdown({
    required this.fieldKey,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    this.enabled = true,
    this.hint,
  });

  final Key fieldKey;
  final String label;
  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;
  final bool enabled;
  final String? hint;

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
        value: value,
        hint: hint == null ? null : Text(hint!),
        items: items,
        onChanged: enabled ? onChanged : null,
      ),
    ),
  );
}

class _ReadonlyScheduleSummaryCard extends StatelessWidget {
  const _ReadonlyScheduleSummaryCard({
    required this.installment,
    required this.assets,
  });

  final Installment installment;
  final List<Asset> assets;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: const Key('installment_readonly_summary_card'),
      margin: EdgeInsets.zero,
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '分期计划参数（不可修改已创建本金与期数）',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '总本金 ¥${formatMinor(installment.principalMinor)} · 共 ${installment.periods} 期 · 手续费 ¥${formatMinor(installment.chargeMinor)}',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '账户: ${assetName(assets, installment.assetId)} · 首期: ${formatDate(DateTime.fromMillisecondsSinceEpoch(installment.startDate))}',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _SchedulePreviewCard extends StatelessWidget {
  const _SchedulePreviewCard({required this.schedule});

  final List<InstallmentPeriodItem> schedule;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final first = schedule.first;
    final last = schedule.last;
    final mid = schedule.length > 2 ? schedule[1] : null;
    var sumPrincipal = BigInt.zero;
    var sumFee = BigInt.zero;
    for (final item in schedule) {
      sumPrincipal += item.principalMinor;
      sumFee += item.feeMinor;
    }

    return Card(
      key: const Key('installment_preview_card'),
      margin: EdgeInsets.zero,
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '还款计划预览（共 ${schedule.length} 期）',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            _PreviewRow(label: '第 1 期', item: first),
            if (mid != null)
              _PreviewRow(
                label: schedule.length == 3
                    ? '第 2 期'
                    : '第 2..${schedule.length - 1} 期',
                item: mid,
              ),
            if (schedule.length > 1)
              _PreviewRow(label: '第 ${last.period} 期', item: last),
            const Divider(height: 16),
            Text(
              '合计应还 ¥${formatMinor(sumPrincipal + sumFee)}（本金 ¥${formatMinor(sumPrincipal)} + 手续费 ¥${formatMinor(sumFee)}）',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewRow extends StatelessWidget {
  const _PreviewRow({required this.label, required this.item});

  final String label;
  final InstallmentPeriodItem item;

  @override
  Widget build(BuildContext context) {
    final feePart = item.feeMinor == BigInt.zero
        ? ''
        : '（含手续费 ¥${formatMinor(item.feeMinor)}）';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$label · ${formatDate(DateTime.fromMillisecondsSinceEpoch(item.plannedDateMs))}',
            ),
          ),
          Text('¥${formatMinor(item.totalMinor)}$feePart'),
        ],
      ),
    );
  }
}
