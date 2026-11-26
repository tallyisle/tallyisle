import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/adaptive.dart';
import '../../core/failure.dart';
import '../../data/migration/cross_migration_service.dart';
import '../../domain/rules/penny_backup.dart';
import '../../platform/files.dart';
import '../backup/post_restore_refresh.dart';
import '../common/common.dart';
import '../common/desktop_modal_page.dart';
import '../csv_transfer/csv_import_page.dart';
import '../csv_transfer/csv_transfer_providers.dart';
import '../csv_transfer/import_batches_page.dart';
import '../me/me_page.dart' show MeEmbeddedNavigationScope;
import '../penny_import/penny_import_providers.dart';
import 'migration_providers.dart';

enum _YiyuBackupKind { penny, yi2a, lanBackup }

const List<int> _sqliteMagicBytes = <int>[
  0x53,
  0x51,
  0x4C,
  0x69,
  0x74,
  0x65,
  0x20,
  0x66,
  0x6F,
  0x72,
  0x6D,
  0x61,
  0x74,
  0x20,
  0x33,
];

bool _hasBytePrefix(Uint8List bytes, List<int> prefix) {
  if (bytes.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[i] != prefix[i]) return false;
  }
  return true;
}

String _lowercaseFileExtension(String fileName) {
  final trimmed = fileName.trim();
  final dot = trimmed.lastIndexOf('.');
  if (dot < 0 || dot == trimmed.length - 1) return '';
  return trimmed.substring(dot + 1).toLowerCase();
}

_YiyuBackupKind _detectYiyuBackupKind(SelectedBytes selected) {
  final bytes = selected.bytes;
  final ext = _lowercaseFileExtension(selected.name);

  if (_hasBytePrefix(bytes, const <int>[0x59, 0x59, 0x42, 0x4B]) ||
      ext == 'penny' ||
      ext == 'yy') {
    return _YiyuBackupKind.penny;
  }
  if (ext == 'yi2a') {
    return _YiyuBackupKind.yi2a;
  }
  if (ext == 'zip' ||
      ext == 'db' ||
      ext == 'sqlite' ||
      ext == 'sqlite3' ||
      _hasBytePrefix(bytes, const <int>[0x50, 0x4B]) ||
      _hasBytePrefix(bytes, _sqliteMagicBytes)) {
    return _YiyuBackupKind.lanBackup;
  }
  if (ext.isEmpty) {
    var i = 0;
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      i = 3;
    }
    while (i < bytes.length &&
        (bytes[i] == 0x20 ||
            bytes[i] == 0x09 ||
            bytes[i] == 0x0A ||
            bytes[i] == 0x0D)) {
      i++;
    }
    if (i < bytes.length && bytes[i] == 0x7B) {
      return _YiyuBackupKind.yi2a;
    }
  }
  throw const Failure(
    FailureCode.validation,
    '无法识别该备份文件格式，请选择一羽记账 .penny / .yy、.yi2a 或 .zip / .db 备份文件',
  );
}

/// Modular third-party bookkeeping software import hub (`第三方数据导入`):
/// - `一羽记账导入`: 1-step 14/15-column CSV incremental import + unified backup
///   auto-dispatch for `.penny`/`.yy`, `.yi2a` (plus external share intent), and
///   LAN `ServerBackup.zip`/`.db`
/// - `好好记账导入`: 1-step Excel/CSV/ZIP incremental import + `.db` full migration
/// - `钱迹导入`: 1-step CSV/Excel/JSON incremental import
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

  Future<void> _refreshProviders() async {
    await invalidateAllAfterDatabaseReplace(ref);
    ref.invalidate(migrationLocalSummaryProvider);
  }

  Future<void> _runPennyImportFlow({
    required String fileName,
    required Uint8List bytes,
    required int sessionId,
  }) async {
    final service = await ref.read(pennyImportServiceProvider.future);
    final preview = await service.previewPenny(
      fileName: fileName,
      bytes: bytes,
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
    final digest = sha256.convert(bytes).toString();
    final commandId = _commandIds.forPayload([
      'penny-import-ui-v1',
      sessionId,
      fileName,
      digest,
    ]);
    final result = await service.importPenny(
      commandId: commandId,
      fileName: fileName,
      bytes: bytes,
    );
    if (mounted) {
      await _refreshProviders();
    }
    _setStatus(
      '一羽记账 Android 备份导入完成：已切换至「${result.preview.targetBookName}」，共恢复 '
      '${result.preview.bookCount} 个账本、${result.preview.assetCount} 个账户、'
      '${result.preview.recordCount} 条账单',
      isError: false,
    );
  }

  Future<void> _runYi2aImportFlow({
    required SelectedBytes selected,
    required int sessionId,
  }) async {
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
  }

  Future<void> _runLanBackupFlow({
    required SelectedBytes selected,
    required int sessionId,
  }) async {
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
  }

  Future<void> _pickAndImportYiyuBackup() async {
    if (_inFlow) return;
    _inFlow = true;
    final sessionId = ++_pickSession;
    _setBusy(true);
    try {
      final picker = ref.read(pennyFilePickerProvider);
      if (!identical(picker, pickPennyBackupFile)) {
        final picked = await picker();
        if (picked == null || !mounted) return;
        await _runPennyImportFlow(
          fileName: picked.name,
          bytes: picked.bytes,
          sessionId: sessionId,
        );
        return;
      }

      final fileAccess = ref.read(migrationFileAccessProvider);
      final selected = await fileAccess.pickBytes(
        allowedExtensions: const <String>[
          'penny',
          'yy',
          'yi2a',
          'zip',
          'db',
          'sqlite',
          'sqlite3',
        ],
      );
      if (!mounted) return;

      switch (_detectYiyuBackupKind(selected)) {
        case _YiyuBackupKind.penny:
          await _runPennyImportFlow(
            fileName: selected.name,
            bytes: selected.bytes,
            sessionId: sessionId,
          );
        case _YiyuBackupKind.yi2a:
          await _runYi2aImportFlow(selected: selected, sessionId: sessionId);
        case _YiyuBackupKind.lanBackup:
          await _runLanBackupFlow(selected: selected, sessionId: sessionId);
      }
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
      await _runYi2aImportFlow(selected: selected, sessionId: sessionId);
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

  Future<void> _pickAndImportHaohaoDb() async {
    if (_inFlow) return;
    _inFlow = true;
    final sessionId = ++_pickSession;
    _setBusy(true);
    try {
      final fileAccess = ref.read(migrationFileAccessProvider);
      final selected = await fileAccess.pickBytes(
        allowedExtensions: const ['db', 'zip', 'sqlite', 'sqlite3'],
      );
      final service = await ref.read(crossMigrationServiceProvider.future);
      final preview = await service.inspectHaohaoDb(
        fileName: selected.name,
        bytes: selected.bytes,
      );
      if (!mounted) return;
      await _confirmAndApplyPreview(
        service: service,
        preview: preview,
        sessionId: sessionId,
        dialogKey: const Key('haohao_db_confirm_dialog'),
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
    if (mounted) {
      await _refreshProviders();
    }
    final kindLabel = switch (preview.sourceKind) {
      MigrationSourceKind.yi2a => '一羽记账 iOS 迁移包导入完成',
      MigrationSourceKind.haohaoDb => '好好记账数据库整库迁入完成',
      MigrationSourceKind.lanBackup => '一羽记账局域网备份恢复完成',
    };
    _setStatus(
      '$kindLabel：共恢复 ${applied.bookCount} 个账本、${applied.assetCount} 个账户、${applied.recordCount} 条账单',
      isError: false,
    );
  }

  void _navigateToChildPage({required String route, required Widget page}) {
    if (!mounted) return;
    final modalRoute = ModalRoute.of(context);
    final isPopupModal = modalRoute is PopupRoute;
    final isImperativeRoute =
        modalRoute != null && modalRoute.settings is! Page;
    final meScope = (isPopupModal || isImperativeRoute)
        ? null
        : MeEmbeddedNavigationScope.maybeOf(context);
    if (meScope != null) {
      meScope.onSelectRoute(route);
      return;
    }
    if (isPopupModal || isImperativeRoute) {
      unawaited(pushDesktopModalOrMaterialRoute<void>(context, child: page));
      return;
    }
    final router = GoRouter.maybeOf(context);
    if (router != null) {
      unawaited(router.push(route));
      return;
    }
    unawaited(
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page)),
    );
  }

  Future<void> _pickFileAndOpenCsvImport(List<String> allowedExtensions) async {
    if (_inFlow) return;
    _inFlow = true;
    _setBusy(true);
    try {
      final fileAccess = ref.read(migrationFileAccessProvider);
      final selected = await fileAccess.pickBytes(
        allowedExtensions: allowedExtensions,
      );
      if (!mounted) return;
      ref.read(pendingCsvImportFileProvider.notifier).setFile(selected);
      _setBusy(false);
      _navigateToChildPage(
        route: '/import/csv',
        page: CsvImportPage(initialFile: selected),
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

  void _openImportBatches() => _navigateToChildPage(
    route: '/import/batches',
    page: const ImportBatchesPage(),
  );

  @override
  Widget build(BuildContext context) {
    final isDesktop = DesktopAdaptive.isDesktop(context);
    final summaryAsync = ref.watch(migrationLocalSummaryProvider);
    final theme = Theme.of(context);

    final mainColumn = Column(
      children: [
        if (_busy)
          const LinearProgressIndicator(key: Key('migration_progress_bar')),
        if (_statusMessage != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Card(
              elevation: 0,
              surfaceTintColor: Colors.transparent,
              clipBehavior: Clip.antiAlias,
              shape: _tonalCardShape,
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
              // Cross-platform schema unity & third-party import guidance banner
              Card(
                margin: EdgeInsets.symmetric(vertical: 4),
                elevation: 0,
                surfaceTintColor: Colors.transparent,
                clipBehavior: Clip.antiAlias,
                shape: _tonalCardShape,
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
                        '1. 帐屿全平台（Android / iOS / HarmonyOS / Windows / Linux / macOS）数据格式完全一致，'
                        '日常多设备流转请使用「云同步与备份（.tally / WebDAV / S3）」；\n'
                        '2. 本页专用于第三方记账软件与外部平台历史数据迁入'
                        '（全量迁入采用单事务安全替换，并自动保留本机已有便签与自定义汇率）。',
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
                  margin: EdgeInsets.symmetric(vertical: 4),
                  elevation: 0,
                  surfaceTintColor: Colors.transparent,
                  clipBehavior: Clip.antiAlias,
                  shape: _tonalCardShape,
                  color: _tonalCardColor(Theme.of(context)),
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

              // 1. Unified card: 一羽记账导入 (CSV incremental import + unified backup auto-dispatch)
              Card(
                margin: EdgeInsets.symmetric(vertical: 4),
                elevation: 0,
                surfaceTintColor: Colors.transparent,
                clipBehavior: Clip.antiAlias,
                shape: _tonalCardShape,
                color: _tonalCardColor(Theme.of(context)),
                key: const Key('migration_yiyu_import_card'),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('一羽记账导入', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 6),
                      const Text(
                        '支持导出的 14/15 列 CSV 表格增量并入所选账本；'
                        '也支持选择一羽记账 Android (.penny / .yy)、iOS (.yi2a) 或局域网备份 (.zip / .db) 单事务整库迁入，'
                        '完整保留本机便签与自定义汇率。',
                      ),
                      const SizedBox(height: 12),
                      LayoutBuilder(
                        builder: (ctx, constraints) {
                          final sheetBtn = OutlinedButton.icon(
                            key: const Key('migration_open_yiyu_sheet_button'),
                            style: const ButtonStyle(
                              padding: WidgetStatePropertyAll(
                                EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 10,
                                ),
                              ),
                            ),
                            onPressed: _busy
                                ? null
                                : () => _pickFileAndOpenCsvImport(
                                    const <String>['csv', 'xlsx', 'xls'],
                                  ),
                            icon: const Icon(
                              Icons.table_rows_outlined,
                              size: 18,
                            ),
                            label: const FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                'CSV 表格增量导入',
                                maxLines: 1,
                                softWrap: false,
                              ),
                            ),
                          );
                          final backupBtn = FilledButton.icon(
                            key: const Key('migration_pick_yiyu_backup_button'),
                            style: const ButtonStyle(
                              padding: WidgetStatePropertyAll(
                                EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 10,
                                ),
                              ),
                            ),
                            onPressed: _busy ? null : _pickAndImportYiyuBackup,
                            icon: const Icon(Icons.archive_outlined, size: 18),
                            label: const FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                '选择备份整库迁入',
                                maxLines: 1,
                                softWrap: false,
                              ),
                            ),
                          );
                          if (constraints.maxWidth < 460) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                sheetBtn,
                                const SizedBox(height: 8),
                                backupBtn,
                              ],
                            );
                          }
                          return Row(
                            children: [
                              Expanded(child: sheetBtn),
                              const SizedBox(width: 10),
                              Expanded(child: backupBtn),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // 2. Dedicated card: 好好记账导入 (sheet/ZIP incremental import & .db full migration)
              Card(
                margin: EdgeInsets.symmetric(vertical: 4),
                elevation: 0,
                surfaceTintColor: Colors.transparent,
                clipBehavior: Clip.antiAlias,
                shape: _tonalCardShape,
                color: _tonalCardColor(Theme.of(context)),
                key: const Key('migration_haohao_import_card'),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('好好记账导入', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 6),
                      const Text(
                        '支持导出的 Excel/CSV 表格与带图 ZIP 增量并入所选账本；'
                        '也支持选择 account_record*.db 备份文件（或未加密 .zip）单事务整库迁入，'
                        '完整还原账本、信用/借贷账户、二级分类、预算、周期/分期与存钱计划，并保留本机随手记便签。',
                      ),
                      const SizedBox(height: 12),
                      LayoutBuilder(
                        builder: (ctx, constraints) {
                          final sheetBtn = OutlinedButton.icon(
                            key: const Key(
                              'migration_open_haohao_sheet_button',
                            ),
                            style: const ButtonStyle(
                              padding: WidgetStatePropertyAll(
                                EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 10,
                                ),
                              ),
                            ),
                            onPressed: _busy
                                ? null
                                : () => _pickFileAndOpenCsvImport(
                                    const <String>['xlsx', 'xls', 'csv', 'zip'],
                                  ),
                            icon: const Icon(
                              Icons.table_rows_outlined,
                              size: 18,
                            ),
                            label: const FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                '表格 / 带图 ZIP 增量导入',
                                maxLines: 1,
                                softWrap: false,
                              ),
                            ),
                          );
                          final dbBtn = FilledButton.icon(
                            key: const Key('migration_pick_haohao_db_button'),
                            style: const ButtonStyle(
                              padding: WidgetStatePropertyAll(
                                EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 10,
                                ),
                              ),
                            ),
                            onPressed: _busy ? null : _pickAndImportHaohaoDb,
                            icon: const Icon(Icons.storage_outlined, size: 18),
                            label: const FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                '选择 .db 备份整库迁入',
                                maxLines: 1,
                                softWrap: false,
                              ),
                            ),
                          );
                          if (constraints.maxWidth < 460) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                sheetBtn,
                                const SizedBox(height: 8),
                                dbBtn,
                              ],
                            );
                          }
                          return Row(
                            children: [
                              Expanded(child: sheetBtn),
                              const SizedBox(width: 10),
                              Expanded(child: dbBtn),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // 3. Dedicated card: 钱迹导入 (1-step CSV / Excel / JSON incremental import)
              Card(
                margin: EdgeInsets.symmetric(vertical: 4),
                elevation: 0,
                surfaceTintColor: Colors.transparent,
                clipBehavior: Clip.antiAlias,
                shape: _tonalCardShape,
                color: _tonalCardColor(Theme.of(context)),
                key: const Key('migration_qianji_import_card'),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('钱迹导入', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 6),
                      const Text(
                        '支持 CSV / Excel (.xlsx) / JSON 账单增量并入所选账本，'
                        '自动创建缺失账户、精准映射报销/退款/手续费/优惠券，并支持按批次一键撤回。',
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.tonalIcon(
                          key: const Key('migration_open_qianji_import_button'),
                          onPressed: _busy
                              ? null
                              : () => _pickFileAndOpenCsvImport(const <String>[
                                  'csv',
                                  'xlsx',
                                  'xls',
                                  'json',
                                ]),
                          icon: const Icon(
                            Icons.upload_file_outlined,
                            size: 18,
                          ),
                          label: const FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              '导入 CSV / Excel / JSON 账单',
                              maxLines: 1,
                              softWrap: false,
                            ),
                          ),
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
    );

    return Scaffold(
      key: const Key('migration_page'),
      appBar: AppBar(
        titleSpacing: isDesktop ? null : 8,
        title: isDesktop
            ? const Text('第三方数据导入')
            : const FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text('第三方数据导入', maxLines: 1, softWrap: false),
              ),
        actions: [
          TextButton.icon(
            key: const Key('migration_open_import_batches_action'),
            style: isDesktop
                ? null
                : TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
            onPressed: _openImportBatches,
            icon: Icon(Icons.history, size: isDesktop ? 18 : 16),
            label: const Text('导入记录', maxLines: 1, softWrap: false),
          ),
          SizedBox(width: isDesktop ? 8 : 4),
        ],
      ),
      body: isDesktop
          ? Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 780),
                child: mainColumn,
              ),
            )
          : mainColumn,
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
        ? '已过滤 ${preview.filteredTombstoneCount} 条（已删除记录不落库）'
        : '0 条（自动过滤已删除记录）';

    return AlertDialog(
      title: const Text('一羽记账 Android 备份导入预览'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _PreviewRow(label: '备份文件', value: preview.fileName),
            _PreviewRow(label: '来源版本', value: preview.appVersion),
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
                '本机已有的便签与自定义汇率将完整保留，不会被清空。',
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
    final theme = Theme.of(context);
    final isYi2a = preview.sourceKind == MigrationSourceKind.yi2a;
    final isHaohaoDb = preview.sourceKind == MigrationSourceKind.haohaoDb;
    final title = switch (preview.sourceKind) {
      MigrationSourceKind.yi2a => '确认导入一羽记账 iOS 迁移数据',
      MigrationSourceKind.haohaoDb => '确认整库迁入好好记账备份',
      MigrationSourceKind.lanBackup => '确认恢复一羽记账局域网备份',
    };

    return AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('文件：${preview.fileName}'),
            if (!isYi2a && preview.entryName != preview.fileName)
              Text('数据库条目：${preview.entryName}'),
            if (preview.usedHistoricalPassword)
              const Text('解密状态：已自动匹配一羽记账历史默认口令'),
            const SizedBox(height: 10),
            if (isHaohaoDb) ...[
              Text(
                '预检概况：账本 ${preview.bookCount} 个、账户 ${preview.assetCount} 个、'
                '分类 ${preview.categoryCount} 个、账单 ${preview.recordCount} 条、'
                '预算 ${preview.budgetCount} 项、计划 ${preview.planCount} 项',
                key: const Key('migration_preview_counts'),
              ),
              const SizedBox(height: 4),
              Text(
                '明细：分期 ${preview.installmentCount} · 周期 ${preview.periodCount} · '
                '存钱计划 ${preview.savingsPlanCount} · 标签 ${preview.tagCount} · '
                '模板 ${preview.templateCount}',
                key: const Key('haohao_preview_detail_counts'),
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              Container(
                key: const Key('haohao_overwrite_warning'),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '覆盖警告：确认迁入将在单一数据库事务内原子替换本地账本、账户、分类、账单、预算与计划业务表（若异常立即完整回滚）；'
                  '本机已有的「随手记」便签与自定义汇率将完整保留，缺失外币币种会自动补充。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ] else ...[
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
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
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
          child: Text(isHaohaoDb ? '确认整库迁入' : '确认恢复'),
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
  Widget build(BuildContext context) {
    final isDesktop = DesktopAdaptive.isDesktop(context);
    final body = Column(
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
              border: isDesktop ? const OutlineInputBorder() : null,
              contentPadding: isDesktop
                  ? const EdgeInsets.symmetric(horizontal: 12, vertical: 16)
                  : null,
              suffixIcon: IconButton(
                key: const Key('lan_password_toggle_visibility'),
                visualDensity: isDesktop ? VisualDensity.compact : null,
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
    );
    return AlertDialog(
      key: const Key('lan_password_dialog'),
      title: const Text('输入局域网备份密码'),
      content: isDesktop
          ? ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 380, maxWidth: 420),
              child: SingleChildScrollView(child: body),
            )
          : body,
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
}

Color _tonalCardColor(ThemeData theme) {
  final scheme = theme.colorScheme;
  return theme.brightness == Brightness.dark
      ? scheme.surfaceContainerLow
      : Color.lerp(scheme.surfaceContainerLow, scheme.surfaceContainer, 0.55)!;
}

const _tonalCardShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(16)),
);
