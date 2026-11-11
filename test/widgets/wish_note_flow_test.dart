import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/tools/wish_service.dart';
import 'package:tallyisle/features/notes/notes_page.dart';
import 'package:tallyisle/features/wishes/wishes_page.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  (AppDatabase, Future<void> Function()) openTestDb(
    WidgetTester tester, {
    int Function()? nowMs,
  }) {
    final db = AppDatabase(NativeDatabase.memory(), nowMs: nowMs);
    var closed = false;
    Future<void> closeCleanly() async {
      if (closed) return;
      closed = true;
      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(db.close);
    }

    addTearDown(() async {
      if (!closed) {
        closed = true;
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(db.close);
      }
    });
    return (db, closeCleanly);
  }

  Widget buildApp(AppDatabase db, Widget home) => ProviderScope(
    retry: (_, _) => null,
    overrides: [databaseProvider.overrideWith((ref) async => db)],
    child: MaterialApp(home: home),
  );

  testWidgets(
    'WishesPage flow: summary banner, countdown/overdue badges, add/edit, realize/reopen, and delete',
    (tester) async {
      final fixedNow = DateTime(2026, 5, 10, 12, 0).millisecondsSinceEpoch;
      final (db, closeCleanly) = openTestDb(tester, nowMs: () => fixedNow);

      // Seed one overdue wish to verify overdue badge alongside newly created wishes
      late final String overdueId;
      await tester.runAsync(() async {
        final ws = WishService(db);
        overdueId = await ws.createWish(
          commandId: 'seed-overdue',
          content: '去年的相机镜头',
          value: Money.parse('3200.00'),
          targetDate: DateTime(2026, 5, 7).millisecondsSinceEpoch,
          icon: 'digital',
        );
      });

      await tester.pumpWidget(buildApp(db, const WishesPage()));
      await settle(tester);

      expect(find.byKey(const Key('wish_summary_banner')), findsOneWidget);
      expect(find.text('待实现（1 项）'), findsOneWidget);
      expect(find.text('¥3200.00'), findsWidgets);
      expect(find.byKey(Key('wish_deadline_$overdueId')), findsOneWidget);
      expect(find.text('已逾期 3 天'), findsOneWidget);

      // Add a new wish via editor
      await tester.tap(find.byKey(const Key('add_wish_fab')));
      await settle(tester);

      // Empty content shows validation error inline
      await tester.tap(find.byKey(const Key('save_wish_button')));
      await settle(tester);
      expect(find.text('请输入心愿内容'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('wish_content_input')),
        '冲绳潜水之旅',
      );
      await tester.enterText(
        find.byKey(const Key('wish_amount_input')),
        '6800.50',
      );
      await tester.tap(find.byKey(const Key('wish_icon_chip_travel')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('save_wish_button')));
      await settle(tester);

      // Back on WishesPage: 2 unrealized wishes totaling 3200.00 + 6800.50 = 10000.50
      expect(find.text('冲绳潜水之旅'), findsOneWidget);
      expect(find.text('待实现（2 项）'), findsOneWidget);
      expect(find.text('¥10000.50'), findsOneWidget);

      // Edit the overdue wish amount from 3200.00 -> 3000.00
      await tester.tap(find.byKey(Key('edit_wish_$overdueId')));
      await settle(tester);
      await tester.enterText(
        find.byKey(const Key('wish_amount_input')),
        '3000.00',
      );
      await tester.tap(find.byKey(const Key('save_wish_button')));
      await settle(tester);
      expect(find.text('¥9800.50'), findsOneWidget);

      // Mark realized -> moves to 已实现 tab
      await tester.tap(find.byKey(Key('realize_wish_$overdueId')));
      await settle(tester);

      expect(find.text('待实现（1 项）'), findsOneWidget);
      expect(find.text('已实现（1 项）'), findsOneWidget);
      expect(find.text('去年的相机镜头'), findsNothing);

      // Switch to 已实现 tab
      await tester.tap(find.byKey(const Key('wish_tab_realized')));
      await settle(tester);
      expect(find.text('去年的相机镜头'), findsOneWidget);

      // Reopen wish -> returns to 待实现 with realizedDate == 0
      await tester.tap(find.byKey(Key('reopen_wish_$overdueId')));
      await settle(tester);
      expect(find.byKey(const Key('wish_realized_empty')), findsOneWidget);

      await tester.tap(find.byKey(const Key('wish_tab_unrealized')));
      await settle(tester);
      expect(find.text('待实现（2 项）'), findsOneWidget);

      final dbRow = await tester.runAsync(
        () => WishService(db).getWish(overdueId),
      );
      expect(dbRow!.isRealized, isFalse);
      expect(dbRow.realizedDate, 0);

      // Delete wish with confirmation
      await tester.tap(find.byKey(Key('delete_wish_$overdueId')));
      await settle(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('删除'),
        ),
      );
      await settle(tester);
      expect(find.text('去年的相机镜头'), findsNothing);
      expect(find.text('待实现（1 项）'), findsOneWidget);

      await closeCleanly();
    },
  );

  testWidgets(
    'NotesPage & NoteTrashPage flow: create, edit, live search, move to trash, restore, delete permanently, and empty trash',
    (tester) async {
      var clock = DateTime(2026, 5, 10, 10, 0).millisecondsSinceEpoch;
      final (db, closeCleanly) = openTestDb(tester, nowMs: () => clock);

      await tester.pumpWidget(buildApp(db, const NotesPage()));
      await settle(tester);

      expect(find.byKey(const Key('notes_empty_state')), findsOneWidget);

      // 1. Create first note
      await tester.tap(find.byKey(const Key('add_note_fab')));
      await settle(tester);
      await tester.enterText(
        find.byKey(const Key('note_title_input')),
        '年度税务备忘',
      );
      await tester.enterText(
        find.byKey(const Key('note_content_input')),
        '专项附加扣除截止 3 月底，准备 Rent Contract。',
      );
      await tester.tap(find.byKey(const Key('save_note_button')));
      await settle(tester);

      // 2. Create second note (untitled)
      clock += 60000;
      await tester.tap(find.byKey(const Key('add_note_fab')));
      await settle(tester);
      await tester.enterText(
        find.byKey(const Key('note_content_input')),
        '周末露营装备清单\n帐篷、睡袋、手冲咖啡壶',
      );
      await tester.tap(find.byKey(const Key('save_note_button')));
      await settle(tester);

      expect(find.text('年度税务备忘'), findsOneWidget);
      expect(find.text('周末露营装备清单'), findsOneWidget);

      // 3. Live case-insensitive search
      await tester.enterText(
        find.byKey(const Key('note_search_input')),
        'rent contract',
      );
      await settle(tester);
      expect(find.text('年度税务备忘'), findsOneWidget);
      expect(find.text('周末露营装备清单'), findsNothing);

      await tester.enterText(
        find.byKey(const Key('note_search_input')),
        '不存在的关键词',
      );
      await settle(tester);
      expect(find.byKey(const Key('notes_search_empty_state')), findsOneWidget);

      await tester.tap(find.byKey(const Key('clear_note_search_button')));
      await settle(tester);
      expect(find.text('年度税务备忘'), findsOneWidget);
      expect(find.text('周末露营装备清单'), findsOneWidget);

      // 4. Edit first note
      await tester.tap(find.text('年度税务备忘'));
      await settle(tester);
      await tester.enterText(
        find.byKey(const Key('note_title_input')),
        '2026 年度个税备忘',
      );
      await tester.tap(find.byKey(const Key('save_note_button')));
      await settle(tester);
      expect(find.text('2026 年度个税备忘'), findsOneWidget);

      final notesInDb = await tester.runAsync(() => db.select(db.notes).get());
      final taxNote = notesInDb!.firstWhere((n) => n.title == '2026 年度个税备忘');
      final campNote = notesInDb.firstWhere((n) => n.title == null);

      // 5. Move taxNote to recycle bin -> restore it
      clock += 60000;
      await tester.tap(find.byKey(Key('trash_note_${taxNote.id}')));
      await settle(tester);
      expect(find.text('2026 年度个税备忘'), findsNothing);
      expect(find.text('回收站 (1)'), findsOneWidget);

      await tester.tap(find.byKey(const Key('open_note_trash_button')));
      await settle(tester);
      expect(find.byKey(const Key('note_trash_page')), findsOneWidget);
      expect(find.text('2026 年度个税备忘'), findsOneWidget);

      await tester.tap(find.byKey(Key('restore_note_${taxNote.id}')));
      await settle(tester);
      expect(find.byKey(const Key('note_trash_empty_state')), findsOneWidget);

      await tester.pageBack();
      await settle(tester);
      expect(find.text('2026 年度个税备忘'), findsOneWidget);

      // 6. Create a 3rd note, move two notes to trash, test single permanent delete + empty trash
      clock += 60000;
      await tester.tap(find.byKey(const Key('add_note_fab')));
      await settle(tester);
      await tester.enterText(
        find.byKey(const Key('note_title_input')),
        '临时草稿A',
      );
      await tester.enterText(
        find.byKey(const Key('note_content_input')),
        '待清理草稿内容',
      );
      await tester.tap(find.byKey(const Key('save_note_button')));
      await settle(tester);

      final allRows = await tester.runAsync(() => db.select(db.notes).get());
      final draftNote = allRows!.firstWhere((n) => n.title == '临时草稿A');

      await tester.tap(find.byKey(Key('trash_note_${campNote.id}')));
      await settle(tester);
      await tester.tap(find.byKey(Key('trash_note_${draftNote.id}')));
      await settle(tester);
      expect(find.text('回收站 (2)'), findsOneWidget);

      await tester.tap(find.byKey(const Key('open_note_trash_button')));
      await settle(tester);

      // Permanently delete campNote
      await tester.tap(
        find.byKey(Key('delete_note_permanently_${campNote.id}')),
      );
      await settle(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('彻底删除'),
        ),
      );
      await settle(tester);
      expect(find.text('周末露营装备清单'), findsNothing);
      expect(find.text('临时草稿A'), findsOneWidget);

      // Empty remaining trash
      await tester.tap(find.byKey(const Key('empty_note_trash_button')));
      await settle(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('清空'),
        ),
      );
      await settle(tester);
      expect(find.byKey(const Key('note_trash_empty_state')), findsOneWidget);

      // Active taxNote remains intact
      await tester.pageBack();
      await settle(tester);
      expect(find.text('2026 年度个税备忘'), findsOneWidget);

      await closeCleanly();
    },
  );
}
