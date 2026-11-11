import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../data/tools/note_service.dart';
import '../../domain/rules/wish_note_rules.dart';

final noteServiceProvider = FutureProvider<NoteService>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return NoteService(db);
});

final class NoteSearchQuery extends Notifier<String> {
  @override
  String build() => '';

  void setQuery(String query) => state = query;
  void clear() => state = '';
}

final noteSearchQueryProvider = NotifierProvider<NoteSearchQuery, String>(
  NoteSearchQuery.new,
);

final allActiveNotesProvider = StreamProvider<List<Note>>((ref) async* {
  final service = await ref.watch(noteServiceProvider.future);
  yield* service.watchActiveNotes();
});

final filteredActiveNotesProvider = Provider<AsyncValue<List<Note>>>((ref) {
  final query = ref.watch(noteSearchQueryProvider);
  final notesAsync = ref.watch(allActiveNotesProvider);
  return notesAsync.whenData(
    (notes) => filterNotesByQuery(
      notes,
      query,
      titleOf: (n) => n.title,
      contentOf: (n) => n.content,
    ),
  );
});

final trashedNotesProvider = StreamProvider<List<Note>>((ref) async* {
  final service = await ref.watch(noteServiceProvider.future);
  yield* service.watchTrashedNotes();
});

final noteProvider = StreamProvider.family<Note?, int>((ref, id) async* {
  final service = await ref.watch(noteServiceProvider.future);
  yield* service.watchNote(id);
});
