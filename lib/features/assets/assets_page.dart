import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../app/adaptive.dart';
import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../domain/model/codes.dart';
import '../common/catalog_icons.dart';
import '../common/common.dart';
import '../common/desktop_modal_page.dart';
import '../debt/debt_detail_page.dart';
import '../debt/debt_editor_page.dart';
import '../debt/debt_page.dart';
import '../deposit/fixed_deposit_page.dart';
import '../installment/installment_page.dart';
import '../stats/asset_trend_page.dart';
import 'asset_detail_page.dart' show AssetDetailPage, creditBalanceLabel;
import 'asset_editor_page.dart';

const _uuid = Uuid();

/// Accounts of the current book with the net-worth summary
/// (docs/modules/asset-overview.md).
class AssetsPage extends ConsumerStatefulWidget {
  const AssetsPage({
    super.key,
    this.pickCustomImageBytes,
    this.standaloneManagement = false,
  });

  /// Optional image bytes provider override (used by widget tests to avoid
  /// platform file dialogs).
  final Future<Uint8List?> Function()? pickCustomImageBytes;

  /// True when pushed as a standalone Account Management view (e.g. `/assets/manage`
  /// from `RecordEditorPage`) rather than the shell's `/assets` tab.
  final bool standaloneManagement;

  @override
  ConsumerState<AssetsPage> createState() => _AssetsPageState();
}

class _AssetsPageState extends ConsumerState<AssetsPage> {
  bool hidden = false;
  bool showHiddenAccounts = false;
  int? _selectedAssetId;

  bool get _hasPageRouteRouter =>
      GoRouter.maybeOf(context) != null &&
      ModalRoute.of(context)?.settings is Page;

  Future<void> _openCreateAsset({int? initialType}) {
    if (_hasPageRouteRouter) {
      final path = initialType == null
          ? '/assets/new'
          : '/assets/new?type=$initialType';
      return context.push<void>(path);
    }
    return pushDesktopModalOrMaterialRoute<void>(
      context,
      child: AssetEditorPage(initialType: initialType),
    );
  }

  Future<void> _openEditAsset(int assetId) {
    if (_hasPageRouteRouter) {
      return context.push<void>('/assets/$assetId/edit');
    }
    return pushDesktopModalOrMaterialRoute<void>(
      context,
      child: AssetEditorPage(assetId: assetId),
    );
  }

  Future<void> _openEditDebt(int debtId) {
    if (_hasPageRouteRouter) {
      return context.push<void>('/debts/$debtId/edit');
    }
    return pushDesktopModalOrMaterialRoute<void>(
      context,
      child: DebtEditorPage(debtId: debtId),
    );
  }

  Future<void> _pushFullPageOrModal(
    String path,
    Widget Function() fallbackBuilder, {
    double maxWidth = 860,
    double maxHeight = 740,
  }) {
    final isPopupModal =
        DesktopAdaptive.isDesktop(context) &&
        ModalRoute.of(context) is PopupRoute;
    if (!isPopupModal && _hasPageRouteRouter) {
      return context.push<void>(path);
    }
    return pushDesktopModalOrMaterialRoute<void>(
      context,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
      child: fallbackBuilder(),
    );
  }

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
    final isDesktop = DesktopAdaptive.isDesktop(context);
    final isExpandedDesktop = DesktopAdaptive.isExpandedDesktop(context);
    final isPopupModal = isDesktop && ModalRoute.of(context) is PopupRoute;
    final isManagementMode = widget.standaloneManagement || isPopupModal;
    final useMasterDetail = isExpandedDesktop && !isManagementMode;

    String show(BigInt v) => hidden ? '***' : formatMinor(v);
    Widget cell(String label, BigInt? v, Key key) => Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Column(
          children: [
            Text(label, style: theme.textTheme.labelMedium),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                v == null ? '' : show(v),
                key: key,
                maxLines: 1,
                softWrap: false,
                style: theme.textTheme.titleMedium,
              ),
            ),
          ],
        ),
      ),
    );

    return Scaffold(
      appBar: AppBar(
        leading: isPopupModal ? const CloseButton() : null,
        title: Text(isManagementMode ? '账户管理' : '资产'),
        actions: [
          IconButton(
            tooltip: hidden ? '显示金额' : '隐藏金额',
            icon: Icon(hidden ? Icons.visibility_off : Icons.visibility),
            onPressed: () => setState(() => hidden = !hidden),
          ),
          if (isDesktop)
            Padding(
              padding: const EdgeInsets.only(right: 12, left: 4),
              child: FilledButton.tonalIcon(
                key: const Key('add-asset'),
                onPressed: _openCreateAsset,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('添加账户'),
              ),
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

        final selectableAssets = <Asset>[...normal, ...credit];
        final int? effectiveSelectedAssetId = selectableAssets.isEmpty
            ? null
            : (selectableAssets.any((a) => a.id == _selectedAssetId)
                  ? _selectedAssetId
                  : selectableAssets.first.id);

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

        Widget buildAccountTile(Asset a, {bool isDebtSection = false}) {
          final isDebt = isDebtSection || a.type == AssetType.debt;
          void openAssetOrDebtDetail() {
            if (isDebt) {
              _pushFullPageOrModal(
                '/debts/${a.id}',
                () => DebtDetailPage(debtId: a.id),
                maxWidth: 680,
                maxHeight: 740,
              );
            } else {
              _pushFullPageOrModal(
                '/assets/${a.id}',
                () => AssetDetailPage(assetId: a.id),
                maxWidth: 680,
                maxHeight: 740,
              );
            }
          }

          if (!isDesktop) {
            return _AssetTile(
              asset: a,
              hidden: hidden,
              isDebtSection: isDebtSection,
              onCustomizeIcon: () => _customizeAssetIcon(a),
              onTap: openAssetOrDebtDetail,
            );
          }
          return _DesktopAssetTile(
            asset: a,
            hidden: hidden,
            isDebtSection: isDebt,
            standaloneManagement: isManagementMode,
            selected:
                useMasterDetail && !isDebt && effectiveSelectedAssetId == a.id,
            onCustomizeIcon: () => _customizeAssetIcon(a),
            onOpenOrSelect: () {
              if (useMasterDetail && !isDebt) {
                setState(() => _selectedAssetId = a.id);
              } else {
                openAssetOrDebtDetail();
              }
            },
            onEdit: () => isDebt ? _openEditDebt(a.id) : _openEditAsset(a.id),
            onOpenTrend: () => _pushFullPageOrModal(
              '/stats/trend?assetId=${a.id}',
              () => AssetTrendPage(initialAssetId: a.id),
            ),
            onManageDebts: () =>
                _pushFullPageOrModal('/debts', () => const DebtPage()),
          );
        }

        final accountTreeList = ListView(
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
            Container(
              key: const Key('assets-quick-bar'),
              margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Material(
                color: theme.colorScheme.surfaceContainerLow,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: BorderSide(
                    color: theme.colorScheme.outlineVariant.withValues(
                      alpha: 0.45,
                    ),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 10,
                    horizontal: 6,
                  ),
                  child: Row(
                    children: [
                      _AssetQuickEntryItem(
                        itemKey: const Key('assets-quick-debts'),
                        icon: Icons.swap_horiz_rounded,
                        label: '借贷管理',
                        onTap: () => _pushFullPageOrModal(
                          '/debts',
                          () => const DebtPage(),
                        ),
                      ),
                      _AssetQuickEntryItem(
                        itemKey: const Key('assets-quick-installments'),
                        icon: Icons.calendar_view_month_rounded,
                        label: '分期管理',
                        onTap: () => _pushFullPageOrModal(
                          '/installments',
                          () => const InstallmentPage(),
                        ),
                      ),
                      _AssetQuickEntryItem(
                        itemKey: const Key('assets-quick-deposits'),
                        icon: Icons.lock_clock_rounded,
                        label: '定期存款',
                        onTap: () => _pushFullPageOrModal(
                          '/deposits',
                          () => const FixedDepositPage(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (allVisibleEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 32,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(isDesktop ? '还没有账户，点右上角或下方添加' : '还没有账户，点右下角添加'),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            key: const Key('empty-add-normal-asset'),
                            onPressed: _openCreateAsset,
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                            ),
                            icon: const Icon(
                              Icons.account_balance_wallet_outlined,
                              size: 18,
                            ),
                            label: const FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                '新建资金账户',
                                maxLines: 1,
                                softWrap: false,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton.icon(
                            key: const Key('empty-add-credit-asset'),
                            onPressed: () =>
                                _openCreateAsset(initialType: AssetType.credit),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                            ),
                            icon: const Icon(
                              Icons.credit_card_outlined,
                              size: 18,
                            ),
                            label: const FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                '新建信用账户',
                                maxLines: 1,
                                softWrap: false,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            if (normal.isNotEmpty) ...[
              header('资金账户'),
              for (final a in normal) buildAccountTile(a),
            ],
            if (credit.isNotEmpty) ...[
              header('信用账户'),
              for (final a in credit) buildAccountTile(a),
            ],
            if (debts.isNotEmpty) ...[
              header('借入 / 借出'),
              for (final a in debts) buildAccountTile(a, isDebtSection: true),
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
            SizedBox(height: isDesktop ? 32 : 96),
          ],
        );

        if (!useMasterDetail) {
          if (!isDesktop) {
            return accountTreeList;
          }
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: accountTreeList,
            ),
          );
        }

        final scheme = theme.colorScheme;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              key: const Key('assets-master-pane'),
              width: 380,
              child: accountTreeList,
            ),
            VerticalDivider(
              width: 1,
              thickness: 1,
              color: scheme.outlineVariant.withValues(alpha: 0.45),
            ),
            Expanded(
              child: ColoredBox(
                key: const Key('assets-detail-pane'),
                color: scheme.surface,
                child: HeroMode(
                  enabled: false,
                  child: effectiveSelectedAssetId == null
                      ? const _DesktopEmptyAssetDetailGuide()
                      : AssetDetailPage(
                          assetId: effectiveSelectedAssetId,
                          embeddedInPane: true,
                          onDeleted: () =>
                              setState(() => _selectedAssetId = null),
                        ),
                ),
              ),
            ),
          ],
        );
      }),
      floatingActionButton: isDesktop
          ? null
          : FloatingActionButton.extended(
              key: const Key('add-asset'),
              heroTag: widget.standaloneManagement
                  ? 'fab-assets-manage'
                  : 'fab-assets',
              onPressed: _openCreateAsset,
              icon: const Icon(Icons.add),
              label: const Text('添加账户'),
            ),
    );
  }
}

class _DesktopEmptyAssetDetailGuide extends StatelessWidget {
  const _DesktopEmptyAssetDetailGuide();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.account_balance_wallet_outlined,
                  size: 28,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '暂无可展示的账户流水',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '在左侧新建或选择任意资金账户、信用账户后，即可在此实时查看按月流水、信用账单与对账余额。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
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

enum _AssetContextAction {
  viewFlows,
  newRecord,
  editAsset,
  assetTrend,
  viewDebtDetail,
  editDebt,
  manageDebts,
}

class _DesktopAssetTile extends StatefulWidget {
  const _DesktopAssetTile({
    required this.asset,
    required this.hidden,
    required this.onCustomizeIcon,
    required this.onOpenOrSelect,
    required this.onEdit,
    required this.onOpenTrend,
    required this.onManageDebts,
    required this.selected,
    this.isDebtSection = false,
    this.standaloneManagement = false,
  });

  final Asset asset;
  final bool hidden;
  final VoidCallback onCustomizeIcon;
  final VoidCallback onOpenOrSelect;
  final VoidCallback onEdit;
  final VoidCallback onOpenTrend;
  final VoidCallback onManageDebts;
  final bool selected;
  final bool isDebtSection;
  final bool standaloneManagement;

  @override
  State<_DesktopAssetTile> createState() => _DesktopAssetTileState();
}

class _DesktopAssetTileState extends State<_DesktopAssetTile> {
  bool _hovered = false;

  Future<void> _showContextMenu(Offset globalPosition) async {
    final asset = widget.asset;
    final isDebt = widget.isDebtSection || asset.type == AssetType.debt;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final position = RelativeRect.fromRect(
      globalPosition & const Size(1, 1),
      Offset.zero & (overlay?.size ?? const Size(1280, 800)),
    );

    final action = await showMenu<_AssetContextAction>(
      context: context,
      position: position,
      items: isDebt
          ? const <PopupMenuEntry<_AssetContextAction>>[
              PopupMenuItem<_AssetContextAction>(
                value: _AssetContextAction.viewDebtDetail,
                child: Text('查看借贷详情'),
              ),
              PopupMenuItem<_AssetContextAction>(
                value: _AssetContextAction.editDebt,
                child: Text('编辑借贷项目'),
              ),
              PopupMenuItem<_AssetContextAction>(
                value: _AssetContextAction.manageDebts,
                child: Text('进入借贷管理'),
              ),
            ]
          : <PopupMenuEntry<_AssetContextAction>>[
              const PopupMenuItem<_AssetContextAction>(
                value: _AssetContextAction.viewFlows,
                child: Text('查看账户流水'),
              ),
              if (!widget.standaloneManagement)
                const PopupMenuItem<_AssetContextAction>(
                  value: _AssetContextAction.newRecord,
                  child: Text('记一笔到此账户'),
                ),
              const PopupMenuItem<_AssetContextAction>(
                value: _AssetContextAction.editAsset,
                child: Text('编辑账户'),
              ),
              const PopupMenuItem<_AssetContextAction>(
                value: _AssetContextAction.assetTrend,
                child: Text('资产趋势'),
              ),
            ],
    );
    if (action == null || !mounted) return;
    switch (action) {
      case _AssetContextAction.viewFlows:
        widget.onOpenOrSelect();
      case _AssetContextAction.newRecord:
        await context.push('/record/new?assetId=${asset.id}&asset=${asset.id}');
      case _AssetContextAction.editAsset:
        widget.onEdit();
      case _AssetContextAction.assetTrend:
        widget.onOpenTrend();
      case _AssetContextAction.viewDebtDetail:
        widget.onOpenOrSelect();
      case _AssetContextAction.editDebt:
        widget.onEdit();
      case _AssetContextAction.manageDebts:
        widget.onManageDebts();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final asset = widget.asset;
    final isArchived = asset.status != AssetStatus.active;
    final statusLabel = switch (asset.status) {
      AssetStatus.hidden => '已隐藏',
      AssetStatus.settled => '已结清',
      _ => null,
    };

    final bgColor = widget.selected
        ? scheme.secondaryContainer.withValues(alpha: _hovered ? 0.65 : 0.5)
        : (_hovered
              ? scheme.surfaceContainerHighest.withValues(alpha: 0.45)
              : Colors.transparent);

    final bool isDebt = widget.isDebtSection || asset.type == AssetType.debt;
    final String trailingText;
    final List<String> subtitleParts;

    if (isDebt) {
      final isLend = asset.subType == AssetType.debtLend;
      final dirLabel = isLend ? '借出' : '借入';
      final displayMinor =
          asset.status == AssetStatus.settled ||
              asset.balanceMinor < BigInt.zero
          ? BigInt.zero
          : asset.balanceMinor;
      subtitleParts = <String>[
        dirLabel,
        ?statusLabel,
        ?asset.currency,
        if (asset.remark != null && asset.remark!.isNotEmpty) asset.remark!,
      ];
      trailingText = widget.hidden ? '***' : formatMinor(displayMinor);
    } else {
      final credit = asset.type == AssetType.credit;
      subtitleParts = <String>[
        ?statusLabel,
        ?asset.currency,
        if (asset.remark != null && asset.remark!.isNotEmpty) asset.remark!,
      ];
      trailingText = widget.hidden
          ? '***'
          : credit
          ? creditBalanceLabel(asset.balanceMinor)
          : formatMinor(asset.balanceMinor);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onSecondaryTapUp: (details) =>
              _showContextMenu(details.globalPosition),
          child: Material(
            color: bgColor,
            borderRadius: BorderRadius.circular(10),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: Key('asset-${asset.name}'),
              onTap: widget.onOpenOrSelect,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 9,
                ),
                child: Row(
                  children: [
                    _CustomizableAssetAvatar(
                      asset: asset,
                      isArchived: isArchived,
                      onCustomize: widget.onCustomizeIcon,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            asset.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontWeight: widget.selected
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                            ),
                          ),
                          if (subtitleParts.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              subtitleParts.join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 140),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Text(
                          trailingText,
                          maxLines: 1,
                          softWrap: false,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    if (widget.standaloneManagement) ...[
                      const SizedBox(width: 4),
                      IconButton(
                        key: Key('manage-edit-asset-${asset.id}'),
                        tooltip: isDebt ? '编辑借贷项目' : '编辑账户',
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints.tightFor(
                          width: 32,
                          height: 32,
                        ),
                        padding: EdgeInsets.zero,
                        icon: Icon(
                          Icons.edit_outlined,
                          size: 18,
                          color: scheme.onSurfaceVariant,
                        ),
                        onPressed: widget.onEdit,
                      ),
                    ],
                  ],
                ),
              ),
            ),
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
    required this.onTap,
    this.isDebtSection = false,
  });

  final Asset asset;
  final bool hidden;
  final VoidCallback onCustomizeIcon;
  final VoidCallback onTap;
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
        onTap: onTap,
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
      onTap: onTap,
    );
  }
}

class _AssetQuickEntryItem extends StatelessWidget {
  const _AssetQuickEntryItem({
    required this.itemKey,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final Key itemKey;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: InkWell(
        key: itemKey,
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer.withValues(alpha: 0.65),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(icon, size: 20, color: scheme.primary),
              ),
              const SizedBox(height: 6),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: scheme.onSurface,
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
