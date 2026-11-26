import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../app/adaptive.dart';
import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../domain/model/codes.dart';
import '../common/catalog_icons.dart';
import '../common/common.dart';
import '../common/desktop_modal_page.dart';
import '../debt/debt_detail_page.dart';
import '../debt/debt_providers.dart' show debtServiceProvider;
import 'asset_detail_page.dart' show AssetDetailPage, creditBalanceLabel;

const _uuid = Uuid();

/// Opens [ArchivedAssetsSheet] as a modal bottom sheet on mobile or a centered
/// `560×680` [Dialog] on desktop.
Future<void> showArchivedAssetsSheet(
  BuildContext context, {
  required bool hiddenAmounts,
}) {
  if (DesktopAdaptive.isDesktop(context)) {
    return showDialog<void>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) => DesktopModalEscapeScope(
        enabled: true,
        child: Dialog(
          key: const Key('archived-assets-dialog'),
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 24,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560, maxHeight: 680),
            child: ArchivedAssetsSheet(
              hiddenAmounts: hiddenAmounts,
              isDesktopDialog: true,
            ),
          ),
        ),
      ),
    );
  }

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.78,
      child: ArchivedAssetsSheet(
        hiddenAmounts: hiddenAmounts,
        isDesktopDialog: false,
      ),
    ),
  );
}

/// Unified 2-tab (`已隐藏 | 已结清`) modal viewer & restorer for archived accounts.
class ArchivedAssetsSheet extends ConsumerStatefulWidget {
  const ArchivedAssetsSheet({
    super.key,
    required this.hiddenAmounts,
    this.isDesktopDialog = false,
  });

  final bool hiddenAmounts;
  final bool isDesktopDialog;

  @override
  ConsumerState<ArchivedAssetsSheet> createState() =>
      _ArchivedAssetsSheetState();
}

class _ArchivedAssetsSheetState extends ConsumerState<ArchivedAssetsSheet> {
  late PageController _pageController;
  int _selectedStatus = AssetStatus.hidden;
  bool _initializedDefaultTab = false;
  bool _hadAnyArchived = false;
  int? _targetPage;
  final Set<int> _restoringIds = <int>{};

  static int _pageForStatus(int status) =>
      status == AssetStatus.settled ? 1 : 0;

  static int _statusForPage(int page) =>
      page == 1 ? AssetStatus.settled : AssetStatus.hidden;

  @override
  void initState() {
    super.initState();
    final initialList = ref.read(bookAssetsProvider).value;
    if (initialList != null) {
      final hiddenCount = initialList
          .where((a) => a.status == AssetStatus.hidden)
          .length;
      final settledCount = initialList
          .where((a) => a.status == AssetStatus.settled)
          .length;
      _selectedStatus = (hiddenCount == 0 && settledCount > 0)
          ? AssetStatus.settled
          : AssetStatus.hidden;
      _initializedDefaultTab = true;
      _hadAnyArchived = (hiddenCount + settledCount) > 0;
    }
    _pageController = PageController(
      initialPage: _pageForStatus(_selectedStatus),
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _selectTab(int nextStatus) {
    if (_selectedStatus == nextStatus) return;
    final targetPage = _pageForStatus(nextStatus);
    setState(() => _selectedStatus = nextStatus);
    if (_pageController.hasClients &&
        _pageController.page?.round() != targetPage) {
      _targetPage = targetPage;
      unawaited(
        _pageController
            .animateToPage(
              targetPage,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
            )
            .whenComplete(() {
              if (_targetPage == targetPage) _targetPage = null;
            }),
      );
    }
  }

  void _onPageChanged(int page) {
    if (_targetPage != null && page != _targetPage) return;
    _targetPage = null;
    final nextStatus = _statusForPage(page);
    if (_selectedStatus != nextStatus) {
      setState(() => _selectedStatus = nextStatus);
    }
  }

  Future<void> _restoreAsset(Asset asset) async {
    if (_restoringIds.contains(asset.id)) return;
    setState(() => _restoringIds.add(asset.id));
    try {
      if (asset.type == AssetType.debt && asset.status == AssetStatus.settled) {
        final debtService = await ref.read(debtServiceProvider.future);
        await debtService.reopenDebt(commandId: _uuid.v4(), debtId: asset.id);
      } else {
        final ledgerService = await ref.read(ledgerServiceProvider.future);
        await ledgerService.setAssetStatus(
          commandId: _uuid.v4(),
          assetId: asset.id,
          status: AssetStatus.active,
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(safeMessage(e))));
    } finally {
      if (mounted) {
        setState(() => _restoringIds.remove(asset.id));
      }
    }
  }

  Future<void> _openDetail(Asset asset) {
    if (asset.type == AssetType.debt) {
      return pushDesktopModalOrMaterialRoute<void>(
        context,
        maxWidth: 680,
        maxHeight: 740,
        child: DebtDetailPage(debtId: asset.id),
      );
    }
    return pushDesktopModalOrMaterialRoute<void>(
      context,
      maxWidth: 680,
      maxHeight: 740,
      child: AssetDetailPage(assetId: asset.id),
    );
  }

  @override
  Widget build(BuildContext context) {
    final assetsAsync = ref.watch(bookAssetsProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Material(
      key: const Key('archived-assets-sheet'),
      color: widget.isDesktopDialog ? scheme.surface : Colors.transparent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              widget.isDesktopDialog ? 12 : 0,
              widget.isDesktopDialog ? 8 : 16,
              8,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '已归档账户',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (widget.isDesktopDialog) const CloseButton(),
              ],
            ),
          ),
          Expanded(
            child: asyncBody(assetsAsync, (list) {
              final archived = list
                  .where((a) => a.status != AssetStatus.active)
                  .toList();
              final hiddenAssets = archived
                  .where((a) => a.status != AssetStatus.settled)
                  .toList();
              final settledAssets = archived
                  .where((a) => a.status == AssetStatus.settled)
                  .toList();

              if (!_initializedDefaultTab) {
                _initializedDefaultTab = true;
                if (hiddenAssets.isEmpty && settledAssets.isNotEmpty) {
                  _selectedStatus = AssetStatus.settled;
                  final wantPage = _pageForStatus(_selectedStatus);
                  if (!_pageController.hasClients &&
                      _pageController.initialPage != wantPage) {
                    _pageController.dispose();
                    _pageController = PageController(initialPage: wantPage);
                  } else if (_pageController.hasClients) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted && _pageController.hasClients) {
                        _pageController.jumpToPage(wantPage);
                      }
                    });
                  }
                }
              }

              if (archived.isNotEmpty) {
                _hadAnyArchived = true;
              } else if (_hadAnyArchived) {
                _hadAnyArchived = false;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) Navigator.of(context).maybePop();
                });
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<int>(
                        key: const Key('archived-assets-tabs'),
                        showSelectedIcon: false,
                        style: const ButtonStyle(
                          visualDensity: VisualDensity.compact,
                          padding: WidgetStatePropertyAll(
                            EdgeInsets.symmetric(horizontal: 10),
                          ),
                        ),
                        segments: [
                          ButtonSegment<int>(
                            value: AssetStatus.hidden,
                            label: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                '已隐藏 (${hiddenAssets.length})',
                                key: const Key('archived-tab-hidden'),
                                maxLines: 1,
                                softWrap: false,
                              ),
                            ),
                          ),
                          ButtonSegment<int>(
                            value: AssetStatus.settled,
                            label: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                '已结清 (${settledAssets.length})',
                                key: const Key('archived-tab-settled'),
                                maxLines: 1,
                                softWrap: false,
                              ),
                            ),
                          ),
                        ],
                        selected: {_selectedStatus},
                        onSelectionChanged: (s) => _selectTab(s.first),
                      ),
                    ),
                  ),
                  Expanded(
                    child: PageView(
                      key: const Key('archived-assets-page-view'),
                      controller: _pageController,
                      onPageChanged: _onPageChanged,
                      children: [
                        _ArchivedTabList(
                          items: hiddenAssets,
                          emptyText: '暂无已隐藏账户',
                          hiddenAmounts: widget.hiddenAmounts,
                          restoringIds: _restoringIds,
                          onTapItem: _openDetail,
                          onRestore: _restoreAsset,
                        ),
                        _ArchivedTabList(
                          items: settledAssets,
                          emptyText: '暂无已结清账户',
                          hiddenAmounts: widget.hiddenAmounts,
                          restoringIds: _restoringIds,
                          onTapItem: _openDetail,
                          onRestore: _restoreAsset,
                        ),
                      ],
                    ),
                  ),
                ],
              );
            }),
          ),
        ],
      ),
    );
  }
}

class _ArchivedTabList extends StatelessWidget {
  const _ArchivedTabList({
    required this.items,
    required this.emptyText,
    required this.hiddenAmounts,
    required this.restoringIds,
    required this.onTapItem,
    required this.onRestore,
  });

  final List<Asset> items;
  final String emptyText;
  final bool hiddenAmounts;
  final Set<int> restoringIds;
  final ValueChanged<Asset> onTapItem;
  final ValueChanged<Asset> onRestore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (items.isEmpty) {
      return Center(
        child: TallyEmptyState(icon: Icons.archive_outlined, title: emptyText),
      );
    }

    final scheme = theme.colorScheme;
    final cardColor = theme.brightness == Brightness.dark
        ? scheme.surfaceContainerLow
        : Color.lerp(
            scheme.surfaceContainerLow,
            scheme.surfaceContainer,
            0.55,
          )!;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
      children: [
        Card(
          margin: EdgeInsets.zero,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          color: cardColor,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final a in items)
                  _ArchivedAssetRow(
                    asset: a,
                    hiddenAmounts: hiddenAmounts,
                    restoring: restoringIds.contains(a.id),
                    onTap: () => onTapItem(a),
                    onRestore: () => onRestore(a),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ArchivedAssetRow extends StatelessWidget {
  const _ArchivedAssetRow({
    required this.asset,
    required this.hiddenAmounts,
    required this.restoring,
    required this.onTap,
    required this.onRestore,
  });

  final Asset asset;
  final bool hiddenAmounts;
  final bool restoring;
  final VoidCallback onTap;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDebt = asset.type == AssetType.debt;
    final isCredit = asset.type == AssetType.credit;

    final typeLabel = isDebt
        ? (asset.subType == AssetType.debtLend ? '借出' : '借入')
        : (isCredit ? '信用账户' : '资金账户');
    final subtitleParts = <String>[
      typeLabel,
      if (asset.currency != null && asset.currency!.isNotEmpty) asset.currency!,
    ];

    final String balanceText;
    if (hiddenAmounts) {
      balanceText = '***';
    } else if (isDebt) {
      final displayMinor =
          asset.status == AssetStatus.settled ||
              asset.balanceMinor < BigInt.zero
          ? BigInt.zero
          : asset.balanceMinor;
      balanceText = formatMinor(displayMinor);
    } else if (isCredit) {
      balanceText = creditBalanceLabel(asset.balanceMinor);
    } else {
      balanceText = formatMinor(asset.balanceMinor);
    }

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: Key('archived-asset-${asset.id}'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              AssetIconAvatar(
                iconKey: asset.icon,
                colorHex: asset.color,
                name: asset.name,
                assetType: asset.type,
                subType: asset.subType,
                size: 38,
              ),
              const SizedBox(width: 10),
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
                        fontWeight: FontWeight.w500,
                      ),
                    ),
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
                ),
              ),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 104),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(
                    balanceText,
                    maxLines: 1,
                    softWrap: false,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TallySoftButton(
                key: Key('restore-archived-asset-${asset.id}'),
                compact: true,
                minimumSize: const Size(52, 32),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                onPressed: restoring ? null : onRestore,
                child: const Text('恢复', maxLines: 1, softWrap: false),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
