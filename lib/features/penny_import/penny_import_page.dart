import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/penny/penny_import_service.dart';
import '../../domain/rules/penny_backup.dart';
import '../common/common.dart';
import 'penny_import_providers.dart';

/// Page for importing original encrypted `.penny` / `.yy` backups (`F-035`).
class PennyImportPage extends ConsumerStatefulWidget {
  const PennyImportPage({super.key});

  @override
  ConsumerState<PennyImportPage> createState() => _PennyImportPageState();
}

class _PennyImportPageState extends ConsumerState<PennyImportPage> {
  final CommandIds _commandIds = CommandIds();

  bool _busy = false;
  String? _busyMessage;
  String? _errorMessage;
  PennyImportResult? _lastResult;

  Future<void> _selectAndImportFile() async {
    if (_busy) return;
    setState(() {
      _errorMessage = null;
    });

    final PennyPickedFile? picked;
    try {
      picked = await ref.read(pennyFilePickerProvider)();
    } catch (error) {
      if (!mounted) return;
      _showFailure(safeMessage(error));
      return;
    }
    if (picked == null || !mounted) return;

    setState(() {
      _busy = true;
      _busyMessage = '正在解析并校验备份文件…';
    });

    final PennyImportService service;
    final PennyBackupPreview preview;
    try {
      service = await ref.read(pennyImportServiceProvider.future);
      preview = await service.previewPenny(
        fileName: picked.name,
        bytes: picked.bytes,
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _busyMessage = null;
      });
      _showFailure(safeMessage(error));
      return;
    }

    if (!mounted) return;
    setState(() {
      _busy = false;
      _busyMessage = null;
    });

    final confirmed = await _showPreviewDialog(preview);
    if (!confirmed || !mounted) return;

    setState(() {
      _busy = true;
      _busyMessage = '正在原子恢复备份数据，请勿关闭应用…';
      _errorMessage = null;
    });

    try {
      final digest = sha256.convert(picked.bytes).toString();
      final commandId = _commandIds.forPayload([
        'penny-import-ui-v1',
        picked.name,
        digest,
      ]);
      final result = await service.importPenny(
        commandId: commandId,
        fileName: picked.name,
        bytes: picked.bytes,
      );

      // Reset home & calendar period offsets so the restored default book shows current period (R7).
      ref.read(periodOffsetProvider.notifier).reset();
      ref.read(calendarMonthOffsetProvider.notifier).reset();

      if (!mounted) return;
      setState(() {
        _busy = false;
        _busyMessage = null;
        _lastResult = result;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('恢复成功')));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _busyMessage = null;
      });
      _showFailure(safeMessage(error));
    }
  }

  void _showFailure(String message) {
    setState(() {
      _errorMessage = message;
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _showPreviewDialog(PennyBackupPreview preview) async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        final theme = Theme.of(dialogContext);
        return AlertDialog(
          key: const Key('penny_preview_dialog'),
          title: const Text('原版备份导入预览'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _PreviewRow(label: '备份文件', value: preview.fileName),
                _PreviewRow(label: '原版版本', value: preview.appVersion),
                _PreviewRow(
                  label: '账本数量',
                  value:
                      '${preview.bookCount} 个（恢复后选中：${preview.targetBookName}）',
                ),
                _PreviewRow(label: '账户资产', value: '${preview.assetCount} 个'),
                _PreviewRow(label: '收支分类', value: '${preview.categoryCount} 个'),
                _PreviewRow(label: '账单流水', value: '${preview.recordCount} 条'),
                _PreviewRow(
                  label: '计划与预算',
                  value: '${preview.totalPlanCount} 项',
                ),
                _PreviewRow(label: '历史备注', value: '${preview.remarkCount} 条'),
                if (preview.filteredTombstoneCount > 0)
                  _PreviewRow(
                    label: '已过滤软删墓碑',
                    value: '${preview.filteredTombstoneCount} 条',
                  ),
                const SizedBox(height: 12),
                Container(
                  key: const Key('penny_overwrite_warning'),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '覆盖警告：确认恢复将以备份内容原子替换本地 20 张账务数据表（账本、账户、分类、账单、预算、分期、周期、存钱计划等）；'
                    '本地已有的便签（note）与自定义汇率（currency）将完整保留，不会被清空。',
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
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('confirm_penny_import_button'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('确认恢复'),
            ),
          ],
        );
      },
    );
    return confirmed == true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('导入原版备份')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('从一羽记账备份文件恢复', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(
                    '支持导入原版导出的 .penny 加密备份文件（兼容历史 .yy 备份）。'
                    '恢复过程在独立暂存校验通过后以单一数据库事务执行，若文件损坏或为空不会改动本地已有数据。',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '• 替换范围：账本、分类、账户、账单、预算、分期、周期、提醒、标签、模板、愿望、存钱计划及备注词库共 20 张业务表。\n'
                    '• 保全范围：本地已有的便签与自定义币种汇率配置完整保留。',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      key: const Key('select_penny_file_button'),
                      onPressed: _busy ? null : _selectAndImportFile,
                      icon: const Icon(Icons.upload_file),
                      label: const Text('选择 .penny / .yy 备份文件'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_busy) ...[
            const SizedBox(height: 16),
            Card(
              key: const Key('penny_importing_indicator'),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: Text(_busyMessage ?? '正在处理…')),
                  ],
                ),
              ),
            ),
          ],
          if (_errorMessage != null) ...[
            const SizedBox(height: 16),
            Card(
              key: const Key('penny_import_error_card'),
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.error_outline,
                      color: theme.colorScheme.onErrorContainer,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style: TextStyle(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (_lastResult != null) ...[
            const SizedBox(height: 16),
            Card(
              key: const Key('penny_import_result_card'),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.check_circle,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Text('恢复成功', style: theme.textTheme.titleMedium),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '已切换至账本「${_lastResult!.preview.targetBookName}」（ID: ${_lastResult!.targetBookId}）。\n'
                      '共恢复 ${_lastResult!.preview.bookCount} 个账本、'
                      '${_lastResult!.preview.assetCount} 个账户、'
                      '${_lastResult!.preview.recordCount} 条账单、'
                      '${_lastResult!.preview.remarkCount} 条历史备注。',
                    ),
                    if (Navigator.of(context).canPop()) ...[
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerRight,
                        child: OutlinedButton(
                          key: const Key('penny_back_button'),
                          onPressed: () => Navigator.of(context).pop(true),
                          child: const Text('返回'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PreviewRow extends StatelessWidget {
  const _PreviewRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
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
}
