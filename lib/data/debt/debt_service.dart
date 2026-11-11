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
import '../../domain/rules/debt_rules.dart';
import '../db/database.dart';
import '../db/failures.dart';
import '../ledger/ledger_service.dart' show factsOf;

const _uuid = Uuid();
final _maxAmountMinor = BigInt.parse('8888888888800');

/// Write boundary for F-011 Debt Management (Lending & Borrowing).
///
/// Every command runs inside a single idempotent transaction (`ADR-009`),
/// updates funding account balances via `netEffects` (`ADR-012`), and
/// recomputes debt principal & `loan_info` from live `{5, 6, 7, 8}` records.
final class DebtService {
  DebtService(this.db);
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

  /// Creates a lending (`subType = 99`) or borrowing (`subType = 100`) project,
  /// binds `asset_book` (`CE-DM-06`), writes the initial `{5|6}` principal
  /// record (`startDate + 1ms`), updates the optional funding account, and
  /// stores `is_effective_asset = 0` when [countedInNetWorth] is `true`
  /// (`CE-DM-01`).
  Future<int> createDebt({
    required String commandId,
    required int subType,
    required String name,
    required Money principal,
    required int bookId,
    List<int>? bookIds,
    required int startDate,
    int endDate = noRef,
    int fundingAssetId = noRef,
    Money? fundingAmount,
    bool countedInNetWorth = true,
    String? currency,
    String? remark,
  }) => _command(
    commandId,
    [
      'debt-create-v1',
      subType,
      name,
      principal.toJson(),
      bookId,
      bookIds,
      startDate,
      endDate,
      fundingAssetId,
      fundingAmount?.toJson(),
      countedInNetWorth,
      currency,
      remark,
    ],
    () async {
      _validateSubType(subType);
      final trimmedName = _validateDebtName(name);
      _validatePositiveMoney(principal, '本金金额须大于 0');
      _validateDates(startDate, endDate);
      final trimmedRemark = _normalizeRemark(remark);

      final resolvedBooks = _resolveBookIds(bookId, bookIds);
      for (final bId in resolvedBooks) {
        await _requireBook(bId);
      }
      final primaryBookId = resolvedBooks.first;

      final normDebtCurr = normalizeCurrency(currency);
      final effectiveDebtCurr = normDebtCurr ?? baseCurrency;
      final rates = await _loadValidatedRates({effectiveDebtCurr});

      final resolvedAmounts = await _resolveAmounts(
        debtCurrency: effectiveDebtCurr,
        sourceMinor: principal.storageMinor,
        fundingAssetId: fundingAssetId,
        explicitFundingAmount: fundingAmount,
        rates: rates,
      );

      final minSortRow = await db
          .customSelect('SELECT COALESCE(MIN(sort), 0) AS s FROM asset')
          .getSingle();
      final nextSort = minSortRow.read<int>('s') - 1;
      final now = _now();

      final initialInfo = LoanInfo(
        schemaVersion: 2,
        startDate: startDate,
        endDate: endDate,
        totalDebtMoneyMinor: principal.storageMinor,
        manualSettled: false,
        positionsUpdatedAtMs: now,
        currencyPositions: [
          LoanCurrencyPosition(
            currencyCode: effectiveDebtCurr,
            principalBalanceMinor: principal.storageMinor,
            totalPrincipalMinor: principal.storageMinor,
          ),
        ],
      );

      final debtId = await db
          .into(db.assets)
          .insert(
            AssetsCompanion.insert(
              name: trimmedName,
              balanceMinor: principal.storageMinor,
              initMoneyMinor: principal.storageMinor,
              type: AssetType.debt,
              subType: Value(subType),
              createDate: now,
              sort: Value(nextSort),
              remark: Value(trimmedRemark.isEmpty ? null : trimmedRemark),
              status: const Value(AssetStatus.active),
              isEffectiveAsset: Value(
                debtEffectiveAssetFlag(countedInNetWorth: countedInNetWorth),
              ),
              currency: Value(normDebtCurr),
              loanInfo: Value(initialInfo.encode()),
            ),
          );

      for (final bId in resolvedBooks) {
        await db
            .into(db.assetBooks)
            .insertOnConflictUpdate(
              AssetBooksCompanion.insert(assetId: debtId, bookId: bId),
            );
      }

      final spec = buildPrincipalRecordSpec(
        debtSubType: subType,
        debtId: debtId,
        fundingAssetId: fundingAssetId,
        isRepayment: false,
      );
      final recId = _uuid.v4();
      final recRow = RecordsCompanion(
        recordId: Value(recId),
        type: Value(spec.type),
        subType: Value(spec.subType),
        moneyMinor: Value(resolvedAmounts.recordMoneyMinor),
        remark: Value(trimmedRemark),
        recordTime: Value(principalRecordTimestamp(startDate)),
        recordCatId: const Value(noRef),
        assetId: const Value(noRef),
        fromAssetId: Value(spec.fromAssetId),
        toAssetId: Value(spec.toAssetId),
        accountBookId: Value(primaryBookId),
        excludeBudget: const Value(false),
        excludeExIn: const Value(false),
        extraInfo: Value(resolvedAmounts.extraInfo),
        createDate: Value(now),
      );

      final recFacts = _factsOfCompanion(recRow);
      await _applyNet(netEffects(after: [recFacts]));
      await _touchAssets([recFacts]);
      await db.into(db.records).insert(recRow);

      await _recomputeAndSaveDebt(debtId);
      return '$debtId';
    },
    int.parse,
  );

  /// Updates debt metadata (`name`, `remark`, `startDate`, `endDate`,
  /// `countedInNetWorth`, and `asset_book` bindings).
  Future<void> updateDebt({
    required String commandId,
    required int debtId,
    required String name,
    int? startDate,
    int? endDate,
    required bool countedInNetWorth,
    String? remark,
    int? bookId,
    List<int>? bookIds,
  }) => _command(
    commandId,
    [
      'debt-update-v1',
      debtId,
      name,
      startDate,
      endDate,
      countedInNetWorth,
      remark,
      bookId,
      bookIds,
    ],
    () async {
      final debt = await _requireDebt(debtId);
      final trimmedName = _validateDebtName(name);
      final trimmedRemark = _normalizeRemark(remark);

      final info = LoanInfo.parse(debt.loanInfo);
      final nextStart = startDate ?? info.startDate;
      final nextEnd = endDate ?? info.endDate;
      _validateDates(nextStart, nextEnd);

      final updatedInfo = info.copyWith(
        schemaVersion: 2,
        startDate: nextStart,
        endDate: nextEnd,
      );

      await (db.update(db.assets)..where((t) => t.id.equals(debtId))).write(
        AssetsCompanion(
          name: Value(trimmedName),
          remark: Value(trimmedRemark.isEmpty ? null : trimmedRemark),
          isEffectiveAsset: Value(
            debtEffectiveAssetFlag(countedInNetWorth: countedInNetWorth),
          ),
          loanInfo: Value(updatedInfo.encode()),
        ),
      );

      if (bookId != null || bookIds != null) {
        final resolvedBooks = _resolveBookIds(
          bookId ?? (bookIds!.isNotEmpty ? bookIds.first : 1),
          bookIds,
        );
        for (final bId in resolvedBooks) {
          await _requireBook(bId);
        }
        await (db.delete(
          db.assetBooks,
        )..where((t) => t.assetId.equals(debtId))).go();
        for (final bId in resolvedBooks) {
          await db
              .into(db.assetBooks)
              .insert(AssetBooksCompanion.insert(assetId: debtId, bookId: bId));
        }
      }
      return '$debtId';
    },
    (_) {},
  );

  /// Records additional principal (`type=5` 借入 or `type=6` 借出) at
  /// `operateDate + 1ms` and recomputes the debt balance.
  Future<String> addPrincipal({
    required String commandId,
    required int debtId,
    required Money amount,
    required int operateDate,
    required int bookId,
    int fundingAssetId = noRef,
    Money? fundingAmount,
    String remark = '',
  }) => _command(
    commandId,
    [
      'debt-add-principal-v1',
      debtId,
      amount.toJson(),
      operateDate,
      bookId,
      fundingAssetId,
      fundingAmount?.toJson(),
      remark,
    ],
    () async {
      final debt = await _requireDebt(debtId);
      if (debt.status == AssetStatus.settled) {
        throw const Failure(FailureCode.validation, '该借贷已结清，请先重新开启后再追加本金');
      }
      _validatePositiveMoney(amount, '追加本金须大于 0');
      await _requireBook(bookId);
      final trimmedRemark = _normalizeRemark(remark);

      final effectiveDebtCurr =
          normalizeCurrency(debt.currency) ?? baseCurrency;
      final rates = await _loadValidatedRates({effectiveDebtCurr});
      final resolved = await _resolveAmounts(
        debtCurrency: effectiveDebtCurr,
        sourceMinor: amount.storageMinor,
        fundingAssetId: fundingAssetId,
        explicitFundingAmount: fundingAmount,
        rates: rates,
      );

      final spec = buildPrincipalRecordSpec(
        debtSubType: debt.subType,
        debtId: debtId,
        fundingAssetId: fundingAssetId,
        isRepayment: false,
      );
      final recId = _uuid.v4();
      final row = RecordsCompanion(
        recordId: Value(recId),
        type: Value(spec.type),
        subType: Value(spec.subType),
        moneyMinor: Value(resolved.recordMoneyMinor),
        remark: Value(trimmedRemark),
        recordTime: Value(principalRecordTimestamp(operateDate)),
        recordCatId: const Value(noRef),
        assetId: const Value(noRef),
        fromAssetId: Value(spec.fromAssetId),
        toAssetId: Value(spec.toAssetId),
        accountBookId: Value(bookId),
        excludeBudget: const Value(false),
        excludeExIn: const Value(false),
        extraInfo: Value(resolved.extraInfo),
        createDate: Value(_now()),
      );

      final facts = _factsOfCompanion(row);
      await _applyNet(netEffects(after: [facts]));
      await _touchAssets([facts]);
      await db.into(db.records).insert(row);

      await _recomputeAndSaveDebt(debtId);
      return recId;
    },
    (id) => id,
  );

  /// Records repayment (`type=7`) / collection (`type=8`) at `operateDate + 1ms`
  /// and/or interest (`type=10`) at `operateDate + 2ms` (R2).
  ///
  /// When `principal == 0 && interest > 0`, writes ONLY `type=10` and updates
  /// the funding account WITHOUT recomputing debt principal!
  Future<String> recordRepayment({
    required String commandId,
    required int debtId,
    required Money principal,
    Money? interest,
    required int operateDate,
    required int bookId,
    int fundingAssetId = noRef,
    Money? fundingPrincipalAmount,
    Money? fundingInterestAmount,
    bool interestExcludeBudget = false,
    String remark = '',
  }) => _command(
    commandId,
    [
      'debt-repay-v1',
      debtId,
      principal.toJson(),
      interest?.toJson(),
      operateDate,
      bookId,
      fundingAssetId,
      fundingPrincipalAmount?.toJson(),
      fundingInterestAmount?.toJson(),
      interestExcludeBudget,
      remark,
    ],
    () async {
      final debt = await _requireDebt(debtId);
      final effInterest =
          interest ?? Money.zero(normalizeCurrency(debt.currency) ?? 'CNY');
      _validateNonNegativeMoney(principal, '本金金额不能为负数');
      _validateNonNegativeMoney(effInterest, '利息金额不能为负数');
      if (principal.isZero && effInterest.isZero) {
        throw const Failure(FailureCode.validation, '本金与利息不能同时为 0');
      }
      if (!principal.isZero && debt.status == AssetStatus.settled) {
        throw const Failure(FailureCode.validation, '该借贷已结清，请先重新开启后再记录本金收还');
      }
      await _requireBook(bookId);
      final trimmedRemark = _normalizeRemark(remark);

      final effectiveDebtCurr =
          normalizeCurrency(debt.currency) ?? baseCurrency;
      final rates = await _loadValidatedRates({effectiveDebtCurr});
      final now = _now();

      final companions = <RecordsCompanion>[];
      String? primaryId;

      if (!principal.isZero) {
        final resolvedPrincipal = await _resolveAmounts(
          debtCurrency: effectiveDebtCurr,
          sourceMinor: principal.storageMinor,
          fundingAssetId: fundingAssetId,
          explicitFundingAmount: fundingPrincipalAmount,
          rates: rates,
        );
        final pSpec = buildPrincipalRecordSpec(
          debtSubType: debt.subType,
          debtId: debtId,
          fundingAssetId: fundingAssetId,
          isRepayment: true,
        );
        final pId = _uuid.v4();
        primaryId = pId;
        companions.add(
          RecordsCompanion(
            recordId: Value(pId),
            type: Value(pSpec.type),
            subType: Value(pSpec.subType),
            moneyMinor: Value(resolvedPrincipal.recordMoneyMinor),
            remark: Value(trimmedRemark),
            recordTime: Value(principalRecordTimestamp(operateDate)),
            recordCatId: const Value(noRef),
            assetId: const Value(noRef),
            fromAssetId: Value(pSpec.fromAssetId),
            toAssetId: Value(pSpec.toAssetId),
            accountBookId: Value(bookId),
            excludeBudget: const Value(false),
            excludeExIn: const Value(false),
            extraInfo: Value(resolvedPrincipal.extraInfo),
            createDate: Value(now),
          ),
        );
      }

      if (!effInterest.isZero) {
        final resolvedInterest = await _resolveAmounts(
          debtCurrency: effectiveDebtCurr,
          sourceMinor: effInterest.storageMinor,
          fundingAssetId: fundingAssetId,
          explicitFundingAmount: fundingInterestAmount,
          rates: rates,
        );
        final iSpec = buildInterestRecordSpec(
          debtSubType: debt.subType,
          debtId: debtId,
          fundingAssetId: fundingAssetId,
          interestExcludeBudget: interestExcludeBudget,
        );
        final iId = _uuid.v4();
        primaryId ??= iId;
        companions.add(
          RecordsCompanion(
            recordId: Value(iId),
            type: Value(iSpec.type),
            subType: Value(iSpec.subType),
            moneyMinor: Value(resolvedInterest.recordMoneyMinor),
            remark: Value(trimmedRemark),
            recordTime: Value(interestRecordTimestamp(operateDate)),
            recordCatId: const Value(noRef),
            assetId: const Value(noRef),
            fromAssetId: Value(iSpec.fromAssetId),
            toAssetId: Value(iSpec.toAssetId),
            accountBookId: Value(bookId),
            excludeBudget: Value(iSpec.excludeBudget),
            excludeExIn: const Value(false),
            extraInfo: Value(resolvedInterest.extraInfo),
            createDate: Value(now),
          ),
        );
      }

      final afterFacts = companions.map(_factsOfCompanion).toList();
      await _applyNet(netEffects(after: afterFacts));
      await _touchAssets(afterFacts);
      for (final c in companions) {
        await db.into(db.records).insert(c);
      }

      // R2: Pure interest (principal == 0 && interest > 0) MUST NOT recompute principal!
      if (!principal.isZero) {
        await _recomputeAndSaveDebt(debtId);
      }
      return primaryId!;
    },
    (id) => id,
  );

  /// Updates an existing single debt record (`type` in `{5, 6, 7, 8, 10}`),
  /// reversing old funding delta and applying new funding delta via `netEffects`.
  Future<void> updateDebtRecord({
    required String commandId,
    required String recordId,
    required Money amount,
    int? operateDate,
    int? fundingAssetId,
    Money? fundingAmount,
    int? bookId,
    bool? interestExcludeBudget,
    String? remark,
  }) => _command(
    commandId,
    [
      'debt-update-record-v1',
      recordId,
      amount.toJson(),
      operateDate,
      fundingAssetId,
      fundingAmount?.toJson(),
      bookId,
      interestExcludeBudget,
      remark,
    ],
    () async {
      _validatePositiveMoney(amount, '流水金额须大于 0');
      final old = await _requireDebtRecord(recordId);
      final debt = await _findAssociatedDebt(old);
      final nextBookId = bookId ?? old.accountBookId;
      await _requireBook(nextBookId);

      final oldFundingId = _extractFundingAssetId(old, debt.id);
      final nextFundingId = fundingAssetId ?? oldFundingId;
      final effectiveDebtCurr =
          normalizeCurrency(debt.currency) ?? baseCurrency;
      final rates = await _loadValidatedRates({effectiveDebtCurr});
      final resolved = await _resolveAmounts(
        debtCurrency: effectiveDebtCurr,
        sourceMinor: amount.storageMinor,
        fundingAssetId: nextFundingId,
        explicitFundingAmount: fundingAmount,
        rates: rates,
      );

      final int nextFrom;
      final int nextTo;
      final bool nextExcludeBudget;
      if (old.type == RecordType.debtInterest) {
        final spec = buildInterestRecordSpec(
          debtSubType: debt.subType,
          debtId: debt.id,
          fundingAssetId: nextFundingId,
          interestExcludeBudget: interestExcludeBudget ?? old.excludeBudget,
        );
        nextFrom = spec.fromAssetId;
        nextTo = spec.toAssetId;
        nextExcludeBudget = spec.excludeBudget;
      } else {
        final isRepay =
            old.type == RecordType.repay || old.type == RecordType.collect;
        final spec = buildPrincipalRecordSpec(
          debtSubType: debt.subType,
          debtId: debt.id,
          fundingAssetId: nextFundingId,
          isRepayment: isRepay,
        );
        nextFrom = spec.fromAssetId;
        nextTo = spec.toAssetId;
        nextExcludeBudget = old.excludeBudget;
      }

      final int nextRecordTime;
      if (operateDate == null) {
        nextRecordTime = old.recordTime;
      } else if (old.type == RecordType.debtInterest) {
        nextRecordTime = interestRecordTimestamp(operateDate);
      } else {
        nextRecordTime = principalRecordTimestamp(operateDate);
      }

      final nextRemark = remark == null ? old.remark : _normalizeRemark(remark);

      final updated = RecordsCompanion(
        recordId: Value(old.recordId),
        type: Value(old.type),
        subType: Value(old.subType),
        moneyMinor: Value(resolved.recordMoneyMinor),
        remark: Value(nextRemark),
        recordTime: Value(nextRecordTime),
        recordCatId: Value(old.recordCatId),
        assetId: Value(old.assetId),
        fromAssetId: Value(nextFrom),
        toAssetId: Value(nextTo),
        accountBookId: Value(nextBookId),
        excludeBudget: Value(nextExcludeBudget),
        excludeExIn: Value(old.excludeExIn),
        extraInfo: Value(resolved.extraInfo),
        relInfo: Value(old.relInfo),
        createDate: Value(old.createDate ?? _now()),
      );

      await _applyNet(
        netEffects(before: [factsOf(old)], after: [_factsOfCompanion(updated)]),
      );
      await db.into(db.records).insertOnConflictUpdate(updated);

      if (old.type != RecordType.debtInterest) {
        await _recomputeAndSaveDebt(debt.id);
      }
      return old.recordId;
    },
    (_) {},
  );

  /// Deletes a single debt record (`{5, 6, 7, 8, 10}`), reversing its funding
  /// account effect via `netEffects(before: ...)` (`ASYM-DM-02`) and
  /// recomputing debt principal when a principal record was deleted.
  Future<void> deleteDebtRecord({
    required String commandId,
    required String recordId,
  }) => _command(commandId, ['debt-delete-record-v1', recordId], () async {
    final old = await _requireDebtRecord(recordId);
    final debt = await _findAssociatedDebtOrNull(old);

    await _applyNet(netEffects(before: [factsOf(old)]));
    await (db.delete(
      db.tagRecords,
    )..where((t) => t.recordId.equals(recordId))).go();
    await (db.delete(
      db.records,
    )..where((t) => t.recordId.equals(recordId))).go();

    if (debt != null && old.type != RecordType.debtInterest) {
      await _recomputeAndSaveDebt(debt.id);
    }
    return recordId;
  }, (_) {});

  /// Manually marks a debt project as settled (`status = 2, balanceMinor = 0,
  /// loan_info.s = true`) without creating a synthetic record (`ASYM-DM-01`).
  Future<void> settleDebt({required String commandId, required int debtId}) =>
      _command(commandId, ['debt-manual-settle-v1', debtId], () async {
        final debt = await _requireDebt(debtId);
        final info = LoanInfo.parse(debt.loanInfo);
        final snapshot = debt.balanceMinor > BigInt.zero
            ? debt.balanceMinor
            : (info.settledSnapshotMinor ?? BigInt.zero);
        final updatedInfo = info.copyWith(
          schemaVersion: 2,
          manualSettled: true,
          settledSnapshotMinor: snapshot,
          settledCurrencyCode: normalizeCurrency(debt.currency) ?? baseCurrency,
          settledAtMs: _now(),
        );

        await (db.update(db.assets)..where((t) => t.id.equals(debtId))).write(
          AssetsCompanion(
            status: const Value(AssetStatus.settled),
            balanceMinor: Value(BigInt.zero),
            loanInfo: Value(updatedInfo.encode()),
          ),
        );
        return '$debtId';
      }, (_) {});

  /// Explicitly reopens a manually settled debt (`allowReopen: true`),
  /// restoring its remaining principal from live `{5, 6, 7, 8}` records.
  Future<void> reopenDebt({required String commandId, required int debtId}) =>
      _command(commandId, ['debt-reopen-v1', debtId], () async {
        await _requireDebt(debtId);
        await _recomputeAndSaveDebt(debtId, allowReopen: true);
        return '$debtId';
      }, (_) {});

  /// Recalibrates debt balance from live `{5, 6, 7, 8}` records while strictly
  /// preserving manual-settlement lock (`ASYM-DM-01`).
  Future<void> recalibrateDebt({
    required String commandId,
    required int debtId,
  }) => _command(commandId, ['debt-recalibrate-v1', debtId], () async {
    await _requireDebt(debtId);
    await _recomputeAndSaveDebt(debtId, allowReopen: false);
    return '$debtId';
  }, (_) {});

  /// Deletes an entire debt project and all its associated records, reversing
  /// funding account balances strictly via `netEffects(before: ...)` (R5 /
  /// `ASYM-DM-02`).
  Future<void> deleteDebt({required String commandId, required int debtId}) =>
      _command(commandId, ['debt-delete-project-v1', debtId], () async {
        await _requireDebt(debtId);
        final rows = await db
            .customSelect(
              'SELECT * FROM record '
              'WHERE asset_id = ?1 OR from_asset_id = ?1 OR to_asset_id = ?1',
              variables: [Variable.withInt(debtId)],
            )
            .get();
        final records = [for (final r in rows) db.records.map(r.data)];

        await _applyNet(
          netEffects(before: records.map(factsOf)),
          skipDebtId: debtId,
        );

        for (final r in records) {
          await (db.delete(
            db.tagRecords,
          )..where((t) => t.recordId.equals(r.recordId))).go();
          await (db.delete(
            db.records,
          )..where((t) => t.recordId.equals(r.recordId))).go();
        }
        await (db.delete(
          db.assetBooks,
        )..where((t) => t.assetId.equals(debtId))).go();
        await (db.delete(db.assets)..where((t) => t.id.equals(debtId))).go();
        return '$debtId';
      }, (_) {});

  // ---- Internal helpers ----

  Future<void> _recomputeAndSaveDebt(
    int debtId, {
    bool allowReopen = false,
  }) async {
    final debt = await _requireDebt(debtId);
    final rows = await db
        .customSelect(
          'SELECT * FROM record '
          'WHERE (from_asset_id = ?1 OR to_asset_id = ?1) '
          'AND type IN (5, 6, 7, 8) '
          'ORDER BY record_time ASC, create_date ASC, record_id ASC',
          variables: [Variable.withInt(debtId)],
        )
        .get();
    final entries = [
      for (final row in rows) _toDebtRecordEntry(db.records.map(row.data)),
    ];
    final currencies = await db.select(db.currencies).get();
    final rates = RateTable({
      for (final c in currencies) c.code: c.rateToAnchor,
    });

    final currentInfo = LoanInfo.parse(debt.loanInfo);
    final result = recomputeDebtPrincipal(
      debtSubType: debt.subType,
      currentStatus: debt.status,
      currentLoanInfo: currentInfo,
      records: entries,
      debtCurrency: debt.currency,
      rates: rates,
      allowReopen: allowReopen,
      nowMs: _now(),
    );

    await (db.update(db.assets)..where((t) => t.id.equals(debtId))).write(
      AssetsCompanion(
        balanceMinor: Value(result.balanceMinor),
        status: Value(result.status),
        loanInfo: Value(result.loanInfo.encode()),
      ),
    );
  }

  DebtRecordEntry _toDebtRecordEntry(LedgerRecord r) => DebtRecordEntry(
    recordId: r.recordId,
    type: r.type,
    subType: r.subType,
    moneyMinor: r.moneyMinor,
    recordTime: r.recordTime,
    currency: RecordExtra.parse(r.extraInfo).currency,
  );

  Future<({BigInt recordMoneyMinor, String? extraInfo})> _resolveAmounts({
    required String debtCurrency,
    required BigInt sourceMinor,
    required int fundingAssetId,
    required Money? explicitFundingAmount,
    required RateTable rates,
  }) async {
    final sc = normalizeCurrency(debtCurrency) ?? baseCurrency;
    if (fundingAssetId == noRef) {
      if (sc == baseCurrency) {
        return (recordMoneyMinor: sourceMinor, extraInfo: null);
      }
      final baseMinor = rates.convert(sourceMinor, sc, baseCurrency);
      final extra = RecordExtra()
        ..currency = CurrencySnapshot(
          sourceCode: sc,
          sourceGross: sourceMinor,
          assetCode: sc,
          assetNet: sourceMinor,
          baseCode: baseCurrency,
          baseAmount: baseMinor,
        );
      return (recordMoneyMinor: sourceMinor, extraInfo: extra.encode());
    }

    final funding = await _requireFundingAccount(fundingAssetId);
    final ac = normalizeCurrency(funding.currency) ?? baseCurrency;
    await _loadValidatedRates({sc, ac});

    final BigInt fundingMinor;
    if (explicitFundingAmount != null) {
      _validatePositiveMoney(explicitFundingAmount, '入账金额须大于 0');
      fundingMinor = explicitFundingAmount.storageMinor;
    } else if (sc == ac) {
      fundingMinor = sourceMinor;
    } else {
      fundingMinor = rates.convert(sourceMinor, sc, ac);
    }

    if (sc == baseCurrency && ac == baseCurrency) {
      return (recordMoneyMinor: fundingMinor, extraInfo: null);
    }

    final baseMinor = sc == baseCurrency
        ? sourceMinor
        : ac == baseCurrency
        ? fundingMinor
        : rates.convert(sourceMinor, sc, baseCurrency);

    final extra = RecordExtra()
      ..currency = CurrencySnapshot(
        sourceCode: sc,
        sourceGross: sourceMinor,
        assetCode: ac,
        assetNet: fundingMinor,
        baseCode: baseCurrency,
        baseAmount: baseMinor,
      );
    return (recordMoneyMinor: fundingMinor, extraInfo: extra.encode());
  }

  Future<RateTable> _loadValidatedRates(Set<String> requiredCodes) async {
    final rows = await db.select(db.currencies).get();
    final byCode = <String, Currency>{
      for (final r in rows)
        if (normalizeCurrency(r.code) != null) normalizeCurrency(r.code)!: r,
    };
    for (final code in requiredCodes) {
      final norm = normalizeCurrency(code) ?? baseCurrency;
      if (norm == baseCurrency) continue;
      final row = byCode[norm];
      if (row == null) {
        throw Failure(FailureCode.validation, '缺少币种汇率：$norm');
      }
      final parsed = DecimalValue.parse(row.rateToAnchor);
      if (parsed.coefficient <= BigInt.zero) {
        throw Failure(FailureCode.validation, '币种汇率无效：$norm');
      }
    }
    return RateTable({for (final r in rows) r.code: r.rateToAnchor});
  }

  void _validateSubType(int subType) {
    if (subType != AssetType.debtLend && subType != AssetType.debtBorrow) {
      throw const Failure(FailureCode.validation, '借贷类型无效');
    }
  }

  String _validateDebtName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.length > 50) {
      throw const Failure(FailureCode.validation, '借贷对象名称须为 1–50 字');
    }
    return trimmed;
  }

  void _validatePositiveMoney(Money m, String message) {
    if (m.scale != Money.ledgerScale) {
      throw const Failure(FailureCode.scaleMismatch, '金额须为两位小数');
    }
    if (m.units <= BigInt.zero) {
      throw Failure(FailureCode.validation, message);
    }
    if (m.units > _maxAmountMinor) {
      throw const Failure(FailureCode.validation, '金额不能超过 88888888888.00');
    }
  }

  void _validateNonNegativeMoney(Money m, String message) {
    if (m.scale != Money.ledgerScale) {
      throw const Failure(FailureCode.scaleMismatch, '金额须为两位小数');
    }
    if (m.isNegative) {
      throw Failure(FailureCode.validation, message);
    }
    if (m.units > _maxAmountMinor) {
      throw const Failure(FailureCode.validation, '金额不能超过 88888888888.00');
    }
  }

  void _validateDates(int startDate, int endDate) {
    if (endDate != noRef && endDate < startDate) {
      throw const Failure(FailureCode.validation, '到期日期不能早于借款日期');
    }
  }

  String _normalizeRemark(String? remark) {
    final t = (remark ?? '').trim();
    if (t.length > 2000) {
      throw const Failure(FailureCode.validation, '备注过长');
    }
    return t;
  }

  List<int> _resolveBookIds(int primaryBookId, List<int>? bookIds) {
    final ordered = <int>[];
    final candidates = (bookIds != null && bookIds.isNotEmpty)
        ? bookIds
        : <int>[primaryBookId];
    for (final id in candidates) {
      if (!ordered.contains(id)) ordered.add(id);
    }
    if (ordered.isEmpty) {
      throw const Failure(FailureCode.validation, '请至少选择一个关联账本');
    }
    return ordered;
  }

  Future<AccountBook> _requireBook(int bookId) async {
    final book = await (db.select(
      db.accountBooks,
    )..where((t) => t.id.equals(bookId))).getSingleOrNull();
    if (book == null) throw const Failure(FailureCode.validation, '账本不存在');
    return book;
  }

  Future<Asset> _requireDebt(int debtId) async {
    final asset = await (db.select(
      db.assets,
    )..where((t) => t.id.equals(debtId))).getSingleOrNull();
    if (asset == null || asset.type != AssetType.debt) {
      throw const Failure(FailureCode.validation, '借贷项目不存在');
    }
    return asset;
  }

  Future<Asset> _requireFundingAccount(int assetId) async {
    final asset = await (db.select(
      db.assets,
    )..where((t) => t.id.equals(assetId))).getSingleOrNull();
    if (asset == null) throw const Failure(FailureCode.validation, '资金账户不存在');
    if (asset.type == AssetType.debt) {
      throw const Failure(FailureCode.validation, '不能选择借贷账户作为资金账户');
    }
    return asset;
  }

  Future<Asset> _existingAsset(int assetId) async {
    final asset = await (db.select(
      db.assets,
    )..where((t) => t.id.equals(assetId))).getSingleOrNull();
    if (asset == null) throw const Failure(FailureCode.validation, '账户不存在');
    return asset;
  }

  Future<LedgerRecord> _requireDebtRecord(String recordId) async {
    final rec = await (db.select(
      db.records,
    )..where((t) => t.recordId.equals(recordId))).getSingleOrNull();
    if (rec == null) {
      throw const Failure(FailureCode.conflict, '借贷流水不存在或已删除');
    }
    if (!const {
      RecordType.borrowIn,
      RecordType.lendOut,
      RecordType.repay,
      RecordType.collect,
      RecordType.debtInterest,
    }.contains(rec.type)) {
      throw const Failure(FailureCode.validation, '该记录不是借贷流水');
    }
    return rec;
  }

  Future<Asset> _findAssociatedDebt(LedgerRecord rec) async {
    final debt = await _findAssociatedDebtOrNull(rec);
    if (debt == null) {
      throw const Failure(FailureCode.validation, '未找到关联的借贷项目');
    }
    return debt;
  }

  Future<Asset?> _findAssociatedDebtOrNull(LedgerRecord rec) async {
    for (final candidateId in [rec.fromAssetId, rec.toAssetId]) {
      if (candidateId == noRef) continue;
      final a = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(candidateId))).getSingleOrNull();
      if (a != null && a.type == AssetType.debt) return a;
    }
    return null;
  }

  int _extractFundingAssetId(LedgerRecord rec, int debtId) {
    if (rec.type == RecordType.borrowIn ||
        rec.type == RecordType.collect ||
        (rec.type == RecordType.debtInterest &&
            rec.subType == RecordDirection.income)) {
      return rec.toAssetId == debtId ? noRef : rec.toAssetId;
    }
    return rec.fromAssetId == debtId ? noRef : rec.fromAssetId;
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

  Future<void> _applyNet(Map<int, BigInt> net, {int? skipDebtId}) async {
    for (final entry in net.entries) {
      if (entry.key == skipDebtId) continue;
      final asset = await _existingAsset(entry.key);
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
}
