import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/failure.dart';
import '../../data/migration/cross_migration_service.dart';
import '../../domain/rules/ios_migration_rules.dart';
import '../../platform/files.dart';
import '../common/common.dart';
import '../reminder/reminder_providers.dart';
import 'migration_providers.dart';

/// Cross-platform iOS migration (`.ya2i` export / `.yi2a` import) and LAN
/// `ServerBackup.zip` / `.db` restore page (`F-035`, `docs/modules/ios-migration.md`).
class MigrationPage extends ConsumerStatefulWidget {
  const MigrationPage({super.key, this.initialSharedYi2a});

  /// Optional `.yi2a` payload received from an external app share intent (§1.2).
  final SelectedBytes? initialSharedYi2a;

  @override
  ConsumerState<MigrationPage> createState() => _MigrationPageState();
}

class _MigrationPageState extends ConsumerState<MigrationPage> {
  final CommandIds _commandIds = CommandIds();
  bool _busy = false;
  bool _handledInitialShare = false;
  String? _statusMessage;
  bool _statusIsError = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialSharedYi2a != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _handledInitialShare) return;
        _handledInitialShare = true;
        unawaited(_handleSharedYi2a(widget.initialSharedYi2a!));
      });
    }
  }

  void _setStatus(String message, {required bool isError}) {
    if (!mounted) return;
    setState(() {
      _statusMessage = message;
      _statusIsError = isError;
    });
  }

  void _refreshProviders() {
    ref
      ..invalidate(migrationLocalSummaryProvider)
      ..invalidate(booksProvider)
      ..invalidate(currentBookIdProvider)
      ..invalidate(assetsProvider)
      ..invalidate(assetBooksProvider)
      ..invalidate(currenciesProvider)
      ..invalidate(remindersProvider)
      ..invalidate(reminderCountProvider);
  }

  Future<void> _exportYa2i({required bool share}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final service = await ref.read(crossMigrationServiceProvider.future);
      final fileAccess = ref.read(migrationFileAccessProvider);
      final bytes = await service.exportYa2iBytes();

      if (share) {
        if (fileAccess.shareCapability.state == CapabilityState.available) {
          await fileAccess.shareBytes(
            defaultYa2iExportFileName,
            bytes,
            mimeType: 'application/json',
            subject: '帐屿跨端迁移文件 (.ya2i)',
          );
          _setStatus('已生成 $defaultYa2iExportFileName 并调起系统分享', isError: false);
          return;
        }
      }

      await fileAccess.saveBytes(
        defaultYa2iExportFileName,
        bytes,
        mimeType: 'application/json',
      );
      _setStatus(
        '已导出跨端迁移文件 $defaultYa2iExportFileName（${bytes.length} 字节）',
        isError: false,
      );
    } on Failure catch (f) {
      if (f.code == FailureCode.cancelled) return;
      _setStatus(f.message, isError: true);
    } catch (e) {
      _setStatus(safeMessage(e), isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handleSharedYi2a(SelectedBytes selected) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final service = await ref.read(crossMigrationServiceProvider.future);
      final preview = service.preflightYi2a(
        fileName: selected.name,
        bytes: selected.bytes,
      );
      if (!mounted) return;
      await _confirmAndApplyPreview(
        service: service,
        preview: preview,
        dialogKey: const Key('yi2a_confirm_dialog'),
      );
    } on Failure catch (f) {
      if (f.code == FailureCode.cancelled) return;
      _setStatus(f.message, isError: true);
    } catch (e) {
      _setStatus(safeMessage(e), isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickAndImportYi2a() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final fileAccess = ref.read(migrationFileAccessProvider);
      final selected = await fileAccess.pickBytes();
      final service = await ref.read(crossMigrationServiceProvider.future);
      final preview = service.preflightYi2a(
        fileName: selected.name,
        bytes: selected.bytes,
      );
      if (!mounted) return;
      await _confirmAndApplyPreview(
        service: service,
        preview: preview,
        dialogKey: const Key('yi2a_confirm_dialog'),
      );
    } on Failure catch (f) {
      if (f.code == FailureCode.cancelled) return;
      _setStatus(f.message, isError: true);
    } catch (e) {
      _setStatus(safeMessage(e), isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickAndRestoreLanBackup() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final fileAccess = ref.read(migrationFileAccessProvider);
      final selected = await fileAccess.pickBytes(
        allowedExtensions: const ['zip', 'db', 'sqlite', 'sqlite3'],
      );
      final service = await ref.read(crossMigrationServiceProvider.future);
      final outcome = await service.inspectLanBackup(
        fileName: selected.name,
        bytes: selected.bytes,
      );
      if (!mounted) return;

      MigrationPreview? preview;
      switch (outcome) {
        case LanInspectReady(:final preview):
          await _confirmAndApplyPreview(
            service: service,
            preview: preview,
            dialogKey: const Key('lan_confirm_dialog'),
          );
          return;
        case LanInspectPasswordRequired():
        case LanInspectWrongPassword():
          preview = await showDialog<MigrationPreview>(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => _LanPasswordDialog(
              fileName: selected.name,
              archiveBytes: selected.bytes,
              service: service,
            ),
          );
      }

      if (preview == null || !mounted) return;
      await _confirmAndApplyPreview(
        service: service,
        preview: preview,
        dialogKey: const Key('lan_confirm_dialog'),
      );
    } on Failure catch (f) {
      if (f.code == FailureCode.cancelled) return;
      _setStatus(f.message, isError: true);
    } catch (e) {
      _setStatus(safeMessage(e), isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmAndApplyPreview({
    required CrossMigrationService service,
    required MigrationPreview preview,
    required Key dialogKey,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) =>
          _MigrationConfirmDialog(key: dialogKey, preview: preview),
    );
    if (confirmed != true || !mounted) return;

    final commandId = _commandIds.forPayload([
      preview.sourceKind.name,
      preview.fileName,
      preview.totalEntityCount,
      preview.recordCount,
      preview.assetCount,
    ]);
    final applied = await service.applyMigrationPayload(
      commandId: commandId,
      payload: preview.payload,
    );
    _refreshProviders();
    final kindLabel = preview.sourceKind == MigrationSourceKind.yi2a
        ? 'iOS 跨端迁移导入完成'
        : '局域网备份恢复完成';
    _setStatus(
      '$kindLabel：共恢复 ${applied.bookCount} 个账本、${applied.assetCount} 个账户、${applied.recordCount} 条账单',
      isError: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final summaryAsync = ref.watch(migrationLocalSummaryProvider);
    final theme = Theme.of(context);

    return Scaffold(
      key: const Key('migration_page'),
      appBar: AppBar(title: const Text('跨端迁移与局域网恢复')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: LinearProgressIndicator(
                key: Key('migration_progress_bar'),
              ),
            ),
          if (_statusMessage != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Card(
                key: const Key('migration_status_banner'),
                color: _statusIsError
                    ? theme.colorScheme.errorContainer
                    : theme.colorScheme.secondaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Icon(
                        _statusIsError
                            ? Icons.error_outline
                            : Icons.check_circle_outline,
                        color: _statusIsError
                            ? theme.colorScheme.onErrorContainer
                            : theme.colorScheme.onSecondaryContainer,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _statusMessage!,
                          key: const Key('migration_status_text'),
                          style: TextStyle(
                            color: _statusIsError
                                ? theme.colorScheme.onErrorContainer
                                : theme.colorScheme.onSecondaryContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          summaryAsync.when(
            data: (summary) => Card(
              key: const Key('migration_local_summary_card'),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('当前本地数据概况', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Text(
                      '账本 ${summary.bookCount} · 账户 ${summary.assetCount} · 账单 ${summary.recordCount} · 便签 ${summary.noteCount}',
                      key: const Key('migration_local_summary_text'),
                    ),
                  ],
                ),
              ),
            ),
            loading: () => const SizedBox.shrink(),
            error: (_, _) => const SizedBox.shrink(),
          ),
          const SizedBox(height: 12),

          // 1. Export `.ya2i` to iOS
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('导出数据到 iOS (.ya2i)', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 6),
                  const Text(
                    '生成标准无加密 UTF-8 跨端迁移文件（完整包含 19 类账本、账户、账单、专属资产关联与统计故事数据），无需登录且完全免费开放。',
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        key: const Key('export_ya2i_save_button'),
                        onPressed: _busy
                            ? null
                            : () => _exportYa2i(share: false),
                        icon: const Icon(Icons.download_outlined),
                        label: const Text('导出 .ya2i 文件'),
                      ),
                      OutlinedButton.icon(
                        key: const Key('export_ya2i_share_button'),
                        onPressed: _busy
                            ? null
                            : () => _exportYa2i(share: true),
                        icon: const Icon(Icons.ios_share_outlined),
                        label: const Text('导出并分享到 iOS'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // 2. Import `.yi2a` from iOS
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '从 iOS 导入数据 (.yi2a)',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '导入前自动执行非空与短键结构预检，并在单事务内原子替换 19 张跨端业务表；本地便签、汇率与自动映射规则将完整保留。',
                  ),
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                    key: const Key('import_yi2a_button'),
                    onPressed: _busy ? null : _pickAndImportYi2a,
                    icon: const Icon(Icons.file_open_outlined),
                    label: const Text('选择 .yi2a 迁移文件'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // 3. Restore LAN `ServerBackup.zip` / `.db`
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '从局域网备份恢复 (ServerBackup.zip / .db)',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '支持局域网传输生成的 ServerBackup.zip（含 AES-256 历史兼容口令与自定义密码解密）及裸 SQLite .db 数据库恢复。',
                  ),
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                    key: const Key('restore_lan_backup_button'),
                    onPressed: _busy ? null : _pickAndRestoreLanBackup,
                    icon: const Icon(Icons.folder_zip_outlined),
                    label: const Text('选择局域网备份 (.zip / .db)'),
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

class _MigrationConfirmDialog extends StatelessWidget {
  const _MigrationConfirmDialog({super.key, required this.preview});

  final MigrationPreview preview;

  @override
  Widget build(BuildContext context) {
    final isYi2a = preview.sourceKind == MigrationSourceKind.yi2a;
    final title = isYi2a ? '确认导入 iOS 迁移数据' : '确认恢复局域网备份';

    return AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('文件：${preview.fileName}'),
          if (!isYi2a && preview.entryName != preview.fileName)
            Text('数据库条目：${preview.entryName}'),
          if (preview.usedHistoricalPassword) const Text('解密状态：已自动匹配原版历史加密口令'),
          const SizedBox(height: 10),
          Text(
            '预检概况：账本 ${preview.bookCount} 个、账户 ${preview.assetCount} 个、账单 ${preview.recordCount} 条',
            key: const Key('migration_preview_counts'),
          ),
          if (preview.assetBookRefCount > 0 || preview.statStoryCount > 0)
            Text(
              '附加关联：专属资产关联 ${preview.assetBookRefCount} 条、统计故事 ${preview.statStoryCount} 条',
              key: const Key('migration_preview_extra_counts'),
            ),
          const SizedBox(height: 10),
          Text(
            isYi2a
                ? '确认后将在单一数据库事务内替换 19 张跨端业务表（若异常立即完整回滚），本地已有的便签、汇率与自动映射规则不会被清空。'
                : '确认后将在单一数据库事务内恢复账本数据；若执行异常将完整回滚保护现有数据。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const Key('migration_confirm_cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('migration_confirm_submit'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('确认恢复'),
        ),
      ],
    );
  }
}

class _LanPasswordDialog extends StatefulWidget {
  const _LanPasswordDialog({
    required this.fileName,
    required this.archiveBytes,
    required this.service,
  });

  final String fileName;
  final Uint8List archiveBytes;
  final CrossMigrationService service;

  @override
  State<_LanPasswordDialog> createState() => _LanPasswordDialogState();
}

class _LanPasswordDialogState extends State<_LanPasswordDialog> {
  final TextEditingController _passwordController = TextEditingController();
  bool _submitting = false;
  bool _obscure = true;
  String? _errorText;

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final password = _passwordController.text;
    if (password.isEmpty) {
      setState(() => _errorText = '请输入备份压缩包密码');
      return;
    }

    setState(() {
      _submitting = true;
      _errorText = null;
    });

    try {
      final outcome = await widget.service.inspectLanBackup(
        fileName: widget.fileName,
        bytes: widget.archiveBytes,
        password: password,
      );
      if (!mounted) return;

      switch (outcome) {
        case LanInspectReady(:final preview):
          Navigator.of(context).pop(preview);
        case LanInspectWrongPassword():
          setState(() {
            _submitting = false;
            _errorText = '密码错误或加密校验未通过，请重新输入';
          });
        case LanInspectPasswordRequired():
          setState(() {
            _submitting = false;
            _errorText = '请输入有效的解密密码';
          });
      }
    } on Failure catch (f) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _errorText = f.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _errorText = safeMessage(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const Key('lan_password_dialog'),
    title: const Text('输入局域网备份密码'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('备份包 ${widget.fileName} 使用了自定义加密口令，请输入密码解密：'),
        const SizedBox(height: 12),
        TextField(
          key: const Key('lan_password_input'),
          controller: _passwordController,
          obscureText: _obscure,
          autofocus: true,
          enabled: !_submitting,
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            labelText: '解密密码',
            errorText: _errorText,
            suffixIcon: IconButton(
              key: const Key('lan_password_toggle_visibility'),
              onPressed: () => setState(() => _obscure = !_obscure),
              icon: Icon(
                _obscure
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
              ),
            ),
          ),
        ),
      ],
    ),
    actions: [
      TextButton(
        key: const Key('lan_password_cancel'),
        onPressed: _submitting ? null : () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const Key('lan_password_submit'),
        onPressed: _submitting ? null : _submit,
        child: const Text('解密并预检'),
      ),
    ],
  );
}
