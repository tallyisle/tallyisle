import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tallyisle/app/app.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/core/zip_archive.dart';
import 'package:tallyisle/data/backup/backup_sync_scheduler.dart';
import 'package:tallyisle/data/backup/s3_client.dart';
import 'package:tallyisle/data/backup/tally_backup_service.dart';
import 'package:tallyisle/data/backup/webdav_client.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/data/periodic/periodic_service.dart';
import 'package:tallyisle/data/reminder/reminder_service.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/cloud_sync_rules.dart';
import 'package:tallyisle/domain/rules/periodic_records.dart';
import 'package:tallyisle/domain/rules/s3_sigv4_rules.dart';
import 'package:tallyisle/domain/rules/tally_backup.dart';
import 'package:tallyisle/features/backup/backup_page.dart';
import 'package:tallyisle/features/backup/backup_providers.dart';
import 'package:tallyisle/features/backup/post_restore_refresh.dart';
import 'package:tallyisle/features/budget/budget_providers.dart';
import 'package:tallyisle/features/receipt/receipt_diy_providers.dart';
import 'package:tallyisle/features/reminder/reminder_providers.dart';
import 'package:tallyisle/features/settings/settings_providers.dart';
import 'package:tallyisle/features/templates/template_providers.dart';
import 'package:tallyisle/platform/files.dart';
import 'package:tallyisle/platform/notifications.dart';

final class _AuditS3Server {
  _AuditS3Server._(this._server, {required this.isIpv6});

  final HttpServer _server;
  final bool isIpv6;
  final Map<String, Uint8List> objects = <String, Uint8List>{};
  final Map<String, DateTime> modifiedAt = <String, DateTime>{};
  final List<Uri> listQueries = <Uri>[];
  final List<String?> acceptEncodingHeaders = <String?>[];
  bool gzipResponses = false;
  int requestCount = 0;
  int _tick = 0;

  static const String bucket = 'audit-bucket';
  static const String region = 'auto';
  String expectedAccessKey = 'AKIA_AUDIT_ONE';
  String expectedSecretKey = 'audit_secret_key_one';

  String get endpoint => isIpv6
      ? 'http://[::1]:${_server.port}'
      : 'http://127.0.0.1:${_server.port}';

  S3Config buildConfig({
    String? accessKeyId,
    String? secretAccessKey,
    String prefix = 'TallyIsle',
    bool autoBackupEnabled = false,
  }) => S3Config(
    endpoint: endpoint,
    region: region,
    bucket: bucket,
    accessKeyId: accessKeyId ?? expectedAccessKey,
    secretAccessKey: secretAccessKey ?? expectedSecretKey,
    remotePrefix: prefix,
    forcePathStyle: true,
    autoBackupEnabled: autoBackupEnabled,
  );

  static Future<_AuditS3Server> start({bool ipv6 = false}) async {
    final http = await HttpServer.bind(
      ipv6 ? InternetAddress.loopbackIPv6 : InternetAddress.loopbackIPv4,
      0,
    );
    final server = _AuditS3Server._(http, isIpv6: ipv6);
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
    final builder = BytesBuilder(copy: false);
    await for (final chunk in req) {
      builder.add(chunk);
    }
    final body = builder.takeBytes();
    requestCount++;
    if (req.method == 'GET' || req.method == 'HEAD') {
      acceptEncodingHeaders.add(
        req.headers.value(HttpHeaders.acceptEncodingHeader),
      );
    }

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
      listQueries.add(req.uri);
      final prefix = req.uri.queryParameters['prefix'] ?? '';
      final delimiter = req.uri.queryParameters['delimiter'];
      final xml = StringBuffer(
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<ListBucketResult><IsTruncated>false</IsTruncated>',
      );
      final keys = objects.keys.toList()..sort();
      for (final k in keys) {
        if (!k.startsWith(prefix)) continue;
        if (delimiter != null &&
            delimiter.isNotEmpty &&
            k.substring(prefix.length).contains(delimiter)) {
          continue;
        }
        final mod = (modifiedAt[k] ?? DateTime.utc(2026, 11, 24, 1))
            .toIso8601String();
        xml.write(
          '<Contents>'
          '<Key>$k</Key>'
          '<LastModified>$mod</LastModified>'
          '<Size>${objects[k]!.length}</Size>'
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
        modifiedAt[key] = DateTime.utc(2026, 11, 24, 1, 0, ++_tick);
        req.response.statusCode = HttpStatus.ok;
        await req.response.close();
      case 'GET':
        final data = objects[key];
        if (data == null) {
          req.response.statusCode = HttpStatus.notFound;
          req.response.write('<Error><Code>NoSuchKey</Code></Error>');
        } else if (gzipResponses) {
          final compressed = gzip.encode(data);
          req.response.statusCode = HttpStatus.ok;
          req.response.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
          req.response.contentLength = compressed.length;
          req.response.add(compressed);
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

  bool _verifySigV4(HttpRequest req, Uint8List body) {
    final auth = req.headers.value(HttpHeaders.authorizationHeader);
    final amzDate = req.headers.value('x-amz-date');
    final contentSha = req.headers.value('x-amz-content-sha256');
    final hostHdr = req.headers.value(HttpHeaders.hostHeader);
    if (auth == null || amzDate == null || contentSha == null) return false;
    if (amzDate.length < 16 || contentSha != sha256Hex(body)) return false;
    if (isIpv6 && hostHdr != '[::1]:${_server.port}') return false;

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
      accessKeyId: expectedAccessKey,
      secretAccessKey: expectedSecretKey,
      region: region,
      payloadBytes: body,
      timestampUtc: parsedAmzUtc,
      extraHeaders: extra,
    );
    return auth == expected.authorization;
  }
}

Future<void> _settleWidget(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 60; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump(const Duration(milliseconds: 50));
    final busy = find
        .byKey(const Key('webdav_transfer_progress'))
        .evaluate()
        .isNotEmpty;
    if (!busy && i >= 8) {
      break;
    }
  }
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() {
    HttpOverrides.global = null;
  });

  group('BRAND-001: TallyIsleApp localeResolutionCallback & brandName', () {
    test(
      'brandName returns 帐屿 for Chinese locales and TallyIsle otherwise',
      () {
        expect(brandName(const Locale('zh')), '帐屿');
        expect(brandName(const Locale('zh', 'CN')), '帐屿');
        expect(brandName(const Locale('zh', 'TW')), '帐屿');
        expect(brandName(const Locale('en')), 'TallyIsle');
        expect(brandName(const Locale('en', 'US')), 'TallyIsle');
        expect(brandName(const Locale('ja', 'JP')), 'TallyIsle');
      },
    );

    testWidgets(
      'TallyIsleApp resolves OS Locale(en) / non-Chinese -> TallyIsle and Locale(zh) -> 帐屿',
      timeout: const Timeout(Duration(seconds: 30)),
      (tester) async {
        late final AppDatabase db;
        await tester.runAsync(() async {
          db = AppDatabase(NativeDatabase.memory());
        });
        final reminderScheduler = InMemoryReminderScheduler();
        addTearDown(() async {
          tester.platformDispatcher.clearLocalesTestValue();
          await tester.pumpWidget(const SizedBox());
          await reminderScheduler.dispose();
          await tester.runAsync(db.close);
        });

        Widget buildSubject() => ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            reminderSchedulerProvider.overrideWithValue(reminderScheduler),
          ],
          child: const TallyIsleApp(),
        );

        // 1. English OS -> Locale('en') -> title 'TallyIsle'
        tester.platformDispatcher.localesTestValue = const <Locale>[
          Locale('en', 'US'),
        ];
        await tester.pumpWidget(buildSubject());
        await _settleWidget(tester);

        var matApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
        expect(matApp.locale, isNull);
        final resolvedEn = matApp.localeResolutionCallback!(
          const Locale('en', 'US'),
          matApp.supportedLocales,
        );
        expect(resolvedEn, const Locale('en'));
        final innerCtxEn = tester.element(find.byType(Scaffold).first);
        expect(matApp.onGenerateTitle!(innerCtxEn), 'TallyIsle');

        // 2. Non-Chinese OS (fr_FR) -> strictly Locale('en') -> 'TallyIsle'
        tester.platformDispatcher.localesTestValue = const <Locale>[
          Locale('fr', 'FR'),
        ];
        await tester.pump();
        await _settleWidget(tester);
        matApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
        expect(
          matApp.localeResolutionCallback!(
            const Locale('fr', 'FR'),
            matApp.supportedLocales,
          ),
          const Locale('en'),
        );
        expect(
          matApp.onGenerateTitle!(tester.element(find.byType(Scaffold).first)),
          'TallyIsle',
        );

        // 3. Chinese OS -> Locale('zh') -> title '帐屿'
        tester.platformDispatcher.localesTestValue = const <Locale>[
          Locale('zh', 'CN'),
        ];
        await tester.pump();
        await _settleWidget(tester);
        matApp = tester.widget<MaterialApp>(find.byType(MaterialApp));
        expect(
          matApp.localeResolutionCallback!(
            const Locale('zh', 'CN'),
            matApp.supportedLocales,
          ),
          const Locale('zh'),
        );
        expect(
          matApp.onGenerateTitle!(tester.element(find.byType(Scaffold).first)),
          '帐屿',
        );

        await tester.pumpWidget(const SizedBox());
        await _settleWidget(tester);
      },
    );
  });

  group(
    'S-01 & S-02: Immutable format: 2 revisions, mid-push safety, legacy conflict & atomic attachment swap',
    () {
      test(
        'writes immutable db_r<rev>_<sha16>.tally, prunes r1 keeping r3+r2, keeps r3 pullable on mid-push failure, and protects legacy format: 1',
        () async {
          final s3 = await _AuditS3Server.start();
          addTearDown(s3.close);
          final tempRoot = await Directory.systemTemp.createTemp('audit_s01_');
          addTearDown(() async {
            if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
          });

          var now = 1795100000000;
          final dbA = AppDatabase(NativeDatabase.memory(), nowMs: () => now);
          final dbB = AppDatabase(NativeDatabase.memory(), nowMs: () => now);
          addTearDown(dbA.close);
          addTearDown(dbB.close);

          TallyBackupService makeSvc(AppDatabase db, String name) =>
              TallyBackupService(
                db,
                reminderService: ReminderService(
                  db,
                  scheduler: InMemoryReminderScheduler(),
                ),
                localBackupsDirectoryProvider: () async =>
                    Directory(p.join(tempRoot.path, 'bk_$name')),
                attachmentsDirectoryProvider: () async =>
                    Directory(p.join(tempRoot.path, 'att_$name')),
              );

          final svcA = makeSvc(dbA, 'a');
          final svcB = makeSvc(dbB, 'b');
          await dbA.select(dbA.accountBooks).get();
          await dbB.select(dbB.accountBooks).get();
          await svcA.saveS3Config(s3.buildConfig());
          await svcB.saveS3Config(s3.buildConfig());
          await svcA.setAutoArchiveBackupEnabled(false);
          await svcB.setAutoArchiveBackupEnabled(false);

          final ledgerA = LedgerService(dbA);
          final pathsByRev = <int, String>{};
          for (var rev = 1; rev <= 3; rev++) {
            now += 5000;
            await ledgerA.saveRecord(
              commandId: 's01-rec-$rev',
              draft: RecordDraft(
                bookId: 1,
                type: RecordType.expense,
                money: Money.parse('${rev * 10}.00'),
                recordTime: now,
                categoryId: 1,
                remark: '版本 $rev',
              ),
            );
            final out = await svcA.syncNow();
            expect(out.status, CloudSyncStatus.pushed);
            expect(out.revision, rev);
            pathsByRev[rev] = out.remoteHead!.databasePath;
          }

          // Never writes sync/latest_db.tally; r3 + r2 kept, r1 pruned!
          expect(
            s3.objects.containsKey('TallyIsle/sync/latest_db.tally'),
            isFalse,
          );
          expect(s3.objects.containsKey('TallyIsle/${pathsByRev[1]}'), isFalse);
          expect(s3.objects.containsKey('TallyIsle/${pathsByRev[2]}'), isTrue);
          expect(s3.objects.containsKey('TallyIsle/${pathsByRev[3]}'), isTrue);

          // Simulate mid-push failure on r4 right before head.json upload: r3 remains pullable!
          now += 5000;
          await ledgerA.saveRecord(
            commandId: 's01-rec-4-aborted',
            draft: RecordDraft(
              bookId: 1,
              type: RecordType.expense,
              money: Money.parse('99.00'),
              recordTime: now,
              categoryId: 1,
              remark: '断网未提交 r4',
            ),
          );
          await expectLater(
            svcA.syncNow(
              beforePushCommitForTest: () =>
                  throw const Failure(FailureCode.remoteUnavailable, '模拟断网'),
            ),
            throwsA(isA<Failure>()),
          );

          final pullB = await svcB.syncNow();
          expect(pullB.status, CloudSyncStatus.pulled);
          expect(pullB.revision, 3);
          expect(await dbB.select(dbB.records).get(), hasLength(3));

          // Legacy format: 1 head.json + sync/latest_db.tally routes into conflict protection!
          final s3Legacy = await _AuditS3Server.start();
          addTearDown(s3Legacy.close);
          final legacyBytes = (await svcB.createBackupBytes()).bytes;
          s3Legacy.objects['TallyIsle/sync/latest_db.tally'] = legacyBytes;
          s3Legacy.objects['TallyIsle/sync/head.json'] = Uint8List.fromList(
            utf8.encode(
              jsonEncode(<String, Object?>{
                'format': 1,
                'revision': 5,
                'dataSha256': 'b' * 64,
                'updatedAtMs': now,
                'deviceId': 'old-v1',
                'deviceName': '旧版客户端',
                'recordCount': 3,
                'attachmentFiles': <String>[],
              }),
            ),
          );

          final dbFresh = AppDatabase(
            NativeDatabase.memory(),
            nowMs: () => now,
          );
          addTearDown(dbFresh.close);
          await dbFresh.select(dbFresh.accountBooks).get();
          final svcFresh = makeSvc(dbFresh, 'fresh');
          await svcFresh.saveS3Config(s3Legacy.buildConfig());
          await svcFresh.setAutoArchiveBackupEnabled(false);

          final legacyConflict = await svcFresh.syncNow();
          expect(legacyConflict.status, CloudSyncStatus.conflict);
          expect(
            s3Legacy.objects['TallyIsle/sync/latest_db.tally'],
            equals(legacyBytes),
          );

          final legacyResolved = await svcFresh.syncNow(
            resolution: SyncConflictResolution.useLocal,
          );
          expect(legacyResolved.status, CloudSyncStatus.pushed);
          expect(legacyResolved.revision, 6);
          expect(
            s3Legacy.objects.keys.any(
              (k) => k.startsWith('TallyIsle/conflict_'),
            ),
            isTrue,
          );
        },
      );

      test(
        'S-02: stages attachments in sibling .staging_<opId>, rolls back .bak on failure, and persists cursor ONLY after swap succeeds',
        () async {
          final s3 = await _AuditS3Server.start();
          addTearDown(s3.close);
          final tempRoot = await Directory.systemTemp.createTemp('audit_s02_');
          addTearDown(() async {
            if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
          });

          final dbA = AppDatabase(NativeDatabase.memory());
          final dbB = AppDatabase(NativeDatabase.memory());
          addTearDown(dbA.close);
          addTearDown(dbB.close);
          await dbA.select(dbA.accountBooks).get();
          await dbB.select(dbB.accountBooks).get();

          final attA = Directory(p.join(tempRoot.path, 'att_a'))
            ..createSync(recursive: true);
          final attB = Directory(p.join(tempRoot.path, 'att_b'))
            ..createSync(recursive: true);
          final remoteImg = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);
          final oldLocalImg = Uint8List.fromList(<int>[9, 8, 7]);
          await File(p.join(attA.path, 'remote.jpg')).writeAsBytes(remoteImg);
          await File(
            p.join(attB.path, 'keep_local.jpg'),
          ).writeAsBytes(oldLocalImg);

          final svcA = TallyBackupService(
            dbA,
            reminderService: ReminderService(
              dbA,
              scheduler: InMemoryReminderScheduler(),
            ),
            localBackupsDirectoryProvider: () async =>
                Directory(p.join(tempRoot.path, 'bk_a')),
            attachmentsDirectoryProvider: () async => attA,
          );
          await svcA.saveS3Config(s3.buildConfig());
          await svcA.setAutoArchiveBackupEnabled(false);
          expect((await svcA.syncNow()).revision, 1);

          var failSwap = true;
          var sawSiblingStagingDir = false;
          final svcB = TallyBackupService(
            dbB,
            reminderService: ReminderService(
              dbB,
              scheduler: InMemoryReminderScheduler(),
            ),
            localBackupsDirectoryProvider: () async =>
                Directory(p.join(tempRoot.path, 'bk_b')),
            attachmentsDirectoryProvider: () async => attB,
            beforeAttachmentSwapFinalizeForTest: () async {
              final siblings = tempRoot.listSync();
              sawSiblingStagingDir = siblings.any(
                (e) => e.path.startsWith('${attB.path}.staging_'),
              );
              if (failSwap) {
                throw const FileSystemException('simulated rename failure');
              }
            },
          );
          await svcB.saveS3Config(s3.buildConfig());
          await svcB.setAutoArchiveBackupEnabled(false);

          // 1. Mid-swap failure rolls back .bak -> attB and leaves sync cursor at revision 0!
          await expectLater(
            svcB.syncNow(resolution: SyncConflictResolution.useRemote),
            throwsA(
              isA<Failure>().having(
                (f) => f.code,
                'code',
                FailureCode.storageUnavailable,
              ),
            ),
          );
          expect(sawSiblingStagingDir, isTrue);
          expect(
            await File(p.join(attB.path, 'keep_local.jpg')).readAsBytes(),
            equals(oldLocalImg),
          );
          expect((await svcB.getSyncCursor()).lastSyncedRevision, 0);

          // 2. Also verify restoreFromBytes rolls back .bak on swap failure
          final archiveBytes = (await svcA.createBackupBytes()).bytes;
          await expectLater(
            svcB.restoreFromBytes(archiveBytes),
            throwsA(
              isA<Failure>().having(
                (f) => f.code,
                'code',
                FailureCode.storageUnavailable,
              ),
            ),
          );
          expect(
            await File(p.join(attB.path, 'keep_local.jpg')).readAsBytes(),
            equals(oldLocalImg),
          );

          // 3. Allowing swap to finish atomically replaces attachments and updates cursor to r1!
          failSwap = false;
          final okPull = await svcB.syncNow(
            resolution: SyncConflictResolution.useRemote,
          );
          expect(okPull.status, CloudSyncStatus.pulled);
          expect((await svcB.getSyncCursor()).lastSyncedRevision, 1);
          expect(
            await File(p.join(attB.path, 'remote.jpg')).readAsBytes(),
            equals(remoteImg),
          );
          expect(
            await File(p.join(attB.path, 'keep_local.jpg')).exists(),
            isFalse,
          );
        },
      );
    },
  );

  group(
    'S-03, S-04, S-06, S-07, S-08 & S-09: Protocol, Guard, Mutex & Validation Hardening',
    () {
      test(
        'S-03: switching S3 accessKeyId on same endpoint scopes cursor and prevents silent overwrite',
        () async {
          final s3 = await _AuditS3Server.start();
          addTearDown(s3.close);
          final tempRoot = await Directory.systemTemp.createTemp('audit_s03_');
          addTearDown(() async {
            if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
          });

          final db = AppDatabase(NativeDatabase.memory());
          addTearDown(db.close);
          await db.select(db.accountBooks).get();
          final svc = TallyBackupService(
            db,
            reminderService: ReminderService(
              db,
              scheduler: InMemoryReminderScheduler(),
            ),
            localBackupsDirectoryProvider: () async =>
                Directory(p.join(tempRoot.path, 'bk')),
            attachmentsDirectoryProvider: () async =>
                Directory(p.join(tempRoot.path, 'att')),
          );
          await svc.saveS3Config(s3.buildConfig(accessKeyId: 'AKIA_AUDIT_ONE'));
          await svc.setAutoArchiveBackupEnabled(false);

          await LedgerService(db).saveRecord(
            commandId: 's03-rec-1',
            draft: RecordDraft(
              bookId: 1,
              type: RecordType.expense,
              money: Money.parse('18.00'),
              recordTime: 1795200000000,
              categoryId: 1,
              remark: '账号一账单',
            ),
          );
          expect((await svc.syncNow()).revision, 1);

          // Switch server & client to second IAM user on same bucket where a different r1 already exists:
          s3.expectedAccessKey = 'AKIA_AUDIT_TWO';
          s3.expectedSecretKey = 'audit_secret_key_two';
          final otherHead = CloudSyncHead(
            revision: 1,
            dataSha256: 'c' * 64,
            updatedAtMs: 1795200050000,
            deviceId: 'other-user-dev',
            deviceName: '账号二手机',
            recordCount: 5,
            attachmentFiles: const <String>[],
          );
          s3.objects['TallyIsle/sync/head.json'] = Uint8List.fromList(
            utf8.encode(jsonEncode(otherHead.toJson())),
          );
          await svc.saveS3Config(
            s3.buildConfig(
              accessKeyId: 'AKIA_AUDIT_TWO',
              secretAccessKey: 'audit_secret_key_two',
            ),
          );

          final outcome = await svc.syncNow();
          expect(outcome.status, CloudSyncStatus.conflict);
        },
      );

      test(
        'S-04: WebDavClient and S3Client send Accept-Encoding: identity and handle transparent gzip decompression',
        () async {
          final payload = Uint8List.fromList(
            utf8.encode('gzip-reverse-proxy-payload-' * 120),
          );

          // 1. S3 gzip GET
          final s3 = await _AuditS3Server.start()
            ..gzipResponses = true;
          addTearDown(s3.close);
          s3.objects['TallyIsle/test.bin'] = payload;
          final s3Client = S3Client(s3.buildConfig());
          final s3Downloaded = await s3Client.getObjectOrNull('test.bin');
          expect(s3Downloaded, equals(payload));
          expect(s3.acceptEncodingHeaders, contains('identity'));

          // 2. WebDAV gzip GET + HEAD (via MOVE 409 fallback PUT + HEAD)
          final davHttp = await HttpServer.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          final davAcceptEncodings = <String?>[];
          davHttp.listen((req) async {
            await req.drain<void>();
            if (req.method == 'GET' || req.method == 'HEAD') {
              davAcceptEncodings.add(
                req.headers.value(HttpHeaders.acceptEncodingHeader),
              );
            }
            if (req.method == 'PROPFIND') {
              req.response.statusCode = 207;
              req.response.write('<d:multistatus xmlns:d="DAV:"/>');
              await req.response.close();
              return;
            }
            if (req.method == 'PUT' || req.method == 'DELETE') {
              req.response.statusCode = HttpStatus.created;
              await req.response.close();
              return;
            }
            if (req.method == 'MOVE') {
              req.response.statusCode = HttpStatus.conflict;
              await req.response.close();
              return;
            }
            final compressed = gzip.encode(payload);
            req.response.statusCode = HttpStatus.ok;
            req.response.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
            req.response.headers.set(
              HttpHeaders.contentLengthHeader,
              '${compressed.length}',
            );
            if (req.method == 'GET') {
              req.response.add(compressed);
            }
            await req.response.close();
          });
          addTearDown(() => davHttp.close(force: true));

          final davClient = WebDavClient(
            WebDavConfig(
              serverUrl: 'http://127.0.0.1:${davHttp.port}/dav',
              username: 'u',
              password: 'p',
              remoteDirectory: '/TallyIsle',
            ),
          );
          final davDownloaded = await davClient.downloadBackup(
            'backup_1.tally',
          );
          expect(davDownloaded, equals(payload));
          await davClient.uploadBackup('backup_1.tally', payload);
          expect(davAcceptEncodings.length, greaterThanOrEqualTo(2));
          expect(davAcceptEncodings, everyElement('identity'));
        },
      );

      test(
        'S-06: runSilentAutoBackupIfNeeded returns null immediately on CloudBackendType.none and triggers via BackupSyncScheduler on resume',
        () async {
          final s3 = await _AuditS3Server.start();
          addTearDown(s3.close);
          final tempRoot = await Directory.systemTemp.createTemp('audit_s06_');
          addTearDown(() async {
            if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
          });

          var now = 1795300000000;
          final db = AppDatabase(NativeDatabase.memory(), nowMs: () => now);
          addTearDown(db.close);
          await db.select(db.accountBooks).get();

          final svc = TallyBackupService(
            db,
            reminderService: ReminderService(
              db,
              scheduler: InMemoryReminderScheduler(),
            ),
            localBackupsDirectoryProvider: () async =>
                Directory(p.join(tempRoot.path, 'bk')),
            attachmentsDirectoryProvider: () async =>
                Directory(p.join(tempRoot.path, 'att')),
          );

          // Save S3 with autoBackupEnabled: true, then explicitly disable backend -> none!
          await svc.saveS3Config(s3.buildConfig(autoBackupEnabled: true));
          await svc.setCloudBackend(CloudBackendType.none);
          await LedgerService(db).saveRecord(
            commandId: 's06-rec-1',
            draft: RecordDraft(
              bookId: 1,
              type: RecordType.expense,
              money: Money.parse('20.00'),
              recordTime: now,
              categoryId: 1,
              remark: '通道未启用静默守卫',
            ),
          );

          s3.requestCount = 0;
          expect(await svc.runSilentAutoBackupIfNeeded(), isNull);
          expect(s3.requestCount, 0);
          expect(await svc.listLocalBackups(), isEmpty);

          // Re-enable S3 and verify BackupSyncScheduler.onAppResumedOrFocused runs 24h silent cloud backup!
          await svc.setCloudBackend(CloudBackendType.s3);
          final uploadedEvents = <BackupFileMetadata>[];
          final scheduler = BackupSyncScheduler(
            service: svc,
            nowMs: () => now,
            onCloudBackupUploaded: uploadedEvents.add,
          );
          addTearDown(scheduler.dispose);
          await scheduler.start();

          now += const Duration(hours: 25).inMilliseconds;
          await scheduler.onAppResumedOrFocused(isInitialStartup: false);
          expect(uploadedEvents, hasLength(1));
          expect(
            s3.objects.keys.any((k) => k.startsWith('TallyIsle/backup_')),
            isTrue,
          );
        },
      );

      test(
        'S-07: serializes concurrent syncNow, createLocalBackup, uploadToActiveCloudBackup & restoreFromBytes in strict FIFO order',
        () async {
          final s3 = await _AuditS3Server.start();
          addTearDown(s3.close);
          final tempRoot = await Directory.systemTemp.createTemp('audit_s07_');
          addTearDown(() async {
            if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
          });

          var now = 1795400000000;
          final db = AppDatabase(NativeDatabase.memory(), nowMs: () => now);
          addTearDown(db.close);
          await db.select(db.accountBooks).get();

          final svc = TallyBackupService(
            db,
            reminderService: ReminderService(
              db,
              scheduler: InMemoryReminderScheduler(),
            ),
            localBackupsDirectoryProvider: () async =>
                Directory(p.join(tempRoot.path, 'bk')),
            attachmentsDirectoryProvider: () async =>
                Directory(p.join(tempRoot.path, 'att')),
          );
          await svc.saveS3Config(s3.buildConfig());
          await svc.setAutoArchiveBackupEnabled(false);
          await LedgerService(db).saveRecord(
            commandId: 's07-rec-1',
            draft: RecordDraft(
              bookId: 1,
              type: RecordType.expense,
              money: Money.parse('15.00'),
              recordTime: now,
              categoryId: 1,
              remark: 'FIFO 队列校验',
            ),
          );
          final restorePayload = (await svc.createBackupBytes()).bytes;

          final gate1Entered = Completer<void>();
          final releaseGate1 = Completer<void>();
          final completionOrder = <String>[];

          final f1 = svc
              .syncNow(
                beforePushCommitForTest: () async {
                  gate1Entered.complete();
                  await releaseGate1.future;
                },
              )
              .then((_) => completionOrder.add('syncNow'));
          await gate1Entered.future;

          final f2 = svc.createLocalBackup().then(
            (_) => completionOrder.add('createLocalBackup'),
          );
          final f3 = svc.uploadToActiveCloudBackup().then(
            (_) => completionOrder.add('uploadCloudBackup'),
          );
          final f4 = svc
              .restoreFromBytes(restorePayload)
              .then((_) => completionOrder.add('restoreFromBytes'));

          // While f1 holds the mutex, f2/f3/f4 must wait!
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(completionOrder, isEmpty);

          releaseGate1.complete();
          await Future.wait(<Future<Object?>>[f1, f2, f3, f4]);
          expect(completionOrder, <String>[
            'syncNow',
            'createLocalBackup',
            'uploadCloudBackup',
            'restoreFromBytes',
          ]);
        },
      );

      test(
        'S-08: rejects WebDAV MKCOL 301, sends S3 delimiter=/, supports IPv6 [::1] loopback S3, and avoids same-second cloud overwrites',
        () async {
          // 1. WebDAV MKCOL 301 must fail rather than succeed
          final mkcol301Http = await HttpServer.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          mkcol301Http.listen((req) async {
            await req.drain<void>();
            req.response.statusCode = req.method == 'PROPFIND'
                ? HttpStatus.notFound
                : HttpStatus.movedPermanently;
            await req.response.close();
          });
          addTearDown(() => mkcol301Http.close(force: true));

          final dav301 = WebDavClient(
            WebDavConfig(
              serverUrl: 'http://127.0.0.1:${mkcol301Http.port}/dav',
              username: 'u',
              password: 'p',
              remoteDirectory: '/TallyIsle',
            ),
          );
          await expectLater(
            dav301.ensureRemoteDirectory(),
            throwsA(isA<Failure>()),
          );

          // 2. S3 delimiter=/ + same-second cloud backup collision suffix (_2.tally)
          final s3 = await _AuditS3Server.start();
          addTearDown(s3.close);
          final tempRoot = await Directory.systemTemp.createTemp('audit_s08_');
          addTearDown(() async {
            if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
          });

          const fixedNowMs = 1795500000000;
          final db = AppDatabase(
            NativeDatabase.memory(),
            nowMs: () => fixedNowMs,
          );
          addTearDown(db.close);
          await db.select(db.accountBooks).get();
          final svc = TallyBackupService(
            db,
            reminderService: ReminderService(
              db,
              scheduler: InMemoryReminderScheduler(),
            ),
            localBackupsDirectoryProvider: () async =>
                Directory(p.join(tempRoot.path, 'bk')),
            attachmentsDirectoryProvider: () async =>
                Directory(p.join(tempRoot.path, 'att')),
          );
          await svc.saveS3Config(s3.buildConfig());

          final up1 = await svc.uploadToActiveCloudBackup();
          final up2 = await svc.uploadToActiveCloudBackup();
          expect(up1.fileName, isNot(up2.fileName));
          expect(up2.fileName, endsWith('_2.tally'));
          expect(
            s3.listQueries.every((u) => u.queryParameters['delimiter'] == '/'),
            isTrue,
          );

          // 3. Real IPv6 [::1] loopback S3 round-trip with SigV4 Host: [::1]:port
          _AuditS3Server? ipv6S3;
          try {
            ipv6S3 = await _AuditS3Server.start(ipv6: true);
          } on SocketException {
            ipv6S3 = null;
          }
          if (ipv6S3 != null) {
            addTearDown(ipv6S3.close);
            final ipv6Client = S3Client(ipv6S3.buildConfig());
            final hello = Uint8List.fromList(utf8.encode('ipv6-sigv4-ok'));
            await ipv6Client.putObject('ipv6.txt', hello);
            expect(await ipv6Client.getObjectOrNull('ipv6.txt'), hello);
          }
        },
      );

      test(
        'S-09: setIncludeAttachments updates both WebDAV & unconfigured S3, and Stage-2 restore rejects empty account_book or missing CNY',
        () async {
          final db = AppDatabase(NativeDatabase.memory());
          addTearDown(db.close);
          await db.select(db.accountBooks).get();
          await LedgerService(db).saveRecord(
            commandId: 's09-sentinel',
            draft: RecordDraft(
              bookId: 1,
              type: RecordType.expense,
              money: Money.parse('77.00'),
              recordTime: 1795600000000,
              categoryId: 1,
              remark: '绝不可被残缺归档清空',
            ),
          );

          final svc = TallyBackupService(
            db,
            reminderService: ReminderService(
              db,
              scheduler: InMemoryReminderScheduler(),
            ),
          );
          await svc.setIncludeAttachments(false);
          expect((await svc.getWebDavConfig()).includeAttachments, isFalse);
          expect((await svc.getS3Config()).includeAttachments, isFalse);

          final emptyBooksArchive = packTallyArchive(
            tables: <String, List<Map<String, Object?>>>{
              'account_book': const <Map<String, Object?>>[],
              'currency': <Map<String, Object?>>[
                <String, Object?>{
                  'code': 'CNY',
                  'name': '人民币',
                  'symbol': '¥',
                  'rate_to_anchor': '1',
                  'anchor_code': 'CNY',
                },
              ],
            },
            createdAtMs: 1795600000000,
          );
          await expectLater(
            svc.restoreFromBytes(emptyBooksArchive.bytes),
            throwsA(
              isA<Failure>().having(
                (f) => f.code,
                'code',
                FailureCode.corruptData,
              ),
            ),
          );

          final missingCnyArchive = packTallyArchive(
            tables: <String, List<Map<String, Object?>>>{
              'account_book': <Map<String, Object?>>[
                <String, Object?>{'id': 1, 'name': '日常账本', 'create_date': 1000},
              ],
              'currency': <Map<String, Object?>>[
                <String, Object?>{
                  'code': 'USD',
                  'name': '美元',
                  'symbol': r'$',
                  'rate_to_anchor': '7.2',
                  'anchor_code': 'CNY',
                },
              ],
            },
            createdAtMs: 1795600000000,
          );
          await expectLater(
            svc.restoreFromBytes(missingCnyArchive.bytes),
            throwsA(
              isA<Failure>().having(
                (f) => f.code,
                'code',
                FailureCode.corruptData,
              ),
            ),
          );

          // Existing sentinel record survived untouched!
          final records = await db.select(db.records).get();
          expect(records.single.remark, '绝不可被残缺归档清空');
        },
      );
    },
  );

  group(
    'S-05 & S-10: Lifecycle Ordering, Persistent Conflict Card, Lightweight ZIP Manifest Read & Post-Restore Refresh',
    () {
      test(
        'S-10: ZipArchive.readSingleEntryFromFile reads manifest.json via EOCD without reading or inflating attachment entries',
        () async {
          final tempDir = await Directory.systemTemp.createTemp(
            'audit_s10_zip_',
          );
          addTearDown(() async {
            if (await tempDir.exists()) await tempDir.delete(recursive: true);
          });

          final db = AppDatabase(NativeDatabase.memory());
          addTearDown(db.close);
          await db.select(db.accountBooks).get();

          final attDir = Directory(p.join(tempDir.path, 'att'))
            ..createSync(recursive: true);
          final bkDir = Directory(p.join(tempDir.path, 'bk'))
            ..createSync(recursive: true);
          // Compressible 64 KB payload so deflate stream is used for attachment entry
          final bigImg = Uint8List.fromList(
            List<int>.generate(65536, (i) => (i * 7) & 0xFF),
          );
          await File(
            p.join(attDir.path, 'receipt_big.jpg'),
          ).writeAsBytes(bigImg);

          final svc = TallyBackupService(
            db,
            reminderService: ReminderService(
              db,
              scheduler: InMemoryReminderScheduler(),
            ),
            localBackupsDirectoryProvider: () async => bkDir,
            attachmentsDirectoryProvider: () async => attDir,
          );
          final created = await svc.createLocalBackup();
          final bkFile = File(p.join(bkDir.path, created.fileName));

          // Locate 'attachments/receipt_big.jpg' local file header and corrupt its compressed payload bytes
          // while leaving EOCD + Central Directory + manifest.json untouched!
          final rawBytes = await bkFile.readAsBytes();
          final nameBytes = utf8.encode('attachments/receipt_big.jpg');
          var headerIdx = -1;
          for (var i = 0; i + nameBytes.length + 30 < rawBytes.length; i++) {
            if (rawBytes[i] == 0x50 &&
                rawBytes[i + 1] == 0x4B &&
                rawBytes[i + 2] == 0x03 &&
                rawBytes[i + 3] == 0x04) {
              var match = true;
              for (var j = 0; j < nameBytes.length; j++) {
                if (rawBytes[i + 30 + j] != nameBytes[j]) {
                  match = false;
                  break;
                }
              }
              if (match) {
                headerIdx = i;
                break;
              }
            }
          }
          expect(headerIdx, greaterThanOrEqualTo(0));
          final fnLen =
              rawBytes[headerIdx + 26] | (rawBytes[headerIdx + 27] << 8);
          final exLen =
              rawBytes[headerIdx + 28] | (rawBytes[headerIdx + 29] << 8);
          final dataStart = headerIdx + 30 + fnLen + exLen;
          for (var k = 0; k < 32; k++) {
            rawBytes[dataStart + k] ^= 0xFF;
          }
          await bkFile.writeAsBytes(rawBytes, flush: true);

          // Full decode fails on corrupted attachment deflate/CRC, whereas readSingleEntryFromFile & listLocalBackups succeed!
          expect(() => ZipArchive.decode(rawBytes), throwsA(isA<Failure>()));
          final manifestBytes = await ZipArchive.readSingleEntryFromFile(
            bkFile,
            'manifest.json',
          );
          expect(manifestBytes, isNotNull);

          final listed = await svc.listLocalBackups();
          expect(listed, hasLength(1));
          expect(listed.single.manifest?.attachmentCount, 1);
        },
      );

      test(
        'S-10: invalidateAllAfterDatabaseReplace clears imageCache and refreshes StreamProvider categories, budget hints, data health & DIY config',
        () async {
          final db = AppDatabase(NativeDatabase.memory());
          addTearDown(db.close);
          await db.select(db.accountBooks).get();

          final container = ProviderContainer(
            retry: (_, _) => null,
            overrides: [databaseProvider.overrideWith((ref) async => db)],
          );
          addTearDown(container.dispose);

          final catSub = container.listen(
            allBookCategoriesMapProvider,
            (_, _) {},
          );
          final diySub = container.listen(diyToolbarConfigProvider, (_, _) {});
          addTearDown(catSub.close);
          addTearDown(diySub.close);

          // Prime providers + PaintingBinding.imageCache
          final initialCatMap = await container.read(
            allBookCategoriesMapProvider.future,
          );
          expect(initialCatMap[1]!.name, '餐饮');
          final initialDiy = await container.read(
            diyToolbarConfigProvider.future,
          );
          expect(initialDiy.datePickerStyle, RecordDatePickerStyle.calendar);
          await container.read(dataHealthReportProvider.future);
          await container.read(
            recordBudgetHintProvider(
              const RecordBudgetHintQuery(
                bookId: 1,
                recordTime: 1795600000000,
                categoryId: 1,
              ),
            ).future,
          );

          final imageCache = PaintingBinding.instance.imageCache;
          imageCache.putIfAbsent(
            const ValueKey<String>('cached_receipt'),
            () => _DummyImageStreamCompleter(),
          );

          // Simulate out-of-band DB overwrite
          await (db.update(db.recordCategories)..where((t) => t.id.equals(1)))
              .write(const RecordCategoriesCompanion(name: Value('恢复后餐饮')));
          await db
              .into(db.preferences)
              .insertOnConflictUpdate(
                PreferencesCompanion.insert(
                  key: prefKeyRecordDiyToolbar,
                  value: initialDiy
                      .copyWithStyles(
                        datePickerStyle: RecordDatePickerStyle.wheel,
                      )
                      .encode(),
                ),
              );

          await invalidateAllAfterDatabaseReplaceForContainer(
            container,
            syncPlatformWidgets: false,
          );

          expect(imageCache.currentSize, 0);
          final refreshedCatMap = await container.read(
            allBookCategoriesMapProvider.future,
          );
          expect(refreshedCatMap[1]!.name, '恢复后餐饮');
          final refreshedDiy = await container.read(
            diyToolbarConfigProvider.future,
          );
          expect(refreshedDiy.datePickerStyle, RecordDatePickerStyle.wheel);
        },
      );

      testWidgets(
        'S-05: TallyIsleApp runs startup cloud sync BEFORE periodic catch-up, and BackupPage conflict card persists across navigation then clears on restore',
        timeout: const Timeout(Duration(seconds: 30)),
        (tester) async {
          final s3 = (await tester.runAsync(_AuditS3Server.start))!;
          final tempRoot = (await tester.runAsync(
            () => Directory.systemTemp.createTemp('audit_s05_'),
          ))!;
          var now = DateTime(2026, 11, 24, 10, 0).millisecondsSinceEpoch;

          late final AppDatabase peerDb;
          late final AppDatabase appDb;
          await tester.runAsync(() async {
            peerDb = AppDatabase(NativeDatabase.memory(), nowMs: () => now);
            appDb = AppDatabase(NativeDatabase.memory(), nowMs: () => now);
          });
          final reminderScheduler = InMemoryReminderScheduler();

          addTearDown(() async {
            await tester.pumpWidget(const SizedBox());
            await reminderScheduler.dispose();
            await tester.runAsync(s3.close);
            await tester.runAsync(peerDb.close);
            await tester.runAsync(appDb.close);
            await tester.runAsync(() async {
              if (await tempRoot.exists())
                await tempRoot.delete(recursive: true);
            });
          });

          // 1. Seed shared baseline r1 with a due periodic plan, then Peer pushes r2!
          // If TallyIsleApp ran periodic catch-up BEFORE startup cloud sync, appDb would
          // mutate locally and hit a spurious conflict instead of pulling r2 cleanly!
          await tester.runAsync(() async {
            await peerDb.select(peerDb.accountBooks).get();
            await appDb.select(appDb.accountBooks).get();

            final peerSvc = TallyBackupService(
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
            final appSvc = TallyBackupService(
              appDb,
              reminderService: ReminderService(
                appDb,
                scheduler: reminderScheduler,
              ),
              localBackupsDirectoryProvider: () async =>
                  Directory(p.join(tempRoot.path, 'app_bk')),
              attachmentsDirectoryProvider: () async =>
                  Directory(p.join(tempRoot.path, 'app_att')),
            );
            await peerSvc.saveS3Config(s3.buildConfig());
            await appSvc.saveS3Config(s3.buildConfig());
            await peerSvc.setAutoArchiveBackupEnabled(false);
            await appSvc.setAutoArchiveBackupEnabled(false);
            await appSvc.updateCloudSyncTriggers(syncOnStartup: true);

            await PeriodicService(peerDb).savePeriod(
              commandId: 'peer-period-due-1',
              draft: PeriodicDraft(
                recordType: RecordType.expense,
                money: Money.parse('30.00'),
                bookId: 1,
                periodType: PeriodType.daily,
                periodStartDate: now + const Duration(days: 1).inMilliseconds,
                categoryId: 1,
                remark: '月度订阅',
              ),
            );
            expect((await peerSvc.syncNow()).revision, 1);
            expect((await appSvc.syncNow()).status, CloudSyncStatus.pulled);

            // Peer adds a new bill and pushes r2 while appDb has the periodic plan!
            now += 10000;
            await LedgerService(peerDb).saveRecord(
              commandId: 'peer-r2-bill',
              draft: RecordDraft(
                bookId: 1,
                type: RecordType.expense,
                money: Money.parse('58.00'),
                recordTime: now,
                categoryId: 1,
                remark: '远端最新账单 r2',
              ),
            );
            expect((await peerSvc.syncNow()).revision, 2);

            // Advance 2 days so the daily periodic plan is overdue when appDb boots!
            now += const Duration(days: 2).inMilliseconds;
          });

          await tester.pumpWidget(
            ProviderScope(
              retry: (_, _) => null,
              overrides: [
                databaseProvider.overrideWith((ref) async => appDb),
                reminderSchedulerProvider.overrideWithValue(reminderScheduler),
                backupLocalDirectoryOverrideProvider.overrideWithValue(
                  () async => Directory(p.join(tempRoot.path, 'app_bk')),
                ),
                backupAttachmentsDirectoryOverrideProvider.overrideWithValue(
                  () async => Directory(p.join(tempRoot.path, 'app_att')),
                ),
              ],
              child: const TallyIsleApp(),
            ),
          );
          await _settleWidget(tester);

          // Verify startup sync pulled r2 cleanly AND THEN periodic catch-up executed!
          List<String> syncedRemarks = const <String>[];
          for (var i = 0; i < 40; i++) {
            syncedRemarks = (await tester.runAsync(
              () => appDb.select(appDb.records).get(),
            ))!.map((r) => r.remark).toList();
            if (syncedRemarks.contains('远端最新账单 r2') &&
                syncedRemarks.contains('月度订阅')) {
              break;
            }
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 30)),
            );
            await tester.pump(const Duration(milliseconds: 50));
          }
          expect(syncedRemarks, contains('远端最新账单 r2'));
          expect(syncedRemarks, contains('月度订阅'));

          // Unmount TallyIsleApp cleanly before out-of-band conflict setup & standalone BackupPage mount!
          await tester.pumpWidget(const SizedBox());
          await _settleWidget(tester);
          await tester.pump(const Duration(seconds: 1));

          // 2. Trigger conflict on appDb, then mount BackupPage, unmount, and remount:
          // conflict banner MUST persist across page navigation and clear on manual restore!
          late final String localBkName;
          await tester.runAsync(() async {
            now += 20000;
            final peerSvc = TallyBackupService(
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
            await LedgerService(peerDb).saveRecord(
              commandId: 'peer-r3-conflict',
              draft: RecordDraft(
                bookId: 1,
                type: RecordType.expense,
                money: Money.parse('99.00'),
                recordTime: now,
                categoryId: 1,
                remark: '远端冲突 r3',
              ),
            );
            expect((await peerSvc.syncNow()).revision, 3);

            now += 5000;
            final appSvc = TallyBackupService(
              appDb,
              reminderService: ReminderService(
                appDb,
                scheduler: reminderScheduler,
              ),
              localBackupsDirectoryProvider: () async =>
                  Directory(p.join(tempRoot.path, 'app_bk')),
              attachmentsDirectoryProvider: () async =>
                  Directory(p.join(tempRoot.path, 'app_att')),
            );
            final conflict = await appSvc.syncNow();
            expect(conflict.isConflict, isTrue);
            localBkName = (await appSvc.createLocalBackup()).fileName;
          });

          Widget buildBackupPageApp() => ProviderScope(
            retry: (_, _) => null,
            overrides: [
              databaseProvider.overrideWith((ref) async => appDb),
              reminderSchedulerProvider.overrideWithValue(reminderScheduler),
              backupFileAccessProvider.overrideWithValue(const FileAccess()),
              backupLocalDirectoryOverrideProvider.overrideWithValue(
                () async => Directory(p.join(tempRoot.path, 'app_bk')),
              ),
              backupAttachmentsDirectoryOverrideProvider.overrideWithValue(
                () async => Directory(p.join(tempRoot.path, 'app_att')),
              ),
            ],
            child: const MaterialApp(home: BackupPage()),
          );

          // Mount standalone BackupPage (fresh State, _pendingConflict == null!), then remount to prove persistence!
          await tester.pumpWidget(buildBackupPageApp());
          await _settleWidget(tester);
          expect(
            find.byKey(const Key('cloud_sync_conflict_banner')),
            findsOneWidget,
          );
          await tester.pumpWidget(const SizedBox());
          await _settleWidget(tester);
          await tester.pumpWidget(buildBackupPageApp());
          await _settleWidget(tester);

          expect(
            find.byKey(const Key('cloud_sync_conflict_banner')),
            findsOneWidget,
          );

          // Restore local backup -> clears lastConflictFileName and hides banner!
          final restoreBtn = find.byKey(Key('local_restore_$localBkName'));
          await tester.ensureVisible(restoreBtn);
          await _settleWidget(tester);
          await tester.tap(restoreBtn);
          await _settleWidget(tester);
          await tester.tap(find.text('确认恢复'));
          await _settleWidget(tester);

          expect(
            find.byKey(const Key('cloud_sync_conflict_banner')),
            findsNothing,
          );

          // 3. Trigger an in-memory `_pendingConflict` on the mounted BackupPage
          // (tap 立即多端同步 -> 稍后处理), then switch active S3 account accessKeyId
          // via S3ConfigPage (`targetFingerprint` changes): banner MUST disappear immediately!
          final syncNowBtn = find.byKey(const Key('cloud_sync_now_button'));
          await tester.ensureVisible(syncNowBtn);
          await _settleWidget(tester);
          await tester.tap(syncNowBtn);
          await _settleWidget(tester);
          expect(
            find.byKey(const Key('cloud_sync_conflict_dialog')),
            findsOneWidget,
          );
          await tester.tap(
            find.byKey(const Key('conflict_resolve_later_button')),
          );
          await _settleWidget(tester);
          expect(
            find.byKey(const Key('cloud_sync_conflict_banner')),
            findsOneWidget,
          );

          // Switch server & S3ConfigPage to a different S3 accessKeyId (new targetFingerprint):
          s3.expectedAccessKey = 'AKIA_AUDIT_SWITCHED';
          final openS3Btn = find.byKey(const Key('open_s3_config_button'));
          await tester.ensureVisible(openS3Btn);
          await _settleWidget(tester);
          await tester.tap(openS3Btn);
          await _settleWidget(tester);
          await tester.enterText(
            find.byKey(const Key('s3_access_key_input')),
            'AKIA_AUDIT_SWITCHED',
          );
          await tester.enterText(
            find.byKey(const Key('s3_secret_key_input')),
            s3.expectedSecretKey,
          );
          final saveS3Btn = find.byKey(const Key('s3_save_config_button'));
          await tester.ensureVisible(saveS3Btn);
          await _settleWidget(tester);
          await tester.tap(saveS3Btn);
          await _settleWidget(tester);

          expect(find.byKey(const Key('backup_page')), findsOneWidget);
          expect(
            find.byKey(const Key('cloud_sync_conflict_banner')),
            findsNothing,
          );

          // Also verify target-fingerprint scoping even if S3Config changes via stream without dialog pop:
          await tester.tap(syncNowBtn);
          await _settleWidget(tester);
          await tester.tap(
            find.byKey(const Key('conflict_resolve_later_button')),
          );
          await _settleWidget(tester);
          expect(
            find.byKey(const Key('cloud_sync_conflict_banner')),
            findsOneWidget,
          );
          await tester.runAsync(() async {
            final appSvc = TallyBackupService(
              appDb,
              reminderService: ReminderService(
                appDb,
                scheduler: reminderScheduler,
              ),
              localBackupsDirectoryProvider: () async =>
                  Directory(p.join(tempRoot.path, 'app_bk')),
              attachmentsDirectoryProvider: () async =>
                  Directory(p.join(tempRoot.path, 'app_att')),
            );
            await appSvc.saveS3Config(
              s3.buildConfig(accessKeyId: 'AKIA_AUDIT_THIRD'),
            );
          });
          await _settleWidget(tester);
          expect(
            find.byKey(const Key('cloud_sync_conflict_banner')),
            findsNothing,
          );

          await tester.pumpWidget(const SizedBox());
          await _settleWidget(tester);
        },
      );
    },
  );
}

final class _DummyImageStreamCompleter extends ImageStreamCompleter {}
