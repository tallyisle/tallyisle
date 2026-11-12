import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../domain/model/codes.dart';
import '../common/catalog_icons.dart';
import '../common/common.dart';
import 'asset_detail_page.dart' show creditBalanceLabel;

const _uuid = Uuid();

/// Accounts of the current book with the net-worth summary
/// (docs/modules/asset-overview.md).
class AssetsPage extends ConsumerStatefulWidget {
  const AssetsPage({super.key, this.pickCustomImageBytes});

  /// Optional image bytes provider override (used by widget tests to avoid
  /// platform file dialogs).
  final Future<Uint8List?> Function()? pickCustomImageBytes;

  @override
  ConsumerState<AssetsPage> createState() => _AssetsPageState();
}

class _AssetsPageState extends ConsumerState<AssetsPage> {
  bool hidden = false;
  bool showHiddenAccounts = false;

  Future<void> _customizeAssetIcon(Asset asset) async {
    final picked = await showAssetVisualPicker(
      context,
      initialIcon: asset.icon.isEmpty ? null : asset.icon,
      initialColor: asset.color,
      assetType: asset.type,
      subType: asset.subType,
      previewName: asset.name,
      pickCustomImageBytes: widget.pickCustomImageBytes,
    );
    if (picked == null || !mounted) return;
    try {
      final service = await ref.read(ledgerServiceProvider.future);
      final counted = asset.type == AssetType.debt
          ? asset.isEffectiveAsset == 0
          : asset.isEffectiveAsset == 1;
      await service.updateAsset(
        commandId: _uuid.v4(),
        assetId: asset.id,
        name: asset.name,
        icon: picked.icon,
        color: picked.colorHex,
        subType: asset.subType,
        remark: asset.remark,
        groupName: asset.groupName,
        currency: asset.currency,
        countedInNetWorth: counted,
        creditInfo: asset.creditInfo,
        extraInfo: asset.extraInfo,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

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
        var hintShown = false;
        Widget header(String text) {
          final showHint = !hintShown;
          hintShown = true;
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Expanded(child: Text(text, style: theme.textTheme.labelLarge)),
                if (showHint)
                  Text(
                    '点击自定义图标',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
              ],
            ),
          );
        }

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
              Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('还没有账户，点右下角添加'),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        OutlinedButton.icon(
                          key: const Key('empty-add-normal-asset'),
                          onPressed: () => context.push('/assets/new'),
                          icon: const Icon(
                            Icons.account_balance_wallet_outlined,
                          ),
                          label: const Text('新建资金账户'),
                        ),
                        OutlinedButton.icon(
                          key: const Key('empty-add-credit-asset'),
                          onPressed: () => context.push(
                            '/assets/new?type=${AssetType.credit}',
                          ),
                          icon: const Icon(Icons.credit_card_outlined),
                          label: const Text('新建信用账户'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            if (normal.isNotEmpty) ...[
              header('资金账户'),
              for (final a in normal)
                _AssetTile(
                  asset: a,
                  hidden: hidden,
                  onCustomizeIcon: () => _customizeAssetIcon(a),
                ),
            ],
            if (credit.isNotEmpty) ...[
              header('信用账户'),
              for (final a in credit)
                _AssetTile(
                  asset: a,
                  hidden: hidden,
                  onCustomizeIcon: () => _customizeAssetIcon(a),
                ),
            ],
            if (debts.isNotEmpty) ...[
              header('借入 / 借出'),
              for (final a in debts)
                _AssetTile(
                  asset: a,
                  hidden: hidden,
                  isDebtSection: true,
                  onCustomizeIcon: () => _customizeAssetIcon(a),
                ),
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

class _CustomizableAssetAvatar extends StatelessWidget {
  const _CustomizableAssetAvatar({
    required this.asset,
    required this.isArchived,
    required this.onCustomize,
  });

  final Asset asset;
  final bool isArchived;
  final VoidCallback onCustomize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Opacity(
      opacity: isArchived ? 0.5 : 1.0,
      child: Tooltip(
        message: '点击自定义图标',
        child: InkWell(
          key: Key('asset-customize-icon-${asset.name}'),
          customBorder: const CircleBorder(),
          onTap: onCustomize,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              AssetIconAvatar(
                iconKey: asset.icon,
                colorHex: asset.color,
                name: asset.name,
                assetType: asset.type,
                subType: asset.subType,
                size: 38,
              ),
              Positioned(
                right: -2,
                bottom: -2,
                child: Container(
                  width: 15,
                  height: 15,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: theme.colorScheme.surface,
                      width: 1.4,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.edit_rounded,
                    size: 9.5,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AssetTile extends StatelessWidget {
  const _AssetTile({
    required this.asset,
    required this.hidden,
    required this.onCustomizeIcon,
    this.isDebtSection = false,
  });

  final Asset asset;
  final bool hidden;
  final VoidCallback onCustomizeIcon;
  final bool isDebtSection;

  @override
  Widget build(BuildContext context) {
    final isArchived = asset.status != AssetStatus.active;
    final statusLabel = switch (asset.status) {
      AssetStatus.hidden => '已隐藏',
      AssetStatus.settled => '已结清',
      _ => null,
    };

    if (isDebtSection || asset.type == AssetType.debt) {
      final isLend = asset.subType == AssetType.debtLend;
      final dirLabel = isLend ? '借出' : '借入';
      final displayMinor =
          asset.status == AssetStatus.settled ||
              asset.balanceMinor < BigInt.zero
          ? BigInt.zero
          : asset.balanceMinor;
      final subtitleParts = <String>[
        dirLabel,
        ?statusLabel,
        ?asset.currency,
        if (asset.remark != null && asset.remark!.isNotEmpty) asset.remark!,
      ];
      return ListTile(
        key: Key('asset-${asset.name}'),
        leading: _CustomizableAssetAvatar(
          asset: asset,
          isArchived: isArchived,
          onCustomize: onCustomizeIcon,
        ),
        title: Text(asset.name),
        subtitle: Text(subtitleParts.join(' · ')),
        trailing: Text(hidden ? '***' : formatMinor(displayMinor)),
        onTap: () => context.push('/debts/${asset.id}'),
      );
    }

    final credit = asset.type == AssetType.credit;
    final subtitleParts = <String>[
      ?statusLabel,
      ?asset.currency,
      if (asset.remark != null && asset.remark!.isNotEmpty) asset.remark!,
    ];

    return ListTile(
      key: Key('asset-${asset.name}'),
      leading: _CustomizableAssetAvatar(
        asset: asset,
        isArchived: isArchived,
        onCustomize: onCustomizeIcon,
      ),
      title: Text(asset.name),
      subtitle: subtitleParts.isEmpty ? null : Text(subtitleParts.join(' · ')),
      trailing: Text(
        hidden
            ? '***'
            : credit
            ? creditBalanceLabel(asset.balanceMinor)
            : formatMinor(asset.balanceMinor),
      ),
      onTap: () => context.push('/assets/${asset.id}'),
    );
  }
}
