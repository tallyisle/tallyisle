import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../app/adaptive.dart';
import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/template_card_rules.dart';
import '../common/common.dart';
import '../common/desktop_modal_page.dart';
import '../me/me_page.dart' show MeEmbeddedNavigationScope;
import 'remarks_page.dart';
import 'template_editor_page.dart';
import 'template_providers.dart';

export '../../domain/rules/template_card_rules.dart' show TemplatePrefill;
export 'remarks_page.dart' show FrequentRemarkChips, RemarksPage;

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
    if (DesktopAdaptive.isDesktop(context)) {
      pushDesktopModalOrMaterialRoute<void>(
        context,
        child: const TemplatesPage(),
      );
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
        return ConstrainedBox(
          key: const Key('template_quick_bar'),
          constraints: const BoxConstraints(minHeight: 44),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
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

/// Management page for Bill Templates (`F-016`).
class TemplatesPage extends ConsumerStatefulWidget {
  const TemplatesPage({super.key});

  @override
  ConsumerState<TemplatesPage> createState() => _TemplatesPageState();
}

class _TemplatesPageState extends ConsumerState<TemplatesPage> {
  static const int _allBooksSentinel = -1;

  int _selectedBookFilter = _allBooksSentinel;
  bool _busy = false;
  List<int>? _optimisticAllTemplateIds;
  int _reorderSeq = 0;
  final CommandIds _toggleIds = CommandIds();
  final CommandIds _deleteIds = CommandIds();
  final CommandIds _reorderIds = CommandIds();

  int? get _bookFilterOrNull =>
      _selectedBookFilter == _allBooksSentinel ? null : _selectedBookFilter;

  Future<void> _openCreate() async {
    final currentBookId = ref.read(currentBookIdProvider).value;
    await pushDesktopModalOrMaterialRoute<int>(
      context,
      child: TemplateEditorPage(
        initialBookId: _bookFilterOrNull ?? currentBookId,
        initialType: ref.read(templateTypeFilterProvider),
      ),
    );
    if (mounted) {
      ref.invalidate(allBookCategoriesMapProvider);
    }
  }

  Future<void> _openEdit(RecordTemplate t) async {
    await pushDesktopModalOrMaterialRoute<int>(
      context,
      child: TemplateEditorPage(templateId: t.id),
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

  List<RecordTemplate> _applyOptimisticTemplates(
    List<RecordTemplate> rawTemplates,
  ) {
    final optimisticIds = _optimisticAllTemplateIds;
    if (optimisticIds == null || optimisticIds.length != rawTemplates.length) {
      return rawTemplates;
    }
    final byId = <int, RecordTemplate>{for (final t in rawTemplates) t.id: t};
    final ordered = <RecordTemplate>[];
    for (final id in optimisticIds) {
      final match = byId[id];
      if (match == null) return rawTemplates;
      ordered.add(match);
    }
    return ordered;
  }

  static List<int> _permuteSubsetSlots({
    required List<int> fullIds,
    required List<int> reorderedSubsetIds,
  }) {
    final subsetSet = reorderedSubsetIds.toSet();
    var cursor = 0;
    return <int>[
      for (final id in fullIds)
        if (subsetSet.contains(id)) reorderedSubsetIds[cursor++] else id,
    ];
  }

  Future<void> _reorderVisibleTemplates({
    required List<RecordTemplate> allTemplates,
    required List<RecordTemplate> visibleRows,
    required int oldIndex,
    required int newIndex,
  }) async {
    if (_busy || oldIndex == newIndex) return;
    final nextVisible = List<RecordTemplate>.from(visibleRows);
    final moved = nextVisible.removeAt(oldIndex);
    nextVisible.insert(newIndex, moved);

    final mergedIds = _permuteSubsetSlots(
      fullIds: allTemplates.map((t) => t.id).toList(),
      reorderedSubsetIds: nextVisible.map((t) => t.id).toList(),
    );

    setState(() {
      _optimisticAllTemplateIds = mergedIds;
    });

    try {
      final svc = await ref.read(templateRemarkServiceProvider.future);
      await svc.reorderTemplates(
        commandId: _reorderIds.forPayload(<Object?>[
          'reorder-tpl',
          _reorderSeq++,
          mergedIds,
        ]),
        orderedIds: mergedIds,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _optimisticAllTemplateIds = null;
      });
      _showTemplateSnack(context, safeMessage(e));
    }
  }

  Widget _buildReorderProxy(
    Widget child,
    int index,
    Animation<double> animation,
  ) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(animation.value);
        final scheme = Theme.of(context).colorScheme;
        return Material(
          elevation: 6 * t,
          color: Colors.transparent,
          shadowColor: scheme.shadow.withValues(alpha: 0.28),
          borderRadius: BorderRadius.circular(14),
          child: child,
        );
      },
      child: child,
    );
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

    const allFilterQuery = (bookId: null, type: null);
    final allTemplatesAsync = ref.watch(templatesQueryProvider(allFilterQuery));
    ref.listen<AsyncValue<List<RecordTemplate>>>(
      templatesQueryProvider(allFilterQuery),
      (_, next) {
        final rows = next.value;
        final optimistic = _optimisticAllTemplateIds;
        if (rows == null || optimistic == null) return;
        final dbIds = rows.map((t) => t.id).toList();
        if (dbIds.length != optimistic.length ||
            listEquals(dbIds, optimistic)) {
          if (mounted) {
            setState(() => _optimisticAllTemplateIds = null);
          }
        }
      },
    );

    final isDesktop = DesktopAdaptive.isDesktop(context);
    final meScope = MeEmbeddedNavigationScope.maybeOf(context);
    final isPopupModal = isDesktop && ModalRoute.of(context) is PopupRoute;

    return DesktopModalEscapeScope(
      enabled: isPopupModal,
      child: Scaffold(
        key: const Key('templates_page'),
        appBar: AppBar(
          leading: isPopupModal ? const CloseButton() : null,
          scrolledUnderElevation: isDesktop ? 0 : null,
          title: const Text('账单模板'),
          actions: [
            TallySoftButton.icon(
              key: const Key('open_remarks_page_button'),
              compact: true,
              onPressed: () {
                if (meScope != null) {
                  meScope.onSelectRoute('/remarks');
                  return;
                }
                if (isDesktop) {
                  pushDesktopModalOrMaterialRoute<void>(
                    context,
                    child: const RemarksPage(),
                  );
                  return;
                }
                Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const RemarksPage()),
                );
              },
              icon: const Icon(Icons.comment_outlined, size: 18),
              label: const Text('常用备注'),
            ),
            if (isDesktop) ...[
              const SizedBox(width: 8),
              TallySoftButton.icon(
                key: const Key('add_template_fab'),
                compact: true,
                onPressed: _openCreate,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('新建模板'),
              ),
              const SizedBox(width: 12),
            ] else
              const SizedBox(width: 12),
          ],
        ),
        floatingActionButton: isDesktop
            ? null
            : FloatingActionButton.extended(
                key: const Key('add_template_fab'),
                heroTag: 'fab-templates',
                onPressed: _openCreate,
                icon: const Icon(Icons.add),
                label: const Text('新建模板'),
              ),
        body: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: isDesktop ? 800 : 720),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TallyFormCard(
                  margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
                  spacing: 10,
                  children: [
                    TallySelectField<int>(
                      key: const Key('templates_book_filter'),
                      label: '筛选账本',
                      value: controlledBookFilter,
                      options: [
                        const TallySelectOption<int>(
                          value: _allBooksSentinel,
                          label: '全部账本',
                        ),
                        for (final b in books)
                          TallySelectOption<int>(value: b.id, label: b.name),
                      ],
                      onChanged: (v) => setState(() => _selectedBookFilter = v),
                    ),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
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
                  ],
                ),
                Expanded(
                  child: asyncBody(allTemplatesAsync, (rawAll) {
                    final allTemplates = _applyOptimisticTemplates(rawAll);
                    final targetBookId =
                        controlledBookFilter == _allBooksSentinel
                        ? null
                        : controlledBookFilter;
                    final rows = allTemplates.where((t) {
                      if (targetBookId != null && t.bookId != targetBookId) {
                        return false;
                      }
                      if (selectedType != null && t.type != selectedType) {
                        return false;
                      }
                      return true;
                    }).toList();

                    if (rows.isEmpty) {
                      return const Center(
                        child: SingleChildScrollView(
                          child: TallyEmptyState(
                            key: Key('templates_empty_state'),
                            icon: Icons.bookmark_border_rounded,
                            title: '暂无账单模板',
                            subtitle: '把高频固定收支存为模板，记账时一键快速填入',
                          ),
                        ),
                      );
                    }
                    return ReorderableListView.builder(
                      key: ValueKey(
                        'templates-reorder-list-${targetBookId ?? "all"}-${selectedType ?? "all"}',
                      ),
                      buildDefaultDragHandles: false,
                      padding: EdgeInsets.fromLTRB(
                        16,
                        4,
                        16,
                        isDesktop ? 24 : 88,
                      ),
                      itemCount: rows.length,
                      onReorderStart: (_) {
                        if (!isDesktop) {
                          HapticFeedback.selectionClick();
                        }
                      },
                      proxyDecorator: _buildReorderProxy,
                      onReorderItem: (oldIndex, newIndex) =>
                          _reorderVisibleTemplates(
                            allTemplates: allTemplates,
                            visibleRows: rows,
                            oldIndex: oldIndex,
                            newIndex: newIndex,
                          ),
                      itemBuilder: (context, index) {
                        final t = rows[index];
                        final dragHandle = isDesktop
                            ? ReorderableDragStartListener(
                                index: index,
                                enabled: !_busy,
                                child: MouseRegion(
                                  cursor: _busy
                                      ? SystemMouseCursors.basic
                                      : SystemMouseCursors.grab,
                                  child: Padding(
                                    key: Key('template-drag-handle-${t.id}'),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 2,
                                      vertical: 2,
                                    ),
                                    child: Icon(
                                      Icons.drag_handle_rounded,
                                      size: 20,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.outline,
                                    ),
                                  ),
                                ),
                              )
                            : null;
                        final cardWidget = Padding(
                          padding: EdgeInsets.only(
                            bottom: index == rows.length - 1 ? 0 : 8,
                          ),
                          child: _TemplateCardTile(
                            template: t,
                            bookMap: bookMap,
                            catMap: catMap,
                            assetMap: assetMap,
                            tagMap: tagMap,
                            busy: _busy,
                            dragHandle: dragHandle,
                            onEdit: () => _openEdit(t),
                            onDelete: () => _deleteTemplate(t),
                            onApplyInstant: () => _applyInstant(t),
                            onToggleAutoSave: (v) => _toggleAutoSave(t, v),
                          ),
                        );
                        if (isDesktop) {
                          return KeyedSubtree(
                            key: ValueKey('template-reorder-item-${t.id}'),
                            child: cardWidget,
                          );
                        }
                        return ReorderableDelayedDragStartListener(
                          key: ValueKey('template-reorder-item-${t.id}'),
                          index: index,
                          enabled: !_busy,
                          child: cardWidget,
                        );
                      },
                    );
                  }),
                ),
              ],
            ),
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
    this.dragHandle,
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
  final Widget? dragHandle;
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
      margin: EdgeInsets.zero,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: _tonalCardShape,
      color: _tonalCardColor(Theme.of(context)),
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
                  if (dragHandle != null) ...[
                    dragHandle!,
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  const SizedBox(width: 8),
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
                    for (final tag in tagNames) _TemplateBadge(label: '#$tag'),
                    if (template.excludeExIn)
                      const _TemplateBadge(label: '不计收支'),
                    if (template.excludeBudget)
                      const _TemplateBadge(label: '不计预算'),
                  ],
                ),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  const Text('秒记'),
                  const SizedBox(width: 4),
                  Switch(
                    key: Key('template_autosave_switch_${template.id}'),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    value: template.autoSave,
                    onChanged: busy ? null : onToggleAutoSave,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: TallySoftButton.icon(
                          key: Key('template_apply_button_${template.id}'),
                          compact: true,
                          onPressed: busy ? null : onApplyInstant,
                          icon: const Icon(Icons.playlist_add_check, size: 16),
                          label: const Text(
                            '记一笔',
                            maxLines: 1,
                            softWrap: false,
                          ),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    key: Key('template_edit_button_${template.id}'),
                    visualDensity: VisualDensity.compact,
                    tooltip: '编辑',
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    onPressed: busy ? null : onEdit,
                  ),
                  IconButton(
                    key: Key('template_delete_button_${template.id}'),
                    visualDensity: VisualDensity.compact,
                    tooltip: '删除',
                    icon: const Icon(Icons.delete_outline, size: 20),
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

class _TemplateBadge extends StatelessWidget {
  const _TemplateBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: tallyNestedSurfaceColor(theme.colorScheme),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
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
