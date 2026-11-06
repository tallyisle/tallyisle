import '../ledger/record_extra.dart';
import '../ledger/record_relations.dart';
import '../model/codes.dart';

/// Record data needed by income/expense statistics.
final class StatEntry {
  const StatEntry({
    required this.type,
    this.subType = RecordDirection.none,
    required this.moneyMinor,
    this.discountMinor,
    this.currency,
    this.relations,
    this.excludeExIn = false,
    this.excludeBudget = false,
  });
  final int type;
  final int subType;
  final BigInt moneyMinor;
  final BigInt? discountMinor;
  final CurrencySnapshot? currency;
  final RecordRelations? relations;
  final bool excludeExIn;
  final bool excludeBudget;
}

final class IncomeExpense {
  const IncomeExpense({
    required this.income,
    required this.expense,
    required this.incomeCount,
    required this.expenseCount,
  });
  final BigInt income;
  final BigInt expense;
  final int incomeCount;
  final int expenseCount;
  BigInt get balance => income - expense;

  static final zero = IncomeExpense(
    income: BigInt.zero,
    expense: BigInt.zero,
    incomeCount: 0,
    expenseCount: 0,
  );
}

/// Amount of [e] expressed in [target] currency (ledger-catalog §2 "金额来源").
BigInt amountIn(StatEntry e, String target) {
  final c = e.currency;
  if (c == null || !c.isValid) return e.moneyMinor;
  if (c.sourceCode == target) {
    return c.sourceGross - (e.discountMinor ?? BigInt.zero);
  }
  if (c.assetCode == target && c.assetNet != null) return c.assetNet!;
  if (c.baseCode == target && c.baseAmount != null) return c.baseAmount!;
  return e.moneyMinor;
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

/// Which records a page includes before aggregation.
final class StatScope {
  const StatScope({
    this.includeBalanceAdjust = false,
    this.honourExcludeExIn = true,
    this.honourExcludeBudget = false,
  });

  /// Home: the "show balance changes" switch (type 4). Type 15 never counts.
  final bool includeBalanceAdjust;
  final bool honourExcludeExIn;
  final bool honourExcludeBudget;

  static const home = StatScope();
  static const budget = StatScope(
    honourExcludeExIn: false,
    honourExcludeBudget: true,
  );
}

/// Common income/expense aggregator used by home, calendar, category and
/// budget pages (original `NwwVVNMNNWN`; docs/modules/home-and-period.md).
///
/// Differences from the original (P-02, recorded in the module doc):
///  * transfers (type 2) never count, whatever their sub_type;
///  * amounts are exact minor units, so no double accumulation drift.
IncomeExpense aggregateIncomeExpense(
  Iterable<StatEntry> entries, {
  String target = 'CNY',
  StatScope scope = StatScope.home,
}) {
  var income = BigInt.zero, expense = BigInt.zero;
  var incomeCount = 0, expenseCount = 0;

  for (final e in entries) {
    if (e.type == RecordType.reimburseReceipt) continue;
    if (e.type == RecordType.balanceAdjust && !scope.includeBalanceAdjust) {
      continue;
    }
    if (scope.honourExcludeExIn && e.excludeExIn) continue;
    if (scope.honourExcludeBudget && e.excludeBudget) continue;
    if (e.type == RecordType.transfer) continue;

    final raw = amountIn(e, target);
    switch (e.type) {
      case RecordType.expense:
      case RecordType.income:
        final isExpense = e.type == RecordType.expense;
        if (raw.isNegative) {
          final refundChild = (e.relations?.refunds?.originId ?? '')
              .trim()
              .isNotEmpty;
          if (refundChild) break; // the original bill nets it
          if (isExpense) {
            expense += raw;
            expenseCount++;
          } else {
            income += raw;
            incomeCount++;
          }
          break;
        }
        final net = raw - _linkedTotal(e.relations?.refunds, target);
        if (isExpense) {
          expenseCount++;
          if (net.isNegative) {
            income += -net;
          } else {
            expense += net;
          }
        } else {
          incomeCount++;
          if (net.isNegative) {
            expense += -net;
          } else {
            income += net;
          }
        }
      case RecordType.fee:
        if (!raw.isNegative) {
          expense += raw;
          expenseCount++;
        }
      case RecordType.reimbursable:
        final links = e.relations?.reimbursements;
        if (links == null || links.children.isEmpty) break;
        final net = raw - _linkedTotal(e.relations?.refunds, target);
        final reimbursed = _linkedTotal(links, target);
        if (reimbursed < net) {
          expense += net - reimbursed;
          expenseCount++;
        } else if (reimbursed > net) {
          income += reimbursed - net;
          incomeCount++;
        }
      default:
        if (e.subType == RecordDirection.expense) {
          expense += raw.abs();
          expenseCount++;
        } else if (e.subType == RecordDirection.income) {
          income += raw.abs();
          incomeCount++;
        }
    }
  }
  return IncomeExpense(
    income: income,
    expense: expense,
    incomeCount: incomeCount,
    expenseCount: expenseCount,
  );
}
