import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/failure.dart';
import '../../data/db/database.dart';
import '../../data/deposit/fixed_deposit_service.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/asset_overview.dart' show normalizeCurrency;
import '../../domain/rules/currency_rates.dart';
import '../../domain/rules/fixed_deposit.dart';
import '../common/common.dart';
import '../records/record_editor_page.dart'
    show amountInputFormatters, parseAmount;
import 'fixed_deposit_providers.dart';

final _rateInputFormatters = <TextInputFormatter>[
  FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,8}')),
];

final _intInputFormatters = <TextInputFormatter>[
  FilteringTextInputFormatter.digitsOnly,
];

/// Create / edit screen for a fixed deposit (`FixedDepositAddEditActivity` / `/bkp/FDAEAct`, F-027).
class FixedDepositEditorPage extends ConsumerStatefulWidget {
  const FixedDepositEditorPage({
    super.key,
    this.initialAssetId,
    this.assetId,
    this.depositIndex,
  });

  /// Optional preselected host account when creating a new deposit.
  final int? initialAssetId;

  /// Host account ID when editing an existing deposit.
  final int? assetId;

  /// Index inside `asset.fixed_deposit_info` when editing (`null` = create).
  final int? depositIndex;

  @override
  ConsumerState<FixedDepositEditorPage> createState() =>
      _FixedDepositEditorPageState();
}

class _FixedDepositEditorPageState
    extends ConsumerState<FixedDepositEditorPage> {
  final _principalCtrl = TextEditingController();
  final _rateCtrl = TextEditingController(text: '2.4');
  final _periodCountCtrl = TextEditingController(text: '1');
  final _expectedIncomeCtrl = TextEditingController(text: '0.00');
  final _remarkCtrl = TextEditingController();
  final _ids = CommandIds();

  int _hostAssetId = noRef;
  int _fromAssetId = noRef;
  bool _updateAssetBalance = false;
  bool _createBalanceAdjustRecord = true;
  int _periodUnit = DepositPeriodUnit.year;
  String _currency = '';
  int _depositDateMs = 0;
  int _dueDateMs = 0;

  List<Asset> _loadedEligibleAssets = const <Asset>[];
  List<Currency> _loadedCurrencies = const <Currency>[];
  Asset? _historicalFromAsset;

  bool _loading = true;
  bool _busy = false;
  bool _isSettled = false;
  bool _suppressAutoCalc = false;
  String? _error;

  bool get _editing => widget.assetId != null && widget.depositIndex != null;

  @override
  void initState() {
    super.initState();
    _principalCtrl.addListener(_onCoreFieldChanged);
    _rateCtrl.addListener(_onCoreFieldChanged);
    _periodCountCtrl.addListener(_onCoreFieldChanged);
    _load();
  }

  @override
  void dispose() {
    _principalCtrl.dispose();
    _rateCtrl.dispose();
    _periodCountCtrl.dispose();
    _expectedIncomeCtrl.dispose();
    _remarkCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final db = await ref.read(databaseProvider.future);
      final queries = await ref.read(fixedDepositQueriesProvider.future);
      final eligible = await queries.getEligibleAssets();
      final loadedCurrencies = await db.select(db.currencies).get();
      final now = db.nowMs();

      _loadedEligibleAssets = eligible;
      _loadedCurrencies = loadedCurrencies;

      _suppressAutoCalc = true;
      if (_editing) {
        final host = eligible.where((a) => a.id == widget.assetId).firstOrNull;
        if (host == null) {
          throw const Failure(FailureCode.validation, '宿主账户不存在或不可用');
        }
        final items = decodeFixedDepositList(host.fixedDepositInfo);
        final idx = widget.depositIndex!;
        if (idx < 0 || idx >= items.length) {
          throw const Failure(FailureCode.validation, '定期存款条目不存在');
        }
        final item = items[idx];
        Asset? historicalFrom;
        if (item.fromAssetId != noRef &&
            !eligible.any((a) => a.id == item.fromAssetId)) {
          historicalFrom = await (db.select(
            db.assets,
          )..where((t) => t.id.equals(item.fromAssetId))).getSingleOrNull();
        }
        _historicalFromAsset = historicalFrom;
        _hostAssetId = host.id;
        _fromAssetId = item.fromAssetId;
        _updateAssetBalance = item.updateAssetBalance;
        _createBalanceAdjustRecord =
            item.adjustRecordId != null || !item.updateAssetBalance;
        _periodUnit = item.periodUnit;
        _periodCountCtrl.text = '${item.periodCount}';
        _principalCtrl.text = formatMinor(item.moneyMinor);
        _rateCtrl.text = annualRateToPercentString(item.annualRate);
        _currency = normalizeCurrency(item.currency) ?? '';
        _depositDateMs = item.depositDate;
        _dueDateMs = item.dueDate;
        _expectedIncomeCtrl.text = formatMinor(item.expectedIncomeMinor);
        _remarkCtrl.text = item.remark;
        _isSettled = item.isSettled;
      } else {
        final preselected =
            widget.initialAssetId != null &&
                eligible.any((a) => a.id == widget.initialAssetId)
            ? widget.initialAssetId!
            : (eligible.isNotEmpty ? eligible.first.id : noRef);
        _hostAssetId = preselected;
        final today = DateTime.fromMillisecondsSinceEpoch(now);
        _depositDateMs = DateTime(
          today.year,
          today.month,
          today.day,
          today.hour,
          today.minute,
        ).millisecondsSinceEpoch;
        _recalculateDerived();
      }
    } catch (e) {
      _error = safeMessage(e);
    } finally {
      _suppressAutoCalc = false;
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onCoreFieldChanged() {
    if (_suppressAutoCalc || _isSettled) return;
    setState(_recalculateDerived);
  }

  /// Recalculates due date and expected income whenever principal, annual rate,
  /// period count, period unit, or deposit date changes (`docs/modules/fixed-deposit.md` §1.2 & R2).
  void _recalculateDerived() {
    final count = int.tryParse(_periodCountCtrl.text.trim()) ?? 1;
    _dueDateMs = calculateDueDate(
      depositDateMs: _depositDateMs,
      periodUnit: _periodUnit,
      periodCount: count < 1 ? 1 : count,
    );

    try {
      final principal = parseAmount(_principalCtrl.text);
      if (principal.units <= BigInt.zero || count < 1) {
        _expectedIncomeCtrl.text = '0.00';
        return;
      }
      final rateText = _rateCtrl.text.trim();
      if (rateText.isEmpty) {
        _expectedIncomeCtrl.text = '0.00';
        return;
      }
      final rate = percentToAnnualRate(rateText);
      final expectedMinor = calculateExpectedIncomeMinor(
        principal: principal,
        annualRate: rate,
        periodUnit: _periodUnit,
        periodCount: count,
      );
      _expectedIncomeCtrl.text = formatMinor(expectedMinor);
    } on Failure {
      // Keep previous text while user is mid-typing invalid characters.
    }
  }

  Future<void> _pickDepositDate() async {
    if (_busy || _isSettled) return;
    final current = DateTime.fromMillisecondsSinceEpoch(_depositDateMs);
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _depositDateMs = DateTime(
        picked.year,
        picked.month,
        picked.day,
        current.hour,
        current.minute,
        current.second,
        current.millisecond,
      ).millisecondsSinceEpoch;
      _recalculateDerived();
    });
  }

  Future<void> _pickDueDate() async {
    if (_busy || _isSettled) return;
    final current = DateTime.fromMillisecondsSinceEpoch(_dueDateMs);
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2000),
      lastDate: DateTime(2150),
    );
    if (picked == null || !mounted) return;
    final baseTime = DateTime.fromMillisecondsSinceEpoch(_depositDateMs);
    setState(() {
      _dueDateMs = DateTime(
        picked.year,
        picked.month,
        picked.day,
        baseTime.hour,
        baseTime.minute,
        baseTime.second,
        baseTime.millisecond,
      ).millisecondsSinceEpoch;
    });
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final service = await ref.read(fixedDepositServiceProvider.future);
      if (_editing && _isSettled) {
        final newRemark = _remarkCtrl.text.trim();
        await service.updateDepositRemark(
          commandId: _ids.forPayload([
            'settled-remark',
            widget.assetId,
            widget.depositIndex,
            newRemark,
          ]),
          assetId: widget.assetId!,
          index: widget.depositIndex!,
          remark: newRemark,
        );
        if (mounted) Navigator.of(context).pop();
        return;
      }

      if (_hostAssetId == noRef) {
        throw const Failure(FailureCode.validation, '请选择定存宿主账户');
      }
      final principal = parseAmount(_principalCtrl.text);
      if (principal.units <= BigInt.zero) {
        throw const Failure(FailureCode.validation, '定存本金须大于 0');
      }
      final annualRate = percentToAnnualRate(_rateCtrl.text);
      final periodCount = int.tryParse(_periodCountCtrl.text.trim());
      if (periodCount == null || periodCount < 1) {
        throw const Failure(FailureCode.validation, '存期须为正整数');
      }
      final expectedMoney = parseAmount(_expectedIncomeCtrl.text);
      if (expectedMoney.isNegative) {
        throw const Failure(FailureCode.validation, '预期收益不能为负数');
      }
      final bookId = ref.read(currentBookIdProvider).value;
      final effectiveFromAssetId = _fromAssetId == _hostAssetId
          ? noRef
          : _fromAssetId;

      final draft = FixedDepositDraft(
        targetAssetId: _hostAssetId,
        principal: principal,
        annualRate: annualRate,
        periodUnit: _periodUnit,
        periodCount: periodCount,
        depositDate: _depositDateMs,
        dueDateOverride: _dueDateMs,
        expectedIncomeMinorOverride: expectedMoney.storageMinor,
        currency: _currency.isEmpty ? null : _currency,
        fromAssetId: effectiveFromAssetId,
        updateAssetBalance: effectiveFromAssetId == noRef
            ? _updateAssetBalance
            : false,
        createBalanceAdjustRecord: _createBalanceAdjustRecord,
        remark: _remarkCtrl.text.trim(),
        bookId: bookId,
      );

      if (_editing) {
        await service.updateDeposit(
          commandId: _ids.forPayload([
            'update',
            widget.assetId,
            widget.depositIndex,
            ...draft.payload,
          ]),
          assetId: widget.assetId!,
          index: widget.depositIndex!,
          draft: draft,
        );
      } else {
        await service.createDeposit(
          commandId: _ids.forPayload(['create', ...draft.payload]),
          draft: draft,
        );
      }
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _error = safeMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currentBookIdProvider);
    final eligibleAssets =
        ref.watch(eligibleDepositAssetsProvider).value ?? _loadedEligibleAssets;
    final currencies = ref.watch(currenciesProvider).value ?? _loadedCurrencies;

    final validHostAssetId = eligibleAssets.any((a) => a.id == _hostAssetId)
        ? _hostAssetId
        : noRef;
    final hostItems = <DropdownMenuItem<int>>[
      if (validHostAssetId == noRef)
        DropdownMenuItem(
          value: noRef,
          child: Text(eligibleAssets.isEmpty ? '暂无可用普通账户' : '请选择定存宿主账户'),
        ),
      for (final a in eligibleAssets)
        DropdownMenuItem(
          value: a.id,
          child: Text(
            '${a.name}（${normalizeCurrency(a.currency) ?? baseCurrency}）',
          ),
        ),
    ];

    final seenCurrencyCodes = <String>{'', baseCurrency};
    final currencyItems = <DropdownMenuItem<String>>[
      const DropdownMenuItem(value: '', child: Text('跟随宿主账户币种')),
      const DropdownMenuItem(value: baseCurrency, child: Text('人民币（CNY）')),
      for (final c in currencies)
        if (c.enable && seenCurrencyCodes.add(c.code))
          DropdownMenuItem(value: c.code, child: Text('${c.name}（${c.code}）')),
      if (_currency.isNotEmpty && seenCurrencyCodes.add(_currency))
        DropdownMenuItem(
          value: _currency,
          child: Text(() {
            final match = currencies
                .where((c) => c.code == _currency)
                .firstOrNull;
            return match != null ? '${match.name}（${match.code}）' : _currency;
          }()),
        ),
    ];

    final sourceCandidates = <Asset>[
      for (final a in eligibleAssets)
        if (a.id != validHostAssetId) a,
    ];
    final hasHistoricalFrom =
        _editing &&
        _fromAssetId != noRef &&
        _fromAssetId != validHostAssetId &&
        !sourceCandidates.any((a) => a.id == _fromAssetId);
    final validFromAsset =
        sourceCandidates.any((a) => a.id == _fromAssetId) || hasHistoricalFrom
        ? _fromAssetId
        : noRef;
    final fromItems = <DropdownMenuItem<int>>[
      const DropdownMenuItem(value: noRef, child: Text('不选择（无转出账户）')),
      for (final a in sourceCandidates)
        DropdownMenuItem(
          value: a.id,
          child: Text(
            '${a.name}（${normalizeCurrency(a.currency) ?? baseCurrency}）',
          ),
        ),
      if (hasHistoricalFrom)
        DropdownMenuItem(
          value: _fromAssetId,
          child: Text(
            _historicalFromAsset != null &&
                    _historicalFromAsset!.id == _fromAssetId
                ? '${_historicalFromAsset!.name}（${normalizeCurrency(_historicalFromAsset!.currency) ?? baseCurrency}）'
                : '账户#$_fromAssetId',
          ),
        ),
    ];

    final editableFinancials = !_busy && !_isSettled;

    return Scaffold(
      key: const Key('fixed_deposit_editor_page'),
      appBar: AppBar(
        title: Text(_editing ? (_isSettled ? '编辑定存备注' : '编辑定期存款') : '新建定期存款'),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton(
            key: const Key('deposit_save_button'),
            onPressed: _busy || _loading ? null : _save,
            child: Text(_busy ? '保存中…' : '保存'),
          ),
        ),
      ),
      body: _loading
          ? const Loading()
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_isSettled)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            '该笔定期存款已到期结清，仅支持修改备注（将同步更新关联流水备注）。',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      _ControlledDropdownField<int>(
                        fieldKey: const Key('deposit_host_asset_dropdown'),
                        label: '定存宿主账户',
                        value: validHostAssetId,
                        items: hostItems,
                        enabled: editableFinancials && !_editing,
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() {
                            _hostAssetId = v;
                            if (_fromAssetId == v) _fromAssetId = noRef;
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      _ControlledDropdownField<String>(
                        fieldKey: const Key('deposit_currency_dropdown'),
                        label: '定存币种',
                        value: _currency,
                        items: currencyItems,
                        enabled: editableFinancials,
                        onChanged: (v) => setState(() => _currency = v ?? ''),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        key: const Key('deposit_principal_input'),
                        controller: _principalCtrl,
                        enabled: editableFinancials,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: amountInputFormatters,
                        decoration: const InputDecoration(labelText: '定存本金'),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        key: const Key('deposit_rate_input'),
                        controller: _rateCtrl,
                        enabled: editableFinancials,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: _rateInputFormatters,
                        decoration: const InputDecoration(
                          labelText: '年化利率',
                          suffixText: '%',
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              key: const Key('deposit_period_count_input'),
                              controller: _periodCountCtrl,
                              enabled: editableFinancials,
                              keyboardType: TextInputType.number,
                              inputFormatters: _intInputFormatters,
                              decoration: const InputDecoration(
                                labelText: '存期',
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          SegmentedButton<int>(
                            key: const Key('deposit_period_unit_selector'),
                            segments: const [
                              ButtonSegment(
                                value: DepositPeriodUnit.month,
                                label: Text('按月'),
                              ),
                              ButtonSegment(
                                value: DepositPeriodUnit.year,
                                label: Text('按年'),
                              ),
                            ],
                            selected: {_periodUnit},
                            onSelectionChanged: !editableFinancials
                                ? null
                                : (s) => setState(() {
                                    _periodUnit = s.first;
                                    _recalculateDerived();
                                  }),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      ListTile(
                        key: const Key('deposit_date_tile'),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('存入日期'),
                        trailing: Text(
                          formatDate(
                            DateTime.fromMillisecondsSinceEpoch(_depositDateMs),
                          ),
                        ),
                        onTap: editableFinancials ? _pickDepositDate : null,
                      ),
                      ListTile(
                        key: const Key('deposit_due_date_tile'),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('到期日期'),
                        subtitle: const Text('系统自动推算，点击可手动覆盖'),
                        trailing: Text(
                          formatDate(
                            DateTime.fromMillisecondsSinceEpoch(_dueDateMs),
                          ),
                        ),
                        onTap: editableFinancials ? _pickDueDate : null,
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        key: const Key('deposit_expected_income_input'),
                        controller: _expectedIncomeCtrl,
                        enabled: editableFinancials,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: amountInputFormatters,
                        decoration: const InputDecoration(
                          labelText: '预期总收益',
                          helperText: '按单利自动计算，支持手动修改覆盖',
                        ),
                      ),
                      const SizedBox(height: 12),
                      _ControlledDropdownField<int>(
                        fieldKey: const Key('deposit_from_asset_dropdown'),
                        label: '本金转出账户（可选）',
                        value: validFromAsset,
                        items: fromItems,
                        enabled: editableFinancials,
                        onChanged: (v) => setState(() {
                          _fromAssetId = v ?? noRef;
                          if (_fromAssetId != noRef) {
                            _updateAssetBalance = false;
                          }
                        }),
                      ),
                      if (validFromAsset == noRef) ...[
                        SwitchListTile(
                          key: const Key('deposit_update_balance_switch'),
                          contentPadding: EdgeInsets.zero,
                          title: const Text('直接增加宿主账户余额'),
                          subtitle: const Text('不选转出账户时，将本金计入宿主账户余额'),
                          value: _updateAssetBalance,
                          onChanged: !editableFinancials
                              ? null
                              : (v) => setState(() => _updateAssetBalance = v),
                        ),
                        if (_updateAssetBalance)
                          SwitchListTile(
                            key: const Key('deposit_record_adjust_switch'),
                            contentPadding: EdgeInsets.zero,
                            title: const Text('生成平账调整记录（推荐）'),
                            subtitle: const Text('避免账户对账出现无单据差额'),
                            value: _createBalanceAdjustRecord,
                            onChanged: !editableFinancials
                                ? null
                                : (v) => setState(
                                    () => _createBalanceAdjustRecord = v,
                                  ),
                          ),
                      ],
                      const SizedBox(height: 12),
                      TextField(
                        key: const Key('deposit_remark_input'),
                        controller: _remarkCtrl,
                        enabled: !_busy,
                        decoration: const InputDecoration(labelText: '备注（可选）'),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _error!,
                          key: const Key('deposit_editor_error'),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
    );
  }
}

class _ControlledDropdownField<T> extends StatelessWidget {
  const _ControlledDropdownField({
    required this.fieldKey,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    this.enabled = true,
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
