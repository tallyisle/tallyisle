import 'dart:convert';

import '../../core/failure.dart';
import '../../core/money.dart';
import '../model/codes.dart';

/// Original `auto_map.key` sentinel for draft inbox rows (`F-020`).
const String autoMapDraftKey = 'KEY_DRAFT';

/// Original `auto_map.key` sentinel for cloud accessibility node config (`F-020`).
const String autoMapConfigKey = 'KEY_CONFIG';

/// Returns true when [key] represents a user mapping rule row in `auto_map`.
bool isAutoMapRuleKey(String key) {
  final normalized = key.trim().toUpperCase();
  return normalized.isNotEmpty &&
      normalized != autoMapDraftKey &&
      normalized != autoMapConfigKey;
}

/// Validates and trims a user-defined `auto_map` rule keyword (`F-020` R2).
String validateAutoMapRuleKey(String rawKey) {
  final trimmed = rawKey.trim();
  if (trimmed.isEmpty || trimmed.length > 100) {
    throw const Failure(FailureCode.validation, '匹配关键词须为 1–100 字');
  }
  final upper = trimmed.toUpperCase();
  if (upper == autoMapDraftKey || upper == autoMapConfigKey) {
    throw const Failure(FailureCode.validation, '该关键词为系统保留标识，请更换关键词');
  }
  return trimmed;
}

int? _normalizeOptionalId(Object? value) {
  if (value == null) return null;
  final int? parsed = switch (value) {
    final int v => v,
    final String s => int.tryParse(s.trim()),
    _ => null,
  };
  if (parsed == null || parsed <= 0) return null;
  return parsed;
}

int? _normalizeRecordType(Object? value) {
  if (value == null) return null;
  final int? parsed = switch (value) {
    final int v => v,
    final String s => int.tryParse(s.trim()),
    _ => null,
  };
  if (parsed == null) return null;
  if (parsed == RecordType.expense ||
      parsed == RecordType.income ||
      parsed == RecordType.transfer) {
    return parsed;
  }
  return null;
}

/// Parses an integer minor-unit field or legacy decimal yuan JSON field into `Money`
/// using pure string / `BigInt` math (`ADR-011`, zero `double` arithmetic).
Money? _parseDraftMoney({
  required Object? minorField,
  required Object? legacyYuanField,
  String currency = 'CNY',
}) {
  if (minorField != null) {
    final text = minorField.toString().trim();
    if (text.isNotEmpty) {
      final parsed = BigInt.tryParse(text);
      if (parsed == null) {
        throw const Failure(FailureCode.corruptData, '草稿金额数据损坏');
      }
      return Money.minor(parsed.abs(), currency);
    }
  }
  if (legacyYuanField != null) {
    final rawText = legacyYuanField.toString().trim();
    if (rawText.isEmpty) return null;
    final minor = _decimalOrScientificToMinor(rawText);
    return Money.minor(minor.abs(), currency);
  }
  return null;
}

BigInt _decimalOrScientificToMinor(String rawText) {
  var text = rawText.trim().replaceAll(',', '');
  if (text.startsWith('+')) text = text.substring(1).trim();
  final expMatch = RegExp(
    r'^(-?)(\d+)(?:\.(\d+))?[eE]([+-]?\d+)$',
  ).firstMatch(text);
  if (expMatch != null) {
    final neg = expMatch.group(1) == '-';
    final intPart = expMatch.group(2)!;
    final fracPart = expMatch.group(3) ?? '';
    final exp = int.parse(expMatch.group(4)!);
    final coeff =
        BigInt.parse('$intPart$fracPart') *
        (neg ? BigInt.from(-1) : BigInt.one);
    final netScale = fracPart.length - exp;
    if (netScale <= 0) {
      final shift = -netScale + Money.ledgerScale;
      if (shift > 30) {
        throw const Failure(FailureCode.validation, '金额超出可存储范围');
      }
      return coeff * powerOfTen(shift);
    }
    return DecimalValue(
      coeff,
      netScale,
    ).unitsAt(Money.ledgerScale, rounding: RoundingMode.halfUp);
  }
  return DecimalValue.parse(
    text,
  ).unitsAt(Money.ledgerScale, rounding: RoundingMode.halfUp);
}

/// Typed representation of `auto_map.map_info` JSON (`F-020`).
///
/// Preserves original Room/Gson keys `mapAssetId` and `mapCategoryId` so `.penny`
/// imported rows round-trip seamlessly.
final class AutoMapInfo {
  AutoMapInfo({
    this.mapAssetId,
    this.mapCategoryId,
    this.bookId,
    this.recordType,
    this.toAssetId,
    this.remark,
    Map<String, Object?>? raw,
  }) : raw = {...?raw};

  final int? mapAssetId;
  final int? mapCategoryId;
  final int? bookId;
  final int? recordType;
  final int? toAssetId;
  final String? remark;
  final Map<String, Object?> raw;

  bool get hasAnyMapping =>
      mapAssetId != null ||
      mapCategoryId != null ||
      toAssetId != null ||
      bookId != null ||
      recordType != null ||
      (remark != null && remark!.trim().isNotEmpty);

  factory AutoMapInfo.parse(String? jsonText) {
    if (jsonText == null || jsonText.trim().isEmpty) {
      return AutoMapInfo();
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(jsonText);
    } on FormatException {
      return AutoMapInfo();
    }
    if (decoded is! Map) return AutoMapInfo();
    final map = <String, Object?>{
      for (final e in decoded.entries) '${e.key}': e.value,
    };
    final remarkVal = map['remark'];
    return AutoMapInfo(
      mapAssetId: _normalizeOptionalId(map['mapAssetId'] ?? map['assetId']),
      mapCategoryId: _normalizeOptionalId(
        map['mapCategoryId'] ?? map['categoryId'],
      ),
      bookId: _normalizeOptionalId(map['bookId']),
      recordType: _normalizeRecordType(map['recordType'] ?? map['type']),
      toAssetId: _normalizeOptionalId(map['toAssetId'] ?? map['mapAssetId2']),
      remark: remarkVal is String && remarkVal.trim().isNotEmpty
          ? remarkVal.trim()
          : null,
      raw: map,
    );
  }

  String encode() {
    final out = <String, Object?>{...raw};
    out
      ..remove('assetId')
      ..remove('categoryId')
      ..remove('type')
      ..remove('mapAssetId2');
    if (mapAssetId != null) {
      out['mapAssetId'] = mapAssetId;
    } else {
      out.remove('mapAssetId');
    }
    if (mapCategoryId != null) {
      out['mapCategoryId'] = mapCategoryId;
    } else {
      out.remove('mapCategoryId');
    }
    if (bookId != null) {
      out['bookId'] = bookId;
    } else {
      out.remove('bookId');
    }
    if (recordType != null) {
      out['recordType'] = recordType;
    } else {
      out.remove('recordType');
    }
    if (toAssetId != null) {
      out['toAssetId'] = toAssetId;
    } else {
      out.remove('toAssetId');
    }
    if (remark != null && remark!.trim().isNotEmpty) {
      out['remark'] = remark!.trim();
    } else {
      out.remove('remark');
    }
    return jsonEncode(out);
  }
}

/// Domain entity for a keyword mapping rule stored in `auto_map`.
final class AutoMapRule {
  const AutoMapRule({required this.id, required this.key, required this.info});

  final int id;
  final String key;
  final AutoMapInfo info;
}

/// Combined mapping result resolved across all matching [AutoMapRule]s.
final class AutoMapMatchResult {
  const AutoMapMatchResult({
    this.matchedRules = const [],
    this.assetId,
    this.toAssetId,
    this.categoryId,
    this.bookId,
    this.recordType,
    this.remark,
  });

  final List<AutoMapRule> matchedRules;
  final int? assetId;
  final int? toAssetId;
  final int? categoryId;
  final int? bookId;
  final int? recordType;
  final String? remark;

  bool get isMatched => matchedRules.isNotEmpty;
}

/// Sorts rules longest-keyword-first (ties broken by ascending `id`) per `F-020` R2.
List<AutoMapRule> sortAutoMapRulesForMatching(Iterable<AutoMapRule> rules) {
  final list = rules.where((r) => isAutoMapRuleKey(r.key)).toList();
  list.sort((a, b) {
    final lenCmp = b.key.trim().length.compareTo(a.key.trim().length);
    if (lenCmp != 0) return lenCmp;
    return a.id.compareTo(b.id);
  });
  return list;
}

/// Matches [candidateTexts] against [rules] (case-insensitive substring match)
/// and merges non-null target IDs in priority order.
AutoMapMatchResult matchAutoMapRules(
  Iterable<AutoMapRule> rules,
  Iterable<String> candidateTexts,
) {
  final normalizedHaystacks = candidateTexts
      .map((t) => t.trim().toLowerCase())
      .where((t) => t.isNotEmpty)
      .toList(growable: false);
  if (normalizedHaystacks.isEmpty) return const AutoMapMatchResult();

  final ordered = sortAutoMapRulesForMatching(rules);
  final matched = <AutoMapRule>[];
  int? assetId;
  int? toAssetId;
  int? categoryId;
  int? bookId;
  int? recordType;
  String? remark;

  for (final rule in ordered) {
    final needle = rule.key.trim().toLowerCase();
    if (needle.isEmpty) continue;
    final hit = normalizedHaystacks.any((h) => h.contains(needle));
    if (!hit) continue;
    matched.add(rule);
    assetId ??= rule.info.mapAssetId;
    toAssetId ??= rule.info.toAssetId;
    categoryId ??= rule.info.mapCategoryId;
    bookId ??= rule.info.bookId;
    recordType ??= rule.info.recordType;
    remark ??= rule.info.remark;
  }

  return AutoMapMatchResult(
    matchedRules: matched,
    assetId: assetId,
    toAssetId: toAssetId,
    categoryId: categoryId,
    bookId: bookId,
    recordType: recordType,
    remark: remark,
  );
}

/// Friendly Chinese app name for known Android payment packages.
String friendlyAutoBillAppName(String? appOrPackage) {
  final raw = appOrPackage?.trim() ?? '';
  if (raw.isEmpty) return '自动识别';
  switch (raw) {
    case 'com.tencent.mm':
      return '微信';
    case 'com.eg.android.AlipayGphone':
      return '支付宝';
    case 'com.unionpay':
      return '云闪付';
    case 'cn.gov.pbc.dcep':
      return '数字人民币';
    case 'com.jingdong.app.mall':
    case 'com.jd.jrapp':
      return '京东';
    case 'com.sankuai.meituan':
    case 'com.sankuai.meituan.takeoutnew':
      return '美团';
    case 'com.xunmeng.pinduoduo':
      return '拼多多';
    case 'com.android.mms':
    case 'com.google.android.apps.messaging':
      return '短信';
    default:
      return raw;
  }
}

/// Typed representation of a pending draft stored in `auto_map` (`key = 'KEY_DRAFT'`).
///
/// Compatible with both TallyIsle integer-minor JSON (`moneyMinor`) and `.penny`
/// imported `AutoBillInfo` JSON (`bt`, `money`, `discf`, `date`, `app`, `remark`,
/// `a1`, `a2`, `cate`, `isrefund`).
final class AutoBillDraft {
  AutoBillDraft({
    this.id,
    this.recordType = RecordType.expense,
    required this.money,
    this.discount,
    required this.recordTimeMs,
    this.sourceApp = '',
    this.remarks = const [],
    this.accountHint1,
    this.accountHint2,
    this.categoryHint,
    this.bookId,
    this.categoryId,
    this.assetId,
    this.toAssetId,
    this.rawText,
    this.fingerprint,
    this.isRefund = false,
    Map<String, Object?>? raw,
  }) : raw = {...?raw};

  final int? id;
  final int recordType;
  final Money money;
  final Money? discount;
  final int recordTimeMs;
  final String sourceApp;
  final List<String> remarks;
  final String? accountHint1;
  final String? accountHint2;
  final String? categoryHint;
  final int? bookId;
  final int? categoryId;
  final int? assetId;
  final int? toAssetId;
  final String? rawText;
  final String? fingerprint;
  final bool isRefund;
  final Map<String, Object?> raw;

  String get displayApp => friendlyAutoBillAppName(sourceApp);

  String get primaryRemark {
    final cleaned = remarks
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    return cleaned.join(' · ');
  }

  Money get netMoney {
    final d = discount;
    if (d != null &&
        !d.isZero &&
        d.units <= money.units &&
        (recordType == RecordType.expense || recordType == RecordType.income)) {
      return money - d;
    }
    return money;
  }

  AutoBillDraft copyWith({
    int? id,
    int? recordType,
    Money? money,
    Money? discount,
    int? recordTimeMs,
    String? sourceApp,
    List<String>? remarks,
    String? accountHint1,
    String? accountHint2,
    String? categoryHint,
    int? bookId,
    int? categoryId,
    int? assetId,
    int? toAssetId,
    String? rawText,
    String? fingerprint,
  }) => AutoBillDraft(
    id: id ?? this.id,
    recordType: recordType ?? this.recordType,
    money: money ?? this.money,
    discount: discount ?? this.discount,
    recordTimeMs: recordTimeMs ?? this.recordTimeMs,
    sourceApp: sourceApp ?? this.sourceApp,
    remarks: remarks ?? this.remarks,
    accountHint1: accountHint1 ?? this.accountHint1,
    accountHint2: accountHint2 ?? this.accountHint2,
    categoryHint: categoryHint ?? this.categoryHint,
    bookId: bookId ?? this.bookId,
    categoryId: categoryId ?? this.categoryId,
    assetId: assetId ?? this.assetId,
    toAssetId: toAssetId ?? this.toAssetId,
    rawText: rawText ?? this.rawText,
    fingerprint: fingerprint ?? this.fingerprint,
    isRefund: isRefund,
    raw: raw,
  );

  factory AutoBillDraft.parse(
    String? jsonText, {
    int? id,
    required int fallbackNowMs,
  }) {
    if (jsonText == null || jsonText.trim().isEmpty) {
      throw const Failure(FailureCode.corruptData, '自动记账草稿为空');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(jsonText);
    } on FormatException {
      throw const Failure(FailureCode.corruptData, '自动记账草稿 JSON 格式损坏');
    }
    if (decoded is! Map) {
      throw const Failure(FailureCode.corruptData, '自动记账草稿结构无效');
    }
    final map = <String, Object?>{
      for (final e in decoded.entries) '${e.key}': e.value,
    };

    final bt =
        _normalizeRecordType(map['bt'] ?? map['type']) ?? RecordType.expense;
    final money =
        _parseDraftMoney(
          minorField: map['moneyMinor'],
          legacyYuanField: map['money'],
        ) ??
        Money.zero();
    final discount = _parseDraftMoney(
      minorField: map['discountMinor'],
      legacyYuanField: map['discf'],
    );

    final rawDate = map['date'];
    final dateMs = switch (rawDate) {
      final int v when v > 0 => v,
      final String s => int.tryParse(s.trim()) ?? fallbackNowMs,
      _ => fallbackNowMs,
    };

    final rawRemark = map['remark'];
    final remarks = <String>[
      if (rawRemark is List) ...[
        for (final item in rawRemark)
          if (item != null && '$item'.trim().isNotEmpty) '$item'.trim(),
      ] else if (rawRemark is String && rawRemark.trim().isNotEmpty)
        rawRemark.trim(),
    ];

    String? optStr(String key) {
      final v = map[key];
      if (v == null) return null;
      final s = '$v'.trim();
      return s.isEmpty ? null : s;
    }

    return AutoBillDraft(
      id: id,
      recordType: bt,
      money: money,
      discount: discount != null && !discount.isZero ? discount : null,
      recordTimeMs: dateMs,
      sourceApp: optStr('app') ?? '',
      remarks: remarks,
      accountHint1: optStr('a1'),
      accountHint2: optStr('a2'),
      categoryHint: optStr('cate'),
      bookId: _normalizeOptionalId(map['bookId']),
      categoryId:
          _normalizeOptionalId(map['categoryId']) ??
          _normalizeOptionalId(map['cate']),
      assetId:
          _normalizeOptionalId(map['assetId']) ??
          _normalizeOptionalId(map['a1']),
      toAssetId:
          _normalizeOptionalId(map['toAssetId']) ??
          _normalizeOptionalId(map['a2']),
      rawText: optStr('rawText'),
      fingerprint: optStr('fingerprint'),
      isRefund: map['isrefund'] == true,
      raw: map,
    );
  }

  String encode() {
    final out = <String, Object?>{
      ...raw,
      'v': 1,
      'bt': recordType,
      'moneyMinor': money.storageMinor.toString(),
      'date': recordTimeMs,
      'app': sourceApp,
      'remark': remarks,
    };
    out
      ..remove('money')
      ..remove('discf');
    if (discount != null && !discount!.isZero) {
      out['discountMinor'] = discount!.storageMinor.toString();
    } else {
      out.remove('discountMinor');
    }
    void putOrRemove(String key, Object? val) {
      if (val != null) {
        out[key] = val;
      } else {
        out.remove(key);
      }
    }

    putOrRemove('a1', accountHint1);
    putOrRemove('a2', accountHint2);
    putOrRemove('cate', categoryHint);
    putOrRemove('bookId', bookId);
    putOrRemove('categoryId', categoryId);
    putOrRemove('assetId', assetId);
    putOrRemove('toAssetId', toAssetId);
    putOrRemove('rawText', rawText);
    putOrRemove('fingerprint', fingerprint);
    if (isRefund) {
      out['isrefund'] = true;
    }
    return jsonEncode(out);
  }
}

/// Structured result of parsing a payment notification, SMS, or screen text (`F-020` R3).
final class ParsedPaymentNotification {
  const ParsedPaymentNotification({
    required this.recordType,
    required this.money,
    this.discount,
    required this.recordTimeMs,
    required this.sourceApp,
    required this.merchant,
    this.accountHint1,
    this.accountHint2,
    this.categoryHint,
    required this.rawText,
  });

  final int recordType;
  final Money money;
  final Money? discount;
  final int recordTimeMs;
  final String sourceApp;
  final String merchant;
  final String? accountHint1;
  final String? accountHint2;
  final String? categoryHint;
  final String rawText;
}

/// Parses WeChat Pay, Alipay, UnionPay, and bank SMS payment texts into a
/// structured draft candidate (`F-020` R3). Returns `null` when no valid positive
/// payment amount is present.
ParsedPaymentNotification? parsePaymentText(
  String rawText, {
  String? packageOrApp,
  required int fallbackNowMs,
}) {
  final normalized = rawText.replaceAll('\r\n', '\n').trim();
  if (normalized.isEmpty) return null;

  final lines = normalized
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList(growable: false);
  if (lines.isEmpty) return null;

  final sourceApp = _detectSourceApp(normalized, packageOrApp);
  final discount = _extractDiscount(normalized);
  final extractedAmount = _extractPrimaryAmount(normalized, lines);
  if (extractedAmount == null || extractedAmount.$1.units <= BigInt.zero) {
    return null;
  }

  final recordType = _detectDirection(
    normalized,
    hasNegativeSign: extractedAmount.$2,
    hasPositiveSign: extractedAmount.$3,
  );
  final recordTimeMs = _extractDateTimeMs(normalized, fallbackNowMs);
  final accounts = _extractAccountHints(normalized, lines, sourceApp);
  final merchant = _extractMerchant(
    normalized,
    lines,
    sourceApp: sourceApp,
    account1: accounts.$1,
  );

  return ParsedPaymentNotification(
    recordType: recordType,
    money: extractedAmount.$1,
    discount: discount,
    recordTimeMs: recordTimeMs,
    sourceApp: sourceApp,
    merchant: merchant,
    accountHint1: accounts.$1,
    accountHint2: accounts.$2,
    categoryHint: _inferCategoryKeyword(merchant, normalized),
    rawText: normalized,
  );
}

String _detectSourceApp(String text, String? packageOrApp) {
  if (packageOrApp != null && packageOrApp.trim().isNotEmpty) {
    return friendlyAutoBillAppName(packageOrApp);
  }
  final lower = text.toLowerCase();
  if (text.contains('微信支付') ||
      text.contains('微信红包') ||
      text.contains('微信转账') ||
      lower.contains('wechat')) {
    return '微信';
  }
  if (text.contains('支付宝') ||
      text.contains('花呗') ||
      text.contains('余额宝') ||
      lower.contains('alipay')) {
    return '支付宝';
  }
  if (text.contains('云闪付') || lower.contains('unionpay')) {
    return '云闪付';
  }
  if (text.contains('数字人民币')) {
    return '数字人民币';
  }
  final bankTag = RegExp(r'【([^】]{2,12}(?:银行|农信|信用社|信用卡))】').firstMatch(text);
  if (bankTag != null) {
    return '短信';
  }
  return '自动识别';
}

(Money, bool, bool)? _extractPrimaryAmount(
  String fullText,
  List<String> lines,
) {
  // 1. Explicit action-amount phrases (SMS / notifications)
  final actionPatterns = <RegExp>[
    RegExp(
      r'(?:付款|消费|支付|扣款|支出|转出|转账|收款|收入|入账|到账|存入|还款|提现|实付|订单金额|金额)[：:\s]*(?:人民币|CNY|RMB)?\s*([+-])?\s*[¥￥]?\s*(\d{1,3}(?:,\d{3})*(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?)\s*元?',
    ),
    RegExp(
      r'([+-])?\s*[¥￥]\s*(\d{1,3}(?:,\d{3})*(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?)',
    ),
    RegExp(r'([+-])\s*(\d{1,3}(?:,\d{3})*\.\d{2}|\d+\.\d{2})(?!\d)'),
    RegExp(r'(\d{1,3}(?:,\d{3})*(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?)\s*元'),
  ];

  // Filter out balance-remainder clauses like "余额1234.56元" or "优惠2.00元" before scanning
  final scrubbed = fullText.replaceAll(
    RegExp(
      r'(?:可用余额|账户余额|当前余额|余额|立减|优惠|随机立减|优惠券)[：:\s]*(?:人民币|CNY|RMB)?\s*[+-]?[¥￥]?\s*\d[\d,]*(?:\.\d+)?\s*元?',
    ),
    ' ',
  );

  for (var i = 0; i < actionPatterns.length; i++) {
    final p = actionPatterns[i];
    final m = p.firstMatch(scrubbed);
    if (m != null) {
      final String? sign;
      final String numStr;
      if (i == 3) {
        sign = null;
        numStr = m.group(1)!;
      } else {
        sign = m.group(1);
        numStr = m.group(2)!;
      }
      final money = _tryParsePositiveMoney(numStr);
      if (money != null) {
        return (money, sign == '-', sign == '+');
      }
    }
  }

  // Fallback: standalone decimal line like "-36.00" or "36.00"
  for (final line in lines) {
    final m = RegExp(
      r'^([+-])?\s*[¥￥]?\s*(\d{1,3}(?:,\d{3})*\.\d{1,2}|\d+\.\d{1,2})$',
    ).firstMatch(line);
    if (m != null) {
      final money = _tryParsePositiveMoney(m.group(2)!);
      if (money != null) {
        return (money, m.group(1) == '-', m.group(1) == '+');
      }
    }
  }
  return null;
}

Money? _extractDiscount(String fullText) {
  final m = RegExp(
    r'(?:优惠|立减|随机立减|红包抵扣)[：:\s]*[+-]?[¥￥]?\s*(\d[\d,]*(?:\.\d{1,2})?)\s*元?',
  ).firstMatch(fullText);
  if (m == null) return null;
  return _tryParsePositiveMoney(m.group(1)!);
}

Money? _tryParsePositiveMoney(String rawDigits) {
  final cleaned = rawDigits.replaceAll(',', '').trim();
  try {
    final units = DecimalValue.parse(
      cleaned,
    ).unitsAt(Money.ledgerScale, rounding: RoundingMode.halfUp);
    if (units <= BigInt.zero) return null;
    final money = Money.minor(units);
    money.storageMinor;
    return money;
  } on Failure {
    return null;
  }
}

int _detectDirection(
  String text, {
  required bool hasNegativeSign,
  required bool hasPositiveSign,
}) {
  if (RegExp(r'信用卡还款|提现到|转入余额宝|向.{1,20}转账.*转入|储蓄卡向.*转账').hasMatch(text)) {
    return RecordType.transfer;
  }
  if (RegExp(r'收款|收到|转入|收入|代发工资|工资|奖金|退款到账|收益|红包入账|入账').hasMatch(text)) {
    if (!RegExp(r'收款方[：:]|商户[：:]').hasMatch(text) || hasPositiveSign) {
      return RecordType.income;
    }
  }
  if (hasPositiveSign && !hasNegativeSign) {
    return RecordType.income;
  }
  return RecordType.expense;
}

int _extractDateTimeMs(String text, int fallbackNowMs) {
  final fullDt = RegExp(
    r'(\d{4})[-年/.](\d{1,2})[-月/.](\d{1,2})日?\s*(\d{1,2}):(\d{2})(?::(\d{2}))?',
  ).firstMatch(text);
  if (fullDt != null) {
    final dt = DateTime(
      int.parse(fullDt.group(1)!),
      int.parse(fullDt.group(2)!),
      int.parse(fullDt.group(3)!),
      int.parse(fullDt.group(4)!),
      int.parse(fullDt.group(5)!),
      fullDt.group(6) == null ? 0 : int.parse(fullDt.group(6)!),
    );
    return dt.millisecondsSinceEpoch;
  }

  final fallback = DateTime.fromMillisecondsSinceEpoch(fallbackNowMs);
  final mdDt = RegExp(
    r'(\d{1,2})(?:月|[-/])(\d{1,2})日?\s*(\d{1,2}):(\d{2})(?::(\d{2}))?',
  ).firstMatch(text);
  if (mdDt != null) {
    final m = int.parse(mdDt.group(1)!);
    final d = int.parse(mdDt.group(2)!);
    final h = int.parse(mdDt.group(3)!);
    final min = int.parse(mdDt.group(4)!);
    if (m >= 1 && m <= 12 && d >= 1 && d <= 31 && h <= 23 && min <= 59) {
      return DateTime(
        fallback.year,
        m,
        d,
        h,
        min,
        mdDt.group(5) == null ? 0 : int.parse(mdDt.group(5)!),
      ).millisecondsSinceEpoch;
    }
  }
  return fallbackNowMs;
}

(String?, String?) _extractAccountHints(
  String text,
  List<String> lines,
  String sourceApp,
) {
  String? a1;
  String? a2;

  final payMethod = RegExp(
    r'(?:支付方式|付款方式|扣款账户|交易方式|收款账户|入账账户)[：:\s]+([^\n，,。；;]+)',
  ).firstMatch(text);
  if (payMethod != null) {
    a1 = payMethod.group(1)!.trim();
    if (sourceApp == '微信' && a1 == '零钱') {
      a1 = '微信零钱';
    }
  }

  if (a1 == null) {
    final bankSms = RegExp(
      r'【([^】]{2,12}银行)】.*?(?:尾号|账户)(\d{4})',
    ).firstMatch(text);
    if (bankSms != null) {
      a1 = '${bankSms.group(1)}(${bankSms.group(2)})';
    } else {
      final tailOnly = RegExp(r'尾号(\d{4})(?:银行卡|储蓄卡|信用卡|卡)?').firstMatch(text);
      final bankHeader = RegExp(r'【([^】]{2,12})】').firstMatch(text);
      if (tailOnly != null && bankHeader != null) {
        a1 = '${bankHeader.group(1)}(${tailOnly.group(1)})';
      } else if (tailOnly != null) {
        a1 = '尾号${tailOnly.group(1)}';
      }
    }
  }

  final transferTo = RegExp(
    r'(?:向尾号|转入尾号|转至|提现到)\s*([^\n，,。；;0-9]*\d{4}|余额宝|零钱通|微信零钱)',
  ).firstMatch(text);
  if (transferTo != null) {
    a2 = transferTo.group(1)!.trim();
  }

  if (a1 == null) {
    if (text.contains('花呗')) {
      a1 = '花呗';
    } else if (text.contains('余额宝')) {
      a1 = '余额宝';
    } else if (text.contains('零钱通')) {
      a1 = '零钱通';
    } else if (sourceApp == '微信') {
      a1 = '微信零钱';
    } else if (sourceApp == '支付宝') {
      a1 = '支付宝';
    }
  }

  return (a1, a2);
}

String _extractMerchant(
  String text,
  List<String> lines, {
  required String sourceApp,
  required String? account1,
}) {
  final explicit = RegExp(
    r'(?:收款方|商户名称|商户|商品说明|交易对象|摘要)[：:\s]+([^\n，,。；;]+)',
  ).firstMatch(text);
  if (explicit != null) {
    return explicit.group(1)!.trim();
  }

  final smsAt = RegExp(
    r'(?:在|于\d{1,2}月\d{1,2}日(?:\d{1,2}:\d{2})?在)([^\n，,。；;]{2,24}?)(?:消费|支付|扣款)',
  ).firstMatch(text);
  if (smsAt != null) {
    return smsAt.group(1)!.trim();
  }

  final transferTarget = RegExp(r'向([^\n，,。；;0-9]{1,16})转账').firstMatch(text);
  if (transferTarget != null) {
    return '转账给${transferTarget.group(1)!.trim()}';
  }

  const noiseTokens = {
    '微信支付',
    '支付宝',
    '支付宝通知',
    '云闪付',
    '账单详情',
    '交易详情',
    '支付成功',
    '交易成功',
    '付款成功',
  };
  for (final line in lines) {
    final cleaned = line.replaceAll(RegExp(r'^【[^】]+】'), '').trim();
    if (cleaned.isEmpty || noiseTokens.contains(cleaned)) continue;
    if (RegExp(r'^[+-]?[¥￥]?\s*\d[\d,]*(?:\.\d+)?\s*元?$').hasMatch(cleaned)) {
      continue;
    }
    if (RegExp(
      r'^(?:支付方式|付款方式|交易时间|创建时间|订单号|商户单号|当前状态|账单分类)',
    ).hasMatch(cleaned)) {
      continue;
    }
    if (account1 != null && cleaned == account1) continue;
    if (cleaned.length <= 40) return cleaned;
    return cleaned.substring(0, 40);
  }
  return sourceApp;
}

String? _inferCategoryKeyword(String merchant, String fullText) {
  final combined = '$merchant $fullText';
  if (RegExp(
    r'咖啡|瑞幸|星巴克|美团外卖|饿了么|餐饮|麦当劳|肯德基|奶茶|喜茶|霸王茶姬|早餐|午餐|晚餐|食堂|火锅',
  ).hasMatch(combined)) {
    return '餐饮';
  }
  if (RegExp(r'地铁|公交|滴滴|打车|出行|高铁|12306|停车|加油|交通').hasMatch(combined)) {
    return '交通';
  }
  if (RegExp(r'超市|便利店|全家|罗森|7-11|沃尔玛|山姆|盒马|京东|淘宝|拼多多|购物').hasMatch(combined)) {
    return '购物';
  }
  if (RegExp(r'话费|流量|中国移动|中国联通|中国电信|宽带').hasMatch(combined)) {
    return '话费';
  }
  if (RegExp(r'医院|药房|药店|门诊|医保|医疗').hasMatch(combined)) {
    return '医疗';
  }
  if (RegExp(r'工资|代发工资|薪资').hasMatch(combined)) {
    return '工资';
  }
  return null;
}
