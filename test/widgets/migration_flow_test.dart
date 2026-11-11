import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show OrderingTerm, Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw_sqlite;
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/migration/lan_zip_crypto.dart';
import 'package:tallyisle/data/repo/ledger_queries.dart';
import 'package:tallyisle/domain/rules/ios_migration_rules.dart';
import 'package:tallyisle/domain/rules/penny_backup.dart';
import 'package:tallyisle/features/migration/migration_page.dart';
import 'package:tallyisle/features/migration/migration_providers.dart';
import 'package:tallyisle/features/reminder/reminder_providers.dart';
import 'package:tallyisle/platform/files.dart';
import 'package:tallyisle/platform/notifications.dart';

Uint8List _buildMinimalRoomDbBytes() {
  final dir = Directory.systemTemp.createTempSync('ti_widget_lan_');
  try {
    final file = File('${dir.path}/yiyujizhang.db');
    final raw = raw_sqlite.sqlite3.open(file.path);
    try {
      raw.execute('''
        CREATE TABLE account_book (
          _id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
          id INTEGER NOT NULL,
          type INTEGER NOT NULL DEFAULT 1,
          name TEXT NOT NULL,
          cover TEXT NOT NULL,
          sort INTEGER NOT NULL DEFAULT 1,
          status INTEGER NOT NULL,
          start_day INTEGER NOT NULL,
          create_date INTEGER NOT NULL,
          display_way INTEGER NOT NULL,
          extra_info TEXT,
          sync_time INTEGER NOT NULL,
          sstatus INTEGER NOT NULL,
          uid TEXT NOT NULL
        );
        CREATE TABLE asset (
          id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
          name TEXT NOT NULL,
          balance REAL NOT NULL,
          type INTEGER NOT NULL,
          sub_type INTEGER NOT NULL DEFAULT -1,
          create_date INTEGER NOT NULL,
          sort INTEGER NOT NULL,
          icon TEXT NOT NULL,
          remark TEXT,
          init_money REAL NOT NULL,
          is_default INTEGER NOT NULL,
          is_effective_asset INTEGER NOT NULL,
          used_times INTEGER NOT NULL,
          color TEXT,
          status INTEGER NOT NULL,
          extra_info TEXT,
          loan_info TEXT,
          credit_info TEXT,
          fixed_deposit_info TEXT,
          group_name TEXT,
          currency TEXT,
          sync_time INTEGER NOT NULL,
          sstatus INTEGER NOT NULL,
          uid TEXT NOT NULL
        );
        CREATE TABLE record (
          record_id TEXT NOT NULL PRIMARY KEY,
          type INTEGER NOT NULL,
          sub_type INTEGER NOT NULL DEFAULT -1,
          money REAL NOT NULL,
          remark TEXT NOT NULL,
          record_time INTEGER NOT NULL,
          record_cat_id INTEGER NOT NULL,
          asset_id INTEGER NOT NULL,
          from_asset_id INTEGER NOT NULL,
          to_asset_id INTEGER NOT NULL,
          account_book_id INTEGER NOT NULL,
          exclude_budget INTEGER NOT NULL,
          exclude_ex_in INTEGER NOT NULL,
          platform_id INTEGER NOT NULL,
          period_id INTEGER NOT NULL,
          installment TEXT,
          images TEXT,
          rel_info TEXT,
          discount REAL,
          extra_info TEXT,
          create_date INTEGER,
          sync_time INTEGER NOT NULL,
          sstatus INTEGER NOT NULL,
          uid TEXT NOT NULL
        );
      ''');
      raw.execute('''
        INSERT INTO account_book (id, type, name, cover, sort, status, start_day, create_date, display_way, sync_time, sstatus, uid)
        VALUES (1, 1, '局域网恢复账本', '', 1, 0, 1, 1710000000000, 0, 0, 0, '');
        INSERT INTO asset (id, name, balance, type, sub_type, create_date, sort, icon, init_money, is_default, is_effective_asset, used_times, status, sync_time, sstatus, uid)
        VALUES (10, '局域网现金', 520.80, 0, 0, 1710000000000, 0, '', 0.0, 1, 1, 0, 0, 0, 0, '');
        INSERT INTO record (record_id, type, sub_type, money, remark, record_time, record_cat_id, asset_id, from_asset_id, to_asset_id, account_book_id, exclude_budget, exclude_ex_in, platform_id, period_id, sync_time, sstatus, uid)
        VALUES ('w-lan-rec-1', 0, -1, 66.50, '晚餐', 1710050000000, -1, 10, -1, -1, 1, 0, 0, -1, -1, 0, 0, '');
      ''');
    } finally {
      raw.close();
    }
    return file.readAsBytesSync();
  } finally {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
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

  testWidgets(
    'MigrationPage: renders unified 从旧软件导入 title, cross-platform .tally unity banner, all 3 legacy import cards, and omits obsolete .ya2i export UI',
    (tester) async {
      final (db, scheduler) = await openTestDb(tester);

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            reminderSchedulerProvider.overrideWithValue(scheduler),
          ],
          child: const MaterialApp(home: MigrationPage()),
        ),
      );
      await settle(tester);

      expect(find.byKey(const Key('migration_page')), findsOneWidget);
      expect(find.text('从旧软件导入'), findsOneWidget);

      // Cross-platform unity banner
      expect(
        find.byKey(const Key('migration_unity_banner_card')),
        findsOneWidget,
      );
      expect(find.textContaining('数据格式 100% 统一'), findsOneWidget);
      expect(find.textContaining('.tally / WebDAV / S3'), findsOneWidget);
      expect(find.textContaining('保留本机已有便签与自定义汇率'), findsOneWidget);

      // Local overview card
      expect(
        find.byKey(const Key('migration_local_summary_card')),
        findsOneWidget,
      );
      expect(find.text('账本 1 · 账户 0 · 账单 0 · 便签 0'), findsOneWidget);

      // Obsolete .ya2i export UI is completely absent
      expect(find.byKey(const Key('export_ya2i_save_button')), findsNothing);
      expect(find.byKey(const Key('export_ya2i_share_button')), findsNothing);
      expect(find.textContaining('导出数据到 iOS'), findsNothing);
      expect(find.textContaining('导出 .ya2i'), findsNothing);

      // Card 1: .penny / .yy
      expect(
        find.byKey(const Key('legacy_import_penny_button')),
        findsOneWidget,
      );

      // Card 2: .yi2a
      await tester.dragUntilVisible(
        find.byKey(const Key('migration_import_yi2a_button')),
        find.byType(ListView),
        const Offset(0, -120),
      );
      await settle(tester);
      expect(
        find.byKey(const Key('migration_import_yi2a_button')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('import_yi2a_button')), findsOneWidget);

      // Card 3: LAN ServerBackup.zip / .db
      await tester.dragUntilVisible(
        find.byKey(const Key('migration_restore_lan_button')),
        find.byType(ListView),
        const Offset(0, -120),
      );
      await settle(tester);
      expect(
        find.byKey(const Key('migration_restore_lan_button')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('restore_lan_backup_button')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('export_ya2i_save_button')), findsNothing);
    },
  );

  testWidgets(
    'MigrationPage .penny import: rejects empty {}, shows full preview (version/counts/remarks/tombstones), and atomically restores 20 tables while preserving local notes & currencies',
    (tester) async {
      final (db, scheduler) = await openTestDb(tester);

      await tester.runAsync(() async {
        await db
            .into(db.notes)
            .insert(
              NotesCompanion.insert(
                title: const Value('本地便签标题'),
                content: '不可丢失的本地便签',
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
                rateToAnchor: '7.28',
                anchorCode: 'CNY',
              ),
            );
        await db
            .into(db.records)
            .insert(
              RecordsCompanion.insert(
                recordId: 'local-before-penny',
                type: 0,
                moneyMinor: BigInt.from(1500),
                recordTime: 1700000000000,
                accountBookId: 1,
              ),
            );
      });

      SelectedBytes nextPick = SelectedBytes(
        'empty.penny',
        encodePennyForTest('{}'),
      );
      final fakeFiles = FileAccess(onPickBytes: (_) async => nextPick);

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            reminderSchedulerProvider.overrideWithValue(scheduler),
            migrationFileAccessProvider.overrideWithValue(fakeFiles),
          ],
          child: const MaterialApp(home: MigrationPage()),
        ),
      );
      await settle(tester);

      expect(find.text('账本 1 · 账户 0 · 账单 1 · 便签 1'), findsOneWidget);

      // 1. Empty {} .penny rejected before dialog; local DB untouched
      await tester.tap(find.byKey(const Key('legacy_import_penny_button')));
      await settle(tester);

      expect(find.byKey(const Key('penny_preview_dialog')), findsNothing);
      expect(find.byKey(const Key('migration_status_banner')), findsOneWidget);
      expect(find.textContaining('备份文件为空'), findsOneWidget);

      final intactAfterEmpty = await tester.runAsync(
        () => db.select(db.records).get(),
      );
      expect(intactAfterEmpty!.map((r) => r.recordId), ['local-before-penny']);

      // 2. Valid encrypted .penny with active rows + sstatus=4 tombstones
      const pennyJson = '''
{
  "books": [
    {"id": 2, "name": "一羽主账本", "cdate": 1700000000000, "sstatus": 0},
    {"id": 9, "name": "已删墓碑账本", "cdate": 1700000001000, "sstatus": 4}
  ],
  "categories": [
    {"id": 11, "name": "餐饮", "type": 0, "book": 2, "sstatus": 0}
  ],
  "assets": [
    {"id": 5, "name": "微信零钱", "bal": 268.50, "type": 2, "initm": 100.00, "cdate": 1700000000000, "effect": true, "sstatus": 0}
  ],
  "records": [
    {"id": "penny-rec-1", "type": 0, "money": 32.50, "remark": "牛肉面", "time": 1700005000000, "cat": 11, "asset": 5, "book": 2, "sstatus": 0},
    {"id": "penny-rec-2", "type": 0, "money": 18.00, "remark": "咖啡", "time": 1700006000000, "cat": 11, "asset": 5, "book": 2, "sstatus": 2},
    {"id": "penny-rec-tombstone", "type": 0, "money": 99.00, "time": 1700007000000, "book": 2, "sstatus": 4}
  ],
  "remarks": [
    {"id": 1, "content": "加卤蛋", "record_cat_id": 11, "used_times": 3}
  ],
  "reminders": [
    {"id": 1, "time": 1260, "tip": "睡前记一笔"}
  ]
}
''';
      nextPick = SelectedBytes(
        '一羽记账_8.6.0_backup.penny',
        encodePennyForTest(pennyJson),
      );

      await tester.tap(find.byKey(const Key('legacy_import_penny_button')));
      await settle(tester);

      expect(find.byKey(const Key('penny_preview_dialog')), findsOneWidget);
      expect(find.text('8.6.0'), findsOneWidget);
      expect(find.textContaining('一羽主账本'), findsOneWidget);
      expect(find.text('1 个'), findsNWidgets(2)); // 1 asset + 1 category
      expect(find.text('2 条'), findsOneWidget); // 2 active records
      expect(find.text('1 条'), findsOneWidget); // 1 remark
      expect(find.textContaining('已过滤 2 条'), findsOneWidget); // 2 tombstones
      expect(find.byKey(const Key('penny_overwrite_warning')), findsOneWidget);

      // Cancel keeps DB untouched
      await tester.tap(find.byKey(const Key('cancel_penny_import_button')));
      await settle(tester);
      expect(find.byKey(const Key('penny_preview_dialog')), findsNothing);

      final intactAfterCancel = await tester.runAsync(
        () => db.select(db.records).get(),
      );
      expect(intactAfterCancel!.map((r) => r.recordId), ['local-before-penny']);

      // Re-open & confirm atomic restore
      await tester.tap(find.byKey(const Key('legacy_import_penny_button')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('confirm_penny_import_button')));
      await settle(tester);

      expect(find.byKey(const Key('penny_preview_dialog')), findsNothing);
      expect(
        find.textContaining('原版 Android 备份导入完成：已切换至「一羽主账本」'),
        findsOneWidget,
      );
      expect(find.text('账本 1 · 账户 1 · 账单 2 · 便签 1'), findsOneWidget);

      final restoredRecords = await tester.runAsync(
        () => (db.select(
          db.records,
        )..orderBy([(t) => OrderingTerm.asc(t.recordTime)])).get(),
      );
      expect(restoredRecords!.map((r) => (r.recordId, r.moneyMinor)).toList(), [
        ('penny-rec-1', BigInt.from(3250)),
        ('penny-rec-2', BigInt.from(1800)),
      ]);

      final restoredRemarks = await tester.runAsync(
        () => db.select(db.remarks).get(),
      );
      expect(restoredRemarks!.single.content, '加卤蛋');

      final preservedNotes = await tester.runAsync(
        () => db.select(db.notes).get(),
      );
      expect(preservedNotes!.single.content, '不可丢失的本地便签');

      final preservedCurrencies = await tester.runAsync(
        () => db.select(db.currencies).get(),
      );
      expect(
        preservedCurrencies!.any(
          (c) => c.code == 'USD' && c.rateToAnchor == '7.28',
        ),
        isTrue,
      );

      final activeBookId = await tester.runAsync(
        () => LedgerQueries(db).watchCurrentBookId().first,
      );
      expect(activeBookId, 2);
      expect(scheduler.scheduledList.single.hour, 21);
      expect(scheduler.scheduledList.single.minute, 0);
    },
  );

  testWidgets(
    'MigrationPage .yi2a import: blocks empty {} .yi2a before dialog, imports valid .yi2a via picker & initialSharedYi2a while preserving local notes and currencies',
    (tester) async {
      final (db, scheduler) = await openTestDb(tester);

      await tester.runAsync(() async {
        await db
            .into(db.notes)
            .insert(
              NotesCompanion.insert(
                content: '保留的本地便签',
                createTime: 1700000000000,
                updateTime: 1700000000000,
              ),
            );
        await db
            .into(db.currencies)
            .insert(
              CurrenciesCompanion.insert(
                code: 'EUR',
                name: '欧元',
                symbol: '€',
                rateToAnchor: '7.85',
                anchorCode: 'CNY',
              ),
            );
        await db
            .into(db.records)
            .insert(
              RecordsCompanion.insert(
                recordId: 'local-before-import',
                type: 0,
                moneyMinor: BigInt.from(1500),
                recordTime: 1700000000000,
                accountBookId: 1,
              ),
            );
      });

      SelectedBytes nextPick = SelectedBytes(
        'empty.yi2a',
        Uint8List.fromList(utf8.encode('{}')),
      );
      final fakeFiles = FileAccess(onPickBytes: (_) async => nextPick);

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            reminderSchedulerProvider.overrideWithValue(scheduler),
            migrationFileAccessProvider.overrideWithValue(fakeFiles),
          ],
          child: const MaterialApp(home: MigrationPage()),
        ),
      );
      await settle(tester);

      expect(find.text('账本 1 · 账户 0 · 账单 1 · 便签 1'), findsOneWidget);

      await tester.dragUntilVisible(
        find.byKey(const Key('migration_import_yi2a_button')),
        find.byType(ListView),
        const Offset(0, -120),
      );
      await settle(tester);

      // 1. Empty {} .yi2a -> intercepted by R1 preflight without dialog or DB loss
      await tester.tap(find.byKey(const Key('migration_import_yi2a_button')));
      await settle(tester);

      expect(find.byKey(const Key('yi2a_confirm_dialog')), findsNothing);
      expect(find.textContaining('不包含有效业务数据'), findsOneWidget);
      final recordsStillIntact = await tester.runAsync(
        () => db.select(db.records).get(),
      );
      expect(recordsStillIntact, hasLength(1));

      // 2. Valid .yi2a -> preview dialog -> confirm -> imports & preserves note + currency
      const validYi2a = '''
{
  "books": [
    {"id": 1, "name": "iOS迁移账本", "cdate": 1710000000000, "uid": ""}
  ],
  "assets": [
    {"id": 5, "name": "Apple Card", "bal": 300.25, "initm": 0, "type": 0, "cdate": 1710000000000, "effect": true, "uid": ""}
  ],
  "records": [
    {"id": "ios-r1", "type": 0, "money": 45.50, "remark": "App Store", "time": 1710020000000, "cat": -1, "asset": 5, "book": 1, "plat": -1, "uid": ""},
    {"id": "ios-r2", "type": 0, "money": 18.00, "remark": "iCloud", "time": 1710030000000, "cat": -1, "asset": 5, "book": 1, "plat": -1, "uid": ""}
  ],
  "assetBookRefs": [
    {"aid": 5, "bid": 1}
  ],
  "statStory": [
    {"id": "ios-story-1", "story": "订阅支出统计", "book_id": 1, "sdate": 1710000000000, "edate": 1712600000000}
  ],
  "reminders": [
    {"id": 1, "time": 540, "tip": "早安记账"}
  ]
}
''';
      nextPick = SelectedBytes(
        'from_ios.yi2a',
        Uint8List.fromList(utf8.encode(validYi2a)),
      );

      await tester.tap(find.byKey(const Key('migration_import_yi2a_button')));
      await settle(tester);

      expect(find.byKey(const Key('yi2a_confirm_dialog')), findsOneWidget);
      expect(find.text('预检概况：账本 1 个、账户 1 个、账单 2 条'), findsOneWidget);
      expect(find.text('附加关联：专属资产关联 1 条、统计故事 1 条'), findsOneWidget);

      await tester.tap(find.byKey(const Key('migration_confirm_submit')));
      await settle(tester);

      expect(find.byKey(const Key('yi2a_confirm_dialog')), findsNothing);
      await tester.drag(find.byType(ListView), const Offset(0, 300));
      await settle(tester);
      expect(find.text('账本 1 · 账户 1 · 账单 2 · 便签 1'), findsOneWidget);
      expect(scheduler.scheduledList, hasLength(1));

      final preservedCurrencies = await tester.runAsync(
        () => db.select(db.currencies).get(),
      );
      expect(
        preservedCurrencies!.any(
          (c) => c.code == 'EUR' && c.rateToAnchor == '7.85',
        ),
        isTrue,
      );

      // 3. External share intent (`initialSharedYi2a`) automatically opens preview confirmation
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            reminderSchedulerProvider.overrideWithValue(scheduler),
            migrationFileAccessProvider.overrideWithValue(fakeFiles),
          ],
          child: MaterialApp(
            home: MigrationPage(
              key: const ValueKey<String>('shared-yi2a-page'),
              initialSharedYi2a: SelectedBytes(
                'shared_ios.yi2a',
                Uint8List.fromList(utf8.encode(validYi2a)),
              ),
            ),
          ),
        ),
      );
      await settle(tester);

      expect(find.byKey(const Key('yi2a_confirm_dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('migration_confirm_cancel')));
      await settle(tester);
      expect(find.byKey(const Key('yi2a_confirm_dialog')), findsNothing);
    },
  );

  testWidgets(
    'MigrationPage LAN restore: prompts password dialog for custom AE-2 ZIP (retry on wrong password -> unlock -> confirm) and auto-decrypts historical "YYjz@23!" AE-2 ZIP while preserving local notes & currencies',
    (tester) async {
      final (db, scheduler) = await openTestDb(tester);

      await tester.runAsync(() async {
        await db
            .into(db.notes)
            .insert(
              NotesCompanion.insert(
                content: '局域网恢复保留便签',
                createTime: 1700000000000,
                updateTime: 1700000000000,
              ),
            );
        await db
            .into(db.currencies)
            .insert(
              CurrenciesCompanion.insert(
                code: 'HKD',
                name: '港币',
                symbol: r'HK$',
                rateToAnchor: '0.92',
                anchorCode: 'CNY',
              ),
            );
      });

      final roomDbBytes = _buildMinimalRoomDbBytes();
      final customEncryptedZip = buildLanZipArchive([
        LanZipInputEntry(name: 'yiyujizhang.db', bytes: roomDbBytes),
      ], password: 'LanCustom#2026');
      final historicalEncryptedZip = buildLanZipArchive([
        LanZipInputEntry(name: 'yiyujizhang.db', bytes: roomDbBytes),
      ], password: historicalLanZipPassword);

      SelectedBytes nextPick = SelectedBytes(
        'ServerBackup.zip',
        customEncryptedZip,
      );
      final fakeFiles = FileAccess(onPickBytes: (_) async => nextPick);

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            reminderSchedulerProvider.overrideWithValue(scheduler),
            migrationFileAccessProvider.overrideWithValue(fakeFiles),
          ],
          child: const MaterialApp(home: MigrationPage()),
        ),
      );
      await settle(tester);

      // 1. Custom password AE-2 ZIP -> opens password dialog (`CE-IOS-03`)
      await tester.dragUntilVisible(
        find.byKey(const Key('migration_restore_lan_button')),
        find.byType(ListView),
        const Offset(0, -120),
      );
      await settle(tester);
      await tester.tap(find.byKey(const Key('migration_restore_lan_button')));
      await settle(tester);

      expect(find.byKey(const Key('lan_password_dialog')), findsOneWidget);

      // Submit wrong password -> stays in dialog and shows inline error
      await tester.enterText(
        find.byKey(const Key('migration_lan_password_input')),
        'WrongPass123',
      );
      await tester.tap(find.byKey(const Key('lan_password_submit')));
      await settle(tester);

      expect(find.byKey(const Key('lan_password_dialog')), findsOneWidget);
      expect(find.textContaining('密码错误或加密校验未通过'), findsOneWidget);

      // Submit correct custom password -> transitions to confirmation dialog
      await tester.enterText(
        find.byKey(const Key('migration_lan_password_input')),
        'LanCustom#2026',
      );
      await tester.tap(find.byKey(const Key('lan_password_submit')));
      await settle(tester);

      expect(find.byKey(const Key('lan_password_dialog')), findsNothing);
      expect(find.byKey(const Key('lan_confirm_dialog')), findsOneWidget);
      expect(find.text('预检概况：账本 1 个、账户 1 个、账单 1 条'), findsOneWidget);

      // Cancel first so we also test `"YYjz@23!"` passwordless auto-decrypt flow
      await tester.tap(find.byKey(const Key('migration_confirm_cancel')));
      await settle(tester);
      expect(find.byKey(const Key('lan_confirm_dialog')), findsNothing);

      // 2. Historical `"YYjz@23!"` AE-2 ZIP -> skips password dialog and opens confirmation directly
      nextPick = SelectedBytes('ServerBackup.zip', historicalEncryptedZip);
      await tester.tap(find.byKey(const Key('migration_restore_lan_button')));
      await settle(tester);

      expect(find.byKey(const Key('lan_password_dialog')), findsNothing);
      expect(find.byKey(const Key('lan_confirm_dialog')), findsOneWidget);
      expect(find.textContaining('已自动匹配原版历史加密口令'), findsOneWidget);

      await tester.tap(find.byKey(const Key('migration_confirm_submit')));
      await settle(tester);

      expect(find.byKey(const Key('lan_confirm_dialog')), findsNothing);
      await tester.drag(find.byType(ListView), const Offset(0, 300));
      await settle(tester);
      expect(find.text('账本 1 · 账户 1 · 账单 1 · 便签 1'), findsOneWidget);

      final restoredAsset = await tester.runAsync(
        () => db.select(db.assets).getSingle(),
      );
      expect(restoredAsset?.name, '局域网现金');
      expect(restoredAsset?.balanceMinor, BigInt.from(52080));

      final preservedNotes = await tester.runAsync(
        () => db.select(db.notes).get(),
      );
      expect(preservedNotes!.single.content, '局域网恢复保留便签');

      final preservedCurrencies = await tester.runAsync(
        () => db.select(db.currencies).get(),
      );
      expect(
        preservedCurrencies!.any(
          (c) => c.code == 'HKD' && c.rateToAnchor == '0.92',
        ),
        isTrue,
      );
    },
  );
}
