import '../ledger/record_extra.dart';
import '../model/codes.dart';

/// A transaction entry used for reconciliation running balance calculation.
final class ReconRecord {
  const ReconRecord({
    required this.id,
    required this.type,
    this.subType = RecordDirection.none,
    required this.moneyMinor,
    this.discountMinor,
    this.recordTime = 0,
    this.assetId = noRef,
    this.fromAssetId = noRef,
    this.toAssetId = noRef,
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
  final CurrencySnapshot? currency;
}

/// Selects the effective transaction amount in the account's target currency
/// according to R3 priority rules.
///
/// Priority:
/// - Target currency `T`: `accountCurrency` (trimmed/uppercase, defaulting to CNY).
/// - Transfer source side (`type == 2 && fromAssetId == accountId`):
///   `sm (sc == T)` -> `bm (bc == T)` -> `am (ac == T)` -> `raw money`.
/// - Everything else (and transfer target side):
///   `am (ac == T)` -> `bm (bc == T)` -> `sm - discount (sc == T)` -> `raw money`.
BigInt selectReconAmount({
  required ReconRecord record,
  required int accountId,
  String? accountCurrency,
}) {
  final target = (accountCurrency != null && accountCurrency.trim().isNotEmpty)
      ? accountCurrency.trim().toUpperCase()
      : 'CNY';
  final curr = record.currency;
  if (curr == null || !curr.isValid) {
    return record.moneyMinor;
  }

  final isTransferSource =
      record.type == RecordType.transfer && record.fromAssetId == accountId;

  if (isTransferSource) {
    if (curr.sourceCode == target) return curr.sourceGross;
    if (curr.baseCode == target && curr.baseAmount != null) {
      return curr.baseAmount!;
    }
    if (curr.assetCode == target && curr.assetNet != null) {
      return curr.assetNet!;
    }
    return record.moneyMinor;
  } else {
    if (curr.assetCode == target && curr.assetNet != null) {
      return curr.assetNet!;
    }
    if (curr.baseCode == target && curr.baseAmount != null) {
      return curr.baseAmount!;
    }
    if (curr.sourceCode == target) {
      return curr.sourceGross - (record.discountMinor ?? BigInt.zero);
    }
    return record.moneyMinor;
  }
}

/// Returns the forward balance delta applied to [accountId] by [record].
///
/// Aligned with `balanceEffects` in `lib/domain/ledger/effects.dart`.
BigInt recordForwardDelta({
  required ReconRecord record,
  required int accountId,
  String? accountCurrency,
}) {
  final amt = selectReconAmount(
    record: record,
    accountId: accountId,
    accountCurrency: accountCurrency,
  );

  switch (record.type) {
    case RecordType.expense: // 0
    case RecordType.installmentPrincipal: // 14
    case RecordType.fee: // 12
      // Negative amounts (e.g. refund child) add back.
      if (record.assetId == accountId) {
        return -amt;
      }
      return BigInt.zero;

    case RecordType.income: // 1
    case RecordType.reimburseReceipt: // 15
    case RecordType.depositInterest: // 17
      if (record.assetId == accountId) {
        return amt;
      }
      return BigInt.zero;

    case RecordType.transfer: // 2
      if (record.fromAssetId == record.toAssetId) {
        return BigInt.zero; // self-transfer
      }
      if (record.fromAssetId == accountId) {
        return -amt;
      }
      if (record.toAssetId == accountId) {
        return amt;
      }
      return BigInt.zero; // dirty or unrelated

    case RecordType.reimbursable: // 3
      // In TallyIsle ledger engine: paying account is fromAssetId.
      if (record.fromAssetId == accountId) {
        return -amt;
      }
      return BigInt.zero;

    case RecordType.balanceAdjust: // 4
      if (record.fromAssetId == accountId ||
          (record.fromAssetId == noRef && record.assetId == accountId)) {
        return record.moneyMinor;
      }
      return BigInt.zero;

    case RecordType.borrowIn: // 5
    case RecordType.collect: // 8
      if (record.toAssetId == accountId) {
        return amt;
      }
      return BigInt.zero;

    case RecordType.lendOut: // 6
    case RecordType.repay: // 7
      if (record.fromAssetId == accountId) {
        return -amt;
      }
      return BigInt.zero;

    case RecordType.debtInterest: // 10
      if (record.subType == RecordDirection.expense &&
          record.fromAssetId == accountId) {
        return -amt;
      }
      if (record.subType == RecordDirection.income &&
          record.toAssetId == accountId) {
        return amt;
      }
      return BigInt.zero;

    case RecordType.reimburseDiff: // 11
      if (record.assetId == accountId) {
        if (record.subType == RecordDirection.expense) {
          return -amt;
        }
        if (record.subType == RecordDirection.income) {
          return amt;
        }
      }
      // Unknown sub_type keeps balance (ASYM-REC-05).
      return BigInt.zero;

    case RecordType.advanceIncome: // 9
    case RecordType.advanceExpense: // 16
    case RecordType.billInstallment: // 13
    default:
      return BigInt.zero;
  }
}

/// Computes the balance AFTER each record by walking backward from [currentBalance] (R2).
/// [records] must be sorted newest-first (`record_time DESC, record_id DESC`).
/// Returns a map from `record.id` to the balance immediately after that record occurred.
Map<String, BigInt> computeReconciliationBalances({
  required BigInt currentBalance,
  required int accountId,
  String? accountCurrency,
  required List<ReconRecord> records,
}) {
  final result = <String, BigInt>{};
  var running = currentBalance;

  for (final record in records) {
    result[record.id] = running;
    final delta = recordForwardDelta(
      record: record,
      accountId: accountId,
      accountCurrency: accountCurrency,
    );
    running = running - delta;
  }

  return result;
}

final class MonthFlowGroup<T> {
  const MonthFlowGroup({
    required this.year,
    required this.month,
    required this.items,
    required this.inflow,
    required this.outflow,
  });

  final int year;
  final int month;
  final List<T> items;
  final BigInt inflow;
  final BigInt outflow;
}

/// Groups records by natural calendar month, computing that month's inflow and
/// outflow for [accountId].
List<MonthFlowGroup<T>> groupRecordsByMonth<T>({
  required List<T> records,
  required int Function(T item) getRecordTime,
  required BigInt Function(T item) getDelta,
}) {
  final groups = <MonthFlowGroup<T>>[];
  if (records.isEmpty) return groups;

  int? currentYear;
  int? currentMonth;
  var currentItems = <T>[];
  var inflow = BigInt.zero;
  var outflow = BigInt.zero;

  void flush() {
    if (currentItems.isNotEmpty &&
        currentYear != null &&
        currentMonth != null) {
      groups.add(
        MonthFlowGroup<T>(
          year: currentYear,
          month: currentMonth,
          items: currentItems,
          inflow: inflow,
          outflow: outflow,
        ),
      );
    }
  }

  for (final record in records) {
    final date = DateTime.fromMillisecondsSinceEpoch(getRecordTime(record));
    if (date.year != currentYear || date.month != currentMonth) {
      flush();
      currentYear = date.year;
      currentMonth = date.month;
      currentItems = [];
      inflow = BigInt.zero;
      outflow = BigInt.zero;
    }
    currentItems.add(record);
    final delta = getDelta(record);
    if (delta > BigInt.zero) {
      inflow += delta;
    } else if (delta < BigInt.zero) {
      outflow += -delta;
    }
  }
  flush();
  return groups;
}

/// A natural calendar month window (`YYYY-MM-01 00:00:00.000` through
/// `YYYY-MM-lastDay 23:59:59.999`).
final class NaturalMonthPeriod {
  const NaturalMonthPeriod({required this.year, required this.month})
    : assert(month >= 1 && month <= 12);

  final int year;
  final int month;

  /// Inclusive start of the calendar month (`00:00:00.000`).
  DateTime get start => DateTime(year, month, 1, 0, 0, 0, 0);

  /// Inclusive end of the calendar month (`23:59:59.999` on the last day).
  DateTime get end => DateTime(year, month + 1, 0, 23, 59, 59, 999);

  int get startMs => start.millisecondsSinceEpoch;
  int get endMs => end.millisecondsSinceEpoch;

  bool contains(int epochMs) => epochMs >= startMs && epochMs <= endMs;

  NaturalMonthPeriod previous() => month == 1
      ? NaturalMonthPeriod(year: year - 1, month: 12)
      : NaturalMonthPeriod(year: year, month: month - 1);

  NaturalMonthPeriod next() => month == 12
      ? NaturalMonthPeriod(year: year + 1, month: 1)
      : NaturalMonthPeriod(year: year, month: month + 1);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NaturalMonthPeriod && year == other.year && month == other.month;

  @override
  int get hashCode => Object.hash(year, month);

  @override
  String toString() => 'NaturalMonthPeriod($year-$month)';
}

/// A single natural-month statement summary for a fund account.
final class FundMonthlyStatementItem {
  const FundMonthlyStatementItem({
    required this.period,
    required this.inflow,
    required this.outflow,
    required this.endingBalance,
    required this.recordCount,
    required this.isCurrentMonth,
    required this.isFutureUnstarted,
  });

  final NaturalMonthPeriod period;
  final BigInt inflow;
  final BigInt outflow;

  /// Net balance change during [period] (`inflow - outflow`).
  BigInt get netDelta => inflow - outflow;

  /// Account balance at [period.endMs], or `null` for future unstarted months
  /// with zero records and zero records after them (rendered as `'—'`).
  final BigInt? endingBalance;

  final int recordCount;
  final bool isCurrentMonth;
  final bool isFutureUnstarted;
}

/// Computes natural-month statements (`12..1`, newest-first) for [selectedYear]
/// by walking backward from [currentBalance] in O(N + 12).
///
/// [records] must be sorted newest-first (`record_time DESC, record_id DESC`).
/// Uses [recordForwardDelta] & [selectReconAmount] so every month's ending
/// balance and inflow/outflow match [computeReconciliationBalances] and
/// multi-currency `sc/ac/bc` snapshots 100%.
List<FundMonthlyStatementItem> calculateFundMonthlyStatements({
  required BigInt currentBalance,
  required int accountId,
  String? accountCurrency,
  required List<ReconRecord> records,
  required int selectedYear,
  required DateTime today,
}) {
  final todayDate = DateTime(today.year, today.month, today.day);
  var running = currentBalance;
  var idx = 0;

  // Roll back all records strictly newer than the end of selectedYear.
  final yearEndMs = NaturalMonthPeriod(year: selectedYear, month: 12).endMs;
  while (idx < records.length && records[idx].recordTime > yearEndMs) {
    running -= recordForwardDelta(
      record: records[idx],
      accountId: accountId,
      accountCurrency: accountCurrency,
    );
    idx++;
  }

  final items = <FundMonthlyStatementItem>[];
  for (var m = 12; m >= 1; m--) {
    final period = NaturalMonthPeriod(year: selectedYear, month: m);
    final startMs = period.startMs;
    final endMs = period.endMs;

    // Guard against any records still newer than this month's endMs.
    while (idx < records.length && records[idx].recordTime > endMs) {
      running -= recordForwardDelta(
        record: records[idx],
        accountId: accountId,
        accountCurrency: accountCurrency,
      );
      idx++;
    }

    // Because records are sorted newest-first, any index < idx strictly
    // occurred after period.endMs.
    final hasRecordsAfter = idx > 0;
    final balanceAtMonthEnd = running;

    var inflow = BigInt.zero;
    var outflow = BigInt.zero;
    var recordCount = 0;

    while (idx < records.length && records[idx].recordTime >= startMs) {
      final r = records[idx];
      final delta = recordForwardDelta(
        record: r,
        accountId: accountId,
        accountCurrency: accountCurrency,
      );
      if (delta > BigInt.zero) {
        inflow += delta;
      } else if (delta < BigInt.zero) {
        outflow += -delta;
      }
      running -= delta;
      recordCount++;
      idx++;
    }

    final isCurrentMonth = selectedYear == today.year && m == today.month;
    final isFutureUnstarted = DateTime(selectedYear, m, 1).isAfter(todayDate);
    final endingBalance =
        isFutureUnstarted && recordCount == 0 && !hasRecordsAfter
        ? null
        : balanceAtMonthEnd;

    items.add(
      FundMonthlyStatementItem(
        period: period,
        inflow: inflow,
        outflow: outflow,
        endingBalance: endingBalance,
        recordCount: recordCount,
        isCurrentMonth: isCurrentMonth,
        isFutureUnstarted: isFutureUnstarted,
      ),
    );
  }

  return items;
}

/// Filters [statements] by hiding empty `0-record` months (both past and future
/// unstarted) unless [includeEmpty] is `true`.
///
/// The current calendar month (`item.isCurrentMonth`) is ALWAYS kept visible
/// even when its `recordCount == 0`.
({List<FundMonthlyStatementItem> visible, int hiddenEmptyCount})
filterVisibleFundMonthlyStatements({
  required List<FundMonthlyStatementItem> statements,
  required DateTime today,
  bool includeEmpty = false,
}) {
  var hiddenEmptyCount = 0;
  final visible = <FundMonthlyStatementItem>[];

  for (final item in statements) {
    final isCurrent =
        item.isCurrentMonth ||
        (item.period.year == today.year && item.period.month == today.month);
    final isFoldableEmpty = !isCurrent && item.recordCount == 0;
    if (isFoldableEmpty) {
      hiddenEmptyCount++;
      if (includeEmpty) {
        visible.add(item);
      }
    } else {
      visible.add(item);
    }
  }

  return (visible: visible, hiddenEmptyCount: hiddenEmptyCount);
}
