import 'dart:convert';

import '../model/codes.dart';
import 'income_expense.dart';

/// Calendar month representation for public calendar natural month [1..lastDay].
/// (docs/modules/calendar.md R1: natural month, unaffected by book start_day).
final class CalendarMonth {
  CalendarMonth(int year, int month)
    : start = DateTime(year, month, 1),
      end = DateTime(
        year,
        month + 1,
        1,
      ).subtract(const Duration(milliseconds: 1));

  final DateTime start;
  final DateTime end;

  int get year => start.year;
  int get month => start.month;
  int get startMs => start.millisecondsSinceEpoch;
  int get endMs => end.millisecondsSinceEpoch;

  /// Days in this calendar month (28, 29, 30, or 31).
  int get daysInMonth => DateTime(start.year, start.month + 1, 0).day;

  /// ISO 8601 weekday of day 1: 1 = Monday, 7 = Sunday.
  int get firstWeekday => start.weekday;

  CalendarMonth previous() => CalendarMonth(year, month - 1);
  CalendarMonth next() => CalendarMonth(year, month + 1);
}

/// Daily summary for a single day in the calendar month.
final class CalendarDailySummary<T> {
  const CalendarDailySummary({
    required this.day,
    required this.incomeExpense,
    required this.records,
  });

  final int day;
  final IncomeExpense incomeExpense;
  final List<T> records;

  bool get hasRecords => records.isNotEmpty;
  bool get hasIncome => incomeExpense.income != BigInt.zero;
  bool get hasExpense => incomeExpense.expense != BigInt.zero;
}

/// Returns true if [type] is visible in calendar view (R2: excludes type 4 and 15).
bool isCalendarRecordVisible(int type) =>
    type != RecordType.balanceAdjust && type != RecordType.reimburseReceipt;

/// Groups records by day of the month (1..31). Excludes type 4 and 15.
Map<int, List<T>> groupCalendarRecordsByDay<T>(
  Iterable<T> items, {
  required int Function(T) recordTimeOf,
  int Function(T)? typeOf,
}) {
  final map = <int, List<T>>{};
  for (final item in items) {
    if (typeOf != null && !isCalendarRecordVisible(typeOf(item))) {
      continue;
    }
    final dt = DateTime.fromMillisecondsSinceEpoch(recordTimeOf(item));
    map.putIfAbsent(dt.day, () => <T>[]).add(item);
  }
  return map;
}

/// Computes daily summaries for all days in [month].
///
/// Rules (docs/modules/calendar.md):
/// - Uses aggregateIncomeExpense per day (R3, R4, R5);
/// - exclude_ex_in=1 amounts are counted as 0, but records remain in [records];
/// - Transfer (type 2) amounts count as 0, but records remain in [records];
/// - Refund / reimbursable net logic applies per day;
/// - Type 4 and 15 are excluded from both totals and records list.
Map<int, CalendarDailySummary<T>> summarizeCalendarMonth<T>(
  CalendarMonth month,
  Iterable<T> items, {
  required int Function(T) recordTimeOf,
  required StatEntry Function(T) statEntryOf,
  String target = 'CNY',
}) {
  final grouped = groupCalendarRecordsByDay(
    items,
    recordTimeOf: recordTimeOf,
    typeOf: (item) => statEntryOf(item).type,
  );
  final result = <int, CalendarDailySummary<T>>{};
  for (var d = 1; d <= month.daysInMonth; d++) {
    final dayItems = grouped[d] ?? const [];
    result[d] = CalendarDailySummary<T>(
      day: d,
      incomeExpense: aggregateIncomeExpense(
        dayItems.map(statEntryOf),
        target: target,
        scope: StatScope.home,
      ),
      records: dayItems,
    );
  }
  return result;
}

/// Clamps credit card repayment day to month length (R7 / ASYM-CD-01c).
/// -2 means end of month (月底).
int clampRepaymentDay(int repaymentDay, int year, int month) {
  final lastDay = DateTime(year, month + 1, 0).day;
  if (repaymentDay == -2) return lastDay;
  if (repaymentDay > lastDay) return lastDay;
  if (repaymentDay < 1) return 1;
  return repaymentDay;
}

/// Parses repayment day from credit_info or extra_info JSON (R7).
int? parseRepaymentDay(String? jsonStr, int year, int month) {
  if (jsonStr == null || jsonStr.trim().isEmpty) return null;
  try {
    final map = jsonDecode(jsonStr);
    if (map is Map) {
      final raw = map['repayment_day'];
      if (raw is int) {
        if (raw == -1) return null;
        return clampRepaymentDay(raw, year, month);
      }
    }
  } catch (_) {}
  return null;
}
