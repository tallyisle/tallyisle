import 'dart:convert';
import 'dart:math';

import '../../core/failure.dart';
import 'tally_backup.dart';

const int cloudSyncFormatVersion = 1;
const String cloudSyncHeadPath = 'sync/head.json';
const String cloudSyncLatestDbPath = 'sync/latest_db.tally';
const String cloudSyncAttachmentsDir = 'sync/attachments';

const String prefKeyCloudSyncSettings = 'cloud_sync_settings';
const String prefKeyCloudSyncCursor = 'cloud_sync_cursor';
const String prefKeyS3Config = 'backup_s3_config';

final RegExp _hex64LowerOrUpper = RegExp(r'^[0-9a-fA-F]{64}$');

/// Active cloud synchronization & backup channel.
enum CloudBackendType {
  none('none', '未启用'),
  webdav('webdav', 'WebDAV'),
  s3('s3', 'S3 对象存储');

  const CloudBackendType(this.wireValue, this.displayLabel);

  final String wireValue;
  final String displayLabel;

  static CloudBackendType fromWire(String? raw) {
    return switch (raw?.trim().toLowerCase()) {
      'webdav' => CloudBackendType.webdav,
      's3' => CloudBackendType.s3,
      _ => CloudBackendType.none,
    };
  }
}

/// User-selected multi-device sync preferences stored in `ti_preference`
/// (`cloud_sync_settings`).
final class CloudSyncSettings {
  const CloudSyncSettings({
    this.backend = CloudBackendType.none,
    this.explicitBackend = false,
    this.autoSyncEnabled = false,
    this.autoArchiveBackupEnabled = true,
    required this.deviceId,
    this.deviceName = '帐屿本机',
  });

  final CloudBackendType backend;
  final bool explicitBackend;
  final bool autoSyncEnabled;
  final bool autoArchiveBackupEnabled;
  final String deviceId;
  final String deviceName;

  CloudSyncSettings copyWith({
    CloudBackendType? backend,
    bool? explicitBackend,
    bool? autoSyncEnabled,
    bool? autoArchiveBackupEnabled,
    String? deviceId,
    String? deviceName,
  }) => CloudSyncSettings(
    backend: backend ?? this.backend,
    explicitBackend: explicitBackend ?? this.explicitBackend,
    autoSyncEnabled: autoSyncEnabled ?? this.autoSyncEnabled,
    autoArchiveBackupEnabled:
        autoArchiveBackupEnabled ?? this.autoArchiveBackupEnabled,
    deviceId: deviceId ?? this.deviceId,
    deviceName: deviceName ?? this.deviceName,
  );

  Map<String, Object> toJson() => <String, Object>{
    'backend': backend.wireValue,
    'explicit_backend': explicitBackend,
    'auto_sync_enabled': autoSyncEnabled,
    'auto_archive_backup_enabled': autoArchiveBackupEnabled,
    'device_id': deviceId,
    'device_name': deviceName.trim().isEmpty ? '帐屿本机' : deviceName.trim(),
  };

  factory CloudSyncSettings.fromJson(
    Map<String, Object?> json, {
    required String fallbackDeviceId,
    String fallbackDeviceName = '帐屿本机',
  }) {
    final rawDeviceId = (json['device_id'] as String?)?.trim() ?? '';
    final rawDeviceName = (json['device_name'] as String?)?.trim() ?? '';
    return CloudSyncSettings(
      backend: CloudBackendType.fromWire(json['backend'] as String?),
      explicitBackend: (json['explicit_backend'] as bool?) ?? false,
      autoSyncEnabled: (json['auto_sync_enabled'] as bool?) ?? false,
      autoArchiveBackupEnabled:
          (json['auto_archive_backup_enabled'] as bool?) ?? true,
      deviceId: rawDeviceId.isEmpty ? fallbackDeviceId : rawDeviceId,
      deviceName: rawDeviceName.isEmpty ? fallbackDeviceName : rawDeviceName,
    );
  }
}

/// Resolves effective [CloudSyncSettings], seamlessly recognizing legacy
/// [isWebDavConfigured] setups when `cloud_sync_settings` has not been
/// explicitly set yet.
CloudSyncSettings resolveEffectiveCloudSyncSettings({
  required String? rawJson,
  required bool isWebDavConfigured,
  required String fallbackDeviceId,
  String fallbackDeviceName = '帐屿本机',
}) {
  if (rawJson == null || rawJson.trim().isEmpty) {
    return CloudSyncSettings(
      backend: isWebDavConfigured
          ? CloudBackendType.webdav
          : CloudBackendType.none,
      explicitBackend: false,
      deviceId: fallbackDeviceId,
      deviceName: fallbackDeviceName,
    );
  }
  try {
    final decoded = jsonDecode(rawJson);
    if (decoded is Map<String, Object?>) {
      final parsed = CloudSyncSettings.fromJson(
        decoded,
        fallbackDeviceId: fallbackDeviceId,
        fallbackDeviceName: fallbackDeviceName,
      );
      if (!parsed.explicitBackend &&
          parsed.backend == CloudBackendType.none &&
          isWebDavConfigured) {
        return parsed.copyWith(backend: CloudBackendType.webdav);
      }
      return parsed;
    }
  } catch (_) {
    // Fall back to safe defaults below on corrupted preference JSON.
  }
  return CloudSyncSettings(
    backend: isWebDavConfigured
        ? CloudBackendType.webdav
        : CloudBackendType.none,
    explicitBackend: false,
    deviceId: fallbackDeviceId,
    deviceName: fallbackDeviceName,
  );
}

/// Generates a persistent RFC-4122 v4 UUID for device identification.
String generateSyncDeviceId([Random? rng]) {
  Random random;
  if (rng != null) {
    random = rng;
  } else {
    try {
      random = Random.secure();
    } catch (_) {
      random = Random();
    }
  }
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0F) | 0x40;
  bytes[8] = (bytes[8] & 0x3F) | 0x80;

  String hexRange(int start, int end) => [
    for (var i = start; i < end; i++)
      bytes[i].toRadixString(16).padLeft(2, '0'),
  ].join();

  return '${hexRange(0, 4)}-${hexRange(4, 6)}-${hexRange(6, 8)}-'
      '${hexRange(8, 10)}-${hexRange(10, 16)}';
}

/// Extracts an 8-char lowercase alphanumeric prefix of [deviceId] for conflict filenames.
String shortDeviceId(String deviceId) {
  final alnum = deviceId
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]'), '')
      .trim();
  if (alnum.isEmpty) return 'device00';
  return alnum.length <= 8 ? alnum : alnum.substring(0, 8);
}

/// Formats a zero-data-loss conflict snapshot filename:
/// `conflict_<deviceIdShort>_<YYYYMMDD_HHMMSS>.tally`.
String formatConflictBackupFileName({
  required String deviceId,
  required DateTime when,
}) {
  String pad2(int n) => n.toString().padLeft(2, '0');
  final y = when.year.toString().padLeft(4, '0');
  final m = pad2(when.month);
  final d = pad2(when.day);
  final hh = pad2(when.hour);
  final mm = pad2(when.minute);
  final ss = pad2(when.second);
  return 'conflict_${shortDeviceId(deviceId)}_${y}${m}${d}_${hh}${mm}${ss}.tally';
}

/// Returns `true` when [fileName] is a protected conflict snapshot (`conflict_*`).
bool isConflictBackupFileName(String fileName) =>
    fileName.trim().toLowerCase().startsWith('conflict_');

/// Selects older routine backups exceeding [keepCount] while NEVER deleting
/// `conflict_*` snapshots (R6).
List<String> selectNonConflictBackupsToPrune(
  Iterable<BackupRetentionItem> items, {
  int keepCount = defaultWebDavKeepCount,
}) {
  final routineOnly = items.where(
    (item) => !isConflictBackupFileName(item.fileName),
  );
  return selectBackupsToPrune(routineOnly, keepCount: keepCount);
}

/// Sanitizes an attachment archive path's basename for `sync/attachments/<sha256>__<basename>`.
String sanitizeAttachmentBasename(String archiveOrRelPath) {
  final normalized = archiveOrRelPath.replaceAll(r'\', '/').trim();
  final idx = normalized.lastIndexOf('/');
  final rawBase = idx >= 0 ? normalized.substring(idx + 1) : normalized;
  final cleaned = rawBase
      .replaceAll(RegExp(r'[\x00-\x1F/\\]'), '_')
      .replaceAll('..', '_')
      .trim();
  if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
    return 'attachment.bin';
  }
  return cleaned;
}

/// Builds deduplicated object name `<sha256>__<basename>`.
String buildAttachmentObjectName({
  required String sha256,
  required String archivePath,
}) {
  final cleanSha = sha256.trim().toLowerCase();
  if (!_hex64LowerOrUpper.hasMatch(cleanSha)) {
    throw Failure(FailureCode.validation, '非法的附件 SHA-256 摘要：$sha256');
  }
  return '${cleanSha}__${sanitizeAttachmentBasename(archivePath)}';
}

/// Parses `<sha256>__<basename>` from `sync/head.json` `attachmentFiles`.
({String sha256, String basename}) parseAttachmentObjectName(
  String objectName,
) {
  final trimmed = objectName.trim();
  if (trimmed.length < 67 ||
      trimmed.contains('/') ||
      trimmed.contains(r'\') ||
      trimmed.contains('\x00') ||
      trimmed.substring(64, 66) != '__') {
    throw Failure(FailureCode.corruptData, '远端同步附件对象名格式损坏：$objectName');
  }
  final sha = trimmed.substring(0, 64).toLowerCase();
  final base = trimmed.substring(66);
  if (!_hex64LowerOrUpper.hasMatch(sha) ||
      base.isEmpty ||
      base == '.' ||
      base == '..') {
    throw Failure(FailureCode.corruptData, '远端同步附件对象名非法：$objectName');
  }
  return (sha256: sha, basename: base);
}

/// Descriptor for a single attachment referenced by a sync snapshot.
final class SyncAttachmentDescriptor {
  const SyncAttachmentDescriptor({
    required this.archivePath,
    required this.sha256,
    required this.objectName,
  });

  /// Normalized archive path (`attachments/<relPath>`).
  final String archivePath;
  final String sha256;

  /// Deduplicated pool object name (`<sha256>__<basename>`).
  final String objectName;
}

/// Computes a deterministic SHA-256 over all 22 canonical tables + sorted
/// attachment SHA-256 checksums, completely independent of timestamps (`R2`).
String computeCanonicalSyncDataSha256({
  required Map<String, List<Map<String, Object?>>> tables,
  Map<String, String> attachmentChecksums = const <String, String>{},
}) {
  final orderedTables = <String, List<Map<String, Object?>>>{
    for (final tableName in tallyBusinessTables)
      tableName: tables[tableName] ?? const <Map<String, Object?>>[],
  };
  final normalizedAtt = <String, String>{};
  for (final entry in attachmentChecksums.entries) {
    final normPath = normalizeAttachmentArchivePath(entry.key);
    final sha = entry.value.trim().toLowerCase();
    if (!_hex64LowerOrUpper.hasMatch(sha)) {
      throw Failure(FailureCode.validation, '附件摘要格式无效：$normPath');
    }
    normalizedAtt[normPath] = sha;
  }
  final sortedKeys = normalizedAtt.keys.toList()..sort();
  final orderedAttachments = <String, String>{
    for (final k in sortedKeys) k: normalizedAtt[k]!,
  };

  final canonicalJson = jsonEncode(<String, Object>{
    'tables': orderedTables,
    'attachments': orderedAttachments,
  });
  return sha256Hex(utf8.encode(canonicalJson));
}

/// Returns `true` when [tables] + [attachmentCount] represent a brand-new
/// freshly seeded local database with zero user-entered records/assets/notes.
bool isFreshSeedSnapshot(
  Map<String, List<Map<String, Object?>>> tables, {
  required int attachmentCount,
}) {
  if (attachmentCount > 0) return false;
  const mustBeEmptyTables = <String>[
    'record',
    'asset',
    'budget',
    'tag',
    'tag_record',
    'installment',
    'record_period',
    'reminder_event',
    'record_template',
    'bank_card',
    'wish',
    'remark',
    'money_save_plan',
    'money_save_plan_record',
    'asset_book',
    'stat_story',
    'auto_map',
    'import_platform',
    'note',
  ];
  for (final name in mustBeEmptyTables) {
    final rows = tables[name];
    if (rows != null && rows.isNotEmpty) return false;
  }
  final books = tables['account_book'] ?? const <Map<String, Object?>>[];
  if (books.length > 1) return false;
  final currencies = tables['currency'] ?? const <Map<String, Object?>>[];
  if (currencies.length > 1) return false;
  if (currencies.length == 1 && currencies.single['code'] != 'CNY') {
    return false;
  }
  return true;
}

/// Parsed remote `sync/head.json` pointer (§2.2).
final class CloudSyncHead {
  CloudSyncHead({
    this.format = cloudSyncFormatVersion,
    required this.revision,
    required String dataSha256,
    required this.updatedAtMs,
    required this.deviceId,
    required this.deviceName,
    required this.recordCount,
    required List<String> attachmentFiles,
    Map<String, String>? attachmentManifest,
  }) : dataSha256 = dataSha256.toLowerCase(),
       attachmentFiles = List<String>.unmodifiable(
         List<String>.from(attachmentFiles)..sort(),
       ),
       attachmentManifest = attachmentManifest == null
           ? null
           : Map<String, String>.unmodifiable({
               for (final e in attachmentManifest.entries)
                 normalizeAttachmentArchivePath(e.key): e.value.toLowerCase(),
             });

  final int format;
  final int revision;
  final String dataSha256;
  final int updatedAtMs;
  final String deviceId;
  final String deviceName;
  final int recordCount;
  final List<String> attachmentFiles;
  final Map<String, String>? attachmentManifest;

  /// Resolves every attachment required to reconstruct this snapshot locally.
  List<SyncAttachmentDescriptor> resolvedAttachments() {
    if (attachmentManifest != null) {
      final keys = attachmentManifest!.keys.toList()..sort();
      return <SyncAttachmentDescriptor>[
        for (final archivePath in keys)
          SyncAttachmentDescriptor(
            archivePath: archivePath,
            sha256: attachmentManifest![archivePath]!,
            objectName: buildAttachmentObjectName(
              sha256: attachmentManifest![archivePath]!,
              archivePath: archivePath,
            ),
          ),
      ];
    }
    return <SyncAttachmentDescriptor>[
      for (final obj in attachmentFiles)
        () {
          final parsed = parseAttachmentObjectName(obj);
          return SyncAttachmentDescriptor(
            archivePath: normalizeAttachmentArchivePath(parsed.basename),
            sha256: parsed.sha256,
            objectName: obj,
          );
        }(),
    ];
  }

  Map<String, Object> toJson() => <String, Object>{
    'format': format,
    'revision': revision,
    'dataSha256': dataSha256,
    'updatedAtMs': updatedAtMs,
    'deviceId': deviceId,
    'deviceName': deviceName,
    'recordCount': recordCount,
    'attachmentFiles': attachmentFiles,
    if (attachmentManifest != null) 'attachmentManifest': attachmentManifest!,
  };

  factory CloudSyncHead.fromJson(Map<String, Object?> json) {
    final format = json['format'];
    if (format is! int || format < 1) {
      throw const Failure(FailureCode.corruptData, '远端 head.json 缺少有效的 format');
    }
    if (format > cloudSyncFormatVersion) {
      throw const Failure(FailureCode.upgradeRequired, '云端同步格式版本较新，请升级帐屿后同步');
    }
    final revision = json['revision'];
    if (revision is! int || revision < 1) {
      throw const Failure(FailureCode.corruptData, '远端 head.json revision 无效');
    }
    final dataSha256 = json['dataSha256'];
    if (dataSha256 is! String || !_hex64LowerOrUpper.hasMatch(dataSha256)) {
      throw const Failure(
        FailureCode.corruptData,
        '远端 head.json dataSha256 损坏',
      );
    }
    final updatedAtMs = json['updatedAtMs'];
    if (updatedAtMs is! int || updatedAtMs < 0) {
      throw const Failure(
        FailureCode.corruptData,
        '远端 head.json updatedAtMs 无效',
      );
    }
    final deviceId = (json['deviceId'] as String?)?.trim() ?? '';
    if (deviceId.isEmpty) {
      throw const Failure(FailureCode.corruptData, '远端 head.json deviceId 缺失');
    }
    final deviceName = (json['deviceName'] as String?)?.trim() ?? '远端设备';
    final recordCount = json['recordCount'];
    if (recordCount is! int || recordCount < 0) {
      throw const Failure(
        FailureCode.corruptData,
        '远端 head.json recordCount 无效',
      );
    }
    final rawAttFiles = json['attachmentFiles'];
    if (rawAttFiles is! List) {
      throw const Failure(
        FailureCode.corruptData,
        '远端 head.json attachmentFiles 缺失',
      );
    }
    final attFiles = <String>[];
    for (final item in rawAttFiles) {
      if (item is! String) {
        throw const Failure(
          FailureCode.corruptData,
          '远端 head.json attachmentFiles 条目损坏',
        );
      }
      parseAttachmentObjectName(item);
      attFiles.add(item.trim());
    }

    Map<String, String>? attManifest;
    final rawManifest = json['attachmentManifest'];
    if (rawManifest != null) {
      if (rawManifest is! Map) {
        throw const Failure(
          FailureCode.corruptData,
          '远端 head.json attachmentManifest 结构损坏',
        );
      }
      attManifest = <String, String>{};
      for (final entry in rawManifest.entries) {
        final k = entry.key;
        final v = entry.value;
        if (k is! String || v is! String || !_hex64LowerOrUpper.hasMatch(v)) {
          throw const Failure(
            FailureCode.corruptData,
            '远端 head.json attachmentManifest 条目无效',
          );
        }
        attManifest[normalizeAttachmentArchivePath(k)] = v.toLowerCase();
      }
    }

    return CloudSyncHead(
      format: format,
      revision: revision,
      dataSha256: dataSha256,
      updatedAtMs: updatedAtMs,
      deviceId: deviceId,
      deviceName: deviceName,
      recordCount: recordCount,
      attachmentFiles: attFiles,
      attachmentManifest: attManifest,
    );
  }
}

/// Persistent local sync cursor stored in `ti_preference` (`cloud_sync_cursor`).
final class LocalSyncCursor {
  const LocalSyncCursor({
    this.lastSyncedRevision = 0,
    this.lastSyncedDataSha256,
    this.lastSyncedAtMs,
    this.targetFingerprint,
    this.lastConflictSha256,
    this.lastConflictFileName,
  });

  const LocalSyncCursor.initial() : this();

  final int lastSyncedRevision;
  final String? lastSyncedDataSha256;
  final int? lastSyncedAtMs;
  final String? targetFingerprint;
  final String? lastConflictSha256;
  final String? lastConflictFileName;

  bool get isNeverSynced =>
      lastSyncedRevision <= 0 ||
      lastSyncedDataSha256 == null ||
      lastSyncedDataSha256!.isEmpty;

  /// Returns an effective cursor scoped to [currentTargetFingerprint] so
  /// switching cloud targets resets cursor state cleanly instead of reusing a
  /// stale revision number from another server/bucket.
  LocalSyncCursor scopedToTarget(String currentTargetFingerprint) {
    if (targetFingerprint != null &&
        targetFingerprint!.isNotEmpty &&
        targetFingerprint != currentTargetFingerprint) {
      return LocalSyncCursor(targetFingerprint: currentTargetFingerprint);
    }
    return this;
  }

  LocalSyncCursor copyWith({
    int? lastSyncedRevision,
    String? lastSyncedDataSha256,
    int? lastSyncedAtMs,
    String? targetFingerprint,
    String? lastConflictSha256,
    String? lastConflictFileName,
    bool clearConflictRecord = false,
  }) => LocalSyncCursor(
    lastSyncedRevision: lastSyncedRevision ?? this.lastSyncedRevision,
    lastSyncedDataSha256: lastSyncedDataSha256 ?? this.lastSyncedDataSha256,
    lastSyncedAtMs: lastSyncedAtMs ?? this.lastSyncedAtMs,
    targetFingerprint: targetFingerprint ?? this.targetFingerprint,
    lastConflictSha256: clearConflictRecord
        ? null
        : (lastConflictSha256 ?? this.lastConflictSha256),
    lastConflictFileName: clearConflictRecord
        ? null
        : (lastConflictFileName ?? this.lastConflictFileName),
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'last_synced_revision': lastSyncedRevision,
    'last_synced_data_sha256': lastSyncedDataSha256,
    'last_synced_at_ms': lastSyncedAtMs,
    'target_fingerprint': targetFingerprint,
    'last_conflict_sha256': lastConflictSha256,
    'last_conflict_file': lastConflictFileName,
  };

  factory LocalSyncCursor.fromJson(Map<String, Object?> json) =>
      LocalSyncCursor(
        lastSyncedRevision: (json['last_synced_revision'] as int?) ?? 0,
        lastSyncedDataSha256: json['last_synced_data_sha256'] as String?,
        lastSyncedAtMs: json['last_synced_at_ms'] as int?,
        targetFingerprint: json['target_fingerprint'] as String?,
        lastConflictSha256: json['last_conflict_sha256'] as String?,
        lastConflictFileName: json['last_conflict_file'] as String?,
      );
}

/// User-chosen resolution strategy when both local and remote diverged.
enum SyncConflictResolution { useRemote, useLocal }

/// Action chosen by the pure sync state machine (`R5`).
enum SyncActionType { noOp, fastForwardCursor, pullRemote, pushLocal, conflict }

final class SyncDecision {
  const SyncDecision({required this.action, this.nextRevision});

  final SyncActionType action;
  final int? nextRevision;
}

/// Pure deterministic state machine evaluating what [syncNow] must do (`R5`).
SyncDecision decideSyncAction({
  required LocalSyncCursor cursor,
  required String localDataSha256,
  required bool isLocalFreshEmpty,
  required CloudSyncHead? remoteHead,
  SyncConflictResolution? resolution,
}) {
  final cleanLocalSha = localDataSha256.toLowerCase();

  if (resolution == SyncConflictResolution.useRemote) {
    if (remoteHead == null) {
      throw const Failure(FailureCode.validation, '云端尚无同步快照，无法采用云端版本');
    }
    return const SyncDecision(action: SyncActionType.pullRemote);
  }
  if (resolution == SyncConflictResolution.useLocal) {
    return SyncDecision(
      action: SyncActionType.pushLocal,
      nextRevision: (remoteHead?.revision ?? 0) + 1,
    );
  }

  // Remote head missing -> initialize cloud with local state at revision 1.
  if (remoteHead == null) {
    return const SyncDecision(
      action: SyncActionType.pushLocal,
      nextRevision: 1,
    );
  }

  // Identical content already on both sides -> align cursor if needed, zero transfer.
  if (remoteHead.dataSha256 == cleanLocalSha) {
    if (cursor.lastSyncedRevision == remoteHead.revision &&
        cursor.lastSyncedDataSha256?.toLowerCase() == cleanLocalSha) {
      return const SyncDecision(action: SyncActionType.noOp);
    }
    return const SyncDecision(action: SyncActionType.fastForwardCursor);
  }

  // First-time sync on this device against a populated cloud snapshot:
  if (cursor.isNeverSynced) {
    if (isLocalFreshEmpty) {
      return const SyncDecision(action: SyncActionType.pullRemote);
    }
    return const SyncDecision(action: SyncActionType.conflict);
  }

  final lastSha = cursor.lastSyncedDataSha256!.toLowerCase();
  final localChanged = cleanLocalSha != lastSha;
  final remoteChanged =
      remoteHead.revision != cursor.lastSyncedRevision ||
      remoteHead.dataSha256 != lastSha;

  if (!localChanged && remoteChanged) {
    return const SyncDecision(action: SyncActionType.pullRemote);
  }
  if (localChanged && !remoteChanged) {
    return SyncDecision(
      action: SyncActionType.pushLocal,
      nextRevision: remoteHead.revision + 1,
    );
  }
  if (localChanged && remoteChanged) {
    return const SyncDecision(action: SyncActionType.conflict);
  }
  return const SyncDecision(action: SyncActionType.noOp);
}

/// High-level outcome status of a completed [syncNow] invocation.
enum CloudSyncStatus { alreadyUpToDate, pushed, pulled, conflict }

/// Rich outcome returned to callers and UI after [syncNow].
final class CloudSyncOutcome {
  const CloudSyncOutcome({
    required this.status,
    required this.revision,
    required this.localDataSha256,
    this.remoteHead,
    this.uploadedAttachments = 0,
    this.downloadedAttachments = 0,
    this.conflictBackupFileName,
    this.archivedBackupFileName,
  });

  const CloudSyncOutcome.conflict({
    required this.revision,
    required this.localDataSha256,
    required this.remoteHead,
    required this.conflictBackupFileName,
  }) : status = CloudSyncStatus.conflict,
       uploadedAttachments = 0,
       downloadedAttachments = 0,
       archivedBackupFileName = null;

  final CloudSyncStatus status;
  final int revision;
  final String localDataSha256;
  final CloudSyncHead? remoteHead;
  final int uploadedAttachments;
  final int downloadedAttachments;
  final String? conflictBackupFileName;
  final String? archivedBackupFileName;

  bool get isConflict => status == CloudSyncStatus.conflict;
}
