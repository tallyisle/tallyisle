import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/failure.dart';
import '../../data/migration/cross_migration_service.dart';
import '../../domain/rules/penny_backup.dart';
import '../../platform/files.dart';
import '../common/common.dart';
import '../penny_import/penny_import_providers.dart';
import '../reminder/reminder_providers.dart';
import 'migration_providers.dart';

/// Unified one-way legacy original-app import page (`F-035`,
/// `docs/modules/ios-migration.md` & `docs/modules/import-original-backup.md`):
/// - Original Android encrypted backup (`.penny` / `.yy`)
/// - Original iOS migration package (`.yi2a`, including external share intent)
/// - Original LAN transfer archive (`ServerBackup.zip` / bare SQLite `.db`)
class MigrationPage extends ConsumerStatefulWidget {
  const MigrationPage({super.key, this.initialSharedYi2a});

  /// Optional `.yi2a` payload received from an external app share intent (§1.3).
  final SelectedBytes? initialSharedYi2a;

  @override
  ConsumerState<MigrationPage> createState() => _MigrationPageState();
}

class _MigrationPageState extends ConsumerState<MigrationPage> {
  final CommandIds _commandIds = CommandIds();
  int _pickSession = 0;
  bool _inFlow = false;
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

  void _setBusy(bool value) {
    if (!mounted || _busy == value) return;
    setState(() => _busy = value);
  }

  void _setStatus(String message, {required bool isError}) {
    if (!mounted) return;
    setState(() {
      _statusMessage = message;
      _statusIsError = isError;
    });
  }

  void _refreshProviders() {
    ref.read(periodOffsetProvider.notifier).reset();
    ref.read(calendarMonthOffsetProvider.notifier).reset();
    ref
      ..invalidate(migrationLocalSummaryProvider)
      ..invalidate(booksProvider)
      ..invalidate(currentBookIdProvider)
      ..invalidate(assetsProvider)
      ..invalidate(assetBooksProvider)
      ..invalidate(currenciesProvider)
      ..invalidate(tagsProvider)
      ..invalidate(remindersProvider)
      ..invalidate(reminderCountProvider);
  }

  Future<PennyPickedFile?> _pickPennyFile() async {
    final picker = ref.read(pennyFilePickerProvider);
    if (!identical(picker, pickPennyBackupFile)) {
      return picker();
    }
    final fileAccess = ref.read(migrationFileAccessProvider);
    try {
      final selected = await fileAccess.pickBytes(
        allowedExtensions: const <String>['penny', 'yy'],
      );
      return PennyPickedFile(name: selected.name, bytes: selected.bytes);
    } on Failure catch (f) {
      if (f.code == FailureCode.cancelled) return null;
      rethrow;
    }
  }

  Future<void> _pickAndImportPenny() async {
    if (_inFlow) return;
    _inFlow = true;
    final sessionId = ++_pickSession;
    _setBusy(true);
    try {
      final picked = await _pickPennyFile();
      if (picked == null || !mounted) return;

      final service = await ref.read(pennyImportServiceProvider.future);
      final preview = await service.previewPenny(
        fileName: picked.name,
        bytes: picked.bytes,
      );
      if (!mounted) return;

      _setBusy(false);
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => _PennyConfirmDialog(
          key: const Key('penny_preview_dialog'),
          preview: preview,
        ),
      );
      if (confirmed != true || !mounted) return;

      _setBusy(true);
      final digest = sha256.convert(picked.bytes).toString();
      final commandId = _commandIds.forPayload([
        'penny-import-ui-v1',
        sessionId,
        picked.name,
        digest,
      ]);
      final result = await service.importPenny(
        commandId: commandId,
        fileName: picked.name,
        bytes: picked.bytes,
      );
      _refreshProviders();
      _setStatus(
        '原版 Android 备份导入完成：已切换至「${result.preview.targetBookName}」，共恢复 '
        '${result.preview.bookCount} 个账本、${result.preview.assetCount} 个账户、'
        '${result.preview.recordCount} 条账单',
        isError: false,
      );
    } on Failure catch (f) {
      if (f.code == FailureCode.cancelled) return;
      _setStatus(f.message, isError: true);
    } catch (e) {
      _setStatus(safeMessage(e), isError: true);
    } finally {
      _inFlow = false;
      _setBusy(false);
    }
  }

  Future<void> _handleSharedYi2a(SelectedBytes selected) async {
    if (_inFlow) return;
    _inFlow = true;
    final sessionId = ++_pickSession;
    _setBusy(true);
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
        sessionId: sessionId,
        dialogKey: const Key('yi2a_confirm_dialog'),
      );
    } on Failure catch (f) {
      if (f.code == FailureCode.cancelled) return;
      _setStatus(f.message, isError: true);
    } catch (e) {
      _setStatus(safeMessage(e), isError: true);
    } finally {
      _inFlow = false;
      _setBusy(false);
    }
  }

  Future<void> _pickAndImportYi2a() async {
    if (_inFlow) return;
    _inFlow = true;
    final sessionId = ++_pickSession;
    _setBusy(true);
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
        sessionId: sessionId,
        dialogKey: const Key('yi2a_confirm_dialog'),
      );
    } on Failure catch (f) {
      if (f.code == FailureCode.cancelled) return;
      _setStatus(f.message, isError: true);
    } catch (e) {
      _setStatus(safeMessage(e), isError: true);
    } finally {
      _inFlow = false;
      _setBusy(false);
    }
  }

  Future<void> _pickAndRestoreLanBackup() async {
    if (_inFlow) return;
    _inFlow = true;
    final sessionId = ++_pickSession;
    _setBusy(true);
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
            sessionId: sessionId,
            dialogKey: const Key('lan_confirm_dialog'),
          );
          return;
        case LanInspectPasswordRequired():
        case LanInspectWrongPassword():
          _setBusy(false);
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
        sessionId: sessionId,
        dialogKey: const Key('lan_confirm_dialog'),
      );
    } on Failure catch (f) {
      if (f.code == FailureCode.cancelled) return;
      _setStatus(f.message, isError: true);
    } catch (e) {
      _setStatus(safeMessage(e), isError: true);
    } finally {
      _inFlow = false;
      _setBusy(false);
    }
  }

  Future<void> _confirmAndApplyPreview({
    required CrossMigrationService service,
    required MigrationPreview preview,
    required int sessionId,
    required Key dialogKey,
  }) async {
    _setBusy(false);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) =>
          _MigrationConfirmDialog(key: dialogKey, preview: preview),
    );
    if (confirmed != true || !mounted) return;

    _setBusy(true);
    final commandId = _commandIds.forPayload([
      preview.sourceKind.name,
      sessionId,
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
        ? '原版 iOS 迁移包导入完成'
        : '原版局域网备份恢复完成';
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
      appBar: AppBar(title: const Text('从旧软件导入')),
      body: Column(
        children: [
          if (_busy)
            const LinearProgressIndicator(key: Key('migration_progress_bar')),
          if (_statusMessage != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Card(
                key: const Key('migration_status_banner'),
                margin: EdgeInsets.zero,
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
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Cross-platform schema unity & legacy-only guidance banner
                Card(
                  key: const Key('migration_unity_banner_card'),
                  color: theme.colorScheme.primaryContainer.withValues(
                    alpha: 0.45,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.devices_outlined,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '全平台数据格式统一说明',
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '• 帐屿各平台（Android / iOS / 桌面 / Web）数据格式 100% 统一，'
                          '日常跨设备请使用「云同步与备份（.tally / WebDAV / S3）」。\n'
                          '• 本页专用于将原版“一羽记账”历史备份一次性迁入帐屿'
                          '（导入时均采用单事务安全替换，并自动保留本机已有便签与自定义汇率）。',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // Local data overview card
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

                // 1. Original Android encrypted backup (`.penny` / `.yy`)
                Card(
                  key: const Key('legacy_import_penny_card'),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '原版 Android 备份导入 (.penny / .yy)',
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          '支持导入原版导出的加密 .penny 备份文件（兼容历史 .yy 备份）。'
                          '独立内存暂存校验并自动过滤软删除墓碑，在单事务内原子替换 20 张账务业务表，完整保留本机便签与自定义汇率。',
                        ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          key: const Key('legacy_import_penny_button'),
                          onPressed: _busy ? null : _pickAndImportPenny,
                          icon: const Icon(Icons.archive_outlined),
                          label: const Text('选择 .penny / .yy 备份文件'),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // 2. Original iOS migration package (`.yi2a`)
                Card(
                  key: const Key('legacy_import_yi2a_card'),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '原版 iOS 迁移包导入 (.yi2a)',
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          '导入前自动执行非空与短键结构预检，并在单事务内原子替换 19 张跨端业务表；'
                          '本机已有的便签、自定义汇率与自动记账规则将完整保留。',
                        ),
                        const SizedBox(height: 12),
                        KeyedSubtree(
                          key: const Key('migration_import_yi2a_button'),
                          child: FilledButton.tonalIcon(
                            key: const Key('import_yi2a_button'),
                            onPressed: _busy ? null : _pickAndImportYi2a,
                            icon: const Icon(Icons.file_open_outlined),
                            label: const Text('选择 .yi2a 迁移文件'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // 3. Original LAN `ServerBackup.zip` / `.db` restore
                Card(
                  key: const Key('legacy_restore_lan_card'),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '原版局域网备份恢复 (ServerBackup.zip / .db)',
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          '支持原版局域网传输生成的 ServerBackup.zip（含 AES-256 历史兼容口令与自定义密码解密）'
                          '及裸 SQLite .db 数据库恢复。',
                        ),
                        const SizedBox(height: 12),
                        KeyedSubtree(
                          key: const Key('migration_restore_lan_button'),
                          child: FilledButton.tonalIcon(
                            key: const Key('restore_lan_backup_button'),
                            onPressed: _busy ? null : _pickAndRestoreLanBackup,
                            icon: const Icon(Icons.folder_zip_outlined),
                            label: const Text('选择局域网备份 (.zip / .db)'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PennyConfirmDialog extends StatelessWidget {
  const _PennyConfirmDialog({super.key, required this.preview});

  final PennyBackupPreview preview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tombstoneText = preview.filteredTombstoneCount > 0
        ? '已过滤 ${preview.filteredTombstoneCount} 条（sstatus=4 软删记录不落库）'
        : '0 条（自动过滤 sstatus=4 软删墓碑）';

    return AlertDialog(
      title: const Text('原版 Android 备份导入预览'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _PreviewRow(label: '备份文件', value: preview.fileName),
            _PreviewRow(label: '原版版本', value: preview.appVersion),
            _PreviewRow(
              label: '账本数量',
              value: '${preview.bookCount} 个（恢复后选中：${preview.targetBookName}）',
            ),
            _PreviewRow(label: '账户资产', value: '${preview.assetCount} 个'),
            _PreviewRow(label: '收支分类', value: '${preview.categoryCount} 个'),
            _PreviewRow(label: '账单流水', value: '${preview.recordCount} 条'),
            _PreviewRow(label: '计划与预算', value: '${preview.totalPlanCount} 项'),
            _PreviewRow(label: '历史备注', value: '${preview.remarkCount} 条'),
            _PreviewRow(label: '软删墓碑过滤', value: tombstoneText),
            const SizedBox(height: 12),
            Container(
              key: const Key('penny_overwrite_warning'),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '覆盖警告：确认恢复将以备份内容在单一数据库事务内替换本地 20 张账务业务表'
                '（账本、账户、分类、账单、预算、分期、周期、存钱计划等）；'
                '本机已有的便签（note）与自定义汇率（currency）将完整保留，不会被清空。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('cancel_penny_import_button'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('confirm_penny_import_button'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('确认恢复'),
        ),
      ],
    );
  }
}

class _PreviewRow extends StatelessWidget {
  const _PreviewRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 96,
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
        Expanded(
          child: Text(value, style: Theme.of(context).textTheme.bodyMedium),
        ),
      ],
    ),
  );
}

class _MigrationConfirmDialog extends StatelessWidget {
  const _MigrationConfirmDialog({super.key, required this.preview});

  final MigrationPreview preview;

  @override
  Widget build(BuildContext context) {
    final isYi2a = preview.sourceKind == MigrationSourceKind.yi2a;
    final title = isYi2a ? '确认导入原版 iOS 迁移数据' : '确认恢复原版局域网备份';

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
                : '确认后将在单一数据库事务内恢复账本数据；若执行异常将完整回滚，且本地已有的便签与自定义汇率不会被清空。',
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
        KeyedSubtree(
          key: const Key('migration_lan_password_input'),
          child: TextField(
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
