import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/domain/ledger/asset_json.dart';
import 'package:tallyisle/domain/model/codes.dart';

Money m(String s) => Money.parse(s);

void main() {
  late AppDatabase db;
  late LedgerService ledger;
  var n = 0;
  String cmd() => 'asset-cmd-${n++}';

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    ledger = LedgerService(db);
  });
  tearDown(() => db.close());

  Future<Asset> load(int id) =>
      (db.select(db.assets)..where((t) => t.id.equals(id))).getSingle();

  test(
    'credit card stores limit in init_money and debt as negative balance',
    () async {
      final info = CreditInfo()
        ..billDay = 10
        ..repaymentDay = 28
        ..billDayCounted = true;
      final id = await ledger.createAsset(
        commandId: cmd(),
        name: '招行信用卡',
        initial: -m('1500.00'),
        type: AssetType.credit,
        limit: m('20000.00'),
        creditInfo: info.encode(),
        currency: ' usd ',
      );
      final a = await load(id);
      expect(a.type, AssetType.credit);
      expect(a.balanceMinor, BigInt.from(-150000));
      expect(a.initMoneyMinor, BigInt.from(2000000));
      expect(a.currency, 'USD');
      final parsed = CreditInfo.parse(a.creditInfo);
      expect(parsed.billDay, 10);
      expect(parsed.repaymentDay, 28);
      expect(parsed.repaymentAfterBillDay, isFalse);
      expect(parsed.billDayCounted, isTrue);
    },
  );

  test('updateAsset edits properties but never the balance', () async {
    final id = await ledger.createAsset(
      commandId: cmd(),
      name: '现金',
      initial: m('100.00'),
    );
    await ledger.updateAsset(
      commandId: cmd(),
      assetId: id,
      name: '钱包',
      remark: '日常',
      countedInNetWorth: false,
    );
    final a = await load(id);
    expect(a.name, '钱包');
    expect(a.remark, '日常');
    expect(a.isEffectiveAsset, 0);
    expect(a.balanceMinor, BigInt.from(10000));
    expect(a.initMoneyMinor, BigInt.from(10000));
  });

  test('status changes and delete is refused once bills exist', () async {
    final id = await ledger.createAsset(
      commandId: cmd(),
      name: '现金',
      initial: m('100.00'),
    );
    await ledger.setAssetStatus(
      commandId: cmd(),
      assetId: id,
      status: AssetStatus.hidden,
    );
    expect((await load(id)).status, AssetStatus.hidden);

    await ledger.adjustBalance(
      commandId: cmd(),
      assetId: id,
      target: m('90.00'),
      bookId: 1,
    );
    await expectLater(
      ledger.deleteAsset(commandId: cmd(), assetId: id),
      throwsA(isA<Failure>()),
    );

    final unused = await ledger.createAsset(
      commandId: cmd(),
      name: '空账户',
      initial: m('0.00'),
    );
    await ledger.deleteAsset(commandId: cmd(), assetId: unused);
    expect(
      await (db.select(
        db.assets,
      )..where((t) => t.id.equals(unused))).getSingleOrNull(),
      isNull,
    );
  });

  test('asset JSON keeps unknown keys and sums active temporary limits', () {
    final info = CreditInfo.parse('{"bill_day":-2,"x_future":1}')
      ..repaymentDay = 5;
    expect(info.billDay, endOfMonthDay);
    expect(info.encode(), contains('"x_future":1'));

    final extra = AssetExtra()
      ..tempAmounts = [
        TempAmount(amount: BigInt.from(100000), deadline: 2000),
        TempAmount(amount: BigInt.from(50000), deadline: 500),
      ];
    expect(extra.activeTempAmount(1000), BigInt.from(100000));
    expect(() => CreditInfo.parse('[1]'), throwsA(isA<Failure>()));
  });
}
