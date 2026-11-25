import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/adaptive.dart';
import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../domain/model/codes.dart';
import '../category_transfer/category_transfer_page.dart';
import '../common/catalog_icons.dart';
import '../common/common.dart';
import '../common/desktop_modal_page.dart';
import '../me/me_page.dart' show MeEmbeddedNavigationScope;

class CategoriesPage extends ConsumerStatefulWidget {
  const CategoriesPage({super.key});

  @override
  ConsumerState<CategoriesPage> createState() => _CategoriesPageState();
}

class _CategoriesPageState extends ConsumerState<CategoriesPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _ids = CommandIds();
  final Set<int> _collapsedParentIds = <int>{};
  final Map<String, List<int>> _optimisticCategoryOrders =
      <String, List<int>>{};
  int _reorderSeq = 0;

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

  Future<({String name, String icon, String colorHex})?> _createOrRenameDialog({
    required String title,
    required String confirmLabel,
    required Key nameFieldKey,
    required Key saveButtonKey,
    required int type,
    String initialName = '',
    String? initialIcon,
    String? initialColor,
    String? parentName,
  }) {
    return showDialog<({String name, String icon, String colorHex})>(
      context: context,
      builder: (dialogCtx) => _CategoryEditorDialog(
        title: title,
        confirmLabel: confirmLabel,
        nameFieldKey: nameFieldKey,
        saveButtonKey: saveButtonKey,
        type: type,
        initialName: initialName,
        initialIcon: initialIcon,
        initialColor: initialColor,
        parentName: parentName,
      ),
    );
  }

  Future<void> _addCategory(
    int bookId,
    int type, {
    int parentCatId = -1,
    RecordCategory? parentCategory,
  }) async {
    final isSub = parentCatId != -1;
    final result = await _createOrRenameDialog(
      title: isSub ? '新建二级分类' : '新建分类',
      confirmLabel: '创建',
      nameFieldKey: const Key('category-name'),
      saveButtonKey: const Key('category-save'),
      type: type,
      initialColor: parentCategory?.colorFill,
      parentName: parentCategory?.name,
    );

    if (result == null || !mounted) return;
    try {
      final service = await ref.read(catalogServiceProvider.future);
      await service.createCategory(
        commandId: _ids.forPayload([
          'add-cat',
          bookId,
          result.name,
          type,
          parentCatId,
          result.icon,
          result.colorHex,
        ]),
        accountBookId: bookId,
        name: result.name,
        type: type,
        parentCatId: parentCatId,
        icon: result.icon,
        colorFill: result.colorHex,
      );
      if (isSub && mounted && _collapsedParentIds.contains(parentCatId)) {
        setState(() => _collapsedParentIds.remove(parentCatId));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

  Future<void> _editCategory(
    RecordCategory category, {
    RecordCategory? parentCategory,
  }) async {
    final result = await _createOrRenameDialog(
      title: '编辑分类“${category.name}”',
      confirmLabel: '保存',
      nameFieldKey: const Key('edit-category-name'),
      saveButtonKey: const Key('edit-category-save'),
      type: category.type,
      initialName: category.name,
      initialIcon: category.icon.isEmpty ? null : category.icon,
      initialColor: category.colorFill,
      parentName: parentCategory?.name,
    );

    if (result == null || !mounted) return;
    try {
      final service = await ref.read(catalogServiceProvider.future);
      await service.updateCategory(
        commandId: _ids.forPayload([
          'update-cat',
          category.id,
          result.name,
          result.icon,
          result.colorHex,
        ]),
        categoryId: category.id,
        name: result.name,
        icon: result.icon,
        colorFill: result.colorHex,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

  Future<void> _toggleHide(RecordCategory category) async {
    try {
      final service = await ref.read(catalogServiceProvider.future);
      await service.setCategoryHidden(
        commandId: _ids.forPayload(['hide-cat', category.id, !category.isHide]),
        categoryId: category.id,
        isHide: !category.isHide,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

  Future<void> _deleteCategory(
    RecordCategory category,
    List<RecordCategory> allCategories,
  ) async {
    try {
      final queries = await ref.read(catalogQueriesProvider.future);
      final count = await queries.countRecordsInCategory(category.id);

      if (!mounted) return;

      int? targetId;
      if (count > 0) {
        // Must select a migration target category of the same book and type.
        final List<int> excludedIds = [category.id];
        if (category.parentCatId == -1) {
          excludedIds.addAll(
            allCategories
                .where((c) => c.parentCatId == category.id)
                .map((c) => c.id),
          );
        }
        final candidates = allCategories
            .where(
              (c) => c.type == category.type && !excludedIds.contains(c.id),
            )
            .toList();

        if (candidates.isEmpty) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('分类下有账单，且没有可供迁移的其他同类型分类，请先创建替代分类后再删除。'),
            ),
          );
          return;
        }

        int selectedTarget = candidates.first.id;
        final ok = await showDialog<bool>(
          context: context,
          builder: (dialogCtx) => StatefulBuilder(
            builder: (ctx, setDialogState) {
              final isDesktop = DesktopAdaptive.isDesktop(ctx);
              final migrateBody = Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('“${category.name}”下有 $count 笔历史账单。'),
                  const SizedBox(height: 8),
                  const Text('删除前请选择将历史账单迁移至的目标分类：'),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    key: const Key('target-category-dropdown'),
                    isExpanded: true,
                    initialValue: selectedTarget,
                    decoration: isDesktop
                        ? const InputDecoration(
                            labelText: '目标分类',
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 15,
                            ),
                          )
                        : const InputDecoration(),
                    items: [
                      for (final cand in candidates)
                        DropdownMenuItem(
                          value: cand.id,
                          child: Row(
                            children: [
                              if (cand.parentCatId != -1)
                                const SizedBox(width: 12),
                              CategoryIconAvatar(
                                iconKey: cand.icon,
                                colorHex: cand.colorFill,
                                name: cand.name,
                                type: cand.type,
                                size: 22,
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  cand.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                    onChanged: (val) {
                      if (val != null) {
                        setDialogState(() => selectedTarget = val);
                      }
                    },
                  ),
                ],
              );
              return AlertDialog(
                title: const Text('迁移并删除分类'),
                content: isDesktop
                    ? ConstrainedBox(
                        constraints: const BoxConstraints(
                          minWidth: 360,
                          maxWidth: 420,
                        ),
                        child: migrateBody,
                      )
                    : migrateBody,
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogCtx, false),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    key: const Key('confirm-migrate-delete'),
                    onPressed: () => Navigator.pop(dialogCtx, true),
                    child: const Text('迁移并删除'),
                  ),
                ],
              );
            },
          ),
        );
        if (ok != true) return;
        targetId = selectedTarget;
      } else {
        final ok = await confirm(
          context,
          title: '删除分类',
          message: category.parentCatId == -1
              ? '确定删除分类“${category.name}”及其所有子分类吗？'
              : '确定删除二级分类“${category.name}”吗？',
          ok: '删除',
        );
        if (!ok) return;
      }

      if (!mounted) return;
      final service = await ref.read(catalogServiceProvider.future);
      await service.deleteCategory(
        commandId: _ids.forPayload(['delete-cat', category.id, targetId]),
        categoryId: category.id,
        targetCategoryId: targetId,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('分类“${category.name}”已删除')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

  void _toggleParentExpanded(int parentId) {
    setState(() {
      if (!_collapsedParentIds.remove(parentId)) {
        _collapsedParentIds.add(parentId);
      }
    });
  }

  List<RecordCategory> _applyOptimisticCategoryOrder(
    String scope,
    List<RecordCategory> items,
  ) {
    final optimisticIds = _optimisticCategoryOrders[scope];
    if (optimisticIds == null || optimisticIds.length != items.length) {
      return items;
    }
    final byId = <int, RecordCategory>{for (final c in items) c.id: c};
    final ordered = <RecordCategory>[];
    for (final id in optimisticIds) {
      final match = byId[id];
      if (match == null) return items;
      ordered.add(match);
    }
    return ordered;
  }

  Future<void> _reorderCategoryScope(
    String scope,
    List<RecordCategory> currentItems,
    int oldIndex,
    int newIndex,
  ) async {
    if (oldIndex == newIndex) return;
    final updated = List<RecordCategory>.from(currentItems);
    final moved = updated.removeAt(oldIndex);
    updated.insert(newIndex, moved);
    final orderedIds = updated.map((c) => c.id).toList();

    setState(() {
      _optimisticCategoryOrders[scope] = orderedIds;
    });

    try {
      final service = await ref.read(catalogServiceProvider.future);
      await service.reorderCategories(
        commandId: _ids.forPayload([
          'reorder-cat',
          scope,
          _reorderSeq++,
          orderedIds,
        ]),
        categoryIds: orderedIds,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _optimisticCategoryOrders.remove(scope);
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

  void _openCategoryTransfer(int bookId) {
    final route = ModalRoute.of(context);
    final isImperativeOrPopup =
        route is PopupRoute || (route != null && route.settings is! Page);
    if (!isImperativeOrPopup) {
      final meScope = MeEmbeddedNavigationScope.maybeOf(context);
      if (meScope != null) {
        meScope.onSelectRoute('/categories/transfer');
        return;
      }
    }
    if (isImperativeOrPopup || GoRouter.maybeOf(context) == null) {
      pushDesktopModalOrMaterialRoute<void>(
        context,
        maxWidth: 760,
        maxHeight: 720,
        barrierDismissible: true,
        child: CategoryTransferPage(initialBookId: bookId),
      );
      return;
    }
    context.push('/categories/transfer?bookId=$bookId');
  }

  Widget _buildReorderProxy(
    Widget child,
    int index,
    Animation<double> animation,
  ) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(animation.value);
        final scheme = Theme.of(context).colorScheme;
        return Material(
          elevation: 6 * t,
          color: scheme.surfaceContainerHigh,
          shadowColor: scheme.shadow.withValues(alpha: 0.28),
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: child,
        );
      },
      child: child,
    );
  }

  Widget _buildDesktopDragHandle({required int index, required Key handleKey}) {
    return ReorderableDragStartListener(
      index: index,
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: Padding(
          key: handleKey,
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
          child: Icon(
            Icons.drag_handle_rounded,
            size: 20,
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bookId = ref.watch(currentBookIdProvider).value ?? 1;
    final categoriesAsync = ref.watch(allCategoriesProvider(bookId));
    ref.listen<AsyncValue<List<RecordCategory>>>(
      allCategoriesProvider(bookId),
      (_, next) {
        final rows = next.value;
        if (rows == null || _optimisticCategoryOrders.isEmpty) return;
        final toRemove = <String>[];
        for (final entry in _optimisticCategoryOrders.entries) {
          final key = entry.key;
          List<int>? dbIds;
          if (key == 'top-$bookId-${RecordType.expense}') {
            dbIds = rows
                .where(
                  (c) => c.type == RecordType.expense && c.parentCatId == -1,
                )
                .map((c) => c.id)
                .toList();
          } else if (key == 'top-$bookId-${RecordType.income}') {
            dbIds = rows
                .where(
                  (c) => c.type == RecordType.income && c.parentCatId == -1,
                )
                .map((c) => c.id)
                .toList();
          } else if (key.startsWith('sub-')) {
            final parentId = int.tryParse(key.substring(4));
            if (parentId != null) {
              dbIds = rows
                  .where((c) => c.parentCatId == parentId)
                  .map((c) => c.id)
                  .toList();
            }
          }
          if (dbIds != null &&
              (dbIds.length != entry.value.length ||
                  listEquals(dbIds, entry.value))) {
            toRemove.add(key);
          }
        }
        if (toRemove.isNotEmpty && mounted) {
          setState(() {
            for (final k in toRemove) {
              _optimisticCategoryOrders.remove(k);
            }
          });
        }
      },
    );

    final isDesktop = DesktopAdaptive.isDesktop(context);
    final isPopupModal = isDesktop && ModalRoute.of(context) is PopupRoute;

    final tabBar = TabBar(
      controller: _tabController,
      tabs: const [
        Tab(text: '支出分类'),
        Tab(text: '收入分类'),
      ],
    );

    return DesktopModalEscapeScope(
      enabled: isPopupModal,
      child: Scaffold(
        appBar: AppBar(
          leading: isPopupModal ? const CloseButton() : null,
          title: const Text('分类管理'),
          actions: [
            IconButton(
              key: const Key('categories-transfer-action'),
              tooltip: '分类导入导出与迁移',
              icon: const Icon(Icons.import_export_outlined),
              onPressed: () => _openCategoryTransfer(bookId),
            ),
            if (isDesktop) ...[
              const SizedBox(width: 4),
              FilledButton.icon(
                key: const Key('add-category'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                ),
                onPressed: () => _addCategory(
                  bookId,
                  _tabController.index == 0
                      ? RecordType.expense
                      : RecordType.income,
                ),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('新建一级分类'),
              ),
              const SizedBox(width: 12),
            ],
          ],
          bottom: isDesktop
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(kTextTabBarHeight),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 820),
                      child: tabBar,
                    ),
                  ),
                )
              : tabBar,
        ),
        body: asyncBody(
          categoriesAsync,
          (all) => TabBarView(
            controller: _tabController,
            children: [
              _buildCategoryList(bookId, RecordType.expense, all),
              _buildCategoryList(bookId, RecordType.income, all),
            ],
          ),
        ),
        floatingActionButton: isDesktop
            ? null
            : FloatingActionButton.extended(
                key: const Key('add-category'),
                heroTag: 'fab-add-category',
                onPressed: () => _addCategory(
                  bookId,
                  _tabController.index == 0
                      ? RecordType.expense
                      : RecordType.income,
                ),
                icon: const Icon(Icons.add),
                label: const Text('新建一级分类'),
              ),
      ),
    );
  }

  Widget _buildCategoryList(int bookId, int type, List<RecordCategory> all) {
    final topScope = 'top-$bookId-$type';
    final topLevels = _applyOptimisticCategoryOrder(
      topScope,
      all.where((c) => c.type == type && c.parentCatId == -1).toList(),
    );

    if (topLevels.isEmpty) {
      return const Center(child: Text('暂无分类'));
    }

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final cardColor = theme.brightness == Brightness.dark
        ? scheme.surfaceContainerLow
        : Color.lerp(
            scheme.surfaceContainerLow,
            scheme.surfaceContainer,
            0.55,
          )!;
    final cardShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
    );
    final isDesktop = DesktopAdaptive.isDesktop(context);
    final reorderableList = ReorderableListView.builder(
      key: ValueKey('categories-reorder-$topScope'),
      padding: isDesktop
          ? const EdgeInsets.symmetric(vertical: 8)
          : const EdgeInsets.fromLTRB(0, 8, 0, 96),
      buildDefaultDragHandles: false,
      itemCount: topLevels.length,
      onReorderStart: (_) {
        if (!isDesktop) {
          HapticFeedback.selectionClick();
        }
      },
      proxyDecorator: _buildReorderProxy,
      onReorderItem: (oldIndex, newIndex) =>
          _reorderCategoryScope(topScope, topLevels, oldIndex, newIndex),
      itemBuilder: (context, topIndex) {
        final top = topLevels[topIndex];
        final subScope = 'sub-${top.id}';
        final subs = _applyOptimisticCategoryOrder(
          subScope,
          all.where((c) => c.parentCatId == top.id).toList(),
        );
        final isExpanded = !_collapsedParentIds.contains(top.id);

        final topAvatar = CategoryIconAvatar(
          iconKey: top.icon,
          colorHex: top.colorFill,
          name: top.name,
          type: top.type,
          size: isDesktop ? 36 : 38,
          dimmed: top.isHide,
        );

        final topTile = ListTile(
          key: Key('category-${top.name}'),
          contentPadding: EdgeInsets.only(left: isDesktop ? 10 : 16, right: 8),
          onTap: subs.isEmpty ? null : () => _toggleParentExpanded(top.id),
          leading: isDesktop
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildDesktopDragHandle(
                      index: topIndex,
                      handleKey: Key('cat-drag-handle-${top.id}'),
                    ),
                    const SizedBox(width: 6),
                    topAvatar,
                  ],
                )
              : topAvatar,
          title: Row(
            children: [
              Flexible(
                child: Text(
                  top.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    decoration: top.isHide ? TextDecoration.lineThrough : null,
                  ),
                ),
              ),
              if (subs.isNotEmpty) ...[
                const SizedBox(width: 4),
                Icon(
                  isExpanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  key: Key('toggle-expand-cat-${top.id}'),
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
              if (top.isHide) ...[
                const SizedBox(width: 6),
                Flexible(
                  flex: 0,
                  child: Text(
                    '(已隐藏)',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ],
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                key: Key('add-subcat-${top.id}'),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.add_circle_outline),
                tooltip: '添加子分类',
                onPressed: () => _addCategory(
                  bookId,
                  type,
                  parentCatId: top.id,
                  parentCategory: top,
                ),
              ),
              IconButton(
                key: Key('hide-cat-${top.id}'),
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  top.isHide
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
                tooltip: top.isHide ? '取消隐藏' : '隐藏',
                onPressed: () => _toggleHide(top),
              ),
              PopupMenuButton<String>(
                key: Key('cat-menu-${top.id}'),
                padding: const EdgeInsets.all(4),
                onSelected: (val) {
                  if (val == 'edit') {
                    _editCategory(top);
                  } else if (val == 'delete') {
                    _deleteCategory(top, all);
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(value: 'edit', child: Text('编辑')),
                  const PopupMenuItem(value: 'delete', child: Text('删除')),
                ],
              ),
            ],
          ),
        );

        final wrappedTopTile = isDesktop
            ? topTile
            : ReorderableDelayedDragStartListener(
                index: topIndex,
                child: topTile,
              );

        return Card(
          key: ValueKey('cat-top-block-${top.id}'),
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          color: cardColor,
          clipBehavior: Clip.antiAlias,
          shape: cardShape,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              wrappedTopTile,
              if (isExpanded && subs.isNotEmpty)
                ReorderableListView.builder(
                  key: ValueKey('categories-reorder-$subScope'),
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: false,
                  itemCount: subs.length,
                  onReorderStart: (_) {
                    if (!isDesktop) {
                      HapticFeedback.selectionClick();
                    }
                  },
                  proxyDecorator: _buildReorderProxy,
                  onReorderItem: (oldSubIndex, newSubIndex) =>
                      _reorderCategoryScope(
                        subScope,
                        subs,
                        oldSubIndex,
                        newSubIndex,
                      ),
                  itemBuilder: (subCtx, subIndex) {
                    final sub = subs[subIndex];
                    final subAvatar = CategoryIconAvatar(
                      iconKey: sub.icon,
                      parentIconKey: top.icon,
                      colorHex: sub.colorFill ?? top.colorFill,
                      name: '${top.name} · ${sub.name}',
                      type: sub.type,
                      size: isDesktop ? 30 : 32,
                      dimmed: sub.isHide,
                    );
                    final subTile = Padding(
                      padding: EdgeInsets.only(left: isDesktop ? 24 : 28),
                      child: ListTile(
                        key: Key('category-${sub.name}'),
                        contentPadding: EdgeInsets.only(
                          left: isDesktop ? 10 : 16,
                          right: 8,
                        ),
                        leading: isDesktop
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _buildDesktopDragHandle(
                                    index: subIndex,
                                    handleKey: Key('cat-drag-handle-${sub.id}'),
                                  ),
                                  const SizedBox(width: 6),
                                  subAvatar,
                                ],
                              )
                            : subAvatar,
                        title: Text(
                          sub.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            decoration: sub.isHide
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                        ),
                        subtitle: sub.isHide
                            ? Text(
                                '已隐藏',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              )
                            : null,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              key: Key('hide-cat-${sub.id}'),
                              visualDensity: VisualDensity.compact,
                              icon: Icon(
                                sub.isHide
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                              tooltip: sub.isHide ? '取消隐藏' : '隐藏',
                              onPressed: () => _toggleHide(sub),
                            ),
                            PopupMenuButton<String>(
                              key: Key('cat-menu-${sub.id}'),
                              padding: const EdgeInsets.all(4),
                              onSelected: (val) {
                                if (val == 'edit') {
                                  _editCategory(sub, parentCategory: top);
                                } else if (val == 'delete') {
                                  _deleteCategory(sub, all);
                                }
                              },
                              itemBuilder: (context) => [
                                const PopupMenuItem(
                                  value: 'edit',
                                  child: Text('编辑'),
                                ),
                                const PopupMenuItem(
                                  value: 'delete',
                                  child: Text('删除'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                    if (isDesktop) {
                      return KeyedSubtree(
                        key: ValueKey('cat-sub-item-${sub.id}'),
                        child: subTile,
                      );
                    }
                    return ReorderableDelayedDragStartListener(
                      key: ValueKey('cat-sub-item-${sub.id}'),
                      index: subIndex,
                      child: subTile,
                    );
                  },
                ),
            ],
          ),
        );
      },
    );

    final viewportList = LayoutBuilder(
      builder: (context, constraints) => ListView(
        physics: const NeverScrollableScrollPhysics(),
        children: [
          SizedBox(
            width: constraints.maxWidth,
            height: constraints.maxHeight,
            child: reorderableList,
          ),
        ],
      ),
    );

    if (!isDesktop) return viewportList;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820),
        child: viewportList,
      ),
    );
  }
}

class _CategoryEditorDialog extends StatefulWidget {
  const _CategoryEditorDialog({
    required this.title,
    required this.confirmLabel,
    required this.nameFieldKey,
    required this.saveButtonKey,
    required this.type,
    required this.initialName,
    this.initialIcon,
    this.initialColor,
    this.parentName,
  });

  final String title;
  final String confirmLabel;
  final Key nameFieldKey;
  final Key saveButtonKey;
  final int type;
  final String initialName;
  final String? initialIcon;
  final String? initialColor;
  final String? parentName;

  @override
  State<_CategoryEditorDialog> createState() => _CategoryEditorDialogState();
}

class _CategoryEditorDialogState extends State<_CategoryEditorDialog> {
  late final TextEditingController _nameController;
  String? _selectedIcon;
  String? _selectedColor;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialName);
    _selectedIcon = widget.initialIcon;
    _selectedColor = widget.initialColor;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  String _effectiveLookupName() {
    final trimmed = _nameController.text.trim();
    if (widget.parentName != null && widget.parentName!.isNotEmpty) {
      return trimmed.isEmpty
          ? widget.parentName!
          : '${widget.parentName!} · $trimmed';
    }
    return trimmed;
  }

  Future<void> _openPicker() async {
    final picked = await showCategoryVisualPicker(
      context,
      initialIcon: _selectedIcon,
      initialColor: _selectedColor,
      previewName: _nameController.text.trim(),
      categoryType: widget.type,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _selectedIcon = picked.icon;
      _selectedColor = picked.colorHex;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visual = resolveCategoryVisual(
      iconKey: _selectedIcon,
      colorHex: _selectedColor,
      name: _effectiveLookupName(),
      type: widget.type,
    );

    final isDesktop = DesktopAdaptive.isDesktop(context);
    final editorScroll = SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: widget.nameFieldKey,
            controller: _nameController,
            autofocus: true,
            decoration: isDesktop
                ? const InputDecoration(
                    labelText: '分类名称',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 15,
                    ),
                  )
                : const InputDecoration(labelText: '分类名称'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          InkWell(
            key: const Key('category-visual-picker-trigger'),
            borderRadius: BorderRadius.circular(12),
            onTap: _openPicker,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Row(
                children: [
                  CategoryIconAvatar(
                    iconKey: visual.iconKey,
                    colorHex: visual.colorHex,
                    name: visual.label,
                    type: widget.type,
                    size: 38,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('图标与配色', style: theme.textTheme.bodyMedium),
                        Text(
                          '${visual.label} · 点击更换图标或颜色',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right),
                ],
              ),
            ),
          ),
        ],
      ),
    );

    return AlertDialog(
      title: Text(widget.title),
      content: isDesktop
          ? ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 360, maxWidth: 420),
              child: editorScroll,
            )
          : editorScroll,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: widget.saveButtonKey,
          onPressed: () {
            final finalVisual = resolveCategoryVisual(
              iconKey: _selectedIcon,
              colorHex: _selectedColor,
              name: _effectiveLookupName(),
              type: widget.type,
            );
            Navigator.pop(context, (
              name: _nameController.text.trim(),
              icon: finalVisual.iconKey,
              colorHex: finalVisual.colorHex,
            ));
          },
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
