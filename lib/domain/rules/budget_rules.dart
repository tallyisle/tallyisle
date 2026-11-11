import 'dart:convert';

import '../model/codes.dart';
import 'billing_period.dart';
import 'income_expense.dart';

/// Budget cycle mode (docs/modules/budget.md R1).
enum BudgetMode {
  monthly(0),
  yearly(1);

  const BudgetMode(this.value);
  final int value;

  static BudgetMode fromInt(int? val) =>
      val == 1 ? BudgetMode.yearly : BudgetMode.monthly;

  String sectionFor(BillingPeriod period) =>
      this == BudgetMode.yearly ? period.yearlySection : period.monthlySection;
}

/// Budget type codes mirroring original Room schema (budget.md §2).
abstract final class BudgetTypeCode {
  /// 0: Total budget for the period (book-wide).
  static const total = 0;

  /// 1: Expense category budget.
  static const expenseCategory = 1;

  /// 2: Saving / income category budget.
  static const savingCategory = 2;

  /// 3: Special budget (project / trip).
  static const special = 3;
}

/// Extra JSON info stored on `budget.extra_info` (docs/modules/budget.md §2, R6).
final class BudgetExtra {
  const BudgetExtra({
    this.autoCopy = false,
    this.forward = false,
    required this.baseMinor,
  });

  /// Automatically copy this budget to the next period (`acopy`).
  final bool autoCopy;

  /// Carry over remaining balance from previous period (`forward`).
  final bool forward;

  /// Base budget amount in minor units (`base`).
  final BigInt baseMinor;

  factory BudgetExtra.fromJson(String? raw, {BigInt? fallbackAmountMinor}) {
    final fallback = fallbackAmountMinor ?? BigInt.zero;
    if (raw == null || raw.trim().isEmpty) {
      return BudgetExtra(autoCopy: false, forward: false, baseMinor: fallback);
    }
    try {
      final map = jsonDecode(raw);
      if (map is! Map) {
        return BudgetExtra(
          autoCopy: false,
          forward: false,
          baseMinor: fallback,
        );
      }
      final acopyVal = map['acopy'];
      final autoCopy = acopyVal == true || acopyVal == 1 || acopyVal == 'true';
      final forwardVal = map['forward'];
      final forward =
          forwardVal == true || forwardVal == 1 || forwardVal == 'true';
      final baseVal = map['base'];
      BigInt baseMinor = fallback;
      if (baseVal is String && baseVal.isNotEmpty) {
        baseMinor = BigInt.tryParse(baseVal) ?? fallback;
      } else if (baseVal is num) {
        baseMinor = BigInt.from(baseVal);
      }
      return BudgetExtra(
        autoCopy: autoCopy,
        forward: forward,
        baseMinor: baseMinor,
      );
    } catch (_) {
      return BudgetExtra(autoCopy: false, forward: false, baseMinor: fallback);
    }
  }

  String toJsonString() => jsonEncode({
    'acopy': autoCopy,
    'forward': forward,
    'base': baseMinor.toString(),
  });
}

/// Category metadata needed for budget evaluation (R4).
final class BudgetCategoryNode {
  const BudgetCategoryNode({
    required this.id,
    required this.name,
    this.icon = '',
    required this.type,
    this.parentCatId = -1,
  });

  final int id;
  final String name;
  final String icon;

  /// 0 expense, 1 income.
  final int type;

  /// -1 for top-level / primary category.
  final int parentCatId;

  bool get isPrimary => parentCatId == -1;
}

/// Record input for budget calculations.
final class BudgetRecordInput {
  const BudgetRecordInput({
    required this.recordId,
    required this.recordCatId,
    required this.entry,
  });

  final String recordId;
  final int recordCatId;
  final StatEntry entry;
}

/// Computed budget usage and UI display properties (R4, R6).
final class BudgetUsage {
  const BudgetUsage({
    this.budgetId,
    required this.budgetType,
    required this.categoryId,
    required this.amountMinor,
    required this.rawUsedMinor,
    required this.billCount,
    required this.matchedRecordIds,
  });

  final int? budgetId;
  final int budgetType;
  final int categoryId;
  final BigInt amountMinor;

  /// Untruncated real used value (can be negative due to refunds/standalone credits).
  final BigInt rawUsedMinor;

  /// Number of bills counting towards this budget.
  final int billCount;

  /// Identifiers of records contributing to this budget or displayed in drilldown.
  final List<String> matchedRecordIds;

  /// R6 UI clamped used amount (0.0 if negative).
  BigInt get displayUsedMinor =>
      rawUsedMinor.isNegative ? BigInt.zero : rawUsedMinor;

  /// Remaining amount (negative when overspent; for saving budget, represents remaining to save).
  BigInt get remainingMinor => amountMinor - displayUsedMinor;

  /// Whether this budget has been exceeded.
  bool get isOverspent => displayUsedMinor > amountMinor;

  /// Percentage (0..100+). Returns 0.0 if amountMinor <= 0 and used <= 0.
  double get percent {
    if (amountMinor <= BigInt.zero) {
      return displayUsedMinor > BigInt.zero ? 100.0 : 0.0;
    }
    return (displayUsedMinor.toDouble() / amountMinor.toDouble()) * 100.0;
  }
}

/// Computes book-wide total budget usage for the period (R2, R3, R5).
BudgetUsage computeTotalBudgetUsage({
  required BigInt amountMinor,
  int? budgetId,
  required Iterable<BudgetRecordInput> records,
  String target = 'CNY',
}) {
  final matched = <String>[];
  var rawUsedMinor = BigInt.zero;
  var billCount = 0;

  for (final r in records) {
    final single = aggregateIncomeExpense(
      [r.entry],
      target: target,
      scope: StatScope.budget,
    );
    if (single.expense != BigInt.zero) {
      matched.add(r.recordId);
      rawUsedMinor += single.expense;
      billCount += single.expenseCount;
    } else if (r.entry.type == RecordType.expense &&
        r.entry.moneyMinor > BigInt.zero &&
        single.income == BigInt.zero &&
        single.expenseCount > 0) {
      // Full refund: net expense is 0.00 but counts as 1 bill (docs/modules/budget.md R5)
      matched.add(r.recordId);
      billCount += 1;
    }
  }

  return BudgetUsage(
    budgetId: budgetId,
    budgetType: BudgetTypeCode.total,
    categoryId: -1,
    amountMinor: amountMinor,
    rawUsedMinor: rawUsedMinor,
    billCount: billCount,
    matchedRecordIds: matched,
  );
}

/// Computes category budget usage (R4).
///
/// For primary categories (parentCatId == -1), aggregates its own records plus
/// all active non-deleted subcategories present in [allCategories].
/// For subcategories (parentCatId != -1), aggregates only its own records.
/// Parent and child budgets compute independently.
BudgetUsage computeCategoryBudgetUsage({
  required BudgetCategoryNode category,
  required Iterable<BudgetCategoryNode> allCategories,
  required BigInt amountMinor,
  int? budgetId,
  required int budgetType,
  required Iterable<BudgetRecordInput> records,
  String target = 'CNY',
}) {
  final Set<int> targetCatIds;
  if (category.parentCatId == -1) {
    targetCatIds = {
      category.id,
      for (final c in allCategories)
        if (c.parentCatId == category.id) c.id,
    };
  } else {
    targetCatIds = {category.id};
  }

  final matched = <String>[];
  var rawUsedMinor = BigInt.zero;
  var billCount = 0;

  final isExpense = budgetType == BudgetTypeCode.expenseCategory;

  for (final r in records) {
    if (!targetCatIds.contains(r.recordCatId)) continue;
    final single = aggregateIncomeExpense(
      [r.entry],
      target: target,
      scope: StatScope.budget,
    );
    if (isExpense) {
      if (single.expense != BigInt.zero) {
        matched.add(r.recordId);
        rawUsedMinor += single.expense;
        billCount += single.expenseCount;
      } else if (r.entry.type == RecordType.expense &&
          r.entry.moneyMinor > BigInt.zero &&
          single.income == BigInt.zero &&
          single.expenseCount > 0) {
        // Full refund: 0.00 minor, 1 bill
        matched.add(r.recordId);
        billCount += 1;
      }
    } else {
      if (single.income != BigInt.zero) {
        matched.add(r.recordId);
        rawUsedMinor += single.income;
        billCount += single.incomeCount;
      } else if (r.entry.type == RecordType.income &&
          r.entry.moneyMinor > BigInt.zero &&
          single.expense == BigInt.zero &&
          single.incomeCount > 0) {
        matched.add(r.recordId);
        billCount += 1;
      }
    }
  }

  return BudgetUsage(
    budgetId: budgetId,
    budgetType: budgetType,
    categoryId: category.id,
    amountMinor: amountMinor,
    rawUsedMinor: rawUsedMinor,
    billCount: billCount,
    matchedRecordIds: matched,
  );
}

/// Next period carryover calculation (R6).
///
/// If [forward] is false, returns [baseAmountMinor].
/// If [forward] is true, uses untruncated [rawPrevUsedMinor]:
///   nextMoney = baseAmountMinor + (prevAmountMinor - rawPrevUsedMinor)
/// If nextMoney <= 0, retains [prevAmountMinor].
BigInt computeNextPeriodCarryover({
  required BigInt baseAmountMinor,
  required BigInt prevAmountMinor,
  required BigInt rawPrevUsedMinor,
  required bool forward,
}) {
  if (!forward) return baseAmountMinor;
  final diff = prevAmountMinor - rawPrevUsedMinor;
  final nextMoney = baseAmountMinor + diff;
  if (nextMoney <= BigInt.zero) {
    return prevAmountMinor;
  }
  return nextMoney;
}

/// R7: Upscales total budget based on expense category budgets.
///
/// Only sums `budget_type == 1` expense category budgets (excluding saving budgets).
/// If `sum > (currentTotalMinor ?? 0)`, returns `sum`. Otherwise returns `currentTotalMinor`.
BigInt? upscaledTotalBudget({
  required Iterable<BigInt> expenseCategoryBudgets,
  BigInt? currentTotalMinor,
}) {
  final sum = expenseCategoryBudgets.fold(BigInt.zero, (acc, val) => acc + val);
  final current = currentTotalMinor ?? BigInt.zero;
  if (sum > current) {
    return sum;
  }
  return currentTotalMinor;
}

/// Resolves real-time budget hint during bill entry using 3-level fallback:
/// 1. Direct category budget
/// 2. Parent primary category budget (if current is a subcategory)
/// 3. Total budget for the period
/// 4. null
BudgetUsage? resolveRecordBudgetHint({
  required int selectedCatId,
  required Map<int, BudgetCategoryNode> categoryMap,
  required Map<int, BudgetUsage> categoryBudgets,
  BudgetUsage? totalBudget,
}) {
  final direct = categoryBudgets[selectedCatId];
  if (direct != null) return direct;

  final node = categoryMap[selectedCatId];
  if (node != null && node.parentCatId != -1) {
    final parentBudget = categoryBudgets[node.parentCatId];
    if (parentBudget != null) return parentBudget;
  }

  return totalBudget;
}
