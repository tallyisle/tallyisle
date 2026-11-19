import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/adaptive.dart';
import '../../app/desktop_shell.dart'
    show DesktopNavigationScaffold, PeriodSwipeRegion, topmostRouterLocation;
import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/app_settings_rules.dart';
import '../../domain/rules/asset_overview.dart';
import '../../domain/rules/income_expense.dart';
import '../books/book_switcher_modal.dart';
import '../backup/mobile_sync_backup_quick_sheet.dart';
import '../budget/budget_providers.dart'
    show budgetOffsetProvider, budgetOverviewForOffsetProvider;
import '../budget/budget_widgets.dart';
import '../common/catalog_icons.dart';
import '../common/common.dart';
import '../receipt/record_receipt_dialog.dart' show showRecordReceiptDialog;
import '../records/record_detail_page.dart'
    show RecordDetailPage, isGeneratedTransferFeeRecord, isRecordEditable;
import '../records/record_labels.dart';

bool _isHomeTopmostActive(BuildContext context) {
  if (!TickerMode.valuesOf(context).enabled) return false;
  BuildContext? cursor = context;
  while (cursor != null) {
    final route = ModalRoute.of(cursor);
    if (route != null && !route.isCurrent) {
      return false;
    }
    final nav = Navigator.maybeOf(cursor);
    if (nav == null) break;
    final nextContext = nav.context;
    final parentNav = Navigator.maybeOf(nextContext);
    if (identical(parentNav, nav)) break;
    cursor = nextContext;
  }
  final router = GoRouter.maybeOf(context);
  if (router != null) {
    final path = topmostRouterLocation(router);
    if (path != '/') return false;
  }
  return true;
}

String _buildDuplicateRecordRoute(LedgerRecord r) {
  const supportedTypes = <int>{
    RecordType.expense,
    RecordType.income,
    RecordType.transfer,
    RecordType.reimbursable,
    RecordType.advanceIncome,
    RecordType.advanceExpense,
  };
  final targetType = supportedTypes.contains(r.type)
      ? r.type
      : (r.subType == RecordDirection.income
            ? RecordType.income
            : RecordType.expense);
  final query = <String, String>{
    'type': '$targetType',
    if (r.moneyMinor != BigInt.zero) 'amount': formatMinor(r.moneyMinor.abs()),
    if (r.remark.trim().isNotEmpty) 'remark': r.remark.trim(),
  };
  if (targetType == RecordType.transfer) {
    if (r.fromAssetId > 0) query['from'] = '${r.fromAssetId}';
    if (r.toAssetId > 0) query['to'] = '${r.toAssetId}';
  } else {
    if (r.recordCatId > 0) query['cat'] = '${r.recordCatId}';
    final effectiveAsset = targetType == RecordType.reimbursable
        ? r.fromAssetId
        : (r.assetId > 0 ? r.assetId : r.fromAssetId);
    if (effectiveAsset > 0) {
      query['asset'] = '$effectiveAsset';
      query['assetId'] = '$effectiveAsset';
    }
  }
  return Uri(path: '/record/new', queryParameters: query).toString();
}

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  final _deleteCommandIds = CommandIds();
  final _homeFocusNode = FocusNode(debugLabel: 'HomeDesktopFocus');
  bool _pickingBook = false;
  String? _selectedRecordId;
  int? _lastBookId;
  int? _lastPeriodOffset;

  @override
  void dispose() {
    _homeFocusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleFocusKeyEvent(FocusNode node, KeyEvent event) {
    if (!mounted) return KeyEventResult.ignored;
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    if (_selectedRecordId == null) return KeyEventResult.ignored;
    if (!DesktopAdaptive.isExpandedDesktop(context)) {
      return KeyEventResult.ignored;
    }

    final hw = HardwareKeyboard.instance;
    if (hw.isControlPressed ||
        hw.isAltPressed ||
        hw.isMetaPressed ||
        hw.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    if (!_isHomeTopmostActive(context)) {
      return KeyEventResult.ignored;
    }
    setState(() => _selectedRecordId = null);
    return KeyEventResult.handled;
  }

  void _handleOpenRecordDetail(String recordId) {
    if (DesktopAdaptive.isExpandedDesktop(context)) {
      setState(() => _selectedRecordId = recordId);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _selectedRecordId == null) return;
        if (!_homeFocusNode.hasFocus && _isHomeTopmostActive(context)) {
          _homeFocusNode.requestFocus();
        }
      });
    } else {
      context.push('/record/$recordId');
    }
  }

  Future<void> _handleDeleteRecordFromMenu(LedgerRecord r) async {
    if (isGeneratedTransferFeeRecord(r)) return;
    final ok = await confirm(
      context,
      title: '删除这笔账单？',
      message: r.type == RecordType.transfer
          ? '转账及其手续费会一并删除，账户余额会恢复。'
          : '删除后账户余额会恢复。',
      ok: '删除',
    );
    if (!ok || !mounted) return;
    try {
      final service = await ref.read(ledgerServiceProvider.future);
      await service.deleteRecord(
        commandId: _deleteCommandIds.forPayload(['home-delete', r.recordId]),
        recordId: r.recordId,
      );
      if (mounted && _selectedRecordId == r.recordId) {
        setState(() => _selectedRecordId = null);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(safeMessage(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final book = ref.watch(currentBookProvider);
    final bookId = book.value?.id;
    if (_lastBookId != null && bookId != null && _lastBookId != bookId) {
      _selectedRecordId = null;
    }
    if (bookId != null) {
      _lastBookId = bookId;
    }

    final currentPeriodOffset = ref.watch(periodOffsetProvider);
    if (_lastPeriodOffset != null && _lastPeriodOffset != currentPeriodOffset) {
      _selectedRecordId = null;
    }
    _lastPeriodOffset = currentPeriodOffset;

    final periodRecords = ref.watch(periodRecordsProvider);
    if (_selectedRecordId != null &&
        periodRecords is AsyncData<List<LedgerRecord>> &&
        !periodRecords.value.any((r) => r.recordId == _selectedRecordId)) {
      _selectedRecordId = null;
    }

    final isDesktop = DesktopAdaptive.isDesktop(context);
    final isExpandedDesktop = DesktopAdaptive.isExpandedDesktop(context);

    Widget body;
    if (!isDesktop) {
      body = const _HomeBody();
    } else {
      final selectedId = isExpandedDesktop ? _selectedRecordId : null;
      final masterPane = _DesktopHomeBody(
        isExpandedDesktop: isExpandedDesktop,
        selectedRecordId: selectedId,
        onOpenRecordDetail: _handleOpenRecordDetail,
        onDeleteRecord: _handleDeleteRecordFromMenu,
      );
      final scheme = Theme.of(context).colorScheme;
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: masterPane),
          if (selectedId != null) ...[
            VerticalDivider(
              width: 1,
              thickness: 1,
              color: scheme.outlineVariant.withValues(alpha: 0.45),
            ),
            SizedBox(
              key: const Key('home-record-detail-pane'),
              width: 392,
              child: HeroMode(
                enabled: false,
                child: RecordDetailPage(
                  key: ValueKey('pane-record-$selectedId'),
                  recordId: selectedId,
                  embeddedInPane: true,
                  onClosePane: () => setState(() => _selectedRecordId = null),
                  onSelectRelatedRecord: (id) =>
                      setState(() => _selectedRecordId = id),
                ),
              ),
            ),
          ],
        ],
      );
    }

    final hasExpandedSidebar =
        isExpandedDesktop &&
        context.findAncestorWidgetOfExactType<DesktopNavigationScaffold>() !=
            null;

    final scaffold = Scaffold(
      appBar: hasExpandedSidebar
          ? AppBar(title: const Text('账单明细'))
          : AppBar(
              title: InkWell(
                key: const Key('book-picker'),
                borderRadius: BorderRadius.circular(8),
                onTap: _pickBook,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 2,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          book.value?.name ?? '帐屿',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const Icon(Icons.arrow_drop_down),
                    ],
                  ),
                ),
              ),
              actions: [
                if (!isDesktop)
                  IconButton(
                    key: const Key('home-sync-backup-button'),
                    tooltip: '同步与备份',
                    icon: const Icon(Icons.cloud_sync_outlined),
                    onPressed: () => showMobileSyncBackupQuickSheet(context),
                  ),
                IconButton(
                  key: const Key('home-calendar-button'),
                  tooltip: '日历',
                  icon: const Icon(Icons.calendar_month),
                  onPressed: () => context.push('/calendar'),
                ),
                IconButton(
                  key: const Key('home-search-button'),
                  tooltip: '搜索',
                  icon: const Icon(Icons.search),
                  onPressed: () => context.push('/search'),
                ),
              ],
            ),
      body: body,
    );

    if (!isDesktop) {
      return scaffold;
    }
    return Focus(
      focusNode: _homeFocusNode,
      autofocus: isExpandedDesktop && _selectedRecordId != null,
      onKeyEvent: _handleFocusKeyEvent,
      child: scaffold,
    );
  }

  Future<void> _pickBook() async {
    if (_pickingBook) return;
    _pickingBook = true;
    try {
      await showBookSwitcher(context, ref);
    } finally {
      _pickingBook = false;
    }
  }
}

class _HomeResetPeriodPill extends StatelessWidget {
  const _HomeResetPeriodPill({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.secondaryContainer,
      borderRadius: BorderRadius.circular(999),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: const Key('home-reset-period-btn'),
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Text(
            '回本月',
            maxLines: 1,
            softWrap: false,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSecondaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

class _HomeBody extends ConsumerWidget {
  const _HomeBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final period = ref.watch(currentPeriodProvider);
    final summary = ref.watch(periodSummaryProvider);
    final records = ref.watch(periodRecordsProvider);
    final bookId = ref.watch(currentBookIdProvider).value;
    final categories = bookId == null
        ? const <RecordCategory>[]
        : ref.watch(categoriesProvider(bookId)).value ?? const [];
    final assets = ref.watch(assetsProvider).value ?? const <Asset>[];
    final settings =
        ref.watch(appSettingsProvider).value ?? AppSettings.defaults;
    final assetOverview = ref.watch(assetOverviewProvider).value;
    final periodOffset = ref.watch(periodOffsetProvider);
    final offset = ref.read(periodOffsetProvider.notifier);

    final periodTitle = period.value == null
        ? ''
        : '${period.value!.year}年${period.value!.month}月';

    return PeriodSwipeRegion(
      onPrevious: offset.previous,
      onNext: offset.next,
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(
                children: [
                  IconButton(
                    tooltip: '上一期',
                    onPressed: offset.previous,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Expanded(
                    child: Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: InkWell(
                              borderRadius: BorderRadius.circular(6),
                              onTap: periodOffset != 0 ? offset.reset : null,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 2,
                                ),
                                child: Text(
                                  periodTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                              ),
                            ),
                          ),
                          if (periodOffset != 0) ...[
                            const SizedBox(width: 6),
                            _HomeResetPeriodPill(onTap: offset.reset),
                          ],
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '下一期',
                    onPressed: offset.next,
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
            ),
          ),
          if (settings.showHomeAssetSummaryBanner)
            SliverToBoxAdapter(
              child: _HomeAssetSummaryBanner(
                overview: assetOverview,
                onTap: () => context.go('/assets'),
              ),
            ),
          SliverToBoxAdapter(
            child: _SummaryCard(summary.value ?? IncomeExpense.zero),
          ),
          if (settings.showHomeBudgetCard && periodOffset == 0)
            SliverToBoxAdapter(
              child: BudgetSummaryCard(
                fixedOffset: 0,
                hideWhenEmpty: true,
                onTap: () {
                  ref.read(budgetOffsetProvider.notifier).reset();
                  context.push('/budget');
                },
              ),
            ),
          ...switch (records) {
            AsyncData(:final value) when value.isEmpty => [
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: Text('本期暂无账单')),
              ),
            ],
            AsyncData(:final value) => [
              SliverList.list(
                children: _grouped(context, value, categories, assets),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 96)),
            ],
            AsyncError(:final error) => [
              SliverFillRemaining(child: ErrorView(error)),
            ],
            _ => [const SliverFillRemaining(child: Loading())],
          },
        ],
      ),
    );
  }

  List<Widget> _grouped(
    BuildContext context,
    List<LedgerRecord> records,
    List<RecordCategory> categories,
    List<Asset> assets,
  ) {
    final widgets = <Widget>[];
    String? day;
    for (final r in records) {
      final time = DateTime.fromMillisecondsSinceEpoch(r.recordTime);
      final key = formatDate(time);
      if (key != day) {
        day = key;
        widgets.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(key, style: Theme.of(context).textTheme.labelLarge),
          ),
        );
      }
      final info = _resolveRecordDisplayInfo(r, categories, assets);
      widgets.add(
        _HomeRecordTile(
          record: r,
          label: info.label,
          categoryName: info.categoryName,
          categoryIcon: info.categoryIcon,
          parentCategoryIcon: info.parentCategoryIcon,
          categoryColor: info.categoryColor,
        ),
      );
    }
    return widgets;
  }
}

final class _RecordDisplayInfo {
  const _RecordDisplayInfo({
    required this.label,
    this.categoryName,
    this.categoryIcon,
    this.parentCategoryIcon,
    this.categoryColor,
  });

  final RecordLabel label;
  final String? categoryName;
  final String? categoryIcon;
  final String? parentCategoryIcon;
  final String? categoryColor;
}

_RecordDisplayInfo _resolveRecordDisplayInfo(
  LedgerRecord r,
  List<RecordCategory> categories,
  List<Asset> assets,
) {
  final label = recordLabel(r, categories, assets);
  final cat = r.recordCatId == noRef
      ? null
      : categories.where((c) => c.id == r.recordCatId).firstOrNull;
  final parentCat = (cat != null && cat.parentCatId != noRef)
      ? categories.where((c) => c.id == cat.parentCatId).firstOrNull
      : null;
  final catDisplayName = cat == null
      ? null
      : (parentCat != null ? '${parentCat.name} · ${cat.name}' : cat.name);
  final catColor = (cat?.colorFill != null && cat!.colorFill!.trim().isNotEmpty)
      ? cat.colorFill
      : parentCat?.colorFill;
  return _RecordDisplayInfo(
    label: label,
    categoryName: catDisplayName,
    categoryIcon: cat?.icon,
    parentCategoryIcon: parentCat?.icon,
    categoryColor: catColor,
  );
}

class _DesktopHomeBody extends ConsumerWidget {
  const _DesktopHomeBody({
    required this.isExpandedDesktop,
    required this.selectedRecordId,
    required this.onOpenRecordDetail,
    required this.onDeleteRecord,
  });

  final bool isExpandedDesktop;
  final String? selectedRecordId;
  final ValueChanged<String> onOpenRecordDetail;
  final Future<void> Function(LedgerRecord) onDeleteRecord;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final period = ref.watch(currentPeriodProvider);
    final summary = ref.watch(periodSummaryProvider);
    final records = ref.watch(periodRecordsProvider);
    final bookId = ref.watch(currentBookIdProvider).value;
    final categories = bookId == null
        ? const <RecordCategory>[]
        : ref.watch(categoriesProvider(bookId)).value ?? const [];
    final assets = ref.watch(assetsProvider).value ?? const <Asset>[];
    final settings =
        ref.watch(appSettingsProvider).value ?? AppSettings.defaults;
    final assetOverview = ref.watch(assetOverviewProvider).value;
    final periodOffset = ref.watch(periodOffsetProvider);
    final offset = ref.read(periodOffsetProvider.notifier);

    final periodTitle = period.value == null
        ? ''
        : '${period.value!.year}年${period.value!.month}月';

    return PeriodSwipeRegion(
      onPrevious: offset.previous,
      onNext: offset.next,
      child: CustomScrollView(
        slivers: [
          if (isExpandedDesktop)
            SliverToBoxAdapter(
              child: _DesktopExpandedOverviewHeader(
                periodTitle: periodTitle,
                periodOffset: periodOffset,
                onPreviousPeriod: offset.previous,
                onNextPeriod: offset.next,
                onResetPeriod: offset.reset,
                summary: summary.value ?? IncomeExpense.zero,
                showAssetBanner: settings.showHomeAssetSummaryBanner,
                assetOverview: assetOverview,
                onOpenAssets: () => context.go('/assets'),
                showBudgetCard:
                    settings.showHomeBudgetCard && periodOffset == 0,
                onOpenBudget: () {
                  ref.read(budgetOffsetProvider.notifier).reset();
                  context.push('/budget');
                },
              ),
            )
          else ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: '上一期',
                      onPressed: offset.previous,
                      icon: const Icon(Icons.chevron_left),
                    ),
                    Expanded(
                      child: Center(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: InkWell(
                                borderRadius: BorderRadius.circular(6),
                                onTap: periodOffset != 0 ? offset.reset : null,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                    vertical: 2,
                                  ),
                                  child: Text(
                                    periodTitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                ),
                              ),
                            ),
                            if (periodOffset != 0) ...[
                              const SizedBox(width: 6),
                              _HomeResetPeriodPill(onTap: offset.reset),
                            ],
                          ],
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '下一期',
                      onPressed: offset.next,
                      icon: const Icon(Icons.chevron_right),
                    ),
                  ],
                ),
              ),
            ),
            if (settings.showHomeAssetSummaryBanner)
              SliverToBoxAdapter(
                child: _HomeAssetSummaryBanner(
                  overview: assetOverview,
                  onTap: () => context.go('/assets'),
                ),
              ),
            SliverToBoxAdapter(
              child: _SummaryCard(summary.value ?? IncomeExpense.zero),
            ),
            if (settings.showHomeBudgetCard && periodOffset == 0)
              SliverToBoxAdapter(
                child: BudgetSummaryCard(
                  fixedOffset: 0,
                  hideWhenEmpty: true,
                  onTap: () {
                    ref.read(budgetOffsetProvider.notifier).reset();
                    context.push('/budget');
                  },
                ),
              ),
          ],
          ...switch (records) {
            AsyncData(:final value) when value.isEmpty => [
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: Text('本期暂无账单')),
              ),
            ],
            AsyncData(:final value) => [
              SliverList.list(
                children: _buildDesktopGrouped(
                  context,
                  value,
                  categories,
                  assets,
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 64)),
            ],
            AsyncError(:final error) => [
              SliverFillRemaining(child: ErrorView(error)),
            ],
            _ => [const SliverFillRemaining(child: Loading())],
          },
        ],
      ),
    );
  }

  List<Widget> _buildDesktopGrouped(
    BuildContext context,
    List<LedgerRecord> records,
    List<RecordCategory> categories,
    List<Asset> assets,
  ) {
    final widgets = <Widget>[];
    String? day;
    for (final r in records) {
      final time = DateTime.fromMillisecondsSinceEpoch(r.recordTime);
      final key = formatDate(time);
      if (key != day) {
        day = key;
        widgets.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Text(key, style: Theme.of(context).textTheme.labelLarge),
          ),
        );
      }
      final info = _resolveRecordDisplayInfo(r, categories, assets);
      widgets.add(
        _DesktopHomeRecordTile(
          record: r,
          label: info.label,
          categoryName: info.categoryName,
          categoryIcon: info.categoryIcon,
          parentCategoryIcon: info.parentCategoryIcon,
          categoryColor: info.categoryColor,
          selected: selectedRecordId == r.recordId,
          onOpenDetail: () => onOpenRecordDetail(r.recordId),
          onDelete: () => onDeleteRecord(r),
        ),
      );
    }
    return widgets;
  }
}

class _DesktopExpandedOverviewHeader extends ConsumerWidget {
  const _DesktopExpandedOverviewHeader({
    required this.periodTitle,
    required this.periodOffset,
    required this.onPreviousPeriod,
    required this.onNextPeriod,
    required this.onResetPeriod,
    required this.summary,
    required this.showAssetBanner,
    required this.assetOverview,
    required this.onOpenAssets,
    required this.showBudgetCard,
    required this.onOpenBudget,
  });

  final String periodTitle;
  final int periodOffset;
  final VoidCallback onPreviousPeriod;
  final VoidCallback onNextPeriod;
  final VoidCallback onResetPeriod;
  final IncomeExpense summary;
  final bool showAssetBanner;
  final AssetOverview? assetOverview;
  final VoidCallback onOpenAssets;
  final bool showBudgetCard;
  final VoidCallback onOpenBudget;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final budgetOverview = showBudgetCard
        ? ref.watch(budgetOverviewForOffsetProvider(0)).value
        : null;
    final hasPopulatedBudget =
        showBudgetCard &&
        budgetOverview?.totalBudget != null &&
        budgetOverview?.totalUsage != null;

    final periodStrip = Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '上一期',
            visualDensity: VisualDensity.compact,
            onPressed: onPreviousPeriod,
            icon: const Icon(Icons.chevron_left, size: 20),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 96),
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: periodOffset != 0 ? onResetPeriod : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Center(
                  widthFactor: 1.0,
                  child: Text(
                    periodTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: '下一期',
            visualDensity: VisualDensity.compact,
            onPressed: onNextPeriod,
            icon: const Icon(Icons.chevron_right, size: 20),
          ),
          if (periodOffset != 0) ...[
            const SizedBox(width: 2),
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: _HomeResetPeriodPill(onTap: onResetPeriod),
            ),
          ],
        ],
      ),
    );

    final budgetCardWidget = showBudgetCard
        ? BudgetSummaryCard(
            fixedOffset: 0,
            hideWhenEmpty: true,
            onTap: onOpenBudget,
          )
        : null;

    return LayoutBuilder(
      key: const Key('home-desktop-overview'),
      builder: (context, constraints) {
        final wideHeader = constraints.maxWidth >= 560;
        final sideBySideBudget =
            hasPopulatedBudget && constraints.maxWidth >= 680;

        return Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: wideHeader
                    ? Row(
                        children: [
                          periodStrip,
                          const SizedBox(width: 12),
                          if (showAssetBanner)
                            Expanded(
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: _DesktopAssetSummaryPill(
                                  overview: assetOverview,
                                  onTap: onOpenAssets,
                                ),
                              ),
                            )
                          else
                            const Spacer(),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Align(
                            alignment: Alignment.centerLeft,
                            child: periodStrip,
                          ),
                          if (showAssetBanner) ...[
                            const SizedBox(height: 8),
                            _DesktopAssetSummaryPill(
                              overview: assetOverview,
                              onTap: onOpenAssets,
                            ),
                          ],
                        ],
                      ),
              ),
              const SizedBox(height: 8),
              if (sideBySideBudget && budgetCardWidget != null)
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        flex: 11,
                        child: _DesktopCompactSummaryCard(
                          summary: summary,
                          margin: const EdgeInsets.fromLTRB(16, 6, 0, 6),
                        ),
                      ),
                      Expanded(flex: 10, child: budgetCardWidget),
                    ],
                  ),
                )
              else ...[
                _DesktopCompactSummaryCard(
                  summary: summary,
                  margin: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                ),
                ?budgetCardWidget,
              ],
            ],
          ),
        );
      },
    );
  }
}

class _DesktopAssetSummaryPill extends StatelessWidget {
  const _DesktopAssetSummaryPill({required this.overview, required this.onTap});

  final AssetOverview? overview;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final net = overview?.netAsset ?? BigInt.zero;
    final totalAsset = overview?.totalAsset ?? BigInt.zero;
    final totalLiability = overview?.totalLiabilities ?? BigInt.zero;

    return Material(
      key: const Key('home-asset-summary-banner'),
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.45)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.account_balance_wallet_outlined,
                size: 17,
                color: scheme.primary,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  '净资产 ¥${formatMinor(net)}  ·  资产 ¥${formatMinor(totalAsset)} · 负债 ¥${formatMinor(totalLiability)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.chevron_right_rounded,
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DesktopCompactSummaryCard extends StatelessWidget {
  const _DesktopCompactSummaryCard({
    required this.summary,
    required this.margin,
  });

  final IncomeExpense summary;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    Widget metricCell(String label, BigInt v, Key key) => Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                formatMinor(v),
                key: key,
                maxLines: 1,
                softWrap: false,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    return Card(
      margin: margin,
      child: Center(
        heightFactor: 1.0,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
          child: Row(
            children: [
              metricCell('结余', summary.balance, const Key('sum-balance')),
              SizedBox(
                height: 32,
                child: VerticalDivider(
                  width: 1,
                  thickness: 0.6,
                  color: scheme.outlineVariant.withValues(alpha: 0.45),
                ),
              ),
              metricCell('支出', summary.expense, const Key('sum-expense')),
              SizedBox(
                height: 32,
                child: VerticalDivider(
                  width: 1,
                  thickness: 0.6,
                  color: scheme.outlineVariant.withValues(alpha: 0.45),
                ),
              ),
              metricCell('收入', summary.income, const Key('sum-income')),
            ],
          ),
        ),
      ),
    );
  }
}

enum _RecordContextAction { detail, edit, duplicate, receipt, delete }

class _DesktopHomeRecordTile extends ConsumerStatefulWidget {
  const _DesktopHomeRecordTile({
    required this.record,
    required this.label,
    this.categoryName,
    this.categoryIcon,
    this.parentCategoryIcon,
    this.categoryColor,
    required this.selected,
    required this.onOpenDetail,
    required this.onDelete,
  });

  final LedgerRecord record;
  final RecordLabel label;
  final String? categoryName;
  final String? categoryIcon;
  final String? parentCategoryIcon;
  final String? categoryColor;
  final bool selected;
  final VoidCallback onOpenDetail;
  final Future<void> Function() onDelete;

  @override
  ConsumerState<_DesktopHomeRecordTile> createState() =>
      _DesktopHomeRecordTileState();
}

class _DesktopHomeRecordTileState
    extends ConsumerState<_DesktopHomeRecordTile> {
  bool _hovered = false;

  Future<void> _showContextMenu(Offset globalPosition) async {
    final r = widget.record;
    final editable = isRecordEditable(r);
    final deletable = !isGeneratedTransferFeeRecord(r);
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final localPos = overlay?.globalToLocal(globalPosition) ?? globalPosition;
    final position = RelativeRect.fromRect(
      localPos & const Size(1, 1),
      Offset.zero & (overlay?.size ?? const Size(1280, 800)),
    );

    final selected = await showMenu<_RecordContextAction>(
      context: context,
      position: position,
      items: <PopupMenuEntry<_RecordContextAction>>[
        const PopupMenuItem<_RecordContextAction>(
          value: _RecordContextAction.detail,
          child: Text('查看详情'),
        ),
        PopupMenuItem<_RecordContextAction>(
          value: _RecordContextAction.edit,
          enabled: editable,
          child: const Text('编辑'),
        ),
        const PopupMenuItem<_RecordContextAction>(
          value: _RecordContextAction.duplicate,
          child: Text('复制再记一笔'),
        ),
        const PopupMenuItem<_RecordContextAction>(
          value: _RecordContextAction.receipt,
          child: Text('生成小票'),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<_RecordContextAction>(
          value: _RecordContextAction.delete,
          enabled: deletable,
          child: const Text('删除'),
        ),
      ],
    );
    if (selected == null || !mounted) return;
    switch (selected) {
      case _RecordContextAction.detail:
        widget.onOpenDetail();
      case _RecordContextAction.edit:
        if (editable) {
          await context.push('/record/${r.recordId}/edit');
        }
      case _RecordContextAction.duplicate:
        await context.push(_buildDuplicateRecordRoute(r));
      case _RecordContextAction.receipt:
        await showRecordReceiptDialog(
          context,
          recordId: r.recordId,
          initialRecord: r,
        );
      case _RecordContextAction.delete:
        if (deletable) {
          await widget.onDelete();
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final record = widget.record;
    final label = widget.label;
    final tags =
        ref.watch(recordTagsProvider(record.recordId)).value ?? const <Tag>[];
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final editable = isRecordEditable(record);
    final isRefund =
        (record.type == RecordType.expense ||
            record.type == RecordType.income) &&
        record.moneyMinor < BigInt.zero;

    Widget? subtitle;
    if (label.subtitle.isNotEmpty && tags.isEmpty) {
      subtitle = Text(
        label.subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      );
    } else if (label.subtitle.isNotEmpty || tags.isNotEmpty) {
      subtitle = Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (label.subtitle.isNotEmpty)
            Text(
              label.subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          for (final t in tags)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: scheme.secondaryContainer.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '#${t.name}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSecondaryContainer,
                ),
              ),
            ),
        ],
      );
    }

    final bgColor = widget.selected
        ? scheme.secondaryContainer.withValues(alpha: _hovered ? 0.62 : 0.45)
        : (_hovered
              ? scheme.surfaceContainerHighest.withValues(alpha: 0.45)
              : Colors.transparent);

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
              key: Key('record-${record.recordId}'),
              onTap: widget.onOpenDetail,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    RecordTypeIconAvatar(
                      recordType: record.type,
                      subType: record.subType,
                      isRefund: isRefund,
                      categoryName: widget.categoryName,
                      categoryIcon: widget.categoryIcon,
                      parentCategoryIcon: widget.parentCategoryIcon,
                      categoryColor: widget.categoryColor,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            label.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyLarge,
                          ),
                          if (subtitle != null) ...[
                            const SizedBox(height: 2),
                            subtitle,
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (_hovered) ...[
                      if (editable)
                        IconButton(
                          key: Key('record-hover-edit-${record.recordId}'),
                          tooltip: '编辑',
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints.tightFor(
                            width: 30,
                            height: 30,
                          ),
                          padding: EdgeInsets.zero,
                          iconSize: 17,
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () =>
                              context.push('/record/${record.recordId}/edit'),
                        ),
                      IconButton(
                        key: Key('record-hover-detail-${record.recordId}'),
                        tooltip: '查看详情',
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints.tightFor(
                          width: 30,
                          height: 30,
                        ),
                        padding: EdgeInsets.zero,
                        iconSize: 17,
                        icon: const Icon(Icons.info_outline_rounded),
                        onPressed: widget.onOpenDetail,
                      ),
                      const SizedBox(width: 6),
                    ],
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 160),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Text(
                          label.amount,
                          maxLines: 1,
                          softWrap: false,
                          style: TextStyle(
                            color: record.type == RecordType.income
                                ? (theme.brightness == Brightness.dark
                                      ? Colors.green.shade300
                                      : Colors.green.shade700)
                                : null,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
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

class _HomeRecordTile extends ConsumerWidget {
  const _HomeRecordTile({
    required this.record,
    required this.label,
    this.categoryName,
    this.categoryIcon,
    this.parentCategoryIcon,
    this.categoryColor,
  });

  final LedgerRecord record;
  final RecordLabel label;
  final String? categoryName;
  final String? categoryIcon;
  final String? parentCategoryIcon;
  final String? categoryColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tags =
        ref.watch(recordTagsProvider(record.recordId)).value ?? const <Tag>[];
    final theme = Theme.of(context);
    final isRefund =
        (record.type == RecordType.expense ||
            record.type == RecordType.income) &&
        record.moneyMinor < BigInt.zero;

    Widget? subtitle;
    if (label.subtitle.isNotEmpty && tags.isEmpty) {
      subtitle = Text(label.subtitle);
    } else if (label.subtitle.isNotEmpty || tags.isNotEmpty) {
      subtitle = Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (label.subtitle.isNotEmpty) Text(label.subtitle),
          for (final t in tags)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer.withValues(
                  alpha: 0.7,
                ),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '#${t.name}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
            ),
        ],
      );
    }

    return ListTile(
      key: Key('record-${record.recordId}'),
      leading: RecordTypeIconAvatar(
        recordType: record.type,
        subType: record.subType,
        isRefund: isRefund,
        categoryName: categoryName,
        categoryIcon: categoryIcon,
        parentCategoryIcon: parentCategoryIcon,
        categoryColor: categoryColor,
      ),
      title: Text(label.title),
      subtitle: subtitle,
      trailing: Text(
        label.amount,
        style: TextStyle(
          color: record.type == RecordType.income
              ? (theme.brightness == Brightness.dark
                    ? Colors.green.shade300
                    : Colors.green.shade700)
              : null,
          fontWeight: FontWeight.w600,
        ),
      ),
      onTap: () => context.push('/record/${record.recordId}'),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard(this.s);
  final IncomeExpense s;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget cell(String label, BigInt v, Key key) => Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Column(
          children: [
            Text(label, style: theme.textTheme.labelMedium),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                formatMinor(v),
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
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Row(
          children: [
            cell('结余', s.balance, const Key('sum-balance')),
            cell('支出', s.expense, const Key('sum-expense')),
            cell('收入', s.income, const Key('sum-income')),
          ],
        ),
      ),
    );
  }
}

class _HomeAssetSummaryBanner extends StatelessWidget {
  const _HomeAssetSummaryBanner({required this.overview, required this.onTap});

  final AssetOverview? overview;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final net = overview?.netAsset ?? BigInt.zero;
    final totalAsset = overview?.totalAsset ?? BigInt.zero;
    final totalLiability = overview?.totalLiabilities ?? BigInt.zero;

    return Card(
      key: const Key('home-asset-summary-banner'),
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(
                Icons.account_balance_wallet_outlined,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '净资产 ¥${formatMinor(net)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  '资产 ¥${formatMinor(totalAsset)} · 负债 ¥${formatMinor(totalLiability)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
