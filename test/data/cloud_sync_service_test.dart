import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/core/zip_archive.dart';
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

/// Real loopback HTTP server verifying AWS Signature Version 4 (`AWS4-HMAC-SHA256`)
/// on every request and implementing S3 `PUT`, `GET`, `DELETE`, and paginated `ListObjectsV2`.
final class _LoopbackSigV4S3Server {
  _LoopbackSigV4S3Server._(this._server);

  final HttpServer _server;
  final Map<String, Uint8List> objects = <String, Uint8List>{};
  final Map<String, DateTime> modifiedAt = <String, DateTime>{};
  final Map<String, int> putCountsByKey = <String, int>{};
  final Map<String, int> getCountsByKey = <String, int>{};
  final List<String> requestLog = <String>[];

  String expectedBucket = 'tally-bucket';
  String expectedRegion = 'auto';
  String expectedAccessKey = 'AKIA_TALLY_TEST';
  String expectedSecretKey = 'secret_s3_signing_key_999';
  int maxKeysPerPage = 2;
  int _tick = 0;

  String get endpoint => 'http://127.0.0.1:${_server.port}';

  static Future<_LoopbackSigV4S3Server> start() async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final s3 = _LoopbackSigV4S3Server._(http);
    http.listen(s3._handle);
    return s3;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    final bodyBuilder = BytesBuilder(copy: false);
    await for (final chunk in req) {
      bodyBuilder.add(chunk);
    }
    final bodyBytes = bodyBuilder.takeBytes();
    requestLog.add('${req.method} ${req.uri.path}');

    // Verify AWS Signature Version 4 strictly!
    if (!_verifySigV4(req, bodyBytes)) {
      req.response.statusCode = HttpStatus.forbidden;
      req.response.write('<Error><Code>SignatureDoesNotMatch</Code></Error>');
      await req.response.close();
      return;
    }

    final rawSegs = <String>[
      for (final s in req.uri.pathSegments)
        if (s.isNotEmpty) s,
    ];
    if (rawSegs.isEmpty || rawSegs.first != expectedBucket) {
      req.response.statusCode = HttpStatus.notFound;
      req.response.write('<Error><Code>NoSuchBucket</Code></Error>');
      await req.response.close();
      return;
    }

    final objectKey = rawSegs.skip(1).join('/');

    // Bucket-level ListObjectsV2 (`GET /<bucket>?list-type=2...`)
    if (req.method == 'GET' &&
        objectKey.isEmpty &&
        req.uri.queryParameters['list-type'] == '2') {
      final prefix = req.uri.queryParameters['prefix'] ?? '';
      final startIdx =
          int.tryParse(req.uri.queryParameters['continuation-token'] ?? '') ??
          0;
      final matchingKeys =
          objects.keys.where((k) => k.startsWith(prefix)).toList()..sort();
      final endIdx = (startIdx + maxKeysPerPage < matchingKeys.length)
          ? startIdx + maxKeysPerPage
          : matchingKeys.length;
      final isTruncated = endIdx < matchingKeys.length;

      String esc(String s) => s
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;')
          .replaceAll('"', '&quot;');

      final xml = StringBuffer()
        ..write('<?xml version="1.0" encoding="UTF-8"?>')
        ..write('<ListBucketResult>')
        ..write('<Name>${esc(expectedBucket)}</Name>')
        ..write('<Prefix>${esc(prefix)}</Prefix>')
        ..write('<IsTruncated>$isTruncated</IsTruncated>');
      if (isTruncated) {
        xml.write('<NextContinuationToken>$endIdx</NextContinuationToken>');
      }
      for (var i = startIdx; i < endIdx; i++) {
        final k = matchingKeys[i];
        final data = objects[k]!;
        final modIso = (modifiedAt[k] ?? DateTime.utc(2026, 11, 11, 10))
            .toIso8601String();
        xml.write(
          '<Contents>'
          '<Key>${esc(k)}</Key>'
          '<LastModified>$modIso</LastModified>'
          '<ETag>"${sha256Hex(data).substring(0, 16)}"</ETag>'
          '<Size>${data.length}</Size>'
          '</Contents>',
        );
      }
      xml.write('</ListBucketResult>');
      req.response.statusCode = HttpStatus.ok;
      req.response.headers.contentType = ContentType('application', 'xml');
      req.response.write(xml.toString());
      await req.response.close();
      return;
    }

    switch (req.method) {
      case 'PUT':
        objects[objectKey] = bodyBytes;
        modifiedAt[objectKey] = DateTime.utc(2026, 11, 11, 10, 0, ++_tick);
        putCountsByKey[objectKey] = (putCountsByKey[objectKey] ?? 0) + 1;
        req.response.statusCode = HttpStatus.ok;
        await req.response.close();
      case 'GET':
        final data = objects[objectKey];
        if (data == null) {
          req.response.statusCode = HttpStatus.notFound;
          req.response.write('<Error><Code>NoSuchKey</Code></Error>');
        } else {
          getCountsByKey[objectKey] = (getCountsByKey[objectKey] ?? 0) + 1;
          req.response.statusCode = HttpStatus.ok;
          req.response.contentLength = data.length;
          req.response.add(data);
        }
        await req.response.close();
      case 'DELETE':
        objects.remove(objectKey);
        modifiedAt.remove(objectKey);
        req.response.statusCode = HttpStatus.noContent;
        await req.response.close();
      default:
        req.response.statusCode = HttpStatus.methodNotAllowed;
        await req.response.close();
    }
  }

  bool _verifySigV4(HttpRequest req, Uint8List bodyBytes) {
    final auth = req.headers.value(HttpHeaders.authorizationHeader);
    final amzDate = req.headers.value('x-amz-date');
    final contentSha = req.headers.value('x-amz-content-sha256');
    if (auth == null || amzDate == null || contentSha == null) return false;
    if (contentSha != sha256Hex(bodyBytes)) return false;

    final parsedAmzUtc = DateTime.tryParse(
      '${amzDate.substring(0, 4)}-${amzDate.substring(4, 6)}-${amzDate.substring(6, 8)}'
      'T${amzDate.substring(9, 11)}:${amzDate.substring(11, 13)}:${amzDate.substring(13, 15)}Z',
    );
    if (parsedAmzUtc == null) return false;

    final signedMatch = RegExp(r'SignedHeaders=([^,]+)').firstMatch(auth);
    if (signedMatch == null) return false;
    final signedHeaderNames = signedMatch.group(1)!.split(';');
    final extraHeaders = <String, String>{};
    for (final h in signedHeaderNames) {
      if (h == 'host' || h == 'x-amz-date' || h == 'x-amz-content-sha256') {
        continue;
      }
      final val = req.headers.value(h);
      if (val == null) return false;
      extraHeaders[h] = val;
    }

    final rawSegs = <String>[
      for (final s in req.uri.pathSegments)
        if (s.isNotEmpty) s,
    ];
    if (rawSegs.isEmpty) return false;
    final bucket = rawSegs.first;
    final objectKey = rawSegs.skip(1).join('/');

    final target = resolveS3RequestTarget(
      endpoint: endpoint,
      bucket: bucket,
      objectKey: objectKey,
      forcePathStyle: true,
      queryParameters: req.uri.queryParameters,
    );
    final expected = signS3Request(
      method: req.method,
      target: target,
      accessKeyId: expectedAccessKey,
      secretAccessKey: expectedSecretKey,
      region: expectedRegion,
      payloadBytes: bodyBytes,
      timestampUtc: parsedAmzUtc,
      extraHeaders: extraHeaders,
    );
    return auth == expected.authorization;
  }
}

/// Real loopback WebDAV server supporting nested subcollections (`sync/`, `sync/attachments/`).
final class _LoopbackSyncWebDavServer {
  _LoopbackSyncWebDavServer._(this._server);

  final HttpServer _server;
  final Map<String, Uint8List> files = <String, Uint8List>{};
  final Map<String, DateTime> modifiedAt = <String, DateTime>{};
  final Set<String> collections = <String>{'/dav'};
  int _tick = 0;

  String get baseUrl => 'http://127.0.0.1:${_server.port}/dav';

  static Future<_LoopbackSyncWebDavServer> start() async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final dav = _LoopbackSyncWebDavServer._(http);
    http.listen(dav._handle);
    return dav;
  }

  Future<void> close() => _server.close(force: true);

  static String _norm(String raw) {
    final d = Uri.decodeFull(raw);
    return d.length > 1 && d.endsWith('/') ? d.substring(0, d.length - 1) : d;
  }

  Future<void> _handle(HttpRequest req) async {
    final path = _norm(req.uri.path);
    switch (req.method) {
      case 'MKCOL':
        await req.drain<void>();
        final parent = p.posix.dirname(path);
        if (!collections.contains(parent)) {
          req.response.statusCode = HttpStatus.conflict;
        } else if (collections.contains(path)) {
          req.response.statusCode = HttpStatus.methodNotAllowed;
        } else {
          collections.add(path);
          req.response.statusCode = HttpStatus.created;
        }
        await req.response.close();

      case 'PROPFIND':
        await req.drain<void>();
        if (!collections.contains(path) && !files.containsKey(path)) {
          req.response.statusCode = HttpStatus.notFound;
          await req.response.close();
          return;
        }
        final depth = req.headers.value('Depth') ?? '1';
        final xml = StringBuffer(
          '<?xml version="1.0" encoding="utf-8"?><D:multistatus xmlns:D="DAV:">',
        );
        if (collections.contains(path)) {
          xml.write(
            '<D:response><D:href>${Uri.encodeFull('$path/')}</D:href>'
            '<D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>'
            '<D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>',
          );
          if (depth != '0') {
            final prefix = '$path/';
            for (final subCol in collections) {
              if (!subCol.startsWith(prefix)) continue;
              final rest = subCol.substring(prefix.length);
              if (rest.isEmpty || rest.contains('/')) continue;
              xml.write(
                '<D:response><D:href>${Uri.encodeFull('$subCol/')}</D:href>'
                '<D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>'
                '<D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>',
              );
            }
            for (final e in files.entries) {
              if (!e.key.startsWith(prefix)) continue;
              final name = e.key.substring(prefix.length);
              if (name.contains('/')) continue;
              final mod = HttpDate.format(
                modifiedAt[e.key] ?? DateTime.utc(2026, 11, 11, 9),
              );
              xml.write(
                '<D:response><D:href>${Uri.encodeFull(e.key)}</D:href>'
                '<D:propstat><D:prop>'
                '<D:displayname>$name</D:displayname>'
                '<D:getcontentlength>${e.value.length}</D:getcontentlength>'
                '<D:getlastmodified>$mod</D:getlastmodified>'
                '<D:resourcetype/>'
                '</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>',
              );
            }
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
        final parent = p.posix.dirname(path);
        if (!collections.contains(parent)) {
          req.response.statusCode = HttpStatus.conflict;
        } else {
          files[path] = b.takeBytes();
          modifiedAt[path] = DateTime.utc(2026, 11, 11, 9, 0, ++_tick);
          req.response.statusCode = HttpStatus.created;
        }
        await req.response.close();

      case 'MOVE':
        await req.drain<void>();
        final dest = _norm(Uri.parse(req.headers.value('Destination')!).path);
        files[dest] = files.remove(path)!;
        modifiedAt[dest] =
            modifiedAt.remove(path) ??
            DateTime.utc(2026, 11, 11, 9, 0, ++_tick);
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
        modifiedAt.remove(path);
        req.response.statusCode = HttpStatus.noContent;
        await req.response.close();

      default:
        await req.drain<void>();
        req.response.statusCode = HttpStatus.methodNotAllowed;
        await req.response.close();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  setUp(() {
    HttpOverrides.global = null;
  });

  group('S3 SigV4 BackupTarget & Multi-Device Sync with Deduplicated Attachments', () {
    test(
      'verifies real SigV4 auth, probe, paginated ListObjectsV2, historical backups, and deduplicated A -> S3 -> B sync',
      () async {
        final s3Server = await _LoopbackSigV4S3Server.start();
        addTearDown(s3Server.close);

        final tempRoot = await Directory.systemTemp.createTemp('s3_sync_test_');
        addTearDown(() async {
          if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
        });

        var now = 1794400000000;
        final dbA = AppDatabase(NativeDatabase.memory(), nowMs: () => now);
        final dbB = AppDatabase(
          NativeDatabase.memory(),
          nowMs: () => now + 5000,
        );
        addTearDown(dbA.close);
        addTearDown(dbB.close);

        final attDirA = Directory(p.join(tempRoot.path, 'att_a'))
          ..createSync(recursive: true);
        final attDirB = Directory(p.join(tempRoot.path, 'att_b'))
          ..createSync(recursive: true);

        final serviceA = TallyBackupService(
          dbA,
          reminderService: ReminderService(
            dbA,
            scheduler: InMemoryReminderScheduler(),
          ),
          localBackupsDirectoryProvider: () async =>
              Directory(p.join(tempRoot.path, 'bk_a')),
          attachmentsDirectoryProvider: () async => attDirA,
        );
        final serviceB = TallyBackupService(
          dbB,
          reminderService: ReminderService(
            dbB,
            scheduler: InMemoryReminderScheduler(),
          ),
          localBackupsDirectoryProvider: () async =>
              Directory(p.join(tempRoot.path, 'bk_b')),
          attachmentsDirectoryProvider: () async => attDirB,
        );

        // 1. Wrong Secret Access Key rejected with authRequired and never leaked!
        final wrongCfg = S3Config(
          endpoint: s3Server.endpoint,
          region: 'auto',
          bucket: s3Server.expectedBucket,
          accessKeyId: s3Server.expectedAccessKey,
          secretAccessKey: 'super_sensitive_wrong_key',
          remotePrefix: 'TallyIsle',
          forcePathStyle: true,
        );
        await expectLater(
          serviceA.testS3Connection(wrongCfg),
          throwsA(
            isA<Failure>()
                .having((f) => f.code, 'code', FailureCode.authRequired)
                .having(
                  (f) => f.message.contains('super_sensitive_wrong_key'),
                  'leaksSecret',
                  isFalse,
                ),
          ),
        );

        // 2. Valid S3Config passes write/read/delete probe and cleans up probe object
        final validS3 = S3Config(
          endpoint: s3Server.endpoint,
          region: 'auto',
          bucket: s3Server.expectedBucket,
          accessKeyId: s3Server.expectedAccessKey,
          secretAccessKey: s3Server.expectedSecretKey,
          remotePrefix: 'TallyIsle',
          forcePathStyle: true,
          keepCount: 2,
        );
        await serviceA.testS3Connection(validS3);
        expect(s3Server.objects, isEmpty);

        await serviceA.saveS3Config(validS3);
        await serviceB.saveS3Config(validS3);
        // Disable auto-archive during dedicated sync deduplication assertions
        await serviceA.setAutoArchiveBackupEnabled(false);
        await serviceB.setAutoArchiveBackupEnabled(false);

        // 3. Seed Device A with real LedgerService asset + expense + note + EUR + img_a.jpg
        await dbA.select(dbA.accountBooks).get();
        final ledgerA = LedgerService(dbA);
        final cardId = await ledgerA.createAsset(
          commandId: 's3-asset-1',
          name: '工商储蓄卡',
          type: AssetType.normal,
          initial: Money.parse('2000.00'),
        );
        await ledgerA.saveRecord(
          commandId: 's3-rec-1',
          draft: RecordDraft(
            bookId: 1,
            type: RecordType.expense,
            money: Money.parse('128.50'),
            recordTime: now,
            categoryId: 1,
            assetId: cardId,
            remark: '团队咖啡',
          ),
        );
        await dbA
            .into(dbA.notes)
            .insert(
              NotesCompanion.insert(
                title: const Value('S3 同步便签'),
                content: '跨设备完整保留',
                createTime: now,
                updateTime: now,
              ),
            );
        await dbA
            .into(dbA.currencies)
            .insert(
              CurrenciesCompanion.insert(
                code: 'EUR',
                name: '欧元',
                symbol: '€',
                rateToAnchor: '7.8500',
                anchorCode: 'CNY',
              ),
            );

        final imgABytes = Uint8List.fromList(utf8.encode('jpeg-payload-alpha'));
        final imgASha = sha256Hex(imgABytes);
        final imgAObjKey = 'TallyIsle/sync/attachments/${imgASha}__img_a.jpg';
        await File(p.join(attDirA.path, 'img_a.jpg')).writeAsBytes(imgABytes);

        // 4. Device A pushes revision 1
        final push1 = await serviceA.syncNow();
        expect(push1.status, CloudSyncStatus.pushed);
        expect(push1.revision, 1);
        expect(push1.uploadedAttachments, 1);
        expect(s3Server.putCountsByKey[imgAObjKey], 1);

        // Verify sync/latest_db.tally is lightweight (does NOT inline attachment bytes)
        final latestZip = ZipArchive.decode(
          s3Server.objects['TallyIsle/sync/latest_db.tally']!,
        );
        expect(
          latestZip.entries.any((e) => e.name.startsWith('attachments/')),
          isFalse,
        );

        // 5. Device B (fresh seed DB) pulls revision 1
        await dbB.select(dbB.accountBooks).get();
        final pull1 = await serviceB.syncNow();
        expect(pull1.status, CloudSyncStatus.pulled);
        expect(pull1.revision, 1);
        expect(pull1.downloadedAttachments, 1);
        expect(s3Server.getCountsByKey[imgAObjKey], 1);

        final assetOnB = await (dbB.select(
          dbB.assets,
        )..where((t) => t.id.equals(cardId))).getSingle();
        // 2000.00 - 128.50 = 1871.50 -> 187150 minor units
        expect(assetOnB.balanceMinor, BigInt.from(187150));
        expect(await dbB.select(dbB.notes).get(), hasLength(1));
        expect(
          (await dbB.select(dbB.currencies).get()).map((c) => c.code),
          contains('EUR'),
        );
        expect(
          await File(p.join(attDirB.path, 'img_a.jpg')).readAsBytes(),
          imgABytes,
        );

        // Re-syncing Device B immediately is a no-op with zero downloads
        final noopOnB = await serviceB.syncNow();
        expect(noopOnB.status, CloudSyncStatus.alreadyUpToDate);
        expect(s3Server.getCountsByKey[imgAObjKey], 1);

        // 6. Deduplication proof: Device A adds a new bill + img_b.png while keeping img_a.jpg
        now += 60000;
        await ledgerA.saveRecord(
          commandId: 's3-rec-2',
          draft: RecordDraft(
            bookId: 1,
            type: RecordType.expense,
            money: Money.parse('21.50'),
            recordTime: now,
            categoryId: 1,
            assetId: cardId,
            remark: '地铁票',
          ),
        );
        final imgBBytes = Uint8List.fromList(utf8.encode('png-payload-bravo'));
        final imgBSha = sha256Hex(imgBBytes);
        final imgBObjKey = 'TallyIsle/sync/attachments/${imgBSha}__img_b.png';
        await File(p.join(attDirA.path, 'img_b.png')).writeAsBytes(imgBBytes);

        final push2 = await serviceA.syncNow();
        expect(push2.status, CloudSyncStatus.pushed);
        expect(push2.revision, 2);
        expect(push2.uploadedAttachments, 1);
        // img_a.jpg was NEVER re-uploaded!
        expect(s3Server.putCountsByKey[imgAObjKey], 1);
        expect(s3Server.putCountsByKey[imgBObjKey], 1);

        // Device B pulls revision 2: downloads ONLY img_b.png, reuses local img_a.jpg!
        final pull2 = await serviceB.syncNow();
        expect(pull2.status, CloudSyncStatus.pulled);
        expect(pull2.revision, 2);
        expect(pull2.downloadedAttachments, 1);
        expect(s3Server.getCountsByKey[imgAObjKey], 1);
        expect(s3Server.getCountsByKey[imgBObjKey], 1);
        expect(
          await File(p.join(attDirB.path, 'img_b.png')).readAsBytes(),
          imgBBytes,
        );

        // 7. Historical S3 backups & retention pruning (keepCount = 2) preserve conflict_*
        final s3Target = await serviceA.getS3Target();
        await s3Target.writeBackup(
          'conflict_a1b2c3d4_20261101_000000.tally',
          (await serviceA.createBackupBytes()).bytes,
        );
        for (final name in <String>[
          'backup_20261102_100000.tally',
          'backup_20261103_100000.tally',
          'backup_20261104_100000.tally',
        ]) {
          await serviceA.uploadBackupToS3(customFileName: name);
        }
        // Paginated ListObjectsV2 (maxKeysPerPage = 2) lists all surviving backups:
        final s3Backups = await serviceA.listActiveCloudBackups();
        expect(s3Backups.map((e) => e.fileName).toList(), <String>[
          'backup_20261104_100000.tally',
          'backup_20261103_100000.tally',
          'conflict_a1b2c3d4_20261101_000000.tally',
        ]);
      },
    );
  });

  group('WebDAV Multi-Device Sync, Zero-Data-Loss Conflict & Race Protection', () {
    test(
      'preserves conflict_*.tally locally & remotely on offline divergence and concurrent races, and resolves cleanly',
      () async {
        final davServer = await _LoopbackSyncWebDavServer.start();
        addTearDown(davServer.close);

        final tempRoot = await Directory.systemTemp.createTemp(
          'dav_sync_test_',
        );
        addTearDown(() async {
          if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
        });

        var now = 1794500000000;
        var httpConnections = 0;
        final dbA = AppDatabase(NativeDatabase.memory(), nowMs: () => now);
        final dbB = AppDatabase(NativeDatabase.memory(), nowMs: () => now);
        addTearDown(dbA.close);
        addTearDown(dbB.close);

        final attDirA = Directory(p.join(tempRoot.path, 'att_a'))
          ..createSync(recursive: true);
        final attDirB = Directory(p.join(tempRoot.path, 'att_b'))
          ..createSync(recursive: true);

        TallyBackupService makeService(
          AppDatabase db,
          String bkFolder,
          Directory attDir,
        ) => TallyBackupService(
          db,
          reminderService: ReminderService(
            db,
            scheduler: InMemoryReminderScheduler(),
          ),
          localBackupsDirectoryProvider: () async =>
              Directory(p.join(tempRoot.path, bkFolder)),
          attachmentsDirectoryProvider: () async => attDir,
          httpClientFactory: () {
            httpConnections++;
            return HttpClient();
          },
        );

        final serviceA = makeService(dbA, 'bk_a', attDirA);
        final serviceB = makeService(dbB, 'bk_b', attDirB);

        // Default-off check: unconfigured / autoSyncEnabled == false makes ZERO network calls!
        expect(await serviceA.runSilentCloudSyncIfNeeded(), isNull);
        expect(httpConnections, 0);

        final davCfg = WebDavConfig(
          serverUrl: davServer.baseUrl,
          username: 'alice',
          password: 'dav_password',
          remoteDirectory: '/TallySync',
        );
        await serviceA.saveWebDavConfig(davCfg);
        await serviceB.saveWebDavConfig(davCfg);
        await serviceA.setAutoArchiveBackupEnabled(false);
        await serviceB.setAutoArchiveBackupEnabled(false);

        // Backward compatibility: saving WebDavConfig automatically activated CloudBackendType.webdav,
        // while autoSyncEnabled stays false until turned on!
        expect(
          (await serviceA.getCloudSyncSettings()).backend,
          CloudBackendType.webdav,
        );
        httpConnections = 0;
        expect(await serviceA.runSilentCloudSyncIfNeeded(), isNull);
        expect(httpConnections, 0);

        // 1. Sync initial baseline r1 between A and B
        await dbA.select(dbA.accountBooks).get();
        await dbB.select(dbB.accountBooks).get();
        final ledgerA = LedgerService(dbA);
        final ledgerB = LedgerService(dbB);

        final cashId = await ledgerA.createAsset(
          commandId: 'dav-cash',
          name: '现金钱包',
          type: AssetType.normal,
          initial: Money.parse('500.00'),
        );
        expect((await serviceA.syncNow()).revision, 1);
        expect((await serviceB.syncNow()).status, CloudSyncStatus.pulled);

        // 2. Both devices edit offline -> conflict!
        now += 10000;
        await ledgerA.saveRecord(
          commandId: 'dav-a-edit',
          draft: RecordDraft(
            bookId: 1,
            type: RecordType.expense,
            money: Money.parse('30.00'),
            recordTime: now,
            categoryId: 1,
            assetId: cashId,
            remark: 'A端早餐',
          ),
        );
        expect((await serviceA.syncNow()).revision, 2);

        now += 10000;
        await ledgerB.saveRecord(
          commandId: 'dav-b-edit',
          draft: RecordDraft(
            bookId: 1,
            type: RecordType.expense,
            money: Money.parse('88.00'),
            recordTime: now,
            categoryId: 1,
            assetId: cashId,
            remark: 'B端离线晚餐',
          ),
        );
        final bOnlyImg = Uint8List.fromList(utf8.encode('b-offline-invoice'));
        await File(
          p.join(attDirB.path, 'b_invoice.jpg'),
        ).writeAsBytes(bOnlyImg);

        final conflictOutcome = await serviceB.syncNow();
        expect(conflictOutcome.isConflict, isTrue);
        expect(conflictOutcome.revision, 2);
        final conflictFile = conflictOutcome.conflictBackupFileName!;
        expect(
          conflictFile,
          matches(RegExp(r'^conflict_[a-z0-9]{1,8}_\d{8}_\d{6}\.tally$')),
        );

        // Neither Device B's local DB nor remote r2 was overwritten!
        final bRecordsStillLocal = await dbB.select(dbB.records).get();
        expect(bRecordsStillLocal.single.remark, 'B端离线晚餐');

        // Conflict backup exists in BOTH Device B local backups AND remote WebDAV backups!
        final localBks = await serviceB.listLocalBackups();
        final remoteBks = await serviceB.listActiveCloudBackups();
        expect(localBks.map((e) => e.fileName), contains(conflictFile));
        expect(remoteBks.map((e) => e.fileName), contains(conflictFile));

        // 3. Resolve conflict with `useRemote` -> B adopts A's r2 cleanly
        final resolvedRemote = await serviceB.syncNow(
          resolution: SyncConflictResolution.useRemote,
        );
        expect(resolvedRemote.status, CloudSyncStatus.pulled);
        expect(resolvedRemote.revision, 2);
        expect((await dbB.select(dbB.records).get()).single.remark, 'A端早餐');

        // Restoring the archived conflict_*.tally recovers B's offline bill + image 100%!
        await serviceB.restoreLocalBackup(conflictFile);
        expect((await dbB.select(dbB.records).get()).single.remark, 'B端离线晚餐');
        expect(
          await File(p.join(attDirB.path, 'b_invoice.jpg')).readAsBytes(),
          bOnlyImg,
        );

        // And resolving with `useLocal` pushes B's state as r3!
        final resolvedLocal = await serviceB.syncNow(
          resolution: SyncConflictResolution.useLocal,
        );
        expect(resolvedLocal.status, CloudSyncStatus.pushed);
        expect(resolvedLocal.revision, 3);

        // Device A pulls r3 via silent cloud sync when autoSyncEnabled is turned on!
        await serviceA.setAutoSyncEnabled(true);
        final silentPullA = await serviceA.runSilentCloudSyncIfNeeded();
        expect(silentPullA?.status, CloudSyncStatus.pulled);
        expect(silentPullA?.revision, 3);
        expect((await dbA.select(dbA.records).get()).single.remark, 'B端离线晚餐');

        // 4. Race guard right before commit: A starts pushing r4, but B commits r4 mid-flight!
        now += 20000;
        await ledgerA.saveRecord(
          commandId: 'dav-a-race',
          draft: RecordDraft(
            bookId: 1,
            type: RecordType.expense,
            money: Money.parse('15.00'),
            recordTime: now,
            categoryId: 1,
            assetId: cashId,
            remark: 'A端并发修改',
          ),
        );
        final racedOutcome = await serviceA.syncNow(
          beforePushCommitForTest: () async {
            await ledgerB.saveRecord(
              commandId: 'dav-b-race-winner',
              draft: RecordDraft(
                bookId: 1,
                type: RecordType.expense,
                money: Money.parse('45.00'),
                recordTime: now + 1000,
                categoryId: 1,
                assetId: cashId,
                remark: 'B端抢先提交',
              ),
            );
            await serviceB.syncNow();
          },
        );
        expect(racedOutcome.isConflict, isTrue);
        expect(racedOutcome.revision, 4);
        expect(racedOutcome.conflictBackupFileName, startsWith('conflict_'));
      },
    );
  });
}
