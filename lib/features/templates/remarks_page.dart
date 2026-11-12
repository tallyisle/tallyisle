import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../domain/model/codes.dart';
import '../attachments/attachment_providers.dart'
    show billAttachmentServiceProvider;
import '../common/common.dart';
import '../receipt/receipt_diy_providers.dart'
    show DiyToolbarAction, DiyToolbarConfig, diyToolbarConfigProvider;
import 'template_providers.dart';

/// Reusable frequent-remark suggestion chips for `RecordEditorPage` and
/// `TemplateEditorPage` (`F-016` R4).
///
/// Watches remarks matching `recordCatId == categoryId` or `-1` (`noRef`),
/// ordered by `usedTimes DESC, id DESC`, and hides itself when empty unless
/// [onManageRemarks] is provided.
class FrequentRemarkChips extends ConsumerWidget {
  const FrequentRemarkChips({
    super.key,
    required this.categoryId,
    required this.onSelectRemark,
    this.selectedRemark,
    this.maxCount = 12,
    this.enabled = true,
    this.onManageRemarks,
  });

  final int categoryId;
  final ValueChanged<String> onSelectRemark;
  final String? selectedRemark;
  final int maxCount;
  final bool enabled;
  final VoidCallback? onManageRemarks;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final remarksAsync = ref.watch(remarksForCategoryProvider(categoryId));
    return remarksAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (rows) {
        final seen = <String>{};
        final unique = <Remark>[];
        for (final r in rows) {
          final text = r.content.trim();
          if (text.isNotEmpty && seen.add(text)) {
            unique.add(r);
            if (unique.length >= maxCount) break;
          }
        }
        if (unique.isEmpty && onManageRemarks == null) {
          return const SizedBox.shrink();
        }
        return Padding(
          key: const Key('frequent_remark_chips'),
          padding: const EdgeInsets.only(top: 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final r in unique)
                ActionChip(
                  key: Key('remark_chip_${r.id}'),
                  visualDensity: VisualDensity.compact,
                  avatar: selectedRemark?.trim() == r.content.trim()
                      ? const Icon(Icons.check, size: 16)
                      : null,
                  label: Text(r.content),
                  onPressed: enabled ? () => onSelectRemark(r.content) : null,
                ),
              if (onManageRemarks != null)
                ActionChip(
                  key: const Key('manage_remarks_chip'),
                  visualDensity: VisualDensity.compact,
                  avatar: const Icon(Icons.tune, size: 16),
                  label: const Text('管理备注'),
                  onPressed: enabled ? onManageRemarks : null,
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Management page for frequent remarks (`F-016` R4): filter by category,
/// search, create, edit, and delete.
class RemarksPage extends ConsumerStatefulWidget {
  const RemarksPage({super.key, this.initialCategoryId});

  final int? initialCategoryId;

  @override
  ConsumerState<RemarksPage> createState() => _RemarksPageState();
}

class _RemarksPageState extends ConsumerState<RemarksPage> {
  static const int _filterAll = -999;

  final TextEditingController _searchController = TextEditingController();
  final CommandIds _deleteIds = CommandIds();
  final CommandIds _toggleIds = CommandIds();
  late int _selectedFilter;
  String _keyword = '';
  bool _toggleBusy = false;
  int _toggleSeq = 0;

  @override
  void initState() {
    super.initState();
    _selectedFilter = widget.initialCategoryId ?? _filterAll;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  int? get _queryCategoryId =>
      _selectedFilter == _filterAll ? null : _selectedFilter;

  Future<void> _openEditor({
    Remark? existing,
    required List<RecordCategory> categories,
  }) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => _RemarkEditDialog(
        existing: existing,
        categories: categories,
        defaultCategoryId: _selectedFilter == _filterAll
            ? noRef
            : _selectedFilter,
      ),
    );
    if (saved == true && mounted) {
      ref.invalidate(allBookCategoriesMapProvider);
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(content: Text(existing == null ? '已添加常用备注' : '已更新常用备注')),
        );
    }
  }

  Future<void> _deleteRemark(Remark item) async {
    final ok = await confirm(
      context,
      title: '确认删除常用备注？',
      message: '删除后“${item.content}”将不再出现在快捷备注联想中。',
      ok: '删除',
    );
    if (!ok || !mounted) return;
    try {
      final svc = await ref.read(templateRemarkServiceProvider.future);
      await svc.deleteRemark(
        commandId: _deleteIds.forPayload(<Object?>['del-remark', item.id]),
        id: item.id,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(content: Text('已删除常用备注')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

  Future<void> _toggleFrequentRemarks(
    DiyToolbarConfig current,
    bool enabled,
  ) async {
    if (_toggleBusy) return;
    setState(() => _toggleBusy = true);
    try {
      final service = await ref.read(billAttachmentServiceProvider.future);
      final next = current.setEnabled(
        DiyToolbarAction.frequentRemarks,
        enabled,
      );
      final seq = _toggleSeq++;
      await service.saveDiyToolbarConfig(
        commandId: _toggleIds.forPayload(<Object?>[
          'remarks-feature-toggle',
          seq,
          next.toJson(),
        ]),
        config: next,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(safeMessage(e))));
    } finally {
      if (mounted) setState(() => _toggleBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final diyConfig =
        ref.watch(diyToolbarConfigProvider).value ??
        DiyToolbarConfig.defaults();
    final remarksEnabled = diyConfig.isEnabled(
      DiyToolbarAction.frequentRemarks,
    );
    final bookId = ref.watch(currentBookIdProvider).value;
    final bookCategories = bookId == null
        ? const <RecordCategory>[]
        : (ref.watch(allCategoriesProvider(bookId)).value ??
              const <RecordCategory>[]);
    final allCatMap =
        ref.watch(allBookCategoriesMapProvider).value ??
        const <int, RecordCategory>{};
    final remarksAsync = ref.watch(allRemarksProvider(_queryCategoryId));

    final validFilterValues = <int>{
      _filterAll,
      noRef,
      for (final c in bookCategories) c.id,
    };
    final controlledFilter = validFilterValues.contains(_selectedFilter)
        ? _selectedFilter
        : _filterAll;

    return Scaffold(
      key: const Key('remarks_page'),
      appBar: AppBar(title: const Text('常用备注管理')),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('add_remark_fab'),
        onPressed: () => _openEditor(categories: bookCategories),
        icon: const Icon(Icons.add),
        label: const Text('新增备注'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            children: [
              Card(
                margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                elevation: 0,
                color: remarksEnabled
                    ? cs.primaryContainer.withAlpha(90)
                    : cs.surfaceContainerLow,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: cs.outlineVariant.withAlpha(120)),
                ),
                child: SwitchListTile(
                  key: const Key('remarks-feature-toggle'),
                  dense: true,
                  secondary: Icon(
                    Icons.comment_outlined,
                    color: remarksEnabled ? cs.primary : cs.onSurfaceVariant,
                  ),
                  title: const Text(
                    '记一笔常用备注联想与自动统计',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                  ),
                  subtitle: Text(
                    remarksEnabled
                        ? '已开启：记账时展示分类常用备注候选，并在保存账单时自动累计备注词频'
                        : '已关闭（默认）：记账时不展示备注候选条，也不自动统计新备注词频',
                    style: const TextStyle(fontSize: 12),
                  ),
                  value: remarksEnabled,
                  onChanged: _toggleBusy
                      ? null
                      : (enabled) => _toggleFrequentRemarks(diyConfig, enabled),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      flex: 5,
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: '筛选分类',
                          border: OutlineInputBorder(),
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<int>(
                            key: const Key('remarks_category_filter'),
                            isExpanded: true,
                            isDense: true,
                            value: controlledFilter,
                            items: [
                              const DropdownMenuItem<int>(
                                value: _filterAll,
                                child: Text('全部分类'),
                              ),
                              const DropdownMenuItem<int>(
                                value: noRef,
                                child: Text('通用备注'),
                              ),
                              for (final c in bookCategories)
                                DropdownMenuItem<int>(
                                  value: c.id,
                                  child: Text(c.name),
                                ),
                            ],
                            onChanged: (v) {
                              if (v == null) return;
                              setState(() => _selectedFilter = v);
                            },
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 6,
                      child: TextField(
                        key: const Key('remarks_search_input'),
                        controller: _searchController,
                        decoration: InputDecoration(
                          labelText: '搜索备注',
                          isDense: true,
                          border: const OutlineInputBorder(),
                          prefixIcon: const Icon(Icons.search, size: 20),
                          suffixIcon: _keyword.isEmpty
                              ? null
                              : IconButton(
                                  icon: const Icon(Icons.clear, size: 18),
                                  onPressed: () {
                                    _searchController.clear();
                                    setState(() => _keyword = '');
                                  },
                                ),
                        ),
                        onChanged: (v) => setState(() => _keyword = v.trim()),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: asyncBody(remarksAsync, (rows) {
                  final needle = _keyword.toLowerCase();
                  final filtered = needle.isEmpty
                      ? rows
                      : rows
                            .where(
                              (r) => r.content.toLowerCase().contains(needle),
                            )
                            .toList();
                  if (filtered.isEmpty) {
                    return Center(
                      key: const Key('remarks_empty_state'),
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          needle.isEmpty
                              ? '暂无常用备注，点击右下角“新增备注”添加'
                              : '未找到匹配的常用备注',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                    );
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
                    itemCount: filtered.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final item = filtered[index];
                      final catLabel = item.recordCatId == noRef
                          ? '通用备注'
                          : (allCatMap[item.recordCatId]?.name ??
                                '分类 #${item.recordCatId}');
                      return ListTile(
                        key: Key('remark_item_${item.id}'),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 2,
                        ),
                        title: Text(item.content),
                        subtitle: Text('$catLabel · 使用 ${item.usedTimes} 次'),
                        onTap: () => _openEditor(
                          existing: item,
                          categories: bookCategories,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              key: Key('edit_remark_${item.id}'),
                              tooltip: '编辑',
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: () => _openEditor(
                                existing: item,
                                categories: bookCategories,
                              ),
                            ),
                            IconButton(
                              key: Key('delete_remark_${item.id}'),
                              tooltip: '删除',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _deleteRemark(item),
                            ),
                          ],
                        ),
                      );
                    },
                  );
                }),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RemarkEditDialog extends ConsumerStatefulWidget {
  const _RemarkEditDialog({
    this.existing,
    required this.categories,
    required this.defaultCategoryId,
  });

  final Remark? existing;
  final List<RecordCategory> categories;
  final int defaultCategoryId;

  @override
  ConsumerState<_RemarkEditDialog> createState() => _RemarkEditDialogState();
}

class _RemarkEditDialogState extends ConsumerState<_RemarkEditDialog> {
  late final TextEditingController _contentController;
  late final TextEditingController _usedTimesController;
  final CommandIds _ids = CommandIds();
  late int _categoryId;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final old = widget.existing;
    _contentController = TextEditingController(text: old?.content ?? '');
    _usedTimesController = TextEditingController(
      text: '${old?.usedTimes ?? 0}',
    );
    _categoryId = old?.recordCatId ?? widget.defaultCategoryId;
  }

  @override
  void dispose() {
    _contentController.dispose();
    _usedTimesController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final usedText = _usedTimesController.text.trim();
      final parsedUsed = usedText.isEmpty ? 0 : int.tryParse(usedText);
      if (parsedUsed == null || parsedUsed < 0) {
        setState(() {
          _error = '使用次数须为非负整数';
          _busy = false;
        });
        return;
      }
      final svc = await ref.read(templateRemarkServiceProvider.future);
      final old = widget.existing;
      if (old == null) {
        final payload = <Object?>[
          'create',
          _contentController.text,
          _categoryId,
          parsedUsed,
        ];
        await svc.createRemark(
          commandId: _ids.forPayload(payload),
          content: _contentController.text,
          recordCatId: _categoryId,
          usedTimes: parsedUsed,
        );
      } else {
        final payload = <Object?>[
          'update',
          old.id,
          _contentController.text,
          _categoryId,
          parsedUsed,
        ];
        await svc.updateRemark(
          commandId: _ids.forPayload(payload),
          id: old.id,
          content: _contentController.text,
          recordCatId: _categoryId,
          usedTimes: parsedUsed,
        );
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = safeMessage(e);
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final categoryItems = <DropdownMenuItem<int>>[
      const DropdownMenuItem<int>(value: noRef, child: Text('通用备注（全部分类可用）')),
      for (final c in widget.categories)
        DropdownMenuItem<int>(value: c.id, child: Text(c.name)),
    ];
    final hasSelected =
        _categoryId == noRef ||
        widget.categories.any((c) => c.id == _categoryId);
    final effectiveCatId = hasSelected ? _categoryId : noRef;

    return AlertDialog(
      title: Text(widget.existing == null ? '新增常用备注' : '编辑常用备注'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const Key('remark_dialog_content_input'),
              controller: _contentController,
              enabled: !_busy,
              autofocus: true,
              maxLength: 200,
              decoration: const InputDecoration(
                labelText: '备注内容',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            InputDecorator(
              decoration: const InputDecoration(
                labelText: '归属分类',
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  key: const Key('remark_dialog_category_dropdown'),
                  isExpanded: true,
                  isDense: true,
                  value: effectiveCatId,
                  items: categoryItems,
                  onChanged: _busy
                      ? null
                      : (v) {
                          if (v != null) setState(() => _categoryId = v);
                        },
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('remark_dialog_used_times_input'),
              controller: _usedTimesController,
              enabled: !_busy,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '累计使用次数',
                border: OutlineInputBorder(),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                key: const Key('remark_dialog_error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('remark_dialog_cancel'),
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('remark_dialog_save'),
          onPressed: _busy ? null : _save,
          child: Text(_busy ? '保存中…' : '保存'),
        ),
      ],
    );
  }
}
