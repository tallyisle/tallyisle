import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/money.dart';
import '../../data/db/database.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/auto_map_rules.dart';
import '../../domain/rules/url_scheme_rules.dart' show parseUrlMoney;
import '../../platform/auto_bill_bridge.dart';
import '../common/common.dart';
import 'automation_providers.dart';

/// Auto-bookkeeping management page (`F-020`):
/// - Honest Android `AccessibilityService` status (`已开启` / `未开启` / `当前平台不支持`)
/// - Pending draft inbox (`KEY_DRAFT`) with payment text parser & confirmation into `LedgerService`
/// - Keyword mapping rule CRUD (`auto_map`)
class AutoBillPage extends ConsumerStatefulWidget {
  const AutoBillPage({super.key});

  @override
  ConsumerState<AutoBillPage> createState() => _AutoBillPageState();
}

class _AutoBillPageState extends ConsumerState<AutoBillPage> {
  final CommandIds _commandIds = CommandIds();
  int _nonce = 0;
  StreamSubscription<CapturedPaymentEvent>? _liveSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pullCapturedEvents();
      _subscribeLiveEvents();
    });
  }

  void _subscribeLiveEvents() {
    final bridge = ref.read(autoBillBridgeProvider);
    _liveSub = bridge.onCapturedEvent.listen((event) async {
      if (!mounted) return;
      try {
        final service = await ref.read(autoBillServiceProvider.future);
        await service.ingestPaymentText(
          commandId: _commandIds.forPayload([
            'live-ev',
            _nonce++,
            event.capturedAtMs,
            event.rawText,
          ]),
          rawText: event.rawText,
          packageName: event.packageName,
          capturedAtMs: event.capturedAtMs,
          allowNonPaymentSkip: true,
        );
      } catch (_) {
        // Non-payment accessibility noise is safely ignored.
      }
    });
  }

  Future<void> _pullCapturedEvents() async {
    try {
      final service = await ref.read(autoBillServiceProvider.future);
      await service.ingestCapturedEvents();
      if (mounted) {
        ref.invalidate(accessibilityStatusProvider);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    unawaited(_liveSub?.cancel());
    super.dispose();
  }

  Future<void> _openSystemAccessibilitySettings() async {
    try {
      final service = await ref.read(autoBillServiceProvider.future);
      final opened = await service.openAccessibilitySettings();
      if (!mounted) return;
      if (!opened) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('当前平台不支持打开系统无障碍设置')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

  Future<void> _showPastePaymentDialog() async {
    final added = await showDialog<bool>(
      context: context,
      builder: (_) => const _PastePaymentTextDialog(),
    );
    if (added == true && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已识别支付文本并加入待确认草稿箱')));
    }
  }

  Future<void> _quickConfirmDraft(AutoBillDraft draft) async {
    if (draft.id == null) return;
    try {
      final service = await ref.read(autoBillServiceProvider.future);
      final commandId = _commandIds.forPayload([
        'quick-confirm',
        draft.id,
        _nonce++,
      ]);
      await service.confirmDraft(commandId: commandId, draftId: draft.id!);
      final widgetService = await ref.read(
        widgetSnapshotServiceProvider.future,
      );
      await widgetService.syncToPlatform();
      ref.invalidate(widgetSnapshotProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('草稿已确认入账')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

  Future<void> _openEditConfirmDialog(
    AutoBillDraft draft,
    List<RecordCategory> categories,
    List<Asset> assets,
  ) async {
    if (draft.id == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _ConfirmDraftDialog(
        draft: draft,
        categories: categories,
        assets: assets,
      ),
    );
    if (confirmed == true && mounted) {
      final widgetService = await ref.read(
        widgetSnapshotServiceProvider.future,
      );
      await widgetService.syncToPlatform();
      ref.invalidate(widgetSnapshotProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('草稿已确认入账')));
    }
  }

  Future<void> _deleteDraft(AutoBillDraft draft) async {
    if (draft.id == null) return;
    try {
      final service = await ref.read(autoBillServiceProvider.future);
      await service.deleteDraft(
        commandId: _commandIds.forPayload(['del-draft', draft.id, _nonce++]),
        draftId: draft.id!,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

  Future<void> _clearAllDrafts() async {
    final ok = await confirm(
      context,
      title: '清空待确认草稿',
      message: '确定删除草稿箱中全部待确认记录吗？已配置的映射规则不会受影响。',
      ok: '清空',
    );
    if (!ok || !mounted) return;
    try {
      final service = await ref.read(autoBillServiceProvider.future);
      await service.clearDrafts(
        commandId: _commandIds.forPayload(['clear-drafts', _nonce++]),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

  Future<void> _openRuleDialog({
    AutoMapRule? existing,
    required List<RecordCategory> categories,
    required List<Asset> assets,
    required int currentBookId,
  }) async {
    await showDialog<bool>(
      context: context,
      builder: (_) => _RuleEditorDialog(
        existing: existing,
        categories: categories,
        assets: assets,
        currentBookId: currentBookId,
      ),
    );
  }

  Future<void> _deleteRule(AutoMapRule rule) async {
    final ok = await confirm(
      context,
      title: '删除映射规则',
      message: '确定删除关键词“${rule.key}”的自动映射规则吗？',
      ok: '删除',
    );
    if (!ok || !mounted) return;
    try {
      final service = await ref.read(autoBillServiceProvider.future);
      await service.deleteRule(
        commandId: _commandIds.forPayload(['del-rule', rule.id, _nonce++]),
        id: rule.id,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final statusAsync = ref.watch(accessibilityStatusProvider);
    final draftsAsync = ref.watch(autoBillDraftsProvider);
    final rulesAsync = ref.watch(autoMapRulesProvider);
    final bookId = ref.watch(currentBookIdProvider).value ?? 1;
    final categories =
        ref.watch(categoriesProvider(bookId)).value ?? const <RecordCategory>[];
    final assets = ref.watch(assetsProvider).value ?? const <Asset>[];

    final fundingAssets = assets
        .where(
          (a) => a.type != AssetType.debt && a.status != AssetStatus.settled,
        )
        .toList(growable: false);

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        key: const Key('auto_bill_page'),
        appBar: AppBar(
          title: const Text('自动记账'),
          actions: [
            IconButton(
              key: const Key('auto_bill_refresh_status_button'),
              tooltip: '刷新状态与草稿队列',
              onPressed: _pullCapturedEvents,
              icon: const Icon(Icons.refresh),
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(key: Key('auto_bill_tab_drafts'), text: '待确认草稿'),
              Tab(key: Key('auto_bill_tab_rules'), text: '映射规则'),
            ],
          ),
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: _AccessibilityStatusCard(
                statusAsync: statusAsync,
                onOpenSettings: _openSystemAccessibilitySettings,
              ),
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _DraftsTabView(
                    draftsAsync: draftsAsync,
                    categories: categories,
                    assets: fundingAssets,
                    onPasteParse: _showPastePaymentDialog,
                    onClearAll: _clearAllDrafts,
                    onQuickConfirm: _quickConfirmDraft,
                    onEditConfirm: (d) =>
                        _openEditConfirmDialog(d, categories, fundingAssets),
                    onDelete: _deleteDraft,
                  ),
                  _RulesTabView(
                    rulesAsync: rulesAsync,
                    categories: categories,
                    assets: fundingAssets,
                    onAddRule: () => _openRuleDialog(
                      categories: categories,
                      assets: fundingAssets,
                      currentBookId: bookId,
                    ),
                    onEditRule: (rule) => _openRuleDialog(
                      existing: rule,
                      categories: categories,
                      assets: fundingAssets,
                      currentBookId: bookId,
                    ),
                    onDeleteRule: _deleteRule,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AccessibilityStatusCard extends StatelessWidget {
  const _AccessibilityStatusCard({
    required this.statusAsync,
    required this.onOpenSettings,
  });

  final AsyncValue<AccessibilityBridgeStatus> statusAsync;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status =
        statusAsync.value ?? const AccessibilityBridgeStatus.unsupported();
    final Color badgeColor = switch (status.statusLabel) {
      accessibilityEnabledLabel => theme.colorScheme.primaryContainer,
      accessibilityDisabledLabel => theme.colorScheme.tertiaryContainer,
      _ => theme.colorScheme.surfaceContainerHighest,
    };

    return Card(
      key: const Key('auto_bill_status_card'),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            const Icon(Icons.accessibility_new),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        '无障碍支付识别',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        key: const Key('auto_bill_status_badge'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: badgeColor,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          status.statusLabel,
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    status.supported
                        ? '仅在本地提取支付通知/结果页金额生成待确认草稿，不上传任何账单数据。'
                        : '当前平台不支持 Android 无障碍服务，可直接粘贴支付通知或短信文本生成草稿。',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            if (status.supported)
              TextButton(
                key: const Key('auto_bill_open_settings_button'),
                onPressed: onOpenSettings,
                child: Text(status.enabled ? '设置' : '去开启'),
              ),
          ],
        ),
      ),
    );
  }
}

class _DraftsTabView extends StatelessWidget {
  const _DraftsTabView({
    required this.draftsAsync,
    required this.categories,
    required this.assets,
    required this.onPasteParse,
    required this.onClearAll,
    required this.onQuickConfirm,
    required this.onEditConfirm,
    required this.onDelete,
  });

  final AsyncValue<List<AutoBillDraft>> draftsAsync;
  final List<RecordCategory> categories;
  final List<Asset> assets;
  final VoidCallback onPasteParse;
  final VoidCallback onClearAll;
  final ValueChanged<AutoBillDraft> onQuickConfirm;
  final ValueChanged<AutoBillDraft> onEditConfirm;
  final ValueChanged<AutoBillDraft> onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return asyncBody(draftsAsync, (drafts) {
      final catMap = {for (final c in categories) c.id: c.name};
      final assetMap = {for (final a in assets) a.id: a.name};

      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              FilledButton.icon(
                key: const Key('auto_bill_paste_parse_button'),
                onPressed: onPasteParse,
                icon: const Icon(Icons.content_paste_go, size: 18),
                label: const Text('粘贴支付文本识别'),
              ),
              const Spacer(),
              if (drafts.isNotEmpty)
                TextButton(
                  key: const Key('auto_bill_clear_drafts_button'),
                  onPressed: onClearAll,
                  child: const Text('清空草稿'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (drafts.isEmpty)
            Padding(
              key: const Key('auto_bill_drafts_empty'),
              padding: const EdgeInsets.symmetric(vertical: 48),
              child: Center(
                child: Text(
                  '暂无待确认草稿\n开启无障碍识别或粘贴微信/支付宝/银行短信即可生成草稿',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ),
            )
          else
            for (final draft in drafts) ...[
              Card(
                key: Key('auto_bill_draft_${draft.id}'),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Chip(
                            label: Text(draft.displayApp),
                            visualDensity: VisualDensity.compact,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            RecordType.names[draft.recordType] ?? '支出',
                            style: theme.textTheme.labelMedium,
                          ),
                          const Spacer(),
                          Text(
                            '¥${draft.money.decimal}',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      if (draft.primaryRemark.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          draft.primaryRemark,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ],
                      const SizedBox(height: 4),
                      Text(
                        [
                          formatDateTime(
                            DateTime.fromMillisecondsSinceEpoch(
                              draft.recordTimeMs,
                            ),
                          ),
                          if (draft.categoryId != null &&
                              catMap[draft.categoryId] != null)
                            '分类：${catMap[draft.categoryId]}'
                          else if (draft.categoryHint != null)
                            '识别分类：${draft.categoryHint}',
                          if (draft.assetId != null &&
                              assetMap[draft.assetId] != null)
                            '账户：${assetMap[draft.assetId]}'
                          else if (draft.accountHint1 != null)
                            '识别账户：${draft.accountHint1}',
                        ].join(' · '),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            key: Key('auto_bill_delete_draft_${draft.id}'),
                            onPressed: () => onDelete(draft),
                            child: const Text('忽略'),
                          ),
                          TextButton(
                            key: Key('auto_bill_edit_confirm_${draft.id}'),
                            onPressed: () => onEditConfirm(draft),
                            child: const Text('编辑入账'),
                          ),
                          const SizedBox(width: 4),
                          FilledButton.tonal(
                            key: Key('auto_bill_quick_confirm_${draft.id}'),
                            onPressed: () => onQuickConfirm(draft),
                            child: const Text('确认入账'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
        ],
      );
    });
  }
}

class _RulesTabView extends StatelessWidget {
  const _RulesTabView({
    required this.rulesAsync,
    required this.categories,
    required this.assets,
    required this.onAddRule,
    required this.onEditRule,
    required this.onDeleteRule,
  });

  final AsyncValue<List<AutoMapRule>> rulesAsync;
  final List<RecordCategory> categories;
  final List<Asset> assets;
  final VoidCallback onAddRule;
  final ValueChanged<AutoMapRule> onEditRule;
  final ValueChanged<AutoMapRule> onDeleteRule;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return asyncBody(rulesAsync, (rules) {
      final catMap = {for (final c in categories) c.id: c.name};
      final assetMap = {for (final a in assets) a.id: a.name};

      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              key: const Key('auto_bill_add_rule_button'),
              onPressed: onAddRule,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('新增映射规则'),
            ),
          ),
          const SizedBox(height: 12),
          if (rules.isEmpty)
            Padding(
              key: const Key('auto_bill_rules_empty'),
              padding: const EdgeInsets.symmetric(vertical: 48),
              child: Center(
                child: Text(
                  '暂无自动映射规则\n添加商户或卡号关键词后，识别草稿将自动匹配账户与分类',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ),
            )
          else
            for (final rule in rules) ...[
              Card(
                key: Key('auto_bill_rule_${rule.id}'),
                child: ListTile(
                  title: Text(
                    rule.key,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(
                    [
                      if (rule.info.recordType != null)
                        '类型：${RecordType.names[rule.info.recordType] ?? '支出'}',
                      if (rule.info.mapCategoryId != null)
                        '分类：${catMap[rule.info.mapCategoryId] ?? '#${rule.info.mapCategoryId}'}',
                      if (rule.info.mapAssetId != null)
                        '账户：${assetMap[rule.info.mapAssetId] ?? '#${rule.info.mapAssetId}'}',
                      if (rule.info.remark != null) '备注：${rule.info.remark}',
                    ].join(' · '),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        key: Key('auto_bill_edit_rule_${rule.id}'),
                        tooltip: '编辑规则',
                        onPressed: () => onEditRule(rule),
                        icon: const Icon(Icons.edit_outlined),
                      ),
                      IconButton(
                        key: Key('auto_bill_delete_rule_${rule.id}'),
                        tooltip: '删除规则',
                        onPressed: () => onDeleteRule(rule),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
        ],
      );
    });
  }
}

class _PastePaymentTextDialog extends ConsumerStatefulWidget {
  const _PastePaymentTextDialog();

  @override
  ConsumerState<_PastePaymentTextDialog> createState() =>
      _PastePaymentTextDialogState();
}

class _PastePaymentTextDialogState
    extends ConsumerState<_PastePaymentTextDialog> {
  final TextEditingController _textController = TextEditingController();
  final CommandIds _commandIds = CommandIds();
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final service = await ref.read(autoBillServiceProvider.future);
      final text = _textController.text;
      await service.ingestPaymentText(
        commandId: _commandIds.forPayload(['paste-ingest', text]),
        rawText: text,
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
    title: const Text('粘贴支付文本识别'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('auto_bill_paste_input'),
            controller: _textController,
            maxLines: 5,
            decoration: const InputDecoration(
              hintText: '例如：【招商银行】您账户8888于11月11日12:30消费人民币36.50元，商户：瑞幸咖啡',
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
        onPressed: _saving ? null : () => Navigator.pop(context, false),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const Key('auto_bill_paste_submit'),
        onPressed: _saving ? null : _submit,
        child: const Text('解析并加入草稿'),
      ),
    ],
  );
}

class _ConfirmDraftDialog extends ConsumerStatefulWidget {
  const _ConfirmDraftDialog({
    required this.draft,
    required this.categories,
    required this.assets,
  });

  final AutoBillDraft draft;
  final List<RecordCategory> categories;
  final List<Asset> assets;

  @override
  ConsumerState<_ConfirmDraftDialog> createState() =>
      _ConfirmDraftDialogState();
}

class _ConfirmDraftDialogState extends ConsumerState<_ConfirmDraftDialog> {
  late final TextEditingController _amountController;
  late final TextEditingController _remarkController;
  final CommandIds _commandIds = CommandIds();

  late int _recordType;
  int? _categoryId;
  int? _assetId;
  int? _toAssetId;
  bool _learnRule = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _recordType = widget.draft.recordType;
    _categoryId = widget.draft.categoryId;
    _assetId = widget.draft.assetId;
    _toAssetId = widget.draft.toAssetId;
    _amountController = TextEditingController(text: widget.draft.money.decimal);
    _remarkController = TextEditingController(text: widget.draft.primaryRemark);
  }

  @override
  void dispose() {
    _amountController.dispose();
    _remarkController.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final Money money = parseUrlMoney(
        _amountController.text,
        fieldLabel: '入账金额',
      );
      final service = await ref.read(autoBillServiceProvider.future);
      final payload = [
        'confirm-dialog',
        widget.draft.id,
        _recordType,
        money.toJson(),
        _categoryId,
        _assetId,
        _toAssetId,
        _remarkController.text.trim(),
        _learnRule,
      ];
      await service.confirmDraft(
        commandId: _commandIds.forPayload(payload),
        draftId: widget.draft.id!,
        recordType: _recordType,
        money: money,
        categoryId: _categoryId,
        assetId: _assetId ?? noRef,
        toAssetId: _toAssetId,
        remark: _remarkController.text.trim(),
        learnRule: _learnRule,
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
  Widget build(BuildContext context) {
    final wantCatType = _recordType == RecordType.income
        ? RecordType.income
        : RecordType.expense;
    final dirCategories = widget.categories
        .where((c) => !c.isHide && c.type == wantCatType)
        .toList(growable: false);
    final validCatId = dirCategories.any((c) => c.id == _categoryId)
        ? _categoryId
        : dirCategories.firstOrNull?.id;
    final validAssetId = widget.assets.any((a) => a.id == _assetId)
        ? _assetId
        : null;
    final validToAssetId = widget.assets.any((a) => a.id == _toAssetId)
        ? _toAssetId
        : null;

    return AlertDialog(
      title: const Text('核对并确认入账'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: RecordType.expense, label: Text('支出')),
                  ButtonSegment(value: RecordType.income, label: Text('收入')),
                  ButtonSegment(value: RecordType.transfer, label: Text('转账')),
                ],
                selected: {_recordType},
                onSelectionChanged: (s) =>
                    setState(() => _recordType = s.first),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('confirm_draft_amount_input'),
                controller: _amountController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: '金额（元）',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_recordType != RecordType.transfer) ...[
                const SizedBox(height: 12),
                InputDecorator(
                  decoration: const InputDecoration(
                    labelText: '分类',
                    border: OutlineInputBorder(),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<int>(
                      isExpanded: true,
                      isDense: true,
                      value: validCatId,
                      items: [
                        for (final c in dirCategories)
                          DropdownMenuItem(value: c.id, child: Text(c.name)),
                      ],
                      onChanged: (v) => setState(() => _categoryId = v),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              InputDecorator(
                decoration: InputDecoration(
                  labelText: _recordType == RecordType.transfer
                      ? '转出账户'
                      : '资金账户',
                  border: const OutlineInputBorder(),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<int?>(
                    isExpanded: true,
                    isDense: true,
                    value: validAssetId,
                    items: [
                      if (_recordType != RecordType.transfer)
                        const DropdownMenuItem<int?>(
                          value: null,
                          child: Text('不选择账户'),
                        ),
                      for (final a in widget.assets)
                        DropdownMenuItem<int?>(
                          value: a.id,
                          child: Text(a.name),
                        ),
                    ],
                    onChanged: (v) => setState(() => _assetId = v),
                  ),
                ),
              ),
              if (_recordType == RecordType.transfer) ...[
                const SizedBox(height: 12),
                InputDecorator(
                  decoration: const InputDecoration(
                    labelText: '转入账户',
                    border: OutlineInputBorder(),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<int?>(
                      isExpanded: true,
                      isDense: true,
                      value: validToAssetId,
                      items: [
                        for (final a in widget.assets)
                          DropdownMenuItem<int?>(
                            value: a.id,
                            child: Text(a.name),
                          ),
                      ],
                      onChanged: (v) => setState(() => _toAssetId = v),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                key: const Key('confirm_draft_remark_input'),
                controller: _remarkController,
                decoration: const InputDecoration(
                  labelText: '备注',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _learnRule,
                onChanged: (v) => setState(() => _learnRule = v ?? false),
                title: const Text('同时记住为关键词映射规则'),
              ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('confirm_draft_submit_button'),
          onPressed: _saving ? null : _confirm,
          child: const Text('确认入账'),
        ),
      ],
    );
  }
}

class _RuleEditorDialog extends ConsumerStatefulWidget {
  const _RuleEditorDialog({
    this.existing,
    required this.categories,
    required this.assets,
    required this.currentBookId,
  });

  final AutoMapRule? existing;
  final List<RecordCategory> categories;
  final List<Asset> assets;
  final int currentBookId;

  @override
  ConsumerState<_RuleEditorDialog> createState() => _RuleEditorDialogState();
}

class _RuleEditorDialogState extends ConsumerState<_RuleEditorDialog> {
  late final TextEditingController _keyController;
  late final TextEditingController _remarkController;
  final CommandIds _commandIds = CommandIds();

  int? _recordType;
  int? _categoryId;
  int? _assetId;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _keyController = TextEditingController(text: existing?.key ?? '');
    _remarkController = TextEditingController(
      text: existing?.info.remark ?? '',
    );
    _recordType = existing?.info.recordType ?? RecordType.expense;
    _categoryId = existing?.info.mapCategoryId;
    _assetId = existing?.info.mapAssetId;
  }

  @override
  void dispose() {
    _keyController.dispose();
    _remarkController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final info = AutoMapInfo(
        raw: widget.existing?.info.raw,
        recordType: _recordType,
        mapCategoryId: _categoryId,
        mapAssetId: _assetId,
        bookId: widget.currentBookId,
        remark: _remarkController.text.trim().isEmpty
            ? null
            : _remarkController.text.trim(),
      );
      final service = await ref.read(autoBillServiceProvider.future);
      final keyText = _keyController.text;
      await service.saveRule(
        commandId: _commandIds.forPayload([
          'save-rule',
          widget.existing?.id,
          keyText,
          info.encode(),
        ]),
        id: widget.existing?.id,
        key: keyText,
        info: info,
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
  Widget build(BuildContext context) {
    final wantCatType = _recordType == RecordType.income
        ? RecordType.income
        : RecordType.expense;
    final visibleCats = widget.categories
        .where((c) => !c.isHide && c.type == wantCatType)
        .toList(growable: false);
    final validCatId = visibleCats.any((c) => c.id == _categoryId)
        ? _categoryId
        : null;
    final validAssetId = widget.assets.any((a) => a.id == _assetId)
        ? _assetId
        : null;

    return AlertDialog(
      key: const Key('auto_bill_rule_dialog'),
      title: Text(widget.existing == null ? '新增映射规则' : '编辑映射规则'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const Key('auto_bill_rule_key_input'),
                controller: _keyController,
                decoration: const InputDecoration(
                  labelText: '匹配关键词（商户名 / 卡号后四位 / 渠道）',
                  hintText: '例如：瑞幸咖啡 或 8888',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: RecordType.expense, label: Text('支出')),
                  ButtonSegment(value: RecordType.income, label: Text('收入')),
                ],
                selected: {_recordType ?? RecordType.expense},
                onSelectionChanged: (s) =>
                    setState(() => _recordType = s.first),
              ),
              const SizedBox(height: 12),
              InputDecorator(
                decoration: const InputDecoration(
                  labelText: '映射分类',
                  border: OutlineInputBorder(),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<int?>(
                    key: const Key('auto_bill_rule_category_dropdown'),
                    isExpanded: true,
                    isDense: true,
                    value: validCatId,
                    items: [
                      const DropdownMenuItem<int?>(
                        value: null,
                        child: Text('不指定分类'),
                      ),
                      for (final c in visibleCats)
                        DropdownMenuItem<int?>(
                          value: c.id,
                          child: Text(c.name),
                        ),
                    ],
                    onChanged: (v) => setState(() => _categoryId = v),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              InputDecorator(
                decoration: const InputDecoration(
                  labelText: '映射资金账户',
                  border: OutlineInputBorder(),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<int?>(
                    key: const Key('auto_bill_rule_asset_dropdown'),
                    isExpanded: true,
                    isDense: true,
                    value: validAssetId,
                    items: [
                      const DropdownMenuItem<int?>(
                        value: null,
                        child: Text('不指定账户'),
                      ),
                      for (final a in widget.assets)
                        DropdownMenuItem<int?>(
                          value: a.id,
                          child: Text(a.name),
                        ),
                    ],
                    onChanged: (v) => setState(() => _assetId = v),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('auto_bill_rule_remark_input'),
                controller: _remarkController,
                decoration: const InputDecoration(
                  labelText: '默认备注（可选）',
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
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('auto_bill_rule_save_button'),
          onPressed: _saving ? null : _save,
          child: const Text('保存规则'),
        ),
      ],
    );
  }
}
