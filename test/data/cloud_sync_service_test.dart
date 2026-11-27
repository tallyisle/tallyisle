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
import 'package:tallyisle/domain/rules/receipt_diy_rules.dart';
import 'package:tallyisle/domain/rules/s3_sigv4_rules.dart';
import 'package:tallyisle/domain/rules/tally_backup.dart';
import 'package:tallyisle/platform/files.dart';
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
  (int statusCode, String? retryAfter)? Function(HttpRequest req)? forceStatus;
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

    final forced = forceStatus?.call(req);
    if (forced != null) {
      req.response.statusCode = forced.$1;
      if (forced.$2 != null) {
        req.response.headers.set(HttpHeaders.retryAfterHeader, forced.$2!);
      }
      req.response.write('<Error><Code>SlowDown</Code></Error>');
      await req.response.close();
      return;
    }

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
      final delimiter = req.uri.queryParameters['delimiter'];
      final startIdx =
          int.tryParse(req.uri.queryParameters['continuation-token'] ?? '') ??
          0;
      final matchingKeys = objects.keys.where((k) {
        if (!k.startsWith(prefix)) return false;
        if (delimiter != null &&
            delimiter.isNotEmpty &&
            k.substring(prefix.length).contains(delimiter)) {
          return false;
        }
        return true;
      }).toList()..sort();
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
        req.response.headers.set(
          HttpHeaders.etagHeader,
          '"${sha256Hex(bodyBytes).substring(0, 16)}"',
        );
        req.response.statusCode = HttpStatus.ok;
        await req.response.close();
      case 'HEAD':
        final data = objects[objectKey];
        if (data == null) {
          req.response.statusCode = HttpStatus.notFound;
        } else {
          req.response.headers.set(
            HttpHeaders.etagHeader,
            '"${sha256Hex(data).substring(0, 16)}"',
          );
          req.response.contentLength = data.length;
          req.response.statusCode = HttpStatus.ok;
        }
        await req.response.close();
      case 'GET':
        final data = objects[objectKey];
        if (data == null) {
          req.response.statusCode = HttpStatus.notFound;
          req.response.write('<Error><Code>NoSuchKey</Code></Error>');
        } else {
          final etag = '"${sha256Hex(data).substring(0, 16)}"';
          final ifNoneMatch = req.headers.value(HttpHeaders.ifNoneMatchHeader);
          if (ifNoneMatch != null && ifNoneMatch.trim() == etag) {
            req.response.headers.set(HttpHeaders.etagHeader, etag);
            req.response.statusCode = HttpStatus.notModified;
          } else {
            getCountsByKey[objectKey] = (getCountsByKey[objectKey] ?? 0) + 1;
            req.response.headers.set(HttpHeaders.etagHeader, etag);
            req.response.statusCode = HttpStatus.ok;
            req.response.contentLength = data.length;
            req.response.add(data);
          }
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
  final List<String> deletedPaths = <String>[];
  bool rejectMoveOverwriteWith409 = false;
  bool rejectAllMoveWith409 = false;
  bool failPutOnNonTmp = false;
  bool rejectExistingMkcolWith409 = false;
  bool failPutAfterSavingHeadJson = false;
  bool failPutBeforeSavingHeadJson = false;
  bool failGetOnHeadJson = false;
  int headCount = 0;
  int getCount = 0;
  String? lastHeadCacheControl;
  String? lastGetCacheControl;
  int? Function(String path, HttpRequest req)? overrideHeadLength;
  Uint8List? Function(String path, HttpRequest req)? overrideGetBytes;
  (int statusCode, String? retryAfter)? Function(HttpRequest req)? forceStatus;
  Future<void> Function(String path)? onBeforeGet;
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
    final forced = forceStatus?.call(req);
    if (forced != null) {
      await req.drain<void>();
      req.response.statusCode = forced.$1;
      if (forced.$2 != null) {
        req.response.headers.set(HttpHeaders.retryAfterHeader, forced.$2!);
      }
      await req.response.close();
      return;
    }
    switch (req.method) {
      case 'MKCOL':
        await req.drain<void>();
        final parent = p.posix.dirname(path);
        if (!collections.contains(parent)) {
          req.response.statusCode = HttpStatus.conflict;
        } else if (collections.contains(path)) {
          req.response.statusCode = rejectExistingMkcolWith409
              ? HttpStatus.conflict
              : HttpStatus.methodNotAllowed;
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
        final isHeadJsonNonTmp = path.endsWith('/sync/head.json');
        if (isHeadJsonNonTmp && failPutBeforeSavingHeadJson) {
          req.response.statusCode = HttpStatus.badGateway;
        } else if (failPutOnNonTmp && !path.toLowerCase().endsWith('.tmp')) {
          req.response.statusCode = HttpStatus.badGateway;
        } else if (!collections.contains(parent)) {
          req.response.statusCode = HttpStatus.conflict;
        } else {
          files[path] = b.takeBytes();
          modifiedAt[path] = DateTime.utc(2026, 11, 11, 9, 0, ++_tick);
          if (isHeadJsonNonTmp && failPutAfterSavingHeadJson) {
            req.response.statusCode = HttpStatus.badGateway;
          } else {
            req.response.statusCode = HttpStatus.created;
          }
        }
        await req.response.close();

      case 'MOVE':
        await req.drain<void>();
        final dest = _norm(Uri.parse(req.headers.value('Destination')!).path);
        if (rejectAllMoveWith409 ||
            (rejectMoveOverwriteWith409 && files.containsKey(dest))) {
          req.response.statusCode = HttpStatus.conflict;
          await req.response.close();
          return;
        }
        files[dest] = files.remove(path)!;
        modifiedAt[dest] =
            modifiedAt.remove(path) ??
            DateTime.utc(2026, 11, 11, 9, 0, ++_tick);
        req.response.statusCode = HttpStatus.created;
        await req.response.close();

      case 'HEAD':
        await req.drain<void>();
        headCount++;
        lastHeadCacheControl = req.headers.value(
          HttpHeaders.cacheControlHeader,
        );
        final headData = files[path];
        if (headData == null) {
          req.response.statusCode = HttpStatus.notFound;
        } else {
          final forcedLen = overrideHeadLength?.call(path, req);
          req.response.statusCode = HttpStatus.ok;
          req.response.headers.set(
            HttpHeaders.contentLengthHeader,
            '${forcedLen ?? headData.length}',
          );
        }
        await req.response.close();

      case 'GET':
        await req.drain<void>();
        getCount++;
        lastGetCacheControl = req.headers.value(HttpHeaders.cacheControlHeader);
        if (onBeforeGet != null) {
          await onBeforeGet!(path);
        }
        if (failGetOnHeadJson && path.endsWith('/sync/head.json')) {
          req.response.statusCode = HttpStatus.serviceUnavailable;
          await req.response.close();
          return;
        }
        final data = overrideGetBytes != null
            ? overrideGetBytes!(path, req)
            : files[path];
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
        deletedPaths.add(path);
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

        // Verify immutable format-2 revision snapshot is lightweight (no inline attachments) and latest_db.tally is never written
        expect(push1.remoteHead!.format, currentCloudSyncHeadFormat);
        expect(
          push1.remoteHead!.databasePath,
          startsWith('sync/revisions/db_r1_'),
        );
        expect(s3Server.objects['TallyIsle/sync/latest_db.tally'], isNull);
        final latestZip = ZipArchive.decode(
          s3Server.objects['TallyIsle/${push1.remoteHead!.databasePath}']!,
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

        // 2. Both devices make conflicting edits offline (A & B rename cashId differently + add bills) -> conflict!
        now += 10000;
        await (dbA.update(dbA.assets)..where((t) => t.id.equals(cashId))).write(
          const AssetsCompanion(name: Value('A端现金钱包')),
        );
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
        await (dbB.update(dbB.assets)..where((t) => t.id.equals(cashId))).write(
          const AssetsCompanion(name: Value('B端现金钱包')),
        );
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

        // 4. Race guard right before commit: A starts pushing r4, but B commits conflicting r4 mid-flight!
        now += 20000;
        await (dbA.update(dbA.assets)..where((t) => t.id.equals(cashId))).write(
          const AssetsCompanion(remark: Value('A并发备注')),
        );
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
            await (dbB.update(dbB.assets)..where((t) => t.id.equals(cashId)))
                .write(const AssetsCompanion(remark: Value('B并发备注')));
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

    test(
      'B-01/B-04/B-05: WebDAV never pre-DELETEs live targets on MOVE 409, surfaces conflict on missing head.json with existing latest_db.tally, always re-reads head.json on push (even uploadedCount == 0), and enforces per-chunk stream idle timeouts',
      () async {
        final davServer = await _LoopbackSyncWebDavServer.start()
          ..rejectMoveOverwriteWith409 = true
          ..rejectExistingMkcolWith409 = true;
        addTearDown(davServer.close);

        // Simulate missing `sync/head.json` while `sync/latest_db.tally` ALREADY exists!
        final stalePayload = Uint8List.fromList(
          utf8.encode('stale-interrupted-latest-db'),
        );
        davServer.collections.addAll(<String>[
          '/dav/TallySync',
          '/dav/TallySync/sync',
        ]);
        davServer.files['/dav/TallySync/sync/latest_db.tally'] = stalePayload;

        final tempRoot = await Directory.systemTemp.createTemp(
          'dav_409_recovery_',
        );
        addTearDown(() async {
          if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
        });

        var now = 1794600000000;
        final dbA = AppDatabase(NativeDatabase.memory(), nowMs: () => now);
        final dbB = AppDatabase(NativeDatabase.memory(), nowMs: () => now);
        final dbEmpty = AppDatabase(NativeDatabase.memory(), nowMs: () => now);
        addTearDown(dbA.close);
        addTearDown(dbB.close);
        addTearDown(dbEmpty.close);

        final serviceA = TallyBackupService(
          dbA,
          reminderService: ReminderService(
            dbA,
            scheduler: InMemoryReminderScheduler(),
          ),
          localBackupsDirectoryProvider: () async =>
              Directory(p.join(tempRoot.path, 'bk_a')),
          attachmentsDirectoryProvider: () async =>
              Directory(p.join(tempRoot.path, 'att_a')),
        );
        final serviceB = TallyBackupService(
          dbB,
          reminderService: ReminderService(
            dbB,
            scheduler: InMemoryReminderScheduler(),
          ),
          localBackupsDirectoryProvider: () async =>
              Directory(p.join(tempRoot.path, 'bk_b')),
          attachmentsDirectoryProvider: () async =>
              Directory(p.join(tempRoot.path, 'att_b')),
        );
        final serviceEmpty = TallyBackupService(
          dbEmpty,
          reminderService: ReminderService(
            dbEmpty,
            scheduler: InMemoryReminderScheduler(),
          ),
          localBackupsDirectoryProvider: () async =>
              Directory(p.join(tempRoot.path, 'bk_empty')),
          attachmentsDirectoryProvider: () async =>
              Directory(p.join(tempRoot.path, 'att_empty')),
        );

        final davCfg = WebDavConfig(
          serverUrl: davServer.baseUrl,
          username: 'alice',
          password: 'dav_password',
          remoteDirectory: '/TallySync',
        );
        await serviceA.saveWebDavConfig(davCfg);
        await serviceB.saveWebDavConfig(davCfg);
        await serviceEmpty.saveWebDavConfig(davCfg);
        await serviceA.setAutoArchiveBackupEnabled(false);
        await serviceB.setAutoArchiveBackupEnabled(false);
        await serviceEmpty.setAutoArchiveBackupEnabled(false);

        await dbA.select(dbA.accountBooks).get();
        await dbB.select(dbB.accountBooks).get();
        await dbEmpty.select(dbEmpty.accountBooks).get();
        final ledgerA = LedgerService(dbA);
        final walletId = await ledgerA.createAsset(
          commandId: 'dav-409-wallet',
          name: '零钱账户',
          type: AssetType.normal,
          initial: Money.parse('300.00'),
        );

        // 1. B-01 defense-in-depth: Fresh empty Device (`isLocalFreshEmpty == true`)
        // MUST NOT overwrite orphan `sync/latest_db.tally` when `head.json` is missing!
        final emptyConflict = await serviceEmpty.syncNow();
        expect(emptyConflict.status, CloudSyncStatus.conflict);
        expect(emptyConflict.conflictBackupFileName, startsWith('conflict_'));
        expect(
          davServer.files['/dav/TallySync/sync/latest_db.tally'],
          equals(stalePayload),
        );

        // Populated Device A ALSO surfaces conflict until explicit resolution:
        final progressStates = <bool>[];
        final sub = serviceA.watchSyncInProgress().listen(progressStates.add);
        addTearDown(sub.cancel);

        final conflictA = await serviceA.syncNow();
        expect(conflictA.status, CloudSyncStatus.conflict);
        expect(
          davServer.files['/dav/TallySync/sync/latest_db.tally'],
          equals(stalePayload),
        );

        // Explicit `useLocal` archives orphan `latest_db.tally` and pushes r1 cleanly!
        final push1 = await serviceA.syncNow(
          resolution: SyncConflictResolution.useLocal,
        );
        expect(push1.status, CloudSyncStatus.pushed);
        expect(push1.revision, 1);
        expect(
          davServer.files.keys,
          containsAll(<String>[
            '/dav/TallySync/${push1.remoteHead!.databasePath}',
            '/dav/TallySync/sync/head.json',
          ]),
        );

        // 2. Subsequent sync r2 on 409-on-MOVE-overwrite server succeeds via
        // in-place PUT + HEAD fallback WITHOUT EVER sending DELETE on live files!
        davServer.deletedPaths.clear();
        now += 5000;
        final attADir = Directory(p.join(tempRoot.path, 'att_a'));
        await attADir.create(recursive: true);
        final receiptABytes = Uint8List.fromList(<int>[
          0x89,
          0x50,
          0x4E,
          0x47,
          0x0D,
          0x0A,
          0x1A,
          0x0A,
          1,
          2,
          3,
          4,
        ]);
        await File(
          p.join(attADir.path, 'receipt_a.png'),
        ).writeAsBytes(receiptABytes, flush: true);

        final rec2Id = await ledgerA.saveRecord(
          commandId: 'dav-409-rec2',
          draft: RecordDraft(
            bookId: 1,
            type: RecordType.expense,
            money: Money.parse('25.00'),
            recordTime: now,
            categoryId: 1,
            assetId: walletId,
            remark: '二次覆盖同步成功',
          ),
        );
        await (dbA.update(dbA.records)..where((t) => t.recordId.equals(rec2Id)))
            .write(const RecordsCompanion(images: Value('receipt_a.png')));
        final push2 = await serviceA.syncNow();
        expect(push2.status, CloudSyncStatus.pushed);
        expect(push2.revision, 2);
        expect(push2.uploadedAttachments, 1);
        expect(progressStates, contains(true));
        expect(serviceA.isSyncInProgress, isFalse);
        // Every DELETE on the WebDAV server was strictly for `.tmp` cleanup, NEVER live targets!
        expect(davServer.deletedPaths, isNotEmpty);
        for (final delPath in davServer.deletedPaths) {
          expect(
            delPath.endsWith('.tmp'),
            isTrue,
            reason: 'Pre-DELETE hit live WebDAV path: $delPath',
          );
        }

        // Simulate network/gateway failure during fallback PUT: live `head.json` &
        // `latest_db.tally` MUST survive untouched!
        final savedHeadBytes = Uint8List.fromList(
          davServer.files['/dav/TallySync/sync/head.json']!,
        );
        davServer.failPutOnNonTmp = true;
        now += 5000;
        await ledgerA.saveRecord(
          commandId: 'dav-409-fail-put',
          draft: RecordDraft(
            bookId: 1,
            type: RecordType.expense,
            money: Money.parse('10.00'),
            recordTime: now,
            categoryId: 1,
            assetId: walletId,
            remark: '断网未覆盖',
          ),
        );
        await expectLater(serviceA.syncNow(), throwsA(isA<Failure>()));
        expect(
          davServer.files['/dav/TallySync/sync/head.json'],
          equals(savedHeadBytes),
        );
        davServer.failPutOnNonTmp = false;

        // Device B pulls r2 with exact 275.00 balance & clears stale defaultAccountId!
        await dbB
            .into(dbB.preferences)
            .insertOnConflictUpdate(
              PreferencesCompanion.insert(
                key: prefKeyRecordDiyToolbar,
                value: DiyToolbarConfig.defaults()
                    .copyWithDefaultAccount(
                      autoSelectDefaultAccount: true,
                      defaultAccountId: 999,
                    )
                    .encode(),
              ),
            );
        final pullB = await serviceB.syncNow();
        expect(pullB.status, CloudSyncStatus.pulled);
        expect(pullB.revision, 2);
        expect(pullB.downloadedAttachments, 1);
        final assetOnB = await (dbB.select(
          dbB.assets,
        )..where((t) => t.id.equals(walletId))).getSingle();
        expect(assetOnB.balanceMinor, BigInt.from(27500));
        final diyOnB = DiyToolbarConfig.decode(
          (await (dbB.select(dbB.preferences)
                    ..where((t) => t.key.equals(prefKeyRecordDiyToolbar)))
                  .getSingle())
              .value,
        );
        expect(diyOnB.defaultAccountId, noRef);
        expect(diyOnB.autoSelectDefaultAccount, isFalse);

        // If `head.json` is accidentally lost on server while valid `latest_db.tally`
        // + remote `sync/attachments/` remain, `useRemote` recovers `latest_db.tally`
        // + remote attachments, purges un-uploaded local-only attachments on the
        // pulling device, sanitizes stale `defaultAccountId`, and heals `head.json`
        // so Device C pulls cleanly with zero 404s!
        final attEmptyDir = Directory(p.join(tempRoot.path, 'att_empty'));
        await attEmptyDir.create(recursive: true);
        await File(
          p.join(attEmptyDir.path, 'unrelated_local_only.png'),
        ).writeAsBytes(Uint8List.fromList(<int>[9, 9, 9, 9]), flush: true);
        await dbEmpty
            .into(dbEmpty.preferences)
            .insertOnConflictUpdate(
              PreferencesCompanion.insert(
                key: prefKeyRecordDiyToolbar,
                value: DiyToolbarConfig.defaults()
                    .copyWithDefaultAccount(
                      autoSelectDefaultAccount: true,
                      defaultAccountId: 888,
                    )
                    .encode(),
              ),
            );

        davServer.files.remove('/dav/TallySync/sync/head.json');
        final emptyConflict2 = await serviceEmpty.syncNow();
        expect(emptyConflict2.status, CloudSyncStatus.conflict);
        final healedPull = await serviceEmpty.syncNow(
          resolution: SyncConflictResolution.useRemote,
        );
        expect(healedPull.status, CloudSyncStatus.pulled);
        expect(healedPull.revision, 2);
        expect(healedPull.downloadedAttachments, 1);
        expect(
          davServer.files.containsKey('/dav/TallySync/sync/head.json'),
          isTrue,
        );
        expect(
          await File(p.join(attEmptyDir.path, 'receipt_a.png')).exists(),
          isTrue,
        );
        expect(
          await File(
            p.join(attEmptyDir.path, 'unrelated_local_only.png'),
          ).exists(),
          isFalse,
        );
        final healedAsset = await (dbEmpty.select(
          dbEmpty.assets,
        )..where((t) => t.id.equals(walletId))).getSingle();
        expect(healedAsset.balanceMinor, BigInt.from(27500));
        final healedDiy = DiyToolbarConfig.decode(
          (await (dbEmpty.select(dbEmpty.preferences)
                    ..where((t) => t.key.equals(prefKeyRecordDiyToolbar)))
                  .getSingle())
              .value,
        );
        expect(healedDiy.defaultAccountId, noRef);
        expect(healedDiy.autoSelectDefaultAccount, isFalse);

        // Device C pulls the healed snapshot + remote attachment without 404!
        final dbC = AppDatabase(NativeDatabase.memory(), nowMs: () => now);
        addTearDown(dbC.close);
        await dbC.select(dbC.accountBooks).get();
        final attCDir = Directory(p.join(tempRoot.path, 'att_c'));
        final serviceC = TallyBackupService(
          dbC,
          reminderService: ReminderService(
            dbC,
            scheduler: InMemoryReminderScheduler(),
          ),
          localBackupsDirectoryProvider: () async =>
              Directory(p.join(tempRoot.path, 'bk_c')),
          attachmentsDirectoryProvider: () async => attCDir,
        );
        await serviceC.saveWebDavConfig(davCfg);
        await serviceC.setAutoArchiveBackupEnabled(false);
        final pullC = await serviceC.syncNow();
        expect(pullC.status, CloudSyncStatus.pulled);
        expect(pullC.revision, 2);
        expect(pullC.downloadedAttachments, 1);
        expect(
          await File(p.join(attCDir.path, 'receipt_a.png')).readAsBytes(),
          equals(receiptABytes),
        );

        // Also verify `restoreFromBytes` clears stale `defaultAccountId` while
        // preserving valid active non-debt `defaultAccountId`:
        final fullBackupFromC = await serviceC.createBackupBytes();
        await dbC
            .into(dbC.preferences)
            .insertOnConflictUpdate(
              PreferencesCompanion.insert(
                key: prefKeyRecordDiyToolbar,
                value: DiyToolbarConfig.defaults()
                    .copyWithDefaultAccount(
                      autoSelectDefaultAccount: true,
                      defaultAccountId: 777,
                    )
                    .encode(),
              ),
            );
        await serviceC.restoreFromBytes(fullBackupFromC.bytes);
        final restoredStaleDiy = DiyToolbarConfig.decode(
          (await (dbC.select(dbC.preferences)
                    ..where((t) => t.key.equals(prefKeyRecordDiyToolbar)))
                  .getSingle())
              .value,
        );
        expect(restoredStaleDiy.defaultAccountId, noRef);
        expect(restoredStaleDiy.autoSelectDefaultAccount, isFalse);

        await dbC
            .into(dbC.preferences)
            .insertOnConflictUpdate(
              PreferencesCompanion.insert(
                key: prefKeyRecordDiyToolbar,
                value: DiyToolbarConfig.defaults()
                    .copyWithDefaultAccount(
                      autoSelectDefaultAccount: true,
                      defaultAccountId: walletId,
                    )
                    .encode(),
              ),
            );
        await serviceC.restoreFromBytes(fullBackupFromC.bytes);
        final restoredValidDiy = DiyToolbarConfig.decode(
          (await (dbC.select(dbC.preferences)
                    ..where((t) => t.key.equals(prefKeyRecordDiyToolbar)))
                  .getSingle())
              .value,
        );
        expect(restoredValidDiy.defaultAccountId, walletId);
        expect(restoredValidDiy.autoSelectDefaultAccount, isTrue);

        // 3. B-04: Concurrent push race WITHOUT `beforePushCommitForTest` and
        // with `uploadedCount == 0`! Re-sync B to r1 first, then mutate remote
        // `head.json` on the 2nd GET during A's push!
        final alignA = await serviceA.syncNow(
          resolution: SyncConflictResolution.useLocal,
        );
        expect(alignA.status, CloudSyncStatus.pushed);
        expect((await serviceB.syncNow()).status, CloudSyncStatus.pulled);

        var headGetCount = 0;
        davServer.onBeforeGet = (path) async {
          if (path == '/dav/TallySync/sync/head.json') {
            headGetCount++;
            if (headGetCount == 2) {
              // Simulate another device committing a new revision right before A commits!
              final concurrentHead = CloudSyncHead(
                revision: alignA.revision + 1,
                dataSha256: 'f' * 64,
                updatedAtMs: now + 9000,
                deviceId: 'other-device-99',
                deviceName: '另一台手机',
                recordCount: 9,
                attachmentFiles: const <String>[],
              );
              davServer.files[path] = Uint8List.fromList(
                utf8.encode(jsonEncode(concurrentHead.toJson())),
              );
            }
          }
        };
        now += 10000;
        await ledgerA.saveRecord(
          commandId: 'dav-b04-zero-att-race',
          draft: RecordDraft(
            bookId: 1,
            type: RecordType.expense,
            money: Money.parse('12.00'),
            recordTime: now,
            categoryId: 1,
            assetId: walletId,
            remark: '无附件并发抢占检测',
          ),
        );
        // Notice: `beforePushCommitForTest` is NOT passed and `uploadedCount == 0`!
        final b04Outcome = await serviceA.syncNow();
        davServer.onBeforeGet = null;
        expect(headGetCount, 2);
        expect(b04Outcome.isConflict, isTrue);
        expect(b04Outcome.revision, alignA.revision + 1);

        // 4. B-05: Active multi-chunk download exceeding single `transferTimeout`
        // wall-clock duration succeeds, while stalled socket times out cleanly!
        final slowStreamServer = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final slowStreamSub = slowStreamServer.listen((req) async {
          await req.drain<void>();
          if (req.uri.path.endsWith('/active.bin')) {
            // Total 5 chunks * 55ms = 275ms > transferTimeout (150ms),
            // but idle gap between chunks (55ms) < 150ms!
            req.response.statusCode = HttpStatus.ok;
            req.response.bufferOutput = false;
            req.response.contentLength = 50;
            for (var i = 0; i < 5; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 55));
              req.response.add(List<int>.filled(10, 65 + i));
              await req.response.flush();
            }
            await req.response.close();
          } else {
            // Intentionally stall mid-stream longer than transferTimeout!
            req.response.statusCode = HttpStatus.ok;
            req.response.bufferOutput = false;
            req.response.contentLength = 20;
            req.response.add(List<int>.filled(10, 90));
            await req.response.flush();
            // Never send second half.
          }
        });
        addTearDown(() async {
          await slowStreamSub.cancel();
          await slowStreamServer.close(force: true);
        });

        final streamClient = WebDavClient(
          WebDavConfig(
            serverUrl: 'http://127.0.0.1:${slowStreamServer.port}/dav',
            username: 'alice',
            password: 'pw',
            remoteDirectory: '/TallySync',
          ),
          controlTimeout: const Duration(milliseconds: 120),
          transferTimeout: const Duration(milliseconds: 150),
        );
        final activeBytes = await streamClient.getRelativeFileOrNull(
          'active.bin',
        );
        expect(activeBytes, isNotNull);
        expect(activeBytes!.length, 50);

        await expectLater(
          streamClient.getRelativeFileOrNull('stalled_mid_stream.bin'),
          throwsA(
            isA<Failure>()
                .having((f) => f.code, 'code', FailureCode.remoteUnavailable)
                .having((f) => f.message, 'msg', contains('超时')),
          ),
        );
      },
    );

    test(
      'Workstream 1 (1-3 & 5): WebDAV stale HEAD cache fallback, non-destructive push head.json verification, missing snapshot self-heal, and batch backup deletion',
      () async {
        final davServer = await _LoopbackSyncWebDavServer.start()
          ..rejectMoveOverwriteWith409 = true;
        final s3Server = await _LoopbackSigV4S3Server.start();
        addTearDown(davServer.close);
        addTearDown(s3Server.close);

        final tempRoot = await Directory.systemTemp.createTemp(
          'ws1_sync_fixes_',
        );
        addTearDown(() async {
          if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
        });

        var now = 1794800000000;
        final dbA = AppDatabase(NativeDatabase.memory(), nowMs: () => now);
        final dbB = AppDatabase(NativeDatabase.memory(), nowMs: () => now);
        addTearDown(dbA.close);
        addTearDown(dbB.close);

        final localBkDirA = Directory(p.join(tempRoot.path, 'bk_a'));
        final attDirA = Directory(p.join(tempRoot.path, 'att_a'))
          ..createSync(recursive: true);
        final serviceA = TallyBackupService(
          dbA,
          reminderService: ReminderService(
            dbA,
            scheduler: InMemoryReminderScheduler(),
          ),
          localBackupsDirectoryProvider: () async => localBkDirA,
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
          attachmentsDirectoryProvider: () async =>
              Directory(p.join(tempRoot.path, 'att_b')),
        );

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

        await dbA.select(dbA.accountBooks).get();
        await dbB.select(dbB.accountBooks).get();
        final ledgerA = LedgerService(dbA);
        final walletId = await ledgerA.createAsset(
          commandId: 'ws1-wallet',
          name: '主力储蓄卡',
          type: AssetType.normal,
          initial: Money.parse('1000.00'),
        );

        // Initial r1 push & B pull
        expect((await serviceA.syncNow()).revision, 1);
        expect((await serviceB.syncNow()).revision, 1);

        // ------------------------------------------------------------------
        // 1a. Stale 0ms HEAD Content-Length on overwrite of small payload
        // (`sync/head.json` <= 256 KB) falls back to no-cache GET + SHA-256!
        // ------------------------------------------------------------------
        final r1HeadLen =
            davServer.files['/dav/TallySync/sync/head.json']!.length;
        // Force a different JSON byte length on r2 (deviceName length change + recordCount)
        await serviceA.saveCloudSyncSettings(
          (await serviceA.getCloudSyncSettings()).copyWith(
            deviceName: '帐屿主力手机-长设备名测试网关缓存',
          ),
        );
        now += 5000;
        await ledgerA.saveRecord(
          commandId: 'ws1-rec-r2',
          draft: RecordDraft(
            bookId: 1,
            type: RecordType.expense,
            money: Money.parse('36.50'),
            recordTime: now,
            categoryId: 1,
            assetId: walletId,
            remark: '网关HEAD旧缓存验证',
          ),
        );

        davServer.overrideHeadLength = (path, req) {
          if (path == '/dav/TallySync/sync/head.json') {
            return r1HeadLen; // Stale cached Content-Length from r1!
          }
          return null;
        };
        final pushR2 = await serviceA.syncNow();
        davServer.overrideHeadLength = null;
        expect(pushR2.status, CloudSyncStatus.pushed);
        expect(pushR2.revision, 2);
        expect(davServer.lastGetCacheControl, 'no-cache');
        expect((await serviceA.getSyncCursor()).lastSyncedRevision, 2);
        expect(
          davServer.files.containsKey(
            '/dav/TallySync/${pushR2.remoteHead!.databasePath}',
          ),
          isTrue,
        );

        // Next local edit + sync pushes r3 cleanly WITHOUT false-positive conflict!
        now += 5000;
        await ledgerA.saveRecord(
          commandId: 'ws1-rec-r3',
          draft: RecordDraft(
            bookId: 1,
            type: RecordType.expense,
            money: Money.parse('13.50'),
            recordTime: now,
            categoryId: 1,
            assetId: walletId,
            remark: '单机连续记账无误报冲突',
          ),
        );
        final pushR3 = await serviceA.syncNow();
        expect(pushR3.status, CloudSyncStatus.pushed);
        expect(pushR3.revision, 3);

        // ------------------------------------------------------------------
        // 1b. Large payload (> 256 KB) stale HEAD retries HEAD with no-cache,
        // and genuine mismatches (both small & large) still fail closed!
        // ------------------------------------------------------------------
        final davClient = WebDavClient(
          davCfg,
          staleHeadRetryDelay: const Duration(milliseconds: 10),
        );
        final largeBytes = Uint8List.fromList(
          List<int>.generate(300 * 1024, (i) => i & 0xFF),
        );
        // Seed existing target so MOVE 409 triggers fallback PUT + HEAD
        davServer.files['/dav/TallySync/large.bin'] = Uint8List.fromList(<int>[
          1,
          2,
          3,
        ]);
        davServer.overrideHeadLength = (path, req) {
          if (path == '/dav/TallySync/large.bin') {
            final cc = req.headers.value(HttpHeaders.cacheControlHeader);
            return cc == 'no-cache' ? largeBytes.length : 3;
          }
          return null;
        };
        final getsBeforeLarge = davServer.getCount;
        await davClient.putRelativeFile('large.bin', largeBytes);
        davServer.overrideHeadLength = null;
        // Large payload verified via no-cache HEAD retry without downloading 300 KB!
        expect(davServer.getCount, getsBeforeLarge);
        expect(davServer.lastHeadCacheControl, 'no-cache');

        // Fail-closed on genuine small payload mismatch (GET returns corrupted bytes)
        davServer.files['/dav/TallySync/small_bad.json'] = Uint8List.fromList(
          utf8.encode('old'),
        );
        davServer.overrideHeadLength = (path, _) =>
            path.endsWith('/small_bad.json') ? 3 : null;
        davServer.overrideGetBytes = (path, _) =>
            path.endsWith('/small_bad.json')
            ? Uint8List.fromList(utf8.encode('corrupt!'))
            : davServer.files[path];
        await expectLater(
          davClient.putRelativeFile(
            'small_bad.json',
            Uint8List.fromList(utf8.encode('expected-valid-json')),
          ),
          throwsA(
            isA<Failure>().having(
              (f) => f.message,
              'msg',
              contains('Content-Length 校验不一致'),
            ),
          ),
        );
        davServer.overrideHeadLength = null;
        davServer.overrideGetBytes = null;

        // Fail-closed on genuine large payload mismatch (both HEADs mismatch)
        davServer.overrideHeadLength = (path, _) =>
            path.endsWith('/large.bin') ? 99 : null;
        await expectLater(
          davClient.putRelativeFile('large.bin', largeBytes),
          throwsA(
            isA<Failure>().having(
              (f) => f.message,
              'msg',
              contains('Content-Length 校验不一致'),
            ),
          ),
        );
        davServer.overrideHeadLength = null;

        // ------------------------------------------------------------------
        // 2a. `_executeSyncPush`: `putObject('sync/head.json')` throws AFTER
        // server already saved `newHead` -> keeps `revisionPath`, updates
        // cursor (clearing `lastConflictFileName`), and returns `pushed`!
        // ------------------------------------------------------------------
        // Seed a stale lastConflictFileName on A's cursor to verify it clears too
        final curBeforeR4 = await serviceA.getSyncCursor();
        await dbA
            .into(dbA.preferences)
            .insertOnConflictUpdate(
              PreferencesCompanion.insert(
                key: prefKeyCloudSyncCursor,
                value: jsonEncode(
                  curBeforeR4
                      .copyWith(
                        lastConflictFileName:
                            'conflict_old_20261124_000000.tally',
                        lastConflictSha256: 'b' * 64,
                      )
                      .toJson(),
                ),
              ),
            );
        now += 5000;
        await ledgerA.saveRecord(
          commandId: 'ws1-rec-r4',
          draft: RecordDraft(
            bookId: 1,
            type: RecordType.expense,
            money: Money.parse('50.00'),
            recordTime: now,
            categoryId: 1,
            assetId: walletId,
            remark: '网关返回502但远端head已落盘',
          ),
        );
        davServer.failPutAfterSavingHeadJson = true;
        final recoveredPushR4 = await serviceA.syncNow();
        davServer.failPutAfterSavingHeadJson = false;
        expect(recoveredPushR4.status, CloudSyncStatus.pushed);
        expect(recoveredPushR4.revision, 4);
        final r4DbServerKey =
            '/dav/TallySync/${recoveredPushR4.remoteHead!.databasePath}';
        expect(davServer.files.containsKey(r4DbServerKey), isTrue);
        final curAfterR4 = await serviceA.getSyncCursor();
        expect(curAfterR4.lastSyncedRevision, 4);
        expect(curAfterR4.lastConflictFileName, isNull);
        // Device B pulls r4 cleanly with zero 404!
        final pullR4OnB = await serviceB.syncNow();
        expect(pullR4OnB.status, CloudSyncStatus.pulled);
        expect(pullR4OnB.revision, 4);

        // ------------------------------------------------------------------
        // 2b. `_executeSyncPush`: `putObject('sync/head.json')` throws AND
        // reading remote `head.json` fails (network outage) -> rethrows
        // WITHOUT deleting `revisionPath`!
        // ------------------------------------------------------------------
        now += 5000;
        await ledgerA.saveRecord(
          commandId: 'ws1-rec-r5',
          draft: RecordDraft(
            bookId: 1,
            type: RecordType.expense,
            money: Money.parse('18.00'),
            recordTime: now,
            categoryId: 1,
            assetId: walletId,
            remark: '断网不可盲删新快照',
          ),
        );
        final expectedR5Sha = await serviceA.computeLocalDataSha256();
        final expectedR5Path = buildCloudSyncRevisionPath(
          revision: 5,
          dataSha256: expectedR5Sha,
        );
        davServer.failPutAfterSavingHeadJson = true;
        // Let initial & pre-commit GET succeed, then return 503 on the 3rd GET
        // (when `_readRemoteSyncHead` tries to inspect remote `head.json`)!
        var seenHeadGetDuringPush = 0;
        davServer.onBeforeGet = (path) async {
          if (path == '/dav/TallySync/sync/head.json') {
            seenHeadGetDuringPush++;
            if (seenHeadGetDuringPush >= 3) {
              davServer.failGetOnHeadJson = true;
            }
          }
        };
        await expectLater(serviceA.syncNow(), throwsA(isA<Failure>()));
        davServer.failPutAfterSavingHeadJson = false;
        davServer.failGetOnHeadJson = false;
        davServer.onBeforeGet = null;
        // `db_r5` MUST still exist on server (not blindly deleted)!
        expect(
          davServer.files.containsKey('/dav/TallySync/$expectedR5Path'),
          isTrue,
        );

        // Restore r4 head.json to test 2c cleanly:
        davServer.files['/dav/TallySync/sync/head.json'] = Uint8List.fromList(
          utf8.encode(jsonEncode(recoveredPushR4.remoteHead!.toJson())),
        );
        davServer.files.remove('/dav/TallySync/$expectedR5Path');

        // ------------------------------------------------------------------
        // 2c. `_executeSyncPush`: `putObject('sync/head.json')` fails BEFORE
        // server updates `head.json` (remote head still r4 != r5) -> cleans up
        // uncommitted `db_r5` and rethrows!
        // ------------------------------------------------------------------
        davServer.failPutBeforeSavingHeadJson = true;
        await expectLater(serviceA.syncNow(), throwsA(isA<Failure>()));
        davServer.failPutBeforeSavingHeadJson = false;
        expect(
          davServer.files.containsKey('/dav/TallySync/$expectedR5Path'),
          isFalse,
        );

        // Now complete r5 push normally:
        final pushR5 = await serviceA.syncNow();
        expect(pushR5.status, CloudSyncStatus.pushed);
        expect(pushR5.revision, 5);
        final r5DbKey = '/dav/TallySync/${pushR5.remoteHead!.databasePath}';

        // ------------------------------------------------------------------
        // 3a & 3b. Self-heal missing remote `databasePath` on `noOp` and
        // `fastForwardCursor` (WebDAV HEAD 404 + S3 ListObjectsV2 missing)!
        // ------------------------------------------------------------------
        // 3a: Delete remote `db_r5` while `head.json` points to r5 and A is at r5 (`noOp`)
        davServer.files.remove(r5DbKey);
        expect(davServer.files.containsKey(r5DbKey), isFalse);
        final healNoOp = await serviceA.syncNow();
        expect(healNoOp.status, CloudSyncStatus.alreadyUpToDate);
        expect(davServer.files.containsKey(r5DbKey), isTrue);

        // 3b: Rewind A's cursor to r4 while local data == remote r5, and delete `db_r5` (`fastForwardCursor`)
        davServer.files.remove(r5DbKey);
        await dbA
            .into(dbA.preferences)
            .insertOnConflictUpdate(
              PreferencesCompanion.insert(
                key: prefKeyCloudSyncCursor,
                value: jsonEncode(
                  (await serviceA.getSyncCursor())
                      .copyWith(
                        lastSyncedRevision: 4,
                        lastSyncedDataSha256: '0' * 64,
                        lastConflictFileName:
                            'conflict_stale_20261124_010101.tally',
                      )
                      .toJson(),
                ),
              ),
            );
        final healFastForward = await serviceA.syncNow();
        expect(healFastForward.status, CloudSyncStatus.alreadyUpToDate);
        expect(healFastForward.revision, 5);
        expect(davServer.files.containsKey(r5DbKey), isTrue);
        expect((await serviceA.getSyncCursor()).lastConflictFileName, isNull);
        // Device B pulls the self-healed r5 snapshot cleanly!
        final pullR5OnB = await serviceB.syncNow();
        expect(pullR5OnB.status, CloudSyncStatus.pulled);
        expect(pullR5OnB.revision, 5);

        // Also verify S3 self-heal when `databasePath` object is missing on S3:
        final s3Cfg = S3Config(
          endpoint: s3Server.endpoint,
          region: 'auto',
          bucket: s3Server.expectedBucket,
          accessKeyId: s3Server.expectedAccessKey,
          secretAccessKey: s3Server.expectedSecretKey,
          remotePrefix: 'TallyIsle',
        );
        await serviceA.saveS3Config(s3Cfg);
        await serviceA.setCloudBackend(CloudBackendType.s3);
        final s3Push1 = await serviceA.syncNow();
        expect(s3Push1.status, CloudSyncStatus.pushed);
        final s3SnapKey = 'TallyIsle/${s3Push1.remoteHead!.databasePath}';
        s3Server.objects.remove(s3SnapKey);
        expect(s3Server.objects.containsKey(s3SnapKey), isFalse);
        final s3Heal = await serviceA.syncNow();
        expect(s3Heal.status, CloudSyncStatus.alreadyUpToDate);
        expect(s3Server.objects.containsKey(s3SnapKey), isTrue);

        // ------------------------------------------------------------------
        // 5. Batch `deleteLocalBackups` & `deleteActiveCloudBackups` + export
        // ------------------------------------------------------------------
        final bkBytes = (await serviceA.createBackupBytes()).bytes;
        await serviceA.localTarget.writeBackup(
          'backup_20261120_100000.tally',
          bkBytes,
        );
        await serviceA.localTarget.writeBackup(
          'conflict_dev1_20261121_100000.tally',
          bkBytes,
        );
        await serviceA.localTarget.writeBackup(
          'backup_20261122_100000.tally',
          bkBytes,
        );
        await dbA
            .into(dbA.preferences)
            .insertOnConflictUpdate(
              PreferencesCompanion.insert(
                key: prefKeyCloudSyncCursor,
                value: jsonEncode(
                  (await serviceA.getSyncCursor())
                      .copyWith(
                        lastConflictFileName:
                            'conflict_dev1_20261121_100000.tally',
                        lastConflictSha256: 'c' * 64,
                      )
                      .toJson(),
                ),
              ),
            );

        // Upfront validation rejects unsafe / non-.tally names without deleting anything
        for (final invalid in <String>[
          '../evil.tally',
          'sub/evil.tally',
          'not_a_backup.txt',
          'staging.tally.tmp',
        ]) {
          await expectLater(
            serviceA.deleteLocalBackups(<String>[
              'backup_20261120_100000.tally',
              invalid,
            ]),
            throwsA(
              isA<Failure>().having(
                (f) => f.code,
                'code',
                FailureCode.validation,
              ),
            ),
          );
        }
        expect(await serviceA.listLocalBackups(), hasLength(3));

        // Exporting a specific historical backup reads its exact bytes
        Uint8List? exportedBytes;
        String? exportedName;
        await serviceA.exportExistingBackup(
          fileName: 'conflict_dev1_20261121_100000.tally',
          isCloud: false,
          fileAccess: FileAccess(
            onSaveBytes: (name, bytes, _) async {
              exportedName = name;
              exportedBytes = bytes;
            },
          ),
        );
        expect(exportedName, 'conflict_dev1_20261121_100000.tally');
        expect(exportedBytes, equals(bkBytes));

        // Deleting a non-conflict file preserves `lastConflictFileName`
        expect(
          await serviceA.deleteLocalBackups(<String>[
            'backup_20261120_100000.tally',
          ]),
          1,
        );
        expect(
          (await serviceA.getSyncCursor()).lastConflictFileName,
          'conflict_dev1_20261121_100000.tally',
        );

        // Batch-deleting the conflict file clears `lastConflictFileName`!
        expect(
          await serviceA.deleteLocalBackups(<String>[
            'conflict_dev1_20261121_100000.tally',
            'backup_20261122_100000.tally',
          ]),
          2,
        );
        expect(await serviceA.listLocalBackups(), isEmpty);
        expect((await serviceA.getSyncCursor()).lastConflictFileName, isNull);

        // Cloud batch delete on active S3 target
        await serviceA.uploadBackupToS3(
          customFileName: 'backup_20261120_120000.tally',
        );
        await serviceA.uploadBackupToS3(
          customFileName: 'conflict_dev1_20261121_120000.tally',
        );
        expect(await serviceA.listActiveCloudBackups(), hasLength(2));
        expect(
          await serviceA.deleteActiveCloudBackups(<String>[
            'backup_20261120_120000.tally',
            'conflict_dev1_20261121_120000.tally',
          ]),
          2,
        );
        expect(await serviceA.listActiveCloudBackups(), isEmpty);
      },
    );

    test(
      'Three-Way Merge end-to-end (with Isolate offload & ti_write_command reset), 304 Conditional Probe, Zero-LIST Push, >1000 S3 Pagination, 30d GC & Oversize Conflict Hydration',
      () async {
        final s3 = await _LoopbackSigV4S3Server.start();
        s3.maxKeysPerPage = 1000;
        addTearDown(s3.close);

        final tempRoot = await Directory.systemTemp.createTemp(
          'tally_sync_3way_scale_',
        );
        addTearDown(() => tempRoot.delete(recursive: true));

        var now = 1762870000000;
        final dbA = AppDatabase(NativeDatabase.memory(), nowMs: () => now);
        final dbB = AppDatabase(NativeDatabase.memory(), nowMs: () => now);
        addTearDown(dbA.close);
        addTearDown(dbB.close);
        await dbA.select(dbA.accountBooks).get();
        await dbB.select(dbB.accountBooks).get();

        final attA = Directory(p.join(tempRoot.path, 'att_a'));
        final attB = Directory(p.join(tempRoot.path, 'att_b'));

        // Seed stale `attachments.bak_100` power-loss rescue test on A before first service call!
        final bakA = Directory('${attA.path}.bak_100');
        await bakA.create(recursive: true);
        final rescuedBytes = Uint8List.fromList(
          utf8.encode('rescued-power-loss'),
        );
        await File(p.join(bakA.path, 'rescued.jpg')).writeAsBytes(rescuedBytes);

        final serviceA = TallyBackupService(
          dbA,
          reminderService: ReminderService(
            dbA,
            scheduler: InMemoryReminderScheduler(),
          ),
          localBackupsDirectoryProvider: () async =>
              Directory(p.join(tempRoot.path, 'bk_a')),
          attachmentsDirectoryProvider: () async => attA,
          isolateOffloadRowThreshold: 1, // Force real background Isolate.run!
        );
        final serviceB = TallyBackupService(
          dbB,
          reminderService: ReminderService(
            dbB,
            scheduler: InMemoryReminderScheduler(),
          ),
          localBackupsDirectoryProvider: () async =>
              Directory(p.join(tempRoot.path, 'bk_b')),
          attachmentsDirectoryProvider: () async => attB,
          isolateOffloadRowThreshold: 1,
        );

        final s3Cfg = S3Config(
          endpoint: s3.endpoint,
          region: s3.expectedRegion,
          bucket: s3.expectedBucket,
          accessKeyId: s3.expectedAccessKey,
          secretAccessKey: s3.expectedSecretKey,
          remotePrefix: 'TallyIsle',
          forcePathStyle: true,
        );
        await serviceA.saveS3Config(s3Cfg);
        await serviceB.saveS3Config(s3Cfg);
        await serviceA.setAutoArchiveBackupEnabled(false);
        await serviceB.setAutoArchiveBackupEnabled(false);
        await serviceA.updateCloudSyncTriggers(syncOnStartup: true);
        await serviceB.updateCloudSyncTriggers(syncOnStartup: true);

        final ledgerA = LedgerService(dbA);
        final ledgerB = LedgerService(dbB);
        final cardId = await ledgerA.createAsset(
          commandId: '3way-card',
          name: '主储蓄卡',
          type: AssetType.normal,
          initial: Money.parse('1000.00'),
        );

        // 1. Push r1 (verifies `.bak_100` power-loss self-healing restored `rescued.jpg`!)
        final push1 = await serviceA.syncNow();
        expect(push1.status, CloudSyncStatus.pushed);
        expect(push1.revision, 1);
        expect(await File(p.join(attA.path, 'rescued.jpg')).exists(), isTrue);

        // B pulls r1
        final pull1 = await serviceB.syncNow();
        expect(pull1.status, CloudSyncStatus.pulled);
        expect(pull1.revision, 1);

        // 2. Clean background auto-sync on B -> 1 HTTP GET (`304 Not Modified`), 0 HEAD, 0 LIST!
        s3.requestLog.clear();
        final bgNoOp = await serviceB.runCloudAutoSyncForTrigger(
          AutoTriggerSource.windowFocus,
        );
        expect(bgNoOp?.status, CloudSyncStatus.alreadyUpToDate);
        expect(s3.requestLog, <String>[
          'GET /tally-bucket/TallyIsle/sync/head.json',
        ]);

        // 3. Zero-LIST incremental push on A -> A adds a bill (-120.00) and pushes r2 without LISTing sync/attachments!
        now += 5000;
        await ledgerA.saveRecord(
          commandId: '3way-a-lunch',
          draft: RecordDraft(
            bookId: 1,
            type: RecordType.expense,
            money: Money.parse('120.00'),
            recordTime: now,
            categoryId: 1,
            assetId: cardId,
            remark: 'A端午餐',
          ),
        );
        s3.requestLog.clear();
        final push2 = await serviceA.syncNow();
        expect(push2.revision, 2);
        // Zero LIST calls for sync/attachments (only 1 LIST for sync/revisions Top-5 prune)!
        final listCalls = s3.requestLog
            .where((l) => l == 'GET /tally-bucket')
            .length;
        expect(listCalls, 1);

        // 4. Offline B adds an independent bill (-80.00) -> `serviceB.syncNow()` executes Three-Way Merge inside Isolate!
        now += 5000;
        await ledgerB.saveRecord(
          commandId: '3way-b-coffee',
          draft: RecordDraft(
            bookId: 1,
            type: RecordType.expense,
            money: Money.parse('80.00'),
            recordTime: now,
            categoryId: 1,
            assetId: cardId,
            remark: 'B端咖啡',
          ),
        );
        expect(await dbB.select(dbB.writeCommands).get(), isNotEmpty);

        final mergedOut = await serviceB.syncNow();
        expect(mergedOut.status, CloudSyncStatus.pushed);
        expect(mergedOut.didMerge, isTrue);
        expect(mergedOut.didReplaceLocalDatabase, isTrue);
        expect(mergedOut.revision, 3);
        expect(
          await serviceB.listLocalBackups(),
          isEmpty,
        ); // Zero false conflict_*.tally!
        expect(
          await dbB.select(dbB.writeCommands).get(),
          isEmpty,
        ); // ti_write_command cleared!

        final bRecords = await dbB.select(dbB.records).get();
        expect(bRecords, hasLength(2));
        final bCard = await (dbB.select(
          dbB.assets,
        )..where((t) => t.id.equals(cardId))).getSingle();
        // 1000.00 - 120.00 - 80.00 = 800.00 (80000 minor)!
        expect(bCard.balanceMinor, BigInt.from(80000));

        // A pulls r3 -> converges to exact 800.00!
        final pullA3 = await serviceA.syncNow();
        expect(pullA3.status, CloudSyncStatus.pulled);
        expect(pullA3.revision, 3);
        final aCard = await (dbA.select(
          dbA.assets,
        )..where((t) => t.id.equals(cardId))).getSingle();
        expect(aCard.balanceMinor, BigInt.from(80000));

        // 5. > 1,000 objects S3 pagination verification (`1,205` objects across 2 pages):
        for (var i = 1; i <= 1205; i++) {
          final pad = i.toString().padLeft(4, '0');
          s3.objects['TallyIsle/sync/revisions/dummy_$pad.txt'] =
              Uint8List.fromList(<int>[1]);
        }
        final s3Target = await serviceA.getS3Target();
        final listedMany = await s3Target.listRelativeFileNames(
          cloudSyncRevisionsDir,
        );
        expect(listedMany.length, greaterThanOrEqualTo(1208));

        // 6. Oversize conflict archive (`maxInlineConflictAttachmentBytes = 5`) -> writes
        // lightweight `includeAttachments: false` `conflict_*.tally` + `sync/conflict_refs/*.json`,
        // and `restoreLocalBackup` automatically hydrates attachments from `sync/attachments/`!
        serviceB.maxInlineConflictAttachmentBytes = 5;
        now += 10000;
        await (dbA.update(dbA.assets)..where((t) => t.id.equals(cardId))).write(
          const AssetsCompanion(name: Value('A改名储蓄卡')),
        );
        expect((await serviceA.syncNow()).revision, 4);

        final bigPhoto = Uint8List.fromList(List<int>.filled(64, 0x42));
        await File(
          p.join(attB.path, 'oversize_bill.jpg'),
        ).writeAsBytes(bigPhoto);
        await (dbB.update(dbB.assets)..where((t) => t.id.equals(cardId))).write(
          const AssetsCompanion(name: Value('B改名储蓄卡')),
        );
        final oversizeConflict = await serviceB.syncNow();
        expect(oversizeConflict.isConflict, isTrue);
        final conflictName = oversizeConflict.conflictBackupFileName!;
        expect(
          s3.objects.containsKey(
            'TallyIsle/$cloudSyncConflictRefsDir/$conflictName.json',
          ),
          isTrue,
        );
        final conflictBks = await serviceB.listLocalBackups();
        final lightMeta = conflictBks.singleWhere(
          (m) => m.fileName == conflictName,
        );
        expect(lightMeta.manifest?.includeAttachments, isFalse);

        // Adopt remote (wipes `oversize_bill.jpg` locally), then restore `conflictName` -> hydrates `oversize_bill.jpg`!
        await serviceB.syncNow(resolution: SyncConflictResolution.useRemote);
        expect(
          await File(p.join(attB.path, 'oversize_bill.jpg')).exists(),
          isFalse,
        );
        await serviceB.restoreLocalBackup(conflictName);
        expect(
          await File(p.join(attB.path, 'oversize_bill.jpg')).readAsBytes(),
          equals(bigPhoto),
        );
      },
    );

    test(
      '24h *.tmp Orphan Cleanup, Exit Merge Deferral, Zero-Copy Incremental Attachments, >30d WriteCommand Pruning & Retry-After Propagation',
      () async {
        driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
        final dav = await _LoopbackSyncWebDavServer.start();
        final s3 = await _LoopbackSigV4S3Server.start();
        final tempRoot = await Directory.systemTemp.createTemp(
          'tally_sync_reg_fixes_',
        );

        var now = DateTime(2026, 11, 20, 10, 0).millisecondsSinceEpoch;
        final dbA = AppDatabase(NativeDatabase.memory(), nowMs: () => now);
        final dbB = AppDatabase(NativeDatabase.memory(), nowMs: () => now);
        addTearDown(() async {
          await dbA.close();
          await dbB.close();
          await dav.close();
          await s3.close();
          if (await tempRoot.exists()) {
            await tempRoot.delete(recursive: true);
          }
        });

        final attA = Directory(p.join(tempRoot.path, 'att_a'))
          ..createSync(recursive: true);
        final attB = Directory(p.join(tempRoot.path, 'att_b'))
          ..createSync(recursive: true);

        // Seed interrupted incremental `.bak_*` with `.in_progress` marker on A
        // AND expired (>30d) vs recent (<30d) `ti_write_command` rows!
        final incBakA = Directory('${attA.path}.bak_999')
          ..createSync(recursive: true);
        await File(p.join(incBakA.path, '.in_progress')).writeAsString('1');
        final rescuedIncBytes = Uint8List.fromList(
          utf8.encode('incremental-rescued-photo'),
        );
        await File(
          p.join(incBakA.path, 'inc_rescued.jpg'),
        ).writeAsBytes(rescuedIncBytes);

        await dbA.select(dbA.accountBooks).get();
        await dbB.select(dbB.accountBooks).get();
        await dbA
            .into(dbA.writeCommands)
            .insert(
              WriteCommandsCompanion.insert(
                commandId: 'old-cmd-35d',
                payloadHash: 'h1',
                resultId: '1',
                committedAt: now - 35 * 24 * 60 * 60 * 1000,
              ),
            );
        await dbA
            .into(dbA.writeCommands)
            .insert(
              WriteCommandsCompanion.insert(
                commandId: 'recent-cmd-2d',
                payloadHash: 'h2',
                resultId: '2',
                committedAt: now - 2 * 24 * 60 * 60 * 1000,
              ),
            );

        final serviceA = TallyBackupService(
          dbA,
          reminderService: ReminderService(
            dbA,
            scheduler: InMemoryReminderScheduler(),
          ),
          localBackupsDirectoryProvider: () async =>
              Directory(p.join(tempRoot.path, 'bk_a')),
          attachmentsDirectoryProvider: () async => attA,
        );
        final serviceB = TallyBackupService(
          dbB,
          reminderService: ReminderService(
            dbB,
            scheduler: InMemoryReminderScheduler(),
          ),
          localBackupsDirectoryProvider: () async =>
              Directory(p.join(tempRoot.path, 'bk_b')),
          attachmentsDirectoryProvider: () async => attB,
        );

        final davCfg = WebDavConfig(
          serverUrl: dav.baseUrl,
          username: 'alice',
          password: 'secret',
          remoteDirectory: '/TallySync',
        );
        await serviceA.saveWebDavConfig(davCfg);
        await serviceB.saveWebDavConfig(davCfg);
        await serviceA.setAutoArchiveBackupEnabled(false);
        await serviceB.setAutoArchiveBackupEnabled(false);
        await serviceB.updateCloudSyncTriggers(
          syncOnStartup: true,
          syncOnExit: true,
        );

        final ledgerA = LedgerService(dbA);
        final ledgerB = LedgerService(dbB);
        final walletId = await ledgerA.createAsset(
          commandId: 'fix-wallet',
          name: '测试钱包',
          type: AssetType.normal,
          initial: Money.parse('1000.00'),
        );
        final recR1Id = await ledgerA.saveRecord(
          commandId: 'fix-r1-att',
          draft: RecordDraft(
            bookId: 1,
            type: RecordType.expense,
            money: Money.parse('10.00'),
            recordTime: now,
            categoryId: 1,
            assetId: walletId,
          ),
        );
        await (dbA.update(dbA.records)
              ..where((t) => t.recordId.equals(recR1Id)))
            .write(const RecordsCompanion(images: Value('inc_rescued.jpg')));

        // 1. Push r1 -> triggers startup self-healing (rescuing `.in_progress`
        // incremental `.bak_999` AND pruning `old-cmd-35d` while keeping `recent-cmd-2d`)!
        final r1 = await serviceA.syncNow();
        expect(r1.revision, 1);
        expect(
          await File(p.join(attA.path, 'inc_rescued.jpg')).readAsBytes(),
          equals(rescuedIncBytes),
        );
        final remainingCmdIds = (await dbA.select(dbA.writeCommands).get())
            .map((r) => r.commandId)
            .toSet();
        expect(remainingCmdIds, contains('recent-cmd-2d'));
        expect(remainingCmdIds, isNot(contains('old-cmd-35d')));

        // B pulls r1 -> backdate `inc_rescued.jpg` mtime on B to 2025-06-01 to prove 0-byte copy!
        expect((await serviceB.syncNow()).revision, 1);
        final existingAttOnB = File(p.join(attB.path, 'inc_rescued.jpg'));
        final pinnedMtime = DateTime.utc(2025, 6, 1, 12, 0, 0);
        await existingAttOnB.setLastModified(pinnedMtime);
        final mtimeBeforePull = (await existingAttOnB.stat()).modified;

        // 2. A adds a new bill + new photo (`new_bill.jpg`) and pushes r2.
        now += 5000;
        final newPhotoBytes = Uint8List.fromList(
          utf8.encode('brand-new-photo'),
        );
        await File(
          p.join(attA.path, 'new_bill.jpg'),
        ).writeAsBytes(newPhotoBytes);
        final recR2Id = await ledgerA.saveRecord(
          commandId: 'fix-a-r2',
          draft: RecordDraft(
            bookId: 1,
            type: RecordType.expense,
            money: Money.parse('25.00'),
            recordTime: now,
            categoryId: 1,
            assetId: walletId,
            remark: 'A端新单',
          ),
        );
        await (dbA.update(dbA.records)
              ..where((t) => t.recordId.equals(recR2Id)))
            .write(const RecordsCompanion(images: Value('new_bill.jpg')));
        expect((await serviceA.syncNow()).revision, 2);

        // 3. B also adds a compatible local bill -> `AutoTriggerSource.exit` MUST
        // defer cleanly WITHOUT creating false `conflict_*.tally` or poisoning cursor!
        now += 5000;
        await ledgerB.saveRecord(
          commandId: 'fix-b-local',
          draft: RecordDraft(
            bookId: 1,
            type: RecordType.expense,
            money: Money.parse('15.00'),
            recordTime: now,
            categoryId: 1,
            assetId: walletId,
            remark: 'B端本地单',
          ),
        );
        final exitSync = await serviceB.runCloudAutoSyncForTrigger(
          AutoTriggerSource.exit,
        );
        expect(exitSync?.status, CloudSyncStatus.alreadyUpToDate);
        expect(exitSync?.isConflict, isFalse);
        expect(await serviceB.listLocalBackups(), isEmpty);
        expect((await serviceB.getSyncCursor()).lastConflictFileName, isNull);

        // Next startup/focus sync on B cleanly 3-way merges r2 + local -> r3,
        // AND `inc_rescued.jpg` on B keeps its exact 2025-06-01 mtime (0-byte copy)!
        final startupMerge = await serviceB.runCloudAutoSyncForTrigger(
          AutoTriggerSource.startup,
        );
        expect(startupMerge?.status, CloudSyncStatus.pushed);
        expect(startupMerge?.didMerge, isTrue);
        expect(startupMerge?.revision, 3);
        expect((await existingAttOnB.stat()).modified, equals(mtimeBeforePull));
        expect(
          await File(p.join(attB.path, 'new_bill.jpg')).readAsBytes(),
          equals(newPhotoBytes),
        );

        // 4. 24h remote `*.tmp` orphan cleanup (`includeTmp: true`) across WebDAV dirs:
        // Advance clock > 25h first so 24h low-frequency remote maintenance runs on push!
        now += 25 * 60 * 60 * 1000;
        final staleMod = DateTime.fromMillisecondsSinceEpoch(
          now - 26 * 60 * 60 * 1000,
          isUtc: true,
        );
        final freshMod = DateTime.fromMillisecondsSinceEpoch(
          now - 1 * 60 * 60 * 1000,
          isUtc: true,
        );
        for (final stalePath in const <String>[
          '/dav/TallySync/orphan_root.tally.tmp',
          '/dav/TallySync/sync/head.json.tmp',
          '/dav/TallySync/sync/revisions/db_r99.tally.tmp',
          '/dav/TallySync/sync/attachments/att_abandoned.jpg.tmp',
        ]) {
          dav.files[stalePath] = Uint8List.fromList(<int>[1, 2, 3]);
          dav.modifiedAt[stalePath] = staleMod;
        }
        const freshTmpPath =
            '/dav/TallySync/sync/attachments/in_flight_upload.jpg.tmp';
        dav.files[freshTmpPath] = Uint8List.fromList(<int>[9, 9]);
        dav.modifiedAt[freshTmpPath] = freshMod;

        await ledgerB.saveRecord(
          commandId: 'fix-b-gc-trigger',
          draft: RecordDraft(
            bookId: 1,
            type: RecordType.expense,
            money: Money.parse('5.00'),
            recordTime: now,
            categoryId: 1,
            assetId: walletId,
            remark: '触发24h维护',
          ),
        );
        expect((await serviceB.syncNow()).revision, 4);
        expect(
          dav.files.containsKey('/dav/TallySync/orphan_root.tally.tmp'),
          isFalse,
        );
        expect(
          dav.files.containsKey('/dav/TallySync/sync/head.json.tmp'),
          isFalse,
        );
        expect(
          dav.files.containsKey(
            '/dav/TallySync/sync/revisions/db_r99.tally.tmp',
          ),
          isFalse,
        );
        expect(
          dav.files.containsKey(
            '/dav/TallySync/sync/attachments/att_abandoned.jpg.tmp',
          ),
          isFalse,
        );
        expect(dav.files.containsKey(freshTmpPath), isTrue);

        // 5. `429` + `Retry-After: 95` propagation across WebDavClient & S3Client!
        final davClient = WebDavClient(davCfg);
        dav.forceStatus = (_) => (429, '95');
        await expectLater(
          davClient.putRelativeFile(
            'throttle_test.bin',
            Uint8List.fromList(<int>[1]),
          ),
          throwsA(
            isA<Failure>().having((f) => f.retryAfterMs, 'retryAfterMs', 95000),
          ),
        );
        await expectLater(
          davClient.headRelativeFileOrNull('sync/head.json'),
          throwsA(
            isA<Failure>().having((f) => f.retryAfterMs, 'retryAfterMs', 95000),
          ),
        );
        dav.forceStatus = null;

        final s3Client = S3Client(
          S3Config(
            endpoint: s3.endpoint,
            region: s3.expectedRegion,
            bucket: s3.expectedBucket,
            accessKeyId: s3.expectedAccessKey,
            secretAccessKey: s3.expectedSecretKey,
            remotePrefix: 'TallyIsle',
            forcePathStyle: true,
          ),
        );
        s3.forceStatus = (_) => (429, '95');
        await expectLater(
          s3Client.getObjectOrNull('sync/head.json'),
          throwsA(
            isA<Failure>().having((f) => f.retryAfterMs, 'retryAfterMs', 95000),
          ),
        );
        await expectLater(
          s3Client.deleteObject('sync/head.json'),
          throwsA(
            isA<Failure>().having((f) => f.retryAfterMs, 'retryAfterMs', 95000),
          ),
        );
        s3.forceStatus = null;
      },
    );

    test(
      '3-Device Asymmetric Ring (A -> B -> C across 2+ revisions), >400 SQL Variable Chunking & lastNonIncrementalRevision Gate',
      () async {
        driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
        final s3 = await _LoopbackSigV4S3Server.start();
        s3.maxKeysPerPage = 1000;
        final tempRoot = await Directory.systemTemp.createTemp(
          'tally_sync_3ring_',
        );

        var now = DateTime(2026, 11, 22, 9, 0).millisecondsSinceEpoch;
        final dbA = AppDatabase(NativeDatabase.memory(), nowMs: () => now);
        final dbB = AppDatabase(NativeDatabase.memory(), nowMs: () => now);
        final dbC = AppDatabase(NativeDatabase.memory(), nowMs: () => now);
        addTearDown(() async {
          await dbA.close();
          await dbB.close();
          await dbC.close();
          await s3.close();
          if (await tempRoot.exists()) {
            await tempRoot.delete(recursive: true);
          }
        });

        final bkC = Directory(p.join(tempRoot.path, 'bk_c'));
        final serviceA = TallyBackupService(
          dbA,
          reminderService: ReminderService(
            dbA,
            scheduler: InMemoryReminderScheduler(),
          ),
          localBackupsDirectoryProvider: () async =>
              Directory(p.join(tempRoot.path, 'bk_a')),
          attachmentsDirectoryProvider: () async =>
              Directory(p.join(tempRoot.path, 'att_a')),
        );
        final serviceB = TallyBackupService(
          dbB,
          reminderService: ReminderService(
            dbB,
            scheduler: InMemoryReminderScheduler(),
          ),
          localBackupsDirectoryProvider: () async =>
              Directory(p.join(tempRoot.path, 'bk_b')),
          attachmentsDirectoryProvider: () async =>
              Directory(p.join(tempRoot.path, 'att_b')),
        );
        final serviceC = TallyBackupService(
          dbC,
          reminderService: ReminderService(
            dbC,
            scheduler: InMemoryReminderScheduler(),
          ),
          localBackupsDirectoryProvider: () async => bkC,
          attachmentsDirectoryProvider: () async =>
              Directory(p.join(tempRoot.path, 'att_c')),
        );

        final s3Cfg = S3Config(
          endpoint: s3.endpoint,
          region: s3.expectedRegion,
          bucket: s3.expectedBucket,
          accessKeyId: s3.expectedAccessKey,
          secretAccessKey: s3.expectedSecretKey,
          remotePrefix: 'RingSync',
          forcePathStyle: true,
        );
        for (final svc in <TallyBackupService>[serviceA, serviceB, serviceC]) {
          await svc.saveS3Config(s3Cfg);
          await svc.setAutoArchiveBackupEnabled(false);
        }

        final ledgerA = LedgerService(dbA);
        final ledgerB = LedgerService(dbB);
        final ledgerC = LedgerService(dbC);
        await dbA.select(dbA.accountBooks).get();
        await dbB.select(dbB.accountBooks).get();
        await dbC.select(dbC.accountBooks).get();

        final cardId = await ledgerA.createAsset(
          commandId: 'ring-card',
          name: '多端环测卡',
          type: AssetType.normal,
          initial: Money.parse('10000.00'), // 1,000,000 minor
        );
        await dbA
            .into(dbA.tags)
            .insert(TagsCompanion.insert(tagId: 'tag-bulk', name: '批量标签'));

        // Batch-insert 520 initial bills (`1.00` each = 520.00) + composite `tag_record`s
        // on A so we exercise > 400 SQL variable chunking on BOTH delete and upsert!
        await dbA.batch((b) {
          for (var i = 0; i < 520; i++) {
            b.insert(
              dbA.records,
              RecordsCompanion.insert(
                recordId: 'base-rec-$i',
                type: RecordType.expense,
                subType: const Value(RecordDirection.none),
                moneyMinor: BigInt.from(100),
                discountMinor: i.isEven
                    ? Value(BigInt.from(10))
                    : const Value(null),
                remark: Value('基线单-$i'),
                recordTime: now + i,
                recordCatId: const Value(1),
                assetId: Value(cardId),
                accountBookId: 1,
                createDate: Value(now + i),
              ),
            );
            b.insert(
              dbA.tagRecords,
              TagRecordsCompanion.insert(
                tagId: 'tag-bulk',
                recordId: 'base-rec-$i',
              ),
            );
          }
        });
        await (dbA.update(dbA.assets)..where((t) => t.id.equals(cardId))).write(
          AssetsCompanion(balanceMinor: Value(BigInt.from(1000000 - 52000))),
        );

        // Push r1 from A, and pull r1 onto both B and C!
        expect((await serviceA.syncNow()).revision, 1);
        expect((await serviceB.syncNow()).revision, 1);
        expect((await serviceC.syncNow()).revision, 1);

        // Delete C's local `.sync_base` directory to force historical ancestor fetch
        // from remote Top-5 `sync/revisions/db_r1_*.tally`!
        final cSyncBase = Directory(p.join(bkC.parent.path, '.sync_base'));
        if (await cSyncBase.exists()) {
          await cSyncBase.delete(recursive: true);
        }

        // A deletes 510 base records (+510.00) and inserts 525 new records (-1050.00) -> pushes r2!
        now += 10000;
        await dbA.transaction(() async {
          for (var i = 0; i < 510; i++) {
            await (dbA.delete(
              dbA.tagRecords,
            )..where((t) => t.recordId.equals('base-rec-$i'))).go();
            await (dbA.delete(
              dbA.records,
            )..where((t) => t.recordId.equals('base-rec-$i'))).go();
          }
          await dbA.batch((b) {
            for (var j = 0; j < 525; j++) {
              b.insert(
                dbA.records,
                RecordsCompanion.insert(
                  recordId: 'a-new-$j',
                  type: RecordType.expense,
                  subType: const Value(RecordDirection.none),
                  moneyMinor: BigInt.from(200),
                  discountMinor: j.isOdd
                      ? Value(BigInt.from(5))
                      : const Value(null),
                  remark: Value('A新增批量-$j'),
                  recordTime: now + j,
                  recordCatId: const Value(1),
                  assetId: Value(cardId),
                  accountBookId: 1,
                  createDate: Value(now + j),
                ),
              );
              b.insert(
                dbA.tagRecords,
                TagRecordsCompanion.insert(
                  tagId: 'tag-bulk',
                  recordId: 'a-new-$j',
                ),
              );
            }
          });
          // 948,000 + 51,000 - 105,000 = 894,000 minor
          await (dbA.update(dbA.assets)..where((t) => t.id.equals(cardId)))
              .write(AssetsCompanion(balanceMinor: Value(BigInt.from(894000))));
        });
        expect((await serviceA.syncNow()).revision, 2);

        // B (at r1) adds a manual bill (-30.00 = -3000 minor) -> 3-way merges r1->r2 into r3!
        now += 10000;
        await ledgerB.saveRecord(
          commandId: 'ring-b-1',
          draft: RecordDraft(
            bookId: 1,
            type: RecordType.expense,
            money: Money.parse('30.00'),
            recordTime: now,
            categoryId: 1,
            assetId: cardId,
            remark: 'B端独立消费',
          ),
        );
        final mergeB = await serviceB.syncNow();
        expect(mergeB.didMerge, isTrue);
        expect(mergeB.revision, 3);

        // C (still at r1, 2 revisions behind r3, AND with `.sync_base` deleted!)
        // adds its own manual bill (-70.00 = -7000 minor) -> fetches `db_r1_*.tally`
        // from remote `sync/revisions/`, merges >500 deletes + >500 upserts into r4!
        now += 10000;
        await ledgerC.saveRecord(
          commandId: 'ring-c-1',
          draft: RecordDraft(
            bookId: 1,
            type: RecordType.expense,
            money: Money.parse('70.00'),
            recordTime: now,
            categoryId: 1,
            assetId: cardId,
            remark: 'C端滞后两版独立消费',
          ),
        );
        final mergeC = await serviceC.syncNow();
        expect(mergeC.status, CloudSyncStatus.pushed);
        expect(mergeC.didMerge, isTrue);
        expect(mergeC.revision, 4);

        // Total records: (520 - 510) + 525 + 1 (B) + 1 (C) = 537!
        expect(await dbC.select(dbC.records).get(), hasLength(537));
        expect(await dbC.select(dbC.tagRecords).get(), hasLength(535));
        final cCard = await (dbC.select(
          dbC.assets,
        )..where((t) => t.id.equals(cardId))).getSingle();
        // 894,000 - 3,000 - 7,000 = 884,000 minor!
        expect(cCard.balanceMinor, BigInt.from(884000));

        // A and B pull r4 -> all 3 devices converge identically to 884,000 minor!
        expect((await serviceA.syncNow()).revision, 4);
        expect((await serviceB.syncNow()).revision, 4);
        final aCard = await (dbA.select(
          dbA.assets,
        )..where((t) => t.id.equals(cardId))).getSingle();
        expect(aCard.balanceMinor, BigInt.from(884000));

        // Now verify `lastNonIncrementalRevision` barrier:
        // B creates a backup, deletes a record, restores backup (`localFullReplaceSinceLastSync`),
        // and force-pushes `useLocal` as r5 -> `lastNonIncrementalRevision == 5`!
        final snapBytes = (await serviceB.createBackupBytes()).bytes;
        await ledgerB.saveRecord(
          commandId: 'ring-b-temp',
          draft: RecordDraft(
            bookId: 1,
            type: RecordType.expense,
            money: Money.parse('1.00'),
            recordTime: now + 1000,
            categoryId: 1,
            assetId: cardId,
          ),
        );
        await serviceB.restoreFromBytes(snapBytes);
        await ledgerB.saveRecord(
          commandId: 'ring-b-post-restore',
          draft: RecordDraft(
            bookId: 1,
            type: RecordType.expense,
            money: Money.parse('9.00'),
            recordTime: now + 2000,
            categoryId: 1,
            assetId: cardId,
          ),
        );
        final forceR5 = await serviceB.syncNow(
          resolution: SyncConflictResolution.useLocal,
        );
        expect(forceR5.revision, 5);
        expect(forceR5.remoteHead?.lastNonIncrementalRevision, 5);

        // C (at r4 < lastNonIncrementalRevision 5) adds a bill -> MUST block
        // unsafe 3-way merge across full-replace barrier and report conflict!
        await ledgerC.saveRecord(
          commandId: 'ring-c-after-r4',
          draft: RecordDraft(
            bookId: 1,
            type: RecordType.expense,
            money: Money.parse('12.00'),
            recordTime: now + 3000,
            categoryId: 1,
            assetId: cardId,
          ),
        );
        final blockedOnC = await serviceC.syncNow();
        expect(blockedOnC.isConflict, isTrue);
        expect(blockedOnC.didMerge, isFalse);
      },
    );
  });
}
