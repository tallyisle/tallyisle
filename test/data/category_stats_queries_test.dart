import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/catalog/catalog_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/data/repo/category_stats_queries.dart';
import 'package:tallyisle/domain/model/codes.dart';

Money m(String s) => Money.parse(s);

void main() {
  late AppDatabase db;
  late LedgerService ledger;
  late CatalogService catalog;
  late CategoryStatsQueries queries;
  var cmdCounter = 0;
  String cmd() => 'cmd-catstats-${cmdCounter++}';

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    ledger = LedgerService(db);
    catalog = CatalogService(db);
    queries = CategoryStatsQueries(db);
  });

  tearDown(() => db.close());

  Future<int> createAccount(String name, String balance) =>
      ledger.createAsset(commandId: cmd(), name: name, initial: m(balance));

  Future<int> getCategoryId(String name, {int bookId = 1}) async =>
      (await (db.select(db.recordCategories)..where(
                (t) => t.accountBookId.equals(bookId) & t.name.equals(name),
              ))
              .getSingle())
          .id;

  test(
    'Multi-book filtering: queries records from one or multiple books',
    () async {
      final cash = await createAccount('现金', '1000.00');
      final food1 = await getCategoryId('餐饮', bookId: 1);
      final book2 = await catalog.createBook(commandId: cmd(), name: '旅行账本');
      final food2 = await getCategoryId('餐饮', bookId: book2);

      // Book 1 bill: 50.00
      await ledger.saveRecord(
        commandId: cmd(),
        draft: RecordDraft(
          type: RecordType.expense,
          money: m('50.00'),
          bookId: 1,
          recordTime: 10000,
          categoryId: food1,
          assetId: cash,
        ),
      );

      // Book 2 bill: 88.00
      await ledger.saveRecord(
        commandId: cmd(),
        draft: RecordDraft(
          type: RecordType.expense,
          money: m('88.00'),
          bookId: book2,
          recordTime: 11000,
          categoryId: food2,
          assetId: cash,
        ),
      );

      // Single book 1
      final resBook1 = await queries.getRecords(
        const AnalyzeFilter(bookIds: [1], startMs: 0, endMs: 20000),
      );
      expect(resBook1.length, 1);
      expect(resBook1.first.moneyMinor, BigInt.from(5000));

      // Multi-book [1, book2]
      final resBoth = await queries.getRecords(
        AnalyzeFilter(bookIds: [1, book2], startMs: 0, endMs: 20000),
      );
      expect(resBoth.length, 2);
      final total = resBoth.fold(BigInt.zero, (sum, r) => sum + r.moneyMinor);
      expect(total, BigInt.from(13800)); // 50 + 88 = 138
    },
  );

  test(
    'Multi-tag filtering with DISTINCT: prevents duplicate rows when bill has multiple tags',
    () async {
      final cash = await createAccount('银行卡', '2000.00');
      final food = await getCategoryId('餐饮');

      // Create 2 tags
      final tagWork = await catalog.createTag(commandId: cmd(), name: '工作');
      final tagMeal = await catalog.createTag(commandId: cmd(), name: '聚餐');

      // Record has BOTH tags
      final recId = await ledger.saveRecord(
        commandId: cmd(),
        draft: RecordDraft(
          type: RecordType.expense,
          money: m('120.00'),
          bookId: 1,
          recordTime: 15000,
          categoryId: food,
          assetId: cash,
          tagIds: [tagWork, tagMeal],
        ),
      );

      // Filter matching BOTH tagWork and tagMeal
      final records = await queries.getRecords(
        AnalyzeFilter(
          bookIds: const [1],
          startMs: 0,
          endMs: 20000,
          tagIds: {tagWork, tagMeal},
        ),
      );

      // DISTINCT must guarantee exactly 1 record is returned, NOT 2!
      expect(records.length, 1);
      expect(records.first.recordId, recId);
      expect(records.first.moneyMinor, BigInt.from(12000));
    },
  );

  test('exclude_ex_in is strictly excluded from query results', () async {
    final cash = await createAccount('零钱', '1000.00');
    final food = await getCategoryId('餐饮');

    await ledger.saveRecord(
      commandId: cmd(),
      draft: RecordDraft(
        type: RecordType.expense,
        money: m('30.00'),
        bookId: 1,
        recordTime: 1000,
        categoryId: food,
        assetId: cash,
        excludeExIn: false,
      ),
    );

    await ledger.saveRecord(
      commandId: cmd(),
      draft: RecordDraft(
        type: RecordType.expense,
        money: m('99.00'),
        bookId: 1,
        recordTime: 2000,
        categoryId: food,
        assetId: cash,
        excludeExIn: true, // Should be excluded!
      ),
    );

    final records = await queries.getRecords(
      const AnalyzeFilter(bookIds: [1], startMs: 0, endMs: 5000),
    );
    expect(records.length, 1);
    expect(records.first.moneyMinor, BigInt.from(3000));
  });

  test('includeExcludeBudget toggle controls exclude_budget bills', () async {
    final cash = await createAccount('账户', '1000.00');
    final food = await getCategoryId('餐饮');

    await ledger.saveRecord(
      commandId: cmd(),
      draft: RecordDraft(
        type: RecordType.expense,
        money: m('50.00'),
        bookId: 1,
        recordTime: 1000,
        categoryId: food,
        assetId: cash,
        excludeBudget: false,
      ),
    );

    await ledger.saveRecord(
      commandId: cmd(),
      draft: RecordDraft(
        type: RecordType.expense,
        money: m('70.00'),
        bookId: 1,
        recordTime: 2000,
        categoryId: food,
        assetId: cash,
        excludeBudget: true,
      ),
    );

    // When includeExcludeBudget = true (default): returns both
    final withBudget = await queries.getRecords(
      const AnalyzeFilter(
        bookIds: [1],
        startMs: 0,
        endMs: 5000,
        includeExcludeBudget: true,
      ),
    );
    expect(withBudget.length, 2);

    // When includeExcludeBudget = false: only normal bill
    final withoutBudget = await queries.getRecords(
      const AnalyzeFilter(
        bookIds: [1],
        startMs: 0,
        endMs: 5000,
        includeExcludeBudget: false,
      ),
    );
    expect(withoutBudget.length, 1);
    expect(withoutBudget.first.moneyMinor, BigInt.from(5000));
  });

  test('Category and Asset filtering in queries', () async {
    final cash = await createAccount('现金', '1000.00');
    final card = await createAccount('银行卡', '1000.00');
    final food = await getCategoryId('餐饮');
    final shopping = await getCategoryId('购物');

    await ledger.saveRecord(
      commandId: cmd(),
      draft: RecordDraft(
        type: RecordType.expense,
        money: m('25.00'),
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
        categoryId: shopping,
        assetId: card,
      ),
    );

    // Filter by category: food
    final catFiltered = await queries.getRecords(
      AnalyzeFilter(
        bookIds: const [1],
        startMs: 0,
        endMs: 5000,
        categoryIds: {food},
      ),
    );
    expect(catFiltered.length, 1);
    expect(catFiltered.first.moneyMinor, BigInt.from(2500));

    // Filter by asset: card
    final assetFiltered = await queries.getRecords(
      AnalyzeFilter(
        bookIds: const [1],
        startMs: 0,
        endMs: 5000,
        assetIds: {card},
      ),
    );
    expect(assetFiltered.length, 1);
    expect(assetFiltered.first.moneyMinor, BigInt.from(6000));
  });
}
