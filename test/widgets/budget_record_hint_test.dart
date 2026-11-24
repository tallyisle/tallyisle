import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/data/budget/budget_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/settings/app_settings_service.dart';
import 'package:tallyisle/domain/rules/app_settings_rules.dart';
import 'package:tallyisle/domain/rules/billing_period.dart';
import 'package:tallyisle/domain/rules/budget_rules.dart';
import 'package:tallyisle/features/budget/budget_widgets.dart';
import 'package:tallyisle/features/settings/settings_page.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  (AppDatabase, Future<void> Function()) openTestDb(WidgetTester tester) {
    final db = AppDatabase(NativeDatabase.memory());
    var closed = false;
    Future<void> closeCleanly() async {
      if (closed) return;
      closed = true;
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(db.close);
    }

    addTearDown(() async {
      if (!closed) {
        closed = true;
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(db.close);
      }
    });
    return (db, closeCleanly);
  }

  group('AppSettings record budget hint JSON & rules', () {
    test('defaults and round-trip JSON serialization', () {
      expect(AppSettings.defaults.showRecordBudgetHint, isTrue);
      expect(
        AppSettings.defaults.recordBudgetHintMode,
        RecordBudgetHintMode.auto,
      );

      final custom = AppSettings.defaults.copyWith(
        showRecordBudgetHint: false,
        recordBudgetHintMode: RecordBudgetHintMode.yearly,
      );
      expect(custom.validated(), custom);
      expect(AppSettings.parse(custom.encode()), custom);
      expect(AppSettings.parse(custom.encode()).hashCode, custom.hashCode);
      expect(custom == AppSettings.defaults, isFalse);
    });

    test('legacy JSON without new keys defaults to true and auto', () {
      const legacyJson =
          '{"showBalanceChangeRecordOnHome":true,"showHomeAssetSummaryBanner":false,"showHomeBudgetCard":true,"defaultRecordType":1,"themeMode":"dark","themeSeedHex":"1565C0"}';
      final parsed = AppSettings.parse(legacyJson);
      expect(parsed.showRecordBudgetHint, isTrue);
      expect(parsed.recordBudgetHintMode, RecordBudgetHintMode.auto);
      expect(parsed.showBalanceChangeRecordOnHome, isTrue);
      expect(parsed.defaultRecordType, 1);
      expect(parsed.themeMode, AppThemeModePreference.dark);
    });

    test('RecordBudgetHintMode.fromCode and corrupt JSON guards', () {
      expect(RecordBudgetHintMode.fromCode(null), RecordBudgetHintMode.auto);
      expect(RecordBudgetHintMode.fromCode(''), RecordBudgetHintMode.auto);
      expect(RecordBudgetHintMode.fromCode('auto'), RecordBudgetHintMode.auto);
      expect(
        RecordBudgetHintMode.fromCode('monthly'),
        RecordBudgetHintMode.monthly,
      );
      expect(
        RecordBudgetHintMode.fromCode('yearly'),
        RecordBudgetHintMode.yearly,
      );
      expect(
        () => RecordBudgetHintMode.fromCode('weekly'),
        throwsA(
          isA<Failure>().having((f) => f.code, 'code', FailureCode.corruptData),
        ),
      );
      expect(
        () => AppSettings.parse('{"showRecordBudgetHint":"yes"}'),
        throwsA(
          isA<Failure>().having((f) => f.code, 'code', FailureCode.corruptData),
        ),
      );
      expect(
        () => AppSettings.parse('{"recordBudgetHintMode":123}'),
        throwsA(
          isA<Failure>().having((f) => f.code, 'code', FailureCode.corruptData),
        ),
      );
      expect(
        () => AppSettings.parse('{"recordBudgetHintMode":"invalid"}'),
        throwsA(
          isA<Failure>().having((f) => f.code, 'code', FailureCode.corruptData),
        ),
      );
    });
  });

  group('RecordBudgetHintBar decoupling & SettingsPage controls', () {
    testWidgets(
      '1) Monthly budget set + yearly unset + Stats/Budget mode yearly still shows monthly hint',
      (tester) async {
        final (db, closeCleanly) = openTestDb(tester);
        final now = DateTime.now();
        final monthPeriod = BillingPeriod.containing(now, 1);
        final service = BudgetService(db);

        await tester.runAsync(() async {
          await service.upsertTotalBudget(
            commandId: 'hint-1-tot',
            bookId: 1,
            section: monthPeriod.monthlySection,
            amountMinor: BigInt.from(300000),
          );
          await service.upsertCategoryBudget(
            commandId: 'hint-1-cat1',
            bookId: 1,
            section: monthPeriod.monthlySection,
            categoryId: 1,
            budgetType: BudgetTypeCode.expenseCategory,
            amountMinor: BigInt.from(80000),
          );
          await service.setBudgetMode(
            commandId: 'hint-1-mode-yearly',
            bookId: 1,
            mode: BudgetMode.yearly,
          );
        });

        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [databaseProvider.overrideWith((ref) async => db)],
            child: MaterialApp(
              home: Scaffold(
                body: Column(
                  children: [
                    RecordBudgetHintBar(
                      bookId: 1,
                      recordTime: monthPeriod.startMs + 1000,
                      categoryId: 1,
                      excludeBudget: false,
                    ),
                    RecordBudgetHintBar(
                      bookId: 1,
                      recordTime: monthPeriod.startMs + 1000,
                      categoryId: 2,
                      excludeBudget: false,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await settle(tester);

        expect(find.text('月分类预算: 剩余 ¥800.00 (0.0%)'), findsOneWidget);
        expect(find.text('月总预算: 剩余 ¥3000.00 (0.0%)'), findsOneWidget);

        await closeCleanly();
      },
    );

    testWidgets(
      '2) Yearly budget set + monthly unset + Stats/Budget mode monthly shows yearly hint via auto fallback',
      (tester) async {
        final (db, closeCleanly) = openTestDb(tester);
        final now = DateTime.now();
        final monthPeriod = BillingPeriod.containing(now, 1);
        final yearPeriod = BillingPeriod.containingYear(now, 1);
        final service = BudgetService(db);

        await tester.runAsync(() async {
          await service.upsertTotalBudget(
            commandId: 'hint-2-ytot',
            bookId: 1,
            section: yearPeriod.yearlySection,
            amountMinor: BigInt.from(5000000),
          );
          await service.upsertCategoryBudget(
            commandId: 'hint-2-ycat1',
            bookId: 1,
            section: yearPeriod.yearlySection,
            categoryId: 1,
            budgetType: BudgetTypeCode.expenseCategory,
            amountMinor: BigInt.from(1200000),
          );
          await service.setBudgetMode(
            commandId: 'hint-2-mode-monthly',
            bookId: 1,
            mode: BudgetMode.monthly,
          );
        });

        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [databaseProvider.overrideWith((ref) async => db)],
            child: MaterialApp(
              home: Scaffold(
                body: Column(
                  children: [
                    RecordBudgetHintBar(
                      bookId: 1,
                      recordTime: monthPeriod.startMs + 1000,
                      categoryId: 1,
                      excludeBudget: false,
                    ),
                    RecordBudgetHintBar(
                      bookId: 1,
                      recordTime: monthPeriod.startMs + 1000,
                      categoryId: 2,
                      excludeBudget: false,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await settle(tester);

        expect(find.text('年分类预算: 剩余 ¥12000.00 (0.0%)'), findsOneWidget);
        expect(find.text('年总预算: 剩余 ¥50000.00 (0.0%)'), findsOneWidget);

        await closeCleanly();
      },
    );

    testWidgets(
      '3 & 4) SettingsPage segmented mode switching, monthly-only hide when only yearly exists, and visibility switch toggle',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(600, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final (db, closeCleanly) = openTestDb(tester);
        final now = DateTime.now();
        final monthPeriod = BillingPeriod.containing(now, 1);
        final yearPeriod = BillingPeriod.containingYear(now, 1);
        final budgetService = BudgetService(db);
        final settingsService = AppSettingsService(db);

        late int monthlyBudgetId;
        await tester.runAsync(() async {
          monthlyBudgetId = await budgetService.upsertTotalBudget(
            commandId: 'hint-3-mtot',
            bookId: 1,
            section: monthPeriod.monthlySection,
            amountMinor: BigInt.from(200000),
          );
          await budgetService.upsertTotalBudget(
            commandId: 'hint-3-ytot',
            bookId: 1,
            section: yearPeriod.yearlySection,
            amountMinor: BigInt.from(3600000),
          );
        });

        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [databaseProvider.overrideWith((ref) async => db)],
            child: MaterialApp(
              home: Column(
                children: [
                  RecordBudgetHintBar(
                    bookId: 1,
                    recordTime: monthPeriod.startMs + 1000,
                    categoryId: 2,
                    excludeBudget: false,
                  ),
                  const Expanded(child: SettingsPage()),
                ],
              ),
            ),
          ),
        );
        await settle(tester);

        final modeSegmented = find.byKey(
          const Key('setting_record_budget_mode_segmented'),
        );
        final hintSwitch = find.byKey(
          const Key('setting_show_record_budget_hint_switch'),
        );

        // Default is auto -> prefers monthly when both exist
        expect(hintSwitch, findsOneWidget);
        expect(modeSegmented, findsOneWidget);
        expect(find.text('月总预算: 剩余 ¥2000.00 (0.0%)'), findsOneWidget);

        // Switch to 年预算 -> shows yearly total budget
        await tester.tap(
          find.descendant(of: modeSegmented, matching: find.text('年预算')),
        );
        await settle(tester);
        expect(find.text('年总预算: 剩余 ¥36000.00 (0.0%)'), findsOneWidget);

        // Switch to 月预算 -> shows monthly total budget
        await tester.tap(
          find.descendant(of: modeSegmented, matching: find.text('月预算')),
        );
        await settle(tester);
        expect(find.text('月总预算: 剩余 ¥2000.00 (0.0%)'), findsOneWidget);

        // Switch back to 自动 -> prefers monthly
        await tester.tap(
          find.descendant(of: modeSegmented, matching: find.text('自动')),
        );
        await settle(tester);
        expect(find.text('月总预算: 剩余 ¥2000.00 (0.0%)'), findsOneWidget);

        // Toggle visibility switch OFF -> hides hint bar AND hides segmented mode selector
        await tester.tap(hintSwitch);
        await settle(tester);
        expect(find.byKey(const Key('record_budget_hint_bar')), findsNothing);
        expect(modeSegmented, findsNothing);

        final persistedOff = await tester.runAsync(settingsService.getSettings);
        expect(persistedOff!.showRecordBudgetHint, isFalse);

        // Toggle visibility switch back ON -> restores both
        await tester.tap(hintSwitch);
        await settle(tester);
        expect(find.byKey(const Key('record_budget_hint_bar')), findsOneWidget);
        expect(modeSegmented, findsOneWidget);

        // Delete monthly budget so only yearly remains:
        // auto shows yearly, selecting 月预算 hides hint cleanly
        await tester.runAsync(() async {
          await budgetService.deleteBudget(
            commandId: 'hint-3-del-mtot',
            budgetId: monthlyBudgetId,
          );
        });
        await settle(tester);
        expect(find.text('年总预算: 剩余 ¥36000.00 (0.0%)'), findsOneWidget);

        await tester.tap(
          find.descendant(of: modeSegmented, matching: find.text('月预算')),
        );
        await settle(tester);
        expect(find.byKey(const Key('record_budget_hint_bar')), findsNothing);

        await closeCleanly();
      },
    );

    testWidgets(
      'SettingsPage renders record budget hint controls with zero overflow at 360x640 and 1.2x text scale',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(360, 640));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final (db, closeCleanly) = openTestDb(tester);

        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [databaseProvider.overrideWith((ref) async => db)],
            child: MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(1.2)),
                child: child!,
              ),
              home: const SettingsPage(),
            ),
          ),
        );
        await settle(tester);

        expect(
          find.byKey(const Key('setting_show_record_budget_hint_switch')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('setting_record_budget_mode_segmented')),
          findsOneWidget,
        );
        expect(find.text('自动：优先显示月预算，未设月预算时自动显示年预算'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await closeCleanly();
      },
    );
  });
}
