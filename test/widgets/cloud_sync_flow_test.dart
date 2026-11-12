import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/data/backup/s3_client.dart';
import 'package:tallyisle/data/backup/tally_backup_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/reminder/reminder_service.dart';
import 'package:tallyisle/domain/rules/s3_sigv4_rules.dart';
import 'package:tallyisle/domain/rules/tally_backup.dart';
import 'package:tallyisle/features/backup/backup_page.dart';
import 'package:tallyisle/features/backup/backup_providers.dart';
import 'package:tallyisle/features/reminder/reminder_providers.dart';
import 'package:tallyisle/platform/files.dart';
import 'package:tallyisle/platform/notifications.dart';

final class _WidgetTestS3Server {
  _WidgetTestS3Server._(this._server);

  final HttpServer _server;
  final Map<String, Uint8List> objects = <String, Uint8List>{};
  final Map<String, DateTime> modifiedAt = <String, DateTime>{};
  int _tick = 0;

  static const String bucket = 'widget-bucket';
  static const String accessKey = 'AKIA_WIDGET_S3';
  static const String secretKey = 'widget_s3_secret_value';

  String get endpoint => 'http://127.0.0.1:${_server.port}';

  static Future<_WidgetTestS3Server> start() async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final s = _WidgetTestS3Server._(http);
    http.listen(s._handle);
    return s;
  }

  Future<void> close() => _server.close(force: true);

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
    final builder = BytesBuilder(copy: false);
    await for (final c in req) {
      builder.add(c);
    }
    final body = builder.takeBytes();

    final auth = req.headers.value(HttpHeaders.authorizationHeader) ?? '';
    final amzDate = req.headers.value('x-amz-date') ?? '';
    final contentSha = req.headers.value('x-amz-content-sha256') ?? '';
    if (amzDate.length < 16 || contentSha != sha256Hex(body)) {
      req.response.statusCode = HttpStatus.forbidden;
      await req.response.close();
      return;
    }

    final segs = <String>[
      for (final s in req.uri.pathSegments)
        if (s.isNotEmpty) s,
    ];
    if (segs.isEmpty || segs.first != bucket) {
      req.response.statusCode = HttpStatus.notFound;
      req.response.write('<Error><Code>NoSuchBucket</Code></Error>');
      await req.response.close();
      return;
    }
    final key = segs.skip(1).join('/');

    // Verify SigV4 authorization signature
    final parsedAmzUtc = DateTime.parse(
      '${amzDate.substring(0, 4)}-${amzDate.substring(4, 6)}-${amzDate.substring(6, 8)}'
      'T${amzDate.substring(9, 11)}:${amzDate.substring(11, 13)}:${amzDate.substring(13, 15)}Z',
    );
    final signedHeadersMatch = RegExp(
      r'SignedHeaders=([^,]+)',
    ).firstMatch(auth);
    final extra = <String, String>{};
    if (signedHeadersMatch != null) {
      for (final h in signedHeadersMatch.group(1)!.split(';')) {
        if (h == 'host' || h == 'x-amz-date' || h == 'x-amz-content-sha256') {
          continue;
        }
        final v = req.headers.value(h);
        if (v != null) extra[h] = v;
      }
    }
    final expectedSigned = signS3Request(
      method: req.method,
      target: resolveS3RequestTarget(
        endpoint: endpoint,
        bucket: bucket,
        objectKey: key,
        forcePathStyle: true,
        queryParameters: req.uri.queryParameters,
      ),
      accessKeyId: accessKey,
      secretAccessKey: secretKey,
      region: 'auto',
      payloadBytes: body,
      timestampUtc: parsedAmzUtc,
      extraHeaders: extra,
    );
    if (auth != expectedSigned.authorization) {
      req.response.statusCode = HttpStatus.forbidden;
      await req.response.close();
      return;
    }

    if (req.method == 'GET' &&
        key.isEmpty &&
        req.uri.queryParameters['list-type'] == '2') {
      final prefix = req.uri.queryParameters['prefix'] ?? '';
      final xml = StringBuffer(
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<ListBucketResult><IsTruncated>false</IsTruncated>',
      );
      for (final e in objects.entries) {
        if (!e.key.startsWith(prefix)) continue;
        final mod = (modifiedAt[e.key] ?? DateTime.utc(2026, 11, 11, 12))
            .toIso8601String();
        xml.write(
          '<Contents>'
          '<Key>${e.key}</Key>'
          '<LastModified>$mod</LastModified>'
          '<Size>${e.value.length}</Size>'
          '</Contents>',
        );
      }
      xml.write('</ListBucketResult>');
      req.response.statusCode = HttpStatus.ok;
      req.response.write(xml.toString());
      await req.response.close();
      return;
    }

    switch (req.method) {
      case 'PUT':
        objects[key] = body;
        modifiedAt[key] = DateTime.utc(2026, 11, 11, 12, 0, ++_tick);
        req.response.statusCode = HttpStatus.ok;
        await req.response.close();
      case 'GET':
        final data = objects[key];
        if (data == null) {
          req.response.statusCode = HttpStatus.notFound;
        } else {
          req.response.statusCode = HttpStatus.ok;
          req.response.contentLength = data.length;
          req.response.add(data);
        }
        await req.response.close();
      case 'DELETE':
        objects.remove(key);
        modifiedAt.remove(key);
        req.response.statusCode = HttpStatus.noContent;
        await req.response.close();
      default:
        req.response.statusCode = HttpStatus.methodNotAllowed;
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
      final busyS3 = find
          .byKey(const Key('s3_config_busy'))
          .evaluate()
          .isNotEmpty;
      if (!busyBackup && !busyS3 && i >= 6) {
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

  Widget buildTestApp({
    required AppDatabase db,
    required Directory localDir,
    required Directory attDir,
    required ReminderScheduler scheduler,
    HttpClient Function()? httpFactory,
  }) => ProviderScope(
    retry: (_, _) => null,
    overrides: [
      databaseProvider.overrideWith((ref) async => db),
      reminderSchedulerProvider.overrideWithValue(scheduler),
      backupFileAccessProvider.overrideWithValue(const FileAccess()),
      backupLocalDirectoryOverrideProvider.overrideWithValue(
        () async => localDir,
      ),
      backupAttachmentsDirectoryOverrideProvider.overrideWithValue(
        () async => attDir,
      ),
      if (httpFactory != null)
        backupHttpClientFactoryProvider.overrideWithValue(httpFactory),
    ],
    child: const MaterialApp(home: BackupPage()),
  );

  testWidgets(
    'BackupPage configures S3 via S3ConfigPage, executes multi-device sync, and manages S3 historical backups',
    (tester) async {
      HttpOverrides.global = null;
      late final AppDatabase db;
      await tester.runAsync(() async {
        db = AppDatabase(NativeDatabase.memory());
      });
      final scheduler = InMemoryReminderScheduler();
      final s3Server = (await tester.runAsync(_WidgetTestS3Server.start))!;
      final tempRoot = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('cloud_sync_widget_1_'),
      ))!;

      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await scheduler.dispose();
        await tester.runAsync(s3Server.close);
        await tester.runAsync(db.close);
        await tester.runAsync(() async {
          if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
        });
      });

      var httpCalls = 0;
      await tester.runAsync(() async {
        await db
            .into(db.notes)
            .insert(
              NotesCompanion.insert(
                title: const Value('S3 界面便签'),
                content: '通过 S3 同步与备份',
                createTime: 1000,
                updateTime: 1000,
              ),
            );
      });

      await tester.pumpWidget(
        buildTestApp(
          db: db,
          localDir: Directory(p.join(tempRoot.path, 'local')),
          attDir: Directory(p.join(tempRoot.path, 'att')),
          scheduler: scheduler,
          httpFactory: () {
            httpCalls++;
            return HttpClient();
          },
        ),
      );
      await settle(tester);

      // 1. Title is 云同步与备份, channel defaults to 未启用, zero network calls
      expect(find.text('云同步与备份'), findsOneWidget);
      expect(find.byKey(const Key('cloud_sync_card')), findsOneWidget);
      expect(httpCalls, 0);

      // 2. Open S3ConfigPage, test connection against SigV4 server, and save
      await tester.tap(find.byKey(const Key('open_s3_config_button')));
      await settle(tester);
      expect(find.byKey(const Key('s3_config_page')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('s3_endpoint_input')),
        s3Server.endpoint,
      );
      await tester.enterText(find.byKey(const Key('s3_region_input')), 'auto');
      await tester.enterText(
        find.byKey(const Key('s3_bucket_input')),
        _WidgetTestS3Server.bucket,
      );
      await tester.enterText(
        find.byKey(const Key('s3_access_key_input')),
        _WidgetTestS3Server.accessKey,
      );
      await tester.enterText(
        find.byKey(const Key('s3_secret_key_input')),
        _WidgetTestS3Server.secretKey,
      );
      await tester.enterText(
        find.byKey(const Key('s3_prefix_input')),
        'TallyIsle',
      );

      final testBtn = find.byKey(const Key('s3_test_connection_button'));
      await tester.ensureVisible(testBtn);
      await settle(tester);
      await tester.tap(testBtn);
      await settle(tester);
      expect(find.text('连接成功，S3 签名认证与对象读写删除验证通过'), findsOneWidget);

      final saveBtn = find.byKey(const Key('s3_save_config_button'));
      await tester.ensureVisible(saveBtn);
      await settle(tester);
      await tester.tap(saveBtn);
      await settle(tester);

      expect(find.byKey(const Key('backup_page')), findsOneWidget);
      expect(find.text('已配置'), findsOneWidget);

      // 3. Toggle 自动多端同步 and tap 立即多端同步 -> pushes r1 to S3 AND auto-archives initial 24h .tally backup
      final autoSwitch = find.byKey(const Key('auto_cloud_sync_switch'));
      await tester.ensureVisible(autoSwitch);
      await settle(tester);
      await tester.tap(autoSwitch);
      await settle(tester);

      final syncNowBtn = find.byKey(const Key('cloud_sync_now_button'));
      await tester.ensureVisible(syncNowBtn);
      await settle(tester);
      await tester.tap(syncNowBtn);
      await settle(tester);
      expect(find.textContaining('已同步版本 r1'), findsOneWidget);
      expect(s3Server.objects.containsKey('TallyIsle/sync/head.json'), isTrue);

      final autoArchivedKeys = s3Server.objects.keys
          .where(
            (k) => k.startsWith('TallyIsle/backup_') && k.endsWith('.tally'),
          )
          .toList();
      expect(autoArchivedKeys, hasLength(1));
      final autoArchiveName = p.posix.basename(autoArchivedKeys.single);
      final deleteAutoBtn = find.byKey(Key('webdav_delete_$autoArchiveName'));
      await tester.ensureVisible(deleteAutoBtn);
      await settle(tester);
      await tester.tap(deleteAutoBtn);
      await settle(tester);
      await tester.tap(find.text('删除'));
      await settle(tester);
      expect(
        s3Server.objects.keys.where((k) => k.startsWith('TallyIsle/backup_')),
        isEmpty,
      );

      // 4. Upload, restore, and delete historical S3 backup via unified Cloud Historical Backups card
      final cloudUploadBtn = find.byKey(const Key('webdav_backup_now_button'));
      await tester.ensureVisible(cloudUploadBtn);
      await settle(tester);
      await tester.tap(cloudUploadBtn);
      await settle(tester);

      final backupKeys = s3Server.objects.keys
          .where(
            (k) => k.startsWith('TallyIsle/backup_') && k.endsWith('.tally'),
          )
          .toList();
      expect(backupKeys, hasLength(1));
      final remoteFileName = p.posix.basename(backupKeys.single);
      expect(
        find.byKey(Key('webdav_backup_item_$remoteFileName')),
        findsOneWidget,
      );

      await tester.runAsync(() => db.delete(db.notes).go());
      expect(await tester.runAsync(() => db.select(db.notes).get()), isEmpty);

      final restoreBtn = find.byKey(Key('webdav_restore_$remoteFileName'));
      await tester.ensureVisible(restoreBtn);
      await settle(tester);
      await tester.tap(restoreBtn);
      await settle(tester);
      expect(find.text('确认从 S3 恢复？'), findsOneWidget);
      await tester.tap(find.text('确认恢复'));
      await settle(tester);

      final restoredNotes = await tester.runAsync(
        () => db.select(db.notes).get(),
      );
      expect(restoredNotes, hasLength(1));
      expect(restoredNotes!.single.content, '通过 S3 同步与备份');

      final deleteBtn = find.byKey(Key('webdav_delete_$remoteFileName'));
      await tester.ensureVisible(deleteBtn);
      await settle(tester);
      await tester.tap(deleteBtn);
      await settle(tester);
      expect(find.text('删除远端备份？'), findsOneWidget);
      await tester.tap(find.text('删除'));
      await settle(tester);

      expect(
        s3Server.objects.keys.where((k) => k.startsWith('TallyIsle/backup_')),
        isEmpty,
      );

      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'Conflict Resolution Dialog archives conflict_*.tally locally & remotely and resolves via 采用云端版本',
    (tester) async {
      HttpOverrides.global = null;
      late final AppDatabase peerDb;
      late final AppDatabase uiDb;
      await tester.runAsync(() async {
        peerDb = AppDatabase(NativeDatabase.memory());
        uiDb = AppDatabase(NativeDatabase.memory());
      });
      final scheduler = InMemoryReminderScheduler();
      final s3Server = (await tester.runAsync(_WidgetTestS3Server.start))!;
      final tempRoot = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('cloud_sync_widget_2_'),
      ))!;

      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await scheduler.dispose();
        await tester.runAsync(s3Server.close);
        await tester.runAsync(peerDb.close);
        await tester.runAsync(uiDb.close);
        await tester.runAsync(() async {
          if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
        });
      });

      final sharedS3Cfg = S3Config(
        endpoint: s3Server.endpoint,
        region: 'auto',
        bucket: _WidgetTestS3Server.bucket,
        accessKeyId: _WidgetTestS3Server.accessKey,
        secretAccessKey: _WidgetTestS3Server.secretKey,
        remotePrefix: 'TallyIsle',
      );

      // Peer device pushes r1 ("云端最新便签"), while UI device has local unsynced note ("本机离线便签")
      await tester.runAsync(() async {
        final peerService = TallyBackupService(
          peerDb,
          reminderService: ReminderService(
            peerDb,
            scheduler: InMemoryReminderScheduler(),
          ),
          localBackupsDirectoryProvider: () async =>
              Directory(p.join(tempRoot.path, 'peer_bk')),
          attachmentsDirectoryProvider: () async =>
              Directory(p.join(tempRoot.path, 'peer_att')),
        );
        await peerService.saveS3Config(sharedS3Cfg);
        await peerService.setAutoArchiveBackupEnabled(false);
        await peerDb
            .into(peerDb.notes)
            .insert(
              NotesCompanion.insert(
                title: const Value('Peer'),
                content: '云端最新便签',
                createTime: 5000,
                updateTime: 5000,
              ),
            );
        await peerService.syncNow();

        final uiService = TallyBackupService(
          uiDb,
          reminderService: ReminderService(uiDb, scheduler: scheduler),
          localBackupsDirectoryProvider: () async =>
              Directory(p.join(tempRoot.path, 'ui_bk')),
          attachmentsDirectoryProvider: () async =>
              Directory(p.join(tempRoot.path, 'ui_att')),
        );
        await uiService.saveS3Config(sharedS3Cfg);
        await uiService.setAutoArchiveBackupEnabled(false);
        await uiDb
            .into(uiDb.notes)
            .insert(
              NotesCompanion.insert(
                title: const Value('Local'),
                content: '本机离线便签',
                createTime: 6000,
                updateTime: 6000,
              ),
            );
      });

      final uiLocalBkDir = Directory(p.join(tempRoot.path, 'ui_bk'));
      await tester.pumpWidget(
        buildTestApp(
          db: uiDb,
          localDir: uiLocalBkDir,
          attDir: Directory(p.join(tempRoot.path, 'ui_att')),
          scheduler: scheduler,
        ),
      );
      await settle(tester);

      // Tap 立即多端同步 -> detects conflict and opens Conflict Resolution Dialog!
      await tester.tap(find.byKey(const Key('cloud_sync_now_button')));
      await settle(tester);

      expect(
        find.byKey(const Key('cloud_sync_conflict_dialog')),
        findsOneWidget,
      );
      expect(find.text('检测到多端同步冲突'), findsOneWidget);

      // Tap 稍后处理 -> dialog closes, conflict banner stays visible, and conflict_*.tally exists locally & on S3!
      await tester.tap(find.byKey(const Key('conflict_resolve_later_button')));
      await settle(tester);

      expect(
        find.byKey(const Key('cloud_sync_conflict_banner')),
        findsOneWidget,
      );
      final localConflictFiles = (await tester.runAsync(
        () => uiLocalBkDir
            .list()
            .where((e) => p.basename(e.path).startsWith('conflict_'))
            .toList(),
      ))!;
      expect(localConflictFiles, hasLength(1));
      final conflictFileName = p.basename(localConflictFiles.single.path);
      expect(
        s3Server.objects.containsKey('TallyIsle/$conflictFileName'),
        isTrue,
      );

      // Re-open dialog via 处理冲突 and choose 采用云端版本
      final reopenBtn = find.byKey(const Key('reopen_conflict_dialog_button'));
      await tester.ensureVisible(reopenBtn);
      await settle(tester);
      await tester.tap(reopenBtn);
      await settle(tester);
      await tester.tap(find.byKey(const Key('conflict_use_remote_button')));
      await settle(tester);

      expect(find.byKey(const Key('cloud_sync_conflict_banner')), findsNothing);
      final notesNow = await tester.runAsync(
        () => uiDb.select(uiDb.notes).get(),
      );
      expect(notesNow, hasLength(1));
      expect(notesNow!.single.content, '云端最新便签');

      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'BackupPage toggles all 4 cloud sync triggers, 4 local auto-backup triggers, and interval/keepCount selectors with defaults off',
    (tester) async {
      HttpOverrides.global = null;
      late final AppDatabase db;
      late final TallyBackupService service;
      final scheduler = InMemoryReminderScheduler();
      final s3Server = (await tester.runAsync(_WidgetTestS3Server.start))!;
      final tempRoot = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('cloud_sync_widget_3_'),
      ))!;
      final localDir = Directory(p.join(tempRoot.path, 'local'));
      final attDir = Directory(p.join(tempRoot.path, 'att'));

      await tester.runAsync(() async {
        db = AppDatabase(NativeDatabase.memory());
        service = TallyBackupService(
          db,
          reminderService: ReminderService(db, scheduler: scheduler),
          localBackupsDirectoryProvider: () async => localDir,
          attachmentsDirectoryProvider: () async => attDir,
        );
        await service.saveS3Config(
          S3Config(
            endpoint: s3Server.endpoint,
            region: 'auto',
            bucket: _WidgetTestS3Server.bucket,
            accessKeyId: _WidgetTestS3Server.accessKey,
            secretAccessKey: _WidgetTestS3Server.secretKey,
            remotePrefix: 'TallyIsle',
          ),
        );
      });

      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await scheduler.dispose();
        await tester.runAsync(s3Server.close);
        await tester.runAsync(db.close);
        await tester.runAsync(() async {
          if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
        });
      });

      await tester.pumpWidget(
        buildTestApp(
          db: db,
          localDir: localDir,
          attDir: attDir,
          scheduler: scheduler,
        ),
      );
      await settle(tester);

      // 1. Verify all 8 automatic triggers default to false on fresh install
      for (final keyName in <String>[
        'cloud_sync_trigger_startup',
        'cloud_sync_trigger_exit',
        'cloud_sync_trigger_idle',
        'cloud_sync_trigger_schedule',
        'local_backup_trigger_startup',
        'local_backup_trigger_exit',
        'local_backup_trigger_idle',
        'local_backup_trigger_schedule',
      ]) {
        final sw = tester.widget<SwitchListTile>(find.byKey(Key(keyName)));
        expect(sw.value, isFalse, reason: '$keyName must default to false');
      }

      Future<void> scrollAndTap(Key key) async {
        final finder = find.byKey(key);
        await tester.ensureVisible(finder);
        await settle(tester);
        await tester.tap(finder);
        await settle(tester);
      }

      Future<void> selectDropdownLabel(Key dropdownKey, String label) async {
        final finder = find.byKey(dropdownKey);
        await tester.ensureVisible(finder);
        await settle(tester);
        await tester.tap(finder);
        await settle(tester);
        await tester.tap(find.text(label).last);
        await settle(tester);
      }

      // 2. Toggle all 4 Cloud Sync triggers & change idle minutes (10 分钟) + schedule interval (6 小时)
      await scrollAndTap(const Key('cloud_sync_trigger_startup'));
      await scrollAndTap(const Key('cloud_sync_trigger_exit'));
      await scrollAndTap(const Key('cloud_sync_trigger_idle'));
      await selectDropdownLabel(
        const Key('cloud_sync_idle_minutes_selector'),
        '10 分钟',
      );
      await scrollAndTap(const Key('cloud_sync_trigger_schedule'));
      await selectDropdownLabel(
        const Key('cloud_sync_schedule_interval_selector'),
        '6 小时',
      );

      final savedCloud = (await tester.runAsync(service.getCloudSyncSettings))!;
      expect(savedCloud.syncOnStartup, isTrue);
      expect(savedCloud.syncOnExit, isTrue);
      expect(savedCloud.syncOnIdle, isTrue);
      expect(savedCloud.idleMinutes, 10);
      expect(savedCloud.syncOnSchedule, isTrue);
      expect(savedCloud.scheduleIntervalMinutes, 360);
      expect(savedCloud.autoSyncEnabled, isTrue);

      // 3. Configure Local Auto-Backup keepCount (20 份), toggle all 4 triggers, and select 15 分钟 + 12 小时
      await selectDropdownLabel(
        const Key('local_backup_keep_count_selector'),
        '20 份',
      );
      await scrollAndTap(const Key('local_backup_trigger_startup'));
      await scrollAndTap(const Key('local_backup_trigger_exit'));
      await scrollAndTap(const Key('local_backup_trigger_idle'));
      await selectDropdownLabel(
        const Key('local_backup_idle_minutes_selector'),
        '15 分钟',
      );
      await scrollAndTap(const Key('local_backup_trigger_schedule'));
      await selectDropdownLabel(
        const Key('local_backup_schedule_interval_selector'),
        '12 小时',
      );

      final savedLocal = (await tester.runAsync(
        service.getLocalAutoBackupPolicy,
      ))!;
      expect(savedLocal.keepCount, 20);
      expect(savedLocal.backupOnStartup, isTrue);
      expect(savedLocal.backupOnExit, isTrue);
      expect(savedLocal.backupOnIdle, isTrue);
      expect(savedLocal.idleMinutes, 15);
      expect(savedLocal.backupOnSchedule, isTrue);
      expect(savedLocal.scheduleIntervalMinutes, 720);
      expect(savedLocal.hasAnyTrigger, isTrue);

      // 4. Master auto_cloud_sync_switch turns off all 4 cloud sync triggers cleanly while leaving local policy intact
      await scrollAndTap(const Key('auto_cloud_sync_switch'));
      final afterMasterOff = (await tester.runAsync(
        service.getCloudSyncSettings,
      ))!;
      expect(afterMasterOff.autoSyncEnabled, isFalse);
      expect(afterMasterOff.syncOnStartup, isFalse);
      expect(afterMasterOff.syncOnExit, isFalse);
      expect(afterMasterOff.syncOnIdle, isFalse);
      expect(afterMasterOff.syncOnSchedule, isFalse);

      final localStillOn = (await tester.runAsync(
        service.getLocalAutoBackupPolicy,
      ))!;
      expect(localStillOn.hasAnyTrigger, isTrue);

      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
    },
  );
}
