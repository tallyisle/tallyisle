import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../common/common.dart';

class TagsPage extends ConsumerStatefulWidget {
  const TagsPage({super.key});

  @override
  ConsumerState<TagsPage> createState() => _TagsPageState();
}

class _TagsPageState extends ConsumerState<TagsPage> {
  final _ids = CommandIds();

  Future<void> _addTag({String? parentTagId, bool isGroup = false}) async {
    final nameController = TextEditingController();
    bool asGroup = isGroup;

    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(
            parentTagId != null ? '新建二级标签' : (asGroup ? '新建标签组' : '新建标签'),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const Key('tag-name'),
                controller: nameController,
                autofocus: true,
                decoration: const InputDecoration(labelText: '标签名称'),
              ),
              if (parentTagId == null) ...[
                const SizedBox(height: 12),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('作为一级标签组'),
                  subtitle: const Text('标签组可用于对二级标签进行归类'),
                  value: asGroup,
                  onChanged: (val) {
                    setDialogState(() => asGroup = val ?? false);
                  },
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('tag-save'),
              onPressed: () => Navigator.pop(dialogCtx, true),
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );

    if (ok != true || !mounted) return;
    try {
      final name = nameController.text.trim();
      final service = await ref.read(catalogServiceProvider.future);
      await service.createTag(
        commandId: _ids.forPayload(['add-tag', name, parentTagId, asGroup]),
        name: name,
        parentTagId: parentTagId,
        isGroup: asGroup,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

  Future<void> _editTag(Tag tag) async {
    final nameController = TextEditingController(text: tag.name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text('编辑标签“${tag.name}”'),
        content: TextField(
          key: const Key('edit-tag-name'),
          controller: nameController,
          autofocus: true,
          decoration: const InputDecoration(labelText: '标签名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('edit-tag-save'),
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
      await service.updateTag(
        commandId: _ids.forPayload(['update-tag', tag.tagId, name]),
        tagId: tag.tagId,
        name: name,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

  Future<void> _toggleHide(Tag tag) async {
    try {
      final service = await ref.read(catalogServiceProvider.future);
      await service.setTagHidden(
        commandId: _ids.forPayload(['hide-tag', tag.tagId, !tag.hidden]),
        tagId: tag.tagId,
        hidden: !tag.hidden,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

  Future<void> _deleteTag(Tag tag) async {
    final isGroup = tag.parent == 1;
    final confirmed = await confirm(
      context,
      title: isGroup ? '删除标签组' : '删除标签',
      message: isGroup
          ? '确定删除标签组“${tag.name}”吗？其下的子标签以及所有账单关联将一并清除。'
          : '确定删除标签“${tag.name}”吗？所有账单上的此标签关联将同步清除。',
      ok: '删除',
    );
    if (!confirmed || !mounted) return;
    try {
      final service = await ref.read(catalogServiceProvider.future);
      await service.deleteTag(
        commandId: _ids.forPayload(['delete-tag', tag.tagId]),
        tagId: tag.tagId,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('标签“${tag.name}”已删除')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tagsAsync = ref.watch(tagsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('标签管理')),
      body: asyncBody(tagsAsync, (allTags) {
        if (allTags.isEmpty) {
          return const Center(child: Text('暂无标签，点击右下角添加'));
        }

        final groups = allTags.where((t) => t.parent == 1).toList();
        final standalone = allTags
            .where(
              (t) =>
                  t.parent == 0 &&
                  (t.parentTagId == null || t.parentTagId!.isEmpty),
            )
            .toList();

        return ListView(
          padding: const EdgeInsets.only(bottom: 96),
          children: [
            for (final grp in groups) ...[
              ListTile(
                key: Key('tag-${grp.name}'),
                leading: Icon(
                  grp.hidden
                      ? Icons.visibility_off_outlined
                      : Icons.folder_special_outlined,
                  color: grp.hidden ? Colors.grey : null,
                ),
                title: Row(
                  children: [
                    Text(
                      grp.name,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        decoration: grp.hidden
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.blueGrey.shade100,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text('标签组', style: TextStyle(fontSize: 11)),
                    ),
                    if (grp.hidden) ...[
                      const SizedBox(width: 6),
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
                      key: Key('add-subtag-${grp.tagId}'),
                      icon: const Icon(Icons.add_circle_outline),
                      tooltip: '添加子标签',
                      onPressed: () => _addTag(parentTagId: grp.tagId),
                    ),
                    IconButton(
                      key: Key('hide-tag-${grp.tagId}'),
                      icon: Icon(
                        grp.hidden
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      tooltip: grp.hidden ? '取消隐藏' : '隐藏',
                      onPressed: () => _toggleHide(grp),
                    ),
                    PopupMenuButton<String>(
                      key: Key('tag-menu-${grp.tagId}'),
                      onSelected: (val) {
                        if (val == 'edit') {
                          _editTag(grp);
                        } else if (val == 'delete') {
                          _deleteTag(grp);
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
              // Child tags
              for (final child in allTags.where(
                (t) => t.parentTagId == grp.tagId,
              ))
                Padding(
                  padding: const EdgeInsets.only(left: 32),
                  child: ListTile(
                    key: Key('tag-${child.name}'),
                    leading: Icon(
                      child.hidden
                          ? Icons.visibility_off_outlined
                          : Icons.label_outlined,
                      color: child.hidden ? Colors.grey : null,
                    ),
                    title: Text(
                      child.name,
                      style: TextStyle(
                        decoration: child.hidden
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          key: Key('hide-tag-${child.tagId}'),
                          icon: Icon(
                            child.hidden
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                          tooltip: child.hidden ? '取消隐藏' : '隐藏',
                          onPressed: () => _toggleHide(child),
                        ),
                        PopupMenuButton<String>(
                          key: Key('tag-menu-${child.tagId}'),
                          onSelected: (val) {
                            if (val == 'edit') {
                              _editTag(child);
                            } else if (val == 'delete') {
                              _deleteTag(child);
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
                ),
              const Divider(height: 1),
            ],
            // Standalone tags
            if (standalone.isNotEmpty) ...[
              if (groups.isNotEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text(
                    '独立标签',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey,
                    ),
                  ),
                ),
              for (final st in standalone)
                ListTile(
                  key: Key('tag-${st.name}'),
                  leading: Icon(
                    st.hidden
                        ? Icons.visibility_off_outlined
                        : Icons.label_outline,
                    color: st.hidden ? Colors.grey : null,
                  ),
                  title: Text(
                    st.name,
                    style: TextStyle(
                      decoration: st.hidden ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        key: Key('hide-tag-${st.tagId}'),
                        icon: Icon(
                          st.hidden
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                        tooltip: st.hidden ? '取消隐藏' : '隐藏',
                        onPressed: () => _toggleHide(st),
                      ),
                      PopupMenuButton<String>(
                        key: Key('tag-menu-${st.tagId}'),
                        onSelected: (val) {
                          if (val == 'edit') {
                            _editTag(st);
                          } else if (val == 'delete') {
                            _deleteTag(st);
                          }
                        },
                        itemBuilder: (context) => [
                          const PopupMenuItem(value: 'edit', child: Text('编辑')),
                          const PopupMenuItem(
                            value: 'delete',
                            child: Text('删除'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
            ],
          ],
        );
      }),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('add-tag'),
        heroTag: 'fab-add-tag',
        onPressed: () => _addTag(),
        icon: const Icon(Icons.add),
        label: const Text('新建标签'),
      ),
    );
  }
}
