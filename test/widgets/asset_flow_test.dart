import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/app/app.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/domain/model/codes.dart';

void main() {
  testWidgets(
    'account detail flow: bill list, month groups, and reconciliation mode',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
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

      // 1. Add an account "招行储蓄卡" with initial balance 1000.00
      await tester.tap(find.text('资产'));
      await settle();
      await tester.tap(find.byKey(const Key('add-asset')));
      await settle();
      await tester.enterText(find.byKey(const Key('asset-name')), '招行储蓄卡');
      await tester.enterText(find.byKey(const Key('asset-balance')), '1000');
      await tester.tap(find.byKey(const Key('asset-save')));
      await settle();
      expect(find.text('招行储蓄卡'), findsOneWidget);

      // 2. Tap account to open detail page (/assets/:id)
      await tester.tap(find.text('招行储蓄卡'));
      await settle();

      // Initially no records: empty state shows
      expect(find.text('明细 · 0 笔'), findsOneWidget);
      expect(find.text('对账模式'), findsOneWidget);
      expect(find.text('暂无账单明细'), findsOneWidget);

      // 3. Record an expense from this account via "记一笔"
      await tester.tap(find.text('记一笔'));
      await settle();
      await tester.enterText(find.byKey(const Key('amount')), '50');
      await tester.tap(find.byKey(const Key('cat-餐饮')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('save')));
      await settle();

      // Now on account detail page, should show 1 record
      expect(find.text('明细 · 1 笔'), findsOneWidget);
      expect(find.text('餐饮'), findsOneWidget);
      expect(find.text('-50.00'), findsOneWidget);
      expect(find.textContaining('流出 50.00'), findsOneWidget);

      // 4. Toggle reconciliation mode on
      final reconSwitch = find.byKey(const Key('reconciliation-switch'));
      expect(reconSwitch, findsOneWidget);
      await tester.tap(reconSwitch);
      await settle();

      // In reconciliation mode, row shows after-balance: 1000 - 50 = 950.00
      expect(find.text('余额：950.00'), findsOneWidget);

      // 5. Add another transaction (Income 200.00) using LedgerService directly
      final service = LedgerService(db);
      final assetRow = await (db.select(
        db.assets,
      )..where((t) => t.name.equals('招行储蓄卡'))).getSingle();
      final bookId = await (db.select(
        db.accountBooks,
      )..limit(1)).getSingle().then((b) => b.id);
      final incomeCat =
          await (db.select(db.recordCategories)
                ..where((t) => t.type.equals(RecordType.income)))
              .get()
              .then((l) => l.first);

      await service.saveRecord(
        commandId: 'cmd-inc-1',
        draft: RecordDraft(
          type: RecordType.income,
          money: Money.minor(BigInt.from(20000)),
          assetId: assetRow.id,
          recordTime: DateTime.now().millisecondsSinceEpoch,
          categoryId: incomeCat.id,
          bookId: bookId,
        ),
      );
      await settle();

      // Should now have 2 records
      expect(find.text('明细 · 2 笔'), findsOneWidget);
      expect(find.text('+200.00'), findsOneWidget);
      // After newest income (+200), current balance is 1150.00
      // Income row shows "余额：1150.00", older expense row shows "余额：950.00"
      expect(find.text('余额：1150.00'), findsOneWidget);
      expect(find.text('余额：950.00'), findsOneWidget);

      // 6. Tap a record row to navigate to record detail page
      await tester.tap(find.text('餐饮'));
      await settle();
      expect(find.text('账单详情'), findsOneWidget);
      expect(find.byKey(const Key('detail-amount')), findsOneWidget);

      // Go back to account detail
      await tester.tap(find.byType(BackButton));
      await settle();

      // 7. Verify R7 dynamic update: adjust account balance and observe running balances update
      await service.adjustBalance(
        commandId: 'cmd-adj-1',
        assetId: assetRow.id,
        target: Money.minor(BigInt.from(120000)),
        bookId: bookId,
      );
      await settle();

      // Balance adjusted to 1200.00 (+50 diff record written)
      expect(find.text('明细 · 3 笔'), findsOneWidget);
      expect(find.text('余额：1200.00'), findsOneWidget);

      // Toggle reconciliation mode off
      await tester.tap(find.byKey(const Key('reconciliation-switch')));
      await settle();
      expect(find.text('余额：1200.00'), findsNothing);

      // Cleanup tree so drift stream queries cancel
      await tester.pumpWidget(const SizedBox());
      await settle();
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'credit card reconciliation mode shows creditBalanceLabel (R4, ASYM-REC-07)',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
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

      // 1. Add credit card with 0 balance (or default)
      await tester.tap(find.text('资产'));
      await settle();
      await tester.tap(find.byKey(const Key('add-asset')));
      await settle();
      await tester.tap(find.text('信用账户'));
      await settle();
      await tester.enterText(find.byKey(const Key('asset-name')), '招行信用卡');
      await tester.enterText(find.byKey(const Key('credit-limit')), '10000');
      await tester.tap(find.byKey(const Key('asset-save')));
      await settle();

      final creditAsset = await (db.select(
        db.assets,
      )..where((t) => t.name.equals('招行信用卡'))).getSingle();
      final bookId = await (db.select(
        db.accountBooks,
      )..limit(1)).getSingle().then((b) => b.id);
      final expenseCat =
          await (db.select(db.recordCategories)
                ..where((t) => t.type.equals(RecordType.expense)))
              .get()
              .then((l) => l.first);

      // Add expense 320.00 to credit card -> balance becomes -320.00
      final service = LedgerService(db);
      await service.saveRecord(
        commandId: 'cmd-card-exp',
        draft: RecordDraft(
          type: RecordType.expense,
          money: Money.minor(BigInt.from(32000)),
          assetId: creditAsset.id,
          recordTime: DateTime.now().millisecondsSinceEpoch,
          categoryId: expenseCat.id,
          bookId: bookId,
        ),
      );
      await settle();

      // Open credit card detail
      await tester.tap(find.text('招行信用卡'));
      await settle();

      // Turn on reconciliation mode (below the credit statements section).
      await tester.scrollUntilVisible(
        find.byKey(const Key('reconciliation-switch')),
        300,
        scrollable: find.byType(Scrollable).last,
      );
      await settle();
      await tester.tap(find.byKey(const Key('reconciliation-switch')));
      await settle();

      // Must display "欠款 320.00", never double minus "欠款 -320.00"
      expect(find.text('欠款 320.00'), findsWidgets);
      expect(find.textContaining('欠款 -'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await settle();
      await tester.pump(const Duration(seconds: 1));
    },
  );
}
