import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../../core/failure.dart';
import '../../core/money.dart';
import '../../domain/ledger/record_extra.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/asset_overview.dart'
    show RateTable, normalizeCurrency;
import '../../domain/rules/currency_rates.dart' show baseCurrency, billSnapshot;
import '../../domain/rules/template_card_rules.dart';
import '../db/database.dart';
import '../db/failures.dart';
import '../ledger/ledger_service.dart';

/// Input payload for creating or updating a bill template (`record_template`).
final class TemplateDraft {
  TemplateDraft({
    required this.type,
    required this.money,
    required this.bookId,
    this.name,
    this.fee,
    this.feeFromTarget = false,
    this.categoryId,
    this.assetId = noRef,
    this.assetId2 = noRef,
    this.remark = '',
    this.autoSave = false,
    this.excludeBudget = false,
    this.excludeExIn = false,
    this.tagIds = const <String>[],
    this.sourceCurrency,
  });

  final int type;
  final Money money;
  final int bookId;
  final String? name;
  final Money? fee;
  final bool feeFromTarget;
  final int? categoryId;

  /// Funding account for non-transfer templates, or source (`from`) account for transfers.
  final int assetId;

  /// Target (`to`) account for transfers (`noRef` for non-transfers).
  final int assetId2;

  final String remark;
  final bool autoSave;
  final bool excludeBudget;
  final bool excludeExIn;
  final List<String> tagIds;
  final String? sourceCurrency;

  List<Object?> get payload => <Object?>[
    type,
    money.toJson(),
    bookId,
    name?.trim(),
    fee?.toJson(),
    feeFromTarget,
    categoryId,
    assetId,
    assetId2,
    remark.trim(),
    autoSave,
    excludeBudget,
    excludeExIn,
    encodeTemplateTagsCsv(tagIds),
    sourceCurrency?.trim().toUpperCase(),
  ];
}

/// Service and query access for Bill Templates & Frequent Remarks (`F-016`, ADR-009).
final class TemplateRemarkService {
  TemplateRemarkService(this.db);
  final AppDatabase db;

  int _now() => db.nowMs();

  Future<T> _command<T>(
    String commandId,
    List<Object?> payload,
    Future<String> Function() body,
    T Function(String resultId) result,
  ) async {
    if (commandId.isEmpty || commandId.length > 128) {
      throw const Failure(FailureCode.validation, '提交标识无效');
    }
    final hash = sha256.convert(utf8.encode(jsonEncode(payload))).toString();
    return guardDatabase(
      () => db.transaction(() async {
        final previous = await (db.select(
          db.writeCommands,
        )..where((t) => t.commandId.equals(commandId))).getSingleOrNull();
        if (previous != null) {
          if (previous.payloadHash != hash) {
            throw const Failure(FailureCode.conflict, '同一提交标识的内容发生变化');
          }
          return result(previous.resultId);
        }
        final id = await body();
        await db
            .into(db.writeCommands)
            .insert(
              WriteCommandsCompanion.insert(
                commandId: commandId,
                payloadHash: hash,
                resultId: id,
                committedAt: _now(),
              ),
            );
        return result(id);
      }),
    );
  }

  /// Allocates next non-autoIncrement PK for `record_template` inside transaction (`R1`).
  Future<int> _nextTemplateId() async {
    final row = await db
        .customSelect(
          'SELECT COALESCE(MAX(id), 0) + 1 AS next_id FROM record_template',
        )
        .getSingle();
    return row.read<int>('next_id');
  }

  Future<int> _nextTemplateSort() async {
    final row = await db
        .customSelect(
          'SELECT COALESCE(MAX(sort), 0) + 1 AS next_sort FROM record_template',
        )
        .getSingle();
    return row.read<int>('next_sort');
  }

  // ---- Template Queries ----

  Stream<List<RecordTemplate>> watchTemplates({int? bookId, int? type}) {
    final q = db.select(db.recordTemplates);
    if (bookId != null) {
      q.where((t) => t.bookId.equals(bookId));
    }
    if (type != null) {
      q.where((t) => t.type.equals(type));
    }
    q.orderBy([(t) => OrderingTerm.asc(t.sort), (t) => OrderingTerm.asc(t.id)]);
    return q.watch();
  }

  Future<List<RecordTemplate>> getTemplates({int? bookId, int? type}) {
    final q = db.select(db.recordTemplates);
    if (bookId != null) {
      q.where((t) => t.bookId.equals(bookId));
    }
    if (type != null) {
      q.where((t) => t.type.equals(type));
    }
    q.orderBy([(t) => OrderingTerm.asc(t.sort), (t) => OrderingTerm.asc(t.id)]);
    return guardDatabase(q.get);
  }

  Stream<RecordTemplate?> watchTemplate(int id) => (db.select(
    db.recordTemplates,
  )..where((t) => t.id.equals(id))).watchSingleOrNull();

  Future<RecordTemplate?> getTemplate(int id) => guardDatabase(
    () => (db.select(
      db.recordTemplates,
    )..where((t) => t.id.equals(id))).getSingleOrNull(),
  );

  /// Resolves [templateId] into a [TemplatePrefill] with clean fallbacks if
  /// linked categories, accounts, or tags were deleted (`R3`).
  Future<TemplatePrefill> buildTemplatePrefill(int templateId) =>
      guardDatabase(() async {
        final row = await (db.select(
          db.recordTemplates,
        )..where((t) => t.id.equals(templateId))).getSingleOrNull();
        if (row == null) {
          throw const Failure(FailureCode.conflict, '账单模板不存在或已删除');
        }
        final book = await (db.select(
          db.accountBooks,
        )..where((b) => b.id.equals(row.bookId))).getSingleOrNull();
        final categories = await (db.select(
          db.recordCategories,
        )..where((c) => c.accountBookId.equals(row.bookId))).get();
        final assets = await db.select(db.assets).get();
        final tags = await (db.select(
          db.tags,
        )..where((t) => t.hidden.equals(false) & t.parent.isNotValue(1))).get();

        return resolveTemplatePrefill(
          template: _snapshotOf(row),
          bookExists: book != null,
          categoriesById: <int, TemplateCategoryRef>{
            for (final c in categories)
              c.id: TemplateCategoryRef(
                id: c.id,
                name: c.name,
                type: c.type,
                bookId: c.accountBookId,
                parentCatId: c.parentCatId,
                isHide: c.isHide,
              ),
          },
          assetsById: <int, TemplateAssetRef>{
            for (final a in assets)
              a.id: TemplateAssetRef(
                id: a.id,
                name: a.name,
                type: a.type,
                status: a.status,
                currency: a.currency,
              ),
          },
          validTagIds: <String>{for (final t in tags) t.tagId},
        );
      });

  // ---- Template Commands ----

  /// Creates (`templateId == null`) or updates a `RecordTemplate`.
  Future<int> saveTemplate({
    required String commandId,
    int? templateId,
    required TemplateDraft draft,
  }) => _command(
    commandId,
    <Object?>['template-save-v1', templateId, ...draft.payload],
    () async {
      final old = templateId == null
          ? null
          : await _requireTemplate(templateId);
      await _validateDraft(draft);

      final extra = TemplateExtra.parse(old?.exi)..name = draft.name;
      if (draft.type == RecordType.transfer) {
        extra.feeFromTarget = draft.feeFromTarget;
        extra.sourceCurrency = null;
      } else {
        extra.raw.remove('fee_from');
        extra.sourceCurrency = draft.sourceCurrency;
      }

      final normalizedCatId = draft.type == RecordType.transfer
          ? null
          : (draft.categoryId == null || draft.categoryId == noRef
                ? null
                : draft.categoryId);
      final normalizedAssetId = draft.assetId;
      final normalizedAssetId2 = draft.type == RecordType.transfer
          ? draft.assetId2
          : noRef;
      final feeMinor = draft.type == RecordType.transfer
          ? (draft.fee?.storageMinor ?? BigInt.zero)
          : BigInt.zero;
      final cleanRemark = draft.remark.trim();
      final encodedTags = encodeTemplateTagsCsv(draft.tagIds);

      if (old == null) {
        final newId = await _nextTemplateId();
        final sort = await _nextTemplateSort();
        await db
            .into(db.recordTemplates)
            .insert(
              RecordTemplatesCompanion.insert(
                id: Value(newId),
                type: draft.type,
                remark: Value(cleanRemark.isEmpty ? null : cleanRemark),
                moneyMinor: draft.money.storageMinor,
                feeMinor: Value(feeMinor),
                recordCatId: Value(normalizedCatId),
                assetId: Value(normalizedAssetId),
                assetId2: Value(normalizedAssetId2),
                sort: Value(sort),
                autoSave: Value(draft.autoSave),
                bookId: draft.bookId,
                excludeBudget: Value(
                  draft.type == RecordType.transfer
                      ? false
                      : draft.excludeBudget,
                ),
                excludeExIn: Value(
                  draft.type == RecordType.transfer ? false : draft.excludeExIn,
                ),
                createDate: _now(),
                tags: Value(encodedTags),
                exi: Value(extra.encode()),
              ),
            );
        return '$newId';
      } else {
        await (db.update(
          db.recordTemplates,
        )..where((t) => t.id.equals(old.id))).write(
          RecordTemplatesCompanion(
            type: Value(draft.type),
            remark: Value(cleanRemark.isEmpty ? null : cleanRemark),
            moneyMinor: Value(draft.money.storageMinor),
            feeMinor: Value(feeMinor),
            recordCatId: Value(normalizedCatId),
            assetId: Value(normalizedAssetId),
            assetId2: Value(normalizedAssetId2),
            autoSave: Value(draft.autoSave),
            bookId: Value(draft.bookId),
            excludeBudget: Value(
              draft.type == RecordType.transfer ? false : draft.excludeBudget,
            ),
            excludeExIn: Value(
              draft.type == RecordType.transfer ? false : draft.excludeExIn,
            ),
            tags: Value(encodedTags),
            exi: Value(extra.encode()),
          ),
        );
        return '${old.id}';
      }
    },
    int.parse,
  );

  /// Toggles `auto_save` on an existing template, verifying instant-save
  /// readiness when enabling `autoSave = true`.
  Future<void> setTemplateAutoSave({
    required String commandId,
    required int templateId,
    required bool autoSave,
  }) => _command(
    commandId,
    <Object?>['template-set-autosave-v1', templateId, autoSave],
    () async {
      final row = await _requireTemplate(templateId);
      if (autoSave) {
        await _validateTemplateForInstantSave(row);
      }
      await (db.update(db.recordTemplates)..where((t) => t.id.equals(row.id)))
          .write(RecordTemplatesCompanion(autoSave: Value(autoSave)));
      return '${row.id}';
    },
    (_) {},
  );

  /// Updates `sort` order for the provided template IDs.
  Future<void> reorderTemplates({
    required String commandId,
    required List<int> orderedIds,
  }) => _command(
    commandId,
    <Object?>['template-reorder-v1', orderedIds],
    () async {
      for (var i = 0; i < orderedIds.length; i++) {
        await (db.update(db.recordTemplates)
              ..where((t) => t.id.equals(orderedIds[i])))
            .write(RecordTemplatesCompanion(sort: Value(i + 1)));
      }
      return '${orderedIds.length}';
    },
    (_) {},
  );

  /// Deletes a `RecordTemplate` row. Existing generated bills are untouched.
  Future<void> deleteTemplate({
    required String commandId,
    required int templateId,
  }) => _command(
    commandId,
    <Object?>['template-delete-v1', templateId],
    () async {
      await _requireTemplate(templateId);
      await (db.delete(
        db.recordTemplates,
      )..where((t) => t.id.equals(templateId))).go();
      return '$templateId';
    },
    (_) {},
  );

  /// Directly books a bill from `[templateId]` via `LedgerService(db).saveRecord`,
  /// strictly validating that the linked book, category, and account(s) exist
  /// and are active (`R3` / `SAFE-TM-01`).
  Future<String> applyTemplateInstant({
    required String commandId,
    required int templateId,
    int? recordTimeMs,
  }) => _command(
    commandId,
    <Object?>['template-apply-instant-v1', templateId, recordTimeMs],
    () async {
      final row = await _requireTemplate(templateId);
      final validated = await _validateTemplateForInstantSave(row);
      final timeMs = recordTimeMs ?? _now();

      final extra = RecordExtra();
      final templateExtra = TemplateExtra.parse(row.exi);
      final rawMoney = Money.minor(row.moneyMinor);
      var bookedMoney = rawMoney;

      if (row.type == RecordType.transfer) {
        final sc =
            normalizeCurrency(validated.fromAsset!.currency) ?? baseCurrency;
        final ac =
            normalizeCurrency(validated.toAsset!.currency) ?? baseCurrency;
        if (sc != ac) {
          final rates = await _loadRateTable();
          final targetMinor = rates.convert(row.moneyMinor, sc, ac);
          if (targetMinor <= BigInt.zero) {
            throw const Failure(FailureCode.validation, '跨币种折算金额须大于 0');
          }
          extra.currency = billSnapshot(
            source: sc,
            sourceMinor: row.moneyMinor,
            account: ac,
            assetMinor: targetMinor,
            rates: rates,
          );
        } else if (sc != baseCurrency) {
          final rates = await _loadRateTable();
          extra.currency = billSnapshot(
            source: sc,
            sourceMinor: row.moneyMinor,
            account: ac,
            assetMinor: row.moneyMinor,
            rates: rates,
          );
        }
      } else {
        final ac = validated.fundingAsset == null
            ? baseCurrency
            : (normalizeCurrency(validated.fundingAsset!.currency) ??
                  baseCurrency);
        final sc = templateExtra.sourceCurrency ?? ac;
        if (sc != ac) {
          final rates = await _loadRateTable();
          final targetMinor = rates.convert(row.moneyMinor, sc, ac);
          if (!rawMoney.isZero && targetMinor <= BigInt.zero) {
            throw const Failure(FailureCode.validation, '外币折算金额须大于 0');
          }
          bookedMoney = Money.minor(targetMinor);
          extra.currency = billSnapshot(
            source: sc,
            sourceMinor: row.moneyMinor,
            account: ac,
            assetMinor: targetMinor,
            rates: rates,
          );
        } else if (sc != baseCurrency) {
          final rates = await _loadRateTable();
          extra.currency = billSnapshot(
            source: sc,
            sourceMinor: row.moneyMinor,
            account: ac,
            assetMinor: row.moneyMinor,
            rates: rates,
          );
        }
      }

      final liveTags = await (db.select(
        db.tags,
      )..where((t) => t.hidden.equals(false) & t.parent.isNotValue(1))).get();
      final validTagSet = <String>{for (final t in liveTags) t.tagId};
      final activeTagIds = <String>[
        for (final id in parseTemplateTagsCsv(row.tags))
          if (validTagSet.contains(id)) id,
      ];

      final draft = RecordDraft(
        type: row.type,
        money: bookedMoney,
        bookId: row.bookId,
        recordTime: timeMs,
        categoryId: row.type == RecordType.transfer
            ? noRef
            : validated.category!.id,
        assetId:
            (row.type == RecordType.transfer ||
                row.type == RecordType.reimbursable)
            ? noRef
            : row.assetId,
        fromAssetId: row.type == RecordType.transfer
            ? row.assetId
            : (row.type == RecordType.reimbursable ? row.assetId : noRef),
        toAssetId: row.type == RecordType.transfer ? row.assetId2 : noRef,
        remark: (row.remark ?? '').trim(),
        excludeBudget: row.type == RecordType.transfer
            ? false
            : row.excludeBudget,
        excludeExIn: row.type == RecordType.transfer ? false : row.excludeExIn,
        extra: extra,
        fee: row.type == RecordType.transfer && row.feeMinor > BigInt.zero
            ? Money.minor(row.feeMinor)
            : null,
        feeFromTarget:
            row.type == RecordType.transfer && templateExtra.feeFromTarget,
        tagIds: activeTagIds,
      );

      final childCommandId = sha256
          .convert(utf8.encode('template-instant-ledger:$commandId'))
          .toString();
      return LedgerService(
        db,
      ).saveRecord(commandId: childCommandId, draft: draft);
    },
    (recordId) => recordId,
  );

  // ---- Frequent Remarks Queries & Commands (F-016 R4) ----

  /// Watches remarks matching `recordCatId == catId` or `-1` (`noRef`),
  /// ordered by `usedTimes DESC, id DESC`.
  Stream<List<Remark>> watchRemarksForCategory(int catId) =>
      (db.select(db.remarks)
            ..where(
              (r) => r.recordCatId.equals(catId) | r.recordCatId.equals(noRef),
            )
            ..orderBy([
              (r) => OrderingTerm.desc(r.usedTimes),
              (r) => OrderingTerm.desc(r.id),
            ]))
          .watch();

  Future<List<Remark>> getRemarksForCategory(int catId) => guardDatabase(
    () =>
        (db.select(db.remarks)
              ..where(
                (r) =>
                    r.recordCatId.equals(catId) | r.recordCatId.equals(noRef),
              )
              ..orderBy([
                (r) => OrderingTerm.desc(r.usedTimes),
                (r) => OrderingTerm.desc(r.id),
              ]))
            .get(),
  );

  /// Watches all remarks for management (`categoryId == null` returns all;
  /// `-1` returns global remarks; `> 0` returns remarks for that category).
  Stream<List<Remark>> watchAllRemarks({int? categoryId}) {
    final q = db.select(db.remarks);
    if (categoryId != null) {
      q.where((r) => r.recordCatId.equals(categoryId));
    }
    q.orderBy([
      (r) => OrderingTerm.desc(r.usedTimes),
      (r) => OrderingTerm.desc(r.id),
    ]);
    return q.watch();
  }

  Future<List<Remark>> getAllRemarks({int? categoryId}) {
    final q = db.select(db.remarks);
    if (categoryId != null) {
      q.where((r) => r.recordCatId.equals(categoryId));
    }
    q.orderBy([
      (r) => OrderingTerm.desc(r.usedTimes),
      (r) => OrderingTerm.desc(r.id),
    ]);
    return guardDatabase(q.get);
  }

  /// Records usage of `[content]` under `[recordCatId]`: increments `usedTimes`
  /// if `(recordCatId, trimmedContent)` already exists, or inserts with
  /// `usedTimes = 1`. Blank content is a safe no-op returning `noRef` (`-1`).
  Future<int> recordRemarkUsage({
    required String commandId,
    required int recordCatId,
    required String content,
  }) => _command(
    commandId,
    <Object?>['remark-usage-v1', recordCatId, content],
    () async {
      final trimmed = normalizeRemarkContent(content, allowEmpty: true);
      if (trimmed.isEmpty) return '$noRef';

      final existing =
          await (db.select(db.remarks)
                ..where(
                  (r) =>
                      r.recordCatId.equals(recordCatId) &
                      r.content.equals(trimmed),
                )
                ..orderBy([(r) => OrderingTerm.desc(r.id)])
                ..limit(1))
              .getSingleOrNull();

      if (existing != null) {
        await (db.update(db.remarks)..where((r) => r.id.equals(existing.id)))
            .write(RemarksCompanion(usedTimes: Value(existing.usedTimes + 1)));
        return '${existing.id}';
      }

      final insertedId = await db
          .into(db.remarks)
          .insert(
            RemarksCompanion.insert(
              content: trimmed,
              recordCatId: recordCatId,
              usedTimes: const Value(1),
            ),
          );
      return '$insertedId';
    },
    int.parse,
  );

  /// Creates a frequent remark in `RemarksPage`.
  Future<int> createRemark({
    required String commandId,
    required String content,
    int recordCatId = noRef,
    int usedTimes = 0,
  }) => _command(
    commandId,
    <Object?>['remark-create-v1', content, recordCatId, usedTimes],
    () async {
      final trimmed = normalizeRemarkContent(content);
      if (usedTimes < 0) {
        throw const Failure(FailureCode.validation, '使用次数不能为负数');
      }
      await _validateRemarkCategory(recordCatId);

      final duplicate =
          await (db.select(db.remarks)
                ..where(
                  (r) =>
                      r.recordCatId.equals(recordCatId) &
                      r.content.equals(trimmed),
                )
                ..limit(1))
              .getSingleOrNull();
      if (duplicate != null) {
        throw const Failure(FailureCode.validation, '该分类下已存在相同常用备注');
      }

      final id = await db
          .into(db.remarks)
          .insert(
            RemarksCompanion.insert(
              content: trimmed,
              recordCatId: recordCatId,
              usedTimes: Value(usedTimes),
            ),
          );
      return '$id';
    },
    int.parse,
  );

  /// Updates an existing frequent remark in `RemarksPage`.
  Future<void> updateRemark({
    required String commandId,
    required int id,
    required String content,
    required int recordCatId,
    int? usedTimes,
  }) => _command(
    commandId,
    <Object?>['remark-update-v1', id, content, recordCatId, usedTimes],
    () async {
      final old = await (db.select(
        db.remarks,
      )..where((r) => r.id.equals(id))).getSingleOrNull();
      if (old == null) {
        throw const Failure(FailureCode.conflict, '常用备注不存在或已删除');
      }
      final trimmed = normalizeRemarkContent(content);
      if (usedTimes != null && usedTimes < 0) {
        throw const Failure(FailureCode.validation, '使用次数不能为负数');
      }
      await _validateRemarkCategory(recordCatId);

      final duplicate =
          await (db.select(db.remarks)
                ..where(
                  (r) =>
                      r.id.isNotValue(id) &
                      r.recordCatId.equals(recordCatId) &
                      r.content.equals(trimmed),
                )
                ..limit(1))
              .getSingleOrNull();
      if (duplicate != null) {
        throw const Failure(FailureCode.validation, '该分类下已存在相同常用备注');
      }

      await (db.update(db.remarks)..where((r) => r.id.equals(id))).write(
        RemarksCompanion(
          content: Value(trimmed),
          recordCatId: Value(recordCatId),
          usedTimes: usedTimes == null
              ? const Value.absent()
              : Value(usedTimes),
        ),
      );
      return '$id';
    },
    (_) {},
  );

  /// Deletes a frequent remark.
  Future<void> deleteRemark({required String commandId, required int id}) =>
      _command(commandId, <Object?>['remark-delete-v1', id], () async {
        final old = await (db.select(
          db.remarks,
        )..where((r) => r.id.equals(id))).getSingleOrNull();
        if (old == null) {
          throw const Failure(FailureCode.conflict, '常用备注不存在或已删除');
        }
        await (db.delete(db.remarks)..where((r) => r.id.equals(id))).go();
        return '$id';
      }, (_) {});

  // ---- Validation Helpers ----

  Future<RecordTemplate> _requireTemplate(int id) async {
    final row = await (db.select(
      db.recordTemplates,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (row == null) {
      throw const Failure(FailureCode.conflict, '账单模板不存在或已删除');
    }
    return row;
  }

  Future<void> _validateRemarkCategory(int recordCatId) async {
    if (recordCatId == noRef) return;
    final cat = await (db.select(
      db.recordCategories,
    )..where((c) => c.id.equals(recordCatId))).getSingleOrNull();
    if (cat == null) {
      throw const Failure(FailureCode.validation, '所选分类不存在');
    }
  }

  Future<Asset> _requireUsableAsset(int assetId, String label) async {
    final asset = await (db.select(
      db.assets,
    )..where((a) => a.id.equals(assetId))).getSingleOrNull();
    if (asset == null) {
      throw Failure(FailureCode.validation, '模板关联的$label不存在');
    }
    if (asset.type == AssetType.debt) {
      throw Failure(FailureCode.validation, '不能选择借贷账户作为$label');
    }
    if (asset.status == AssetStatus.settled) {
      throw Failure(FailureCode.validation, '模板关联的$label已结清，请更换账户');
    }
    return asset;
  }

  Future<void> _validateDraft(TemplateDraft d) async {
    if (!isSupportedTemplateType(d.type)) {
      throw Failure(FailureCode.validation, '不支持的模板类型 ${d.type}');
    }
    if (d.money.scale != Money.ledgerScale) {
      throw const Failure(FailureCode.scaleMismatch, '金额须为两位小数');
    }
    if (d.money.isNegative) {
      throw const Failure(FailureCode.validation, '模板金额不能为负数');
    }
    if (d.money.storageMinor > maxTemplateAmountMinor) {
      throw const Failure(FailureCode.validation, '模板金额不能超过 88888888888.00');
    }
    if (d.remark.trim().length > 2000) {
      throw const Failure(FailureCode.validation, '模板备注过长');
    }
    final name = d.name?.trim() ?? '';
    if (name.length > maxTemplateNameLength) {
      throw const Failure(
        FailureCode.validation,
        '模板名称不能超过 $maxTemplateNameLength 字',
      );
    }

    final book = await (db.select(
      db.accountBooks,
    )..where((b) => b.id.equals(d.bookId))).getSingleOrNull();
    if (book == null) {
      throw const Failure(FailureCode.validation, '所属账本不存在');
    }

    if (d.type == RecordType.transfer) {
      if (d.fee != null) {
        if (d.fee!.scale != Money.ledgerScale) {
          throw const Failure(FailureCode.scaleMismatch, '手续费须为两位小数');
        }
        if (d.fee!.isNegative || d.fee!.storageMinor > maxTemplateAmountMinor) {
          throw const Failure(FailureCode.validation, '手续费金额无效');
        }
      }
      if (d.assetId != noRef) {
        await _requireUsableAsset(d.assetId, '转出账户');
      }
      if (d.assetId2 != noRef) {
        await _requireUsableAsset(d.assetId2, '转入账户');
      }
      if (d.assetId != noRef && d.assetId == d.assetId2) {
        throw const Failure(FailureCode.validation, '转出和转入账户不能相同');
      }
      if (d.autoSave) {
        if (d.money.units <= BigInt.zero) {
          throw const Failure(FailureCode.validation, '开启直接入账的转账模板金额须大于 0');
        }
        if (d.assetId == noRef || d.assetId2 == noRef) {
          throw const Failure(FailureCode.validation, '开启直接入账的转账模板须选择转出和转入账户');
        }
      }
    } else {
      final wantCatType = templateCategoryTypeFor(d.type)!;
      final catId = d.categoryId ?? noRef;
      if (catId != noRef) {
        final cat = await (db.select(
          db.recordCategories,
        )..where((c) => c.id.equals(catId))).getSingleOrNull();
        if (cat == null ||
            cat.isHide ||
            cat.accountBookId != d.bookId ||
            cat.type != wantCatType) {
          throw const Failure(FailureCode.validation, '请选择所属账本下的有效分类');
        }
      } else if (d.autoSave) {
        throw const Failure(FailureCode.validation, '开启直接入账的模板须绑定有效分类');
      }
      if (d.assetId != noRef) {
        await _requireUsableAsset(d.assetId, '账户');
      }
      if (d.autoSave &&
          templateRequiresPositiveAmount(d.type) &&
          d.money.units <= BigInt.zero) {
        throw const Failure(FailureCode.validation, '开启直接入账时该类型模板金额须大于 0');
      }
    }
  }

  Future<_ValidatedInstantEntities> _validateTemplateForInstantSave(
    RecordTemplate row,
  ) async {
    if (!isSupportedTemplateType(row.type)) {
      throw Failure(FailureCode.validation, '不支持的模板类型 ${row.type}');
    }
    if (row.moneyMinor.isNegative || row.moneyMinor > maxTemplateAmountMinor) {
      throw const Failure(FailureCode.validation, '模板金额无效');
    }
    if (templateRequiresPositiveAmount(row.type) &&
        row.moneyMinor <= BigInt.zero) {
      throw const Failure(FailureCode.validation, '该类型模板金额须大于 0 才能直接入账');
    }

    final book = await (db.select(
      db.accountBooks,
    )..where((b) => b.id.equals(row.bookId))).getSingleOrNull();
    if (book == null) {
      throw const Failure(FailureCode.validation, '模板关联的账本不存在');
    }

    if (row.type == RecordType.transfer) {
      if (row.feeMinor.isNegative || row.feeMinor > maxTemplateAmountMinor) {
        throw const Failure(FailureCode.validation, '模板手续费金额无效');
      }
      if (row.assetId == noRef) {
        throw const Failure(FailureCode.validation, '模板未设置转出账户');
      }
      if (row.assetId2 == noRef) {
        throw const Failure(FailureCode.validation, '模板未设置转入账户');
      }
      if (row.assetId == row.assetId2) {
        throw const Failure(FailureCode.validation, '转出和转入账户不能相同');
      }
      final from = await _requireUsableAsset(row.assetId, '转出账户');
      final to = await _requireUsableAsset(row.assetId2, '转入账户');
      return _ValidatedInstantEntities(fromAsset: from, toAsset: to);
    }

    final catId = row.recordCatId ?? noRef;
    if (catId == noRef) {
      throw const Failure(FailureCode.validation, '模板未绑定分类，无法直接入账');
    }
    final wantCatType = templateCategoryTypeFor(row.type)!;
    final cat = await (db.select(
      db.recordCategories,
    )..where((c) => c.id.equals(catId))).getSingleOrNull();
    if (cat == null ||
        cat.isHide ||
        cat.accountBookId != row.bookId ||
        cat.type != wantCatType) {
      throw const Failure(FailureCode.validation, '模板关联的分类不存在或不可用');
    }

    final funding = row.assetId == noRef
        ? null
        : await _requireUsableAsset(row.assetId, '账户');
    return _ValidatedInstantEntities(category: cat, fundingAsset: funding);
  }

  Future<RateTable> _loadRateTable() async {
    final rows = await db.select(db.currencies).get();
    return RateTable(<String, String>{
      for (final c in rows) c.code: c.rateToAnchor,
    });
  }

  TemplateSnapshot _snapshotOf(RecordTemplate r) => TemplateSnapshot(
    id: r.id,
    type: r.type,
    moneyMinor: r.moneyMinor,
    feeMinor: r.feeMinor,
    bookId: r.bookId,
    recordCatId: r.recordCatId,
    assetId: r.assetId,
    assetId2: r.assetId2,
    remark: r.remark,
    autoSave: r.autoSave,
    excludeBudget: r.excludeBudget,
    excludeExIn: r.excludeExIn,
    tags: r.tags,
    exi: r.exi,
  );
}

final class _ValidatedInstantEntities {
  const _ValidatedInstantEntities({
    this.category,
    this.fundingAsset,
    this.fromAsset,
    this.toAsset,
  });

  final RecordCategory? category;
  final Asset? fundingAsset;
  final Asset? fromAsset;
  final Asset? toAsset;
}
