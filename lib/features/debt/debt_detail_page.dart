import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../app/providers.dart';
import '../../core/money.dart';
import '../../data/db/database.dart';
import '../../domain/ledger/record_extra.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/asset_overview.dart' show normalizeCurrency;
import '../../domain/rules/currency_rates.dart';
import '../common/common.dart';
import 'debt_editor_page.dart';
import 'debt_providers.dart';

const _uuid = Uuid();

enum _DetailMenuAction { edit, recalibrate, settle, reopen, delete }

/// Detail page for one lending/borrowing project (`F-011` / `/bkp/DDAct`).
class DebtDetailPage extends ConsumerStatefulWidget {
  const DebtDetailPage({super.key, required this.debtId});

  final int debtId;

  @override
  ConsumerState<DebtDetailPage> createState() => _DebtDetailPageState();
}

class _DebtDetailPageState extends ConsumerState<DebtDetailPage> {
  final _ids = CommandIds();
  bool _groupByType = false;

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _onMenuAction(_DetailMenuAction action, Asset debt) async {
    try {
      final service = await ref.read(debtServiceProvider.future);
      switch (action) {
        case _DetailMenuAction.edit:
          if (!mounted) return;
          await Navigator.of(context).push<bool>(
            MaterialPageRoute(builder: (_) => DebtEditorPage(debtId: debt.id)),
          );
        case _DetailMenuAction.recalibrate:
          await service.recalibrateDebt(
            commandId: _ids.forPayload(['recal', debt.id, _uuid.v4()]),
            debtId: debt.id,
          );
          _toast('余额校准完成');
        case _DetailMenuAction.settle:
          if (!mounted) return;
          final ok = await confirm(
            context,
            title: '手动结清“${debt.name}”？',
            message: '标记结清后剩余本金将归零，后续自动校准不会意外重开。',
            ok: '确认结清',
          );
          if (!ok || !mounted) return;
          await service.settleDebt(
            commandId: _ids.forPayload(['settle', debt.id, _uuid.v4()]),
            debtId: debt.id,
          );
          _toast('已标记为已结清');
        case _DetailMenuAction.reopen:
          if (!mounted) return;
          final ok = await confirm(
            context,
            title: '重新开启“${debt.name}”？',
            message: '将根据历史本金流水重新计算当前未结清本金。',
            ok: '重新开启',
          );
          if (!ok || !mounted) return;
          await service.reopenDebt(
            commandId: _ids.forPayload(['reopen', debt.id, _uuid.v4()]),
            debtId: debt.id,
          );
          _toast('已恢复借贷状态');
        case _DetailMenuAction.delete:
          if (!mounted) return;
          final ok = await confirm(
            context,
            title: '删除借贷“${debt.name}”？',
            message: '将一并删除关联流水并回滚资金账户余额。',
            ok: '删除',
          );
          if (!ok || !mounted) return;
          await service.deleteDebt(
            commandId: _ids.forPayload(['delete-debt', debt.id]),
            debtId: debt.id,
          );
          if (mounted) Navigator.of(context).pop(true);
      }
    } catch (e) {
      _toast(safeMessage(e));
    }
  }

  Future<List<Asset>> _loadFundingAccounts() async {
    final ledgerQ = await ref.read(queriesProvider.future);
    final active = await ledgerQ.getAssets(includeArchived: false);
    return [
      for (final a in active)
        if (a.type != AssetType.debt) a,
    ];
  }

  Future<void> _showRepayDialog(
    DebtDetailView view, {
    bool pureInterestOnly = false,
  }) async {
    final ledgerQ = await ref.read(queriesProvider.future);
    final currentBookId = await ledgerQ.getCurrentBookId();
    final books = await ledgerQ.getBooks();
    final fundingAccounts = await _loadFundingAccounts();
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (_) => _RepayDialog(
        view: view,
        pureInterestOnly: pureInterestOnly,
        currentBookId: currentBookId,
        books: books,
        fundingAccounts: fundingAccounts,
        ids: _ids,
      ),
    );
  }

  Future<void> _showAddPrincipalDialog(DebtDetailView view) async {
    final ledgerQ = await ref.read(queriesProvider.future);
    final currentBookId = await ledgerQ.getCurrentBookId();
    final books = await ledgerQ.getBooks();
    final fundingAccounts = await _loadFundingAccounts();
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (_) => _AddPrincipalDialog(
        view: view,
        currentBookId: currentBookId,
        books: books,
        fundingAccounts: fundingAccounts,
        ids: _ids,
      ),
    );
  }

  Future<void> _showEditRecordDialog(
    DebtDetailView view,
    LedgerRecord rec,
  ) async {
    final fundingAccounts = await _loadFundingAccounts();
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (_) => _EditRecordDialog(
        view: view,
        rec: rec,
        initialFundingId: _fundingIdOfRecord(rec, view.debt.id),
        recordLabel: _recordTypeLabel(rec),
        fundingAccounts: fundingAccounts,
        ids: _ids,
      ),
    );
  }

  Future<void> _deleteSingleRecord(LedgerRecord rec) async {
    final ok = await confirm(
      context,
      title: '删除此笔${_recordTypeLabel(rec)}？',
      message: '删除后将自动回滚关联资金账户并更新借贷本金。',
      ok: '删除',
    );
    if (!ok || !mounted) return;
    try {
      final service = await ref.read(debtServiceProvider.future);
      await service.deleteDebtRecord(
        commandId: _ids.forPayload(['del-rec', rec.recordId]),
        recordId: rec.recordId,
      );
    } catch (e) {
      _toast(safeMessage(e));
    }
  }

  int _fundingIdOfRecord(LedgerRecord rec, int debtId) {
    if (rec.type == RecordType.borrowIn ||
        rec.type == RecordType.collect ||
        (rec.type == RecordType.debtInterest &&
            rec.subType == RecordDirection.income)) {
      return rec.toAssetId == debtId ? noRef : rec.toAssetId;
    }
    return rec.fromAssetId == debtId ? noRef : rec.fromAssetId;
  }

  String _recordTypeLabel(LedgerRecord rec) => switch (rec.type) {
    RecordType.borrowIn => '借入',
    RecordType.lendOut => '借出',
    RecordType.repay => '还款',
    RecordType.collect => '收款',
    RecordType.debtInterest =>
      rec.subType == RecordDirection.expense ? '利息支出' : '利息收入',
    _ => RecordType.names[rec.type] ?? '流水',
  };

  @override
  Widget build(BuildContext context) {
    final viewAsync = ref.watch(debtDetailViewProvider(widget.debtId));
    ref.watch(debtFundingAccountsProvider);
    ref.watch(booksProvider);
    final theme = Theme.of(context);

    return Scaffold(
      key: const Key('debt_detail_page'),
      appBar: AppBar(
        title: Text(viewAsync.value?.debt.name ?? '借贷详情'),
        actions: [
          if (viewAsync.value != null)
            PopupMenuButton<_DetailMenuAction>(
              key: const Key('debt_detail_menu'),
              onSelected: (a) => _onMenuAction(a, viewAsync.value!.debt),
              itemBuilder: (_) {
                final settled =
                    viewAsync.value!.debt.status == AssetStatus.settled;
                return [
                  const PopupMenuItem(
                    key: Key('debt_menu_edit'),
                    value: _DetailMenuAction.edit,
                    child: Text('编辑信息'),
                  ),
                  const PopupMenuItem(
                    key: Key('debt_menu_recalibrate'),
                    value: _DetailMenuAction.recalibrate,
                    child: Text('自动校准余额'),
                  ),
                  if (!settled)
                    const PopupMenuItem(
                      key: Key('debt_menu_settle'),
                      value: _DetailMenuAction.settle,
                      child: Text('手动结清'),
                    )
                  else
                    const PopupMenuItem(
                      key: Key('debt_menu_reopen'),
                      value: _DetailMenuAction.reopen,
                      child: Text('重新开启'),
                    ),
                  const PopupMenuItem(
                    key: Key('debt_menu_delete'),
                    value: _DetailMenuAction.delete,
                    child: Text('删除借贷'),
                  ),
                ];
              },
            ),
        ],
      ),
      body: asyncBody(viewAsync, (view) {
        if (view == null) {
          return const Center(child: Text('借贷项目不存在或已删除'));
        }
        final debt = view.debt;
        final m = view.metrics;
        final isBorrow = debt.subType == AssetType.debtBorrow;
        final settled = debt.status == AssetStatus.settled;
        final permille = m.progressPermille;

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              key: const Key('debt_detail_summary_card'),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Chip(label: Text(isBorrow ? '借入（应付）' : '借出（应收）')),
                        Chip(
                          key: const Key('debt_status_chip'),
                          label: Text(settled ? '已结清' : '进行中'),
                        ),
                        if (debt.currency != null)
                          Chip(label: Text(debt.currency!)),
                        if (!m.countedInNetWorth)
                          const Chip(label: Text('不计入资产/负债')),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      isBorrow ? '剩余待还本金' : '剩余应收本金',
                      style: theme.textTheme.labelMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      formatMinor(m.remainingPrincipalMinor),
                      key: const Key('debt_remaining_principal'),
                      style: theme.textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          isBorrow ? '还款进度' : '收回进度',
                          style: theme.textTheme.bodySmall,
                        ),
                        Text(
                          m.progressLabel,
                          key: const Key('debt_progress_label'),
                          style: theme.textTheme.labelLarge,
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: SizedBox(
                        key: const Key('debt_progress_bar'),
                        height: 8,
                        child: Row(
                          children: [
                            if (permille > 0)
                              Expanded(
                                flex: permille,
                                child: ColoredBox(
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                            if (permille < 1000)
                              Expanded(
                                flex: 1000 - permille,
                                child: ColoredBox(
                                  color:
                                      theme.colorScheme.surfaceContainerHighest,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: _MetricColumn(
                            label: '总本金',
                            value: formatMinor(m.totalPrincipalMinor),
                            valueKey: const Key('debt_total_principal'),
                          ),
                        ),
                        Expanded(
                          child: _MetricColumn(
                            label: isBorrow ? '已还本金' : '已收本金',
                            value: formatMinor(m.repaidPrincipalMinor),
                            valueKey: const Key('debt_repaid_principal'),
                          ),
                        ),
                        Expanded(
                          child: _MetricColumn(
                            label: '累计利息',
                            value: formatMinor(m.totalInterestMinor),
                            valueKey: const Key('debt_total_interest'),
                          ),
                        ),
                      ],
                    ),
                    if (m.loanInfo.startDate > 0 ||
                        m.loanInfo.endDate != noRef ||
                        (debt.remark != null && debt.remark!.isNotEmpty)) ...[
                      const Divider(height: 24),
                      if (m.loanInfo.startDate > 0)
                        Text(
                          '借款日期：${formatDate(DateTime.fromMillisecondsSinceEpoch(m.loanInfo.startDate))}'
                          '${m.loanInfo.endDate != noRef && m.loanInfo.endDate > 0 ? ' · 到期日期：${formatDate(DateTime.fromMillisecondsSinceEpoch(m.loanInfo.endDate))}' : ''}',
                          style: theme.textTheme.bodySmall,
                        ),
                      if (debt.remark != null && debt.remark!.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(debt.remark!, style: theme.textTheme.bodySmall),
                      ],
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (!settled) ...[
                  FilledButton.icon(
                    key: const Key('debt_action_repay'),
                    icon: const Icon(Icons.payments_outlined),
                    label: Text(isBorrow ? '还款' : '收款'),
                    onPressed: () => _showRepayDialog(view),
                  ),
                  OutlinedButton.icon(
                    key: const Key('debt_action_add_principal'),
                    icon: const Icon(Icons.add_circle_outline),
                    label: Text(isBorrow ? '追加借入' : '追加借出'),
                    onPressed: () => _showAddPrincipalDialog(view),
                  ),
                ],
                OutlinedButton.icon(
                  key: const Key('debt_action_interest_only'),
                  icon: const Icon(Icons.percent),
                  label: const Text('记纯利息'),
                  onPressed: () =>
                      _showRepayDialog(view, pureInterestOnly: true),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '关联流水 (${view.records.length})',
                  style: theme.textTheme.titleSmall,
                ),
                TextButton.icon(
                  key: const Key('debt_group_mode_toggle'),
                  onPressed: () => setState(() => _groupByType = !_groupByType),
                  icon: const Icon(Icons.sort, size: 18),
                  label: Text(_groupByType ? '按类型分组' : '按时间排序'),
                ),
              ],
            ),
            if (view.records.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: Text('暂无关联流水')),
              )
            else if (!_groupByType)
              for (final r in view.records) _buildRecordTile(view, r)
            else
              ..._buildGroupedByType(view),
            const SizedBox(height: 64),
          ],
        );
      }),
    );
  }

  List<Widget> _buildGroupedByType(DebtDetailView view) {
    final buckets = <String, List<LedgerRecord>>{};
    for (final r in view.records) {
      final label = _recordTypeLabel(r);
      buckets.putIfAbsent(label, () => []).add(r);
    }
    final widgets = <Widget>[];
    for (final entry in buckets.entries) {
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Text(
            '${entry.key} (${entry.value.length})',
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
      );
      for (final r in entry.value) {
        widgets.add(_buildRecordTile(view, r));
      }
    }
    return widgets;
  }

  Widget _buildRecordTile(DebtDetailView view, LedgerRecord rec) {
    final debtId = view.debt.id;
    final fundingId = _fundingIdOfRecord(rec, debtId);
    final fundingName = fundingId == noRef
        ? '无关联账户'
        : (view.accountNames[fundingId] ?? '账户#$fundingId');
    final bookName = view.bookNames[rec.accountBookId] ?? '账本';
    final dateStr = formatDate(
      DateTime.fromMillisecondsSinceEpoch(rec.recordTime),
    );
    final currSnap = RecordExtra.parse(rec.extraInfo).currency;
    final debtCurr = normalizeCurrency(view.debt.currency) ?? baseCurrency;
    final displayMinor =
        (currSnap != null &&
            currSnap.isValid &&
            normalizeCurrency(currSnap.sourceCode) == debtCurr)
        ? currSnap.sourceGross
        : rec.moneyMinor;

    return Card(
      key: Key('debt_record_${rec.recordId}'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        onTap: () => _showEditRecordDialog(view, rec),
        title: Text(_recordTypeLabel(rec)),
        subtitle: Text(
          [
            dateStr,
            fundingName,
            bookName,
            if (rec.remark.isNotEmpty) rec.remark,
          ].join(' · '),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              formatMinor(displayMinor),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            IconButton(
              key: Key('delete_debt_record_${rec.recordId}'),
              tooltip: '删除流水',
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: () => _deleteSingleRecord(rec),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricColumn extends StatelessWidget {
  const _MetricColumn({
    required this.label,
    required this.value,
    required this.valueKey,
  });

  final String label;
  final String value;
  final Key valueKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.labelSmall),
        const SizedBox(height: 2),
        Text(value, key: valueKey, style: theme.textTheme.titleMedium),
      ],
    );
  }
}

class _RepayDialog extends ConsumerStatefulWidget {
  const _RepayDialog({
    required this.view,
    required this.pureInterestOnly,
    required this.currentBookId,
    required this.books,
    required this.fundingAccounts,
    required this.ids,
  });

  final DebtDetailView view;
  final bool pureInterestOnly;
  final int currentBookId;
  final List<AccountBook> books;
  final List<Asset> fundingAccounts;
  final CommandIds ids;

  @override
  ConsumerState<_RepayDialog> createState() => _RepayDialogState();
}

class _RepayDialogState extends ConsumerState<_RepayDialog> {
  late final TextEditingController _principalCtrl;
  final _interestCtrl = TextEditingController();
  final _remarkCtrl = TextEditingController();
  late int _selectedBookId;
  int _selectedFundingId = noRef;
  bool _excludeBudget = false;
  late DateTime _operateDate;
  bool _submitting = false;
  String? _dialogError;

  @override
  void initState() {
    super.initState();
    _principalCtrl = TextEditingController(
      text: widget.pureInterestOnly
          ? '0'
          : formatMinor(widget.view.metrics.remainingPrincipalMinor),
    );
    var bookId = widget.view.boundBookIds.contains(widget.currentBookId)
        ? widget.currentBookId
        : (widget.view.boundBookIds.isNotEmpty
              ? widget.view.boundBookIds.first
              : widget.currentBookId);
    if (widget.books.isNotEmpty && !widget.books.any((b) => b.id == bookId)) {
      bookId = widget.books.first.id;
    }
    _selectedBookId = bookId;
    final now = DateTime.now();
    _operateDate = DateTime(now.year, now.month, now.day);
  }

  @override
  void dispose() {
    _principalCtrl.dispose();
    _interestCtrl.dispose();
    _remarkCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final debt = widget.view.debt;
    final isBorrow = debt.subType == AssetType.debtBorrow;
    final debtCurr = normalizeCurrency(debt.currency) ?? baseCurrency;

    return AlertDialog(
      title: Text(
        widget.pureInterestOnly ? '记录纯利息' : (isBorrow ? '记录还款' : '记录收款'),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!widget.pureInterestOnly) ...[
              TextField(
                key: const Key('repay_principal_input'),
                controller: _principalCtrl,
                enabled: !_submitting,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: debtAmountInputFormatters,
                decoration: InputDecoration(
                  labelText: isBorrow
                      ? '归还本金 ($debtCurr，填 0 为纯利息)'
                      : '收回本金 ($debtCurr，填 0 为纯利息)',
                ),
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              key: Key(
                widget.pureInterestOnly
                    ? 'pure_interest_input'
                    : 'repay_interest_input',
              ),
              controller: _interestCtrl,
              enabled: !_submitting,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: debtAmountInputFormatters,
              decoration: InputDecoration(
                labelText: isBorrow
                    ? '利息支出 ($debtCurr${widget.pureInterestOnly ? '' : '，可选'})'
                    : '利息收入 ($debtCurr${widget.pureInterestOnly ? '' : '，可选'})',
              ),
            ),
            const SizedBox(height: 12),
            InputDecorator(
              decoration: const InputDecoration(labelText: '资金账户'),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  key: const Key('repay_funding_selector'),
                  value: _selectedFundingId,
                  isExpanded: true,
                  isDense: true,
                  items: [
                    const DropdownMenuItem<int>(
                      value: noRef,
                      child: Text('不关联资金账户'),
                    ),
                    for (final a in widget.fundingAccounts)
                      DropdownMenuItem<int>(value: a.id, child: Text(a.name)),
                  ],
                  onChanged: _submitting
                      ? null
                      : (v) => setState(() => _selectedFundingId = v ?? noRef),
                ),
              ),
            ),
            if (widget.books.length > 1) ...[
              const SizedBox(height: 12),
              InputDecorator(
                decoration: const InputDecoration(labelText: '记入账本'),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                    key: const Key('repay_book_selector'),
                    value: _selectedBookId,
                    isExpanded: true,
                    isDense: true,
                    items: [
                      for (final b in widget.books)
                        DropdownMenuItem<int>(value: b.id, child: Text(b.name)),
                    ],
                    onChanged: _submitting
                        ? null
                        : (v) {
                            if (v != null) {
                              setState(() => _selectedBookId = v);
                            }
                          },
                  ),
                ),
              ),
            ],
            if (isBorrow) ...[
              const SizedBox(height: 8),
              SwitchListTile(
                key: const Key('repay_interest_exclude_budget'),
                contentPadding: EdgeInsets.zero,
                title: const Text('利息不计入预算'),
                value: _excludeBudget,
                onChanged: _submitting
                    ? null
                    : (v) => setState(() => _excludeBudget = v),
              ),
            ],
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('操作日期'),
              trailing: Text(formatDate(_operateDate)),
              onTap: _submitting
                  ? null
                  : () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: _operateDate,
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                      );
                      if (picked != null && mounted) {
                        setState(() {
                          _operateDate = DateTime(
                            picked.year,
                            picked.month,
                            picked.day,
                          );
                        });
                      }
                    },
            ),
            TextField(
              key: const Key('repay_remark_input'),
              controller: _remarkCtrl,
              enabled: !_submitting,
              decoration: const InputDecoration(labelText: '备注（可选）'),
            ),
            if (_dialogError != null) ...[
              const SizedBox(height: 8),
              Text(
                _dialogError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('confirm_repay_button'),
          onPressed: _submitting
              ? null
              : () async {
                  setState(() {
                    _submitting = true;
                    _dialogError = null;
                  });
                  try {
                    final p = widget.pureInterestOnly
                        ? Money.zero(debtCurr)
                        : parseDebtAmount(
                            _principalCtrl.text,
                            currency: debtCurr,
                          );
                    final i = parseDebtAmount(
                      _interestCtrl.text,
                      currency: debtCurr,
                    );
                    final service = await ref.read(debtServiceProvider.future);
                    await service.recordRepayment(
                      commandId: widget.ids.forPayload([
                        'repay-dialog',
                        debt.id,
                        p.toJson(),
                        i.toJson(),
                        _operateDate.millisecondsSinceEpoch,
                        _selectedBookId,
                        _selectedFundingId,
                        _excludeBudget,
                        _remarkCtrl.text,
                        _uuid.v4(),
                      ]),
                      debtId: debt.id,
                      principal: p,
                      interest: i,
                      operateDate: _operateDate.millisecondsSinceEpoch,
                      bookId: _selectedBookId,
                      fundingAssetId: _selectedFundingId,
                      interestExcludeBudget: _excludeBudget,
                      remark: _remarkCtrl.text,
                    );
                    if (context.mounted) Navigator.pop(context);
                  } catch (e) {
                    if (mounted) {
                      setState(() {
                        _submitting = false;
                        _dialogError = safeMessage(e);
                      });
                    }
                  }
                },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _AddPrincipalDialog extends ConsumerStatefulWidget {
  const _AddPrincipalDialog({
    required this.view,
    required this.currentBookId,
    required this.books,
    required this.fundingAccounts,
    required this.ids,
  });

  final DebtDetailView view;
  final int currentBookId;
  final List<AccountBook> books;
  final List<Asset> fundingAccounts;
  final CommandIds ids;

  @override
  ConsumerState<_AddPrincipalDialog> createState() =>
      _AddPrincipalDialogState();
}

class _AddPrincipalDialogState extends ConsumerState<_AddPrincipalDialog> {
  final _amountCtrl = TextEditingController();
  final _remarkCtrl = TextEditingController();
  late int _selectedBookId;
  int _selectedFundingId = noRef;
  late DateTime _operateDate;
  bool _submitting = false;
  String? _dialogError;

  @override
  void initState() {
    super.initState();
    var bookId = widget.view.boundBookIds.contains(widget.currentBookId)
        ? widget.currentBookId
        : (widget.view.boundBookIds.isNotEmpty
              ? widget.view.boundBookIds.first
              : widget.currentBookId);
    if (widget.books.isNotEmpty && !widget.books.any((b) => b.id == bookId)) {
      bookId = widget.books.first.id;
    }
    _selectedBookId = bookId;
    final now = DateTime.now();
    _operateDate = DateTime(now.year, now.month, now.day);
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _remarkCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final debt = widget.view.debt;
    final isBorrow = debt.subType == AssetType.debtBorrow;
    final debtCurr = normalizeCurrency(debt.currency) ?? baseCurrency;

    return AlertDialog(
      title: Text(isBorrow ? '追加借入' : '追加借出'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('add_principal_input'),
              controller: _amountCtrl,
              enabled: !_submitting,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: debtAmountInputFormatters,
              decoration: InputDecoration(
                labelText: isBorrow
                    ? '追加借入本金 ($debtCurr)'
                    : '追加借出本金 ($debtCurr)',
              ),
            ),
            const SizedBox(height: 12),
            InputDecorator(
              decoration: const InputDecoration(labelText: '资金账户'),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  key: const Key('add_principal_funding_selector'),
                  value: _selectedFundingId,
                  isExpanded: true,
                  isDense: true,
                  items: [
                    const DropdownMenuItem<int>(
                      value: noRef,
                      child: Text('不关联资金账户'),
                    ),
                    for (final a in widget.fundingAccounts)
                      DropdownMenuItem<int>(value: a.id, child: Text(a.name)),
                  ],
                  onChanged: _submitting
                      ? null
                      : (v) => setState(() => _selectedFundingId = v ?? noRef),
                ),
              ),
            ),
            if (widget.books.length > 1) ...[
              const SizedBox(height: 12),
              InputDecorator(
                decoration: const InputDecoration(labelText: '记入账本'),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                    key: const Key('add_principal_book_selector'),
                    value: _selectedBookId,
                    isExpanded: true,
                    isDense: true,
                    items: [
                      for (final b in widget.books)
                        DropdownMenuItem<int>(value: b.id, child: Text(b.name)),
                    ],
                    onChanged: _submitting
                        ? null
                        : (v) {
                            if (v != null) {
                              setState(() => _selectedBookId = v);
                            }
                          },
                  ),
                ),
              ),
            ],
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('操作日期'),
              trailing: Text(formatDate(_operateDate)),
              onTap: _submitting
                  ? null
                  : () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: _operateDate,
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                      );
                      if (picked != null && mounted) {
                        setState(() {
                          _operateDate = DateTime(
                            picked.year,
                            picked.month,
                            picked.day,
                          );
                        });
                      }
                    },
            ),
            TextField(
              key: const Key('add_principal_remark_input'),
              controller: _remarkCtrl,
              enabled: !_submitting,
              decoration: const InputDecoration(labelText: '备注（可选）'),
            ),
            if (_dialogError != null) ...[
              const SizedBox(height: 8),
              Text(
                _dialogError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('confirm_add_principal_button'),
          onPressed: _submitting
              ? null
              : () async {
                  setState(() {
                    _submitting = true;
                    _dialogError = null;
                  });
                  try {
                    final amt = parseDebtAmount(
                      _amountCtrl.text,
                      currency: debtCurr,
                    );
                    final service = await ref.read(debtServiceProvider.future);
                    await service.addPrincipal(
                      commandId: widget.ids.forPayload([
                        'add-principal',
                        debt.id,
                        amt.toJson(),
                        _operateDate.millisecondsSinceEpoch,
                        _selectedBookId,
                        _selectedFundingId,
                        _remarkCtrl.text,
                        _uuid.v4(),
                      ]),
                      debtId: debt.id,
                      amount: amt,
                      operateDate: _operateDate.millisecondsSinceEpoch,
                      bookId: _selectedBookId,
                      fundingAssetId: _selectedFundingId,
                      remark: _remarkCtrl.text,
                    );
                    if (context.mounted) Navigator.pop(context);
                  } catch (e) {
                    if (mounted) {
                      setState(() {
                        _submitting = false;
                        _dialogError = safeMessage(e);
                      });
                    }
                  }
                },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _EditRecordDialog extends ConsumerStatefulWidget {
  const _EditRecordDialog({
    required this.view,
    required this.rec,
    required this.initialFundingId,
    required this.recordLabel,
    required this.fundingAccounts,
    required this.ids,
  });

  final DebtDetailView view;
  final LedgerRecord rec;
  final int initialFundingId;
  final String recordLabel;
  final List<Asset> fundingAccounts;
  final CommandIds ids;

  @override
  ConsumerState<_EditRecordDialog> createState() => _EditRecordDialogState();
}

class _EditRecordDialogState extends ConsumerState<_EditRecordDialog> {
  late final TextEditingController _amountCtrl;
  late final TextEditingController _remarkCtrl;
  late int _selectedFundingId;
  bool _submitting = false;
  String? _dialogError;

  @override
  void initState() {
    super.initState();
    final debtCurr =
        normalizeCurrency(widget.view.debt.currency) ?? baseCurrency;
    final currSnap = RecordExtra.parse(widget.rec.extraInfo).currency;
    final initialMinor =
        (currSnap != null &&
            currSnap.isValid &&
            normalizeCurrency(currSnap.sourceCode) == debtCurr)
        ? currSnap.sourceGross
        : widget.rec.moneyMinor;
    _amountCtrl = TextEditingController(text: formatMinor(initialMinor));
    _remarkCtrl = TextEditingController(text: widget.rec.remark);
    _selectedFundingId = widget.initialFundingId;
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _remarkCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final debtCurr =
        normalizeCurrency(widget.view.debt.currency) ?? baseCurrency;
    final hasInitialInActive =
        widget.initialFundingId == noRef ||
        widget.fundingAccounts.any((a) => a.id == widget.initialFundingId);

    return AlertDialog(
      title: Text('编辑${widget.recordLabel}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('edit_debt_record_amount_input'),
              controller: _amountCtrl,
              enabled: !_submitting,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: debtAmountInputFormatters,
              decoration: InputDecoration(labelText: '金额 ($debtCurr)'),
            ),
            const SizedBox(height: 12),
            InputDecorator(
              decoration: const InputDecoration(labelText: '资金账户'),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  key: const Key('edit_debt_record_funding_selector'),
                  value: _selectedFundingId,
                  isExpanded: true,
                  isDense: true,
                  items: [
                    const DropdownMenuItem<int>(
                      value: noRef,
                      child: Text('不关联资金账户'),
                    ),
                    if (!hasInitialInActive)
                      DropdownMenuItem<int>(
                        value: widget.initialFundingId,
                        child: Text(
                          widget.view.accountNames[widget.initialFundingId] ??
                              '账户#${widget.initialFundingId}',
                        ),
                      ),
                    for (final a in widget.fundingAccounts)
                      DropdownMenuItem<int>(value: a.id, child: Text(a.name)),
                  ],
                  onChanged: _submitting
                      ? null
                      : (v) => setState(() => _selectedFundingId = v ?? noRef),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('edit_debt_record_remark_input'),
              controller: _remarkCtrl,
              enabled: !_submitting,
              decoration: const InputDecoration(labelText: '备注'),
            ),
            if (_dialogError != null) ...[
              const SizedBox(height: 8),
              Text(
                _dialogError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('confirm_edit_debt_record_button'),
          onPressed: _submitting
              ? null
              : () async {
                  setState(() {
                    _submitting = true;
                    _dialogError = null;
                  });
                  try {
                    final amt = parseDebtAmount(
                      _amountCtrl.text,
                      currency: debtCurr,
                    );
                    final service = await ref.read(debtServiceProvider.future);
                    await service.updateDebtRecord(
                      commandId: widget.ids.forPayload([
                        'edit-rec',
                        widget.rec.recordId,
                        amt.toJson(),
                        _selectedFundingId,
                        _remarkCtrl.text,
                        _uuid.v4(),
                      ]),
                      recordId: widget.rec.recordId,
                      amount: amt,
                      fundingAssetId: _selectedFundingId,
                      remark: _remarkCtrl.text,
                    );
                    if (context.mounted) Navigator.pop(context);
                  } catch (e) {
                    if (mounted) {
                      setState(() {
                        _submitting = false;
                        _dialogError = safeMessage(e);
                      });
                    }
                  }
                },
          child: const Text('保存'),
        ),
      ],
    );
  }
}
