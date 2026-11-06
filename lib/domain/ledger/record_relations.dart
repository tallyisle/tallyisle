import 'dart:convert';

import '../../core/failure.dart';

const _corrupt = Failure(FailureCode.corruptData, '账单关联信息格式损坏');

/// Entry of a refund/reimbursement link list (original `LinkedBillInfo`).
/// Amounts are minor units; `lbm` is the absolute linked amount.
final class LinkedBill {
  const LinkedBill({
    required this.billId,
    required this.amount,
    this.assetCode,
    this.assetAmount,
    this.baseCode,
    this.baseAmount,
  });
  final String billId; // lbid
  final BigInt amount; // lbm
  final String? assetCode; // ac
  final BigInt? assetAmount; // am
  final String? baseCode; // bc
  final BigInt? baseAmount; // bm

  Map<String, Object> toJson() => {
    'lbid': billId,
    'lbm': amount.toString(),
    'ac': ?assetCode,
    'am': ?assetAmount?.toString(),
    'bc': ?baseCode,
    'bm': ?baseAmount?.toString(),
  };

  static LinkedBill fromJson(Object? json) {
    if (json is! Map || json['lbid'] is! String) throw _corrupt;
    return LinkedBill(
      billId: json['lbid'] as String,
      amount: _minor(json['lbm']) ?? (throw _corrupt),
      assetCode: json['ac'] as String?,
      assetAmount: _minor(json['am']),
      baseCode: json['bc'] as String?,
      baseAmount: _minor(json['bm']),
    );
  }
}

/// Link block used by refunds (`lrefundi`: rfbinfo/rfobid) and
/// reimbursements (`lreimbursei`: ribinfo/riobid).
final class BillLinks {
  const BillLinks({this.children = const [], this.originId});

  /// On the original bill: the linked child bills.
  final List<LinkedBill> children;

  /// On a child bill: the original bill id.
  final String? originId;

  bool get isEmpty =>
      children.isEmpty && (originId == null || originId!.trim().isEmpty);

  Map<String, Object> toJson(String listKey, String originKey) => {
    if (children.isNotEmpty) listKey: [for (final c in children) c.toJson()],
    if (originId != null && originId!.isNotEmpty) originKey: originId!,
  };

  static BillLinks? fromJson(Object? json, String listKey, String originKey) {
    if (json == null) return null;
    if (json is! Map) throw _corrupt;
    final list = json[listKey];
    return BillLinks(
      children: list == null
          ? const []
          : [for (final item in list as List) LinkedBill.fromJson(item)],
      originId: json[originKey] as String?,
    );
  }
}

/// Transfer fee link (original `ltfeei`).
final class TransferFeeLink {
  const TransferFeeLink({
    required this.feeFromTarget,
    this.repay = false,
    this.parentId = '',
  });

  /// tff: false = fee paid by the outgoing account, true = by the incoming one.
  final bool feeFromTarget;

  /// tfrepay: the transfer repays a credit account.
  final bool repay;

  /// tfobid: "" on the transfer itself, the transfer id on the fee child.
  final String parentId;

  Map<String, Object> toJson() => {
    'tff': feeFromTarget ? 1 : 0,
    'tfrepay': repay,
    'tfobid': parentId,
  };

  static TransferFeeLink? fromJson(Object? json) {
    if (json == null) return null;
    if (json is! Map) throw _corrupt;
    return TransferFeeLink(
      feeFromTarget: json['tff'] == 1,
      repay: json['tfrepay'] == true,
      parentId: (json['tfobid'] as String?) ?? '',
    );
  }
}

/// Typed view over `record.rel_info`; unknown keys (e.g. `lc`) are preserved.
final class RecordRelations {
  RecordRelations([Map<String, Object?>? raw]) : raw = {...?raw};
  final Map<String, Object?> raw;

  BillLinks? get refunds =>
      BillLinks.fromJson(raw['lrefundi'], 'rfbinfo', 'rfobid');
  set refunds(BillLinks? v) =>
      _put('lrefundi', v?.toJson('rfbinfo', 'rfobid'), v);

  BillLinks? get reimbursements =>
      BillLinks.fromJson(raw['lreimbursei'], 'ribinfo', 'riobid');
  set reimbursements(BillLinks? v) =>
      _put('lreimbursei', v?.toJson('ribinfo', 'riobid'), v);

  TransferFeeLink? get transferFee => TransferFeeLink.fromJson(raw['ltfeei']);
  set transferFee(TransferFeeLink? v) {
    if (v == null) {
      raw.remove('ltfeei');
    } else {
      raw['ltfeei'] = v.toJson();
    }
  }

  void _put(String key, Map<String, Object>? json, BillLinks? links) {
    if (links == null || links.isEmpty) {
      raw.remove(key);
    } else {
      raw[key] = json;
    }
  }

  static RecordRelations parse(String? text) {
    if (text == null || text.isEmpty) return RecordRelations();
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, Object?>) throw _corrupt;
    return RecordRelations(decoded);
  }

  String? encode() => raw.isEmpty ? null : jsonEncode(raw);
}

BigInt? _minor(Object? value) {
  if (value == null) return null;
  if (value is String) {
    final parsed = BigInt.tryParse(value);
    if (parsed != null) return parsed;
  }
  throw _corrupt;
}
