import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Result returned when confirming [RecordDateTimeDialog].
final class RecordDateTimeDialogResult {
  const RecordDateTimeDialogResult({
    required this.dateTime,
    required this.dateWheelStyle,
    required this.timeDialStyle,
  });

  final DateTime dateTime;
  final bool dateWheelStyle;
  final bool timeDialStyle;
}

/// Shows the unified thumb-friendly dual-mode (Date ⇄ Time) and dual-style
/// (Calendar ⇄ 3-Col Wheel, 2-Col Wheel ⇄ 24h Clock Dial) date-time dialog.
Future<RecordDateTimeDialogResult?> showRecordDateTimeDialog({
  required BuildContext context,
  required DateTime initialDateTime,
  DateTime? firstDate,
  DateTime? lastDate,
  bool initialDateWheelStyle = false,
  bool initialTimeDialStyle = false,
  void Function({required bool dateWheelStyle, required bool timeDialStyle})?
  onStyleChanged,
}) => showDialog<RecordDateTimeDialogResult>(
  context: context,
  builder: (_) => RecordDateTimeDialog(
    initialDateTime: initialDateTime,
    firstDate: firstDate,
    lastDate: lastDate,
    initialDateWheelStyle: initialDateWheelStyle,
    initialTimeDialStyle: initialTimeDialStyle,
    onStyleChanged: onStyleChanged,
  ),
);

enum _PickerMode { date, time }

enum _DialUnit { hour, minute }

String _two(int v) => v.toString().padLeft(2, '0');

const List<String> _weekdayHeaders = <String>[
  '一',
  '二',
  '三',
  '四',
  '五',
  '六',
  '日',
];

const List<String> _weekdayFullLabels = <String>[
  '周一',
  '周二',
  '周三',
  '周四',
  '周五',
  '周六',
  '周日',
];

/// Borderless Material 3 date-time dialog with bottom-right thumb-zone
/// Date ⇄ Time switching and user-toggleable styles for both Date and Time.
class RecordDateTimeDialog extends StatefulWidget {
  const RecordDateTimeDialog({
    super.key,
    required this.initialDateTime,
    this.firstDate,
    this.lastDate,
    this.initialDateWheelStyle = false,
    this.initialTimeDialStyle = false,
    this.onStyleChanged,
  });

  final DateTime initialDateTime;
  final DateTime? firstDate;
  final DateTime? lastDate;
  final bool initialDateWheelStyle;
  final bool initialTimeDialStyle;
  final void Function({
    required bool dateWheelStyle,
    required bool timeDialStyle,
  })?
  onStyleChanged;

  @override
  State<RecordDateTimeDialog> createState() => _RecordDateTimeDialogState();
}

class _RecordDateTimeDialogState extends State<RecordDateTimeDialog> {
  static const double _wheelItemExtent = 40.0;
  static const double _wheelViewportHeight = 200.0;

  late final DateTime _firstDay;
  late final DateTime _lastDay;

  _PickerMode _mode = _PickerMode.date;
  _DialUnit _dialUnit = _DialUnit.hour;
  bool _dialKeyboardInput = false;

  late bool _dateWheelStyle;
  late bool _timeDialStyle;

  late int _year;
  late int _month;
  late int _day;
  late int _hour;
  late int _minute;

  late int _displayedYear;
  late int _displayedMonth;

  FixedExtentScrollController? _yearCtrl;
  FixedExtentScrollController? _monthCtrl;
  FixedExtentScrollController? _dayCtrl;
  FixedExtentScrollController? _hourCtrl;
  FixedExtentScrollController? _minuteCtrl;
  bool _suppressDateWheelCallbacks = false;
  bool _suppressTimeWheelCallbacks = false;

  late final TextEditingController _hourInputCtrl;
  late final TextEditingController _minuteInputCtrl;
  late final FocusNode _hourInputFocus;
  late final FocusNode _minuteInputFocus;

  @override
  void initState() {
    super.initState();
    final rawFirst = widget.firstDate ?? DateTime(2000);
    final rawLast = widget.lastDate ?? DateTime(2100, 12, 31);
    final normalizedFirst = DateTime(
      rawFirst.year,
      rawFirst.month,
      rawFirst.day,
    );
    final normalizedLast = DateTime(rawLast.year, rawLast.month, rawLast.day);
    if (normalizedLast.isBefore(normalizedFirst)) {
      _firstDay = normalizedLast;
      _lastDay = normalizedFirst;
    } else {
      _firstDay = normalizedFirst;
      _lastDay = normalizedLast;
    }

    final clampedDate = _clampDate(
      widget.initialDateTime.year,
      widget.initialDateTime.month,
      widget.initialDateTime.day,
    );
    _year = clampedDate.year;
    _month = clampedDate.month;
    _day = clampedDate.day;
    _hour = widget.initialDateTime.hour.clamp(0, 23);
    _minute = widget.initialDateTime.minute.clamp(0, 59);

    _displayedYear = _year;
    _displayedMonth = _month;

    _dateWheelStyle = widget.initialDateWheelStyle;
    _timeDialStyle = widget.initialTimeDialStyle;

    _hourInputCtrl = TextEditingController(text: _two(_hour));
    _minuteInputCtrl = TextEditingController(text: _two(_minute));
    _hourInputFocus = FocusNode()..addListener(_onHourInputFocusChanged);
    _minuteInputFocus = FocusNode()..addListener(_onMinuteInputFocusChanged);

    _recreateDateWheelControllers();
    _recreateTimeWheelControllers();
  }

  @override
  void dispose() {
    _yearCtrl?.dispose();
    _monthCtrl?.dispose();
    _dayCtrl?.dispose();
    _hourCtrl?.dispose();
    _minuteCtrl?.dispose();
    _hourInputFocus
      ..removeListener(_onHourInputFocusChanged)
      ..dispose();
    _minuteInputFocus
      ..removeListener(_onMinuteInputFocusChanged)
      ..dispose();
    _hourInputCtrl.dispose();
    _minuteInputCtrl.dispose();
    super.dispose();
  }

  void _onHourInputFocusChanged() {
    if (!_hourInputFocus.hasFocus && mounted) {
      _commitKeyboardInputs(formatFields: true);
    }
  }

  void _onMinuteInputFocusChanged() {
    if (!_minuteInputFocus.hasFocus && mounted) {
      _commitKeyboardInputs(formatFields: true);
    }
  }

  DateTime _clampDate(int year, int month, int day) {
    final safeMonth = month.clamp(1, 12);
    final maxDays = DateUtils.getDaysInMonth(year, safeMonth);
    final safeDay = math.min(math.max(1, day), maxDays);
    final candidate = DateTime(year, safeMonth, safeDay);
    if (candidate.isBefore(_firstDay)) return _firstDay;
    if (candidate.isAfter(_lastDay)) return _lastDay;
    return candidate;
  }

  void _recreateDateWheelControllers() {
    _yearCtrl?.dispose();
    _monthCtrl?.dispose();
    _dayCtrl?.dispose();
    _yearCtrl = FixedExtentScrollController(
      initialItem: (_year - _firstDay.year).clamp(
        0,
        _lastDay.year - _firstDay.year,
      ),
    );
    _monthCtrl = FixedExtentScrollController(initialItem: _month - 1);
    _dayCtrl = FixedExtentScrollController(initialItem: _day - 1);
  }

  void _recreateTimeWheelControllers() {
    _hourCtrl?.dispose();
    _minuteCtrl?.dispose();
    _hourCtrl = FixedExtentScrollController(initialItem: _hour);
    _minuteCtrl = FixedExtentScrollController(initialItem: _minute);
  }

  void _syncDateWheelControllersToDraft({required int previousMaxDays}) {
    final targetYearIdx = _year - _firstDay.year;
    final targetMonthIdx = _month - 1;
    final targetDayIdx = _day - 1;

    _suppressDateWheelCallbacks = true;
    try {
      if (_yearCtrl != null &&
          _yearCtrl!.hasClients &&
          _yearCtrl!.selectedItem != targetYearIdx) {
        _yearCtrl!.jumpToItem(targetYearIdx);
      }
      if (_monthCtrl != null &&
          _monthCtrl!.hasClients &&
          _monthCtrl!.selectedItem != targetMonthIdx) {
        _monthCtrl!.jumpToItem(targetMonthIdx);
      }
      if (_dayCtrl != null &&
          _dayCtrl!.hasClients &&
          targetDayIdx < previousMaxDays &&
          _dayCtrl!.selectedItem != targetDayIdx) {
        _dayCtrl!.jumpToItem(targetDayIdx);
      }
    } finally {
      _suppressDateWheelCallbacks = false;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _mode != _PickerMode.date || !_dateWheelStyle) return;
      _suppressDateWheelCallbacks = true;
      try {
        if (_yearCtrl != null &&
            _yearCtrl!.hasClients &&
            _yearCtrl!.selectedItem != _year - _firstDay.year) {
          _yearCtrl!.jumpToItem(_year - _firstDay.year);
        }
        if (_monthCtrl != null &&
            _monthCtrl!.hasClients &&
            _monthCtrl!.selectedItem != _month - 1) {
          _monthCtrl!.jumpToItem(_month - 1);
        }
        if (_dayCtrl != null &&
            _dayCtrl!.hasClients &&
            _dayCtrl!.selectedItem != _day - 1) {
          _dayCtrl!.jumpToItem(_day - 1);
        }
      } finally {
        _suppressDateWheelCallbacks = false;
      }
    });
  }

  void _applyDateWheelChange({int? year, int? month, int? day}) {
    if (_suppressDateWheelCallbacks) return;
    final prevMaxDays = DateUtils.getDaysInMonth(_year, _month);
    final next = _clampDate(year ?? _year, month ?? _month, day ?? _day);
    setState(() {
      _year = next.year;
      _month = next.month;
      _day = next.day;
      _displayedYear = _year;
      _displayedMonth = _month;
    });
    _syncDateWheelControllersToDraft(previousMaxDays: prevMaxDays);
  }

  void _commitKeyboardInputs({required bool formatFields}) {
    final rawH = _hourInputCtrl.text.trim();
    final rawM = _minuteInputCtrl.text.trim();
    var nextHour = _hour;
    var nextMinute = _minute;
    if (rawH.isNotEmpty) {
      final parsedH = int.tryParse(rawH);
      if (parsedH != null) nextHour = parsedH.clamp(0, 23);
    }
    if (rawM.isNotEmpty) {
      final parsedM = int.tryParse(rawM);
      if (parsedM != null) nextMinute = parsedM.clamp(0, 59);
    }
    if (nextHour != _hour || nextMinute != _minute) {
      setState(() {
        _hour = nextHour;
        _minute = nextMinute;
      });
    }
    if (formatFields) {
      final hText = _two(_hour);
      final mText = _two(_minute);
      if (_hourInputCtrl.text != hText) {
        _hourInputCtrl.value = TextEditingValue(
          text: hText,
          selection: TextSelection.collapsed(offset: hText.length),
        );
      }
      if (_minuteInputCtrl.text != mText) {
        _minuteInputCtrl.value = TextEditingValue(
          text: mText,
          selection: TextSelection.collapsed(offset: mText.length),
        );
      }
    }
  }

  void _syncInputsFromTime() {
    _hourInputCtrl.text = _two(_hour);
    _minuteInputCtrl.text = _two(_minute);
  }

  void _toggleMode() {
    FocusScope.of(context).unfocus();
    if (_mode == _PickerMode.time && _timeDialStyle && _dialKeyboardInput) {
      _commitKeyboardInputs(formatFields: true);
    }
    setState(() {
      if (_mode == _PickerMode.date) {
        _mode = _PickerMode.time;
        _dialUnit = _DialUnit.hour;
        _dialKeyboardInput = false;
        _syncInputsFromTime();
        _recreateTimeWheelControllers();
      } else {
        _mode = _PickerMode.date;
        _displayedYear = _year;
        _displayedMonth = _month;
        _recreateDateWheelControllers();
      }
    });
  }

  void _toggleStyle() {
    FocusScope.of(context).unfocus();
    if (_mode == _PickerMode.time && _timeDialStyle && _dialKeyboardInput) {
      _commitKeyboardInputs(formatFields: true);
    }
    setState(() {
      if (_mode == _PickerMode.date) {
        _dateWheelStyle = !_dateWheelStyle;
        _displayedYear = _year;
        _displayedMonth = _month;
        if (_dateWheelStyle) {
          _recreateDateWheelControllers();
        }
      } else {
        _timeDialStyle = !_timeDialStyle;
        _dialUnit = _DialUnit.hour;
        _dialKeyboardInput = false;
        _syncInputsFromTime();
        if (!_timeDialStyle) {
          _recreateTimeWheelControllers();
        }
      }
    });
    widget.onStyleChanged?.call(
      dateWheelStyle: _dateWheelStyle,
      timeDialStyle: _timeDialStyle,
    );
  }

  void _confirm() {
    if (_mode == _PickerMode.time && _timeDialStyle && _dialKeyboardInput) {
      _commitKeyboardInputs(formatFields: false);
    }
    Navigator.of(context).pop(
      RecordDateTimeDialogResult(
        dateTime: DateTime(_year, _month, _day, _hour, _minute),
        dateWheelStyle: _dateWheelStyle,
        timeDialStyle: _timeDialStyle,
      ),
    );
  }

  bool get _canGoPrevMonth {
    final currentMonthStart = DateTime(_displayedYear, _displayedMonth);
    final firstMonthStart = DateTime(_firstDay.year, _firstDay.month);
    return currentMonthStart.isAfter(firstMonthStart);
  }

  bool get _canGoNextMonth {
    final currentMonthStart = DateTime(_displayedYear, _displayedMonth);
    final lastMonthStart = DateTime(_lastDay.year, _lastDay.month);
    return currentMonthStart.isBefore(lastMonthStart);
  }

  void _stepDisplayedMonth(int deltaMonths) {
    final target = DateTime(_displayedYear, _displayedMonth + deltaMonths);
    final firstMonthStart = DateTime(_firstDay.year, _firstDay.month);
    final lastMonthStart = DateTime(_lastDay.year, _lastDay.month);
    if (target.isBefore(firstMonthStart) || target.isAfter(lastMonthStart)) {
      return;
    }
    setState(() {
      _displayedYear = target.year;
      _displayedMonth = target.month;
    });
  }

  Widget _buildCalendarView(BuildContext context, ColorScheme cs, bool isDark) {
    final selectedDate = DateTime(_year, _month, _day);
    final weekdayText = _weekdayFullLabels[selectedDate.weekday - 1];
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    final firstOfMonth = DateTime(_displayedYear, _displayedMonth);
    final leadingEmpty = firstOfMonth.weekday - 1; // Mon=0 .. Sun=6
    final daysInMonth = DateUtils.getDaysInMonth(
      _displayedYear,
      _displayedMonth,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$_year年',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: cs.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '$_month月$_day日 $weekdayText',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            IconButton(
              key: const Key('datetime-prev-month'),
              visualDensity: VisualDensity.compact,
              tooltip: '上个月',
              onPressed: _canGoPrevMonth ? () => _stepDisplayedMonth(-1) : null,
              icon: const Icon(Icons.chevron_left_rounded, size: 22),
            ),
            Expanded(
              child: Center(
                child: Text(
                  '$_displayedYear年$_displayedMonth月',
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
            IconButton(
              key: const Key('datetime-next-month'),
              visualDensity: VisualDensity.compact,
              tooltip: '下个月',
              onPressed: _canGoNextMonth ? () => _stepDisplayedMonth(1) : null,
              icon: const Icon(Icons.chevron_right_rounded, size: 22),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Row(
          children: [
            for (final label in _weekdayHeaders)
              Expanded(
                child: Center(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Column(
          key: const Key('datetime-calendar-grid'),
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var row = 0; row < 6; row++)
              SizedBox(
                height: 36,
                child: Row(
                  children: [
                    for (var col = 0; col < 7; col++)
                      Expanded(
                        child: _buildDayCell(
                          cs: cs,
                          isDark: isDark,
                          cellIndex: row * 7 + col,
                          leadingEmpty: leadingEmpty,
                          daysInMonth: daysInMonth,
                          today: today,
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildDayCell({
    required ColorScheme cs,
    required bool isDark,
    required int cellIndex,
    required int leadingEmpty,
    required int daysInMonth,
    required DateTime today,
  }) {
    final day = cellIndex - leadingEmpty + 1;
    if (day < 1 || day > daysInMonth) {
      return const SizedBox.shrink();
    }

    final cellDate = DateTime(_displayedYear, _displayedMonth, day);
    final isDisabled =
        cellDate.isBefore(_firstDay) || cellDate.isAfter(_lastDay);
    final isSelected =
        _displayedYear == _year && _displayedMonth == _month && day == _day;
    final isToday = cellDate == today;

    Color? fillColor;
    Color textColor;
    FontWeight fontWeight = FontWeight.w500;

    if (isSelected) {
      fillColor = cs.primary;
      textColor = cs.onPrimary;
      fontWeight = FontWeight.w700;
    } else if (isDisabled) {
      fillColor = null;
      textColor = cs.onSurface.withAlpha(70);
    } else if (isToday) {
      fillColor = isDark
          ? cs.secondaryContainer.withAlpha(140)
          : cs.primaryContainer.withAlpha(150);
      textColor = cs.primary;
      fontWeight = FontWeight.w700;
    } else {
      fillColor = null;
      textColor = cs.onSurface;
    }

    return Center(
      child: SizedBox(
        width: 34,
        height: 34,
        child: Material(
          color: fillColor ?? Colors.transparent,
          shape: const CircleBorder(side: BorderSide.none),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: Key('datetime-day-$day'),
            customBorder: const CircleBorder(),
            onTap: isDisabled
                ? null
                : () {
                    setState(() {
                      _year = _displayedYear;
                      _month = _displayedMonth;
                      _day = day;
                    });
                  },
            child: Center(
              child: Text(
                '$day',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: fontWeight,
                  color: textColor,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildWheelHighlightBand(ColorScheme cs, bool isDark) => IgnorePointer(
    child: Center(
      child: Container(
        height: _wheelItemExtent,
        decoration: BoxDecoration(
          color: isDark
              ? cs.surfaceContainerHighest.withAlpha(175)
              : cs.secondaryContainer.withAlpha(120),
          borderRadius: BorderRadius.circular(10),
        ),
      ),
    ),
  );

  Widget _buildDateWheelView(
    BuildContext context,
    ColorScheme cs,
    bool isDark,
  ) {
    final yearCount = _lastDay.year - _firstDay.year + 1;
    final maxDays = DateUtils.getDaysInMonth(_year, _month);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Center(
          child: Text(
            '选择日期',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: cs.onSurface,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            for (final unit in const ['年', '月', '日'])
              Expanded(
                child: Center(
                  child: Text(
                    unit,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        SizedBox(
          key: const Key('datetime-date-wheel'),
          height: _wheelViewportHeight,
          child: Stack(
            alignment: Alignment.center,
            children: [
              _buildWheelHighlightBand(cs, isDark),
              Row(
                children: [
                  Expanded(
                    flex: 5,
                    child: ListWheelScrollView.useDelegate(
                      key: const Key('datetime-wheel-year'),
                      controller: _yearCtrl,
                      itemExtent: _wheelItemExtent,
                      diameterRatio: 1.45,
                      perspective: 0.003,
                      physics: const FixedExtentScrollPhysics(),
                      onSelectedItemChanged: (idx) =>
                          _applyDateWheelChange(year: _firstDay.year + idx),
                      childDelegate: ListWheelChildBuilderDelegate(
                        childCount: yearCount,
                        builder: (context, index) {
                          if (index < 0 || index >= yearCount) return null;
                          final y = _firstDay.year + index;
                          final selected = y == _year;
                          return _buildWheelItem(
                            cs: cs,
                            text: '$y',
                            selected: selected,
                            disabled: false,
                            onTap: () => _yearCtrl?.animateToItem(
                              index,
                              duration: const Duration(milliseconds: 160),
                              curve: Curves.easeOutCubic,
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 4,
                    child: ListWheelScrollView.useDelegate(
                      key: const Key('datetime-wheel-month'),
                      controller: _monthCtrl,
                      itemExtent: _wheelItemExtent,
                      diameterRatio: 1.45,
                      perspective: 0.003,
                      physics: const FixedExtentScrollPhysics(),
                      onSelectedItemChanged: (idx) =>
                          _applyDateWheelChange(month: idx + 1),
                      childDelegate: ListWheelChildBuilderDelegate(
                        childCount: 12,
                        builder: (context, index) {
                          if (index < 0 || index >= 12) return null;
                          final m = index + 1;
                          final selected = m == _month;
                          final monthEnd = DateTime(
                            _year,
                            m,
                            DateUtils.getDaysInMonth(_year, m),
                          );
                          final monthStart = DateTime(_year, m, 1);
                          final disabled =
                              monthEnd.isBefore(_firstDay) ||
                              monthStart.isAfter(_lastDay);
                          return _buildWheelItem(
                            cs: cs,
                            text: _two(m),
                            selected: selected,
                            disabled: disabled,
                            onTap: disabled
                                ? null
                                : () => _monthCtrl?.animateToItem(
                                    index,
                                    duration: const Duration(milliseconds: 160),
                                    curve: Curves.easeOutCubic,
                                  ),
                          );
                        },
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 4,
                    child: ListWheelScrollView.useDelegate(
                      key: const Key('datetime-wheel-day'),
                      controller: _dayCtrl,
                      itemExtent: _wheelItemExtent,
                      diameterRatio: 1.45,
                      perspective: 0.003,
                      physics: const FixedExtentScrollPhysics(),
                      onSelectedItemChanged: (idx) =>
                          _applyDateWheelChange(day: idx + 1),
                      childDelegate: ListWheelChildBuilderDelegate(
                        childCount: maxDays,
                        builder: (context, index) {
                          if (index < 0 || index >= maxDays) return null;
                          final d = index + 1;
                          final selected = d == _day;
                          final candidate = DateTime(_year, _month, d);
                          final disabled =
                              candidate.isBefore(_firstDay) ||
                              candidate.isAfter(_lastDay);
                          return _buildWheelItem(
                            cs: cs,
                            text: _two(d),
                            selected: selected,
                            disabled: disabled,
                            onTap: disabled
                                ? null
                                : () => _dayCtrl?.animateToItem(
                                    index,
                                    duration: const Duration(milliseconds: 160),
                                    curve: Curves.easeOutCubic,
                                  ),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTimeWheelView(
    BuildContext context,
    ColorScheme cs,
    bool isDark,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Center(
          child: Text(
            '选择时间',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: cs.onSurface,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Center(
                child: Text(
                  '时',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 24),
            Expanded(
              child: Center(
                child: Text(
                  '分',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        SizedBox(
          key: const Key('datetime-time-wheel'),
          height: _wheelViewportHeight,
          child: Stack(
            alignment: Alignment.center,
            children: [
              _buildWheelHighlightBand(cs, isDark),
              Row(
                children: [
                  Expanded(
                    child: ListWheelScrollView.useDelegate(
                      key: const Key('datetime-wheel-hour'),
                      controller: _hourCtrl,
                      itemExtent: _wheelItemExtent,
                      diameterRatio: 1.45,
                      perspective: 0.003,
                      physics: const FixedExtentScrollPhysics(),
                      onSelectedItemChanged: (idx) {
                        if (_suppressTimeWheelCallbacks) return;
                        setState(() {
                          _hour = idx.clamp(0, 23);
                          _syncInputsFromTime();
                        });
                      },
                      childDelegate: ListWheelChildBuilderDelegate(
                        childCount: 24,
                        builder: (context, index) {
                          if (index < 0 || index >= 24) return null;
                          return _buildWheelItem(
                            cs: cs,
                            text: _two(index),
                            selected: index == _hour,
                            disabled: false,
                            onTap: () => _hourCtrl?.animateToItem(
                              index,
                              duration: const Duration(milliseconds: 160),
                              curve: Curves.easeOutCubic,
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      ':',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: cs.onSurface,
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListWheelScrollView.useDelegate(
                      key: const Key('datetime-wheel-minute'),
                      controller: _minuteCtrl,
                      itemExtent: _wheelItemExtent,
                      diameterRatio: 1.45,
                      perspective: 0.003,
                      physics: const FixedExtentScrollPhysics(),
                      onSelectedItemChanged: (idx) {
                        if (_suppressTimeWheelCallbacks) return;
                        setState(() {
                          _minute = idx.clamp(0, 59);
                          _syncInputsFromTime();
                        });
                      },
                      childDelegate: ListWheelChildBuilderDelegate(
                        childCount: 60,
                        builder: (context, index) {
                          if (index < 0 || index >= 60) return null;
                          return _buildWheelItem(
                            cs: cs,
                            text: _two(index),
                            selected: index == _minute,
                            disabled: false,
                            onTap: () => _minuteCtrl?.animateToItem(
                              index,
                              duration: const Duration(milliseconds: 160),
                              curve: Curves.easeOutCubic,
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildWheelItem({
    required ColorScheme cs,
    required String text,
    required bool selected,
    required bool disabled,
    required VoidCallback? onTap,
  }) {
    final Color color;
    if (disabled) {
      color = cs.onSurfaceVariant.withAlpha(75);
    } else if (selected) {
      color = cs.onSurface;
    } else {
      color = cs.onSurfaceVariant.withAlpha(185);
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Center(
        child: Text(
          text,
          style: TextStyle(
            fontSize: selected ? 18 : 15.5,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
            color: color,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }

  Widget _buildTimeDialView(BuildContext context, ColorScheme cs, bool isDark) {
    if (_dialKeyboardInput) {
      return _buildDialKeyboardInputView(cs, isDark);
    }

    final screenHeight = MediaQuery.sizeOf(context).height;
    final dialSize = screenHeight < 620 ? 192.0 : 208.0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          key: const Key('datetime-dial-header'),
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildDialHeaderTab(
              key: const Key('datetime-dial-hour-tab'),
              text: _two(_hour),
              active: _dialUnit == _DialUnit.hour,
              cs: cs,
              isDark: isDark,
              onTap: () => setState(() => _dialUnit = _DialUnit.hour),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                ':',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.w700,
                  height: 1.0,
                  color: cs.onSurface,
                ),
              ),
            ),
            _buildDialHeaderTab(
              key: const Key('datetime-dial-minute-tab'),
              text: _two(_minute),
              active: _dialUnit == _DialUnit.minute,
              cs: cs,
              isDark: isDark,
              onTap: () => setState(() => _dialUnit = _DialUnit.minute),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: dialSize,
          child: Stack(
            alignment: Alignment.center,
            children: [
              _ClockDial24h(
                key: const Key('datetime-clock-dial'),
                size: dialSize,
                unit: _dialUnit,
                hour: _hour,
                minute: _minute,
                onHourChanged: (h, {required bool advanceToMinute}) {
                  setState(() {
                    _hour = h;
                    _syncInputsFromTime();
                    if (advanceToMinute) {
                      _dialUnit = _DialUnit.minute;
                    }
                  });
                },
                onMinuteChanged: (m) {
                  setState(() {
                    _minute = m;
                    _syncInputsFromTime();
                  });
                },
                onHourDragEnd: () {
                  if (_dialUnit == _DialUnit.hour) {
                    setState(() => _dialUnit = _DialUnit.minute);
                  }
                },
              ),
              Positioned(
                left: 0,
                bottom: 0,
                child: IconButton(
                  key: const Key('datetime-dial-input-toggle'),
                  visualDensity: VisualDensity.compact,
                  tooltip: '键盘输入时间',
                  onPressed: () {
                    setState(() {
                      _syncInputsFromTime();
                      _dialKeyboardInput = true;
                    });
                  },
                  icon: Icon(
                    Icons.keyboard_alt_outlined,
                    size: 20,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDialHeaderTab({
    required Key key,
    required String text,
    required bool active,
    required ColorScheme cs,
    required bool isDark,
    required VoidCallback onTap,
  }) {
    final bgColor = active
        ? (isDark
              ? cs.primaryContainer.withAlpha(190)
              : cs.primaryContainer.withAlpha(220))
        : (isDark
              ? cs.surfaceContainerHighest.withAlpha(130)
              : cs.surfaceContainerHighest.withAlpha(120));
    final fgColor = active ? cs.primary : cs.onSurfaceVariant;

    return Material(
      color: bgColor,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: key,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Text(
            text,
            style: TextStyle(
              fontSize: 34,
              fontWeight: FontWeight.w700,
              height: 1.1,
              color: fgColor,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDialKeyboardInputView(ColorScheme cs, bool isDark) {
    final fieldFill = isDark
        ? cs.surfaceContainerHighest.withAlpha(160)
        : cs.surfaceContainerHighest.withAlpha(135);

    Widget buildNumberBox({
      required Key key,
      required TextEditingController controller,
      required FocusNode focusNode,
      required String unitLabel,
      required int maxValue,
      required ValueChanged<int> onValidValue,
      TextInputAction? textInputAction,
      VoidCallback? onSubmitted,
    }) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 88,
            child: TextField(
              key: key,
              controller: controller,
              focusNode: focusNode,
              keyboardType: TextInputType.number,
              textInputAction: textInputAction,
              textAlign: TextAlign.center,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(2),
              ],
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                color: cs.onSurface,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: fieldFill,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 12,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (raw) {
                final trimmed = raw.trim();
                if (trimmed.isEmpty) return;
                final parsed = int.tryParse(trimmed);
                if (parsed == null) return;
                final clamped = parsed.clamp(0, maxValue);
                onValidValue(clamped);
              },
              onSubmitted: (_) => onSubmitted?.call(),
            ),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Text(
              unitLabel,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ),
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Text(
            '输入时间',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: cs.onSurface,
            ),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            buildNumberBox(
              key: const Key('datetime-hour-input'),
              controller: _hourInputCtrl,
              focusNode: _hourInputFocus,
              unitLabel: '时 (00–23)',
              maxValue: 23,
              textInputAction: TextInputAction.next,
              onValidValue: (v) => setState(() => _hour = v),
              onSubmitted: () => _minuteInputFocus.requestFocus(),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              child: Text(
                ':',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                ),
              ),
            ),
            buildNumberBox(
              key: const Key('datetime-minute-input'),
              controller: _minuteInputCtrl,
              focusNode: _minuteInputFocus,
              unitLabel: '分 (00–59)',
              maxValue: 59,
              textInputAction: TextInputAction.done,
              onValidValue: (v) => setState(() => _minute = v),
              onSubmitted: () {
                _commitKeyboardInputs(formatFields: true);
                FocusScope.of(context).unfocus();
              },
            ),
          ],
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: IconButton(
            key: const Key('datetime-dial-input-toggle'),
            visualDensity: VisualDensity.compact,
            tooltip: '返回表盘选择',
            onPressed: () {
              FocusScope.of(context).unfocus();
              _commitKeyboardInputs(formatFields: true);
              setState(() => _dialKeyboardInput = false);
            },
            icon: Icon(
              Icons.access_time_rounded,
              size: 20,
              color: cs.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final surfaceColor = isDark ? cs.surfaceContainer : cs.surface;

    final Widget upperContent;
    if (_mode == _PickerMode.date) {
      upperContent = _dateWheelStyle
          ? _buildDateWheelView(context, cs, isDark)
          : _buildCalendarView(context, cs, isDark);
    } else {
      upperContent = _timeDialStyle
          ? _buildTimeDialView(context, cs, isDark)
          : _buildTimeWheelView(context, cs, isDark);
    }

    final switchCapsuleText = _mode == _PickerMode.date
        ? '${_two(_hour)}:${_two(_minute)}'
        : '$_year-${_two(_month)}-${_two(_day)}';
    final switchCapsuleIcon = _mode == _PickerMode.date
        ? Icons.schedule_rounded
        : Icons.calendar_today_rounded;
    final switchCapsuleIconSize = _mode == _PickerMode.date ? 15.0 : 14.0;

    return Dialog(
      backgroundColor: surfaceColor,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide.none,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 336),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              upperContent,
              const SizedBox(height: 10),
              // Lower Control Row (Thumb Zone, right above Cancel/Confirm)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton(
                    key: const Key('datetime-toggle-style-btn'),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      minimumSize: const Size(0, 36),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      side: BorderSide.none,
                    ),
                    onPressed: _toggleStyle,
                    child: const Text(
                      '切换样式',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Material(
                    color: isDark
                        ? cs.secondaryContainer.withAlpha(175)
                        : cs.secondaryContainer,
                    shape: const StadiumBorder(side: BorderSide.none),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      key: const Key('datetime-switch-mode-btn'),
                      onTap: _toggleMode,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              switchCapsuleIcon,
                              size: switchCapsuleIconSize,
                              color: cs.onSecondaryContainer,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              switchCapsuleText,
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: cs.onSecondaryContainer,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              // Bottom-Right Action Row
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    key: const Key('datetime-cancel-btn'),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 38),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      side: BorderSide.none,
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonal(
                    key: const Key('datetime-confirm-btn'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 38),
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      side: BorderSide.none,
                    ),
                    onPressed: _confirm,
                    child: const Text(
                      '完成',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Self-contained Android Material 3 style 24-hour dual-ring clock dial:
/// - Outer ring (`12, 1..11`) + Inner ring (`00, 13..23`) in hour mode,
/// - `00, 05, ..., 55` with exact 1-minute (`0..59`) angle snapping in minute mode.
class _ClockDial24h extends StatelessWidget {
  const _ClockDial24h({
    super.key,
    required this.size,
    required this.unit,
    required this.hour,
    required this.minute,
    required this.onHourChanged,
    required this.onMinuteChanged,
    required this.onHourDragEnd,
  });

  final double size;
  final _DialUnit unit;
  final int hour;
  final int minute;
  final void Function(int hour, {required bool advanceToMinute}) onHourChanged;
  final ValueChanged<int> onMinuteChanged;
  final VoidCallback onHourDragEnd;

  static const double _outerRingFactor = 0.78;
  static const double _innerRingFactor = 0.50;
  static const double _ringSplitFactor = 0.64;

  void _handlePointer(Offset localPos, {required bool advanceIfHour}) {
    final center = Offset(size / 2, size / 2);
    final delta = localPos - center;
    final dist = delta.distance;
    if (dist < 4.0) return;

    var angle = math.atan2(delta.dy, delta.dx) + math.pi / 2;
    if (angle < 0) angle += 2 * math.pi;

    final radius = size / 2;
    if (unit == _DialUnit.hour) {
      final slot = ((angle / (2 * math.pi)) * 12).round() % 12;
      final isInner = dist < radius * _ringSplitFactor;
      final resolvedHour = isInner
          ? (slot == 0 ? 0 : slot + 12)
          : (slot == 0 ? 12 : slot);
      onHourChanged(resolvedHour, advanceToMinute: advanceIfHour);
    } else {
      final resolvedMinute = ((angle / (2 * math.pi)) * 60).round() % 60;
      onMinuteChanged(resolvedMinute);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) => _handlePointer(d.localPosition, advanceIfHour: false),
      onTapUp: (d) => _handlePointer(d.localPosition, advanceIfHour: true),
      onPanStart: (d) => _handlePointer(d.localPosition, advanceIfHour: false),
      onPanUpdate: (d) => _handlePointer(d.localPosition, advanceIfHour: false),
      onPanEnd: (_) => onHourDragEnd(),
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _ClockDial24hPainter(
            unit: unit,
            hour: hour,
            minute: minute,
            dialBackground: isDark
                ? cs.surfaceContainerHighest.withAlpha(155)
                : cs.surfaceContainerHighest.withAlpha(135),
            handColor: cs.primary,
            onHandColor: cs.onPrimary,
            outerTextColor: cs.onSurface,
            innerTextColor: cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _ClockDial24hPainter extends CustomPainter {
  const _ClockDial24hPainter({
    required this.unit,
    required this.hour,
    required this.minute,
    required this.dialBackground,
    required this.handColor,
    required this.onHandColor,
    required this.outerTextColor,
    required this.innerTextColor,
  });

  final _DialUnit unit;
  final int hour;
  final int minute;
  final Color dialBackground;
  final Color handColor;
  final Color onHandColor;
  final Color outerTextColor;
  final Color innerTextColor;

  Offset _polarFromTop(Offset center, double r, double angleRad) => Offset(
    center.dx + r * math.sin(angleRad),
    center.dy - r * math.cos(angleRad),
  );

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2;
    final outerR = radius * _ClockDial24h._outerRingFactor;
    final innerR = radius * _ClockDial24h._innerRingFactor;

    // 1. Dial background circle (borderless)
    final bgPaint = Paint()
      ..color = dialBackground
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius, bgPaint);

    // 2. Clock hand + tip selector circle
    final double handAngle;
    final double handR;
    final bool exactFiveMinuteLabel;
    if (unit == _DialUnit.hour) {
      final slot = hour % 12;
      final isInner = hour == 0 || hour >= 13;
      handAngle = (slot / 12.0) * 2 * math.pi;
      handR = isInner ? innerR : outerR;
      exactFiveMinuteLabel = true;
    } else {
      handAngle = (minute / 60.0) * 2 * math.pi;
      handR = outerR;
      exactFiveMinuteLabel = minute % 5 == 0;
    }

    final tipCenter = _polarFromTop(center, handR, handAngle);
    final selectorRadius = unit == _DialUnit.hour && (hour == 0 || hour >= 13)
        ? 14.0
        : 15.5;

    final linePaint = Paint()
      ..color = handColor
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(center, tipCenter, linePaint);
    canvas.drawCircle(center, 3.5, Paint()..color = handColor);
    canvas.drawCircle(tipCenter, selectorRadius, Paint()..color = handColor);
    if (!exactFiveMinuteLabel) {
      canvas.drawCircle(tipCenter, 2.5, Paint()..color = onHandColor);
    }

    // 3. Labels
    if (unit == _DialUnit.hour) {
      for (var slot = 0; slot < 12; slot++) {
        final angle = (slot / 12.0) * 2 * math.pi;
        final outerVal = slot == 0 ? 12 : slot;
        final innerVal = slot == 0 ? 0 : slot + 12;

        _drawLabel(
          canvas: canvas,
          pos: _polarFromTop(center, outerR, angle),
          text: '$outerVal',
          fontSize: 13.5,
          fontWeight: hour == outerVal ? FontWeight.w700 : FontWeight.w500,
          color: hour == outerVal ? onHandColor : outerTextColor,
        );
        _drawLabel(
          canvas: canvas,
          pos: _polarFromTop(center, innerR, angle),
          text: _two(innerVal),
          fontSize: 11.5,
          fontWeight: hour == innerVal ? FontWeight.w700 : FontWeight.w500,
          color: hour == innerVal ? onHandColor : innerTextColor,
        );
      }
    } else {
      for (var slot = 0; slot < 12; slot++) {
        final mVal = slot * 5;
        final angle = (slot / 12.0) * 2 * math.pi;
        final selected = minute == mVal;
        _drawLabel(
          canvas: canvas,
          pos: _polarFromTop(center, outerR, angle),
          text: _two(mVal),
          fontSize: 13.5,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          color: selected ? onHandColor : outerTextColor,
        );
      }
    }
  }

  void _drawLabel({
    required Canvas canvas,
    required Offset pos,
    required String text,
    required double fontSize,
    required FontWeight fontWeight,
    required Color color,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: fontWeight,
          color: color,
          height: 1.0,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(pos.dx - tp.width / 2, pos.dy - tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _ClockDial24hPainter oldDelegate) =>
      oldDelegate.unit != unit ||
      oldDelegate.hour != hour ||
      oldDelegate.minute != minute ||
      oldDelegate.dialBackground != dialBackground ||
      oldDelegate.handColor != handColor ||
      oldDelegate.onHandColor != onHandColor ||
      oldDelegate.outerTextColor != outerTextColor ||
      oldDelegate.innerTextColor != innerTextColor;
}
