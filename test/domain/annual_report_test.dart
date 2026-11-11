import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/domain/ledger/record_extra.dart';
import 'package:tallyisle/domain/ledger/record_relations.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/annual_report.dart';

void main() {
  group('Annual Report Domain Rules', () {
    test(
      'VEC-AR-01: empty ledger returns clean zero values and 12 empty months',
      () {
        final res = computeAnnualReport(
          year: 2026,
          startDay: 1,
          records: const [],
        );

        expect(res.year, 2026);
        expect(res.startDay, 1);
        expect(res.totalIncome, BigInt.zero);
        expect(res.totalExpense, BigInt.zero);
        expect(res.totalBalance, BigInt.zero);
        expect(res.totalBillCount, 0);
        expect(res.activeDays, 0);
        expect(res.savingsRate, 0.0);
        expect(res.averageMonthIncome, BigInt.zero);
        expect(res.averageMonthExpense, BigInt.zero);
        expect(res.averageMonthSurplus, BigInt.zero);

        expect(res.monthlySummaries.length, 12);
        for (var i = 0; i < 12; i++) {
          final m = res.monthlySummaries[i];
          expect(m.month, i + 1);
          expect(m.income, BigInt.zero);
          expect(m.expense, BigInt.zero);
          expect(m.balance, BigInt.zero);
          expect(m.billCount, 0);
        }

        expect(res.topExpenseCategories, isEmpty);
        expect(res.topIncomeCategories, isEmpty);
        expect(res.maxExpenseRecord, isNull);
        expect(res.maxIncomeRecord, isNull);
        expect(res.maxExpenseMonth, isNull);
        expect(res.maxIncomeMonth, isNull);
        expect(res.maxBillDayDate, isNull);
        expect(res.maxBillDayCount, 0);
        expect(res.mostUsedAsset, isNull);
        expect(res.totalDiscount, BigInt.zero);
      },
    );

    test('VEC-AR-02: standard 12-month income/expense pattern', () {
      final records = <AnnualRecordItem>[];

      // Odd months: 1 expense of 100.00 CNY (10000 minor) on the 5th
      for (var m = 1; m <= 11; m += 2) {
        records.add(
          AnnualRecordItem(
            id: 'exp-$m',
            type: RecordType.expense,
            moneyMinor: BigInt.from(10000),
            recordTime: DateTime(2026, m, 5, 12, 0).millisecondsSinceEpoch,
            categoryId: 1,
            categoryName: '餐饮',
            assetName: '微信零钱',
          ),
        );
      }

      // Even months: 1 income of 200.00 CNY (20000 minor) on the 10th
      for (var m = 2; m <= 12; m += 2) {
        records.add(
          AnnualRecordItem(
            id: 'inc-$m',
            type: RecordType.income,
            moneyMinor: BigInt.from(20000),
            recordTime: DateTime(2026, m, 10, 12, 0).millisecondsSinceEpoch,
            categoryId: 2,
            categoryName: '工资',
            assetName: '招商银行',
          ),
        );
      }

      final res = computeAnnualReport(
        year: 2026,
        startDay: 1,
        records: records,
      );

      // 6 expenses of 100.00 = 600.00 (60000)
      expect(res.totalExpense, BigInt.from(60000));
      expect(res.totalExpenseCount, 6);

      // 6 incomes of 200.00 = 1200.00 (120000)
      expect(res.totalIncome, BigInt.from(120000));
      expect(res.totalIncomeCount, 6);

      // Balance = 120000 - 60000 = 60000
      expect(res.totalBalance, BigInt.from(60000));
      expect(res.totalBillCount, 12);
      expect(res.activeDays, 12);

      // Monthly averages
      expect(res.averageMonthExpense, BigInt.from(5000)); // 60000 ~/ 12
      expect(res.averageMonthIncome, BigInt.from(10000)); // 120000 ~/ 12
      expect(res.averageMonthSurplus, BigInt.from(5000));

      // Savings rate = 60000 / 120000 = 0.5 (50%)
      expect(res.savingsRate, closeTo(0.5, 0.0001));

      // 12 monthly buckets check
      expect(res.monthlySummaries.length, 12);
      for (var m = 1; m <= 12; m++) {
        final item = res.monthlySummaries[m - 1];
        expect(item.month, m);
        if (m.isOdd) {
          expect(item.expense, BigInt.from(10000));
          expect(item.income, BigInt.zero);
          expect(item.balance, BigInt.from(-10000));
        } else {
          expect(item.expense, BigInt.zero);
          expect(item.income, BigInt.from(20000));
          expect(item.balance, BigInt.from(20000));
        }
      }
    });

    test('VEC-AR-03: custom startDay = 15 cross-year boundary attribution', () {
      final records = [
        // 2026-01-10: before Jan 15 -> belongs to 2025 period month 12
        AnnualRecordItem(
          id: 'early-jan',
          type: RecordType.expense,
          moneyMinor: BigInt.from(5000), // 50.00 CNY
          recordTime: DateTime(2026, 1, 10, 10, 0).millisecondsSinceEpoch,
          categoryName: '早点',
        ),
        // 2026-01-20: on or after Jan 15 -> belongs to 2026 period month 1
        AnnualRecordItem(
          id: 'late-jan',
          type: RecordType.expense,
          moneyMinor: BigInt.from(8000), // 80.00 CNY
          recordTime: DateTime(2026, 1, 20, 10, 0).millisecondsSinceEpoch,
          categoryName: '午餐',
        ),
        // 2027-01-10: belongs to 2026 period month 12
        AnnualRecordItem(
          id: 'next-year-jan',
          type: RecordType.expense,
          moneyMinor: BigInt.from(7000), // 70.00 CNY
          recordTime: DateTime(2027, 1, 10, 10, 0).millisecondsSinceEpoch,
          categoryName: '晚餐',
        ),
      ];

      final res = computeAnnualReport(
        year: 2026,
        startDay: 15,
        records: records,
      );

      // early-jan (50.00) is in 2025 period, so not in 2026 annual report
      // late-jan (80.00) is in month 1
      // next-year-jan (70.00) is in month 12
      expect(res.totalExpense, BigInt.from(15000)); // 8000 + 7000
      expect(res.monthlySummaries[0].month, 1);
      expect(res.monthlySummaries[0].expense, BigInt.from(8000));
      expect(res.monthlySummaries[11].month, 12);
      expect(res.monthlySummaries[11].expense, BigInt.from(7000));
    });

    test('VEC-AR-04: refund deduction, reimbursement, and exclusions', () {
      final relationsWithRefund = RecordRelations()
        ..refunds = BillLinks(
          children: [
            LinkedBill(
              billId: 'ref-1',
              amount: BigInt.from(10000),
              assetAmount: BigInt.from(10000),
            ),
          ],
        );

      final childRelations = RecordRelations()
        ..refunds = const BillLinks(originId: 'main-exp', children: []);

      final records = [
        // 500.00 CNY expense with 100.00 refund link
        AnnualRecordItem(
          id: 'main-exp',
          type: RecordType.expense,
          moneyMinor: BigInt.from(50000),
          recordTime: DateTime(2026, 3, 1).millisecondsSinceEpoch,
          relations: relationsWithRefund,
          categoryId: 10,
          categoryName: '数码',
        ),
        // The negative refund child bill (originId set) - should not duplicate deduction
        AnnualRecordItem(
          id: 'ref-1',
          type: RecordType.expense,
          moneyMinor: BigInt.from(-10000),
          recordTime: DateTime(2026, 3, 2).millisecondsSinceEpoch,
          relations: childRelations,
        ),
        // Excluded from income/expense
        AnnualRecordItem(
          id: 'excluded-exp',
          type: RecordType.expense,
          moneyMinor: BigInt.from(30000),
          excludeExIn: true,
          recordTime: DateTime(2026, 3, 5).millisecondsSinceEpoch,
        ),
        // Type 15: reimburse receipt (excluded from expense/income)
        AnnualRecordItem(
          id: 'receipt-15',
          type: RecordType.reimburseReceipt,
          moneyMinor: BigInt.from(20000),
          recordTime: DateTime(2026, 3, 10).millisecondsSinceEpoch,
        ),
      ];

      final res = computeAnnualReport(
        year: 2026,
        startDay: 1,
        records: records,
      );

      // Only main-exp nets 400.00 CNY (40000 minor)
      expect(res.totalExpense, BigInt.from(40000));
      expect(res.totalExpenseCount, 1);
      expect(res.totalIncome, BigInt.zero);

      // Category check
      expect(res.topExpenseCategories.length, 1);
      expect(res.topExpenseCategories.first.categoryName, '数码');
      expect(res.topExpenseCategories.first.amount, BigInt.from(40000));
      expect(res.topExpenseCategories.first.ratio, 1.0);
    });

    test(
      'VEC-AR-05: max single record, peak months, most used asset, and discounts',
      () {
        final records = [
          // Month 5: single large expense 1000.00 CNY
          AnnualRecordItem(
            id: 'big-may',
            type: RecordType.expense,
            moneyMinor: BigInt.from(100000),
            recordTime: DateTime(2026, 5, 20, 10, 0).millisecondsSinceEpoch,
            categoryId: 100,
            categoryName: '旅行',
            assetName: '信用卡',
            discountMinor: BigInt.from(5000), // 50.00 CNY discount
          ),
          // Month 3: three expenses of 400.00 CNY (total 1200.00 CNY)
          AnnualRecordItem(
            id: 'mar-1',
            type: RecordType.expense,
            moneyMinor: BigInt.from(40000),
            recordTime: DateTime(2026, 3, 1, 10, 0).millisecondsSinceEpoch,
            categoryName: '数码',
            assetName: '微信支付',
          ),
          AnnualRecordItem(
            id: 'mar-2',
            type: RecordType.expense,
            moneyMinor: BigInt.from(40000),
            recordTime: DateTime(2026, 3, 1, 14, 0).millisecondsSinceEpoch,
            categoryName: '数码',
            assetName: '微信支付',
          ),
          AnnualRecordItem(
            id: 'mar-3',
            type: RecordType.expense,
            moneyMinor: BigInt.from(40000),
            recordTime: DateTime(2026, 3, 1, 18, 0).millisecondsSinceEpoch,
            categoryName: '数码',
            assetName: '微信支付',
          ),
          // Month 8: income 8000.00 CNY
          AnnualRecordItem(
            id: 'aug-inc',
            type: RecordType.income,
            moneyMinor: BigInt.from(800000),
            recordTime: DateTime(2026, 8, 15, 10, 0).millisecondsSinceEpoch,
            categoryName: '年终奖',
            assetName: '工商银行',
          ),
        ];

        final res = computeAnnualReport(
          year: 2026,
          startDay: 1,
          records: records,
        );

        // Peak single records
        expect(res.maxExpenseRecord?.id, 'big-may');
        expect(res.maxExpenseRecord?.amount, BigInt.from(100000));
        expect(res.maxExpenseRecord?.categoryName, '旅行');

        expect(res.maxIncomeRecord?.id, 'aug-inc');
        expect(res.maxIncomeRecord?.amount, BigInt.from(800000));
        expect(res.maxIncomeRecord?.categoryName, '年终奖');

        // Peak months: Month 3 expense is 120000, Month 5 is 100000
        expect(res.maxExpenseMonth, 3);
        expect(res.maxExpenseMonthAmount, BigInt.from(120000));

        expect(res.maxIncomeMonth, 8);
        expect(res.maxIncomeMonthAmount, BigInt.from(800000));

        // Peak day: 2026-03-01 has 3 bills
        expect(res.maxBillDayDate, '2026-03-01');
        expect(res.maxBillDayCount, 3);

        // Most used asset: 微信支付 has 3 bills out of 5 total effective bills
        expect(res.mostUsedAsset?.assetName, '微信支付');
        expect(res.mostUsedAsset?.count, 3);
        expect(res.mostUsedAsset?.ratio, closeTo(3 / 5, 0.001));

        // Total discount
        expect(res.totalDiscount, BigInt.from(5000));
      },
    );

    test('Multi-currency conversion using CurrencySnapshot', () {
      final records = [
        // USD expense: source 100 USD, base amount 700 CNY (70000 minor)
        AnnualRecordItem(
          id: 'usd-1',
          type: RecordType.expense,
          moneyMinor: BigInt.from(10000),
          currency: CurrencySnapshot(
            sourceCode: 'USD',
            sourceGross: BigInt.from(10000),
            baseCode: 'CNY',
            baseAmount: BigInt.from(70000),
          ),
          recordTime: DateTime(2026, 6, 1).millisecondsSinceEpoch,
          categoryName: '海淘',
        ),
      ];

      final res = computeAnnualReport(
        year: 2026,
        startDay: 1,
        records: records,
        baseCurrency: 'CNY',
      );

      expect(res.totalExpense, BigInt.from(70000));
      expect(res.monthlySummaries[5].expense, BigInt.from(70000));
    });
  });
}
