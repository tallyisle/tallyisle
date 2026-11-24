import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/budget/budget_service.dart';
import 'package:tallyisle/data/catalog/catalog_service.dart';
import 'package:tallyisle/data/catalog/currency_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/db/seed.dart';
import 'package:tallyisle/data/debt/debt_service.dart';
import 'package:tallyisle/data/installment/installment_service.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/data/periodic/periodic_service.dart';
import 'package:tallyisle/data/repo/ledger_queries.dart';
import 'package:tallyisle/data/savings/savings_service.dart';
import 'package:tallyisle/data/settings/data_health_service.dart';
import 'package:tallyisle/data/tools/template_remark_service.dart';
import 'package:tallyisle/domain/ledger/effects.dart';
import 'package:tallyisle/domain/ledger/record_extra.dart';
import 'package:tallyisle/domain/ledger/record_relations.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/asset_overview.dart';
import 'package:tallyisle/domain/rules/currency_rates.dart';
import 'package:tallyisle/domain/rules/periodic_records.dart';
import 'package:tallyisle/domain/rules/savings_plan.dart';

void main() {
  late AppDatabase db;
  late LedgerService ledger;
  late int expenseCatId;
  late int expenseCatId2;
  late int incomeCatId;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    ledger = LedgerService(db);
    final cats = await LedgerQueries(db).getCategories(defaultBookId);
    final expCats = cats.where((c) => c.type == RecordType.expense).toList();
    expenseCatId = expCats[0].id;
    expenseCatId2 = expCats[1].id;
    incomeCatId = cats.firstWhere((c) => c.type == RecordType.income).id;
    await CurrencyService(db).saveCurrency(
      commandId: 'seed-usd',
      code: 'USD',
      name: '美元',
      symbol: r'$',
      price: '7.20',
    );
  });

  tearDown(() => db.close());

  Future<Asset> assetRow(int id) =>
      (db.select(db.assets)..where((t) => t.id.equals(id))).getSingle();

  Future<LedgerRecord> recordRow(String id) =>
      (db.select(db.records)..where((t) => t.recordId.equals(id))).getSingle();

  group('Plan A: Interleaved + grouped reorderAssets slot preservation', () {
    test(
      'interleaved reorder sets cross-type order, then grouped reorder preserves credit slot',
      () async {
        final cashId = await ledger.createAsset(
          commandId: 'a-cash',
          name: '现金',
          initial: Money.parse('100.00'),
        );
        final alipayId = await ledger.createAsset(
          commandId: 'a-alipay',
          name: '支付宝',
          initial: Money.parse('200.00'),
        );
        final huabeiId = await ledger.createAsset(
          commandId: 'a-huabei',
          name: '花呗',
          type: AssetType.credit,
          initial: Money.zero(),
          limit: Money.parse('5000.00'),
        );

        // Interleave credit card between Cash and Alipay: [Cash, Huabei, Alipay]
        await ledger.reorderAssets(
          commandId: 'reorder-interleave',
          orderedAssetIds: [cashId, huabeiId, alipayId],
        );
        final afterInterleave = await LedgerQueries(db).getAssets();
        expect(afterInterleave.map((a) => a.id).toList(), [
          cashId,
          huabeiId,
          alipayId,
        ]);
        expect(afterInterleave.map((a) => a.sort).toList(), [0, 1, 2]);

        // Group-only reorder on normal accounts [Alipay, Cash] swaps ONLY slots 0 & 2!
        await ledger.reorderAssets(
          commandId: 'reorder-normal-only',
          orderedAssetIds: [alipayId, cashId],
        );
        final afterGroup = await LedgerQueries(db).getAssets();
        expect(afterGroup.map((a) => a.id).toList(), [
          alipayId,
          huabeiId,
          cashId,
        ]);
        expect(afterGroup.map((a) => a.sort).toList(), [0, 1, 2]);
      },
    );
  });

  group('L-01 & L-07: Discount + FX validation and historical bm preservation', () {
    test(
      'rejects discount > sourceGross and ignores discount on transfer',
      () async {
        final usdId = await ledger.createAsset(
          commandId: 'usd-acc',
          name: '美元卡',
          initial: Money.parse('500.00'),
          currency: 'USD',
        );
        final cnyId = await ledger.createAsset(
          commandId: 'cny-acc',
          name: '人民币卡',
          initial: Money.parse('1000.00'),
        );

        final badSnap = CurrencySnapshot(
          sourceCode: 'USD',
          sourceGross: BigInt.from(5000),
          assetCode: 'USD',
          assetNet: BigInt.from(5000),
          baseCode: 'CNY',
          baseAmount: BigInt.from(36000),
        );
        await expectLater(
          () => ledger.saveRecord(
            commandId: 'bad-disc',
            draft: RecordDraft(
              type: RecordType.expense,
              money: Money.parse('50.00'),
              bookId: defaultBookId,
              recordTime: 1700000000000,
              categoryId: expenseCatId,
              assetId: usdId,
              discount: Money.parse('60.00'),
              extra: RecordExtra()..currency = badSnap,
            ),
          ),
          throwsA(isA<Failure>()),
        );

        // Discount passed on a transfer is stripped cleanly.
        final txId = await ledger.saveRecord(
          commandId: 'tx-ignore-disc',
          draft: RecordDraft(
            type: RecordType.transfer,
            money: Money.parse('100.00'),
            bookId: defaultBookId,
            recordTime: 1700000000000,
            fromAssetId: cnyId,
            toAssetId: usdId,
            discount: Money.parse('10.00'),
          ),
        );
        expect((await recordRow(txId)).discountMinor, isNull);
      },
    );

    test(
      'L-07: editing remark/category on foreign bill after rate change preserves historical bm',
      () async {
        final usdId = await ledger.createAsset(
          commandId: 'usd-hist',
          name: '美元卡',
          initial: Money.parse('500.00'),
          currency: 'USD',
        );
        final recId = await ledger.saveRecord(
          commandId: 'usd-bill-1',
          draft: RecordDraft(
            type: RecordType.expense,
            money: Money.parse('10.00'),
            bookId: defaultBookId,
            recordTime: 1700000000000,
            categoryId: expenseCatId,
            assetId: usdId,
            remark: '旧备注',
          ),
        );
        final before = await recordRow(recId);
        final snapBefore = RecordExtra.parse(before.extraInfo).currency!;
        expect(snapBefore.baseAmount, BigInt.from(7200)); // $10 * 7.20 = ¥72.00

        // Change exchange rate to 1 USD = 8.00 CNY
        await CurrencyService(db).saveCurrency(
          commandId: 'usd-rate-8',
          code: 'USD',
          name: '美元',
          symbol: r'$',
          price: '8.00',
        );

        // Edit remark & category only (even if caller builds a snapshot with new rate)
        final newRateTable = RateTable({
          'CNY': '1',
          'USD': rateToAnchorFromPrice('8.00'),
        });
        final recalcSnap = billSnapshot(
          source: 'USD',
          sourceMinor: BigInt.from(1000),
          account: 'USD',
          assetMinor: BigInt.from(1000),
          rates: newRateTable,
        )!;
        expect(recalcSnap.baseAmount, BigInt.from(8000));

        await ledger.saveRecord(
          commandId: 'usd-bill-edit',
          recordId: recId,
          draft: RecordDraft(
            type: RecordType.expense,
            money: Money.parse('10.00'),
            bookId: defaultBookId,
            recordTime: 1700000000000,
            categoryId: expenseCatId2,
            assetId: usdId,
            remark: '新备注',
            extra: RecordExtra()..currency = recalcSnap,
          ),
        );

        final after = await recordRow(recId);
        expect(after.remark, '新备注');
        expect(after.recordCatId, expenseCatId2);
        final snapAfter = RecordExtra.parse(after.extraInfo).currency!;
        // Historical bm ¥72.00 preserved!
        expect(snapAfter.baseAmount, BigInt.from(7200));
      },
    );
  });

  group('L-03 & L-10: FX snapshots on fee, refund, reimburse, advance & effects', () {
    test(
      'foreign transfer fee, refund, reimbursement, advance settlement attach FX snapshots and pass DataHealthService',
      () async {
        final usd1 = await ledger.createAsset(
          commandId: 'usd-1',
          name: '美元卡A',
          initial: Money.parse('1000.00'),
          currency: 'USD',
        );
        final usd2 = await ledger.createAsset(
          commandId: 'usd-2',
          name: '美元卡B',
          initial: Money.parse('500.00'),
          currency: 'USD',
        );
        final cny1 = await ledger.createAsset(
          commandId: 'cny-1',
          name: '人民币卡',
          initial: Money.parse('2000.00'),
        );

        // 1. Transfer with fee on foreign account -> fee child gets USD snapshot
        final transferId = await ledger.saveRecord(
          commandId: 'fx-tx-fee',
          draft: RecordDraft(
            type: RecordType.transfer,
            money: Money.parse('100.00'),
            fee: Money.parse('2.00'),
            bookId: defaultBookId,
            recordTime: 1700000001000,
            fromAssetId: usd1,
            toAssetId: usd2,
          ),
        );
        final feeChild = (await LedgerQueries(db).feeChildOf(transferId))!;
        final feeSnap = RecordExtra.parse(feeChild.extraInfo).currency!;
        expect(feeSnap.assetCode, 'USD');
        expect(feeSnap.assetNet, BigInt.from(200));
        expect(feeSnap.baseAmount, BigInt.from(1440)); // $2 * 7.20 = ¥14.40

        // 2. Foreign reimbursable bill (`L-10` uses assetAmount) + refund + reimbursement
        final rates = RateTable({
          'CNY': '1',
          'USD': rateToAnchorFromPrice('7.20'),
        });
        final reimSnap = billSnapshot(
          source: 'CNY',
          sourceMinor: BigInt.from(72000), // ¥720 gross
          account: 'USD',
          assetMinor: BigInt.from(10000), // $100 booked on USD card
          rates: rates,
        )!;
        // Verify L-10 directly: EntryFacts with moneyMinor != assetNet uses assetNet!
        expect(
          balanceEffects(
            EntryFacts(
              type: RecordType.reimbursable,
              moneyMinor: BigInt.from(72000),
              fromAssetId: usd1,
              currency: reimSnap,
            ),
          ),
          [AssetDelta(usd1, BigInt.from(-10000))],
        );

        final reimId = await ledger.saveRecord(
          commandId: 'fx-reim',
          draft: RecordDraft(
            type: RecordType.reimbursable,
            money: Money.parse('100.00'),
            bookId: defaultBookId,
            recordTime: 1700000002000,
            categoryId: expenseCatId,
            fromAssetId: usd1,
            extra: RecordExtra()..currency = reimSnap,
          ),
        );

        // Cross-currency refund must be rejected
        await expectLater(
          () => ledger.addRefund(
            commandId: 'bad-ref-ccy',
            originId: reimId,
            amount: Money.parse('20.00'),
            assetId: cny1,
            recordTime: 1700000003000,
          ),
          throwsA(isA<Failure>()),
        );

        // Same-currency USD refund attaches negative snapshot + positive LinkedBill FX fields
        final refundId = await ledger.addRefund(
          commandId: 'ok-ref-usd',
          originId: reimId,
          amount: Money.parse('20.00'),
          assetId: usd1,
          recordTime: 1700000003000,
        );
        final refundRow = await recordRow(refundId);
        final refundSnap = RecordExtra.parse(refundRow.extraInfo).currency!;
        expect(refundSnap.assetCode, 'USD');
        expect(refundSnap.assetNet, BigInt.from(-2000));
        expect(refundSnap.baseAmount, BigInt.from(-14400));

        final reimAfterRefund = await recordRow(reimId);
        final refundLink = RecordRelations.parse(
          reimAfterRefund.relInfo,
        ).refunds!.children.single;
        expect(refundLink.assetCode, 'USD');
        expect(refundLink.assetAmount, BigInt.from(2000));
        expect(refundLink.baseCode, 'CNY');
        expect(refundLink.baseAmount, BigInt.from(14400));

        // Cross-currency reimbursement must be rejected
        await expectLater(
          () => ledger.addReimbursement(
            commandId: 'bad-reim-ccy',
            originId: reimId,
            amount: Money.parse('80.00'),
            assetId: cny1,
            recordTime: 1700000004000,
          ),
          throwsA(isA<Failure>()),
        );

        // Same-currency USD reimbursement attaches snapshot + LinkedBill FX fields
        final receiptId = await ledger.addReimbursement(
          commandId: 'ok-reim-usd',
          originId: reimId,
          amount: Money.parse('80.00'),
          assetId: usd2,
          recordTime: 1700000004000,
        );
        final receiptRow = await recordRow(receiptId);
        final receiptSnap = RecordExtra.parse(receiptRow.extraInfo).currency!;
        expect(receiptSnap.assetCode, 'USD');
        expect(receiptSnap.assetNet, BigInt.from(8000));
        expect(receiptSnap.baseAmount, BigInt.from(57600));

        // 3. Foreign advance expense + partial settle + full settle
        final advId = await ledger.saveRecord(
          commandId: 'fx-adv',
          draft: RecordDraft(
            type: RecordType.advanceExpense,
            money: Money.parse('100.00'),
            bookId: defaultBookId,
            recordTime: 1700000005000,
            categoryId: expenseCatId,
            assetId: usd1,
          ),
        );
        await expectLater(
          () => ledger.settleAdvance(
            commandId: 'bad-adv-ccy',
            originId: advId,
            amount: Money.parse('40.00'),
            assetId: cny1,
            recordTime: 1700000006000,
            finish: false,
          ),
          throwsA(isA<Failure>()),
        );
        final partialSettledId = await ledger.settleAdvance(
          commandId: 'partial-adv-usd',
          originId: advId,
          amount: Money.parse('40.00'),
          assetId: usd1,
          recordTime: 1700000006000,
          finish: false,
        );
        final partialRow = await recordRow(partialSettledId);
        final partialSnap = RecordExtra.parse(partialRow.extraInfo).currency!;
        expect(partialSnap.assetCode, 'USD');
        expect(partialSnap.assetNet, BigInt.from(4000));
        expect(partialSnap.baseAmount, BigInt.from(28800));

        final advAfterPartial = await recordRow(advId);
        expect(advAfterPartial.moneyMinor, BigInt.from(6000));
        final advSnapAfterPartial = RecordExtra.parse(
          advAfterPartial.extraInfo,
        ).currency!;
        expect(advSnapAfterPartial.assetNet, BigInt.from(6000));
        expect(advSnapAfterPartial.sourceGross, BigInt.from(6000));
        expect(advSnapAfterPartial.baseAmount, BigInt.from(43200));

        // Health check must report zero anomalies!
        final health = await DataHealthService(db).checkHealth();
        expect(health.issues, isEmpty);
      },
    );
  });

  group('L-05: Debt account isolation & full category deletion migration', () {
    test(
      'Savings, Periodic, Installment and adjustBalance reject debt accounts',
      () async {
        final normalId = await ledger.createAsset(
          commandId: 'norm-1',
          name: '工资卡',
          initial: Money.parse('1000.00'),
        );
        final debtId = await DebtService(db).createDebt(
          commandId: 'debt-1',
          name: '借给小明',
          subType: AssetType.debtLend,
          principal: Money.parse('500.00'),
          fundingAssetId: normalId,
          bookId: defaultBookId,
          startDate: 1700000000000,
        );

        // adjustBalance rejects debt
        await expectLater(
          () => ledger.adjustBalance(
            commandId: 'adj-debt',
            assetId: debtId,
            target: Money.parse('200.00'),
            bookId: defaultBookId,
          ),
          throwsA(isA<Failure>()),
        );

        // SavingsService rejects debt
        await expectLater(
          () => SavingsService(db).savePlan(
            commandId: 'save-debt',
            draft: SavingsPlanDraft(
              name: '存钱测试',
              planType: SavingsPlanType.free,
              startDateMs: 1700000000000,
              customPlanMoneyMinor: BigInt.from(10000),
              fromAssetId: debtId,
              toAssetId: normalId,
            ),
          ),
          throwsA(isA<Failure>()),
        );

        // PeriodicService rejects debt
        await expectLater(
          () => PeriodicService(db).savePeriod(
            commandId: 'per-debt',
            draft: PeriodicDraft(
              recordType: RecordType.expense,
              money: Money.parse('50.00'),
              bookId: defaultBookId,
              categoryId: expenseCatId,
              assetId: debtId,
              periodType: PeriodType.monthly,
              periodTypeDates: const ['1'],
              periodStartDate: 1700000000000,
            ),
          ),
          throwsA(isA<Failure>()),
        );

        // InstallmentService rejects debt
        await expectLater(
          () => InstallmentService(db).createInstallment(
            commandId: 'inst-debt',
            draft: InstallmentDraft(
              name: '分期测试',
              catId: expenseCatId,
              principal: Money.parse('600.00'),
              periods: 6,
              charge: Money.zero(),
              startDateMs: 1700000000000,
              assetId: debtId,
              bookId: defaultBookId,
            ),
          ),
          throwsA(isA<Failure>()),
        );
      },
    );

    test(
      'CatalogService.deleteCategory checks & migrates records, installments, periods, templates & merges budgets',
      () async {
        final catalog = CatalogService(db);
        final cardId = await ledger.createAsset(
          commandId: 'card-cat',
          name: '信用卡',
          type: AssetType.credit,
          initial: Money.zero(),
          limit: Money.parse('10000.00'),
        );
        final srcCat = await catalog.createCategory(
          commandId: 'cat-src',
          accountBookId: defaultBookId,
          name: '待删分类',
          type: RecordType.expense,
        );
        final dstCat = await catalog.createCategory(
          commandId: 'cat-dst',
          accountBookId: defaultBookId,
          name: '目标分类',
          type: RecordType.expense,
        );

        // Attach 1 installment, 1 periodic rule, 1 template, and overlapping budgets on BOTH srcCat & dstCat
        final instId = await InstallmentService(db).createInstallment(
          commandId: 'inst-cat',
          draft: InstallmentDraft(
            name: '手机分期',
            catId: srcCat,
            principal: Money.parse('1200.00'),
            periods: 12,
            charge: Money.zero(),
            startDateMs: 1700000000000,
            assetId: cardId,
            bookId: defaultBookId,
          ),
        );
        final periodId = await PeriodicService(db).savePeriod(
          commandId: 'per-cat',
          draft: PeriodicDraft(
            recordType: RecordType.expense,
            money: Money.parse('30.00'),
            bookId: defaultBookId,
            categoryId: srcCat,
            assetId: cardId,
            periodType: PeriodType.monthly,
            periodTypeDates: const ['1'],
            periodStartDate: 1700000000000,
          ),
        );
        final tplId = await TemplateRemarkService(db).saveTemplate(
          commandId: 'tpl-cat',
          draft: TemplateDraft(
            type: RecordType.expense,
            money: Money.parse('15.00'),
            bookId: defaultBookId,
            categoryId: srcCat,
            assetId: cardId,
            remark: '模板',
          ),
        );
        final budgetSvc = BudgetService(db);
        await budgetSvc.upsertCategoryBudget(
          commandId: 'b-src',
          bookId: defaultBookId,
          section: '2026-11',
          budgetType: 1,
          categoryId: srcCat,
          amountMinor: BigInt.from(30000),
          autoCopy: true,
        );
        await budgetSvc.upsertCategoryBudget(
          commandId: 'b-dst',
          bookId: defaultBookId,
          section: '2026-11',
          budgetType: 1,
          categoryId: dstCat,
          amountMinor: BigInt.from(50000),
        );

        // Deleting without targetCategoryId must fail even with 0 records!
        await expectLater(
          () => catalog.deleteCategory(
            commandId: 'del-no-target',
            categoryId: srcCat,
          ),
          throwsA(isA<Failure>()),
        );

        // Deleting WITH targetCategoryId migrates everything atomically & merges budget!
        await catalog.deleteCategory(
          commandId: 'del-with-target',
          categoryId: srcCat,
          targetCategoryId: dstCat,
        );

        final instAfter = await (db.select(
          db.installments,
        )..where((t) => t.id.equals(instId))).getSingle();
        expect(instAfter.catId, dstCat);

        final periodAfter = await (db.select(
          db.recordPeriods,
        )..where((t) => t.id.equals(periodId))).getSingle();
        expect(periodAfter.catId, dstCat);

        final tplAfter = await (db.select(
          db.recordTemplates,
        )..where((t) => t.id.equals(tplId))).getSingle();
        expect(tplAfter.recordCatId, dstCat);

        final budgetsAfter = await (db.select(
          db.budgets,
        )..where((t) => t.recordCatId.equals(dstCat))).get();
        expect(budgetsAfter, hasLength(1));
        expect(budgetsAfter.single.amountMinor, BigInt.from(80000));
      },
    );
  });

  group('L-06 & L-08: Repeated adjustBalance & linked record consistency', () {
    test(
      'L-06: adjustBalance accepts explicit recordTime for repeated adjustments',
      () async {
        final cashId = await ledger.createAsset(
          commandId: 'cash-adj',
          name: '现金',
          initial: Money.parse('100.00'),
        );
        final id1 = await ledger.adjustBalance(
          commandId: 'adj-1',
          assetId: cashId,
          target: Money.parse('150.00'),
          bookId: defaultBookId,
          recordTime: 1700000001000,
        );
        expect(id1, isNotNull);
        expect((await recordRow(id1!)).recordTime, 1700000001000);
        expect((await assetRow(cashId)).balanceMinor, BigInt.from(15000));

        // Spend 50, then adjust back to 150.00 again at a new timestamp!
        await ledger.saveRecord(
          commandId: 'spend-50',
          draft: RecordDraft(
            type: RecordType.expense,
            money: Money.parse('50.00'),
            bookId: defaultBookId,
            recordTime: 1700000002000,
            categoryId: expenseCatId,
            assetId: cashId,
          ),
        );
        final id2 = await ledger.adjustBalance(
          commandId: 'adj-2',
          assetId: cashId,
          target: Money.parse('150.00'),
          bookId: defaultBookId,
          recordTime: 1700000003000,
        );
        expect(id2, isNotNull);
        expect((await assetRow(cashId)).balanceMinor, BigInt.from(15000));
      },
    );

    test(
      'L-08: deleting fee child clears parent transferFee; deleting settled advance reopens origin; editing parent cascades flags & guards refunds',
      () async {
        final a1 = await ledger.createAsset(
          commandId: 'l8-a1',
          name: '账户A',
          initial: Money.parse('1000.00'),
        );
        final a2 = await ledger.createAsset(
          commandId: 'l8-a2',
          name: '账户B',
          initial: Money.parse('500.00'),
        );
        final usd = await ledger.createAsset(
          commandId: 'l8-usd',
          name: '美元户',
          initial: Money.parse('500.00'),
          currency: 'USD',
        );

        // 1. Delete fee child -> parent transferFee cleared
        final txId = await ledger.saveRecord(
          commandId: 'l8-tx',
          draft: RecordDraft(
            type: RecordType.transfer,
            money: Money.parse('100.00'),
            fee: Money.parse('5.00'),
            bookId: defaultBookId,
            recordTime: 1700000010000,
            fromAssetId: a1,
            toAssetId: a2,
          ),
        );
        final fee = (await LedgerQueries(db).feeChildOf(txId))!;
        await ledger.deleteRecord(
          commandId: 'l8-del-fee',
          recordId: fee.recordId,
        );
        final parentTx = await recordRow(txId);
        expect(RecordRelations.parse(parentTx.relInfo).transferFee, isNull);

        // 2. Delete final settled advance bill -> reopens origin advance
        final advId = await ledger.saveRecord(
          commandId: 'l8-adv',
          draft: RecordDraft(
            type: RecordType.advanceExpense,
            money: Money.parse('80.00'),
            bookId: defaultBookId,
            recordTime: 1700000020000,
            categoryId: expenseCatId,
            assetId: a1,
          ),
        );
        final settledId = await ledger.settleAdvance(
          commandId: 'l8-settle',
          originId: advId,
          amount: Money.parse('80.00'),
          assetId: a1,
          recordTime: 1700000021000,
          finish: true,
        );
        expect(
          RecordExtra.parse((await recordRow(advId)).extraInfo).advance,
          isNotNull,
        );
        await ledger.deleteRecord(
          commandId: 'l8-del-settled',
          recordId: settledId,
        );
        expect(
          RecordExtra.parse((await recordRow(advId)).extraInfo).advance,
          isNull,
        );

        // 3. Parent with refund guards + metadata cascade
        final expId = await ledger.saveRecord(
          commandId: 'l8-exp',
          draft: RecordDraft(
            type: RecordType.expense,
            money: Money.parse('100.00'),
            bookId: defaultBookId,
            recordTime: 1700000030000,
            categoryId: expenseCatId,
            assetId: a1,
          ),
        );
        final refId = await ledger.addRefund(
          commandId: 'l8-ref',
          originId: expId,
          amount: Money.parse('40.00'),
          assetId: a1,
          recordTime: 1700000031000,
        );

        // Reject net < refunded
        await expectLater(
          () => ledger.saveRecord(
            commandId: 'l8-shrink-fail',
            recordId: expId,
            draft: RecordDraft(
              type: RecordType.expense,
              money: Money.parse('30.00'),
              bookId: defaultBookId,
              recordTime: 1700000030000,
              categoryId: expenseCatId,
              assetId: a1,
            ),
          ),
          throwsA(isA<Failure>()),
        );

        // Reject currency change
        await expectLater(
          () => ledger.saveRecord(
            commandId: 'l8-ccy-fail',
            recordId: expId,
            draft: RecordDraft(
              type: RecordType.expense,
              money: Money.parse('100.00'),
              bookId: defaultBookId,
              recordTime: 1700000030000,
              categoryId: expenseCatId,
              assetId: usd,
            ),
          ),
          throwsA(isA<Failure>()),
        );

        // Reject type change
        await expectLater(
          () => ledger.saveRecord(
            commandId: 'l8-type-fail',
            recordId: expId,
            draft: RecordDraft(
              type: RecordType.income,
              money: Money.parse('100.00'),
              bookId: defaultBookId,
              recordTime: 1700000030000,
              categoryId: incomeCatId,
              assetId: a1,
            ),
          ),
          throwsA(isA<Failure>()),
        );

        // Valid edit cascades category, excludeBudget, excludeExIn to refund child
        await ledger.saveRecord(
          commandId: 'l8-cascade',
          recordId: expId,
          draft: RecordDraft(
            type: RecordType.expense,
            money: Money.parse('100.00'),
            bookId: defaultBookId,
            recordTime: 1700000030000,
            categoryId: expenseCatId2,
            assetId: a1,
            excludeBudget: true,
            excludeExIn: true,
          ),
        );
        final refAfter = await recordRow(refId);
        expect(refAfter.recordCatId, expenseCatId2);
        expect(refAfter.excludeBudget, isTrue);
        expect(refAfter.excludeExIn, isTrue);

        // DataHealthService check passes with 0 anomalies
        final health = await DataHealthService(db).checkHealth();
        expect(health.issues, isEmpty);
      },
    );
  });
}
