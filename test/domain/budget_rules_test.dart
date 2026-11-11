import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/domain/ledger/record_relations.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/billing_period.dart';
import 'package:tallyisle/domain/rules/budget_rules.dart';
import 'package:tallyisle/domain/rules/income_expense.dart';

void main() {
  BigInt y(num yuan) => BigInt.from((yuan * 100).round());

  BudgetRecordInput bill(
    String id,
    int catId,
    int type,
    num yuan, {
    int sub = -1,
    RecordRelations? rel,
    bool excludeBudget = false,
    bool excludeExIn = false,
  }) => BudgetRecordInput(
    recordId: id,
    recordCatId: catId,
    entry: StatEntry(
      type: type,
      subType: sub,
      moneyMinor: y(yuan),
      relations: rel,
      excludeBudget: excludeBudget,
      excludeExIn: excludeExIn,
    ),
  );

  RecordRelations refunds(List<num> amounts) =>
      RecordRelations()
        ..refunds = BillLinks(
          children: [
            for (final (i, a) in amounts.indexed)
              LinkedBill(billId: 'ref_$i', amount: y(a)),
          ],
        );

  RecordRelations reimbursed(List<num> amounts) =>
      RecordRelations()
        ..reimbursements = BillLinks(
          children: [
            for (final (i, a) in amounts.indexed)
              LinkedBill(billId: 'rmb_$i', amount: y(a)),
          ],
        );

  final cat100 = const BudgetCategoryNode(
    id: 100,
    name: '餐饮',
    type: 0,
    parentCatId: -1,
  );
  final cat101 = const BudgetCategoryNode(
    id: 101,
    name: '正餐',
    type: 0,
    parentCatId: 100,
  );
  final cat102 = const BudgetCategoryNode(
    id: 102,
    name: '咖啡',
    type: 0,
    parentCatId: 100,
  );
  // cat 103 is deleted, not in activeCategories
  final cat200 = const BudgetCategoryNode(
    id: 200,
    name: '数码',
    type: 0,
    parentCatId: -1,
  );
  final cat300 = const BudgetCategoryNode(
    id: 300,
    name: '办公报销',
    type: 0,
    parentCatId: -1,
  );
  final cat400 = const BudgetCategoryNode(
    id: 400,
    name: '工资储蓄',
    type: 1,
    parentCatId: -1,
  );

  final activeCategories = [cat100, cat101, cat102, cat200, cat300, cat400];

  group('Budget Golden Vectors (docs/modules/budget.md §4, 02zr)', () {
    // 23 bills from 02zr Scenario A
    final r01 = bill('R01', 101, RecordType.expense, 100);
    final r02 = bill('R02', 101, RecordType.expense, 100, excludeBudget: true);
    final r03 = bill('R03', 101, RecordType.expense, 100, excludeExIn: true);
    final r04 = bill('R04', 102, RecordType.expense, 200, rel: refunds([60]));
    final r05 = bill(
      'R05',
      102,
      RecordType.expense,
      -60,
      rel: RecordRelations()..refunds = const BillLinks(originId: 'R04'),
    );
    final r06 = bill('R06', 100, RecordType.expense, 80, rel: refunds([80]));
    final r07 = bill('R07', 100, RecordType.expense, 50, rel: refunds([80]));
    final r08 = bill('R08', 100, RecordType.expense, -25);
    final r09 = bill('R09', 200, RecordType.expense, 40);
    final r09b = bill('R09B', 103, RecordType.expense, 30);
    final r10 = bill('R10', 300, RecordType.reimbursable, 120);
    final r11 = bill(
      'R11',
      300,
      RecordType.reimbursable,
      90,
      rel: reimbursed([90]),
    );
    final r12 = bill(
      'R12',
      300,
      RecordType.reimbursable,
      150,
      rel: reimbursed([100]),
    );
    final r13 = bill(
      'R13',
      300,
      RecordType.reimbursable,
      100,
      rel: reimbursed([130]),
    );
    final r14 = bill('R14', 300, RecordType.reimburseReceipt, 320);
    final r15Skipped = bill('R15', 300, RecordType.advanceIncome, 70, sub: -1);
    final r16 = bill('R16', 300, RecordType.fee, 5, sub: 0);
    final r20 = bill('R20', 100, RecordType.expense, 88, excludeBudget: true);
    final r22 = bill('R22', 400, RecordType.income, 500);

    final smallLedgerRecords = [
      r01,
      r02,
      r03,
      r04,
      r05,
      r06,
      r07,
      r08,
      r09,
      r09b,
      r10,
      r11,
      r12,
      r13,
      r14,
      r15Skipped,
      r16,
      // r17 is from other book so would not be queried in book 1
      r20,
      r22,
    ];

    test(
      'Scenario A: total budget usage 3000 yuan -> used 440, rem 2560, 9 bills',
      () {
        final usage = computeTotalBudgetUsage(
          amountMinor: y(3000),
          budgetId: 1,
          records: smallLedgerRecords,
        );

        expect(usage.rawUsedMinor, y(440));
        expect(usage.displayUsedMinor, y(440));
        expect(usage.remainingMinor, y(2560));
        expect(usage.billCount, 9);
        expect(usage.isOverspent, isFalse);
        expect(usage.matchedRecordIds, [
          'R01',
          'R03',
          'R04',
          'R06',
          'R08',
          'R09',
          'R09B',
          'R12',
          'R16',
        ]);
      },
    );

    test(
      'Scenario A: primary catering cat 100 -> used 315, rem 685, 5 bills',
      () {
        final usage = computeCategoryBudgetUsage(
          category: cat100,
          allCategories: activeCategories,
          amountMinor: y(1000),
          budgetId: 2,
          budgetType: BudgetTypeCode.expenseCategory,
          records: smallLedgerRecords,
        );

        expect(usage.rawUsedMinor, y(315));
        expect(usage.displayUsedMinor, y(315));
        expect(usage.remainingMinor, y(685));
        expect(usage.billCount, 5);
        expect(usage.matchedRecordIds, ['R01', 'R03', 'R04', 'R06', 'R08']);
        // Note: R09B (cat 103) is NOT in cat 100 because cat 103 is not in activeCategories
      },
    );

    test(
      'Scenario A: secondary meals cat 101 -> used 200, rem 400, 2 bills',
      () {
        final usage = computeCategoryBudgetUsage(
          category: cat101,
          allCategories: activeCategories,
          amountMinor: y(600),
          budgetId: 3,
          budgetType: BudgetTypeCode.expenseCategory,
          records: smallLedgerRecords,
        );

        expect(usage.rawUsedMinor, y(200));
        expect(usage.displayUsedMinor, y(200));
        expect(usage.remainingMinor, y(400));
        expect(usage.billCount, 2);
        expect(usage.matchedRecordIds, ['R01', 'R03']);
      },
    );

    test(
      'Scenario A: office reimbursement cat 300 -> used 55, rem 445, 2 bills (ASYM-BG-01 fixed)',
      () {
        final usage = computeCategoryBudgetUsage(
          category: cat300,
          allCategories: activeCategories,
          amountMinor: y(500),
          budgetId: 4,
          budgetType: BudgetTypeCode.expenseCategory,
          records: smallLedgerRecords,
        );

        expect(usage.rawUsedMinor, y(55));
        expect(usage.displayUsedMinor, y(55));
        expect(usage.remainingMinor, y(445));
        expect(usage.billCount, 2);
        expect(usage.matchedRecordIds, ['R12', 'R16']);
      },
    );

    test(
      'Scenario A: saving budget cat 400 -> used(saved) 500, to save 1500, 1 bill',
      () {
        final usage = computeCategoryBudgetUsage(
          category: cat400,
          allCategories: activeCategories,
          amountMinor: y(2000),
          budgetId: 5,
          budgetType: BudgetTypeCode.savingCategory,
          records: smallLedgerRecords,
        );

        expect(usage.rawUsedMinor, y(500));
        expect(usage.displayUsedMinor, y(500));
        expect(usage.remainingMinor, y(1500));
        expect(usage.billCount, 1);
        expect(usage.matchedRecordIds, ['R22']);
      },
    );

    test(
      '03zf correction: type 9 prepaid with subType=0 counts 70 towards expense budget',
      () {
        final r15Active = bill(
          'R15',
          300,
          RecordType.advanceIncome,
          70,
          sub: RecordDirection.expense,
        );
        final usage = computeTotalBudgetUsage(
          amountMinor: y(3000),
          records: [r15Active],
        );
        expect(usage.rawUsedMinor, y(70));
        expect(usage.billCount, 1);
        expect(usage.matchedRecordIds, ['R15']);
      },
    );

    test('Scenario B: negative used clamp and carryover', () {
      // Only R08 (-25 yuan)
      final usage = computeTotalBudgetUsage(
        amountMinor: y(3000),
        records: [r08],
      );

      expect(usage.rawUsedMinor, y(-25));
      expect(usage.displayUsedMinor, BigInt.zero);
      expect(usage.remainingMinor, y(3000));
      expect(usage.isOverspent, isFalse);

      // Carryover with forward == true
      final next = computeNextPeriodCarryover(
        baseAmountMinor: y(3000),
        prevAmountMinor: y(3000),
        rawPrevUsedMinor: usage.rawUsedMinor,
        forward: true,
      );
      expect(next, y(6025));

      // Without forward
      final nextNoForward = computeNextPeriodCarryover(
        baseAmountMinor: y(3000),
        prevAmountMinor: y(3000),
        rawPrevUsedMinor: usage.rawUsedMinor,
        forward: false,
      );
      expect(nextNoForward, y(3000));

      // Severe overspent fallback (nextMoney <= 0)
      final fallbackNext = computeNextPeriodCarryover(
        baseAmountMinor: y(3000),
        prevAmountMinor: y(3000),
        rawPrevUsedMinor: y(6200),
        forward: true,
      );
      expect(fallbackNext, y(3000)); // retains prevAmountMinor
    });

    test(
      'Scenario E: R7 category save automatically upscales total budget',
      () {
        // Expense categories: 1000 + 600 + 500 = 2100.
        final expenseBudgets = [y(1000), y(600), y(500)];

        // Old total is 1800 -> upscales to 2100
        expect(
          upscaledTotalBudget(
            expenseCategoryBudgets: expenseBudgets,
            currentTotalMinor: y(1800),
          ),
          y(2100),
        );

        // Old total is 3000 -> remains 3000
        expect(
          upscaledTotalBudget(
            expenseCategoryBudgets: expenseBudgets,
            currentTotalMinor: y(3000),
          ),
          y(3000),
        );

        // No current total budget -> returns 2100
        expect(
          upscaledTotalBudget(
            expenseCategoryBudgets: expenseBudgets,
            currentTotalMinor: null,
          ),
          y(2100),
        );
      },
    );

    test('3-level hint fallback resolution', () {
      final categoryMap = {for (final c in activeCategories) c.id: c};
      final usage101 = BudgetUsage(
        budgetType: 1,
        categoryId: 101,
        amountMinor: y(600),
        rawUsedMinor: y(200),
        billCount: 2,
        matchedRecordIds: const ['R01', 'R03'],
      );
      final usage100 = BudgetUsage(
        budgetType: 1,
        categoryId: 100,
        amountMinor: y(1000),
        rawUsedMinor: y(315),
        billCount: 5,
        matchedRecordIds: const ['R01', 'R03', 'R04', 'R06', 'R08'],
      );
      final usageTotal = BudgetUsage(
        budgetType: 0,
        categoryId: -1,
        amountMinor: y(3000),
        rawUsedMinor: y(440),
        billCount: 9,
        matchedRecordIds: const [],
      );

      // Level 1: Subcategory 101 has direct budget
      final hint101 = resolveRecordBudgetHint(
        selectedCatId: 101,
        categoryMap: categoryMap,
        categoryBudgets: {101: usage101, 100: usage100},
        totalBudget: usageTotal,
      );
      expect(hint101?.categoryId, 101);

      // Level 2: Subcategory 102 has no budget, falls back to parent 100
      final hint102 = resolveRecordBudgetHint(
        selectedCatId: 102,
        categoryMap: categoryMap,
        categoryBudgets: {101: usage101, 100: usage100},
        totalBudget: usageTotal,
      );
      expect(hint102?.categoryId, 100);

      // Level 3: Category 200 has no budget, parent is -1, falls back to total
      final hint200 = resolveRecordBudgetHint(
        selectedCatId: 200,
        categoryMap: categoryMap,
        categoryBudgets: {101: usage101, 100: usage100},
        totalBudget: usageTotal,
      );
      expect(hint200?.budgetType, BudgetTypeCode.total);

      // Level 4: No total budget returns null
      final hintNone = resolveRecordBudgetHint(
        selectedCatId: 200,
        categoryMap: categoryMap,
        categoryBudgets: {101: usage101, 100: usage100},
        totalBudget: null,
      );
      expect(hintNone, isNull);
    });

    test('BudgetExtra JSON parsing and serialization', () {
      final extra = BudgetExtra(
        autoCopy: true,
        forward: true,
        baseMinor: BigInt.from(300000),
      );
      final jsonStr = extra.toJsonString();
      final parsed = BudgetExtra.fromJson(jsonStr);

      expect(parsed.autoCopy, isTrue);
      expect(parsed.forward, isTrue);
      expect(parsed.baseMinor, BigInt.from(300000));

      final fallback = BudgetExtra.fromJson(
        null,
        fallbackAmountMinor: BigInt.from(12300),
      );
      expect(fallback.autoCopy, isFalse);
      expect(fallback.forward, isFalse);
      expect(fallback.baseMinor, BigInt.from(12300));
    });

    test('BudgetMode monthly and yearly sections', () {
      final period = BillingPeriod.starting(2026, 3, 1);
      expect(BudgetMode.monthly.sectionFor(period), '2026-3');
      expect(BudgetMode.yearly.sectionFor(period), '2026');

      final periodNov = BillingPeriod.starting(2026, 11, 1);
      expect(BudgetMode.monthly.sectionFor(periodNov), '2026-11');
      expect(BudgetMode.yearly.sectionFor(periodNov), '2026');
    });
  });
}
