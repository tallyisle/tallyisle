import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../domain/rules/tag_stats.dart' show kTagColorSwatches;
import '../common/common.dart';
import '../stats/tag_stats_page.dart' show parseTagColor;
import '../stats/tag_stats_providers.dart' show tagRecordCountsProvider;

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
    String? selectedColor;

    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(
            parentTagId != null ? '新建二级标签' : (asGroup ? '新建标签组' : '新建标签'),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  key: const Key('tag-name'),
                  controller: nameController,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: '标签名称'),
                ),
                if (parentTagId == null) ...[
                  const SizedBox(height: 8),
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
                const SizedBox(height: 12),
                _TagColorPicker(
                  selectedColor: selectedColor,
                  onChanged: (hex) => setDialogState(() => selectedColor = hex),
                ),
              ],
            ),
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
        commandId: _ids.forPayload([
          'add-tag',
          name,
          parentTagId,
          asGroup,
          selectedColor,
        ]),
        name: name,
        parentTagId: parentTagId,
        isGroup: asGroup,
        color: selectedColor,
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
    String? selectedColor = (tag.color != null && tag.color!.trim().isNotEmpty)
        ? tag.color!.trim()
        : null;

    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('编辑标签“${tag.name}”'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  key: const Key('edit-tag-name'),
                  controller: nameController,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: '标签名称'),
                ),
                const SizedBox(height: 12),
                _TagColorPicker(
                  selectedColor: selectedColor,
                  onChanged: (hex) => setDialogState(() => selectedColor = hex),
                ),
              ],
            ),
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
      ),
    );

    if (ok != true || !mounted) return;
    try {
      final name = nameController.text.trim();
      final colorValue = selectedColor ?? '';
      final service = await ref.read(catalogServiceProvider.future);
      await service.updateTag(
        commandId: _ids.forPayload(['update-tag', tag.tagId, name, colorValue]),
        tagId: tag.tagId,
        name: name,
        color: colorValue,
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

  void _openTagStats(Tag tag) {
    context.push('/stats/tag/${tag.tagId}');
  }

  Widget _buildBillCountBadge(BuildContext context, String tagId, int count) {
    final theme = Theme.of(context);
    return Container(
      key: Key('tag-count-$tagId'),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: count > 0
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '$count 笔',
        style: TextStyle(
          fontSize: 11,
          fontWeight: count > 0 ? FontWeight.w600 : FontWeight.normal,
          color: count > 0
              ? theme.colorScheme.onPrimaryContainer
              : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tagsAsync = ref.watch(tagsProvider);
    final counts =
        ref.watch(tagRecordCountsProvider).value ?? const <String, int>{};

    return Scaffold(
      appBar: AppBar(
        title: const Text('标签管理'),
        actions: [
          IconButton(
            key: const Key('tags-stats-btn'),
            icon: const Icon(Icons.bar_chart_outlined),
            tooltip: '标签统计排行',
            onPressed: () => context.push('/stats/tags'),
          ),
        ],
      ),
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
              Builder(
                builder: (context) {
                  final grpColor = parseTagColor(grp.color);
                  final grpCount = counts[grp.tagId] ?? 0;
                  return ListTile(
                    key: Key('tag-${grp.name}'),
                    onTap: () => _openTagStats(grp),
                    leading: Icon(
                      grp.hidden
                          ? Icons.visibility_off_outlined
                          : Icons.folder_special_outlined,
                      color: grp.hidden ? Colors.grey : grpColor,
                    ),
                    title: Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (grpColor != null && !grp.hidden)
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: grpColor,
                              shape: BoxShape.circle,
                            ),
                          ),
                        Text(
                          grp.name,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            decoration: grp.hidden
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.blueGrey.shade100,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            '标签组',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                        _buildBillCountBadge(context, grp.tagId, grpCount),
                        if (grp.hidden)
                          const Text(
                            '(已隐藏)',
                            style: TextStyle(fontSize: 12, color: Colors.grey),
                          ),
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
                            if (val == 'stats') {
                              _openTagStats(grp);
                            } else if (val == 'edit') {
                              _editTag(grp);
                            } else if (val == 'delete') {
                              _deleteTag(grp);
                            }
                          },
                          itemBuilder: (context) => const [
                            PopupMenuItem(
                              value: 'stats',
                              child: Text('查看账单与统计'),
                            ),
                            PopupMenuItem(value: 'edit', child: Text('编辑')),
                            PopupMenuItem(value: 'delete', child: Text('删除')),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
              // Child tags
              for (final child in allTags.where(
                (t) => t.parentTagId == grp.tagId,
              ))
                Builder(
                  builder: (context) {
                    final childColor = parseTagColor(child.color);
                    final childCount = counts[child.tagId] ?? 0;
                    return Padding(
                      padding: const EdgeInsets.only(left: 32),
                      child: ListTile(
                        key: Key('tag-${child.name}'),
                        onTap: () => _openTagStats(child),
                        leading: Icon(
                          child.hidden
                              ? Icons.visibility_off_outlined
                              : Icons.label,
                          color: child.hidden ? Colors.grey : childColor,
                        ),
                        title: Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              child.name,
                              style: TextStyle(
                                decoration: child.hidden
                                    ? TextDecoration.lineThrough
                                    : null,
                              ),
                            ),
                            _buildBillCountBadge(
                              context,
                              child.tagId,
                              childCount,
                            ),
                          ],
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
                                if (val == 'stats') {
                                  _openTagStats(child);
                                } else if (val == 'edit') {
                                  _editTag(child);
                                } else if (val == 'delete') {
                                  _deleteTag(child);
                                }
                              },
                              itemBuilder: (context) => const [
                                PopupMenuItem(
                                  value: 'stats',
                                  child: Text('查看账单与统计'),
                                ),
                                PopupMenuItem(value: 'edit', child: Text('编辑')),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: Text('删除'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
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
                Builder(
                  builder: (context) {
                    final stColor = parseTagColor(st.color);
                    final stCount = counts[st.tagId] ?? 0;
                    return ListTile(
                      key: Key('tag-${st.name}'),
                      onTap: () => _openTagStats(st),
                      leading: Icon(
                        st.hidden
                            ? Icons.visibility_off_outlined
                            : (stColor != null
                                  ? Icons.label
                                  : Icons.label_outline),
                        color: st.hidden ? Colors.grey : stColor,
                      ),
                      title: Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            st.name,
                            style: TextStyle(
                              decoration: st.hidden
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                          ),
                          _buildBillCountBadge(context, st.tagId, stCount),
                        ],
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
                              if (val == 'stats') {
                                _openTagStats(st);
                              } else if (val == 'edit') {
                                _editTag(st);
                              } else if (val == 'delete') {
                                _deleteTag(st);
                              }
                            },
                            itemBuilder: (context) => const [
                              PopupMenuItem(
                                value: 'stats',
                                child: Text('查看账单与统计'),
                              ),
                              PopupMenuItem(value: 'edit', child: Text('编辑')),
                              PopupMenuItem(value: 'delete', child: Text('删除')),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
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

class _TagColorPicker extends StatelessWidget {
  const _TagColorPicker({required this.selectedColor, required this.onChanged});

  final String? selectedColor;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final normalizedSelected = selectedColor?.trim().toUpperCase();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '标签颜色',
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            InkWell(
              key: const Key('tag-color-clear'),
              borderRadius: BorderRadius.circular(16),
              onTap: () => onChanged(null),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color:
                      normalizedSelected == null || normalizedSelected.isEmpty
                      ? theme.colorScheme.secondaryContainer
                      : theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color:
                        normalizedSelected == null || normalizedSelected.isEmpty
                        ? theme.colorScheme.primary
                        : Colors.transparent,
                    width: 1.5,
                  ),
                ),
                child: const Text('默认', style: TextStyle(fontSize: 12)),
              ),
            ),
            for (final hex in kTagColorSwatches)
              Builder(
                builder: (context) {
                  final c = parseTagColor(hex)!;
                  final isSelected = normalizedSelected == hex.toUpperCase();
                  return InkWell(
                    key: Key('tag-color-$hex'),
                    customBorder: const CircleBorder(),
                    onTap: () => onChanged(hex),
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: isSelected
                            ? Border.all(
                                color: theme.colorScheme.onSurface,
                                width: 2.5,
                              )
                            : null,
                      ),
                      child: isSelected
                          ? const Icon(
                              Icons.check,
                              size: 16,
                              color: Colors.white,
                            )
                          : null,
                    ),
                  );
                },
              ),
          ],
        ),
      ],
    );
  }
}
