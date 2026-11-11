import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../app/providers.dart';
import '../../core/money.dart';
import '../../data/db/database.dart';
import '../../domain/rules/budget_rules.dart';
import '../common/common.dart';
import 'budget_providers.dart';
import 'budget_widgets.dart';

const _uuid = Uuid();

/// Budget management page (F-006, docs/modules/budget.md).
class BudgetPage extends ConsumerStatefulWidget {
  const BudgetPage({super.key});

  @override
  ConsumerState<BudgetPage> createState() => _BudgetPageState();
}

class _BudgetPageState extends ConsumerState<BudgetPage> {
  final _commandIds = CommandIds();

  void _showTotalBudgetDialog(
    BuildContext context, {
    Budget? existing,
    BudgetUsage? usage,
  }) {
    final extra = existing != null
        ? BudgetExtra.fromJson(
            existing.extraInfo,
            fallbackAmountMinor: existing.amountMinor,
          )
        : null;

    final controller = TextEditingController(
      text: existing != null ? formatMinor(existing.amountMinor) : '',
    );
    var autoCopy = extra?.autoCopy ?? false;
    var forward = extra?.forward ?? false;

    showDialog<void>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(existing == null ? '设置总预算' : '修改总预算'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  key: const Key('total_budget_amount_input'),
                  controller: controller,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: '预算金额 (元)',
                    prefixText: '¥ ',
                  ),
                  autofocus: true,
                ),
                const SizedBox(height: 16),
                SwitchListTile(
                  key: const Key('total_budget_acopy_switch'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('自动复制到下期'),
                  subtitle: const Text('新周期无预算时自动沿用'),
                  value: autoCopy,
                  onChanged: (val) => setDialogState(() => autoCopy = val),
                ),
                SwitchListTile(
                  key: const Key('total_budget_forward_switch'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('结余结转'),
                  subtitle: const Text('上期结余或超支自动结转至下期'),
                  value: forward,
                  onChanged: (val) => setDialogState(() => forward = val),
                ),
              ],
            ),
          ),
          actions: [
            if (existing != null)
              TextButton(
                key: const Key('delete_total_budget_button'),
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                onPressed: () async {
                  Navigator.pop(dialogCtx);
                  final confirmed = await confirm(
                    context,
                    title: '删除总预算',
                    message: '确定要删除当期总预算吗？',
                  );
                  if (confirmed && mounted) {
                    final service = await ref.read(
                      budgetServiceProvider.future,
                    );
                    await service.deleteBudget(
                      commandId: _commandIds.forPayload([
                        'del',
                        existing.id,
                        _uuid.v4(),
                      ]),
                      budgetId: existing.id,
                    );
                  }
                },
                child: const Text('删除'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('save_total_budget_button'),
              onPressed: () async {
                final text = controller.text.trim();
                if (text.isEmpty) return;
                try {
                  final amountMinor = Money.parse(text).storageMinor;
                  final service = await ref.read(budgetServiceProvider.future);
                  final bookId = await ref.read(currentBookIdProvider.future);
                  final section = await ref.read(budgetSectionProvider.future);

                  await service.upsertTotalBudget(
                    commandId: _commandIds.forPayload([
                      'total',
                      bookId,
                      section,
                      amountMinor.toString(),
                      autoCopy,
                      forward,
                      _uuid.v4(),
                    ]),
                    bookId: bookId,
                    section: section,
                    amountMinor: amountMinor,
                    autoCopy: autoCopy,
                    forward: forward,
                  );

                  if (dialogCtx.mounted) Navigator.pop(dialogCtx);
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('保存失败: ${safeMessage(e)}')),
                    );
                  }
                }
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  void _showCategoryBudgetDialog(
    BuildContext context, {
    required int budgetType,
    CategoryBudgetDetail? existing,
    required List<RecordCategory> availableCategories,
  }) {
    final extra = existing != null
        ? BudgetExtra.fromJson(
            existing.budget.extraInfo,
            fallbackAmountMinor: existing.budget.amountMinor,
          )
        : null;

    final controller = TextEditingController(
      text: existing != null ? formatMinor(existing.budget.amountMinor) : '',
    );
    var selectedCatId =
        existing?.category.id ??
        (availableCategories.isNotEmpty ? availableCategories.first.id : 0);
    var autoCopy = extra?.autoCopy ?? false;
    var forward = extra?.forward ?? false;

    final isExpense = budgetType == BudgetTypeCode.expenseCategory;
    final title = existing == null
        ? (isExpense ? '添加支出分类预算' : '添加储蓄预算')
        : (isExpense ? '修改支出分类预算' : '修改储蓄预算');

    showDialog<void>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (existing == null) ...[
                  const Text('选择分类', style: TextStyle(fontSize: 13)),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<int>(
                    key: const Key('category_budget_picker'),
                    initialValue: selectedCatId,
                    items: availableCategories
                        .map(
                          (c) => DropdownMenuItem<int>(
                            value: c.id,
                            child: Text(
                              c.parentCatId != -1 ? '  └ ${c.name}' : c.name,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (val) {
                      if (val != null) {
                        setDialogState(() => selectedCatId = val);
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                ],
                TextField(
                  key: const Key('category_budget_amount_input'),
                  controller: controller,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: isExpense ? '预算金额 (元)' : '储蓄目标金额 (元)',
                    prefixText: '¥ ',
                  ),
                  autofocus: true,
                ),
                const SizedBox(height: 16),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('自动复制到下期'),
                  subtitle: const Text('新周期无预算时自动沿用'),
                  value: autoCopy,
                  onChanged: (val) => setDialogState(() => autoCopy = val),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('结余结转'),
                  subtitle: const Text('上期结余或超支自动结转至下期'),
                  value: forward,
                  onChanged: (val) => setDialogState(() => forward = val),
                ),
              ],
            ),
          ),
          actions: [
            if (existing != null)
              TextButton(
                key: const Key('delete_category_budget_button'),
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                onPressed: () async {
                  Navigator.pop(dialogCtx);
                  final confirmed = await confirm(
                    context,
                    title: '删除分类预算',
                    message: '确定要删除此分类预算吗？',
                  );
                  if (confirmed && mounted) {
                    final service = await ref.read(
                      budgetServiceProvider.future,
                    );
                    await service.deleteBudget(
                      commandId: _commandIds.forPayload([
                        'del_cat',
                        existing.budget.id,
                        _uuid.v4(),
                      ]),
                      budgetId: existing.budget.id,
                    );
                  }
                },
                child: const Text('删除'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('save_category_budget_button'),
              onPressed: () async {
                final text = controller.text.trim();
                if (text.isEmpty || selectedCatId <= 0) return;
                try {
                  final amountMinor = Money.parse(text).storageMinor;
                  final service = await ref.read(budgetServiceProvider.future);
                  final bookId = await ref.read(currentBookIdProvider.future);
                  final section = await ref.read(budgetSectionProvider.future);

                  await service.upsertCategoryBudget(
                    commandId: _commandIds.forPayload([
                      'cat_bg',
                      bookId,
                      section,
                      selectedCatId,
                      budgetType,
                      amountMinor.toString(),
                      autoCopy,
                      forward,
                      _uuid.v4(),
                    ]),
                    bookId: bookId,
                    section: section,
                    categoryId: selectedCatId,
                    budgetType: budgetType,
                    amountMinor: amountMinor,
                    autoCopy: autoCopy,
                    forward: forward,
                  );

                  if (dialogCtx.mounted) Navigator.pop(dialogCtx);
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('保存失败: ${safeMessage(e)}')),
                    );
                  }
                }
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  void _openDrilldown(
    BuildContext context, {
    required String title,
    required List<String> matchedRecordIds,
    required String periodLabel,
    required BigInt amountMinor,
    required BigInt usedMinor,
    required bool isSaving,
  }) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BudgetDrilldownPage(
          title: title,
          matchedRecordIds: matchedRecordIds,
          periodLabel: periodLabel,
          amountMinor: amountMinor,
          usedMinor: usedMinor,
          isSaving: isSaving,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final modeAsync = ref.watch(budgetModeProvider);
    final periodAsync = ref.watch(budgetPeriodProvider);
    final overviewAsync = ref.watch(budgetOverviewProvider);
    final bookIdAsync = ref.watch(currentBookIdProvider);

    return Scaffold(
      key: const Key('budget_page'),
      appBar: AppBar(
        title: const Text('预算管理'),
        actions: [
          modeAsync.when(
            data: (mode) => Padding(
              padding: const EdgeInsets.only(right: 8),
              child: SegmentedButton<BudgetMode>(
                key: const Key('budget_mode_toggle'),
                segments: const [
                  ButtonSegment(value: BudgetMode.monthly, label: Text('月预算')),
                  ButtonSegment(value: BudgetMode.yearly, label: Text('年预算')),
                ],
                selected: {mode},
                onSelectionChanged: (newSelection) async {
                  final newMode = newSelection.first;
                  final bookId = bookIdAsync.value;
                  if (bookId != null) {
                    final service = await ref.read(
                      budgetServiceProvider.future,
                    );
                    await service.setBudgetMode(
                      commandId: _commandIds.forPayload([
                        'set_mode',
                        bookId,
                        newMode.value,
                        _uuid.v4(),
                      ]),
                      bookId: bookId,
                      mode: newMode,
                    );
                    ref.read(budgetOffsetProvider.notifier).reset();
                  }
                },
              ),
            ),
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
          ),
        ],
      ),
      body: Column(
        children: [
          // Period navigation bar
          periodAsync.when(
            data: (period) {
              final mode = modeAsync.value ?? BudgetMode.monthly;
              final periodText = mode == BudgetMode.yearly
                  ? '${period.year} 年'
                  : '${period.year} 年 ${period.month} 月';

              return Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                color: Theme.of(context).cardColor,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    IconButton(
                      key: const Key('budget_period_prev'),
                      icon: const Icon(Icons.chevron_left),
                      onPressed: () =>
                          ref.read(budgetOffsetProvider.notifier).previous(),
                    ),
                    InkWell(
                      onTap: () =>
                          ref.read(budgetOffsetProvider.notifier).reset(),
                      child: Text(
                        periodText,
                        key: const Key('budget_period_title'),
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                    ),
                    IconButton(
                      key: const Key('budget_period_next'),
                      icon: const Icon(Icons.chevron_right),
                      onPressed: () =>
                          ref.read(budgetOffsetProvider.notifier).next(),
                    ),
                  ],
                ),
              );
            },
            loading: () => const LinearProgressIndicator(),
            error: (e, _) => Center(child: Text('账期错误: ${safeMessage(e)}')),
          ),

          // Main list
          Expanded(
            child: overviewAsync.when(
              loading: () => const Loading(),
              error: (e, _) => ErrorView(e),
              data: (overview) {
                final allCategoriesAsync = ref.watch(
                  categoriesProvider(bookIdAsync.value ?? 1),
                );
                final allCategories = allCategoriesAsync.value ?? [];

                final expenseCategories = allCategories
                    .where((c) => c.type == 0 && !c.isHide)
                    .toList();
                final savingCategories = allCategories
                    .where((c) => c.type == 1 && !c.isHide)
                    .toList();

                final periodLabel = overview.mode == BudgetMode.yearly
                    ? '${overview.period.year}年'
                    : '${overview.period.year}年${overview.period.month}月';

                return ListView(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  children: [
                    // 1. Total budget section
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '总预算',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          if (overview.totalBudget == null)
                            TextButton.icon(
                              key: const Key('set_total_budget_button'),
                              onPressed: () => _showTotalBudgetDialog(context),
                              icon: const Icon(Icons.add, size: 18),
                              label: const Text('设置总预算'),
                            )
                          else
                            IconButton(
                              key: const Key('edit_total_budget_button'),
                              icon: const Icon(Icons.edit_outlined, size: 20),
                              onPressed: () => _showTotalBudgetDialog(
                                context,
                                existing: overview.totalBudget,
                                usage: overview.totalUsage,
                              ),
                            ),
                        ],
                      ),
                    ),
                    BudgetSummaryCard(
                      onTap: () {
                        if (overview.totalBudget != null &&
                            overview.totalUsage != null) {
                          _openDrilldown(
                            context,
                            title: '总预算明细',
                            matchedRecordIds:
                                overview.totalUsage!.matchedRecordIds,
                            periodLabel: periodLabel,
                            amountMinor: overview.totalBudget!.amountMinor,
                            usedMinor: overview.totalUsage!.displayUsedMinor,
                            isSaving: false,
                          );
                        } else {
                          _showTotalBudgetDialog(context);
                        }
                      },
                    ),

                    const Divider(height: 32),

                    // 2. Expense category budgets
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '支出分类预算',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          TextButton.icon(
                            key: const Key('add_expense_budget_button'),
                            onPressed: () => _showCategoryBudgetDialog(
                              context,
                              budgetType: BudgetTypeCode.expenseCategory,
                              availableCategories: expenseCategories,
                            ),
                            icon: const Icon(Icons.add, size: 18),
                            label: const Text('添加'),
                          ),
                        ],
                      ),
                    ),
                    if (overview.expenseCategoryBudgets.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(
                          child: Text(
                            '暂无支出分类预算',
                            style: TextStyle(color: Colors.grey),
                          ),
                        ),
                      )
                    else
                      ...overview.expenseCategoryBudgets.map((detail) {
                        final usage = detail.usage;
                        final isOver = usage.isOverspent;
                        final percent = usage.percent;
                        final progress = (percent / 100.0).clamp(0.0, 1.0);

                        return Card(
                          key: Key(
                            'category_budget_card_${detail.category.id}',
                          ),
                          margin: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 4,
                          ),
                          child: ListTile(
                            onTap: () => _openDrilldown(
                              context,
                              title: '${detail.category.name}支出明细',
                              matchedRecordIds: usage.matchedRecordIds,
                              periodLabel: periodLabel,
                              amountMinor: detail.budget.amountMinor,
                              usedMinor: usage.displayUsedMinor,
                              isSaving: false,
                            ),
                            title: Row(
                              children: [
                                Text(
                                  detail.parentCategory != null
                                      ? '${detail.parentCategory!.name} / ${detail.category.name}'
                                      : detail.category.name,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  '¥${formatMinor(detail.budget.amountMinor)}',
                                ),
                              ],
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 6),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(3),
                                  child: LinearProgressIndicator(
                                    value: progress,
                                    minHeight: 6,
                                    backgroundColor: Colors.grey.withAlpha(50),
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      isOver
                                          ? Colors.red
                                          : Theme.of(context).primaryColor,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      '已用: ¥${formatMinor(usage.displayUsedMinor)} (${percent.toStringAsFixed(1)}%)',
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                    Text(
                                      isOver
                                          ? '超支: ¥${formatMinor(-usage.remainingMinor)}'
                                          : '剩余: ¥${formatMinor(usage.remainingMinor)}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                        color: isOver
                                            ? Colors.red
                                            : Colors.green[700],
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.more_vert, size: 20),
                              onPressed: () => _showCategoryBudgetDialog(
                                context,
                                budgetType: BudgetTypeCode.expenseCategory,
                                existing: detail,
                                availableCategories: expenseCategories,
                              ),
                            ),
                          ),
                        );
                      }),

                    const Divider(height: 32),

                    // 3. Saving category budgets
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '储蓄分类预算',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          TextButton.icon(
                            key: const Key('add_saving_budget_button'),
                            onPressed: () => _showCategoryBudgetDialog(
                              context,
                              budgetType: BudgetTypeCode.savingCategory,
                              availableCategories: savingCategories,
                            ),
                            icon: const Icon(Icons.add, size: 18),
                            label: const Text('添加'),
                          ),
                        ],
                      ),
                    ),
                    if (overview.savingCategoryBudgets.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(
                          child: Text(
                            '暂无储蓄分类预算',
                            style: TextStyle(color: Colors.grey),
                          ),
                        ),
                      )
                    else
                      ...overview.savingCategoryBudgets.map((detail) {
                        final usage = detail.usage;
                        final percent = usage.percent;
                        final progress = (percent / 100.0).clamp(0.0, 1.0);
                        final isReached = usage.remainingMinor <= BigInt.zero;

                        return Card(
                          key: Key('saving_budget_card_${detail.category.id}'),
                          margin: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 4,
                          ),
                          child: ListTile(
                            onTap: () => _openDrilldown(
                              context,
                              title: '${detail.category.name}储蓄明细',
                              matchedRecordIds: usage.matchedRecordIds,
                              periodLabel: periodLabel,
                              amountMinor: detail.budget.amountMinor,
                              usedMinor: usage.displayUsedMinor,
                              isSaving: true,
                            ),
                            title: Row(
                              children: [
                                Text(
                                  detail.parentCategory != null
                                      ? '${detail.parentCategory!.name} / ${detail.category.name}'
                                      : detail.category.name,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  '目标: ¥${formatMinor(detail.budget.amountMinor)}',
                                ),
                              ],
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 6),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(3),
                                  child: LinearProgressIndicator(
                                    value: progress,
                                    minHeight: 6,
                                    backgroundColor: Colors.grey.withAlpha(50),
                                    valueColor:
                                        const AlwaysStoppedAnimation<Color>(
                                          Colors.teal,
                                        ),
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      '已存: ¥${formatMinor(usage.displayUsedMinor)} (${percent.toStringAsFixed(1)}%)',
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                    Text(
                                      isReached
                                          ? '已达成目标'
                                          : '待存: ¥${formatMinor(usage.remainingMinor)}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                        color: isReached
                                            ? Colors.teal[700]
                                            : Colors.blueGrey,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.more_vert, size: 20),
                              onPressed: () => _showCategoryBudgetDialog(
                                context,
                                budgetType: BudgetTypeCode.savingCategory,
                                existing: detail,
                                availableCategories: savingCategories,
                              ),
                            ),
                          ),
                        );
                      }),
                    const SizedBox(height: 24),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Drilldown list of bills contributing to a budget (docs/modules/budget.md ASYM-BG-01).
class BudgetDrilldownPage extends ConsumerWidget {
  const BudgetDrilldownPage({
    super.key,
    required this.title,
    required this.matchedRecordIds,
    required this.periodLabel,
    required this.amountMinor,
    required this.usedMinor,
    this.isSaving = false,
    this.onRecordTap,
  });

  final String title;
  final List<String> matchedRecordIds;
  final String periodLabel;
  final BigInt amountMinor;
  final BigInt usedMinor;
  final bool isSaving;
  final void Function(String recordId)? onRecordTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final periodRecordsAsync = ref.watch(budgetPeriodRecordsProvider);
    final bookIdAsync = ref.watch(currentBookIdProvider);
    final categoriesAsync = ref.watch(
      categoriesProvider(bookIdAsync.value ?? 1),
    );

    return Scaffold(
      key: const Key('budget_drilldown_page'),
      appBar: AppBar(title: Text(title)),
      body: Column(
        children: [
          // Header summary card
          Container(
            padding: const EdgeInsets.all(16),
            color: Theme.of(context).cardColor,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      periodLabel,
                      style: const TextStyle(fontSize: 13, color: Colors.grey),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      isSaving
                          ? '已存 ¥${formatMinor(usedMinor)} / 目标 ¥${formatMinor(amountMinor)}'
                          : '已用 ¥${formatMinor(usedMinor)} / 预算 ¥${formatMinor(amountMinor)}',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                Text(
                  '共 ${matchedRecordIds.length} 笔',
                  style: const TextStyle(fontSize: 14, color: Colors.grey),
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // Bill records list
          Expanded(
            child: periodRecordsAsync.when(
              loading: () => const Loading(),
              error: (e, _) => ErrorView(e),
              data: (records) {
                final categoryMap = {
                  for (final c in categoriesAsync.value ?? <RecordCategory>[])
                    c.id: c,
                };

                final matchedSet = matchedRecordIds.toSet();
                final bills = records
                    .where((r) => matchedSet.contains(r.recordId))
                    .toList();

                if (bills.isEmpty) {
                  return const Center(
                    child: Text(
                      '暂无计入此预算的账单',
                      style: TextStyle(color: Colors.grey),
                    ),
                  );
                }

                return ListView.separated(
                  itemCount: bills.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final r = bills[index];
                    final cat = categoryMap[r.recordCatId];
                    final date = DateTime.fromMillisecondsSinceEpoch(
                      r.recordTime,
                    );

                    return ListTile(
                      key: Key('drilldown_bill_${r.recordId}'),
                      onTap: () {
                        if (onRecordTap != null) {
                          onRecordTap!(r.recordId);
                        } else {
                          try {
                            context.push('/record/${r.recordId}');
                          } catch (_) {}
                        }
                      },
                      title: Row(
                        children: [
                          Text(
                            cat?.name ?? '无分类',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          if (r.remark.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                r.remark,
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: Colors.grey,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                          const Spacer(),
                          Text(
                            r.moneyMinor.isNegative
                                ? '-¥${formatMinor(-r.moneyMinor)}'
                                : '¥${formatMinor(r.moneyMinor)}',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: isSaving ? Colors.teal[700] : null,
                            ),
                          ),
                        ],
                      ),
                      subtitle: Text(
                        formatDateTime(date),
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
