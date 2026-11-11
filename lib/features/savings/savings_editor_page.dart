import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/failure.dart';
import '../../core/money.dart';
import '../../data/db/database.dart';
import '../../data/savings/savings_service.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/asset_overview.dart' show normalizeCurrency;
import '../../domain/rules/currency_rates.dart' show baseCurrency;
import '../../domain/rules/savings_plan.dart';
import '../common/common.dart';
import 'savings_providers.dart';

/// Create / edit page for a Savings Plan (F-012, `MoneySaveAddEditActivity`).
class SavingsEditorPage extends ConsumerStatefulWidget {
  const SavingsEditorPage({this.planId, super.key});

  final int? planId;

  @override
  ConsumerState<SavingsEditorPage> createState() => _SavingsEditorPageState();
}

class _SavingsEditorPageState extends ConsumerState<SavingsEditorPage> {
  final _nameCtrl = TextEditingController();
  final _remarkCtrl = TextEditingController();
  final _startMoneyCtrl = TextEditingController(text: '10.00');
  final _incMoneyCtrl = TextEditingController(text: '10.00');
  final _customTargetCtrl = TextEditingController();
  final _ids = CommandIds();

  int _planType = SavingsPlanType.incremental;
  int _cycleType = SavingsCycleType.daily;
  late LocalCalendarDate _startDate;
  late LocalCalendarDate _endDate;
  bool _freeHasEndDate = false;
  bool _autoPlan = false;
  int _fromAssetId = noRef;
  int _toAssetId = noRef;
  int _bookId = noRef;
  String? _lockedCurrency;

  List<Asset> _initialAssets = const [];
  List<AccountBook> _initialBooks = const [];
  List<Currency> _initialCurrencies = const [];

  bool _loading = true;
  bool _busy = false;
  String? _error;

  bool get _editing => widget.planId != null;

  @override
  void initState() {
    super.initState();
    final today = LocalCalendarDate.fromDateTime(DateTime.now());
    _startDate = today;
    _endDate = today.plusDays(29);
    _load();
  }

  Future<void> _load() async {
    try {
      final assets = await ref.read(assetsProvider.future);
      final books = await ref.read(booksProvider.future);
      final currencies = await ref.read(currenciesProvider.future);
      _initialAssets = assets;
      _initialBooks = books;
      _initialCurrencies = currencies;

      if (_editing) {
        final q = await ref.read(savingsQueriesProvider.future);
        final plan = await q.getPlan(widget.planId!);
        if (plan == null) {
          throw const Failure(FailureCode.conflict, '存钱计划不存在或已删除');
        }
        _nameCtrl.text = plan.name;
        _remarkCtrl.text = plan.remark;
        _planType = plan.planType;
        _cycleType = plan.planType == SavingsPlanType.free
            ? SavingsCycleType.daily
            : plan.cycleType;
        if (plan.startDate >= 0) {
          _startDate = LocalCalendarDate.fromEpochMs(plan.startDate);
        }
        if (plan.endDate >= 0) {
          _endDate = LocalCalendarDate.fromEpochMs(plan.endDate);
          _freeHasEndDate = true;
        } else {
          _freeHasEndDate = false;
        }
        if (plan.planType == SavingsPlanType.free) {
          _customTargetCtrl.text = formatMinor(plan.planMoneyMinor);
        } else {
          _startMoneyCtrl.text = formatMinor(plan.startMoneyMinor);
          if (plan.planType == SavingsPlanType.incremental) {
            _incMoneyCtrl.text = formatMinor(plan.incrementalMinor);
          }
        }
        _autoPlan = plan.autoPlan;
        _fromAssetId = plan.fromAssetId;
        _toAssetId = plan.toAssetId;
        _bookId = plan.bookId;
        _lockedCurrency = SavingsPlanExtra.parse(plan.extraInfo).currency;
      }
    } catch (e) {
      _error = safeMessage(e);
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _remarkCtrl.dispose();
    _startMoneyCtrl.dispose();
    _incMoneyCtrl.dispose();
    _customTargetCtrl.dispose();
    super.dispose();
  }

  void _applyTemplate(SavingsPlanTemplate tpl) {
    setState(() {
      _error = null;
      _nameCtrl.text = tpl.name;
      _planType = tpl.planType;
      _cycleType = tpl.cycleType;
      _startDate = tpl.startDate;
      _endDate = tpl.endDate;
      _startMoneyCtrl.text = formatMinor(tpl.startMoneyMinor);
      _incMoneyCtrl.text = formatMinor(tpl.incrementalMinor);
    });
  }

  BigInt? _tryParsePositiveMinor(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    try {
      final money = Money.parse(trimmed, rounding: RoundingMode.halfUp);
      if (money.units <= BigInt.zero) return null;
      return money.storageMinor;
    } on Failure {
      return null;
    }
  }

  BigInt _parseRequiredMinor(String text, String fieldLabel) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw Failure(FailureCode.validation, '请输入$fieldLabel');
    }
    final money = Money.parse(trimmed, rounding: RoundingMode.halfUp);
    if (money.units <= BigInt.zero) {
      throw Failure(FailureCode.validation, '$fieldLabel须大于 0');
    }
    return money.storageMinor;
  }

  (int periods, BigInt? targetMinor) _previewScheduleTarget() {
    if (_planType == SavingsPlanType.free) {
      return (0, _tryParsePositiveMinor(_customTargetCtrl.text));
    }
    if (_endDate < _startDate) return (0, null);
    try {
      final periods = countSchedulePeriods(
        start: _startDate,
        end: _endDate,
        cycleType: _cycleType,
      );
      final startMinor = _tryParsePositiveMinor(_startMoneyCtrl.text);
      if (startMinor == null) return (periods, null);
      final incMinor = _planType == SavingsPlanType.incremental
          ? _tryParsePositiveMinor(_incMoneyCtrl.text)
          : BigInt.zero;
      if (_planType == SavingsPlanType.incremental && incMinor == null) {
        return (periods, null);
      }
      final target = computePlanTargetMinor(
        planType: _planType,
        periodCount: periods,
        startMoneyMinor: startMinor,
        incrementalMinor: incMinor,
      );
      return (periods, target);
    } on Failure {
      return (0, null);
    }
  }

  Future<void> _pickDate({required bool isStart}) async {
    final initial = isStart ? _startDate : _endDate;
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(initial.year, initial.month, initial.day),
      firstDate: DateTime(2000, 1, 1),
      lastDate: DateTime(2100, 12, 31),
    );
    if (picked == null || !mounted) return;
    setState(() {
      final selected = LocalCalendarDate.fromDateTime(picked);
      if (isStart) {
        _startDate = selected;
        if (_endDate < _startDate) {
          _endDate = _startDate;
        }
      } else {
        _endDate = selected;
        _freeHasEndDate = true;
      }
    });
  }

  String _effectiveCurrency(List<Asset> assets) {
    if (_lockedCurrency != null) return _lockedCurrency!;
    if (_toAssetId != noRef) {
      for (final a in assets) {
        if (a.id == _toAssetId) {
          return normalizeCurrency(a.currency) ?? baseCurrency;
        }
      }
    }
    return baseCurrency;
  }

  Future<void> _submit(
    List<Asset> assets, {
    required int fromAssetId,
    required int toAssetId,
    required int bookId,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final name = _nameCtrl.text.trim();
      if (name.isEmpty) {
        throw const Failure(FailureCode.validation, '请输入计划名称');
      }

      BigInt? startMinor;
      BigInt? incMinor;
      BigInt? customMinor;
      int cycleType;
      int endDateMs;

      if (_planType == SavingsPlanType.free) {
        cycleType = SavingsCycleType.free;
        customMinor = _parseRequiredMinor(_customTargetCtrl.text, '目标金额');
        endDateMs = _freeHasEndDate ? _endDate.startOfDayMs : noRef;
      } else {
        cycleType = _cycleType;
        if (_endDate < _startDate) {
          throw const Failure(FailureCode.validation, '结束日期不能早于开始日期');
        }
        endDateMs = _endDate.startOfDayMs;
        startMinor = _parseRequiredMinor(
          _startMoneyCtrl.text,
          _planType == SavingsPlanType.incremental ? '起始金额' : '每期金额',
        );
        incMinor = _planType == SavingsPlanType.incremental
            ? _parseRequiredMinor(_incMoneyCtrl.text, '每期递增金额')
            : BigInt.zero;
      }

      final draft = SavingsPlanDraft(
        name: name,
        remark: _remarkCtrl.text.trim(),
        planType: _planType,
        cycleType: cycleType,
        startDateMs: _startDate.startOfDayMs,
        endDateMs: endDateMs,
        startMoneyMinor: startMinor,
        incrementalMinor: incMinor,
        customPlanMoneyMinor: customMinor,
        autoPlan: _planType == SavingsPlanType.free ? false : _autoPlan,
        fromAssetId: fromAssetId,
        toAssetId: toAssetId,
        bookId: bookId,
        currency: _editing ? _lockedCurrency : _effectiveCurrency(assets),
      );

      final service = await ref.read(savingsServiceProvider.future);
      final savedId = await service.savePlan(
        commandId: _ids.forPayload([widget.planId, ...draft.payload]),
        planId: widget.planId,
        draft: draft,
      );

      if (draft.autoPlan) {
        await service.runAutoSave();
      }

      if (!mounted) return;
      Navigator.of(context).pop(savedId);
    } catch (e) {
      if (mounted) setState(() => _error = safeMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _assetOptionLabel(Asset a) {
    final code = normalizeCurrency(a.currency) ?? baseCurrency;
    final suffix = a.status == AssetStatus.active ? '' : ' (已停用)';
    return '${a.name} ($code)$suffix';
  }

  @override
  Widget build(BuildContext context) {
    final assetsAsync = ref.watch(assetsProvider);
    final booksAsync = ref.watch(booksProvider);
    final currenciesAsync = ref.watch(currenciesProvider);

    if (_loading) {
      return const Scaffold(body: Loading());
    }

    final allAssets = assetsAsync.value ?? _initialAssets;
    final books = booksAsync.value ?? _initialBooks;
    final currencies = currenciesAsync.value ?? _initialCurrencies;

    final activeFromAssets = [
      for (final a in allAssets)
        if ((a.status == AssetStatus.active && a.type != AssetType.debt) ||
            a.id == _fromAssetId)
          a,
    ];
    final activeToAssets = [
      for (final a in allAssets)
        if (((a.status == AssetStatus.active && a.type != AssetType.debt) ||
                a.id == _toAssetId) &&
            (_lockedCurrency == null ||
                a.id == _toAssetId ||
                (normalizeCurrency(a.currency) ?? baseCurrency) ==
                    _lockedCurrency))
          a,
    ];

    final effectiveFromValue =
        (_fromAssetId == noRef ||
            activeFromAssets.any((a) => a.id == _fromAssetId))
        ? _fromAssetId
        : noRef;
    final effectiveToValue =
        (_toAssetId == noRef || activeToAssets.any((a) => a.id == _toAssetId))
        ? _toAssetId
        : noRef;
    final effectiveBookValue =
        (_bookId == noRef || books.any((b) => b.id == _bookId))
        ? _bookId
        : noRef;

    final currCode = _effectiveCurrency(allAssets);
    final currSymbol = resolveCurrencySymbol(currCode, currencies);
    final (periods, previewTarget) = _previewScheduleTarget();
    final today = LocalCalendarDate.fromDateTime(DateTime.now());

    return Scaffold(
      key: const Key('savings_editor_page'),
      appBar: AppBar(
        title: Text(_editing ? '编辑存钱计划' : '新建存钱计划'),
        actions: [
          TextButton(
            key: const Key('save_savings_plan_button'),
            onPressed: _busy
                ? null
                : () => _submit(
                    allAssets,
                    fromAssetId: effectiveFromValue,
                    toAssetId: effectiveToValue,
                    bookId: effectiveBookValue,
                  ),
            child: const Text('保存'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_error != null) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _error!,
                key: const Key('savings_editor_error'),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (!_editing) ...[
            Text('经典模板', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ActionChip(
                  key: const Key('template_365_days'),
                  avatar: const Icon(Icons.bolt, size: 16),
                  label: const Text('365天存钱（66795.00）'),
                  onPressed: _busy
                      ? null
                      : () =>
                            _applyTemplate(SavingsPlanTemplate.days365(today)),
                ),
                ActionChip(
                  key: const Key('template_52_weeks'),
                  avatar: const Icon(Icons.calendar_view_week, size: 16),
                  label: const Text('52周存钱（13780.00）'),
                  onPressed: _busy
                      ? null
                      : () =>
                            _applyTemplate(SavingsPlanTemplate.weeks52(today)),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
          Wrap(
            spacing: 8,
            children: [
              for (final mode in const [
                SavingsPlanType.incremental,
                SavingsPlanType.fixed,
                SavingsPlanType.free,
              ])
                ChoiceChip(
                  key: Key('plan_type_$mode'),
                  label: Text(SavingsPlanType.labelOf(mode)),
                  selected: _planType == mode,
                  onSelected: _busy
                      ? null
                      : (_) => setState(() {
                          _planType = mode;
                          if (mode == SavingsPlanType.free) {
                            _autoPlan = false;
                          }
                        }),
                ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('savings_name_input'),
            controller: _nameCtrl,
            enabled: !_busy,
            decoration: const InputDecoration(
              labelText: '计划名称',
              hintText: '例如：旅行基金、365天存钱',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          if (_planType != SavingsPlanType.free) ...[
            Text('存钱周期', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final cycle in SavingsCycleType.scheduledValues)
                  ChoiceChip(
                    key: Key('cycle_type_$cycle'),
                    label: Text(SavingsCycleType.labelOf(cycle)),
                    selected: _cycleType == cycle,
                    onSelected: _busy
                        ? null
                        : (_) => setState(() => _cycleType = cycle),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('pick_start_date_button'),
                    onPressed: _busy ? null : () => _pickDate(isStart: true),
                    icon: const Icon(Icons.event, size: 18),
                    label: Text('开始 ${_startDate.dateKey}'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('pick_end_date_button'),
                    onPressed: _busy ? null : () => _pickDate(isStart: false),
                    icon: const Icon(Icons.event_available, size: 18),
                    label: Text('结束 ${_endDate.dateKey}'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('savings_start_money_input'),
              controller: _startMoneyCtrl,
              enabled: !_busy,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: _planType == SavingsPlanType.incremental
                    ? '首期存入金额'
                    : '每期定额金额',
                prefixText: '$currSymbol ',
                border: const OutlineInputBorder(),
              ),
            ),
            if (_planType == SavingsPlanType.incremental) ...[
              const SizedBox(height: 12),
              TextField(
                key: const Key('savings_incremental_input'),
                controller: _incMoneyCtrl,
                enabled: !_busy,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: '每期递增金额',
                  prefixText: '$currSymbol ',
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Card(
              key: const Key('savings_target_preview'),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('预计共 $periods 期'),
                    Text(
                      previewTarget == null
                          ? '--'
                          : '目标总额 $currSymbol${formatMinor(previewTarget)}',
                      key: const Key('savings_preview_target_text'),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ] else ...[
            TextField(
              key: const Key('savings_custom_target_input'),
              controller: _customTargetCtrl,
              enabled: !_busy,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: '目标总金额',
                prefixText: '$currSymbol ',
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('pick_start_date_button'),
                    onPressed: _busy ? null : () => _pickDate(isStart: true),
                    icon: const Icon(Icons.event, size: 18),
                    label: Text('开始 ${_startDate.dateKey}'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('pick_end_date_button'),
                    onPressed: _busy ? null : () => _pickDate(isStart: false),
                    icon: const Icon(Icons.event_available, size: 18),
                    label: Text(
                      _freeHasEndDate ? '截止 ${_endDate.dateKey}' : '截止日期（可选）',
                    ),
                  ),
                ),
                if (_freeHasEndDate)
                  IconButton(
                    tooltip: '清除截止日期',
                    onPressed: _busy
                        ? null
                        : () => setState(() => _freeHasEndDate = false),
                    icon: const Icon(Icons.clear, size: 18),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          InputDecorator(
            decoration: const InputDecoration(
              labelText: '转出扣款账户（可选）',
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                key: const Key('savings_from_asset_dropdown'),
                value: effectiveFromValue,
                isExpanded: true,
                items: [
                  const DropdownMenuItem(value: noRef, child: Text('不绑定转出账户')),
                  for (final a in activeFromAssets)
                    DropdownMenuItem(
                      value: a.id,
                      child: Text(_assetOptionLabel(a)),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _fromAssetId = v ?? noRef),
              ),
            ),
          ),
          const SizedBox(height: 12),
          InputDecorator(
            decoration: InputDecoration(
              labelText: '转入存钱账户（可选）',
              helperText: _editing ? '编辑计划时币种已锁定为 $currCode' : null,
              border: const OutlineInputBorder(),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 4,
              ),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                key: const Key('savings_to_asset_dropdown'),
                value: effectiveToValue,
                isExpanded: true,
                items: [
                  const DropdownMenuItem(value: noRef, child: Text('不绑定转入账户')),
                  for (final a in activeToAssets)
                    DropdownMenuItem(
                      value: a.id,
                      child: Text(_assetOptionLabel(a)),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _toAssetId = v ?? noRef),
              ),
            ),
          ),
          if (books.isNotEmpty) ...[
            const SizedBox(height: 12),
            InputDecorator(
              decoration: const InputDecoration(
                labelText: '转账入账账本',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  key: const Key('savings_book_dropdown'),
                  value: effectiveBookValue,
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem(value: noRef, child: Text('跟随当前账本')),
                    for (final b in books)
                      DropdownMenuItem(value: b.id, child: Text(b.name)),
                  ],
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _bookId = v ?? noRef),
                ),
              ),
            ),
          ],
          if (_planType != SavingsPlanType.free) ...[
            const SizedBox(height: 8),
            SwitchListTile(
              key: const Key('savings_auto_plan_switch'),
              contentPadding: EdgeInsets.zero,
              title: const Text('自动存钱'),
              subtitle: const Text('到达应存日期时自动打卡并生成转账流水'),
              value: _autoPlan,
              onChanged: _busy
                  ? null
                  : (val) => setState(() => _autoPlan = val),
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            key: const Key('savings_remark_input'),
            controller: _remarkCtrl,
            enabled: !_busy,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: '备注（可选）',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
    );
  }
}
