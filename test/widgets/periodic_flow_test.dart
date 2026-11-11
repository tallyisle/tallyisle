import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/data/periodic/periodic_service.dart';
import 'package:tallyisle/data/repo/periodic_queries.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/periodic_records.dart';
import 'package:tallyisle/features/periodic/periodic_editor_page.dart';
import 'package:tallyisle/features/periodic/periodic_page.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Widget buildApp(Widget child, AppDatabase db) => ProviderScope(
    retry: (_, _) => null,
    overrides: [databaseProvider.overrideWith((ref) async => db)],
    child: MaterialApp(home: child),
  );

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  testWidgets(
    'PeriodicPage lifecycle flow: create rule, auto catch-up, history drilldown, pause/resume across 3 tabs, and delete retaining history',
    (tester) async {
      final fixedNow = DateTime(2026, 3, 5, 10, 30).millisecondsSinceEpoch;
      final db = AppDatabase(NativeDatabase.memory(), nowMs: () => fixedNow);
      final ledger = LedgerService(db);
      final assetId = (await tester.runAsync(
        () => ledger.createAsset(
          commandId: 'w-asset-1',
          name: '招商卡',
          initial: Money.parse('500.00'),
        ),
      ))!;

      await tester.pumpWidget(buildApp(const PeriodicPage(), db));
      await settle(tester);

      expect(find.byKey(const Key('periodic_page')), findsOneWidget);
      expect(find.text('暂无进行中的周期记账'), findsOneWidget);

      // 1. Tap FAB to create a daily expense rule due today
      await tester.tap(find.byKey(const Key('add_periodic_button')));
      await settle(tester);

      expect(find.byKey(const Key('periodic_editor_page')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('periodic_amount_input')),
        '35.00',
      );
      await tester.tap(find.byKey(const Key('periodic_cat_餐饮')));
      await settle(tester);

      await tester.tap(find.byKey(const Key('periodic_asset_picker')));
      await settle(tester);
      await tester.tap(find.text('招商卡').last);
      await settle(tester);

      await tester.ensureVisible(find.byKey(const Key('period_type_0')));
      await tester.tap(find.byKey(const Key('period_type_0')));
      await settle(tester);

      await tester.tap(find.byKey(const Key('save_periodic_button')));
      await settle(tester);

      // Back on PeriodicPage: rule is active and already caught up 1 bill for today!
      expect(find.byKey(const Key('periodic_page')), findsOneWidget);
      expect(find.text('餐饮'), findsOneWidget);
      expect(find.text('-¥35.00'), findsOneWidget);
      expect(find.textContaining('已记 1 次'), findsOneWidget);

      // 2. Tap rule card to inspect generated history drilldown
      await tester.tap(find.byKey(const Key('periodic_card_1')));
      await settle(tester);

      expect(find.byKey(const Key('periodic_history_page')), findsOneWidget);
      expect(find.textContaining('共生成 1 笔记录'), findsOneWidget);
      expect(find.text('-35.00'), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await settle(tester);
      expect(find.byKey(const Key('periodic_page')), findsOneWidget);

      // 3. Pause rule -> moves to 已停用 tab (state = 2)
      await tester.tap(find.byKey(const Key('periodic_menu_1')));
      await settle(tester);
      await tester.tap(find.text('停用'));
      await settle(tester);

      expect(find.text('暂无进行中的周期记账'), findsOneWidget);

      await tester.tap(find.byKey(const Key('periodic_tab_2')));
      await settle(tester);
      expect(find.byKey(const Key('periodic_card_1')), findsOneWidget);

      // 4. Resume rule -> moves back to 进行中 tab (state = 0)
      await tester.tap(find.byKey(const Key('periodic_menu_1')));
      await settle(tester);
      await tester.tap(find.text('设为进行中'));
      await settle(tester);

      expect(find.text('暂无已停用的周期记账'), findsOneWidget);

      await tester.tap(find.byKey(const Key('periodic_tab_0')));
      await settle(tester);
      expect(find.byKey(const Key('periodic_card_1')), findsOneWidget);

      // 5. Delete rule -> confirm dialog -> rule deleted, historical record & asset balance retained
      await tester.tap(find.byKey(const Key('periodic_menu_1')));
      await settle(tester);
      await tester.tap(find.text('删除'));
      await settle(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await settle(tester);

      expect(find.text('暂无进行中的周期记账'), findsOneWidget);

      final retainedRecords = (await tester.runAsync(
        () => PeriodicQueries(db).getHistoryRecords(1),
      ))!;
      expect(retainedRecords, hasLength(1));
      final updatedAsset = (await tester.runAsync(
        () => (db.select(
          db.assets,
        )..where((t) => t.id.equals(assetId))).getSingle(),
      ))!;
      expect(
        updatedAsset.balanceMinor,
        BigInt.from(46500),
      ); // 500 - 35 = 465.00

      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      await tester.runAsync(db.close);
    },
  );

  testWidgets(
    'PeriodicPage transfer with fee auto-ends to Tab 1 with both parent & fee in history, and warns on inactive account',
    (tester) async {
      final fixedNow = DateTime(2026, 3, 5, 11, 0).millisecondsSinceEpoch;
      final db = AppDatabase(NativeDatabase.memory(), nowMs: () => fixedNow);
      final ledger = LedgerService(db);
      final periodic = PeriodicService(db);

      final (skippedRuleId, transferRuleId) = (await tester.runAsync(() async {
        final fromId = await ledger.createAsset(
          commandId: 't-from',
          name: '工资储蓄',
          initial: Money.parse('5000.00'),
        );
        final toId = await ledger.createAsset(
          commandId: 't-to',
          name: '还款专户',
          initial: Money.parse('0.00'),
        );
        final hiddenId = await ledger.createAsset(
          commandId: 't-hidden',
          name: '已隐藏卡',
          initial: Money.parse('300.00'),
        );

        final skipId = await periodic.savePeriod(
          commandId: 'p-skip',
          draft: PeriodicDraft(
            recordType: RecordType.expense,
            money: Money.parse('20.00'),
            bookId: 1,
            categoryId: 1,
            assetId: hiddenId,
            periodType: PeriodType.daily,
            periodStartDate: const CalendarDate(2026, 3, 5).startOfDayMs,
          ),
        );
        await ledger.setAssetStatus(
          commandId: 'hide-card',
          assetId: hiddenId,
          status: AssetStatus.hidden,
        );

        final transId = await periodic.savePeriod(
          commandId: 'p-transfer',
          draft: PeriodicDraft(
            recordType: RecordType.transfer,
            money: Money.parse('1000.00'),
            fee: Money.parse('5.00'),
            bookId: 1,
            assetId: fromId,
            assetId2: toId,
            periodType: PeriodType.daily,
            periodStartDate: const CalendarDate(2026, 3, 5).startOfDayMs,
            periodEndDate: 1,
          ),
        );
        return (skipId, transId);
      }))!;

      await tester.pumpWidget(buildApp(const PeriodicPage(), db));
      await settle(tester);

      // Skipped rule stays in Tab 0 with warning banner & inline issue indicator
      expect(find.byKey(const Key('periodic_skipped_banner')), findsOneWidget);
      expect(find.byKey(Key('periodic_issue_$skippedRuleId')), findsOneWidget);

      // Switch to Tab 1 (已结束): transferRuleId auto-ended after generating 1 occurrence!
      await tester.tap(find.byKey(const Key('periodic_tab_1')));
      await settle(tester);

      expect(find.byKey(Key('periodic_card_$transferRuleId')), findsOneWidget);
      expect(find.textContaining('手续费 ¥5.00'), findsOneWidget);

      // Drill down into transferRuleId history: BOTH parent transfer and child fee appear!
      await tester.tap(find.byKey(Key('periodic_card_$transferRuleId')));
      await settle(tester);

      final historyPage = find.byKey(const Key('periodic_history_page'));
      expect(historyPage, findsOneWidget);
      expect(
        find.descendant(
          of: historyPage,
          matching: find.textContaining('共生成 2 笔记录'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: historyPage, matching: find.text('转账')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: historyPage, matching: find.text('手续费')),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      await tester.runAsync(db.close);
    },
  );

  testWidgets(
    'PeriodicEditorPage direct entry preselects bound account, clamps yearly Jan 31 -> Feb 29 without crash, and handles hidden account safely',
    (tester) async {
      final fixedNow = DateTime(2026, 3, 5, 14, 0).millisecondsSinceEpoch;
      final db = AppDatabase(NativeDatabase.memory(), nowMs: () => fixedNow);
      final ledger = LedgerService(db);
      final periodic = PeriodicService(db);

      final (assetId, ruleId, hiddenRuleId) = (await tester.runAsync(() async {
        final activeId = await ledger.createAsset(
          commandId: 'ed-active',
          name: '工资卡',
          initial: Money.parse('2000.00'),
        );
        final hiddenId = await ledger.createAsset(
          commandId: 'ed-hidden',
          name: '旧储蓄卡',
          initial: Money.parse('100.00'),
        );

        final rId = await periodic.savePeriod(
          commandId: 'ed-rule-active',
          draft: PeriodicDraft(
            recordType: RecordType.expense,
            money: Money.parse('88.00'),
            bookId: 1,
            categoryId: 1,
            assetId: activeId,
            periodType: PeriodType.yearly,
            periodTypeDates: const ['01-15'],
            periodStartDate: const CalendarDate(2026, 3, 5).startOfDayMs,
          ),
        );
        final hRuleId = await periodic.savePeriod(
          commandId: 'ed-rule-hidden',
          draft: PeriodicDraft(
            recordType: RecordType.expense,
            money: Money.parse('50.00'),
            bookId: 1,
            categoryId: 1,
            assetId: hiddenId,
            periodType: PeriodType.daily,
            periodStartDate: const CalendarDate(2026, 3, 5).startOfDayMs,
          ),
        );
        await ledger.setAssetStatus(
          commandId: 'ed-hide-asset',
          assetId: hiddenId,
          status: AssetStatus.hidden,
        );
        return (activeId, rId, hRuleId);
      }))!;

      // (a) Direct entry into PeriodicEditorPage(periodId: ruleId) without warming up PeriodicPage first
      await tester.pumpWidget(
        buildApp(PeriodicEditorPage(periodId: ruleId), db),
      );
      await settle(tester);

      expect(find.byKey(const Key('periodic_editor_page')), findsOneWidget);
      final assetDropdown = tester.widget<DropdownButton<int>>(
        find.byKey(const Key('periodic_asset_picker')),
      );
      expect(assetDropdown.value, assetId);
      expect(find.text('工资卡'), findsOneWidget);

      // (b) Open _showAddYearlyDateDialog, pick 31 日 in 1 月, switch 月份 to 2 月 -> clamps to 29 日(闰) without crash
      await tester.scrollUntilVisible(
        find.byKey(const Key('add_yearly_date_button')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('add_yearly_date_button')));
      await settle(tester);

      await tester.tap(find.byKey(const Key('yearly_day_picker')));
      await settle(tester);
      await tester.scrollUntilVisible(
        find.text('31 日'),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.text('31 日').last);
      await settle(tester);

      await tester.tap(find.byKey(const Key('yearly_month_picker')));
      await settle(tester);
      await tester.tap(find.text('2 月').last);
      await settle(tester);

      final yearlyDayDropdown = tester.widget<DropdownButton<int>>(
        find.byKey(const Key('yearly_day_picker')),
      );
      expect(yearlyDayDropdown.value, 29);
      expect(find.text('29 日(闰)'), findsOneWidget);

      await tester.tap(find.byKey(const Key('confirm_yearly_date_button')));
      await settle(tester);

      expect(find.byKey(const Key('yearly_date_chip_02-29')), findsOneWidget);

      // (c) Direct entry on a rule whose bound account was hidden renders fallback safely without crash
      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      await tester.pumpWidget(
        buildApp(PeriodicEditorPage(periodId: hiddenRuleId), db),
      );
      await settle(tester);

      expect(find.text('旧储蓄卡 (已停用)'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      await tester.runAsync(db.close);
    },
  );
}
