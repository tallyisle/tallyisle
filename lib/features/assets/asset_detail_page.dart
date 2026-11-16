import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/adaptive.dart';
import '../../app/providers.dart';
import '../../core/failure.dart';
import '../../core/money.dart';
import '../../data/db/database.dart';
import '../../data/ledger/ledger_service.dart';
import '../../domain/ledger/asset_json.dart';
import '../../domain/model/codes.dart';
import '../common/catalog_icons.dart';
import '../common/common.dart';
import 'asset_editor_page.dart';
import 'asset_flow_section.dart';
import 'credit_section.dart';

final _maxAdjustAmount = Money.parse('88888888888.00');

Money _parseAmount(String text) {
  final t = text.trim();
  if (t.isEmpty) return Money.zero();
  final normalized = t.endsWith('.') ? t.substring(0, t.length - 1) : t;
  final money = Money.parse(
    normalized.startsWith('.') ? '0$normalized' : normalized,
  );
  if (money.units > _maxAdjustAmount.units) {
    throw const Failure(FailureCode.validation, '金额不能超过 88888888888.00');
  }
  return money;
}

Future<int> _readCurrentBookId(AppDatabase db) async {
  final pref = await (db.select(
    db.preferences,
  )..where((t) => t.key.equals('current_book_id'))).getSingleOrNull();
  final parsed = int.tryParse(pref?.value ?? '');
  if (parsed != null) return parsed;
  final firstBook =
      await (db.select(db.accountBooks)
            ..orderBy([
              (t) => OrderingTerm.asc(t.sort),
              (t) => OrderingTerm.asc(t.id),
            ])
            ..limit(1))
          .getSingleOrNull();
  return firstBook?.id ?? 1;
}

/// "欠款 320.00" / "溢存款 50.00" for credit balances (reconciliation.md R4:
/// never a double minus sign).
String creditBalanceLabel(BigInt balance) => balance > BigInt.zero
    ? '溢存款 ${formatMinor(balance)}'
    : '欠款 ${formatMinor(-balance)}';

/// Account detail (`/assets/:id`): header, actions, credit statements and the
/// account's bill list with optional running balances.
class AssetDetailPage extends ConsumerWidget {
  const AssetDetailPage({
    super.key,
    required this.assetId,
    this.embeddedInPane = false,
    this.onDeleted,
  });

  final int assetId;
  final bool embeddedInPane;
  final VoidCallback? onDeleted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asset = ref.watch(assetProvider(assetId));
    final fallbackAsset = embeddedInPane
        ? ref
              .watch(assetsProvider)
              .value
              ?.where((x) => x.id == assetId)
              .firstOrNull
        : null;
    final currentAsset = asset.value ?? fallbackAsset;
    final theme = Theme.of(context);

    Widget buildScrollableDetail(Asset a) {
      return CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            key: const ValueKey('asset-header'),
            child: _Header(asset: a),
          ),
          if (a.type == AssetType.credit)
            SliverToBoxAdapter(
              key: const ValueKey('asset-credit-section'),
              child: CreditSection(asset: a),
            ),
          AssetFlowSection(key: const ValueKey('asset-flow-section'), asset: a),
          SliverToBoxAdapter(
            key: const ValueKey('asset-bottom-pad'),
            child: SizedBox(height: embeddedInPane ? 64 : 96),
          ),
        ],
      );
    }

    final Widget detailBody;
    if (embeddedInPane && currentAsset != null) {
      detailBody = buildScrollableDetail(currentAsset);
    } else {
      detailBody = asyncBody(asset, (a) {
        if (a == null) return const Center(child: Text('账户不存在或已删除'));
        return buildScrollableDetail(a);
      });
    }

    if (embeddedInPane) {
      return Material(
        color: theme.colorScheme.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 52,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        currentAsset?.name ?? '账户详情',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (currentAsset != null)
                      _AssetMenu(
                        asset: currentAsset,
                        key: const Key('asset-menu'),
                        embeddedInPane: true,
                        onDeleted: onDeleted,
                      ),
                  ],
                ),
              ),
            ),
            Divider(
              height: 1,
              thickness: 0.6,
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.45),
            ),
            Expanded(child: detailBody),
          ],
        ),
      );
    }

    final isDesktop = DesktopAdaptive.isDesktop(context);
    final isDesktopModal =
        isDesktop &&
        ModalRoute.of(context) is PopupRoute &&
        Navigator.of(context).canPop();

    return Scaffold(
      appBar: AppBar(
        leading: isDesktopModal ? const CloseButton() : null,
        title: Text(asset.value?.name ?? '账户详情'),
        actions: [
          if (asset.value != null)
            _AssetMenu(asset: asset.value!, key: const Key('asset-menu')),
        ],
      ),
      body: isDesktop
          ? Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 820),
                child: detailBody,
              ),
            )
          : detailBody,
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
    final accountTypeLabel = credit
        ? '信用账户'
        : asset.type == AssetType.debt
        ? '借贷账户'
        : '资金账户';

    final actionButtons = <Widget>[
      if (credit)
        FilledButton.icon(
          key: const Key('credit-repay'),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          icon: const Icon(Icons.payments_outlined, size: 18),
          label: const FittedBox(
            fit: BoxFit.scaleDown,
            child: Text('还款', maxLines: 1, softWrap: false),
          ),
          onPressed: () => context.push(
            repayRoute(
              asset,
              asset.balanceMinor.isNegative ? -asset.balanceMinor : BigInt.zero,
            ),
          ),
        ),
      if (asset.type != AssetType.debt)
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          icon: const Icon(Icons.edit_note, size: 18),
          label: const FittedBox(
            fit: BoxFit.scaleDown,
            child: Text('记一笔', maxLines: 1, softWrap: false),
          ),
          onPressed: () => context.push('/record/new?asset=${asset.id}'),
        ),
      if (!credit && asset.type != AssetType.debt)
        OutlinedButton.icon(
          key: const Key('asset-detail-deposits'),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          icon: const Icon(Icons.lock_clock_outlined, size: 18),
          label: const FittedBox(
            fit: BoxFit.scaleDown,
            child: Text('定期存款', maxLines: 1, softWrap: false),
          ),
          onPressed: () => context.push('/deposits?assetId=${asset.id}'),
        ),
      if (credit)
        OutlinedButton.icon(
          key: const Key('asset-detail-installments'),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
          icon: const Icon(Icons.calendar_view_month_outlined, size: 18),
          label: const FittedBox(
            fit: BoxFit.scaleDown,
            child: Text('分期管理', maxLines: 1, softWrap: false),
          ),
          onPressed: () => context.push('/installments'),
        ),
      if (asset.type == AssetType.debt)
        OutlinedButton.icon(
          key: const Key('asset-detail-debt'),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 12),
          ),
          icon: const Icon(Icons.swap_horiz_outlined, size: 18),
          label: const FittedBox(
            fit: BoxFit.scaleDown,
            child: Text('借贷详情', maxLines: 1, softWrap: false),
          ),
          onPressed: () => context.pushReplacement('/debts/${asset.id}'),
        ),
    ];

    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AssetIconAvatar(
                  iconKey: asset.icon,
                  colorHex: asset.color,
                  name: asset.name,
                  assetType: asset.type,
                  subType: asset.subType,
                  size: 40,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(accountTypeLabel, style: theme.textTheme.labelLarge),
                      if (asset.currency != null)
                        Chip(
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          label: Text(asset.currency!),
                        ),
                      if (status != null)
                        Chip(
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          label: Text(status),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              credit ? creditBalanceLabel(asset.balanceMinor) : '余额',
              style: theme.textTheme.labelMedium,
            ),
            if (!credit)
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  formatMinor(asset.balanceMinor),
                  key: const Key('asset-detail-balance'),
                  maxLines: 1,
                  softWrap: false,
                  style: theme.textTheme.headlineMedium,
                ),
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
            if (actionButtons.isNotEmpty) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  for (var i = 0; i < actionButtons.length; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    Expanded(child: actionButtons[i]),
                  ],
                ],
              ),
            ],
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
      'remark': '信用账户还款',
    },
  ).toString();
}

enum _Action { trend, edit, adjust, hide, unhide, settle, unsettle, delete }

class _AssetMenu extends ConsumerStatefulWidget {
  const _AssetMenu({
    super.key,
    required this.asset,
    this.embeddedInPane = false,
    this.onDeleted,
  });

  final Asset asset;
  final bool embeddedInPane;
  final VoidCallback? onDeleted;

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
          if (mounted) {
            if (widget.embeddedInPane) {
              widget.onDeleted?.call();
            } else if (GoRouter.maybeOf(context) != null && context.canPop()) {
              context.pop();
            } else {
              await Navigator.of(context).maybePop();
            }
          }
      }
    } catch (e) {
      _toast(safeMessage(e));
    }
  }

  Future<void> _adjust(Asset asset) async {
    if (!mounted) return;
    final credit = asset.type == AssetType.credit;
    final initialText = formatMinor(
      credit ? -asset.balanceMinor : asset.balanceMinor,
    );
    final value = await showDialog<String>(
      context: context,
      builder: (_) => _AdjustBalanceDialog(
        assetName: asset.name,
        isCredit: credit,
        initialText: initialText,
      ),
    );
    if (value == null || !mounted) return;
    final text = value.trim();
    final negative = text.startsWith('-');
    var target = _parseAmount(negative ? text.substring(1) : text);
    if (negative) target = -target;
    if (credit) target = -target;
    final db = await ref.read(databaseProvider.future);
    final bookId = await _readCurrentBookId(db);
    final service = LedgerService(db);
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

class _AdjustBalanceDialog extends StatefulWidget {
  const _AdjustBalanceDialog({
    required this.assetName,
    required this.isCredit,
    required this.initialText,
  });

  final String assetName;
  final bool isCredit;
  final String initialText;

  @override
  State<_AdjustBalanceDialog> createState() => _AdjustBalanceDialogState();
}

class _AdjustBalanceDialogState extends State<_AdjustBalanceDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = DesktopAdaptive.isDesktop(context);
    Widget field = TextField(
      key: const Key('adjust-amount'),
      controller: _controller,
      autofocus: true,
      keyboardType: const TextInputType.numberWithOptions(
        decimal: true,
        signed: true,
      ),
      decoration: InputDecoration(
        border: isDesktop ? const OutlineInputBorder() : null,
        helperText: widget.isCredit
            ? '填当前实际欠款（溢存款填负数）；会生成一条“余额变更”记录'
            : '会生成一条“余额变更”记录',
      ),
    );
    if (isDesktop) {
      field = ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 360, maxWidth: 420),
        child: field,
      );
    }
    return AlertDialog(
      title: Text('调整“${widget.assetName}”${widget.isCredit ? '欠款' : '余额'}'),
      content: field,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('adjust-save'),
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('保存'),
        ),
      ],
    );
  }
}
