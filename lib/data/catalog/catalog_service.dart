import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/failure.dart';
import '../db/database.dart';
import '../db/failures.dart';
import '../db/seed.dart';

const _uuid = Uuid();

/// Write boundary for account books, categories, and tags (F-003, F-005, F-018).
///
/// Every mutating command executes within an idempotent database transaction.
final class CatalogService {
  CatalogService(this.db);
  final AppDatabase db;

  int _now() => db.nowMs();

  Future<T> _command<T>(
    String commandId,
    List<Object?> payload,
    Future<String> Function() body,
    T Function(String resultId) result,
  ) async {
    if (commandId.isEmpty || commandId.length > 128) {
      throw const Failure(FailureCode.validation, '提交标识无效');
    }
    final hash = sha256.convert(utf8.encode(jsonEncode(payload))).toString();
    return guardDatabase(
      () => db.transaction(() async {
        final previous = await (db.select(
          db.writeCommands,
        )..where((t) => t.commandId.equals(commandId))).getSingleOrNull();
        if (previous != null) {
          if (previous.payloadHash != hash) {
            throw const Failure(FailureCode.conflict, '同一提交标识的内容发生变化');
          }
          return result(previous.resultId);
        }
        final id = await body();
        await db
            .into(db.writeCommands)
            .insert(
              WriteCommandsCompanion.insert(
                commandId: commandId,
                payloadHash: hash,
                resultId: id,
                committedAt: _now(),
              ),
            );
        return result(id);
      }),
    );
  }

  // ---------------------------------------------------------------------------
  // Books (F-003)
  // ---------------------------------------------------------------------------

  /// Creates a new book and copies the 16 preset categories into it.
  Future<int> createBook({
    required String commandId,
    required String name,
    int startDay = 1,
    int? sort,
  }) {
    final trimmedName = name.trim();
    return _command(
      commandId,
      ['catalog-create-book-v1', trimmedName, startDay, sort],
      () async {
        if (trimmedName.isEmpty) {
          throw const Failure(FailureCode.validation, '账本名称不能为空');
        }
        if (startDay < 1 || startDay > 28) {
          throw const Failure(FailureCode.validation, '月起始日须在 1 到 28 之间');
        }

        final maxIdRow = await db
            .customSelect('SELECT MAX(id) AS m FROM account_book')
            .getSingleOrNull();
        final newBookId = ((maxIdRow?.data['m'] as int?) ?? 0) + 1;

        final maxSortRow = await db
            .customSelect('SELECT MAX(sort) AS m FROM account_book')
            .getSingleOrNull();
        final effectiveSort =
            sort ?? (((maxSortRow?.data['m'] as int?) ?? 0) + 1);

        await db
            .into(db.accountBooks)
            .insert(
              AccountBooksCompanion.insert(
                id: Value(newBookId),
                name: trimmedName,
                startDay: Value(startDay),
                sort: Value(effectiveSort),
                createDate: _now(),
              ),
            );

        // Seed 16 preset categories for the new book (12 expense + 4 income).
        var catSort = 0;
        for (final (type, names) in [
          (0, presetExpenseCategories),
          (1, presetIncomeCategories),
        ]) {
          for (final catName in names) {
            await db
                .into(db.recordCategories)
                .insert(
                  RecordCategoriesCompanion.insert(
                    name: catName,
                    type: type,
                    sort: Value(catSort++),
                    accountBookId: newBookId,
                    parentCatId: const Value(-1),
                  ),
                );
          }
        }

        return '$newBookId';
      },
      int.parse,
    );
  }

  /// Updates book name and start day.
  Future<int> updateBook({
    required String commandId,
    required int bookId,
    required String name,
    required int startDay,
  }) {
    final trimmedName = name.trim();
    return _command(
      commandId,
      ['catalog-update-book-v1', bookId, trimmedName, startDay],
      () async {
        if (trimmedName.isEmpty) {
          throw const Failure(FailureCode.validation, '账本名称不能为空');
        }
        if (startDay < 1 || startDay > 28) {
          throw const Failure(FailureCode.validation, '月起始日须在 1 到 28 之间');
        }
        final existing = await (db.select(
          db.accountBooks,
        )..where((t) => t.id.equals(bookId))).getSingleOrNull();
        if (existing == null) {
          throw const Failure(FailureCode.validation, '账本不存在');
        }

        await (db.update(
          db.accountBooks,
        )..where((t) => t.id.equals(bookId))).write(
          AccountBooksCompanion(
            name: Value(trimmedName),
            startDay: Value(startDay),
          ),
        );
        return '$bookId';
      },
      int.parse,
    );
  }

  /// Reorders books by setting sort according to the given order.
  Future<void> reorderBooks({
    required String commandId,
    required List<int> bookIds,
  }) => _command(commandId, ['catalog-reorder-books-v1', bookIds], () async {
    for (final (index, id) in bookIds.indexed) {
      await (db.update(db.accountBooks)..where((t) => t.id.equals(id))).write(
        AccountBooksCompanion(sort: Value(index)),
      );
    }
    return 'ok';
  }, (_) {});

  /// Deletes a book.
  ///
  /// Enforces:
  /// - At least one book must remain.
  /// - Cannot delete if the book contains records.
  /// - If the deleted book was the current book, switches current_book_id to
  ///   the first remaining book.
  Future<void> deleteBook({required String commandId, required int bookId}) =>
      _command(commandId, ['catalog-delete-book-v1', bookId], () async {
        final totalRow = await db
            .customSelect('SELECT COUNT(*) AS c FROM account_book')
            .getSingle();
        final totalCount = (totalRow.data['c'] as int?) ?? 0;
        if (totalCount <= 1) {
          throw const Failure(FailureCode.validation, '至少保留一个账本');
        }

        final recCountRow = await db
            .customSelect(
              'SELECT COUNT(*) AS c FROM record WHERE account_book_id = ?',
              variables: [Variable.withInt(bookId)],
            )
            .getSingle();
        final recordCount = (recCountRow.data['c'] as int?) ?? 0;
        if (recordCount > 0) {
          throw const Failure(FailureCode.validation, '账本下有账单，无法删除');
        }

        await (db.delete(
          db.accountBooks,
        )..where((t) => t.id.equals(bookId))).go();
        await (db.delete(
          db.recordCategories,
        )..where((t) => t.accountBookId.equals(bookId))).go();
        await (db.delete(
          db.assetBooks,
        )..where((t) => t.bookId.equals(bookId))).go();

        final currentPref = await (db.select(
          db.preferences,
        )..where((t) => t.key.equals('current_book_id'))).getSingleOrNull();
        if (currentPref?.value == '$bookId') {
          final remaining =
              await (db.select(db.accountBooks)
                    ..orderBy([
                      (t) => OrderingTerm.asc(t.sort),
                      (t) => OrderingTerm.asc(t.id),
                    ])
                    ..limit(1))
                  .getSingle();
          await db
              .into(db.preferences)
              .insertOnConflictUpdate(
                PreferencesCompanion.insert(
                  key: 'current_book_id',
                  value: '${remaining.id}',
                ),
              );
        }

        return '$bookId';
      }, (_) {});

  /// Switches the active book in preferences.
  Future<void> setCurrentBook({
    required String commandId,
    required int bookId,
  }) => _command(commandId, ['catalog-set-current-book-v1', bookId], () async {
    final book = await (db.select(
      db.accountBooks,
    )..where((t) => t.id.equals(bookId))).getSingleOrNull();
    if (book == null) {
      throw const Failure(FailureCode.validation, '账本不存在');
    }
    await db
        .into(db.preferences)
        .insertOnConflictUpdate(
          PreferencesCompanion.insert(key: 'current_book_id', value: '$bookId'),
        );
    return '$bookId';
  }, (_) {});

  // ---------------------------------------------------------------------------
  // Categories (F-005)
  // ---------------------------------------------------------------------------

  /// Creates a top-level (parentCatId = -1) or secondary category.
  Future<int> createCategory({
    required String commandId,
    required int accountBookId,
    required String name,
    required int type,
    int parentCatId = -1,
    String? icon,
    String? colorFill,
  }) {
    final trimmedName = name.trim();
    return _command(
      commandId,
      [
        'catalog-create-category-v1',
        accountBookId,
        trimmedName,
        type,
        parentCatId,
        icon,
        colorFill,
      ],
      () async {
        if (trimmedName.isEmpty) {
          throw const Failure(FailureCode.validation, '分类名称不能为空');
        }
        if (type != 0 && type != 1) {
          throw const Failure(FailureCode.validation, '分类类型无效');
        }

        if (parentCatId != -1) {
          final parent = await (db.select(
            db.recordCategories,
          )..where((t) => t.id.equals(parentCatId))).getSingleOrNull();
          if (parent == null) {
            throw const Failure(FailureCode.validation, '父分类不存在');
          }
          if (parent.accountBookId != accountBookId) {
            throw const Failure(FailureCode.validation, '父分类属于不同账本');
          }
          if (parent.type != type) {
            throw const Failure(FailureCode.validation, '父分类类型不匹配');
          }
          if (parent.parentCatId != -1) {
            throw const Failure(FailureCode.validation, '仅支持两级分类，无法在子分类下创建分类');
          }
        }

        final maxSortRow = await db
            .customSelect(
              'SELECT MAX(sort) AS m FROM record_category '
              'WHERE account_book_id = ? AND parent_cat_id = ? AND type = ?',
              variables: [
                Variable.withInt(accountBookId),
                Variable.withInt(parentCatId),
                Variable.withInt(type),
              ],
            )
            .getSingleOrNull();
        final sort = ((maxSortRow?.data['m'] as int?) ?? 0) + 1;

        final id = await db
            .into(db.recordCategories)
            .insert(
              RecordCategoriesCompanion.insert(
                name: trimmedName,
                icon: Value(icon ?? ''),
                type: type,
                sort: Value(sort),
                parentCatId: Value(parentCatId),
                colorFill: Value(colorFill),
                accountBookId: accountBookId,
              ),
            );
        return '$id';
      },
      int.parse,
    );
  }

  /// Renames or edits a category.
  Future<int> updateCategory({
    required String commandId,
    required int categoryId,
    required String name,
    String? icon,
    String? colorFill,
  }) {
    final trimmedName = name.trim();
    return _command(
      commandId,
      ['catalog-update-category-v1', categoryId, trimmedName, icon, colorFill],
      () async {
        if (trimmedName.isEmpty) {
          throw const Failure(FailureCode.validation, '分类名称不能为空');
        }
        final existing = await (db.select(
          db.recordCategories,
        )..where((t) => t.id.equals(categoryId))).getSingleOrNull();
        if (existing == null) {
          throw const Failure(FailureCode.validation, '分类不存在');
        }

        await (db.update(
          db.recordCategories,
        )..where((t) => t.id.equals(categoryId))).write(
          RecordCategoriesCompanion(
            name: Value(trimmedName),
            icon: icon == null ? const Value.absent() : Value(icon),
            colorFill: colorFill == null
                ? const Value.absent()
                : Value(colorFill),
          ),
        );
        return '$categoryId';
      },
      int.parse,
    );
  }

  /// Reorders categories within the same level/type.
  Future<void> reorderCategories({
    required String commandId,
    required List<int> categoryIds,
  }) => _command(
    commandId,
    ['catalog-reorder-categories-v1', categoryIds],
    () async {
      for (final (index, id) in categoryIds.indexed) {
        await (db.update(db.recordCategories)..where((t) => t.id.equals(id)))
            .write(RecordCategoriesCompanion(sort: Value(index)));
      }
      return 'ok';
    },
    (_) {},
  );

  /// Toggles is_hide on a category.
  Future<void> setCategoryHidden({
    required String commandId,
    required int categoryId,
    required bool isHide,
  }) => _command(
    commandId,
    ['catalog-set-category-hidden-v1', categoryId, isHide],
    () async {
      final existing = await (db.select(
        db.recordCategories,
      )..where((t) => t.id.equals(categoryId))).getSingleOrNull();
      if (existing == null) {
        throw const Failure(FailureCode.validation, '分类不存在');
      }

      await (db.update(db.recordCategories)
            ..where((t) => t.id.equals(categoryId)))
          .write(RecordCategoriesCompanion(isHide: Value(isHide)));
      return '$categoryId';
    },
    (_) {},
  );

  /// Deletes a category.
  ///
  /// If the category (or its children) has bills:
  /// - [targetCategoryId] is required, must belong to the same book and type,
  ///   and cannot be inside the subtree to be deleted.
  /// - All referencing records have their `record_cat_id` moved to [targetCategoryId].
  ///
  /// If the category has no bills, it is deleted directly (a top-level category
  /// also deletes its subcategories).
  Future<void> deleteCategory({
    required String commandId,
    required int categoryId,
    int? targetCategoryId,
  }) => _command(
    commandId,
    ['catalog-delete-category-v1', categoryId, targetCategoryId],
    () async {
      final cat = await (db.select(
        db.recordCategories,
      )..where((t) => t.id.equals(categoryId))).getSingleOrNull();
      if (cat == null) {
        throw const Failure(FailureCode.validation, '分类不存在');
      }

      final List<int> affectedIds;
      if (cat.parentCatId == -1) {
        final subs = await (db.select(
          db.recordCategories,
        )..where((t) => t.parentCatId.equals(categoryId))).get();
        affectedIds = [categoryId, ...subs.map((s) => s.id)];
      } else {
        affectedIds = [categoryId];
      }

      final inClause = affectedIds.join(',');
      final recCountRow = await db
          .customSelect(
            'SELECT COUNT(*) AS c FROM record WHERE record_cat_id IN ($inClause)',
          )
          .getSingle();
      final count = (recCountRow.data['c'] as int?) ?? 0;

      if (count > 0) {
        if (targetCategoryId == null) {
          throw const Failure(FailureCode.validation, '该分类下有账单，请选择迁移目标分类');
        }
        if (affectedIds.contains(targetCategoryId)) {
          throw const Failure(FailureCode.validation, '不能迁移到即将被删除的分类');
        }
        final target = await (db.select(
          db.recordCategories,
        )..where((t) => t.id.equals(targetCategoryId))).getSingleOrNull();
        if (target == null) {
          throw const Failure(FailureCode.validation, '目标分类不存在');
        }
        if (target.accountBookId != cat.accountBookId) {
          throw const Failure(FailureCode.validation, '目标分类属于不同账本');
        }
        if (target.type != cat.type) {
          throw const Failure(FailureCode.validation, '目标分类类型不匹配');
        }

        await db.customUpdate(
          'UPDATE record SET record_cat_id = ? WHERE record_cat_id IN ($inClause)',
          variables: [Variable.withInt(targetCategoryId)],
          updates: {db.records},
        );
        await db.customUpdate(
          'UPDATE budget SET record_cat_id = ? WHERE record_cat_id IN ($inClause)',
          variables: [Variable.withInt(targetCategoryId)],
          updates: {db.budgets},
        );
      }

      await (db.delete(
        db.recordCategories,
      )..where((t) => t.id.isIn(affectedIds))).go();

      return '$categoryId';
    },
    (_) {},
  );

  // ---------------------------------------------------------------------------
  // Tags (F-018)
  // ---------------------------------------------------------------------------

  /// Creates a tag or tag group. Returns the generated tagId (UUID).
  Future<String> createTag({
    required String commandId,
    required String name,
    String? parentTagId,
    bool isGroup = false,
    String? color,
    int? sort,
  }) {
    final trimmedName = name.trim();
    return _command(
      commandId,
      ['catalog-create-tag-v1', trimmedName, parentTagId, isGroup, color, sort],
      () async {
        if (trimmedName.isEmpty) {
          throw const Failure(FailureCode.validation, '标签名称不能为空');
        }

        if (parentTagId != null) {
          final parentTag = await (db.select(
            db.tags,
          )..where((t) => t.tagId.equals(parentTagId))).getSingleOrNull();
          if (parentTag == null) {
            throw const Failure(FailureCode.validation, '父标签不存在');
          }
          if (parentTag.parent != 1) {
            throw const Failure(FailureCode.validation, '父标签不是标签组');
          }
        }

        final maxSortRow = await db
            .customSelect('SELECT MAX(sort) AS m FROM tag')
            .getSingleOrNull();
        final effectiveSort =
            sort ?? (((maxSortRow?.data['m'] as int?) ?? 0) + 1);

        final tagId = _uuid.v4();
        await db
            .into(db.tags)
            .insert(
              TagsCompanion.insert(
                tagId: tagId,
                name: trimmedName,
                sort: Value(effectiveSort),
                hidden: const Value(false),
                parentTagId: Value(isGroup ? null : parentTagId),
                parent: Value(isGroup ? 1 : 0),
                color: Value(color),
              ),
            );
        return tagId;
      },
      (id) => id,
    );
  }

  /// Renames or updates the color of a tag.
  Future<String> updateTag({
    required String commandId,
    required String tagId,
    required String name,
    String? color,
  }) {
    final trimmedName = name.trim();
    return _command(
      commandId,
      ['catalog-update-tag-v1', tagId, trimmedName, color],
      () async {
        if (trimmedName.isEmpty) {
          throw const Failure(FailureCode.validation, '标签名称不能为空');
        }
        final existing = await (db.select(
          db.tags,
        )..where((t) => t.tagId.equals(tagId))).getSingleOrNull();
        if (existing == null) {
          throw const Failure(FailureCode.validation, '标签不存在');
        }

        await (db.update(db.tags)..where((t) => t.tagId.equals(tagId))).write(
          TagsCompanion(
            name: Value(trimmedName),
            color: color == null ? const Value.absent() : Value(color),
          ),
        );
        return tagId;
      },
      (id) => id,
    );
  }

  /// Reorders tags according to the given order.
  Future<void> reorderTags({
    required String commandId,
    required List<String> tagIds,
  }) => _command(commandId, ['catalog-reorder-tags-v1', tagIds], () async {
    for (final (index, id) in tagIds.indexed) {
      await (db.update(db.tags)..where((t) => t.tagId.equals(id))).write(
        TagsCompanion(sort: Value(index)),
      );
    }
    return 'ok';
  }, (_) {});

  /// Toggles hidden on a tag.
  Future<void> setTagHidden({
    required String commandId,
    required String tagId,
    required bool hidden,
  }) => _command(
    commandId,
    ['catalog-set-tag-hidden-v1', tagId, hidden],
    () async {
      final existing = await (db.select(
        db.tags,
      )..where((t) => t.tagId.equals(tagId))).getSingleOrNull();
      if (existing == null) {
        throw const Failure(FailureCode.validation, '标签不存在');
      }

      await (db.update(db.tags)..where((t) => t.tagId.equals(tagId))).write(
        TagsCompanion(hidden: Value(hidden)),
      );
      return tagId;
    },
    (_) {},
  );

  /// Deletes a tag, deleting its children if it is a tag group,
  /// and cleaning up all tag_record links.
  Future<void> deleteTag({required String commandId, required String tagId}) =>
      _command(commandId, ['catalog-delete-tag-v1', tagId], () async {
        final tag = await (db.select(
          db.tags,
        )..where((t) => t.tagId.equals(tagId))).getSingleOrNull();
        if (tag == null) return tagId;

        final List<String> affectedIds;
        if (tag.parent == 1) {
          final children = await (db.select(
            db.tags,
          )..where((t) => t.parentTagId.equals(tagId))).get();
          affectedIds = [tagId, ...children.map((c) => c.tagId)];
        } else {
          affectedIds = [tagId];
        }

        await (db.delete(
          db.tagRecords,
        )..where((t) => t.tagId.isIn(affectedIds))).go();
        await (db.delete(
          db.tags,
        )..where((t) => t.tagId.isIn(affectedIds))).go();

        return tagId;
      }, (_) {});
}
