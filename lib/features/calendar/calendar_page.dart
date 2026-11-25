import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/adaptive.dart';
import '../../app/providers.dart';
import '../../data/db/database.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/calendar.dart';
import '../../domain/rules/income_expense.dart';
import '../common/catalog_icons.dart';
import '../common/common.dart';
import '../common/year_month_picker_dialog.dart';
import '../records/record_labels.dart';

class CalendarPage extends ConsumerStatefulWidget {
  const CalendarPage({super.key});

  @override
  ConsumerState<CalendarPage> createState() => _CalendarPageState();
}

class _SyncedPageController extends PageController {
  _SyncedPageController({required int initialPage})
    : _syncedInitialPage = initialPage,
      super(initialPage: initialPage, keepPage: false);

  int _syncedInitialPage;

  @override
  int get initialPage => _syncedInitialPage;

  set syncedInitialPage(int value) {
    _syncedInitialPage = value;
  }
}

class _CalendarPageState extends ConsumerState<CalendarPage> {
  static const int _kBasePage = 12000;
  static const Duration _trackpadCooldown = Duration(milliseconds: 320);

  int _selectedDay = DateTime.now().day;
  late final _SyncedPageController _pageController;
  bool? _lastExpandedDesktop;
  bool _syncingFromPageView = false;
  Timer? _trackpadCooldownTimer;
  bool _trackpadInCooldown = false;

  @override
  void initState() {
    super.initState();
    final initialOffset = ref.read(calendarMonthOffsetProvider);
    _pageController = _SyncedPageController(
      initialPage: _kBasePage + initialOffset,
    );
  }

  @override
  void dispose() {
    _trackpadCooldownTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  void _startTrackpadCooldown() {
    _trackpadInCooldown = true;
    _trackpadCooldownTimer?.cancel();
    _trackpadCooldownTimer = Timer(_trackpadCooldown, () {
      _trackpadInCooldown = false;
    });
  }

  void _handleCalendarPointerSignal(PointerSignalEvent event) {
    if (_trackpadInCooldown) return;
    if (event is PointerScrollEvent) {
      final dx = event.scrollDelta.dx;
      final dy = event.scrollDelta.dy;
      if (dx.abs() >= 18.0 && dx.abs() > dy.abs() * 1.3) {
        _startTrackpadCooldown();
        final notifier = ref.read(calendarMonthOffsetProvider.notifier);
        if (dx > 0) {
          notifier.next();
        } else {
          notifier.previous();
        }
      }
    }
  }

  void _handleCalendarPanZoomUpdate(PointerPanZoomUpdateEvent event) {
    if (_trackpadInCooldown) return;
    final dx = event.localPan.dx;
    final dy = event.localPan.dy;
    if (dx.abs() > 48.0 && dx.abs() > dy.abs() * 1.4) {
      _startTrackpadCooldown();
      final notifier = ref.read(calendarMonthOffsetProvider.notifier);
      if (dx > 0) {
        notifier.previous();
      } else {
        notifier.next();
      }
    }
  }

  void _handlePageChanged(int pageIndex) {
    final newOffset = pageIndex - _kBasePage;
    final newMonth = ref.read(calendarMonthForOffsetProvider(newOffset));
    final clamped = _selectedDay.clamp(1, newMonth.daysInMonth);
    if (clamped != _selectedDay) {
      setState(() => _selectedDay = clamped);
    }
    if (ref.read(calendarMonthOffsetProvider) != newOffset) {
      _syncingFromPageView = true;
      ref.read(calendarMonthOffsetProvider.notifier).setOffset(newOffset);
      _syncingFromPageView = false;
    }
  }

  Set<int> _getRepaymentDays(int year, int month, List<Asset> assets) {
    final days = <int>{};
    for (final a in assets) {
      if (a.type == AssetType.credit && a.status == 0) {
        final day =
            parseRepaymentDay(a.creditInfo, year, month) ??
            parseRepaymentDay(a.extraInfo, year, month);
        if (day != null) days.add(day);
      }
    }
    return days;
  }

  void _resetToToday() {
    ref.read(calendarMonthOffsetProvider.notifier).reset();
    setState(() => _selectedDay = DateTime.now().day);
    if (_pageController.hasClients) {
      final currentPage =
          _pageController.page?.round() ?? _pageController.initialPage;
      if (currentPage != _kBasePage) {
        _pageController.jumpToPage(_kBasePage);
      }
    }
  }

  Future<void> _pickMonth(
    BuildContext context,
    CalendarMonth currentMonth,
  ) async {
    final picked = await showYearMonthPickerDialog(
      context,
      initialYear: currentMonth.year,
      initialMonth: currentMonth.month,
    );
    if (picked == null || !mounted) return;
    final now = DateTime.now();
    final newOffset =
        (picked.year - now.year) * 12 + (picked.month - now.month);
    final targetMonth = ref.read(calendarMonthForOffsetProvider(newOffset));
    final clampedDay = _selectedDay.clamp(1, targetMonth.daysInMonth);
    if (clampedDay != _selectedDay) {
      setState(() => _selectedDay = clampedDay);
    }
    ref.read(calendarMonthOffsetProvider.notifier).setOffset(newOffset);
    final targetPage = _kBasePage + newOffset;
    _pageController.syncedInitialPage = targetPage;
    if (_pageController.hasClients) {
      final currentPage =
          _pageController.page?.round() ?? _pageController.initialPage;
      if (currentPage != targetPage) {
        _pageController.jumpToPage(targetPage);
      }
    }
  }

  static int _rowCountForMonth(CalendarMonth month) {
    final leadingBlanks = (month.firstWeekday - 1) % 7;
    final totalCells = leadingBlanks + month.daysInMonth;
    return ((totalCells + 6) ~/ 7).clamp(4, 6);
  }

  static double _cellHeightForContext(
    BuildContext context, {
    required int rowCount,
    required bool isDesktopPane,
  }) {
    final viewportHeight = MediaQuery.sizeOf(context).height;
    final textScale = MediaQuery.textScalerOf(
      context,
    ).scale(1.0).clamp(1.0, 1.35);
    if (isDesktopPane) {
      final baseDesktopHeight = viewportHeight < 740 ? 52.0 : 58.0;
      return (baseDesktopHeight * textScale).clamp(48.0, 68.0);
    }
    if (DesktopAdaptive.isDesktop(context) && viewportHeight < 680) {
      final maxCompactGridHeight = (viewportHeight - 385.0).clamp(180.0, 224.0);
      return (maxCompactGridHeight / rowCount).clamp(32.0, 40.0);
    }
    final baseCellHeight = viewportHeight < 700 ? 46.0 : 54.0;
    final maxGridHeight = (viewportHeight - 305.0).clamp(192.0, 390.0);
    return (baseCellHeight * textScale).clamp(42.0, maxGridHeight / rowCount);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(calendarMonthOffsetProvider, (prev, next) {
      if (prev == next) return;
      final nextMonth = ref.read(calendarMonthForOffsetProvider(next));
      final clamped = _selectedDay.clamp(1, nextMonth.daysInMonth);
      if (clamped != _selectedDay) {
        setState(() => _selectedDay = clamped);
      }
      if (!_syncingFromPageView && _pageController.hasClients) {
        final targetPage = _kBasePage + next;
        final currentPage =
            _pageController.page?.round() ?? _pageController.initialPage;
        if (currentPage != targetPage) {
          _pageController.jumpToPage(targetPage);
        }
      }
    });

    final activeOffset = ref.watch(calendarMonthOffsetProvider);
    final month = ref.watch(calendarCurrentMonthProvider);
    final summariesAsync = ref.watch(calendarDailySummariesProvider);
    final monthSummaryAsync = ref.watch(calendarMonthSummaryProvider);
    final bookId = ref.watch(currentBookIdProvider).value ?? 1;
    final categories = ref.watch(categoriesProvider(bookId)).value ?? const [];
    final assets = ref.watch(assetsProvider).value ?? const <Asset>[];

    final clampedSelectedDay = _selectedDay.clamp(1, month.daysInMonth);
    if (clampedSelectedDay != _selectedDay) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _selectedDay = clampedSelectedDay);
      });
    }

    final isDesktop = DesktopAdaptive.isDesktop(context);
    final isExpandedDesktop = DesktopAdaptive.isExpandedDesktop(context);
    final targetPage = _kBasePage + activeOffset;
    _pageController.syncedInitialPage = targetPage;
    if (_lastExpandedDesktop != null &&
        _lastExpandedDesktop != isExpandedDesktop) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_pageController.hasClients) return;
        final currentPage =
            _pageController.page?.round() ?? _pageController.initialPage;
        final int currentOffset = ref.read(calendarMonthOffsetProvider);
        final desiredPage = _kBasePage + currentOffset;
        if (currentPage != desiredPage) {
          _pageController.jumpToPage(desiredPage);
        }
      });
    }
    _lastExpandedDesktop = isExpandedDesktop;

    final selectedDayNoonMs = DateTime(
      month.year,
      month.month,
      clampedSelectedDay,
      12,
    ).millisecondsSinceEpoch;

    Widget buildSingleColumnBody() => Column(
      children: [
        _buildSectionCard(
          context,
          margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: _buildMonthSection(
            context,
            month: month,
            monthSummaryAsync: monthSummaryAsync,
            activeOffset: activeOffset,
            assets: assets,
            clampedSelectedDay: clampedSelectedDay,
          ),
        ),
        Expanded(
          child: _buildSectionCard(
            context,
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildSelectedDayHeader(
                  context,
                  month,
                  summariesAsync,
                  clampedSelectedDay,
                  selectedDayNoonMs: selectedDayNoonMs,
                ),
                Expanded(
                  child: _buildSelectedDayRecords(
                    context,
                    summariesAsync,
                    clampedSelectedDay,
                    categories,
                    assets,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('日历视图'),
        actions: [
          TextButton(
            key: const Key('calendar-today-button'),
            onPressed: _resetToToday,
            child: const Text('今天'),
          ),
        ],
      ),
      body: isExpandedDesktop
          ? Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1440),
                child: Row(
                  key: const Key('calendar-desktop-split'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: 480,
                      child: SingleChildScrollView(
                        child: _buildSectionCard(
                          context,
                          margin: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                          child: _buildMonthSection(
                            context,
                            month: month,
                            monthSummaryAsync: monthSummaryAsync,
                            activeOffset: activeOffset,
                            assets: assets,
                            clampedSelectedDay: clampedSelectedDay,
                            isDesktopPane: true,
                          ),
                        ),
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: _buildSectionCard(
                        context,
                        margin: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildDesktopSelectedDayHeader(
                              context,
                              month,
                              summariesAsync,
                              clampedSelectedDay,
                              selectedDayNoonMs,
                            ),
                            Expanded(
                              child: _buildSelectedDayRecords(
                                context,
                                summariesAsync,
                                clampedSelectedDay,
                                categories,
                                assets,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : (isDesktop
                ? Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: buildSingleColumnBody(),
                    ),
                  )
                : buildSingleColumnBody()),
    );
  }

  Widget _buildSectionCard(
    BuildContext context, {
    required EdgeInsetsGeometry margin,
    required Widget child,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    return Card(
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      color: isDark
          ? scheme.surfaceContainerLow
          : Color.lerp(
              scheme.surfaceContainerLow,
              scheme.surfaceContainer,
              0.55,
            )!,
      margin: margin,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: child,
    );
  }

  Widget _buildMonthSection(
    BuildContext context, {
    required CalendarMonth month,
    required AsyncValue<IncomeExpense> monthSummaryAsync,
    required int activeOffset,
    required List<Asset> assets,
    required int clampedSelectedDay,
    bool isDesktopPane = false,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildMonthSwitcher(context, month),
        _buildMonthSummaryCard(context, monthSummaryAsync),
        _buildWeekdayHeader(context),
        _buildCalendarPageView(
          context,
          activeOffset: activeOffset,
          activeMonth: month,
          assets: assets,
          clampedSelectedDay: clampedSelectedDay,
          isDesktopPane: isDesktopPane,
        ),
        const SizedBox(height: 4),
      ],
    );
  }

  Widget _buildCalendarPageView(
    BuildContext context, {
    required int activeOffset,
    required CalendarMonth activeMonth,
    required List<Asset> assets,
    required int clampedSelectedDay,
    bool isDesktopPane = false,
  }) {
    final activeRowCount = _rowCountForMonth(activeMonth);
    final activeCellHeight = _cellHeightForContext(
      context,
      rowCount: activeRowCount,
      isDesktopPane: isDesktopPane,
    );
    final activeGridHeight = activeRowCount * activeCellHeight;

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerSignal: _handleCalendarPointerSignal,
      onPointerPanZoomUpdate: _handleCalendarPanZoomUpdate,
      child: AnimatedSize(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: SizedBox(
          height: activeGridHeight,
          child: PageView.builder(
            key: const Key('calendar-month-pageview'),
            controller: _pageController,
            scrollBehavior: ScrollConfiguration.of(context).copyWith(
              dragDevices: const <PointerDeviceKind>{
                PointerDeviceKind.touch,
                PointerDeviceKind.mouse,
                PointerDeviceKind.trackpad,
                PointerDeviceKind.stylus,
                PointerDeviceKind.invertedStylus,
              },
            ),
            onPageChanged: _handlePageChanged,
            itemBuilder: (context, pageIndex) {
              final pageOffset = pageIndex - _kBasePage;
              final isActivePage = pageOffset == activeOffset;
              final pageMonth = ref.watch(
                calendarMonthForOffsetProvider(pageOffset),
              );
              final pageSummariesAsync = ref.watch(
                calendarDailySummariesForOffsetProvider(pageOffset),
              );
              if (pageSummariesAsync.hasError && isActivePage) {
                return ErrorView(pageSummariesAsync.error!);
              }
              final pageDailyMap =
                  pageSummariesAsync.value ??
                  const <int, CalendarDailySummary<LedgerRecord>>{};
              final pageRepaymentDays = _getRepaymentDays(
                pageMonth.year,
                pageMonth.month,
                assets,
              );
              final pageSelectedDay = clampedSelectedDay.clamp(
                1,
                pageMonth.daysInMonth,
              );
              return _buildCalendarGrid(
                context,
                pageMonth,
                pageDailyMap,
                pageRepaymentDays,
                pageSelectedDay,
                pageOffset: pageOffset,
                isActivePage: isActivePage,
                isDesktopPane: isDesktopPane,
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildMonthSwitcher(BuildContext context, CalendarMonth month) {
    final offsetNotifier = ref.read(calendarMonthOffsetProvider.notifier);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Row(
        children: [
          IconButton(
            key: const Key('calendar-prev-month'),
            tooltip: '上个月',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.chevron_left),
            onPressed: offsetNotifier.previous,
          ),
          Expanded(
            child: Center(
              child: InkWell(
                key: const Key('calendar-period-picker-trigger'),
                borderRadius: BorderRadius.circular(8),
                onTap: () => _pickMonth(context, month),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      '${month.year}年${month.month}月',
                      maxLines: 1,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            key: const Key('calendar-next-month'),
            tooltip: '下个月',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.chevron_right),
            onPressed: offsetNotifier.next,
          ),
        ],
      ),
    );
  }

  Widget _buildMonthSummaryCard(
    BuildContext context,
    AsyncValue<IncomeExpense> summaryAsync,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final expenseColor = isDark ? Colors.red.shade300 : Colors.red.shade700;
    final incomeColor = isDark ? Colors.green.shade300 : Colors.green.shade700;
    final summary = summaryAsync.value ?? IncomeExpense.zero;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      decoration: BoxDecoration(
        color: isDark
            ? scheme.surfaceContainerHigh.withValues(alpha: 0.65)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: _summaryItem(
              context,
              '结余',
              formatMinor(summary.balance),
              scheme.onSurface,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _summaryItem(
              context,
              '支出',
              formatMinor(summary.expense),
              expenseColor,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _summaryItem(
              context,
              '收入',
              formatMinor(summary.income),
              incomeColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryItem(
    BuildContext context,
    String label,
    String value,
    Color? color,
  ) {
    final mutedColor = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          maxLines: 1,
          style: TextStyle(fontSize: 11, color: mutedColor),
        ),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            '¥$value',
            maxLines: 1,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildWeekdayHeader(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final weekendColor = isDark
        ? Colors.orange.shade300
        : Colors.orange.shade800;
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        children: [
          for (var i = 0; i < 7; i++)
            Expanded(
              child: Center(
                child: Text(
                  weekdays[i],
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: i >= 5 ? weekendColor : scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCalendarGrid(
    BuildContext context,
    CalendarMonth month,
    Map<int, CalendarDailySummary<LedgerRecord>> dailyMap,
    Set<int> repaymentDays,
    int selectedDay, {
    required int pageOffset,
    required bool isActivePage,
    bool isDesktopPane = false,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final expenseColor = isDark ? Colors.red.shade300 : Colors.red.shade700;
    final incomeColor = isDark ? Colors.green.shade300 : Colors.green.shade700;
    final now = DateTime.now();
    final isCurrentMonth = now.year == month.year && now.month == month.month;

    // ISO 8601: Monday=1 .. Sunday=7. Leading blanks count:
    final leadingBlanks = (month.firstWeekday - 1) % 7;
    final totalCells = leadingBlanks + month.daysInMonth;
    final rowCount = ((totalCells + 6) ~/ 7).clamp(4, 6);
    final cellHeight = _cellHeightForContext(
      context,
      rowCount: rowCount,
      isDesktopPane: isDesktopPane,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final effectiveCellHeight =
            constraints.maxHeight.isFinite && constraints.maxHeight > 0
            ? math.min(cellHeight, constraints.maxHeight / rowCount)
            : cellHeight;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: GridView.builder(
            key: isActivePage
                ? const Key('calendar-grid')
                : ValueKey('calendar-grid-$pageOffset'),
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              mainAxisExtent: effectiveCellHeight,
            ),
            itemCount: totalCells,
            itemBuilder: (context, index) {
              if (index < leadingBlanks) {
                return const SizedBox();
              }
              final day = index - leadingBlanks + 1;
              final isSelected = day == selectedDay;
              final isToday = isCurrentMonth && day == now.day;
              final hasRepayBadge = repaymentDays.contains(day);
              final summary = dailyMap[day];
              final cellExpenseColor = isSelected
                  ? (isDark ? Colors.red.shade200 : Colors.red.shade900)
                  : expenseColor;
              final cellIncomeColor = isSelected
                  ? (isDark ? Colors.green.shade200 : Colors.green.shade900)
                  : incomeColor;

              return InkWell(
                key: isActivePage
                    ? Key('calendar-cell-$day')
                    : ValueKey('calendar-cell-$pageOffset-$day'),
                onTap: () => setState(() => _selectedDay = day),
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  margin: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? scheme.primaryContainer
                        : (isToday
                              ? scheme.primary.withValues(alpha: 0.08)
                              : null),
                    borderRadius: BorderRadius.circular(8),
                    border: isSelected
                        ? Border.all(color: scheme.primary, width: 1.5)
                        : (isToday
                              ? Border.all(
                                  color: scheme.primary.withValues(alpha: 0.5),
                                )
                              : null),
                  ),
                  child: Stack(
                    children: [
                      // Repayment badge ("还")
                      if (hasRepayBadge)
                        Positioned(
                          top: 1,
                          right: 2,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 2,
                              vertical: 0.5,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.error,
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Text(
                              '还',
                              style: TextStyle(
                                color: scheme.onError,
                                fontSize: 8,
                                height: 1.1,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      // Day content (detailed view: day number + daily amounts)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 2,
                          vertical: 1,
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Flexible(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  '$day',
                                  textAlign: TextAlign.center,
                                  maxLines: 1,
                                  style: TextStyle(
                                    fontSize: 12,
                                    height: 1.15,
                                    fontWeight: isToday || isSelected
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                    color: isSelected
                                        ? scheme.onPrimaryContainer
                                        : null,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 1),
                            // Detailed view: expense
                            if (summary != null &&
                                summary.incomeExpense.expense != BigInt.zero)
                              Flexible(
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 64,
                                    ),
                                    child: Text(
                                      '-${formatMinor(summary.incomeExpense.expense)}',
                                      textAlign: TextAlign.center,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 9,
                                        height: 1.1,
                                        color: cellExpenseColor,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                ),
                              )
                            // Detailed view: income
                            else if (summary != null &&
                                summary.incomeExpense.income != BigInt.zero)
                              Flexible(
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 64,
                                    ),
                                    child: Text(
                                      '+${formatMinor(summary.incomeExpense.income)}',
                                      textAlign: TextAlign.center,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 9,
                                        height: 1.1,
                                        color: cellIncomeColor,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                ),
                              )
                            // Records present but amounts net to 0 (e.g. transfers, excludeExIn)
                            else if (summary != null && summary.hasRecords)
                              Center(
                                child: Container(
                                  width: 4,
                                  height: 4,
                                  decoration: BoxDecoration(
                                    color: isSelected
                                        ? scheme.onPrimaryContainer.withValues(
                                            alpha: 0.7,
                                          )
                                        : scheme.outline,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildDesktopSelectedDayHeader(
    BuildContext context,
    CalendarMonth month,
    AsyncValue<Map<int, CalendarDailySummary<LedgerRecord>>> summariesAsync,
    int selectedDay,
    int selectedDayNoonMs,
  ) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final expenseColor = isDark ? Colors.red.shade300 : Colors.red.shade700;
    final incomeColor = isDark ? Colors.green.shade300 : Colors.green.shade700;
    final dayDt = DateTime(month.year, month.month, selectedDay);
    const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    final weekdayName = weekdays[(dayDt.weekday - 1) % 7];

    final summary =
        summariesAsync.value?[selectedDay]?.incomeExpense ?? IncomeExpense.zero;
    final hasDaySummary =
        summary.expense != BigInt.zero || summary.income != BigInt.zero;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${month.year}年${month.month}月$selectedDay日 $weekdayName',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (hasDaySummary) ...[
                  const SizedBox(height: 2),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (summary.expense != BigInt.zero)
                          Text(
                            '支出 ¥${formatMinor(summary.expense)}',
                            maxLines: 1,
                            style: TextStyle(fontSize: 12, color: expenseColor),
                          ),
                        if (summary.expense != BigInt.zero &&
                            summary.income != BigInt.zero)
                          const SizedBox(width: 10),
                        if (summary.income != BigInt.zero)
                          Text(
                            '收入 ¥${formatMinor(summary.income)}',
                            maxLines: 1,
                            style: TextStyle(fontSize: 12, color: incomeColor),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.tonal(
            key: const Key('calendar-add-for-day'),
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: () =>
                context.push('/record/new?time=$selectedDayNoonMs'),
            child: const Text('+ 补记该日账单', maxLines: 1, softWrap: false),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectedDayHeader(
    BuildContext context,
    CalendarMonth month,
    AsyncValue<Map<int, CalendarDailySummary<LedgerRecord>>> summariesAsync,
    int selectedDay, {
    required int selectedDayNoonMs,
  }) {
    final theme = Theme.of(context);
    final isDesktop = DesktopAdaptive.isDesktop(context);
    final isDark = theme.brightness == Brightness.dark;
    final expenseColor = isDark ? Colors.red.shade300 : Colors.red.shade700;
    final incomeColor = isDark ? Colors.green.shade300 : Colors.green.shade700;
    final dayDt = DateTime(month.year, month.month, selectedDay);
    const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    final weekdayName = weekdays[(dayDt.weekday - 1) % 7];

    final summary =
        summariesAsync.value?[selectedDay]?.incomeExpense ?? IncomeExpense.zero;
    final hasDaySummary =
        summary.expense != BigInt.zero || summary.income != BigInt.zero;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Flexible(
            flex: hasDaySummary ? 0 : 1,
            child: Text(
              '${month.month}月$selectedDay日 $weekdayName',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          if (hasDaySummary) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (summary.expense != BigInt.zero)
                        Text(
                          '支出 ¥${formatMinor(summary.expense)}',
                          maxLines: 1,
                          style: TextStyle(fontSize: 12, color: expenseColor),
                        ),
                      if (summary.expense != BigInt.zero &&
                          summary.income != BigInt.zero)
                        const SizedBox(width: 8),
                      if (summary.income != BigInt.zero)
                        Text(
                          '收入 ¥${formatMinor(summary.income)}',
                          maxLines: 1,
                          style: TextStyle(fontSize: 12, color: incomeColor),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ] else if (isDesktop)
            const Spacer(),
          if (isDesktop) ...[
            const SizedBox(width: 8),
            FilledButton.tonal(
              key: const Key('calendar-compact-add-for-day'),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () =>
                  context.push('/record/new?time=$selectedDayNoonMs'),
              child: const Text(
                '+ 补记该日账单',
                maxLines: 1,
                softWrap: false,
                style: TextStyle(fontSize: 12),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSelectedDayRecords(
    BuildContext context,
    AsyncValue<Map<int, CalendarDailySummary<LedgerRecord>>> summariesAsync,
    int selectedDay,
    List<RecordCategory> categories,
    List<Asset> assets,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final incomeColor = isDark ? Colors.green.shade300 : Colors.green.shade700;
    return summariesAsync.when(
      data: (dailyMap) {
        final records = dailyMap[selectedDay]?.records ?? const [];
        if (records.isEmpty) {
          return const Center(child: Text('当日无账单'));
        }
        return ListView.builder(
          key: Key('calendar-day-records-$selectedDay'),
          itemCount: records.length,
          itemBuilder: (context, index) {
            final r = records[index];
            final label = recordLabel(r, categories, assets);
            final cat = r.recordCatId == noRef
                ? null
                : categories.where((c) => c.id == r.recordCatId).firstOrNull;
            final parentCat = (cat != null && cat.parentCatId != noRef)
                ? categories.where((c) => c.id == cat.parentCatId).firstOrNull
                : null;
            final catDisplayName = cat == null
                ? null
                : (parentCat != null
                      ? '${parentCat.name} · ${cat.name}'
                      : cat.name);
            final catColor = cat?.colorFill ?? parentCat?.colorFill;
            final isRefund =
                (r.type == RecordType.expense || r.type == RecordType.income) &&
                r.moneyMinor < BigInt.zero;
            return ListTile(
              key: Key('calendar-record-${r.recordId}'),
              leading: RecordTypeIconAvatar(
                recordType: r.type,
                subType: r.subType,
                isRefund: isRefund,
                categoryName: catDisplayName,
                categoryIcon: cat?.icon,
                parentCategoryIcon: parentCat?.icon,
                categoryColor: catColor,
              ),
              title: Text(
                label.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: label.subtitle.isEmpty
                  ? null
                  : Text(
                      label.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
              trailing: Text(
                label.amount,
                style: TextStyle(
                  color: r.type == RecordType.income ? incomeColor : null,
                  fontWeight: FontWeight.w600,
                ),
              ),
              onTap: () => context.push('/record/${r.recordId}'),
            );
          },
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => ErrorView(err),
    );
  }
}
