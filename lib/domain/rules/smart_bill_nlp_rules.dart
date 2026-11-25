import 'dart:convert';

import '../../core/failure.dart';
import '../../core/money.dart';
import '../model/codes.dart';
import 'url_scheme_rules.dart' show parseUrlDateTimeMs, parseUrlMoney;

/// `ti_preference` key storing [AutoBillSettings] JSON (zero DDL, `ADR-013`).
const String autoBillSettingsPreferenceKey = 'auto_bill_settings';

/// `ti_preference` key storing [AiBillParserConfig] JSON (zero DDL, `ADR-013`).
const String aiBillParserConfigPreferenceKey = 'ai_bill_parser_config';

// ---------------------------------------------------------------------------
// Auto-bill preferences
// ---------------------------------------------------------------------------

/// Android instant prompt style after a payment is captured (`decision 3`).
enum AutoBillPromptMode {
  /// Heads-up notification with action buttons (default).
  notification('notification', '顶部快捷通知'),

  /// Cross-app bottom overlay card (needs overlay permission; falls back to
  /// [notification] natively when not granted).
  overlay('overlay', '底部悬浮记账窗'),

  /// No interruption; only the home-page pending-draft banner.
  silent('silent', '纯静默（仅首页提醒）');

  const AutoBillPromptMode(this.wireKey, this.label);

  final String wireKey;
  final String label;

  static AutoBillPromptMode fromWireKey(Object? raw) {
    final key = raw?.toString().trim().toLowerCase();
    for (final mode in AutoBillPromptMode.values) {
      if (mode.wireKey == key) return mode;
    }
    return AutoBillPromptMode.notification;
  }
}

/// Auto-bookkeeping preferences persisted in `ti_preference['auto_bill_settings']`.
final class AutoBillSettings {
  const AutoBillSettings({
    this.enableNotificationCapture = true,
    this.enableAccessibilityCapture = true,
    this.promptMode = AutoBillPromptMode.notification,
    this.autoConfirmMatchedRules = false,
    this.showHomeDraftBanner = true,
  });

  /// Android `NotificationListenerService` business switch.
  final bool enableNotificationCapture;

  /// Android `AccessibilityService` business switch.
  final bool enableAccessibilityCapture;

  /// Android prompt style (`notification` | `overlay` | `silent`).
  final AutoBillPromptMode promptMode;

  /// Global switch: auto-confirm bills that pass the “rule category + account”
  /// gate (`AutoMapMatchResult.canAutoConfirm`). Defaults to `false`.
  final bool autoConfirmMatchedRules;

  /// Whether the home page renders the pending-draft banner.
  final bool showHomeDraftBanner;

  factory AutoBillSettings.parse(String? jsonText) {
    if (jsonText == null || jsonText.trim().isEmpty) {
      return const AutoBillSettings();
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(jsonText);
    } on FormatException {
      return const AutoBillSettings();
    }
    if (decoded is! Map) return const AutoBillSettings();
    final Map<Object?, Object?> map = decoded;
    bool flag(String key, bool fallback) {
      final v = map[key];
      if (v is bool) return v;
      if (v is String) {
        final s = v.trim().toLowerCase();
        if (s == 'true' || s == '1') return true;
        if (s == 'false' || s == '0') return false;
      }
      if (v is int) return v != 0;
      return fallback;
    }

    return AutoBillSettings(
      enableNotificationCapture: flag('enableNotificationCapture', true),
      enableAccessibilityCapture: flag('enableAccessibilityCapture', true),
      promptMode: AutoBillPromptMode.fromWireKey(
        map['androidPromptMode'] ?? map['promptMode'],
      ),
      autoConfirmMatchedRules: flag('autoConfirmMatchedRules', false),
      showHomeDraftBanner: flag('showHomeDraftBanner', true),
    );
  }

  String encode() => jsonEncode({
    'v': 1,
    'enableNotificationCapture': enableNotificationCapture,
    'enableAccessibilityCapture': enableAccessibilityCapture,
    'androidPromptMode': promptMode.wireKey,
    'autoConfirmMatchedRules': autoConfirmMatchedRules,
    'showHomeDraftBanner': showHomeDraftBanner,
  });

  AutoBillSettings copyWith({
    bool? enableNotificationCapture,
    bool? enableAccessibilityCapture,
    AutoBillPromptMode? promptMode,
    bool? autoConfirmMatchedRules,
    bool? showHomeDraftBanner,
  }) => AutoBillSettings(
    enableNotificationCapture:
        enableNotificationCapture ?? this.enableNotificationCapture,
    enableAccessibilityCapture:
        enableAccessibilityCapture ?? this.enableAccessibilityCapture,
    promptMode: promptMode ?? this.promptMode,
    autoConfirmMatchedRules:
        autoConfirmMatchedRules ?? this.autoConfirmMatchedRules,
    showHomeDraftBanner: showHomeDraftBanner ?? this.showHomeDraftBanner,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AutoBillSettings &&
          enableNotificationCapture == other.enableNotificationCapture &&
          enableAccessibilityCapture == other.enableAccessibilityCapture &&
          promptMode == other.promptMode &&
          autoConfirmMatchedRules == other.autoConfirmMatchedRules &&
          showHomeDraftBanner == other.showHomeDraftBanner;

  @override
  int get hashCode => Object.hash(
    enableNotificationCapture,
    enableAccessibilityCapture,
    promptMode,
    autoConfirmMatchedRules,
    showHomeDraftBanner,
  );
}

// ---------------------------------------------------------------------------
// Optional user-configured OpenAI-compatible AI parser
// ---------------------------------------------------------------------------

/// User-supplied OpenAI-compatible endpoint (DeepSeek / 通义千问 / OpenAI …),
/// persisted in `ti_preference['ai_bill_parser_config']`. Disabled by default
/// (`P-03`: zero network unless the user opts in).
final class AiBillParserConfig {
  const AiBillParserConfig({
    this.enabled = false,
    this.baseUrl = '',
    this.apiKey = '',
    this.model = '',
    this.useForImages = false,
    this.fallbackOnly = true,
    this.timeoutSeconds = 30,
  });

  final bool enabled;
  final String baseUrl;
  final String apiKey;
  final String model;

  /// Whether multimodal image recognition (`ai_vision` OCR mode) may be used.
  final bool useForImages;

  /// Only call the AI when offline rules fail or confidence is low.
  final bool fallbackOnly;
  final int timeoutSeconds;

  bool get hasValidBaseUrl {
    final trimmed = baseUrl.trim();
    if (trimmed.isEmpty) return false;
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasAuthority || uri.host.trim().isEmpty) {
      return false;
    }
    final scheme = uri.scheme.toLowerCase();
    return scheme == 'http' || scheme == 'https';
  }

  /// `true` only when enabled with a valid `http(s)` base URL and model name.
  bool get isConfigured =>
      enabled && hasValidBaseUrl && model.trim().isNotEmpty;

  String get statusLabel => isConfigured ? '已配置' : '未配置';

  /// Resolves `<baseUrl>/chat/completions` (idempotent when already present).
  Uri get chatCompletionsUri {
    var base = baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (base.toLowerCase().endsWith('/chat/completions')) {
      return Uri.parse(base);
    }
    return Uri.parse('$base/chat/completions');
  }

  AiBillParserConfig validated() {
    final url = baseUrl.trim();
    if (url.isNotEmpty && !hasValidBaseUrl) {
      throw const Failure(
        FailureCode.validation,
        'AI 接口地址须以 http:// 或 https:// 开头且包含有效域名或 IP',
      );
    }
    if (enabled) {
      if (url.isEmpty) {
        throw const Failure(FailureCode.validation, '启用 AI 识账前请填写接口地址');
      }
      if (model.trim().isEmpty) {
        throw const Failure(FailureCode.validation, '启用 AI 识账前请填写模型名称');
      }
    }
    return AiBillParserConfig(
      enabled: enabled,
      baseUrl: url,
      apiKey: apiKey.trim(),
      model: model.trim(),
      useForImages: useForImages,
      fallbackOnly: fallbackOnly,
      timeoutSeconds: timeoutSeconds.clamp(5, 120),
    );
  }

  factory AiBillParserConfig.parse(String? jsonText) {
    if (jsonText == null || jsonText.trim().isEmpty) {
      return const AiBillParserConfig();
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(jsonText);
    } on FormatException {
      return const AiBillParserConfig();
    }
    if (decoded is! Map) return const AiBillParserConfig();
    final Map<Object?, Object?> map = decoded;
    String str(String key) => map[key]?.toString().trim() ?? '';
    bool flag(String key, bool fallback) {
      final v = map[key];
      return v is bool ? v : fallback;
    }

    final rawTimeout = map['timeoutSeconds'];
    return AiBillParserConfig(
      enabled: flag('enabled', false),
      baseUrl: str('baseUrl'),
      apiKey: str('apiKey'),
      model: str('model'),
      useForImages: flag('useForImages', false),
      fallbackOnly: flag('fallbackOnly', true),
      timeoutSeconds: rawTimeout is int ? rawTimeout.clamp(5, 120) : 30,
    );
  }

  String encode() => jsonEncode({
    'v': 1,
    'enabled': enabled,
    'baseUrl': baseUrl.trim(),
    'apiKey': apiKey.trim(),
    'model': model.trim(),
    'useForImages': useForImages,
    'fallbackOnly': fallbackOnly,
    'timeoutSeconds': timeoutSeconds.clamp(5, 120),
  });

  AiBillParserConfig copyWith({
    bool? enabled,
    String? baseUrl,
    String? apiKey,
    String? model,
    bool? useForImages,
    bool? fallbackOnly,
    int? timeoutSeconds,
  }) => AiBillParserConfig(
    enabled: enabled ?? this.enabled,
    baseUrl: baseUrl ?? this.baseUrl,
    apiKey: apiKey ?? this.apiKey,
    model: model ?? this.model,
    useForImages: useForImages ?? this.useForImages,
    fallbackOnly: fallbackOnly ?? this.fallbackOnly,
    timeoutSeconds: timeoutSeconds ?? this.timeoutSeconds,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AiBillParserConfig &&
          enabled == other.enabled &&
          baseUrl == other.baseUrl &&
          apiKey == other.apiKey &&
          model == other.model &&
          useForImages == other.useForImages &&
          fallbackOnly == other.fallbackOnly &&
          timeoutSeconds == other.timeoutSeconds;

  @override
  int get hashCode => Object.hash(
    enabled,
    baseUrl,
    apiKey,
    model,
    useForImages,
    fallbackOnly,
    timeoutSeconds,
  );
}

// ---------------------------------------------------------------------------
// Parse result
// ---------------------------------------------------------------------------

enum SmartBillConfidence { low, medium, high }

/// Structured bill extracted from colloquial text, payment text, or AI JSON.
final class SmartBillParseResult {
  const SmartBillParseResult({
    required this.recordType,
    required this.money,
    this.discount,
    required this.recordTimeMs,
    this.hasExplicitTime = false,
    this.assetHint,
    this.toAssetHint,
    this.categoryHint,
    this.remark = '',
    this.confidence = SmartBillConfidence.medium,
    required this.rawText,
    this.source = 'nlp',
  });

  final int recordType;

  /// Gross amount (`> 0`), `BigInt` minor units (`ADR-011`).
  final Money money;
  final Money? discount;
  final int recordTimeMs;
  final bool hasExplicitTime;
  final String? assetHint;
  final String? toAssetHint;
  final String? categoryHint;
  final String remark;
  final SmartBillConfidence confidence;
  final String rawText;

  /// `'nlp'` (offline colloquial rules) or `'ai'` (user AI endpoint).
  final String source;

  /// Merchant-like display text (same as [remark]; may be empty).
  String get merchant => remark;
}

// ---------------------------------------------------------------------------
// Chinese numerals & amounts (pure BigInt, zero double)
// ---------------------------------------------------------------------------

const Map<String, int> _cnDigit = {
  '零': 0,
  '〇': 0,
  '一': 1,
  '壹': 1,
  '二': 2,
  '贰': 2,
  '两': 2,
  '三': 3,
  '叁': 3,
  '四': 4,
  '肆': 4,
  '五': 5,
  '伍': 5,
  '六': 6,
  '陆': 6,
  '七': 7,
  '柒': 7,
  '八': 8,
  '捌': 8,
  '九': 9,
  '玖': 9,
};

const Map<String, int> _cnSmallUnit = {
  '十': 10,
  '拾': 10,
  '百': 100,
  '佰': 100,
  '千': 1000,
  '仟': 1000,
};

/// Parses a Chinese integer numeral (`三十二`、`一百零五`、`两千五`、`三万五`)
/// into a [BigInt]. Supports colloquial trailing digits (`两千五` = 2500).
/// Returns `null` for malformed input.
BigInt? parseChineseInteger(String input) {
  final text = input.trim();
  if (text.isEmpty || text.length > 24) return null;
  var total = BigInt.zero;
  var section = BigInt.zero;
  var number = -1;
  var lastUnit = 0;
  var zeroSeen = false;
  var prevWasUnit = false;
  var digitFollowsUnit = false;
  for (final rune in text.runes) {
    final c = String.fromCharCode(rune);
    final digit = _cnDigit[c];
    if (digit != null) {
      if (digit == 0) {
        zeroSeen = true;
        number = -1;
      } else {
        if (number >= 0 && !prevWasUnit) return null; // e.g. "三四" ambiguous
        number = digit;
        digitFollowsUnit = prevWasUnit;
      }
      prevWasUnit = false;
      continue;
    }
    final small = _cnSmallUnit[c];
    if (small != null) {
      final n = number < 0 ? (small == 10 ? 1 : -1) : number;
      if (n < 0) return null;
      section += BigInt.from(n * small);
      number = -1;
      lastUnit = small;
      zeroSeen = false;
      prevWasUnit = true;
      continue;
    }
    if (c == '万' || c == '亿') {
      final big = c == '万' ? BigInt.from(10000) : BigInt.from(100000000);
      if (number > 0) section += BigInt.from(number);
      if (section == BigInt.zero && total == BigInt.zero) return null;
      if (c == '亿') {
        total = (total + section) * big;
      } else {
        total += section * big;
      }
      section = BigInt.zero;
      number = -1;
      lastUnit = c == '万' ? 10000 : 100000000;
      zeroSeen = false;
      prevWasUnit = true;
      continue;
    }
    return null;
  }
  if (number > 0) {
    if (digitFollowsUnit && !zeroSeen && lastUnit >= 100) {
      section += BigInt.from(number) * BigInt.from(lastUnit ~/ 10);
    } else {
      section += BigInt.from(number);
    }
  }
  return total + section;
}

final class _AmountHit {
  const _AmountHit(this.money, this.start, this.end, this.strength);
  final Money money;
  final int start;
  final int end;

  /// 3 = currency/unit marker, 2 = chinese with unit/verb, 1 = bare number.
  final int strength;
}

const String _numPattern = r'(?<int>\d{1,3}(?:,\d{3})+|\d+)(?:\.(?<frac>\d+))?';
const String _cnNumChars = '零〇一二两三四五六七八九十百千万亿壹贰叁肆伍陆柒捌玖拾佰仟';

final List<RegExp> _arabicAmountPatterns = [
  // 18.5元 / 18块5 / 18元5角3分 / 8,500元
  RegExp(
    '$_numPattern\\s*(?:元|块|圆|RMB|rmb|CNY)(?:(?<jiao>\\d)(?:毛|角)?(?!\\d))?(?:(?<fen>\\d)分)?',
  ),
  // ¥18.5
  RegExp('[¥￥]\\s*$_numPattern'),
  // 9毛5 / 9毛 / 5角
  RegExp(r'(?<![\d.])(?<jiao>\d)\s*(?:毛|角)(?:(?<fen>\d)分?)?'),
];

final RegExp _cnUnitAmount = RegExp(
  '(?<cn>[$_cnNumChars]+)\\s*(?:元|块|圆)(?:(?<cjiao>[一二两三四五六七八九])(?:毛|角)?)?(?:(?<cfen>[一二两三四五六七八九])分)?',
);
final RegExp _cnJiaoAmount = RegExp(
  r'(?<cjiao>[一二两三四五六七八九])\s*(?:毛|角)(?:(?<cfen>[一二两三四五六七八九])分?)?',
);
final RegExp _cnVerbAmount = RegExp(
  '(?:花了|花费|付了|付款|收了|收到|共计|一共|总共|合计|消费)\\s*(?<cn>[$_cnNumChars]{1,12})(?![$_cnNumChars个份杯件次斤瓶袋盒包张本支台只条位天小分钟年月日号人])',
);
final RegExp _bareArabic = RegExp(
  r'(?<![\d.,])(?<int>\d{1,3}(?:,\d{3})+|\d+)(?:\.(?<frac>\d{1,2}))?(?![\d.]|\s*(?:个|份|杯|件|次|斤|公斤|kg|KG|g|克|km|公里|折|%|岁|天|人|号|楼|层|瓶|袋|盒|包|张|本|支|台|只|条|位|晚|分钟|小时|年|月|日|周|期|点|时|:|：))',
);

BigInt? _arabicUnits(String? intPart, String? fracPart) {
  if (intPart == null) return BigInt.zero;
  final cleanedInt = intPart.replaceAll(',', '');
  if (cleanedInt.length > 11) return null;
  final text = (fracPart == null || fracPart.isEmpty)
      ? cleanedInt
      : '$cleanedInt.$fracPart';
  try {
    return DecimalValue.parse(
      text,
    ).unitsAt(Money.ledgerScale, rounding: RoundingMode.halfUp);
  } on Failure {
    return null;
  }
}

Money? _positiveMoney(BigInt? units) {
  if (units == null || units <= BigInt.zero) return null;
  if (units > maxSmartBillAmountMinor) return null;
  return Money.minor(units);
}

/// Upper bound for any single parsed bill (`88,888,888,888.00`).
final BigInt maxSmartBillAmountMinor = BigInt.parse('8888888888800');

String? _group(RegExpMatch m, String name) {
  try {
    return m.namedGroup(name);
  } on ArgumentError {
    return null;
  }
}

_AmountHit? _findAmount(String work) {
  // 1. Arabic numerals with unit or currency marker.
  for (var i = 0; i < _arabicAmountPatterns.length; i++) {
    for (final m in _arabicAmountPatterns[i].allMatches(work)) {
      BigInt? units;
      if (i == 2) {
        final jiao = int.parse(_group(m, 'jiao')!);
        final fen = int.tryParse(_group(m, 'fen') ?? '') ?? 0;
        units = BigInt.from(jiao * 10 + fen);
      } else {
        units = _arabicUnits(_group(m, 'int'), _group(m, 'frac'));
        if (units != null && i == 0) {
          final jiao = int.tryParse(_group(m, 'jiao') ?? '') ?? 0;
          final fen = int.tryParse(_group(m, 'fen') ?? '') ?? 0;
          if (_group(m, 'frac') == null) {
            units += BigInt.from(jiao * 10 + fen);
          }
        }
      }
      final money = _positiveMoney(units);
      if (money != null) return _AmountHit(money, m.start, m.end, 3);
    }
  }
  // 2. Chinese numerals with unit.
  for (final m in _cnUnitAmount.allMatches(work)) {
    final yuan = parseChineseInteger(_group(m, 'cn')!);
    if (yuan == null) continue;
    final jiao = _cnDigit[_group(m, 'cjiao') ?? ''] ?? 0;
    final fen = _cnDigit[_group(m, 'cfen') ?? ''] ?? 0;
    final money = _positiveMoney(
      yuan * BigInt.from(100) + BigInt.from(jiao * 10 + fen),
    );
    if (money != null) return _AmountHit(money, m.start, m.end, 2);
  }
  for (final m in _cnJiaoAmount.allMatches(work)) {
    final jiao = _cnDigit[_group(m, 'cjiao')!] ?? 0;
    final fen = _cnDigit[_group(m, 'cfen') ?? ''] ?? 0;
    final money = _positiveMoney(BigInt.from(jiao * 10 + fen));
    if (money != null) return _AmountHit(money, m.start, m.end, 2);
  }
  for (final m in _cnVerbAmount.allMatches(work)) {
    final cn = _group(m, 'cn')!;
    final yuan = parseChineseInteger(cn);
    final money = _positiveMoney(yuan == null ? null : yuan * BigInt.from(100));
    if (money != null) {
      final cnStart = m.end - cn.length;
      return _AmountHit(money, cnStart, m.end, 2);
    }
  }
  // 3. Bare arabic number (e.g. "包子8.5微信").
  for (final m in _bareArabic.allMatches(work)) {
    final money = _positiveMoney(
      _arabicUnits(_group(m, 'int'), _group(m, 'frac')),
    );
    if (money != null) return _AmountHit(money, m.start, m.end, 1);
  }
  return null;
}

// ---------------------------------------------------------------------------
// Relative time
// ---------------------------------------------------------------------------

final RegExp _dayWordPattern = RegExp(r'大前天|前天|昨天|昨日|今天|今日|刚才|刚刚');
final RegExp _periodWordPattern = RegExp(
  r'今早|今晨|今晚|昨早|昨晚|昨夜|前晚|早上|早晨|上午|中午|下午|傍晚|晚上|夜里|凌晨',
);
final RegExp _hourPattern = RegExp(
  r'(?<h>\d{1,2}|[零一二两三四五六七八九十]{1,3})\s*[点时](?:\s*(?<half>半|一刻|三刻)|\s*(?<m>\d{1,2}|[零一二三四五六七八九十]{1,3})\s*分?)?',
);
final RegExp _clockPattern = RegExp(
  r'(?<![\d.])(?<h>\d{1,2})[:：](?<m>\d{2})(?!\d)',
);
final RegExp _datePattern = RegExp(r'(?<mo>\d{1,2})月(?<d>\d{1,2})[日号]');
final RegExp _mealWordPattern = RegExp(r'早饭|早餐|午饭|午餐|中饭|晚饭|晚餐|夜宵|宵夜');

int? _smallNumber(String raw) {
  final asInt = int.tryParse(raw);
  if (asInt != null) return asInt;
  return parseChineseInteger(raw)?.toInt();
}

final class _TimeResult {
  _TimeResult(this.ms, this.explicit, this.spans);
  final int ms;
  final bool explicit;
  final List<(int, int)> spans;
}

_TimeResult _resolveTime(String text, int nowMs) {
  final now = DateTime.fromMillisecondsSinceEpoch(nowMs);
  final spans = <(int, int)>[];
  var dayOffset = 0;
  var hasDay = false;
  DateTime? explicitDate;

  final dayMatch = _dayWordPattern.firstMatch(text);
  if (dayMatch != null) {
    spans.add((dayMatch.start, dayMatch.end));
    switch (dayMatch.group(0)) {
      case '大前天':
        dayOffset = -3;
      case '前天':
        dayOffset = -2;
      case '昨天':
      case '昨日':
        dayOffset = -1;
      default:
        dayOffset = 0;
    }
    hasDay = dayMatch.group(0) != '刚才' && dayMatch.group(0) != '刚刚';
  }

  final dateMatch = _datePattern.firstMatch(text);
  if (dateMatch != null) {
    final mo = int.parse(dateMatch.namedGroup('mo')!);
    final d = int.parse(dateMatch.namedGroup('d')!);
    if (mo >= 1 && mo <= 12 && d >= 1 && d <= 31) {
      var candidate = DateTime(now.year, mo, d, now.hour, now.minute);
      if (candidate.month == mo && candidate.day == d) {
        if (candidate.isAfter(now.add(const Duration(days: 1)))) {
          candidate = DateTime(now.year - 1, mo, d, now.hour, now.minute);
        }
        explicitDate = candidate;
        spans.add((dateMatch.start, dateMatch.end));
      }
    }
  }

  String? period;
  final periodMatch = _periodWordPattern.firstMatch(text);
  if (periodMatch != null) {
    period = periodMatch.group(0);
    spans.add((periodMatch.start, periodMatch.end));
    if (period!.startsWith('昨')) {
      dayOffset = -1;
      hasDay = true;
    } else if (period.startsWith('前')) {
      dayOffset = -2;
      hasDay = true;
    } else if (period.startsWith('今')) {
      hasDay = true;
    }
  }

  int? hour;
  var minute = 0;
  final clock = _clockPattern.firstMatch(text);
  if (clock != null) {
    final h = int.parse(clock.namedGroup('h')!);
    final m = int.parse(clock.namedGroup('m')!);
    if (h <= 23 && m <= 59) {
      hour = h;
      minute = m;
      spans.add((clock.start, clock.end));
    }
  }
  if (hour == null) {
    for (final hm in _hourPattern.allMatches(text)) {
      final h = _smallNumber(hm.namedGroup('h')!);
      if (h == null || h > 24) continue;
      var mi = 0;
      final half = hm.namedGroup('half');
      if (half == '半') {
        mi = 30;
      } else if (half == '一刻') {
        mi = 15;
      } else if (half == '三刻') {
        mi = 45;
      } else if (hm.namedGroup('m') != null) {
        mi = _smallNumber(hm.namedGroup('m')!) ?? 0;
        if (mi > 59) mi = 0;
      }
      hour = h == 24 ? 0 : h;
      minute = mi;
      spans.add((hm.start, hm.end));
      break;
    }
  }

  if (hour != null && period != null) {
    final isAfternoon = RegExp(r'下午|傍晚|晚|夜').hasMatch(period);
    final isNight = period == '夜里';
    if (period == '中午') {
      if (hour <= 2) hour += 12;
    } else if (isAfternoon && hour < 12 && !(isNight && hour <= 4)) {
      hour += 12;
    }
  }

  var explicit = hour != null || explicitDate != null || hasDay;
  if (hour == null && period != null) {
    hour = switch (period) {
      '今早' || '今晨' || '昨早' || '早上' || '早晨' => 8,
      '上午' => 10,
      '中午' => 12,
      '下午' => 15,
      '傍晚' => 18,
      '凌晨' => 2,
      _ => 20,
    };
  }
  if (hour == null && (hasDay && dayOffset != 0 || explicitDate != null)) {
    final meal = _mealWordPattern.firstMatch(text)?.group(0);
    hour = switch (meal) {
      '早饭' || '早餐' => 8,
      '午饭' || '午餐' || '中饭' => 12,
      '晚饭' || '晚餐' => 19,
      '夜宵' || '宵夜' => 22,
      _ => null,
    };
  }

  final baseDay = explicitDate ?? now.add(Duration(days: dayOffset));
  if (hour == null && minute == 0 && !explicit) {
    return _TimeResult(nowMs, false, spans);
  }
  final resolved = DateTime(
    baseDay.year,
    baseDay.month,
    baseDay.day,
    hour ?? now.hour,
    hour == null ? now.minute : minute,
  );
  explicit = true;
  return _TimeResult(resolved.millisecondsSinceEpoch, explicit, spans);
}

// ---------------------------------------------------------------------------
// Direction
// ---------------------------------------------------------------------------

final RegExp _transferCue = RegExp(
  r'转到|转入到|转账到|转存到|转存|还款到|还信用卡|信用卡还款|还花呗|还白条|提现到|充值到',
);
final RegExp _incomeCue = RegExp(
  r'收款(?!方|人)|收到|收入|工资|薪水|薪资|奖金|入账|到账|退回|退款|返现|报销款|收红包|红包收|利息|分红|赚了|进账|卖了|卖出',
);

int _detectNlpDirection(String text) {
  if (_transferCue.hasMatch(text)) return RecordType.transfer;
  if (_incomeCue.hasMatch(text)) return RecordType.income;
  return RecordType.expense;
}

final RegExp _expenseVerbCue = RegExp(r'花了|花费|买了|买|付了|付款|支付|刷了|刷卡|消费|支出|缴费|交了');

// ---------------------------------------------------------------------------
// Assets & categories
// ---------------------------------------------------------------------------

const List<String> _assetHintTokens = [
  '微信零钱',
  '零钱通',
  '微信',
  '支付宝',
  '花呗',
  '余额宝',
  '白条',
  '云闪付',
  '数字人民币',
  '现金',
  '信用卡',
  '储蓄卡',
  '银行卡',
  '招商银行',
  '招行',
  '工商银行',
  '工行',
  '建设银行',
  '建行',
  '农业银行',
  '农行',
  '中国银行',
  '中行',
  '交通银行',
  '交行',
  '邮储银行',
  '邮储',
  '中信银行',
  '光大银行',
  '浦发银行',
  '民生银行',
  '兴业银行',
  '平安银行',
  '广发银行',
];

const Map<String, List<String>> _assetAliases = {
  '招行': ['招商', '招行'],
  '招商银行': ['招商', '招行'],
  '工行': ['工商', '工行'],
  '工商银行': ['工商', '工行'],
  '建行': ['建设', '建行'],
  '建设银行': ['建设', '建行'],
  '农行': ['农业', '农行'],
  '农业银行': ['农业', '农行'],
  '中行': ['中国银行', '中行'],
  '中国银行': ['中国银行', '中行'],
  '交行': ['交通银行', '交行'],
  '交通银行': ['交通银行', '交行'],
  '邮储': ['邮储', '邮政'],
  '邮储银行': ['邮储', '邮政'],
  '微信': ['微信', '零钱'],
  '微信零钱': ['微信', '零钱'],
  '零钱通': ['零钱通', '微信'],
  '支付宝': ['支付宝'],
};

final class _AssetHit {
  const _AssetHit(this.name, this.start, this.end);
  final String name;
  final int start;
  final int end;
}

List<_AssetHit> _findAssetHits(String text, List<String> assetNames) {
  final lower = text.toLowerCase();
  final hits = <_AssetHit>[];
  bool overlaps(int s, int e) => hits.any((h) => s < h.end && e > h.start);

  final sortedNames =
      assetNames
          .map((n) => n.trim())
          .where((n) => n.isNotEmpty)
          .toSet()
          .toList()
        ..sort((a, b) => b.length.compareTo(a.length));
  for (final name in sortedNames) {
    final idx = lower.indexOf(name.toLowerCase());
    if (idx >= 0 && !overlaps(idx, idx + name.length)) {
      hits.add(_AssetHit(name, idx, idx + name.length));
    }
  }

  for (final token in _assetHintTokens) {
    var from = 0;
    while (true) {
      final idx = lower.indexOf(token.toLowerCase(), from);
      if (idx < 0) break;
      from = idx + token.length;
      if (overlaps(idx, idx + token.length)) continue;
      // Try mapping the colloquial token onto a real user asset name.
      final aliases = _assetAliases[token] ?? [token];
      String? mapped;
      for (final name in sortedNames.reversed) {
        final ln = name.toLowerCase();
        if (aliases.any((a) => ln.contains(a.toLowerCase())) ||
            ln.contains(token.toLowerCase())) {
          mapped = name;
          break;
        }
      }
      // Extend "招行卡" / "工行储蓄卡" spans so the remark stays clean.
      var end = idx + token.length;
      final tail = RegExp(
        r'^(?:储蓄卡|信用卡|借记卡|卡)',
      ).firstMatch(text.substring(end));
      if (tail != null) end += tail.end;
      hits.add(_AssetHit(mapped ?? text.substring(idx, end), idx, end));
    }
  }

  final tailNo = RegExp(r'尾号\s*(\d{4})').firstMatch(text);
  if (tailNo != null && !overlaps(tailNo.start, tailNo.end)) {
    final digits = tailNo.group(1)!;
    final byTail = sortedNames.where((n) => n.contains(digits)).firstOrNull;
    hits.add(_AssetHit(byTail ?? '尾号$digits', tailNo.start, tailNo.end));
  }

  hits.sort((a, b) => a.start.compareTo(b.start));
  return hits;
}

const Map<String, String> _categorySynonyms = {
  '早饭': '早餐',
  '午饭': '午餐',
  '中饭': '午餐',
  '晚饭': '晚餐',
  '宵夜': '夜宵',
  '打车': '打车',
  '地铁': '地铁',
  '买菜': '买菜',
  '水果': '水果',
  '零食': '零食',
  '房租': '房租',
};

String? _inferCategoryKeyword(String text, int recordType) {
  if (recordType == RecordType.income) {
    if (RegExp(r'工资|薪水|薪资|代发').hasMatch(text)) return '工资';
    if (RegExp(r'奖金|年终').hasMatch(text)) return '奖金';
    if (RegExp(r'红包').hasMatch(text)) return '收红包';
    return null;
  }
  if (recordType == RecordType.transfer) return null;
  if (RegExp(
    r'早饭|早餐|午饭|午餐|中饭|晚饭|晚餐|夜宵|宵夜|包子|煎饼|油条|豆浆|面条|米粉|米线|饺子|外卖|奶茶|咖啡|瑞幸|星巴克|麦当劳|肯德基|火锅|烧烤|吃饭|聚餐|餐',
  ).hasMatch(text)) {
    return '餐饮';
  }
  if (RegExp(r'打车|地铁|公交|滴滴|高铁|火车|动车|机票|飞机|加油|停车|出租|单车|交通').hasMatch(text)) {
    return '交通';
  }
  if (RegExp(r'零食|饮料|薯片|雪糕').hasMatch(text)) return '零食';
  if (RegExp(r'纸巾|洗发|牙膏|日用').hasMatch(text)) return '日用品';
  if (RegExp(r'超市|买菜|菜市场|水果|淘宝|京东|拼多多|衣服|鞋|购物').hasMatch(text)) {
    return '购物';
  }
  if (RegExp(r'话费|流量|宽带').hasMatch(text)) return '话费';
  if (RegExp(r'电影|游戏|KTV|ktv|演唱会|会员').hasMatch(text)) return '娱乐';
  if (RegExp(r'医院|药|门诊|挂号|体检').hasMatch(text)) return '医疗';
  if (RegExp(r'健身|球|游泳|跑步|运动').hasMatch(text)) return '运动';
  if (RegExp(r'房租|水费|电费|燃气|物业|水电').hasMatch(text)) return '生活居家';
  if (RegExp(r'发红包|红包').hasMatch(text)) return '发红包';
  return null;
}

(String?, int, int) _findCategoryHint(
  String text,
  List<String> categoryNames,
  int recordType,
) {
  final lower = text.toLowerCase();
  final names =
      categoryNames
          .map((n) => n.trim())
          .where((n) => n.isNotEmpty)
          .toSet()
          .toList()
        ..sort((a, b) => b.length.compareTo(a.length));
  for (final name in names) {
    final idx = lower.indexOf(name.toLowerCase());
    if (idx >= 0) return (name, idx, idx + name.length);
  }
  for (final entry in _categorySynonyms.entries) {
    final idx = text.indexOf(entry.key);
    if (idx >= 0 && names.contains(entry.value)) {
      return (entry.value, -1, -1);
    }
  }
  return (_inferCategoryKeyword(text, recordType), -1, -1);
}

// ---------------------------------------------------------------------------
// Remark cleanup
// ---------------------------------------------------------------------------

final RegExp _fillerPattern = RegExp(
  r'花了|花费|付了|付款|支付了|支付|刷了|刷卡|消费了|消费|一共|总共|共计|合计|收到了|收到|收款|入账|到账|转到|转入到|转账到|转存到|还款到|提现到|充值到|通过|使用|块钱|元钱|人民币',
);

String _cleanRemark(String text) {
  var out = text
      .replaceAll(_fillerPattern, ' ')
      .replaceAll(RegExp(r'[，,。.!！?？;；:：、|()（）\[\]【】\s]+'), ' ')
      .trim();
  final onlyParticles = RegExp(r'^(?:了|的|用|在|给|和|是|钱|去|从)+$');
  final edges = RegExp(r'^(?:用|在|给|从)+|(?:了|的)+$');
  final parts = out
      .split(' ')
      .where((p) => !onlyParticles.hasMatch(p))
      .map((p) => p.replaceAll(edges, '').trim())
      .where((p) => p.isNotEmpty)
      .toList(growable: false);
  out = parts.join(' ');
  if (out.length > 60) out = out.substring(0, 60);
  return out;
}

String _blank(String text, Iterable<(int, int)> spans) {
  final chars = text.split('');
  for (final (s, e) in spans) {
    if (s < 0 || e <= s) continue;
    for (var i = s; i < e && i < chars.length; i++) {
      chars[i] = '|';
    }
  }
  return chars.join();
}

/// Offline colloquial Chinese bill parser (decision 7).
///
/// Examples: `"早饭包子8.5微信"`, `"昨天早饭买煎饼微信花了9块5"`,
/// `"三十二块八 打车"`, `"收到工资8,500元"`, `"从招行转到余额宝500"`.
/// Returns `null` when no positive amount can be extracted. All amounts are
/// exact `Money` (`BigInt` minor units, zero `double`, `ADR-011`).
SmartBillParseResult? parseNaturalLanguageBill(
  String input, {
  required int nowMs,
  List<String> categoryNames = const [],
  List<String> assetNames = const [],
}) {
  final text = input.replaceAll('\r\n', '\n').replaceAll('\n', ' ').trim();
  if (text.isEmpty || text.length > 2000) return null;

  final time = _resolveTime(text, nowMs);
  // Card-tail digits are never amounts.
  final tailSpans = [
    for (final m in RegExp(r'尾号\s*\d{4}').allMatches(text)) (m.start, m.end),
  ];
  final amountWork = _blank(text, [...time.spans, ...tailSpans]);
  final amount = _findAmount(amountWork);
  if (amount == null) return null;

  final recordType = _detectNlpDirection(text);
  final assetHits = _findAssetHits(
    _blank(text, [(amount.start, amount.end)]),
    assetNames,
  );

  String? assetHint;
  String? toAssetHint;
  if (recordType == RecordType.transfer && assetHits.isNotEmpty) {
    final cue = _transferCue.firstMatch(text);
    final cueIdx = cue?.start ?? 0;
    final after = assetHits.where((h) => h.start >= cueIdx).toList();
    final before = assetHits.where((h) => h.start < cueIdx).toList();
    toAssetHint = after.isNotEmpty ? after.first.name : null;
    assetHint = before.isNotEmpty
        ? before.first.name
        : assetHits.where((h) => h.name != toAssetHint).firstOrNull?.name;
  } else if (assetHits.isNotEmpty) {
    assetHint = assetHits.first.name;
  }

  final (categoryHint, catStart, catEnd) = _findCategoryHint(
    _blank(text, [(amount.start, amount.end)]),
    categoryNames,
    recordType,
  );

  // Remark: drop amount, time words, asset tokens; keep the rest.
  final baseSpans = <(int, int)>[
    (amount.start, amount.end),
    ...time.spans,
    for (final h in assetHits) (h.start, h.end),
  ];
  final dayAll = [
    for (final m in _dayWordPattern.allMatches(text)) (m.start, m.end),
    for (final m in _periodWordPattern.allMatches(text)) (m.start, m.end),
    for (final m in RegExp(r'从').allMatches(text)) (m.start, m.end),
  ];
  var remark = _cleanRemark(_blank(text, [...baseSpans, ...dayAll]));
  final mealSpans = [
    for (final m in _mealWordPattern.allMatches(text)) (m.start, m.end),
  ];
  if (mealSpans.isNotEmpty) {
    final withoutMeal = _cleanRemark(
      _blank(text, [...baseSpans, ...dayAll, ...mealSpans]),
    );
    if (withoutMeal.isNotEmpty) remark = withoutMeal;
  }
  if (catStart >= 0) {
    final withoutCat = _cleanRemark(
      _blank(text, [...baseSpans, ...dayAll, ...mealSpans, (catStart, catEnd)]),
    );
    if (withoutCat.isNotEmpty) remark = withoutCat;
  }
  if (remark.isEmpty && categoryHint != null) remark = categoryHint;

  final hasDirectionCue =
      _transferCue.hasMatch(text) ||
      _incomeCue.hasMatch(text) ||
      _expenseVerbCue.hasMatch(text);
  final confidence =
      amount.strength >= 2 &&
          (hasDirectionCue || assetHint != null || categoryHint != null)
      ? SmartBillConfidence.high
      : (amount.strength >= 2 || assetHint != null || categoryHint != null)
      ? SmartBillConfidence.medium
      : SmartBillConfidence.low;

  return SmartBillParseResult(
    recordType: recordType,
    money: amount.money,
    recordTimeMs: time.ms,
    hasExplicitTime: time.explicit,
    assetHint: assetHint,
    toAssetHint: toAssetHint,
    categoryHint: categoryHint,
    remark: remark,
    confidence: confidence,
    rawText: input.trim(),
  );
}

// ---------------------------------------------------------------------------
// AI request / response (OpenAI-compatible chat completions)
// ---------------------------------------------------------------------------

/// Builds OpenAI-compatible chat messages asking for strict JSON bills.
List<Map<String, String>> buildAiBillParserMessages(
  String text, {
  required int nowMs,
  List<String> categoryNames = const [],
  List<String> assetNames = const [],
}) {
  final now = DateTime.fromMillisecondsSinceEpoch(nowMs);
  String two(int v) => v.toString().padLeft(2, '0');
  final nowText =
      '${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}:${two(now.minute)}';
  final system = StringBuffer()
    ..writeln('你是记账助手。把用户提供的支付通知、短信、小票或口语记账文本解析为 JSON。')
    ..writeln('只输出 JSON，不要任何解释。格式：')
    ..writeln(
      '{"bills":[{"type":"expense|income|transfer","amount":"18.50","discount":"0.00",'
      '"time":"YYYY-MM-DD HH:mm","category":"分类名","account":"付款账户","toAccount":"转入账户",'
      '"remark":"商户或备注"}]}',
    )
    ..writeln('金额必须是带两位小数的字符串，且大于 0；无法确定的字段留空字符串。')
    ..writeln('当前时间：$nowText');
  if (categoryNames.isNotEmpty) {
    system.writeln('可选分类：${categoryNames.take(80).join('、')}');
  }
  if (assetNames.isNotEmpty) {
    system.writeln('可选账户：${assetNames.take(40).join('、')}');
  }
  return [
    {'role': 'system', 'content': system.toString().trim()},
    {'role': 'user', 'content': text.trim()},
  ];
}

final RegExp _jsonNumericMoneyField = RegExp(
  r'("(?:amount|money|discount|total|price)"\s*:\s*)(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)',
);

int _aiRecordType(Object? raw) {
  final v = raw?.toString().trim().toLowerCase() ?? '';
  switch (v) {
    case '1':
    case 'income':
    case '收入':
      return RecordType.income;
    case '2':
    case 'transfer':
    case '转账':
      return RecordType.transfer;
    default:
      return RecordType.expense;
  }
}

/// Parses an OpenAI-compatible model reply into validated bills.
///
/// Numeric JSON amounts are re-quoted **before** `jsonDecode` so they never pass
/// through `double`; each amount is validated by `parseUrlMoney` (`> 0`,
/// `<= 88888888888.00`). Invalid items are skipped; throws
/// `Failure(FailureCode.validation)` when no valid bill remains.
List<SmartBillParseResult> parseAiBillJsonResponse(
  String content, {
  required int nowMs,
}) {
  var body = content.trim();
  final firstObj = body.indexOf('{');
  final firstArr = body.indexOf('[');
  int start;
  if (firstObj < 0) {
    start = firstArr;
  } else if (firstArr < 0) {
    start = firstObj;
  } else {
    start = firstObj < firstArr ? firstObj : firstArr;
  }
  if (start < 0) {
    throw const Failure(FailureCode.validation, 'AI 返回内容不是有效 JSON');
  }
  final closer = body[start] == '{' ? '}' : ']';
  final end = body.lastIndexOf(closer);
  if (end <= start) {
    throw const Failure(FailureCode.validation, 'AI 返回内容不是有效 JSON');
  }
  body = body
      .substring(start, end + 1)
      .replaceAllMapped(_jsonNumericMoneyField, (m) => '${m[1]}"${m[2]}"');

  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    throw const Failure(FailureCode.validation, 'AI 返回内容不是有效 JSON');
  }

  final List<Object?> items;
  if (decoded is List) {
    items = decoded;
  } else if (decoded is Map) {
    final nested = decoded['bills'] ?? decoded['items'] ?? decoded['records'];
    items = nested is List ? nested : [decoded];
  } else {
    items = const [];
  }

  String? str(Map item, List<String> keys) {
    for (final k in keys) {
      final v = item[k];
      if (v == null) continue;
      final s = v.toString().trim();
      if (s.isNotEmpty) return s;
    }
    return null;
  }

  final out = <SmartBillParseResult>[];
  for (final item in items) {
    if (item is! Map) continue;
    var amountText = str(item, const ['amount', 'money', 'total', 'price']);
    if (amountText == null) continue;
    var type = _aiRecordType(item['type'] ?? item['recordType']);
    if (amountText.startsWith('-')) {
      amountText = amountText.substring(1);
      if (item['type'] == null) type = RecordType.expense;
    }
    final Money money;
    try {
      money = parseUrlMoney(amountText, fieldLabel: '金额');
    } on Failure {
      continue;
    }
    Money? discount;
    final discountText = str(item, const ['discount']);
    if (discountText != null) {
      try {
        final d = parseUrlMoney(
          discountText,
          fieldLabel: '优惠',
          allowZero: true,
        );
        if (!d.isZero && d.units <= money.units) discount = d;
      } on Failure {
        discount = null;
      }
    }
    var timeMs = nowMs;
    var explicitTime = false;
    final timeText = str(item, const ['time', 'datetime', 'date']);
    if (timeText != null) {
      try {
        final parsed = parseUrlDateTimeMs(timeText);
        if (parsed != null) {
          timeMs = parsed;
          explicitTime = true;
        }
      } on Failure {
        timeMs = nowMs;
      }
    }
    out.add(
      SmartBillParseResult(
        recordType: type,
        money: money,
        discount: discount,
        recordTimeMs: timeMs,
        hasExplicitTime: explicitTime,
        assetHint: str(item, const ['account', 'asset', 'from', 'fromAccount']),
        toAssetHint: str(item, const ['toAccount', 'toAsset', 'to']),
        categoryHint: str(item, const ['category', 'cate']),
        remark: str(item, const ['remark', 'note', 'merchant']) ?? '',
        confidence: SmartBillConfidence.high,
        rawText: content.trim(),
        source: 'ai',
      ),
    );
  }
  if (out.isEmpty) {
    throw const Failure(FailureCode.validation, 'AI 返回内容中没有可识别的有效账单');
  }
  return out;
}
