import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../app/adaptive.dart';
import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../domain/rules/wish_note_rules.dart';
import '../common/common.dart';
import '../common/desktop_modal_page.dart';
import 'wish_editor_page.dart';
import 'wish_providers.dart';

const _uuid = Uuid();

/// Wish List page (`F-014`, original route `/bkp/WLAct`).
class WishesPage extends ConsumerStatefulWidget {
  const WishesPage({super.key});

  @override
  ConsumerState<WishesPage> createState() => _WishesPageState();
}

class _WishesPageState extends ConsumerState<WishesPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _openEditor({String? wishId}) async {
    await pushDesktopModalOrMaterialRoute<void>(
      context,
      child: WishEditorPage(wishId: wishId),
    );
  }

  Future<void> _markRealized(Wish wish) async {
    try {
      final service = await ref.read(wishServiceProvider.future);
      await service.markRealized(commandId: _uuid.v4(), id: wish.id);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已标记心愿为已实现')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
      }
    }
  }

  Future<void> _reopenWish(Wish wish) async {
    try {
      final service = await ref.read(wishServiceProvider.future);
      await service.reopenWish(commandId: _uuid.v4(), id: wish.id);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已移回待实现')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
      }
    }
  }

  Future<void> _deleteWish(Wish wish) async {
    final ok = await confirm(
      context,
      title: '确认删除此心愿？',
      message: '删除「${wish.content}」后不可恢复。',
      ok: '删除',
    );
    if (!ok || !mounted) return;
    try {
      final service = await ref.read(wishServiceProvider.future);
      await service.deleteWish(commandId: _uuid.v4(), id: wish.id);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('心愿已删除')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final summaryAsync = ref.watch(wishSummaryProvider);
    final unrealizedAsync = ref.watch(unrealizedWishesProvider);
    final realizedAsync = ref.watch(realizedWishesProvider);
    final nowMs =
        ref.watch(databaseProvider).value?.nowMs() ??
        DateTime.now().millisecondsSinceEpoch;

    final isDesktop = DesktopAdaptive.isDesktop(context);
    final tabBar = TabBar(
      controller: _tabController,
      tabs: const [
        Tab(key: Key('wish_tab_unrealized'), text: '待实现'),
        Tab(key: Key('wish_tab_realized'), text: '已实现'),
      ],
    );
    final bodyColumn = Column(
      children: [
        _WishSummaryBanner(summaryAsync: summaryAsync),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              asyncBody(
                unrealizedAsync,
                (items) => _WishListView(
                  wishes: items,
                  isRealizedTab: false,
                  nowMs: nowMs,
                  onEdit: (w) => _openEditor(wishId: w.id),
                  onToggleRealized: _markRealized,
                  onDelete: _deleteWish,
                ),
              ),
              asyncBody(
                realizedAsync,
                (items) => _WishListView(
                  wishes: items,
                  isRealizedTab: true,
                  nowMs: nowMs,
                  onEdit: (w) => _openEditor(wishId: w.id),
                  onToggleRealized: _reopenWish,
                  onDelete: _deleteWish,
                ),
              ),
            ],
          ),
        ),
      ],
    );

    return Scaffold(
      key: const Key('wishes_page'),
      appBar: AppBar(
        scrolledUnderElevation: isDesktop ? 0 : null,
        title: const Text('心愿单'),
        actions: isDesktop
            ? [
                FilledButton.icon(
                  key: const Key('add_wish_fab'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                  onPressed: _openEditor,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('新建心愿'),
                ),
                const SizedBox(width: 12),
              ]
            : null,
        bottom: isDesktop
            ? PreferredSize(
                preferredSize: tabBar.preferredSize,
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 800),
                    child: tabBar,
                  ),
                ),
              )
            : tabBar,
      ),
      body: isDesktop
          ? Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 800),
                child: bodyColumn,
              ),
            )
          : bodyColumn,
      floatingActionButton: isDesktop
          ? null
          : FloatingActionButton.extended(
              key: const Key('add_wish_fab'),
              heroTag: 'fab-wishes',
              onPressed: _openEditor,
              icon: const Icon(Icons.add),
              label: const Text('新建心愿'),
            ),
    );
  }
}

class _WishSummaryBanner extends StatelessWidget {
  const _WishSummaryBanner({required this.summaryAsync});

  final AsyncValue<WishSummary> summaryAsync;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final summary =
        summaryAsync.value ??
        WishSummary(
          unrealizedCount: 0,
          realizedCount: 0,
          unrealizedTotalMinor: BigInt.zero,
          realizedTotalMinor: BigInt.zero,
        );

    return Card(
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: _tonalCardShape,
      color: _tonalCardColor(Theme.of(context)),
      key: const Key('wish_summary_banner'),
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '待实现（${summary.unrealizedCount} 项）',
                      key: const Key('wish_summary_unrealized_count'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 4),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '¥${formatMinor(summary.unrealizedTotalMinor)}',
                        key: const Key('wish_summary_unrealized_total'),
                        maxLines: 1,
                        softWrap: false,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Container(
              width: 1,
              height: 36,
              color: theme.colorScheme.outlineVariant,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '已实现（${summary.realizedCount} 项）',
                    key: const Key('wish_summary_realized_count'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '¥${formatMinor(summary.realizedTotalMinor)}',
                      key: const Key('wish_summary_realized_total'),
                      maxLines: 1,
                      softWrap: false,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WishListView extends StatelessWidget {
  const _WishListView({
    required this.wishes,
    required this.isRealizedTab,
    required this.nowMs,
    required this.onEdit,
    required this.onToggleRealized,
    required this.onDelete,
  });

  final List<Wish> wishes;
  final bool isRealizedTab;
  final int nowMs;
  final ValueChanged<Wish> onEdit;
  final ValueChanged<Wish> onToggleRealized;
  final ValueChanged<Wish> onDelete;

  @override
  Widget build(BuildContext context) {
    final isDesktop = DesktopAdaptive.isDesktop(context);
    if (wishes.isEmpty) {
      return Center(
        key: Key(
          isRealizedTab ? 'wish_realized_empty' : 'wish_unrealized_empty',
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            isRealizedTab
                ? '暂无已实现的心愿'
                : (isDesktop ? '还没有待实现的心愿，点击右上角新建一个吧' : '还没有待实现的心愿，点击右下角新建一个吧'),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView.separated(
      padding: EdgeInsets.fromLTRB(16, 8, 16, isDesktop ? 24 : 88),
      itemCount: wishes.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final wish = wishes[index];
        return _WishCard(
          wish: wish,
          nowMs: nowMs,
          onTap: () => onEdit(wish),
          onToggleRealized: () => onToggleRealized(wish),
          onDelete: () => onDelete(wish),
        );
      },
    );
  }
}

class _WishCard extends StatelessWidget {
  const _WishCard({
    required this.wish,
    required this.nowMs,
    required this.onTap,
    required this.onToggleRealized,
    required this.onDelete,
  });

  final Wish wish;
  final int nowMs;
  final VoidCallback onTap;
  final VoidCallback onToggleRealized;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final deadline = evaluateWishDeadline(
      targetDateMs: wish.targetDate,
      nowMs: nowMs,
      isRealized: wish.isRealized,
    );

    final (Color badgeBg, Color badgeFg) = switch (deadline.status) {
      WishDeadlineStatus.overdue => (cs.errorContainer, cs.onErrorContainer),
      WishDeadlineStatus.dueToday => (
        cs.tertiaryContainer,
        cs.onTertiaryContainer,
      ),
      WishDeadlineStatus.upcoming => (
        cs.secondaryContainer,
        cs.onSecondaryContainer,
      ),
      _ => (cs.surfaceContainerHighest, cs.onSurfaceVariant),
    };

    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: _tonalCardShape,
      color: _tonalCardColor(Theme.of(context)),
      key: Key('wish_card_${wish.id}'),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    backgroundColor: wish.isRealized
                        ? cs.secondaryContainer
                        : cs.primaryContainer,
                    foregroundColor: wish.isRealized
                        ? cs.onSecondaryContainer
                        : cs.onPrimaryContainer,
                    child: Icon(wishIconData(wish.icon)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          wish.content,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            if (wish.isRealized && wish.realizedDate > 0)
                              Text(
                                '实现于 ${formatDate(DateTime.fromMillisecondsSinceEpoch(wish.realizedDate))}',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: cs.onSurfaceVariant,
                                ),
                              )
                            else
                              Text(
                                '创建于 ${formatDate(DateTime.fromMillisecondsSinceEpoch(wish.createDate))}',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            if (!wish.isRealized && wish.targetDate > 0)
                              Text(
                                '目标 ${formatDate(DateTime.fromMillisecondsSinceEpoch(wish.targetDate))}',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            if (deadline.label != null)
                              Container(
                                key: Key('wish_deadline_${wish.id}'),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: badgeBg,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  deadline.label!,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: badgeFg,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 112),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Text(
                        '¥${formatMinor(wish.valueMinor)}',
                        maxLines: 1,
                        softWrap: false,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: wish.isRealized ? cs.onSurface : cs.primary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Flexible(
                    child: TextButton.icon(
                      key: Key(
                        wish.isRealized
                            ? 'reopen_wish_${wish.id}'
                            : 'realize_wish_${wish.id}',
                      ),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      onPressed: onToggleRealized,
                      icon: Icon(
                        wish.isRealized
                            ? Icons.replay_outlined
                            : Icons.check_circle_outline,
                        size: 18,
                      ),
                      label: Text(
                        wish.isRealized ? '重新开启' : '实现',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  IconButton(
                    key: Key('edit_wish_${wish.id}'),
                    visualDensity: VisualDensity.compact,
                    tooltip: '编辑',
                    onPressed: onTap,
                    icon: const Icon(Icons.edit_outlined, size: 20),
                  ),
                  IconButton(
                    key: Key('delete_wish_${wish.id}'),
                    visualDensity: VisualDensity.compact,
                    tooltip: '删除',
                    onPressed: onDelete,
                    icon: const Icon(Icons.delete_outline, size: 20),
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

Color _tonalCardColor(ThemeData theme) {
  final scheme = theme.colorScheme;
  return theme.brightness == Brightness.dark
      ? scheme.surfaceContainerLow
      : Color.lerp(scheme.surfaceContainerLow, scheme.surfaceContainer, 0.55)!;
}

const _tonalCardShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(16)),
);
