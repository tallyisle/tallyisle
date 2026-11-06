import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/data/repo/search_queries.dart';
import 'package:tallyisle/domain/model/codes.dart';

Money m(String s) => Money.parse(s);

void main() {
  late AppDatabase db;
  late LedgerService ledger;
  late SearchQueries searchQueries;
  var cmdCounter = 0;
  String cmd() => 'cmd-search-${cmdCounter++}';

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    ledger = LedgerService(db);
    searchQueries = SearchQueries(db);
  });

  tearDown(() => db.close());

  Future<int> createAccount(String name, String balance) =>
      ledger.createAsset(commandId: cmd(), name: name, initial: m(balance));

  Future<int> getCategoryId(String name) async => (await (db.select(
    db.recordCategories,
  )..where((t) => t.name.equals(name))).getSingle()).id;

  test('Search filter: book isolation', () async {
    final cash = await createAccount('现金', '1000.00');
    final food = await getCategoryId('餐饮');

    await ledger.saveRecord(
      commandId: cmd(),
      draft: RecordDraft(
        type: RecordType.expense,
        money: m('20.00'),
        bookId: 1,
        recordTime: 1000,
        categoryId: food,
        assetId: cash,
      ),
    );
    await ledger.saveRecord(
      commandId: cmd(),
      draft: RecordDraft(
        type: RecordType.expense,
        money: m('30.00'),
        bookId: 2,
        recordTime: 1000,
        categoryId: food,
        assetId: cash,
      ),
    );

    final resBook1 = await searchQueries.getRecords(
      const SearchFilter(bookId: 1),
    );
    expect(resBook1, hasLength(1));
    expect(resBook1.first.moneyMinor, BigInt.from(2000));

    final resBook2 = await searchQueries.getRecords(
      const SearchFilter(bookId: 2),
    );
    expect(resBook2, hasLength(1));
    expect(resBook2.first.moneyMinor, BigInt.from(3000));
  });

  test('Search filter: time range [startMs, endMs]', () async {
    final cash = await createAccount('现金', '1000.00');
    final food = await getCategoryId('餐饮');

    for (final time in [1000, 2000, 3000, 4000]) {
      await ledger.saveRecord(
        commandId: cmd(),
        draft: RecordDraft(
          type: RecordType.expense,
          money: m('10.00'),
          bookId: 1,
          recordTime: time,
          categoryId: food,
          assetId: cash,
        ),
      );
    }

    final res = await searchQueries.getRecords(
      const SearchFilter(bookId: 1, startMs: 2000, endMs: 3000),
    );
    expect(res, hasLength(2));
    expect(res.map((r) => r.recordTime), containsAllInOrder([3000, 2000]));
  });

  test('Search filter: type (Expense / Income / Transfer)', () async {
    final cash = await createAccount('现金', '1000.00');
    final card = await createAccount('银行卡', '1000.00');
    final food = await getCategoryId('餐饮');
    final salary = await getCategoryId('工资');

    await ledger.saveRecord(
      commandId: cmd(),
      draft: RecordDraft(
        type: RecordType.expense,
        money: m('15.00'),
        bookId: 1,
        recordTime: 1000,
        categoryId: food,
        assetId: cash,
      ),
    );
    await ledger.saveRecord(
      commandId: cmd(),
      draft: RecordDraft(
        type: RecordType.income,
        money: m('200.00'),
        bookId: 1,
        recordTime: 2000,
        categoryId: salary,
        assetId: card,
      ),
    );
    await ledger.saveRecord(
      commandId: cmd(),
      draft: RecordDraft(
        type: RecordType.transfer,
        money: m('50.00'),
        bookId: 1,
        recordTime: 3000,
        fromAssetId: cash,
        toAssetId: card,
      ),
    );

    final expenseOnly = await searchQueries.getRecords(
      const SearchFilter(bookId: 1, type: RecordType.expense),
    );
    expect(expenseOnly, hasLength(1));
    expect(expenseOnly.first.type, RecordType.expense);

    final incomeOnly = await searchQueries.getRecords(
      const SearchFilter(bookId: 1, type: RecordType.income),
    );
    expect(incomeOnly, hasLength(1));
    expect(incomeOnly.first.type, RecordType.income);

    final transferOnly = await searchQueries.getRecords(
      const SearchFilter(bookId: 1, type: RecordType.transfer),
    );
    expect(transferOnly, hasLength(1));
    expect(transferOnly.first.type, RecordType.transfer);

    final allTypes = await searchQueries.getRecords(
      const SearchFilter(bookId: 1),
    );
    expect(allTypes, hasLength(3));
  });

  test('Search filter: categoryIds', () async {
    final cash = await createAccount('现金', '1000.00');
    final food = await getCategoryId('餐饮');
    final traffic = await getCategoryId('交通');
    final salary = await getCategoryId('工资');

    await ledger.saveRecord(
      commandId: cmd(),
      draft: RecordDraft(
        type: RecordType.expense,
        money: m('10.00'),
        bookId: 1,
        recordTime: 1000,
        categoryId: food,
        assetId: cash,
      ),
    );
    await ledger.saveRecord(
      commandId: cmd(),
      draft: RecordDraft(
        type: RecordType.expense,
        money: m('20.00'),
        bookId: 1,
        recordTime: 2000,
        categoryId: traffic,
        assetId: cash,
      ),
    );
    await ledger.saveRecord(
      commandId: cmd(),
      draft: RecordDraft(
        type: RecordType.income,
        money: m('100.00'),
        bookId: 1,
        recordTime: 3000,
        categoryId: salary,
        assetId: cash,
      ),
    );

    final res = await searchQueries.getRecords(
      SearchFilter(bookId: 1, categoryIds: {food, traffic}),
    );
    expect(res, hasLength(2));
    expect(res.map((r) => r.recordCatId), containsAll([food, traffic]));
  });

  test('Search filter: assetId (asset_id, from_asset_id, to_asset_id)', () async {
    final a1 = await createAccount('账户1', '1000.00');
    final a2 = await createAccount('账户2', '1000.00');
    final a3 = await createAccount('账户3', '1000.00');
    final food = await getCategoryId('餐饮');

    // Expense from a1
    await ledger.saveRecord(
      commandId: cmd(),
      draft: RecordDraft(
        type: RecordType.expense,
        money: m('10.00'),
        bookId: 1,
        recordTime: 1000,
        categoryId: food,
        assetId: a1,
      ),
    );
    // Transfer from a1 to a2
    await ledger.saveRecord(
      commandId: cmd(),
      draft: RecordDraft(
        type: RecordType.transfer,
        money: m('20.00'),
        bookId: 1,
        recordTime: 2000,
        fromAssetId: a1,
        toAssetId: a2,
      ),
    );
    // Transfer from a2 to a3
    await ledger.saveRecord(
      commandId: cmd(),
      draft: RecordDraft(
        type: RecordType.transfer,
        money: m('30.00'),
        bookId: 1,
        recordTime: 3000,
        fromAssetId: a2,
        toAssetId: a3,
      ),
    );

    // Filter by a1: matches expense (assetId=a1) and transfer a1->a2 (fromAssetId=a1)
    final resA1 = await searchQueries.getRecords(
      SearchFilter(bookId: 1, assetId: a1),
    );
    expect(resA1, hasLength(2));

    // Filter by a2: matches transfer a1->a2 (toAssetId=a2) and transfer a2->a3 (fromAssetId=a2)
    final resA2 = await searchQueries.getRecords(
      SearchFilter(bookId: 1, assetId: a2),
    );
    expect(resA2, hasLength(2));

    // Filter by a3: matches transfer a2->a3 (toAssetId=a3)
    final resA3 = await searchQueries.getRecords(
      SearchFilter(bookId: 1, assetId: a3),
    );
    expect(resA3, hasLength(1));
  });

  test('Search filter: keyword with LIKE escaping (%, _, \\)', () async {
    final cash = await createAccount('现金', '1000.00');
    final food = await getCategoryId('餐饮');

    // 1. Literal % test: "50% off" vs "500 off"
    await ledger.saveRecord(
      commandId: cmd(),
      draft: RecordDraft(
        type: RecordType.expense,
        money: m('10.00'),
        bookId: 1,
        recordTime: 1000,
        categoryId: food,
        assetId: cash,
        remark: '买咖啡 50% 折扣',
      ),
    );
    await ledger.saveRecord(
      commandId: cmd(),
      draft: RecordDraft(
        type: RecordType.expense,
        money: m('10.00'),
        bookId: 1,
        recordTime: 2000,
        categoryId: food,
        assetId: cash,
        remark: '买咖啡 500 折扣',
      ),
    );

    final resPercent = await searchQueries.getRecords(
      const SearchFilter(bookId: 1, keyword: '50%'),
    );
    expect(resPercent, hasLength(1));
    expect(resPercent.first.remark, contains('50%'));

    // 2. Literal _ test: "item_1" vs "itemX1"
    await ledger.saveRecord(
      commandId: cmd(),
      draft: RecordDraft(
        type: RecordType.expense,
        money: m('10.00'),
        bookId: 1,
        recordTime: 3000,
        categoryId: food,
        assetId: cash,
        remark: 'item_1',
      ),
    );
    await ledger.saveRecord(
      commandId: cmd(),
      draft: RecordDraft(
        type: RecordType.expense,
        money: m('10.00'),
        bookId: 1,
        recordTime: 4000,
        categoryId: food,
        assetId: cash,
        remark: 'itemX1',
      ),
    );

    final resUnderscore = await searchQueries.getRecords(
      const SearchFilter(bookId: 1, keyword: 'm_1'),
    );
    expect(resUnderscore, hasLength(1));
    expect(resUnderscore.first.remark, 'item_1');

    // 3. Literal \ test: "c:\\docs"
    await ledger.saveRecord(
      commandId: cmd(),
      draft: RecordDraft(
        type: RecordType.expense,
        money: m('10.00'),
        bookId: 1,
        recordTime: 5000,
        categoryId: food,
        assetId: cash,
        remark: r'路径 c:\docs',
      ),
    );
    final resBackslash = await searchQueries.getRecords(
      const SearchFilter(bookId: 1, keyword: r'\docs'),
    );
    expect(resBackslash, hasLength(1));
    expect(resBackslash.first.remark, contains(r'\docs'));
  });

  test('Search filter: money range [minMoneyMinor, maxMoneyMinor]', () async {
    final cash = await createAccount('现金', '1000.00');
    final food = await getCategoryId('餐饮');

    for (final amt in ['30.00', '80.00', '120.00', '200.00']) {
      await ledger.saveRecord(
        commandId: cmd(),
        draft: RecordDraft(
          type: RecordType.expense,
          money: m(amt),
          bookId: 1,
          recordTime: 1000,
          categoryId: food,
          assetId: cash,
        ),
      );
    }

    final res = await searchQueries.getRecords(
      SearchFilter(
        bookId: 1,
        minMoneyMinor: BigInt.from(5000), // 50.00
        maxMoneyMinor: BigInt.from(15000), // 150.00
      ),
    );
    expect(res, hasLength(2));
    expect(
      res.map((r) => r.moneyMinor),
      containsAll([BigInt.from(8000), BigInt.from(12000)]),
    );
  });

  test(
    'Search filter: pagination and stable ordering (record_time, create_date, record_id DESC)',
    () async {
      final cash = await createAccount('现金', '1000.00');
      final food = await getCategoryId('餐饮');

      // Insert 10 records with same record_time but different creation order
      for (var i = 0; i < 10; i++) {
        await ledger.saveRecord(
          commandId: cmd(),
          draft: RecordDraft(
            type: RecordType.expense,
            money: m('${i + 1}.00'),
            bookId: 1,
            recordTime: 1000,
            categoryId: food,
            assetId: cash,
            remark: 'item-$i',
          ),
        );
      }

      // Page 1: 4 items
      final page1 = await searchQueries.getRecords(
        const SearchFilter(bookId: 1, limit: 4, offset: 0),
      );
      expect(page1, hasLength(4));

      // Page 2: 4 items
      final page2 = await searchQueries.getRecords(
        const SearchFilter(bookId: 1, limit: 4, offset: 4),
      );
      expect(page2, hasLength(4));

      // Page 3: 2 items
      final page3 = await searchQueries.getRecords(
        const SearchFilter(bookId: 1, limit: 4, offset: 8),
      );
      expect(page3, hasLength(2));

      // Verify all 10 distinct records without overlap
      final allIds = [
        ...page1.map((r) => r.recordId),
        ...page2.map((r) => r.recordId),
        ...page3.map((r) => r.recordId),
      ];
      expect(allIds.toSet(), hasLength(10));
    },
  );

  test(
    'Search queries summary: aggregateIncomeExpense of matching records',
    () async {
      final cash = await createAccount('现金', '1000.00');
      final food = await getCategoryId('餐饮');
      final salary = await getCategoryId('工资');

      await ledger.saveRecord(
        commandId: cmd(),
        draft: RecordDraft(
          type: RecordType.expense,
          money: m('40.00'),
          bookId: 1,
          recordTime: 1000,
          categoryId: food,
          assetId: cash,
        ),
      );
      await ledger.saveRecord(
        commandId: cmd(),
        draft: RecordDraft(
          type: RecordType.expense,
          money: m('60.00'),
          bookId: 1,
          recordTime: 2000,
          categoryId: food,
          assetId: cash,
        ),
      );
      await ledger.saveRecord(
        commandId: cmd(),
        draft: RecordDraft(
          type: RecordType.income,
          money: m('300.00'),
          bookId: 1,
          recordTime: 3000,
          categoryId: salary,
          assetId: cash,
        ),
      );

      final summary = await searchQueries
          .watchSummary(const SearchFilter(bookId: 1))
          .first;
      expect(summary.expense, BigInt.from(10000)); // 100.00
      expect(summary.income, BigInt.from(30000)); // 300.00
      expect(summary.balance, BigInt.from(20000)); // 200.00
    },
  );
}
