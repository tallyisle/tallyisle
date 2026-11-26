import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/adaptive.dart';
import '../../domain/model/codes.dart';
import '../common/common.dart';
import '../common/desktop_modal_page.dart';
import 'debt_detail_page.dart';
import 'debt_editor_page.dart';
import 'debt_providers.dart';

/// Main Debt Management page (`F-011` / original `DebtManageActivity`).
class DebtPage extends ConsumerStatefulWidget {
  const DebtPage({super.key});

  @override
  ConsumerState<DebtPage> createState() => _DebtPageState();
}

class _DebtPageState extends ConsumerState<DebtPage> {
  late PageController _pageController;
  int? _targetPage;

  static int _pageForStatus(int status) =>
      status == AssetStatus.settled ? 1 : 0;

  static int _statusForPage(int page) =>
      page == 1 ? AssetStatus.settled : AssetStatus.active;

  @override
  void initState() {
    super.initState();
    final initialStatus = ref.read(debtStatusTabProvider);
    _pageController = PageController(
      initialPage: _pageForStatus(initialStatus),
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _syncControllerToStatus(int nextStatus) {
    final targetPage = _pageForStatus(nextStatus);
    if (!_pageController.hasClients) {
      if (_pageController.initialPage != targetPage) {
        _pageController.dispose();
        _pageController = PageController(initialPage: targetPage);
      }
      return;
    }
    if (_pageController.page?.round() != targetPage) {
      _targetPage = targetPage;
      unawaited(
        _pageController
            .animateToPage(
              targetPage,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
            )
            .whenComplete(() {
              if (_targetPage == targetPage) _targetPage = null;
            }),
      );
    }
  }

  void _onPageChanged(int page) {
    if (_targetPage != null && page != _targetPage) return;
    _targetPage = null;
    final nextStatus = _statusForPage(page);
    if (ref.read(debtStatusTabProvider) != nextStatus) {
      ref.read(debtStatusTabProvider.notifier).select(nextStatus);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(debtStatusTabProvider, (_, next) {
      _syncControllerToStatus(next);
    });

    final isDesktop = DesktopAdaptive.isDesktop(context);
    final allBooks = ref.watch(debtAllBooksScopeProvider);
    final selectedStatus = ref.watch(debtStatusTabProvider);
    final viewAsync = ref.watch(debtListViewProvider);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      key: const Key('debt_page'),
      appBar: AppBar(
        title: const Text('借贷管理'),
        actions: [
          Padding(
            padding: EdgeInsets.only(right: isDesktop ? 8 : 12),
            child: Center(
              child: ActionChip(
                key: const Key('debt_scope_toggle'),
                visualDensity: isDesktop ? null : VisualDensity.compact,
                avatar: Icon(
                  allBooks ? Icons.library_books_rounded : Icons.book_outlined,
                  size: 16,
                  color: allBooks
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant,
                ),
                backgroundColor: allBooks
                    ? colorScheme.primaryContainer.withValues(alpha: 0.65)
                    : colorScheme.surfaceContainerHighest.withValues(
                        alpha: 0.55,
                      ),
                side: BorderSide(
                  color: allBooks
                      ? colorScheme.primary.withValues(alpha: 0.35)
                      : colorScheme.outlineVariant.withValues(alpha: 0.5),
                ),
                label: Text(
                  allBooks ? '全部账本' : '当前账本',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: allBooks
                        ? colorScheme.primary
                        : colorScheme.onSurface,
                  ),
                ),
                onPressed: () =>
                    ref.read(debtAllBooksScopeProvider.notifier).toggle(),
              ),
            ),
          ),
          if (isDesktop)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: TallySoftButton.icon(
                key: const Key('add_debt_button'),
                compact: true,
                onPressed: () async {
                  await pushDesktopModalOrMaterialRoute<bool>(
                    context,
                    child: const DebtEditorPage(),
                  );
                },
                icon: const Icon(Icons.add, size: 18),
                label: const Text('新建借贷'),
              ),
            ),
        ],
      ),
      body: asyncBody(viewAsync, (view) {
        final activeTab = selectedStatus == AssetStatus.settled
            ? AssetStatus.settled
            : AssetStatus.active;
        final wantPage = _pageForStatus(activeTab);
        if (!_pageController.hasClients &&
            _pageController.initialPage != wantPage) {
          _pageController.dispose();
          _pageController = PageController(initialPage: wantPage);
        }

        final content = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Card(
                    key: const Key('debt_summary_card'),
                    elevation: 0,
                    surfaceTintColor: Colors.transparent,
                    clipBehavior: Clip.antiAlias,
                    color: _tonalCardColor(Theme.of(context)),
                    shape: _tonalCardShape,
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 16,
                        horizontal: 12,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: _SummaryCell(
                              label: '借出应收',
                              value: formatMinor(
                                view.summary.totalReceivableMinor,
                              ),
                              valueKey: const Key('debt_total_receivable'),
                            ),
                          ),
                          Expanded(
                            child: _SummaryCell(
                              label: '借入应付',
                              value: formatMinor(
                                view.summary.totalPayableMinor,
                              ),
                              valueKey: const Key('debt_total_payable'),
                            ),
                          ),
                          Expanded(
                            child: _SummaryCell(
                              label: '净债权',
                              value: formatMinor(
                                view.summary.netReceivableMinor,
                              ),
                              valueKey: const Key('debt_net_receivable'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<int>(
                      key: const Key('debt_state_tabs'),
                      showSelectedIcon: false,
                      style: isDesktop
                          ? const ButtonStyle(
                              padding: WidgetStatePropertyAll(
                                EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 6,
                                ),
                              ),
                            )
                          : const ButtonStyle(
                              visualDensity: VisualDensity.compact,
                              padding: WidgetStatePropertyAll(
                                EdgeInsets.symmetric(horizontal: 10),
                              ),
                            ),
                      segments: [
                        ButtonSegment<int>(
                          value: AssetStatus.active,
                          label: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              '进行中 (${view.activeItems.length})',
                              key: const Key('debt_tab_active'),
                              maxLines: 1,
                              softWrap: false,
                            ),
                          ),
                        ),
                        ButtonSegment<int>(
                          value: AssetStatus.settled,
                          label: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              '已结清 (${view.settledItems.length})',
                              key: const Key('debt_tab_settled'),
                              maxLines: 1,
                              softWrap: false,
                            ),
                          ),
                        ),
                      ],
                      selected: {activeTab},
                      onSelectionChanged: (selection) => ref
                          .read(debtStatusTabProvider.notifier)
                          .select(selection.first),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: PageView(
                key: const Key('debt_page_view'),
                controller: _pageController,
                onPageChanged: _onPageChanged,
                children: [
                  _DebtTabList(
                    items: view.activeItems,
                    isSettledTab: false,
                    isDesktop: isDesktop,
                  ),
                  _DebtTabList(
                    items: view.settledItems,
                    isSettledTab: true,
                    isDesktop: isDesktop,
                  ),
                ],
              ),
            ),
          ],
        );

        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: isDesktop ? 800 : double.infinity,
            ),
            child: content,
          ),
        );
      }),
      floatingActionButton: isDesktop
          ? null
          : FloatingActionButton.extended(
              key: const Key('add_debt_button'),
              heroTag: 'fab-debt',
              onPressed: () async {
                await pushDesktopModalOrMaterialRoute<bool>(
                  context,
                  child: const DebtEditorPage(),
                );
              },
              icon: const Icon(Icons.add),
              label: const Text('新建借贷'),
            ),
    );
  }
}

class _DebtTabList extends StatelessWidget {
  const _DebtTabList({
    required this.items,
    required this.isSettledTab,
    required this.isDesktop,
  });

  final List<DebtListItem> items;
  final bool isSettledTab;
  final bool isDesktop;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return ListView(
        padding: EdgeInsets.fromLTRB(16, 0, 16, isDesktop ? 24 : 80),
        children: [
          if (isSettledTab)
            const TallyEmptyState(
              icon: Icons.task_alt_rounded,
              title: '暂无已结清的借贷项目',
            )
          else
            const TallyEmptyState(
              icon: Icons.swap_horiz_rounded,
              title: '暂无进行中的借贷项目',
              subtitle: '借出周转或日常借入后，可在此跟踪本息与收还款进度',
            ),
        ],
      );
    }

    return ListView.builder(
      padding: EdgeInsets.fromLTRB(16, 0, 16, isDesktop ? 24 : 80),
      itemCount: items.length,
      itemBuilder: (context, index) => _DebtItemCard(item: items[index]),
    );
  }
}

class _SummaryCell extends StatelessWidget {
  const _SummaryCell({
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        children: [
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              key: valueKey,
              maxLines: 1,
              softWrap: false,
              style: theme.textTheme.titleMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class _DebtItemCard extends StatelessWidget {
  const _DebtItemCard({required this.item});

  final DebtListItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final debt = item.debt;
    final isBorrow = debt.subType == AssetType.debtBorrow;
    final dueText = item.loanInfo.endDate != noRef && item.loanInfo.endDate > 0
        ? '到期 ${formatDate(DateTime.fromMillisecondsSinceEpoch(item.loanInfo.endDate))}'
        : null;

    return Card(
      key: Key('debt_item_${debt.id}'),
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      color: _tonalCardColor(Theme.of(context)),
      shape: _tonalCardShape,
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () async {
          await pushDesktopModalOrMaterialRoute<bool>(
            context,
            child: DebtDetailPage(debtId: debt.id),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    isBorrow ? Icons.call_received : Icons.call_made,
                    size: 18,
                    color: isBorrow
                        ? colorScheme.tertiary
                        : colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(debt.name, style: theme.textTheme.titleMedium),
                  ),
                  Text(
                    formatMinor(item.remainingPrincipalMinor),
                    key: Key('debt_item_balance_${debt.id}'),
                    style: theme.textTheme.titleMedium,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      [
                        isBorrow ? '借入' : '借出',
                        '总额 ${formatMinor(item.totalPrincipalMinor)}',
                        if (debt.currency != null) debt.currency!,
                        if (!item.countedInNetWorth) '不计入资产',
                        ?dueText,
                      ].join(' · '),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '进度 ${item.progressLabel}',
                    key: Key('debt_item_progress_${debt.id}'),
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
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

/// Borderless soft tonal card surface (16dp) shared by this feature's cards.
Color _tonalCardColor(ThemeData theme) {
  final scheme = theme.colorScheme;
  return theme.brightness == Brightness.dark
      ? scheme.surfaceContainerLow
      : Color.lerp(scheme.surfaceContainerLow, scheme.surfaceContainer, 0.55)!;
}

const RoundedRectangleBorder _tonalCardShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(16)),
);
