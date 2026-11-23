import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
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
import 'package:tallyisle/features/budget/budget_providers.dart';
import 'package:tallyisle/features/budget/budget_widgets.dart';
import 'package:tallyisle/features/common/year_month_picker_dialog.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

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

  testWidgets(
    'BudgetSummaryCard inline period controls step months/years, reset to current period without firing onTap, and do not prematurely copy future budgets',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final service = BudgetService(db);
      final now = DateTime.now();
      final curPeriod = BillingPeriod.containing(now, 1);
      final prevPeriod = BillingPeriod.starting(
        curPeriod.year,
        curPeriod.month - 1,
        1,
      );
      final nextPeriod = BillingPeriod.starting(
        curPeriod.year,
        curPeriod.month + 1,
        1,
      );

      // Current period has 2500.00 total budget with autoCopy=true; previous & next have none.
      await service.upsertTotalBudget(
        commandId: 'cmd-inline-cur',
        bookId: 1,
        section: curPeriod.monthlySection,
        amountMinor: BigInt.from(250000),
        autoCopy: true,
        forward: true,
      );

      var cardTappedCount = 0;
      await tester.pumpWidget(
        buildApp(
          Scaffold(
            body: BudgetSummaryCard(
              enablePeriodControls: true,
              onTap: () => cardTappedCount++,
            ),
          ),
          db,
        ),
      );
      await settle(tester);

      // Offset == 0: reset pill is hidden, arrows are visible, shows current month total budget.
      expect(find.byKey(const Key('budget_card_period_prev')), findsOneWidget);
      expect(find.byKey(const Key('budget_card_period_next')), findsOneWidget);
      expect(find.byKey(const Key('budget_card_period_reset')), findsNothing);
      expect(
        find.text('${curPeriod.year}年${curPeriod.month}月总预算'),
        findsOneWidget,
      );
      expect(find.text('¥2500.00'), findsOneWidget);

      // Step to previous month (empty): arrows remain, reset pill '回本月' appears, onTap NOT fired.
      await tester.tap(find.byKey(const Key('budget_card_period_prev')));
      await settle(tester);
      expect(cardTappedCount, 0);
      expect(find.byKey(const Key('budget_card_period_prev')), findsOneWidget);
      expect(find.byKey(const Key('budget_card_period_next')), findsOneWidget);
      expect(find.byKey(const Key('budget_card_period_reset')), findsOneWidget);
      expect(find.text('回本月'), findsOneWidget);
      expect(
        find.text('${prevPeriod.year}年${prevPeriod.month}月预算'),
        findsOneWidget,
      );
      expect(find.text('该期未设置预算'), findsOneWidget);

      // Verify zero overflow on narrow 320dp and 360dp viewports in both empty & populated states.
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      for (final w in <double>[320, 360]) {
        tester.view.physicalSize = Size(w, 640);
        tester.view.devicePixelRatio = 1.0;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      await tester.pumpAndSettle();

      // Tap '回本月' -> returns immediately to current month, hides reset pill, onTap NOT fired.
      await tester.tap(find.byKey(const Key('budget_card_period_reset')));
      await settle(tester);
      expect(cardTappedCount, 0);
      expect(find.byKey(const Key('budget_card_period_reset')), findsNothing);
      expect(find.text('¥2500.00'), findsOneWidget);

      // Step forward to next month (offset == +1): must NOT materialize auto-carryover into next month!
      await tester.tap(find.byKey(const Key('budget_card_period_next')));
      await settle(tester);
      expect(cardTappedCount, 0);
      expect(
        find.text('${nextPeriod.year}年${nextPeriod.month}月预算'),
        findsOneWidget,
      );
      expect(find.text('该期未设置预算'), findsOneWidget);

      // Switch to yearly mode -> reset pill shows '回今年'.
      await service.setBudgetMode(
        commandId: 'cmd-inline-yearly',
        bookId: 1,
        mode: BudgetMode.yearly,
      );
      await settle(tester);
      expect(find.text('回今年'), findsOneWidget);

      // Reset to current year -> hides '回今年'.
      await tester.tap(find.byKey(const Key('budget_card_period_reset')));
      await settle(tester);
      expect(find.byKey(const Key('budget_card_period_reset')), findsNothing);

      // Tapping the card body itself still fires onTap.
      await tester.tap(find.byKey(const Key('budget_summary_card')));
      expect(cardTappedCount, 1);

      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'BudgetPage: year/year-month pickers respect custom startDay, show 回本月/回本年 reset pills, and have zero overflow at 360x640 @ 1.2x',
    (tester) async {
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });

      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = 1.2;

      final db = AppDatabase(NativeDatabase.memory());
      // Configure custom book startDay = 15
      await (db.update(db.accountBooks)..where((b) => b.id.equals(1))).write(
        const AccountBooksCompanion(startDay: Value(15)),
      );

      final now = DateTime.now();
      final curMonth = BillingPeriod.containing(now, 15);
      final curYear = BillingPeriod.containingYear(now, 15);
      final targetYear = curYear.year - 1;

      await tester.pumpWidget(buildApp(const BudgetPage(), db));
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(
        find.text('${curMonth.year} 年 ${curMonth.month} 月'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('budget_period_reset')), findsNothing);

      // Tap period title -> opens Year-Month picker; jump to targetYear-02
      await tester.tap(find.byKey(const Key('budget-period-picker-trigger')));
      await settle(tester);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('ym-picker-toggle-year-grid')));
      await settle(tester);
      await tester.tap(find.byKey(Key('ym-picker-year-$targetYear')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('ym-picker-month-2')));
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('$targetYear 年 2 月'), findsOneWidget);
      expect(find.byKey(const Key('budget_period_reset')), findsOneWidget);
      expect(find.text('回本月'), findsOneWidget);

      // Tap 回本月 -> returns to curMonth (startDay=15)
      await tester.tap(find.byKey(const Key('budget_period_reset')));
      await settle(tester);
      expect(
        find.text('${curMonth.year} 年 ${curMonth.month} 月'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('budget_period_reset')), findsNothing);

      // Switch to yearly budget -> tap period title -> opens Year-Only picker; jump to targetYear
      await tester.tap(find.text('年预算'));
      await settle(tester);
      expect(find.text('${curYear.year} 年'), findsOneWidget);

      await tester.tap(find.byKey(const Key('budget-period-picker-trigger')));
      await settle(tester);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(Key('y-picker-year-$targetYear')));
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('$targetYear 年'), findsOneWidget);
      expect(find.byKey(const Key('budget_period_reset')), findsOneWidget);
      expect(find.text('回本年'), findsOneWidget);

      // Tap 回本年 -> returns to curYear
      await tester.tap(find.byKey(const Key('budget_period_reset')));
      await settle(tester);
      expect(find.text('${curYear.year} 年'), findsOneWidget);
      expect(find.byKey(const Key('budget_period_reset')), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'YearMonthPicker & YearOnlyPicker honor explicit billing currentYear/currentMonth for shortcut visibility, pop result, and highlight',
    (tester) async {
      ({int year, int month})? pickedYm;
      int? pickedY;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: Column(
                children: [
                  ElevatedButton(
                    key: const Key('open-ym-same'),
                    onPressed: () async {
                      pickedYm = await showYearMonthPickerDialog(
                        ctx,
                        initialYear: 2024,
                        initialMonth: 7,
                        currentYear: 2024,
                        currentMonth: 7,
                      );
                    },
                    child: const Text('YM_SAME'),
                  ),
                  ElevatedButton(
                    key: const Key('open-ym-diff'),
                    onPressed: () async {
                      pickedYm = await showYearMonthPickerDialog(
                        ctx,
                        initialYear: 2024,
                        initialMonth: 3,
                        currentYear: 2024,
                        currentMonth: 7,
                      );
                    },
                    child: const Text('YM_DIFF'),
                  ),
                  ElevatedButton(
                    key: const Key('open-y-same'),
                    onPressed: () async {
                      pickedY = await showYearOnlyPickerDialog(
                        ctx,
                        initialYear: 2024,
                        currentYear: 2024,
                      );
                    },
                    child: const Text('Y_SAME'),
                  ),
                  ElevatedButton(
                    key: const Key('open-y-diff'),
                    onPressed: () async {
                      pickedY = await showYearOnlyPickerDialog(
                        ctx,
                        initialYear: 2022,
                        currentYear: 2024,
                      );
                    },
                    child: const Text('Y_DIFF'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      // 1. YM when initial == billing current (2024-07 != DateTime.now()): `本月` pill MUST be hidden!
      await tester.tap(find.byKey(const Key('open-ym-same')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ym-picker-jump-current')), findsNothing);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      // 2. YM when initial (2024-03) != billing current (2024-07):
      // `ym-picker-month-7` gets primaryContainer highlight & `本月` pops (2024, 7)!
      await tester.tap(find.byKey(const Key('open-ym-diff')));
      await tester.pumpAndSettle();
      final ctx = tester.element(find.byKey(const Key('ym-picker-month-7')));
      final scheme = Theme.of(ctx).colorScheme;
      final curTileMaterial = tester.widget<Material>(
        find.descendant(
          of: find.byKey(const Key('ym-picker-month-7')),
          matching: find.byType(Material),
        ),
      );
      final selTileMaterial = tester.widget<Material>(
        find.descendant(
          of: find.byKey(const Key('ym-picker-month-3')),
          matching: find.byType(Material),
        ),
      );
      expect(curTileMaterial.color, scheme.primaryContainer);
      expect(selTileMaterial.color, scheme.primary);
      expect(find.byKey(const Key('ym-picker-jump-current')), findsOneWidget);
      await tester.tap(find.byKey(const Key('ym-picker-jump-current')));
      await tester.pumpAndSettle();
      expect(pickedYm, (year: 2024, month: 7));

      // 3. Year-only when initial == billing current (2024): `本年` hidden!
      await tester.tap(find.byKey(const Key('open-y-same')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('y-picker-jump-current')), findsNothing);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      // 4. Year-only when initial (2022) != billing current (2024):
      // `y-picker-year-2024` gets primaryContainer highlight & `本年` pops 2024!
      await tester.tap(find.byKey(const Key('open-y-diff')));
      await tester.pumpAndSettle();
      final yCurMaterial = tester.widget<Material>(
        find.descendant(
          of: find.byKey(const Key('y-picker-year-2024')),
          matching: find.byType(Material),
        ),
      );
      expect(yCurMaterial.color, scheme.primaryContainer);
      expect(find.byKey(const Key('y-picker-jump-current')), findsOneWidget);
      await tester.tap(find.byKey(const Key('y-picker-jump-current')));
      await tester.pumpAndSettle();
      expect(pickedY, 2024);
    },
  );

  testWidgets(
    'BudgetPage with startDay > today: tapping picker 本月 returns to offset 0 (not +1)',
    (tester) async {
      final now = DateTime.now();
      if (now.day > 27) {
        // Only skipped on days 28..31 when startDay (max 28) cannot exceed today.
        return;
      }
      final shiftedStartDay = now.day + 1;
      final db = AppDatabase(NativeDatabase.memory());
      await (db.update(db.accountBooks)..where((b) => b.id.equals(1))).write(
        AccountBooksCompanion(startDay: Value(shiftedStartDay)),
      );

      final activeBillingMonth = BillingPeriod.containing(now, shiftedStartDay);
      // Sanity check: billing month differs from calendar month!
      expect(activeBillingMonth.month, isNot(now.month));

      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: Consumer(
            builder: (context, ref, _) {
              container = ProviderScope.containerOf(context, listen: false);
              return const MaterialApp(home: BudgetPage());
            },
          ),
        ),
      );
      await settle(tester);

      // At offset 0: opening picker MUST NOT show `本月` shortcut!
      expect(container.read(budgetOffsetProvider), 0);
      await tester.tap(find.byKey(const Key('budget-period-picker-trigger')));
      await settle(tester);
      expect(find.byKey(const Key('ym-picker-jump-current')), findsNothing);
      await tester.tapAt(const Offset(5, 5));
      await settle(tester);

      // Step to offset -1, open picker, tap `本月` -> MUST return to offset 0 (not +1)!
      await tester.tap(find.byKey(const Key('budget_period_prev')));
      await settle(tester);
      expect(container.read(budgetOffsetProvider), -1);
      await tester.tap(find.byKey(const Key('budget-period-picker-trigger')));
      await settle(tester);
      expect(find.byKey(const Key('ym-picker-jump-current')), findsOneWidget);
      await tester.tap(find.byKey(const Key('ym-picker-jump-current')));
      await settle(tester);
      expect(container.read(budgetOffsetProvider), 0);
      expect(find.byKey(const Key('budget_period_reset')), findsNothing);
      expect(
        find.text('${activeBillingMonth.year} 年 ${activeBillingMonth.month} 月'),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
    },
  );
}
