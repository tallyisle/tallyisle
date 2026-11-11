import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/domain/ledger/effects.dart';
import 'package:tallyisle/domain/ledger/record_extra.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/billing_period.dart';
import 'package:tallyisle/domain/rules/income_expense.dart';
import 'package:tallyisle/domain/ledger/record_relations.dart';

BigInt y(num yuan) => BigInt.from((yuan * 100).round());

void main() {
  group('balanceEffects (ledger-catalog §1)', () {
    test('expense deducts asset, income adds', () {
      expect(
        balanceEffects(EntryFacts(type: 0, moneyMinor: y(85.5), assetId: 1)),
        [AssetDelta(1, -y(85.5))],
      );
      expect(
        balanceEffects(EntryFacts(type: 1, moneyMinor: y(10), assetId: 2)),
        [AssetDelta(2, y(10))],
      );
    });

    test('refund child (negative expense) adds back', () {
      expect(
        balanceEffects(EntryFacts(type: 0, moneyMinor: -y(60), assetId: 1)),
        [AssetDelta(1, y(60))],
      );
    });

    test('expense without account has no balance effect', () {
      expect(balanceEffects(EntryFacts(type: 0, moneyMinor: y(5))), isEmpty);
    });

    test('cross-currency expense uses curr.am (VEC-FX-01)', () {
      final facts = EntryFacts(
        type: 0,
        moneyMinor: y(615.6),
        assetId: 1,
        currency: CurrencySnapshot(
          sourceCode: 'USD',
          sourceGross: y(100),
          assetCode: 'CNY',
          assetNet: y(615.6),
        ),
      );
      expect(balanceEffects(facts), [AssetDelta(1, -y(615.6))]);
    });

    test('transfer: source pays money, target receives am ?? money', () {
      expect(
        balanceEffects(
          EntryFacts(type: 2, moneyMinor: y(100), fromAssetId: 1, toAssetId: 2),
        ),
        [AssetDelta(1, -y(100)), AssetDelta(2, y(100))],
      );
      expect(
        balanceEffects(
          EntryFacts(
            type: 2,
            moneyMinor: y(100),
            fromAssetId: 1,
            toAssetId: 2,
            currency: CurrencySnapshot(
              sourceCode: 'CNY',
              sourceGross: y(100),
              assetCode: 'USD',
              assetNet: y(13.9),
            ),
          ),
        ),
        [AssetDelta(1, -y(100)), AssetDelta(2, y(13.9))],
      );
    });

    test('transfer to the same account is rejected', () {
      expect(
        () => balanceEffects(
          EntryFacts(type: 2, moneyMinor: y(1), fromAssetId: 3, toAssetId: 3),
        ),
        throwsA(anything),
      );
    });

    test('balance adjust adds signed money to from_asset_id', () {
      expect(
        balanceEffects(EntryFacts(type: 4, moneyMinor: -y(20), fromAssetId: 5)),
        [AssetDelta(5, -y(20))],
      );
    });

    test('debt records only move funding accounts', () {
      expect(
        balanceEffects(
          EntryFacts(type: 5, moneyMinor: y(300), fromAssetId: 9, toAssetId: 1),
        ),
        [AssetDelta(1, y(300))],
      );
      expect(
        balanceEffects(
          EntryFacts(type: 6, moneyMinor: y(300), fromAssetId: 1, toAssetId: 9),
        ),
        [AssetDelta(1, -y(300))],
      );
      expect(
        balanceEffects(
          EntryFacts(
            type: 10,
            subType: 0,
            moneyMinor: y(5),
            fromAssetId: 1,
            toAssetId: 9,
          ),
        ),
        [AssetDelta(1, -y(5))],
      );
    });

    test('netEffects of an edit reverses old and applies new', () {
      final net = netEffects(
        before: [EntryFacts(type: 0, moneyMinor: y(85.5), assetId: 1)],
        after: [EntryFacts(type: 0, moneyMinor: y(100), assetId: 2)],
      );
      expect(net, {1: y(85.5), 2: -y(100)});
    });
  });

  group('aggregateIncomeExpense (home-and-period R3)', () {
    StatEntry e(
      int type,
      num yuan, {
      int sub = -1,
      RecordRelations? rel,
      bool exIn = false,
    }) => StatEntry(
      type: type,
      subType: sub,
      moneyMinor: y(yuan),
      relations: rel,
      excludeExIn: exIn,
    );

    RecordRelations refunds(List<num> amounts) =>
        RecordRelations()
          ..refunds = BillLinks(
            children: [
              for (final (i, a) in amounts.indexed)
                LinkedBill(billId: 'r$i', amount: y(a)),
            ],
          );

    RecordRelations reimbursed(List<num> amounts) =>
        RecordRelations()
          ..reimbursements = BillLinks(
            children: [
              for (final (i, a) in amounts.indexed)
                LinkedBill(billId: 'b$i', amount: y(a)),
            ],
          );

    test('full refund contributes 0 but counts the bill', () {
      final s = aggregateIncomeExpense([
        e(0, 80, rel: refunds([80])),
      ]);
      expect(s.expense, BigInt.zero);
      expect(s.expenseCount, 1);
    });

    test('over-refund turns into income', () {
      final s = aggregateIncomeExpense([
        e(0, 50, rel: refunds([80])),
      ]);
      expect(s.expense, BigInt.zero);
      expect(s.income, y(30));
    });

    test('linked refund child contributes nothing', () {
      final child = RecordRelations()..refunds = const BillLinks(originId: 'o');
      final s = aggregateIncomeExpense([e(0, -60, rel: child)]);
      expect(s.expense, BigInt.zero);
      expect(s.expenseCount, 0);
    });

    test('standalone negative expense reduces expense', () {
      final s = aggregateIncomeExpense([e(0, 100), e(0, -25)]);
      expect(s.expense, y(75));
    });

    test('reimbursable 120: unreimbursed 0, 50 reimbursed 70, full 0', () {
      expect(aggregateIncomeExpense([e(3, 120)]).expense, BigInt.zero);
      expect(
        aggregateIncomeExpense([
          e(3, 120, rel: reimbursed([50])),
        ]).expense,
        y(70),
      );
      final full = aggregateIncomeExpense([
        e(3, 120, rel: reimbursed([120])),
      ]);
      expect(full.expense, BigInt.zero);
      expect(full.income, BigInt.zero);
    });

    test('fee counts as expense, transfer and balance adjust do not', () {
      final s = aggregateIncomeExpense([
        e(12, 2, sub: 0),
        e(2, 500),
        e(2, 500, sub: 0), // fixed-deposit Mode A transfer (P-02: never counts)
        e(4, 30, sub: 0),
      ]);
      expect(s.expense, y(2));
    });

    test('exclude_ex_in skips the bill on home', () {
      final s = aggregateIncomeExpense([e(0, 120, exIn: true), e(1, 10)]);
      expect(s.expense, BigInt.zero);
      expect(s.income, y(10));
    });

    test('generic chain uses sub_type', () {
      final s = aggregateIncomeExpense([
        e(10, 5, sub: 0),
        e(10, 7, sub: 1),
        e(17, 3, sub: 1),
        e(14, 9),
      ]);
      expect(s.expense, y(5));
      expect(s.income, y(10));
    });
  });

  group('BillingPeriod (02zi vectors)', () {
    test('start_day 15, March 2026', () {
      final p = BillingPeriod.starting(2026, 3, 15);
      expect(p.start, DateTime(2026, 3, 15));
      expect(p.end, DateTime(2026, 4, 14, 23, 59, 59, 999));
    });

    test('start_day 28 in a common and a leap February', () {
      expect(
        BillingPeriod.starting(2026, 2, 28).end,
        DateTime(2026, 3, 27, 23, 59, 59, 999),
      );
      expect(
        BillingPeriod.starting(2024, 2, 28).end,
        DateTime(2024, 3, 27, 23, 59, 59, 999),
      );
    });

    test('a day before start_day belongs to the previous period', () {
      final p = BillingPeriod.containing(DateTime(2026, 3, 10), 15);
      expect((p.year, p.month), (2026, 2));
      expect(
        p.contains(
          DateTime(2026, 3, 14, 23, 59, 59, 999).millisecondsSinceEpoch,
        ),
        isTrue,
      );
      expect(p.contains(DateTime(2026, 3, 15).millisecondsSinceEpoch), isFalse);
    });

    test('January rolls back to December', () {
      final p = BillingPeriod.containing(DateTime(2026, 1, 3), 10);
      expect((p.year, p.month), (2025, 12));
    });

    test('annual period, section keys, and elapsedDays (M3 shared rules)', () {
      final mar = BillingPeriod.starting(2026, 3, 15);
      expect(mar.monthlySection, '2026-3');
      expect(mar.totalDays, 31);
      expect(mar.elapsedDays(DateTime(2026, 3, 24, 12)), 10);
      expect(mar.elapsedDays(DateTime(2026, 3, 14, 23)), 0);
      expect(mar.elapsedDays(DateTime(2026, 5, 1)), 31);

      final y = BillingPeriod.containingYear(DateTime(2026, 1, 5), 10);
      expect(y.year, 2025);
      expect(y.yearlySection, '2025');
      expect(y.start, DateTime(2025, 1, 10));
      expect(y.end, DateTime(2026, 1, 9, 23, 59, 59, 999));
    });

    test('record type codes stay identical to the original', () {
      expect(RecordType.depositInterest, 17);
      expect(AssetType.credit, 6);
    });
  });
}
