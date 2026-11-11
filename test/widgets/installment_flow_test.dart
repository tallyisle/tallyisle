import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/installment/installment_service.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/domain/ledger/asset_json.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/asset_overview.dart';
import 'package:tallyisle/domain/rules/installment_rules.dart';
import 'package:tallyisle/features/installment/installment_detail_page.dart';
import 'package:tallyisle/features/installment/installment_editor_page.dart';
import 'package:tallyisle/features/installment/installment_page.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Widget buildApp(Widget child, AppDatabase db) => ProviderScope(
    retry: (_, _) => null,
    overrides: [databaseProvider.overrideWith((ref) async => db)],
    child: MaterialApp(home: child),
  );

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> unmountApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    await tester.pump(const Duration(seconds: 1));
  }

  Future<AppDatabase> openTestDb(WidgetTester tester) async {
    late final AppDatabase db;
    await tester.runAsync(() async {
      db = AppDatabase(NativeDatabase.memory());
    });
    addTearDown(() async {
      await tester.runAsync(db.close);
    });
    return db;
  }

  testWidgets(
    'InstallmentPage full flow: create on credit card, post period 1, record link, edit metadata, early settle with fee waiver, finished tab & rollback delete',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final db = await openTestDb(tester);
      late final int cardId;
      await tester.runAsync(() async {
        final creditInfo =
            (CreditInfo()
                  ..billDay = 10
                  ..repaymentDay = 28)
                .encode();
        cardId = await db
            .into(db.assets)
            .insert(
              AssetsCompanion.insert(
                name: '招商信用卡',
                type: AssetType.credit,
                balanceMinor: BigInt.zero,
                initMoneyMinor: BigInt.from(3000000),
                creditInfo: Value(creditInfo),
                createDate: db.nowMs(),
              ),
            );
      });

      String? tappedRecordId;
      await tester.pumpWidget(
        buildApp(
          InstallmentPage(
            autoCatchUpOnOpen: false,
            onRecordTap: (recordId) => tappedRecordId = recordId,
          ),
          db,
        ),
      );
      await settle(tester);

      expect(find.byKey(const Key('installment_page')), findsOneWidget);
      expect(find.byKey(const Key('installment_empty_active')), findsOneWidget);

      // 1. Open Create Installment page
      await tester.tap(find.byKey(const Key('add_installment_fab')));
      await settle(tester);
      expect(find.byKey(const Key('installment_editor_page')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('installment_name_input')),
        'MacBook分期',
      );
      await tester.enterText(
        find.byKey(const Key('installment_principal_input')),
        '1200.00',
      );
      await tester.enterText(
        find.byKey(const Key('installment_periods_input')),
        '3',
      );
      await tester.enterText(
        find.byKey(const Key('installment_charge_input')),
        '60.00',
      );
      await tester.pump();

      // Enable uncredited fee counting on credit card (`ci = true`)
      await tester.ensureVisible(
        find.byKey(const Key('installment_ci_switch')),
      );
      await tester.tap(find.byKey(const Key('installment_ci_switch')));
      await tester.pump();

      // Schedule preview card shows exact 420.00 per period & 1260.00 total
      expect(find.byKey(const Key('installment_preview_card')), findsOneWidget);
      expect(find.textContaining('合计应还 ¥1260.00'), findsOneWidget);

      await tester.tap(find.byKey(const Key('save_installment_button')));
      await settle(tester);

      // 2. Verify active list & credit card uncredited liability (1260.00)
      expect(
        find.byKey(const Key('installment_active_summary_card')),
        findsOneWidget,
      );
      expect(find.text('¥1260.00'), findsOneWidget);
      expect(find.text('MacBook分期'), findsOneWidget);
      expect(find.text('0/3期'), findsOneWidget);

      final cardAfterCreate = await tester.runAsync(
        () => (db.select(
          db.assets,
        )..where((t) => t.id.equals(cardId))).getSingle(),
      );
      expect(
        uncreditedInstallment(cardAfterCreate!.creditInfo),
        BigInt.from(126000),
      );

      // 3. Open Detail Page & manually post period 1 ("本期入账")
      await tester.tap(find.byKey(const Key('installment_card_1')));
      await settle(tester);
      expect(find.byKey(const Key('installment_detail_page')), findsOneWidget);

      await tester.tap(find.byKey(const Key('post_next_period_button')));
      await settle(tester);
      expect(
        find.byKey(const Key('confirm_post_period_button')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('confirm_post_period_button')));
      await settle(tester);

      // Remaining drops to 840.00 in detail summary card
      expect(
        find.descendant(
          of: find.byKey(const Key('installment_detail_summary_card')),
          matching: find.text('¥840.00'),
        ),
        findsOneWidget,
      );
      final postedBills = await tester.runAsync(
        () => db.select(db.records).get(),
      );
      expect(postedBills!, hasLength(2));

      // Tap posted principal record link -> invokes record navigation callback
      final principalBill = postedBills.firstWhere(
        (r) => r.type != RecordType.fee,
      );
      final recordTile = find.byKey(
        Key('posted_record_${principalBill.recordId}'),
      );
      await tester.ensureVisible(recordTile);
      await tester.tap(recordTile);
      await tester.pump();
      expect(tappedRecordId, principalBill.recordId);

      // 4. Edit metadata name
      await tester.tap(find.byKey(const Key('edit_installment_button')));
      await settle(tester);
      await tester.enterText(
        find.byKey(const Key('installment_name_input')),
        'MacBook Pro分期',
      );
      await tester.tap(find.byKey(const Key('save_installment_button')));
      await settle(tester);
      expect(
        find.descendant(
          of: find.byKey(const Key('installment_detail_page')),
          matching: find.text('MacBook Pro分期'),
        ),
        findsOneWidget,
      );

      // 5. Early full settlement with fee waiver
      await tester.tap(find.byKey(const Key('early_settle_button')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('waive_fee_switch')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('confirm_early_settle_button')));
      await settle(tester);

      expect(find.byKey(const Key('early_settled_banner')), findsOneWidget);
      expect(find.textContaining('已免除手续费 ¥40.00'), findsOneWidget);

      final cardAfterSettle = await tester.runAsync(
        () => (db.select(
          db.assets,
        )..where((t) => t.id.equals(cardId))).getSingle(),
      );
      expect(uncreditedInstallment(cardAfterSettle!.creditInfo), BigInt.zero);
      expect(cardAfterSettle.balanceMinor, BigInt.from(-122000));

      // 6. Back to InstallmentPage -> Active tab empty, Finished tab has item!
      await tester.tap(find.byType(BackButton));
      await settle(tester);
      expect(find.byKey(const Key('installment_empty_active')), findsOneWidget);

      await tester.tap(find.byKey(const Key('installment_tab_finished')));
      await settle(tester);
      expect(find.text('MacBook Pro分期'), findsOneWidget);
      expect(find.text('已提前结清'), findsOneWidget);

      // 7. Re-open detail and delete with rollback -> card balance restored to 0!
      await tester.tap(find.byKey(const Key('installment_card_1')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('delete_installment_button')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('delete_records_checkbox')));
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('confirm_delete_installment_button')),
      );
      await settle(tester);

      expect(
        find.byKey(const Key('installment_empty_finished')),
        findsOneWidget,
      );
      final cardAfterDelete = await tester.runAsync(
        () => (db.select(
          db.assets,
        )..where((t) => t.id.equals(cardId))).getSingle(),
      );
      expect(cardAfterDelete!.balanceMinor, BigInt.zero);
      expect(await tester.runAsync(() => db.select(db.records).get()), isEmpty);
      await unmountApp(tester);
    },
  );

  testWidgets(
    'InstallmentPage autoCatchUpOnOpen & cross-book category label resolution in all-books scope',
    (tester) async {
      final db = await openTestDb(tester);

      await tester.runAsync(() async {
        final cashId = await db
            .into(db.assets)
            .insert(
              AssetsCompanion.insert(
                name: '储蓄卡',
                type: AssetType.normal,
                balanceMinor: BigInt.from(100000),
                initMoneyMinor: BigInt.from(100000),
                createDate: db.nowMs(),
              ),
            );

        // Create second book (id=2) with its own expense category
        await db
            .into(db.accountBooks)
            .insert(
              AccountBooksCompanion.insert(
                id: const Value(2),
                name: '家庭装修账本',
                createDate: db.nowMs(),
              ),
            );
        final book2CatId = await db
            .into(db.recordCategories)
            .insert(
              RecordCategoriesCompanion.insert(
                name: '大家电分期',
                type: RecordType.expense,
                accountBookId: 2,
              ),
            );

        final now = DateTime.now();
        final todayStartMs = DateTime(
          now.year,
          now.month,
          now.day,
        ).millisecondsSinceEpoch;

        final service = InstallmentService(db);
        await service.createInstallment(
          commandId: 'auto-cu-1',
          draft: InstallmentDraft(
            name: '今日到期分期',
            catId: 1,
            principal: Money.parse('300.00'),
            periods: 3,
            charge: Money.zero(),
            calWay: InstallmentCalWay.halfUp2,
            startDateMs: todayStartMs,
            assetId: cashId,
            bookId: 1,
          ),
        );
        await service.createInstallment(
          commandId: 'book2-inst',
          draft: InstallmentDraft(
            name: '洗碗机分期',
            catId: book2CatId,
            principal: Money.parse('600.00'),
            periods: 6,
            charge: Money.zero(),
            calWay: InstallmentCalWay.halfUp2,
            startDateMs: DateTime(now.year + 1, 1, 10).millisecondsSinceEpoch,
            assetId: cashId,
            bookId: 2,
          ),
        );
      });

      await tester.pumpWidget(
        buildApp(const InstallmentPage(autoCatchUpOnOpen: true), db),
      );
      await settle(tester);

      // Current book (1): due period 1 caught up automatically; book 2 hidden
      expect(find.text('今日到期分期'), findsOneWidget);
      expect(find.text('1/3期'), findsOneWidget);
      expect(find.text('待还 ¥200.00'), findsOneWidget);
      expect(find.text('洗碗机分期'), findsNothing);

      // Toggle to all-books scope -> book 2 installment appears with '大家电分期' (not '未分类')!
      await tester.tap(find.byKey(const Key('installment_book_scope_button')));
      await settle(tester);
      expect(find.text('洗碗机分期'), findsOneWidget);
      expect(find.textContaining('大家电分期 · 储蓄卡'), findsOneWidget);
      expect(find.textContaining('未分类'), findsNothing);
      await unmountApp(tester);
    },
  );

  testWidgets(
    'Direct cold-stream InstallmentEditorPage handles hidden category & hidden tag without crash',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final db = await openTestDb(tester);
      late final int instId;
      await tester.runAsync(() async {
        final cashId = await db
            .into(db.assets)
            .insert(
              AssetsCompanion.insert(
                name: '工资卡',
                type: AssetType.normal,
                balanceMinor: BigInt.from(100000),
                initMoneyMinor: BigInt.from(100000),
                createDate: db.nowMs(),
              ),
            );
        await db
            .into(db.tags)
            .insert(
              TagsCompanion.insert(
                tagId: 'hidden-tag',
                name: '历史标签',
                hidden: const Value(true),
              ),
            );

        instId = await InstallmentService(db).createInstallment(
          commandId: 'cold-create',
          draft: InstallmentDraft(
            name: '冷启动编辑测试',
            catId: 2, // 购物
            principal: Money.parse('200.00'),
            periods: 2,
            charge: Money.zero(),
            startDateMs: DateTime(2027, 1, 15).millisecondsSinceEpoch,
            assetId: cashId,
            bookId: 1,
            tagIds: const ['hidden-tag'],
          ),
        );

        await (db.update(db.recordCategories)..where((t) => t.id.equals(2)))
            .write(const RecordCategoriesCompanion(isHide: Value(true)));
      });

      await tester.pumpWidget(
        buildApp(InstallmentEditorPage(installmentId: instId), db),
      );
      await settle(tester);

      expect(find.byKey(const Key('installment_editor_page')), findsOneWidget);
      expect(find.text('购物'), findsOneWidget);
      expect(
        find.byKey(const Key('installment_tag_hidden-tag')),
        findsOneWidget,
      );
      await unmountApp(tester);
    },
  );

  testWidgets(
    'Direct cold-stream InstallmentDetailPage safely reposts externally deleted period record',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final db = await openTestDb(tester);
      late final int instId;
      await tester.runAsync(() async {
        final cashId = await db
            .into(db.assets)
            .insert(
              AssetsCompanion.insert(
                name: '工资卡',
                type: AssetType.normal,
                balanceMinor: BigInt.from(100000),
                initMoneyMinor: BigInt.from(100000),
                createDate: db.nowMs(),
              ),
            );
        final service = InstallmentService(db);
        instId = await service.createInstallment(
          commandId: 'repost-create',
          draft: InstallmentDraft(
            name: '外部删单补记测试',
            catId: 1,
            principal: Money.parse('200.00'),
            periods: 2,
            charge: Money.zero(),
            startDateMs: DateTime(2027, 1, 15).millisecondsSinceEpoch,
            assetId: cashId,
            bookId: 1,
          ),
        );
        final p1Bills = await service.postPeriod(
          commandId: 'repost-p1',
          installmentId: instId,
        );
        await LedgerService(
          db,
        ).deleteRecord(commandId: 'repost-ext-del', recordId: p1Bills.single);
      });

      await tester.pumpWidget(
        buildApp(InstallmentDetailPage(installmentId: instId), db),
      );
      await settle(tester);

      expect(find.text('关联账单已被手动删除'), findsOneWidget);
      await tester.tap(find.byKey(const Key('repost_period_1')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('confirm_post_period_button')));
      await settle(tester);

      expect(find.text('关联账单已被手动删除'), findsNothing);
      expect(
        await tester.runAsync(() => db.select(db.records).get()),
        hasLength(1),
      );
      await unmountApp(tester);
    },
  );
}
