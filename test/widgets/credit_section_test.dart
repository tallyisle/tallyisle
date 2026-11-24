import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/app/app.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/domain/ledger/asset_json.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/features/assets/asset_detail_page.dart';
import 'package:tallyisle/features/common/catalog_icons.dart';

void main() {
  testWidgets(
    'credit account detail defaults to first-screen flows, supports statement tab folding, and filters flows on statement card tap',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWith((ref) async => db)],
      );

      final ledger = await container.read(ledgerServiceProvider.future);
      // Pin deterministic dates inside current year so both an active/recent
      // bill and an older cycle bill exist.
      final now = DateTime.now();
      final info = CreditInfo()
        ..billDay = 10
        ..repaymentDay = 28
        ..billDayCounted = true;

      final cardId = await ledger.createAsset(
        commandId: 'cmd-create-card',
        name: '招行经典白',
        type: AssetType.credit,
        limit: Money.parse('20000.00'),
        initial: -Money.parse('1500.00'),
        creditInfo: info.encode(),
      );

      final recentTime = DateTime(
        now.year,
        now.month,
        now.day,
        12,
      ).millisecondsSinceEpoch;
      final prevMonthYear = now.month == 1 ? now.year - 1 : now.year;
      final prevMonth = now.month == 1 ? 12 : now.month - 1;
      final olderTime = DateTime(
        prevMonthYear,
        prevMonth,
        5,
        10,
      ).millisecondsSinceEpoch;

      await ledger.saveRecord(
        commandId: 'cmd-expense-recent',
        draft: RecordDraft(
          bookId: 1,
          type: RecordType.expense,
          money: Money.parse('400.00'),
          assetId: cardId,
          recordTime: recentTime,
          categoryId: 1,
          remark: '测试消费',
        ),
      );
      await ledger.saveRecord(
        commandId: 'cmd-expense-older',
        draft: RecordDraft(
          bookId: 1,
          type: RecordType.expense,
          money: Money.parse('180.00'),
          assetId: cardId,
          recordTime: olderTime,
          categoryId: 1,
          remark: '上期聚餐',
        ),
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const TallyIsleApp(),
        ),
      );

      Future<void> settle() async {
        for (var i = 0; i < 10; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
      }

      await settle();

      // Navigate to Assets page and open credit card detail.
      await tester.tap(find.text('资产'));
      await settle();

      expect(find.text('招行经典白'), findsOneWidget);
      await tester.tap(find.text('招行经典白'));
      await settle();

      // 1. Unified dual-metric header + sticky bar + flows are immediately visible
      //    on the first screen WITHOUT scrolling!
      expect(find.text('信用账户'), findsOneWidget);
      expect(find.byKey(const Key('credit-current-debt')), findsOneWidget);
      expect(find.byKey(const Key('credit-usable-limit')), findsOneWidget);
      expect(find.byKey(const Key('asset-sticky-control-bar')), findsOneWidget);
      expect(find.byKey(const Key('reconciliation-switch')), findsOneWidget);
      expect(find.text('-400.00'), findsOneWidget);
      expect(find.textContaining('测试消费'), findsOneWidget);
      expect(find.byType(RecordTypeIconAvatar), findsWidgets);
      // Redundant self-account name is omitted from single-account expense subtitle.
      expect(find.textContaining('招行经典白 · 测试消费'), findsNothing);

      // 2. Switch to "账期账单" tab.
      await tester.tap(find.byKey(const Key('credit-tab-statements')));
      await settle();

      expect(find.byKey(const Key('statement-year-label')), findsOneWidget);
      expect(find.text('${now.year}年'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_drop_down), findsNothing);
      expect(find.textContaining('期账单'), findsWidgets);

      // Test StickyStatementYearSwitcher prev/reset + year-only picker dialog.
      await tester.tap(find.byKey(const Key('statement-year-prev')));
      await settle();
      expect(find.text('${now.year - 1}年'), findsOneWidget);
      expect(find.byKey(const Key('statement-year-reset')), findsOneWidget);
      await tester.tap(find.byKey(const Key('statement-year-reset')));
      await settle();
      expect(find.text('${now.year}年'), findsOneWidget);

      final futureToggle = find.byKey(
        const Key('credit-toggle-future-periods'),
      );
      if (futureToggle.evaluate().isNotEmpty) {
        final foldedCount = find.textContaining('期账单').evaluate().length;
        expect(foldedCount, lessThan(12));
        await tester.ensureVisible(futureToggle);
        await settle();
        await tester.tap(futureToggle);
        await settle();
        expect(
          find.textContaining('期账单').evaluate().length,
          greaterThan(foldedCount),
        );
      }

      // 3. Tap the topmost visible statement card with a bill to filter flows to that cycle.
      final targetCard = find.widgetWithText(Card, '1笔').evaluate().isNotEmpty
          ? find.widgetWithText(Card, '1笔').first
          : find.byWidgetPredicate((w) {
              final k = w.key;
              return k is ValueKey<String> &&
                  k.value.startsWith('credit-statement-card-');
            }).first;
      await tester.ensureVisible(targetCard);
      await settle();
      await tester.tap(targetCard);
      await settle();

      // Automatically switched back to "流水明细" with continuous period filter bar!
      expect(find.byKey(const Key('credit-period-filter-bar')), findsOneWidget);
      expect(find.byKey(const Key('flow-filter-prev')), findsOneWidget);
      expect(find.byKey(const Key('flow-filter-next')), findsOneWidget);
      expect(find.byKey(const Key('flow-filter-pick')), findsOneWidget);
      expect(
        find.byKey(const Key('clear-credit-period-filter')),
        findsOneWidget,
      );

      // Step to previous period via continuous nav button & verify no crash/overflow.
      await tester.tap(find.byKey(const Key('flow-filter-prev')));
      await settle();
      expect(find.byKey(const Key('credit-period-filter-bar')), findsOneWidget);

      // Tap period picker trigger on filter bar -> opens 3x4 credit period picker!
      await tester.tap(find.byKey(const Key('flow-filter-pick')));
      await settle();
      expect(find.byKey(const Key('cp-picker-period-1')), findsOneWidget);
      expect(find.byKey(const Key('cp-picker-period-12')), findsOneWidget);
      expect(find.byIcon(Icons.arrow_drop_down), findsNothing);
      await tester.tap(find.byKey(const Key('cp-picker-period-4')));
      await settle();
      expect(find.textContaining('第4期'), findsWidgets);

      // Clear period filter -> restores unfiltered flow view.
      await tester.tap(find.byKey(const Key('clear-credit-period-filter')));
      await settle();
      expect(find.byKey(const Key('credit-period-filter-bar')), findsNothing);
      expect(find.text('-400.00'), findsOneWidget);
      expect(find.text('-180.00'), findsOneWidget);

      // Tap calendar quick-jump button on sticky bar -> opens credit period picker!
      await tester.tap(find.byKey(const Key('asset-flow-period-picker-btn')));
      await settle();
      expect(
        find.byKey(const Key('cp-picker-toggle-year-grid')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('cp-picker-toggle-year-grid')));
      await settle();
      expect(find.byKey(Key('cp-picker-year-${now.year}')), findsOneWidget);
      await tester.tap(find.byKey(Key('cp-picker-year-${now.year}')));
      await settle();
      await tester.tap(find.byKey(const Key('cp-picker-period-1')));
      await settle();
      expect(find.byKey(const Key('credit-period-filter-bar')), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await settle();
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    '360x640 @ 1.2x text scale: zero overflow on Fund & Credit sticky year switcher (with reset pill), filter bars, and 3x4 credit period picker dialog',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final db = AppDatabase(NativeDatabase.memory());
      final container = ProviderContainer(
        overrides: [databaseProvider.overrideWith((ref) async => db)],
      );
      final ledger = await container.read(ledgerServiceProvider.future);
      final now = DateTime.now();

      final fundId = await ledger.createAsset(
        commandId: 'stress-fund',
        name: '招商储蓄卡',
        initial: Money.parse('8800.00'),
      );
      final creditInfo = CreditInfo()
        ..billDay = 10
        ..repaymentDay = 28
        ..billDayCounted = true;
      final creditId = await ledger.createAsset(
        commandId: 'stress-credit',
        name: '招商经典白',
        type: AssetType.credit,
        limit: Money.parse('20000.00'),
        initial: -Money.parse('680.00'),
        creditInfo: creditInfo.encode(),
      );

      await ledger.saveRecord(
        commandId: 'stress-fund-rec',
        draft: RecordDraft(
          bookId: 1,
          type: RecordType.expense,
          money: Money.parse('66.00'),
          assetId: fundId,
          recordTime: DateTime(
            now.year,
            now.month,
            5,
            12,
          ).millisecondsSinceEpoch,
          categoryId: 1,
        ),
      );
      await ledger.saveRecord(
        commandId: 'stress-credit-rec',
        draft: RecordDraft(
          bookId: 1,
          type: RecordType.expense,
          money: Money.parse('128.00'),
          assetId: creditId,
          recordTime: DateTime(
            now.year,
            now.month,
            5,
            12,
          ).millisecondsSinceEpoch,
          categoryId: 1,
        ),
      );

      Future<void> settle() async {
        for (var i = 0; i < 10; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
      }

      Widget wrap(Widget home) => UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            useMaterial3: true,
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.2)),
            child: child ?? const SizedBox.shrink(),
          ),
          home: home,
        ),
      );

      // 1. Fund account @ 360x640 1.2x
      await tester.pumpWidget(wrap(AssetDetailPage(assetId: fundId)));
      await settle();
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const Key('fund-tab-statements')));
      await settle();
      expect(tester.takeException(), isNull);

      // Trigger reset pill next to year switcher on narrow 360dp @ 1.2x!
      await tester.tap(find.byKey(const Key('statement-year-prev')));
      await settle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('statement-year-reset')), findsOneWidget);
      expect(find.text('今年'), findsOneWidget);

      await tester.tap(find.byKey(const Key('statement-year-reset')));
      await settle();
      await tester.tap(
        find.byKey(Key('fund-statement-card-${now.year}-${now.month}')),
      );
      await settle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('fund-month-filter-bar')), findsOneWidget);

      // 2. Credit account @ 360x640 1.2x
      await tester.pumpWidget(wrap(AssetDetailPage(assetId: creditId)));
      await settle();
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const Key('credit-tab-statements')));
      await settle();
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const Key('statement-year-prev')));
      await settle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('statement-year-reset')), findsOneWidget);

      await tester.tap(find.byKey(const Key('credit-tab-flows')));
      await settle();
      expect(tester.takeException(), isNull);

      // Open 3x4 credit period picker dialog @ 360x640 1.2x!
      await tester.tap(find.byKey(const Key('asset-flow-period-picker-btn')));
      await settle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('cp-picker-period-12')), findsOneWidget);

      await tester.tap(find.byKey(const Key('cp-picker-period-4')));
      await settle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('credit-period-filter-bar')), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await settle();
      await tester.pump(const Duration(seconds: 1));
    },
  );
}
