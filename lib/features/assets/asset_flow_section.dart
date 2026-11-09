import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../domain/model/codes.dart';
import '../common/common.dart';
import '../records/record_labels.dart';
import 'asset_detail_page.dart';
import 'asset_flow_providers.dart';

/// The account's bills across all books with an optional reconciliation mode
/// (docs/modules/reconciliation.md). Returns a sliver.
class AssetFlowSection extends ConsumerStatefulWidget {
  const AssetFlowSection({super.key, required this.asset});
  final Asset asset;

  @override
  ConsumerState<AssetFlowSection> createState() => _AssetFlowSectionState();
}

class _AssetFlowSectionState extends ConsumerState<AssetFlowSection> {
  bool _reconMode = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final asset = widget.asset;

    final recordsAsync = ref.watch(assetRecordsProvider(asset.id));
    final categories = ref.watch(crossBookCategoriesProvider).value ?? const [];
    final assets = ref.watch(assetsProvider).value ?? const [];
    final balances = ref.watch(reconciliationBalancesProvider(asset.id));
    final groups = ref.watch(assetMonthGroupsProvider(asset.id));

    return recordsAsync.when(
      loading: () => const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
      error: (e, _) => SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(child: Text(safeMessage(e))),
        ),
      ),
      data: (records) {
        final totalCount = records.length;

        Widget buildHeader() => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Text('明细 · $totalCount 笔', style: theme.textTheme.titleMedium),
              const Spacer(),
              Text('对账模式', style: theme.textTheme.bodyMedium),
              const SizedBox(width: 8),
              Switch(
                key: const Key('reconciliation-switch'),
                value: _reconMode,
                onChanged: (v) => setState(() => _reconMode = v),
              ),
            ],
          ),
        );

        if (records.isEmpty) {
          return SliverMainAxisGroup(
            slivers: [
              SliverToBoxAdapter(child: buildHeader()),
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(
                    child: Text('暂无账单明细', style: TextStyle(color: Colors.grey)),
                  ),
                ),
              ),
            ],
          );
        }

        final slivers = <Widget>[SliverToBoxAdapter(child: buildHeader())];

        for (final group in groups) {
          slivers.add(
            SliverToBoxAdapter(
              child: Container(
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.4,
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    Text(
                      '${group.year}年${group.month}月',
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '流入 ${formatMinor(group.inflow)}  流出 ${formatMinor(group.outflow)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );

          slivers.add(
            SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                final r = group.items[index];
                final label = recordLabel(r, categories, assets);
                final balance = balances[r.recordId];
                final reconText = _reconMode && balance != null
                    ? (asset.type == AssetType.credit
                          ? creditBalanceLabel(balance)
                          : '余额：${formatMinor(balance)}')
                    : null;

                return ListTile(
                  key: Key('flow-record-${r.recordId}'),
                  onTap: () => context.push('/record/${r.recordId}'),
                  title: Text(label.title),
                  subtitle: Text(
                    [
                      formatDateTime(
                        DateTime.fromMillisecondsSinceEpoch(r.recordTime),
                      ),
                      if (label.subtitle.isNotEmpty) label.subtitle,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        label.amount,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (reconText != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          reconText,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              }, childCount: group.items.length),
            ),
          );
        }

        return SliverMainAxisGroup(slivers: slivers);
      },
    );
  }
}
