import 'dart:convert';

import '../../core/failure.dart';
import '../../core/money.dart';
import '../ledger/record_extra.dart';
import '../model/codes.dart';
import 'asset_overview.dart';
import 'currency_rates.dart';

/// Principal records `{5, 6, 7, 8}` are stamped at `operateDate + 1ms` (R2).
const int debtPrincipalOffsetMs = 1;

/// Interest records `type = 10` are stamped at `operateDate + 2ms` so they sort
/// strictly above the paired principal record in `record_time DESC` lists (R2).
const int debtInterestOffsetMs = 2;

const _corruptLoanInfo = Failure(FailureCode.corruptData, '借贷附加信息格式损坏');

/// Encodes domain `countedInNetWorth` to `asset.is_effective_asset` for
/// `asset.type == 4` (CE-DM-01: `0` = counted in net worth, `1` = excluded,
/// matching `OverviewAccount.counted` in `asset_overview.dart:72`).
int debtEffectiveAssetFlag({required bool countedInNetWorth}) =>
    countedInNetWorth ? 0 : 1;

/// Decodes `asset.is_effective_asset` of a `type == 4` debt into positive
/// domain boolean `countedInNetWorth` (`0` -> `true`, non-zero -> `false`).
bool isDebtCountedInNetWorth(int isEffectiveAsset) => isEffectiveAsset == 0;

/// Book-isolation visibility predicate for debts (CE-DM-06):
/// - [queryBookId] == null (all-books view): all debts are visible.
/// - Bound debts (`boundBookIds.isNotEmpty`): visible iff bound to [queryBookId].
/// - Unbound legacy debts (`boundBookIds.isEmpty`): visible ONLY in
///   [defaultBookId], never leaked into other single books.
bool isDebtVisibleInBook({
  required Set<int> boundBookIds,
  int? queryBookId,
  int defaultBookId = 1,
}) {
  if (queryBookId == null) return true;
  if (boundBookIds.isEmpty) return queryBookId == defaultBookId;
  return boundBookIds.contains(queryBookId);
}

int principalRecordTimestamp(int operateDateMs) =>
    operateDateMs + debtPrincipalOffsetMs;

int interestRecordTimestamp(int operateDateMs) =>
    operateDateMs + debtInterestOffsetMs;

BigInt? _parseMinorField(Object? value) {
  if (value == null) return null;
  if (value is String) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    final direct = BigInt.tryParse(trimmed);
    if (direct != null) return direct;
    return DecimalValue.parse(
      trimmed,
    ).unitsAt(Money.ledgerScale, rounding: RoundingMode.halfUp);
  }
  if (value is int) return BigInt.from(value);
  throw _corruptLoanInfo;
}

int? _parseIntField(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is String) return int.tryParse(value) ?? (throw _corruptLoanInfo);
  throw _corruptLoanInfo;
}

bool? _parseBoolField(Object? value) {
  if (value == null) return null;
  if (value is bool) return value;
  throw _corruptLoanInfo;
}

/// Per-currency principal position stored in `loan_info.cp` (DR-DM-01).
final class LoanCurrencyPosition {
  const LoanCurrencyPosition({
    required this.currencyCode,
    required this.principalBalanceMinor,
    required this.totalPrincipalMinor,
  });

  /// Normalized currency code (`cc`).
  final String currencyCode;

  /// Remaining principal in original currency minor units (`pb`).
  final BigInt principalBalanceMinor;

  /// Cumulative borrowed/lent principal in original currency minor units (`tp`).
  final BigInt totalPrincipalMinor;

  Map<String, Object> toJson() => {
    'cc': currencyCode,
    'pb': principalBalanceMinor.toString(),
    'tp': totalPrincipalMinor.toString(),
  };

  static LoanCurrencyPosition fromJson(Object? json) {
    if (json is! Map) throw _corruptLoanInfo;
    final rawCode = json['cc'];
    if (rawCode is! String || rawCode.trim().isEmpty) throw _corruptLoanInfo;
    return LoanCurrencyPosition(
      currencyCode: normalizeCurrency(rawCode) ?? baseCurrency,
      principalBalanceMinor: _parseMinorField(json['pb']) ?? BigInt.zero,
      totalPrincipalMinor: _parseMinorField(json['tp']) ?? BigInt.zero,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LoanCurrencyPosition &&
      other.currencyCode == currencyCode &&
      other.principalBalanceMinor == principalBalanceMinor &&
      other.totalPrincipalMinor == totalPrincipalMinor;

  @override
  int get hashCode =>
      Object.hash(currencyCode, principalBalanceMinor, totalPrincipalMinor);
}

/// Typed representation of `asset.loan_info` JSON (docs/modules/debt.md §2).
///
/// Amounts are serialized as minor-unit strings (ADR-011). Unknown JSON keys
/// are preserved on rewrite.
final class LoanInfo {
  LoanInfo({
    this.schemaVersion = 2,
    this.startDate = 0,
    this.endDate = noRef,
    BigInt? totalDebtMoneyMinor,
    this.manualSettled = false,
    this.settledSnapshotMinor,
    this.settledCurrencyCode,
    this.settledAtMs,
    this.positionsUpdatedAtMs,
    this.currencyPositions = const [],
    Map<String, Object?>? preservedRaw,
  }) : totalDebtMoneyMinor = totalDebtMoneyMinor ?? BigInt.zero,
       _preservedRaw = {...?preservedRaw};

  final int schemaVersion; // sv
  final int startDate; // startDate (epoch ms)
  final int endDate; // endDate (epoch ms, -1 = unset)
  final BigInt totalDebtMoneyMinor; // totalDebtMoney (minor string)
  final bool manualSettled; // s
  final BigInt? settledSnapshotMinor; // sb (minor string)
  final String? settledCurrencyCode; // scc
  final int? settledAtMs; // sa
  final int? positionsUpdatedAtMs; // pua
  final List<LoanCurrencyPosition> currencyPositions; // cp
  final Map<String, Object?> _preservedRaw;

  static LoanInfo parse(String? text) {
    if (text == null || text.trim().isEmpty) {
      return LoanInfo(schemaVersion: 1);
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw _corruptLoanInfo;
    }
    if (decoded is! Map<String, Object?>) throw _corruptLoanInfo;
    final rawCp = decoded['cp'];
    final List<LoanCurrencyPosition> positions;
    if (rawCp == null) {
      positions = const <LoanCurrencyPosition>[];
    } else if (rawCp is List) {
      positions = [
        for (final item in rawCp) LoanCurrencyPosition.fromJson(item),
      ];
    } else {
      throw _corruptLoanInfo;
    }
    final rawScc = decoded['scc'];
    final String? sccText;
    if (rawScc == null) {
      sccText = null;
    } else if (rawScc is String) {
      sccText = rawScc;
    } else {
      throw _corruptLoanInfo;
    }

    return LoanInfo(
      schemaVersion: _parseIntField(decoded['sv']) ?? 1,
      startDate: _parseIntField(decoded['startDate']) ?? 0,
      endDate: _parseIntField(decoded['endDate']) ?? noRef,
      totalDebtMoneyMinor:
          _parseMinorField(decoded['totalDebtMoney']) ?? BigInt.zero,
      manualSettled: _parseBoolField(decoded['s']) ?? false,
      settledSnapshotMinor: _parseMinorField(decoded['sb']),
      settledCurrencyCode: normalizeCurrency(sccText),
      settledAtMs: _parseIntField(decoded['sa']),
      positionsUpdatedAtMs: _parseIntField(decoded['pua']),
      currencyPositions: positions,
      preservedRaw: decoded,
    );
  }

  LoanInfo copyWith({
    int? schemaVersion,
    int? startDate,
    int? endDate,
    BigInt? totalDebtMoneyMinor,
    bool? manualSettled,
    BigInt? settledSnapshotMinor,
    bool clearSettledSnapshot = false,
    String? settledCurrencyCode,
    int? settledAtMs,
    int? positionsUpdatedAtMs,
    List<LoanCurrencyPosition>? currencyPositions,
  }) => LoanInfo(
    schemaVersion: schemaVersion ?? this.schemaVersion,
    startDate: startDate ?? this.startDate,
    endDate: endDate ?? this.endDate,
    totalDebtMoneyMinor: totalDebtMoneyMinor ?? this.totalDebtMoneyMinor,
    manualSettled: manualSettled ?? this.manualSettled,
    settledSnapshotMinor: clearSettledSnapshot
        ? null
        : (settledSnapshotMinor ?? this.settledSnapshotMinor),
    settledCurrencyCode: clearSettledSnapshot
        ? null
        : (settledCurrencyCode ?? this.settledCurrencyCode),
    settledAtMs: clearSettledSnapshot
        ? null
        : (settledAtMs ?? this.settledAtMs),
    positionsUpdatedAtMs: positionsUpdatedAtMs ?? this.positionsUpdatedAtMs,
    currencyPositions: currencyPositions ?? this.currencyPositions,
    preservedRaw: _preservedRaw,
  );

  Map<String, Object?> toJson() {
    final out = <String, Object?>{..._preservedRaw};
    out['sv'] = schemaVersion;
    out['startDate'] = startDate;
    out['endDate'] = endDate;
    out['totalDebtMoney'] = totalDebtMoneyMinor.toString();
    out['s'] = manualSettled;
    out['cp'] = [for (final p in currencyPositions) p.toJson()];
    if (settledSnapshotMinor != null) {
      out['sb'] = settledSnapshotMinor!.toString();
    } else {
      out.remove('sb');
    }
    if (settledCurrencyCode != null) {
      out['scc'] = settledCurrencyCode;
    } else {
      out.remove('scc');
    }
    if (settledAtMs != null) {
      out['sa'] = settledAtMs;
    } else {
      out.remove('sa');
    }
    if (positionsUpdatedAtMs != null) {
      out['pua'] = positionsUpdatedAtMs;
    } else {
      out.remove('pua');
    }
    return out;
  }

  String encode() => jsonEncode(toJson());
}

/// Direction and column routing for debt principal records `{5, 6, 7, 8}` (R2):
/// - `type=5` 借入 (`fromAssetId = debtId`, `toAssetId = fundingAssetId`)
/// - `type=6` 借出 (`fromAssetId = fundingAssetId`, `toAssetId = debtId`)
/// - `type=7` 还款 (`fromAssetId = fundingAssetId`, `toAssetId = debtId`)
/// - `type=8` 收款 (`fromAssetId = debtId`, `toAssetId = fundingAssetId`)
({int type, int subType, int fromAssetId, int toAssetId})
buildPrincipalRecordSpec({
  required int debtSubType,
  required int debtId,
  int fundingAssetId = noRef,
  required bool isRepayment,
}) {
  switch (debtSubType) {
    case AssetType.debtBorrow:
      return isRepayment
          ? (
              type: RecordType.repay,
              subType: RecordDirection.none,
              fromAssetId: fundingAssetId,
              toAssetId: debtId,
            )
          : (
              type: RecordType.borrowIn,
              subType: RecordDirection.none,
              fromAssetId: debtId,
              toAssetId: fundingAssetId,
            );
    case AssetType.debtLend:
      return isRepayment
          ? (
              type: RecordType.collect,
              subType: RecordDirection.none,
              fromAssetId: debtId,
              toAssetId: fundingAssetId,
            )
          : (
              type: RecordType.lendOut,
              subType: RecordDirection.none,
              fromAssetId: fundingAssetId,
              toAssetId: debtId,
            );
    default:
      throw const Failure(FailureCode.validation, '借贷类型无效');
  }
}

/// Direction and column routing for debt interest records `type=10` (R2,
/// aligned with `effects.dart` lines 91-96):
/// - `debtBorrow` (`subType=100`): `subType=0` 利息支出, `fromAssetId = funding`,
///   `toAssetId = debtId`, `excludeBudget = interestExcludeBudget`.
/// - `debtLend` (`subType=99`): `subType=1` 利息收入, `fromAssetId = debtId`,
///   `toAssetId = funding`, `excludeBudget = false`.
({int type, int subType, int fromAssetId, int toAssetId, bool excludeBudget})
buildInterestRecordSpec({
  required int debtSubType,
  required int debtId,
  int fundingAssetId = noRef,
  bool interestExcludeBudget = false,
}) {
  switch (debtSubType) {
    case AssetType.debtBorrow:
      return (
        type: RecordType.debtInterest,
        subType: RecordDirection.expense,
        fromAssetId: fundingAssetId,
        toAssetId: debtId,
        excludeBudget: interestExcludeBudget,
      );
    case AssetType.debtLend:
      return (
        type: RecordType.debtInterest,
        subType: RecordDirection.income,
        fromAssetId: debtId,
        toAssetId: fundingAssetId,
        excludeBudget: false,
      );
    default:
      throw const Failure(FailureCode.validation, '借贷类型无效');
  }
}

/// Minimal record projection used by pure debt rules.
final class DebtRecordEntry {
  const DebtRecordEntry({
    required this.recordId,
    required this.type,
    this.subType = RecordDirection.none,
    required this.moneyMinor,
    required this.recordTime,
    this.currency,
  });

  final String recordId;
  final int type;
  final int subType;
  final BigInt moneyMinor;
  final int recordTime;
  final CurrencySnapshot? currency;
}

/// Result of recomputing a debt account from its live `{5, 6, 7, 8}` records.
final class DebtRecomputeResult {
  const DebtRecomputeResult({
    required this.totalPrincipalMinor,
    required this.totalRepaidMinor,
    required this.remainingPrincipalMinor,
    required this.balanceMinor,
    required this.status,
    required this.loanInfo,
  });

  final BigInt totalPrincipalMinor;
  final BigInt totalRepaidMinor;

  /// Recomputed unpaid/uncollected principal before manual-settle zeroing.
  final BigInt remainingPrincipalMinor;

  /// Stored `asset.balance_minor` (`0` when settled, else [remainingPrincipalMinor]).
  final BigInt balanceMinor;

  /// Stored `asset.status` (`0` active, `2` settled).
  final int status;

  /// Updated `asset.loan_info` payload (`sv: 2`).
  final LoanInfo loanInfo;
}

BigInt _entryAmountInCurrency(
  DebtRecordEntry entry,
  String targetCurrency, {
  RateTable? rates,
}) {
  final target = normalizeCurrency(targetCurrency) ?? baseCurrency;
  final curr = entry.currency;
  if (curr == null || !curr.isValid) return entry.moneyMinor;
  final sc = normalizeCurrency(curr.sourceCode);
  if (sc == target) return curr.sourceGross;
  final ac = normalizeCurrency(curr.assetCode);
  if (ac == target && curr.assetNet != null) return curr.assetNet!;
  final bc = normalizeCurrency(curr.baseCode);
  if (bc == target && curr.baseAmount != null) return curr.baseAmount!;
  if (rates != null && sc != null) {
    return rates.convert(curr.sourceGross, sc, target);
  }
  return entry.moneyMinor;
}

/// Recomputes debt principal, currency positions, and settlement state from
/// live `{5, 6, 7, 8}` records (R3 / ASYM-DM-01 / CE-DM-02).
///
/// Pure interest records (`type == 10`) are ignored.
/// If the debt was manually settled (`currentStatus == AssetStatus.settled` and
/// `currentLoanInfo.manualSettled == true`, or legacy `sv < 2`), [status] stays
/// `AssetStatus.settled` (`2`) and [balanceMinor] stays `0` unless
/// [allowReopen] is explicitly `true`.
DebtRecomputeResult recomputeDebtPrincipal({
  required int debtSubType,
  required int currentStatus,
  required LoanInfo currentLoanInfo,
  required Iterable<DebtRecordEntry> records,
  String? debtCurrency,
  RateTable? rates,
  bool allowReopen = false,
  int? nowMs,
}) {
  if (debtSubType != AssetType.debtBorrow &&
      debtSubType != AssetType.debtLend) {
    throw const Failure(FailureCode.validation, '借贷类型无效');
  }

  final targetCurrency = normalizeCurrency(debtCurrency) ?? baseCurrency;
  final increaseType = debtSubType == AssetType.debtBorrow
      ? RecordType.borrowIn
      : RecordType.lendOut;
  final decreaseType = debtSubType == AssetType.debtBorrow
      ? RecordType.repay
      : RecordType.collect;

  var totalPrincipal = BigInt.zero;
  var totalRepaid = BigInt.zero;

  final tpByCode = <String, BigInt>{};
  final pbByCode = <String, BigInt>{};
  final histCostByCode = <String, BigInt>{};
  final codeOrder = <String>[];

  void trackCode(String code) {
    if (!tpByCode.containsKey(code)) {
      codeOrder.add(code);
      tpByCode[code] = BigInt.zero;
      pbByCode[code] = BigInt.zero;
      histCostByCode[code] = BigInt.zero;
    }
  }

  for (final r in records) {
    if (r.type != increaseType && r.type != decreaseType) continue;

    final curr = r.currency;
    final srcCode = (curr != null && curr.isValid)
        ? (normalizeCurrency(curr.sourceCode) ?? targetCurrency)
        : targetCurrency;
    final srcAmount = (curr != null && curr.isValid)
        ? curr.sourceGross
        : r.moneyMinor;
    final targetAmount = _entryAmountInCurrency(
      r,
      targetCurrency,
      rates: rates,
    );

    trackCode(srcCode);
    if (r.type == increaseType) {
      totalPrincipal += targetAmount;
      tpByCode[srcCode] = tpByCode[srcCode]! + srcAmount;
      pbByCode[srcCode] = pbByCode[srcCode]! + srcAmount;
      histCostByCode[srcCode] = histCostByCode[srcCode]! + targetAmount;
    } else {
      totalRepaid += targetAmount;
      pbByCode[srcCode] = pbByCode[srcCode]! - srcAmount;
    }
  }

  final positions = <LoanCurrencyPosition>[
    for (final code in codeOrder)
      if (pbByCode[code] != BigInt.zero || tpByCode[code]! > BigInt.zero)
        LoanCurrencyPosition(
          currencyCode: code,
          principalBalanceMinor: pbByCode[code]!,
          totalPrincipalMinor: tpByCode[code]!,
        ),
  ];

  final hasPos = positions.any((p) => p.principalBalanceMinor > BigInt.zero);
  final hasNeg = positions.any((p) => p.principalBalanceMinor < BigInt.zero);
  final netDiff = totalPrincipal - totalRepaid;

  final BigInt rawRemaining;
  if (!hasPos || (hasNeg && netDiff <= BigInt.zero)) {
    rawRemaining = BigInt.zero;
  } else if (netDiff > BigInt.zero) {
    rawRemaining = netDiff;
  } else {
    // CE-DM-02: foreign-currency appreciation caused repaid target value to
    // exceed historical principal cost while original-currency principal > 0.
    var proportional = BigInt.zero;
    for (final p in positions) {
      if (p.principalBalanceMinor > BigInt.zero &&
          p.totalPrincipalMinor > BigInt.zero) {
        final cost = histCostByCode[p.currencyCode] ?? BigInt.zero;
        proportional += divideRounded(
          cost * p.principalBalanceMinor,
          p.totalPrincipalMinor,
          RoundingMode.halfUp,
        );
      }
    }
    rawRemaining = proportional > BigInt.zero ? proportional : BigInt.zero;
  }

  final clampedTotal = totalPrincipal > BigInt.zero
      ? totalPrincipal
      : BigInt.zero;

  final lockedByManualSettle =
      !allowReopen &&
      currentStatus == AssetStatus.settled &&
      (currentLoanInfo.manualSettled || currentLoanInfo.schemaVersion < 2);

  final int nextStatus;
  final BigInt nextBalance;
  final bool nextManualSettled;
  final BigInt? nextSnapshot;
  final String? nextSnapshotCode;
  final int? nextSettledAt;

  if (lockedByManualSettle) {
    nextStatus = AssetStatus.settled;
    nextBalance = BigInt.zero;
    nextManualSettled = true;
    nextSnapshot = currentLoanInfo.settledSnapshotMinor ?? rawRemaining;
    nextSnapshotCode = currentLoanInfo.settledCurrencyCode ?? targetCurrency;
    nextSettledAt = currentLoanInfo.settledAtMs ?? nowMs;
  } else if (rawRemaining <= BigInt.zero) {
    nextStatus = AssetStatus.settled;
    nextBalance = BigInt.zero;
    nextManualSettled = false;
    nextSnapshot = null;
    nextSnapshotCode = null;
    nextSettledAt = null;
  } else {
    nextStatus = AssetStatus.active;
    nextBalance = rawRemaining;
    nextManualSettled = false;
    nextSnapshot = null;
    nextSnapshotCode = null;
    nextSettledAt = null;
  }

  final updatedLoanInfo = LoanInfo(
    schemaVersion: 2,
    startDate: currentLoanInfo.startDate,
    endDate: currentLoanInfo.endDate,
    totalDebtMoneyMinor: clampedTotal,
    manualSettled: nextManualSettled,
    settledSnapshotMinor: nextSnapshot,
    settledCurrencyCode: nextSnapshotCode,
    settledAtMs: nextSettledAt,
    positionsUpdatedAtMs: nowMs ?? currentLoanInfo.positionsUpdatedAtMs,
    currencyPositions: positions,
    preservedRaw: currentLoanInfo.toJson(),
  );

  return DebtRecomputeResult(
    totalPrincipalMinor: clampedTotal,
    totalRepaidMinor: totalRepaid > BigInt.zero ? totalRepaid : BigInt.zero,
    remainingPrincipalMinor: rawRemaining,
    balanceMinor: nextBalance,
    status: nextStatus,
    loanInfo: updatedLoanInfo,
  );
}

/// Computes exact progress in permille (`0..1000`, corresponding to
/// `0.0%..100.0%`) using pure `BigInt` HALF_UP rounding (R4 / CE-DM-07).
int computeDebtProgressPermille({
  required int status,
  required BigInt totalPrincipalMinor,
  required BigInt repaidPrincipalMinor,
}) {
  if (status == AssetStatus.settled) return 1000;
  if (totalPrincipalMinor <= BigInt.zero ||
      repaidPrincipalMinor <= BigInt.zero) {
    return 0;
  }
  final permille = divideRounded(
    repaidPrincipalMinor * BigInt.from(1000),
    totalPrincipalMinor,
    RoundingMode.halfUp,
  );
  if (permille <= BigInt.zero) return 0;
  if (permille >= BigInt.from(1000)) return 1000;
  return permille.toInt();
}

/// Formats debt repayment/collection progress to 1 decimal place (R4 / CE-DM-07):
/// - `status == 2` -> `"100.0%"`
/// - `100 / 300` -> `"33.3%"` (fixing the original `scale=2` `"33.0%"` truncation).
String formatDebtProgress({
  required int status,
  required BigInt totalPrincipalMinor,
  required BigInt repaidPrincipalMinor,
}) {
  final permille = computeDebtProgressPermille(
    status: status,
    totalPrincipalMinor: totalPrincipalMinor,
    repaidPrincipalMinor: repaidPrincipalMinor,
  );
  final whole = permille ~/ 10;
  final tenths = permille % 10;
  return '$whole.$tenths%';
}

/// Sums cumulative interest across all `type == 10` records of a debt (R4),
/// independent of `subType` or `excludeBudget`.
BigInt computeDebtTotalInterest(
  Iterable<DebtRecordEntry> records, {
  String? targetCurrency,
  RateTable? rates,
}) {
  final target = normalizeCurrency(targetCurrency) ?? baseCurrency;
  var sum = BigInt.zero;
  for (final r in records) {
    if (r.type != RecordType.debtInterest) continue;
    sum += _entryAmountInCurrency(r, target, rates: rates).abs();
  }
  return sum;
}

/// Input projection for top-of-page debt overview aggregation.
final class DebtSummaryInput {
  const DebtSummaryInput({
    required this.subType,
    required this.status,
    required this.balanceMinor,
    required this.isEffectiveAsset,
    this.currency,
  });

  final int subType;
  final int status;
  final BigInt balanceMinor;
  final int isEffectiveAsset;
  final String? currency;

  bool get countedInNetWorth => isDebtCountedInNetWorth(isEffectiveAsset);
}

/// Top summary card values for the debt management page (R1 / DM-02).
final class DebtOverviewSummary {
  const DebtOverviewSummary({
    required this.totalReceivableMinor,
    required this.totalPayableMinor,
  });

  /// Sum of active, counted lent debts (`subType == 99`) in base currency.
  final BigInt totalReceivableMinor;

  /// Sum of active, counted borrowed debts (`subType == 100`) in base currency.
  final BigInt totalPayableMinor;

  BigInt get netReceivableMinor => totalReceivableMinor - totalPayableMinor;
}

/// Aggregates active, counted debts into base-currency receivable and payable
/// totals (R1 / CE-DM-01).
DebtOverviewSummary computeDebtOverview(
  Iterable<DebtSummaryInput> debts,
  RateTable rates,
) {
  var receivable = BigInt.zero;
  var payable = BigInt.zero;
  for (final d in debts) {
    if (d.status != AssetStatus.active || !d.countedInNetWorth) continue;
    if (d.balanceMinor <= BigInt.zero) continue;
    final converted = rates.convert(d.balanceMinor, d.currency, rates.base);
    if (converted <= BigInt.zero) continue;
    if (d.subType == AssetType.debtLend) {
      receivable += converted;
    } else if (d.subType == AssetType.debtBorrow) {
      payable += converted;
    }
  }
  return DebtOverviewSummary(
    totalReceivableMinor: receivable,
    totalPayableMinor: payable,
  );
}

/// Complete detail metrics derived for a single debt and its records.
final class DebtDetailMetrics {
  const DebtDetailMetrics({
    required this.loanInfo,
    required this.countedInNetWorth,
    required this.totalPrincipalMinor,
    required this.repaidPrincipalMinor,
    required this.remainingPrincipalMinor,
    required this.totalInterestMinor,
    required this.progressPermille,
    required this.progressLabel,
  });

  final LoanInfo loanInfo;
  final bool countedInNetWorth;
  final BigInt totalPrincipalMinor;
  final BigInt repaidPrincipalMinor;
  final BigInt remainingPrincipalMinor;
  final BigInt totalInterestMinor;
  final int progressPermille;
  final String progressLabel;
}

/// Computes detail-page summary metrics (total, repaid, remaining, progress,
/// cumulative interest) for a debt account.
DebtDetailMetrics computeDebtDetailMetrics({
  required int status,
  required BigInt balanceMinor,
  required int isEffectiveAsset,
  String? loanInfoJson,
  String? currency,
  required Iterable<DebtRecordEntry> records,
  RateTable? rates,
}) {
  final info = LoanInfo.parse(loanInfoJson);
  final remaining = status == AssetStatus.settled || balanceMinor <= BigInt.zero
      ? BigInt.zero
      : balanceMinor;
  final total = info.totalDebtMoneyMinor > BigInt.zero
      ? info.totalDebtMoneyMinor
      : remaining;
  final rawRepaid = total - remaining;
  final repaid = rawRepaid > BigInt.zero ? rawRepaid : BigInt.zero;
  final permille = computeDebtProgressPermille(
    status: status,
    totalPrincipalMinor: total,
    repaidPrincipalMinor: repaid,
  );
  final label = formatDebtProgress(
    status: status,
    totalPrincipalMinor: total,
    repaidPrincipalMinor: repaid,
  );
  final totalInterest = computeDebtTotalInterest(
    records,
    targetCurrency: currency,
    rates: rates,
  );

  return DebtDetailMetrics(
    loanInfo: info,
    countedInNetWorth: isDebtCountedInNetWorth(isEffectiveAsset),
    totalPrincipalMinor: total,
    repaidPrincipalMinor: repaid,
    remainingPrincipalMinor: remaining,
    totalInterestMinor: totalInterest,
    progressPermille: permille,
    progressLabel: label,
  );
}
