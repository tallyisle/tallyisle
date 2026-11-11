import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/data/budget/budget_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/domain/ledger/record_relations.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/billing_period.dart';
import 'package:tallyisle/domain/rules/budget_rules.dart';
import 'package:tallyisle/features/budget/budget_page.dart';
import 'package:tallyisle/features/budget/budget_widgets.dart';

void main() {
  Widget buildApp(Widget child, AppDatabase db) => ProviderScope(
    retry: (_, _) => null,
    overrides: [databaseProvider.overrideWith((ref) async => db)],
    child: MaterialApp(home: child),
  );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  testWidgets(
    'BudgetPage flow: set total budget, set category budget with R7 upscale, and drilldown',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final now = DateTime.now();
      final period = BillingPeriod.containing(now, 1);

      // Pre-insert a reimbursable bill (R12: 150 yuan with 100 reimbursed => 50 self-borne)
      // and a fee bill (R16: 5 yuan) in category 1 (餐饮)
      final r12Rel = RecordRelations()
        ..reimbursements = BillLinks(
          children: [
            LinkedBill(billId: 'b1', amount: BigInt.from(10000)), // 100.00
          ],
        );

      await db
          .into(db.records)
          .insert(
            RecordsCompanion.insert(
              recordId: 'R12',
              type: RecordType.reimbursable,
              moneyMinor: BigInt.from(15000), // 150.00
              recordTime: period.startMs + 10000,
              accountBookId: 1,
              recordCatId: const Value(1), // 餐饮
              relInfo: Value(r12Rel.encode()),
            ),
          );

      await db
          .into(db.records)
          .insert(
            RecordsCompanion.insert(
              recordId: 'R16',
              type: RecordType.fee,
              moneyMinor: BigInt.from(500), // 5.00
              recordTime: period.startMs + 20000,
              accountBookId: 1,
              recordCatId: const Value(1), // 餐饮
            ),
          );

      await tester.pumpWidget(buildApp(const BudgetPage(), db));
      await settle(tester);

      expect(find.byKey(const Key('budget_page')), findsOneWidget);
      expect(find.text('未设置当期预算'), findsOneWidget);

      // 1. Set total budget to 1800.00
      await tester.tap(find.byKey(const Key('set_total_budget_button')));
      await settle(tester);

      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('total_budget_amount_input')),
        '1800.00',
      );
      await tester.tap(find.byKey(const Key('save_total_budget_button')));
      await settle(tester);

      // Total budget is now 1800.00
      expect(find.text('¥1800.00'), findsOneWidget);

      // 2. Add category budget for category 1 (餐饮) with 2100.00
      await tester.tap(find.byKey(const Key('add_expense_budget_button')));
      await settle(tester);

      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('category_budget_amount_input')),
        '2100.00',
      );
      await tester.tap(find.byKey(const Key('save_category_budget_button')));
      await settle(tester);

      // 3. Verify R7: total budget automatically upscaled to 2100.00!
      expect(find.text('¥2100.00'), findsWidgets);

      // 4. Tap the category budget card to drill down
      await tester.tap(find.byKey(const Key('category_budget_card_1')));
      await settle(tester);

      // Should be on drilldown page
      expect(find.byKey(const Key('budget_drilldown_page')), findsOneWidget);
      expect(find.text('餐饮支出明细'), findsOneWidget);

      // Both R12 (partial reimbursable self-borne 50) and R16 (fee 5) appear in drilldown!
      expect(find.byKey(const Key('drilldown_bill_R12')), findsOneWidget);
      expect(find.byKey(const Key('drilldown_bill_R16')), findsOneWidget);

      // Back to BudgetPage
      await tester.tap(find.byType(BackButton));
      await settle(tester);
      expect(find.byKey(const Key('budget_page')), findsOneWidget);

      // Clean up
      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets('BudgetSummaryCard displays empty state and populated state', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    var tapped = false;
    await tester.pumpWidget(
      buildApp(
        Scaffold(body: BudgetSummaryCard(onTap: () => tapped = true)),
        db,
      ),
    );
    await settle(tester);

    expect(find.byKey(const Key('budget_summary_card')), findsOneWidget);
    expect(find.byKey(const Key('budget_empty_prompt')), findsOneWidget);

    // Tap triggers callback
    await tester.tap(find.byKey(const Key('budget_summary_card')));
    expect(tapped, isTrue);

    // Set a total budget directly via BudgetService
    final service = BudgetService(db);
    final now = DateTime.now();
    final period = BillingPeriod.containing(now, 1);

    await service.upsertTotalBudget(
      commandId: 'cmd-total-card',
      bookId: 1,
      section: period.monthlySection,
      amountMinor: BigInt.from(300000), // 3000.00
    );

    // Add a bill of 600.00
    await db
        .into(db.records)
        .insert(
          RecordsCompanion.insert(
            recordId: 'bill_card_1',
            type: RecordType.expense,
            moneyMinor: BigInt.from(60000), // 600.00
            recordTime: period.startMs + 5000,
            accountBookId: 1,
            recordCatId: const Value(1),
          ),
        );

    await settle(tester);

    expect(find.byKey(const Key('budget_progress_bar')), findsOneWidget);
    expect(find.byKey(const Key('budget_used_text')), findsOneWidget);
    expect(find.text('已用: ¥600.00'), findsOneWidget);
    expect(find.byKey(const Key('budget_remaining_text')), findsOneWidget);
    expect(find.text('剩余: ¥2400.00'), findsOneWidget);
    expect(find.text('20.0%'), findsOneWidget);

    // Clean up
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('RecordBudgetHintBar 3-level fallback and excludeBudget flag', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    final now = DateTime.now();
    final period = BillingPeriod.containing(now, 1);
    final service = BudgetService(db);

    // Set total budget 3000.00
    await service.upsertTotalBudget(
      commandId: 'cmd-hint-tot',
      bookId: 1,
      section: period.monthlySection,
      amountMinor: BigInt.from(300000),
    );

    // Set category budget for category 1 (餐饮) 1000.00
    await service.upsertCategoryBudget(
      commandId: 'cmd-hint-c1',
      bookId: 1,
      section: period.monthlySection,
      categoryId: 1,
      budgetType: BudgetTypeCode.expenseCategory,
      amountMinor: BigInt.from(100000),
    );

    // Test 1: excludeBudget == true -> hidden
    await tester.pumpWidget(
      buildApp(
        RecordBudgetHintBar(
          bookId: 1,
          recordTime: period.startMs + 1000,
          categoryId: 1,
          excludeBudget: true,
        ),
        db,
      ),
    );
    await settle(tester);
    expect(find.byKey(const Key('record_budget_hint_bar')), findsNothing);

    // Test 2: category 1 has direct budget -> shows category budget hint
    await tester.pumpWidget(
      buildApp(
        RecordBudgetHintBar(
          bookId: 1,
          recordTime: period.startMs + 1000,
          categoryId: 1,
          excludeBudget: false,
        ),
        db,
      ),
    );
    await settle(tester);
    expect(find.byKey(const Key('record_budget_hint_bar')), findsOneWidget);
    expect(find.textContaining('分类预算: 剩余 ¥1000.00'), findsOneWidget);

    // Test 3: category 2 has no direct budget and is a top-level category -> falls back to total budget
    await tester.pumpWidget(
      buildApp(
        RecordBudgetHintBar(
          bookId: 1,
          recordTime: period.startMs + 1000,
          categoryId: 2,
          excludeBudget: false,
        ),
        db,
      ),
    );
    await settle(tester);
    expect(find.byKey(const Key('record_budget_hint_bar')), findsOneWidget);
    expect(find.textContaining('总预算: 剩余 ¥3000.00'), findsOneWidget);

    // Clean up
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    await tester.pump(const Duration(seconds: 1));
  });
}
