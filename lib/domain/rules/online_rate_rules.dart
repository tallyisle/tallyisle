import 'dart:convert';

import '../../core/failure.dart';
import '../../core/money.dart';
import 'asset_overview.dart' show normalizeCurrency;
import 'currency_rates.dart';

/// `ti_preference` key storing serialized [OnlineRateSettings] JSON.
const String onlineRateSettingsPreferenceKey = 'online_rate_settings';

/// Default cooldown interval (24 hours) for optional launch auto-sync.
const int defaultOnlineRateSyncIntervalHours = 24;

/// Honest `ADR-017` capability reason when online exchange rates are disabled.
const String offlineExchangeRateCapabilityReason = '默认离线（未开启联网汇率）';

/// Upper bound for `1 CNY = r <CODE>` (`10^9` units per 1 anchor unit).
final BigInt maxOnlineRateToAnchorUnits = BigInt.from(1000000000);

const _corruptOnlineRateSettings = Failure(
  FailureCode.corruptData,
  '在线汇率设置格式损坏',
);

const Set<String> _flatPayloadMetadataKeys = <String>{
  'date',
  'time_last_update_unix',
  'time_last_update_utc',
  'time_next_update_unix',
  'time_next_update_utc',
  'time_eol_unix',
  'documentation',
  'terms_of_use',
  'provider',
  'result',
  'success',
  'base',
  'base_code',
  'basecurrency',
  'anchor',
  'amount',
  'timestamp',
  'updated_at',
};

final RegExp _currencyCodePattern = RegExp(r'^[A-Z]{3,8}$');
final RegExp _scientificDecimalPattern = RegExp(
  r'^([+-]?)([0-9]+)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]{1,4}))?$',
);

/// Validates and normalizes an optional custom exchange rate endpoint URL.
///
/// An empty string `''` means using the built-in keyless public failover chain.
/// A non-empty string must be a valid `http://` or `https://` URL with host.
String validateCustomRateEndpointUrl(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '';
  if (trimmed.length > 512) {
    throw const Failure(FailureCode.validation, '自定义汇率源地址长度不能超过 512 字符');
  }
  final uri = Uri.tryParse(trimmed);
  if (uri == null ||
      !uri.hasAuthority ||
      uri.host.trim().isEmpty ||
      (uri.scheme != 'https' && uri.scheme != 'http')) {
    throw const Failure(
      FailureCode.validation,
      '自定义汇率源须为有效的 https:// 或 http:// 地址',
    );
  }
  return trimmed;
}

/// Privacy-first configuration for optional online exchange rate sync.
///
/// Strictly disabled (`enabled == false`) by default so the app makes ZERO
/// network calls unless explicitly opted in by the user.
final class OnlineRateSettings {
  const OnlineRateSettings({
    this.enabled = false,
    this.autoSyncOnLaunch = true,
    this.syncIntervalHours = defaultOnlineRateSyncIntervalHours,
    this.customEndpointUrl = '',
    this.lastSyncedAtMs = 0,
    this.lastSyncSource = '',
  });

  static const OnlineRateSettings defaults = OnlineRateSettings();

  /// Master opt-in switch (`false` by default!).
  final bool enabled;

  /// Whether to auto-sync once every [syncIntervalHours] when [enabled] is on.
  final bool autoSyncOnLaunch;

  /// Cooldown hours between automatic sync runs (default 24h).
  final int syncIntervalHours;

  /// Optional custom JSON endpoint (`''` uses built-in public failover).
  final String customEndpointUrl;

  /// Epoch milliseconds of the last successful online sync (`0` = never).
  final int lastSyncedAtMs;

  /// Label/host of the endpoint that served the last sync (`''` = none).
  final String lastSyncSource;

  bool get hasCustomEndpoint => customEndpointUrl.trim().isNotEmpty;

  int get syncCooldownMs =>
      (syncIntervalHours <= 0
          ? defaultOnlineRateSyncIntervalHours
          : syncIntervalHours) *
      60 *
      60 *
      1000;

  /// Returns `true` ONLY when [enabled] AND [autoSyncOnLaunch] are both true
  /// and at least [syncCooldownMs] has elapsed since [lastSyncedAtMs].
  bool shouldAutoSync({required int nowMs}) {
    if (!enabled || !autoSyncOnLaunch) return false;
    if (lastSyncedAtMs <= 0) return true;
    if (nowMs < lastSyncedAtMs) return false;
    return nowMs - lastSyncedAtMs >= syncCooldownMs;
  }

  OnlineRateSettings validated() {
    if (syncIntervalHours <= 0 || syncIntervalHours > 24 * 365) {
      throw const Failure(FailureCode.validation, '自动同步间隔须在 1–8760 小时之间');
    }
    if (lastSyncedAtMs < 0) {
      throw const Failure(FailureCode.validation, '最近同步时间戳无效');
    }
    final cleanUrl = validateCustomRateEndpointUrl(customEndpointUrl);
    final cleanSource = lastSyncSource.trim();
    if (cleanSource.length > 200) {
      throw const Failure(FailureCode.validation, '汇率来源标识过长');
    }
    return OnlineRateSettings(
      enabled: enabled,
      autoSyncOnLaunch: autoSyncOnLaunch,
      syncIntervalHours: syncIntervalHours,
      customEndpointUrl: cleanUrl,
      lastSyncedAtMs: lastSyncedAtMs,
      lastSyncSource: cleanSource,
    );
  }

  OnlineRateSettings copyWith({
    bool? enabled,
    bool? autoSyncOnLaunch,
    int? syncIntervalHours,
    String? customEndpointUrl,
    int? lastSyncedAtMs,
    String? lastSyncSource,
  }) => OnlineRateSettings(
    enabled: enabled ?? this.enabled,
    autoSyncOnLaunch: autoSyncOnLaunch ?? this.autoSyncOnLaunch,
    syncIntervalHours: syncIntervalHours ?? this.syncIntervalHours,
    customEndpointUrl: customEndpointUrl ?? this.customEndpointUrl,
    lastSyncedAtMs: lastSyncedAtMs ?? this.lastSyncedAtMs,
    lastSyncSource: lastSyncSource ?? this.lastSyncSource,
  );

  Map<String, Object> toJson() => <String, Object>{
    'enabled': enabled,
    'autoSyncOnLaunch': autoSyncOnLaunch,
    'syncIntervalHours': syncIntervalHours,
    'customEndpointUrl': customEndpointUrl,
    'lastSyncedAtMs': lastSyncedAtMs,
    'lastSyncSource': lastSyncSource,
  };

  String encode() => jsonEncode(toJson());

  static OnlineRateSettings parse(String? text) {
    if (text == null || text.trim().isEmpty) return defaults;
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw _corruptOnlineRateSettings;
    }
    if (decoded is! Map<String, Object?>) throw _corruptOnlineRateSettings;

    final enabled = decoded['enabled'] ?? false;
    final autoSync = decoded['autoSyncOnLaunch'] ?? true;
    final interval =
        decoded['syncIntervalHours'] ?? defaultOnlineRateSyncIntervalHours;
    final customUrl = decoded['customEndpointUrl'] ?? '';
    final lastSynced = decoded['lastSyncedAtMs'] ?? 0;
    final lastSource = decoded['lastSyncSource'] ?? '';

    if (enabled is! bool ||
        autoSync is! bool ||
        interval is! int ||
        customUrl is! String ||
        lastSynced is! int ||
        lastSource is! String) {
      throw _corruptOnlineRateSettings;
    }

    try {
      return OnlineRateSettings(
        enabled: enabled,
        autoSyncOnLaunch: autoSync,
        syncIntervalHours: interval,
        customEndpointUrl: customUrl,
        lastSyncedAtMs: lastSynced,
        lastSyncSource: lastSource,
      ).validated();
    } on Failure {
      throw _corruptOnlineRateSettings;
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OnlineRateSettings &&
          enabled == other.enabled &&
          autoSyncOnLaunch == other.autoSyncOnLaunch &&
          syncIntervalHours == other.syncIntervalHours &&
          customEndpointUrl == other.customEndpointUrl &&
          lastSyncedAtMs == other.lastSyncedAtMs &&
          lastSyncSource == other.lastSyncSource;

  @override
  int get hashCode => Object.hash(
    enabled,
    autoSyncOnLaunch,
    syncIntervalHours,
    customEndpointUrl,
    lastSyncedAtMs,
    lastSyncSource,
  );
}

/// Parses a JSON number or numeric string into an exact positive [DecimalValue]
/// (`BigInt` arithmetic only; rejects `<= 0`, `NaN`, `Infinity`, and bounds).
DecimalValue parsePositiveOnlineDecimal(Object? raw) {
  if (raw == null || raw is bool || raw is List || raw is Map) {
    throw const Failure(FailureCode.validation, '汇率值须为正十进制数');
  }
  if (raw is! num && raw is! String) {
    throw const Failure(FailureCode.validation, '汇率值须为正十进制数');
  }
  final text = raw.toString().trim();
  if (text.isEmpty) {
    throw const Failure(FailureCode.validation, '汇率值不能为空');
  }
  final lower = text.toLowerCase();
  if (lower == 'nan' ||
      lower == 'infinity' ||
      lower == '+infinity' ||
      lower == '-infinity' ||
      lower == 'inf' ||
      lower == '+inf' ||
      lower == '-inf') {
    throw const Failure(FailureCode.validation, '汇率值不能为 NaN 或无穷大');
  }

  // Fast path for standard plain decimals within scale 0..30.
  if (RegExp(r'^[0-9]+(?:\.[0-9]{1,30})?$').hasMatch(text)) {
    final dv = DecimalValue.parse(text);
    if (dv.coefficient <= BigInt.zero) {
      throw const Failure(FailureCode.validation, '汇率须为正数');
    }
    return dv;
  }

  final match = _scientificDecimalPattern.firstMatch(text);
  if (match == null) {
    throw const Failure(FailureCode.validation, '汇率格式无效');
  }
  if (match.group(1) == '-') {
    throw const Failure(FailureCode.validation, '汇率须为正数');
  }
  final intPart = match.group(2)!;
  final fracPart = match.group(3) ?? '';
  final expGroup = match.group(4);
  final exponent = expGroup == null ? 0 : int.parse(expGroup);

  final trimmedDigits = '$intPart$fracPart'.replaceFirst(RegExp(r'^0+'), '');
  if (trimmedDigits.isEmpty) {
    throw const Failure(FailureCode.validation, '汇率须为正数');
  }

  // Exact base-10 order of magnitude of the leading significant digit.
  final orderOfMagnitude =
      trimmedDigits.length - 1 + exponent - fracPart.length;
  if (orderOfMagnitude > 12) {
    throw const Failure(FailureCode.validation, '汇率超出合理上限');
  }
  if (orderOfMagnitude < -18) {
    throw const Failure(FailureCode.validation, '汇率过小，超出精度下限');
  }

  final fracScale = fracPart.length - exponent;
  if (fracScale <= 0) {
    final expanded = '$trimmedDigits${'0' * (-fracScale)}';
    return DecimalValue.parse(expanded);
  }
  if (fracScale <= 30) {
    return DecimalValue(BigInt.parse(trimmedDigits), fracScale);
  }

  // When fractional precision exceeds 30 digits, round HALF_UP to 18 decimals
  // via exact BigInt integer division so DecimalValue stays within scale <= 30.
  const targetIntermediateScale = 18;
  final roundedCoeff = divideRounded(
    BigInt.parse(trimmedDigits),
    BigInt.from(10).pow(fracScale - targetIntermediateScale),
    RoundingMode.halfUp,
  );
  if (roundedCoeff <= BigInt.zero) {
    throw const Failure(FailureCode.validation, '汇率过小，超出精度下限');
  }
  return DecimalValue(roundedCoeff, targetIntermediateScale);
}

/// Converts a single quoted rate (`1 CNY = r <CODE>`, or `[perBaseAmount] CNY = r <CODE>`)
/// into a validated, normalized 12-decimal `rate_to_anchor` string (`HALF_UP`).
String convertOnlineQuoteToRateToAnchor(
  Object? rawQuote, {
  DecimalValue? perBaseAmount,
}) {
  final quote = parsePositiveOnlineDecimal(rawQuote);
  final baseAmt = perBaseAmount ?? DecimalValue(BigInt.one, 0);
  if (baseAmt.coefficient <= BigInt.zero) {
    throw const Failure(FailureCode.validation, '基准金额须为正数');
  }

  final BigInt scaled12;
  if (baseAmt.coefficient == BigInt.one && baseAmt.scale == 0) {
    scaled12 = quote.unitsAt(rateToAnchorScale, rounding: RoundingMode.halfUp);
  } else {
    final numerator =
        quote.coefficient *
        BigInt.from(10).pow(baseAmt.scale + rateToAnchorScale);
    final denominator = baseAmt.coefficient * BigInt.from(10).pow(quote.scale);
    scaled12 = divideRounded(numerator, denominator, RoundingMode.halfUp);
  }

  if (scaled12 <= BigInt.zero) {
    throw const Failure(FailureCode.validation, '汇率过小，四舍五入后为 0');
  }
  final maxScaled12 =
      maxOnlineRateToAnchorUnits * powerOfTen(rateToAnchorScale);
  if (scaled12 > maxScaled12) {
    throw const Failure(FailureCode.validation, '汇率超出合理上限');
  }
  return formatRateDecimal(scaled12, rateToAnchorScale);
}

/// Validated result of parsing an online exchange-rate JSON payload.
final class ParsedOnlineRates {
  ParsedOnlineRates({
    required this.baseCode,
    required Map<String, String> ratesToAnchor,
    this.providerDate,
    Set<String> rejectedCodes = const <String>{},
  }) : ratesToAnchor = Map<String, String>.unmodifiable(ratesToAnchor),
       rejectedCodes = Set<String>.unmodifiable(rejectedCodes);

  final String baseCode;

  /// Normalized currency code -> 12-decimal `rate_to_anchor` string.
  final Map<String, String> ratesToAnchor;

  /// Optional provider date string (e.g. `"2026-11-11"`).
  final String? providerDate;

  /// Codes present in the payload whose values were invalid and rejected.
  final Set<String> rejectedCodes;
}

/// Parses CNY-base rate payloads across multiple keyless JSON formats:
/// 1. `open.er-api.com`: `{"result":"success","base_code":"CNY","rates":{...}}`
/// 2. `fawazahmed0/currency-api`: `{"date":"2026-11-11","cny":{"usd":0.138889,...}}`
/// 3. `api.frankfurter.dev`: `{"amount":1.0,"base":"CNY","rates":{...}}`
/// 4. Custom flat `{...}` or nested `{"data":{...}}` / `{"rates":{...}}`.
ParsedOnlineRates parseOnlineRatesPayload(
  String jsonBody, {
  String baseCode = baseCurrency,
}) {
  final expectedBase = normalizeCurrency(baseCode);
  if (expectedBase == null || !_currencyCodePattern.hasMatch(expectedBase)) {
    throw const Failure(FailureCode.validation, '目标本位币代码无效');
  }
  if (jsonBody.trim().isEmpty) {
    throw const Failure(FailureCode.validation, '汇率响应内容为空');
  }

  final Object? decoded;
  try {
    decoded = jsonDecode(jsonBody);
  } on FormatException {
    throw const Failure(FailureCode.validation, '汇率响应不是合法的 JSON');
  }
  if (decoded is! Map) {
    throw const Failure(FailureCode.validation, '汇率响应须为 JSON 对象');
  }

  final resultField = decoded['result'];
  if (resultField is String && resultField.trim().toLowerCase() == 'error') {
    throw const Failure(FailureCode.validation, '汇率源返回错误状态');
  }
  if (decoded['success'] == false) {
    throw const Failure(FailureCode.validation, '汇率源返回失败状态');
  }

  _verifyOptionalBaseCode(decoded, expectedBase);

  DecimalValue baseAmount = DecimalValue(BigInt.one, 0);
  if (decoded.containsKey('amount') && decoded['amount'] != null) {
    baseAmount = parsePositiveOnlineDecimal(decoded['amount']);
  }

  final rawDate = decoded['date'];
  final providerDate = rawDate is String && rawDate.trim().isNotEmpty
      ? rawDate.trim()
      : null;

  final (Map<Object?, Object?> rawMap, bool isFlatRoot) = _extractRatesMap(
    decoded,
    expectedBase,
  );

  final normalizedRates = <String, String>{};
  final rejected = <String>{};

  for (final entry in rawMap.entries) {
    final key = entry.key;
    if (key is! String) continue;
    final trimmedKey = key.trim();
    if (trimmedKey.isEmpty) continue;
    if (isFlatRoot &&
        _flatPayloadMetadataKeys.contains(trimmedKey.toLowerCase())) {
      continue;
    }

    final code = normalizeCurrency(trimmedKey);
    if (code == null || !_currencyCodePattern.hasMatch(code)) {
      // Ignore non-ISO keys (e.g. token tickers like "1inch" or metadata fields).
      continue;
    }
    if (code == expectedBase) {
      // Base currency is anchored at '1' and never overwritten from remote quotes.
      continue;
    }

    try {
      normalizedRates[code] = convertOnlineQuoteToRateToAnchor(
        entry.value,
        perBaseAmount: baseAmount,
      );
    } on Failure {
      rejected.add(code);
    }
  }

  if (normalizedRates.isEmpty) {
    throw const Failure(FailureCode.validation, '未从响应中解析到任何有效外币汇率');
  }

  return ParsedOnlineRates(
    baseCode: expectedBase,
    ratesToAnchor: normalizedRates,
    providerDate: providerDate,
    rejectedCodes: rejected,
  );
}

void _verifyOptionalBaseCode(Map<Object?, Object?> map, String expectedBase) {
  for (final key in const ['base_code', 'base', 'baseCurrency', 'anchor']) {
    final v = map[key];
    if (v is String && v.trim().isNotEmpty) {
      final actual = normalizeCurrency(v);
      if (actual != expectedBase) {
        throw Failure(
          FailureCode.validation,
          '汇率源基准币种不匹配：期望 $expectedBase，实际为 ${actual ?? v}',
        );
      }
    }
  }
}

(Map<Object?, Object?>, bool) _extractRatesMap(
  Map<Object?, Object?> root,
  String expectedBase,
) {
  final rates = root['rates'];
  if (rates is Map) return (rates, false);

  final conversionRates = root['conversion_rates'];
  if (conversionRates is Map) return (conversionRates, false);

  // Format 2 (`fawazahmed0/currency-api`): key matches base currency code case-insensitively.
  for (final entry in root.entries) {
    final k = entry.key;
    if (k is String &&
        k.trim().toUpperCase() == expectedBase &&
        entry.value is Map) {
      return (entry.value as Map<Object?, Object?>, false);
    }
  }

  final data = root['data'];
  if (data is Map) {
    _verifyOptionalBaseCode(data, expectedBase);
    final nestedRates = data['rates'];
    if (nestedRates is Map) return (nestedRates, false);
    return (data, false);
  }

  return (root, true);
}
