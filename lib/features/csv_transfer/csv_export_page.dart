import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/adaptive.dart';
import '../../app/providers.dart';
import '../../core/failure.dart';
import '../../domain/model/codes.dart';
import '../../platform/files.dart';
import '../common/common.dart';
import 'csv_transfer_providers.dart';

typedef CsvSaveCallback =
    Future<void> Function(String suggestedName, Uint8List bytes);

class CsvExportPage extends ConsumerStatefulWidget {
  const CsvExportPage({this.saveFile, this.shareFile, super.key});

  final CsvSaveCallback? saveFile;
  final CsvSaveCallback? shareFile;

  @override
  ConsumerState<CsvExportPage> createState() => _CsvExportPageState();
}

class _CsvExportPageState extends ConsumerState<CsvExportPage> {
  int _selectedBookId = noRef;
  bool _filterByDate = false;
  late DateTime _startDate;
  late DateTime _endDate;
  bool _includeCurrency = true;
  bool _utf8WithBom = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _endDate = DateTime(now.year, now.month, now.day);
    _startDate = DateTime(now.year, now.month, 1);
  }

  Future<void> _pickDate({required bool isStart}) async {
    final initial = isStart ? _startDate : _endDate;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100, 12, 31),
    );
    if (picked == null || !mounted) return;
    setState(() {
      final normalized = DateTime(picked.year, picked.month, picked.day);
      if (isStart) {
        _startDate = normalized;
        if (_startDate.isAfter(_endDate)) {
          _endDate = _startDate;
        }
      } else {
        _endDate = normalized;
        if (_endDate.isBefore(_startDate)) {
          _startDate = _endDate;
        }
      }
    });
  }

  Future<void> _runExport({required bool share}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final service = await ref.read(csvExcelServiceProvider.future);
      final startMs = _filterByDate
          ? DateTime(
              _startDate.year,
              _startDate.month,
              _startDate.day,
            ).millisecondsSinceEpoch
          : null;
      final endMs = _filterByDate
          ? DateTime(
              _endDate.year,
              _endDate.month,
              _endDate.day,
              23,
              59,
              59,
              999,
            ).millisecondsSinceEpoch
          : null;

      final result = await service.exportCsv(
        bookId: _selectedBookId == noRef ? null : _selectedBookId,
        startMs: startMs,
        endMs: endMs,
        includeCurrency: _includeCurrency,
        utf8WithBom: _utf8WithBom,
      );

      final fileAccess = ref.read(csvFileAccessProvider);
      if (share) {
        final shareFn = widget.shareFile;
        if (shareFn != null) {
          await shareFn(result.suggestedFileName, result.bytes);
        } else {
          await fileAccess.shareBytes(
            result.suggestedFileName,
            result.bytes,
            mimeType: 'text/csv',
            subject: '帐屿 CSV 账单导出',
          );
        }
      } else {
        final saveFn = widget.saveFile;
        if (saveFn != null) {
          await saveFn(result.suggestedFileName, result.bytes);
        } else {
          await fileAccess.saveBytes(
            result.suggestedFileName,
            result.bytes,
            mimeType: 'text/csv',
          );
        }
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导出 ${result.exportedCount} 条账单')),
      );
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
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = DesktopAdaptive.isDesktop(context);
    final booksAsync = ref.watch(booksProvider);
    final fileAccess = ref.watch(csvFileAccessProvider);
    final canShare =
        widget.shareFile != null ||
        fileAccess.shareCapability.state == CapabilityState.available;

    return Scaffold(
      key: const Key('csv_export_page'),
      appBar: AppBar(title: const Text('导出 CSV 账单')),
      body: asyncBody(booksAsync, (books) {
        final validBookIds = <int>{noRef, for (final b in books) b.id};
        final effectiveBookId = validBookIds.contains(_selectedBookId)
            ? _selectedBookId
            : noRef;

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
                      '导出范围与格式',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 16),
                    TallySelectField<int>(
                      key: const Key('export_book_dropdown'),
                      label: '选择账本',
                      sheetTitle: '选择导出账本',
                      value: effectiveBookId,
                      enabled: !_busy,
                      options: [
                        const TallySelectOption<int>(
                          value: noRef,
                          label: '全部账本',
                        ),
                        for (final b in books)
                          TallySelectOption<int>(value: b.id, label: b.name),
                      ],
                      onChanged: _busy
                          ? null
                          : (value) => setState(() => _selectedBookId = value),
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      key: const Key('export_date_filter_switch'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('按日期范围筛选'),
                      subtitle: Text(
                        _filterByDate
                            ? '${formatDate(_startDate)} 至 ${formatDate(_endDate)}'
                            : '导出所选账本的全部历史账单',
                      ),
                      value: _filterByDate,
                      onChanged: _busy
                          ? null
                          : (v) => setState(() => _filterByDate = v),
                    ),
                    if (_filterByDate) ...[
                      Row(
                        children: [
                          Expanded(
                            child: TallySoftButton.icon(
                              key: const Key('export_start_date_button'),
                              onPressed: _busy
                                  ? null
                                  : () => _pickDate(isStart: true),
                              icon: const Icon(Icons.calendar_today, size: 16),
                              label: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  '起：${formatDate(_startDate)}',
                                  maxLines: 1,
                                  softWrap: false,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TallySoftButton.icon(
                              key: const Key('export_end_date_button'),
                              onPressed: _busy
                                  ? null
                                  : () => _pickDate(isStart: false),
                              icon: const Icon(Icons.event, size: 16),
                              label: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  '止：${formatDate(_endDate)}',
                                  maxLines: 1,
                                  softWrap: false,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                    ],
                    const SizedBox(height: 16),
                    SwitchListTile(
                      key: const Key('export_include_currency_switch'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('包含「币种」列（15 列标准格式）'),
                      subtitle: const Text('关闭后将导出兼容无币种列的 14 列 CSV 格式'),
                      value: _includeCurrency,
                      onChanged: _busy
                          ? null
                          : (v) => setState(() => _includeCurrency = v),
                    ),
                    const SizedBox(height: 12),
                    Text('文件编码', style: Theme.of(context).textTheme.labelLarge),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<bool>(
                        key: const Key('export_encoding_selector'),
                        showSelectedIcon: false,
                        segments: const [
                          ButtonSegment<bool>(
                            value: true,
                            label: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                'UTF-8（推荐）',
                                maxLines: 1,
                                softWrap: false,
                              ),
                            ),
                          ),
                          ButtonSegment<bool>(
                            value: false,
                            label: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                'GBK（旧版兼容）',
                                maxLines: 1,
                                softWrap: false,
                              ),
                            ),
                          ),
                        ],
                        selected: {_utf8WithBom},
                        onSelectionChanged: _busy
                            ? null
                            : (selection) => setState(
                                () => _utf8WithBom = selection.first,
                              ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '遵循 RFC 4180 标准转义，备注中的逗号、双引号及多行换行均可无损往返导入。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 16),
                    LayoutBuilder(
                      builder: (ctx, constraints) {
                        final confirmBtn = TallySoftButton.icon(
                          key: const Key('confirm_csv_export_button'),
                          onPressed: _busy
                              ? null
                              : () => _runExport(share: false),
                          icon: _busy
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.download_outlined, size: 18),
                          label: const FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              '导出并保存 CSV',
                              maxLines: 1,
                              softWrap: false,
                            ),
                          ),
                        );
                        if (!canShare) {
                          return SizedBox(
                            width: double.infinity,
                            child: confirmBtn,
                          );
                        }
                        final shareBtn = TallySoftButton.icon(
                          key: const Key('share_csv_export_button'),
                          onPressed: _busy
                              ? null
                              : () => _runExport(share: true),
                          icon: const Icon(Icons.share_outlined, size: 18),
                          label: const FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              '生成并调用系统分享',
                              maxLines: 1,
                              softWrap: false,
                            ),
                          ),
                        );
                        if (constraints.maxWidth >= 440) {
                          return Row(
                            children: [
                              Expanded(child: shareBtn),
                              const SizedBox(width: 10),
                              Expanded(child: confirmBtn),
                            ],
                          );
                        }
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            confirmBtn,
                            const SizedBox(height: 10),
                            shareBtn,
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
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

Color _tonalCardColor(ThemeData theme) {
  final scheme = theme.colorScheme;
  return theme.brightness == Brightness.dark
      ? scheme.surfaceContainerLow
      : Color.lerp(scheme.surfaceContainerLow, scheme.surfaceContainer, 0.55)!;
}

const _tonalCardShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(16)),
);
