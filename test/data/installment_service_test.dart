import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/catalog/currency_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/installment/installment_service.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/data/repo/installment_queries.dart';
import 'package:tallyisle/domain/ledger/asset_json.dart';
import 'package:tallyisle/domain/ledger/record_extra.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/asset_overview.dart';
import 'package:tallyisle/domain/rules/credit_cycle.dart'
    show calculateCardDisplayBalance;
import 'package:tallyisle/domain/rules/installment_rules.dart';

void main() {
  BigInt m(int minor) => BigInt.from(minor);

  Future<int> insertAsset(
    AppDatabase db, {
    required String name,
    int type = AssetType.normal,
    int status = AssetStatus.active,
    int balanceMinor = 0,
    int initMoneyMinor = 0,
    String? currency,
    String? creditInfo,
  }) => db
      .into(db.assets)
      .insert(
        AssetsCompanion.insert(
          name: name,
          type: type,
          status: Value(status),
          balanceMinor: m(balanceMinor),
          initMoneyMinor: m(initMoneyMinor),
          currency: Value(currency),
          creditInfo: Value(creditInfo),
          createDate: db.nowMs(),
        ),
      );

  test(
    'categorized vs uncategorized bills, fee record, tags, and AL-30 balance conservation',
    () async {
      var clockMs = DateTime(2026, 6, 10, 9, 30).millisecondsSinceEpoch;
      final db = AppDatabase(NativeDatabase.memory(), nowMs: () => clockMs);
      addTearDown(db.close);

      await db
          .into(db.tags)
          .insert(TagsCompanion.insert(tagId: 't1', name: '数码'));
      final cashId = await insertAsset(
        db,
        name: '储蓄卡',
        balanceMinor: 500000, // 5000.00
      );

      final service = InstallmentService(db);
      final queries = InstallmentQueries(db);

      // 1. Categorized installment (catId=2 '购物' -> RecordType.expense = 0)
      final catInstId = await service.createInstallment(
        commandId: 'cmd-cat-1',
        draft: InstallmentDraft(
          name: '平板分期',
          catId: 2,
          principal: Money.parse('600.00'),
          periods: 3,
          charge: Money.parse('15.00'),
          chargeWay: InstallmentChargeWay.firstPeriod, // all 15.00 in period 1
          startDateMs: DateTime(2026, 6, 15).millisecondsSinceEpoch,
          assetId: cashId,
          bookId: 1,
          excludeBudget: true,
          excludeExIn: true,
          tagIds: const ['t1'],
        ),
      );

      // Period 1 has principal 200.00 + fee 15.00 -> 2 records
      final p1Ids = await service.postPeriod(
        commandId: 'cmd-cat-p1',
        installmentId: catInstId,
      );
      expect(p1Ids, hasLength(2));

      final detailAfterP1 = await queries.getInstallmentDetail(catInstId);
      final p1Records = detailAfterP1!.recordsForPeriod(1);
      expect(p1Records, hasLength(2));
      final p1Principal = p1Records.firstWhere(
        (r) => r.type == RecordType.expense,
      );
      final p1Fee = p1Records.firstWhere((r) => r.type == RecordType.fee);
      expect(p1Principal.subType, RecordDirection.none);
      expect(p1Principal.recordCatId, 2);
      expect(p1Principal.moneyMinor, m(20000));
      expect(p1Principal.installment, '$catInstId-1');
      expect(p1Principal.excludeBudget, isTrue);
      expect(p1Principal.excludeExIn, isTrue);

      expect(p1Fee.subType, RecordDirection.expense);
      expect(p1Fee.recordCatId, noRef);
      expect(p1Fee.moneyMinor, m(1500));
      expect(p1Fee.installment, '$catInstId-1');
      expect(p1Fee.recordTime, p1Principal.recordTime);

      // Tags linked to both generated records
      final tagLinks = await db.select(db.tagRecords).get();
      expect(tagLinks.map((tr) => tr.recordId).toSet(), p1Ids.toSet());

      // Period 2 has fee == 0 -> only 1 principal record
      final p2Ids = await service.postPeriod(
        commandId: 'cmd-cat-p2',
        installmentId: catInstId,
      );
      expect(p2Ids, hasLength(1));

      // 2. Uncategorized installment (catId=-1 -> RecordType.installmentPrincipal = 14)
      final uncatId = await service.createInstallment(
        commandId: 'cmd-uncat-1',
        draft: InstallmentDraft(
          name: '账单分期',
          catId: noRef,
          principal: Money.parse('6.00'),
          periods: 6,
          charge: Money.parse(
            '0.03',
          ), // AL-30: [-0.02, 0.01, 0.01, 0.01, 0.01, 0.01]
          chargeWay: InstallmentChargeWay.perPeriod,
          calWay: InstallmentCalWay.halfUp2,
          remainderIn: InstallmentRemainderIn.firstPeriod,
          startDateMs: DateTime(2026, 6, 15).millisecondsSinceEpoch,
          assetId: cashId,
          bookId: 1,
        ),
      );

      final beforeUncatAsset = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(cashId))).getSingle();

      for (var p = 1; p <= 6; p++) {
        await service.postPeriod(
          commandId: 'cmd-uncat-p$p',
          installmentId: uncatId,
        );
      }

      final uncatDetail = await queries.getInstallmentDetail(uncatId);
      expect(uncatDetail!.summary.isFinished, isTrue);
      final uncatP1Principal = uncatDetail
          .recordsForPeriod(1)
          .firstWhere((r) => r.type == RecordType.installmentPrincipal);
      expect(uncatP1Principal.type, 14);
      expect(uncatP1Principal.subType, RecordDirection.none);
      expect(uncatP1Principal.recordCatId, noRef);

      final afterUncatAsset = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(cashId))).getSingle();
      // Exact 6.00 + 0.03 = 6.03 (603 minor units) deducted across all 6 periods!
      expect(
        beforeUncatAsset.balanceMinor - afterUncatAsset.balanceMinor,
        m(603),
      );
    },
  );

  test(
    'credit-card uncredited liability conservation across create, post, metadata edit, and early settlement',
    () async {
      final nowMs = DateTime(2026, 4, 1, 10).millisecondsSinceEpoch;
      final db = AppDatabase(NativeDatabase.memory(), nowMs: () => nowMs);
      addTearDown(db.close);

      final initialCreditInfo =
          (CreditInfo()
                ..billDay = 10
                ..repaymentDay = 28)
              .encode();
      final cardId = await insertAsset(
        db,
        name: '招商信用卡',
        type: AssetType.credit,
        balanceMinor: 0,
        initMoneyMinor: 5000000,
        creditInfo: initialCreditInfo,
      );

      final service = InstallmentService(db);
      final rates = RateTable(const {'CNY': '1'});

      Future<AssetOverview> cardOverview() async {
        final card = await (db.select(
          db.assets,
        )..where((t) => t.id.equals(cardId))).getSingle();
        return computeAssetOverview([
          OverviewAccount(
            id: card.id,
            type: card.type,
            subType: card.subType,
            balanceMinor: card.balanceMinor,
            isEffectiveAsset: 1,
            status: card.status,
            currency: card.currency,
            creditInfo: card.creditInfo,
          ),
        ], rates);
      }

      // Create #1: 1200.00 principal + 60.00 fee, 3 periods, cb=true, ci=true
      final inst1 = await service.createInstallment(
        commandId: 'cc-create-1',
        draft: InstallmentDraft(
          name: '手机分期',
          catId: 2,
          principal: Money.parse('1200.00'),
          periods: 3,
          charge: Money.parse('60.00'),
          chargeWay: InstallmentChargeWay.perPeriod,
          startDateMs: DateTime(2026, 5, 1).millisecondsSinceEpoch,
          assetId: cardId,
          bookId: 1,
          principalCounted: true,
          interestCounted: true,
        ),
      );

      // Create #2 on same card: 300.00 principal + 0 fee, 3 periods
      final inst2 = await service.createInstallment(
        commandId: 'cc-create-2',
        draft: InstallmentDraft(
          name: '耳机分期',
          catId: 2,
          principal: Money.parse('300.00'),
          periods: 3,
          charge: Money.zero(),
          startDateMs: DateTime(2026, 5, 1).millisecondsSinceEpoch,
          assetId: cardId,
          bookId: 1,
        ),
      );

      // Before posting: balance == 0, uncredited == 1260 + 300 = 1560.00
      expect((await cardOverview()).totalLiabilities, m(156000));

      // Post period 1 of #1 (400.00 + 20.00 = 420.00):
      // balance becomes -420.00, uncredited becomes 840.00 + 300.00 = 1140.00
      // Total liability stays strictly 1560.00!
      await service.postPeriod(commandId: 'cc-p1', installmentId: inst1);
      final cardAfterP1 = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(cardId))).getSingle();
      expect(cardAfterP1.balanceMinor, m(-42000));
      expect(uncreditedInstallment(cardAfterP1.creditInfo), m(114000));
      expect((await cardOverview()).totalLiabilities, m(156000));
      expect(
        calculateCardDisplayBalance(
          cardAfterP1.balanceMinor,
          CreditInfo.parse(cardAfterP1.creditInfo).installments,
        ),
        m(-156000),
      );

      // Edit metadata on #1: turn off interestCounted (ci=false) -> card display balance drops by remaining 40.00 fee
      await service.updateInstallment(
        commandId: 'cc-edit-1',
        installmentId: inst1,
        name: '新款手机分期',
        catId: 2,
        bookId: 1,
        excludeBudget: false,
        excludeExIn: false,
        principalCounted: true,
        interestCounted: false,
      );
      final cardAfterEdit = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(cardId))).getSingle();
      expect(
        calculateCardDisplayBalance(
          cardAfterEdit.balanceMinor,
          CreditInfo.parse(cardAfterEdit.creditInfo).installments,
        ),
        m(-152000),
      ); // -420 - 800 - 300

      // Early full settlement of #1 with full fee waiver (settlementFee = 0.00):
      // Posts remaining 800.00 principal, 0.00 fee, closes periods 1..3, removes #1 from CreditInfo!
      final settleIds = await service.settleEarly(
        commandId: 'cc-settle-1',
        installmentId: inst1,
        settlementFee: Money.zero(),
      );
      expect(settleIds, hasLength(1)); // no fee record since fee == 0

      final cardAfterSettle = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(cardId))).getSingle();
      expect(cardAfterSettle.balanceMinor, m(-122000)); // -420 - 800
      expect(
        uncreditedInstallment(cardAfterSettle.creditInfo),
        m(30000),
      ); // #2 preserved!
      expect((await cardOverview()).totalLiabilities, m(152000));

      final row1 = await InstallmentQueries(db).getInstallment(inst1);
      expect(row1!.nextPeriod, 4);
      final extra1 = InstallmentExtra.parse(row1.exi);
      expect(extra1.settledEarly, isTrue);
      expect(extra1.settledPrincipalMinor, m(80000));
      expect(extra1.settledFeeMinor, BigInt.zero);
      expect(extra1.waivedFeeMinor, m(4000));

      // Delete #2 -> uncreditedInstallment becomes 0
      await service.deleteInstallment(
        commandId: 'cc-del-2',
        installmentId: inst2,
      );
      final cardFinal = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(cardId))).getSingle();
      expect(uncreditedInstallment(cardFinal.creditInfo), BigInt.zero);
    },
  );

  test(
    'out-of-order manual posting, duplicate guard, and safe repost after external record deletion',
    () async {
      final nowMs = DateTime(2026, 2, 1, 10).millisecondsSinceEpoch;
      final db = AppDatabase(NativeDatabase.memory(), nowMs: () => nowMs);
      addTearDown(db.close);

      final cashId = await insertAsset(db, name: '钱包', balanceMinor: 100000);
      final service = InstallmentService(db);
      final ledger = LedgerService(db);
      final queries = InstallmentQueries(db);

      final instId = await service.createInstallment(
        commandId: 'ooo-create',
        draft: InstallmentDraft(
          name: '相机分期',
          catId: 2,
          principal: Money.parse('400.00'),
          periods: 4,
          charge: Money.zero(),
          startDateMs: DateTime(2026, 3, 10).millisecondsSinceEpoch,
          assetId: cashId,
          bookId: 1,
        ),
      );

      // Post period 3 early -> nextPeriod remains 1
      await service.postPeriod(
        commandId: 'ooo-p3',
        installmentId: instId,
        period: 3,
      );
      expect((await queries.getInstallment(instId))!.nextPeriod, 1);

      // Duplicate post of period 3 while live record exists -> conflict
      await expectLater(
        service.postPeriod(
          commandId: 'ooo-p3-dup',
          installmentId: instId,
          period: 3,
        ),
        throwsA(
          isA<Failure>().having((f) => f.code, 'code', FailureCode.conflict),
        ),
      );

      // Post period 1 -> nextPeriod = 2; then post period 2 -> jumps over 3 to 4!
      final p1Records = await service.postPeriod(
        commandId: 'ooo-p1',
        installmentId: instId,
      );
      expect((await queries.getInstallment(instId))!.nextPeriod, 2);

      await service.postPeriod(commandId: 'ooo-p2', installmentId: instId);
      expect((await queries.getInstallment(instId))!.nextPeriod, 4);

      // User manually deletes period 1's generated bill via LedgerService
      await ledger.deleteRecord(
        commandId: 'ext-del-p1',
        recordId: p1Records.single,
      );
      final cashAfterExtDel = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(cashId))).getSingle();
      expect(
        cashAfterExtDel.balanceMinor,
        m(80000),
      ); // only p2 & p3 remain (-200.00)

      // Period 1 now has 0 live records -> safe repost succeeds!
      await service.postPeriod(
        commandId: 'ooo-p1-repost',
        installmentId: instId,
        period: 1,
      );
      final cashAfterRepost = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(cashId))).getSingle();
      expect(cashAfterRepost.balanceMinor, m(70000)); // p1, p2, p3 (-300.00)
    },
  );

  test(
    'runCatchUp: historical multi-period catch-up, mutex concurrency safety, inactive account & missing FX skip',
    () async {
      final now = DateTime(2026, 4, 20, 15, 0);
      final db = AppDatabase(
        NativeDatabase.memory(),
        nowMs: () => now.millisecondsSinceEpoch,
      );
      addTearDown(db.close);

      final activeId = await insertAsset(db, name: '工资卡', balanceMinor: 200000);
      final hiddenId = await insertAsset(
        db,
        name: '隐藏卡',
        status: AssetStatus.hidden,
        balanceMinor: 200000,
      );
      final usdId = await insertAsset(
        db,
        name: '美金卡',
        currency: 'USD',
        balanceMinor: 100000,
      );

      final service = InstallmentService(db);

      // Active installment started 2026-02-15 -> periods 1 (Feb 15), 2 (Mar 15), 3 (Apr 15) are due; 4 (May 15) is not
      final dueId = await service.createInstallment(
        commandId: 'cu-active',
        draft: InstallmentDraft(
          name: '房租分期',
          catId: 1,
          principal: Money.parse('400.00'),
          periods: 4,
          charge: Money.zero(),
          startDateMs: DateTime(2026, 2, 15).millisecondsSinceEpoch,
          assetId: activeId,
          bookId: 1,
        ),
      );

      // Insert an installment bound to a hidden account directly to test ASYM-INST-02 skip
      final hiddenInstId = await db
          .into(db.installments)
          .insert(
            InstallmentsCompanion.insert(
              name: '隐藏账户分期',
              principalMinor: m(20000),
              periods: 2,
              chargeMinor: BigInt.zero,
              chargeWay: InstallmentChargeWay.perPeriod,
              remainderIn: InstallmentRemainderIn.firstPeriod,
              calWay: InstallmentCalWay.halfUp2,
              startDate: DateTime(2026, 2, 15).millisecondsSinceEpoch,
              assetId: hiddenId,
              nextPeriod: 1,
              nextPeriodDate: DateTime(2026, 2, 15).millisecondsSinceEpoch,
              bookId: 1,
              createDate: now.millisecondsSinceEpoch,
            ),
          );

      // Foreign currency installment without USD rate configured yet
      final usdInstId = await service.createInstallment(
        commandId: 'cu-usd',
        draft: InstallmentDraft(
          name: '海外订阅分期',
          catId: 2,
          principal: Money.parse('200.00'),
          periods: 2,
          charge: Money.zero(),
          startDateMs: DateTime(2026, 3, 1).millisecondsSinceEpoch,
          assetId: usdId,
          bookId: 1,
        ),
      );

      // Fire 3 concurrent runCatchUp calls -> mutex guarantees zero duplicate bills!
      final results = await Future.wait([
        service.runCatchUp(now: now),
        service.runCatchUp(now: now),
        service.runCatchUp(now: now),
      ]);

      final totalPosted = results.fold<int>(
        0,
        (s, r) => s + r.postedPeriodsCount,
      );
      expect(totalPosted, 3); // periods 1, 2, 3 of dueId posted exactly once
      expect(
        results.first.skippedInstallmentIds,
        containsAll([hiddenInstId, usdInstId]),
      );

      final dueDetail = await InstallmentQueries(
        db,
      ).getInstallmentDetail(dueId);
      expect(dueDetail!.summary.progress.creditedPeriods, [1, 2, 3]);
      expect(dueDetail.summary.progress.nextPeriod, 4);
      expect(dueDetail.allRecords, hasLength(3));

      final hiddenInst = await InstallmentQueries(
        db,
      ).getInstallment(hiddenInstId);
      expect(hiddenInst!.nextPeriod, 1); // cursor NOT falsely advanced!

      // Configure USD exchange rate -> USD installment catches up cleanly with CurrencySnapshot
      await CurrencyService(db).saveCurrency(
        commandId: 'add-usd',
        code: 'USD',
        name: '美元',
        symbol: r'$',
        price: '7.20',
      );
      final usdCatchUp = await service.runCatchUp(now: now);
      expect(usdCatchUp.postedPeriodsCount, 2);
      final usdDetail = await InstallmentQueries(
        db,
      ).getInstallmentDetail(usdInstId);
      final snap = RecordExtra.parse(
        usdDetail!.allRecords.first.extraInfo,
      ).currency;
      expect(snap, isNotNull);
      expect(snap!.assetCode, 'USD');
      expect(snap.baseAmount, m(72000)); // 100.00 USD * 7.20 = 720.00 CNY
    },
  );

  test(
    'safe delete (ASYM-INST-05): avoids double-refund on externally deleted bills & avoids 1 vs 10 ID prefix collision',
    () async {
      final nowMs = DateTime(2026, 6, 1, 12).millisecondsSinceEpoch;
      final db = AppDatabase(NativeDatabase.memory(), nowMs: () => nowMs);
      addTearDown(db.close);

      final cashId = await insertAsset(db, name: '银行卡', balanceMinor: 300000);
      final service = InstallmentService(db);
      final ledger = LedgerService(db);

      // Create installments 1..10 so ID 1 and ID 10 coexist in the database!
      var inst1Id = 0;
      var inst10Id = 0;
      for (var i = 1; i <= 10; i++) {
        final id = await service.createInstallment(
          commandId: 'create-seq-$i',
          draft: InstallmentDraft(
            name: '分期-$i',
            catId: 2,
            principal: Money.parse('200.00'),
            periods: 2,
            charge: Money.zero(),
            startDateMs: DateTime(2026, 6, 1).millisecondsSinceEpoch,
            assetId: cashId,
            bookId: 1,
          ),
        );
        if (i == 1) inst1Id = id;
        if (i == 10) inst10Id = id;
      }
      expect(inst1Id, 1);
      expect(inst10Id, 10);

      // Post periods 1 and 2 of #1 (-100.00 * 2 = -200.00), and period 1 of #10 (-100.00)
      final p1Bill = (await service.postPeriod(
        commandId: 'post-1-p1',
        installmentId: inst1Id,
      )).single;
      await service.postPeriod(commandId: 'post-1-p2', installmentId: inst1Id);
      await service.postPeriod(
        commandId: 'post-10-p1',
        installmentId: inst10Id,
      );

      // Balance is now 3000.00 - 300.00 = 2700.00
      expect(
        (await (db.select(
          db.assets,
        )..where((t) => t.id.equals(cashId))).getSingle()).balanceMinor,
        m(270000),
      );

      // User manually deletes period 1 of #1 via LedgerService -> balance becomes 2800.00
      await ledger.deleteRecord(commandId: 'manual-del', recordId: p1Bill);
      expect(
        (await (db.select(
          db.assets,
        )..where((t) => t.id.equals(cashId))).getSingle()).balanceMinor,
        m(280000),
      );

      // Delete installment #1 WITH deleteGeneratedRecords: true
      // Must reverse ONLY live period 2 (+100.00 -> 2900.00), NOT period 1 again, and NOT #10's record!
      await service.deleteInstallment(
        commandId: 'safe-del-1',
        installmentId: inst1Id,
        deleteGeneratedRecords: true,
      );

      final afterDelAsset = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(cashId))).getSingle();
      expect(afterDelAsset.balanceMinor, m(290000));

      final inst10Detail = await InstallmentQueries(
        db,
      ).getInstallmentDetail(inst10Id);
      expect(inst10Detail!.allRecords, hasLength(1));

      // Delete installment #10 WITH deleteGeneratedRecords: false -> keeps bill & balance at 2900.00
      await service.deleteInstallment(
        commandId: 'keep-bills-del-10',
        installmentId: inst10Id,
        deleteGeneratedRecords: false,
      );
      expect(
        (await (db.select(
          db.assets,
        )..where((t) => t.id.equals(cashId))).getSingle()).balanceMinor,
        m(290000),
      );
      final remainingRecords = await db.select(db.records).get();
      expect(remainingRecords, hasLength(1));
      expect(remainingRecords.single.installment, '10-1');
    },
  );

  test(
    'commandId idempotency returns previous result and rejects altered payload',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      final cashId = await insertAsset(db, name: '现金', balanceMinor: 100000);
      final service = InstallmentService(db);
      final draft = InstallmentDraft(
        name: '幂等测试',
        catId: 1,
        principal: Money.parse('300.00'),
        periods: 3,
        charge: Money.zero(),
        startDateMs: DateTime(2026, 8, 1).millisecondsSinceEpoch,
        assetId: cashId,
        bookId: 1,
      );

      final firstId = await service.createInstallment(
        commandId: 'same-cmd',
        draft: draft,
      );
      final replayId = await service.createInstallment(
        commandId: 'same-cmd',
        draft: draft,
      );
      expect(replayId, firstId);
      expect(await db.select(db.installments).get(), hasLength(1));

      await expectLater(
        service.createInstallment(
          commandId: 'same-cmd',
          draft: InstallmentDraft(
            name: '篡改名称',
            catId: 1,
            principal: Money.parse('300.00'),
            periods: 3,
            charge: Money.zero(),
            startDateMs: DateTime(2026, 8, 1).millisecondsSinceEpoch,
            assetId: cashId,
            bookId: 1,
          ),
        ),
        throwsA(
          isA<Failure>().having((f) => f.code, 'code', FailureCode.conflict),
        ),
      );
    },
  );
}
