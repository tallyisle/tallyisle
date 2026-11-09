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
