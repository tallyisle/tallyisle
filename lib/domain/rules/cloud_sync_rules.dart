import 'dart:convert';
import 'dart:math';

import '../../core/failure.dart';
import 'tally_backup.dart';

const int currentCloudSyncHeadFormat = 2;
const int cloudSyncFormatVersion = currentCloudSyncHeadFormat;
const String cloudSyncHeadPath = 'sync/head.json';
const String cloudSyncRevisionsDir = 'sync/revisions';
const String legacyCloudSyncLatestDbPath = 'sync/latest_db.tally';
const String cloudSyncAttachmentsDir = 'sync/attachments';
const int maxSanitizedAttachmentBasenameUtf8Bytes = 120;

const String prefKeyCloudSyncSettings = 'cloud_sync_settings';
const String prefKeyCloudSyncCursor = 'cloud_sync_cursor';
const String prefKeyS3Config = 'backup_s3_config';
const String prefKeyLocalAutoBackupPolicy = 'local_auto_backup_policy';
const String prefKeyLocalAutoBackupLastAtMs = 'local_auto_backup_last_at_ms';
const String prefKeyLocalAutoBackupLastSha256 = 'local_auto_backup_last_sha256';
const String prefKeyCloudSyncLastScheduleCheckAtMs =
    'cloud_sync_last_schedule_check_at_ms';

const List<int> autoIdleMinutesChoices = <int>[1, 3, 5, 10, 15, 30];
const List<int> localScheduleIntervalMinutesChoices = <int>[
  30,
  60,
  360,
  720,
  1440,
];
const List<int> cloudScheduleIntervalMinutesChoices = <int>[
  15,
  30,
  60,
  360,
  720,
  1440,
];
const List<int> localBackupKeepCountChoices = <int>[5, 10, 20, 50, 100];

final RegExp _hex64LowerOrUpper = RegExp(r'^[0-9a-fA-F]{64}$');

/// Trigger source for automatic local backup or multi-device cloud sync.
enum AutoTriggerSource { startup, windowFocus, exit, idleAfterChange, schedule }

/// Independent user-configured policy for automatic local `.tally` backups
/// stored in `ti_preference` (`local_auto_backup_policy`).
///
/// All triggers default to `false` on fresh installs.
final class LocalAutoBackupPolicy {
  const LocalAutoBackupPolicy({
    this.backupOnStartup = false,
    this.backupOnExit = false,
    this.backupOnIdle = false,
    int idleMinutes = 5,
    this.backupOnSchedule = false,
    int scheduleIntervalMinutes = 360,
    int keepCount = defaultWebDavKeepCount,
  }) : idleMinutes = idleMinutes < 1
           ? 1
           : (idleMinutes > 1440 ? 1440 : idleMinutes),
       scheduleIntervalMinutes = scheduleIntervalMinutes < 5
           ? 5
           : (scheduleIntervalMinutes > 10080
                 ? 10080
                 : scheduleIntervalMinutes),
       keepCount = keepCount < 1 ? 1 : (keepCount > 200 ? 200 : keepCount);

  static const LocalAutoBackupPolicy defaults = LocalAutoBackupPolicy();

  final bool backupOnStartup;
  final bool backupOnExit;
  final bool backupOnIdle;
  final int idleMinutes;
  final bool backupOnSchedule;
  final int scheduleIntervalMinutes;
  final int keepCount;

  bool get hasAnyTrigger =>
      backupOnStartup || backupOnExit || backupOnIdle || backupOnSchedule;

  int get idleDurationMs => idleMinutes * 60 * 1000;
  int get scheduleIntervalMs => scheduleIntervalMinutes * 60 * 1000;

  LocalAutoBackupPolicy copyWith({
    bool? backupOnStartup,
    bool? backupOnExit,
    bool? backupOnIdle,
    int? idleMinutes,
    bool? backupOnSchedule,
    int? scheduleIntervalMinutes,
    int? keepCount,
  }) => LocalAutoBackupPolicy(
    backupOnStartup: backupOnStartup ?? this.backupOnStartup,
    backupOnExit: backupOnExit ?? this.backupOnExit,
    backupOnIdle: backupOnIdle ?? this.backupOnIdle,
    idleMinutes: idleMinutes ?? this.idleMinutes,
    backupOnSchedule: backupOnSchedule ?? this.backupOnSchedule,
    scheduleIntervalMinutes:
        scheduleIntervalMinutes ?? this.scheduleIntervalMinutes,
    keepCount: keepCount ?? this.keepCount,
  );

  Map<String, Object> toJson() => <String, Object>{
    'backup_on_startup': backupOnStartup,
    'backup_on_exit': backupOnExit,
    'backup_on_idle': backupOnIdle,
    'idle_minutes': idleMinutes,
    'backup_on_schedule': backupOnSchedule,
    'schedule_interval_minutes': scheduleIntervalMinutes,
    'keep_count': keepCount,
  };

  factory LocalAutoBackupPolicy.fromJson(Map<String, Object?> json) {
    final rawIdle = json['idle_minutes'];
    final rawSchedule = json['schedule_interval_minutes'];
    final rawKeep = json['keep_count'];
    return LocalAutoBackupPolicy(
      backupOnStartup: (json['backup_on_startup'] as bool?) ?? false,
      backupOnExit: (json['backup_on_exit'] as bool?) ?? false,
      backupOnIdle: (json['backup_on_idle'] as bool?) ?? false,
      idleMinutes: rawIdle is int ? rawIdle : 5,
      backupOnSchedule: (json['backup_on_schedule'] as bool?) ?? false,
      scheduleIntervalMinutes: rawSchedule is int ? rawSchedule : 360,
      keepCount: rawKeep is int ? rawKeep : defaultWebDavKeepCount,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalAutoBackupPolicy &&
          other.backupOnStartup == backupOnStartup &&
          other.backupOnExit == backupOnExit &&
          other.backupOnIdle == backupOnIdle &&
          other.idleMinutes == idleMinutes &&
          other.backupOnSchedule == backupOnSchedule &&
          other.scheduleIntervalMinutes == scheduleIntervalMinutes &&
          other.keepCount == keepCount);

  @override
  int get hashCode => Object.hash(
    backupOnStartup,
    backupOnExit,
    backupOnIdle,
    idleMinutes,
    backupOnSchedule,
    scheduleIntervalMinutes,
    keepCount,
  );
}

/// Decodes [LocalAutoBackupPolicy] from preference JSON, falling back to
/// [LocalAutoBackupPolicy.defaults] (all triggers `false`) if unset or corrupt.
LocalAutoBackupPolicy resolveLocalAutoBackupPolicy(String? rawJson) {
  if (rawJson == null || rawJson.trim().isEmpty) {
    return LocalAutoBackupPolicy.defaults;
  }
  try {
    final decoded = jsonDecode(rawJson);
    if (decoded is Map<String, Object?>) {
      return LocalAutoBackupPolicy.fromJson(decoded);
    }
  } catch (_) {
    // Safe default on corrupt preference JSON.
  }
  return LocalAutoBackupPolicy.defaults;
}

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
///
/// All automatic triggers default to `false` on fresh installs.
final class CloudSyncSettings {
  const CloudSyncSettings({
    this.backend = CloudBackendType.none,
    this.explicitBackend = false,
    bool autoSyncEnabled = false,
    bool? syncOnStartup,
    bool? syncOnExit,
    this.syncOnIdle = false,
    int idleMinutes = 3,
    this.syncOnSchedule = false,
    int scheduleIntervalMinutes = 60,
    this.autoArchiveBackupEnabled = true,
    this.showHomeQuickEntry = false,
    this.showMeQuickEntry = false,
    required this.deviceId,
    this.deviceName = '帐屿本机',
  }) : syncOnStartup =
           syncOnStartup ?? (autoSyncEnabled && !syncOnIdle && !syncOnSchedule),
       syncOnExit =
           syncOnExit ?? (autoSyncEnabled && !syncOnIdle && !syncOnSchedule),
       idleMinutes = idleMinutes < 1
           ? 1
           : (idleMinutes > 1440 ? 1440 : idleMinutes),
       scheduleIntervalMinutes = scheduleIntervalMinutes < 5
           ? 5
           : (scheduleIntervalMinutes > 10080
                 ? 10080
                 : scheduleIntervalMinutes);

  final CloudBackendType backend;
  final bool explicitBackend;
  final bool syncOnStartup;
  final bool syncOnExit;
  final bool syncOnIdle;
  final int idleMinutes;
  final bool syncOnSchedule;
  final int scheduleIntervalMinutes;
  final bool autoArchiveBackupEnabled;
  final bool showHomeQuickEntry;
  final bool showMeQuickEntry;
  final String deviceId;
  final String deviceName;

  /// Returns `true` whenever at least one automatic sync trigger is enabled.
  bool get autoSyncEnabled =>
      syncOnStartup || syncOnExit || syncOnIdle || syncOnSchedule;

  int get idleDurationMs => idleMinutes * 60 * 1000;
  int get scheduleIntervalMs => scheduleIntervalMinutes * 60 * 1000;

  CloudSyncSettings copyWith({
    CloudBackendType? backend,
    bool? explicitBackend,
    bool? autoSyncEnabled,
    bool? syncOnStartup,
    bool? syncOnExit,
    bool? syncOnIdle,
    int? idleMinutes,
    bool? syncOnSchedule,
    int? scheduleIntervalMinutes,
    bool? autoArchiveBackupEnabled,
    bool? showHomeQuickEntry,
    bool? showMeQuickEntry,
    String? deviceId,
    String? deviceName,
  }) {
    var nextStartup = syncOnStartup ?? this.syncOnStartup;
    var nextExit = syncOnExit ?? this.syncOnExit;
    var nextIdle = syncOnIdle ?? this.syncOnIdle;
    var nextSchedule = syncOnSchedule ?? this.syncOnSchedule;

    if (autoSyncEnabled != null) {
      if (!autoSyncEnabled) {
        if (syncOnStartup == null) nextStartup = false;
        if (syncOnExit == null) nextExit = false;
        if (syncOnIdle == null) nextIdle = false;
        if (syncOnSchedule == null) nextSchedule = false;
      } else if (!nextStartup && !nextExit && !nextIdle && !nextSchedule) {
        nextStartup = true;
        nextExit = true;
      }
    }

    return CloudSyncSettings(
      backend: backend ?? this.backend,
      explicitBackend: explicitBackend ?? this.explicitBackend,
      syncOnStartup: nextStartup,
      syncOnExit: nextExit,
      syncOnIdle: nextIdle,
      idleMinutes: idleMinutes ?? this.idleMinutes,
      syncOnSchedule: nextSchedule,
      scheduleIntervalMinutes:
          scheduleIntervalMinutes ?? this.scheduleIntervalMinutes,
      autoArchiveBackupEnabled:
          autoArchiveBackupEnabled ?? this.autoArchiveBackupEnabled,
      showHomeQuickEntry: showHomeQuickEntry ?? this.showHomeQuickEntry,
      showMeQuickEntry: showMeQuickEntry ?? this.showMeQuickEntry,
      deviceId: deviceId ?? this.deviceId,
      deviceName: deviceName ?? this.deviceName,
    );
  }

  Map<String, Object> toJson() => <String, Object>{
    'backend': backend.wireValue,
    'explicit_backend': explicitBackend,
    'auto_sync_enabled': autoSyncEnabled,
    'sync_on_startup': syncOnStartup,
    'sync_on_exit': syncOnExit,
    'sync_on_idle': syncOnIdle,
    'idle_minutes': idleMinutes,
    'sync_on_schedule': syncOnSchedule,
    'schedule_interval_minutes': scheduleIntervalMinutes,
    'auto_archive_backup_enabled': autoArchiveBackupEnabled,
    'show_home_quick_entry': showHomeQuickEntry,
    'show_me_quick_entry': showMeQuickEntry,
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
    final hasExplicitTriggerKeys =
        json.containsKey('sync_on_startup') ||
        json.containsKey('sync_on_exit') ||
        json.containsKey('sync_on_idle') ||
        json.containsKey('sync_on_schedule');
    final legacyAutoSync = (json['auto_sync_enabled'] as bool?) ?? false;
    final rawIdle = json['idle_minutes'];
    final rawSchedule = json['schedule_interval_minutes'];

    return CloudSyncSettings(
      backend: CloudBackendType.fromWire(json['backend'] as String?),
      explicitBackend: (json['explicit_backend'] as bool?) ?? false,
      syncOnStartup: hasExplicitTriggerKeys
          ? ((json['sync_on_startup'] as bool?) ?? false)
          : legacyAutoSync,
      syncOnExit: hasExplicitTriggerKeys
          ? ((json['sync_on_exit'] as bool?) ?? false)
          : legacyAutoSync,
      syncOnIdle: hasExplicitTriggerKeys
          ? ((json['sync_on_idle'] as bool?) ?? false)
          : false,
      idleMinutes: rawIdle is int ? rawIdle : 3,
      syncOnSchedule: hasExplicitTriggerKeys
          ? ((json['sync_on_schedule'] as bool?) ?? false)
          : false,
      scheduleIntervalMinutes: rawSchedule is int ? rawSchedule : 60,
      autoArchiveBackupEnabled:
          (json['auto_archive_backup_enabled'] as bool?) ?? true,
      showHomeQuickEntry: (json['show_home_quick_entry'] as bool?) ?? false,
      showMeQuickEntry: (json['show_me_quick_entry'] as bool?) ?? false,
      deviceId: rawDeviceId.isEmpty ? fallbackDeviceId : rawDeviceId,
      deviceName: rawDeviceName.isEmpty ? fallbackDeviceName : rawDeviceName,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CloudSyncSettings &&
          other.backend == backend &&
          other.explicitBackend == explicitBackend &&
          other.syncOnStartup == syncOnStartup &&
          other.syncOnExit == syncOnExit &&
          other.syncOnIdle == syncOnIdle &&
          other.idleMinutes == idleMinutes &&
          other.syncOnSchedule == syncOnSchedule &&
          other.scheduleIntervalMinutes == scheduleIntervalMinutes &&
          other.autoArchiveBackupEnabled == autoArchiveBackupEnabled &&
          other.showHomeQuickEntry == showHomeQuickEntry &&
          other.showMeQuickEntry == showMeQuickEntry &&
          other.deviceId == deviceId &&
          other.deviceName == deviceName);

  @override
  int get hashCode => Object.hash(
    backend,
    explicitBackend,
    syncOnStartup,
    syncOnExit,
    syncOnIdle,
    idleMinutes,
    syncOnSchedule,
    scheduleIntervalMinutes,
    autoArchiveBackupEnabled,
    showHomeQuickEntry,
    showMeQuickEntry,
    deviceId,
    deviceName,
  );
}

/// Returns `true` if the specific [source] switch is turned on in [policy].
bool isLocalTriggerEnabled(
  LocalAutoBackupPolicy policy,
  AutoTriggerSource source,
) {
  return switch (source) {
    AutoTriggerSource.startup ||
    AutoTriggerSource.windowFocus => policy.backupOnStartup,
    AutoTriggerSource.exit => policy.backupOnExit,
    AutoTriggerSource.idleAfterChange => policy.backupOnIdle,
    AutoTriggerSource.schedule => policy.backupOnSchedule,
  };
}

/// Pure eligibility rule evaluating whether a local `.tally` auto-backup should
/// execute for [source].
bool shouldRunLocalAutoBackupForTrigger({
  required LocalAutoBackupPolicy policy,
  required AutoTriggerSource source,
  required bool localDataChanged,
  required int? lastAutoBackupAtMs,
  required int nowMs,
}) {
  if (!isLocalTriggerEnabled(policy, source) || !localDataChanged) {
    return false;
  }
  if (source == AutoTriggerSource.schedule) {
    if (lastAutoBackupAtMs != null &&
        (nowMs - lastAutoBackupAtMs) < policy.scheduleIntervalMs) {
      return false;
    }
  }
  return true;
}

/// Returns `true` if the specific [source] switch is turned on in [settings].
bool isCloudTriggerEnabled(
  CloudSyncSettings settings,
  AutoTriggerSource source,
) {
  if (settings.backend == CloudBackendType.none) return false;
  return switch (source) {
    AutoTriggerSource.startup ||
    AutoTriggerSource.windowFocus => settings.syncOnStartup,
    AutoTriggerSource.exit => settings.syncOnExit,
    AutoTriggerSource.idleAfterChange => settings.syncOnIdle,
    AutoTriggerSource.schedule => settings.syncOnSchedule,
  };
}

/// Pure eligibility rule evaluating whether multi-device cloud sync should
/// execute for [source].
bool shouldRunCloudAutoSyncForTrigger({
  required CloudSyncSettings settings,
  required bool isBackendConfigured,
  required AutoTriggerSource source,
  required int? lastScheduleCheckAtMs,
  required int nowMs,
}) {
  if (!isBackendConfigured || !isCloudTriggerEnabled(settings, source)) {
    return false;
  }
  if (source == AutoTriggerSource.schedule) {
    if (lastScheduleCheckAtMs != null &&
        (nowMs - lastScheduleCheckAtMs) < settings.scheduleIntervalMs) {
      return false;
    }
  }
  return true;
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
/// `conflict_<deviceIdShort>_<YYYYMMDD_HHMMSS>.tally`, appending a
/// collision-safe `_2` / `_3` suffix when [existingFileNames] already has a
/// conflict file from the same second (`S-08`).
String formatConflictBackupFileName({
  required String deviceId,
  required DateTime when,
  Iterable<String> existingFileNames = const <String>[],
}) {
  String pad2(int n) => n.toString().padLeft(2, '0');
  final y = when.year.toString().padLeft(4, '0');
  final m = pad2(when.month);
  final d = pad2(when.day);
  final hh = pad2(when.hour);
  final mm = pad2(when.minute);
  final ss = pad2(when.second);
  final base =
      'conflict_${shortDeviceId(deviceId)}_${y}${m}${d}_${hh}${mm}${ss}.tally';
  return resolveCollisionSafeBackupFileName(base, existingFileNames);
}

/// Builds immutable versioned sync snapshot path:
/// `sync/revisions/db_r<rev>_<sha16>.tally` (`S-01`).
String buildCloudSyncRevisionPath({
  required int revision,
  required String dataSha256,
}) {
  if (revision < 1) {
    throw Failure(FailureCode.validation, '非法的云同步版本号：$revision');
  }
  final cleanSha = dataSha256.trim().toLowerCase();
  if (!_hex64LowerOrUpper.hasMatch(cleanSha)) {
    throw Failure(FailureCode.validation, '非法的同步数据摘要：$dataSha256');
  }
  return '$cloudSyncRevisionsDir/db_r${revision}_${cleanSha.substring(0, 16)}.tally';
}

/// Validates that [rawPath] is a safe relative snapshot path directly under
/// `sync/revisions/` without path traversal, backslashes, or `.tmp` suffix (`S-01`).
String validateCloudSyncDatabasePath(String rawPath) {
  final trimmed = rawPath.trim();
  if (trimmed.isEmpty) {
    throw const Failure(
      FailureCode.corruptData,
      '远端 head.json 缺少 databasePath',
    );
  }
  if (trimmed.contains(r'\') ||
      trimmed.contains('\x00') ||
      trimmed.startsWith('/') ||
      trimmed.endsWith('/')) {
    throw Failure(
      FailureCode.corruptData,
      '远端 head.json databasePath 非法：$rawPath',
    );
  }
  final segments = trimmed.split('/');
  if (segments.length != 3 ||
      segments[0] != 'sync' ||
      segments[1] != 'revisions') {
    throw Failure(
      FailureCode.corruptData,
      '远端 head.json databasePath 必须位于 sync/revisions/ 下：$rawPath',
    );
  }
  final fileName = segments[2];
  final lowerName = fileName.toLowerCase();
  if (fileName.isEmpty ||
      fileName == '.' ||
      fileName == '..' ||
      fileName.contains('..') ||
      lowerName.endsWith('.tmp') ||
      !lowerName.endsWith('.tally')) {
    throw Failure(
      FailureCode.corruptData,
      '远端 head.json databasePath 文件名非法：$rawPath',
    );
  }
  return 'sync/revisions/$fileName';
}

final RegExp _syncRevisionFilePattern = RegExp(
  r'^db_r([1-9][0-9]*)_([0-9a-fA-F]{16})\.tally$',
);

/// Parses `db_r<rev>_<sha16>.tally` inside `sync/revisions/`, or returns `null`.
({int revision, String sha16})? parseSyncRevisionFileName(String fileName) {
  final m = _syncRevisionFilePattern.firstMatch(fileName.trim());
  if (m == null) return null;
  final rev = int.tryParse(m.group(1)!);
  if (rev == null || rev < 1) return null;
  return (revision: rev, sha16: m.group(2)!.toLowerCase());
}

/// Selects superseded `sync/revisions/*` filenames safe to prune after
/// [currentRevision] (`[currentDatabasePath]`) has been committed to `head.json`,
/// always preserving the current revision AND the immediate previous revision
/// (`r(N-1)` / [previousDatabasePath]) so an in-flight reader on the prior
/// revision is never broken (`S-01`).
List<String> selectSupersededSyncRevisionFileNames(
  Iterable<String> existingFileNames, {
  required int currentRevision,
  required String currentDatabasePath,
  String? previousDatabasePath,
}) {
  final keepNames = <String>{
    currentDatabasePath.split('/').last,
    if (previousDatabasePath != null && previousDatabasePath.contains('/'))
      previousDatabasePath.split('/').last,
  };

  int? highestPriorRev;
  for (final name in existingFileNames) {
    final parsed = parseSyncRevisionFileName(name);
    if (parsed == null) continue;
    if (parsed.revision < currentRevision) {
      if (highestPriorRev == null || parsed.revision > highestPriorRev) {
        highestPriorRev = parsed.revision;
      }
    }
  }

  final minProtectedRev = currentRevision - 1;
  final toDelete = <String>[];
  for (final name in existingFileNames) {
    if (keepNames.contains(name)) continue;
    final parsed = parseSyncRevisionFileName(name);
    if (parsed == null) continue;
    if (parsed.revision >= minProtectedRev) continue;
    if (highestPriorRev != null && parsed.revision == highestPriorRev) {
      continue;
    }
    toDelete.add(name);
  }
  toDelete.sort();
  return toDelete;
}

/// Returns `true` when decoded `head.json` is an incompatible legacy format
/// (`format < 2`) that must route into conflict protection (`S-01`).
bool isLegacyCloudSyncHeadJson(Map<String, Object?> json) {
  final format = json['format'];
  return format is int && format >= 1 && format < currentCloudSyncHeadFormat;
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

String _truncateUtf8ByRunes(String input, int maxBytes) {
  if (maxBytes <= 0 || input.isEmpty) return '';
  final sb = StringBuffer();
  var usedBytes = 0;
  for (final rune in input.runes) {
    final ch = String.fromCharCode(rune);
    final chBytes = utf8.encode(ch).length;
    if (usedBytes + chBytes > maxBytes) break;
    sb.write(ch);
    usedBytes += chBytes;
  }
  return sb.toString();
}

/// Sanitizes an attachment archive path's basename for `sync/attachments/<sha256>__<basename>`,
/// truncating UTF-8 byte length safely to `<= 120` bytes while preserving the
/// file extension (`S-08`).
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
  if (utf8.encode(cleaned).length <= maxSanitizedAttachmentBasenameUtf8Bytes) {
    return cleaned;
  }

  final dotIdx = cleaned.lastIndexOf('.');
  String stem = cleaned;
  String ext = '';
  if (dotIdx > 0) {
    final candidateExt = cleaned.substring(dotIdx);
    if (candidateExt.length > 1 && utf8.encode(candidateExt).length <= 24) {
      stem = cleaned.substring(0, dotIdx);
      ext = candidateExt;
    }
  }
  final extBytes = utf8.encode(ext).length;
  final maxStemBytes = maxSanitizedAttachmentBasenameUtf8Bytes - extBytes;
  var truncatedStem = _truncateUtf8ByRunes(stem, maxStemBytes);
  if (truncatedStem.isEmpty || truncatedStem == '.' || truncatedStem == '..') {
    truncatedStem = 'att';
  }
  final candidate = '$truncatedStem$ext';
  if (candidate.isEmpty || candidate == '.' || candidate == '..') {
    return 'attachment.bin';
  }
  return candidate;
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

const List<String> _defaultSeedExpenseCategoryNames = <String>[
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

const List<String> _defaultSeedIncomeCategoryNames = <String>[
  '工资',
  '零花钱',
  '奖金',
  '收红包',
];

/// Returns `true` when [tables] + [attachmentCount] represent a brand-new
/// freshly seeded local database with zero user-entered records/assets/notes
/// AND uncustomized default `account_book` #1 and `record_category` rows (`S-09`).
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
  if (books.length == 1) {
    final book = books.single;
    if ((book['id'] ?? 1) != 1 ||
        (book['name'] ?? '日常账本') != '日常账本' ||
        (book['type'] ?? 1) != 1 ||
        (book['cover'] ?? '') != '' ||
        (book['sort'] ?? 1) != 1 ||
        (book['status'] ?? 0) != 0 ||
        (book['start_day'] ?? 1) != 1 ||
        (book['display_way'] ?? 0) != 0 ||
        (book['extra_info'] != null && book['extra_info'] != '')) {
      return false;
    }
  }

  final categories = tables['record_category'];
  if (categories != null && (categories.isNotEmpty || books.isNotEmpty)) {
    const expectedTotal = 16;
    if (categories.length != expectedTotal) return false;
    for (var i = 0; i < expectedTotal; i++) {
      final row = categories[i];
      final expectedName = i < _defaultSeedExpenseCategoryNames.length
          ? _defaultSeedExpenseCategoryNames[i]
          : _defaultSeedIncomeCategoryNames[i -
                _defaultSeedExpenseCategoryNames.length];
      final expectedType = i < _defaultSeedExpenseCategoryNames.length ? 0 : 1;
      final isHidden = row['is_hide'];
      if ((row['id'] ?? (i + 1)) != i + 1 ||
          row['name'] != expectedName ||
          row['type'] != expectedType ||
          (row['sort'] ?? i) != i ||
          (row['parent_cat_id'] ?? -1) != -1 ||
          (row['account_book_id'] ?? 1) != 1 ||
          (isHidden == true || isHidden == 1) ||
          (row['icon'] ?? '') != '' ||
          (row['color_fill'] != null && row['color_fill'] != '') ||
          (row['extra_info'] != null && row['extra_info'] != '')) {
        return false;
      }
    }
  }

  final currencies = tables['currency'] ?? const <Map<String, Object?>>[];
  if (currencies.length > 1) return false;
  if (currencies.length == 1 && currencies.single['code'] != 'CNY') {
    return false;
  }
  return true;
}

/// Parsed remote `sync/head.json` pointer (`format: 2`, `S-01`).
final class CloudSyncHead {
  CloudSyncHead({
    this.format = currentCloudSyncHeadFormat,
    required this.revision,
    required String dataSha256,
    String? databasePath,
    required this.updatedAtMs,
    required this.deviceId,
    required this.deviceName,
    required this.recordCount,
    required List<String> attachmentFiles,
    Map<String, String>? attachmentManifest,
  }) : dataSha256 = dataSha256.toLowerCase(),
       databasePath = validateCloudSyncDatabasePath(
         databasePath ??
             buildCloudSyncRevisionPath(
               revision: revision,
               dataSha256: dataSha256,
             ),
       ),
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
  final String databasePath;
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
    'databasePath': databasePath,
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
    if (format > currentCloudSyncHeadFormat) {
      throw const Failure(FailureCode.upgradeRequired, '云端同步格式版本较新，请升级帐屿后同步');
    }
    if (format < currentCloudSyncHeadFormat) {
      throw Failure(
        FailureCode.corruptData,
        '远端同步清单为旧版格式（format=$format），需冲突保护升级',
      );
    }
    final rawDatabasePath = json['databasePath'];
    if (rawDatabasePath is! String || rawDatabasePath.trim().isEmpty) {
      throw const Failure(
        FailureCode.corruptData,
        '远端 head.json 缺少 databasePath',
      );
    }
    final databasePath = validateCloudSyncDatabasePath(rawDatabasePath);
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
      databasePath: databasePath,
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

/// Pure deterministic state machine evaluating what [syncNow] must do (`R5`, `S-01`).
SyncDecision decideSyncAction({
  required LocalSyncCursor cursor,
  required String localDataSha256,
  required bool isLocalFreshEmpty,
  required CloudSyncHead? remoteHead,
  bool hasRemoteOrphanLatestDb = false,
  bool hasLegacyIncompatibleRemoteHead = false,
  int? legacyRemoteRevision,
  SyncConflictResolution? resolution,
}) {
  final cleanLocalSha = localDataSha256.toLowerCase();
  final hasUnusableRemoteState =
      hasRemoteOrphanLatestDb || hasLegacyIncompatibleRemoteHead;

  if (resolution == SyncConflictResolution.useRemote) {
    if (remoteHead == null && !hasRemoteOrphanLatestDb) {
      throw const Failure(FailureCode.validation, '云端尚无有效同步快照，无法采用云端版本');
    }
    return const SyncDecision(action: SyncActionType.pullRemote);
  }
  if (resolution == SyncConflictResolution.useLocal) {
    final baseRev = remoteHead?.revision ?? legacyRemoteRevision ?? 0;
    return SyncDecision(
      action: SyncActionType.pushLocal,
      nextRevision: baseRev + 1,
    );
  }

  // Remote head missing or legacy format < 2: if an orphan revision snapshot or
  // legacy `format: 1` state already exists on remote, NEVER treat the remote
  // as an empty cloud!
  if (remoteHead == null) {
    if (hasUnusableRemoteState) {
      return SyncDecision(
        action: SyncActionType.conflict,
        nextRevision: legacyRemoteRevision,
      );
    }
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
