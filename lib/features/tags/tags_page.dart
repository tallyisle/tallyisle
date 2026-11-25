import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/adaptive.dart';
import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../domain/rules/tag_stats.dart' show kTagColorSwatches;
import '../common/common.dart';
import '../common/desktop_modal_page.dart';
import '../stats/tag_stats_page.dart'
    show TagDetailStatsPage, TagRankingsPage, parseTagColor;
import '../stats/tag_stats_providers.dart' show tagRecordCountsProvider;

class TagsPage extends ConsumerStatefulWidget {
  const TagsPage({super.key});

  @override
  ConsumerState<TagsPage> createState() => _TagsPageState();
}

class _TagsPageState extends ConsumerState<TagsPage> {
  final _ids = CommandIds();
  final Set<String> _collapsedGroupIds = <String>{};
  List<String>? _optimisticAllTagIds;
  int _reorderSeq = 0;

  Future<void> _addTag({String? parentTagId, bool isGroup = false}) async {
    final nameController = TextEditingController();
    bool asGroup = isGroup;
    String? selectedColor;

    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final isDesktop = DesktopAdaptive.isDesktop(ctx);
          final formScroll = SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  key: const Key('tag-name'),
                  controller: nameController,
                  autofocus: true,
                  decoration: isDesktop
                      ? const InputDecoration(
                          labelText: '标签名称',
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 15,
                          ),
                        )
                      : const InputDecoration(labelText: '标签名称'),
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
          );
          return AlertDialog(
            title: Text(
              parentTagId != null ? '新建二级标签' : (asGroup ? '新建标签组' : '新建标签'),
            ),
            content: isDesktop
                ? ConstrainedBox(
                    constraints: const BoxConstraints(
                      minWidth: 360,
                      maxWidth: 420,
                    ),
                    child: formScroll,
                  )
                : formScroll,
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
          );
        },
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
      if (parentTagId != null &&
          mounted &&
          _collapsedGroupIds.contains(parentTagId)) {
        setState(() => _collapsedGroupIds.remove(parentTagId));
      }
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
        builder: (ctx, setDialogState) {
          final isDesktop = DesktopAdaptive.isDesktop(ctx);
          final formScroll = SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  key: const Key('edit-tag-name'),
                  controller: nameController,
                  autofocus: true,
                  decoration: isDesktop
                      ? const InputDecoration(
                          labelText: '标签名称',
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 15,
                          ),
                        )
                      : const InputDecoration(labelText: '标签名称'),
                ),
                const SizedBox(height: 12),
                _TagColorPicker(
                  selectedColor: selectedColor,
                  onChanged: (hex) => setDialogState(() => selectedColor = hex),
                ),
              ],
            ),
          );
          return AlertDialog(
            title: Text('编辑标签“${tag.name}”'),
            content: isDesktop
                ? ConstrainedBox(
                    constraints: const BoxConstraints(
                      minWidth: 360,
                      maxWidth: 420,
                    ),
                    child: formScroll,
                  )
                : formScroll,
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
          );
        },
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
    if (GoRouter.maybeOf(context) != null &&
        ModalRoute.of(context)?.settings is Page) {
      context.push('/stats/tag/${tag.tagId}');
      return;
    }
    pushDesktopModalOrMaterialRoute<void>(
      context,
      maxWidth: 860,
      maxHeight: 720,
      barrierDismissible: true,
      child: TagDetailStatsPage(tagId: tag.tagId),
    );
  }

  void _openTagRankings() {
    if (GoRouter.maybeOf(context) != null &&
        ModalRoute.of(context)?.settings is Page) {
      context.push('/stats/tags');
      return;
    }
    pushDesktopModalOrMaterialRoute<void>(
      context,
      maxWidth: 860,
      maxHeight: 720,
      barrierDismissible: true,
      child: const TagRankingsPage(),
    );
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

  void _toggleGroupExpanded(String groupId) {
    setState(() {
      if (!_collapsedGroupIds.remove(groupId)) {
        _collapsedGroupIds.add(groupId);
      }
    });
  }

  List<Tag> _applyOptimisticTags(List<Tag> rawTags) {
    final optimisticIds = _optimisticAllTagIds;
    if (optimisticIds == null || optimisticIds.length != rawTags.length) {
      return rawTags;
    }
    final byId = <String, Tag>{for (final t in rawTags) t.tagId: t};
    final ordered = <Tag>[];
    for (final id in optimisticIds) {
      final match = byId[id];
      if (match == null) return rawTags;
      ordered.add(match);
    }
    return ordered;
  }

  static List<String> _flattenCanonicalTagIds({
    required List<Tag> groups,
    required Map<String, List<Tag>> childrenByGroup,
    required List<Tag> standalone,
  }) {
    return <String>[
      for (final grp in groups) ...[
        grp.tagId,
        for (final child in childrenByGroup[grp.tagId] ?? const <Tag>[])
          child.tagId,
      ],
      for (final solo in standalone) solo.tagId,
    ];
  }

  Future<void> _persistTagOrder(List<String> canonicalIds) async {
    setState(() {
      _optimisticAllTagIds = canonicalIds;
    });
    try {
      final service = await ref.read(catalogServiceProvider.future);
      await service.reorderTags(
        commandId: _ids.forPayload([
          'reorder-tags',
          _reorderSeq++,
          canonicalIds,
        ]),
        tagIds: canonicalIds,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _optimisticAllTagIds = null;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

  Future<void> _reorderGroups({
    required List<Tag> groups,
    required Map<String, List<Tag>> childrenByGroup,
    required List<Tag> standalone,
    required int oldIndex,
    required int newIndex,
  }) async {
    if (oldIndex == newIndex) return;
    final nextGroups = List<Tag>.from(groups);
    final moved = nextGroups.removeAt(oldIndex);
    nextGroups.insert(newIndex, moved);
    await _persistTagOrder(
      _flattenCanonicalTagIds(
        groups: nextGroups,
        childrenByGroup: childrenByGroup,
        standalone: standalone,
      ),
    );
  }

  Future<void> _reorderGroupChildren({
    required String groupId,
    required List<Tag> groups,
    required Map<String, List<Tag>> childrenByGroup,
    required List<Tag> standalone,
    required int oldIndex,
    required int newIndex,
  }) async {
    if (oldIndex == newIndex) return;
    final currentChildren = childrenByGroup[groupId] ?? const <Tag>[];
    final nextChildren = List<Tag>.from(currentChildren);
    final moved = nextChildren.removeAt(oldIndex);
    nextChildren.insert(newIndex, moved);
    final nextChildrenMap = <String, List<Tag>>{
      ...childrenByGroup,
      groupId: nextChildren,
    };
    await _persistTagOrder(
      _flattenCanonicalTagIds(
        groups: groups,
        childrenByGroup: nextChildrenMap,
        standalone: standalone,
      ),
    );
  }

  Future<void> _reorderStandalone({
    required List<Tag> groups,
    required Map<String, List<Tag>> childrenByGroup,
    required List<Tag> standalone,
    required int oldIndex,
    required int newIndex,
  }) async {
    if (oldIndex == newIndex) return;
    final nextStandalone = List<Tag>.from(standalone);
    final moved = nextStandalone.removeAt(oldIndex);
    nextStandalone.insert(newIndex, moved);
    await _persistTagOrder(
      _flattenCanonicalTagIds(
        groups: groups,
        childrenByGroup: childrenByGroup,
        standalone: nextStandalone,
      ),
    );
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
    final theme = Theme.of(context);
    final tagsAsync = ref.watch(tagsProvider);
    ref.listen<AsyncValue<List<Tag>>>(tagsProvider, (_, next) {
      final rows = next.value;
      final optimistic = _optimisticAllTagIds;
      if (rows == null || optimistic == null) return;
      final dbIds = rows.map((t) => t.tagId).toList();
      if (dbIds.length != optimistic.length || listEquals(dbIds, optimistic)) {
        if (mounted) {
          setState(() => _optimisticAllTagIds = null);
        }
      }
    });

    final counts =
        ref.watch(tagRecordCountsProvider).value ?? const <String, int>{};
    final isDesktop = DesktopAdaptive.isDesktop(context);
    final isPopupModal = isDesktop && ModalRoute.of(context) is PopupRoute;

    return DesktopModalEscapeScope(
      enabled: isPopupModal,
      child: Scaffold(
        appBar: AppBar(
          leading: isPopupModal ? const CloseButton() : null,
          title: const Text('标签管理'),
          actions: [
            IconButton(
              key: const Key('tags-stats-btn'),
              icon: const Icon(Icons.bar_chart_outlined),
              tooltip: '标签统计排行',
              onPressed: _openTagRankings,
            ),
            if (isDesktop) ...[
              const SizedBox(width: 4),
              FilledButton.icon(
                key: const Key('add-tag'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                ),
                onPressed: () => _addTag(),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('新建标签'),
              ),
              const SizedBox(width: 12),
            ],
          ],
        ),
        body: asyncBody(tagsAsync, (rawTags) {
          final allTags = _applyOptimisticTags(rawTags);
          if (allTags.isEmpty) {
            return Center(
              child: Text(isDesktop ? '暂无标签，点击右上角添加' : '暂无标签，点击右下角添加'),
            );
          }

          final groups = allTags.where((t) => t.parent == 1).toList();
          final groupIds = <String>{for (final g in groups) g.tagId};
          final childrenByGroup = <String, List<Tag>>{
            for (final g in groups)
              g.tagId: allTags
                  .where((t) => t.parent != 1 && t.parentTagId == g.tagId)
                  .toList(),
          };
          final standalone = allTags
              .where(
                (t) =>
                    t.parent != 1 &&
                    (t.parentTagId == null ||
                        t.parentTagId!.isEmpty ||
                        !groupIds.contains(t.parentTagId)),
              )
              .toList();

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

          final scrollView = CustomScrollView(
            slivers: [
              if (groups.isNotEmpty)
                SliverPadding(
                  padding: const EdgeInsets.only(top: 8),
                  sliver: SliverReorderableList(
                    key: const ValueKey('tags-groups-reorder-sliver'),
                    itemCount: groups.length,
                    onReorderStart: (_) {
                      if (!isDesktop) {
                        HapticFeedback.selectionClick();
                      }
                    },
                    proxyDecorator: _buildReorderProxy,
                    onReorderItem: (oldIndex, newIndex) => _reorderGroups(
                      groups: groups,
                      childrenByGroup: childrenByGroup,
                      standalone: standalone,
                      oldIndex: oldIndex,
                      newIndex: newIndex,
                    ),
                    itemBuilder: (context, groupIndex) {
                      final grp = groups[groupIndex];
                      final grpColor = parseTagColor(grp.color);
                      final grpCount = counts[grp.tagId] ?? 0;
                      final children =
                          childrenByGroup[grp.tagId] ?? const <Tag>[];
                      final isExpanded = !_collapsedGroupIds.contains(
                        grp.tagId,
                      );

                      final grpIcon = Icon(
                        grp.hidden
                            ? Icons.visibility_off_outlined
                            : Icons.folder_special_outlined,
                        color: grp.hidden
                            ? theme.colorScheme.outline
                            : grpColor,
                      );

                      final grpTile = ListTile(
                        key: Key('tag-${grp.name}'),
                        contentPadding: EdgeInsets.only(
                          left: isDesktop ? 10 : 16,
                          right: 8,
                        ),
                        onTap: () => _openTagStats(grp),
                        leading: isDesktop
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _buildDesktopDragHandle(
                                    index: groupIndex,
                                    handleKey: Key(
                                      'tag-drag-handle-${grp.tagId}',
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  grpIcon,
                                ],
                              )
                            : grpIcon,
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
                                color: theme.colorScheme.secondaryContainer,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                '标签组',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                  color: theme.colorScheme.onSecondaryContainer,
                                ),
                              ),
                            ),
                            _buildBillCountBadge(context, grp.tagId, grpCount),
                            if (children.isNotEmpty)
                              InkWell(
                                key: Key('toggle-expand-tag-${grp.tagId}'),
                                borderRadius: BorderRadius.circular(12),
                                onTap: () => _toggleGroupExpanded(grp.tagId),
                                child: Padding(
                                  padding: const EdgeInsets.all(2),
                                  child: Icon(
                                    isExpanded
                                        ? Icons.expand_less_rounded
                                        : Icons.expand_more_rounded,
                                    size: 18,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            if (grp.hidden)
                              Text(
                                '(已隐藏)',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                          ],
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              key: Key('add-subtag-${grp.tagId}'),
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.add_circle_outline),
                              tooltip: '添加子标签',
                              onPressed: () => _addTag(parentTagId: grp.tagId),
                            ),
                            IconButton(
                              key: Key('hide-tag-${grp.tagId}'),
                              visualDensity: VisualDensity.compact,
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
                              padding: const EdgeInsets.all(4),
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
                                PopupMenuItem(
                                  value: 'delete',
                                  child: Text('删除'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );

                      final wrappedGrpTile = isDesktop
                          ? grpTile
                          : ReorderableDelayedDragStartListener(
                              index: groupIndex,
                              child: grpTile,
                            );

                      return Card(
                        key: ValueKey('tag-group-block-${grp.tagId}'),
                        margin: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 5,
                        ),
                        elevation: 0,
                        surfaceTintColor: Colors.transparent,
                        color: cardColor,
                        clipBehavior: Clip.antiAlias,
                        shape: cardShape,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            wrappedGrpTile,
                            if (isExpanded && children.isNotEmpty)
                              ReorderableListView.builder(
                                key: ValueKey(
                                  'tags-children-reorder-${grp.tagId}',
                                ),
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                buildDefaultDragHandles: false,
                                itemCount: children.length,
                                onReorderStart: (_) {
                                  if (!isDesktop) {
                                    HapticFeedback.selectionClick();
                                  }
                                },
                                proxyDecorator: _buildReorderProxy,
                                onReorderItem: (oldChildIdx, newChildIdx) =>
                                    _reorderGroupChildren(
                                      groupId: grp.tagId,
                                      groups: groups,
                                      childrenByGroup: childrenByGroup,
                                      standalone: standalone,
                                      oldIndex: oldChildIdx,
                                      newIndex: newChildIdx,
                                    ),
                                itemBuilder: (childCtx, childIndex) {
                                  final child = children[childIndex];
                                  final childColor = parseTagColor(child.color);
                                  final childCount = counts[child.tagId] ?? 0;
                                  final childIcon = Icon(
                                    child.hidden
                                        ? Icons.visibility_off_outlined
                                        : Icons.label,
                                    color: child.hidden
                                        ? theme.colorScheme.outline
                                        : childColor,
                                  );
                                  final childTile = Padding(
                                    padding: EdgeInsets.only(
                                      left: isDesktop ? 24 : 28,
                                    ),
                                    child: ListTile(
                                      key: Key('tag-${child.name}'),
                                      contentPadding: EdgeInsets.only(
                                        left: isDesktop ? 10 : 16,
                                        right: 8,
                                      ),
                                      onTap: () => _openTagStats(child),
                                      leading: isDesktop
                                          ? Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                _buildDesktopDragHandle(
                                                  index: childIndex,
                                                  handleKey: Key(
                                                    'tag-drag-handle-${child.tagId}',
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                                childIcon,
                                              ],
                                            )
                                          : childIcon,
                                      title: Wrap(
                                        spacing: 6,
                                        runSpacing: 4,
                                        crossAxisAlignment:
                                            WrapCrossAlignment.center,
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
                                            visualDensity:
                                                VisualDensity.compact,
                                            icon: Icon(
                                              child.hidden
                                                  ? Icons.visibility_outlined
                                                  : Icons
                                                        .visibility_off_outlined,
                                            ),
                                            tooltip: child.hidden
                                                ? '取消隐藏'
                                                : '隐藏',
                                            onPressed: () => _toggleHide(child),
                                          ),
                                          PopupMenuButton<String>(
                                            key: Key('tag-menu-${child.tagId}'),
                                            padding: const EdgeInsets.all(4),
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
                                              PopupMenuItem(
                                                value: 'edit',
                                                child: Text('编辑'),
                                              ),
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
                                  if (isDesktop) {
                                    return KeyedSubtree(
                                      key: ValueKey(
                                        'tag-child-item-${child.tagId}',
                                      ),
                                      child: childTile,
                                    );
                                  }
                                  return ReorderableDelayedDragStartListener(
                                    key: ValueKey(
                                      'tag-child-item-${child.tagId}',
                                    ),
                                    index: childIndex,
                                    child: childTile,
                                  );
                                },
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              if (standalone.isNotEmpty)
                SliverToBoxAdapter(
                  child: Card(
                    margin: EdgeInsets.fromLTRB(
                      16,
                      groups.isEmpty ? 12 : 6,
                      16,
                      6,
                    ),
                    elevation: 0,
                    surfaceTintColor: Colors.transparent,
                    color: cardColor,
                    clipBehavior: Clip.antiAlias,
                    shape: cardShape,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (groups.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                            child: Text(
                              '独立标签',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ReorderableListView.builder(
                          key: const ValueKey('tags-standalone-reorder-sliver'),
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          buildDefaultDragHandles: false,
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          itemCount: standalone.length,
                          onReorderStart: (_) {
                            if (!isDesktop) {
                              HapticFeedback.selectionClick();
                            }
                          },
                          proxyDecorator: _buildReorderProxy,
                          onReorderItem: (oldSoloIdx, newSoloIdx) =>
                              _reorderStandalone(
                                groups: groups,
                                childrenByGroup: childrenByGroup,
                                standalone: standalone,
                                oldIndex: oldSoloIdx,
                                newIndex: newSoloIdx,
                              ),
                          itemBuilder: (context, soloIndex) {
                            final st = standalone[soloIndex];
                            final stColor = parseTagColor(st.color);
                            final stCount = counts[st.tagId] ?? 0;
                            final stIcon = Icon(
                              st.hidden
                                  ? Icons.visibility_off_outlined
                                  : (stColor != null
                                        ? Icons.label
                                        : Icons.label_outline),
                              color: st.hidden
                                  ? theme.colorScheme.outline
                                  : stColor,
                            );
                            final stTile = ListTile(
                              key: Key('tag-${st.name}'),
                              contentPadding: EdgeInsets.only(
                                left: isDesktop ? 10 : 16,
                                right: 8,
                              ),
                              onTap: () => _openTagStats(st),
                              leading: isDesktop
                                  ? Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        _buildDesktopDragHandle(
                                          index: soloIndex,
                                          handleKey: Key(
                                            'tag-drag-handle-${st.tagId}',
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        stIcon,
                                      ],
                                    )
                                  : stIcon,
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
                                  _buildBillCountBadge(
                                    context,
                                    st.tagId,
                                    stCount,
                                  ),
                                ],
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    key: Key('hide-tag-${st.tagId}'),
                                    visualDensity: VisualDensity.compact,
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
                                    padding: const EdgeInsets.all(4),
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
                                      PopupMenuItem(
                                        value: 'edit',
                                        child: Text('编辑'),
                                      ),
                                      PopupMenuItem(
                                        value: 'delete',
                                        child: Text('删除'),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            );
                            if (isDesktop) {
                              return KeyedSubtree(
                                key: ValueKey('tag-solo-item-${st.tagId}'),
                                child: stTile,
                              );
                            }
                            return ReorderableDelayedDragStartListener(
                              key: ValueKey('tag-solo-item-${st.tagId}'),
                              index: soloIndex,
                              child: stTile,
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              SliverToBoxAdapter(child: SizedBox(height: isDesktop ? 16 : 96)),
            ],
          );
          if (!isDesktop) return scrollView;
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: scrollView,
            ),
          );
        }),
        floatingActionButton: isDesktop
            ? null
            : FloatingActionButton.extended(
                key: const Key('add-tag'),
                heroTag: 'fab-add-tag',
                onPressed: () => _addTag(),
                icon: const Icon(Icons.add),
                label: const Text('新建标签'),
              ),
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
                child: Text(
                  '默认',
                  style: TextStyle(
                    fontSize: 12,
                    color:
                        normalizedSelected == null || normalizedSelected.isEmpty
                        ? theme.colorScheme.onSecondaryContainer
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            for (final hex in kTagColorSwatches)
              Builder(
                builder: (context) {
                  final c = parseTagColor(hex)!;
                  final isSelected = normalizedSelected == hex.toUpperCase();
                  final checkColor =
                      ThemeData.estimateBrightnessForColor(c) ==
                          Brightness.light
                      ? Colors.black87
                      : Colors.white;
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
                          ? Icon(Icons.check, size: 16, color: checkColor)
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
