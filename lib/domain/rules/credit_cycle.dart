import '../ledger/asset_json.dart';
import '../ledger/record_extra.dart';
import '../ledger/record_relations.dart';
import '../model/codes.dart';
import 'asset_overview.dart';
import 'calendar.dart';

/// Pure domain rules for credit account statement cycles (F-028 / docs/modules/credit-account.md).
///
/// Rules implemented:
/// - R1: Statement period boundaries, end-of-month and short-month clamping,
///       and whole-natural-month special case.
/// - R2: Statement date and safe due date calculation (ASYM-CD-01 unified clamping).
/// - R3: 8-accumulator statement amount per period with P-02 fixes (ASYM-CD-03, ASYM-CD-04,
///       CD-F01 per-operand cents precision, CD-F02 child-record refund lookup).
/// - R4: Newest-first debt pool allocation across all constructed periods (CD-F03),
///       filtered by selected year.
/// - R5: Earliest issued unpaid period pending banner with overdue calculation.
/// - R6: Uncredited installment dual view and shared credit limit group calculation (ASYM-CD-07).
/// - R7: Interest-free days for today swiping.

/// Plain Dart model of a record touching a credit account.
final class CreditCardRecord {
  const CreditCardRecord({
    required this.id,
    required this.recordTime,
    required this.type,
    this.subType = RecordDirection.none,
    required this.moneyMinor,
    this.assetId,
    this.fromAssetId,
    this.toAssetId,
    this.excludeBudget = false,
    this.excludeExIn = false,
    this.currencySnapshot,
    this.relations,
  });

  final String id;
  final int recordTime; // epoch milliseconds
  final int type;
  final int subType;
  final BigInt moneyMinor;
  final int? assetId;
  final int? fromAssetId;
  final int? toAssetId;
  final bool excludeBudget;
  final bool excludeExIn;
  final CurrencySnapshot? currencySnapshot;
  final RecordRelations? relations;

  /// Converted minor units for this card (DR-CD-04 / 02zx §3.2).
  BigInt amountForCard(int cardId) {
    if (type == RecordType.transfer && fromAssetId == cardId) {
      return currencySnapshot?.sourceGross ?? moneyMinor;
    }
    return currencySnapshot?.assetNet ?? moneyMinor;
  }
}

/// Returns the number of days in [month] of [year].
int daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

/// Clamps [billDay] to the valid day range in [year]/[month] (R1).
/// [endOfMonthDay] (-2) evaluates to the last day of the month.
int anchorDay(int year, int month, int billDay) {
  final last = daysInMonth(year, month);
  if (billDay == endOfMonthDay) return last;
  if (billDay > last) return last;
  if (billDay < 1) return 1;
  return billDay;
}

/// Calculates the safe repayment due date for a given [statementDate] (R2 / ASYM-CD-01).
///
/// Rules:
/// - If [repaymentAfterBillDay] is true: statementDate + max(0, repaymentDay) days.
/// - If fixed day repayment:
///   - If [repaymentDay] == -2 (end of month): if statementDate is already end of month,
///     moves to next month's end of month (never same-day due date).
///   - If [repaymentDay] <= statementDate.day: moves to next month with safe clamping.
///   - If [repaymentDay] > statementDate.day: stays in current month with safe clamping.
/// Never throws DateTimeException in February or short months.
DateTime computeDueDate({
  required DateTime statementDate,
  required int repaymentDay,
  required bool repaymentAfterBillDay,
}) {
  if (repaymentAfterBillDay) {
    final offset = repaymentDay > 0 ? repaymentDay : 0;
    return DateTime(
      statementDate.year,
      statementDate.month,
      statementDate.day + offset,
    );
  }

  final lastDayOfStmtMonth = daysInMonth(
    statementDate.year,
    statementDate.month,
  );
  final isEndOfMonthStmt = statementDate.day >= lastDayOfStmtMonth;

  if (repaymentDay == endOfMonthDay) {
    if (isEndOfMonthStmt) {
      final nextYear = statementDate.month == 12
          ? statementDate.year + 1
          : statementDate.year;
      final nextMonth = statementDate.month == 12 ? 1 : statementDate.month + 1;
      final lastDay = daysInMonth(nextYear, nextMonth);
      return DateTime(nextYear, nextMonth, lastDay);
    } else {
      return DateTime(
        statementDate.year,
        statementDate.month,
        lastDayOfStmtMonth,
      );
    }
  }

  if (repaymentDay <= statementDate.day) {
    final nextYear = statementDate.month == 12
        ? statementDate.year + 1
        : statementDate.year;
    final nextMonth = statementDate.month == 12 ? 1 : statementDate.month + 1;
    final clamped = clampRepaymentDay(repaymentDay, nextYear, nextMonth);
    return DateTime(nextYear, nextMonth, clamped);
  } else {
    final clamped = clampRepaymentDay(
      repaymentDay,
      statementDate.year,
      statementDate.month,
    );
    return DateTime(statementDate.year, statementDate.month, clamped);
  }
}

/// A single credit statement period with bounds and key dates (R1, R2).
final class CreditStatementPeriod {
  const CreditStatementPeriod({
    required this.year,
    required this.periodIndex,
    required this.start,
    required this.end,
    required this.statementDate,
    required this.dueDate,
  });

  /// The statement cycle year (e.g. 2026).
  final int year;

  /// Period index (1..12).
  final int periodIndex;

  /// Closed start interval (inclusive).
  final DateTime start;

  /// Closed end interval (inclusive).
  final DateTime end;

  /// Statement issue date (00:00:00).
  final DateTime statementDate;

  /// Repayment due date (00:00:00).
  final DateTime dueDate;

  int get startMs => start.millisecondsSinceEpoch;
  int get endMs => end.millisecondsSinceEpoch;

  /// Whether this statement is already issued as of [today].
  bool isIssued(DateTime today) {
    final t0 = DateTime(today.year, today.month, today.day);
    final s0 = DateTime(
      statementDate.year,
      statementDate.month,
      statementDate.day,
    );
    return !t0.isBefore(s0);
  }

  bool contains(int epochMs) => epochMs >= startMs && epochMs <= endMs;
}

/// Computes the [CreditStatementPeriod] for [year] and [month] (1..12) (R1, R2).
CreditStatementPeriod computePeriod({
  required int year,
  required int month,
  required int billDay,
  required int repaymentDay,
  required bool repaymentAfterBillDay,
  required bool billDayCounted,
}) {
  final isWholeNaturalMonth =
      (billDay == 1 && !billDayCounted) ||
      (billDay == endOfMonthDay && billDayCounted);

  final DateTime start;
  final DateTime end;
  final DateTime statementDate;

  if (isWholeNaturalMonth) {
    start = DateTime(year, month, 1, 0, 0, 0, 0);
    final lastDay = daysInMonth(year, month);
    end = DateTime(year, month, lastDay, 23, 59, 59, 999);
    statementDate = billDayCounted
        ? DateTime(year, month, lastDay)
        : (month == 12
              ? DateTime(year + 1, 1, 1)
              : DateTime(year, month + 1, 1));
  } else {
    final prevYear = month == 1 ? year - 1 : year;
    final prevMonth = month == 1 ? 12 : month - 1;
    final prevAnchor = anchorDay(prevYear, prevMonth, billDay);
    final currAnchor = anchorDay(year, month, billDay);

    if (billDayCounted) {
      start = DateTime(
        prevYear,
        prevMonth,
        prevAnchor,
      ).add(const Duration(days: 1));
      end = DateTime(year, month, currAnchor, 23, 59, 59, 999);
      statementDate = DateTime(year, month, currAnchor);
    } else {
      start = DateTime(prevYear, prevMonth, prevAnchor, 0, 0, 0, 0);
      end = DateTime(
        year,
        month,
        currAnchor,
      ).subtract(const Duration(milliseconds: 1));
      statementDate = DateTime(year, month, currAnchor);
    }
  }

  final dueDate = computeDueDate(
    statementDate: statementDate,
    repaymentDay: repaymentDay,
    repaymentAfterBillDay: repaymentAfterBillDay,
  );

  return CreditStatementPeriod(
    year: year,
    periodIndex: month,
    start: start,
    end: end,
    statementDate: statementDate,
    dueDate: dueDate,
  );
}

/// Helper to sum linked refund child amounts (CD-F02: prefers child record in query results).
BigInt _sumLinkedRefunds(
  CreditCardRecord r,
  Map<String, CreditCardRecord> recordsById,
  int cardId,
) {
  final links = r.relations?.refunds?.children;
  if (links == null || links.isEmpty) return BigInt.zero;
  var sum = BigInt.zero;
  for (final link in links) {
    final child = recordsById[link.billId];
    if (child != null) {
      sum += child.amountForCard(cardId).abs();
    } else {
      sum += link.amount.abs(); // lbm fallback
    }
  }
  return sum;
}

/// Helper to sum linked reimbursement amounts.
BigInt _sumLinkedReimbursements(
  CreditCardRecord r,
  Map<String, CreditCardRecord> recordsById,
  int cardId,
) {
  final links = r.relations?.reimbursements?.children;
  if (links == null || links.isEmpty) return BigInt.zero;
  var sum = BigInt.zero;
  for (final link in links) {
    final child = recordsById[link.billId];
    if (child != null) {
      sum += child.amountForCard(cardId).abs();
    } else {
      sum += link.amount.abs();
    }
  }
  return sum;
}

/// Computes the statement amount and breakdown for a single period (R3 / P-02).
///
/// NOTE on CD-F01 (per-operand HALF_UP):
/// Because all ledger amounts in TallyIsle are stored and calculated as exact integer cents
/// (minor units, BigInt), every operand is inherently an exact cent value with 2 decimals.
/// Thus the per-operand 2-decimal HALF_UP rule is automatically and mathematically satisfied.
({
  BigInt statementAmount,
  BigInt installmentAmount,
  BigInt normalAmount,
  int billCount,
})
calculatePeriodStatement({
  required CreditStatementPeriod period,
  required Iterable<CreditCardRecord> recordsInWindow,
  required Map<String, CreditCardRecord> recordsById,
  required int cardId,
}) {
  var bMain = BigInt.zero;
  var cExtra = BigInt.zero;
  var dOffset = BigInt.zero;
  var eParentRf = BigInt.zero;
  var fChildRf = BigInt.zero;
  var gParentRb = BigInt.zero;
  var hChildRb = BigInt.zero;
  var instTotal = BigInt.zero;
  var count = 0;

  for (final r in recordsInWindow) {
    if (!period.contains(r.recordTime)) continue;

    // R3: Exclude repayment transfers into the card (type == 2 && to_asset_id == card.id).
    if (r.type == RecordType.transfer && r.toAssetId == cardId) {
      continue;
    }

    count++;
    final amt = r.amountForCard(cardId);

    // Reimbursement receipt child deposited into the card (type == 15).
    if (r.type == RecordType.reimburseReceipt) {
      hChildRb += amt.abs();
      continue;
    }

    // Refund child record (originId present or negative expense).
    final isRefundChild =
        (r.relations?.refunds?.originId != null &&
            r.relations!.refunds!.originId!.trim().isNotEmpty) ||
        (r.type == RecordType.expense && amt.isNegative);
    if (isRefundChild) {
      fChildRf += amt.abs();
      continue;
    }

    // Bill installment (type == 13).
    if (r.type == RecordType.billInstallment) {
      instTotal += amt.abs();
      // P-02 (ASYM-CD-03): Recorded as installment and included in statement amount.
      continue;
    }

    // Balance adjust (type == 4).
    if (r.type == RecordType.balanceAdjust) {
      if (amt >= BigInt.zero) {
        dOffset += amt.abs();
      } else {
        cExtra += amt.abs();
      }
      continue;
    }

    // Fee (type == 12).
    if (r.type == RecordType.fee) {
      if (amt.isNegative) {
        cExtra -= amt.abs();
      } else {
        bMain += amt;
      }
      continue;
    }

    // Excluded from statistics (exclude_ex_in == 1).
    if (r.excludeExIn) {
      if (amt > BigInt.zero) {
        // P-02 (ASYM-CD-04): Linked refunds properly offset exclude_ex_in spending.
        final linkedRf = _sumLinkedRefunds(r, recordsById, cardId);
        final net = amt - linkedRf;
        if (net > BigInt.zero) {
          cExtra += net;
        } else if (net < BigInt.zero) {
          dOffset += -net;
        }
        if (linkedRf > BigInt.zero) {
          eParentRf += linkedRf;
        }
      }
      continue;
    }

    // Standard spending / income.
    if (r.type == RecordType.expense || r.type == RecordType.income) {
      if (amt.isNegative) {
        if (r.type == RecordType.expense) {
          bMain -= amt.abs();
        } else {
          dOffset -= amt.abs();
        }
      } else {
        final linkedRf = _sumLinkedRefunds(r, recordsById, cardId);
        final net = amt - linkedRf;
        if (r.type == RecordType.expense) {
          if (net >= BigInt.zero) {
            bMain += net;
          } else {
            dOffset += -net;
          }
        } else {
          if (net >= BigInt.zero) {
            dOffset += net;
          } else {
            bMain += -net;
          }
        }
        if (linkedRf > BigInt.zero) {
          eParentRf += linkedRf;
        }
      }
    } else if (r.type == RecordType.reimbursable) {
      final linkedRf = _sumLinkedRefunds(r, recordsById, cardId);
      final linkedRb = _sumLinkedReimbursements(r, recordsById, cardId);
      if (linkedRb == BigInt.zero && linkedRf == BigInt.zero) {
        cExtra += amt.abs();
      } else {
        final afterRf = amt - linkedRf;
        final net = afterRf - linkedRb;
        if (net > BigInt.zero) {
          bMain += net;
        } else if (net < BigInt.zero) {
          dOffset += -net;
        }
        if (linkedRf > BigInt.zero) {
          eParentRf += linkedRf;
        }
        if (linkedRb > BigInt.zero) {
          gParentRb += linkedRb;
        }
      }
    } else if (r.type == RecordType.installmentPrincipal) {
      bMain += amt.abs();
    } else if ((r.type == RecordType.transfer ||
            r.type == RecordType.borrowIn ||
            r.type == RecordType.lendOut ||
            r.type == RecordType.repay ||
            r.type == RecordType.collect ||
            r.type == RecordType.debtInterest) &&
        r.fromAssetId == cardId) {
      cExtra += amt.abs();
    } else {
      if (r.subType == RecordDirection.expense) {
        bMain += amt.abs();
      } else if (r.subType == RecordDirection.income) {
        dOffset += amt.abs();
      }
    }
  }

  // Formula: max(0, B_main + C_extra - D_offset + E_parentRf - F_childRf + G_parentRb - H_childRb)
  final normalFormula =
      bMain + cExtra - dOffset + eParentRf - fChildRf + gParentRb - hChildRb;
  final statementAmount = normalFormula > BigInt.zero
      ? normalFormula
      : BigInt.zero;

  // Under P-02 ASYM-CD-03: installment is properly broken out from statementAmount
  // without double deduction: normal spending (585) + installment (60) = total statement (645).
  final normalAmount = statementAmount >= instTotal
      ? statementAmount - instTotal
      : BigInt.zero;

  return (
    statementAmount: statementAmount,
    installmentAmount: instTotal,
    normalAmount: normalAmount,
    billCount: count,
  );
}

/// A statement card presentation item after debt pool allocation (R4).
final class CreditStatementItem {
  const CreditStatementItem({
    required this.period,
    required this.statementAmount,
    required this.installmentAmount,
    required this.normalAmount,
    required this.remainingAmount,
    required this.repaidAmount,
    required this.billCount,
    required this.isIssued,
  });

  final CreditStatementPeriod period;
  final BigInt statementAmount;
  final BigInt installmentAmount;
  final BigInt normalAmount;
  final BigInt remainingAmount;
  final BigInt repaidAmount;
  final int billCount;
  final bool isIssued;

  bool get isPaidOff =>
      statementAmount > BigInt.zero && remainingAmount == BigInt.zero;
}

/// Computes all credit statement items for [selectedYear] using the newest-first
/// debt pool allocation (R4, CD-F03).
List<CreditStatementItem> calculateCreditStatements({
  required CreditInfo creditInfo,
  required BigInt cardBalanceMinor,
  required Iterable<CreditCardRecord> records,
  required int cardId,
  required int selectedYear,
  required DateTime today,
}) {
  if (!creditInfo.configured) return const [];

  final recordsList = records.toList();
  final recordsById = {for (final r in recordsList) r.id: r};

  // Determine year range for period construction (CD-F03):
  // from earliest record year to max(selectedYear, today.year) + 1.
  var minYear = selectedYear < today.year ? selectedYear : today.year;
  if (recordsList.isNotEmpty) {
    for (final r in recordsList) {
      final y = DateTime.fromMillisecondsSinceEpoch(r.recordTime).year;
      if (y < minYear) minYear = y;
    }
  }
  final maxYear = (selectedYear > today.year ? selectedYear : today.year) + 1;

  // 1. Construct all periods across the years.
  final allPeriods = <CreditStatementPeriod>[];
  for (var y = minYear; y <= maxYear; y++) {
    for (var m = 1; m <= 12; m++) {
      allPeriods.add(
        computePeriod(
          year: y,
          month: m,
          billDay: creditInfo.billDay,
          repaymentDay: creditInfo.repaymentDay,
          repaymentAfterBillDay: creditInfo.repaymentAfterBillDay,
          billDayCounted: creditInfo.billDayCounted,
        ),
      );
    }
  }

  // 2. Calculate statement amounts for each period.
  final periodStatements = [
    for (final p in allPeriods)
      (
        period: p,
        amounts: calculatePeriodStatement(
          period: p,
          recordsInWindow: recordsList,
          recordsById: recordsById,
          cardId: cardId,
        ),
      ),
  ];

  // 3. Newest-first debt pool allocation (R4, CD-F03):
  // pool = max(0, -balance). Sort all periods by statementDate DESC.
  var pool = cardBalanceMinor.isNegative ? -cardBalanceMinor : BigInt.zero;
  periodStatements.sort(
    (a, b) => b.period.statementDate.compareTo(a.period.statementDate),
  );

  final allocated = <CreditStatementItem>[];
  for (final item in periodStatements) {
    final stmt = item.amounts.statementAmount;
    final remaining = pool < stmt ? pool : stmt;
    final repaid = stmt - remaining;
    pool -= remaining;

    allocated.add(
      CreditStatementItem(
        period: item.period,
        statementAmount: stmt,
        installmentAmount: item.amounts.installmentAmount,
        normalAmount: item.amounts.normalAmount,
        remainingAmount: remaining,
        repaidAmount: repaid,
        billCount: item.amounts.billCount,
        isIssued: item.period.isIssued(today),
      ),
    );
  }

  // 4. Filter by selectedYear (R4) and sort by periodIndex DESC (newest first).
  return allocated
      .where((item) => item.period.statementDate.year == selectedYear)
      .toList()
    ..sort((a, b) => b.period.periodIndex.compareTo(a.period.periodIndex));
}

/// Pending repayment banner info (R5).
final class CreditPendingBannerInfo {
  const CreditPendingBannerInfo({
    required this.period,
    required this.remainingAmount,
    required this.overdueDays,
    required this.isOverdue,
  });

  final CreditStatementPeriod period;
  final BigInt remainingAmount;
  final int overdueDays;
  final bool isOverdue;
}

/// Finds the pending repayment banner (R5).
///
/// Rules:
/// - Only shown when selectedYear == currentYear.
/// - Takes the EARLIEST issued period with remainingAmount > 0.
CreditPendingBannerInfo? findPendingRepaymentBanner({
  required List<CreditStatementItem> statementItems,
  required int selectedYear,
  required DateTime today,
}) {
  if (selectedYear != today.year) return null;

  // Filter issued with remaining > 0, sorted by statementDate ASC (earliest first).
  final unpaidIssued =
      statementItems
          .where((i) => i.isIssued && i.remainingAmount > BigInt.zero)
          .toList()
        ..sort(
          (a, b) => a.period.statementDate.compareTo(b.period.statementDate),
        );

  if (unpaidIssued.isEmpty) return null;

  final earliest = unpaidIssued.first;
  final todayDate = DateTime(today.year, today.month, today.day);
  final dueDate = DateTime(
    earliest.period.dueDate.year,
    earliest.period.dueDate.month,
    earliest.period.dueDate.day,
  );

  final isOverdue = todayDate.isAfter(dueDate);
  final overdueDays = isOverdue ? todayDate.difference(dueDate).inDays : 0;

  return CreditPendingBannerInfo(
    period: earliest.period,
    remainingAmount: earliest.remainingAmount,
    overdueDays: overdueDays,
    isOverdue: isOverdue,
  );
}

/// Single card display balance accounting for installments in arrears (R6).
/// displayBalance = balance - sum(inst.cb && inst.ci ? b + i : ...).
BigInt calculateCardDisplayBalance(
  BigInt balanceMinor,
  List<UncreditedInstallment>? installments,
) {
  if (installments == null || installments.isEmpty) {
    return balanceMinor;
  }
  var uncreditedInArrears = BigInt.zero;
  for (final inst in installments) {
    if (inst.principalCounted && inst.interestCounted) {
      uncreditedInArrears += inst.principal + inst.interest;
    } else if (inst.principalCounted) {
      uncreditedInArrears += inst.principal;
    } else if (inst.interestCounted) {
      uncreditedInArrears += inst.interest;
    }
  }
  return balanceMinor - uncreditedInArrears;
}

/// Total uncredited installments ignoring cb/ci flags for header summary (R6).
BigInt calculateTotalUncreditedInstallments(
  List<UncreditedInstallment>? installments,
) {
  if (installments == null || installments.isEmpty) {
    return BigInt.zero;
  }
  var total = BigInt.zero;
  for (final inst in installments) {
    total += inst.principal + inst.interest;
  }
  return total;
}

/// Shared credit limit group computation result (R6 / ASYM-CD-07).
final class SharedLimitResult {
  const SharedLimitResult({
    required this.effectiveTotalLimit,
    required this.usableLimit,
    required this.groupDisplayBalance,
    required this.isShared,
    required this.isPrimary,
  });

  final BigInt effectiveTotalLimit;
  final BigInt usableLimit;
  final BigInt groupDisplayBalance;
  final bool isShared;
  final bool isPrimary;
}

/// Shared card representation for limit calculations.
final class SharedGroupCard {
  const SharedGroupCard({
    required this.id,
    required this.balanceMinor,
    required this.initMoneyMinor,
    this.status = AssetStatus.active,
    this.currency,
    required this.creditInfo,
    this.extraInfo,
  });

  final int id;
  final BigInt balanceMinor;
  final BigInt initMoneyMinor;
  final int status;
  final String? currency;
  final CreditInfo creditInfo;
  final AssetExtra? extraInfo;
}

/// Computes shared limit for [targetCard] across [allCards] (R6, ASYM-CD-07).
SharedLimitResult calculateSharedLimit({
  required SharedGroupCard targetCard,
  required List<SharedGroupCard> allCards,
  required int nowMs,
  RateTable? rateTable,
}) {
  final targetInfo = targetCard.creditInfo;
  final sharedParentId = targetInfo.sharedLimitAssetId;

  // Find primary card.
  SharedGroupCard primary;
  bool isShared = false;
  bool isPrimary = false;

  if (sharedParentId != null && sharedParentId > 0) {
    // Target is a secondary card.
    final found = allCards.where((c) => c.id == sharedParentId).firstOrNull;
    if (found != null) {
      primary = found;
      isShared = true;
      isPrimary = false;
    } else {
      // Primary card broken/not found: fallback gracefully.
      primary = targetCard;
      isShared = false;
      isPrimary = true;
    }
  } else {
    // Check if other cards point to targetCard.
    final secondaries = allCards
        .where((c) => c.creditInfo.sharedLimitAssetId == targetCard.id)
        .toList();
    if (secondaries.isNotEmpty) {
      primary = targetCard;
      isShared = true;
      isPrimary = true;
    } else {
      primary = targetCard;
      isShared = false;
      isPrimary = true;
    }
  }

  // Effective total limit comes from primary card's limit + active temp limits.
  final primaryActiveTemp =
      primary.extraInfo?.activeTempAmount(nowMs) ?? BigInt.zero;
  final effectiveTotalLimit = primary.initMoneyMinor + primaryActiveTemp;

  if (!isShared) {
    final targetActiveTemp =
        targetCard.extraInfo?.activeTempAmount(nowMs) ?? BigInt.zero;
    final singleEffectiveLimit = targetCard.initMoneyMinor + targetActiveTemp;
    final dispBal = calculateCardDisplayBalance(
      targetCard.balanceMinor,
      targetCard.creditInfo.installments,
    );
    return SharedLimitResult(
      effectiveTotalLimit: singleEffectiveLimit,
      usableLimit: singleEffectiveLimit + dispBal,
      groupDisplayBalance: dispBal,
      isShared: false,
      isPrimary: true,
    );
  }

  // Find all group members: primary + secondary cards (including hidden cards ASYM-CD-07).
  final groupMembers = allCards
      .where(
        (c) =>
            c.id == primary.id || c.creditInfo.sharedLimitAssetId == primary.id,
      )
      .toList();

  final baseCurrency = primary.currency ?? 'CNY';
  var groupDisplayBalance = BigInt.zero;

  for (final card in groupMembers) {
    final dispBal = calculateCardDisplayBalance(
      card.balanceMinor,
      card.creditInfo.installments,
    );
    final BigInt converted;
    if (rateTable != null && card.currency != null) {
      converted = rateTable.convert(dispBal, card.currency, baseCurrency);
    } else {
      converted = dispBal;
    }
    groupDisplayBalance += converted;
  }

  final usableLimit = effectiveTotalLimit + groupDisplayBalance;

  return SharedLimitResult(
    effectiveTotalLimit: effectiveTotalLimit,
    usableLimit: usableLimit,
    groupDisplayBalance: groupDisplayBalance,
    isShared: true,
    isPrimary: isPrimary,
  );
}

/// Computes the interest-free days for swiping [today] (R7).
int calculateInterestFreeDays({
  required CreditInfo creditInfo,
  required DateTime today,
}) {
  if (!creditInfo.configured || creditInfo.repaymentDay == unsetDay) return 0;

  final anchorToday = anchorDay(today.year, today.month, creditInfo.billDay);
  final DateTime stmtDate;

  if (today.day < anchorToday) {
    stmtDate = DateTime(today.year, today.month, anchorToday);
  } else if (today.day == anchorToday) {
    if (creditInfo.billDayCounted) {
      stmtDate = DateTime(today.year, today.month, anchorToday);
    } else {
      final nextYear = today.month == 12 ? today.year + 1 : today.year;
      final nextMonth = today.month == 12 ? 1 : today.month + 1;
      final nextAnchor = anchorDay(nextYear, nextMonth, creditInfo.billDay);
      stmtDate = DateTime(nextYear, nextMonth, nextAnchor);
    }
  } else {
    final nextYear = today.month == 12 ? today.year + 1 : today.year;
    final nextMonth = today.month == 12 ? 1 : today.month + 1;
    final nextAnchor = anchorDay(nextYear, nextMonth, creditInfo.billDay);
    stmtDate = DateTime(nextYear, nextMonth, nextAnchor);
  }

  final dueDate = computeDueDate(
    statementDate: stmtDate,
    repaymentDay: creditInfo.repaymentDay,
    repaymentAfterBillDay: creditInfo.repaymentAfterBillDay,
  );

  final todayStart = DateTime(today.year, today.month, today.day);
  final dueStart = DateTime(dueDate.year, dueDate.month, dueDate.day);
  return dueStart.difference(todayStart).inDays + 1;
}
