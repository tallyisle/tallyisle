import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/db/seed.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/data/repo/ledger_queries.dart';
import 'package:tallyisle/domain/ledger/record_relations.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/income_expense.dart';

Money m(String s) => Money.parse(s);

void main() {
  late AppDatabase db;
  late LedgerService ledger;
  late LedgerQueries queries;
  var n = 0;
  String cmd() => 'cmd-${n++}';

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    ledger = LedgerService(db);
    queries = LedgerQueries(db);
  });
  tearDown(() => db.close());

  Future<BigInt> balance(int id) async => (await (db.select(
    db.assets,
  )..where((t) => t.id.equals(id))).getSingle()).balanceMinor;

  Future<int> category(String name) async => (await (db.select(
    db.recordCategories,
  )..where((t) => t.name.equals(name))).getSingle()).id;

  Future<int> account(String name, String initial) =>
      ledger.createAsset(commandId: cmd(), name: name, initial: m(initial));

  test('first run seeds book 1, 16 categories and no accounts', () async {
    final books = await db.select(db.accountBooks).get();
    expect(books.single.id, defaultBookId);
    expect(books.single.name, '日常账本');
    final cats = await db.select(db.recordCategories).get();
    expect(cats.where((c) => c.type == 0), hasLength(12));
    expect(cats.where((c) => c.type == 1), hasLength(4));
    expect(await db.select(db.assets).get(), isEmpty);
    expect(await queries.watchCurrentBookId().first, 1);
  });

  test('SC-001: 1000.00 -> expense 85.50 -> edit 100.00 -> delete', () async {
    final cash = await account('现金', '1000.00');
    final food = await category('餐饮');
    final id = await ledger.saveRecord(
      commandId: cmd(),
      draft: RecordDraft(
        type: RecordType.expense,
        money: m('85.50'),
        bookId: 1,
        recordTime: DateTime(2026, 11, 6, 12).millisecondsSinceEpoch,
        categoryId: food,
        assetId: cash,
      ),
    );
    expect(await balance(cash), BigInt.from(91450));

    await ledger.saveRecord(
      commandId: cmd(),
      recordId: id,
      draft: RecordDraft(
        type: RecordType.expense,
        money: m('100.00'),
        bookId: 1,
        recordTime: DateTime(2026, 11, 6, 12).millisecondsSinceEpoch,
        categoryId: food,
        assetId: cash,
      ),
    );
    expect(await balance(cash), BigInt.from(90000));

    await ledger.deleteRecord(commandId: cmd(), recordId: id);
    expect(await balance(cash), BigInt.from(100000));
    expect(await db.select(db.records).get(), isEmpty);
  });

  test(
    'retrying the same command is idempotent; changed payload conflicts',
    () async {
      final cash = await account('现金', '100.00');
      final food = await category('餐饮');
      RecordDraft draft(String amount) => RecordDraft(
        type: RecordType.expense,
        money: m(amount),
        bookId: 1,
        recordTime: 1,
        categoryId: food,
        assetId: cash,
      );
      final a = await ledger.saveRecord(
        commandId: 'same',
        draft: draft('10.00'),
      );
      final b = await ledger.saveRecord(
        commandId: 'same',
        draft: draft('10.00'),
      );
      expect(a, b);
      expect(await balance(cash), BigInt.from(9000));
      await expectLater(
        ledger.saveRecord(commandId: 'same', draft: draft('11.00')),
        throwsA(
          isA<Failure>().having((f) => f.code, 'code', FailureCode.conflict),
        ),
      );
    },
  );

  test(
    'transfer with fee writes a type=12 child and balances both sides',
    () async {
      final bank = await account('银行卡', '1000.00');
      final wallet = await account('钱包', '0.00');
      final time = DateTime(2026, 11, 6, 9).millisecondsSinceEpoch;
      final id = await ledger.saveRecord(
        commandId: cmd(),
        draft: RecordDraft(
          type: RecordType.transfer,
          money: m('200.00'),
          bookId: 1,
          recordTime: time,
          fromAssetId: bank,
          toAssetId: wallet,
          fee: m('2.00'),
        ),
      );
      expect(await balance(bank), BigInt.from(79800));
      expect(await balance(wallet), BigInt.from(20000));
      final fee = await queries.feeChildOf(id);
      expect(fee, isNotNull);
      expect(fee!.type, RecordType.fee);
      expect(fee.subType, 0);
      expect(fee.assetId, bank);
      expect(fee.recordTime, time + 1);

      // Edit: fee paid by the target, amount 300.
      await ledger.saveRecord(
        commandId: cmd(),
        recordId: id,
        draft: RecordDraft(
          type: RecordType.transfer,
          money: m('300.00'),
          bookId: 1,
          recordTime: time,
          fromAssetId: bank,
          toAssetId: wallet,
          fee: m('1.00'),
          feeFromTarget: true,
        ),
      );
      expect(await balance(bank), BigInt.from(70000));
      expect(await balance(wallet), BigInt.from(29900));

      // Edit: fee removed -> child deleted.
      await ledger.saveRecord(
        commandId: cmd(),
        recordId: id,
        draft: RecordDraft(
          type: RecordType.transfer,
          money: m('300.00'),
          bookId: 1,
          recordTime: time,
          fromAssetId: bank,
          toAssetId: wallet,
        ),
      );
      expect(await queries.feeChildOf(id), isNull);
      expect(await balance(wallet), BigInt.from(30000));

      await ledger.deleteRecord(commandId: cmd(), recordId: id);
      expect(await balance(bank), BigInt.from(100000));
      expect(await balance(wallet), BigInt.zero);
    },
  );

  test('fee at 23:59:59.999 moves the parent 1 ms earlier', () async {
    final a = await account('A', '10.00');
    final b = await account('B', '0.00');
    final time = DateTime(2026, 11, 6, 23, 59, 59, 999).millisecondsSinceEpoch;
    final id = await ledger.saveRecord(
      commandId: cmd(),
      draft: RecordDraft(
        type: RecordType.transfer,
        money: m('1.00'),
        bookId: 1,
        recordTime: time,
        fromAssetId: a,
        toAssetId: b,
        fee: m('0.10'),
      ),
    );
    final parent = await queries.watchRecord(id).first;
    expect(parent!.recordTime, time - 1);
    expect((await queries.feeChildOf(id))!.recordTime, time);
  });

  test('a failure inside the transaction leaves balances untouched', () async {
    final cash = await account('现金', '50.00');
    await expectLater(
      ledger.saveRecord(
        commandId: cmd(),
        draft: RecordDraft(
          type: RecordType.transfer,
          money: m('10.00'),
          bookId: 1,
          recordTime: 1,
          fromAssetId: cash,
          toAssetId: 999,
        ),
      ),
      throwsA(isA<Failure>()),
    );
    expect(await balance(cash), BigInt.from(5000));
    expect(await db.select(db.records).get(), isEmpty);
  });

  test(
    'adjustBalance writes a type=4 record with the signed difference',
    () async {
      final cash = await account('现金', '100.00');
      await ledger.adjustBalance(
        commandId: cmd(),
        assetId: cash,
        target: m('80.00'),
        bookId: 1,
      );
      expect(await balance(cash), BigInt.from(8000));
      final r = (await db.select(db.records).get()).single;
      expect(r.type, RecordType.balanceAdjust);
      expect(r.fromAssetId, cash);
      expect(r.moneyMinor, BigInt.from(-2000));
    },
  );

  test(
    'period query is closed on both ends and hides type 4 by default',
    () async {
      final cash = await account('现金', '0.00');
      final food = await category('餐饮');
      Future<void> at(DateTime t) => ledger.saveRecord(
        commandId: cmd(),
        draft: RecordDraft(
          type: RecordType.expense,
          money: m('1.00'),
          bookId: 1,
          recordTime: t.millisecondsSinceEpoch,
          categoryId: food,
          assetId: cash,
        ),
      );
      await at(DateTime(2026, 11, 1));
      await at(DateTime(2026, 11, 30, 23, 59, 59, 999));
      await at(DateTime(2026, 12, 1));
      await ledger.adjustBalance(
        commandId: cmd(),
        assetId: cash,
        target: m('5.00'),
        bookId: 1,
      );
      final rows = await queries
          .watchRecords(
            1,
            DateTime(2026, 11).millisecondsSinceEpoch,
            DateTime(2026, 11, 30, 23, 59, 59, 999).millisecondsSinceEpoch,
          )
          .first;
      expect(rows, hasLength(2));
    },
  );

  test('money columns are stored as SQLite integers', () async {
    await account('现金', '12.34');
    final row = await db
        .customSelect(
          'SELECT typeof(balance_minor) AS t, balance_minor AS v FROM asset',
        )
        .getSingle();
    expect(row.read<String>('t'), 'integer');
    expect(row.read<int>('v'), 1234);
  });

  test('used_times increments on create and edit only', () async {
    final cash = await account('现金', '10.00');
    final food = await category('餐饮');
    RecordDraft d() => RecordDraft(
      type: 0,
      money: m('1.00'),
      bookId: 1,
      recordTime: 1,
      categoryId: food,
      assetId: cash,
    );
    final id = await ledger.saveRecord(commandId: cmd(), draft: d());
    await ledger.saveRecord(commandId: cmd(), recordId: id, draft: d());
    await ledger.deleteRecord(commandId: cmd(), recordId: id);
    final asset = await (db.select(
      db.assets,
    )..where((t) => t.id.equals(cash))).getSingle();
    expect(asset.usedTimes, 2);
    expect(asset.createDate, isNonZero);
    expect(const Constant(1), isNotNull);
  });

  group('refunds and reimbursements', () {
    test('refund adds money back, links both ways, nets home stats', () async {
      final cash = await account('现金', '500.00');
      final food = await category('餐饮');
      final id = await ledger.saveRecord(
        commandId: cmd(),
        draft: RecordDraft(
          type: RecordType.expense,
          money: m('200.00'),
          bookId: 1,
          recordTime: 1000,
          categoryId: food,
          assetId: cash,
        ),
      );
      final refundId = await ledger.addRefund(
        commandId: cmd(),
        originId: id,
        amount: m('60.00'),
        assetId: cash,
        recordTime: 2000,
      );
      expect(await balance(cash), BigInt.from(36000));
      final child = (await queries.watchRecord(refundId).first)!;
      expect(child.type, RecordType.expense);
      expect(child.moneyMinor, BigInt.from(-6000));
      expect(child.recordCatId, food);
      final rows = await queries.watchRecords(1, 0, 10000).first;
      final s = aggregateIncomeExpense(rows.map(statEntryOf));
      expect(
        s.expense,
        BigInt.from(14000),
      ); // 200 - 60, counted on the original

      // Editing the original keeps the link.
      await ledger.saveRecord(
        commandId: cmd(),
        recordId: id,
        draft: RecordDraft(
          type: RecordType.expense,
          money: m('210.00'),
          bookId: 1,
          recordTime: 1000,
          categoryId: food,
          assetId: cash,
        ),
      );
      final again = await queries.watchRecords(1, 0, 10000).first;
      expect(
        aggregateIncomeExpense(again.map(statEntryOf)).expense,
        BigInt.from(15000),
      );

      // The child cannot be edited through the form.
      await expectLater(
        ledger.saveRecord(
          commandId: cmd(),
          recordId: refundId,
          draft: RecordDraft(
            type: 0,
            money: m('1.00'),
            bookId: 1,
            recordTime: 1,
            categoryId: food,
          ),
        ),
        throwsA(isA<Failure>()),
      );

      // Deleting the child unlinks it and takes the money back out.
      await ledger.deleteRecord(commandId: cmd(), recordId: refundId);
      expect(await balance(cash), BigInt.from(29000));
      final origin = (await queries.watchRecord(id).first)!;
      expect(RecordRelations.parse(origin.relInfo).refunds, isNull);
    });

    test('deleting the original cascades its refunds', () async {
      final cash = await account('现金', '100.00');
      final food = await category('餐饮');
      final id = await ledger.saveRecord(
        commandId: cmd(),
        draft: RecordDraft(
          type: 0,
          money: m('50.00'),
          bookId: 1,
          recordTime: 1,
          categoryId: food,
          assetId: cash,
        ),
      );
      await ledger.addRefund(
        commandId: cmd(),
        originId: id,
        amount: m('20.00'),
        assetId: cash,
        recordTime: 2,
      );
      expect(await balance(cash), BigInt.from(7000));
      await ledger.deleteRecord(commandId: cmd(), recordId: id);
      expect(await balance(cash), BigInt.from(10000));
      expect(await db.select(db.records).get(), isEmpty);
    });

    test('reimbursable 120: receipt 50 then 70; stats 0 -> 70 -> 0', () async {
      final card = await account('信用卡', '0.00');
      final wallet = await account('钱包', '0.00');
      final food = await category('餐饮');
      final id = await ledger.saveRecord(
        commandId: cmd(),
        draft: RecordDraft(
          type: RecordType.reimbursable,
          money: m('120.00'),
          bookId: 1,
          recordTime: 5000,
          categoryId: food,
          fromAssetId: card,
        ),
      );
      expect(await balance(card), BigInt.from(-12000));
      Future<BigInt> expense() async => aggregateIncomeExpense(
        (await queries.watchRecords(1, 0, 100000).first).map(statEntryOf),
      ).expense;
      expect(await expense(), BigInt.zero);

      final r1 = await ledger.addReimbursement(
        commandId: cmd(),
        originId: id,
        amount: m('50.00'),
        assetId: wallet,
        recordTime: 100,
      );
      expect(await expense(), BigInt.from(7000));
      final receipt = (await queries.watchRecord(r1).first)!;
      expect(receipt.type, RecordType.reimburseReceipt);
      expect(receipt.recordTime, 5001); // clamped after the original
      expect(await balance(wallet), BigInt.from(5000));

      await ledger.addReimbursement(
        commandId: cmd(),
        originId: id,
        amount: m('70.00'),
        assetId: wallet,
        recordTime: 9000,
      );
      expect(await expense(), BigInt.zero);
      expect(await balance(wallet), BigInt.from(12000));

      await ledger.deleteRecord(commandId: cmd(), recordId: id);
      expect(await balance(card), BigInt.zero);
      expect(await balance(wallet), BigInt.zero);
    });
  });
}
