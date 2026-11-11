import 'dart:typed_data';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/repo/ledger_queries.dart';
import 'package:tallyisle/domain/rules/penny_backup.dart';
import 'package:tallyisle/features/penny_import/penny_import_page.dart';
import 'package:tallyisle/features/penny_import/penny_import_providers.dart';
import 'package:tallyisle/features/reminder/reminder_providers.dart';
import 'package:tallyisle/platform/notifications.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<(AppDatabase, InMemoryReminderScheduler)> openTestDb(
    WidgetTester tester,
  ) async {
    late final AppDatabase db;
    await tester.runAsync(() async {
      db = AppDatabase(NativeDatabase.memory());
    });
    final scheduler = InMemoryReminderScheduler();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await scheduler.dispose();
      await tester.runAsync(db.close);
    });
    return (db, scheduler);
  }

  Widget buildApp({
    required AppDatabase db,
    required InMemoryReminderScheduler scheduler,
    required PennyFilePicker picker,
  }) => ProviderScope(
    retry: (_, _) => null,
    overrides: [
      databaseProvider.overrideWith((ref) async => db),
      reminderSchedulerProvider.overrideWithValue(scheduler),
      pennyFilePickerProvider.overrideWithValue(picker),
    ],
    child: const MaterialApp(home: PennyImportPage()),
  );

  testWidgets(
    'preview dialog displays version/counts/overwrite warning, cancel keeps DB untouched, confirm restores 20 tables while preserving note & currency',
    (tester) async {
      final (db, scheduler) = await openTestDb(tester);

      // Seed local note, custom USD rate, and pre-existing record inside runAsync
      await tester.runAsync(() async {
        await db
            .into(db.notes)
            .insert(
              NotesCompanion.insert(
                title: const Value('本地便签'),
                content: '不可丢失的便签内容',
                createTime: 1700000000000,
                updateTime: 1700000000000,
              ),
            );
        await db
            .into(db.currencies)
            .insert(
              CurrenciesCompanion.insert(
                code: 'USD',
                name: '美元',
                symbol: r'$',
                rateToAnchor: '7.25',
                anchorCode: 'CNY',
              ),
            );
        await db
            .into(db.records)
            .insert(
              RecordsCompanion.insert(
                recordId: 'old-local-rec',
                type: 0,
                moneyMinor: BigInt.from(5000),
                recordTime: 1700000000000,
                accountBookId: 1,
              ),
            );
      });

      final validBytes = encodePennyForTest({
        'books': [
          {'id': 1, 'name': '一羽主账本', 'cdate': 1700000000000},
        ],
        'categories': [
          {'id': 11, 'name': '午餐', 'type': 0, 'book': 1},
        ],
        'assets': [
          {'id': 5, 'name': '微信零钱', 'bal': 268.50, 'type': 2, 'initm': 100},
        ],
        'records': [
          {
            'id': 'penny-rec-1',
            'type': 0,
            'money': 32.50,
            'remark': '牛肉面',
            'time': 1700005000000,
            'cat': 11,
            'asset': 5,
            'book': 1,
          },
          {
            'id': 'penny-rec-del',
            'type': 0,
            'money': 99.00,
            'time': 1700006000000,
            'book': 1,
            'sstatus': 4,
          },
        ],
        'moneySavePlans': [
          {
            'id': 1,
            'name': '应急金计划',
            'plan_type': 0,
            'cycle_type': 2,
            'start_date': 1700000000000,
            'end_date': 1731536000000,
            'plan_money': 10000,
            'saved_money': 1500,
            'start_money': 0,
            'incremental': 0,
            'create_date': 1700000000000,
            'next_save_date': 1702592000000,
          },
        ],
        'remarks': [
          {'id': 1, 'content': '加卤蛋', 'record_cat_id': 11, 'used_times': 3},
        ],
        'reminders': [
          {'id': 1, 'time': 1260, 'tip': '睡前记一笔'},
        ],
      });

      await tester.pumpWidget(
        buildApp(
          db: db,
          scheduler: scheduler,
          picker: () async => PennyPickedFile(
            name: '一羽记账_8.6.0_backup.penny',
            bytes: validBytes,
          ),
        ),
      );
      await settle(tester);

      // 1. Tap file picker -> preview dialog appears with counts & warning
      await tester.tap(find.byKey(const Key('select_penny_file_button')));
      await settle(tester);

      expect(find.byKey(const Key('penny_preview_dialog')), findsOneWidget);
      expect(find.text('8.6.0'), findsOneWidget);
      expect(find.textContaining('一羽主账本'), findsOneWidget);
      expect(find.byKey(const Key('penny_overwrite_warning')), findsOneWidget);
      expect(
        find.textContaining('便签（note）与自定义汇率（currency）将完整保留'),
        findsOneWidget,
      );

      // 2. Cancel leaves local DB untouched
      await tester.tap(find.byKey(const Key('cancel_penny_import_button')));
      await settle(tester);
      expect(find.byKey(const Key('penny_preview_dialog')), findsNothing);

      final afterCancelRecords = await tester.runAsync(
        () => db.select(db.records).get(),
      );
      expect(afterCancelRecords!.map((r) => r.recordId), ['old-local-rec']);

      // 3. Open again and confirm restore
      await tester.tap(find.byKey(const Key('select_penny_file_button')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('confirm_penny_import_button')));
      await settle(tester);

      expect(find.byKey(const Key('penny_import_result_card')), findsOneWidget);
      expect(find.text('恢复成功'), findsWidgets);

      final restoredRecords = await tester.runAsync(
        () => db.select(db.records).get(),
      );
      expect(restoredRecords!.map((r) => r.recordId), ['penny-rec-1']);
      expect(restoredRecords.single.moneyMinor, BigInt.from(3250));

      final preservedNotes = await tester.runAsync(
        () => db.select(db.notes).get(),
      );
      expect(preservedNotes!.single.content, '不可丢失的便签内容');

      final preservedCurrencies = await tester.runAsync(
        () => db.select(db.currencies).get(),
      );
      expect(
        preservedCurrencies!.any(
          (c) => c.code == 'USD' && c.rateToAnchor == '7.25',
        ),
        isTrue,
      );

      final currentBookId = await tester.runAsync(
        () => LedgerQueries(db).watchCurrentBookId().first,
      );
      expect(currentBookId, 1);
      expect(scheduler.scheduledList.single.hour, 21);
      expect(scheduler.scheduledList.single.minute, 0);
    },
  );

  testWidgets(
    'corrupt or empty .penny file shows clear error feedback without touching DB',
    (tester) async {
      final (db, scheduler) = await openTestDb(tester);

      await tester.runAsync(() async {
        await db
            .into(db.records)
            .insert(
              RecordsCompanion.insert(
                recordId: 'keep-me-rec',
                type: 0,
                moneyMinor: BigInt.from(1999),
                recordTime: 1700000000000,
                accountBookId: 1,
              ),
            );
      });

      late PennyPickedFile currentFile;
      await tester.pumpWidget(
        buildApp(db: db, scheduler: scheduler, picker: () async => currentFile),
      );
      await settle(tester);

      // Case A: corrupt bytes
      currentFile = PennyPickedFile(
        name: 'broken.penny',
        bytes: Uint8List.fromList([
          0x59,
          0x59,
          0x42,
          0x4B,
          0x02,
          0x01,
          0x01,
          0x00,
        ]),
      );
      await tester.tap(find.byKey(const Key('select_penny_file_button')));
      await settle(tester);

      expect(find.byKey(const Key('penny_preview_dialog')), findsNothing);
      expect(find.byKey(const Key('penny_import_error_card')), findsOneWidget);

      // Case B: empty {} payload
      currentFile = PennyPickedFile(
        name: 'empty.penny',
        bytes: encodePennyForTest('{}'),
      );
      await tester.tap(find.byKey(const Key('select_penny_file_button')));
      await settle(tester);

      expect(find.byKey(const Key('penny_preview_dialog')), findsNothing);
      expect(find.byKey(const Key('penny_import_error_card')), findsOneWidget);
      expect(find.textContaining('备份文件为空'), findsWidgets);

      final records = await tester.runAsync(() => db.select(db.records).get());
      expect(records!.map((r) => r.recordId), ['keep-me-rec']);
    },
  );
}
