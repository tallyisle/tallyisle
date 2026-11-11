import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/failure.dart';
import '../../core/money.dart';
import '../../domain/rules/wish_note_rules.dart';
import '../db/database.dart';
import '../db/failures.dart';

const _uuid = Uuid();

/// Data access & idempotent write boundary for Wish List (`F-014`, ADR-009).
final class WishService {
  WishService(this.db);
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

  /// Creates an unrealized wish with a fresh UUID v4 primary key.
  Future<String> createWish({
    required String commandId,
    required String content,
    required Money value,
    int targetDate = unsetWishTargetDate,
    String? icon,
    int? sort,
  }) => _command(
    commandId,
    ['create-wish-v1', content, value.toJson(), targetDate, icon, sort],
    () async {
      final validated = validateWishInput(
        content: content,
        value: value,
        targetDateMs: targetDate,
        icon: icon,
        sort: sort,
      );
      final id = _uuid.v4();
      final int resolvedSort;
      if (validated.sort != null) {
        resolvedSort = validated.sort!;
      } else {
        final existingRows = await db.select(db.wishes).get();
        resolvedSort = nextTopWishSort(existingRows.map((w) => w.sort));
      }
      await db
          .into(db.wishes)
          .insert(
            WishesCompanion.insert(
              id: id,
              content: validated.content,
              valueMinor: validated.valueMinor,
              createDate: _now(),
              isRealized: const Value(false),
              realizedDate: const Value(unrealizedWishDate),
              sort: Value(resolvedSort),
              icon: Value(validated.icon),
              targetDate: Value(validated.targetDateMs),
            ),
          );
      return id;
    },
    (id) => id,
  );

  /// Updates editable fields on an existing wish while preserving realized state.
  Future<void> updateWish({
    required String commandId,
    required String id,
    required String content,
    required Money value,
    int targetDate = unsetWishTargetDate,
    String? icon,
    int? sort,
  }) => _command(
    commandId,
    ['update-wish-v1', id, content, value.toJson(), targetDate, icon, sort],
    () async {
      if (id.trim().isEmpty) {
        throw const Failure(FailureCode.validation, '心愿标识无效');
      }
      final validated = validateWishInput(
        content: content,
        value: value,
        targetDateMs: targetDate,
        icon: icon,
        sort: sort,
      );
      final existing = await (db.select(
        db.wishes,
      )..where((t) => t.id.equals(id))).getSingleOrNull();
      if (existing == null) {
        throw const Failure(FailureCode.conflict, '心愿不存在或已删除');
      }
      final safeRealizedDate = normalizeWishRealizedDate(
        isRealized: existing.isRealized,
        realizedDateMs: existing.realizedDate,
        fallbackNowMs: _now(),
      );
      await (db.update(db.wishes)..where((t) => t.id.equals(id))).write(
        WishesCompanion(
          content: Value(validated.content),
          valueMinor: Value(validated.valueMinor),
          targetDate: Value(validated.targetDateMs),
          icon: Value(validated.icon),
          sort: Value(validated.sort ?? existing.sort),
          realizedDate: Value(safeRealizedDate),
        ),
      );
      return id;
    },
    (_) {},
  );

  /// Marks a wish realized (`realizedDate > 0`) or unrealized (`realizedDate = 0`).
  Future<void> setWishRealized({
    required String commandId,
    required String id,
    required bool isRealized,
    int? realizedDateMs,
  }) => _command(
    commandId,
    ['set-wish-realized-v1', id, isRealized, realizedDateMs],
    () async {
      if (id.trim().isEmpty) {
        throw const Failure(FailureCode.validation, '心愿标识无效');
      }
      final existing = await (db.select(
        db.wishes,
      )..where((t) => t.id.equals(id))).getSingleOrNull();
      if (existing == null) {
        throw const Failure(FailureCode.conflict, '心愿不存在或已删除');
      }
      final nextRealizedDate = normalizeWishRealizedDate(
        isRealized: isRealized,
        realizedDateMs: realizedDateMs,
        fallbackNowMs: _now(),
      );
      await (db.update(db.wishes)..where((t) => t.id.equals(id))).write(
        WishesCompanion(
          isRealized: Value(isRealized),
          realizedDate: Value(nextRealizedDate),
        ),
      );
      return id;
    },
    (_) {},
  );

  /// Marks an unrealized wish as realized.
  Future<void> markRealized({
    required String commandId,
    required String id,
    int? realizedDateMs,
  }) => setWishRealized(
    commandId: commandId,
    id: id,
    isRealized: true,
    realizedDateMs: realizedDateMs,
  );

  /// Reopens a realized wish back to unrealized (`realizedDate = 0`).
  Future<void> reopenWish({required String commandId, required String id}) =>
      setWishRealized(commandId: commandId, id: id, isRealized: false);

  /// Updates custom sort indices in [orderedIds] order (`0..n-1`).
  Future<void> reorderWishes({
    required String commandId,
    required List<String> orderedIds,
  }) => _command(commandId, ['reorder-wishes-v1', orderedIds], () async {
    for (var i = 0; i < orderedIds.length; i++) {
      await (db.update(db.wishes)..where((t) => t.id.equals(orderedIds[i])))
          .write(WishesCompanion(sort: Value(i)));
    }
    return '${orderedIds.length}';
  }, (_) {});

  /// Physically deletes a wish by [id].
  Future<void> deleteWish({required String commandId, required String id}) =>
      _command(commandId, ['delete-wish-v1', id], () async {
        if (id.trim().isEmpty) {
          throw const Failure(FailureCode.validation, '心愿标识无效');
        }
        await (db.delete(db.wishes)..where((t) => t.id.equals(id))).go();
        return id;
      }, (_) {});

  // ---- Read / Stream queries ----

  Stream<List<Wish>> watchAllWishes() => db
      .select(db.wishes)
      .watch()
      .map(
        (rows) => sortWishes(
          rows,
          isRealizedOf: (w) => w.isRealized,
          realizedDateOf: (w) => w.realizedDate,
          sortOf: (w) => w.sort,
          createDateOf: (w) => w.createDate,
          idOf: (w) => w.id,
        ),
      );

  Stream<List<Wish>> watchUnrealizedWishes() =>
      (db.select(
        db.wishes,
      )..where((t) => t.isRealized.equals(false))).watch().map(
        (rows) => sortUnrealizedWishes(
          rows,
          sortOf: (w) => w.sort,
          createDateOf: (w) => w.createDate,
          idOf: (w) => w.id,
        ),
      );

  Stream<List<Wish>> watchRealizedWishes() =>
      (db.select(
        db.wishes,
      )..where((t) => t.isRealized.equals(true))).watch().map(
        (rows) => sortRealizedWishes(
          rows,
          realizedDateOf: (w) => w.realizedDate,
          sortOf: (w) => w.sort,
          createDateOf: (w) => w.createDate,
          idOf: (w) => w.id,
        ),
      );

  Stream<Wish?> watchWish(String id) =>
      (db.select(db.wishes)..where((t) => t.id.equals(id))).watchSingleOrNull();

  Future<Wish?> getWish(String id) => guardDatabase(
    () =>
        (db.select(db.wishes)..where((t) => t.id.equals(id))).getSingleOrNull(),
  );

  Future<List<Wish>> getUnrealizedWishes() => guardDatabase(() async {
    final rows = await (db.select(
      db.wishes,
    )..where((t) => t.isRealized.equals(false))).get();
    return sortUnrealizedWishes(
      rows,
      sortOf: (w) => w.sort,
      createDateOf: (w) => w.createDate,
      idOf: (w) => w.id,
    );
  });

  Future<List<Wish>> getRealizedWishes() => guardDatabase(() async {
    final rows = await (db.select(
      db.wishes,
    )..where((t) => t.isRealized.equals(true))).get();
    return sortRealizedWishes(
      rows,
      realizedDateOf: (w) => w.realizedDate,
      sortOf: (w) => w.sort,
      createDateOf: (w) => w.createDate,
      idOf: (w) => w.id,
    );
  });

  Future<WishSummary> getSummary() => guardDatabase(() async {
    final rows = await db.select(db.wishes).get();
    return summarizeWishes(
      rows,
      isRealizedOf: (w) => w.isRealized,
      valueMinorOf: (w) => w.valueMinor,
    );
  });
}
