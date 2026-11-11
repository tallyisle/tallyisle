import '../ledger/record_extra.dart';
import '../ledger/record_relations.dart';
import '../model/codes.dart';
import 'billing_period.dart';
import 'income_expense.dart';

/// Single bill record representation required for annual analysis.
final class AnnualRecordItem {
  const AnnualRecordItem({
    required this.id,
    required this.type,
    this.subType = RecordDirection.none,
    required this.moneyMinor,
    this.discountMinor,
    this.currency,
    this.relations,
    this.excludeExIn = false,
    this.excludeBudget = false,
    required this.recordTime,
    this.bookId,
    this.categoryId,
    this.categoryName,
    this.categoryIcon,
    this.assetId,
    this.assetName,
  });

  final String id;
  final int type;
  final int subType;
  final BigInt moneyMinor;
  final BigInt? discountMinor;
  final CurrencySnapshot? currency;
  final RecordRelations? relations;
  final bool excludeExIn;
  final bool excludeBudget;
  final int recordTime;
  final int? bookId;
  final int? categoryId;
  final String? categoryName;
  final String? categoryIcon;
  final int? assetId;
  final String? assetName;

  StatEntry toStatEntry() => StatEntry(
    type: type,
    subType: subType,
    moneyMinor: moneyMinor,
    discountMinor: discountMinor,
    currency: currency,
    relations: relations,
    excludeExIn: excludeExIn,
    excludeBudget: excludeBudget,
  );
}

/// Monthly summary row for the 12-month breakdown table and chart.
final class MonthlyBucketSummary {
  const MonthlyBucketSummary({
    required this.year,
    required this.month,
    required this.income,
    required this.expense,
    required this.incomeCount,
    required this.expenseCount,
  });

  final int year;
  final int month;
  final BigInt income;
  final BigInt expense;
  final int incomeCount;
  final int expenseCount;

  BigInt get balance => income - expense;
  int get billCount => incomeCount + expenseCount;
}

/// Category item in the annual spending / income ranking.
final class AnnualCategoryItem {
  const AnnualCategoryItem({
    required this.categoryId,
    required this.categoryName,
    required this.categoryIcon,
    required this.amount,
    required this.count,
    required this.ratio,
  });

  final int categoryId;
  final String categoryName;
  final String categoryIcon;
  final BigInt amount;
  final int count;
  final double ratio;
}

/// Highlighted single record (e.g. max single expense or max single income).
final class AnnualRecordHighlight {
  const AnnualRecordHighlight({
    required this.id,
    required this.recordTime,
    required this.amount,
    this.categoryId,
    required this.categoryName,
    this.categoryIcon,
  });

  final String id;
  final int recordTime;
  final BigInt amount;
  final int? categoryId;
  final String categoryName;
  final String? categoryIcon;
}

/// Most frequently used account summary.
final class AnnualAssetHighlight {
  const AnnualAssetHighlight({
    required this.assetName,
    required this.count,
    required this.ratio,
  });

  final String assetName;
  final int count;
  final double ratio;
}

/// Aggregated result for a given year and startDay.
final class AnnualReportResult {
  const AnnualReportResult({
    required this.year,
    required this.startDay,
    required this.totalIncome,
    required this.totalExpense,
    required this.totalIncomeCount,
    required this.totalExpenseCount,
    required this.activeDays,
    required this.monthlySummaries,
    required this.topExpenseCategories,
    required this.topIncomeCategories,
    this.maxExpenseRecord,
    this.maxIncomeRecord,
    this.maxExpenseMonth,
    required this.maxExpenseMonthAmount,
    this.maxIncomeMonth,
    required this.maxIncomeMonthAmount,
    this.maxBillDayDate,
    required this.maxBillDayCount,
    this.mostUsedAsset,
    required this.totalDiscount,
  });

  final int year;
  final int startDay;
  final BigInt totalIncome;
  final BigInt totalExpense;
  final int totalIncomeCount;
  final int totalExpenseCount;
  final int activeDays;
  final List<MonthlyBucketSummary> monthlySummaries;
  final List<AnnualCategoryItem> topExpenseCategories;
  final List<AnnualCategoryItem> topIncomeCategories;
  final AnnualRecordHighlight? maxExpenseRecord;
  final AnnualRecordHighlight? maxIncomeRecord;
  final int? maxExpenseMonth;
  final BigInt maxExpenseMonthAmount;
  final int? maxIncomeMonth;
  final BigInt maxIncomeMonthAmount;
  final String? maxBillDayDate;
  final int maxBillDayCount;
  final AnnualAssetHighlight? mostUsedAsset;
  final BigInt totalDiscount;

  BigInt get totalBalance => totalIncome - totalExpense;
  int get totalBillCount => totalIncomeCount + totalExpenseCount;

  BigInt get averageMonthIncome => totalIncome ~/ BigInt.from(12);
  BigInt get averageMonthExpense => totalExpense ~/ BigInt.from(12);
  BigInt get averageMonthSurplus => totalBalance ~/ BigInt.from(12);

  double get savingsRate {
    if (totalIncome <= BigInt.zero) return 0.0;
    final surplus = totalIncome - totalExpense;
    return surplus.toDouble() / totalIncome.toDouble();
  }

  static AnnualReportResult empty({required int year, int startDay = 1}) {
    final day = normalizeStartDay(startDay);
    return AnnualReportResult(
      year: year,
      startDay: day,
      totalIncome: BigInt.zero,
      totalExpense: BigInt.zero,
      totalIncomeCount: 0,
      totalExpenseCount: 0,
      activeDays: 0,
      monthlySummaries: List.generate(
        12,
        (i) => MonthlyBucketSummary(
          year: year,
          month: i + 1,
          income: BigInt.zero,
          expense: BigInt.zero,
          incomeCount: 0,
          expenseCount: 0,
        ),
      ),
      topExpenseCategories: const [],
      topIncomeCategories: const [],
      maxExpenseRecord: null,
      maxIncomeRecord: null,
      maxExpenseMonth: null,
      maxExpenseMonthAmount: BigInt.zero,
      maxIncomeMonth: null,
      maxIncomeMonthAmount: BigInt.zero,
      maxBillDayDate: null,
      maxBillDayCount: 0,
      mostUsedAsset: null,
      totalDiscount: BigInt.zero,
    );
  }
}

BigInt _linkedRefundTotal(BillLinks? links, String target) {
  var total = BigInt.zero;
  for (final item in links?.children ?? const <LinkedBill>[]) {
    final BigInt v;
    if (item.assetCode == target && item.assetAmount != null) {
      v = item.assetAmount!;
    } else if (item.baseCode == target && item.baseAmount != null) {
      v = item.baseAmount!;
    } else {
      v = item.amount;
    }
    total += v.abs();
  }
  return total;
}

/// Pure domain rule: calculates the annual report for [year] with [startDay].
AnnualReportResult computeAnnualReport({
  required int year,
  required int startDay,
  required Iterable<AnnualRecordItem> records,
  String baseCurrency = 'CNY',
}) {
  final day = normalizeStartDay(startDay);
  final yearPeriod = BillingPeriod.year(year, day);

  final monthPeriods = List.generate(
    12,
    (index) => BillingPeriod.starting(year, index + 1, day),
  );

  final monthBuckets = List.generate(12, (_) => <AnnualRecordItem>[]);
  final effectiveRecords = <AnnualRecordItem>[];

  for (final r in records) {
    if (!yearPeriod.contains(r.recordTime)) continue;
    effectiveRecords.add(r);

    for (var m = 0; m < 12; m++) {
      if (monthPeriods[m].contains(r.recordTime)) {
        monthBuckets[m].add(r);
        break;
      }
    }
  }

  // 12-month summaries
  var totalIncome = BigInt.zero;
  var totalExpense = BigInt.zero;
  var totalIncomeCount = 0;
  var totalExpenseCount = 0;

  final monthlySummaries = <MonthlyBucketSummary>[];
  for (var m = 0; m < 12; m++) {
    final ie = aggregateIncomeExpense(
      monthBuckets[m].map((r) => r.toStatEntry()),
      target: baseCurrency,
      scope: StatScope.home,
    );
    totalIncome += ie.income;
    totalExpense += ie.expense;
    totalIncomeCount += ie.incomeCount;
    totalExpenseCount += ie.expenseCount;

    monthlySummaries.add(
      MonthlyBucketSummary(
        year: year,
        month: m + 1,
        income: ie.income,
        expense: ie.expense,
        incomeCount: ie.incomeCount,
        expenseCount: ie.expenseCount,
      ),
    );
  }

  // Active days & peak date & asset counts & total discounts
  final activeDateCounts = <String, int>{};
  final assetCounts = <String, int>{};
  var totalDiscount = BigInt.zero;

  // Category aggregates: catId -> (name, icon, amount, count)
  final expenseCategories =
      <int, ({String name, String icon, BigInt amount, int count})>{};
  final incomeCategories =
      <int, ({String name, String icon, BigInt amount, int count})>{};

  AnnualRecordHighlight? maxExpenseRecord;
  BigInt maxExpenseRecordAmount = BigInt.zero;

  AnnualRecordHighlight? maxIncomeRecord;
  BigInt maxIncomeRecordAmount = BigInt.zero;

  var totalEffectiveBills = 0;

  for (final r in effectiveRecords) {
    if (r.excludeExIn) continue;
    if (r.type == RecordType.reimburseReceipt) continue;
    if (r.type == RecordType.transfer) continue;

    totalEffectiveBills++;

    // Date tracking
    final dt = DateTime.fromMillisecondsSinceEpoch(r.recordTime);
    final dateKey =
        '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
    activeDateCounts[dateKey] = (activeDateCounts[dateKey] ?? 0) + 1;

    // Asset tracking
    final assetName = r.assetName;
    if (assetName != null && assetName.isNotEmpty) {
      assetCounts[assetName] = (assetCounts[assetName] ?? 0) + 1;
    }

    // Discounts
    if (r.discountMinor != null && r.discountMinor! > BigInt.zero) {
      totalDiscount += r.discountMinor!;
    }

    // Net contribution for single record & category
    final statEntry = r.toStatEntry();
    final raw = amountIn(statEntry, baseCurrency);

    BigInt recordExpense = BigInt.zero;
    BigInt recordIncome = BigInt.zero;

    switch (r.type) {
      case RecordType.expense:
        if (raw.isNegative) {
          final isRefundChild = (r.relations?.refunds?.originId ?? '')
              .trim()
              .isNotEmpty;
          if (!isRefundChild) {
            recordExpense = raw;
          }
        } else {
          final net =
              raw - _linkedRefundTotal(r.relations?.refunds, baseCurrency);
          if (net.isNegative) {
            recordIncome = -net;
          } else {
            recordExpense = net;
          }
        }
      case RecordType.income:
        if (raw.isNegative) {
          final isRefundChild = (r.relations?.refunds?.originId ?? '')
              .trim()
              .isNotEmpty;
          if (!isRefundChild) {
            recordIncome = raw;
          }
        } else {
          final net =
              raw - _linkedRefundTotal(r.relations?.refunds, baseCurrency);
          if (net.isNegative) {
            recordExpense = -net;
          } else {
            recordIncome = net;
          }
        }
      case RecordType.fee:
        if (!raw.isNegative) {
          recordExpense = raw;
        }
      case RecordType.reimbursable:
        final links = r.relations?.reimbursements;
        if (links != null && links.children.isNotEmpty) {
          final net =
              raw - _linkedRefundTotal(r.relations?.refunds, baseCurrency);
          final reimbursed = _linkedRefundTotal(links, baseCurrency);
          if (reimbursed < net) {
            recordExpense = net - reimbursed;
          } else if (reimbursed > net) {
            recordIncome = reimbursed - net;
          }
        }
      default:
        if (r.subType == RecordDirection.expense) {
          recordExpense = raw.abs();
        } else if (r.subType == RecordDirection.income) {
          recordIncome = raw.abs();
        }
    }

    // Check single expense
    if (recordExpense > BigInt.zero) {
      final catId = r.categoryId ?? -1;
      final catName = r.categoryName ?? '未分类';
      final catIcon = r.categoryIcon ?? '';

      final prev = expenseCategories[catId];
      if (prev == null) {
        expenseCategories[catId] = (
          name: catName,
          icon: catIcon,
          amount: recordExpense,
          count: 1,
        );
      } else {
        expenseCategories[catId] = (
          name: catName,
          icon: catIcon.isNotEmpty ? catIcon : prev.icon,
          amount: prev.amount + recordExpense,
          count: prev.count + 1,
        );
      }

      if (recordExpense > maxExpenseRecordAmount) {
        maxExpenseRecordAmount = recordExpense;
        maxExpenseRecord = AnnualRecordHighlight(
          id: r.id,
          recordTime: r.recordTime,
          amount: recordExpense,
          categoryId: r.categoryId,
          categoryName: catName,
          categoryIcon: catIcon,
        );
      }
    }

    // Check single income
    if (recordIncome > BigInt.zero) {
      final catId = r.categoryId ?? -1;
      final catName = r.categoryName ?? '未分类';
      final catIcon = r.categoryIcon ?? '';

      final prev = incomeCategories[catId];
      if (prev == null) {
        incomeCategories[catId] = (
          name: catName,
          icon: catIcon,
          amount: recordIncome,
          count: 1,
        );
      } else {
        incomeCategories[catId] = (
          name: catName,
          icon: catIcon.isNotEmpty ? catIcon : prev.icon,
          amount: prev.amount + recordIncome,
          count: prev.count + 1,
        );
      }

      if (recordIncome > maxIncomeRecordAmount) {
        maxIncomeRecordAmount = recordIncome;
        maxIncomeRecord = AnnualRecordHighlight(
          id: r.id,
          recordTime: r.recordTime,
          amount: recordIncome,
          categoryId: r.categoryId,
          categoryName: catName,
          categoryIcon: catIcon,
        );
      }
    }
  }

  // Peak months
  int? maxExpenseMonth;
  BigInt maxExpenseMonthAmount = BigInt.zero;
  int? maxIncomeMonth;
  BigInt maxIncomeMonthAmount = BigInt.zero;

  for (final m in monthlySummaries) {
    if (m.expense > maxExpenseMonthAmount) {
      maxExpenseMonthAmount = m.expense;
      maxExpenseMonth = m.month;
    }
    if (m.income > maxIncomeMonthAmount) {
      maxIncomeMonthAmount = m.income;
      maxIncomeMonth = m.month;
    }
  }

  // Max bill day
  String? maxBillDayDate;
  var maxBillDayCount = 0;
  for (final entry in activeDateCounts.entries) {
    if (entry.value > maxBillDayCount) {
      maxBillDayCount = entry.value;
      maxBillDayDate = entry.key;
    }
  }

  // Most used asset
  AnnualAssetHighlight? mostUsedAsset;
  if (assetCounts.isNotEmpty && totalEffectiveBills > 0) {
    var topAssetName = '';
    var topAssetCount = 0;
    for (final entry in assetCounts.entries) {
      if (entry.value > topAssetCount) {
        topAssetCount = entry.value;
        topAssetName = entry.key;
      }
    }
    if (topAssetCount > 0) {
      mostUsedAsset = AnnualAssetHighlight(
        assetName: topAssetName,
        count: topAssetCount,
        ratio: topAssetCount / totalEffectiveBills,
      );
    }
  }

  // Top categories sorted descending by amount
  final topExpenseCategories = expenseCategories.entries.map((e) {
    final ratio = totalExpense > BigInt.zero
        ? e.value.amount.toDouble() / totalExpense.toDouble()
        : 0.0;
    return AnnualCategoryItem(
      categoryId: e.key,
      categoryName: e.value.name,
      categoryIcon: e.value.icon,
      amount: e.value.amount,
      count: e.value.count,
      ratio: ratio,
    );
  }).toList()..sort((a, b) => b.amount.compareTo(a.amount));

  final topIncomeCategories = incomeCategories.entries.map((e) {
    final ratio = totalIncome > BigInt.zero
        ? e.value.amount.toDouble() / totalIncome.toDouble()
        : 0.0;
    return AnnualCategoryItem(
      categoryId: e.key,
      categoryName: e.value.name,
      categoryIcon: e.value.icon,
      amount: e.value.amount,
      count: e.value.count,
      ratio: ratio,
    );
  }).toList()..sort((a, b) => b.amount.compareTo(a.amount));

  return AnnualReportResult(
    year: year,
    startDay: day,
    totalIncome: totalIncome,
    totalExpense: totalExpense,
    totalIncomeCount: totalIncomeCount,
    totalExpenseCount: totalExpenseCount,
    activeDays: activeDateCounts.length,
    monthlySummaries: monthlySummaries,
    topExpenseCategories: topExpenseCategories,
    topIncomeCategories: topIncomeCategories,
    maxExpenseRecord: maxExpenseRecord,
    maxIncomeRecord: maxIncomeRecord,
    maxExpenseMonth: maxExpenseMonth,
    maxExpenseMonthAmount: maxExpenseMonthAmount,
    maxIncomeMonth: maxIncomeMonth,
    maxIncomeMonthAmount: maxIncomeMonthAmount,
    maxBillDayDate: maxBillDayDate,
    maxBillDayCount: maxBillDayCount,
    mostUsedAsset: mostUsedAsset,
    totalDiscount: totalDiscount,
  );
}
