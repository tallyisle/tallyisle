import 'dart:convert';

import '../../core/failure.dart';
import '../model/codes.dart';

/// `record_period.state` values (docs/modules/periodic-records.md §2).
abstract final class PeriodState {
  static const active = 0; // 进行中
  static const ended = 1; // 已结束
  static const paused = 2; // 已停用

  static const labels = <int, String>{
    active: '进行中',
    ended: '已结束',
    paused: '已停用',
  };
}

/// `record_period.period_type` values (docs/modules/periodic-records.md §2).
abstract final class PeriodType {
  static const daily = 0; // 每日
  static const weekly = 1; // 每周
  static const monthly = 2; // 每月
  static const yearly = 3; // 每年

  static const labels = <int, String>{
    daily: '每日',
    weekly: '每周',
    monthly: '每月',
    yearly: '每年',
  };
}

/// Monthly end-of-month sentinel stored in `period_type_date`.
const monthEndToken = '-12';

/// Sentinel for endless `period_end_date`.
const periodEndNever = -1;

/// Maximum execution count encoded directly in `period_end_date` (`1..366`).
/// Values `> 366` represent an end date in epoch milliseconds (DR-PB-03).
const periodMaxEndCount = 366;

/// Sentinel for `last_add_date` when no occurrence has been generated yet.
const noLastAddDate = -1;

/// Safety bound per catch-up pass against corrupt historical timestamps.
const maxCatchUpOccurrencesPerRun = 5000;

/// Three-state interpretation of `record_period.period_end_date` (DR-PB-03).
enum PeriodEndMode { never, count, date }

PeriodEndMode classifyPeriodEndDate(int periodEndDate) {
  if (periodEndDate == periodEndNever) return PeriodEndMode.never;
  if (periodEndDate >= 1 && periodEndDate <= periodMaxEndCount) {
    return PeriodEndMode.count;
  }
  if (periodEndDate > periodMaxEndCount) return PeriodEndMode.date;
  throw const Failure(FailureCode.validation, '周期结束条件无效');
}

/// Clamps repetition step `frequency` per golden vector PB-11:
/// - daily (`0`): `1..100` (`120 -> 100`)
/// - weekly (`1`): `1..3` (`5 -> 3`)
/// - monthly (`2`): `1..10` (`15 -> 10`)
/// - yearly (`3`): `>= 1`
int clampFrequency(int periodType, int frequency) {
  final positive = frequency < 1 ? 1 : frequency;
  return switch (periodType) {
    PeriodType.daily => positive > 100 ? 100 : positive,
    PeriodType.weekly => positive > 3 ? 3 : positive,
    PeriodType.monthly => positive > 10 ? 10 : positive,
    PeriodType.yearly => positive,
    _ => throw Failure(FailureCode.validation, '未知的周期类型 $periodType'),
  };
}

/// Pure local calendar date `(year, month, day)` free of DST drift.
final class CalendarDate implements Comparable<CalendarDate> {
  const CalendarDate(this.year, this.month, this.day);

  factory CalendarDate.fromDateTime(DateTime dt) =>
      CalendarDate(dt.year, dt.month, dt.day);

  factory CalendarDate.fromEpochMs(int epochMs) =>
      CalendarDate.fromDateTime(DateTime.fromMillisecondsSinceEpoch(epochMs));

  final int year;
  final int month;
  final int day;

  /// Local `00:00:00.000` epoch milliseconds.
  int get startOfDayMs => DateTime(year, month, day).millisecondsSinceEpoch;

  /// ISO 8601 weekday: `1` (Monday) .. `7` (Sunday).
  int get weekday => DateTime(year, month, day).weekday;

  CalendarDate plusDays(int days) {
    final dt = DateTime(year, month, day + days);
    return CalendarDate(dt.year, dt.month, dt.day);
  }

  bool isBefore(CalendarDate other) => compareTo(other) < 0;
  bool isAfter(CalendarDate other) => compareTo(other) > 0;
  bool isAtOrBefore(CalendarDate other) => compareTo(other) <= 0;
  bool isAtOrAfter(CalendarDate other) => compareTo(other) >= 0;

  @override
  int compareTo(CalendarDate other) {
    if (year != other.year) return year.compareTo(other.year);
    if (month != other.month) return month.compareTo(other.month);
    return day.compareTo(other.day);
  }

  String formatIso() =>
      '${year.toString().padLeft(4, '0')}-'
      '${month.toString().padLeft(2, '0')}-'
      '${day.toString().padLeft(2, '0')}';

  @override
  bool operator ==(Object other) =>
      other is CalendarDate &&
      other.year == year &&
      other.month == month &&
      other.day == day;

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() => formatIso();
}

/// Number of days in `[month]` (`1..12`) of `[year]`.
int daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

/// Adds `[deltaMonths]` to `(year, month)` and returns normalized `(year, month)`.
(int, int) addMonths(int year, int month, int deltaMonths) {
  final zeroBased = (year * 12 + (month - 1)) + deltaMonths;
  final newYear = zeroBased ~/ 12;
  final newMonth = (zeroBased % 12) + 1;
  return (newYear, newMonth);
}

/// Parses `"HH:mm"` into `(hour, minute)`, or returns `null` if invalid.
(int, int)? parseHourMinute(String? text) {
  if (text == null) return null;
  final trimmed = text.trim();
  final match = RegExp(r'^(\d{1,2}):(\d{1,2})$').firstMatch(trimmed);
  if (match == null) return null;
  final hour = int.tryParse(match.group(1)!);
  final minute = int.tryParse(match.group(2)!);
  if (hour == null || minute == null) return null;
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
  return (hour, minute);
}

String formatHourMinute(int hour, int minute) =>
    '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

const _corruptExtra = Failure(FailureCode.corruptData, '周期记账附加信息格式损坏');

/// Typed codec for `record_period.exi` JSON (`rt`, `rte`, `fee_from`).
/// Preserves unknown keys on round-trip.
final class PeriodExtra {
  PeriodExtra([Map<String, Object?>? raw]) : raw = {...?raw};

  final Map<String, Object?> raw;

  /// Fixed booking time `"HH:mm"`.
  String? get recordTime {
    final v = raw['rt'];
    if (v is! String) return null;
    final parsed = parseHourMinute(v);
    return parsed == null ? null : formatHourMinute(parsed.$1, parsed.$2);
  }

  set recordTime(String? value) {
    if (value == null || value.trim().isEmpty) {
      raw.remove('rt');
    } else {
      final parsed = parseHourMinute(value);
      if (parsed == null) {
        throw const Failure(FailureCode.validation, '记账时间格式须为 HH:mm');
      }
      raw['rt'] = formatHourMinute(parsed.$1, parsed.$2);
    }
  }

  /// Whether fixed booking time is enabled (`rte`).
  bool get recordTimeEnabled => raw['rte'] == true;
  set recordTimeEnabled(bool value) => raw['rte'] = value;

  /// Transfer fee payer (`fee_from`: `0` outgoing account, `1` incoming account).
  bool get feeFromTarget => raw['fee_from'] == 1 || raw['fee_from'] == true;
  set feeFromTarget(bool value) => raw['fee_from'] = value ? 1 : 0;

  static PeriodExtra parse(String? text) {
    if (text == null || text.trim().isEmpty) return PeriodExtra();
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw _corruptExtra;
    }
    if (decoded is! Map<String, Object?>) throw _corruptExtra;
    return PeriodExtra(decoded);
  }

  String? encode() => raw.isEmpty ? null : jsonEncode(raw);
}

/// Normalizes and validates `"M-D"` / `"MM-dd"` into zero-padded `"MM-dd"`.
/// Uses leap year 2024 as reference so `"02-29"` is valid while `"02-30"` is rejected.
String? tryNormalizeYearlyToken(String raw) {
  final parts = raw.trim().split('-');
  if (parts.length != 2) return null;
  final m = int.tryParse(parts[0]);
  final d = int.tryParse(parts[1]);
  if (m == null || d == null) return null;
  if (m < 1 || m > 12) return null;
  final maxDay = daysInMonth(2024, m);
  if (d < 1 || d > maxDay) return null;
  return '${m.toString().padLeft(2, '0')}-${d.toString().padLeft(2, '0')}';
}

/// Normalizes and sorts `period_type_date` tokens according to `[periodType]`:
/// - daily (`0`): `[]`
/// - weekly (`1`): `["1".."7"]` sorted ascending
/// - monthly (`2`): `["1".."31"]` sorted ascending by integer value, with `"-12"` at the end
/// - yearly (`3`): `["MM-dd"]` zero-padded BEFORE sorting ascending (fixes ASYM-PB-03 / CE-PB-03)
List<String> normalizePeriodTypeDates(
  int periodType,
  Iterable<String> rawTokens, {
  bool strict = false,
}) {
  switch (periodType) {
    case PeriodType.daily:
      return const [];
    case PeriodType.weekly:
      final days = <int>{};
      for (final token in rawTokens) {
        final d = int.tryParse(token.trim());
        if (d == null || d < 1 || d > 7) {
          if (strict) {
            throw const Failure(FailureCode.validation, '每周日期须在周一至周日之间');
          }
          continue;
        }
        days.add(d);
      }
      final sorted = days.toList()..sort();
      if (strict && sorted.isEmpty) {
        throw const Failure(FailureCode.validation, '请至少选择一个星期几');
      }
      return [for (final d in sorted) '$d'];
    case PeriodType.monthly:
      final numericDays = <int>{};
      var hasMonthEnd = false;
      for (final token in rawTokens) {
        final trimmed = token.trim();
        if (trimmed == monthEndToken) {
          hasMonthEnd = true;
          continue;
        }
        final d = int.tryParse(trimmed);
        if (d == null || d < 1 || d > 31) {
          if (strict) {
            throw const Failure(FailureCode.validation, '每月日期须为 1–31 日或月末');
          }
          continue;
        }
        numericDays.add(d);
      }
      final sorted = numericDays.toList()..sort();
      final result = <String>[
        for (final d in sorted) '$d',
        if (hasMonthEnd) monthEndToken,
      ];
      if (strict && result.isEmpty) {
        throw const Failure(FailureCode.validation, '请至少选择一个每月记账日');
      }
      return result;
    case PeriodType.yearly:
      final normalized = <String>{};
      for (final token in rawTokens) {
        final norm = tryNormalizeYearlyToken(token);
        if (norm == null) {
          if (strict) {
            throw Failure(FailureCode.validation, '每年日期格式无效: $token');
          }
          continue;
        }
        normalized.add(norm);
      }
      // Zero-padded "MM-dd" lexicographical order equals chronological (month, day) order!
      final sorted = normalized.toList()..sort();
      if (strict && sorted.isEmpty) {
        throw const Failure(FailureCode.validation, '请至少选择一个每年记账月日');
      }
      return sorted;
    default:
      throw Failure(FailureCode.validation, '未知的周期类型 $periodType');
  }
}

/// Parses `record_period.period_type_date` JSON array string into normalized tokens.
List<String> parsePeriodTypeDateJson(int periodType, String? jsonText) {
  if (periodType == PeriodType.daily) return const [];
  if (jsonText == null || jsonText.trim().isEmpty) return const [];
  final Object? decoded;
  try {
    decoded = jsonDecode(jsonText);
  } on FormatException {
    return const [];
  }
  if (decoded is! List) return const [];
  return normalizePeriodTypeDates(
    periodType,
    decoded.map((e) => e?.toString() ?? ''),
  );
}

/// Encodes normalized `period_type_date` JSON array string for persistence.
String encodePeriodTypeDateJson(int periodType, Iterable<String> rawTokens) =>
    jsonEncode(normalizePeriodTypeDates(periodType, rawTokens, strict: true));

/// Parses comma-separated tag tokens from `record_period.tags`, preserving order without blanks.
List<String> parsePeriodTagTokens(String? tagsColumn) {
  if (tagsColumn == null || tagsColumn.trim().isEmpty) return const [];
  final seen = <String>{};
  final out = <String>[];
  for (final part in tagsColumn.split(',')) {
    final trimmed = part.trim();
    if (trimmed.isNotEmpty && seen.add(trimmed)) {
      out.add(trimmed);
    }
  }
  return out;
}

/// Encodes deduplicated tag IDs into `record_period.tags` column.
String? encodePeriodTagTokens(Iterable<String> tagIds) {
  final seen = <String>{};
  final out = <String>[];
  for (final id in tagIds) {
    final trimmed = id.trim();
    if (trimmed.isNotEmpty && seen.add(trimmed)) {
      out.add(trimmed);
    }
  }
  return out.isEmpty ? null : out.join(',');
}

/// Domain snapshot of a `record_period` scheduling state.
final class PeriodScheduleSpec {
  const PeriodScheduleSpec({
    required this.periodType,
    required this.periodTypeDateJson,
    required this.frequency,
    required this.periodStartDateMs,
    required this.periodEndDate,
    this.lastAddDateMs = noLastAddDate,
    this.periodAddTimes = 0,
    this.state = PeriodState.active,
  });

  final int periodType;
  final String periodTypeDateJson;
  final int frequency;
  final int periodStartDateMs;
  final int periodEndDate;
  final int lastAddDateMs;
  final int periodAddTimes;
  final int state;

  PeriodScheduleSpec copyWith({
    int? lastAddDateMs,
    int? periodAddTimes,
    int? state,
  }) => PeriodScheduleSpec(
    periodType: periodType,
    periodTypeDateJson: periodTypeDateJson,
    frequency: frequency,
    periodStartDateMs: periodStartDateMs,
    periodEndDate: periodEndDate,
    lastAddDateMs: lastAddDateMs ?? this.lastAddDateMs,
    periodAddTimes: periodAddTimes ?? this.periodAddTimes,
    state: state ?? this.state,
  );
}

/// Computes the next calendar due date from `[spec]`'s cursor (`start` when
/// `lastAddDateMs == -1`, else `lastAddDate`), ignoring `periodEndDate` bounds.
///
/// Key guarantees (docs/modules/periodic-records.md R2):
/// - Daily: `start` on first run, then `+clampedFrequency` days.
/// - Weekly: sorted `[1..7]`; first matching weekday in week (`>=` on first run,
///   `>` on subsequent runs), else `+clampedFrequency` weeks at `dows.first`.
/// - Monthly: `["1".."31", "-12"]`; resolves each target against the candidate
///   month's length while anchoring to `period_type_date` (so `31` clamps to
///   Feb 28/29 and restores to Mar 31, fixing CE-PB-02).
/// - Yearly: zero-padded sorted `["MM-dd"]`; `"02-29"` clamps to Feb 28 in
///   non-leap years without skipping the year (fixing ASYM-PB-02/03 & CE-PB-03).
CalendarDate? computeNextDueDate(PeriodScheduleSpec spec) {
  final freq = clampFrequency(spec.periodType, spec.frequency);
  final start = CalendarDate.fromEpochMs(spec.periodStartDateMs);
  final isFirst = spec.lastAddDateMs == noLastAddDate;
  final cursor = isFirst ? start : CalendarDate.fromEpochMs(spec.lastAddDateMs);

  switch (spec.periodType) {
    case PeriodType.daily:
      return isFirst ? start : cursor.plusDays(freq);

    case PeriodType.weekly:
      final tokens = parsePeriodTypeDateJson(
        PeriodType.weekly,
        spec.periodTypeDateJson,
      );
      if (tokens.isEmpty) return null;
      final dows = [for (final t in tokens) int.parse(t)];
      final dow = cursor.weekday;
      for (final d in dows) {
        if (isFirst ? d >= dow : d > dow) {
          return cursor.plusDays(d - dow);
        }
      }
      // Advance `freq` weeks from Monday of `cursor`'s week, landing on `dows.first`.
      final monday = cursor.plusDays(1 - dow);
      return monday.plusDays(freq * 7 + (dows.first - 1));

    case PeriodType.monthly:
      final tokens = parsePeriodTypeDateJson(
        PeriodType.monthly,
        spec.periodTypeDateJson,
      );
      if (tokens.isEmpty) return null;

      List<int> resolveMonthDays(int year, int month) {
        final maxDay = daysInMonth(year, month);
        final resolved = <int>{};
        for (final t in tokens) {
          if (t == monthEndToken) {
            resolved.add(maxDay);
          } else {
            final target = int.parse(t);
            resolved.add(target > maxDay ? maxDay : target);
          }
        }
        return resolved.toList()..sort();
      }

      final sameMonthDays = resolveMonthDays(cursor.year, cursor.month);
      for (final d in sameMonthDays) {
        if (isFirst ? d >= cursor.day : d > cursor.day) {
          return CalendarDate(cursor.year, cursor.month, d);
        }
      }
      final (nextYear, nextMonth) = addMonths(cursor.year, cursor.month, freq);
      final nextMonthDays = resolveMonthDays(nextYear, nextMonth);
      return CalendarDate(nextYear, nextMonth, nextMonthDays.first);

    case PeriodType.yearly:
      final tokens = parsePeriodTypeDateJson(
        PeriodType.yearly,
        spec.periodTypeDateJson,
      );
      if (tokens.isEmpty) return null;

      List<CalendarDate> resolveYearDates(int year) {
        final resolved = <CalendarDate>{};
        for (final t in tokens) {
          final parts = t.split('-');
          final m = int.parse(parts[0]);
          final d = int.parse(parts[1]);
          final maxDay = daysInMonth(year, m);
          resolved.add(CalendarDate(year, m, d > maxDay ? maxDay : d));
        }
        return resolved.toList()..sort();
      }

      final sameYearDates = resolveYearDates(cursor.year);
      for (final candidate in sameYearDates) {
        if (isFirst
            ? candidate.isAtOrAfter(cursor)
            : candidate.isAfter(cursor)) {
          return candidate;
        }
      }
      final nextYear = cursor.year + freq;
      return resolveYearDates(nextYear).first;

    default:
      return null;
  }
}

/// Checks whether a candidate `[dueDate]` satisfies `[spec]`'s end condition
/// and is due on or before `[today]`.
bool isDueEligible(
  PeriodScheduleSpec spec,
  CalendarDate dueDate,
  CalendarDate today,
) {
  if (dueDate.isAfter(today)) return false;
  switch (classifyPeriodEndDate(spec.periodEndDate)) {
    case PeriodEndMode.never:
      return true;
    case PeriodEndMode.count:
      return spec.periodAddTimes < spec.periodEndDate;
    case PeriodEndMode.date:
      final endDate = CalendarDate.fromEpochMs(spec.periodEndDate);
      return dueDate.isAtOrBefore(endDate);
  }
}

/// Evaluates whether `[spec]` should transition to `PeriodState.ended (1)`
/// given its latest `lastAddDateMs` and `periodAddTimes` (DR-PB-03, ASYM-PB-04).
bool shouldRuleEnd(PeriodScheduleSpec spec) {
  switch (classifyPeriodEndDate(spec.periodEndDate)) {
    case PeriodEndMode.never:
      return computeNextDueDate(spec) == null;
    case PeriodEndMode.count:
      return spec.periodAddTimes >= spec.periodEndDate ||
          computeNextDueDate(spec) == null;
    case PeriodEndMode.date:
      final endDate = CalendarDate.fromEpochMs(spec.periodEndDate);
      final nextDue = computeNextDueDate(spec);
      return nextDue == null || nextDue.isAfter(endDate);
  }
}

/// Planned catch-up result for a single active rule up to `[today]`.
final class RuleCatchUpPlan {
  const RuleCatchUpPlan({
    required this.dueDates,
    required this.nextLastAddDateMs,
    required this.nextAddTimes,
    required this.nextState,
  });

  final List<CalendarDate> dueDates;
  final int nextLastAddDateMs;
  final int nextAddTimes;
  final int nextState;
}

/// Computes all due dates `<= today` for `[spec]` and the resulting rule state.
RuleCatchUpPlan computeCatchUpPlan(
  PeriodScheduleSpec spec,
  CalendarDate today,
) {
  if (spec.state != PeriodState.active) {
    return RuleCatchUpPlan(
      dueDates: const [],
      nextLastAddDateMs: spec.lastAddDateMs,
      nextAddTimes: spec.periodAddTimes,
      nextState: spec.state,
    );
  }

  var current = spec;
  final dueDates = <CalendarDate>[];

  for (var i = 0; i < maxCatchUpOccurrencesPerRun; i++) {
    final nextDue = computeNextDueDate(current);
    if (nextDue == null || !isDueEligible(current, nextDue, today)) {
      break;
    }
    dueDates.add(nextDue);
    current = current.copyWith(
      lastAddDateMs: nextDue.startOfDayMs,
      periodAddTimes: current.periodAddTimes + 1,
    );
  }

  final ended = shouldRuleEnd(current);
  return RuleCatchUpPlan(
    dueDates: dueDates,
    nextLastAddDateMs: current.lastAddDateMs,
    nextAddTimes: current.periodAddTimes,
    nextState: ended ? PeriodState.ended : PeriodState.active,
  );
}

/// Fast-forwards `[spec]` when resuming (`state: 2 -> 0`, R5):
/// skips all scheduled dates strictly before `[today]` (`dueDate < today`)
/// by advancing `lastAddDateMs` WITHOUT generating historical bills and
/// WITHOUT incrementing `periodAddTimes`.
PeriodScheduleSpec fastForwardMissedDates(
  PeriodScheduleSpec spec,
  CalendarDate today,
) {
  var current = spec.copyWith(state: PeriodState.active);
  final endMode = classifyPeriodEndDate(current.periodEndDate);
  final endDate = endMode == PeriodEndMode.date
      ? CalendarDate.fromEpochMs(current.periodEndDate)
      : null;

  if (endMode == PeriodEndMode.count &&
      current.periodAddTimes >= current.periodEndDate) {
    return current.copyWith(state: PeriodState.ended);
  }

  for (var i = 0; i < maxCatchUpOccurrencesPerRun; i++) {
    final nextDue = computeNextDueDate(current);
    if (nextDue == null) {
      return current.copyWith(state: PeriodState.ended);
    }
    if (endDate != null && nextDue.isAfter(endDate)) {
      return current.copyWith(state: PeriodState.ended);
    }
    if (!nextDue.isBefore(today)) {
      break;
    }
    current = current.copyWith(lastAddDateMs: nextDue.startOfDayMs);
  }

  if (shouldRuleEnd(current)) {
    return current.copyWith(state: PeriodState.ended);
  }
  return current;
}

/// Computes deterministic `record_time` (epoch ms) for a generated periodic bill
/// (P-02 / ASYM-PB-06):
/// - If `extra.recordTimeEnabled == true` and a valid `"HH:mm"` exists in
///   `extra.recordTime` (or `[fallbackTime]`): `dueDate` at `HH:mm:00.000` local time.
/// - Otherwise: if `dueDate == today` -> `[nowMs]`; if `dueDate < today` ->
///   local `12:00:00.000` on `dueDate`.
int computePeriodicRecordTime({
  required CalendarDate dueDate,
  required int nowMs,
  required PeriodExtra extra,
  String? fallbackTime,
}) {
  if (extra.recordTimeEnabled) {
    final hm = parseHourMinute(extra.recordTime ?? fallbackTime);
    if (hm != null) {
      return DateTime(
        dueDate.year,
        dueDate.month,
        dueDate.day,
        hm.$1,
        hm.$2,
      ).millisecondsSinceEpoch;
    }
  }
  final today = CalendarDate.fromEpochMs(nowMs);
  if (dueDate == today) {
    return nowMs;
  }
  return DateTime(
    dueDate.year,
    dueDate.month,
    dueDate.day,
    12,
  ).millisecondsSinceEpoch;
}

/// Computes `(parentTimeMs, feeTimeMs)` for a periodic transfer with fee,
/// shifting `parentTimeMs` by `-1ms` if `+1ms` would cross local midnight (02o §2.2).
(int, int) computeTransferWithFeeTimestamps(int baseTimeMs) {
  final local = DateTime.fromMillisecondsSinceEpoch(baseTimeMs);
  final next = DateTime.fromMillisecondsSinceEpoch(baseTimeMs + 1);
  if (next.day != local.day) {
    return (baseTimeMs - 1, baseTimeMs);
  }
  return (baseTimeMs, baseTimeMs + 1);
}

const _weekdayLabels = <int, String>{
  1: '周一',
  2: '周二',
  3: '周三',
  4: '周四',
  5: '周五',
  6: '周六',
  7: '周日',
};

/// Human-readable description of a periodic cycle for UI cards.
String formatPeriodCycleSummary({
  required int periodType,
  required String periodTypeDateJson,
  required int frequency,
}) {
  final freq = clampFrequency(periodType, frequency);
  final tokens = parsePeriodTypeDateJson(periodType, periodTypeDateJson);
  switch (periodType) {
    case PeriodType.daily:
      return freq == 1 ? '每天' : '每 $freq 天';
    case PeriodType.weekly:
      final prefix = freq == 1 ? '每周' : '每 $freq 周';
      final days = tokens
          .map((t) => _weekdayLabels[int.tryParse(t)] ?? t)
          .join('、');
      return days.isEmpty ? prefix : '$prefix $days';
    case PeriodType.monthly:
      final prefix = freq == 1 ? '每月' : '每 $freq 个月';
      final days = tokens
          .map((t) => t == monthEndToken ? '月末' : '$t日')
          .join('、');
      return days.isEmpty ? prefix : '$prefix $days';
    case PeriodType.yearly:
      final prefix = freq == 1 ? '每年' : '每 $freq 年';
      final dates = tokens.join('、');
      return dates.isEmpty ? prefix : '$prefix $dates';
    default:
      return '周期';
  }
}

/// Human-readable description of `period_end_date` for UI cards.
String formatPeriodEndSummary(int periodEndDate) {
  switch (classifyPeriodEndDate(periodEndDate)) {
    case PeriodEndMode.never:
      return '永不结束';
    case PeriodEndMode.count:
      return '共 $periodEndDate 次';
    case PeriodEndMode.date:
      final d = CalendarDate.fromEpochMs(periodEndDate);
      return '截止 ${d.formatIso()}';
  }
}

/// Validates record type allowed for periodic rules (`{0, 1, 2}`).
void validatePeriodicRecordType(int recordType) {
  if (recordType != RecordType.expense &&
      recordType != RecordType.income &&
      recordType != RecordType.transfer) {
    throw const Failure(FailureCode.validation, '周期记账仅支持支出、收入和转账');
  }
}
