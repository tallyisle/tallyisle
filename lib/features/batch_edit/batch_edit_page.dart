import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../domain/ledger/record_extra.dart';
import '../../domain/ledger/record_relations.dart';
import '../../domain/model/codes.dart';
import '../common/common.dart';
import 'batch_edit_providers.dart';

class BatchEditPage extends ConsumerStatefulWidget {
  const BatchEditPage({
    super.key,
    this.initialBookId,
    this.initialSelectedIds = const <String>{},
  });

  final int? initialBookId;
  final Set<String> initialSelectedIds;

  @override
  ConsumerState<BatchEditPage> createState() => _BatchEditPageState();
}

class _BatchEditPageState extends ConsumerState<BatchEditPage> {
  final _searchController = TextEditingController();
  final _ids = CommandIds();
  late final Set<String> _selectedIds = {...widget.initialSelectedIds};

  int? _bookId;
  String _keyword = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _bookId = widget.initialBookId;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  static String _catTitle(List<RecordCategory> cats, int id) {
    final c = cats.where((x) => x.id == id).firstOrNull;
    if (c == null) return '未分类';
    if (c.parentCatId != -1) {
      final p = cats.where((x) => x.id == c.parentCatId).firstOrNull;
      if (p != null) return '${p.name} · ${c.name}';
    }
    return c.name;
  }

  static String _assetTitle(List<Asset> assets, int id) => id == noRef
      ? '无账户'
      : (assets.where((a) => a.id == id).firstOrNull?.name ?? '已删除账户');

  static (String title, String subtitle, String amount) _describeRecord(
    LedgerRecord r,
    List<RecordCategory> cats,
    List<Asset> assets,
  ) {
    final dt = DateTime.fromMillisecondsSinceEpoch(r.recordTime);
    final timeStr = formatDateTime(dt);
    final rawAmt = formatMinor(r.moneyMinor.abs());

    if (r.type == RecordType.transfer) {
      final pair =
          '${_assetTitle(assets, r.fromAssetId)} → ${_assetTitle(assets, r.toAssetId)}';
      return (
        '转账',
        [timeStr, pair, if (r.remark.isNotEmpty) r.remark].join(' · '),
        rawAmt,
      );
    }

    final isRefund =
        (r.type == RecordType.expense || r.type == RecordType.income) &&
        r.moneyMinor < BigInt.zero;
    final catPart = requiredCategoryTypeForRecord(r.type) != null
        ? _catTitle(cats, r.recordCatId)
        : (RecordType.names[r.type] ?? '账单');
    final title = isRefund ? '退款 · $catPart' : catPart;

    final int effectiveAsset = r.type == RecordType.reimbursable
        ? r.fromAssetId
        : r.assetId;
    final subtitle = [
      timeStr,
      if (effectiveAsset != noRef) _assetTitle(assets, effectiveAsset),
      if (r.remark.isNotEmpty) r.remark,
    ].join(' · ');

    final sign = switch (r.type) {
      RecordType.expense when r.moneyMinor < BigInt.zero => '+',
      RecordType.income when r.moneyMinor < BigInt.zero => '-',
      RecordType.expense ||
      RecordType.reimbursable ||
      RecordType.fee ||
      RecordType.installmentPrincipal ||
      RecordType.advanceExpense => '-',
      RecordType.income ||
      RecordType.depositInterest ||
      RecordType.advanceIncome => '+',
      _ => '',
    };
    return (title, subtitle, '$sign$rawAmt');
  }

  Future<void> _confirmBatchDelete(List<LedgerRecord> selectedRecords) async {
    if (selectedRecords.isEmpty) return;
    final ids = [for (final r in selectedRecords) r.recordId];
    final ok = await confirm(
      context,
      title: '确认批量删除',
      message:
          '将永久删除已选中的 ${ids.length} 笔账单（含关联转账手续费及退款/报销子记录），并自动回冲关联账户余额。此操作不可撤销。',
      ok: '确认删除',
    );
    if (!ok || !mounted) return;

    setState(() => _busy = true);
    try {
      final service = await ref.read(batchRecordServiceProvider.future);
      final sorted = ids.toList()..sort();
      final result = await service.batchDelete(
        commandId: _ids.forPayload(['ui-batch-delete', sorted]),
        recordIds: ids,
      );
      if (!mounted) return;
      setState(() => _selectedIds.removeAll(ids));
      _showSnack(
        '已删除 ${result.deletedPrimaryCount} 笔账单（共清理 ${result.deletedTotalRowCount} 条记录）',
      );
    } catch (e) {
      _showSnack(safeMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openBatchEditSheet({
    required int currentBookId,
    required List<AccountBook> books,
    required List<Asset> assets,
    required List<Tag> tags,
    required List<LedgerRecord> selectedRecords,
  }) async {
    if (selectedRecords.isEmpty) return;

    // Pre-check R1 editability so the user gets immediate clear feedback.
    try {
      for (final r in selectedRecords) {
        validateRecordEditableInBatch(
          type: r.type,
          relations: RecordRelations.parse(r.relInfo),
          extra: RecordExtra.parse(r.extraInfo),
        );
      }
    } catch (e) {
      _showSnack(safeMessage(e));
      return;
    }

    final patch = await showModalBottomSheet<BatchEditPatch>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _BatchEditConfigSheet(
        currentBookId: currentBookId,
        books: books,
        assets: assets,
        tags: tags,
        selectedRecords: selectedRecords,
      ),
    );
    if (patch == null || !patch.hasChanges || !mounted) return;

    setState(() => _busy = true);
    try {
      final service = await ref.read(batchRecordServiceProvider.future);
      final ids = [for (final r in selectedRecords) r.recordId]..sort();
      final result = await service.batchEdit(
        commandId: _ids.forPayload([
          'ui-batch-edit',
          ids,
          patch.toPayloadJson(),
        ]),
        recordIds: ids,
        patch: patch,
      );
      if (!mounted) return;
      setState(() => _selectedIds.clear());
      _showSnack('已批量更新 ${result.updatedRecordCount} 笔账单');
    } catch (e) {
      _showSnack(safeMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final booksAsync = ref.watch(booksProvider);
    final activeBookId = ref.watch(currentBookIdProvider).value ?? 1;
    final assets = ref.watch(assetsProvider).value ?? const <Asset>[];
    final tags = ref.watch(tagsProvider).value ?? const <Tag>[];

    return Scaffold(
      appBar: AppBar(title: const Text('账单批量管理')),
      body: asyncBody(booksAsync, (books) {
        if (books.isEmpty) {
          return const Center(child: Text('暂无账本'));
        }
        final effectiveBookId = books.any((b) => b.id == _bookId)
            ? _bookId!
            : (books.any((b) => b.id == activeBookId)
                  ? activeBookId
                  : books.first.id);

        final recordsAsync = ref.watch(
          batchBookRecordsProvider(effectiveBookId),
        );
        final cats =
            ref.watch(allCategoriesProvider(effectiveBookId)).value ??
            const <RecordCategory>[];

        return recordsAsync.when(
          loading: () => const Loading(),
          error: (e, _) => ErrorView(e),
          data: (allRecords) {
            final kw = _keyword.trim().toLowerCase();
            final visibleRecords = kw.isEmpty
                ? allRecords
                : allRecords.where((r) {
                    final (title, sub, amt) = _describeRecord(r, cats, assets);
                    return title.toLowerCase().contains(kw) ||
                        sub.toLowerCase().contains(kw) ||
                        amt.toLowerCase().contains(kw);
                  }).toList();

            final selectedInBook = allRecords
                .where((r) => _selectedIds.contains(r.recordId))
                .toList();

            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: InputDecorator(
                          decoration: const InputDecoration(
                            labelText: '当前账本',
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 2,
                            ),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<int>(
                              key: const Key('batch-book-dropdown'),
                              isExpanded: true,
                              value: effectiveBookId,
                              items: [
                                for (final b in books)
                                  DropdownMenuItem(
                                    value: b.id,
                                    child: Text(b.name),
                                  ),
                              ],
                              onChanged: _busy
                                  ? null
                                  : (id) {
                                      if (id == null) return;
                                      setState(() {
                                        _bookId = id;
                                        _selectedIds.clear();
                                      });
                                    },
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        key: const Key('batch-select-all'),
                        onPressed: _busy || visibleRecords.isEmpty
                            ? null
                            : () => setState(() {
                                for (final r in visibleRecords) {
                                  _selectedIds.add(r.recordId);
                                }
                              }),
                        child: const Text('全选'),
                      ),
                      TextButton(
                        key: const Key('batch-invert-select'),
                        onPressed: _busy || visibleRecords.isEmpty
                            ? null
                            : () => setState(() {
                                for (final r in visibleRecords) {
                                  if (!_selectedIds.remove(r.recordId)) {
                                    _selectedIds.add(r.recordId);
                                  }
                                }
                              }),
                        child: const Text('反选'),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    key: const Key('batch-search-input'),
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: '搜索分类、备注、账户或金额',
                      prefixIcon: const Icon(Icons.search),
                      isDense: true,
                      border: const OutlineInputBorder(),
                      suffixIcon: _keyword.isEmpty
                          ? null
                          : IconButton(
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _keyword = '');
                              },
                              icon: const Icon(Icons.clear),
                            ),
                    ),
                    onChanged: (v) => setState(() => _keyword = v),
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: visibleRecords.isEmpty
                      ? const Center(child: Text('当前条件下暂无可操作的账单'))
                      : ListView.separated(
                          itemCount: visibleRecords.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final r = visibleRecords[index];
                            final (title, subtitle, amount) = _describeRecord(
                              r,
                              cats,
                              assets,
                            );
                            final checked = _selectedIds.contains(r.recordId);
                            return CheckboxListTile(
                              key: Key('batch-item-${r.recordId}'),
                              controlAffinity: ListTileControlAffinity.leading,
                              value: checked,
                              onChanged: _busy
                                  ? null
                                  : (val) => setState(() {
                                      if (val == true) {
                                        _selectedIds.add(r.recordId);
                                      } else {
                                        _selectedIds.remove(r.recordId);
                                      }
                                    }),
                              title: Row(
                                children: [
                                  Expanded(child: Text(title)),
                                  Text(
                                    amount,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                              subtitle: Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            );
                          },
                        ),
                ),
                Material(
                  elevation: 8,
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  child: SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '已选 ${selectedInBook.length} 笔',
                              key: const Key('batch-selected-count'),
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                          OutlinedButton.icon(
                            key: const Key('batch-delete-btn'),
                            onPressed: _busy || selectedInBook.isEmpty
                                ? null
                                : () => _confirmBatchDelete(selectedInBook),
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('批量删除'),
                          ),
                          const SizedBox(width: 12),
                          FilledButton.icon(
                            key: const Key('batch-open-edit-btn'),
                            onPressed: _busy || selectedInBook.isEmpty
                                ? null
                                : () => _openBatchEditSheet(
                                    currentBookId: effectiveBookId,
                                    books: books,
                                    assets: assets,
                                    tags: tags,
                                    selectedRecords: selectedInBook,
                                  ),
                            icon: const Icon(Icons.edit_note),
                            label: const Text('批量修改'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      }),
    );
  }
}

class _BatchEditConfigSheet extends ConsumerStatefulWidget {
  const _BatchEditConfigSheet({
    required this.currentBookId,
    required this.books,
    required this.assets,
    required this.tags,
    required this.selectedRecords,
  });

  final int currentBookId;
  final List<AccountBook> books;
  final List<Asset> assets;
  final List<Tag> tags;
  final List<LedgerRecord> selectedRecords;

  @override
  ConsumerState<_BatchEditConfigSheet> createState() =>
      _BatchEditConfigSheetState();
}

class _BatchEditConfigSheetState extends ConsumerState<_BatchEditConfigSheet> {
  bool _editCategory = false;
  int? _targetCategoryId;

  bool _editAsset = false;
  int _targetAssetId = noRef;

  bool _editBook = false;
  int? _targetBookId;

  bool _editDate = false;
  DateTime _shiftDate = DateTime.now();

  final Set<String> _addTagIds = <String>{};
  final Set<String> _removeTagIds = <String>{};

  bool? _excludeBudget;
  bool? _excludeExIn;

  int? get _uniformCategoryDirection {
    int? common;
    for (final r in widget.selectedRecords) {
      final dir = requiredCategoryTypeForRecord(r.type);
      if (dir == null) return null;
      if (common == null) {
        common = dir;
      } else if (common != dir) {
        return null;
      }
    }
    return common;
  }

  bool get _canEditAsset => widget.selectedRecords.every(
    (r) =>
        batchEditableAssetSlot(
          type: r.type,
          relations: RecordRelations.parse(r.relInfo),
        ) !=
        BatchAssetSlot.unsupported,
  );

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _shiftDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) {
      setState(() => _shiftDate = picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final effectiveBookForCats = _editBook && _targetBookId != null
        ? _targetBookId!
        : widget.currentBookId;
    final cats =
        ref.watch(allCategoriesProvider(effectiveBookForCats)).value ??
        const <RecordCategory>[];
    final catDir = _uniformCategoryDirection;
    final matchingCats = catDir == null
        ? const <RecordCategory>[]
        : cats.where((c) => c.type == catDir && !c.isHide).toList();
    final catById = {for (final c in cats) c.id: c};

    final validCatId = matchingCats.any((c) => c.id == _targetCategoryId)
        ? _targetCategoryId
        : matchingCats.firstOrNull?.id;

    final fundingAssets = widget.assets
        .where(
          (a) => a.type != AssetType.debt && a.status != AssetStatus.settled,
        )
        .toList();
    final validAssetIds = <int>{noRef, for (final a in fundingAssets) a.id};
    final effectiveAssetId = validAssetIds.contains(_targetAssetId)
        ? _targetAssetId
        : noRef;

    final otherBooks = widget.books
        .where((b) => b.id != widget.currentBookId)
        .toList();
    final effectiveTargetBookId = otherBooks.any((b) => b.id == _targetBookId)
        ? _targetBookId
        : otherBooks.firstOrNull?.id;

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '批量修改 ${widget.selectedRecords.length} 笔账单',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),

            // 1. Category
            SwitchListTile(
              key: const Key('batch-toggle-category'),
              contentPadding: EdgeInsets.zero,
              title: const Text('统一修改分类'),
              subtitle: catDir == null
                  ? const Text('所选账单包含转账/借贷或收支方向不一致，不可统一改分类')
                  : null,
              value: _editCategory && catDir != null,
              onChanged: catDir == null || matchingCats.isEmpty
                  ? null
                  : (v) => setState(() {
                      _editCategory = v;
                      _targetCategoryId ??= matchingCats.first.id;
                    }),
            ),
            if (_editCategory && catDir != null && matchingCats.isNotEmpty)
              InputDecorator(
                decoration: const InputDecoration(
                  labelText: '目标分类',
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                    key: const Key('batch-target-category'),
                    isExpanded: true,
                    value: validCatId,
                    items: [
                      for (final c in matchingCats)
                        DropdownMenuItem(
                          value: c.id,
                          child: Text(
                            c.parentCatId != -1 &&
                                    catById[c.parentCatId] != null
                                ? '${catById[c.parentCatId]!.name} · ${c.name}'
                                : c.name,
                          ),
                        ),
                    ],
                    onChanged: (v) => setState(() => _targetCategoryId = v),
                  ),
                ),
              ),

            // 2. Asset
            SwitchListTile(
              key: const Key('batch-toggle-asset'),
              contentPadding: EdgeInsets.zero,
              title: const Text('统一修改账户'),
              subtitle: _canEditAsset
                  ? null
                  : const Text('所选账单包含转账或借贷记录，不可统一改账户'),
              value: _editAsset && _canEditAsset,
              onChanged: !_canEditAsset
                  ? null
                  : (v) => setState(() => _editAsset = v),
            ),
            if (_editAsset && _canEditAsset)
              InputDecorator(
                decoration: const InputDecoration(
                  labelText: '目标资金账户',
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                    key: const Key('batch-target-asset'),
                    isExpanded: true,
                    value: effectiveAssetId,
                    items: [
                      const DropdownMenuItem(value: noRef, child: Text('无账户')),
                      for (final a in fundingAssets)
                        DropdownMenuItem(value: a.id, child: Text(a.name)),
                    ],
                    onChanged: (v) {
                      if (v != null) setState(() => _targetAssetId = v);
                    },
                  ),
                ),
              ),

            // 3. Target Book
            if (otherBooks.isNotEmpty) ...[
              SwitchListTile(
                key: const Key('batch-toggle-book'),
                contentPadding: EdgeInsets.zero,
                title: const Text('移动到其他账本'),
                subtitle: const Text('自动同步子单并映射目标账本同名分类'),
                value: _editBook,
                onChanged: (v) => setState(() {
                  _editBook = v;
                  _targetBookId ??= otherBooks.first.id;
                  _targetCategoryId = null;
                }),
              ),
              if (_editBook && effectiveTargetBookId != null)
                InputDecorator(
                  decoration: const InputDecoration(
                    labelText: '目标账本',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<int>(
                      key: const Key('batch-target-book'),
                      isExpanded: true,
                      value: effectiveTargetBookId,
                      items: [
                        for (final b in otherBooks)
                          DropdownMenuItem(value: b.id, child: Text(b.name)),
                      ],
                      onChanged: (v) => setState(() {
                        _targetBookId = v;
                        _targetCategoryId = null;
                      }),
                    ),
                  ),
                ),
            ],

            // 4. Date Shift
            SwitchListTile(
              key: const Key('batch-toggle-date'),
              contentPadding: EdgeInsets.zero,
              title: const Text('统一修改日期'),
              subtitle: const Text('保留每笔账单原有的时分秒'),
              value: _editDate,
              onChanged: (v) => setState(() => _editDate = v),
            ),
            if (_editDate)
              OutlinedButton.icon(
                key: const Key('batch-pick-date-btn'),
                onPressed: _pickDate,
                icon: const Icon(Icons.calendar_today_outlined),
                label: Text('目标日期：${formatDate(_shiftDate)}'),
              ),

            // 5. Tags
            if (widget.tags.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('增加标签', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final t in widget.tags)
                    FilterChip(
                      key: Key('batch-add-tag-${t.tagId}'),
                      label: Text('+ ${t.name}'),
                      selected: _addTagIds.contains(t.tagId),
                      onSelected: (sel) => setState(() {
                        if (sel) {
                          _addTagIds.add(t.tagId);
                          _removeTagIds.remove(t.tagId);
                        } else {
                          _addTagIds.remove(t.tagId);
                        }
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text('移除标签', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final t in widget.tags)
                    FilterChip(
                      key: Key('batch-rm-tag-${t.tagId}'),
                      label: Text('- ${t.name}'),
                      selected: _removeTagIds.contains(t.tagId),
                      onSelected: (sel) => setState(() {
                        if (sel) {
                          _removeTagIds.add(t.tagId);
                          _addTagIds.remove(t.tagId);
                        } else {
                          _removeTagIds.remove(t.tagId);
                        }
                      }),
                    ),
                ],
              ),
            ],

            // 6. Exclude Budget / ExIn
            const SizedBox(height: 12),
            _TriStateBoolRow(
              rowKey: const Key('batch-exclude-budget-row'),
              label: '不计入预算',
              value: _excludeBudget,
              onChanged: (v) => setState(() => _excludeBudget = v),
            ),
            const SizedBox(height: 8),
            _TriStateBoolRow(
              rowKey: const Key('batch-exclude-exin-row'),
              label: '不计入收支',
              value: _excludeExIn,
              onChanged: (v) => setState(() => _excludeExIn = v),
            ),

            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const Key('batch-apply-edit-btn'),
                  onPressed: () {
                    final patch = BatchEditPatch(
                      targetCategoryId: _editCategory && catDir != null
                          ? validCatId
                          : null,
                      targetAssetId: _editAsset && _canEditAsset
                          ? effectiveAssetId
                          : null,
                      targetBookId: _editBook ? effectiveTargetBookId : null,
                      shiftToDate: _editDate ? _shiftDate : null,
                      addTagIds: _addTagIds,
                      removeTagIds: _removeTagIds,
                      excludeBudget: _excludeBudget,
                      excludeExIn: _excludeExIn,
                    );
                    if (!patch.hasChanges) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('请至少选择一项要修改的内容')),
                      );
                      return;
                    }
                    Navigator.pop(context, patch);
                  },
                  child: const Text('确认修改'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TriStateBoolRow extends StatelessWidget {
  const _TriStateBoolRow({
    required this.rowKey,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final Key rowKey;
  final String label;
  final bool? value;
  final ValueChanged<bool?> onChanged;

  @override
  Widget build(BuildContext context) {
    final code = value == null ? -1 : (value! ? 1 : 0);
    return Row(
      key: rowKey,
      children: [
        Expanded(child: Text(label)),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: -1, label: Text('不改')),
            ButtonSegment(value: 1, label: Text('开启')),
            ButtonSegment(value: 0, label: Text('关闭')),
          ],
          selected: {code},
          onSelectionChanged: (sel) {
            final chosen = sel.first;
            onChanged(chosen == -1 ? null : (chosen == 1));
          },
        ),
      ],
    );
  }
}
