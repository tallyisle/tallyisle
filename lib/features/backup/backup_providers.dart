import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/backup/s3_client.dart';
import '../../data/backup/tally_backup_service.dart';
import '../../data/backup/webdav_client.dart';
import '../../domain/rules/cloud_sync_rules.dart';
import '../../platform/files.dart';
import '../reminder/reminder_providers.dart';

final backupFileAccessProvider = Provider<FileAccess>(
  (ref) => const FileAccess(),
);

final backupLocalDirectoryOverrideProvider =
    Provider<Future<Directory> Function()?>((ref) => null);

final backupAttachmentsDirectoryOverrideProvider =
    Provider<Future<Directory> Function()?>((ref) => null);

final backupHttpClientFactoryProvider = Provider<HttpClient Function()?>(
  (ref) => null,
);

final tallyBackupServiceProvider = FutureProvider<TallyBackupService>((
  ref,
) async {
  final db = await ref.watch(databaseProvider.future);
  final reminderService = await ref.watch(reminderServiceProvider.future);
  final localDirOverride = ref.watch(backupLocalDirectoryOverrideProvider);
  final attDirOverride = ref.watch(backupAttachmentsDirectoryOverrideProvider);
  final httpFactory = ref.watch(backupHttpClientFactoryProvider);
  return TallyBackupService(
    db,
    reminderService: reminderService,
    localBackupsDirectoryProvider: localDirOverride,
    attachmentsDirectoryProvider: attDirOverride,
    httpClientFactory: httpFactory,
  );
});

final webDavConfigProvider = StreamProvider<WebDavConfig>((ref) async* {
  final service = await ref.watch(tallyBackupServiceProvider.future);
  yield* service.watchWebDavConfig();
});

final s3ConfigProvider = StreamProvider<S3Config>((ref) async* {
  final service = await ref.watch(tallyBackupServiceProvider.future);
  yield* service.watchS3Config();
});

final cloudSyncSettingsProvider = StreamProvider<CloudSyncSettings>((
  ref,
) async* {
  final service = await ref.watch(tallyBackupServiceProvider.future);
  yield* service.watchCloudSyncSettings();
});

final cloudSyncCursorProvider = StreamProvider<LocalSyncCursor>((ref) async* {
  final service = await ref.watch(tallyBackupServiceProvider.future);
  yield* service.watchSyncCursor();
});

final localBackupsProvider = FutureProvider<List<BackupFileMetadata>>((
  ref,
) async {
  final service = await ref.watch(tallyBackupServiceProvider.future);
  return service.listLocalBackups();
});

final webDavBackupsProvider =
    FutureProvider.autoDispose<List<BackupFileMetadata>>((ref) async {
      final config = await ref.watch(webDavConfigProvider.future);
      if (!config.isConfigured) {
        return const <BackupFileMetadata>[];
      }
      final service = await ref.watch(tallyBackupServiceProvider.future);
      return service.listWebDavBackups();
    });

final s3BackupsProvider = FutureProvider.autoDispose<List<BackupFileMetadata>>((
  ref,
) async {
  final config = await ref.watch(s3ConfigProvider.future);
  if (!config.isConfigured) {
    return const <BackupFileMetadata>[];
  }
  final service = await ref.watch(tallyBackupServiceProvider.future);
  return service.listS3Backups();
});

/// Lists historical `.tally` backups for whichever cloud backend (`WebDAV` or `S3`)
/// is currently active, performing zero network requests when disabled or unconfigured.
final activeCloudBackupsProvider =
    FutureProvider.autoDispose<List<BackupFileMetadata>>((ref) async {
      final settings = await ref.watch(cloudSyncSettingsProvider.future);
      switch (settings.backend) {
        case CloudBackendType.none:
          return const <BackupFileMetadata>[];
        case CloudBackendType.webdav:
          final dav = await ref.watch(webDavConfigProvider.future);
          if (!dav.isConfigured) return const <BackupFileMetadata>[];
          final service = await ref.watch(tallyBackupServiceProvider.future);
          return service.listWebDavBackups();
        case CloudBackendType.s3:
          final s3 = await ref.watch(s3ConfigProvider.future);
          if (!s3.isConfigured) return const <BackupFileMetadata>[];
          final service = await ref.watch(tallyBackupServiceProvider.future);
          return service.listS3Backups();
      }
    });

final lastBackupAtMsProvider = FutureProvider<int?>((ref) async {
  final service = await ref.watch(tallyBackupServiceProvider.future);
  return service.getLastBackupAtMs();
});

/// Optional silent auto-backup check provider (R7) for app startup / foreground resume.
final silentAutoBackupBootstrapProvider = FutureProvider<BackupFileMetadata?>((
  ref,
) async {
  final service = await ref.watch(tallyBackupServiceProvider.future);
  return service.runSilentAutoBackupIfNeeded();
});

/// Optional silent multi-device cloud sync check provider (`R5`, `R6`).
final silentCloudSyncBootstrapProvider = FutureProvider<CloudSyncOutcome?>((
  ref,
) async {
  final service = await ref.watch(tallyBackupServiceProvider.future);
  return service.runSilentCloudSyncIfNeeded();
});
