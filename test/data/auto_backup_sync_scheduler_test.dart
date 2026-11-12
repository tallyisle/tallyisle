import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/backup/backup_sync_scheduler.dart';
import 'package:tallyisle/data/backup/s3_client.dart';
import 'package:tallyisle/data/backup/tally_backup_service.dart';
import 'package:tallyisle/data/backup/webdav_client.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/data/reminder/reminder_service.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/cloud_sync_rules.dart';
import 'package:tallyisle/domain/rules/s3_sigv4_rules.dart';
import 'package:tallyisle/domain/rules/tally_backup.dart';
import 'package:tallyisle/platform/notifications.dart';

/// Loopback HTTP server verifying AWS Signature Version 4 (`AWS4-HMAC-SHA256`)
/// for S3 sync and backup integration tests.
final class _SchedulerSigV4S3Server {
  _SchedulerSigV4S3Server._(this._server);

  final HttpServer _server;
  final Map<String, Uint8List> objects = <String, Uint8List>{};
  final Map<String, DateTime> modifiedAt = <String, DateTime>{};
  final Map<String, int> putCountsByKey = <String, int>{};
  final Map<String, int> getCountsByKey = <String, int>{};
  int requestCount = 0;
  int _tick = 0;

  static const String bucket = 'auto-sync-bucket';
  static const String region = 'auto';
  static const String accessKey = 'AKIA_SCHEDULER_TEST';
  static const String secretKey = 'scheduler_secret_signing_key_01';

  String get endpoint => 'http://127.0.0.1:${_server.port}';

  S3Config buildConfig({String prefix = 'TallyIsle', int keepCount = 5}) =>
      S3Config(
        endpoint: endpoint,
        region: region,
        bucket: bucket,
        accessKeyId: accessKey,
        secretAccessKey: secretKey,
        remotePrefix: prefix,
        forcePathStyle: true,
        keepCount: keepCount,
      );

  static Future<_SchedulerSigV4S3Server> start() async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final server = _SchedulerSigV4S3Server._(http);
    http.listen(server._handle);
    return server;
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
    final bodyBuilder = BytesBuilder(copy: false);
    await for (final chunk in req) {
      bodyBuilder.add(chunk);
    }
    final body = bodyBuilder.takeBytes();
    requestCount++;

    if (!_verifySigV4(req, body)) {
      req.response.statusCode = HttpStatus.forbidden;
      req.response.write('<Error><Code>SignatureDoesNotMatch</Code></Error>');
      await req.response.close();
      return;
    }

    final segs = <String>[
      for (final s in req.uri.pathSegments)
        if (s.isNotEmpty) s,
    ];
    if (segs.isEmpty || segs.first != bucket) {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }
    final key = segs.skip(1).join('/');

    if (req.method == 'GET' &&
        key.isEmpty &&
        req.uri.queryParameters['list-type'] == '2') {
      final prefix = req.uri.queryParameters['prefix'] ?? '';
      final xml = StringBuffer(
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<ListBucketResult><IsTruncated>false</IsTruncated>',
      );
      for (final entry in objects.entries) {
        if (!entry.key.startsWith(prefix)) continue;
        final mod = (modifiedAt[entry.key] ?? DateTime.utc(2026, 11, 12, 8))
            .toIso8601String();
        xml.write(
          '<Contents>'
          '<Key>${entry.key}</Key>'
          '<LastModified>$mod</LastModified>'
          '<Size>${entry.value.length}</Size>'
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
        modifiedAt[key] = DateTime.utc(2026, 11, 12, 8, 0, ++_tick);
        putCountsByKey[key] = (putCountsByKey[key] ?? 0) + 1;
        req.response.statusCode = HttpStatus.ok;
        await req.response.close();
      case 'GET':
        final data = objects[key];
        if (data == null) {
          req.response.statusCode = HttpStatus.notFound;
          req.response.write('<Error><Code>NoSuchKey</Code></Error>');
        } else {
          getCountsByKey[key] = (getCountsByKey[key] ?? 0) + 1;
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

  bool _verifySigV4(HttpRequest req, Uint8List body) {
    final auth = req.headers.value(HttpHeaders.authorizationHeader);
    final amzDate = req.headers.value('x-amz-date');
    final contentSha = req.headers.value('x-amz-content-sha256');
    if (auth == null || amzDate == null || contentSha == null) return false;
    if (amzDate.length < 16 || contentSha != sha256Hex(body)) return false;

    final parsedAmzUtc = DateTime.tryParse(
      '${amzDate.substring(0, 4)}-${amzDate.substring(4, 6)}-${amzDate.substring(6, 8)}'
      'T${amzDate.substring(9, 11)}:${amzDate.substring(11, 13)}:${amzDate.substring(13, 15)}Z',
    );
    if (parsedAmzUtc == null) return false;

    final signedMatch = RegExp(r'SignedHeaders=([^,]+)').firstMatch(auth);
    if (signedMatch == null) return false;
    final extra = <String, String>{};
    for (final h in signedMatch.group(1)!.split(';')) {
      if (h == 'host' || h == 'x-amz-date' || h == 'x-amz-content-sha256') {
        continue;
      }
      final val = req.headers.value(h);
      if (val == null) return false;
      extra[h] = val;
    }

    final segs = <String>[
      for (final s in req.uri.pathSegments)
        if (s.isNotEmpty) s,
    ];
    if (segs.isEmpty) return false;
    final expected = signS3Request(
      method: req.method,
      target: resolveS3RequestTarget(
        endpoint: endpoint,
        bucket: segs.first,
        objectKey: segs.skip(1).join('/'),
        forcePathStyle: true,
        queryParameters: req.uri.queryParameters,
      ),
      accessKeyId: accessKey,
      secretAccessKey: secretKey,
      region: region,
      payloadBytes: body,
      timestampUtc: parsedAmzUtc,
      extraHeaders: extra,
    );
    return auth == expected.authorization;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() {
    HttpOverrides.global = null;
  });

  group('BackupSyncScheduler — Idle Debounce, Anti-Loop, Exit Timeout & Policies', () {
    test(
      'coalesces 3 rapid bookkeeping writes via db.tableUpdates() into 1 sync & 1 local backup after idle window, ignoring non-business tables',
      () async {
        final s3 = await _SchedulerSigV4S3Server.start();
        addTearDown(s3.close);

        final tempRoot = await Directory.systemTemp.createTemp(
          'scheduler_idle_debounce_',
        );
        addTearDown(() async {
          if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
        });

        var now = 1794600000000;
        final db = AppDatabase(NativeDatabase.memory(), nowMs: () => now);
        addTearDown(db.close);

        final service = TallyBackupService(
          db,
          reminderService: ReminderService(
            db,
            scheduler: InMemoryReminderScheduler(),
          ),
          localBackupsDirectoryProvider: () async =>
              Directory(p.join(tempRoot.path, 'local_bk')),
          attachmentsDirectoryProvider: () async =>
              Directory(p.join(tempRoot.path, 'att')),
        );

        await db.select(db.accountBooks).get();
        await service.saveS3Config(s3.buildConfig());
        await service.setAutoArchiveBackupEnabled(false);
        await service.updateCloudSyncTriggers(syncOnIdle: true, idleMinutes: 3);
        await service.saveLocalAutoBackupPolicy(
          const LocalAutoBackupPolicy(
            backupOnIdle: true,
            idleMinutes: 5,
            keepCount: 10,
          ),
        );

        final cloudOutcomes = <CloudSyncOutcome>[];
        final localCreated = <BackupFileMetadata>[];

        final scheduler = BackupSyncScheduler(
          service: service,
          nowMs: () => now,
          onCloudSyncOutcome: cloudOutcomes.add,
          onLocalBackupCreated: localCreated.add,
          // Map 3 min -> 180ms and 5 min -> 300ms for fast real-I/O verification
          idleTimerDurationBuilder: (minutes) =>
              Duration(milliseconds: minutes * 60),
        );
        addTearDown(scheduler.dispose);
        await scheduler.start();

        // 1. Writes to non-business tables (`ti_preference`, `ti_write_command`) MUST NOT arm idle timers!
        await db
            .into(db.preferences)
            .insertOnConflictUpdate(
              PreferencesCompanion.insert(
                key: 'ui_theme_hint',
                value: 'forest',
              ),
            );
        await db
            .into(db.writeCommands)
            .insert(
              WriteCommandsCompanion.insert(
                commandId: 'noop-cmd-check',
                payloadHash: 'noop-hash',
                resultId: '0',
                committedAt: now,
              ),
            );
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(scheduler.pendingLocalChangeAtMs, isNull);
        expect(scheduler.pendingCloudChangeAtMs, isNull);
        expect(s3.requestCount, 0);

        // 2. Perform 3 rapid bookkeeping writes spaced 45ms apart (< 180ms idle window)
        final ledger = LedgerService(db);
        for (var i = 1; i <= 3; i++) {
          now += 1000;
          await ledger.saveRecord(
            commandId: 'rapid-rec-$i',
            draft: RecordDraft(
              bookId: 1,
              type: RecordType.expense,
              money: Money.parse('${i * 10}.50'),
              recordTime: now,
              categoryId: 1,
              remark: '连续记账 #$i',
            ),
          );
          if (i < 3) {
            await Future<void>.delayed(const Duration(milliseconds: 45));
          }
        }

        // Still inside quiet window (70ms < 180ms): 0 syncs and 0 local backups!
        await Future<void>.delayed(const Duration(milliseconds: 70));
        expect(s3.putCountsByKey['TallyIsle/sync/head.json'] ?? 0, 0);
        expect(await service.listLocalBackups(), isEmpty);
        expect(cloudOutcomes, isEmpty);
        expect(localCreated, isEmpty);

        // Wait until both 180ms (cloud) and 300ms (local) quiet windows finish
        await Future<void>.delayed(const Duration(milliseconds: 360));

        // Exactly ONE cloud push (revision 1) and ONE local backup containing all 3 records!
        expect(s3.putCountsByKey['TallyIsle/sync/head.json'], 1);
        expect(cloudOutcomes, hasLength(1));
        expect(cloudOutcomes.single.status, CloudSyncStatus.pushed);
        expect(cloudOutcomes.single.revision, 1);

        expect(localCreated, hasLength(1));
        final savedLocalList = await service.listLocalBackups();
        expect(savedLocalList, hasLength(1));
        expect(savedLocalList.single.manifest?.recordCount, 3);
      },
    );

    test(
      'windowFocus pulls remote when !localChanged && remoteChanged, and suppresses idle loops during pull & restoreFromBytes',
      () async {
        final s3 = await _SchedulerSigV4S3Server.start();
        addTearDown(s3.close);

        final tempRoot = await Directory.systemTemp.createTemp(
          'scheduler_antiloop_',
        );
        addTearDown(() async {
          if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
        });

        var now = 1794700000000;
        final dbDesktop = AppDatabase(
          NativeDatabase.memory(),
          nowMs: () => now,
        );
        final dbPhone = AppDatabase(NativeDatabase.memory(), nowMs: () => now);
        addTearDown(dbDesktop.close);
        addTearDown(dbPhone.close);

        TallyBackupService buildSvc(AppDatabase db, String tag) =>
            TallyBackupService(
              db,
              reminderService: ReminderService(
                db,
                scheduler: InMemoryReminderScheduler(),
              ),
              localBackupsDirectoryProvider: () async =>
                  Directory(p.join(tempRoot.path, 'bk_$tag')),
              attachmentsDirectoryProvider: () async =>
                  Directory(p.join(tempRoot.path, 'att_$tag')),
            );

        final desktopSvc = buildSvc(dbDesktop, 'desktop');
        final phoneSvc = buildSvc(dbPhone, 'phone');

        await dbDesktop.select(dbDesktop.accountBooks).get();
        await dbPhone.select(dbPhone.accountBooks).get();

        final s3Cfg = s3.buildConfig();
        await desktopSvc.saveS3Config(s3Cfg);
        await phoneSvc.saveS3Config(s3Cfg);
        await desktopSvc.setAutoArchiveBackupEnabled(false);
        await phoneSvc.setAutoArchiveBackupEnabled(false);

        // Phone pushes initial r1; Desktop pulls r1 so both share baseline r1
        final phoneLedger = LedgerService(dbPhone);
        await phoneLedger.saveRecord(
          commandId: 'phone-r1',
          draft: RecordDraft(
            bookId: 1,
            type: RecordType.expense,
            money: Money.parse('25.00'),
            recordTime: now,
            categoryId: 1,
            remark: '手机午餐 r1',
          ),
        );
        expect((await phoneSvc.syncNow()).revision, 1);
        expect((await desktopSvc.syncNow()).revision, 1);

        // Enable startup/windowFocus + idle triggers on Desktop
        await desktopSvc.updateCloudSyncTriggers(
          syncOnStartup: true,
          syncOnIdle: true,
          idleMinutes: 1,
        );
        await desktopSvc.saveLocalAutoBackupPolicy(
          const LocalAutoBackupPolicy(backupOnIdle: true, idleMinutes: 1),
        );

        final desktopOutcomes = <CloudSyncOutcome>[];
        final desktopLocalBackups = <BackupFileMetadata>[];
        final desktopScheduler = BackupSyncScheduler(
          service: desktopSvc,
          nowMs: () => now,
          onCloudSyncOutcome: desktopOutcomes.add,
          onLocalBackupCreated: desktopLocalBackups.add,
          idleTimerDurationBuilder: (_) => const Duration(milliseconds: 80),
        );
        addTearDown(desktopScheduler.dispose);
        await desktopScheduler.start();

        // Phone records a second bill and pushes r2 while Desktop was idle/unfocused
        now += 30000;
        await phoneLedger.saveRecord(
          commandId: 'phone-r2',
          draft: RecordDraft(
            bookId: 1,
            type: RecordType.expense,
            money: Money.parse('66.00'),
            recordTime: now,
            categoryId: 1,
            remark: '手机地铁卡充值 r2',
          ),
        );
        expect((await phoneSvc.syncNow()).revision, 2);
        final headPutsBeforeFocus =
            s3.putCountsByKey['TallyIsle/sync/head.json']!;
        expect(headPutsBeforeFocus, 2);

        // Desktop window regains focus (`isInitialStartup: false`):
        // `!localChanged && remoteChanged` -> pulls r2 immediately, preventing stale-desktop conflicts!
        await desktopScheduler.onAppResumedOrFocused(isInitialStartup: false);
        expect(desktopOutcomes, hasLength(1));
        expect(desktopOutcomes.single.status, CloudSyncStatus.pulled);
        expect(desktopOutcomes.single.revision, 2);
        expect(await dbDesktop.select(dbDesktop.records).get(), hasLength(2));

        // Anti-loop proof #1: wait well past 80ms idle window; pull MUST NOT arm idle push or local backup!
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(desktopScheduler.pendingCloudChangeAtMs, isNull);
        expect(desktopScheduler.pendingLocalChangeAtMs, isNull);
        expect(
          s3.putCountsByKey['TallyIsle/sync/head.json'],
          headPutsBeforeFocus,
        );
        expect(desktopLocalBackups, isEmpty);

        // Anti-loop proof #2: restoring a `.tally` archive via restoreFromBytes MUST NOT trigger idle push/backup!
        final packedSnapshot = await phoneSvc.createBackupBytes();
        await desktopSvc.restoreFromBytes(packedSnapshot.bytes);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(desktopScheduler.pendingCloudChangeAtMs, isNull);
        expect(desktopScheduler.pendingLocalChangeAtMs, isNull);
        expect(
          s3.putCountsByKey['TallyIsle/sync/head.json'],
          headPutsBeforeFocus,
        );
        expect(desktopLocalBackups, isEmpty);
      },
    );

    test(
      'onDesktopExitRequested saves local backup and bounds hung HTTP server by timeout without hanging window close',
      () async {
        final releaseHungRequests = Completer<void>();
        final hungHttp = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        hungHttp.listen((req) async {
          await req.drain<void>();
          // Intentionally never respond until tearDown to simulate blackholed network on exit!
          await releaseHungRequests.future;
          try {
            await req.response.close();
          } catch (_) {}
        });
        addTearDown(() async {
          if (!releaseHungRequests.isCompleted) {
            releaseHungRequests.complete();
          }
          await hungHttp.close(force: true);
        });

        final tempRoot = await Directory.systemTemp.createTemp(
          'scheduler_exit_timeout_',
        );
        addTearDown(() async {
          if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
        });

        final db = AppDatabase(
          NativeDatabase.memory(),
          nowMs: () => 1794800000000,
        );
        addTearDown(db.close);

        final service = TallyBackupService(
          db,
          reminderService: ReminderService(
            db,
            scheduler: InMemoryReminderScheduler(),
          ),
          localBackupsDirectoryProvider: () async =>
              Directory(p.join(tempRoot.path, 'local_bk')),
          attachmentsDirectoryProvider: () async =>
              Directory(p.join(tempRoot.path, 'att')),
        );

        await db.select(db.accountBooks).get();
        await service.saveS3Config(
          S3Config(
            endpoint: 'http://127.0.0.1:${hungHttp.port}',
            region: 'auto',
            bucket: 'hung-bucket',
            accessKeyId: 'AKIA_HUNG',
            secretAccessKey: 'secret_hung',
            remotePrefix: 'TallyIsle',
          ),
        );
        await service.updateCloudSyncTriggers(syncOnExit: true);
        await service.saveLocalAutoBackupPolicy(
          const LocalAutoBackupPolicy(backupOnExit: true),
        );

        await LedgerService(db).saveRecord(
          commandId: 'exit-rec-1',
          draft: RecordDraft(
            bookId: 1,
            type: RecordType.expense,
            money: Money.parse('42.00'),
            recordTime: 1794800005000,
            categoryId: 1,
            remark: '关窗前最后一笔账',
          ),
        );

        final scheduler = BackupSyncScheduler(service: service);
        addTearDown(scheduler.dispose);
        await scheduler.start();

        final sw = Stopwatch()..start();
        await scheduler.onDesktopExitRequested(
          timeout: const Duration(milliseconds: 250),
        );
        sw.stop();

        // Bounded cleanly by timeout (well under 2 seconds, never hanging for 30s+ socket timeout)
        expect(sw.elapsedMilliseconds, lessThan(2000));

        // Local exit backup completed cleanly despite the hung remote server!
        final localBackups = await service.listLocalBackups();
        expect(localBackups, hasLength(1));
        expect(localBackups.single.manifest?.recordCount, 1);
      },
    );

    test(
      'handles mobile onAppPaused, overdue idle catch-up on resume, periodic schedule throttling, and local keepCount pruning + digest independence',
      () async {
        final s3 = await _SchedulerSigV4S3Server.start();
        addTearDown(s3.close);

        final tempRoot = await Directory.systemTemp.createTemp(
          'scheduler_schedule_prune_',
        );
        addTearDown(() async {
          if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
        });

        var now = 1794900000000;
        final db = AppDatabase(NativeDatabase.memory(), nowMs: () => now);
        addTearDown(db.close);

        final service = TallyBackupService(
          db,
          reminderService: ReminderService(
            db,
            scheduler: InMemoryReminderScheduler(),
          ),
          localBackupsDirectoryProvider: () async =>
              Directory(p.join(tempRoot.path, 'local_bk')),
          attachmentsDirectoryProvider: () async =>
              Directory(p.join(tempRoot.path, 'att')),
        );

        await db.select(db.accountBooks).get();
        await service.saveS3Config(s3.buildConfig());
        await service.setAutoArchiveBackupEnabled(false);

        // Seed a protected conflict_*.tally file in local backups directory
        final initialBytes = (await service.createBackupBytes()).bytes;
        await service.localTarget.writeBackup(
          'conflict_cafebabe_20261101_000000.tally',
          initialBytes,
        );

        // 1. Digest independence + local keepCount = 2 pruning while preserving conflict_*.tally
        await service.saveLocalAutoBackupPolicy(
          const LocalAutoBackupPolicy(backupOnStartup: true, keepCount: 2),
        );
        final ledger = LedgerService(db);

        for (var i = 1; i <= 3; i++) {
          now += 5000;
          await ledger.saveRecord(
            commandId: 'prune-rec-$i',
            draft: RecordDraft(
              bookId: 1,
              type: RecordType.expense,
              money: Money.parse('${i * 5}.00'),
              recordTime: now,
              categoryId: 1,
              remark: '本地裁剪测试 #$i',
            ),
          );
          final created = await service.runLocalAutoBackupForTrigger(
            AutoTriggerSource.startup,
          );
          expect(created, isNotNull);
        }

        // Routine local backups pruned to 2 newest, while conflict_*.tally is strictly preserved!
        final afterPrune = await service.listLocalBackups();
        expect(afterPrune, hasLength(3));
        expect(
          afterPrune.map((e) => e.fileName),
          contains('conflict_cafebabe_20261101_000000.tally'),
        );
        expect(
          afterPrune.where((e) => !e.fileName.startsWith('conflict_')).length,
          2,
        );

        // Digest independence: local auto-backup is now up-to-date,
        // yet cloud backup `hasLocalDataChanged()` is STILL true and cloud sync still pushes r1!
        expect(await service.hasLocalDataChangedForLocalBackup(), isFalse);
        expect(await service.hasLocalDataChanged(), isTrue);
        expect((await service.syncNow()).revision, 1);

        // Conversely, pushing a new edit to cloud sync does NOT mask `hasLocalDataChangedForLocalBackup()`!
        now += 5000;
        await ledger.saveRecord(
          commandId: 'cloud-only-push',
          draft: RecordDraft(
            bookId: 1,
            type: RecordType.expense,
            money: Money.parse('19.90'),
            recordTime: now,
            categoryId: 1,
            remark: '仅推送云端尚未本地备份',
          ),
        );
        expect((await service.syncNow()).revision, 2);
        expect(await service.hasLocalDataChangedForLocalBackup(), isTrue);

        // 2. Mobile OS timer-freeze catch-up on `onAppResumedOrFocused`
        await service.saveLocalAutoBackupPolicy(
          const LocalAutoBackupPolicy(
            backupOnIdle: true,
            idleMinutes: 5,
            keepCount: 2,
          ),
        );
        await service.updateCloudSyncTriggers(syncOnIdle: true, idleMinutes: 3);

        final scheduler = BackupSyncScheduler(
          service: service,
          nowMs: () => now,
          // Long wall-clock timer simulates OS freezing timers while app is suspended
          idleTimerDurationBuilder: (_) => const Duration(hours: 1),
          scheduleTimerDurationBuilder: (_) => const Duration(milliseconds: 70),
        );
        addTearDown(scheduler.dispose);
        await scheduler.start();

        now += 5000;
        await ledger.saveRecord(
          commandId: 'sleep-catchup-rec',
          draft: RecordDraft(
            bookId: 1,
            type: RecordType.expense,
            money: Money.parse('33.00'),
            recordTime: now,
            categoryId: 1,
            remark: '切后台休眠前记账',
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(scheduler.pendingLocalChangeAtMs, isNotNull);
        expect(scheduler.pendingCloudChangeAtMs, isNotNull);

        // Simulate 6 minutes passing while mobile OS suspended background Dart timers
        now += 6 * 60 * 1000;
        await scheduler.onAppResumedOrFocused(isInitialStartup: false);
        expect(scheduler.pendingLocalChangeAtMs, isNull);
        expect(scheduler.pendingCloudChangeAtMs, isNull);
        expect(await service.hasLocalDataChangedForLocalBackup(), isFalse);
        final headAfterCatchup = CloudSyncHead.fromJson(
          jsonDecode(utf8.decode(s3.objects['TallyIsle/sync/head.json']!))
              as Map<String, Object?>,
        );
        expect(headAfterCatchup.revision, 3);

        // 3. Mobile `onAppPaused` runs `backupOnExit` & `syncOnExit` immediately
        await service.saveLocalAutoBackupPolicy(
          const LocalAutoBackupPolicy(backupOnExit: true, keepCount: 2),
        );
        await service.updateCloudSyncTriggers(
          syncOnIdle: false,
          syncOnExit: true,
        );
        now += 5000;
        await ledger.saveRecord(
          commandId: 'pause-exit-rec',
          draft: RecordDraft(
            bookId: 1,
            type: RecordType.expense,
            money: Money.parse('12.00'),
            recordTime: now,
            categoryId: 1,
            remark: '手机切入后台立即同步',
          ),
        );
        await scheduler.onAppPaused();
        expect(await service.hasLocalDataChangedForLocalBackup(), isFalse);
        final headAfterPause = CloudSyncHead.fromJson(
          jsonDecode(utf8.decode(s3.objects['TallyIsle/sync/head.json']!))
              as Map<String, Object?>,
        );
        expect(headAfterPause.revision, 4);

        // 4. Periodic schedule trigger & interval throttling
        await service.saveLocalAutoBackupPolicy(
          const LocalAutoBackupPolicy(
            backupOnSchedule: true,
            scheduleIntervalMinutes: 30,
            keepCount: 2,
          ),
        );
        await service.updateCloudSyncTriggers(
          syncOnExit: false,
          syncOnSchedule: true,
          scheduleIntervalMinutes: 15,
        );
        // Give stream listeners a moment to arm the 70ms periodic timers
        await Future<void>.delayed(const Duration(milliseconds: 30));

        // Advance logical clock past both 15m and 30m and add a new record
        now += 31 * 60 * 1000;
        await ledger.saveRecord(
          commandId: 'scheduled-rec-1',
          draft: RecordDraft(
            bookId: 1,
            type: RecordType.expense,
            money: Money.parse('55.00'),
            recordTime: now,
            categoryId: 1,
            remark: '定时周期自动同步与备份',
          ),
        );

        await Future<void>.delayed(const Duration(milliseconds: 180));
        final headAfterSchedule = CloudSyncHead.fromJson(
          jsonDecode(utf8.decode(s3.objects['TallyIsle/sync/head.json']!))
              as Map<String, Object?>,
        );
        expect(headAfterSchedule.revision, 5);
        expect(await service.hasLocalDataChangedForLocalBackup(), isFalse);

        // Without advancing `now` by another 15 minutes, subsequent 70ms ticks are throttled (zero extra network requests!)
        final reqCountSnapshot = s3.requestCount;
        await Future<void>.delayed(const Duration(milliseconds: 180));
        expect(s3.requestCount, reqCountSnapshot);
      },
    );
  });
}
