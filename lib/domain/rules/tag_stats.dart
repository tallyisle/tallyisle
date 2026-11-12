import '../../core/money.dart';
import '../model/codes.dart';
import 'category_stats.dart';
import 'income_expense.dart';

/// Statistical bucket for tag rankings and breakdowns.
enum StatBucket {
  expense,
  income;

  StatDimension get toStatDimension =>
      this == StatBucket.expense ? StatDimension.expense : StatDimension.income;

  static StatBucket fromStatDimension(StatDimension dim) =>
      dim == StatDimension.expense ? StatBucket.expense : StatBucket.income;
}

/// Preset tasteful hex color swatches for tags.
const List<String> kTagColorSwatches = <String>[
  '#E53935', // Coral Red
  '#FB8C00', // Vibrant Orange
  '#F9A825', // Warm Amber
  '#43A047', // Forest Green
  '#00897B', // Teal
  '#1E88E5', // Ocean Blue
  '#3949AB', // Indigo
  '#8E24AA', // Iris Purple
  '#D81B60', // Berry Pink
  '#6D4C41', // Cocoa Brown
];

/// Parses a stored tag color string (`#RRGGBB`, `#AARRGGBB`, `0x...`, or
/// signed 32-bit integer string from legacy backups) into a 32-bit ARGB int.
/// Returns `null` when unset, empty, or invalid.
int? parseTagColorArgb(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;

  if (trimmed.startsWith('#')) {
    final hex = trimmed.substring(1);
    if (hex.length == 6) {
      final v = int.tryParse(hex, radix: 16);
      return v == null ? null : (0xFF000000 | v);
    }
    if (hex.length == 8) {
      return int.tryParse(hex, radix: 16);
    }
    return null;
  }

  if (trimmed.startsWith('0x') || trimmed.startsWith('0X')) {
    final hex = trimmed.substring(2);
    final v = int.tryParse(hex, radix: 16);
    if (v == null) return null;
    return hex.length <= 6 ? (0xFF000000 | v) : (v & 0xFFFFFFFF);
  }

  final intVal = int.tryParse(trimmed);
  if (intVal != null) {
    final masked = intVal & 0xFFFFFFFF;
    return (masked & 0xFF000000) == 0 ? (0xFF000000 | masked) : masked;
  }

  if (trimmed.length == 6) {
    final v = int.tryParse(trimmed, radix: 16);
    return v == null ? null : (0xFF000000 | v);
  }
  return null;
}

/// Pure domain metadata of a tag or tag group.
final class TagStatMeta {
  const TagStatMeta({
    required this.tagId,
    required this.name,
    this.parentId,
    this.isGroup = false,
    this.color,
    this.sort = 0,
    this.hidden = false,
  });

  final String tagId;
  final String name;
  final String? parentId;
  final bool isGroup;
  final String? color;
  final int sort;
  final bool hidden;

  /// Normalized parent tag ID (`null` when root/standalone, i.e. `null`, `''`, or `'-1'`).
  String? get normalizedParentId {
    final p = parentId?.trim();
    if (p == null || p.isEmpty || p == '-1') return null;
    return p;
  }

  bool get isRoot => normalizedParentId == null;
}

/// Ranked statistics row for a single tag or rolled-up tag group.
final class TagRankingItem {
  const TagRankingItem({
    required this.tagId,
    required this.name,
    this.parentId,
    this.parentName,
    this.isGroup = false,
    this.color,
    required this.moneyMinor,
    required this.count,
    required this.ratioBasisPoints,
    this.sort = 0,
  });

  final String tagId;
  final String name;
  final String? parentId;
  final String? parentName;
  final bool isGroup;
  final String? color;
  final BigInt moneyMinor;
  final int count;

  /// Share in integer basis points (`10000 == 100.00%`).
  final int ratioBasisPoints;
  final int sort;

  String get ratioText => formatBasisPoints(ratioBasisPoints);
}

/// Complete ranked tag statistics result for a given [StatBucket].
final class TagRankingsResult {
  const TagRankingsResult({
    required this.bucket,
    required this.rollupGroups,
    required this.totalMinor,
    required this.totalBillCount,
    required this.items,
  });

  final StatBucket bucket;
  final bool rollupGroups;

  /// Total distinct tagged amount in minor units (deduplicated by `recordId`).
  final BigInt totalMinor;

  /// Total distinct tagged bill count in this bucket.
  final int totalBillCount;

  /// Ranked tag items sorted descending by [TagRankingItem.moneyMinor], then [TagRankingItem.count].
  final List<TagRankingItem> items;
}

/// Category breakdown row within a single tag's detail statistics.
final class TagCategoryBreakdownItem {
  const TagCategoryBreakdownItem({
    required this.categoryId,
    required this.name,
    this.icon = '',
    required this.moneyMinor,
    required this.count,
    required this.ratioBasisPoints,
    this.sort = 0,
  });

  final int categoryId;
  final String name;
  final String icon;
  final BigInt moneyMinor;
  final int count;
  final int ratioBasisPoints;
  final int sort;

  String get ratioText => formatBasisPoints(ratioBasisPoints);
}

/// Child-tag contribution row when viewing a parent tag group's detail statistics.
final class TagChildBreakdownItem {
  const TagChildBreakdownItem({
    required this.tagId,
    required this.name,
    this.color,
    this.isDirectOnGroup = false,
    required this.expenseMinor,
    required this.incomeMinor,
    required this.billCount,
    required this.expenseCount,
    required this.incomeCount,
    required this.expenseRatioBasisPoints,
    required this.incomeRatioBasisPoints,
    this.sort = 0,
  });

  final String tagId;
  final String name;
  final String? color;

  /// True when representing bills tagged directly with the parent group itself.
  final bool isDirectOnGroup;
  final BigInt expenseMinor;
  final BigInt incomeMinor;
  final int billCount;
  final int expenseCount;
  final int incomeCount;
  final int expenseRatioBasisPoints;
  final int incomeRatioBasisPoints;
  final int sort;

  String get expenseRatioText => formatBasisPoints(expenseRatioBasisPoints);
  String get incomeRatioText => formatBasisPoints(incomeRatioBasisPoints);
}

/// Complete detail statistics for a single tag or parent tag group.
final class SingleTagStatsResult {
  const SingleTagStatsResult({
    required this.tag,
    this.parentTag,
    required this.isGroup,
    required this.childTags,
    required this.totalExpense,
    required this.totalIncome,
    required this.netBalance,
    required this.billCount,
    required this.expenseBillCount,
    required this.incomeBillCount,
    required this.matchingRecordIds,
    required this.expenseCategories,
    required this.incomeCategories,
    required this.childBreakdowns,
  });

  final TagStatMeta tag;
  final TagStatMeta? parentTag;
  final bool isGroup;
  final List<TagStatMeta> childTags;

  final BigInt totalExpense;
  final BigInt totalIncome;
  final BigInt netBalance;

  /// Total distinct matching non-type-15 bills (deduplicated by `recordId`).
  final int billCount;
  final int expenseBillCount;
  final int incomeBillCount;

  /// Ordered matching `recordId`s (newest first, deduplicated).
  final List<String> matchingRecordIds;

  /// Category breakdown for expenses.
  final List<TagCategoryBreakdownItem> expenseCategories;

  /// Category breakdown for income.
  final List<TagCategoryBreakdownItem> incomeCategories;

  /// Child-tag breakdown when [isGroup] is true.
  final List<TagChildBreakdownItem> childBreakdowns;
}

int _computeBasisPoints(BigInt partMinor, BigInt totalMinor) {
  if (partMinor <= BigInt.zero) return 0;
  if (totalMinor <= BigInt.zero) return 10000;
  final bp = divideRounded(
    partMinor * BigInt.from(10000),
    totalMinor,
    RoundingMode.halfUp,
  ).toInt();
  if (bp < 0) return 0;
  if (bp > 10000) return 10000;
  return bp;
}

StatEntry _toStatEntry(CategoryStatEntry e) => StatEntry(
  type: e.type,
  subType: e.subType,
  moneyMinor: e.moneyMinor,
  discountMinor: e.discountMinor,
  currency: e.currency,
  relations: e.relations,
  excludeExIn: e.excludeExIn,
  excludeBudget: e.excludeBudget,
);

/// Computes distinct non-type-15 bill counts per `tagId`, plus aggregated
/// distinct bill counts across `{group.tagId, ...childTagIds}` for parent tag groups.
Map<String, int> computeTagRecordCounts({
  required Map<String, List<String>> recordTagIds,
  required List<TagStatMeta> tags,
  Set<String>? validRecordIds,
}) {
  final directRecordsByTag = <String, Set<String>>{};
  for (final entry in recordTagIds.entries) {
    final recordId = entry.key;
    if (validRecordIds != null && !validRecordIds.contains(recordId)) continue;
    for (final rawTagId in entry.value) {
      if (rawTagId.isEmpty) continue;
      directRecordsByTag.putIfAbsent(rawTagId, () => <String>{}).add(recordId);
    }
  }

  final childrenByParent = <String, List<TagStatMeta>>{};
  for (final t in tags) {
    final p = t.normalizedParentId;
    if (p != null) {
      childrenByParent.putIfAbsent(p, () => <TagStatMeta>[]).add(t);
    }
  }

  final counts = <String, int>{};
  for (final t in tags) {
    final children = childrenByParent[t.tagId];
    final isGroup =
        t.isRoot && (t.isGroup || (children != null && children.isNotEmpty));
    if (isGroup) {
      final merged = <String>{...?directRecordsByTag[t.tagId]};
      if (children != null) {
        for (final c in children) {
          final childSet = directRecordsByTag[c.tagId];
          if (childSet != null) merged.addAll(childSet);
        }
      }
      counts[t.tagId] = merged.length;
    } else {
      counts[t.tagId] = directRecordsByTag[t.tagId]?.length ?? 0;
    }
  }
  return counts;
}

/// Computes ranked tag statistics for [bucket] (`StatBucket.expense` or `StatBucket.income`).
///
/// - Uses [processCategoryEntry] so foreign currency snapshots (`amountIn`),
///   refund offsets, reimbursable net rules, `excludeExIn`, and `RecordType.reimburseReceipt` (15)
///   exclusion stay 100% consistent with `category_stats.dart` and `income_expense.dart`.
/// - When [rollupGroups] is `false` (default), ranks individual leaf/standalone tags
///   (plus any group tag that was directly attached to bills).
/// - When [rollupGroups] is `true`, rolls up child tags into their parent tag group,
///   deduplicating by `recordId` so a bill carrying two child tags of the same group
///   is NEVER double-counted.
TagRankingsResult computeTagRankings({
  required List<CategoryStatEntry> entries,
  required Map<String, List<String>> recordTagIds,
  required List<TagStatMeta> tags,
  required StatBucket bucket,
  bool rollupGroups = false,
  bool includeExcludeBudget = true,
  String targetCurrency = 'CNY',
}) {
  final targetDim = bucket.toStatDimension;
  final tagMap = <String, TagStatMeta>{for (final t in tags) t.tagId: t};
  final childrenByParent = <String, List<TagStatMeta>>{};
  for (final t in tags) {
    final p = t.normalizedParentId;
    if (p != null) {
      childrenByParent.putIfAbsent(p, () => <TagStatMeta>[]).add(t);
    }
  }

  // Deduplicate input entries by recordId first.
  final seenRecordIds = <String>{};
  final bucketBills = <CategoryBill>[];
  for (final e in entries) {
    if (e.type == RecordType.reimburseReceipt) continue;
    if (!seenRecordIds.add(e.recordId)) continue;
    final bill = processCategoryEntry(
      e,
      includeExcludeBudget: includeExcludeBudget,
      targetCurrency: targetCurrency,
    );
    if (bill != null && bill.dimension == targetDim) {
      bucketBills.add(bill);
    }
  }

  var totalDistinctTaggedMinor = BigInt.zero;
  var totalDistinctTaggedCount = 0;

  // Map target bucket key (tagId) -> (moneyMinor, count, seenRecordIds)
  final amountByTargetTag = <String, BigInt>{};
  final countByTargetTag = <String, int>{};
  final seenRecordsByTargetTag = <String, Set<String>>{};

  for (final bill in bucketBills) {
    final attachedList = recordTagIds[bill.recordId];
    if (attachedList == null || attachedList.isEmpty) continue;

    final validTagIds = <String>{};
    for (final rawId in attachedList) {
      if (rawId.isNotEmpty && tagMap.containsKey(rawId)) {
        validTagIds.add(rawId);
      }
    }
    if (validTagIds.isEmpty) continue;

    totalDistinctTaggedMinor += bill.netMinor;
    totalDistinctTaggedCount++;

    for (final tid in validTagIds) {
      final meta = tagMap[tid]!;
      final parentId = meta.normalizedParentId;
      final String targetKey;
      if (rollupGroups && parentId != null && tagMap.containsKey(parentId)) {
        targetKey = parentId;
      } else {
        targetKey = tid;
      }

      final seenForTag = seenRecordsByTargetTag.putIfAbsent(
        targetKey,
        () => <String>{},
      );
      if (seenForTag.add(bill.recordId)) {
        amountByTargetTag[targetKey] =
            (amountByTargetTag[targetKey] ?? BigInt.zero) + bill.netMinor;
        countByTargetTag[targetKey] = (countByTargetTag[targetKey] ?? 0) + 1;
      }
    }
  }

  final items = <TagRankingItem>[];
  for (final entry in countByTargetTag.entries) {
    final tid = entry.key;
    final count = entry.value;
    if (count <= 0) continue;
    final moneyMinor = amountByTargetTag[tid] ?? BigInt.zero;
    final meta = tagMap[tid]!;
    final parentId = meta.normalizedParentId;
    final parentMeta = parentId != null ? tagMap[parentId] : null;
    final isGroup =
        meta.isRoot &&
        (meta.isGroup || (childrenByParent[tid]?.isNotEmpty ?? false));

    items.add(
      TagRankingItem(
        tagId: tid,
        name: meta.name,
        parentId: parentId,
        parentName: parentMeta?.name,
        isGroup: isGroup,
        color: meta.color,
        moneyMinor: moneyMinor,
        count: count,
        ratioBasisPoints: _computeBasisPoints(
          moneyMinor,
          totalDistinctTaggedMinor,
        ),
        sort: meta.sort,
      ),
    );
  }

  items.sort((a, b) {
    final cmpMoney = b.moneyMinor.compareTo(a.moneyMinor);
    if (cmpMoney != 0) return cmpMoney;
    final cmpCount = b.count.compareTo(a.count);
    if (cmpCount != 0) return cmpCount;
    final cmpSort = a.sort.compareTo(b.sort);
    if (cmpSort != 0) return cmpSort;
    return a.tagId.compareTo(b.tagId);
  });

  return TagRankingsResult(
    bucket: bucket,
    rollupGroups: rollupGroups,
    totalMinor: totalDistinctTaggedMinor,
    totalBillCount: totalDistinctTaggedCount,
    items: items,
  );
}

List<TagCategoryBreakdownItem> _buildCategoryBreakdown({
  required List<CategoryBill> bills,
  required Map<int, CategoryMeta> categories,
  required BigInt bucketTotalMinor,
}) {
  if (bills.isEmpty) return const <TagCategoryBreakdownItem>[];

  final amountByCat = <int, BigInt>{};
  final countByCat = <int, int>{};

  for (final b in bills) {
    final cat = categories[b.recordCatId];
    final int groupCatId;
    if (cat == null || b.recordCatId == -1) {
      groupCatId = -1;
    } else if (cat.isParent) {
      groupCatId = cat.id;
    } else {
      final parent = categories[cat.parentCatId];
      groupCatId = parent != null ? parent.id : cat.id;
    }
    amountByCat[groupCatId] =
        (amountByCat[groupCatId] ?? BigInt.zero) + b.netMinor;
    countByCat[groupCatId] = (countByCat[groupCatId] ?? 0) + 1;
  }

  final rows = <TagCategoryBreakdownItem>[];
  for (final entry in countByCat.entries) {
    final catId = entry.key;
    final count = entry.value;
    final money = amountByCat[catId] ?? BigInt.zero;
    final catMeta = catId == -1 ? null : categories[catId];
    rows.add(
      TagCategoryBreakdownItem(
        categoryId: catId,
        name: catMeta?.name ?? '未分类',
        icon: catMeta?.icon ?? '',
        moneyMinor: money,
        count: count,
        ratioBasisPoints: _computeBasisPoints(money, bucketTotalMinor),
        sort: catMeta?.sort ?? 999999,
      ),
    );
  }

  rows.sort((a, b) {
    final cmpMoney = b.moneyMinor.compareTo(a.moneyMinor);
    if (cmpMoney != 0) return cmpMoney;
    final cmpCount = b.count.compareTo(a.count);
    if (cmpCount != 0) return cmpCount;
    final cmpSort = a.sort.compareTo(b.sort);
    if (cmpSort != 0) return cmpSort;
    return a.categoryId.compareTo(b.categoryId);
  });

  return rows;
}

/// Computes comprehensive detail statistics for a single tag or parent tag group.
///
/// - When [targetTagId] is a parent tag group (`parentId == '-1'` / `null` and
///   `isGroup == true` or has child tags), includes all bills tagged with either
///   the group itself OR any of its child tags, **strictly deduplicated by `recordId`**
///   so a bill carrying multiple child tags of the same group is NEVER double-counted.
/// - Computes `totalExpense`, `totalIncome`, `netBalance` (`income - expense`),
///   matching bill count, expense/income category breakdowns, and child-tag breakdowns.
SingleTagStatsResult computeSingleTagStats({
  required String targetTagId,
  required List<CategoryStatEntry> entries,
  required Map<String, List<String>> recordTagIds,
  required List<TagStatMeta> tags,
  required Map<int, CategoryMeta> categories,
  bool includeExcludeBudget = true,
  String targetCurrency = 'CNY',
}) {
  final tagMap = <String, TagStatMeta>{for (final t in tags) t.tagId: t};
  final targetTag =
      tagMap[targetTagId] ?? TagStatMeta(tagId: targetTagId, name: '未知标签');

  final parentId = targetTag.normalizedParentId;
  final parentTag = parentId != null ? tagMap[parentId] : null;

  final childTags =
      <TagStatMeta>[
        for (final t in tags)
          if (t.normalizedParentId == targetTagId) t,
      ]..sort((a, b) {
        final c = a.sort.compareTo(b.sort);
        return c != 0 ? c : a.name.compareTo(b.name);
      });

  final isGroup =
      targetTag.isRoot && (targetTag.isGroup || childTags.isNotEmpty);

  final effectiveTagIds = <String>{
    targetTagId,
    if (isGroup) ...childTags.map((c) => c.tagId),
  };

  // Deduplicate matching entries by recordId, excluding internal type 15.
  final seenRecordIds = <String>{};
  final matchingEntries = <CategoryStatEntry>[];
  final sanitizedRecordTags = <String, Set<String>>{};

  for (final e in entries) {
    if (e.type == RecordType.reimburseReceipt) continue;
    final attached = recordTagIds[e.recordId];
    if (attached == null || attached.isEmpty) continue;
    final tagSet = attached.where((id) => id.isNotEmpty).toSet();
    if (!tagSet.any(effectiveTagIds.contains)) continue;
    if (!seenRecordIds.add(e.recordId)) continue;
    sanitizedRecordTags[e.recordId] = tagSet;
    matchingEntries.add(e);
  }

  matchingEntries.sort((a, b) {
    final cmpTime = b.recordTime.compareTo(a.recordTime);
    if (cmpTime != 0) return cmpTime;
    final cmpCreate = (b.createDate ?? 0).compareTo(a.createDate ?? 0);
    if (cmpCreate != 0) return cmpCreate;
    return b.recordId.compareTo(a.recordId);
  });

  final summary = aggregateIncomeExpense(
    matchingEntries.map(_toStatEntry),
    target: targetCurrency,
    scope: StatScope(
      includeBalanceAdjust: false,
      honourExcludeExIn: true,
      honourExcludeBudget: !includeExcludeBudget,
    ),
  );

  final expenseBills = <CategoryBill>[];
  final incomeBills = <CategoryBill>[];
  final billByRecordId = <String, CategoryBill>{};

  for (final e in matchingEntries) {
    final bill = processCategoryEntry(
      e,
      includeExcludeBudget: includeExcludeBudget,
      targetCurrency: targetCurrency,
    );
    if (bill == null) continue;
    billByRecordId[e.recordId] = bill;
    if (bill.dimension == StatDimension.expense) {
      expenseBills.add(bill);
    } else {
      incomeBills.add(bill);
    }
  }

  final expenseCategories = _buildCategoryBreakdown(
    bills: expenseBills,
    categories: categories,
    bucketTotalMinor: summary.expense,
  );
  final incomeCategories = _buildCategoryBreakdown(
    bills: incomeBills,
    categories: categories,
    bucketTotalMinor: summary.income,
  );

  // Child-tag breakdown when viewing a parent tag group.
  final childBreakdowns = <TagChildBreakdownItem>[];
  if (isGroup && childTags.isNotEmpty) {
    for (final child in childTags) {
      var expMinor = BigInt.zero;
      var incMinor = BigInt.zero;
      var totalCount = 0;
      var expCount = 0;
      var incCount = 0;

      for (final e in matchingEntries) {
        final tagSet = sanitizedRecordTags[e.recordId]!;
        if (!tagSet.contains(child.tagId)) continue;
        totalCount++;
        final bill = billByRecordId[e.recordId];
        if (bill != null) {
          if (bill.dimension == StatDimension.expense) {
            expMinor += bill.netMinor;
            expCount++;
          } else {
            incMinor += bill.netMinor;
            incCount++;
          }
        }
      }

      childBreakdowns.add(
        TagChildBreakdownItem(
          tagId: child.tagId,
          name: child.name,
          color: child.color,
          expenseMinor: expMinor,
          incomeMinor: incMinor,
          billCount: totalCount,
          expenseCount: expCount,
          incomeCount: incCount,
          expenseRatioBasisPoints: _computeBasisPoints(
            expMinor,
            summary.expense,
          ),
          incomeRatioBasisPoints: _computeBasisPoints(incMinor, summary.income),
          sort: child.sort,
        ),
      );
    }

    // Also capture bills tagged directly with the parent group itself (if any).
    var directExp = BigInt.zero;
    var directInc = BigInt.zero;
    var directTotalCount = 0;
    var directExpCount = 0;
    var directIncCount = 0;
    for (final e in matchingEntries) {
      final tagSet = sanitizedRecordTags[e.recordId]!;
      if (!tagSet.contains(targetTagId)) continue;
      directTotalCount++;
      final bill = billByRecordId[e.recordId];
      if (bill != null) {
        if (bill.dimension == StatDimension.expense) {
          directExp += bill.netMinor;
          directExpCount++;
        } else {
          directInc += bill.netMinor;
          directIncCount++;
        }
      }
    }
    if (directTotalCount > 0) {
      childBreakdowns.add(
        TagChildBreakdownItem(
          tagId: targetTagId,
          name: '${targetTag.name}（直属）',
          color: targetTag.color,
          isDirectOnGroup: true,
          expenseMinor: directExp,
          incomeMinor: directInc,
          billCount: directTotalCount,
          expenseCount: directExpCount,
          incomeCount: directIncCount,
          expenseRatioBasisPoints: _computeBasisPoints(
            directExp,
            summary.expense,
          ),
          incomeRatioBasisPoints: _computeBasisPoints(
            directInc,
            summary.income,
          ),
          sort: -1,
        ),
      );
    }

    childBreakdowns.sort((a, b) {
      final aTotal = a.expenseMinor + a.incomeMinor;
      final bTotal = b.expenseMinor + b.incomeMinor;
      final cmpTotal = bTotal.compareTo(aTotal);
      if (cmpTotal != 0) return cmpTotal;
      final cmpCount = b.billCount.compareTo(a.billCount);
      if (cmpCount != 0) return cmpCount;
      return a.sort.compareTo(b.sort);
    });
  }

  return SingleTagStatsResult(
    tag: targetTag,
    parentTag: parentTag,
    isGroup: isGroup,
    childTags: childTags,
    totalExpense: summary.expense,
    totalIncome: summary.income,
    netBalance: summary.balance,
    billCount: matchingEntries.length,
    expenseBillCount: summary.expenseCount,
    incomeBillCount: summary.incomeCount,
    matchingRecordIds: matchingEntries.map((e) => e.recordId).toList(),
    expenseCategories: expenseCategories,
    incomeCategories: incomeCategories,
    childBreakdowns: childBreakdowns,
  );
}
