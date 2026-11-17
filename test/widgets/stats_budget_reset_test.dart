import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/app/app.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/budget/budget_service.dart';
import 'package:tallyisle/data/catalog/catalog_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/billing_period.dart';
import 'package:tallyisle/domain/rules/category_stats.dart';
import 'package:tallyisle/features/stats/category_stats_providers.dart';
import 'package:tallyisle/features/stats/tag_stats_providers.dart';

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
}

Finder _statsScrollable() => find.descendant(
  of: find.byKey(const Key('stats-hub-list')),
  matching: find.byType(Scrollable),
);

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets(
    'BudgetPage & StatsPage auto-reset to current month (本月) and current year (本年) on every re-open while preserving explicit Stats card period jump',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final budgetSvc = BudgetService(db);
      final now = DateTime.now();
      final curMonth = BillingPeriod.containing(now, 1);
      final prevMonth = BillingPeriod.starting(
        curMonth.year,
        curMonth.month - 1,
        1,
      );
      final curYear = BillingPeriod.containingYear(now, 1);
      final prevYear = BillingPeriod.year(curYear.year - 1, 1);

      await budgetSvc.upsertTotalBudget(
        commandId: 'seed-cur-month-budget',
        bookId: 1,
        section: curMonth.monthlySection,
        amountMinor: BigInt.from(300000), // ¥3000.00
      );
      await budgetSvc.upsertTotalBudget(
        commandId: 'seed-prev-month-budget',
        bookId: 1,
        section: prevMonth.monthlySection,
        amountMinor: BigInt.from(150000), // ¥1500.00
      );
      await budgetSvc.upsertTotalBudget(
        commandId: 'seed-cur-year-budget',
        bookId: 1,
        section: curYear.yearlySection,
        amountMinor: BigInt.from(3600000), // ¥36000.00
      );
      await budgetSvc.upsertTotalBudget(
        commandId: 'seed-prev-year-budget',
        bookId: 1,
        section: prevYear.yearlySection,
        amountMinor: BigInt.from(2400000), // ¥24000.00
      );

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: const TallyIsleApp(),
        ),
      );
      await _settle(tester);

      // 1. Monthly mode: open BudgetPage from Home card -> step to previous month -> pop & re-open -> resets to 本月!
      expect(find.text('¥3000.00'), findsOneWidget);
      await tester.tap(find.byKey(const Key('budget_summary_card')));
      await _settle(tester);
      expect(find.byKey(const Key('budget_page')), findsOneWidget);
      expect(
        find.text('${curMonth.year} 年 ${curMonth.month} 月'),
        findsOneWidget,
      );
      expect(find.text('¥3000.00'), findsOneWidget);

      await tester.tap(find.byKey(const Key('budget_period_prev')));
      await _settle(tester);
      expect(
        find.text('${prevMonth.year} 年 ${prevMonth.month} 月'),
        findsOneWidget,
      );
      expect(find.text('¥1500.00'), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await _settle(tester);
      expect(find.text('¥3000.00'), findsOneWidget);

      // Re-open BudgetPage from Home -> auto-resets to current month (本月)!
      await tester.tap(find.byKey(const Key('budget_summary_card')));
      await _settle(tester);
      expect(
        find.text('${curMonth.year} 年 ${curMonth.month} 月'),
        findsOneWidget,
      );
      expect(find.text('¥3000.00'), findsOneWidget);

      // Step back to -2 on BudgetPage, then pop and switch to Stats tab
      await tester.tap(find.byKey(const Key('budget_period_prev')));
      await tester.tap(find.byKey(const Key('budget_period_prev')));
      await _settle(tester);
      expect(find.text('未设置当期预算'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await _settle(tester);

      // 2. Open Stats tab -> auto-resets to current month (¥3000.00)
      await tester.tap(find.text('统计'));
      await _settle(tester);
      await tester.scrollUntilVisible(
        find.byKey(const Key('budget_summary_card')),
        200,
        scrollable: _statsScrollable(),
      );
      await _settle(tester);
      expect(find.byKey(const Key('budget_card_period_reset')), findsNothing);
      expect(find.text('¥3000.00'), findsOneWidget);

      // Step StatsPage card to -1 (¥1500.00), then tap AppBar budget icon -> opens BudgetPage at offset=0 (¥3000.00)!
      await tester.tap(find.byKey(const Key('budget_card_period_prev')));
      await _settle(tester);
      expect(find.text('¥1500.00'), findsOneWidget);
      await tester.tap(find.byKey(const Key('stats-budget-action')));
      await _settle(tester);
      expect(find.byKey(const Key('budget_page')), findsOneWidget);
      expect(
        find.text('${curMonth.year} 年 ${curMonth.month} 月'),
        findsOneWidget,
      );
      expect(find.text('¥3000.00'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await _settle(tester);
      expect(find.text('¥3000.00'), findsOneWidget);

      // Step StatsPage card to -1 (¥1500.00), tap BudgetSummaryCard -> opens BudgetPage on -1, resets StatsPage on back!
      await tester.tap(find.byKey(const Key('budget_card_period_prev')));
      await _settle(tester);
      expect(find.text('¥1500.00'), findsOneWidget);
      await tester.tap(find.byKey(const Key('budget_summary_card')));
      await _settle(tester);
      expect(find.byKey(const Key('budget_page')), findsOneWidget);
      expect(
        find.text('${prevMonth.year} 年 ${prevMonth.month} 月'),
        findsOneWidget,
      );
      expect(find.text('¥1500.00'), findsOneWidget);

      // 3. Switch to Yearly mode (年预算) -> step to previous year -> pop & re-open -> auto-resets to 本年!
      await tester.tap(find.text('年预算'));
      await _settle(tester);
      expect(find.text('${curYear.year} 年'), findsOneWidget);
      expect(find.text('¥36000.00'), findsOneWidget);

      await tester.tap(find.byKey(const Key('budget_period_prev')));
      await _settle(tester);
      expect(find.text('${prevYear.year} 年'), findsOneWidget);
      expect(find.text('¥24000.00'), findsOneWidget);

      // Pop back to StatsPage -> auto-resets to current year (本年: ¥36000.00)!
      await tester.tap(find.byType(BackButton));
      await _settle(tester);
      expect(find.byKey(const Key('budget_card_period_reset')), findsNothing);
      expect(find.text('${curYear.year}年总预算'), findsOneWidget);
      expect(find.text('¥36000.00'), findsOneWidget);

      // Re-open BudgetPage via AppBar icon -> auto-resets to current year (本年)!
      await tester.tap(find.byKey(const Key('stats-budget-action')));
      await _settle(tester);
      expect(find.text('${curYear.year} 年'), findsOneWidget);
      expect(find.text('¥36000.00'), findsOneWidget);
      await tester.tap(find.byKey(const Key('budget_period_prev')));
      await _settle(tester);
      expect(find.text('${prevYear.year} 年'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await _settle(tester);

      // Step StatsPage inline card to previous year, switch away to 资产 tab and back -> auto-resets to 本年!
      await tester.tap(find.byKey(const Key('budget_card_period_prev')));
      await _settle(tester);
      expect(find.text('回今年'), findsOneWidget);
      expect(find.text('¥24000.00'), findsOneWidget);

      await tester.tap(find.text('资产'));
      await _settle(tester);
      await tester.tap(find.text('统计'));
      await _settle(tester);
      await tester.scrollUntilVisible(
        find.byKey(const Key('budget_summary_card')),
        200,
        scrollable: _statsScrollable(),
      );
      await _settle(tester);
      expect(find.byKey(const Key('budget_card_period_reset')), findsNothing);
      expect(find.text('¥36000.00'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(db.close);
    },
  );

  testWidgets(
    'StatsPage Category & Tag overview cards stay anchored to current month while CategoryStatsPage & TagRankingsPage auto-reset on re-open',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final ledger = LedgerService(db);
      final catalog = CatalogService(db);

      final cats = await (db.select(
        db.recordCategories,
      )..where((c) => c.accountBookId.equals(1))).get();
      final diningCat = cats.firstWhere((c) => c.name == '餐饮');
      final trafficCat = cats.firstWhere((c) => c.name == '交通');

      final curTagId = await catalog.createTag(
        commandId: 'seed-tag-cur',
        name: '本月通勤',
        color: '#1E88E5',
      );
      final prevTagId = await catalog.createTag(
        commandId: 'seed-tag-prev',
        name: '上月差旅',
        color: '#E53935',
      );

      final now = DateTime.now();
      final curPeriod = BillingPeriod.containing(now, 1);
      final prevPeriod = BillingPeriod.starting(
        curPeriod.year,
        curPeriod.month - 1,
        1,
      );
      final prevYearPeriod = BillingPeriod.year(curPeriod.year - 1, 1);

      // Current-month expense: 餐饮 ¥188.00 (#本月通勤)
      await ledger.saveRecord(
        commandId: 'seed-rec-cur',
        draft: RecordDraft(
          type: RecordType.expense,
          money: Money.parse('188.00'),
          bookId: 1,
          recordTime: DateTime(
            now.year,
            now.month,
            now.day,
            12,
          ).millisecondsSinceEpoch,
          categoryId: diningCat.id,
          remark: '当月午餐',
          tagIds: [curTagId],
        ),
      );

      // Previous-month expense: 交通 ¥666.00 (#上月差旅)
      await ledger.saveRecord(
        commandId: 'seed-rec-prev',
        draft: RecordDraft(
          type: RecordType.expense,
          money: Money.parse('666.00'),
          bookId: 1,
          recordTime: prevPeriod.start
              .add(const Duration(days: 2, hours: 12))
              .millisecondsSinceEpoch,
          categoryId: trafficCat.id,
          remark: '上月机票',
          tagIds: [prevTagId],
        ),
      );

      // Previous-year expense: 交通 ¥999.00 (#上月差旅)
      await ledger.saveRecord(
        commandId: 'seed-rec-prev-year',
        draft: RecordDraft(
          type: RecordType.expense,
          money: Money.parse('999.00'),
          bookId: 1,
          recordTime: prevYearPeriod.start
              .add(const Duration(days: 10, hours: 12))
              .millisecondsSinceEpoch,
          categoryId: trafficCat.id,
          remark: '去年高铁',
          tagIds: [prevTagId],
        ),
      );

      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: Builder(
            builder: (context) {
              container = ProviderScope.containerOf(context);
              return const TallyIsleApp();
            },
          ),
        ),
      );
      await _settle(tester);

      // 1. Open StatsPage and verify both overview cards show current month (餐饮 ¥188.00 & #本月通勤)
      await tester.tap(find.text('统计'));
      await _settle(tester);
      expect(find.text('餐饮'), findsOneWidget);
      expect(find.text('¥188.00 (100.00%)'), findsWidgets);
      expect(find.text('交通'), findsNothing);
      expect(find.byKey(Key('stats-tag-row-$curTagId')), findsOneWidget);
      expect(find.byKey(Key('stats-tag-row-$prevTagId')), findsNothing);

      // 2. Open CategoryStatsPage, step to previous month (交通 ¥666.00), and apply an excluding filter
      await tester.tap(find.text('查看完整分析'));
      await _settle(tester);
      expect(
        find.text('${curPeriod.year}年${curPeriod.month}月'),
        findsOneWidget,
      );
      expect(find.text('¥188.00'), findsWidgets);

      await tester.tap(find.byKey(const Key('period-prev-button')));
      await _settle(tester);
      expect(
        find.text('${prevPeriod.year}年${prevPeriod.month}月'),
        findsOneWidget,
      );
      expect(find.text('¥666.00'), findsWidgets);

      container
          .read(categoryStatsFilterConfigProvider.notifier)
          .update(
            FilterConfigState(
              selectedCategoryIds: {trafficCat.id},
              includeExcludeBudget: false,
            ),
          );
      await _settle(tester);

      // Pop back to StatsPage -> BOTH CategoryStatsOverviewCard and _TagStatsOverviewCard MUST remain anchored to current month!
      await tester.tap(find.byType(BackButton));
      await _settle(tester);
      expect(container.read(categoryStatsOffsetProvider), -1);
      expect(find.text('餐饮'), findsOneWidget);
      expect(find.text('交通'), findsNothing);
      expect(find.byKey(Key('stats-tag-row-$curTagId')), findsOneWidget);
      expect(find.byKey(Key('stats-tag-row-$prevTagId')), findsNothing);

      // Tapping category row '餐饮' on StatsPage aligns period/filter and drills into current month (1 笔, ¥188.00)!
      await tester.tap(find.text('餐饮'));
      await _settle(tester);
      expect(find.text('包含账单明细 (1 笔)'), findsOneWidget);
      expect(find.text('当月午餐'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await _settle(tester);

      // Mutate subpage state to Custom range & non-zero offset, then re-open CategoryStatsPage -> resets to StatRangeKind.month & offset=0!
      container
          .read(categoryStatsRangeKindProvider.notifier)
          .setRangeKind(StatRangeKind.custom);
      container
          .read(categoryStatsCustomRangeProvider.notifier)
          .setRange(prevPeriod.start, prevPeriod.end);
      container.read(categoryStatsOffsetProvider.notifier).setOffset(-2);
      await _settle(tester);
      // StatsPage cards are STILL anchored to current month even while subpage is in custom range!
      expect(find.text('餐饮'), findsOneWidget);
      expect(find.byKey(Key('stats-tag-row-$curTagId')), findsOneWidget);

      await tester.tap(find.text('查看完整分析'));
      await _settle(tester);
      expect(
        container.read(categoryStatsRangeKindProvider),
        StatRangeKind.month,
      );
      expect(container.read(categoryStatsOffsetProvider), 0);
      expect(
        find.text('${curPeriod.year}年${curPeriod.month}月'),
        findsOneWidget,
      );
      expect(find.text('¥188.00'), findsWidgets);

      // Switch CategoryStatsPage to 按年 and step to previous year -> pop & re-open -> resets offset to 0 (current year)!
      await tester.tap(find.byKey(const Key('period-kind-year')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('period-prev-button')));
      await _settle(tester);
      expect(find.text('${prevYearPeriod.year}年'), findsOneWidget);
      expect(find.text('¥999.00'), findsWidgets);

      await tester.tap(find.byType(BackButton));
      await _settle(tester);
      await tester.tap(find.text('查看完整分析'));
      await _settle(tester);
      expect(container.read(categoryStatsOffsetProvider), 0);
      expect(find.text('${curPeriod.year}年'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await _settle(tester);

      // 3. Open TagRankingsPage -> switch to 按月 -> step to previous month -> pop & re-open -> auto-resets offset to 0!
      await tester.tap(find.byKey(const Key('stats-tag-all-rankings-btn')));
      await _settle(tester);
      expect(find.byKey(const Key('tag-rankings-page')), findsOneWidget);

      await tester.tap(find.byKey(const Key('tag-rankings-mode-month')));
      await _settle(tester);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('tag-rankings-period-label')))
            .data,
        formatTagStatsPeriodLabel(TagStatsPeriodMode.month, curPeriod),
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('tag-rankings-total-amount')))
            .data,
        '¥188.00',
      );

      await tester.tap(find.byKey(const Key('tag-rankings-prev-period')));
      await _settle(tester);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('tag-rankings-period-label')))
            .data,
        formatTagStatsPeriodLabel(TagStatsPeriodMode.month, prevPeriod),
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('tag-rankings-total-amount')))
            .data,
        '¥666.00',
      );

      await tester.tap(find.byType(BackButton));
      await _settle(tester);

      // Re-open TagRankingsPage -> auto-resets offset to 0 (current month)!
      await tester.tap(find.byKey(const Key('stats-tag-all-rankings-btn')));
      await _settle(tester);
      expect(container.read(tagRankingsOffsetProvider), 0);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('tag-rankings-period-label')))
            .data,
        formatTagStatsPeriodLabel(TagStatsPeriodMode.month, curPeriod),
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('tag-rankings-total-amount')))
            .data,
        '¥188.00',
      );

      // Switch TagRankingsPage to 按年 -> step to previous year -> pop & re-open from TagsPage -> auto-resets offset to 0!
      await tester.tap(find.byKey(const Key('tag-rankings-mode-year')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('tag-rankings-prev-period')));
      await _settle(tester);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('tag-rankings-period-label')))
            .data,
        '${prevYearPeriod.year}',
      );
      await tester.tap(find.byType(BackButton));
      await _settle(tester);

      await tester.tap(find.text('更多'));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('me-tags')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('tags-stats-btn')));
      await _settle(tester);
      expect(container.read(tagRankingsOffsetProvider), 0);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('tag-rankings-period-label')))
            .data,
        '${curPeriod.year}',
      );
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(db.close);
    },
  );

  testWidgets(
    'Desktop widescreen sidebar branch switch & 360dp narrow screen 1.2x text scale auto-reset cleanly without overflow',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    (tester) async {
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });

      final db = AppDatabase(NativeDatabase.memory());
      final budgetSvc = BudgetService(db);
      final curMonth = BillingPeriod.containing(DateTime.now(), 1);
      await budgetSvc.upsertTotalBudget(
        commandId: 'desk-reset-budget',
        bookId: 1,
        section: curMonth.monthlySection,
        amountMinor: BigInt.from(500000), // ¥5000.00
      );

      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: const TallyIsleApp(),
        ),
      );
      await _settle(tester);

      expect(find.byKey(const Key('desktop-sidebar')), findsOneWidget);
      await tester.tap(find.byKey(const Key('nav-slot-stats')));
      await _settle(tester);
      expect(find.text('¥5000.00'), findsOneWidget);

      // Step budget card to previous month on desktop widescreen StatsPage
      await tester.tap(find.byKey(const Key('budget_card_period_prev')));
      await _settle(tester);
      expect(find.text('回本月'), findsOneWidget);
      expect(find.text('该期未设置预算'), findsOneWidget);

      // Switch to 明细 via desktop sidebar and switch back to 统计 -> TickerMode resets budget card!
      await tester.tap(find.byKey(const Key('nav-slot-home')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('nav-slot-stats')));
      await _settle(tester);
      expect(find.byKey(const Key('budget_card_period_reset')), findsNothing);
      expect(find.text('¥5000.00'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Narrow 360x640 @ 1.2x text scale check
      tester.view.physicalSize = const Size(360, 640);
      tester.platformDispatcher.textScaleFactorTestValue = 1.2;
      await _settle(tester);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(db.close);
    },
  );
}
