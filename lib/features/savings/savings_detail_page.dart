import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/failure.dart';
import '../../core/money.dart';
import '../../data/db/database.dart';
import '../../domain/rules/savings_plan.dart';
import '../common/common.dart';
import 'savings_editor_page.dart';
import 'savings_page.dart' show SavingsProgressBar;
import 'savings_providers.dart';

const _uuid = Uuid();

/// Detail page for a Savings Plan (F-012, original route R-028 `/bkp/MSPDAct`).
class SavingsDetailPage extends ConsumerStatefulWidget {
  const SavingsDetailPage({required this.planId, super.key});

  final int planId;

  @override
  ConsumerState<SavingsDetailPage> createState() => _SavingsDetailPageState();
}

class _SavingsDetailPageState extends ConsumerState<SavingsDetailPage> {
  bool _healedOnce = false;

  @override
  void initState() {
    super.initState();
    unawaited(_healSavedMoney());
  }

  Future<void> _healSavedMoney() async {
    if (_healedOnce) return;
    _healedOnce = true;
    try {
      final service = await ref.read(savingsServiceProvider.future);
      await service.healSavedMoney(widget.planId);
    } catch (_) {
      // Non-blocking self-healing on entry.
    }
  }

  Future<void> _openEdit(int planId) async {
    await Navigator.of(context).push<int>(
      MaterialPageRoute(builder: (_) => SavingsEditorPage(planId: planId)),
    );
  }

  Future<void> _toggleArchive(MoneySavePlan plan) async {
    final targetArchived = plan.status != SavingsPlanStatus.archived;
    final ok = await confirm(
      context,
      title: targetArchived ? '归档存钱计划' : '恢复存钱计划',
      message: targetArchived
          ? '归档后计划移至“已归档”列表并关闭自动存钱，确认归档吗？'
          : '确认将该计划恢复为“进行中”状态吗？',
    );
    if (!ok || !mounted) return;
    try {
      final service = await ref.read(savingsServiceProvider.future);
      await service.setPlanArchived(
        commandId: _uuid.v4(),
        planId: plan.id,
        archived: targetArchived,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

  Future<void> _confirmDeletePlan(SavingsPlanDetailView detail) async {
    var deleteLinkedTransfers = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('删除存钱计划'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('确认删除“${detail.plan.name}”吗？此操作不可撤销。'),
              if (detail.hasAnyLinkedTransfer) ...[
                const SizedBox(height: 12),
                CheckboxListTile(
                  key: const Key('delete_linked_transfers_checkbox'),
                  contentPadding: EdgeInsets.zero,
                  value: deleteLinkedTransfers,
                  onChanged: (val) => setDialogState(
                    () => deleteLinkedTransfers = val ?? false,
                  ),
                  title: const Text('同时删除关联转账流水并回滚账户余额'),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('confirm_delete_plan_button'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('删除'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true || !mounted) return;
    try {
      final service = await ref.read(savingsServiceProvider.future);
      await service.deletePlan(
        commandId: _uuid.v4(),
        planId: detail.plan.id,
        deleteLinkedTransfers: deleteLinkedTransfers,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

  Future<void> _showSlotCheckInDialog(
    SavingsPlanDetailView detail,
    SavingsScheduleSlot slot,
  ) async {
    await showDialog<bool>(
      context: context,
      builder: (_) => _SlotCheckInDialog(detail: detail, slot: slot),
    );
  }

  Future<void> _showFreePlanCheckInDialog(SavingsPlanDetailView detail) async {
    await showDialog<bool>(
      context: context,
      builder: (_) => _FreePlanCheckInDialog(detail: detail),
    );
  }

  Future<void> _confirmCancelDeposit(MoneySavePlanRecord record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('取消存入'),
        content: const Text('取消后将扣减已存金额；若关联了未删除的转账流水，将同步删除并回滚账户余额。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('返回'),
          ),
          FilledButton(
            key: const Key('confirm_cancel_deposit_button'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('确认取消'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final service = await ref.read(savingsServiceProvider.future);
      await service.cancelDeposit(
        commandId: _uuid.v4(),
        planRecordId: record.id,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final detailAsync = ref.watch(savingsDetailViewProvider(widget.planId));

    return detailAsync.when(
      loading: () => const Scaffold(body: Loading()),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: const Text('存钱详情')),
        body: ErrorView(e),
      ),
      data: (detail) {
        if (detail == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('存钱详情')),
            body: const Center(child: Text('存钱计划已删除')),
          );
        }
        final plan = detail.plan;
        final isArchived = plan.status == SavingsPlanStatus.archived;
        final today = LocalCalendarDate.fromDateTime(DateTime.now());
        final tip = formatConductTip(
          startDateMs: plan.startDate,
          endDateMs: plan.endDate,
          status: plan.status,
          today: today,
        );
        final permille = clampedProgressPermille(
          plan.savedMoneyMinor,
          plan.planMoneyMinor,
        );
        final percentText = formatProgressPercent(
          plan.savedMoneyMinor,
          plan.planMoneyMinor,
        );

        return Scaffold(
          key: const Key('savings_detail_page'),
          appBar: AppBar(
            title: Text(plan.name),
            actions: [
              IconButton(
                key: const Key('edit_savings_plan_button'),
                tooltip: '编辑计划',
                onPressed: () => _openEdit(plan.id),
                icon: const Icon(Icons.edit_outlined),
              ),
              IconButton(
                key: const Key('toggle_archive_plan_button'),
                tooltip: isArchived ? '恢复进行中' : '归档计划',
                onPressed: () => _toggleArchive(plan),
                icon: Icon(
                  isArchived
                      ? Icons.unarchive_outlined
                      : Icons.archive_outlined,
                ),
              ),
              IconButton(
                key: const Key('delete_savings_plan_button'),
                tooltip: '删除计划',
                onPressed: () => _confirmDeletePlan(detail),
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
            children: [
              _DetailHeaderCard(
                detail: detail,
                tip: tip,
                permille: permille,
                percentText: percentText,
              ),
              const SizedBox(height: 16),
              if (plan.planType == SavingsPlanType.free) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '存入记录',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    FilledButton.tonalIcon(
                      key: const Key('free_plan_checkin_button'),
                      onPressed: () => _showFreePlanCheckInDialog(detail),
                      icon: const Icon(Icons.savings_outlined, size: 18),
                      label: const Text('打卡存钱'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (detail.schedule.freePlanRows.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: Center(child: Text('暂无存入记录，点击“打卡存钱”记录第一笔吧')),
                  )
                else
                  for (final row in detail.schedule.freePlanRows)
                    _FreeRecordTile(
                      row: row,
                      symbol: detail.currencySymbol,
                      hasLiveTransfer:
                          row.record.recordId != null &&
                          detail.liveTransferIds.contains(row.record.recordId),
                      onCancel: () => _confirmCancelDeposit(row.record),
                    ),
              ] else ...[
                Text(
                  '存钱排期（共 ${detail.schedule.slots.length} 期）',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                for (final merged in detail.schedule.slots)
                  _ScheduleSlotTile(
                    merged: merged,
                    symbol: detail.currencySymbol,
                    onCheckIn: () =>
                        _showSlotCheckInDialog(detail, merged.slot),
                    onCancel: merged.matchedRecord == null
                        ? null
                        : () => _confirmCancelDeposit(merged.matchedRecord!),
                  ),
                if (detail.schedule.outOfScheduleRecords.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  Card(
                    key: const Key('out_of_schedule_section'),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '排期外历史存入记录（${detail.schedule.outOfScheduleRecords.length} 笔）',
                            style: Theme.of(context).textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '修改起止日期或周期前的历史已存记录，仍计入已存总额，可随时取消存入。',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const Divider(),
                          for (final rec
                              in detail.schedule.outOfScheduleRecords)
                            ListTile(
                              key: Key('out_of_schedule_record_${rec.id}'),
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                '${detail.currencySymbol}${formatMinor(rec.recordMoneyMinor)}',
                              ),
                              subtitle: Text(
                                '${formatDate(DateTime.fromMillisecondsSinceEpoch(rec.recordDate))}'
                                '${rec.remark.isEmpty ? '' : ' · ${rec.remark}'}',
                              ),
                              trailing: TextButton(
                                key: Key('cancel_out_of_schedule_${rec.id}'),
                                onPressed: () => _confirmCancelDeposit(rec),
                                child: const Text('取消存入'),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ],
          ),
        );
      },
    );
  }
}

class _SlotCheckInDialog extends ConsumerStatefulWidget {
  const _SlotCheckInDialog({required this.detail, required this.slot});

  final SavingsPlanDetailView detail;
  final SavingsScheduleSlot slot;

  @override
  ConsumerState<_SlotCheckInDialog> createState() => _SlotCheckInDialogState();
}

class _SlotCheckInDialogState extends ConsumerState<_SlotCheckInDialog> {
  late final TextEditingController _amountCtrl;
  final _remarkCtrl = TextEditingController();
  String? _error;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _amountCtrl = TextEditingController(
      text: formatMinor(widget.slot.plannedMoneyMinor),
    );
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _remarkCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final parsed = Money.parse(
        _amountCtrl.text.trim(),
        rounding: RoundingMode.halfUp,
      );
      if (parsed.units <= BigInt.zero) {
        throw const Failure(FailureCode.validation, '存入金额须大于 0');
      }
      final service = await ref.read(savingsServiceProvider.future);
      final recordTimeMs = widget.slot.date.withWallClockMs(
        DateTime.now().millisecondsSinceEpoch,
      );
      await service.checkIn(
        commandId: _uuid.v4(),
        planId: widget.detail.plan.id,
        amountMinor: parsed.storageMinor,
        recordDateMs: recordTimeMs,
        remark: _remarkCtrl.text.trim(),
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = safeMessage(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('checkin_slot_dialog'),
      title: Text(
        '第 ${widget.slot.periodNumber} 期打卡（${widget.slot.date.dateKey}）',
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_error != null) ...[
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 8),
          ],
          TextField(
            key: const Key('slot_checkin_amount_input'),
            controller: _amountCtrl,
            enabled: !_submitting,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: '存入金额',
              prefixText: '${widget.detail.currencySymbol} ',
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('slot_checkin_remark_input'),
            controller: _remarkCtrl,
            enabled: !_submitting,
            decoration: const InputDecoration(
              labelText: '备注（可选）',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _submitting
              ? null
              : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('confirm_slot_checkin_button'),
          onPressed: _submitting ? null : _submit,
          child: const Text('确认存入'),
        ),
      ],
    );
  }
}

class _FreePlanCheckInDialog extends ConsumerStatefulWidget {
  const _FreePlanCheckInDialog({required this.detail});

  final SavingsPlanDetailView detail;

  @override
  ConsumerState<_FreePlanCheckInDialog> createState() =>
      _FreePlanCheckInDialogState();
}

class _FreePlanCheckInDialogState
    extends ConsumerState<_FreePlanCheckInDialog> {
  final _directCtrl = TextEditingController();
  final _cumulativeCtrl = TextEditingController();
  final _remarkCtrl = TextEditingController();
  bool _cumulativeMode = false;
  String? _error;
  bool _submitting = false;

  @override
  void dispose() {
    _directCtrl.dispose();
    _cumulativeCtrl.dispose();
    _remarkCtrl.dispose();
    super.dispose();
  }

  BigInt? _previewDelta() {
    if (!_cumulativeMode) return null;
    final text = _cumulativeCtrl.text.trim();
    if (text.isEmpty) return null;
    try {
      final target = Money.parse(
        text,
        rounding: RoundingMode.halfUp,
      ).storageMinor;
      return computeFreePlanDeltaMinor(
        currentSavedMinor: widget.detail.plan.savedMoneyMinor,
        targetCumulativeMinor: target,
      );
    } on Failure {
      return null;
    }
  }

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final service = await ref.read(savingsServiceProvider.future);
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (_cumulativeMode) {
        final target = Money.parse(
          _cumulativeCtrl.text.trim(),
          rounding: RoundingMode.halfUp,
        ).storageMinor;
        await service.checkIn(
          commandId: _uuid.v4(),
          planId: widget.detail.plan.id,
          targetCumulativeMinor: target,
          recordDateMs: nowMs,
          remark: _remarkCtrl.text.trim(),
        );
      } else {
        final direct = Money.parse(
          _directCtrl.text.trim(),
          rounding: RoundingMode.halfUp,
        ).storageMinor;
        await service.checkIn(
          commandId: _uuid.v4(),
          planId: widget.detail.plan.id,
          amountMinor: direct,
          recordDateMs: nowMs,
          remark: _remarkCtrl.text.trim(),
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = safeMessage(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final delta = _previewDelta();
    final symbol = widget.detail.currencySymbol;
    return AlertDialog(
      key: const Key('free_checkin_dialog'),
      title: const Text('打卡存钱'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_error != null) ...[
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: 8),
            ],
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  key: const Key('free_mode_direct'),
                  label: const Text('按本次金额'),
                  selected: !_cumulativeMode,
                  onSelected: _submitting
                      ? null
                      : (_) => setState(() {
                          _cumulativeMode = false;
                          _error = null;
                        }),
                ),
                ChoiceChip(
                  key: const Key('free_mode_cumulative'),
                  label: const Text('按累计目标额'),
                  selected: _cumulativeMode,
                  onSelected: _submitting
                      ? null
                      : (_) => setState(() {
                          _cumulativeMode = true;
                          _error = null;
                        }),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (!_cumulativeMode)
              TextField(
                key: const Key('free_amount_input'),
                controller: _directCtrl,
                enabled: !_submitting,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: '本次存入金额',
                  prefixText: '$symbol ',
                  border: const OutlineInputBorder(),
                ),
              )
            else ...[
              Text(
                '当前已存：$symbol${formatMinor(widget.detail.plan.savedMoneyMinor)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('free_cumulative_input'),
                controller: _cumulativeCtrl,
                enabled: !_submitting,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: '目标累计已存金额',
                  prefixText: '$symbol ',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                delta == null
                    ? '请输入大于当前已存的目标累计金额'
                    : '本次反算存入：$symbol${formatMinor(delta)}',
                key: const Key('free_backcalc_preview'),
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              key: const Key('free_remark_input'),
              controller: _remarkCtrl,
              enabled: !_submitting,
              decoration: const InputDecoration(
                labelText: '备注（可选）',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting
              ? null
              : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('confirm_free_checkin_button'),
          onPressed: _submitting ? null : _submit,
          child: const Text('确认存入'),
        ),
      ],
    );
  }
}

class _DetailHeaderCard extends StatelessWidget {
  const _DetailHeaderCard({
    required this.detail,
    required this.tip,
    required this.permille,
    required this.percentText,
  });

  final SavingsPlanDetailView detail;
  final String tip;
  final int permille;
  final String percentText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final plan = detail.plan;
    final symbol = detail.currencySymbol;
    final isArchived = plan.status == SavingsPlanStatus.archived;

    return Card(
      key: const Key('savings_detail_header'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  key: const Key('savings_detail_status_badge'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: isArchived
                        ? theme.colorScheme.secondaryContainer
                        : theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    isArchived ? '已归档' : '进行中',
                    style: theme.textTheme.labelSmall,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    tip,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '$symbol${formatMinor(plan.savedMoneyMinor)}',
              key: const Key('savings_detail_saved_text'),
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '目标金额 $symbol${formatMinor(plan.planMoneyMinor)} · 进度 $percentText',
              key: const Key('savings_detail_target_text'),
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            SavingsProgressBar(
              barKey: const Key('savings_detail_progress_bar'),
              permille: permille,
            ),
            if (detail.fromAsset != null || detail.toAsset != null) ...[
              const SizedBox(height: 12),
              Text(
                '账户联动：${detail.fromAsset?.name ?? '未绑定'} → ${detail.toAsset?.name ?? '未绑定'}',
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (plan.remark.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('备注：${plan.remark}', style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}

class _ScheduleSlotTile extends StatelessWidget {
  const _ScheduleSlotTile({
    required this.merged,
    required this.symbol,
    required this.onCheckIn,
    required this.onCancel,
  });

  final MergedSavingsSlot<MoneySavePlanRecord> merged;
  final String symbol;
  final VoidCallback onCheckIn;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final slot = merged.slot;
    final rec = merged.matchedRecord;
    final displayMinor = rec?.recordMoneyMinor ?? slot.plannedMoneyMinor;

    return Card(
      key: Key('savings_slot_${slot.slotIndex}'),
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          radius: 16,
          backgroundColor: merged.isSaved
              ? Theme.of(context).colorScheme.primaryContainer
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Icon(
            merged.isSaved ? Icons.check : Icons.schedule,
            size: 16,
            color: merged.isSaved
                ? Theme.of(context).colorScheme.onPrimaryContainer
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        title: Text(
          '第${slot.periodNumber}期 · $symbol${formatMinor(displayMinor)}',
        ),
        subtitle: Text(
          '${slot.date.dateKey} · 累计 $symbol${formatMinor(slot.plannedCumulativeMinor)}'
          '${rec != null && rec.remark.isNotEmpty ? ' · ${rec.remark}' : ''}',
        ),
        trailing: merged.isSaved
            ? TextButton(
                key: Key('cancel_slot_deposit_${slot.slotIndex}'),
                onPressed: onCancel,
                child: const Text('取消存入'),
              )
            : FilledButton.tonal(
                key: Key('checkin_slot_button_${slot.slotIndex}'),
                onPressed: onCheckIn,
                child: const Text('打卡'),
              ),
      ),
    );
  }
}

class _FreeRecordTile extends StatelessWidget {
  const _FreeRecordTile({
    required this.row,
    required this.symbol,
    required this.hasLiveTransfer,
    required this.onCancel,
  });

  final FreePlanRecordRow<MoneySavePlanRecord> row;
  final String symbol;
  final bool hasLiveTransfer;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final rec = row.record;
    return Card(
      key: Key('free_record_${rec.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text('+$symbol${formatMinor(rec.recordMoneyMinor)}'),
        subtitle: Text(
          '${formatDate(DateTime.fromMillisecondsSinceEpoch(rec.recordDate))} · '
          '累计 $symbol${formatMinor(row.runningCumulativeMinor)}'
          '${hasLiveTransfer ? ' · 已生成转账' : ''}'
          '${rec.remark.isEmpty ? '' : ' · ${rec.remark}'}',
        ),
        trailing: TextButton(
          key: Key('cancel_free_record_${rec.id}'),
          onPressed: onCancel,
          child: const Text('取消存入'),
        ),
      ),
    );
  }
}
