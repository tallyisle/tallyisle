import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/domain/ledger/effects.dart';
import 'package:tallyisle/domain/ledger/record_extra.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/reconciliation.dart';
import 'package:tallyisle/features/assets/asset_detail_page.dart';

BigInt y(num yuan) => BigInt.from((yuan * 100).round());

void main() {
  const accountA = 1;
  const accountB = 2;

  group('Golden Vectors (reconciliation.md §4)', () {
    test('R01–R09: standard 51-row test suite anchor walk (02zw / 03zj)', () {
      final records = [
        // R01: 最新支出 50.00 元
        ReconRecord(
          id: 'R01',
          type: RecordType.expense,
          moneyMinor: y(50),
          assetId: accountA,
          recordTime: 10009,
        ),
        // R02: 收入 100.00 元
        ReconRecord(
          id: 'R02',
          type: RecordType.income,
          moneyMinor: y(100),
          assetId: accountA,
          recordTime: 10008,
        ),
        // R03: 转账转出 200.00 元
        ReconRecord(
          id: 'R03',
          type: RecordType.transfer,
          moneyMinor: y(200),
          fromAssetId: accountA,
          toAssetId: accountB,
          recordTime: 10007,
        ),
        // R04: 转账手续费 2.00 元
        ReconRecord(
          id: 'R04',
          type: RecordType.fee,
          moneyMinor: y(2),
          assetId: accountA,
          recordTime: 10006,
        ),
        // R05: 平账增加 +30.00 元
        ReconRecord(
          id: 'R05',
          type: RecordType.balanceAdjust,
          moneyMinor: y(30),
          fromAssetId: accountA,
          recordTime: 10005,
        ),
        // R06: 报销入账 80.00 元
        ReconRecord(
          id: 'R06',
          type: RecordType.reimburseReceipt,
          moneyMinor: y(80),
          assetId: accountA,
          recordTime: 10004,
        ),
        // R07: 定存收益 60.00 元
        ReconRecord(
          id: 'R07',
          type: RecordType.depositInterest,
          moneyMinor: y(60),
          assetId: accountA,
          recordTime: 10003,
        ),
        // R08: 信用还款单 500.00 元 (type=11, sub=1)
        ReconRecord(
          id: 'R08',
          type: RecordType.reimburseDiff,
          subType: RecordDirection.income,
          moneyMinor: y(500),
          assetId: accountA,
          recordTime: 10002,
        ),
        // R09: 代付收款 20.00 元 (type=9)
        ReconRecord(
          id: 'R09',
          type: RecordType.advanceIncome,
          moneyMinor: y(20),
          assetId: accountA,
          recordTime: 10001,
        ),
      ];

      final balances = computeReconciliationBalances(
        currentBalance: y(2000),
        accountId: accountA,
        accountCurrency: 'CNY',
        records: records,
      );

      expect(balances['R01'], y(2000), reason: 'R01 after-balance');
      expect(balances['R02'], y(2050), reason: 'R02 after-balance');
      expect(balances['R03'], y(1950), reason: 'R03 after-balance');
      expect(balances['R04'], y(2150), reason: 'R04 after-balance');
      expect(balances['R05'], y(2152), reason: 'R05 after-balance');
      expect(balances['R06'], y(2122), reason: 'R06 after-balance');
      expect(balances['R07'], y(2042), reason: 'R07 after-balance');
      expect(balances['R08'], y(1982), reason: 'R08 after-balance');
      expect(balances['R09'], y(1482), reason: 'R09 after-balance');
    });

    test(
      'credit display formats correctly without double negative (R4, ASYM-REC-07)',
      () {
        expect(creditBalanceLabel(-y(320)), '欠款 320.00');
        expect(creditBalanceLabel(y(50)), '溢存款 50.00');
        expect(creditBalanceLabel(BigInt.zero), '欠款 0.00');
      },
    );

    test(
      'dirty record (ASYM-REC-01b: from/to both other accounts) keeps balance',
      () {
        final dirtyRecord = ReconRecord(
          id: 'dirty-1',
          type: RecordType.transfer,
          moneyMinor: y(100),
          fromAssetId: accountB,
          toAssetId: 99,
          assetId: accountA, // Hit only via asset_id query, neither from nor to
        );

        final balances = computeReconciliationBalances(
          currentBalance: y(1000),
          accountId: accountA,
          records: [dirtyRecord],
        );

        expect(balances['dirty-1'], y(1000));
        expect(
          recordForwardDelta(record: dirtyRecord, accountId: accountA),
          BigInt.zero,
        );
      },
    );

    test('type 11 unknown sub_type keeps balance (ASYM-REC-05)', () {
      final record = ReconRecord(
        id: 'unknown-sub',
        type: RecordType.reimburseDiff,
        subType: 99,
        moneyMinor: y(100),
        assetId: accountA,
      );

      final balances = computeReconciliationBalances(
        currentBalance: y(500),
        accountId: accountA,
        records: [record],
      );

      expect(balances['unknown-sub'], y(500));
      expect(
        recordForwardDelta(record: record, accountId: accountA),
        BigInt.zero,
      );
    });

    test('type 4 negative adjustment (balance decrease)', () {
      final record = ReconRecord(
        id: 'adj-neg',
        type: RecordType.balanceAdjust,
        moneyMinor: -y(30),
        fromAssetId: accountA,
      );

      final balances = computeReconciliationBalances(
        currentBalance: y(100),
        accountId: accountA,
        records: [record],
      );

      // Current balance is 100. Delta was -30. Before adj balance was 130.
      expect(balances['adj-neg'], y(100));
      expect(recordForwardDelta(record: record, accountId: accountA), -y(30));
    });
  });

  group('Currency snapshot amount selection (reconciliation.md R3)', () {
    test('transfer source side prefers sm -> bm -> am', () {
      // sm matches target USD
      final r1 = ReconRecord(
        id: 't1',
        type: RecordType.transfer,
        moneyMinor: y(100),
        fromAssetId: accountA,
        toAssetId: accountB,
        currency: CurrencySnapshot(
          sourceCode: 'USD',
          sourceGross: y(100),
          baseCode: 'CNY',
          baseAmount: y(720),
          assetCode: 'EUR',
          assetNet: y(92),
        ),
      );
      expect(
        selectReconAmount(
          record: r1,
          accountId: accountA,
          accountCurrency: 'USD',
        ),
        y(100),
      );

      // sm does not match, bm matches USD
      final r2 = ReconRecord(
        id: 't2',
        type: RecordType.transfer,
        moneyMinor: y(100),
        fromAssetId: accountA,
        toAssetId: accountB,
        currency: CurrencySnapshot(
          sourceCode: 'GBP',
          sourceGross: y(80),
          baseCode: 'USD',
          baseAmount: y(105),
          assetCode: 'EUR',
          assetNet: y(92),
        ),
      );
      expect(
        selectReconAmount(
          record: r2,
          accountId: accountA,
          accountCurrency: 'USD',
        ),
        y(105),
      );
    });

    test('expense/income prefers am -> bm -> (sm - discount)', () {
      final r1 = ReconRecord(
        id: 'e1',
        type: RecordType.expense,
        moneyMinor: y(100),
        assetId: accountA,
        discountMinor: y(5),
        currency: CurrencySnapshot(
          sourceCode: 'USD',
          sourceGross: y(15),
          baseCode: 'CNY',
          baseAmount: y(100),
          assetCode: 'CNY',
          assetNet: y(95),
        ),
      );
      // ac matches CNY -> am (95)
      expect(
        selectReconAmount(
          record: r1,
          accountId: accountA,
          accountCurrency: 'CNY',
        ),
        y(95),
      );

      // only sc matches USD -> sm - discount
      final r2 = ReconRecord(
        id: 'e2',
        type: RecordType.expense,
        moneyMinor: y(100),
        assetId: accountA,
        discountMinor: y(5),
        currency: CurrencySnapshot(
          sourceCode: 'USD',
          sourceGross: y(50),
          assetCode: 'EUR',
          assetNet: y(45),
        ),
      );
      expect(
        selectReconAmount(
          record: r2,
          accountId: accountA,
          accountCurrency: 'USD',
        ),
        y(45), // 50 - 5
      );
    });
  });

  group('Forward balanceEffects inversion round-trip', () {
    final startBalance = y(1000);

    final testCases = <(String, ReconRecord, EntryFacts)>[
      (
        'type 0: expense',
        ReconRecord(
          id: '0',
          type: RecordType.expense,
          moneyMinor: y(45),
          assetId: accountA,
        ),
        EntryFacts(
          type: RecordType.expense,
          moneyMinor: y(45),
          assetId: accountA,
        ),
      ),
      (
        'type 1: income',
        ReconRecord(
          id: '1',
          type: RecordType.income,
          moneyMinor: y(80),
          assetId: accountA,
        ),
        EntryFacts(
          type: RecordType.income,
          moneyMinor: y(80),
          assetId: accountA,
        ),
      ),
      (
        'type 2: transfer out',
        ReconRecord(
          id: '2-out',
          type: RecordType.transfer,
          moneyMinor: y(120),
          fromAssetId: accountA,
          toAssetId: accountB,
        ),
        EntryFacts(
          type: RecordType.transfer,
          moneyMinor: y(120),
          fromAssetId: accountA,
          toAssetId: accountB,
        ),
      ),
      (
        'type 2: transfer in',
        ReconRecord(
          id: '2-in',
          type: RecordType.transfer,
          moneyMinor: y(120),
          fromAssetId: accountB,
          toAssetId: accountA,
        ),
        EntryFacts(
          type: RecordType.transfer,
          moneyMinor: y(120),
          fromAssetId: accountB,
          toAssetId: accountA,
        ),
      ),
      (
        'type 3: reimbursable (from_asset_id pays)',
        ReconRecord(
          id: '3',
          type: RecordType.reimbursable,
          moneyMinor: y(60),
          fromAssetId: accountA,
        ),
        EntryFacts(
          type: RecordType.reimbursable,
          moneyMinor: y(60),
          fromAssetId: accountA,
        ),
      ),
      (
        'type 4: balance adjust',
        ReconRecord(
          id: '4',
          type: RecordType.balanceAdjust,
          moneyMinor: y(25),
          fromAssetId: accountA,
        ),
        EntryFacts(
          type: RecordType.balanceAdjust,
          moneyMinor: y(25),
          fromAssetId: accountA,
        ),
      ),
      (
        'type 5: borrow in (funding account receives)',
        ReconRecord(
          id: '5',
          type: RecordType.borrowIn,
          moneyMinor: y(300),
          fromAssetId: 99,
          toAssetId: accountA,
        ),
        EntryFacts(
          type: RecordType.borrowIn,
          moneyMinor: y(300),
          fromAssetId: 99,
          toAssetId: accountA,
        ),
      ),
      (
        'type 6: lend out (funding account pays)',
        ReconRecord(
          id: '6',
          type: RecordType.lendOut,
          moneyMinor: y(300),
          fromAssetId: accountA,
          toAssetId: 99,
        ),
        EntryFacts(
          type: RecordType.lendOut,
          moneyMinor: y(300),
          fromAssetId: accountA,
          toAssetId: 99,
        ),
      ),
      (
        'type 7: repay (funding account pays)',
        ReconRecord(
          id: '7',
          type: RecordType.repay,
          moneyMinor: y(150),
          fromAssetId: accountA,
          toAssetId: 99,
        ),
        EntryFacts(
          type: RecordType.repay,
          moneyMinor: y(150),
          fromAssetId: accountA,
          toAssetId: 99,
        ),
      ),
      (
        'type 8: collect (funding account receives)',
        ReconRecord(
          id: '8',
          type: RecordType.collect,
          moneyMinor: y(150),
          fromAssetId: 99,
          toAssetId: accountA,
        ),
        EntryFacts(
          type: RecordType.collect,
          moneyMinor: y(150),
          fromAssetId: 99,
          toAssetId: accountA,
        ),
      ),
      (
        'type 9: advance income (no balance movement)',
        ReconRecord(
          id: '9',
          type: RecordType.advanceIncome,
          moneyMinor: y(100),
          assetId: accountA,
        ),
        EntryFacts(
          type: RecordType.advanceIncome,
          moneyMinor: y(100),
          assetId: accountA,
        ),
      ),
      (
        'type 10: debt interest expense',
        ReconRecord(
          id: '10-exp',
          type: RecordType.debtInterest,
          subType: RecordDirection.expense,
          moneyMinor: y(12),
          fromAssetId: accountA,
        ),
        EntryFacts(
          type: RecordType.debtInterest,
          subType: RecordDirection.expense,
          moneyMinor: y(12),
          fromAssetId: accountA,
        ),
      ),
      (
        'type 10: debt interest income',
        ReconRecord(
          id: '10-inc',
          type: RecordType.debtInterest,
          subType: RecordDirection.income,
          moneyMinor: y(15),
          toAssetId: accountA,
        ),
        EntryFacts(
          type: RecordType.debtInterest,
          subType: RecordDirection.income,
          moneyMinor: y(15),
          toAssetId: accountA,
        ),
      ),
      (
        'type 11: reimburse diff expense',
        ReconRecord(
          id: '11-exp',
          type: RecordType.reimburseDiff,
          subType: RecordDirection.expense,
          moneyMinor: y(8),
          assetId: accountA,
        ),
        EntryFacts(
          type: RecordType.reimburseDiff,
          subType: RecordDirection.expense,
          moneyMinor: y(8),
          assetId: accountA,
        ),
      ),
      (
        'type 11: reimburse diff income',
        ReconRecord(
          id: '11-inc',
          type: RecordType.reimburseDiff,
          subType: RecordDirection.income,
          moneyMinor: y(18),
          assetId: accountA,
        ),
        EntryFacts(
          type: RecordType.reimburseDiff,
          subType: RecordDirection.income,
          moneyMinor: y(18),
          assetId: accountA,
        ),
      ),
      (
        'type 12: fee',
        ReconRecord(
          id: '12',
          type: RecordType.fee,
          moneyMinor: y(3),
          assetId: accountA,
        ),
        EntryFacts(type: RecordType.fee, moneyMinor: y(3), assetId: accountA),
      ),
      (
        'type 14: installment principal',
        ReconRecord(
          id: '14',
          type: RecordType.installmentPrincipal,
          moneyMinor: y(88),
          assetId: accountA,
        ),
        EntryFacts(
          type: RecordType.installmentPrincipal,
          moneyMinor: y(88),
          assetId: accountA,
        ),
      ),
      (
        'type 15: reimburse receipt',
        ReconRecord(
          id: '15',
          type: RecordType.reimburseReceipt,
          moneyMinor: y(70),
          assetId: accountA,
        ),
        EntryFacts(
          type: RecordType.reimburseReceipt,
          moneyMinor: y(70),
          assetId: accountA,
        ),
      ),
      (
        'type 16: advance expense (no balance movement)',
        ReconRecord(
          id: '16',
          type: RecordType.advanceExpense,
          moneyMinor: y(50),
          assetId: accountA,
        ),
        EntryFacts(
          type: RecordType.advanceExpense,
          moneyMinor: y(50),
          assetId: accountA,
        ),
      ),
      (
        'type 17: deposit interest',
        ReconRecord(
          id: '17',
          type: RecordType.depositInterest,
          moneyMinor: y(42),
          assetId: accountA,
        ),
        EntryFacts(
          type: RecordType.depositInterest,
          moneyMinor: y(42),
          assetId: accountA,
        ),
      ),
    ];

    for (final (name, reconRecord, entryFacts) in testCases) {
      test(name, () {
        // Compute forward delta using the app's balanceEffects
        final deltas = balanceEffects(entryFacts);
        final forwardDelta = deltas
            .where((d) => d.assetId == accountA)
            .fold(BigInt.zero, (sum, d) => sum + d.minor);

        final endBalance = startBalance + forwardDelta;

        // Verify recordForwardDelta matches
        final ruleDelta = recordForwardDelta(
          record: reconRecord,
          accountId: accountA,
        );
        expect(ruleDelta, forwardDelta, reason: '$name delta mismatch');

        // Verify reverse walk recovers starting balance
        final balances = computeReconciliationBalances(
          currentBalance: endBalance,
          accountId: accountA,
          records: [reconRecord],
        );

        expect(balances[reconRecord.id], endBalance);
        final recoveredStart = endBalance - ruleDelta;
        expect(
          recoveredStart,
          startBalance,
          reason: '$name recovered start mismatch',
        );
      });
    }
  });

  group('Month grouping and inflow/outflow', () {
    test(
      'groups records by natural month and aggregates inflow and outflow',
      () {
        final records = [
          // 2026-03-15: expense 50
          ReconRecord(
            id: '1',
            type: RecordType.expense,
            moneyMinor: y(50),
            assetId: accountA,
            recordTime: DateTime(2026, 3, 15, 10).millisecondsSinceEpoch,
          ),
          // 2026-03-10: income 200
          ReconRecord(
            id: '2',
            type: RecordType.income,
            moneyMinor: y(200),
            assetId: accountA,
            recordTime: DateTime(2026, 3, 10, 10).millisecondsSinceEpoch,
          ),
          // 2026-02-20: expense 30
          ReconRecord(
            id: '3',
            type: RecordType.expense,
            moneyMinor: y(30),
            assetId: accountA,
            recordTime: DateTime(2026, 2, 20, 10).millisecondsSinceEpoch,
          ),
        ];

        final groups = groupRecordsByMonth(
          records: records,
          getRecordTime: (r) => r.recordTime,
          getDelta: (r) => recordForwardDelta(record: r, accountId: accountA),
        );

        expect(groups.length, 2);
        expect(groups[0].year, 2026);
        expect(groups[0].month, 3);
        expect(groups[0].items.length, 2);
        expect(groups[0].inflow, y(200));
        expect(groups[0].outflow, y(50));

        expect(groups[1].year, 2026);
        expect(groups[1].month, 2);
        expect(groups[1].items.length, 1);
        expect(groups[1].inflow, BigInt.zero);
        expect(groups[1].outflow, y(30));
      },
    );
  });

  group('NaturalMonthPeriod & Fund Monthly Statements', () {
    test(
      'NaturalMonthPeriod bounds, leap years, contains, and year crossings',
      () {
        const feb2024 = NaturalMonthPeriod(year: 2024, month: 2);
        expect(feb2024.start, DateTime(2024, 2, 1, 0, 0, 0, 0));
        expect(feb2024.end, DateTime(2024, 2, 29, 23, 59, 59, 999));
        expect(feb2024.contains(feb2024.startMs), isTrue);
        expect(feb2024.contains(feb2024.endMs), isTrue);
        expect(feb2024.contains(feb2024.startMs - 1), isFalse);
        expect(feb2024.contains(feb2024.endMs + 1), isFalse);

        const feb2026 = NaturalMonthPeriod(year: 2026, month: 2);
        expect(feb2026.end, DateTime(2026, 2, 28, 23, 59, 59, 999));

        const jan2026 = NaturalMonthPeriod(year: 2026, month: 1);
        expect(
          jan2026.previous(),
          const NaturalMonthPeriod(year: 2025, month: 12),
        );
        expect(jan2026.next(), const NaturalMonthPeriod(year: 2026, month: 2));

        const dec2026 = NaturalMonthPeriod(year: 2026, month: 12);
        expect(dec2026.next(), const NaturalMonthPeriod(year: 2027, month: 1));
        expect(
          dec2026.previous(),
          const NaturalMonthPeriod(year: 2026, month: 11),
        );
      },
    );

    test(
      'calculateFundMonthlyStatements walks backward across years, carries forward empty past months, and nulls unstarted future empty months',
      () {
        final today = DateTime(2026, 4, 20);
        // Sorted newest-first:
        // 2026-04-10: expense 50 (-50)
        // 2026-02-15: income 200 (+200)
        // 2025-11-10: income 300 (+300)
        final records = [
          ReconRecord(
            id: 'r-2026-04',
            type: RecordType.expense,
            moneyMinor: y(50),
            assetId: accountA,
            recordTime: DateTime(2026, 4, 10, 12).millisecondsSinceEpoch,
          ),
          ReconRecord(
            id: 'r-2026-02',
            type: RecordType.income,
            moneyMinor: y(200),
            assetId: accountA,
            recordTime: DateTime(2026, 2, 15, 12).millisecondsSinceEpoch,
          ),
          ReconRecord(
            id: 'r-2025-11',
            type: RecordType.income,
            moneyMinor: y(300),
            assetId: accountA,
            recordTime: DateTime(2025, 11, 10, 12).millisecondsSinceEpoch,
          ),
        ];

        final stmts2026 = calculateFundMonthlyStatements(
          currentBalance: y(1000),
          accountId: accountA,
          accountCurrency: 'CNY',
          records: records,
          selectedYear: 2026,
          today: today,
        );
        expect(stmts2026.length, 12);
        expect(stmts2026.map((s) => s.period.month).toList(), [
          12,
          11,
          10,
          9,
          8,
          7,
          6,
          5,
          4,
          3,
          2,
          1,
        ]);

        FundMonthlyStatementItem monthOf(
          List<FundMonthlyStatementItem> list,
          int m,
        ) => list.firstWhere((s) => s.period.month == m);

        // Future unstarted months (5..12) have null endingBalance.
        for (var m = 5; m <= 12; m++) {
          final item = monthOf(stmts2026, m);
          expect(item.isFutureUnstarted, isTrue);
          expect(item.isCurrentMonth, isFalse);
          expect(item.recordCount, 0);
          expect(item.endingBalance, isNull);
        }

        // Current month (4): inflow 0, outflow 50, net -50, endingBalance 1000.
        final m4 = monthOf(stmts2026, 4);
        expect(m4.isCurrentMonth, isTrue);
        expect(m4.isFutureUnstarted, isFalse);
        expect(m4.recordCount, 1);
        expect(m4.inflow, BigInt.zero);
        expect(m4.outflow, y(50));
        expect(m4.netDelta, -y(50));
        expect(m4.endingBalance, y(1000));

        // Empty past month (3): carries forward 1050.
        final m3 = monthOf(stmts2026, 3);
        expect(m3.recordCount, 0);
        expect(m3.endingBalance, y(1050));

        // Month 2: inflow 200, endingBalance 1050.
        final m2 = monthOf(stmts2026, 2);
        expect(m2.recordCount, 1);
        expect(m2.inflow, y(200));
        expect(m2.netDelta, y(200));
        expect(m2.endingBalance, y(1050));

        // Month 1: empty past month before Feb +200 -> 850.
        final m1 = monthOf(stmts2026, 1);
        expect(m1.recordCount, 0);
        expect(m1.endingBalance, y(850));

        // Previous year (2025): rolls back 2026 records (-50 + 200 = +150) -> Dec 2025 end = 850!
        final stmts2025 = calculateFundMonthlyStatements(
          currentBalance: y(1000),
          accountId: accountA,
          accountCurrency: 'CNY',
          records: records,
          selectedYear: 2025,
          today: today,
        );
        expect(monthOf(stmts2025, 12).endingBalance, y(850));
        expect(monthOf(stmts2025, 11).endingBalance, y(850));
        expect(monthOf(stmts2025, 11).inflow, y(300));
        expect(monthOf(stmts2025, 10).endingBalance, y(550));
        expect(monthOf(stmts2025, 1).endingBalance, y(550));
      },
    );

    test(
      'calculateFundMonthlyStatements handles pre-recorded future bills & multi-currency snapshots',
      () {
        final today = DateTime(2026, 4, 20);
        final records = [
          // Future pre-recorded USD transfer source (uses sm = 100 USD)
          ReconRecord(
            id: 'future-usd',
            type: RecordType.transfer,
            moneyMinor: y(720),
            fromAssetId: accountA,
            toAssetId: accountB,
            recordTime: DateTime(2026, 8, 5, 10).millisecondsSinceEpoch,
            currency: CurrencySnapshot(
              sourceCode: 'USD',
              sourceGross: y(100),
              baseCode: 'CNY',
              baseAmount: y(720),
              assetCode: 'CNY',
              assetNet: y(720),
            ),
          ),
          // Current-month expense in USD (uses am = 25 USD)
          ReconRecord(
            id: 'curr-usd',
            type: RecordType.expense,
            moneyMinor: y(180),
            assetId: accountA,
            recordTime: DateTime(2026, 4, 10, 10).millisecondsSinceEpoch,
            currency: CurrencySnapshot(
              sourceCode: 'EUR',
              sourceGross: y(23),
              baseCode: 'CNY',
              baseAmount: y(180),
              assetCode: 'USD',
              assetNet: y(25),
            ),
          ),
        ];

        final stmts = calculateFundMonthlyStatements(
          currentBalance: y(500),
          accountId: accountA,
          accountCurrency: 'USD',
          records: records,
          selectedYear: 2026,
          today: today,
        );

        FundMonthlyStatementItem m(int month) =>
            stmts.firstWhere((s) => s.period.month == month);

        // Months 9..12 have no records in or after them -> null.
        expect(m(12).endingBalance, isNull);
        expect(m(9).endingBalance, isNull);
        // Month 8 has future-usd (-100) -> endingBalance 500.
        expect(m(8).recordCount, 1);
        expect(m(8).outflow, y(100));
        expect(m(8).endingBalance, y(500));
        // Months 5..7 are empty future months BEFORE Month 8's future record -> carry forward 600!
        expect(m(7).endingBalance, y(600));
        expect(m(5).endingBalance, y(600));
        // Month 4 has curr-usd (-25) -> endingBalance 600, Month 3 endingBalance 625.
        expect(m(4).outflow, y(25));
        expect(m(4).endingBalance, y(600));
        expect(m(3).endingBalance, y(625));
      },
    );

    test(
      'filterVisibleFundMonthlyStatements always keeps current month even at 0 records and folds other empty months',
      () {
        final today = DateTime(2026, 4, 20);
        // Zero records in current year 2026:
        final emptyYearStmts = calculateFundMonthlyStatements(
          currentBalance: y(1000),
          accountId: accountA,
          records: const [],
          selectedYear: 2026,
          today: today,
        );

        final folded = filterVisibleFundMonthlyStatements(
          statements: emptyYearStmts,
          today: today,
        );
        expect(folded.hiddenEmptyCount, 11);
        expect(folded.visible.length, 1);
        expect(
          folded.visible.first.period,
          const NaturalMonthPeriod(year: 2026, month: 4),
        );
        expect(folded.visible.first.isCurrentMonth, isTrue);

        final expanded = filterVisibleFundMonthlyStatements(
          statements: emptyYearStmts,
          today: today,
          includeEmpty: true,
        );
        expect(expanded.hiddenEmptyCount, 11);
        expect(expanded.visible.length, 12);

        // Past year 2025 with zero records -> visible empty, hiddenEmptyCount = 12.
        final pastEmptyStmts = calculateFundMonthlyStatements(
          currentBalance: y(1000),
          accountId: accountA,
          records: const [],
          selectedYear: 2025,
          today: today,
        );
        final pastFolded = filterVisibleFundMonthlyStatements(
          statements: pastEmptyStmts,
          today: today,
        );
        expect(pastFolded.visible, isEmpty);
        expect(pastFolded.hiddenEmptyCount, 12);
      },
    );
  });
}
