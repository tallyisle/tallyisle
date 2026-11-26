import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;

import '../../core/failure.dart';
import '../../domain/ledger/record_extra.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/asset_overview.dart'
    show RateTable, normalizeCurrency;
import '../../domain/rules/auto_map_rules.dart';
import '../../domain/rules/currency_rates.dart' show baseCurrency, billSnapshot;
import '../../domain/rules/ocr_bill_rules.dart';
import '../../domain/rules/smart_bill_nlp_rules.dart';
import '../../platform/auto_bill_bridge.dart';
import '../../platform/files.dart';
import '../db/database.dart';
import '../db/failures.dart';
import '../ledger/ledger_service.dart';
import 'url_scheme_service.dart'
    show matchCategoryByRef, matchFundingAssetByHint;

/// Pluggable OCR provider contract (`F-021`, `ADR-017`).
///
/// Must explicitly surface `'未配置'` when unconfigured and NEVER fake image recognition.
abstract interface class OcrProvider {
  String get id;
  String get label;
  bool get isConfigured;

  /// Returns `'未配置'` when unconfigured or `'已配置'` when ready (`ADR-017`).
  String get statusLabel;
  Capability get capability;

  /// Recognizes plain text lines from [imageBytes], or throws `Failure(unsupportedCapability)`
  /// when unconfigured.
  Future<String> recognizeImage(Uint8List imageBytes, {String? fileName});
}

/// Default honest unconfigured provider (`ADR-017`).
final class UnconfiguredOcrProvider implements OcrProvider {
  const UnconfiguredOcrProvider({this.hint = ocrUnconfiguredStatusLabel});

  /// Human-readable reason shown in [capability] (e.g. desktop hint).
  final String hint;

  @override
  String get id => 'unconfigured';

  @override
  String get label => '自定义 HTTP OCR 接口';

  @override
  bool get isConfigured => false;

  @override
  String get statusLabel => ocrUnconfiguredStatusLabel;

  @override
  Capability get capability => Capability(CapabilityState.unconfigured, hint);

  @override
  Future<String> recognizeImage(Uint8List imageBytes, {String? fileName}) {
    throw const Failure(
      FailureCode.unsupportedCapability,
      'OCR 服务未配置：请先配置 HTTP OCR 接口地址，或直接粘贴账单文本进行解析',
    );
  }
}

/// Built-in on-device OCR (Android ML Kit Chinese / iOS Vision / HarmonyOS
/// CoreVisionKit) via `AutoBillBridge.recognizeImageOffline`. Zero network.
final class NativeOfflineOcrProvider implements OcrProvider {
  const NativeOfflineOcrProvider(this.bridge);

  final AutoBillBridge bridge;

  @override
  String get id => 'native_offline';

  @override
  String get label => '本机离线识图';

  @override
  bool get isConfigured => true;

  @override
  String get statusLabel => ocrNativeOfflineReadyLabel;

  @override
  Capability get capability =>
      const Capability(CapabilityState.available, ocrNativeOfflineReadyLabel);

  @override
  Future<String> recognizeImage(
    Uint8List imageBytes, {
    String? fileName,
  }) async {
    if (imageBytes.isEmpty) {
      throw const Failure(FailureCode.validation, '所选图片内容为空');
    }
    final result = await bridge.recognizeImageOffline(
      imageBytes,
      fileName: fileName,
    );
    if (!result.supported) {
      throw const Failure(
        FailureCode.unsupportedCapability,
        '当前设备不支持本机离线识图，请改用自定义接口或直接粘贴账单文本',
      );
    }
    if (result.text.trim().isEmpty) {
      throw const Failure(FailureCode.validation, '未在图片中识别到文字，请换一张更清晰的截图');
    }
    return result.text;
  }
}

/// Optional OpenAI-compatible AI client (text parsing & image transcription).
abstract interface class AiBillParserClient {
  /// Parses free text into validated bills (`parseAiBillJsonResponse`).
  Future<List<SmartBillParseResult>> parseText(
    String text, {
    required AiBillParserConfig config,
    required int nowMs,
    List<String> categoryNames = const [],
    List<String> assetNames = const [],
  });

  /// Transcribes all visible text lines in an image (multimodal models).
  Future<String> transcribeImage(
    Uint8List imageBytes, {
    required AiBillParserConfig config,
    String? fileName,
  });
}

/// `dart:io` `HttpClient` implementation of an OpenAI-compatible
/// `/chat/completions` client (DeepSeek / 通义千问 / OpenAI …). Zero third-party
/// packages; only used when the user explicitly enables it (`P-03`).
final class OpenAiCompatibleBillParserClient implements AiBillParserClient {
  OpenAiCompatibleBillParserClient({HttpClient Function()? httpClientFactory})
    : _httpClientFactory = httpClientFactory ?? HttpClient.new;

  final HttpClient Function() _httpClientFactory;

  static const int _maxResponseBytes = 4 * 1024 * 1024;

  @override
  Future<List<SmartBillParseResult>> parseText(
    String text, {
    required AiBillParserConfig config,
    required int nowMs,
    List<String> categoryNames = const [],
    List<String> assetNames = const [],
  }) async {
    if (text.trim().isEmpty) {
      throw const Failure(FailureCode.validation, '待识别文本为空');
    }
    final content = await _chat(config, [
      for (final m in buildAiBillParserMessages(
        text,
        nowMs: nowMs,
        categoryNames: categoryNames,
        assetNames: assetNames,
      ))
        m,
    ]);
    return parseAiBillJsonResponse(content, nowMs: nowMs);
  }

  @override
  Future<String> transcribeImage(
    Uint8List imageBytes, {
    required AiBillParserConfig config,
    String? fileName,
  }) async {
    if (imageBytes.isEmpty) {
      throw const Failure(FailureCode.validation, '所选图片内容为空');
    }
    final lower = (fileName ?? '').toLowerCase();
    final mime = lower.endsWith('.jpg') || lower.endsWith('.jpeg')
        ? 'image/jpeg'
        : lower.endsWith('.webp')
        ? 'image/webp'
        : 'image/png';
    final text = await _chat(config, [
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': '请逐行原样输出这张账单图片中的全部文字，不要解释、不要总结。'},
          {
            'type': 'image_url',
            'image_url': {
              'url': 'data:$mime;base64,${base64Encode(imageBytes)}',
            },
          },
        ],
      },
    ]);
    if (text.trim().isEmpty) {
      throw const Failure(FailureCode.validation, 'AI 未识别到图片文字');
    }
    return text.trim();
  }

  Future<String> _chat(
    AiBillParserConfig config,
    List<Map<String, Object>> messages,
  ) async {
    if (!config.isConfigured) {
      throw const Failure(
        FailureCode.unsupportedCapability,
        'AI 识账未配置：请先填写接口地址与模型名称并启用',
      );
    }
    final uri = config.chatCompletionsUri;
    final timeout = Duration(seconds: config.timeoutSeconds.clamp(5, 120));
    final client = _httpClientFactory()..connectionTimeout = timeout;
    try {
      final request = await client.postUrl(uri).timeout(timeout);
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/json; charset=utf-8',
      );
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final token = config.apiKey.trim();
      if (token.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      request.add(
        utf8.encode(
          jsonEncode({
            'model': config.model.trim(),
            'messages': messages,
            'temperature': 0,
            'stream': false,
          }),
        ),
      );
      final response = await request.close().timeout(timeout);
      final chunks = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(timeout)) {
        if (chunks.length + chunk.length > _maxResponseBytes) {
          throw const Failure(FailureCode.validation, 'AI 接口响应体积超出限制');
        }
        chunks.add(chunk);
      }
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw Failure(
          FailureCode.authRequired,
          'AI 接口鉴权未通过（HTTP ${response.statusCode}），请检查 API Key',
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Failure(
          FailureCode.remoteUnavailable,
          'AI 接口请求失败（HTTP ${response.statusCode}）',
        );
      }
      final body = utf8.decode(chunks.takeBytes(), allowMalformed: true);
      final Object? decoded;
      try {
        decoded = jsonDecode(body);
      } on FormatException {
        throw const Failure(FailureCode.validation, 'AI 接口返回的不是有效 JSON');
      }
      if (decoded is Map) {
        final choices = decoded['choices'];
        if (choices is List && choices.isNotEmpty && choices.first is Map) {
          final first = choices.first as Map;
          final message = first['message'];
          if (message is Map && message['content'] is String) {
            return message['content'] as String;
          }
          if (first['text'] is String) return first['text'] as String;
        }
      }
      throw const Failure(
        FailureCode.validation,
        'AI 接口响应缺少 choices[0].message.content',
      );
    } on Failure {
      rethrow;
    } on TimeoutException {
      throw const Failure(
        FailureCode.remoteUnavailable,
        'AI 接口请求超时，请检查网络或服务状态',
      );
    } on SocketException catch (e) {
      throw Failure(FailureCode.remoteUnavailable, '无法连接 AI 接口：${e.message}');
    } on HttpException catch (e) {
      throw Failure(FailureCode.remoteUnavailable, 'AI 接口通信异常：${e.message}');
    } catch (_) {
      throw const Failure(FailureCode.remoteUnavailable, 'AI 识账请求未完成，请检查接口配置');
    } finally {
      client.close(force: true);
    }
  }
}

/// Multimodal AI image transcription provider (`OcrModePreference.aiVision`).
final class AiVisionOcrProvider implements OcrProvider {
  const AiVisionOcrProvider(this.config, this.client);

  final AiBillParserConfig config;
  final AiBillParserClient client;

  @override
  String get id => 'ai_vision';

  @override
  String get label => '自定义 AI 大模型识图';

  @override
  bool get isConfigured => config.isConfigured && config.useForImages;

  @override
  String get statusLabel =>
      isConfigured ? ocrConfiguredStatusLabel : ocrUnconfiguredStatusLabel;

  @override
  Capability get capability => isConfigured
      ? Capability(
          CapabilityState.available,
          '已连接至 ${config.chatCompletionsUri.host}',
        )
      : const Capability(
          CapabilityState.unconfigured,
          ocrUnconfiguredStatusLabel,
        );

  @override
  Future<String> recognizeImage(Uint8List imageBytes, {String? fileName}) {
    if (!isConfigured) {
      throw const Failure(
        FailureCode.unsupportedCapability,
        'AI 识图未配置：请在 AI 识账设置中启用并允许用于图片',
      );
    }
    return client.transcribeImage(
      imageBytes,
      config: config,
      fileName: fileName,
    );
  }
}

/// User-configured HTTP OCR provider backed by `dart:io` `HttpClient` (`ADR-017`, `P-03`).
final class ConfigurableHttpOcrProvider implements OcrProvider {
  ConfigurableHttpOcrProvider(
    this.config, {
    HttpClient Function()? httpClientFactory,
  }) : _httpClientFactory = httpClientFactory ?? HttpClient.new;

  final OcrEndpointConfig config;
  final HttpClient Function() _httpClientFactory;

  static const int _maxResponseBytes = 4 * 1024 * 1024;

  @override
  String get id => 'configurable_http';

  @override
  String get label => '自定义 HTTP OCR 接口';

  @override
  bool get isConfigured => config.isConfigured;

  @override
  String get statusLabel => config.statusLabel;

  @override
  Capability get capability => config.isConfigured
      ? Capability(
          CapabilityState.available,
          '已连接至 ${Uri.parse(config.endpointUrl.trim()).host}',
        )
      : const Capability(
          CapabilityState.unconfigured,
          ocrUnconfiguredStatusLabel,
        );

  @override
  Future<String> recognizeImage(
    Uint8List imageBytes, {
    String? fileName,
  }) async {
    if (!config.isConfigured) {
      throw const Failure(
        FailureCode.unsupportedCapability,
        'OCR 服务未配置：请先配置 HTTP OCR 接口地址，或直接粘贴账单文本进行解析',
      );
    }
    if (imageBytes.isEmpty) {
      throw const Failure(FailureCode.validation, '所选图片内容为空');
    }

    final uri = Uri.parse(config.endpointUrl.trim());
    final timeout = Duration(seconds: config.timeoutSeconds.clamp(5, 120));
    final client = _httpClientFactory()..connectionTimeout = timeout;

    try {
      final request = await client.postUrl(uri).timeout(timeout);
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/json; charset=utf-8',
      );
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final token = config.apiKey.trim();
      if (token.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }

      final requestPayload = jsonEncode({
        'image_base64': base64Encode(imageBytes),
        if (fileName != null && fileName.trim().isNotEmpty)
          'file_name': fileName.trim(),
      });
      request.add(utf8.encode(requestPayload));

      final response = await request.close().timeout(timeout);
      final chunks = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(timeout)) {
        if (chunks.length + chunk.length > _maxResponseBytes) {
          throw const Failure(FailureCode.validation, 'OCR 接口响应体积超出限制');
        }
        chunks.add(chunk);
      }

      if (response.statusCode == 401 || response.statusCode == 403) {
        throw Failure(
          FailureCode.authRequired,
          'OCR 接口鉴权未通过（HTTP ${response.statusCode}），请检查 API Key',
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Failure(
          FailureCode.remoteUnavailable,
          'OCR 接口请求失败（HTTP ${response.statusCode}）',
        );
      }

      final bodyText = utf8.decode(chunks.takeBytes(), allowMalformed: true);
      return extractTextFromOcrJsonResponse(bodyText);
    } on Failure {
      rethrow;
    } on TimeoutException {
      throw const Failure(
        FailureCode.remoteUnavailable,
        'OCR 接口请求超时，请检查网络或服务状态',
      );
    } on SocketException catch (e) {
      throw Failure(FailureCode.remoteUnavailable, '无法连接 OCR 接口：${e.message}');
    } on HttpException catch (e) {
      throw Failure(FailureCode.remoteUnavailable, 'OCR 接口通信异常：${e.message}');
    } catch (_) {
      throw const Failure(FailureCode.remoteUnavailable, 'OCR 识别请求未完成，请检查接口配置');
    } finally {
      client.close(force: true);
    }
  }
}

/// Coordinates `OcrProvider` configuration in `ti_preference`, OCR image/text
/// parsing, rule pre-matching, and atomic batch confirmation into `LedgerService` (`F-021`).
final class OcrService {
  OcrService(
    this.db, {
    LedgerService? ledgerService,
    HttpClient Function()? httpClientFactory,
    AutoBillBridge? bridge,
    AiBillParserClient? aiClient,
    bool? nativeOfflineSupported,
  }) : _ledger = ledgerService ?? LedgerService(db),
       _httpClientFactory = httpClientFactory,
       _bridge = bridge,
       _aiClient = aiClient,
       _nativeOfflineSupported = nativeOfflineSupported;

  final AppDatabase db;
  final LedgerService _ledger;
  final HttpClient Function()? _httpClientFactory;
  final AutoBillBridge? _bridge;
  final AiBillParserClient? _aiClient;
  final bool? _nativeOfflineSupported;

  /// Whether the built-in on-device engine can be used (Android / iOS /
  /// HarmonyOS with a bridge). Desktop & tests without a bridge: `false`.
  bool get nativeOfflineAvailable {
    if (_bridge == null) return false;
    final override = _nativeOfflineSupported;
    if (override != null) return override;
    if (kIsWeb) return false;
    final p = defaultTargetPlatform;
    return p == TargetPlatform.android ||
        p == TargetPlatform.iOS ||
        p.name == 'ohos';
  }

  /// Watches `OcrEndpointConfig` stored in `ti_preference` (`ocr_provider_config`).
  Stream<OcrEndpointConfig> watchConfig() =>
      (db.select(db.preferences)
            ..where((t) => t.key.equals(ocrProviderPreferenceKey)))
          .watchSingleOrNull()
          .map((row) => OcrEndpointConfig.parse(row?.value));

  /// Reads current `OcrEndpointConfig` once.
  Future<OcrEndpointConfig> getConfig() => guardDatabase(() async {
    final row = await (db.select(
      db.preferences,
    )..where((t) => t.key.equals(ocrProviderPreferenceKey))).getSingleOrNull();
    return OcrEndpointConfig.parse(row?.value);
  });

  /// Watches the active [OcrProvider] (reacts to OCR and AI config rows).
  Stream<OcrProvider> watchProvider() =>
      (db.select(db.preferences)..where(
            (t) => t.key.isIn(const [
              ocrProviderPreferenceKey,
              aiBillParserConfigPreferenceKey,
            ]),
          ))
          .watch()
          .map(_providerForRows);

  /// Builds the active [OcrProvider] once.
  Future<OcrProvider> getProvider() => guardDatabase(() async {
    final rows =
        await (db.select(db.preferences)..where(
              (t) => t.key.isIn(const [
                ocrProviderPreferenceKey,
                aiBillParserConfigPreferenceKey,
              ]),
            ))
            .get();
    return _providerForRows(rows);
  });

  OcrProvider _providerForRows(List<Preference> rows) {
    String? valueOf(String key) =>
        rows.where((r) => r.key == key).firstOrNull?.value;
    return _providerForConfig(
      OcrEndpointConfig.parse(valueOf(ocrProviderPreferenceKey)),
      AiBillParserConfig.parse(valueOf(aiBillParserConfigPreferenceKey)),
    );
  }

  /// Provider resolution:
  /// - `customHttp` (or `nativeOffline` with a configured endpoint override)
  ///   → [ConfigurableHttpOcrProvider];
  /// - `aiVision` with an enabled AI config allowing images → [AiVisionOcrProvider];
  /// - `nativeOffline` on Android / iOS / HarmonyOS → [NativeOfflineOcrProvider];
  /// - otherwise an honest [UnconfiguredOcrProvider] (`'未配置'`).
  OcrProvider _providerForConfig(
    OcrEndpointConfig config, [
    AiBillParserConfig ai = const AiBillParserConfig(),
  ]) {
    switch (config.effectiveMode) {
      case OcrModePreference.customHttp:
        if (!config.isConfigured) return const UnconfiguredOcrProvider();
        return ConfigurableHttpOcrProvider(
          config,
          httpClientFactory: _httpClientFactory,
        );
      case OcrModePreference.aiVision:
        final client = _aiClient;
        if (client != null && ai.isConfigured && ai.useForImages) {
          return AiVisionOcrProvider(ai, client);
        }
        return const UnconfiguredOcrProvider(hint: 'AI 识图未配置：请启用 AI 识账并允许用于图片');
      case OcrModePreference.nativeOffline:
        final bridge = _bridge;
        if (bridge != null && nativeOfflineAvailable) {
          return NativeOfflineOcrProvider(bridge);
        }
        return const UnconfiguredOcrProvider(hint: ocrDesktopUnconfiguredHint);
    }
  }

  Future<T> _command<T>(
    String commandId,
    List<Object?> payload,
    Future<String> Function() body,
    T Function(String resultId) decodeResult,
  ) async {
    if (commandId.isEmpty || commandId.length > 128) {
      throw const Failure(FailureCode.validation, '提交标识无效');
    }
    final hash = sha256.convert(utf8.encode(jsonEncode(payload))).toString();
    return guardDatabase(
      () => db.transaction(() async {
        final prev = await (db.select(
          db.writeCommands,
        )..where((t) => t.commandId.equals(commandId))).getSingleOrNull();
        if (prev != null) {
          if (prev.payloadHash != hash) {
            throw const Failure(FailureCode.conflict, '同一提交标识的内容发生变化');
          }
          return decodeResult(prev.resultId);
        }
        final resultId = await body();
        await db
            .into(db.writeCommands)
            .insert(
              WriteCommandsCompanion.insert(
                commandId: commandId,
                payloadHash: hash,
                resultId: resultId,
                committedAt: db.nowMs(),
              ),
            );
        return decodeResult(resultId);
      }),
    );
  }

  /// Validates and persists `OcrEndpointConfig` in `ti_preference` (`ADR-017`).
  Future<OcrEndpointConfig> saveConfig({
    required String commandId,
    required OcrEndpointConfig config,
  }) => _command(commandId, ['ocr-save-config-v1', config.encode()], () async {
    final validated = config.validated();
    if (validated.isDefault) {
      await (db.delete(
        db.preferences,
      )..where((t) => t.key.equals(ocrProviderPreferenceKey))).go();
    } else {
      await db
          .into(db.preferences)
          .insertOnConflictUpdate(
            PreferencesCompanion.insert(
              key: ocrProviderPreferenceKey,
              value: validated.encode(),
            ),
          );
    }
    return validated.encode();
  }, OcrEndpointConfig.parse);

  /// Resets `OcrProvider` back to `'未配置'`.
  Future<void> clearConfig({required String commandId}) =>
      _command(commandId, const ['ocr-clear-config-v1'], () async {
        await (db.delete(
          db.preferences,
        )..where((t) => t.key.equals(ocrProviderPreferenceKey))).go();
        return 'cleared';
      }, (_) {});

  /// Calls the active [OcrProvider] to recognize [imageBytes] and parses candidates.
  /// Throws `Failure(FailureCode.unsupportedCapability)` when unconfigured (`ADR-017`).
  Future<(String, List<OcrBillCandidate>)> recognizeImageToCandidates(
    Uint8List imageBytes, {
    String? fileName,
    int? bookId,
    DateTime? now,
  }) async {
    final provider = await getProvider();
    final recognizedText = await provider.recognizeImage(
      imageBytes,
      fileName: fileName,
    );
    final candidates = await parseTextToCandidates(
      recognizedText,
      bookId: bookId,
      now: now,
    );
    return (recognizedText, candidates);
  }

  /// Parses pasted or OCR-recognized ledger/receipt text and enriches each candidate
  /// with `auto_map` rule matches and book category/account pre-selections.
  Future<List<OcrBillCandidate>> parseTextToCandidates(
    String rawText, {
    int? bookId,
    DateTime? now,
  }) => guardDatabase(() async {
    final moment = (now ?? DateTime.fromMillisecondsSinceEpoch(db.nowMs()))
        .toLocal();
    final rawCandidates = parseOcrBillCandidates(
      rawText,
      defaultYear: moment.year,
      fallbackTimeMs: moment.millisecondsSinceEpoch,
    );
    if (rawCandidates.isEmpty) return const [];

    final book = await _resolveBook(bookId);
    final autoRows = await db.select(db.autoMaps).get();
    final rules = [
      for (final row in autoRows)
        if (isAutoMapRuleKey(row.key))
          AutoMapRule(
            id: row.id,
            key: row.key,
            info: AutoMapInfo.parse(row.mapInfo),
          ),
    ];
    final categories =
        await (db.select(db.recordCategories)
              ..where((t) => t.accountBookId.equals(book.id))
              ..orderBy([
                (t) => OrderingTerm.asc(t.sort),
                (t) => OrderingTerm.asc(t.id),
              ]))
            .get();
    final assets =
        await (db.select(db.assets)..orderBy([
              (t) => OrderingTerm.asc(t.sort),
              (t) => OrderingTerm.asc(t.id),
            ]))
            .get();
    final links = await db.select(db.assetBooks).get();

    final enriched = <OcrBillCandidate>[];
    for (final item in rawCandidates) {
      final matched = matchAutoMapRules(rules, [
        item.merchant,
        item.remark,
        ?item.categoryHint,
        ?item.accountHint,
      ]);
      final effectiveType =
          (matched.recordType == RecordType.income ||
              matched.recordType == RecordType.expense)
          ? matched.recordType!
          : item.type;
      final wantCatType = effectiveType == RecordType.income
          ? RecordType.income
          : RecordType.expense;
      final dirCategories = categories
          .where((c) => c.type == wantCatType)
          .toList(growable: false);

      int? catId;
      if (matched.categoryId != null) {
        catId = dirCategories
            .where((c) => c.id == matched.categoryId)
            .firstOrNull
            ?.id;
      }
      if (catId == null && item.categoryHint != null) {
        catId = matchCategoryByRef(dirCategories, item.categoryHint!)?.id;
      }
      catId ??=
          (dirCategories.where((c) => !c.isHide).firstOrNull ??
                  dirCategories.firstOrNull)
              ?.id;

      int? resolvedAssetId;
      if (matched.assetId != null) {
        resolvedAssetId = assets
            .where(
              (a) =>
                  a.id == matched.assetId &&
                  a.type != AssetType.debt &&
                  a.status != AssetStatus.settled,
            )
            .firstOrNull
            ?.id;
      }
      resolvedAssetId ??= matchFundingAssetByHint(
        assets: assets,
        links: links,
        bookId: book.id,
        rawHint: item.accountHint,
      )?.id;

      enriched.add(
        item.copyWith(
          type: effectiveType,
          remark: matched.remark ?? item.remark,
          categoryId: catId,
          assetId: resolvedAssetId,
        ),
      );
    }
    return enriched;
  });

  /// Atomically confirms all `selected` [OcrBillCandidate]s into `LedgerService` (`ADR-009`).
  Future<List<String>> confirmCandidates({
    required String commandId,
    int? bookId,
    required List<OcrBillCandidate> candidates,
    int? defaultAssetId,
  }) async {
    final selected = candidates
        .where((c) => c.selected)
        .toList(growable: false);
    if (selected.isEmpty) {
      throw const Failure(FailureCode.validation, '请至少勾选一条需要入账的识别记录');
    }

    final payloadItems = [
      for (final c in selected)
        [
          c.index,
          c.type,
          c.money.toJson(),
          c.discount?.toJson(),
          c.recordTimeMs,
          c.remark,
          c.categoryId,
          c.assetId,
        ],
    ];

    return _command<List<String>>(
      commandId,
      ['ocr-confirm-batch-v1', bookId, defaultAssetId, payloadItems],
      () async {
        final book = await _resolveBook(bookId);
        final categories =
            await (db.select(db.recordCategories)
                  ..where((t) => t.accountBookId.equals(book.id))
                  ..orderBy([
                    (t) => OrderingTerm.asc(t.sort),
                    (t) => OrderingTerm.asc(t.id),
                  ]))
                .get();
        final assets = await db.select(db.assets).get();
        final currencyRows = await db.select(db.currencies).get();
        final rates = RateTable({
          for (final r in currencyRows) r.code: r.rateToAnchor,
        });

        final createdIds = <String>[];
        for (var i = 0; i < selected.length; i++) {
          final item = selected[i];
          if (item.money.units <= BigInt.zero) {
            throw Failure(FailureCode.validation, '第 ${i + 1} 条记录金额须大于 0');
          }
          final type = item.type == RecordType.income
              ? RecordType.income
              : RecordType.expense;
          final dirCats = categories
              .where((c) => c.type == type)
              .toList(growable: false);

          final cat = item.categoryId != null
              ? dirCats.where((c) => c.id == item.categoryId).firstOrNull
              : (dirCats.where((c) => !c.isHide).firstOrNull ??
                    dirCats.firstOrNull);
          if (cat == null) {
            throw Failure(
              FailureCode.validation,
              '第 ${i + 1} 条记录缺少有效${type == RecordType.income ? '收入' : '支出'}分类',
            );
          }

          final effectiveAssetId = item.assetId ?? defaultAssetId ?? noRef;
          Asset? asset;
          if (effectiveAssetId != noRef) {
            asset = assets
                .where(
                  (a) => a.id == effectiveAssetId && a.type != AssetType.debt,
                )
                .firstOrNull;
            if (asset == null) {
              throw Failure(FailureCode.validation, '第 ${i + 1} 条记录所选账户无效');
            }
          }

          final discount = item.discount;
          if (discount != null && discount.units > item.money.units) {
            throw Failure(FailureCode.validation, '第 ${i + 1} 条记录优惠金额不能大于账单金额');
          }
          final netMoney = discount != null && !discount.isZero
              ? item.money - discount
              : item.money;

          final extra = RecordExtra();
          final ac = normalizeCurrency(asset?.currency) ?? baseCurrency;
          if (ac != baseCurrency) {
            extra.currency = billSnapshot(
              source: ac,
              sourceMinor: item.money.storageMinor,
              account: ac,
              assetMinor: netMoney.storageMinor,
              rates: rates,
            );
          }

          final draft = RecordDraft(
            type: type,
            money: netMoney,
            bookId: book.id,
            recordTime: item.recordTimeMs,
            categoryId: cat.id,
            assetId: effectiveAssetId,
            remark: item.remark.trim(),
            discount: discount != null && !discount.isZero ? discount : null,
            extra: extra,
          );

          final innerCmdId =
              'ocr-rec:${sha256.convert(utf8.encode('$commandId:$i')).toString()}';
          final recId = await _ledger.saveRecord(
            commandId: innerCmdId,
            draft: draft,
          );
          createdIds.add(recId);
        }

        return jsonEncode(createdIds);
      },
      (jsonList) => [for (final id in jsonDecode(jsonList) as List) '$id'],
    );
  }

  Future<AccountBook> _resolveBook(int? preferredBookId) async {
    if (preferredBookId != null) {
      final found = await (db.select(
        db.accountBooks,
      )..where((t) => t.id.equals(preferredBookId))).getSingleOrNull();
      if (found != null) return found;
    }
    final pref = await (db.select(
      db.preferences,
    )..where((t) => t.key.equals(prefKeyCurrentBookId))).getSingleOrNull();
    final currentId = int.tryParse(pref?.value ?? '') ?? 1;
    final current = await (db.select(
      db.accountBooks,
    )..where((t) => t.id.equals(currentId))).getSingleOrNull();
    if (current != null) return current;

    final first =
        await (db.select(db.accountBooks)
              ..orderBy([(t) => OrderingTerm.asc(t.id)])
              ..limit(1))
            .getSingleOrNull();
    if (first == null) {
      throw const Failure(FailureCode.validation, '当前尚无可用账本');
    }
    return first;
  }
}
