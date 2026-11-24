import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/failure.dart';
import '../../data/backup/s3_client.dart';
import '../../data/backup/webdav_client.dart';
import '../../domain/rules/cloud_sync_rules.dart';
import '../../platform/files.dart';
import '../common/common.dart';
import 'backup_page.dart';
import 'backup_providers.dart';
import 'post_restore_refresh.dart';

/// Snapshot of sync/backup status for mobile quick entry widgets without
/// forcing cold-start DB initialization in standalone widget layout tests.
final class MobileSyncQuickPreview {
  const MobileSyncQuickPreview({
    required this.isCloudReady,
    required this.backendLabel,
    required this.statusLine,
    this.hasConflict = false,
  });

  const MobileSyncQuickPreview.fallback()
    : isCloudReady = false,
      hasConflict = false,
      backendLabel = '本地与云端',
      statusLine = '单设备快照接力 · 一键同步与本地备份';

  final bool isCloudReady;
  final bool hasConflict;
  final String backendLabel;
  final String statusLine;
}

final quickSyncEntryVisibilityProvider =
    Provider<({bool showHome, bool showMe})>((ref) {
      if (!ref.exists(databaseProvider) &&
          !ref.exists(cloudSyncSettingsProvider)) {
        return (showHome: false, showMe: false);
      }
      final s = ref.watch(cloudSyncSettingsProvider).value;
      return (
        showHome: s?.showHomeQuickEntry ?? false,
        showMe: s?.showMeQuickEntry ?? false,
      );
    });

final mobileSyncQuickPreviewProvider = Provider<MobileSyncQuickPreview>((ref) {
  if (!ref.exists(databaseProvider)) {
    return const MobileSyncQuickPreview.fallback();
  }
  final davConfig = ref
      .watch(webDavConfigProvider)
      .maybeWhen(data: (c) => c, orElse: WebDavConfig.unconfigured);
  final s3Config = ref
      .watch(s3ConfigProvider)
      .maybeWhen(data: (c) => c, orElse: S3Config.unconfigured);
  final settings = ref
      .watch(cloudSyncSettingsProvider)
      .maybeWhen(
        data: (s) => s,
        orElse: () => CloudSyncSettings(
          backend: davConfig.isConfigured
              ? CloudBackendType.webdav
              : CloudBackendType.none,
          deviceId: 'pending',
        ),
      );
  final rawCursor = ref
      .watch(cloudSyncCursorProvider)
      .maybeWhen(data: (c) => c, orElse: LocalSyncCursor.initial);

  final ready = switch (settings.backend) {
    CloudBackendType.webdav => davConfig.isConfigured,
    CloudBackendType.s3 => s3Config.isConfigured,
    CloudBackendType.none => false,
  };

  if (!ready) {
    final lastBackupMs = ref
        .watch(lastBackupAtMsProvider)
        .maybeWhen(data: (ms) => ms, orElse: () => null);
    final status = lastBackupMs == null
        ? '单设备快照接力 · 点击配置云同步或一键备份'
        : '上次备份 ${formatDateTime(DateTime.fromMillisecondsSinceEpoch(lastBackupMs))}';
    return MobileSyncQuickPreview(
      isCloudReady: false,
      backendLabel: '本地备份',
      statusLine: status,
    );
  }

  final targetFingerprint = switch (settings.backend) {
    CloudBackendType.webdav => davConfig.targetFingerprint,
    CloudBackendType.s3 => s3Config.targetFingerprint,
    CloudBackendType.none => '',
  };
  final cursor = targetFingerprint.isEmpty
      ? rawCursor
      : rawCursor.scopedToTarget(targetFingerprint);

  final conflictFile = cursor.lastConflictFileName?.trim();
  final hasConflict = conflictFile != null && conflictFile.isNotEmpty;
  final String status;
  if (hasConflict) {
    status = '检测到同步冲突 · 待处理';
  } else if (cursor.isNeverSynced || cursor.lastSyncedAtMs == null) {
    status = '${settings.backend.displayLabel} 已就绪 · 换设备前请先同步';
  } else {
    status =
        '${settings.backend.displayLabel} · 已同步 r${cursor.lastSyncedRevision} · ${formatDateTime(DateTime.fromMillisecondsSinceEpoch(cursor.lastSyncedAtMs!))}';
  }
  return MobileSyncQuickPreview(
    isCloudReady: true,
    hasConflict: hasConflict,
    backendLabel: settings.backend.displayLabel,
    statusLine: status,
  );
});

Future<void> _invalidateBackupState(
  WidgetRef ref, {
  required bool didPullOrRestore,
}) async {
  if (didPullOrRestore) {
    await invalidateAllAfterDatabaseReplace(ref);
    return;
  }
  ref
    ..invalidate(localBackupsProvider)
    ..invalidate(webDavBackupsProvider)
    ..invalidate(s3BackupsProvider)
    ..invalidate(activeCloudBackupsProvider)
    ..invalidate(cloudSyncCursorProvider)
    ..invalidate(lastBackupAtMsProvider);
}

void _openFullBackupPage(BuildContext context) {
  final router = GoRouter.maybeOf(context);
  if (router != null) {
    context.push('/backup');
  } else {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const BackupPage()));
  }
}

Future<SyncConflictResolution?> _promptQuickConflictResolution(
  BuildContext context,
  CloudSyncOutcome conflict,
) {
  final head = conflict.remoteHead;
  final remoteDesc = head == null
      ? '云端新版本'
      : '设备「${head.deviceName}」于 ${formatDateTime(DateTime.fromMillisecondsSinceEpoch(head.updatedAtMs))} 推送的版本 r${head.revision}（账单 ${head.recordCount} 条）';
  final backupName = conflict.conflictBackupFileName ?? 'conflict_*.tally';
  return showDialog<SyncConflictResolution?>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const Key('cloud_sync_conflict_dialog'),
      title: const Text('检测到多端同步冲突'),
      content: Text(
        '本机与云端自上次同步后均产生了新的账务改动。\n\n'
        '• 云端状态：$remoteDesc\n'
        '• 零丢数保护：已自动将本机当前完整数据归档保存为「$backupName」。\n\n'
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
}

/// Opens a compact mobile bottom sheet for 1-tap Cloud Sync, Local `.tally`
/// Backup, external export, and quick navigation to `/backup`.
Future<void> showMobileSyncBackupQuickSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    enableDrag: false,
    showDragHandle: false,
    builder: (_) => const _MobileSyncBackupQuickSheet(),
  );
}

class _MobileSyncBackupQuickSheet extends ConsumerStatefulWidget {
  const _MobileSyncBackupQuickSheet();

  @override
  ConsumerState<_MobileSyncBackupQuickSheet> createState() =>
      _MobileSyncBackupQuickSheetState();
}

class _MobileSyncBackupQuickSheetState
    extends ConsumerState<_MobileSyncBackupQuickSheet> {
  bool _busy = false;
  String? _busyText;

  bool get _isCloudSyncInProgress => ref
      .read(cloudSyncInProgressProvider)
      .maybeWhen(data: (v) => v, orElse: () => false);

  void _showToast(ScaffoldMessengerState? messenger, String text) {
    messenger
      ?..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _runSync({SyncConflictResolution? resolution}) async {
    if (_busy || _isCloudSyncInProgress) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() {
      _busy = true;
      _busyText = '正在执行多端云同步…';
    });
    CloudSyncOutcome? pendingConflict;
    try {
      final service = await ref.read(tallyBackupServiceProvider.future);
      final outcome = await service.syncNow(resolution: resolution);
      if (!mounted) return;
      switch (outcome.status) {
        case CloudSyncStatus.alreadyUpToDate:
          await _invalidateBackupState(ref, didPullOrRestore: false);
          if (!mounted) return;
          Navigator.of(context).pop();
          _showToast(messenger, '多端数据已是最新（版本 r${outcome.revision}）');
        case CloudSyncStatus.pushed:
          await _invalidateBackupState(ref, didPullOrRestore: false);
          if (!mounted) return;
          Navigator.of(context).pop();
          _showToast(messenger, '已推送最新快照至云端（版本 r${outcome.revision}）');
        case CloudSyncStatus.pulled:
          await _invalidateBackupState(ref, didPullOrRestore: true);
          if (!mounted) return;
          Navigator.of(context).pop();
          _showToast(messenger, '已从云端同步最新数据（版本 r${outcome.revision}）');
        case CloudSyncStatus.conflict:
          await _invalidateBackupState(ref, didPullOrRestore: false);
          pendingConflict = outcome;
      }
    } catch (e) {
      if (mounted) {
        _showToast(messenger, safeMessage(e));
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyText = null;
        });
      }
    }

    if (pendingConflict != null && mounted) {
      final choice = await _promptQuickConflictResolution(
        context,
        pendingConflict,
      );
      if (choice != null && mounted) {
        await _runSync(resolution: choice);
      }
    }
  }

  Future<void> _runLocalBackup() async {
    if (_busy || _isCloudSyncInProgress) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() {
      _busy = true;
      _busyText = '正在打包本地备份…';
    });
    try {
      final service = await ref.read(tallyBackupServiceProvider.future);
      final saved = await service.createLocalBackup();
      if (!mounted) return;
      await _invalidateBackupState(ref, didPullOrRestore: false);
      if (!mounted) return;
      Navigator.of(context).pop();
      _showToast(messenger, '已生成本地备份：${saved.fileName}');
    } catch (e) {
      if (mounted) {
        _showToast(messenger, safeMessage(e));
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyText = null;
        });
      }
    }
  }

  Future<void> _runExportExternal() async {
    if (_busy || _isCloudSyncInProgress) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final fileAccess = ref.read(backupFileAccessProvider);
    final canSave =
        fileAccess.saveLocationCapability.state == CapabilityState.available;
    setState(() {
      _busy = true;
      _busyText = canSave ? '正在导出 .tally 备份…' : '正在准备系统分享…';
    });
    try {
      final service = await ref.read(tallyBackupServiceProvider.future);
      if (canSave) {
        final name = await service.exportBackupToSaveLocation(
          fileAccess: fileAccess,
        );
        if (!mounted) return;
        await _invalidateBackupState(ref, didPullOrRestore: false);
        if (!mounted) return;
        Navigator.of(context).pop();
        _showToast(messenger, '已保存备份文件：$name');
      } else {
        await service.shareBackup(fileAccess: fileAccess);
        if (!mounted) return;
        Navigator.of(context).pop();
      }
    } on Failure catch (e) {
      if (e.code != FailureCode.cancelled && mounted) {
        _showToast(messenger, e.message);
      }
    } catch (e) {
      if (mounted) {
        _showToast(messenger, safeMessage(e));
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyText = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    // Touch databaseProvider inside the sheet so status streams warm up cleanly.
    ref.watch(databaseProvider);
    final syncInProgress = ref
        .watch(cloudSyncInProgressProvider)
        .maybeWhen(data: (v) => v, orElse: () => false);
    final busy = _busy || syncInProgress;
    final preview = ref.watch(mobileSyncQuickPreviewProvider);
    final fileAccess = ref.watch(backupFileAccessProvider);
    final canSave =
        fileAccess.saveLocationCapability.state == CapabilityState.available;
    final canShare =
        fileAccess.shareCapability.state == CapabilityState.available;

    return PopScope(
      canPop: !busy,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragEnd: busy
            ? null
            : (details) {
                if ((details.primaryVelocity ?? 0) > 280) {
                  Navigator.of(context).maybePop();
                }
              },
        child: Padding(
          key: const Key('mobile_sync_backup_quick_sheet'),
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 32,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                children: [
                  Icon(
                    preview.hasConflict
                        ? Icons.sync_problem_rounded
                        : Icons.cloud_sync_outlined,
                    size: 22,
                    color: preview.hasConflict ? scheme.error : scheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '快捷同步与备份',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  TextButton(
                    key: const Key('quick_sheet_open_backup_page'),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed: busy
                        ? null
                        : () {
                            final parentCtx = Navigator.of(context).context;
                            Navigator.of(context).pop();
                            _openFullBackupPage(parentCtx);
                          },
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('完整设置'),
                        Icon(Icons.chevron_right_rounded, size: 18),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                preview.statusLine,
                key: const Key('quick_sheet_status_text'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: preview.hasConflict
                      ? scheme.error
                      : scheme.onSurfaceVariant,
                  fontWeight: preview.hasConflict ? FontWeight.w600 : null,
                ),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: isDark
                      ? scheme.tertiaryContainer.withValues(alpha: 0.32)
                      : scheme.tertiaryContainer.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 16,
                      color: scheme.onTertiaryContainer,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '提示：快照云同步适用于单设备主力记账，换设备前请先同步接力，避免多台设备离线并发记账。',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onTertiaryContainer,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (busy) ...[
                const SizedBox(height: 12),
                Row(
                  key: const Key('quick_sheet_busy_indicator'),
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _busyText ?? (syncInProgress ? '正在执行多端云同步…' : '正在处理…'),
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 14),
              if (preview.isCloudReady) ...[
                FilledButton.icon(
                  key: const Key('quick_sheet_sync_now_button'),
                  onPressed: busy ? null : _runSync,
                  icon: const Icon(Icons.sync_rounded, size: 18),
                  label: const Text('立即多端同步'),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const Key('quick_sheet_local_backup_button'),
                        onPressed: busy ? null : _runLocalBackup,
                        icon: const Icon(Icons.save_outlined, size: 17),
                        label: const FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text('生成本地备份', maxLines: 1, softWrap: false),
                        ),
                      ),
                    ),
                    if (canSave || canShare) ...[
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          key: const Key('quick_sheet_export_save_button'),
                          onPressed: busy ? null : _runExportExternal,
                          icon: Icon(
                            canSave
                                ? Icons.download_outlined
                                : Icons.ios_share_rounded,
                            size: 17,
                          ),
                          label: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              canSave ? '另存为 .tally' : '分享 .tally',
                              maxLines: 1,
                              softWrap: false,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ] else ...[
                FilledButton.icon(
                  key: const Key('quick_sheet_local_backup_button'),
                  onPressed: busy ? null : _runLocalBackup,
                  icon: const Icon(Icons.save_outlined, size: 18),
                  label: const Text('立即生成本地备份'),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const Key('quick_sheet_configure_sync_button'),
                        onPressed: busy
                            ? null
                            : () {
                                final parentCtx = Navigator.of(context).context;
                                Navigator.of(context).pop();
                                _openFullBackupPage(parentCtx);
                              },
                        icon: const Icon(Icons.cloud_outlined, size: 17),
                        label: const FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text('配置云同步', maxLines: 1, softWrap: false),
                        ),
                      ),
                    ),
                    if (canSave || canShare) ...[
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          key: const Key('quick_sheet_export_save_button'),
                          onPressed: busy ? null : _runExportExternal,
                          icon: Icon(
                            canSave
                                ? Icons.download_outlined
                                : Icons.ios_share_rounded,
                            size: 17,
                          ),
                          label: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              canSave ? '另存为 .tally' : '分享 .tally',
                              maxLines: 1,
                              softWrap: false,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Top pinned quick-entry card on mobile `MePage` (`更多`) for 1-tap sync/backup
/// and direct `/backup` access without scrolling through 5 menu groups.
class MobileMeSyncQuickCard extends ConsumerStatefulWidget {
  const MobileMeSyncQuickCard({super.key, required this.cardColor});

  final Color cardColor;

  @override
  ConsumerState<MobileMeSyncQuickCard> createState() =>
      _MobileMeSyncQuickCardState();
}

class _MobileMeSyncQuickCardState extends ConsumerState<MobileMeSyncQuickCard> {
  bool _busy = false;

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  bool get _isCloudSyncInProgress =>
      (ref.exists(databaseProvider) ||
          ref.exists(cloudSyncInProgressProvider)) &&
      ref
          .read(cloudSyncInProgressProvider)
          .maybeWhen(data: (v) => v, orElse: () => false);

  Future<void> _handleOneTap(MobileSyncQuickPreview preview) async {
    if (_busy || _isCloudSyncInProgress) return;
    setState(() => _busy = true);
    CloudSyncOutcome? pendingConflict;
    try {
      final service = await ref.read(tallyBackupServiceProvider.future);
      if (preview.isCloudReady) {
        final outcome = await service.syncNow();
        if (!mounted) return;
        switch (outcome.status) {
          case CloudSyncStatus.alreadyUpToDate:
            await _invalidateBackupState(ref, didPullOrRestore: false);
            _toast('多端数据已是最新（版本 r${outcome.revision}）');
          case CloudSyncStatus.pushed:
            await _invalidateBackupState(ref, didPullOrRestore: false);
            _toast('已推送最新快照至云端（版本 r${outcome.revision}）');
          case CloudSyncStatus.pulled:
            await _invalidateBackupState(ref, didPullOrRestore: true);
            _toast('已从云端同步最新数据（版本 r${outcome.revision}）');
          case CloudSyncStatus.conflict:
            await _invalidateBackupState(ref, didPullOrRestore: false);
            pendingConflict = outcome;
        }
      } else {
        final saved = await service.createLocalBackup();
        if (!mounted) return;
        await _invalidateBackupState(ref, didPullOrRestore: false);
        _toast('已生成本地备份：${saved.fileName}');
      }
    } catch (e) {
      _toast(safeMessage(e));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }

    if (pendingConflict != null && mounted) {
      final choice = await _promptQuickConflictResolution(
        context,
        pendingConflict,
      );
      if (choice != null && mounted) {
        setState(() => _busy = true);
        try {
          final service = await ref.read(tallyBackupServiceProvider.future);
          final resolved = await service.syncNow(resolution: choice);
          if (!mounted) return;
          await _invalidateBackupState(
            ref,
            didPullOrRestore: resolved.status == CloudSyncStatus.pulled,
          );
          _toast('冲突已处理（版本 r${resolved.revision}）');
        } catch (e) {
          _toast(safeMessage(e));
        } finally {
          if (mounted) setState(() => _busy = false);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final preview = ref.watch(mobileSyncQuickPreviewProvider);
    final syncInProgress =
        (ref.exists(databaseProvider) ||
            ref.exists(cloudSyncInProgressProvider))
        ? ref
              .watch(cloudSyncInProgressProvider)
              .maybeWhen(data: (v) => v, orElse: () => false)
        : false;
    final busy = _busy || syncInProgress;
    final accent = isDark ? const Color(0xFF6EE7B7) : const Color(0xFF1F7A53);
    final fgTone = Color.lerp(accent, scheme.primary, 0.18)!;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Material(
        color: widget.cardColor,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const Key('me-mobile-sync-quick-card'),
          onTap: () => _openFullBackupPage(context),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: (preview.hasConflict ? scheme.error : fgTone)
                        .withValues(alpha: isDark ? 0.16 : 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    preview.hasConflict
                        ? Icons.sync_problem_rounded
                        : (preview.isCloudReady
                              ? Icons.cloud_sync_outlined
                              : Icons.backup_outlined),
                    size: 19,
                    color: preview.hasConflict ? scheme.error : fgTone,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '快捷同步与备份',
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        syncInProgress ? '正在执行多端云同步…' : preview.statusLine,
                        key: const Key('me-mobile-sync-quick-status'),
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: preview.hasConflict && !syncInProgress
                              ? scheme.error
                              : scheme.onSurfaceVariant,
                          fontWeight: preview.hasConflict && !syncInProgress
                              ? FontWeight.w600
                              : null,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  key: const Key('me-mobile-sync-quick-action'),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                  ),
                  onPressed: busy ? null : () => _handleOneTap(preview),
                  child: busy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            preview.isCloudReady ? '立即同步' : '立即备份',
                            maxLines: 1,
                            softWrap: false,
                            style: const TextStyle(fontSize: 12.5),
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
