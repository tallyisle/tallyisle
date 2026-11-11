import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/catalog/catalog_service.dart';
import 'package:tallyisle/data/catalog/currency_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/debt/debt_service.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/data/repo/debt_queries.dart';
import 'package:tallyisle/data/repo/ledger_queries.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/asset_overview.dart';
import 'package:tallyisle/domain/rules/debt_rules.dart';
import 'package:tallyisle/domain/rules/income_expense.dart';

Money m(String text, [String currency = 'CNY']) =>
    Money.parse(text, currency: currency);

void main() {
  late AppDatabase db;
  late LedgerService ledger;
  late DebtService debtService;
  late DebtQueries debtQueries;
  late CatalogService catalog;
  late CurrencyService currencyService;
  var seq = 0;
  String cmd() => 'debt-cmd-${seq++}';

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    ledger = LedgerService(db);
    debtService = DebtService(db);
    debtQueries = DebtQueries(db);
    catalog = CatalogService(db);
    currencyService = CurrencyService(db);
  });

  tearDown(() => db.close());

  Future<Asset> assetRow(int id) =>
      (db.select(db.assets)..where((t) => t.id.equals(id))).getSingle();

  Future<int> createCash(String name, String initial, {String? currency}) =>
      ledger.createAsset(
        commandId: cmd(),
        name: name,
        initial: m(initial, currency ?? 'CNY'),
        currency: currency,
      );

  test(
    'CE-DM-01: countedInNetWorth stores inverted is_effective_asset and integrates with AssetOverview',
    () async {
      final lendCountedId = await debtService.createDebt(
        commandId: cmd(),
        subType: AssetType.debtLend,
        name: '张三应收',
        principal: m('400.00'),
        bookId: 1,
        startDate: 1700000000000,
        countedInNetWorth: true,
      );
      final borrowCountedId = await debtService.createDebt(
        commandId: cmd(),
        subType: AssetType.debtBorrow,
        name: '李四应付',
        principal: m('150.00'),
        bookId: 1,
        startDate: 1700000000000,
        countedInNetWorth: true,
      );
      final borrowExcludedId = await debtService.createDebt(
        commandId: cmd(),
        subType: AssetType.debtBorrow,
        name: '不计入借款',
        principal: m('999.00'),
        bookId: 1,
        startDate: 1700000000000,
        countedInNetWorth: false,
      );

      expect((await assetRow(lendCountedId)).isEffectiveAsset, 0);
      expect((await assetRow(borrowCountedId)).isEffectiveAsset, 0);
      expect((await assetRow(borrowExcludedId)).isEffectiveAsset, 1);

      final allAssets = await db.select(db.assets).get();
      final overview = computeAssetOverview([
        for (final a in allAssets)
          OverviewAccount(
            id: a.id,
            type: a.type,
            subType: a.subType,
            balanceMinor: a.balanceMinor,
            isEffectiveAsset: a.isEffectiveAsset,
            status: a.status,
            currency: a.currency,
          ),
      ], RateTable({'CNY': '1'}));

      expect(overview.totalAsset, BigInt.from(40000));
      expect(overview.totalLiabilities, BigInt.from(15000));
      expect(overview.netAsset, BigInt.from(25000));
    },
  );

  test(
    'CE-DM-06: asset_book binding isolates single-book queries while legacy unbound debts show only in book 1 / all-books',
    () async {
      final book2 = await catalog.createBook(commandId: cmd(), name: '生意账本');

      final debtBook1 = await debtService.createDebt(
        commandId: cmd(),
        subType: AssetType.debtLend,
        name: '日常借出',
        principal: m('200.00'),
        bookId: 1,
        startDate: 1700000000000,
      );
      final debtBook2 = await debtService.createDebt(
        commandId: cmd(),
        subType: AssetType.debtBorrow,
        name: '生意借入',
        principal: m('500.00'),
        bookId: book2,
        startDate: 1700000000000,
      );

      // Insert a legacy unbound debt (no asset_book row).
      final legacyUnbound = await db
          .into(db.assets)
          .insert(
            AssetsCompanion.insert(
              name: '历史未绑借出',
              balanceMinor: BigInt.from(30000),
              initMoneyMinor: BigInt.from(30000),
              type: AssetType.debt,
              subType: const Value(AssetType.debtLend),
              createDate: 1700000000000,
              isEffectiveAsset: const Value(0),
            ),
          );

      final inBook1 = await debtQueries.watchDebts(bookId: 1).first;
      final inBook2 = await debtQueries.watchDebts(bookId: book2).first;
      final inAll = await debtQueries.watchDebts().first;

      expect(inBook1.map((d) => d.id).toSet(), {debtBook1, legacyUnbound});
      expect(inBook2.map((d) => d.id).toSet(), {debtBook2});
      expect(inAll.map((d) => d.id).toSet(), {
        debtBook1,
        debtBook2,
        legacyUnbound,
      });
    },
  );

  test(
    'DM-L01 & DM-L12: borrowing lifecycle, +1ms/+2ms ordering, funding balance, and income/expense/budget stats',
    () async {
      final bank = await createCash('招行储蓄', '5000.00');
      const day1 = 1700000000000;
      const day2 = 1700086400000;

      final debtId = await debtService.createDebt(
        commandId: cmd(),
        subType: AssetType.debtBorrow,
        name: '房东押金周转',
        principal: m('1000.00'),
        bookId: 1,
        startDate: day1,
        fundingAssetId: bank,
      );

      expect((await assetRow(bank)).balanceMinor, BigInt.from(600000));
      expect((await assetRow(debtId)).balanceMinor, BigInt.from(100000));

      // Repay 400 principal + 25 interest (counted in budget)
      await debtService.recordRepayment(
        commandId: cmd(),
        debtId: debtId,
        principal: m('400.00'),
        interest: m('25.00'),
        operateDate: day2,
        bookId: 1,
        fundingAssetId: bank,
        interestExcludeBudget: false,
      );

      // Bank: 6000 - 400 - 25 = 5575.00; Debt remaining: 600.00
      expect((await assetRow(bank)).balanceMinor, BigInt.from(557500));
      expect((await assetRow(debtId)).balanceMinor, BigInt.from(60000));

      // Pure interest 15.00 excluded from budget (R2 / DM-L03)
      const day3 = day2 + 86400000;
      await debtService.recordRepayment(
        commandId: cmd(),
        debtId: debtId,
        principal: m('0.00'),
        interest: m('15.00'),
        operateDate: day3,
        bookId: 1,
        fundingAssetId: bank,
        interestExcludeBudget: true,
      );

      // Pure interest deducts bank to 5560.00 WITHOUT altering debt principal 600.00!
      expect((await assetRow(bank)).balanceMinor, BigInt.from(556000));
      expect((await assetRow(debtId)).balanceMinor, BigInt.from(60000));

      // Verify +2ms interest strictly precedes +1ms repayment of day2 in DESC order
      final recs = await debtQueries.watchDebtRecords(debtId).first;
      expect(recs, hasLength(4));
      expect(recs[0].type, RecordType.debtInterest); // day3 + 2ms
      expect(recs[0].recordTime, day3 + 2);
      expect(recs[1].type, RecordType.debtInterest); // day2 + 2ms
      expect(recs[1].recordTime, day2 + 2);
      expect(recs[2].type, RecordType.repay); // day2 + 1ms
      expect(recs[2].recordTime, day2 + 1);
      expect(recs[3].type, RecordType.borrowIn); // day1 + 1ms
      expect(recs[3].recordTime, day1 + 1);

      // Verify home stats (25 + 15 = 40 expense) vs budget stats (only 25)
      final homeStats = aggregateIncomeExpense(
        recs.map(statEntryOf),
        scope: StatScope.home,
      );
      final budgetStats = aggregateIncomeExpense(
        recs.map(statEntryOf),
        scope: StatScope.budget,
      );
      expect(homeStats.expense, BigInt.from(4000));
      expect(homeStats.income, BigInt.zero);
      expect(budgetStats.expense, BigInt.from(2500));
    },
  );

  test(
    'ASYM-DM-01: manual settlement locks status=2 across recalibration and record edits until explicit reopen',
    () async {
      final cash = await createCash('现金', '2000.00');
      final debtId = await debtService.createDebt(
        commandId: cmd(),
        subType: AssetType.debtLend,
        name: '王五借款',
        principal: m('1000.00'),
        bookId: 1,
        startDate: 1700000000000,
        fundingAssetId: cash,
      );

      final collectId = await debtService.recordRepayment(
        commandId: cmd(),
        debtId: debtId,
        principal: m('300.00'),
        operateDate: 1700086400000,
        bookId: 1,
        fundingAssetId: cash,
      );
      expect((await assetRow(debtId)).balanceMinor, BigInt.from(70000));

      // Manually settle while 700.00 remains unpaid
      await debtService.settleDebt(commandId: cmd(), debtId: debtId);
      final settledRow = await assetRow(debtId);
      expect(settledRow.status, AssetStatus.settled);
      expect(settledRow.balanceMinor, BigInt.zero);
      expect(LoanInfo.parse(settledRow.loanInfo).manualSettled, isTrue);
      expect(
        LoanInfo.parse(settledRow.loanInfo).settledSnapshotMinor,
        BigInt.from(70000),
      );

      // Recalibrating MUST NOT reopen to status=0
      await debtService.recalibrateDebt(commandId: cmd(), debtId: debtId);
      expect((await assetRow(debtId)).status, AssetStatus.settled);
      expect((await assetRow(debtId)).balanceMinor, BigInt.zero);

      // Editing a historical record MUST NOT reopen to status=0
      await debtService.updateDebtRecord(
        commandId: cmd(),
        recordId: collectId,
        amount: m('400.00'),
      );
      expect((await assetRow(debtId)).status, AssetStatus.settled);
      expect((await assetRow(debtId)).balanceMinor, BigInt.zero);
      expect((await assetRow(cash)).balanceMinor, BigInt.from(140000));

      // Explicit reopen restores status=0 with updated remaining 600.00
      await debtService.reopenDebt(commandId: cmd(), debtId: debtId);
      final reopened = await assetRow(debtId);
      expect(reopened.status, AssetStatus.active);
      expect(reopened.balanceMinor, BigInt.from(60000));
      expect(LoanInfo.parse(reopened.loanInfo).manualSettled, isFalse);
    },
  );

  test(
    'R5 / ASYM-DM-02 & ASYM-DM-03: single-record delete, whole-debt delete, cross-currency rollback, and funding deletion guard',
    () async {
      await currencyService.saveCurrency(
        commandId: cmd(),
        code: 'USD',
        name: '美元',
        symbol: r'$',
        price: '8', // 1 USD = 8 CNY -> rateToAnchor = 0.125
      );

      final cnyBank = await createCash('人民币卡', '5000.00');
      final usdWallet = await createCash('美元钱包', '200.00', currency: 'USD');

      final debtId = await debtService.createDebt(
        commandId: cmd(),
        subType: AssetType.debtBorrow,
        name: '跨币种测试借入',
        principal: m('1000.00'),
        bookId: 1,
        startDate: 1700000000000,
        fundingAssetId: cnyBank,
      );
      expect((await assetRow(cnyBank)).balanceMinor, BigInt.from(600000));

      // Repay 400 CNY from USD wallet (auto converts to 50.00 USD)
      final repayId = await debtService.recordRepayment(
        commandId: cmd(),
        debtId: debtId,
        principal: m('400.00'),
        operateDate: 1700086400000,
        bookId: 1,
        fundingAssetId: usdWallet,
      );
      expect((await assetRow(usdWallet)).balanceMinor, BigInt.from(15000));
      expect((await assetRow(debtId)).balanceMinor, BigInt.from(60000));

      // ASYM-DM-03: deleting funding account referenced by debt records is blocked
      await expectLater(
        ledger.deleteAsset(commandId: cmd(), assetId: usdWallet),
        throwsA(
          isA<Failure>().having((f) => f.code, 'code', FailureCode.validation),
        ),
      );

      // Single-record delete reverses 50.00 USD back to 200.00 USD and restores debt to 1000.00 CNY
      await debtService.deleteDebtRecord(commandId: cmd(), recordId: repayId);
      expect((await assetRow(usdWallet)).balanceMinor, BigInt.from(20000));
      expect((await assetRow(debtId)).balanceMinor, BigInt.from(100000));

      // Re-record 400 CNY from USD wallet + 16 CNY interest (2.00 USD) -> 52.00 USD deducted
      await debtService.recordRepayment(
        commandId: cmd(),
        debtId: debtId,
        principal: m('400.00'),
        interest: m('16.00'),
        operateDate: 1700086400000,
        bookId: 1,
        fundingAssetId: usdWallet,
      );
      expect((await assetRow(usdWallet)).balanceMinor, BigInt.from(14800));

      // Whole-debt delete reverses BOTH cnyBank (-1000 CNY -> 5000 CNY) and usdWallet (+52 USD -> 200 USD)
      await debtService.deleteDebt(commandId: cmd(), debtId: debtId);
      expect((await assetRow(cnyBank)).balanceMinor, BigInt.from(500000));
      expect((await assetRow(usdWallet)).balanceMinor, BigInt.from(20000));
      expect(await debtQueries.watchDebt(debtId).first, isNull);
      expect(await debtQueries.watchDebtRecords(debtId).first, isEmpty);
    },
  );

  test('idempotency and validation errors', () async {
    final id1 = await debtService.createDebt(
      commandId: 'idem-create-1',
      subType: AssetType.debtLend,
      name: '幂等借出',
      principal: m('300.00'),
      bookId: 1,
      startDate: 1700000000000,
    );
    final id2 = await debtService.createDebt(
      commandId: 'idem-create-1',
      subType: AssetType.debtLend,
      name: '幂等借出',
      principal: m('300.00'),
      bookId: 1,
      startDate: 1700000000000,
    );
    expect(id1, id2);

    await expectLater(
      debtService.createDebt(
        commandId: 'idem-create-1',
        subType: AssetType.debtLend,
        name: '篡改名称',
        principal: m('300.00'),
        bookId: 1,
        startDate: 1700000000000,
      ),
      throwsA(
        isA<Failure>().having((f) => f.code, 'code', FailureCode.conflict),
      ),
    );

    // End date before start date rejected
    await expectLater(
      debtService.createDebt(
        commandId: cmd(),
        subType: AssetType.debtLend,
        name: '非法到期日',
        principal: m('100.00'),
        bookId: 1,
        startDate: 2000,
        endDate: 1000,
      ),
      throwsA(
        isA<Failure>().having((f) => f.code, 'code', FailureCode.validation),
      ),
    );
  });
}
