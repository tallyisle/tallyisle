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

void main() {
  testWidgets('credit card detail page displays limits, banner, and statements', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWith((ref) async => db)],
    );

    // Create a credit card with limit 20000, initial debt 1500, bill day 10, repayment day 28
    final ledger = await container.read(ledgerServiceProvider.future);
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

    // Record an expense of 400.00 on the credit card
    await ledger.saveRecord(
      commandId: 'cmd-expense-1',
      draft: RecordDraft(
        bookId: 1,
        type: RecordType.expense,
        money: Money.parse('400.00'),
        assetId: cardId,
        recordTime: now.millisecondsSinceEpoch,
        categoryId: 1,
        remark: '测试消费',
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

    // Navigate to Assets page
    await tester.tap(find.text('资产'));
    await settle();

    // Verify card is in list and tap it
    expect(find.text('招行经典白'), findsOneWidget);
    await tester.tap(find.text('招行经典白'));
    await settle();

    // Verify header and credit section
    expect(find.text('信用卡'), findsOneWidget);
    expect(find.byKey(const Key('credit-usable-limit')), findsOneWidget);

    // Year switcher should be present
    expect(find.text('${now.year} 年'), findsOneWidget);

    // Statement cards should show
    expect(find.textContaining('期账单'), findsWidgets);

    // Clean up
    await tester.pumpWidget(const SizedBox());
    await settle();
    await tester.pump(const Duration(seconds: 1));
  });
}
