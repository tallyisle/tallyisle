import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/catalog/catalog_service.dart';
import 'package:tallyisle/data/catalog/currency_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/db/seed.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/data/repo/ledger_queries.dart';
import 'package:tallyisle/domain/ledger/record_extra.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/receipt_diy_rules.dart';
import 'package:tallyisle/features/assets/assets_page.dart';
import 'package:tallyisle/features/records/record_detail_page.dart';
import 'package:tallyisle/features/records/record_editor_page.dart';

Future<void> _settle(WidgetTester tester, [int steps = 10]) async {
  for (var i = 0; i < steps; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  group('Plan A: Interleaved account sorting UI', () {
    testWidgets(
      'mobile & desktop account picker toggles 排序/完成, hides 不选账户, interleaves credit card and persists order',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);

        final ledger = LedgerService(db);
        final cashId = await ledger.createAsset(
          commandId: 'p-cash',
          name: '现金账户',
          initial: Money.parse('100.00'),
        );
        final alipayId = await ledger.createAsset(
          commandId: 'p-alipay',
          name: '支付宝账户',
          initial: Money.parse('200.00'),
        );
        final huabeiId = await ledger.createAsset(
          commandId: 'p-huabei',
          name: '花呗信用',
          type: AssetType.credit,
          initial: Money.parse('-50.00'),
          limit: Money.parse('5000.00'),
        );
        // Set deterministic initial order: [Cash, Alipay, Huabei]
        await ledger.reorderAssets(
          commandId: 'p-init-order',
          orderedAssetIds: [cashId, alipayId, huabeiId],
        );

        // --- Mobile viewport (360x720 @ 1.2x text scale) ---
        tester.view.physicalSize = const Size(360, 720);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [databaseProvider.overrideWith((ref) async => db)],
            child: MediaQuery(
              data: const MediaQueryData(
                size: Size(360, 720),
                textScaler: TextScaler.linear(1.2),
              ),
              child: const MaterialApp(home: RecordEditorPage()),
            ),
          ),
        );
        await _settle(tester, 12);

        // Open account picker sheet
        await tester.tap(find.byKey(const Key('asset')));
        await _settle(tester, 8);

        final sheetScope = find.byType(BottomSheet);
        expect(
          find.descendant(of: sheetScope, matching: find.text('不选账户')),
          findsOneWidget,
        );
        expect(find.textContaining('信用账户 · CNY'), findsOneWidget);
        expect(
          find.byKey(const Key('toggle-account-picker-reorder-btn')),
          findsOneWidget,
        );
        expect(find.text('排序'), findsOneWidget);

        // Enter reorder mode -> hides 不选账户, shows ReorderableListView
        await tester.tap(
          find.byKey(const Key('toggle-account-picker-reorder-btn')),
        );
        await _settle(tester, 6);

        expect(find.text('完成'), findsOneWidget);
        expect(
          find.descendant(of: sheetScope, matching: find.text('不选账户')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('account-picker-reorder-list')),
          findsOneWidget,
        );
        expect(
          find.byKey(Key('account-picker-drag-$huabeiId')),
          findsOneWidget,
        );

        // Trigger onReorderItem directly (moves Huabei from index 2 to index 1 -> [Cash, Huabei, Alipay])
        final reorderList = tester.widget<ReorderableListView>(
          find.byKey(const Key('account-picker-reorder-list')),
        );
        reorderList.onReorderItem!(2, 1);
        await _settle(tester, 8);

        // Exit reorder mode back to selection mode
        await tester.tap(
          find.byKey(const Key('toggle-account-picker-reorder-btn')),
        );
        await _settle(tester, 6);
        expect(find.text('排序'), findsOneWidget);
        expect(
          find.descendant(of: sheetScope, matching: find.text('不选账户')),
          findsOneWidget,
        );

        final dbOrder = (await LedgerQueries(
          db,
        ).getAssets()).map((a) => a.id).toList();
        expect(dbOrder, [cashId, huabeiId, alipayId]);
        expect(tester.takeException(), isNull);

        // Dismiss sheet & switch to Desktop viewport (1280x800)
        await tester.tap(find.byKey(ValueKey('picker-account-row-$huabeiId')));
        await _settle(tester, 6);

        tester.view.physicalSize = const Size(1280, 800);
        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [databaseProvider.overrideWith((ref) async => db)],
            child: MaterialApp(
              theme: ThemeData(platform: TargetPlatform.linux),
              home: const RecordEditorPage(),
            ),
          ),
        );
        await _settle(tester, 12);

        await tester.tap(find.byKey(const Key('asset')));
        await _settle(tester, 8);
        expect(
          find.byKey(const Key('desktop-account-picker-dialog')),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(const Key('toggle-account-picker-reorder-btn')),
        );
        await _settle(tester, 6);
        expect(find.byKey(Key('account-picker-drag-$cashId')), findsOneWidget);

        // Move Alipay (index 2) to top (index 0) -> [Alipay, Cash, Huabei]
        final desktopReorder = tester.widget<ReorderableListView>(
          find.byKey(const Key('account-picker-reorder-list')),
        );
        desktopReorder.onReorderItem!(2, 0);
        await _settle(tester, 8);

        final dbOrderAfterDesktop = (await LedgerQueries(
          db,
        ).getAssets()).map((a) => a.id).toList();
        expect(dbOrderAfterDesktop, [alipayId, cashId, huabeiId]);
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox());
        await _settle(tester, 4);
      },
    );

    testWidgets(
      'AssetsPage management mode merges spendable accounts with 信用 badge at 360dp @ 1.2x; tab mode keeps 3 groups',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);

        final ledger = LedgerService(db);
        final cashId = await ledger.createAsset(
          commandId: 'am-cash',
          name: '工资卡',
          initial: Money.parse('1000.00'),
        );
        final creditId = await ledger.createAsset(
          commandId: 'am-credit',
          name: '招行信用卡',
          type: AssetType.credit,
          initial: Money.parse('-300.00'),
          limit: Money.parse('20000.00'),
        );

        tester.view.physicalSize = const Size(360, 640);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        // 1. Standalone management mode -> merged spendable list + credit badge
        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [databaseProvider.overrideWith((ref) async => db)],
            child: MediaQuery(
              data: const MediaQueryData(
                size: Size(360, 640),
                textScaler: TextScaler.linear(1.2),
              ),
              child: const MaterialApp(
                home: AssetsPage(standaloneManagement: true),
              ),
            ),
          ),
        );
        await _settle(tester, 10);

        expect(
          find.byKey(const Key('assets-reorder-spendable')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('assets-reorder-normal')), findsNothing);
        expect(find.byKey(const Key('assets-reorder-credit')), findsNothing);
        expect(find.byKey(Key('asset-credit-badge-$creditId')), findsOneWidget);
        expect(find.byKey(Key('asset-credit-badge-$cashId')), findsNothing);
        expect(tester.takeException(), isNull);

        // 2. Normal tab mode -> 3 grouped sections (normal + credit)
        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [databaseProvider.overrideWith((ref) async => db)],
            child: const MaterialApp(home: AssetsPage()),
          ),
        );
        await _settle(tester, 10);

        expect(find.byKey(const Key('assets-reorder-normal')), findsOneWidget);
        expect(find.byKey(const Key('assets-reorder-credit')), findsOneWidget);
        expect(find.byKey(const Key('assets-reorder-spendable')), findsNothing);
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox());
        await _settle(tester, 4);
      },
    );
  });

  group('L-01, L-06, L-09 Editor & Detail UI audit fixes', () {
    testWidgets(
      'L-01: Discount + FX booking deducts discount cleanly and re-editing causes 0 cent drift',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        await CurrencyService(db).saveCurrency(
          commandId: 'c-usd',
          code: 'USD',
          name: '美元',
          symbol: r'$',
          price: '7.20',
        );
        // Ensure discount & currency pills are enabled in DIY config
        final diy = DiyToolbarConfig.defaults()
            .setEnabled(DiyToolbarAction.discount, true)
            .setEnabled(DiyToolbarAction.currency, true);
        await db
            .into(db.preferences)
            .insertOnConflictUpdate(
              PreferencesCompanion.insert(
                key: prefKeyRecordDiyToolbar,
                value: diy.encode(),
              ),
            );

        final ledger = LedgerService(db);
        final usdCardId = await ledger.createAsset(
          commandId: 'u-card',
          name: '美元卡',
          initial: Money.parse('500.00'),
          currency: 'USD',
        );
        final cats = await LedgerQueries(db).getCategories(defaultBookId);
        final expCatId = cats
            .firstWhere((c) => c.type == RecordType.expense)
            .id;

        tester.view.physicalSize = const Size(420, 840);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [databaseProvider.overrideWith((ref) async => db)],
            child: MaterialApp(
              home: RecordEditorPage(
                initialAsset: usdCardId,
                initialCategory: expCatId,
              ),
            ),
          ),
        );
        await _settle(tester, 12);

        // Enter gross 100 on keypad
        await tester.tap(find.byKey(const Key('keypad-1')));
        await tester.tap(find.byKey(const Key('keypad-0')));
        await tester.tap(find.byKey(const Key('keypad-0')));
        await _settle(tester, 4);

        // Set discount = 20 USD
        await tester.tap(find.byKey(const Key('editor-discount-pill')));
        await _settle(tester, 6);
        await tester.enterText(find.byKey(const Key('discount')), '20');
        await tester.tap(find.byKey(const Key('discount-confirm-btn')));
        await _settle(tester, 6);

        // Save record
        await tester.tap(find.byKey(const Key('save')));
        await _settle(tester, 10);

        final saved = (await db.select(db.records).get()).single;
        expect(saved.moneyMinor, BigInt.from(8000)); // net $80.00
        expect(saved.discountMinor, BigInt.from(2000)); // $20.00 discount
        final snap1 = RecordExtra.parse(saved.extraInfo).currency!;
        expect(snap1.sourceGross, BigInt.from(10000));
        expect(snap1.assetNet, BigInt.from(8000));
        expect(snap1.baseAmount, BigInt.from(57600)); // $80 * 7.20 = ¥576.00

        // Reopen existing bill in editor & tap Save without edits -> 0 cent drift!
        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [databaseProvider.overrideWith((ref) async => db)],
            child: MaterialApp(
              home: RecordEditorPage(recordId: saved.recordId),
            ),
          ),
        );
        await _settle(tester, 12);

        final amountField = tester.widget<TextField>(
          find.byKey(const Key('amount')),
        );
        expect(amountField.controller!.text, '100.00'); // gross restored!

        await tester.tap(find.byKey(const Key('save')));
        await _settle(tester, 10);

        final resaved = (await db.select(db.records).get()).single;
        expect(resaved.moneyMinor, BigInt.from(8000));
        expect(resaved.discountMinor, BigInt.from(2000));
        expect(
          RecordExtra.parse(resaved.extraInfo).currency!.baseAmount,
          BigInt.from(57600),
        );

        await tester.pumpWidget(const SizedBox());
        await _settle(tester, 4);
      },
    );

    testWidgets(
      'L-06: RecordDetailPage allows two consecutive same-amount partial refunds without conflict',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);

        final ledger = LedgerService(db);
        final cashId = await ledger.createAsset(
          commandId: 'r-cash',
          name: '现金',
          initial: Money.parse('500.00'),
        );
        final catId = (await LedgerQueries(db).getCategories(
          defaultBookId,
        )).firstWhere((c) => c.type == RecordType.expense).id;
        final billId = await ledger.saveRecord(
          commandId: 'r-bill',
          draft: RecordDraft(
            type: RecordType.expense,
            money: Money.parse('100.00'),
            bookId: defaultBookId,
            recordTime: 1700000000000,
            categoryId: catId,
            assetId: cashId,
          ),
        );

        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [databaseProvider.overrideWith((ref) async => db)],
            child: MaterialApp(home: RecordDetailPage(recordId: billId)),
          ),
        );
        await _settle(tester, 10);

        for (var i = 0; i < 2; i++) {
          await tester.scrollUntilVisible(
            find.byKey(const Key('add-refund')),
            200,
          );
          await tester.tap(find.byKey(const Key('add-refund')));
          await _settle(tester, 6);
          await tester.enterText(find.byKey(const Key('link-amount')), '10');
          await tester.tap(find.byKey(const Key('link-save')));
          await _settle(tester, 8);
        }

        expect(find.byKey(const Key('refunded')), findsOneWidget);
        expect(
          tester.widget<Text>(find.byKey(const Key('refunded'))).data,
          '20.00',
        );

        await tester.pumpWidget(const SizedBox());
        await _settle(tester, 4);
      },
    );

    testWidgets(
      'L-09: 再记 (stayAndReset) clears tags, excludeBudget, excludeExIn, and sourceCurrency',
      (tester) async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        await CurrencyService(db).saveCurrency(
          commandId: 'c-usd-l9',
          code: 'USD',
          name: '美元',
          symbol: r'$',
          price: '7.20',
        );
        final tagId = await CatalogService(
          db,
        ).createTag(commandId: 't-l9', name: '差旅标签');

        final diy = DiyToolbarConfig.defaults()
            .setEnabled(DiyToolbarAction.tags, true)
            .setEnabled(DiyToolbarAction.excludeBudget, true)
            .setEnabled(DiyToolbarAction.excludeExIn, true)
            .setEnabled(DiyToolbarAction.currency, true);
        await db
            .into(db.preferences)
            .insertOnConflictUpdate(
              PreferencesCompanion.insert(
                key: prefKeyRecordDiyToolbar,
                value: diy.encode(),
              ),
            );

        final ledger = LedgerService(db);
        final cashId = await ledger.createAsset(
          commandId: 'l9-cash',
          name: '现金',
          initial: Money.parse('500.00'),
        );
        final catId = (await LedgerQueries(db).getCategories(
          defaultBookId,
        )).firstWhere((c) => c.type == RecordType.expense).id;

        tester.view.physicalSize = const Size(420, 840);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [databaseProvider.overrideWith((ref) async => db)],
            child: MaterialApp(
              home: RecordEditorPage(
                initialAsset: cashId,
                initialCategory: catId,
              ),
            ),
          ),
        );
        await _settle(tester, 12);

        // Enter amount 50, select tag, toggle excludeBudget & excludeExIn
        await tester.tap(find.byKey(const Key('keypad-5')));
        await tester.tap(find.byKey(const Key('keypad-0')));
        await tester.tap(find.byKey(const Key('editor-tags-pill')));
        await _settle(tester, 6);
        await tester.tap(find.text('差旅标签'));
        await _settle(tester, 4);
        await tester.tapAt(const Offset(10, 10)); // dismiss tag sheet
        await _settle(tester, 6);

        await tester.ensureVisible(
          find.byKey(const Key('editor-exclude-exin-pill')),
        );
        await tester.tap(find.byKey(const Key('editor-exclude-exin-pill')));
        await tester.ensureVisible(
          find.byKey(const Key('editor-exclude-budget-pill')),
        );
        await tester.tap(find.byKey(const Key('editor-exclude-budget-pill')));
        await _settle(tester, 4);

        // Tap 再记 (save-and-new)
        await tester.tap(find.byKey(const Key('save-and-new')));
        await _settle(tester, 10);

        // Enter second bill 25 and save
        await tester.tap(find.byKey(const Key('keypad-2')));
        await tester.tap(find.byKey(const Key('keypad-5')));
        await tester.tap(find.byKey(const Key('save')));
        await _settle(tester, 10);

        final records = await db.select(db.records).get();
        expect(records, hasLength(2));
        final first = records.firstWhere(
          (r) => r.moneyMinor == BigInt.from(5000),
        );
        final second = records.firstWhere(
          (r) => r.moneyMinor == BigInt.from(2500),
        );
        expect(first.excludeBudget, isTrue);
        expect(first.excludeExIn, isTrue);
        expect(second.excludeBudget, isFalse);
        expect(second.excludeExIn, isFalse);

        final secondTags = await (db.select(
          db.tagRecords,
        )..where((t) => t.recordId.equals(second.recordId))).get();
        expect(secondTags, isEmpty);
        final firstTags = await (db.select(
          db.tagRecords,
        )..where((t) => t.recordId.equals(first.recordId))).get();
        expect(firstTags.map((t) => t.tagId), [tagId]);

        await tester.pumpWidget(const SizedBox());
        await _settle(tester, 4);
      },
    );
  });
}
