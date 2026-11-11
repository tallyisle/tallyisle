import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../data/db/database.dart';
import '../../domain/rules/wish_note_rules.dart';
import '../common/common.dart';
import 'note_editor_page.dart';
import 'note_providers.dart';
import 'note_trash_page.dart';

const _uuid = Uuid();

/// Notes management page (`F-015`, original route `/bkp/NAct`).
class NotesPage extends ConsumerStatefulWidget {
  const NotesPage({super.key});

  @override
  ConsumerState<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends ConsumerState<NotesPage> {
  late final TextEditingController _searchCtrl;

  @override
  void initState() {
    super.initState();
    _searchCtrl = TextEditingController(
      text: ref.read(noteSearchQueryProvider),
    );
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _openEditor({int? noteId}) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => NoteEditorPage(noteId: noteId)),
    );
  }

  Future<void> _openTrash() async {
    await Navigator.of(
      context,
    ).push<void>(MaterialPageRoute(builder: (_) => const NoteTrashPage()));
  }

  Future<void> _moveToTrash(Note note) async {
    try {
      final service = await ref.read(noteServiceProvider.future);
      await service.moveToTrash(commandId: _uuid.v4(), id: note.id);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('便签已移入回收站')));
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
    final query = ref.watch(noteSearchQueryProvider);
    final notesAsync = ref.watch(filteredActiveNotesProvider);
    final trashCount = ref.watch(trashedNotesProvider).value?.length ?? 0;

    return Scaffold(
      key: const Key('notes_page'),
      appBar: AppBar(
        title: const Text('便签'),
        actions: [
          TextButton.icon(
            key: const Key('open_note_trash_button'),
            onPressed: _openTrash,
            icon: const Icon(Icons.delete_sweep_outlined),
            label: Text(trashCount > 0 ? '回收站 ($trashCount)' : '回收站'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              key: const Key('note_search_input'),
              controller: _searchCtrl,
              onChanged: (value) =>
                  ref.read(noteSearchQueryProvider.notifier).setQuery(value),
              decoration: InputDecoration(
                hintText: '搜索便签标题或正文…',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: query.isEmpty
                    ? null
                    : IconButton(
                        key: const Key('clear_note_search_button'),
                        tooltip: '清除搜索',
                        onPressed: () {
                          _searchCtrl.clear();
                          ref.read(noteSearchQueryProvider.notifier).clear();
                        },
                        icon: const Icon(Icons.clear),
                      ),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          Expanded(
            child: asyncBody(notesAsync, (notes) {
              if (notes.isEmpty) {
                final searching = query.trim().isNotEmpty;
                return Center(
                  key: Key(
                    searching
                        ? 'notes_search_empty_state'
                        : 'notes_empty_state',
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      searching ? '未找到匹配的便签' : '还没有便签，点击右下角记录灵感或备忘',
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              }

              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 88),
                itemCount: notes.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final note = notes[index];
                  return _NoteCard(
                    note: note,
                    onTap: () => _openEditor(noteId: note.id),
                    onMoveToTrash: () => _moveToTrash(note),
                  );
                },
              );
            }),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('add_note_fab'),
        onPressed: _openEditor,
        icon: const Icon(Icons.edit_note),
        label: const Text('新建便签'),
      ),
    );
  }
}

class _NoteCard extends StatelessWidget {
  const _NoteCard({
    required this.note,
    required this.onTap,
    required this.onMoveToTrash,
  });

  final Note note;
  final VoidCallback onTap;
  final VoidCallback onMoveToTrash;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final displayTitle = resolveNoteDisplayTitle(
      title: note.title,
      content: note.content,
    );
    final snippet = buildNoteSnippet(note.content);

    return Card(
      key: Key('note_card_${note.id}'),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      displayTitle,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      snippet,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      formatDateTime(
                        DateTime.fromMillisecondsSinceEpoch(note.updateTime),
                      ),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: cs.outline,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                key: Key('trash_note_${note.id}'),
                tooltip: '移入回收站',
                onPressed: onMoveToTrash,
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
