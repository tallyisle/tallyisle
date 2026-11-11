import 'dart:convert';

import '../../core/failure.dart';
import '../../core/money.dart';
import '../ledger/record_extra.dart';
import 'asset_overview.dart' show RateTable, normalizeCurrency;
import 'currency_rates.dart' show baseCurrency, billSnapshot;

/// Plan mode codes stored in `money_save_plan.plan_type` (savings-plan.md §2, R1).
abstract final class SavingsPlanType {
  /// 1: Incremental plan (递增计划).
  static const incremental = 1;

  /// 2: Fixed-amount periodic plan (定额计划).
  static const fixed = 2;

  /// 3: Free-form plan (自由计划).
  static const free = 3;

  static bool isValid(int value) =>
      value == incremental || value == fixed || value == free;

  static String labelOf(int value) => switch (value) {
    incremental => '递增计划',
    fixed => '定额计划',
    free => '自由计划',
    _ => '存钱计划',
  };
}

/// Cycle codes stored in `money_save_plan.cycle_type` (savings-plan.md §2, DR-SP-02).
/// Note: code `4` is unused in the original Room v42 schema.
abstract final class SavingsCycleType {
  static const free = -1;
  static const daily = 1;
  static const weekly = 2;
  static const monthly = 3;
  static const yearly = 5;

  static const scheduledValues = <int>[daily, weekly, monthly, yearly];

  static bool isValidScheduled(int value) =>
      value == daily || value == weekly || value == monthly || value == yearly;

  static String labelOf(int value) => switch (value) {
    daily => '每日',
    weekly => '每周',
    monthly => '每月',
    yearly => '每年',
    free => '自由',
    _ => '未知周期',
  };
}

/// Status codes stored in `money_save_plan.status` (savings-plan.md §1, §2).
abstract final class SavingsPlanStatus {
  static const active = 0;
  static const archived = 1;
}

/// Calendar date in local timezone without time-of-day, immune to DST shifts.
final class LocalCalendarDate implements Comparable<LocalCalendarDate> {
  const LocalCalendarDate(this.year, this.month, this.day);

  factory LocalCalendarDate.fromDateTime(DateTime dt) =>
      LocalCalendarDate(dt.year, dt.month, dt.day);

  factory LocalCalendarDate.fromEpochMs(int epochMs) =>
      LocalCalendarDate.fromDateTime(
        DateTime.fromMillisecondsSinceEpoch(epochMs),
      );

  final int year;
  final int month;
  final int day;

  static int daysInMonth(int year, int month) =>
      DateTime.utc(year, month + 1, 0).day;

  /// Start of day `00:00:00.000` in local timezone (`mask = 7` in DR-SP-03).
  int get startOfDayMs => DateTime(year, month, day).millisecondsSinceEpoch;

  /// End of day `23:59:59.999` in local timezone (`mask = 5` in DR-SP-03).
  int get endOfDayMs =>
      DateTime(year, month, day, 23, 59, 59, 999).millisecondsSinceEpoch;

  /// Combines this calendar date with the wall-clock time of [wallClockMs]
  /// (`mask = 3` in DR-SP-03).
  int withWallClockMs(int wallClockMs) {
    final wall = DateTime.fromMillisecondsSinceEpoch(wallClockMs);
    return DateTime(
      year,
      month,
      day,
      wall.hour,
      wall.minute,
      wall.second,
      wall.millisecond,
    ).millisecondsSinceEpoch;
  }

  String get dateKey =>
      '${year.toString().padLeft(4, '0')}-'
      '${month.toString().padLeft(2, '0')}-'
      '${day.toString().padLeft(2, '0')}';

  LocalCalendarDate plusDays(int days) {
    final utc = DateTime.utc(year, month, day + days);
    return LocalCalendarDate(utc.year, utc.month, utc.day);
  }

  /// Standard `LocalDate.plusMonths(months)` clamping to end-of-month.
  LocalCalendarDate plusMonths(int months) {
    final totalMonths = year * 12 + (month - 1) + months;
    final targetYear = totalMonths ~/ 12;
    final targetMonth = (totalMonths % 12) + 1;
    final maxDay = daysInMonth(targetYear, targetMonth);
    final clampedDay = day <= maxDay ? day : maxDay;
    return LocalCalendarDate(targetYear, targetMonth, clampedDay);
  }

  /// Standard `LocalDate.plusYears(years)` clamping leap day `02-29` -> `02-28`
  /// in non-leap years (R4 / CE-SP-03).
  LocalCalendarDate plusYears(int years) {
    final targetYear = year + years;
    final maxDay = daysInMonth(targetYear, month);
    final clampedDay = day <= maxDay ? day : maxDay;
    return LocalCalendarDate(targetYear, month, clampedDay);
  }

  /// Advances one cycle step according to [cycleType].
  LocalCalendarDate stepCycle(int cycleType) => switch (cycleType) {
    SavingsCycleType.daily => plusDays(1),
    SavingsCycleType.weekly => plusDays(7),
    SavingsCycleType.monthly => plusMonths(1),
    SavingsCycleType.yearly => plusYears(1),
    _ => throw const Failure(FailureCode.validation, '存钱计划周期类型无效'),
  };

  /// Exact calendar day difference `other - this` (DST-safe via UTC midnight).
  int daysUntil(LocalCalendarDate other) => DateTime.utc(
    other.year,
    other.month,
    other.day,
  ).difference(DateTime.utc(year, month, day)).inDays;

  @override
  int compareTo(LocalCalendarDate other) {
    if (year != other.year) return year.compareTo(other.year);
    if (month != other.month) return month.compareTo(other.month);
    return day.compareTo(other.day);
  }

  bool operator <(LocalCalendarDate other) => compareTo(other) < 0;
  bool operator <=(LocalCalendarDate other) => compareTo(other) <= 0;
  bool operator >(LocalCalendarDate other) => compareTo(other) > 0;
  bool operator >=(LocalCalendarDate other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) =>
      other is LocalCalendarDate &&
      year == other.year &&
      month == other.month &&
      day == other.day;

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() => dateKey;
}

/// Typed view of `money_save_plan.extra_info` (`{"curr":"USD"}`, DR-SP-01).
final class SavingsPlanExtra {
  SavingsPlanExtra({String? currency, Map<String, Object?>? raw})
    : raw = {...?raw},
      currency = normalizeCurrency(currency) ?? baseCurrency;

  final String currency;
  final Map<String, Object?> raw;

  /// Parses `extra_info`; blank/null/corrupt JSON falls back to [base] (DR-SP-01).
  static SavingsPlanExtra parse(String? text, {String base = baseCurrency}) {
    final fallback = normalizeCurrency(base) ?? baseCurrency;
    if (text == null || text.trim().isEmpty) {
      return SavingsPlanExtra(currency: fallback);
    }
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) {
        return SavingsPlanExtra(currency: fallback);
      }
      final map = <String, Object?>{
        for (final entry in decoded.entries) entry.key.toString(): entry.value,
      };
      final rawCurr = map['curr'];
      final curr = rawCurr is String
          ? (normalizeCurrency(rawCurr) ?? fallback)
          : fallback;
      return SavingsPlanExtra(currency: curr, raw: map);
    } on FormatException {
      return SavingsPlanExtra(currency: fallback);
    }
  }

  String encode() => jsonEncode({...raw, 'curr': currency});
}

/// Built-in classic savings plan preset templates (R1, SP-11).
final class SavingsPlanTemplate {
  const SavingsPlanTemplate({
    required this.name,
    required this.planType,
    required this.cycleType,
    required this.startDate,
    required this.endDate,
    required this.periodCount,
    required this.startMoneyMinor,
    required this.incrementalMinor,
    required this.planMoneyMinor,
  });

  final String name;
  final int planType;
  final int cycleType;
  final LocalCalendarDate startDate;
  final LocalCalendarDate endDate;
  final int periodCount;
  final BigInt startMoneyMinor;
  final BigInt incrementalMinor;
  final BigInt planMoneyMinor;

  /// "365天存钱": N=365, start=1.00, inc=1.00 -> 66,795.00 (02aad SP-11).
  factory SavingsPlanTemplate.days365(LocalCalendarDate startDate) {
    final endDate = startDate.plusDays(364);
    final startMinor = BigInt.from(100);
    final incMinor = BigInt.from(100);
    final periods = countSchedulePeriods(
      start: startDate,
      end: endDate,
      cycleType: SavingsCycleType.daily,
    );
    final totalMinor = computePlanTargetMinor(
      planType: SavingsPlanType.incremental,
      periodCount: periods,
      startMoneyMinor: startMinor,
      incrementalMinor: incMinor,
    );
    return SavingsPlanTemplate(
      name: '365天存钱',
      planType: SavingsPlanType.incremental,
      cycleType: SavingsCycleType.daily,
      startDate: startDate,
      endDate: endDate,
      periodCount: periods,
      startMoneyMinor: startMinor,
      incrementalMinor: incMinor,
      planMoneyMinor: totalMinor,
    );
  }

  /// "52周存钱": N=52, start=10.00, inc=10.00 -> 13,780.00 (02aad SP-11).
  factory SavingsPlanTemplate.weeks52(LocalCalendarDate startDate) {
    final endDate = startDate.plusDays(51 * 7);
    final startMinor = BigInt.from(1000);
    final incMinor = BigInt.from(1000);
    final periods = countSchedulePeriods(
      start: startDate,
      end: endDate,
      cycleType: SavingsCycleType.weekly,
    );
    final totalMinor = computePlanTargetMinor(
      planType: SavingsPlanType.incremental,
      periodCount: periods,
      startMoneyMinor: startMinor,
      incrementalMinor: incMinor,
    );
    return SavingsPlanTemplate(
      name: '52周存钱',
      planType: SavingsPlanType.incremental,
      cycleType: SavingsCycleType.weekly,
      startDate: startDate,
      endDate: endDate,
      periodCount: periods,
      startMoneyMinor: startMinor,
      incrementalMinor: incMinor,
      planMoneyMinor: totalMinor,
    );
  }
}

const int _maxScheduleSlots = 36600;

/// Unified calendar progression used by BOTH form period counting and detail/auto-save
/// slot generation so leap-day ranges (e.g. `2024-02-29`..`2025-02-28`) never diverge
/// (R4 / CE-SP-03).
List<LocalCalendarDate> generateScheduleDates({
  required LocalCalendarDate start,
  required LocalCalendarDate end,
  required int cycleType,
}) {
  if (!SavingsCycleType.isValidScheduled(cycleType)) {
    throw const Failure(FailureCode.validation, '请选择有效的存钱周期');
  }
  if (end < start) {
    throw const Failure(FailureCode.validation, '结束日期不能早于开始日期');
  }
  final dates = <LocalCalendarDate>[];
  var cursor = start;
  while (cursor <= end) {
    dates.add(cursor);
    if (dates.length > _maxScheduleSlots) {
      throw const Failure(FailureCode.validation, '计划跨度超出上限（最多支持 36,600 期）');
    }
    cursor = cursor.stepCycle(cycleType);
  }
  return dates;
}

/// Counts total periods $N$ using the exact same progression as [generateScheduleDates].
int countSchedulePeriods({
  required LocalCalendarDate start,
  required LocalCalendarDate end,
  required int cycleType,
}) =>
    generateScheduleDates(start: start, end: end, cycleType: cycleType).length;

/// Amount for 0-based [slotIndex] of a scheduled plan.
BigInt computeSlotAmountMinor({
  required int planType,
  required int slotIndex,
  required BigInt startMoneyMinor,
  required BigInt incrementalMinor,
}) {
  if (slotIndex < 0) {
    throw const Failure(FailureCode.validation, '期次索引无效');
  }
  return switch (planType) {
    SavingsPlanType.incremental => Money.minor(
      startMoneyMinor + BigInt.from(slotIndex) * incrementalMinor,
    ).storageMinor,
    SavingsPlanType.fixed => Money.minor(startMoneyMinor).storageMinor,
    _ => throw const Failure(FailureCode.validation, '自由计划无固定期次金额'),
  };
}

/// Exact `BigInt` target formula (R1, SP-11):
/// - Incremental (`1`): $N \times \text{start} + \frac{N(N-1)}{2} \times \text{incremental}$
/// - Fixed (`2`): $N \times \text{start}$
/// - Free (`3`): [customPlanMoneyMinor]
BigInt computePlanTargetMinor({
  required int planType,
  int periodCount = 0,
  BigInt? startMoneyMinor,
  BigInt? incrementalMinor,
  BigInt? customPlanMoneyMinor,
}) {
  switch (planType) {
    case SavingsPlanType.incremental:
      if (periodCount <= 0) {
        throw const Failure(FailureCode.validation, '存钱期数须大于 0');
      }
      final start = startMoneyMinor ?? BigInt.zero;
      final inc = incrementalMinor ?? BigInt.zero;
      if (start <= BigInt.zero) {
        throw const Failure(FailureCode.validation, '起始金额须大于 0');
      }
      if (inc <= BigInt.zero) {
        throw const Failure(FailureCode.validation, '递增金额须大于 0');
      }
      final n = BigInt.from(periodCount);
      final triangular = (n * (n - BigInt.one)) ~/ BigInt.two;
      final total = n * start + triangular * inc;
      return Money.minor(total).storageMinor;

    case SavingsPlanType.fixed:
      if (periodCount <= 0) {
        throw const Failure(FailureCode.validation, '存钱期数须大于 0');
      }
      final start = startMoneyMinor ?? BigInt.zero;
      if (start <= BigInt.zero) {
        throw const Failure(FailureCode.validation, '每期金额须大于 0');
      }
      final total = BigInt.from(periodCount) * start;
      return Money.minor(total).storageMinor;

    case SavingsPlanType.free:
      final custom = customPlanMoneyMinor ?? BigInt.zero;
      if (custom <= BigInt.zero) {
        throw const Failure(FailureCode.validation, '目标金额须大于 0');
      }
      return Money.minor(custom).storageMinor;

    default:
      throw const Failure(FailureCode.validation, '未知的存钱计划类型');
  }
}

/// Back-calculates deposit delta from a cumulative target amount for a free plan
/// (R1, golden vector SP-23: `500 - 300 = 200`).
BigInt computeFreePlanDeltaMinor({
  required BigInt currentSavedMinor,
  required BigInt targetCumulativeMinor,
}) {
  if (targetCumulativeMinor <= BigInt.zero) {
    throw const Failure(FailureCode.validation, '目标累计金额须大于 0');
  }
  final delta = targetCumulativeMinor - currentSavedMinor;
  if (delta <= BigInt.zero) {
    throw const Failure(FailureCode.validation, '目标累计金额须大于当前已存金额');
  }
  return Money.minor(delta).storageMinor;
}

/// One theoretical schedule slot for incremental/fixed plans.
final class SavingsScheduleSlot {
  const SavingsScheduleSlot({
    required this.slotIndex,
    required this.date,
    required this.plannedMoneyMinor,
    required this.plannedCumulativeMinor,
  });

  /// 0-based slot index (period number = `slotIndex + 1`).
  final int slotIndex;
  final LocalCalendarDate date;
  final BigInt plannedMoneyMinor;
  final BigInt plannedCumulativeMinor;

  int get periodNumber => slotIndex + 1;
}

/// Generates all theoretical schedule slots for a scheduled plan (`planType` 1 or 2).
List<SavingsScheduleSlot> generateScheduleSlots({
  required int planType,
  required int cycleType,
  required LocalCalendarDate start,
  required LocalCalendarDate end,
  required BigInt startMoneyMinor,
  required BigInt incrementalMinor,
}) {
  final dates = generateScheduleDates(
    start: start,
    end: end,
    cycleType: cycleType,
  );
  final slots = <SavingsScheduleSlot>[];
  var cumulative = BigInt.zero;
  for (var i = 0; i < dates.length; i++) {
    final amount = computeSlotAmountMinor(
      planType: planType,
      slotIndex: i,
      startMoneyMinor: startMoneyMinor,
      incrementalMinor: incrementalMinor,
    );
    cumulative = Money.minor(cumulative + amount).storageMinor;
    slots.add(
      SavingsScheduleSlot(
        slotIndex: i,
        date: dates[i],
        plannedMoneyMinor: amount,
        plannedCumulativeMinor: cumulative,
      ),
    );
  }
  return slots;
}

/// Schedule slot paired with its matched deposit record (if checked in).
final class MergedSavingsSlot<T> {
  const MergedSavingsSlot({required this.slot, this.matchedRecord});

  final SavingsScheduleSlot slot;
  final T? matchedRecord;

  bool get isSaved => matchedRecord != null;
}

/// Free-plan deposit record row with running cumulative amount (DR-SP-04).
final class FreePlanRecordRow<T> {
  const FreePlanRecordRow({
    required this.record,
    required this.runningCumulativeMinor,
  });

  final T record;
  final BigInt runningCumulativeMinor;
}

/// Result of merging DB deposit records with a plan's schedule (R7 / CE-SP-07).
final class MergedSavingsSchedule<T> {
  const MergedSavingsSchedule({
    required this.slots,
    required this.outOfScheduleRecords,
    required this.freePlanRows,
  });

  /// Scheduled slots in chronological order (`planType` 1 or 2).
  final List<MergedSavingsSlot<T>> slots;

  /// Records falling outside current schedule slots (or duplicate same-day legacy
  /// records), ordered newest-first so zero historical records are ever hidden (CE-SP-07).
  final List<T> outOfScheduleRecords;

  /// Newest-first deposit rows with true running cumulative amounts (`planType` 3).
  final List<FreePlanRecordRow<T>> freePlanRows;
}

/// Merges stored deposit records with the plan's current schedule.
///
/// Guarantees `matchedSlots + outOfScheduleRecords == records` for scheduled plans,
/// preserving every historical record after plan date/cycle edits (R7 / CE-SP-07).
MergedSavingsSchedule<T> mergeSavingsSchedule<T>({
  required int planType,
  required int cycleType,
  required int startDateMs,
  required int endDateMs,
  required BigInt startMoneyMinor,
  required BigInt incrementalMinor,
  required List<T> records,
  required int Function(T) recordDateOf,
  required int Function(T) recordIdOf,
  required BigInt Function(T) recordMoneyOf,
}) {
  if (planType == SavingsPlanType.free) {
    // Sort oldest-first to accumulate true running totals, then reverse to newest-first.
    final chronological = [...records]
      ..sort((a, b) {
        final cmp = recordDateOf(a).compareTo(recordDateOf(b));
        return cmp != 0 ? cmp : recordIdOf(a).compareTo(recordIdOf(b));
      });
    var cumulative = BigInt.zero;
    final ascRows = <FreePlanRecordRow<T>>[];
    for (final r in chronological) {
      cumulative += recordMoneyOf(r);
      ascRows.add(
        FreePlanRecordRow(record: r, runningCumulativeMinor: cumulative),
      );
    }
    return MergedSavingsSchedule<T>(
      slots: const [],
      outOfScheduleRecords: const [],
      freePlanRows: ascRows.reversed.toList(growable: false),
    );
  }

  if (startDateMs < 0 ||
      endDateMs < 0 ||
      !SavingsCycleType.isValidScheduled(cycleType)) {
    final sortedDesc = [...records]
      ..sort((a, b) {
        final cmp = recordDateOf(b).compareTo(recordDateOf(a));
        return cmp != 0 ? cmp : recordIdOf(b).compareTo(recordIdOf(a));
      });
    return MergedSavingsSchedule<T>(
      slots: const [],
      outOfScheduleRecords: sortedDesc,
      freePlanRows: const [],
    );
  }

  final start = LocalCalendarDate.fromEpochMs(startDateMs);
  final end = LocalCalendarDate.fromEpochMs(endDateMs);
  if (end < start) {
    final sortedDesc = [...records]
      ..sort((a, b) {
        final cmp = recordDateOf(b).compareTo(recordDateOf(a));
        return cmp != 0 ? cmp : recordIdOf(b).compareTo(recordIdOf(a));
      });
    return MergedSavingsSchedule<T>(
      slots: const [],
      outOfScheduleRecords: sortedDesc,
      freePlanRows: const [],
    );
  }

  final rawSlots = generateScheduleSlots(
    planType: planType,
    cycleType: cycleType,
    start: start,
    end: end,
    startMoneyMinor: startMoneyMinor,
    incrementalMinor: incrementalMinor,
  );

  // Oldest record on a scheduled calendar day claims that slot (matching DR-SP-04);
  // any unmatched or extra historical record is surfaced in `outOfScheduleRecords`.
  final chronological = [...records]
    ..sort((a, b) {
      final cmp = recordDateOf(a).compareTo(recordDateOf(b));
      return cmp != 0 ? cmp : recordIdOf(a).compareTo(recordIdOf(b));
    });

  final slotDates = {for (final s in rawSlots) s.date};
  final matchedByDate = <LocalCalendarDate, T>{};
  final extras = <T>[];

  for (final rec in chronological) {
    final recDate = LocalCalendarDate.fromEpochMs(recordDateOf(rec));
    if (slotDates.contains(recDate) && !matchedByDate.containsKey(recDate)) {
      matchedByDate[recDate] = rec;
    } else {
      extras.add(rec);
    }
  }

  extras.sort((a, b) {
    final cmp = recordDateOf(b).compareTo(recordDateOf(a));
    return cmp != 0 ? cmp : recordIdOf(b).compareTo(recordIdOf(a));
  });

  final mergedSlots = [
    for (final s in rawSlots)
      MergedSavingsSlot<T>(slot: s, matchedRecord: matchedByDate[s.date]),
  ];

  return MergedSavingsSchedule<T>(
    slots: mergedSlots,
    outOfScheduleRecords: extras,
    freePlanRows: const [],
  );
}

/// 5-branch days copy formula (`conductTip`, DR-SP-06 / SP-01b).
String formatConductTip({
  required int startDateMs,
  required int endDateMs,
  required int status,
  required LocalCalendarDate today,
}) {
  final suffix = status == SavingsPlanStatus.archived ? ' 已归档计划' : '';
  if (startDateMs < 0) return '';
  final start = LocalCalendarDate.fromEpochMs(startDateMs);
  if (start > today) return suffix;
  if (endDateMs < 0) {
    final elapsed = start.daysUntil(today) + 1;
    return '已存钱$elapsed天$suffix';
  }
  final end = LocalCalendarDate.fromEpochMs(endDateMs);
  if (end < today) {
    final totalSpan = start.daysUntil(end) + 1;
    return '已存钱$totalSpan天$suffix';
  }
  final elapsed = start.daysUntil(today) + 1;
  if (status == SavingsPlanStatus.archived) {
    return '已存钱$elapsed天 已归档计划';
  }
  final remaining = today.daysUntil(end);
  return '已存钱$elapsed天，还剩$remaining天';
}

/// Progress in basis points (`10000` == `100.00%`), HALF_UP, purely in `BigInt`.
BigInt computeProgressBasisPoints(BigInt savedMinor, BigInt planMinor) {
  if (planMinor <= BigInt.zero || savedMinor <= BigInt.zero) {
    return BigInt.zero;
  }
  return divideRounded(
    savedMinor * BigInt.from(10000),
    planMinor,
    RoundingMode.halfUp,
  );
}

/// Formatted percentage string (e.g. `"66.79%"`, `"0.00%"`, `"100.00%"`).
String formatProgressPercent(BigInt savedMinor, BigInt planMinor) {
  final bps = computeProgressBasisPoints(savedMinor, planMinor);
  return '${Money.minor(bps).decimal}%';
}

/// Clamped integer progress in `0..1000` permille for progress bar rendering.
int clampedProgressPermille(BigInt savedMinor, BigInt planMinor) {
  final bps = computeProgressBasisPoints(savedMinor, planMinor);
  if (bps <= BigInt.zero) return 0;
  if (bps >= BigInt.from(10000)) return 1000;
  return divideRounded(bps, BigInt.from(10), RoundingMode.halfUp).toInt();
}

/// Checks whether [code] has a valid positive exchange rate in [rawRates].
bool hasValidExchangeRate(
  Map<String, String> rawRates,
  String? code, {
  String base = baseCurrency,
}) {
  final normalized = normalizeCurrency(code) ?? base;
  final anchor = normalizeCurrency(base) ?? baseCurrency;
  if (normalized == anchor) return true;
  for (final entry in rawRates.entries) {
    if (normalizeCurrency(entry.key) == normalized) {
      try {
        final parsed = DecimalValue.parse(entry.value.trim());
        return parsed.coefficient > BigInt.zero;
      } on Failure {
        return false;
      }
    }
  }
  return false;
}

Map<String, String> _validRateMap(
  Map<String, String> rawRates, {
  String base = baseCurrency,
}) {
  final anchor = normalizeCurrency(base) ?? baseCurrency;
  final map = <String, String>{anchor: '1'};
  for (final entry in rawRates.entries) {
    final code = normalizeCurrency(entry.key);
    if (code == null) continue;
    try {
      final parsed = DecimalValue.parse(entry.value.trim());
      if (parsed.coefficient > BigInt.zero) {
        map[code] = entry.value.trim();
      }
    } on Failure {
      // Ignore corrupt/invalid rate row; handled via hasValidExchangeRate.
    }
  }
  return map;
}

/// Input item for active savings summary header.
final class SavingsActivePlanInput {
  const SavingsActivePlanInput({
    required this.id,
    required this.savedMoneyMinor,
    required this.currency,
  });

  final int id;
  final BigInt savedMoneyMinor;
  final String? currency;
}

/// Summary of active (`status == 0`) savings plans in base currency (DR-SP-06, CE-SP-08).
final class SavingsActiveSummary {
  const SavingsActiveSummary({
    required this.totalSavedBaseMinor,
    required this.activeCount,
    required this.missingRates,
  });

  final BigInt totalSavedBaseMinor;
  final int activeCount;
  final Set<String> missingRates;
}

/// Summarizes active savings plans in [base] currency using exact `BigInt` math.
///
/// Unlike the original app's silent 1:1 fallback (`CE-SP-08`), any active foreign
/// plan lacking a valid positive exchange rate is reported in [missingRates] and
/// NOT falsely added 1:1 as base currency.
SavingsActiveSummary summarizeActiveSavingsPlans({
  required Iterable<SavingsActivePlanInput> plans,
  required Map<String, String> rawRates,
  String base = baseCurrency,
}) {
  final anchor = normalizeCurrency(base) ?? baseCurrency;
  final validMap = _validRateMap(rawRates, base: anchor);
  final rateTable = RateTable(validMap, base: anchor);
  final missing = <String>{};
  var total = BigInt.zero;
  var count = 0;

  for (final p in plans) {
    count++;
    if (p.savedMoneyMinor == BigInt.zero) continue;
    final curr = normalizeCurrency(p.currency) ?? anchor;
    if (curr == anchor) {
      total += p.savedMoneyMinor;
      continue;
    }
    if (!hasValidExchangeRate(rawRates, curr, base: anchor)) {
      missing.add(curr);
      continue;
    }
    total += rateTable.convert(p.savedMoneyMinor, curr, anchor);
  }

  return SavingsActiveSummary(
    totalSavedBaseMinor: Money.minor(total, anchor).storageMinor,
    activeCount: count,
    missingRates: missing,
  );
}

/// Quoted transfer amounts and optional `extra_info.curr` snapshot for R5 / CE-SP-08.
final class SavingsTransferQuote {
  const SavingsTransferQuote({
    required this.fromCurrency,
    required this.fromMinor,
    required this.toCurrency,
    required this.toMinor,
    required this.snapshot,
  });

  final String fromCurrency;
  final BigInt fromMinor;
  final String toCurrency;
  final BigInt toMinor;
  final CurrencySnapshot? snapshot;
}

/// Computes exact source debit (`fromMinor`), target credit (`toMinor`), and
/// `CurrencySnapshot` for a savings transfer, throwing `FailureCode.validation`
/// if any required foreign exchange rate is missing or `<= 0` (R5 / CE-SP-08).
SavingsTransferQuote quoteSavingsTransfer({
  required BigInt depositPlanMinor,
  required String? planCurrency,
  required String? fromAssetCurrency,
  required String? toAssetCurrency,
  required Map<String, String> rawRates,
  String base = baseCurrency,
}) {
  if (depositPlanMinor <= BigInt.zero) {
    throw const Failure(FailureCode.validation, '存入金额须大于 0');
  }
  final anchor = normalizeCurrency(base) ?? baseCurrency;
  final pCurr = normalizeCurrency(planCurrency) ?? anchor;
  final fCurr = normalizeCurrency(fromAssetCurrency) ?? anchor;
  final tCurr = normalizeCurrency(toAssetCurrency) ?? anchor;

  // Same currency across plan, source, and target: no FX conversion needed!
  if (pCurr == fCurr && fCurr == tCurr && fCurr == anchor) {
    final minor = Money.minor(depositPlanMinor, anchor).storageMinor;
    return SavingsTransferQuote(
      fromCurrency: anchor,
      fromMinor: minor,
      toCurrency: anchor,
      toMinor: minor,
      snapshot: null,
    );
  }

  // Validate required exchange rates strictly (CE-SP-08: never fallback to 1:1).
  final neededCurrencies = <String>{
    if (fCurr != pCurr) ...[pCurr, fCurr],
    if (tCurr != pCurr) ...[pCurr, tCurr],
    if (fCurr != anchor || tCurr != anchor) ...[fCurr, tCurr],
  };
  for (final code in neededCurrencies) {
    if (!hasValidExchangeRate(rawRates, code, base: anchor)) {
      throw Failure(FailureCode.validation, '外币 $code 汇率缺失或无效，请先设置有效汇率');
    }
  }

  final rateTable = RateTable(
    _validRateMap(rawRates, base: anchor),
    base: anchor,
  );

  final toMinor = tCurr == pCurr
      ? depositPlanMinor
      : rateTable.convert(depositPlanMinor, pCurr, tCurr);
  final fromMinor = fCurr == pCurr
      ? depositPlanMinor
      : (fCurr == tCurr
            ? toMinor
            : rateTable.convert(depositPlanMinor, pCurr, fCurr));

  if (fromMinor <= BigInt.zero || toMinor <= BigInt.zero) {
    throw const Failure(FailureCode.validation, '折算后转账金额须大于 0');
  }

  final snapshot = billSnapshot(
    source: fCurr,
    sourceMinor: Money.minor(fromMinor, fCurr).storageMinor,
    account: tCurr,
    assetMinor: Money.minor(toMinor, tCurr).storageMinor,
    rates: rateTable,
  );

  return SavingsTransferQuote(
    fromCurrency: fCurr,
    fromMinor: Money.minor(fromMinor, fCurr).storageMinor,
    toCurrency: tCurr,
    toMinor: Money.minor(toMinor, tCurr).storageMinor,
    snapshot: snapshot,
  );
}
