import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/catalog/currency_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/deposit/fixed_deposit_service.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/data/repo/fixed_deposit_queries.dart';
import 'package:tallyisle/data/repo/ledger_queries.dart' show statEntryOf;
import 'package:tallyisle/domain/ledger/record_extra.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/fixed_deposit.dart';
import 'package:tallyisle/domain/rules/income_expense.dart';
import 'package:tallyisle/domain/rules/reconciliation.dart';

BigInt y(String amount) => Money.parse(amount).storageMinor;

void main() {
  late int clockMs;
  late AppDatabase db;
  late LedgerService ledger;
  late CurrencyService currencyService;
  late FixedDepositService depositService;
  late FixedDepositQueries depositQueries;
  var seq = 0;
  String cmd() => 'fd-cmd-${seq++}';

  setUp(() {
    clockMs = DateTime(2026, 6, 1, 12, 0).millisecondsSinceEpoch;
    db = AppDatabase(NativeDatabase.memory(), nowMs: () => clockMs);
    ledger = LedgerService(db);
    currencyService = CurrencyService(db);
    depositService = FixedDepositService(db);
    depositQueries = FixedDepositQueries(db);
  });

  tearDown(() => db.close());

  Future<Asset> assetRow(int id) async =>
      (await (db.select(db.assets)..where((t) => t.id.equals(id))).getSingle());

  group('R3: Mode A, Mode B1 (ASYM-FD-08), Mode B2 & ASYM-FD-07 book binding', () {
    test(
      'Mode A cross-currency (FD-F02: 100 USD from CNY @ 0.13 -> 769.23 CNY) in Book 2',
      () async {
        // Create Book 2 so we prove ASYM-FD-07 never hardcodes Book 1.
        await db
            .into(db.accountBooks)
            .insert(
              AccountBooksCompanion.insert(
                id: const Value(2),
                name: '家庭定存账本',
                createDate: clockMs,
              ),
            );
        await db
            .into(db.currencies)
            .insertOnConflictUpdate(
              CurrenciesCompanion.insert(
                code: 'USD',
                name: '美元',
                symbol: r'$',
                rateToAnchor: '0.13',
                anchorCode: 'CNY',
              ),
            );

        final cnyId = await ledger.createAsset(
          commandId: cmd(),
          name: '招行活期',
          initial: Money.parse('2000.00', currency: 'CNY'),
          currency: 'CNY',
        );
        final usdId = await ledger.createAsset(
          commandId: cmd(),
          name: '汇丰美元卡',
          initial: Money.parse('50.00', currency: 'USD'),
          currency: 'USD',
        );

        final depTime = DateTime(2026, 3, 1, 10, 0).millisecondsSinceEpoch;
        final idx = await depositService.createDeposit(
          commandId: cmd(),
          draft: FixedDepositDraft(
            targetAssetId: usdId,
            principal: Money.parse('100.00', currency: 'USD'),
            annualRate: percentToAnnualRate('4.5'),
            periodUnit: DepositPeriodUnit.year,
            periodCount: 1,
            depositDate: depTime,
            currency: 'USD',
            fromAssetId: cnyId,
            remark: '美元一年定存',
            bookId: 2,
          ),
        );
        expect(idx, 0);

        // Source deducted 769.23 CNY -> 1230.77 CNY; Target credited 100.00 USD -> 150.00 USD
        final cnyAfter = await assetRow(cnyId);
        final usdAfter = await assetRow(usdId);
        expect(cnyAfter.balanceMinor, y('1230.77'));
        expect(usdAfter.balanceMinor, y('150.00'));
        expect(cnyAfter.usedTimes, 1);
        expect(usdAfter.usedTimes, 1);

        final item = decodeFixedDepositList(usdAfter.fixedDepositInfo).single;
        expect(item.updateAssetBalance, isFalse);
        expect(item.transferRecordId, isNotNull);

        final tr = await (db.select(
          db.records,
        )..where((t) => t.recordId.equals(item.transferRecordId!))).getSingle();
        expect(tr.type, RecordType.transfer);
        expect(tr.subType, RecordDirection.expense);
        expect(tr.accountBookId, 2); // ASYM-FD-07 fixed!
        expect(tr.recordTime, depTime);
        expect(
          tr.moneyMinor,
          BigInt.from(76923),
        ); // 769.23 CNY in source currency!

        final curr = RecordExtra.parse(tr.extraInfo).currency!;
        expect(curr.sourceCode, 'CNY');
        expect(curr.sourceGross, BigInt.from(76923));
        expect(curr.assetCode, 'USD');
        expect(curr.assetNet, BigInt.from(10000));
        expect(curr.baseCode, 'CNY');
        expect(curr.baseAmount, BigInt.from(76923));

        // Ensure Mode A transfer (type=2, subType=0) never inflates income/expense stats!
        final summary = aggregateIncomeExpense([statEntryOf(tr)]);
        expect(summary.expense, BigInt.zero);
        expect(summary.income, BigInt.zero);
      },
    );

    test(
      'Mode B1 writes balanceAdjust record for reconciliation safety (ASYM-FD-08) & Mode B2 keeps balance unchanged',
      () async {
        final hostId = await ledger.createAsset(
          commandId: cmd(),
          name: '工行储蓄卡',
          initial: Money.parse('1000.00'),
        );

        // Mode B1 (default createBalanceAdjustRecord = true)
        final depTime = DateTime(2026, 5, 1, 9, 0).millisecondsSinceEpoch;
        await depositService.createDeposit(
          commandId: cmd(),
          draft: FixedDepositDraft(
            targetAssetId: hostId,
            principal: Money.parse('3000.00'),
            annualRate: percentToAnnualRate('2.0'),
            periodUnit: DepositPeriodUnit.month,
            periodCount: 6,
            depositDate: depTime,
            updateAssetBalance: true,
            remark: '工资定存',
          ),
        );
        expect((await assetRow(hostId)).balanceMinor, y('4000.00'));

        // Mode B2 (memo only)
        await depositService.createDeposit(
          commandId: cmd(),
          draft: FixedDepositDraft(
            targetAssetId: hostId,
            principal: Money.parse('500.00'),
            annualRate: percentToAnnualRate('1.5'),
            periodUnit: DepositPeriodUnit.month,
            periodCount: 3,
            depositDate: depTime + 1000,
            updateAssetBalance: false,
          ),
        );
        expect((await assetRow(hostId)).balanceMinor, y('4000.00'));

        // Verify reconciliation backward walk reaches exact initial 1000.00 with zero gap!
        final records = await db.select(db.records).get();
        expect(records, hasLength(1));
        expect(records.single.type, RecordType.balanceAdjust);
        final delta = recordForwardDelta(
          record: ReconRecord(
            id: records.single.recordId,
            type: records.single.type,
            subType: records.single.subType,
            moneyMinor: records.single.moneyMinor,
            fromAssetId: records.single.fromAssetId,
          ),
          accountId: hostId,
        );
        expect(y('4000.00') - delta, y('1000.00'));
      },
    );
  });

  group('R4, P-03, ASYM-FD-05..06 & FD-F04: Auto-settlement & concurrency', () {
    test(
      'Foreign-currency settlement, ASYM-FD-05 actual settled Record.bm, hidden account skip, and FD-F04 zero-interest guard',
      () async {
        // Set USD initially to 1 USD = 7.20 CNY, create USD deposit, then change rate to 1 USD = 8.00 CNY!
        await currencyService.saveCurrency(
          commandId: cmd(),
          code: 'USD',
          name: '美元',
          symbol: r'$',
          price: '7.20',
        );

        final usdId = await ledger.createAsset(
          commandId: cmd(),
          name: '美元定存卡',
          initial: Money.parse('1000.00', currency: 'USD'),
          currency: 'USD',
        );
        final cnyId = await ledger.createAsset(
          commandId: cmd(),
          name: '零息测试卡',
          initial: Money.parse('5000.00'),
        );
        final hiddenId = await ledger.createAsset(
          commandId: cmd(),
          name: '隐藏存折',
          initial: Money.parse('4000.00'),
        );

        // 1. USD deposit: 1000 USD @ 4.5% for 1 yr, due 2026-05-10 (expected 45.00 USD)
        await depositService.createDeposit(
          commandId: cmd(),
          draft: FixedDepositDraft(
            targetAssetId: usdId,
            principal: Money.parse('1000.00', currency: 'USD'),
            annualRate: percentToAnnualRate('4.5'),
            periodUnit: DepositPeriodUnit.year,
            periodCount: 1,
            depositDate: DateTime(2025, 5, 10).millisecondsSinceEpoch,
            currency: 'USD',
            remark: '汇丰定存',
          ),
        );

        // 2. Zero-interest deposit (FD-F04): 5000 CNY @ 0% for 1 month, due 2026-05-20
        await depositService.createDeposit(
          commandId: cmd(),
          draft: FixedDepositDraft(
            targetAssetId: cnyId,
            principal: Money.parse('5000.00'),
            annualRate: DecimalValue(BigInt.zero, 0),
            periodUnit: DepositPeriodUnit.month,
            periodCount: 1,
            depositDate: DateTime(2026, 4, 20).millisecondsSinceEpoch,
            remark: '',
          ),
        );

        // 3. Deposit on account that is then hidden (ASYM-FD-06)
        await depositService.createDeposit(
          commandId: cmd(),
          draft: FixedDepositDraft(
            targetAssetId: hiddenId,
            principal: Money.parse('4000.00'),
            annualRate: percentToAnnualRate('2.0'),
            periodUnit: DepositPeriodUnit.month,
            periodCount: 6,
            depositDate: DateTime(2025, 11, 20).millisecondsSinceEpoch,
          ),
        );
        await ledger.setAssetStatus(
          commandId: cmd(),
          assetId: hiddenId,
          status: AssetStatus.hidden,
        );

        // Update USD rate to 1 USD = 8.00 CNY (`rate_to_anchor = 0.125`) before maturity scan!
        await db
            .into(db.currencies)
            .insertOnConflictUpdate(
              CurrenciesCompanion.insert(
                code: 'USD',
                name: '美元',
                symbol: r'$',
                rateToAnchor: '0.125',
                anchorCode: 'CNY',
              ),
            );

        // Concurrent settleDueDeposits calls serialized via async mutex -> settles exactly 2!
        final results = await Future.wait([
          depositService.settleDueDeposits(nowMs: clockMs),
          depositService.settleDueDeposits(nowMs: clockMs),
          depositService.settleDueDeposits(nowMs: clockMs, assetId: hiddenId),
        ]);
        expect(results.reduce((a, b) => a + b), 2);

        // USD account: ONLY interest (+45.00 USD) added -> 1045.00 USD, usedTimes == 1
        final usdAfter = await assetRow(usdId);
        expect(usdAfter.balanceMinor, y('1045.00'));
        expect(usdAfter.usedTimes, 1);

        // Zero-interest CNY account (FD-F04): status==1, balance unchanged, usedTimes STILL 0!
        final cnyAfter = await assetRow(cnyId);
        expect(cnyAfter.balanceMinor, y('5000.00'));
        expect(cnyAfter.usedTimes, 0);
        final cnyDep = decodeFixedDepositList(cnyAfter.fixedDepositInfo).single;
        expect(cnyDep.isSettled, isTrue);

        // Hidden account (ASYM-FD-06): NOT settled even when targeted by assetId!
        final hiddenAfter = await assetRow(hiddenId);
        expect(hiddenAfter.balanceMinor, y('4000.00'));
        expect(
          decodeFixedDepositList(hiddenAfter.fixedDepositInfo).single.isRunning,
          isTrue,
        );

        // Verify ASYM-FD-05 in FixedDepositQueries: header settledIncomeMinor reads
        // actual settled Record.bm = 360.00 CNY (45 * 8.00), NOT historical 324.00 CNY!
        final overview = await depositQueries.getOverview();
        expect(overview.header.settledIncomeMinor, y('360.00'));
      },
    );
  });

  group(
    'R6, ASYM-FD-03, ASYM-FD-04 & ADR-009: Edit, remark sync, delete & idempotency',
    () {
      test(
        'ASYM-FD-03: editing settled deposit syncs remark to both transfer and income bills',
        () async {
          final srcId = await ledger.createAsset(
            commandId: cmd(),
            name: '活期卡',
            initial: Money.parse('20000.00'),
          );
          final hostId = await ledger.createAsset(
            commandId: cmd(),
            name: '定存卡',
            initial: Money.parse('0.00'),
          );

          await depositService.createDeposit(
            commandId: cmd(),
            draft: FixedDepositDraft(
              targetAssetId: hostId,
              principal: Money.parse('10000.00'),
              annualRate: percentToAnnualRate('2.4'),
              periodUnit: DepositPeriodUnit.month,
              periodCount: 3,
              depositDate: DateTime(2026, 2, 1).millisecondsSinceEpoch,
              fromAssetId: srcId,
              remark: '旧备注',
            ),
          );
          await depositService.settleDueDeposits(nowMs: clockMs);

          // Attempting to change principal on settled deposit fails validation
          await expectLater(
            depositService.updateDeposit(
              commandId: cmd(),
              assetId: hostId,
              index: 0,
              draft: FixedDepositDraft(
                targetAssetId: hostId,
                principal: Money.parse('9000.00'),
                annualRate: percentToAnnualRate('2.4'),
                periodUnit: DepositPeriodUnit.month,
                periodCount: 3,
                depositDate: DateTime(2026, 2, 1).millisecondsSinceEpoch,
                fromAssetId: srcId,
                remark: '新备注',
              ),
            ),
            throwsA(isA<Failure>()),
          );

          // Updating settled remark syncs transfer bill & income bill!
          await depositService.updateDepositRemark(
            commandId: cmd(),
            assetId: hostId,
            index: 0,
            remark: '年终奖定存',
          );

          final settledItem = decodeFixedDepositList(
            (await assetRow(hostId)).fixedDepositInfo,
          ).single;
          expect(settledItem.remark, '年终奖定存');

          final tr =
              await (db.select(db.records)..where(
                    (t) => t.recordId.equals(settledItem.transferRecordId!),
                  ))
                  .getSingle();
          final inc =
              await (db.select(db.records)..where(
                    (t) => t.recordId.equals(settledItem.incomeRecordId!),
                  ))
                  .getSingle();
          expect(tr.remark, '年终奖定存');
          expect(inc.remark, '定期存款收益：年终奖定存');
        },
      );

      test(
        'ASYM-FD-04: deleting deposit checks live record existence (zero double deduction)',
        () async {
          final srcId = await ledger.createAsset(
            commandId: cmd(),
            name: '工行活期',
            initial: Money.parse('30000.00'),
          );
          final hostId = await ledger.createAsset(
            commandId: cmd(),
            name: '招行定存',
            initial: Money.parse('3000.00'),
          );

          // Mode A 10,000 from srcId -> src=20,000, host=13,000; settles +60 -> host=13,060
          await depositService.createDeposit(
            commandId: cmd(),
            draft: FixedDepositDraft(
              targetAssetId: hostId,
              principal: Money.parse('10000.00'),
              annualRate: percentToAnnualRate('2.4'),
              periodUnit: DepositPeriodUnit.month,
              periodCount: 3,
              depositDate: DateTime(2026, 2, 15).millisecondsSinceEpoch,
              fromAssetId: srcId,
              remark: '三月期定存',
            ),
          );
          await depositService.settleDueDeposits(nowMs: clockMs);
          expect((await assetRow(hostId)).balanceMinor, y('13060.00'));
          expect((await assetRow(srcId)).balanceMinor, y('20000.00'));

          final item = decodeFixedDepositList(
            (await assetRow(hostId)).fixedDepositInfo,
          ).single;

          // User manually deletes the 60.00 interest bill in LedgerService FIRST!
          await ledger.deleteRecord(
            commandId: cmd(),
            recordId: item.incomeRecordId!,
          );
          expect((await assetRow(hostId)).balanceMinor, y('13000.00'));

          // Now user deletes the fixed deposit -> reverses transfer (10,000), skips missing 60.00!
          await depositService.deleteDeposit(
            commandId: cmd(),
            assetId: hostId,
            index: 0,
          );
          expect((await assetRow(hostId)).balanceMinor, y('3000.00'));
          expect((await assetRow(srcId)).balanceMinor, y('30000.00'));
          expect((await assetRow(hostId)).fixedDepositInfo, isNull);
        },
      );

      test(
        'Running deposit edit replaces mode cleanly & commandId is idempotent (ADR-009)',
        () async {
          final hostId = await ledger.createAsset(
            commandId: cmd(),
            name: '建行卡',
            initial: Money.parse('5000.00'),
          );

          final createCmd = cmd();
          final draft1 = FixedDepositDraft(
            targetAssetId: hostId,
            principal: Money.parse('2000.00'),
            annualRate: percentToAnnualRate('2.0'),
            periodUnit: DepositPeriodUnit.year,
            periodCount: 1,
            depositDate: DateTime(2026, 5, 1).millisecondsSinceEpoch,
            updateAssetBalance: true,
          );
          await depositService.createDeposit(
            commandId: createCmd,
            draft: draft1,
          );
          // Retry with identical commandId -> idempotent no-op!
          await depositService.createDeposit(
            commandId: createCmd,
            draft: draft1,
          );
          expect((await assetRow(hostId)).balanceMinor, y('7000.00'));
          expect(
            decodeFixedDepositList((await assetRow(hostId)).fixedDepositInfo),
            hasLength(1),
          );

          // Reuse commandId with modified payload -> Conflict!
          await expectLater(
            depositService.createDeposit(
              commandId: createCmd,
              draft: FixedDepositDraft(
                targetAssetId: hostId,
                principal: Money.parse('3000.00'),
                annualRate: percentToAnnualRate('2.0'),
                depositDate: DateTime(2026, 5, 1).millisecondsSinceEpoch,
              ),
            ),
            throwsA(
              isA<Failure>().having(
                (f) => f.code,
                'code',
                FailureCode.conflict,
              ),
            ),
          );

          // Edit running deposit from Mode B1 (+2000) to Mode B2 (memo 3500) -> host returns to 5000!
          await depositService.updateDeposit(
            commandId: cmd(),
            assetId: hostId,
            index: 0,
            draft: FixedDepositDraft(
              targetAssetId: hostId,
              principal: Money.parse('3500.00'),
              annualRate: percentToAnnualRate('2.5'),
              periodUnit: DepositPeriodUnit.year,
              periodCount: 2,
              depositDate: DateTime(2026, 5, 1).millisecondsSinceEpoch,
              updateAssetBalance: false,
            ),
          );
          expect((await assetRow(hostId)).balanceMinor, y('5000.00'));
          final edited = decodeFixedDepositList(
            (await assetRow(hostId)).fixedDepositInfo,
          ).single;
          expect(edited.moneyMinor, y('3500.00'));
          expect(edited.expectedIncomeMinor, y('175.00'));
        },
      );
    },
  );
}
