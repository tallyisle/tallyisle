import '../../core/money.dart';
import '../ledger/record_extra.dart';
import '../ledger/record_relations.dart';
import '../model/codes.dart';
import 'billing_period.dart';
import 'income_expense.dart';

/// Statistical dimension: Expense or Income.
enum StatDimension { expense, income }

/// Statistical period granularity: Month, Year, or Custom range.
enum StatRangeKind { month, year, custom }

/// Outlier smoothing mode using Tukey's boxplot IQR method.
enum OutlierSmoothing {
  none,
  primary, // Q3 + 1.5 * IQR
  secondary, // Q3 + 3.0 * IQR
}

/// Metadata of a category for statistics aggregation.
final class CategoryMeta {
  const CategoryMeta({
    required this.id,
    required this.name,
    this.icon = '',
    this.type = 0,
    this.parentCatId = -1,
    this.sort = 0,
    this.accountBookId = 1,
  });

  final int id;
  final String name;
  final String icon;

  /// 0 expense, 1 income.
  final int type;
  final int parentCatId;
  final int sort;
  final int accountBookId;

  bool get isParent => parentCatId == -1;
}

/// A normalized transaction record entry fed into category statistics.
final class CategoryStatEntry {
  const CategoryStatEntry({
    required this.recordId,
    required this.accountBookId,
    required this.recordTime,
    required this.type,
    this.subType = RecordDirection.none,
    required this.moneyMinor,
    this.discountMinor,
    this.recordCatId = -1,
    this.assetId = -1,
    this.fromAssetId = -1,
    this.toAssetId = -1,
    this.currency,
    this.relations,
    this.excludeExIn = false,
    this.excludeBudget = false,
    this.remark = '',
    this.tagIds = const [],
    this.createDate,
  });

  final String recordId;
  final int accountBookId;
  final int recordTime;
  final int type;
  final int subType;
  final BigInt moneyMinor;
  final BigInt? discountMinor;
  final int recordCatId;
  final int assetId;
  final int fromAssetId;
  final int toAssetId;
  final CurrencySnapshot? currency;
  final RecordRelations? relations;
  final bool excludeExIn;
  final bool excludeBudget;
  final String remark;
  final List<String> tagIds;
  final int? createDate;
}

/// A net transaction bill classified into a specific dimension.
final class CategoryBill {
  CategoryBill({
    required this.entry,
    required this.dimension,
    required this.netMinor,
    BigInt? discountMinor,
  }) : discountMinor = discountMinor ?? BigInt.zero;

  final CategoryStatEntry entry;
  final StatDimension dimension;
  final BigInt netMinor;
  final BigInt discountMinor;

  String get recordId => entry.recordId;
  int get recordTime => entry.recordTime;
  int get recordCatId => entry.recordCatId;
  String get remark => entry.remark;
}

/// A single category row item in the ranking list.
final class CategoryRowItem {
  CategoryRowItem({
    required this.categoryId,
    required this.name,
    this.icon = '',
    this.isDirectChild = false,
    this.isFirstLevel = true,
    this.parentCatId = -1,
    required this.moneyMinor,
    required this.count,
    required this.ratioBasisPoints,
    BigInt? discountMinor,
    this.children = const [],
    this.bills = const [],
    this.lastPeriodMoneyMinor,
    this.growthBasisPoints,
  }) : discountMinor = discountMinor ?? BigInt.zero;

  final int categoryId;
  final String name;
  final String icon;
  final bool isDirectChild;
  final bool isFirstLevel;
  final int parentCatId;
  final BigInt moneyMinor;
  final int count;

  /// Percentage in basis points (10000 = 100.00%, 9662 = 96.62%, 97 = 0.97%).
  final int ratioBasisPoints;
  final BigInt discountMinor;
  final List<CategoryRowItem> children;
  final List<CategoryBill> bills;
  final BigInt? lastPeriodMoneyMinor;
  final int? growthBasisPoints;

  double get ratioPercent => ratioBasisPoints / 100.0;

  String get ratioText => formatBasisPoints(ratioBasisPoints);

  CategoryRowItem copyWith({
    int? categoryId,
    String? name,
    String? icon,
    bool? isDirectChild,
    bool? isFirstLevel,
    int? parentCatId,
    BigInt? moneyMinor,
    int? count,
    int? ratioBasisPoints,
    BigInt? discountMinor,
    List<CategoryRowItem>? children,
    List<CategoryBill>? bills,
    BigInt? lastPeriodMoneyMinor,
    int? growthBasisPoints,
  }) {
    return CategoryRowItem(
      categoryId: categoryId ?? this.categoryId,
      name: name ?? this.name,
      icon: icon ?? this.icon,
      isDirectChild: isDirectChild ?? this.isDirectChild,
      isFirstLevel: isFirstLevel ?? this.isFirstLevel,
      parentCatId: parentCatId ?? this.parentCatId,
      moneyMinor: moneyMinor ?? this.moneyMinor,
      count: count ?? this.count,
      ratioBasisPoints: ratioBasisPoints ?? this.ratioBasisPoints,
      discountMinor: discountMinor ?? this.discountMinor,
      children: children ?? this.children,
      bills: bills ?? this.bills,
      lastPeriodMoneyMinor: lastPeriodMoneyMinor ?? this.lastPeriodMoneyMinor,
      growthBasisPoints: growthBasisPoints ?? this.growthBasisPoints,
    );
  }
}

/// Fallback closing item for uncategorized records (ASYM-CAT-01).
final class UncategorizedRowItem {
  const UncategorizedRowItem({
    this.name = '未分类 / 其他',
    required this.moneyMinor,
    required this.count,
    required this.ratioBasisPoints,
    required this.recordIds,
    this.bills = const [],
  });

  final String name;
  final BigInt moneyMinor;
  final int count;
  final int ratioBasisPoints;
  final List<String> recordIds;
  final List<CategoryBill> bills;

  double get ratioPercent => ratioBasisPoints / 100.0;
  String get ratioText => formatBasisPoints(ratioBasisPoints);
}

/// A trend bucket data point for plotting charts.
final class TrendBucket {
  const TrendBucket({
    required this.label,
    required this.startDate,
    required this.endDate,
    required this.actualMinor,
    required this.displayMinor,
    this.isOutlier = false,
    this.upperFenceMinor,
    this.medianMinor,
  });

  final String label;
  final DateTime startDate;
  final DateTime endDate;
  final BigInt actualMinor;
  final BigInt displayMinor;
  final bool isOutlier;
  final BigInt? upperFenceMinor;
  final BigInt? medianMinor;
}

/// Complete result of category stats aggregation.
final class CategoryStatsResult {
  const CategoryStatsResult({
    required this.dimension,
    required this.period,
    required this.headerTotalMinor,
    required this.headerCount,
    required this.dailyAverageMinor,
    required this.elapsedDays,
    required this.firstLevelRows,
    required this.flattenRows,
    required this.flattenDenominatorMinor,
    this.uncategorizedRow,
    required this.trendBuckets,
    this.lastPeriodTotalMinor,
    this.growthBasisPoints,
    this.bills = const [],
  });

  final StatDimension dimension;
  final BillingPeriod period;
  final BigInt headerTotalMinor;
  final int headerCount;
  final BigInt dailyAverageMinor;
  final int elapsedDays;

  /// First-level rolled up category ranking list.
  final List<CategoryRowItem> firstLevelRows;

  /// Second-level flattened category ranking list (F01).
  final List<CategoryRowItem> flattenRows;

  /// The sum of all retained flatten category rows (F01 denominator).
  final BigInt flattenDenominatorMinor;

  /// Uncategorized closing row (ASYM-CAT-01).
  final UncategorizedRowItem? uncategorizedRow;

  /// Trend buckets for chart rendering.
  final List<TrendBucket> trendBuckets;

  /// Total amount of previous comparable period.
  final BigInt? lastPeriodTotalMinor;

  /// Growth rate relative to previous period in basis points.
  final int? growthBasisPoints;

  /// All transaction bills in this dimension.
  final List<CategoryBill> bills;
}

/// Helper to format basis points to percentage text (e.g. 9662 -> "96.62%").
String formatBasisPoints(int basisPoints) {
  final whole = basisPoints ~/ 100;
  final fraction = (basisPoints % 100).abs();
  final fractionStr = fraction < 10 ? '0$fraction' : '$fraction';
  return '$whole.$fractionStr%';
}

BigInt _linkedTotal(BillLinks? links, String target) {
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

/// Process a single [CategoryStatEntry] into a [CategoryBill] under R2 & R3 rules.
CategoryBill? processCategoryEntry(
  CategoryStatEntry entry, {
  bool includeExcludeBudget = true,
  String targetCurrency = 'CNY',
}) {
  // R2: strictly exclude exclude_ex_in == true.
  if (entry.excludeExIn) return null;

  // R2: filter out exclude_budget if disabled.
  if (!includeExcludeBudget && entry.excludeBudget) return null;

  // Internal transfers and reimbursement receipts never count.
  if (entry.type == RecordType.transfer) return null;
  if (entry.type == RecordType.reimburseReceipt) return null;

  // Linked refund child bills contribute 0 / 0 count (already netted on origin bill).
  final isRefundChild = (entry.relations?.refunds?.originId ?? '')
      .trim()
      .isNotEmpty;
  if (isRefundChild) return null;

  final stat = StatEntry(
    type: entry.type,
    subType: entry.subType,
    moneyMinor: entry.moneyMinor,
    discountMinor: entry.discountMinor,
    currency: entry.currency,
    relations: entry.relations,
    excludeExIn: entry.excludeExIn,
    excludeBudget: entry.excludeBudget,
  );
  final raw = amountIn(stat, targetCurrency);

  switch (entry.type) {
    case RecordType.expense:
      if (raw.isNegative) {
        return CategoryBill(
          entry: entry,
          dimension: StatDimension.expense,
          netMinor: raw,
          discountMinor: entry.discountMinor ?? BigInt.zero,
        );
      }
      final refundTotal = _linkedTotal(
        entry.relations?.refunds,
        targetCurrency,
      );
      final net = raw - refundTotal;
      if (net >= BigInt.zero) {
        // Full refund (net == 0) retains count = 1 and generates a 0.00 category row (R3).
        return CategoryBill(
          entry: entry,
          dimension: StatDimension.expense,
          netMinor: net,
          discountMinor: entry.discountMinor ?? BigInt.zero,
        );
      } else {
        // Over-refund: excess moves to income axis (R3).
        return CategoryBill(
          entry: entry,
          dimension: StatDimension.income,
          netMinor: -net,
          discountMinor: BigInt.zero,
        );
      }

    case RecordType.income:
      if (raw.isNegative) {
        return CategoryBill(
          entry: entry,
          dimension: StatDimension.income,
          netMinor: raw,
          discountMinor: entry.discountMinor ?? BigInt.zero,
        );
      }
      final refundTotal = _linkedTotal(
        entry.relations?.refunds,
        targetCurrency,
      );
      final net = raw - refundTotal;
      if (net >= BigInt.zero) {
        return CategoryBill(
          entry: entry,
          dimension: StatDimension.income,
          netMinor: net,
          discountMinor: entry.discountMinor ?? BigInt.zero,
        );
      } else {
        return CategoryBill(
          entry: entry,
          dimension: StatDimension.expense,
          netMinor: -net,
          discountMinor: BigInt.zero,
        );
      }

    case RecordType.fee:
      if (!raw.isNegative) {
        return CategoryBill(
          entry: entry,
          dimension: StatDimension.expense,
          netMinor: raw,
          discountMinor: BigInt.zero,
        );
      }
      return null;

    case RecordType.reimbursable:
      // R3: type == 3 reimbursable expense three-state rule.
      final links = entry.relations?.reimbursements;
      if (links == null || links.children.isEmpty) {
        // Unreimbursed: 0.00 / 0 count / no category row.
        return null;
      }
      final refundTotal = _linkedTotal(
        entry.relations?.refunds,
        targetCurrency,
      );
      final net = raw - refundTotal;
      final reimbursed = _linkedTotal(links, targetCurrency);
      if (reimbursed < net) {
        // Partially reimbursed (e.g. 120 reimb 50 -> net 70, 1 count).
        return CategoryBill(
          entry: entry,
          dimension: StatDimension.expense,
          netMinor: net - reimbursed,
          discountMinor: entry.discountMinor ?? BigInt.zero,
        );
      } else if (reimbursed > net) {
        // Over-reimbursed: excess difference moves to income axis.
        return CategoryBill(
          entry: entry,
          dimension: StatDimension.income,
          netMinor: reimbursed - net,
          discountMinor: BigInt.zero,
        );
      } else {
        // Fully reimbursed (120 reimb 120): 0.00 / 0 count / no category row.
        return null;
      }

    default:
      if (entry.subType == RecordDirection.expense) {
        return CategoryBill(
          entry: entry,
          dimension: StatDimension.expense,
          netMinor: raw.abs(),
          discountMinor: entry.discountMinor ?? BigInt.zero,
        );
      } else if (entry.subType == RecordDirection.income) {
        return CategoryBill(
          entry: entry,
          dimension: StatDimension.income,
          netMinor: raw.abs(),
          discountMinor: entry.discountMinor ?? BigInt.zero,
        );
      }
      return null;
  }
}

/// Computes Tukey IQR outlier statistics on a sequence of buckets (R7).
List<TrendBucket> applyTukeySmoothing(
  List<TrendBucket> buckets,
  OutlierSmoothing mode,
) {
  if (mode == OutlierSmoothing.none) return buckets;

  final positiveBuckets = buckets
      .where((b) => b.actualMinor > BigInt.zero)
      .toList();
  if (positiveBuckets.length < 4) {
    return buckets;
  }

  final sortedAmounts = positiveBuckets.map((b) => b.actualMinor).toList()
    ..sort();
  final n = sortedAmounts.length;

  BigInt medianOf(List<BigInt> list) {
    final m = list.length;
    if (m == 0) return BigInt.zero;
    if (m % 2 == 1) return list[m ~/ 2];
    return (list[m ~/ 2 - 1] + list[m ~/ 2]) ~/ BigInt.two;
  }

  // Tukey exclusive median
  final lowerHalf = sortedAmounts.sublist(0, n ~/ 2);
  final upperHalf = (n % 2 == 0)
      ? sortedAmounts.sublist(n ~/ 2)
      : sortedAmounts.sublist(n ~/ 2 + 1);

  final q1 = medianOf(lowerHalf);
  final q3 = medianOf(upperHalf);
  final iqr = q3 - q1;
  final overallMedian = medianOf(sortedAmounts);

  final BigInt kIqr;
  if (mode == OutlierSmoothing.primary) {
    // 1.5 * IQR = (15 * IQR) / 10
    kIqr = divideRounded(
      iqr * BigInt.from(15),
      BigInt.from(10),
      RoundingMode.halfUp,
    );
  } else {
    // 3.0 * IQR = 3 * IQR
    kIqr = iqr * BigInt.from(3);
  }
  final upperFence = q3 + kIqr;

  return [
    for (final b in buckets)
      if (b.actualMinor > upperFence)
        TrendBucket(
          label: b.label,
          startDate: b.startDate,
          endDate: b.endDate,
          actualMinor: b.actualMinor,
          displayMinor: overallMedian, // Truncate display to median (DR-CAT-09)
          isOutlier: true,
          upperFenceMinor: upperFence,
          medianMinor: overallMedian,
        )
      else
        TrendBucket(
          label: b.label,
          startDate: b.startDate,
          endDate: b.endDate,
          actualMinor: b.actualMinor,
          displayMinor: b.actualMinor,
          isOutlier: false,
          upperFenceMinor: upperFence,
          medianMinor: overallMedian,
        ),
  ];
}

/// Generates time trend buckets based on period and range kind.
List<TrendBucket> generateTrendBuckets({
  required BillingPeriod period,
  required List<CategoryBill> bills,
  required StatRangeKind rangeKind,
  required OutlierSmoothing smoothing,
}) {
  final buckets = <TrendBucket>[];

  if (rangeKind == StatRangeKind.month) {
    // Daily buckets across the billing period
    final startDay = DateTime(
      period.start.year,
      period.start.month,
      period.start.day,
    );
    final endDay = DateTime(period.end.year, period.end.month, period.end.day);
    var cursor = startDay;

    while (!cursor.isAfter(endDay)) {
      final bucketStart = DateTime(cursor.year, cursor.month, cursor.day);
      final nextDay = DateTime(cursor.year, cursor.month, cursor.day + 1);
      final bucketEnd = nextDay.subtract(const Duration(milliseconds: 1));
      final sMs = bucketStart.millisecondsSinceEpoch;
      final eMs = bucketEnd.millisecondsSinceEpoch;

      var actual = BigInt.zero;
      for (final b in bills) {
        if (b.recordTime >= sMs && b.recordTime <= eMs) {
          actual += b.netMinor;
        }
      }

      final label =
          '${cursor.month.toString().padLeft(2, '0')}-${cursor.day.toString().padLeft(2, '0')}';
      buckets.add(
        TrendBucket(
          label: label,
          startDate: bucketStart,
          endDate: bucketEnd,
          actualMinor: actual,
          displayMinor: actual,
        ),
      );

      cursor = nextDay;
    }
  } else if (rangeKind == StatRangeKind.year) {
    // 12 monthly buckets across the yearly billing period
    for (var m = 0; m < 12; m++) {
      final monthStart = DateTime(period.start.year, period.start.month + m, 1);
      final nextMonth = DateTime(
        period.start.year,
        period.start.month + m + 1,
        1,
      );
      final monthEnd = nextMonth.subtract(const Duration(milliseconds: 1));
      final sMs = monthStart.millisecondsSinceEpoch;
      final eMs = monthEnd.millisecondsSinceEpoch;

      var actual = BigInt.zero;
      for (final b in bills) {
        if (b.recordTime >= sMs && b.recordTime <= eMs) {
          actual += b.netMinor;
        }
      }

      buckets.add(
        TrendBucket(
          label: '${monthStart.month}月',
          startDate: monthStart,
          endDate: monthEnd,
          actualMinor: actual,
          displayMinor: actual,
        ),
      );
    }
  } else {
    // Custom date range
    final totalDays = period.totalDays;
    if (totalDays <= 31) {
      // Daily
      var cursor = DateTime(
        period.start.year,
        period.start.month,
        period.start.day,
      );
      final endDay = DateTime(
        period.end.year,
        period.end.month,
        period.end.day,
      );
      while (!cursor.isAfter(endDay)) {
        final bucketStart = DateTime(cursor.year, cursor.month, cursor.day);
        final nextDay = DateTime(cursor.year, cursor.month, cursor.day + 1);
        final bucketEnd = nextDay.subtract(const Duration(milliseconds: 1));
        final sMs = bucketStart.millisecondsSinceEpoch;
        final eMs = bucketEnd.millisecondsSinceEpoch;

        var actual = BigInt.zero;
        for (final b in bills) {
          if (b.recordTime >= sMs && b.recordTime <= eMs) {
            actual += b.netMinor;
          }
        }

        final label =
            '${cursor.month.toString().padLeft(2, '0')}-${cursor.day.toString().padLeft(2, '0')}';
        buckets.add(
          TrendBucket(
            label: label,
            startDate: bucketStart,
            endDate: bucketEnd,
            actualMinor: actual,
            displayMinor: actual,
          ),
        );
        cursor = nextDay;
      }
    } else {
      // Monthly partitions
      var cursor = DateTime(period.start.year, period.start.month, 1);
      while (cursor.isBefore(period.end)) {
        final next = DateTime(cursor.year, cursor.month + 1, 1);
        final sMs = cursor.millisecondsSinceEpoch;
        final eMs = next
            .subtract(const Duration(milliseconds: 1))
            .millisecondsSinceEpoch;

        var actual = BigInt.zero;
        for (final b in bills) {
          if (b.recordTime >= sMs && b.recordTime <= eMs) {
            actual += b.netMinor;
          }
        }

        buckets.add(
          TrendBucket(
            label: '${cursor.month}月',
            startDate: cursor,
            endDate: next.subtract(const Duration(milliseconds: 1)),
            actualMinor: actual,
            displayMinor: actual,
          ),
        );
        cursor = next;
      }
    }
  }

  return applyTukeySmoothing(buckets, smoothing);
}

/// Core domain function: aggregates records into [CategoryStatsResult].
CategoryStatsResult aggregateCategoryStats({
  required List<CategoryStatEntry> entries,
  required Map<int, CategoryMeta> categories,
  required BillingPeriod period,
  required StatDimension dimension,
  DateTime? now,
  bool includeExcludeBudget = true,
  StatRangeKind rangeKind = StatRangeKind.month,
  OutlierSmoothing outlierSmoothing = OutlierSmoothing.none,
  String targetCurrency = 'CNY',
  List<CategoryStatEntry>? lastPeriodEntries,
}) {
  // 1. Process entries into net bills.
  final allBills = <CategoryBill>[];
  for (final e in entries) {
    final bill = processCategoryEntry(
      e,
      includeExcludeBudget: includeExcludeBudget,
      targetCurrency: targetCurrency,
    );
    if (bill != null) {
      allBills.add(bill);
    }
  }

  // Filter bills belonging to the target dimension.
  final dimensionBills = allBills
      .where((b) => b.dimension == dimension)
      .toList();

  // 2. Header card totals.
  var headerTotalMinor = BigInt.zero;
  var headerCount = 0;
  for (final b in dimensionBills) {
    headerTotalMinor += b.netMinor;
    headerCount++;
  }

  // R1: Daily average calculation.
  final elapsedDays = period.elapsedDays(now ?? DateTime.now());
  final BigInt dailyAverageMinor;
  if (elapsedDays <= 0) {
    dailyAverageMinor = BigInt.zero;
  } else {
    dailyAverageMinor = divideRounded(
      headerTotalMinor,
      BigInt.from(elapsedDays),
      RoundingMode.halfUp,
    );
  }

  // 3. Separate categorized vs uncategorized records.
  final categorizedBills = <CategoryBill>[];
  final uncategorizedBills = <CategoryBill>[];
  for (final b in dimensionBills) {
    if (b.recordCatId == -1 || !categories.containsKey(b.recordCatId)) {
      uncategorizedBills.add(b);
    } else {
      categorizedBills.add(b);
    }
  }

  // Uncategorized closing row (ASYM-CAT-01).
  final UncategorizedRowItem? uncategorizedRow;
  if (uncategorizedBills.isNotEmpty) {
    var uncatTotal = BigInt.zero;
    for (final b in uncategorizedBills) {
      uncatTotal += b.netMinor;
    }
    final int uncatRatioBp;
    if (headerTotalMinor == BigInt.zero) {
      uncatRatioBp =
          (uncatTotal != BigInt.zero || uncategorizedBills.isNotEmpty)
          ? 10000
          : 0;
    } else {
      uncatRatioBp = divideRounded(
        uncatTotal * BigInt.from(10000),
        headerTotalMinor,
        RoundingMode.halfUp,
      ).toInt();
    }
    uncategorizedRow = UncategorizedRowItem(
      name: '未分类 / 其他',
      moneyMinor: uncatTotal,
      count: uncategorizedBills.length,
      ratioBasisPoints: uncatRatioBp,
      recordIds: uncategorizedBills.map((b) => b.recordId).toList(),
      bills: uncategorizedBills,
    );
  } else {
    uncategorizedRow = null;
  }

  // 4. First-Level Rollup (一级分类汇总) & Child Items (R6).
  // Group categorized bills by their parent first-level category.
  final billsByParentId = <int, List<CategoryBill>>{};
  for (final b in categorizedBills) {
    final cat = categories[b.recordCatId]!;
    final int parentId;
    if (cat.isParent) {
      parentId = cat.id;
    } else {
      final p = categories[cat.parentCatId];
      parentId = (p != null) ? p.id : cat.id;
    }
    billsByParentId.putIfAbsent(parentId, () => []).add(b);
  }

  final firstLevelRows = <CategoryRowItem>[];

  for (final entry in billsByParentId.entries) {
    final parentId = entry.key;
    final parentBills = entry.value;
    if (parentBills.isEmpty) continue; // Only retain categories with count > 0

    final parentMeta =
        categories[parentId] ??
        CategoryMeta(id: parentId, name: '分类 $parentId');

    var parentTotal = BigInt.zero;
    var parentDiscount = BigInt.zero;
    for (final b in parentBills) {
      parentTotal += b.netMinor;
      parentDiscount += b.discountMinor;
    }

    final int parentRatioBp;
    if (headerTotalMinor == BigInt.zero) {
      parentRatioBp = 10000; // headerTotalMinor == 0 fallback to 100.00%
    } else {
      parentRatioBp = divideRounded(
        parentTotal * BigInt.from(10000),
        headerTotalMinor,
        RoundingMode.halfUp,
      ).toInt();
    }

    // Decompose children: direct bills vs subcategory bills (R6).
    final directBills = <CategoryBill>[];
    final subBillsByCatId = <int, List<CategoryBill>>{};

    for (final b in parentBills) {
      if (b.recordCatId == parentId) {
        directBills.add(b);
      } else {
        subBillsByCatId.putIfAbsent(b.recordCatId, () => []).add(b);
      }
    }

    final children = <CategoryRowItem>[];

    // Build subcategory rows
    final subRows = <CategoryRowItem>[];
    for (final subEntry in subBillsByCatId.entries) {
      final subCatId = subEntry.key;
      final subList = subEntry.value;
      if (subList.isEmpty) continue;

      final subMeta =
          categories[subCatId] ??
          CategoryMeta(
            id: subCatId,
            name: '子分类 $subCatId',
            parentCatId: parentId,
          );
      var subTotal = BigInt.zero;
      var subDiscount = BigInt.zero;
      for (final b in subList) {
        subTotal += b.netMinor;
        subDiscount += b.discountMinor;
      }

      final int subRatioBp;
      if (parentTotal == BigInt.zero) {
        subRatioBp = 10000; // Denominator 0 fallback to 100.00%
      } else {
        subRatioBp = divideRounded(
          subTotal * BigInt.from(10000),
          parentTotal,
          RoundingMode.halfUp,
        ).toInt();
      }

      subRows.add(
        CategoryRowItem(
          categoryId: subCatId,
          name: subMeta.name,
          icon: subMeta.icon,
          isDirectChild: false,
          isFirstLevel: false,
          parentCatId: parentId,
          moneyMinor: subTotal,
          count: subList.length,
          ratioBasisPoints: subRatioBp,
          discountMinor: subDiscount,
          bills: subList,
        ),
      );
    }

    // Sort subcategories by amount descending
    subRows.sort((a, b) => b.moneyMinor.compareTo(a.moneyMinor));

    // R6: When both direct bills and subcategories exist, insert direct item at index 0.
    if (directBills.isNotEmpty && subRows.isNotEmpty) {
      var directTotal = BigInt.zero;
      var directDiscount = BigInt.zero;
      for (final b in directBills) {
        directTotal += b.netMinor;
        directDiscount += b.discountMinor;
      }
      final int directRatioBp;
      if (parentTotal == BigInt.zero) {
        directRatioBp = 10000;
      } else {
        directRatioBp = divideRounded(
          directTotal * BigInt.from(10000),
          parentTotal,
          RoundingMode.halfUp,
        ).toInt();
      }

      final directItem = CategoryRowItem(
        categoryId: parentId,
        name: '${parentMeta.name}直属',
        icon: parentMeta.icon,
        isDirectChild: true,
        isFirstLevel: false,
        parentCatId: parentId,
        moneyMinor: directTotal,
        count: directBills.length,
        ratioBasisPoints: directRatioBp,
        discountMinor: directDiscount,
        bills: directBills,
      );

      children.add(directItem);
      children.addAll(subRows);
    } else if (subRows.isNotEmpty) {
      children.addAll(subRows);
    }

    firstLevelRows.add(
      CategoryRowItem(
        categoryId: parentId,
        name: parentMeta.name,
        icon: parentMeta.icon,
        isDirectChild: false,
        isFirstLevel: true,
        parentCatId: -1,
        moneyMinor: parentTotal,
        count: parentBills.length,
        ratioBasisPoints: parentRatioBp,
        discountMinor: parentDiscount,
        children: children,
        bills: parentBills,
      ),
    );
  }

  // Sort first level categories by amount descending
  firstLevelRows.sort((a, b) => b.moneyMinor.compareTo(a.moneyMinor));

  // 5. Second-Level Flatten (二级平铺, F01 核准规则).
  // Expand retained first-level rows.
  final flattenCandidates = <CategoryRowItem>[];
  for (final parent in firstLevelRows) {
    if (parent.children.isNotEmpty) {
      flattenCandidates.addAll(parent.children);
    } else {
      flattenCandidates.add(parent);
    }
  }

  final BigInt flattenDenominatorMinor;
  final flattenRows = <CategoryRowItem>[];

  if (flattenCandidates.isEmpty) {
    flattenDenominatorMinor = BigInt.zero;
  } else {
    // F01: flatten denominator = sum of all retained flatten row amounts!
    flattenDenominatorMinor = flattenCandidates.fold(
      BigInt.zero,
      (sum, r) => sum + r.moneyMinor,
    );

    for (final r in flattenCandidates) {
      final int flRatioBp;
      if (flattenDenominatorMinor == BigInt.zero) {
        flRatioBp = 10000; // Fallback to 100.00%
      } else {
        flRatioBp = divideRounded(
          r.moneyMinor * BigInt.from(10000),
          flattenDenominatorMinor,
          RoundingMode.halfUp,
        ).toInt();
      }
      flattenRows.add(r.copyWith(ratioBasisPoints: flRatioBp));
    }
    flattenRows.sort((a, b) => b.moneyMinor.compareTo(a.moneyMinor));
  }

  // 6. Trend buckets with optional Tukey IQR outlier smoothing (R7).
  final trendBuckets = generateTrendBuckets(
    period: period,
    bills: dimensionBills,
    rangeKind: rangeKind,
    smoothing: outlierSmoothing,
  );

  // 7. Period-over-period comparison (fixing ASYM-CAT-04).
  BigInt? lastPeriodTotal;
  int? growthBp;

  if (lastPeriodEntries != null) {
    final lastPeriodBilling = period.previous(period.start.day);
    final lastStats = aggregateCategoryStats(
      entries: lastPeriodEntries,
      categories: categories,
      period: lastPeriodBilling,
      dimension: dimension,
      now: now,
      includeExcludeBudget: includeExcludeBudget,
      rangeKind: rangeKind,
      outlierSmoothing: outlierSmoothing,
      targetCurrency: targetCurrency,
    );
    lastPeriodTotal = lastStats.headerTotalMinor;
    if (lastPeriodTotal > BigInt.zero) {
      growthBp = divideRounded(
        (headerTotalMinor - lastPeriodTotal) * BigInt.from(10000),
        lastPeriodTotal,
        RoundingMode.halfUp,
      ).toInt();
    }
  }

  return CategoryStatsResult(
    dimension: dimension,
    period: period,
    headerTotalMinor: headerTotalMinor,
    headerCount: headerCount,
    dailyAverageMinor: dailyAverageMinor,
    elapsedDays: elapsedDays,
    firstLevelRows: firstLevelRows,
    flattenRows: flattenRows,
    flattenDenominatorMinor: flattenDenominatorMinor,
    uncategorizedRow: uncategorizedRow,
    trendBuckets: trendBuckets,
    lastPeriodTotalMinor: lastPeriodTotal,
    growthBasisPoints: growthBp,
    bills: dimensionBills,
  );
}
