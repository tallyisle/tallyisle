import 'dart:convert';

import '../../core/failure.dart';

/// Multi-currency snapshot stored in `record.extra_info.curr`
/// (original `BillCurrencyExtra`, ledger-catalog §4).
///
/// Key names follow the original; amounts are minor units (2 decimals)
/// serialized as JSON strings so they survive JavaScript number limits.
final class CurrencySnapshot {
  const CurrencySnapshot({
    required this.sourceCode,
    required this.sourceGross,
    this.assetCode,
    this.assetNet,
    this.baseCode,
    this.baseAmount,
    this.assetDiscount,
    this.baseDiscount,
  });

  final String sourceCode; // sc
  final BigInt sourceGross; // sm: source amount before discount
  final String? assetCode; // ac
  final BigInt? assetNet; // am: net amount in the asset currency
  final String? baseCode; // bc
  final BigInt? baseAmount; // bm
  final BigInt? assetDiscount; // dam
  final BigInt? baseDiscount; // dbm

  bool get isValid => sourceCode.trim().isNotEmpty;

  Map<String, Object> toJson() => {
    'sc': sourceCode,
    'sm': sourceGross.toString(),
    'ac': ?assetCode,
    'am': ?assetNet?.toString(),
    'bc': ?baseCode,
    'bm': ?baseAmount?.toString(),
    'dam': ?assetDiscount?.toString(),
    'dbm': ?baseDiscount?.toString(),
  };

  static CurrencySnapshot? fromJson(Object? json) {
    if (json == null) return null;
    if (json is! Map) throw _corrupt;
    final sc = json['sc'];
    final sm = _minor(json['sm']);
    if (sc is! String || sm == null) return null;
    return CurrencySnapshot(
      sourceCode: sc,
      sourceGross: sm,
      assetCode: json['ac'] as String?,
      assetNet: _minor(json['am']),
      baseCode: json['bc'] as String?,
      baseAmount: _minor(json['bm']),
      assetDiscount: _minor(json['dam']),
      baseDiscount: _minor(json['dbm']),
    );
  }
}

const _corrupt = Failure(FailureCode.corruptData, '账单附加信息格式损坏');

BigInt? _minor(Object? value) {
  if (value == null) return null;
  if (value is String) {
    final parsed = BigInt.tryParse(value);
    if (parsed != null) return parsed;
  }
  throw _corrupt;
}

/// Typed view of `record.extra_info`. Unknown keys are preserved on rewrite.
final class RecordExtra {
  RecordExtra([Map<String, Object?>? raw]) : raw = {...?raw};

  final Map<String, Object?> raw;

  CurrencySnapshot? get currency => CurrencySnapshot.fromJson(raw['curr']);
  set currency(CurrencySnapshot? value) {
    if (value == null) {
      raw.remove('curr');
    } else {
      raw['curr'] = value.toJson();
    }
  }

  static RecordExtra parse(String? text) {
    if (text == null || text.isEmpty) return RecordExtra();
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, Object?>) throw _corrupt;
    return RecordExtra(decoded);
  }

  String? encode() => raw.isEmpty ? null : jsonEncode(raw);
}
