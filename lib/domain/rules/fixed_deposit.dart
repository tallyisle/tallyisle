import 'dart:convert';

import '../../core/failure.dart';
import '../../core/money.dart';
import '../ledger/record_extra.dart';
import '../model/codes.dart';
import 'asset_overview.dart';
import 'currency_rates.dart';

/// Period unit codes in `fixed_deposit_info.period_unit` (`docs/modules/fixed-deposit.md` §2).
abstract final class DepositPeriodUnit {
  static const month = 1;
  static const year = 2;
}

/// Deposit lifecycle status codes in `fixed_deposit_info.status` (`docs/modules/fixed-deposit.md` §2).
abstract final class FixedDepositStatus {
  static const running = 0;
  static const settled = 1;
}

const _corruptDeposit = Failure(FailureCode.corruptData, '定期存款数据格式损坏');

/// Account type gate (R1): excludes credit cards (`6`) and debt accounts (`4`).
bool isFixedDepositEligibleType(int assetType) =>
    assetType != AssetType.credit && assetType != AssetType.debt;

/// Uniform account eligibility gate (R1 + ASYM-FD-06): active and eligible type.
/// Note: `isEffectiveAsset == 0` active accounts remain eligible (SQL-FD-01).
bool isFixedDepositEligibleAccount({required int type, required int status}) =>
    status == AssetStatus.active && isFixedDepositEligibleType(type);

/// Parses a decimal from a `DecimalValue`, string, int, or legacy JSON number
/// without any floating-point arithmetic.
DecimalValue parseFlexibleDecimal(Object? raw) {
  if (raw is DecimalValue) return raw;
  if (raw is BigInt) return DecimalValue(raw, 0);
  if (raw is int) return DecimalValue(BigInt.from(raw), 0);
  final String text;
  if (raw is String) {
    text = raw.trim();
  } else if (raw is num) {
    text = raw.toString().trim();
  } else {
    throw _corruptDeposit;
  }
  if (text.isEmpty) {
    throw const Failure(FailureCode.validation, '请输入有效数值');
  }
  return _parseDecimalOrScientific(text);
}

DecimalValue _parseDecimalOrScientific(String input) {
  final match = RegExp(
    r'^([+-]?)(?:([0-9]+)(?:\.([0-9]*))?|\.([0-9]+))(?:[eE]([+-]?[0-9]+))?$',
  ).firstMatch(input);
  if (match == null) {
    throw const Failure(FailureCode.validation, '请输入有效的十进制数');
  }
  final sign = match.group(1) == '-' ? '-' : '';
  final intPart = match.group(2) ?? '0';
  final fracPart = match.group(3) ?? match.group(4) ?? '';
  final expText = match.group(5);
  final exp = expText == null ? 0 : int.parse(expText);

  final digits = '$intPart$fracPart';
  var scale = fracPart.length - exp;
  var coeff = BigInt.parse('$sign$digits');
  if (coeff == BigInt.zero) {
    return DecimalValue(BigInt.zero, scale.clamp(0, 30));
  }
  if (scale < 0) {
    final shift = -scale;
    if (shift > 30) {
      throw const Failure(FailureCode.validation, '数值超出精度范围');
    }
    coeff *= powerOfTen(shift);
    scale = 0;
  } else if (scale > 30) {
    // Round ultra-deep scales cleanly to 30 decimal places HALF_UP.
    final extra = scale - 30;
    final factor = BigInt.from(10).pow(extra);
    coeff = divideRounded(coeff, factor, RoundingMode.halfUp);
    scale = 30;
  }
  return DecimalValue(coeff, scale);
}

/// Formats [value] as an exact decimal string without floating-point math.
String formatDecimalValue(
  DecimalValue value, {
  bool trimTrailingZeros = false,
}) {
  if (value.scale == 0) return value.coefficient.toString();
  final negative = value.coefficient.isNegative;
  final digits = value.coefficient.abs().toString().padLeft(
    value.scale + 1,
    '0',
  );
  final head = digits.substring(0, digits.length - value.scale);
  final tail = digits.substring(digits.length - value.scale);
  var formatted = '${negative ? '-' : ''}$head.$tail';
  if (trimTrailingZeros && formatted.contains('.')) {
    formatted = formatted.replaceFirst(RegExp(r'0+$'), '');
    if (formatted.endsWith('.')) {
      formatted = formatted.substring(0, formatted.length - 1);
    }
    if (formatted == '-0') formatted = '0';
  }
  return formatted;
}

/// Converts user-entered percentage text (e.g. `'2.4'` for `2.4%`) to a stored
/// decimal rate (`0.024`).
DecimalValue percentToAnnualRate(String percentText) {
  final trimmed = percentText.trim();
  if (trimmed.isEmpty) {
    throw const Failure(FailureCode.validation, '请输入年化利率');
  }
  final parsed = _parseDecimalOrScientific(trimmed);
  if (parsed.coefficient.isNegative) {
    throw const Failure(FailureCode.validation, '年化利率不能为负数');
  }
  final nextScale = parsed.scale + 2;
  if (nextScale <= 30) {
    return DecimalValue(parsed.coefficient, nextScale);
  }
  final shifted = divideRounded(
    parsed.coefficient,
    BigInt.from(10).pow(nextScale - 30),
    RoundingMode.halfUp,
  );
  return DecimalValue(shifted, 30);
}

/// Formats stored fractional [annualRate] (`0.024`) as percentage text (`'2.4'`).
String annualRateToPercentString(DecimalValue annualRate) {
  if (annualRate.scale >= 2) {
    return formatDecimalValue(
      DecimalValue(annualRate.coefficient, annualRate.scale - 2),
      trimTrailingZeros: true,
    );
  }
  final factor = powerOfTen(2 - annualRate.scale);
  return formatDecimalValue(
    DecimalValue(annualRate.coefficient * factor, 0),
    trimTrailingZeros: true,
  );
}

/// Number of days in [year]-[month] (1..12).
int daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

/// Calendar maturity calculation (R2): preserves local time-of-day, clamps
/// `periodCount` to `>= 1`, and clamps short months / leap years naturally
/// (e.g. Jan 31 + 1 month -> Feb 28/29; 2024-02-29 + 1 year -> 2025-02-28).
int calculateDueDate({
  required int depositDateMs,
  required int periodUnit,
  required int periodCount,
}) {
  final start = DateTime.fromMillisecondsSinceEpoch(depositDateMs);
  final count = periodCount < 1 ? 1 : periodCount;
  final int targetYear;
  final int targetMonth;
  if (periodUnit == DepositPeriodUnit.month) {
    final zeroBasedMonths = start.year * 12 + (start.month - 1) + count;
    targetYear = zeroBasedMonths ~/ 12;
    targetMonth = (zeroBasedMonths % 12) + 1;
  } else {
    targetYear = start.year + count;
    targetMonth = start.month;
  }
  final maxDay = daysInMonth(targetYear, targetMonth);
  final targetDay = start.day > maxDay ? maxDay : start.day;
  return DateTime(
    targetYear,
    targetMonth,
    targetDay,
    start.hour,
    start.minute,
    start.second,
    start.millisecond,
  ).millisecondsSinceEpoch;
}

/// Original `mul6(a, b)` operator (R2 / FD-F01):
/// rounds both operands to 6 decimal places `HALF_UP` before multiplying,
/// and rounds the product to 6 decimal places `HALF_UP`.
DecimalValue mul6(DecimalValue a, DecimalValue b) {
  final a6 = a.unitsAt(6, rounding: RoundingMode.halfUp);
  final b6 = b.unitsAt(6, rounding: RoundingMode.halfUp);
  final prod6 = divideRounded(a6 * b6, powerOfTen(6), RoundingMode.halfUp);
  return DecimalValue(prod6, 6);
}

/// Pure single-interest formula (R2 / FD-F01):
/// - Monthly (`periodUnit == 1`): `mul6(mul6(money, annualRate), periodCount) / 12`
///   rounded to 2 decimals `HALF_UP`.
/// - Yearly (`periodUnit == 2`): `mul6(mul6(money, annualRate), periodCount)`
///   keeping 6 decimals (rounded to 2 decimals `HALF_UP` at display/settlement).
DecimalValue calculateExpectedIncome({
  required Money principal,
  required DecimalValue annualRate,
  required int periodUnit,
  required int periodCount,
}) {
  final moneyDec = DecimalValue(principal.units, principal.scale);
  final countDec = DecimalValue(BigInt.from(periodCount), 0);
  final total = mul6(mul6(moneyDec, annualRate), countDec);
  if (periodUnit == DepositPeriodUnit.month) {
    // total has scale 6; dividing by 12 to scale 2 divides coefficient by 12 * 10^4.
    final minor = divideRounded(
      total.coefficient,
      BigInt.from(12) * powerOfTen(4),
      RoundingMode.halfUp,
    );
    return DecimalValue(minor, Money.ledgerScale);
  }
  return total;
}

/// Rounds [expectedIncome] (2 or 6 decimals) to 2-decimal minor units `HALF_UP`.
BigInt expectedIncomeToMinor(DecimalValue expectedIncome) =>
    expectedIncome.unitsAt(Money.ledgerScale, rounding: RoundingMode.halfUp);

/// Convenience wrapper returning 2-decimal minor units directly.
BigInt calculateExpectedIncomeMinor({
  required Money principal,
  required DecimalValue annualRate,
  required int periodUnit,
  required int periodCount,
}) => expectedIncomeToMinor(
  calculateExpectedIncome(
    principal: principal,
    annualRate: annualRate,
    periodUnit: periodUnit,
    periodCount: periodCount,
  ),
);

/// Standard maturity bill remark (R4 / ASYM-FD-03):
/// `'定期存款收益'` when blank, `'定期存款收益：$trimmed'` when non-blank.
String depositIncomeRemark(String remark) {
  final trimmed = remark.trim();
  return trimmed.isEmpty ? '定期存款收益' : '定期存款收益：$trimmed';
}

/// Standard Mode B1 balance-adjustment bill remark (ASYM-FD-08).
String depositAdjustRemark(String remark) {
  final trimmed = remark.trim();
  return trimmed.isEmpty ? '定期存款本金入账' : '定期存款本金入账：$trimmed';
}

/// Checks whether [rates] has valid strictly-positive rates to convert [from] -> [to].
bool hasValidRate(RateTable rates, String? from, String? to) {
  final src = normalizeCurrency(from) ?? rates.base;
  final dst = normalizeCurrency(to) ?? rates.base;
  if (src == dst) return true;
  final missing = <String>{};
  final probe = rates.convert(powerOfTen(18), src, dst, missing: missing);
  return missing.isEmpty && probe > BigInt.zero;
}

/// Converts [minor] from [from] to [to] `HALF_UP`, throwing validation [Failure]
/// when `from != to` and a rate is missing or non-positive.
BigInt strictConvertMinor(
  BigInt minor,
  String? from,
  String? to,
  RateTable rates,
) {
  final src = normalizeCurrency(from) ?? rates.base;
  final dst = normalizeCurrency(to) ?? rates.base;
  if (src == dst) return minor;
  if (!hasValidRate(rates, src, dst)) {
    throw Failure(FailureCode.validation, '缺少 $src/$dst 有效汇率，请先维护币种汇率');
  }
  return rates.convert(minor, src, dst);
}

/// Converts [minor] from [from] to [to] `HALF_UP`, returning `null` if a
/// required foreign rate is missing or non-positive (used by lazy settlement).
BigInt? tryConvertMinor(
  BigInt minor,
  String? from,
  String? to,
  RateTable rates,
) {
  final src = normalizeCurrency(from) ?? rates.base;
  final dst = normalizeCurrency(to) ?? rates.base;
  if (src == dst) return minor;
  if (!hasValidRate(rates, src, dst)) return null;
  return rates.convert(minor, src, dst);
}

/// Converts [minor] from [from] to [rates.base] for header display, falling back
/// `1:1` if the live rate is missing or non-positive (matching 02zz §5.1 / 708#0).
BigInt headerConvertMinorToBase(BigInt minor, String? from, RateTable rates) {
  final src = normalizeCurrency(from) ?? rates.base;
  if (src == rates.base || minor == BigInt.zero) return minor;
  if (!hasValidRate(rates, src, rates.base)) return minor;
  return rates.convert(minor, src, rates.base);
}

/// Computed Mode A transfer record amounts & currency snapshot (`FD-F02`).
final class ModeATransferPlan {
  const ModeATransferPlan({
    required this.depositCurrency,
    required this.sourceCurrency,
    required this.sourceMoneyMinor,
    required this.targetCurrency,
    required this.targetMoneyMinor,
    required this.baseCurrencyCode,
    required this.baseMoneyMinor,
    required this.snapshot,
  });

  final String depositCurrency;
  final String sourceCurrency;
  final BigInt sourceMoneyMinor;
  final String targetCurrency;
  final BigInt targetMoneyMinor;
  final String baseCurrencyCode;
  final BigInt baseMoneyMinor;
  final CurrencySnapshot? snapshot;
}

/// Builds the Mode A transfer amounts and `BillCurrencyExtra` (`FD-F02`):
/// - Empty `depositCurrency` falls back to `targetAssetCurrency` (NOT `fromAssetCurrency`).
/// - `record.money` is in `sourceCurrency` (`fromAssetCurrency`).
/// - `curr` records `sc/sm` (source), `ac/am` (target), `bc/bm` (base).
ModeATransferPlan buildModeATransferPlan({
  required BigInt principalMinor,
  String? depositCurrency,
  String? fromAssetCurrency,
  String? targetAssetCurrency,
  required RateTable rates,
}) {
  final base = rates.base;
  final targetCurr = normalizeCurrency(targetAssetCurrency) ?? base;
  final fromCurr = normalizeCurrency(fromAssetCurrency) ?? base;
  final depCurr = normalizeCurrency(depositCurrency) ?? targetCurr;

  final sourceMinor = strictConvertMinor(
    principalMinor,
    depCurr,
    fromCurr,
    rates,
  );
  final targetMinor = strictConvertMinor(
    principalMinor,
    depCurr,
    targetCurr,
    rates,
  );
  final baseMinor = strictConvertMinor(principalMinor, depCurr, base, rates);

  final allBase =
      fromCurr == base &&
      targetCurr == base &&
      depCurr == base &&
      sourceMinor == targetMinor;
  final snapshot = allBase
      ? null
      : CurrencySnapshot(
          sourceCode: fromCurr,
          sourceGross: sourceMinor,
          assetCode: targetCurr,
          assetNet: targetMinor,
          baseCode: base,
          baseAmount: baseMinor,
        );

  return ModeATransferPlan(
    depositCurrency: depCurr,
    sourceCurrency: fromCurr,
    sourceMoneyMinor: sourceMinor,
    targetCurrency: targetCurr,
    targetMoneyMinor: targetMinor,
    baseCurrencyCode: base,
    baseMoneyMinor: baseMinor,
    snapshot: snapshot,
  );
}

/// One element of `asset.fixed_deposit_info` JSON array (`docs/modules/fixed-deposit.md` §2).
final class FixedDepositItem {
  FixedDepositItem({
    required this.moneyMinor,
    this.fromAssetId = noRef,
    this.updateAssetBalance = false,
    required this.annualRate,
    this.periodUnit = DepositPeriodUnit.year,
    this.periodCount = 1,
    required this.depositDate,
    required this.dueDate,
    required this.expectedIncomeMinor,
    this.currency = '',
    this.assetCurrency = '',
    BigInt? assetMoneyMinor,
    this.baseCurrency = '',
    BigInt? baseMoneyMinor,
    this.remark = '',
    this.transferRecordId,
    this.incomeRecordId,
    this.status = FixedDepositStatus.running,
    this.adjustRecordId,
  }) : assetMoneyMinor = assetMoneyMinor ?? BigInt.zero,
       baseMoneyMinor = baseMoneyMinor ?? BigInt.zero;

  final BigInt moneyMinor;
  final int fromAssetId;
  final bool updateAssetBalance;
  final DecimalValue annualRate;
  final int periodUnit;
  final int periodCount;
  final int depositDate;
  final int dueDate;
  final BigInt expectedIncomeMinor;
  final String currency;
  final String assetCurrency;
  final BigInt assetMoneyMinor;
  final String baseCurrency;
  final BigInt baseMoneyMinor;
  final String remark;
  final String? transferRecordId;
  final String? incomeRecordId;
  final int status;

  /// Optional Mode B1 `RecordType.balanceAdjust` ID (`ASYM-FD-08`).
  /// Omitted from JSON when null so standard entries emit exact 18 keys.
  final String? adjustRecordId;

  bool get isRunning => status == FixedDepositStatus.running;
  bool get isSettled => status == FixedDepositStatus.settled;

  /// `am > 0 ? am : money` (`02zz` §2.2 `resolvedAssetMoney()`).
  BigInt get resolvedAssetMoneyMinor =>
      assetMoneyMinor > BigInt.zero ? assetMoneyMinor : moneyMinor;

  /// Maturity settlement gate (R4):
  /// `status == 0 && incomeRecordId == null/blank && dueDate <= nowMs`.
  bool shouldSettle(int nowMs) =>
      status == FixedDepositStatus.running &&
      (incomeRecordId == null || incomeRecordId!.trim().isEmpty) &&
      dueDate <= nowMs;

  FixedDepositItem copyWith({
    BigInt? moneyMinor,
    int? fromAssetId,
    bool? updateAssetBalance,
    DecimalValue? annualRate,
    int? periodUnit,
    int? periodCount,
    int? depositDate,
    int? dueDate,
    BigInt? expectedIncomeMinor,
    String? currency,
    String? assetCurrency,
    BigInt? assetMoneyMinor,
    String? baseCurrency,
    BigInt? baseMoneyMinor,
    String? remark,
    Object? transferRecordId = _unset,
    Object? incomeRecordId = _unset,
    int? status,
    Object? adjustRecordId = _unset,
  }) => FixedDepositItem(
    moneyMinor: moneyMinor ?? this.moneyMinor,
    fromAssetId: fromAssetId ?? this.fromAssetId,
    updateAssetBalance: updateAssetBalance ?? this.updateAssetBalance,
    annualRate: annualRate ?? this.annualRate,
    periodUnit: periodUnit ?? this.periodUnit,
    periodCount: periodCount ?? this.periodCount,
    depositDate: depositDate ?? this.depositDate,
    dueDate: dueDate ?? this.dueDate,
    expectedIncomeMinor: expectedIncomeMinor ?? this.expectedIncomeMinor,
    currency: currency ?? this.currency,
    assetCurrency: assetCurrency ?? this.assetCurrency,
    assetMoneyMinor: assetMoneyMinor ?? this.assetMoneyMinor,
    baseCurrency: baseCurrency ?? this.baseCurrency,
    baseMoneyMinor: baseMoneyMinor ?? this.baseMoneyMinor,
    remark: remark ?? this.remark,
    transferRecordId: identical(transferRecordId, _unset)
        ? this.transferRecordId
        : transferRecordId as String?,
    incomeRecordId: identical(incomeRecordId, _unset)
        ? this.incomeRecordId
        : incomeRecordId as String?,
    status: status ?? this.status,
    adjustRecordId: identical(adjustRecordId, _unset)
        ? this.adjustRecordId
        : adjustRecordId as String?,
  );

  Map<String, Object?> toJson() => {
    'money_minor': moneyMinor.toString(),
    'from_asset_id': fromAssetId,
    'update_asset_balance': updateAssetBalance,
    'annual_rate': formatDecimalValue(annualRate, trimTrailingZeros: true),
    'period_unit': periodUnit,
    'period_count': periodCount,
    'deposit_date': depositDate,
    'due_date': dueDate,
    'expected_income_minor': expectedIncomeMinor.toString(),
    'c': currency,
    'ac': assetCurrency,
    'am_minor': assetMoneyMinor.toString(),
    'bc': baseCurrency,
    'bm_minor': baseMoneyMinor.toString(),
    'remark': remark,
    'transfer_record_id': transferRecordId,
    'income_record_id': incomeRecordId,
    'status': status,
    if (adjustRecordId != null) 'adjust_record_id': adjustRecordId,
  };

  static FixedDepositItem fromJson(Object? json) {
    if (json is! Map) throw _corruptDeposit;
    return FixedDepositItem(
      moneyMinor: _parseMinorField(json, 'money_minor', 'money'),
      fromAssetId: _parseIntField(json['from_asset_id'], fallback: noRef),
      updateAssetBalance: _parseBoolField(
        json['update_asset_balance'],
        fallback: false,
      ),
      annualRate: json['annual_rate'] == null
          ? DecimalValue(BigInt.zero, 0)
          : parseFlexibleDecimal(json['annual_rate']),
      periodUnit: _parseIntField(
        json['period_unit'],
        fallback: DepositPeriodUnit.year,
      ),
      periodCount: _parseIntField(json['period_count'], fallback: 1),
      depositDate: _parseIntField(json['deposit_date'], fallback: 0),
      dueDate: _parseIntField(json['due_date'], fallback: 0),
      expectedIncomeMinor: _parseMinorField(
        json,
        'expected_income_minor',
        'expected_income',
      ),
      currency: _parseStringField(json['c']),
      assetCurrency: _parseStringField(json['ac']),
      assetMoneyMinor: _parseMinorField(json, 'am_minor', 'am'),
      baseCurrency: _parseStringField(json['bc']),
      baseMoneyMinor: _parseMinorField(json, 'bm_minor', 'bm'),
      remark: _parseStringField(json['remark']),
      transferRecordId: _parseNullableId(json['transfer_record_id']),
      incomeRecordId: _parseNullableId(json['income_record_id']),
      status: _parseIntField(
        json['status'],
        fallback: FixedDepositStatus.running,
      ),
      adjustRecordId: _parseNullableId(json['adjust_record_id']),
    );
  }
}

const _unset = Object();

BigInt _parseMinorField(
  Map<dynamic, dynamic> json,
  String minorKey,
  String legacyMajorKey,
) {
  final rawMinor = json[minorKey];
  if (rawMinor != null) {
    if (rawMinor is int) return BigInt.from(rawMinor);
    if (rawMinor is BigInt) return rawMinor;
    if (rawMinor is String) {
      final trimmed = rawMinor.trim();
      if (trimmed.isEmpty) return BigInt.zero;
      final exact = BigInt.tryParse(trimmed);
      if (exact != null) return exact;
      return parseFlexibleDecimal(
        trimmed,
      ).unitsAt(0, rounding: RoundingMode.halfUp);
    }
    if (rawMinor is num) {
      return parseFlexibleDecimal(
        rawMinor,
      ).unitsAt(0, rounding: RoundingMode.halfUp);
    }
    throw _corruptDeposit;
  }
  final rawMajor = json[legacyMajorKey];
  if (rawMajor != null) {
    return parseFlexibleDecimal(
      rawMajor,
    ).unitsAt(Money.ledgerScale, rounding: RoundingMode.halfUp);
  }
  return BigInt.zero;
}

int _parseIntField(Object? raw, {required int fallback}) {
  if (raw == null) return fallback;
  if (raw is int) return raw;
  if (raw is String) return int.tryParse(raw.trim()) ?? (throw _corruptDeposit);
  if (raw is num) {
    return int.tryParse(raw.toString()) ?? (throw _corruptDeposit);
  }
  throw _corruptDeposit;
}

bool _parseBoolField(Object? raw, {required bool fallback}) {
  if (raw == null) return fallback;
  if (raw is bool) return raw;
  if (raw is int) return raw != 0;
  if (raw is String) {
    final lower = raw.trim().toLowerCase();
    if (lower == 'true' || lower == '1') return true;
    if (lower == 'false' || lower == '0') return false;
  }
  throw _corruptDeposit;
}

String _parseStringField(Object? raw) => raw == null ? '' : raw.toString();

String? _parseNullableId(Object? raw) {
  if (raw == null) return null;
  final s = raw.toString().trim();
  return s.isEmpty ? null : s;
}

/// Encodes `List<FixedDepositItem>` for `asset.fixed_deposit_info` (`null` when empty).
String? encodeFixedDepositList(List<FixedDepositItem> items) =>
    items.isEmpty ? null : jsonEncode([for (final e in items) e.toJson()]);

/// Decodes `asset.fixed_deposit_info` JSON string into `List<FixedDepositItem>`.
List<FixedDepositItem> decodeFixedDepositList(String? jsonText) {
  if (jsonText == null || jsonText.trim().isEmpty) return const [];
  final Object? decoded;
  try {
    decoded = jsonDecode(jsonText);
  } on FormatException {
    throw _corruptDeposit;
  }
  if (decoded is! List) throw _corruptDeposit;
  return [for (final item in decoded) FixedDepositItem.fromJson(item)];
}

/// Sorts items by `(status ASC, dueDate ASC)` (`docs/modules/fixed-deposit.md` R5).
List<T> sortFixedDeposits<T>(
  Iterable<T> entries, {
  required FixedDepositItem Function(T entry) itemOf,
  int Function(T a, T b)? tieBreaker,
}) {
  final list = entries.toList();
  list.sort((a, b) {
    final ia = itemOf(a);
    final ib = itemOf(b);
    final byStatus = ia.status.compareTo(ib.status);
    if (byStatus != 0) return byStatus;
    final byDue = ia.dueDate.compareTo(ib.dueDate);
    if (byDue != 0) return byDue;
    return tieBreaker == null ? 0 : tieBreaker(a, b);
  });
  return list;
}

/// Top summary card values in `baseCurrency` minor units (R5).
final class FixedDepositHeaderSummary {
  const FixedDepositHeaderSummary({
    required this.totalPrincipalMinor,
    required this.pendingIncomeMinor,
    required this.settledIncomeMinor,
    this.baseCurrencyCode = baseCurrency,
  });

  final BigInt totalPrincipalMinor;
  final BigInt pendingIncomeMinor;
  final BigInt settledIncomeMinor;
  final String baseCurrencyCode;
}

/// Computes the 3 header metrics with per-item 2-decimal `HALF_UP` rounding (`FD-F04`)
/// and `ASYM-FD-05` priority on actual settled `Record` base amounts.
///
/// - [items]: deposits belonging to eligible active accounts (`status == 0`).
/// - [settledRecordBaseMinors]: optional map `incomeRecordId -> actual settled base minor`
///   from live `record` rows (`ASYM-FD-05`). When absent for an entry, falls back to
///   historical `bm/money` ratio or live [rates].
FixedDepositHeaderSummary computeDepositHeaderSummary(
  Iterable<FixedDepositItem> items,
  RateTable rates, {
  Map<String, BigInt> settledRecordBaseMinors = const {},
}) {
  var totalPrincipal = BigInt.zero;
  var pendingIncome = BigInt.zero;
  var settledIncome = BigInt.zero;
  final base = rates.base;

  BigInt principalInBase(FixedDepositItem item) {
    final depCurr =
        normalizeCurrency(item.currency) ??
        normalizeCurrency(item.assetCurrency) ??
        base;
    if (depCurr == base) return item.moneyMinor;
    if (normalizeCurrency(item.baseCurrency) == base &&
        item.baseMoneyMinor > BigInt.zero) {
      return item.baseMoneyMinor;
    }
    return headerConvertMinorToBase(item.moneyMinor, depCurr, rates);
  }

  BigInt expectedIncomeInBase(FixedDepositItem item) {
    final depCurr =
        normalizeCurrency(item.currency) ??
        normalizeCurrency(item.assetCurrency) ??
        base;
    if (depCurr == base) return item.expectedIncomeMinor;
    if (normalizeCurrency(item.baseCurrency) == base &&
        item.baseMoneyMinor > BigInt.zero &&
        item.moneyMinor > BigInt.zero) {
      // Original 12-decimal historical ratio: round2(expectedIncome * round12(bm / money))
      final ratio12 = divideRounded(
        item.baseMoneyMinor * powerOfTen(12),
        item.moneyMinor,
        RoundingMode.halfUp,
      );
      return divideRounded(
        item.expectedIncomeMinor * ratio12,
        powerOfTen(12),
        RoundingMode.halfUp,
      );
    }
    return headerConvertMinorToBase(item.expectedIncomeMinor, depCurr, rates);
  }

  for (final item in items) {
    if (item.status == FixedDepositStatus.running) {
      totalPrincipal += principalInBase(item);
      pendingIncome += expectedIncomeInBase(item);
    } else if (item.status == FixedDepositStatus.settled) {
      final recId = item.incomeRecordId;
      if (recId != null && settledRecordBaseMinors.containsKey(recId)) {
        settledIncome += settledRecordBaseMinors[recId]!;
      } else {
        settledIncome += expectedIncomeInBase(item);
      }
    }
  }

  return FixedDepositHeaderSummary(
    totalPrincipalMinor: totalPrincipal,
    pendingIncomeMinor: pendingIncome,
    settledIncomeMinor: settledIncome,
    baseCurrencyCode: base,
  );
}
