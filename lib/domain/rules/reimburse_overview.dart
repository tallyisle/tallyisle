import '../../core/money.dart';
import '../ledger/record_extra.dart';
import '../ledger/record_relations.dart';
import '../model/codes.dart';
import 'asset_overview.dart';

/// Pure input fact for a `type == RecordType.reimbursable` (`3`) bill.
final class ReimburseBillInput {
  const ReimburseBillInput({
    required this.recordId,
    required this.bookId,
    this.type = RecordType.reimbursable,
    required this.moneyMinor,
    required this.recordTime,
    this.createDate,
    this.categoryId = noRef,
    this.assetId = noRef,
    this.fromAssetId = noRef,
    this.remark = '',
    this.relInfo,
    this.extraInfo,
    this.fallbackCurrencyCode,
  });

  final String recordId;
  final int bookId;
  final int type;
  final BigInt moneyMinor;
  final int recordTime;
  final int? createDate;
  final int categoryId;
  final int assetId;
  final int fromAssetId;
  final String remark;
  final String? relInfo;
  final String? extraInfo;
  final String? fallbackCurrencyCode;
}

/// Pure input fact for a live `type == RecordType.reimburseReceipt` (`15`) bill.
final class ReimburseReceiptInput {
  const ReimburseReceiptInput({
    required this.recordId,
    required this.moneyMinor,
    this.recordTime = 0,
    this.assetId = noRef,
    this.remark = '',
    this.relInfo,
    this.extraInfo,
  });

  final String recordId;
  final BigInt moneyMinor;
  final int recordTime;
  final int assetId;
  final String remark;
  final String? relInfo;
  final String? extraInfo;
}

/// Computed reimbursement status for a single `RecordType.reimbursable` bill.
final class ReimburseBillItem {
  ReimburseBillItem({
    required this.recordId,
    required this.bookId,
    required this.recordTime,
    required this.createDate,
    required this.categoryId,
    required this.fundingAssetId,
    required this.remark,
    required this.currencyCode,
    required this.originMinor,
    required this.reimbursedMinor,
    required List<String> receiptIds,
  }) : remainingMinor = originMinor > reimbursedMinor
           ? originMinor - reimbursedMinor
           : BigInt.zero,
       overageMinor = reimbursedMinor > originMinor
           ? reimbursedMinor - originMinor
           : BigInt.zero,
       isSettled = reimbursedMinor >= originMinor,
       isPartial =
           reimbursedMinor > BigInt.zero && reimbursedMinor < originMinor,
       receiptIds = List<String>.unmodifiable(receiptIds);

  final String recordId;
  final int bookId;
  final int recordTime;
  final int? createDate;
  final int categoryId;
  final int fundingAssetId;
  final String remark;
  final String currencyCode;

  final BigInt originMinor;
  final BigInt reimbursedMinor;
  final BigInt remainingMinor;
  final BigInt overageMinor;
  final bool isSettled;
  final bool isPartial;
  final List<String> receiptIds;
}

/// Aggregated overview across all scoped reimbursable bills.
final class ReimburseOverview {
  ReimburseOverview({
    required List<ReimburseBillItem> pendingItems,
    required List<ReimburseBillItem> settledItems,
    required this.pendingTotalMinor,
    required this.reimbursedTotalMinor,
    required this.totalOriginMinor,
  }) : pendingItems = List<ReimburseBillItem>.unmodifiable(pendingItems),
       settledItems = List<ReimburseBillItem>.unmodifiable(settledItems);

  final List<ReimburseBillItem> pendingItems;
  final List<ReimburseBillItem> settledItems;
  final BigInt pendingTotalMinor;
  final BigInt reimbursedTotalMinor;
  final BigInt totalOriginMinor;

  int get pendingCount => pendingItems.length;
  int get settledCount => settledItems.length;
  bool get isEmpty => pendingItems.isEmpty && settledItems.isEmpty;

  static final empty = ReimburseOverview(
    pendingItems: const <ReimburseBillItem>[],
    settledItems: const <ReimburseBillItem>[],
    pendingTotalMinor: BigInt.zero,
    reimbursedTotalMinor: BigInt.zero,
    totalOriginMinor: BigInt.zero,
  );
}

/// Classification for a live reimbursement input amount preview.
enum ReimbursePreviewKind { partial, full, overage }

/// Live preview of what happens after applying [inputMinor] to a bill.
final class ReimburseAmountPreview {
  const ReimburseAmountPreview({
    required this.kind,
    required this.afterRemainingMinor,
    required this.overageMinor,
    required this.hintText,
  });

  final ReimbursePreviewKind kind;
  final BigInt afterRemainingMinor;
  final BigInt overageMinor;
  final String hintText;
}

/// Computes the live hint for a single-bill reimbursement amount input.
ReimburseAmountPreview computeReimbursePreview({
  required BigInt originMinor,
  required BigInt alreadyReimbursedMinor,
  required BigInt inputMinor,
  String currencySymbol = '¥',
}) {
  final totalAfter = alreadyReimbursedMinor + inputMinor;
  if (totalAfter < originMinor) {
    final rem = originMinor - totalAfter;
    return ReimburseAmountPreview(
      kind: ReimbursePreviewKind.partial,
      afterRemainingMinor: rem,
      overageMinor: BigInt.zero,
      hintText: '报销后剩余待报 $currencySymbol${Money.minor(rem).decimal}',
    );
  }
  if (totalAfter == originMinor) {
    return ReimburseAmountPreview(
      kind: ReimbursePreviewKind.full,
      afterRemainingMinor: BigInt.zero,
      overageMinor: BigInt.zero,
      hintText: '全额结清',
    );
  }
  final over = totalAfter - originMinor;
  return ReimburseAmountPreview(
    kind: ReimbursePreviewKind.overage,
    afterRemainingMinor: BigInt.zero,
    overageMinor: over,
    hintText: '超出垫付 +$currencySymbol${Money.minor(over).decimal}',
  );
}

/// Computes [ReimburseOverview] from [bills] (`type == RecordType.reimbursable`)
/// and optional [liveReceipts] (`type == RecordType.reimburseReceipt`).
///
/// When [rates] is provided, top-level totals (`pendingTotalMinor`,
/// `reimbursedTotalMinor`, `totalOriginMinor`) are converted to
/// [baseCurrencyCode].
ReimburseOverview computeReimburseOverview(
  Iterable<ReimburseBillInput> bills, {
  Map<String, ReimburseReceiptInput>? liveReceipts,
  String baseCurrencyCode = 'CNY',
  RateTable? rates,
}) {
  final base = normalizeCurrency(baseCurrencyCode) ?? 'CNY';

  BigInt toBase(BigInt minor, String code) {
    if (rates == null || code == base) return minor;
    return rates.convert(minor, code, base);
  }

  // Index reverse links (`riobid`) from live receipts if provided so receipts
  // linked via `rel_info.lreimbursei.riobid` reconcile cleanly even if missing
  // from a parent's child array.
  final reverseReceiptsByOrigin = <String, List<ReimburseReceiptInput>>{};
  if (liveReceipts != null) {
    for (final receipt in liveReceipts.values) {
      final originId = _parseRelationsSafe(
        receipt.relInfo,
      ).reimbursements?.originId?.trim();
      if (originId != null && originId.isNotEmpty) {
        reverseReceiptsByOrigin
            .putIfAbsent(originId, () => <ReimburseReceiptInput>[])
            .add(receipt);
      }
    }
  }

  final pending = <ReimburseBillItem>[];
  final settled = <ReimburseBillItem>[];
  var pendingTotalMinor = BigInt.zero;
  var reimbursedTotalMinor = BigInt.zero;
  var totalOriginMinor = BigInt.zero;

  for (final bill in bills) {
    if (bill.type != RecordType.reimbursable) continue;

    final rel = _parseRelationsSafe(bill.relInfo);
    final snap = _parseCurrencySafe(bill.extraInfo);
    final currencyCode = _resolveCurrencyCode(
      snap: snap,
      fallbackCurrencyCode: bill.fallbackCurrencyCode,
      baseCurrencyCode: base,
    );

    final rawOriginMinor =
        (snap != null && snap.isValid && snap.assetNet != null)
        ? snap.assetNet!
        : bill.moneyMinor;

    // Deduct linked refunds so refunded reimbursable bills reduce pending
    // amounts rather than overstating what still awaits reimbursement.
    final seenRefundIds = <String>{};
    var refundedMinor = BigInt.zero;
    for (final refund in rel.refunds?.children ?? const <LinkedBill>[]) {
      final id = refund.billId.trim();
      if (id.isNotEmpty && !seenRefundIds.add(id)) continue;
      final rAmt =
          (normalizeCurrency(refund.assetCode) == currencyCode &&
              refund.assetAmount != null)
          ? refund.assetAmount!.abs()
          : refund.amount.abs();
      refundedMinor += rAmt;
    }
    final effectiveOriginMinor = rawOriginMinor > refundedMinor
        ? rawOriginMinor - refundedMinor
        : BigInt.zero;

    final children = rel.reimbursements?.children ?? const <LinkedBill>[];
    final seenReceiptIds = <String>{};
    final receiptIds = <String>[];
    var reimbursedMinor = BigInt.zero;

    for (final link in children) {
      final id = link.billId.trim();
      if (id.isNotEmpty && !seenReceiptIds.add(id)) {
        continue;
      }
      final live = (liveReceipts != null && id.isNotEmpty)
          ? liveReceipts[id]
          : null;
      final BigInt receiptMinor;
      if (live != null) {
        final liveSnap = _parseCurrencySafe(live.extraInfo);
        receiptMinor =
            (liveSnap != null && liveSnap.isValid && liveSnap.assetNet != null)
            ? liveSnap.assetNet!.abs()
            : live.moneyMinor.abs();
      } else if (normalizeCurrency(link.assetCode) == currencyCode &&
          link.assetAmount != null) {
        receiptMinor = link.assetAmount!.abs();
      } else {
        receiptMinor = link.amount.abs();
      }
      reimbursedMinor += receiptMinor;
      if (id.isNotEmpty) {
        receiptIds.add(id);
      }
    }

    final reverseList = reverseReceiptsByOrigin[bill.recordId];
    if (reverseList != null) {
      for (final receipt in reverseList) {
        final id = receipt.recordId.trim();
        if (id.isNotEmpty && seenReceiptIds.add(id)) {
          final liveSnap = _parseCurrencySafe(receipt.extraInfo);
          final receiptMinor =
              (liveSnap != null &&
                  liveSnap.isValid &&
                  liveSnap.assetNet != null)
              ? liveSnap.assetNet!.abs()
              : receipt.moneyMinor.abs();
          reimbursedMinor += receiptMinor;
          receiptIds.add(id);
        }
      }
    }

    final fundingAssetId = bill.fromAssetId != noRef
        ? bill.fromAssetId
        : bill.assetId;

    final item = ReimburseBillItem(
      recordId: bill.recordId,
      bookId: bill.bookId,
      recordTime: bill.recordTime,
      createDate: bill.createDate,
      categoryId: bill.categoryId,
      fundingAssetId: fundingAssetId,
      remark: bill.remark,
      currencyCode: currencyCode,
      originMinor: effectiveOriginMinor,
      reimbursedMinor: reimbursedMinor,
      receiptIds: receiptIds,
    );

    totalOriginMinor += toBase(item.originMinor, item.currencyCode);
    reimbursedTotalMinor += toBase(item.reimbursedMinor, item.currencyCode);

    if (item.isSettled) {
      settled.add(item);
    } else {
      pending.add(item);
      pendingTotalMinor += toBase(item.remainingMinor, item.currencyCode);
    }
  }

  pending.sort(_compareReimburseItemsDesc);
  settled.sort(_compareReimburseItemsDesc);

  return ReimburseOverview(
    pendingItems: pending,
    settledItems: settled,
    pendingTotalMinor: pendingTotalMinor,
    reimbursedTotalMinor: reimbursedTotalMinor,
    totalOriginMinor: totalOriginMinor,
  );
}

int _compareReimburseItemsDesc(ReimburseBillItem a, ReimburseBillItem b) {
  final byTime = b.recordTime.compareTo(a.recordTime);
  if (byTime != 0) return byTime;
  final byCreate = (b.createDate ?? 0).compareTo(a.createDate ?? 0);
  if (byCreate != 0) return byCreate;
  return b.recordId.compareTo(a.recordId);
}

RecordRelations _parseRelationsSafe(String? relInfo) {
  try {
    return RecordRelations.parse(relInfo);
  } on Object {
    return RecordRelations();
  }
}

CurrencySnapshot? _parseCurrencySafe(String? extraInfo) {
  try {
    return RecordExtra.parse(extraInfo).currency;
  } on Object {
    return null;
  }
}

String _resolveCurrencyCode({
  required CurrencySnapshot? snap,
  required String? fallbackCurrencyCode,
  required String baseCurrencyCode,
}) {
  // Funding account currency (`ac`) governs booked balance & settlement.
  final ac = normalizeCurrency(snap?.assetCode);
  if (ac != null) return ac;
  final fb = normalizeCurrency(fallbackCurrencyCode);
  if (fb != null) return fb;
  final sc = normalizeCurrency(snap?.sourceCode);
  if (sc != null) return sc;
  return normalizeCurrency(baseCurrencyCode) ?? 'CNY';
}
