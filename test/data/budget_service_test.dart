import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/data/budget/budget_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/repo/budget_queries.dart';
import 'package:tallyisle/domain/ledger/record_relations.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/billing_period.dart';
import 'package:tallyisle/domain/rules/budget_rules.dart';

void main() {
  late AppDatabase db;
  late BudgetService budgetService;
  late BudgetQueries budgetQueries;
  var n = 0;
  String cmd() => 'budget-cmd-${n++}';

  BigInt y(num yuan) => BigInt.from((yuan * 100).round());

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    budgetService = BudgetService(db);
    budgetQueries = BudgetQueries(db);
  });

  tearDown(() => db.close());

  group('BudgetService & BudgetQueries (F-006, ADR-009, R7)', () {
    test('budget mode defaults to monthly and updates idempotently', () async {
      final initialMode = await budgetQueries.getBudgetMode(1);
      expect(initialMode, BudgetMode.monthly);

      // Set to yearly
      final cId = cmd();
      await budgetService.setBudgetMode(
        commandId: cId,
        bookId: 1,
        mode: BudgetMode.yearly,
      );
      expect(await budgetQueries.getBudgetMode(1), BudgetMode.yearly);

      // Idempotent retry with same commandId
      await budgetService.setBudgetMode(
        commandId: cId,
        bookId: 1,
        mode: BudgetMode.yearly,
      );
      expect(await budgetQueries.getBudgetMode(1), BudgetMode.yearly);

      // Conflict failure if same commandId has different payload
      expect(
        () => budgetService.setBudgetMode(
          commandId: cId,
          bookId: 1,
          mode: BudgetMode.monthly,
        ),
        throwsA(isA<Failure>()),
      );
    });

    test(
      'upsertTotalBudget creates with id=MAX+1 and updates existing',
      () async {
        final id1 = await budgetService.upsertTotalBudget(
          commandId: cmd(),
          bookId: 1,
          section: '2026-3',
          amountMinor: y(3000),
          autoCopy: true,
          forward: true,
        );
        expect(id1, isPositive);

        final budgets = await budgetQueries.getBudgets(1, '2026-3');
        expect(budgets, hasLength(1));
        expect(budgets.first.id, id1);
        expect(budgets.first.amountMinor, y(3000));
        expect(budgets.first.recordCatId, -1);
        expect(budgets.first.budgetType, BudgetTypeCode.total);

        final extra = BudgetExtra.fromJson(budgets.first.extraInfo);
        expect(extra.autoCopy, isTrue);
        expect(extra.forward, isTrue);
        expect(extra.baseMinor, y(3000));

        // Update existing
        final id1Updated = await budgetService.upsertTotalBudget(
          commandId: cmd(),
          bookId: 1,
          section: '2026-3',
          amountMinor: y(3500),
          autoCopy: false,
          forward: false,
        );
        expect(id1Updated, id1);

        final budgetsUpdated = await budgetQueries.getBudgets(1, '2026-3');
        expect(budgetsUpdated, hasLength(1));
        expect(budgetsUpdated.first.amountMinor, y(3500));
        final extraUpdated = BudgetExtra.fromJson(
          budgetsUpdated.first.extraInfo,
        );
        expect(extraUpdated.autoCopy, isFalse);
      },
    );

    test('upsertCategoryBudget and R7 auto-upscale total budget', () async {
      // 1. Initially set a total budget of 1800 yuan
      await budgetService.upsertTotalBudget(
        commandId: cmd(),
        bookId: 1,
        section: '2026-11',
        amountMinor: y(1800),
        autoCopy: true,
      );

      // 2. Add expense category 100 with budget 1000 yuan
      await budgetService.upsertCategoryBudget(
        commandId: cmd(),
        bookId: 1,
        section: '2026-11',
        categoryId: 100,
        budgetType: BudgetTypeCode.expenseCategory,
        amountMinor: y(1000),
      );

      // Total budget is still 1800 because 1000 <= 1800
      var currentBudgets = await budgetQueries.getBudgets(1, '2026-11');
      var total = currentBudgets.firstWhere(
        (b) => b.budgetType == BudgetTypeCode.total,
      );
      expect(total.amountMinor, y(1800));

      // 3. Add expense category 101 with budget 600 yuan (sum = 1600 <= 1800)
      await budgetService.upsertCategoryBudget(
        commandId: cmd(),
        bookId: 1,
        section: '2026-11',
        categoryId: 101,
        budgetType: BudgetTypeCode.expenseCategory,
        amountMinor: y(600),
      );
      currentBudgets = await budgetQueries.getBudgets(1, '2026-11');
      total = currentBudgets.firstWhere(
        (b) => b.budgetType == BudgetTypeCode.total,
      );
      expect(total.amountMinor, y(1800));

      // 4. Add saving category 400 with 2000 yuan (sum of expense is still 1600, saving does not count)
      await budgetService.upsertCategoryBudget(
        commandId: cmd(),
        bookId: 1,
        section: '2026-11',
        categoryId: 400,
        budgetType: BudgetTypeCode.savingCategory,
        amountMinor: y(2000),
      );
      currentBudgets = await budgetQueries.getBudgets(1, '2026-11');
      total = currentBudgets.firstWhere(
        (b) => b.budgetType == BudgetTypeCode.total,
      );
      expect(total.amountMinor, y(1800));

      // 5. Add expense category 300 with 500 yuan -> expense sum becomes 1000 + 600 + 500 = 2100 > 1800!
      // R7 triggers: total budget automatically upscaled to 2100 in the same transaction!
      await budgetService.upsertCategoryBudget(
        commandId: cmd(),
        bookId: 1,
        section: '2026-11',
        categoryId: 300,
        budgetType: BudgetTypeCode.expenseCategory,
        amountMinor: y(500),
      );

      currentBudgets = await budgetQueries.getBudgets(1, '2026-11');
      total = currentBudgets.firstWhere(
        (b) => b.budgetType == BudgetTypeCode.total,
      );
      expect(total.amountMinor, y(2100));
      final totalExtra = BudgetExtra.fromJson(total.extraInfo);
      expect(totalExtra.baseMinor, y(2100));
      expect(
        totalExtra.autoCopy,
        isTrue,
      ); // preserves previous autoCopy setting
    });

    test('deleteBudget removes budget row', () async {
      final id = await budgetService.upsertTotalBudget(
        commandId: cmd(),
        bookId: 1,
        section: '2026-5',
        amountMinor: y(2000),
      );
      expect(await budgetQueries.getBudgets(1, '2026-5'), hasLength(1));

      await budgetService.deleteBudget(commandId: cmd(), budgetId: id);
      expect(await budgetQueries.getBudgets(1, '2026-5'), isEmpty);
    });

    test(
      'ensureAutoCarryoverIfNeeded handles multiple acopy category budgets without singleOrNull bug',
      () async {
        final periodPrev = BillingPeriod.starting(2026, 3, 1);
        final periodCurr = BillingPeriod.starting(2026, 4, 1);

        // 1. In prev period (2026-3), create total budget and 2 category budgets, all with acopy=true
        await budgetService.upsertTotalBudget(
          commandId: cmd(),
          bookId: 1,
          section: '2026-3',
          amountMinor: y(3000),
          autoCopy: true,
          forward: true,
        );
        await budgetService.upsertCategoryBudget(
          commandId: cmd(),
          bookId: 1,
          section: '2026-3',
          categoryId: 100,
          budgetType: BudgetTypeCode.expenseCategory,
          amountMinor: y(1000),
          autoCopy: true,
          forward: false,
        );
        await budgetService.upsertCategoryBudget(
          commandId: cmd(),
          bookId: 1,
          section: '2026-3',
          categoryId: 101,
          budgetType: BudgetTypeCode.expenseCategory,
          amountMinor: y(600),
          autoCopy: true,
          forward: false,
        );

        // Add a standalone negative bill of -25 in prev period
        await db
            .into(db.records)
            .insert(
              RecordsCompanion.insert(
                recordId: 'r_prev_neg',
                type: RecordType.expense,
                moneyMinor: y(-25),
                recordTime: periodPrev.startMs + 1000,
                accountBookId: 1,
                recordCatId: const Value(100),
              ),
            );

        // 2. In current period (2026-4), there are currently no budgets
        expect(await budgetQueries.getBudgets(1, '2026-4'), isEmpty);

        // 3. Trigger auto carryover
        final copied = await budgetService.ensureAutoCarryoverIfNeeded(
          commandId: cmd(),
          bookId: 1,
          mode: BudgetMode.monthly,
          currentPeriod: periodCurr,
          startDay: 1,
        );
        expect(copied, 3); // 1 total + 2 categories copied!

        final newBudgets = await budgetQueries.getBudgets(1, '2026-4');
        expect(newBudgets, hasLength(3));

        // Total budget had forward=true: base 3000, rawPrevUsed -25 => 6025
        final newTotal = newBudgets.firstWhere(
          (b) => b.budgetType == BudgetTypeCode.total,
        );
        expect(newTotal.amountMinor, y(6025));

        // Categories had forward=false: copied baseMinor
        final newCat100 = newBudgets.firstWhere((b) => b.recordCatId == 100);
        expect(newCat100.amountMinor, y(1000));
        final newCat101 = newBudgets.firstWhere((b) => b.recordCatId == 101);
        expect(newCat101.amountMinor, y(600));

        // Calling again when current period already has budgets does nothing
        final copiedAgain = await budgetService.ensureAutoCarryoverIfNeeded(
          commandId: cmd(),
          bookId: 1,
          mode: BudgetMode.monthly,
          currentPeriod: periodCurr,
          startDay: 1,
        );
        expect(copiedAgain, 0);
      },
    );

    test(
      'Drilldown includes reimbursable type 3 and fee type 12 (ASYM-BG-01 fixed)',
      () async {
        final period = BillingPeriod.starting(2026, 11, 1);

        // Insert R12 (type 3 reimbursable with 50 self-borne)
        final r12Rel = RecordRelations()
          ..reimbursements = BillLinks(
            children: [LinkedBill(billId: 'b1', amount: BigInt.from(10000))],
          );

        await db
            .into(db.records)
            .insert(
              RecordsCompanion.insert(
                recordId: 'R12',
                type: RecordType.reimbursable,
                moneyMinor: y(150),
                recordTime: period.startMs + 5000,
                accountBookId: 1,
                recordCatId: const Value(300),
                relInfo: Value(r12Rel.encode()),
              ),
            );

        // Insert R16 (type 12 fee 5 yuan)
        await db
            .into(db.records)
            .insert(
              RecordsCompanion.insert(
                recordId: 'R16',
                type: RecordType.fee,
                moneyMinor: y(5),
                recordTime: period.endMs - 1000,
                accountBookId: 1,
                recordCatId: const Value(300),
              ),
            );

        final periodRecords = await budgetQueries.getBudgetPeriodRecords(
          1,
          period.startMs,
          period.endMs,
        );
        expect(periodRecords, hasLength(2));
        expect(
          periodRecords.map((r) => r.recordId),
          containsAll(['R12', 'R16']),
        );
      },
    );
  });
}
