import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/domain/ledger/effects.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/asset_overview.dart';
import 'package:tallyisle/domain/rules/currency_rates.dart';
import 'package:tallyisle/domain/rules/income_expense.dart';

void main() {
  // 1 USD = 7.20 CNY => rate_to_anchor = 1 / 7.20 = 0.138888888889
  final rates = RateTable({'CNY': '1', 'USD': rateToAnchorFromPrice('7.20')});

  group('L-01 billSnapshot across all 4 currency combinations', () {
    test('CNY -> CNY returns null with or without discount', () {
      expect(
        billSnapshot(
          source: 'CNY',
          sourceMinor: BigInt.from(10000),
          account: 'CNY',
          assetMinor: BigInt.from(8000),
          discountMinor: BigInt.from(2000),
          rates: rates,
        ),
        isNull,
      );
      expect(
        billSnapshot(
          source: 'CNY',
          sourceMinor: BigInt.from(10000),
          account: 'CNY',
          assetMinor: BigInt.from(10000),
          rates: rates,
        ),
        isNull,
      );
    });

    test(
      'USD -> USD with discount computes bm from net assetMinor (not gross)',
      () {
        // Gross $100.00, discount $20.00, booked net $80.00 => bm = 80 * 7.20 = ¥576.00
        final snap = billSnapshot(
          source: 'USD',
          sourceMinor: BigInt.from(10000),
          account: 'USD',
          assetMinor: BigInt.from(8000),
          discountMinor: BigInt.from(2000),
          rates: rates,
        )!;
        expect(snap.sourceCode, 'USD');
        expect(snap.sourceGross, BigInt.from(10000));
        expect(snap.assetCode, 'USD');
        expect(snap.assetNet, BigInt.from(8000));
        expect(snap.baseCode, 'CNY');
        expect(snap.baseAmount, BigInt.from(57600));

        // Consistency with effects & income_expense
        final deltas = balanceEffects(
          EntryFacts(
            type: RecordType.expense,
            moneyMinor: BigInt.from(8000),
            assetId: 1,
            currency: snap,
          ),
        );
        expect(deltas, [AssetDelta(1, BigInt.from(-8000))]);

        final statCny = aggregateIncomeExpense([
          StatEntry(
            type: RecordType.expense,
            moneyMinor: BigInt.from(8000),
            discountMinor: BigInt.from(2000),
            currency: snap,
          ),
        ], target: 'CNY');
        expect(statCny.expense, BigInt.from(57600));

        final statUsd = aggregateIncomeExpense([
          StatEntry(
            type: RecordType.expense,
            moneyMinor: BigInt.from(8000),
            discountMinor: BigInt.from(2000),
            currency: snap,
          ),
        ], target: 'USD');
        expect(statUsd.expense, BigInt.from(8000));
      },
    );

    test('USD -> CNY with discount sets bm = assetMinor (net CNY booked)', () {
      // Gross $100, discount $20, net $80 -> booked ¥576.00 (or custom ¥580.00)
      final snap = billSnapshot(
        source: 'USD',
        sourceMinor: BigInt.from(10000),
        account: 'CNY',
        assetMinor: BigInt.from(58000),
        discountMinor: BigInt.from(2000),
        rates: rates,
      )!;
      expect(snap.sourceCode, 'USD');
      expect(snap.sourceGross, BigInt.from(10000));
      expect(snap.assetCode, 'CNY');
      expect(snap.assetNet, BigInt.from(58000));
      expect(snap.baseAmount, BigInt.from(58000));

      final statCny = aggregateIncomeExpense([
        StatEntry(
          type: RecordType.expense,
          moneyMinor: BigInt.from(58000),
          discountMinor: BigInt.from(2000),
          currency: snap,
        ),
      ], target: 'CNY');
      expect(statCny.expense, BigInt.from(58000));
    });

    test(
      'CNY -> USD with discount sets bm = netSource (gross - discount), NOT gross',
      () {
        // Gross ¥100, discount ¥20, net ¥80 -> booked $11.11 on USD card
        final bookedUsd = rates.convert(BigInt.from(8000), 'CNY', 'USD');
        final snap = billSnapshot(
          source: 'CNY',
          sourceMinor: BigInt.from(10000),
          account: 'USD',
          assetMinor: bookedUsd,
          discountMinor: BigInt.from(2000),
          rates: rates,
        )!;
        expect(snap.sourceCode, 'CNY');
        expect(snap.sourceGross, BigInt.from(10000));
        expect(snap.assetCode, 'USD');
        expect(snap.assetNet, bookedUsd);
        expect(snap.baseAmount, BigInt.from(8000));

        final statCny = aggregateIncomeExpense([
          StatEntry(
            type: RecordType.expense,
            moneyMinor: bookedUsd,
            discountMinor: BigInt.from(2000),
            currency: snap,
          ),
        ], target: 'CNY');
        expect(statCny.expense, BigInt.from(8000));
      },
    );

    test('negative refund child snapshot preserves signed baseAmount', () {
      final snap = billSnapshot(
        source: 'USD',
        sourceMinor: BigInt.from(-2500),
        account: 'USD',
        assetMinor: BigInt.from(-2500),
        rates: rates,
      )!;
      expect(snap.sourceGross, BigInt.from(-2500));
      expect(snap.assetNet, BigInt.from(-2500));
      expect(snap.baseAmount, BigInt.from(-18000));
    });
  });
}
