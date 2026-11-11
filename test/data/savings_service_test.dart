import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/data/repo/savings_queries.dart';
import 'package:tallyisle/data/savings/savings_service.dart';
import 'package:tallyisle/domain/ledger/record_extra.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/savings_plan.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  late LedgerService ledgerService;
  late SavingsService savingsService;
  late SavingsQueries savingsQueries;
  var seq = 0;
  String cmd() => 'savings-cmd-${seq++}';

  BigInt yuan(int whole, [int cents = 0]) => BigInt.from(whole * 100 + cents);

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    ledgerService = LedgerService(db);
    savingsService = SavingsService(db);
    savingsQueries = SavingsQueries(db);
  });

  tearDown(() => db.close());

  Future<int> createAccount(String name, int initialYuan, {String? currency}) =>
      ledgerService.createAsset(
        commandId: cmd(),
        name: name,
        initial: Money.minor(yuan(initialYuan), currency ?? 'CNY'),
        currency: currency,
      );

  Future<BigInt> balanceOf(int assetId) async {
    final row = await (db.select(
      db.assets,
    )..where((t) => t.id.equals(assetId))).getSingle();
    return row.balanceMinor;
  }

  group('PK allocation, idempotency, templates & currency locking', () {
    test(
      'allocates COALESCE(MAX(id), 0) + 1 for plans/records and enforces commandId idempotency',
      () async {
        const start = LocalCalendarDate(2026, 1, 1);
        final tpl365 = SavingsPlanTemplate.days365(start);
        final c1 = cmd();

        final draft365 = SavingsPlanDraft(
          name: tpl365.name,
          planType: tpl365.planType,
          cycleType: tpl365.cycleType,
          startDateMs: tpl365.startDate.startOfDayMs,
          endDateMs: tpl365.endDate.startOfDayMs,
          startMoneyMinor: tpl365.startMoneyMinor,
          incrementalMinor: tpl365.incrementalMinor,
        );

        final id1 = await savingsService.savePlan(
          commandId: c1,
          draft: draft365,
        );
        expect(id1, 1);

        // Idempotent retry returns same id without inserting a second row
        final id1Retry = await savingsService.savePlan(
          commandId: c1,
          draft: draft365,
        );
        expect(id1Retry, 1);
        expect(await savingsQueries.getPlans(), hasLength(1));

        // Same commandId with mutated payload throws FailureCode.conflict
        await expectLater(
          savingsService.savePlan(
            commandId: c1,
            draft: const SavingsPlanDraft(
              name: '不同名称',
              planType: SavingsPlanType.free,
              startDateMs: 0,
              customPlanMoneyMinor: null,
            ),
          ),
          throwsA(
            isA<Failure>().having((f) => f.code, 'code', FailureCode.conflict),
          ),
        );

        // Second plan gets id = 2 and top-of-list sort < first plan's sort
        final tpl52 = SavingsPlanTemplate.weeks52(start);
        final id2 = await savingsService.savePlan(
          commandId: cmd(),
          draft: SavingsPlanDraft(
            name: tpl52.name,
            planType: tpl52.planType,
            cycleType: tpl52.cycleType,
            startDateMs: tpl52.startDate.startOfDayMs,
            endDateMs: tpl52.endDate.startOfDayMs,
            startMoneyMinor: tpl52.startMoneyMinor,
            incrementalMinor: tpl52.incrementalMinor,
          ),
        );
        expect(id2, 2);

        final plans = await savingsQueries.getPlans(
          status: SavingsPlanStatus.active,
        );
        expect(plans.map((p) => p.id).toList(), [2, 1]);
        expect(plans[0].planMoneyMinor, yuan(13780));
        expect(plans[1].planMoneyMinor, yuan(66795));
      },
    );

    test(
      'free plan forbids autoPlan; editing locks currency against mismatched toAsset',
      () async {
        await expectLater(
          savingsService.savePlan(
            commandId: cmd(),
            draft: SavingsPlanDraft(
              name: '违规自动自由计划',
              planType: SavingsPlanType.free,
              startDateMs: const LocalCalendarDate(2026, 3, 1).startOfDayMs,
              customPlanMoneyMinor: yuan(1000),
              autoPlan: true,
            ),
          ),
          throwsA(isA<Failure>()),
        );

        await db
            .into(db.currencies)
            .insert(
              CurrenciesCompanion.insert(
                code: 'USD',
                name: '美元',
                symbol: r'$',
                rateToAnchor: '0.125',
                anchorCode: 'CNY',
              ),
            );
        final usdAsset = await createAccount('美元储蓄', 100, currency: 'USD');
        final cnyAsset = await createAccount('人民币储蓄', 1000);

        final planId = await savingsService.savePlan(
          commandId: cmd(),
          draft: SavingsPlanDraft(
            name: '美元旅行计划',
            planType: SavingsPlanType.free,
            startDateMs: const LocalCalendarDate(2026, 3, 1).startOfDayMs,
            customPlanMoneyMinor: yuan(500),
            toAssetId: usdAsset,
          ),
        );

        // Editing to switch `toAssetId` from USD to CNY must fail validation!
        await expectLater(
          savingsService.savePlan(
            commandId: cmd(),
            planId: planId,
            draft: SavingsPlanDraft(
              name: '美元旅行计划',
              planType: SavingsPlanType.free,
              startDateMs: const LocalCalendarDate(2026, 3, 1).startOfDayMs,
              customPlanMoneyMinor: yuan(500),
              toAssetId: cnyAsset,
            ),
          ),
          throwsA(isA<Failure>()),
        );
      },
    );
  });

  group('R5 Transfer linkage, SP-23 back-calc, FX snapshot & CE-SP-08', () {
    test(
      'manual check-in inserts transfer record in target book, updates balances, and SP-23 back-calc works',
      () async {
        // Create Book 2 (旅行账本) to verify CE-SP-01 global visibility + target book routing
        await db
            .into(db.accountBooks)
            .insert(
              AccountBooksCompanion.insert(
                id: const Value(2),
                name: '旅行账本',
                createDate: 1700000000000,
              ),
            );

        final fromId = await createAccount('招行储蓄卡', 5000);
        final toId = await createAccount('心愿存钱罐', 1000);

        final planId = await savingsService.savePlan(
          commandId: cmd(),
          draft: SavingsPlanDraft(
            name: '海岛游',
            planType: SavingsPlanType.free,
            startDateMs: const LocalCalendarDate(2026, 3, 1).startOfDayMs,
            customPlanMoneyMinor: yuan(500),
            fromAssetId: fromId,
            toAssetId: toId,
            bookId: 2,
          ),
        );

        // Step 1: Direct deposit of 300.00
        final rec1Id = await savingsService.checkIn(
          commandId: cmd(),
          planId: planId,
          amountMinor: yuan(300),
          recordDateMs: DateTime(2026, 3, 1, 10, 0).millisecondsSinceEpoch,
          remark: '首笔存入',
        );
        expect(rec1Id, 1);
        expect(await balanceOf(fromId), yuan(4700));
        expect(await balanceOf(toId), yuan(1300));

        // Step 2: Golden vector SP-23 cumulative target 500.00 -> back-calculates 200.00
        // and auto-archives because saved (500) >= target (500)!
        final rec2Id = await savingsService.checkIn(
          commandId: cmd(),
          planId: planId,
          targetCumulativeMinor: yuan(500),
          recordDateMs: DateTime(2026, 3, 2, 11, 0).millisecondsSinceEpoch,
        );
        expect(rec2Id, 2);
        expect(await balanceOf(fromId), yuan(4500));
        expect(await balanceOf(toId), yuan(1500));

        final updatedPlan = await savingsQueries.getPlan(planId);
        expect(updatedPlan!.savedMoneyMinor, yuan(500));
        expect(updatedPlan.status, SavingsPlanStatus.archived);

        // Verify both generated Record(type=2) rows landed in Book 2 with remark '存钱 - 海岛游'
        final transfers = await (db.select(
          db.records,
        )..where((t) => t.type.equals(RecordType.transfer))).get();
        expect(transfers, hasLength(2));
        for (final tr in transfers) {
          expect(tr.accountBookId, 2);
          expect(tr.remark, '存钱 - 海岛游');
        }
      },
    );

    test(
      'degrades cleanly to plan-only record (recordId = null) when account is inactive or unbound (CE-SP-04)',
      () async {
        final fromId = await createAccount('工资卡', 2000);
        final toId = await createAccount('定存罐', 500);

        final planId = await savingsService.savePlan(
          commandId: cmd(),
          draft: SavingsPlanDraft(
            name: '零钱罐',
            planType: SavingsPlanType.fixed,
            cycleType: SavingsCycleType.daily,
            startDateMs: const LocalCalendarDate(2026, 3, 1).startOfDayMs,
            endDateMs: const LocalCalendarDate(2026, 3, 2).startOfDayMs,
            startMoneyMinor: yuan(50),
            fromAssetId: fromId,
            toAssetId: toId,
          ),
        );

        // Hide `toAsset` (status = 1) before check-in
        await ledgerService.setAssetStatus(
          commandId: cmd(),
          assetId: toId,
          status: AssetStatus.hidden,
        );

        await savingsService.checkIn(
          commandId: cmd(),
          planId: planId,
          amountMinor: yuan(50),
          recordDateMs: DateTime(2026, 3, 1, 9, 0).millisecondsSinceEpoch,
        );

        final records = await savingsQueries.getPlanRecords(planId);
        expect(records, hasLength(1));
        expect(records.first.recordId, isNull);
        expect(records.first.fromAssetId, noRef);
        expect(records.first.toAssetId, noRef);

        // Account balances stay untouched
        expect(await balanceOf(fromId), yuan(2000));
        expect(await balanceOf(toId), yuan(500));
      },
    );

    test(
      'SP-502 & CE-SP-08: multi-currency transfer updates exact balances & halts when rate <= 0',
      () async {
        await db
            .into(db.currencies)
            .insert(
              CurrenciesCompanion.insert(
                code: 'USD',
                name: '美元',
                symbol: r'$',
                rateToAnchor: '0.125', // 1 USD = 8.00 CNY
                anchorCode: 'CNY',
              ),
            );
        await db
            .into(db.currencies)
            .insert(
              CurrenciesCompanion.insert(
                code: 'JPY',
                name: '日元',
                symbol: '¥',
                rateToAnchor: '0', // invalid rate <= 0
                anchorCode: 'CNY',
              ),
            );

        final cnyFrom = await createAccount('招行CNY', 5000);
        final usdTo = await createAccount('美元定存户', 200, currency: 'USD');
        final jpyTo = await createAccount('日元信封', 1000, currency: 'JPY');

        final usdPlanId = await savingsService.savePlan(
          commandId: cmd(),
          draft: SavingsPlanDraft(
            name: '每周100刀',
            planType: SavingsPlanType.fixed,
            cycleType: SavingsCycleType.weekly,
            startDateMs: const LocalCalendarDate(2026, 3, 3).startOfDayMs,
            endDateMs: const LocalCalendarDate(2026, 3, 10).startOfDayMs,
            startMoneyMinor: yuan(100),
            autoPlan: true,
            fromAssetId: cnyFrom,
            toAssetId: usdTo,
          ),
        );

        final jpyPlanId = await savingsService.savePlan(
          commandId: cmd(),
          draft: SavingsPlanDraft(
            name: '日元储蓄',
            planType: SavingsPlanType.fixed,
            cycleType: SavingsCycleType.daily,
            startDateMs: const LocalCalendarDate(2026, 3, 3).startOfDayMs,
            endDateMs: const LocalCalendarDate(2026, 3, 4).startOfDayMs,
            startMoneyMinor: yuan(500),
            autoPlan: true,
            fromAssetId: cnyFrom,
            toAssetId: jpyTo,
          ),
        );

        // Manual check-in on JPY plan with 0 rate throws clean validation Failure
        await expectLater(
          savingsService.checkIn(
            commandId: cmd(),
            planId: jpyPlanId,
            amountMinor: yuan(500),
            recordDateMs: DateTime(2026, 3, 3, 10, 0).millisecondsSinceEpoch,
          ),
          throwsA(isA<Failure>()),
        );

        // runAutoSave on 2026-03-03 executes USD plan (A101 -800 CNY, A103 +100 USD)
        // and cleanly halts JPY plan without writing corrupt records!
        final result = await savingsService.runAutoSave(
          DateTime(2026, 3, 3, 15, 0).millisecondsSinceEpoch,
        );
        expect(result.createdRecordCount, 1);
        expect(result.haltedPlanIds, [jpyPlanId]);

        expect(await balanceOf(cnyFrom), yuan(4200));
        expect(await balanceOf(usdTo), yuan(300));
        expect(await balanceOf(jpyTo), yuan(1000));

        final usdRecords = await savingsQueries.getPlanRecords(usdPlanId);
        expect(usdRecords, hasLength(1));
        final tr =
            await (db.select(db.records)
                  ..where((t) => t.recordId.equals(usdRecords.first.recordId!)))
                .getSingle();
        expect(tr.moneyMinor, yuan(800));
        final snap = RecordExtra.parse(tr.extraInfo).currency!;
        expect(snap.sourceCode, 'CNY');
        expect(snap.sourceGross, yuan(800));
        expect(snap.assetCode, 'USD');
        expect(snap.assetNet, yuan(100));

        final updatedUsdPlan = await savingsQueries.getPlan(usdPlanId);
        expect(
          updatedUsdPlan!.nextSaveDate,
          const LocalCalendarDate(2026, 3, 10).startOfDayMs,
        );
        expect(await savingsQueries.getPlanRecords(jpyPlanId), isEmpty);
      },
    );
  });

  group(
    'R3 Natural-day idempotency, mutex serialization & DR-SP-05 cancel/unarchive',
    () {
      test(
        'CE-SP-02: manual wall-clock check-in + re-enabling autoPlan never double-deducts same day, even under concurrent runAutoSave',
        () async {
          final fromId = await createAccount('活期卡', 1000);
          final toId = await createAccount('存钱罐', 0);

          final planId = await savingsService.savePlan(
            commandId: cmd(),
            draft: SavingsPlanDraft(
              name: '三日挑战',
              planType: SavingsPlanType.incremental,
              cycleType: SavingsCycleType.daily,
              startDateMs: const LocalCalendarDate(2026, 3, 1).startOfDayMs,
              endDateMs: const LocalCalendarDate(2026, 3, 3).startOfDayMs,
              startMoneyMinor: yuan(10),
              incrementalMinor: yuan(5), // slots: 10, 15, 20 -> total 45
              autoPlan: false,
              fromAssetId: fromId,
              toAssetId: toId,
            ),
          );

          // User manually checks in slot 2026-03-02 at wall-clock 12:30:00.000 (not 00:00:00.000!)
          await savingsService.checkIn(
            commandId: cmd(),
            planId: planId,
            amountMinor: yuan(15),
            recordDateMs: DateTime(2026, 3, 2, 12, 30).millisecondsSinceEpoch,
          );
          expect(await balanceOf(fromId), yuan(985));
          expect(await balanceOf(toId), yuan(15));

          // User edits plan to turn autoPlan ON (nextSaveDate resets to 2026-03-01 00:00:00.000)
          await savingsService.savePlan(
            commandId: cmd(),
            planId: planId,
            draft: SavingsPlanDraft(
              name: '三日挑战',
              planType: SavingsPlanType.incremental,
              cycleType: SavingsCycleType.daily,
              startDateMs: const LocalCalendarDate(2026, 3, 1).startOfDayMs,
              endDateMs: const LocalCalendarDate(2026, 3, 3).startOfDayMs,
              startMoneyMinor: yuan(10),
              incrementalMinor: yuan(5),
              autoPlan: true,
              fromAssetId: fromId,
              toAssetId: toId,
            ),
          );

          // Fire 3 concurrent runAutoSave calls on 2026-03-03 across two service instances!
          final nowMs = DateTime(2026, 3, 3, 18, 0).millisecondsSinceEpoch;
          final secondService = SavingsService(db);
          final results = await Future.wait([
            savingsService.runAutoSave(nowMs),
            savingsService.runAutoSave(nowMs),
            secondService.runAutoSave(nowMs),
          ]);

          // Only 2026-03-01 (10) and 2026-03-03 (20) are auto-saved; 2026-03-02 (15) is NOT duplicated!
          final totalCreated = results.fold<int>(
            0,
            (sum, r) => sum + r.createdRecordCount,
          );
          expect(totalCreated, 2);

          final allPlanRecords = await savingsQueries.getPlanRecords(planId);
          expect(allPlanRecords, hasLength(3));
          expect(await balanceOf(fromId), yuan(955));
          expect(await balanceOf(toId), yuan(45));

          final finalPlan = await savingsQueries.getPlan(planId);
          expect(finalPlan!.savedMoneyMinor, yuan(45));
          expect(finalPlan.status, SavingsPlanStatus.archived);
        },
      );

      test(
        'Golden vector DR-SP-05: cancelDeposit reverses transfer balances and auto-unarchives status 1 -> 0',
        () async {
          final fromId = await createAccount('转出户', 2000);
          final toId = await createAccount('转入户', 0);

          final planId = await savingsService.savePlan(
            commandId: cmd(),
            draft: SavingsPlanDraft(
              name: '千元目标',
              planType: SavingsPlanType.free,
              startDateMs: const LocalCalendarDate(2026, 3, 1).startOfDayMs,
              customPlanMoneyMinor: yuan(1000),
              fromAssetId: fromId,
              toAssetId: toId,
            ),
          );

          await savingsService.checkIn(
            commandId: cmd(),
            planId: planId,
            amountMinor: yuan(800),
            recordDateMs: DateTime(2026, 3, 1, 10, 0).millisecondsSinceEpoch,
          );
          final rec200Id = await savingsService.checkIn(
            commandId: cmd(),
            planId: planId,
            amountMinor: yuan(200),
            recordDateMs: DateTime(2026, 3, 2, 10, 0).millisecondsSinceEpoch,
          );

          var plan = await savingsQueries.getPlan(planId);
          expect(plan!.savedMoneyMinor, yuan(1000));
          expect(plan.status, SavingsPlanStatus.archived);
          expect(await balanceOf(fromId), yuan(1000));
          expect(await balanceOf(toId), yuan(1000));

          // Cancel the 200.00 deposit -> saved becomes 800.00, status auto-restores to 0!
          await savingsService.cancelDeposit(
            commandId: cmd(),
            planRecordId: rec200Id,
          );

          plan = await savingsQueries.getPlan(planId);
          expect(plan!.savedMoneyMinor, yuan(800));
          expect(plan.status, SavingsPlanStatus.active);
          expect(await balanceOf(fromId), yuan(1200));
          expect(await balanceOf(toId), yuan(800));
          expect(
            await (db.select(
              db.records,
            )..where((t) => t.type.equals(RecordType.transfer))).get(),
            hasLength(1),
          );
        },
      );

      test(
        'NP-SP-03, healSavedMoney, setPlanArchived, and deletePlan live-transfer check',
        () async {
          final fromId = await createAccount('钱包A', 1000);
          final toId = await createAccount('钱包B', 0);

          final planId = await savingsService.savePlan(
            commandId: cmd(),
            draft: SavingsPlanDraft(
              name: '测试删除与外部删单',
              planType: SavingsPlanType.free,
              startDateMs: const LocalCalendarDate(2026, 3, 1).startOfDayMs,
              customPlanMoneyMinor: yuan(500),
              fromAssetId: fromId,
              toAssetId: toId,
            ),
          );

          final r1 = await savingsService.checkIn(
            commandId: cmd(),
            planId: planId,
            amountMinor: yuan(100),
            recordDateMs: DateTime(2026, 3, 1, 10, 0).millisecondsSinceEpoch,
          );
          await savingsService.checkIn(
            commandId: cmd(),
            planId: planId,
            amountMinor: yuan(150),
            recordDateMs: DateTime(2026, 3, 2, 10, 0).millisecondsSinceEpoch,
          );
          expect(await balanceOf(fromId), yuan(750));
          expect(await balanceOf(toId), yuan(250));

          // User deletes r1's transfer bill externally via LedgerService
          final recordsBefore = await savingsQueries.getPlanRecords(planId);
          final r1Row = recordsBefore.firstWhere((r) => r.id == r1);
          await ledgerService.deleteRecord(
            commandId: cmd(),
            recordId: r1Row.recordId!,
          );
          expect(await balanceOf(fromId), yuan(850));
          expect(await balanceOf(toId), yuan(150));

          // Cancelling r1 in SavingsService must NOT double-reverse balances!
          await savingsService.cancelDeposit(
            commandId: cmd(),
            planRecordId: r1,
          );
          expect(await balanceOf(fromId), yuan(850));
          expect(await balanceOf(toId), yuan(150));

          // Corrupt saved_money_minor manually and verify healSavedMoney fixes it without changing status
          await savingsService.setPlanArchived(
            commandId: cmd(),
            planId: planId,
            archived: true,
          );
          await (db.update(
            db.moneySavePlans,
          )..where((t) => t.id.equals(planId))).write(
            MoneySavePlansCompanion(savedMoneyMinor: Value(yuan(120))),
          );
          final healed = await savingsService.healSavedMoney(planId);
          expect(healed, yuan(150));
          final healedPlan = await savingsQueries.getPlan(planId);
          expect(healedPlan!.savedMoneyMinor, yuan(150));
          expect(healedPlan.status, SavingsPlanStatus.archived);

          // Delete plan with deleteLinkedTransfers: true -> reverses remaining live 150 transfer!
          await savingsService.deletePlan(
            commandId: cmd(),
            planId: planId,
            deleteLinkedTransfers: true,
          );
          expect(await savingsQueries.getPlan(planId), isNull);
          expect(await savingsQueries.getPlanRecords(planId), isEmpty);
          expect(await balanceOf(fromId), yuan(1000));
          expect(await balanceOf(toId), BigInt.zero);
        },
      );
    },
  );
}
