import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/app/app.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/db/seed.dart' show defaultBookId;
import 'package:tallyisle/data/debt/debt_service.dart';
import 'package:tallyisle/data/deposit/fixed_deposit_service.dart';
import 'package:tallyisle/data/installment/installment_service.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/data/periodic/periodic_service.dart';
import 'package:tallyisle/data/savings/savings_service.dart';
import 'package:tallyisle/domain/ledger/asset_json.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/debt_rules.dart';
import 'package:tallyisle/domain/rules/fixed_deposit.dart';
import 'package:tallyisle/domain/rules/periodic_records.dart';
import 'package:tallyisle/domain/rules/savings_plan.dart';
import 'package:tallyisle/features/reminder/reminder_providers.dart';
import 'package:tallyisle/platform/notifications.dart';

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump();
  }
}

Future<void> _disposeApp(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await _settle(tester);
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _goBack(WidgetTester tester) async {
  await tester.tap(find.byType(BackButton).last);
  await _settle(tester);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets('MePage Plan & Reminder section navigates to all 6 M4 pages', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    final scheduler = InMemoryReminderScheduler();
    await tester.pumpWidget(
      ProviderScope(
        retry: (_, _) => null,
        overrides: [
          databaseProvider.overrideWith((ref) async => db),
          reminderSchedulerProvider.overrideWithValue(scheduler),
        ],
        child: const TallyIsleApp(),
      ),
    );
    await _settle(tester);

    await tester.tap(find.text('我的'));
    await _settle(tester);
    expect(find.text('计划与提醒'), findsOneWidget);

    const routesToVerify = <(Key, Key)>[
      (Key('me-periodic'), Key('periodic_page')),
      (Key('me-installments'), Key('installment_page')),
      (Key('me-debts'), Key('debt_page')),
      (Key('me-savings'), Key('savings_page')),
      (Key('me-deposits'), Key('fixed_deposit_page')),
      (Key('me-reminders'), Key('reminder_page')),
    ];

    for (final (tileKey, pageKey) in routesToVerify) {
      await tester.scrollUntilVisible(
        find.byKey(tileKey),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await _settle(tester);
      await tester.tap(find.byKey(tileKey));
      await _settle(tester);

      expect(find.byKey(pageKey), findsOneWidget);

      await _goBack(tester);
      expect(find.text('我的'), findsWidgets);
    }

    await _disposeApp(tester);
  });

  testWidgets(
    'AssetsPage isolates debt section, routes debt tap to /debts/:id, '
    'wires AssetDetailPage shortcuts, and guards RecordEditor/RecordDetail',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final scheduler = InMemoryReminderScheduler();

      late int bankId;
      late int creditId;
      late int lendId;
      await tester.runAsync(() async {
        // Ensure seed runs first.
        await db.select(db.accountBooks).get();
        final ledger = LedgerService(db);
        final debtService = DebtService(db);

        bankId = await ledger.createAsset(
          commandId: 'seed-bank',
          name: '储蓄卡',
          type: AssetType.normal,
          initial: Money.parse('5000'),
        );
        creditId = await ledger.createAsset(
          commandId: 'seed-credit',
          name: '招行信用卡',
          type: AssetType.credit,
          limit: Money.parse('20000'),
          initial: Money.zero('CNY'),
          creditInfo:
              (CreditInfo()
                    ..billDay = 5
                    ..repaymentDay = 25)
                  .encode(),
        );
        final today = DateTime.now();
        final todayStartMs = DateTime(
          today.year,
          today.month,
          today.day,
        ).millisecondsSinceEpoch;
        lendId = await debtService.createDebt(
          commandId: 'seed-lend',
          subType: AssetType.debtLend,
          name: '借给阿明',
          principal: Money.parse('800'),
          bookId: defaultBookId,
          startDate: todayStartMs,
          fundingAssetId: bankId,
        );
        await debtService.createDebt(
          commandId: 'seed-borrow',
          subType: AssetType.debtBorrow,
          name: '向小王借款',
          principal: Money.parse('300'),
          bookId: defaultBookId,
          startDate: todayStartMs,
        );
      });

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            reminderSchedulerProvider.overrideWithValue(scheduler),
          ],
          child: const TallyIsleApp(),
        ),
      );
      await _settle(tester);

      // 1. RecordEditorPage excludes debt accounts from ordinary funding dropdown.
      await tester.tap(find.byKey(const Key('add-record')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('asset')));
      await _settle(tester);
      expect(find.text('储蓄卡'), findsWidgets);
      expect(find.text('招行信用卡'), findsWidgets);
      expect(find.text('借给阿明'), findsNothing);
      expect(find.text('向小王借款'), findsNothing);
      // Dismiss dropdown and go back to HomePage.
      await tester.tapAt(const Offset(10, 10));
      await _settle(tester);
      await _goBack(tester);

      // 2. RecordDetailPage renders debt account name cleanly & hides generic edit.
      await tester.tap(find.text('借出'));
      await _settle(tester);
      expect(find.text('账单详情'), findsOneWidget);
      expect(find.text('借贷项目'), findsOneWidget);
      expect(find.text('储蓄卡'), findsOneWidget);
      expect(find.text('借给阿明'), findsOneWidget);
      expect(find.byKey(const Key('edit')), findsNothing);
      await _goBack(tester);

      // 3. AssetsPage renders normal, credit, and dedicated '借入 / 借出' sections.
      await tester.tap(find.text('资产'));
      await _settle(tester);

      expect(find.text('资金账户'), findsOneWidget);
      expect(find.text('信用卡'), findsOneWidget);

      // Quick-action chips on AssetsPage.
      await tester.tap(find.byKey(const Key('assets-quick-deposits')));
      await _settle(tester);
      expect(find.byKey(const Key('fixed_deposit_page')), findsOneWidget);
      await _goBack(tester);

      // Scroll to dedicated '借入 / 借出' section and verify debt tiles.
      await tester.scrollUntilVisible(
        find.byKey(const Key('asset-向小王借款')),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await _settle(tester);
      expect(find.text('借入 / 借出'), findsOneWidget);
      expect(find.byKey(const Key('asset-借给阿明')), findsOneWidget);
      expect(find.byKey(const Key('asset-向小王借款')), findsOneWidget);
      expect(find.textContaining('借出'), findsWidgets);
      expect(find.textContaining('借入'), findsWidgets);

      // Tap debt account tile -> navigates to /debts/:id (DebtDetailPage), NOT /assets/:id!
      await tester.tap(find.byKey(const Key('asset-借给阿明')));
      await _settle(tester);
      expect(find.byKey(const Key('debt_remaining_principal')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('debt_remaining_principal')))
            .data,
        '800.00',
      );
      expect(lendId, greaterThan(0));
      await _goBack(tester);

      // 4. AssetDetailPage for normal account has '定期存款' -> /deposits?assetId=...
      await tester.scrollUntilVisible(
        find.byKey(const Key('asset-储蓄卡')),
        -150,
        scrollable: find.byType(Scrollable).first,
      );
      await _settle(tester);
      await tester.tap(find.byKey(const Key('asset-储蓄卡')));
      await _settle(tester);
      expect(bankId, greaterThan(0));
      expect(find.byKey(const Key('asset-detail-deposits')), findsOneWidget);
      expect(find.byKey(const Key('asset-detail-installments')), findsNothing);
      await tester.tap(find.byKey(const Key('asset-detail-deposits')));
      await _settle(tester);
      expect(find.byKey(const Key('fixed_deposit_page')), findsOneWidget);
      await _goBack(tester);
      await _goBack(tester);

      // 5. AssetDetailPage for credit card has '分期管理' -> /installments.
      await tester.tap(find.byKey(const Key('asset-招行信用卡')));
      await _settle(tester);
      expect(creditId, greaterThan(0));
      expect(
        find.byKey(const Key('asset-detail-installments')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('asset-detail-deposits')), findsNothing);
      await tester.tap(find.byKey(const Key('asset-detail-installments')));
      await _settle(tester);
      expect(find.byKey(const Key('installment_page')), findsOneWidget);

      await _disposeApp(tester);
    },
  );

  testWidgets(
    'TallyIsleApp runs cold-start lifecycle catch-up and handles reminder launch route',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final scheduler = InMemoryReminderScheduler(
        initialPendingLaunchRoute: '/record/new',
      );

      late int bankId;
      await tester.runAsync(() async {
        await db.select(db.accountBooks).get();
        final ledger = LedgerService(db);
        bankId = await ledger.createAsset(
          commandId: 'catchup-bank',
          name: '工资卡',
          type: AssetType.normal,
          initial: Money.parse('1000'),
        );

        final yesterday = DateTime.now().subtract(const Duration(days: 1));
        final cat = await (db.select(
          db.recordCategories,
        )..limit(1)).getSingle();
        await PeriodicService(db).savePeriod(
          commandId: 'catchup-period',
          draft: PeriodicDraft(
            recordType: RecordType.expense,
            money: Money.parse('30'),
            bookId: defaultBookId,
            categoryId: cat.id,
            assetId: bankId,
            periodType: PeriodType.daily,
            periodStartDate: DateTime(
              yesterday.year,
              yesterday.month,
              yesterday.day,
            ).millisecondsSinceEpoch,
            periodEndDate: 1, // 1 occurrence total
            remark: '自动通勤',
          ),
        );
      });

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            reminderSchedulerProvider.overrideWithValue(scheduler),
          ],
          child: const TallyIsleApp(),
        ),
      );
      await _settle(tester);

      // Pending reminder launch route opened '/record/new' (RecordEditorPage).
      expect(find.byKey(const Key('save')), findsOneWidget);

      // Cold-start catch-up generated the due periodic expense and deducted balance.
      final assetAfter = await tester.runAsync(
        () => (db.select(
          db.assets,
        )..where((t) => t.id.equals(bankId))).getSingle(),
      );
      expect(assetAfter!.balanceMinor, BigInt.from(97000));

      // Pop back to Home, then simulate tapping a live notification.
      await _goBack(tester);
      expect(find.byKey(const Key('save')), findsNothing);

      scheduler.simulateNotificationTap();
      await _settle(tester);
      expect(find.byKey(const Key('save')), findsOneWidget);

      await _disposeApp(tester);
    },
  );

  test(
    'LedgerService.deleteRecord recomputes debt principal & respects manual settle lock',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      await db.select(db.accountBooks).get();
      final ledger = LedgerService(db);
      final debtService = DebtService(db);

      final bankId = await ledger.createAsset(
        commandId: 'del-bank',
        name: '现金账户',
        type: AssetType.normal,
        initial: Money.parse('2000'),
      );

      final debtId = await debtService.createDebt(
        commandId: 'del-lend',
        subType: AssetType.debtLend,
        name: '借给老张',
        principal: Money.parse('500'),
        bookId: defaultBookId,
        startDate: DateTime(2026, 6, 1).millisecondsSinceEpoch,
        fundingAssetId: bankId,
      );

      // Bank: 2000 - 500 = 1500; Debt: active, remaining = 500.
      final repayRecordId = await debtService.recordRepayment(
        commandId: 'del-repay-full',
        debtId: debtId,
        principal: Money.parse('500'),
        operateDate: DateTime(2026, 6, 5).millisecondsSinceEpoch,
        bookId: defaultBookId,
        fundingAssetId: bankId,
      );

      var debtRow = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(debtId))).getSingle();
      var bankRow = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(bankId))).getSingle();
      expect(debtRow.status, AssetStatus.settled);
      expect(debtRow.balanceMinor, BigInt.zero);
      expect(bankRow.balanceMinor, BigInt.from(200000));

      // Delete the repayment record from generic LedgerService.deleteRecord
      // (e.g. from Home/RecordDetail). Both bank balance AND debt principal must sync!
      await ledger.deleteRecord(
        commandId: 'ledger-del-repay',
        recordId: repayRecordId,
      );

      debtRow = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(debtId))).getSingle();
      bankRow = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(bankId))).getSingle();
      expect(debtRow.status, AssetStatus.active);
      expect(debtRow.balanceMinor, BigInt.from(50000));
      expect(bankRow.balanceMinor, BigInt.from(150000));

      // Now record a partial repayment (200), then manually settle the remaining 300.
      final partialRepayId = await debtService.recordRepayment(
        commandId: 'del-repay-partial',
        debtId: debtId,
        principal: Money.parse('200'),
        operateDate: DateTime(2026, 6, 6).millisecondsSinceEpoch,
        bookId: defaultBookId,
        fundingAssetId: bankId,
      );
      await debtService.settleDebt(
        commandId: 'manual-settle-lock',
        debtId: debtId,
      );

      debtRow = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(debtId))).getSingle();
      expect(debtRow.status, AssetStatus.settled);
      expect(debtRow.balanceMinor, BigInt.zero);
      expect(LoanInfo.parse(debtRow.loanInfo).manualSettled, isTrue);

      // Deleting the partial repayment while manualSettled == true must reverse
      // bank balance (1700 -> 1500) WITHOUT reopening the manually settled debt
      // (ASYM-DM-01)!
      await ledger.deleteRecord(
        commandId: 'ledger-del-partial-under-lock',
        recordId: partialRepayId,
      );

      debtRow = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(debtId))).getSingle();
      bankRow = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(bankId))).getSingle();
      final infoAfter = LoanInfo.parse(debtRow.loanInfo);
      expect(debtRow.status, AssetStatus.settled);
      expect(debtRow.balanceMinor, BigInt.zero);
      expect(infoAfter.manualSettled, isTrue);
      expect(infoAfter.settledSnapshotMinor, BigInt.from(30000));
      expect(
        infoAfter.currencyPositions.single.principalBalanceMinor,
        BigInt.from(50000),
      );
      expect(bankRow.balanceMinor, BigInt.from(150000));
    },
  );

  test(
    'LedgerService.deleteAsset rejects accounts referenced by M4 modules',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      await db.select(db.accountBooks).get();
      final ledger = LedgerService(db);
      final cat = await (db.select(db.recordCategories)..limit(1)).getSingle();

      // 1. Periodic rule guard.
      final periodicAssetId = await ledger.createAsset(
        commandId: 'guard-periodic-asset',
        name: '周期卡',
        type: AssetType.normal,
        initial: Money.parse('100'),
      );
      final periodId = await PeriodicService(db).savePeriod(
        commandId: 'guard-period-create',
        draft: PeriodicDraft(
          recordType: RecordType.expense,
          money: Money.parse('10'),
          bookId: defaultBookId,
          categoryId: cat.id,
          assetId: periodicAssetId,
          periodType: PeriodType.monthly,
          periodTypeDates: const ['15'],
          periodStartDate: DateTime(2027, 1, 15).millisecondsSinceEpoch,
        ),
      );
      await expectLater(
        ledger.deleteAsset(
          commandId: 'try-del-periodic-asset',
          assetId: periodicAssetId,
        ),
        throwsA(isA<Failure>()),
      );
      await PeriodicService(
        db,
      ).deletePeriod(commandId: 'cleanup-period', periodId: periodId);
      await ledger.deleteAsset(
        commandId: 'del-periodic-asset-ok',
        assetId: periodicAssetId,
      );

      // 2. Installment plan guard.
      final instAssetId = await ledger.createAsset(
        commandId: 'guard-inst-asset',
        name: '分期信用卡',
        type: AssetType.credit,
        limit: Money.parse('10000'),
        initial: Money.zero('CNY'),
        creditInfo:
            (CreditInfo()
                  ..billDay = 10
                  ..repaymentDay = 28)
                .encode(),
      );
      final instId = await InstallmentService(db).createInstallment(
        commandId: 'guard-inst-create',
        draft: InstallmentDraft(
          name: '买手机',
          catId: cat.id,
          principal: Money.parse('3000'),
          periods: 3,
          charge: Money.zero('CNY'),
          startDateMs: DateTime(2027, 2, 10).millisecondsSinceEpoch,
          assetId: instAssetId,
          bookId: defaultBookId,
        ),
      );
      await expectLater(
        ledger.deleteAsset(
          commandId: 'try-del-inst-asset',
          assetId: instAssetId,
        ),
        throwsA(isA<Failure>()),
      );
      await InstallmentService(
        db,
      ).deleteInstallment(commandId: 'cleanup-inst', installmentId: instId);
      await ledger.deleteAsset(
        commandId: 'del-inst-asset-ok',
        assetId: instAssetId,
      );

      // 3. Savings plan guard.
      final savAssetId = await ledger.createAsset(
        commandId: 'guard-sav-asset',
        name: '心愿金库',
        type: AssetType.normal,
        initial: Money.zero('CNY'),
      );
      final planId = await SavingsService(db).savePlan(
        commandId: 'guard-sav-create',
        draft: SavingsPlanDraft(
          name: '旅行基金',
          planType: SavingsPlanType.free,
          startDateMs: DateTime(2026, 6, 1).millisecondsSinceEpoch,
          customPlanMoneyMinor: BigInt.from(500000),
          toAssetId: savAssetId,
          bookId: defaultBookId,
        ),
      );
      await expectLater(
        ledger.deleteAsset(commandId: 'try-del-sav-asset', assetId: savAssetId),
        throwsA(isA<Failure>()),
      );
      await SavingsService(
        db,
      ).deletePlan(commandId: 'cleanup-sav', planId: planId);
      await ledger.deleteAsset(
        commandId: 'del-sav-asset-ok',
        assetId: savAssetId,
      );

      // 4. Fixed deposit guard (Mode B2: zero ledger records, non-empty fixed_deposit_info).
      final depAssetId = await ledger.createAsset(
        commandId: 'guard-dep-asset',
        name: '定存存折',
        type: AssetType.normal,
        initial: Money.parse('10000'),
      );
      final depIdx = await FixedDepositService(db).createDeposit(
        commandId: 'guard-dep-create',
        draft: FixedDepositDraft(
          targetAssetId: depAssetId,
          principal: Money.parse('10000'),
          annualRate: DecimalValue.parse('2.15'),
          periodUnit: DepositPeriodUnit.year,
          periodCount: 1,
          depositDate: DateTime(2026, 6, 1).millisecondsSinceEpoch,
          fromAssetId: noRef,
          updateAssetBalance: false,
        ),
      );
      await expectLater(
        ledger.deleteAsset(commandId: 'try-del-dep-asset', assetId: depAssetId),
        throwsA(isA<Failure>()),
      );
      await FixedDepositService(db).deleteDeposit(
        commandId: 'cleanup-dep',
        assetId: depAssetId,
        index: depIdx,
      );
      await ledger.deleteAsset(
        commandId: 'del-dep-asset-ok',
        assetId: depAssetId,
      );
    },
  );
}
