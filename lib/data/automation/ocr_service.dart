import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../../core/failure.dart';
import '../../domain/ledger/record_extra.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/asset_overview.dart'
    show RateTable, normalizeCurrency;
import '../../domain/rules/auto_map_rules.dart';
import '../../domain/rules/currency_rates.dart' show baseCurrency, billSnapshot;
import '../../domain/rules/ocr_bill_rules.dart';
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
  const UnconfiguredOcrProvider();

  @override
  String get id => 'unconfigured';

  @override
  String get label => '自定义 HTTP OCR 接口';

  @override
  bool get isConfigured => false;

  @override
  String get statusLabel => ocrUnconfiguredStatusLabel;

  @override
  Capability get capability => const Capability(
    CapabilityState.unconfigured,
    ocrUnconfiguredStatusLabel,
  );

  @override
  Future<String> recognizeImage(Uint8List imageBytes, {String? fileName}) {
    throw const Failure(
      FailureCode.unsupportedCapability,
      'OCR 服务未配置：请先配置 HTTP OCR 接口地址，或直接粘贴账单文本进行解析',
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
  }) : _ledger = ledgerService ?? LedgerService(db),
       _httpClientFactory = httpClientFactory;

  final AppDatabase db;
  final LedgerService _ledger;
  final HttpClient Function()? _httpClientFactory;

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

  /// Watches the active [OcrProvider] (`UnconfiguredOcrProvider` when unconfigured).
  Stream<OcrProvider> watchProvider() => watchConfig().map(_providerForConfig);

  /// Builds the active [OcrProvider] once.
  Future<OcrProvider> getProvider() async =>
      _providerForConfig(await getConfig());

  OcrProvider _providerForConfig(OcrEndpointConfig config) {
    if (!config.isConfigured) {
      return const UnconfiguredOcrProvider();
    }
    return ConfigurableHttpOcrProvider(
      config,
      httpClientFactory: _httpClientFactory,
    );
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
    if (!validated.isConfigured) {
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
    )..where((t) => t.key.equals('current_book_id'))).getSingleOrNull();
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
