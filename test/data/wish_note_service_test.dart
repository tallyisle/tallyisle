import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/tools/note_service.dart';
import 'package:tallyisle/data/tools/wish_service.dart';

void main() {
  late AppDatabase db;
  late WishService wishService;
  late NoteService noteService;
  var now = DateTime(2026, 5, 10, 12, 0).millisecondsSinceEpoch;
  var seq = 0;
  String cmd() => 'wn-cmd-${seq++}';

  setUp(() {
    now = DateTime(2026, 5, 10, 12, 0).millisecondsSinceEpoch;
    db = AppDatabase(NativeDatabase.memory(), nowMs: () => now);
    wishService = WishService(db);
    noteService = NoteService(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('WishService (F-014, ADR-009)', () {
    test(
      'creates UUID wishes, maintains realizedDate invariant (0 when unrealized), summarizes BigInt totals, and deletes physically',
      () async {
        final id1 = await wishService.createWish(
          commandId: cmd(),
          content: '机械键盘',
          value: Money.parse('899.50'),
          icon: 'digital',
        );
        expect(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ).hasMatch(id1),
          isTrue,
        );

        now += 1000;
        final targetMs = DateTime(2026, 5, 20).millisecondsSinceEpoch;
        final id2 = await wishService.createWish(
          commandId: cmd(),
          content: '海岛旅行',
          value: Money.parse('5000.00'),
          targetDate: targetMs,
          icon: 'travel',
        );

        // Auto-top sort places newest wish first (id2 sort = -1, id1 sort = 0)
        final unrealized = await wishService.getUnrealizedWishes();
        expect(unrealized.map((w) => w.id).toList(), [id2, id1]);
        expect(unrealized.first.realizedDate, 0);
        expect(unrealized.first.isRealized, isFalse);

        // Realize id1 at exact timestamp
        now = DateTime(2026, 5, 12, 9, 30).millisecondsSinceEpoch;
        await wishService.markRealized(commandId: cmd(), id: id1);

        final realizedRow = await wishService.getWish(id1);
        expect(realizedRow!.isRealized, isTrue);
        expect(realizedRow.realizedDate, now);

        final summary = await wishService.getSummary();
        expect(summary.unrealizedCount, 1);
        expect(summary.realizedCount, 1);
        expect(summary.unrealizedTotalMinor, BigInt.from(500000));
        expect(summary.realizedTotalMinor, BigInt.from(89950));

        // Update realized wish keeps realized state and realizedDate
        await wishService.updateWish(
          commandId: cmd(),
          id: id1,
          content: '客制化机械键盘',
          value: Money.parse('999.00'),
          icon: 'digital',
        );
        final updatedRealized = await wishService.getWish(id1);
        expect(updatedRealized!.content, '客制化机械键盘');
        expect(updatedRealized.valueMinor, BigInt.from(99900));
        expect(updatedRealized.isRealized, isTrue);
        expect(updatedRealized.realizedDate, now);

        // Reopen resets realizedDate strictly back to 0
        await wishService.reopenWish(commandId: cmd(), id: id1);
        final reopened = await wishService.getWish(id1);
        expect(reopened!.isRealized, isFalse);
        expect(reopened.realizedDate, 0);

        // Reorder and physical delete
        await wishService.reorderWishes(
          commandId: cmd(),
          orderedIds: [id1, id2],
        );
        expect(
          (await wishService.getUnrealizedWishes()).map((w) => w.id).toList(),
          [id1, id2],
        );

        await wishService.deleteWish(commandId: cmd(), id: id1);
        expect(await wishService.getWish(id1), isNull);
        expect(await wishService.getUnrealizedWishes(), hasLength(1));
      },
    );

    test(
      'enforces ADR-009 ti_write_command idempotency and conflict detection on WishService',
      () async {
        final createCmd = cmd();
        final idFirst = await wishService.createWish(
          commandId: createCmd,
          content: '阅读器',
          value: Money.parse('1299.00'),
        );
        final idRetry = await wishService.createWish(
          commandId: createCmd,
          content: '阅读器',
          value: Money.parse('1299.00'),
        );
        expect(idRetry, idFirst);
        expect(await wishService.getUnrealizedWishes(), hasLength(1));

        // Same commandId with mutated amount triggers conflict
        await expectLater(
          wishService.createWish(
            commandId: createCmd,
            content: '阅读器',
            value: Money.parse('1399.00'),
          ),
          throwsA(
            isA<Failure>().having((f) => f.code, 'code', FailureCode.conflict),
          ),
        );
      },
    );
  });

  group('NoteService (F-015, ADR-009)', () {
    test(
      'CRUD, case-insensitive search, moveToTrash, restoreFromTrash, deletePermanently, and emptyTrash isolation',
      () async {
        final id1 = await noteService.createNote(
          commandId: cmd(),
          title: '报销材料清单',
          content: '发票 PDF + 行程单',
        );
        now += 5000;
        final id2 = await noteService.createNote(
          commandId: cmd(),
          title: null,
          content: 'Weekly Grocery: Milk & Bread',
        );
        // Simulate legacy imported active note with trashTime == -1 (CE-WN-01)
        final legacyId = await db
            .into(db.notes)
            .insert(
              NotesCompanion.insert(
                title: const Value('历史便签'),
                content: '旧版本导入内容',
                createTime: now - 10000,
                updateTime: now - 10000,
                trashTime: const Value(-1),
              ),
            );

        // Active order: id2 (newest update) -> id1 -> legacyId
        final active = await noteService.getActiveNotes();
        expect(active.map((n) => n.id).toList(), [id2, id1, legacyId]);

        // Case-insensitive search
        final matchMilk = await noteService.getActiveNotes(query: 'milk');
        expect(matchMilk.map((n) => n.id).toList(), [id2]);
        final matchPdf = await noteService.getActiveNotes(query: 'pdf');
        expect(matchPdf.map((n) => n.id).toList(), [id1]);

        // Update refreshes updateTime while preserving createTime
        final beforeUpdate = await noteService.getNote(id1);
        now += 10000;
        await noteService.updateNote(
          commandId: cmd(),
          id: id1,
          title: '差旅报销清单',
          content: '发票 PDF + 登机牌',
        );
        final afterUpdate = await noteService.getNote(id1);
        expect(afterUpdate!.createTime, beforeUpdate!.createTime);
        expect(afterUpdate.updateTime, now);
        expect(afterUpdate.trashTime, 0);

        // Move id1 and id2 to trash
        final trashAt1 = now + 2000;
        now = trashAt1;
        await noteService.moveToTrash(commandId: cmd(), id: id1);
        final trashAt2 = now + 3000;
        now = trashAt2;
        await noteService.moveToTrash(commandId: cmd(), id: id2);

        expect((await noteService.getActiveNotes()).map((n) => n.id).toList(), [
          legacyId,
        ]);
        final trashed = await noteService.getTrashedNotes();
        expect(trashed.map((n) => n.id).toList(), [id2, id1]);
        expect(trashed.first.trashTime, trashAt2);

        // Editing a trashed note is rejected until restored
        await expectLater(
          noteService.updateNote(
            commandId: cmd(),
            id: id1,
            title: '不可直接改',
            content: '内容',
          ),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.validation,
            ),
          ),
        );

        // Restore id1 from trash: trashTime becomes 0, updateTime preserved
        await noteService.restoreFromTrash(commandId: cmd(), id: id1);
        final restored = await noteService.getNote(id1);
        expect(restored!.trashTime, 0);
        expect(restored.updateTime, afterUpdate.updateTime);

        // Move id1 back to trash, add a 3rd trashed note, test deletePermanently + emptyTrash
        now += 1000;
        await noteService.moveToTrash(commandId: cmd(), id: id1);
        final id3 = await noteService.createNote(
          commandId: cmd(),
          title: '活跃保留便签',
          content: '绝不能被清空回收站删除',
        );

        await noteService.deletePermanently(commandId: cmd(), id: id2);
        expect(await noteService.getNote(id2), isNull);
        expect((await noteService.getTrashedNotes()).map((n) => n.id), [id1]);

        final emptyCmd = cmd();
        final deletedCount = await noteService.emptyTrash(commandId: emptyCmd);
        expect(deletedCount, 1);
        // Retry with same commandId returns cached deletedCount (1)
        expect(await noteService.emptyTrash(commandId: emptyCmd), 1);

        expect(await noteService.getTrashedNotes(), isEmpty);
        // Both normal active note (trashTime = 0) and legacy active note (trashTime = -1) survive!
        final remainingIds = (await noteService.getActiveNotes())
            .map((n) => n.id)
            .toSet();
        expect(remainingIds, {id3, legacyId});
      },
    );

    test(
      'enforces ADR-009 idempotency and conflict rejection on NoteService',
      () async {
        final createCmd = cmd();
        final firstId = await noteService.createNote(
          commandId: createCmd,
          title: '标题',
          content: '内容A',
        );
        final retryId = await noteService.createNote(
          commandId: createCmd,
          title: '标题',
          content: '内容A',
        );
        expect(retryId, firstId);
        expect(await noteService.getActiveNotes(), hasLength(1));

        await expectLater(
          noteService.createNote(
            commandId: createCmd,
            title: '标题',
            content: '内容B',
          ),
          throwsA(
            isA<Failure>().having((f) => f.code, 'code', FailureCode.conflict),
          ),
        );
      },
    );
  });
}
