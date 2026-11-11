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
import '../../domain/rules/periodic_records.dart';
import '../db/database.dart';
import '../db/failures.dart';

const _uuid = Uuid();

const _lastCheckPrefKey = 'periodic_last_check_ms';
const _throttleIntervalMs = 600000; // 10 minutes

final _dbMutexes = Expando<_AsyncMutex>('PeriodicServiceMutex');

_AsyncMutex _mutexFor(AppDatabase db) => _dbMutexes[db] ??= _AsyncMutex();

final class _AsyncMutex {
  Future<void> _tail = Future<void>.value();

  Future<T> synchronized<T>(Future<T> Function() action) {
    final prev = _tail;
    final completer = Completer<void>();
    _tail = completer.future;
    return prev.then((_) => action()).whenComplete(completer.complete);
  }
}

/// Input draft for creating or editing a periodic bookkeeping rule (F-009).
final class PeriodicDraft {
  PeriodicDraft({
    required this.recordType,
    required this.money,
    required this.bookId,
    required this.periodType,
    this.periodTypeDates = const [],
    this.frequency = 1,
    required this.periodStartDate,
    this.periodEndDate = periodEndNever,
    this.fee,
    this.feeFromTarget = false,
    this.remark = '',
    this.categoryId = noRef,
    this.assetId = noRef,
    this.assetId2 = noRef,
    this.excludeBudget = false,
    this.excludeExIn = false,
    this.recordTimeEnabled = false,
    this.recordTime,
    this.tagIds = const [],
    this.images,
  });

  final int recordType;
  final Money money;
  final Money? fee;
  final bool feeFromTarget;
  final String remark;
  final int categoryId;
  final int assetId;
  final int assetId2;
  final int bookId;
  final int periodType;
  final List<String> periodTypeDates;
  final int frequency;
  final int periodStartDate;
  final int periodEndDate;
  final bool excludeBudget;
  final bool excludeExIn;
  final bool recordTimeEnabled;
  final String? recordTime;
  final List<String> tagIds;
  final String? images;

  List<Object?> get payload => [
    recordType,
    money.toJson(),
    fee?.toJson(),
    feeFromTarget,
    remark,
    categoryId,
    assetId,
    assetId2,
    bookId,
    periodType,
    periodTypeDates,
    frequency,
    periodStartDate,
    periodEndDate,
    excludeBudget,
    excludeExIn,
    recordTimeEnabled,
    recordTime,
    tagIds,
    images,
  ];
}

/// Details of an active periodic rule skipped during `runCatchUp` (ASYM-PB-01).
final class SkippedPeriodRule {
  const SkippedPeriodRule({required this.periodId, required this.reason});

  final int periodId;
  final String reason;
}

/// Summary returned by `PeriodicService.runCatchUp`.
final class CatchUpResult {
  const CatchUpResult({
    this.generatedRecordIds = const [],
    this.feeRecordIds = const [],
    this.endedRuleIds = const [],
    this.skippedRules = const [],
    this.throttled = false,
  });

  const CatchUpResult.throttled() : this(throttled: true);

  /// Primary generated `record.record_id`s (one per triggered due occurrence).
  final List<String> generatedRecordIds;

  /// Generated child fee `record.record_id`s (`type = 12`).
  final List<String> feeRecordIds;

  /// Rule IDs that transitioned to `PeriodState.ended (1)` in this pass.
  final List<int> endedRuleIds;

  /// Rules skipped due to missing/inactive accounts, missing book/category, or invalid FX rates.
  final List<SkippedPeriodRule> skippedRules;

  /// True when `force == false` and skipped within the 10-minute throttle window.
  final bool throttled;

  /// Count of due occurrences generated.
  int get generatedCount => generatedRecordIds.length;

  /// Count of active due rules skipped.
  int get skippedCount => skippedRules.length;

  /// Total `record` rows inserted (primary bills + transfer fee children).
  int get totalRowsWritten => generatedRecordIds.length + feeRecordIds.length;

  Set<int> get skippedRuleIds => {for (final s in skippedRules) s.periodId};
}

/// Extracts `PeriodScheduleSpec` from a stored `RecordPeriod` row.
PeriodScheduleSpec scheduleSpecOf(RecordPeriod row) => PeriodScheduleSpec(
  periodType: row.periodType,
  periodTypeDateJson: row.periodTypeDate,
  frequency: row.frequency,
  periodStartDateMs: row.periodStartDate,
  periodEndDate: row.periodEndDate,
  lastAddDateMs: row.lastAddDate,
  periodAddTimes: row.periodAddTimes,
  state: row.state,
);

/// Write service and catch-up engine for periodic bookkeeping (F-009).
final class PeriodicService {
  PeriodicService(this.db);
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

  /// Creates (`periodId == null`) or updates an existing periodic rule.
  Future<int> savePeriod({
    required String commandId,
    int? periodId,
    required PeriodicDraft draft,
    bool resetCountOnStartChange = false,
  }) => _command(
    commandId,
    ['periodic-save-v1', periodId, resetCountOnStartChange, ...draft.payload],
    () async {
      await _validateDraft(draft);

      final old = periodId == null ? null : await _requirePeriod(periodId);
      final clampedFreq = clampFrequency(draft.periodType, draft.frequency);
      final encodedDates = encodePeriodTypeDateJson(
        draft.periodType,
        draft.periodTypeDates,
      );
      final startCal = CalendarDate.fromEpochMs(draft.periodStartDate);
      final normalizedStartMs = startCal.startOfDayMs;

      final endMode = classifyPeriodEndDate(draft.periodEndDate);
      final normalizedEnd = endMode == PeriodEndMode.date
          ? CalendarDate.fromEpochMs(draft.periodEndDate).startOfDayMs
          : draft.periodEndDate;

      final extra = PeriodExtra.parse(old?.exi)
        ..recordTimeEnabled = draft.recordTimeEnabled
        ..recordTime = draft.recordTimeEnabled ? draft.recordTime : null;
      if (draft.recordType == RecordType.transfer) {
        extra.feeFromTarget = draft.feeFromTarget;
      } else {
        extra.raw.remove('fee_from');
      }

      final feeMinor = draft.recordType == RecordType.transfer
          ? (draft.fee?.storageMinor ?? BigInt.zero)
          : BigInt.zero;
      final normalizedTime = draft.recordTimeEnabled ? extra.recordTime : null;
      final encodedTags = encodePeriodTagTokens(draft.tagIds);

      if (old == null) {
        final newId = await db
            .into(db.recordPeriods)
            .insert(
              RecordPeriodsCompanion.insert(
                recordType: draft.recordType,
                moneyMinor: draft.money.storageMinor,
                feeMinor: Value(feeMinor),
                remark: Value(draft.remark.trim()),
                catId: Value(
                  draft.recordType == RecordType.transfer
                      ? noRef
                      : draft.categoryId,
                ),
                assetId: Value(draft.assetId),
                assetId2: Value(
                  draft.recordType == RecordType.transfer
                      ? draft.assetId2
                      : noRef,
                ),
                bookId: draft.bookId,
                images: Value(draft.images),
                state: const Value(PeriodState.active),
                time: Value(normalizedTime),
                excludeBudget: Value(draft.excludeBudget),
                excludeExIn: Value(draft.excludeExIn),
                periodType: draft.periodType,
                periodTypeDate: encodedDates,
                periodStartDate: normalizedStartMs,
                periodEndDate: normalizedEnd,
                frequency: Value(clampedFreq),
                lastAddDate: const Value(noLastAddDate),
                periodAddTimes: const Value(0),
                createTime: _now(),
                tags: Value(encodedTags),
                exi: Value(extra.encode()),
              ),
            );
        return '$newId';
      }

      var nextLastAddDate = old.lastAddDate;
      var nextAddTimes = old.periodAddTimes;
      if (nextLastAddDate != noLastAddDate &&
          startCal.isAfter(CalendarDate.fromEpochMs(nextLastAddDate))) {
        nextLastAddDate = noLastAddDate;
        if (resetCountOnStartChange) {
          nextAddTimes = 0;
        }
      }

      final updatedSpec = PeriodScheduleSpec(
        periodType: draft.periodType,
        periodTypeDateJson: encodedDates,
        frequency: clampedFreq,
        periodStartDateMs: normalizedStartMs,
        periodEndDate: normalizedEnd,
        lastAddDateMs: nextLastAddDate,
        periodAddTimes: nextAddTimes,
        state: old.state,
      );
      final nextState = old.state == PeriodState.paused
          ? PeriodState.paused
          : (shouldRuleEnd(updatedSpec)
                ? PeriodState.ended
                : PeriodState.active);

      await (db.update(
        db.recordPeriods,
      )..where((t) => t.id.equals(old.id))).write(
        RecordPeriodsCompanion(
          recordType: Value(draft.recordType),
          moneyMinor: Value(draft.money.storageMinor),
          feeMinor: Value(feeMinor),
          remark: Value(draft.remark.trim()),
          catId: Value(
            draft.recordType == RecordType.transfer ? noRef : draft.categoryId,
          ),
          assetId: Value(draft.assetId),
          assetId2: Value(
            draft.recordType == RecordType.transfer ? draft.assetId2 : noRef,
          ),
          bookId: Value(draft.bookId),
          images: Value(draft.images),
          state: Value(nextState),
          time: Value(normalizedTime),
          excludeBudget: Value(draft.excludeBudget),
          excludeExIn: Value(draft.excludeExIn),
          periodType: Value(draft.periodType),
          periodTypeDate: Value(encodedDates),
          periodStartDate: Value(normalizedStartMs),
          periodEndDate: Value(normalizedEnd),
          frequency: Value(clampedFreq),
          lastAddDate: Value(nextLastAddDate),
          periodAddTimes: Value(nextAddTimes),
          tags: Value(encodedTags),
          exi: Value(extra.encode()),
        ),
      );
      return '${old.id}';
    },
    int.parse,
  );

  /// Pauses a periodic rule (`state = 2`, R5).
  Future<void> pausePeriod({
    required String commandId,
    required int periodId,
  }) => _command(commandId, ['periodic-pause-v1', periodId], () async {
    await _requirePeriod(periodId);
    await (db.update(db.recordPeriods)..where((t) => t.id.equals(periodId)))
        .write(const RecordPeriodsCompanion(state: Value(PeriodState.paused)));
    return '$periodId';
  }, (_) {});

  /// Resumes a periodic rule (`state = 0`, R5), fast-forwarding `last_add_date`
  /// past any historical missed dates strictly before `today` without back-posting.
  Future<void> resumePeriod({
    required String commandId,
    required int periodId,
    int? nowMs,
  }) => _command(commandId, ['periodic-resume-v1', periodId, nowMs], () async {
    final rule = await _requirePeriod(periodId);
    final today = CalendarDate.fromEpochMs(nowMs ?? _now());
    final advanced = fastForwardMissedDates(scheduleSpecOf(rule), today);
    await (db.update(
      db.recordPeriods,
    )..where((t) => t.id.equals(periodId))).write(
      RecordPeriodsCompanion(
        state: Value(advanced.state),
        lastAddDate: Value(advanced.lastAddDateMs),
      ),
    );
    return '$periodId';
  }, (_) {});

  /// Physically deletes a periodic rule while retaining all historical `record`
  /// rows and account balances (R5).
  Future<void> deletePeriod({
    required String commandId,
    required int periodId,
  }) => _command(commandId, ['periodic-delete-v1', periodId], () async {
    await (db.delete(
      db.recordPeriods,
    )..where((t) => t.id.equals(periodId))).go();
    return '$periodId';
  }, (_) {});

  /// Serialized catch-up engine: scans all active rules (`state = 0`), skips rules
  /// with missing/inactive accounts or invalid rates (ASYM-PB-01), generates due
  /// bills with deterministic timestamps (ASYM-PB-06) and fee child `periodId`
  /// links (ASYM-PB-05), and updates balances atomically via `netEffects`.
  Future<CatchUpResult> runCatchUp({
    bool force = true,
    int? nowMs,
  }) => _mutexFor(db).synchronized(
    () => guardDatabase(
      () => db.transaction(() async {
        final effectiveNow = nowMs ?? _now();
        if (!force) {
          final pref = await (db.select(
            db.preferences,
          )..where((t) => t.key.equals(_lastCheckPrefKey))).getSingleOrNull();
          final lastCheck = int.tryParse(pref?.value ?? '');
          if (lastCheck != null &&
              (effectiveNow - lastCheck).abs() < _throttleIntervalMs) {
            return const CatchUpResult.throttled();
          }
          await db
              .into(db.preferences)
              .insertOnConflictUpdate(
                PreferencesCompanion.insert(
                  key: _lastCheckPrefKey,
                  value: '$effectiveNow',
                ),
              );
        }

        final activeRules =
            await (db.select(db.recordPeriods)
                  ..where((t) => t.state.equals(PeriodState.active))
                  ..orderBy([(t) => OrderingTerm.asc(t.id)]))
                .get();
        if (activeRules.isEmpty) {
          return const CatchUpResult();
        }

        final today = CalendarDate.fromEpochMs(effectiveNow);
        final books = {
          for (final b in await db.select(db.accountBooks).get()) b.id: b,
        };
        final categories = {
          for (final c in await db.select(db.recordCategories).get()) c.id: c,
        };
        final assets = {
          for (final a in await db.select(db.assets).get()) a.id: a,
        };
        final currencies = await db.select(db.currencies).get();
        final positiveRates = <String>{baseCurrency};
        final rateMap = <String, String>{};
        for (final c in currencies) {
          final code = normalizeCurrency(c.code);
          if (code == null) continue;
          rateMap[code] = c.rateToAnchor;
          if (!c.enable) continue;
          try {
            final parsed = DecimalValue.parse(c.rateToAnchor);
            if (parsed.coefficient > BigInt.zero) {
              positiveRates.add(code);
            }
          } on Failure {
            // Invalid rate string stays excluded from positiveRates.
          }
        }
        final rateTable = RateTable(rateMap);

        final allTags = await db.select(db.tags).get();
        final tagById = <String, Tag>{
          for (final t in allTags)
            if (t.parent != 1) t.tagId: t,
        };
        final tagByName = <String, Tag>{
          for (final t in allTags)
            if (t.parent != 1) t.name: t,
        };

        final generatedRecordIds = <String>[];
        final feeRecordIds = <String>[];
        final endedRuleIds = <int>[];
        final skippedRules = <SkippedPeriodRule>[];
        final allFacts = <EntryFacts>[];

        for (final rule in activeRules) {
          final spec = scheduleSpecOf(rule);
          final plan = computeCatchUpPlan(spec, today);

          if (plan.dueDates.isEmpty) {
            if (plan.nextState != rule.state) {
              await (db.update(db.recordPeriods)
                    ..where((t) => t.id.equals(rule.id)))
                  .write(RecordPeriodsCompanion(state: Value(plan.nextState)));
              if (plan.nextState == PeriodState.ended) {
                endedRuleIds.add(rule.id);
              }
            }
            continue;
          }

          final skipReason = _checkRuleTargetValidity(
            rule: rule,
            books: books,
            categories: categories,
            assets: assets,
            positiveRates: positiveRates,
          );
          if (skipReason != null) {
            skippedRules.add(
              SkippedPeriodRule(periodId: rule.id, reason: skipReason),
            );
            continue;
          }

          final PeriodExtra extra;
          try {
            extra = PeriodExtra.parse(rule.exi);
          } on Failure {
            skippedRules.add(
              SkippedPeriodRule(periodId: rule.id, reason: '周期附加信息格式损坏'),
            );
            continue;
          }

          final resolvedTagIds = _resolveTagIds(
            rule.tags,
            tagById: tagById,
            tagByName: tagByName,
          );

          for (final dueDate in plan.dueDates) {
            final baseTime = computePeriodicRecordTime(
              dueDate: dueDate,
              nowMs: effectiveNow,
              extra: extra,
              fallbackTime: rule.time,
            );

            if (rule.recordType == RecordType.transfer) {
              final fromAsset = assets[rule.assetId]!;
              final toAsset = assets[rule.assetId2]!;
              final fromCode =
                  normalizeCurrency(fromAsset.currency) ?? baseCurrency;
              final toCode =
                  normalizeCurrency(toAsset.currency) ?? baseCurrency;

              final parentExtra = RecordExtra();
              if (fromCode != baseCurrency || toCode != baseCurrency) {
                final targetMinor = fromCode == toCode
                    ? rule.moneyMinor
                    : rateTable.convert(rule.moneyMinor, fromCode, toCode);
                parentExtra.currency = billSnapshot(
                  source: fromCode,
                  sourceMinor: rule.moneyMinor,
                  account: toCode,
                  assetMinor: targetMinor,
                  rates: rateTable,
                );
              }

              final hasFee = rule.feeMinor > BigInt.zero;
              final (parentTime, feeTime) = hasFee
                  ? computeTransferWithFeeTimestamps(baseTime)
                  : (baseTime, 0);

              final parentId = _uuid.v4();
              final parentRel = RecordRelations();
              if (hasFee) {
                parentRel.transferFee = TransferFeeLink(
                  feeFromTarget: extra.feeFromTarget,
                  repay: toAsset.type == AssetType.credit,
                );
              }

              final parentCompanion = RecordsCompanion.insert(
                recordId: parentId,
                type: RecordType.transfer,
                subType: const Value(RecordDirection.none),
                moneyMinor: Money.minor(rule.moneyMinor).storageMinor,
                remark: Value(rule.remark),
                recordTime: parentTime,
                recordCatId: const Value(noRef),
                assetId: const Value(noRef),
                fromAssetId: Value(fromAsset.id),
                toAssetId: Value(toAsset.id),
                accountBookId: rule.bookId,
                excludeBudget: Value(rule.excludeBudget),
                excludeExIn: Value(rule.excludeExIn),
                platformId: const Value(noRef),
                periodId: Value(rule.id),
                images: Value(rule.images),
                relInfo: Value(parentRel.encode()),
                extraInfo: Value(parentExtra.encode()),
                createDate: Value(effectiveNow),
              );

              await db.into(db.records).insert(parentCompanion);
              await _insertTags(parentId, resolvedTagIds);
              generatedRecordIds.add(parentId);
              allFacts.add(
                EntryFacts(
                  type: RecordType.transfer,
                  moneyMinor: rule.moneyMinor,
                  fromAssetId: fromAsset.id,
                  toAssetId: toAsset.id,
                  currency: parentExtra.currency,
                ),
              );

              if (hasFee) {
                final payerAsset = extra.feeFromTarget ? toAsset : fromAsset;
                final payerCode =
                    normalizeCurrency(payerAsset.currency) ?? baseCurrency;
                final feeExtra = RecordExtra();
                if (payerCode != baseCurrency) {
                  feeExtra.currency = billSnapshot(
                    source: payerCode,
                    sourceMinor: rule.feeMinor,
                    account: payerCode,
                    assetMinor: rule.feeMinor,
                    rates: rateTable,
                  );
                }

                final feeId = _uuid.v4();
                final feeRel = RecordRelations()
                  ..transferFee = TransferFeeLink(
                    feeFromTarget: extra.feeFromTarget,
                    repay: toAsset.type == AssetType.credit,
                    parentId: parentId,
                  );

                final feeCompanion = RecordsCompanion.insert(
                  recordId: feeId,
                  type: RecordType.fee,
                  subType: const Value(RecordDirection.expense),
                  moneyMinor: Money.minor(rule.feeMinor).storageMinor,
                  remark: Value(rule.remark),
                  recordTime: feeTime,
                  recordCatId: const Value(noRef),
                  assetId: Value(payerAsset.id),
                  fromAssetId: const Value(noRef),
                  toAssetId: const Value(noRef),
                  accountBookId: rule.bookId,
                  excludeBudget: Value(rule.excludeBudget),
                  excludeExIn: Value(rule.excludeExIn),
                  platformId: const Value(noRef),
                  periodId: Value(rule.id),
                  relInfo: Value(feeRel.encode()),
                  extraInfo: Value(feeExtra.encode()),
                  createDate: Value(effectiveNow),
                );

                await db.into(db.records).insert(feeCompanion);
                await _insertTags(feeId, resolvedTagIds);
                feeRecordIds.add(feeId);
                allFacts.add(
                  EntryFacts(
                    type: RecordType.fee,
                    subType: RecordDirection.expense,
                    moneyMinor: rule.feeMinor,
                    assetId: payerAsset.id,
                    currency: feeExtra.currency,
                  ),
                );
              }
            } else {
              final asset = rule.assetId == noRef ? null : assets[rule.assetId];
              final assetCode =
                  normalizeCurrency(asset?.currency) ?? baseCurrency;
              final billExtra = RecordExtra();
              if (assetCode != baseCurrency) {
                billExtra.currency = billSnapshot(
                  source: assetCode,
                  sourceMinor: rule.moneyMinor,
                  account: assetCode,
                  assetMinor: rule.moneyMinor,
                  rates: rateTable,
                );
              }

              final recordId = _uuid.v4();
              final companion = RecordsCompanion.insert(
                recordId: recordId,
                type: rule.recordType,
                subType: const Value(RecordDirection.none),
                moneyMinor: Money.minor(rule.moneyMinor).storageMinor,
                remark: Value(rule.remark),
                recordTime: baseTime,
                recordCatId: Value(rule.catId),
                assetId: Value(rule.assetId),
                fromAssetId: const Value(noRef),
                toAssetId: const Value(noRef),
                accountBookId: rule.bookId,
                excludeBudget: Value(rule.excludeBudget),
                excludeExIn: Value(rule.excludeExIn),
                platformId: const Value(noRef),
                periodId: Value(rule.id),
                images: Value(rule.images),
                extraInfo: Value(billExtra.encode()),
                createDate: Value(effectiveNow),
              );

              await db.into(db.records).insert(companion);
              await _insertTags(recordId, resolvedTagIds);
              generatedRecordIds.add(recordId);
              allFacts.add(
                EntryFacts(
                  type: rule.recordType,
                  moneyMinor: rule.moneyMinor,
                  assetId: rule.assetId,
                  currency: billExtra.currency,
                ),
              );
            }
          }

          await (db.update(
            db.recordPeriods,
          )..where((t) => t.id.equals(rule.id))).write(
            RecordPeriodsCompanion(
              lastAddDate: Value(plan.nextLastAddDateMs),
              periodAddTimes: Value(plan.nextAddTimes),
              state: Value(plan.nextState),
            ),
          );
          if (plan.nextState == PeriodState.ended) {
            endedRuleIds.add(rule.id);
          }
        }

        if (allFacts.isNotEmpty) {
          final net = netEffects(after: allFacts);
          for (final entry in net.entries) {
            final asset = assets[entry.key]!;
            final updatedBalance = Money.minor(
              asset.balanceMinor + entry.value,
            );
            await (db.update(
              db.assets,
            )..where((t) => t.id.equals(entry.key))).write(
              AssetsCompanion(balanceMinor: Value(updatedBalance.storageMinor)),
            );
          }
          await _touchAssets(allFacts);
        }

        return CatchUpResult(
          generatedRecordIds: generatedRecordIds,
          feeRecordIds: feeRecordIds,
          endedRuleIds: endedRuleIds,
          skippedRules: skippedRules,
        );
      }),
    ),
  );

  // ---- helpers ----

  Future<RecordPeriod> _requirePeriod(int id) async {
    final row = await (db.select(
      db.recordPeriods,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (row == null) {
      throw const Failure(FailureCode.conflict, '周期记账规则不存在或已删除');
    }
    return row;
  }

  Future<void> _validateDraft(PeriodicDraft d) async {
    validatePeriodicRecordType(d.recordType);
    if (d.money.scale != Money.ledgerScale) {
      throw const Failure(FailureCode.scaleMismatch, '金额须为两位小数');
    }
    if (d.money.units <= BigInt.zero) {
      throw const Failure(FailureCode.validation, '金额须大于 0');
    }
    d.money.storageMinor;

    if (d.fee != null) {
      if (d.fee!.scale != Money.ledgerScale) {
        throw const Failure(FailureCode.scaleMismatch, '手续费须为两位小数');
      }
      if (d.fee!.isNegative) {
        throw const Failure(FailureCode.validation, '手续费不能为负数');
      }
      d.fee!.storageMinor;
    }

    if (d.remark.length > 2000) {
      throw const Failure(FailureCode.validation, '备注过长');
    }

    final book = await (db.select(
      db.accountBooks,
    )..where((t) => t.id.equals(d.bookId))).getSingleOrNull();
    if (book == null) {
      throw const Failure(FailureCode.validation, '账本不存在');
    }

    if (d.recordType == RecordType.transfer) {
      if (d.assetId == noRef) {
        throw const Failure(FailureCode.validation, '请选择转出账户');
      }
      if (d.assetId2 == noRef) {
        throw const Failure(FailureCode.validation, '请选择转入账户');
      }
      if (d.assetId == d.assetId2) {
        throw const Failure(FailureCode.validation, '转出和转入账户不能相同');
      }
      final fromAsset = await _requireActiveAsset(d.assetId, '转出账户');
      final toAsset = await _requireActiveAsset(d.assetId2, '转入账户');
      await _validateAssetCurrency(fromAsset);
      await _validateAssetCurrency(toAsset);
    } else {
      final cat = await (db.select(
        db.recordCategories,
      )..where((t) => t.id.equals(d.categoryId))).getSingleOrNull();
      if (cat == null ||
          cat.type != d.recordType ||
          cat.accountBookId != d.bookId) {
        throw const Failure(FailureCode.validation, '请选择当前账本的对应分类');
      }
      if (d.assetId != noRef) {
        final asset = await _requireActiveAsset(d.assetId, '账户');
        await _validateAssetCurrency(asset);
      }
    }

    clampFrequency(d.periodType, d.frequency);
    encodePeriodTypeDateJson(d.periodType, d.periodTypeDates);

    final endMode = classifyPeriodEndDate(d.periodEndDate);
    if (endMode == PeriodEndMode.date) {
      final startCal = CalendarDate.fromEpochMs(d.periodStartDate);
      final endCal = CalendarDate.fromEpochMs(d.periodEndDate);
      if (endCal.isBefore(startCal)) {
        throw const Failure(FailureCode.validation, '截止日期不能早于开始日期');
      }
    }

    if (d.recordTimeEnabled && parseHourMinute(d.recordTime) == null) {
      throw const Failure(FailureCode.validation, '请设置有效的记账时间 (HH:mm)');
    }
  }

  Future<Asset> _requireActiveAsset(int id, String label) async {
    final asset = await (db.select(
      db.assets,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (asset == null) {
      throw Failure(FailureCode.validation, '$label不存在');
    }
    if (asset.status != AssetStatus.active) {
      throw Failure(FailureCode.validation, '$label已隐藏或归档，不可用于周期记账');
    }
    return asset;
  }

  Future<void> _validateAssetCurrency(Asset asset) async {
    final code = normalizeCurrency(asset.currency);
    if (code == null || code == baseCurrency) return;
    final row = await (db.select(
      db.currencies,
    )..where((t) => t.code.equals(code))).getSingleOrNull();
    if (row == null || !row.enable) {
      throw Failure(FailureCode.validation, '请先配置币种 $code 的有效汇率');
    }
    final rate = DecimalValue.parse(row.rateToAnchor);
    if (rate.coefficient <= BigInt.zero) {
      throw Failure(FailureCode.validation, '币种 $code 的汇率无效');
    }
  }

  String? _checkRuleTargetValidity({
    required RecordPeriod rule,
    required Map<int, AccountBook> books,
    required Map<int, RecordCategory> categories,
    required Map<int, Asset> assets,
    required Set<String> positiveRates,
  }) {
    if (!books.containsKey(rule.bookId)) {
      return '关联账本不存在';
    }
    if (rule.moneyMinor <= BigInt.zero || rule.feeMinor.isNegative) {
      return '规则金额配置异常';
    }

    if (rule.recordType == RecordType.transfer) {
      if (rule.assetId == noRef) return '转出账户缺失';
      if (rule.assetId2 == noRef) return '转入账户缺失';
      if (rule.assetId == rule.assetId2) return '转出与转入账户相同';
      final fromAsset = assets[rule.assetId];
      if (fromAsset == null) return '转出账户已删除';
      if (fromAsset.status != AssetStatus.active) return '转出账户已隐藏或归档';
      final toAsset = assets[rule.assetId2];
      if (toAsset == null) return '转入账户已删除';
      if (toAsset.status != AssetStatus.active) return '转入账户已隐藏或归档';

      final fromCode = normalizeCurrency(fromAsset.currency) ?? baseCurrency;
      final toCode = normalizeCurrency(toAsset.currency) ?? baseCurrency;
      if (!positiveRates.contains(fromCode) ||
          !positiveRates.contains(toCode)) {
        return '外币汇率未配置或无效';
      }
      return null;
    }

    if (rule.recordType != RecordType.expense &&
        rule.recordType != RecordType.income) {
      return '不支持的周期账单类型';
    }

    final cat = categories[rule.catId];
    if (cat == null ||
        cat.accountBookId != rule.bookId ||
        cat.type != rule.recordType) {
      return '关联分类不存在或已变更';
    }

    if (rule.assetId != noRef) {
      final asset = assets[rule.assetId];
      if (asset == null) return '关联账户已删除';
      if (asset.status != AssetStatus.active) return '关联账户已隐藏或归档';
      final code = normalizeCurrency(asset.currency) ?? baseCurrency;
      if (!positiveRates.contains(code)) {
        return '外币汇率未配置或无效';
      }
    }
    return null;
  }

  List<String> _resolveTagIds(
    String? tagsColumn, {
    required Map<String, Tag> tagById,
    required Map<String, Tag> tagByName,
  }) {
    final tokens = parsePeriodTagTokens(tagsColumn);
    if (tokens.isEmpty) return const [];
    final seen = <String>{};
    final out = <String>[];
    for (final token in tokens) {
      final byId = tagById[token];
      if (byId != null) {
        if (seen.add(byId.tagId)) out.add(byId.tagId);
        continue;
      }
      final byName = tagByName[token];
      if (byName != null) {
        if (seen.add(byName.tagId)) out.add(byName.tagId);
      }
    }
    return out;
  }

  Future<void> _insertTags(String recordId, List<String> tagIds) async {
    for (final tagId in tagIds.toSet()) {
      await db
          .into(db.tagRecords)
          .insert(
            TagRecordsCompanion.insert(tagId: tagId, recordId: recordId),
            mode: InsertMode.insertOrIgnore,
          );
    }
  }

  Future<void> _touchAssets(Iterable<EntryFacts> facts) async {
    final counts = <int, int>{};
    for (final f in facts) {
      for (final id in {f.assetId, f.fromAssetId, f.toAssetId}) {
        if (id != noRef) {
          counts[id] = (counts[id] ?? 0) + 1;
        }
      }
    }
    for (final entry in counts.entries) {
      await db.customUpdate(
        'UPDATE asset SET used_times = used_times + ? WHERE id = ?',
        variables: [Variable.withInt(entry.value), Variable.withInt(entry.key)],
        updates: {db.assets},
      );
    }
  }
}
