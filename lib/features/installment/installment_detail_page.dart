import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/money.dart';
import '../../data/db/database.dart';
import '../../data/repo/installment_queries.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/installment_rules.dart';
import '../common/common.dart';
import '../records/record_detail_page.dart';
import '../records/record_editor_page.dart'
    show amountInputFormatters, parseAmount;
import '../records/record_labels.dart' show assetName, categoryName;
import 'installment_editor_page.dart';
import 'installment_page.dart' show InstallmentIntProgressBar;
import 'installment_providers.dart';

/// Installment detail & repayment schedule page (F-010, original `/bkp/InstDtlAct`).
class InstallmentDetailPage extends ConsumerStatefulWidget {
  const InstallmentDetailPage({
    super.key,
    required this.installmentId,
    this.onRecordTap,
  });

  final int installmentId;
  final void Function(String recordId)? onRecordTap;

  @override
  ConsumerState<InstallmentDetailPage> createState() =>
      _InstallmentDetailPageState();
}

class _InstallmentDetailPageState extends ConsumerState<InstallmentDetailPage> {
  final _ids = CommandIds();
  bool _busy = false;
  int _actionNonce = 0;

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _postSinglePeriod(
    InstallmentSummaryView summary,
    InstallmentPeriodItem item, {
    required bool isRepost,
  }) async {
    final inst = summary.installment;
    final feeLine = item.feeMinor == BigInt.zero
        ? ''
        : '\n手续费：¥${formatMinor(item.feeMinor)}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          isRepost
              ? '补记第 ${item.period} 期账单？'
              : item.period == summary.progress.nextPeriod
              ? '确认本期入账？'
              : '提前入账第 ${item.period} 期？',
        ),
        content: Text(
          '分期：${inst.name}（第 ${item.period}/${inst.periods} 期）\n'
          '本金：¥${formatMinor(item.principalMinor)}'
          '$feeLine\n'
          '入账后将生成对应账单并更新账户余额。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('confirm_post_period_button'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认入账'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final nonce = ++_actionNonce;
    setState(() => _busy = true);
    try {
      final service = await ref.read(installmentServiceProvider.future);
      await service.postPeriod(
        commandId: _ids.forPayload(['post', inst.id, item.period, nonce]),
        installmentId: inst.id,
        period: item.period,
      );
      _showSnack('第 ${item.period} 期已入账');
    } catch (e) {
      _showSnack(safeMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _earlySettle(InstallmentSummaryView summary) async {
    final inst = summary.installment;
    final progress = summary.progress;
    final defaultFeeMinor = progress.remainingFeeMinor > BigInt.zero
        ? progress.remainingFeeMinor
        : BigInt.zero;

    final settlementFee = await showDialog<Money>(
      context: context,
      builder: (_) => _EarlySettleDialog(
        installmentName: inst.name,
        remainingPeriods: progress.remainingCount,
        remainingPrincipalMinor: progress.remainingPrincipalMinor,
        defaultFeeMinor: defaultFeeMinor,
      ),
    );
    if (settlementFee == null || !mounted) return;

    final nonce = ++_actionNonce;
    setState(() => _busy = true);
    try {
      final service = await ref.read(installmentServiceProvider.future);
      await service.settleEarly(
        commandId: _ids.forPayload([
          'settle-early',
          inst.id,
          settlementFee.toJson(),
          nonce,
        ]),
        installmentId: inst.id,
        settlementFee: settlementFee,
      );
      _showSnack('已完成提前结清');
    } catch (e) {
      _showSnack(safeMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteInstallment(InstallmentDetailView detail) async {
    final inst = detail.summary.installment;
    final hasRecords = detail.allRecords.isNotEmpty;

    final decision = await showDialog<({bool confirmed, bool deleteRecords})>(
      context: context,
      builder: (_) => _DeleteInstallmentDialog(
        installmentName: inst.name,
        liveRecordCount: detail.allRecords.length,
        hasRecords: hasRecords,
      ),
    );
    if (decision == null || !decision.confirmed || !mounted) return;

    final nonce = ++_actionNonce;
    setState(() => _busy = true);
    try {
      final service = await ref.read(installmentServiceProvider.future);
      await service.deleteInstallment(
        commandId: _ids.forPayload([
          'delete',
          inst.id,
          decision.deleteRecords,
          nonce,
        ]),
        installmentId: inst.id,
        deleteGeneratedRecords: decision.deleteRecords,
      );
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      _showSnack(safeMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _openRecord(String recordId) {
    if (widget.onRecordTap != null) {
      widget.onRecordTap!(recordId);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RecordDetailPage(recordId: recordId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final detailAsync = ref.watch(
      installmentDetailProvider(widget.installmentId),
    );
    final assets = ref.watch(assetsProvider).value ?? const <Asset>[];
    final books = ref.watch(booksProvider).value ?? const <AccountBook>[];
    final allTags = ref.watch(tagsProvider).value ?? const <Tag>[];

    final loaded = detailAsync.value;
    final bookId = loaded?.summary.installment.bookId ?? 1;
    final categories =
        ref.watch(categoriesProvider(bookId)).value ?? const <RecordCategory>[];

    return Scaffold(
      key: const Key('installment_detail_page'),
      appBar: AppBar(
        title: Text(loaded?.summary.installment.name ?? '分期详情'),
        actions: [
          if (loaded != null) ...[
            IconButton(
              key: const Key('edit_installment_button'),
              tooltip: '编辑分期',
              onPressed: _busy
                  ? null
                  : () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => InstallmentEditorPage(
                          installmentId: loaded.summary.installment.id,
                        ),
                      ),
                    ),
              icon: const Icon(Icons.edit_outlined),
            ),
            IconButton(
              key: const Key('delete_installment_button'),
              tooltip: '删除分期',
              onPressed: _busy ? null : () => _deleteInstallment(loaded),
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ],
      ),
      body: asyncBody(detailAsync, (detail) {
        if (detail == null) {
          return const Center(child: Text('分期计划不存在或已删除'));
        }
        final summary = detail.summary;
        final inst = summary.installment;
        final progress = summary.progress;
        final nextItem = !summary.isFinished
            ? summary.schedule[progress.nextPeriod - 1]
            : null;

        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                _DetailSummaryCard(
                  summary: summary,
                  assets: assets,
                  books: books,
                  categories: categories,
                  allTags: allTags,
                  busy: _busy,
                  onPostNext: nextItem == null
                      ? null
                      : () => _postSinglePeriod(
                          summary,
                          nextItem,
                          isRepost: false,
                        ),
                  onEarlySettle: summary.isFinished
                      ? null
                      : () => _earlySettle(summary),
                ),
                const SizedBox(height: 16),
                Text(
                  '分期还款计划（${inst.periods} 期）',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                for (final item in summary.schedule)
                  _PeriodScheduleCard(
                    item: item,
                    summary: summary,
                    records: detail.recordsForPeriod(item.period),
                    categories: categories,
                    busy: _busy,
                    onPost: () =>
                        _postSinglePeriod(summary, item, isRepost: false),
                    onRepost: () =>
                        _postSinglePeriod(summary, item, isRepost: true),
                    onRecordTap: _openRecord,
                  ),
              ],
            ),
          ),
        );
      }),
    );
  }
}

class _DetailSummaryCard extends StatelessWidget {
  const _DetailSummaryCard({
    required this.summary,
    required this.assets,
    required this.books,
    required this.categories,
    required this.allTags,
    required this.busy,
    required this.onPostNext,
    required this.onEarlySettle,
  });

  final InstallmentSummaryView summary;
  final List<Asset> assets;
  final List<AccountBook> books;
  final List<RecordCategory> categories;
  final List<Tag> allTags;
  final bool busy;
  final VoidCallback? onPostNext;
  final VoidCallback? onEarlySettle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inst = summary.installment;
    final progress = summary.progress;
    final extra = summary.extra;
    final accName = assetName(assets, inst.assetId);
    final catText = inst.catId == noRef
        ? '账单分期'
        : categoryName(categories, inst.catId);
    final bookName =
        books.where((b) => b.id == inst.bookId).firstOrNull?.name ?? '默认账本';
    final tagIds = parseInstallmentTags(inst.tags);
    final tagNames = [
      for (final id in tagIds)
        allTags.where((t) => t.tagId == id).firstOrNull?.name ?? id,
    ];

    return Card(
      key: const Key('installment_detail_summary_card'),
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    summary.isFinished ? '分期已完结' : '剩余待入账总额',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Text(
                  extra.settledEarly
                      ? '提前结清'
                      : '${progress.creditedCount}/${progress.periods} 期',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              summary.isFinished
                  ? '¥0.00'
                  : '¥${formatMinor(progress.remainingTotalMinor)}',
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 10),
            InstallmentIntProgressBar(
              creditedCount: progress.creditedCount,
              remainingCount: progress.remainingCount,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 6,
              children: [
                Text('总本金: ¥${formatMinor(inst.principalMinor)}'),
                Text('总手续费: ¥${formatMinor(inst.chargeMinor)}'),
                Text('剩余本金: ¥${formatMinor(progress.remainingPrincipalMinor)}'),
                Text('剩余手续费: ¥${formatMinor(progress.remainingFeeMinor)}'),
              ],
            ),
            const Divider(height: 20),
            Text(
              '扣款账户：$accName · 分类：$catText · 账本：$bookName',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              '规则：${InstallmentChargeWay.labelOf(inst.chargeWay)} · '
              '${InstallmentCalWay.labelOf(inst.calWay)} · '
              '余数${InstallmentRemainderIn.labelOf(inst.remainderIn)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (tagNames.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final name in tagNames)
                    Chip(
                      label: Text(name, style: theme.textTheme.labelSmall),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ],
            if (extra.settledEarly) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Container(
                      key: const Key('early_settled_banner'),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.tertiaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '已于第 ${extra.settledPeriod ?? '-'} 期提前结清：'
                        '结清本金 ¥${formatMinor(extra.settledPrincipalMinor ?? BigInt.zero)}，'
                        '实收结清手续费 ¥${formatMinor(extra.settledFeeMinor ?? BigInt.zero)}'
                        '${(extra.waivedFeeMinor ?? BigInt.zero) > BigInt.zero ? '（已免除手续费 ¥${formatMinor(extra.waivedFeeMinor!)}）' : ''}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onTertiaryContainer,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (!summary.isFinished) ...[
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      key: const Key('post_next_period_button'),
                      onPressed: busy ? null : onPostNext,
                      icon: const Icon(Icons.playlist_add_check, size: 18),
                      label: Text('本期入账（第${progress.nextPeriod}期）'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('early_settle_button'),
                      onPressed: busy ? null : onEarlySettle,
                      icon: const Icon(Icons.done_all, size: 18),
                      label: const Text('提前结清'),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PeriodScheduleCard extends StatelessWidget {
  const _PeriodScheduleCard({
    required this.item,
    required this.summary,
    required this.records,
    required this.categories,
    required this.busy,
    required this.onPost,
    required this.onRepost,
    required this.onRecordTap,
  });

  final InstallmentPeriodItem item;
  final InstallmentSummaryView summary;
  final List<LedgerRecord> records;
  final List<RecordCategory> categories;
  final bool busy;
  final VoidCallback onPost;
  final VoidCallback onRepost;
  final void Function(String recordId) onRecordTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inst = summary.installment;
    final extra = summary.extra;
    final isMergedEarly =
        item.isCredited &&
        records.isEmpty &&
        extra.settledEarly &&
        extra.settledPeriod != null &&
        item.period != extra.settledPeriod;

    return Card(
      key: Key('period_item_${item.period}'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '第 ${item.period}/${inst.periods} 期 · '
                    '${formatDate(DateTime.fromMillisecondsSinceEpoch(item.plannedDateMs))}',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: item.isCredited
                        ? theme.colorScheme.secondaryContainer
                        : theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    item.isCredited ? '已入账' : '待入账',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: item.isCredited
                          ? theme.colorScheme.onSecondaryContainer
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    item.feeMinor == BigInt.zero
                        ? '计划本金 ¥${formatMinor(item.principalMinor)}'
                        : '计划本金 ¥${formatMinor(item.principalMinor)} + 手续费 ¥${formatMinor(item.feeMinor)}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                Text(
                  '¥${formatMinor(item.totalMinor)}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            if (!item.isCredited) ...[
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  key: Key('post_period_${item.period}'),
                  onPressed: busy ? null : onPost,
                  icon: const Icon(Icons.check_circle_outline, size: 16),
                  label: Text(
                    item.period == summary.progress.nextPeriod
                        ? '本期入账'
                        : '提前入账',
                  ),
                ),
              ),
            ] else if (records.isNotEmpty) ...[
              const Divider(height: 16),
              for (final r in records)
                ListTile(
                  key: Key('posted_record_${r.recordId}'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    r.type == RecordType.fee
                        ? Icons.percent
                        : Icons.receipt_long_outlined,
                    size: 18,
                  ),
                  title: Text(
                    r.type == RecordType.fee
                        ? '分期手续费'
                        : r.recordCatId == noRef
                        ? '分期还款本金'
                        : categoryName(categories, r.recordCatId),
                  ),
                  subtitle: Text(
                    r.remark.isEmpty
                        ? formatDateTime(
                            DateTime.fromMillisecondsSinceEpoch(r.recordTime),
                          )
                        : '${r.remark} · ${formatDate(DateTime.fromMillisecondsSinceEpoch(r.recordTime))}',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        r.moneyMinor.isNegative
                            ? '+¥${formatMinor(-r.moneyMinor)}'
                            : '-¥${formatMinor(r.moneyMinor)}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Icon(Icons.chevron_right, size: 18),
                    ],
                  ),
                  onTap: () => onRecordTap(r.recordId),
                ),
            ] else if (isMergedEarly) ...[
              const SizedBox(height: 6),
              Text(
                '已随第 ${extra.settledPeriod} 期合并提前结清',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ] else ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '关联账单已被手动删除',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                  TextButton(
                    key: Key('repost_period_${item.period}'),
                    onPressed: busy ? null : onRepost,
                    child: const Text('重新补记'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _EarlySettleDialog extends StatefulWidget {
  const _EarlySettleDialog({
    required this.installmentName,
    required this.remainingPeriods,
    required this.remainingPrincipalMinor,
    required this.defaultFeeMinor,
  });

  final String installmentName;
  final int remainingPeriods;
  final BigInt remainingPrincipalMinor;
  final BigInt defaultFeeMinor;

  @override
  State<_EarlySettleDialog> createState() => _EarlySettleDialogState();
}

class _EarlySettleDialogState extends State<_EarlySettleDialog> {
  late final TextEditingController _feeCtrl;
  bool _waiveFee = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _feeCtrl = TextEditingController(text: formatMinor(widget.defaultFeeMinor));
  }

  @override
  void dispose() {
    _feeCtrl.dispose();
    super.dispose();
  }

  void _confirm() {
    try {
      final fee = _waiveFee ? Money.zero() : parseAmount(_feeCtrl.text);
      if (fee.storageMinor < BigInt.zero) {
        setState(() => _error = '结清手续费不能为负数');
        return;
      }
      Navigator.of(context).pop(fee);
    } catch (e) {
      setState(() => _error = safeMessage(e));
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('提前结清分期'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '分期：${widget.installmentName}\n'
            '剩余未入账期数：${widget.remainingPeriods} 期\n'
            '一次性结清剩余本金：¥${formatMinor(widget.remainingPrincipalMinor)}',
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            key: const Key('waive_fee_switch'),
            contentPadding: EdgeInsets.zero,
            title: const Text('免除剩余手续费'),
            value: _waiveFee,
            onChanged: (v) => setState(() {
              _waiveFee = v;
              _error = null;
              _feeCtrl.text = v ? '0.00' : formatMinor(widget.defaultFeeMinor);
            }),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('settlement_fee_input'),
            controller: _feeCtrl,
            enabled: !_waiveFee,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: amountInputFormatters,
            decoration: InputDecoration(
              labelText: '结清实收手续费',
              prefixText: '¥ ',
              errorText: _error,
              border: const OutlineInputBorder(),
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const Key('confirm_early_settle_button'),
        onPressed: _confirm,
        child: const Text('确认结清'),
      ),
    ],
  );
}

class _DeleteInstallmentDialog extends StatefulWidget {
  const _DeleteInstallmentDialog({
    required this.installmentName,
    required this.liveRecordCount,
    required this.hasRecords,
  });

  final String installmentName;
  final int liveRecordCount;
  final bool hasRecords;

  @override
  State<_DeleteInstallmentDialog> createState() =>
      _DeleteInstallmentDialogState();
}

class _DeleteInstallmentDialogState extends State<_DeleteInstallmentDialog> {
  bool _deleteRecords = false;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('删除分期计划？'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('确定删除“${widget.installmentName}”？信用卡未入账分期负债将同步移除。'),
        if (widget.hasRecords) ...[
          const SizedBox(height: 12),
          CheckboxListTile(
            key: const Key('delete_records_checkbox'),
            contentPadding: EdgeInsets.zero,
            value: _deleteRecords,
            onChanged: (v) => setState(() => _deleteRecords = v ?? false),
            title: Text('同时删除已生成的关联账单（共 ${widget.liveRecordCount} 笔）并恢复账户余额'),
          ),
        ],
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const Key('confirm_delete_installment_button'),
        onPressed: () => Navigator.of(
          context,
        ).pop((confirmed: true, deleteRecords: _deleteRecords)),
        child: const Text('删除'),
      ),
    ],
  );
}
