import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/features/stats/category_stats_page.dart';

Money m(String s) => Money.parse(s);

void main() {
  testWidgets(
    'CategoryStatsPage: dimension switch, rollup vs flatten, drilldown & uncategorized row',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final db = AppDatabase(NativeDatabase.memory());
      final ledger = LedgerService(db);

      var cmdCounter = 0;
      String cmd() => 'cmd-catstats-widget-${cmdCounter++}';

      // 1. Setup accounts and categories
      final cash = await ledger.createAsset(
        commandId: cmd(),
        name: '现金',
        initial: m('2000.00'),
      );

      final diningParent =
          (await (db.select(db.recordCategories)..where(
                    (t) => t.accountBookId.equals(1) & t.name.equals('餐饮'),
                  ))
                  .getSingle())
              .id;

      // Create subcategory under 餐饮
      final mealChild = await db
          .into(db.recordCategories)
          .insert(
            RecordCategoriesCompanion.insert(
              name: '正餐',
              accountBookId: 1,
              parentCatId: Value(diningParent),
              type: 0,
              sort: const Value(1),
            ),
          );

      final salaryCat =
          (await (db.select(db.recordCategories)..where(
                    (t) => t.accountBookId.equals(1) & t.name.equals('工资'),
                  ))
                  .getSingle())
              .id;

      final now = DateTime.now();
      final nowMs = now.millisecondsSinceEpoch;

      // Direct dining bill: 30.00
      await ledger.saveRecord(
        commandId: cmd(),
        draft: RecordDraft(
          type: RecordType.expense,
          money: m('30.00'),
          bookId: 1,
          recordTime: nowMs,
          categoryId: diningParent,
          assetId: cash,
          remark: '晚餐水果',
        ),
      );

      // Subcategory meal bill: 120.00
      await ledger.saveRecord(
        commandId: cmd(),
        draft: RecordDraft(
          type: RecordType.expense,
          money: m('120.00'),
          bookId: 1,
          recordTime: nowMs + 1000,
          categoryId: mealChild,
          assetId: cash,
          remark: '正餐聚餐',
        ),
      );

      // Uncategorized fee bill: 8.00
      await db
          .into(db.records)
          .insert(
            RecordsCompanion.insert(
              recordId: 'rec-fee-8',
              type: RecordType.fee,
              moneyMinor: BigInt.from(800),
              recordTime: nowMs + 2000,
              accountBookId: 1,
              recordCatId: const Value(noRef),
              assetId: Value(cash),
              remark: const Value('提现手续费'),
            ),
          );

      // Income bill: 1000.00
      await ledger.saveRecord(
        commandId: cmd(),
        draft: RecordDraft(
          type: RecordType.income,
          money: m('1000.00'),
          bookId: 1,
          recordTime: nowMs + 3000,
          categoryId: salaryCat,
          assetId: cash,
          remark: '本月工资',
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

      await tester.pumpWidget(
        ProviderScope(
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: const MaterialApp(home: CategoryStatsPage()),
        ),
      );

      await settle();

      // Verify Title and Header Amount
      // Total expense: 30 + 120 + 8 = 158.00
      expect(find.text('分类统计'), findsOneWidget);
      expect(find.byKey(const Key('header-total-amount')), findsOneWidget);
      expect(find.text('¥158.00'), findsOneWidget);
      expect(find.text('3 笔'), findsOneWidget);

      // Verify First-level rollup: 餐饮 row exists
      expect(find.byKey(Key('category-row-$diningParent')), findsOneWidget);
      expect(find.text('餐饮'), findsOneWidget);
      // 150.00 / 158.00 = 94.94%
      expect(find.text('¥150.00'), findsOneWidget);

      // Verify Uncategorized fallback closing row (ASYM-CAT-01)
      expect(
        find.byKey(const Key('category-row-uncategorized')),
        findsOneWidget,
      );
      expect(find.text('未分类 / 其他'), findsOneWidget);
      expect(find.text('¥8.00'), findsOneWidget);
      expect(find.text('兜底闭合'), findsOneWidget);

      // Expand 餐饮 row to see direct child "餐饮直属" and "正餐"
      final expandBtn = find.descendant(
        of: find.byKey(Key('category-row-$diningParent')),
        matching: find.byType(IconButton),
      );
      expect(expandBtn, findsOneWidget);
      await tester.tap(expandBtn);
      await settle();

      // R6 direct item check
      expect(find.text('餐饮直属'), findsOneWidget);
      expect(find.text('¥30.00'), findsOneWidget);
      expect(find.text('正餐'), findsOneWidget);
      expect(find.text('¥120.00'), findsOneWidget);

      // Switch to Flatten view (二级平铺)
      await tester.tap(find.text('二级平铺'));
      await settle();

      // In Flatten view: 餐饮直属 and 正餐 are flattened rows
      // Flatten denominator: 30 + 120 = 150.00
      // 正餐: 120 / 150 = 80.00%
      // 餐饮直属: 30 / 150 = 20.00%
      expect(find.text('平铺保留分母: ¥150.00 (F01)'), findsOneWidget);
      expect(find.text('80.00%'), findsOneWidget);
      expect(find.text('20.00%'), findsOneWidget);

      // Switch back to 一级汇总
      await tester.tap(find.text('一级汇总'));
      await settle();

      // Tap 餐饮 to enter CategoryDrilldownPage
      await tester.tap(find.text('餐饮'));
      await tester.pumpAndSettle();

      // In Drilldown page
      expect(find.text('包含账单明细 (2 笔)'), findsOneWidget);
      expect(find.text('晚餐水果'), findsOneWidget);
      expect(find.text('正餐聚餐'), findsOneWidget);

      // Toggle sort: 按金额
      final sortSwitch = find.byKey(const Key('drilldown-sort-switch'));
      expect(sortSwitch, findsOneWidget);
      await tester.tap(sortSwitch);
      await tester.pumpAndSettle();

      // Pop drilldown page
      await tester.pageBack();
      await tester.pumpAndSettle();

      // Switch dimension: 收入
      await tester.tap(find.text('收入'));
      await settle();

      // Income total: 1000.00 (both header and category row display ¥1000.00)
      expect(find.byKey(const Key('header-total-amount')), findsOneWidget);
      expect(find.text('¥1000.00'), findsNWidgets(2));
      expect(find.text('1 笔'), findsNWidgets(2));
      expect(find.text('工资'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await settle();
      await tester.pump(
        const Duration(seconds: 1),
      ); // drift stream-close timers
    },
  );

  testWidgets('CategoryStatsOverviewCard renders top 5 and handles clicks', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    final ledger = LedgerService(db);

    var cmdCounter = 0;
    String cmd() => 'cmd-overview-${cmdCounter++}';

    final cash = await ledger.createAsset(
      commandId: cmd(),
      name: '现金',
      initial: m('500.00'),
    );

    final dining =
        (await (db.select(db.recordCategories)..where(
                  (t) => t.accountBookId.equals(1) & t.name.equals('餐饮'),
                ))
                .getSingle())
            .id;

    await ledger.saveRecord(
      commandId: cmd(),
      draft: RecordDraft(
        type: RecordType.expense,
        money: m('45.00'),
        bookId: 1,
        recordTime: DateTime.now().millisecondsSinceEpoch,
        categoryId: dining,
        assetId: cash,
      ),
    );

    var openedDetail = false;

    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
    }

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWith((ref) async => db)],
        child: MaterialApp(
          home: Scaffold(
            body: CategoryStatsOverviewCard(
              onOpenDetail: () => openedDetail = true,
            ),
          ),
        ),
      ),
    );

    await settle();

    expect(find.text('当月分类排行 Top 5'), findsOneWidget);
    expect(find.text('餐饮'), findsOneWidget);
    expect(find.text('¥45.00 (100.00%)'), findsOneWidget);

    await tester.tap(find.text('查看完整分析'));
    expect(openedDetail, isTrue);

    await tester.pumpWidget(const SizedBox());
    await settle();
    await tester.pump(const Duration(seconds: 1)); // drift stream-close timers
  });
}
