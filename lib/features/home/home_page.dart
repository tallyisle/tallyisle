import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/income_expense.dart';
import '../common/common.dart';
import '../records/record_labels.dart';

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final book = ref.watch(currentBookProvider);
    return Scaffold(
      appBar: AppBar(
        title: InkWell(
          onTap: () => _pickBook(context, ref),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(book.value?.name ?? '帐屿'),
              const Icon(Icons.arrow_drop_down),
            ],
          ),
        ),
        actions: [
          IconButton(
            key: const Key('home-calendar-button'),
            tooltip: '日历',
            icon: const Icon(Icons.calendar_month),
            onPressed: () => context.push('/calendar'),
          ),
          IconButton(
            key: const Key('home-search-button'),
            tooltip: '搜索',
            icon: const Icon(Icons.search),
            onPressed: () => context.push('/search'),
          ),
        ],
      ),
      body: const _HomeBody(),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('add-record'),
        heroTag: 'fab-home',
        onPressed: () => context.push('/record/new'),
        icon: const Icon(Icons.edit),
        label: const Text('记一笔'),
      ),
    );
  }

  Future<void> _pickBook(BuildContext context, WidgetRef ref) async {
    final books = await ref.read(booksProvider.future);
    if (!context.mounted) return;
    final current = ref.read(currentBookIdProvider).value;
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final b in books)
              ListTile(
                title: Text(b.name),
                trailing: b.id == current ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(context, b.id),
              ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('管理账本…'),
              onTap: () {
                Navigator.pop(context);
                context.push('/books');
              },
            ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await (await ref.read(queriesProvider.future)).setCurrentBook(picked);
    ref.read(periodOffsetProvider.notifier).reset();
  }
}

class _HomeBody extends ConsumerWidget {
  const _HomeBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final period = ref.watch(currentPeriodProvider);
    final summary = ref.watch(periodSummaryProvider);
    final records = ref.watch(periodRecordsProvider);
    final bookId = ref.watch(currentBookIdProvider).value;
    final categories = bookId == null
        ? const <RecordCategory>[]
        : ref.watch(categoriesProvider(bookId)).value ?? const [];
    final assets = ref.watch(assetsProvider).value ?? const <Asset>[];
    final offset = ref.read(periodOffsetProvider.notifier);

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                IconButton(
                  tooltip: '上一期',
                  onPressed: offset.previous,
                  icon: const Icon(Icons.chevron_left),
                ),
                Expanded(
                  child: Center(
                    child: Text(
                      period.value == null
                          ? ''
                          : '${period.value!.year}年${period.value!.month}月',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '下一期',
                  onPressed: offset.next,
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: _SummaryCard(summary.value ?? IncomeExpense.zero),
        ),
        ...switch (records) {
          AsyncData(:final value) when value.isEmpty => [
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: Text('本期暂无账单')),
            ),
          ],
          AsyncData(:final value) => [
            SliverList.list(
              children: _grouped(context, value, categories, assets),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 96)),
          ],
          AsyncError(:final error) => [
            SliverFillRemaining(child: ErrorView(error)),
          ],
          _ => [const SliverFillRemaining(child: Loading())],
        },
      ],
    );
  }

  List<Widget> _grouped(
    BuildContext context,
    List<LedgerRecord> records,
    List<RecordCategory> categories,
    List<Asset> assets,
  ) {
    final widgets = <Widget>[];
    String? day;
    for (final r in records) {
      final time = DateTime.fromMillisecondsSinceEpoch(r.recordTime);
      final key = formatDate(time);
      if (key != day) {
        day = key;
        widgets.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(key, style: Theme.of(context).textTheme.labelLarge),
          ),
        );
      }
      final label = recordLabel(r, categories, assets);
      widgets.add(
        ListTile(
          key: Key('record-${r.recordId}'),
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

class _SummaryCard extends StatelessWidget {
  const _SummaryCard(this.s);
  final IncomeExpense s;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget cell(String label, BigInt v, Key key) => Expanded(
      child: Column(
        children: [
          Text(label, style: theme.textTheme.labelMedium),
          const SizedBox(height: 4),
          Text(formatMinor(v), key: key, style: theme.textTheme.titleMedium),
        ],
      ),
    );
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Row(
          children: [
            cell('结余', s.balance, const Key('sum-balance')),
            cell('支出', s.expense, const Key('sum-expense')),
            cell('收入', s.income, const Key('sum-income')),
          ],
        ),
      ),
    );
  }
}
