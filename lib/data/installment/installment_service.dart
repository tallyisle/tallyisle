import 'dart:async';
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
import '../../domain/rules/currency_rates.dart' show baseCurrency, billSnapshot;
import '../../domain/rules/installment_rules.dart';
import '../db/database.dart';
import '../db/failures.dart';
import '../ledger/ledger_service.dart' show factsOf;

const _uuid = Uuid();

final class _AsyncMutex {
  Future<void> _tail = Future<void>.value();

  Future<T> synchronized<T>(Future<T> Function() action) {
    final prev = _tail;
    final completer = Completer<void>();
    _tail = completer.future;
    return prev.then((_) => action()).whenComplete(() {
      if (!completer.isCompleted) completer.complete();
    });
  }
}

/// Creation payload for a new installment plan (F-010).
final class InstallmentDraft {
  const InstallmentDraft({
    required this.name,
    this.catId = noRef,
    required this.principal,
    required this.periods,
    required this.charge,
    this.chargeWay = InstallmentChargeWay.perPeriod,
    this.calWay = InstallmentCalWay.halfUp2,
    this.remainderIn = InstallmentRemainderIn.firstPeriod,
    required this.startDateMs,
    required this.assetId,
    required this.bookId,
    this.excludeBudget = false,
    this.excludeExIn = false,
    this.tagIds = const [],
    this.images,
    this.principalCounted = true,
    this.interestCounted = false,
    this.catchUpDueNow = false,
  });

  final String name;
  final int catId;
  final Money principal;
  final int periods;
  final Money charge;
  final int chargeWay;
  final int calWay;
  final int remainderIn;
  final int startDateMs;
  final int assetId;
  final int bookId;
  final bool excludeBudget;
  final bool excludeExIn;
  final List<String> tagIds;
  final String? images;
  final bool principalCounted;
  final bool interestCounted;
  final bool catchUpDueNow;

  List<Object?> get payload => [
    name,
    catId,
    principal.toJson(),
    periods,
    charge.toJson(),
    chargeWay,
    calWay,
    remainderIn,
    startDateMs,
    assetId,
    bookId,
    excludeBudget,
    excludeExIn,
    tagIds,
    images,
    principalCounted,
    interestCounted,
    catchUpDueNow,
  ];
}

/// Summary returned by [InstallmentService.runCatchUp].
final class InstallmentCatchUpResult {
  const InstallmentCatchUpResult({
    required this.postedPeriodsCount,
    required this.createdRecordIds,
    required this.skippedInstallmentIds,
  });

  final int postedPeriodsCount;
  final List<String> createdRecordIds;
  final List<int> skippedInstallmentIds;
}

/// Write & scheduling service for installments (F-010, ADR-009, ADR-012).
final class InstallmentService {
  InstallmentService(this.db);
  final AppDatabase db;

  static final Expando<_AsyncMutex> _mutexes = Expando<_AsyncMutex>(
    'InstallmentServiceMutex',
  );

  _AsyncMutex get _mutex => _mutexes[db] ??= _AsyncMutex();

  int _now() => db.nowMs();

  Future<T> _command<T>(
    String commandId,
    List<Object?> payload,
    Future<String> Function() body,
    T Function(String resultId) result,
  ) {
    if (commandId.isEmpty || commandId.length > 128) {
      return Future<T>.error(const Failure(FailureCode.validation, '提交标识无效'));
    }
    final hash = sha256.convert(utf8.encode(jsonEncode(payload))).toString();
    return _mutex.synchronized(
      () => guardDatabase(
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
      ),
    );
  }

  /// Creates a new installment plan and synchronizes credit-card liability.
  Future<int> createInstallment({
    required String commandId,
    required InstallmentDraft draft,
  }) => _command(
    commandId,
    ['installment-create-v1', ...draft.payload],
    () async {
      validateInstallmentInput(
        name: draft.name,
        principal: draft.principal,
        periods: draft.periods,
        charge: draft.charge,
        chargeWay: draft.chargeWay,
        calWay: draft.calWay,
        remainderIn: draft.remainderIn,
        assetId: draft.assetId,
      );
      await _validateBookAndCategory(draft.bookId, draft.catId);
      final asset = await _requireUsableAsset(
        draft.assetId,
        allowHidden: false,
      );

      final firstPlannedMs = installmentPeriodDateMs(draft.startDateMs, 1);
      final extra = InstallmentExtra()
        ..principalCounted = draft.principalCounted
        ..interestCounted = draft.interestCounted;

      final id = await db
          .into(db.installments)
          .insert(
            InstallmentsCompanion.insert(
              name: draft.name.trim(),
              catId: Value(draft.catId),
              principalMinor: draft.principal.storageMinor,
              periods: draft.periods,
              chargeMinor: draft.charge.storageMinor,
              chargeWay: draft.chargeWay,
              remainderIn: draft.remainderIn,
              calWay: draft.calWay,
              startDate: firstPlannedMs,
              assetId: draft.assetId,
              nextPeriod: 1,
              nextPeriodDate: firstPlannedMs,
              credited: const Value('[]'),
              bookId: draft.bookId,
              excludeBudget: Value(draft.excludeBudget),
              excludeExIn: Value(draft.excludeExIn),
              createDate: _now(),
              tags: Value(encodeInstallmentTags(draft.tagIds)),
              images: Value(draft.images),
              exi: Value(extra.encode()),
            ),
          );

      if (asset.type == AssetType.credit) {
        final updatedCredit = syncCreditInfoInstallment(
          currentCreditInfoJson: asset.creditInfo,
          installmentId: id,
          remainingPrincipalMinor: draft.principal.storageMinor,
          remainingFeeMinor: draft.charge.storageMinor,
          isFinished: false,
          principalCounted: draft.principalCounted,
          interestCounted: draft.interestCounted,
        );
        await (db.update(db.assets)..where((t) => t.id.equals(asset.id))).write(
          AssetsCompanion(creditInfo: Value(updatedCredit)),
        );
      }

      if (draft.catchUpDueNow) {
        await _catchUpSingleInTx(id, _now());
      }

      return '$id';
    },
    int.parse,
  );

  /// Updates installment metadata and credit-card `cb`/`ci` flags.
  Future<void> updateInstallment({
    required String commandId,
    required int installmentId,
    required String name,
    required int catId,
    required int bookId,
    required bool excludeBudget,
    required bool excludeExIn,
    List<String> tagIds = const [],
    String? images,
    bool? principalCounted,
    bool? interestCounted,
  }) => _command(
    commandId,
    [
      'installment-update-v1',
      installmentId,
      name,
      catId,
      bookId,
      excludeBudget,
      excludeExIn,
      tagIds,
      images,
      principalCounted,
      interestCounted,
    ],
    () async {
      final inst = await _requireInstallment(installmentId);
      final trimmed = name.trim();
      if (trimmed.isEmpty || trimmed.length > 50) {
        throw const Failure(FailureCode.validation, '分期名称须为 1–50 字');
      }
      await _validateBookAndCategory(bookId, catId);

      final extra = InstallmentExtra.parse(inst.exi);
      if (principalCounted != null) extra.principalCounted = principalCounted;
      if (interestCounted != null) extra.interestCounted = interestCounted;

      await (db.update(
        db.installments,
      )..where((t) => t.id.equals(installmentId))).write(
        InstallmentsCompanion(
          name: Value(trimmed),
          catId: Value(catId),
          bookId: Value(bookId),
          excludeBudget: Value(excludeBudget),
          excludeExIn: Value(excludeExIn),
          tags: Value(encodeInstallmentTags(tagIds)),
          images: images == null ? const Value.absent() : Value(images),
          exi: Value(extra.encode()),
        ),
      );

      final asset = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(inst.assetId))).getSingleOrNull();
      if (asset != null && asset.type == AssetType.credit) {
        final credited = parseCreditedPeriods(
          inst.credited,
          maxPeriod: inst.periods,
        );
        final schedule = buildInstallmentSchedule(
          installmentId: inst.id,
          principalMinor: inst.principalMinor,
          periods: inst.periods,
          chargeMinor: inst.chargeMinor,
          chargeWay: inst.chargeWay,
          calWay: inst.calWay,
          remainderIn: inst.remainderIn,
          startDateMs: inst.startDate,
          creditedPeriods: credited,
        );
        final progress = computeInstallmentProgress(
          schedule: schedule,
          principalMinor: inst.principalMinor,
          chargeMinor: inst.chargeMinor,
          startDateMs: inst.startDate,
          currentNextPeriod: inst.nextPeriod,
        );
        final updatedCredit = syncCreditInfoInstallment(
          currentCreditInfoJson: asset.creditInfo,
          installmentId: inst.id,
          remainingPrincipalMinor: progress.remainingPrincipalMinor,
          remainingFeeMinor: progress.remainingFeeMinor,
          isFinished: progress.isFinished,
          principalCounted: extra.principalCounted,
          interestCounted: extra.interestCounted,
        );
        await (db.update(db.assets)..where((t) => t.id.equals(asset.id))).write(
          AssetsCompanion(creditInfo: Value(updatedCredit)),
        );
      }

      return '$installmentId';
    },
    (_) {},
  );

  /// Manually posts a single period ("本期入账" when [period] is null, or
  /// out-of-order early single-period posting when [period] is specified).
  ///
  /// Also safely supports re-posting if a previously credited period's live
  /// records were all externally deleted (ASYM-INST-03).
  Future<List<String>> postPeriod({
    required String commandId,
    required int installmentId,
    int? period,
    int? recordTimeMs,
  }) => _command(
    commandId,
    ['installment-post-period-v1', installmentId, period, recordTimeMs],
    () async {
      final inst = await _requireInstallment(installmentId);
      final credited = parseCreditedPeriods(
        inst.credited,
        maxPeriod: inst.periods,
      );
      final targetPeriod = period ?? inst.nextPeriod;
      if (targetPeriod < 1 || targetPeriod > inst.periods) {
        throw const Failure(FailureCode.validation, '该分期已全部入账');
      }

      final alreadyCredited = credited.contains(targetPeriod);
      if (alreadyCredited) {
        final existingLive = await _liveRecordsForPeriod(inst.id, targetPeriod);
        if (existingLive.isNotEmpty) {
          throw const Failure(FailureCode.conflict, '该期已入账，请勿重复入账');
        }
      }

      final asset = await _requireActiveAssetForPosting(inst.assetId);
      final rates = await _loadRateTableForAsset(asset, strict: true);
      if (rates == null) {
        final code = normalizeCurrency(asset.currency) ?? baseCurrency;
        throw Failure(FailureCode.validation, '请先设置 $code 汇率');
      }

      final schedule = buildInstallmentSchedule(
        installmentId: inst.id,
        principalMinor: inst.principalMinor,
        periods: inst.periods,
        chargeMinor: inst.chargeMinor,
        chargeWay: inst.chargeWay,
        calWay: inst.calWay,
        remainderIn: inst.remainderIn,
        startDateMs: inst.startDate,
        creditedPeriods: credited,
      );
      final item = schedule[targetPeriod - 1];
      final effectiveTime =
          recordTimeMs ?? (alreadyCredited ? item.plannedDateMs : _now());

      final createdIds = await _insertPeriodBillsInTx(
        inst: inst,
        asset: asset,
        rates: rates,
        period: targetPeriod,
        principalMinor: item.principalMinor,
        feeMinor: item.feeMinor,
        recordTimeMs: effectiveTime,
        principalRemark: '${inst.name} ($targetPeriod/${inst.periods}期)',
        feeRemark: '${inst.name} ($targetPeriod/${inst.periods}期手续费)',
      );

      if (!alreadyCredited) {
        final newCredited = {...credited, targetPeriod}.toList()..sort();
        final updatedSchedule = buildInstallmentSchedule(
          installmentId: inst.id,
          principalMinor: inst.principalMinor,
          periods: inst.periods,
          chargeMinor: inst.chargeMinor,
          chargeWay: inst.chargeWay,
          calWay: inst.calWay,
          remainderIn: inst.remainderIn,
          startDateMs: inst.startDate,
          creditedPeriods: newCredited,
        );
        final progress = computeInstallmentProgress(
          schedule: updatedSchedule,
          principalMinor: inst.principalMinor,
          chargeMinor: inst.chargeMinor,
          startDateMs: inst.startDate,
          currentNextPeriod: inst.nextPeriod,
        );

        await (db.update(
          db.installments,
        )..where((t) => t.id.equals(inst.id))).write(
          InstallmentsCompanion(
            credited: Value(
              encodeCreditedPeriods(newCredited, maxPeriod: inst.periods),
            ),
            nextPeriod: Value(progress.nextPeriod),
            nextPeriodDate: Value(progress.nextPeriodDateMs),
          ),
        );

        await _syncCreditAssetInTx(
          assetId: inst.assetId,
          installmentId: inst.id,
          exi: inst.exi,
          remainingPrincipalMinor: progress.remainingPrincipalMinor,
          remainingFeeMinor: progress.remainingFeeMinor,
          isFinished: progress.isFinished,
        );
      }

      return jsonEncode(createdIds);
    },
    (raw) => (jsonDecode(raw) as List<Object?>).cast<String>(),
  );

  /// Runs automatic catch-up across all active installments due on or before
  /// [now] (serialized by async mutex; skips missing/inactive accounts safely).
  Future<InstallmentCatchUpResult> runCatchUp({DateTime? now}) =>
      _mutex.synchronized(
        () => guardDatabase(() async {
          final nowMs = now?.millisecondsSinceEpoch ?? _now();
          final active =
              await (db.select(db.installments)
                    ..where((t) => t.nextPeriod.isSmallerOrEqual(t.periods))
                    ..orderBy([(t) => OrderingTerm.asc(t.id)]))
                  .get();

          var postedCount = 0;
          final recordIds = <String>[];
          final skippedIds = <int>[];

          for (final row in active) {
            await db.transaction(() async {
              final outcome = await _catchUpSingleInTx(row.id, nowMs);
              postedCount += outcome.postedCount;
              recordIds.addAll(outcome.recordIds);
              if (outcome.skipped) {
                skippedIds.add(row.id);
              }
            });
          }

          return InstallmentCatchUpResult(
            postedPeriodsCount: postedCount,
            createdRecordIds: List<String>.unmodifiable(recordIds),
            skippedInstallmentIds: List<int>.unmodifiable(skippedIds),
          );
        }),
      );

  Future<({int postedCount, List<String> recordIds, bool skipped})>
  _catchUpSingleInTx(int installmentId, int nowMs) async {
    final inst = await (db.select(
      db.installments,
    )..where((t) => t.id.equals(installmentId))).getSingleOrNull();
    if (inst == null || inst.nextPeriod > inst.periods) {
      return (postedCount: 0, recordIds: const <String>[], skipped: false);
    }

    final asset = await (db.select(
      db.assets,
    )..where((t) => t.id.equals(inst.assetId))).getSingleOrNull();
    if (asset == null || asset.status != AssetStatus.active) {
      return (postedCount: 0, recordIds: const <String>[], skipped: true);
    }

    final rates = await _loadRateTableForAsset(asset, strict: true);
    if (rates == null) {
      return (postedCount: 0, recordIds: const <String>[], skipped: true);
    }

    final creditedSet = parseCreditedPeriods(
      inst.credited,
      maxPeriod: inst.periods,
    ).toSet();
    final baseSchedule = buildInstallmentSchedule(
      installmentId: inst.id,
      principalMinor: inst.principalMinor,
      periods: inst.periods,
      chargeMinor: inst.chargeMinor,
      chargeWay: inst.chargeWay,
      calWay: inst.calWay,
      remainderIn: inst.remainderIn,
      startDateMs: inst.startDate,
      creditedPeriods: creditedSet,
    );

    var cursor = advanceNextPeriod(
      currentNextPeriod: inst.nextPeriod,
      periods: inst.periods,
      creditedPeriods: creditedSet,
      startDateMs: inst.startDate,
    );

    var postedCount = 0;
    final createdIds = <String>[];

    while (!cursor.isFinished) {
      final period = cursor.nextPeriod;
      final plannedMs = cursor.nextPeriodDateMs;
      if (!isPeriodDueOnOrBefore(plannedDateMs: plannedMs, nowMs: nowMs)) {
        break;
      }

      final item = baseSchedule[period - 1];
      final recordTimeMs = dueRecordTimestampMs(
        plannedDateMs: plannedMs,
        nowMs: nowMs,
      );
      final freshAsset = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(inst.assetId))).getSingle();

      final ids = await _insertPeriodBillsInTx(
        inst: inst,
        asset: freshAsset,
        rates: rates,
        period: period,
        principalMinor: item.principalMinor,
        feeMinor: item.feeMinor,
        recordTimeMs: recordTimeMs,
        principalRemark: '${inst.name} ($period/${inst.periods}期)',
        feeRemark: '${inst.name} ($period/${inst.periods}期手续费)',
      );
      createdIds.addAll(ids);
      postedCount++;
      creditedSet.add(period);

      cursor = advanceNextPeriod(
        currentNextPeriod: period,
        periods: inst.periods,
        creditedPeriods: creditedSet,
        startDateMs: inst.startDate,
      );
    }

    if (postedCount > 0 ||
        cursor.nextPeriod != inst.nextPeriod ||
        cursor.nextPeriodDateMs != inst.nextPeriodDate) {
      final updatedSchedule = buildInstallmentSchedule(
        installmentId: inst.id,
        principalMinor: inst.principalMinor,
        periods: inst.periods,
        chargeMinor: inst.chargeMinor,
        chargeWay: inst.chargeWay,
        calWay: inst.calWay,
        remainderIn: inst.remainderIn,
        startDateMs: inst.startDate,
        creditedPeriods: creditedSet,
      );
      final progress = computeInstallmentProgress(
        schedule: updatedSchedule,
        principalMinor: inst.principalMinor,
        chargeMinor: inst.chargeMinor,
        startDateMs: inst.startDate,
        currentNextPeriod: cursor.nextPeriod,
      );

      await (db.update(
        db.installments,
      )..where((t) => t.id.equals(inst.id))).write(
        InstallmentsCompanion(
          credited: Value(
            encodeCreditedPeriods(creditedSet, maxPeriod: inst.periods),
          ),
          nextPeriod: Value(progress.nextPeriod),
          nextPeriodDate: Value(progress.nextPeriodDateMs),
        ),
      );

      await _syncCreditAssetInTx(
        assetId: inst.assetId,
        installmentId: inst.id,
        exi: inst.exi,
        remainingPrincipalMinor: progress.remainingPrincipalMinor,
        remainingFeeMinor: progress.remainingFeeMinor,
        isFinished: progress.isFinished,
      );
    }

    return (postedCount: postedCount, recordIds: createdIds, skipped: false);
  }

  /// Settles all remaining uncredited periods in one atomic transaction:
  /// posts remaining principal + optional waived/custom remaining fee, closes
  /// remaining periods, and removes uncredited liability from `CreditInfo`.
  Future<List<String>> settleEarly({
    required String commandId,
    required int installmentId,
    Money? settlementFee,
    int? recordTimeMs,
    String? remark,
  }) => _command(
    commandId,
    [
      'installment-settle-early-v1',
      installmentId,
      settlementFee?.toJson(),
      recordTimeMs,
      remark,
    ],
    () async {
      final inst = await _requireInstallment(installmentId);
      final credited = parseCreditedPeriods(
        inst.credited,
        maxPeriod: inst.periods,
      );
      final schedule = buildInstallmentSchedule(
        installmentId: inst.id,
        principalMinor: inst.principalMinor,
        periods: inst.periods,
        chargeMinor: inst.chargeMinor,
        chargeWay: inst.chargeWay,
        calWay: inst.calWay,
        remainderIn: inst.remainderIn,
        startDateMs: inst.startDate,
        creditedPeriods: credited,
      );
      final progress = computeInstallmentProgress(
        schedule: schedule,
        principalMinor: inst.principalMinor,
        chargeMinor: inst.chargeMinor,
        startDateMs: inst.startDate,
        currentNextPeriod: inst.nextPeriod,
      );

      if (progress.isFinished || progress.remainingCount <= 0) {
        throw const Failure(FailureCode.validation, '该分期已完结，无需提前结清');
      }
      if (settlementFee != null && settlementFee.scale != Money.ledgerScale) {
        throw const Failure(FailureCode.scaleMismatch, '手续费须为两位小数');
      }

      final defaultRemainingFee = progress.remainingFeeMinor > BigInt.zero
          ? progress.remainingFeeMinor
          : BigInt.zero;
      final feeMinor = settlementFee?.storageMinor ?? defaultRemainingFee;
      if (feeMinor < BigInt.zero) {
        throw const Failure(FailureCode.validation, '结清手续费不能为负数');
      }

      final asset = await _requireActiveAssetForPosting(inst.assetId);
      final rates = await _loadRateTableForAsset(asset, strict: true);
      if (rates == null) {
        final code = normalizeCurrency(asset.currency) ?? baseCurrency;
        throw Failure(FailureCode.validation, '请先设置 $code 汇率');
      }

      final settlePeriod = progress.nextPeriod;
      final timeMs = recordTimeMs ?? _now();
      final baseRemark = (remark != null && remark.trim().isNotEmpty)
          ? remark.trim()
          : '${inst.name}（提前结清）';

      final createdIds = await _insertPeriodBillsInTx(
        inst: inst,
        asset: asset,
        rates: rates,
        period: settlePeriod,
        principalMinor: progress.remainingPrincipalMinor,
        feeMinor: feeMinor,
        recordTimeMs: timeMs,
        principalRemark: baseRemark,
        feeRemark: '$baseRemark手续费',
      );

      final allPeriods = [for (var p = 1; p <= inst.periods; p++) p];
      final finishedNext = inst.periods + 1;
      final finishedDateMs = installmentPeriodDateMs(
        inst.startDate,
        finishedNext,
      );

      final waived = progress.remainingFeeMinor - feeMinor;
      final extra = InstallmentExtra.parse(inst.exi)
        ..settledEarly = true
        ..settledAt = timeMs
        ..settledPeriod = settlePeriod
        ..settledPrincipalMinor = progress.remainingPrincipalMinor
        ..settledFeeMinor = feeMinor
        ..waivedFeeMinor = waived > BigInt.zero ? waived : BigInt.zero;

      await (db.update(
        db.installments,
      )..where((t) => t.id.equals(inst.id))).write(
        InstallmentsCompanion(
          credited: Value(
            encodeCreditedPeriods(allPeriods, maxPeriod: inst.periods),
          ),
          nextPeriod: Value(finishedNext),
          nextPeriodDate: Value(finishedDateMs),
          exi: Value(extra.encode()),
        ),
      );

      await _syncCreditAssetInTx(
        assetId: inst.assetId,
        installmentId: inst.id,
        exi: extra.encode(),
        remainingPrincipalMinor: BigInt.zero,
        remainingFeeMinor: BigInt.zero,
        isFinished: true,
        remove: true,
      );

      return jsonEncode(createdIds);
    },
    (raw) => (jsonDecode(raw) as List<Object?>).cast<String>(),
  );

  /// Safely deletes an installment plan:
  /// - Cleans `CreditInfo.installments` if bound to a credit card.
  /// - When [deleteGeneratedRecords] is true, inspects live records in `record`
  ///   (plus any live linked refund/reimbursement children) and reverses only
  ///   live balance effects via `netEffects`, preventing double-refunds.
  Future<void> deleteInstallment({
    required String commandId,
    required int installmentId,
    bool deleteGeneratedRecords = false,
  }) => _command(
    commandId,
    ['installment-delete-v1', installmentId, deleteGeneratedRecords],
    () async {
      final inst = await _requireInstallment(installmentId);

      if (deleteGeneratedRecords) {
        final candidates = await (db.select(
          db.records,
        )..where((t) => t.installment.like('${inst.id}-%'))).get();

        final byId = <String, LedgerRecord>{};
        for (final r in candidates) {
          final parsed = parseInstallmentRecordKey(r.installment);
          if (parsed != null && parsed.installmentId == inst.id) {
            byId[r.recordId] = r;
            final rel = RecordRelations.parse(r.relInfo);
            final childIds = <String>[
              for (final c in rel.refunds?.children ?? const <LinkedBill>[])
                c.billId,
              for (final c
                  in rel.reimbursements?.children ?? const <LinkedBill>[])
                c.billId,
            ];
            for (final cid in childIds) {
              final child = await (db.select(
                db.records,
              )..where((t) => t.recordId.equals(cid))).getSingleOrNull();
              if (child != null) {
                byId[child.recordId] = child;
              }
            }
          }
        }

        if (byId.isNotEmpty) {
          final liveRows = byId.values.toList();
          final net = netEffects(before: liveRows.map(factsOf));
          await _applyNetSafely(net);
          for (final r in liveRows) {
            await (db.delete(
              db.tagRecords,
            )..where((t) => t.recordId.equals(r.recordId))).go();
            await (db.delete(
              db.records,
            )..where((t) => t.recordId.equals(r.recordId))).go();
          }
        }
      }

      await _syncCreditAssetInTx(
        assetId: inst.assetId,
        installmentId: inst.id,
        exi: inst.exi,
        remainingPrincipalMinor: BigInt.zero,
        remainingFeeMinor: BigInt.zero,
        isFinished: true,
        remove: true,
      );

      await (db.delete(
        db.installments,
      )..where((t) => t.id.equals(inst.id))).go();
      return '$installmentId';
    },
    (_) {},
  );

  // ---- internal helpers ----

  Future<Installment> _requireInstallment(int id) async {
    final inst = await (db.select(
      db.installments,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (inst == null) {
      throw const Failure(FailureCode.conflict, '分期计划不存在或已删除');
    }
    return inst;
  }

  Future<void> _validateBookAndCategory(int bookId, int catId) async {
    final book = await (db.select(
      db.accountBooks,
    )..where((t) => t.id.equals(bookId))).getSingleOrNull();
    if (book == null) {
      throw const Failure(FailureCode.validation, '账本不存在');
    }
    if (catId != noRef) {
      final cat = await (db.select(
        db.recordCategories,
      )..where((t) => t.id.equals(catId))).getSingleOrNull();
      if (cat == null ||
          cat.type != RecordType.expense ||
          cat.accountBookId != bookId) {
        throw const Failure(FailureCode.validation, '请选择当前账本的支出分类');
      }
    }
  }

  Future<Asset> _requireUsableAsset(
    int assetId, {
    required bool allowHidden,
  }) async {
    final asset = await (db.select(
      db.assets,
    )..where((t) => t.id.equals(assetId))).getSingleOrNull();
    if (asset == null) {
      throw const Failure(FailureCode.validation, '扣款账户不存在');
    }
    if (asset.type == AssetType.debt) {
      throw const Failure(FailureCode.validation, '借贷账户不支持创建分期');
    }
    if (asset.status == AssetStatus.settled ||
        (!allowHidden && asset.status != AssetStatus.active)) {
      throw const Failure(FailureCode.validation, '所选扣款账户已隐藏或已结清');
    }
    return asset;
  }

  Future<Asset> _requireActiveAssetForPosting(int assetId) async {
    final asset = await (db.select(
      db.assets,
    )..where((t) => t.id.equals(assetId))).getSingleOrNull();
    if (asset == null || asset.status != AssetStatus.active) {
      throw const Failure(FailureCode.validation, '关联账户不存在或不可用');
    }
    return asset;
  }

  Future<RateTable?> _loadRateTableForAsset(
    Asset asset, {
    required bool strict,
  }) async {
    final currencies = await db.select(db.currencies).get();
    final rates = RateTable({
      for (final c in currencies) c.code: c.rateToAnchor,
    });
    final ac = normalizeCurrency(asset.currency) ?? baseCurrency;
    if (ac != baseCurrency && strict) {
      final missing = <String>{};
      final probe = rates.convert(
        BigInt.from(100),
        ac,
        baseCurrency,
        missing: missing,
      );
      if (missing.isNotEmpty || probe <= BigInt.zero) {
        return null;
      }
    }
    return rates;
  }

  Future<List<LedgerRecord>> _liveRecordsForPeriod(
    int installmentId,
    int period,
  ) {
    final key = formatInstallmentRecordKey(installmentId, period);
    return (db.select(
      db.records,
    )..where((t) => t.installment.equals(key))).get();
  }

  Future<List<String>> _insertPeriodBillsInTx({
    required Installment inst,
    required Asset asset,
    required RateTable rates,
    required int period,
    required BigInt principalMinor,
    required BigInt feeMinor,
    required int recordTimeMs,
    required String principalRemark,
    required String feeRemark,
  }) async {
    final instKey = formatInstallmentRecordKey(inst.id, period);
    final ac = normalizeCurrency(asset.currency) ?? baseCurrency;
    final tagIds = parseInstallmentTags(inst.tags);
    final companions = <RecordsCompanion>[];
    final createdIds = <String>[];

    final principalId = _uuid.v4();
    final principalSnap = billSnapshot(
      source: ac,
      sourceMinor: principalMinor,
      account: ac,
      assetMinor: principalMinor,
      rates: rates,
    );
    final principalExtra = principalSnap == null
        ? null
        : (RecordExtra()..currency = principalSnap).encode();

    companions.add(
      RecordsCompanion(
        recordId: Value(principalId),
        type: Value(
          inst.catId == noRef
              ? RecordType.installmentPrincipal
              : RecordType.expense,
        ),
        subType: const Value(RecordDirection.none),
        moneyMinor: Value(principalMinor),
        remark: Value(principalRemark),
        recordTime: Value(recordTimeMs),
        recordCatId: Value(inst.catId),
        assetId: Value(inst.assetId),
        fromAssetId: const Value(noRef),
        toAssetId: const Value(noRef),
        accountBookId: Value(inst.bookId),
        excludeBudget: Value(inst.excludeBudget),
        excludeExIn: Value(inst.excludeExIn),
        installment: Value(instKey),
        images: Value(inst.images),
        extraInfo: Value(principalExtra),
        createDate: Value(_now()),
      ),
    );
    createdIds.add(principalId);

    if (feeMinor != BigInt.zero) {
      final feeId = _uuid.v4();
      final feeSnap = billSnapshot(
        source: ac,
        sourceMinor: feeMinor,
        account: ac,
        assetMinor: feeMinor,
        rates: rates,
      );
      final feeExtra = feeSnap == null
          ? null
          : (RecordExtra()..currency = feeSnap).encode();

      companions.add(
        RecordsCompanion(
          recordId: Value(feeId),
          type: const Value(RecordType.fee),
          subType: const Value(RecordDirection.expense),
          moneyMinor: Value(feeMinor),
          remark: Value(feeRemark),
          recordTime: Value(recordTimeMs),
          recordCatId: const Value(noRef),
          assetId: Value(inst.assetId),
          fromAssetId: const Value(noRef),
          toAssetId: const Value(noRef),
          accountBookId: Value(inst.bookId),
          excludeBudget: Value(inst.excludeBudget),
          excludeExIn: Value(inst.excludeExIn),
          installment: Value(instKey),
          extraInfo: Value(feeExtra),
          createDate: Value(_now()),
        ),
      );
      createdIds.add(feeId);
    }

    final afterFacts = [for (final c in companions) _factsOfCompanion(c)];
    final net = netEffects(after: afterFacts);
    for (final entry in net.entries) {
      final currentAsset = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(entry.key))).getSingle();
      final nextBalance = Money.minor(currentAsset.balanceMinor + entry.value);
      await (db.update(db.assets)..where((t) => t.id.equals(entry.key))).write(
        AssetsCompanion(
          balanceMinor: Value(nextBalance.storageMinor),
          usedTimes: Value(currentAsset.usedTimes + 1),
        ),
      );
    }

    for (final c in companions) {
      await db.into(db.records).insert(c);
      if (tagIds.isNotEmpty) {
        for (final tagId in tagIds) {
          await db
              .into(db.tagRecords)
              .insert(
                TagRecordsCompanion.insert(
                  tagId: tagId,
                  recordId: c.recordId.value,
                ),
              );
        }
      }
    }

    return createdIds;
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

  Future<void> _applyNetSafely(Map<int, BigInt> net) async {
    for (final entry in net.entries) {
      final asset = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(entry.key))).getSingleOrNull();
      if (asset == null) continue;
      final nextBalance = Money.minor(asset.balanceMinor + entry.value);
      await (db.update(db.assets)..where((t) => t.id.equals(entry.key))).write(
        AssetsCompanion(balanceMinor: Value(nextBalance.storageMinor)),
      );
    }
  }

  Future<void> _syncCreditAssetInTx({
    required int assetId,
    required int installmentId,
    required String? exi,
    required BigInt remainingPrincipalMinor,
    required BigInt remainingFeeMinor,
    required bool isFinished,
    bool remove = false,
  }) async {
    final asset = await (db.select(
      db.assets,
    )..where((t) => t.id.equals(assetId))).getSingleOrNull();
    if (asset == null || asset.type != AssetType.credit) return;

    final extra = InstallmentExtra.parse(exi);
    final updatedCredit = syncCreditInfoInstallment(
      currentCreditInfoJson: asset.creditInfo,
      installmentId: installmentId,
      remainingPrincipalMinor: remainingPrincipalMinor,
      remainingFeeMinor: remainingFeeMinor,
      isFinished: isFinished,
      principalCounted: extra.principalCounted,
      interestCounted: extra.interestCounted,
      remove: remove,
    );
    await (db.update(db.assets)..where((t) => t.id.equals(asset.id))).write(
      AssetsCompanion(creditInfo: Value(updatedCredit)),
    );
  }
}
