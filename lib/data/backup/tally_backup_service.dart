import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/failure.dart';
import '../../core/zip_archive.dart';
import '../../domain/rules/cloud_sync_rules.dart';
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
const String _prefKeyCurrentBookId = 'current_book_id';

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

  @override
  Future<List<BackupFileMetadata>> listBackups() async {
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
        final bytes = await entity.readAsBytes();
        final zip = ZipArchive.decode(bytes);
        final manifestEntry = zip[tallyManifestFileName];
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
      return b.fileName.compareTo(a.fileName);
    });
    return items;
  }

  @override
  Future<BackupFileMetadata> writeBackup(
    String fileName,
    Uint8List bytes, {
    BackupProgressCallback? onProgress,
  }) async {
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
      manifest = unpackAndVerifyTallyArchive(bytes).manifest;
    } catch (_) {}

    final stat = await finalFile.stat();
    return BackupFileMetadata(
      fileName: cleanName,
      sizeBytes: stat.size,
      modifiedAtMs:
          manifest?.createdAtMs ?? stat.modified.millisecondsSinceEpoch,
      manifest: manifest,
    );
  }

  @override
  Future<Uint8List> readBackup(
    String fileName, {
    BackupProgressCallback? onProgress,
  }) async {
    final cleanName = _validateFileName(fileName);
    final dir = await directoryProvider();
    final file = File(p.join(dir.path, cleanName));
    if (!await file.exists()) {
      throw const Failure(FailureCode.storageUnavailable, '本地备份文件不存在');
    }
    final bytes = await file.readAsBytes();
    onProgress?.call(bytes.length, bytes.length);
    return bytes;
  }

  @override
  Future<void> deleteBackup(String fileName) async {
    final cleanName = _validateFileName(fileName);
    final dir = await directoryProvider();
    final file = File(p.join(dir.path, cleanName));
    if (await file.exists()) {
      await file.delete();
    }
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
    this.httpClientFactory,
    this.appVersion = tallyDefaultAppVersion,
  }) : _localBackupsDirProvider =
           localBackupsDirectoryProvider ?? _defaultBackupsDirectory,
       _attachmentsDirProvider =
           attachmentsDirectoryProvider ?? _defaultAttachmentsDirectory;

  final AppDatabase db;
  final ReminderService reminderService;
  final Future<Directory> Function() _localBackupsDirProvider;
  final Future<Directory> Function() _attachmentsDirProvider;
  final HttpClient Function()? httpClientFactory;
  final String appVersion;

  late final LocalDirectoryBackupTarget localTarget =
      LocalDirectoryBackupTarget(_localBackupsDirProvider);

  String? _cachedFallbackDeviceId;
  Future<void>? _syncSerialChain;

  static Directory? _headlessSupportRoot;

  static Future<Directory> _resolveSupportRoot() async {
    try {
      return await getApplicationSupportDirectory();
    } on MissingPluginException {
      return _headlessSupportRoot ??= await Directory.systemTemp.createTemp(
        'tallyisle_support_',
      );
    }
  }

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
      return resolveEffectiveCloudSyncSettings(
        rawJson: rawSync,
        isWebDavConfigured: davCfg.isConfigured,
        fallbackDeviceId: _ensureFallbackDeviceId(),
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
    return resolveEffectiveCloudSyncSettings(
      rawJson: rawSync,
      isWebDavConfigured: davCfg.isConfigured,
      fallbackDeviceId: _ensureFallbackDeviceId(),
    );
  }

  /// Persists [settings] to `ti_preference` (`cloud_sync_settings`).
  Future<void> saveCloudSyncSettings(CloudSyncSettings settings) async {
    final normalized = settings.copyWith(
      deviceId: settings.deviceId.trim().isEmpty
          ? _ensureFallbackDeviceId()
          : settings.deviceId.trim(),
      deviceName: settings.deviceName.trim().isEmpty
          ? '帐屿本机'
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

  /// Enables or disables automatic multi-device cloud sync on app resume.
  Future<void> setAutoSyncEnabled(bool enabled) async {
    final settings = await getCloudSyncSettings();
    if (enabled) {
      if (settings.backend == CloudBackendType.none) {
        throw const Failure(
          FailureCode.validation,
          '请先选择并配置 WebDAV 或 S3 云存储通道',
        );
      }
      if (settings.backend == CloudBackendType.webdav) {
        final dav = await getWebDavConfig();
        if (!dav.isConfigured) {
          throw const Failure(FailureCode.validation, '请先完成 WebDAV 配置再开启自动同步');
        }
      } else if (settings.backend == CloudBackendType.s3) {
        final s3 = await getS3Config();
        if (!s3.isConfigured) {
          throw const Failure(FailureCode.validation, '请先完成 S3 配置再开启自动同步');
        }
      }
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
        final settings = resolveEffectiveCloudSyncSettings(
          rawJson: rawSyncRow?.value,
          isWebDavConfigured: config.isConfigured,
          fallbackDeviceId: _ensureFallbackDeviceId(),
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
          final settings = resolveEffectiveCloudSyncSettings(
            rawJson: rawSync,
            isWebDavConfigured: false,
            fallbackDeviceId: _ensureFallbackDeviceId(),
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
        final settings = resolveEffectiveCloudSyncSettings(
          rawJson: rawSync,
          isWebDavConfigured: _decodeWebDavConfig(rawDav).isConfigured,
          fallbackDeviceId: _ensureFallbackDeviceId(),
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
          final settings = resolveEffectiveCloudSyncSettings(
            rawJson: rawSync,
            isWebDavConfigured: _decodeWebDavConfig(rawDav).isConfigured,
            fallbackDeviceId: _ensureFallbackDeviceId(),
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
  }

  /// Updates the full vs lightweight no-attachment export toggle (§6.3).
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
        if (currentS3.isConfigured) {
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
        }
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

  /// Builds a [WebDavBackupTarget] for the current [WebDavConfig] (ADR-017).
  Future<WebDavBackupTarget> getWebDavTarget() async {
    final config = await getWebDavConfig();
    return WebDavBackupTarget(
      config,
      httpClientFactory: httpClientFactory,
      nowMs: _nowMs,
    );
  }

  /// Builds an [S3BackupTarget] for the current [S3Config] (ADR-017).
  Future<S3BackupTarget> getS3Target() async {
    final config = await getS3Config();
    return S3BackupTarget(
      config,
      httpClientFactory: httpClientFactory,
      nowMs: _nowMs,
    );
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
  /// ZIP bytes in memory (§2.2, R1, R2, R3, §6.3).
  Future<PackedTallyBackup> createBackupBytes({
    bool? includeAttachments,
  }) async {
    final config = await getWebDavConfig();
    final withAttachments = includeAttachments ?? config.includeAttachments;
    final tables = await guardDatabase(
      () => db.transaction(_exportAll22Tables),
    );
    final attachments = withAttachments
        ? await _collectLocalAttachments()
        : const <String, Uint8List>{};

    return packTallyArchive(
      tables: tables,
      attachments: attachments,
      createdAtMs: _nowMs(),
      appVersion: appVersion,
      includeAttachments: withAttachments,
    );
  }

  /// Generates a `.tally` backup inside the app-managed local backup directory.
  Future<BackupFileMetadata> createLocalBackup({
    bool? includeAttachments,
    String? customFileName,
    BackupProgressCallback? onProgress,
  }) async {
    final packed = await createBackupBytes(
      includeAttachments: includeAttachments,
    );
    final fileName =
        customFileName ??
        formatTallyBackupFileName(
          DateTime.fromMillisecondsSinceEpoch(packed.manifest.createdAtMs),
        );
    final saved = await localTarget.writeBackup(
      fileName,
      packed.bytes,
      onProgress: onProgress,
    );
    await _recordCompletedBackupState(packed.manifest.createdAtMs);
    return saved;
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

  Future<List<BackupFileMetadata>> listLocalBackups() =>
      localTarget.listBackups();

  Future<void> deleteLocalBackup(String fileName) =>
      localTarget.deleteBackup(fileName);

  Future<TallyManifest> restoreLocalBackup(String fileName) async {
    final bytes = await localTarget.readBackup(fileName);
    return restoreFromBytes(bytes);
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
  }) async {
    final config = await getWebDavConfig();
    if (!config.isConfigured) {
      throw const Failure(FailureCode.validation, 'WebDAV 未配置');
    }
    final packed = await createBackupBytes(
      includeAttachments: includeAttachments ?? config.includeAttachments,
    );
    final fileName =
        customFileName ??
        formatTallyBackupFileName(
          DateTime.fromMillisecondsSinceEpoch(packed.manifest.createdAtMs),
        );
    final target = WebDavBackupTarget(
      config,
      httpClientFactory: httpClientFactory,
      nowMs: _nowMs,
    );
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
  }) async {
    final config = await getS3Config();
    if (!config.isConfigured) {
      throw const Failure(FailureCode.validation, 'S3 对象存储未配置');
    }
    final packed = await createBackupBytes(
      includeAttachments: includeAttachments ?? config.includeAttachments,
    );
    final fileName =
        customFileName ??
        formatTallyBackupFileName(
          DateTime.fromMillisecondsSinceEpoch(packed.manifest.createdAtMs),
        );
    final target = S3BackupTarget(
      config,
      httpClientFactory: httpClientFactory,
      nowMs: _nowMs,
    );
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
  }) async {
    final settings = await getCloudSyncSettings();
    return switch (settings.backend) {
      CloudBackendType.s3 => uploadBackupToS3(
        includeAttachments: includeAttachments,
        customFileName: customFileName,
        onProgress: onProgress,
      ),
      CloudBackendType.webdav => uploadBackupToWebDav(
        includeAttachments: includeAttachments,
        customFileName: customFileName,
        onProgress: onProgress,
      ),
      CloudBackendType.none => throw const Failure(
        FailureCode.validation,
        '请先选择并配置云存储通道（WebDAV 或 S3）',
      ),
    };
  }

  /// Downloads a remote `.tally` backup from WebDAV and executes the 3-stage
  /// atomic restore (R5).
  Future<TallyManifest> restoreWebDavBackup(
    String fileName, {
    BackupProgressCallback? onProgress,
  }) async {
    final target = await getWebDavTarget();
    final bytes = await target.readBackup(fileName, onProgress: onProgress);
    return restoreFromBytes(bytes);
  }

  /// Downloads a remote `.tally` backup from S3 and executes the 3-stage
  /// atomic restore (R5).
  Future<TallyManifest> restoreS3Backup(
    String fileName, {
    BackupProgressCallback? onProgress,
  }) async {
    final target = await getS3Target();
    final bytes = await target.readBackup(fileName, onProgress: onProgress);
    return restoreFromBytes(bytes);
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
    final target = await getWebDavTarget();
    await target.deleteBackup(fileName);
  }

  /// Deletes a remote `.tally` backup from S3.
  Future<void> deleteS3Backup(String fileName) async {
    final target = await getS3Target();
    await target.deleteBackup(fileName);
  }

  /// Deletes a historical `.tally` backup from whichever cloud target is active.
  Future<void> deleteActiveCloudBackup(String fileName) async {
    final settings = await getCloudSyncSettings();
    return switch (settings.backend) {
      CloudBackendType.s3 => deleteS3Backup(fileName),
      CloudBackendType.webdav => deleteWebDavBackup(fileName),
      CloudBackendType.none => throw const Failure(
        FailureCode.validation,
        '云存储通道未启用',
      ),
    };
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
  /// throttled, disabled, or unchanged.
  Future<BackupFileMetadata?> runSilentAutoBackupIfNeeded({
    BackupProgressCallback? onProgress,
  }) async {
    final settings = await getCloudSyncSettings();
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
      return uploadBackupToS3(onProgress: onProgress);
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
    return uploadBackupToWebDav(onProgress: onProgress);
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
    return syncNow(onProgress: onProgress);
  }

  /// Executes multi-device snapshot synchronization (`sync/head.json` +
  /// `sync/latest_db.tally` + deduplicated `sync/attachments/*`) with atomic
  /// pull replacement, race-guarded push commits, and zero-data-loss conflict
  /// backup preservation (`R4`, `R5`, `R6`).
  Future<CloudSyncOutcome> syncNow({
    SyncConflictResolution? resolution,
    BackupProgressCallback? onProgress,
    FutureOr<void> Function()? beforePushCommitForTest,
  }) {
    final prev = _syncSerialChain ?? Future<void>.value();
    final completer = Completer<CloudSyncOutcome>();
    _syncSerialChain = prev.catchError((_) {}).then((_) async {
      try {
        final outcome = await _syncNowUnlocked(
          resolution: resolution,
          onProgress: onProgress,
          beforePushCommitForTest: beforePushCommitForTest,
        );
        completer.complete(outcome);
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<CloudSyncOutcome> _syncNowUnlocked({
    SyncConflictResolution? resolution,
    BackupProgressCallback? onProgress,
    FutureOr<void> Function()? beforePushCommitForTest,
  }) async {
    final settings = await getCloudSyncSettings();
    final CloudSyncObjectStore store;
    final BackupTarget cloudBackupTarget;
    final int archiveCooldownMs;

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
        final target = WebDavBackupTarget(
          davCfg,
          httpClientFactory: httpClientFactory,
          nowMs: _nowMs,
        );
        store = target;
        cloudBackupTarget = target;
        archiveCooldownMs = davCfg.autoBackupCooldownMs;
      case CloudBackendType.s3:
        final s3Cfg = await getS3Config();
        if (!s3Cfg.isConfigured) {
          throw const Failure(FailureCode.validation, 'S3 对象存储未配置，无法执行多端同步');
        }
        final target = S3BackupTarget(
          s3Cfg,
          httpClientFactory: httpClientFactory,
          nowMs: _nowMs,
        );
        store = target;
        cloudBackupTarget = target;
        archiveCooldownMs = s3Cfg.autoBackupCooldownMs;
    }

    final localTables = await guardDatabase(
      () => db.transaction(_exportAll22Tables),
    );
    final localAttachments = await _collectLocalAttachments();
    final localAttChecksums = <String, String>{
      for (final entry in localAttachments.entries)
        entry.key: sha256Hex(entry.value),
    };
    final localDataSha256 = computeCanonicalSyncDataSha256(
      tables: localTables,
      attachmentChecksums: localAttChecksums,
    );
    final isLocalFreshEmpty = isFreshSeedSnapshot(
      localTables,
      attachmentCount: localAttachments.length,
    );

    final rawCursor = await getSyncCursor();
    final cursor = rawCursor.scopedToTarget(store.targetFingerprint);
    final remoteHead = await _readRemoteHeadOrNull(store);

    final decision = decideSyncAction(
      cursor: cursor,
      localDataSha256: localDataSha256,
      isLocalFreshEmpty: isLocalFreshEmpty,
      remoteHead: remoteHead,
      resolution: resolution,
    );

    switch (decision.action) {
      case SyncActionType.noOp:
        return CloudSyncOutcome(
          status: CloudSyncStatus.alreadyUpToDate,
          revision: remoteHead!.revision,
          localDataSha256: localDataSha256,
          remoteHead: remoteHead,
        );

      case SyncActionType.fastForwardCursor:
        final updatedCursor = cursor.copyWith(
          lastSyncedRevision: remoteHead!.revision,
          lastSyncedDataSha256: localDataSha256,
          lastSyncedAtMs: _nowMs(),
          targetFingerprint: store.targetFingerprint,
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
        return _executeSyncPull(
          settings: settings,
          store: store,
          remoteHead: remoteHead!,
          localAttachments: localAttachments,
          localAttChecksums: localAttChecksums,
          onProgress: onProgress,
        );

      case SyncActionType.pushLocal:
        return _executeSyncPush(
          settings: settings,
          store: store,
          cloudBackupTarget: cloudBackupTarget,
          cursor: cursor,
          initialRemoteHead: remoteHead,
          localTables: localTables,
          localAttachments: localAttachments,
          localAttChecksums: localAttChecksums,
          localDataSha256: localDataSha256,
          archiveCooldownMs: archiveCooldownMs,
          forceOverwriteRemote: resolution == SyncConflictResolution.useLocal,
          onProgress: onProgress,
          beforePushCommitForTest: beforePushCommitForTest,
        );

      case SyncActionType.conflict:
        return _preserveConflictAndReport(
          settings: settings,
          store: store,
          cloudBackupTarget: cloudBackupTarget,
          cursor: cursor,
          remoteHead: remoteHead!,
          localTables: localTables,
          localAttachments: localAttachments,
          localDataSha256: localDataSha256,
        );
    }
  }

  Future<CloudSyncHead?> _readRemoteHeadOrNull(
    CloudSyncObjectStore store,
  ) async {
    final bytes = await store.getObjectOrNull(cloudSyncHeadPath);
    if (bytes == null) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } catch (_) {
      throw const Failure(FailureCode.corruptData, '远端 sync/head.json 解析失败');
    }
    if (decoded is! Map<String, Object?>) {
      throw const Failure(FailureCode.corruptData, '远端 sync/head.json 格式损坏');
    }
    return CloudSyncHead.fromJson(decoded);
  }

  Future<CloudSyncOutcome> _executeSyncPull({
    required CloudSyncSettings settings,
    required CloudSyncObjectStore store,
    required CloudSyncHead remoteHead,
    required Map<String, Uint8List> localAttachments,
    required Map<String, String> localAttChecksums,
    BackupProgressCallback? onProgress,
  }) async {
    final latestDbBytes = await store.getObject(
      cloudSyncLatestDbPath,
      onProgress: onProgress,
    );
    final verifiedDb = unpackAndVerifyTallyArchive(latestDbBytes);
    final Object? rawDbJson;
    try {
      final zip = ZipArchive.decode(latestDbBytes);
      rawDbJson = jsonDecode(
        utf8.decode(zip[verifiedDb.manifest.databaseFile]!.bytes),
      );
    } catch (_) {
      throw const Failure(FailureCode.corruptData, '远端同步数据库 JSON 损坏');
    }
    if (rawDbJson is! Map<String, Object?>) {
      throw const Failure(FailureCode.corruptData, '远端同步数据库顶层结构损坏');
    }
    final parsedRows = _parseAndValidateAll22Tables(
      rawDbJson,
      verifiedDb.manifest,
    );

    // Build local content-addressed index for deduplicated pull (`R4`).
    final localBytesBySha = <String, Uint8List>{
      for (final entry in localAttChecksums.entries)
        entry.value: localAttachments[entry.key]!,
    };

    final requiredAtts = remoteHead.resolvedAttachments();
    final verifiedPulledAttachments = <String, Uint8List>{};
    final pulledAttChecksums = <String, String>{};
    var downloadedCount = 0;

    for (final desc in requiredAtts) {
      Uint8List bytes;
      final cachedLocal = localBytesBySha[desc.sha256];
      if (cachedLocal != null) {
        bytes = cachedLocal;
      } else {
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
        localBytesBySha[desc.sha256] = bytes;
        downloadedCount++;
      }
      verifiedPulledAttachments[desc.archivePath] = bytes;
      pulledAttChecksums[desc.archivePath] = desc.sha256;
    }

    final pulledCanonicalSha = computeCanonicalSyncDataSha256(
      tables: verifiedDb.tables,
      attachmentChecksums: pulledAttChecksums,
    );
    if (pulledCanonicalSha != remoteHead.dataSha256) {
      throw const Failure(
        FailureCode.remoteUnavailable,
        '远端同步快照正在更新或校验不一致，请稍后重试',
      );
    }

    final stagingDir = await Directory.systemTemp.createTemp(
      'tally_sync_pull_',
    );
    try {
      final stagedAttRoot = Directory(p.join(stagingDir.path, 'attachments'));
      for (final entry in verifiedPulledAttachments.entries) {
        final relUnderAtt = entry.key.substring(tallyAttachmentsPrefix.length);
        final stagedFile = File(
          p.joinAll(<String>[stagedAttRoot.path, ...relUnderAtt.split('/')]),
        );
        await stagedFile.parent.create(recursive: true);
        await stagedFile.writeAsBytes(entry.value, flush: true);
      }

      final now = _nowMs();
      final newCursor = LocalSyncCursor(
        lastSyncedRevision: remoteHead.revision,
        lastSyncedDataSha256: remoteHead.dataSha256,
        lastSyncedAtMs: now,
        targetFingerprint: store.targetFingerprint,
      );

      await guardDatabase(
        () => db.transaction(() async {
          await _clearAll22TablesInTransaction();
          await db.delete(db.writeCommands).go();
          await _insertAll22TablesInTransaction(parsedRows);

          final activeBookId = resolveRestoredActiveBookId(
            parsedRows.accountBooks.map((b) => (id: b.id, sort: b.sort)),
          );
          await db
              .into(db.preferences)
              .insertOnConflictUpdate(
                PreferencesCompanion.insert(
                  key: _prefKeyCurrentBookId,
                  value: '$activeBookId',
                ),
              );
          await db
              .into(db.preferences)
              .insertOnConflictUpdate(
                PreferencesCompanion.insert(
                  key: prefKeyCloudSyncCursor,
                  value: jsonEncode(newCursor.toJson()),
                ),
              );
          await db
              .into(db.preferences)
              .insert(
                PreferencesCompanion.insert(
                  key: prefKeyCloudSyncSettings,
                  value: jsonEncode(settings.toJson()),
                ),
                mode: InsertMode.insertOrIgnore,
              );
        }),
      );

      final targetAttDir = await _attachmentsDirProvider();
      if (await targetAttDir.exists()) {
        await for (final child in targetAttDir.list(followLinks: false)) {
          await child.delete(recursive: true);
        }
      }
      if (verifiedPulledAttachments.isNotEmpty) {
        await targetAttDir.create(recursive: true);
        for (final archivePath in verifiedPulledAttachments.keys) {
          final relUnderAtt = archivePath.substring(
            tallyAttachmentsPrefix.length,
          );
          final srcFile = File(
            p.joinAll(<String>[stagedAttRoot.path, ...relUnderAtt.split('/')]),
          );
          final dstFile = File(
            p.joinAll(<String>[targetAttDir.path, ...relUnderAtt.split('/')]),
          );
          await dstFile.parent.create(recursive: true);
          await srcFile.copy(dstFile.path);
        }
      }

      await reminderService.resyncAll();

      return CloudSyncOutcome(
        status: CloudSyncStatus.pulled,
        revision: remoteHead.revision,
        localDataSha256: remoteHead.dataSha256,
        remoteHead: remoteHead,
        downloadedAttachments: downloadedCount,
      );
    } finally {
      try {
        if (await stagingDir.exists()) {
          await stagingDir.delete(recursive: true);
        }
      } catch (_) {}
    }
  }

  Future<CloudSyncOutcome> _executeSyncPush({
    required CloudSyncSettings settings,
    required CloudSyncObjectStore store,
    required BackupTarget cloudBackupTarget,
    required LocalSyncCursor cursor,
    required CloudSyncHead? initialRemoteHead,
    required Map<String, List<Map<String, Object?>>> localTables,
    required Map<String, Uint8List> localAttachments,
    required Map<String, String> localAttChecksums,
    required String localDataSha256,
    required int archiveCooldownMs,
    required bool forceOverwriteRemote,
    BackupProgressCallback? onProgress,
    FutureOr<void> Function()? beforePushCommitForTest,
  }) async {
    // 1. Deduplicated attachment upload (`sync/attachments/<sha256>__<basename>`).
    final objectBytesMap = <String, Uint8List>{};
    final sortedArchivePaths = localAttachments.keys.toList()..sort();
    for (final archivePath in sortedArchivePaths) {
      final sha = localAttChecksums[archivePath]!;
      final objName = buildAttachmentObjectName(
        sha256: sha,
        archivePath: archivePath,
      );
      objectBytesMap.putIfAbsent(objName, () => localAttachments[archivePath]!);
    }

    var uploadedCount = 0;
    if (objectBytesMap.isNotEmpty) {
      final existingRemote = await store.listRelativeFileNames(
        cloudSyncAttachmentsDir,
      );
      for (final entry in objectBytesMap.entries) {
        if (existingRemote.contains(entry.key)) continue;
        await store.putObject(
          '$cloudSyncAttachmentsDir/${entry.key}',
          entry.value,
        );
        uploadedCount++;
      }
    }

    // 2. Re-read `sync/head.json` right before commit to guard concurrent races!
    if (beforePushCommitForTest != null) {
      await beforePushCommitForTest();
    }
    final freshHead = await _readRemoteHeadOrNull(store);
    if (!forceOverwriteRemote) {
      final raced =
          (initialRemoteHead == null && freshHead != null) ||
          (initialRemoteHead != null &&
              (freshHead == null ||
                  freshHead.revision != initialRemoteHead.revision ||
                  freshHead.dataSha256 != initialRemoteHead.dataSha256));
      if (raced) {
        if (freshHead != null && freshHead.dataSha256 == localDataSha256) {
          final aligned = cursor.copyWith(
            lastSyncedRevision: freshHead.revision,
            lastSyncedDataSha256: localDataSha256,
            lastSyncedAtMs: _nowMs(),
            targetFingerprint: store.targetFingerprint,
            clearConflictRecord: true,
          );
          await _saveSyncCursor(aligned);
          return CloudSyncOutcome(
            status: CloudSyncStatus.alreadyUpToDate,
            revision: freshHead.revision,
            localDataSha256: localDataSha256,
            remoteHead: freshHead,
          );
        }
        if (freshHead != null) {
          return _preserveConflictAndReport(
            settings: settings,
            store: store,
            cloudBackupTarget: cloudBackupTarget,
            cursor: cursor,
            remoteHead: freshHead,
            localTables: localTables,
            localAttachments: localAttachments,
            localDataSha256: localDataSha256,
          );
        }
      }
    }

    // 3. Upload lightweight `sync/latest_db.tally` + updated `sync/head.json`.
    final now = _nowMs();
    final lightweightDb = packTallyArchive(
      tables: localTables,
      createdAtMs: now,
      appVersion: appVersion,
      includeAttachments: false,
    );
    await store.putObject(
      cloudSyncLatestDbPath,
      lightweightDb.bytes,
      onProgress: onProgress,
    );

    final nextRevision = (freshHead?.revision ?? 0) + 1;
    final newHead = CloudSyncHead(
      revision: nextRevision,
      dataSha256: localDataSha256,
      updatedAtMs: now,
      deviceId: settings.deviceId,
      deviceName: settings.deviceName,
      recordCount: (localTables['record'] ?? const <Object?>[]).length,
      attachmentFiles: objectBytesMap.keys.toList()..sort(),
      attachmentManifest: localAttChecksums,
    );
    final headBytes = Uint8List.fromList(
      utf8.encode(const JsonEncoder.withIndent('  ').convert(newHead.toJson())),
    );
    await store.putObject(
      cloudSyncHeadPath,
      headBytes,
      contentType: 'application/json; charset=utf-8',
    );

    final updatedCursor = LocalSyncCursor(
      lastSyncedRevision: nextRevision,
      lastSyncedDataSha256: localDataSha256,
      lastSyncedAtMs: now,
      targetFingerprint: store.targetFingerprint,
    );
    await _saveSyncCursor(updatedCursor, ensureSettings: settings);

    // 4. Optional 24h full versioned `.tally` archive backup & pruning.
    String? archivedName;
    if (settings.autoArchiveBackupEnabled) {
      final lastBackupAt = await getLastBackupAtMs();
      if (lastBackupAt == null || (now - lastBackupAt) >= archiveCooldownMs) {
        final archived = await uploadToActiveCloudBackup();
        archivedName = archived.fileName;
      }
    }

    return CloudSyncOutcome(
      status: CloudSyncStatus.pushed,
      revision: nextRevision,
      localDataSha256: localDataSha256,
      remoteHead: newHead,
      uploadedAttachments: uploadedCount,
      archivedBackupFileName: archivedName,
    );
  }

  Future<CloudSyncOutcome> _preserveConflictAndReport({
    required CloudSyncSettings settings,
    required CloudSyncObjectStore store,
    required BackupTarget cloudBackupTarget,
    required LocalSyncCursor cursor,
    required CloudSyncHead remoteHead,
    required Map<String, List<Map<String, Object?>>> localTables,
    required Map<String, Uint8List> localAttachments,
    required String localDataSha256,
  }) async {
    String? conflictFileName;
    if (cursor.lastConflictSha256 == localDataSha256 &&
        cursor.lastConflictFileName != null &&
        cursor.lastConflictFileName!.isNotEmpty) {
      final localDir = await _localBackupsDirProvider();
      final existing = File(
        p.join(localDir.path, cursor.lastConflictFileName!),
      );
      if (await existing.exists()) {
        conflictFileName = cursor.lastConflictFileName;
      }
    }

    if (conflictFileName == null) {
      final now = _nowMs();
      conflictFileName = formatConflictBackupFileName(
        deviceId: settings.deviceId,
        when: DateTime.fromMillisecondsSinceEpoch(now),
      );
      final fullConflictPack = packTallyArchive(
        tables: localTables,
        attachments: localAttachments,
        createdAtMs: now,
        appVersion: appVersion,
        includeAttachments: true,
      );
      await localTarget.writeBackup(conflictFileName, fullConflictPack.bytes);
      await cloudBackupTarget.writeBackup(
        conflictFileName,
        fullConflictPack.bytes,
      );
      await _saveSyncCursor(
        cursor.copyWith(
          targetFingerprint: store.targetFingerprint,
          lastConflictSha256: localDataSha256,
          lastConflictFileName: conflictFileName,
        ),
      );
    }

    return CloudSyncOutcome.conflict(
      revision: remoteHead.revision,
      localDataSha256: localDataSha256,
      remoteHead: remoteHead,
      conflictBackupFileName: conflictFileName,
    );
  }

  /// Executes the 3-stage safe restore workflow (R5):
  /// 1. Unpacks archive into an isolated temporary `staging/` directory (with
  ///    zip-slip containment check);
  /// 2. Validates `manifest.json`, `database_sha256`, every `attachments/*`
  ///    SHA-256, `table_counts`, and parses/validates all 22 table rows BEFORE
  ///    touching SQLite or local attachments;
  /// 3. Replaces all 22 business tables atomically in a single SQLite
  ///    transaction, resets `current_book_id` to a valid book (`1` if present
  ///    else first book), syncs attachments, and calls
  ///    `ReminderService.resyncAll()`.
  Future<TallyManifest> restoreFromBytes(
    Uint8List archiveBytes, {
    void Function()? beforeTransactionCommitForTest,
  }) async {
    final stagingDir = await Directory.systemTemp.createTemp(
      'tally_restore_staging_',
    );
    try {
      // Stage 1: Extract ZIP entries into isolated staging directory.
      final zip = ZipArchive.decode(archiveBytes);
      final canonicalStagingRoot = await stagingDir.resolveSymbolicLinks();
      for (final entry in zip.entries) {
        final safeRel = validateZipEntryPath(entry.name);
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

      // Stage 2: Static SHA-256 & schema validation on staged files BEFORE touching DB.
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
        throw const Failure(FailureCode.corruptData, '备份包 manifest.json 解析失败');
      }
      if (rawManifest is! Map<String, Object?>) {
        throw const Failure(FailureCode.corruptData, '备份包 manifest.json 结构损坏');
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
      if (sha256Hex(stagedDbBytes) != manifest.databaseSha256) {
        throw const Failure(
          FailureCode.corruptData,
          '备份数据文件哈希校验失败（文件已被篡改或损坏），已拒绝恢复',
        );
      }

      for (final expected in manifest.filesChecksum.entries) {
        final stagedAttPath = p.normalize(
          p.joinAll(<String>[canonicalStagingRoot, ...expected.key.split('/')]),
        );
        final stagedAttFile = File(stagedAttPath);
        if (!await stagedAttFile.exists()) {
          throw Failure(
            FailureCode.corruptData,
            '备份包缺少清单登记的附件文件：${expected.key}',
          );
        }
        final attBytes = await stagedAttFile.readAsBytes();
        if (sha256Hex(attBytes) != expected.value) {
          throw Failure(
            FailureCode.corruptData,
            '备份附件哈希校验失败（${expected.key}），已拒绝恢复',
          );
        }
      }

      final stagedAttachmentsRoot = Directory(
        p.join(canonicalStagingRoot, 'attachments'),
      );
      if (await stagedAttachmentsRoot.exists()) {
        await for (final entity in stagedAttachmentsRoot.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is! File) continue;
          final relPosix = p
              .split(p.relative(entity.path, from: canonicalStagingRoot))
              .join('/');
          if (!manifest.filesChecksum.containsKey(relPosix)) {
            throw Failure(
              FailureCode.corruptData,
              '备份包存在未在清单登记的额外附件（$relPosix），已拒绝恢复',
            );
          }
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

      // Stage 3: Single atomic SQLite transaction replacing all 22 tables.
      await guardDatabase(
        () => db.transaction(() async {
          await _clearAll22TablesInTransaction();
          await db.delete(db.writeCommands).go();
          await _insertAll22TablesInTransaction(parsedRows);

          final activeBookId = resolveRestoredActiveBookId(
            parsedRows.accountBooks.map((b) => (id: b.id, sort: b.sort)),
          );
          await db
              .into(db.preferences)
              .insertOnConflictUpdate(
                PreferencesCompanion.insert(
                  key: _prefKeyCurrentBookId,
                  value: '$activeBookId',
                ),
              );

          beforeTransactionCommitForTest?.call();
        }),
      );

      // Sync verified attachments into app attachments directory after DB commit.
      await _syncStagedAttachments(
        stagedAttachmentsRoot: stagedAttachmentsRoot,
        manifest: manifest,
      );

      await _recordCompletedBackupState(_nowMs());
      await reminderService.resyncAll();

      return manifest;
    } finally {
      try {
        if (await stagingDir.exists()) {
          await stagingDir.delete(recursive: true);
        }
      } catch (_) {}
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

  Future<String> _computeCanonicalStateDigest() async {
    final tables = await guardDatabase(
      () => db.transaction(_exportAll22Tables),
    );
    final attachments = await _collectLocalAttachments();
    final attChecksums = <String, String>{
      for (final entry in attachments.entries)
        entry.key: sha256Hex(entry.value),
    };
    return computeCanonicalSyncDataSha256(
      tables: tables,
      attachmentChecksums: attChecksums,
    );
  }

  Future<Map<String, Uint8List>> _collectLocalAttachments() async {
    final dir = await _attachmentsDirProvider();
    if (!await dir.exists()) return const <String, Uint8List>{};
    final result = <String, Uint8List>{};
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final relSegments = p.split(p.relative(entity.path, from: dir.path));
      if (relSegments.isEmpty) continue;
      if (relSegments.last.toLowerCase().endsWith('.tmp')) continue;
      final archivePath = normalizeAttachmentArchivePath(relSegments.join('/'));
      result[archivePath] = await entity.readAsBytes();
    }
    return result;
  }

  Future<void> _syncStagedAttachments({
    required Directory stagedAttachmentsRoot,
    required TallyManifest manifest,
  }) async {
    final targetDir = await _attachmentsDirProvider();
    if (manifest.includeAttachments) {
      if (await targetDir.exists()) {
        await for (final child in targetDir.list(followLinks: false)) {
          await child.delete(recursive: true);
        }
      } else if (manifest.filesChecksum.isNotEmpty) {
        await targetDir.create(recursive: true);
      }
    }

    if (!await stagedAttachmentsRoot.exists()) return;
    await targetDir.create(recursive: true);
    for (final archivePath in manifest.filesChecksum.keys) {
      final relUnderAttachments = archivePath.substring(
        tallyAttachmentsPrefix.length,
      );
      final srcFile = File(
        p.joinAll(<String>[
          stagedAttachmentsRoot.path,
          ...relUnderAttachments.split('/'),
        ]),
      );
      final dstFile = File(
        p.joinAll(<String>[targetDir.path, ...relUnderAttachments.split('/')]),
      );
      await dstFile.parent.create(recursive: true);
      await srcFile.copy(dstFile.path);
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
    TallyManifest manifest,
  ) {
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
      final expectedCount = manifest.tableCounts[name];
      if (expectedCount != null && rows.length != expectedCount) {
        throw Failure(
          FailureCode.corruptData,
          '备份表 $name 记录数（${rows.length}）与清单（$expectedCount）不一致',
        );
      }
      return rows;
    }

    return _ValidatedDatabaseRows(
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
