import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/db/database.dart';
import '../../domain/ledger/asset_json.dart';
import '../../domain/rules/credit_cycle.dart';
import '../common/common.dart';
import 'asset_detail_page.dart';
import 'credit_providers.dart';

String _formatShortDate(DateTime d) => '${two(d.month)}-${two(d.day)}';

/// Credit card section on the account detail page (F-028 / docs/modules/credit-account.md).
/// Displays:
/// - Available credit, total limit, current debt/overpayment, and uncredited installments.
/// - Pending repayment banner for the earliest issued unpaid statement (R5).
/// - Year switcher and statement cards with issued/unissued tags, period, dates, amounts.
class CreditSection extends ConsumerWidget {
  const CreditSection({super.key, required this.asset});
  final Asset asset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = CreditInfo.parse(asset.creditInfo);
    if (!info.configured) {
      return Card(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Icon(Icons.info_outline),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  '尚未配置账单日与还款日，请编辑卡片补充信息。',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              OutlinedButton(
                onPressed: () => context.push('/assets/${asset.id}/edit'),
                child: const Text('去配置'),
              ),
            ],
          ),
        ),
      );
    }

    final sharedLimitAsync = ref.watch(creditSharedLimitProvider(asset));
    final bannerAsync = ref.watch(creditPendingBannerProvider(asset));
    final statementsAsync = ref.watch(creditStatementsProvider(asset));
    final selectedYear = ref.watch(creditSelectedYearProvider);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. Available credit / Total limit / Balance Card (R6)
          sharedLimitAsync.when(
            data: (shared) => _LimitSummaryCard(asset: asset, shared: shared),
            loading: () => const Card(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
            error: (e, _) => Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text('额度计算出错: ${safeMessage(e)}'),
              ),
            ),
          ),
          const SizedBox(height: 8),

          // 2. Pending repayment banner (R5)
          bannerAsync.when(
            data: (banner) {
              if (banner == null) return const SizedBox.shrink();
              return _PendingBanner(asset: asset, banner: banner);
            },
            loading: () => const SizedBox.shrink(),
            error: (_, _) => const SizedBox.shrink(),
          ),

          // 3. Year Switcher
          _YearSwitcher(selectedYear: selectedYear),
          const SizedBox(height: 4),

          // 4. Statement list (R4)
          statementsAsync.when(
            data: (statements) {
              if (statements.isEmpty) {
                return const Card(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: Text('本年度暂无账单数据')),
                  ),
                );
              }
              return Column(
                children: [
                  for (final item in statements)
                    _StatementCard(asset: asset, item: item),
                ],
              );
            },
            loading: () => const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(),
              ),
            ),
            error: (e, _) => Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text('账单加载出错: ${safeMessage(e)}'),
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

class _LimitSummaryCard extends StatelessWidget {
  const _LimitSummaryCard({required this.asset, required this.shared});
  final Asset asset;
  final SharedLimitResult shared;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final info = CreditInfo.parse(asset.creditInfo);
    final extra = AssetExtra.parse(asset.extraInfo);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final hasActiveTemp = extra.activeTempAmount(nowMs) > BigInt.zero;
    final totalInstallments = calculateTotalUncreditedInstallments(
      info.installments,
    );
    final ifcDays = calculateInterestFreeDays(
      creditInfo: info,
      today: DateTime.now(),
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  shared.isShared ? '共享剩余额度' : '可用额度',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                if (ifcDays > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '今日享 $ifcDays 天免息期',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              formatMinor(shared.usableLimit),
              key: const Key('credit-usable-limit'),
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Divider(height: 16),
            Wrap(
              spacing: 16,
              runSpacing: 4,
              children: [
                Text(
                  '${hasActiveTemp ? '总额度(含临额)' : '总额度'}: ${formatMinor(shared.effectiveTotalLimit)}',
                  style: theme.textTheme.bodySmall,
                ),
                Text(
                  '账面${creditBalanceLabel(shared.groupDisplayBalance)}',
                  style: theme.textTheme.bodySmall,
                ),
                if (totalInstallments > BigInt.zero)
                  Text(
                    '分期未入账: ${formatMinor(totalInstallments)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PendingBanner extends StatelessWidget {
  const _PendingBanner({required this.asset, required this.banner});
  final Asset asset;
  final CreditPendingBannerInfo banner;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isOverdue = banner.isOverdue;
    final bgColor = isOverdue
        ? theme.colorScheme.errorContainer
        : theme.colorScheme.secondaryContainer;
    final fgColor = isOverdue
        ? theme.colorScheme.onErrorContainer
        : theme.colorScheme.onSecondaryContainer;

    return Card(
      key: const Key('credit-pending-banner'),
      color: bgColor,
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(
              isOverdue ? Icons.warning_rounded : Icons.notifications_active,
              color: fgColor,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '第 ${banner.period.periodIndex} 期账单待还 ${formatMinor(banner.remainingAmount)}',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: fgColor,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (isOverdue)
                    Text(
                      '已逾期 ${banner.overdueDays} 天',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: fgColor,
                      ),
                    ),
                ],
              ),
            ),
            FilledButton.tonal(
              key: const Key('credit-banner-repay'),
              onPressed: () =>
                  context.push(repayRoute(asset, banner.remainingAmount)),
              child: const Text('立即还款'),
            ),
          ],
        ),
      ),
    );
  }
}

class _YearSwitcher extends ConsumerWidget {
  const _YearSwitcher({required this.selectedYear});
  final int selectedYear;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          key: const Key('credit-year-prev'),
          icon: const Icon(Icons.chevron_left),
          tooltip: '上一年度',
          onPressed: () =>
              ref.read(creditSelectedYearProvider.notifier).previous(),
        ),
        Text(
          '$selectedYear 年',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        IconButton(
          key: const Key('credit-year-next'),
          icon: const Icon(Icons.chevron_right),
          tooltip: '下一年度',
          onPressed: () => ref.read(creditSelectedYearProvider.notifier).next(),
        ),
      ],
    );
  }
}

class _StatementCard extends StatelessWidget {
  const _StatementCard({required this.asset, required this.item});
  final Asset asset;
  final CreditStatementItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = item.period;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '第 ${p.periodIndex} 期账单',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: item.isIssued
                        ? theme.colorScheme.primaryContainer
                        : theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    item.isIssued ? '已出账' : '未出账',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: item.isIssued
                          ? theme.colorScheme.onPrimaryContainer
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const Spacer(),
                if (item.isPaidOff)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.tertiaryContainer,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '已还清',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onTertiaryContainer,
                      ),
                    ),
                  )
                else if (item.isIssued && item.remainingAmount > BigInt.zero)
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    onPressed: () =>
                        context.push(repayRoute(asset, item.remainingAmount)),
                    child: const Text('还款'),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${formatDate(p.start)} 至 ${formatDate(p.end)}'
              ' · 出账日 ${_formatShortDate(p.statementDate)}'
              ' · 还款日 ${_formatShortDate(p.dueDate)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('账单金额', style: theme.textTheme.labelSmall),
                      Text(
                        formatMinor(item.statementAmount),
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (item.installmentAmount > BigInt.zero)
                        Text(
                          '含分期 ${formatMinor(item.installmentAmount)}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.secondary,
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('已还金额', style: theme.textTheme.labelSmall),
                      Text(
                        formatMinor(item.repaidAmount),
                        style: theme.textTheme.bodyLarge,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('剩余待还', style: theme.textTheme.labelSmall),
                      Text(
                        formatMinor(item.remainingAmount),
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: item.remainingAmount > BigInt.zero
                              ? theme.colorScheme.error
                              : null,
                          fontWeight: item.remainingAmount > BigInt.zero
                              ? FontWeight.bold
                              : null,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
