import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/core/zip_archive.dart';
import 'package:tallyisle/data/backup/s3_client.dart';
import 'package:tallyisle/data/backup/webdav_client.dart';
import 'package:tallyisle/domain/rules/cloud_sync_rules.dart';
import 'package:tallyisle/domain/rules/s3_sigv4_rules.dart';
import 'package:tallyisle/domain/rules/tally_backup.dart';

Map<String, List<Map<String, Object?>>> _buildDefaultSeedTables() {
  const expenseNames = <String>[
    '餐饮',
    '购物',
    '交通',
    '娱乐',
    '零食',
    '日用品',
    '生活居家',
    '话费',
    '运动',
    '医疗',
    '发红包',
    '捐款',
  ];
  const incomeNames = <String>['工资', '零花钱', '奖金', '收红包'];
  final categories = <Map<String, Object?>>[];
  for (var i = 0; i < expenseNames.length; i++) {
    categories.add(<String, Object?>{
      'id': i + 1,
      'account_book_id': 1,
      'parent_cat_id': -1,
      'name': expenseNames[i],
      'type': 0,
      'sort': i,
      'is_hide': 0,
      'icon': '',
    });
  }
  for (var i = 0; i < incomeNames.length; i++) {
    final idx = expenseNames.length + i;
    categories.add(<String, Object?>{
      'id': idx + 1,
      'account_book_id': 1,
      'parent_cat_id': -1,
      'name': incomeNames[i],
      'type': 1,
      'sort': idx,
      'is_hide': 0,
      'icon': '',
    });
  }
  return <String, List<Map<String, Object?>>>{
    'account_book': <Map<String, Object?>>[
      <String, Object?>{
        'id': 1,
        'name': '日常账本',
        'type': 1,
        'cover': '',
        'sort': 1,
        'status': 0,
        'start_day': 1,
        'display_way': 0,
      },
    ],
    'record_category': categories,
    'currency': <Map<String, Object?>>[
      <String, Object?>{
        'code': 'CNY',
        'name': '人民币',
        'symbol': '¥',
        'rate_to_anchor': '1',
        'anchor_code': 'CNY',
      },
    ],
  };
}

void main() {
  group('S-01: CloudSyncHead format: 2, databasePath validation & revision pruning', () {
    test(
      'serializes format: 2 with immutable databasePath and rejects unsafe/legacy heads',
      () {
        const sha =
            '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
        expect(currentCloudSyncHeadFormat, 2);
        expect(
          buildCloudSyncRevisionPath(revision: 7, dataSha256: sha),
          'sync/revisions/db_r7_0123456789abcdef.tally',
        );

        final head = CloudSyncHead(
          revision: 7,
          dataSha256: sha,
          updatedAtMs: 1795000000000,
          deviceId: 'dev-a',
          deviceName: 'Pixel 9',
          recordCount: 42,
          attachmentFiles: const <String>[],
        );
        final json = head.toJson();
        expect(json['format'], 2);
        expect(
          json['databasePath'],
          'sync/revisions/db_r7_0123456789abcdef.tally',
        );

        final decoded = CloudSyncHead.fromJson(json);
        expect(decoded.format, 2);
        expect(decoded.databasePath, head.databasePath);

        // Legacy format: 1 is detected as legacy and rejected by CloudSyncHead.fromJson
        final legacyJson = Map<String, Object?>.of(json)
          ..['format'] = 1
          ..remove('databasePath');
        expect(isLegacyCloudSyncHeadJson(legacyJson), isTrue);
        expect(
          () => CloudSyncHead.fromJson(legacyJson),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.corruptData,
            ),
          ),
        );

        // Future format > 2 throws upgradeRequired
        final futureJson = Map<String, Object?>.of(json)..['format'] = 3;
        expect(isLegacyCloudSyncHeadJson(futureJson), isFalse);
        expect(
          () => CloudSyncHead.fromJson(futureJson),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.upgradeRequired,
            ),
          ),
        );

        // Path traversal / legacy pointer in databasePath rejected
        for (final badPath in <String>[
          '',
          'sync/latest_db.tally',
          'sync/revisions/../latest_db.tally',
          '../db_r7_0123456789abcdef.tally',
          'sync/revisions/sub/db_r7_0123456789abcdef.tally',
          'sync/revisions/evil.zip',
        ]) {
          final badJson = Map<String, Object?>.of(json)
            ..['databasePath'] = badPath;
          expect(
            () => CloudSyncHead.fromJson(badJson),
            throwsA(
              isA<Failure>().having(
                (f) => f.code,
                'code',
                FailureCode.corruptData,
              ),
            ),
            reason: 'Must reject unsafe databasePath: $badPath',
          );
        }
      },
    );

    test(
      'decideSyncAction routes legacy format: 1 remote head into conflict protection',
      () {
        const localSha =
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
        final conflictOnEmpty = decideSyncAction(
          cursor: const LocalSyncCursor.initial(),
          localDataSha256: localSha,
          isLocalFreshEmpty: true,
          remoteHead: null,
          hasLegacyIncompatibleRemoteHead: true,
          legacyRemoteRevision: 5,
        );
        expect(conflictOnEmpty.action, SyncActionType.conflict);
        expect(conflictOnEmpty.nextRevision, 5);

        final useLocal = decideSyncAction(
          cursor: const LocalSyncCursor.initial(),
          localDataSha256: localSha,
          isLocalFreshEmpty: false,
          remoteHead: null,
          hasLegacyIncompatibleRemoteHead: true,
          legacyRemoteRevision: 5,
          resolution: SyncConflictResolution.useLocal,
        );
        expect(useLocal.action, SyncActionType.pushLocal);
        expect(useLocal.nextRevision, 6);
      },
    );

    test(
      'selectSupersededSyncRevisionFileNames retains Top-5 (current + 4 prior < currentRevision), never touches >= currentRevision, and prunes older ancestors',
      () {
        final remoteFiles = <String>[
          'db_r1_1111111111111111.tally',
          'db_r2_2222222222222222.tally',
          'db_r3_3333333333333333.tally',
          'db_r4_4444444444444444.tally',
          'db_r5_5555555555555555.tally',
          'db_r6_6666666666666666.tally',
          'db_r7_7777777777777777.tally', // concurrent future upload -> NEVER touch!
          'notes.txt',
        ];
        final toDelete = selectSupersededSyncRevisionFileNames(
          remoteFiles,
          currentRevision: 6,
          currentDatabasePath: 'sync/revisions/db_r6_6666666666666666.tally',
        );
        expect(toDelete, <String>['db_r1_1111111111111111.tally']);
      },
    );
  });

  group(
    'S-03 & S-08: Account-scoped targetFingerprint, UTF-8 byte cap, IPv6 SigV4 & WebDAV XML',
    () {
      test(
        'targetFingerprint distinguishes WebDAV username and S3 accessKeyId',
        () {
          const davAlice = WebDavConfig(
            serverUrl: 'https://dav.example.com/remote.php/dav',
            username: 'Alice',
            password: 'pw1',
            remoteDirectory: '/TallyIsle',
          );
          const davBob = WebDavConfig(
            serverUrl: 'https://dav.example.com/remote.php/dav',
            username: 'bob',
            password: 'pw2',
            remoteDirectory: '/TallyIsle',
          );
          expect(davAlice.targetFingerprint, isNot(davBob.targetFingerprint));
          expect(
            davAlice.targetFingerprint,
            const WebDavConfig(
              serverUrl: 'https://dav.example.com/remote.php/dav/',
              username: '  alice ',
              password: 'changed_pw',
              remoteDirectory: 'TallyIsle/',
            ).targetFingerprint,
          );

          const s3Key1 = S3Config(
            endpoint: 'https://s3.example.com',
            region: 'auto',
            bucket: 'tally',
            accessKeyId: 'AKIA_ONE',
            secretAccessKey: 'sec1',
            remotePrefix: 'TallyIsle',
          );
          const s3Key2 = S3Config(
            endpoint: 'https://s3.example.com',
            region: 'auto',
            bucket: 'tally',
            accessKeyId: 'AKIA_TWO',
            secretAccessKey: 'sec2',
            remotePrefix: 'TallyIsle',
          );
          expect(s3Key1.targetFingerprint, isNot(s3Key2.targetFingerprint));
        },
      );

      test(
        'sanitizeAttachmentBasename enforces <= 120 UTF-8 bytes without splitting multi-byte runes and preserves extension',
        () {
          // 60 CJK chars (180 UTF-8 bytes) + 10 4-byte emojis (40 UTF-8 bytes) + .jpeg
          final longName = '${'餐饮发票报销凭证' * 8}${'🧾📸' * 6}.jpeg';
          final clean = sanitizeAttachmentBasename(longName);
          final encoded = utf8.encode(clean);
          expect(encoded.length, lessThanOrEqualTo(120));
          expect(clean, endsWith('.jpeg'));
          // Verify valid UTF-8 round-trip with no U+FFFD replacement characters
          expect(utf8.decode(encoded).contains('\uFFFD'), isFalse);
        },
      );

      test(
        'collision-safe backup and conflict filenames append _2/_3 within same second and preserve conflict retention',
        () {
          final ts = DateTime(2026, 11, 24, 12, 34, 56);
          final bk1 = formatTallyBackupFileName(ts);
          final bk2 = formatTallyBackupFileName(
            ts,
            existingFileNames: <String>[bk1],
          );
          final bk3 = formatTallyBackupFileName(
            ts,
            existingFileNames: <String>[bk1, bk2],
          );
          expect(bk1, 'backup_20261124_123456.tally');
          expect(bk2, 'backup_20261124_123456_2.tally');
          expect(bk3, 'backup_20261124_123456_3.tally');

          final cf1 = formatConflictBackupFileName(
            deviceId: 'dev12345',
            when: ts,
          );
          final cf2 = formatConflictBackupFileName(
            deviceId: 'dev12345',
            when: ts,
            existingFileNames: <String>[cf1],
          );
          expect(cf1, 'conflict_dev12345_20261124_123456.tally');
          expect(cf2, 'conflict_dev12345_20261124_123456_2.tally');
          expect(isConflictBackupFileName(cf1), isTrue);
          expect(isConflictBackupFileName(cf2), isTrue);
        },
      );

      test(
        'resolveS3RequestTarget & signS3Request preserve [::1] brackets on IPv6 loopback endpoints',
        () {
          final target = resolveS3RequestTarget(
            endpoint: 'http://[::1]:9000',
            bucket: 'tally-ipv6',
            objectKey: 'sync/head.json',
            forcePathStyle: true,
          );
          expect(target.hostHeader, '[::1]:9000');
          expect(
            target.requestUri.toString(),
            'http://[::1]:9000/tally-ipv6/sync/head.json',
          );

          final signed = signS3Request(
            method: 'GET',
            target: target,
            accessKeyId: 'AKIA_IPV6',
            secretAccessKey: 'secret_ipv6',
            region: 'auto',
            payloadBytes: Uint8List(0),
            timestampUtc: DateTime.utc(2026, 11, 24, 1, 0, 0),
          );
          expect(signed.canonicalRequest, contains('host:[::1]:9000\n'));
        },
      );

      test(
        'WebDAV PROPFIND parser handles %40/%2B/literal %, 2xx-only propstat, and single-pass XML entity unescaping',
        () {
          expect(
            WebDavClient.unescapeWebDavXml(
              'a &amp;lt; b &amp;amp; &#38; &#x2B; &quot;ok&quot;',
            ),
            'a &lt; b &amp; & + "ok"',
          );

          const propfindXml = '''<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dav/TallyIsle/</d:href>
    <d:propstat>
      <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/TallyIsle/backup_20261124_010203.tally</d:href>
    <d:propstat>
      <d:prop>
        <d:getcontentlength>4096</d:getcontentlength>
        <d:getlastmodified>Tue, 24 Nov 2026 01:02:03 GMT</d:getlastmodified>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
    <d:propstat>
      <d:prop>
        <d:resourcetype><d:collection/></d:resourcetype>
        <d:getcontentlength>999999</d:getcontentlength>
      </d:prop>
      <d:status>HTTP/1.1 404 Not Found</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>''';

          final backups = WebDavClient.parsePropfindBackups(
            propfindXml,
            collectionPath: '/dav/TallyIsle/',
          );
          expect(backups, hasLength(1));
          expect(backups.single.fileName, 'backup_20261124_010203.tally');
          expect(backups.single.sizeBytes, 4096);

          const attPropfindXml = '''<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dav/TallyIsle/sync/attachments/</d:href>
    <d:propstat>
      <d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/TallyIsle/sync/attachments/user%40mail%2B1_100%_off.jpg</d:href>
    <d:propstat>
      <d:prop><d:getcontentlength>128</d:getcontentlength></d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>''';

          final names = WebDavClient.parsePropfindFileNames(
            attPropfindXml,
            collectionPath: '/dav/TallyIsle/sync/attachments/',
          );
          expect(names, <String>{'user@mail+1_100%_off.jpg'});
        },
      );
    },
  );

  group(
    'S-09: isFreshSeedSnapshot detects customized book #1 and preset categories',
    () {
      test(
        'accepts untouched seed tables and rejects book or category customizations',
        () {
          final fresh = _buildDefaultSeedTables();
          expect(isFreshSeedSnapshot(fresh, attachmentCount: 0), isTrue);

          final renamedBook = _buildDefaultSeedTables();
          renamedBook['account_book']!.first['name'] = '我的装修账本';
          expect(isFreshSeedSnapshot(renamedBook, attachmentCount: 0), isFalse);

          final customStartDay = _buildDefaultSeedTables();
          customStartDay['account_book']!.first['start_day'] = 15;
          expect(
            isFreshSeedSnapshot(customStartDay, attachmentCount: 0),
            isFalse,
          );

          final customCover = _buildDefaultSeedTables();
          customCover['account_book']!.first['cover'] = 'travel.png';
          expect(isFreshSeedSnapshot(customCover, attachmentCount: 0), isFalse);

          final hiddenCat = _buildDefaultSeedTables();
          hiddenCat['record_category']!.first['is_hide'] = 1;
          expect(isFreshSeedSnapshot(hiddenCat, attachmentCount: 0), isFalse);

          final renamedCat = _buildDefaultSeedTables();
          renamedCat['record_category']!.first['name'] = '外卖奶茶';
          expect(isFreshSeedSnapshot(renamedCat, attachmentCount: 0), isFalse);

          final extraCat = _buildDefaultSeedTables();
          extraCat['record_category']!.add(<String, Object?>{
            'id': 17,
            'book_id': 1,
            'parent_id': -1,
            'name': '宠物',
            'type': 0,
            'sort': 13,
            'hide': 0,
          });
          expect(isFreshSeedSnapshot(extraCat, attachmentCount: 0), isFalse);
        },
      );
    },
  );

  group(
    'Extreme-Scale Hardening: Revision Bound, Natural Sort, Backoff, GC & O(1) Zip',
    () {
      test(
        'enforces maxSafeCloudSyncRevision (2^53 - 1) and natural numeric ordering for _10.tally > _9.tally > base',
        () {
          final maxPath = buildCloudSyncRevisionPath(
            revision: maxSafeCloudSyncRevision,
            dataSha256: 'a' * 64,
          );
          final parsedMax = parseSyncRevisionFileName(maxPath.split('/').last);
          expect(parsedMax?.revision, maxSafeCloudSyncRevision);

          expect(
            () => buildCloudSyncRevisionPath(
              revision: maxSafeCloudSyncRevision + 1,
              dataSha256: 'a' * 64,
            ),
            throwsA(isA<Failure>()),
          );
          expect(
            parseSyncRevisionFileName(
              'db_r9999999999999999999999999999_aaaaaaaaaaaaaaaa.tally',
            ),
            isNull,
          );

          final names = <String>[
            'backup_20261127_120000.tally',
            'backup_20261127_120000_2.tally',
            'backup_20261127_120000_9.tally',
            'backup_20261127_120000_10.tally',
            'backup_20261127_120000_12.tally',
          ];
          final sorted = [...names]..sort(compareBackupFileNamesNewestFirst);
          expect(sorted, <String>[
            'backup_20261127_120000_12.tally',
            'backup_20261127_120000_10.tally',
            'backup_20261127_120000_9.tally',
            'backup_20261127_120000_2.tally',
            'backup_20261127_120000.tally',
          ]);
        },
      );

      test(
        'auto-upgrades legacy 帐屿本机 device name to platform-labelled short4 and evaluates exponential backoff vs auth circuit breaker',
        () {
          final upgraded = resolveEffectiveCloudSyncSettings(
            rawJson: jsonEncode(<String, Object>{
              'backend': 's3',
              'deviceId': '89ab1234-5678-4000-8000-000000000000',
              'deviceName': '帐屿本机',
            }),
            isWebDavConfigured: false,
            fallbackDeviceId: '89ab1234-5678-4000-8000-000000000000',
            fallbackDeviceName: 'Windows (89ab)',
          );
          expect(upgraded.deviceName, 'Windows (89ab)');

          // 1. RequestTimeTooSkewed -> transient backoff (NOT permanent circuit open!)
          final skewState = evaluateSyncFailureBackoff(
            previous: SyncBackoffState.healthy,
            failure: const Failure(
              FailureCode.authRequired,
              'S3 请求时钟偏差过大（RequestTimeTooSkewed）',
            ),
            nowMs: 1000,
            jitterPermille: 0,
          );
          expect(skewState.isAuthCircuitOpen, isFalse);
          expect(skewState.nextRetryAtMs, 31000);

          // 2. 429 with Retry-After -> honors Retry-After > base delay
          final rateLimitState = evaluateSyncFailureBackoff(
            previous: SyncBackoffState.healthy,
            failure: const Failure(
              FailureCode.remoteUnavailable,
              'WebDAV 请求过于频繁（429）',
              retryAfterMs: 120000,
            ),
            nowMs: 1000,
            retryAfterMs: 120000,
            jitterPermille: 0,
          );
          expect(rateLimitState.isAuthCircuitOpen, isFalse);
          expect(rateLimitState.nextRetryAtMs, 121000);

          // 3. First generic 403 -> 30s backoff; 2nd consecutive 403 -> opens circuit!
          final first403 = evaluateSyncFailureBackoff(
            previous: SyncBackoffState.healthy,
            failure: const Failure(
              FailureCode.authRequired,
              'WebDAV 访问被拒绝（403）',
            ),
            nowMs: 5000,
          );
          expect(first403.isAuthCircuitOpen, isFalse);
          final second403 = evaluateSyncFailureBackoff(
            previous: first403,
            failure: const Failure(
              FailureCode.authRequired,
              'WebDAV 访问被拒绝（403）',
            ),
            nowMs: 40000,
          );
          expect(second403.isAuthCircuitOpen, isTrue);

          // 4. Explicit 401 -> immediate circuit open!
          final auth401 = evaluateSyncFailureBackoff(
            previous: SyncBackoffState.healthy,
            failure: const Failure(
              FailureCode.authRequired,
              'WebDAV 鉴权失败（401）',
            ),
            nowMs: 5000,
          );
          expect(auth401.isAuthCircuitOpen, isTrue);
        },
      );

      test(
        'evaluateAttachmentGarbageCollection enforces 30-day grace + minRetainedRevision + ConflictAttachmentRefLock protection + O(1) Zip readSingleEntryFromBytes',
        () {
          final shaA = 'a' * 64;
          final shaB = 'b' * 64;
          final shaC = 'c' * 64;
          final objA = '${shaA}__live.jpg';
          final objB = '${shaB}__conflict_locked.jpg';
          final objC = '${shaC}__unreferenced.jpg';
          const t0 = 1700000000000;

          // Pass 1: objC first observed unreferenced at rev 5 -> enters gc_pending, NOT deleted!
          final pass1 = evaluateAttachmentGarbageCollection(
            existingRemoteAttachments: <String, int?>{
              objA: t0 - 90000000,
              objB: t0 - 90000000,
              objC: t0 - 90000000,
            },
            referencedObjectNames: <String>{objA, objB},
            previousPending: const <String, GcPendingEntry>{},
            currentRevision: 5,
            minRetainedRevision: 2,
            nowMs: t0,
          );
          expect(pass1.toDelete, isEmpty);
          expect(pass1.nextPending.keys, <String>[objC]);

          // Pass 2: 31 days later, BUT minRetainedRevision is still 5 (<= 5) -> still kept!
          const t31d = t0 + 31 * 24 * 60 * 60 * 1000;
          final pass2 = evaluateAttachmentGarbageCollection(
            existingRemoteAttachments: <String, int?>{
              objA: t0 - 90000000,
              objB: t0 - 90000000,
              objC: t0 - 90000000,
            },
            referencedObjectNames: <String>{objA, objB},
            previousPending: pass1.nextPending,
            currentRevision: 8,
            minRetainedRevision: 5,
            nowMs: t31d,
          );
          expect(pass2.toDelete, isEmpty);

          // Pass 3: 31 days later AND minRetainedRevision advanced to 6 (> 5) -> objC deleted, objB protected!
          final pass3 = evaluateAttachmentGarbageCollection(
            existingRemoteAttachments: <String, int?>{
              objA: t0 - 90000000,
              objB: t0 - 90000000,
              objC: t0 - 90000000,
            },
            referencedObjectNames: <String>{objA, objB},
            previousPending: pass2.nextPending,
            currentRevision: 10,
            minRetainedRevision: 6,
            nowMs: t31d,
          );
          expect(pass3.toDelete, <String>[objC]);

          // O(1) ZipArchive.readSingleEntryFromBytes reads manifest.json without decoding database/attachments!
          final packed = packTallyArchive(
            tables: _buildDefaultSeedTables(),
            attachments: <String, Uint8List>{
              'attachments/big.bin': Uint8List(4096),
            },
            createdAtMs: t0,
            appVersion: '0.11.0',
            includeAttachments: true,
          );
          final rawManifestBytes = ZipArchive.readSingleEntryFromBytes(
            packed.bytes,
            tallyManifestFileName,
          );
          expect(rawManifestBytes, isNotNull);
          final onlyManifest = extractTallyManifestOnly(packed.bytes);
          expect(onlyManifest.createdAtMs, t0);
          expect(onlyManifest.attachmentCount, 1);
        },
      );
    },
  );
}
