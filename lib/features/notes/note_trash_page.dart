import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../data/db/database.dart';
import '../../domain/rules/wish_note_rules.dart';
import '../common/common.dart';
import 'note_providers.dart';

const _uuid = Uuid();

/// Recycle bin page for trashed notes (`F-015`, original route `/bkp/NTAct`).
class NoteTrashPage extends ConsumerWidget {
  const NoteTrashPage({super.key});

  Future<void> _restore(BuildContext context, WidgetRef ref, Note note) async {
    try {
      final service = await ref.read(noteServiceProvider.future);
      await service.restoreFromTrash(commandId: _uuid.v4(), id: note.id);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('便签已恢复')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
      }
    }
  }

  Future<void> _deletePermanently(
    BuildContext context,
    WidgetRef ref,
    Note note,
  ) async {
    final displayTitle = resolveNoteDisplayTitle(
      title: note.title,
      content: note.content,
    );
    final ok = await confirm(
      context,
      title: '确认彻底删除？',
      message: '「$displayTitle」将被永久删除，无法恢复。',
      ok: '彻底删除',
    );
    if (!ok || !context.mounted) return;
    try {
      final service = await ref.read(noteServiceProvider.future);
      await service.deletePermanently(commandId: _uuid.v4(), id: note.id);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('便签已彻底删除')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
      }
    }
  }

  Future<void> _emptyTrash(
    BuildContext context,
    WidgetRef ref,
    int count,
  ) async {
    final ok = await confirm(
      context,
      title: '确认清空回收站？',
      message: '回收站内的 $count 条便签将被永久删除，无法恢复。',
      ok: '清空',
    );
    if (!ok || !context.mounted) return;
    try {
      final service = await ref.read(noteServiceProvider.future);
      final removed = await service.emptyTrash(commandId: _uuid.v4());
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已清空回收站（共删除 $removed 条）')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trashedAsync = ref.watch(trashedNotesProvider);
    final trashedList = trashedAsync.value ?? const <Note>[];

    return Scaffold(
      key: const Key('note_trash_page'),
      appBar: AppBar(
        title: const Text('便签回收站'),
        actions: [
          TextButton.icon(
            key: const Key('empty_note_trash_button'),
            onPressed: trashedList.isEmpty
                ? null
                : () => _emptyTrash(context, ref, trashedList.length),
            icon: const Icon(Icons.delete_forever_outlined),
            label: const Text('清空回收站'),
          ),
        ],
      ),
      body: asyncBody(trashedAsync, (notes) {
        if (notes.isEmpty) {
          return const Center(
            key: Key('note_trash_empty_state'),
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('回收站为空', textAlign: TextAlign.center),
            ),
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          itemCount: notes.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final note = notes[index];
            return _TrashedNoteCard(
              note: note,
              onRestore: () => _restore(context, ref, note),
              onDeletePermanently: () => _deletePermanently(context, ref, note),
            );
          },
        );
      }),
    );
  }
}

class _TrashedNoteCard extends StatelessWidget {
  const _TrashedNoteCard({
    required this.note,
    required this.onRestore,
    required this.onDeletePermanently,
  });

  final Note note;
  final VoidCallback onRestore;
  final VoidCallback onDeletePermanently;

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
      key: Key('trash_note_card_${note.id}'),
      child: Padding(
        padding: const EdgeInsets.all(14),
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
            Row(
              children: [
                Expanded(
                  child: Text(
                    '删除于 ${formatDateTime(DateTime.fromMillisecondsSinceEpoch(note.trashTime))}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: cs.outline,
                    ),
                  ),
                ),
                TextButton.icon(
                  key: Key('restore_note_${note.id}'),
                  onPressed: onRestore,
                  icon: const Icon(Icons.restore_from_trash_outlined, size: 18),
                  label: const Text('恢复'),
                ),
                TextButton.icon(
                  key: Key('delete_note_permanently_${note.id}'),
                  onPressed: onDeletePermanently,
                  style: TextButton.styleFrom(foregroundColor: cs.error),
                  icon: const Icon(Icons.delete_forever_outlined, size: 18),
                  label: const Text('彻底删除'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
