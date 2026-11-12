import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/failure.dart';
import '../../data/backup/s3_client.dart';
import '../../data/backup/webdav_client.dart';
import '../../domain/rules/cloud_sync_rules.dart';
import '../../domain/rules/tally_backup.dart';
import '../../platform/files.dart';
import '../common/common.dart';
import '../migration/migration_providers.dart';
import '../reminder/reminder_providers.dart';
import 'backup_providers.dart';
import 's3_config_page.dart';
import 'webdav_config_page.dart';

class BackupPage extends ConsumerStatefulWidget {
  const BackupPage({super.key});

  @override
  ConsumerState<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends ConsumerState<BackupPage>
    with WidgetsBindingObserver {
  bool _busy = false;
  String? _progressLabel;
  int _transferredBytes = 0;
  int _totalBytes = 0;
  CloudSyncOutcome? _pendingConflict;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted && !_busy) {
      unawaited(_checkSilentTasksOnResume());
    }
  }

  Future<void> _checkSilentTasksOnResume() async {
    try {
      final service = await ref.read(tallyBackupServiceProvider.future);
      if (!service.hasAttachedScheduler) {
        final syncOutcome = await service.runCloudAutoSyncForTrigger(
          AutoTriggerSource.windowFocus,
        );
        if (syncOutcome != null && mounted) {
          if (syncOutcome.status == CloudSyncStatus.pulled) {
            _refreshAfterRestore();
          } else if (syncOutcome.isConflict) {
            setState(() => _pendingConflict = syncOutcome);
            _refreshAfterBackupChange();
          } else {
            _refreshAfterBackupChange();
          }
        }
        final localSaved = await service.runLocalAutoBackupForTrigger(
          AutoTriggerSource.windowFocus,
        );
        if (localSaved != null && mounted) {
          _refreshAfterBackupChange();
        }
      }
      final uploaded = await service.runSilentAutoBackupIfNeeded();
      if (uploaded != null && mounted) {
        _refreshAfterBackupChange();
      }
    } catch (_) {
      // Silent background check never interrupts foreground workflow.
    }
  }

  void _refreshAfterBackupChange() {
    ref
      ..invalidate(localBackupsProvider)
      ..invalidate(webDavBackupsProvider)
      ..invalidate(s3BackupsProvider)
      ..invalidate(activeCloudBackupsProvider)
      ..invalidate(cloudSyncCursorProvider)
      ..invalidate(lastBackupAtMsProvider);
  }

  void _refreshAfterRestore() {
    _refreshAfterBackupChange();
    ref.read(periodOffsetProvider.notifier).reset();
    ref.read(calendarMonthOffsetProvider.notifier).reset();
    ref
      ..invalidate(currentBookIdProvider)
      ..invalidate(booksProvider)
      ..invalidate(assetsProvider)
      ..invalidate(assetBooksProvider)
      ..invalidate(currenciesProvider)
      ..invalidate(tagsProvider)
      ..invalidate(remindersProvider)
      ..invalidate(reminderCountProvider)
      ..invalidate(migrationLocalSummaryProvider);
  }

  void _showMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _toggleIncludeAttachments(bool value) async {
    try {
      final service = await ref.read(tallyBackupServiceProvider.future);
      await service.setIncludeAttachments(value);
      ref
        ..invalidate(webDavConfigProvider)
        ..invalidate(s3ConfigProvider);
    } catch (e) {
      _showMessage(safeMessage(e));
    }
  }

  Future<void> _selectCloudBackend(CloudBackendType backend) async {
    try {
      final service = await ref.read(tallyBackupServiceProvider.future);
      await service.setCloudBackend(backend);
      setState(() => _pendingConflict = null);
      ref
        ..invalidate(cloudSyncSettingsProvider)
        ..invalidate(activeCloudBackupsProvider)
        ..invalidate(cloudSyncCursorProvider);
    } catch (e) {
      _showMessage(safeMessage(e));
    }
  }

  Future<void> _toggleAutoSync(bool value) async {
    try {
      final service = await ref.read(tallyBackupServiceProvider.future);
      await service.setAutoSyncEnabled(value);
      ref.invalidate(cloudSyncSettingsProvider);
    } catch (e) {
      _showMessage(safeMessage(e));
    }
  }

  Future<void> _updateCloudSyncTriggers({
    bool? syncOnStartup,
    bool? syncOnExit,
    bool? syncOnIdle,
    int? idleMinutes,
    bool? syncOnSchedule,
    int? scheduleIntervalMinutes,
  }) async {
    try {
      final service = await ref.read(tallyBackupServiceProvider.future);
      await service.updateCloudSyncTriggers(
        syncOnStartup: syncOnStartup,
        syncOnExit: syncOnExit,
        syncOnIdle: syncOnIdle,
        idleMinutes: idleMinutes,
        syncOnSchedule: syncOnSchedule,
        scheduleIntervalMinutes: scheduleIntervalMinutes,
      );
      ref.invalidate(cloudSyncSettingsProvider);
    } catch (e) {
      _showMessage(safeMessage(e));
    }
  }

  Future<void> _updateLocalAutoBackupPolicy(
    LocalAutoBackupPolicy nextPolicy,
  ) async {
    try {
      final service = await ref.read(tallyBackupServiceProvider.future);
      await service.saveLocalAutoBackupPolicy(nextPolicy);
      ref.invalidate(localAutoBackupPolicyProvider);
    } catch (e) {
      _showMessage(safeMessage(e));
    }
  }

  Future<void> _toggleAutoBackup(bool value) async {
    try {
      final service = await ref.read(tallyBackupServiceProvider.future);
      await service.setAutoBackupEnabled(value);
      ref
        ..invalidate(webDavConfigProvider)
        ..invalidate(s3ConfigProvider);
    } catch (e) {
      _showMessage(safeMessage(e));
    }
  }

  Future<void> _openWebDavConfig(WebDavConfig current) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => WebDavConfigPage(initialConfig: current),
      ),
    );
    if (changed == true && mounted) {
      _refreshAfterBackupChange();
      ref.invalidate(cloudSyncSettingsProvider);
      _showMessage('WebDAV 配置已更新');
    }
  }

  Future<void> _openS3Config(S3Config current) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => S3ConfigPage(initialConfig: current),
      ),
    );
    if (changed == true && mounted) {
      _refreshAfterBackupChange();
      ref.invalidate(cloudSyncSettingsProvider);
      _showMessage('S3 对象存储配置已更新');
    }
  }

  Future<void> _handleSyncNow({SyncConflictResolution? resolution}) async {
    setState(() {
      _busy = true;
      _progressLabel = switch (resolution) {
        SyncConflictResolution.useRemote => '正在拉取云端版本解决冲突…',
        SyncConflictResolution.useLocal => '正在以本机版本覆盖推送…',
        null => '正在执行多端云同步…',
      };
      _transferredBytes = 0;
      _totalBytes = 0;
    });
    CloudSyncOutcome? conflictToPrompt;
    try {
      final service = await ref.read(tallyBackupServiceProvider.future);
      final outcome = await service.syncNow(
        resolution: resolution,
        onProgress: (transferred, total) {
          if (!mounted) return;
          setState(() {
            _transferredBytes = transferred;
            _totalBytes = total;
          });
        },
      );
      if (!mounted) return;
      switch (outcome.status) {
        case CloudSyncStatus.alreadyUpToDate:
          setState(() => _pendingConflict = null);
          _refreshAfterBackupChange();
          _showMessage('多端数据已是最新（版本 r${outcome.revision}）');
        case CloudSyncStatus.pushed:
          setState(() => _pendingConflict = null);
          _refreshAfterBackupChange();
          _showMessage('已推送最新快照至云端（版本 r${outcome.revision}）');
        case CloudSyncStatus.pulled:
          setState(() => _pendingConflict = null);
          _refreshAfterRestore();
          _showMessage('已从云端同步最新数据（版本 r${outcome.revision}）');
        case CloudSyncStatus.conflict:
          setState(() => _pendingConflict = outcome);
          _refreshAfterBackupChange();
          conflictToPrompt = outcome;
      }
    } catch (e) {
      _showMessage(safeMessage(e));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progressLabel = null;
        });
      }
    }

    if (conflictToPrompt != null && mounted) {
      await _showConflictResolutionDialog(conflictToPrompt);
    }
  }

  Future<void> _showConflictResolutionDialog(CloudSyncOutcome conflict) async {
    final head = conflict.remoteHead;
    final remoteDesc = head == null
        ? '云端新版本'
        : '设备「${head.deviceName}」于 ${formatDateTime(DateTime.fromMillisecondsSinceEpoch(head.updatedAtMs))} 推送的版本 r${head.revision}（账单 ${head.recordCount} 条）';
    final backupName = conflict.conflictBackupFileName ?? 'conflict_*.tally';

    final choice = await showDialog<SyncConflictResolution?>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('cloud_sync_conflict_dialog'),
        title: const Text('检测到多端同步冲突'),
        content: Text(
          '本机与云端自上次同步后均产生了新的账务改动。\n\n'
          '• 云端状态：$remoteDesc\n'
          '• 零丢数保护：已自动将本机当前完整数据（含附件）归档保存为「$backupName」，同时留存于本机与云端备份列表。\n\n'
          '请选择如何处理当前同步冲突：',
        ),
        actions: [
          TextButton(
            key: const Key('conflict_resolve_later_button'),
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('稍后处理'),
          ),
          OutlinedButton(
            key: const Key('conflict_use_remote_button'),
            onPressed: () =>
                Navigator.of(ctx).pop(SyncConflictResolution.useRemote),
            child: const Text('采用云端版本'),
          ),
          FilledButton(
            key: const Key('conflict_use_local_button'),
            onPressed: () =>
                Navigator.of(ctx).pop(SyncConflictResolution.useLocal),
            child: const Text('以本机覆盖云端'),
          ),
        ],
      ),
    );

    if (choice != null && mounted) {
      await _handleSyncNow(resolution: choice);
    }
  }

  Future<void> _handleCreateLocalBackup() async {
    setState(() {
      _busy = true;
      _progressLabel = '正在打包本地备份…';
      _transferredBytes = 0;
      _totalBytes = 0;
    });
    try {
      final service = await ref.read(tallyBackupServiceProvider.future);
      final saved = await service.createLocalBackup();
      _refreshAfterBackupChange();
      _showMessage('已生成本地备份：${saved.fileName}');
    } catch (e) {
      _showMessage(safeMessage(e));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progressLabel = null;
        });
      }
    }
  }

  Future<void> _handleExportSaveAs() async {
    setState(() {
      _busy = true;
      _progressLabel = '正在导出备份文件…';
      _transferredBytes = 0;
      _totalBytes = 0;
    });
    try {
      final service = await ref.read(tallyBackupServiceProvider.future);
      final fileAccess = ref.read(backupFileAccessProvider);
      final name = await service.exportBackupToSaveLocation(
        fileAccess: fileAccess,
      );
      _refreshAfterBackupChange();
      _showMessage('已保存备份文件：$name');
    } on Failure catch (e) {
      if (e.code != FailureCode.cancelled) {
        _showMessage(e.message);
      }
    } catch (e) {
      _showMessage(safeMessage(e));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progressLabel = null;
        });
      }
    }
  }

  Future<void> _handleShareBackup() async {
    setState(() {
      _busy = true;
      _progressLabel = '正在准备系统分享…';
      _transferredBytes = 0;
      _totalBytes = 0;
    });
    try {
      final service = await ref.read(tallyBackupServiceProvider.future);
      final fileAccess = ref.read(backupFileAccessProvider);
      await service.shareBackup(fileAccess: fileAccess);
    } on Failure catch (e) {
      if (e.code != FailureCode.cancelled) {
        _showMessage(e.message);
      }
    } catch (e) {
      _showMessage(safeMessage(e));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progressLabel = null;
        });
      }
    }
  }

  Future<void> _handleImportAndRestore() async {
    final fileAccess = ref.read(backupFileAccessProvider);
    final SelectedBytes selected;
    try {
      selected = await fileAccess.pickBytes(
        allowedExtensions: const <String>['tally', 'tallyzip', 'zip'],
      );
    } on Failure catch (e) {
      if (e.code != FailureCode.cancelled) {
        _showMessage(e.message);
      }
      return;
    } catch (e) {
      _showMessage(safeMessage(e));
      return;
    }

    if (!mounted) return;
    final ok = await confirm(
      context,
      title: '确认从文件恢复？',
      message: '将先校验「${selected.name}」完整性，校验通过后覆盖当前全部 22 张业务数据表。',
      ok: '确认恢复',
    );
    if (!ok || !mounted) return;

    setState(() {
      _busy = true;
      _progressLabel = '正在校验并恢复备份…';
      _transferredBytes = 0;
      _totalBytes = 0;
    });
    try {
      final service = await ref.read(tallyBackupServiceProvider.future);
      final manifest = await service.restoreFromBytes(selected.bytes);
      _refreshAfterRestore();
      _showMessage('恢复完成：共导入 ${manifest.totalRows} 条数据');
    } catch (e) {
      _showMessage(safeMessage(e));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progressLabel = null;
        });
      }
    }
  }

  Future<void> _handleRestoreLocalItem(BackupFileMetadata item) async {
    final ok = await confirm(
      context,
      title: '确认恢复此本地备份？',
      message: '将校验「${item.fileName}」完整性并覆盖当前全部账务、便签与配置数据。',
      ok: '确认恢复',
    );
    if (!ok || !mounted) return;

    setState(() {
      _busy = true;
      _progressLabel = '正在恢复本地备份…';
      _transferredBytes = 0;
      _totalBytes = 0;
    });
    try {
      final service = await ref.read(tallyBackupServiceProvider.future);
      final manifest = await service.restoreLocalBackup(item.fileName);
      _refreshAfterRestore();
      _showMessage('恢复完成：共导入 ${manifest.totalRows} 条数据');
    } catch (e) {
      _showMessage(safeMessage(e));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progressLabel = null;
        });
      }
    }
  }

  Future<void> _handleDeleteLocalItem(BackupFileMetadata item) async {
    final ok = await confirm(
      context,
      title: '删除本地备份？',
      message: '确认删除本地备份文件「${item.fileName}」？',
      ok: '删除',
    );
    if (!ok || !mounted) return;

    try {
      final service = await ref.read(tallyBackupServiceProvider.future);
      await service.deleteLocalBackup(item.fileName);
      ref.invalidate(localBackupsProvider);
      _showMessage('已删除本地备份：${item.fileName}');
    } catch (e) {
      _showMessage(safeMessage(e));
    }
  }

  Future<void> _handleCloudBackupUpload(CloudBackendType activeBackend) async {
    setState(() {
      _busy = true;
      _progressLabel = activeBackend == CloudBackendType.s3
          ? '正在上传至 S3 对象存储…'
          : '正在上传至 WebDAV…';
      _transferredBytes = 0;
      _totalBytes = 0;
    });
    try {
      final service = await ref.read(tallyBackupServiceProvider.future);
      final uploaded = await service.uploadToActiveCloudBackup(
        onProgress: (sent, total) {
          if (!mounted) return;
          setState(() {
            _transferredBytes = sent;
            _totalBytes = total;
          });
        },
      );
      _refreshAfterBackupChange();
      _showMessage('已上传云端备份：${uploaded.fileName}');
    } catch (e) {
      _showMessage(safeMessage(e));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progressLabel = null;
        });
      }
    }
  }

  Future<void> _handleRestoreCloudItem(
    BackupFileMetadata item,
    CloudBackendType activeBackend,
  ) async {
    final backendTitle = activeBackend == CloudBackendType.s3 ? 'S3' : 'WebDAV';
    final ok = await confirm(
      context,
      title: '确认从 $backendTitle 恢复？',
      message: '将下载「${item.fileName}」至隔离暂存区完成哈希校验，再原子替换当前数据。',
      ok: '确认恢复',
    );
    if (!ok || !mounted) return;

    setState(() {
      _busy = true;
      _progressLabel = '正在下载并校验远端备份…';
      _transferredBytes = 0;
      _totalBytes = item.sizeBytes;
    });
    try {
      final service = await ref.read(tallyBackupServiceProvider.future);
      final manifest = await service.restoreActiveCloudBackup(
        item.fileName,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _transferredBytes = received;
            _totalBytes = total;
          });
        },
      );
      _refreshAfterRestore();
      _showMessage('云端恢复完成：共导入 ${manifest.totalRows} 条数据');
    } catch (e) {
      _showMessage(safeMessage(e));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progressLabel = null;
        });
      }
    }
  }

  Future<void> _handleDeleteCloudItem(
    BackupFileMetadata item,
    CloudBackendType activeBackend,
  ) async {
    final backendLabel = activeBackend == CloudBackendType.s3
        ? 'S3 对象存储'
        : 'WebDAV 服务器';
    final ok = await confirm(
      context,
      title: '删除远端备份？',
      message: '确认从$backendLabel删除「${item.fileName}」？',
      ok: '删除',
    );
    if (!ok || !mounted) return;

    setState(() {
      _busy = true;
      _progressLabel = '正在删除远端备份…';
      _transferredBytes = 0;
      _totalBytes = 0;
    });
    try {
      final service = await ref.read(tallyBackupServiceProvider.future);
      await service.deleteActiveCloudBackup(item.fileName);
      _refreshAfterBackupChange();
      _showMessage('已删除远端备份：${item.fileName}');
    } catch (e) {
      _showMessage(safeMessage(e));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progressLabel = null;
        });
      }
    }
  }

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      final tenths = (bytes * 10) ~/ 1024;
      return '${tenths ~/ 10}.${tenths % 10} KB';
    }
    final tenths = (bytes * 10) ~/ (1024 * 1024);
    return '${tenths ~/ 10}.${tenths % 10} MB';
  }

  static String _formatManifestSummary(TallyManifest? m) {
    if (m == null) return '';
    final attSuffix = m.attachmentCount > 0 ? ' · 附件 ${m.attachmentCount}' : '';
    return '共 ${m.totalRows} 条 · 账单 ${m.recordCount} · 便签 ${m.noteCount} · 币种 ${m.currencyCount}$attSuffix';
  }

  static String _formatIntervalMinutes(int minutes) {
    if (minutes >= 60 && minutes % 60 == 0) {
      return '${minutes ~/ 60} 小时';
    }
    return '$minutes 分钟';
  }

  static String _buildSyncStatusSummary({
    required CloudSyncSettings settings,
    required LocalSyncCursor cursor,
    required bool isActiveReady,
  }) {
    if (settings.backend == CloudBackendType.none) {
      return '当前多端同步未启用；可选择 WebDAV 或 S3 对象存储实现跨设备快照同步。';
    }
    if (!isActiveReady) {
      return '已选择 ${settings.backend.displayLabel} 通道，请先完成连接参数配置。';
    }
    if (cursor.isNeverSynced || cursor.lastSyncedAtMs == null) {
      return '当前通道：${settings.backend.displayLabel}（就绪）· 尚未执行过多端同步';
    }
    final syncTime = formatDateTime(
      DateTime.fromMillisecondsSinceEpoch(cursor.lastSyncedAtMs!),
    );
    return '当前通道：${settings.backend.displayLabel} · 已同步版本 r${cursor.lastSyncedRevision} · $syncTime';
  }

  @override
  Widget build(BuildContext context) {
    final davConfigAsync = ref.watch(webDavConfigProvider);
    final s3ConfigAsync = ref.watch(s3ConfigProvider);
    final syncSettingsAsync = ref.watch(cloudSyncSettingsProvider);
    final localPolicyAsync = ref.watch(localAutoBackupPolicyProvider);
    final syncCursorAsync = ref.watch(cloudSyncCursorProvider);
    final localListAsync = ref.watch(localBackupsProvider);
    final lastBackupAsync = ref.watch(lastBackupAtMsProvider);
    final fileAccess = ref.watch(backupFileAccessProvider);

    final davConfig = davConfigAsync.maybeWhen(
      data: (c) => c,
      orElse: WebDavConfig.unconfigured,
    );
    final s3Config = s3ConfigAsync.maybeWhen(
      data: (c) => c,
      orElse: S3Config.unconfigured,
    );
    final syncSettings = syncSettingsAsync.maybeWhen(
      data: (s) => s,
      orElse: () => CloudSyncSettings(
        backend: davConfig.isConfigured
            ? CloudBackendType.webdav
            : CloudBackendType.none,
        deviceId: 'pending',
      ),
    );
    final localPolicy = localPolicyAsync.maybeWhen(
      data: (p) => p,
      orElse: () => LocalAutoBackupPolicy.defaults,
    );
    final syncCursor = syncCursorAsync.maybeWhen(
      data: (c) => c,
      orElse: LocalSyncCursor.initial,
    );

    final cloudIdleOptions = <int>{
      ...autoIdleMinutesChoices,
      syncSettings.idleMinutes,
    }.toList()..sort();
    final cloudScheduleOptions = <int>{
      ...cloudScheduleIntervalMinutesChoices,
      syncSettings.scheduleIntervalMinutes,
    }.toList()..sort();
    final localKeepOptions = <int>{
      ...localBackupKeepCountChoices,
      localPolicy.keepCount,
    }.toList()..sort();
    final localIdleOptions = <int>{
      ...autoIdleMinutesChoices,
      localPolicy.idleMinutes,
    }.toList()..sort();
    final localScheduleOptions = <int>{
      ...localScheduleIntervalMinutesChoices,
      localPolicy.scheduleIntervalMinutes,
    }.toList()..sort();

    final activeBackend = syncSettings.backend;
    final isActiveCloudReady = switch (activeBackend) {
      CloudBackendType.webdav => davConfig.isConfigured,
      CloudBackendType.s3 => s3Config.isConfigured,
      CloudBackendType.none => false,
    };
    final AsyncValue<List<BackupFileMetadata>> remoteListAsync =
        isActiveCloudReady
        ? ref.watch(activeCloudBackupsProvider)
        : const AsyncValue.data(<BackupFileMetadata>[]);
    final activeBadgeText = switch (activeBackend) {
      CloudBackendType.webdav => davConfig.capability.reason,
      CloudBackendType.s3 => s3Config.capability.reason,
      CloudBackendType.none =>
        (davConfig.isConfigured || s3Config.isConfigured) ? '已停用' : '未配置',
    };
    final activeAutoBackupEnabled = switch (activeBackend) {
      CloudBackendType.s3 => s3Config.autoBackupEnabled,
      CloudBackendType.webdav => davConfig.autoBackupEnabled,
      CloudBackendType.none => false,
    };
    final activeCloudSubtitle = switch (activeBackend) {
      CloudBackendType.webdav when davConfig.isConfigured =>
        '${davConfig.serverUrl} · 目录 ${davConfig.remoteDirectory} · 保留最近 ${davConfig.keepCount} 份',
      CloudBackendType.s3 when s3Config.isConfigured =>
        '${s3Config.endpoint} · Bucket ${s3Config.bucket}/${s3Config.normalizedPrefix} · 保留最近 ${s3Config.keepCount} 份',
      _ =>
        '支持 WebDAV（坚果云 / Nextcloud）或 S3 对象存储（R2 / OSS / COS / MinIO）保留多版本历史备份。',
    };

    final lastBackupText = lastBackupAsync.maybeWhen(
      data: (ms) => ms == null
          ? '尚未执行过备份'
          : '上次备份：${formatDateTime(DateTime.fromMillisecondsSinceEpoch(ms))}',
      orElse: () => '正在读取备份状态…',
    );

    final canSaveExternal =
        fileAccess.saveLocationCapability.state == CapabilityState.available;
    final canShareExternal =
        fileAccess.shareCapability.state == CapabilityState.available;

    return Scaffold(
      key: const Key('backup_page'),
      appBar: AppBar(title: const Text('云同步与备份')),
      body: Column(
        children: [
          if (_busy)
            Material(
              key: const Key('webdav_transfer_progress'),
              elevation: 1,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_progressLabel ?? '正在处理…'),
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      value: _totalBytes > 0
                          ? _transferredBytes / _totalBytes
                          : null,
                    ),
                    if (_totalBytes > 0) ...[
                      const SizedBox(height: 4),
                      Text(
                        '${_formatSize(_transferredBytes)} / ${_formatSize(_totalBytes)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Card(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.shield_outlined),
                          title: const Text('备份导出模式'),
                          subtitle: Text(lastBackupText),
                        ),
                        SwitchListTile(
                          key: const Key('include_attachments_switch'),
                          dense: true,
                          title: const Text('完整备份（包含账单图片附件）'),
                          subtitle: Text(
                            davConfig.includeAttachments
                                ? '打包全部 22 张业务表及原图附件并写入 SHA-256 校验清单'
                                : '纯数据轻量备份（仅打包 22 张业务表，不含图片附件）',
                          ),
                          value: davConfig.includeAttachments,
                          onChanged: _busy ? null : _toggleIncludeAttachments,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Card(
                    key: const Key('cloud_sync_card'),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '多端云同步（WebDAV / S3）',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          SegmentedButton<CloudBackendType>(
                            key: const Key('cloud_backend_selector'),
                            showSelectedIcon: false,
                            segments: const <ButtonSegment<CloudBackendType>>[
                              ButtonSegment<CloudBackendType>(
                                value: CloudBackendType.none,
                                label: Text('未启用'),
                              ),
                              ButtonSegment<CloudBackendType>(
                                value: CloudBackendType.webdav,
                                label: Text('WebDAV'),
                              ),
                              ButtonSegment<CloudBackendType>(
                                value: CloudBackendType.s3,
                                label: Text('S3 对象存储'),
                              ),
                            ],
                            selected: <CloudBackendType>{activeBackend},
                            onSelectionChanged: _busy
                                ? null
                                : (selected) =>
                                      _selectCloudBackend(selected.first),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _buildSyncStatusSummary(
                              settings: syncSettings,
                              cursor: syncCursor,
                              isActiveReady: isActiveCloudReady,
                            ),
                            key: const Key('cloud_sync_status_summary'),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              OutlinedButton.icon(
                                key: const Key('open_webdav_config_button'),
                                onPressed: _busy
                                    ? null
                                    : () => _openWebDavConfig(davConfig),
                                icon: const Icon(Icons.settings_outlined),
                                label: Text(
                                  davConfig.isConfigured
                                      ? 'WebDAV 配置'
                                      : '配置 WebDAV',
                                ),
                              ),
                              OutlinedButton.icon(
                                key: const Key('open_s3_config_button'),
                                onPressed: _busy
                                    ? null
                                    : () => _openS3Config(s3Config),
                                icon: const Icon(Icons.cloud_outlined),
                                label: Text(
                                  s3Config.isConfigured ? 'S3 配置' : '配置 S3',
                                ),
                              ),
                              FilledButton.icon(
                                key: const Key('cloud_sync_now_button'),
                                onPressed: !_busy && isActiveCloudReady
                                    ? _handleSyncNow
                                    : null,
                                icon: const Icon(Icons.sync),
                                label: const Text('立即多端同步'),
                              ),
                            ],
                          ),
                          const Divider(height: 20),
                          SwitchListTile(
                            key: const Key('auto_cloud_sync_switch'),
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: const Text('自动多端同步策略'),
                            subtitle: const Text('按需独立开启各自动同步时机（默认全部关闭，零静默联网）'),
                            value: syncSettings.autoSyncEnabled,
                            onChanged: !_busy && isActiveCloudReady
                                ? _toggleAutoSync
                                : null,
                          ),
                          SwitchListTile(
                            key: const Key('cloud_sync_trigger_startup'),
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: const Text('启动 / 窗口激活时自动同步'),
                            subtitle: const Text('桌面获焦或回到前台时自动拉取或推送，预防多端陈旧冲突'),
                            value: syncSettings.syncOnStartup,
                            onChanged: !_busy && isActiveCloudReady
                                ? (v) =>
                                      _updateCloudSyncTriggers(syncOnStartup: v)
                                : null,
                          ),
                          SwitchListTile(
                            key: const Key('cloud_sync_trigger_exit'),
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: const Text('退出 / 切入后台时自动同步'),
                            subtitle: const Text(
                              '切入后台或桌面关窗时自动同步（含 5 秒超时保护，离线绝不卡死）',
                            ),
                            value: syncSettings.syncOnExit,
                            onChanged: !_busy && isActiveCloudReady
                                ? (v) => _updateCloudSyncTriggers(syncOnExit: v)
                                : null,
                          ),
                          SwitchListTile(
                            key: const Key('cloud_sync_trigger_idle'),
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: const Text('记账变更静置后自动同步'),
                            subtitle: const Text('连续记账结束后静置指定时长合并推送一次'),
                            value: syncSettings.syncOnIdle,
                            onChanged: !_busy && isActiveCloudReady
                                ? (v) => _updateCloudSyncTriggers(syncOnIdle: v)
                                : null,
                          ),
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: InputDecorator(
                              decoration: const InputDecoration(
                                labelText: '记账静置同步等待时长',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<int>(
                                  key: const Key(
                                    'cloud_sync_idle_minutes_selector',
                                  ),
                                  isExpanded: true,
                                  isDense: true,
                                  value: syncSettings.idleMinutes,
                                  items: [
                                    for (final m in cloudIdleOptions)
                                      DropdownMenuItem<int>(
                                        value: m,
                                        child: Text('$m 分钟'),
                                      ),
                                  ],
                                  onChanged: _busy
                                      ? null
                                      : (val) {
                                          if (val != null) {
                                            _updateCloudSyncTriggers(
                                              idleMinutes: val,
                                            );
                                          }
                                        },
                                ),
                              ),
                            ),
                          ),
                          SwitchListTile(
                            key: const Key('cloud_sync_trigger_schedule'),
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: const Text('定时周期自动同步'),
                            subtitle: const Text('应用运行期间按固定间隔自动检查同步'),
                            value: syncSettings.syncOnSchedule,
                            onChanged: !_busy && isActiveCloudReady
                                ? (v) => _updateCloudSyncTriggers(
                                    syncOnSchedule: v,
                                  )
                                : null,
                          ),
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: InputDecorator(
                              decoration: const InputDecoration(
                                labelText: '定时自动同步周期',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<int>(
                                  key: const Key(
                                    'cloud_sync_schedule_interval_selector',
                                  ),
                                  isExpanded: true,
                                  isDense: true,
                                  value: syncSettings.scheduleIntervalMinutes,
                                  items: [
                                    for (final m in cloudScheduleOptions)
                                      DropdownMenuItem<int>(
                                        value: m,
                                        child: Text(_formatIntervalMinutes(m)),
                                      ),
                                  ],
                                  onChanged: _busy
                                      ? null
                                      : (val) {
                                          if (val != null) {
                                            _updateCloudSyncTriggers(
                                              scheduleIntervalMinutes: val,
                                            );
                                          }
                                        },
                                ),
                              ),
                            ),
                          ),
                          if (_pendingConflict != null) ...[
                            const SizedBox(height: 8),
                            Container(
                              key: const Key('cloud_sync_conflict_banner'),
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: Theme.of(
                                  context,
                                ).colorScheme.errorContainer,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      '检测到同步冲突，本机快照已保护存为 ${_pendingConflict!.conflictBackupFileName ?? ''}',
                                      style: TextStyle(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onErrorContainer,
                                      ),
                                    ),
                                  ),
                                  TextButton(
                                    key: const Key(
                                      'reopen_conflict_dialog_button',
                                    ),
                                    onPressed: _busy
                                        ? null
                                        : () => _showConflictResolutionDialog(
                                            _pendingConflict!,
                                          ),
                                    child: const Text('处理冲突'),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '本地备份（.tally）',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '离线单机可用，采用开放标准 ZIP 容器与三阶段原子校验恢复。',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              FilledButton.icon(
                                key: const Key('local_backup_create_button'),
                                onPressed: _busy
                                    ? null
                                    : _handleCreateLocalBackup,
                                icon: const Icon(Icons.archive_outlined),
                                label: const Text('生成本地备份'),
                              ),
                              OutlinedButton.icon(
                                key: const Key('local_backup_export_button'),
                                onPressed: !_busy && canSaveExternal
                                    ? _handleExportSaveAs
                                    : null,
                                icon: const Icon(Icons.save_alt),
                                label: const Text('另存为文件'),
                              ),
                              OutlinedButton.icon(
                                key: const Key('local_backup_share_button'),
                                onPressed: !_busy && canShareExternal
                                    ? _handleShareBackup
                                    : null,
                                icon: const Icon(Icons.share_outlined),
                                label: const Text('系统分享'),
                              ),
                              OutlinedButton.icon(
                                key: const Key('local_backup_import_button'),
                                onPressed: _busy
                                    ? null
                                    : _handleImportAndRestore,
                                icon: const Icon(Icons.folder_open_outlined),
                                label: const Text('从文件恢复'),
                              ),
                            ],
                          ),
                          const Divider(height: 24),
                          Text(
                            '本地自动备份策略',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 8),
                          InputDecorator(
                            decoration: const InputDecoration(
                              labelText: '本地备份保留份数',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<int>(
                                key: const Key(
                                  'local_backup_keep_count_selector',
                                ),
                                isExpanded: true,
                                isDense: true,
                                value: localPolicy.keepCount,
                                items: [
                                  for (final n in localKeepOptions)
                                    DropdownMenuItem<int>(
                                      value: n,
                                      child: Text('$n 份'),
                                    ),
                                ],
                                onChanged: _busy
                                    ? null
                                    : (val) {
                                        if (val != null) {
                                          _updateLocalAutoBackupPolicy(
                                            localPolicy.copyWith(
                                              keepCount: val,
                                            ),
                                          );
                                        }
                                      },
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          SwitchListTile(
                            key: const Key('local_backup_trigger_startup'),
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: const Text('启动 App 时自动备份'),
                            subtitle: const Text('仅在本地账务数据有变更时生成新快照'),
                            value: localPolicy.backupOnStartup,
                            onChanged: _busy
                                ? null
                                : (v) => _updateLocalAutoBackupPolicy(
                                    localPolicy.copyWith(backupOnStartup: v),
                                  ),
                          ),
                          SwitchListTile(
                            key: const Key('local_backup_trigger_exit'),
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: const Text('退出 / 切入后台时自动备份'),
                            subtitle: const Text('切入后台或关闭桌面窗口时保存变更快照'),
                            value: localPolicy.backupOnExit,
                            onChanged: _busy
                                ? null
                                : (v) => _updateLocalAutoBackupPolicy(
                                    localPolicy.copyWith(backupOnExit: v),
                                  ),
                          ),
                          SwitchListTile(
                            key: const Key('local_backup_trigger_idle'),
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: const Text('记账变更静置后自动备份'),
                            subtitle: const Text('连续记账结束后静置指定分钟数自动打包备份'),
                            value: localPolicy.backupOnIdle,
                            onChanged: _busy
                                ? null
                                : (v) => _updateLocalAutoBackupPolicy(
                                    localPolicy.copyWith(backupOnIdle: v),
                                  ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: InputDecorator(
                              decoration: const InputDecoration(
                                labelText: '本地静置备份等待时长',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<int>(
                                  key: const Key(
                                    'local_backup_idle_minutes_selector',
                                  ),
                                  isExpanded: true,
                                  isDense: true,
                                  value: localPolicy.idleMinutes,
                                  items: [
                                    for (final m in localIdleOptions)
                                      DropdownMenuItem<int>(
                                        value: m,
                                        child: Text('$m 分钟'),
                                      ),
                                  ],
                                  onChanged: _busy
                                      ? null
                                      : (val) {
                                          if (val != null) {
                                            _updateLocalAutoBackupPolicy(
                                              localPolicy.copyWith(
                                                idleMinutes: val,
                                              ),
                                            );
                                          }
                                        },
                                ),
                              ),
                            ),
                          ),
                          SwitchListTile(
                            key: const Key('local_backup_trigger_schedule'),
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: const Text('定时周期自动备份'),
                            subtitle: const Text('距上次本地备份满设定周期且有数据变更时生成'),
                            value: localPolicy.backupOnSchedule,
                            onChanged: _busy
                                ? null
                                : (v) => _updateLocalAutoBackupPolicy(
                                    localPolicy.copyWith(backupOnSchedule: v),
                                  ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: InputDecorator(
                              decoration: const InputDecoration(
                                labelText: '本地定时备份周期',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<int>(
                                  key: const Key(
                                    'local_backup_schedule_interval_selector',
                                  ),
                                  isExpanded: true,
                                  isDense: true,
                                  value: localPolicy.scheduleIntervalMinutes,
                                  items: [
                                    for (final m in localScheduleOptions)
                                      DropdownMenuItem<int>(
                                        value: m,
                                        child: Text(_formatIntervalMinutes(m)),
                                      ),
                                  ],
                                  onChanged: _busy
                                      ? null
                                      : (val) {
                                          if (val != null) {
                                            _updateLocalAutoBackupPolicy(
                                              localPolicy.copyWith(
                                                scheduleIntervalMinutes: val,
                                              ),
                                            );
                                          }
                                        },
                                ),
                              ),
                            ),
                          ),
                          const Divider(height: 24),
                          localListAsync.when(
                            loading: () => const Padding(
                              padding: EdgeInsets.all(12),
                              child: Center(child: CircularProgressIndicator()),
                            ),
                            error: (e, _) => Text(safeMessage(e)),
                            data: (items) {
                              if (items.isEmpty) {
                                return const Padding(
                                  key: Key('local_backups_empty'),
                                  padding: EdgeInsets.symmetric(vertical: 8),
                                  child: Text('暂无应用内本地备份'),
                                );
                              }
                              return Column(
                                children: [
                                  for (final item in items)
                                    ListTile(
                                      key: Key(
                                        'local_backup_item_${item.fileName}',
                                      ),
                                      contentPadding: EdgeInsets.zero,
                                      title: Text(item.fileName),
                                      subtitle: Text(
                                        <String>[
                                          '${formatDateTime(DateTime.fromMillisecondsSinceEpoch(item.modifiedAtMs))} · ${_formatSize(item.sizeBytes)}',
                                          if (item.manifest != null)
                                            _formatManifestSummary(
                                              item.manifest,
                                            ),
                                        ].join('\n'),
                                      ),
                                      isThreeLine: item.manifest != null,
                                      trailing: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          TextButton(
                                            key: Key(
                                              'local_restore_${item.fileName}',
                                            ),
                                            onPressed: _busy
                                                ? null
                                                : () => _handleRestoreLocalItem(
                                                    item,
                                                  ),
                                            child: const Text('恢复'),
                                          ),
                                          IconButton(
                                            key: Key(
                                              'local_delete_${item.fileName}',
                                            ),
                                            tooltip: '删除',
                                            onPressed: _busy
                                                ? null
                                                : () => _handleDeleteLocalItem(
                                                    item,
                                                  ),
                                            icon: const Icon(
                                              Icons.delete_outline,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                ],
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '云端历史版本备份',
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                              ),
                              Chip(
                                key: const Key('webdav_status_badge'),
                                label: Text(activeBadgeText),
                                visualDensity: VisualDensity.compact,
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            activeCloudSubtitle,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              FilledButton.icon(
                                key: const Key('webdav_backup_now_button'),
                                onPressed: !_busy && isActiveCloudReady
                                    ? () => _handleCloudBackupUpload(
                                        activeBackend,
                                      )
                                    : null,
                                icon: const Icon(Icons.cloud_upload_outlined),
                                label: const Text('立即云端备份'),
                              ),
                              if (isActiveCloudReady)
                                OutlinedButton.icon(
                                  key: const Key('webdav_refresh_button'),
                                  onPressed: _busy
                                      ? null
                                      : _refreshAfterBackupChange,
                                  icon: const Icon(Icons.refresh),
                                  label: const Text('刷新列表'),
                                ),
                            ],
                          ),
                          if (isActiveCloudReady) ...[
                            const SizedBox(height: 8),
                            SwitchListTile(
                              key: const Key('auto_backup_switch'),
                              contentPadding: EdgeInsets.zero,
                              title: const Text('自动静默云备份'),
                              subtitle: const Text(
                                '距上次备份满 24 小时且本地有新账单变动时自动上传',
                              ),
                              value: activeAutoBackupEnabled,
                              onChanged: _busy ? null : _toggleAutoBackup,
                            ),
                          ],
                          const Divider(height: 24),
                          if (!isActiveCloudReady)
                            Padding(
                              key: const Key('webdav_unconfigured_hint'),
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Text(
                                activeBackend == CloudBackendType.s3
                                    ? 'S3 对象存储尚未完成配置，请点击上方「配置 S3」。'
                                    : '云备份尚未启用或配置，请在上方配置 WebDAV 或 S3 对象存储。',
                              ),
                            )
                          else
                            remoteListAsync.when(
                              loading: () => const Padding(
                                padding: EdgeInsets.all(12),
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              ),
                              error: (e, _) => Text(safeMessage(e)),
                              data: (items) {
                                if (items.isEmpty) {
                                  return const Padding(
                                    key: Key('webdav_backups_empty'),
                                    padding: EdgeInsets.symmetric(vertical: 8),
                                    child: Text('远端目录暂无备份文件'),
                                  );
                                }
                                return Column(
                                  children: [
                                    for (final item in items)
                                      ListTile(
                                        key: Key(
                                          'webdav_backup_item_${item.fileName}',
                                        ),
                                        contentPadding: EdgeInsets.zero,
                                        title: Text(item.fileName),
                                        subtitle: Text(
                                          isConflictBackupFileName(
                                                item.fileName,
                                              )
                                              ? '${formatDateTime(DateTime.fromMillisecondsSinceEpoch(item.modifiedAtMs))} · ${_formatSize(item.sizeBytes)} · 冲突保护快照'
                                              : '${formatDateTime(DateTime.fromMillisecondsSinceEpoch(item.modifiedAtMs))} · ${_formatSize(item.sizeBytes)}',
                                        ),
                                        trailing: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            TextButton(
                                              key: Key(
                                                'webdav_restore_${item.fileName}',
                                              ),
                                              onPressed: _busy
                                                  ? null
                                                  : () =>
                                                        _handleRestoreCloudItem(
                                                          item,
                                                          activeBackend,
                                                        ),
                                              child: const Text('恢复'),
                                            ),
                                            IconButton(
                                              key: Key(
                                                'webdav_delete_${item.fileName}',
                                              ),
                                              tooltip: '删除',
                                              onPressed: _busy
                                                  ? null
                                                  : () =>
                                                        _handleDeleteCloudItem(
                                                          item,
                                                          activeBackend,
                                                        ),
                                              icon: const Icon(
                                                Icons.delete_outline,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                  ],
                                );
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
