import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/domain/rules/cloud_sync_rules.dart';
import 'package:tallyisle/domain/rules/s3_sigv4_rules.dart';
import 'package:tallyisle/domain/rules/tally_backup.dart';

void main() {
  group('AWS Signature Version 4 (R1) golden vectors & target resolution', () {
    test(
      'matches official AWS S3 SigV4 GET Object golden vector byte-for-byte',
      () {
        final target = resolveS3RequestTarget(
          endpoint: 'https://s3.amazonaws.com',
          bucket: 'examplebucket',
          objectKey: 'test.txt',
          forcePathStyle: false,
        );
        expect(target.hostHeader, 'examplebucket.s3.amazonaws.com');
        expect(target.canonicalUri, '/test.txt');
        expect(target.canonicalQueryString, '');

        final signed = signS3Request(
          method: 'GET',
          target: target,
          accessKeyId: 'AKIAIOSFODNN7EXAMPLE',
          secretAccessKey: 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY',
          region: 'us-east-1',
          timestampUtc: DateTime.utc(2013, 5, 24, 0, 0, 0),
          extraHeaders: const <String, String>{'Range': 'bytes=0-9'},
        );

        expect(signed.payloadSha256, s3EmptyPayloadSha256);
        expect(signed.amzDate, '20130524T000000Z');
        expect(signed.dateStamp, '20130524');
        expect(
          signed.signature,
          'f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41',
        );
        expect(
          signed.authorization,
          'AWS4-HMAC-SHA256 '
          'Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, '
          'SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, '
          'Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41',
        );
      },
    );

    test(
      'encodes UTF-8 paths/spaces, sorts query strings, and resolves path-style vs virtual-hosted ports',
      () {
        expect(
          s3UriEncode('餐饮 小票~1_a-b.jpg', encodeSlash: true),
          '%E9%A4%90%E9%A5%AE%20%E5%B0%8F%E7%A5%A8~1_a-b.jpg',
        );
        expect(s3UriEncode('a/b c', encodeSlash: false), 'a/b%20c');

        final query = buildCanonicalQueryString(const <String, String>{
          'prefix': 'TallyIsle/sync/',
          'list-type': '2',
          'continuation-token': 'tok+1/2=',
        });
        expect(
          query,
          'continuation-token=tok%2B1%2F2%3D&list-type=2&prefix=TallyIsle%2Fsync%2F',
        );

        // Path-style with custom MinIO port :9000
        final minioTarget = resolveS3RequestTarget(
          endpoint: 'http://127.0.0.1:9000',
          bucket: 'tally-bucket',
          objectKey: 'TallyIsle/sync/attachments/abc__餐饮 1.jpg',
          forcePathStyle: true,
        );
        expect(minioTarget.hostHeader, '127.0.0.1:9000');
        expect(minioTarget.requestUri.path, minioTarget.canonicalUri);
        expect(
          minioTarget.canonicalUri,
          '/tally-bucket/TallyIsle/sync/attachments/abc__%E9%A4%90%E9%A5%AE%201.jpg',
        );

        // Virtual-hosted when endpoint already includes bucket prefix (e.g. OSS/COS user input)
        final ossTarget = resolveS3RequestTarget(
          endpoint: 'https://my-bucket.oss-cn-hangzhou.aliyuncs.com',
          bucket: 'my-bucket',
          objectKey: 'TallyIsle/sync/head.json',
          forcePathStyle: false,
        );
        expect(ossTarget.hostHeader, 'my-bucket.oss-cn-hangzhou.aliyuncs.com');
        expect(ossTarget.canonicalUri, '/TallyIsle/sync/head.json');

        // Rejects path traversal in prefix or object key
        expect(
          () => normalizeS3Prefix('../escape'),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.validation,
            ),
          ),
        );
      },
    );

    test(
      'parses ListObjectsV2 XML with pagination and XML entity unescaping',
      () {
        const xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
  <Name>tally-bucket</Name>
  <Prefix>TallyIsle/</Prefix>
  <IsTruncated>true</IsTruncated>
  <NextContinuationToken>next-page-token-&amp;-2</NextContinuationToken>
  <Contents>
    <Key>TallyIsle/backup_20261111_120000.tally</Key>
    <LastModified>2026-11-11T12:00:00.000Z</LastModified>
    <ETag>"9a8b7c6d"</ETag>
    <Size>4096</Size>
  </Contents>
  <Contents>
    <Key>TallyIsle/sync/attachments/0123__a&amp;b.jpg</Key>
    <LastModified>2026-11-11T12:05:00.000Z</LastModified>
    <Size>1024</Size>
  </Contents>
</ListBucketResult>
''';
        final page = parseS3ListObjectsV2Xml(xml);
        expect(page.isTruncated, isTrue);
        expect(page.nextContinuationToken, 'next-page-token-&-2');
        expect(page.objects, hasLength(2));
        expect(page.objects[0].key, 'TallyIsle/backup_20261111_120000.tally');
        expect(page.objects[0].sizeBytes, 4096);
        expect(page.objects[0].etag, '9a8b7c6d');
        expect(
          page.objects[0].lastModifiedMs,
          DateTime.utc(2026, 11, 11, 12, 0, 0).millisecondsSinceEpoch,
        );
        expect(page.objects[1].key, 'TallyIsle/sync/attachments/0123__a&b.jpg');
      },
    );
  });

  group('Canonical dataSha256 & Cloud Sync State Machine (R2, R4, R5, R6)', () {
    test(
      'computeCanonicalSyncDataSha256 is invariant across Manifest timestamps and key insertion order',
      () {
        final tablesA = <String, List<Map<String, Object?>>>{
          'record': <Map<String, Object?>>[
            <String, Object?>{'record_id': 'r1', 'money_minor': 1250},
          ],
          'account_book': <Map<String, Object?>>[
            <String, Object?>{'id': 1, 'name': '日常账本', 'create_date': 1000},
          ],
        };
        final tablesB = <String, List<Map<String, Object?>>>{
          'account_book': <Map<String, Object?>>[
            <String, Object?>{'id': 1, 'name': '日常账本', 'create_date': 1000},
          ],
          'record': <Map<String, Object?>>[
            <String, Object?>{'record_id': 'r1', 'money_minor': 1250},
          ],
        };
        final attBytes = Uint8List.fromList(utf8.encode('receipt-bytes'));
        final attSha = sha256Hex(attBytes);

        // Packing at two different createdAtMs changes .tally ZIP bytes,
        // while canonical sync dataSha256 MUST stay 100% identical!
        final packEarly = packTallyArchive(
          tables: tablesA,
          attachments: <String, Uint8List>{'receipt.jpg': attBytes},
          createdAtMs: 1793952000000,
        );
        final packLate = packTallyArchive(
          tables: tablesB,
          attachments: <String, Uint8List>{'receipt.jpg': attBytes},
          createdAtMs: 1794038400000,
        );
        expect(
          packEarly.manifest.createdAtMs,
          isNot(packLate.manifest.createdAtMs),
        );

        final sha1 = computeCanonicalSyncDataSha256(
          tables: tablesA,
          attachmentChecksums: <String, String>{'receipt.jpg': attSha},
        );
        final sha2 = computeCanonicalSyncDataSha256(
          tables: tablesB,
          attachmentChecksums: <String, String>{
            'attachments/receipt.jpg': attSha.toUpperCase(),
          },
        );
        expect(sha1, sha2);

        // Mutating an attachment hash changes canonical dataSha256
        final shaOtherAtt = computeCanonicalSyncDataSha256(
          tables: tablesA,
          attachmentChecksums: <String, String>{
            'receipt.jpg': sha256Hex(const <int>[9, 9, 9]),
          },
        );
        expect(shaOtherAtt, isNot(sha1));
      },
    );

    test(
      'resolveEffectiveCloudSyncSettings seamlessly recognizes legacy WebDavConfig and honors explicit none',
      () {
        final freshUnconfigured = resolveEffectiveCloudSyncSettings(
          rawJson: null,
          isWebDavConfigured: false,
          fallbackDeviceId: 'dev-1',
        );
        expect(freshUnconfigured.backend, CloudBackendType.none);
        expect(freshUnconfigured.autoSyncEnabled, isFalse);

        final legacyWebDav = resolveEffectiveCloudSyncSettings(
          rawJson: null,
          isWebDavConfigured: true,
          fallbackDeviceId: 'dev-1',
        );
        expect(legacyWebDav.backend, CloudBackendType.webdav);

        final explicitDisabled = resolveEffectiveCloudSyncSettings(
          rawJson: jsonEncode(
            const CloudSyncSettings(
              backend: CloudBackendType.none,
              explicitBackend: true,
              deviceId: 'dev-1',
            ).toJson(),
          ),
          isWebDavConfigured: true,
          fallbackDeviceId: 'dev-1',
        );
        expect(explicitDisabled.backend, CloudBackendType.none);
      },
    );

    test(
      'formatConflictBackupFileName & selectNonConflictBackupsToPrune protect conflict snapshots (R6)',
      () {
        final devId = generateSyncDeviceId(Random(42));
        expect(devId, matches(RegExp(r'^[0-9a-f-]{36}$')));

        final conflictName = formatConflictBackupFileName(
          deviceId: 'a1b2c3d4-e5f6-4789-8000-112233445566',
          when: DateTime(2026, 11, 11, 17, 30, 5),
        );
        expect(conflictName, 'conflict_a1b2c3d4_20261111_173005.tally');
        expect(isConflictBackupFileName(conflictName), isTrue);

        final toPrune = selectNonConflictBackupsToPrune(<BackupRetentionItem>[
          BackupRetentionItem(fileName: conflictName, modifiedAtMs: 100),
          const BackupRetentionItem(
            fileName: 'backup_20261101_120000.tally',
            modifiedAtMs: 200,
          ),
          const BackupRetentionItem(
            fileName: 'backup_20261102_120000.tally',
            modifiedAtMs: 300,
          ),
          const BackupRetentionItem(
            fileName: 'backup_20261103_120000.tally',
            modifiedAtMs: 400,
          ),
        ], keepCount: 2);

        // Oldest routine backup pruned; even older conflict_* snapshot untouched!
        expect(toPrune, <String>['backup_20261101_120000.tally']);
      },
    );

    test(
      'decideSyncAction covers pull, push, conflict, fast-forward, and explicit resolution',
      () {
        final shaA = 'a' * 64;
        final shaB = 'b' * 64;
        final shaC = 'c' * 64;

        CloudSyncHead makeHead(int rev, String sha) => CloudSyncHead(
          revision: rev,
          dataSha256: sha,
          updatedAtMs: 1793952000000,
          deviceId: 'dev-remote',
          deviceName: 'Pixel',
          recordCount: 5,
          attachmentFiles: const <String>[],
        );

        // 1. Remote head missing -> push revision 1
        final initPush = decideSyncAction(
          cursor: const LocalSyncCursor.initial(),
          localDataSha256: shaA,
          isLocalFreshEmpty: false,
          remoteHead: null,
        );
        expect(initPush.action, SyncActionType.pushLocal);
        expect(initPush.nextRevision, 1);

        // 2. Brand-new empty device joining populated cloud -> pull
        final freshPull = decideSyncAction(
          cursor: const LocalSyncCursor.initial(),
          localDataSha256: shaA,
          isLocalFreshEmpty: true,
          remoteHead: makeHead(3, shaB),
        );
        expect(freshPull.action, SyncActionType.pullRemote);

        // 3. Unsynced device that ALREADY has local user data joining different cloud -> conflict!
        final unsyncedConflict = decideSyncAction(
          cursor: const LocalSyncCursor.initial(),
          localDataSha256: shaA,
          isLocalFreshEmpty: false,
          remoteHead: makeHead(3, shaB),
        );
        expect(unsyncedConflict.action, SyncActionType.conflict);

        // 4. Synced at rev 2 (shaA), remote advances to rev 3 (shaB), local unchanged -> pull
        final syncedCursor = LocalSyncCursor(
          lastSyncedRevision: 2,
          lastSyncedDataSha256: shaA,
          lastSyncedAtMs: 1000,
        );
        expect(
          decideSyncAction(
            cursor: syncedCursor,
            localDataSha256: shaA,
            isLocalFreshEmpty: false,
            remoteHead: makeHead(3, shaB),
          ).action,
          SyncActionType.pullRemote,
        );

        // 5. Synced at rev 2 (shaA), local edited (shaC), remote still rev 2 (shaA) -> push rev 3
        final normalPush = decideSyncAction(
          cursor: syncedCursor,
          localDataSha256: shaC,
          isLocalFreshEmpty: false,
          remoteHead: makeHead(2, shaA),
        );
        expect(normalPush.action, SyncActionType.pushLocal);
        expect(normalPush.nextRevision, 3);

        // 6. Both local (shaC) and remote (rev 3, shaB) changed -> conflict!
        expect(
          decideSyncAction(
            cursor: syncedCursor,
            localDataSha256: shaC,
            isLocalFreshEmpty: false,
            remoteHead: makeHead(3, shaB),
          ).action,
          SyncActionType.conflict,
        );

        // 7. Explicit resolutions override conflict cleanly
        expect(
          decideSyncAction(
            cursor: syncedCursor,
            localDataSha256: shaC,
            isLocalFreshEmpty: false,
            remoteHead: makeHead(3, shaB),
            resolution: SyncConflictResolution.useRemote,
          ).action,
          SyncActionType.pullRemote,
        );
        final resolveLocal = decideSyncAction(
          cursor: syncedCursor,
          localDataSha256: shaC,
          isLocalFreshEmpty: false,
          remoteHead: makeHead(3, shaB),
          resolution: SyncConflictResolution.useLocal,
        );
        expect(resolveLocal.action, SyncActionType.pushLocal);
        expect(resolveLocal.nextRevision, 4);

        // 8. Same dataSha256 on both sides -> fastForwardCursor or noOp
        expect(
          decideSyncAction(
            cursor: const LocalSyncCursor.initial(),
            localDataSha256: shaB,
            isLocalFreshEmpty: false,
            remoteHead: makeHead(3, shaB),
          ).action,
          SyncActionType.fastForwardCursor,
        );
        expect(
          decideSyncAction(
            cursor: LocalSyncCursor(
              lastSyncedRevision: 3,
              lastSyncedDataSha256: shaB,
            ),
            localDataSha256: shaB,
            isLocalFreshEmpty: false,
            remoteHead: makeHead(3, shaB),
          ).action,
          SyncActionType.noOp,
        );
      },
    );
  });

  group('LocalAutoBackupPolicy & Upgraded CloudSyncSettings Trigger Rules', () {
    test(
      'LocalAutoBackupPolicy defaults all triggers to false, clamps intervals/keepCount, and round-trips JSON',
      () {
        const defaults = LocalAutoBackupPolicy();
        expect(defaults.backupOnStartup, isFalse);
        expect(defaults.backupOnExit, isFalse);
        expect(defaults.backupOnIdle, isFalse);
        expect(defaults.idleMinutes, 5);
        expect(defaults.backupOnSchedule, isFalse);
        expect(defaults.scheduleIntervalMinutes, 360);
        expect(defaults.keepCount, 10);
        expect(defaults.hasAnyTrigger, isFalse);

        // Corrupt or null JSON resolves safely to all-false defaults
        expect(resolveLocalAutoBackupPolicy(null), defaults);
        expect(resolveLocalAutoBackupPolicy('{not-valid-json'), defaults);

        // Bounds clamping: idleMinutes 1..1440, schedule 5..10080, keepCount 1..200
        const clampedLow = LocalAutoBackupPolicy(
          idleMinutes: 0,
          scheduleIntervalMinutes: 1,
          keepCount: -5,
        );
        expect(clampedLow.idleMinutes, 1);
        expect(clampedLow.scheduleIntervalMinutes, 5);
        expect(clampedLow.keepCount, 1);

        const clampedHigh = LocalAutoBackupPolicy(
          idleMinutes: 99999,
          scheduleIntervalMinutes: 99999,
          keepCount: 500,
        );
        expect(clampedHigh.idleMinutes, 1440);
        expect(clampedHigh.scheduleIntervalMinutes, 10080);
        expect(clampedHigh.keepCount, 200);

        final custom = defaults.copyWith(
          backupOnStartup: true,
          backupOnIdle: true,
          idleMinutes: 15,
          backupOnSchedule: true,
          scheduleIntervalMinutes: 720,
          keepCount: 20,
        );
        expect(custom.hasAnyTrigger, isTrue);
        final roundTripped = resolveLocalAutoBackupPolicy(
          jsonEncode(custom.toJson()),
        );
        expect(roundTripped, custom);
      },
    );

    test(
      'CloudSyncSettings defaults all 4 triggers to false, migrates legacy auto_sync_enabled, and round-trips JSON',
      () {
        const fresh = CloudSyncSettings(deviceId: 'dev-fresh');
        expect(fresh.syncOnStartup, isFalse);
        expect(fresh.syncOnExit, isFalse);
        expect(fresh.syncOnIdle, isFalse);
        expect(fresh.idleMinutes, 3);
        expect(fresh.syncOnSchedule, isFalse);
        expect(fresh.scheduleIntervalMinutes, 60);
        expect(fresh.autoSyncEnabled, isFalse);

        // Constructor legacy compatibility: autoSyncEnabled: true without explicit triggers
        const legacyCtor = CloudSyncSettings(
          backend: CloudBackendType.s3,
          autoSyncEnabled: true,
          deviceId: 'dev-ctor',
        );
        expect(legacyCtor.syncOnStartup, isTrue);
        expect(legacyCtor.syncOnExit, isTrue);
        expect(legacyCtor.syncOnIdle, isFalse);
        expect(legacyCtor.syncOnSchedule, isFalse);
        expect(legacyCtor.autoSyncEnabled, isTrue);

        // JSON legacy migration: {"auto_sync_enabled": true} without sync_on_* keys
        final migratedTrue = CloudSyncSettings.fromJson(const <String, Object?>{
          'backend': 'webdav',
          'explicit_backend': true,
          'auto_sync_enabled': true,
          'device_id': 'dev-legacy',
        }, fallbackDeviceId: 'fallback');
        expect(migratedTrue.syncOnStartup, isTrue);
        expect(migratedTrue.syncOnExit, isTrue);
        expect(migratedTrue.syncOnIdle, isFalse);
        expect(migratedTrue.syncOnSchedule, isFalse);
        expect(migratedTrue.autoSyncEnabled, isTrue);

        // JSON legacy migration: {"auto_sync_enabled": false} keeps all 4 false
        final migratedFalse = CloudSyncSettings.fromJson(
          const <String, Object?>{
            'backend': 'webdav',
            'auto_sync_enabled': false,
          },
          fallbackDeviceId: 'dev-legacy-off',
        );
        expect(migratedFalse.autoSyncEnabled, isFalse);
        expect(migratedFalse.syncOnStartup, isFalse);
        expect(migratedFalse.syncOnExit, isFalse);

        // Fine-grained single trigger (e.g. only syncOnIdle: true)
        final idleOnly = fresh.copyWith(
          backend: CloudBackendType.s3,
          explicitBackend: true,
          syncOnIdle: true,
          idleMinutes: 10,
          scheduleIntervalMinutes: 15,
        );
        expect(idleOnly.autoSyncEnabled, isTrue);
        expect(idleOnly.syncOnStartup, isFalse);
        expect(idleOnly.syncOnExit, isFalse);
        expect(idleOnly.syncOnIdle, isTrue);
        expect(idleOnly.idleMinutes, 10);

        final parsedIdleOnly = CloudSyncSettings.fromJson(
          idleOnly.toJson(),
          fallbackDeviceId: 'fallback',
        );
        expect(parsedIdleOnly, idleOnly);

        // Turning master autoSyncEnabled: false clears all 4 triggers
        final cleared = idleOnly.copyWith(autoSyncEnabled: false);
        expect(cleared.autoSyncEnabled, isFalse);
        expect(cleared.syncOnStartup, isFalse);
        expect(cleared.syncOnExit, isFalse);
        expect(cleared.syncOnIdle, isFalse);
        expect(cleared.syncOnSchedule, isFalse);
      },
    );

    test(
      'shouldRunLocalAutoBackupForTrigger & shouldRunCloudAutoSyncForTrigger evaluate all 5 AutoTriggerSource modes',
      () {
        const localPolicy = LocalAutoBackupPolicy(
          backupOnStartup: true,
          backupOnExit: false,
          backupOnIdle: true,
          idleMinutes: 5,
          backupOnSchedule: true,
          scheduleIntervalMinutes: 60,
          keepCount: 5,
        );

        // Local startup/windowFocus requires localDataChanged == true
        expect(
          shouldRunLocalAutoBackupForTrigger(
            policy: localPolicy,
            source: AutoTriggerSource.startup,
            localDataChanged: false,
            lastAutoBackupAtMs: null,
            nowMs: 100000,
          ),
          isFalse,
        );
        expect(
          shouldRunLocalAutoBackupForTrigger(
            policy: localPolicy,
            source: AutoTriggerSource.windowFocus,
            localDataChanged: true,
            lastAutoBackupAtMs: null,
            nowMs: 100000,
          ),
          isTrue,
        );
        // backupOnExit is false
        expect(
          shouldRunLocalAutoBackupForTrigger(
            policy: localPolicy,
            source: AutoTriggerSource.exit,
            localDataChanged: true,
            lastAutoBackupAtMs: null,
            nowMs: 100000,
          ),
          isFalse,
        );
        // schedule throttled until 60m (3,600,000 ms) elapsed
        expect(
          shouldRunLocalAutoBackupForTrigger(
            policy: localPolicy,
            source: AutoTriggerSource.schedule,
            localDataChanged: true,
            lastAutoBackupAtMs: 100000,
            nowMs: 100000 + 59 * 60 * 1000,
          ),
          isFalse,
        );
        expect(
          shouldRunLocalAutoBackupForTrigger(
            policy: localPolicy,
            source: AutoTriggerSource.schedule,
            localDataChanged: true,
            lastAutoBackupAtMs: 100000,
            nowMs: 100000 + 60 * 60 * 1000,
          ),
          isTrue,
        );

        const cloudSettings = CloudSyncSettings(
          backend: CloudBackendType.s3,
          explicitBackend: true,
          syncOnStartup: true,
          syncOnExit: false,
          syncOnIdle: true,
          idleMinutes: 3,
          syncOnSchedule: true,
          scheduleIntervalMinutes: 30,
          deviceId: 'dev-elig',
        );
        expect(
          shouldRunCloudAutoSyncForTrigger(
            settings: cloudSettings,
            isBackendConfigured: false,
            source: AutoTriggerSource.startup,
            lastScheduleCheckAtMs: null,
            nowMs: 50000,
          ),
          isFalse,
        );
        expect(
          shouldRunCloudAutoSyncForTrigger(
            settings: cloudSettings,
            isBackendConfigured: true,
            source: AutoTriggerSource.windowFocus,
            lastScheduleCheckAtMs: null,
            nowMs: 50000,
          ),
          isTrue,
        );
        expect(
          shouldRunCloudAutoSyncForTrigger(
            settings: cloudSettings,
            isBackendConfigured: true,
            source: AutoTriggerSource.exit,
            lastScheduleCheckAtMs: null,
            nowMs: 50000,
          ),
          isFalse,
        );
        expect(
          shouldRunCloudAutoSyncForTrigger(
            settings: cloudSettings,
            isBackendConfigured: true,
            source: AutoTriggerSource.schedule,
            lastScheduleCheckAtMs: 50000,
            nowMs: 50000 + 29 * 60 * 1000,
          ),
          isFalse,
        );
        expect(
          shouldRunCloudAutoSyncForTrigger(
            settings: cloudSettings,
            isBackendConfigured: true,
            source: AutoTriggerSource.schedule,
            lastScheduleCheckAtMs: 50000,
            nowMs: 50000 + 30 * 60 * 1000,
          ),
          isTrue,
        );
      },
    );
  });
}
