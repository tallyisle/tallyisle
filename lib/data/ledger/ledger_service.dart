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
import '../../domain/rules/asset_overview.dart'
    show RateTable, normalizeCurrency;
import '../../domain/rules/debt_rules.dart'
    show DebtRecordEntry, LoanInfo, recomputeDebtPrincipal;
import '../../domain/rules/fixed_deposit.dart' show decodeFixedDepositList;
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
      if (old != null && _isLinkedChild(old)) {
        throw const Failure(FailureCode.validation, '这是退款/报销记录，请删除后在原账单上重新添加');
      }
      if (old != null &&
          (old.type == RecordType.advanceIncome ||
              old.type == RecordType.advanceExpense) &&
          RecordExtra.parse(old.extraInfo).advance != null) {
        throw const Failure(FailureCode.validation, '已结算的预收/预支不能再编辑');
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
      if (old != null) {
        // Child links are owned by addRefund/addReimbursement, never by the form.
        final oldRel = RecordRelations.parse(old.relInfo);
        relations.refunds = oldRel.refunds;
        relations.reimbursements = oldRel.reimbursements;
      } else {
        relations.refunds = null;
        relations.reimbursements = null;
      }
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
      if (feeRow != null) {
        await _replaceTags(feeRow.recordId.value, draft.tagIds);
      }
      if (old != null && old.accountBookId != draft.bookId) {
        // Refund/reimbursement children follow their original bill's book.
        for (final childId in _childIds(relations)) {
          await (db.update(db.records)
                ..where((t) => t.recordId.equals(childId)))
              .write(RecordsCompanion(accountBookId: Value(draft.bookId)));
        }
      }
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
    final children = <LedgerRecord>[
      for (final id in _childIds(RecordRelations.parse(old.relInfo)))
        ?await (db.select(
          db.records,
        )..where((t) => t.recordId.equals(id))).getSingleOrNull(),
    ];
    final rows = [old, ?fee, ...children];
    await _applyNet(netEffects(before: rows.map(factsOf)));
    if (_isLinkedChild(old)) await _unlinkFromOrigin(old);
    for (final r in rows) {
      await (db.delete(
        db.tagRecords,
      )..where((t) => t.recordId.equals(r.recordId))).go();
      await (db.delete(
        db.records,
      )..where((t) => t.recordId.equals(r.recordId))).go();
    }
    await _recomputeAffectedDebtsAfterDelete(rows);
    return recordId;
  }, (_) => true);

  /// Creates an account; its balance starts at [initial].
  ///
  /// For credit cards (type 6) [initial] is the signed balance (debt < 0) and
  /// [limit] the fixed credit limit stored in `init_money`.
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
    Money? limit,
    String? creditInfo,
    String? extraInfo,
  }) => _command(
    commandId,
    [
      'create-asset-v2',
      name,
      initial.toJson(),
      type,
      subType,
      currency,
      groupName,
      remark,
      countedInNetWorth,
      limit?.toJson(),
      creditInfo,
      extraInfo,
    ],
    () async {
      final trimmed = _assetName(name);
      if (limit != null && limit.isNegative) {
        throw const Failure(FailureCode.validation, '额度不能为负数');
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
              initMoneyMinor: (limit ?? initial).storageMinor,
              type: type,
              subType: Value(subType),
              createDate: _now(),
              sort: Value(minSort.read<int>('s') - 1),
              currency: Value(normalizeCurrency(currency)),
              groupName: Value(groupName),
              remark: Value(remark),
              creditInfo: Value(creditInfo),
              extraInfo: Value(extraInfo),
              isEffectiveAsset: Value(_effectiveFlag(type, countedInNetWorth)),
            ),
          );
      return '$id';
    },
    int.parse,
  );

  /// Edits account properties. The balance is never changed here: use
  /// [adjustBalance] so the change is recorded as a type=4 bill.
  Future<void> updateAsset({
    required String commandId,
    required int assetId,
    required String name,
    String? remark,
    String? groupName,
    String? currency,
    required bool countedInNetWorth,
    Money? limit,
    String? creditInfo,
    String? extraInfo,
  }) => _command(
    commandId,
    [
      'update-asset-v1',
      assetId,
      name,
      remark,
      groupName,
      currency,
      countedInNetWorth,
      limit?.toJson(),
      creditInfo,
      extraInfo,
    ],
    () async {
      final asset = await _asset(assetId);
      final trimmed = _assetName(name);
      if (limit != null && limit.isNegative) {
        throw const Failure(FailureCode.validation, '额度不能为负数');
      }
      await (db.update(db.assets)..where((t) => t.id.equals(assetId))).write(
        AssetsCompanion(
          name: Value(trimmed),
          remark: Value(remark),
          groupName: Value(groupName),
          currency: Value(normalizeCurrency(currency)),
          isEffectiveAsset: Value(
            _effectiveFlag(asset.type, countedInNetWorth),
          ),
          initMoneyMinor: limit == null
              ? const Value.absent()
              : Value(limit.storageMinor),
          creditInfo: Value(creditInfo),
          extraInfo: Value(extraInfo),
        ),
      );
      return '$assetId';
    },
    (_) {},
  );

  /// Sets `asset.status` (0 active / 1 hidden / 2 settled).
  Future<void> setAssetStatus({
    required String commandId,
    required int assetId,
    required int status,
  }) => _command(commandId, ['set-asset-status-v1', assetId, status], () async {
    await _asset(assetId);
    if (!const {
      AssetStatus.active,
      AssetStatus.hidden,
      AssetStatus.settled,
    }.contains(status)) {
      throw const Failure(FailureCode.validation, '账户状态无效');
    }
    await (db.update(db.assets)..where((t) => t.id.equals(assetId))).write(
      AssetsCompanion(status: Value(status)),
    );
    return '$assetId';
  }, (_) {});

  /// Deletes an account that no bill or plan references (otherwise hide it
  /// instead, so history keeps its account name).
  Future<void> deleteAsset({required String commandId, required int assetId}) =>
      _command(commandId, ['delete-asset-v1', assetId], () async {
        final asset = await _asset(assetId);
        final used = await db
            .customSelect(
              'SELECT COUNT(*) AS n FROM record '
              'WHERE asset_id = ?1 OR from_asset_id = ?1 OR to_asset_id = ?1',
              variables: [Variable.withInt(assetId)],
            )
            .getSingle();
        if (used.read<int>('n') > 0) {
          throw const Failure(
            FailureCode.validation,
            '该账户已有账单，不能删除；可以改为“隐藏”或“已结清”',
          );
        }

        final periodRef = await db
            .customSelect(
              'SELECT COUNT(*) AS n FROM record_period '
              'WHERE asset_id = ?1 OR asset_id2 = ?1',
              variables: [Variable.withInt(assetId)],
            )
            .getSingle();
        if (periodRef.read<int>('n') > 0) {
          throw const Failure(
            FailureCode.validation,
            '该账户已关联周期记账规则，不能删除；请先修改或删除对应周期规则，或改为“隐藏”',
          );
        }

        final instRef = await db
            .customSelect(
              'SELECT COUNT(*) AS n FROM installment WHERE asset_id = ?1',
              variables: [Variable.withInt(assetId)],
            )
            .getSingle();
        if (instRef.read<int>('n') > 0) {
          throw const Failure(
            FailureCode.validation,
            '该账户已关联分期计划，不能删除；请先删除对应分期计划，或改为“隐藏”',
          );
        }

        final savePlanRef = await db
            .customSelect(
              'SELECT ('
              '(SELECT COUNT(*) FROM money_save_plan '
              'WHERE from_asset_id = ?1 OR to_asset_id = ?1) + '
              '(SELECT COUNT(*) FROM money_save_plan_record '
              'WHERE from_asset_id = ?1 OR to_asset_id = ?1)'
              ') AS n',
              variables: [Variable.withInt(assetId)],
            )
            .getSingle();
        if (savePlanRef.read<int>('n') > 0) {
          throw const Failure(
            FailureCode.validation,
            '该账户已关联存钱计划，不能删除；请先修改或删除对应存钱计划，或改为“隐藏”',
          );
        }

        if (_hasNonEmptyFixedDeposit(asset.fixedDepositInfo)) {
          throw const Failure(
            FailureCode.validation,
            '该账户下存在定期存款记录，不能删除；请先删除对应定期存款，或改为“隐藏”',
          );
        }

        final otherDepositHosts = await db
            .customSelect(
              'SELECT fixed_deposit_info FROM asset '
              'WHERE id != ?1 AND fixed_deposit_info IS NOT NULL '
              "AND TRIM(fixed_deposit_info) != ''",
              variables: [Variable.withInt(assetId)],
            )
            .get();
        for (final row in otherDepositHosts) {
          final raw = row.read<String?>('fixed_deposit_info');
          try {
            final items = decodeFixedDepositList(raw);
            if (items.any((item) => item.fromAssetId == assetId)) {
              throw const Failure(
                FailureCode.validation,
                '该账户已被定期存款关联为转出账户，不能删除；请先删除对应定期存款，或改为“隐藏”',
              );
            }
          } on Failure catch (e) {
            if (e.code == FailureCode.validation) rethrow;
          }
        }

        await (db.delete(
          db.assetBooks,
        )..where((t) => t.assetId.equals(assetId))).go();
        await (db.delete(db.assets)..where((t) => t.id.equals(assetId))).go();
        return '$assetId';
      }, (_) {});

  String _assetName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.length > 50) {
      throw const Failure(FailureCode.validation, '账户名称须为 1–50 字');
    }
    return trimmed;
  }

  // Original flag: 1 = counted, inverted for type 4 (ledger-catalog §3).
  int _effectiveFlag(int type, bool counted) =>
      type == AssetType.debt ? (counted ? 0 : 1) : (counted ? 1 : 0);

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

  /// Adds a refund to an expense/income/reimbursable bill (ledger-catalog §1/§4):
  /// a child bill of the same direction with negative money, linked both ways.
  Future<String> addRefund({
    required String commandId,
    required String originId,
    required Money amount,
    required int assetId,
    required int recordTime,
    String remark = '',
  }) => _command(
    commandId,
    ['add-refund-v1', originId, amount.toJson(), assetId, recordTime, remark],
    () async {
      final origin = await _liveRecord(originId);
      if (!const {
            RecordType.expense,
            RecordType.income,
            RecordType.reimbursable,
          }.contains(origin.type) ||
          _isLinkedChild(origin)) {
        throw const Failure(FailureCode.validation, '这笔账单不能退款');
      }
      if (amount.units <= BigInt.zero) {
        throw const Failure(FailureCode.validation, '退款金额须大于 0');
      }
      if (assetId != noRef) await _fundingAsset(assetId);
      final childId = _uuid.v4();
      final row = RecordsCompanion(
        recordId: Value(childId),
        type: Value(
          origin.type == RecordType.income
              ? RecordType.income
              : RecordType.expense,
        ),
        moneyMinor: Value(-amount.storageMinor),
        remark: Value(remark),
        recordTime: Value(recordTime),
        recordCatId: Value(origin.recordCatId),
        assetId: Value(assetId),
        accountBookId: Value(origin.accountBookId),
        excludeBudget: Value(origin.excludeBudget),
        excludeExIn: Value(origin.excludeExIn),
        relInfo: Value(
          (RecordRelations()..refunds = BillLinks(originId: originId)).encode(),
        ),
        createDate: Value(_now()),
      );
      await _applyNet(netEffects(after: [_factsOfCompanion(row)]));
      await _touchAssets([_factsOfCompanion(row)]);
      await db.into(db.records).insert(row);
      final rel = RecordRelations.parse(origin.relInfo);
      final links = rel.refunds ?? const BillLinks();
      rel.refunds = BillLinks(
        children: [
          ...links.children,
          LinkedBill(billId: childId, amount: amount.storageMinor),
        ],
        originId: links.originId,
      );
      await _writeRelations(originId, rel);
      return childId;
    },
    (id) => id,
  );

  /// Records money received for a reimbursable (type 3) bill: a type 15 bill
  /// on the receiving account, linked both ways (ledger-catalog §1).
  Future<String> addReimbursement({
    required String commandId,
    required String originId,
    required Money amount,
    required int assetId,
    required int recordTime,
    String remark = '',
  }) => _command(
    commandId,
    [
      'add-reimbursement-v1',
      originId,
      amount.toJson(),
      assetId,
      recordTime,
      remark,
    ],
    () async {
      final origin = await _liveRecord(originId);
      if (origin.type != RecordType.reimbursable) {
        throw const Failure(FailureCode.validation, '只有报销账单可以登记报销款');
      }
      if (amount.units <= BigInt.zero) {
        throw const Failure(FailureCode.validation, '报销金额须大于 0');
      }
      if (assetId != noRef) await _fundingAsset(assetId);
      // A receipt dated before the original bill is clamped to origin + 1 ms.
      final time = recordTime <= origin.recordTime
          ? origin.recordTime + 1
          : recordTime;
      final childId = _uuid.v4();
      final row = RecordsCompanion(
        recordId: Value(childId),
        type: const Value(RecordType.reimburseReceipt),
        subType: const Value(RecordDirection.income),
        moneyMinor: Value(amount.storageMinor),
        remark: Value(remark),
        recordTime: Value(time),
        assetId: Value(assetId),
        accountBookId: Value(origin.accountBookId),
        relInfo: Value(
          (RecordRelations()..reimbursements = BillLinks(originId: originId))
              .encode(),
        ),
        createDate: Value(_now()),
      );
      await _applyNet(netEffects(after: [_factsOfCompanion(row)]));
      await _touchAssets([_factsOfCompanion(row)]);
      await db.into(db.records).insert(row);
      final rel = RecordRelations.parse(origin.relInfo);
      final links = rel.reimbursements ?? const BillLinks();
      rel.reimbursements = BillLinks(
        children: [
          ...links.children,
          LinkedBill(billId: childId, amount: amount.storageMinor),
        ],
        originId: links.originId,
      );
      await _writeRelations(originId, rel);
      return childId;
    },
    (id) => id,
  );

  /// Settles a pending advance bill (`type=9` 预收 -> `type=1` 收入,
  /// `type=16` 预支 -> `type=0` 支出) onto [assetId] at [recordTime].
  Future<String> settleAdvance({
    required String commandId,
    required String originId,
    required Money amount,
    required int assetId,
    required int recordTime,
    bool finish = true,
    String remark = '',
  }) => _command(
    commandId,
    [
      'settle-advance-v1',
      originId,
      amount.toJson(),
      assetId,
      recordTime,
      finish,
      remark,
    ],
    () async {
      final origin = await _liveRecord(originId);
      if (origin.type != RecordType.advanceIncome &&
          origin.type != RecordType.advanceExpense) {
        throw const Failure(FailureCode.validation, '只有预收/预支账单可以结算');
      }
      final originExtra = RecordExtra.parse(origin.extraInfo);
      if (originExtra.advance != null) {
        throw const Failure(FailureCode.validation, '该预收/预支已结算');
      }
      if (amount.units <= BigInt.zero) {
        throw const Failure(FailureCode.validation, '结算金额须大于 0');
      }
      if (assetId != noRef) await _fundingAsset(assetId);

      final settledType = origin.type == RecordType.advanceIncome
          ? RecordType.income
          : RecordType.expense;
      final settledId = _uuid.v4();
      final settledExtra = RecordExtra()
        ..advance = AdvanceBillInfo(
          advanceDate: origin.recordTime,
          advanceMoney: origin.moneyMinor,
          advanceDiffMoney: BigInt.zero,
          partialInclude: true,
        );
      final settledRow = RecordsCompanion(
        recordId: Value(settledId),
        type: Value(settledType),
        moneyMinor: Value(amount.storageMinor),
        remark: Value(remark.trim().isEmpty ? origin.remark : remark.trim()),
        recordTime: Value(recordTime),
        recordCatId: Value(origin.recordCatId),
        assetId: Value(assetId),
        accountBookId: Value(origin.accountBookId),
        excludeBudget: Value(origin.excludeBudget),
        excludeExIn: Value(origin.excludeExIn),
        extraInfo: Value(settledExtra.encode()),
        createDate: Value(_now()),
      );

      await _applyNet(netEffects(after: [_factsOfCompanion(settledRow)]));
      await _touchAssets([_factsOfCompanion(settledRow)]);
      await db.into(db.records).insert(settledRow);

      final originTags = await (db.select(
        db.tagRecords,
      )..where((t) => t.recordId.equals(originId))).get();
      if (originTags.isNotEmpty) {
        await _replaceTags(
          settledId,
          originTags.map((t) => t.tagId).toList(growable: false),
        );
      }

      if (!finish && amount.storageMinor < origin.moneyMinor) {
        await (db.update(
          db.records,
        )..where((t) => t.recordId.equals(originId))).write(
          RecordsCompanion(
            moneyMinor: Value(origin.moneyMinor - amount.storageMinor),
          ),
        );
      } else {
        originExtra.advance = AdvanceBillInfo(
          advanceDate: recordTime,
          advanceMoney: origin.moneyMinor,
          advanceDiffMoney: amount.storageMinor - origin.moneyMinor,
          partialInclude: false,
        );
        await (db.update(db.records)..where((t) => t.recordId.equals(originId)))
            .write(RecordsCompanion(extraInfo: Value(originExtra.encode())));
      }
      return settledId;
    },
    (id) => id,
  );

  // ---- helpers ----

  bool _isLinkedChild(LedgerRecord r) {
    final rel = RecordRelations.parse(r.relInfo);
    bool has(String? id) => id != null && id.trim().isNotEmpty;
    return has(rel.refunds?.originId) || has(rel.reimbursements?.originId);
  }

  Iterable<String> _childIds(RecordRelations rel) => [
    for (final c in rel.refunds?.children ?? const <LinkedBill>[]) c.billId,
    for (final c in rel.reimbursements?.children ?? const <LinkedBill>[])
      c.billId,
  ];

  Future<void> _writeRelations(String recordId, RecordRelations rel) =>
      (db.update(db.records)..where((t) => t.recordId.equals(recordId))).write(
        RecordsCompanion(relInfo: Value(rel.encode())),
      );

  Future<void> _unlinkFromOrigin(LedgerRecord child) async {
    final childRel = RecordRelations.parse(child.relInfo);
    final originId =
        childRel.refunds?.originId ?? childRel.reimbursements?.originId;
    if (originId == null) return;
    final origin = await (db.select(
      db.records,
    )..where((t) => t.recordId.equals(originId))).getSingleOrNull();
    if (origin == null) return;
    final rel = RecordRelations.parse(origin.relInfo);
    BillLinks? without(BillLinks? links) => links == null
        ? null
        : BillLinks(
            children: [
              for (final c in links.children)
                if (c.billId != child.recordId) c,
            ],
            originId: links.originId,
          );
    rel.refunds = without(rel.refunds);
    rel.reimbursements = without(rel.reimbursements);
    await _writeRelations(originId, rel);
  }

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
      await _fundingAsset(id);
    }

    switch (d.type) {
      case RecordType.reimbursable:
        if (d.money.units <= BigInt.zero) {
          throw const Failure(FailureCode.validation, '报销金额须大于 0');
        }
        final cat = await (db.select(
          db.recordCategories,
        )..where((t) => t.id.equals(d.categoryId))).getSingleOrNull();
        if (cat == null ||
            cat.type != RecordType.expense ||
            cat.accountBookId != d.bookId) {
          throw const Failure(FailureCode.validation, '请选择当前账本的支出分类');
        }
        if (d.fromAssetId != noRef) await _fundingAsset(d.fromAssetId);
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
        if (d.assetId != noRef) await _fundingAsset(d.assetId);
        if (d.discount != null && d.discount!.isNegative) {
          throw const Failure(FailureCode.validation, '优惠金额无效');
        }
      case RecordType.advanceIncome:
      case RecordType.advanceExpense:
        if (d.money.units <= BigInt.zero) {
          throw const Failure(FailureCode.validation, '预收/预支金额须大于 0');
        }
        final wantCatType = d.type == RecordType.advanceIncome
            ? RecordType.income
            : RecordType.expense;
        final cat = await (db.select(
          db.recordCategories,
        )..where((t) => t.id.equals(d.categoryId))).getSingleOrNull();
        if (cat == null ||
            cat.type != wantCatType ||
            cat.accountBookId != d.bookId) {
          throw const Failure(FailureCode.validation, '请选择当前账本的对应分类');
        }
        if (d.assetId != noRef) await _fundingAsset(d.assetId);
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

  Future<Asset> _fundingAsset(int id) async {
    final asset = await _asset(id);
    if (asset.type == AssetType.debt) {
      throw const Failure(FailureCode.validation, '不能选择借贷账户作为普通资金账户');
    }
    return asset;
  }

  bool _hasNonEmptyFixedDeposit(String? fixedDepositInfo) {
    if (fixedDepositInfo == null || fixedDepositInfo.trim().isEmpty) {
      return false;
    }
    try {
      return decodeFixedDepositList(fixedDepositInfo).isNotEmpty;
    } on Failure {
      return true;
    }
  }

  Future<void> _recomputeAffectedDebtsAfterDelete(
    Iterable<LedgerRecord> deletedRows,
  ) async {
    const debtPrincipalTypes = {
      RecordType.borrowIn,
      RecordType.lendOut,
      RecordType.repay,
      RecordType.collect,
    };
    final candidateIds = <int>{
      for (final r in deletedRows)
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
      if (asset.type == AssetType.debt) continue;
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
