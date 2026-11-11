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
import '../../platform/auto_bill_bridge.dart';
import '../db/database.dart';
import '../db/failures.dart';
import '../ledger/ledger_service.dart';
import 'url_scheme_service.dart'
    show matchCategoryByRef, matchFundingAssetByHint;

/// Data & application service for `F-020` auto-bookkeeping keyword rules,
/// payment notification text ingestion, draft inbox, and accessibility bridge.
final class AutoBillService {
  AutoBillService(
    this.db, {
    LedgerService? ledgerService,
    AutoBillBridge? bridge,
  }) : _ledger = ledgerService ?? LedgerService(db),
       _bridge = bridge ?? createAutoBillBridge();

  final AppDatabase db;
  final LedgerService _ledger;
  final AutoBillBridge _bridge;

  AutoBillBridge get bridge => _bridge;

  /// Queries honest Android `AccessibilityService` status (`已开启` / `未开启` / `当前平台不支持`).
  Future<AccessibilityBridgeStatus> getAccessibilityStatus() =>
      _bridge.getAccessibilityStatus();

  /// Opens Android system accessibility settings when supported.
  Future<bool> openAccessibilitySettings() =>
      _bridge.openAccessibilitySettings();

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

  /// Parses payment text (WeChat/Alipay/UnionPay/SMS), applies `auto_map` rules,
  /// and inserts a pending draft into `auto_map` (`key = 'KEY_DRAFT'`).
  ///
  /// When [allowNonPaymentSkip] is `true` (used for background accessibility events),
  /// returns `null` if [rawText] contains no valid positive payment amount.
  Future<int?> ingestPaymentText({
    required String commandId,
    required String rawText,
    String? packageName,
    int? capturedAtMs,
    bool allowNonPaymentSkip = false,
  }) => _command<int?>(
    commandId,
    [
      'auto-bill-ingest-v1',
      rawText,
      packageName,
      capturedAtMs,
      allowNonPaymentSkip,
    ],
    () async {
      final fallbackMs = capturedAtMs ?? db.nowMs();
      final parsed = parsePaymentText(
        rawText,
        packageOrApp: packageName,
        fallbackNowMs: fallbackMs,
      );
      if (parsed == null) {
        if (allowNonPaymentSkip) return '';
        throw const Failure(FailureCode.validation, '未从文本中识别出有效收支金额，请检查粘贴内容');
      }

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

      final resolvedCatId = await _tryPreMatchCategory(
        bookId: book.id,
        recordType: recordType,
        explicitId: matched.categoryId,
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

      // Deduplicate identical pending draft already sitting in the inbox.
      final existingDraftRows = await (db.select(
        db.autoMaps,
      )..where((t) => t.key.equals(autoMapDraftKey))).get();
      for (final row in existingDraftRows) {
        try {
          final existing = AutoBillDraft.parse(
            row.draft,
            id: row.id,
            fallbackNowMs: fallbackMs,
          );
          if (existing.fingerprint == fingerprint) {
            return '${row.id}';
          }
        } on Failure {
          // Ignore malformed rows.
        }
      }

      final remarkItems = <String>[
        if (matched.remark != null && matched.remark!.trim().isNotEmpty)
          matched.remark!.trim()
        else if (parsed.merchant.trim().isNotEmpty)
          parsed.merchant.trim(),
      ];

      final draft = AutoBillDraft(
        recordType: recordType,
        money: parsed.money,
        discount: parsed.discount,
        recordTimeMs: parsed.recordTimeMs,
        sourceApp: parsed.sourceApp,
        remarks: remarkItems,
        accountHint1: parsed.accountHint1,
        accountHint2: parsed.accountHint2,
        categoryHint: parsed.categoryHint,
        bookId: book.id,
        categoryId: resolvedCatId,
        assetId: resolvedAssetId,
        toAssetId: resolvedToAssetId,
        rawText: parsed.rawText,
        fingerprint: fingerprint,
      );

      final insertedId = await db
          .into(db.autoMaps)
          .insert(
            AutoMapsCompanion.insert(
              key: autoMapDraftKey,
              draft: Value(draft.encode()),
            ),
          );
      return '$insertedId';
    },
    (res) => res.isEmpty ? null : int.parse(res),
  );

  /// Pulls any queued events from [AutoBillBridge] and ingests valid payment drafts.
  Future<int> ingestCapturedEvents() async {
    final events = await _bridge.consumeCapturedEvents();
    var created = 0;
    for (var i = 0; i < events.length; i++) {
      final ev = events[i];
      final cmdHash = sha256
          .convert(
            utf8.encode(
              '${ev.packageName}|${ev.capturedAtMs}|${ev.rawText}|$i',
            ),
          )
          .toString()
          .substring(0, 40);
      final id = await ingestPaymentText(
        commandId: 'acc-ev:$cmdHash',
        rawText: ev.rawText,
        packageName: ev.packageName,
        capturedAtMs: ev.capturedAtMs,
        allowNonPaymentSkip: true,
      );
      if (id != null) created++;
    }
    return created;
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
