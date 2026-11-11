import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tallyisle/app/app.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/backup/webdav_client.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/csv_excel_codec.dart';
import 'package:tallyisle/features/backup/backup_providers.dart';
import 'package:tallyisle/features/csv_transfer/csv_transfer_providers.dart';
import 'package:tallyisle/features/reminder/reminder_providers.dart';
import 'package:tallyisle/platform/files.dart';
import 'package:tallyisle/platform/notifications.dart';

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 60; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 60));
    final busyBackup = find
        .byKey(const Key('webdav_transfer_progress'))
        .evaluate()
        .isNotEmpty;
    final busyConfig = find
        .byKey(const Key('webdav_config_busy'))
        .evaluate()
        .isNotEmpty;
    if (!busyBackup && !busyConfig && i >= 6) {
      break;
    }
  }
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<void> _goBack(WidgetTester tester) async {
  await tester.tap(find.byType(BackButton).last);
  await _settle(tester);
}

final class _TestRig {
  _TestRig({
    required this.db,
    required this.scheduler,
    required this.backupsDir,
    required this.attachmentsDir,
    required this.disposeCleanly,
  });

  final AppDatabase db;
  final InMemoryReminderScheduler scheduler;
  final Directory backupsDir;
  final Directory attachmentsDir;
  final Future<void> Function() disposeCleanly;
}

Future<_TestRig> _openTestRig(WidgetTester tester) async {
  final db = AppDatabase(NativeDatabase.memory());
  final scheduler = InMemoryReminderScheduler();
  final rootTemp = (await tester.runAsync(
    () => Directory.systemTemp.createTemp('m5_integration_'),
  ))!;
  final backupsDir = Directory('${rootTemp.path}/backups');
  final attachmentsDir = Directory('${rootTemp.path}/attachments');

  var closed = false;
  Future<void> closeAll() async {
    if (closed) return;
    closed = true;
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 60));
    await tester.runAsync(db.close);
    await tester.runAsync(scheduler.dispose);
    await tester.runAsync(() async {
      if (await rootTemp.exists()) {
        await rootTemp.delete(recursive: true);
      }
    });
  }

  addTearDown(closeAll);

  Future<void> disposeCleanly() async {
    if (closed) return;
    await tester.pumpWidget(const SizedBox());
    await _settle(tester);
    await tester.pump(const Duration(seconds: 1));
    await closeAll();
  }

  return _TestRig(
    db: db,
    scheduler: scheduler,
    backupsDir: backupsDir,
    attachmentsDir: attachmentsDir,
    disposeCleanly: disposeCleanly,
  );
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets(
    'MePage Data & Backup section navigates to all 5 consolidated pages, legacy /import/penny deep link lands on MigrationPage, and direct /backup/webdav route loads stored config',
    (tester) async {
      final rig = await _openTestRig(tester);
      var httpClientCalls = 0;

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => rig.db),
            reminderSchedulerProvider.overrideWithValue(rig.scheduler),
            backupLocalDirectoryOverrideProvider.overrideWithValue(
              () async => rig.backupsDir,
            ),
            backupAttachmentsDirectoryOverrideProvider.overrideWithValue(
              () async => rig.attachmentsDir,
            ),
            backupHttpClientFactoryProvider.overrideWithValue(() {
              httpClientCalls++;
              return HttpClient();
            }),
          ],
          child: const TallyIsleApp(),
        ),
      );
      await _settle(tester);

      // Lifecycle startup and foreground resume with unconfigured WebDAV/S3 must perform zero network I/O.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _settle(tester);
      expect(httpClientCalls, 0);

      await tester.tap(find.text('我的'));
      await _settle(tester);

      await tester.scrollUntilVisible(
        find.text('数据与备份'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await _settle(tester);
      expect(find.text('数据与备份'), findsOneWidget);
      expect(find.byKey(const Key('me-import-penny')), findsNothing);

      // 1. /backup + nested WebDavConfigPage
      await tester.scrollUntilVisible(
        find.byKey(const Key('me-backup')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await _settle(tester);
      expect(find.text('云同步与备份'), findsOneWidget);
      await tester.tap(find.byKey(const Key('me-backup')));
      await _settle(tester);
      expect(find.byKey(const Key('backup_page')), findsOneWidget);

      await tester.tap(find.byKey(const Key('open_webdav_config_button')));
      await _settle(tester);
      expect(find.byKey(const Key('webdav_config_page')), findsOneWidget);
      await _goBack(tester);
      expect(find.byKey(const Key('backup_page')), findsOneWidget);
      await _goBack(tester);

      // 2..5. Remaining 4 consolidated Data & Backup destinations on MePage
      const routesToVerify = <(Key, Key)>[
        (Key('me-import-csv'), Key('csv_import_page')),
        (Key('me-import-batches'), Key('import_batches_page')),
        (Key('me-export-csv'), Key('csv_export_page')),
        (Key('me-migration'), Key('migration_page')),
      ];

      for (final (tileKey, pageKey) in routesToVerify) {
        await tester.scrollUntilVisible(
          find.byKey(tileKey),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await _settle(tester);
        await tester.tap(find.byKey(tileKey));
        await _settle(tester);

        expect(find.byKey(pageKey), findsOneWidget);

        await _goBack(tester);
        expect(find.text('我的'), findsWidgets);
      }

      await tester.scrollUntilVisible(
        find.text('开发版本'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await _settle(tester);
      expect(
        find.text(
          '数据保存在本机，可选配置私有 WebDAV / S3 云同步与备份；已支持核心记账、资产与多币种（含可选在线汇率）、统计预算、计划提醒、数据迁移备份，以及常用工具、安全锁与桌面/自动记账联动。',
        ),
        findsOneWidget,
      );

      // Legacy deep link `/import/penny` lands cleanly on unified MigrationPage.
      await tester.scrollUntilVisible(
        find.byKey(const Key('me-migration')),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      await _settle(tester);
      final legacyCtx = tester.element(find.byKey(const Key('me-migration')));
      unawaited(GoRouter.of(legacyCtx).push('/import/penny'));
      await _settle(tester);
      expect(find.byKey(const Key('migration_page')), findsOneWidget);
      expect(
        find.byKey(const Key('legacy_import_penny_button')),
        findsOneWidget,
      );
      await _goBack(tester);

      // Direct semantic route `/backup/webdav` (initialConfig == null) loads stored WebDAV config.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(Scaffold).first),
      );
      await tester.runAsync(() async {
        final backupService = await container.read(
          tallyBackupServiceProvider.future,
        );
        await backupService.saveWebDavConfig(
          const WebDavConfig(
            serverUrl: 'https://dav.example.com/dav/',
            username: 'alice',
            password: 'secret-app-password',
            remoteDirectory: '/MyBackups',
            keepCount: 20,
          ),
        );
      });

      final navCtx = tester.element(find.byKey(const Key('me-migration')));
      unawaited(GoRouter.of(navCtx).push('/backup/webdav'));
      await _settle(tester);

      expect(find.byKey(const Key('webdav_config_page')), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('webdav_url_input')))
            .controller!
            .text,
        'https://dav.example.com/dav/',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('webdav_username_input')))
            .controller!
            .text,
        'alice',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('webdav_remote_dir_input')))
            .controller!
            .text,
        '/MyBackups',
      );
      expect(
        find.byKey(const Key('webdav_clear_config_button')),
        findsOneWidget,
      );

      await _goBack(tester);
      await rig.disposeCleanly();
    },
  );

  testWidgets(
    'Cross-module round-trip: CSV batch import -> .tally backup -> batch undo rolls back balances -> .tally restore recovers batch & balances',
    (tester) async {
      final rig = await _openTestRig(tester);

      late int bankId;
      late int walletId;
      await tester.runAsync(() async {
        await rig.db.select(rig.db.accountBooks).get();
        final ledger = LedgerService(rig.db);
        bankId = await ledger.createAsset(
          commandId: 'm5-seed-bank',
          name: '招商银行卡',
          type: AssetType.normal,
          initial: Money.parse('5000.00'),
        );
        walletId = await ledger.createAsset(
          commandId: 'm5-seed-wallet',
          name: '微信钱包',
          type: AssetType.normal,
          initial: Money.parse('1000.00'),
        );
        await rig.db
            .into(rig.db.notes)
            .insert(
              NotesCompanion.insert(
                title: const Value('报税备忘'),
                content: '保存发票扫描件',
                createTime: 1773120000000,
                updateTime: 1773120000000,
              ),
            );
      });

      // Template v3 (13 columns): expense 120.50 from 微信钱包 + transfer 300.00 (fee 2.50) from 招商银行卡 -> 微信钱包.
      final csvBytes = encodeCsvBytes(const [
        [
          '日期',
          '类型',
          '分类',
          '金额',
          '账户',
          '账户2',
          '备注',
          '账单图片',
          '标签',
          '手续费',
          '优惠',
          '不计预算',
          '不计收支',
        ],
        [
          '2026-11-10 12:30',
          '支出',
          '餐饮',
          '120.50',
          '微信钱包',
          '',
          '工作午餐',
          '',
          '#团建',
          '',
          '',
          '0',
          '0',
        ],
        [
          '2026-11-10 15:00',
          '转账',
          '',
          '300.00',
          '招商银行卡',
          '微信钱包',
          '零钱充值',
          '',
          '',
          '2.50',
          '',
          '0',
          '0',
        ],
      ]);

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => rig.db),
            reminderSchedulerProvider.overrideWithValue(rig.scheduler),
            backupLocalDirectoryOverrideProvider.overrideWithValue(
              () async => rig.backupsDir,
            ),
            backupAttachmentsDirectoryOverrideProvider.overrideWithValue(
              () async => rig.attachmentsDir,
            ),
            csvFileAccessProvider.overrideWithValue(
              FileAccess(
                onPickBytes: (_) async =>
                    SelectedBytes('november_v3.csv', csvBytes),
              ),
            ),
          ],
          child: const TallyIsleApp(),
        ),
      );
      await _settle(tester);

      // Step 1: Import CSV batch via MePage -> /import/csv
      await tester.tap(find.text('我的'));
      await _settle(tester);
      await tester.scrollUntilVisible(
        find.byKey(const Key('me-import-csv')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await _settle(tester);
      await tester.tap(find.byKey(const Key('me-import-csv')));
      await _settle(tester);

      await tester.tap(find.byKey(const Key('pick_import_file_button')));
      await _settle(tester);
      expect(find.byKey(const Key('import_preview_card')), findsOneWidget);

      await tester.scrollUntilVisible(
        find.byKey(const Key('confirm_import_button')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await _settle(tester);
      await tester.tap(find.byKey(const Key('confirm_import_button')));
      await _settle(tester);

      late int batchId;
      await tester.runAsync(() async {
        final bank = await (rig.db.select(
          rig.db.assets,
        )..where((t) => t.id.equals(bankId))).getSingle();
        final wallet = await (rig.db.select(
          rig.db.assets,
        )..where((t) => t.id.equals(walletId))).getSingle();
        // 5000.00 - 300.00 - 2.50 = 4697.50 (469750 minor)
        expect(bank.balanceMinor, BigInt.from(469750));
        // 1000.00 - 120.50 + 300.00 = 1179.50 (117950 minor)
        expect(wallet.balanceMinor, BigInt.from(117950));

        final batches = await rig.db.select(rig.db.importPlatforms).get();
        expect(batches, hasLength(1));
        batchId = batches.single.id;

        final importedRecords = await (rig.db.select(
          rig.db.records,
        )..where((t) => t.platformId.equals(batchId))).get();
        // Expense + Transfer + Transfer fee child (type = 12) all bound to batchId
        expect(importedRecords, hasLength(3));
      });

      await _goBack(tester);

      // Step 2: Create local .tally backup via MePage -> /backup
      await tester.scrollUntilVisible(
        find.byKey(const Key('me-backup')),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      await _settle(tester);
      await tester.tap(find.byKey(const Key('me-backup')));
      await _settle(tester);

      final createBtn = find.byKey(const Key('local_backup_create_button'));
      await tester.ensureVisible(createBtn);
      await _settle(tester);
      await tester.tap(createBtn);
      await _settle(tester);

      final backupFiles = (await tester.runAsync(
        () => rig.backupsDir
            .list()
            .where((e) => e.path.endsWith('.tally'))
            .toList(),
      ))!;
      expect(backupFiles, hasLength(1));
      final backupFileName = backupFiles.single.uri.pathSegments.last;
      expect(
        find.byKey(Key('local_backup_item_$backupFileName')),
        findsOneWidget,
      );

      await _goBack(tester);

      // Step 3: Undo CSV batch via semantic route /import/batches/:id (or MePage -> /import/batches)
      await tester.scrollUntilVisible(
        find.byKey(const Key('me-import-batches')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await _settle(tester);
      await tester.tap(find.byKey(const Key('me-import-batches')));
      await _settle(tester);
      expect(find.byKey(Key('import_batch_card_$batchId')), findsOneWidget);

      // Also verify direct /import/batches/:id semantic route
      final batchesCtx = tester.element(
        find.byKey(const Key('import_batches_page')),
      );
      unawaited(GoRouter.of(batchesCtx).push('/import/batches/$batchId'));
      await _settle(tester);
      expect(find.byKey(const Key('import_batch_detail_page')), findsOneWidget);

      await tester.tap(find.byKey(const Key('detail_undo_batch_button')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('confirm_undo_batch_button')));
      await _settle(tester);

      // Verify symmetric balance rollback (including fee 2.50!) and batch deletion
      await tester.runAsync(() async {
        final bank = await (rig.db.select(
          rig.db.assets,
        )..where((t) => t.id.equals(bankId))).getSingle();
        final wallet = await (rig.db.select(
          rig.db.assets,
        )..where((t) => t.id.equals(walletId))).getSingle();
        expect(bank.balanceMinor, BigInt.from(500000));
        expect(wallet.balanceMinor, BigInt.from(100000));

        final batches = await rig.db.select(rig.db.importPlatforms).get();
        expect(batches, isEmpty);
        final importedRecords = await (rig.db.select(
          rig.db.records,
        )..where((t) => t.platformId.equals(batchId))).get();
        expect(importedRecords, isEmpty);
      });

      // Back to MePage from ImportBatchesPage
      await _goBack(tester);

      // Step 4: Restore .tally backup via MePage -> /backup
      await tester.scrollUntilVisible(
        find.byKey(const Key('me-backup')),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      await _settle(tester);
      await tester.tap(find.byKey(const Key('me-backup')));
      await _settle(tester);

      final restoreBtn = find.byKey(Key('local_restore_$backupFileName'));
      await tester.ensureVisible(restoreBtn);
      await _settle(tester);
      await tester.tap(restoreBtn);
      await _settle(tester);
      await tester.tap(find.text('确认恢复'));
      await _settle(tester);

      // Verify DB state (batch, 3 records including fee child, balances, and note) restored 100%
      await tester.runAsync(() async {
        final bank = await (rig.db.select(
          rig.db.assets,
        )..where((t) => t.id.equals(bankId))).getSingle();
        final wallet = await (rig.db.select(
          rig.db.assets,
        )..where((t) => t.id.equals(walletId))).getSingle();
        expect(bank.balanceMinor, BigInt.from(469750));
        expect(wallet.balanceMinor, BigInt.from(117950));

        final batches = await rig.db.select(rig.db.importPlatforms).get();
        expect(batches, hasLength(1));
        expect(batches.single.id, batchId);

        final importedRecords = await (rig.db.select(
          rig.db.records,
        )..where((t) => t.platformId.equals(batchId))).get();
        expect(importedRecords, hasLength(3));

        final notes = await rig.db.select(rig.db.notes).get();
        expect(notes, hasLength(1));
        expect(notes.single.title, '报税备忘');
      });

      // Verify AssetsPage UI immediately reflects restored balances without restart
      await _goBack(tester);
      await tester.tap(find.text('资产'));
      await _settle(tester);
      expect(find.textContaining('4697.50'), findsOneWidget);
      expect(find.textContaining('1179.50'), findsOneWidget);

      await rig.disposeCleanly();
    },
  );
}
