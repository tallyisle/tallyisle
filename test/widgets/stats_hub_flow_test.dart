import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/app/app.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/data/db/database.dart';

void main() {
  testWidgets(
    'M3 end-to-end integration: Stats hub, budget setup, Home card, RecordEditor hint, Category/Annual/Trend navigation & AssetDetail trend menu',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: const TallyIsleApp(),
        ),
      );

      Future<void> settle() async {
        for (var i = 0; i < 12; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
      }

      await settle();

      // 1. Add a cash account first
      await tester.tap(find.text('资产'));
      await settle();
      await tester.tap(find.byKey(const Key('add-asset')));
      await settle();
      await tester.enterText(find.byKey(const Key('asset-name')), '现金');
      await tester.enterText(find.byKey(const Key('asset-balance')), '1000');
      await tester.tap(find.byKey(const Key('asset-save')));
      await settle();

      // 2. Open bottom "统计" Tab and verify hub cards
      await tester.tap(find.text('统计'));
      await settle();
      expect(find.byKey(const Key('stats-hub-page')), findsOneWidget);
      expect(
        find.byKey(const Key('annual-report-overview-card')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('stats-category-overview-card')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('budget_summary_card')), findsOneWidget);

      // 3. Navigate to BudgetPage (/budget) from Stats hub & configure 2000.00 total budget
      await tester.tap(find.text('去设置'));
      await settle();
      expect(find.byKey(const Key('budget_page')), findsOneWidget);

      await tester.tap(find.byKey(const Key('set_total_budget_button')));
      await settle();
      await tester.enterText(
        find.byKey(const Key('total_budget_amount_input')),
        '2000',
      );
      await tester.tap(find.byKey(const Key('save_total_budget_button')));
      await settle();
      expect(find.text('¥2000.00'), findsOneWidget);

      // Pop back to Stats hub
      await tester.tap(find.byType(BackButton));
      await settle();
      expect(find.byKey(const Key('stats-hub-page')), findsOneWidget);

      // 4. Switch to Home ("明细") Tab: BudgetSummaryCard is now visible on Home!
      await tester.tap(find.text('明细'));
      await settle();
      expect(find.text('¥2000.00'), findsOneWidget);

      // 5. Open RecordEditorPage ("记一笔"), select "餐饮", verify live RecordBudgetHintBar!
      await tester.tap(find.byKey(const Key('add-record')));
      await settle();
      await tester.enterText(find.byKey(const Key('amount')), '120');
      await tester.tap(find.byKey(const Key('cat-餐饮')));
      await settle();
      expect(find.byKey(const Key('record_budget_hint_bar')), findsOneWidget);
      expect(find.textContaining('总预算: 剩余 ¥2000.00'), findsOneWidget);

      await tester.tap(find.byKey(const Key('asset')));
      await settle();
      await tester.tap(find.text('现金').last);
      await settle();
      await tester.tap(find.byKey(const Key('save')));
      await settle();

      // Home budget card reflects 120.00 used, 1880.00 remaining
      expect(find.text('已用: ¥120.00'), findsOneWidget);
      expect(find.text('剩余: ¥1880.00'), findsOneWidget);

      // 6. Switch back to "统计" Tab and verify CategoryStats, AnnualReport & AssetTrend routes
      await tester.tap(find.text('统计'));
      await settle();

      // Open CategoryStatsPage via "查看完整分析"
      await tester.tap(find.text('查看完整分析'));
      await settle();
      expect(find.text('分类统计'), findsOneWidget);
      await tester.drag(find.byType(ListView).last, const Offset(0, -350));
      await settle();
      expect(find.text('餐饮'), findsWidgets);
      await tester.tap(find.byType(BackButton));
      await settle();

      // Open CategoryRouteDrilldownPage (/stats/category/:id) by tapping category row on Stats hub
      await tester.tap(find.text('餐饮').first);
      await settle();
      expect(find.text('该分类总额'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await settle();

      // Open AnnualReportPage (/stats/annual)
      await tester.tap(find.byKey(const Key('annual-report-overview-card')));
      await settle();
      expect(find.text('年度统计'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await settle();

      // Scroll down to AssetTrendOverviewCard on Stats hub and open /stats/trend
      await tester.drag(
        find.byKey(const Key('stats-hub-list')),
        const Offset(0, -300),
      );
      await settle();
      await tester.tap(find.byKey(const Key('trend-overview-card')));
      await settle();
      expect(find.text('资产趋势'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await settle();

      // 7. Open AssetDetailPage -> menu -> "资产趋势" (/stats/trend?assetId=...)
      await tester.tap(find.text('资产'));
      await settle();
      await tester.tap(find.byKey(const Key('asset-现金')));
      await settle();
      await tester.tap(find.byKey(const Key('asset-menu')));
      await settle();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('menu-trend')));
      await settle();
      expect(find.text('现金 趋势'), findsOneWidget);

      // Cleanup drift streams
      await tester.pumpWidget(const SizedBox());
      await settle();
      await tester.pump(const Duration(seconds: 1));
    },
  );
}
