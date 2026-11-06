import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/money.dart';
import '../../data/db/database.dart';
import '../../data/repo/search_queries.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/income_expense.dart';
import '../common/common.dart';
import '../records/record_labels.dart';

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _keywordController = TextEditingController();
  final _minMoneyController = TextEditingController();
  final _maxMoneyController = TextEditingController();

  int? _selectedType;
  final Set<int> _selectedCategoryIds = {};
  int? _selectedAssetId;
  DateTime? _startDate;
  DateTime? _endDate;
  bool _filterExpanded = false;
  int _limit = 50;

  @override
  void dispose() {
    _keywordController.dispose();
    _minMoneyController.dispose();
    _maxMoneyController.dispose();
    super.dispose();
  }

  BigInt? _parseMoneyMinor(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    try {
      return Money.parse(trimmed).units;
    } catch (_) {
      return null;
    }
  }

  void _resetFilters() {
    setState(() {
      _keywordController.clear();
      _minMoneyController.clear();
      _maxMoneyController.clear();
      _selectedType = null;
      _selectedCategoryIds.clear();
      _selectedAssetId = null;
      _startDate = null;
      _endDate = null;
      _limit = 50;
    });
  }

  bool get _hasActiveFilters =>
      _keywordController.text.trim().isNotEmpty ||
      _selectedType != null ||
      _selectedCategoryIds.isNotEmpty ||
      _selectedAssetId != null ||
      _startDate != null ||
      _endDate != null ||
      _minMoneyController.text.trim().isNotEmpty ||
      _maxMoneyController.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final bookId = ref.watch(currentBookIdProvider).value ?? 1;
    final categories = ref.watch(categoriesProvider(bookId)).value ?? const [];
    final assets = ref.watch(assetsProvider).value ?? const <Asset>[];

    final filter = SearchFilter(
      bookId: bookId,
      keyword: _keywordController.text.trim().isEmpty
          ? null
          : _keywordController.text.trim(),
      type: _selectedType,
      categoryIds: _selectedCategoryIds.isEmpty
          ? null
          : Set.of(_selectedCategoryIds),
      assetId: _selectedAssetId,
      startMs: _startDate?.millisecondsSinceEpoch,
      endMs: _endDate == null
          ? null
          : DateTime(
              _endDate!.year,
              _endDate!.month,
              _endDate!.day,
              23,
              59,
              59,
              999,
            ).millisecondsSinceEpoch,
      minMoneyMinor: _parseMoneyMinor(_minMoneyController.text),
      maxMoneyMinor: _parseMoneyMinor(_maxMoneyController.text),
      limit: _limit,
      offset: 0,
    );

    final recordsAsync = ref.watch(searchRecordsProvider(filter));
    final summaryAsync = ref.watch(searchSummaryProvider(filter));

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          key: const Key('search-keyword-field'),
          controller: _keywordController,
          autofocus: false,
          decoration: InputDecoration(
            hintText: '搜索备注关键词…',
            border: InputBorder.none,
            suffixIcon: _keywordController.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      _keywordController.clear();
                      setState(() {});
                    },
                  )
                : null,
          ),
          onChanged: (_) => setState(() {}),
        ),
        actions: [
          IconButton(
            key: const Key('search-filter-toggle'),
            icon: Badge(
              isLabelVisible: _hasActiveFilters,
              child: Icon(
                _filterExpanded ? Icons.filter_list_off : Icons.filter_list,
              ),
            ),
            tooltip: _filterExpanded ? '收起筛选' : '展开筛选',
            onPressed: () => setState(() => _filterExpanded = !_filterExpanded),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_filterExpanded) _buildFilterPanel(context, categories, assets),
          _buildSummaryBar(context, summaryAsync),
          Expanded(
            child: recordsAsync.when(
              data: (records) {
                if (records.isEmpty) {
                  return const Center(child: Text('未找到符合条件的账单'));
                }
                return ListView(
                  children: [
                    ..._buildGroupedRecords(
                      context,
                      records,
                      categories,
                      assets,
                    ),
                    if (records.length >= _limit)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 16,
                          horizontal: 32,
                        ),
                        child: OutlinedButton(
                          key: const Key('search-load-more'),
                          onPressed: () => setState(() => _limit += 50),
                          child: const Text('加载更多'),
                        ),
                      ),
                    const SizedBox(height: 32),
                  ],
                );
              },
              loading: () => const Loading(),
              error: (err, _) => ErrorView(err),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterPanel(
    BuildContext context,
    List<RecordCategory> categories,
    List<Asset> assets,
  ) {
    final theme = Theme.of(context);
    return Material(
      elevation: 2,
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Type row
            Row(
              children: [
                Text('类型：', style: theme.textTheme.bodyMedium),
                const SizedBox(width: 8),
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('全部'),
                        selected: _selectedType == null,
                        onSelected: (selected) {
                          if (selected) setState(() => _selectedType = null);
                        },
                      ),
                      ChoiceChip(
                        label: const Text('支出'),
                        selected: _selectedType == RecordType.expense,
                        onSelected: (selected) {
                          setState(
                            () => _selectedType = selected
                                ? RecordType.expense
                                : null,
                          );
                        },
                      ),
                      ChoiceChip(
                        label: const Text('收入'),
                        selected: _selectedType == RecordType.income,
                        onSelected: (selected) {
                          setState(
                            () => _selectedType = selected
                                ? RecordType.income
                                : null,
                          );
                        },
                      ),
                      ChoiceChip(
                        label: const Text('转账'),
                        selected: _selectedType == RecordType.transfer,
                        onSelected: (selected) {
                          setState(
                            () => _selectedType = selected
                                ? RecordType.transfer
                                : null,
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Time range row
            Row(
              children: [
                Text('时间：', style: theme.textTheme.bodyMedium),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.date_range, size: 18),
                    label: Text(
                      _startDate == null && _endDate == null
                          ? '选择日期范围'
                          : '${_startDate == null ? '不限' : formatDate(_startDate!)} ~ ${_endDate == null ? '不限' : formatDate(_endDate!)}',
                    ),
                    onPressed: () async {
                      final picked = await showDateRangePicker(
                        context: context,
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                        initialDateRange: _startDate != null && _endDate != null
                            ? DateTimeRange(start: _startDate!, end: _endDate!)
                            : null,
                      );
                      if (picked != null) {
                        setState(() {
                          _startDate = picked.start;
                          _endDate = picked.end;
                        });
                      }
                    },
                  ),
                ),
                if (_startDate != null || _endDate != null)
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: '清除日期',
                    onPressed: () => setState(() {
                      _startDate = null;
                      _endDate = null;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 8),

            // Account & Category dropdowns
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int?>(
                    initialValue: _selectedAssetId,
                    decoration: const InputDecoration(
                      labelText: '账户',
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                    ),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('所有账户')),
                      for (final a in assets)
                        DropdownMenuItem(value: a.id, child: Text(a.name)),
                    ],
                    onChanged: (val) => setState(() => _selectedAssetId = val),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonFormField<int?>(
                    initialValue: _selectedCategoryIds.length == 1
                        ? _selectedCategoryIds.first
                        : null,
                    decoration: const InputDecoration(
                      labelText: '分类',
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                    ),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('所有分类')),
                      for (final c in categories)
                        DropdownMenuItem(value: c.id, child: Text(c.name)),
                    ],
                    onChanged: (val) {
                      setState(() {
                        _selectedCategoryIds.clear();
                        if (val != null) _selectedCategoryIds.add(val);
                      });
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Money range inputs
            Row(
              children: [
                Text('金额：', style: theme.textTheme.bodyMedium),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _minMoneyController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      hintText: '最低金额',
                      isDense: true,
                      prefixText: '¥ ',
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4),
                  child: Text('~'),
                ),
                Expanded(
                  child: TextField(
                    controller: _maxMoneyController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      hintText: '最高金额',
                      isDense: true,
                      prefixText: '¥ ',
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Reset button
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('重置筛选'),
                onPressed: _resetFilters,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryBar(
    BuildContext context,
    AsyncValue<IncomeExpense> summaryAsync,
  ) {
    final theme = Theme.of(context);
    final summary = summaryAsync.value ?? IncomeExpense.zero;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _summaryColumn(
            '支出',
            formatMinor(summary.expense),
            Colors.red.shade700,
          ),
          _summaryColumn(
            '收入',
            formatMinor(summary.income),
            Colors.green.shade700,
          ),
          _summaryColumn(
            '结余',
            formatMinor(summary.balance),
            theme.textTheme.bodyMedium?.color,
          ),
        ],
      ),
    );
  }

  Widget _summaryColumn(String label, String amount, Color? color) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 2),
        Text(
          '¥$amount',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ],
    );
  }

  List<Widget> _buildGroupedRecords(
    BuildContext context,
    List<LedgerRecord> records,
    List<RecordCategory> categories,
    List<Asset> assets,
  ) {
    final widgets = <Widget>[];
    String? currentDay;

    for (final r in records) {
      final time = DateTime.fromMillisecondsSinceEpoch(r.recordTime);
      final dayKey = formatDate(time);
      if (dayKey != currentDay) {
        currentDay = dayKey;
        widgets.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              dayKey,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        );
      }
      final label = recordLabel(r, categories, assets);
      widgets.add(
        ListTile(
          key: Key('search-record-${r.recordId}'),
          leading: CircleAvatar(child: Text(label.title.characters.first)),
          title: Text(label.title),
          subtitle: label.subtitle.isEmpty ? null : Text(label.subtitle),
          trailing: Text(
            label.amount,
            style: TextStyle(
              color: r.type == RecordType.income ? Colors.green.shade700 : null,
              fontWeight: FontWeight.w600,
            ),
          ),
          onTap: () => context.push('/record/${r.recordId}'),
        ),
      );
    }
    return widgets;
  }
}
