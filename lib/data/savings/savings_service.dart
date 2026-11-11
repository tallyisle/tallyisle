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
import '../../domain/rules/asset_overview.dart' show normalizeCurrency;
import '../../domain/rules/currency_rates.dart' show baseCurrency;
import '../../domain/rules/savings_plan.dart';
import '../db/database.dart';
import '../db/failures.dart';
import '../db/seed.dart' show defaultBookId;
import '../ledger/ledger_service.dart' show factsOf;

const _uuid = Uuid();

/// FIFO async mutex ensuring `runAutoSave` executions on the same database
/// never interleave concurrently.
final class _AsyncMutex {
  Future<void> _tail = Future<void>.value();

  Future<T> synchronized<T>(Future<T> Function() action) {
    final previous = _tail;
    final completer = Completer<void>();
    _tail = completer.future;
    return previous.then((_) => action()).whenComplete(completer.complete);
  }
}

/// Form payload for creating or updating a savings plan.
final class SavingsPlanDraft {
  const SavingsPlanDraft({
    required this.name,
    this.remark = '',
    required this.planType,
    this.cycleType = SavingsCycleType.free,
    required this.startDateMs,
    this.endDateMs = noRef,
    this.startMoneyMinor,
    this.incrementalMinor,
    this.customPlanMoneyMinor,
    this.autoPlan = false,
    this.fromAssetId = noRef,
    this.toAssetId = noRef,
    this.bookId = noRef,
    this.currency,
    this.icon,
  });

  final String name;
  final String remark;
  final int planType;
  final int cycleType;
  final int startDateMs;
  final int endDateMs;
  final BigInt? startMoneyMinor;
  final BigInt? incrementalMinor;
  final BigInt? customPlanMoneyMinor;
  final bool autoPlan;
  final int fromAssetId;
  final int toAssetId;
  final int bookId;
  final String? currency;
  final String? icon;

  List<Object?> get payload => [
    name,
    remark,
    planType,
    cycleType,
    startDateMs,
    endDateMs,
    startMoneyMinor?.toString(),
    incrementalMinor?.toString(),
    customPlanMoneyMinor?.toString(),
    autoPlan,
    fromAssetId,
    toAssetId,
    bookId,
    currency,
    icon,
  ];
}

/// Outcome of a `runAutoSave` pass across candidate plans.
final class AutoSaveResult {
  const AutoSaveResult({
    required this.createdRecordCount,
    required this.archivedPlanIds,
    required this.haltedPlanIds,
  });

  final int createdRecordCount;
  final List<int> archivedPlanIds;

  /// Plans halted mid-cycle due to missing or non-positive foreign exchange rates
  /// (R5 / CE-SP-08).
  final List<int> haltedPlanIds;
}

/// Mutating write service for Savings Plans (F-012, ADR-009, ADR-012).
final class SavingsService {
  SavingsService(this.db);
  final AppDatabase db;

  static final Expando<_AsyncMutex> _mutexByDb = Expando<_AsyncMutex>(
    'savings_autosave_mutex',
  );

  _AsyncMutex get _autoSaveMutex => _mutexByDb[db] ??= _AsyncMutex();

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

  /// Allocates next non-autoIncrement PK for `money_save_plan` inside a transaction.
  Future<int> _nextPlanId() async {
    final row = await db
        .customSelect(
          'SELECT COALESCE(MAX(id), 0) + 1 AS next_id FROM money_save_plan',
        )
        .getSingle();
    return row.read<int>('next_id');
  }

  /// Allocates next non-autoIncrement PK for `money_save_plan_record` inside a transaction.
  Future<int> _nextPlanRecordId() async {
    final row = await db
        .customSelect(
          'SELECT COALESCE(MAX(id), 0) + 1 AS next_id FROM money_save_plan_record',
        )
        .getSingle();
    return row.read<int>('next_id');
  }

  /// Creates ([planId] == null) or updates a savings plan. Returns the plan id.
  Future<int> savePlan({
    required String commandId,
    int? planId,
    required SavingsPlanDraft draft,
  }) => _command(
    commandId,
    ['savings-save-plan-v1', planId, ...draft.payload],
    () async {
      final name = draft.name.trim();
      if (name.isEmpty || name.length > 50) {
        throw const Failure(FailureCode.validation, '计划名称须为 1–50 字');
      }
      final remark = draft.remark.trim();
      if (remark.length > 500) {
        throw const Failure(FailureCode.validation, '备注不能超过 500 字');
      }
      if (!SavingsPlanType.isValid(draft.planType)) {
        throw const Failure(FailureCode.validation, '无效的存钱计划模式');
      }
      if (draft.planType == SavingsPlanType.free && draft.autoPlan) {
        throw const Failure(FailureCode.validation, '自由存钱计划不支持开启自动存钱');
      }
      if (draft.fromAssetId != noRef &&
          draft.toAssetId != noRef &&
          draft.fromAssetId == draft.toAssetId) {
        throw const Failure(FailureCode.validation, '转出账户和转入账户不能相同');
      }

      final existing = planId == null ? null : await _livePlan(planId);

      if (draft.bookId != noRef) {
        final book = await (db.select(
          db.accountBooks,
        )..where((t) => t.id.equals(draft.bookId))).getSingleOrNull();
        if (book == null) {
          throw const Failure(FailureCode.validation, '关联账本不存在');
        }
      }

      Asset? fromAsset;
      if (draft.fromAssetId != noRef) {
        fromAsset = await (db.select(
          db.assets,
        )..where((t) => t.id.equals(draft.fromAssetId))).getSingleOrNull();
        if (fromAsset == null) {
          throw const Failure(FailureCode.validation, '转出账户不存在');
        }
      }

      Asset? toAsset;
      if (draft.toAssetId != noRef) {
        toAsset = await (db.select(
          db.assets,
        )..where((t) => t.id.equals(draft.toAssetId))).getSingleOrNull();
        if (toAsset == null) {
          throw const Failure(FailureCode.validation, '转入账户不存在');
        }
      }

      // Currency locking (DR-SP-01 / SP-04 / SP-13):
      // Existing plans keep their locked currency; `toAsset` must match it.
      final String planCurrency;
      if (existing != null) {
        planCurrency = SavingsPlanExtra.parse(existing.extraInfo).currency;
        if (toAsset != null) {
          final toCurr = normalizeCurrency(toAsset.currency) ?? baseCurrency;
          if (toCurr != planCurrency) {
            throw Failure(
              FailureCode.validation,
              '转入账户币种（$toCurr）须与计划锁定币种（$planCurrency）一致',
            );
          }
        }
      } else {
        final toCurr = toAsset == null
            ? null
            : (normalizeCurrency(toAsset.currency) ?? baseCurrency);
        final explicitCurr = normalizeCurrency(draft.currency);
        planCurrency = explicitCurr ?? toCurr ?? baseCurrency;
        if (toCurr != null && toCurr != planCurrency) {
          throw Failure(
            FailureCode.validation,
            '转入账户币种（$toCurr）须与计划币种（$planCurrency）一致',
          );
        }
      }

      final int normalizedCycle;
      final int normalizedStartMs;
      final int normalizedEndMs;
      final BigInt normalizedStartMoney;
      final BigInt normalizedIncMoney;
      final BigInt planMoneyMinor;

      if (draft.planType == SavingsPlanType.free) {
        normalizedCycle = SavingsCycleType.free;
        final start = draft.startDateMs >= 0
            ? LocalCalendarDate.fromEpochMs(draft.startDateMs)
            : LocalCalendarDate.fromEpochMs(_now());
        normalizedStartMs = start.startOfDayMs;
        if (draft.endDateMs >= 0) {
          final end = LocalCalendarDate.fromEpochMs(draft.endDateMs);
          if (end < start) {
            throw const Failure(FailureCode.validation, '结束日期不能早于开始日期');
          }
          normalizedEndMs = end.startOfDayMs;
        } else {
          normalizedEndMs = noRef;
        }
        normalizedStartMoney = BigInt.zero;
        normalizedIncMoney = BigInt.zero;
        planMoneyMinor = computePlanTargetMinor(
          planType: SavingsPlanType.free,
          customPlanMoneyMinor: draft.customPlanMoneyMinor,
        );
      } else {
        if (!SavingsCycleType.isValidScheduled(draft.cycleType)) {
          throw const Failure(FailureCode.validation, '请选择有效的存钱周期');
        }
        if (draft.startDateMs < 0 || draft.endDateMs < 0) {
          throw const Failure(FailureCode.validation, '请选择开始日期和结束日期');
        }
        final start = LocalCalendarDate.fromEpochMs(draft.startDateMs);
        final end = LocalCalendarDate.fromEpochMs(draft.endDateMs);
        final periods = countSchedulePeriods(
          start: start,
          end: end,
          cycleType: draft.cycleType,
        );
        normalizedCycle = draft.cycleType;
        normalizedStartMs = start.startOfDayMs;
        normalizedEndMs = end.startOfDayMs;
        normalizedStartMoney = Money.minor(
          draft.startMoneyMinor ?? BigInt.zero,
          planCurrency,
        ).storageMinor;
        normalizedIncMoney = draft.planType == SavingsPlanType.incremental
            ? Money.minor(
                draft.incrementalMinor ?? BigInt.zero,
                planCurrency,
              ).storageMinor
            : BigInt.zero;
        planMoneyMinor = computePlanTargetMinor(
          planType: draft.planType,
          periodCount: periods,
          startMoneyMinor: normalizedStartMoney,
          incrementalMinor: normalizedIncMoney,
        );
      }

      final extra = SavingsPlanExtra(
        currency: planCurrency,
        raw: existing == null
            ? null
            : SavingsPlanExtra.parse(existing.extraInfo).raw,
      );

      if (existing == null) {
        final newId = await _nextPlanId();
        final minSortRow = await db
            .customSelect(
              'SELECT COALESCE(MIN(sort), 0) AS s FROM money_save_plan',
            )
            .getSingle();
        final sort = minSortRow.read<int>('s') - 1;
        final nextSaveDate = draft.autoPlan ? normalizedStartMs : noRef;

        await db
            .into(db.moneySavePlans)
            .insert(
              MoneySavePlansCompanion.insert(
                id: Value(newId),
                name: name,
                remark: Value(remark),
                planType: draft.planType,
                cycleType: normalizedCycle,
                startDate: normalizedStartMs,
                endDate: normalizedEndMs,
                planMoneyMinor: planMoneyMinor,
                savedMoneyMinor: BigInt.zero,
                autoPlan: Value(draft.autoPlan),
                fromAssetId: Value(draft.fromAssetId),
                toAssetId: Value(draft.toAssetId),
                bookId: Value(draft.bookId),
                startMoneyMinor: normalizedStartMoney,
                incrementalMinor: normalizedIncMoney,
                status: const Value(SavingsPlanStatus.active),
                createDate: _now(),
                sort: Value(sort),
                nextSaveDate: nextSaveDate,
                icon: Value(draft.icon),
                extraInfo: Value(extra.encode()),
              ),
            );
        return '$newId';
      } else {
        final savedMinor = await _sumPlanRecordsMinor(existing.id);
        final int newStatus;
        if (savedMinor >= planMoneyMinor) {
          newStatus = SavingsPlanStatus.archived;
        } else if (existing.status == SavingsPlanStatus.archived &&
            savedMinor < planMoneyMinor) {
          newStatus = SavingsPlanStatus.active;
        } else {
          newStatus = existing.status;
        }
        final effectiveAuto =
            draft.autoPlan && newStatus == SavingsPlanStatus.active;
        final nextSaveDate = effectiveAuto ? normalizedStartMs : noRef;

        await (db.update(
          db.moneySavePlans,
        )..where((t) => t.id.equals(existing.id))).write(
          MoneySavePlansCompanion(
            name: Value(name),
            remark: Value(remark),
            planType: Value(draft.planType),
            cycleType: Value(normalizedCycle),
            startDate: Value(normalizedStartMs),
            endDate: Value(normalizedEndMs),
            planMoneyMinor: Value(planMoneyMinor),
            savedMoneyMinor: Value(savedMinor),
            autoPlan: Value(effectiveAuto),
            fromAssetId: Value(draft.fromAssetId),
            toAssetId: Value(draft.toAssetId),
            bookId: Value(draft.bookId),
            startMoneyMinor: Value(normalizedStartMoney),
            incrementalMinor: Value(normalizedIncMoney),
            status: Value(newStatus),
            nextSaveDate: Value(nextSaveDate),
            icon: draft.icon == null ? const Value.absent() : Value(draft.icon),
            extraInfo: Value(extra.encode()),
          ),
        );
        return '${existing.id}';
      }
    },
    int.parse,
  );

  /// Manual check-in on either a scheduled slot or a free plan (R1, R5, SP-23).
  ///
  /// For free plans (`planType == 3`), callers may supply either direct
  /// [amountMinor] or [targetCumulativeMinor] (back-calculating `target - saved`).
  Future<int> checkIn({
    required String commandId,
    required int planId,
    BigInt? amountMinor,
    BigInt? targetCumulativeMinor,
    required int recordDateMs,
    String remark = '',
    int? fromAssetId,
    int? toAssetId,
  }) => _command(
    commandId,
    [
      'savings-checkin-v1',
      planId,
      amountMinor?.toString(),
      targetCumulativeMinor?.toString(),
      recordDateMs,
      remark,
      fromAssetId,
      toAssetId,
    ],
    () async {
      final plan = await _livePlan(planId);
      final trimmedRemark = remark.trim();
      if (trimmedRemark.length > 500) {
        throw const Failure(FailureCode.validation, '备注不能超过 500 字');
      }

      final planCurrency = SavingsPlanExtra.parse(plan.extraInfo).currency;
      final BigInt depositMinor;
      if (plan.planType == SavingsPlanType.free) {
        if (targetCumulativeMinor != null) {
          depositMinor = computeFreePlanDeltaMinor(
            currentSavedMinor: plan.savedMoneyMinor,
            targetCumulativeMinor: targetCumulativeMinor,
          );
        } else if (amountMinor != null && amountMinor > BigInt.zero) {
          depositMinor = Money.minor(amountMinor, planCurrency).storageMinor;
        } else {
          throw const Failure(FailureCode.validation, '存入金额须大于 0');
        }
      } else {
        if (amountMinor == null || amountMinor <= BigInt.zero) {
          throw const Failure(FailureCode.validation, '存入金额须大于 0');
        }
        depositMinor = Money.minor(amountMinor, planCurrency).storageMinor;
        // Guard against duplicate check-in on the same natural calendar day.
        final targetDay = LocalCalendarDate.fromEpochMs(recordDateMs);
        final existingRecords = await (db.select(
          db.moneySavePlanRecords,
        )..where((t) => t.planId.equals(planId))).get();
        final alreadySavedOnDay = existingRecords.any(
          (r) => LocalCalendarDate.fromEpochMs(r.recordDate) == targetDay,
        );
        if (alreadySavedOnDay) {
          throw const Failure(FailureCode.conflict, '该日期期次已打卡存入');
        }
      }

      final effectiveFromId = fromAssetId ?? plan.fromAssetId;
      final effectiveToId = toAssetId ?? plan.toAssetId;

      final transferLink = await _insertTransferIfAccountsActive(
        plan: plan,
        planCurrency: planCurrency,
        depositPlanMinor: depositMinor,
        fromAssetId: effectiveFromId,
        toAssetId: effectiveToId,
        recordTimeMs: recordDateMs,
      );

      final newRecordId = await _nextPlanRecordId();
      await db
          .into(db.moneySavePlanRecords)
          .insert(
            MoneySavePlanRecordsCompanion.insert(
              id: Value(newRecordId),
              planId: plan.id,
              remark: Value(trimmedRemark),
              fromAssetId: Value(transferLink.recordedFromId),
              toAssetId: Value(transferLink.recordedToId),
              recordDate: recordDateMs,
              recordMoneyMinor: depositMinor,
              recordId: Value(transferLink.recordId),
            ),
          );

      final newSavedMinor = Money.minor(
        plan.savedMoneyMinor + depositMinor,
        planCurrency,
      ).storageMinor;
      final archived = newSavedMinor >= plan.planMoneyMinor;
      final newStatus = archived ? SavingsPlanStatus.archived : plan.status;
      final int newNextSaveDate = (!plan.autoPlan || archived)
          ? noRef
          : await _computeNextUnsavedSlotMs(plan);
      final newAutoPlan =
          plan.autoPlan && !archived && newNextSaveDate != noRef;

      await (db.update(
        db.moneySavePlans,
      )..where((t) => t.id.equals(plan.id))).write(
        MoneySavePlansCompanion(
          savedMoneyMinor: Value(newSavedMinor),
          status: Value(newStatus),
          autoPlan: Value(newAutoPlan),
          nextSaveDate: Value(newNextSaveDate),
        ),
      );

      return '$newRecordId';
    },
    int.parse,
  );

  /// Executes automatic due-slot check-ins serialized by an async mutex
  /// (R2, R3 / CE-SP-02, R5 / CE-SP-08).
  ///
  /// Idempotency is checked strictly by natural calendar day / slot index rather
  /// than exact `00:00:00.000` milliseconds, preventing duplicate same-day
  /// deductions after manual check-ins!
  Future<AutoSaveResult> runAutoSave([
    int? nowMs,
  ]) => _autoSaveMutex.synchronized(() async {
    final effectiveNow = nowMs ?? _now();
    final today = LocalCalendarDate.fromEpochMs(effectiveNow);

    final candidates = await guardDatabase(
      () =>
          (db.select(db.moneySavePlans)
                ..where(
                  (t) =>
                      t.status.equals(SavingsPlanStatus.active) &
                      t.autoPlan.equals(true) &
                      t.nextSaveDate.isBiggerOrEqualValue(0) &
                      t.nextSaveDate.isSmallerOrEqualValue(today.endOfDayMs),
                )
                ..orderBy([
                  (t) => OrderingTerm.asc(t.sort),
                  (t) => OrderingTerm.asc(t.id),
                ]))
              .get(),
    );

    var totalCreated = 0;
    final archivedIds = <int>[];
    final haltedIds = <int>[];

    for (final candidate in candidates) {
      await guardDatabase(
        () => db.transaction(() async {
          final plan = await (db.select(
            db.moneySavePlans,
          )..where((t) => t.id.equals(candidate.id))).getSingleOrNull();
          if (plan == null ||
              plan.status != SavingsPlanStatus.active ||
              !plan.autoPlan ||
              plan.planType == SavingsPlanType.free ||
              plan.nextSaveDate < 0 ||
              plan.nextSaveDate > today.endOfDayMs) {
            return;
          }

          final planCurrency = SavingsPlanExtra.parse(plan.extraInfo).currency;
          final existingRecords = await (db.select(
            db.moneySavePlanRecords,
          )..where((t) => t.planId.equals(plan.id))).get();

          final savedDates = <LocalCalendarDate>{
            for (final r in existingRecords)
              LocalCalendarDate.fromEpochMs(r.recordDate),
          };
          var savedMinor = existingRecords.isEmpty
              ? plan.savedMoneyMinor
              : existingRecords.fold<BigInt>(
                  BigInt.zero,
                  (acc, r) => acc + r.recordMoneyMinor,
                );

          if (savedMinor >= plan.planMoneyMinor) {
            await (db.update(
              db.moneySavePlans,
            )..where((t) => t.id.equals(plan.id))).write(
              MoneySavePlansCompanion(
                savedMoneyMinor: Value(savedMinor),
                status: const Value(SavingsPlanStatus.archived),
                autoPlan: const Value(false),
                nextSaveDate: const Value(noRef),
              ),
            );
            archivedIds.add(plan.id);
            return;
          }

          if (plan.startDate < 0 ||
              plan.endDate < 0 ||
              !SavingsCycleType.isValidScheduled(plan.cycleType)) {
            return;
          }
          final start = LocalCalendarDate.fromEpochMs(plan.startDate);
          final end = LocalCalendarDate.fromEpochMs(plan.endDate);
          if (end < start) return;

          final slots = generateScheduleSlots(
            planType: plan.planType,
            cycleType: plan.cycleType,
            start: start,
            end: end,
            startMoneyMinor: plan.startMoneyMinor,
            incrementalMinor: plan.incrementalMinor,
          );

          final cursorDate = LocalCalendarDate.fromEpochMs(
            plan.nextSaveDate > 0 ? plan.nextSaveDate : plan.startDate,
          );

          int? nextFutureSlotMs;
          var archivedInLoop = false;
          var haltedOnFx = false;

          for (final slot in slots) {
            if (slot.date < cursorDate) continue;
            if (slot.date > today) {
              nextFutureSlotMs = slot.date.startOfDayMs;
              break;
            }
            // R3 / CE-SP-02: Natural-day / slot idempotency check!
            if (savedDates.contains(slot.date)) {
              continue;
            }

            final _TransferLinkResult link;
            try {
              link = await _insertTransferIfAccountsActive(
                plan: plan,
                planCurrency: planCurrency,
                depositPlanMinor: slot.plannedMoneyMinor,
                fromAssetId: plan.fromAssetId,
                toAssetId: plan.toAssetId,
                recordTimeMs: slot.date.startOfDayMs,
              );
            } on Failure {
              // CE-SP-08: Missing or invalid foreign exchange rate halts this
              // plan's loop cleanly without corrupting balances or skipping slot.
              haltedOnFx = true;
              haltedIds.add(plan.id);
              nextFutureSlotMs = slot.date.startOfDayMs;
              break;
            }

            final recId = await _nextPlanRecordId();
            await db
                .into(db.moneySavePlanRecords)
                .insert(
                  MoneySavePlanRecordsCompanion.insert(
                    id: Value(recId),
                    planId: plan.id,
                    remark: const Value(''),
                    fromAssetId: Value(link.recordedFromId),
                    toAssetId: Value(link.recordedToId),
                    recordDate: slot.date.startOfDayMs,
                    recordMoneyMinor: slot.plannedMoneyMinor,
                    recordId: Value(link.recordId),
                  ),
                );
            savedDates.add(slot.date);
            savedMinor = Money.minor(
              savedMinor + slot.plannedMoneyMinor,
              planCurrency,
            ).storageMinor;
            totalCreated++;

            if (savedMinor >= plan.planMoneyMinor) {
              archivedInLoop = true;
              archivedIds.add(plan.id);
              await (db.update(
                db.moneySavePlans,
              )..where((t) => t.id.equals(plan.id))).write(
                MoneySavePlansCompanion(
                  savedMoneyMinor: Value(savedMinor),
                  status: const Value(SavingsPlanStatus.archived),
                  autoPlan: const Value(false),
                  nextSaveDate: const Value(noRef),
                ),
              );
              break;
            }
          }

          if (!archivedInLoop) {
            if (haltedOnFx) {
              await (db.update(
                db.moneySavePlans,
              )..where((t) => t.id.equals(plan.id))).write(
                MoneySavePlansCompanion(
                  savedMoneyMinor: Value(savedMinor),
                  nextSaveDate: Value(nextFutureSlotMs ?? plan.nextSaveDate),
                ),
              );
            } else if (nextFutureSlotMs != null) {
              await (db.update(
                db.moneySavePlans,
              )..where((t) => t.id.equals(plan.id))).write(
                MoneySavePlansCompanion(
                  savedMoneyMinor: Value(savedMinor),
                  nextSaveDate: Value(nextFutureSlotMs),
                ),
              );
            } else {
              // All schedule slots up to endDate processed without reaching target.
              await (db.update(
                db.moneySavePlans,
              )..where((t) => t.id.equals(plan.id))).write(
                MoneySavePlansCompanion(
                  savedMoneyMinor: Value(savedMinor),
                  autoPlan: const Value(false),
                  nextSaveDate: const Value(noRef),
                ),
              );
            }
          }
        }),
      );
    }

    return AutoSaveResult(
      createdRecordCount: totalCreated,
      archivedPlanIds: archivedIds,
      haltedPlanIds: haltedIds,
    );
  });

  /// Cancels a deposit check-in, deleting any live linked transfer bill and reversing
  /// account balances, decrementing `savedMoneyMinor`, and auto-unarchiving if
  /// `status == 1 && savedMoneyMinor < planMoneyMinor` (R6 / golden vector DR-SP-05).
  Future<void> cancelDeposit({
    required String commandId,
    required int planRecordId,
  }) => _command(
    commandId,
    ['savings-cancel-deposit-v1', planRecordId],
    () async {
      final planRecord = await (db.select(
        db.moneySavePlanRecords,
      )..where((t) => t.id.equals(planRecordId))).getSingleOrNull();
      if (planRecord == null) {
        throw const Failure(FailureCode.conflict, '存入记录不存在或已取消');
      }
      final plan = await _livePlan(planRecord.planId);

      if (planRecord.recordId != null && planRecord.recordId!.isNotEmpty) {
        await _deleteLinkedTransferIfLive(planRecord.recordId!);
      }

      await (db.delete(
        db.moneySavePlanRecords,
      )..where((t) => t.id.equals(planRecordId))).go();

      final rawDecremented = plan.savedMoneyMinor - planRecord.recordMoneyMinor;
      final newSavedMinor = rawDecremented.isNegative
          ? BigInt.zero
          : rawDecremented;

      final int newStatus;
      if (plan.status == SavingsPlanStatus.archived &&
          newSavedMinor < plan.planMoneyMinor) {
        newStatus = SavingsPlanStatus.active;
      } else if (newSavedMinor >= plan.planMoneyMinor) {
        newStatus = SavingsPlanStatus.archived;
      } else {
        newStatus = plan.status;
      }

      await (db.update(
        db.moneySavePlans,
      )..where((t) => t.id.equals(plan.id))).write(
        MoneySavePlansCompanion(
          savedMoneyMinor: Value(newSavedMinor),
          status: Value(newStatus),
          autoPlan: const Value(false),
          nextSaveDate: const Value(noRef),
        ),
      );

      return '$planRecordId';
    },
    (_) {},
  );

  /// Self-heals `saved_money_minor` from `SUM(record_money_minor)` without altering
  /// `plan.status` when opening the detail page (DR-SP-04 / CE-SP-05).
  Future<BigInt> healSavedMoney(int planId) => guardDatabase(
    () => db.transaction(() async {
      final plan = await (db.select(
        db.moneySavePlans,
      )..where((t) => t.id.equals(planId))).getSingleOrNull();
      if (plan == null) return BigInt.zero;
      final records = await (db.select(
        db.moneySavePlanRecords,
      )..where((t) => t.planId.equals(planId))).get();
      final sum = records.fold<BigInt>(
        BigInt.zero,
        (acc, r) => acc + r.recordMoneyMinor,
      );
      final validSum = Money.minor(sum).storageMinor;
      if (plan.savedMoneyMinor != validSum) {
        await (db.update(db.moneySavePlans)..where((t) => t.id.equals(planId)))
            .write(MoneySavePlansCompanion(savedMoneyMinor: Value(validSum)));
      }
      return validSum;
    }),
  );

  /// Manually archives (`archived == true` -> `status = 1`) or unarchives
  /// (`archived == false` -> `status = 0`) a plan (SP-25).
  Future<void> setPlanArchived({
    required String commandId,
    required int planId,
    required bool archived,
  }) => _command(
    commandId,
    ['savings-set-archived-v1', planId, archived],
    () async {
      await _livePlan(planId);
      await (db.update(
        db.moneySavePlans,
      )..where((t) => t.id.equals(planId))).write(
        MoneySavePlansCompanion(
          status: Value(
            archived ? SavingsPlanStatus.archived : SavingsPlanStatus.active,
          ),
          autoPlan: const Value(false),
          nextSaveDate: const Value(noRef),
        ),
      );
      return '$planId';
    },
    (_) {},
  );

  /// Deletes a savings plan and its `money_save_plan_record` rows.
  ///
  /// By default (`deleteLinkedTransfers == false`), preserves historical transfer
  /// bills per original DR-SP-05. When `deleteLinkedTransfers == true`, checks each
  /// linked `recordId` and deletes live transfer bills while reversing `netEffects`.
  Future<void> deletePlan({
    required String commandId,
    required int planId,
    bool deleteLinkedTransfers = false,
  }) => _command(
    commandId,
    ['savings-delete-plan-v1', planId, deleteLinkedTransfers],
    () async {
      await _livePlan(planId);
      final planRecords = await (db.select(
        db.moneySavePlanRecords,
      )..where((t) => t.planId.equals(planId))).get();

      if (deleteLinkedTransfers) {
        final seenIds = <String>{};
        for (final rec in planRecords) {
          final rid = rec.recordId;
          if (rid != null && rid.isNotEmpty && seenIds.add(rid)) {
            await _deleteLinkedTransferIfLive(rid);
          }
        }
      }

      await (db.delete(
        db.moneySavePlanRecords,
      )..where((t) => t.planId.equals(planId))).go();
      await (db.delete(
        db.moneySavePlans,
      )..where((t) => t.id.equals(planId))).go();
      return '$planId';
    },
    (_) {},
  );

  // ---- Internal helpers ----

  Future<MoneySavePlan> _livePlan(int planId) async {
    final plan = await (db.select(
      db.moneySavePlans,
    )..where((t) => t.id.equals(planId))).getSingleOrNull();
    if (plan == null) {
      throw const Failure(FailureCode.conflict, '存钱计划不存在或已删除');
    }
    return plan;
  }

  Future<BigInt> _sumPlanRecordsMinor(int planId) async {
    final records = await (db.select(
      db.moneySavePlanRecords,
    )..where((t) => t.planId.equals(planId))).get();
    if (records.isEmpty) return BigInt.zero;
    final sum = records.fold<BigInt>(
      BigInt.zero,
      (acc, r) => acc + r.recordMoneyMinor,
    );
    return Money.minor(sum).storageMinor;
  }

  Future<int> _computeNextUnsavedSlotMs(MoneySavePlan plan) async {
    if (plan.planType == SavingsPlanType.free ||
        plan.startDate < 0 ||
        plan.endDate < 0 ||
        !SavingsCycleType.isValidScheduled(plan.cycleType)) {
      return noRef;
    }
    final start = LocalCalendarDate.fromEpochMs(plan.startDate);
    final end = LocalCalendarDate.fromEpochMs(plan.endDate);
    if (end < start) return noRef;

    final slots = generateScheduleSlots(
      planType: plan.planType,
      cycleType: plan.cycleType,
      start: start,
      end: end,
      startMoneyMinor: plan.startMoneyMinor,
      incrementalMinor: plan.incrementalMinor,
    );
    final records = await (db.select(
      db.moneySavePlanRecords,
    )..where((t) => t.planId.equals(plan.id))).get();
    final savedDates = {
      for (final r in records) LocalCalendarDate.fromEpochMs(r.recordDate),
    };
    final cursor = LocalCalendarDate.fromEpochMs(
      plan.nextSaveDate > 0 ? plan.nextSaveDate : plan.startDate,
    );

    for (final slot in slots) {
      if (slot.date < cursor) continue;
      if (!savedDates.contains(slot.date)) {
        return slot.date.startOfDayMs;
      }
    }
    return noRef;
  }

  Future<int> _resolveTargetBookId(int planBookId) async {
    if (planBookId != noRef) {
      final explicit = await (db.select(
        db.accountBooks,
      )..where((t) => t.id.equals(planBookId))).getSingleOrNull();
      if (explicit != null) return explicit.id;
    }
    final pref = await (db.select(
      db.preferences,
    )..where((t) => t.key.equals('current_book_id'))).getSingleOrNull();
    final prefId = int.tryParse(pref?.value ?? '');
    if (prefId != null) {
      final current = await (db.select(
        db.accountBooks,
      )..where((t) => t.id.equals(prefId))).getSingleOrNull();
      if (current != null) return current.id;
    }
    final anyBook =
        await (db.select(db.accountBooks)
              ..orderBy([(t) => OrderingTerm.asc(t.id)])
              ..limit(1))
            .getSingleOrNull();
    return anyBook?.id ?? defaultBookId;
  }

  Future<Map<String, String>> _loadRawRates() async {
    final currencies = await db.select(db.currencies).get();
    return {
      for (final c in currencies)
        if (c.enable) c.code: c.rateToAnchor,
    };
  }

  Future<_TransferLinkResult> _insertTransferIfAccountsActive({
    required MoneySavePlan plan,
    required String planCurrency,
    required BigInt depositPlanMinor,
    required int fromAssetId,
    required int toAssetId,
    required int recordTimeMs,
  }) async {
    if (fromAssetId == noRef ||
        toAssetId == noRef ||
        fromAssetId == toAssetId) {
      return const _TransferLinkResult.planOnly();
    }
    final fromAsset = await (db.select(
      db.assets,
    )..where((t) => t.id.equals(fromAssetId))).getSingleOrNull();
    final toAsset = await (db.select(
      db.assets,
    )..where((t) => t.id.equals(toAssetId))).getSingleOrNull();

    // R5: Only link transfer when BOTH accounts exist and are active (`status == 0`).
    if (fromAsset == null ||
        toAsset == null ||
        fromAsset.status != AssetStatus.active ||
        toAsset.status != AssetStatus.active) {
      return const _TransferLinkResult.planOnly();
    }

    final rawRates = await _loadRawRates();
    final quote = quoteSavingsTransfer(
      depositPlanMinor: depositPlanMinor,
      planCurrency: planCurrency,
      fromAssetCurrency: fromAsset.currency,
      toAssetCurrency: toAsset.currency,
      rawRates: rawRates,
    );

    final targetBookId = await _resolveTargetBookId(plan.bookId);
    final recordId = _uuid.v4();
    final extra = RecordExtra()..currency = quote.snapshot;

    final row = RecordsCompanion.insert(
      recordId: recordId,
      type: RecordType.transfer,
      subType: const Value(RecordDirection.none),
      moneyMinor: quote.fromMinor,
      remark: Value('存钱 - ${plan.name}'),
      recordTime: recordTimeMs,
      recordCatId: const Value(noRef),
      assetId: const Value(noRef),
      fromAssetId: Value(fromAsset.id),
      toAssetId: Value(toAsset.id),
      accountBookId: targetBookId,
      extraInfo: Value(extra.encode()),
      createDate: Value(_now()),
    );

    final facts = EntryFacts(
      type: RecordType.transfer,
      subType: RecordDirection.none,
      moneyMinor: quote.fromMinor,
      fromAssetId: fromAsset.id,
      toAssetId: toAsset.id,
      currency: quote.snapshot,
    );
    await _applyNet(netEffects(after: [facts]));
    await _touchAssets([fromAsset.id, toAsset.id]);
    await db.into(db.records).insert(row);

    return _TransferLinkResult(
      recordId: recordId,
      recordedFromId: fromAsset.id,
      recordedToId: toAsset.id,
    );
  }

  Future<void> _deleteLinkedTransferIfLive(String recordId) async {
    final live = await (db.select(
      db.records,
    )..where((t) => t.recordId.equals(recordId))).getSingleOrNull();
    if (live == null) return;

    final feeRows = await db
        .customSelect(
          "SELECT record_id FROM record WHERE type = ? "
          "AND json_extract(rel_info, '\$.ltfeei.tfobid') = ?",
          variables: [
            Variable.withInt(RecordType.fee),
            Variable.withString(recordId),
          ],
        )
        .get();
    LedgerRecord? feeChild;
    if (feeRows.isNotEmpty) {
      final feeId = feeRows.first.read<String>('record_id');
      feeChild = await (db.select(
        db.records,
      )..where((t) => t.recordId.equals(feeId))).getSingleOrNull();
    }

    final toDelete = [live, ?feeChild];
    await _applyNet(netEffects(before: toDelete.map(factsOf)));
    for (final r in toDelete) {
      await (db.delete(
        db.tagRecords,
      )..where((t) => t.recordId.equals(r.recordId))).go();
      await (db.delete(
        db.records,
      )..where((t) => t.recordId.equals(r.recordId))).go();
    }
  }

  Future<void> _applyNet(Map<int, BigInt> net) async {
    for (final entry in net.entries) {
      final asset = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(entry.key))).getSingleOrNull();
      if (asset == null) continue;
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

final class _TransferLinkResult {
  const _TransferLinkResult({
    required this.recordId,
    required this.recordedFromId,
    required this.recordedToId,
  });

  const _TransferLinkResult.planOnly()
    : recordId = null,
      recordedFromId = noRef,
      recordedToId = noRef;

  final String? recordId;
  final int recordedFromId;
  final int recordedToId;
}
