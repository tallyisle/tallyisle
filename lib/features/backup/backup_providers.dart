import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/backup/tally_backup_service.dart';
import '../../data/backup/webdav_client.dart';
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

final localBackupsProvider = FutureProvider<List<BackupFileMetadata>>((
  ref,
) async {
  final service = await ref.watch(tallyBackupServiceProvider.future);
  return service.listLocalBackups();
});

final webDavBackupsProvider = FutureProvider<List<BackupFileMetadata>>((
  ref,
) async {
  final config = await ref.watch(webDavConfigProvider.future);
  if (!config.isConfigured) {
    return const <BackupFileMetadata>[];
  }
  final service = await ref.watch(tallyBackupServiceProvider.future);
  return service.listWebDavBackups();
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
