import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as raw_sqlite;
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/migration/lan_zip_crypto.dart';
import 'package:tallyisle/domain/rules/ios_migration_rules.dart';
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
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  testWidgets(
    'MigrationPage: exports .ya2i, blocks empty {} .yi2a before dialog, and imports valid .yi2a via preview confirmation while preserving local notes',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(db.close);
      });
      final scheduler = InMemoryReminderScheduler();
      addTearDown(scheduler.dispose);

      // Seed an existing local note & record in DB
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

      String? savedName;
      Uint8List? savedBytes;
      SelectedBytes nextPick = SelectedBytes(
        'empty.yi2a',
        Uint8List.fromList(utf8.encode('{}')),
      );

      final fakeFiles = FileAccess(
        onSaveBytes: (name, bytes, _) async {
          savedName = name;
          savedBytes = bytes;
        },
        onPickBytes: (_) async => nextPick,
      );

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

      expect(find.byKey(const Key('migration_page')), findsOneWidget);
      expect(find.text('账本 1 · 账户 0 · 账单 1 · 便签 1'), findsOneWidget);

      // 1. Export `.ya2i`
      await tester.tap(find.byKey(const Key('export_ya2i_save_button')));
      await settle(tester);

      expect(savedName, defaultYa2iExportFileName);
      expect(savedBytes, isNotNull);
      final exportedMap =
          jsonDecode(utf8.decode(savedBytes!)) as Map<String, Object?>;
      expect(
        exportedMap['records'],
        isA<List>().having((l) => l.length, 'len', 1),
      );
      expect(find.byKey(const Key('migration_status_banner')), findsOneWidget);

      // 2. Pick empty `{}` `.yi2a` -> intercepted by R1 preflight without dialog or DB loss
      await tester.tap(find.byKey(const Key('import_yi2a_button')));
      await settle(tester);

      expect(find.byKey(const Key('yi2a_confirm_dialog')), findsNothing);
      expect(find.textContaining('不包含有效业务数据'), findsOneWidget);
      final recordsStillIntact = await tester.runAsync(
        () => db.select(db.records).get(),
      );
      expect(recordsStillIntact, hasLength(1));

      // 3. Pick valid `.yi2a` -> preview dialog shows counts -> confirm -> imports & preserves note
      final validYi2a = jsonEncode({
        'books': [
          {'id': 1, 'name': 'iOS迁移账本', 'cdate': 1710000000000, 'uid': ''},
        ],
        'assets': [
          {
            'id': 5,
            'name': 'Apple Card',
            'bal': 300.25,
            'initm': 0,
            'type': 0,
            'cdate': 1710000000000,
            'effect': true,
            'uid': '',
          },
        ],
        'records': [
          {
            'id': 'ios-r1',
            'type': 0,
            'money': 45.50,
            'remark': 'App Store',
            'time': 1710020000000,
            'cat': -1,
            'asset': 5,
            'book': 1,
            'plat': -1,
            'uid': '',
          },
          {
            'id': 'ios-r2',
            'type': 0,
            'money': 18.00,
            'remark': 'iCloud',
            'time': 1710030000000,
            'cat': -1,
            'asset': 5,
            'book': 1,
            'plat': -1,
            'uid': '',
          },
        ],
        'assetBookRefs': [
          {'aid': 5, 'bid': 1},
        ],
        'statStory': [
          {
            'id': 'ios-story-1',
            'story': '订阅支出统计',
            'book_id': 1,
            'sdate': 1710000000000,
            'edate': 1712600000000,
          },
        ],
        'reminders': [
          {'id': 1, 'time': 540, 'tip': '早安记账'},
        ],
      });
      nextPick = SelectedBytes(
        'from_ios.yi2a',
        Uint8List.fromList(utf8.encode(validYi2a)),
      );

      await tester.tap(find.byKey(const Key('import_yi2a_button')));
      await settle(tester);

      expect(find.byKey(const Key('yi2a_confirm_dialog')), findsOneWidget);
      expect(find.text('预检概况：账本 1 个、账户 1 个、账单 2 条'), findsOneWidget);
      expect(find.text('附加关联：专属资产关联 1 条、统计故事 1 条'), findsOneWidget);

      await tester.tap(find.byKey(const Key('migration_confirm_submit')));
      await settle(tester);

      expect(find.byKey(const Key('yi2a_confirm_dialog')), findsNothing);
      expect(find.text('账本 1 · 账户 1 · 账单 2 · 便签 1'), findsOneWidget);
      expect(scheduler.scheduledList, hasLength(1));
    },
  );

  testWidgets(
    'MigrationPage LAN restore: prompts password dialog for custom AE-2 ZIP (retry on wrong password -> unlock -> confirm) and auto-decrypts historical "YYjz@23!" AE-2 ZIP',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(db.close);
      });
      final scheduler = InMemoryReminderScheduler();
      addTearDown(scheduler.dispose);

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
        find.byKey(const Key('restore_lan_backup_button')),
        find.byType(ListView),
        const Offset(0, -120),
      );
      await settle(tester);
      await tester.tap(find.byKey(const Key('restore_lan_backup_button')));
      await settle(tester);

      expect(find.byKey(const Key('lan_password_dialog')), findsOneWidget);

      // Submit wrong password -> stays in dialog and shows inline error
      await tester.enterText(
        find.byKey(const Key('lan_password_input')),
        'WrongPass123',
      );
      await tester.tap(find.byKey(const Key('lan_password_submit')));
      await settle(tester);

      expect(find.byKey(const Key('lan_password_dialog')), findsOneWidget);
      expect(find.textContaining('密码错误或加密校验未通过'), findsOneWidget);

      // Submit correct custom password -> transitions to confirmation dialog
      await tester.enterText(
        find.byKey(const Key('lan_password_input')),
        'LanCustom#2026',
      );
      await tester.tap(find.byKey(const Key('lan_password_submit')));
      await settle(tester);

      expect(find.byKey(const Key('lan_password_dialog')), findsNothing);
      expect(find.byKey(const Key('lan_confirm_dialog')), findsOneWidget);
      expect(find.text('预检概况：账本 1 个、账户 1 个、账单 1 条'), findsOneWidget);

      // Cancel first so we also test `"YYjz@23!"` passwordless auto-decrypt flow!
      await tester.tap(find.byKey(const Key('migration_confirm_cancel')));
      await settle(tester);
      expect(find.byKey(const Key('lan_confirm_dialog')), findsNothing);

      // 2. Historical `"YYjz@23!"` AE-2 ZIP -> skips password dialog and opens confirmation directly!
      nextPick = SelectedBytes('ServerBackup.zip', historicalEncryptedZip);
      await tester.tap(find.byKey(const Key('restore_lan_backup_button')));
      await settle(tester);

      expect(find.byKey(const Key('lan_password_dialog')), findsNothing);
      expect(find.byKey(const Key('lan_confirm_dialog')), findsOneWidget);
      expect(find.textContaining('已自动匹配原版历史加密口令'), findsOneWidget);

      await tester.tap(find.byKey(const Key('migration_confirm_submit')));
      await settle(tester);

      expect(find.byKey(const Key('lan_confirm_dialog')), findsNothing);
      final restoredAsset = await tester.runAsync(
        () => db.select(db.assets).getSingle(),
      );
      expect(restoredAsset?.name, '局域网现金');
      expect(restoredAsset?.balanceMinor, BigInt.from(52080));
    },
  );
}
