import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/failure.dart';
import '../../core/money.dart';
import '../../data/db/database.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/asset_overview.dart' show normalizeCurrency;
import '../../domain/rules/currency_rates.dart';
import '../../domain/rules/debt_rules.dart';
import '../common/common.dart';
import 'debt_providers.dart';

final _maxDebtAmount = Money.parse('88888888888.00');

final debtAmountInputFormatters = <TextInputFormatter>[
  FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
];

Money parseDebtAmount(String text, {String currency = 'CNY'}) {
  final t = text.trim();
  if (t.isEmpty) return Money.zero(currency);
  final normalized = t.endsWith('.') ? t.substring(0, t.length - 1) : t;
  final money = Money.parse(
    normalized.startsWith('.') ? '0$normalized' : normalized,
    currency: currency,
  );
  if (money.units > _maxDebtAmount.units) {
    throw const Failure(FailureCode.validation, '金额不能超过 88888888888.00');
  }
  return money;
}

/// Creates ([debtId] == null) or edits a lending/borrowing project (`F-011`).
class DebtEditorPage extends ConsumerStatefulWidget {
  const DebtEditorPage({super.key, this.debtId, this.initialSubType});

  final int? debtId;
  final int? initialSubType;

  @override
  ConsumerState<DebtEditorPage> createState() => _DebtEditorPageState();
}

class _DebtEditorPageState extends ConsumerState<DebtEditorPage> {
  final _nameCtrl = TextEditingController();
  final _principalCtrl = TextEditingController();
  final _fundingAmountCtrl = TextEditingController();
  final _remarkCtrl = TextEditingController();
  final _ids = CommandIds();

  int _subType = AssetType.debtLend;
  String? _currency;
  int _fundingAssetId = noRef;
  Set<int> _selectedBookIds = {};
  late DateTime _startDate;
  DateTime? _endDate;
  bool _countedInNetWorth = true;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  bool get _editing => widget.debtId != null;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _startDate = DateTime(now.year, now.month, now.day);
    if (widget.initialSubType == AssetType.debtBorrow ||
        widget.initialSubType == AssetType.debtLend) {
      _subType = widget.initialSubType!;
    }
    _loadInitial();
  }

  Future<void> _loadInitial() async {
    try {
      final currentBookId = await ref.read(currentBookIdProvider.future);
      await ref.read(booksProvider.future);
      await ref.read(currenciesProvider.future);
      await ref.read(debtFundingAccountsProvider.future);
      if (_editing) {
        final debt = await ref.read(
          debtAssetStreamProvider(widget.debtId!).future,
        );
        if (debt == null) {
          throw const Failure(FailureCode.conflict, '借贷项目不存在或已删除');
        }
        final bound = await ref.read(
          debtBoundBookIdsProvider(widget.debtId!).future,
        );
        final info = LoanInfo.parse(debt.loanInfo);
        _subType = debt.subType;
        _nameCtrl.text = debt.name;
        _remarkCtrl.text = debt.remark ?? '';
        _currency = debt.currency;
        _countedInNetWorth = isDebtCountedInNetWorth(debt.isEffectiveAsset);
        _selectedBookIds = bound.isEmpty ? {currentBookId} : bound.toSet();
        if (info.startDate > 0) {
          final sd = DateTime.fromMillisecondsSinceEpoch(info.startDate);
          _startDate = DateTime(sd.year, sd.month, sd.day);
        }
        if (info.endDate != noRef && info.endDate > 0) {
          final ed = DateTime.fromMillisecondsSinceEpoch(info.endDate);
          _endDate = DateTime(ed.year, ed.month, ed.day);
        }
      } else {
        _selectedBookIds = {currentBookId};
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
    _nameCtrl.dispose();
    _principalCtrl.dispose();
    _fundingAmountCtrl.dispose();
    _remarkCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickStartDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) {
      setState(() {
        _startDate = DateTime(picked.year, picked.month, picked.day);
        if (_endDate != null && _endDate!.isBefore(_startDate)) {
          _endDate = _startDate;
        }
      });
    }
  }

  Future<void> _pickEndDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _endDate ?? _startDate,
      firstDate: _startDate,
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) {
      setState(() {
        _endDate = DateTime(picked.year, picked.month, picked.day);
      });
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_selectedBookIds.isEmpty) {
        throw const Failure(FailureCode.validation, '请至少选择一个关联账本');
      }
      final orderedBooks = _selectedBookIds.toList()..sort();
      final startMs = _startDate.millisecondsSinceEpoch;
      final endMs = _endDate == null ? noRef : _endDate!.millisecondsSinceEpoch;
      final debtCurr = normalizeCurrency(_currency) ?? baseCurrency;
      final service = await ref.read(debtServiceProvider.future);

      if (_editing) {
        await service.updateDebt(
          commandId: _ids.forPayload([
            'edit-debt',
            widget.debtId,
            _nameCtrl.text,
            startMs,
            endMs,
            _countedInNetWorth,
            _remarkCtrl.text,
            orderedBooks,
          ]),
          debtId: widget.debtId!,
          name: _nameCtrl.text,
          startDate: startMs,
          endDate: endMs,
          countedInNetWorth: _countedInNetWorth,
          remark: _remarkCtrl.text,
          bookIds: orderedBooks,
        );
      } else {
        final principal = parseDebtAmount(
          _principalCtrl.text,
          currency: debtCurr,
        );
        Money? explicitFundingAmount;
        if (_fundingAssetId != noRef &&
            _fundingAmountCtrl.text.trim().isNotEmpty) {
          final accounts = await ref.read(debtFundingAccountsProvider.future);
          final selectedAcc = accounts
              .where((a) => a.id == _fundingAssetId)
              .firstOrNull;
          final accCurr =
              normalizeCurrency(selectedAcc?.currency) ?? baseCurrency;
          explicitFundingAmount = parseDebtAmount(
            _fundingAmountCtrl.text,
            currency: accCurr,
          );
        }
        await service.createDebt(
          commandId: _ids.forPayload([
            'create-debt',
            _subType,
            _nameCtrl.text,
            principal.toJson(),
            orderedBooks,
            startMs,
            endMs,
            _fundingAssetId,
            explicitFundingAmount?.toJson(),
            _countedInNetWorth,
            _currency,
            _remarkCtrl.text,
          ]),
          subType: _subType,
          name: _nameCtrl.text,
          principal: principal,
          bookId: orderedBooks.first,
          bookIds: orderedBooks,
          startDate: startMs,
          endDate: endMs,
          fundingAssetId: _fundingAssetId,
          fundingAmount: explicitFundingAmount,
          countedInNetWorth: _countedInNetWorth,
          currency: _currency,
          remark: _remarkCtrl.text,
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = safeMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final books = ref.watch(booksProvider).value ?? const <AccountBook>[];
    final currencies =
        ref.watch(currenciesProvider).value ?? const <Currency>[];
    final fundingAccounts =
        ref.watch(debtFundingAccountsProvider).value ?? const <Asset>[];
    final selectedFunding = fundingAccounts
        .where((a) => a.id == _fundingAssetId)
        .firstOrNull;
    final debtCurr = normalizeCurrency(_currency) ?? baseCurrency;
    final fundingCurr =
        normalizeCurrency(selectedFunding?.currency) ?? baseCurrency;
    final crossCurrency = _fundingAssetId != noRef && debtCurr != fundingCurr;

    return Scaffold(
      key: const Key('debt_editor_page'),
      appBar: AppBar(title: Text(_editing ? '编辑借贷' : '新建借贷')),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton(
            key: const Key('save_debt_button'),
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
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (!_editing)
                      SegmentedButton<int>(
                        key: const Key('debt_direction_selector'),
                        segments: const [
                          ButtonSegment(
                            value: AssetType.debtLend,
                            label: Text('借出（应收）'),
                            icon: Icon(Icons.call_made),
                          ),
                          ButtonSegment(
                            value: AssetType.debtBorrow,
                            label: Text('借入（应付）'),
                            icon: Icon(Icons.call_received),
                          ),
                        ],
                        selected: {_subType},
                        onSelectionChanged: _busy
                            ? null
                            : (s) => setState(() => _subType = s.first),
                      )
                    else
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('借贷方向'),
                        trailing: Chip(
                          label: Text(
                            _subType == AssetType.debtBorrow
                                ? '借入（应付）'
                                : '借出（应收）',
                          ),
                        ),
                      ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const Key('debt_name_input'),
                      controller: _nameCtrl,
                      enabled: !_busy,
                      decoration: InputDecoration(
                        labelText: _subType == AssetType.debtBorrow
                            ? '债权人 / 借入方名称'
                            : '借款人 / 借出对象名称',
                        hintText: '如：张三、朋友周转',
                      ),
                    ),
                    if (!_editing) ...[
                      const SizedBox(height: 12),
                      TextField(
                        key: const Key('debt_principal_input'),
                        controller: _principalCtrl,
                        enabled: !_busy,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: debtAmountInputFormatters,
                        decoration: InputDecoration(
                          labelText: _subType == AssetType.debtBorrow
                              ? '借入总本金 ($debtCurr)'
                              : '借出总本金 ($debtCurr)',
                        ),
                      ),
                      if (currencies.length > 1 ||
                          (_currency != null && _currency != baseCurrency)) ...[
                        const SizedBox(height: 12),
                        InputDecorator(
                          decoration: const InputDecoration(labelText: '借贷币种'),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<String?>(
                              key: const Key('debt_currency_selector'),
                              value: _currency,
                              isExpanded: true,
                              isDense: true,
                              items: [
                                const DropdownMenuItem<String?>(
                                  value: null,
                                  child: Text('默认本位币 (CNY)'),
                                ),
                                if (_currency != null &&
                                    _currency != baseCurrency &&
                                    !currencies.any((c) => c.code == _currency))
                                  DropdownMenuItem<String?>(
                                    value: _currency,
                                    child: Text(_currency!),
                                  ),
                                for (final c in currencies)
                                  if (c.code != baseCurrency)
                                    DropdownMenuItem<String?>(
                                      value: c.code,
                                      child: Text('${c.name} (${c.code})'),
                                    ),
                              ],
                              onChanged: _busy
                                  ? null
                                  : (v) => setState(() => _currency = v),
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      InputDecorator(
                        decoration: InputDecoration(
                          labelText: _subType == AssetType.debtBorrow
                              ? '收款资金账户（可选）'
                              : '付款资金账户（可选）',
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<int>(
                            key: const Key('debt_funding_selector'),
                            value: _fundingAssetId,
                            isExpanded: true,
                            isDense: true,
                            items: [
                              const DropdownMenuItem<int>(
                                value: noRef,
                                child: Text('不关联资金账户'),
                              ),
                              if (_fundingAssetId != noRef &&
                                  !fundingAccounts.any(
                                    (a) => a.id == _fundingAssetId,
                                  ))
                                DropdownMenuItem<int>(
                                  value: _fundingAssetId,
                                  child: Text('账户#$_fundingAssetId'),
                                ),
                              for (final a in fundingAccounts)
                                DropdownMenuItem<int>(
                                  value: a.id,
                                  child: Text(
                                    a.currency == null
                                        ? a.name
                                        : '${a.name} (${a.currency})',
                                  ),
                                ),
                            ],
                            onChanged: _busy
                                ? null
                                : (v) => setState(
                                    () => _fundingAssetId = v ?? noRef,
                                  ),
                          ),
                        ),
                      ),
                      if (crossCurrency) ...[
                        const SizedBox(height: 12),
                        TextField(
                          key: const Key('debt_funding_amount_input'),
                          controller: _fundingAmountCtrl,
                          enabled: !_busy,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          inputFormatters: debtAmountInputFormatters,
                          decoration: InputDecoration(
                            labelText: '资金账户实际变动金额 ($fundingCurr，留空按汇率自动折算)',
                          ),
                        ),
                      ],
                    ],
                    const SizedBox(height: 16),
                    Text('关联账本', style: Theme.of(context).textTheme.labelLarge),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final b in books)
                          FilterChip(
                            key: Key('debt_book_chip_${b.id}'),
                            label: Text(b.name),
                            selected: _selectedBookIds.contains(b.id),
                            onSelected: _busy
                                ? null
                                : (selected) {
                                    setState(() {
                                      if (selected) {
                                        _selectedBookIds.add(b.id);
                                      } else if (_selectedBookIds.length > 1) {
                                        _selectedBookIds.remove(b.id);
                                      }
                                    });
                                  },
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    ListTile(
                      key: const Key('debt_start_date_tile'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('借款日期'),
                      trailing: Text(formatDate(_startDate)),
                      onTap: _busy ? null : _pickStartDate,
                    ),
                    ListTile(
                      key: const Key('debt_end_date_tile'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('到期日期（可选）'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _endDate == null ? '未设置' : formatDate(_endDate!),
                          ),
                          if (_endDate != null)
                            IconButton(
                              key: const Key('clear_debt_end_date'),
                              tooltip: '清除到期日期',
                              icon: const Icon(Icons.clear, size: 18),
                              onPressed: _busy
                                  ? null
                                  : () => setState(() => _endDate = null),
                            ),
                        ],
                      ),
                      onTap: _busy ? null : _pickEndDate,
                    ),
                    SwitchListTile(
                      key: const Key('debt_counted_switch'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        _subType == AssetType.debtBorrow ? '计入总负债' : '计入总资产',
                      ),
                      subtitle: const Text('关闭后不计入净资产与借贷顶部汇总'),
                      value: _countedInNetWorth,
                      onChanged: _busy
                          ? null
                          : (v) => setState(() => _countedInNetWorth = v),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      key: const Key('debt_remark_input'),
                      controller: _remarkCtrl,
                      enabled: !_busy,
                      decoration: const InputDecoration(labelText: '备注（可选）'),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        key: const Key('debt_editor_error'),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
    );
  }
}
