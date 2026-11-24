import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Compact borderless pill button used next to period headers to jump back
/// to the active month (`回本月`) or active year (`回本年`).
class PeriodResetPill extends StatelessWidget {
  const PeriodResetPill({super.key, required this.label, required this.onTap});

  final String label;
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
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
