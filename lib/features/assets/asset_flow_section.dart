import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../domain/ledger/asset_json.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/credit_cycle.dart';
import '../../domain/rules/reconciliation.dart';
import '../common/catalog_icons.dart';
import '../common/common.dart';
import '../common/year_month_picker_dialog.dart';
import '../records/record_labels.dart';
import 'asset_detail_page.dart';
import 'asset_flow_providers.dart';

/// The account's bills across all books with optional reconciliation running
/// balances and optional credit-statement period or natural-month filtering
/// (docs/modules/reconciliation.md). Returns a sliver.
class AssetFlowSection extends ConsumerWidget {
  const AssetFlowSection({
    super.key,
    required this.asset,
    required this.reconMode,
    this.periodFilter,
    this.monthFilter,
    this.onChangePeriodFilter,
    this.onChangeMonthFilter,
    this.onClearPeriodFilter,
    this.onOpenRecord,
  });

  final Asset asset;
  final bool reconMode;
  final CreditStatementPeriod? periodFilter;
  final NaturalMonthPeriod? monthFilter;
  final ValueChanged<CreditStatementPeriod>? onChangePeriodFilter;
  final ValueChanged<NaturalMonthPeriod>? onChangeMonthFilter;
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
        final activeMonth = activePeriod == null ? monthFilter : null;
        final hasActiveFilter = activePeriod != null || activeMonth != null;

        final displayedRecords = activePeriod != null
            ? records.where((r) => activePeriod.contains(r.recordTime)).toList()
            : activeMonth != null
            ? records.where((r) => activeMonth.contains(r.recordTime)).toList()
            : records;

        final groups = !hasActiveFilter
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
          if (hasActiveFilter)
            SliverToBoxAdapter(
              child: _ActivePeriodFilterBar(
                asset: asset,
                periodFilter: activePeriod,
                monthFilter: activeMonth,
                recordCount: displayedRecords.length,
                onChangePeriodFilter: onChangePeriodFilter,
                onChangeMonthFilter: onChangeMonthFilter,
                onClear: onClearPeriodFilter,
              ),
            ),
        ];

        if (displayedRecords.isEmpty) {
          slivers.add(
            SliverToBoxAdapter(
              child: TallyEmptyState(
                icon: Icons.receipt_long_outlined,
                title: activePeriod != null
                    ? '该账期内暂无流水记录'
                    : activeMonth != null
                    ? '该月暂无流水记录'
                    : '暂无账单明细',
                action: hasActiveFilter && onClearPeriodFilter != null
                    ? TallySoftButton(
                        compact: true,
                        onPressed: onClearPeriodFilter,
                        child: const Text('恢复查看全部流水'),
                      )
                    : null,
              ),
            ),
          );
          return SliverMainAxisGroup(slivers: slivers);
        }

        final catById = <int, RecordCategory>{
          for (final c in categories) c.id: c,
        };
        final cardColor = isDark
            ? scheme.surfaceContainerLow
            : Color.lerp(
                scheme.surfaceContainerLow,
                scheme.surfaceContainer,
                0.55,
              )!;

        slivers.add(
          SliverList(
            delegate: SliverChildBuilderDelegate((context, groupIndex) {
              final group = groups[groupIndex];
              return Card(
                margin: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                elevation: 0,
                surfaceTintColor: Colors.transparent,
                color: cardColor,
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 16, 4),
                      child: Row(
                        children: [
                          Material(
                            color: Colors.transparent,
                            child: InkWell(
                              key: Key(
                                'flow-month-header-${group.year}-${group.month}',
                              ),
                              borderRadius: BorderRadius.circular(6),
                              onTap: onChangeMonthFilter == null
                                  ? null
                                  : () async {
                                      final now = DateTime.now();
                                      final picked =
                                          await showYearMonthPickerDialog(
                                            context,
                                            initialYear: group.year,
                                            initialMonth: group.month,
                                            currentYear: now.year,
                                            currentMonth: now.month,
                                          );
                                      if (picked != null) {
                                        onChangeMonthFilter!(
                                          NaturalMonthPeriod(
                                            year: picked.year,
                                            month: picked.month,
                                          ),
                                        );
                                      }
                                    },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 2,
                                ),
                                child: Text(
                                  '${group.year}年${group.month}月',
                                  style: theme.textTheme.labelMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
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
                    for (final r in group.items)
                      Builder(
                        builder: (context) {
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
                                  DateTime.fromMillisecondsSinceEpoch(
                                    r.recordTime,
                                  ),
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
                        },
                      ),
                    const SizedBox(height: 4),
                  ],
                ),
              );
            }, childCount: groups.length),
          ),
        );

        return SliverMainAxisGroup(slivers: slivers);
      },
    );
  }
}

class _ActivePeriodFilterBar extends StatelessWidget {
  const _ActivePeriodFilterBar({
    required this.asset,
    required this.periodFilter,
    required this.monthFilter,
    required this.recordCount,
    required this.onChangePeriodFilter,
    required this.onChangeMonthFilter,
    required this.onClear,
  });

  final Asset asset;
  final CreditStatementPeriod? periodFilter;
  final NaturalMonthPeriod? monthFilter;
  final int recordCount;
  final ValueChanged<CreditStatementPeriod>? onChangePeriodFilter;
  final ValueChanged<NaturalMonthPeriod>? onChangeMonthFilter;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isCreditPeriod = periodFilter != null;

    final String title;
    final String rangeText;
    if (periodFilter != null) {
      final p = periodFilter!;
      title = '${p.year}年 第${p.periodIndex}期 · $recordCount 笔';
      rangeText = '${formatDate(p.start)} 至 ${formatDate(p.end)}';
    } else {
      final m = monthFilter!;
      title = '${m.year}年${m.month}月 · $recordCount 笔';
      rangeText = '${formatDate(m.start)} 至 ${formatDate(m.end)}';
    }

    final creditInfo = isCreditPeriod
        ? CreditInfo.parse(asset.creditInfo)
        : null;

    void stepPeriod(int delta) {
      if (periodFilter != null &&
          creditInfo != null &&
          onChangePeriodFilter != null) {
        onChangePeriodFilter!(
          adjacentCreditPeriod(
            current: periodFilter!,
            creditInfo: creditInfo,
            delta: delta,
          ),
        );
      } else if (monthFilter != null && onChangeMonthFilter != null) {
        onChangeMonthFilter!(
          delta < 0 ? monthFilter!.previous() : monthFilter!.next(),
        );
      }
    }

    Future<void> pickPeriod() async {
      if (periodFilter != null &&
          creditInfo != null &&
          onChangePeriodFilter != null) {
        final picked = await showCreditPeriodPickerDialog(
          context,
          creditInfo: creditInfo,
          initialYear: periodFilter!.year,
          initialPeriodIndex: periodFilter!.periodIndex,
        );
        if (picked != null) {
          onChangePeriodFilter!(picked);
        }
      } else if (monthFilter != null && onChangeMonthFilter != null) {
        final now = DateTime.now();
        final picked = await showYearMonthPickerDialog(
          context,
          initialYear: monthFilter!.year,
          initialMonth: monthFilter!.month,
          currentYear: now.year,
          currentMonth: now.month,
        );
        if (picked != null) {
          onChangeMonthFilter!(
            NaturalMonthPeriod(year: picked.year, month: picked.month),
          );
        }
      }
    }

    final canStep = isCreditPeriod
        ? (creditInfo != null && onChangePeriodFilter != null)
        : (monthFilter != null && onChangeMonthFilter != null);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Material(
        key: Key(
          isCreditPeriod ? 'credit-period-filter-bar' : 'fund-month-filter-bar',
        ),
        color: scheme.secondaryContainer.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 6, 4),
          child: Row(
            children: [
              Tooltip(
                message: isCreditPeriod ? '上一账期' : '上个月',
                child: InkWell(
                  key: const Key('flow-filter-prev'),
                  borderRadius: BorderRadius.circular(8),
                  onTap: canStep ? () => stepPeriod(-1) : null,
                  child: SizedBox(
                    width: 28,
                    height: 34,
                    child: Icon(
                      Icons.chevron_left_rounded,
                      size: 18,
                      color: scheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: InkWell(
                  key: const Key('flow-filter-pick'),
                  borderRadius: BorderRadius.circular(8),
                  onTap: canStep ? pickPeriod : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 2,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: scheme.onSecondaryContainer,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          rangeText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSecondaryContainer.withValues(
                              alpha: 0.8,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Tooltip(
                message: isCreditPeriod ? '下一账期' : '下个月',
                child: InkWell(
                  key: const Key('flow-filter-next'),
                  borderRadius: BorderRadius.circular(8),
                  onTap: canStep ? () => stepPeriod(1) : null,
                  child: SizedBox(
                    width: 28,
                    height: 34,
                    child: Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: scheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ),
              if (onClear != null)
                TextButton.icon(
                  key: Key(
                    isCreditPeriod
                        ? 'clear-credit-period-filter'
                        : 'flow-filter-clear',
                  ),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: onClear,
                  icon: const Icon(Icons.close_rounded, size: 15),
                  label: const Text('全部流水', maxLines: 1, softWrap: false),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
