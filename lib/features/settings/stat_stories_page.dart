import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../app/providers.dart';
import '../../core/failure.dart';
import '../../data/db/database.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/app_settings_rules.dart';
import 'settings_providers.dart';

const _uuid = Uuid();

String _formatDateMs(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

int _startOfDayMs(DateTime d) =>
    DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;

int _endOfDayMs(DateTime d) =>
    DateTime(d.year, d.month, d.day, 23, 59, 59, 999).millisecondsSinceEpoch;

/// `stat_story` management page (`F-030` / `F-038`): book filter, CRUD, and
/// exact `Money`/`BigInt` period narrative generation.
class StatStoriesPage extends ConsumerStatefulWidget {
  const StatStoriesPage({super.key});

  @override
  ConsumerState<StatStoriesPage> createState() => _StatStoriesPageState();
}

class _StatStoriesPageState extends ConsumerState<StatStoriesPage> {
  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _openEditor({
    StatStory? existing,
    required List<AccountBook> books,
  }) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _StatStoryEditorDialog(existing: existing, books: books),
    );
    if (saved == true) {
      _toast(existing == null ? '已保存统计故事' : '已更新统计故事');
    }
  }

  Future<void> _confirmDelete(StatStory item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除统计故事'),
        content: const Text('确定删除这条统计故事回顾吗？删除后不会影响任何账单流水。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('stat_story_confirm_delete_button'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final svc = await ref.read(statStoryServiceProvider.future);
      await svc.deleteStory(commandId: _uuid.v4(), id: item.id);
      _toast('已删除统计故事');
    } on Failure catch (f) {
      _toast(f.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final booksAsync = ref.watch(booksProvider);
    final selectedBookId = ref.watch(statStoriesBookFilterProvider);
    final storiesAsync = ref.watch(statStoriesProvider);
    final books = booksAsync.asData?.value ?? const <AccountBook>[];
    final bookNameById = <int, String>{for (final b in books) b.id: b.name};
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('统计故事')),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('stat_story_add_fab'),
        onPressed: () => _openEditor(books: books),
        icon: const Icon(Icons.add),
        label: const Text('新增故事'),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (books.isNotEmpty)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  ChoiceChip(
                    key: const Key('stat_story_filter_all'),
                    label: const Text('全部账本'),
                    selected: selectedBookId == null,
                    onSelected: (_) => ref
                        .read(statStoriesBookFilterProvider.notifier)
                        .selectBook(null),
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    key: const Key('stat_story_filter_global'),
                    label: const Text('跨账本汇总'),
                    selected: selectedBookId == noRef,
                    onSelected: (_) => ref
                        .read(statStoriesBookFilterProvider.notifier)
                        .selectBook(noRef),
                  ),
                  for (final b in books) ...[
                    const SizedBox(width: 8),
                    ChoiceChip(
                      key: Key('stat_story_filter_book_${b.id}'),
                      label: Text(b.name),
                      selected: selectedBookId == b.id,
                      onSelected: (_) => ref
                          .read(statStoriesBookFilterProvider.notifier)
                          .selectBook(b.id),
                    ),
                  ],
                ],
              ),
            ),
          Expanded(
            child: storiesAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (err, _) => Center(child: Text('读取失败：$err')),
              data: (stories) {
                if (stories.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.auto_stories_outlined,
                            size: 52,
                            color: scheme.outline,
                          ),
                          const SizedBox(height: 12),
                          Text('暂无统计故事', style: theme.textTheme.titleMedium),
                          const SizedBox(height: 4),
                          Text(
                            '点击右下角“新增故事”，可根据所选账期自动汇总收支摘要并编辑留存。',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }

                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 88),
                  itemCount: stories.length,
                  itemBuilder: (context, index) {
                    final item = stories[index];
                    final bookLabel = item.bookId == noRef
                        ? '全部账本'
                        : (bookNameById[item.bookId] ?? '账本 #${item.bookId}');
                    final rangeLabel =
                        '${_formatDateMs(item.sdate)} ~ ${_formatDateMs(item.edate)}';
                    final sectionTitle =
                        (item.dsection != null &&
                            item.dsection!.trim().isNotEmpty)
                        ? item.dsection!.trim()
                        : rangeLabel;

                    return Card(
                      key: Key('stat_story_card_${item.id}'),
                      margin: const EdgeInsets.only(bottom: 12),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 8, 14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: scheme.primaryContainer,
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Text(
                                    bookLabel,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: scheme.onPrimaryContainer,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    sectionTitle,
                                    style: theme.textTheme.titleSmall?.copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                IconButton(
                                  key: Key('stat_story_edit_${item.id}'),
                                  tooltip: '编辑',
                                  icon: const Icon(
                                    Icons.edit_outlined,
                                    size: 20,
                                  ),
                                  onPressed: () =>
                                      _openEditor(existing: item, books: books),
                                ),
                                IconButton(
                                  key: Key('stat_story_delete_${item.id}'),
                                  tooltip: '删除',
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    size: 20,
                                  ),
                                  onPressed: () => _confirmDelete(item),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: Text(
                                item.story,
                                style: theme.textTheme.bodyMedium,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '统计区间：$rangeLabel',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _StatStoryEditorDialog extends ConsumerStatefulWidget {
  const _StatStoryEditorDialog({this.existing, required this.books});

  final StatStory? existing;
  final List<AccountBook> books;

  @override
  ConsumerState<_StatStoryEditorDialog> createState() =>
      _StatStoryEditorDialogState();
}

class _StatStoryEditorDialogState
    extends ConsumerState<_StatStoryEditorDialog> {
  late final TextEditingController _sectionCtrl;
  late final TextEditingController _storyCtrl;
  late int _bookId;
  late DateTime _startDate;
  late DateTime _endDate;
  String? _errorText;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    if (existing != null) {
      _bookId = existing.bookId;
      _startDate = DateTime.fromMillisecondsSinceEpoch(existing.sdate);
      _endDate = DateTime.fromMillisecondsSinceEpoch(existing.edate);
      _sectionCtrl = TextEditingController(text: existing.dsection ?? '');
      _storyCtrl = TextEditingController(text: existing.story);
    } else {
      final dbNowMs = ref.read(databaseProvider).asData?.value.nowMs();
      final now = dbNowMs != null
          ? DateTime.fromMillisecondsSinceEpoch(dbNowMs)
          : DateTime.now();
      _bookId = widget.books.isNotEmpty ? widget.books.first.id : noRef;
      _startDate = DateTime(now.year, now.month, 1);
      _endDate = DateTime(now.year, now.month + 1, 0);
      _sectionCtrl = TextEditingController(
        text: '${now.year}年${now.month.toString().padLeft(2, '0')}月',
      );
      _storyCtrl = TextEditingController();
    }
  }

  @override
  void dispose() {
    _sectionCtrl.dispose();
    _storyCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickStartDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) {
      setState(() {
        _startDate = picked;
        if (_endDate.isBefore(_startDate)) {
          _endDate = _startDate;
        }
      });
    }
  }

  Future<void> _pickEndDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _endDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) {
      setState(() {
        _endDate = picked;
        if (_startDate.isAfter(_endDate)) {
          _startDate = _endDate;
        }
      });
    }
  }

  Future<void> _generateNarrative() async {
    setState(() {
      _busy = true;
      _errorText = null;
    });
    try {
      final svc = await ref.read(statStoryServiceProvider.future);
      final generated = await svc.generatePeriodNarrative(
        bookId: _bookId,
        startMs: _startOfDayMs(_startDate),
        endMs: _endOfDayMs(_endDate),
        sectionLabel: _sectionCtrl.text,
      );
      if (mounted) {
        setState(() {
          _storyCtrl.text = generated;
        });
      }
    } on Failure catch (f) {
      if (mounted) setState(() => _errorText = f.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _errorText = null;
    });
    try {
      final svc = await ref.read(statStoryServiceProvider.future);
      await svc.saveStory(
        commandId: _uuid.v4(),
        id: widget.existing?.id,
        draft: StatStoryDraft(
          story: _storyCtrl.text,
          bookId: _bookId,
          sdate: _startOfDayMs(_startDate),
          edate: _endOfDayMs(_endDate),
          dsection: _sectionCtrl.text,
        ),
      );
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } on Failure catch (f) {
      if (mounted) setState(() => _errorText = f.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.existing != null;
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(isEditing ? '编辑统计故事' : '新增统计故事'),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('统计范围账本', style: theme.textTheme.labelMedium),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  ChoiceChip(
                    key: const Key('stat_story_editor_book_all'),
                    label: const Text('全部账本'),
                    selected: _bookId == noRef,
                    onSelected: _busy
                        ? null
                        : (_) => setState(() => _bookId = noRef),
                  ),
                  for (final b in widget.books)
                    ChoiceChip(
                      key: Key('stat_story_editor_book_${b.id}'),
                      label: Text(b.name),
                      selected: _bookId == b.id,
                      onSelected: _busy
                          ? null
                          : (_) => setState(() => _bookId = b.id),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('stat_story_pick_sdate_button'),
                      onPressed: _busy ? null : _pickStartDate,
                      icon: const Icon(Icons.calendar_today_outlined, size: 16),
                      label: Text(
                        '起 ${_formatDateMs(_startOfDayMs(_startDate))}',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('stat_story_pick_edate_button'),
                      onPressed: _busy ? null : _pickEndDate,
                      icon: const Icon(Icons.event_outlined, size: 16),
                      label: Text('止 ${_formatDateMs(_endOfDayMs(_endDate))}'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('stat_story_dsection_input'),
                controller: _sectionCtrl,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: '账期标题（可选，如 2026年11月）',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                key: const Key('stat_story_generate_button'),
                onPressed: _busy ? null : _generateNarrative,
                icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                label: const Text('根据本期账单自动生成摘要'),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const Key('stat_story_content_input'),
                controller: _storyCtrl,
                enabled: !_busy,
                maxLines: 5,
                maxLength: 2000,
                decoration: const InputDecoration(
                  labelText: '故事内容',
                  hintText: '写下本期的收支感悟，或点击上方按钮从真实账单自动汇总……',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_errorText != null) ...[
                const SizedBox(height: 6),
                Text(
                  _errorText!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('stat_story_save_button'),
          onPressed: _busy ? null : _save,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
