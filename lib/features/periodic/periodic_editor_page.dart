import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/failure.dart';
import '../../core/money.dart';
import '../../data/db/database.dart';
import '../../data/periodic/periodic_service.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/asset_overview.dart' show normalizeCurrency;
import '../../domain/rules/currency_rates.dart' show baseCurrency;
import '../../domain/rules/periodic_records.dart';
import '../common/common.dart';
import 'periodic_providers.dart';

final _maxAmount = Money.parse('88888888888.00');

final _amountFormatters = <TextInputFormatter>[
  FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
];

Money _parseMoney(String text, {bool allowZero = false}) {
  final t = text.trim();
  if (t.isEmpty) {
    if (allowZero) return Money.zero();
    throw const Failure(FailureCode.validation, '请输入金额');
  }
  final normalized = t.endsWith('.') ? t.substring(0, t.length - 1) : t;
  final money = Money.parse(
    normalized.startsWith('.') ? '0$normalized' : normalized,
  );
  if (money.units > _maxAmount.units) {
    throw const Failure(FailureCode.validation, '金额不能超过 88888888888.00');
  }
  if (!allowZero && money.units <= BigInt.zero) {
    throw const Failure(FailureCode.validation, '金额须大于 0');
  }
  return money;
}

/// Create / edit page for periodic bookkeeping rules (F-009).
class PeriodicEditorPage extends ConsumerStatefulWidget {
  const PeriodicEditorPage({super.key, this.periodId});

  final int? periodId;

  @override
  ConsumerState<PeriodicEditorPage> createState() => _PeriodicEditorPageState();
}

class _PeriodicEditorPageState extends ConsumerState<PeriodicEditorPage> {
  final _amountCtrl = TextEditingController();
  final _feeCtrl = TextEditingController();
  final _freqCtrl = TextEditingController(text: '1');
  final _endCountCtrl = TextEditingController(text: '12');
  final _remarkCtrl = TextEditingController();
  final _ids = CommandIds();

  int _recordType = RecordType.expense;
  int? _bookId;
  int? _categoryId;
  int? _parentCatId;
  int _assetId = noRef;
  int _fromAssetId = noRef;
  int _toAssetId = noRef;
  bool _feeFromTarget = false;

  int _periodType = PeriodType.monthly;
  Set<String> _weeklyDays = {'1'};
  Set<String> _monthlyDays = {'1'};
  List<String> _yearlyDates = ['01-01'];

  CalendarDate _startDate = CalendarDate.fromDateTime(DateTime.now());
  PeriodEndMode _endMode = PeriodEndMode.never;
  CalendarDate _endDate = CalendarDate.fromDateTime(DateTime.now());

  bool _recordTimeEnabled = false;
  int _rtHour = 9;
  int _rtMinute = 0;

  bool _excludeBudget = false;
  bool _excludeExIn = false;
  Set<String> _selectedTagIds = {};

  bool _loading = true;
  bool _busy = false;
  String? _error;

  bool get _editing => widget.periodId != null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final db = await ref.read(databaseProvider.future);
      final today = CalendarDate.fromEpochMs(db.nowMs());
      _startDate = today;
      _endDate = today.plusDays(30);
      _weeklyDays = {'${today.weekday}'};
      _monthlyDays = {'${today.day}'};
      _yearlyDates = ['${two(today.month)}-${two(today.day)}'];

      if (_editing) {
        final q = await ref.read(periodicQueriesProvider.future);
        final rule = await q.getPeriod(widget.periodId!);
        if (rule == null) {
          throw const Failure(FailureCode.conflict, '周期记账规则不存在或已删除');
        }
        _bookId = rule.bookId;
        _recordType = rule.recordType;
        _amountCtrl.text = formatMinor(rule.moneyMinor);
        if (rule.recordType == RecordType.transfer) {
          _fromAssetId = rule.assetId;
          _toAssetId = rule.assetId2;
          if (rule.feeMinor > BigInt.zero) {
            _feeCtrl.text = formatMinor(rule.feeMinor);
          }
        } else {
          _categoryId = rule.catId == noRef ? null : rule.catId;
          _assetId = rule.assetId;
        }
        _remarkCtrl.text = rule.remark;
        _excludeBudget = rule.excludeBudget;
        _excludeExIn = rule.excludeExIn;

        _periodType = rule.periodType;
        _freqCtrl.text = '${rule.frequency}';
        final tokens = parsePeriodTypeDateJson(
          rule.periodType,
          rule.periodTypeDate,
        );
        if (rule.periodType == PeriodType.weekly && tokens.isNotEmpty) {
          _weeklyDays = tokens.toSet();
        } else if (rule.periodType == PeriodType.monthly && tokens.isNotEmpty) {
          _monthlyDays = tokens.toSet();
        } else if (rule.periodType == PeriodType.yearly && tokens.isNotEmpty) {
          _yearlyDates = tokens;
        }

        _startDate = CalendarDate.fromEpochMs(rule.periodStartDate);
        _endMode = classifyPeriodEndDate(rule.periodEndDate);
        if (_endMode == PeriodEndMode.count) {
          _endCountCtrl.text = '${rule.periodEndDate}';
        } else if (_endMode == PeriodEndMode.date) {
          _endDate = CalendarDate.fromEpochMs(rule.periodEndDate);
        }

        final extra = PeriodExtra.parse(rule.exi);
        _feeFromTarget = extra.feeFromTarget;
        _recordTimeEnabled = extra.recordTimeEnabled;
        final hm = parseHourMinute(extra.recordTime ?? rule.time);
        if (hm != null) {
          _rtHour = hm.$1;
          _rtMinute = hm.$2;
        }

        final allTags = await db.select(db.tags).get();
        final byId = {for (final t in allTags) t.tagId: t.tagId};
        final byName = {for (final t in allTags) t.name: t.tagId};
        final resolved = <String>{};
        for (final token in parsePeriodTagTokens(rule.tags)) {
          final id = byId[token] ?? byName[token];
          if (id != null) resolved.add(id);
        }
        _selectedTagIds = resolved;
      } else {
        _bookId = await ref.read(currentBookIdProvider.future);
      }

      await ref.read(assetsProvider.future);
      await ref.read(categoriesProvider(_bookId!).future);
      await ref.read(activeTagsProvider.future);
    } catch (e) {
      _error = safeMessage(e);
    }
    if (mounted) {
      setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _feeCtrl.dispose();
    _freqCtrl.dispose();
    _endCountCtrl.dispose();
    _remarkCtrl.dispose();
    super.dispose();
  }

  String _currencyPrefix(List<Asset> assets) {
    final targetId = _recordType == RecordType.transfer
        ? _fromAssetId
        : _assetId;
    if (targetId == noRef) return baseCurrency;
    final asset = assets.where((a) => a.id == targetId).firstOrNull;
    return normalizeCurrency(asset?.currency) ?? baseCurrency;
  }

  List<String> _currentPeriodDates() => switch (_periodType) {
    PeriodType.daily => const [],
    PeriodType.weekly => _weeklyDays.toList(),
    PeriodType.monthly => _monthlyDays.toList(),
    PeriodType.yearly => _yearlyDates,
    _ => const [],
  };

  int _resolveEndDateValue() {
    switch (_endMode) {
      case PeriodEndMode.never:
        return periodEndNever;
      case PeriodEndMode.count:
        final count = int.tryParse(_endCountCtrl.text.trim());
        if (count == null || count < 1 || count > periodMaxEndCount) {
          throw const Failure(FailureCode.validation, '重复次数须在 1–366 之间');
        }
        return count;
      case PeriodEndMode.date:
        if (_endDate.isBefore(_startDate)) {
          throw const Failure(FailureCode.validation, '截止日期不能早于开始日期');
        }
        return _endDate.startOfDayMs;
    }
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final int bookId =
          _bookId ?? await ref.read(currentBookIdProvider.future);
      final money = _parseMoney(_amountCtrl.text);
      final fee = _recordType == RecordType.transfer
          ? _parseMoney(_feeCtrl.text, allowZero: true)
          : null;

      if (_recordType != RecordType.transfer && _categoryId == null) {
        throw const Failure(FailureCode.validation, '请选择分类');
      }

      final rawFreq = int.tryParse(_freqCtrl.text.trim());
      if (rawFreq == null || rawFreq < 1) {
        throw const Failure(FailureCode.validation, '重复间隔步长须为大于等于 1 的整数');
      }

      final endValue = _resolveEndDateValue();
      final rtString = _recordTimeEnabled
          ? formatHourMinute(_rtHour, _rtMinute)
          : null;

      final draft = PeriodicDraft(
        recordType: _recordType,
        money: money,
        fee: fee,
        feeFromTarget: _feeFromTarget,
        remark: _remarkCtrl.text.trim(),
        categoryId: _recordType == RecordType.transfer ? noRef : _categoryId!,
        assetId: _recordType == RecordType.transfer ? _fromAssetId : _assetId,
        assetId2: _recordType == RecordType.transfer ? _toAssetId : noRef,
        bookId: bookId,
        periodType: _periodType,
        periodTypeDates: _currentPeriodDates(),
        frequency: rawFreq,
        periodStartDate: _startDate.startOfDayMs,
        periodEndDate: endValue,
        excludeBudget: _excludeBudget,
        excludeExIn: _excludeExIn,
        recordTimeEnabled: _recordTimeEnabled,
        recordTime: rtString,
        tagIds: _selectedTagIds.toList(),
      );

      final service = await ref.read(periodicServiceProvider.future);
      final savedId = await service.savePeriod(
        commandId: _ids.forPayload([widget.periodId, ...draft.payload]),
        periodId: widget.periodId,
        draft: draft,
      );
      // R1 (T3): immediately run forced catch-up after saving a periodic rule.
      await service.runCatchUp(force: true);

      if (!mounted) return;
      Navigator.of(context).pop(savedId);
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

  Future<void> _pickStartDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(_startDate.year, _startDate.month, _startDate.day),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) {
      setState(() {
        _startDate = CalendarDate.fromDateTime(picked);
        if (_endDate.isBefore(_startDate)) {
          _endDate = _startDate;
        }
      });
    }
  }

  Future<void> _pickEndDate() async {
    final initial = _endDate.isBefore(_startDate) ? _startDate : _endDate;
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(initial.year, initial.month, initial.day),
      firstDate: DateTime(_startDate.year, _startDate.month, _startDate.day),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) {
      setState(() => _endDate = CalendarDate.fromDateTime(picked));
    }
  }

  Future<void> _pickRecordTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _rtHour, minute: _rtMinute),
    );
    if (picked != null && mounted) {
      setState(() {
        _rtHour = picked.hour;
        _rtMinute = picked.minute;
      });
    }
  }

  Future<void> _showAddYearlyDateDialog() async {
    var selectedMonth = 1;
    var selectedDay = 1;

    final added = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (context, setDialogState) {
          final maxDay = daysInMonth(2024, selectedMonth);
          if (selectedDay > maxDay) selectedDay = maxDay;
          return AlertDialog(
            title: const Text('添加每年记账月日'),
            content: Row(
              children: [
                Expanded(
                  child: InputDecorator(
                    decoration: const InputDecoration(labelText: '月份'),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<int>(
                        key: const Key('yearly_month_picker'),
                        value: selectedMonth,
                        isDense: true,
                        isExpanded: true,
                        items: [
                          for (var m = 1; m <= 12; m++)
                            DropdownMenuItem(value: m, child: Text('$m 月')),
                        ],
                        onChanged: (val) {
                          if (val != null) {
                            setDialogState(() {
                              selectedMonth = val;
                              final nextMax = daysInMonth(2024, selectedMonth);
                              if (selectedDay > nextMax) {
                                selectedDay = nextMax;
                              }
                            });
                          }
                        },
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: InputDecorator(
                    decoration: const InputDecoration(labelText: '日期'),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<int>(
                        key: const Key('yearly_day_picker'),
                        value: selectedDay,
                        isDense: true,
                        isExpanded: true,
                        items: [
                          for (var d = 1; d <= maxDay; d++)
                            DropdownMenuItem(
                              value: d,
                              child: Text(
                                selectedMonth == 2 && d == 29
                                    ? '29 日(闰)'
                                    : '$d 日',
                              ),
                            ),
                        ],
                        onChanged: (val) {
                          if (val != null) {
                            setDialogState(() => selectedDay = val);
                          }
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogCtx),
                child: const Text('取消'),
              ),
              FilledButton(
                key: const Key('confirm_yearly_date_button'),
                onPressed: () => Navigator.pop(
                  dialogCtx,
                  '${two(selectedMonth)}-${two(selectedDay)}',
                ),
                child: const Text('添加'),
              ),
            ],
          );
        },
      ),
    );

    if (added != null && mounted) {
      setState(() {
        _yearlyDates = normalizePeriodTypeDates(PeriodType.yearly, [
          ..._yearlyDates,
          added,
        ]);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bookId = _bookId ?? ref.watch(currentBookIdProvider).value ?? 1;
    final categories =
        ref.watch(categoriesProvider(bookId)).value ?? const <RecordCategory>[];
    final allAssets = ref.watch(assetsProvider).value ?? const <Asset>[];
    final activeAssets = allAssets
        .where((a) => a.status == AssetStatus.active)
        .toList();
    final tags = (ref.watch(activeTagsProvider).value ?? const <Tag>[])
        .where((t) => t.parent != 1)
        .toList();

    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        key: const Key('periodic_editor_page'),
        appBar: AppBar(title: Text(_editing ? '编辑周期记账' : '新建周期记账')),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: FilledButton(
              key: const Key('save_periodic_button'),
              onPressed: _busy || _loading ? null : _submit,
              child: Text(_busy ? '保存中…' : '保存'),
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
                        children: [
                          for (final (val, label) in const [
                            (RecordType.expense, '支出'),
                            (RecordType.income, '收入'),
                            (RecordType.transfer, '转账'),
                          ])
                            ChoiceChip(
                              key: Key('periodic_type_$val'),
                              label: Text(label),
                              selected: _recordType == val,
                              onSelected: _busy
                                  ? null
                                  : (_) => setState(() {
                                      _recordType = val;
                                      _categoryId = null;
                                      _parentCatId = null;
                                    }),
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        key: const Key('periodic_amount_input'),
                        controller: _amountCtrl,
                        enabled: !_busy,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: _amountFormatters,
                        style: Theme.of(context).textTheme.headlineSmall,
                        decoration: InputDecoration(
                          labelText: '每期金额',
                          prefixText: '${_currencyPrefix(allAssets)} ',
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (_recordType == RecordType.transfer)
                        ..._buildTransferSection(allAssets, activeAssets)
                      else
                        ..._buildCategoryAndAssetSection(
                          categories,
                          allAssets,
                          activeAssets,
                        ),
                      const Divider(height: 32),
                      ..._buildCycleSection(),
                      const Divider(height: 32),
                      ..._buildScheduleBoundsSection(),
                      const Divider(height: 32),
                      TextField(
                        key: const Key('periodic_remark_input'),
                        controller: _remarkCtrl,
                        enabled: !_busy,
                        maxLength: 200,
                        decoration: const InputDecoration(labelText: '备注'),
                      ),
                      SwitchListTile(
                        key: const Key('periodic_exclude_exin_switch'),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('不计入收支'),
                        value: _excludeExIn,
                        onChanged: _busy
                            ? null
                            : (v) => setState(() => _excludeExIn = v),
                      ),
                      SwitchListTile(
                        key: const Key('periodic_exclude_budget_switch'),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('不计入预算'),
                        value: _excludeBudget,
                        onChanged: _busy
                            ? null
                            : (v) => setState(() => _excludeBudget = v),
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
                                key: Key('periodic_tag_${t.name}'),
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
                            key: const Key('periodic_form_error'),
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

  DropdownMenuItem<int>? _fallbackAssetItem(
    int selectedId,
    List<Asset> allAssets,
    List<Asset> activeAssets,
  ) {
    if (selectedId == noRef || activeAssets.any((a) => a.id == selectedId)) {
      return null;
    }
    final inactive = allAssets.where((a) => a.id == selectedId).firstOrNull;
    final label = inactive != null
        ? '${inactive.name} (已停用)'
        : '账户#$selectedId (已删除)';
    return DropdownMenuItem<int>(value: selectedId, child: Text(label));
  }

  List<Widget> _buildCategoryAndAssetSection(
    List<RecordCategory> all,
    List<Asset> allAssets,
    List<Asset> activeAssets,
  ) {
    if (_categoryId != null && _parentCatId == null) {
      final chosen = all.where((c) => c.id == _categoryId).firstOrNull;
      if (chosen != null) {
        _parentCatId = chosen.parentCatId == noRef
            ? chosen.id
            : chosen.parentCatId;
      }
    }
    final topCats = all
        .where(
          (c) => c.type == _recordType && !c.isHide && c.parentCatId == noRef,
        )
        .toList();
    final subCats = _parentCatId == null
        ? const <RecordCategory>[]
        : all.where((c) => c.parentCatId == _parentCatId && !c.isHide).toList();

    final fallbackAsset = _fallbackAssetItem(_assetId, allAssets, activeAssets);

    return [
      Text('分类', style: Theme.of(context).textTheme.labelLarge),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final c in topCats)
            ChoiceChip(
              key: Key('periodic_cat_${c.name}'),
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
              key: const Key('periodic_subcat_all'),
              label: const Text('全部'),
              selected: _categoryId == _parentCatId,
              onSelected: _busy
                  ? null
                  : (_) => setState(() => _categoryId = _parentCatId),
            ),
            for (final s in subCats)
              ChoiceChip(
                key: Key('periodic_cat_${s.name}'),
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
      InputDecorator(
        decoration: const InputDecoration(labelText: '关联账户'),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<int>(
            key: const Key('periodic_asset_picker'),
            value: _assetId,
            isDense: true,
            isExpanded: true,
            items: [
              const DropdownMenuItem(value: noRef, child: Text('不选账户')),
              for (final a in activeAssets)
                DropdownMenuItem(value: a.id, child: Text(a.name)),
              if (fallbackAsset != null) fallbackAsset,
            ],
            onChanged: _busy
                ? null
                : (v) => setState(() => _assetId = v ?? noRef),
          ),
        ),
      ),
    ];
  }

  List<Widget> _buildTransferSection(
    List<Asset> allAssets,
    List<Asset> activeAssets,
  ) {
    final fromFallback = _fallbackAssetItem(
      _fromAssetId,
      allAssets,
      activeAssets,
    );
    final toFallback = _fallbackAssetItem(_toAssetId, allAssets, activeAssets);
    final fromValue = _fromAssetId == noRef ? null : _fromAssetId;
    final toValue = _toAssetId == noRef ? null : _toAssetId;

    return [
      if (activeAssets.length < 2)
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text('周期转账至少需要两个启用状态的账户。'),
        ),
      InputDecorator(
        decoration: const InputDecoration(labelText: '转出账户'),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<int>(
            key: const Key('periodic_from_asset_picker'),
            value: fromValue,
            isDense: true,
            isExpanded: true,
            items: [
              for (final a in activeAssets)
                DropdownMenuItem(value: a.id, child: Text(a.name)),
              if (fromFallback != null) fromFallback,
            ],
            onChanged: _busy
                ? null
                : (v) => setState(() => _fromAssetId = v ?? noRef),
          ),
        ),
      ),
      const SizedBox(height: 12),
      InputDecorator(
        decoration: const InputDecoration(labelText: '转入账户'),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<int>(
            key: const Key('periodic_to_asset_picker'),
            value: toValue,
            isDense: true,
            isExpanded: true,
            items: [
              for (final a in activeAssets)
                DropdownMenuItem(value: a.id, child: Text(a.name)),
              if (toFallback != null) toFallback,
            ],
            onChanged: _busy
                ? null
                : (v) => setState(() => _toAssetId = v ?? noRef),
          ),
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        key: const Key('periodic_fee_input'),
        controller: _feeCtrl,
        enabled: !_busy,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: _amountFormatters,
        decoration: const InputDecoration(
          labelText: '转账手续费（可选）',
          prefixText: '¥ ',
        ),
      ),
      SwitchListTile(
        key: const Key('periodic_fee_from_target_switch'),
        contentPadding: EdgeInsets.zero,
        title: const Text('手续费由转入账户承担'),
        value: _feeFromTarget,
        onChanged: _busy ? null : (v) => setState(() => _feeFromTarget = v),
      ),
    ];
  }

  List<Widget> _buildCycleSection() {
    final freqHint = switch (_periodType) {
      PeriodType.daily => '上限 100 天（超限自动钳制）',
      PeriodType.weekly => '上限 3 周（超限自动钳制）',
      PeriodType.monthly => '上限 10 个月（超限自动钳制）',
      PeriodType.yearly => '间隔年数 >= 1',
      _ => '',
    };

    return [
      Text('重复周期', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        children: [
          for (final entry in PeriodType.labels.entries)
            ChoiceChip(
              key: Key('period_type_${entry.key}'),
              label: Text(entry.value),
              selected: _periodType == entry.key,
              onSelected: _busy
                  ? null
                  : (_) => setState(() => _periodType = entry.key),
            ),
        ],
      ),
      const SizedBox(height: 12),
      TextField(
        key: const Key('periodic_frequency_input'),
        controller: _freqCtrl,
        enabled: !_busy,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(labelText: '重复间隔步长', helperText: freqHint),
      ),
      const SizedBox(height: 12),
      if (_periodType == PeriodType.weekly) ...[
        const Text('选择星期（可多选）'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (d, name) in const [
              ('1', '周一'),
              ('2', '周二'),
              ('3', '周三'),
              ('4', '周四'),
              ('5', '周五'),
              ('6', '周六'),
              ('7', '周日'),
            ])
              FilterChip(
                key: Key('weekly_day_$d'),
                label: Text(name),
                selected: _weeklyDays.contains(d),
                onSelected: _busy
                    ? null
                    : (sel) => setState(() {
                        if (sel) {
                          _weeklyDays.add(d);
                        } else if (_weeklyDays.length > 1) {
                          _weeklyDays.remove(d);
                        }
                      }),
              ),
          ],
        ),
      ] else if (_periodType == PeriodType.monthly) ...[
        const Text('选择每月日期（可多选，不足月自动取当月末日并锚定初始日）'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (var d = 1; d <= 31; d++)
              FilterChip(
                key: Key('monthly_day_$d'),
                label: Text('$d日'),
                selected: _monthlyDays.contains('$d'),
                onSelected: _busy
                    ? null
                    : (sel) => setState(() {
                        if (sel) {
                          _monthlyDays.add('$d');
                        } else if (_monthlyDays.length > 1) {
                          _monthlyDays.remove('$d');
                        }
                      }),
              ),
            FilterChip(
              key: const Key('monthly_day_-12'),
              label: const Text('月末'),
              selected: _monthlyDays.contains(monthEndToken),
              onSelected: _busy
                  ? null
                  : (sel) => setState(() {
                      if (sel) {
                        _monthlyDays.add(monthEndToken);
                      } else if (_monthlyDays.length > 1) {
                        _monthlyDays.remove(monthEndToken);
                      }
                    }),
            ),
          ],
        ),
      ] else if (_periodType == PeriodType.yearly) ...[
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Expanded(child: Text('选择每年月日（02-29 平年自动于 02-28 触发）')),
            TextButton.icon(
              key: const Key('add_yearly_date_button'),
              onPressed: _busy ? null : _showAddYearlyDateDialog,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('添加月日'),
            ),
          ],
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final md in _yearlyDates)
              InputChip(
                key: Key('yearly_date_chip_$md'),
                label: Text(md),
                onDeleted: _busy || _yearlyDates.length <= 1
                    ? null
                    : () => setState(() {
                        _yearlyDates = [
                          for (final x in _yearlyDates)
                            if (x != md) x,
                        ];
                      }),
              ),
          ],
        ),
      ],
    ];
  }

  List<Widget> _buildScheduleBoundsSection() {
    return [
      ListTile(
        key: const Key('periodic_start_date_tile'),
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.play_circle_outline),
        title: const Text('开始日期'),
        trailing: Text(_startDate.formatIso()),
        onTap: _busy ? null : _pickStartDate,
      ),
      const SizedBox(height: 8),
      Text('结束条件', style: Theme.of(context).textTheme.labelLarge),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        children: [
          ChoiceChip(
            key: const Key('periodic_end_mode_0'),
            label: const Text('永不结束'),
            selected: _endMode == PeriodEndMode.never,
            onSelected: _busy
                ? null
                : (_) => setState(() => _endMode = PeriodEndMode.never),
          ),
          ChoiceChip(
            key: const Key('periodic_end_mode_1'),
            label: const Text('按次数结束'),
            selected: _endMode == PeriodEndMode.count,
            onSelected: _busy
                ? null
                : (_) => setState(() => _endMode = PeriodEndMode.count),
          ),
          ChoiceChip(
            key: const Key('periodic_end_mode_2'),
            label: const Text('按截止日期'),
            selected: _endMode == PeriodEndMode.date,
            onSelected: _busy
                ? null
                : (_) => setState(() => _endMode = PeriodEndMode.date),
          ),
        ],
      ),
      if (_endMode == PeriodEndMode.count) ...[
        const SizedBox(height: 12),
        TextField(
          key: const Key('periodic_end_count_input'),
          controller: _endCountCtrl,
          enabled: !_busy,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(labelText: '累计执行次数上限（1–366）'),
        ),
      ] else if (_endMode == PeriodEndMode.date) ...[
        ListTile(
          key: const Key('periodic_end_date_tile'),
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.event_busy_outlined),
          title: const Text('截止日期'),
          trailing: Text(_endDate.formatIso()),
          onTap: _busy ? null : _pickEndDate,
        ),
      ],
      SwitchListTile(
        key: const Key('periodic_rte_switch'),
        contentPadding: EdgeInsets.zero,
        title: const Text('指定固定记账时间'),
        subtitle: const Text('关闭时当天取当前时刻，历史补记取中午 12:00'),
        value: _recordTimeEnabled,
        onChanged: _busy ? null : (v) => setState(() => _recordTimeEnabled = v),
      ),
      if (_recordTimeEnabled)
        ListTile(
          key: const Key('periodic_rt_tile'),
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.access_time),
          title: const Text('记账时间'),
          trailing: Text(formatHourMinute(_rtHour, _rtMinute)),
          onTap: _busy ? null : _pickRecordTime,
        ),
    ];
  }
}
