import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../data/repo/installment_queries.dart';
import '../../domain/model/codes.dart';
import '../common/common.dart';
import '../records/record_labels.dart' show assetName, categoryName;
import 'installment_detail_page.dart';
import 'installment_editor_page.dart';
import 'installment_providers.dart';

/// Installment management list page (F-010, original `/bkp/IRAct`).
class InstallmentPage extends ConsumerStatefulWidget {
  const InstallmentPage({
    super.key,
    this.autoCatchUpOnOpen = true,
    this.onRecordTap,
  });

  final bool autoCatchUpOnOpen;
  final void Function(String recordId)? onRecordTap;

  @override
  ConsumerState<InstallmentPage> createState() => _InstallmentPageState();
}

class _InstallmentPageState extends ConsumerState<InstallmentPage> {
  bool _catchingUp = false;

  @override
  void initState() {
    super.initState();
    if (widget.autoCatchUpOnOpen) {
      unawaited(_runCatchUp(silent: true));
    }
  }

  Future<void> _runCatchUp({required bool silent}) async {
    if (_catchingUp) return;
    setState(() => _catchingUp = true);
    try {
      final service = await ref.read(installmentServiceProvider.future);
      final res = await service.runCatchUp();
      if (!mounted) return;
      if (!silent || res.postedPeriodsCount > 0) {
        final msg = res.postedPeriodsCount > 0
            ? '已自动入账 ${res.postedPeriodsCount} 期到期分期'
            : '暂无到期未入账分期';
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (e) {
      if (!silent && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
      }
    } finally {
      if (mounted) setState(() => _catchingUp = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final showAllBooks = ref.watch(installmentAllBooksProvider);
    final activeAsync = ref.watch(activeInstallmentsProvider);
    final finishedAsync = ref.watch(finishedInstallmentsProvider);
    final assets = ref.watch(assetsProvider).value ?? const <Asset>[];

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        key: const Key('installment_page'),
        appBar: AppBar(
          title: const Text('分期管理'),
          actions: [
            TextButton.icon(
              key: const Key('installment_book_scope_button'),
              onPressed: () =>
                  ref.read(installmentAllBooksProvider.notifier).toggle(),
              icon: Icon(
                showAllBooks ? Icons.library_books : Icons.book_outlined,
                size: 18,
              ),
              label: Text(showAllBooks ? '全部账本' : '当前账本'),
            ),
            IconButton(
              key: const Key('installment_catchup_button'),
              tooltip: '检查到期入账',
              onPressed: _catchingUp ? null : () => _runCatchUp(silent: false),
              icon: const Icon(Icons.sync),
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(key: Key('installment_tab_active'), text: '进行中'),
              Tab(key: Key('installment_tab_finished'), text: '已完结'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            asyncBody(
              activeAsync,
              (items) => _InstallmentTabList(
                items: items,
                isFinishedTab: false,
                assets: assets,
                onRecordTap: widget.onRecordTap,
              ),
            ),
            asyncBody(
              finishedAsync,
              (items) => _InstallmentTabList(
                items: items,
                isFinishedTab: true,
                assets: assets,
                onRecordTap: widget.onRecordTap,
              ),
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          key: const Key('add_installment_fab'),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const InstallmentEditorPage(),
            ),
          ),
          icon: const Icon(Icons.add),
          label: const Text('新建分期'),
        ),
      ),
    );
  }
}

class _InstallmentTabList extends StatelessWidget {
  const _InstallmentTabList({
    required this.items,
    required this.isFinishedTab,
    required this.assets,
    this.onRecordTap,
  });

  final List<InstallmentSummaryView> items;
  final bool isFinishedTab;
  final List<Asset> assets;
  final void Function(String recordId)? onRecordTap;

  @override
  Widget build(BuildContext context) {
    final totals = InstallmentTabTotals.fromItems(items);
    if (items.isEmpty) {
      return Center(
        key: Key(
          isFinishedTab
              ? 'installment_empty_finished'
              : 'installment_empty_active',
        ),
        child: Text(isFinishedTab ? '暂无已完结分期' : '暂无进行中的分期计划'),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
      children: [
        _TabSummaryCard(totals: totals, isFinishedTab: isFinishedTab),
        const SizedBox(height: 8),
        for (final item in items)
          _InstallmentCard(
            item: item,
            assets: assets,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => InstallmentDetailPage(
                  installmentId: item.installment.id,
                  onRecordTap: onRecordTap,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _TabSummaryCard extends StatelessWidget {
  const _TabSummaryCard({required this.totals, required this.isFinishedTab});

  final InstallmentTabTotals totals;
  final bool isFinishedTab;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: Key(
        isFinishedTab
            ? 'installment_finished_summary_card'
            : 'installment_active_summary_card',
      ),
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isFinishedTab
                  ? '共 ${totals.count} 笔已完结分期'
                  : '待入账总额（${totals.count} 笔进行中）',
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '¥${formatMinor(isFinishedTab ? totals.totalPrincipalMinor + totals.totalChargeMinor : totals.remainingTotalMinor)}',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              runSpacing: 4,
              children: [
                Text(
                  isFinishedTab
                      ? '累计本金: ¥${formatMinor(totals.totalPrincipalMinor)}'
                      : '剩余本金: ¥${formatMinor(totals.remainingPrincipalMinor)}',
                  style: theme.textTheme.bodySmall,
                ),
                Text(
                  isFinishedTab
                      ? '原总手续费: ¥${formatMinor(totals.totalChargeMinor)}'
                      : '剩余手续费: ¥${formatMinor(totals.remainingFeeMinor)}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _InstallmentCard extends ConsumerWidget {
  const _InstallmentCard({
    required this.item,
    required this.assets,
    required this.onTap,
  });

  final InstallmentSummaryView item;
  final List<Asset> assets;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final inst = item.installment;
    final progress = item.progress;
    final categories =
        ref.watch(categoriesProvider(inst.bookId)).value ??
        const <RecordCategory>[];
    final catText = inst.catId == noRef
        ? '账单分期'
        : categoryName(categories, inst.catId);
    final accText = assetName(assets, inst.assetId);

    return Card(
      key: Key('installment_card_${inst.id}'),
      margin: const EdgeInsets.symmetric(vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      inst.name,
                      style: theme.textTheme.titleMedium?.copyWith(
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
                      color: item.isFinished
                          ? theme.colorScheme.tertiaryContainer
                          : theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      item.extra.settledEarly
                          ? '已提前结清'
                          : '${progress.creditedCount}/${progress.periods}期',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: item.isFinished
                            ? theme.colorScheme.onTertiaryContainer
                            : theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '$catText · $accText',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 10),
              InstallmentIntProgressBar(
                creditedCount: progress.creditedCount,
                remainingCount: progress.remainingCount,
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      item.isFinished
                          ? '总本金 ¥${formatMinor(inst.principalMinor)}'
                          : '待还 ¥${formatMinor(progress.remainingTotalMinor)}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (!item.isFinished)
                    Text(
                      '下期: ${formatDate(DateTime.fromMillisecondsSinceEpoch(progress.nextPeriodDateMs))}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Pure integer-flex progress bar (zero floating-point `double` math).
class InstallmentIntProgressBar extends StatelessWidget {
  const InstallmentIntProgressBar({
    super.key,
    required this.creditedCount,
    required this.remainingCount,
  });

  final int creditedCount;
  final int remainingCount;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final left = creditedCount < 0 ? 0 : creditedCount;
    final right = remainingCount < 0 ? 0 : remainingCount;
    if (left == 0 && right == 0) {
      return const SizedBox(height: 6);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: 6,
        child: Row(
          children: [
            if (left > 0)
              Expanded(
                flex: left,
                child: ColoredBox(color: scheme.primary),
              ),
            if (right > 0)
              Expanded(
                flex: right,
                child: ColoredBox(color: scheme.surfaceContainerHighest),
              ),
          ],
        ),
      ),
    );
  }
}
