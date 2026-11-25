import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/adaptive.dart';
import '../../core/failure.dart';
import '../../data/backup/webdav_client.dart';
import '../../domain/rules/cloud_sync_rules.dart';
import '../../domain/rules/tally_backup.dart';
import '../../platform/files.dart';
import '../common/common.dart';
import '../common/desktop_modal_page.dart';
import 'backup_providers.dart';
import 'post_restore_refresh.dart';

/// Storage source managed by [BackupHistoryManagementDialog].
enum BackupHistorySource { local, cloud }

/// Filter mode in [BackupHistoryManagementDialog].
enum BackupHistoryFilter { all, routine, conflict }

/// Summary returned to `BackupPage` when [BackupHistoryManagementDialog] closes.
final class BackupHistoryDialogOutcome {
  const BackupHistoryDialogOutcome({
    this.didRestore = false,
    this.restoredTotalRows = 0,
    this.deletedLocalFileNames = const <String>{},
  });

  final bool didRestore;
  final int restoredTotalRows;
  final Set<String> deletedLocalFileNames;
}

/// Reusable compact pill badge marking `conflict_*.tally` zero-data-loss archives.
class ConflictBackupBadge extends StatelessWidget {
  const ConflictBackupBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '冲突保护',
        maxLines: 1,
        softWrap: false,
        style: theme.textTheme.labelSmall?.copyWith(
          fontSize: 10.5,
          height: 1.15,
          fontWeight: FontWeight.w600,
          color: scheme.onErrorContainer,
        ),
      ),
    );
  }
}

/// Opens [BackupHistoryManagementDialog] as a centered modal [Dialog] on
/// desktop or a tall safe-area modal bottom sheet on mobile.
Future<BackupHistoryDialogOutcome?> showBackupHistoryManagementDialog(
  BuildContext context, {
  required BackupHistorySource source,
  CloudBackendType? cloudBackend,
}) {
  if (DesktopAdaptive.isDesktop(context)) {
    return showDialog<BackupHistoryDialogOutcome>(
      context: context,
      useRootNavigator: true,
      builder: (_) => DesktopModalEscapeScope(
        enabled: true,
        child: Dialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 20,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640, maxHeight: 700),
            child: BackupHistoryManagementDialog(
              source: source,
              cloudBackend: cloudBackend,
              isDesktopDialog: true,
            ),
          ),
        ),
      ),
    );
  }

  return showModalBottomSheet<BackupHistoryDialogOutcome>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: false,
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.90,
      child: BackupHistoryManagementDialog(
        source: source,
        cloudBackend: cloudBackend,
        isDesktopDialog: false,
      ),
    ),
  );
}

/// Full-list viewer and multi-select batch cleaner for local and cloud `.tally`
/// backups, supporting filter chips (`全部` / `常规备份` / `冲突保护包`), one-tap
/// `'选中全部冲突包'`, virtualized [ListView.builder], single-item
/// restore/export/delete, and confirmed batch deletion (`'删除已选 (K)'`).
class BackupHistoryManagementDialog extends ConsumerStatefulWidget {
  const BackupHistoryManagementDialog({
    super.key,
    required this.source,
    this.cloudBackend,
    this.isDesktopDialog = false,
  });

  final BackupHistorySource source;
  final CloudBackendType? cloudBackend;
  final bool isDesktopDialog;

  @override
  ConsumerState<BackupHistoryManagementDialog> createState() =>
      _BackupHistoryManagementDialogState();
}

class _BackupHistoryManagementDialogState
    extends ConsumerState<BackupHistoryManagementDialog> {
  BackupHistoryFilter _filter = BackupHistoryFilter.all;
  final Set<String> _selectedNames = <String>{};
  final Set<String> _deletedLocalNames = <String>{};
  bool _busy = false;
  String? _busyText;

  bool get _isCloud => widget.source == BackupHistorySource.cloud;

  String get _cloudBackendTitle =>
      widget.cloudBackend == CloudBackendType.s3 ? 'S3' : 'WebDAV';

  String get _cloudBackendLabel =>
      widget.cloudBackend == CloudBackendType.s3 ? 'S3 对象存储' : 'WebDAV 服务器';

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
      ?..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _closeWithOutcome({bool didRestore = false, int restoredRows = 0}) {
    if (!mounted) return;
    Navigator.of(context).pop(
      BackupHistoryDialogOutcome(
        didRestore: didRestore,
        restoredTotalRows: restoredRows,
        deletedLocalFileNames: Set<String>.unmodifiable(_deletedLocalNames),
      ),
    );
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
    return '共 ${m.totalRows} 条 · 账单 ${m.recordCount} · 便签 ${m.noteCount}$attSuffix';
  }

  List<BackupFileMetadata> _applyFilter(List<BackupFileMetadata> items) {
    return switch (_filter) {
      BackupHistoryFilter.all => items,
      BackupHistoryFilter.routine =>
        items.where((e) => !isConflictBackupFileName(e.fileName)).toList(),
      BackupHistoryFilter.conflict =>
        items.where((e) => isConflictBackupFileName(e.fileName)).toList(),
    };
  }

  void _toggleItem(String fileName) {
    setState(() {
      if (!_selectedNames.remove(fileName)) {
        _selectedNames.add(fileName);
      }
    });
  }

  void _toggleSelectAllFiltered(List<BackupFileMetadata> filteredItems) {
    if (filteredItems.isEmpty) return;
    final filteredSet = <String>{
      for (final item in filteredItems) item.fileName,
    };
    final allSelected = filteredSet.every(_selectedNames.contains);
    setState(() {
      if (allSelected) {
        _selectedNames.removeAll(filteredSet);
      } else {
        _selectedNames.addAll(filteredSet);
      }
    });
  }

  void _selectAllConflicts(List<BackupFileMetadata> conflictItems) {
    if (conflictItems.isEmpty) return;
    setState(() {
      if (_filter == BackupHistoryFilter.routine) {
        _filter = BackupHistoryFilter.conflict;
      }
      for (final item in conflictItems) {
        _selectedNames.add(item.fileName);
      }
    });
  }

  Future<void> _handleSingleRestore(BackupFileMetadata item) async {
    final ok = await confirm(
      context,
      title: _isCloud ? '确认从 $_cloudBackendTitle 恢复？' : '确认恢复此本地备份？',
      message: _isCloud
          ? '将下载「${item.fileName}」至隔离暂存区完成哈希校验，再原子替换当前数据。'
          : '将校验「${item.fileName}」完整性并覆盖当前全部账务、便签与配置数据。',
      ok: '确认恢复',
    );
    if (!ok || !mounted) return;

    setState(() {
      _busy = true;
      _busyText = _isCloud ? '正在下载并校验远端备份…' : '正在恢复本地备份…';
    });
    try {
      final service = await ref.read(tallyBackupServiceProvider.future);
      final manifest = _isCloud
          ? await service.restoreActiveCloudBackup(item.fileName)
          : await service.restoreLocalBackup(item.fileName);
      if (!mounted) return;
      await invalidateAllAfterDatabaseReplace(ref);
      if (!mounted) return;
      _closeWithOutcome(didRestore: true, restoredRows: manifest.totalRows);
    } catch (e) {
      _showSnack(safeMessage(e));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyText = null;
        });
      }
    }
  }

  Future<void> _handleSingleExport(BackupFileMetadata item) async {
    final fileAccess = ref.read(backupFileAccessProvider);
    setState(() {
      _busy = true;
      _busyText = '正在导出「${item.fileName}」…';
    });
    try {
      final service = await ref.read(tallyBackupServiceProvider.future);
      final exportedName = await service.exportExistingBackup(
        fileName: item.fileName,
        isCloud: _isCloud,
        fileAccess: fileAccess,
      );
      _showSnack('已导出备份文件：$exportedName');
    } on Failure catch (e) {
      if (e.code != FailureCode.cancelled) {
        _showSnack(e.message);
      }
    } catch (e) {
      _showSnack(safeMessage(e));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyText = null;
        });
      }
    }
  }

  Future<void> _handleSingleDelete(BackupFileMetadata item) async {
    final ok = await confirm(
      context,
      title: _isCloud ? '删除远端备份？' : '删除本地备份？',
      message: _isCloud
          ? '确认从$_cloudBackendLabel删除「${item.fileName}」？'
          : '确认删除本地备份文件「${item.fileName}」？',
      ok: '删除',
    );
    if (!ok || !mounted) return;

    setState(() {
      _busy = true;
      _busyText = _isCloud ? '正在删除远端备份…' : '正在删除本地备份…';
    });
    try {
      final service = await ref.read(tallyBackupServiceProvider.future);
      if (_isCloud) {
        await service.deleteActiveCloudBackup(item.fileName);
      } else {
        await service.deleteLocalBackup(item.fileName);
        _deletedLocalNames.add(item.fileName);
      }
      if (!mounted) return;
      setState(() => _selectedNames.remove(item.fileName));
      invalidateBackupHistoryProviders(ref);
      _showSnack('已删除备份：${item.fileName}');
    } catch (e) {
      _showSnack(safeMessage(e));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyText = null;
        });
      }
    }
  }

  Future<void> _handleBatchDelete(List<String> targets) async {
    if (targets.isEmpty) return;
    final conflictCount = targets.where(isConflictBackupFileName).length;
    final conflictNote = conflictCount > 0
        ? '\n其中包含 $conflictCount 份冲突保护包，删除后不可恢复。'
        : '\n删除后无法恢复。';
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            key: const Key('backup_history_batch_delete_confirm_dialog'),
            title: Text(_isCloud ? '批量删除远端备份？' : '批量删除本地备份？'),
            content: Text(
              _isCloud
                  ? '确认从$_cloudBackendLabel永久删除已选的 ${targets.length} 份备份文件？$conflictNote'
                  : '确认永久删除已选的 ${targets.length} 份本地备份文件？$conflictNote',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                key: const Key('backup_history_confirm_batch_delete_button'),
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error,
                  foregroundColor: Theme.of(ctx).colorScheme.onError,
                ),
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('确认删除'),
              ),
            ],
          ),
        ) ==
        true;
    if (!confirmed || !mounted) return;

    setState(() {
      _busy = true;
      _busyText = '正在批量删除 ${targets.length} 份备份…';
    });
    try {
      final service = await ref.read(tallyBackupServiceProvider.future);
      final int deletedCount;
      if (_isCloud) {
        deletedCount = await service.deleteActiveCloudBackups(targets);
      } else {
        deletedCount = await service.deleteLocalBackups(targets);
        _deletedLocalNames.addAll(targets);
      }
      if (!mounted) return;
      setState(() => _selectedNames.removeAll(targets));
      invalidateBackupHistoryProviders(ref);
      _showSnack(
        _isCloud ? '已批量删除 $deletedCount 份远端备份' : '已批量删除 $deletedCount 份本地备份',
      );
    } catch (e) {
      _showSnack(safeMessage(e));
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
    final listAsync = _isCloud
        ? ref.watch(activeCloudBackupsProvider)
        : ref.watch(localBackupsProvider);
    final syncInProgress =
        ref.watch(cloudSyncInProgressProvider).value ?? false;
    final effectiveBusy = _busy || syncInProgress;
    final fileAccess = ref.watch(backupFileAccessProvider);
    final canExportExternal =
        fileAccess.saveLocationCapability.state == CapabilityState.available ||
        fileAccess.shareCapability.state == CapabilityState.available;

    return PopScope(
      canPop: !effectiveBusy,
      child: Material(
        key: const Key('backup_history_management_dialog'),
        color: widget.isDesktopDialog ? scheme.surface : Colors.transparent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!widget.isDesktopDialog)
              Center(
                child: Container(
                  width: 32,
                  height: 4,
                  margin: const EdgeInsets.only(top: 8, bottom: 4),
                  decoration: BoxDecoration(
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.38),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                widget.isDesktopDialog ? 12 : 4,
                8,
                6,
              ),
              child: Row(
                children: [
                  Icon(
                    _isCloud
                        ? Icons.cloud_done_outlined
                        : Icons.folder_zip_outlined,
                    size: 20,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _isCloud ? '云端备份历史管理' : '本地备份历史管理',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('backup_history_close_button'),
                    tooltip: '关闭',
                    visualDensity: VisualDensity.compact,
                    onPressed: effectiveBusy ? null : _closeWithOutcome,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            if (effectiveBusy)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _busyText ?? (syncInProgress ? '正在执行多端云同步…' : '正在处理…'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.primary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const LinearProgressIndicator(minHeight: 2),
                  ],
                ),
              ),
            Expanded(
              child: listAsync.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(safeMessage(e), textAlign: TextAlign.center),
                  ),
                ),
                data: (allItems) {
                  final existingNameSet = <String>{
                    for (final item in allItems) item.fileName,
                  };
                  final validSelected = <String>[
                    for (final item in allItems)
                      if (_selectedNames.contains(item.fileName)) item.fileName,
                  ];
                  final routineItems = allItems
                      .where((e) => !isConflictBackupFileName(e.fileName))
                      .toList();
                  final conflictItems = allItems
                      .where((e) => isConflictBackupFileName(e.fileName))
                      .toList();
                  final filteredItems = _applyFilter(allItems);
                  final allFilteredSelected =
                      filteredItems.isNotEmpty &&
                      filteredItems.every(
                        (e) =>
                            existingNameSet.contains(e.fileName) &&
                            _selectedNames.contains(e.fileName),
                      );

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            FilterChip(
                              key: const Key('backup_filter_all'),
                              visualDensity: VisualDensity.compact,
                              showCheckmark: false,
                              selected: _filter == BackupHistoryFilter.all,
                              onSelected: effectiveBusy
                                  ? null
                                  : (_) => setState(
                                      () => _filter = BackupHistoryFilter.all,
                                    ),
                              label: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text('全部'),
                                  const SizedBox(width: 4),
                                  Text('${allItems.length}'),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            FilterChip(
                              key: const Key('backup_filter_routine'),
                              visualDensity: VisualDensity.compact,
                              showCheckmark: false,
                              selected: _filter == BackupHistoryFilter.routine,
                              onSelected: effectiveBusy
                                  ? null
                                  : (_) => setState(
                                      () =>
                                          _filter = BackupHistoryFilter.routine,
                                    ),
                              label: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text('常规备份'),
                                  const SizedBox(width: 4),
                                  Text('${routineItems.length}'),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            FilterChip(
                              key: const Key('backup_filter_conflict'),
                              visualDensity: VisualDensity.compact,
                              showCheckmark: false,
                              selected: _filter == BackupHistoryFilter.conflict,
                              onSelected: effectiveBusy
                                  ? null
                                  : (_) => setState(
                                      () => _filter =
                                          BackupHistoryFilter.conflict,
                                    ),
                              label: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text('冲突保护包'),
                                  const SizedBox(width: 4),
                                  Text('${conflictItems.length}'),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (allItems.isNotEmpty)
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
                          child: Row(
                            children: [
                              TextButton.icon(
                                key: const Key(
                                  'backup_history_select_all_button',
                                ),
                                style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                ),
                                onPressed:
                                    effectiveBusy || filteredItems.isEmpty
                                    ? null
                                    : () => _toggleSelectAllFiltered(
                                        filteredItems,
                                      ),
                                icon: Icon(
                                  allFilteredSelected
                                      ? Icons.deselect_rounded
                                      : Icons.select_all_rounded,
                                  size: 17,
                                ),
                                label: Text(
                                  allFilteredSelected ? '取消全选' : '全选',
                                ),
                              ),
                              const SizedBox(width: 4),
                              TextButton.icon(
                                key: const Key(
                                  'backup_history_select_conflicts_button',
                                ),
                                style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                ),
                                onPressed:
                                    effectiveBusy || conflictItems.isEmpty
                                    ? null
                                    : () => _selectAllConflicts(conflictItems),
                                icon: const Icon(
                                  Icons.warning_amber_rounded,
                                  size: 17,
                                ),
                                label: const Text('选中全部冲突包'),
                              ),
                              if (validSelected.isNotEmpty) ...[
                                const SizedBox(width: 4),
                                TextButton(
                                  key: const Key(
                                    'backup_history_clear_selection_button',
                                  ),
                                  style: TextButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                    ),
                                  ),
                                  onPressed: effectiveBusy
                                      ? null
                                      : () => setState(_selectedNames.clear),
                                  child: const Text('清空选择'),
                                ),
                              ],
                            ],
                          ),
                        ),
                      const SizedBox(height: 4),
                      Expanded(
                        child: filteredItems.isEmpty
                            ? Center(
                                key: const Key('backup_history_empty'),
                                child: Padding(
                                  padding: const EdgeInsets.all(24),
                                  child: Text(
                                    allItems.isEmpty
                                        ? '暂无历史备份文件'
                                        : '当前筛选下暂无匹配的备份文件',
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              )
                            : ListView.builder(
                                key: const Key('backup_history_list'),
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  8,
                                  16,
                                  8,
                                ),
                                itemCount: filteredItems.length,
                                itemBuilder: (ctx, index) {
                                  final item = filteredItems[index];
                                  final isSelected = _selectedNames.contains(
                                    item.fileName,
                                  );
                                  final isConflict = isConflictBackupFileName(
                                    item.fileName,
                                  );
                                  final timeAndSize =
                                      '${formatDateTime(DateTime.fromMillisecondsSinceEpoch(item.modifiedAtMs))} · ${_formatSize(item.sizeBytes)}';
                                  final manifestInfo = _formatManifestSummary(
                                    item.manifest,
                                  );

                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: Material(
                                      key: Key(
                                        'backup_history_row_${item.fileName}',
                                      ),
                                      color: isSelected
                                          ? scheme.secondaryContainer
                                                .withValues(alpha: 0.55)
                                          : scheme.surfaceContainerLow,
                                      borderRadius: BorderRadius.circular(12),
                                      clipBehavior: Clip.antiAlias,
                                      child: InkWell(
                                        onTap: effectiveBusy
                                            ? null
                                            : () => _toggleItem(item.fileName),
                                        child: Padding(
                                          padding: const EdgeInsets.fromLTRB(
                                            6,
                                            8,
                                            10,
                                            6,
                                          ),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.stretch,
                                            children: [
                                              Row(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Checkbox(
                                                    key: Key(
                                                      'backup_history_checkbox_${item.fileName}',
                                                    ),
                                                    visualDensity:
                                                        VisualDensity.compact,
                                                    materialTapTargetSize:
                                                        MaterialTapTargetSize
                                                            .shrinkWrap,
                                                    value: isSelected,
                                                    onChanged: effectiveBusy
                                                        ? null
                                                        : (_) => _toggleItem(
                                                            item.fileName,
                                                          ),
                                                  ),
                                                  const SizedBox(width: 4),
                                                  Expanded(
                                                    child: Column(
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .start,
                                                      children: [
                                                        Row(
                                                          children: [
                                                            if (isConflict) ...[
                                                              const ConflictBackupBadge(),
                                                              const SizedBox(
                                                                width: 6,
                                                              ),
                                                            ],
                                                            Expanded(
                                                              child: Text(
                                                                item.fileName,
                                                                maxLines: 1,
                                                                overflow:
                                                                    TextOverflow
                                                                        .ellipsis,
                                                                style: theme
                                                                    .textTheme
                                                                    .bodyMedium
                                                                    ?.copyWith(
                                                                      fontWeight:
                                                                          FontWeight
                                                                              .w600,
                                                                    ),
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                        const SizedBox(
                                                          height: 2,
                                                        ),
                                                        Text(
                                                          manifestInfo.isEmpty
                                                              ? timeAndSize
                                                              : '$timeAndSize\n$manifestInfo',
                                                          style: theme
                                                              .textTheme
                                                              .bodySmall
                                                              ?.copyWith(
                                                                color: scheme
                                                                    .onSurfaceVariant,
                                                                height: 1.3,
                                                              ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              Row(
                                                mainAxisAlignment:
                                                    MainAxisAlignment.end,
                                                children: [
                                                  TextButton(
                                                    key: Key(
                                                      'backup_history_restore_${item.fileName}',
                                                    ),
                                                    style: TextButton.styleFrom(
                                                      visualDensity:
                                                          VisualDensity.compact,
                                                      tapTargetSize:
                                                          MaterialTapTargetSize
                                                              .shrinkWrap,
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                            horizontal: 8,
                                                            vertical: 4,
                                                          ),
                                                    ),
                                                    onPressed: effectiveBusy
                                                        ? null
                                                        : () =>
                                                              _handleSingleRestore(
                                                                item,
                                                              ),
                                                    child: const Text('恢复'),
                                                  ),
                                                  if (canExportExternal)
                                                    TextButton(
                                                      key: Key(
                                                        'backup_history_export_${item.fileName}',
                                                      ),
                                                      style: TextButton.styleFrom(
                                                        visualDensity:
                                                            VisualDensity
                                                                .compact,
                                                        tapTargetSize:
                                                            MaterialTapTargetSize
                                                                .shrinkWrap,
                                                        padding:
                                                            const EdgeInsets.symmetric(
                                                              horizontal: 8,
                                                              vertical: 4,
                                                            ),
                                                      ),
                                                      onPressed: effectiveBusy
                                                          ? null
                                                          : () =>
                                                                _handleSingleExport(
                                                                  item,
                                                                ),
                                                      child: const Text('导出'),
                                                    ),
                                                  TextButton(
                                                    key: Key(
                                                      'backup_history_delete_${item.fileName}',
                                                    ),
                                                    style: TextButton.styleFrom(
                                                      visualDensity:
                                                          VisualDensity.compact,
                                                      tapTargetSize:
                                                          MaterialTapTargetSize
                                                              .shrinkWrap,
                                                      foregroundColor:
                                                          scheme.error,
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                            horizontal: 8,
                                                            vertical: 4,
                                                          ),
                                                    ),
                                                    onPressed: effectiveBusy
                                                        ? null
                                                        : () =>
                                                              _handleSingleDelete(
                                                                item,
                                                              ),
                                                    child: const Text('删除'),
                                                  ),
                                                ],
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                      const SizedBox(height: 4),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                validSelected.isEmpty
                                    ? '勾选文件可批量清理'
                                    : '已选 ${validSelected.length} 份备份',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: validSelected.isEmpty
                                      ? scheme.onSurfaceVariant
                                      : scheme.onSurface,
                                  fontWeight: validSelected.isEmpty
                                      ? null
                                      : FontWeight.w600,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            FilledButton.icon(
                              key: const Key(
                                'backup_history_batch_delete_button',
                              ),
                              style: validSelected.isEmpty
                                  ? null
                                  : FilledButton.styleFrom(
                                      backgroundColor: scheme.error,
                                      foregroundColor: scheme.onError,
                                    ),
                              onPressed:
                                  !effectiveBusy && validSelected.isNotEmpty
                                  ? () => _handleBatchDelete(validSelected)
                                  : null,
                              icon: const Icon(
                                Icons.delete_sweep_outlined,
                                size: 18,
                              ),
                              label: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  '删除已选 (${validSelected.length})',
                                  maxLines: 1,
                                  softWrap: false,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
