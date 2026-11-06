import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/app/app.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/data/db/database.dart';

void main() {
  testWidgets('add account, record an expense, see home totals', (
    tester,
  ) async {
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
    expect(find.text('日常账本'), findsOneWidget);
    expect(find.text('本期暂无账单'), findsOneWidget);

    // Add an account.
    await tester.tap(find.text('资产'));
    await settle();
    await tester.tap(find.byKey(const Key('add-asset')));
    await settle();
    await tester.enterText(find.byKey(const Key('asset-name')), '现金');
    await tester.enterText(find.byKey(const Key('asset-balance')), '1000');
    await tester.tap(find.byKey(const Key('asset-save')));
    await settle();
    expect(find.byKey(const Key('asset-现金')), findsOneWidget);
    expect(find.text('1000.00'), findsWidgets);

    // Record an expense from the home page.
    await tester.tap(find.text('明细'));
    await settle();
    await tester.tap(find.byKey(const Key('add-record')));
    await settle();
    await tester.enterText(find.byKey(const Key('amount')), '85.5');
    await tester.tap(find.byKey(const Key('cat-餐饮')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('asset')));
    await settle();
    await tester.tap(find.text('现金').last);
    await settle();
    await tester.tap(find.byKey(const Key('save')));
    await settle();

    expect(find.byKey(const Key('sum-expense')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('sum-expense'))).data,
      '85.50',
    );
    expect(find.text('-85.50'), findsNWidgets(2)); // balance + list row

    await tester.tap(find.text('资产'));
    await settle();
    expect(find.text('914.50'), findsWidgets);

    // Dispose the tree so drift stream queries are cancelled. The in-memory
    // database is not closed here: closing it inside the fake-async test zone
    // never completes; it is released with the test isolate.
    await tester.pumpWidget(const SizedBox());
    await settle();
    await tester.pump(const Duration(seconds: 1)); // drift stream-close timers
  });
}
