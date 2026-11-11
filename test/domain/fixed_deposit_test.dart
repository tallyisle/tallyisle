import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/asset_overview.dart';
import 'package:tallyisle/domain/rules/fixed_deposit.dart';

BigInt y(String amount) => Money.parse(amount).storageMinor;

/// Golden vectors: `docs/modules/fixed-deposit.md` §4 (`02zz` + `03zl` FD-F01..04, ASYM-FD-01..08).
void main() {
  group('R2 & FD-F01: mul6 single-interest golden vectors', () {
    test(
      'FD-1: 3333.33 @ 3.3335% for 3 years -> 333.349668 (6 decimals) -> 333.35',
      () {
        final principal = Money.parse('3333.33');
        final rate = percentToAnnualRate('3.3335'); // 0.033335
        expect(formatDecimalValue(rate), '0.033335');

        final exact6 = calculateExpectedIncome(
          principal: principal,
          annualRate: rate,
          periodUnit: DepositPeriodUnit.year,
          periodCount: 3,
        );
        expect(exact6.scale, 6);
        expect(formatDecimalValue(exact6), '333.349668');
        expect(expectedIncomeToMinor(exact6), BigInt.from(33335));
        expect(Money.minor(expectedIncomeToMinor(exact6)).decimal, '333.35');
      },
    );

    test('FD-2: 10000.00 @ 2.4% for 6 months -> 120.00', () {
      final principal = Money.parse('10000.00');
      final rate = percentToAnnualRate('2.4'); // 0.024
      final income = calculateExpectedIncome(
        principal: principal,
        annualRate: rate,
        periodUnit: DepositPeriodUnit.month,
        periodCount: 6,
      );
      expect(formatDecimalValue(income), '120.00');
      expect(expectedIncomeToMinor(income), BigInt.from(12000));
    });

    test(
      'FD-3: 100000.00 @ 0.00000049 for 12 months -> 0.00 (operand 6-decimal rounding)',
      () {
        final principal = Money.parse('100000.00');
        final rate = DecimalValue.parse('0.00000049');
        final income = calculateExpectedIncome(
          principal: principal,
          annualRate: rate,
          periodUnit: DepositPeriodUnit.month,
          periodCount: 12,
        );
        expect(formatDecimalValue(income), '0.00');
        expect(expectedIncomeToMinor(income), BigInt.zero);
      },
    );

    test('FD-JAVA-04: 1000.33 @ 1.755% for 7 months -> 10.24', () {
      final income = calculateExpectedIncome(
        principal: Money.parse('1000.33'),
        annualRate: percentToAnnualRate('1.755'),
        periodUnit: DepositPeriodUnit.month,
        periodCount: 7,
      );
      expect(formatDecimalValue(income), '10.24');
      expect(expectedIncomeToMinor(income), BigInt.from(1024));
    });

    test(
      'FD-F01 entity signed domain: -100.00 @ 3% for 1 year -> -3.000000',
      () {
        final income = calculateExpectedIncome(
          principal: Money.parse('-100.00'),
          annualRate: DecimalValue.parse('0.03'),
          periodUnit: DepositPeriodUnit.year,
          periodCount: 1,
        );
        expect(formatDecimalValue(income), '-3.000000');
        expect(expectedIncomeToMinor(income), BigInt.from(-300));
      },
    );
  });

  group('R2: Calendar due date calculation & clamping', () {
    test('Jan 31 + 1 month clamps to Feb 28 (non-leap) and Feb 29 (leap)', () {
      final nonLeap = DateTime(2026, 1, 31, 14, 35, 20, 456);
      final dueNonLeap = DateTime.fromMillisecondsSinceEpoch(
        calculateDueDate(
          depositDateMs: nonLeap.millisecondsSinceEpoch,
          periodUnit: DepositPeriodUnit.month,
          periodCount: 1,
        ),
      );
      expect(dueNonLeap, DateTime(2026, 2, 28, 14, 35, 20, 456));

      final leap = DateTime(2024, 1, 31, 9, 15, 0, 0);
      final dueLeap = DateTime.fromMillisecondsSinceEpoch(
        calculateDueDate(
          depositDateMs: leap.millisecondsSinceEpoch,
          periodUnit: DepositPeriodUnit.month,
          periodCount: 1,
        ),
      );
      expect(dueLeap, DateTime(2024, 2, 29, 9, 15, 0, 0));
    });

    test('Leap day 2024-02-29 + 1 year clamps to 2025-02-28', () {
      final start = DateTime(2024, 2, 29, 8, 0, 0, 0);
      final due1Yr = DateTime.fromMillisecondsSinceEpoch(
        calculateDueDate(
          depositDateMs: start.millisecondsSinceEpoch,
          periodUnit: DepositPeriodUnit.year,
          periodCount: 1,
        ),
      );
      expect(due1Yr, DateTime(2025, 2, 28, 8, 0, 0, 0));

      final due4Yr = DateTime.fromMillisecondsSinceEpoch(
        calculateDueDate(
          depositDateMs: start.millisecondsSinceEpoch,
          periodUnit: DepositPeriodUnit.year,
          periodCount: 4,
        ),
      );
      expect(due4Yr, DateTime(2028, 2, 29, 8, 0, 0, 0));
    });

    test('periodCount <= 0 clamps due date to +1 period while income is 0', () {
      final start = DateTime(2026, 3, 15, 10, 0);
      final due = DateTime.fromMillisecondsSinceEpoch(
        calculateDueDate(
          depositDateMs: start.millisecondsSinceEpoch,
          periodUnit: DepositPeriodUnit.month,
          periodCount: 0,
        ),
      );
      expect(due, DateTime(2026, 4, 15, 10, 0));
      expect(
        calculateExpectedIncomeMinor(
          principal: Money.parse('5000.00'),
          annualRate: DecimalValue.parse('0.03'),
          periodUnit: DepositPeriodUnit.month,
          periodCount: 0,
        ),
        BigInt.zero,
      );
    });
  });

  group('R3 & FD-F02: Mode A cross-currency transfer plan', () {
    final rates = RateTable({'CNY': '1', 'USD': '0.13'});

    test(
      'FD-F02 golden vector: 100 USD deposit from CNY -> USD @ 0.13 => 769.23 CNY',
      () {
        final plan = buildModeATransferPlan(
          principalMinor: y('100.00'),
          depositCurrency: 'USD',
          fromAssetCurrency: 'CNY',
          targetAssetCurrency: 'USD',
          rates: rates,
        );
        expect(plan.sourceCurrency, 'CNY');
        expect(plan.sourceMoneyMinor, BigInt.from(76923)); // 769.23 CNY
        expect(plan.targetCurrency, 'USD');
        expect(plan.targetMoneyMinor, BigInt.from(10000)); // 100.00 USD
        expect(plan.baseMoneyMinor, BigInt.from(76923));
        expect(plan.snapshot, isNotNull);
        expect(plan.snapshot!.sourceCode, 'CNY');
        expect(plan.snapshot!.sourceGross, BigInt.from(76923));
        expect(plan.snapshot!.assetCode, 'USD');
        expect(plan.snapshot!.assetNet, BigInt.from(10000));
        expect(plan.snapshot!.baseCode, 'CNY');
        expect(plan.snapshot!.baseAmount, BigInt.from(76923));
      },
    );

    test(
      'FD-F02 empty currency fallback: empty c falls back to target CNY, source USD = 13.00',
      () {
        final plan = buildModeATransferPlan(
          principalMinor: y('100.00'),
          depositCurrency: '',
          fromAssetCurrency: 'USD',
          targetAssetCurrency: 'CNY',
          rates: rates,
        );
        expect(plan.depositCurrency, 'CNY');
        expect(plan.sourceCurrency, 'USD');
        expect(plan.sourceMoneyMinor, BigInt.from(1300)); // 13.00 USD
        expect(plan.targetCurrency, 'CNY');
        expect(plan.targetMoneyMinor, BigInt.from(10000)); // 100.00 CNY
      },
    );

    test('Missing or zero foreign rate throws validation Failure', () {
      final brokenRates = RateTable({'CNY': '1', 'GBP': '0'});
      expect(
        () => buildModeATransferPlan(
          principalMinor: y('100.00'),
          depositCurrency: 'GBP',
          fromAssetCurrency: 'CNY',
          targetAssetCurrency: 'GBP',
          rates: brokenRates,
        ),
        throwsA(
          isA<Failure>().having((f) => f.code, 'code', FailureCode.validation),
        ),
      );
    });
  });

  group('R5, FD-4 & ASYM-FD-05: Header summary golden vectors', () {
    test(
      'FD-4: two 0.01 USD expected incomes @ 0.13 -> per-item HALF_UP 0.08 + 0.08 = 0.16 CNY',
      () {
        final rates = RateTable({'CNY': '1', 'USD': '0.13'});
        FixedDepositItem oneCentUsd(int due) => FixedDepositItem(
          moneyMinor: y('10.00'),
          annualRate: DecimalValue.parse('0.001'),
          depositDate: 1000,
          dueDate: due,
          expectedIncomeMinor: BigInt.one, // 0.01 USD
          currency: 'USD',
          assetCurrency: 'USD',
          status: FixedDepositStatus.running,
        );

        final header = computeDepositHeaderSummary([
          oneCentUsd(2000),
          oneCentUsd(3000),
        ], rates);
        expect(
          header.pendingIncomeMinor,
          BigInt.from(16),
        ); // 0.16 CNY, NOT 0.15!
      },
    );

    test(
      'Standard 7-deposit fixture header before & after settlement (02zz / 03zl + ASYM-FD-05)',
      () {
        // Rates per 02zz §6: CNY=1, USD=0.125 (1 USD = 8.00 CNY), JPY=20, GBP=0 (invalid)
        final rates = RateTable({
          'CNY': '1',
          'USD': '0.125',
          'JPY': '20',
          'GBP': '0',
        });

        // Active eligible deposits (hidden account 705#0 excluded by status == 0):
        final fd701_0 = FixedDepositItem(
          moneyMinor: y('5000.00'),
          annualRate: DecimalValue.parse('0.03'),
          periodUnit: DepositPeriodUnit.year,
          periodCount: 1,
          depositDate: DateTime(2025, 1, 1).millisecondsSinceEpoch,
          dueDate: DateTime(2026, 1, 1).millisecondsSinceEpoch,
          expectedIncomeMinor: y('150.00'),
          currency: 'CNY',
          assetCurrency: 'CNY',
          assetMoneyMinor: y('5000.00'),
          baseCurrency: 'CNY',
          baseMoneyMinor: y('5000.00'),
          incomeRecordId: 'rec_fd_701_0_inc',
          status: FixedDepositStatus.settled,
        );
        final fd701_1 = FixedDepositItem(
          moneyMinor: y('10000.00'),
          fromAssetId: 702,
          annualRate: DecimalValue.parse('0.024'),
          periodUnit: DepositPeriodUnit.month,
          periodCount: 3,
          depositDate: DateTime(2026, 2, 15).millisecondsSinceEpoch,
          dueDate: DateTime(2026, 5, 15).millisecondsSinceEpoch,
          expectedIncomeMinor: y('60.00'),
          currency: 'CNY',
          assetCurrency: 'CNY',
          assetMoneyMinor: y('10000.00'),
          baseCurrency: 'CNY',
          baseMoneyMinor: y('10000.00'),
          remark: '三月期定存',
          status: FixedDepositStatus.running,
        );
        final fd701_2 = FixedDepositItem(
          moneyMinor: y('3000.00'),
          updateAssetBalance: true,
          annualRate: DecimalValue.parse('0.018'),
          periodUnit: DepositPeriodUnit.month,
          periodCount: 6,
          depositDate: DateTime(2026, 4, 1).millisecondsSinceEpoch,
          dueDate: DateTime(2026, 10, 1).millisecondsSinceEpoch,
          expectedIncomeMinor: y('27.00'),
          currency: 'CNY',
          assetCurrency: 'CNY',
          assetMoneyMinor: y('3000.00'),
          baseCurrency: 'CNY',
          baseMoneyMinor: y('3000.00'),
          status: FixedDepositStatus.running,
        );
        final fd703_0 = FixedDepositItem(
          moneyMinor: y('2000.00'),
          annualRate: DecimalValue.parse('0.015'),
          periodUnit: DepositPeriodUnit.year,
          periodCount: 1,
          depositDate: DateTime(2025, 5, 20).millisecondsSinceEpoch,
          dueDate: DateTime(2026, 5, 20).millisecondsSinceEpoch,
          expectedIncomeMinor: y('30.00'),
          currency: 'CNY',
          assetCurrency: 'CNY',
          assetMoneyMinor: y('2000.00'),
          baseCurrency: 'CNY',
          baseMoneyMinor: y('2000.00'),
          status: FixedDepositStatus.running,
        );
        final fd704_0 = FixedDepositItem(
          moneyMinor: y('1000.00'),
          annualRate: DecimalValue.parse('0.045'),
          periodUnit: DepositPeriodUnit.year,
          periodCount: 1,
          depositDate: DateTime(2025, 5, 10).millisecondsSinceEpoch,
          dueDate: DateTime(2026, 5, 10).millisecondsSinceEpoch,
          expectedIncomeMinor: y('45.00'),
          currency: 'USD',
          assetCurrency: 'USD',
          assetMoneyMinor: y('1000.00'),
          baseCurrency: 'CNY',
          baseMoneyMinor: y('7200.00'), // created at 1 USD = 7.20 CNY
          status: FixedDepositStatus.running,
        );
        final fd708_0 = FixedDepositItem(
          moneyMinor: y('500.00'),
          annualRate: DecimalValue.parse('0.04'),
          periodUnit: DepositPeriodUnit.year,
          periodCount: 1,
          depositDate: DateTime(2025, 5, 1).millisecondsSinceEpoch,
          dueDate: DateTime(2026, 5, 1).millisecondsSinceEpoch,
          expectedIncomeMinor: y('20.00'),
          currency: 'GBP',
          assetCurrency: 'GBP',
          assetMoneyMinor: y('500.00'),
          baseCurrency: '',
          baseMoneyMinor: BigInt.zero,
          status: FixedDepositStatus.running,
        );

        // Vector 5: Before global settlement -> 22700.00 / 461.00 / 150.00
        final beforeHeader = computeDepositHeaderSummary(
          [fd701_0, fd701_1, fd701_2, fd703_0, fd704_0, fd708_0],
          rates,
          settledRecordBaseMinors: {'rec_fd_701_0_inc': y('150.00')},
        );
        expect(beforeHeader.totalPrincipalMinor, y('22700.00'));
        expect(beforeHeader.pendingIncomeMinor, y('461.00'));
        expect(beforeHeader.settledIncomeMinor, y('150.00'));

        // Simulate global settlement of 701#1, 703#0, 704#0 (708#0 skipped due to GBP rate=0)
        final settled701_1 = fd701_1.copyWith(
          status: FixedDepositStatus.settled,
          incomeRecordId: 'rec_701_1',
        );
        final settled703_0 = fd703_0.copyWith(
          status: FixedDepositStatus.settled,
          incomeRecordId: 'rec_703_0',
        );
        final settled704_0 = fd704_0.copyWith(
          status: FixedDepositStatus.settled,
          incomeRecordId: 'rec_704_0',
        );
        final postItems = [
          fd701_0,
          settled701_1,
          fd701_2,
          settled703_0,
          settled704_0,
          fd708_0,
        ];

        // Vector 6a: Historical ratio fallback (without Record.bm map) -> 3500.00 / 47.00 / 564.00
        final fallbackPostHeader = computeDepositHeaderSummary(
          postItems,
          rates,
        );
        expect(fallbackPostHeader.totalPrincipalMinor, y('3500.00'));
        expect(fallbackPostHeader.pendingIncomeMinor, y('47.00'));
        expect(fallbackPostHeader.settledIncomeMinor, y('564.00'));

        // Vector 6b: ASYM-FD-05 P-02 fix (reads actual settled Record.bm = 360.00 CNY @ 8.00) -> 600.00
        final actualPostHeader = computeDepositHeaderSummary(
          postItems,
          rates,
          settledRecordBaseMinors: {
            'rec_fd_701_0_inc': y('150.00'),
            'rec_701_1': y('60.00'),
            'rec_703_0': y('30.00'),
            'rec_704_0': y('360.00'), // 45 USD * 8.00 CNY
          },
        );
        expect(actualPostHeader.totalPrincipalMinor, y('3500.00'));
        expect(actualPostHeader.pendingIncomeMinor, y('47.00'));
        expect(actualPostHeader.settledIncomeMinor, y('600.00'));
      },
    );
  });

  group('JSON codec, eligibility, sorting & remark formatting', () {
    test('Empty list encodes to null and null/blank decodes to empty list', () {
      expect(encodeFixedDepositList(const []), isNull);
      expect(decodeFixedDepositList(null), isEmpty);
      expect(decodeFixedDepositList('   '), isEmpty);
    });

    test(
      '18-field canonical JSON roundtrip and legacy float/int tolerant parsing',
      () {
        final item = FixedDepositItem(
          moneyMinor: y('10000.00'),
          fromAssetId: 2,
          updateAssetBalance: false,
          annualRate: DecimalValue.parse('0.024'),
          periodUnit: DepositPeriodUnit.month,
          periodCount: 6,
          depositDate: 1700000000000,
          dueDate: 1715000000000,
          expectedIncomeMinor: y('120.00'),
          currency: 'CNY',
          assetCurrency: 'CNY',
          assetMoneyMinor: y('10000.00'),
          baseCurrency: 'CNY',
          baseMoneyMinor: y('10000.00'),
          remark: '半年期',
          transferRecordId: 'tr-1',
          incomeRecordId: null,
          status: FixedDepositStatus.running,
        );

        final jsonMap = item.toJson();
        expect(jsonMap.keys.length, 18);
        expect(
          jsonMap.keys,
          containsAll([
            'money_minor',
            'from_asset_id',
            'update_asset_balance',
            'annual_rate',
            'period_unit',
            'period_count',
            'deposit_date',
            'due_date',
            'expected_income_minor',
            'c',
            'ac',
            'am_minor',
            'bc',
            'bm_minor',
            'remark',
            'transfer_record_id',
            'income_record_id',
            'status',
          ]),
        );

        final encoded = encodeFixedDepositList([item]);
        final decoded = decodeFixedDepositList(encoded).single;
        expect(decoded.moneyMinor, y('10000.00'));
        expect(formatDecimalValue(decoded.annualRate), '0.024');
        expect(decoded.transferRecordId, 'tr-1');
        expect(decoded.incomeRecordId, isNull);

        // Legacy imported JSON (Gson major-unit fields & scientific notation rate)
        final legacyJson = jsonEncode([
          {
            'money': 3333.33,
            'from_asset_id': -1,
            'update_asset_balance': true,
            'annual_rate': '4.9e-7',
            'period_unit': 1,
            'period_count': 12,
            'deposit_date': 1700000000000,
            'due_date': 1731536000000,
            'expected_income': 0,
            'c': 'CNY',
            'ac': 'CNY',
            'am': '3333.33',
            'bc': 'CNY',
            'bm': 3333.33,
            'remark': '',
            'status': 0,
          },
        ]);
        final legacyItem = decodeFixedDepositList(legacyJson).single;
        expect(legacyItem.moneyMinor, y('3333.33'));
        expect(legacyItem.assetMoneyMinor, y('3333.33'));
        expect(legacyItem.baseMoneyMinor, y('3333.33'));
        expect(formatDecimalValue(legacyItem.annualRate), '0.00000049');
        expect(legacyItem.updateAssetBalance, isTrue);
      },
    );

    test(
      'R1 & ASYM-FD-06: eligibility excludes credit (6), debt (4), and non-active',
      () {
        expect(
          isFixedDepositEligibleAccount(
            type: AssetType.normal,
            status: AssetStatus.active,
          ),
          isTrue,
        );
        expect(
          isFixedDepositEligibleAccount(type: 1, status: AssetStatus.active),
          isTrue,
        );
        expect(
          isFixedDepositEligibleAccount(
            type: AssetType.credit,
            status: AssetStatus.active,
          ),
          isFalse,
        );
        expect(
          isFixedDepositEligibleAccount(
            type: AssetType.debt,
            status: AssetStatus.active,
          ),
          isFalse,
        );
        expect(
          isFixedDepositEligibleAccount(
            type: AssetType.normal,
            status: AssetStatus.hidden,
          ),
          isFalse,
        );
      },
    );

    test('R5: sortFixedDeposits orders (status ASC, dueDate ASC)', () {
      FixedDepositItem mk(int status, int due, String rem) => FixedDepositItem(
        moneyMinor: y('100.00'),
        annualRate: DecimalValue.parse('0.02'),
        depositDate: 100,
        dueDate: due,
        expectedIncomeMinor: y('2.00'),
        remark: rem,
        status: status,
      );

      final sorted = sortFixedDeposits([
        mk(FixedDepositStatus.settled, 1000, 'settled-early'),
        mk(FixedDepositStatus.running, 5000, 'running-late'),
        mk(FixedDepositStatus.running, 2000, 'running-early'),
        mk(FixedDepositStatus.settled, 3000, 'settled-late'),
      ], itemOf: (x) => x);
      expect(sorted.map((e) => e.remark).toList(), [
        'running-early',
        'running-late',
        'settled-early',
        'settled-late',
      ]);
    });

    test(
      'R4: depositIncomeRemark formats full-width colon only when non-blank',
      () {
        expect(depositIncomeRemark(''), '定期存款收益');
        expect(depositIncomeRemark('   '), '定期存款收益');
        expect(depositIncomeRemark('三月期定存'), '定期存款收益：三月期定存');
      },
    );
  });
}
