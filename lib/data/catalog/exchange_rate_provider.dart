import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../core/failure.dart';
import '../../domain/rules/asset_overview.dart' show normalizeCurrency;
import '../../domain/rules/currency_rates.dart';
import '../../domain/rules/online_rate_rules.dart';
import '../../platform/files.dart';

/// Snapshot of foreign exchange rates fetched from an [ExchangeRateProvider].
final class FetchedExchangeRates {
  FetchedExchangeRates({
    required this.baseCode,
    required Map<String, String> ratesToAnchor,
    required this.sourceLabel,
    required this.sourceUrl,
    required this.fetchedAtMs,
    this.providerDate,
  }) : ratesToAnchor = Map<String, String>.unmodifiable(ratesToAnchor);

  /// Base (anchor) currency code (e.g. `'CNY'`).
  final String baseCode;

  /// Normalized foreign currency code -> 12-decimal `rate_to_anchor` string.
  final Map<String, String> ratesToAnchor;

  /// Concise human-readable label of the winning endpoint (e.g. `'open.er-api.com'`).
  final String sourceLabel;

  /// Full URL of the endpoint that served the payload.
  final String sourceUrl;

  /// Epoch milliseconds when the response was parsed.
  final int fetchedAtMs;

  /// Optional quote date reported by the upstream API.
  final String? providerDate;
}

/// Pluggable exchange-rate provider boundary (`ADR-017`, `P-03`).
///
/// Must report `CapabilityState.unconfigured` with `'默认离线（未开启联网汇率）'`
/// and strictly refuse network calls when disabled.
abstract interface class ExchangeRateProvider {
  Capability get capability;

  Future<FetchedExchangeRates> fetchRatesRelativeToBase({
    String baseCode = baseCurrency,
  });
}

/// Pure offline provider that never performs network I/O (`ADR-017`).
final class OfflineExchangeRateProvider implements ExchangeRateProvider {
  const OfflineExchangeRateProvider();

  @override
  Capability get capability => const Capability(
    CapabilityState.unconfigured,
    offlineExchangeRateCapabilityReason,
  );

  @override
  Future<FetchedExchangeRates> fetchRatesRelativeToBase({
    String baseCode = baseCurrency,
  }) {
    throw const Failure(
      FailureCode.unsupportedCapability,
      offlineExchangeRateCapabilityReason,
    );
  }
}

/// Keyless multi-source HTTP exchange-rate provider with 8-second timeout and
/// automatic failover (`ADR-017`).
final class HttpExchangeRateProvider implements ExchangeRateProvider {
  HttpExchangeRateProvider({
    this.settings = OnlineRateSettings.defaults,
    HttpClient Function()? httpClientFactory,
    this.timeout = defaultTimeout,
    int Function()? nowMs,
  }) : _httpClientFactory = httpClientFactory ?? HttpClient.new,
       _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  static const Duration defaultTimeout = Duration(seconds: 8);
  static const int _maxResponseBytes = 4 * 1024 * 1024;

  final OnlineRateSettings settings;
  final HttpClient Function() _httpClientFactory;
  final Duration timeout;
  final int Function() _nowMs;

  /// Built-in keyless public endpoints for [baseCode] in failover priority order:
  /// 1. `open.er-api.com`
  /// 2. `fawazahmed0/currency-api` (jsDelivr CDN)
  /// 3. `api.frankfurter.dev` (ECB reference rates)
  static List<String> publicEndpointsForBase(String baseCode) {
    final upper = normalizeCurrency(baseCode) ?? baseCurrency;
    final lower = upper.toLowerCase();
    return <String>[
      'https://open.er-api.com/v6/latest/$upper',
      'https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/$lower.json',
      'https://api.frankfurter.dev/v1/latest?base=$upper',
    ];
  }

  /// Ordered candidate URLs: custom endpoint first (if configured), followed by
  /// built-in public failover endpoints.
  List<String> candidateEndpoints({String baseCode = baseCurrency}) {
    final custom = validateCustomRateEndpointUrl(settings.customEndpointUrl);
    final builtins = publicEndpointsForBase(baseCode);
    if (custom.isEmpty) return builtins;
    return <String>[custom, ...builtins.where((u) => u != custom)];
  }

  @override
  Capability get capability {
    if (!settings.enabled) {
      return const Capability(
        CapabilityState.unconfigured,
        offlineExchangeRateCapabilityReason,
      );
    }
    try {
      final custom = validateCustomRateEndpointUrl(settings.customEndpointUrl);
      if (custom.isNotEmpty) {
        final host = Uri.parse(custom).host;
        return Capability(CapabilityState.available, '已开启（自定义源：$host）');
      }
    } on Failure catch (f) {
      return Capability(CapabilityState.unconfigured, f.message);
    }
    return const Capability(CapabilityState.available, '已开启（公共免密钥多源容灾）');
  }

  @override
  Future<FetchedExchangeRates> fetchRatesRelativeToBase({
    String baseCode = baseCurrency,
  }) async {
    // Strict privacy gate: NEVER instantiate HttpClient or make network calls when disabled!
    if (!settings.enabled) {
      throw const Failure(
        FailureCode.unsupportedCapability,
        offlineExchangeRateCapabilityReason,
      );
    }

    final normalizedBase = normalizeCurrency(baseCode);
    if (normalizedBase == null ||
        !RegExp(r'^[A-Z]{3,8}$').hasMatch(normalizedBase)) {
      throw const Failure(FailureCode.validation, '本位币代码无效');
    }

    final customUrl = validateCustomRateEndpointUrl(settings.customEndpointUrl);
    final urls = candidateEndpoints(baseCode: normalizedBase);
    String lastReason = '无可用汇率源';

    for (final url in urls) {
      final isCustom = customUrl.isNotEmpty && url == customUrl;
      try {
        final body = await _getJsonText(Uri.parse(url));
        final parsed = parseOnlineRatesPayload(body, baseCode: normalizedBase);
        final uri = Uri.parse(url);
        final sourceLabel = isCustom ? '自定义源 (${uri.host})' : uri.host;
        return FetchedExchangeRates(
          baseCode: parsed.baseCode,
          ratesToAnchor: parsed.ratesToAnchor,
          sourceLabel: sourceLabel,
          sourceUrl: url,
          fetchedAtMs: _nowMs(),
          providerDate: parsed.providerDate,
        );
      } on Failure catch (f) {
        lastReason = f.message;
      } on TimeoutException {
        lastReason = '请求超时';
      } on SocketException {
        lastReason = '网络连接失败';
      } on HttpException {
        lastReason = 'HTTP 协议异常';
      } catch (_) {
        lastReason = '汇率源响应异常';
      }
    }

    throw Failure(
      FailureCode.remoteUnavailable,
      '无法获取最新在线汇率（已尝试 ${urls.length} 个汇率源：$lastReason）',
    );
  }

  Future<String> _getJsonText(Uri uri) {
    final completer = Completer<String>();
    Zone.root.run(() async {
      final client = _httpClientFactory()..connectionTimeout = timeout;
      try {
        final request = await client.getUrl(uri).timeout(timeout);
        request.headers.set(HttpHeaders.acceptHeader, 'application/json');
        final response = await request.close().timeout(timeout);

        if (response.statusCode < 200 || response.statusCode >= 300) {
          await response.drain<void>().timeout(timeout);
          throw Failure(
            FailureCode.remoteUnavailable,
            '汇率源返回 HTTP ${response.statusCode}',
          );
        }

        final chunks = BytesBuilder(copy: false);
        await for (final chunk in response.timeout(timeout)) {
          if (chunks.length + chunk.length > _maxResponseBytes) {
            throw const Failure(FailureCode.validation, '汇率源响应体积超出限制');
          }
          chunks.add(chunk);
        }
        completer.complete(
          utf8.decode(chunks.takeBytes(), allowMalformed: true),
        );
      } catch (e, st) {
        completer.completeError(e, st);
      } finally {
        client.close(force: true);
      }
    });
    return completer.future;
  }
}
