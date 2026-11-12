import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/app/app.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/data/db/database.dart';

void main() {
  testWidgets('navigate to me page, manage books, categories, and tags', (
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

    // 1. Go to "更多"
    await tester.tap(find.text('更多'));
    await settle();
    expect(find.text('账本管理'), findsOneWidget);
    expect(find.text('分类管理'), findsOneWidget);
    expect(find.text('标签管理'), findsOneWidget);

    // 2. Open Books Page
    await tester.tap(find.byKey(const Key('me-books')));
    await settle();
    expect(find.text('日常账本'), findsOneWidget);
    expect(find.text('当前'), findsOneWidget);

    // Add a new book
    await tester.tap(find.byKey(const Key('add-book')));
    await settle();
    await tester.enterText(find.byKey(const Key('book-name')), '旅行账本');
    await tester.enterText(find.byKey(const Key('book-start-day')), '15');
    await tester.tap(find.byKey(const Key('book-save')));
    await settle();
    expect(find.text('旅行账本'), findsOneWidget);
    expect(find.text('每月 15 日起始'), findsOneWidget);

    // Back to "我的"
    await tester.tap(find.byType(BackButton));
    await settle();

    // 3. Open Categories Page
    await tester.tap(find.byKey(const Key('me-categories')));
    await settle();
    expect(find.text('餐饮'), findsOneWidget);
    expect(find.text('购物'), findsOneWidget);

    // Add a top-level category
    await tester.tap(find.byKey(const Key('add-category')));
    await settle();
    await tester.enterText(find.byKey(const Key('category-name')), '数码科技');
    await tester.tap(find.byKey(const Key('category-save')));
    await settle();
    await tester.drag(find.byType(ListView).first, const Offset(0, -300));
    await settle();
    expect(find.text('数码科技'), findsOneWidget);

    // Back to "我的"
    await tester.tap(find.byType(BackButton));
    await settle();

    // 4. Open Tags Page
    await tester.tap(find.byKey(const Key('me-tags')));
    await settle();
    expect(find.text('新建标签'), findsOneWidget);

    // Add a tag
    await tester.tap(find.byKey(const Key('add-tag')));
    await settle();
    await tester.enterText(find.byKey(const Key('tag-name')), '出差报销');
    await tester.tap(find.byKey(const Key('tag-save')));
    await settle();
    expect(find.text('出差报销'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await settle();
    await tester.pump(const Duration(seconds: 1));
  });
}
