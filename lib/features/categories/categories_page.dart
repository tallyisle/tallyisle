import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../domain/model/codes.dart';
import '../common/common.dart';

class CategoriesPage extends ConsumerStatefulWidget {
  const CategoriesPage({super.key});

  @override
  ConsumerState<CategoriesPage> createState() => _CategoriesPageState();
}

class _CategoriesPageState extends ConsumerState<CategoriesPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _ids = CommandIds();

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

  Future<void> _addCategory(
    int bookId,
    int type, {
    int parentCatId = -1,
  }) async {
    final nameController = TextEditingController();
    final isSub = parentCatId != -1;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(isSub ? '新建二级分类' : '新建分类'),
        content: TextField(
          key: const Key('category-name'),
          controller: nameController,
          autofocus: true,
          decoration: const InputDecoration(labelText: '分类名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('category-save'),
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('创建'),
          ),
        ],
      ),
    );

    if (ok != true || !mounted) return;
    try {
      final name = nameController.text.trim();
      final service = await ref.read(catalogServiceProvider.future);
      await service.createCategory(
        commandId: _ids.forPayload([
          'add-cat',
          bookId,
          name,
          type,
          parentCatId,
        ]),
        accountBookId: bookId,
        name: name,
        type: type,
        parentCatId: parentCatId,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

  Future<void> _editCategory(RecordCategory category) async {
    final nameController = TextEditingController(text: category.name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text('编辑分类“${category.name}”'),
        content: TextField(
          key: const Key('edit-category-name'),
          controller: nameController,
          autofocus: true,
          decoration: const InputDecoration(labelText: '分类名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('edit-category-save'),
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    if (ok != true || !mounted) return;
    try {
      final name = nameController.text.trim();
      final service = await ref.read(catalogServiceProvider.future);
      await service.updateCategory(
        commandId: _ids.forPayload(['update-cat', category.id, name]),
        categoryId: category.id,
        name: name,
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
            builder: (ctx, setDialogState) => AlertDialog(
              title: const Text('迁移并删除分类'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('“${category.name}”下有 $count 笔历史账单。'),
                  const SizedBox(height: 8),
                  const Text('删除前请选择将历史账单迁移至的目标分类：'),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    key: const Key('target-category-dropdown'),
                    initialValue: selectedTarget,
                    items: [
                      for (final cand in candidates)
                        DropdownMenuItem(
                          value: cand.id,
                          child: Text(
                            cand.parentCatId == -1
                                ? cand.name
                                : '  ${cand.name}',
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
              ),
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
            ),
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

  @override
  Widget build(BuildContext context) {
    final bookId = ref.watch(currentBookIdProvider).value ?? 1;
    final categoriesAsync = ref.watch(allCategoriesProvider(bookId));

    return Scaffold(
      appBar: AppBar(
        title: const Text('分类管理'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: '支出分类'),
            Tab(text: '收入分类'),
          ],
        ),
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
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('add-category'),
        heroTag: 'fab-add-category',
        onPressed: () => _addCategory(
          bookId,
          _tabController.index == 0 ? RecordType.expense : RecordType.income,
        ),
        icon: const Icon(Icons.add),
        label: const Text('新建一级分类'),
      ),
    );
  }

  Widget _buildCategoryList(int bookId, int type, List<RecordCategory> all) {
    final topLevels = all
        .where((c) => c.type == type && c.parentCatId == -1)
        .toList();

    if (topLevels.isEmpty) {
      return const Center(child: Text('暂无分类'));
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 96),
      children: [
        for (final top in topLevels) ...[
          ListTile(
            key: Key('category-${top.name}'),
            leading: Icon(
              top.isHide
                  ? Icons.visibility_off_outlined
                  : Icons.folder_outlined,
              color: top.isHide ? Colors.grey : null,
            ),
            title: Row(
              children: [
                Text(
                  top.name,
                  style: TextStyle(
                    decoration: top.isHide ? TextDecoration.lineThrough : null,
                  ),
                ),
                if (top.isHide) ...[
                  const SizedBox(width: 8),
                  const Text(
                    '(已隐藏)',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: Key('add-subcat-${top.id}'),
                  icon: const Icon(Icons.add_circle_outline),
                  tooltip: '添加子分类',
                  onPressed: () =>
                      _addCategory(bookId, type, parentCatId: top.id),
                ),
                IconButton(
                  key: Key('hide-cat-${top.id}'),
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
          ),
          // Subcategories
          for (final sub in all.where((c) => c.parentCatId == top.id))
            Padding(
              padding: const EdgeInsets.only(left: 32),
              child: ListTile(
                key: Key('category-${sub.name}'),
                leading: Icon(
                  sub.isHide
                      ? Icons.visibility_off_outlined
                      : Icons.subdirectory_arrow_right,
                  color: sub.isHide ? Colors.grey : null,
                ),
                title: Text(
                  sub.name,
                  style: TextStyle(
                    decoration: sub.isHide ? TextDecoration.lineThrough : null,
                  ),
                ),
                subtitle: sub.isHide
                    ? const Text('已隐藏', style: TextStyle(fontSize: 12))
                    : null,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      key: Key('hide-cat-${sub.id}'),
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
                      onSelected: (val) {
                        if (val == 'edit') {
                          _editCategory(sub);
                        } else if (val == 'delete') {
                          _deleteCategory(sub, all);
                        }
                      },
                      itemBuilder: (context) => [
                        const PopupMenuItem(value: 'edit', child: Text('编辑')),
                        const PopupMenuItem(value: 'delete', child: Text('删除')),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          const Divider(height: 1),
        ],
      ],
    );
  }
}
