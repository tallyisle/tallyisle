import '../../data/db/database.dart';
import '../../domain/ledger/record_extra.dart';
import '../../domain/model/codes.dart';
import '../common/common.dart';

final class RecordLabel {
  const RecordLabel(this.title, this.subtitle, this.amount);
  final String title;
  final String subtitle;
  final String amount;
}

String assetName(List<Asset> assets, int id) => id == noRef
    ? '无账户'
    : assets.where((a) => a.id == id).firstOrNull?.name ?? '账户已删除';

String categoryName(List<RecordCategory> categories, int id) {
  final cat = categories.where((c) => c.id == id).firstOrNull;
  if (cat == null) return '未分类';
  if (cat.parentCatId != noRef && cat.parentCatId != -1) {
    final parent = categories.where((c) => c.id == cat.parentCatId).firstOrNull;
    if (parent != null) {
      return '${parent.name} · ${cat.name}';
    }
  }
  return cat.name;
}

/// Adds the entered foreign amount ("USD 100.00") when a bill was recorded in
/// another currency than the one it was booked in.
RecordLabel recordLabel(
  LedgerRecord r,
  List<RecordCategory> categories,
  List<Asset> assets,
) {
  final label = _recordLabel(r, categories, assets);
  final CurrencySnapshot? snap;
  try {
    snap = RecordExtra.parse(r.extraInfo).currency;
  } on Object {
    return label;
  }
  if (snap == null ||
      !snap.isValid ||
      snap.assetCode == null ||
      snap.sourceCode.trim().toUpperCase() ==
          snap.assetCode!.trim().toUpperCase()) {
    return label;
  }
  final fx = r.type == RecordType.transfer && snap.assetNet != null
      ? '转入 ${snap.assetCode} ${formatMinor(snap.assetNet!)}'
      : '${snap.sourceCode} ${formatMinor(snap.sourceGross)}';
  return RecordLabel(
    label.title,
    label.subtitle.isEmpty ? fx : '${label.subtitle} · $fx',
    label.amount,
  );
}

RecordLabel _recordLabel(
  LedgerRecord r,
  List<RecordCategory> categories,
  List<Asset> assets,
) {
  final amount = formatMinor(r.moneyMinor);
  if ((r.type == RecordType.expense || r.type == RecordType.income) &&
      r.moneyMinor < BigInt.zero) {
    // Refund child: money flows back in the opposite direction.
    return RecordLabel(
      '退款 · ${categoryName(categories, r.recordCatId)}',
      [
        if (r.assetId != noRef) assetName(assets, r.assetId),
        r.remark,
      ].where((s) => s.isNotEmpty).join(' · '),
      '${r.type == RecordType.expense ? '+' : '-'}${formatMinor(-r.moneyMinor)}',
    );
  }
  switch (r.type) {
    case RecordType.expense:
      return RecordLabel(
        categoryName(categories, r.recordCatId),
        [
          if (r.assetId != noRef) assetName(assets, r.assetId),
          r.remark,
        ].where((s) => s.isNotEmpty).join(' · '),
        '-$amount',
      );
    case RecordType.income:
      return RecordLabel(
        categoryName(categories, r.recordCatId),
        [
          if (r.assetId != noRef) assetName(assets, r.assetId),
          r.remark,
        ].where((s) => s.isNotEmpty).join(' · '),
        '+$amount',
      );
    case RecordType.transfer:
      return RecordLabel(
        '转账',
        '${assetName(assets, r.fromAssetId)} → ${assetName(assets, r.toAssetId)}'
            '${r.remark.isEmpty ? '' : ' · ${r.remark}'}',
        amount,
      );
    case RecordType.fee:
      return RecordLabel(
        '手续费',
        [
          assetName(assets, r.assetId),
          r.remark,
        ].where((s) => s.isNotEmpty).join(' · '),
        '-$amount',
      );
    case RecordType.reimbursable:
      return RecordLabel(
        '${categoryName(categories, r.recordCatId)}（报销）',
        [
          if (r.fromAssetId != noRef) assetName(assets, r.fromAssetId),
          r.remark,
        ].where((s) => s.isNotEmpty).join(' · '),
        '-$amount',
      );
    case RecordType.reimburseReceipt:
      return RecordLabel(
        '报销收款',
        [
          assetName(assets, r.assetId),
          r.remark,
        ].where((s) => s.isNotEmpty).join(' · '),
        '+$amount',
      );
    case RecordType.advanceIncome:
      final settled = RecordExtra.parse(r.extraInfo).advance != null;
      return RecordLabel(
        '${categoryName(categories, r.recordCatId)}（预收·${settled ? '已结算' : '待结算'}）',
        [
          if (r.assetId != noRef) assetName(assets, r.assetId),
          r.remark,
        ].where((s) => s.isNotEmpty).join(' · '),
        '+$amount',
      );
    case RecordType.advanceExpense:
      final settled = RecordExtra.parse(r.extraInfo).advance != null;
      return RecordLabel(
        '${categoryName(categories, r.recordCatId)}（预支·${settled ? '已结算' : '待结算'}）',
        [
          if (r.assetId != noRef) assetName(assets, r.assetId),
          r.remark,
        ].where((s) => s.isNotEmpty).join(' · '),
        '-$amount',
      );
    case RecordType.balanceAdjust:
      return RecordLabel(
        '余额调整',
        [
          if (r.fromAssetId != noRef) assetName(assets, r.fromAssetId),
          r.remark,
        ].where((s) => s.isNotEmpty).join(' · '),
        '${r.moneyMinor < BigInt.zero ? '' : '+'}${formatMinor(r.moneyMinor)}',
      );
    default:
      return RecordLabel(RecordType.names[r.type] ?? '账单', r.remark, amount);
  }
}
