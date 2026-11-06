import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/failure.dart';
import '../../core/money.dart';
import '../../domain/ledger/effects.dart';
import '../../domain/ledger/record_extra.dart';
import '../../domain/ledger/record_relations.dart';
import '../../domain/model/codes.dart';
import '../db/database.dart';
import '../db/failures.dart';

const _uuid = Uuid();

/// Everything the user entered for one bill. Amounts are 2-decimal [Money].
final class RecordDraft {
  RecordDraft({
    required this.type,
    this.subType = RecordDirection.none,
    required this.money,
    required this.bookId,
    required this.recordTime,
    this.categoryId = noRef,
    this.assetId = noRef,
    this.fromAssetId = noRef,
    this.toAssetId = noRef,
    this.remark = '',
    this.excludeBudget = false,
    this.excludeExIn = false,
    this.discount,
    RecordExtra? extra,
    RecordRelations? relations,
    this.fee,
    this.feeFromTarget = false,
    this.tagIds = const [],
  }) : extra = extra ?? RecordExtra(),
       relations = relations ?? RecordRelations();

  final int type;
  final int subType;

  /// Net amount in the asset currency (income/expense) or the source amount
  /// (transfer).
  final Money money;
  final int bookId;
  final int recordTime;
  final int categoryId;
  final int assetId;
  final int fromAssetId;
  final int toAssetId;
  final String remark;
  final bool excludeBudget;
  final bool excludeExIn;
  final Money? discount;
  final RecordExtra extra;
  final RecordRelations relations;

  /// Transfer fee; a separate type=12 child record is written when > 0.
  final Money? fee;
  final bool feeFromTarget;
  final List<String> tagIds;

  List<Object?> get payload => [
    type,
    subType,
    money.toJson(),
    bookId,
    recordTime,
    categoryId,
    assetId,
    fromAssetId,
    toAssetId,
    remark,
    excludeBudget,
    excludeExIn,
    discount?.toJson(),
    extra.encode(),
    relations.encode(),
    fee?.toJson(),
    feeFromTarget,
    tagIds,
  ];
}

EntryFacts factsOf(LedgerRecord r) => EntryFacts(
  type: r.type,
  subType: r.subType,
  moneyMinor: r.moneyMinor,
  assetId: r.assetId,
  fromAssetId: r.fromAssetId,
  toAssetId: r.toAssetId,
  currency: RecordExtra.parse(r.extraInfo).currency,
);

/// The single write boundary for bills and balances (ADR-009, ADR-012).
///
/// Every command runs in one transaction: idempotency check, record rows,
/// child rows, tag links and incremental balance deltas.
final class LedgerService {
  LedgerService(this.db);
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

  /// Creates ([recordId] null) or replaces a bill. Returns the record id.
  Future<String> saveRecord({
    required String commandId,
    String? recordId,
    required RecordDraft draft,
  }) => _command(
    commandId,
    ['save-record-v1', recordId, ...draft.payload],
    () async {
      await _validate(draft);
      final id = recordId ?? _uuid.v4();
      final old = recordId == null ? null : await _liveRecord(recordId);
      if (recordId == null &&
          await (db.select(
                db.records,
              )..where((t) => t.recordId.equals(id))).getSingleOrNull() !=
              null) {
        throw const Failure(FailureCode.conflict, '账单标识已存在');
      }
      final oldFee = old == null ? null : await _feeChild(old.recordId);

      var parentTime = draft.recordTime;
      int? feeTime;
      final hasFee =
          draft.type == RecordType.transfer &&
          draft.fee != null &&
          !draft.fee!.isZero;
      if (hasFee) {
        // Child at +1 ms; if that crosses midnight, parent moves to -1 ms (02o §2.2).
        final local = DateTime.fromMillisecondsSinceEpoch(parentTime);
        final next = DateTime.fromMillisecondsSinceEpoch(parentTime + 1);
        if (next.day != local.day) {
          feeTime = parentTime;
          parentTime -= 1;
        } else {
          feeTime = parentTime + 1;
        }
      }

      final relations = RecordRelations(draft.relations.raw);
      if (draft.type == RecordType.transfer) {
        relations.transferFee = hasFee
            ? TransferFeeLink(feeFromTarget: draft.feeFromTarget)
            : null;
      }

      final main = RecordsCompanion(
        recordId: Value(id),
        type: Value(draft.type),
        subType: Value(draft.subType),
        moneyMinor: Value(draft.money.storageMinor),
        remark: Value(draft.remark),
        recordTime: Value(parentTime),
        recordCatId: Value(draft.categoryId),
        assetId: Value(draft.assetId),
        fromAssetId: Value(draft.fromAssetId),
        toAssetId: Value(draft.toAssetId),
        accountBookId: Value(draft.bookId),
        excludeBudget: Value(draft.excludeBudget),
        excludeExIn: Value(draft.excludeExIn),
        discountMinor: Value(draft.discount?.storageMinor),
        extraInfo: Value(draft.extra.encode()),
        relInfo: Value(relations.encode()),
        createDate: Value(old?.createDate ?? _now()),
        platformId: Value(old?.platformId ?? noRef),
        periodId: Value(old?.periodId ?? noRef),
        installment: Value(old?.installment),
        images: Value(old?.images),
      );

      RecordsCompanion? feeRow;
      if (hasFee) {
        final payer = draft.feeFromTarget ? draft.toAssetId : draft.fromAssetId;
        final feeId = oldFee?.recordId ?? _uuid.v4();
        final feeRel = RecordRelations()
          ..transferFee = TransferFeeLink(
            feeFromTarget: draft.feeFromTarget,
            parentId: id,
          );
        feeRow = RecordsCompanion(
          recordId: Value(feeId),
          type: const Value(RecordType.fee),
          subType: const Value(RecordDirection.expense),
          moneyMinor: Value(draft.fee!.storageMinor),
          remark: Value(draft.remark),
          recordTime: Value(feeTime!),
          assetId: Value(payer),
          accountBookId: Value(draft.bookId),
          excludeBudget: Value(draft.excludeBudget),
          excludeExIn: Value(draft.excludeExIn),
          relInfo: Value(feeRel.encode()),
          createDate: Value(oldFee?.createDate ?? _now()),
        );
      }

      final before = [?old, ?oldFee].map(factsOf);
      final after = [
        _factsOfCompanion(main),
        if (feeRow != null) _factsOfCompanion(feeRow),
      ];
      await _applyNet(netEffects(before: before, after: after));
      await _touchAssets(after);

      await db.into(db.records).insertOnConflictUpdate(main);
      if (feeRow != null) {
        await db.into(db.records).insertOnConflictUpdate(feeRow);
      } else if (oldFee != null) {
        await (db.delete(
          db.records,
        )..where((t) => t.recordId.equals(oldFee.recordId))).go();
      }
      await _replaceTags(id, draft.tagIds);
      if (feeRow != null)
        await _replaceTags(feeRow.recordId.value, draft.tagIds);
      return id;
    },
    (id) => id,
  );

  /// Deletes a bill and its transfer-fee child, reversing balance effects.
  Future<void> deleteRecord({
    required String commandId,
    required String recordId,
  }) => _command(commandId, ['delete-record-v1', recordId], () async {
    final old = await _liveRecord(recordId);
    final fee = await _feeChild(recordId);
    final rows = [old, ?fee];
    await _applyNet(netEffects(before: rows.map(factsOf)));
    for (final r in rows) {
      await (db.delete(
        db.tagRecords,
      )..where((t) => t.recordId.equals(r.recordId))).go();
      await (db.delete(
        db.records,
      )..where((t) => t.recordId.equals(r.recordId))).go();
    }
    return recordId;
  }, (_) => true);

  /// Creates an account; its balance starts at [initial].
  Future<int> createAsset({
    required String commandId,
    required String name,
    required Money initial,
    int type = AssetType.normal,
    int subType = RecordDirection.none,
    String? currency,
    String? groupName,
    String? remark,
    bool countedInNetWorth = true,
  }) => _command(
    commandId,
    [
      'create-asset-v1',
      name,
      initial.toJson(),
      type,
      subType,
      currency,
      groupName,
      remark,
      countedInNetWorth,
    ],
    () async {
      final trimmed = name.trim();
      if (trimmed.isEmpty || trimmed.length > 50) {
        throw const Failure(FailureCode.validation, '账户名称须为 1–50 字');
      }
      final minSort = await db
          .customSelect('SELECT COALESCE(MIN(sort), 0) AS s FROM asset')
          .getSingle();
      final id = await db
          .into(db.assets)
          .insert(
            AssetsCompanion.insert(
              name: trimmed,
              balanceMinor: initial.storageMinor,
              initMoneyMinor: initial.storageMinor,
              type: type,
              subType: Value(subType),
              createDate: _now(),
              sort: Value(minSort.read<int>('s') - 1),
              currency: Value(currency),
              groupName: Value(groupName),
              remark: Value(remark),
              // Original flag: 1 = counted, inverted for type 4 (ledger-catalog §3).
              isEffectiveAsset: Value(
                type == AssetType.debt
                    ? (countedInNetWorth ? 0 : 1)
                    : (countedInNetWorth ? 1 : 0),
              ),
            ),
          );
      return '$id';
    },
    int.parse,
  );

  /// Sets an account to [target] by writing a type=4 balance-change record.
  Future<String?> adjustBalance({
    required String commandId,
    required int assetId,
    required Money target,
    required int bookId,
    String remark = '',
  }) => _command<String?>(
    commandId,
    ['adjust-balance-v1', assetId, target.toJson(), bookId, remark],
    () async {
      final asset = await _asset(assetId);
      final diff = target.storageMinor - asset.balanceMinor;
      if (diff == BigInt.zero) return '';
      final id = _uuid.v4();
      final row = RecordsCompanion(
        recordId: Value(id),
        type: const Value(RecordType.balanceAdjust),
        moneyMinor: Value(diff),
        remark: Value(remark),
        recordTime: Value(_now()),
        fromAssetId: Value(assetId),
        accountBookId: Value(bookId),
        createDate: Value(_now()),
      );
      await _applyNet(netEffects(after: [_factsOfCompanion(row)]));
      await db.into(db.records).insert(row);
      return id;
    },
    (id) => id.isEmpty ? null : id,
  );

  // ---- helpers ----

  EntryFacts _factsOfCompanion(RecordsCompanion c) => EntryFacts(
    type: c.type.value,
    subType: c.subType.present ? c.subType.value : RecordDirection.none,
    moneyMinor: c.moneyMinor.value,
    assetId: c.assetId.present ? c.assetId.value : noRef,
    fromAssetId: c.fromAssetId.present ? c.fromAssetId.value : noRef,
    toAssetId: c.toAssetId.present ? c.toAssetId.value : noRef,
    currency: c.extraInfo.present
        ? RecordExtra.parse(c.extraInfo.value).currency
        : null,
  );

  Future<void> _validate(RecordDraft d) async {
    if (d.money.scale != Money.ledgerScale) {
      throw const Failure(FailureCode.scaleMismatch, '金额须为两位小数');
    }
    if (d.remark.length > 2000) {
      throw const Failure(FailureCode.validation, '备注过长');
    }
    final book = await (db.select(
      db.accountBooks,
    )..where((t) => t.id.equals(d.bookId))).getSingleOrNull();
    if (book == null) throw const Failure(FailureCode.validation, '账本不存在');

    Future<void> needAsset(int id, String label) async {
      if (id == noRef) {
        throw Failure(FailureCode.validation, '请选择$label');
      }
      await _asset(id);
    }

    switch (d.type) {
      case RecordType.expense:
      case RecordType.income:
        if (d.money.isNegative) {
          throw const Failure(FailureCode.validation, '金额不能为负数');
        }
        final cat = await (db.select(
          db.recordCategories,
        )..where((t) => t.id.equals(d.categoryId))).getSingleOrNull();
        if (cat == null ||
            cat.type != d.type ||
            cat.accountBookId != d.bookId) {
          throw const Failure(FailureCode.validation, '请选择当前账本的分类');
        }
        // Original allows bills without an account (asset_id = -1).
        if (d.assetId != noRef) await _asset(d.assetId);
        if (d.discount != null && d.discount!.isNegative) {
          throw const Failure(FailureCode.validation, '优惠金额无效');
        }
      case RecordType.transfer:
        if (d.money.units <= BigInt.zero) {
          throw const Failure(FailureCode.validation, '转账金额须大于 0');
        }
        await needAsset(d.fromAssetId, '转出账户');
        await needAsset(d.toAssetId, '转入账户');
        if (d.fromAssetId == d.toAssetId) {
          throw const Failure(FailureCode.validation, '转出和转入账户不能相同');
        }
        if (d.fee != null && d.fee!.isNegative) {
          throw const Failure(FailureCode.validation, '手续费不能为负数');
        }
      default:
        throw Failure(
          FailureCode.unsupportedCapability,
          '${RecordType.names[d.type] ?? d.type} 尚未开放',
        );
    }
  }

  Future<Asset> _asset(int id) async {
    final asset = await (db.select(
      db.assets,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (asset == null) throw const Failure(FailureCode.validation, '账户不存在');
    return asset;
  }

  Future<LedgerRecord> _liveRecord(String id) async {
    final r = await (db.select(
      db.records,
    )..where((t) => t.recordId.equals(id))).getSingleOrNull();
    if (r == null) throw const Failure(FailureCode.conflict, '账单不存在或已删除');
    return r;
  }

  Future<LedgerRecord?> _feeChild(String parentId) async {
    final rows = await db
        .customSelect(
          "SELECT record_id FROM record WHERE type = ? "
          "AND json_extract(rel_info, '\$.ltfeei.tfobid') = ?",
          variables: [
            Variable.withInt(RecordType.fee),
            Variable.withString(parentId),
          ],
        )
        .get();
    if (rows.isEmpty) return null;
    return _liveRecord(rows.first.read<String>('record_id'));
  }

  Future<void> _applyNet(Map<int, BigInt> net) async {
    for (final entry in net.entries) {
      final asset = await _asset(entry.key);
      final balance = Money.minor(asset.balanceMinor + entry.value);
      await (db.update(db.assets)..where((t) => t.id.equals(entry.key))).write(
        AssetsCompanion(balanceMinor: Value(balance.storageMinor)),
      );
    }
  }

  Future<void> _touchAssets(Iterable<EntryFacts> facts) async {
    final ids = <int>{
      for (final f in facts)
        for (final id in [f.assetId, f.fromAssetId, f.toAssetId])
          if (id != noRef) id,
    };
    for (final id in ids) {
      await db.customUpdate(
        'UPDATE asset SET used_times = used_times + 1 WHERE id = ?',
        variables: [Variable.withInt(id)],
        updates: {db.assets},
      );
    }
  }

  Future<void> _replaceTags(String recordId, List<String> tagIds) async {
    await (db.delete(
      db.tagRecords,
    )..where((t) => t.recordId.equals(recordId))).go();
    for (final tag in tagIds.toSet()) {
      await db
          .into(db.tagRecords)
          .insert(TagRecordsCompanion.insert(tagId: tag, recordId: recordId));
    }
  }
}
