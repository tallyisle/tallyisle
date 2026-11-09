import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/catalog/currency_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/data/repo/ledger_queries.dart';
import 'package:tallyisle/domain/ledger/record_extra.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/asset_overview.dart';
import 'package:tallyisle/domain/rules/currency_rates.dart';
import 'package:tallyisle/domain/rules/income_expense.dart';

Money m(String s) => Money.parse(s);

void main() {
  group('rate conversion helpers', () {
    test('price <-> rate_to_anchor round trip', () {
      expect(rateToAnchorFromPrice('8'), '0.125');
      expect(priceFromRateToAnchor('0.125'), '8');
      final r = rateToAnchorFromPrice('7.1');
      expect(r, '0.140845070423');
      expect(priceFromRateToAnchor(r), '7.1');
      expect(() => rateToAnchorFromPrice('0'), throwsA(isA<Failure>()));
      expect(() => rateToAnchorFromPrice('abc'), throwsA(isA<Failure>()));
    });

    test('100 USD at 7.10 converts to 710.00 CNY', () {
      final rates = RateTable({
        'CNY': '1',
        'USD': rateToAnchorFromPrice('7.10'),
      });
      expect(
        rates.convert(BigInt.from(10000), 'USD', 'CNY'),
        BigInt.from(71000),
      );
    });

    test('bill snapshot is null for pure CNY and filled otherwise', () {
      final rates = RateTable({'CNY': '1', 'USD': '0.125'});
      expect(
        billSnapshot(
          source: 'CNY',
          sourceMinor: BigInt.from(100),
          account: 'CNY',
          assetMinor: BigInt.from(100),
          rates: rates,
        ),
        isNull,
      );
      final s = billSnapshot(
        source: 'USD',
        sourceMinor: BigInt.from(10000),
        account: 'CNY',
        assetMinor: BigInt.from(80000),
        rates: rates,
      )!;
      expect(s.sourceCode, 'USD');
      expect(s.assetCode, 'CNY');
      expect(s.assetNet, BigInt.from(80000));
      expect(s.baseAmount, BigInt.from(80000));

      final usdAccount = billSnapshot(
        source: 'USD',
        sourceMinor: BigInt.from(10000),
        account: 'USD',
        assetMinor: BigInt.from(10000),
        rates: rates,
      )!;
      expect(usdAccount.baseAmount, BigInt.from(80000));
    });
  });

  group('currency service and foreign bills', () {
    late AppDatabase db;
    late LedgerService ledger;
    late CurrencyService currencies;
    var n = 0;
    String cmd() => 'fx-${n++}';

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      ledger = LedgerService(db);
      currencies = CurrencyService(db);
    });
    tearDown(() => db.close());

    Future<BigInt> balance(int id) async => (await (db.select(
      db.assets,
    )..where((t) => t.id.equals(id))).getSingle()).balanceMinor;

    test('save, update and refuse deleting a used currency', () async {
      await currencies.saveCurrency(
        commandId: cmd(),
        code: 'usd',
        name: '美元',
        symbol: r'$',
        price: '7.10',
      );
      var usd = await (db.select(
        db.currencies,
      )..where((t) => t.code.equals('USD'))).getSingle();
      expect(priceFromRateToAnchor(usd.rateToAnchor), '7.1');

      await currencies.saveCurrency(
        commandId: cmd(),
        code: 'USD',
        name: '美元',
        symbol: r'$',
        price: '7.20',
      );
      usd = await (db.select(
        db.currencies,
      )..where((t) => t.code.equals('USD'))).getSingle();
      expect(priceFromRateToAnchor(usd.rateToAnchor), '7.2');

      await expectLater(
        currencies.saveCurrency(
          commandId: cmd(),
          code: 'CNY',
          name: '人民币',
          symbol: '¥',
          price: '1',
        ),
        throwsA(isA<Failure>()),
      );

      await ledger.createAsset(
        commandId: cmd(),
        name: '美元账户',
        initial: m('100.00'),
        currency: 'USD',
      );
      await expectLater(
        currencies.deleteCurrency(commandId: cmd(), code: 'USD'),
        throwsA(isA<Failure>()),
      );
    });

    test('USD expense on a CNY account books CNY and stats use CNY', () async {
      final cash = await ledger.createAsset(
        commandId: cmd(),
        name: '现金',
        initial: m('1000.00'),
      );
      final food = (await (db.select(
        db.recordCategories,
      )..where((t) => t.name.equals('餐饮'))).getSingle()).id;
      final rates = RateTable({'CNY': '1', 'USD': '0.125'});
      final extra = RecordExtra()
        ..currency = billSnapshot(
          source: 'USD',
          sourceMinor: BigInt.from(1000),
          account: 'CNY',
          assetMinor: BigInt.from(8000),
          rates: rates,
        );
      await ledger.saveRecord(
        commandId: cmd(),
        draft: RecordDraft(
          type: RecordType.expense,
          money: m('80.00'),
          bookId: 1,
          recordTime: 1000,
          categoryId: food,
          assetId: cash,
          extra: extra,
        ),
      );
      expect(await balance(cash), BigInt.from(92000));
      final rows = await LedgerQueries(db).watchRecords(1, 0, 5000).first;
      final sum = aggregateIncomeExpense(rows.map(statEntryOf));
      expect(sum.expense, BigInt.from(8000));
    });

    test('cross-currency transfer moves source and target amounts', () async {
      final cny = await ledger.createAsset(
        commandId: cmd(),
        name: '人民币卡',
        initial: m('1000.00'),
      );
      final usd = await ledger.createAsset(
        commandId: cmd(),
        name: '美元卡',
        initial: m('0.00'),
        currency: 'USD',
      );
      final rates = RateTable({'CNY': '1', 'USD': '0.125'});
      final extra = RecordExtra()
        ..currency = billSnapshot(
          source: 'CNY',
          sourceMinor: BigInt.from(80000),
          account: 'USD',
          assetMinor: BigInt.from(10000),
          rates: rates,
        );
      await ledger.saveRecord(
        commandId: cmd(),
        draft: RecordDraft(
          type: RecordType.transfer,
          money: m('800.00'),
          bookId: 1,
          recordTime: 1000,
          fromAssetId: cny,
          toAssetId: usd,
          extra: extra,
        ),
      );
      expect(await balance(cny), BigInt.from(20000));
      expect(await balance(usd), BigInt.from(10000));
    });
  });
}
