import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/catalog/catalog_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/debt/debt_service.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/features/debt/debt_page.dart';

void main() {
  Widget buildApp(Widget child, AppDatabase db) => ProviderScope(
    retry: (_, _) => null,
    overrides: [databaseProvider.overrideWith((ref) async => db)],
    child: MaterialApp(home: child),
  );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets(
    'DebtPage -> DebtEditorPage -> DebtDetailPage full flow: create, 33.3% progress, pure interest, manual settle lock, reopen & delete',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final ledger = LedgerService(db);
      final cashId = await ledger.createAsset(
        commandId: 'seed-cash',
        name: '招行现金',
        initial: Money.parse('1000.00'),
      );

      await tester.pumpWidget(buildApp(const DebtPage(), db));
      await settle(tester);

      expect(find.byKey(const Key('debt_page')), findsOneWidget);
      expect(find.text('暂无进行中的借贷项目，点击右下角新建'), findsOneWidget);

      // 1. Open DebtEditorPage and create a 300.00 lending project ("张三")
      await tester.tap(find.byKey(const Key('add_debt_button')));
      await settle(tester);

      expect(find.byKey(const Key('debt_editor_page')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('debt_name_input')), '张三');
      await tester.enterText(
        find.byKey(const Key('debt_principal_input')),
        '300.00',
      );
      await tester.tap(find.byKey(const Key('debt_funding_selector')));
      await settle(tester);
      await tester.tap(find.text('招行现金').last);
      await settle(tester);

      await tester.tap(find.byKey(const Key('save_debt_button')));
      await settle(tester);

      // Back on DebtPage: receivable = 300.00, cash = 700.00
      expect(find.byKey(const Key('debt_page')), findsOneWidget);
      expect(find.text('张三'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('debt_total_receivable')))
            .data,
        '300.00',
      );

      // 2. Tap into DebtDetailPage
      await tester.tap(find.text('张三'));
      await settle(tester);

      expect(find.byKey(const Key('debt_detail_page')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('debt_progress_label'))).data,
        '0.0%',
      );

      // 3. Record collection of 100.00 + 15.00 interest -> 33.3% progress (CE-DM-07)
      await tester.tap(find.byKey(const Key('debt_action_repay')));
      await settle(tester);

      await tester.enterText(
        find.byKey(const Key('repay_principal_input')),
        '100.00',
      );
      await tester.enterText(
        find.byKey(const Key('repay_interest_input')),
        '15.00',
      );
      await tester.tap(find.byKey(const Key('repay_funding_selector')));
      await settle(tester);
      await tester.tap(find.text('招行现金').last);
      await settle(tester);

      await tester.tap(find.byKey(const Key('confirm_repay_button')));
      await settle(tester);

      expect(
        tester.widget<Text>(find.byKey(const Key('debt_progress_label'))).data,
        '33.3%',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('debt_remaining_principal')))
            .data,
        '200.00',
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('debt_total_interest'))).data,
        '15.00',
      );

      // 4. Record pure interest of 20.00 -> interest rises to 35.00, principal stays 200.00
      await tester.tap(find.byKey(const Key('debt_action_interest_only')));
      await settle(tester);

      await tester.enterText(
        find.byKey(const Key('pure_interest_input')),
        '20.00',
      );
      await tester.tap(find.byKey(const Key('repay_funding_selector')));
      await settle(tester);
      await tester.tap(find.text('招行现金').last);
      await settle(tester);

      await tester.tap(find.byKey(const Key('confirm_repay_button')));
      await settle(tester);

      expect(
        tester
            .widget<Text>(find.byKey(const Key('debt_remaining_principal')))
            .data,
        '200.00',
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('debt_total_interest'))).data,
        '35.00',
      );

      // 5. Manual settle & recalibration lock (ASYM-DM-01)
      await tester.tap(find.byKey(const Key('debt_detail_menu')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('debt_menu_settle')));
      await settle(tester);
      await tester.tap(find.text('确认结清'));
      await settle(tester);

      expect(find.text('已结清'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('debt_progress_label'))).data,
        '100.0%',
      );

      // Trigger recalibrate -> stays settled!
      await tester.tap(find.byKey(const Key('debt_detail_menu')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('debt_menu_recalibrate')));
      await settle(tester);

      expect(find.text('已结清'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('debt_remaining_principal')))
            .data,
        '0.00',
      );

      // 6. Reopen and delete whole debt project -> cash returns to 1000.00!
      await tester.tap(find.byKey(const Key('debt_detail_menu')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('debt_menu_reopen')));
      await settle(tester);
      await tester.tap(find.text('重新开启').last);
      await settle(tester);

      expect(find.text('进行中'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('debt_remaining_principal')))
            .data,
        '200.00',
      );

      await tester.tap(find.byKey(const Key('debt_detail_menu')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('debt_menu_delete')));
      await settle(tester);
      await tester.tap(find.text('删除').last);
      await settle(tester);

      expect(find.byKey(const Key('debt_page')), findsOneWidget);
      expect(find.text('张三'), findsNothing);

      final cashAfter = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(cashId))).getSingle();
      expect(cashAfter.balanceMinor, BigInt.from(100000));

      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await db.close();
    },
  );

  testWidgets('DebtPage book scope toggle and active/settled tabs', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    final catalog = CatalogService(db);
    final debtService = DebtService(db);
    final book2 = await catalog.createBook(
      commandId: 'mk-book-2',
      name: '副业账本',
    );

    await debtService.createDebt(
      commandId: 'd-b1',
      subType: AssetType.debtBorrow,
      name: '日常借入A',
      principal: Money.parse('500.00'),
      bookId: 1,
      startDate: 1700000000000,
    );
    final d2 = await debtService.createDebt(
      commandId: 'd-b2',
      subType: AssetType.debtLend,
      name: '副业借出B',
      principal: Money.parse('800.00'),
      bookId: book2,
      startDate: 1700000000000,
    );
    await debtService.settleDebt(commandId: 'settle-d2', debtId: d2);

    await tester.pumpWidget(buildApp(const DebtPage(), db));
    await settle(tester);

    // Default scope = current book (book 1) -> shows 日常借入A, hides 副业借出B
    expect(find.text('日常借入A'), findsOneWidget);
    expect(find.text('副业借出B'), findsNothing);

    // Toggle to all-books scope -> active tab still shows 日常借入A, settled tab shows 副业借出B
    await tester.tap(find.byKey(const Key('debt_scope_toggle')));
    await settle(tester);
    expect(find.text('全部账本'), findsOneWidget);

    await tester.tap(find.byKey(const Key('debt_tab_settled')));
    await settle(tester);
    expect(find.text('副业借出B'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    await tester.pump(const Duration(seconds: 1));
    await db.close();
  });

  testWidgets(
    'Direct entry DebtPage -> DebtDetailPage populates funding/book dropdowns and edits record with hidden funding account',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final ledger = LedgerService(db);
      final catalog = CatalogService(db);
      final debtService = DebtService(db);

      final bankId = await ledger.createAsset(
        commandId: 'seed-icbc',
        name: '工商银行卡',
        initial: Money.parse('1000.00'),
      );
      await catalog.createBook(commandId: 'seed-book2', name: '家庭账本');

      await debtService.createDebt(
        commandId: 'seed-lisi',
        subType: AssetType.debtLend,
        name: '李四',
        principal: Money.parse('400.00'),
        bookId: 1,
        startDate: 1700000000000,
      );

      // Direct entry without ever visiting DebtEditorPage
      await tester.pumpWidget(buildApp(const DebtPage(), db));
      await settle(tester);

      await tester.tap(find.text('李四'));
      await settle(tester);
      expect(find.byKey(const Key('debt_detail_page')), findsOneWidget);

      // Open repay/collect dialog directly and select pre-seeded funding account & book
      await tester.tap(find.byKey(const Key('debt_action_repay')));
      await settle(tester);

      await tester.enterText(
        find.byKey(const Key('repay_principal_input')),
        '150.00',
      );
      await tester.tap(find.byKey(const Key('repay_funding_selector')));
      await settle(tester);
      await tester.tap(find.text('工商银行卡').last);
      await settle(tester);

      await tester.tap(find.byKey(const Key('repay_book_selector')));
      await settle(tester);
      await tester.tap(find.text('家庭账本').last);
      await settle(tester);

      await tester.tap(find.byKey(const Key('confirm_repay_button')));
      await settle(tester);

      expect(
        tester
            .widget<Text>(find.byKey(const Key('debt_remaining_principal')))
            .data,
        '250.00',
      );

      // Hide the funding account (status = AssetStatus.hidden)
      await ledger.setAssetStatus(
        commandId: 'hide-icbc',
        assetId: bankId,
        status: AssetStatus.hidden,
      );
      await settle(tester);

      // Tap the collection record linked to the now-hidden funding account
      await tester.tap(find.widgetWithText(ListTile, '收款'));
      await settle(tester);

      expect(find.text('编辑收款'), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('edit_debt_record_funding_selector')),
      );
      await settle(tester);
      await tester.tap(find.text('工商银行卡').last);
      await settle(tester);

      await tester.enterText(
        find.byKey(const Key('edit_debt_record_amount_input')),
        '200.00',
      );
      await tester.tap(
        find.byKey(const Key('confirm_edit_debt_record_button')),
      );
      await settle(tester);

      expect(
        tester
            .widget<Text>(find.byKey(const Key('debt_remaining_principal')))
            .data,
        '200.00',
      );
      final bankAfter = await (db.select(
        db.assets,
      )..where((t) => t.id.equals(bankId))).getSingle();
      expect(bankAfter.balanceMinor, BigInt.from(120000));

      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await db.close();
    },
  );
}
