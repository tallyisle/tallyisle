import '../../core/money.dart';
import '../ledger/record_extra.dart';
import '../model/codes.dart';
import 'asset_overview.dart';

/// Target account filter scope for asset trend (F-030 / R3, fixing ASYM-AT-02/03).
sealed class AssetTrendFilter {
  const AssetTrendFilter();

  const factory AssetTrendFilter.allEffective() = AssetTrendFilterAllEffective;
  const factory AssetTrendFilter.assetCategory(int categoryCode) =
      AssetTrendFilterCategory;
  const factory AssetTrendFilter.customGroup(String groupName) =
      AssetTrendFilterCustomGroup;
  const factory AssetTrendFilter.singleAsset(int assetId) =
      AssetTrendFilterSingleAsset;

  bool matches(TrendAccount account);
}

final class AssetTrendFilterAllEffective extends AssetTrendFilter {
  const AssetTrendFilterAllEffective();

  @override
  bool matches(TrendAccount account) {
    return account.status == AssetStatus.active && account.counted;
  }

  @override
  bool operator ==(Object other) => other is AssetTrendFilterAllEffective;

  @override
  int get hashCode => runtimeType.hashCode;
}

final class AssetTrendFilterCategory extends AssetTrendFilter {
  const AssetTrendFilterCategory(this.categoryCode);
  final int categoryCode;

  @override
  bool matches(TrendAccount account) {
    if (account.status != AssetStatus.active) return false;
    if (categoryCode == AssetType.debtLend ||
        categoryCode == AssetType.debtBorrow) {
      return account.type == AssetType.debt && account.subType == categoryCode;
    }
    return account.type == categoryCode;
  }

  @override
  bool operator ==(Object other) =>
      other is AssetTrendFilterCategory && other.categoryCode == categoryCode;

  @override
  int get hashCode => categoryCode.hashCode;
}

final class AssetTrendFilterCustomGroup extends AssetTrendFilter {
  const AssetTrendFilterCustomGroup(this.groupName);
  final String groupName;

  @override
  bool matches(TrendAccount account) {
    return account.status == AssetStatus.active &&
        account.groupName == groupName;
  }

  @override
  bool operator ==(Object other) =>
      other is AssetTrendFilterCustomGroup && other.groupName == groupName;

  @override
  int get hashCode => groupName.hashCode;
}

final class AssetTrendFilterSingleAsset extends AssetTrendFilter {
  const AssetTrendFilterSingleAsset(this.assetId);
  final int assetId;

  @override
  bool matches(TrendAccount account) {
    return account.id == assetId;
  }

  @override
  bool operator ==(Object other) =>
      other is AssetTrendFilterSingleAsset && other.assetId == assetId;

  @override
  int get hashCode => assetId.hashCode;
}

/// Perspective switch for asset trend charts (R2, fixing ASYM-AT-01).
enum AssetTrendPerspective { netWorth, totalAsset, totalLiability }

/// Account entity needed by the asset trend engine.
final class TrendAccount {
  const TrendAccount({
    required this.id,
    required this.name,
    required this.type,
    this.subType = -1,
    required this.balanceMinor,
    required this.isEffectiveAsset,
    this.status = AssetStatus.active,
    this.currency,
    this.groupName,
    this.creditInfo,
  });

  final int id;
  final String name;
  final int type;
  final int subType;
  final BigInt balanceMinor;
  final int isEffectiveAsset;
  final int status;
  final String? currency;
  final String? groupName;
  final String? creditInfo;

  bool get counted =>
      type == AssetType.debt ? isEffectiveAsset == 0 : isEffectiveAsset == 1;

  bool get isCredit => type == AssetType.credit;
}

/// Transaction record used for asset trend backward walk.
final class TrendRecord {
  const TrendRecord({
    required this.id,
    required this.type,
    this.subType = RecordDirection.none,
    required this.moneyMinor,
    this.discountMinor,
    required this.recordTime,
    this.assetId = noRef,
    this.fromAssetId = noRef,
    this.toAssetId = noRef,
    this.accountBookId = 1,
    this.currency,
  });

  final String id;
  final int type;
  final int subType;
  final BigInt moneyMinor;
  final BigInt? discountMinor;
  final int recordTime;
  final int assetId;
  final int fromAssetId;
  final int toAssetId;
  final int accountBookId;
  final CurrencySnapshot? currency;
}

/// A monthly point in the trend series (R4 / R6).
final class TrendPoint {
  const TrendPoint({
    required this.yearMonth,
    required this.year,
    required this.month,
    required this.balanceMinor,
    required this.inflowMinor,
    required this.outflowMinor,
    required this.hasRecords,
    required this.isCarriedForward,
    this.isFuturePadding = false,
  });

  final String yearMonth;
  final int year;
  final int month;
  final BigInt balanceMinor;
  final BigInt inflowMinor;
  final BigInt outflowMinor;
  final bool hasRecords;
  final bool isCarriedForward;
  final bool isFuturePadding;
}

/// Result of the monthly asset trend calculation.
final class AssetTrendResult {
  const AssetTrendResult({
    required this.anchorMinor,
    required this.chartPoints,
    required this.tableRows,
    required this.currencySymbol,
    required this.currencyCode,
    required this.isCredit,
  });

  final BigInt anchorMinor;
  final List<TrendPoint> chartPoints;
  final List<TrendPoint> tableRows;
  final String currencySymbol;
  final String currencyCode;
  final bool isCredit;
}

/// Item in Card 1 asset distribution.
final class AssetDistributionItem {
  const AssetDistributionItem({
    required this.id,
    required this.name,
    required this.amountMinor,
    required this.ratio,
    this.currency = 'CNY',
  });

  final int id;
  final String name;
  final BigInt amountMinor;
  final double ratio;
  final String currency;
}

/// Real-time asset distribution breakdown (Card 1, R1/R3, fixing ASYM-AT-02).
final class AssetDistributionResult {
  const AssetDistributionResult({
    required this.positiveTotalMinor,
    required this.positiveItems,
    required this.liabilityTotalMinor,
    required this.liabilityItems,
  });

  final BigInt positiveTotalMinor;
  final List<AssetDistributionItem> positiveItems;
  final BigInt liabilityTotalMinor;
  final List<AssetDistributionItem> liabilityItems;

  BigInt get netAssetMinor => positiveTotalMinor - liabilityTotalMinor;
}

/// Computes the real-time asset and liability distribution for Card 1.
///
/// Strictly filters `status == AssetStatus.active && counted` (fixing ASYM-AT-02).
AssetDistributionResult computeAssetDistribution(
  Iterable<TrendAccount> accounts,
  RateTable rates,
) {
  var positiveTotal = BigInt.zero;
  var liabilityTotal = BigInt.zero;
  final posList = <({TrendAccount account, BigInt converted})>[];
  final liabList = <({TrendAccount account, BigInt converted})>[];

  for (final a in accounts) {
    if (a.status != AssetStatus.active || !a.counted) continue;
    final converted = rates.convert(a.balanceMinor, a.currency, rates.base);
    final borrowed =
        a.type == AssetType.debt && a.subType == AssetType.debtBorrow;
    if (borrowed) {
      if (converted > BigInt.zero) {
        liabilityTotal += converted;
        liabList.add((account: a, converted: converted));
      } else if (converted < BigInt.zero) {
        final pos = -converted;
        positiveTotal += pos;
        posList.add((account: a, converted: pos));
      }
    } else {
      if (converted > BigInt.zero) {
        positiveTotal += converted;
        posList.add((account: a, converted: converted));
      } else if (converted < BigInt.zero) {
        final neg = -converted;
        liabilityTotal += neg;
        liabList.add((account: a, converted: neg));
      }
    }
  }

  posList.sort((x, y) => y.converted.compareTo(x.converted));
  liabList.sort((x, y) => y.converted.compareTo(x.converted));

  final positiveItems = posList.map((e) {
    final r = positiveTotal > BigInt.zero
        ? (e.converted.toDouble() / positiveTotal.toDouble())
        : 0.0;
    return AssetDistributionItem(
      id: e.account.id,
      name: e.account.name,
      amountMinor: e.converted,
      ratio: r,
      currency: rates.base,
    );
  }).toList();

  final liabilityItems = liabList.map((e) {
    final r = liabilityTotal > BigInt.zero
        ? (e.converted.toDouble() / liabilityTotal.toDouble())
        : 0.0;
    return AssetDistributionItem(
      id: e.account.id,
      name: e.account.name,
      amountMinor: e.converted,
      ratio: r,
      currency: rates.base,
    );
  }).toList();

  return AssetDistributionResult(
    positiveTotalMinor: positiveTotal,
    positiveItems: positiveItems,
    liabilityTotalMinor: liabilityTotal,
    liabilityItems: liabilityItems,
  );
}

/// Computes the anchor benchmark `anchorMinor` for the target account set (R2).
///
/// Historical monthly backward baseline does not deduct uncredited installment
/// `inst` (fixing ASYM-AT-04a).
BigInt computeTrendAnchor({
  required List<TrendAccount> accounts,
  required RateTable rates,
  required AssetTrendFilter filter,
  AssetTrendPerspective perspective = AssetTrendPerspective.netWorth,
  bool useOriginalCurrency = false,
  bool includeInstallment = false,
}) {
  final targetAccounts = accounts.where(filter.matches).toList();
  if (targetAccounts.isEmpty) return BigInt.zero;

  if (filter is AssetTrendFilterSingleAsset) {
    final account = targetAccounts.first;
    if (useOriginalCurrency) {
      return account.balanceMinor;
    }
    return rates.convert(account.balanceMinor, account.currency, rates.base);
  }

  var posAsset = BigInt.zero;
  var liabAsset = BigInt.zero;

  for (final a in targetAccounts) {
    final converted = rates.convert(a.balanceMinor, a.currency, rates.base);
    final borrowed =
        a.type == AssetType.debt && a.subType == AssetType.debtBorrow;
    if (borrowed) {
      if (converted > BigInt.zero) {
        liabAsset += converted;
      } else if (converted < BigInt.zero) {
        posAsset += -converted;
      }
    } else {
      if (converted > BigInt.zero) {
        posAsset += converted;
      } else if (converted < BigInt.zero) {
        liabAsset += -converted;
      }
    }
    if (includeInstallment && a.type == AssetType.credit) {
      final inst = rates.convert(
        uncreditedInstallment(a.creditInfo),
        a.currency,
        rates.base,
      );
      liabAsset += inst;
    }
  }

  return switch (perspective) {
    AssetTrendPerspective.netWorth => posAsset - liabAsset,
    AssetTrendPerspective.totalAsset => posAsset,
    AssetTrendPerspective.totalLiability => liabAsset,
  };
}

/// Returns the assigned billing period year-month key (`"yyyy-MM"`) based on `startDay` (R4).
String getPeriodKey(int recordTimeMs, int startDay) {
  final effectiveStartDay = (startDay >= 1 && startDay <= 28) ? startDay : 1;
  final dt = DateTime.fromMillisecondsSinceEpoch(recordTimeMs);
  final int year, month;
  if (dt.day < effectiveStartDay) {
    final prev = DateTime(dt.year, dt.month - 1, 1);
    year = prev.year;
    month = prev.month;
  } else {
    year = dt.year;
    month = dt.month;
  }
  return '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}';
}

/// Formats balance or credit arrears label (fixing ASYM-AT-04b).
///
/// In credit mode:
/// - positive value renders `'溢存款：¥xx.xx'`
/// - negative/zero value renders `'欠款：¥xx.xx'` with absolute value (no double negative).
String formatTrendBalance(
  BigInt minor, {
  required bool isCredit,
  String symbol = '¥',
}) {
  final absDecimal = Money.minor(minor.abs()).decimal;
  if (isCredit) {
    if (minor > BigInt.zero) {
      return '溢存款：$symbol$absDecimal';
    } else {
      return '欠款：$symbol$absDecimal';
    }
  } else {
    if (minor < BigInt.zero) {
      return '余额：-$symbol$absDecimal';
    } else {
      return '余额：$symbol$absDecimal';
    }
  }
}

/// Maps currency code to standard currency symbol.
String currencySymbolOf(String? currencyCode) {
  final c = normalizeCurrency(currencyCode);
  return switch (c) {
    'CNY' => '¥',
    'USD' => r'$',
    'EUR' => '€',
    'GBP' => '£',
    'JPY' => '¥',
    'HKD' => r'HK$',
    _ => '¥',
  };
}

/// Selects the effective transaction amount in [targetCurrency] according to R5 rules.
BigInt _selectTrendAmount({
  required TrendRecord record,
  required String targetCurrency,
  required RateTable rates,
  bool isFromSide = false,
  bool preferAssetSide = false,
}) {
  final target = normalizeCurrency(targetCurrency) ?? rates.base;
  final curr = record.currency;

  if (curr != null && curr.isValid) {
    if (record.type == RecordType.transfer) {
      if (isFromSide) {
        if (normalizeCurrency(curr.sourceCode) == target) {
          return curr.sourceGross;
        }
        if (normalizeCurrency(curr.baseCode) == target &&
            curr.baseAmount != null) {
          return curr.baseAmount!;
        }
        if (normalizeCurrency(curr.assetCode) == target &&
            curr.assetNet != null) {
          return curr.assetNet!;
        }
        if (curr.baseAmount != null && curr.baseCode != null) {
          return rates.convert(curr.baseAmount!, curr.baseCode, target);
        }
        return rates.convert(curr.sourceGross, curr.sourceCode, target);
      } else {
        if (normalizeCurrency(curr.assetCode) == target &&
            curr.assetNet != null) {
          return curr.assetNet!;
        }
        if (normalizeCurrency(curr.baseCode) == target &&
            curr.baseAmount != null) {
          return curr.baseAmount!;
        }
        if (normalizeCurrency(curr.sourceCode) == target) {
          return curr.sourceGross - (record.discountMinor ?? BigInt.zero);
        }
        if (curr.assetNet != null && curr.assetCode != null) {
          return rates.convert(curr.assetNet!, curr.assetCode, target);
        }
        if (curr.baseAmount != null && curr.baseCode != null) {
          return rates.convert(curr.baseAmount!, curr.baseCode, target);
        }
        return rates.convert(
          curr.sourceGross - (record.discountMinor ?? BigInt.zero),
          curr.sourceCode,
          target,
        );
      }
    } else {
      if (normalizeCurrency(curr.sourceCode) == target) {
        return curr.sourceGross - (record.discountMinor ?? BigInt.zero);
      }
      if (normalizeCurrency(curr.assetCode) == target &&
          curr.assetNet != null) {
        return curr.assetNet!;
      }
      if (normalizeCurrency(curr.baseCode) == target &&
          curr.baseAmount != null) {
        return curr.baseAmount!;
      }
      if (curr.baseAmount != null && curr.baseCode != null) {
        return rates.convert(curr.baseAmount!, curr.baseCode, target);
      }
      return rates.convert(
        curr.sourceGross - (record.discountMinor ?? BigInt.zero),
        curr.sourceCode,
        target,
      );
    }
  }

  final netMoney = record.moneyMinor - (record.discountMinor ?? BigInt.zero);
  return netMoney;
}

/// Card 2 & Card 3 monthly backward walk engine (R2/R4/R5/R6).
AssetTrendResult computeAssetTrend({
  required List<TrendAccount> accounts,
  required List<TrendRecord> records,
  required RateTable rates,
  required AssetTrendFilter filter,
  AssetTrendPerspective perspective = AssetTrendPerspective.netWorth,
  int? selectedYear,
  bool useOriginalCurrency = false,
  Map<int, int> bookStartDays = const {},
  BigInt? explicitAnchorMinor,
  DateTime? referenceDate,
}) {
  final targetAccounts = accounts.where(filter.matches).toList();
  final targetIds = targetAccounts.map((a) => a.id).toSet();

  final singleAccount =
      filter is AssetTrendFilterSingleAsset && targetAccounts.isNotEmpty
      ? targetAccounts.first
      : null;

  final isCredit =
      (filter is AssetTrendFilterSingleAsset &&
          targetAccounts.isNotEmpty &&
          targetAccounts.first.isCredit) ||
      (filter is AssetTrendFilterCategory &&
          filter.categoryCode == AssetType.credit);

  final targetCurrency = (useOriginalCurrency && singleAccount != null)
      ? (normalizeCurrency(singleAccount.currency) ?? rates.base)
      : rates.base;
  final currencySymbol = currencySymbolOf(targetCurrency);

  final anchorMinor =
      explicitAnchorMinor ??
      computeTrendAnchor(
        accounts: accounts,
        rates: rates,
        filter: filter,
        perspective: perspective,
        useOriginalCurrency: useOriginalCurrency,
      );

  final monthInflow = <String, BigInt>{};
  final monthOutflow = <String, BigInt>{};
  final monthHasRecords = <String, bool>{};
  final recordYears = <int>{};

  for (final r in records) {
    if (r.recordTime <= 0) continue;
    final touches =
        targetIds.contains(r.assetId) ||
        targetIds.contains(r.fromAssetId) ||
        targetIds.contains(r.toAssetId);
    if (!touches) continue;

    final startDay = bookStartDays[r.accountBookId] ?? 1;
    final key = getPeriodKey(r.recordTime, startDay);
    final year = int.parse(key.substring(0, 4));
    recordYears.add(year);

    var inflow = BigInt.zero;
    var outflow = BigInt.zero;

    switch (r.type) {
      case RecordType.expense:
      case RecordType.installmentPrincipal:
      case RecordType.fee:
        if (targetIds.contains(r.assetId)) {
          final amt = _selectTrendAmount(
            record: r,
            targetCurrency: targetCurrency,
            rates: rates,
            preferAssetSide: false,
          );
          if (amt >= BigInt.zero) {
            outflow += amt;
          } else {
            inflow += -amt;
          }
        }

      case RecordType.income:
      case RecordType.reimburseReceipt:
      case RecordType.depositInterest:
        if (targetIds.contains(r.assetId)) {
          final amt = _selectTrendAmount(
            record: r,
            targetCurrency: targetCurrency,
            rates: rates,
            preferAssetSide: true,
          );
          if (amt >= BigInt.zero) {
            inflow += amt;
          } else {
            outflow += -amt;
          }
        }

      case RecordType.transfer:
        if (r.fromAssetId != r.toAssetId) {
          if (targetIds.contains(r.fromAssetId)) {
            final amt = _selectTrendAmount(
              record: r,
              targetCurrency: targetCurrency,
              rates: rates,
              isFromSide: true,
            );
            outflow += amt;
          }
          if (targetIds.contains(r.toAssetId)) {
            final amt = _selectTrendAmount(
              record: r,
              targetCurrency: targetCurrency,
              rates: rates,
              isFromSide: false,
            );
            inflow += amt;
          }
        }

      case RecordType.reimbursable:
        final payingId = r.fromAssetId != noRef ? r.fromAssetId : r.assetId;
        if (targetIds.contains(payingId)) {
          final amt = _selectTrendAmount(
            record: r,
            targetCurrency: targetCurrency,
            rates: rates,
            preferAssetSide: false,
          );
          if (amt >= BigInt.zero) {
            outflow += amt;
          } else {
            inflow += -amt;
          }
        }

      case RecordType.balanceAdjust:
        final targetId = r.fromAssetId != noRef ? r.fromAssetId : r.assetId;
        if (targetIds.contains(targetId)) {
          final amt = rates.convert(
            r.moneyMinor,
            singleAccount?.currency,
            targetCurrency,
          );
          if (amt >= BigInt.zero) {
            inflow += amt;
          } else {
            outflow += -amt;
          }
        }

      case RecordType.borrowIn:
      case RecordType.collect:
        if (targetIds.contains(r.toAssetId)) {
          final amt = _selectTrendAmount(
            record: r,
            targetCurrency: targetCurrency,
            rates: rates,
            preferAssetSide: true,
          );
          inflow += amt;
        }
        if (targetIds.contains(r.fromAssetId)) {
          final amt = _selectTrendAmount(
            record: r,
            targetCurrency: targetCurrency,
            rates: rates,
            preferAssetSide: false,
          );
          outflow += amt;
        }

      case RecordType.lendOut:
      case RecordType.repay:
        if (targetIds.contains(r.fromAssetId)) {
          final amt = _selectTrendAmount(
            record: r,
            targetCurrency: targetCurrency,
            rates: rates,
            preferAssetSide: false,
          );
          outflow += amt;
        }
        if (targetIds.contains(r.toAssetId)) {
          final amt = _selectTrendAmount(
            record: r,
            targetCurrency: targetCurrency,
            rates: rates,
            preferAssetSide: true,
          );
          inflow += amt;
        }

      case RecordType.debtInterest:
        if (r.subType == RecordDirection.expense &&
            targetIds.contains(r.fromAssetId)) {
          final amt = _selectTrendAmount(
            record: r,
            targetCurrency: targetCurrency,
            rates: rates,
            preferAssetSide: false,
          );
          outflow += amt;
        } else if (r.subType == RecordDirection.income &&
            targetIds.contains(r.toAssetId)) {
          final amt = _selectTrendAmount(
            record: r,
            targetCurrency: targetCurrency,
            rates: rates,
            preferAssetSide: true,
          );
          inflow += amt;
        }

      case RecordType.reimburseDiff:
        if (targetIds.contains(r.assetId)) {
          final amt = _selectTrendAmount(
            record: r,
            targetCurrency: targetCurrency,
            rates: rates,
          );
          if (r.subType == RecordDirection.expense) {
            outflow += amt;
          } else if (r.subType == RecordDirection.income) {
            inflow += amt;
          }
        }

      case RecordType.billInstallment:
        if (targetIds.contains(r.toAssetId) || targetIds.contains(r.assetId)) {
          final amt = _selectTrendAmount(
            record: r,
            targetCurrency: targetCurrency,
            rates: rates,
            preferAssetSide: true,
          );
          if (amt >= BigInt.zero) {
            inflow += amt;
          } else {
            outflow += -amt;
          }
        }

      case RecordType.advanceIncome:
      case RecordType.advanceExpense:
      default:
        break;
    }

    monthInflow[key] = (monthInflow[key] ?? BigInt.zero) + inflow;
    monthOutflow[key] = (monthOutflow[key] ?? BigInt.zero) + outflow;
    monthHasRecords[key] = true;
  }

  final now = referenceDate ?? DateTime.now();
  final currentYear = now.year;

  if (recordYears.isEmpty) {
    if (selectedYear != null) {
      final yPoints = List.generate(12, (i) {
        final m = i + 1;
        final k =
            '${selectedYear.toString().padLeft(4, '0')}-${m.toString().padLeft(2, '0')}';
        return TrendPoint(
          yearMonth: k,
          year: selectedYear,
          month: m,
          balanceMinor: anchorMinor,
          inflowMinor: BigInt.zero,
          outflowMinor: BigInt.zero,
          hasRecords: false,
          isCarriedForward: false,
        );
      });
      return AssetTrendResult(
        anchorMinor: anchorMinor,
        chartPoints: yPoints,
        tableRows: const [],
        currencySymbol: currencySymbol,
        currencyCode: targetCurrency,
        isCredit: isCredit,
      );
    } else {
      final defPoints = List.generate(3, (i) {
        final m = i + 1;
        final k =
            '${currentYear.toString().padLeft(4, '0')}-${m.toString().padLeft(2, '0')}';
        return TrendPoint(
          yearMonth: k,
          year: currentYear,
          month: m,
          balanceMinor: anchorMinor,
          inflowMinor: BigInt.zero,
          outflowMinor: BigInt.zero,
          hasRecords: false,
          isCarriedForward: false,
        );
      });
      return AssetTrendResult(
        anchorMinor: anchorMinor,
        chartPoints: defPoints,
        tableRows: const [],
        currencySymbol: currencySymbol,
        currencyCode: targetCurrency,
        isCredit: isCredit,
      );
    }
  }

  var minYear = recordYears.reduce((a, b) => a < b ? a : b);
  var maxYear = recordYears.reduce((a, b) => a > b ? a : b);
  if (currentYear > maxYear) maxYear = currentYear;
  if (selectedYear != null) {
    if (selectedYear < minYear) minYear = selectedYear;
    if (selectedYear > maxYear) maxYear = selectedYear;
  }

  final allKeys = <String>[];
  for (var y = minYear; y <= maxYear; y++) {
    for (var m = 1; m <= 12; m++) {
      allKeys.add(
        '${y.toString().padLeft(4, '0')}-${m.toString().padLeft(2, '0')}',
      );
    }
  }

  var cur = anchorMinor;
  final monthBalance = <String, BigInt>{};

  for (var i = allKeys.length - 1; i >= 0; i--) {
    final key = allKeys[i];
    if (monthHasRecords[key] == true) {
      monthBalance[key] = cur;
      final netFlow =
          (monthInflow[key] ?? BigInt.zero) -
          (monthOutflow[key] ?? BigInt.zero);
      cur = cur - netFlow;
    }
  }

  var seenFirst = false;
  var prevBalance = BigInt.zero;
  final fullPoints = <TrendPoint>[];

  for (final key in allKeys) {
    final year = int.parse(key.substring(0, 4));
    final month = int.parse(key.substring(5, 7));
    final hasRec = monthHasRecords[key] == true;
    final inFlow = monthInflow[key] ?? BigInt.zero;
    final outFlow = monthOutflow[key] ?? BigInt.zero;

    if (!seenFirst) {
      if (hasRec) {
        seenFirst = true;
        final bal = monthBalance[key]!;
        prevBalance = bal;
        fullPoints.add(
          TrendPoint(
            yearMonth: key,
            year: year,
            month: month,
            balanceMinor: bal,
            inflowMinor: inFlow,
            outflowMinor: outFlow,
            hasRecords: true,
            isCarriedForward: false,
          ),
        );
      } else {
        fullPoints.add(
          TrendPoint(
            yearMonth: key,
            year: year,
            month: month,
            balanceMinor: BigInt.zero,
            inflowMinor: BigInt.zero,
            outflowMinor: BigInt.zero,
            hasRecords: false,
            isCarriedForward: false,
          ),
        );
      }
    } else {
      if (hasRec) {
        final bal = monthBalance[key]!;
        prevBalance = bal;
        fullPoints.add(
          TrendPoint(
            yearMonth: key,
            year: year,
            month: month,
            balanceMinor: bal,
            inflowMinor: inFlow,
            outflowMinor: outFlow,
            hasRecords: true,
            isCarriedForward: false,
          ),
        );
      } else {
        fullPoints.add(
          TrendPoint(
            yearMonth: key,
            year: year,
            month: month,
            balanceMinor: prevBalance,
            inflowMinor: BigInt.zero,
            outflowMinor: BigInt.zero,
            hasRecords: false,
            isCarriedForward: true,
          ),
        );
      }
    }
  }

  if (selectedYear == null) {
    var lastWithRecordsIndex = -1;
    for (var i = fullPoints.length - 1; i >= 0; i--) {
      if (fullPoints[i].hasRecords) {
        lastWithRecordsIndex = i;
        break;
      }
    }
    var trimmed = lastWithRecordsIndex >= 0
        ? fullPoints.sublist(0, lastWithRecordsIndex + 1)
        : fullPoints;

    var firstWithRecordsIndex = -1;
    for (var i = 0; i < trimmed.length; i++) {
      if (trimmed[i].hasRecords) {
        firstWithRecordsIndex = i;
        break;
      }
    }
    trimmed = firstWithRecordsIndex >= 0
        ? trimmed.sublist(firstWithRecordsIndex)
        : trimmed;

    final chartPoints = List<TrendPoint>.from(trimmed);
    if (chartPoints.isNotEmpty && chartPoints.length < 3) {
      var last = chartPoints.last;
      while (chartPoints.length < 3) {
        final nextYear = last.month == 12 ? last.year + 1 : last.year;
        final nextMonth = last.month == 12 ? 1 : last.month + 1;
        final nextKey =
            '${nextYear.toString().padLeft(4, '0')}-${nextMonth.toString().padLeft(2, '0')}';
        final padPoint = TrendPoint(
          yearMonth: nextKey,
          year: nextYear,
          month: nextMonth,
          balanceMinor: last.balanceMinor,
          inflowMinor: BigInt.zero,
          outflowMinor: BigInt.zero,
          hasRecords: false,
          isCarriedForward: true,
          isFuturePadding: true,
        );
        chartPoints.add(padPoint);
        last = padPoint;
      }
    }

    final tableRows = chartPoints
        .where((p) => !p.isFuturePadding)
        .toList()
        .reversed
        .toList();

    return AssetTrendResult(
      anchorMinor: anchorMinor,
      chartPoints: chartPoints,
      tableRows: tableRows,
      currencySymbol: currencySymbol,
      currencyCode: targetCurrency,
      isCredit: isCredit,
    );
  } else {
    final yearPrefix = '${selectedYear.toString().padLeft(4, '0')}-';
    final yearPoints = fullPoints
        .where((p) => p.yearMonth.startsWith(yearPrefix))
        .toList();
    final tableRows = yearPoints.reversed.toList();

    return AssetTrendResult(
      anchorMinor: anchorMinor,
      chartPoints: yearPoints,
      tableRows: tableRows,
      currencySymbol: currencySymbol,
      currencyCode: targetCurrency,
      isCredit: isCredit,
    );
  }
}
