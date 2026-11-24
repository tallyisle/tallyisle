import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/credit_cycle.dart';
import '../../domain/rules/reconciliation.dart';
import '../common/catalog_icons.dart';
import '../common/common.dart';
import '../records/record_labels.dart';
import 'asset_detail_page.dart';
import 'asset_flow_providers.dart';

/// The account's bills across all books with optional reconciliation running
/// balances and optional credit-statement period filtering
/// (docs/modules/reconciliation.md). Returns a sliver.
class AssetFlowSection extends ConsumerWidget {
  const AssetFlowSection({
    super.key,
    required this.asset,
    required this.reconMode,
    this.periodFilter,
    this.onClearPeriodFilter,
    this.onOpenRecord,
  });

  final Asset asset;
  final bool reconMode;
  final CreditStatementPeriod? periodFilter;
  final VoidCallback? onClearPeriodFilter;
  final ValueChanged<String>? onOpenRecord;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final recordsAsync = ref.watch(assetRecordsProvider(asset.id));
    final categories = ref.watch(crossBookCategoriesProvider).value ?? const [];
    final assets = ref.watch(assetsProvider).value ?? const [];
    final balances = ref.watch(reconciliationBalancesProvider(asset.id));
    final allGroups = ref.watch(assetMonthGroupsProvider(asset.id));

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
        final activePeriod = periodFilter;
        final displayedRecords = activePeriod == null
            ? records
            : records
                  .where((r) => activePeriod.contains(r.recordTime))
                  .toList();

        final groups = activePeriod == null
            ? allGroups
            : groupRecordsByMonth<LedgerRecord>(
                records: displayedRecords,
                getRecordTime: (r) => r.recordTime,
                getDelta: (r) => recordForwardDelta(
                  record: reconRecordOf(r),
                  accountId: asset.id,
                  accountCurrency: asset.currency,
                ),
              );

        final slivers = <Widget>[
          if (activePeriod != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Material(
                  key: const Key('credit-period-filter-bar'),
                  color: scheme.secondaryContainer.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(10),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
                    child: Row(
                      children: [
                        Icon(
                          Icons.filter_alt_outlined,
                          size: 16,
                          color: scheme.onSecondaryContainer,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '第 ${activePeriod.periodIndex} 期账单'
                            '（${formatDate(activePeriod.start)} 至 ${formatDate(activePeriod.end)}）'
                            ' · ${displayedRecords.length} 笔',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: scheme.onSecondaryContainer,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (onClearPeriodFilter != null)
                          TextButton.icon(
                            key: const Key('clear-credit-period-filter'),
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            onPressed: onClearPeriodFilter,
                            icon: const Icon(Icons.close_rounded, size: 15),
                            label: const Text('全部流水'),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ];

        if (displayedRecords.isEmpty) {
          slivers.add(
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      activePeriod != null ? '该账期内暂无流水记录' : '暂无账单明细',
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                    if (activePeriod != null &&
                        onClearPeriodFilter != null) ...[
                      const SizedBox(height: 8),
                      OutlinedButton(
                        onPressed: onClearPeriodFilter,
                        child: const Text('恢复查看全部流水'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
          return SliverMainAxisGroup(slivers: slivers);
        }

        final catById = <int, RecordCategory>{
          for (final c in categories) c.id: c,
        };

        for (final group in groups) {
          slivers.add(
            SliverToBoxAdapter(
              child: Container(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
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
                    const SizedBox(width: 8),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            '流入 ${formatMinor(group.inflow)}  流出 ${formatMinor(group.outflow)}',
                            maxLines: 1,
                            softWrap: false,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
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
                final label = recordLabel(
                  r,
                  categories,
                  assets,
                  omitRedundantAssetId: asset.id,
                );
                final balance = balances[r.recordId];
                final reconText = reconMode && balance != null
                    ? (asset.type == AssetType.credit
                          ? creditBalanceLabel(balance)
                          : '余额：${formatMinor(balance)}')
                    : null;

                final cat = r.recordCatId == noRef
                    ? null
                    : catById[r.recordCatId];
                final parentCat =
                    (cat != null &&
                        cat.parentCatId != noRef &&
                        cat.parentCatId != -1)
                    ? catById[cat.parentCatId]
                    : null;
                final catDisplayName = cat == null
                    ? null
                    : (parentCat != null
                          ? '${parentCat.name} · ${cat.name}'
                          : cat.name);
                final catColor =
                    (cat?.colorFill != null &&
                        cat!.colorFill!.trim().isNotEmpty)
                    ? cat.colorFill
                    : parentCat?.colorFill;
                final isRefund =
                    (r.type == RecordType.expense ||
                        r.type == RecordType.income) &&
                    r.moneyMinor < BigInt.zero;
                final isPositiveAmount = label.amount.startsWith('+');

                return ListTile(
                  key: Key('flow-record-${r.recordId}'),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 2,
                  ),
                  onTap: () {
                    if (onOpenRecord != null) {
                      onOpenRecord!(r.recordId);
                    } else {
                      context.push('/record/${r.recordId}');
                    }
                  },
                  leading: RecordTypeIconAvatar(
                    recordType: r.type,
                    subType: r.subType,
                    isRefund: isRefund,
                    categoryName: catDisplayName,
                    categoryIcon: cat?.icon,
                    parentCategoryIcon: parentCat?.icon,
                    categoryColor: catColor,
                    size: 36,
                  ),
                  title: Text(
                    label.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
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
                          color: isPositiveAmount
                              ? (isDark
                                    ? Colors.green.shade300
                                    : Colors.green.shade700)
                              : null,
                        ),
                      ),
                      if (reconText != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          reconText,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.outline,
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
