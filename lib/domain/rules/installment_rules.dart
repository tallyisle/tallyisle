import 'dart:convert';

import '../../core/failure.dart';
import '../../core/money.dart';
import '../ledger/asset_json.dart';
import '../model/codes.dart';

/// Rounding / base-amount mode (`installment.cal_way`, DR-009 / 02w).
abstract final class InstallmentCalWay {
  /// Keep 2 decimals, floor (`FLOOR2`).
  static const floor2 = 0;

  /// Whole currency unit (0 decimals), round half-up (`HALF_UP0`).
  static const halfUp0 = 1;

  /// Keep 2 decimals, round half-up (`HALF_UP2`).
  static const halfUp2 = 2;

  /// Whole currency unit (0 decimals), floor (`FLOOR0`).
  static const floor0 = 3;

  static const valid = <int>{floor2, halfUp0, halfUp2, floor0};

  static String labelOf(int calWay) => switch (calWay) {
    floor2 => '保留两位小数（舍去余数）',
    halfUp0 => '取整（四舍五入）',
    halfUp2 => '保留两位小数（四舍五入）',
    floor0 => '取整（舍去余数）',
    _ => '保留两位小数（四舍五入）',
  };
}

/// Total fee allocation mode (`installment.charge_way`, DR-009 / 02w).
abstract final class InstallmentChargeWay {
  /// Full total fee charged in period 1.
  static const firstPeriod = 0;

  /// Total fee amortized across all periods using `cal_way` + `remainder_in`.
  static const perPeriod = 1;

  /// Full total fee charged in the final period.
  static const lastPeriod = 2;

  static const valid = <int>{firstPeriod, perPeriod, lastPeriod};

  static String labelOf(int chargeWay) => switch (chargeWay) {
    firstPeriod => '首期全额收取',
    perPeriod => '每期均摊收取',
    lastPeriod => '末期全额收取',
    _ => '每期均摊收取',
  };
}

/// Target period for division remainder (`installment.remainder_in`, DR-009 / 02w).
abstract final class InstallmentRemainderIn {
  static const firstPeriod = 0;
  static const lastPeriod = 1;

  static const valid = <int>{firstPeriod, lastPeriod};

  static String labelOf(int remainderIn) => switch (remainderIn) {
    firstPeriod => '计入首期',
    lastPeriod => '计入末期',
    _ => '计入首期',
  };
}

/// Per-period posting state (`M-INST-16`, 02w).
abstract final class InstallmentPeriodState {
  static const credited = 0;
  static const pending = 1;
}

const _corruptExtra = Failure(FailureCode.corruptData, '分期附加信息格式损坏');

/// Typed view of `installment.exi` JSON. Unknown keys are preserved on rewrite.
final class InstallmentExtra {
  InstallmentExtra([Map<String, Object?>? raw]) : raw = {...?raw};
  final Map<String, Object?> raw;

  static InstallmentExtra parse(String? text) {
    if (text == null || text.trim().isEmpty) return InstallmentExtra();
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw _corruptExtra;
    }
    if (decoded is! Map<String, Object?>) throw _corruptExtra;
    return InstallmentExtra(decoded);
  }

  String? encode() => raw.isEmpty ? null : jsonEncode(raw);

  bool? _bool(String key) {
    final v = raw[key];
    if (v == null) return null;
    if (v is bool) return v;
    if (v is int) return v != 0;
    throw _corruptExtra;
  }

  int? _int(String key) {
    final v = raw[key];
    if (v == null) return null;
    if (v is int) return v;
    throw _corruptExtra;
  }

  BigInt? _minor(String key) {
    final v = raw[key];
    if (v == null) return null;
    if (v is String) return BigInt.tryParse(v) ?? (throw _corruptExtra);
    if (v is int) return BigInt.from(v);
    throw _corruptExtra;
  }

  /// Whether uncredited principal counts toward credit-card debt/limit (`cb`).
  bool get principalCounted => _bool('cb') ?? true;
  set principalCounted(bool v) => raw['cb'] = v;

  /// Whether uncredited fee counts toward credit-card debt/limit (`ci`).
  bool get interestCounted => _bool('ci') ?? false;
  set interestCounted(bool v) => raw['ci'] = v;

  /// Whether the installment was closed via early full settlement.
  bool get settledEarly => _bool('settled_early') ?? false;
  set settledEarly(bool v) {
    if (!v) {
      raw.remove('settled_early');
    } else {
      raw['settled_early'] = true;
    }
  }

  int? get settledAt => _int('settled_at');
  set settledAt(int? v) {
    if (v == null) {
      raw.remove('settled_at');
    } else {
      raw['settled_at'] = v;
    }
  }

  int? get settledPeriod => _int('settled_period');
  set settledPeriod(int? v) {
    if (v == null) {
      raw.remove('settled_period');
    } else {
      raw['settled_period'] = v;
    }
  }

  BigInt? get settledPrincipalMinor => _minor('settled_principal');
  set settledPrincipalMinor(BigInt? v) {
    if (v == null) {
      raw.remove('settled_principal');
    } else {
      raw['settled_principal'] = v.toString();
    }
  }

  BigInt? get settledFeeMinor => _minor('settled_fee');
  set settledFeeMinor(BigInt? v) {
    if (v == null) {
      raw.remove('settled_fee');
    } else {
      raw['settled_fee'] = v.toString();
    }
  }

  BigInt? get waivedFeeMinor => _minor('waived_fee');
  set waivedFeeMinor(BigInt? v) {
    if (v == null) {
      raw.remove('waived_fee');
    } else {
      raw['waived_fee'] = v.toString();
    }
  }
}

/// Formats `record.installment` string `"<installmentId>-<period>"` (DR-009).
String formatInstallmentRecordKey(int installmentId, int period) =>
    '$installmentId-$period';

/// Parses `"<installmentId>-<period>"`; returns null for non-matching strings.
({int installmentId, int period})? parseInstallmentRecordKey(String? value) {
  if (value == null) return null;
  final match = RegExp(r'^([0-9]+)-([0-9]+)$').firstMatch(value.trim());
  if (match == null) return null;
  final id = int.tryParse(match.group(1)!);
  final period = int.tryParse(match.group(2)!);
  if (id == null || period == null || id <= 0 || period <= 0) return null;
  return (installmentId: id, period: period);
}

/// Parses `installment.credited` JSON (`List<int>`) with deduplication,
/// ascending sort, and optional `[1..maxPeriod]` bounds filtering (ASYM-INST-04).
List<int> parseCreditedPeriods(String? creditedJson, {int? maxPeriod}) {
  if (creditedJson == null || creditedJson.trim().isEmpty) return const [];
  final Object? decoded;
  try {
    decoded = jsonDecode(creditedJson);
  } on FormatException {
    throw const Failure(FailureCode.corruptData, '分期已入账期次格式损坏');
  }
  if (decoded is! List) {
    throw const Failure(FailureCode.corruptData, '分期已入账期次格式损坏');
  }
  final set = <int>{};
  for (final item in decoded) {
    final int? p = switch (item) {
      int v => v,
      String s => int.tryParse(s.trim()),
      _ => null,
    };
    if (p == null || p < 1) continue;
    if (maxPeriod != null && p > maxPeriod) continue;
    set.add(p);
  }
  final sorted = set.toList()..sort();
  return List<int>.unmodifiable(sorted);
}

/// Encodes `credited` periods as canonical sorted JSON array string.
String encodeCreditedPeriods(Iterable<int> periods, {int? maxPeriod}) {
  final set = <int>{};
  for (final p in periods) {
    if (p < 1) continue;
    if (maxPeriod != null && p > maxPeriod) continue;
    set.add(p);
  }
  final sorted = set.toList()..sort();
  return jsonEncode(sorted);
}

/// Parses comma-separated `installment.tags`.
List<String> parseInstallmentTags(String? tagsCsv) {
  if (tagsCsv == null || tagsCsv.trim().isEmpty) return const [];
  final seen = <String>{};
  final result = <String>[];
  for (final part in tagsCsv.split(',')) {
    final trimmed = part.trim();
    if (trimmed.isNotEmpty && seen.add(trimmed)) {
      result.add(trimmed);
    }
  }
  return List<String>.unmodifiable(result);
}

/// Encodes tag IDs to comma-separated text (or null when empty).
String? encodeInstallmentTags(Iterable<String> tagIds) {
  final cleaned = <String>[];
  final seen = <String>{};
  for (final tag in tagIds) {
    final trimmed = tag.trim();
    if (trimmed.isNotEmpty && seen.add(trimmed)) {
      cleaned.add(trimmed);
    }
  }
  return cleaned.isEmpty ? null : cleaned.join(',');
}

/// Validates user input parameters for creating an installment.
void validateInstallmentInput({
  required String name,
  required Money principal,
  required int periods,
  required Money charge,
  required int chargeWay,
  required int calWay,
  required int remainderIn,
  required int assetId,
}) {
  final trimmed = name.trim();
  if (trimmed.isEmpty || trimmed.length > 50) {
    throw const Failure(FailureCode.validation, '分期名称须为 1–50 字');
  }
  if (principal.scale != Money.ledgerScale ||
      charge.scale != Money.ledgerScale) {
    throw const Failure(FailureCode.scaleMismatch, '分期金额须为两位小数');
  }
  if (principal.storageMinor <= BigInt.zero) {
    throw const Failure(FailureCode.validation, '分期总本金须大于 0');
  }
  if (periods < 1 || periods > 360) {
    throw const Failure(FailureCode.validation, '分期期数须在 1–360 期之间');
  }
  if (charge.storageMinor < BigInt.zero) {
    throw const Failure(FailureCode.validation, '分期手续费不能为负数');
  }
  if (!InstallmentChargeWay.valid.contains(chargeWay)) {
    throw const Failure(FailureCode.validation, '手续费收取方式无效');
  }
  if (!InstallmentCalWay.valid.contains(calWay)) {
    throw const Failure(FailureCode.validation, '每期取舍方式无效');
  }
  if (!InstallmentRemainderIn.valid.contains(remainderIn)) {
    throw const Failure(FailureCode.validation, '余数归属方式无效');
  }
  if (assetId == noRef || assetId <= 0) {
    throw const Failure(FailureCode.validation, '请选择扣款账户');
  }
}

/// Computes the base per-period amount in minor units (`M-INST-06`, R1).
///
/// Pure `BigInt` integer math:
/// - `floor2` (0): floor to 1 minor unit (0.01)
/// - `halfUp0` (1): half-up to 100 minor units (1.00)
/// - `halfUp2` (2): half-up to 1 minor unit (0.01)
/// - `floor0` (3): floor to 100 minor units (1.00)
BigInt computeBasePerPeriod(BigInt totalMinor, int periods, int calWay) {
  if (periods < 1) {
    throw const Failure(FailureCode.validation, '分期期数须大于 0');
  }
  final n = BigInt.from(periods);
  final hundred = BigInt.from(100);
  return switch (calWay) {
    InstallmentCalWay.floor2 => divideRounded(
      totalMinor,
      n,
      RoundingMode.floor,
    ),
    InstallmentCalWay.halfUp0 =>
      divideRounded(totalMinor, n * hundred, RoundingMode.halfUp) * hundred,
    InstallmentCalWay.halfUp2 => divideRounded(
      totalMinor,
      n,
      RoundingMode.halfUp,
    ),
    InstallmentCalWay.floor0 =>
      divideRounded(totalMinor, n * hundred, RoundingMode.floor) * hundred,
    _ => divideRounded(totalMinor, n, RoundingMode.halfUp),
  };
}

/// Allocates [totalMinor] across [periods] with exact conservation (`M-INST-04/05`).
///
/// Remainder `totalMinor - base * periods` (which may be negative, e.g. AL-29/30)
/// is added to period 1 (`remainderIn == 0`) or period `periods` (`remainderIn == 1`).
({BigInt baseMinor, BigInt remainderMinor, List<BigInt> amountsMinor})
allocateAcrossPeriods({
  required BigInt totalMinor,
  required int periods,
  required int calWay,
  required int remainderIn,
}) {
  if (periods < 1) {
    throw const Failure(FailureCode.validation, '分期期数须大于 0');
  }
  final base = computeBasePerPeriod(totalMinor, periods, calWay);
  final remainder = totalMinor - base * BigInt.from(periods);
  final list = List<BigInt>.filled(periods, base);
  final targetIdx = remainderIn == InstallmentRemainderIn.firstPeriod
      ? 0
      : periods - 1;
  if (remainder != BigInt.zero) {
    list[targetIdx] = list[targetIdx] + remainder;
  }
  return (
    baseMinor: base,
    remainderMinor: remainder,
    amountsMinor: List<BigInt>.unmodifiable(list),
  );
}

/// Planned local calendar date for 1-based [period] (`1..periods + 1`),
/// anchored to [startLocalDate] with month-end clamping (`M-INST-17`, R2).
DateTime installmentPeriodLocalDate(DateTime startLocalDate, int period) {
  if (period < 1) {
    throw const Failure(FailureCode.validation, '期号须从第 1 期开始');
  }
  final zeroBasedMonth =
      startLocalDate.year * 12 + (startLocalDate.month - 1) + (period - 1);
  final year = zeroBasedMonth ~/ 12;
  final month = (zeroBasedMonth % 12) + 1;
  final maxDay = DateTime(year, month + 1, 0).day;
  final day = startLocalDate.day > maxDay ? maxDay : startLocalDate.day;
  return DateTime(year, month, day);
}

/// Planned date epoch ms (at local 00:00:00.000) for 1-based [period].
int installmentPeriodDateMs(int startDateMs, int period) {
  final s = DateTime.fromMillisecondsSinceEpoch(startDateMs);
  return installmentPeriodLocalDate(
    DateTime(s.year, s.month, s.day),
    period,
  ).millisecondsSinceEpoch;
}

/// Deterministic `record_time` for an automatic due-period catch-up post:
/// uses [nowMs] when due date is today in local calendar, else local 12:00:00
/// on the planned date so statement-cycle bucketing is deterministic.
int dueRecordTimestampMs({required int plannedDateMs, required int nowMs}) {
  final planned = DateTime.fromMillisecondsSinceEpoch(plannedDateMs);
  final now = DateTime.fromMillisecondsSinceEpoch(nowMs);
  if (planned.year == now.year &&
      planned.month == now.month &&
      planned.day == now.day) {
    return nowMs;
  }
  return DateTime(
    planned.year,
    planned.month,
    planned.day,
    12,
  ).millisecondsSinceEpoch;
}

/// Whether [plannedDateMs] is due on or before the local calendar day of [nowMs].
bool isPeriodDueOnOrBefore({required int plannedDateMs, required int nowMs}) {
  final p = DateTime.fromMillisecondsSinceEpoch(plannedDateMs);
  final n = DateTime.fromMillisecondsSinceEpoch(nowMs);
  final pDay = DateTime(p.year, p.month, p.day);
  final nDay = DateTime(n.year, n.month, n.day);
  return !pDay.isAfter(nDay);
}

/// One period row in an installment repayment schedule (`M-INST-16`).
final class InstallmentPeriodItem {
  const InstallmentPeriodItem({
    required this.installmentId,
    required this.period,
    required this.plannedDateMs,
    required this.principalMinor,
    required this.feeMinor,
    required this.state,
  });

  final int installmentId;

  /// 1-based period index (`1..periods`).
  final int period;
  final int plannedDateMs;
  final BigInt principalMinor;
  final BigInt feeMinor;

  /// `0` = credited (`InstallmentPeriodState.credited`), `1` = pending.
  final int state;

  BigInt get totalMinor => principalMinor + feeMinor;
  bool get isCredited => state == InstallmentPeriodState.credited;
  String get recordKey => formatInstallmentRecordKey(installmentId, period);
}

/// Builds the full `1..periods` schedule with exact principal & fee conservation.
List<InstallmentPeriodItem> buildInstallmentSchedule({
  required int installmentId,
  required BigInt principalMinor,
  required int periods,
  required BigInt chargeMinor,
  required int chargeWay,
  required int calWay,
  required int remainderIn,
  required int startDateMs,
  Iterable<int> creditedPeriods = const [],
}) {
  if (periods < 1) {
    throw const Failure(FailureCode.validation, '分期期数须大于 0');
  }
  final principalAlloc = allocateAcrossPeriods(
    totalMinor: principalMinor,
    periods: periods,
    calWay: calWay,
    remainderIn: remainderIn,
  ).amountsMinor;

  final List<BigInt> feeAlloc;
  if (chargeMinor <= BigInt.zero) {
    feeAlloc = List<BigInt>.filled(periods, BigInt.zero);
  } else if (chargeWay == InstallmentChargeWay.firstPeriod) {
    final list = List<BigInt>.filled(periods, BigInt.zero);
    list[0] = chargeMinor;
    feeAlloc = list;
  } else if (chargeWay == InstallmentChargeWay.perPeriod) {
    feeAlloc = allocateAcrossPeriods(
      totalMinor: chargeMinor,
      periods: periods,
      calWay: calWay,
      remainderIn: remainderIn,
    ).amountsMinor;
  } else {
    final list = List<BigInt>.filled(periods, BigInt.zero);
    list[periods - 1] = chargeMinor;
    feeAlloc = list;
  }

  final creditedSet = <int>{
    for (final p in creditedPeriods)
      if (p >= 1 && p <= periods) p,
  };

  return List<InstallmentPeriodItem>.unmodifiable([
    for (var i = 0; i < periods; i++)
      InstallmentPeriodItem(
        installmentId: installmentId,
        period: i + 1,
        plannedDateMs: installmentPeriodDateMs(startDateMs, i + 1),
        principalMinor: principalAlloc[i],
        feeMinor: feeAlloc[i],
        state: creditedSet.contains(i + 1)
            ? InstallmentPeriodState.credited
            : InstallmentPeriodState.pending,
      ),
  ]);
}

/// Advances `next_period` along the contiguous credited range (`M-INST-17`).
({int nextPeriod, int nextPeriodDateMs, bool isFinished}) advanceNextPeriod({
  required int currentNextPeriod,
  required int periods,
  required Iterable<int> creditedPeriods,
  required int startDateMs,
}) {
  final creditedSet = <int>{
    for (final p in creditedPeriods)
      if (p >= 1 && p <= periods) p,
  };
  var next = currentNextPeriod < 1 ? 1 : currentNextPeriod;
  while (next <= periods && creditedSet.contains(next)) {
    next++;
  }
  if (next > periods + 1) next = periods + 1;
  return (
    nextPeriod: next,
    nextPeriodDateMs: installmentPeriodDateMs(startDateMs, next),
    isFinished: next > periods,
  );
}

/// Computed progress and remaining balances of an installment (`M-INST-17/18`).
final class InstallmentProgress {
  const InstallmentProgress({
    required this.periods,
    required this.creditedPeriods,
    required this.creditedPrincipalMinor,
    required this.creditedFeeMinor,
    required this.remainingPrincipalMinor,
    required this.remainingFeeMinor,
    required this.nextPeriod,
    required this.nextPeriodDateMs,
  });

  final int periods;
  final List<int> creditedPeriods;
  final BigInt creditedPrincipalMinor;
  final BigInt creditedFeeMinor;
  final BigInt remainingPrincipalMinor;
  final BigInt remainingFeeMinor;
  final int nextPeriod;
  final int nextPeriodDateMs;

  int get creditedCount => creditedPeriods.length;
  int get remainingCount => periods - creditedPeriods.length;
  BigInt get creditedTotalMinor => creditedPrincipalMinor + creditedFeeMinor;
  BigInt get remainingTotalMinor => remainingPrincipalMinor + remainingFeeMinor;
  bool get isFinished => nextPeriod > periods;
}

/// Computes remaining principal/fee and next cursor from [schedule] (`M-INST-18`).
InstallmentProgress computeInstallmentProgress({
  required List<InstallmentPeriodItem> schedule,
  required BigInt principalMinor,
  required BigInt chargeMinor,
  required int startDateMs,
  int currentNextPeriod = 1,
}) {
  final periods = schedule.length;
  var creditedPrincipal = BigInt.zero;
  var creditedFee = BigInt.zero;
  final creditedList = <int>[];

  for (final item in schedule) {
    if (item.isCredited) {
      creditedList.add(item.period);
      creditedPrincipal += item.principalMinor;
      creditedFee += item.feeMinor;
    }
  }

  final cursor = advanceNextPeriod(
    currentNextPeriod: currentNextPeriod,
    periods: periods,
    creditedPeriods: creditedList,
    startDateMs: startDateMs,
  );

  return InstallmentProgress(
    periods: periods,
    creditedPeriods: List<int>.unmodifiable(creditedList),
    creditedPrincipalMinor: creditedPrincipal,
    creditedFeeMinor: creditedFee,
    remainingPrincipalMinor: principalMinor - creditedPrincipal,
    remainingFeeMinor: chargeMinor - creditedFee,
    nextPeriod: cursor.nextPeriod,
    nextPeriodDateMs: cursor.nextPeriodDateMs,
  );
}

/// Synchronizes a credit card's `credit_info.inst` (`UncreditedInstallment`)
/// entry for [installmentId] (R5 / DR-AST-05).
///
/// - Preserves all other keys in `CreditInfo` and all other installment IDs.
/// - Removes `[installmentId]` when [remove] or [isFinished] is true (leaving
///   `inst: []` when empty so `uncreditedInstallment(creditInfo)` returns `0`
///   instead of falling back to legacy `installment`).
String? syncCreditInfoInstallment({
  required String? currentCreditInfoJson,
  required int installmentId,
  required BigInt remainingPrincipalMinor,
  required BigInt remainingFeeMinor,
  required bool isFinished,
  bool principalCounted = true,
  bool interestCounted = false,
  bool remove = false,
}) {
  final info = CreditInfo.parse(currentCreditInfoJson);
  final iid = '$installmentId';
  final existing = info.installments ?? const <UncreditedInstallment>[];
  final others = <UncreditedInstallment>[
    for (final item in existing)
      if (item.id != iid) item,
  ];

  if (remove || isFinished) {
    info.installments = others;
  } else {
    info.installments = [
      ...others,
      UncreditedInstallment(
        id: iid,
        principal: remainingPrincipalMinor,
        interest: remainingFeeMinor,
        principalCounted: principalCounted,
        interestCounted: interestCounted,
      ),
    ];
  }
  return info.encode();
}
