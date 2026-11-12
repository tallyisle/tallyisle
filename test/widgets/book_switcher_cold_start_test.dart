import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/app/app.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/catalog/catalog_queries.dart';
import 'package:tallyisle/data/catalog/catalog_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/data/repo/ledger_queries.dart';
import 'package:tallyisle/domain/model/codes.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets(
    'cold-start book picker opens on first tap, guards rapid taps, and switches books without stacked sheets',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: const TallyIsleApp(),
        ),
      );

      Future<void> settle([int steps = 10]) async {
        for (var i = 0; i < steps; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 50));
        }
      }

      await settle();

      final pickerFinder = find.byKey(const Key('book-picker'));
      expect(pickerFinder, findsOneWidget);
      expect(
        find.descendant(of: pickerFinder, matching: find.text('日常账本')),
        findsOneWidget,
      );
      expect(find.byType(BottomSheet), findsNothing);

      // 1. Cold-start onto HomePage (without pre-watching booksProvider anywhere):
      // tap '日常账本' (Key('book-picker')) ONCE -> bottom sheet opens immediately!
      await tester.tap(pickerFinder);
      await settle();

      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.widgetWithText(ListTile, '日常账本'), findsOneWidget);
      expect(find.byKey(const Key('book-picker-manage')), findsOneWidget);

      // Dismiss the bottom sheet cleanly.
      await tester.tapAt(const Offset(20, 20));
      await settle();
      expect(find.byType(BottomSheet), findsNothing);

      // 2. Rapid-tap Key('book-picker') 5 times before settling ->
      // at most ONE modal bottom sheet opens and dismissing it once returns cleanly.
      for (var i = 0; i < 5; i++) {
        await tester.tap(pickerFinder, warnIfMissed: false);
      }
      await settle();

      expect(find.byType(BottomSheet), findsOneWidget);
      await tester.tapAt(const Offset(20, 20));
      await settle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(pickerFinder, findsOneWidget);

      // 3. Open book picker, tap '账本管理' -> navigate to '/books', create '旅行账本',
      // return to HomePage -> zero unexpected modal sheets -> switch to '旅行账本'.
      await tester.tap(pickerFinder);
      await settle();
      expect(find.byType(BottomSheet), findsOneWidget);
      await tester.tap(find.byKey(const Key('book-picker-manage')));
      await settle();

      expect(find.byType(BottomSheet), findsNothing);
      await tester.tap(find.byKey(const Key('add-book')));
      await settle();
      await tester.enterText(find.byKey(const Key('book-name')), '旅行账本');
      await tester.tap(find.byKey(const Key('book-save')));
      await settle();
      expect(find.text('旅行账本'), findsOneWidget);

      await tester.tap(find.byType(BackButton));
      await settle();

      // Zero stacked or unexpected modal sheets upon returning to HomePage.
      expect(find.byType(BottomSheet), findsNothing);
      expect(
        find.descendant(of: pickerFinder, matching: find.text('日常账本')),
        findsOneWidget,
      );

      // Tap Key('book-picker') and switch cleanly to '旅行账本'.
      await tester.tap(pickerFinder);
      await settle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.widgetWithText(ListTile, '日常账本'), findsOneWidget);
      expect(find.widgetWithText(ListTile, '旅行账本'), findsOneWidget);

      await tester.tap(find.widgetWithText(ListTile, '旅行账本'));
      await settle();

      expect(find.byType(BottomSheet), findsNothing);
      expect(
        find.descendant(of: pickerFinder, matching: find.text('旅行账本')),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox());
      await settle();
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'HomePage bill row displays compact #标签名 badges alongside remark and one-shot queries work standalone',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());

      // Seed via real services & verify one-shot Future query methods directly.
      late String recordId;
      await tester.runAsync(() async {
        final ledgerQ = LedgerQueries(db);
        final catalogQ = CatalogQueries(db);
        final catalogSvc = CatalogService(db);
        final ledgerSvc = LedgerService(db);

        final bookId = await ledgerQ.getCurrentBookId();
        expect(bookId, 1);
        final books = await ledgerQ.getBooks();
        expect(books.map((b) => b.name), contains('日常账本'));
        final book = await ledgerQ.getBook(bookId);
        expect(book?.name, '日常账本');

        final currencies = await ledgerQ.getCurrencies();
        expect(currencies.map((c) => c.code), contains('CNY'));

        final categories = await ledgerQ.getCategories(bookId);
        final activeCats = await catalogQ.getActiveCategories(bookId);
        expect(categories, isNotEmpty);
        expect(activeCats.length, categories.length);

        final tagId = await catalogSvc.createTag(
          commandId: 'cmd-create-tag-1',
          name: '出差报销',
        );
        expect((await catalogQ.getActiveTags()).map((t) => t.name), ['出差报销']);

        recordId = await ledgerSvc.saveRecord(
          commandId: 'cmd-create-rec-1',
          draft: RecordDraft(
            type: RecordType.expense,
            money: Money.parse('68.00'),
            bookId: bookId,
            recordTime: DateTime.now().millisecondsSinceEpoch,
            categoryId: categories.first.id,
            remark: '高铁盒饭',
            tagIds: [tagId],
          ),
        );

        final savedRecord = await ledgerQ.getRecord(recordId);
        expect(savedRecord?.remark, '高铁盒饭');
        final recTags = await catalogQ.getRecordTags(recordId);
        expect(recTags.map((t) => t.name), ['出差报销']);
      });

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: const TallyIsleApp(),
        ),
      );

      Future<void> settle([int steps = 10]) async {
        for (var i = 0; i < steps; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 50));
        }
      }

      await settle();

      final rowFinder = find.byKey(Key('record-$recordId'));
      expect(rowFinder, findsOneWidget);
      expect(
        find.descendant(of: rowFinder, matching: find.text('高铁盒饭')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: rowFinder, matching: find.text('#出差报销')),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox());
      await settle();
      await tester.pump(const Duration(seconds: 1));
    },
  );
}
