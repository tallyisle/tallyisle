import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/features/stats/annual_report_page.dart';

void main() {
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  testWidgets('AnnualReportOverviewCard renders and triggers onTap callback', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(() => db.close());

    // Insert an asset and a record in the current year
    final now = DateTime.now();
    final year = now.year;

    await db
        .into(db.assets)
        .insert(
          AssetsCompanion.insert(
            id: const Value(1),
            name: '招商银行',
            balanceMinor: BigInt.from(100000),
            initMoneyMinor: BigInt.from(100000),
            type: 1,
            createDate: 1700000000000,
          ),
        );

    await db
        .into(db.records)
        .insert(
          RecordsCompanion.insert(
            recordId: 'rec-test-1',
            type: 0, // expense
            moneyMinor: BigInt.from(8800), // 88.00 CNY
            accountBookId: 1,
            assetId: const Value(1),
            recordCatId: const Value(1),
            recordTime: DateTime(year, 2, 10, 12, 0).millisecondsSinceEpoch,
          ),
        );

    var tapped = false;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWith((ref) async => db)],
        child: MaterialApp(
          home: Scaffold(
            body: AnnualReportOverviewCard(
              onTap: () {
                tapped = true;
              },
            ),
          ),
        ),
      ),
    );

    await settle(tester);

    expect(
      find.byKey(const Key('annual-report-overview-card')),
      findsOneWidget,
    );
    expect(find.text('$year年度统计'), findsOneWidget);
    expect(find.text('-¥88.00'), findsNWidgets(2));
    expect(find.text('查看年度账单与报告 >'), findsOneWidget);

    await tester.tap(find.byKey(const Key('annual-report-overview-card')));
    await settle(tester);

    expect(tapped, isTrue);

    // Cleanup tree so drift stream queries cancel
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets(
    'AnnualReportPage renders bill table, toggles tabs, switches years and triggers record tap',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(() => db.close());

      // Insert asset
      await db
          .into(db.assets)
          .insert(
            AssetsCompanion.insert(
              id: const Value(10),
              name: '微信钱包',
              balanceMinor: BigInt.from(500000),
              initMoneyMinor: BigInt.from(500000),
              type: 1,
              createDate: 1700000000000,
            ),
          );

      // Insert records for 2026:
      // 1. May 15: 120.00 CNY expense (12000 minor)
      await db
          .into(db.records)
          .insert(
            RecordsCompanion.insert(
              recordId: 'rec-2026-may',
              type: 0,
              moneyMinor: BigInt.from(12000),
              accountBookId: 1,
              assetId: const Value(10),
              recordCatId: const Value(1), // 餐饮
              recordTime: DateTime(2026, 5, 15, 12, 0).millisecondsSinceEpoch,
              discountMinor: Value(BigInt.from(500)), // 5.00 CNY discount
            ),
          );

      // 2. May 20: 300.00 CNY expense (30000 minor) - will be max expense
      await db
          .into(db.records)
          .insert(
            RecordsCompanion.insert(
              recordId: 'rec-2026-max-exp',
              type: 0,
              moneyMinor: BigInt.from(30000),
              accountBookId: 1,
              assetId: const Value(10),
              recordCatId: const Value(1), // 餐饮
              recordTime: DateTime(2026, 5, 20, 18, 0).millisecondsSinceEpoch,
            ),
          );

      // 3. June 1: 500.00 CNY income (50000 minor)
      await db
          .into(db.records)
          .insert(
            RecordsCompanion.insert(
              recordId: 'rec-2026-inc',
              type: 1,
              moneyMinor: BigInt.from(50000),
              accountBookId: 1,
              assetId: const Value(10),
              recordCatId: const Value(13), // 工资
              recordTime: DateTime(2026, 6, 1, 9, 0).millisecondsSinceEpoch,
            ),
          );

      String? tappedRecordId;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: MaterialApp(
            home: AnnualReportPage(
              initialYear: 2026,
              onRecordTap: (id) {
                tappedRecordId = id;
              },
            ),
          ),
        ),
      );

      await settle(tester);

      // 1. Default Tab: 年度账单
      expect(find.byKey(const Key('annual-report-bill-view')), findsOneWidget);
      expect(find.text('2026年'), findsOneWidget);
      expect(find.text('总结余'), findsOneWidget);
      expect(find.text('总支出'), findsOneWidget);
      expect(find.text('总收入'), findsOneWidget);

      // Total expense = 120 + 300 = 420.00
      // Total income = 500.00
      // Total balance = 80.00
      expect(find.text('¥420.00'), findsOneWidget);
      expect(find.text('¥500.00'), findsOneWidget);
      expect(find.text('¥80.00'), findsOneWidget);

      // 12 months table rows present
      expect(find.text('5月'), findsOneWidget);
      expect(find.text('6月'), findsOneWidget);
      expect(find.text('-¥420.00'), findsNWidgets(2)); // June expense & balance
      expect(find.text('+¥500.00'), findsNWidgets(2)); // June income & balance

      // Test sort toggle (1月至12月 <-> 12月至1月)
      expect(
        find.byKey(const Key('annual-report-toggle-sort-button')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const Key('annual-report-toggle-sort-button')),
      );
      await settle(tester);
      expect(find.text('12月至1月'), findsOneWidget);

      // 2. Switch to Tab: 年度报告
      await tester.tap(find.text('年度报告'));
      await settle(tester);

      expect(
        find.byKey(const Key('annual-report-highlight-view')),
        findsOneWidget,
      );
      expect(find.text('2026 年度记账回顾'), findsOneWidget);
      expect(find.text('收支之最'), findsOneWidget);
      expect(find.text('单笔最高支出'), findsOneWidget);
      expect(find.text('-¥300.00'), findsOneWidget);
      expect(find.text('单笔最高收入'), findsOneWidget);
      expect(find.text('+¥500.00'), findsOneWidget);

      // Tap single max expense record tile
      expect(
        find.byKey(const Key('annual-report-max-expense-record-tile')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const Key('annual-report-max-expense-record-tile')),
      );
      await settle(tester);
      expect(tappedRecordId, 'rec-2026-max-exp');

      // 3. Year switching: Previous Year -> 2025
      await tester.tap(find.byKey(const Key('annual-report-prev-year-button')));
      await settle(tester);
      expect(find.text('2025年'), findsOneWidget);

      // Next Year -> 2026
      await tester.tap(find.byKey(const Key('annual-report-next-year-button')));
      await settle(tester);
      expect(find.text('2026年'), findsOneWidget);

      // 4. Book filter toggle
      expect(
        find.byKey(const Key('annual-report-book-filter-chip')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('annual-report-book-filter-chip')));
      await settle(tester);
      expect(find.text('全部账本'), findsOneWidget);

      // Cleanup tree so drift stream queries cancel
      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
    },
  );
}
