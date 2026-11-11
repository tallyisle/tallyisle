import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../data/periodic/periodic_service.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/periodic_records.dart';
import '../common/common.dart';
import '../records/record_labels.dart';
import 'periodic_editor_page.dart';
import 'periodic_providers.dart';

const _uuid = Uuid();

/// Management page for periodic bookkeeping rules across 3 state tabs (F-009, R-042).
class PeriodicPage extends ConsumerStatefulWidget {
  const PeriodicPage({super.key, this.onRecordTap});

  final void Function(String recordId)? onRecordTap;

  @override
  ConsumerState<PeriodicPage> createState() => _PeriodicPageState();
}

class _PeriodicPageState extends ConsumerState<PeriodicPage>
    with WidgetsBindingObserver {
  final _commandIds = CommandIds();
  CatchUpResult? _lastCatchUp;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _triggerCatchUp(force: true);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _triggerCatchUp(force: false);
    }
  }

  Future<void> _triggerCatchUp({
    required bool force,
    bool notify = false,
  }) async {
    try {
      final service = await ref.read(periodicServiceProvider.future);
      final result = await service.runCatchUp(force: force);
      if (!mounted) return;
      if (!result.throttled) {
        setState(() => _lastCatchUp = result);
      }
      if (notify && mounted) {
        final message = result.generatedCount > 0
            ? '已自动补记 ${result.generatedCount} 笔到期周期账单'
            : (result.skippedCount > 0
                  ? '有 ${result.skippedCount} 条到期规则因账户或汇率不可用已跳过'
                  : '暂无需要补记的到期账单');
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (e) {
      if (notify && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('补记失败: ${safeMessage(e)}')));
      }
    }
  }

  Future<void> _openEditor({int? periodId}) async {
    final savedId = await Navigator.of(context).push<int>(
      MaterialPageRoute<int>(
        builder: (_) => PeriodicEditorPage(periodId: periodId),
      ),
    );
    if (savedId != null && mounted) {
      await _triggerCatchUp(force: true);
    }
  }

  void _openHistory(int periodId) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PeriodicHistoryPage(
          periodId: periodId,
          onRecordTap: widget.onRecordTap,
        ),
      ),
    );
  }

  Future<void> _handleRuleAction(String action, RecordPeriod rule) async {
    switch (action) {
      case 'history':
        _openHistory(rule.id);
      case 'edit':
        await _openEditor(periodId: rule.id);
      case 'pause':
        try {
          final service = await ref.read(periodicServiceProvider.future);
          await service.pausePeriod(
            commandId: _commandIds.forPayload(['pause', rule.id, _uuid.v4()]),
            periodId: rule.id,
          );
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
          }
        }
      case 'resume':
        try {
          final service = await ref.read(periodicServiceProvider.future);
          await service.resumePeriod(
            commandId: _commandIds.forPayload(['resume', rule.id, _uuid.v4()]),
            periodId: rule.id,
          );
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
          }
        }
      case 'delete':
        final confirmed = await confirm(
          context,
          title: '删除周期记账',
          message: '确认删除该周期记账规则？已生成的历史账单和账户余额将完整保留。',
          ok: '删除',
        );
        if (!confirmed || !mounted) return;
        try {
          final service = await ref.read(periodicServiceProvider.future);
          await service.deletePeriod(
            commandId: _commandIds.forPayload(['delete', rule.id, _uuid.v4()]),
            periodId: rule.id,
          );
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
          }
        }
    }
  }

  String? _accountIssue(RecordPeriod rule, List<Asset> assets) {
    Asset? findAsset(int id) => assets.where((a) => a.id == id).firstOrNull;

    if (rule.recordType == RecordType.transfer) {
      final from = findAsset(rule.assetId);
      final to = findAsset(rule.assetId2);
      if (from == null || to == null) return '关联账户已删除，暂停补记';
      if (from.status != AssetStatus.active ||
          to.status != AssetStatus.active) {
        return '关联账户已隐藏或归档，暂停补记';
      }
      return null;
    }
    if (rule.assetId != noRef) {
      final a = findAsset(rule.assetId);
      if (a == null) return '关联账户已删除，暂停补记';
      if (a.status != AssetStatus.active) return '关联账户已隐藏或归档，暂停补记';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final selectedTab = ref.watch(periodicTabProvider);
    final countsAsync = ref.watch(periodicStateCountsProvider);
    final rulesAsync = ref.watch(periodicRulesByStateProvider(selectedTab));
    final allCategories =
        ref.watch(periodicAllCategoriesProvider).value ??
        const <RecordCategory>[];
    final allAssets = ref.watch(assetsProvider).value ?? const <Asset>[];
    final books = ref.watch(booksProvider).value ?? const <AccountBook>[];

    final counts = countsAsync.value;
    final skippedCount = _lastCatchUp?.skippedCount ?? 0;

    return Scaffold(
      key: const Key('periodic_page'),
      appBar: AppBar(
        title: const Text('周期记账'),
        actions: [
          IconButton(
            key: const Key('periodic_catchup_button'),
            tooltip: '立即检查补记',
            icon: const Icon(Icons.sync),
            onPressed: () => _triggerCatchUp(force: true, notify: true),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        key: const Key('add_periodic_button'),
        tooltip: '新建周期记账',
        onPressed: () => _openEditor(),
        child: const Icon(Icons.add),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: SegmentedButton<int>(
              key: const Key('periodic_state_tabs'),
              segments: [
                ButtonSegment<int>(
                  value: PeriodState.active,
                  label: Text(
                    counts == null ? '进行中' : '进行中 (${counts.active})',
                    key: const Key('periodic_tab_0'),
                  ),
                ),
                ButtonSegment<int>(
                  value: PeriodState.ended,
                  label: Text(
                    counts == null ? '已结束' : '已结束 (${counts.ended})',
                    key: const Key('periodic_tab_1'),
                  ),
                ),
                ButtonSegment<int>(
                  value: PeriodState.paused,
                  label: Text(
                    counts == null ? '已停用' : '已停用 (${counts.paused})',
                    key: const Key('periodic_tab_2'),
                  ),
                ),
              ],
              selected: {selectedTab},
              onSelectionChanged: (selection) {
                ref.read(periodicTabProvider.notifier).select(selection.first);
              },
            ),
          ),
          if (skippedCount > 0)
            Container(
              key: const Key('periodic_skipped_banner'),
              width: double.infinity,
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.amber.withAlpha(40),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.amber),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.warning_amber_rounded,
                    color: Colors.orange,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '有 $skippedCount 条到期周期规则因关联账户不可用或外币汇率缺失已跳过自动入账。',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: rulesAsync.when(
              loading: () => const Loading(),
              error: (e, _) => ErrorView(e),
              data: (rules) {
                if (rules.isEmpty) {
                  final emptyText = switch (selectedTab) {
                    PeriodState.active => '暂无进行中的周期记账',
                    PeriodState.ended => '暂无已结束的周期记账',
                    PeriodState.paused => '暂无已停用的周期记账',
                    _ => '暂无周期记账',
                  };
                  return RefreshIndicator(
                    onRefresh: () => _triggerCatchUp(force: true),
                    child: ListView(
                      children: [
                        const SizedBox(height: 120),
                        Center(
                          child: Text(
                            emptyText,
                            style: const TextStyle(color: Colors.grey),
                          ),
                        ),
                      ],
                    ),
                  );
                }

                return RefreshIndicator(
                  onRefresh: () => _triggerCatchUp(force: true),
                  child: ListView.builder(
                    padding: const EdgeInsets.only(top: 4, bottom: 88),
                    itemCount: rules.length,
                    itemBuilder: (context, index) {
                      final rule = rules[index];
                      return _buildRuleCard(
                        context,
                        rule: rule,
                        categories: allCategories,
                        assets: allAssets,
                        books: books,
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRuleCard(
    BuildContext context, {
    required RecordPeriod rule,
    required List<RecordCategory> categories,
    required List<Asset> assets,
    required List<AccountBook> books,
  }) {
    final String title;
    final String accountSummary;
    final String amountText;
    final Color? amountColor;

    if (rule.recordType == RecordType.transfer) {
      title = '转账';
      accountSummary =
          '${assetName(assets, rule.assetId)} → ${assetName(assets, rule.assetId2)}';
      amountText = '¥${formatMinor(rule.moneyMinor)}';
      amountColor = null;
    } else if (rule.recordType == RecordType.income) {
      title = categoryName(categories, rule.catId);
      accountSummary = assetName(assets, rule.assetId);
      amountText = '+¥${formatMinor(rule.moneyMinor)}';
      amountColor = Colors.green[700];
    } else {
      title = categoryName(categories, rule.catId);
      accountSummary = assetName(assets, rule.assetId);
      amountText = '-¥${formatMinor(rule.moneyMinor)}';
      amountColor = Colors.red[700];
    }

    final cycleText = formatPeriodCycleSummary(
      periodType: rule.periodType,
      periodTypeDateJson: rule.periodTypeDate,
      frequency: rule.frequency,
    );
    final endText = formatPeriodEndSummary(rule.periodEndDate);
    final spec = scheduleSpecOf(rule);
    final nextDue = rule.state == PeriodState.active
        ? computeNextDueDate(spec)
        : null;
    final bookName = books.where((b) => b.id == rule.bookId).firstOrNull?.name;
    final issue = _accountIssue(rule, assets);

    return Card(
      key: Key('periodic_card_${rule.id}'),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openHistory(rule.id),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        Text(
                          amountText,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: amountColor,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      [
                        accountSummary,
                        if (rule.feeMinor > BigInt.zero)
                          '手续费 ¥${formatMinor(rule.feeMinor)}',
                        if (bookName != null) bookName,
                        if (rule.remark.isNotEmpty) rule.remark,
                      ].join(' · '),
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        Text(
                          '$cycleText · $endText · 已记 ${rule.periodAddTimes} 次',
                          style: const TextStyle(fontSize: 12),
                        ),
                        if (nextDue != null)
                          Text(
                            '下次: ${nextDue.formatIso()}',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                      ],
                    ),
                    if (issue != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        issue,
                        key: Key('periodic_issue_${rule.id}'),
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              PopupMenuButton<String>(
                key: Key('periodic_menu_${rule.id}'),
                onSelected: (action) => _handleRuleAction(action, rule),
                itemBuilder: (context) => [
                  const PopupMenuItem(value: 'history', child: Text('查看历史账单')),
                  const PopupMenuItem(value: 'edit', child: Text('编辑')),
                  if (rule.state == PeriodState.active)
                    const PopupMenuItem(value: 'pause', child: Text('停用')),
                  if (rule.state == PeriodState.paused)
                    const PopupMenuItem(value: 'resume', child: Text('设为进行中')),
                  const PopupMenuItem(value: 'delete', child: Text('删除')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Generated bill history drilldown page for a periodic rule (`record.period_id`).
class PeriodicHistoryPage extends ConsumerWidget {
  const PeriodicHistoryPage({
    super.key,
    required this.periodId,
    this.onRecordTap,
  });

  final int periodId;
  final void Function(String recordId)? onRecordTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ruleAsync = ref.watch(periodicRuleProvider(periodId));
    final historyAsync = ref.watch(periodicHistoryProvider(periodId));
    final categories =
        ref.watch(periodicAllCategoriesProvider).value ??
        const <RecordCategory>[];
    final assets = ref.watch(assetsProvider).value ?? const <Asset>[];

    return Scaffold(
      key: const Key('periodic_history_page'),
      appBar: AppBar(title: const Text('周期历史账单')),
      body: historyAsync.when(
        loading: () => const Loading(),
        error: (e, _) => ErrorView(e),
        data: (records) {
          final rule = ruleAsync.value;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Text(
                  rule == null
                      ? '规则已删除 · 历史保留 ${records.length} 笔记录'
                      : '${formatPeriodCycleSummary(periodType: rule.periodType, periodTypeDateJson: rule.periodTypeDate, frequency: rule.frequency)} · 共生成 ${records.length} 笔记录',
                  key: const Key('periodic_history_summary'),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              Expanded(
                child: records.isEmpty
                    ? const Center(
                        child: Text(
                          '暂无已生成的周期账单',
                          style: TextStyle(color: Colors.grey),
                        ),
                      )
                    : ListView.separated(
                        itemCount: records.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final r = records[index];
                          final label = recordLabel(r, categories, assets);
                          final timeStr = formatDateTime(
                            DateTime.fromMillisecondsSinceEpoch(r.recordTime),
                          );
                          return ListTile(
                            key: Key('periodic_history_item_${r.recordId}'),
                            title: Text(label.title),
                            subtitle: Text(
                              label.subtitle.isEmpty
                                  ? timeStr
                                  : '${label.subtitle} · $timeStr',
                            ),
                            trailing: Text(
                              label.amount,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            onTap: onRecordTap == null
                                ? null
                                : () => onRecordTap!(r.recordId),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}
