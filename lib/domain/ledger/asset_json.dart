import 'dart:convert';

import '../../core/failure.dart';

/// `credit_info.bill_day` / `repayment_day` value meaning "last day of month".
const endOfMonthDay = -2;

/// "Not set" for bill/repayment day.
const unsetDay = -1;

const _corrupt = Failure(FailureCode.corruptData, '账户附加信息格式损坏');

Map<String, Object?> _decode(String? text) {
  if (text == null || text.trim().isEmpty) return {};
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    throw _corrupt;
  }
  if (decoded is! Map<String, Object?>) throw _corrupt;
  return decoded;
}

/// Minor units are written as JSON strings; legacy numbers are accepted.
BigInt? _minor(Object? v) {
  if (v == null) return null;
  if (v is String) return BigInt.tryParse(v) ?? (throw _corrupt);
  if (v is int) return BigInt.from(v);
  throw _corrupt;
}

int? _int(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  throw _corrupt;
}

bool? _bool(Object? v) {
  if (v == null) return null;
  if (v is bool) return v;
  throw _corrupt;
}

/// One uncredited installment in `credit_info.inst`.
final class UncreditedInstallment {
  const UncreditedInstallment({
    required this.id,
    required this.principal,
    required this.interest,
    this.principalCounted = false,
    this.interestCounted = false,
  });
  final String id; // iid
  final BigInt principal; // b
  final BigInt interest; // i
  final bool principalCounted; // cb
  final bool interestCounted; // ci

  Map<String, Object> toJson() => {
    'iid': id,
    'b': principal.toString(),
    'i': interest.toString(),
    'cb': principalCounted,
    'ci': interestCounted,
  };

  static UncreditedInstallment fromJson(Object? json) {
    if (json is! Map) throw _corrupt;
    return UncreditedInstallment(
      id: '${json['iid'] ?? ''}',
      principal: _minor(json['b']) ?? BigInt.zero,
      interest: _minor(json['i']) ?? BigInt.zero,
      principalCounted: _bool(json['cb']) ?? false,
      interestCounted: _bool(json['ci']) ?? false,
    );
  }
}

/// Typed view of `asset.credit_info` (docs/modules/credit-account.md §2).
/// Unknown keys survive a rewrite.
final class CreditInfo {
  CreditInfo([Map<String, Object?>? raw]) : raw = {...?raw};
  final Map<String, Object?> raw;

  static CreditInfo parse(String? text) => CreditInfo(_decode(text));
  String? encode() => raw.isEmpty ? null : jsonEncode(raw);

  /// 1..28, [endOfMonthDay] or [unsetDay].
  int get billDay => _int(raw['bill_day']) ?? unsetDay;
  set billDay(int v) => raw['bill_day'] = v;

  /// Fixed day (1..28 / [endOfMonthDay]) or N days after the bill day.
  int get repaymentDay => _int(raw['repayment_day']) ?? unsetDay;
  set repaymentDay(int v) => raw['repayment_day'] = v;

  bool get repaymentAfterBillDay =>
      _bool(raw['repayment_day_after_bd']) ?? false;
  set repaymentAfterBillDay(bool v) => raw['repayment_day_after_bd'] = v;

  /// Whether spending on the bill day belongs to the current statement.
  bool get billDayCounted => _bool(raw['bill_day_count']) ?? true;
  set billDayCounted(bool v) => raw['bill_day_count'] = v;

  /// Interest-free reminder switch (null = true).
  bool get interestFreeReminder => _bool(raw['ifc']) ?? true;

  /// Null when absent (legacy `installment` then applies).
  List<UncreditedInstallment>? get installments {
    final v = raw['inst'];
    if (v == null) return null;
    if (v is! List) throw _corrupt;
    return [for (final e in v) UncreditedInstallment.fromJson(e)];
  }

  set installments(List<UncreditedInstallment>? v) {
    if (v == null) {
      raw.remove('inst');
    } else {
      raw['inst'] = [for (final e in v) e.toJson()];
    }
  }

  /// Primary card id of a shared-limit group.
  int? get sharedLimitAssetId => _int(raw['share_amt_asset']);
  set sharedLimitAssetId(int? v) {
    if (v == null) {
      raw.remove('share_amt_asset');
    } else {
      raw['share_amt_asset'] = v;
    }
  }

  bool get configured => billDay != unsetDay;
}

/// One temporary credit limit in `asset.extra_info.temp_amt`.
final class TempAmount {
  const TempAmount({
    required this.amount,
    required this.deadline,
    this.updatedAt = 0,
  });
  final BigInt amount; // m
  final int deadline; // ddl (ms)
  final int updatedAt; // upd (ms)

  Map<String, Object> toJson() => {
    'm': amount.toString(),
    'ddl': deadline,
    'upd': updatedAt,
  };

  static TempAmount fromJson(Object? json) {
    if (json is! Map) throw _corrupt;
    return TempAmount(
      amount: _minor(json['m']) ?? BigInt.zero,
      deadline: _int(json['ddl']) ?? 0,
      updatedAt: _int(json['upd']) ?? 0,
    );
  }
}

/// Typed view of `asset.extra_info` (docs/modules/credit-account.md §2).
final class AssetExtra {
  AssetExtra([Map<String, Object?>? raw]) : raw = {...?raw};
  final Map<String, Object?> raw;

  static AssetExtra parse(String? text) => AssetExtra(_decode(text));
  String? encode() => raw.isEmpty ? null : jsonEncode(raw);

  /// Default account a credit card is repaid from.
  int? get repayAssetId => _int(raw['repay_asset']);
  set repayAssetId(int? v) {
    if (v == null) {
      raw.remove('repay_asset');
    } else {
      raw['repay_asset'] = v;
    }
  }

  List<TempAmount> get tempAmounts {
    final v = raw['temp_amt'];
    if (v == null) return const [];
    if (v is! List) throw _corrupt;
    return [for (final e in v) TempAmount.fromJson(e)];
  }

  /// At most 10 entries are kept (original limit).
  set tempAmounts(List<TempAmount> v) {
    if (v.isEmpty) {
      raw.remove('temp_amt');
    } else {
      raw['temp_amt'] = [for (final e in v.take(10)) e.toJson()];
    }
  }

  /// Sum of temporary limits whose deadline has not passed (R6).
  BigInt activeTempAmount(int nowMs) => tempAmounts
      .where((t) => t.deadline >= nowMs)
      .fold(BigInt.zero, (s, t) => s + t.amount);
}
