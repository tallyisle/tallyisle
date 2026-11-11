import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/failure.dart';
import '../../data/db/database.dart';
import '../../platform/files.dart';
import '../common/common.dart';
import 'category_transfer_providers.dart';

class CategoryTransferPage extends ConsumerStatefulWidget {
  const CategoryTransferPage({
    super.key,
    this.initialBookId,
    this.initialTab = 0,
  });

  final int? initialBookId;
  final int initialTab;

  @override
  ConsumerState<CategoryTransferPage> createState() =>
      _CategoryTransferPageState();
}

class _CategoryTransferPageState extends ConsumerState<CategoryTransferPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final _ids = CommandIds();

  int? _jsonBookId;
  bool _jsonIncludeHidden = true;

  int? _copySourceBookId;
  int? _copyTargetBookId;
  bool _copyIncludeHidden = false;
  bool _copySelectSubset = false;
  final Set<int> _selectedSourceCategoryIds = <int>{};

  int? _migrateBookId;
  int _migrateType = 0;
  int? _migrateSourceCatId;
  int? _migrateTargetCatId;
  bool _migrateIncludeSubs = true;
  bool _migrateDeleteSource = false;

  bool _busy = false;
  String? _lastStatusMessage;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 3,
      vsync: this,
      initialIndex: widget.initialTab.clamp(0, 2),
    );
    _jsonBookId = widget.initialBookId;
    _copySourceBookId = widget.initialBookId;
    _migrateBookId = widget.initialBookId;
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  static String _formatCategoryOption(
    RecordCategory cat,
    Map<int, RecordCategory> byId,
  ) {
    if (cat.parentCatId != -1) {
      final parent = byId[cat.parentCatId];
      if (parent != null) {
        return '${parent.name} · ${cat.name}${cat.isHide ? '（已隐藏）' : ''}';
      }
    }
    return '${cat.name}${cat.isHide ? '（已隐藏）' : ''}';
  }

  Future<void> _exportSave(int bookId) async {
    setState(() => _busy = true);
    try {
      final service = await ref.read(categoryTransferServiceProvider.future);
      final fileAccess = ref.read(categoryTransferFileAccessProvider);
      final savedName = await service.exportCategoriesToSaveLocation(
        bookId: bookId,
        fileAccess: fileAccess,
        includeHidden: _jsonIncludeHidden,
      );
      if (!mounted) return;
      final msg = '分类方案已导出：$savedName';
      setState(() => _lastStatusMessage = msg);
      _showSnack(msg);
    } on Failure catch (e) {
      if (e.code == FailureCode.cancelled) return;
      _showSnack(e.message);
    } catch (e) {
      _showSnack(safeMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportShare(int bookId) async {
    setState(() => _busy = true);
    try {
      final service = await ref.read(categoryTransferServiceProvider.future);
      final fileAccess = ref.read(categoryTransferFileAccessProvider);
      final sharedName = await service.shareCategoriesPack(
        bookId: bookId,
        fileAccess: fileAccess,
        includeHidden: _jsonIncludeHidden,
      );
      if (!mounted) return;
      final msg = '已调起分类方案分享：$sharedName';
      setState(() => _lastStatusMessage = msg);
      _showSnack(msg);
    } on Failure catch (e) {
      if (e.code == FailureCode.cancelled) return;
      _showSnack(e.message);
    } catch (e) {
      _showSnack(safeMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickAndImport(int targetBookId, String targetBookName) async {
    setState(() => _busy = true);
    ({String fileName, CategoryPack pack})? picked;
    try {
      final service = await ref.read(categoryTransferServiceProvider.future);
      final fileAccess = ref.read(categoryTransferFileAccessProvider);
      picked = await service.pickCategoryPack(fileAccess: fileAccess);
    } on Failure catch (e) {
      if (mounted) setState(() => _busy = false);
      if (e.code == FailureCode.cancelled) return;
      _showSnack(e.message);
      return;
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      _showSnack(safeMessage(e));
      return;
    }

    if (!mounted) return;
    setState(() => _busy = false);

    final pack = picked.pack;
    final ok = await confirm(
      context,
      title: '确认导入分类方案',
      message:
          '文件：${picked.fileName}\n'
          '来源账本：${pack.bookName}\n'
          '包含一级分类 ${pack.topCategoryCount} 个、二级分类 ${pack.subCategoryCount} 个。\n'
          '将按同名去重规则合并到「$targetBookName」。',
      ok: '确认导入',
    );
    if (!ok || !mounted) return;

    setState(() => _busy = true);
    try {
      final service = await ref.read(categoryTransferServiceProvider.future);
      final result = await service.importCategoryPack(
        commandId: _ids.forPayload([
          'ui-import-cat-pack',
          targetBookId,
          pack.toJson(),
        ]),
        targetBookId: targetBookId,
        pack: pack,
      );
      if (!mounted) return;
      final msg =
          '导入完成：新增一级 ${result.addedTopCount} 个、二级 ${result.addedSubCount} 个，跳过同名 ${result.skippedDuplicateCount} 个';
      setState(() => _lastStatusMessage = msg);
      _showSnack(msg);
    } catch (e) {
      _showSnack(safeMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submitCrossBookCopy({
    required int sourceBookId,
    required int targetBookId,
  }) async {
    final subset = _copySelectSubset
        ? Set<int>.from(_selectedSourceCategoryIds)
        : null;
    if (subset != null && subset.isEmpty) {
      _showSnack('请至少勾选一个要复制的分类');
      return;
    }
    setState(() => _busy = true);
    try {
      final service = await ref.read(categoryTransferServiceProvider.future);
      final sortedSubset = subset == null ? null : (subset.toList()..sort());
      final result = await service.copyCategoriesBetweenBooks(
        commandId: _ids.forPayload([
          'ui-copy-cats',
          sourceBookId,
          targetBookId,
          sortedSubset,
          _copyIncludeHidden,
        ]),
        sourceBookId: sourceBookId,
        targetBookId: targetBookId,
        sourceCategoryIds: subset,
        includeHidden: _copyIncludeHidden,
      );
      if (!mounted) return;
      final msg =
          '复制完成：新增一级 ${result.addedTopCount} 个、二级 ${result.addedSubCount} 个，跳过同名 ${result.skippedDuplicateCount} 个';
      setState(() => _lastStatusMessage = msg);
      _showSnack(msg);
    } catch (e) {
      _showSnack(safeMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submitIntraBookMigration({
    required RecordCategory source,
    required RecordCategory target,
  }) async {
    final ok = await confirm(
      context,
      title: '确认迁移分类关联数据',
      message:
          '将「${source.name}」${source.parentCatId == -1 && _migrateIncludeSubs ? '（含其二级子分类）' : ''}下的账单、预算、周期记账、模板、分期及常用备注全部迁移至「${target.name}」'
          '${_migrateDeleteSource ? '，并在迁移后删除源分类' : ''}。',
      ok: '确认迁移',
    );
    if (!ok || !mounted) return;

    setState(() => _busy = true);
    try {
      final service = await ref.read(categoryTransferServiceProvider.future);
      final result = await service.migrateCategoryBills(
        commandId: _ids.forPayload([
          'ui-migrate-cat-bills',
          source.id,
          target.id,
          _migrateIncludeSubs,
          _migrateDeleteSource,
        ]),
        sourceCategoryId: source.id,
        targetCategoryId: target.id,
        includeSubcategories: _migrateIncludeSubs,
        deleteSourceAfterMigrate: _migrateDeleteSource,
      );
      if (!mounted) return;
      final msg =
          '迁移完成：账单 ${result.migratedRecordCount} 笔、预算 ${result.migratedBudgetCount} 项、'
          '周期 ${result.migratedPeriodCount} 条、模板 ${result.migratedTemplateCount} 个、'
          '分期 ${result.migratedInstallmentCount} 笔、备注 ${result.migratedRemarkCount} 条';
      setState(() {
        _lastStatusMessage = msg;
        if (_migrateDeleteSource) {
          _migrateSourceCatId = null;
        }
      });
      _showSnack(msg);
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('分类导入导出与迁移'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(key: Key('cat-transfer-tab-json'), text: '本地导入导出'),
            Tab(key: Key('cat-transfer-tab-copy'), text: '跨账本复制'),
            Tab(key: Key('cat-transfer-tab-migrate'), text: '分类迁移'),
          ],
        ),
      ),
      body: asyncBody(booksAsync, (books) {
        if (books.isEmpty) {
          return const Center(child: Text('暂无可用账本'));
        }
        final fallbackBookId = books.any((b) => b.id == activeBookId)
            ? activeBookId
            : books.first.id;
        final effectiveJsonBookId = books.any((b) => b.id == _jsonBookId)
            ? _jsonBookId!
            : fallbackBookId;
        final effectiveCopySourceId =
            books.any((b) => b.id == _copySourceBookId)
            ? _copySourceBookId!
            : fallbackBookId;
        final otherBooks = books
            .where((b) => b.id != effectiveCopySourceId)
            .toList();
        final effectiveCopyTargetId =
            otherBooks.any((b) => b.id == _copyTargetBookId)
            ? _copyTargetBookId
            : otherBooks.firstOrNull?.id;
        final effectiveMigrateBookId = books.any((b) => b.id == _migrateBookId)
            ? _migrateBookId!
            : fallbackBookId;

        return Column(
          children: [
            if (_lastStatusMessage != null)
              MaterialBanner(
                key: const Key('cat-transfer-status-banner'),
                content: Text(_lastStatusMessage!),
                leading: const Icon(Icons.check_circle_outline),
                actions: [
                  TextButton(
                    onPressed: () => setState(() => _lastStatusMessage = null),
                    child: const Text('知道了'),
                  ),
                ],
              ),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildJsonTab(books, effectiveJsonBookId),
                  _buildCrossBookCopyTab(
                    books: books,
                    sourceBookId: effectiveCopySourceId,
                    targetBookId: effectiveCopyTargetId,
                  ),
                  _buildMigrateTab(books, effectiveMigrateBookId),
                ],
              ),
            ),
          ],
        );
      }),
    );
  }

  Widget _buildJsonTab(List<AccountBook> books, int selectedBookId) {
    final catsAsync = ref.watch(allCategoriesProvider(selectedBookId));
    final fileAccess = ref.watch(categoryTransferFileAccessProvider);
    final shareCap = fileAccess.shareCapability;
    final selectedBook = books.firstWhere((b) => b.id == selectedBookId);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _BookDropdownField(
          fieldKey: const Key('cat-json-book-dropdown'),
          label: '选择操作账本',
          books: books,
          selectedBookId: selectedBookId,
          enabled: !_busy,
          onChanged: (id) => setState(() => _jsonBookId = id),
        ),
        const SizedBox(height: 12),
        catsAsync.when(
          data: (cats) {
            final visible = _jsonIncludeHidden
                ? cats
                : cats.where((c) => !c.isHide).toList();
            final expTop = visible
                .where((c) => c.type == 0 && c.parentCatId == -1)
                .length;
            final expSub = visible
                .where((c) => c.type == 0 && c.parentCatId != -1)
                .length;
            final incTop = visible
                .where((c) => c.type == 1 && c.parentCatId == -1)
                .length;
            final incSub = visible
                .where((c) => c.type == 1 && c.parentCatId != -1)
                .length;
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '「${selectedBook.name}」分类概览',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text('支出分类：一级 $expTop 个 · 二级 $expSub 个'),
                    const SizedBox(height: 4),
                    Text('收入分类：一级 $incTop 个 · 二级 $incSub 个'),
                  ],
                ),
              ),
            );
          },
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: LinearProgressIndicator(),
          ),
          error: (e, _) => Text(safeMessage(e)),
        ),
        SwitchListTile(
          key: const Key('cat-json-include-hidden'),
          title: const Text('导出时包含已隐藏分类'),
          value: _jsonIncludeHidden,
          onChanged: _busy
              ? null
              : (v) => setState(() => _jsonIncludeHidden = v),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          key: const Key('cat-export-save-btn'),
          onPressed: _busy ? null : () => _exportSave(selectedBookId),
          icon: const Icon(Icons.download_outlined),
          label: const Text('导出分类方案为 JSON 文件'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const Key('cat-export-share-btn'),
          onPressed: _busy || shareCap.state != CapabilityState.available
              ? null
              : () => _exportShare(selectedBookId),
          icon: const Icon(Icons.share_outlined),
          label: Text(
            shareCap.state == CapabilityState.available
                ? '系统分享分类方案 JSON'
                : '系统分享（${shareCap.reason}）',
          ),
        ),
        const Divider(height: 32),
        Text('从本地导入分类方案', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        const Text('支持导入帐屿导出的两级分类 .json 文件。同名同类型分类将自动复用合并，不会产生重复分类。'),
        const SizedBox(height: 12),
        FilledButton.tonalIcon(
          key: const Key('cat-import-pick-btn'),
          onPressed: _busy
              ? null
              : () => _pickAndImport(selectedBookId, selectedBook.name),
          icon: const Icon(Icons.upload_file_outlined),
          label: Text('选择 JSON 文件导入到「${selectedBook.name}」'),
        ),
      ],
    );
  }

  Widget _buildCrossBookCopyTab({
    required List<AccountBook> books,
    required int sourceBookId,
    required int? targetBookId,
  }) {
    if (books.length < 2) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '当前仅有一个账本。新建更多账本后，可在此一键跨账本复制两级分类树。',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final targetOptions = books.where((b) => b.id != sourceBookId).toList();
    final sourceCatsAsync = ref.watch(allCategoriesProvider(sourceBookId));

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _BookDropdownField(
          fieldKey: const Key('cat-copy-source-book'),
          label: '源账本（复制来源）',
          books: books,
          selectedBookId: sourceBookId,
          enabled: !_busy,
          onChanged: (id) => setState(() {
            _copySourceBookId = id;
            _selectedSourceCategoryIds.clear();
            if (_copyTargetBookId == id) {
              _copyTargetBookId = books
                  .where((b) => b.id != id)
                  .firstOrNull
                  ?.id;
            }
          }),
        ),
        const SizedBox(height: 12),
        _BookDropdownField(
          fieldKey: const Key('cat-copy-target-book'),
          label: '目标账本（合并去向）',
          books: targetOptions,
          selectedBookId: targetBookId ?? targetOptions.first.id,
          enabled: !_busy,
          onChanged: (id) => setState(() => _copyTargetBookId = id),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          key: const Key('cat-copy-include-hidden'),
          title: const Text('包含已隐藏分类'),
          value: _copyIncludeHidden,
          onChanged: _busy
              ? null
              : (v) => setState(() => _copyIncludeHidden = v),
        ),
        SwitchListTile(
          key: const Key('cat-copy-subset-toggle'),
          title: const Text('仅复制勾选的指定分类'),
          subtitle: const Text('关闭时复制源账本全部可用分类'),
          value: _copySelectSubset,
          onChanged: _busy
              ? null
              : (v) => setState(() => _copySelectSubset = v),
        ),
        if (_copySelectSubset)
          sourceCatsAsync.when(
            data: (cats) {
              final byId = {for (final c in cats) c.id: c};
              final visible = _copyIncludeHidden
                  ? cats
                  : cats.where((c) => !c.isHide).toList();
              return Card(
                margin: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  children: [
                    for (final c in visible)
                      CheckboxListTile(
                        key: Key('cat-copy-check-${c.id}'),
                        dense: true,
                        title: Text(_formatCategoryOption(c, byId)),
                        subtitle: Text(c.type == 0 ? '支出' : '收入'),
                        value: _selectedSourceCategoryIds.contains(c.id),
                        onChanged: _busy
                            ? null
                            : (checked) => setState(() {
                                if (checked == true) {
                                  _selectedSourceCategoryIds.add(c.id);
                                } else {
                                  _selectedSourceCategoryIds.remove(c.id);
                                }
                              }),
                      ),
                  ],
                ),
              );
            },
            loading: () => const LinearProgressIndicator(),
            error: (e, _) => Text(safeMessage(e)),
          ),
        const SizedBox(height: 16),
        FilledButton.icon(
          key: const Key('cat-copy-submit-btn'),
          onPressed: _busy || targetBookId == null
              ? null
              : () => _submitCrossBookCopy(
                  sourceBookId: sourceBookId,
                  targetBookId: targetBookId,
                ),
          icon: const Icon(Icons.copy_all_outlined),
          label: const Text('开始复制到目标账本'),
        ),
      ],
    );
  }

  Widget _buildMigrateTab(List<AccountBook> books, int bookId) {
    final catsAsync = ref.watch(allCategoriesProvider(bookId));

    return catsAsync.when(
      loading: () => const Loading(),
      error: (e, _) => ErrorView(e),
      data: (allCats) {
        final typedCats = allCats.where((c) => c.type == _migrateType).toList();
        final byId = {for (final c in typedCats) c.id: c};

        final validSource = typedCats
            .where((c) => c.id == _migrateSourceCatId)
            .firstOrNull;
        final effectiveSource = validSource ?? typedCats.firstOrNull;

        final excludedIds = <int>{
          if (effectiveSource != null) effectiveSource.id,
          if (effectiveSource != null &&
              effectiveSource.parentCatId == -1 &&
              _migrateIncludeSubs)
            for (final c in typedCats)
              if (c.parentCatId == effectiveSource.id) c.id,
        };
        final targetCandidates = typedCats
            .where((c) => !excludedIds.contains(c.id))
            .toList();
        final effectiveTarget =
            targetCandidates
                .where((c) => c.id == _migrateTargetCatId)
                .firstOrNull ??
            targetCandidates.firstOrNull;

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _BookDropdownField(
              fieldKey: const Key('cat-migrate-book'),
              label: '所属账本',
              books: books,
              selectedBookId: bookId,
              enabled: !_busy,
              onChanged: (id) => setState(() {
                _migrateBookId = id;
                _migrateSourceCatId = null;
                _migrateTargetCatId = null;
              }),
            ),
            const SizedBox(height: 12),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('支出分类')),
                ButtonSegment(value: 1, label: Text('收入分类')),
              ],
              selected: {_migrateType},
              onSelectionChanged: _busy
                  ? null
                  : (sel) => setState(() {
                      _migrateType = sel.first;
                      _migrateSourceCatId = null;
                      _migrateTargetCatId = null;
                    }),
            ),
            const SizedBox(height: 16),
            if (typedCats.length < 2)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('当前类型下不足两个分类，无法执行分类间迁移。'),
                ),
              )
            else ...[
              _ControlledDropdownField<int>(
                fieldKey: const Key('cat-migrate-source'),
                label: '迁出源分类',
                value: effectiveSource?.id,
                items: [
                  for (final c in typedCats)
                    DropdownMenuItem(
                      value: c.id,
                      child: Text(_formatCategoryOption(c, byId)),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (id) => setState(() => _migrateSourceCatId = id),
              ),
              const SizedBox(height: 12),
              _ControlledDropdownField<int>(
                fieldKey: const Key('cat-migrate-target'),
                label: '迁入目标分类',
                value: effectiveTarget?.id,
                items: [
                  for (final c in targetCandidates)
                    DropdownMenuItem(
                      value: c.id,
                      child: Text(_formatCategoryOption(c, byId)),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (id) => setState(() => _migrateTargetCatId = id),
              ),
              if (effectiveSource != null && effectiveSource.parentCatId == -1)
                SwitchListTile(
                  key: const Key('cat-migrate-include-subs'),
                  title: const Text('包含源分类下的全部二级子分类'),
                  value: _migrateIncludeSubs,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _migrateIncludeSubs = v),
                ),
              SwitchListTile(
                key: const Key('cat-migrate-delete-source'),
                title: const Text('迁移完成后删除源分类'),
                value: _migrateDeleteSource,
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _migrateDeleteSource = v),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const Key('cat-migrate-submit-btn'),
                onPressed:
                    _busy || effectiveSource == null || effectiveTarget == null
                    ? null
                    : () => _submitIntraBookMigration(
                        source: effectiveSource,
                        target: effectiveTarget,
                      ),
                icon: const Icon(Icons.drive_file_move_outlined),
                label: const Text('执行关联数据迁移'),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _BookDropdownField extends StatelessWidget {
  const _BookDropdownField({
    required this.fieldKey,
    required this.label,
    required this.books,
    required this.selectedBookId,
    required this.enabled,
    required this.onChanged,
  });

  final Key fieldKey;
  final String label;
  final List<AccountBook> books;
  final int selectedBookId;
  final bool enabled;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final valid = books.any((b) => b.id == selectedBookId)
        ? selectedBookId
        : books.firstOrNull?.id;
    return _ControlledDropdownField<int>(
      fieldKey: fieldKey,
      label: label,
      value: valid,
      items: [
        for (final b in books)
          DropdownMenuItem(value: b.id, child: Text(b.name)),
      ],
      onChanged: enabled
          ? (v) {
              if (v != null) onChanged(v);
            }
          : null,
    );
  }
}

class _ControlledDropdownField<T> extends StatelessWidget {
  const _ControlledDropdownField({
    required this.fieldKey,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final Key fieldKey;
  final String label;
  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;

  @override
  Widget build(BuildContext context) {
    final effectiveValue = items.any((item) => item.value == value)
        ? value
        : null;
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          key: fieldKey,
          isExpanded: true,
          value: effectiveValue,
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
  }
}
