import 'package:drift/drift.dart';

import 'database.dart';

/// Default initial account book id (日常账本).
const defaultBookId = 1;

/// Built-in 16 preset categories (12 expense + 4 income) seeded on first run.
const presetExpenseCategories = [
  '餐饮', '购物', '交通', '娱乐', '零食', '日用品', //
  '生活居家', '话费', '运动', '医疗', '发红包', '捐款',
];
const presetIncomeCategories = ['工资', '零花钱', '奖金', '收红包'];

/// First-run initial database state: book 1 + 16 preset categories, no accounts.
Future<void> seedDefaults(AppDatabase db, int nowMs) async {
  await db
      .into(db.accountBooks)
      .insert(
        AccountBooksCompanion.insert(
          id: const Value(defaultBookId),
          name: '日常账本',
          createDate: nowMs,
        ),
      );
  var sort = 0;
  for (final (type, names) in [
    (0, presetExpenseCategories),
    (1, presetIncomeCategories),
  ]) {
    for (final name in names) {
      await db
          .into(db.recordCategories)
          .insert(
            RecordCategoriesCompanion.insert(
              name: name,
              type: type,
              sort: Value(sort++),
              accountBookId: defaultBookId,
            ),
          );
    }
  }
  await db
      .into(db.currencies)
      .insert(
        CurrenciesCompanion.insert(
          code: 'CNY',
          name: '人民币',
          symbol: '¥',
          rateToAnchor: '1',
          anchorCode: 'CNY',
        ),
      );
  await db
      .into(db.preferences)
      .insert(
        PreferencesCompanion.insert(
          key: 'current_book_id',
          value: '$defaultBookId',
        ),
      );
}
