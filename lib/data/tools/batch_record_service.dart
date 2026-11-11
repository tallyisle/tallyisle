import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../../core/failure.dart';
import '../../core/money.dart';
import '../../domain/ledger/effects.dart';
import '../../domain/ledger/record_extra.dart';
import '../../domain/ledger/record_relations.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/asset_overview.dart' show RateTable;
import '../../domain/rules/batch_edit_rules.dart';
import '../../domain/rules/debt_rules.dart'
    show DebtRecordEntry, LoanInfo, recomputeDebtPrincipal;
import '../db/database.dart';
import '../db/failures.dart';
import '../ledger/ledger_service.dart' show factsOf;

export '../../domain/rules/batch_edit_rules.dart';

final class BatchEditResult {
  const BatchEditResult({
    required this.updatedRecordCount,
    required this.updatedChildCount,
    required this.createdTargetCategoryCount,
  });

  final int updatedRecordCount;
  final int updatedChildCount;
  final int createdTargetCategoryCount;

  Map<String, Object> toJson() => {
    'updatedRecordCount': updatedRecordCount,
    'updatedChildCount': updatedChildCount,
    'createdTargetCategoryCount': createdTargetCategoryCount,
  };

  factory BatchEditResult.fromJson(Map<String, Object?> json) =>
      BatchEditResult(
        updatedRecordCount: (json['updatedRecordCount'] as int?) ?? 0,
        updatedChildCount: (json['updatedChildCount'] as int?) ?? 0,
        createdTargetCategoryCount:
            (json['createdTargetCategoryCount'] as int?) ?? 0,
      );
}

final class BatchDeleteResult {
  const BatchDeleteResult({
    required this.deletedPrimaryCount,
    required this.deletedTotalRowCount,
  });

  final int deletedPrimaryCount;
  final int deletedTotalRowCount;

  Map<String, Object> toJson() => {
    'deletedPrimaryCount': deletedPrimaryCount,
    'deletedTotalRowCount': deletedTotalRowCount,
  };

  factory BatchDeleteResult.fromJson(Map<String, Object?> json) =>
      BatchDeleteResult(
        deletedPrimaryCount: (json['deletedPrimaryCount'] as int?) ?? 0,
        deletedTotalRowCount: (json['deletedTotalRowCount'] as int?) ?? 0,
      );
}

/// Atomic multi-select batch edit and batch delete service (F-025, ADR-009, ADR-012).
final class BatchRecordService {
  BatchRecordService(this.db);
  final AppDatabase db;

  int _now() => db.nowMs();

  Future<T> _command<T>(
    String commandId,
    List<Object?> payload,
    Future<Map<String, Object>> Function() body,
    T Function(Map<String, Object?> json) decode,
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
          final raw = jsonDecode(previous.resultId) as Map<String, Object?>;
          return decode(raw);
        }
        final out = await body();
        await db
            .into(db.writeCommands)
            .insert(
              WriteCommandsCompanion.insert(
                commandId: commandId,
                payloadHash: hash,
                resultId: jsonEncode(out),
                committedAt: _now(),
              ),
            );
        return decode(out);
      }),
    );
  }

  static List<String> _dedupeRecordIds(Iterable<String> rawIds) {
    final seen = <String>{};
    final out = <String>[];
    for (final raw in rawIds) {
      final id = raw.trim();
      if (id.isNotEmpty && seen.add(id)) {
        out.add(id);
      }
    }
    return out;
  }

  /// Atomically edits all [recordIds] according to [patch] in one transaction (R1..R3).
  Future<BatchEditResult> batchEdit({
    required String commandId,
    required Iterable<String> recordIds,
    required BatchEditPatch patch,
  }) {
    final ids = _dedupeRecordIds(recordIds);
    return _command(
      commandId,
      ['batch-edit-records-v1', ids, patch.toPayloadJson()],
      () async {
        if (ids.isEmpty) {
          throw const Failure(FailureCode.validation, '请至少选择一笔账单');
        }
        if (!patch.hasChanges) {
          throw const Failure(FailureCode.validation, '请至少选择一项要修改的内容');
        }

        // Load all selected records and enforce R1 guards.
        final records = <LedgerRecord>[];
        final relationsById = <String, RecordRelations>{};
        final extraById = <String, RecordExtra>{};
        for (final id in ids) {
          final r = await (db.select(
            db.records,
          )..where((t) => t.recordId.equals(id))).getSingleOrNull();
          if (r == null) {
            throw const Failure(FailureCode.conflict, '部分选中账单不存在或已被删除');
          }
          final rel = RecordRelations.parse(r.relInfo);
          final extra = RecordExtra.parse(r.extraInfo);
          validateRecordEditableInBatch(
            type: r.type,
            relations: rel,
            extra: extra,
          );
          records.add(r);
          relationsById[r.recordId] = rel;
          extraById[r.recordId] = extra;
        }

        // Validate target book if requested.
        if (patch.targetBookId != null) {
          final book = await (db.select(
            db.accountBooks,
          )..where((t) => t.id.equals(patch.targetBookId!))).getSingleOrNull();
          if (book == null) {
            throw const Failure(FailureCode.validation, '目标账本不存在');
          }
        }

        // Validate target category if requested.
        RecordCategory? explicitTargetCat;
        if (patch.targetCategoryId != null) {
          explicitTargetCat =
              await (db.select(db.recordCategories)
                    ..where((t) => t.id.equals(patch.targetCategoryId!)))
                  .getSingleOrNull();
          if (explicitTargetCat == null) {
            throw const Failure(FailureCode.validation, '目标分类不存在');
          }
          for (final r in records) {
            final requiredCatType = requiredCategoryTypeForRecord(r.type);
            if (requiredCatType == null) {
              throw const Failure(
                FailureCode.validation,
                '转账、借贷、手续费或平账记录不支持修改分类',
              );
            }
            if (requiredCatType != explicitTargetCat.type) {
              throw const Failure(FailureCode.validation, '所选账单收支方向与目标分类类型不匹配');
            }
            final effectiveBookId = patch.targetBookId ?? r.accountBookId;
            if (explicitTargetCat.accountBookId != effectiveBookId) {
              throw const Failure(FailureCode.validation, '目标分类不属于账单所在的目标账本');
            }
          }
        }

        // Validate target asset & multi-currency compatibility if requested.
        Asset? targetAsset;
        final assetCache = <int, Asset>{};
        Future<Asset?> loadAssetOptional(int id) async {
          if (id == noRef || id < 0) return null;
          if (assetCache.containsKey(id)) return assetCache[id];
          final found = await (db.select(
            db.assets,
          )..where((t) => t.id.equals(id))).getSingleOrNull();
          if (found != null) assetCache[id] = found;
          return found;
        }

        if (patch.targetAssetId != null) {
          if (patch.targetAssetId != noRef) {
            targetAsset = await loadAssetOptional(patch.targetAssetId!);
            if (targetAsset == null) {
              throw const Failure(FailureCode.validation, '目标账户不存在');
            }
            if (targetAsset.type == AssetType.debt) {
              throw const Failure(FailureCode.validation, '不能选择借贷账户作为普通资金账户');
            }
          }
          for (final r in records) {
            final rel = relationsById[r.recordId]!;
            final slot = batchEditableAssetSlot(type: r.type, relations: rel);
            if (slot == BatchAssetSlot.unsupported) {
              throw const Failure(
                FailureCode.validation,
                '转账、借贷或特殊记录不支持批量修改账户',
              );
            }
            final oldAssetId = slot == BatchAssetSlot.fromAssetColumn
                ? r.fromAssetId
                : r.assetId;
            final oldAsset = await loadAssetOptional(oldAssetId);
            validateBatchAssetCurrencyCompatibility(
              oldAssetId: oldAssetId,
              oldAssetCurrency: oldAsset?.currency,
              targetAssetId: patch.targetAssetId!,
              targetAssetCurrency: targetAsset?.currency,
              recordCurrency: extraById[r.recordId]!.currency,
            );
          }
        }

        // Validate added tags exist in `tag` table.
        if (patch.addTagIds.isNotEmpty) {
          final existingTags = await (db.select(
            db.tags,
          )..where((t) => t.tagId.isIn(patch.addTagIds))).get();
          if (existingTags.length != patch.addTagIds.length) {
            throw const Failure(FailureCode.validation, '部分待添加的标签不存在');
          }
        }

        // Prepare cross-book category resolver cache when moving to `targetBookId`
        // without an explicit `targetCategoryId` so zero cross-book orphan categories occur.
        final catByIdCache = <int, RecordCategory?>{};
        Future<RecordCategory?> loadCatOptional(int catId) async {
          if (catId == noRef || catId < 0) return null;
          if (catByIdCache.containsKey(catId)) return catByIdCache[catId];
          final row = await (db.select(
            db.recordCategories,
          )..where((t) => t.id.equals(catId))).getSingleOrNull();
          catByIdCache[catId] = row;
          return row;
        }

        List<RecordCategory>? targetBookCats;
        var createdTargetCategoryCount = 0;
        if (patch.targetBookId != null && explicitTargetCat == null) {
          targetBookCats = await (db.select(
            db.recordCategories,
          )..where((t) => t.accountBookId.equals(patch.targetBookId!))).get();
          for (final c in targetBookCats) {
            catByIdCache[c.id] = c;
          }
        }

        Future<int> resolveCrossBookCategory(LedgerRecord r) async {
          if (explicitTargetCat != null) return explicitTargetCat.id;
          final targetBookId = patch.targetBookId;
          if (targetBookId == null || r.accountBookId == targetBookId) {
            return r.recordCatId;
          }
          if (r.recordCatId == noRef || r.recordCatId < 0) {
            return noRef;
          }
          final oldCat = await loadCatOptional(r.recordCatId);
          if (oldCat == null) return noRef;
          if (oldCat.accountBookId == targetBookId) return oldCat.id;

          final cats = targetBookCats!;
          int nextSort({required int parentCatId, required int type}) {
            var maxSort = -1;
            for (final c in cats) {
              if (c.parentCatId == parentCatId &&
                  c.type == type &&
                  c.sort > maxSort) {
                maxSort = c.sort;
              }
            }
            return maxSort + 1;
          }

          Future<RecordCategory> findOrCreateTop(RecordCategory srcTop) async {
            final nameKey = srcTop.name.trim();
            final match = cats
                .where(
                  (c) =>
                      c.parentCatId == -1 &&
                      c.type == srcTop.type &&
                      c.name.trim() == nameKey,
                )
                .firstOrNull;
            if (match != null) return match;
            if (!patch.createMissingTargetCategories) {
              throw Failure(
                FailureCode.validation,
                '目标账本不存在同名分类“$nameKey”，请同时指定目标分类或先复制分类',
              );
            }
            final sort = nextSort(parentCatId: -1, type: srcTop.type);
            final newId = await db
                .into(db.recordCategories)
                .insert(
                  RecordCategoriesCompanion.insert(
                    name: nameKey,
                    icon: Value(srcTop.icon),
                    type: srcTop.type,
                    sort: Value(sort),
                    parentCatId: const Value(-1),
                    colorFill: Value(srcTop.colorFill),
                    accountBookId: targetBookId,
                    isHide: Value(srcTop.isHide),
                    extraInfo: Value(srcTop.extraInfo),
                  ),
                );
            createdTargetCategoryCount++;
            final created = RecordCategory(
              id: newId,
              name: nameKey,
              icon: srcTop.icon,
              type: srcTop.type,
              sort: sort,
              parentCatId: -1,
              colorFill: srcTop.colorFill,
              platformId: -1,
              accountBookId: targetBookId,
              isHide: srcTop.isHide,
              extraInfo: srcTop.extraInfo,
            );
            cats.add(created);
            catByIdCache[newId] = created;
            return created;
          }

          if (oldCat.parentCatId == -1) {
            final top = await findOrCreateTop(oldCat);
            return top.id;
          }

          final oldParent = await loadCatOptional(oldCat.parentCatId);
          if (oldParent == null) {
            final top = await findOrCreateTop(oldCat);
            return top.id;
          }
          final targetParent = await findOrCreateTop(oldParent);
          final subName = oldCat.name.trim();
          final existingSub = cats
              .where(
                (c) =>
                    c.parentCatId == targetParent.id &&
                    c.type == oldCat.type &&
                    c.name.trim() == subName,
              )
              .firstOrNull;
          if (existingSub != null) return existingSub.id;
          if (!patch.createMissingTargetCategories) {
            throw Failure(
              FailureCode.validation,
              '目标账本分类“${targetParent.name}”下不存在子分类“$subName”',
            );
          }
          final subSort = nextSort(
            parentCatId: targetParent.id,
            type: oldCat.type,
          );
          final newSubId = await db
              .into(db.recordCategories)
              .insert(
                RecordCategoriesCompanion.insert(
                  name: subName,
                  icon: Value(oldCat.icon),
                  type: oldCat.type,
                  sort: Value(subSort),
                  parentCatId: Value(targetParent.id),
                  colorFill: Value(oldCat.colorFill),
                  accountBookId: targetBookId,
                  isHide: Value(oldCat.isHide),
                  extraInfo: Value(oldCat.extraInfo),
                ),
              );
          createdTargetCategoryCount++;
          final createdSub = RecordCategory(
            id: newSubId,
            name: subName,
            icon: oldCat.icon,
            type: oldCat.type,
            sort: subSort,
            parentCatId: targetParent.id,
            colorFill: oldCat.colorFill,
            platformId: -1,
            accountBookId: targetBookId,
            isHide: oldCat.isHide,
            extraInfo: oldCat.extraInfo,
          );
          cats.add(createdSub);
          catByIdCache[newSubId] = createdSub;
          return newSubId;
        }

        final beforeFacts = <EntryFacts>[];
        final afterFacts = <EntryFacts>[];
        final newlyTouchedAssetIds = <int>{};
        final shiftedDebtRows = <LedgerRecord>[];
        var updatedChildCount = 0;

        for (final r in records) {
          final rel = relationsById[r.recordId]!;
          final extra = extraById[r.recordId]!;
          final feeChild = r.type == RecordType.transfer
              ? await _feeChild(r.recordId)
              : null;

          final nextBookId = patch.targetBookId ?? r.accountBookId;
          final nextCatId = await resolveCrossBookCategory(r);

          var nextAssetId = r.assetId;
          var nextFromAssetId = r.fromAssetId;
          if (patch.targetAssetId != null) {
            final slot = batchEditableAssetSlot(type: r.type, relations: rel);
            if (slot == BatchAssetSlot.fromAssetColumn) {
              if (nextFromAssetId != patch.targetAssetId &&
                  patch.targetAssetId != noRef) {
                newlyTouchedAssetIds.add(patch.targetAssetId!);
              }
              nextFromAssetId = patch.targetAssetId!;
            } else {
              if (nextAssetId != patch.targetAssetId &&
                  patch.targetAssetId != noRef) {
                newlyTouchedAssetIds.add(patch.targetAssetId!);
              }
              nextAssetId = patch.targetAssetId!;
            }
          }

          var nextTime = r.recordTime;
          var nextFeeTime = feeChild?.recordTime;
          if (patch.shiftToDate != null) {
            final shifted = shiftRecordDatePreservingClock(
              originalTimeMs: r.recordTime,
              targetDate: patch.shiftToDate!,
              hasTransferFee: feeChild != null,
            );
            nextTime = shifted.parentTimeMs;
            nextFeeTime = shifted.feeTimeMs;
          }

          final nextExcludeBudget = patch.excludeBudget ?? r.excludeBudget;
          final nextExcludeExIn = patch.excludeExIn ?? r.excludeExIn;

          if (nextAssetId != r.assetId || nextFromAssetId != r.fromAssetId) {
            beforeFacts.add(factsOf(r));
            afterFacts.add(
              EntryFacts(
                type: r.type,
                subType: r.subType,
                moneyMinor: r.moneyMinor,
                assetId: nextAssetId,
                fromAssetId: nextFromAssetId,
                toAssetId: r.toAssetId,
                currency: extra.currency,
              ),
            );
          }

          await (db.update(
            db.records,
          )..where((t) => t.recordId.equals(r.recordId))).write(
            RecordsCompanion(
              recordCatId: Value(nextCatId),
              assetId: Value(nextAssetId),
              fromAssetId: Value(nextFromAssetId),
              accountBookId: Value(nextBookId),
              recordTime: Value(nextTime),
              excludeBudget: Value(nextExcludeBudget),
              excludeExIn: Value(nextExcludeExIn),
            ),
          );

          if (patch.shiftToDate != null &&
              const {
                RecordType.borrowIn,
                RecordType.lendOut,
                RecordType.repay,
                RecordType.collect,
              }.contains(r.type)) {
            shiftedDebtRows.add(r);
          }

          // Update transfer-fee child (`type == 12`) if present.
          if (feeChild != null) {
            final childChanged =
                feeChild.accountBookId != nextBookId ||
                (nextFeeTime != null && feeChild.recordTime != nextFeeTime) ||
                feeChild.excludeBudget != nextExcludeBudget ||
                feeChild.excludeExIn != nextExcludeExIn;
            if (childChanged) {
              await (db.update(
                db.records,
              )..where((t) => t.recordId.equals(feeChild.recordId))).write(
                RecordsCompanion(
                  accountBookId: Value(nextBookId),
                  recordTime: Value(nextFeeTime ?? feeChild.recordTime),
                  excludeBudget: Value(nextExcludeBudget),
                  excludeExIn: Value(nextExcludeExIn),
                ),
              );
              updatedChildCount++;
            }
          }

          // Sync linked refund children (book, category, exclusion flags).
          for (final refundLink
              in rel.refunds?.children ?? const <LinkedBill>[]) {
            final childRow =
                await (db.select(db.records)
                      ..where((t) => t.recordId.equals(refundLink.billId)))
                    .getSingleOrNull();
            if (childRow == null) continue;
            final childChanged =
                childRow.accountBookId != nextBookId ||
                childRow.recordCatId != nextCatId ||
                childRow.excludeBudget != nextExcludeBudget ||
                childRow.excludeExIn != nextExcludeExIn;
            if (childChanged) {
              await (db.update(
                db.records,
              )..where((t) => t.recordId.equals(childRow.recordId))).write(
                RecordsCompanion(
                  accountBookId: Value(nextBookId),
                  recordCatId: Value(nextCatId),
                  excludeBudget: Value(nextExcludeBudget),
                  excludeExIn: Value(nextExcludeExIn),
                ),
              );
              updatedChildCount++;
            }
          }

          // Sync linked reimbursement receipt children (book + timestamp floor).
          for (final reimbLink
              in rel.reimbursements?.children ?? const <LinkedBill>[]) {
            final childRow =
                await (db.select(db.records)
                      ..where((t) => t.recordId.equals(reimbLink.billId)))
                    .getSingleOrNull();
            if (childRow == null) continue;
            final clampedTime = childRow.recordTime <= nextTime
                ? nextTime + 1
                : childRow.recordTime;
            if (childRow.accountBookId != nextBookId ||
                childRow.recordTime != clampedTime) {
              await (db.update(
                db.records,
              )..where((t) => t.recordId.equals(childRow.recordId))).write(
                RecordsCompanion(
                  accountBookId: Value(nextBookId),
                  recordTime: Value(clampedTime),
                ),
              );
              updatedChildCount++;
            }
          }

          // Update tags if requested.
          if (patch.addTagIds.isNotEmpty || patch.removeTagIds.isNotEmpty) {
            final curTagRows = await (db.select(
              db.tagRecords,
            )..where((t) => t.recordId.equals(r.recordId))).get();
            final nextTags = mergeBatchTags(
              existingTagIds: curTagRows.map((t) => t.tagId),
              addTagIds: patch.addTagIds,
              removeTagIds: patch.removeTagIds,
            );
            await _replaceTags(r.recordId, nextTags);
            if (feeChild != null) {
              await _replaceTags(feeChild.recordId, nextTags);
            }
          }
        }

        // Apply exact incremental net balance delta (`ADR-012`).
        await _applyNet(netEffects(before: beforeFacts, after: afterFacts));

        for (final assetId in newlyTouchedAssetIds) {
          await db.customUpdate(
            'UPDATE asset SET used_times = used_times + 1 WHERE id = ?',
            variables: [Variable.withInt(assetId)],
            updates: {db.assets},
          );
        }

        if (shiftedDebtRows.isNotEmpty) {
          await _recomputeAffectedDebts(shiftedDebtRows);
        }

        return BatchEditResult(
          updatedRecordCount: records.length,
          updatedChildCount: updatedChildCount,
          createdTargetCategoryCount: createdTargetCategoryCount,
        ).toJson();
      },
      BatchEditResult.fromJson,
    );
  }

  /// Atomically deletes [recordIds] plus any transfer-fee or refund/reimbursement
  /// children, unlinks surviving origins, reverses `netEffects`, and recomputes
  /// affected debt accounts (`type == 4`) in one transaction (R4).
  Future<BatchDeleteResult> batchDelete({
    required String commandId,
    required Iterable<String> recordIds,
  }) {
    final ids = _dedupeRecordIds(recordIds);
    return _command(commandId, ['batch-delete-records-v1', ids], () async {
      if (ids.isEmpty) {
        throw const Failure(FailureCode.validation, '请至少选择一笔账单');
      }

      final toDeleteById = <String, LedgerRecord>{};
      for (final id in ids) {
        final primary = await (db.select(
          db.records,
        )..where((t) => t.recordId.equals(id))).getSingleOrNull();
        if (primary == null) {
          throw const Failure(FailureCode.conflict, '部分选中账单不存在或已被删除');
        }
        toDeleteById[primary.recordId] = primary;

        final fee = await _feeChild(primary.recordId);
        if (fee != null) {
          toDeleteById[fee.recordId] = fee;
        }

        final rel = RecordRelations.parse(primary.relInfo);
        for (final childId in _childIds(rel)) {
          final child = await (db.select(
            db.records,
          )..where((t) => t.recordId.equals(childId))).getSingleOrNull();
          if (child != null) {
            toDeleteById[child.recordId] = child;
          }
        }
      }

      final allDeletedRows = toDeleteById.values.toList(growable: false);

      // Unlink deleted child records from any surviving origin/parent record.
      final unlinkedByOrigin = <String, Set<String>>{};
      final clearedTransferFeeParents = <String>{};
      for (final row in allDeletedRows) {
        final rel = RecordRelations.parse(row.relInfo);
        final originId = rel.refunds?.originId ?? rel.reimbursements?.originId;
        if (originId != null &&
            originId.trim().isNotEmpty &&
            !toDeleteById.containsKey(originId)) {
          unlinkedByOrigin
              .putIfAbsent(originId, () => <String>{})
              .add(row.recordId);
        }
        if (row.type == RecordType.fee) {
          final parentId = rel.transferFee?.parentId;
          if (parentId != null &&
              parentId.trim().isNotEmpty &&
              !toDeleteById.containsKey(parentId)) {
            clearedTransferFeeParents.add(parentId);
          }
        }
      }

      for (final entry in unlinkedByOrigin.entries) {
        final origin = await (db.select(
          db.records,
        )..where((t) => t.recordId.equals(entry.key))).getSingleOrNull();
        if (origin == null) continue;
        final removedChildIds = entry.value;
        final originRel = RecordRelations.parse(origin.relInfo);
        BillLinks? withoutRemoved(BillLinks? links) => links == null
            ? null
            : BillLinks(
                children: [
                  for (final c in links.children)
                    if (!removedChildIds.contains(c.billId)) c,
                ],
                originId: links.originId,
              );
        originRel.refunds = withoutRemoved(originRel.refunds);
        originRel.reimbursements = withoutRemoved(originRel.reimbursements);
        await (db.update(db.records)
              ..where((t) => t.recordId.equals(origin.recordId)))
            .write(RecordsCompanion(relInfo: Value(originRel.encode())));
      }

      for (final parentId in clearedTransferFeeParents) {
        final parent = await (db.select(
          db.records,
        )..where((t) => t.recordId.equals(parentId))).getSingleOrNull();
        if (parent == null) continue;
        final parentRel = RecordRelations.parse(parent.relInfo)
          ..transferFee = null;
        await (db.update(db.records)
              ..where((t) => t.recordId.equals(parent.recordId)))
            .write(RecordsCompanion(relInfo: Value(parentRel.encode())));
      }

      // Reverse exact balance effects across all unique rows being deleted.
      await _applyNet(netEffects(before: allDeletedRows.map(factsOf)));

      final deleteIds = toDeleteById.keys.toList(growable: false);
      await (db.delete(
        db.tagRecords,
      )..where((t) => t.recordId.isIn(deleteIds))).go();
      await (db.delete(
        db.records,
      )..where((t) => t.recordId.isIn(deleteIds))).go();

      await _recomputeAffectedDebts(allDeletedRows);

      return BatchDeleteResult(
        deletedPrimaryCount: ids.length,
        deletedTotalRowCount: allDeletedRows.length,
      ).toJson();
    }, BatchDeleteResult.fromJson);
  }

  Iterable<String> _childIds(RecordRelations rel) => [
    for (final c in rel.refunds?.children ?? const <LinkedBill>[]) c.billId,
    for (final c in rel.reimbursements?.children ?? const <LinkedBill>[])
      c.billId,
  ];

  Future<LedgerRecord?> _feeChild(String parentId) async {
    final rows = await db
        .customSelect(
          'SELECT * FROM record WHERE type = ? '
          "AND json_extract(rel_info, '\$.ltfeei.tfobid') = ?",
          variables: [
            Variable.withInt(RecordType.fee),
            Variable.withString(parentId),
          ],
          readsFrom: {db.records},
        )
        .get();
    if (rows.isEmpty) return null;
    return db.records.map(rows.first.data);
  }

  Future<void> _applyNet(Map<int, BigInt> net) async {
    for (final entry in net.entries) {
      final asset = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(entry.key))).getSingleOrNull();
      if (asset == null) {
        throw const Failure(FailureCode.validation, '关联账户不存在');
      }
      if (asset.type == AssetType.debt) continue;
      final balance = Money.minor(asset.balanceMinor + entry.value);
      await (db.update(db.assets)..where((t) => t.id.equals(entry.key))).write(
        AssetsCompanion(balanceMinor: Value(balance.storageMinor)),
      );
    }
  }

  Future<void> _replaceTags(String recordId, List<String> tagIds) async {
    await (db.delete(
      db.tagRecords,
    )..where((t) => t.recordId.equals(recordId))).go();
    for (final tagId in tagIds.toSet()) {
      await db
          .into(db.tagRecords)
          .insert(TagRecordsCompanion.insert(tagId: tagId, recordId: recordId));
    }
  }

  Future<void> _recomputeAffectedDebts(
    Iterable<LedgerRecord> touchedRows,
  ) async {
    const debtPrincipalTypes = {
      RecordType.borrowIn,
      RecordType.lendOut,
      RecordType.repay,
      RecordType.collect,
    };
    final candidateIds = <int>{
      for (final r in touchedRows)
        if (debtPrincipalTypes.contains(r.type)) ...[
          if (r.fromAssetId != noRef) r.fromAssetId,
          if (r.toAssetId != noRef) r.toAssetId,
        ],
    };
    if (candidateIds.isEmpty) return;

    final debtAssets = <Asset>[];
    for (final id in candidateIds) {
      final asset = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(id))).getSingleOrNull();
      if (asset != null && asset.type == AssetType.debt) {
        debtAssets.add(asset);
      }
    }
    if (debtAssets.isEmpty) return;

    final currencies = await db.select(db.currencies).get();
    final rates = RateTable({
      for (final c in currencies) c.code: c.rateToAnchor,
    });
    final now = _now();

    for (final debt in debtAssets) {
      final liveRows = await db
          .customSelect(
            'SELECT * FROM record '
            'WHERE (from_asset_id = ?1 OR to_asset_id = ?1) '
            'AND type IN (5, 6, 7, 8) '
            'ORDER BY record_time ASC, create_date ASC, record_id ASC',
            variables: [Variable.withInt(debt.id)],
          )
          .get();
      final entries = [
        for (final row in liveRows)
          _toDebtRecordEntry(db.records.map(row.data)),
      ];
      final currentInfo = LoanInfo.parse(debt.loanInfo);
      final result = recomputeDebtPrincipal(
        debtSubType: debt.subType,
        currentStatus: debt.status,
        currentLoanInfo: currentInfo,
        records: entries,
        debtCurrency: debt.currency,
        rates: rates,
        allowReopen: false,
        nowMs: now,
      );
      await (db.update(db.assets)..where((t) => t.id.equals(debt.id))).write(
        AssetsCompanion(
          balanceMinor: Value(result.balanceMinor),
          status: Value(result.status),
          loanInfo: Value(result.loanInfo.encode()),
        ),
      );
    }
  }

  DebtRecordEntry _toDebtRecordEntry(LedgerRecord r) => DebtRecordEntry(
    recordId: r.recordId,
    type: r.type,
    subType: r.subType,
    moneyMinor: r.moneyMinor,
    recordTime: r.recordTime,
    currency: RecordExtra.parse(r.extraInfo).currency,
  );
}
