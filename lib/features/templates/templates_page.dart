import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/template_card_rules.dart';
import '../common/common.dart';
import 'remarks_page.dart';
import 'template_editor_page.dart';
import 'template_providers.dart';

export '../../domain/rules/template_card_rules.dart' show TemplatePrefill;
export 'remarks_page.dart' show FrequentRemarkChips;

const _quickUuid = Uuid();

void _showTemplateSnack(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(text)));
}

/// Reusable horizontal quick-template bar for `RecordEditorPage` (`F-016` R3).
///
/// Tapping a template with `autoSave == true` immediately books a bill via
/// `TemplateRemarkService.applyTemplateInstant` and notifies [onInstantSaved];
/// tapping a template with `autoSave == false` resolves a [TemplatePrefill]
/// (falling back cleanly if linked category/account was deleted) and invokes
/// [onPrefill]. Long-pressing any template always prefills without auto-saving.
class TemplateQuickBar extends ConsumerStatefulWidget {
  const TemplateQuickBar({
    super.key,
    required this.bookId,
    this.recordType,
    required this.onPrefill,
    this.onInstantSaved,
    this.onManageTemplates,
    this.recordTimeMs,
    this.enabled = true,
  });

  final int bookId;
  final int? recordType;
  final ValueChanged<TemplatePrefill> onPrefill;
  final ValueChanged<String>? onInstantSaved;
  final VoidCallback? onManageTemplates;
  final int? recordTimeMs;
  final bool enabled;

  @override
  ConsumerState<TemplateQuickBar> createState() => _TemplateQuickBarState();
}

class _TemplateQuickBarState extends ConsumerState<TemplateQuickBar> {
  bool _busy = false;

  Future<void> _handleTap(
    RecordTemplate template, {
    bool forcePrefill = false,
  }) async {
    if (_busy || !widget.enabled) return;
    setState(() => _busy = true);
    try {
      final svc = await ref.read(templateRemarkServiceProvider.future);
      if (template.autoSave && !forcePrefill) {
        try {
          final recordId = await svc.applyTemplateInstant(
            commandId: _quickUuid.v4(),
            templateId: template.id,
            recordTimeMs: widget.recordTimeMs,
          );
          if (!mounted) return;
          _showTemplateSnack(context, '已通过模板生成账单');
          widget.onInstantSaved?.call(recordId);
          return;
        } catch (instantError) {
          // If linked category/account was deleted, fall back to form prefill
          // and surface the validation reason so the user can fix it cleanly.
          final prefill = await svc.buildTemplatePrefill(template.id);
          if (!mounted) return;
          widget.onPrefill(prefill);
          _showTemplateSnack(context, safeMessage(instantError));
          return;
        }
      }

      final prefill = await svc.buildTemplatePrefill(template.id);
      if (!mounted) return;
      widget.onPrefill(prefill);
      if (prefill.warnings.isNotEmpty) {
        _showTemplateSnack(context, prefill.warnings.first);
      }
    } catch (e) {
      if (!mounted) return;
      _showTemplateSnack(context, safeMessage(e));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _openManage() {
    if (widget.onManageTemplates != null) {
      widget.onManageTemplates!();
      return;
    }
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const TemplatesPage()));
  }

  @override
  Widget build(BuildContext context) {
    final query = (bookId: widget.bookId, type: widget.recordType);
    final templatesAsync = ref.watch(templatesQueryProvider(query));
    return templatesAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (rows) {
        if (rows.isEmpty && widget.onManageTemplates == null) {
          return const SizedBox.shrink();
        }
        return SizedBox(
          key: const Key('template_quick_bar'),
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final t in rows)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GestureDetector(
                    onLongPress: _busy || !widget.enabled
                        ? null
                        : () => _handleTap(t, forcePrefill: true),
                    child: ActionChip(
                      key: Key('quick_template_${t.id}'),
                      avatar: Icon(
                        t.autoSave
                            ? Icons.flash_on_rounded
                            : Icons.bookmark_outline,
                        size: 16,
                      ),
                      label: Text(_chipLabel(t)),
                      onPressed: _busy || !widget.enabled
                          ? null
                          : () => _handleTap(t),
                    ),
                  ),
                ),
              if (widget.onManageTemplates != null || rows.isNotEmpty)
                ActionChip(
                  key: const Key('quick_template_manage'),
                  avatar: const Icon(Icons.settings_outlined, size: 16),
                  label: const Text('模板'),
                  onPressed: _busy || !widget.enabled ? null : _openManage,
                ),
            ],
          ),
        );
      },
    );
  }

  String _chipLabel(RecordTemplate t) {
    final extra = TemplateExtra.parse(t.exi);
    final remark = (t.remark ?? '').trim();
    final title =
        extra.name ?? (remark.isNotEmpty ? remark : templateTypeLabel(t.type));
    if (t.moneyMinor > BigInt.zero) {
      return '$title ¥${formatMinor(t.moneyMinor)}';
    }
    return title;
  }
}

/// Management page for Bill Templates (`F-016`, original `/bkp/RTAct`).
class TemplatesPage extends ConsumerStatefulWidget {
  const TemplatesPage({super.key});

  @override
  ConsumerState<TemplatesPage> createState() => _TemplatesPageState();
}

class _TemplatesPageState extends ConsumerState<TemplatesPage> {
  static const int _allBooksSentinel = -1;

  int _selectedBookFilter = _allBooksSentinel;
  bool _busy = false;
  final CommandIds _toggleIds = CommandIds();
  final CommandIds _deleteIds = CommandIds();

  int? get _bookFilterOrNull =>
      _selectedBookFilter == _allBooksSentinel ? null : _selectedBookFilter;

  Future<void> _openCreate() async {
    final currentBookId = ref.read(currentBookIdProvider).value;
    await Navigator.of(context).push(
      MaterialPageRoute<int>(
        builder: (_) => TemplateEditorPage(
          initialBookId: _bookFilterOrNull ?? currentBookId,
          initialType: ref.read(templateTypeFilterProvider),
        ),
      ),
    );
    if (mounted) {
      ref.invalidate(allBookCategoriesMapProvider);
    }
  }

  Future<void> _openEdit(RecordTemplate t) async {
    await Navigator.of(context).push(
      MaterialPageRoute<int>(
        builder: (_) => TemplateEditorPage(templateId: t.id),
      ),
    );
    if (mounted) {
      ref.invalidate(allBookCategoriesMapProvider);
    }
  }

  Future<void> _toggleAutoSave(RecordTemplate t, bool nextValue) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final svc = await ref.read(templateRemarkServiceProvider.future);
      await svc.setTemplateAutoSave(
        commandId: _toggleIds.forPayload(<Object?>[
          'autosave',
          t.id,
          nextValue,
          t.moneyMinor.toString(),
          t.recordCatId,
          t.assetId,
          t.assetId2,
        ]),
        templateId: t.id,
        autoSave: nextValue,
      );
    } catch (e) {
      if (!mounted) return;
      _showTemplateSnack(context, safeMessage(e));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _applyInstant(RecordTemplate t) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final svc = await ref.read(templateRemarkServiceProvider.future);
      await svc.applyTemplateInstant(
        commandId: _quickUuid.v4(),
        templateId: t.id,
      );
      if (!mounted) return;
      _showTemplateSnack(context, '已通过模板生成账单');
    } catch (e) {
      if (!mounted) return;
      _showTemplateSnack(context, safeMessage(e));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _deleteTemplate(RecordTemplate t) async {
    final ok = await confirm(
      context,
      title: '确认删除此模板？',
      message: '删除模板不会影响此前已生成的账单。',
      ok: '删除',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      final svc = await ref.read(templateRemarkServiceProvider.future);
      await svc.deleteTemplate(
        commandId: _deleteIds.forPayload(<Object?>['del-tpl', t.id]),
        templateId: t.id,
      );
      if (!mounted) return;
      _showTemplateSnack(context, '已删除账单模板');
    } catch (e) {
      if (!mounted) return;
      _showTemplateSnack(context, safeMessage(e));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedType = ref.watch(templateTypeFilterProvider);
    final books = ref.watch(booksProvider).value ?? const <AccountBook>[];
    final assets = ref.watch(assetsProvider).value ?? const <Asset>[];
    final tags = ref.watch(tagsProvider).value ?? const <Tag>[];
    final catMap =
        ref.watch(allBookCategoriesMapProvider).value ??
        const <int, RecordCategory>{};

    final bookMap = <int, AccountBook>{for (final b in books) b.id: b};
    final assetMap = <int, Asset>{for (final a in assets) a.id: a};
    final tagMap = <String, Tag>{for (final t in tags) t.tagId: t};

    final controlledBookFilter =
        (_selectedBookFilter == _allBooksSentinel ||
            bookMap.containsKey(_selectedBookFilter))
        ? _selectedBookFilter
        : _allBooksSentinel;

    final templatesAsync = ref.watch(
      templatesQueryProvider((
        bookId: controlledBookFilter == _allBooksSentinel
            ? null
            : controlledBookFilter,
        type: selectedType,
      )),
    );

    return Scaffold(
      key: const Key('templates_page'),
      appBar: AppBar(
        title: const Text('账单模板'),
        actions: [
          TextButton.icon(
            key: const Key('open_remarks_page_button'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const RemarksPage()),
            ),
            icon: const Icon(Icons.comment_outlined, size: 18),
            label: const Text('常用备注'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('add_template_fab'),
        onPressed: _openCreate,
        icon: const Icon(Icons.add),
        label: const Text('新建模板'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: '筛选账本',
                    border: OutlineInputBorder(),
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<int>(
                      key: const Key('templates_book_filter'),
                      isExpanded: true,
                      isDense: true,
                      value: controlledBookFilter,
                      items: [
                        const DropdownMenuItem<int>(
                          value: _allBooksSentinel,
                          child: Text('全部账本'),
                        ),
                        for (final b in books)
                          DropdownMenuItem<int>(
                            value: b.id,
                            child: Text(b.name),
                          ),
                      ],
                      onChanged: (v) {
                        if (v != null) {
                          setState(() => _selectedBookFilter = v);
                        }
                      },
                    ),
                  ),
                ),
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    for (final (value, label) in const <(int?, String)>[
                      (null, '全部'),
                      (RecordType.expense, '支出'),
                      (RecordType.income, '收入'),
                      (RecordType.transfer, '转账'),
                      (RecordType.reimbursable, '报销'),
                      (RecordType.advanceExpense, '预支'),
                      (RecordType.advanceIncome, '预收'),
                    ])
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          key: Key('template_filter_${value ?? "all"}'),
                          label: Text(label),
                          selected: selectedType == value,
                          onSelected: (_) => ref
                              .read(templateTypeFilterProvider.notifier)
                              .select(value),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: asyncBody(templatesAsync, (rows) {
                  if (rows.isEmpty) {
                    return Center(
                      key: const Key('templates_empty_state'),
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          '暂无账单模板，点击右下角“新建模板”添加常用记账项',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                    );
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 88),
                    itemCount: rows.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final t = rows[index];
                      return _TemplateCardTile(
                        template: t,
                        bookMap: bookMap,
                        catMap: catMap,
                        assetMap: assetMap,
                        tagMap: tagMap,
                        busy: _busy,
                        onEdit: () => _openEdit(t),
                        onDelete: () => _deleteTemplate(t),
                        onApplyInstant: () => _applyInstant(t),
                        onToggleAutoSave: (v) => _toggleAutoSave(t, v),
                      );
                    },
                  );
                }),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TemplateCardTile extends StatelessWidget {
  const _TemplateCardTile({
    required this.template,
    required this.bookMap,
    required this.catMap,
    required this.assetMap,
    required this.tagMap,
    required this.busy,
    required this.onEdit,
    required this.onDelete,
    required this.onApplyInstant,
    required this.onToggleAutoSave,
  });

  final RecordTemplate template;
  final Map<int, AccountBook> bookMap;
  final Map<int, RecordCategory> catMap;
  final Map<int, Asset> assetMap;
  final Map<String, Tag> tagMap;
  final bool busy;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onApplyInstant;
  final ValueChanged<bool> onToggleAutoSave;

  @override
  Widget build(BuildContext context) {
    final extra = TemplateExtra.parse(template.exi);
    final cat = template.recordCatId == null
        ? null
        : catMap[template.recordCatId!];
    final remark = (template.remark ?? '').trim();
    final title =
        extra.name ??
        (remark.isNotEmpty
            ? remark
            : (cat?.name ?? templateTypeLabel(template.type)));
    final bookName = bookMap[template.bookId]?.name ?? '已删账本';

    final details = <String>[templateTypeLabel(template.type), bookName];
    if (template.type == RecordType.transfer) {
      final fromName = template.assetId == noRef
          ? '未选转出户'
          : (assetMap[template.assetId]?.name ?? '已删转出户');
      final toName = template.assetId2 == noRef
          ? '未选转入户'
          : (assetMap[template.assetId2]?.name ?? '已删转入户');
      details.add('$fromName → $toName');
      if (template.feeMinor > BigInt.zero) {
        details.add('手续费 ¥${formatMinor(template.feeMinor)}');
      }
    } else {
      if (template.recordCatId != null && template.recordCatId != noRef) {
        details.add(cat == null || cat.isHide ? '分类已失效' : cat.name);
      }
      if (template.assetId != noRef) {
        final a = assetMap[template.assetId];
        details.add(
          a == null || a.status == AssetStatus.settled ? '账户已失效' : a.name,
        );
      }
    }

    final tagNames = <String>[
      for (final id in parseTemplateTagsCsv(template.tags))
        if (tagMap[id] != null && !tagMap[id]!.hidden) tagMap[id]!.name,
    ];

    return Card(
      key: Key('template_card_${template.id}'),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: busy ? null : onEdit,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  Text(
                    '${extra.sourceCurrency ?? '¥'} ${formatMinor(template.moneyMinor)}',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                details.join(' · '),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (remark.isNotEmpty && extra.name != null) ...[
                const SizedBox(height: 2),
                Text(
                  '备注：$remark',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              if (tagNames.isNotEmpty ||
                  template.excludeBudget ||
                  template.excludeExIn) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final tag in tagNames)
                      Chip(
                        visualDensity: VisualDensity.compact,
                        label: Text('#$tag'),
                      ),
                    if (template.excludeExIn)
                      const Chip(
                        visualDensity: VisualDensity.compact,
                        label: Text('不计收支'),
                      ),
                    if (template.excludeBudget)
                      const Chip(
                        visualDensity: VisualDensity.compact,
                        label: Text('不计预算'),
                      ),
                  ],
                ),
              ],
              const Divider(height: 16),
              Row(
                children: [
                  const Text('秒记'),
                  Switch(
                    key: Key('template_autosave_switch_${template.id}'),
                    value: template.autoSave,
                    onChanged: busy ? null : onToggleAutoSave,
                  ),
                  const Spacer(),
                  TextButton.icon(
                    key: Key('template_apply_button_${template.id}'),
                    onPressed: busy ? null : onApplyInstant,
                    icon: const Icon(Icons.playlist_add_check, size: 18),
                    label: const Text('记一笔'),
                  ),
                  IconButton(
                    key: Key('template_edit_button_${template.id}'),
                    tooltip: '编辑',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: busy ? null : onEdit,
                  ),
                  IconButton(
                    key: Key('template_delete_button_${template.id}'),
                    tooltip: '删除',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: busy ? null : onDelete,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
