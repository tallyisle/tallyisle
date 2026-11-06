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
        final hiddenCount = list
            .where((a) => a.status == AssetStatus.hidden)
            .length;
        final visible = list
            .where((a) => showHiddenAccounts || a.status != AssetStatus.hidden)
            .toList();
        final normal = visible.where((a) => a.type != AssetType.credit);
        final credit = visible.where((a) => a.type == AssetType.credit);
        Widget header(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(text, style: theme.textTheme.labelLarge),
        );
        return ListView(
          children: [
            Card(
              margin: const EdgeInsets.all(16),
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
            if (visible.isEmpty)
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
            if (hiddenCount > 0)
              TextButton(
                onPressed: () =>
                    setState(() => showHiddenAccounts = !showHiddenAccounts),
                child: Text(
                  showHiddenAccounts ? '收起已隐藏账户' : '显示已隐藏账户（$hiddenCount）',
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
