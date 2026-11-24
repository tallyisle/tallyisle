import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/app/adaptive.dart';
import 'package:tallyisle/app/app.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/features/budget/budget_page.dart';
import 'package:tallyisle/features/calendar/calendar_page.dart';
import 'package:tallyisle/features/reminder/reminder_providers.dart';
import 'package:tallyisle/features/stats/annual_report_page.dart';
import 'package:tallyisle/features/stats/category_stats_page.dart';
import 'package:tallyisle/features/stats/tag_stats_page.dart';
import 'package:tallyisle/platform/notifications.dart';

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
}

void _expectNoDropdownArrowInside(Finder triggerFinder) {
  expect(triggerFinder, findsOneWidget);
  expect(
    find.descendant(
      of: triggerFinder,
      matching: find.byIcon(Icons.arrow_drop_down),
    ),
    findsNothing,
  );
  expect(
    find.descendant(
      of: triggerFinder,
      matching: find.byIcon(Icons.arrow_drop_down_rounded),
    ),
    findsNothing,
  );
  expect(
    find.descendant(
      of: triggerFinder,
      matching: find.byIcon(Icons.arrow_drop_up_rounded),
    ),
    findsNothing,
  );
}

Future<void> _verifyYearMonthPickerOpensAndToggles(
  WidgetTester tester,
  Finder triggerFinder,
) async {
  _expectNoDropdownArrowInside(triggerFinder);

  await tester.tap(triggerFinder);
  await _settle(tester);
  expect(tester.takeException(), isNull);

  final toggleFinder = find.byKey(const Key('ym-picker-toggle-year-grid'));
  _expectNoDropdownArrowInside(toggleFinder);

  final nowYear = DateTime.now().year;
  await tester.tap(toggleFinder);
  await _settle(tester);
  expect(find.byKey(Key('ym-picker-year-$nowYear')), findsOneWidget);
  _expectNoDropdownArrowInside(toggleFinder);

  await tester.tap(toggleFinder);
  await _settle(tester);
  expect(find.byKey(const Key('ym-picker-month-1')), findsOneWidget);

  // Close dialog by picking month 1.
  await tester.tap(find.byKey(const Key('ym-picker-month-1')));
  await _settle(tester);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets(
    'Home switchers (mobile, medium desktop, expanded desktop) and YearMonthPickerDialog have no dropdown/dropup arrows while keeping tap actions and book-picker arrow',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final reminderScheduler = InMemoryReminderScheduler();
      addTearDown(() async {
        await tester.runAsync(reminderScheduler.dispose);
        await tester.runAsync(db.close);
      });
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      var forceDesktop = false;
      late StateSetter setMode;

      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;

      try {
        await tester.pumpWidget(
          StatefulBuilder(
            builder: (context, setState) {
              setMode = setState;
              return ProviderScope(
                key: ValueKey(forceDesktop),
                retry: (_, _) => null,
                overrides: [
                  databaseProvider.overrideWith((ref) async => db),
                  reminderSchedulerProvider.overrideWithValue(
                    reminderScheduler,
                  ),
                  desktopModeOverrideProvider.overrideWith(
                    (ref) => forceDesktop,
                  ),
                ],
                child: const TallyIsleApp(),
              );
            },
          ),
        );
        await _settle(tester);

        // AppBar book-picker MUST retain Icons.arrow_drop_down.
        final bookPicker = find.byKey(const Key('book-picker'));
        expect(bookPicker, findsOneWidget);
        expect(
          find.descendant(
            of: bookPicker,
            matching: find.byIcon(Icons.arrow_drop_down),
          ),
          findsOneWidget,
        );

        // 1. Mobile _HomeBody switcher.
        await _verifyYearMonthPickerOpensAndToggles(
          tester,
          find.byKey(const Key('home-period-picker-trigger')),
        );

        // 2. Desktop medium (_DesktopHomeBody non-expanded).
        tester.view.physicalSize = const Size(900, 700);
        setMode(() => forceDesktop = true);
        await _settle(tester);
        await _verifyYearMonthPickerOpensAndToggles(
          tester,
          find.byKey(const Key('home-period-picker-trigger')),
        );

        // 3. Desktop expanded (_DesktopExpandedOverviewHeader).
        tester.view.physicalSize = const Size(1280, 800);
        await _settle(tester);
        await _verifyYearMonthPickerOpensAndToggles(
          tester,
          find.byKey(const Key('home-period-picker-trigger')),
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester);
        await tester.pump(const Duration(seconds: 1));
      }
    },
  );

  testWidgets(
    'Calendar, Budget, CategoryStats, TagStats, and AnnualReport switchers have no dropdown arrows and still open pickers',
    (tester) async {
      tester.view.physicalSize = const Size(420, 840);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(() async {
        await tester.runAsync(db.close);
      });

      Future<void> pumpPage(Widget page) async {
        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [
              databaseProvider.overrideWith((ref) async => db),
              desktopModeOverrideProvider.overrideWithValue(false),
            ],
            child: DesktopAdaptiveScope(
              isDesktop: false,
              child: MaterialApp(home: page),
            ),
          ),
        );
        await _settle(tester);
      }

      try {
        // 4. CalendarPage
        await pumpPage(const CalendarPage());
        await _verifyYearMonthPickerOpensAndToggles(
          tester,
          find.byKey(const Key('calendar-period-picker-trigger')),
        );

        // 5. BudgetPage
        await pumpPage(const BudgetPage());
        await _verifyYearMonthPickerOpensAndToggles(
          tester,
          find.byKey(const Key('budget-period-picker-trigger')),
        );

        // 6. CategoryStatsPage
        await pumpPage(const CategoryStatsPage());
        await _verifyYearMonthPickerOpensAndToggles(
          tester,
          find.byKey(const Key('category-stats-period-picker-trigger')),
        );

        // 7. TagRankingsPage (tag_stats_page.dart)
        await pumpPage(const TagRankingsPage());
        await tester.tap(find.byKey(const Key('tag-rankings-mode-month')));
        await _settle(tester);
        await _verifyYearMonthPickerOpensAndToggles(
          tester,
          find.byKey(const Key('tag-stats-period-picker-trigger')),
        );

        // 8. AnnualReportPage
        await pumpPage(const AnnualReportPage());
        final yearTrigger = find.byKey(
          const Key('annual-report-year-picker-trigger'),
        );
        _expectNoDropdownArrowInside(yearTrigger);
        await tester.tap(yearTrigger);
        await _settle(tester);
        expect(tester.takeException(), isNull);
        final nowYear = DateTime.now().year;
        expect(find.byKey(Key('y-picker-year-$nowYear')), findsOneWidget);
        await tester.tap(find.byKey(Key('y-picker-year-$nowYear')));
        await _settle(tester);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester);
        await tester.pump(const Duration(seconds: 1));
      }
    },
  );
}
