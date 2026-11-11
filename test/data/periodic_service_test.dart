import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/catalog/catalog_service.dart';
import 'package:tallyisle/data/catalog/currency_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/data/periodic/periodic_service.dart';
import 'package:tallyisle/data/repo/periodic_queries.dart';
import 'package:tallyisle/domain/ledger/record_extra.dart';
import 'package:tallyisle/domain/ledger/record_relations.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/periodic_records.dart';

void main() {
  test(
    'savePeriod persists PB-11 clamped frequencies and enforces commandId idempotency',
    () async {
      final now = DateTime(2026, 3, 5, 10, 0).millisecondsSinceEpoch;
      final db = AppDatabase(NativeDatabase.memory(), nowMs: () => now);
      addTearDown(db.close);

      final service = PeriodicService(db);
      final queries = PeriodicQueries(db);
      final startMs = const CalendarDate(2026, 3, 1).startOfDayMs;

      final dailyId = await service.savePeriod(
        commandId: 'cmd-pb11-daily',
        draft: PeriodicDraft(
          recordType: RecordType.expense,
          money: Money.parse('20.00'),
          bookId: 1,
          categoryId: 1,
          periodType: PeriodType.daily,
          frequency: 120,
          periodStartDate: startMs,
        ),
      );
      // Exact replay returns identical ID
      final replayId = await service.savePeriod(
        commandId: 'cmd-pb11-daily',
        draft: PeriodicDraft(
          recordType: RecordType.expense,
          money: Money.parse('20.00'),
          bookId: 1,
          categoryId: 1,
          periodType: PeriodType.daily,
          frequency: 120,
          periodStartDate: startMs,
        ),
      );
      expect(replayId, dailyId);

      // Mutated payload with same commandId throws conflict
      await expectLater(
        service.savePeriod(
          commandId: 'cmd-pb11-daily',
          draft: PeriodicDraft(
            recordType: RecordType.expense,
            money: Money.parse('99.00'),
            bookId: 1,
            categoryId: 1,
            periodType: PeriodType.daily,
            frequency: 120,
            periodStartDate: startMs,
          ),
        ),
        throwsA(
          isA<Failure>().having((f) => f.code, 'code', FailureCode.conflict),
        ),
      );

      final weeklyId = await service.savePeriod(
        commandId: 'cmd-pb11-weekly',
        draft: PeriodicDraft(
          recordType: RecordType.expense,
          money: Money.parse('30.00'),
          bookId: 1,
          categoryId: 1,
          periodType: PeriodType.weekly,
          periodTypeDates: const ['5', '1'],
          frequency: 5,
          periodStartDate: startMs,
        ),
      );
      final monthlyId = await service.savePeriod(
        commandId: 'cmd-pb11-monthly',
        draft: PeriodicDraft(
          recordType: RecordType.expense,
          money: Money.parse('40.00'),
          bookId: 1,
          categoryId: 1,
          periodType: PeriodType.monthly,
          periodTypeDates: const ['-12', '31', '1'],
          frequency: 15,
          periodStartDate: startMs,
        ),
      );

      expect((await queries.getPeriod(dailyId))!.frequency, 100);
      final weeklyRow = (await queries.getPeriod(weeklyId))!;
      expect(weeklyRow.frequency, 3);
      expect(weeklyRow.periodTypeDate, '["1","5"]');

      final monthlyRow = (await queries.getPeriod(monthlyId))!;
      expect(monthlyRow.frequency, 10);
      expect(monthlyRow.periodTypeDate, '["1","31","-12"]');
    },
  );

  test(
    'ASYM-PB-05: transfer with fee sets periodId on BOTH parent and child, inherits exclusions, deduplicates tags, and updates balances atomically',
    () async {
      final now = DateTime(2026, 3, 5, 14, 30).millisecondsSinceEpoch;
      final db = AppDatabase(NativeDatabase.memory(), nowMs: () => now);
      addTearDown(db.close);

      final ledger = LedgerService(db);
      final catalog = CatalogService(db);
      final service = PeriodicService(db);
      final queries = PeriodicQueries(db);

      final fromId = await ledger.createAsset(
        commandId: 'asset-from',
        name: '招商储蓄卡',
        initial: Money.parse('5000.00'),
      );
      final toId = await ledger.createAsset(
        commandId: 'asset-to',
        name: '零钱通',
        initial: Money.parse('200.00'),
      );
      final tag1 = await catalog.createTag(commandId: 'tag-1', name: '固定转账');

      // Golden vector: transfer 1000.00 + fee 5.00
      final periodId = await service.savePeriod(
        commandId: 'save-transfer-rule',
        draft: PeriodicDraft(
          recordType: RecordType.transfer,
          money: Money.parse('1000.00'),
          fee: Money.parse('5.00'),
          feeFromTarget: false,
          bookId: 1,
          assetId: fromId,
          assetId2: toId,
          periodType: PeriodType.daily,
          frequency: 1,
          periodStartDate: const CalendarDate(2026, 3, 5).startOfDayMs,
          periodEndDate: 1,
          excludeBudget: true,
          excludeExIn: true,
          remark: '每月房贷储蓄',
          tagIds: [tag1, tag1, 'non-existent-deleted-tag'],
        ),
      );

      final result = await service.runCatchUp();
      expect(result.generatedCount, 1);
      expect(result.totalRowsWritten, 2);
      expect(result.endedRuleIds, [periodId]);
      expect(result.skippedCount, 0);

      // Both parent transfer (type=2) and fee child (type=12, subType=0) have periodId == periodId
      final history = await queries.getHistoryRecords(periodId);
      expect(history, hasLength(2));

      final feeRecord = history.firstWhere((r) => r.type == RecordType.fee);
      final parentRecord = history.firstWhere(
        (r) => r.type == RecordType.transfer,
      );

      expect(parentRecord.periodId, periodId);
      expect(feeRecord.periodId, periodId);
      expect(feeRecord.subType, RecordDirection.expense);
      expect(parentRecord.moneyMinor, BigInt.from(100000));
      expect(feeRecord.moneyMinor, BigInt.from(500));
      expect(feeRecord.assetId, fromId);
      expect(feeRecord.recordTime, parentRecord.recordTime + 1);

      // Exclusion flags inherited on BOTH parent and child
      expect(parentRecord.excludeBudget, isTrue);
      expect(parentRecord.excludeExIn, isTrue);
      expect(feeRecord.excludeBudget, isTrue);
      expect(feeRecord.excludeExIn, isTrue);

      // Bidirectional transfer-fee relation intact
      expect(
        RecordRelations.parse(feeRecord.relInfo).transferFee?.parentId,
        parentRecord.recordId,
      );

      // Deduplicated tag_record links (only live tag1 once per record)
      final parentTags = await (db.select(
        db.tagRecords,
      )..where((t) => t.recordId.equals(parentRecord.recordId))).get();
      final feeTags = await (db.select(
        db.tagRecords,
      )..where((t) => t.recordId.equals(feeRecord.recordId))).get();
      expect(parentTags.map((t) => t.tagId).toList(), [tag1]);
      expect(feeTags.map((t) => t.tagId).toList(), [tag1]);

      // Balances updated atomically via netEffects: 5000 - 1000 - 5 = 3995.00; 200 + 1000 = 1200.00
      final fromAfter = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(fromId))).getSingle();
      final toAfter = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(toId))).getSingle();
      expect(fromAfter.balanceMinor, BigInt.from(399500));
      expect(toAfter.balanceMinor, BigInt.from(120000));

      // Rule auto-ended after hitting count limit 1
      final updatedRule = (await queries.getPeriod(periodId))!;
      expect(updatedRule.state, PeriodState.ended);
      expect(updatedRule.periodAddTimes, 1);
    },
  );

  test(
    'ASYM-PB-01: runCatchUp skips rules with hidden, settled, missing, or invalid-rate accounts without altering balances',
    () async {
      final now = DateTime(2026, 3, 5, 10, 0).millisecondsSinceEpoch;
      final db = AppDatabase(NativeDatabase.memory(), nowMs: () => now);
      addTearDown(db.close);

      final ledger = LedgerService(db);
      final currencyService = CurrencyService(db);
      final service = PeriodicService(db);
      final queries = PeriodicQueries(db);

      final activeAssetId = await ledger.createAsset(
        commandId: 'a-active',
        name: '活跃账户',
        initial: Money.parse('1000.00'),
      );
      final hiddenAssetId = await ledger.createAsset(
        commandId: 'a-hidden',
        name: '即将隐藏账户',
        initial: Money.parse('1000.00'),
      );
      final settledAssetId = await ledger.createAsset(
        commandId: 'a-settled',
        name: '即将归档账户',
        initial: Money.parse('1000.00'),
      );
      final deletedAssetId = await ledger.createAsset(
        commandId: 'a-deleted',
        name: '即将删除账户',
        initial: Money.parse('500.00'),
      );

      await currencyService.saveCurrency(
        commandId: 'curr-usd',
        code: 'USD',
        name: '美元',
        symbol: r'$',
        price: '7.25',
      );
      final usdAssetId = await ledger.createAsset(
        commandId: 'a-usd',
        name: '美元卡',
        initial: Money.parse('200.00', currency: 'USD'),
        currency: 'USD',
      );

      final dueStartMs = const CalendarDate(2026, 3, 5).startOfDayMs;

      final activeRuleId = await service.savePeriod(
        commandId: 'r-active',
        draft: PeriodicDraft(
          recordType: RecordType.expense,
          money: Money.parse('50.00'),
          bookId: 1,
          categoryId: 1,
          assetId: activeAssetId,
          periodType: PeriodType.daily,
          periodStartDate: dueStartMs,
        ),
      );
      final hiddenRuleId = await service.savePeriod(
        commandId: 'r-hidden',
        draft: PeriodicDraft(
          recordType: RecordType.expense,
          money: Money.parse('60.00'),
          bookId: 1,
          categoryId: 1,
          assetId: hiddenAssetId,
          periodType: PeriodType.daily,
          periodStartDate: dueStartMs,
        ),
      );
      final settledRuleId = await service.savePeriod(
        commandId: 'r-settled',
        draft: PeriodicDraft(
          recordType: RecordType.transfer,
          money: Money.parse('70.00'),
          bookId: 1,
          assetId: activeAssetId,
          assetId2: settledAssetId,
          periodType: PeriodType.daily,
          periodStartDate: dueStartMs,
        ),
      );
      final deletedRuleId = await service.savePeriod(
        commandId: 'r-deleted',
        draft: PeriodicDraft(
          recordType: RecordType.expense,
          money: Money.parse('80.00'),
          bookId: 1,
          categoryId: 1,
          assetId: deletedAssetId,
          periodType: PeriodType.daily,
          periodStartDate: dueStartMs,
        ),
      );
      final usdRuleId = await service.savePeriod(
        commandId: 'r-usd',
        draft: PeriodicDraft(
          recordType: RecordType.expense,
          money: Money.parse('10.00'),
          bookId: 1,
          categoryId: 1,
          assetId: usdAssetId,
          periodType: PeriodType.daily,
          periodStartDate: dueStartMs,
        ),
      );

      // Now make hiddenAsset hidden, settledAsset settled, deletedAsset deleted, and corrupt USD rate to 0
      await ledger.setAssetStatus(
        commandId: 'hide-a',
        assetId: hiddenAssetId,
        status: AssetStatus.hidden,
      );
      await ledger.setAssetStatus(
        commandId: 'settle-a',
        assetId: settledAssetId,
        status: AssetStatus.settled,
      );
      // Simulate legacy/imported missing account row directly in DB
      // (LedgerService.deleteAsset guards accounts referenced by record_period).
      await (db.delete(
        db.assets,
      )..where((t) => t.id.equals(deletedAssetId))).go();
      await (db.update(db.currencies)..where((t) => t.code.equals('USD')))
          .write(const CurrenciesCompanion(rateToAnchor: Value('0')));

      final res1 = await service.runCatchUp();
      expect(res1.generatedCount, 1); // Only activeRuleId succeeded
      expect(res1.skippedCount, 4);
      expect(res1.skippedRuleIds, {
        hiddenRuleId,
        settledRuleId,
        deletedRuleId,
        usdRuleId,
      });

      // Hidden & settled & USD balances untouched; active deducted by 50.00
      final hiddenAfter = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(hiddenAssetId))).getSingle();
      final settledAfter = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(settledAssetId))).getSingle();
      final activeAfter = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(activeAssetId))).getSingle();
      expect(hiddenAfter.balanceMinor, BigInt.from(100000));
      expect(settledAfter.balanceMinor, BigInt.from(100000));
      expect(activeAfter.balanceMinor, BigInt.from(95000));

      // Skipped rules retain lastAddDate == -1 and periodAddTimes == 0
      expect(
        (await queries.getPeriod(hiddenRuleId))!.lastAddDate,
        noLastAddDate,
      );
      expect((await queries.getPeriod(activeRuleId))!.periodAddTimes, 1);

      // Reactivating hiddenAsset and restoring valid USD rate allows catch-up to post both
      await ledger.setAssetStatus(
        commandId: 'unhide-a',
        assetId: hiddenAssetId,
        status: AssetStatus.active,
      );
      await currencyService.saveCurrency(
        commandId: 'curr-usd-fix',
        code: 'USD',
        name: '美元',
        symbol: r'$',
        price: '7.25',
      );

      final res2 = await service.runCatchUp();
      expect(res2.generatedCount, 2); // hiddenRuleId + usdRuleId
      expect(res2.skippedRuleIds, {settledRuleId, deletedRuleId});

      final usdHistory = await queries.getHistoryRecords(usdRuleId);
      expect(usdHistory, hasLength(1));
      final snap = RecordExtra.parse(usdHistory.single.extraInfo).currency!;
      expect(snap.sourceCode, 'USD');
      expect(
        snap.baseAmount,
        BigInt.from(7250),
      ); // 10.00 USD * 7.25 = 72.50 CNY
    },
  );

  test(
    'ASYM-PB-06 & mutex: deterministic timestamps ignore existing DB maxTime and concurrent runCatchUp calls never duplicate records',
    () async {
      final nowMs = DateTime(
        2026,
        3,
        5,
        16,
        15,
        30,
        500,
      ).millisecondsSinceEpoch;
      final db = AppDatabase(NativeDatabase.memory(), nowMs: () => nowMs);
      addTearDown(db.close);

      final ledger = LedgerService(db);
      final assetId = await ledger.createAsset(
        commandId: 'a-mutex',
        name: '现金',
        initial: Money.parse('1000.00'),
      );

      // Insert an existing bill at 2026-03-03 18:30:00.500 (would have triggered SQL-PB-09 maxTime+1ms in original APK)
      await ledger.saveRecord(
        commandId: 'existing-bill',
        draft: RecordDraft(
          type: RecordType.expense,
          money: Money.parse('12.00'),
          bookId: 1,
          categoryId: 1,
          recordTime: DateTime(
            2026,
            3,
            3,
            18,
            30,
            0,
            500,
          ).millisecondsSinceEpoch,
        ),
      );

      final s1 = PeriodicService(db);
      final s2 = PeriodicService(db);
      final queries = PeriodicQueries(db);

      final defaultTimeRuleId = await s1.savePeriod(
        commandId: 'r-default-time',
        draft: PeriodicDraft(
          recordType: RecordType.expense,
          money: Money.parse('25.00'),
          bookId: 1,
          categoryId: 1,
          assetId: assetId,
          periodType: PeriodType.daily,
          frequency: 2,
          periodStartDate: const CalendarDate(2026, 3, 3).startOfDayMs,
          recordTimeEnabled: false,
        ),
      );
      final fixedTimeRuleId = await s1.savePeriod(
        commandId: 'r-fixed-time',
        draft: PeriodicDraft(
          recordType: RecordType.expense,
          money: Money.parse('15.00'),
          bookId: 1,
          categoryId: 1,
          assetId: assetId,
          periodType: PeriodType.daily,
          frequency: 2,
          periodStartDate: const CalendarDate(2026, 3, 3).startOfDayMs,
          recordTimeEnabled: true,
          recordTime: '09:05',
        ),
      );

      // Fire 4 concurrent runCatchUp calls across two service instances sharing `db`
      final results = await Future.wait([
        s1.runCatchUp(),
        s2.runCatchUp(),
        s1.runCatchUp(),
        s2.runCatchUp(),
      ]);

      final totalGenerated = results.fold<int>(
        0,
        (sum, r) => sum + r.generatedCount,
      );
      expect(
        totalGenerated,
        4,
      ); // 2 dates (03-03, 03-05) * 2 rules, ZERO duplicates!

      final defaultHistory = await queries.getHistoryRecords(defaultTimeRuleId);
      expect(defaultHistory, hasLength(2));
      // Newest first: 03-05 at nowMs, 03-03 at local 12:00:00.000
      expect(defaultHistory[0].recordTime, nowMs);
      expect(
        defaultHistory[1].recordTime,
        DateTime(2026, 3, 3, 12).millisecondsSinceEpoch,
      );

      final fixedHistory = await queries.getHistoryRecords(fixedTimeRuleId);
      expect(fixedHistory, hasLength(2));
      expect(
        fixedHistory[0].recordTime,
        DateTime(2026, 3, 5, 9, 5).millisecondsSinceEpoch,
      );
      expect(
        fixedHistory[1].recordTime,
        DateTime(2026, 3, 3, 9, 5).millisecondsSinceEpoch,
      );

      // Balance: 1000.00 - (2 * 25.00 + 2 * 15.00) = 920.00
      final assetAfter = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(assetId))).getSingle();
      expect(assetAfter.balanceMinor, BigInt.from(92000));
    },
  );

  test(
    'Pause, resume fast-forward without back-posting, edit startDate, and delete retaining historical records & balances',
    () async {
      var currentNow = DateTime(2026, 3, 1, 10, 0).millisecondsSinceEpoch;
      final db = AppDatabase(NativeDatabase.memory(), nowMs: () => currentNow);
      addTearDown(db.close);

      final ledger = LedgerService(db);
      final service = PeriodicService(db);
      final queries = PeriodicQueries(db);

      final assetId = await ledger.createAsset(
        commandId: 'a-life',
        name: '工资卡',
        initial: Money.parse('1000.00'),
      );

      final periodId = await service.savePeriod(
        commandId: 'create-life',
        draft: PeriodicDraft(
          recordType: RecordType.expense,
          money: Money.parse('50.00'),
          bookId: 1,
          categoryId: 1,
          assetId: assetId,
          periodType: PeriodType.daily,
          frequency: 1,
          periodStartDate: const CalendarDate(2026, 3, 1).startOfDayMs,
        ),
      );

      // 1. Catch up on 2026-03-01 -> posts 1 bill (balance 950.00)
      expect((await service.runCatchUp()).generatedCount, 1);

      // 2. Pause rule on 2026-03-01 -> state = 2
      await service.pausePeriod(commandId: 'pause-life', periodId: periodId);
      expect((await queries.getPeriod(periodId))!.state, PeriodState.paused);

      // 3. Advance clock to 2026-03-05; catch-up does nothing while paused
      currentNow = DateTime(2026, 3, 5, 11, 0).millisecondsSinceEpoch;
      expect((await service.runCatchUp()).generatedCount, 0);

      // 4. Resume on 2026-03-05 -> fast-forwards 03-02..03-04 without back-posting
      await service.resumePeriod(commandId: 'resume-life', periodId: periodId);
      final resumedRule = (await queries.getPeriod(periodId))!;
      expect(resumedRule.state, PeriodState.active);
      expect(
        resumedRule.lastAddDate,
        const CalendarDate(2026, 3, 4).startOfDayMs,
      );
      expect(resumedRule.periodAddTimes, 1);
      expect(await queries.getHistoryRecords(periodId), hasLength(1));

      // 5. Next catch-up on 2026-03-05 posts ONLY 2026-03-05 (1 bill, total 2, balance 900.00)
      expect((await service.runCatchUp()).generatedCount, 1);
      expect(await queries.getHistoryRecords(periodId), hasLength(2));

      // 6. Edit rule moving startDate forward to 2026-03-10 -> resets lastAddDate to -1
      await service.savePeriod(
        commandId: 'edit-life-future',
        periodId: periodId,
        draft: PeriodicDraft(
          recordType: RecordType.expense,
          money: Money.parse('60.00'),
          bookId: 1,
          categoryId: 1,
          assetId: assetId,
          periodType: PeriodType.daily,
          frequency: 1,
          periodStartDate: const CalendarDate(2026, 3, 10).startOfDayMs,
        ),
      );
      expect((await queries.getPeriod(periodId))!.lastAddDate, noLastAddDate);

      // 7. Delete rule -> rule row gone, but historical records & balance (900.00) retained!
      await service.deletePeriod(commandId: 'delete-life', periodId: periodId);
      expect(await queries.getPeriod(periodId), isNull);
      final retainedHistory = await queries.getHistoryRecords(periodId);
      expect(retainedHistory, hasLength(2));

      final assetFinal = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(assetId))).getSingle();
      expect(assetFinal.balanceMinor, BigInt.from(90000));
    },
  );

  test(
    'Cross-currency transfer with feeFromTarget=true and non-forced 10-minute throttle',
    () async {
      var currentNow = DateTime(2026, 3, 5, 10, 0).millisecondsSinceEpoch;
      final db = AppDatabase(NativeDatabase.memory(), nowMs: () => currentNow);
      addTearDown(db.close);

      final ledger = LedgerService(db);
      final currencyService = CurrencyService(db);
      final service = PeriodicService(db);
      final queries = PeriodicQueries(db);

      // 1 USD = 8.00 CNY, 1 GBP = 10.00 CNY -> 10.00 GBP = 100.00 CNY = 12.50 USD
      await currencyService.saveCurrency(
        commandId: 'c-usd',
        code: 'USD',
        name: '美元',
        symbol: r'$',
        price: '8.00',
      );
      await currencyService.saveCurrency(
        commandId: 'c-gbp',
        code: 'GBP',
        name: '英镑',
        symbol: '£',
        price: '10.00',
      );

      final gbpId = await ledger.createAsset(
        commandId: 'a-gbp',
        name: '英镑户',
        initial: Money.parse('100.00', currency: 'GBP'),
        currency: 'GBP',
      );
      final usdId = await ledger.createAsset(
        commandId: 'a-usd',
        name: '美元户',
        initial: Money.parse('50.00', currency: 'USD'),
        currency: 'USD',
      );

      final ruleId = await service.savePeriod(
        commandId: 'fx-transfer-fee-target',
        draft: PeriodicDraft(
          recordType: RecordType.transfer,
          money: Money.parse('10.00', currency: 'GBP'),
          fee: Money.parse('1.00', currency: 'USD'),
          feeFromTarget: true,
          bookId: 1,
          assetId: gbpId,
          assetId2: usdId,
          periodType: PeriodType.daily,
          periodStartDate: const CalendarDate(2026, 3, 5).startOfDayMs,
        ),
      );

      final firstRun = await service.runCatchUp(force: false);
      expect(firstRun.throttled, isFalse);
      expect(firstRun.generatedCount, 1);
      expect(firstRun.totalRowsWritten, 2);

      // Within 10 minutes (including small clock rollback): force=false throttles
      currentNow -= 120000;
      final rolledBack = await service.runCatchUp(force: false);
      expect(rolledBack.throttled, isTrue);

      final history = await queries.getHistoryRecords(ruleId);
      expect(history, hasLength(2));

      // GBP: 100.00 - 10.00 = 90.00; USD: 50.00 + 12.50 - 1.00 = 61.50
      final gbpAfter = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(gbpId))).getSingle();
      final usdAfter = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(usdId))).getSingle();
      expect(gbpAfter.balanceMinor, BigInt.from(9000));
      expect(usdAfter.balanceMinor, BigInt.from(6150));
    },
  );
}
