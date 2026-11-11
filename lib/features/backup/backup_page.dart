import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/failure.dart';
import '../../data/backup/webdav_client.dart';
import '../../domain/rules/tally_backup.dart';
import '../../platform/files.dart';
import '../common/common.dart';
import 'backup_providers.dart';
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
      unawaited(_checkSilentAutoBackup());
    }
  }

  Future<void> _checkSilentAutoBackup() async {
    try {
      final service = await ref.read(tallyBackupServiceProvider.future);
      final uploaded = await service.runSilentAutoBackupIfNeeded();
      if (uploaded != null && mounted) {
        ref.invalidate(webDavBackupsProvider);
        ref.invalidate(lastBackupAtMsProvider);
      }
    } catch (_) {
      // Silent background check never interrupts foreground workflow.
    }
  }

  void _refreshAfterBackupChange() {
    ref.invalidate(localBackupsProvider);
    ref.invalidate(webDavBackupsProvider);
    ref.invalidate(lastBackupAtMsProvider);
  }

  void _refreshAfterRestore() {
    _refreshAfterBackupChange();
    ref.invalidate(currentBookIdProvider);
    ref.invalidate(booksProvider);
    ref.invalidate(assetsProvider);
    ref.invalidate(currenciesProvider);
    ref.invalidate(tagsProvider);
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
    } catch (e) {
      _showMessage(safeMessage(e));
    }
  }

  Future<void> _toggleAutoBackup(bool value) async {
    try {
      final service = await ref.read(tallyBackupServiceProvider.future);
      await service.setAutoBackupEnabled(value);
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
      _showMessage('WebDAV 配置已更新');
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

  Future<void> _handleWebDavUpload() async {
    setState(() {
      _busy = true;
      _progressLabel = '正在上传至 WebDAV…';
      _transferredBytes = 0;
      _totalBytes = 0;
    });
    try {
      final service = await ref.read(tallyBackupServiceProvider.future);
      final uploaded = await service.uploadBackupToWebDav(
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

  Future<void> _handleRestoreWebDavItem(BackupFileMetadata item) async {
    final ok = await confirm(
      context,
      title: '确认从 WebDAV 恢复？',
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
      final manifest = await service.restoreWebDavBackup(
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

  Future<void> _handleDeleteWebDavItem(BackupFileMetadata item) async {
    final ok = await confirm(
      context,
      title: '删除远端备份？',
      message: '确认从 WebDAV 服务器删除「${item.fileName}」？',
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
      await service.deleteWebDavBackup(item.fileName);
      ref.invalidate(webDavBackupsProvider);
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

  @override
  Widget build(BuildContext context) {
    final configAsync = ref.watch(webDavConfigProvider);
    final localListAsync = ref.watch(localBackupsProvider);
    final remoteListAsync = ref.watch(webDavBackupsProvider);
    final lastBackupAsync = ref.watch(lastBackupAtMsProvider);
    final fileAccess = ref.watch(backupFileAccessProvider);

    final config = configAsync.maybeWhen(
      data: (c) => c,
      orElse: WebDavConfig.unconfigured,
    );
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
      appBar: AppBar(title: const Text('备份与恢复')),
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
                          leading: const Icon(Icons.shield_outlined),
                          title: const Text('备份导出模式'),
                          subtitle: Text(lastBackupText),
                        ),
                        SwitchListTile(
                          key: const Key('include_attachments_switch'),
                          title: const Text('完整备份（包含账单图片附件）'),
                          subtitle: Text(
                            config.includeAttachments
                                ? '打包全部 22 张业务表及原图附件并写入 SHA-256 校验清单'
                                : '纯数据轻量备份（仅打包 22 张业务表，不含图片附件）',
                          ),
                          value: config.includeAttachments,
                          onChanged: _busy ? null : _toggleIncludeAttachments,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
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
                  const SizedBox(height: 16),
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
                                  'WebDAV 私有云备份',
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                              ),
                              Chip(
                                key: const Key('webdav_status_badge'),
                                label: Text(config.capability.reason),
                                visualDensity: VisualDensity.compact,
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            config.isConfigured
                                ? '${config.serverUrl} · 目录 ${config.remoteDirectory} · 保留最近 ${config.keepCount} 份'
                                : '支持坚果云、Nextcloud 或自建 WebDAV，两阶段安全上传，无任何账号或会员限制。',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              OutlinedButton.icon(
                                key: const Key('open_webdav_config_button'),
                                onPressed: _busy
                                    ? null
                                    : () => _openWebDavConfig(config),
                                icon: const Icon(Icons.settings_outlined),
                                label: Text(
                                  config.isConfigured ? '修改配置' : '配置 WebDAV',
                                ),
                              ),
                              FilledButton.icon(
                                key: const Key('webdav_backup_now_button'),
                                onPressed: !_busy && config.isConfigured
                                    ? _handleWebDavUpload
                                    : null,
                                icon: const Icon(Icons.cloud_upload_outlined),
                                label: const Text('立即云端备份'),
                              ),
                              if (config.isConfigured)
                                OutlinedButton.icon(
                                  key: const Key('webdav_refresh_button'),
                                  onPressed: _busy
                                      ? null
                                      : () => ref.invalidate(
                                          webDavBackupsProvider,
                                        ),
                                  icon: const Icon(Icons.refresh),
                                  label: const Text('刷新列表'),
                                ),
                            ],
                          ),
                          if (config.isConfigured) ...[
                            const SizedBox(height: 8),
                            SwitchListTile(
                              key: const Key('auto_backup_switch'),
                              contentPadding: EdgeInsets.zero,
                              title: const Text('自动静默云备份'),
                              subtitle: const Text(
                                '距上次备份满 24 小时且本地有新账单变动时自动上传',
                              ),
                              value: config.autoBackupEnabled,
                              onChanged: _busy ? null : _toggleAutoBackup,
                            ),
                          ],
                          const Divider(height: 24),
                          if (!config.isConfigured)
                            const Padding(
                              key: Key('webdav_unconfigured_hint'),
                              padding: EdgeInsets.symmetric(vertical: 8),
                              child: Text('WebDAV 未配置，请点击「配置 WebDAV」接入私有云目录。'),
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
                                          '${formatDateTime(DateTime.fromMillisecondsSinceEpoch(item.modifiedAtMs))} · ${_formatSize(item.sizeBytes)}',
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
                                                        _handleRestoreWebDavItem(
                                                          item,
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
                                                        _handleDeleteWebDavItem(
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
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
