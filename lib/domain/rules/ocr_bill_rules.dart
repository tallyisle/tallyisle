import 'dart:convert';

import '../../core/failure.dart';
import '../../core/money.dart';
import '../model/codes.dart';

/// Preference key storing `OcrEndpointConfig` in `ti_preference` (`ADR-017`).
const String ocrProviderPreferenceKey = 'ocr_provider_config';

/// Explicit status label required by `ADR-017` when no OCR provider is configured.
const String ocrUnconfiguredStatusLabel = '未配置';
const String ocrConfiguredStatusLabel = '已配置';

/// User-configurable HTTP OCR endpoint settings (`F-021`, `ADR-017`).
final class OcrEndpointConfig {
  const OcrEndpointConfig({
    this.endpointUrl = '',
    this.apiKey = '',
    this.timeoutSeconds = 30,
  });

  final String endpointUrl;
  final String apiKey;
  final int timeoutSeconds;

  bool get isConfigured {
    final trimmed = endpointUrl.trim();
    if (trimmed.isEmpty) return false;
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasAuthority || uri.host.trim().isEmpty) {
      return false;
    }
    final scheme = uri.scheme.toLowerCase();
    return scheme == 'http' || scheme == 'https';
  }

  String get statusLabel =>
      isConfigured ? ocrConfiguredStatusLabel : ocrUnconfiguredStatusLabel;

  OcrEndpointConfig validated() {
    final trimmedUrl = endpointUrl.trim();
    if (trimmedUrl.isNotEmpty && !isConfigured) {
      throw const Failure(
        FailureCode.validation,
        'OCR 接口地址须以 http:// 或 https:// 开头且包含有效域名或 IP',
      );
    }
    final clampedTimeout = timeoutSeconds.clamp(5, 120);
    return OcrEndpointConfig(
      endpointUrl: trimmedUrl,
      apiKey: apiKey.trim(),
      timeoutSeconds: clampedTimeout,
    );
  }

  factory OcrEndpointConfig.parse(String? jsonText) {
    if (jsonText == null || jsonText.trim().isEmpty) {
      return const OcrEndpointConfig();
    }
    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is! Map) return const OcrEndpointConfig();
      final url = (decoded['endpointUrl'] as String?)?.trim() ?? '';
      final key = (decoded['apiKey'] as String?)?.trim() ?? '';
      final rawTimeout = decoded['timeoutSeconds'];
      final timeout = rawTimeout is int ? rawTimeout.clamp(5, 120) : 30;
      return OcrEndpointConfig(
        endpointUrl: url,
        apiKey: key,
        timeoutSeconds: timeout,
      );
    } on FormatException {
      return const OcrEndpointConfig();
    }
  }

  String encode() => jsonEncode({
    'endpointUrl': endpointUrl.trim(),
    'apiKey': apiKey.trim(),
    'timeoutSeconds': timeoutSeconds.clamp(5, 120),
  });
}

/// Extracts recognized plain text from common HTTP OCR JSON payloads (`F-021`).
String extractTextFromOcrJsonResponse(String responseBody) {
  final trimmed = responseBody.trim();
  if (trimmed.isEmpty) {
    throw const Failure(FailureCode.validation, 'OCR 接口返回了空响应');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(trimmed);
  } on FormatException {
    throw const Failure(FailureCode.validation, 'OCR 接口返回的不是有效 JSON');
  }
  if (decoded is! Map) {
    throw const Failure(FailureCode.validation, 'OCR 接口响应格式不受支持');
  }

  final lines = <String>[];
  void collect(Object? node) {
    if (node == null) return;
    if (node is String) {
      final s = node.trim();
      if (s.isNotEmpty) lines.add(s);
      return;
    }
    if (node is List) {
      for (final item in node) {
        if (item is String) {
          collect(item);
        } else if (item is Map) {
          collect(item['text'] ?? item['words'] ?? item['content']);
        }
      }
      return;
    }
    if (node is Map) {
      if (node['text'] is String) {
        collect(node['text']);
        return;
      }
      if (node['lines'] != null) {
        collect(node['lines']);
        return;
      }
      if (node['words_result'] != null) {
        collect(node['words_result']);
        return;
      }
      if (node['results'] != null) {
        collect(node['results']);
        return;
      }
      if (node['result'] is String || node['result'] is List) {
        collect(node['result']);
        return;
      }
      if (node['data'] != null) {
        collect(node['data']);
        return;
      }
      final choices = node['choices'];
      if (choices is List && choices.isNotEmpty) {
        final first = choices.first;
        if (first is Map) {
          final msg = first['message'];
          if (msg is Map && msg['content'] is String) {
            collect(msg['content']);
            return;
          }
          if (first['text'] is String) {
            collect(first['text']);
            return;
          }
        }
      }
    }
  }

  collect(decoded);
  final joined = lines.join('\n').trim();
  if (joined.isEmpty) {
    throw const Failure(FailureCode.validation, 'OCR 接口响应未包含可识别文本');
  }
  return joined;
}

/// Candidate bill parsed from OCR text (WeChat/Alipay ledger screenshot or receipt).
final class OcrBillCandidate {
  const OcrBillCandidate({
    required this.index,
    required this.type,
    required this.money,
    this.discount,
    required this.recordTimeMs,
    required this.merchant,
    required this.remark,
    this.categoryHint,
    this.accountHint,
    this.categoryId,
    this.assetId,
    this.selected = true,
  });

  final int index;
  final int type;
  final Money money;
  final Money? discount;
  final int recordTimeMs;
  final String merchant;
  final String remark;
  final String? categoryHint;
  final String? accountHint;
  final int? categoryId;
  final int? assetId;
  final bool selected;

  OcrBillCandidate copyWith({
    int? type,
    Money? money,
    Money? discount,
    int? recordTimeMs,
    String? merchant,
    String? remark,
    String? categoryHint,
    String? accountHint,
    int? categoryId,
    int? assetId,
    bool? selected,
  }) => OcrBillCandidate(
    index: index,
    type: type ?? this.type,
    money: money ?? this.money,
    discount: discount ?? this.discount,
    recordTimeMs: recordTimeMs ?? this.recordTimeMs,
    merchant: merchant ?? this.merchant,
    remark: remark ?? this.remark,
    categoryHint: categoryHint ?? this.categoryHint,
    accountHint: accountHint ?? this.accountHint,
    categoryId: categoryId ?? this.categoryId,
    assetId: assetId ?? this.assetId,
    selected: selected ?? this.selected,
  );
}

/// Parses OCR-extracted or pasted WeChat/Alipay bill list or single receipt text
/// into reviewable [OcrBillCandidate] items (`F-021` R4).
///
/// Uses `DecimalValue` / `Money` (`BigInt` minor units) exclusively — zero `double`.
List<OcrBillCandidate> parseOcrBillCandidates(
  String rawText, {
  required int defaultYear,
  required int fallbackTimeMs,
}) {
  final normalized = rawText.replaceAll('\r\n', '\n').trim();
  if (normalized.isEmpty) return const [];

  final rawLines = normalized
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList(growable: false);
  if (rawLines.isEmpty) return const [];

  final ledgerItems = _parseLedgerListCandidates(
    rawLines,
    defaultYear: defaultYear,
    fallbackTimeMs: fallbackTimeMs,
  );
  if (ledgerItems.isNotEmpty) {
    return ledgerItems;
  }

  final receipt = _parseSingleReceiptCandidate(
    rawLines,
    fullText: normalized,
    defaultYear: defaultYear,
    fallbackTimeMs: fallbackTimeMs,
  );
  return receipt == null ? const [] : [receipt];
}

final RegExp _signedAmountInline = RegExp(
  r'(?:^|\s)([+-])\s*[¥￥]?\s*(\d{1,3}(?:,\d{3})*\.\d{2}|\d+\.\d{1,2})(?=\s|$)',
);

final RegExp _signedAmountWholeLine = RegExp(
  r'^([+-])\s*[¥￥]?\s*(\d{1,3}(?:,\d{3})*(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?)$',
);

bool _isLedgerNoiseLine(String line) {
  if (RegExp(
    r'^(?:账单|账单明细|零钱明细|收支明细|统计|筛选|全部账单|本月|支出\s*[¥￥]?|收入\s*[¥￥]?|余额\s*[¥￥:]|剩余)',
  ).hasMatch(line)) {
    return true;
  }
  if (RegExp(r'^\d{4}年\d{1,2}月$').hasMatch(line)) return true;
  if (RegExp(r'^\d{12,}$').hasMatch(line)) return true;
  if (RegExp(r'^(?:交易成功|支付成功|已全额退款|退款成功|已完成|待收货)$').hasMatch(line)) {
    return true;
  }
  return false;
}

List<OcrBillCandidate> _parseLedgerListCandidates(
  List<String> lines, {
  required int defaultYear,
  required int fallbackTimeMs,
}) {
  final candidates = <OcrBillCandidate>[];
  var activeYear = defaultYear;
  final pendingTexts = <String>[];
  int? pendingDateMs;

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final yearHeader = RegExp(r'^(\d{4})年\d{1,2}月').firstMatch(line);
    if (yearHeader != null) {
      activeYear = int.parse(yearHeader.group(1)!);
      continue;
    }
    if (_isLedgerNoiseLine(line)) continue;

    // Case A: Single-line tabular entry, e.g. "瑞幸咖啡 -18.50 11-10 09:15" or "11-10 09:15 瑞幸咖啡 -18.50"
    final wholeSigned = _signedAmountWholeLine.firstMatch(line);
    if (wholeSigned != null) {
      final sign = wholeSigned.group(1)!;
      final money = _parsePositiveMoney(wholeSigned.group(2)!);
      if (money != null) {
        // Look ahead 1 line if date wasn't seen yet (Alipay often puts date below or right of amount)
        var resolvedTime = pendingDateMs;
        if (resolvedTime == null && i + 1 < lines.length) {
          final nextDate = _tryExtractLineDateMs(lines[i + 1], activeYear);
          if (nextDate != null &&
              _signedAmountWholeLine.firstMatch(lines[i + 1]) == null &&
              _signedAmountInline.firstMatch(lines[i + 1]) == null) {
            resolvedTime = nextDate;
            i++;
          }
        }
        final merchant = _pickMerchantFromPending(pendingTexts);
        final catHint = _pickCategoryHintFromPending(pendingTexts, merchant);
        candidates.add(
          OcrBillCandidate(
            index: candidates.length,
            type: sign == '+' ? RecordType.income : RecordType.expense,
            money: money,
            recordTimeMs: resolvedTime ?? fallbackTimeMs,
            merchant: merchant,
            remark: merchant,
            categoryHint: catHint,
          ),
        );
        pendingTexts.clear();
        pendingDateMs = null;
      }
      continue;
    }

    final inlineMatch = _signedAmountInline.firstMatch(line);
    if (inlineMatch != null) {
      final sign = inlineMatch.group(1)!;
      final money = _parsePositiveMoney(inlineMatch.group(2)!);
      if (money != null) {
        final withoutAmount = line
            .replaceRange(inlineMatch.start, inlineMatch.end, ' ')
            .trim();
        final lineDate = _tryExtractLineDateMs(withoutAmount, activeYear);
        final strippedMerchant = _stripDateTokens(withoutAmount).trim();
        final merchant = strippedMerchant.isNotEmpty
            ? strippedMerchant
            : _pickMerchantFromPending(pendingTexts);
        candidates.add(
          OcrBillCandidate(
            index: candidates.length,
            type: sign == '+' ? RecordType.income : RecordType.expense,
            money: money,
            recordTimeMs: lineDate ?? pendingDateMs ?? fallbackTimeMs,
            merchant: merchant,
            remark: merchant,
            categoryHint: _inferOcrCategory(merchant),
          ),
        );
        pendingTexts.clear();
        pendingDateMs = null;
        continue;
      }
    }

    final maybeDate = _tryExtractLineDateMs(line, activeYear);
    if (maybeDate != null) {
      pendingDateMs = maybeDate;
      final remainder = _stripDateTokens(line).trim();
      if (remainder.isNotEmpty && !_isLedgerNoiseLine(remainder)) {
        pendingTexts.add(remainder);
      }
      continue;
    }

    pendingTexts.add(line);
    if (pendingTexts.length > 4) {
      pendingTexts.removeAt(0);
    }
  }

  return candidates;
}

OcrBillCandidate? _parseSingleReceiptCandidate(
  List<String> lines, {
  required String fullText,
  required int defaultYear,
  required int fallbackTimeMs,
}) {
  final totalPatterns = <RegExp>[
    RegExp(
      r'(?:实付金额|实付款|实付|应付金额|应付|合计金额|总计|合计|TOTAL|Total)[：:\s]*[¥￥$]?\s*(\d{1,3}(?:,\d{3})*(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?)\s*元?',
    ),
    RegExp(r'[¥￥]\s*(\d{1,3}(?:,\d{3})*\.\d{2}|\d+\.\d{1,2})'),
  ];

  Money? foundMoney;
  for (final p in totalPatterns) {
    final matches = p.allMatches(fullText).toList();
    if (matches.isNotEmpty) {
      // On retail receipts, the final total/paid line is typically the last match
      final chosen = p == totalPatterns.first ? matches.last : matches.first;
      foundMoney = _parsePositiveMoney(chosen.group(1)!);
      if (foundMoney != null) break;
    }
  }
  if (foundMoney == null) return null;

  int? timeMs;
  for (final line in lines) {
    timeMs = _tryExtractLineDateMs(line, defaultYear);
    if (timeMs != null) break;
  }

  var merchant = '小票识别';
  for (final line in lines) {
    if (_isLedgerNoiseLine(line)) continue;
    if (RegExp(
      r'(?:欢迎光临|收银员|单号|机号|小票|合计|实付|应付|找零|谢谢惠顾|日期|时间|\d{2}:\d{2})',
    ).hasMatch(line)) {
      continue;
    }
    if (RegExp(r'^[¥￥\d.,+-\s]+$').hasMatch(line)) continue;
    merchant = line.length <= 32 ? line : line.substring(0, 32);
    break;
  }

  return OcrBillCandidate(
    index: 0,
    type: RecordType.expense,
    money: foundMoney,
    recordTimeMs: timeMs ?? fallbackTimeMs,
    merchant: merchant,
    remark: merchant,
    categoryHint: _inferOcrCategory(merchant) ?? _inferOcrCategory(fullText),
  );
}

Money? _parsePositiveMoney(String raw) {
  final cleaned = raw.replaceAll(',', '').trim();
  try {
    final minor = DecimalValue.parse(
      cleaned,
    ).unitsAt(Money.ledgerScale, rounding: RoundingMode.halfUp);
    if (minor <= BigInt.zero) return null;
    final m = Money.minor(minor);
    m.storageMinor;
    return m;
  } on Failure {
    return null;
  }
}

int? _tryExtractLineDateMs(String line, int defaultYear) {
  final full = RegExp(
    r'(\d{4})[-年/.](\d{1,2})[-月/.](\d{1,2})日?(?:\s+(\d{1,2}):(\d{2})(?::(\d{2}))?)?',
  ).firstMatch(line);
  if (full != null) {
    final y = int.parse(full.group(1)!);
    final m = int.parse(full.group(2)!);
    final d = int.parse(full.group(3)!);
    final h = full.group(4) == null ? 12 : int.parse(full.group(4)!);
    final min = full.group(5) == null ? 0 : int.parse(full.group(5)!);
    final sec = full.group(6) == null ? 0 : int.parse(full.group(6)!);
    if (m >= 1 && m <= 12 && d >= 1 && d <= 31 && h <= 23 && min <= 59) {
      return DateTime(y, m, d, h, min, sec).millisecondsSinceEpoch;
    }
  }

  final md = RegExp(
    r'(\d{1,2})(?:月|[-/])(\d{1,2})日?(?:\s+(\d{1,2}):(\d{2})(?::(\d{2}))?)?',
  ).firstMatch(line);
  if (md != null) {
    final m = int.parse(md.group(1)!);
    final d = int.parse(md.group(2)!);
    final h = md.group(3) == null ? 12 : int.parse(md.group(3)!);
    final min = md.group(4) == null ? 0 : int.parse(md.group(4)!);
    final sec = md.group(5) == null ? 0 : int.parse(md.group(5)!);
    if (m >= 1 && m <= 12 && d >= 1 && d <= 31 && h <= 23 && min <= 59) {
      return DateTime(defaultYear, m, d, h, min, sec).millisecondsSinceEpoch;
    }
  }
  return null;
}

String _stripDateTokens(String text) => text
    .replaceAll(
      RegExp(
        r'\d{4}[-年/.]\d{1,2}[-月/.]\d{1,2}日?(?:\s+\d{1,2}:\d{2}(?::\d{2})?)?',
      ),
      ' ',
    )
    .replaceAll(
      RegExp(r'\d{1,2}(?:月|[-/])\d{1,2}日?(?:\s+\d{1,2}:\d{2}(?::\d{2})?)?'),
      ' ',
    )
    .replaceAll(RegExp(r'\s+'), ' ');

String _pickMerchantFromPending(List<String> pending) {
  for (final s in pending) {
    if (!_isLedgerNoiseLine(s)) return s;
  }
  return '账单识别';
}

String? _pickCategoryHintFromPending(List<String> pending, String merchant) {
  for (final s in pending) {
    if (s != merchant) {
      final hinted = _inferOcrCategory(s);
      if (hinted != null) return hinted;
    }
  }
  return _inferOcrCategory(merchant);
}

String? _inferOcrCategory(String text) {
  if (RegExp(
    r'餐饮|美食|咖啡|瑞幸|星巴克|外卖|饿了么|美团|麦当劳|肯德基|奶茶|超市生鲜|火锅|早餐|午餐|晚餐',
  ).hasMatch(text)) {
    return '餐饮';
  }
  if (RegExp(r'交通|出行|地铁|公交|滴滴|打车|高铁|停车|加油').hasMatch(text)) {
    return '交通';
  }
  if (RegExp(r'购物|百货|服饰|日用|便利店|全家|罗森|沃尔玛|山姆|京东|淘宝|拼多多').hasMatch(text)) {
    return '购物';
  }
  if (RegExp(r'娱乐|电影|游戏|会员|视频|音乐').hasMatch(text)) {
    return '娱乐';
  }
  if (RegExp(r'医疗|医院|药房|药店|门诊').hasMatch(text)) {
    return '医疗';
  }
  if (RegExp(r'话费|通讯|移动|联通|电信|宽带').hasMatch(text)) {
    return '话费';
  }
  if (RegExp(r'工资|薪资|奖金').hasMatch(text)) {
    return '工资';
  }
  return null;
}
