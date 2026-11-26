import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/adaptive.dart';
import '../../app/providers.dart';
import '../../core/failure.dart';
import '../../data/csv_import/csv_excel_service.dart';
import '../../data/db/database.dart';
import '../../domain/rules/csv_excel_rules.dart';
import '../../platform/files.dart';
import '../common/common.dart';
import '../common/desktop_modal_page.dart';
import '../me/me_page.dart' show MeEmbeddedNavigationScope;
import 'csv_export_page.dart';
import 'csv_transfer_providers.dart';
import 'import_batches_page.dart';

typedef CsvPickCallback = Future<SelectedBytes> Function();

class CsvImportPage extends ConsumerStatefulWidget {
  const CsvImportPage({
    this.initialFile,
    this.pickFile,
    this.saveFile,
    super.key,
  });

  final SelectedBytes? initialFile;
  final CsvPickCallback? pickFile;
  final CsvSaveCallback? saveFile;

  @override
  ConsumerState<CsvImportPage> createState() => _CsvImportPageState();
}

class _CsvImportPageState extends ConsumerState<CsvImportPage> {
  final _commandIds = CommandIds();

  SelectedBytes? _selectedFile;
  CsvImportPreview? _preview;
  String? _parseError;
  int? _selectedBookId;
  bool _restoreFileBooks = true;
  bool _autoCreateMissingAccounts = false;
  bool _loadingPreview = false;
  bool _committing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final pending = ref.read(pendingCsvImportFileProvider.notifier).consume();
      final initial = widget.initialFile ?? pending;
      if (initial != null) {
        unawaited(_previewSelectedFile(initial));
      }
    });
  }

  int? _effectiveBookId(List<AccountBook> books, int? currentBookId) {
    if (books.isEmpty) return null;
    final ids = <int>{for (final b in books) b.id};
    if (_selectedBookId != null && ids.contains(_selectedBookId)) {
      return _selectedBookId;
    }
    if (currentBookId != null && ids.contains(currentBookId)) {
      return currentBookId;
    }
    return books.first.id;
  }

  Future<void> _pickAndPreview() async {
    if (_loadingPreview || _committing) return;
    try {
      final pickFn = widget.pickFile;
      final selected = pickFn != null
          ? await pickFn()
          : await ref
                .read(csvFileAccessProvider)
                .pickBytes(
                  allowedExtensions: const [
                    'csv',
                    'xlsx',
                    'xls',
                    'json',
                    'zip',
                  ],
                );
      if (!mounted) return;
      await _previewSelectedFile(selected);
    } on Failure catch (f) {
      if (f.code == FailureCode.cancelled || !mounted) return;
      setState(() {
        _preview = null;
        _parseError = f.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _preview = null;
        _parseError = safeMessage(e);
      });
    }
  }

  Future<void> _previewSelectedFile(
    SelectedBytes file, {
    bool? autoCreateOverride,
  }) async {
    setState(() {
      _selectedFile = file;
      _loadingPreview = true;
      _parseError = null;
    });
    try {
      final service = await ref.read(csvExcelServiceProvider.future);
      final ledgerQ = await ref.read(queriesProvider.future);
      final books = await ledgerQ.getBooks();
      final currentBookId = await ledgerQ.getCurrentBookId();
      final targetBookId = _effectiveBookId(books, currentBookId);

      final preview = await service.previewImport(
        fileName: file.name,
        bytes: file.bytes,
        targetBookId: targetBookId,
        autoCreateMissingAccounts: autoCreateOverride,
      );
      if (!mounted) return;
      setState(() {
        _preview = preview;
        if (autoCreateOverride == null) {
          _restoreFileBooks = preview.hasBookColumn;
          _autoCreateMissingAccounts = preview.defaultAutoCreateAccounts;
        } else {
          _autoCreateMissingAccounts = autoCreateOverride;
        }
        _selectedBookId ??= targetBookId;
      });
    } on Failure catch (f) {
      if (!mounted) return;
      setState(() {
        _preview = null;
        _parseError = f.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _preview = null;
        _parseError = safeMessage(e);
      });
    } finally {
      if (mounted) setState(() => _loadingPreview = false);
    }
  }

  void _onToggleAutoCreateAccounts(bool value) {
    if (_loadingPreview || _committing) return;
    final file = _selectedFile;
    if (file != null) {
      unawaited(_previewSelectedFile(file, autoCreateOverride: value));
    } else {
      setState(() => _autoCreateMissingAccounts = value);
    }
  }

  Future<void> _downloadTemplateV3() async {
    if (_loadingPreview || _committing) return;
    try {
      final bytes = generateOfficialTemplateV3Bytes();
      final saveFn = widget.saveFile;
      if (saveFn != null) {
        await saveFn('template3.csv', bytes);
      } else {
        await ref
            .read(csvFileAccessProvider)
            .saveBytes('template3.csv', bytes, mimeType: 'text/csv');
      }
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('导入模板 template3.csv 已保存')));
    } on Failure catch (f) {
      if (f.code == FailureCode.cancelled || !mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(f.message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

  Future<void> _commitImport(int targetBookId) async {
    final preview = _preview;
    if (preview == null ||
        preview.validRows.isEmpty ||
        _committing ||
        _loadingPreview) {
      return;
    }

    setState(() => _committing = true);
    try {
      final service = await ref.read(csvExcelServiceProvider.future);
      final cmdId = _commandIds.forPayload([
        preview.fileName,
        preview.platformName,
        preview.totalRecordCount,
        preview.validRows.length,
        targetBookId,
        _restoreFileBooks,
        _autoCreateMissingAccounts,
      ]);
      final result = await service.commitImport(
        commandId: cmdId,
        preview: preview,
        selectedBookId: targetBookId,
        restoreFileBooks: _restoreFileBooks,
        autoCreateMissingAccounts: _autoCreateMissingAccounts,
      );
      if (!mounted) return;
      setState(() {
        _preview = null;
        _selectedFile = null;
        _parseError = null;
      });
      final extraSummary = <String>[
        if (result.createdBookCount > 0) '新建账本 ${result.createdBookCount} 个',
        if (result.createdAccountCount > 0)
          '新建账户 ${result.createdAccountCount} 个',
      ];
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '成功导入 ${result.importedBillCount} 笔账单'
            '${extraSummary.isNotEmpty ? '（${extraSummary.join('，')}）' : ''}',
          ),
          action: SnackBarAction(label: '导入记录', onPressed: _openImportBatches),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    } finally {
      if (mounted) setState(() => _committing = false);
    }
  }

  void _openImportBatches() {
    if (!mounted) return;
    final route = ModalRoute.of(context);
    final isPopupModal = route is PopupRoute;
    final isImperativeRoute = route != null && route.settings is! Page;
    final meScope = (isPopupModal || isImperativeRoute)
        ? null
        : MeEmbeddedNavigationScope.maybeOf(context);
    if (meScope != null) {
      meScope.onSelectRoute('/import/batches');
      return;
    }
    if (isPopupModal || isImperativeRoute) {
      unawaited(
        pushDesktopModalOrMaterialRoute<void>(
          context,
          child: const ImportBatchesPage(),
        ),
      );
      return;
    }
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const ImportBatchesPage()));
  }

  void _openCsvExport() {
    if (!mounted) return;
    final route = ModalRoute.of(context);
    final isPopupModal = route is PopupRoute;
    final isImperativeRoute = route != null && route.settings is! Page;
    final meScope =
        (isPopupModal || isImperativeRoute || widget.saveFile != null)
        ? null
        : MeEmbeddedNavigationScope.maybeOf(context);
    if (meScope != null) {
      meScope.onSelectRoute('/export/csv');
      return;
    }
    final exportPage = CsvExportPage(saveFile: widget.saveFile);
    if (isPopupModal || isImperativeRoute) {
      unawaited(
        pushDesktopModalOrMaterialRoute<void>(context, child: exportPage),
      );
      return;
    }
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => exportPage));
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = DesktopAdaptive.isDesktop(context);
    final booksAsync = ref.watch(booksProvider);
    final currentBookId = ref.watch(currentBookIdProvider).value;
    final busy = _loadingPreview || _committing;

    return Scaffold(
      key: const Key('csv_import_page'),
      appBar: AppBar(
        titleSpacing: isDesktop ? null : 8,
        title: isDesktop
            ? const Text('表格账单导入与导出')
            : const FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text('表格账单导入与导出', maxLines: 1, softWrap: false),
              ),
        actions: [
          TallySoftButton.icon(
            key: const Key('open_csv_export_button'),
            compact: true,
            padding: isDesktop
                ? null
                : const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            minimumSize: isDesktop ? null : const Size(0, 32),
            onPressed: _openCsvExport,
            icon: Icon(Icons.upload_file_outlined, size: isDesktop ? 18 : 15),
            label: const Text('导出 CSV', maxLines: 1, softWrap: false),
          ),
          const SizedBox(width: 6),
          TallySoftButton.icon(
            key: const Key('open_import_batches_button'),
            compact: true,
            padding: isDesktop
                ? null
                : const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            minimumSize: isDesktop ? null : const Size(0, 32),
            onPressed: _openImportBatches,
            icon: Icon(Icons.history, size: isDesktop ? 18 : 15),
            label: const Text('导入记录', maxLines: 1, softWrap: false),
          ),
          SizedBox(width: isDesktop ? 8 : 6),
        ],
      ),
      body: asyncBody(booksAsync, (books) {
        final targetBookId = _effectiveBookId(books, currentBookId);
        final preview = _preview;

        final list = ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              margin: EdgeInsets.symmetric(vertical: 4),
              elevation: 0,
              surfaceTintColor: Colors.transparent,
              clipBehavior: Clip.antiAlias,
              shape: _tonalCardShape,
              color: _tonalCardColor(Theme.of(context)),

              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '微信支付、支付宝与标准 CSV / Excel 账单导入',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '支持 .csv、.xlsx、.xls、.json、.zip 格式（单文件最大 64MB），'
                      '自动识别 UTF-8 / GBK / UTF-16LE 编码及内嵌/压缩包账单图片。'
                      '导入后可在「导入记录」中随时一键撤销整个批次。',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: TallySoftButton.icon(
                            key: const Key('pick_import_file_button'),
                            onPressed: busy ? null : _pickAndPreview,
                            icon: const Icon(
                              Icons.folder_open_outlined,
                              size: 18,
                            ),
                            label: const FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                '选择账单文件',
                                maxLines: 1,
                                softWrap: false,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TallySoftButton.icon(
                            key: const Key('export_template_v3_button'),
                            onPressed: busy ? null : _downloadTemplateV3,
                            icon: const Icon(
                              Icons.description_outlined,
                              size: 18,
                            ),
                            label: const FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                '下载标准模板',
                                maxLines: 1,
                                softWrap: false,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (_loadingPreview) ...[
              const SizedBox(height: 24),
              const Loading(),
            ],
            if (_parseError != null) ...[
              const SizedBox(height: 16),
              Card(
                margin: EdgeInsets.symmetric(vertical: 4),
                elevation: 0,
                surfaceTintColor: Colors.transparent,
                clipBehavior: Clip.antiAlias,
                shape: _tonalCardShape,
                key: const Key('import_error_banner'),
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.error_outline,
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _parseError!,
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onErrorContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (preview != null) ...[
              const SizedBox(height: 16),
              _PreviewCard(
                preview: preview,
                books: books,
                targetBookId: targetBookId,
                restoreFileBooks: _restoreFileBooks,
                autoCreateMissingAccounts: _autoCreateMissingAccounts,
                busy: busy,
                onBookChanged: (id) => setState(() => _selectedBookId = id),
                onRestoreBooksChanged: (v) =>
                    setState(() => _restoreFileBooks = v),
                onAutoCreateAccountsChanged: _onToggleAutoCreateAccounts,
                onConfirm: targetBookId == null
                    ? null
                    : () => _commitImport(targetBookId),
              ),
            ],
          ],
        );
        if (!isDesktop) return list;
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 780),
            child: list,
          ),
        );
      }),
    );
  }
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({
    required this.preview,
    required this.books,
    required this.targetBookId,
    required this.restoreFileBooks,
    required this.autoCreateMissingAccounts,
    required this.busy,
    required this.onBookChanged,
    required this.onRestoreBooksChanged,
    required this.onAutoCreateAccountsChanged,
    required this.onConfirm,
  });

  final CsvImportPreview preview;
  final List<AccountBook> books;
  final int? targetBookId;
  final bool restoreFileBooks;
  final bool autoCreateMissingAccounts;
  final bool busy;
  final ValueChanged<int> onBookChanged;
  final ValueChanged<bool> onRestoreBooksChanged;
  final ValueChanged<bool> onAutoCreateAccountsChanged;
  final VoidCallback? onConfirm;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final failPreview = preview.failRows.take(50).toList(growable: false);

    return Card(
      margin: EdgeInsets.symmetric(vertical: 4),
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: _tonalCardShape,
      color: _tonalCardColor(Theme.of(context)),
      key: const Key('import_preview_card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '解析预览：${preview.platformName}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              '文件：${preview.fileName}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Chip(label: Text('有效账单 ${preview.validRows.length} 条')),
                Chip(label: Text('失败行 ${preview.failRows.length} 条')),
                if (preview.emptyRowCount > 0)
                  Chip(label: Text('空行 ${preview.emptyRowCount} 行')),
              ],
            ),
            if (preview.possibleDuplicateCount > 0) ...[
              const SizedBox(height: 12),
              Container(
                key: const Key('duplicate_hint_banner'),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '提示：检测到 ${preview.possibleDuplicateCount} 条时间、类型与金额相同的已有账单'
                  '（不会拦截，确认后仍会作为新批次导入）。',
                  style: TextStyle(color: colorScheme.onSecondaryContainer),
                ),
              ),
            ],
            if (preview.unknownAssets.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                key: const Key('unknown_assets_banner'),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  autoCreateMissingAccounts
                      ? '未匹配账户：${preview.unknownAssets.join('、')}\n'
                            '已开启「自动创建缺失账户」，导入时将自动新建对应账户/借贷项目并按流水计算余额。'
                      : '未匹配账户：${preview.unknownAssets.join('、')}\n'
                            '收支账单将以「不选账户」导入（不会自动新建账户或变动余额）；转账缺失/未知账户已归入失败行。',
                  style: TextStyle(color: colorScheme.onTertiaryContainer),
                ),
              ),
            ],
            const SizedBox(height: 16),
            if (books.isNotEmpty && targetBookId != null)
              TallySelectField<int>(
                key: const Key('import_target_book_dropdown'),
                label: preview.hasBookColumn && restoreFileBooks
                    ? '默认回退账本（文件账本列为空时使用）'
                    : '导入目标账本',
                sheetTitle: '选择目标账本',
                value: targetBookId,
                enabled: !busy,
                options: [
                  for (final b in books)
                    TallySelectOption<int>(value: b.id, label: b.name),
                ],
                onChanged: busy ? null : onBookChanged,
              ),
            const SizedBox(height: 8),
            SwitchListTile(
              key: const Key('auto_create_accounts_switch'),
              contentPadding: EdgeInsets.zero,
              title: const Text('自动创建缺失账户'),
              subtitle: const Text('开启后自动新建未匹配的资金/信用账户与借贷对象，并智能匹配银行图标与币种'),
              value: autoCreateMissingAccounts,
              onChanged: busy ? null : onAutoCreateAccountsChanged,
            ),
            if (preview.hasBookColumn) ...[
              SwitchListTile(
                key: const Key('restore_file_books_switch'),
                contentPadding: EdgeInsets.zero,
                title: const Text('按文件内「账本」列还原'),
                subtitle: const Text('开启后按每行账本名归入对应账本（不存在时自动新建）；关闭则全部导入所选目标账本'),
                value: restoreFileBooks,
                onChanged: busy ? null : onRestoreBooksChanged,
              ),
            ],
            if (failPreview.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                '失败行明细（共 ${preview.failRows.length} 条）',
                key: const Key('import_fail_rows_section'),
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              for (final fail in failPreview)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    fail.sheetNo > 1
                        ? '工作表 ${fail.sheetNo} 第 ${fail.rowNo} 行：${fail.reason}'
                        : '第 ${fail.rowNo} 行：${fail.reason}',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: colorScheme.error),
                  ),
                ),
              if (preview.failRows.length > failPreview.length)
                Text(
                  '其余 ${preview.failRows.length - failPreview.length} 条失败记录已省略…',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const Key('confirm_import_button'),
                onPressed: busy || preview.validRows.isEmpty ? null : onConfirm,
                icon: busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_circle_outline),
                label: Text('确认导入 ${preview.validRows.length} 笔有效账单'),
              ),
            ),
          ],
        ),
      ),
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
