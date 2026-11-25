import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../../core/failure.dart';
import '../../core/money.dart';
import '../../domain/ledger/record_extra.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/asset_overview.dart'
    show RateTable, normalizeCurrency;
import '../../domain/rules/auto_map_rules.dart';
import '../../domain/rules/currency_rates.dart' show baseCurrency, billSnapshot;
import '../../domain/rules/smart_bill_nlp_rules.dart';
import '../../domain/rules/url_scheme_rules.dart' show autoBillDraftsRoute;
import '../../platform/auto_bill_bridge.dart';
import '../db/database.dart';
import '../db/failures.dart';
import '../ledger/ledger_service.dart';
import 'ocr_service.dart' show AiBillParserClient;
import 'url_scheme_service.dart'
    show matchCategoryByRef, matchFundingAssetByHint;

/// `ti_preference` key holding the recent capture log used for cross-channel
/// 15 s dedup and auto-confirm undo bookkeeping (zero DDL).
const String _recentCapturesPreferenceKey = 'auto_bill_recent_captures';

/// Data & application service for `F-020` auto-bookkeeping keyword rules,
/// payment notification text ingestion, tiered auto-confirmation, draft inbox,
/// prompt actions and native capture bridges.
final class AutoBillService {
  AutoBillService(
    this.db, {
    LedgerService? ledgerService,
    AutoBillBridge? bridge,
    AiBillParserClient? aiClient,
    Future<void> Function()? afterChange,
  }) : _ledger = ledgerService ?? LedgerService(db),
       _bridge = bridge ?? createAutoBillBridge(),
       _aiClient = aiClient,
       _afterChange = afterChange;

  final AppDatabase db;
  final LedgerService _ledger;
  final AutoBillBridge _bridge;
  final AiBillParserClient? _aiClient;
  final Future<void> Function()? _afterChange;

  AutoBillBridge get bridge => _bridge;

  /// Queries honest Android `AccessibilityService` status (`已开启` / `未开启` / `当前平台不支持`).
  Future<AccessibilityBridgeStatus> getAccessibilityStatus() =>
      _bridge.getAccessibilityStatus();

  /// Opens Android system accessibility settings when supported.
  Future<bool> openAccessibilitySettings() =>
      _bridge.openAccessibilitySettings();

  /// Android notification-listener status (`已开启` / `未开启` / `当前平台不支持`).
  Future<AutoBillPermissionStatus> getNotificationListenerStatus() =>
      _bridge.getNotificationListenerStatus();

  Future<bool> openNotificationListenerSettings() =>
      _bridge.openNotificationListenerSettings();

  /// Android overlay permission (`已授权` / `未授权` / `当前平台不支持`).
  Future<AutoBillPermissionStatus> getOverlayPermissionStatus() =>
      _bridge.getOverlayPermissionStatus();

  Future<bool> openOverlaySettings() => _bridge.openOverlaySettings();

  /// Watches all user-defined `auto_map` keyword rules (`key != KEY_DRAFT && key != KEY_CONFIG`).
  Stream<List<AutoMapRule>> watchRules() =>
      (db.select(
        db.autoMaps,
      )..orderBy([(t) => OrderingTerm.desc(t.id)])).watch().map(
        (rows) => [
          for (final row in rows)
            if (isAutoMapRuleKey(row.key))
              AutoMapRule(
                id: row.id,
                key: row.key,
                info: AutoMapInfo.parse(row.mapInfo),
              ),
        ],
      );

  /// Loads all user-defined `auto_map` keyword rules once.
  Future<List<AutoMapRule>> listRules() => guardDatabase(() async {
    final rows = await (db.select(
      db.autoMaps,
    )..orderBy([(t) => OrderingTerm.desc(t.id)])).get();
    return [
      for (final row in rows)
        if (isAutoMapRuleKey(row.key))
          AutoMapRule(
            id: row.id,
            key: row.key,
            info: AutoMapInfo.parse(row.mapInfo),
          ),
    ];
  });

  /// Watches all pending drafts (`auto_map.key == 'KEY_DRAFT'`), including `.penny` imported drafts.
  Stream<List<AutoBillDraft>> watchDrafts() =>
      (db.select(db.autoMaps)
            ..where((t) => t.key.equals(autoMapDraftKey))
            ..orderBy([(t) => OrderingTerm.desc(t.id)]))
          .watch()
          .map((rows) {
            final now = db.nowMs();
            final out = <AutoBillDraft>[];
            for (final row in rows) {
              try {
                out.add(
                  AutoBillDraft.parse(
                    row.draft,
                    id: row.id,
                    fallbackNowMs: now,
                  ),
                );
              } on Failure {
                // Skip structurally corrupt draft JSON without crashing the inbox stream.
              }
            }
            return out;
          });

  /// Loads all pending drafts once.
  Future<List<AutoBillDraft>> listDrafts() => guardDatabase(() async {
    final rows =
        await (db.select(db.autoMaps)
              ..where((t) => t.key.equals(autoMapDraftKey))
              ..orderBy([(t) => OrderingTerm.desc(t.id)]))
            .get();
    final now = db.nowMs();
    final out = <AutoBillDraft>[];
    for (final row in rows) {
      try {
        out.add(AutoBillDraft.parse(row.draft, id: row.id, fallbackNowMs: now));
      } on Failure {
        // Skip corrupt rows.
      }
    }
    return out;
  });

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

  /// Creates or updates a keyword mapping rule in `auto_map` (`F-020` R2).
  Future<int> saveRule({
    required String commandId,
    int? id,
    required String key,
    required AutoMapInfo info,
  }) => _command(
    commandId,
    ['auto-map-save-rule-v1', id, key, info.encode()],
    () async {
      final cleanKey = validateAutoMapRuleKey(key);
      if (!info.hasAnyMapping) {
        throw const Failure(FailureCode.validation, '请至少配置一项映射目标（账户或分类）');
      }
      await _validateRuleTargets(info);

      final existingRows = await db.select(db.autoMaps).get();
      final duplicate = existingRows
          .where(
            (r) =>
                isAutoMapRuleKey(r.key) &&
                r.id != id &&
                r.key.trim().toLowerCase() == cleanKey.toLowerCase(),
          )
          .firstOrNull;
      if (duplicate != null) {
        throw Failure(FailureCode.conflict, '关键词“$cleanKey”已存在映射规则，请直接编辑原有规则');
      }

      if (id != null) {
        final target = existingRows
            .where((r) => r.id == id && isAutoMapRuleKey(r.key))
            .firstOrNull;
        if (target == null) {
          throw const Failure(FailureCode.conflict, '该映射规则不存在或已删除');
        }
        await (db.update(db.autoMaps)..where((t) => t.id.equals(id))).write(
          AutoMapsCompanion(
            key: Value(cleanKey),
            mapInfo: Value(info.encode()),
          ),
        );
        return '$id';
      }

      final insertedId = await db
          .into(db.autoMaps)
          .insert(
            AutoMapsCompanion.insert(
              key: cleanKey,
              mapInfo: Value(info.encode()),
            ),
          );
      return '$insertedId';
    },
    int.parse,
  );

  /// Deletes a user mapping rule from `auto_map`.
  Future<void> deleteRule({required String commandId, required int id}) =>
      _command(commandId, ['auto-map-delete-rule-v1', id], () async {
        await (db.delete(db.autoMaps)..where(
              (t) =>
                  t.id.equals(id) &
                  t.key.isNotIn(const [autoMapDraftKey, autoMapConfigKey]),
            ))
            .go();
        return '$id';
      }, (_) {});

  /// Watches [AutoBillSettings] (`ti_preference['auto_bill_settings']`).
  Stream<AutoBillSettings> watchSettings() =>
      (db.select(db.preferences)
            ..where((t) => t.key.equals(autoBillSettingsPreferenceKey)))
          .watchSingleOrNull()
          .map((row) => AutoBillSettings.parse(row?.value));

  /// Reads [AutoBillSettings] once.
  Future<AutoBillSettings> getSettings() => guardDatabase(
    () => _readPreference(autoBillSettingsPreferenceKey),
  ).then(AutoBillSettings.parse);

  /// Persists [settings] and pushes capture switches / prompt mode / pick
  /// lists to native (`syncAndroidAutoBillConfig`, best-effort).
  Future<AutoBillSettings> saveSettings({
    required String commandId,
    required AutoBillSettings settings,
  }) async {
    final saved = await _command(
      commandId,
      ['auto-bill-save-settings-v1', settings.encode()],
      () async {
        await _writePreference(
          autoBillSettingsPreferenceKey,
          settings.encode(),
        );
        return settings.encode();
      },
      AutoBillSettings.parse,
    );
    await syncNativeConfig(settings: saved);
    return saved;
  }

  /// Pushes current settings + category/asset pick lists to native.
  Future<bool> syncNativeConfig({AutoBillSettings? settings}) async {
    try {
      final effective = settings ?? await getSettings();
      final config = await guardDatabase(() async {
        final book = await _resolveBook(null);
        final cats =
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
        return AutoBillNativeConfig(
          enableNotificationCapture: effective.enableNotificationCapture,
          enableAccessibilityCapture: effective.enableAccessibilityCapture,
          promptMode: effective.promptMode.wireKey,
          categories: [
            for (final c in cats)
              if (!c.isHide &&
                  (c.type == RecordType.expense || c.type == RecordType.income))
                {
                  'id': c.id,
                  'name': c.name,
                  'type': c.type,
                  'parentId': c.parentCatId,
                },
          ],
          assets: [
            for (final a in assets)
              if (a.type != AssetType.debt && a.status == AssetStatus.active)
                {'id': a.id, 'name': a.name},
          ],
        );
      });
      return await _bridge.syncAndroidAutoBillConfig(config);
    } on Failure {
      return false;
    }
  }

  /// Watches the optional user AI parser config (`ai_bill_parser_config`).
  Stream<AiBillParserConfig> watchAiParserConfig() =>
      (db.select(db.preferences)
            ..where((t) => t.key.equals(aiBillParserConfigPreferenceKey)))
          .watchSingleOrNull()
          .map((row) => AiBillParserConfig.parse(row?.value));

  Future<AiBillParserConfig> getAiParserConfig() => guardDatabase(
    () => _readPreference(aiBillParserConfigPreferenceKey),
  ).then(AiBillParserConfig.parse);

  /// Validates and persists [config] (`ti_preference`, zero DDL).
  Future<AiBillParserConfig> saveAiParserConfig({
    required String commandId,
    required AiBillParserConfig config,
  }) => _command(
    commandId,
    ['ai-parser-save-config-v1', config.encode()],
    () async {
      final validated = config.validated();
      if (validated == const AiBillParserConfig()) {
        await (db.delete(
          db.preferences,
        )..where((t) => t.key.equals(aiBillParserConfigPreferenceKey))).go();
      } else {
        await _writePreference(
          aiBillParserConfigPreferenceKey,
          validated.encode(),
        );
      }
      return validated.encode();
    },
    AiBillParserConfig.parse,
  );

  Future<String?> _readPreference(String key) async {
    final row = await (db.select(
      db.preferences,
    )..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> _writePreference(String key, String value) => db
      .into(db.preferences)
      .insertOnConflictUpdate(
        PreferencesCompanion.insert(key: key, value: value),
      );

  /// Parses payment text (WeChat/Alipay/UnionPay/SMS), applies `auto_map` rules,
  /// and inserts a pending draft into `auto_map` (`key = 'KEY_DRAFT'`).
  ///
  /// Backward-compatible wrapper: never auto-confirms and returns the draft id
  /// (existing or new), or `null` when [allowNonPaymentSkip] skipped non-payment
  /// text. Use [ingestPaymentTextWithOutcome] for tiered auto-confirmation.
  Future<int?> ingestPaymentText({
    required String commandId,
    required String rawText,
    String? packageName,
    int? capturedAtMs,
    bool allowNonPaymentSkip = false,
  }) async {
    final outcome = await ingestPaymentTextWithOutcome(
      commandId: commandId,
      rawText: rawText,
      packageName: packageName,
      capturedAtMs: capturedAtMs,
      allowNonPaymentSkip: allowNonPaymentSkip,
      allowAutoConfirm: false,
      dispatchPrompt: false,
    );
    return outcome.draftId;
  }

  /// Tiered ingestion (decisions 1 / 2 / 7 / 9):
  /// 1. Parse with `parsePaymentText`; when that fails on user-supplied text
  ///    (not background captures) fall back to `parseNaturalLanguageBill`,
  ///    then the optional user AI endpoint.
  /// 2. Apply `auto_map` rules; dedupe against pending drafts and recent
  ///    captures (same fingerprint, or cross-channel within 15 s).
  /// 3. When [allowAutoConfirm], `AutoBillSettings.autoConfirmMatchedRules` and
  ///    `AutoMapMatchResult.canAutoConfirm` all pass, book directly via
  ///    `LedgerService.saveRecord` in the same transaction; otherwise queue a
  ///    `KEY_DRAFT`.
  /// 4. When [dispatchPrompt], ask native to show the configured prompt.
  Future<AutoBillIngestOutcome> ingestPaymentTextWithOutcome({
    required String commandId,
    required String rawText,
    String? packageName,
    int? capturedAtMs,
    bool allowNonPaymentSkip = false,
    String? channel,
    bool allowAutoConfirm = true,
    bool dispatchPrompt = true,
  }) async {
    final normalizedChannel = channel?.trim().isEmpty ?? true
        ? null
        : channel!.trim();
    final payload = <Object?>[
      'auto-bill-ingest-v2',
      rawText,
      packageName,
      capturedAtMs,
      allowNonPaymentSkip,
      normalizedChannel,
      allowAutoConfirm,
    ];
    final replay = await _replayIfCommitted(commandId, payload);
    if (replay != null) return AutoBillIngestOutcome.decode(replay);

    final fallbackMs = capturedAtMs ?? db.nowMs();
    final candidate = await _preParse(
      rawText,
      packageName: packageName,
      fallbackMs: fallbackMs,
      allowFallbacks: !allowNonPaymentSkip,
    );

    var executed = false;
    AutoBillPromptRequest? prompt;
    final outcome = await _command<AutoBillIngestOutcome>(
      commandId,
      payload,
      () async {
        executed = true;
        if (candidate == null) {
          if (allowNonPaymentSkip) return '';
          throw const Failure(FailureCode.validation, '未从文本中识别出有效收支金额，请检查粘贴内容');
        }
        final (result, request) = await _ingestCandidate(
          candidate,
          innerCommandSeed: commandId,
          channel: normalizedChannel,
          captureMs: capturedAtMs ?? candidate.recordTimeMs,
          allowAutoConfirm: allowAutoConfirm,
        );
        prompt = request;
        return result.encode();
      },
      AutoBillIngestOutcome.decode,
    );

    if (executed && outcome.created) {
      final request = prompt;
      if (dispatchPrompt && request != null) {
        try {
          await _bridge.showAutoBillPrompt(request);
        } on Object {
          // Prompts are best-effort; the draft / record is already committed.
        }
      }
      await _notifyChanged();
    }
    return outcome;
  }

  /// Ingests text from `tallyisle://smartbill`, the smart quick sheet, a
  /// share, or an iOS shortcut. [autoConfirm] `false` always queues a draft.
  Future<AutoBillIngestOutcome> ingestSmartText({
    required String commandId,
    required String text,
    String? sourceApp,
    bool autoConfirm = true,
    bool dispatchPrompt = true,
  }) => ingestPaymentTextWithOutcome(
    commandId: commandId,
    rawText: text,
    packageName: sourceApp,
    allowAutoConfirm: autoConfirm,
    dispatchPrompt: dispatchPrompt,
  );

  Future<void> _notifyChanged() async {
    final hook = _afterChange;
    if (hook == null) return;
    try {
      await hook();
    } on Object {
      // Widget refresh is best-effort.
    }
  }

  Future<String?> _replayIfCommitted(
    String commandId,
    List<Object?> payload,
  ) async {
    if (commandId.isEmpty || commandId.length > 128) return null;
    final prev = await guardDatabase(
      () => (db.select(
        db.writeCommands,
      )..where((t) => t.commandId.equals(commandId))).getSingleOrNull(),
    );
    if (prev == null) return null;
    final hash = sha256.convert(utf8.encode(jsonEncode(payload))).toString();
    if (prev.payloadHash != hash) {
      throw const Failure(FailureCode.conflict, '同一提交标识的内容发生变化');
    }
    return prev.resultId;
  }

  Future<_IngestCandidate?> _preParse(
    String rawText, {
    required String? packageName,
    required int fallbackMs,
    required bool allowFallbacks,
  }) async {
    final parsed = parsePaymentText(
      rawText,
      packageOrApp: packageName,
      fallbackNowMs: fallbackMs,
    );
    if (parsed != null) return _IngestCandidate.fromPayment(parsed);
    if (!allowFallbacks) return null;

    final (categoryNames, assetNames) = await guardDatabase(_pickListNames);
    final nlp = parseNaturalLanguageBill(
      rawText,
      nowMs: fallbackMs,
      categoryNames: categoryNames,
      assetNames: assetNames,
    );

    final client = _aiClient;
    if (client != null &&
        (nlp == null || nlp.confidence == SmartBillConfidence.low)) {
      final aiConfig = await getAiParserConfig();
      if (aiConfig.isConfigured) {
        try {
          final bills = await client.parseText(
            rawText,
            config: aiConfig,
            nowMs: fallbackMs,
            categoryNames: categoryNames,
            assetNames: assetNames,
          );
          if (bills.isNotEmpty) {
            return _IngestCandidate.fromSmart(
              bills.first,
              sourceApp: friendlyAutoBillAppName(packageName),
            );
          }
        } on Failure {
          // Fall through to the offline result.
        }
      }
    }
    if (nlp == null) return null;
    return _IngestCandidate.fromSmart(
      nlp,
      sourceApp: packageName == null || packageName.trim().isEmpty
          ? '口语识账'
          : friendlyAutoBillAppName(packageName),
    );
  }

  Future<(List<String>, List<String>)> _pickListNames() async {
    final book = await _resolveBook(null);
    final cats = await (db.select(
      db.recordCategories,
    )..where((t) => t.accountBookId.equals(book.id))).get();
    final assets = await db.select(db.assets).get();
    return (
      [
        for (final c in cats)
          if (!c.isHide) c.name,
      ],
      [
        for (final a in assets)
          if (a.type != AssetType.debt && a.status != AssetStatus.settled)
            a.name,
      ],
    );
  }

  /// Core decision inside the caller's transaction.
  Future<(AutoBillIngestOutcome, AutoBillPromptRequest?)> _ingestCandidate(
    _IngestCandidate parsed, {
    required String innerCommandSeed,
    required String? channel,
    required int captureMs,
    required bool allowAutoConfirm,
  }) async {
    final settings = AutoBillSettings.parse(
      await _readPreference(autoBillSettingsPreferenceKey),
    );
    final rules = await _loadRulesInternal();
    final matched = matchAutoMapRules(rules, [
      parsed.merchant,
      ?parsed.accountHint1,
      ?parsed.accountHint2,
      ?parsed.categoryHint,
      parsed.sourceApp,
      parsed.rawText,
    ]);

    final book = await _resolveBook(matched.bookId);
    final recordType = matched.recordType ?? parsed.recordType;

    final ruleCategoryId = await _tryPreMatchCategory(
      bookId: book.id,
      recordType: recordType,
      explicitId: matched.categoryId,
      hint: null,
    );
    final resolvedCatId =
        ruleCategoryId ??
        await _tryPreMatchCategory(
          bookId: book.id,
          recordType: recordType,
          explicitId: null,
          hint: parsed.categoryHint,
        );
    final assets =
        await (db.select(db.assets)..orderBy([
              (t) => OrderingTerm.asc(t.sort),
              (t) => OrderingTerm.asc(t.id),
            ]))
            .get();
    final links = await db.select(db.assetBooks).get();

    final resolvedAssetId =
        await _verifyFundingAssetId(assets, matched.assetId) ??
        matchFundingAssetByHint(
          assets: assets,
          links: links,
          bookId: book.id,
          rawHint: parsed.accountHint1 ?? parsed.sourceApp,
        )?.id;
    final resolvedToAssetId =
        await _verifyFundingAssetId(assets, matched.toAssetId) ??
        matchFundingAssetByHint(
          assets: assets,
          links: links,
          bookId: book.id,
          rawHint: parsed.accountHint2,
        )?.id;

    final timeBucket = parsed.recordTimeMs ~/ 15000;
    final fingerprint = sha256
        .convert(
          utf8.encode(
            '${parsed.sourceApp}|$recordType|${parsed.money.storageMinor}|${parsed.merchant}|$timeBucket',
          ),
        )
        .toString()
        .substring(0, 32);
    final crossFingerprint = computeCrossChannelPaymentFingerprint(
      sourceAppOrPackage: parsed.sourceApp,
      recordType: recordType,
      money: parsed.money,
    );

    // 1. Pending drafts: identical fingerprint, or cross-channel twin.
    final existingDraftRows = await (db.select(
      db.autoMaps,
    )..where((t) => t.key.equals(autoMapDraftKey))).get();
    for (final row in existingDraftRows) {
      try {
        final existing = AutoBillDraft.parse(
          row.draft,
          id: row.id,
          fallbackNowMs: captureMs,
        );
        if (existing.fingerprint == fingerprint ||
            _isCrossChannelTwin(
              crossFingerprint,
              channel,
              captureMs,
              existing.raw['xcfp'],
              existing.raw['channel'],
              existing.raw['capturedAtMs'],
            )) {
          return (AutoBillIngestOutcome.duplicate(draftId: row.id), null);
        }
      } on Failure {
        // Ignore malformed rows.
      }
    }

    // 2. Recent captures (covers already auto-confirmed bills).
    final log = _RecentCaptureLog.parse(
      await _readPreference(_recentCapturesPreferenceKey),
    );
    for (final entry in log.entries) {
      if (entry.undone) continue;
      if (entry.fingerprint == fingerprint ||
          _isCrossChannelTwin(
            crossFingerprint,
            channel,
            captureMs,
            entry.crossFingerprint,
            entry.channel,
            entry.atMs,
          )) {
        final recordId = entry.recordId;
        if (recordId != null) {
          final stillExists =
              await (db.select(
                db.records,
              )..where((t) => t.recordId.equals(recordId))).getSingleOrNull() !=
              null;
          if (stillExists) {
            return (AutoBillIngestOutcome.duplicate(recordId: recordId), null);
          }
        } else if (entry.draftId != null) {
          // Draft already handled (confirmed / ignored) — never resurrect it.
          return (
            AutoBillIngestOutcome.duplicate(draftId: entry.draftId),
            null,
          );
        }
      }
    }

    final remark =
        (matched.remark != null && matched.remark!.trim().isNotEmpty
                ? matched.remark!.trim()
                : parsed.merchant.trim())
            .trim();

    final canAuto =
        allowAutoConfirm &&
        matched.canAutoConfirm(
          globalAutoConfirmEnabled: settings.autoConfirmMatchedRules,
          resolvedRecordType: recordType,
          resolvedRuleCategoryId: ruleCategoryId,
          resolvedPrimaryAssetId: resolvedAssetId,
          resolvedSecondaryAssetId: resolvedToAssetId,
        );

    final primaryAsset = assets
        .where((a) => a.id == resolvedAssetId)
        .firstOrNull;
    final secondaryAsset = assets
        .where((a) => a.id == resolvedToAssetId)
        .firstOrNull;
    final categoryName = resolvedCatId == null
        ? null
        : (await (db.select(
            db.recordCategories,
          )..where((t) => t.id.equals(resolvedCatId))).getSingleOrNull())?.name;
    final currencySymbol = await _currencySymbolFor(primaryAsset);

    if (canAuto) {
      final discount = parsed.discount;
      final useDiscount =
          discount != null &&
          !discount.isZero &&
          discount.units <= parsed.money.units &&
          recordType != RecordType.transfer;
      final netMoney = useDiscount ? parsed.money - discount : parsed.money;
      final extra = await _buildCurrencyExtra(
        recordType: recordType,
        grossMoney: parsed.money,
        netMoney: netMoney,
        primaryAsset: primaryAsset,
        secondaryAsset: recordType == RecordType.transfer
            ? secondaryAsset
            : null,
      );
      final recordId = await _ledger.saveRecord(
        commandId:
            'auto-rec:${sha256.convert(utf8.encode(innerCommandSeed)).toString()}',
        draft: RecordDraft(
          type: recordType,
          money: netMoney,
          bookId: book.id,
          recordTime: parsed.recordTimeMs,
          categoryId: recordType == RecordType.transfer
              ? noRef
              : ruleCategoryId!,
          assetId: recordType == RecordType.transfer ? noRef : resolvedAssetId!,
          fromAssetId: recordType == RecordType.transfer
              ? resolvedAssetId!
              : noRef,
          toAssetId: recordType == RecordType.transfer
              ? resolvedToAssetId!
              : noRef,
          remark: remark,
          discount: useDiscount ? discount : null,
          extra: extra,
        ),
      );
      log.add(
        _RecentCaptureEntry(
          fingerprint: fingerprint,
          crossFingerprint: crossFingerprint,
          channel: channel,
          atMs: captureMs,
          recordId: recordId,
          sourceApp: parsed.sourceApp,
        ),
      );
      await _writePreference(_recentCapturesPreferenceKey, log.encode());
      return (
        AutoBillIngestOutcome.autoConfirmed(
          recordId: recordId,
          recordType: recordType,
          money: netMoney,
          merchant: remark,
          categoryId: ruleCategoryId,
          assetId: resolvedAssetId,
          toAssetId: recordType == RecordType.transfer
              ? resolvedToAssetId
              : null,
          parseSource: parsed.source,
        ),
        AutoBillPromptRequest(
          promptKind: AutoBillPromptRequest.kindAutoConfirmed,
          promptMode: settings.promptMode.wireKey,
          recordId: recordId,
          recordType: recordType,
          amountFormatted: netMoney.decimal,
          currencySymbol: currencySymbol,
          merchant: remark,
          categoryId: recordType == RecordType.transfer ? null : ruleCategoryId,
          categoryName: recordType == RecordType.transfer ? null : categoryName,
          assetId: resolvedAssetId,
          assetName: primaryAsset?.name,
        ),
      );
    }

    final draft = AutoBillDraft(
      recordType: recordType,
      money: parsed.money,
      discount: parsed.discount,
      recordTimeMs: parsed.recordTimeMs,
      sourceApp: parsed.sourceApp,
      remarks: [if (remark.isNotEmpty) remark],
      accountHint1: parsed.accountHint1,
      accountHint2: parsed.accountHint2,
      categoryHint: parsed.categoryHint,
      bookId: book.id,
      categoryId: resolvedCatId,
      assetId: resolvedAssetId,
      toAssetId: resolvedToAssetId,
      rawText: parsed.rawText,
      fingerprint: fingerprint,
      isRefund: parsed.isRefund,
      raw: {
        'xcfp': crossFingerprint,
        'channel': ?channel,
        'capturedAtMs': captureMs,
        'parseSource': parsed.source,
      },
    );
    final insertedId = await db
        .into(db.autoMaps)
        .insert(
          AutoMapsCompanion.insert(
            key: autoMapDraftKey,
            draft: Value(draft.encode()),
          ),
        );
    log.add(
      _RecentCaptureEntry(
        fingerprint: fingerprint,
        crossFingerprint: crossFingerprint,
        channel: channel,
        atMs: captureMs,
        draftId: insertedId,
        sourceApp: parsed.sourceApp,
      ),
    );
    await _writePreference(_recentCapturesPreferenceKey, log.encode());
    return (
      AutoBillIngestOutcome.draftQueued(
        draftId: insertedId,
        recordType: recordType,
        money: parsed.money,
        merchant: remark,
        categoryId: resolvedCatId,
        assetId: resolvedAssetId,
        toAssetId: resolvedToAssetId,
        parseSource: parsed.source,
      ),
      AutoBillPromptRequest(
        promptKind: AutoBillPromptRequest.kindDraft,
        promptMode: settings.promptMode.wireKey,
        draftId: insertedId,
        recordType: recordType,
        amountFormatted: parsed.money.decimal,
        currencySymbol: currencySymbol,
        merchant: remark,
        categoryId: resolvedCatId,
        categoryName: categoryName,
        assetId: resolvedAssetId,
        assetName: primaryAsset?.name,
      ),
    );
  }

  static bool _isCrossChannelTwin(
    String crossFingerprint,
    String? channel,
    int captureMs,
    Object? otherFingerprint,
    Object? otherChannel,
    Object? otherAtMs,
  ) {
    if (channel == null || otherChannel is! String || otherChannel.isEmpty) {
      return false;
    }
    if (otherChannel == channel) return false;
    if (otherFingerprint != crossFingerprint) return false;
    final at = otherAtMs is int ? otherAtMs : int.tryParse('$otherAtMs');
    return at != null && isWithinCrossChannelWindow(at, captureMs);
  }

  Future<String> _currencySymbolFor(Asset? asset) async {
    final code = normalizeCurrency(asset?.currency) ?? baseCurrency;
    if (code == 'CNY') return '¥';
    final row = await (db.select(
      db.currencies,
    )..where((t) => t.code.equals(code))).getSingleOrNull();
    final symbol = row?.symbol.trim();
    return symbol == null || symbol.isEmpty ? code : symbol;
  }

  /// Pulls any queued events from [AutoBillBridge] and ingests valid payment
  /// bills (draft or auto-confirmed). Returns the number created.
  Future<int> ingestCapturedEvents() async {
    final outcomes = await ingestCapturedEventsWithOutcomes();
    return outcomes.where((o) => o.created).length;
  }

  /// Like [ingestCapturedEvents] but returns every outcome.
  Future<List<AutoBillIngestOutcome>> ingestCapturedEventsWithOutcomes() async {
    final events = await _bridge.consumeCapturedEvents();
    final settings = events.isEmpty
        ? const AutoBillSettings()
        : await getSettings();
    final out = <AutoBillIngestOutcome>[];
    for (var i = 0; i < events.length; i++) {
      out.add(
        await ingestCapturedEvent(events[i], index: i, settings: settings),
      );
    }
    return out;
  }

  /// Ingests one live or queued capture, honoring per-channel switches.
  Future<AutoBillIngestOutcome> ingestCapturedEvent(
    CapturedPaymentEvent ev, {
    int index = 0,
    AutoBillSettings? settings,
  }) async {
    final effective = settings ?? await getSettings();
    if (ev.channel == captureChannelNotification &&
        !effective.enableNotificationCapture) {
      return const AutoBillIngestOutcome.skipped();
    }
    if (ev.channel == captureChannelAccessibility &&
        !effective.enableAccessibilityCapture) {
      return const AutoBillIngestOutcome.skipped();
    }
    final cmdHash = sha256
        .convert(
          utf8.encode(
            '${ev.packageName}|${ev.capturedAtMs}|${ev.rawText}|$index',
          ),
        )
        .toString()
        .substring(0, 40);
    return ingestPaymentTextWithOutcome(
      commandId: 'acc-ev:$cmdHash',
      rawText: ev.rawText,
      packageName: ev.packageName,
      capturedAtMs: ev.capturedAtMs,
      allowNonPaymentSkip: true,
      channel: ev.channel,
    );
  }

  /// Updates an existing pending draft in `auto_map`.
  Future<int> saveDraft({
    required String commandId,
    required AutoBillDraft draft,
  }) => _command(
    commandId,
    ['auto-bill-save-draft-v1', draft.id, draft.encode()],
    () async {
      if (draft.money.units <= BigInt.zero) {
        throw const Failure(FailureCode.validation, '草稿金额须大于 0');
      }
      if (draft.id != null) {
        final existing =
            await (db.select(db.autoMaps)..where(
                  (t) => t.id.equals(draft.id!) & t.key.equals(autoMapDraftKey),
                ))
                .getSingleOrNull();
        if (existing == null) {
          throw const Failure(FailureCode.conflict, '该草稿不存在或已处理');
        }
        await (db.update(db.autoMaps)..where((t) => t.id.equals(draft.id!)))
            .write(AutoMapsCompanion(draft: Value(draft.encode())));
        return '${draft.id}';
      }
      final newId = await db
          .into(db.autoMaps)
          .insert(
            AutoMapsCompanion.insert(
              key: autoMapDraftKey,
              draft: Value(draft.encode()),
            ),
          );
      return '$newId';
    },
    int.parse,
  );

  /// Deletes a single pending draft from `auto_map`.
  Future<void> deleteDraft({required String commandId, required int draftId}) =>
      _command(commandId, ['auto-bill-delete-draft-v1', draftId], () async {
        await (db.delete(db.autoMaps)..where(
              (t) => t.id.equals(draftId) & t.key.equals(autoMapDraftKey),
            ))
            .go();
        return '$draftId';
      }, (_) {});

  /// Clears all pending drafts (`key == 'KEY_DRAFT'`) without touching user rules.
  Future<int> clearDrafts({required String commandId}) =>
      _command(commandId, const ['auto-bill-clear-drafts-v1'], () async {
        final deleted = await (db.delete(
          db.autoMaps,
        )..where((t) => t.key.equals(autoMapDraftKey))).go();
        return '$deleted';
      }, int.parse);

  /// Confirms a pending draft into `record` via `LedgerService.saveRecord`,
  /// atomically deleting the `KEY_DRAFT` row and optionally learning a keyword rule (`F-020` R4).
  Future<String> confirmDraft({
    required String commandId,
    required int draftId,
    int? bookId,
    int? recordType,
    Money? money,
    Money? discount,
    int? categoryId,
    int? assetId,
    int? toAssetId,
    String? remark,
    int? recordTimeMs,
    bool learnRule = false,
    String? ruleKeyword,
  }) => _command(
    commandId,
    [
      'auto-bill-confirm-draft-v1',
      draftId,
      bookId,
      recordType,
      money?.toJson(),
      discount?.toJson(),
      categoryId,
      assetId,
      toAssetId,
      remark,
      recordTimeMs,
      learnRule,
      ruleKeyword,
    ],
    () async {
      final row =
          await (db.select(db.autoMaps)..where(
                (t) => t.id.equals(draftId) & t.key.equals(autoMapDraftKey),
              ))
              .getSingleOrNull();
      if (row == null) {
        throw const Failure(FailureCode.conflict, '该草稿已处理或已删除');
      }

      final parsedDraft = AutoBillDraft.parse(
        row.draft,
        id: row.id,
        fallbackNowMs: db.nowMs(),
      );
      final rules = await _loadRulesInternal();
      final ruleMatch = matchAutoMapRules(rules, [
        parsedDraft.primaryRemark,
        ?parsedDraft.accountHint1,
        ?parsedDraft.accountHint2,
        ?parsedDraft.categoryHint,
        parsedDraft.sourceApp,
        ?parsedDraft.rawText,
      ]);

      final effectiveType =
          recordType ?? ruleMatch.recordType ?? parsedDraft.recordType;
      final grossMoney = money ?? parsedDraft.money;
      if (grossMoney.units <= BigInt.zero) {
        throw const Failure(FailureCode.validation, '入账金额须大于 0');
      }
      final effectiveDiscount = discount ?? parsedDraft.discount;
      if (effectiveDiscount != null &&
          effectiveDiscount.units > grossMoney.units) {
        throw const Failure(FailureCode.validation, '优惠金额不能大于账单金额');
      }
      final netMoney =
          (effectiveDiscount != null &&
              !effectiveDiscount.isZero &&
              (effectiveType == RecordType.expense ||
                  effectiveType == RecordType.income))
          ? grossMoney - effectiveDiscount
          : grossMoney;

      final book = await _resolveBook(
        bookId ?? parsedDraft.bookId ?? ruleMatch.bookId,
      );

      final resolvedCategoryId = effectiveType == RecordType.transfer
          ? noRef
          : await _resolveCategoryRequired(
              book: book,
              recordType: effectiveType,
              explicitId:
                  categoryId ?? parsedDraft.categoryId ?? ruleMatch.categoryId,
              hint: parsedDraft.categoryHint,
            );

      final assets =
          await (db.select(db.assets)..orderBy([
                (t) => OrderingTerm.asc(t.sort),
                (t) => OrderingTerm.asc(t.id),
              ]))
              .get();
      final links = await db.select(db.assetBooks).get();

      final primaryAsset = await _resolveAssetOptionalOrExplicit(
        assets: assets,
        links: links,
        bookId: book.id,
        explicitId: assetId,
        fallbackId: parsedDraft.assetId ?? ruleMatch.assetId,
        hint: parsedDraft.accountHint1 ?? parsedDraft.sourceApp,
        label: effectiveType == RecordType.transfer ? '转出账户' : '账户',
      );
      final secondaryAsset = effectiveType == RecordType.transfer
          ? await _resolveAssetOptionalOrExplicit(
              assets: assets,
              links: links,
              bookId: book.id,
              explicitId: toAssetId,
              fallbackId: parsedDraft.toAssetId ?? ruleMatch.toAssetId,
              hint: parsedDraft.accountHint2,
              label: '转入账户',
            )
          : null;

      if (effectiveType == RecordType.transfer) {
        if (primaryAsset == null || secondaryAsset == null) {
          throw const Failure(FailureCode.validation, '转账入账必须选择有效的转出账户与转入账户');
        }
        if (primaryAsset.id == secondaryAsset.id) {
          throw const Failure(FailureCode.validation, '转出和转入账户不能相同');
        }
      }

      final effectiveRemark =
          (remark ?? ruleMatch.remark ?? parsedDraft.primaryRemark).trim();
      final effectiveTimeMs = recordTimeMs ?? parsedDraft.recordTimeMs;

      final extra = await _buildCurrencyExtra(
        recordType: effectiveType,
        grossMoney: grossMoney,
        netMoney: netMoney,
        primaryAsset: primaryAsset,
        secondaryAsset: secondaryAsset,
      );

      final recordDraft = RecordDraft(
        type: effectiveType,
        money: netMoney,
        bookId: book.id,
        recordTime: effectiveTimeMs,
        categoryId: resolvedCategoryId,
        assetId:
            (effectiveType == RecordType.transfer ||
                effectiveType == RecordType.reimbursable)
            ? noRef
            : (primaryAsset?.id ?? noRef),
        fromAssetId: effectiveType == RecordType.transfer
            ? primaryAsset!.id
            : (effectiveType == RecordType.reimbursable
                  ? (primaryAsset?.id ?? noRef)
                  : noRef),
        toAssetId: effectiveType == RecordType.transfer
            ? secondaryAsset!.id
            : noRef,
        remark: effectiveRemark,
        discount: effectiveDiscount != null && !effectiveDiscount.isZero
            ? effectiveDiscount
            : null,
        extra: extra,
      );

      final innerCmdId =
          'draft-rec:${sha256.convert(utf8.encode(commandId)).toString()}';
      final createdRecordId = await _ledger.saveRecord(
        commandId: innerCmdId,
        draft: recordDraft,
      );

      await (db.delete(db.autoMaps)..where((t) => t.id.equals(draftId))).go();

      if (learnRule) {
        final candidateKey = (ruleKeyword ?? effectiveRemark).trim();
        if (candidateKey.isNotEmpty &&
            candidateKey.length <= 100 &&
            isAutoMapRuleKey(candidateKey)) {
          final learnedInfo = AutoMapInfo(
            mapAssetId: primaryAsset?.id,
            toAssetId: secondaryAsset?.id,
            mapCategoryId: resolvedCategoryId == noRef
                ? null
                : resolvedCategoryId,
            bookId: book.id,
            recordType: effectiveType,
          );
          if (learnedInfo.hasAnyMapping) {
            await _upsertLearnedRule(candidateKey, learnedInfo);
          }
        }
      }

      return createdRecordId;
    },
    (id) => id,
  );

  /// Confirms several pending drafts atomically (all-or-nothing) and returns
  /// the created record ids in [draftIds] order.
  Future<List<String>> confirmDraftsBatch({
    required String commandId,
    required List<int> draftIds,
  }) {
    final ids = draftIds.toSet().toList(growable: false);
    if (ids.isEmpty) {
      throw const Failure(FailureCode.validation, '请至少勾选一条待确认草稿');
    }
    return _command<List<String>>(
      commandId,
      ['auto-bill-confirm-batch-v1', ids],
      () async {
        final created = <String>[];
        for (var i = 0; i < ids.length; i++) {
          final innerCmd =
              'draft-batch:${sha256.convert(utf8.encode('$commandId:${ids[i]}')).toString().substring(0, 48)}';
          try {
            created.add(
              await confirmDraft(commandId: innerCmd, draftId: ids[i]),
            );
          } on Failure catch (e) {
            throw Failure(e.code, '第 ${i + 1} 条草稿无法入账：${e.message}');
          }
        }
        return jsonEncode(created);
      },
      (json) => [for (final id in jsonDecode(json) as List) '$id'],
    ).whenComplete(_notifyChanged);
  }

  /// Undoes an auto-confirmed bill (notification “撤销”): deletes the record
  /// through `LedgerService.deleteRecord` (balances restored) and restores it
  /// as a `KEY_DRAFT` so nothing is lost. Idempotent: a second undo of the same
  /// record returns the already restored draft id.
  Future<int> undoAutoConfirmedRecord({
    required String commandId,
    required String recordId,
  }) => _command<int>(
    commandId,
    ['auto-bill-undo-record-v1', recordId],
    () async {
      final drafts = await (db.select(
        db.autoMaps,
      )..where((t) => t.key.equals(autoMapDraftKey))).get();
      for (final row in drafts) {
        try {
          final d = AutoBillDraft.parse(
            row.draft,
            id: row.id,
            fallbackNowMs: db.nowMs(),
          );
          if (d.raw['undoneRecordId'] == recordId) return '${row.id}';
        } on Failure {
          // Ignore malformed rows.
        }
      }

      final rec = await (db.select(
        db.records,
      )..where((t) => t.recordId.equals(recordId))).getSingleOrNull();
      if (rec == null) {
        throw const Failure(FailureCode.conflict, '该账单已删除或已撤销');
      }
      if (rec.type != RecordType.expense &&
          rec.type != RecordType.income &&
          rec.type != RecordType.transfer) {
        throw const Failure(FailureCode.validation, '仅支持撤销自动入账的收支或转账账单');
      }

      final log = _RecentCaptureLog.parse(
        await _readPreference(_recentCapturesPreferenceKey),
      );
      final entry = log.entries
          .where((e) => e.recordId == recordId)
          .firstOrNull;

      final discountMinor = rec.discountMinor ?? BigInt.zero;
      final hasDiscount =
          discountMinor > BigInt.zero && rec.type != RecordType.transfer;
      final isTransfer = rec.type == RecordType.transfer;
      int? positive(int id) => id > 0 ? id : null;
      final restored = AutoBillDraft(
        recordType: rec.type,
        money: Money.minor(
          hasDiscount ? rec.moneyMinor + discountMinor : rec.moneyMinor,
        ),
        discount: hasDiscount ? Money.minor(discountMinor) : null,
        recordTimeMs: rec.recordTime,
        sourceApp: entry?.sourceApp ?? '',
        remarks: [if (rec.remark.trim().isNotEmpty) rec.remark.trim()],
        bookId: rec.accountBookId,
        categoryId: isTransfer ? null : positive(rec.recordCatId),
        assetId: isTransfer ? positive(rec.fromAssetId) : positive(rec.assetId),
        toAssetId: isTransfer ? positive(rec.toAssetId) : null,
        fingerprint: entry?.fingerprint,
        raw: {'undoneRecordId': recordId},
      );

      await _ledger.deleteRecord(
        commandId:
            'undo-rec:${sha256.convert(utf8.encode(commandId)).toString()}',
        recordId: recordId,
      );
      final draftId = await db
          .into(db.autoMaps)
          .insert(
            AutoMapsCompanion.insert(
              key: autoMapDraftKey,
              draft: Value(restored.encode()),
            ),
          );
      if (entry != null) {
        log.markUndone(recordId);
        await _writePreference(_recentCapturesPreferenceKey, log.encode());
      }
      return '$draftId';
    },
    int.parse,
  ).whenComplete(_notifyChanged);

  /// Executes a native prompt action (notification button / overlay card).
  Future<AutoBillPromptActionResult> executePromptAction(
    AutoBillPromptActionEvent event, {
    String? commandId,
  }) async {
    final cmd =
        commandId ??
        'prompt:${sha256.convert(utf8.encode('${event.action}|${event.draftId}|${event.recordId}|${event.actionAtMs}|${event.categoryId}|${event.assetId}|${event.remark}')).toString().substring(0, 48)}';
    switch (event.action) {
      case AutoBillPromptActionKind.confirmDraft:
        final recordId = await confirmDraft(
          commandId: cmd,
          draftId: event.draftId!,
          categoryId: event.categoryId,
          assetId: event.assetId,
          remark: event.remark,
        );
        await _notifyChanged();
        return AutoBillPromptActionResult(
          action: event.action,
          draftId: event.draftId,
          recordId: recordId,
        );
      case AutoBillPromptActionKind.ignoreDraft:
        await deleteDraft(commandId: cmd, draftId: event.draftId!);
        await _notifyChanged();
        return AutoBillPromptActionResult(
          action: event.action,
          draftId: event.draftId,
        );
      case AutoBillPromptActionKind.editDraft:
        return AutoBillPromptActionResult(
          action: event.action,
          draftId: event.draftId,
          targetRoute: Uri(
            path: autoBillDraftsRoute,
            queryParameters: {'draftId': '${event.draftId}'},
          ).toString(),
        );
      case AutoBillPromptActionKind.undoRecord:
        final draftId = await undoAutoConfirmedRecord(
          commandId: cmd,
          recordId: event.recordId!,
        );
        return AutoBillPromptActionResult(
          action: event.action,
          draftId: draftId,
          recordId: event.recordId,
        );
      case AutoBillPromptActionKind.editRecord:
        return AutoBillPromptActionResult(
          action: event.action,
          recordId: event.recordId,
          targetRoute: '/record/${Uri.encodeComponent(event.recordId!)}',
        );
      default:
        throw Failure(FailureCode.validation, '不支持的提醒操作：${event.action}');
    }
  }

  /// Drains queued prompt actions (tapped while Flutter was detached) and
  /// executes them; failures are reported per item instead of aborting.
  Future<List<AutoBillPromptActionResult>>
  consumeAndExecutePendingPromptActions() async {
    final events = await _bridge.consumePendingPromptActions();
    final out = <AutoBillPromptActionResult>[];
    for (final e in events) {
      try {
        out.add(await executePromptAction(e));
      } on Failure catch (f) {
        out.add(
          AutoBillPromptActionResult(
            action: e.action,
            draftId: e.draftId,
            recordId: e.recordId,
            error: f.message,
          ),
        );
      }
    }
    return out;
  }

  Future<void> _upsertLearnedRule(String key, AutoMapInfo info) async {
    final rows = await db.select(db.autoMaps).get();
    final existing = rows
        .where(
          (r) =>
              isAutoMapRuleKey(r.key) &&
              r.key.trim().toLowerCase() == key.toLowerCase(),
        )
        .firstOrNull;
    if (existing != null) {
      await (db.update(db.autoMaps)..where((t) => t.id.equals(existing.id)))
          .write(AutoMapsCompanion(mapInfo: Value(info.encode())));
    } else {
      await db
          .into(db.autoMaps)
          .insert(
            AutoMapsCompanion.insert(key: key, mapInfo: Value(info.encode())),
          );
    }
  }

  Future<List<AutoMapRule>> _loadRulesInternal() async {
    final rows = await db.select(db.autoMaps).get();
    return [
      for (final row in rows)
        if (isAutoMapRuleKey(row.key))
          AutoMapRule(
            id: row.id,
            key: row.key,
            info: AutoMapInfo.parse(row.mapInfo),
          ),
    ];
  }

  Future<void> _validateRuleTargets(AutoMapInfo info) async {
    if (info.bookId != null) {
      final book = await (db.select(
        db.accountBooks,
      )..where((t) => t.id.equals(info.bookId!))).getSingleOrNull();
      if (book == null) {
        throw const Failure(FailureCode.validation, '映射的目标账本不存在');
      }
    }
    if (info.mapAssetId != null) {
      final asset = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(info.mapAssetId!))).getSingleOrNull();
      if (asset == null || asset.type == AssetType.debt) {
        throw const Failure(FailureCode.validation, '映射的目标账户无效');
      }
    }
    if (info.toAssetId != null) {
      final asset2 = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(info.toAssetId!))).getSingleOrNull();
      if (asset2 == null || asset2.type == AssetType.debt) {
        throw const Failure(FailureCode.validation, '映射的目标转入账户无效');
      }
    }
    if (info.mapCategoryId != null) {
      final cat = await (db.select(
        db.recordCategories,
      )..where((t) => t.id.equals(info.mapCategoryId!))).getSingleOrNull();
      if (cat == null) {
        throw const Failure(FailureCode.validation, '映射的目标分类不存在');
      }
    }
  }

  Future<AccountBook> _resolveBook(int? preferredBookId) async {
    if (preferredBookId != null) {
      final byPreferred = await (db.select(
        db.accountBooks,
      )..where((t) => t.id.equals(preferredBookId))).getSingleOrNull();
      if (byPreferred != null) return byPreferred;
    }
    final pref = await (db.select(
      db.preferences,
    )..where((t) => t.key.equals('current_book_id'))).getSingleOrNull();
    final currentId = int.tryParse(pref?.value ?? '') ?? 1;
    final current = await (db.select(
      db.accountBooks,
    )..where((t) => t.id.equals(currentId))).getSingleOrNull();
    if (current != null) return current;

    final fallback =
        await (db.select(db.accountBooks)
              ..orderBy([(t) => OrderingTerm.asc(t.id)])
              ..limit(1))
            .getSingleOrNull();
    if (fallback == null) {
      throw const Failure(FailureCode.validation, '当前尚无可用账本');
    }
    return fallback;
  }

  Future<int?> _tryPreMatchCategory({
    required int bookId,
    required int recordType,
    required int? explicitId,
    required String? hint,
  }) async {
    if (recordType == RecordType.transfer) return null;
    final wantType = recordType == RecordType.income
        ? RecordType.income
        : RecordType.expense;
    final categories =
        await (db.select(db.recordCategories)
              ..where(
                (t) => t.accountBookId.equals(bookId) & t.type.equals(wantType),
              )
              ..orderBy([
                (t) => OrderingTerm.asc(t.sort),
                (t) => OrderingTerm.asc(t.id),
              ]))
            .get();
    if (explicitId != null) {
      final byId = categories.where((c) => c.id == explicitId).firstOrNull;
      if (byId != null) return byId.id;
    }
    if (hint != null && hint.trim().isNotEmpty) {
      final byHint = matchCategoryByRef(categories, hint);
      if (byHint != null) return byHint.id;
    }
    return null;
  }

  Future<int> _resolveCategoryRequired({
    required AccountBook book,
    required int recordType,
    required int? explicitId,
    required String? hint,
  }) async {
    final wantType =
        (recordType == RecordType.income ||
            recordType == RecordType.advanceIncome)
        ? RecordType.income
        : RecordType.expense;
    final categories =
        await (db.select(db.recordCategories)
              ..where(
                (t) =>
                    t.accountBookId.equals(book.id) & t.type.equals(wantType),
              )
              ..orderBy([
                (t) => OrderingTerm.asc(t.sort),
                (t) => OrderingTerm.asc(t.id),
              ]))
            .get();

    if (explicitId != null) {
      final byId = categories.where((c) => c.id == explicitId).firstOrNull;
      if (byId != null) return byId.id;
    }
    if (hint != null && hint.trim().isNotEmpty) {
      final byHint = matchCategoryByRef(categories, hint);
      if (byHint != null) return byHint.id;
    }
    final fallback =
        categories.where((c) => !c.isHide).firstOrNull ??
        categories.firstOrNull;
    if (fallback == null) {
      throw Failure(FailureCode.validation, '账本“${book.name}”下暂无可用分类');
    }
    return fallback.id;
  }

  Future<int?> _verifyFundingAssetId(List<Asset> assets, int? id) async {
    if (id == null || id <= 0) return null;
    final hit = assets
        .where(
          (a) =>
              a.id == id &&
              a.type != AssetType.debt &&
              a.status != AssetStatus.settled,
        )
        .firstOrNull;
    return hit?.id;
  }

  Future<Asset?> _resolveAssetOptionalOrExplicit({
    required List<Asset> assets,
    required List<AssetBook> links,
    required int bookId,
    required int? explicitId,
    required int? fallbackId,
    required String? hint,
    required String label,
  }) async {
    if (explicitId != null) {
      if (explicitId == noRef) return null;
      final exact = assets
          .where((a) => a.id == explicitId && a.type != AssetType.debt)
          .firstOrNull;
      if (exact == null) {
        throw Failure(FailureCode.validation, '所选$label不存在或不可用');
      }
      return exact;
    }
    if (fallbackId != null && fallbackId > 0) {
      final byFallback = assets
          .where(
            (a) =>
                a.id == fallbackId &&
                a.type != AssetType.debt &&
                a.status != AssetStatus.settled,
          )
          .firstOrNull;
      if (byFallback != null) return byFallback;
    }
    return matchFundingAssetByHint(
      assets: assets,
      links: links,
      bookId: bookId,
      rawHint: hint,
    );
  }

  Future<RecordExtra> _buildCurrencyExtra({
    required int recordType,
    required Money grossMoney,
    required Money netMoney,
    required Asset? primaryAsset,
    required Asset? secondaryAsset,
  }) async {
    final extra = RecordExtra();
    final primaryCurrency =
        normalizeCurrency(primaryAsset?.currency) ?? baseCurrency;
    final secondaryCurrency =
        normalizeCurrency(secondaryAsset?.currency) ?? baseCurrency;

    if (recordType == RecordType.transfer) {
      if (primaryCurrency == baseCurrency &&
          secondaryCurrency == baseCurrency) {
        return extra;
      }
      final rates = await _loadRateTable();
      final targetMinor = primaryCurrency == secondaryCurrency
          ? netMoney.storageMinor
          : rates.convert(
              netMoney.storageMinor,
              primaryCurrency,
              secondaryCurrency,
            );
      extra.currency = billSnapshot(
        source: primaryCurrency,
        sourceMinor: netMoney.storageMinor,
        account: secondaryCurrency,
        assetMinor: targetMinor,
        rates: rates,
      );
      return extra;
    }

    if (primaryCurrency != baseCurrency) {
      final rates = await _loadRateTable();
      extra.currency = billSnapshot(
        source: primaryCurrency,
        sourceMinor: grossMoney.storageMinor,
        account: primaryCurrency,
        assetMinor: netMoney.storageMinor,
        rates: rates,
      );
    }
    return extra;
  }

  Future<RateTable> _loadRateTable() async {
    final rows = await db.select(db.currencies).get();
    return RateTable({for (final c in rows) c.code: c.rateToAnchor});
  }
}

/// Kind of [AutoBillIngestOutcome].
enum AutoBillIngestKind { draftQueued, autoConfirmed, duplicate, skipped }

/// Result of tiered ingestion (`AutoBillService.ingestPaymentTextWithOutcome`).
final class AutoBillIngestOutcome {
  const AutoBillIngestOutcome._({
    required this.kind,
    this.draftId,
    this.recordId,
    this.recordType,
    this.money,
    this.merchant,
    this.categoryId,
    this.assetId,
    this.toAssetId,
    this.parseSource,
  });

  const AutoBillIngestOutcome.draftQueued({
    required int draftId,
    required int recordType,
    required Money money,
    String merchant = '',
    int? categoryId,
    int? assetId,
    int? toAssetId,
    String? parseSource,
  }) : this._(
         kind: AutoBillIngestKind.draftQueued,
         draftId: draftId,
         recordType: recordType,
         money: money,
         merchant: merchant,
         categoryId: categoryId,
         assetId: assetId,
         toAssetId: toAssetId,
         parseSource: parseSource,
       );

  const AutoBillIngestOutcome.autoConfirmed({
    required String recordId,
    required int recordType,
    required Money money,
    String merchant = '',
    int? categoryId,
    int? assetId,
    int? toAssetId,
    String? parseSource,
  }) : this._(
         kind: AutoBillIngestKind.autoConfirmed,
         recordId: recordId,
         recordType: recordType,
         money: money,
         merchant: merchant,
         categoryId: categoryId,
         assetId: assetId,
         toAssetId: toAssetId,
         parseSource: parseSource,
       );

  const AutoBillIngestOutcome.duplicate({int? draftId, String? recordId})
    : this._(
        kind: AutoBillIngestKind.duplicate,
        draftId: draftId,
        recordId: recordId,
      );

  const AutoBillIngestOutcome.skipped()
    : this._(kind: AutoBillIngestKind.skipped);

  final AutoBillIngestKind kind;
  final int? draftId;
  final String? recordId;
  final int? recordType;

  /// Draft gross amount or booked net amount (`BigInt` minor units).
  final Money? money;
  final String? merchant;
  final int? categoryId;
  final int? assetId;
  final int? toAssetId;

  /// `'payment'` | `'nlp'` | `'ai'`.
  final String? parseSource;

  /// `true` when a new draft or record was written.
  bool get created =>
      kind == AutoBillIngestKind.draftQueued ||
      kind == AutoBillIngestKind.autoConfirmed;

  String encode() => jsonEncode({
    'k': kind.name,
    'd': draftId,
    'r': recordId,
    't': recordType,
    'm': money?.storageMinor.toString(),
    'n': merchant,
    'c': categoryId,
    'a': assetId,
    'b': toAssetId,
    's': parseSource,
  });

  static AutoBillIngestOutcome decode(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return const AutoBillIngestOutcome.skipped();
    final legacyId = int.tryParse(text);
    if (legacyId != null) {
      return AutoBillIngestOutcome.duplicate(draftId: legacyId);
    }
    final map = jsonDecode(text) as Map<String, Object?>;
    final kind = AutoBillIngestKind.values.firstWhere(
      (k) => k.name == map['k'],
      orElse: () => AutoBillIngestKind.skipped,
    );
    final minor = BigInt.tryParse('${map['m'] ?? ''}');
    return AutoBillIngestOutcome._(
      kind: kind,
      draftId: map['d'] as int?,
      recordId: map['r'] as String?,
      recordType: map['t'] as int?,
      money: minor == null ? null : Money.minor(minor),
      merchant: map['n'] as String?,
      categoryId: map['c'] as int?,
      assetId: map['a'] as int?,
      toAssetId: map['b'] as int?,
      parseSource: map['s'] as String?,
    );
  }
}

/// Result of [AutoBillService.executePromptAction].
final class AutoBillPromptActionResult {
  const AutoBillPromptActionResult({
    required this.action,
    this.draftId,
    this.recordId,
    this.targetRoute,
    this.error,
  });

  final String action;
  final int? draftId;
  final String? recordId;

  /// Route the UI should open (`edit_draft` / `edit_record`).
  final String? targetRoute;

  /// Failure message when the action could not be executed.
  final String? error;

  bool get succeeded => error == null;
}

/// Normalized parse candidate fed into the rule / gate pipeline.
final class _IngestCandidate {
  const _IngestCandidate({
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
    this.isRefund = false,
    required this.source,
  });

  factory _IngestCandidate.fromPayment(ParsedPaymentNotification p) =>
      _IngestCandidate(
        recordType: p.recordType,
        money: p.money,
        discount: p.discount,
        recordTimeMs: p.recordTimeMs,
        sourceApp: p.sourceApp,
        merchant: p.merchant,
        accountHint1: p.accountHint1,
        accountHint2: p.accountHint2,
        categoryHint: p.categoryHint,
        rawText: p.rawText,
        isRefund: p.isRefund,
        source: 'payment',
      );

  factory _IngestCandidate.fromSmart(
    SmartBillParseResult r, {
    required String sourceApp,
  }) => _IngestCandidate(
    recordType: r.recordType,
    money: r.money,
    discount: r.discount,
    recordTimeMs: r.recordTimeMs,
    sourceApp: sourceApp,
    merchant: r.remark,
    accountHint1: r.assetHint,
    accountHint2: r.toAssetHint,
    categoryHint: r.categoryHint,
    rawText: r.rawText,
    source: r.source,
  );

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
  final bool isRefund;
  final String source;
}

final class _RecentCaptureEntry {
  _RecentCaptureEntry({
    required this.fingerprint,
    required this.crossFingerprint,
    this.channel,
    required this.atMs,
    this.recordId,
    this.draftId,
    this.sourceApp,
    this.undone = false,
  });

  static _RecentCaptureEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final fp = raw['fp'];
    final xc = raw['xc'];
    final at = raw['at'];
    if (fp is! String || xc is! String || at is! int) return null;
    return _RecentCaptureEntry(
      fingerprint: fp,
      crossFingerprint: xc,
      channel: raw['ch'] as String?,
      atMs: at,
      recordId: raw['rid'] as String?,
      draftId: raw['did'] as int?,
      sourceApp: raw['app'] as String?,
      undone: raw['undone'] == true,
    );
  }

  final String fingerprint;
  final String crossFingerprint;
  final String? channel;
  final int atMs;
  final String? recordId;
  final int? draftId;
  final String? sourceApp;
  bool undone;

  Map<String, Object?> toJson() => {
    'fp': fingerprint,
    'xc': crossFingerprint,
    'ch': ?channel,
    'at': atMs,
    'rid': ?recordId,
    'did': ?draftId,
    'app': ?sourceApp,
    if (undone) 'undone': true,
  };
}

/// Bounded FIFO log in `ti_preference['auto_bill_recent_captures']`.
final class _RecentCaptureLog {
  _RecentCaptureLog(this.entries);

  static const int maxEntries = 60;

  factory _RecentCaptureLog.parse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return _RecentCaptureLog([]);
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return _RecentCaptureLog([]);
      return _RecentCaptureLog([
        for (final item in decoded) ?_RecentCaptureEntry.fromJson(item),
      ]);
    } on FormatException {
      return _RecentCaptureLog([]);
    }
  }

  final List<_RecentCaptureEntry> entries;

  void add(_RecentCaptureEntry entry) {
    entries.add(entry);
    if (entries.length > maxEntries) {
      entries.removeRange(0, entries.length - maxEntries);
    }
  }

  void markUndone(String recordId) {
    for (final e in entries) {
      if (e.recordId == recordId) e.undone = true;
    }
  }

  String encode() => jsonEncode([for (final e in entries) e.toJson()]);
}
