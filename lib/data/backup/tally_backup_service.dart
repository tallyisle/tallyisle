import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/drift.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/app_version.dart';
import '../../core/failure.dart';
import '../../core/zip_archive.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/cloud_sync_merge_rules.dart';
import '../../domain/rules/cloud_sync_rules.dart';
import '../../domain/rules/online_rate_rules.dart';
import '../../domain/rules/receipt_diy_rules.dart';
import '../../domain/rules/s3_sigv4_rules.dart';
import '../../domain/rules/tally_backup.dart';
import '../../platform/files.dart';
import '../db/database.dart';
import '../db/failures.dart';
import '../reminder/reminder_service.dart';
import 's3_client.dart';
import 'webdav_client.dart';

const String prefKeyWebDavConfig = 'backup_webdav_config';
const String prefKeyLastBackupAtMs = 'backup_last_at_ms';
const String prefKeyLastBackupDataSha256 = 'backup_last_data_sha256';
const String prefKeyExternalBackupDirBinding = 'backup_external_dir_binding';
const String prefKeyExternalBackupDirNeedsRebind =
    'backup_external_dir_needs_rebind';
const int defaultIsolateOffloadRowThreshold = 1000;
const int defaultMaxInlineConflictAttachmentBytes = 120 * 1024 * 1024;

/// Local app-managed backup directory implementation of [BackupTarget] (ADR-017).
final class LocalDirectoryBackupTarget implements BackupTarget {
  LocalDirectoryBackupTarget(this.directoryProvider);

  final Future<Directory> Function() directoryProvider;

  @override
  String get id => 'local';

  @override
  String get label => '本地备份目录';

  @override
  Capability get capability =>
      const Capability(CapabilityState.available, '应用本地备份目录可用');

  static String _validateFileName(String fileName) {
    final trimmed = fileName.trim();
    if (trimmed.isEmpty ||
        trimmed == '.' ||
        trimmed == '..' ||
        trimmed.contains('/') ||
        trimmed.contains(r'\') ||
        trimmed.contains('\x00')) {
      throw Failure(FailureCode.validation, '非法的备份文件名：$fileName');
    }
    return trimmed;
  }

  static Future<T> _runRootIo<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    Zone.root.run(() async {
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  @override
  Future<List<BackupFileMetadata>> listBackups() => _runRootIo(() async {
    final dir = await directoryProvider();
    if (!await dir.exists()) return const <BackupFileMetadata>[];

    final items = <BackupFileMetadata>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      final lower = name.toLowerCase();
      if (lower.endsWith('.tmp')) continue;
      if (!lower.endsWith('.tally') && !lower.endsWith('.tallyzip')) continue;

      final stat = await entity.stat();
      TallyManifest? manifest;
      try {
        final manifestEntry = await ZipArchive.readSingleEntryFromFile(
          entity,
          tallyManifestFileName,
        );
        if (manifestEntry != null) {
          final decoded = jsonDecode(utf8.decode(manifestEntry.bytes));
          if (decoded is Map<String, Object?>) {
            manifest = TallyManifest.fromJson(decoded);
          }
        }
      } catch (_) {
        // Keep listing resilient even if a file is corrupted; restore will report exact error.
      }
      items.add(
        BackupFileMetadata(
          fileName: name,
          sizeBytes: stat.size,
          modifiedAtMs:
              manifest?.createdAtMs ?? stat.modified.millisecondsSinceEpoch,
          manifest: manifest,
        ),
      );
    }

    items.sort((a, b) {
      final byTime = b.modifiedAtMs.compareTo(a.modifiedAtMs);
      if (byTime != 0) return byTime;
      return compareBackupFileNamesNewestFirst(a.fileName, b.fileName);
    });
    return items;
  });

  @override
  Future<BackupFileMetadata> writeBackup(
    String fileName,
    Uint8List bytes, {
    BackupProgressCallback? onProgress,
  }) => _runRootIo(() async {
    final cleanName = _validateFileName(fileName);
    final dir = await directoryProvider();
    await dir.create(recursive: true);

    final tmpFile = File(p.join(dir.path, '$cleanName.tmp'));
    final finalFile = File(p.join(dir.path, cleanName));
    try {
      await tmpFile.writeAsBytes(bytes, flush: true);
      onProgress?.call(bytes.length, bytes.length);
      if (await finalFile.exists()) {
        await finalFile.delete();
      }
      await tmpFile.rename(finalFile.path);
    } catch (_) {
      try {
        if (await tmpFile.exists()) await tmpFile.delete();
      } catch (_) {}
      throw const Failure(FailureCode.storageUnavailable, '写入本地备份文件失败');
    }

    TallyManifest? manifest;
    try {
      manifest = extractTallyManifestOnly(bytes);
    } catch (_) {}

    final stat = await finalFile.stat();
    return BackupFileMetadata(
      fileName: cleanName,
      sizeBytes: stat.size,
      modifiedAtMs:
          manifest?.createdAtMs ?? stat.modified.millisecondsSinceEpoch,
      manifest: manifest,
    );
  });

  @override
  Future<Uint8List> readBackup(
    String fileName, {
    BackupProgressCallback? onProgress,
  }) => _runRootIo(() async {
    final cleanName = _validateFileName(fileName);
    final dir = await directoryProvider();
    final file = File(p.join(dir.path, cleanName));
    if (!await file.exists()) {
      throw const Failure(FailureCode.storageUnavailable, '本地备份文件不存在');
    }
    final bytes = await file.readAsBytes();
    onProgress?.call(bytes.length, bytes.length);
    return bytes;
  });

  @override
  Future<void> deleteBackup(String fileName) => _runRootIo(() async {
    final cleanName = _validateFileName(fileName);
    final dir = await directoryProvider();
    final file = File(p.join(dir.path, cleanName));
    if (await file.exists()) {
      await file.delete();
    }
  });
}

/// User-authorized external backup directory implementation of [BackupTarget]
/// surviving app uninstall/reinstall across Android SAF, iOS Files Bookmark,
/// HarmonyOS NEXT Download folder, macOS App-Scoped Bookmark, Windows, and Linux.
final class ExternalDirectoryBackupTarget implements BackupTarget {
  ExternalDirectoryBackupTarget(
    this.binding, {
    required this.fileAccess,
    int Function()? nowMs,
  }) : _nowMs = nowMs;

  final ExternalBackupDirBinding binding;
  final FileAccess fileAccess;
  final int Function()? _nowMs;

  @override
  String get id => 'external_local';

  @override
  String get label => '外部安全备份目录（${binding.displayPath}）';

  @override
  Capability get capability => fileAccess.externalBackupDirCapability;

  @override
  Future<List<BackupFileMetadata>> listBackups() async {
    final entries = await fileAccess.listExternalDirectoryFiles(binding);
    final items = <BackupFileMetadata>[];

    for (final entry in entries) {
      final name = entry.fileName.trim();
      final lower = name.toLowerCase();
      if (lower.endsWith('.tmp')) continue;
      if (!lower.endsWith('.tally') && !lower.endsWith('.tallyzip')) continue;

      TallyManifest? manifest;
      try {
        if (binding.mode == ExternalBackupDirMode.path &&
            !fileAccess.hasCustomDirectoryReadHandler) {
          final manifestEntry = await LocalDirectoryBackupTarget._runRootIo(
            () => ZipArchive.readSingleEntryFromFile(
              File(p.join(binding.locator, name)),
              tallyManifestFileName,
            ),
          );
          if (manifestEntry != null) {
            final decoded = jsonDecode(utf8.decode(manifestEntry.bytes));
            if (decoded is Map<String, Object?>) {
              manifest = TallyManifest.fromJson(decoded);
            }
          }
        }
        // Note: For SAF / Bookmark / Ohos channels without random-access seek,
        // NEVER read & inflate full multi-hundred-MB `.tally` archives during
        // directory listing (which causes mobile OOMs). Rely on filename/stat
        // timestamps until actual restore!
      } catch (_) {
        // Keep listing resilient even if a file is corrupted; restore reports exact error.
      }

      final fallbackTs = entry.modifiedAtMs > 0
          ? entry.modifiedAtMs
          : (WebDavClient.parseTimestampFromFileName(name) ?? 0);
      items.add(
        BackupFileMetadata(
          fileName: name,
          sizeBytes: entry.sizeBytes,
          modifiedAtMs: manifest?.createdAtMs ?? fallbackTs,
          manifest: manifest,
        ),
      );
    }

    items.sort((a, b) {
      final byTime = b.modifiedAtMs.compareTo(a.modifiedAtMs);
      if (byTime != 0) return byTime;
      return compareBackupFileNamesNewestFirst(a.fileName, b.fileName);
    });
    return items;
  }

  @override
  Future<BackupFileMetadata> writeBackup(
    String fileName,
    Uint8List bytes, {
    BackupProgressCallback? onProgress,
  }) async {
    final cleanName = LocalDirectoryBackupTarget._validateFileName(fileName);
    await fileAccess.writeExternalDirectoryFile(binding, cleanName, bytes);
    onProgress?.call(bytes.length, bytes.length);

    TallyManifest? manifest;
    try {
      manifest = extractTallyManifestOnly(bytes);
    } catch (_) {}

    final fallbackNow = _nowMs?.call() ?? DateTime.now().millisecondsSinceEpoch;
    return BackupFileMetadata(
      fileName: cleanName,
      sizeBytes: bytes.length,
      modifiedAtMs: manifest?.createdAtMs ?? fallbackNow,
      manifest: manifest,
    );
  }

  @override
  Future<Uint8List> readBackup(
    String fileName, {
    BackupProgressCallback? onProgress,
  }) async {
    final cleanName = LocalDirectoryBackupTarget._validateFileName(fileName);
    final bytes = await fileAccess.readExternalDirectoryFile(
      binding,
      cleanName,
    );
    onProgress?.call(bytes.length, bytes.length);
    return bytes;
  }

  @override
  Future<void> deleteBackup(String fileName) async {
    final cleanName = LocalDirectoryBackupTarget._validateFileName(fileName);
    await fileAccess.deleteExternalDirectoryFile(binding, cleanName);
  }
}

/// Core backup, 3-stage atomic restore, and WebDAV orchestration service
/// (`F-035`, `ADR-017`, `docs/modules/backup-webdav.md`).
final class TallyBackupService {
  TallyBackupService(
    this.db, {
    required this.reminderService,
    Future<Directory> Function()? localBackupsDirectoryProvider,
    Future<Directory> Function()? attachmentsDirectoryProvider,
    FileAccess? fileAccess,
    this.httpClientFactory,
    this.appVersion = appVersionName,
    this.beforeAttachmentSwapFinalizeForTest,
    this.maxInlineConflictAttachmentBytes =
        defaultMaxInlineConflictAttachmentBytes,
    this.isolateOffloadRowThreshold = defaultIsolateOffloadRowThreshold,
  }) : hasCustomLocalDirOverride = localBackupsDirectoryProvider != null,
       _localBackupsDirProvider =
           localBackupsDirectoryProvider ?? _defaultBackupsDirectory,
       _attachmentsDirProvider =
           attachmentsDirectoryProvider ?? _defaultAttachmentsDirectory,
       _fileAccess = fileAccess ?? const FileAccess();

  final AppDatabase db;
  final ReminderService reminderService;
  final bool hasCustomLocalDirOverride;
  final Future<Directory> Function() _localBackupsDirProvider;
  final Future<Directory> Function() _attachmentsDirProvider;
  final FileAccess _fileAccess;
  final HttpClient Function()? httpClientFactory;
  final String appVersion;
  FutureOr<void> Function()? beforeAttachmentSwapFinalizeForTest;
  int maxInlineConflictAttachmentBytes;
  int isolateOffloadRowThreshold;

  late final LocalDirectoryBackupTarget localTarget =
      LocalDirectoryBackupTarget(_localBackupsDirProvider);

  String? _cachedFallbackDeviceId;
  Future<void>? _startupSelfHealFuture;
  Future<void> _exclusiveChain = Future<void>.value();
  int _attachmentSwapSeq = 0;
  int _internalRestoreDepth = 0;
  int _silentMaintenanceDepth = 0;
  int _attachedSchedulerCount = 0;
  int _activeSyncCount = 0;
  final StreamController<bool> _syncInProgressController =
      StreamController<bool>.broadcast();
  final StreamController<void> _manualSyncOrConfigResetController =
      StreamController<void>.broadcast();

  // Cached remote targets preserving verified WebDAV collection paths across ticks.
  String? _cachedWebDavConfigKey;
  WebDavBackupTarget? _cachedWebDavTarget;
  String? _cachedS3ConfigKey;
  S3BackupTarget? _cachedS3Target;

  // Incremental attachment hash cache + SQLite dirty tracking for 0-SQL clean probes.
  Map<String, ({int size, int modifiedMs, String sha256})>? _attHashCache;
  // ignore: cancel_subscriptions
  StreamSubscription<Set<TableUpdate>>? _dirtyTableSub;
  bool _tablesPossiblyDirty = true;
  String? _cachedCanonicalStateSha256;
  String? _cachedLastAttachmentsSig;
  bool? _cachedIsLocalTablesFreshSeed;

  /// Single FIFO async mutex serializing [syncNow], manual/auto local backup,
  /// cloud backup upload, [runSilentAutoBackupIfNeeded], and [restoreFromBytes] (`S-07`).
  Future<T> _runExclusive<T>(Future<T> Function() action) {
    final prev = _exclusiveChain;
    final completer = Completer<T>();
    final gate = Completer<void>();
    _exclusiveChain = gate.future;
    unawaited(
      prev.then((_) async {
        try {
          final result = await action();
          completer.complete(result);
        } catch (e, st) {
          completer.completeError(e, st);
        } finally {
          gate.complete();
        }
      }),
    );
    return completer.future;
  }

  /// `true` whenever a foreground or background [syncNow] task is queued or active.
  bool get isSyncInProgress => _activeSyncCount > 0;

  /// Broadcasts changes in [isSyncInProgress] (starting with the current value).
  Stream<bool> watchSyncInProgress() async* {
    yield isSyncInProgress;
    yield* _syncInProgressController.stream.distinct();
  }

  /// `true` while [restoreFromBytes] or a remote sync pull/merge is replacing
  /// business tables, allowing [BackupSyncScheduler] to suppress table-change
  /// idle debounce loops.
  bool get isSuppressingTableChangeTriggers => _internalRestoreDepth > 0;

  /// `true` while silent background maintenance (online rate auto-sync or
  /// day-1 auto budget carryover) is executing so [BackupSyncScheduler] does
  /// not arm `syncOnIdle` on pure `{currency, budget}` maintenance writes.
  bool get isInSilentMaintenanceScope => _silentMaintenanceDepth > 0;

  /// Runs [action] inside a silent maintenance scope.
  Future<T> runInSilentMaintenanceScope<T>(Future<T> Function() action) async {
    _silentMaintenanceDepth++;
    try {
      return await action();
    } finally {
      await Future<void>.microtask(() {});
      await Future<void>.microtask(() {});
      if (_silentMaintenanceDepth > 0) {
        _silentMaintenanceDepth--;
      }
    }
  }

  /// Emits whenever a manual foreground `syncNow()` succeeds or cloud
  /// credentials are updated, resetting scheduler backoff / auth circuit break.
  Stream<void> watchManualResetSignals() =>
      _manualSyncOrConfigResetController.stream;

  void _emitManualResetSignal() {
    if (!_manualSyncOrConfigResetController.isClosed) {
      _manualSyncOrConfigResetController.add(null);
    }
  }

  /// `true` when an app-level [BackupSyncScheduler] is actively managing
  /// lifecycle and idle triggers for this service instance.
  bool get hasAttachedScheduler => _attachedSchedulerCount > 0;

  void registerAttachedScheduler() {
    _attachedSchedulerCount++;
    _ensureDirtyTrackingSubscription();
  }

  void unregisterAttachedScheduler() {
    if (_attachedSchedulerCount > 0) {
      _attachedSchedulerCount--;
    }
    if (_attachedSchedulerCount == 0) {
      final sub = _dirtyTableSub;
      _dirtyTableSub = null;
      if (sub != null) {
        unawaited(sub.cancel());
      }
    }
  }

  void _ensureDirtyTrackingSubscription() {
    if (_dirtyTableSub != null) return;
    final watchedNames = tallyBusinessTables.toSet();
    _dirtyTableSub = db.tableUpdates().listen(
      (updates) {
        if (updates.any((u) => watchedNames.contains(u.table))) {
          _tablesPossiblyDirty = true;
        }
      },
      onDone: () {
        _dirtyTableSub = null;
      },
      cancelOnError: false,
    );
  }

  void _invalidateLocalTableDigestCache() {
    _tablesPossiblyDirty = true;
    _cachedCanonicalStateSha256 = null;
    _cachedLastAttachmentsSig = null;
    _cachedIsLocalTablesFreshSeed = null;
  }

  Future<void> _pruneExpiredWriteCommandsBestEffort([
    int? nowOverrideMs,
  ]) async {
    try {
      final cutoffMs =
          (nowOverrideMs ?? _nowMs()) - defaultWriteCommandRetentionMs;
      await (db.delete(
        db.writeCommands,
      )..where((t) => t.committedAt.isSmallerThanValue(cutoffMs))).go();
    } catch (_) {}
  }

  Future<void>
  _ensureSandboxSelfHealedOnce() => _startupSelfHealFuture ??= () async {
    final now = _nowMs();
    await LocalDirectoryBackupTarget._runRootIo(() async {
      const staleCutoffMs = 60 * 60 * 1000; // 1 hour

      try {
        final rawAtt = await _attachmentsDirProvider();
        final attDir = Directory(p.normalize(rawAtt.path));
        final parentDir = attDir.parent;
        if (await parentDir.exists()) {
          final bakDirs = <({Directory dir, int modMs})>[];
          final staleDirs = <Directory>[];
          await for (final entity in parentDir.list(followLinks: false)) {
            if (entity is! Directory) continue;
            final normPath = p.normalize(entity.path);
            final isBak = normPath.startsWith('${attDir.path}.bak_');
            final isStaging = normPath.startsWith('${attDir.path}.staging_');
            if (!isBak && !isStaging) continue;
            final stat = await entity.stat();
            final modMs = stat.modified.millisecondsSinceEpoch;
            if (isBak) {
              bakDirs.add((dir: entity, modMs: modMs));
            }
            if ((now - modMs) >= staleCutoffMs) {
              staleDirs.add(entity);
            }
          }
          // Power-loss self-healing:
          // 1) Full directory swap interrupted -> restore newest `.bak_*`.
          // 2) Incremental swap interrupted (`.in_progress` marker present) ->
          //    rescue any moved-out files missing from live `attDir`.
          if (!await attDir.exists() && bakDirs.isNotEmpty) {
            bakDirs.sort((a, b) => b.modMs.compareTo(a.modMs));
            final rescued = bakDirs.first.dir;
            await rescued.rename(attDir.path);
            staleDirs.removeWhere((d) => d.path == rescued.path);
          } else if (await attDir.exists() && bakDirs.isNotEmpty) {
            bakDirs.sort((a, b) => b.modMs.compareTo(a.modMs));
            for (final item in bakDirs) {
              final marker = File(p.join(item.dir.path, '.in_progress'));
              if (!await marker.exists()) continue;
              await for (final ent in item.dir.list(
                recursive: true,
                followLinks: false,
              )) {
                if (ent is! File) continue;
                final rel = p.relative(ent.path, from: item.dir.path);
                if (rel == '.in_progress') continue;
                final liveFile = File(p.join(attDir.path, rel));
                if (!await liveFile.exists()) {
                  await liveFile.parent.create(recursive: true);
                  await ent.rename(liveFile.path);
                }
              }
              try {
                await item.dir.delete(recursive: true);
              } catch (_) {}
              staleDirs.removeWhere((d) => d.path == item.dir.path);
            }
          }
          for (final d in staleDirs) {
            try {
              if (await d.exists()) await d.delete(recursive: true);
            } catch (_) {}
          }
        }

        if (await attDir.exists()) {
          await for (final entity in attDir.list(
            recursive: true,
            followLinks: false,
          )) {
            if (entity is! File) continue;
            if (!entity.path.toLowerCase().endsWith('.tmp')) continue;
            final stat = await entity.stat();
            if ((now - stat.modified.millisecondsSinceEpoch) >= staleCutoffMs) {
              try {
                await entity.delete();
              } catch (_) {}
            }
          }
        }
      } catch (_) {}

      try {
        final bkDir = await _localBackupsDirProvider();
        if (await bkDir.exists()) {
          await for (final entity in bkDir.list(followLinks: false)) {
            if (entity is! File) continue;
            if (!entity.path.toLowerCase().endsWith('.tmp')) continue;
            final stat = await entity.stat();
            if ((now - stat.modified.millisecondsSinceEpoch) >= staleCutoffMs) {
              try {
                await entity.delete();
              } catch (_) {}
            }
          }
        }
      } catch (_) {}
    });
    await _pruneExpiredWriteCommandsBestEffort(now);
  }();

  static Directory? _headlessSupportRoot;

  /// Allows headless widget tests exercising default `!hasCustomLocalDirOverride`
  /// flows to pin the fallback sandbox root inside a per-test temporary folder.
  static void setHeadlessSupportRootForTest(Directory? directory) {
    _headlessSupportRoot = directory;
  }

  static Future<Directory> _resolveSupportRoot() =>
      LocalDirectoryBackupTarget._runRootIo<Directory>(() async {
        final pinnedOrCached = _headlessSupportRoot;
        if (Platform.environment['FLUTTER_TEST'] == 'true') {
          if (pinnedOrCached != null) {
            if (!await pinnedOrCached.exists()) {
              await pinnedOrCached.create(recursive: true);
            }
            return pinnedOrCached;
          }
          final created = await Directory.systemTemp.createTemp(
            'tallyisle_support_',
          );
          _headlessSupportRoot = created;
          return created;
        }
        try {
          return await getApplicationSupportDirectory();
        } on MissingPluginException {
          if (pinnedOrCached != null && await pinnedOrCached.exists()) {
            return pinnedOrCached;
          }
          final created = await Directory.systemTemp.createTemp(
            'tallyisle_support_',
          );
          _headlessSupportRoot = created;
          return created;
        }
      });

  static Future<Directory> _defaultBackupsDirectory() async {
    final support = await _resolveSupportRoot();
    return Directory(p.join(support.path, 'backups'));
  }

  static Future<Directory> _defaultAttachmentsDirectory() async {
    final support = await _resolveSupportRoot();
    return Directory(p.join(support.path, 'attachments'));
  }

  int _nowMs() => db.nowMs();

  String _ensureFallbackDeviceId() =>
      _cachedFallbackDeviceId ??= generateSyncDeviceId();

  static String _currentPlatformLabel() {
    if (Platform.operatingSystem == 'ohos') return 'HarmonyOS';
    if (Platform.isAndroid) return 'Android';
    if (Platform.isIOS) return 'iOS';
    if (Platform.isMacOS) return 'macOS';
    if (Platform.isWindows) return 'Windows';
    if (Platform.isLinux) return 'Linux';
    return 'Device';
  }

  String _ensureFallbackDeviceName([String? deviceId]) {
    final id = deviceId ?? _ensureFallbackDeviceId();
    return defaultSyncDeviceNameForPlatform(
      platformLabel: _currentPlatformLabel(),
      deviceId: id,
    );
  }

  /// Reactive stream of [WebDavConfig] from `ti_preference`.
  Stream<WebDavConfig> watchWebDavConfig() =>
      (db.select(db.preferences)
            ..where((t) => t.key.equals(prefKeyWebDavConfig)))
          .watchSingleOrNull()
          .map((row) => _decodeWebDavConfig(row?.value));

  /// Current [WebDavConfig] snapshot (returns [WebDavConfig.unconfigured] if unset).
  Future<WebDavConfig> getWebDavConfig() async {
    final row = await guardDatabase(
      () => (db.select(
        db.preferences,
      )..where((t) => t.key.equals(prefKeyWebDavConfig))).getSingleOrNull(),
    );
    return _decodeWebDavConfig(row?.value);
  }

  static WebDavConfig _decodeWebDavConfig(String? raw) {
    if (raw == null || raw.isEmpty) return const WebDavConfig.unconfigured();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        return WebDavConfig.fromJson(decoded);
      }
    } catch (_) {}
    return const WebDavConfig.unconfigured();
  }

  /// Reactive stream of [S3Config] from `ti_preference`.
  Stream<S3Config> watchS3Config() =>
      (db.select(db.preferences)..where((t) => t.key.equals(prefKeyS3Config)))
          .watchSingleOrNull()
          .map((row) => _decodeS3Config(row?.value));

  /// Current [S3Config] snapshot (returns [S3Config.unconfigured] if unset).
  Future<S3Config> getS3Config() async {
    final row = await guardDatabase(
      () => (db.select(
        db.preferences,
      )..where((t) => t.key.equals(prefKeyS3Config))).getSingleOrNull(),
    );
    return _decodeS3Config(row?.value);
  }

  static S3Config _decodeS3Config(String? raw) {
    if (raw == null || raw.isEmpty) return const S3Config.unconfigured();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        return S3Config.fromJson(decoded);
      }
    } catch (_) {}
    return const S3Config.unconfigured();
  }

  /// Reactive stream of effective [CloudSyncSettings], seamlessly recognizing
  /// previously configured [WebDavConfig] when `cloud_sync_settings` is unset.
  Stream<CloudSyncSettings> watchCloudSyncSettings() {
    final keys = <String>[prefKeyCloudSyncSettings, prefKeyWebDavConfig];
    return (db.select(
      db.preferences,
    )..where((t) => t.key.isIn(keys))).watch().map((rows) {
      String? rawSync;
      String? rawDav;
      for (final r in rows) {
        if (r.key == prefKeyCloudSyncSettings) rawSync = r.value;
        if (r.key == prefKeyWebDavConfig) rawDav = r.value;
      }
      final davCfg = _decodeWebDavConfig(rawDav);
      final fbId = _ensureFallbackDeviceId();
      return resolveEffectiveCloudSyncSettings(
        rawJson: rawSync,
        isWebDavConfigured: davCfg.isConfigured,
        fallbackDeviceId: fbId,
        fallbackDeviceName: _ensureFallbackDeviceName(fbId),
      );
    });
  }

  /// Reads effective [CloudSyncSettings] without mutating the database.
  Future<CloudSyncSettings> getCloudSyncSettings() async {
    final rows = await guardDatabase(
      () =>
          (db.select(db.preferences)..where(
                (t) => t.key.isIn(<String>[
                  prefKeyCloudSyncSettings,
                  prefKeyWebDavConfig,
                ]),
              ))
              .get(),
    );
    String? rawSync;
    String? rawDav;
    for (final r in rows) {
      if (r.key == prefKeyCloudSyncSettings) rawSync = r.value;
      if (r.key == prefKeyWebDavConfig) rawDav = r.value;
    }
    final davCfg = _decodeWebDavConfig(rawDav);
    final fbId = _ensureFallbackDeviceId();
    return resolveEffectiveCloudSyncSettings(
      rawJson: rawSync,
      isWebDavConfigured: davCfg.isConfigured,
      fallbackDeviceId: fbId,
      fallbackDeviceName: _ensureFallbackDeviceName(fbId),
    );
  }

  /// Persists [settings] to `ti_preference` (`cloud_sync_settings`).
  Future<void> saveCloudSyncSettings(CloudSyncSettings settings) async {
    final effId = settings.deviceId.trim().isEmpty
        ? _ensureFallbackDeviceId()
        : settings.deviceId.trim();
    final normalized = settings.copyWith(
      deviceId: effId,
      deviceName: settings.deviceName.trim().isEmpty
          ? _ensureFallbackDeviceName(effId)
          : settings.deviceName.trim(),
    );
    await guardDatabase(
      () => db
          .into(db.preferences)
          .insertOnConflictUpdate(
            PreferencesCompanion.insert(
              key: prefKeyCloudSyncSettings,
              value: jsonEncode(normalized.toJson()),
            ),
          ),
    );
  }

  /// Updates the human-readable [deviceName] shown in sync headers and
  /// multi-device conflict comparison dialogs (`1–40` characters).
  Future<CloudSyncSettings> updateSyncDeviceName(String newName) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty || trimmed.runes.length > 40) {
      throw const Failure(FailureCode.validation, '设备标识名称须为 1–40 个字符');
    }
    final current = await getCloudSyncSettings();
    final updated = current.copyWith(deviceName: trimmed);
    await saveCloudSyncSettings(updated);
    return updated;
  }

  /// Switches the active cloud backend (`none` / `webdav` / `s3`).
  Future<void> setCloudBackend(CloudBackendType backend) async {
    final current = await getCloudSyncSettings();
    final updated = current.copyWith(
      backend: backend,
      explicitBackend: true,
      autoSyncEnabled: backend == CloudBackendType.none
          ? false
          : current.autoSyncEnabled,
    );
    await saveCloudSyncSettings(updated);
  }

  /// Updates mobile quick-entry visibility switches in `ti_preference`
  /// (`cloud_sync_settings`) without requiring a configured cloud backend.
  Future<void> updateQuickEntryVisibility({
    bool? showHomeQuickEntry,
    bool? showMeQuickEntry,
  }) async {
    final current = await getCloudSyncSettings();
    final updated = current.copyWith(
      showHomeQuickEntry: showHomeQuickEntry,
      showMeQuickEntry: showMeQuickEntry,
    );
    await saveCloudSyncSettings(updated);
  }

  /// Reactive stream of [LocalAutoBackupPolicy] from `ti_preference`.
  Stream<LocalAutoBackupPolicy> watchLocalAutoBackupPolicy() =>
      (db.select(db.preferences)
            ..where((t) => t.key.equals(prefKeyLocalAutoBackupPolicy)))
          .watchSingleOrNull()
          .map((row) => resolveLocalAutoBackupPolicy(row?.value));

  /// Reads current [LocalAutoBackupPolicy] snapshot (defaults to all `false`).
  Future<LocalAutoBackupPolicy> getLocalAutoBackupPolicy() async {
    final row = await guardDatabase(
      () =>
          (db.select(db.preferences)
                ..where((t) => t.key.equals(prefKeyLocalAutoBackupPolicy)))
              .getSingleOrNull(),
    );
    return resolveLocalAutoBackupPolicy(row?.value);
  }

  /// Validates and persists [policy] to `ti_preference` (`local_auto_backup_policy`).
  Future<void> saveLocalAutoBackupPolicy(LocalAutoBackupPolicy policy) async {
    if (policy.keepCount < 1 || policy.keepCount > 200) {
      throw const Failure(FailureCode.validation, '本地备份保留份数须在 1–200 之间');
    }
    await guardDatabase(
      () => db
          .into(db.preferences)
          .insertOnConflictUpdate(
            PreferencesCompanion.insert(
              key: prefKeyLocalAutoBackupPolicy,
              value: jsonEncode(policy.toJson()),
            ),
          ),
    );
  }

  /// Reactive stream of [ExternalBackupDirBinding] from `ti_preference`.
  Stream<ExternalBackupDirBinding?> watchExternalBackupDirBinding() =>
      (db.select(db.preferences)
            ..where((t) => t.key.equals(prefKeyExternalBackupDirBinding)))
          .watchSingleOrNull()
          .map((row) => ExternalBackupDirBinding.tryDecode(row?.value));

  /// Current [ExternalBackupDirBinding] snapshot (`null` when unbound).
  Future<ExternalBackupDirBinding?> getExternalBackupDirBinding() async {
    final row = await guardDatabase(
      () =>
          (db.select(db.preferences)
                ..where((t) => t.key.equals(prefKeyExternalBackupDirBinding)))
              .getSingleOrNull(),
    );
    return ExternalBackupDirBinding.tryDecode(row?.value);
  }

  /// Reactive stream indicating whether the bound external directory became
  /// inaccessible (e.g. unplugged drive or revoked permission) and fell back to sandbox.
  Stream<bool> watchExternalBackupNeedsRebind() =>
      (db.select(db.preferences)
            ..where((t) => t.key.equals(prefKeyExternalBackupDirNeedsRebind)))
          .watchSingleOrNull()
          .map((row) => row?.value == 'true');

  /// Current `needsRebind` flag snapshot.
  Future<bool> getExternalBackupNeedsRebind() async {
    final row = await guardDatabase(
      () =>
          (db.select(db.preferences)..where(
                (t) => t.key.equals(prefKeyExternalBackupDirNeedsRebind),
              ))
              .getSingleOrNull(),
    );
    return row?.value == 'true';
  }

  Future<void> _setExternalBackupNeedsRebindIfChanged(bool needsRebind) async {
    final current = await getExternalBackupNeedsRebind();
    if (current == needsRebind) return;
    await guardDatabase(
      () => db
          .into(db.preferences)
          .insertOnConflictUpdate(
            PreferencesCompanion.insert(
              key: prefKeyExternalBackupDirNeedsRebind,
              value: needsRebind ? 'true' : 'false',
            ),
          ),
    );
  }

  /// Prompts the user to pick/authorize an external `.tally` backup directory,
  /// migrates any existing `.tally`/`.tallyzip` files from the app sandbox
  /// directory into the newly bound external directory (without overwriting
  /// files already present), persists the binding, and clears `needsRebind`.
  Future<ExternalBackupDirBinding> bindExternalBackupDirectory({
    FileAccess? fileAccess,
    String? initialDirectory,
  }) async {
    final access = fileAccess ?? _fileAccess;
    String? effectiveInitial = initialDirectory;
    if (effectiveInitial == null) {
      final prev = await getExternalBackupDirBinding();
      if (prev != null && prev.mode == ExternalBackupDirMode.path) {
        effectiveInitial = prev.locator;
      }
    }

    final picked = await access.pickExternalBackupDirectory(
      initialDirectory: effectiveInitial,
      nowMs: _nowMs(),
    );

    return _runExclusive(() async {
      if (picked.mode == ExternalBackupDirMode.path &&
          !access.hasCustomDirectoryCheckHandler &&
          !access.hasCustomDirectoryWriteHandler) {
        await LocalDirectoryBackupTarget._runRootIo(() async {
          final dir = Directory(picked.locator);
          if (!await dir.exists() && await dir.parent.exists()) {
            await dir.create();
          }
        });
      }

      final accessible = await access.checkExternalDirectoryAccessible(picked);
      if (!accessible) {
        throw const Failure(
          FailureCode.storageUnavailable,
          '所选外部备份目录不可访问或无读写权限',
        );
      }

      // Migrate any legacy/fallback `.tally`/`.tallyzip` backups from app sandbox
      // one file at a time (never reading all archives into a single RAM list).
      final extEntries = await access.listExternalDirectoryFiles(picked);
      final existingExtNames = <String>{
        for (final entry in extEntries) entry.fileName,
      };
      final sandboxCandidates = await LocalDirectoryBackupTarget._runRootIo(
        () async {
          final sandboxDir = await _localBackupsDirProvider();
          if (!await sandboxDir.exists()) {
            return const <({String name, String path})>[];
          }
          final collected = <({String name, String path})>[];
          await for (final entity in sandboxDir.list(followLinks: false)) {
            if (entity is! File) continue;
            final name = p.basename(entity.path);
            final lower = name.toLowerCase();
            if (lower.endsWith('.tmp')) continue;
            if (!lower.endsWith('.tally') && !lower.endsWith('.tallyzip')) {
              continue;
            }
            if (existingExtNames.contains(name)) continue;
            collected.add((name: name, path: entity.path));
          }
          return collected;
        },
      );
      for (final candidate in sandboxCandidates) {
        final bytes = await LocalDirectoryBackupTarget._runRootIo(() async {
          final f = File(candidate.path);
          if (!await f.exists()) return null;
          return f.readAsBytes();
        });
        if (bytes != null) {
          await access.writeExternalDirectoryFile(
            picked,
            candidate.name,
            bytes,
          );
        }
      }

      await guardDatabase(
        () => db.transaction(() async {
          await db
              .into(db.preferences)
              .insertOnConflictUpdate(
                PreferencesCompanion.insert(
                  key: prefKeyExternalBackupDirBinding,
                  value: picked.encode(),
                ),
              );
          await db
              .into(db.preferences)
              .insertOnConflictUpdate(
                PreferencesCompanion.insert(
                  key: prefKeyExternalBackupDirNeedsRebind,
                  value: 'false',
                ),
              );
        }),
      );
      return picked;
    });
  }

  /// Opens the currently bound external backup directory in the desktop file manager.
  Future<void> openBoundExternalBackupDirectory({
    FileAccess? fileAccess,
  }) async {
    final binding = await getExternalBackupDirBinding();
    if (binding == null) {
      throw const Failure(FailureCode.validation, '尚未绑定外部备份目录');
    }
    await (fileAccess ?? _fileAccess).openBackupDirectory(binding);
  }

  Future<
    ({
      BackupTarget target,
      ExternalBackupDirBinding? externalBinding,
      bool fellBackToSandbox,
    })
  >
  _resolveActiveLocalTarget() async {
    final binding = await getExternalBackupDirBinding();
    if (binding == null) {
      return (
        target: localTarget,
        externalBinding: null,
        fellBackToSandbox: false,
      );
    }
    final accessible = await _fileAccess.checkExternalDirectoryAccessible(
      binding,
    );
    if (accessible) {
      await _setExternalBackupNeedsRebindIfChanged(false);
      return (
        target: ExternalDirectoryBackupTarget(
          binding,
          fileAccess: _fileAccess,
          nowMs: _nowMs,
        ),
        externalBinding: binding,
        fellBackToSandbox: false,
      );
    }
    await _setExternalBackupNeedsRebindIfChanged(true);
    return (
      target: localTarget,
      externalBinding: null,
      fellBackToSandbox: true,
    );
  }

  Future<void> _ensureCloudBackendConfigured(CloudBackendType backend) async {
    if (backend == CloudBackendType.none) {
      throw const Failure(FailureCode.validation, '请先选择并配置 WebDAV 或 S3 云存储通道');
    }
    if (backend == CloudBackendType.webdav) {
      final dav = await getWebDavConfig();
      if (!dav.isConfigured) {
        throw const Failure(FailureCode.validation, '请先完成 WebDAV 配置再开启自动同步');
      }
    } else if (backend == CloudBackendType.s3) {
      final s3 = await getS3Config();
      if (!s3.isConfigured) {
        throw const Failure(FailureCode.validation, '请先完成 S3 配置再开启自动同步');
      }
    }
  }

  /// Updates any combination of multi-device cloud sync trigger options cleanly.
  Future<CloudSyncSettings> updateCloudSyncTriggers({
    bool? syncOnStartup,
    bool? syncOnExit,
    bool? syncOnIdle,
    int? idleMinutes,
    bool? syncOnSchedule,
    int? scheduleIntervalMinutes,
    bool? autoArchiveBackupEnabled,
  }) async {
    final current = await getCloudSyncSettings();
    final updated = current.copyWith(
      syncOnStartup: syncOnStartup,
      syncOnExit: syncOnExit,
      syncOnIdle: syncOnIdle,
      idleMinutes: idleMinutes,
      syncOnSchedule: syncOnSchedule,
      scheduleIntervalMinutes: scheduleIntervalMinutes,
      autoArchiveBackupEnabled: autoArchiveBackupEnabled,
    );
    final enablingNewTrigger =
        (syncOnStartup == true && !current.syncOnStartup) ||
        (syncOnExit == true && !current.syncOnExit) ||
        (syncOnIdle == true && !current.syncOnIdle) ||
        (syncOnSchedule == true && !current.syncOnSchedule);
    if (enablingNewTrigger ||
        (!current.autoSyncEnabled && updated.autoSyncEnabled)) {
      await _ensureCloudBackendConfigured(updated.backend);
    }
    await saveCloudSyncSettings(updated);
    return updated;
  }

  /// Enables or disables automatic multi-device cloud sync on app resume/exit.
  Future<void> setAutoSyncEnabled(bool enabled) async {
    final settings = await getCloudSyncSettings();
    if (enabled) {
      await _ensureCloudBackendConfigured(settings.backend);
    }
    await saveCloudSyncSettings(settings.copyWith(autoSyncEnabled: enabled));
  }

  /// Enables or disables 24h full `.tally` archive generation during sync pushes.
  Future<void> setAutoArchiveBackupEnabled(bool enabled) async {
    final settings = await getCloudSyncSettings();
    await saveCloudSyncSettings(
      settings.copyWith(autoArchiveBackupEnabled: enabled),
    );
  }

  /// Reactive stream of [LocalSyncCursor] from `ti_preference`.
  Stream<LocalSyncCursor> watchSyncCursor() =>
      (db.select(db.preferences)
            ..where((t) => t.key.equals(prefKeyCloudSyncCursor)))
          .watchSingleOrNull()
          .map((row) => _decodeSyncCursor(row?.value));

  /// Current [LocalSyncCursor] snapshot.
  Future<LocalSyncCursor> getSyncCursor() async {
    final row = await guardDatabase(
      () => (db.select(
        db.preferences,
      )..where((t) => t.key.equals(prefKeyCloudSyncCursor))).getSingleOrNull(),
    );
    return _decodeSyncCursor(row?.value);
  }

  static LocalSyncCursor _decodeSyncCursor(String? raw) {
    if (raw == null || raw.isEmpty) return const LocalSyncCursor.initial();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        return LocalSyncCursor.fromJson(decoded);
      }
    } catch (_) {}
    return const LocalSyncCursor.initial();
  }

  Future<void> _saveSyncCursor(
    LocalSyncCursor cursor, {
    CloudSyncSettings? ensureSettings,
  }) => guardDatabase(
    () => db.transaction(() async {
      await db
          .into(db.preferences)
          .insertOnConflictUpdate(
            PreferencesCompanion.insert(
              key: prefKeyCloudSyncCursor,
              value: jsonEncode(cursor.toJson()),
            ),
          );
      if (ensureSettings != null) {
        await db
            .into(db.preferences)
            .insert(
              PreferencesCompanion.insert(
                key: prefKeyCloudSyncSettings,
                value: jsonEncode(ensureSettings.toJson()),
              ),
              mode: InsertMode.insertOrIgnore,
            );
      }
    }),
  );

  /// Validates and saves [config] to `ti_preference`.
  Future<void> saveWebDavConfig(WebDavConfig config) async {
    final trimmedUrl = config.serverUrl.trim();
    if (trimmedUrl.isNotEmpty ||
        config.username.trim().isNotEmpty ||
        config.password.isNotEmpty) {
      if (!config.isConfigured) {
        throw const Failure(
          FailureCode.validation,
          '请填写有效的 http/https 服务器地址、用户名与密码',
        );
      }
    }
    if (config.keepCount < 1 || config.keepCount > 200) {
      throw const Failure(FailureCode.validation, '备份保留份数须在 1–200 之间');
    }
    await guardDatabase(
      () => db.transaction(() async {
        final rawSyncRow =
            await (db.select(db.preferences)
                  ..where((t) => t.key.equals(prefKeyCloudSyncSettings)))
                .getSingleOrNull();
        final fbId = _ensureFallbackDeviceId();
        final settings = resolveEffectiveCloudSyncSettings(
          rawJson: rawSyncRow?.value,
          isWebDavConfigured: config.isConfigured,
          fallbackDeviceId: fbId,
          fallbackDeviceName: _ensureFallbackDeviceName(fbId),
        );
        await db
            .into(db.preferences)
            .insertOnConflictUpdate(
              PreferencesCompanion.insert(
                key: prefKeyWebDavConfig,
                value: jsonEncode(config.toJson()),
              ),
            );
        if (config.isConfigured &&
            rawSyncRow != null &&
            settings.backend == CloudBackendType.none &&
            !settings.explicitBackend) {
          await db
              .into(db.preferences)
              .insertOnConflictUpdate(
                PreferencesCompanion.insert(
                  key: prefKeyCloudSyncSettings,
                  value: jsonEncode(
                    settings
                        .copyWith(backend: CloudBackendType.webdav)
                        .toJson(),
                  ),
                ),
              );
        }
      }),
    );
    _cachedWebDavConfigKey = null;
    _cachedWebDavTarget = null;
    _emitManualResetSignal();
  }

  /// Clears WebDAV server credentials while keeping local export preferences.
  Future<void> clearWebDavConfig() async {
    await guardDatabase(
      () => db.transaction(() async {
        final rows =
            await (db.select(db.preferences)..where(
                  (t) => t.key.isIn(<String>[
                    prefKeyWebDavConfig,
                    prefKeyCloudSyncSettings,
                  ]),
                ))
                .get();
        String? rawDav;
        String? rawSync;
        for (final r in rows) {
          if (r.key == prefKeyWebDavConfig) rawDav = r.value;
          if (r.key == prefKeyCloudSyncSettings) rawSync = r.value;
        }
        final current = _decodeWebDavConfig(rawDav);
        final cleared = WebDavConfig(
          includeAttachments: current.includeAttachments,
          keepCount: current.keepCount,
        );
        await db
            .into(db.preferences)
            .insertOnConflictUpdate(
              PreferencesCompanion.insert(
                key: prefKeyWebDavConfig,
                value: jsonEncode(cleared.toJson()),
              ),
            );
        if (rawSync != null && rawSync.isNotEmpty) {
          final fbId = _ensureFallbackDeviceId();
          final settings = resolveEffectiveCloudSyncSettings(
            rawJson: rawSync,
            isWebDavConfigured: false,
            fallbackDeviceId: fbId,
            fallbackDeviceName: _ensureFallbackDeviceName(fbId),
          );
          if (settings.backend == CloudBackendType.webdav) {
            await db
                .into(db.preferences)
                .insertOnConflictUpdate(
                  PreferencesCompanion.insert(
                    key: prefKeyCloudSyncSettings,
                    value: jsonEncode(
                      settings
                          .copyWith(
                            backend: settings.explicitBackend
                                ? CloudBackendType.webdav
                                : CloudBackendType.none,
                            autoSyncEnabled: false,
                          )
                          .toJson(),
                    ),
                  ),
                );
          }
        }
      }),
    );
    _cachedWebDavConfigKey = null;
    _cachedWebDavTarget = null;
    _emitManualResetSignal();
  }

  /// Validates and saves [config] (`S3Config`) to `ti_preference`.
  Future<void> saveS3Config(S3Config config) async {
    final hasAnyInput =
        config.endpoint.trim().isNotEmpty ||
        config.bucket.trim().isNotEmpty ||
        config.accessKeyId.trim().isNotEmpty ||
        config.secretAccessKey.isNotEmpty;
    if (hasAnyInput && !config.isConfigured) {
      throw const Failure(
        FailureCode.validation,
        '请完整填写有效的 S3 Endpoint、Bucket、Access Key ID 与 Secret Access Key',
      );
    }
    normalizeS3Prefix(config.remotePrefix);
    if (config.keepCount < 1 || config.keepCount > 200) {
      throw const Failure(FailureCode.validation, '备份保留份数须在 1–200 之间');
    }
    await guardDatabase(
      () => db.transaction(() async {
        final rows =
            await (db.select(db.preferences)..where(
                  (t) => t.key.isIn(<String>[
                    prefKeyCloudSyncSettings,
                    prefKeyWebDavConfig,
                  ]),
                ))
                .get();
        String? rawSync;
        String? rawDav;
        for (final r in rows) {
          if (r.key == prefKeyCloudSyncSettings) rawSync = r.value;
          if (r.key == prefKeyWebDavConfig) rawDav = r.value;
        }
        final fbId = _ensureFallbackDeviceId();
        final settings = resolveEffectiveCloudSyncSettings(
          rawJson: rawSync,
          isWebDavConfigured: _decodeWebDavConfig(rawDav).isConfigured,
          fallbackDeviceId: fbId,
          fallbackDeviceName: _ensureFallbackDeviceName(fbId),
        );
        await db
            .into(db.preferences)
            .insertOnConflictUpdate(
              PreferencesCompanion.insert(
                key: prefKeyS3Config,
                value: jsonEncode(config.toJson()),
              ),
            );
        if (config.isConfigured && settings.backend == CloudBackendType.none) {
          await db
              .into(db.preferences)
              .insertOnConflictUpdate(
                PreferencesCompanion.insert(
                  key: prefKeyCloudSyncSettings,
                  value: jsonEncode(
                    settings
                        .copyWith(
                          backend: CloudBackendType.s3,
                          explicitBackend: true,
                        )
                        .toJson(),
                  ),
                ),
              );
        }
      }),
    );
    _cachedS3ConfigKey = null;
    _cachedS3Target = null;
    _emitManualResetSignal();
  }

  /// Clears S3 credentials while preserving export & retention preferences.
  Future<void> clearS3Config() async {
    await guardDatabase(
      () => db.transaction(() async {
        final rows =
            await (db.select(db.preferences)..where(
                  (t) => t.key.isIn(<String>[
                    prefKeyS3Config,
                    prefKeyCloudSyncSettings,
                    prefKeyWebDavConfig,
                  ]),
                ))
                .get();
        String? rawS3;
        String? rawSync;
        String? rawDav;
        for (final r in rows) {
          if (r.key == prefKeyS3Config) rawS3 = r.value;
          if (r.key == prefKeyCloudSyncSettings) rawSync = r.value;
          if (r.key == prefKeyWebDavConfig) rawDav = r.value;
        }
        final current = _decodeS3Config(rawS3);
        final cleared = S3Config(
          includeAttachments: current.includeAttachments,
          keepCount: current.keepCount,
          forcePathStyle: current.forcePathStyle,
        );
        await db
            .into(db.preferences)
            .insertOnConflictUpdate(
              PreferencesCompanion.insert(
                key: prefKeyS3Config,
                value: jsonEncode(cleared.toJson()),
              ),
            );
        if (rawSync != null && rawSync.isNotEmpty) {
          final fbId = _ensureFallbackDeviceId();
          final settings = resolveEffectiveCloudSyncSettings(
            rawJson: rawSync,
            isWebDavConfigured: _decodeWebDavConfig(rawDav).isConfigured,
            fallbackDeviceId: fbId,
            fallbackDeviceName: _ensureFallbackDeviceName(fbId),
          );
          if (settings.backend == CloudBackendType.s3) {
            await db
                .into(db.preferences)
                .insertOnConflictUpdate(
                  PreferencesCompanion.insert(
                    key: prefKeyCloudSyncSettings,
                    value: jsonEncode(
                      settings.copyWith(autoSyncEnabled: false).toJson(),
                    ),
                  ),
                );
          }
        }
      }),
    );
    _cachedS3ConfigKey = null;
    _cachedS3Target = null;
    _emitManualResetSignal();
  }

  /// Updates the full vs lightweight no-attachment export toggle across BOTH
  /// WebDAV and S3 stored configurations regardless of `isConfigured` (`S-09`).
  Future<void> setIncludeAttachments(bool includeAttachments) async {
    final currentDav = await getWebDavConfig();
    final currentS3 = await getS3Config();
    await guardDatabase(
      () => db.transaction(() async {
        await db
            .into(db.preferences)
            .insertOnConflictUpdate(
              PreferencesCompanion.insert(
                key: prefKeyWebDavConfig,
                value: jsonEncode(
                  currentDav
                      .copyWith(includeAttachments: includeAttachments)
                      .toJson(),
                ),
              ),
            );
        await db
            .into(db.preferences)
            .insertOnConflictUpdate(
              PreferencesCompanion.insert(
                key: prefKeyS3Config,
                value: jsonEncode(
                  currentS3
                      .copyWith(includeAttachments: includeAttachments)
                      .toJson(),
                ),
              ),
            );
      }),
    );
  }

  /// Updates the silent 24h auto-backup switch (§1.5, R7) for the active cloud target.
  Future<void> setAutoBackupEnabled(bool enabled) async {
    final settings = await getCloudSyncSettings();
    if (settings.backend == CloudBackendType.s3) {
      final s3 = await getS3Config();
      if (enabled && !s3.isConfigured) {
        throw const Failure(FailureCode.validation, '请先配置 S3 对象存储再开启自动云备份');
      }
      await guardDatabase(
        () => db
            .into(db.preferences)
            .insertOnConflictUpdate(
              PreferencesCompanion.insert(
                key: prefKeyS3Config,
                value: jsonEncode(
                  s3.copyWith(autoBackupEnabled: enabled).toJson(),
                ),
              ),
            ),
      );
      return;
    }

    final current = await getWebDavConfig();
    if (enabled && !current.isConfigured) {
      throw const Failure(FailureCode.validation, '请先配置 WebDAV 服务器再开启自动云备份');
    }
    final updated = current.copyWith(autoBackupEnabled: enabled);
    await guardDatabase(
      () => db
          .into(db.preferences)
          .insertOnConflictUpdate(
            PreferencesCompanion.insert(
              key: prefKeyWebDavConfig,
              value: jsonEncode(updated.toJson()),
            ),
          ),
    );
  }

  /// Builds a [WebDavBackupTarget] for the current [WebDavConfig] (ADR-017),
  /// reusing the cached target when the configuration is unchanged so verified
  /// remote directory paths are preserved across sync ticks.
  Future<WebDavBackupTarget> getWebDavTarget() async {
    final config = await getWebDavConfig();
    final key = jsonEncode(config.toJson());
    final cached = _cachedWebDavTarget;
    if (cached != null && _cachedWebDavConfigKey == key) {
      return cached;
    }
    final created = WebDavBackupTarget(
      config,
      httpClientFactory: httpClientFactory,
      nowMs: _nowMs,
    );
    _cachedWebDavConfigKey = key;
    _cachedWebDavTarget = created;
    return created;
  }

  /// Builds an [S3BackupTarget] for the current [S3Config] (ADR-017).
  Future<S3BackupTarget> getS3Target() async {
    final config = await getS3Config();
    final key = jsonEncode(config.toJson());
    final cached = _cachedS3Target;
    if (cached != null && _cachedS3ConfigKey == key) {
      return cached;
    }
    final created = S3BackupTarget(
      config,
      httpClientFactory: httpClientFactory,
      nowMs: _nowMs,
    );
    _cachedS3ConfigKey = key;
    _cachedS3Target = created;
    return created;
  }

  /// Returns the currently selected cloud [BackupTarget] (`WebDavBackupTarget`
  /// or `S3BackupTarget`), or `null` when cloud sync/backup is disabled (`none`).
  Future<BackupTarget?> getActiveCloudBackupTarget() async {
    final settings = await getCloudSyncSettings();
    return switch (settings.backend) {
      CloudBackendType.webdav => await getWebDavTarget(),
      CloudBackendType.s3 => await getS3Target(),
      CloudBackendType.none => null,
    };
  }

  /// Tests WebDAV connectivity, credentials, and directory write permission (§1.2).
  Future<void> testWebDavConnection([WebDavConfig? draftConfig]) async {
    final effective = draftConfig ?? await getWebDavConfig();
    if (!effective.isConfigured) {
      throw const Failure(FailureCode.validation, '请完整填写有效的服务器地址、用户名与密码');
    }
    final client = WebDavClient(
      effective,
      httpClientFactory: httpClientFactory,
      nowMs: _nowMs,
    );
    await client.testConnection();
  }

  /// Tests S3 connectivity, SigV4 credentials, and write/read/delete permission.
  Future<void> testS3Connection([S3Config? draftConfig]) async {
    final effective = draftConfig ?? await getS3Config();
    if (!effective.isConfigured) {
      throw const Failure(
        FailureCode.validation,
        '请完整填写有效的 S3 Endpoint、Bucket、Access Key ID 与 Secret Access Key',
      );
    }
    normalizeS3Prefix(effective.remotePrefix);
    final target = S3BackupTarget(
      effective,
      httpClientFactory: httpClientFactory,
      nowMs: _nowMs,
    );
    await target.testConnection();
  }

  /// Exports all 22 business tables (and optional attachments) into `.tally`
  /// ZIP bytes in memory (§2.2, R1, R2, R3, §6.3), offloading JSON/ZIP/SHA-256
  /// work to a background isolate when row count `>= 1000`.
  Future<PackedTallyBackup> createBackupBytes({
    bool? includeAttachments,
  }) async {
    await _ensureSandboxSelfHealedOnce();
    final bool withAttachments;
    if (includeAttachments != null) {
      withAttachments = includeAttachments;
    } else {
      final settings = await getCloudSyncSettings();
      if (settings.backend == CloudBackendType.s3) {
        withAttachments = (await getS3Config()).includeAttachments;
      } else {
        withAttachments = (await getWebDavConfig()).includeAttachments;
      }
    }
    final tables = await guardDatabase(
      () => db.transaction(_exportAll22Tables),
    );
    final attachments = withAttachments
        ? await _collectLocalAttachments()
        : const <String, Uint8List>{};

    return _packArchiveOffloaded(
      tables: tables,
      attachments: attachments,
      createdAtMs: _nowMs(),
      includeAttachments: withAttachments,
    );
  }

  /// Generates a `.tally` backup inside the app-managed local backup directory,
  /// records the independent local backup digest & timestamp, and prunes older
  /// routine backups exceeding `policy.keepCount` while preserving `conflict_*`.
  Future<BackupFileMetadata> createLocalBackup({
    bool? includeAttachments,
    String? customFileName,
    BackupProgressCallback? onProgress,
  }) => _runExclusive(
    () => _createLocalBackupUnlocked(
      includeAttachments: includeAttachments,
      customFileName: customFileName,
      onProgress: onProgress,
    ),
  );

  Future<BackupFileMetadata> _createLocalBackupUnlocked({
    bool? includeAttachments,
    String? customFileName,
    BackupProgressCallback? onProgress,
  }) async {
    final packed = await createBackupBytes(
      includeAttachments: includeAttachments,
    );
    final result = await _writeBytesToLocalWithFallback(
      packedBytes: packed.bytes,
      createdAtMs: packed.manifest.createdAtMs,
      customFileName: customFileName,
      onProgress: onProgress,
    );
    await _recordCompletedLocalBackupState(packed.manifest.createdAtMs);
    await _pruneBackupsOnTargetIfNeeded(
      target: result.targetUsed,
      protectedFileName: result.saved.fileName,
    );
    return result.saved;
  }

  Future<({BackupFileMetadata saved, BackupTarget targetUsed})>
  _writeBytesToLocalWithFallback({
    required Uint8List packedBytes,
    required int createdAtMs,
    String? customFileName,
    BackupProgressCallback? onProgress,
  }) async {
    final resolved = await _resolveActiveLocalTarget();
    final extBinding = resolved.externalBinding;
    if (extBinding != null) {
      try {
        final String fileName;
        if (customFileName != null) {
          fileName = customFileName;
        } else {
          final existingEntries = await _fileAccess.listExternalDirectoryFiles(
            extBinding,
          );
          fileName = formatTallyBackupFileName(
            DateTime.fromMillisecondsSinceEpoch(createdAtMs),
            existingFileNames: existingEntries.map((e) => e.fileName),
          );
        }
        final saved = await resolved.target.writeBackup(
          fileName,
          packedBytes,
          onProgress: onProgress,
        );
        return (saved: saved, targetUsed: resolved.target);
      } catch (_) {
        await _setExternalBackupNeedsRebindIfChanged(true);
      }
    }

    final String sandboxFileName;
    if (customFileName != null) {
      sandboxFileName = customFileName;
    } else {
      final base = formatTallyBackupFileName(
        DateTime.fromMillisecondsSinceEpoch(createdAtMs),
      );
      sandboxFileName = await _resolveUniqueLocalBackupFileName(base);
    }
    final saved = await localTarget.writeBackup(
      sandboxFileName,
      packedBytes,
      onProgress: onProgress,
    );
    return (saved: saved, targetUsed: localTarget);
  }

  Future<String> _resolveUniqueLocalBackupFileName(String baseFileName) =>
      LocalDirectoryBackupTarget._runRootIo(() async {
        final dir = await _localBackupsDirProvider();
        if (!await dir.exists()) return baseFileName;
        if (!await File(p.join(dir.path, baseFileName)).exists()) {
          return baseFileName;
        }
        final dotIdx = baseFileName.lastIndexOf('.');
        final stem = dotIdx > 0
            ? baseFileName.substring(0, dotIdx)
            : baseFileName;
        final ext = dotIdx > 0 ? baseFileName.substring(dotIdx) : '';
        var seq = 2;
        while (await File(p.join(dir.path, '${stem}_$seq$ext')).exists()) {
          seq++;
        }
        return '${stem}_$seq$ext';
      });

  Future<void> _pruneBackupsOnTargetIfNeeded({
    required BackupTarget target,
    String? protectedFileName,
  }) async {
    final policy = await getLocalAutoBackupPolicy();
    final allLocal = await target.listBackups();
    final toPrune = selectNonConflictBackupsToPrune(
      allLocal.map(
        (b) => BackupRetentionItem(
          fileName: b.fileName,
          modifiedAtMs: b.modifiedAtMs,
        ),
      ),
      keepCount: policy.keepCount,
    );
    for (final name in toPrune) {
      if (name == protectedFileName) continue;
      await target.deleteBackup(name);
    }
  }

  /// Exports a `.tally` backup to a user-chosen OS location (SAF on Android,
  /// save dialog on Desktop).
  Future<String> exportBackupToSaveLocation({
    required FileAccess fileAccess,
    bool? includeAttachments,
  }) async {
    final packed = await createBackupBytes(
      includeAttachments: includeAttachments,
    );
    final fileName = formatTallyBackupFileName(
      DateTime.fromMillisecondsSinceEpoch(packed.manifest.createdAtMs),
    );
    await fileAccess.saveBytes(fileName, packed.bytes);
    await _recordCompletedBackupState(packed.manifest.createdAtMs);
    return fileName;
  }

  /// Shares a freshly generated `.tally` backup via the OS share sheet
  /// (`FileProvider` + `ACTION_SEND` on Android).
  Future<String> shareBackup({
    required FileAccess fileAccess,
    bool? includeAttachments,
    String? subject,
  }) async {
    final packed = await createBackupBytes(
      includeAttachments: includeAttachments,
    );
    final fileName = formatTallyBackupFileName(
      DateTime.fromMillisecondsSinceEpoch(packed.manifest.createdAtMs),
    );
    await fileAccess.shareBytes(
      fileName,
      packed.bytes,
      subject: subject ?? '帐屿数据备份 $fileName',
    );
    return fileName;
  }

  static String _validateSafeBackupFileName(String fileName) {
    final trimmed = fileName.trim();
    if (trimmed.isEmpty ||
        trimmed == '.' ||
        trimmed == '..' ||
        trimmed.contains('/') ||
        trimmed.contains(r'\') ||
        trimmed.contains('\x00') ||
        !WebDavClient.isSupportedBackupFileName(trimmed)) {
      throw Failure(FailureCode.validation, '非法的备份文件名：$fileName');
    }
    return trimmed;
  }

  static List<String> _validateUniqueBackupFileNames(List<String> fileNames) {
    final seen = <String>{};
    final result = <String>[];
    for (final raw in fileNames) {
      final clean = _validateSafeBackupFileName(raw);
      if (seen.add(clean)) {
        result.add(clean);
      }
    }
    return result;
  }

  Future<List<BackupFileMetadata>> listLocalBackups() async {
    final resolved = await _resolveActiveLocalTarget();
    if (resolved.externalBinding != null) {
      try {
        return await resolved.target.listBackups();
      } catch (_) {
        await _setExternalBackupNeedsRebindIfChanged(true);
        return localTarget.listBackups();
      }
    }
    return localTarget.listBackups();
  }

  Future<void> deleteLocalBackup(String fileName) async {
    final clean = _validateSafeBackupFileName(fileName);
    await _runExclusive(() => _deleteLocalBackupsUnlocked(<String>[clean]));
  }

  /// Batch-deletes the specified `.tally` / `.tallyzip` files from the active
  /// local backup directory (bound external folder when accessible, otherwise
  /// app sandbox) after upfront filename validation, clearing any matching
  /// `lastConflictFileName` on [LocalSyncCursor].
  Future<int> deleteLocalBackups(List<String> fileNames) async {
    final cleanNames = _validateUniqueBackupFileNames(fileNames);
    if (cleanNames.isEmpty) return 0;
    return _runExclusive(() => _deleteLocalBackupsUnlocked(cleanNames));
  }

  Future<int> _deleteLocalBackupsUnlocked(List<String> cleanNames) async {
    final resolved = await _resolveActiveLocalTarget();
    int deletedCount = 0;
    if (resolved.externalBinding != null) {
      final extEntries = await _fileAccess.listExternalDirectoryFiles(
        resolved.externalBinding!,
      );
      final existingExt = <String>{for (final e in extEntries) e.fileName};
      for (final name in cleanNames) {
        if (existingExt.contains(name)) {
          await _fileAccess.deleteExternalDirectoryFile(
            resolved.externalBinding!,
            name,
          );
          deletedCount++;
        }
      }
      // Best-effort remove any migrated copy in app sandbox so deleted backups
      // never resurrect when switching external folders later.
      await LocalDirectoryBackupTarget._runRootIo(() async {
        try {
          final dir = await _localBackupsDirProvider();
          if (!await dir.exists()) return;
          for (final name in cleanNames) {
            final file = File(p.join(dir.path, name));
            if (await file.exists()) {
              await file.delete();
            }
          }
        } catch (_) {}
      });
    } else {
      deletedCount = await LocalDirectoryBackupTarget._runRootIo(() async {
        final dir = await _localBackupsDirProvider();
        if (!await dir.exists()) return 0;
        var count = 0;
        for (final name in cleanNames) {
          final file = File(p.join(dir.path, name));
          if (await file.exists()) {
            await file.delete();
            count++;
          }
        }
        return count;
      });
    }

    final cursor = await getSyncCursor();
    final conflictName = cursor.lastConflictFileName?.trim();
    if (conflictName != null &&
        conflictName.isNotEmpty &&
        cleanNames.contains(conflictName)) {
      await _saveSyncCursor(cursor.copyWith(clearConflictRecord: true));
    }
    return deletedCount;
  }

  /// Exports a specific historical `.tally` backup (from either local backups
  /// or the active cloud target) via OS Save-As or Share sheet.
  Future<String> exportExistingBackup({
    required String fileName,
    required bool isCloud,
    required FileAccess fileAccess,
    BackupProgressCallback? onProgress,
  }) async {
    final cleanName = _validateSafeBackupFileName(fileName);
    final Uint8List bytes;
    if (isCloud) {
      final settings = await getCloudSyncSettings();
      bytes = switch (settings.backend) {
        CloudBackendType.s3 => await (await getS3Target()).readBackup(
          cleanName,
          onProgress: onProgress,
        ),
        CloudBackendType.webdav => await (await getWebDavTarget()).readBackup(
          cleanName,
          onProgress: onProgress,
        ),
        CloudBackendType.none => throw const Failure(
          FailureCode.validation,
          '云存储通道未启用',
        ),
      };
    } else {
      final resolved = await _resolveActiveLocalTarget();
      bytes = await resolved.target.readBackup(
        cleanName,
        onProgress: onProgress,
      );
    }

    if (fileAccess.saveLocationCapability.state == CapabilityState.available) {
      await fileAccess.saveBytes(cleanName, bytes);
      return cleanName;
    }
    if (fileAccess.shareCapability.state == CapabilityState.available) {
      await fileAccess.shareBytes(
        cleanName,
        bytes,
        subject: '帐屿历史备份 $cleanName',
      );
      return cleanName;
    }
    throw const Failure(FailureCode.storageUnavailable, '当前平台不支持导出文件');
  }

  Future<TallyManifest> restoreLocalBackup(String fileName) async {
    final clean = _validateSafeBackupFileName(fileName);
    final resolved = await _resolveActiveLocalTarget();
    final bytes = await resolved.target.readBackup(clean);
    final manifest = await restoreFromBytes(bytes);
    if (isConflictBackupFileName(clean) && !manifest.includeAttachments) {
      await _hydrateLightweightConflictAttachmentsBestEffort(clean);
    }
    return manifest;
  }

  /// Prompts the user to pick an external `.tally` file and restores it via the
  /// 3-stage safe restore pipeline.
  Future<TallyManifest> restoreFromFilePicker({
    required FileAccess fileAccess,
  }) async {
    final selected = await fileAccess.pickBytes(
      allowedExtensions: const <String>['tally', 'tallyzip', 'zip'],
    );
    return restoreFromBytes(selected.bytes);
  }

  /// Lists remote `.tally` backups on WebDAV (`PROPFIND Depth: 1`).
  Future<List<BackupFileMetadata>> listWebDavBackups() async {
    final target = await getWebDavTarget();
    return target.listBackups();
  }

  /// Lists remote `.tally` backups on S3 (`GET ?list-type=2`).
  Future<List<BackupFileMetadata>> listS3Backups() async {
    final target = await getS3Target();
    return target.listBackups();
  }

  /// Lists historical `.tally` backups on the currently active cloud backend.
  Future<List<BackupFileMetadata>> listActiveCloudBackups() async {
    final target = await getActiveCloudBackupTarget();
    if (target == null ||
        target.capability.state != CapabilityState.available) {
      return const <BackupFileMetadata>[];
    }
    return target.listBackups();
  }

  /// Packs a `.tally` backup and uploads it to WebDAV via two-phase atomic
  /// `.tmp -> MOVE` (or `PUT + HEAD` fallback), then prunes older remote
  /// backups beyond `config.keepCount` (§1.4, R4, §6.2).
  Future<BackupFileMetadata> uploadBackupToWebDav({
    bool? includeAttachments,
    String? customFileName,
    BackupProgressCallback? onProgress,
  }) => _runExclusive(
    () => _uploadBackupToWebDavUnlocked(
      includeAttachments: includeAttachments,
      customFileName: customFileName,
      onProgress: onProgress,
    ),
  );

  Future<BackupFileMetadata> _uploadBackupToWebDavUnlocked({
    bool? includeAttachments,
    String? customFileName,
    BackupProgressCallback? onProgress,
  }) async {
    final config = await getWebDavConfig();
    if (!config.isConfigured) {
      throw const Failure(FailureCode.validation, 'WebDAV 未配置');
    }
    final packed = await createBackupBytes(
      includeAttachments: includeAttachments ?? config.includeAttachments,
    );
    final target = await getWebDavTarget();
    final String fileName;
    if (customFileName != null) {
      fileName = customFileName;
    } else {
      final existing = await target.listBackups().then(
        (items) => items.map((e) => e.fileName),
        onError: (_) => const <String>[],
      );
      fileName = formatTallyBackupFileName(
        DateTime.fromMillisecondsSinceEpoch(packed.manifest.createdAtMs),
        existingFileNames: existing,
      );
    }
    final uploaded = await target.writeBackup(
      fileName,
      packed.bytes,
      onProgress: onProgress,
    );
    await _recordCompletedBackupState(packed.manifest.createdAtMs);
    return BackupFileMetadata(
      fileName: uploaded.fileName,
      sizeBytes: uploaded.sizeBytes,
      modifiedAtMs: uploaded.modifiedAtMs,
      manifest: packed.manifest,
    );
  }

  /// Packs a `.tally` backup and uploads it to S3 via SigV4 `PUT`, then prunes
  /// older routine backups beyond `config.keepCount`.
  Future<BackupFileMetadata> uploadBackupToS3({
    bool? includeAttachments,
    String? customFileName,
    BackupProgressCallback? onProgress,
  }) => _runExclusive(
    () => _uploadBackupToS3Unlocked(
      includeAttachments: includeAttachments,
      customFileName: customFileName,
      onProgress: onProgress,
    ),
  );

  Future<BackupFileMetadata> _uploadBackupToS3Unlocked({
    bool? includeAttachments,
    String? customFileName,
    BackupProgressCallback? onProgress,
  }) async {
    final config = await getS3Config();
    if (!config.isConfigured) {
      throw const Failure(FailureCode.validation, 'S3 对象存储未配置');
    }
    final packed = await createBackupBytes(
      includeAttachments: includeAttachments ?? config.includeAttachments,
    );
    final target = await getS3Target();
    final String fileName;
    if (customFileName != null) {
      fileName = customFileName;
    } else {
      final existing = await target.listBackups().then(
        (items) => items.map((e) => e.fileName),
        onError: (_) => const <String>[],
      );
      fileName = formatTallyBackupFileName(
        DateTime.fromMillisecondsSinceEpoch(packed.manifest.createdAtMs),
        existingFileNames: existing,
      );
    }
    final uploaded = await target.writeBackup(
      fileName,
      packed.bytes,
      onProgress: onProgress,
    );
    await _recordCompletedBackupState(packed.manifest.createdAtMs);
    return BackupFileMetadata(
      fileName: uploaded.fileName,
      sizeBytes: uploaded.sizeBytes,
      modifiedAtMs: uploaded.modifiedAtMs,
      manifest: packed.manifest,
    );
  }

  /// Uploads a historical `.tally` backup to whichever cloud backend is active.
  Future<BackupFileMetadata> uploadToActiveCloudBackup({
    bool? includeAttachments,
    String? customFileName,
    BackupProgressCallback? onProgress,
  }) => _runExclusive(() async {
    final settings = await getCloudSyncSettings();
    return switch (settings.backend) {
      CloudBackendType.s3 => _uploadBackupToS3Unlocked(
        includeAttachments: includeAttachments,
        customFileName: customFileName,
        onProgress: onProgress,
      ),
      CloudBackendType.webdav => _uploadBackupToWebDavUnlocked(
        includeAttachments: includeAttachments,
        customFileName: customFileName,
        onProgress: onProgress,
      ),
      CloudBackendType.none => throw const Failure(
        FailureCode.validation,
        '请先选择并配置云存储通道（WebDAV 或 S3）',
      ),
    };
  });

  /// Downloads a remote `.tally` backup from WebDAV and executes the 3-stage
  /// atomic restore (R5).
  Future<TallyManifest> restoreWebDavBackup(
    String fileName, {
    BackupProgressCallback? onProgress,
  }) async {
    final target = await getWebDavTarget();
    final bytes = await target.readBackup(fileName, onProgress: onProgress);
    final manifest = await restoreFromBytes(bytes);
    if (isConflictBackupFileName(fileName) && !manifest.includeAttachments) {
      await _hydrateLightweightConflictAttachmentsBestEffort(
        fileName,
        explicitStore: target,
      );
    }
    return manifest;
  }

  /// Downloads a remote `.tally` backup from S3 and executes the 3-stage
  /// atomic restore (R5).
  Future<TallyManifest> restoreS3Backup(
    String fileName, {
    BackupProgressCallback? onProgress,
  }) async {
    final target = await getS3Target();
    final bytes = await target.readBackup(fileName, onProgress: onProgress);
    final manifest = await restoreFromBytes(bytes);
    if (isConflictBackupFileName(fileName) && !manifest.includeAttachments) {
      await _hydrateLightweightConflictAttachmentsBestEffort(
        fileName,
        explicitStore: target,
      );
    }
    return manifest;
  }

  /// Downloads and restores a historical `.tally` backup from the active cloud target.
  Future<TallyManifest> restoreActiveCloudBackup(
    String fileName, {
    BackupProgressCallback? onProgress,
  }) async {
    final settings = await getCloudSyncSettings();
    return switch (settings.backend) {
      CloudBackendType.s3 => restoreS3Backup(fileName, onProgress: onProgress),
      CloudBackendType.webdav => restoreWebDavBackup(
        fileName,
        onProgress: onProgress,
      ),
      CloudBackendType.none => throw const Failure(
        FailureCode.validation,
        '云存储通道未启用',
      ),
    };
  }

  /// Deletes a remote `.tally` backup from WebDAV (§1.8).
  Future<void> deleteWebDavBackup(String fileName) async {
    final clean = _validateSafeBackupFileName(fileName);
    await _runExclusive(() async {
      final target = await getWebDavTarget();
      await target.deleteBackup(clean);
      if (isConflictBackupFileName(clean)) {
        try {
          await target.deleteObject('$cloudSyncConflictRefsDir/$clean.json');
        } catch (_) {}
      }
    });
  }

  /// Deletes a remote `.tally` backup from S3.
  Future<void> deleteS3Backup(String fileName) async {
    final clean = _validateSafeBackupFileName(fileName);
    await _runExclusive(() async {
      final target = await getS3Target();
      await target.deleteBackup(clean);
      if (isConflictBackupFileName(clean)) {
        try {
          await target.deleteObject('$cloudSyncConflictRefsDir/$clean.json');
        } catch (_) {}
      }
    });
  }

  /// Deletes a historical `.tally` backup from whichever cloud target is active.
  Future<void> deleteActiveCloudBackup(String fileName) async {
    final clean = _validateSafeBackupFileName(fileName);
    await _runExclusive(
      () => _deleteActiveCloudBackupsUnlocked(<String>[clean]),
    );
  }

  /// Batch-deletes historical `.tally` / `.tallyzip` backups from whichever
  /// cloud target is active, serialized under [_runExclusive].
  Future<int> deleteActiveCloudBackups(List<String> fileNames) async {
    final cleanNames = _validateUniqueBackupFileNames(fileNames);
    if (cleanNames.isEmpty) return 0;
    return _runExclusive(() => _deleteActiveCloudBackupsUnlocked(cleanNames));
  }

  Future<int> _deleteActiveCloudBackupsUnlocked(List<String> cleanNames) async {
    final settings = await getCloudSyncSettings();
    final BackupTarget target;
    final CloudSyncObjectStore store;
    switch (settings.backend) {
      case CloudBackendType.s3:
        final s3 = await getS3Config();
        if (!s3.isConfigured) {
          throw const Failure(FailureCode.validation, 'S3 对象存储未配置');
        }
        final t = await getS3Target();
        target = t;
        store = t;
      case CloudBackendType.webdav:
        final dav = await getWebDavConfig();
        if (!dav.isConfigured) {
          throw const Failure(FailureCode.validation, 'WebDAV 未配置');
        }
        final t = await getWebDavTarget();
        target = t;
        store = t;
      case CloudBackendType.none:
        throw const Failure(FailureCode.validation, '云存储通道未启用');
    }
    var deleted = 0;
    for (final name in cleanNames) {
      await target.deleteBackup(name);
      if (isConflictBackupFileName(name)) {
        try {
          await store.deleteObject('$cloudSyncConflictRefsDir/$name.json');
        } catch (_) {}
      }
      deleted++;
    }
    return deleted;
  }

  /// Returns epoch milliseconds of the last successful backup, if any.
  Future<int?> getLastBackupAtMs() async {
    final row = await guardDatabase(
      () => (db.select(
        db.preferences,
      )..where((t) => t.key.equals(prefKeyLastBackupAtMs))).getSingleOrNull(),
    );
    return row == null ? null : int.tryParse(row.value);
  }

  /// Computes deterministic SHA-256 over all 22 tables + sorted local attachments (`R2`).
  Future<String> computeLocalDataSha256() => _computeCanonicalStateDigest();

  /// Returns `true` if any of the 22 business tables or attachments changed
  /// since the last completed backup (`localDataChanged` in R7).
  Future<bool> hasLocalDataChanged() async {
    final prevRow = await guardDatabase(
      () =>
          (db.select(db.preferences)
                ..where((t) => t.key.equals(prefKeyLastBackupDataSha256)))
              .getSingleOrNull(),
    );
    final currentDigest = await _computeCanonicalStateDigest();
    return prevRow?.value != currentDigest;
  }

  /// Checks R7 silent auto-backup eligibility (`enabled && configured &&
  /// elapsed >= cooldown && localDataChanged`) and, if eligible, packs and
  /// uploads a backup to the configured cloud target. Returns `null` when
  /// backend is `none`, throttled, disabled, or unchanged (`S-06`, `S-07`).
  Future<BackupFileMetadata?> runSilentAutoBackupIfNeeded({
    BackupProgressCallback? onProgress,
  }) async {
    final settings = await getCloudSyncSettings();
    if (settings.backend == CloudBackendType.none) {
      return null;
    }
    return _runExclusive(
      () => _runSilentAutoBackupIfNeededUnlocked(onProgress: onProgress),
    );
  }

  Future<BackupFileMetadata?> _runSilentAutoBackupIfNeededUnlocked({
    BackupProgressCallback? onProgress,
  }) async {
    final settings = await getCloudSyncSettings();
    if (settings.backend == CloudBackendType.none) {
      return null;
    }
    if (settings.backend == CloudBackendType.s3) {
      final s3Config = await getS3Config();
      if (!s3Config.autoBackupEnabled || !s3Config.isConfigured) {
        return null;
      }
      final lastBackupAtMs = await getLastBackupAtMs();
      final now = _nowMs();
      if (lastBackupAtMs != null &&
          (now - lastBackupAtMs) < s3Config.autoBackupCooldownMs) {
        return null;
      }
      final changed = await hasLocalDataChanged();
      if (!shouldTriggerAutoBackup(
        enabled: s3Config.autoBackupEnabled,
        webDavConfigured: s3Config.isConfigured,
        localDataChanged: changed,
        lastBackupAtMs: lastBackupAtMs,
        nowMs: now,
        cooldownMs: s3Config.autoBackupCooldownMs,
      )) {
        return null;
      }
      return _uploadBackupToS3Unlocked(onProgress: onProgress);
    }

    final config = await getWebDavConfig();
    if (!config.autoBackupEnabled || !config.isConfigured) {
      return null;
    }
    final lastBackupAtMs = await getLastBackupAtMs();
    final now = _nowMs();
    if (lastBackupAtMs != null &&
        (now - lastBackupAtMs) < config.autoBackupCooldownMs) {
      return null;
    }
    final changed = await hasLocalDataChanged();
    if (!shouldTriggerAutoBackup(
      enabled: config.autoBackupEnabled,
      webDavConfigured: config.isConfigured,
      localDataChanged: changed,
      lastBackupAtMs: lastBackupAtMs,
      nowMs: now,
      cooldownMs: config.autoBackupCooldownMs,
    )) {
      return null;
    }
    return _uploadBackupToWebDavUnlocked(onProgress: onProgress);
  }

  /// Returns epoch milliseconds of the last successful local `.tally` backup, if any.
  Future<int?> getLastLocalAutoBackupAtMs() async {
    final row = await guardDatabase(
      () =>
          (db.select(db.preferences)
                ..where((t) => t.key.equals(prefKeyLocalAutoBackupLastAtMs)))
              .getSingleOrNull(),
    );
    return row == null ? null : int.tryParse(row.value);
  }

  /// Returns `true` if any of the 22 business tables or local attachments
  /// changed since the last completed local `.tally` backup.
  ///
  /// Tracked in `local_auto_backup_last_sha256` completely independently of
  /// cloud backup (`backup_last_data_sha256`) and cloud sync (`cloud_sync_cursor`).
  Future<bool> hasLocalDataChangedForLocalBackup() async {
    final prevRow = await guardDatabase(
      () =>
          (db.select(db.preferences)
                ..where((t) => t.key.equals(prefKeyLocalAutoBackupLastSha256)))
              .getSingleOrNull(),
    );
    final currentDigest = await _computeCanonicalStateDigest();
    return prevRow?.value != currentDigest;
  }

  /// Returns epoch milliseconds of the last periodic cloud sync schedule check.
  Future<int?> getLastCloudScheduleCheckAtMs() async {
    final row = await guardDatabase(
      () =>
          (db.select(db.preferences)..where(
                (t) => t.key.equals(prefKeyCloudSyncLastScheduleCheckAtMs),
              ))
              .getSingleOrNull(),
    );
    return row == null ? null : int.tryParse(row.value);
  }

  Future<void> _recordCloudScheduleCheckAtMs(int timestampMs) => guardDatabase(
    () => db
        .into(db.preferences)
        .insertOnConflictUpdate(
          PreferencesCompanion.insert(
            key: prefKeyCloudSyncLastScheduleCheckAtMs,
            value: '$timestampMs',
          ),
        ),
  );

  /// Evaluates [LocalAutoBackupPolicy] for [source] and generates a pruned
  /// local `.tally` backup when eligible and local data changed (`S-07`).
  Future<BackupFileMetadata?> runLocalAutoBackupForTrigger(
    AutoTriggerSource source, {
    BackupProgressCallback? onProgress,
  }) => _runExclusive(
    () => _runLocalAutoBackupForTriggerUnlocked(source, onProgress: onProgress),
  );

  Future<BackupFileMetadata?> _runLocalAutoBackupForTriggerUnlocked(
    AutoTriggerSource source, {
    BackupProgressCallback? onProgress,
  }) async {
    final policy = await getLocalAutoBackupPolicy();
    if (!isLocalTriggerEnabled(policy, source)) {
      return null;
    }
    int? lastAtMs;
    final now = _nowMs();
    if (source == AutoTriggerSource.schedule) {
      lastAtMs = await getLastLocalAutoBackupAtMs();
      if (lastAtMs != null && (now - lastAtMs) < policy.scheduleIntervalMs) {
        return null;
      }
    }
    final changed = await hasLocalDataChangedForLocalBackup();
    if (!shouldRunLocalAutoBackupForTrigger(
      policy: policy,
      source: source,
      localDataChanged: changed,
      lastAutoBackupAtMs: lastAtMs,
      nowMs: _nowMs(),
    )) {
      return null;
    }
    return _createLocalBackupUnlocked(onProgress: onProgress);
  }

  /// Evaluates [CloudSyncSettings] for [source] and executes silent multi-device
  /// cloud sync when eligible, performing zero network I/O when disabled or
  /// unconfigured.
  Future<CloudSyncOutcome?> runCloudAutoSyncForTrigger(
    AutoTriggerSource source, {
    BackupProgressCallback? onProgress,
  }) async {
    final settings = await getCloudSyncSettings();
    if (!isCloudTriggerEnabled(settings, source)) {
      return null;
    }
    final bool isConfigured;
    switch (settings.backend) {
      case CloudBackendType.none:
        return null;
      case CloudBackendType.webdav:
        isConfigured = (await getWebDavConfig()).isConfigured;
      case CloudBackendType.s3:
        isConfigured = (await getS3Config()).isConfigured;
    }
    if (!isConfigured) {
      return null;
    }

    int? lastScheduleCheckAtMs;
    final now = _nowMs();
    if (source == AutoTriggerSource.schedule) {
      lastScheduleCheckAtMs = await getLastCloudScheduleCheckAtMs();
    }
    if (!shouldRunCloudAutoSyncForTrigger(
      settings: settings,
      isBackendConfigured: isConfigured,
      source: source,
      lastScheduleCheckAtMs: lastScheduleCheckAtMs,
      nowMs: now,
    )) {
      return null;
    }

    final outcome = await _syncInternal(
      isBackgroundAutoTrigger: true,
      triggerSource: source,
      onProgress: onProgress,
    );
    if (source == AutoTriggerSource.schedule) {
      await _recordCloudScheduleCheckAtMs(_nowMs());
    }
    return outcome;
  }

  /// Runs silent multi-device snapshot sync when `autoSyncEnabled` is `true`
  /// and the active cloud backend (`WebDAV` or `S3`) is configured.
  /// Performs zero network I/O when disabled or unconfigured.
  Future<CloudSyncOutcome?> runSilentCloudSyncIfNeeded({
    BackupProgressCallback? onProgress,
  }) async {
    final settings = await getCloudSyncSettings();
    if (!settings.autoSyncEnabled ||
        settings.backend == CloudBackendType.none) {
      return null;
    }
    if (settings.backend == CloudBackendType.webdav) {
      final dav = await getWebDavConfig();
      if (!dav.isConfigured) return null;
    } else if (settings.backend == CloudBackendType.s3) {
      final s3 = await getS3Config();
      if (!s3.isConfigured) return null;
    }
    return _syncInternal(
      isBackgroundAutoTrigger: true,
      triggerSource: AutoTriggerSource.windowFocus,
      onProgress: onProgress,
    );
  }

  /// Executes multi-device snapshot synchronization (`sync/head.json` `format: 2` +
  /// immutable `sync/revisions/db_r<rev>_<sha16>.tally` + deduplicated
  /// `sync/attachments/*`) with three-way accounting-conserving merge,
  /// same-filesystem atomic pull replacement, race-guarded push commits, and
  /// conflict preservation (`R4`, `R5`, `R6`, `S-01`, `S-02`, `S-07`).
  Future<CloudSyncOutcome> syncNow({
    SyncConflictResolution? resolution,
    BackupProgressCallback? onProgress,
    FutureOr<void> Function()? beforePushCommitForTest,
  }) => _syncInternal(
    resolution: resolution,
    isBackgroundAutoTrigger: false,
    onProgress: onProgress,
    beforePushCommitForTest: beforePushCommitForTest,
  );

  Future<CloudSyncOutcome> _syncInternal({
    SyncConflictResolution? resolution,
    required bool isBackgroundAutoTrigger,
    AutoTriggerSource? triggerSource,
    BackupProgressCallback? onProgress,
    FutureOr<void> Function()? beforePushCommitForTest,
  }) {
    _activeSyncCount++;
    if (_activeSyncCount == 1 && !_syncInProgressController.isClosed) {
      _syncInProgressController.add(true);
    }
    return _runExclusive(() async {
      try {
        final outcome = await _syncNowUnlocked(
          resolution: resolution,
          isBackgroundAutoTrigger: isBackgroundAutoTrigger,
          triggerSource: triggerSource,
          onProgress: onProgress,
          beforePushCommitForTest: beforePushCommitForTest,
        );
        if (!isBackgroundAutoTrigger) {
          _emitManualResetSignal();
        }
        return outcome;
      } finally {
        if (_activeSyncCount > 0) {
          _activeSyncCount--;
        }
        if (_activeSyncCount == 0 && !_syncInProgressController.isClosed) {
          _syncInProgressController.add(false);
        }
      }
    });
  }

  Future<CloudSyncOutcome> _syncNowUnlocked({
    SyncConflictResolution? resolution,
    bool isBackgroundAutoTrigger = false,
    AutoTriggerSource? triggerSource,
    BackupProgressCallback? onProgress,
    FutureOr<void> Function()? beforePushCommitForTest,
  }) async {
    await _ensureSandboxSelfHealedOnce();
    final settings = await getCloudSyncSettings();
    final CloudSyncObjectStore store;
    final BackupTarget cloudBackupTarget;
    final int archiveCooldownMs;
    final bool includeArchiveAttachments;

    switch (settings.backend) {
      case CloudBackendType.none:
        throw const Failure(
          FailureCode.validation,
          '尚未启用云同步通道，请先选择 WebDAV 或 S3 对象存储',
        );
      case CloudBackendType.webdav:
        final davCfg = await getWebDavConfig();
        if (!davCfg.isConfigured) {
          throw const Failure(FailureCode.validation, 'WebDAV 未配置，无法执行多端同步');
        }
        final target = await getWebDavTarget();
        store = target;
        cloudBackupTarget = target;
        archiveCooldownMs = davCfg.autoBackupCooldownMs;
        includeArchiveAttachments = davCfg.includeAttachments;
      case CloudBackendType.s3:
        final s3Cfg = await getS3Config();
        if (!s3Cfg.isConfigured) {
          throw const Failure(FailureCode.validation, 'S3 对象存储未配置，无法执行多端同步');
        }
        final target = await getS3Target();
        store = target;
        cloudBackupTarget = target;
        archiveCooldownMs = s3Cfg.autoBackupCooldownMs;
        includeArchiveAttachments = s3Cfg.includeAttachments;
    }

    return store.runSession(() async {
      final rawCursor = await getSyncCursor();
      final cursor = rawCursor.scopedToTarget(store.targetFingerprint);

      final localSummary = await _computeLocalSyncSnapshotSummary();
      final localAttChecksums = localSummary.attChecksums;
      final localDataSha256 = localSummary.dataSha256;
      final isLocalFreshEmpty = localSummary.isFreshSeed;
      Map<String, List<Map<String, Object?>>>? localTables =
          localSummary.tables;

      Future<Map<String, List<Map<String, Object?>>>>
      ensureLocalTables() async {
        final existing = localTables;
        if (existing != null) return existing;
        final exported = await guardDatabase(
          () => db.transaction(_exportAll22Tables),
        );
        localTables = exported;
        return exported;
      }

      // 1-Request / 0B Background Conditional Probe (`If-None-Match` + `304`):
      ConditionalGetResult? prefetchedHead;
      if (isBackgroundAutoTrigger &&
          resolution == null &&
          !cursor.isNeverSynced &&
          !cursor.localFullReplaceSinceLastSync &&
          cursor.lastConflictFileName == null &&
          cursor.lastSyncedDataSha256?.toLowerCase() ==
              localDataSha256.toLowerCase()) {
        final cond = await store.getObjectConditional(
          cloudSyncHeadPath,
          ifNoneMatch: cursor.lastRemoteHeadEtag,
          noCache: true,
        );
        if (cond.notModified) {
          return CloudSyncOutcome(
            status: CloudSyncStatus.alreadyUpToDate,
            revision: cursor.lastSyncedRevision,
            localDataSha256: localDataSha256,
          );
        }
        prefetchedHead = cond;
      }

      final remoteState = await _inspectRemoteSyncState(
        store,
        prefetchedHead: prefetchedHead,
      );
      final remoteHead = remoteState.head;
      final orphanRemoteDbBytes = remoteState.orphanOrLegacyDbBytes;
      final hasRemoteOrphanSnapshot = orphanRemoteDbBytes != null;

      final decision = decideSyncAction(
        cursor: cursor,
        localDataSha256: localDataSha256,
        isLocalFreshEmpty: isLocalFreshEmpty,
        remoteHead: remoteHead,
        hasRemoteOrphanLatestDb: hasRemoteOrphanSnapshot,
        hasLegacyIncompatibleRemoteHead: remoteState.isLegacyFormat,
        legacyRemoteRevision:
            remoteState.legacyRevision ?? remoteState.orphanRevisionHint,
        resolution: resolution,
      );

      switch (decision.action) {
        case SyncActionType.noOp:
          if (remoteHead != null && !isBackgroundAutoTrigger) {
            await _selfHealMissingRemoteSnapshotIfNeeded(
              store: store,
              remoteHead: remoteHead,
              localTables: await ensureLocalTables(),
              localAttChecksums: localAttChecksums,
              localDataSha256: localDataSha256,
              onProgress: onProgress,
            );
          }
          if (remoteHead != null) {
            await _ensureSyncBaseSavedIfMissing(
              targetFingerprint: store.targetFingerprint,
              revision: remoteHead.revision,
              dataSha256: localDataSha256,
              attachmentChecksums: localAttChecksums,
              ensureLocalTables: ensureLocalTables,
            );
          }
          final nextEtag = remoteState.headEtag ?? cursor.lastRemoteHeadEtag;
          if (cursor.lastConflictFileName != null ||
              cursor.lastConflictSha256 != null ||
              cursor.lastConflictSummaryJson != null ||
              nextEtag != cursor.lastRemoteHeadEtag) {
            await _saveSyncCursor(
              cursor.copyWith(
                targetFingerprint: store.targetFingerprint,
                lastRemoteHeadEtag: nextEtag,
                clearConflictRecord: true,
              ),
              ensureSettings: settings,
            );
          }
          return CloudSyncOutcome(
            status: CloudSyncStatus.alreadyUpToDate,
            revision: remoteHead!.revision,
            localDataSha256: localDataSha256,
            remoteHead: remoteHead,
          );

        case SyncActionType.fastForwardCursor:
          if (!isBackgroundAutoTrigger) {
            await _selfHealMissingRemoteSnapshotIfNeeded(
              store: store,
              remoteHead: remoteHead!,
              localTables: await ensureLocalTables(),
              localAttChecksums: localAttChecksums,
              localDataSha256: localDataSha256,
              onProgress: onProgress,
            );
          }
          await _ensureSyncBaseSavedIfMissing(
            targetFingerprint: store.targetFingerprint,
            revision: remoteHead!.revision,
            dataSha256: localDataSha256,
            attachmentChecksums: localAttChecksums,
            ensureLocalTables: ensureLocalTables,
          );
          final updatedCursor = cursor.copyWith(
            lastSyncedRevision: remoteHead.revision,
            lastSyncedDataSha256: localDataSha256,
            lastSyncedAtMs: _nowMs(),
            targetFingerprint: store.targetFingerprint,
            localFullReplaceSinceLastSync: false,
            lastRemoteHeadEtag:
                remoteState.headEtag ?? cursor.lastRemoteHeadEtag,
            clearConflictRecord: true,
          );
          await _saveSyncCursor(updatedCursor, ensureSettings: settings);
          return CloudSyncOutcome(
            status: CloudSyncStatus.alreadyUpToDate,
            revision: remoteHead.revision,
            localDataSha256: localDataSha256,
            remoteHead: remoteHead,
          );

        case SyncActionType.pullRemote:
          if (remoteHead == null) {
            if (orphanRemoteDbBytes == null) {
              throw const Failure(
                FailureCode.storageUnavailable,
                '云端旧版同步快照缺失，请使用本机覆盖推送或从历史备份恢复',
              );
            }
            if (remoteState.isLegacyFormat) {
              await _archiveOrphanRemoteSnapshotIfNeeded(
                orphanBytes: orphanRemoteDbBytes,
                cloudBackupTarget: cloudBackupTarget,
              );
            }
            return _executeOrphanRemotePull(
              settings: settings,
              store: store,
              orphanDbBytes: orphanRemoteDbBytes,
              healedRevision:
                  (remoteState.legacyRevision ??
                      remoteState.orphanRevisionHint) ??
                  1,
              localAttChecksums: localAttChecksums,
            );
          }
          return _executeSyncPull(
            settings: settings,
            store: store,
            remoteHead: remoteHead,
            remoteHeadEtag: remoteState.headEtag,
            localAttChecksums: localAttChecksums,
            onProgress: onProgress,
          );

        case SyncActionType.pushLocal:
          if (orphanRemoteDbBytes != null) {
            await _archiveOrphanRemoteSnapshotIfNeeded(
              orphanBytes: orphanRemoteDbBytes,
              cloudBackupTarget: cloudBackupTarget,
            );
          }
          return _executeSyncPush(
            settings: settings,
            store: store,
            cloudBackupTarget: cloudBackupTarget,
            cursor: cursor,
            initialRemoteHead: remoteHead,
            legacyRemoteRevision:
                remoteState.legacyRevision ?? remoteState.orphanRevisionHint,
            localTables: await ensureLocalTables(),
            localAttChecksums: localAttChecksums,
            localDataSha256: localDataSha256,
            archiveCooldownMs: archiveCooldownMs,
            includeArchiveAttachments: includeArchiveAttachments,
            forceOverwriteRemote: resolution == SyncConflictResolution.useLocal,
            triggerSource: triggerSource,
            onProgress: onProgress,
            beforePushCommitForTest: beforePushCommitForTest,
          );

        case SyncActionType.conflict:
          if (resolution == null && triggerSource == AutoTriggerSource.exit) {
            // Skip heavy 3-way merge AND skip packing/dual-uploading conflict
            // archives during app exit / backgrounding so window close stays
            // instant and next launch/focus merges cleanly (`S-07`).
            return CloudSyncOutcome(
              status: CloudSyncStatus.alreadyUpToDate,
              revision: cursor.lastSyncedRevision,
              localDataSha256: localDataSha256,
              remoteHead: remoteHead,
            );
          }

          Map<String, List<Map<String, Object?>>>? preloadedRemoteTables;
          if (resolution == null &&
              remoteHead != null &&
              !remoteState.isLegacyFormat &&
              !cursor.isNeverSynced &&
              cursor.lastSyncedDataSha256 != null &&
              !cursor.localFullReplaceSinceLastSync &&
              (remoteHead.lastNonIncrementalRevision == null ||
                  remoteHead.lastNonIncrementalRevision! <=
                      cursor.lastSyncedRevision)) {
            // Crash-idempotent recovery: if an earlier merge from this device
            // already committed on remote before local DB/cursor updated, pull!
            if (remoteHead.hasCommittedMergeForLocalSha(
              deviceId: settings.deviceId,
              localDataSha256: localDataSha256,
              afterRevision: cursor.lastSyncedRevision,
            )) {
              return _executeSyncPull(
                settings: settings,
                store: store,
                remoteHead: remoteHead,
                remoteHeadEtag: remoteState.headEtag,
                localAttChecksums: localAttChecksums,
                onProgress: onProgress,
              );
            }

            final mergeAttempt = await _tryExecuteThreeWayMerge(
              settings: settings,
              store: store,
              cloudBackupTarget: cloudBackupTarget,
              cursor: cursor,
              remoteHead: remoteHead,
              remoteHeadEtag: remoteState.headEtag,
              localTables: await ensureLocalTables(),
              localAttChecksums: localAttChecksums,
              localDataSha256: localDataSha256,
              archiveCooldownMs: archiveCooldownMs,
              includeArchiveAttachments: includeArchiveAttachments,
              triggerSource: triggerSource,
              onProgress: onProgress,
              beforePushCommitForTest: beforePushCommitForTest,
            );
            if (mergeAttempt.outcome != null) {
              return mergeAttempt.outcome!;
            }
            preloadedRemoteTables = mergeAttempt.preloadedRemoteTables;
          }

          return _preserveConflictAndReport(
            settings: settings,
            store: store,
            cloudBackupTarget: cloudBackupTarget,
            cursor: cursor,
            remoteHead: remoteHead,
            fallbackRemoteRevision:
                remoteState.legacyRevision ?? remoteState.orphanRevisionHint,
            orphanRemoteLatestDbBytes: orphanRemoteDbBytes,
            isLocalFreshEmpty: isLocalFreshEmpty,
            localTables: await ensureLocalTables(),
            localAttChecksums: localAttChecksums,
            localDataSha256: localDataSha256,
            preloadedRemoteTables: preloadedRemoteTables,
          );
      }
    });
  }

  Future<void> _selfHealMissingRemoteSnapshotIfNeeded({
    required CloudSyncObjectStore store,
    required CloudSyncHead remoteHead,
    required Map<String, List<Map<String, Object?>>> localTables,
    required Map<String, String> localAttChecksums,
    required String localDataSha256,
    BackupProgressCallback? onProgress,
  }) async {
    final cleanLocalSha = localDataSha256.toLowerCase();
    final existingObj = await store.headObject(remoteHead.databasePath);
    if (existingObj != null || cleanLocalSha != remoteHead.dataSha256) {
      return;
    }

    if (localAttChecksums.isNotEmpty) {
      final existingAtts = await store.listRelativeFileNames(
        cloudSyncAttachmentsDir,
      );
      final sortedPaths = localAttChecksums.keys.toList()..sort();
      for (final archivePath in sortedPaths) {
        final sha = localAttChecksums[archivePath]!;
        final objName = buildAttachmentObjectName(
          sha256: sha,
          archivePath: archivePath,
        );
        if (existingAtts.contains(objName)) continue;
        final bytes = await _readSingleLocalAttachmentBytes(archivePath);
        await store.putObject('$cloudSyncAttachmentsDir/$objName', bytes);
      }
    }

    final healedLightweightDb = await _packArchiveOffloaded(
      tables: localTables,
      attachments: const <String, Uint8List>{},
      createdAtMs: _nowMs(),
      includeAttachments: false,
    );
    await store.putObject(
      remoteHead.databasePath,
      healedLightweightDb.bytes,
      onProgress: onProgress,
    );
  }

  Future<_RemoteHeadProbe> _readRemoteSyncHead(
    CloudSyncObjectStore store,
  ) async {
    final cond = await store.getObjectConditional(
      cloudSyncHeadPath,
      noCache: true,
    );
    final bytes = cond.bytes;
    if (bytes == null) {
      return const _RemoteHeadProbe.missing();
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } catch (_) {
      throw const Failure(FailureCode.corruptData, '远端 sync/head.json 解析失败');
    }
    if (decoded is! Map<String, Object?>) {
      throw const Failure(FailureCode.corruptData, '远端 sync/head.json 格式损坏');
    }
    if (isLegacyCloudSyncHeadJson(decoded)) {
      return const _RemoteHeadProbe.legacy();
    }
    return _RemoteHeadProbe.valid(
      CloudSyncHead.fromJson(decoded),
      etag: cond.etag,
    );
  }

  Future<_RemoteSyncState> _inspectRemoteSyncState(
    CloudSyncObjectStore store, {
    ConditionalGetResult? prefetchedHead,
  }) async {
    final headResp =
        prefetchedHead ??
        await store.getObjectConditional(cloudSyncHeadPath, noCache: true);
    final bytes = headResp.bytes;
    if (bytes != null) {
      final Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(bytes));
      } catch (_) {
        throw const Failure(FailureCode.corruptData, '远端 sync/head.json 解析失败');
      }
      if (decoded is! Map<String, Object?>) {
        throw const Failure(FailureCode.corruptData, '远端 sync/head.json 格式损坏');
      }
      if (isLegacyCloudSyncHeadJson(decoded)) {
        final rawRev = decoded['revision'];
        final legacyRev = (rawRev is int && rawRev > 0) ? rawRev : null;
        final legacyOrOrphan = await _findOrphanOrLegacyRemoteDb(store);
        return _RemoteSyncState(
          head: null,
          isLegacyFormat: true,
          legacyRevision: legacyRev,
          orphanOrLegacyDbBytes: legacyOrOrphan.bytes,
          orphanRevisionHint: legacyRev ?? legacyOrOrphan.revision,
        );
      }
      return _RemoteSyncState(
        head: CloudSyncHead.fromJson(decoded),
        headEtag: headResp.etag,
      );
    }

    final orphan = await _findOrphanOrLegacyRemoteDb(store);
    return _RemoteSyncState(
      head: null,
      orphanOrLegacyDbBytes: orphan.bytes,
      orphanRevisionHint: orphan.revision,
    );
  }

  Future<({Uint8List? bytes, int? revision})> _findOrphanOrLegacyRemoteDb(
    CloudSyncObjectStore store,
  ) async {
    final revFiles = await store.listRelativeFileNames(cloudSyncRevisionsDir);
    if (revFiles.isNotEmpty) {
      final candidates = <({int revision, String name})>[];
      for (final name in revFiles) {
        final parsed = parseSyncRevisionFileName(name);
        if (parsed != null) {
          candidates.add((revision: parsed.revision, name: name));
        }
      }
      if (candidates.isNotEmpty) {
        candidates.sort((a, b) {
          final byRev = b.revision.compareTo(a.revision);
          return byRev != 0 ? byRev : b.name.compareTo(a.name);
        });
        final newest = candidates.first;
        final revBytes = await store.getObjectOrNull(
          '$cloudSyncRevisionsDir/${newest.name}',
        );
        if (revBytes != null) {
          return (bytes: revBytes, revision: newest.revision);
        }
      }
    }

    // Also archive/recover legacy `sync/latest_db.tally` if left behind on remote
    // so zero user data is ever lost during format-1 -> format-2 transition.
    final legacyBytes = await store.getObjectOrNull(
      legacyCloudSyncLatestDbPath,
    );
    return (bytes: legacyBytes, revision: null);
  }

  Future<({Directory targetDir, Directory stagingDir, Directory backupDir})>
  _prepareSiblingAttachmentStagingDir() =>
      LocalDirectoryBackupTarget._runRootIo(() async {
        final rawTarget = await _attachmentsDirProvider();
        final targetDir = Directory(p.normalize(rawTarget.path));
        await targetDir.parent.create(recursive: true);
        final opId = '${_nowMs()}_${++_attachmentSwapSeq}';
        final stagingDir = Directory('${targetDir.path}.staging_$opId');
        final backupDir = Directory('${targetDir.path}.bak_$opId');
        if (await stagingDir.exists()) {
          await stagingDir.delete(recursive: true);
        }
        await stagingDir.create(recursive: true);
        return (
          targetDir: targetDir,
          stagingDir: stagingDir,
          backupDir: backupDir,
        );
      });

  Future<void> _stageAndVerifyAttachmentsOnSameFs({
    required Directory stagingDir,
    required Map<String, Uint8List> attachments,
    required Map<String, String> expectedChecksums,
    Map<String, String> reusableLocalPathBySha = const <String, String>{},
  }) => LocalDirectoryBackupTarget._runRootIo(() async {
    final canonicalStagingRoot = await stagingDir.resolveSymbolicLinks();
    final rawLiveDir = await _attachmentsDirProvider();
    final liveDirPath = p.normalize(rawLiveDir.path);

    for (final expected in expectedChecksums.entries) {
      final cleanArchivePath = normalizeAttachmentArchivePath(expected.key);
      final expectedSha = expected.value.toLowerCase();
      final relUnderAtt = cleanArchivePath.substring(
        tallyAttachmentsPrefix.length,
      );
      final outPath = p.normalize(
        p.joinAll(<String>[canonicalStagingRoot, ...relUnderAtt.split('/')]),
      );
      if (!p.isWithin(canonicalStagingRoot, outPath)) {
        throw Failure(FailureCode.corruptData, '拒绝越界的附件暂存路径：$cleanArchivePath');
      }
      final stagedFile = File(outPath);
      await stagedFile.parent.create(recursive: true);

      final inMemBytes = attachments[cleanArchivePath];
      if (inMemBytes != null) {
        await stagedFile.writeAsBytes(inMemBytes, flush: true);
      } else {
        final existingArchivePath = reusableLocalPathBySha[expectedSha];
        if (existingArchivePath == null) {
          throw Failure(FailureCode.corruptData, '暂存附件文件缺失：$cleanArchivePath');
        }
        final srcRel = existingArchivePath.substring(
          tallyAttachmentsPrefix.length,
        );
        final srcFile = File(
          p.joinAll(<String>[liveDirPath, ...srcRel.split('/')]),
        );
        if (!await srcFile.exists()) {
          throw Failure(
            FailureCode.corruptData,
            '本地复用附件缺失：$existingArchivePath',
          );
        }
        await srcFile.copy(outPath);
      }

      final actualSha = (await crypto.sha256.bind(stagedFile.openRead()).first)
          .toString();
      if (actualSha != expectedSha) {
        throw Failure(FailureCode.corruptData, '暂存附件哈希校验失败：$cleanArchivePath');
      }
    }
  });

  Future<void> _swapStagedAttachmentsAtomically({
    required Directory targetDir,
    required Directory stagingDir,
    required Directory backupDir,
  }) => LocalDirectoryBackupTarget._runRootIo(() async {
    var movedTargetToBak = false;
    try {
      if (await backupDir.exists()) {
        await backupDir.delete(recursive: true);
      }
      if (await targetDir.exists()) {
        await targetDir.rename(backupDir.path);
        movedTargetToBak = true;
      }
      if (beforeAttachmentSwapFinalizeForTest != null) {
        await beforeAttachmentSwapFinalizeForTest!();
      }
      await stagingDir.rename(targetDir.path);
    } catch (e) {
      if (movedTargetToBak) {
        try {
          if (await targetDir.exists()) {
            await targetDir.delete(recursive: true);
          }
          if (await backupDir.exists()) {
            await backupDir.rename(targetDir.path);
          }
        } catch (_) {}
      }
      if (e is Failure && e.code == FailureCode.storageUnavailable) {
        rethrow;
      }
      throw const Failure(
        FailureCode.storageUnavailable,
        '切换本地附件目录失败，已自动回滚原附件数据',
      );
    }

    _attHashCache = null;
    if (movedTargetToBak) {
      try {
        if (await backupDir.exists()) {
          await backupDir.delete(recursive: true);
        }
      } catch (_) {}
    }
  });

  Future<({Set<String> stagedRelPaths, Set<String> movedOutRelPaths})>
  _stageIncrementalAttachmentsOnSameFs({
    required Directory targetDir,
    required Directory stagingDir,
    required Map<String, Uint8List> attachments,
    required Map<String, String> localAttChecksums,
    required Map<String, String> expectedChecksums,
    Map<String, String> reusableLocalPathBySha = const <String, String>{},
  }) => LocalDirectoryBackupTarget._runRootIo(() async {
    final canonicalStagingRoot = await stagingDir.resolveSymbolicLinks();
    final liveDirPath = p.normalize(targetDir.path);

    final expectedNorm = <String, String>{
      for (final e in expectedChecksums.entries)
        normalizeAttachmentArchivePath(e.key): e.value.toLowerCase(),
    };
    final localNorm = <String, String>{
      for (final e in localAttChecksums.entries)
        normalizeAttachmentArchivePath(e.key): e.value.toLowerCase(),
    };

    final stagedRelPaths = <String>{};
    for (final expected in expectedNorm.entries) {
      final cleanArchivePath = expected.key;
      final expectedSha = expected.value;
      final relUnderAtt = cleanArchivePath.substring(
        tallyAttachmentsPrefix.length,
      );
      final outPath = p.normalize(
        p.joinAll(<String>[canonicalStagingRoot, ...relUnderAtt.split('/')]),
      );
      if (!p.isWithin(canonicalStagingRoot, outPath)) {
        throw Failure(FailureCode.corruptData, '拒绝越界的附件暂存路径：$cleanArchivePath');
      }

      final livePath = p.normalize(
        p.joinAll(<String>[liveDirPath, ...relUnderAtt.split('/')]),
      );
      if (localNorm[cleanArchivePath] == expectedSha &&
          !attachments.containsKey(cleanArchivePath) &&
          await File(livePath).exists()) {
        // Unchanged existing attachment: 0-byte disk copy & untouched mtime!
        continue;
      }

      final stagedFile = File(outPath);
      await stagedFile.parent.create(recursive: true);

      final inMemBytes = attachments[cleanArchivePath];
      if (inMemBytes != null) {
        await stagedFile.writeAsBytes(inMemBytes, flush: true);
      } else {
        final existingArchivePath = reusableLocalPathBySha[expectedSha];
        if (existingArchivePath == null) {
          throw Failure(FailureCode.corruptData, '暂存附件文件缺失：$cleanArchivePath');
        }
        final srcRel = existingArchivePath.substring(
          tallyAttachmentsPrefix.length,
        );
        final srcFile = File(
          p.joinAll(<String>[liveDirPath, ...srcRel.split('/')]),
        );
        if (!await srcFile.exists()) {
          throw Failure(
            FailureCode.corruptData,
            '本地复用附件缺失：$existingArchivePath',
          );
        }
        await srcFile.copy(outPath);
      }

      final actualSha = (await crypto.sha256.bind(stagedFile.openRead()).first)
          .toString();
      if (actualSha != expectedSha) {
        throw Failure(FailureCode.corruptData, '暂存附件哈希校验失败：$cleanArchivePath');
      }
      stagedRelPaths.add(relUnderAtt);
    }

    final movedOutRelPaths = <String>{};
    for (final localArchivePath in localNorm.keys) {
      final relUnderAtt = localArchivePath.substring(
        tallyAttachmentsPrefix.length,
      );
      if (!expectedNorm.containsKey(localArchivePath) ||
          stagedRelPaths.contains(relUnderAtt)) {
        movedOutRelPaths.add(relUnderAtt);
      }
    }

    return (stagedRelPaths: stagedRelPaths, movedOutRelPaths: movedOutRelPaths);
  });

  Future<void> _applyIncrementalAttachmentsAtomically({
    required Directory targetDir,
    required Directory stagingDir,
    required Directory backupDir,
    required ({Set<String> stagedRelPaths, Set<String> movedOutRelPaths}) plan,
  }) => LocalDirectoryBackupTarget._runRootIo(() async {
    final movedToBak = <({String livePath, String bakPath})>[];
    final movedFromStaging = <String>[];
    File? inProgressMarker;
    try {
      await targetDir.create(recursive: true);
      if (await backupDir.exists()) {
        await backupDir.delete(recursive: true);
      }
      await backupDir.create(recursive: true);
      inProgressMarker = File(p.join(backupDir.path, '.in_progress'));
      await inProgressMarker.writeAsString('1', flush: true);

      for (final rel in plan.movedOutRelPaths) {
        final liveFile = File(
          p.joinAll(<String>[targetDir.path, ...rel.split('/')]),
        );
        if (!await liveFile.exists()) continue;
        final bakFile = File(
          p.joinAll(<String>[backupDir.path, ...rel.split('/')]),
        );
        await bakFile.parent.create(recursive: true);
        await liveFile.rename(bakFile.path);
        movedToBak.add((livePath: liveFile.path, bakPath: bakFile.path));
      }

      if (beforeAttachmentSwapFinalizeForTest != null) {
        await beforeAttachmentSwapFinalizeForTest!();
      }

      for (final rel in plan.stagedRelPaths) {
        final stagedFile = File(
          p.joinAll(<String>[stagingDir.path, ...rel.split('/')]),
        );
        final liveFile = File(
          p.joinAll(<String>[targetDir.path, ...rel.split('/')]),
        );
        await liveFile.parent.create(recursive: true);
        await stagedFile.rename(liveFile.path);
        movedFromStaging.add(liveFile.path);
      }

      if (await inProgressMarker.exists()) {
        await inProgressMarker.delete();
      }
    } catch (e) {
      for (final livePath in movedFromStaging.reversed) {
        try {
          final f = File(livePath);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
      for (final item in movedToBak.reversed) {
        try {
          final bf = File(item.bakPath);
          if (await bf.exists()) {
            await File(item.livePath).parent.create(recursive: true);
            await bf.rename(item.livePath);
          }
        } catch (_) {}
      }
      try {
        if (inProgressMarker != null && await inProgressMarker.exists()) {
          await inProgressMarker.delete();
        }
        if (await backupDir.exists()) {
          await backupDir.delete(recursive: true);
        }
      } catch (_) {}
      if (e is Failure && e.code == FailureCode.storageUnavailable) {
        rethrow;
      }
      throw const Failure(
        FailureCode.storageUnavailable,
        '切换本地附件目录失败，已自动回滚原附件数据',
      );
    }

    final cache = _attHashCache;
    if (cache != null) {
      for (final rel in plan.movedOutRelPaths) {
        cache.remove(normalizeAttachmentArchivePath(rel));
      }
      for (final rel in plan.stagedRelPaths) {
        cache.remove(normalizeAttachmentArchivePath(rel));
      }
    }

    try {
      if (await backupDir.exists()) {
        await backupDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  static bool _sameChecksumsMap(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final e in a.entries) {
      if (b[e.key]?.toLowerCase() != e.value.toLowerCase()) return false;
    }
    return true;
  }

  Future<CloudSyncOutcome> _executeSyncPull({
    required CloudSyncSettings settings,
    required CloudSyncObjectStore store,
    required CloudSyncHead remoteHead,
    String? remoteHeadEtag,
    required Map<String, String> localAttChecksums,
    BackupProgressCallback? onProgress,
  }) async {
    final snapshotDbBytes = await store.getObject(
      remoteHead.databasePath,
      onProgress: onProgress,
    );
    final verifiedDb = await _unpackAndVerifyArchiveOffloaded(
      snapshotDbBytes,
      expectedRowCountHint: remoteHead.recordCount,
    );
    final parsedRows = _parseAndValidateAll22Tables(
      verifiedDb.tables,
      verifiedDb.manifest,
    );

    final reusableLocalPathBySha = <String, String>{
      for (final entry in localAttChecksums.entries)
        entry.value.toLowerCase(): entry.key,
    };

    final requiredAtts = remoteHead.resolvedAttachments();
    final downloadedByPath = <String, Uint8List>{};
    final downloadedBySha = <String, Uint8List>{};
    final pulledAttChecksums = <String, String>{};
    var downloadedCount = 0;

    for (final desc in requiredAtts) {
      if (!reusableLocalPathBySha.containsKey(desc.sha256)) {
        var bytes = downloadedBySha[desc.sha256];
        if (bytes == null) {
          bytes = await store.getObject(
            '$cloudSyncAttachmentsDir/${desc.objectName}',
          );
          final actualSha = sha256Hex(bytes);
          if (actualSha != desc.sha256) {
            throw Failure(
              FailureCode.corruptData,
              '远端同步附件哈希校验失败（${desc.objectName}），已拒绝拉取覆盖',
            );
          }
          downloadedBySha[desc.sha256] = bytes;
          downloadedCount++;
        }
        downloadedByPath[desc.archivePath] = bytes;
      }
      pulledAttChecksums[desc.archivePath] = desc.sha256;
    }

    final pulledCanonicalSha = await _computeDigestOffloaded(
      tables: verifiedDb.tables,
      attachmentChecksums: pulledAttChecksums,
    );
    if (pulledCanonicalSha != remoteHead.dataSha256) {
      throw const Failure(
        FailureCode.remoteUnavailable,
        '远端同步快照正在更新或校验不一致，请稍后重试',
      );
    }

    final needAttSwap =
        beforeAttachmentSwapFinalizeForTest != null ||
        !_sameChecksumsMap(localAttChecksums, pulledAttChecksums);
    final dirs = needAttSwap
        ? await _prepareSiblingAttachmentStagingDir()
        : null;
    try {
      final incPlan = dirs != null
          ? await _stageIncrementalAttachmentsOnSameFs(
              targetDir: dirs.targetDir,
              stagingDir: dirs.stagingDir,
              attachments: downloadedByPath,
              localAttChecksums: localAttChecksums,
              expectedChecksums: pulledAttChecksums,
              reusableLocalPathBySha: reusableLocalPathBySha,
            )
          : null;

      final now = _nowMs();
      final newCursor = LocalSyncCursor(
        lastSyncedRevision: remoteHead.revision,
        lastSyncedDataSha256: remoteHead.dataSha256,
        lastSyncedAtMs: now,
        targetFingerprint: store.targetFingerprint,
        localFullReplaceSinceLastSync: false,
        lastRemoteHeadEtag: remoteHeadEtag,
      );

      _internalRestoreDepth++;
      try {
        await guardDatabase(
          () => db.transaction(() async {
            await _clearAll22TablesInTransaction();
            await db.delete(db.writeCommands).go();
            await (db.delete(
              db.preferences,
            )..where((t) => t.key.equals('periodic_last_check_ms'))).go();
            await _insertAll22TablesInTransaction(parsedRows);
            await _sanitizeDiyDefaultAccountInTransaction(parsedRows.assets);
            await _alignOnlineRateCooldownInTransaction(parsedRows.currencies);

            final activeBookId = resolveRestoredActiveBookId(
              parsedRows.accountBooks.map((b) => (id: b.id, sort: b.sort)),
            );
            await db
                .into(db.preferences)
                .insertOnConflictUpdate(
                  PreferencesCompanion.insert(
                    key: prefKeyCurrentBookId,
                    value: '$activeBookId',
                  ),
                );
          }),
        );

        if (dirs != null && incPlan != null) {
          await _applyIncrementalAttachmentsAtomically(
            targetDir: dirs.targetDir,
            stagingDir: dirs.stagingDir,
            backupDir: dirs.backupDir,
            plan: incPlan,
          );
        }

        _invalidateLocalTableDigestCache();
        await _writeSyncBaseSnapshot(
          targetFingerprint: store.targetFingerprint,
          revision: remoteHead.revision,
          dataSha256: remoteHead.dataSha256,
          lightweightDbBytes: snapshotDbBytes,
          attachmentChecksums: pulledAttChecksums,
        );

        // Persist sync cursor ONLY AFTER same-FS attachment swap succeeds (`S-02`).
        await _saveSyncCursor(newCursor, ensureSettings: settings);
        await reminderService.resyncAll();
      } finally {
        await Future<void>.microtask(() {});
        await Future<void>.microtask(() {});
        _internalRestoreDepth--;
      }

      return CloudSyncOutcome(
        status: CloudSyncStatus.pulled,
        revision: remoteHead.revision,
        localDataSha256: remoteHead.dataSha256,
        remoteHead: remoteHead,
        downloadedAttachments: downloadedCount,
      );
    } finally {
      if (dirs != null) {
        try {
          if (await dirs.stagingDir.exists()) {
            await dirs.stagingDir.delete(recursive: true);
          }
        } catch (_) {}
      }
    }
  }

  Future<CloudSyncOutcome> _executeSyncPush({
    required CloudSyncSettings settings,
    required CloudSyncObjectStore store,
    required BackupTarget cloudBackupTarget,
    required LocalSyncCursor cursor,
    required CloudSyncHead? initialRemoteHead,
    int? legacyRemoteRevision,
    required Map<String, List<Map<String, Object?>>> localTables,
    required Map<String, String> localAttChecksums,
    required String localDataSha256,
    required int archiveCooldownMs,
    required bool includeArchiveAttachments,
    required bool forceOverwriteRemote,
    AutoTriggerSource? triggerSource,
    BackupProgressCallback? onProgress,
    FutureOr<void> Function()? beforePushCommitForTest,
  }) async {
    // 1. Zero-LIST deduplicated attachment upload (`sync/attachments/<sha256>__<basename>`):
    // When `initialRemoteHead != null` and not force-overwriting, diff directly
    // against `initialRemoteHead.attachmentFiles` (`0` remote LIST calls).
    final objectArchivePaths = <String, String>{};
    final sortedArchivePaths = localAttChecksums.keys.toList()..sort();
    for (final archivePath in sortedArchivePaths) {
      final sha = localAttChecksums[archivePath]!;
      final objName = buildAttachmentObjectName(
        sha256: sha,
        archivePath: archivePath,
      );
      objectArchivePaths.putIfAbsent(objName, () => archivePath);
    }

    var uploadedCount = 0;
    if (objectArchivePaths.isNotEmpty) {
      final Set<String> existingRemote;
      if (initialRemoteHead != null && !forceOverwriteRemote) {
        existingRemote = initialRemoteHead.attachmentFiles.toSet();
      } else {
        existingRemote = await store.listRelativeFileNames(
          cloudSyncAttachmentsDir,
        );
      }
      for (final entry in objectArchivePaths.entries) {
        if (existingRemote.contains(entry.key)) continue;
        final bytes = await _readSingleLocalAttachmentBytes(entry.value);
        await store.putObject('$cloudSyncAttachmentsDir/${entry.key}', bytes);
        uploadedCount++;
      }
    }

    // 2. Pack lightweight DB snapshot (offloaded to Isolate for >= 1000 rows)
    // and re-read `sync/head.json` right before committing (`S-01`).
    final now = _nowMs();
    final lightweightDb = await _packArchiveOffloaded(
      tables: localTables,
      attachments: const <String, Uint8List>{},
      createdAtMs: now,
      includeAttachments: false,
    );

    if (beforePushCommitForTest != null) {
      await beforePushCommitForTest();
    }
    final freshState = await _inspectRemoteSyncState(store);
    final freshHead = freshState.head;
    if (!forceOverwriteRemote) {
      final raced =
          freshState.isLegacyFormat ||
          (initialRemoteHead == null &&
              (freshHead != null ||
                  freshState.orphanOrLegacyDbBytes != null)) ||
          (initialRemoteHead != null &&
              (freshHead == null ||
                  freshHead.revision != initialRemoteHead.revision ||
                  freshHead.dataSha256 != initialRemoteHead.dataSha256));
      if (raced) {
        if (freshHead != null && freshHead.dataSha256 == localDataSha256) {
          await _writeSyncBaseSnapshot(
            targetFingerprint: store.targetFingerprint,
            revision: freshHead.revision,
            dataSha256: localDataSha256,
            lightweightDbBytes: lightweightDb.bytes,
            attachmentChecksums: localAttChecksums,
          );
          final aligned = cursor.copyWith(
            lastSyncedRevision: freshHead.revision,
            lastSyncedDataSha256: localDataSha256,
            lastSyncedAtMs: _nowMs(),
            targetFingerprint: store.targetFingerprint,
            localFullReplaceSinceLastSync: false,
            lastRemoteHeadEtag: freshState.headEtag,
            clearConflictRecord: true,
          );
          await _saveSyncCursor(aligned, ensureSettings: settings);
          return CloudSyncOutcome(
            status: CloudSyncStatus.alreadyUpToDate,
            revision: freshHead.revision,
            localDataSha256: localDataSha256,
            remoteHead: freshHead,
          );
        }

        if (triggerSource == AutoTriggerSource.exit) {
          return CloudSyncOutcome(
            status: CloudSyncStatus.alreadyUpToDate,
            revision: cursor.lastSyncedRevision,
            localDataSha256: localDataSha256,
            remoteHead: freshHead,
          );
        }

        if (freshHead != null &&
            !freshState.isLegacyFormat &&
            !cursor.isNeverSynced &&
            cursor.lastSyncedDataSha256 != null &&
            !cursor.localFullReplaceSinceLastSync &&
            (freshHead.lastNonIncrementalRevision == null ||
                freshHead.lastNonIncrementalRevision! <=
                    cursor.lastSyncedRevision)) {
          final racedMerge = await _tryExecuteThreeWayMerge(
            settings: settings,
            store: store,
            cloudBackupTarget: cloudBackupTarget,
            cursor: cursor,
            remoteHead: freshHead,
            remoteHeadEtag: freshState.headEtag,
            localTables: localTables,
            localAttChecksums: localAttChecksums,
            localDataSha256: localDataSha256,
            archiveCooldownMs: archiveCooldownMs,
            includeArchiveAttachments: includeArchiveAttachments,
            triggerSource: triggerSource,
            onProgress: onProgress,
          );
          if (racedMerge.outcome != null) {
            return racedMerge.outcome!;
          }
          return _preserveConflictAndReport(
            settings: settings,
            store: store,
            cloudBackupTarget: cloudBackupTarget,
            cursor: cursor,
            remoteHead: freshHead,
            fallbackRemoteRevision:
                freshState.legacyRevision ?? freshState.orphanRevisionHint,
            orphanRemoteLatestDbBytes: freshState.orphanOrLegacyDbBytes,
            isLocalFreshEmpty: false,
            localTables: localTables,
            localAttChecksums: localAttChecksums,
            localDataSha256: localDataSha256,
            preloadedRemoteTables: racedMerge.preloadedRemoteTables,
          );
        }

        return _preserveConflictAndReport(
          settings: settings,
          store: store,
          cloudBackupTarget: cloudBackupTarget,
          cursor: cursor,
          remoteHead: freshHead,
          fallbackRemoteRevision:
              freshState.legacyRevision ?? freshState.orphanRevisionHint,
          orphanRemoteLatestDbBytes: freshState.orphanOrLegacyDbBytes,
          isLocalFreshEmpty: false,
          localTables: localTables,
          localAttChecksums: localAttChecksums,
          localDataSha256: localDataSha256,
        );
      }
    }

    // 3. Upload immutable `sync/revisions/db_r<rev>_<sha16>.tally` BEFORE
    // updating `sync/head.json` (`S-01`).
    final baseRevision =
        freshHead?.revision ??
        initialRemoteHead?.revision ??
        freshState.legacyRevision ??
        legacyRemoteRevision ??
        0;
    final nextRevision = baseRevision + 1;
    final revisionPath = buildCloudSyncRevisionPath(
      revision: nextRevision,
      dataSha256: localDataSha256,
    );
    await store.putObject(
      revisionPath,
      lightweightDb.bytes,
      onProgress: onProgress,
    );

    final priorHead = freshHead ?? initialRemoteHead;
    final isNonIncremental =
        forceOverwriteRemote ||
        priorHead == null ||
        cursor.localFullReplaceSinceLastSync;
    final nextNonIncRev = isNonIncremental
        ? nextRevision
        : priorHead.lastNonIncrementalRevision;
    final nextRecent = appendSyncRevisionHistory(
      priorHead?.recentRevisions ?? const <SyncRevisionHistoryEntry>[],
      SyncRevisionHistoryEntry(
        revision: nextRevision,
        dataSha256: localDataSha256,
        deviceId: settings.deviceId,
      ),
    );

    // 4. Commit `sync/head.json` (`format: 2` with `databasePath`).
    final newHead = CloudSyncHead(
      format: currentCloudSyncHeadFormat,
      revision: nextRevision,
      dataSha256: localDataSha256,
      databasePath: revisionPath,
      updatedAtMs: now,
      deviceId: settings.deviceId,
      deviceName: settings.deviceName,
      recordCount: (localTables['record'] ?? const <Object?>[]).length,
      attachmentFiles: objectArchivePaths.keys.toList()..sort(),
      attachmentManifest: localAttChecksums,
      recentRevisions: nextRecent,
      lastNonIncrementalRevision: nextNonIncRev,
    );
    final headCommit = await _commitSyncHeadSafely(
      store: store,
      newHead: newHead,
      revisionPath: revisionPath,
    );
    final committedHead = headCommit.head;

    await _writeSyncBaseSnapshot(
      targetFingerprint: store.targetFingerprint,
      revision: nextRevision,
      dataSha256: localDataSha256,
      lightweightDbBytes: lightweightDb.bytes,
      attachmentChecksums: localAttChecksums,
    );

    // 5. Persist local `prefKeyCloudSyncCursor` (clearing any conflict record).
    final updatedCursor = LocalSyncCursor(
      lastSyncedRevision: nextRevision,
      lastSyncedDataSha256: localDataSha256,
      lastSyncedAtMs: now,
      targetFingerprint: store.targetFingerprint,
      localFullReplaceSinceLastSync: false,
      lastRemoteHeadEtag: headCommit.etag,
    );
    await _saveSyncCursor(updatedCursor, ensureSettings: settings);

    if (triggerSource == AutoTriggerSource.exit) {
      return CloudSyncOutcome(
        status: CloudSyncStatus.pushed,
        revision: nextRevision,
        localDataSha256: localDataSha256,
        remoteHead: committedHead,
        uploadedAttachments: uploadedCount,
      );
    }

    // 6. Best-effort prune superseded `sync/revisions/*` objects (Top-5 `< nextRevision`).
    await _pruneSupersededRemoteRevisionsBestEffort(
      store: store,
      nextRevision: nextRevision,
      revisionPath: revisionPath,
      previousDatabasePath: priorHead?.databasePath,
    );
    await _runLowFrequencyRemoteMaintenanceIfNeeded(
      store: store,
      nowMs: now,
      committedHead: committedHead,
    );

    // 7. Optional 24h full versioned `.tally` archive backup & pruning.
    String? archivedName;
    if (settings.autoArchiveBackupEnabled) {
      archivedName = await _maybeCreateSyncArchiveBackup(
        cloudBackupTarget: cloudBackupTarget,
        localTables: localTables,
        includeArchiveAttachments: includeArchiveAttachments,
        archiveCooldownMs: archiveCooldownMs,
        nowMs: now,
      );
    }

    return CloudSyncOutcome(
      status: CloudSyncStatus.pushed,
      revision: nextRevision,
      localDataSha256: localDataSha256,
      remoteHead: committedHead,
      uploadedAttachments: uploadedCount,
      archivedBackupFileName: archivedName,
    );
  }

  Future<({CloudSyncHead head, String? etag})> _commitSyncHeadSafely({
    required CloudSyncObjectStore store,
    required CloudSyncHead newHead,
    required String revisionPath,
  }) async {
    final headBytes = Uint8List.fromList(
      utf8.encode(const JsonEncoder.withIndent('  ').convert(newHead.toJson())),
    );
    try {
      final etag = await store.putObjectReturningEtag(
        cloudSyncHeadPath,
        headBytes,
        contentType: 'application/json; charset=utf-8',
      );
      return (head: newHead, etag: etag);
    } catch (_) {
      _RemoteHeadProbe? remoteProbe;
      try {
        remoteProbe = await _readRemoteSyncHead(store);
      } catch (_) {
        remoteProbe = null;
      }
      if (remoteProbe == null) {
        rethrow;
      }
      final probedHead = remoteProbe.head;
      if (probedHead != null &&
          probedHead.revision == newHead.revision &&
          probedHead.dataSha256 == newHead.dataSha256.toLowerCase() &&
          probedHead.databasePath == revisionPath) {
        return (head: probedHead, etag: remoteProbe.etag);
      }
      if (probedHead == null || probedHead.databasePath != revisionPath) {
        try {
          await store.deleteObject(revisionPath);
        } catch (_) {}
      }
      rethrow;
    }
  }

  Future<void> _pruneSupersededRemoteRevisionsBestEffort({
    required CloudSyncObjectStore store,
    required int nextRevision,
    required String revisionPath,
    required String? previousDatabasePath,
  }) async {
    if (nextRevision <= 1) return;
    try {
      final existingRevFiles = await store.listRelativeFileNames(
        cloudSyncRevisionsDir,
      );
      final superseded = selectSupersededSyncRevisionFileNames(
        existingRevFiles,
        currentRevision: nextRevision,
        currentDatabasePath: revisionPath,
        previousDatabasePath: previousDatabasePath,
      );
      for (final oldFile in superseded) {
        await store.deleteObject('$cloudSyncRevisionsDir/$oldFile');
      }
    } catch (_) {
      // Best-effort revision cleanup never fails a committed sync push.
    }
  }

  Future<String?> _maybeCreateSyncArchiveBackup({
    required BackupTarget cloudBackupTarget,
    required Map<String, List<Map<String, Object?>>> localTables,
    required bool includeArchiveAttachments,
    required int archiveCooldownMs,
    required int nowMs,
  }) async {
    try {
      final lastBackupAt = await getLastBackupAtMs();
      if (lastBackupAt != null && (nowMs - lastBackupAt) < archiveCooldownMs) {
        return null;
      }
      final archiveAttachments = includeArchiveAttachments
          ? await _collectLocalAttachments()
          : const <String, Uint8List>{};
      final archivePack = await _packArchiveOffloaded(
        tables: localTables,
        attachments: archiveAttachments,
        createdAtMs: nowMs,
        includeAttachments: includeArchiveAttachments,
      );
      final existingCloudNames = await cloudBackupTarget.listBackups().then(
        (items) => items.map((e) => e.fileName),
        onError: (_) => const <String>[],
      );
      final archiveFileName = formatTallyBackupFileName(
        DateTime.fromMillisecondsSinceEpoch(nowMs),
        existingFileNames: existingCloudNames,
      );
      final archived = await cloudBackupTarget.writeBackup(
        archiveFileName,
        archivePack.bytes,
      );
      await _recordCompletedBackupState(nowMs);
      return archived.fileName;
    } catch (_) {
      return null;
    }
  }

  Future<void> _runLowFrequencyRemoteMaintenanceIfNeeded({
    required CloudSyncObjectStore store,
    required int nowMs,
    CloudSyncHead? committedHead,
  }) async {
    const maintenanceCooldownMs = 24 * 60 * 60 * 1000;
    try {
      final lastGcRow = await guardDatabase(
        () =>
            (db.select(db.preferences)
                  ..where((t) => t.key.equals(prefKeyCloudSyncLastGcAtMs)))
                .getSingleOrNull(),
      );
      final lastGcMs = lastGcRow == null ? null : int.tryParse(lastGcRow.value);
      if (lastGcMs != null && (nowMs - lastGcMs) < maintenanceCooldownMs) {
        return;
      }

      final liveHead = committedHead ?? (await _readRemoteSyncHead(store)).head;
      if (liveHead == null) return;

      // On brand-new `r1` bootstrap (`lastGcMs == null`), seed the 24h timer
      // without issuing redundant directory LIST sweeps against an empty store.
      if (lastGcMs == null && liveHead.revision <= 1) {
        await guardDatabase(
          () => db
              .into(db.preferences)
              .insertOnConflictUpdate(
                PreferencesCompanion.insert(
                  key: prefKeyCloudSyncLastGcAtMs,
                  value: '$nowMs',
                ),
              ),
        );
        return;
      }

      // 1. Prune abandoned future revision files (`> liveHead.revision`, >= 2h old).
      final revEntries = await store.listRelativeEntriesWithMetadataOrNull(
        cloudSyncRevisionsDir,
        includeTmp: true,
      );
      if (revEntries != null) {
        final staleFuture = selectStaleFutureOrphanRevisionFileNames(
          revEntries.map(
            (e) => (fileName: e.fileName, modifiedAtMs: e.modifiedAtMs),
          ),
          headRevision: liveHead.revision,
          nowMs: nowMs,
        );
        for (final f in staleFuture) {
          try {
            await store.deleteObject('$cloudSyncRevisionsDir/$f');
          } catch (_) {}
        }
      }

      // 2. Prune stale `*.tmp` staging files (`>= 24h` old), caching `attMeta`.
      List<RemoteEntryMetadata>? attMeta;
      for (final dir in const <String>[
        '',
        'sync',
        cloudSyncRevisionsDir,
        cloudSyncAttachmentsDir,
      ]) {
        final List<RemoteEntryMetadata>? meta;
        if (dir == cloudSyncRevisionsDir) {
          meta = revEntries;
        } else {
          meta = await store.listRelativeEntriesWithMetadataOrNull(
            dir,
            includeTmp: true,
          );
          if (dir == cloudSyncAttachmentsDir) {
            attMeta = meta;
          }
        }
        if (meta == null) continue;
        for (final entry in meta) {
          if (!entry.fileName.toLowerCase().endsWith('.tmp')) continue;
          final modMs = entry.modifiedAtMs;
          if (modMs == null || modMs <= 0) continue;
          if ((nowMs - modMs) >= defaultOrphanTmpMinAgeMs) {
            final relPath = dir.isEmpty
                ? entry.fileName
                : '$dir/${entry.fileName}';
            try {
              await store.deleteObject(relPath);
            } catch (_) {}
          }
        }
      }

      // 3. 30-day dual-watermark attachment GC (`sync/gc_pending.json` + `sync/conflict_refs/*.json`).
      if (attMeta != null && (attMeta.isNotEmpty || lastGcMs != null)) {
        final minRetainedRev = computeMinRetainedSyncRevision(
          revEntries?.map((e) => e.fileName) ??
              <String>[p.basename(liveHead.databasePath)],
          currentRevision: liveHead.revision,
        );
        final referenced = <String>{...liveHead.attachmentFiles};

        try {
          final lockFiles = await store.listRelativeFileNames(
            cloudSyncConflictRefsDir,
          );
          for (final lf in lockFiles) {
            if (!lf.toLowerCase().endsWith('.json')) continue;
            final rawLock = await store.getObjectOrNull(
              '$cloudSyncConflictRefsDir/$lf',
            );
            if (rawLock == null) continue;
            try {
              final decoded = jsonDecode(utf8.decode(rawLock));
              if (decoded is Map<String, Object?>) {
                final lock = ConflictAttachmentRefLock.fromJson(decoded);
                referenced.addAll(lock.attachmentFiles);
              }
            } catch (_) {}
          }
        } catch (_) {}

        final prevPending = <String, GcPendingEntry>{};
        try {
          final rawGc = await store.getObjectOrNull(cloudSyncGcPendingPath);
          if (rawGc != null) {
            final decoded = jsonDecode(utf8.decode(rawGc));
            if (decoded is Map<String, Object?>) {
              final entriesMap = decoded['entries'];
              if (entriesMap is Map<String, Object?>) {
                for (final e in entriesMap.entries) {
                  if (e.value is Map<String, Object?>) {
                    try {
                      prevPending[e.key] = GcPendingEntry.fromJson(
                        e.value! as Map<String, Object?>,
                      );
                    } catch (_) {}
                  }
                }
              }
            }
          }
        } catch (_) {}

        final gcEval = evaluateAttachmentGarbageCollection(
          existingRemoteAttachments: <String, int?>{
            for (final e in attMeta) e.fileName: e.modifiedAtMs,
          },
          referencedObjectNames: referenced,
          previousPending: prevPending,
          currentRevision: liveHead.revision,
          minRetainedRevision: minRetainedRev,
          nowMs: nowMs,
        );

        if (gcEval.toDelete.isNotEmpty) {
          final recheck = (await _readRemoteSyncHead(store)).head;
          if (recheck != null) {
            final liveProtected = recheck.attachmentFiles.toSet();
            for (final objName in gcEval.toDelete) {
              if (liveProtected.contains(objName)) continue;
              try {
                await store.deleteObject('$cloudSyncAttachmentsDir/$objName');
              } catch (_) {}
            }
          }
        }

        final pendingChanged =
            gcEval.toDelete.isNotEmpty ||
            gcEval.nextPending.length != prevPending.length ||
            gcEval.nextPending.entries.any((e) {
              final pEntry = prevPending[e.key];
              return pEntry == null ||
                  pEntry.unreferencedSinceMs != e.value.unreferencedSinceMs ||
                  pEntry.unreferencedAtRevision !=
                      e.value.unreferencedAtRevision;
            });
        if (pendingChanged) {
          final gcJson = jsonEncode(<String, Object>{
            'updatedAtMs': nowMs,
            'entries': <String, Object>{
              for (final e in gcEval.nextPending.entries)
                e.key: e.value.toJson(),
            },
          });
          await store.putObject(
            cloudSyncGcPendingPath,
            Uint8List.fromList(utf8.encode(gcJson)),
            contentType: 'application/json; charset=utf-8',
          );
        }
      }

      await _pruneExpiredWriteCommandsBestEffort(nowMs);
      await guardDatabase(
        () => db
            .into(db.preferences)
            .insertOnConflictUpdate(
              PreferencesCompanion.insert(
                key: prefKeyCloudSyncLastGcAtMs,
                value: '$nowMs',
              ),
            ),
      );
    } catch (_) {
      // Low-frequency GC is strictly best-effort and never fails user sync.
    }
  }

  Future<
    ({
      CloudSyncOutcome? outcome,
      Map<String, List<Map<String, Object?>>>? preloadedRemoteTables,
    })
  >
  _tryExecuteThreeWayMerge({
    required CloudSyncSettings settings,
    required CloudSyncObjectStore store,
    required BackupTarget cloudBackupTarget,
    required LocalSyncCursor cursor,
    required CloudSyncHead remoteHead,
    required String? remoteHeadEtag,
    required Map<String, List<Map<String, Object?>>> localTables,
    required Map<String, String> localAttChecksums,
    required String localDataSha256,
    required int archiveCooldownMs,
    required bool includeArchiveAttachments,
    required AutoTriggerSource? triggerSource,
    BackupProgressCallback? onProgress,
    FutureOr<void> Function()? beforePushCommitForTest,
  }) async {
    final remoteResolvedAttChecksums = <String, String>{
      for (final d in remoteHead.resolvedAttachments()) d.archivePath: d.sha256,
    };
    final baseLoaded = await _loadSyncBaseOrRemoteAncestor(
      store: store,
      targetFingerprint: store.targetFingerprint,
      lastSyncedRevision: cursor.lastSyncedRevision,
      lastSyncedDataSha256: cursor.lastSyncedDataSha256!,
      localAttChecksums: localAttChecksums,
      remoteAttChecksums: remoteResolvedAttChecksums,
    );
    if (baseLoaded == null) {
      return (outcome: null, preloadedRemoteTables: null);
    }

    final remoteDbBytes = await store.getObjectOrNull(remoteHead.databasePath);
    if (remoteDbBytes == null) {
      return (outcome: null, preloadedRemoteTables: null);
    }
    final now = _nowMs();
    final ({
      bool merged,
      Map<String, List<Map<String, Object?>>>? remoteTables,
      Map<String, List<Map<String, Object?>>>? mergedTables,
      Map<String, MergedAttachmentEntry>? mergedAttachments,
      Map<String, SyncTableDelta>? tableDeltas,
      String? mergedDataSha256,
      Uint8List? mergedLightweightDbBytes,
    })
    offloaded;
    try {
      offloaded = await _runTwoPhaseThreeWayMergeOffloaded(
        baseDbBytes: baseLoaded.lightweightDbBytes,
        baseAttChecksums: baseLoaded.attachmentChecksums,
        localTables: localTables,
        localAttChecksums: localAttChecksums,
        remoteDbBytes: remoteDbBytes,
        remoteHead: remoteHead,
        nowMs: now,
      );
    } on Failure catch (e) {
      if (e.code == FailureCode.corruptData) {
        return (outcome: null, preloadedRemoteTables: null);
      }
      rethrow;
    }

    if (!offloaded.merged) {
      return (outcome: null, preloadedRemoteTables: offloaded.remoteTables);
    }

    final mergedTables = offloaded.mergedTables!;
    final mergedAttachments = offloaded.mergedAttachments!;
    final tableDeltas = offloaded.tableDeltas!;
    final mergedDataSha256 = offloaded.mergedDataSha256!;
    final mergedAttChecksums = <String, String>{
      for (final e in mergedAttachments.entries) e.key: e.value.sha256,
    };

    // Verify remote snapshot integrity before mutating anything locally or remotely!
    final remoteCanonicalSha = await _computeDigestOffloaded(
      tables: offloaded.remoteTables!,
      attachmentChecksums: remoteResolvedAttChecksums,
    );
    if (remoteCanonicalSha != remoteHead.dataSha256) {
      throw const Failure(
        FailureCode.remoteUnavailable,
        '远端同步快照正在更新或校验不一致，请稍后重试',
      );
    }

    final reusableLocalPathBySha = <String, String>{
      for (final entry in localAttChecksums.entries)
        entry.value.toLowerCase(): entry.key,
    };
    final remoteObjBySha = <String, String>{};
    for (final desc in remoteHead.resolvedAttachments()) {
      remoteObjBySha.putIfAbsent(desc.sha256, () => desc.objectName);
    }

    // Download any remote-only merged attachments and upload any local-only ones.
    final downloadedByPath = <String, Uint8List>{};
    final downloadedBySha = <String, Uint8List>{};
    var downloadedCount = 0;
    var uploadedCount = 0;

    final mergedObjectNames = <String>{};
    final knownRemoteObjects = remoteHead.attachmentFiles.toSet();
    final convergesToRemoteHead = mergedDataSha256 == remoteHead.dataSha256;

    final sortedMergedAttPaths = mergedAttachments.keys.toList()..sort();
    for (final archivePath in sortedMergedAttPaths) {
      final item = mergedAttachments[archivePath]!;
      final objName = buildAttachmentObjectName(
        sha256: item.sha256,
        archivePath: archivePath,
      );
      mergedObjectNames.add(objName);

      if (!reusableLocalPathBySha.containsKey(item.sha256)) {
        final remoteObjName = remoteObjBySha[item.sha256] ?? objName;
        var bytes = downloadedBySha[item.sha256];
        if (bytes == null) {
          bytes = await store.getObject(
            '$cloudSyncAttachmentsDir/$remoteObjName',
          );
          if (sha256Hex(bytes) != item.sha256) {
            throw Failure(
              FailureCode.corruptData,
              '远端同步附件哈希校验失败（$remoteObjName），已拒绝合并',
            );
          }
          downloadedBySha[item.sha256] = bytes;
          downloadedCount++;
        }
        downloadedByPath[archivePath] = bytes;
      }

      if (!convergesToRemoteHead && !knownRemoteObjects.contains(objName)) {
        final Uint8List uploadBytes;
        if (downloadedByPath.containsKey(archivePath)) {
          uploadBytes = downloadedByPath[archivePath]!;
        } else {
          final localPath = reusableLocalPathBySha[item.sha256] ?? archivePath;
          uploadBytes = await _readSingleLocalAttachmentBytes(localPath);
        }
        await store.putObject('$cloudSyncAttachmentsDir/$objName', uploadBytes);
        knownRemoteObjects.add(objName);
        uploadedCount++;
      }
    }

    final needAttSwap =
        beforeAttachmentSwapFinalizeForTest != null ||
        !_sameChecksumsMap(localAttChecksums, mergedAttChecksums);
    final dirs = needAttSwap
        ? await _prepareSiblingAttachmentStagingDir()
        : null;

    try {
      final incPlan = dirs != null
          ? await _stageIncrementalAttachmentsOnSameFs(
              targetDir: dirs.targetDir,
              stagingDir: dirs.stagingDir,
              attachments: downloadedByPath,
              localAttChecksums: localAttChecksums,
              expectedChecksums: mergedAttChecksums,
              reusableLocalPathBySha: reusableLocalPathBySha,
            )
          : null;

      // Silent Convergence (`mergedDataSha256 == remoteHead.dataSha256`):
      // Both devices produced equivalent auto-derived catch-ups; align local DB
      // to Remote without bumping remote `revision`!
      if (convergesToRemoteHead) {
        _internalRestoreDepth++;
        try {
          await guardDatabase(
            () => db.transaction(
              () => _applySyncTableDeltasInTransaction(
                tableDeltas: tableDeltas,
                mergedTables: mergedTables,
              ),
            ),
          );
          if (dirs != null && incPlan != null) {
            await _applyIncrementalAttachmentsAtomically(
              targetDir: dirs.targetDir,
              stagingDir: dirs.stagingDir,
              backupDir: dirs.backupDir,
              plan: incPlan,
            );
          }
          _invalidateLocalTableDigestCache();
          await _writeSyncBaseSnapshot(
            targetFingerprint: store.targetFingerprint,
            revision: remoteHead.revision,
            dataSha256: remoteHead.dataSha256,
            lightweightDbBytes: remoteDbBytes,
            attachmentChecksums: mergedAttChecksums,
          );
          await _saveSyncCursor(
            LocalSyncCursor(
              lastSyncedRevision: remoteHead.revision,
              lastSyncedDataSha256: remoteHead.dataSha256,
              lastSyncedAtMs: now,
              targetFingerprint: store.targetFingerprint,
              localFullReplaceSinceLastSync: false,
              lastRemoteHeadEtag: remoteHeadEtag,
            ),
            ensureSettings: settings,
          );
          await reminderService.resyncAll();
        } finally {
          await Future<void>.microtask(() {});
          await Future<void>.microtask(() {});
          _internalRestoreDepth--;
        }

        return (
          outcome: CloudSyncOutcome(
            status: CloudSyncStatus.pulled,
            revision: remoteHead.revision,
            localDataSha256: remoteHead.dataSha256,
            remoteHead: remoteHead,
            downloadedAttachments: downloadedCount,
          ),
          preloadedRemoteTables: null,
        );
      }

      final mergedLightweightDbBytes = offloaded.mergedLightweightDbBytes!;
      if (beforePushCommitForTest != null) {
        await beforePushCommitForTest();
      }

      final freshState = await _inspectRemoteSyncState(store);
      final freshHead = freshState.head;
      if (freshState.isLegacyFormat ||
          freshHead == null ||
          freshHead.revision != remoteHead.revision ||
          freshHead.dataSha256 != remoteHead.dataSha256) {
        return (outcome: null, preloadedRemoteTables: null);
      }

      final nextRevision = remoteHead.revision + 1;
      final revisionPath = buildCloudSyncRevisionPath(
        revision: nextRevision,
        dataSha256: mergedDataSha256,
      );
      await store.putObject(
        revisionPath,
        mergedLightweightDbBytes,
        onProgress: onProgress,
      );

      final nextRecent = appendSyncRevisionHistory(
        remoteHead.recentRevisions,
        SyncRevisionHistoryEntry(
          revision: nextRevision,
          dataSha256: mergedDataSha256,
          deviceId: settings.deviceId,
          mergedParentSha: localDataSha256,
        ),
      );
      final newHead = CloudSyncHead(
        format: currentCloudSyncHeadFormat,
        revision: nextRevision,
        dataSha256: mergedDataSha256,
        databasePath: revisionPath,
        updatedAtMs: now,
        deviceId: settings.deviceId,
        deviceName: settings.deviceName,
        recordCount: (mergedTables['record'] ?? const <Object?>[]).length,
        attachmentFiles: mergedObjectNames.toList()..sort(),
        attachmentManifest: mergedAttChecksums,
        recentRevisions: nextRecent,
        lastNonIncrementalRevision: remoteHead.lastNonIncrementalRevision,
      );

      final headCommit = await _commitSyncHeadSafely(
        store: store,
        newHead: newHead,
        revisionPath: revisionPath,
      );
      final committedHead = headCommit.head;

      _internalRestoreDepth++;
      try {
        await guardDatabase(
          () => db.transaction(
            () => _applySyncTableDeltasInTransaction(
              tableDeltas: tableDeltas,
              mergedTables: mergedTables,
            ),
          ),
        );
        if (dirs != null && incPlan != null) {
          await _applyIncrementalAttachmentsAtomically(
            targetDir: dirs.targetDir,
            stagingDir: dirs.stagingDir,
            backupDir: dirs.backupDir,
            plan: incPlan,
          );
        }
        _invalidateLocalTableDigestCache();
        await _writeSyncBaseSnapshot(
          targetFingerprint: store.targetFingerprint,
          revision: nextRevision,
          dataSha256: mergedDataSha256,
          lightweightDbBytes: mergedLightweightDbBytes,
          attachmentChecksums: mergedAttChecksums,
        );
        await _saveSyncCursor(
          LocalSyncCursor(
            lastSyncedRevision: nextRevision,
            lastSyncedDataSha256: mergedDataSha256,
            lastSyncedAtMs: now,
            targetFingerprint: store.targetFingerprint,
            localFullReplaceSinceLastSync: false,
            lastRemoteHeadEtag: headCommit.etag,
          ),
          ensureSettings: settings,
        );
        await reminderService.resyncAll();
      } finally {
        await Future<void>.microtask(() {});
        await Future<void>.microtask(() {});
        _internalRestoreDepth--;
      }

      await _pruneSupersededRemoteRevisionsBestEffort(
        store: store,
        nextRevision: nextRevision,
        revisionPath: revisionPath,
        previousDatabasePath: remoteHead.databasePath,
      );
      await _runLowFrequencyRemoteMaintenanceIfNeeded(
        store: store,
        nowMs: now,
        committedHead: committedHead,
      );

      String? archivedName;
      if (settings.autoArchiveBackupEnabled) {
        archivedName = await _maybeCreateSyncArchiveBackup(
          cloudBackupTarget: cloudBackupTarget,
          localTables: mergedTables,
          includeArchiveAttachments: includeArchiveAttachments,
          archiveCooldownMs: archiveCooldownMs,
          nowMs: now,
        );
      }

      return (
        outcome: CloudSyncOutcome(
          status: CloudSyncStatus.pushed,
          revision: nextRevision,
          localDataSha256: mergedDataSha256,
          remoteHead: committedHead,
          uploadedAttachments: uploadedCount,
          downloadedAttachments: downloadedCount,
          archivedBackupFileName: archivedName,
          didMerge: true,
        ),
        preloadedRemoteTables: null,
      );
    } finally {
      if (dirs != null) {
        try {
          if (await dirs.stagingDir.exists()) {
            await dirs.stagingDir.delete(recursive: true);
          }
        } catch (_) {}
      }
    }
  }

  String? _lastArchivedOrphanRemoteSha256;
  String? _lastArchivedOrphanRemoteFileName;

  Future<Set<String>> _collectExistingConflictAndBackupFileNames(
    BackupTarget cloudBackupTarget,
  ) async {
    final resolvedLocal = await _resolveActiveLocalTarget();
    final activeLocalNames = resolvedLocal.externalBinding != null
        ? await _fileAccess
              .listExternalDirectoryFiles(resolvedLocal.externalBinding!)
              .then(
                (items) => items.map((e) => e.fileName),
                onError: (_) => const <String>[],
              )
        : const <String>[];
    final sandboxNames = await localTarget.listBackups().then(
      (items) => items.map((e) => e.fileName),
      onError: (_) => const <String>[],
    );
    final remoteNames = await cloudBackupTarget.listBackups().then(
      (items) => items.map((e) => e.fileName),
      onError: (_) => const <String>[],
    );
    return <String>{...activeLocalNames, ...sandboxNames, ...remoteNames};
  }

  Future<bool> _doesActiveLocalBackupExist(String fileName) async {
    final resolved = await _resolveActiveLocalTarget();
    if (resolved.externalBinding != null) {
      try {
        final entries = await _fileAccess.listExternalDirectoryFiles(
          resolved.externalBinding!,
        );
        return entries.any((e) => e.fileName == fileName);
      } catch (_) {
        await _setExternalBackupNeedsRebindIfChanged(true);
      }
    }
    return LocalDirectoryBackupTarget._runRootIo(() async {
      final localDir = await _localBackupsDirProvider();
      return File(p.join(localDir.path, fileName)).exists();
    });
  }

  Future<String> _archiveOrphanRemoteSnapshotIfNeeded({
    required Uint8List orphanBytes,
    required BackupTarget cloudBackupTarget,
  }) async {
    final orphanSha = sha256Hex(orphanBytes);
    if (_lastArchivedOrphanRemoteSha256 == orphanSha &&
        _lastArchivedOrphanRemoteFileName != null) {
      if (await _doesActiveLocalBackupExist(
        _lastArchivedOrphanRemoteFileName!,
      )) {
        return _lastArchivedOrphanRemoteFileName!;
      }
    }

    final now = _nowMs();
    final existingNames = await _collectExistingConflictAndBackupFileNames(
      cloudBackupTarget,
    );
    final orphanConflictName = formatConflictBackupFileName(
      deviceId: 'remote${orphanSha.substring(0, 4)}',
      when: DateTime.fromMillisecondsSinceEpoch(now),
      existingFileNames: existingNames,
    );
    await _writeBytesToLocalWithFallback(
      packedBytes: orphanBytes,
      createdAtMs: now,
      customFileName: orphanConflictName,
    );
    await cloudBackupTarget.writeBackup(orphanConflictName, orphanBytes);
    _lastArchivedOrphanRemoteSha256 = orphanSha;
    _lastArchivedOrphanRemoteFileName = orphanConflictName;
    return orphanConflictName;
  }

  Future<CloudSyncOutcome> _executeOrphanRemotePull({
    required CloudSyncSettings settings,
    required CloudSyncObjectStore store,
    required Uint8List orphanDbBytes,
    required int healedRevision,
    required Map<String, String> localAttChecksums,
  }) async {
    final verifiedDb = await _unpackAndVerifyArchiveOffloaded(orphanDbBytes);
    final parsedRows = _parseAndValidateAll22Tables(
      verifiedDb.tables,
      verifiedDb.manifest,
    );

    final referencedBasenames = collectReferencedAttachmentNames(<String?>[
      for (final r in parsedRows.records) r.images,
      for (final r in parsedRows.recordPeriods) r.images,
      for (final r in parsedRows.installments) r.images,
    ]);
    final sanitizedToOriginal = <String, String>{
      for (final name in referencedBasenames)
        sanitizeAttachmentBasename(name): name,
    };
    final reusableLocalPathBySha = <String, String>{
      for (final entry in localAttChecksums.entries)
        entry.value.toLowerCase(): entry.key,
    };

    final downloadedByPath = <String, Uint8List>{};
    final downloadedBySha = <String, Uint8List>{};
    final pulledAttChecksums = <String, String>{};
    final objectNames = <String>[];
    var downloadedCount = 0;

    if (sanitizedToOriginal.isNotEmpty) {
      final remoteObjects = (await store.listRelativeFileNames(
        cloudSyncAttachmentsDir,
      )).toList()..sort();
      for (final objName in remoteObjects) {
        final ({String sha256, String basename}) parsed;
        try {
          parsed = parseAttachmentObjectName(objName);
        } on Failure {
          continue;
        }
        final matchedRelName = sanitizedToOriginal[parsed.basename];
        if (matchedRelName == null) continue;
        final archivePath = normalizeAttachmentArchivePath(matchedRelName);
        if (pulledAttChecksums.containsKey(archivePath)) continue;

        if (!reusableLocalPathBySha.containsKey(parsed.sha256)) {
          var bytes = downloadedBySha[parsed.sha256];
          if (bytes == null) {
            bytes = await store.getObject('$cloudSyncAttachmentsDir/$objName');
            final actualSha = sha256Hex(bytes);
            if (actualSha != parsed.sha256) {
              throw Failure(
                FailureCode.corruptData,
                '远端同步附件哈希校验失败（$objName），已拒绝拉取覆盖',
              );
            }
            downloadedBySha[parsed.sha256] = bytes;
            downloadedCount++;
          }
          downloadedByPath[archivePath] = bytes;
        }
        pulledAttChecksums[archivePath] = parsed.sha256;
        objectNames.add(
          buildAttachmentObjectName(
            sha256: parsed.sha256,
            archivePath: archivePath,
          ),
        );
      }
    }
    objectNames.sort();

    final needAttSwap =
        beforeAttachmentSwapFinalizeForTest != null ||
        !_sameChecksumsMap(localAttChecksums, pulledAttChecksums);
    final dirs = needAttSwap
        ? await _prepareSiblingAttachmentStagingDir()
        : null;
    try {
      final incPlan = dirs != null
          ? await _stageIncrementalAttachmentsOnSameFs(
              targetDir: dirs.targetDir,
              stagingDir: dirs.stagingDir,
              attachments: downloadedByPath,
              localAttChecksums: localAttChecksums,
              expectedChecksums: pulledAttChecksums,
              reusableLocalPathBySha: reusableLocalPathBySha,
            )
          : null;

      final now = _nowMs();
      final effectiveRev = healedRevision < 1 ? 1 : healedRevision;
      final healedDataSha = await _computeDigestOffloaded(
        tables: verifiedDb.tables,
        attachmentChecksums: pulledAttChecksums,
      );
      final healedRevisionPath = buildCloudSyncRevisionPath(
        revision: effectiveRev,
        dataSha256: healedDataSha,
      );
      final healedLightweightDb = await _packArchiveOffloaded(
        tables: verifiedDb.tables,
        attachments: const <String, Uint8List>{},
        createdAtMs: now,
        includeAttachments: false,
      );
      final healedHead = CloudSyncHead(
        format: currentCloudSyncHeadFormat,
        revision: effectiveRev,
        dataSha256: healedDataSha,
        databasePath: healedRevisionPath,
        updatedAtMs: now,
        deviceId: settings.deviceId,
        deviceName: settings.deviceName,
        recordCount: parsedRows.records.length,
        attachmentFiles: objectNames,
        attachmentManifest: pulledAttChecksums,
        recentRevisions: <SyncRevisionHistoryEntry>[
          SyncRevisionHistoryEntry(
            revision: effectiveRev,
            dataSha256: healedDataSha,
            deviceId: settings.deviceId,
          ),
        ],
      );

      _internalRestoreDepth++;
      try {
        await guardDatabase(
          () => db.transaction(() async {
            await _clearAll22TablesInTransaction();
            await db.delete(db.writeCommands).go();
            await (db.delete(
              db.preferences,
            )..where((t) => t.key.equals('periodic_last_check_ms'))).go();
            await _insertAll22TablesInTransaction(parsedRows);
            await _sanitizeDiyDefaultAccountInTransaction(parsedRows.assets);
            await _alignOnlineRateCooldownInTransaction(parsedRows.currencies);

            final activeBookId = resolveRestoredActiveBookId(
              parsedRows.accountBooks.map((b) => (id: b.id, sort: b.sort)),
            );
            await db
                .into(db.preferences)
                .insertOnConflictUpdate(
                  PreferencesCompanion.insert(
                    key: prefKeyCurrentBookId,
                    value: '$activeBookId',
                  ),
                );
          }),
        );

        if (dirs != null && incPlan != null) {
          await _applyIncrementalAttachmentsAtomically(
            targetDir: dirs.targetDir,
            stagingDir: dirs.stagingDir,
            backupDir: dirs.backupDir,
            plan: incPlan,
          );
        }

        await store.putObject(healedRevisionPath, healedLightweightDb.bytes);
        final headBytes = Uint8List.fromList(
          utf8.encode(
            const JsonEncoder.withIndent('  ').convert(healedHead.toJson()),
          ),
        );
        final headEtag = await store.putObjectReturningEtag(
          cloudSyncHeadPath,
          headBytes,
          contentType: 'application/json; charset=utf-8',
        );

        _invalidateLocalTableDigestCache();
        await _writeSyncBaseSnapshot(
          targetFingerprint: store.targetFingerprint,
          revision: effectiveRev,
          dataSha256: healedDataSha,
          lightweightDbBytes: healedLightweightDb.bytes,
          attachmentChecksums: pulledAttChecksums,
        );

        final newCursor = LocalSyncCursor(
          lastSyncedRevision: effectiveRev,
          lastSyncedDataSha256: healedDataSha,
          lastSyncedAtMs: now,
          targetFingerprint: store.targetFingerprint,
          localFullReplaceSinceLastSync: false,
          lastRemoteHeadEtag: headEtag,
        );
        await _saveSyncCursor(newCursor, ensureSettings: settings);
        await reminderService.resyncAll();
      } finally {
        await Future<void>.microtask(() {});
        await Future<void>.microtask(() {});
        _internalRestoreDepth--;
      }

      return CloudSyncOutcome(
        status: CloudSyncStatus.pulled,
        revision: effectiveRev,
        localDataSha256: healedDataSha,
        remoteHead: healedHead,
        downloadedAttachments: downloadedCount,
      );
    } finally {
      if (dirs != null) {
        try {
          if (await dirs.stagingDir.exists()) {
            await dirs.stagingDir.delete(recursive: true);
          }
        } catch (_) {}
      }
    }
  }

  Future<CloudSyncOutcome> _preserveConflictAndReport({
    required CloudSyncSettings settings,
    required CloudSyncObjectStore store,
    required BackupTarget cloudBackupTarget,
    required LocalSyncCursor cursor,
    required CloudSyncHead? remoteHead,
    int? fallbackRemoteRevision,
    Uint8List? orphanRemoteLatestDbBytes,
    bool isLocalFreshEmpty = false,
    required Map<String, List<Map<String, Object?>>> localTables,
    required Map<String, String> localAttChecksums,
    required String localDataSha256,
    Map<String, List<Map<String, Object?>>>? preloadedRemoteTables,
  }) async {
    String? orphanConflictFileName;
    if (orphanRemoteLatestDbBytes != null) {
      orphanConflictFileName = await _archiveOrphanRemoteSnapshotIfNeeded(
        orphanBytes: orphanRemoteLatestDbBytes,
        cloudBackupTarget: cloudBackupTarget,
      );
    }

    String? conflictFileName;
    if (orphanConflictFileName != null && isLocalFreshEmpty) {
      conflictFileName = orphanConflictFileName;
    } else if (cursor.lastConflictSha256 == localDataSha256 &&
        cursor.lastConflictFileName != null &&
        cursor.lastConflictFileName!.isNotEmpty) {
      if (await _doesActiveLocalBackupExist(cursor.lastConflictFileName!)) {
        conflictFileName = cursor.lastConflictFileName;
      }
    }

    if (conflictFileName == null) {
      final now = _nowMs();
      final existingNames = await _collectExistingConflictAndBackupFileNames(
        cloudBackupTarget,
      );
      conflictFileName = formatConflictBackupFileName(
        deviceId: settings.deviceId,
        when: DateTime.fromMillisecondsSinceEpoch(now),
        existingFileNames: existingNames,
      );

      final totalAttBytes = await _computeTotalLocalAttachmentsBytes();
      final PackedTallyBackup conflictPack;
      if (totalAttBytes > maxInlineConflictAttachmentBytes &&
          localAttChecksums.isNotEmpty) {
        // Oversize conflict fallback: stream-upload local-only attachments to
        // `sync/attachments/`, register a GC-protected `ConflictAttachmentRefLock`
        // under `sync/conflict_refs/<conflictFileName>.json`, and pack a
        // lightweight DB-only `conflict_*.tally` to avoid OOM!
        final knownRemote = remoteHead?.attachmentFiles.toSet() ?? <String>{};
        final allObjNames = <String>[];
        final sortedPaths = localAttChecksums.keys.toList()..sort();
        for (final archivePath in sortedPaths) {
          final sha = localAttChecksums[archivePath]!;
          final objName = buildAttachmentObjectName(
            sha256: sha,
            archivePath: archivePath,
          );
          allObjNames.add(objName);
          if (!knownRemote.contains(objName)) {
            final bytes = await _readSingleLocalAttachmentBytes(archivePath);
            await store.putObject('$cloudSyncAttachmentsDir/$objName', bytes);
            knownRemote.add(objName);
          }
        }
        final refLock = ConflictAttachmentRefLock(
          conflictFileName: conflictFileName,
          createdAtMs: now,
          attachmentFiles: allObjNames,
          attachmentManifest: localAttChecksums,
        );
        await store.putObject(
          '$cloudSyncConflictRefsDir/$conflictFileName.json',
          Uint8List.fromList(utf8.encode(jsonEncode(refLock.toJson()))),
          contentType: 'application/json; charset=utf-8',
        );
        conflictPack = await _packArchiveOffloaded(
          tables: localTables,
          attachments: const <String, Uint8List>{},
          createdAtMs: now,
          includeAttachments: false,
        );
      } else {
        final localAttachments = localAttChecksums.isEmpty
            ? const <String, Uint8List>{}
            : await _collectLocalAttachments();
        conflictPack = await _packArchiveOffloaded(
          tables: localTables,
          attachments: localAttachments,
          createdAtMs: now,
          includeAttachments: true,
        );
      }

      await _writeBytesToLocalWithFallback(
        packedBytes: conflictPack.bytes,
        createdAtMs: now,
        customFileName: conflictFileName,
      );
      await cloudBackupTarget.writeBackup(conflictFileName, conflictPack.bytes);
    }

    Map<String, List<Map<String, Object?>>>? remoteTablesForSummary =
        preloadedRemoteTables;
    if (remoteTablesForSummary == null && remoteHead != null) {
      try {
        final rBytes = await store.getObjectOrNull(remoteHead.databasePath);
        if (rBytes != null) {
          final verified = await _unpackAndVerifyArchiveOffloaded(
            rBytes,
            expectedRowCountHint: remoteHead.recordCount,
          );
          remoteTablesForSummary = verified.tables;
        }
      } catch (_) {}
    }
    final summary = computeSyncConflictComparison(
      localDeviceName: settings.deviceName,
      localTables: localTables,
      remoteTables: remoteTablesForSummary,
      remoteHead: remoteHead,
    );
    final summaryJson = jsonEncode(summary.toJson());

    if (cursor.lastConflictFileName != conflictFileName ||
        cursor.lastConflictSha256 != localDataSha256 ||
        cursor.lastConflictSummaryJson != summaryJson ||
        cursor.targetFingerprint != store.targetFingerprint) {
      await _saveSyncCursor(
        cursor.copyWith(
          targetFingerprint: store.targetFingerprint,
          lastConflictSha256: localDataSha256,
          lastConflictFileName: conflictFileName,
          lastConflictSummaryJson: summaryJson,
        ),
        ensureSettings: settings,
      );
    }

    return CloudSyncOutcome.conflict(
      revision: remoteHead?.revision ?? fallbackRemoteRevision ?? 0,
      localDataSha256: localDataSha256,
      remoteHead: remoteHead,
      conflictBackupFileName: conflictFileName,
    );
  }

  /// Loads or computes a structured [SyncConflictComparison] for the conflict
  /// resolution dialog, gracefully falling back to the cached summary in
  /// `cloud_sync_cursor` when offline.
  Future<SyncConflictComparison> inspectCurrentConflictComparison({
    CloudSyncOutcome? conflictOutcome,
  }) async {
    final settings = await getCloudSyncSettings();
    final cursor = await getSyncCursor();
    final localTables = await guardDatabase(
      () => db.transaction(_exportAll22Tables),
    );

    CloudSyncHead? remoteHead = conflictOutcome?.remoteHead;
    Map<String, List<Map<String, Object?>>>? remoteTables;

    final store = await _getActiveObjectStoreOrNull();
    if (store != null) {
      try {
        await store.runSession(() async {
          remoteHead ??= (await _readRemoteSyncHead(store)).head;
          if (remoteHead != null) {
            final bytes = await store.getObjectOrNull(remoteHead!.databasePath);
            if (bytes != null) {
              final verified = await _unpackAndVerifyArchiveOffloaded(
                bytes,
                expectedRowCountHint: remoteHead!.recordCount,
              );
              remoteTables = verified.tables;
            }
          }
        });
      } catch (_) {}
    }

    if (remoteTables != null) {
      return computeSyncConflictComparison(
        localDeviceName: settings.deviceName,
        localTables: localTables,
        remoteTables: remoteTables,
        remoteHead: remoteHead,
      );
    }

    final cachedRaw = cursor.lastConflictSummaryJson;
    if (cachedRaw != null && cachedRaw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(cachedRaw);
        if (decoded is Map<String, Object?>) {
          final cached = SyncConflictComparison.fromJson(decoded);
          if (remoteHead == null ||
              cached.remoteRevision == remoteHead!.revision) {
            return cached;
          }
        }
      } catch (_) {}
    }

    return computeSyncConflictComparison(
      localDeviceName: settings.deviceName,
      localTables: localTables,
      remoteTables: null,
      remoteHead: remoteHead,
    );
  }

  Future<CloudSyncObjectStore?> _getActiveObjectStoreOrNull() async {
    final settings = await getCloudSyncSettings();
    switch (settings.backend) {
      case CloudBackendType.webdav:
        final dav = await getWebDavConfig();
        return dav.isConfigured ? await getWebDavTarget() : null;
      case CloudBackendType.s3:
        final s3 = await getS3Config();
        return s3.isConfigured ? await getS3Target() : null;
      case CloudBackendType.none:
        return null;
    }
  }

  Future<void> _hydrateLightweightConflictAttachmentsBestEffort(
    String conflictFileName, {
    CloudSyncObjectStore? explicitStore,
  }) => _runExclusive(() async {
    try {
      final store = explicitStore ?? await _getActiveObjectStoreOrNull();
      if (store == null) return;
      await store.runSession(() async {
        final rawLock = await store.getObjectOrNull(
          '$cloudSyncConflictRefsDir/$conflictFileName.json',
        );
        if (rawLock == null) return;
        final decoded = jsonDecode(utf8.decode(rawLock));
        if (decoded is! Map<String, Object?>) return;
        final lock = ConflictAttachmentRefLock.fromJson(decoded);
        if (lock.attachmentManifest.isEmpty) return;

        final localAttChecksums = await _collectLocalAttachmentChecksums();
        final reusableLocalPathBySha = <String, String>{
          for (final e in localAttChecksums.entries)
            e.value.toLowerCase(): e.key,
        };
        final objBySha = <String, String>{};
        for (final objName in lock.attachmentFiles) {
          try {
            final parsed = parseAttachmentObjectName(objName);
            objBySha.putIfAbsent(parsed.sha256, () => objName);
          } catch (_) {}
        }

        final downloadedByPath = <String, Uint8List>{};
        final downloadedBySha = <String, Uint8List>{};
        for (final entry in lock.attachmentManifest.entries) {
          final archivePath = entry.key;
          final sha = entry.value.toLowerCase();
          if (reusableLocalPathBySha.containsKey(sha)) continue;
          var bytes = downloadedBySha[sha];
          if (bytes == null) {
            final objName =
                objBySha[sha] ??
                buildAttachmentObjectName(
                  sha256: sha,
                  archivePath: archivePath,
                );
            final fetched = await store.getObjectOrNull(
              '$cloudSyncAttachmentsDir/$objName',
            );
            if (fetched == null || sha256Hex(fetched) != sha) {
              return;
            }
            bytes = fetched;
            downloadedBySha[sha] = bytes;
          }
          downloadedByPath[archivePath] = bytes;
        }

        final dirs = await _prepareSiblingAttachmentStagingDir();
        try {
          final incPlan = await _stageIncrementalAttachmentsOnSameFs(
            targetDir: dirs.targetDir,
            stagingDir: dirs.stagingDir,
            attachments: downloadedByPath,
            localAttChecksums: localAttChecksums,
            expectedChecksums: lock.attachmentManifest,
            reusableLocalPathBySha: reusableLocalPathBySha,
          );
          await _applyIncrementalAttachmentsAtomically(
            targetDir: dirs.targetDir,
            stagingDir: dirs.stagingDir,
            backupDir: dirs.backupDir,
            plan: incPlan,
          );
          _invalidateLocalTableDigestCache();
        } finally {
          try {
            if (await dirs.stagingDir.exists()) {
              await dirs.stagingDir.delete(recursive: true);
            }
          } catch (_) {}
        }
      });
    } catch (_) {}
  });

  /// Executes the 3-stage safe restore workflow (`R5`, `S-02`, `S-05`, `S-07`, `S-09`).
  Future<TallyManifest> restoreFromBytes(
    Uint8List archiveBytes, {
    void Function()? beforeTransactionCommitForTest,
  }) => _runExclusive(
    () => _restoreFromBytesUnlocked(
      archiveBytes,
      beforeTransactionCommitForTest: beforeTransactionCommitForTest,
    ),
  );

  Future<TallyManifest> _restoreFromBytesUnlocked(
    Uint8List archiveBytes, {
    void Function()? beforeTransactionCommitForTest,
  }) async {
    final stagingDir = await LocalDirectoryBackupTarget._runRootIo(
      () => Directory.systemTemp.createTemp('tally_restore_staging_'),
    );
    ({Directory targetDir, Directory stagingDir, Directory backupDir})?
    attSwapDirs;
    try {
      final stagedStage1 = await LocalDirectoryBackupTarget._runRootIo(
        () async {
          final zip = ZipArchive.decode(archiveBytes);
          final canonicalStagingRoot = await stagingDir.resolveSymbolicLinks();
          final rawAttEntries = <String, Uint8List>{};
          for (final entry in zip.entries) {
            final safeRel = validateZipEntryPath(entry.name);
            if (safeRel.startsWith(tallyAttachmentsPrefix)) {
              rawAttEntries[safeRel] = entry.bytes;
              continue;
            }
            final outPath = p.normalize(
              p.joinAll(<String>[canonicalStagingRoot, ...safeRel.split('/')]),
            );
            if (!p.isWithin(canonicalStagingRoot, outPath)) {
              throw Failure(FailureCode.corruptData, '拒绝越界的暂存路径：$safeRel');
            }
            final outFile = File(outPath);
            await outFile.parent.create(recursive: true);
            await outFile.writeAsBytes(entry.bytes);
          }

          final stagedManifestFile = File(
            p.join(canonicalStagingRoot, tallyManifestFileName),
          );
          if (!await stagedManifestFile.exists()) {
            throw const Failure(FailureCode.corruptData, '备份包缺少 manifest.json');
          }
          final Object? rawManifest;
          try {
            rawManifest = jsonDecode(await stagedManifestFile.readAsString());
          } catch (_) {
            throw const Failure(
              FailureCode.corruptData,
              '备份包 manifest.json 解析失败',
            );
          }
          if (rawManifest is! Map<String, Object?>) {
            throw const Failure(
              FailureCode.corruptData,
              '备份包 manifest.json 结构损坏',
            );
          }
          final manifest = TallyManifest.fromJson(rawManifest);

          final stagedDbFile = File(
            p.join(canonicalStagingRoot, manifest.databaseFile),
          );
          if (!await stagedDbFile.exists()) {
            throw Failure(
              FailureCode.corruptData,
              '备份包缺少数据库文件 ${manifest.databaseFile}',
            );
          }
          final stagedDbBytes = await stagedDbFile.readAsBytes();
          return (
            manifest: manifest,
            stagedDbBytes: stagedDbBytes,
            rawAttEntries: rawAttEntries,
          );
        },
      );
      final manifest = stagedStage1.manifest;
      final stagedDbBytes = stagedStage1.stagedDbBytes;
      final rawAttEntries = stagedStage1.rawAttEntries;
      if (sha256Hex(stagedDbBytes) != manifest.databaseSha256) {
        throw const Failure(
          FailureCode.corruptData,
          '备份数据文件哈希校验失败（文件已被篡改或损坏），已拒绝恢复',
        );
      }

      for (final attName in rawAttEntries.keys) {
        if (!manifest.filesChecksum.containsKey(attName)) {
          throw Failure(
            FailureCode.corruptData,
            '备份包存在未在清单登记的额外附件（$attName），已拒绝恢复',
          );
        }
      }
      for (final expected in manifest.filesChecksum.entries) {
        final attBytes = rawAttEntries[expected.key];
        if (attBytes == null) {
          throw Failure(
            FailureCode.corruptData,
            '备份包缺少清单登记的附件文件：${expected.key}',
          );
        }
        if (sha256Hex(attBytes) != expected.value) {
          throw Failure(
            FailureCode.corruptData,
            '备份附件哈希校验失败（${expected.key}），已拒绝恢复',
          );
        }
      }

      final Object? rawDbJson;
      try {
        rawDbJson = jsonDecode(utf8.decode(stagedDbBytes));
      } catch (_) {
        throw const Failure(FailureCode.corruptData, '备份数据库 JSON 解析失败');
      }
      if (rawDbJson is! Map<String, Object?>) {
        throw const Failure(FailureCode.corruptData, '备份数据库 JSON 顶层结构损坏');
      }

      final parsedRows = _parseAndValidateAll22Tables(rawDbJson, manifest);

      if (manifest.includeAttachments) {
        attSwapDirs = await _prepareSiblingAttachmentStagingDir();
        await _stageAndVerifyAttachmentsOnSameFs(
          stagingDir: attSwapDirs.stagingDir,
          attachments: rawAttEntries,
          expectedChecksums: manifest.filesChecksum,
        );
      }

      // Stage 3: Single atomic SQLite transaction replacing all 22 tables.
      _internalRestoreDepth++;
      try {
        await guardDatabase(
          () => db.transaction(() async {
            await _clearAll22TablesInTransaction();
            await db.delete(db.writeCommands).go();
            await (db.delete(
              db.preferences,
            )..where((t) => t.key.equals('periodic_last_check_ms'))).go();
            await _insertAll22TablesInTransaction(parsedRows);
            await _sanitizeDiyDefaultAccountInTransaction(parsedRows.assets);
            await _alignOnlineRateCooldownInTransaction(parsedRows.currencies);

            final activeBookId = resolveRestoredActiveBookId(
              parsedRows.accountBooks.map((b) => (id: b.id, sort: b.sort)),
            );
            await db
                .into(db.preferences)
                .insertOnConflictUpdate(
                  PreferencesCompanion.insert(
                    key: prefKeyCurrentBookId,
                    value: '$activeBookId',
                  ),
                );

            beforeTransactionCommitForTest?.call();
          }),
        );

        // Same-filesystem atomic swap of verified attachments (`S-02`).
        if (attSwapDirs != null) {
          await _swapStagedAttachmentsAtomically(
            targetDir: attSwapDirs.targetDir,
            stagingDir: attSwapDirs.stagingDir,
            backupDir: attSwapDirs.backupDir,
          );
        }

        _invalidateLocalTableDigestCache();

        // Mark `localFullReplaceSinceLastSync` so subsequent sync never
        // misinterprets restored-away rows as incremental deletions (`S-05`).
        final existingCursor = await getSyncCursor();
        if (!existingCursor.isNeverSynced ||
            existingCursor.lastConflictFileName != null ||
            existingCursor.lastConflictSha256 != null ||
            existingCursor.lastConflictSummaryJson != null) {
          await _saveSyncCursor(
            existingCursor.copyWith(
              localFullReplaceSinceLastSync: !existingCursor.isNeverSynced,
              clearConflictRecord: true,
            ),
          );
        }

        final restoredAt = _nowMs();
        await _recordCompletedBackupState(restoredAt);
        await _recordCompletedLocalBackupState(restoredAt);
        await reminderService.resyncAll();
      } finally {
        await Future<void>.microtask(() {});
        await Future<void>.microtask(() {});
        _internalRestoreDepth--;
      }

      return manifest;
    } finally {
      final attSwap = attSwapDirs;
      await LocalDirectoryBackupTarget._runRootIo(() async {
        try {
          if (await stagingDir.exists()) {
            await stagingDir.delete(recursive: true);
          }
        } catch (_) {}
        if (attSwap != null) {
          try {
            if (await attSwap.stagingDir.exists()) {
              await attSwap.stagingDir.delete(recursive: true);
            }
          } catch (_) {}
        }
      });
    }
  }

  Future<void> _recordCompletedBackupState(int timestampMs) async {
    final digest = await _computeCanonicalStateDigest();
    await guardDatabase(
      () => db.transaction(() async {
        await db
            .into(db.preferences)
            .insertOnConflictUpdate(
              PreferencesCompanion.insert(
                key: prefKeyLastBackupAtMs,
                value: '$timestampMs',
              ),
            );
        await db
            .into(db.preferences)
            .insertOnConflictUpdate(
              PreferencesCompanion.insert(
                key: prefKeyLastBackupDataSha256,
                value: digest,
              ),
            );
      }),
    );
  }

  Future<void> _recordCompletedLocalBackupState(int timestampMs) async {
    final digest = await _computeCanonicalStateDigest();
    await guardDatabase(
      () => db.transaction(() async {
        await db
            .into(db.preferences)
            .insertOnConflictUpdate(
              PreferencesCompanion.insert(
                key: prefKeyLocalAutoBackupLastAtMs,
                value: '$timestampMs',
              ),
            );
        await db
            .into(db.preferences)
            .insertOnConflictUpdate(
              PreferencesCompanion.insert(
                key: prefKeyLocalAutoBackupLastSha256,
                value: digest,
              ),
            );
      }),
    );
  }

  Future<
    ({
      String dataSha256,
      bool isFreshSeed,
      Map<String, String> attChecksums,
      Map<String, List<Map<String, Object?>>>? tables,
    })
  >
  _computeLocalSyncSnapshotSummary() async {
    _ensureDirtyTrackingSubscription();
    await Future<void>.microtask(() {});
    await Future<void>.microtask(() {});

    final attChecksums = await _collectLocalAttachmentChecksums();
    final sortedKeys = attChecksums.keys.toList()..sort();
    final attSig = jsonEncode(<String, String>{
      for (final k in sortedKeys) k: attChecksums[k]!,
    });

    if (!_tablesPossiblyDirty &&
        _cachedCanonicalStateSha256 != null &&
        _cachedIsLocalTablesFreshSeed != null &&
        _cachedLastAttachmentsSig == attSig) {
      return (
        dataSha256: _cachedCanonicalStateSha256!,
        isFreshSeed: _cachedIsLocalTablesFreshSeed!,
        attChecksums: attChecksums,
        tables: null,
      );
    }

    _tablesPossiblyDirty = false;
    final tables = await guardDatabase(
      () => db.transaction(_exportAll22Tables),
    );
    final sha = await _computeDigestOffloaded(
      tables: tables,
      attachmentChecksums: attChecksums,
    );
    final freshSeed = isFreshSeedSnapshot(
      tables,
      attachmentCount: attChecksums.length,
    );
    await Future<void>.microtask(() {});
    if (!_tablesPossiblyDirty) {
      _cachedCanonicalStateSha256 = sha;
      _cachedLastAttachmentsSig = attSig;
      _cachedIsLocalTablesFreshSeed = freshSeed;
    }
    return (
      dataSha256: sha,
      isFreshSeed: freshSeed,
      attChecksums: attChecksums,
      tables: tables,
    );
  }

  Future<String> _computeCanonicalStateDigest() async {
    final summary = await _computeLocalSyncSnapshotSummary();
    return summary.dataSha256;
  }

  Future<Map<String, String>>
  _collectLocalAttachmentChecksums() => LocalDirectoryBackupTarget._runRootIo(
    () async {
      final rawDir = await _attachmentsDirProvider();
      final dir = Directory(p.normalize(rawDir.path));
      if (!await dir.exists()) {
        _attHashCache = <String, ({int size, int modifiedMs, String sha256})>{};
        return const <String, String>{};
      }

      final cacheFile = File('${dir.path}.hash_cache.json');
      if (_attHashCache == null) {
        final loaded = <String, ({int size, int modifiedMs, String sha256})>{};
        try {
          if (await cacheFile.exists()) {
            final decoded = jsonDecode(await cacheFile.readAsString());
            if (decoded is Map<String, Object?>) {
              for (final e in decoded.entries) {
                final v = e.value;
                if (v is Map<String, Object?>) {
                  final sz = v['s'];
                  final m = v['m'];
                  final h = v['h'];
                  if (sz is int && m is int && h is String && h.length == 64) {
                    loaded[e.key] = (
                      size: sz,
                      modifiedMs: m,
                      sha256: h.toLowerCase(),
                    );
                  }
                }
              }
            }
          }
        } catch (_) {}
        _attHashCache = loaded;
      }

      final cache = _attHashCache!;
      final nextCache = <String, ({int size, int modifiedMs, String sha256})>{};
      final result = <String, String>{};
      var cacheDirty = false;

      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final relSegments = p.split(p.relative(entity.path, from: dir.path));
        if (relSegments.isEmpty) continue;
        if (relSegments.last.toLowerCase().endsWith('.tmp')) continue;
        final archivePath = normalizeAttachmentArchivePath(
          relSegments.join('/'),
        );
        final stat = await entity.stat();
        final size = stat.size;
        final modMs = stat.modified.millisecondsSinceEpoch;
        final hit = cache[archivePath];
        String sha;
        if (hit != null && hit.size == size && hit.modifiedMs == modMs) {
          sha = hit.sha256;
        } else {
          sha = (await crypto.sha256.bind(entity.openRead()).first).toString();
          cacheDirty = true;
        }
        nextCache[archivePath] = (size: size, modifiedMs: modMs, sha256: sha);
        result[archivePath] = sha;
      }

      if (nextCache.length != cache.length) {
        cacheDirty = true;
      }
      _attHashCache = nextCache;

      if (cacheDirty) {
        try {
          final encoded = jsonEncode(<String, Object>{
            for (final e in nextCache.entries)
              e.key: <String, Object>{
                's': e.value.size,
                'm': e.value.modifiedMs,
                'h': e.value.sha256,
              },
          });
          await cacheFile.writeAsString(encoded, flush: true);
        } catch (_) {}
      }
      return result;
    },
  );

  Future<int> _computeTotalLocalAttachmentsBytes() =>
      LocalDirectoryBackupTarget._runRootIo(() async {
        final dir = await _attachmentsDirProvider();
        if (!await dir.exists()) return 0;
        var total = 0;
        await for (final entity in dir.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is! File) continue;
          if (entity.path.toLowerCase().endsWith('.tmp')) continue;
          total += (await entity.stat()).size;
        }
        return total;
      });

  Future<Uint8List> _readSingleLocalAttachmentBytes(String archivePath) =>
      LocalDirectoryBackupTarget._runRootIo(() async {
        final dir = await _attachmentsDirProvider();
        final clean = normalizeAttachmentArchivePath(archivePath);
        final rel = clean.substring(tallyAttachmentsPrefix.length);
        final f = File(p.joinAll(<String>[dir.path, ...rel.split('/')]));
        return f.readAsBytes();
      });

  Future<Map<String, Uint8List>> _collectLocalAttachments() =>
      LocalDirectoryBackupTarget._runRootIo(() async {
        final dir = await _attachmentsDirProvider();
        if (!await dir.exists()) return const <String, Uint8List>{};
        final result = <String, Uint8List>{};
        await for (final entity in dir.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is! File) continue;
          final relSegments = p.split(p.relative(entity.path, from: dir.path));
          if (relSegments.isEmpty) continue;
          if (relSegments.last.toLowerCase().endsWith('.tmp')) continue;
          final archivePath = normalizeAttachmentArchivePath(
            relSegments.join('/'),
          );
          result[archivePath] = await entity.readAsBytes();
        }
        return result;
      });

  static int _countTotalTableRows(
    Map<String, List<Map<String, Object?>>> tables,
  ) {
    var total = 0;
    for (final list in tables.values) {
      total += list.length;
    }
    return total;
  }

  static String _computeDigestStatic(
    Map<String, List<Map<String, Object?>>> tables,
    Map<String, String> attachmentChecksums,
  ) => computeCanonicalSyncDataSha256(
    tables: tables,
    attachmentChecksums: attachmentChecksums,
  );

  Future<String> _computeDigestOffloaded({
    required Map<String, List<Map<String, Object?>>> tables,
    required Map<String, String> attachmentChecksums,
  }) async {
    if (_countTotalTableRows(tables) < isolateOffloadRowThreshold) {
      return _computeDigestStatic(tables, attachmentChecksums);
    }
    return Isolate.run(() => _computeDigestStatic(tables, attachmentChecksums));
  }

  static ({TallyManifest manifest, TransferableTypedData transferableBytes})
  _packArchiveStatic(
    Map<String, List<Map<String, Object?>>> tables,
    Map<String, TransferableTypedData> attTransfer,
    int createdAtMs,
    String appVersion,
    bool includeAttachments,
  ) {
    final unpackedAtts = <String, Uint8List>{
      for (final e in attTransfer.entries)
        e.key: e.value.materialize().asUint8List(),
    };
    final packed = packTallyArchive(
      tables: tables,
      attachments: unpackedAtts,
      createdAtMs: createdAtMs,
      appVersion: appVersion,
      includeAttachments: includeAttachments,
    );
    return (
      manifest: packed.manifest,
      transferableBytes: TransferableTypedData.fromList(<Uint8List>[
        packed.bytes,
      ]),
    );
  }

  Future<PackedTallyBackup> _packArchiveOffloaded({
    required Map<String, List<Map<String, Object?>>> tables,
    required Map<String, Uint8List> attachments,
    required int createdAtMs,
    required bool includeAttachments,
  }) async {
    if (_countTotalTableRows(tables) < isolateOffloadRowThreshold) {
      return packTallyArchive(
        tables: tables,
        attachments: attachments,
        createdAtMs: createdAtMs,
        appVersion: appVersion,
        includeAttachments: includeAttachments,
      );
    }
    final ver = appVersion;
    final attTransfer = <String, TransferableTypedData>{
      for (final e in attachments.entries)
        e.key: TransferableTypedData.fromList(<Uint8List>[e.value]),
    };
    final res = await Isolate.run(
      () => _packArchiveStatic(
        tables,
        attTransfer,
        createdAtMs,
        ver,
        includeAttachments,
      ),
    );
    return PackedTallyBackup(
      bytes: res.transferableBytes.materialize().asUint8List(),
      manifest: res.manifest,
    );
  }

  static VerifiedTallyArchive _unpackArchiveStatic(
    TransferableTypedData transfer,
  ) => unpackAndVerifyTallyArchive(transfer.materialize().asUint8List());

  Future<VerifiedTallyArchive> _unpackAndVerifyArchiveOffloaded(
    Uint8List archiveBytes, {
    int expectedRowCountHint = 0,
  }) async {
    const byteOffloadThreshold = 256 * 1024;
    if (expectedRowCountHint < isolateOffloadRowThreshold &&
        archiveBytes.length < byteOffloadThreshold) {
      return unpackAndVerifyTallyArchive(archiveBytes);
    }
    final transfer = TransferableTypedData.fromList(<Uint8List>[archiveBytes]);
    return Isolate.run(() => _unpackArchiveStatic(transfer));
  }

  static ({
    bool merged,
    Map<String, List<Map<String, Object?>>>? remoteTables,
    Map<String, List<Map<String, Object?>>>? mergedTables,
    Map<String, MergedAttachmentEntry>? mergedAttachments,
    Map<String, SyncTableDelta>? tableDeltas,
    String? mergedDataSha256,
    TransferableTypedData? mergedDbTransfer,
  })
  _executeThreeWayMergeStatic({
    required Uint8List rawBase,
    required Map<String, String> baseAttChecksums,
    required Map<String, List<Map<String, Object?>>> localTables,
    required Map<String, String> localAttChecksums,
    required Uint8List rawRemote,
    required Map<String, String> remoteAttChecksums,
    required String remoteHeadSha,
    required String appVersion,
    required int nowMs,
  }) {
    // Phase 1: Decode Base, build compact `BaseLocalDiffRepresentation`,
    // and release full `baseTables` BEFORE decoding Remote!
    Map<String, List<Map<String, Object?>>>? baseTables =
        unpackAndVerifyTallyArchive(rawBase).tables;
    final baseLocalDiff = buildBaseLocalDiffRepresentation(
      baseTables: baseTables,
      localTables: localTables,
      baseAttachmentChecksums: baseAttChecksums,
      localAttachmentChecksums: localAttChecksums,
    );
    baseTables = null;

    // Phase 2: Decode Remote and execute accounting-conserving 3-way merge.
    final remoteVerified = unpackAndVerifyTallyArchive(rawRemote);
    _parseAndValidateAll22Tables(
      remoteVerified.tables,
      remoteVerified.manifest,
    );

    final res = tryThreeWayMergeSyncSnapshots(
      baseLocalDiff: baseLocalDiff,
      localTables: localTables,
      remoteTables: remoteVerified.tables,
      remoteAttachmentChecksums: remoteAttChecksums,
      nowMs: nowMs,
    );
    if (!res.merged) {
      return (
        merged: false,
        remoteTables: remoteVerified.tables,
        mergedTables: null,
        mergedAttachments: null,
        tableDeltas: null,
        mergedDataSha256: null,
        mergedDbTransfer: null,
      );
    }

    final mergedAttChecksums = <String, String>{
      for (final e in res.mergedAttachments!.entries) e.key: e.value.sha256,
    };
    final mergedSha = computeCanonicalSyncDataSha256(
      tables: res.mergedTables!,
      attachmentChecksums: mergedAttChecksums,
    );
    TransferableTypedData? packedTransfer;
    if (mergedSha != remoteHeadSha) {
      final packed = packTallyArchive(
        tables: res.mergedTables!,
        createdAtMs: nowMs,
        appVersion: appVersion,
        includeAttachments: false,
      );
      packedTransfer = TransferableTypedData.fromList(<Uint8List>[
        packed.bytes,
      ]);
    }
    return (
      merged: true,
      remoteTables: remoteVerified.tables,
      mergedTables: res.mergedTables,
      mergedAttachments: res.mergedAttachments,
      tableDeltas: res.tableDeltas,
      mergedDataSha256: mergedSha,
      mergedDbTransfer: packedTransfer,
    );
  }

  Future<
    ({
      bool merged,
      Map<String, List<Map<String, Object?>>>? remoteTables,
      Map<String, List<Map<String, Object?>>>? mergedTables,
      Map<String, MergedAttachmentEntry>? mergedAttachments,
      Map<String, SyncTableDelta>? tableDeltas,
      String? mergedDataSha256,
      Uint8List? mergedLightweightDbBytes,
    })
  >
  _runTwoPhaseThreeWayMergeOffloaded({
    required Uint8List baseDbBytes,
    required Map<String, String> baseAttChecksums,
    required Map<String, List<Map<String, Object?>>> localTables,
    required Map<String, String> localAttChecksums,
    required Uint8List remoteDbBytes,
    required CloudSyncHead remoteHead,
    required int nowMs,
  }) async {
    final ver = appVersion;
    final remoteAttChecksums = <String, String>{
      for (final d in remoteHead.resolvedAttachments()) d.archivePath: d.sha256,
    };
    final remoteHeadSha = remoteHead.dataSha256;

    final shouldOffload =
        _countTotalTableRows(localTables) >= isolateOffloadRowThreshold ||
        remoteHead.recordCount >= isolateOffloadRowThreshold;
    final ({
      bool merged,
      Map<String, List<Map<String, Object?>>>? remoteTables,
      Map<String, List<Map<String, Object?>>>? mergedTables,
      Map<String, MergedAttachmentEntry>? mergedAttachments,
      Map<String, SyncTableDelta>? tableDeltas,
      String? mergedDataSha256,
      TransferableTypedData? mergedDbTransfer,
    })
    coreRes;
    if (shouldOffload) {
      final bTransfer = TransferableTypedData.fromList(<Uint8List>[
        baseDbBytes,
      ]);
      final rTransfer = TransferableTypedData.fromList(<Uint8List>[
        remoteDbBytes,
      ]);
      coreRes = await Isolate.run(
        () => _executeThreeWayMergeStatic(
          rawBase: bTransfer.materialize().asUint8List(),
          baseAttChecksums: baseAttChecksums,
          localTables: localTables,
          localAttChecksums: localAttChecksums,
          rawRemote: rTransfer.materialize().asUint8List(),
          remoteAttChecksums: remoteAttChecksums,
          remoteHeadSha: remoteHeadSha,
          appVersion: ver,
          nowMs: nowMs,
        ),
      );
    } else {
      coreRes = _executeThreeWayMergeStatic(
        rawBase: baseDbBytes,
        baseAttChecksums: baseAttChecksums,
        localTables: localTables,
        localAttChecksums: localAttChecksums,
        rawRemote: remoteDbBytes,
        remoteAttChecksums: remoteAttChecksums,
        remoteHeadSha: remoteHeadSha,
        appVersion: ver,
        nowMs: nowMs,
      );
    }

    return (
      merged: coreRes.merged,
      remoteTables: coreRes.remoteTables,
      mergedTables: coreRes.mergedTables,
      mergedAttachments: coreRes.mergedAttachments,
      tableDeltas: coreRes.tableDeltas,
      mergedDataSha256: coreRes.mergedDataSha256,
      mergedLightweightDbBytes: coreRes.mergedDbTransfer
          ?.materialize()
          .asUint8List(),
    );
  }

  String _syncBaseKeyForTarget(String targetFingerprint) => sha256Hex(
    Uint8List.fromList(utf8.encode(targetFingerprint)),
  ).substring(0, 16);

  Future<Directory> _syncBaseDirectory() async {
    final rawAtt = await _attachmentsDirProvider();
    return Directory('${p.normalize(rawAtt.path)}.sync_base');
  }

  Future<void> _writeSyncBaseSnapshot({
    required String targetFingerprint,
    required int revision,
    required String dataSha256,
    required Uint8List lightweightDbBytes,
    required Map<String, String> attachmentChecksums,
  }) => LocalDirectoryBackupTarget._runRootIo(() async {
    try {
      final dir = await _syncBaseDirectory();
      await dir.create(recursive: true);
      final key = _syncBaseKeyForTarget(targetFingerprint);
      final dbTmp = File(p.join(dir.path, 'base_$key.tally.tmp'));
      final dbOut = File(p.join(dir.path, 'base_$key.tally'));
      await dbTmp.writeAsBytes(lightweightDbBytes, flush: true);
      await dbTmp.rename(dbOut.path);

      final metaTmp = File(p.join(dir.path, 'base_$key.meta.json.tmp'));
      final metaOut = File(p.join(dir.path, 'base_$key.meta.json'));
      final metaJson = jsonEncode(<String, Object>{
        'revision': revision,
        'dataSha256': dataSha256.toLowerCase(),
        'attachmentManifest': <String, String>{
          for (final e in attachmentChecksums.entries)
            normalizeAttachmentArchivePath(e.key): e.value.toLowerCase(),
        },
      });
      await metaTmp.writeAsString(metaJson, flush: true);
      await metaTmp.rename(metaOut.path);
    } catch (_) {}
  });

  Future<void> _ensureSyncBaseSavedIfMissing({
    required String targetFingerprint,
    required int revision,
    required String dataSha256,
    required Map<String, String> attachmentChecksums,
    required Future<Map<String, List<Map<String, Object?>>>> Function()
    ensureLocalTables,
  }) async {
    final cleanSha = dataSha256.toLowerCase();
    final hasValid = await LocalDirectoryBackupTarget._runRootIo(() async {
      try {
        final dir = await _syncBaseDirectory();
        final key = _syncBaseKeyForTarget(targetFingerprint);
        final metaFile = File(p.join(dir.path, 'base_$key.meta.json'));
        final dbFile = File(p.join(dir.path, 'base_$key.tally'));
        if (!await metaFile.exists() || !await dbFile.exists()) return false;
        final decoded = jsonDecode(await metaFile.readAsString());
        if (decoded is! Map<String, Object?>) return false;
        return decoded['revision'] == revision &&
            decoded['dataSha256'] == cleanSha;
      } catch (_) {
        return false;
      }
    });
    if (hasValid) return;

    final tables = await ensureLocalTables();
    final packed = await _packArchiveOffloaded(
      tables: tables,
      attachments: const <String, Uint8List>{},
      createdAtMs: _nowMs(),
      includeAttachments: false,
    );
    await _writeSyncBaseSnapshot(
      targetFingerprint: targetFingerprint,
      revision: revision,
      dataSha256: cleanSha,
      lightweightDbBytes: packed.bytes,
      attachmentChecksums: attachmentChecksums,
    );
  }

  Future<
    ({Uint8List lightweightDbBytes, Map<String, String> attachmentChecksums})?
  >
  _loadSyncBaseOrRemoteAncestor({
    required CloudSyncObjectStore store,
    required String targetFingerprint,
    required int lastSyncedRevision,
    required String lastSyncedDataSha256,
    required Map<String, String> localAttChecksums,
    required Map<String, String> remoteAttChecksums,
  }) async {
    final cleanSha = lastSyncedDataSha256.toLowerCase();
    final localCached = await LocalDirectoryBackupTarget._runRootIo(() async {
      try {
        final dir = await _syncBaseDirectory();
        final key = _syncBaseKeyForTarget(targetFingerprint);
        final metaFile = File(p.join(dir.path, 'base_$key.meta.json'));
        final dbFile = File(p.join(dir.path, 'base_$key.tally'));
        if (!await metaFile.exists() || !await dbFile.exists()) return null;
        final decoded = jsonDecode(await metaFile.readAsString());
        if (decoded is! Map<String, Object?>) return null;
        if (decoded['revision'] != lastSyncedRevision ||
            decoded['dataSha256'] != cleanSha) {
          return null;
        }
        final rawAtt = decoded['attachmentManifest'];
        final attMap = <String, String>{};
        if (rawAtt is Map<String, Object?>) {
          for (final e in rawAtt.entries) {
            if (e.value is String) {
              attMap[normalizeAttachmentArchivePath(e.key)] =
                  (e.value! as String).toLowerCase();
            }
          }
        }
        return (
          lightweightDbBytes: await dbFile.readAsBytes(),
          attachmentChecksums: attMap,
        );
      } catch (_) {
        return null;
      }
    });
    if (localCached != null) {
      return localCached;
    }

    // Fallback: fetch retained ancestor `sync/revisions/db_r<lastRev>_<sha16>.tally`
    // directly by deterministic path (Top-5 retention keeps 4 prior revisions!).
    try {
      final ancestorPath = buildCloudSyncRevisionPath(
        revision: lastSyncedRevision,
        dataSha256: cleanSha,
      );
      final ancestorBytes = await store.getObjectOrNull(ancestorPath);
      if (ancestorBytes == null) return null;
      final verified = await _unpackAndVerifyArchiveOffloaded(ancestorBytes);
      final inferredAtt = <String, String>{};
      final referencedNames = collectReferencedAttachmentNames(<String?>[
        for (final r
            in verified.tables['record'] ?? const <Map<String, Object?>>[])
          r['images'] as String?,
        for (final r
            in verified.tables['record_period'] ??
                const <Map<String, Object?>>[])
          r['images'] as String?,
        for (final r
            in verified.tables['installment'] ?? const <Map<String, Object?>>[])
          r['images'] as String?,
      ]);
      for (final name in referencedNames) {
        final arch = normalizeAttachmentArchivePath(name);
        final sha = localAttChecksums[arch] ?? remoteAttChecksums[arch];
        if (sha != null) {
          inferredAtt[arch] = sha.toLowerCase();
        }
      }
      return (
        lightweightDbBytes: ancestorBytes,
        attachmentChecksums: inferredAtt,
      );
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, List<Map<String, Object?>>>> _exportAll22Tables() async {
    final accountBooks = await (db.select(
      db.accountBooks,
    )..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
    final records = await (db.select(
      db.records,
    )..orderBy([(t) => OrderingTerm.asc(t.recordId)])).get();
    final assets = await (db.select(
      db.assets,
    )..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
    final categories = await (db.select(
      db.recordCategories,
    )..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
    final budgets = await (db.select(
      db.budgets,
    )..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
    final tags = await (db.select(
      db.tags,
    )..orderBy([(t) => OrderingTerm.asc(t.tagId)])).get();
    final tagRecords =
        await (db.select(db.tagRecords)..orderBy([
              (t) => OrderingTerm.asc(t.tagId),
              (t) => OrderingTerm.asc(t.recordId),
            ]))
            .get();
    final installments = await (db.select(
      db.installments,
    )..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
    final recordPeriods = await (db.select(
      db.recordPeriods,
    )..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
    final reminderEvents = await (db.select(
      db.reminderEvents,
    )..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
    final recordTemplates = await (db.select(
      db.recordTemplates,
    )..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
    final bankCards = await (db.select(
      db.bankCards,
    )..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
    final wishes = await (db.select(
      db.wishes,
    )..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
    final remarks = await (db.select(
      db.remarks,
    )..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
    final moneySavePlans = await (db.select(
      db.moneySavePlans,
    )..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
    final moneySavePlanRecords = await (db.select(
      db.moneySavePlanRecords,
    )..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
    final assetBooks =
        await (db.select(db.assetBooks)..orderBy([
              (t) => OrderingTerm.asc(t.assetId),
              (t) => OrderingTerm.asc(t.bookId),
            ]))
            .get();
    final statStories = await (db.select(
      db.statStories,
    )..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
    final autoMaps = await (db.select(
      db.autoMaps,
    )..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
    final importPlatforms = await (db.select(
      db.importPlatforms,
    )..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
    final notes = await (db.select(
      db.notes,
    )..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
    final currencies = await (db.select(
      db.currencies,
    )..orderBy([(t) => OrderingTerm.asc(t.code)])).get();

    return <String, List<Map<String, Object?>>>{
      'account_book': <Map<String, Object?>>[
        for (final r in accountBooks)
          <String, Object?>{
            'id': r.id,
            'type': r.type,
            'name': r.name,
            'cover': r.cover,
            'sort': r.sort,
            'status': r.status,
            'start_day': r.startDay,
            'create_date': r.createDate,
            'display_way': r.displayWay,
            'extra_info': r.extraInfo,
          },
      ],
      'record': <Map<String, Object?>>[
        for (final r in records)
          <String, Object?>{
            'record_id': r.recordId,
            'type': r.type,
            'sub_type': r.subType,
            'money_minor': encodeMinorJson(r.moneyMinor),
            'remark': r.remark,
            'record_time': r.recordTime,
            'record_cat_id': r.recordCatId,
            'asset_id': r.assetId,
            'from_asset_id': r.fromAssetId,
            'to_asset_id': r.toAssetId,
            'account_book_id': r.accountBookId,
            'exclude_budget': r.excludeBudget,
            'exclude_ex_in': r.excludeExIn,
            'platform_id': r.platformId,
            'period_id': r.periodId,
            'installment': r.installment,
            'images': r.images,
            'rel_info': r.relInfo,
            'discount_minor': encodeNullableMinorJson(r.discountMinor),
            'extra_info': r.extraInfo,
            'create_date': r.createDate,
          },
      ],
      'asset': <Map<String, Object?>>[
        for (final r in assets)
          <String, Object?>{
            'id': r.id,
            'name': r.name,
            'balance_minor': encodeMinorJson(r.balanceMinor),
            'type': r.type,
            'sub_type': r.subType,
            'create_date': r.createDate,
            'sort': r.sort,
            'icon': r.icon,
            'remark': r.remark,
            'init_money_minor': encodeMinorJson(r.initMoneyMinor),
            'is_default': r.isDefault,
            'is_effective_asset': r.isEffectiveAsset,
            'used_times': r.usedTimes,
            'color': r.color,
            'status': r.status,
            'extra_info': r.extraInfo,
            'loan_info': r.loanInfo,
            'credit_info': r.creditInfo,
            'fixed_deposit_info': r.fixedDepositInfo,
            'group_name': r.groupName,
            'currency': r.currency,
          },
      ],
      'record_category': <Map<String, Object?>>[
        for (final r in categories)
          <String, Object?>{
            'id': r.id,
            'name': r.name,
            'icon': r.icon,
            'type': r.type,
            'sort': r.sort,
            'parent_cat_id': r.parentCatId,
            'color_fill': r.colorFill,
            'platform_id': r.platformId,
            'account_book_id': r.accountBookId,
            'is_hide': r.isHide,
            'extra_info': r.extraInfo,
          },
      ],
      'budget': <Map<String, Object?>>[
        for (final r in budgets)
          <String, Object?>{
            'id': r.id,
            'budget_type': r.budgetType,
            'record_cat_id': r.recordCatId,
            'amount_minor': encodeMinorJson(r.amountMinor),
            'book_id': r.bookId,
            'section': r.section,
            'sort': r.sort,
            'create_date': r.createDate,
            'remark': r.remark,
            'extra_info': r.extraInfo,
          },
      ],
      'tag': <Map<String, Object?>>[
        for (final r in tags)
          <String, Object?>{
            'tag_id': r.tagId,
            'name': r.name,
            'sort': r.sort,
            'hidden': r.hidden,
            'parent_tag_id': r.parentTagId,
            'parent': r.parent,
            'color': r.color,
            'extra_info': r.extraInfo,
          },
      ],
      'tag_record': <Map<String, Object?>>[
        for (final r in tagRecords)
          <String, Object?>{'tag_id': r.tagId, 'record_id': r.recordId},
      ],
      'installment': <Map<String, Object?>>[
        for (final r in installments)
          <String, Object?>{
            'id': r.id,
            'name': r.name,
            'cat_id': r.catId,
            'principal_minor': encodeMinorJson(r.principalMinor),
            'periods': r.periods,
            'charge_minor': encodeMinorJson(r.chargeMinor),
            'charge_way': r.chargeWay,
            'remainder_in': r.remainderIn,
            'cal_way': r.calWay,
            'start_date': r.startDate,
            'asset_id': r.assetId,
            'next_period': r.nextPeriod,
            'next_period_date': r.nextPeriodDate,
            'credited': r.credited,
            'book_id': r.bookId,
            'exclude_budget': r.excludeBudget,
            'exclude_ex_in': r.excludeExIn,
            'create_date': r.createDate,
            'tags': r.tags,
            'images': r.images,
            'exi': r.exi,
          },
      ],
      'record_period': <Map<String, Object?>>[
        for (final r in recordPeriods)
          <String, Object?>{
            'id': r.id,
            'record_type': r.recordType,
            'money_minor': encodeMinorJson(r.moneyMinor),
            'fee_minor': encodeMinorJson(r.feeMinor),
            'remark': r.remark,
            'cat_id': r.catId,
            'asset_id': r.assetId,
            'asset_id2': r.assetId2,
            'book_id': r.bookId,
            'images': r.images,
            'state': r.state,
            'time': r.time,
            'exclude_budget': r.excludeBudget,
            'exclude_ex_in': r.excludeExIn,
            'period_type': r.periodType,
            'period_type_date': r.periodTypeDate,
            'period_start_date': r.periodStartDate,
            'period_end_date': r.periodEndDate,
            'frequency': r.frequency,
            'last_add_date': r.lastAddDate,
            'period_add_times': r.periodAddTimes,
            'create_time': r.createTime,
            'tags': r.tags,
            'exi': r.exi,
          },
      ],
      'reminder_event': <Map<String, Object?>>[
        for (final r in reminderEvents)
          <String, Object?>{
            'id': r.id,
            'reminder_time': r.reminderTime,
            'reminder_tip': r.reminderTip,
          },
      ],
      'record_template': <Map<String, Object?>>[
        for (final r in recordTemplates)
          <String, Object?>{
            'id': r.id,
            'type': r.type,
            'remark': r.remark,
            'money_minor': encodeMinorJson(r.moneyMinor),
            'fee_minor': encodeMinorJson(r.feeMinor),
            'record_cat_id': r.recordCatId,
            'asset_id': r.assetId,
            'asset_id2': r.assetId2,
            'sort': r.sort,
            'auto_save': r.autoSave,
            'book_id': r.bookId,
            'exclude_budget': r.excludeBudget,
            'exclude_ex_in': r.excludeExIn,
            'create_date': r.createDate,
            'tags': r.tags,
            'exi': r.exi,
          },
      ],
      'bank_card': <Map<String, Object?>>[
        for (final r in bankCards)
          <String, Object?>{
            'id': r.id,
            'card_type': r.cardType,
            'card_name': r.cardName,
            'card_no': r.cardNo,
            'card_owner': r.cardOwner,
            'remark': r.remark,
            'card_color': r.cardColor,
            'sort': r.sort,
            'create_date': r.createDate,
            'card_asset_id': r.cardAssetId,
          },
      ],
      'wish': <Map<String, Object?>>[
        for (final r in wishes)
          <String, Object?>{
            'id': r.id,
            'content': r.content,
            'value_minor': encodeMinorJson(r.valueMinor),
            'create_date': r.createDate,
            'is_realized': r.isRealized,
            'realized_date': r.realizedDate,
            'sort': r.sort,
            'icon': r.icon,
            'target_date': r.targetDate,
          },
      ],
      'remark': <Map<String, Object?>>[
        for (final r in remarks)
          <String, Object?>{
            'id': r.id,
            'content': r.content,
            'record_cat_id': r.recordCatId,
            'used_times': r.usedTimes,
          },
      ],
      'money_save_plan': <Map<String, Object?>>[
        for (final r in moneySavePlans)
          <String, Object?>{
            'id': r.id,
            'name': r.name,
            'remark': r.remark,
            'plan_type': r.planType,
            'cycle_type': r.cycleType,
            'start_date': r.startDate,
            'end_date': r.endDate,
            'plan_money_minor': encodeMinorJson(r.planMoneyMinor),
            'saved_money_minor': encodeMinorJson(r.savedMoneyMinor),
            'auto_plan': r.autoPlan,
            'from_asset_id': r.fromAssetId,
            'to_asset_id': r.toAssetId,
            'book_id': r.bookId,
            'start_money_minor': encodeMinorJson(r.startMoneyMinor),
            'incremental_minor': encodeMinorJson(r.incrementalMinor),
            'status': r.status,
            'create_date': r.createDate,
            'sort': r.sort,
            'next_save_date': r.nextSaveDate,
            'bbz_daily_times': r.bbzDailyTimes,
            'icon': r.icon,
            'extra_info': r.extraInfo,
          },
      ],
      'money_save_plan_record': <Map<String, Object?>>[
        for (final r in moneySavePlanRecords)
          <String, Object?>{
            'id': r.id,
            'plan_id': r.planId,
            'remark': r.remark,
            'from_asset_id': r.fromAssetId,
            'to_asset_id': r.toAssetId,
            'record_date': r.recordDate,
            'record_money_minor': encodeMinorJson(r.recordMoneyMinor),
            'record_id': r.recordId,
          },
      ],
      'asset_book': <Map<String, Object?>>[
        for (final r in assetBooks)
          <String, Object?>{'asset_id': r.assetId, 'book_id': r.bookId},
      ],
      'stat_story': <Map<String, Object?>>[
        for (final r in statStories)
          <String, Object?>{
            'id': r.id,
            'story': r.story,
            'book_id': r.bookId,
            'sdate': r.sdate,
            'edate': r.edate,
            'dsection': r.dsection,
          },
      ],
      'auto_map': <Map<String, Object?>>[
        for (final r in autoMaps)
          <String, Object?>{
            'id': r.id,
            'key': r.key,
            'map_info': r.mapInfo,
            'draft': r.draft,
          },
      ],
      'import_platform': <Map<String, Object?>>[
        for (final r in importPlatforms)
          <String, Object?>{
            'id': r.id,
            'platform': r.platform,
            'import_record_count': r.importRecordCount,
            'import_category_count': r.importCategoryCount,
            'import_time': r.importTime,
            'hidden': r.hidden,
          },
      ],
      'note': <Map<String, Object?>>[
        for (final r in notes)
          <String, Object?>{
            'id': r.id,
            'title': r.title,
            'content': r.content,
            'create_time': r.createTime,
            'update_time': r.updateTime,
            'trash_time': r.trashTime,
          },
      ],
      'currency': <Map<String, Object?>>[
        for (final r in currencies)
          <String, Object?>{
            'code': r.code,
            'name': r.name,
            'symbol': r.symbol,
            'type': r.type,
            'rate_to_anchor': r.rateToAnchor,
            'anchor_code': r.anchorCode,
            'rate_refresh_time': r.rateRefreshTime,
            'icon': r.icon,
            'enable': r.enable,
          },
      ],
    };
  }

  Future<void> _sanitizeDiyDefaultAccountInTransaction(
    List<Asset> restoredAssets,
  ) async {
    final diyRow = await (db.select(
      db.preferences,
    )..where((t) => t.key.equals(prefKeyRecordDiyToolbar))).getSingleOrNull();
    if (diyRow == null || diyRow.value.isEmpty) return;
    final current = DiyToolbarConfig.decode(diyRow.value);
    if (current.defaultAccountId == noRef &&
        !current.autoSelectDefaultAccount) {
      return;
    }
    final isValidActiveNonDebt =
        current.defaultAccountId != noRef &&
        restoredAssets.any(
          (a) =>
              a.id == current.defaultAccountId &&
              a.status == AssetStatus.active &&
              a.type != AssetType.debt,
        );
    if (!isValidActiveNonDebt) {
      final resetDiy = current.copyWithDefaultAccount(
        defaultAccountId: noRef,
        autoSelectDefaultAccount: false,
      );
      await db
          .into(db.preferences)
          .insertOnConflictUpdate(
            PreferencesCompanion.insert(
              key: prefKeyRecordDiyToolbar,
              value: resetDiy.encode(),
            ),
          );
    }
  }

  Future<void> _alignOnlineRateCooldownInTransaction(
    Iterable<Currency> currencies,
  ) async {
    var maxForeignRefresh = 0;
    for (final c in currencies) {
      if (c.code.trim().toUpperCase() == 'CNY') continue;
      if (c.rateRefreshTime > maxForeignRefresh) {
        maxForeignRefresh = c.rateRefreshTime;
      }
    }
    if (maxForeignRefresh <= 0) return;
    final row =
        await (db.select(db.preferences)
              ..where((t) => t.key.equals(onlineRateSettingsPreferenceKey)))
            .getSingleOrNull();
    if (row == null || row.value.trim().isEmpty) return;
    try {
      final current = OnlineRateSettings.parse(row.value);
      if (maxForeignRefresh > current.lastSyncedAtMs) {
        final aligned = current.copyWith(lastSyncedAtMs: maxForeignRefresh);
        await db
            .into(db.preferences)
            .insertOnConflictUpdate(
              PreferencesCompanion.insert(
                key: onlineRateSettingsPreferenceKey,
                value: aligned.encode(),
              ),
            );
      }
    } catch (_) {}
  }

  static Iterable<List<T>> _chunkList<T>(List<T> items, int chunkSize) sync* {
    for (var i = 0; i < items.length; i += chunkSize) {
      final end = i + chunkSize < items.length ? i + chunkSize : items.length;
      yield items.sublist(i, end);
    }
  }

  Future<void> _applySyncTableDeltasInTransaction({
    required Map<String, SyncTableDelta> tableDeltas,
    required Map<String, List<Map<String, Object?>>> mergedTables,
  }) async {
    await db.delete(db.writeCommands).go();
    await (db.delete(
      db.preferences,
    )..where((t) => t.key.equals('periodic_last_check_ms'))).go();

    final upsertRawMap = <String, Object?>{
      for (final e in tableDeltas.entries)
        if (e.value.upserts.isNotEmpty) e.key: e.value.upserts,
    };
    final upsertRows = _parseAndValidateAll22Tables(
      upsertRawMap,
      null,
      requireSeedInvariants: false,
    );

    const chunkSz = 400;
    await db.batch((b) {
      // 1. Delete removed keys (child-first order, chunked <= 400 SQL vars).
      final delTagRec = tableDeltas['tag_record']?.deletedKeys;
      if (delTagRec != null && delTagRec.isNotEmpty) {
        for (final k in delTagRec) {
          final pair = splitCompositeSyncKey('$k');
          b.deleteWhere(
            db.tagRecords,
            (t) => t.tagId.equals(pair.$1) & t.recordId.equals(pair.$2),
          );
        }
      }
      final delSaveRec = tableDeltas['money_save_plan_record']?.deletedKeys;
      if (delSaveRec != null && delSaveRec.isNotEmpty) {
        for (final chunk in _chunkList(delSaveRec.cast<int>(), chunkSz)) {
          b.deleteWhere(db.moneySavePlanRecords, (t) => t.id.isIn(chunk));
        }
      }
      final delAssetBook = tableDeltas['asset_book']?.deletedKeys;
      if (delAssetBook != null && delAssetBook.isNotEmpty) {
        for (final k in delAssetBook) {
          final pair = splitCompositeSyncKey('$k');
          final aid = int.parse(pair.$1);
          final bid = int.parse(pair.$2);
          b.deleteWhere(
            db.assetBooks,
            (t) => t.assetId.equals(aid) & t.bookId.equals(bid),
          );
        }
      }
      final delRec = tableDeltas['record']?.deletedKeys;
      if (delRec != null && delRec.isNotEmpty) {
        for (final chunk in _chunkList(delRec.cast<String>(), chunkSz)) {
          b.deleteWhere(db.records, (t) => t.recordId.isIn(chunk));
        }
      }
      final delBud = tableDeltas['budget']?.deletedKeys;
      if (delBud != null && delBud.isNotEmpty) {
        for (final chunk in _chunkList(delBud.cast<int>(), chunkSz)) {
          b.deleteWhere(db.budgets, (t) => t.id.isIn(chunk));
        }
      }
      final delPer = tableDeltas['record_period']?.deletedKeys;
      if (delPer != null && delPer.isNotEmpty) {
        for (final chunk in _chunkList(delPer.cast<int>(), chunkSz)) {
          b.deleteWhere(db.recordPeriods, (t) => t.id.isIn(chunk));
        }
      }
      final delInst = tableDeltas['installment']?.deletedKeys;
      if (delInst != null && delInst.isNotEmpty) {
        for (final chunk in _chunkList(delInst.cast<int>(), chunkSz)) {
          b.deleteWhere(db.installments, (t) => t.id.isIn(chunk));
        }
      }
      final delTpl = tableDeltas['record_template']?.deletedKeys;
      if (delTpl != null && delTpl.isNotEmpty) {
        for (final chunk in _chunkList(delTpl.cast<int>(), chunkSz)) {
          b.deleteWhere(db.recordTemplates, (t) => t.id.isIn(chunk));
        }
      }
      final delRem = tableDeltas['remark']?.deletedKeys;
      if (delRem != null && delRem.isNotEmpty) {
        for (final chunk in _chunkList(delRem.cast<int>(), chunkSz)) {
          b.deleteWhere(db.remarks, (t) => t.id.isIn(chunk));
        }
      }
      final delCard = tableDeltas['bank_card']?.deletedKeys;
      if (delCard != null && delCard.isNotEmpty) {
        for (final chunk in _chunkList(delCard.cast<int>(), chunkSz)) {
          b.deleteWhere(db.bankCards, (t) => t.id.isIn(chunk));
        }
      }
      final delWish = tableDeltas['wish']?.deletedKeys;
      if (delWish != null && delWish.isNotEmpty) {
        for (final chunk in _chunkList(delWish.cast<String>(), chunkSz)) {
          b.deleteWhere(db.wishes, (t) => t.id.isIn(chunk));
        }
      }
      final delRemEv = tableDeltas['reminder_event']?.deletedKeys;
      if (delRemEv != null && delRemEv.isNotEmpty) {
        for (final chunk in _chunkList(delRemEv.cast<int>(), chunkSz)) {
          b.deleteWhere(db.reminderEvents, (t) => t.id.isIn(chunk));
        }
      }
      final delNote = tableDeltas['note']?.deletedKeys;
      if (delNote != null && delNote.isNotEmpty) {
        for (final chunk in _chunkList(delNote.cast<int>(), chunkSz)) {
          b.deleteWhere(db.notes, (t) => t.id.isIn(chunk));
        }
      }
      final delStory = tableDeltas['stat_story']?.deletedKeys;
      if (delStory != null && delStory.isNotEmpty) {
        for (final chunk in _chunkList(delStory.cast<String>(), chunkSz)) {
          b.deleteWhere(db.statStories, (t) => t.id.isIn(chunk));
        }
      }
      final delAuto = tableDeltas['auto_map']?.deletedKeys;
      if (delAuto != null && delAuto.isNotEmpty) {
        for (final chunk in _chunkList(delAuto.cast<int>(), chunkSz)) {
          b.deleteWhere(db.autoMaps, (t) => t.id.isIn(chunk));
        }
      }
      final delPlat = tableDeltas['import_platform']?.deletedKeys;
      if (delPlat != null && delPlat.isNotEmpty) {
        for (final chunk in _chunkList(delPlat.cast<int>(), chunkSz)) {
          b.deleteWhere(db.importPlatforms, (t) => t.id.isIn(chunk));
        }
      }
      final delSavePlan = tableDeltas['money_save_plan']?.deletedKeys;
      if (delSavePlan != null && delSavePlan.isNotEmpty) {
        for (final chunk in _chunkList(delSavePlan.cast<int>(), chunkSz)) {
          b.deleteWhere(db.moneySavePlans, (t) => t.id.isIn(chunk));
        }
      }
      final delTag = tableDeltas['tag']?.deletedKeys;
      if (delTag != null && delTag.isNotEmpty) {
        for (final chunk in _chunkList(delTag.cast<String>(), chunkSz)) {
          b.deleteWhere(db.tags, (t) => t.tagId.isIn(chunk));
        }
      }
      final delCat = tableDeltas['record_category']?.deletedKeys;
      if (delCat != null && delCat.isNotEmpty) {
        for (final chunk in _chunkList(delCat.cast<int>(), chunkSz)) {
          b.deleteWhere(db.recordCategories, (t) => t.id.isIn(chunk));
        }
      }
      final delAsset = tableDeltas['asset']?.deletedKeys;
      if (delAsset != null && delAsset.isNotEmpty) {
        for (final chunk in _chunkList(delAsset.cast<int>(), chunkSz)) {
          b.deleteWhere(db.assets, (t) => t.id.isIn(chunk));
        }
      }
      final delBook = tableDeltas['account_book']?.deletedKeys;
      if (delBook != null && delBook.isNotEmpty) {
        for (final chunk in _chunkList(delBook.cast<int>(), chunkSz)) {
          b.deleteWhere(db.accountBooks, (t) => t.id.isIn(chunk));
        }
      }
      final delCurr = tableDeltas['currency']?.deletedKeys;
      if (delCurr != null && delCurr.isNotEmpty) {
        for (final chunk in _chunkList(delCurr.cast<String>(), chunkSz)) {
          b.deleteWhere(db.currencies, (t) => t.code.isIn(chunk));
        }
      }

      // 2. Upsert added/modified rows (parent-first order).
      if (upsertRows.accountBooks.isNotEmpty) {
        b.insertAllOnConflictUpdate(db.accountBooks, upsertRows.accountBooks);
      }
      if (upsertRows.currencies.isNotEmpty) {
        b.insertAllOnConflictUpdate(db.currencies, upsertRows.currencies);
      }
      if (upsertRows.assets.isNotEmpty) {
        b.insertAllOnConflictUpdate(db.assets, upsertRows.assets);
      }
      if (upsertRows.assetBooks.isNotEmpty) {
        b.insertAllOnConflictUpdate(db.assetBooks, upsertRows.assetBooks);
      }
      if (upsertRows.recordCategories.isNotEmpty) {
        b.insertAllOnConflictUpdate(
          db.recordCategories,
          upsertRows.recordCategories,
        );
      }
      if (upsertRows.tags.isNotEmpty) {
        b.insertAllOnConflictUpdate(db.tags, upsertRows.tags);
      }
      if (upsertRows.importPlatforms.isNotEmpty) {
        b.insertAllOnConflictUpdate(
          db.importPlatforms,
          upsertRows.importPlatforms,
        );
      }
      if (upsertRows.recordPeriods.isNotEmpty) {
        b.insertAllOnConflictUpdate(db.recordPeriods, upsertRows.recordPeriods);
      }
      if (upsertRows.installments.isNotEmpty) {
        b.insertAllOnConflictUpdate(db.installments, upsertRows.installments);
      }
      if (upsertRows.records.isNotEmpty) {
        b.insertAllOnConflictUpdate(db.records, upsertRows.records);
      }
      if (upsertRows.tagRecords.isNotEmpty) {
        b.insertAllOnConflictUpdate(db.tagRecords, upsertRows.tagRecords);
      }
      if (upsertRows.budgets.isNotEmpty) {
        b.insertAllOnConflictUpdate(db.budgets, upsertRows.budgets);
      }
      if (upsertRows.reminderEvents.isNotEmpty) {
        b.insertAllOnConflictUpdate(
          db.reminderEvents,
          upsertRows.reminderEvents,
        );
      }
      if (upsertRows.recordTemplates.isNotEmpty) {
        b.insertAllOnConflictUpdate(
          db.recordTemplates,
          upsertRows.recordTemplates,
        );
      }
      if (upsertRows.bankCards.isNotEmpty) {
        b.insertAllOnConflictUpdate(db.bankCards, upsertRows.bankCards);
      }
      if (upsertRows.wishes.isNotEmpty) {
        b.insertAllOnConflictUpdate(db.wishes, upsertRows.wishes);
      }
      if (upsertRows.remarks.isNotEmpty) {
        b.insertAllOnConflictUpdate(db.remarks, upsertRows.remarks);
      }
      if (upsertRows.moneySavePlans.isNotEmpty) {
        b.insertAllOnConflictUpdate(
          db.moneySavePlans,
          upsertRows.moneySavePlans,
        );
      }
      if (upsertRows.moneySavePlanRecords.isNotEmpty) {
        b.insertAllOnConflictUpdate(
          db.moneySavePlanRecords,
          upsertRows.moneySavePlanRecords,
        );
      }
      if (upsertRows.statStories.isNotEmpty) {
        b.insertAllOnConflictUpdate(db.statStories, upsertRows.statStories);
      }
      if (upsertRows.autoMaps.isNotEmpty) {
        b.insertAllOnConflictUpdate(db.autoMaps, upsertRows.autoMaps);
      }
      if (upsertRows.notes.isNotEmpty) {
        b.insertAllOnConflictUpdate(db.notes, upsertRows.notes);
      }
    });

    final metaRows = _parseAndValidateAll22Tables(
      <String, Object?>{
        'account_book': mergedTables['account_book'],
        'asset': mergedTables['asset'],
        'currency': mergedTables['currency'],
      },
      null,
      requireSeedInvariants: false,
    );
    await _sanitizeDiyDefaultAccountInTransaction(metaRows.assets);
    await _alignOnlineRateCooldownInTransaction(metaRows.currencies);

    final curBookRow = await (db.select(
      db.preferences,
    )..where((t) => t.key.equals(prefKeyCurrentBookId))).getSingleOrNull();
    final curBookId = int.tryParse(curBookRow?.value ?? '');
    if (curBookId == null ||
        !metaRows.accountBooks.any((b) => b.id == curBookId)) {
      final activeBookId = resolveRestoredActiveBookId(
        metaRows.accountBooks.map((b) => (id: b.id, sort: b.sort)),
      );
      await db
          .into(db.preferences)
          .insertOnConflictUpdate(
            PreferencesCompanion.insert(
              key: prefKeyCurrentBookId,
              value: '$activeBookId',
            ),
          );
    }
  }

  Future<void> _clearAll22TablesInTransaction() async {
    await db.batch((b) {
      b.deleteAll(db.tagRecords);
      b.deleteAll(db.moneySavePlanRecords);
      b.deleteAll(db.assetBooks);
      b.deleteAll(db.records);
      b.deleteAll(db.budgets);
      b.deleteAll(db.recordPeriods);
      b.deleteAll(db.installments);
      b.deleteAll(db.recordTemplates);
      b.deleteAll(db.remarks);
      b.deleteAll(db.bankCards);
      b.deleteAll(db.wishes);
      b.deleteAll(db.reminderEvents);
      b.deleteAll(db.notes);
      b.deleteAll(db.statStories);
      b.deleteAll(db.autoMaps);
      b.deleteAll(db.importPlatforms);
      b.deleteAll(db.moneySavePlans);
      b.deleteAll(db.tags);
      b.deleteAll(db.recordCategories);
      b.deleteAll(db.assets);
      b.deleteAll(db.accountBooks);
      b.deleteAll(db.currencies);
    });
  }

  Future<void> _insertAll22TablesInTransaction(
    _ValidatedDatabaseRows rows,
  ) async {
    await db.batch((b) {
      if (rows.accountBooks.isNotEmpty) {
        b.insertAll(db.accountBooks, rows.accountBooks);
      }
      if (rows.currencies.isNotEmpty) {
        b.insertAll(db.currencies, rows.currencies);
      }
      if (rows.assets.isNotEmpty) {
        b.insertAll(db.assets, rows.assets);
      }
      if (rows.assetBooks.isNotEmpty) {
        b.insertAll(db.assetBooks, rows.assetBooks);
      }
      if (rows.recordCategories.isNotEmpty) {
        b.insertAll(db.recordCategories, rows.recordCategories);
      }
      if (rows.tags.isNotEmpty) {
        b.insertAll(db.tags, rows.tags);
      }
      if (rows.importPlatforms.isNotEmpty) {
        b.insertAll(db.importPlatforms, rows.importPlatforms);
      }
      if (rows.recordPeriods.isNotEmpty) {
        b.insertAll(db.recordPeriods, rows.recordPeriods);
      }
      if (rows.installments.isNotEmpty) {
        b.insertAll(db.installments, rows.installments);
      }
      if (rows.records.isNotEmpty) {
        b.insertAll(db.records, rows.records);
      }
      if (rows.tagRecords.isNotEmpty) {
        b.insertAll(db.tagRecords, rows.tagRecords);
      }
      if (rows.budgets.isNotEmpty) {
        b.insertAll(db.budgets, rows.budgets);
      }
      if (rows.reminderEvents.isNotEmpty) {
        b.insertAll(db.reminderEvents, rows.reminderEvents);
      }
      if (rows.recordTemplates.isNotEmpty) {
        b.insertAll(db.recordTemplates, rows.recordTemplates);
      }
      if (rows.bankCards.isNotEmpty) {
        b.insertAll(db.bankCards, rows.bankCards);
      }
      if (rows.wishes.isNotEmpty) {
        b.insertAll(db.wishes, rows.wishes);
      }
      if (rows.remarks.isNotEmpty) {
        b.insertAll(db.remarks, rows.remarks);
      }
      if (rows.moneySavePlans.isNotEmpty) {
        b.insertAll(db.moneySavePlans, rows.moneySavePlans);
      }
      if (rows.moneySavePlanRecords.isNotEmpty) {
        b.insertAll(db.moneySavePlanRecords, rows.moneySavePlanRecords);
      }
      if (rows.statStories.isNotEmpty) {
        b.insertAll(db.statStories, rows.statStories);
      }
      if (rows.autoMaps.isNotEmpty) {
        b.insertAll(db.autoMaps, rows.autoMaps);
      }
      if (rows.notes.isNotEmpty) {
        b.insertAll(db.notes, rows.notes);
      }
    });
  }

  static _ValidatedDatabaseRows _parseAndValidateAll22Tables(
    Map<String, Object?> rawDbJson,
    TallyManifest? manifest, {
    bool requireSeedInvariants = true,
  }) {
    List<Map<String, Object?>> tableMaps(String name) {
      final raw = rawDbJson[name];
      final List<Map<String, Object?>> rows;
      if (raw == null) {
        rows = const <Map<String, Object?>>[];
      } else if (raw is List) {
        rows = <Map<String, Object?>>[
          for (final item in raw)
            item is Map<String, Object?>
                ? item
                : throw Failure(FailureCode.corruptData, '备份表 $name 行记录格式损坏'),
        ];
      } else {
        throw Failure(FailureCode.corruptData, '备份表 $name 必须为数组');
      }
      final expectedCount = manifest?.tableCounts[name];
      if (expectedCount != null && rows.length != expectedCount) {
        throw Failure(
          FailureCode.corruptData,
          '备份表 $name 记录数（${rows.length}）与清单（$expectedCount）不一致',
        );
      }
      return rows;
    }

    final validated = _ValidatedDatabaseRows(
      accountBooks: <AccountBook>[
        for (final m in tableMaps('account_book'))
          AccountBook(
            id: _reqInt(m, 'id', 'account_book'),
            type: _defInt(m, 'type', 1, 'account_book'),
            name: _reqStr(m, 'name', 'account_book'),
            cover: _defStr(m, 'cover', '', 'account_book'),
            sort: _defInt(m, 'sort', 1, 'account_book'),
            status: _defInt(m, 'status', 0, 'account_book'),
            startDay: _defInt(m, 'start_day', 1, 'account_book'),
            createDate: _reqInt(m, 'create_date', 'account_book'),
            displayWay: _defInt(m, 'display_way', 0, 'account_book'),
            extraInfo: _optStr(m, 'extra_info', 'account_book'),
          ),
      ],
      records: <LedgerRecord>[
        for (final m in tableMaps('record'))
          LedgerRecord(
            recordId: _reqStr(m, 'record_id', 'record'),
            type: _reqInt(m, 'type', 'record'),
            subType: _defInt(m, 'sub_type', -1, 'record'),
            moneyMinor: decodeMinorJson(
              m['money_minor'],
              field: 'record.money_minor',
            ),
            remark: _defStr(m, 'remark', '', 'record'),
            recordTime: _reqInt(m, 'record_time', 'record'),
            recordCatId: _defInt(m, 'record_cat_id', -1, 'record'),
            assetId: _defInt(m, 'asset_id', -1, 'record'),
            fromAssetId: _defInt(m, 'from_asset_id', -1, 'record'),
            toAssetId: _defInt(m, 'to_asset_id', -1, 'record'),
            accountBookId: _reqInt(m, 'account_book_id', 'record'),
            excludeBudget: _defBool(m, 'exclude_budget', false, 'record'),
            excludeExIn: _defBool(m, 'exclude_ex_in', false, 'record'),
            platformId: _defInt(m, 'platform_id', -1, 'record'),
            periodId: _defInt(m, 'period_id', -1, 'record'),
            installment: _optStr(m, 'installment', 'record'),
            images: _optStr(m, 'images', 'record'),
            relInfo: _optStr(m, 'rel_info', 'record'),
            discountMinor: decodeNullableMinorJson(
              m['discount_minor'],
              field: 'record.discount_minor',
            ),
            extraInfo: _optStr(m, 'extra_info', 'record'),
            createDate: _optInt(m, 'create_date', 'record'),
          ),
      ],
      assets: <Asset>[
        for (final m in tableMaps('asset'))
          Asset(
            id: _reqInt(m, 'id', 'asset'),
            name: _reqStr(m, 'name', 'asset'),
            balanceMinor: decodeMinorJson(
              m['balance_minor'],
              field: 'asset.balance_minor',
            ),
            type: _reqInt(m, 'type', 'asset'),
            subType: _defInt(m, 'sub_type', -1, 'asset'),
            createDate: _reqInt(m, 'create_date', 'asset'),
            sort: _defInt(m, 'sort', 0, 'asset'),
            icon: _defStr(m, 'icon', '', 'asset'),
            remark: _optStr(m, 'remark', 'asset'),
            initMoneyMinor: decodeMinorJson(
              m['init_money_minor'],
              field: 'asset.init_money_minor',
            ),
            isDefault: _defBool(m, 'is_default', false, 'asset'),
            isEffectiveAsset: _defInt(m, 'is_effective_asset', 1, 'asset'),
            usedTimes: _defInt(m, 'used_times', 0, 'asset'),
            color: _optStr(m, 'color', 'asset'),
            status: _defInt(m, 'status', 0, 'asset'),
            extraInfo: _optStr(m, 'extra_info', 'asset'),
            loanInfo: _optStr(m, 'loan_info', 'asset'),
            creditInfo: _optStr(m, 'credit_info', 'asset'),
            fixedDepositInfo: _optStr(m, 'fixed_deposit_info', 'asset'),
            groupName: _optStr(m, 'group_name', 'asset'),
            currency: _optStr(m, 'currency', 'asset'),
          ),
      ],
      recordCategories: <RecordCategory>[
        for (final m in tableMaps('record_category'))
          RecordCategory(
            id: _reqInt(m, 'id', 'record_category'),
            name: _reqStr(m, 'name', 'record_category'),
            icon: _defStr(m, 'icon', '', 'record_category'),
            type: _reqInt(m, 'type', 'record_category'),
            sort: _defInt(m, 'sort', 0, 'record_category'),
            parentCatId: _defInt(m, 'parent_cat_id', -1, 'record_category'),
            colorFill: _optStr(m, 'color_fill', 'record_category'),
            platformId: _defInt(m, 'platform_id', -1, 'record_category'),
            accountBookId: _reqInt(m, 'account_book_id', 'record_category'),
            isHide: _defBool(m, 'is_hide', false, 'record_category'),
            extraInfo: _optStr(m, 'extra_info', 'record_category'),
          ),
      ],
      budgets: <Budget>[
        for (final m in tableMaps('budget'))
          Budget(
            id: _reqInt(m, 'id', 'budget'),
            budgetType: _reqInt(m, 'budget_type', 'budget'),
            recordCatId: _reqInt(m, 'record_cat_id', 'budget'),
            amountMinor: decodeMinorJson(
              m['amount_minor'],
              field: 'budget.amount_minor',
            ),
            bookId: _reqInt(m, 'book_id', 'budget'),
            section: _reqStr(m, 'section', 'budget'),
            sort: _defInt(m, 'sort', 0, 'budget'),
            createDate: _reqInt(m, 'create_date', 'budget'),
            remark: _optStr(m, 'remark', 'budget'),
            extraInfo: _optStr(m, 'extra_info', 'budget'),
          ),
      ],
      tags: <Tag>[
        for (final m in tableMaps('tag'))
          Tag(
            tagId: _reqStr(m, 'tag_id', 'tag'),
            name: _reqStr(m, 'name', 'tag'),
            sort: _defInt(m, 'sort', 0, 'tag'),
            hidden: _defBool(m, 'hidden', false, 'tag'),
            parentTagId: _optStr(m, 'parent_tag_id', 'tag'),
            parent: _defInt(m, 'parent', 0, 'tag'),
            color: _optStr(m, 'color', 'tag'),
            extraInfo: _optStr(m, 'extra_info', 'tag'),
          ),
      ],
      tagRecords: <TagRecord>[
        for (final m in tableMaps('tag_record'))
          TagRecord(
            tagId: _reqStr(m, 'tag_id', 'tag_record'),
            recordId: _reqStr(m, 'record_id', 'tag_record'),
          ),
      ],
      installments: <Installment>[
        for (final m in tableMaps('installment'))
          Installment(
            id: _reqInt(m, 'id', 'installment'),
            name: _reqStr(m, 'name', 'installment'),
            catId: _defInt(m, 'cat_id', -1, 'installment'),
            principalMinor: decodeMinorJson(
              m['principal_minor'],
              field: 'installment.principal_minor',
            ),
            periods: _reqInt(m, 'periods', 'installment'),
            chargeMinor: decodeMinorJson(
              m['charge_minor'],
              field: 'installment.charge_minor',
            ),
            chargeWay: _reqInt(m, 'charge_way', 'installment'),
            remainderIn: _reqInt(m, 'remainder_in', 'installment'),
            calWay: _reqInt(m, 'cal_way', 'installment'),
            startDate: _reqInt(m, 'start_date', 'installment'),
            assetId: _reqInt(m, 'asset_id', 'installment'),
            nextPeriod: _reqInt(m, 'next_period', 'installment'),
            nextPeriodDate: _reqInt(m, 'next_period_date', 'installment'),
            credited: _optStr(m, 'credited', 'installment'),
            bookId: _reqInt(m, 'book_id', 'installment'),
            excludeBudget: _defBool(m, 'exclude_budget', false, 'installment'),
            excludeExIn: _defBool(m, 'exclude_ex_in', false, 'installment'),
            createDate: _reqInt(m, 'create_date', 'installment'),
            tags: _optStr(m, 'tags', 'installment'),
            images: _optStr(m, 'images', 'installment'),
            exi: _optStr(m, 'exi', 'installment'),
          ),
      ],
      recordPeriods: <RecordPeriod>[
        for (final m in tableMaps('record_period'))
          RecordPeriod(
            id: _reqInt(m, 'id', 'record_period'),
            recordType: _reqInt(m, 'record_type', 'record_period'),
            moneyMinor: decodeMinorJson(
              m['money_minor'],
              field: 'record_period.money_minor',
            ),
            feeMinor: m['fee_minor'] == null
                ? BigInt.zero
                : decodeMinorJson(
                    m['fee_minor'],
                    field: 'record_period.fee_minor',
                  ),
            remark: _defStr(m, 'remark', '', 'record_period'),
            catId: _defInt(m, 'cat_id', -1, 'record_period'),
            assetId: _defInt(m, 'asset_id', -1, 'record_period'),
            assetId2: _defInt(m, 'asset_id2', -1, 'record_period'),
            bookId: _reqInt(m, 'book_id', 'record_period'),
            images: _optStr(m, 'images', 'record_period'),
            state: _defInt(m, 'state', 0, 'record_period'),
            time: _optStr(m, 'time', 'record_period'),
            excludeBudget: _defBool(
              m,
              'exclude_budget',
              false,
              'record_period',
            ),
            excludeExIn: _defBool(m, 'exclude_ex_in', false, 'record_period'),
            periodType: _reqInt(m, 'period_type', 'record_period'),
            periodTypeDate: _reqStr(m, 'period_type_date', 'record_period'),
            periodStartDate: _reqInt(m, 'period_start_date', 'record_period'),
            periodEndDate: _reqInt(m, 'period_end_date', 'record_period'),
            frequency: _defInt(m, 'frequency', 1, 'record_period'),
            lastAddDate: _defInt(m, 'last_add_date', -1, 'record_period'),
            periodAddTimes: _defInt(m, 'period_add_times', 0, 'record_period'),
            createTime: _reqInt(m, 'create_time', 'record_period'),
            tags: _optStr(m, 'tags', 'record_period'),
            exi: _optStr(m, 'exi', 'record_period'),
          ),
      ],
      reminderEvents: <ReminderEvent>[
        for (final m in tableMaps('reminder_event'))
          ReminderEvent(
            id: _reqInt(m, 'id', 'reminder_event'),
            reminderTime: _reqInt(m, 'reminder_time', 'reminder_event'),
            reminderTip: _optStr(m, 'reminder_tip', 'reminder_event'),
          ),
      ],
      recordTemplates: <RecordTemplate>[
        for (final m in tableMaps('record_template'))
          RecordTemplate(
            id: _reqInt(m, 'id', 'record_template'),
            type: _reqInt(m, 'type', 'record_template'),
            remark: _optStr(m, 'remark', 'record_template'),
            moneyMinor: decodeMinorJson(
              m['money_minor'],
              field: 'record_template.money_minor',
            ),
            feeMinor: m['fee_minor'] == null
                ? BigInt.zero
                : decodeMinorJson(
                    m['fee_minor'],
                    field: 'record_template.fee_minor',
                  ),
            recordCatId: _optInt(m, 'record_cat_id', 'record_template'),
            assetId: _defInt(m, 'asset_id', -1, 'record_template'),
            assetId2: _defInt(m, 'asset_id2', -1, 'record_template'),
            sort: _defInt(m, 'sort', 0, 'record_template'),
            autoSave: _defBool(m, 'auto_save', false, 'record_template'),
            bookId: _reqInt(m, 'book_id', 'record_template'),
            excludeBudget: _defBool(
              m,
              'exclude_budget',
              false,
              'record_template',
            ),
            excludeExIn: _defBool(m, 'exclude_ex_in', false, 'record_template'),
            createDate: _reqInt(m, 'create_date', 'record_template'),
            tags: _optStr(m, 'tags', 'record_template'),
            exi: _optStr(m, 'exi', 'record_template'),
          ),
      ],
      bankCards: <BankCard>[
        for (final m in tableMaps('bank_card'))
          BankCard(
            id: _reqInt(m, 'id', 'bank_card'),
            cardType: _reqInt(m, 'card_type', 'bank_card'),
            cardName: _reqStr(m, 'card_name', 'bank_card'),
            cardNo: _reqStr(m, 'card_no', 'bank_card'),
            cardOwner: _reqStr(m, 'card_owner', 'bank_card'),
            remark: _defStr(m, 'remark', '', 'bank_card'),
            cardColor: _optStr(m, 'card_color', 'bank_card'),
            sort: _defInt(m, 'sort', -1, 'bank_card'),
            createDate: _reqInt(m, 'create_date', 'bank_card'),
            cardAssetId: _defInt(m, 'card_asset_id', -1, 'bank_card'),
          ),
      ],
      wishes: <Wish>[
        for (final m in tableMaps('wish'))
          Wish(
            id: _reqStr(m, 'id', 'wish'),
            content: _reqStr(m, 'content', 'wish'),
            valueMinor: decodeMinorJson(
              m['value_minor'],
              field: 'wish.value_minor',
            ),
            createDate: _reqInt(m, 'create_date', 'wish'),
            isRealized: _defBool(m, 'is_realized', false, 'wish'),
            realizedDate: _defInt(m, 'realized_date', 0, 'wish'),
            sort: _defInt(m, 'sort', 0, 'wish'),
            icon: _optStr(m, 'icon', 'wish'),
            targetDate: _defInt(m, 'target_date', 0, 'wish'),
          ),
      ],
      remarks: <Remark>[
        for (final m in tableMaps('remark'))
          Remark(
            id: _reqInt(m, 'id', 'remark'),
            content: _reqStr(m, 'content', 'remark'),
            recordCatId: _reqInt(m, 'record_cat_id', 'remark'),
            usedTimes: _defInt(m, 'used_times', 0, 'remark'),
          ),
      ],
      moneySavePlans: <MoneySavePlan>[
        for (final m in tableMaps('money_save_plan'))
          MoneySavePlan(
            id: _reqInt(m, 'id', 'money_save_plan'),
            name: _reqStr(m, 'name', 'money_save_plan'),
            remark: _defStr(m, 'remark', '', 'money_save_plan'),
            planType: _reqInt(m, 'plan_type', 'money_save_plan'),
            cycleType: _reqInt(m, 'cycle_type', 'money_save_plan'),
            startDate: _reqInt(m, 'start_date', 'money_save_plan'),
            endDate: _reqInt(m, 'end_date', 'money_save_plan'),
            planMoneyMinor: decodeMinorJson(
              m['plan_money_minor'],
              field: 'money_save_plan.plan_money_minor',
            ),
            savedMoneyMinor: decodeMinorJson(
              m['saved_money_minor'],
              field: 'money_save_plan.saved_money_minor',
            ),
            autoPlan: _defBool(m, 'auto_plan', false, 'money_save_plan'),
            fromAssetId: _defInt(m, 'from_asset_id', -1, 'money_save_plan'),
            toAssetId: _defInt(m, 'to_asset_id', -1, 'money_save_plan'),
            bookId: _defInt(m, 'book_id', -1, 'money_save_plan'),
            startMoneyMinor: decodeMinorJson(
              m['start_money_minor'],
              field: 'money_save_plan.start_money_minor',
            ),
            incrementalMinor: decodeMinorJson(
              m['incremental_minor'],
              field: 'money_save_plan.incremental_minor',
            ),
            status: _defInt(m, 'status', 0, 'money_save_plan'),
            createDate: _reqInt(m, 'create_date', 'money_save_plan'),
            sort: _defInt(m, 'sort', 0, 'money_save_plan'),
            nextSaveDate: _reqInt(m, 'next_save_date', 'money_save_plan'),
            bbzDailyTimes: _defInt(m, 'bbz_daily_times', 0, 'money_save_plan'),
            icon: _optStr(m, 'icon', 'money_save_plan'),
            extraInfo: _optStr(m, 'extra_info', 'money_save_plan'),
          ),
      ],
      moneySavePlanRecords: <MoneySavePlanRecord>[
        for (final m in tableMaps('money_save_plan_record'))
          MoneySavePlanRecord(
            id: _reqInt(m, 'id', 'money_save_plan_record'),
            planId: _reqInt(m, 'plan_id', 'money_save_plan_record'),
            remark: _defStr(m, 'remark', '', 'money_save_plan_record'),
            fromAssetId: _defInt(
              m,
              'from_asset_id',
              -1,
              'money_save_plan_record',
            ),
            toAssetId: _defInt(m, 'to_asset_id', -1, 'money_save_plan_record'),
            recordDate: _reqInt(m, 'record_date', 'money_save_plan_record'),
            recordMoneyMinor: decodeMinorJson(
              m['record_money_minor'],
              field: 'money_save_plan_record.record_money_minor',
            ),
            recordId: _optStr(m, 'record_id', 'money_save_plan_record'),
          ),
      ],
      assetBooks: <AssetBook>[
        for (final m in tableMaps('asset_book'))
          AssetBook(
            assetId: _reqInt(m, 'asset_id', 'asset_book'),
            bookId: _reqInt(m, 'book_id', 'asset_book'),
          ),
      ],
      statStories: <StatStory>[
        for (final m in tableMaps('stat_story'))
          StatStory(
            id: _reqStr(m, 'id', 'stat_story'),
            story: _reqStr(m, 'story', 'stat_story'),
            bookId: _reqInt(m, 'book_id', 'stat_story'),
            sdate: _reqInt(m, 'sdate', 'stat_story'),
            edate: _reqInt(m, 'edate', 'stat_story'),
            dsection: _optStr(m, 'dsection', 'stat_story'),
          ),
      ],
      autoMaps: <AutoMap>[
        for (final m in tableMaps('auto_map'))
          AutoMap(
            id: _reqInt(m, 'id', 'auto_map'),
            key: _reqStr(m, 'key', 'auto_map'),
            mapInfo: _optStr(m, 'map_info', 'auto_map'),
            draft: _optStr(m, 'draft', 'auto_map'),
          ),
      ],
      importPlatforms: <ImportPlatform>[
        for (final m in tableMaps('import_platform'))
          ImportPlatform(
            id: _reqInt(m, 'id', 'import_platform'),
            platform: _reqStr(m, 'platform', 'import_platform'),
            importRecordCount: _reqInt(
              m,
              'import_record_count',
              'import_platform',
            ),
            importCategoryCount: _reqInt(
              m,
              'import_category_count',
              'import_platform',
            ),
            importTime: _reqInt(m, 'import_time', 'import_platform'),
            hidden: _defBool(m, 'hidden', false, 'import_platform'),
          ),
      ],
      notes: <Note>[
        for (final m in tableMaps('note'))
          Note(
            id: _reqInt(m, 'id', 'note'),
            title: _optStr(m, 'title', 'note'),
            content: _reqStr(m, 'content', 'note'),
            createTime: _reqInt(m, 'create_time', 'note'),
            updateTime: _reqInt(m, 'update_time', 'note'),
            trashTime: _defInt(m, 'trash_time', 0, 'note'),
          ),
      ],
      currencies: <Currency>[
        for (final m in tableMaps('currency'))
          Currency(
            code: _reqStr(m, 'code', 'currency'),
            name: _reqStr(m, 'name', 'currency'),
            symbol: _reqStr(m, 'symbol', 'currency'),
            type: _defInt(m, 'type', 0, 'currency'),
            rateToAnchor: _reqStr(m, 'rate_to_anchor', 'currency'),
            anchorCode: _reqStr(m, 'anchor_code', 'currency'),
            rateRefreshTime: _defInt(m, 'rate_refresh_time', 0, 'currency'),
            icon: _optStr(m, 'icon', 'currency'),
            enable: _defBool(m, 'enable', true, 'currency'),
          ),
      ],
    );
    if (requireSeedInvariants) {
      if (validated.accountBooks.isEmpty) {
        throw const Failure(
          FailureCode.corruptData,
          '备份数据缺少有效账本（account_book 不能为空），已拒绝恢复',
        );
      }
      final hasBaseCny = validated.currencies.any(
        (c) => c.code.trim().toUpperCase() == 'CNY',
      );
      if (!hasBaseCny) {
        throw const Failure(FailureCode.corruptData, '备份数据缺少本位币 CNY 配置，已拒绝恢复');
      }
    }
    return validated;
  }

  static int _reqInt(Map<String, Object?> m, String key, String table) {
    final v = m[key];
    if (v is int) return v;
    if (v is String) {
      final parsed = int.tryParse(v);
      if (parsed != null) return parsed;
    }
    throw Failure(FailureCode.corruptData, '表 $table 缺少有效的整数字段 $key');
  }

  static int? _optInt(Map<String, Object?> m, String key, String table) {
    final v = m[key];
    if (v == null) return null;
    return _reqInt(m, key, table);
  }

  static int _defInt(
    Map<String, Object?> m,
    String key,
    int fallback,
    String table,
  ) => m[key] == null ? fallback : _reqInt(m, key, table);

  static String _reqStr(Map<String, Object?> m, String key, String table) {
    final v = m[key];
    if (v is String) return v;
    throw Failure(FailureCode.corruptData, '表 $table 缺少有效的文本字段 $key');
  }

  static String? _optStr(Map<String, Object?> m, String key, String table) {
    final v = m[key];
    if (v == null) return null;
    if (v is String) return v;
    throw Failure(FailureCode.corruptData, '表 $table 文本字段 $key 类型损坏');
  }

  static String _defStr(
    Map<String, Object?> m,
    String key,
    String fallback,
    String table,
  ) => m[key] == null ? fallback : _reqStr(m, key, table);

  static bool _defBool(
    Map<String, Object?> m,
    String key,
    bool fallback,
    String table,
  ) {
    final v = m[key];
    if (v == null) return fallback;
    if (v is bool) return v;
    if (v is int && (v == 0 || v == 1)) return v == 1;
    throw Failure(FailureCode.corruptData, '表 $table 布尔字段 $key 类型损坏');
  }
}

final class _ValidatedDatabaseRows {
  const _ValidatedDatabaseRows({
    required this.accountBooks,
    required this.records,
    required this.assets,
    required this.recordCategories,
    required this.budgets,
    required this.tags,
    required this.tagRecords,
    required this.installments,
    required this.recordPeriods,
    required this.reminderEvents,
    required this.recordTemplates,
    required this.bankCards,
    required this.wishes,
    required this.remarks,
    required this.moneySavePlans,
    required this.moneySavePlanRecords,
    required this.assetBooks,
    required this.statStories,
    required this.autoMaps,
    required this.importPlatforms,
    required this.notes,
    required this.currencies,
  });

  final List<AccountBook> accountBooks;
  final List<LedgerRecord> records;
  final List<Asset> assets;
  final List<RecordCategory> recordCategories;
  final List<Budget> budgets;
  final List<Tag> tags;
  final List<TagRecord> tagRecords;
  final List<Installment> installments;
  final List<RecordPeriod> recordPeriods;
  final List<ReminderEvent> reminderEvents;
  final List<RecordTemplate> recordTemplates;
  final List<BankCard> bankCards;
  final List<Wish> wishes;
  final List<Remark> remarks;
  final List<MoneySavePlan> moneySavePlans;
  final List<MoneySavePlanRecord> moneySavePlanRecords;
  final List<AssetBook> assetBooks;
  final List<StatStory> statStories;
  final List<AutoMap> autoMaps;
  final List<ImportPlatform> importPlatforms;
  final List<Note> notes;
  final List<Currency> currencies;
}

enum _RemoteHeadProbeState { missing, legacyFormat, valid }

final class _RemoteHeadProbe {
  const _RemoteHeadProbe.missing()
    : state = _RemoteHeadProbeState.missing,
      head = null,
      etag = null;

  const _RemoteHeadProbe.legacy()
    : state = _RemoteHeadProbeState.legacyFormat,
      head = null,
      etag = null;

  const _RemoteHeadProbe.valid(CloudSyncHead this.head, {this.etag})
    : state = _RemoteHeadProbeState.valid;

  final _RemoteHeadProbeState state;
  final CloudSyncHead? head;
  final String? etag;
}

final class _RemoteSyncState {
  const _RemoteSyncState({
    required this.head,
    this.headEtag,
    this.isLegacyFormat = false,
    this.legacyRevision,
    this.orphanOrLegacyDbBytes,
    this.orphanRevisionHint,
  });

  final CloudSyncHead? head;
  final String? headEtag;
  final bool isLegacyFormat;
  final int? legacyRevision;
  final Uint8List? orphanOrLegacyDbBytes;
  final int? orphanRevisionHint;
}
