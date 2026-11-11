import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../../core/failure.dart';
import '../../domain/rules/wish_note_rules.dart';
import '../db/database.dart';
import '../db/failures.dart';

/// Data access & idempotent write boundary for Notes & Recycle Bin (`F-015`, ADR-009).
final class NoteService {
  NoteService(this.db);
  final AppDatabase db;

  int _now() => db.nowMs();

  Future<T> _command<T>(
    String commandId,
    List<Object?> payload,
    Future<String> Function() body,
    T Function(String resultId) result,
  ) async {
    if (commandId.isEmpty || commandId.length > 128) {
      throw const Failure(FailureCode.validation, '提交标识无效');
    }
    final hash = sha256.convert(utf8.encode(jsonEncode(payload))).toString();
    return guardDatabase(
      () => db.transaction(() async {
        final previous = await (db.select(
          db.writeCommands,
        )..where((t) => t.commandId.equals(commandId))).getSingleOrNull();
        if (previous != null) {
          if (previous.payloadHash != hash) {
            throw const Failure(FailureCode.conflict, '同一提交标识的内容发生变化');
          }
          return result(previous.resultId);
        }
        final id = await body();
        await db
            .into(db.writeCommands)
            .insert(
              WriteCommandsCompanion.insert(
                commandId: commandId,
                payloadHash: hash,
                resultId: id,
                committedAt: _now(),
              ),
            );
        return result(id);
      }),
    );
  }

  /// Creates an active note (`trashTime = 0`) and returns its autoIncrement [id].
  Future<int> createNote({
    required String commandId,
    String? title,
    required String content,
  }) => _command(commandId, ['create-note-v1', title, content], () async {
    final validated = validateNoteInput(title: title, content: content);
    final now = _now();
    final id = await db
        .into(db.notes)
        .insert(
          NotesCompanion.insert(
            title: Value(validated.title),
            content: validated.content,
            createTime: now,
            updateTime: now,
            trashTime: const Value(activeNoteTrashTime),
          ),
        );
    return '$id';
  }, int.parse);

  /// Updates an active note's [title] and [content], refreshing `updateTime`.
  Future<void> updateNote({
    required String commandId,
    required int id,
    String? title,
    required String content,
  }) => _command(commandId, ['update-note-v1', id, title, content], () async {
    final validated = validateNoteInput(title: title, content: content);
    final existing = await (db.select(
      db.notes,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (existing == null) {
      throw const Failure(FailureCode.conflict, '便签不存在或已删除');
    }
    if (isNoteTrashed(existing.trashTime)) {
      throw const Failure(FailureCode.validation, '回收站中的便签请先恢复再编辑');
    }
    await (db.update(db.notes)..where((t) => t.id.equals(id))).write(
      NotesCompanion(
        title: Value(validated.title),
        content: Value(validated.content),
        updateTime: Value(_now()),
        trashTime: const Value(activeNoteTrashTime),
      ),
    );
    return '$id';
  }, (_) {});

  /// Moves a note into the recycle bin (`trashTime > 0`), preserving `updateTime`.
  Future<void> moveToTrash({required String commandId, required int id}) =>
      _command(commandId, ['move-note-trash-v1', id], () async {
        final existing = await (db.select(
          db.notes,
        )..where((t) => t.id.equals(id))).getSingleOrNull();
        if (existing == null) {
          throw const Failure(FailureCode.conflict, '便签不存在或已删除');
        }
        if (isNoteActive(existing.trashTime)) {
          final rawNow = _now();
          final trashedAt = rawNow > 0 ? rawNow : 1;
          await (db.update(db.notes)..where((t) => t.id.equals(id))).write(
            NotesCompanion(trashTime: Value(trashedAt)),
          );
        }
        return '$id';
      }, (_) {});

  /// Restores a trashed note back to active (`trashTime = 0`).
  Future<void> restoreFromTrash({required String commandId, required int id}) =>
      _command(commandId, ['restore-note-trash-v1', id], () async {
        final existing = await (db.select(
          db.notes,
        )..where((t) => t.id.equals(id))).getSingleOrNull();
        if (existing == null) {
          throw const Failure(FailureCode.conflict, '便签不存在或已彻底删除');
        }
        await (db.update(db.notes)..where((t) => t.id.equals(id))).write(
          const NotesCompanion(trashTime: Value(activeNoteTrashTime)),
        );
        return '$id';
      }, (_) {});

  /// Permanently deletes a single note row from SQLite.
  Future<void> deletePermanently({
    required String commandId,
    required int id,
  }) => _command(commandId, ['delete-note-perm-v1', id], () async {
    await (db.delete(db.notes)..where((t) => t.id.equals(id))).go();
    return '$id';
  }, (_) {});

  /// Permanently deletes all trashed notes (`trashTime > 0`), keeping active notes intact.
  /// Returns the count of deleted rows.
  Future<int> emptyTrash({required String commandId}) =>
      _command(commandId, ['empty-note-trash-v1'], () async {
        final deleted = await (db.delete(
          db.notes,
        )..where((t) => t.trashTime.isBiggerThanValue(0))).go();
        return '$deleted';
      }, int.parse);

  // ---- Read / Stream queries ----

  Stream<List<Note>> watchActiveNotes({String query = ''}) =>
      (db.select(db.notes)..where((t) => t.trashTime.isSmallerOrEqualValue(0)))
          .watch()
          .map((rows) {
            final sorted = sortActiveNotes(
              rows,
              updateTimeOf: (n) => n.updateTime,
              createTimeOf: (n) => n.createTime,
              idOf: (n) => n.id,
            );
            return filterNotesByQuery(
              sorted,
              query,
              titleOf: (n) => n.title,
              contentOf: (n) => n.content,
            );
          });

  Stream<List<Note>> watchTrashedNotes() =>
      (db.select(
        db.notes,
      )..where((t) => t.trashTime.isBiggerThanValue(0))).watch().map(
        (rows) => sortTrashedNotes(
          rows,
          trashTimeOf: (n) => n.trashTime,
          updateTimeOf: (n) => n.updateTime,
          idOf: (n) => n.id,
        ),
      );

  Stream<Note?> watchNote(int id) =>
      (db.select(db.notes)..where((t) => t.id.equals(id))).watchSingleOrNull();

  Future<Note?> getNote(int id) => guardDatabase(
    () =>
        (db.select(db.notes)..where((t) => t.id.equals(id))).getSingleOrNull(),
  );

  Future<List<Note>> getActiveNotes({String query = ''}) =>
      guardDatabase(() async {
        final rows = await (db.select(
          db.notes,
        )..where((t) => t.trashTime.isSmallerOrEqualValue(0))).get();
        final sorted = sortActiveNotes(
          rows,
          updateTimeOf: (n) => n.updateTime,
          createTimeOf: (n) => n.createTime,
          idOf: (n) => n.id,
        );
        return filterNotesByQuery(
          sorted,
          query,
          titleOf: (n) => n.title,
          contentOf: (n) => n.content,
        );
      });

  Future<List<Note>> getTrashedNotes() => guardDatabase(() async {
    final rows = await (db.select(
      db.notes,
    )..where((t) => t.trashTime.isBiggerThanValue(0))).get();
    return sortTrashedNotes(
      rows,
      trashTimeOf: (n) => n.trashTime,
      updateTimeOf: (n) => n.updateTime,
      idOf: (n) => n.id,
    );
  });
}
