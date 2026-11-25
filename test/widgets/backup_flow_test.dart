import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tallyisle/app/adaptive.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/data/backup/tally_backup_service.dart';
import 'package:tallyisle/data/backup/webdav_client.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/reminder/reminder_service.dart';
import 'package:tallyisle/domain/rules/cloud_sync_rules.dart';
import 'package:tallyisle/features/backup/backup_page.dart';
import 'package:tallyisle/features/backup/backup_providers.dart';
import 'package:tallyisle/features/backup/mobile_sync_backup_quick_sheet.dart';
import 'package:tallyisle/features/reminder/reminder_providers.dart';
import 'package:tallyisle/platform/files.dart';
import 'package:tallyisle/platform/notifications.dart';

final class _WidgetTestWebDavServer {
  _WidgetTestWebDavServer._(this._server);

  final HttpServer _server;
  final Map<String, Uint8List> files = <String, Uint8List>{};
  final Set<String> collections = <String>{'/dav'};

  String get baseUrl => 'http://127.0.0.1:${_server.port}/dav';

  static Future<_WidgetTestWebDavServer> start() async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final s = _WidgetTestWebDavServer._(http);
    http.listen(s._handle);
    return s;
  }

  Future<void> close() => _server.close(force: true);

  static String _norm(String raw) {
    final d = Uri.decodeFull(raw);
    return d.length > 1 && d.endsWith('/') ? d.substring(0, d.length - 1) : d;
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      await _handleInner(req);
    } catch (_) {
      try {
        await req.response.close();
      } catch (_) {}
    }
  }

  Future<void> _handleInner(HttpRequest req) async {
    final path = _norm(req.uri.path);
    switch (req.method) {
      case 'MKCOL':
        await req.drain<void>();
        collections.add(path);
        req.response.statusCode = HttpStatus.created;
        await req.response.close();
      case 'PROPFIND':
        await req.drain<void>();
        if (!collections.contains(path)) {
          req.response.statusCode = HttpStatus.notFound;
          await req.response.close();
          return;
        }
        final depth = req.headers.value('Depth') ?? '1';
        final xml = StringBuffer(
          '<?xml version="1.0" encoding="utf-8"?><D:multistatus xmlns:D="DAV:">'
          '<D:response><D:href>${Uri.encodeFull('$path/')}</D:href>'
          '<D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>'
          '<D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>',
        );
        if (depth != '0') {
          final prefix = '$path/';
          for (final e in files.entries) {
            if (!e.key.startsWith(prefix)) continue;
            final name = e.key.substring(prefix.length);
            if (name.contains('/')) continue;
            xml.write(
              '<D:response><D:href>${Uri.encodeFull(e.key)}</D:href>'
              '<D:propstat><D:prop>'
              '<D:displayname>$name</D:displayname>'
              '<D:getcontentlength>${e.value.length}</D:getcontentlength>'
              '<D:getlastmodified>${HttpDate.format(DateTime.utc(2026, 11, 11, 8))}</D:getlastmodified>'
              '<D:resourcetype/>'
              '</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>',
            );
          }
        }
        xml.write('</D:multistatus>');
        req.response.statusCode = 207;
        req.response.write(xml.toString());
        await req.response.close();
      case 'PUT':
        final b = BytesBuilder(copy: false);
        await for (final c in req) {
          b.add(c);
        }
        files[path] = b.takeBytes();
        req.response.statusCode = HttpStatus.created;
        await req.response.close();
      case 'MOVE':
        await req.drain<void>();
        final dest = _norm(Uri.parse(req.headers.value('Destination')!).path);
        files[dest] = files.remove(path)!;
        req.response.statusCode = HttpStatus.created;
        await req.response.close();
      case 'GET':
        await req.drain<void>();
        final data = files[path];
        if (data == null) {
          req.response.statusCode = HttpStatus.notFound;
        } else {
          req.response.statusCode = HttpStatus.ok;
          req.response.contentLength = data.length;
          req.response.add(data);
        }
        await req.response.close();
      case 'DELETE':
        await req.drain<void>();
        files.remove(path);
        req.response.statusCode = HttpStatus.noContent;
        await req.response.close();
      default:
        await req.drain<void>();
        req.response.statusCode = HttpStatus.ok;
        await req.response.close();
    }
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    for (var i = 0; i < 80; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
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

  Widget buildApp({
    required AppDatabase db,
    required Directory localDir,
    required Directory attDir,
    required FileAccess fileAccess,
    required ReminderScheduler scheduler,
  }) => ProviderScope(
    retry: (_, _) => null,
    overrides: [
      databaseProvider.overrideWith((ref) async => db),
      reminderSchedulerProvider.overrideWithValue(scheduler),
      backupFileAccessProvider.overrideWithValue(fileAccess),
      backupLocalDirectoryOverrideProvider.overrideWithValue(
        () async => localDir,
      ),
      backupAttachmentsDirectoryOverrideProvider.overrideWithValue(
        () async => attDir,
      ),
    ],
    child: const MaterialApp(home: BackupPage()),
  );

  testWidgets(
    'BackupPage shows 未配置 initially, creates/exports/shares local .tally backup, and restores safely',
    (tester) async {
      HttpOverrides.global = null;
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

      final tempRoot = await tester.runAsync(
        () => Directory.systemTemp.createTemp('tally_widget_bk_1_'),
      );
      addTearDown(() async {
        await tester.runAsync(() async {
          if (tempRoot != null && await tempRoot.exists()) {
            await tempRoot.delete(recursive: true);
          }
        });
      });

      await tester.runAsync(() async {
        await db
            .into(db.notes)
            .insert(
              NotesCompanion.insert(
                title: const Value('备份前便签'),
                content: '原始重要记录',
                createTime: 1000,
                updateTime: 1000,
              ),
            );
      });

      String? savedName;
      Uint8List? savedBytes;
      String? sharedName;

      final fakeFileAccess = FileAccess(
        onSaveBytes: (name, bytes, _) async {
          savedName = name;
          savedBytes = bytes;
        },
        onShareBytes: (name, bytes, _, _) async {
          sharedName = name;
        },
      );

      final localDir = Directory(p.join(tempRoot!.path, 'local'));
      final attDir = Directory(p.join(tempRoot.path, 'att'));

      await tester.pumpWidget(
        buildApp(
          db: db,
          localDir: localDir,
          attDir: attDir,
          fileAccess: fakeFileAccess,
          scheduler: scheduler,
        ),
      );
      await settle(tester);

      // 1. Unconfigured WebDAV clearly shows "未配置" and disables cloud backup button (ADR-017)
      expect(find.byKey(const Key('backup_page')), findsOneWidget);
      expect(find.text('未配置'), findsOneWidget);
      final uploadBtn = tester.widget<FilledButton>(
        find.byKey(const Key('webdav_backup_now_button')),
      );
      expect(uploadBtn.onPressed, isNull);

      // 2. Toggle lightweight / full export switch (§6.3)
      await tester.tap(find.byKey(const Key('include_attachments_switch')));
      await settle(tester);
      expect(find.textContaining('纯数据轻量备份'), findsOneWidget);

      await tester.tap(find.byKey(const Key('include_attachments_switch')));
      await settle(tester);

      // 3. Create local backup, export via SAF/SaveAs, and share
      final createBtn = find.byKey(const Key('local_backup_create_button'));
      await tester.ensureVisible(createBtn);
      await settle(tester);
      await tester.tap(createBtn);
      await settle(tester);
      expect(find.byKey(const Key('local_backups_empty')), findsNothing);
      expect(find.textContaining('便签 1'), findsOneWidget);

      final exportBtn = find.byKey(const Key('local_backup_export_button'));
      await tester.ensureVisible(exportBtn);
      await settle(tester);
      await tester.tap(exportBtn);
      await settle(tester);
      expect(savedName, isNotNull);
      expect(savedBytes, isNotEmpty);

      final shareBtn = find.byKey(const Key('local_backup_share_button'));
      await tester.ensureVisible(shareBtn);
      await settle(tester);
      await tester.tap(shareBtn);
      await settle(tester);
      expect(sharedName, isNotNull);

      // 4. Delete all notes in DB, then restore from the local backup list item
      await tester.runAsync(() => db.delete(db.notes).go());
      expect(await tester.runAsync(() => db.select(db.notes).get()), isEmpty);

      final restoreBtnFinder = find.widgetWithText(TextButton, '恢复').first;
      await tester.ensureVisible(restoreBtnFinder);
      await settle(tester);
      await tester.tap(restoreBtnFinder);
      await settle(tester);
      expect(find.text('确认恢复此本地备份？'), findsOneWidget);

      await tester.tap(find.text('确认恢复'));
      await settle(tester);

      final restoredNotes = await tester.runAsync(
        () => db.select(db.notes).get(),
      );
      expect(restoredNotes, hasLength(1));
      expect(restoredNotes!.single.content, '原始重要记录');

      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'WebDavConfigPage tests connection, saves config, uploads to WebDAV, restores, and deletes remote backup',
    (tester) async {
      HttpOverrides.global = null;
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

      final tempRoot = await tester.runAsync(
        () => Directory.systemTemp.createTemp('tally_widget_bk_2_'),
      );
      final server = await tester.runAsync(_WidgetTestWebDavServer.start);
      addTearDown(() async {
        await tester.runAsync(() async {
          await server?.close();
          if (tempRoot != null && await tempRoot.exists()) {
            await tempRoot.delete(recursive: true);
          }
        });
      });

      await tester.runAsync(() async {
        await db
            .into(db.notes)
            .insert(
              NotesCompanion.insert(
                title: const Value('云端便签'),
                content: 'WebDAV 往返验证',
                createTime: 2000,
                updateTime: 2000,
              ),
            );
      });

      await tester.pumpWidget(
        buildApp(
          db: db,
          localDir: Directory(p.join(tempRoot!.path, 'local')),
          attDir: Directory(p.join(tempRoot.path, 'att')),
          fileAccess: const FileAccess(),
          scheduler: scheduler,
        ),
      );
      await settle(tester);

      // Open WebDavConfigPage
      final openConfigBtn = find.byKey(const Key('open_webdav_config_button'));
      await tester.ensureVisible(openConfigBtn);
      await settle(tester);
      await tester.tap(openConfigBtn);
      await settle(tester);

      expect(find.byKey(const Key('webdav_config_page')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('webdav_url_input')),
        server!.baseUrl,
      );
      await tester.enterText(
        find.byKey(const Key('webdav_username_input')),
        'dav_user',
      );
      await tester.enterText(
        find.byKey(const Key('webdav_password_input')),
        'dav_secret_token',
      );
      await tester.enterText(
        find.byKey(const Key('webdav_remote_dir_input')),
        '/TallyIsleCloud',
      );

      // Select retention count 20 via controlled DropdownButton<int>
      final keepDropdown = find.byKey(const Key('webdav_keep_count_dropdown'));
      await tester.ensureVisible(keepDropdown);
      await settle(tester);
      await tester.tap(keepDropdown);
      await settle(tester);
      await tester.tap(find.text('保留最近 20 份备份').last);
      await settle(tester);

      // Test connection against real loopback server
      final testConnBtn = find.byKey(
        const Key('webdav_test_connection_button'),
      );
      await tester.ensureVisible(testConnBtn);
      await settle(tester);
      await tester.tap(testConnBtn);
      await settle(tester);
      expect(find.text('连接成功，远端目录读写权限验证通过'), findsOneWidget);

      // Save config -> returns to BackupPage showing "已配置"
      final saveCfgBtn = find.byKey(const Key('webdav_save_config_button'));
      await tester.ensureVisible(saveCfgBtn);
      await settle(tester);
      await tester.tap(saveCfgBtn);
      await settle(tester);
      expect(find.byKey(const Key('backup_page')), findsOneWidget);
      expect(find.text('已配置'), findsOneWidget);

      // Upload backup to WebDAV
      final cloudUploadBtn = find.byKey(const Key('webdav_backup_now_button'));
      await tester.ensureVisible(cloudUploadBtn);
      await settle(tester);
      await tester.tap(cloudUploadBtn);
      await settle(tester);

      expect(server.files, hasLength(1));
      final remoteFileName = p.posix.basename(server.files.keys.single);
      expect(
        find.byKey(Key('webdav_backup_item_$remoteFileName')),
        findsOneWidget,
      );

      // Wipe local notes, then restore from WebDAV item
      await tester.runAsync(() => db.delete(db.notes).go());
      expect(await tester.runAsync(() => db.select(db.notes).get()), isEmpty);

      final remoteRestoreBtn = find.byKey(
        Key('webdav_restore_$remoteFileName'),
      );
      await tester.ensureVisible(remoteRestoreBtn);
      await settle(tester);
      await tester.tap(remoteRestoreBtn);
      await settle(tester);
      expect(find.text('确认从 WebDAV 恢复？'), findsOneWidget);
      await tester.tap(find.text('确认恢复'));
      await settle(tester);

      final notesAfter = await tester.runAsync(() => db.select(db.notes).get());
      expect(notesAfter, hasLength(1));
      expect(notesAfter!.single.content, 'WebDAV 往返验证');

      // Delete remote backup item
      final remoteDeleteBtn = find.byKey(Key('webdav_delete_$remoteFileName'));
      await tester.ensureVisible(remoteDeleteBtn);
      await settle(tester);
      await tester.tap(remoteDeleteBtn);
      await settle(tester);
      expect(find.text('删除远端备份？'), findsOneWidget);
      await tester.tap(find.text('删除'));
      await settle(tester);

      expect(server.files, isEmpty);

      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'BackupPage folds inline local & cloud backups to latest 3 with 冲突保护 badges, and BackupHistoryManagementDialog filters, exports, and batch-deletes on 360x640 mobile and 1280x800 desktop without overflow',
    (tester) async {
      HttpOverrides.global = null;
      late final AppDatabase db;
      await tester.runAsync(() async {
        db = AppDatabase(NativeDatabase.memory());
      });
      final scheduler = InMemoryReminderScheduler();
      final tempRoot = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('tally_widget_bk_fold_'),
      ))!;
      final server = (await tester.runAsync(_WidgetTestWebDavServer.start))!;

      addTearDown(() async {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        await tester.pumpWidget(const SizedBox());
        await scheduler.dispose();
        await tester.runAsync(server.close);
        await tester.runAsync(db.close);
        await tester.runAsync(() async {
          if (await tempRoot.exists()) {
            await tempRoot.delete(recursive: true);
          }
        });
      });

      final localDir = Directory(p.join(tempRoot.path, 'local'));
      final attDir = Directory(p.join(tempRoot.path, 'att'));
      late final TallyBackupService service;
      late final Uint8List validArchiveBytes;

      const fiveNamesNewestFirst = <String>[
        'conflict_dev1_20261124_100500.tally',
        'backup_20261124_100400.tally',
        'conflict_dev1_20261124_100300.tally',
        'backup_20261124_100200.tally',
        'backup_20261124_100100.tally',
      ];

      await tester.runAsync(() async {
        await db
            .into(db.notes)
            .insert(
              NotesCompanion.insert(
                title: const Value('折叠与批管验证'),
                content: '共五份备份测试',
                createTime: 3000,
                updateTime: 3000,
              ),
            );
        service = TallyBackupService(
          db,
          reminderService: ReminderService(db, scheduler: scheduler),
          localBackupsDirectoryProvider: () async => localDir,
          attachmentsDirectoryProvider: () async => attDir,
        );
        final davCfg = WebDavConfig(
          serverUrl: server.baseUrl,
          username: 'dav_user',
          password: 'dav_password',
          remoteDirectory: '/TallyFold',
          keepCount: 20,
        );
        await service.saveWebDavConfig(davCfg);
        validArchiveBytes = (await service.createBackupBytes()).bytes;

        await localDir.create(recursive: true);
        server.collections.add('/dav/TallyFold');
        for (var i = 0; i < fiveNamesNewestFirst.length; i++) {
          final name = fiveNamesNewestFirst[i];
          final ts = DateTime(2026, 11, 24, 10, 5 - i);
          final localFile = File(p.join(localDir.path, name));
          await localFile.writeAsBytes(validArchiveBytes, flush: true);
          await localFile.setLastModified(ts);
          server.files['/dav/TallyFold/$name'] = validArchiveBytes;
        }

        // Seed pending conflict cursor pointing to the newest local conflict archive
        await db
            .into(db.preferences)
            .insertOnConflictUpdate(
              PreferencesCompanion.insert(
                key: prefKeyCloudSyncCursor,
                value: jsonEncode(
                  LocalSyncCursor(
                    lastSyncedRevision: 3,
                    lastSyncedDataSha256: 'a' * 64,
                    lastSyncedAtMs: DateTime(
                      2026,
                      11,
                      24,
                      9,
                    ).millisecondsSinceEpoch,
                    targetFingerprint: davCfg.targetFingerprint,
                    lastConflictFileName: 'conflict_dev1_20261124_100500.tally',
                    lastConflictSha256: 'b' * 64,
                  ).toJson(),
                ),
              ),
            );
      });

      String? exportedName;
      Uint8List? exportedBytes;
      final fakeFileAccess = FileAccess(
        onSaveBytes: (name, bytes, _) async {
          exportedName = name;
          exportedBytes = bytes;
        },
      );

      // 1. Render on narrow 360x640 mobile viewport with 1.2x text scale!
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;

      await tester.pumpWidget(
        ProviderScope(
          key: const ValueKey<String>('mobile_fold_scope'),
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            reminderSchedulerProvider.overrideWithValue(scheduler),
            backupFileAccessProvider.overrideWithValue(fakeFileAccess),
            backupLocalDirectoryOverrideProvider.overrideWithValue(
              () async => localDir,
            ),
            backupAttachmentsDirectoryOverrideProvider.overrideWithValue(
              () async => attDir,
            ),
          ],
          child: MediaQuery(
            data: const MediaQueryData(
              size: Size(360, 640),
              textScaler: TextScaler.linear(1.2),
            ),
            child: const MaterialApp(home: BackupPage()),
          ),
        ),
      );
      await settle(tester);
      expect(tester.takeException(), isNull);

      // Verify inline Local Backups shows ONLY the latest 3 items and hides the 2 older ones
      for (final visibleName in fiveNamesNewestFirst.take(3)) {
        expect(
          find.byKey(Key('local_backup_item_$visibleName')),
          findsOneWidget,
        );
      }
      for (final foldedName in fiveNamesNewestFirst.skip(3)) {
        expect(find.byKey(Key('local_backup_item_$foldedName')), findsNothing);
      }
      // Verify inline Cloud Backups also shows ONLY the latest 3 items
      for (final visibleName in fiveNamesNewestFirst.take(3)) {
        expect(
          find.byKey(Key('webdav_backup_item_$visibleName')),
          findsOneWidget,
        );
      }
      for (final foldedName in fiveNamesNewestFirst.skip(3)) {
        expect(find.byKey(Key('webdav_backup_item_$foldedName')), findsNothing);
      }
      expect(find.text('冲突保护'), findsWidgets);
      expect(find.text('查看全部（共 5 份）/ 批量管理'), findsNWidgets(2));

      // 2. Open Local BackupHistoryManagementDialog on 360x640 mobile
      final openLocalAllBtn = find.byKey(
        const Key('open_all_local_backups_button'),
      );
      await tester.ensureVisible(openLocalAllBtn);
      await settle(tester);
      await tester.tap(openLocalAllBtn);
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const Key('backup_history_management_dialog')),
        findsOneWidget,
      );

      // Filter chips: 冲突保护包 -> shows only the 2 conflict items
      await tester.tap(find.byKey(const Key('backup_filter_conflict')));
      await settle(tester);
      expect(
        find.byKey(
          const Key('backup_history_row_conflict_dev1_20261124_100500.tally'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('backup_history_row_backup_20261124_100400.tally'),
        ),
        findsNothing,
      );

      // Filter chips: 常规备份 -> shows routine items, then tap 选中全部冲突包 -> switches & selects all conflicts!
      await tester.tap(find.byKey(const Key('backup_filter_routine')));
      await settle(tester);
      await tester.tap(
        find.byKey(const Key('backup_history_select_conflicts_button')),
      );
      await settle(tester);
      expect(find.text('删除已选 (2)'), findsOneWidget);

      // Single-item export from BackupHistoryManagementDialog
      await tester.tap(
        find.byKey(
          const Key(
            'backup_history_export_conflict_dev1_20261124_100500.tally',
          ),
        ),
      );
      await settle(tester);
      expect(exportedName, 'conflict_dev1_20261124_100500.tally');
      expect(exportedBytes, equals(validArchiveBytes));

      // Test 全选 / 取消全选 on 全部 filter
      await tester.tap(find.byKey(const Key('backup_filter_all')));
      await settle(tester);
      await tester.tap(
        find.byKey(const Key('backup_history_select_all_button')),
      );
      await settle(tester);
      expect(find.text('删除已选 (5)'), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('backup_history_select_all_button')),
      );
      await settle(tester);
      expect(find.text('删除已选 (0)'), findsOneWidget);

      // Select all conflict archives and execute confirmed batch delete!
      await tester.tap(
        find.byKey(const Key('backup_history_select_conflicts_button')),
      );
      await settle(tester);
      expect(find.text('删除已选 (2)'), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('backup_history_batch_delete_button')),
      );
      await settle(tester);
      expect(
        find.byKey(const Key('backup_history_batch_delete_confirm_dialog')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const Key('backup_history_confirm_batch_delete_button')),
      );
      await settle(tester);
      expect(tester.takeException(), isNull);

      final remainingLocal = (await tester.runAsync(service.listLocalBackups))!;
      expect(remainingLocal, hasLength(3));
      expect(
        remainingLocal.any((e) => e.fileName.startsWith('conflict_')),
        isFalse,
      );
      // Deleting the local conflict archive cleared `lastConflictFileName`!
      final cursorAfterLocalClean = (await tester.runAsync(
        service.getSyncCursor,
      ))!;
      expect(cursorAfterLocalClean.lastConflictFileName, isNull);

      // Close mobile sheet
      await tester.tap(find.byKey(const Key('backup_history_close_button')));
      await settle(tester);

      // 3. Switch to 1280x800 Desktop mode and batch-delete Cloud Backups via modal dialog
      tester.view.physicalSize = const Size(1280, 800);
      await tester.pumpWidget(
        ProviderScope(
          key: const ValueKey<String>('desktop_fold_scope'),
          retry: (_, _) => null,
          overrides: [
            desktopModeOverrideProvider.overrideWithValue(true),
            databaseProvider.overrideWith((ref) async => db),
            reminderSchedulerProvider.overrideWithValue(scheduler),
            backupFileAccessProvider.overrideWithValue(fakeFileAccess),
            backupLocalDirectoryOverrideProvider.overrideWithValue(
              () async => localDir,
            ),
            backupAttachmentsDirectoryOverrideProvider.overrideWithValue(
              () async => attDir,
            ),
          ],
          child: const DesktopAdaptiveScope(
            isDesktop: true,
            child: MaterialApp(home: BackupPage()),
          ),
        ),
      );
      await settle(tester);
      expect(tester.takeException(), isNull);

      final openCloudAllBtn = find.byKey(
        const Key('open_all_cloud_backups_button'),
      );
      await tester.ensureVisible(openCloudAllBtn);
      await settle(tester);
      await tester.tap(openCloudAllBtn);
      await settle(tester);
      expect(
        find.byKey(const Key('backup_history_management_dialog')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const Key('backup_history_select_conflicts_button')),
      );
      await settle(tester);
      await tester.tap(
        find.byKey(const Key('backup_history_batch_delete_button')),
      );
      await settle(tester);
      await tester.tap(
        find.byKey(const Key('backup_history_confirm_batch_delete_button')),
      );
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(server.files, hasLength(3));
      expect(server.files.keys.any((k) => k.contains('conflict_')), isFalse);

      await tester.tap(find.byKey(const Key('backup_history_close_button')));
      await settle(tester);

      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'External backup directory banner, first-tap bind UX (BackupPage + QuickSheet + MeQuickCard), needsRebind recovery, and responsive viewports have zero layout errors',
    (tester) async {
      HttpOverrides.global = null;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(360, 640);

      late final AppDatabase db;
      await tester.runAsync(() async {
        db = AppDatabase(NativeDatabase.memory());
      });
      final scheduler = InMemoryReminderScheduler();
      final tempRoot = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('tally_widget_ext_dir_'),
      ))!;
      final extDir1 = Directory(p.join(tempRoot.path, 'ext_1'));
      final extDir2 = Directory(p.join(tempRoot.path, 'ext_2'));
      final supportRoot = Directory(p.join(tempRoot.path, 'headless_support'));
      final attDir = Directory(p.join(tempRoot.path, 'att'));
      TallyBackupService.setHeadlessSupportRootForTest(supportRoot);
      await tester.runAsync(() async {
        await extDir1.create(recursive: true);
        await extDir2.create(recursive: true);
        await supportRoot.create(recursive: true);
      });

      addTearDown(() async {
        TallyBackupService.setHeadlessSupportRootForTest(null);
        await tester.pumpWidget(const SizedBox());
        await scheduler.dispose();
        await tester.runAsync(db.close);
        await tester.runAsync(() async {
          if (await tempRoot.exists()) {
            await tempRoot.delete(recursive: true);
          }
        });
      });

      var cancelPicker = true;
      var activeExtDir = extDir1;
      String? openedDirLocator;

      final fakeFileAccess = FileAccess(
        onPickBackupDirectory: (_) async {
          if (cancelPicker) {
            throw const Failure(FailureCode.cancelled, '已取消选择备份目录');
          }
          return ExternalBackupDirBinding(
            mode: ExternalBackupDirMode.path,
            locator: activeExtDir.path,
            displayPath: '内部存储/Download/TallyBackups',
            boundAtMs: 1764000000000,
          );
        },
        onOpenBackupDirectory: (binding) async {
          openedDirLocator = binding.locator;
        },
      );

      // Note: Do NOT override backupLocalDirectoryOverrideProvider so
      // `!service.hasCustomLocalDirOverride` exercises real first-tap bind UX!
      Widget buildResponsiveBackupPage({
        required Size size,
        required bool isDesktop,
        double textScale = 1.0,
      }) {
        return ProviderScope(
          key: ValueKey<String>(
            'ext_scope_${size.width}x${size.height}_$isDesktop',
          ),
          retry: (_, _) => null,
          overrides: [
            desktopModeOverrideProvider.overrideWithValue(isDesktop),
            databaseProvider.overrideWith((ref) async => db),
            reminderSchedulerProvider.overrideWithValue(scheduler),
            backupFileAccessProvider.overrideWithValue(fakeFileAccess),
            backupAttachmentsDirectoryOverrideProvider.overrideWithValue(
              () async => attDir,
            ),
          ],
          child: DesktopAdaptiveScope(
            isDesktop: isDesktop,
            child: MediaQuery(
              data: MediaQueryData(
                size: size,
                textScaler: TextScaler.linear(textScale),
              ),
              child: const MaterialApp(home: BackupPage()),
            ),
          ),
        );
      }

      // 1. Mobile 360x640 @ 1.2x text scale: unbound state + first-tap cancel -> clean no-op
      await tester.pumpWidget(
        buildResponsiveBackupPage(
          size: const Size(360, 640),
          isDesktop: false,
          textScale: 1.2,
        ),
      );
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const Key('external_backup_dir_banner')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('bind_external_backup_dir_button')),
        findsOneWidget,
      );

      final createBtn = find.byKey(const Key('local_backup_create_button'));
      await tester.ensureVisible(createBtn);
      await settle(tester);
      await tester.tap(createBtn);
      await settle(tester);
      expect(tester.takeException(), isNull);
      // Cancelled picker: no error SnackBar and still unbound with 0 backups!
      expect(find.textContaining('取消'), findsNothing);
      expect(
        find.byKey(const Key('bind_external_backup_dir_button')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('local_backups_empty')), findsOneWidget);

      // 2. Confirming directory picker on first tap of `local_backup_create_button`
      // binds external folder AND immediately writes .tally into extDir1!
      cancelPicker = false;
      await tester.tap(createBtn);
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('外部安全目录：内部存储/Download/TallyBackups'), findsOneWidget);
      expect(find.textContaining('卸载 App 不丢失'), findsNothing);
      expect(
        find.byKey(const Key('change_external_backup_dir_button')),
        findsOneWidget,
      );
      final ext1Files = await tester.runAsync(
        () => extDir1.list().where((e) => e.path.endsWith('.tally')).length,
      );
      expect(ext1Files, 1);

      // 3. Enable startup/focus auto-backup via UI switch, unplug/delete extDir1,
      // and resume app -> auto-backup falls back to sandbox & sets needsRebind = true!
      final startupSwitch = find.byKey(
        const Key('local_backup_trigger_startup'),
      );
      await tester.ensureVisible(startupSwitch);
      await settle(tester);
      await tester.tap(startupSwitch);
      await settle(tester);

      await tester.runAsync(() async {
        await extDir1.delete(recursive: true);
        await db
            .into(db.notes)
            .insert(
              NotesCompanion.insert(
                title: const Value('沙盒回退便签'),
                content: '拔出存储后自动保护',
                createTime: 9000,
                updateTime: 9000,
              ),
            );
      });
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const Key('rebind_external_backup_dir_button')),
        findsOneWidget,
      );

      // Rebind to extDir2 -> migrates sandbox fallback backup into extDir2 & clears error!
      activeExtDir = extDir2;
      final rebindBtn = find.byKey(
        const Key('rebind_external_backup_dir_button'),
      );
      await tester.ensureVisible(rebindBtn);
      await settle(tester);
      await tester.tap(rebindBtn);
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const Key('rebind_external_backup_dir_button')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('change_external_backup_dir_button')),
        findsOneWidget,
      );
      final ext2Files = await tester.runAsync(
        () => extDir2.list().where((e) => e.path.endsWith('.tally')).length,
      );
      expect(ext2Files, greaterThanOrEqualTo(1));

      // 4. Verify all 4 desktop probe viewports (`1280x800`, `1080x700`, `900x700`, `520x600`)
      // render cleanly with zero RenderFlex overflows and `open_external_backup_dir_button` works!
      for (final desktopSize in const <Size>[
        Size(1280, 800),
        Size(1080, 700),
        Size(900, 700),
        Size(520, 600),
      ]) {
        tester.view.physicalSize = desktopSize;
        await tester.pumpWidget(
          buildResponsiveBackupPage(size: desktopSize, isDesktop: true),
        );
        await settle(tester);
        expect(
          tester.takeException(),
          isNull,
          reason: 'Expected zero layout exceptions at $desktopSize',
        );
        expect(
          find.byKey(const Key('open_external_backup_dir_button')),
          findsOneWidget,
        );
      }

      final openDirBtn = find.byKey(
        const Key('open_external_backup_dir_button'),
      );
      await tester.ensureVisible(openDirBtn);
      await settle(tester);
      await tester.tap(openDirBtn);
      await settle(tester);
      expect(openedDirLocator, extDir2.path);

      // 5. Verify QuickSheet (`quick_sheet_local_backup_button`) and `MobileMeSyncQuickCard`
      // (`me-mobile-sync-quick-action`) first-tap UX when unbound!
      final supportRootQuick = Directory(
        p.join(tempRoot.path, 'headless_support_quick'),
      );
      final extQuickDir = Directory(p.join(tempRoot.path, 'ext_quick'));
      late final AppDatabase dbQuick;
      await tester.runAsync(() async {
        await supportRootQuick.create(recursive: true);
        await extQuickDir.create(recursive: true);
        dbQuick = AppDatabase(NativeDatabase.memory());
      });
      TallyBackupService.setHeadlessSupportRootForTest(supportRootQuick);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(dbQuick.close);
      });
      activeExtDir = extQuickDir;

      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpWidget(
        ProviderScope(
          key: const ValueKey<String>('quick_sheet_ext_scope'),
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => dbQuick),
            reminderSchedulerProvider.overrideWithValue(scheduler),
            backupFileAccessProvider.overrideWithValue(fakeFileAccess),
            backupAttachmentsDirectoryOverrideProvider.overrideWithValue(
              () async => attDir,
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (ctx) => Column(
                  children: [
                    MobileMeSyncQuickCard(cardColor: Colors.grey.shade100),
                    ElevatedButton(
                      key: const Key('open_quick_sheet_trigger'),
                      onPressed: () => showMobileSyncBackupQuickSheet(ctx),
                      child: const Text('打开面板'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await settle(tester);

      // Open QuickSheet -> first tap with cancelPicker = true stops cleanly without closing/error
      cancelPicker = true;
      await tester.tap(find.byKey(const Key('open_quick_sheet_trigger')));
      await settle(tester);
      await tester.tap(
        find.byKey(const Key('quick_sheet_local_backup_button')),
      );
      await settle(tester);
      expect(
        find.byKey(const Key('mobile_sync_backup_quick_sheet')),
        findsOneWidget,
      );

      // Confirm picker in QuickSheet -> binds extQuickDir and writes 1st .tally!
      cancelPicker = false;
      await tester.tap(
        find.byKey(const Key('quick_sheet_local_backup_button')),
      );
      await settle(tester);
      final quickFilesAfterSheet = await tester.runAsync(
        () => extQuickDir.list().where((e) => e.path.endsWith('.tally')).length,
      );
      expect(quickFilesAfterSheet, 1);

      // Tap `MobileMeSyncQuickCard` (`me-mobile-sync-quick-action`) -> writes 2nd .tally directly!
      await tester.tap(find.byKey(const Key('me-mobile-sync-quick-action')));
      await settle(tester);
      final quickFilesAfterCard = await tester.runAsync(
        () => extQuickDir.list().where((e) => e.path.endsWith('.tally')).length,
      );
      expect(quickFilesAfterCard, 2);

      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
    },
  );
}
