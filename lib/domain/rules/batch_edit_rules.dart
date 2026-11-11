import '../../core/failure.dart';
import '../ledger/record_extra.dart';
import '../ledger/record_relations.dart';
import '../model/codes.dart';
import 'asset_overview.dart' show normalizeCurrency;
import 'currency_rates.dart' show baseCurrency;

/// Atomic multi-bill modification specification (F-025).
final class BatchEditPatch {
  BatchEditPatch({
    this.targetCategoryId,
    this.targetAssetId,
    this.targetBookId,
    this.shiftToDate,
    Iterable<String> addTagIds = const [],
    Iterable<String> removeTagIds = const [],
    this.excludeBudget,
    this.excludeExIn,
    this.createMissingTargetCategories = true,
  }) : addTagIds = Set<String>.unmodifiable(
         addTagIds.map((e) => e.trim()).where((e) => e.isNotEmpty),
       ),
       removeTagIds = Set<String>.unmodifiable(
         removeTagIds.map((e) => e.trim()).where((e) => e.isNotEmpty),
       );

  /// Target `record_cat_id` (`null` = keep existing).
  final int? targetCategoryId;

  /// Target funding account (`null` = keep existing, `noRef` `-1` = clear to
  /// 无账户, `> 0` = specific funding asset).
  final int? targetAssetId;

  /// Target `account_book_id` (`null` = keep existing).
  final int? targetBookId;

  /// Target calendar date (`year, month, day` in local time; `null` = keep existing).
  final DateTime? shiftToDate;

  /// Tag IDs to add to every selected record.
  final Set<String> addTagIds;

  /// Tag IDs to remove from every selected record.
  final Set<String> removeTagIds;

  /// New `exclude_budget` flag (`null` = keep existing).
  final bool? excludeBudget;

  /// New `exclude_ex_in` flag (`null` = keep existing).
  final bool? excludeExIn;

  /// When moving bills to [targetBookId] without an explicit [targetCategoryId],
  /// auto-creates missing `(type, name)` categories in the target book if no
  /// matching category exists yet (if false, throws validation error).
  final bool createMissingTargetCategories;

  bool get hasChanges =>
      targetCategoryId != null ||
      targetAssetId != null ||
      targetBookId != null ||
      shiftToDate != null ||
      addTagIds.isNotEmpty ||
      removeTagIds.isNotEmpty ||
      excludeBudget != null ||
      excludeExIn != null;

  Map<String, Object?> toPayloadJson() => {
    'cat': targetCategoryId,
    'asset': targetAssetId,
    'book': targetBookId,
    'date': shiftToDate == null
        ? null
        : '${shiftToDate!.year.toString().padLeft(4, '0')}-'
              '${shiftToDate!.month.toString().padLeft(2, '0')}-'
              '${shiftToDate!.day.toString().padLeft(2, '0')}',
    'addTags': addTagIds.toList()..sort(),
    'rmTags': removeTagIds.toList()..sort(),
    'exBudget': excludeBudget,
    'exExIn': excludeExIn,
    'autoCat': createMissingTargetCategories,
  };
}

/// Which column stores the editable single funding account of a record.
enum BatchAssetSlot { assetColumn, fromAssetColumn, unsupported }

/// Returns the required `record_category.type` (`0` expense / `1` income) for
/// [recordType], or `null` if [recordType] does not support categories (R2).
int? requiredCategoryTypeForRecord(int recordType) => switch (recordType) {
  RecordType.expense ||
  RecordType.reimbursable ||
  RecordType.advanceExpense => 0,
  RecordType.income || RecordType.advanceIncome => 1,
  _ => null,
};

/// True if the record is a refund child or reimbursement receipt child (R1).
bool isLinkedChildRecord({
  required int type,
  required RecordRelations relations,
}) {
  if (type == RecordType.reimburseReceipt) return true;
  final refundOrigin = relations.refunds?.originId;
  if (refundOrigin != null && refundOrigin.trim().isNotEmpty) return true;
  final reimburseOrigin = relations.reimbursements?.originId;
  if (reimburseOrigin != null && reimburseOrigin.trim().isNotEmpty) return true;
  return false;
}

/// True if the record is a transfer-fee child (`type == 12` with `ltfeei.tfobid`) (R1).
bool isTransferFeeChildRecord({
  required int type,
  required RecordRelations relations,
}) =>
    type == RecordType.fee &&
    (relations.transferFee?.parentId.trim().isNotEmpty ?? false);

/// True if the record is an advance bill that has already been settled (R1).
bool isSettledAdvanceRecord({required int type, required RecordExtra extra}) =>
    (type == RecordType.advanceIncome || type == RecordType.advanceExpense) &&
    extra.advance != null;

/// Enforces R1 guards before batch-editing a record.
void validateRecordEditableInBatch({
  required int type,
  required RecordRelations relations,
  required RecordExtra extra,
}) {
  if (isLinkedChildRecord(type: type, relations: relations)) {
    throw const Failure(FailureCode.validation, '选中的账单包含退款或报销收款子记录，无法直接批量编辑');
  }
  if (isTransferFeeChildRecord(type: type, relations: relations)) {
    throw const Failure(FailureCode.validation, '选中的账单包含转账手续费子单，请编辑对应的转账主账单');
  }
  if (isSettledAdvanceRecord(type: type, extra: extra)) {
    throw const Failure(FailureCode.validation, '选中的账单包含已结算的预收/预支记录，不能再编辑');
  }
}

/// Determines how `targetAssetId` applies to a record type (R2).
BatchAssetSlot batchEditableAssetSlot({
  required int type,
  required RecordRelations relations,
}) {
  if (isTransferFeeChildRecord(type: type, relations: relations) ||
      isLinkedChildRecord(type: type, relations: relations)) {
    return BatchAssetSlot.unsupported;
  }
  return switch (type) {
    RecordType.reimbursable => BatchAssetSlot.fromAssetColumn,
    RecordType.expense ||
    RecordType.income ||
    RecordType.advanceIncome ||
    RecordType.advanceExpense ||
    RecordType.reimburseDiff ||
    RecordType.fee ||
    RecordType.installmentPrincipal ||
    RecordType.depositInterest => BatchAssetSlot.assetColumn,
    _ => BatchAssetSlot.unsupported,
  };
}

/// Validates multi-currency compatibility when moving a bill to [targetAssetId] (R2).
///
/// A bill booked in currency `C` (either `curr.ac` if valid FX snapshot exists,
/// or the original asset's currency, with `noRef` defaulting to `CNY`) can only
/// be batch-reassigned to an account with the exact same currency `C`.
void validateBatchAssetCurrencyCompatibility({
  required int oldAssetId,
  required String? oldAssetCurrency,
  required int targetAssetId,
  required String? targetAssetCurrency,
  required CurrencySnapshot? recordCurrency,
}) {
  final oldCode = oldAssetId == noRef
      ? baseCurrency
      : (normalizeCurrency(oldAssetCurrency) ?? baseCurrency);
  final targetCode = targetAssetId == noRef
      ? baseCurrency
      : (normalizeCurrency(targetAssetCurrency) ?? baseCurrency);

  final String bookedCode;
  if (recordCurrency != null &&
      recordCurrency.isValid &&
      recordCurrency.assetCode != null &&
      recordCurrency.assetCode!.trim().isNotEmpty) {
    bookedCode = normalizeCurrency(recordCurrency.assetCode) ?? oldCode;
  } else {
    bookedCode = oldCode;
  }

  if (bookedCode != targetCode) {
    throw Failure(
      FailureCode.validation,
      '目标账户币种（$targetCode）与账单原入账币种（$bookedCode）不一致，无法批量修改账户',
    );
  }
}

/// Shifts [originalTimeMs] to [targetDate] (`year, month, day` in local time)
/// while preserving `hour:minute:second.millisecond` and applying the midnight-safe
/// `+1ms` / `-1ms` transfer-fee child timestamp rule (`02o §2.2`, R3).
({int parentTimeMs, int? feeTimeMs}) shiftRecordDatePreservingClock({
  required int originalTimeMs,
  required DateTime targetDate,
  required bool hasTransferFee,
}) {
  final orig = DateTime.fromMillisecondsSinceEpoch(originalTimeMs);
  final shifted = DateTime(
    targetDate.year,
    targetDate.month,
    targetDate.day,
    orig.hour,
    orig.minute,
    orig.second,
    orig.millisecond,
  );
  var parentTime = shifted.millisecondsSinceEpoch;
  if (!hasTransferFee) {
    return (parentTimeMs: parentTime, feeTimeMs: null);
  }
  final local = DateTime.fromMillisecondsSinceEpoch(parentTime);
  final next = DateTime.fromMillisecondsSinceEpoch(parentTime + 1);
  final int feeTime;
  if (next.day != local.day) {
    feeTime = parentTime;
    parentTime -= 1;
  } else {
    feeTime = parentTime + 1;
  }
  return (parentTimeMs: parentTime, feeTimeMs: feeTime);
}

/// Computes `(existing \ removeTagIds) U addTagIds` with stable deduplicated order.
List<String> mergeBatchTags({
  required Iterable<String> existingTagIds,
  required Set<String> addTagIds,
  required Set<String> removeTagIds,
}) {
  final seen = <String>{};
  final result = <String>[];
  for (final tagId in existingTagIds) {
    final trimmed = tagId.trim();
    if (trimmed.isEmpty) continue;
    if (removeTagIds.contains(trimmed) && !addTagIds.contains(trimmed)) {
      continue;
    }
    if (seen.add(trimmed)) {
      result.add(trimmed);
    }
  }
  final sortedAdds = addTagIds.toList()..sort();
  for (final tagId in sortedAdds) {
    if (seen.add(tagId)) {
      result.add(tagId);
    }
  }
  return result;
}
