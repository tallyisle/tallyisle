import 'dart:async' show unawaited;

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tallyisle/app/adaptive.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/budget/budget_service.dart';
import 'package:tallyisle/data/catalog/catalog_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/billing_period.dart';
import 'package:tallyisle/domain/rules/budget_rules.dart';
import 'package:tallyisle/features/calendar/calendar_page.dart';
import 'package:tallyisle/features/stats/annual_report_page.dart';
import 'package:tallyisle/features/stats/asset_trend_page.dart';
import 'package:tallyisle/features/stats/category_stats_page.dart';
import 'package:tallyisle/features/stats/stats_page.dart';
import 'package:tallyisle/features/stats/tag_stats_page.dart';

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 14; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 40));
  }
}

class _SeededFixture {
  const _SeededFixture({
    required this.db,
    required this.diningCategoryId,
    required this.groupTagId,
    required this.flightTagId,
    required this.cashAssetId,
    required this.maxExpenseRecordId,
    required this.targetCalendarDay,
  });

  final AppDatabase db;
  final int diningCategoryId;
  final String groupTagId;
  final String flightTagId;
  final int cashAssetId;
  final String maxExpenseRecordId;
  final int targetCalendarDay;
}

Future<_SeededFixture> _createSeededDatabase() async {
  final db = AppDatabase(NativeDatabase.memory());
  final ledger = LedgerService(db);
  final catalog = CatalogService(db);
  final budgetSvc = BudgetService(db);

  var seq = 0;
  String nextCmd() => 'desk-p3-stats-${seq++}';

  final cashId = await ledger.createAsset(
    commandId: nextCmd(),
    name: '招商储蓄卡',
    initial: Money.parse('8000.00'),
  );
  await ledger.createAsset(
    commandId: nextCmd(),
    name: '日常钱包',
    initial: Money.parse('1500.00'),
  );
  await db
      .into(db.assets)
      .insert(
        AssetsCompanion.insert(
          name: '招行信用卡',
          balanceMinor: BigInt.from(-60000),
          initMoneyMinor: BigInt.zero,
          type: AssetType.credit,
          createDate: 1700000000000,
        ),
      );

  final cats = await (db.select(
    db.recordCategories,
  )..where((t) => t.accountBookId.equals(1))).get();
  final diningCat = cats.firstWhere((c) => c.name == '餐饮');
  final trafficCat = cats.firstWhere((c) => c.name == '交通');
  final shoppingCat = cats.firstWhere((c) => c.name == '购物');
  final salaryCat = cats.firstWhere((c) => c.name == '工资');

  final hotpotSubCatId = await db
      .into(db.recordCategories)
      .insert(
        RecordCategoriesCompanion.insert(
          name: '火锅聚餐',
          accountBookId: 1,
          parentCatId: Value(diningCat.id),
          type: RecordDirection.expense,
          sort: const Value(1),
        ),
      );

  final groupTagId = await catalog.createTag(
    commandId: nextCmd(),
    name: '2026差旅',
    isGroup: true,
    color: '#1E88E5',
  );
  final flightTagId = await catalog.createTag(
    commandId: nextCmd(),
    name: '高铁机票',
    parentTagId: groupTagId,
    color: '#E53935',
  );
  final mealTagId = await catalog.createTag(
    commandId: nextCmd(),
    name: '团队聚餐',
    color: '#43A047',
  );

  final now = DateTime.now();
  final period = BillingPeriod.containing(now, 1);
  await budgetSvc.upsertTotalBudget(
    commandId: nextCmd(),
    bookId: 1,
    section: BudgetMode.monthly.sectionFor(period),
    amountMinor: BigInt.from(500000), // ¥5000.00
  );

  final targetDay = now.day > 1 ? 1 : (now.day + 1).clamp(1, 28);
  final todayNoon = DateTime(now.year, now.month, now.day, 12);
  final targetDayNoon = DateTime(now.year, now.month, targetDay, 12);

  await ledger.saveRecord(
    commandId: nextCmd(),
    draft: RecordDraft(
      type: RecordType.expense,
      money: Money.parse('68.50'),
      bookId: 1,
      recordTime: todayNoon.millisecondsSinceEpoch,
      categoryId: diningCat.id,
      assetId: cashId,
      remark: '工作日午餐',
      tagIds: [mealTagId],
    ),
  );

  await ledger.saveRecord(
    commandId: nextCmd(),
    draft: RecordDraft(
      type: RecordType.expense,
      money: Money.parse('260.00'),
      bookId: 1,
      recordTime: targetDayNoon.millisecondsSinceEpoch,
      categoryId: hotpotSubCatId,
      assetId: cashId,
      remark: '周末火锅',
      tagIds: [mealTagId],
    ),
  );

  final maxExpId = await ledger.saveRecord(
    commandId: nextCmd(),
    draft: RecordDraft(
      type: RecordType.expense,
      money: Money.parse('880.00'),
      bookId: 1,
      recordTime: targetDayNoon
          .add(const Duration(minutes: 10))
          .millisecondsSinceEpoch,
      categoryId: trafficCat.id,
      assetId: cashId,
      remark: '商务高铁票',
      tagIds: [flightTagId],
    ),
  );

  await ledger.saveRecord(
    commandId: nextCmd(),
    draft: RecordDraft(
      type: RecordType.expense,
      money: Money.parse('199.00'),
      bookId: 1,
      recordTime: todayNoon
          .subtract(const Duration(hours: 1))
          .millisecondsSinceEpoch,
      categoryId: shoppingCat.id,
      assetId: cashId,
      remark: '办公配件',
      discount: Money.parse('20.00'),
    ),
  );

  await ledger.saveRecord(
    commandId: nextCmd(),
    draft: RecordDraft(
      type: RecordType.income,
      money: Money.parse('12000.00'),
      bookId: 1,
      recordTime: todayNoon
          .subtract(const Duration(hours: 2))
          .millisecondsSinceEpoch,
      categoryId: salaryCat.id,
      assetId: cashId,
      remark: '月度薪资',
    ),
  );

  return _SeededFixture(
    db: db,
    diningCategoryId: diningCat.id,
    groupTagId: groupTagId,
    flightTagId: flightTagId,
    cashAssetId: cashId,
    maxExpenseRecordId: maxExpId,
    targetCalendarDay: targetDay,
  );
}

GoRouter _buildStatsTestRouter({
  String initialLocation = '/stats',
  bool withDesktopSidebarFrame = true,
  ValueChanged<String>? onRecordOpened,
  ValueChanged<String?>? onNewRecordTimeQuery,
}) {
  return GoRouter(
    initialLocation: initialLocation,
    routes: [
      GoRoute(
        path: '/stats',
        builder: (context, _) {
          if (!withDesktopSidebarFrame ||
              !DesktopAdaptive.isExpandedDesktop(context)) {
            return const StatsPage();
          }
          // Simulates the 208px expanded left sidebar so StatsPage's real
          // available width (e.g. 1080 - 208 = 872px) is strictly tested.
          return Row(
            children: const [
              SizedBox(width: 208, child: Material()),
              VerticalDivider(width: 1),
              Expanded(child: StatsPage()),
            ],
          );
        },
      ),
      GoRoute(
        path: '/budget',
        builder: (_, _) => Scaffold(
          appBar: AppBar(title: const Text('预算占位')),
          body: const Center(child: Text('BUDGET_ROUTE')),
        ),
      ),
      GoRoute(
        path: '/stats/category',
        builder: (_, _) => const CategoryStatsPage(),
      ),
      GoRoute(
        path: '/stats/category/:id',
        builder: (_, state) => CategoryRouteDrilldownPage(
          categoryId: int.parse(state.pathParameters['id']!),
        ),
      ),
      GoRoute(path: '/stats/tags', builder: (_, _) => const TagRankingsPage()),
      GoRoute(
        path: '/stats/tag/:id',
        builder: (_, state) =>
            TagDetailStatsPage(tagId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/stats/trend',
        builder: (_, state) => AssetTrendPage(
          initialAssetId: int.tryParse(
            state.uri.queryParameters['assetId'] ?? '',
          ),
        ),
      ),
      GoRoute(
        path: '/stats/annual',
        builder: (context, state) {
          final q = state.uri.queryParameters;
          return AnnualReportPage(
            initialYear: int.tryParse(q['year'] ?? ''),
            initialBookId: int.tryParse(q['bookId'] ?? ''),
            onRecordTap: (id) {
              onRecordOpened?.call(id);
              context.push('/record/$id');
            },
          );
        },
      ),
      GoRoute(path: '/calendar', builder: (_, _) => const CalendarPage()),
      GoRoute(
        path: '/record/new',
        builder: (_, state) {
          final timeParam = state.uri.queryParameters['time'];
          onNewRecordTimeQuery?.call(timeParam);
          return Scaffold(
            key: const Key('mock-record-new-page'),
            appBar: AppBar(title: const Text('记一笔')),
            body: Center(child: Text('NEW_RECORD_TIME=${timeParam ?? ''}')),
          );
        },
      ),
      GoRoute(
        path: '/record/:id',
        builder: (_, state) {
          final id = state.pathParameters['id']!;
          onRecordOpened?.call(id);
          return Scaffold(
            key: Key('mock-record-detail-$id'),
            appBar: AppBar(title: const Text('账单详情')),
            body: Center(child: Text('RECORD_DETAIL=$id')),
          );
        },
      ),
    ],
  );
}

Widget _wrapRouterApp({
  required AppDatabase db,
  required GoRouter router,
  required bool isDesktop,
  ThemeMode themeMode = ThemeMode.light,
}) {
  return ProviderScope(
    retry: (_, _) => null,
    overrides: [databaseProvider.overrideWith((ref) async => db)],
    child: DesktopAdaptiveScope(
      isDesktop: isDesktop,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [Locale('zh', 'CN'), Locale('en', 'US')],
        locale: const Locale('zh', 'CN'),
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: const Color(0xFF2B6CB0),
          brightness: Brightness.light,
        ),
        darkTheme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: const Color(0xFF2B6CB0),
          brightness: Brightness.dark,
        ),
        themeMode: themeMode,
        routerConfig: router,
      ),
    ),
  );
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets(
    'Desktop widescreen (1280x800 & 1080x700, Light & Dark): all 6 Stats & Calendar pages render dual-column layouts with zero overflow and interactive drilldown',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    (tester) async {
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final fixture = (await tester.runAsync(_createSeededDatabase))!;
      String? lastOpenedRecordId;
      String? capturedNewRecordTime;

      var closed = false;
      Future<void> cleanUp() async {
        if (closed) return;
        closed = true;
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester);
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(fixture.db.close);
      }

      addTearDown(cleanUp);

      for (final themeMode in const [ThemeMode.light, ThemeMode.dark]) {
        for (final viewport in const [Size(1280, 800), Size(1080, 700)]) {
          tester.view.physicalSize = viewport;
          tester.view.devicePixelRatio = 1.0;

          final router = _buildStatsTestRouter(
            initialLocation: '/stats',
            onRecordOpened: (id) => lastOpenedRecordId = id,
            onNewRecordTimeQuery: (t) => capturedNewRecordTime = t,
          );

          await tester.pumpWidget(
            _wrapRouterApp(
              db: fixture.db,
              router: router,
              isDesktop: true,
              themeMode: themeMode,
            ),
          );
          await _settle(tester);
          expect(tester.takeException(), isNull);

          // -----------------------------------------------------------------
          // 1. StatsPage: 2-column grid (`stats-desktop-grid`, maxWidth 1360)
          // -----------------------------------------------------------------
          expect(find.byKey(const Key('stats-desktop-grid')), findsOneWidget);
          final annualRect = tester.getRect(
            find.byKey(const Key('annual-report-overview-card')),
          );
          final budgetRect = tester.getRect(
            find.byKey(const Key('budget_summary_card')),
          );
          // Row 1: side-by-side and top-aligned (CrossAxisAlignment.start)
          expect(annualRect.left, lessThan(budgetRect.left));
          expect((annualRect.top - budgetRect.top).abs(), lessThan(2.0));

          final catCardRect = tester.getRect(
            find.byKey(const Key('stats-category-overview-card')),
          );
          final tagCardRect = tester.getRect(
            find.byKey(const Key('stats-tag-overview-card')),
          );
          // Row 2: side-by-side
          expect(catCardRect.left, lessThan(tagCardRect.left));
          expect((catCardRect.top - tagCardRect.top).abs(), lessThan(2.0));
          expect(find.byKey(const Key('trend-overview-card')), findsOneWidget);

          // -----------------------------------------------------------------
          // 2. CategoryStatsPage & CategoryDrilldownPage
          // -----------------------------------------------------------------
          await tester.tap(find.text('查看完整分析'));
          await _settle(tester);
          expect(tester.takeException(), isNull);
          expect(
            find.byKey(const Key('category-stats-desktop-split')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('category-stats-donut-card')),
            findsOneWidget,
          );

          final leftCatPane = tester.getRect(
            find.byKey(const Key('category-stats-left-pane')),
          );
          final rightCatPane = tester.getRect(
            find.byKey(const Key('category-stats-right-pane')),
          );
          expect(leftCatPane.left, lessThan(rightCatPane.left));
          final totalSplitW = leftCatPane.width + rightCatPane.width;
          expect(leftCatPane.width / totalSplitW, inInclusiveRange(0.44, 0.49));

          // Flatten toggle & dimension toggle work without overflow
          await tester.tap(find.text('二级平铺'));
          await _settle(tester);
          expect(tester.takeException(), isNull);
          await tester.tap(find.text('一级汇总'));
          await _settle(tester);

          // Drilldown into 餐饮 -> CategoryDrilldownPage dual-column split
          await tester.tap(
            find.byKey(Key('category-row-${fixture.diningCategoryId}')),
          );
          await _settle(tester);
          expect(tester.takeException(), isNull);
          expect(
            find.byKey(const Key('category-drilldown-desktop-split')),
            findsOneWidget,
          );
          expect(find.text('子分类构成'), findsOneWidget);
          expect(find.text('包含账单明细 (2 笔)'), findsOneWidget);
          await tester.tap(find.text('按金额'));
          await _settle(tester);
          expect(tester.takeException(), isNull);

          // Pop back to CategoryStatsPage, then back to StatsPage
          await tester.tap(find.byType(BackButton));
          await _settle(tester);
          await tester.tap(find.byType(BackButton));
          await _settle(tester);

          // -----------------------------------------------------------------
          // 3. TagRankingsPage & TagDetailStatsPage
          // -----------------------------------------------------------------
          await tester.tap(find.byKey(const Key('stats-tag-all-rankings-btn')));
          await _settle(tester);
          expect(tester.takeException(), isNull);
          expect(
            find.byKey(const Key('tag-rankings-desktop-split')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('tag-rankings-donut-card')),
            findsOneWidget,
          );

          // Switch to 按标签组 and drill down into group tag "2026差旅"
          await tester.tap(find.text('按标签组'));
          await _settle(tester);
          expect(tester.takeException(), isNull);
          await tester.tap(
            find.byKey(Key('tag-ranking-row-${fixture.groupTagId}')),
          );
          await _settle(tester);
          expect(tester.takeException(), isNull);
          expect(
            find.byKey(const Key('tag-detail-desktop-split')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('tag-detail-summary-card')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('tag-detail-children-section')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('tag-detail-category-section')),
            findsOneWidget,
          );
          expect(find.text('关联账单明细 (1 笔)'), findsOneWidget);

          // Reset rollup back to 按标签 for next loop iteration
          await tester.tap(find.byType(BackButton));
          await _settle(tester);
          await tester.tap(find.text('按标签'));
          await _settle(tester);
          await tester.tap(find.byType(BackButton));
          await _settle(tester);

          // -----------------------------------------------------------------
          // 4. AssetTrendPage
          // -----------------------------------------------------------------
          unawaited(router.push('/stats/trend'));
          await _settle(tester);
          expect(tester.takeException(), isNull);
          expect(
            find.byKey(const Key('asset-trend-desktop-split')),
            findsOneWidget,
          );
          final distRect = tester.getRect(
            find.byKey(const Key('trend-card-distribution')),
          );
          final flowRect = tester.getRect(
            find.byKey(const Key('trend-card-flow')),
          );
          expect(distRect.left, lessThan(flowRect.left));

          await tester.tap(
            find.byKey(const Key('trend-perspective-totalLiability')),
          );
          await _settle(tester);
          expect(find.text('总负债趋势'), findsOneWidget);
          expect(tester.takeException(), isNull);

          // Desktop scope picker opens centered Dialog
          await tester.tap(find.byKey(const Key('trend-filter-button')));
          await _settle(tester);
          expect(
            find.byKey(const Key('trend-scope-picker-dialog')),
            findsOneWidget,
          );
          await tester.tap(find.text('全部有效净资产 (默认)'));
          await _settle(tester);
          await tester.tap(find.byKey(const Key('trend-perspective-netWorth')));
          await _settle(tester);
          await tester.tap(find.byType(BackButton));
          await _settle(tester);

          // -----------------------------------------------------------------
          // 5. AnnualReportPage (年度账单 split + 年度报告 2-column grid)
          // -----------------------------------------------------------------
          unawaited(router.push('/stats/annual'));
          await _settle(tester);
          expect(tester.takeException(), isNull);
          expect(
            find.byKey(const Key('annual-bill-desktop-split')),
            findsOneWidget,
          );
          await tester.tap(
            find.byKey(const Key('annual-report-toggle-sort-button')),
          );
          await _settle(tester);
          expect(find.text('12月至1月'), findsOneWidget);
          expect(tester.takeException(), isNull);

          // Switch to 年度报告 Tab -> 2-column grid
          await tester.tap(find.text('年度报告'));
          await _settle(tester);
          expect(tester.takeException(), isNull);
          expect(
            find.byKey(const Key('annual-report-desktop-grid')),
            findsOneWidget,
          );
          await tester.tap(
            find.byKey(const Key('annual-report-max-expense-record-tile')),
          );
          await _settle(tester);
          expect(lastOpenedRecordId, fixture.maxExpenseRecordId);
          await tester.tap(find.byType(BackButton));
          await _settle(tester);
          await tester.tap(find.byType(BackButton));
          await _settle(tester);

          // -----------------------------------------------------------------
          // 6. CalendarPage (`calendar-desktop-split` + `calendar-add-for-day`)
          // -----------------------------------------------------------------
          unawaited(router.push('/calendar'));
          await _settle(tester);
          expect(tester.takeException(), isNull);
          expect(
            find.byKey(const Key('calendar-desktop-split')),
            findsOneWidget,
          );
          final gridWidth = tester
              .getSize(find.byKey(const Key('calendar-grid')))
              .width;
          // Left pane is 480px with 8px horizontal padding -> grid width 464px
          expect(gridWidth, inInclusiveRange(440.0, 500.0));

          // Select targetCalendarDay and verify right pane updates & "+ 补记该日账单"
          await tester.tap(
            find.byKey(Key('calendar-cell-${fixture.targetCalendarDay}')),
          );
          await _settle(tester);
          expect(
            find.byKey(Key('calendar-record-${fixture.maxExpenseRecordId}')),
            findsOneWidget,
          );
          expect(find.textContaining('商务高铁票'), findsOneWidget);
          expect(find.textContaining('周末火锅'), findsOneWidget);

          final now = DateTime.now();
          final expectedNoonMs = DateTime(
            now.year,
            now.month,
            fixture.targetCalendarDay,
            12,
          ).millisecondsSinceEpoch;

          await tester.tap(find.byKey(const Key('calendar-add-for-day')));
          await _settle(tester);
          expect(tester.takeException(), isNull);
          expect(capturedNewRecordTime, '$expectedNoonMs');
          expect(find.text('NEW_RECORD_TIME=$expectedNoonMs'), findsOneWidget);
        }
      }

      await cleanUp();
    },
  );

  testWidgets(
    'Narrow desktop (< 1080px) and mobile (360x640 Android) keep single-column layouts with zero regression',
    (tester) async {
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final fixture = (await tester.runAsync(_createSeededDatabase))!;

      var closed = false;
      Future<void> cleanUp() async {
        if (closed) return;
        closed = true;
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester);
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(fixture.db.close);
      }

      addTearDown(cleanUp);

      for (final (isDesktop, size) in const [
        (true, Size(900, 700)), // Medium desktop < 1080px
        (false, Size(360, 640)), // Mobile portrait
      ]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;

        for (final route in [
          '/stats',
          '/stats/category',
          '/stats/tags',
          '/stats/tag/${fixture.groupTagId}',
          '/stats/trend',
          '/stats/annual',
          '/calendar',
        ]) {
          final router = _buildStatsTestRouter(
            initialLocation: route,
            withDesktopSidebarFrame: false,
          );
          await tester.pumpWidget(
            _wrapRouterApp(
              db: fixture.db,
              router: router,
              isDesktop: isDesktop,
            ),
          );
          await _settle(tester);
          expect(tester.takeException(), isNull);

          expect(find.byKey(const Key('stats-desktop-grid')), findsNothing);
          expect(
            find.byKey(const Key('category-stats-desktop-split')),
            findsNothing,
          );
          expect(
            find.byKey(const Key('tag-rankings-desktop-split')),
            findsNothing,
          );
          expect(
            find.byKey(const Key('tag-detail-desktop-split')),
            findsNothing,
          );
          expect(
            find.byKey(const Key('asset-trend-desktop-split')),
            findsNothing,
          );
          expect(
            find.byKey(const Key('annual-bill-desktop-split')),
            findsNothing,
          );
          expect(
            find.byKey(const Key('annual-report-desktop-grid')),
            findsNothing,
          );
          expect(find.byKey(const Key('calendar-desktop-split')), findsNothing);
          expect(find.byKey(const Key('calendar-add-for-day')), findsNothing);
        }
      }

      await cleanUp();
    },
  );
}
