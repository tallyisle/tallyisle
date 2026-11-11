import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/data/savings/savings_service.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/savings_plan.dart';
import 'package:tallyisle/features/savings/savings_editor_page.dart';
import 'package:tallyisle/features/savings/savings_page.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  BigInt yuan(int whole, [int cents = 0]) => BigInt.from(whole * 100 + cents);

  Widget buildApp(Widget child, AppDatabase db) => ProviderScope(
    retry: (_, _) => null,
    overrides: [databaseProvider.overrideWith((ref) async => db)],
    child: MaterialApp(home: child),
  );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  (AppDatabase, Future<void> Function()) openTestDb(WidgetTester tester) {
    final db = AppDatabase(NativeDatabase.memory());
    var closed = false;
    Future<void> closeNow() async {
      if (closed) return;
      closed = true;
      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(db.close);
    }

    addTearDown(() async {
      if (!closed) {
        closed = true;
        await tester.runAsync(db.close);
      }
    });
    return (db, closeNow);
  }

  testWidgets(
    'Templates preview (365d=66795, 52w=13780), slot check-in -> auto-archive -> cancel deposit -> auto-unarchive (DR-SP-05)',
    (tester) async {
      final (db, closeCleanly) = openTestDb(tester);
      final ledger = LedgerService(db);

      final fromId = await ledger.createAsset(
        commandId: 'init-a1',
        name: '工资卡',
        initial: Money.minor(yuan(500)),
      );
      final toId = await ledger.createAsset(
        commandId: 'init-a2',
        name: '存钱罐',
        initial: Money.minor(BigInt.zero),
      );

      final service = SavingsService(db);
      final today = LocalCalendarDate.fromDateTime(DateTime.now());
      final twoDayPlanId = await service.savePlan(
        commandId: 'seed-2d',
        draft: SavingsPlanDraft(
          name: '双日冲刺',
          planType: SavingsPlanType.fixed,
          cycleType: SavingsCycleType.daily,
          startDateMs: today.startOfDayMs,
          endDateMs: today.plusDays(1).startOfDayMs,
          startMoneyMinor: yuan(100),
          fromAssetId: fromId,
          toAssetId: toId,
        ),
      );

      await tester.pumpWidget(buildApp(const SavingsPage(), db));
      await settle(tester);

      expect(find.byKey(const Key('savings_page')), findsOneWidget);
      expect(find.text('双日冲刺'), findsOneWidget);

      // Open Editor via FAB and verify quick templates 365d & 52w
      await tester.tap(find.byKey(const Key('add_savings_plan_fab')));
      await settle(tester);

      expect(find.byKey(const Key('savings_editor_page')), findsOneWidget);
      await tester.tap(find.byKey(const Key('template_365_days')));
      await tester.pump();
      expect(find.textContaining('66795.00'), findsWidgets);

      await tester.tap(find.byKey(const Key('template_52_weeks')));
      await tester.pump();
      expect(find.textContaining('13780.00'), findsWidgets);

      // Back to SavingsPage
      await tester.tap(find.byType(BackButton));
      await settle(tester);

      // Tap the 2-day plan to open SavingsDetailPage
      await tester.tap(find.byKey(Key('savings_plan_card_$twoDayPlanId')));
      await settle(tester);

      expect(find.byKey(const Key('savings_detail_page')), findsOneWidget);

      // Check in slot 0 and slot 1 -> reaches 200.00 -> auto-archives!
      await tester.tap(find.byKey(const Key('checkin_slot_button_0')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('confirm_slot_checkin_button')));
      await settle(tester);

      await tester.tap(find.byKey(const Key('checkin_slot_button_1')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('confirm_slot_checkin_button')));
      await settle(tester);

      expect(find.text('已归档'), findsOneWidget);

      // Cancel slot 1 deposit -> DR-SP-05 auto-unarchives back to 进行中!
      await tester.tap(find.byKey(const Key('cancel_slot_deposit_1')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('confirm_cancel_deposit_button')));
      await settle(tester);

      expect(find.text('进行中'), findsOneWidget);

      final fromRow = await tester.runAsync(
        () => (db.select(
          db.assets,
        )..where((t) => t.id.equals(fromId))).getSingle(),
      );
      final toRow = await tester.runAsync(
        () =>
            (db.select(db.assets)..where((t) => t.id.equals(toId))).getSingle(),
      );
      expect(fromRow!.balanceMinor, yuan(400));
      expect(toRow!.balanceMinor, yuan(100));

      await closeCleanly();
    },
  );

  testWidgets(
    'Free plan cumulative target back-calculation (SP-23) and out-of-schedule historical section (CE-SP-07)',
    (tester) async {
      final (db, closeCleanly) = openTestDb(tester);
      final service = SavingsService(db);

      // 1. Free plan for SP-23 (target 1000)
      final freePlanId = await service.savePlan(
        commandId: 'free-p1',
        draft: SavingsPlanDraft(
          name: '自由小金库',
          planType: SavingsPlanType.free,
          startDateMs: const LocalCalendarDate(2026, 3, 1).startOfDayMs,
          customPlanMoneyMinor: yuan(1000),
        ),
      );

      // 2. Scheduled plan with an out-of-schedule historical deposit (CE-SP-07)
      final schedPlanId = await service.savePlan(
        commandId: 'sched-p2',
        draft: SavingsPlanDraft(
          name: '改期计划',
          planType: SavingsPlanType.fixed,
          cycleType: SavingsCycleType.daily,
          startDateMs: const LocalCalendarDate(2026, 3, 1).startOfDayMs,
          endDateMs: const LocalCalendarDate(2026, 3, 2).startOfDayMs,
          startMoneyMinor: yuan(50),
        ),
      );
      await service.checkIn(
        commandId: 'hist-checkin',
        planId: schedPlanId,
        amountMinor: yuan(50),
        recordDateMs: DateTime(2026, 3, 1, 9, 0).millisecondsSinceEpoch,
        remark: '改期前记录',
      );
      // Edit start/end date to 2026-03-05..2026-03-06 so 2026-03-01 is now out-of-schedule!
      await service.savePlan(
        commandId: 'sched-p2-edit',
        planId: schedPlanId,
        draft: SavingsPlanDraft(
          name: '改期计划',
          planType: SavingsPlanType.fixed,
          cycleType: SavingsCycleType.daily,
          startDateMs: const LocalCalendarDate(2026, 3, 5).startOfDayMs,
          endDateMs: const LocalCalendarDate(2026, 3, 6).startOfDayMs,
          startMoneyMinor: yuan(50),
        ),
      );

      await tester.pumpWidget(buildApp(const SavingsPage(), db));
      await settle(tester);

      // Test SP-23 on Free Plan
      await tester.tap(find.byKey(Key('savings_plan_card_$freePlanId')));
      await settle(tester);

      // Deposit 300.00 directly
      await tester.tap(find.byKey(const Key('free_plan_checkin_button')));
      await settle(tester);
      await tester.enterText(
        find.byKey(const Key('free_amount_input')),
        '300.00',
      );
      await tester.tap(find.byKey(const Key('confirm_free_checkin_button')));
      await settle(tester);

      expect(find.text('¥300.00'), findsWidgets);

      // Deposit via cumulative target 500.00 -> previews 200.00 -> saved becomes 500.00!
      await tester.tap(find.byKey(const Key('free_plan_checkin_button')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('free_mode_cumulative')));
      await settle(tester);
      await tester.enterText(
        find.byKey(const Key('free_cumulative_input')),
        '500.00',
      );
      await settle(tester);
      expect(find.textContaining('200.00'), findsWidgets);
      await tester.tap(find.byKey(const Key('confirm_free_checkin_button')));
      await settle(tester);

      expect(find.text('¥500.00'), findsWidgets);

      // Go back to SavingsPage and open schedPlanId to verify CE-SP-07 out-of-schedule section!
      await tester.tap(find.byType(BackButton));
      await settle(tester);

      await tester.tap(find.byKey(Key('savings_plan_card_$schedPlanId')));
      await settle(tester);

      await tester.ensureVisible(
        find.byKey(const Key('cancel_out_of_schedule_1')),
      );
      await settle(tester);
      expect(find.byKey(const Key('out_of_schedule_section')), findsOneWidget);
      expect(find.textContaining('改期前记录'), findsOneWidget);

      // Cancel the out-of-schedule deposit directly from the UI!
      await tester.tap(find.byKey(const Key('cancel_out_of_schedule_1')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('confirm_cancel_deposit_button')));
      await settle(tester);

      expect(find.byKey(const Key('out_of_schedule_section')), findsNothing);

      await closeCleanly();
    },
  );

  testWidgets(
    'Manual archive/unarchive, missing-rate warning banner (CE-SP-08), delete plan with rollback, and direct editor cold-stream safety',
    (tester) async {
      final (db, closeCleanly) = openTestDb(tester);
      final ledger = LedgerService(db);
      final service = SavingsService(db);

      final fromId = await ledger.createAsset(
        commandId: 'del-a1',
        name: '主卡',
        initial: Money.minor(yuan(1000)),
      );
      final toId = await ledger.createAsset(
        commandId: 'del-a2',
        name: '小金库',
        initial: Money.minor(BigInt.zero),
      );
      final eurToId = await ledger.createAsset(
        commandId: 'del-eur',
        name: '欧元罐',
        initial: Money.minor(yuan(100), 'EUR'),
        currency: 'EUR',
      );

      final cnyPlanId = await service.savePlan(
        commandId: 'cny-plan',
        draft: SavingsPlanDraft(
          name: '应急金',
          planType: SavingsPlanType.free,
          startDateMs: const LocalCalendarDate(2026, 3, 1).startOfDayMs,
          customPlanMoneyMinor: yuan(1000),
          fromAssetId: fromId,
          toAssetId: toId,
        ),
      );
      await service.checkIn(
        commandId: 'cny-ci-1',
        planId: cnyPlanId,
        amountMinor: yuan(200),
        recordDateMs: DateTime(2026, 3, 2, 10, 0).millisecondsSinceEpoch,
      );

      // Foreign EUR plan without EUR exchange rate in `currency` table -> missing rate banner!
      final eurPlanId = await service.savePlan(
        commandId: 'eur-plan',
        draft: SavingsPlanDraft(
          name: '欧洲旅行',
          planType: SavingsPlanType.free,
          startDateMs: const LocalCalendarDate(2026, 3, 1).startOfDayMs,
          customPlanMoneyMinor: yuan(500),
          toAssetId: eurToId,
        ),
      );
      await service.checkIn(
        commandId: 'eur-ci-1',
        planId: eurPlanId,
        amountMinor: yuan(80),
        recordDateMs: DateTime(2026, 3, 2, 11, 0).millisecondsSinceEpoch,
      );
      // Bind CNY `fromId` -> EUR `eurToId`: cross-currency check-in without rate halts cleanly
      await service.savePlan(
        commandId: 'eur-plan-bind-from',
        planId: eurPlanId,
        draft: SavingsPlanDraft(
          name: '欧洲旅行',
          planType: SavingsPlanType.free,
          startDateMs: const LocalCalendarDate(2026, 3, 1).startOfDayMs,
          customPlanMoneyMinor: yuan(500),
          fromAssetId: fromId,
          toAssetId: eurToId,
        ),
      );

      await tester.pumpWidget(buildApp(const SavingsPage(), db));
      await settle(tester);

      // Verify CE-SP-08 missing rate banner & CNY-only total (¥200.00, NOT 280.00!)
      expect(
        find.byKey(const Key('savings_missing_rate_banner')),
        findsOneWidget,
      );
      expect(find.text('¥200.00'), findsOneWidget);

      // Open CNY plan detail -> manually archive -> restore -> delete with rollback
      await tester.tap(find.byKey(Key('savings_plan_card_$cnyPlanId')));
      await settle(tester);

      await tester.tap(find.byKey(const Key('toggle_archive_plan_button')));
      await settle(tester);
      await tester.tap(find.text('确定'));
      await settle(tester);
      expect(find.text('已归档'), findsOneWidget);

      // Restore back to active
      await tester.tap(find.byKey(const Key('toggle_archive_plan_button')));
      await settle(tester);
      await tester.tap(find.text('确定'));
      await settle(tester);
      expect(find.text('进行中'), findsOneWidget);

      // Delete plan AND check "同时删除关联转账流水并回滚账户余额"
      await tester.tap(find.byKey(const Key('delete_savings_plan_button')));
      await settle(tester);
      await tester.tap(
        find.byKey(const Key('delete_linked_transfers_checkbox')),
      );
      await settle(tester);
      await tester.tap(find.byKey(const Key('confirm_delete_plan_button')));
      await settle(tester);

      expect(find.byKey(const Key('savings_page')), findsOneWidget);
      expect(find.text('应急金'), findsNothing);

      final fromAfter = await tester.runAsync(
        () => (db.select(
          db.assets,
        )..where((t) => t.id.equals(fromId))).getSingle(),
      );
      final toAfter = await tester.runAsync(
        () =>
            (db.select(db.assets)..where((t) => t.id.equals(toId))).getSingle(),
      );
      expect(fromAfter!.balanceMinor, yuan(1000));
      expect(toAfter!.balanceMinor, BigInt.zero);

      // Hide `fromId` and mount `SavingsEditorPage` directly on `eurPlanId` (cold stream)
      await tester.runAsync(
        () => ledger.setAssetStatus(
          commandId: 'hide-from',
          assetId: fromId,
          status: AssetStatus.hidden,
        ),
      );
      await tester.pumpWidget(
        buildApp(SavingsEditorPage(planId: eurPlanId), db),
      );
      await settle(tester);
      expect(find.byKey(const Key('savings_editor_page')), findsOneWidget);
      expect(find.text('主卡 (CNY) (已停用)'), findsOneWidget);
      expect(find.textContaining('EUR'), findsWidgets);

      await closeCleanly();
    },
  );
}
