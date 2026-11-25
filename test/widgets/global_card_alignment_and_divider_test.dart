import 'dart:io';
import 'dart:math' as math;

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tallyisle/app/adaptive.dart';
import 'package:tallyisle/app/app.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/budget/budget_service.dart';
import 'package:tallyisle/data/catalog/catalog_service.dart';
import 'package:tallyisle/data/catalog/currency_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/debt/debt_service.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/app_settings_rules.dart';
import 'package:tallyisle/domain/rules/billing_period.dart';
import 'package:tallyisle/domain/rules/budget_rules.dart';
import 'package:tallyisle/features/assets/assets_page.dart';
import 'package:tallyisle/features/automation/automation_providers.dart';
import 'package:tallyisle/features/backup/backup_providers.dart';
import 'package:tallyisle/features/budget/budget_page.dart';
import 'package:tallyisle/features/calendar/calendar_page.dart';
import 'package:tallyisle/features/categories/categories_page.dart';
import 'package:tallyisle/features/common/common.dart';
import 'package:tallyisle/features/currencies/currencies_page.dart';
import 'package:tallyisle/features/me/me_page.dart';
import 'package:tallyisle/features/reminder/reminder_providers.dart';
import 'package:tallyisle/features/search/search_page.dart';
import 'package:tallyisle/features/settings/settings_page.dart';
import 'package:tallyisle/features/tags/tags_page.dart';
import 'package:tallyisle/platform/app_widgets.dart';
import 'package:tallyisle/platform/auto_bill_bridge.dart';
import 'package:tallyisle/platform/notifications.dart';

ThemeData _buildTestTheme({
  required Brightness brightness,
  required bool isDesktop,
}) {
  final seedColor = Color(AppSettings.defaults.themeSeedArgb32);
  final scheme = ColorScheme.fromSeed(
    seedColor: seedColor,
    brightness: brightness,
  );
  final base = ThemeData(
    colorScheme: scheme,
    cardTheme: tallyCardTheme(scheme),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        visualDensity: isDesktop
            ? VisualDensity.standard
            : VisualDensity.compact,
        minimumSize: isDesktop
            ? const WidgetStatePropertyAll(Size(0, 36))
            : null,
        padding: WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 10, vertical: isDesktop ? 6 : 0),
        ),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    ),
    useMaterial3: true,
  );
  if (!isDesktop) return base;
  return base.copyWith(
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
    ),
  );
}

/// Returns the painted visual bounds of a [Card] (excluding its outer
/// [Card.margin] Padding wrapper) or of a direct [Material] / [Container].
Rect _visualSurfaceRect(WidgetTester tester, Finder finder) {
  final el = finder.evaluate().first;
  return _visualElementRect(tester, el);
}

Rect _visualElementRect(WidgetTester tester, Element el) {
  if (el.widget is Card) {
    final matFinder = find.descendant(
      of: find.byElementPredicate((e) => identical(e, el)),
      matching: find.byWidgetPredicate(
        (w) => w is Material && w.type == MaterialType.card,
      ),
    );
    return tester.getRect(matFinder.first);
  }
  return tester.getRect(find.byElementPredicate((e) => identical(e, el)));
}

final class _AlignmentSeedHarness {
  _AlignmentSeedHarness({
    required this.db,
    required this.day1,
    required this.day2,
    required this.tempRoot,
    required this.localBackupDir,
    required this.attachmentsDir,
    required this.scheduler,
    required this.autoBridge,
    required this.widgetBridge,
  });

  final AppDatabase db;
  final DateTime day1;
  final DateTime day2;
  final Directory tempRoot;
  final Directory localBackupDir;
  final Directory attachmentsDir;
  final InMemoryReminderScheduler scheduler;
  final InMemoryAutoBillBridge autoBridge;
  final InMemoryAppWidgetBridge widgetBridge;

  static Future<_AlignmentSeedHarness> create(WidgetTester tester) async {
    late AppDatabase db;
    late DateTime day1;
    late DateTime day2;
    late Directory tempRoot;
    late Directory localBackupDir;
    late Directory attachmentsDir;

    await tester.runAsync(() async {
      db = AppDatabase(NativeDatabase.memory());
      tempRoot = await Directory.systemTemp.createTemp('tally_card_align_');
      localBackupDir = Directory(p.join(tempRoot.path, 'backups'));
      attachmentsDir = Directory(p.join(tempRoot.path, 'attachments'));
      await localBackupDir.create(recursive: true);
      await attachmentsDir.create(recursive: true);

      final ledger = LedgerService(db);
      final catalog = CatalogService(db);
      final currency = CurrencyService(db);
      final budget = BudgetService(db);
      final debtSvc = DebtService(db);

      final book = await (db.select(db.accountBooks)..limit(1)).getSingle();
      final categories = await db.select(db.recordCategories).get();
      final foodCat = categories.firstWhere((c) => c.name == '餐饮');
      final shoppingCat = categories.firstWhere((c) => c.name == '购物');
      final salaryCat = categories.firstWhere((c) => c.name == '工资');

      await catalog.createCategory(
        commandId: 'seed-subcat-lunch',
        accountBookId: book.id,
        name: '工作餐',
        type: RecordType.expense,
        parentCatId: foodCat.id,
      );

      final bankAssetId = await ledger.createAsset(
        commandId: 'seed-asset-bank',
        name: '招商储蓄卡',
        initial: Money.parse('12800.00'),
      );
      final creditAssetId = await ledger.createAsset(
        commandId: 'seed-asset-credit',
        name: '招商信用卡',
        type: AssetType.credit,
        initial: Money.parse('-680.50'),
        limit: Money.parse('30000.00'),
        creditInfo: '{"bill_day":10,"repayment_day":25,"bill_day_count":true}',
      );

      await debtSvc.createDebt(
        commandId: 'seed-debt-lend',
        subType: AssetType.debtLend,
        name: '张三周转借款',
        principal: Money.parse('3000.00'),
        bookId: book.id,
        startDate: DateTime.now().millisecondsSinceEpoch,
      );

      await currency.saveCurrency(
        commandId: 'seed-cur-usd',
        code: 'USD',
        name: '美元',
        symbol: r'$',
        price: '7.2350',
      );
      await currency.saveCurrency(
        commandId: 'seed-cur-jpy',
        code: 'JPY',
        name: '日元',
        symbol: '¥',
        price: '0.0485',
      );

      final groupTagId = await catalog.createTag(
        commandId: 'seed-tag-group',
        name: '2026差旅项目',
        isGroup: true,
        color: '#1E88E5',
      );
      final childTagId = await catalog.createTag(
        commandId: 'seed-tag-child',
        name: '高铁机票',
        parentTagId: groupTagId,
        color: '#E53935',
      );
      final soloTagId = await catalog.createTag(
        commandId: 'seed-tag-solo',
        name: '日常餐饮',
        color: '#43A047',
      );

      final now = DateTime.now();
      final period = BillingPeriod.containing(now, book.startDay);
      // Two distinct days strictly inside the active billing period so the
      // test is calendar-date-independent (including the 1st of any month).
      day1 = DateTime(period.start.year, period.start.month, period.start.day);
      day2 = DateTime(
        period.start.year,
        period.start.month,
        period.start.day + 1,
      );

      // Day 2: two expenses (68.50 + 131.50 = 200.00) + one income (1500.00).
      await ledger.saveRecord(
        commandId: 'seed-rec-d2-exp1',
        draft: RecordDraft(
          type: RecordType.expense,
          money: Money.parse('68.50'),
          bookId: book.id,
          recordTime: DateTime(
            day2.year,
            day2.month,
            day2.day,
            14,
            15,
          ).millisecondsSinceEpoch,
          categoryId: foodCat.id,
          assetId: bankAssetId,
          remark: '午餐',
          tagIds: <String>[soloTagId],
        ),
      );
      await ledger.saveRecord(
        commandId: 'seed-rec-d2-exp2',
        draft: RecordDraft(
          type: RecordType.expense,
          money: Money.parse('131.50'),
          bookId: book.id,
          recordTime: DateTime(
            day2.year,
            day2.month,
            day2.day,
            11,
            30,
          ).millisecondsSinceEpoch,
          categoryId: shoppingCat.id,
          assetId: creditAssetId,
          remark: '耗材',
          tagIds: <String>[childTagId],
        ),
      );
      await ledger.saveRecord(
        commandId: 'seed-rec-d2-inc1',
        draft: RecordDraft(
          type: RecordType.income,
          money: Money.parse('1500.00'),
          bookId: book.id,
          recordTime: DateTime(
            day2.year,
            day2.month,
            day2.day,
            9,
            0,
          ).millisecondsSinceEpoch,
          categoryId: salaryCat.id,
          assetId: bankAssetId,
          remark: '奖金',
        ),
      );

      // Day 1: expense only (45.80), zero income.
      await ledger.saveRecord(
        commandId: 'seed-rec-d1-exp1',
        draft: RecordDraft(
          type: RecordType.expense,
          money: Money.parse('45.80'),
          bookId: book.id,
          recordTime: DateTime(
            day1.year,
            day1.month,
            day1.day,
            18,
            30,
          ).millisecondsSinceEpoch,
          categoryId: foodCat.id,
          assetId: bankAssetId,
          remark: '晚餐',
        ),
      );

      final section = BudgetMode.monthly.sectionFor(period);
      await budget.upsertTotalBudget(
        commandId: 'seed-budget-total',
        bookId: book.id,
        section: section,
        amountMinor: BigInt.from(500000),
        autoCopy: true,
        forward: true,
      );
      await budget.upsertCategoryBudget(
        commandId: 'seed-budget-food',
        bookId: book.id,
        section: section,
        categoryId: foodCat.id,
        budgetType: BudgetTypeCode.expenseCategory,
        amountMinor: BigInt.from(150000),
      );
      await budget.upsertCategoryBudget(
        commandId: 'seed-budget-saving',
        bookId: book.id,
        section: section,
        categoryId: salaryCat.id,
        budgetType: BudgetTypeCode.savingCategory,
        amountMinor: BigInt.from(800000),
      );
    });

    return _AlignmentSeedHarness(
      db: db,
      day1: day1,
      day2: day2,
      tempRoot: tempRoot,
      localBackupDir: localBackupDir,
      attachmentsDir: attachmentsDir,
      scheduler: InMemoryReminderScheduler(),
      autoBridge: InMemoryAutoBillBridge(),
      widgetBridge: InMemoryAppWidgetBridge(),
    );
  }

  List<dynamic> get overrides => [
    databaseProvider.overrideWith((ref) async => db),
    reminderSchedulerProvider.overrideWithValue(scheduler),
    backupLocalDirectoryOverrideProvider.overrideWithValue(
      () async => localBackupDir,
    ),
    backupAttachmentsDirectoryOverrideProvider.overrideWithValue(
      () async => attachmentsDir,
    ),
    autoBillBridgeProvider.overrideWithValue(autoBridge),
    appWidgetBridgeProvider.overrideWithValue(widgetBridge),
  ];

  Future<void> dispose(WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = null;
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    await tester.pumpWidget(const SizedBox.shrink());
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 40));
    }
    await tester.pump(const Duration(seconds: 1));
    await scheduler.dispose();
    await autoBridge.dispose();
    await widgetBridge.dispose();
    await tester.runAsync(() async {
      await db.close();
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Future<void> _settle(WidgetTester tester, {required String ctx}) async {
  await tester.pump();
  expect(tester.takeException(), isNull, reason: 'Initial pump error ($ctx)');
  for (var i = 0; i < 14; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      tester.takeException(),
      isNull,
      reason: 'Settle pump #$i error ($ctx)',
    );
  }
}

Future<void> _ensureBuiltByScrollingDown(
  WidgetTester tester,
  Finder target,
) async {
  if (target.evaluate().isNotEmpty) return;
  final scrollables = tester
      .stateList<ScrollableState>(find.byType(Scrollable))
      .where((s) => s.position.axisDirection == AxisDirection.down)
      .toList();
  for (final s in scrollables) {
    var guard = 0;
    while (target.evaluate().isEmpty &&
        s.mounted &&
        s.position.hasContentDimensions &&
        s.position.pixels < s.position.maxScrollExtent &&
        guard < 8) {
      final next = math.min(
        s.position.pixels + 220.0,
        s.position.maxScrollExtent,
      );
      s.position.jumpTo(next);
      await tester.pump(const Duration(milliseconds: 40));
      guard++;
    }
    if (target.evaluate().isNotEmpty) return;
  }
}

List<Element> _topLevelCardElements(WidgetTester tester) {
  final cards = find.byType(Card).evaluate().toList();
  return cards.where((el) {
    var hasCardAncestor = false;
    el.visitAncestorElements((ancestor) {
      if (ancestor.widget is Card) {
        hasCardAncestor = true;
        return false;
      }
      return true;
    });
    return !hasCardAncestor;
  }).toList();
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets(
    'HomePage: 0.0px horizontal edge alignment, daily record cards with weekday & subtotals, and zero Dividers on Mobile (390x844) & Expanded Desktop (1280x800)',
    (tester) async {
      final harness = await _AlignmentSeedHarness.create(tester);
      try {
        final day2Key = formatDate(harness.day2);
        final day1Key = formatDate(harness.day1);
        final weekdayPattern = RegExp(r'^\d{4}-\d{2}-\d{2} 周[一二三四五六日]$');

        void verifyDay2HeaderAndTotals(String ctx) {
          final date2Text =
              tester
                  .widget<Text>(find.byKey(Key('daily-card-date-$day2Key')))
                  .data ??
              '';
          expect(
            date2Text,
            matches(weekdayPattern),
            reason: 'daily-card-date-$day2Key must match YYYY-MM-DD 周X ($ctx)',
          );
          expect(date2Text, equals(formatDateWithWeekday(harness.day2)));
          expect(
            tester
                .widget<Text>(find.byKey(Key('daily-card-expense-$day2Key')))
                .data,
            equals('支 ¥200.00'),
            reason: 'Day 2 expense subtotal ($ctx)',
          );
          expect(
            tester
                .widget<Text>(find.byKey(Key('daily-card-income-$day2Key')))
                .data,
            equals('收 ¥1500.00'),
            reason: 'Day 2 income subtotal ($ctx)',
          );
        }

        void verifyDay1HeaderAndTotals(String ctx) {
          final date1Text =
              tester
                  .widget<Text>(find.byKey(Key('daily-card-date-$day1Key')))
                  .data ??
              '';
          expect(
            date1Text,
            matches(weekdayPattern),
            reason: 'daily-card-date-$day1Key must match YYYY-MM-DD 周X ($ctx)',
          );
          expect(date1Text, equals(formatDateWithWeekday(harness.day1)));
          expect(
            tester
                .widget<Text>(find.byKey(Key('daily-card-expense-$day1Key')))
                .data,
            equals('支 ¥45.80'),
            reason: 'Day 1 expense subtotal ($ctx)',
          );
          expect(
            find.byKey(Key('daily-card-income-$day1Key')),
            findsNothing,
            reason: 'Zero income subtotal must be hidden ($ctx)',
          );
        }

        // 1) Mobile 390x844
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;

        await tester.pumpWidget(
          ProviderScope(
            key: const ValueKey<String>('home-mobile-scope'),
            retry: (_, _) => null,
            overrides: [...harness.overrides],
            child: const TallyIsleApp(),
          ),
        );
        await _settle(tester, ctx: 'HomePage Mobile 390x844');

        expect(find.byType(Divider), findsNothing);
        verifyDay2HeaderAndTotals('Mobile 390x844');

        final mobileAssetRect = _visualSurfaceRect(
          tester,
          find.byKey(const Key('home-asset-summary-banner')),
        );
        final mobileSummaryRect = _visualSurfaceRect(
          tester,
          find
              .ancestor(
                of: find.byKey(const Key('sum-balance')),
                matching: find.byType(Card),
              )
              .first,
        );
        final mobileBudgetRect = _visualSurfaceRect(
          tester,
          find.byKey(const Key('budget_summary_card')),
        );
        final mobileDay2Rect = _visualSurfaceRect(
          tester,
          find.byKey(Key('daily-card-$day2Key')),
        );

        await _ensureBuiltByScrollingDown(
          tester,
          find.byKey(Key('daily-card-$day1Key')),
        );
        expect(find.byType(Divider), findsNothing);
        verifyDay1HeaderAndTotals('Mobile 390x844');
        final mobileDay1Rect = _visualSurfaceRect(
          tester,
          find.byKey(Key('daily-card-$day1Key')),
        );

        final mobileCards = <(String, Rect)>[
          ('home-asset-summary-banner', mobileAssetRect),
          ('summary_card', mobileSummaryRect),
          ('budget_summary_card', mobileBudgetRect),
          ('daily-card-$day2Key', mobileDay2Rect),
          ('daily-card-$day1Key', mobileDay1Rect),
        ];

        for (final (name, rect) in mobileCards) {
          expect(
            (rect.left - 16.0).abs(),
            lessThan(0.5),
            reason: 'Mobile $name left edge (${rect.left}) must be 16.0px',
          );
          expect(
            (rect.right - 374.0).abs(),
            lessThan(0.5),
            reason: 'Mobile $name right edge (${rect.right}) must be 374.0px',
          );
        }
        for (var i = 0; i < mobileCards.length; i++) {
          for (var j = i + 1; j < mobileCards.length; j++) {
            final (nameA, rectA) = mobileCards[i];
            final (nameB, rectB) = mobileCards[j];
            expect(
              (rectA.left - rectB.left).abs(),
              lessThan(0.5),
              reason:
                  'Mobile left edge delta $nameA (${rectA.left}) vs $nameB (${rectB.left})',
            );
            expect(
              (rectA.right - rectB.right).abs(),
              lessThan(0.5),
              reason:
                  'Mobile right edge delta $nameA (${rectA.right}) vs $nameB (${rectB.right})',
            );
          }
        }

        // 2) Expanded Desktop 1280x800
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;

        await tester.pumpWidget(
          ProviderScope(
            key: const ValueKey<String>('home-desktop-scope'),
            retry: (_, _) => null,
            overrides: [...harness.overrides],
            child: const TallyIsleApp(),
          ),
        );
        await _settle(tester, ctx: 'HomePage Expanded Desktop 1280x800');

        expect(find.byType(Divider), findsNothing);
        expect(find.byKey(const Key('home-desktop-overview')), findsOneWidget);
        verifyDay2HeaderAndTotals('Expanded Desktop 1280x800');

        final deskPeriodStripRect = tester.getRect(
          find
              .ancestor(
                of: find.byKey(const Key('home-period-picker-trigger')),
                matching: find.byType(Container),
              )
              .first,
        );
        final deskAssetRect = _visualSurfaceRect(
          tester,
          find.byKey(const Key('home-asset-summary-banner')),
        );
        final deskSummaryRect = _visualSurfaceRect(
          tester,
          find
              .ancestor(
                of: find.byKey(const Key('sum-balance')),
                matching: find.byType(Card),
              )
              .first,
        );
        final deskBudgetRect = _visualSurfaceRect(
          tester,
          find.byKey(const Key('budget_summary_card')),
        );
        final deskDay2Rect = _visualSurfaceRect(
          tester,
          find.byKey(Key('daily-card-$day2Key')),
        );

        await _ensureBuiltByScrollingDown(
          tester,
          find.byKey(Key('daily-card-$day1Key')),
        );
        expect(find.byType(Divider), findsNothing);
        verifyDay1HeaderAndTotals('Expanded Desktop 1280x800');
        final deskDay1Rect = _visualSurfaceRect(
          tester,
          find.byKey(Key('daily-card-$day1Key')),
        );

        expect(
          (deskDay2Rect.left - deskDay1Rect.left).abs(),
          lessThan(0.5),
          reason: 'Desktop daily cards must share exact left edge',
        );
        expect(
          (deskDay2Rect.right - deskDay1Rect.right).abs(),
          lessThan(0.5),
          reason: 'Desktop daily cards must share exact right edge',
        );
        expect(
          (deskDay2Rect.right - (1280.0 - 16.0)).abs(),
          lessThan(0.5),
          reason: 'Desktop daily card right edge must inset 16px from 1280px',
        );

        expect(
          (deskPeriodStripRect.left - deskDay2Rect.left).abs(),
          lessThan(0.5),
          reason:
              'Desktop period strip left (${deskPeriodStripRect.left}) vs daily card left (${deskDay2Rect.left})',
        );
        expect(
          (deskAssetRect.right - deskDay2Rect.right).abs(),
          lessThan(0.5),
          reason:
              'Desktop home-asset-summary-banner right (${deskAssetRect.right}) vs daily card right (${deskDay2Rect.right})',
        );
        expect(
          (deskSummaryRect.left - deskDay2Rect.left).abs(),
          lessThan(0.5),
          reason:
              'Desktop summary card left (${deskSummaryRect.left}) vs daily card left (${deskDay2Rect.left})',
        );
        expect(
          (deskBudgetRect.right - deskDay2Rect.right).abs(),
          lessThan(0.5),
          reason:
              'Desktop budget_summary_card right (${deskBudgetRect.right}) vs daily card right (${deskDay2Rect.right})',
        );
        expect(
          (deskBudgetRect.left - deskSummaryRect.right - 16.0).abs(),
          lessThan(0.5),
          reason:
              'Desktop summary card & budget_summary_card center gap must be 16.0px',
        );
      } finally {
        await harness.dispose(tester);
      }
    },
  );

  testWidgets(
    'Core 9 pages: zero horizontal Dividers and 16px card alignment across Mobile (390x844) & Desktop (1280x800)',
    (tester) async {
      final harness = await _AlignmentSeedHarness.create(tester);
      try {
        final pages =
            <
              (
                String,
                Widget Function(),
                Future<void> Function(WidgetTester, bool)?,
              )
            >[
              ('BudgetPage', () => const BudgetPage(), null),
              ('CalendarPage', () => const CalendarPage(), null),
              ('AssetsPage', () => const AssetsPage(), null),
              ('CurrenciesPage', () => const CurrenciesPage(), null),
              ('TagsPage', () => const TagsPage(), null),
              (
                'CategoriesPage',
                () => const CategoriesPage(),
                (tester, isDesktop) async {
                  await tester.tap(find.text('收入分类'));
                  await _settle(tester, ctx: 'CategoriesPage income tab');
                  expect(find.byType(Divider), findsNothing);
                },
              ),
              (
                'SearchPage',
                () => const SearchPage(),
                (tester, isDesktop) async {
                  await tester.tap(
                    find.byKey(const Key('search-filter-toggle')),
                  );
                  await _settle(tester, ctx: 'SearchPage filter expanded');
                  expect(
                    find.byKey(const Key('search-filter-panel')),
                    findsOneWidget,
                  );
                  expect(find.byType(Divider), findsNothing);
                  if (!isDesktop) {
                    final filterRect = _visualSurfaceRect(
                      tester,
                      find.byKey(const Key('search-filter-panel')),
                    );
                    expect((filterRect.left - 16.0).abs(), lessThan(0.5));
                    expect((filterRect.right - 374.0).abs(), lessThan(0.5));
                  }
                },
              ),
              ('MePage', () => const MePage(), null),
              ('SettingsPage', () => const SettingsPage(), null),
            ];

        for (final isDesktop in <bool>[false, true]) {
          debugDefaultTargetPlatformOverride = isDesktop
              ? TargetPlatform.linux
              : TargetPlatform.android;
          final viewport = isDesktop
              ? const Size(1280, 800)
              : const Size(390, 844);
          tester.view.physicalSize = viewport;
          tester.view.devicePixelRatio = 1.0;

          final theme = _buildTestTheme(
            brightness: Brightness.light,
            isDesktop: isDesktop,
          );

          for (final (name, builder, extraCheck) in pages) {
            final ctx =
                '$name (${isDesktop ? "Desktop 1280x800" : "Mobile 390x844"})';
            await tester.pumpWidget(
              ProviderScope(
                key: ValueKey<String>('scope-$ctx'),
                retry: (_, _) => null,
                overrides: [...harness.overrides],
                child: MaterialApp(
                  key: ValueKey<String>('app-$ctx'),
                  debugShowCheckedModeBanner: false,
                  locale: const Locale('zh'),
                  supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
                  localizationsDelegates: GlobalMaterialLocalizations.delegates,
                  theme: theme,
                  home: DesktopAdaptiveScope(
                    isDesktop: isDesktop,
                    child: builder(),
                  ),
                ),
              ),
            );
            await _settle(tester, ctx: ctx);

            expect(
              find.byType(Divider),
              findsNothing,
              reason: '$ctx must render zero horizontal Divider widgets',
            );

            var verifiedCards = 0;
            void checkMobile16pxCards(String stepCtx) {
              if (isDesktop) return;
              if (name == 'MePage') {
                final sectionMaterials = find
                    .byWidgetPredicate(
                      (w) =>
                          w is Material &&
                          w.borderRadius == BorderRadius.circular(16),
                    )
                    .evaluate();
                for (final el in sectionMaterials) {
                  final box = el.renderObject as RenderBox?;
                  if (box == null || !box.hasSize) continue;
                  final rect = box.localToGlobal(Offset.zero) & box.size;
                  verifiedCards++;
                  expect(
                    (rect.left - 16.0).abs(),
                    lessThan(0.5),
                    reason: '$stepCtx section card left (${rect.left}) != 16px',
                  );
                  expect(
                    (rect.right - 374.0).abs(),
                    lessThan(0.5),
                    reason:
                        '$stepCtx section card right (${rect.right}) != 374px',
                  );
                }
                return;
              }

              for (final el in _topLevelCardElements(tester)) {
                final rect = _visualElementRect(tester, el);
                verifiedCards++;
                expect(
                  (rect.left - 16.0).abs(),
                  lessThan(0.5),
                  reason:
                      '$stepCtx top-level Card (${el.widget.key}) left (${rect.left}) != 16px',
                );
                expect(
                  (rect.right - 374.0).abs(),
                  lessThan(0.5),
                  reason:
                      '$stepCtx top-level Card (${el.widget.key}) right (${rect.right}) != 374px',
                );
              }
            }

            checkMobile16pxCards(ctx);

            // Walk vertical scrollables to verify lazy offscreen items also have zero Dividers & 16px alignment.
            final verticalScrollables = tester
                .stateList<ScrollableState>(find.byType(Scrollable))
                .where((s) => s.position.axisDirection == AxisDirection.down)
                .toList();
            for (final scrollable in verticalScrollables) {
              if (!scrollable.mounted) continue;
              final step = viewport.height * 0.65;
              var target = step;
              var guard = 0;
              while (scrollable.mounted &&
                  scrollable.position.hasContentDimensions &&
                  scrollable.position.pixels <
                      scrollable.position.maxScrollExtent &&
                  guard < 10) {
                final next = math.min(
                  target,
                  scrollable.position.maxScrollExtent,
                );
                scrollable.position.jumpTo(next);
                await tester.pump(const Duration(milliseconds: 40));
                expect(tester.takeException(), isNull);
                expect(
                  find.byType(Divider),
                  findsNothing,
                  reason: '$ctx @ scroll=$next must have zero Dividers',
                );
                checkMobile16pxCards('$ctx @ scroll=$next');
                target += step;
                guard++;
              }
              if (scrollable.mounted &&
                  scrollable.position.hasContentDimensions) {
                scrollable.position.jumpTo(0);
                await tester.pump();
              }
            }

            if (!isDesktop) {
              expect(
                verifiedCards,
                greaterThan(0),
                reason: '$ctx should render at least one 16px tonal card',
              );
            }

            if (extraCheck != null) {
              await extraCheck(tester, isDesktop);
            }
          }
        }
      } finally {
        await harness.dispose(tester);
      }
    },
  );

  test(
    'Static source guard: zero horizontal Divider(...) calls across lib/app and lib/features (except paper-styled record_receipt_dialog.dart)',
    () {
      final dividerPattern = RegExp(r'\bDivider\s*\(');
      const excludedRelPath = 'lib/features/receipt/record_receipt_dialog.dart';
      final roots = <Directory>[
        Directory('lib/app'),
        Directory('lib/features'),
      ];

      var scannedFiles = 0;
      final violations = <String>[];

      for (final root in roots) {
        expect(
          root.existsSync(),
          isTrue,
          reason: 'Expected directory ${root.path} to exist',
        );
        for (final entity in root.listSync(recursive: true)) {
          if (entity is! File || !entity.path.endsWith('.dart')) continue;
          final relPath = p.posix.joinAll(p.split(entity.path));
          if (relPath == excludedRelPath) continue;
          scannedFiles++;
          final lines = entity.readAsLinesSync();
          for (var i = 0; i < lines.length; i++) {
            if (dividerPattern.hasMatch(lines[i])) {
              violations.add('$relPath:${i + 1}: ${lines[i].trim()}');
            }
          }
        }
      }

      expect(scannedFiles, greaterThanOrEqualTo(60));
      expect(
        violations,
        isEmpty,
        reason:
            'Horizontal Divider(...) is forbidden outside $excludedRelPath:\n${violations.join('\n')}',
      );
    },
  );
}
