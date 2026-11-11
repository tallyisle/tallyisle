import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../domain/ledger/asset_json.dart';
import '../../domain/model/codes.dart';
import '../common/common.dart';
import '../records/record_editor_page.dart';
import 'asset_editor_page.dart';
import 'asset_flow_section.dart';
import 'credit_section.dart';

/// "欠款 320.00" / "溢存款 50.00" for credit balances (reconciliation.md R4:
/// never a double minus sign).
String creditBalanceLabel(BigInt balance) => balance > BigInt.zero
    ? '溢存款 ${formatMinor(balance)}'
    : '欠款 ${formatMinor(-balance)}';

/// Account detail (`/assets/:id`): header, actions, credit statements and the
/// account's bill list with optional running balances.
class AssetDetailPage extends ConsumerWidget {
  const AssetDetailPage({super.key, required this.assetId});
  final int assetId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asset = ref.watch(assetProvider(assetId));
    return Scaffold(
      appBar: AppBar(
        title: Text(asset.value?.name ?? '账户详情'),
        actions: [
          if (asset.value != null)
            _AssetMenu(asset: asset.value!, key: const Key('asset-menu')),
        ],
      ),
      body: asyncBody(asset, (a) {
        if (a == null) return const Center(child: Text('账户不存在或已删除'));
        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _Header(asset: a)),
            if (a.type == AssetType.credit)
              SliverToBoxAdapter(child: CreditSection(asset: a)),
            AssetFlowSection(asset: a),
            const SliverToBoxAdapter(child: SizedBox(height: 96)),
          ],
        );
      }),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.asset});
  final Asset asset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final credit = asset.type == AssetType.credit;
    final info = credit ? CreditInfo.parse(asset.creditInfo) : null;
    final status = switch (asset.status) {
      AssetStatus.hidden => '已隐藏',
      AssetStatus.settled => '已结清',
      _ => null,
    };
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  credit
                      ? Icons.credit_card
                      : Icons.account_balance_wallet_outlined,
                ),
                const SizedBox(width: 8),
                Text(
                  credit ? '信用卡' : '普通账户',
                  style: theme.textTheme.labelLarge,
                ),
                if (asset.currency != null) ...[
                  const SizedBox(width: 8),
                  Chip(label: Text(asset.currency!)),
                ],
                if (status != null) ...[
                  const SizedBox(width: 8),
                  Chip(label: Text(status)),
                ],
              ],
            ),
            const SizedBox(height: 12),
            Text(
              credit ? creditBalanceLabel(asset.balanceMinor) : '余额',
              style: theme.textTheme.labelMedium,
            ),
            if (!credit)
              Text(
                formatMinor(asset.balanceMinor),
                key: const Key('asset-detail-balance'),
                style: theme.textTheme.headlineMedium,
              ),
            if (credit) ...[
              const SizedBox(height: 4),
              Text(
                '额度 ${formatMinor(asset.initMoneyMinor)}'
                ' · 账单日 ${creditDayLabel(info!.billDay)}'
                ' · 还款日 ${info.repaymentAfterBillDay ? '账单日后 ${info.repaymentDay} 天' : creditDayLabel(info.repaymentDay)}',
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (asset.remark != null && asset.remark!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(asset.remark!, style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (credit)
                  FilledButton.icon(
                    key: const Key('credit-repay'),
                    icon: const Icon(Icons.payments_outlined),
                    label: const Text('还款'),
                    onPressed: () => context.push(
                      repayRoute(
                        asset,
                        asset.balanceMinor.isNegative
                            ? -asset.balanceMinor
                            : BigInt.zero,
                      ),
                    ),
                  ),
                if (asset.type != AssetType.debt)
                  OutlinedButton.icon(
                    icon: const Icon(Icons.edit_note),
                    label: const Text('记一笔'),
                    onPressed: () =>
                        context.push('/record/new?asset=${asset.id}'),
                  ),
                if (!credit && asset.type != AssetType.debt)
                  OutlinedButton.icon(
                    key: const Key('asset-detail-deposits'),
                    icon: const Icon(Icons.lock_clock_outlined),
                    label: const Text('定期存款'),
                    onPressed: () =>
                        context.push('/deposits?assetId=${asset.id}'),
                  ),
                if (credit)
                  OutlinedButton.icon(
                    key: const Key('asset-detail-installments'),
                    icon: const Icon(Icons.calendar_view_month_outlined),
                    label: const Text('分期管理'),
                    onPressed: () => context.push('/installments'),
                  ),
                if (asset.type == AssetType.debt)
                  OutlinedButton.icon(
                    key: const Key('asset-detail-debt'),
                    icon: const Icon(Icons.swap_horiz_outlined),
                    label: const Text('借贷详情'),
                    onPressed: () =>
                        context.pushReplacement('/debts/${asset.id}'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Route that opens a transfer from the default repay account into [card].
String repayRoute(Asset card, BigInt amount) {
  final from = AssetExtra.parse(card.extraInfo).repayAssetId;
  return Uri(
    path: '/record/new',
    queryParameters: {
      'type': '${RecordType.transfer}',
      'to': '${card.id}',
      'from': ?from?.toString(),
      if (amount > BigInt.zero) 'amount': formatMinor(amount),
      'remark': '信用卡还款',
    },
  ).toString();
}

enum _Action { trend, edit, adjust, hide, unhide, settle, unsettle, delete }

class _AssetMenu extends ConsumerStatefulWidget {
  const _AssetMenu({super.key, required this.asset});
  final Asset asset;
  @override
  ConsumerState<_AssetMenu> createState() => _AssetMenuState();
}

class _AssetMenuState extends ConsumerState<_AssetMenu> {
  final ids = CommandIds();

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _run(_Action action) async {
    final a = widget.asset;
    try {
      final service = await ref.read(ledgerServiceProvider.future);
      switch (action) {
        case _Action.trend:
          if (mounted) await context.push('/stats/trend?assetId=${a.id}');
        case _Action.edit:
          if (mounted) await context.push('/assets/${a.id}/edit');
        case _Action.adjust:
          await _adjust(a);
        case _Action.hide ||
            _Action.unhide ||
            _Action.settle ||
            _Action.unsettle:
          final status = switch (action) {
            _Action.hide => AssetStatus.hidden,
            _Action.settle => AssetStatus.settled,
            _ => AssetStatus.active,
          };
          await service.setAssetStatus(
            commandId: ids.forPayload(['status', a.id, status]),
            assetId: a.id,
            status: status,
          );
        case _Action.delete:
          if (!mounted) return;
          final ok = await confirm(
            context,
            title: '删除“${a.name}”？',
            message: '只有没有任何账单的账户可以删除。',
            ok: '删除',
          );
          if (!ok) return;
          await service.deleteAsset(
            commandId: ids.forPayload(['delete', a.id]),
            assetId: a.id,
          );
          if (mounted) context.pop();
      }
    } catch (e) {
      _toast(safeMessage(e));
    }
  }

  Future<void> _adjust(Asset asset) async {
    final credit = asset.type == AssetType.credit;
    final controller = TextEditingController(
      text: formatMinor(credit ? -asset.balanceMinor : asset.balanceMinor),
    );
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('调整“${asset.name}”${credit ? '欠款' : '余额'}'),
        content: TextField(
          key: const Key('adjust-amount'),
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(
            decimal: true,
            signed: true,
          ),
          decoration: InputDecoration(
            helperText: credit
                ? '填当前实际欠款（溢存款填负数）；会生成一条“余额变更”记录'
                : '会生成一条“余额变更”记录',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('adjust-save'),
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null) return;
    final text = value.trim();
    final negative = text.startsWith('-');
    var target = parseAmount(negative ? text.substring(1) : text);
    if (negative) target = -target;
    if (credit) target = -target;
    final service = await ref.read(ledgerServiceProvider.future);
    final bookId = await ref.read(currentBookIdProvider.future);
    await service.adjustBalance(
      commandId: ids.forPayload(['adjust', asset.id, target.toJson()]),
      assetId: asset.id,
      target: target,
      bookId: bookId,
    );
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.asset;
    return PopupMenuButton<_Action>(
      onSelected: (v) => _run(v),
      itemBuilder: (_) => [
        const PopupMenuItem(
          key: Key('menu-trend'),
          value: _Action.trend,
          child: Text('资产趋势'),
        ),
        const PopupMenuItem(value: _Action.edit, child: Text('编辑账户')),
        const PopupMenuItem(
          key: Key('menu-adjust'),
          value: _Action.adjust,
          child: Text('调整余额'),
        ),
        if (a.status == AssetStatus.hidden)
          const PopupMenuItem(value: _Action.unhide, child: Text('取消隐藏'))
        else
          const PopupMenuItem(value: _Action.hide, child: Text('隐藏账户')),
        if (a.status == AssetStatus.settled)
          const PopupMenuItem(value: _Action.unsettle, child: Text('恢复为正常'))
        else
          const PopupMenuItem(value: _Action.settle, child: Text('标记为已结清')),
        const PopupMenuItem(value: _Action.delete, child: Text('删除账户')),
      ],
    );
  }
}
