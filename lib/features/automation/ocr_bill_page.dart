import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/failure.dart';
import '../../data/automation/ocr_service.dart';
import '../../data/db/database.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/ocr_bill_rules.dart';
import '../../domain/rules/url_scheme_rules.dart' show parseUrlMoney;
import '../common/common.dart';
import 'automation_providers.dart';

/// Bill screenshot OCR & text parsing review page (`F-021`, `ADR-017`).
///
/// Explicitly displays `'未配置'` when no `OcrProvider` endpoint is configured
/// and NEVER fakes image OCR results.
class OcrBillPage extends ConsumerStatefulWidget {
  const OcrBillPage({super.key});

  @override
  ConsumerState<OcrBillPage> createState() => _OcrBillPageState();
}

class _OcrBillPageState extends ConsumerState<OcrBillPage> {
  final TextEditingController _textController = TextEditingController();
  final CommandIds _commandIds = CommandIds();
  int _nonce = 0;

  bool _recognizing = false;
  bool _confirming = false;
  String? _error;
  String? _infoMessage;
  int? _defaultAssetId;
  List<OcrBillCandidate> _candidates = const [];

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _openConfigDialog(OcrEndpointConfig current) async {
    final updated = await showDialog<bool>(
      context: context,
      builder: (_) => _OcrConfigDialog(initial: current),
    );
    if (updated == true && mounted) {
      setState(() => _error = null);
    }
  }

  Future<void> _pickAndRecognizeImage() async {
    setState(() {
      _recognizing = true;
      _error = null;
      _infoMessage = null;
    });
    try {
      final service = await ref.read(ocrServiceProvider.future);
      final provider = await service.getProvider();
      if (!provider.isConfigured) {
        // Delegate to UnconfiguredOcrProvider so ADR-017 rejection is uniform and immediate.
        await provider.recognizeImage(Uint8List(0));
      }

      final fileAccess = ref.read(ocrFileAccessProvider);
      final selected = await fileAccess.pickBytes(
        allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp'],
      );
      final bookId = ref.read(currentBookIdProvider).value;
      final (recognizedText, parsed) = await service.recognizeImageToCandidates(
        selected.bytes,
        fileName: selected.name,
        bookId: bookId,
      );
      if (!mounted) return;
      setState(() {
        _textController.text = recognizedText;
        _candidates = parsed;
        if (parsed.isEmpty) {
          _error = '已提取图片文字，但未识别出有效账单金额，可在下方文本框调整后重新解析';
        } else {
          _infoMessage = '已从图片识别出 ${parsed.length} 条待核对账单';
        }
      });
    } on Failure catch (f) {
      if (!mounted) return;
      if (f.code == FailureCode.cancelled) return;
      setState(() => _error = f.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = safeMessage(e));
    } finally {
      if (mounted) setState(() => _recognizing = false);
    }
  }

  Future<void> _parseTextLocally() async {
    final raw = _textController.text.trim();
    if (raw.isEmpty) {
      setState(() {
        _error = '请先粘贴或输入微信/支付宝账单文本或小票内容';
        _infoMessage = null;
      });
      return;
    }
    setState(() {
      _recognizing = true;
      _error = null;
      _infoMessage = null;
    });
    try {
      final service = await ref.read(ocrServiceProvider.future);
      final bookId = ref.read(currentBookIdProvider).value;
      final parsed = await service.parseTextToCandidates(raw, bookId: bookId);
      if (!mounted) return;
      setState(() {
        _candidates = parsed;
        if (parsed.isEmpty) {
          _error = '未从文本中提取到有效金额，请包含如“-18.50”或“实付 36.00”的金额行';
        } else {
          _infoMessage = '解析成功：共识别出 ${parsed.length} 条待核对账单';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = safeMessage(e));
    } finally {
      if (mounted) setState(() => _recognizing = false);
    }
  }

  void _updateCandidate(int index, OcrBillCandidate updated) {
    setState(() {
      _candidates = [
        for (final c in _candidates)
          if (c.index == index) updated else c,
      ];
    });
  }

  Future<void> _editCandidateDialog(OcrBillCandidate candidate) async {
    final edited = await showDialog<OcrBillCandidate>(
      context: context,
      builder: (_) => _EditCandidateDialog(candidate: candidate),
    );
    if (edited != null && mounted) {
      _updateCandidate(candidate.index, edited);
    }
  }

  Future<void> _confirmBatch() async {
    final selectedCount = _candidates.where((c) => c.selected).length;
    if (selectedCount == 0) {
      setState(() => _error = '请至少勾选一条需要入账的记录');
      return;
    }
    setState(() {
      _confirming = true;
      _error = null;
    });
    try {
      final service = await ref.read(ocrServiceProvider.future);
      final bookId = ref.read(currentBookIdProvider).value;
      final cmdId = _commandIds.forPayload([
        'ocr-batch',
        _nonce++,
        bookId,
        _defaultAssetId,
        for (final c in _candidates)
          if (c.selected)
            [
              c.index,
              c.type,
              c.money.toJson(),
              c.categoryId,
              c.assetId,
              c.remark,
            ],
      ]);
      final ids = await service.confirmCandidates(
        commandId: cmdId,
        bookId: bookId,
        candidates: _candidates,
        defaultAssetId: _defaultAssetId,
      );
      final widgetService = await ref.read(
        widgetSnapshotServiceProvider.future,
      );
      await widgetService.syncToPlatform();
      ref.invalidate(widgetSnapshotProvider);

      if (!mounted) return;
      setState(() {
        _candidates = _candidates
            .where((c) => !c.selected)
            .toList(growable: false);
        _infoMessage = '已成功批量入账 ${ids.length} 笔账单';
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已成功入账 ${ids.length} 笔账单')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = safeMessage(e));
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final providerAsync = ref.watch(ocrProviderInstanceProvider);
    final config =
        ref.watch(ocrConfigProvider).value ?? const OcrEndpointConfig();
    final provider = providerAsync.value ?? const UnconfiguredOcrProvider();
    final bookId = ref.watch(currentBookIdProvider).value ?? 1;
    final categories =
        ref.watch(categoriesProvider(bookId)).value ?? const <RecordCategory>[];
    final assets = (ref.watch(assetsProvider).value ?? const <Asset>[])
        .where(
          (a) => a.type != AssetType.debt && a.status != AssetStatus.settled,
        )
        .toList(growable: false);

    final validDefaultAssetId = assets.any((a) => a.id == _defaultAssetId)
        ? _defaultAssetId
        : null;
    final selectedCount = _candidates.where((c) => c.selected).length;
    final theme = Theme.of(context);

    return Scaffold(
      key: const Key('ocr_bill_page'),
      appBar: AppBar(title: const Text('账单图 / 文本识别')),
      body: ListView(
        key: const Key('ocr_list_view'),
        padding: const EdgeInsets.all(16),
        children: [
          _OcrProviderStatusCard(
            provider: provider,
            config: config,
            onConfigure: () => _openConfigDialog(config),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        key: const Key('ocr_pick_image_button'),
                        onPressed: _recognizing ? null : _pickAndRecognizeImage,
                        icon: const Icon(Icons.image_search),
                        label: Text(_recognizing ? '识别中…' : '选择账单图片识别'),
                      ),
                      OutlinedButton.icon(
                        key: const Key('ocr_parse_text_button'),
                        onPressed: _recognizing ? null : _parseTextLocally,
                        icon: const Icon(Icons.notes),
                        label: const Text('解析下方文本'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('ocr_text_input'),
                    controller: _textController,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: '账单明细或小票文本（支持直接离线粘贴解析）',
                      hintText: '例如：\n11月10日 09:15\n瑞幸咖啡\n-18.50',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Container(
              key: const Key('ocr_error_banner'),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
              ),
            ),
          ],
          if (_infoMessage != null) ...[
            const SizedBox(height: 12),
            Container(
              key: const Key('ocr_info_banner'),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _infoMessage!,
                style: TextStyle(color: theme.colorScheme.onSecondaryContainer),
              ),
            ),
          ],
          if (_candidates.isNotEmpty) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '识别结果核对（已选 $selectedCount / ${_candidates.length} 笔）',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                FilledButton(
                  key: const Key('ocr_confirm_batch_button'),
                  onPressed: _confirming || selectedCount == 0
                      ? null
                      : _confirmBatch,
                  child: Text(_confirming ? '入账中…' : '批量确认入账 ($selectedCount)'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            InputDecorator(
              decoration: const InputDecoration(
                labelText: '默认入账资金账户（单笔未指定时生效）',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int?>(
                  key: const Key('ocr_default_asset_dropdown'),
                  isExpanded: true,
                  isDense: true,
                  value: validDefaultAssetId,
                  items: [
                    const DropdownMenuItem<int?>(
                      value: null,
                      child: Text('不指定默认账户'),
                    ),
                    for (final a in assets)
                      DropdownMenuItem<int?>(value: a.id, child: Text(a.name)),
                  ],
                  onChanged: (v) => setState(() => _defaultAssetId = v),
                ),
              ),
            ),
            const SizedBox(height: 12),
            for (final candidate in _candidates) ...[
              _CandidateReviewCard(
                candidate: candidate,
                categories: categories,
                assets: assets,
                onChanged: (next) => _updateCandidate(candidate.index, next),
                onEditDetail: () => _editCandidateDialog(candidate),
              ),
              const SizedBox(height: 8),
            ],
          ],
        ],
      ),
    );
  }
}

class _OcrProviderStatusCard extends StatelessWidget {
  const _OcrProviderStatusCard({
    required this.provider,
    required this.config,
    required this.onConfigure,
  });

  final OcrProvider provider;
  final OcrEndpointConfig config;
  final VoidCallback onConfigure;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final configured = provider.isConfigured;

    return Card(
      key: const Key('ocr_provider_status_card'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(
              configured ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
              color: configured
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        provider.label,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        key: const Key('ocr_provider_status_badge'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: configured
                              ? theme.colorScheme.primaryContainer
                              : theme.colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          provider.statusLabel,
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: configured
                                ? theme.colorScheme.onPrimaryContainer
                                : theme.colorScheme.onErrorContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    configured
                        ? '接口地址：${config.endpointUrl}'
                        : '当前未配置图片 OCR 接口；可点击右侧配置自建/第三方 HTTP OCR 服务，或直接粘贴文本解析。',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            TextButton(
              key: const Key('ocr_config_button'),
              onPressed: onConfigure,
              child: Text(configured ? '修改配置' : '配置接口'),
            ),
          ],
        ),
      ),
    );
  }
}

class _OcrConfigDialog extends ConsumerStatefulWidget {
  const _OcrConfigDialog({required this.initial});

  final OcrEndpointConfig initial;

  @override
  ConsumerState<_OcrConfigDialog> createState() => _OcrConfigDialogState();
}

class _OcrConfigDialogState extends ConsumerState<_OcrConfigDialog> {
  late final TextEditingController _urlController;
  late final TextEditingController _apiKeyController;
  final CommandIds _commandIds = CommandIds();
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(text: widget.initial.endpointUrl);
    _apiKeyController = TextEditingController(text: widget.initial.apiKey);
  }

  @override
  void dispose() {
    _urlController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final service = await ref.read(ocrServiceProvider.future);
      final next = OcrEndpointConfig(
        endpointUrl: _urlController.text,
        apiKey: _apiKeyController.text,
        timeoutSeconds: widget.initial.timeoutSeconds,
      );
      await service.saveConfig(
        commandId: _commandIds.forPayload(['save-ocr-cfg', next.encode()]),
        config: next,
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = safeMessage(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _clear() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final service = await ref.read(ocrServiceProvider.future);
      await service.clearConfig(
        commandId: _commandIds.forPayload([
          'clear-ocr-cfg',
          DateTime.now().millisecondsSinceEpoch,
        ]),
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = safeMessage(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const Key('ocr_config_dialog'),
    title: const Text('配置 HTTP OCR 接口'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('ocr_endpoint_input'),
            controller: _urlController,
            decoration: const InputDecoration(
              labelText: 'HTTP/HTTPS 接口地址',
              hintText: 'https://ocr.example.com/v1/recognize',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('ocr_apikey_input'),
            controller: _apiKeyController,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Bearer API Key（可选）',
              border: OutlineInputBorder(),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    ),
    actions: [
      if (widget.initial.isConfigured)
        TextButton(
          key: const Key('ocr_config_clear_button'),
          onPressed: _saving ? null : _clear,
          child: const Text('清除配置'),
        ),
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context, false),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const Key('ocr_config_save_button'),
        onPressed: _saving ? null : _save,
        child: const Text('保存配置'),
      ),
    ],
  );
}

class _CandidateReviewCard extends StatelessWidget {
  const _CandidateReviewCard({
    required this.candidate,
    required this.categories,
    required this.assets,
    required this.onChanged,
    required this.onEditDetail,
  });

  final OcrBillCandidate candidate;
  final List<RecordCategory> categories;
  final List<Asset> assets;
  final ValueChanged<OcrBillCandidate> onChanged;
  final VoidCallback onEditDetail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dirCats = categories
        .where((c) => !c.isHide && c.type == candidate.type)
        .toList(growable: false);
    final validCatId = dirCats.any((c) => c.id == candidate.categoryId)
        ? candidate.categoryId
        : dirCats.firstOrNull?.id;
    final validAssetId = assets.any((a) => a.id == candidate.assetId)
        ? candidate.assetId
        : null;

    return Card(
      key: Key('ocr_candidate_${candidate.index}'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Checkbox(
                  key: Key('ocr_candidate_check_${candidate.index}'),
                  value: candidate.selected,
                  onChanged: (v) =>
                      onChanged(candidate.copyWith(selected: v ?? false)),
                ),
                ActionChip(
                  label: Text(
                    candidate.type == RecordType.income ? '收入' : '支出',
                  ),
                  onPressed: () {
                    final nextType = candidate.type == RecordType.income
                        ? RecordType.expense
                        : RecordType.income;
                    final nextCat = categories
                        .where((c) => !c.isHide && c.type == nextType)
                        .firstOrNull
                        ?.id;
                    onChanged(
                      candidate.copyWith(type: nextType, categoryId: nextCat),
                    );
                  },
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    candidate.remark,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  '¥${candidate.money.decimal}',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                IconButton(
                  key: Key('ocr_candidate_edit_${candidate.index}'),
                  tooltip: '修改金额与备注',
                  onPressed: onEditDetail,
                  icon: const Icon(Icons.edit_outlined, size: 20),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 12, right: 12, bottom: 4),
              child: Text(
                formatDateTime(
                  DateTime.fromMillisecondsSinceEpoch(candidate.recordTimeMs),
                ),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: '分类',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<int>(
                        isExpanded: true,
                        isDense: true,
                        value: validCatId,
                        items: [
                          for (final c in dirCats)
                            DropdownMenuItem(value: c.id, child: Text(c.name)),
                        ],
                        onChanged: (v) =>
                            onChanged(candidate.copyWith(categoryId: v)),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: '账户（可选）',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<int?>(
                        isExpanded: true,
                        isDense: true,
                        value: validAssetId,
                        items: [
                          const DropdownMenuItem<int?>(
                            value: null,
                            child: Text('跟随默认'),
                          ),
                          for (final a in assets)
                            DropdownMenuItem<int?>(
                              value: a.id,
                              child: Text(a.name),
                            ),
                        ],
                        onChanged: (v) => onChanged(
                          OcrBillCandidate(
                            index: candidate.index,
                            type: candidate.type,
                            money: candidate.money,
                            discount: candidate.discount,
                            recordTimeMs: candidate.recordTimeMs,
                            merchant: candidate.merchant,
                            remark: candidate.remark,
                            categoryHint: candidate.categoryHint,
                            accountHint: candidate.accountHint,
                            categoryId: validCatId,
                            assetId: v,
                            selected: candidate.selected,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EditCandidateDialog extends StatefulWidget {
  const _EditCandidateDialog({required this.candidate});

  final OcrBillCandidate candidate;

  @override
  State<_EditCandidateDialog> createState() => _EditCandidateDialogState();
}

class _EditCandidateDialogState extends State<_EditCandidateDialog> {
  late final TextEditingController _amountController;
  late final TextEditingController _remarkController;
  String? _error;

  @override
  void initState() {
    super.initState();
    _amountController = TextEditingController(
      text: widget.candidate.money.decimal,
    );
    _remarkController = TextEditingController(text: widget.candidate.remark);
  }

  @override
  void dispose() {
    _amountController.dispose();
    _remarkController.dispose();
    super.dispose();
  }

  void _submit() {
    try {
      final money = parseUrlMoney(_amountController.text, fieldLabel: '金额');
      Navigator.pop(
        context,
        widget.candidate.copyWith(
          money: money,
          remark: _remarkController.text.trim(),
        ),
      );
    } catch (e) {
      setState(() => _error = safeMessage(e));
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('修改识别记录'),
    content: SizedBox(
      width: 380,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('ocr_edit_amount_input'),
            controller: _amountController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: '金额（元）',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('ocr_edit_remark_input'),
            controller: _remarkController,
            decoration: const InputDecoration(
              labelText: '备注',
              border: OutlineInputBorder(),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const Key('ocr_edit_save_button'),
        onPressed: _submit,
        child: const Text('确定'),
      ),
    ],
  );
}
