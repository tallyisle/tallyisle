import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/features/stats/asset_trend_page.dart';

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());

    // Update account book 1 with startDay = 5
    await db
        .into(db.accountBooks)
        .insertOnConflictUpdate(
          AccountBooksCompanion.insert(
            id: const drift.Value(1),
            name: '默认账本',
            createDate: 1700000000,
            startDay: const drift.Value(5),
          ),
        );

    // Seed currency USD
    await db
        .into(db.currencies)
        .insertOnConflictUpdate(
          CurrenciesCompanion.insert(
            code: 'USD',
            name: '美元',
            symbol: r'$',
            rateToAnchor: '0.14',
            anchorCode: 'CNY',
            enable: const drift.Value(true),
          ),
        );

    // 101: 招行储蓄卡, 1000 CNY
    await db
        .into(db.assets)
        .insert(
          AssetsCompanion.insert(
            id: const drift.Value(101),
            name: '招行储蓄卡',
            balanceMinor: BigInt.from(100000),
            initMoneyMinor: BigInt.from(50000),
            type: AssetType.normal,
            createDate: 1700000000,
          ),
        );

    // 102: 共享现金, 300 CNY
    await db
        .into(db.assets)
        .insert(
          AssetsCompanion.insert(
            id: const drift.Value(102),
            name: '现金',
            balanceMinor: BigInt.from(30000),
            initMoneyMinor: BigInt.zero,
            type: AssetType.normal,
            createDate: 1700000000,
          ),
        );

    // 103: 美元储蓄, 100 USD (@ 0.14 = 714.29 CNY)
    await db
        .into(db.assets)
        .insert(
          AssetsCompanion.insert(
            id: const drift.Value(103),
            name: '美元储蓄',
            balanceMinor: BigInt.from(10000),
            initMoneyMinor: BigInt.zero,
            type: AssetType.normal,
            currency: const drift.Value('USD'),
            createDate: 1700000000,
          ),
        );

    // 104: 招行信用卡, -200 CNY (debt)
    await db
        .into(db.assets)
        .insert(
          AssetsCompanion.insert(
            id: const drift.Value(104),
            name: '招行信用卡',
            balanceMinor: BigInt.from(-20000),
            initMoneyMinor: BigInt.zero,
            type: AssetType.credit,
            createDate: 1700000000,
          ),
        );

    // Records in 2026-03
    await db
        .into(db.records)
        .insert(
          RecordsCompanion.insert(
            recordId: 'R01',
            type: RecordType.expense,
            moneyMinor: BigInt.from(5000),
            recordTime: DateTime(2026, 3, 10).millisecondsSinceEpoch,
            assetId: const drift.Value(101),
            accountBookId: 1,
            createDate: const drift.Value(1700000000),
          ),
        );

    await db
        .into(db.records)
        .insert(
          RecordsCompanion.insert(
            recordId: 'R02',
            type: RecordType.income,
            moneyMinor: BigInt.from(20000),
            recordTime: DateTime(2026, 3, 15).millisecondsSinceEpoch,
            assetId: const drift.Value(101),
            accountBookId: 1,
            createDate: const drift.Value(1700000000),
          ),
        );

    // Record on USD account 103
    await db
        .into(db.records)
        .insert(
          RecordsCompanion.insert(
            recordId: 'R03_USD',
            type: RecordType.income,
            moneyMinor: BigInt.from(10000),
            recordTime: DateTime(2026, 3, 1).millisecondsSinceEpoch,
            assetId: const drift.Value(103),
            accountBookId: 1,
            createDate: const drift.Value(1700000000),
          ),
        );

    // Record on credit card 104
    await db
        .into(db.records)
        .insert(
          RecordsCompanion.insert(
            recordId: 'R04_CREDIT',
            type: RecordType.expense,
            moneyMinor: BigInt.from(20000),
            recordTime: DateTime(2026, 3, 5).millisecondsSinceEpoch,
            assetId: const drift.Value(104),
            accountBookId: 1,
            createDate: const drift.Value(1700000000),
          ),
        );
  });

  tearDown(() => db.close());

  Widget buildApp({int? initialAssetId}) {
    return ProviderScope(
      retry: (_, _) => null,
      overrides: [databaseProvider.overrideWith((ref) async => db)],
      child: MaterialApp(home: AssetTrendPage(initialAssetId: initialAssetId)),
    );
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  Future<void> cleanUp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('AssetTrendPage renders 3 cards', (tester) async {
    await tester.pumpWidget(buildApp());
    await settle(tester);

    // Verify AppBar title
    expect(find.text('资产趋势'), findsOneWidget);

    // Card 1: 资产状况
    expect(find.byKey(const Key('trend-card-distribution')), findsOneWidget);
    expect(find.text('资产状况'), findsOneWidget);
    expect(find.text('招行储蓄卡'), findsWidgets);

    // Card 2: 趋势图
    expect(find.byKey(const Key('trend-card-chart')), findsOneWidget);
    expect(find.text('净资产趋势'), findsOneWidget);

    // Card 3: 资产流水
    expect(find.byKey(const Key('trend-card-flow')), findsOneWidget);
    expect(find.text('资产流水'), findsOneWidget);

    await cleanUp(tester);
  });

  testWidgets(
    'Perspective switching: net worth, total asset, total liability',
    (tester) async {
      await tester.pumpWidget(buildApp());
      await settle(tester);

      // Default: 净资产趋势
      expect(find.text('净资产趋势'), findsOneWidget);

      // Tap 总资产
      await tester.tap(find.byKey(const Key('trend-perspective-totalAsset')));
      await settle(tester);
      expect(find.text('总资产趋势'), findsOneWidget);

      // Tap 总负债
      await tester.tap(
        find.byKey(const Key('trend-perspective-totalLiability')),
      );
      await settle(tester);
      expect(find.text('总负债趋势'), findsOneWidget);

      // Tap 净资产
      await tester.tap(find.byKey(const Key('trend-perspective-netWorth')));
      await settle(tester);
      expect(find.text('净资产趋势'), findsOneWidget);

      await cleanUp(tester);
    },
  );

  testWidgets(
    'Single credit card mode:欠款趋势 and no double negative (ASYM-AT-04b)',
    (tester) async {
      await tester.pumpWidget(buildApp(initialAssetId: 104));
      await settle(tester);

      expect(find.text('招行信用卡 趋势'), findsOneWidget);
      expect(find.text('欠款趋势'), findsOneWidget);

      // Arrears should be rendered without double negative: 欠款：¥200.00
      expect(find.text('欠款：¥200.00'), findsWidgets);
      expect(find.textContaining('欠款：-¥'), findsNothing);

      await cleanUp(tester);
    },
  );

  testWidgets(
    'Foreign currency single account: switch between base and original currency',
    (tester) async {
      await tester.pumpWidget(buildApp(initialAssetId: 103));
      await settle(tester);

      expect(find.text('美元储蓄 趋势'), findsOneWidget);
      expect(find.byKey(const Key('trend-currency-switch')), findsOneWidget);

      // By default: base currency CNY ¥
      expect(find.textContaining('¥714.29'), findsWidgets);

      // Switch to original currency USD $
      await tester.tap(find.byKey(const Key('trend-currency-switch')));
      await settle(tester);

      // In original currency mode: shows $100.00
      expect(find.textContaining(r'$100.00'), findsWidgets);

      await cleanUp(tester);
    },
  );

  testWidgets('Year selection: switch to 所有时间', (tester) async {
    await tester.pumpWidget(buildApp());
    await settle(tester);

    expect(find.byKey(const Key('trend-year-all')), findsOneWidget);
    await tester.tap(find.byKey(const Key('trend-year-all')));
    await settle(tester);

    // Card 3 flow list still present and responsive
    expect(find.byKey(const Key('trend-card-flow')), findsOneWidget);

    await cleanUp(tester);
  });

  testWidgets('AssetTrendOverviewCard displays summary and handles tap', (
    tester,
  ) async {
    var tapped = false;
    await tester.pumpWidget(
      ProviderScope(
        retry: (_, _) => null,
        overrides: [databaseProvider.overrideWith((ref) async => db)],
        child: MaterialApp(
          home: Scaffold(
            body: AssetTrendOverviewCard(onTap: () => tapped = true),
          ),
        ),
      ),
    );
    await settle(tester);

    expect(find.byKey(const Key('trend-overview-card')), findsOneWidget);
    expect(find.text('总净资产'), findsOneWidget);
    expect(find.textContaining('总资产'), findsOneWidget);

    await tester.tap(find.byKey(const Key('trend-overview-card')));
    await settle(tester);
    expect(tapped, true);

    await cleanUp(tester);
  });
}
