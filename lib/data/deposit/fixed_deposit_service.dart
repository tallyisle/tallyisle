import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/failure.dart';
import '../../core/money.dart';
import '../../domain/ledger/effects.dart';
import '../../domain/ledger/record_extra.dart';
import '../../domain/model/codes.dart';
import '../../domain/rules/asset_overview.dart';
import '../../domain/rules/currency_rates.dart';
import '../../domain/rules/fixed_deposit.dart';
import '../db/database.dart';
import '../db/failures.dart';
import '../ledger/ledger_service.dart' show factsOf;

const _uuid = Uuid();

final class _AsyncMutex {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }
}

/// Input payload for creating or editing a fixed deposit (F-027).
final class FixedDepositDraft {
  FixedDepositDraft({
    required this.targetAssetId,
    required this.principal,
    required this.annualRate,
    this.periodUnit = DepositPeriodUnit.year,
    this.periodCount = 1,
    required this.depositDate,
    this.dueDateOverride,
    this.expectedIncomeMinorOverride,
    this.currency,
    this.fromAssetId = noRef,
    this.updateAssetBalance = false,
    this.createBalanceAdjustRecord = true,
    this.remark = '',
    this.bookId,
  });

  final int targetAssetId;
  final Money principal;
  final DecimalValue annualRate;
  final int periodUnit;
  final int periodCount;
  final int depositDate;
  final int? dueDateOverride;
  final BigInt? expectedIncomeMinorOverride;
  final String? currency;
  final int fromAssetId;
  final bool updateAssetBalance;

  /// Mode B1 reconciliation safety (`ASYM-FD-08` / §6.2):
  /// when `fromAssetId == -1 && updateAssetBalance == true`, writes a
  /// `RecordType.balanceAdjust` row by default so reconciliation has no gap.
  final bool createBalanceAdjustRecord;
  final String remark;
  final int? bookId;

  List<Object?> get payload => [
    targetAssetId,
    principal.toJson(),
    formatDecimalValue(annualRate),
    periodUnit,
    periodCount,
    depositDate,
    dueDateOverride,
    expectedIncomeMinorOverride?.toString(),
    currency,
    fromAssetId,
    updateAssetBalance,
    createBalanceAdjustRecord,
    remark,
    bookId,
  ];
}

/// Write service and lazy maturity settlement engine for fixed deposits (F-027).
final class FixedDepositService {
  FixedDepositService(this.db);
  final AppDatabase db;

  static final _settleLocks = Expando<_AsyncMutex>();
  _AsyncMutex get _mutex => _settleLocks[db] ??= _AsyncMutex();

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

  /// Creates a fixed deposit in Mode A, Mode B1, or Mode B2 (R3).
  /// Returns the inserted index inside `targetAsset.fixed_deposit_info`.
  Future<int> createDeposit({
    required String commandId,
    required FixedDepositDraft draft,
  }) => _command(commandId, ['deposit-create-v1', ...draft.payload], () async {
    final rates = await _loadRates();
    final prepared = await _prepareDraft(draft, rates);
    final idx = await _applyAndAppendPrepared(prepared);
    return '$idx';
  }, int.parse);

  /// Updates an existing fixed deposit at `(assetId, index)` (R6).
  /// - Running (`status == 0`): `prepare -> delete old -> add new`.
  /// - Settled (`status == 1`): only remark edits are permitted; syncs linked bills.
  Future<int> updateDeposit({
    required String commandId,
    required int assetId,
    required int index,
    required FixedDepositDraft draft,
  }) => _command(
    commandId,
    ['deposit-update-v1', assetId, index, ...draft.payload],
    () async {
      final asset = await _eligibleActiveAsset(assetId);
      final items = decodeFixedDepositList(asset.fixedDepositInfo);
      if (index < 0 || index >= items.length) {
        throw const Failure(FailureCode.validation, '定期存款条目不存在');
      }
      final existing = items[index];
      if (existing.isSettled) {
        if (!_sameSettledFields(assetId, existing, draft)) {
          throw const Failure(FailureCode.validation, '已结束的定期存款仅支持修改备注');
        }
        await _updateRemarkInternal(
          asset: asset,
          items: items,
          index: index,
          newRemark: draft.remark,
        );
        return '$index';
      }

      final rates = await _loadRates();
      // Validate draft before mutating old state; note if Mode A transfers from
      // the same asset or another eligible asset, verify against post-removal state
      // cleanly by checking eligibility upfront.
      final prepared = await _prepareDraft(draft, rates);
      await _removeDepositInternal(assetId: assetId, index: index);
      final newIndex = await _applyAndAppendPrepared(prepared);
      return '$newIndex';
    },
    int.parse,
  );

  /// Updates `remark` of a deposit (primarily settled deposits) and syncs
  /// linked transfer / adjustment / income records (`ASYM-FD-03`).
  Future<void> updateDepositRemark({
    required String commandId,
    required int assetId,
    required int index,
    required String remark,
  }) => _command(
    commandId,
    ['deposit-update-remark-v1', assetId, index, remark],
    () async {
      if (remark.length > 2000) {
        throw const Failure(FailureCode.validation, '备注过长');
      }
      final asset = await _eligibleActiveAsset(assetId);
      final items = decodeFixedDepositList(asset.fixedDepositInfo);
      if (index < 0 || index >= items.length) {
        throw const Failure(FailureCode.validation, '定期存款条目不存在');
      }
      await _updateRemarkInternal(
        asset: asset,
        items: items,
        index: index,
        newRemark: remark,
      );
      return '$assetId:$index';
    },
    (_) {},
  );

  /// Deletes a deposit at `(assetId, index)`, checking live `record` existence
  /// before reversing `netEffects` to prevent double deduction (`ASYM-FD-04`).
  Future<void> deleteDeposit({
    required String commandId,
    required int assetId,
    required int index,
  }) => _command(commandId, ['deposit-delete-v1', assetId, index], () async {
    await _removeDepositInternal(assetId: assetId, index: index);
    return '$assetId:$index';
  }, (_) {});

  /// Scans eligible active accounts (`status == 0 && type != 4 && type != 6`)
  /// and settles all due deposits (`status == 0 && incomeRecordId == null && dueDate <= nowMs`)
  /// inside an async mutex + DB transaction (R4, `ASYM-FD-02`, `ASYM-FD-06`, `FD-F04`).
  ///
  /// Returns the count of deposits settled during this call.
  Future<int> settleDueDeposits({
    int? nowMs,
    int? assetId,
    int? fallbackBookId,
  }) => _mutex.run(
    () => guardDatabase(
      () => db.transaction(() async {
        final effectiveNow = nowMs ?? _now();
        final query = db.select(db.assets)
          ..where(
            (t) =>
                t.status.equals(AssetStatus.active) &
                t.type.equals(AssetType.credit).not() &
                t.type.equals(AssetType.debt).not() &
                (assetId == null ? const Constant(true) : t.id.equals(assetId)),
          )
          ..orderBy([
            (t) => OrderingTerm.asc(t.sort),
            (t) => OrderingTerm.asc(t.id),
          ]);

        final candidates = await query.get();
        if (candidates.isEmpty) return 0;

        final rates = await _loadRates();
        var settledCount = 0;

        for (final asset in candidates) {
          if (asset.fixedDepositInfo == null ||
              asset.fixedDepositInfo!.trim().isEmpty) {
            continue;
          }
          final items = decodeFixedDepositList(asset.fixedDepositInfo);
          if (items.isEmpty) continue;

          final assetCurr = normalizeCurrency(asset.currency) ?? rates.base;
          var dirty = false;
          var usedTimesDelta = 0;
          final afterFacts = <EntryFacts>[];
          final rowsToInsert = <RecordsCompanion>[];
          int? resolvedBookId;

          for (var i = 0; i < items.length; i++) {
            final item = items[i];
            if (!item.shouldSettle(effectiveNow)) continue;

            final depCurr = normalizeCurrency(item.currency) ?? assetCurr;
            final incMinor = item.expectedIncomeMinor;
            final BigInt assetInterestMinor;
            final BigInt baseInterestMinor;

            if (incMinor <= BigInt.zero) {
              assetInterestMinor = BigInt.zero;
              baseInterestMinor = BigInt.zero;
            } else {
              final convertedAsset = tryConvertMinor(
                incMinor,
                depCurr,
                assetCurr,
                rates,
              );
              final convertedBase = tryConvertMinor(
                incMinor,
                depCurr,
                rates.base,
                rates,
              );
              if (convertedAsset == null || convertedBase == null) {
                // Missing or invalid (<= 0) foreign currency rate: leave unsettled.
                continue;
              }
              assetInterestMinor = convertedAsset;
              baseInterestMinor = convertedBase;
            }

            resolvedBookId ??= await _resolveBookId(
              hostAssetId: asset.id,
              explicitBookId: fallbackBookId,
            );

            final allBase = depCurr == rates.base && assetCurr == rates.base;
            final currSnapshot = allBase
                ? null
                : CurrencySnapshot(
                    sourceCode: depCurr,
                    sourceGross: incMinor,
                    assetCode: assetCurr,
                    assetNet: assetInterestMinor,
                    baseCode: rates.base,
                    baseAmount: baseInterestMinor,
                  );

            final incomeId = _uuid.v4();
            final extra = RecordExtra()..currency = currSnapshot;
            final row = RecordsCompanion(
              recordId: Value(incomeId),
              type: const Value(RecordType.depositInterest),
              subType: const Value(RecordDirection.income),
              moneyMinor: Value(assetInterestMinor),
              remark: Value(depositIncomeRemark(item.remark)),
              recordTime: Value(item.dueDate),
              assetId: Value(asset.id),
              accountBookId: Value(resolvedBookId),
              extraInfo: Value(extra.encode()),
              createDate: Value(_now()),
            );

            rowsToInsert.add(row);
            // FD-F04: when settled interest == 0, skip balance & usedTimes increment!
            if (assetInterestMinor > BigInt.zero) {
              afterFacts.add(_factsOfCompanion(row));
              usedTimesDelta += 1;
            }

            items[i] = item.copyWith(
              status: FixedDepositStatus.settled,
              incomeRecordId: incomeId,
            );
            dirty = true;
            settledCount += 1;
          }

          if (dirty) {
            for (final row in rowsToInsert) {
              await db.into(db.records).insert(row);
            }
            if (afterFacts.isNotEmpty) {
              await _applyNet(netEffects(after: afterFacts));
            }
            final latest = await _asset(asset.id);
            await (db.update(
              db.assets,
            )..where((t) => t.id.equals(asset.id))).write(
              AssetsCompanion(
                fixedDepositInfo: Value(encodeFixedDepositList(items)),
                usedTimes: usedTimesDelta > 0
                    ? Value(latest.usedTimes + usedTimesDelta)
                    : const Value.absent(),
              ),
            );
          }
        }

        return settledCount;
      }),
    ),
  );

  // ---- Internal helpers ----

  Future<_PreparedDeposit> _prepareDraft(
    FixedDepositDraft draft,
    RateTable rates,
  ) async {
    if (draft.principal.scale != Money.ledgerScale) {
      throw const Failure(FailureCode.scaleMismatch, '定存本金须为两位小数');
    }
    if (draft.principal.units <= BigInt.zero) {
      throw const Failure(FailureCode.validation, '定存本金须大于 0');
    }
    if (draft.annualRate.coefficient.isNegative) {
      throw const Failure(FailureCode.validation, '年化利率不能为负数');
    }
    if (draft.periodUnit != DepositPeriodUnit.month &&
        draft.periodUnit != DepositPeriodUnit.year) {
      throw const Failure(FailureCode.validation, '存期单位无效');
    }
    if (draft.periodCount < 1) {
      throw const Failure(FailureCode.validation, '存期须至少为 1');
    }
    if (draft.remark.length > 2000) {
      throw const Failure(FailureCode.validation, '备注过长');
    }

    final targetAsset = await _eligibleActiveAsset(draft.targetAssetId);
    final bookId = await _resolveBookId(
      hostAssetId: targetAsset.id,
      explicitBookId: draft.bookId,
    );

    final dueDate =
        draft.dueDateOverride ??
        calculateDueDate(
          depositDateMs: draft.depositDate,
          periodUnit: draft.periodUnit,
          periodCount: draft.periodCount,
        );

    final expectedIncomeMinor =
        draft.expectedIncomeMinorOverride ??
        calculateExpectedIncomeMinor(
          principal: draft.principal,
          annualRate: draft.annualRate,
          periodUnit: draft.periodUnit,
          periodCount: draft.periodCount,
        );
    if (expectedIncomeMinor.isNegative) {
      throw const Failure(FailureCode.validation, '预期收益不能为负数');
    }

    final principalMinor = draft.principal.storageMinor;
    final targetCurr = normalizeCurrency(targetAsset.currency) ?? rates.base;
    final depCurr = normalizeCurrency(draft.currency) ?? targetCurr;

    if (draft.fromAssetId != noRef) {
      if (draft.fromAssetId == targetAsset.id) {
        throw const Failure(FailureCode.validation, '转出账户不能与定存账户相同');
      }
      final fromAsset = await _eligibleActiveAsset(draft.fromAssetId);
      final plan = buildModeATransferPlan(
        principalMinor: principalMinor,
        depositCurrency: draft.currency,
        fromAssetCurrency: fromAsset.currency,
        targetAssetCurrency: targetAsset.currency,
        rates: rates,
      );
      return _PreparedDeposit(
        targetAssetId: targetAsset.id,
        bookId: bookId,
        draft: draft,
        dueDate: dueDate,
        expectedIncomeMinor: expectedIncomeMinor,
        depositCurrency: plan.depositCurrency,
        assetCurrency: plan.targetCurrency,
        assetMoneyMinor: plan.targetMoneyMinor,
        baseCurrencyCode: plan.baseCurrencyCode,
        baseMoneyMinor: plan.baseMoneyMinor,
        modeAPlan: plan,
      );
    }

    final amMinor = strictConvertMinor(
      principalMinor,
      depCurr,
      targetCurr,
      rates,
    );
    final bmMinor = strictConvertMinor(
      principalMinor,
      depCurr,
      rates.base,
      rates,
    );

    return _PreparedDeposit(
      targetAssetId: targetAsset.id,
      bookId: bookId,
      draft: draft,
      dueDate: dueDate,
      expectedIncomeMinor: expectedIncomeMinor,
      depositCurrency: depCurr,
      assetCurrency: targetCurr,
      assetMoneyMinor: amMinor,
      baseCurrencyCode: rates.base,
      baseMoneyMinor: bmMinor,
    );
  }

  Future<int> _applyAndAppendPrepared(_PreparedDeposit p) async {
    String? transferRecordId;
    String? adjustRecordId;
    final bool effectiveUpdateBalance;

    if (p.modeAPlan != null) {
      // Mode A: create transfer record (`type = 2, subType = 0, recordTime = depositDate`)
      effectiveUpdateBalance = false;
      final id = _uuid.v4();
      transferRecordId = id;
      final extra = RecordExtra()..currency = p.modeAPlan!.snapshot;
      final row = RecordsCompanion(
        recordId: Value(id),
        type: const Value(RecordType.transfer),
        subType: const Value(RecordDirection.expense),
        moneyMinor: Value(p.modeAPlan!.sourceMoneyMinor),
        remark: Value(p.draft.remark),
        recordTime: Value(p.draft.depositDate),
        fromAssetId: Value(p.draft.fromAssetId),
        toAssetId: Value(p.targetAssetId),
        accountBookId: Value(p.bookId),
        extraInfo: Value(extra.encode()),
        createDate: Value(_now()),
      );
      final facts = _factsOfCompanion(row);
      await _applyNet(netEffects(after: [facts]));
      await _touchAssets([p.draft.fromAssetId, p.targetAssetId]);
      await db.into(db.records).insert(row);
    } else if (p.draft.updateAssetBalance) {
      // Mode B1: host balance increases; write `RecordType.balanceAdjust` by default (ASYM-FD-08).
      effectiveUpdateBalance = true;
      if (p.draft.createBalanceAdjustRecord) {
        final id = _uuid.v4();
        adjustRecordId = id;
        final row = RecordsCompanion(
          recordId: Value(id),
          type: const Value(RecordType.balanceAdjust),
          subType: const Value(RecordDirection.none),
          moneyMinor: Value(p.assetMoneyMinor),
          remark: Value(depositAdjustRemark(p.draft.remark)),
          recordTime: Value(p.draft.depositDate),
          fromAssetId: Value(p.targetAssetId),
          accountBookId: Value(p.bookId),
          createDate: Value(_now()),
        );
        final facts = _factsOfCompanion(row);
        await _applyNet(netEffects(after: [facts]));
        await db.into(db.records).insert(row);
      } else {
        await _applyNet({p.targetAssetId: p.assetMoneyMinor});
      }
    } else {
      // Mode B2: memo only.
      effectiveUpdateBalance = false;
    }

    final item = FixedDepositItem(
      moneyMinor: p.draft.principal.storageMinor,
      fromAssetId: p.draft.fromAssetId,
      updateAssetBalance: effectiveUpdateBalance,
      annualRate: p.draft.annualRate,
      periodUnit: p.draft.periodUnit,
      periodCount: p.draft.periodCount,
      depositDate: p.draft.depositDate,
      dueDate: p.dueDate,
      expectedIncomeMinor: p.expectedIncomeMinor,
      currency: p.depositCurrency,
      assetCurrency: p.assetCurrency,
      assetMoneyMinor: p.assetMoneyMinor,
      baseCurrency: p.baseCurrencyCode,
      baseMoneyMinor: p.baseMoneyMinor,
      remark: p.draft.remark,
      transferRecordId: transferRecordId,
      incomeRecordId: null,
      status: FixedDepositStatus.running,
      adjustRecordId: adjustRecordId,
    );

    final latestTarget = await _asset(p.targetAssetId);
    final list = [
      ...decodeFixedDepositList(latestTarget.fixedDepositInfo),
      item,
    ];
    await (db.update(
      db.assets,
    )..where((t) => t.id.equals(p.targetAssetId))).write(
      AssetsCompanion(fixedDepositInfo: Value(encodeFixedDepositList(list))),
    );
    return list.length - 1;
  }

  Future<void> _removeDepositInternal({
    required int assetId,
    required int index,
  }) async {
    final asset = await _asset(assetId);
    if (!isFixedDepositEligibleType(asset.type)) {
      throw const Failure(FailureCode.validation, '该账户不支持定期存款');
    }
    final items = decodeFixedDepositList(asset.fixedDepositInfo).toList();
    if (index < 0 || index >= items.length) {
      throw const Failure(FailureCode.validation, '定期存款条目不存在');
    }
    final item = items[index];

    // 1. Reverse principal effect safely (ASYM-FD-04: check live record existence first!)
    if (item.transferRecordId != null && item.transferRecordId!.isNotEmpty) {
      final liveTransfer = await _liveRecordOrNull(item.transferRecordId!);
      if (liveTransfer != null) {
        await _deleteLiveRecordAndReverse(liveTransfer);
      }
    } else if (item.adjustRecordId != null && item.adjustRecordId!.isNotEmpty) {
      final liveAdjust = await _liveRecordOrNull(item.adjustRecordId!);
      if (liveAdjust != null) {
        await _deleteLiveRecordAndReverse(liveAdjust);
      }
    } else if (item.fromAssetId == noRef && item.updateAssetBalance) {
      // Legacy Mode B1 without adjustment record: deduct resolvedAssetMoneyMinor.
      await _applyNet({assetId: -item.resolvedAssetMoneyMinor});
    }

    // 2. Reverse settled interest effect safely (ASYM-FD-04: check live record existence first!)
    if (item.incomeRecordId != null && item.incomeRecordId!.isNotEmpty) {
      final liveIncome = await _liveRecordOrNull(item.incomeRecordId!);
      if (liveIncome != null) {
        await _deleteLiveRecordAndReverse(liveIncome);
      }
    }

    // 3. Remove item from host JSON array (`null` when empty).
    items.removeAt(index);
    await (db.update(db.assets)..where((t) => t.id.equals(assetId))).write(
      AssetsCompanion(fixedDepositInfo: Value(encodeFixedDepositList(items))),
    );
  }

  Future<void> _updateRemarkInternal({
    required Asset asset,
    required List<FixedDepositItem> items,
    required int index,
    required String newRemark,
  }) async {
    final old = items[index];
    final updated = items.toList();
    updated[index] = old.copyWith(remark: newRemark);
    await (db.update(db.assets)..where((t) => t.id.equals(asset.id))).write(
      AssetsCompanion(fixedDepositInfo: Value(encodeFixedDepositList(updated))),
    );

    // ASYM-FD-03: sync remark to live linked bills!
    if (old.transferRecordId != null && old.transferRecordId!.isNotEmpty) {
      final live = await _liveRecordOrNull(old.transferRecordId!);
      if (live != null) {
        await (db.update(db.records)
              ..where((t) => t.recordId.equals(live.recordId)))
            .write(RecordsCompanion(remark: Value(newRemark)));
      }
    }
    if (old.adjustRecordId != null && old.adjustRecordId!.isNotEmpty) {
      final live = await _liveRecordOrNull(old.adjustRecordId!);
      if (live != null) {
        await (db.update(
          db.records,
        )..where((t) => t.recordId.equals(live.recordId))).write(
          RecordsCompanion(remark: Value(depositAdjustRemark(newRemark))),
        );
      }
    }
    if (old.incomeRecordId != null && old.incomeRecordId!.isNotEmpty) {
      final live = await _liveRecordOrNull(old.incomeRecordId!);
      if (live != null) {
        await (db.update(
          db.records,
        )..where((t) => t.recordId.equals(live.recordId))).write(
          RecordsCompanion(remark: Value(depositIncomeRemark(newRemark))),
        );
      }
    }
  }

  bool _sameSettledFields(
    int assetId,
    FixedDepositItem existing,
    FixedDepositDraft draft,
  ) {
    if (draft.targetAssetId != assetId) return false;
    if (draft.principal.storageMinor != existing.moneyMinor) return false;
    if (formatDecimalValue(draft.annualRate, trimTrailingZeros: true) !=
        formatDecimalValue(existing.annualRate, trimTrailingZeros: true)) {
      return false;
    }
    if (draft.periodUnit != existing.periodUnit) return false;
    if (draft.periodCount != existing.periodCount) return false;
    if (draft.depositDate != existing.depositDate) return false;
    if (draft.dueDateOverride != null &&
        draft.dueDateOverride != existing.dueDate) {
      return false;
    }
    if (draft.expectedIncomeMinorOverride != null &&
        draft.expectedIncomeMinorOverride != existing.expectedIncomeMinor) {
      return false;
    }
    if (draft.fromAssetId != existing.fromAssetId) return false;
    if (draft.fromAssetId == noRef &&
        draft.updateAssetBalance != existing.updateAssetBalance) {
      return false;
    }
    return true;
  }

  Future<void> _deleteLiveRecordAndReverse(LedgerRecord record) async {
    await _applyNet(netEffects(before: [factsOf(record)]));
    await (db.delete(
      db.tagRecords,
    )..where((t) => t.recordId.equals(record.recordId))).go();
    await (db.delete(
      db.records,
    )..where((t) => t.recordId.equals(record.recordId))).go();
  }

  Future<LedgerRecord?> _liveRecordOrNull(String recordId) => (db.select(
    db.records,
  )..where((t) => t.recordId.equals(recordId))).getSingleOrNull();

  Future<Asset> _asset(int id) async {
    final asset = await (db.select(
      db.assets,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (asset == null) throw const Failure(FailureCode.validation, '账户不存在');
    return asset;
  }

  Future<Asset> _eligibleActiveAsset(int id) async {
    final asset = await _asset(id);
    if (!isFixedDepositEligibleType(asset.type)) {
      throw const Failure(FailureCode.validation, '信用账户与借贷账户不支持定期存款');
    }
    if (asset.status != AssetStatus.active) {
      throw const Failure(FailureCode.validation, '隐藏或已归档账户不支持此操作');
    }
    return asset;
  }

  Future<RateTable> _loadRates() async {
    final rows = await db.select(db.currencies).get();
    final map = <String, String>{baseCurrency: '1'};
    for (final c in rows) {
      if (c.enable) {
        map[c.code] = c.rateToAnchor;
      }
    }
    return RateTable(map);
  }

  /// Resolves target `account_book_id` without ever hardcoding `1` (`ASYM-FD-07`):
  /// 1. Explicit `explicitBookId` (verified to exist in `account_book`);
  /// 2. Host asset's bound book(s) in `asset_book` (preferring `current_book_id` if bound to multiple);
  /// 3. Active `current_book_id` preference in `ti_preference`;
  /// 4. First available `account_book`.
  Future<int> _resolveBookId({
    required int hostAssetId,
    int? explicitBookId,
  }) async {
    if (explicitBookId != null) {
      final book = await (db.select(
        db.accountBooks,
      )..where((t) => t.id.equals(explicitBookId))).getSingleOrNull();
      if (book == null) {
        throw const Failure(FailureCode.validation, '账本不存在');
      }
      return book.id;
    }

    final prefRow = await (db.select(
      db.preferences,
    )..where((t) => t.key.equals('current_book_id'))).getSingleOrNull();
    final currentPrefId = int.tryParse(prefRow?.value ?? '');

    final links = await (db.select(
      db.assetBooks,
    )..where((t) => t.assetId.equals(hostAssetId))).get();
    if (links.isNotEmpty) {
      final boundIds = links.map((l) => l.bookId).toSet();
      if (currentPrefId != null && boundIds.contains(currentPrefId)) {
        final book = await (db.select(
          db.accountBooks,
        )..where((t) => t.id.equals(currentPrefId))).getSingleOrNull();
        if (book != null) return book.id;
      }
      for (final bId in boundIds) {
        final book = await (db.select(
          db.accountBooks,
        )..where((t) => t.id.equals(bId))).getSingleOrNull();
        if (book != null) return book.id;
      }
    }

    if (currentPrefId != null) {
      final book = await (db.select(
        db.accountBooks,
      )..where((t) => t.id.equals(currentPrefId))).getSingleOrNull();
      if (book != null) return book.id;
    }

    final firstBook =
        await (db.select(db.accountBooks)
              ..orderBy([
                (t) => OrderingTerm.asc(t.sort),
                (t) => OrderingTerm.asc(t.id),
              ])
              ..limit(1))
            .getSingleOrNull();
    if (firstBook == null) {
      throw const Failure(FailureCode.validation, '账本不存在');
    }
    return firstBook.id;
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

  Future<void> _applyNet(Map<int, BigInt> net) async {
    for (final entry in net.entries) {
      if (entry.value == BigInt.zero) continue;
      final asset = await _asset(entry.key);
      final balance = Money.minor(asset.balanceMinor + entry.value);
      await (db.update(db.assets)..where((t) => t.id.equals(entry.key))).write(
        AssetsCompanion(balanceMinor: Value(balance.storageMinor)),
      );
    }
  }

  Future<void> _touchAssets(Iterable<int> assetIds) async {
    for (final id in assetIds.toSet()) {
      if (id == noRef) continue;
      await db.customUpdate(
        'UPDATE asset SET used_times = used_times + 1 WHERE id = ?',
        variables: [Variable.withInt(id)],
        updates: {db.assets},
      );
    }
  }
}

final class _PreparedDeposit {
  const _PreparedDeposit({
    required this.targetAssetId,
    required this.bookId,
    required this.draft,
    required this.dueDate,
    required this.expectedIncomeMinor,
    required this.depositCurrency,
    required this.assetCurrency,
    required this.assetMoneyMinor,
    required this.baseCurrencyCode,
    required this.baseMoneyMinor,
    this.modeAPlan,
  });

  final int targetAssetId;
  final int bookId;
  final FixedDepositDraft draft;
  final int dueDate;
  final BigInt expectedIncomeMinor;
  final String depositCurrency;
  final String assetCurrency;
  final BigInt assetMoneyMinor;
  final String baseCurrencyCode;
  final BigInt baseMoneyMinor;
  final ModeATransferPlan? modeAPlan;
}
