import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/failure.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/app_settings_rules.dart';
import '../../domain/rules/income_expense.dart';
import '../db/database.dart';
import '../db/failures.dart';
import '../repo/ledger_queries.dart';

const _uuid = Uuid();

/// CRUD and local period-narrative generation service for `stat_story`
/// (`F-030` / `F-038`, `ADR-009`, zero `double` math).
final class StatStoryService {
  StatStoryService(this.db);
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

  /// Watches `stat_story` rows ordered by `edate DESC, sdate DESC, id DESC`.
  /// When [bookId] is provided, filters to that book.
  Stream<List<StatStory>> watchStories({int? bookId}) {
    final query = db.select(db.statStories);
    if (bookId != null) {
      query.where((t) => t.bookId.equals(bookId));
    }
    query.orderBy([
      (t) => OrderingTerm.desc(t.edate),
      (t) => OrderingTerm.desc(t.sdate),
      (t) => OrderingTerm.desc(t.id),
    ]);
    return query.watch();
  }

  /// Reads `stat_story` rows snapshot.
  Future<List<StatStory>> getStories({int? bookId}) => guardDatabase(() {
    final query = db.select(db.statStories);
    if (bookId != null) {
      query.where((t) => t.bookId.equals(bookId));
    }
    query.orderBy([
      (t) => OrderingTerm.desc(t.edate),
      (t) => OrderingTerm.desc(t.sdate),
      (t) => OrderingTerm.desc(t.id),
    ]);
    return query.get();
  });

  /// Creates ([id] == null) or updates a `stat_story` row (`ADR-009`).
  Future<String> saveStory({
    required String commandId,
    String? id,
    required StatStoryDraft draft,
  }) {
    final clean = draft.validated();
    return _command(
      commandId,
      ['stat-story-save-v1', id, ...clean.payload],
      () async {
        if (clean.bookId != noRef) {
          final book = await (db.select(
            db.accountBooks,
          )..where((t) => t.id.equals(clean.bookId))).getSingleOrNull();
          if (book == null) {
            throw const Failure(FailureCode.validation, '所选账本不存在');
          }
        }
        if (id != null) {
          final existing = await (db.select(
            db.statStories,
          )..where((t) => t.id.equals(id))).getSingleOrNull();
          if (existing == null) {
            throw const Failure(FailureCode.conflict, '统计故事不存在或已删除');
          }
        }

        final targetId = id ?? _uuid.v4();
        await db
            .into(db.statStories)
            .insertOnConflictUpdate(
              StatStoriesCompanion(
                id: Value(targetId),
                story: Value(clean.story),
                bookId: Value(clean.bookId),
                sdate: Value(clean.sdate),
                edate: Value(clean.edate),
                dsection: Value(clean.dsection),
              ),
            );
        return targetId;
      },
      (savedId) => savedId,
    );
  }

  /// Deletes a `stat_story` row by [id] (`ADR-009`).
  Future<void> deleteStory({required String commandId, required String id}) =>
      _command(commandId, ['stat-story-delete-v1', id], () async {
        await (db.delete(db.statStories)..where((t) => t.id.equals(id))).go();
        return id;
      }, (_) {});

  /// Generates a ready-to-edit narrative string from local bills in
  /// `[startMs, endMs]` using exact `BigInt`/`Money` aggregation.
  Future<String> generatePeriodNarrative({
    required int bookId,
    required int startMs,
    required int endMs,
    String? sectionLabel,
  }) => guardDatabase(() async {
    if (startMs > endMs) {
      throw const Failure(FailureCode.validation, '起始日期不能晚于结束日期');
    }

    String bookLabel = '全部账本';
    if (bookId != noRef) {
      final book = await (db.select(
        db.accountBooks,
      )..where((t) => t.id.equals(bookId))).getSingleOrNull();
      if (book == null) {
        throw const Failure(FailureCode.validation, '所选账本不存在');
      }
      bookLabel = book.name;
    }

    final recQuery = db.select(db.records)
      ..where(
        (t) =>
            (bookId == noRef
                ? const Constant(true)
                : t.accountBookId.equals(bookId)) &
            t.recordTime.isBetweenValues(startMs, endMs) &
            t.type.equals(RecordType.reimburseReceipt).not() &
            t.type.equals(RecordType.balanceAdjust).not(),
      );
    final records = await recQuery.get();
    final summary = aggregateIncomeExpense(records.map(statEntryOf));

    // Aggregate top expense root category in exact minor units.
    final categories = await db.select(db.recordCategories).get();
    final catById = <int, RecordCategory>{for (final c in categories) c.id: c};
    final expenseByCatName = <String, BigInt>{};

    for (final r in records) {
      if (r.recordCatId == noRef) continue;
      final single = aggregateIncomeExpense(<StatEntry>[statEntryOf(r)]);
      if (single.expense == BigInt.zero) continue;
      final cat = catById[r.recordCatId];
      if (cat == null) continue;
      final rootCat = cat.parentCatId != noRef
          ? (catById[cat.parentCatId] ?? cat)
          : cat;
      expenseByCatName[rootCat.name] =
          (expenseByCatName[rootCat.name] ?? BigInt.zero) + single.expense;
    }

    String? topCatName;
    BigInt? topCatMinor;
    for (final entry in expenseByCatName.entries) {
      if (entry.value <= BigInt.zero) continue;
      if (topCatMinor == null || entry.value > topCatMinor) {
        topCatName = entry.key;
        topCatMinor = entry.value;
      }
    }

    final start = DateTime.fromMillisecondsSinceEpoch(startMs);
    final end = DateTime.fromMillisecondsSinceEpoch(endMs);
    String fmtDate(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final label = (sectionLabel != null && sectionLabel.trim().isNotEmpty)
        ? sectionLabel.trim()
        : '${fmtDate(start)} 至 ${fmtDate(end)}';

    return buildStatStoryNarrative(
      periodLabel: label,
      bookLabel: bookLabel,
      recordCount: records.length,
      summary: summary,
      topExpenseCategoryName: topCatName,
      topExpenseCategoryMinor: topCatMinor,
    );
  });
}
