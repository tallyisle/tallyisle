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

RecordLabel recordLabel(
  LedgerRecord r,
  List<RecordCategory> categories,
  List<Asset> assets,
) {
  final amount = formatMinor(r.moneyMinor);
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
    default:
      return RecordLabel(RecordType.names[r.type] ?? '账单', r.remark, amount);
  }
}
