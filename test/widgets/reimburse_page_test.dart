import 'package:drift/drift.dart'
    show BooleanExpressionOperators, Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/catalog/catalog_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/features/reimburse/reimburse_page.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<void> settle(WidgetTester tester, [int steps = 12]) async {
    for (var i = 0; i < steps; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<int> firstExpenseCategoryId(AppDatabase db, int bookId) async {
    final cats = await (db.select(
      db.recordCategories,
    )..where((c) => c.accountBookId.equals(bookId) & c.type.equals(0))).get();
    return cats.first.id;
  }

  testWidgets(
    'ReimbursePage renders empty state cleanly on 360x640 and routes quick-add actions to /record/new?type=3',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      final pushedRoutes = <String>[];
      final router = GoRouter(
        initialLocation: '/reimburse',
        routes: [
          GoRoute(path: '/reimburse', builder: (_, _) => const ReimbursePage()),
          GoRoute(
            path: '/record/new',
            builder: (context, state) {
              pushedRoutes.add(state.uri.toString());
              return Scaffold(appBar: AppBar(title: Text('新建:${state.uri}')));
            },
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await settle(tester);

      expect(find.text('报销管理'), findsOneWidget);
      expect(find.byKey(const Key('reimburse-scope-toggle')), findsOneWidget);
      expect(find.text('当前账本'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('reimburse-pending-total')))
            .data,
        '¥0.00',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('reimburse-pending-count')))
            .data,
        '0 笔',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('reimburse-settled-total')))
            .data,
        '¥0.00',
      );
      expect(find.text('待报销 (0)'), findsOneWidget);
      expect(find.text('已报销 (0)'), findsOneWidget);
      expect(find.text('记一笔待报销支出'), findsOneWidget);

      // Empty state CTA routes to /record/new?type=3
      await tester.tap(find.text('记一笔待报销支出'));
      await settle(tester);
      expect(pushedRoutes, contains('/record/new?type=3'));

      router.pop();
      await settle(tester);

      // AppBar quick add button routes to /record/new?type=3
      await tester.tap(find.byKey(const Key('reimburse-add-btn')));
      await settle(tester);
      expect(pushedRoutes.length, 2);
      expect(pushedRoutes.last, '/record/new?type=3');

      await tester.pumpWidget(const SizedBox());
      await settle(tester, 4);
    },
  );

  testWidgets(
    'ReimbursePage supports book scope toggle, partial reimbursement, over-reimbursement diff badge, and tap-through',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      final ledger = LedgerService(db);
      final catalog = CatalogService(db);

      final bankId = await ledger.createAsset(
        commandId: 'seed-bank',
        name: '招行储蓄卡',
        initial: Money.parse('1000.00'),
      );
      final book1CatId = await firstExpenseCategoryId(db, 1);

      final book2Id = await catalog.createBook(
        commandId: 'seed-book-2',
        name: '公司账本',
      );
      final book2CatId = await firstExpenseCategoryId(db, book2Id);

      final billAId = await ledger.saveRecord(
        commandId: 'seed-bill-a',
        draft: RecordDraft(
          type: RecordType.reimbursable,
          money: Money.parse('100.00'),
          bookId: 1,
          recordTime: DateTime(2026, 11, 10, 10).millisecondsSinceEpoch,
          categoryId: book1CatId,
          fromAssetId: bankId,
          remark: '差旅机票',
        ),
      );
      final billBId = await ledger.saveRecord(
        commandId: 'seed-bill-b',
        draft: RecordDraft(
          type: RecordType.reimbursable,
          money: Money.parse('50.00'),
          bookId: 1,
          recordTime: DateTime(2026, 11, 11, 12).millisecondsSinceEpoch,
          categoryId: book1CatId,
          fromAssetId: bankId,
          remark: '项目打车',
        ),
      );
      await ledger.saveRecord(
        commandId: 'seed-bill-c',
        draft: RecordDraft(
          type: RecordType.reimbursable,
          money: Money.parse('80.00'),
          bookId: book2Id,
          recordTime: DateTime(2026, 11, 11, 15).millisecondsSinceEpoch,
          categoryId: book2CatId,
          fromAssetId: bankId,
          remark: '客户招待',
        ),
      );

      final tappedIds = <String>[];
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: MaterialApp(home: ReimbursePage(onRecordTap: tappedIds.add)),
        ),
      );
      await settle(tester);

      // 1. Default scope = 当前账本 (Book 1): 100 + 50 = 150.00 across 2 bills
      expect(
        tester
            .widget<Text>(find.byKey(const Key('reimburse-pending-total')))
            .data,
        '¥150.00',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('reimburse-pending-count')))
            .data,
        '2 笔',
      );
      expect(find.text('差旅机票'), findsOneWidget);
      expect(find.text('项目打车'), findsOneWidget);
      expect(find.text('客户招待'), findsNothing);

      // 2. Toggle scope -> 全部账本: 100 + 50 + 80 = 230.00 across 3 bills
      await tester.tap(find.byKey(const Key('reimburse-scope-toggle')));
      await settle(tester);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('reimburse-pending-total')))
            .data,
        '¥230.00',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('reimburse-pending-count')))
            .data,
        '3 笔',
      );
      expect(find.text('客户招待'), findsOneWidget);
      expect(find.textContaining('公司账本'), findsOneWidget);

      // Toggle back to 当前账本
      await tester.tap(find.byKey(const Key('reimburse-scope-toggle')));
      await settle(tester);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('reimburse-pending-total')))
            .data,
        '¥150.00',
      );

      // 3. Partial reimbursement on Bill A (100.00 -> reimburse 40.00)
      await tester.tap(find.byKey(Key('reimburse-action-$billAId')));
      await settle(tester);

      final amountField = find.byKey(const Key('reimburse-dialog-amount'));
      expect(tester.widget<TextField>(amountField).controller?.text, '100.00');
      expect(find.text('全额结清'), findsOneWidget);

      await tester.enterText(amountField, '40.00');
      await tester.pump();
      expect(find.text('报销后剩余待报 ¥60.00'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('reimburse-dialog-remark')),
        '先报一部分',
      );
      await tester.tap(find.byKey(const Key('reimburse-dialog-confirm')));
      await settle(tester);

      // Bill A remains pending with 60.00 remaining and '已报 ¥40.00' chip!
      expect(find.text('已报 ¥40.00'), findsOneWidget);
      expect(find.text('待报 ¥60.00'), findsOneWidget);
      expect(find.text('垫付 ¥100.00'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('reimburse-pending-total')))
            .data,
        '¥110.00',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('reimburse-settled-total')))
            .data,
        '¥40.00',
      );

      // 4. Over-reimbursement on Bill B (50.00 -> reimburse 65.00, +15.00 diff)
      await tester.tap(find.byKey(Key('reimburse-action-$billBId')));
      await settle(tester);

      await tester.enterText(
        find.byKey(const Key('reimburse-dialog-amount')),
        '65.00',
      );
      await tester.pump();
      expect(find.text('超出垫付 +¥15.00'), findsOneWidget);

      await tester.tap(find.byKey(const Key('reimburse-dialog-confirm')));
      await settle(tester);

      // Pending now only has Bill A (remaining 60.00); settled has Bill B (65.00)
      expect(
        tester
            .widget<Text>(find.byKey(const Key('reimburse-pending-total')))
            .data,
        '¥60.00',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('reimburse-pending-count')))
            .data,
        '1 笔',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('reimburse-settled-total')))
            .data,
        '¥105.00',
      );
      expect(find.text('已报销 (1)'), findsOneWidget);

      // 5. Switch to Settled tab -> verify '已报销' & '+¥15.00 差额' badge & tap-through
      await tester.tap(find.byKey(const Key('reimburse-tab-settled')));
      await settle(tester);

      expect(find.text('项目打车'), findsOneWidget);
      expect(find.text('已报销'), findsOneWidget);
      expect(find.text('+¥15.00 差额'), findsOneWidget);
      expect(find.textContaining('1 笔收款'), findsOneWidget);

      await tester.tap(find.text('项目打车'));
      await settle(tester);
      expect(tappedIds, equals([billBId]));

      // Verify bank balance: 1000 - 100 - 50 - 80 + 40 + 65 = 875.00 (87500 minor)
      final bankAfter = await (db.select(
        db.assets,
      )..where((a) => a.id.equals(bankId))).getSingle();
      expect(bankAfter.balanceMinor, BigInt.from(87500));

      await tester.pumpWidget(const SizedBox());
      await settle(tester, 4);
    },
  );

  testWidgets(
    'ReimbursePage batch multi-select mode settles multiple bills accurately and updates receiving account balance',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      final ledger = LedgerService(db);
      final payCardId = await ledger.createAsset(
        commandId: 'seed-pay-card',
        name: '工行卡',
        initial: Money.parse('2000.00'),
      );
      final receiveAlipayId = await ledger.createAsset(
        commandId: 'seed-receive-alipay',
        name: '支付宝',
        initial: Money.parse('500.00'),
      );
      await (db.update(db.assets)..where((a) => a.id.equals(receiveAlipayId)))
          .write(const AssetsCompanion(isDefault: Value(true)));
      final catId = await firstExpenseCategoryId(db, 1);

      final id1 = await ledger.saveRecord(
        commandId: 'batch-b1',
        draft: RecordDraft(
          type: RecordType.reimbursable,
          money: Money.parse('120.00'),
          bookId: 1,
          recordTime: DateTime(2026, 11, 8, 9).millisecondsSinceEpoch,
          categoryId: catId,
          fromAssetId: payCardId,
          remark: '高铁票',
        ),
      );
      final id2 = await ledger.saveRecord(
        commandId: 'batch-b2',
        draft: RecordDraft(
          type: RecordType.reimbursable,
          money: Money.parse('45.50'),
          bookId: 1,
          recordTime: DateTime(2026, 11, 9, 10).millisecondsSinceEpoch,
          categoryId: catId,
          fromAssetId: payCardId,
          remark: '市内出租',
        ),
      );
      final id3 = await ledger.saveRecord(
        commandId: 'batch-b3',
        draft: RecordDraft(
          type: RecordType.reimbursable,
          money: Money.parse('200.00'),
          bookId: 1,
          recordTime: DateTime(2026, 11, 10, 11).millisecondsSinceEpoch,
          categoryId: catId,
          fromAssetId: payCardId,
          remark: '会议酒店',
        ),
      );
      // Pre-reimburse 50.00 on id3 so its remainingMinor is 150.00
      await ledger.addReimbursement(
        commandId: 'pre-reimburse-id3',
        originId: id3,
        amount: Money.parse('50.00'),
        assetId: receiveAlipayId,
        recordTime: DateTime(2026, 11, 10, 18).millisecondsSinceEpoch,
      );

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: const MaterialApp(home: ReimbursePage()),
        ),
      );
      await settle(tester);

      // Total pending = 120.00 + 45.50 + 150.00 = 315.50
      expect(
        tester
            .widget<Text>(find.byKey(const Key('reimburse-pending-total')))
            .data,
        '¥315.50',
      );

      // Enter batch selection mode
      await tester.tap(find.byKey(const Key('reimburse-batch-toggle')));
      await settle(tester);

      expect(find.byKey(Key('reimburse-select-$id1')), findsOneWidget);
      expect(find.byKey(Key('reimburse-select-$id2')), findsOneWidget);
      expect(find.byKey(Key('reimburse-select-$id3')), findsOneWidget);
      expect(find.text('已选 0 笔 · 合计 ¥0.00'), findsOneWidget);

      // Select id1 via checkbox, then tap '全选'
      await tester.tap(find.byKey(Key('reimburse-select-$id1')));
      await tester.pump();
      expect(find.text('已选 1 笔 · 合计 ¥120.00'), findsOneWidget);

      await tester.tap(find.text('全选'));
      await tester.pump();
      expect(find.text('已选 3 笔 · 合计 ¥315.50'), findsOneWidget);

      // Submit batch reimbursement -> opens _BatchReimburseSheet defaulting to '支付宝'
      await tester.tap(find.byKey(const Key('reimburse-batch-submit')));
      await settle(tester);

      expect(find.text('合并报销（3 笔）'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('reimburse-batch-remark')),
        '11月集中报销',
      );
      await tester.tap(find.byKey(const Key('reimburse-batch-confirm')));
      await settle(tester);

      // All 3 bills are now settled!
      expect(
        tester
            .widget<Text>(find.byKey(const Key('reimburse-pending-total')))
            .data,
        '¥0.00',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('reimburse-pending-count')))
            .data,
        '0 笔',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('reimburse-settled-total')))
            .data,
        '¥365.50',
      );
      expect(find.text('已报销 (3)'), findsOneWidget);

      // Receiving account '支付宝': 500.00 + 50.00 (pre) + 315.50 (batch) = 865.50 (86550 minor)
      final alipayAfter = await (db.select(
        db.assets,
      )..where((a) => a.id.equals(receiveAlipayId))).getSingle();
      expect(alipayAfter.balanceMinor, BigInt.from(86550));

      await tester.pumpWidget(const SizedBox());
      await settle(tester, 4);
    },
  );

  testWidgets(
    'ReimbursePage filters out settled/debt accounts in picker, defaults tap-through to /record/:id, and reacts to receipt deletion',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      final ledger = LedgerService(db);
      final cashId = await ledger.createAsset(
        commandId: 'seed-cash',
        name: '日常现金',
        initial: Money.parse('200.00'),
      );
      final wechatId = await ledger.createAsset(
        commandId: 'seed-wechat',
        name: '微信零钱',
        initial: Money.parse('300.00'),
      );
      final settledCardId = await ledger.createAsset(
        commandId: 'seed-settled',
        name: '已销户旧卡',
        initial: Money.zero(),
      );
      await (db.update(db.assets)..where((a) => a.id.equals(settledCardId)))
          .write(const AssetsCompanion(status: Value(AssetStatus.settled)));
      await (db.into(db.assets)).insert(
        AssetsCompanion.insert(
          name: '张三借款',
          balanceMinor: BigInt.from(10000),
          type: AssetType.debt,
          subType: const Value(AssetType.debtLend),
          createDate: 1000,
          initMoneyMinor: BigInt.from(10000),
        ),
      );

      final catId = await firstExpenseCategoryId(db, 1);
      // Bill with empty remark should fall back to category name as title
      final billId = await ledger.saveRecord(
        commandId: 'seed-cat-fallback-bill',
        draft: RecordDraft(
          type: RecordType.reimbursable,
          money: Money.parse('88.00'),
          bookId: 1,
          recordTime: DateTime(2026, 11, 12, 9).millisecondsSinceEpoch,
          categoryId: catId,
          fromAssetId: cashId,
        ),
      );

      final visitedDetailIds = <String>[];
      final router = GoRouter(
        initialLocation: '/reimburse',
        routes: [
          GoRoute(path: '/reimburse', builder: (_, _) => const ReimbursePage()),
          GoRoute(
            path: '/record/:id',
            builder: (_, state) {
              final id = state.pathParameters['id']!;
              visitedDetailIds.add(id);
              return Scaffold(appBar: AppBar(title: Text('详情:$id')));
            },
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await settle(tester);

      // Default tap-through when onRecordTap is null -> /record/:id
      await tester.tap(find.text('待报 ¥88.00'));
      await settle(tester);
      expect(visitedDetailIds, equals([billId]));

      router.pop();
      await settle(tester);

      // Open single reimburse dialog and switch receiving account to '微信零钱'
      await tester.tap(find.byKey(Key('reimburse-action-$billId')));
      await settle(tester);

      await tester.tap(find.byKey(const Key('reimburse-dialog-account')));
      await settle(tester);
      // Settled and debt accounts must NOT appear in receiving account options
      expect(find.text('已销户旧卡'), findsNothing);
      expect(find.text('张三借款'), findsNothing);
      expect(find.text('微信零钱'), findsWidgets);

      await tester.tap(find.text('微信零钱').last);
      await settle(tester);

      await tester.tap(find.byKey(const Key('reimburse-dialog-confirm')));
      await settle(tester);

      expect(find.text('待报销 (0)'), findsOneWidget);
      expect(find.text('已报销 (1)'), findsOneWidget);

      final wechatAfter = await (db.select(
        db.assets,
      )..where((a) => a.id.equals(wechatId))).getSingle();
      expect(wechatAfter.balanceMinor, BigInt.from(38800));

      // Delete the generated type=15 receipt -> bill reactively returns to 待报销 (1)!
      final receiptRow = await (db.select(
        db.records,
      )..where((r) => r.type.equals(RecordType.reimburseReceipt))).getSingle();
      await ledger.deleteRecord(
        commandId: 'del-receipt',
        recordId: receiptRow.recordId,
      );
      await settle(tester);

      expect(find.text('待报销 (1)'), findsOneWidget);
      expect(find.text('已报销 (0)'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('reimburse-pending-total')))
            .data,
        '¥88.00',
      );

      await tester.pumpWidget(const SizedBox());
      await settle(tester, 4);
    },
  );
}
