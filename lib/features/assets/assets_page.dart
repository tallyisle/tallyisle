import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../domain/model/codes.dart';
import '../common/common.dart';
import 'asset_detail_page.dart' show creditBalanceLabel;

/// Accounts of the current book with the net-worth summary
/// (docs/modules/asset-overview.md).
class AssetsPage extends ConsumerStatefulWidget {
  const AssetsPage({super.key});
  @override
  ConsumerState<AssetsPage> createState() => _AssetsPageState();
}

class _AssetsPageState extends ConsumerState<AssetsPage> {
  bool hidden = false;
  bool showHiddenAccounts = false;

  @override
  Widget build(BuildContext context) {
    final assets = ref.watch(bookAssetsProvider);
    final overview = ref.watch(assetOverviewProvider).value;
    final theme = Theme.of(context);
    String show(BigInt v) => hidden ? '***' : formatMinor(v);
    Widget cell(String label, BigInt? v, Key key) => Expanded(
      child: Column(
        children: [
          Text(label, style: theme.textTheme.labelMedium),
          const SizedBox(height: 4),
          Text(
            v == null ? '' : show(v),
            key: key,
            style: theme.textTheme.titleMedium,
          ),
        ],
      ),
    );

    Widget tile(Asset a) {
      final credit = a.type == AssetType.credit;
      final status = switch (a.status) {
        AssetStatus.hidden => '已隐藏',
        AssetStatus.settled => '已结清',
        _ => null,
      };
      return ListTile(
        key: Key('asset-${a.name}'),
        leading: Icon(
          credit ? Icons.credit_card : Icons.account_balance_wallet_outlined,
        ),
        title: Text(a.name),
        subtitle: Text(
          [
            ?status,
            ?a.currency,
            if (a.remark != null && a.remark!.isNotEmpty) a.remark!,
          ].join(' · '),
        ),
        trailing: Text(
          hidden
              ? '***'
              : credit
              ? creditBalanceLabel(a.balanceMinor)
              : formatMinor(a.balanceMinor),
        ),
        onTap: () => context.push('/assets/${a.id}'),
      );
    }

    Widget debtTile(Asset a) {
      final isLend = a.subType == AssetType.debtLend;
      final dirLabel = isLend ? '借出' : '借入';
      final status = switch (a.status) {
        AssetStatus.hidden => '已隐藏',
        AssetStatus.settled => '已结清',
        _ => null,
      };
      final displayMinor =
          a.status == AssetStatus.settled || a.balanceMinor < BigInt.zero
          ? BigInt.zero
          : a.balanceMinor;
      return ListTile(
        key: Key('asset-${a.name}'),
        leading: Icon(
          isLend ? Icons.call_made_outlined : Icons.call_received_outlined,
        ),
        title: Text(a.name),
        subtitle: Text(
          [
            dirLabel,
            ?status,
            ?a.currency,
            if (a.remark != null && a.remark!.isNotEmpty) a.remark!,
          ].join(' · '),
        ),
        trailing: Text(hidden ? '***' : formatMinor(displayMinor)),
        onTap: () => context.push('/debts/${a.id}'),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('资产'),
        actions: [
          IconButton(
            tooltip: hidden ? '显示金额' : '隐藏金额',
            icon: Icon(hidden ? Icons.visibility_off : Icons.visibility),
            onPressed: () => setState(() => hidden = !hidden),
          ),
        ],
      ),
      body: asyncBody(assets, (list) {
        final archivedCount = list
            .where(
              (a) => a.type == AssetType.debt
                  ? a.status != AssetStatus.active
                  : a.status == AssetStatus.hidden,
            )
            .length;
        final normal = list
            .where(
              (a) =>
                  a.type != AssetType.credit &&
                  a.type != AssetType.debt &&
                  (showHiddenAccounts || a.status != AssetStatus.hidden),
            )
            .toList();
        final credit = list
            .where(
              (a) =>
                  a.type == AssetType.credit &&
                  (showHiddenAccounts || a.status != AssetStatus.hidden),
            )
            .toList();
        final debts = list
            .where(
              (a) =>
                  a.type == AssetType.debt &&
                  (showHiddenAccounts || a.status == AssetStatus.active),
            )
            .toList();
        final allVisibleEmpty =
            normal.isEmpty && credit.isEmpty && debts.isEmpty;
        Widget header(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(text, style: theme.textTheme.labelLarge),
        );
        return ListView(
          children: [
            Card(
              margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Column(
                  children: [
                    Row(
                      children: [
                        cell('净资产', overview?.netAsset, const Key('net-asset')),
                        cell(
                          '总资产',
                          overview?.totalAsset,
                          const Key('total-asset'),
                        ),
                        cell(
                          '总负债',
                          overview?.totalLiabilities,
                          const Key('total-liabilities'),
                        ),
                      ],
                    ),
                    if (overview != null && overview.missingRates.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          '缺少汇率：${overview.missingRates.join('、')}（暂按 1:1 计算）',
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ActionChip(
                    key: const Key('assets-quick-debts'),
                    avatar: const Icon(Icons.swap_horiz_outlined, size: 18),
                    label: const Text('借贷管理'),
                    onPressed: () => context.push('/debts'),
                  ),
                  ActionChip(
                    key: const Key('assets-quick-installments'),
                    avatar: const Icon(
                      Icons.calendar_view_month_outlined,
                      size: 18,
                    ),
                    label: const Text('分期管理'),
                    onPressed: () => context.push('/installments'),
                  ),
                  ActionChip(
                    key: const Key('assets-quick-deposits'),
                    avatar: const Icon(Icons.lock_clock_outlined, size: 18),
                    label: const Text('定期存款'),
                    onPressed: () => context.push('/deposits'),
                  ),
                ],
              ),
            ),
            if (allVisibleEmpty)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: Text('还没有账户，点右下角添加')),
              ),
            if (normal.isNotEmpty) ...[
              header('资金账户'),
              for (final a in normal) tile(a),
            ],
            if (credit.isNotEmpty) ...[
              header('信用卡'),
              for (final a in credit) tile(a),
            ],
            if (debts.isNotEmpty) ...[
              header('借入 / 借出'),
              for (final a in debts) debtTile(a),
            ],
            if (archivedCount > 0)
              TextButton(
                key: const Key('toggle-hidden-assets'),
                onPressed: () =>
                    setState(() => showHiddenAccounts = !showHiddenAccounts),
                child: Text(
                  showHiddenAccounts ? '收起已隐藏账户' : '显示已隐藏账户（$archivedCount）',
                ),
              ),
            const SizedBox(height: 96),
          ],
        );
      }),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('add-asset'),
        heroTag: 'fab-assets',
        onPressed: () => context.push('/assets/new'),
        icon: const Icon(Icons.add),
        label: const Text('添加账户'),
      ),
    );
  }
}
