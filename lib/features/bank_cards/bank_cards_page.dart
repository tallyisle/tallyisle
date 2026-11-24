import 'dart:async' show unawaited;
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/adaptive.dart';
import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/template_card_rules.dart';
import '../common/catalog_icons.dart';
import '../common/common.dart';
import '../common/desktop_modal_page.dart';
import 'bank_card_editor_page.dart';
import 'bank_card_providers.dart';

/// Bank Card Memo Folder page (`F-023`, original `/bkp/BCBAct`).
class BankCardsPage extends ConsumerStatefulWidget {
  const BankCardsPage({super.key});

  @override
  ConsumerState<BankCardsPage> createState() => _BankCardsPageState();
}

class _BankCardsPageState extends ConsumerState<BankCardsPage> {
  static const List<int?> _tabFilterTypes = <int?>[
    null,
    BankCardType.debit,
    BankCardType.credit,
  ];

  final CommandIds _deleteIds = CommandIds();
  final CommandIds _reorderIds = CommandIds();
  late final PageController _pageController;
  List<int>? _optimisticAllCardIds;
  int _reorderSeq = 0;
  int _programmaticTurnDepth = 0;
  bool _updatingFromSwipe = false;
  bool _busy = false;

  static int _pageIndexForFilter(int? filterType) => switch (filterType) {
    BankCardType.debit => 1,
    BankCardType.credit => 2,
    _ => 0,
  };

  @override
  void initState() {
    super.initState();
    _pageController = PageController(
      initialPage: _pageIndexForFilter(ref.read(bankCardFilterProvider)),
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _syncPageToFilter(int? filterType) async {
    if (!mounted || !_pageController.hasClients) return;
    final targetPage = _pageIndexForFilter(filterType);
    final currentPage = _pageController.page;
    if (currentPage != null && (currentPage - targetPage).abs() < 0.01) {
      return;
    }
    _programmaticTurnDepth++;
    try {
      await _pageController.animateToPage(
        targetPage,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    } on Object {
      // PageController may detach if widget disposes mid-animation.
    } finally {
      _programmaticTurnDepth--;
    }
  }

  List<BankCard> _applyOptimisticCards(List<BankCard> rawCards) {
    final optimisticIds = _optimisticAllCardIds;
    if (optimisticIds == null || optimisticIds.length != rawCards.length) {
      return rawCards;
    }
    final byId = <int, BankCard>{for (final c in rawCards) c.id: c};
    final ordered = <BankCard>[];
    for (final id in optimisticIds) {
      final match = byId[id];
      if (match == null) return rawCards;
      ordered.add(match);
    }
    return ordered;
  }

  static List<int> _permuteSubsetSlots({
    required List<int> fullIds,
    required List<int> reorderedSubsetIds,
  }) {
    final subsetSet = reorderedSubsetIds.toSet();
    var cursor = 0;
    return <int>[
      for (final id in fullIds)
        if (subsetSet.contains(id)) reorderedSubsetIds[cursor++] else id,
    ];
  }

  Future<void> _reorderVisibleCards({
    required List<BankCard> allCards,
    required List<BankCard> visibleRows,
    required int oldIndex,
    required int newIndex,
  }) async {
    if (_busy || oldIndex == newIndex) return;
    final nextVisible = List<BankCard>.from(visibleRows);
    final moved = nextVisible.removeAt(oldIndex);
    nextVisible.insert(newIndex, moved);

    final mergedIds = _permuteSubsetSlots(
      fullIds: allCards.map((c) => c.id).toList(),
      reorderedSubsetIds: nextVisible.map((c) => c.id).toList(),
    );

    setState(() {
      _optimisticAllCardIds = mergedIds;
    });

    try {
      final svc = await ref.read(bankCardServiceProvider.future);
      await svc.reorderBankCards(
        commandId: _reorderIds.forPayload(<Object?>[
          'reorder-card',
          _reorderSeq++,
          mergedIds,
        ]),
        orderedIds: mergedIds,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _optimisticAllCardIds = null;
      });
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

  Widget _buildReorderProxy(
    Widget child,
    int index,
    Animation<double> animation,
  ) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(animation.value);
        final scheme = Theme.of(context).colorScheme;
        return Material(
          elevation: 6 * t,
          color: Colors.transparent,
          shadowColor: scheme.shadow.withValues(alpha: 0.28),
          borderRadius: BorderRadius.circular(14),
          child: child,
        );
      },
      child: child,
    );
  }

  Future<void> _openCreate() async {
    await pushDesktopModalOrMaterialRoute<int>(
      context,
      child: const BankCardEditorPage(),
    );
  }

  Future<void> _openEdit(BankCard card) async {
    await pushDesktopModalOrMaterialRoute<int>(
      context,
      child: BankCardEditorPage(cardId: card.id),
    );
  }

  Future<void> _copyCardNumber(BankCard card) async {
    await Clipboard.setData(ClipboardData(text: card.cardNo));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(const SnackBar(content: Text('已复制卡号')));
  }

  Future<void> _copyFullInfo(BankCard card, String? linkedAssetName) async {
    final fullText = formatBankCardFullInfo(
      cardName: card.cardName,
      cardType: card.cardType,
      cardNo: card.cardNo,
      cardOwner: card.cardOwner,
      remark: card.remark,
      linkedAssetName: linkedAssetName,
    );
    await Clipboard.setData(ClipboardData(text: fullText));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(const SnackBar(content: Text('已复制完整卡片信息')));
  }

  Future<void> _deleteCard(BankCard card) async {
    final ok = await confirm(
      context,
      title: '确认删除银行卡备忘？',
      message: '删除“${card.cardName}”不会影响已关联的资金账户与账单。',
      ok: '删除',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      final svc = await ref.read(bankCardServiceProvider.future);
      await svc.deleteBankCard(
        commandId: _deleteIds.forPayload(<Object?>['del-card', card.id]),
        cardId: card.id,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(content: Text('已删除银行卡备忘')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(safeMessage(e))));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final filterType = ref.watch(bankCardFilterProvider);
    ref.listen<int?>(bankCardFilterProvider, (prev, next) {
      if (_updatingFromSwipe) return;
      unawaited(_syncPageToFilter(next));
    });

    final maskState = ref.watch(bankCardMaskProvider);
    final allCardsAsync = ref.watch(bankCardsProvider(null));
    ref.listen<AsyncValue<List<BankCard>>>(bankCardsProvider(null), (_, next) {
      final rows = next.value;
      final optimistic = _optimisticAllCardIds;
      if (rows == null || optimistic == null) return;
      final dbIds = rows.map((c) => c.id).toList();
      if (dbIds.length != optimistic.length || listEquals(dbIds, optimistic)) {
        if (mounted) {
          setState(() => _optimisticAllCardIds = null);
        }
      }
    });

    final assets = ref.watch(assetsProvider).value ?? const <Asset>[];
    final assetMap = <int, Asset>{for (final a in assets) a.id: a};

    final isDesktop = DesktopAdaptive.isDesktop(context);
    final isPopupModal = isDesktop && ModalRoute.of(context) is PopupRoute;
    final activePageIndex = _pageIndexForFilter(filterType);

    return DesktopModalEscapeScope(
      enabled: isPopupModal,
      child: Scaffold(
        key: const Key('bank_cards_page'),
        appBar: AppBar(
          leading: isPopupModal ? const CloseButton() : null,
          scrolledUnderElevation: isDesktop ? 0 : null,
          title: const Text('银行卡备忘'),
          actions: [
            IconButton(
              key: const Key('toggle_global_card_mask'),
              tooltip: maskState.maskByDefault ? '显示全部卡号' : '隐藏全部卡号',
              icon: Icon(
                maskState.maskByDefault
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
              ),
              onPressed: () =>
                  ref.read(bankCardMaskProvider.notifier).toggleGlobal(),
            ),
            if (isDesktop) ...[
              const SizedBox(width: 8),
              FilledButton.icon(
                key: const Key('add_bank_card_fab'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                ),
                onPressed: _openCreate,
                icon: const Icon(Icons.add_card, size: 18),
                label: const Text('添加银行卡'),
              ),
              const SizedBox(width: 12),
            ],
          ],
        ),
        floatingActionButton: isDesktop
            ? null
            : FloatingActionButton.extended(
                key: const Key('add_bank_card_fab'),
                heroTag: 'fab-bank-cards',
                onPressed: _openCreate,
                icon: const Icon(Icons.add_card),
                label: const Text('添加银行卡'),
              ),
        body: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: isDesktop ? 800 : 720),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<int?>(
                      key: const Key('bank_card_filter_tabs'),
                      showSelectedIcon: false,
                      style: isDesktop
                          ? null
                          : const ButtonStyle(
                              visualDensity: VisualDensity.compact,
                              padding: WidgetStatePropertyAll(
                                EdgeInsets.symmetric(horizontal: 10),
                              ),
                            ),
                      segments: [
                        for (final (value, label) in const <(int?, String)>[
                          (null, '全部'),
                          (BankCardType.debit, '储蓄卡'),
                          (BankCardType.credit, '信用卡'),
                        ])
                          ButtonSegment<int?>(
                            value: value,
                            label: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                label,
                                key: Key('card_filter_${value ?? "all"}'),
                                maxLines: 1,
                                softWrap: false,
                              ),
                            ),
                          ),
                      ],
                      selected: {filterType},
                      onSelectionChanged: (selection) => ref
                          .read(bankCardFilterProvider.notifier)
                          .select(selection.first),
                    ),
                  ),
                ),
                Expanded(
                  child: asyncBody(allCardsAsync, (rawAll) {
                    final allCards = _applyOptimisticCards(rawAll);
                    return ScrollConfiguration(
                      behavior: ScrollConfiguration.of(context).copyWith(
                        dragDevices: const <PointerDeviceKind>{
                          PointerDeviceKind.touch,
                          PointerDeviceKind.mouse,
                          PointerDeviceKind.trackpad,
                          PointerDeviceKind.stylus,
                        },
                      ),
                      child: PageView.builder(
                        key: const Key('bank_cards_page_view'),
                        controller: _pageController,
                        itemCount: _tabFilterTypes.length,
                        onPageChanged: (page) {
                          if (_programmaticTurnDepth > 0) return;
                          final nextFilter = _tabFilterTypes[page];
                          if (ref.read(bankCardFilterProvider) != nextFilter) {
                            _updatingFromSwipe = true;
                            try {
                              ref
                                  .read(bankCardFilterProvider.notifier)
                                  .select(nextFilter);
                            } finally {
                              _updatingFromSwipe = false;
                            }
                          }
                        },
                        itemBuilder: (context, pageIndex) {
                          final pageFilter = _tabFilterTypes[pageIndex];
                          final isActivePage = pageIndex == activePageIndex;
                          final rows = pageFilter == null
                              ? allCards
                              : allCards
                                    .where((c) => c.cardType == pageFilter)
                                    .toList();

                          if (rows.isEmpty) {
                            return Center(
                              key: isActivePage
                                  ? const Key('bank_cards_empty_state')
                                  : ValueKey(
                                      'bank_cards_empty_state_page_$pageIndex',
                                    ),
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Text(
                                  isDesktop
                                      ? '暂无银行卡备忘，点击右上角“添加银行卡”保存常用卡号'
                                      : '暂无银行卡备忘，点击右下角“添加银行卡”保存常用卡号',
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ),
                            );
                          }

                          return ReorderableListView.builder(
                            key: ValueKey(
                              'bank_cards_reorder_page_${pageFilter ?? "all"}',
                            ),
                            buildDefaultDragHandles: false,
                            padding: EdgeInsets.fromLTRB(
                              16,
                              4,
                              16,
                              isDesktop ? 24 : 88,
                            ),
                            itemCount: rows.length,
                            onReorderStart: (_) {
                              if (!isDesktop) {
                                HapticFeedback.selectionClick();
                              }
                            },
                            proxyDecorator: _buildReorderProxy,
                            onReorderItem: (oldIndex, newIndex) =>
                                _reorderVisibleCards(
                                  allCards: allCards,
                                  visibleRows: rows,
                                  oldIndex: oldIndex,
                                  newIndex: newIndex,
                                ),
                            itemBuilder: (context, index) {
                              final card = rows[index];
                              final linkedAsset = card.cardAssetId == noRef
                                  ? null
                                  : assetMap[card.cardAssetId];
                              final masked = maskState.isCardMasked(card.id);
                              final dragHandle = isDesktop
                                  ? ReorderableDragStartListener(
                                      index: index,
                                      enabled: !_busy,
                                      child: MouseRegion(
                                        cursor: _busy
                                            ? SystemMouseCursors.basic
                                            : SystemMouseCursors.grab,
                                        child: Padding(
                                          key: isActivePage
                                              ? Key(
                                                  'bank-card-drag-handle-${card.id}',
                                                )
                                              : ValueKey(
                                                  'bank-card-drag-handle-p$pageIndex-${card.id}',
                                                ),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 2,
                                            vertical: 2,
                                          ),
                                          child: Icon(
                                            Icons.drag_handle_rounded,
                                            size: 20,
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.outline,
                                          ),
                                        ),
                                      ),
                                    )
                                  : null;

                              final cardWidget = Padding(
                                padding: EdgeInsets.only(
                                  bottom: index == rows.length - 1 ? 0 : 10,
                                ),
                                child: _BankCardTile(
                                  card: card,
                                  masked: masked,
                                  linkedAssetName: linkedAsset?.name,
                                  busy: _busy,
                                  isActivePage: isActivePage,
                                  pageIndex: pageIndex,
                                  dragHandle: dragHandle,
                                  onToggleMask: () => ref
                                      .read(bankCardMaskProvider.notifier)
                                      .toggleCard(card.id),
                                  onCopyNumber: () => _copyCardNumber(card),
                                  onCopyFull: () =>
                                      _copyFullInfo(card, linkedAsset?.name),
                                  onEdit: () => _openEdit(card),
                                  onDelete: () => _deleteCard(card),
                                ),
                              );

                              if (isDesktop) {
                                return KeyedSubtree(
                                  key: ValueKey(
                                    'card-reorder-item-p$pageIndex-${card.id}',
                                  ),
                                  child: cardWidget,
                                );
                              }
                              return ReorderableDelayedDragStartListener(
                                key: ValueKey(
                                  'card-reorder-item-p$pageIndex-${card.id}',
                                ),
                                index: index,
                                enabled: !_busy,
                                child: cardWidget,
                              );
                            },
                          );
                        },
                      ),
                    );
                  }),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BankCardTile extends StatelessWidget {
  const _BankCardTile({
    required this.card,
    required this.masked,
    required this.linkedAssetName,
    required this.busy,
    this.isActivePage = true,
    this.pageIndex = 0,
    this.dragHandle,
    required this.onToggleMask,
    required this.onCopyNumber,
    required this.onCopyFull,
    required this.onEdit,
    required this.onDelete,
  });

  final BankCard card;
  final bool masked;
  final String? linkedAssetName;
  final bool busy;
  final bool isActivePage;
  final int pageIndex;
  final Widget? dragHandle;
  final VoidCallback onToggleMask;
  final VoidCallback onCopyNumber;
  final VoidCallback onCopyFull;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  Key _scopedKey(String name) =>
      isActivePage ? Key(name) : ValueKey('p${pageIndex}_$name');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final tint = parseCardColorOrNull(card.cardColor);
    final luhn = inspectCardLuhn(card.cardNo);
    final luhnBgColor = luhn.passesLuhn
        ? (isDark
              ? Colors.green.shade900.withValues(alpha: 0.45)
              : Colors.green.withValues(alpha: 0.14))
        : theme.colorScheme.surfaceContainerHighest;
    final luhnFgColor = luhn.passesLuhn
        ? (isDark ? Colors.green.shade300 : Colors.green.shade700)
        : theme.colorScheme.onSurfaceVariant;
    final displayNumber = masked
        ? formatCardNumberMasked(card.cardNo)
        : formatCardNumberGrouped(card.cardNo);

    return Card(
      key: _scopedKey('bank_card_item_${card.id}'),
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: tint == null
            ? null
            : BoxDecoration(
                border: Border(left: BorderSide(color: tint, width: 6)),
              ),
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: double.infinity,
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 6,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (dragHandle != null) ...[
                        dragHandle!,
                        const SizedBox(width: 6),
                      ],
                      BankCardIconAvatar(
                        key: _scopedKey('bank_card_avatar_${card.id}'),
                        cardColorMeta: card.cardColor,
                        cardName: card.cardName,
                        cardType: card.cardType,
                        size: 30,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          card.cardName,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Chip(
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        label: Text(BankCardType.labelOf(card.cardType)),
                      ),
                      Container(
                        key: _scopedKey('card_luhn_badge_${card.id}'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: luhnBgColor,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          luhn.passesLuhn ? 'Luhn 校验通过' : '非标准校验号',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: luhnFgColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: DesktopAdaptive.isDesktop(context)
                      ? SelectableText(
                          displayNumber,
                          key: _scopedKey('card_no_display_${card.id}'),
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                letterSpacing: 1.2,
                                fontFeatures: const <FontFeature>[
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                        )
                      : Text(
                          displayNumber,
                          key: _scopedKey('card_no_display_${card.id}'),
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                letterSpacing: 1.2,
                                fontFeatures: const <FontFeature>[
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                        ),
                ),
                IconButton(
                  key: _scopedKey('toggle_card_mask_${card.id}'),
                  tooltip: masked ? '显示完整卡号' : '隐藏卡号',
                  icon: Icon(
                    masked
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  onPressed: onToggleMask,
                ),
              ],
            ),
            if (card.cardOwner.trim().isNotEmpty ||
                linkedAssetName != null ||
                card.remark.trim().isNotEmpty) ...[
              const SizedBox(height: 4),
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  if (card.cardOwner.trim().isNotEmpty)
                    Text(
                      '持卡人：${card.cardOwner.trim()}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  if (linkedAssetName != null)
                    Text(
                      '关联账户：$linkedAssetName',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  if (card.remark.trim().isNotEmpty)
                    Text(
                      '备注：${card.remark.trim()}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
            ],
            const Divider(height: 16),
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: TextButton.icon(
                          key: _scopedKey('copy_card_no_${card.id}'),
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: onCopyNumber,
                          icon: const Icon(Icons.copy, size: 15),
                          label: const FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text('复制卡号', maxLines: 1, softWrap: false),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: TextButton.icon(
                          key: _scopedKey('copy_card_full_${card.id}'),
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: onCopyFull,
                          icon: const Icon(Icons.assignment_outlined, size: 15),
                          label: const FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text('复制完整信息', maxLines: 1, softWrap: false),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: _scopedKey('edit_bank_card_${card.id}'),
                  visualDensity: VisualDensity.compact,
                  tooltip: '编辑',
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  onPressed: busy ? null : onEdit,
                ),
                IconButton(
                  key: _scopedKey('delete_bank_card_${card.id}'),
                  visualDensity: VisualDensity.compact,
                  tooltip: '删除',
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: busy ? null : onDelete,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
