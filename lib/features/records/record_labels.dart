import '../../data/db/database.dart';
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

String categoryName(List<RecordCategory> categories, int id) =>
    categories.where((c) => c.id == id).firstOrNull?.name ?? '未分类';

RecordLabel recordLabel(
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
    default:
      return RecordLabel(RecordType.names[r.type] ?? '账单', r.remark, amount);
  }
}
