import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/ledger/asset_json.dart';
import '../../domain/rules/credit_cycle.dart';

/// Compact borderless pill button used next to period headers to jump back
/// to the active month (`回本月`) or active year (`回本年`).
class PeriodResetPill extends StatelessWidget {
  const PeriodResetPill({
    super.key,
    required this.label,
    required this.onTap,
    this.compact = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.secondaryContainer,
      borderRadius: BorderRadius.circular(999),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 7 : 10,
            vertical: 4,
          ),
          child: Text(
            label,
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

/// Shows a borderless rounded year-month picker dialog (`3×4` month grid with
/// quick prev/next year buttons and expandable scrollable year grid).
///
/// Pass [currentYear] and [currentMonth] when the caller uses a custom billing
/// period (e.g. `startDay != 1`) so the `本月` shortcut and current-month
/// highlight align with the active billing period rather than the raw calendar.
Future<({int year, int month})?> showYearMonthPickerDialog(
  BuildContext context, {
  required int initialYear,
  required int initialMonth,
  int? currentYear,
  int? currentMonth,
  int minYear = 2000,
  int maxYear = 2100,
}) {
  assert(minYear <= maxYear);
  final now = DateTime.now();
  final clampedYear = initialYear.clamp(minYear, maxYear);
  final clampedMonth = initialMonth.clamp(1, 12);
  final effectiveCurrentYear = currentYear ?? now.year;
  final effectiveCurrentMonth = (currentMonth ?? now.month).clamp(1, 12);
  return showDialog<({int year, int month})>(
    context: context,
    barrierDismissible: true,
    builder: (context) => _YearMonthPickerDialog(
      initialYear: clampedYear,
      initialMonth: clampedMonth,
      currentYear: effectiveCurrentYear,
      currentMonth: effectiveCurrentMonth,
      minYear: minYear,
      maxYear: maxYear,
    ),
  );
}

/// Shows a borderless rounded year-only picker dialog with a scrollable
/// year grid (`minYear..maxYear`) auto-scrolled near [initialYear].
///
/// Pass [currentYear] when the caller uses a custom billing year (e.g.
/// `BillingPeriod.containingYear`) so the `本年` shortcut and current-year
/// highlight align with the active billing year.
Future<int?> showYearOnlyPickerDialog(
  BuildContext context, {
  required int initialYear,
  int? currentYear,
  int minYear = 2000,
  int maxYear = 2100,
}) {
  assert(minYear <= maxYear);
  final clampedYear = initialYear.clamp(minYear, maxYear);
  final effectiveCurrentYear = currentYear ?? DateTime.now().year;
  return showDialog<int>(
    context: context,
    barrierDismissible: true,
    builder: (context) => _YearOnlyPickerDialog(
      initialYear: clampedYear,
      currentYear: effectiveCurrentYear,
      minYear: minYear,
      maxYear: maxYear,
    ),
  );
}

double _yearGridInitialOffset({
  required int targetYear,
  required int minYear,
  int crossAxisCount = 3,
  double tileHeight = 46,
  double mainAxisSpacing = 8,
  double leadingRows = 1.5,
}) {
  final index = math.max(0, targetYear - minYear);
  final row = index ~/ crossAxisCount;
  final rowExtent = tileHeight + mainAxisSpacing;
  return math.max(0.0, (row - leadingRows) * rowExtent);
}

class _YearMonthPickerDialog extends StatefulWidget {
  const _YearMonthPickerDialog({
    required this.initialYear,
    required this.initialMonth,
    required this.currentYear,
    required this.currentMonth,
    required this.minYear,
    required this.maxYear,
  });

  final int initialYear;
  final int initialMonth;
  final int currentYear;
  final int currentMonth;
  final int minYear;
  final int maxYear;

  @override
  State<_YearMonthPickerDialog> createState() => _YearMonthPickerDialogState();
}

class _YearMonthPickerDialogState extends State<_YearMonthPickerDialog> {
  static const double _tileHeight = 46;
  static const double _gridSpacing = 8;

  late int _browsingYear;
  bool _showingYearGrid = false;
  ScrollController? _yearScrollController;

  @override
  void initState() {
    super.initState();
    _browsingYear = widget.initialYear;
  }

  @override
  void dispose() {
    _yearScrollController?.dispose();
    super.dispose();
  }

  void _toggleYearGrid() {
    setState(() {
      _showingYearGrid = !_showingYearGrid;
      if (_showingYearGrid) {
        _yearScrollController?.dispose();
        _yearScrollController = ScrollController(
          initialScrollOffset: _yearGridInitialOffset(
            targetYear: _browsingYear,
            minYear: widget.minYear,
            tileHeight: _tileHeight,
            mainAxisSpacing: _gridSpacing,
          ),
        );
      }
    });
  }

  void _selectBrowsingYear(int year) {
    setState(() {
      _browsingYear = year;
      _showingYearGrid = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final currentYear = widget.currentYear;
    final currentMonth = widget.currentMonth;
    final canJumpCurrent =
        currentYear >= widget.minYear && currentYear <= widget.maxYear;
    final isAtCurrent =
        _browsingYear == currentYear &&
        widget.initialYear == currentYear &&
        widget.initialMonth == currentMonth;
    final yearCount = widget.maxYear - widget.minYear + 1;

    return Dialog(
      backgroundColor: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  IconButton(
                    key: const Key('ym-picker-prev-year'),
                    tooltip: '上一年',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 36,
                      height: 36,
                    ),
                    icon: const Icon(Icons.chevron_left_rounded),
                    onPressed: _browsingYear > widget.minYear
                        ? () => setState(() => _browsingYear -= 1)
                        : null,
                  ),
                  Expanded(
                    child: Center(
                      child: InkWell(
                        key: const Key('ym-picker-toggle-year-grid'),
                        borderRadius: BorderRadius.circular(10),
                        onTap: _toggleYearGrid,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              '$_browsingYear年',
                              maxLines: 1,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('ym-picker-next-year'),
                    tooltip: '下一年',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 36,
                      height: 36,
                    ),
                    icon: const Icon(Icons.chevron_right_rounded),
                    onPressed: _browsingYear < widget.maxYear
                        ? () => setState(() => _browsingYear += 1)
                        : null,
                  ),
                  if (canJumpCurrent && !isAtCurrent) ...[
                    const SizedBox(width: 4),
                    PeriodResetPill(
                      key: const Key('ym-picker-jump-current'),
                      label: '本月',
                      onTap: () => Navigator.of(
                        context,
                      ).pop((year: currentYear, month: currentMonth)),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              if (_showingYearGrid)
                SizedBox(
                  height: 236,
                  child: GridView.builder(
                    controller: _yearScrollController,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          mainAxisExtent: _tileHeight,
                          crossAxisSpacing: _gridSpacing,
                          mainAxisSpacing: _gridSpacing,
                        ),
                    itemCount: yearCount,
                    itemBuilder: (context, index) {
                      final year = widget.minYear + index;
                      final isSelected = year == _browsingYear;
                      final isCurrentYear = year == currentYear;
                      return _PickerGridTile(
                        key: Key('ym-picker-year-$year'),
                        label: '$year年',
                        isSelected: isSelected,
                        isCurrent: isCurrentYear,
                        onTap: () => _selectBrowsingYear(year),
                      );
                    },
                  ),
                )
              else
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisExtent: _tileHeight,
                    crossAxisSpacing: _gridSpacing,
                    mainAxisSpacing: _gridSpacing,
                  ),
                  itemCount: 12,
                  itemBuilder: (context, index) {
                    final month = index + 1;
                    final isSelected =
                        _browsingYear == widget.initialYear &&
                        month == widget.initialMonth;
                    final isCurrentMonth =
                        _browsingYear == currentYear && month == currentMonth;
                    return _PickerGridTile(
                      key: Key('ym-picker-month-$month'),
                      label: '$month月',
                      isSelected: isSelected,
                      isCurrent: isCurrentMonth,
                      onTap: () => Navigator.of(
                        context,
                      ).pop((year: _browsingYear, month: month)),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _YearOnlyPickerDialog extends StatefulWidget {
  const _YearOnlyPickerDialog({
    required this.initialYear,
    required this.currentYear,
    required this.minYear,
    required this.maxYear,
  });

  final int initialYear;
  final int currentYear;
  final int minYear;
  final int maxYear;

  @override
  State<_YearOnlyPickerDialog> createState() => _YearOnlyPickerDialogState();
}

class _YearOnlyPickerDialogState extends State<_YearOnlyPickerDialog> {
  static const double _tileHeight = 46;
  static const double _gridSpacing = 8;

  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController(
      initialScrollOffset: _yearGridInitialOffset(
        targetYear: widget.initialYear,
        minYear: widget.minYear,
        tileHeight: _tileHeight,
        mainAxisSpacing: _gridSpacing,
      ),
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final currentYear = widget.currentYear;
    final canJumpCurrent =
        currentYear >= widget.minYear && currentYear <= widget.maxYear;
    final showCurrentShortcut =
        canJumpCurrent && widget.initialYear != currentYear;
    final yearCount = widget.maxYear - widget.minYear + 1;

    return Dialog(
      backgroundColor: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '选择年份',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  if (showCurrentShortcut) ...[
                    const SizedBox(width: 8),
                    PeriodResetPill(
                      key: const Key('y-picker-jump-current'),
                      label: '本年',
                      onTap: () => Navigator.of(context).pop(currentYear),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 256,
                child: GridView.builder(
                  controller: _scrollController,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisExtent: _tileHeight,
                    crossAxisSpacing: _gridSpacing,
                    mainAxisSpacing: _gridSpacing,
                  ),
                  itemCount: yearCount,
                  itemBuilder: (context, index) {
                    final year = widget.minYear + index;
                    final isSelected = year == widget.initialYear;
                    final isCurrentYear = year == currentYear;
                    return _PickerGridTile(
                      key: Key('y-picker-year-$year'),
                      label: '$year年',
                      isSelected: isSelected,
                      isCurrent: isCurrentYear,
                      onTap: () => Navigator.of(context).pop(year),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PickerGridTile extends StatelessWidget {
  const _PickerGridTile({
    super.key,
    required this.label,
    required this.isSelected,
    required this.isCurrent,
    required this.onTap,
  });

  final String label;
  final bool isSelected;
  final bool isCurrent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final Color bgColor;
    final Color fgColor;
    final FontWeight fontWeight;

    if (isSelected) {
      bgColor = scheme.primary;
      fgColor = scheme.onPrimary;
      fontWeight = FontWeight.bold;
    } else if (isCurrent) {
      bgColor = scheme.primaryContainer;
      fgColor = scheme.onPrimaryContainer;
      fontWeight = FontWeight.w600;
    } else {
      bgColor = scheme.surfaceContainer;
      fgColor = scheme.onSurface;
      fontWeight = FontWeight.w500;
    }

    return Material(
      color: bgColor,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                maxLines: 1,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: fgColor,
                  fontWeight: fontWeight,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _twoDigits(int v) => v.toString().padLeft(2, '0');

/// Shows a borderless rounded credit statement period picker dialog (`3×4`
/// grid of `第1期`..`第12期` with compact `MM/DD~MM/DD` date range, quick
/// prev/next year buttons, and expandable scrollable year grid).
Future<CreditStatementPeriod?> showCreditPeriodPickerDialog(
  BuildContext context, {
  required CreditInfo creditInfo,
  required int initialYear,
  required int initialPeriodIndex,
  DateTime? today,
  int minYear = 2000,
  int maxYear = 2100,
}) {
  assert(minYear <= maxYear);
  final effectiveToday = today ?? DateTime.now();
  final clampedYear = initialYear.clamp(minYear, maxYear);
  final clampedPeriod = initialPeriodIndex.clamp(1, 12);
  final currentPeriod = currentCreditPeriodForToday(
    creditInfo: creditInfo,
    today: effectiveToday,
  );
  return showDialog<CreditStatementPeriod>(
    context: context,
    barrierDismissible: true,
    builder: (context) => _CreditPeriodPickerDialog(
      creditInfo: creditInfo,
      initialYear: clampedYear,
      initialPeriodIndex: clampedPeriod,
      currentPeriod: currentPeriod,
      minYear: minYear,
      maxYear: maxYear,
    ),
  );
}

class _CreditPeriodPickerDialog extends StatefulWidget {
  const _CreditPeriodPickerDialog({
    required this.creditInfo,
    required this.initialYear,
    required this.initialPeriodIndex,
    required this.currentPeriod,
    required this.minYear,
    required this.maxYear,
  });

  final CreditInfo creditInfo;
  final int initialYear;
  final int initialPeriodIndex;
  final CreditStatementPeriod currentPeriod;
  final int minYear;
  final int maxYear;

  @override
  State<_CreditPeriodPickerDialog> createState() =>
      _CreditPeriodPickerDialogState();
}

class _CreditPeriodPickerDialogState extends State<_CreditPeriodPickerDialog> {
  static const double _yearTileHeight = 46;
  static const double _periodTileHeight = 56;
  static const double _gridSpacing = 8;

  late int _browsingYear;
  bool _showingYearGrid = false;
  ScrollController? _yearScrollController;

  @override
  void initState() {
    super.initState();
    _browsingYear = widget.initialYear;
  }

  @override
  void dispose() {
    _yearScrollController?.dispose();
    super.dispose();
  }

  void _toggleYearGrid() {
    setState(() {
      _showingYearGrid = !_showingYearGrid;
      if (_showingYearGrid) {
        _yearScrollController?.dispose();
        _yearScrollController = ScrollController(
          initialScrollOffset: _yearGridInitialOffset(
            targetYear: _browsingYear,
            minYear: widget.minYear,
            tileHeight: _yearTileHeight,
            mainAxisSpacing: _gridSpacing,
          ),
        );
      }
    });
  }

  void _selectBrowsingYear(int year) {
    setState(() {
      _browsingYear = year;
      _showingYearGrid = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final current = widget.currentPeriod;
    final canJumpCurrent =
        current.year >= widget.minYear && current.year <= widget.maxYear;
    final isAtCurrent =
        _browsingYear == current.year &&
        widget.initialYear == current.year &&
        widget.initialPeriodIndex == current.periodIndex;
    final yearCount = widget.maxYear - widget.minYear + 1;

    return Dialog(
      backgroundColor: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  IconButton(
                    key: const Key('cp-picker-prev-year'),
                    tooltip: '上一年',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 36,
                      height: 36,
                    ),
                    icon: const Icon(Icons.chevron_left_rounded),
                    onPressed: _browsingYear > widget.minYear
                        ? () => setState(() => _browsingYear -= 1)
                        : null,
                  ),
                  Expanded(
                    child: Center(
                      child: InkWell(
                        key: const Key('cp-picker-toggle-year-grid'),
                        borderRadius: BorderRadius.circular(10),
                        onTap: _toggleYearGrid,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              '$_browsingYear年',
                              maxLines: 1,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('cp-picker-next-year'),
                    tooltip: '下一年',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 36,
                      height: 36,
                    ),
                    icon: const Icon(Icons.chevron_right_rounded),
                    onPressed: _browsingYear < widget.maxYear
                        ? () => setState(() => _browsingYear += 1)
                        : null,
                  ),
                  if (canJumpCurrent && !isAtCurrent) ...[
                    const SizedBox(width: 4),
                    PeriodResetPill(
                      key: const Key('cp-picker-jump-current'),
                      label: '当期',
                      onTap: () => Navigator.of(context).pop(current),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              if (_showingYearGrid)
                SizedBox(
                  height: 236,
                  child: GridView.builder(
                    controller: _yearScrollController,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          mainAxisExtent: _yearTileHeight,
                          crossAxisSpacing: _gridSpacing,
                          mainAxisSpacing: _gridSpacing,
                        ),
                    itemCount: yearCount,
                    itemBuilder: (context, index) {
                      final year = widget.minYear + index;
                      final isSelected = year == _browsingYear;
                      final isCurrentYear = year == current.year;
                      return _PickerGridTile(
                        key: Key('cp-picker-year-$year'),
                        label: '$year年',
                        isSelected: isSelected,
                        isCurrent: isCurrentYear,
                        onTap: () => _selectBrowsingYear(year),
                      );
                    },
                  ),
                )
              else
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisExtent: _periodTileHeight,
                    crossAxisSpacing: _gridSpacing,
                    mainAxisSpacing: _gridSpacing,
                  ),
                  itemCount: 12,
                  itemBuilder: (context, index) {
                    final periodIndex = index + 1;
                    final period = computePeriod(
                      year: _browsingYear,
                      month: periodIndex,
                      billDay: widget.creditInfo.billDay,
                      repaymentDay: widget.creditInfo.repaymentDay,
                      repaymentAfterBillDay:
                          widget.creditInfo.repaymentAfterBillDay,
                      billDayCounted: widget.creditInfo.billDayCounted,
                    );
                    final isSelected =
                        _browsingYear == widget.initialYear &&
                        periodIndex == widget.initialPeriodIndex;
                    final isCurrentPeriod =
                        _browsingYear == current.year &&
                        periodIndex == current.periodIndex;
                    final rangeLabel =
                        '${_twoDigits(period.start.month)}/${_twoDigits(period.start.day)}'
                        '~${_twoDigits(period.end.month)}/${_twoDigits(period.end.day)}';
                    return _CreditPeriodGridTile(
                      key: Key('cp-picker-period-$periodIndex'),
                      title: '第$periodIndex期',
                      rangeLabel: rangeLabel,
                      isSelected: isSelected,
                      isCurrent: isCurrentPeriod,
                      onTap: () => Navigator.of(context).pop(period),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CreditPeriodGridTile extends StatelessWidget {
  const _CreditPeriodGridTile({
    super.key,
    required this.title,
    required this.rangeLabel,
    required this.isSelected,
    required this.isCurrent,
    required this.onTap,
  });

  final String title;
  final String rangeLabel;
  final bool isSelected;
  final bool isCurrent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final Color bgColor;
    final Color fgColor;
    final Color subColor;
    final FontWeight fontWeight;

    if (isSelected) {
      bgColor = scheme.primary;
      fgColor = scheme.onPrimary;
      subColor = scheme.onPrimary.withValues(alpha: 0.85);
      fontWeight = FontWeight.bold;
    } else if (isCurrent) {
      bgColor = scheme.primaryContainer;
      fgColor = scheme.onPrimaryContainer;
      subColor = scheme.onPrimaryContainer.withValues(alpha: 0.8);
      fontWeight = FontWeight.w600;
    } else {
      bgColor = scheme.surfaceContainer;
      fgColor = scheme.onSurface;
      subColor = scheme.onSurfaceVariant;
      fontWeight = FontWeight.w500;
    }

    return Material(
      color: bgColor,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    softWrap: false,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: fgColor,
                      fontWeight: fontWeight,
                      height: 1.15,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    rangeLabel,
                    maxLines: 1,
                    softWrap: false,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: subColor,
                      fontSize: 10.5,
                      height: 1.1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shared 34dp tonal year-switcher capsule placed on the right side of the
/// pinned account detail control bar when viewing monthly / credit statements.
///
/// Matches the 34dp height and border radius of the left dual-tab capsule,
/// renders no dropdown arrow icons, and shows a compact reset pill to its left
/// whenever [selectedYear] differs from [currentYear].
class StickyStatementYearSwitcher extends StatelessWidget {
  const StickyStatementYearSwitcher({
    super.key,
    required this.selectedYear,
    required this.onYearChanged,
    this.currentYear,
    this.minYear = 2000,
    this.maxYear = 2100,
    this.compact = false,
  });

  final int selectedYear;
  final ValueChanged<int> onYearChanged;
  final int? currentYear;
  final int minYear;
  final int maxYear;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final effectiveCurrentYear = currentYear ?? DateTime.now().year;
    final showReset = selectedYear != effectiveCurrentYear;
    final canPrev = selectedYear > minYear;
    final canNext = selectedYear < maxYear;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showReset) ...[
          PeriodResetPill(
            key: const Key('statement-year-reset'),
            label: compact ? '今年' : '回今年',
            compact: compact,
            onTap: () => onYearChanged(effectiveCurrentYear),
          ),
          SizedBox(width: compact ? 4 : 6),
        ],
        Container(
          height: 34,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(10),
          ),
          clipBehavior: Clip.antiAlias,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Tooltip(
                message: '上一年',
                child: InkWell(
                  key: const Key('statement-year-prev'),
                  onTap: canPrev ? () => onYearChanged(selectedYear - 1) : null,
                  child: SizedBox(
                    width: compact ? 24 : 28,
                    height: 34,
                    child: Icon(
                      Icons.chevron_left_rounded,
                      size: 18,
                      color: canPrev
                          ? scheme.onSurface
                          : scheme.onSurface.withValues(alpha: 0.35),
                    ),
                  ),
                ),
              ),
              InkWell(
                key: const Key('statement-year-label'),
                borderRadius: BorderRadius.circular(6),
                onTap: () async {
                  final picked = await showYearOnlyPickerDialog(
                    context,
                    initialYear: selectedYear,
                    currentYear: effectiveCurrentYear,
                    minYear: minYear,
                    maxYear: maxYear,
                  );
                  if (picked != null) {
                    onYearChanged(picked);
                  }
                },
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: compact ? 3 : 5),
                  child: Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        '$selectedYear年',
                        maxLines: 1,
                        softWrap: false,
                        style:
                            (compact
                                    ? theme.textTheme.labelMedium
                                    : theme.textTheme.labelLarge)
                                ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ),
              ),
              Tooltip(
                message: '下一年',
                child: InkWell(
                  key: const Key('statement-year-next'),
                  onTap: canNext ? () => onYearChanged(selectedYear + 1) : null,
                  child: SizedBox(
                    width: compact ? 24 : 28,
                    height: 34,
                    child: Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: canNext
                          ? scheme.onSurface
                          : scheme.onSurface.withValues(alpha: 0.35),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
