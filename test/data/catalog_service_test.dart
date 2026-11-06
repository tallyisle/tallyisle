import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/catalog/catalog_queries.dart';
import 'package:tallyisle/data/catalog/catalog_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/db/seed.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/domain/model/codes.dart';

Money m(String s) => Money.parse(s);

void main() {
  late AppDatabase db;
  late CatalogService catalog;
  late CatalogQueries queries;
  late LedgerService ledger;
  var n = 0;
  String cmd() => 'cat-cmd-${n++}';

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    catalog = CatalogService(db);
    queries = CatalogQueries(db);
    ledger = LedgerService(db);
  });

  tearDown(() => db.close());

  group('Books (F-003)', () {
    test('initial seed creates book 1 with 16 preset categories', () async {
      final books = await queries.watchBooks().first;
      expect(books, hasLength(1));
      expect(books.first.id, defaultBookId);
      expect(books.first.name, '日常账本');
      expect(books.first.startDay, 1);

      final cats = await queries.watchCategories(defaultBookId).first;
      expect(cats.where((c) => c.type == 0), hasLength(12));
      expect(cats.where((c) => c.type == 1), hasLength(4));
      expect(await queries.watchCurrentBookId().first, 1);
    });

    test(
      'createBook copies 16 preset categories and validates startDay',
      () async {
        final b2Id = await catalog.createBook(
          commandId: cmd(),
          name: '旅行账本',
          startDay: 15,
        );
        expect(b2Id, 2);

        final book2 = await queries.watchBook(b2Id).first;
        expect(book2, isNotNull);
        expect(book2!.name, '旅行账本');
        expect(book2.startDay, 15);

        final cats = await queries.watchCategories(b2Id).first;
        expect(cats.where((c) => c.type == 0), hasLength(12));
        expect(cats.where((c) => c.type == 1), hasLength(4));

        // Validation
        expect(
          () => catalog.createBook(commandId: cmd(), name: '   '),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.validation,
            ),
          ),
        );
        expect(
          () => catalog.createBook(commandId: cmd(), name: '非法', startDay: 0),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.validation,
            ),
          ),
        );
        expect(
          () => catalog.createBook(commandId: cmd(), name: '非法', startDay: 29),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.validation,
            ),
          ),
        );
      },
    );

    test('updateBook and reorderBooks', () async {
      await catalog.updateBook(
        commandId: cmd(),
        bookId: 1,
        name: '家庭账本',
        startDay: 10,
      );
      final b1 = await queries.watchBook(1).first;
      expect(b1!.name, '家庭账本');
      expect(b1.startDay, 10);

      final b2 = await catalog.createBook(commandId: cmd(), name: '第二本');
      await catalog.reorderBooks(commandId: cmd(), bookIds: [b2, 1]);

      final books = await queries.watchBooks().first;
      expect(books.first.id, b2);
      expect(books.last.id, 1);
    });

    test('deleteBook rules: cannot delete sole book', () async {
      expect(
        () => catalog.deleteBook(commandId: cmd(), bookId: 1),
        throwsA(
          isA<Failure>()
              .having((f) => f.code, 'code', FailureCode.validation)
              .having((f) => f.message, 'message', contains('至少保留一个账本')),
        ),
      );
    });

    test('deleteBook rules: cannot delete book with records', () async {
      final b2 = await catalog.createBook(commandId: cmd(), name: '副账本');
      final assetId = await ledger.createAsset(
        commandId: cmd(),
        name: '钱包',
        initial: m('100.00'),
      );
      final foodCat = (await queries.watchCategories(b2).first).firstWhere(
        (c) => c.name == '餐饮',
      );

      await ledger.saveRecord(
        commandId: cmd(),
        draft: RecordDraft(
          type: RecordType.expense,
          money: m('20.00'),
          bookId: b2,
          recordTime: 1000,
          categoryId: foodCat.id,
          assetId: assetId,
        ),
      );

      expect(
        () => catalog.deleteBook(commandId: cmd(), bookId: b2),
        throwsA(
          isA<Failure>()
              .having((f) => f.code, 'code', FailureCode.validation)
              .having((f) => f.message, 'message', contains('账本下有账单，无法删除')),
        ),
      );
    });

    test(
      'deleteBook switches active book when current book is deleted',
      () async {
        final b2 = await catalog.createBook(commandId: cmd(), name: '账本2');
        expect(await queries.watchCurrentBookId().first, 1);

        // Book 1 has no records, delete it.
        await catalog.deleteBook(commandId: cmd(), bookId: 1);

        final books = await queries.watchBooks().first;
        expect(books, hasLength(1));
        expect(books.first.id, b2);
        // Switched to b2!
        expect(await queries.watchCurrentBookId().first, b2);
      },
    );
  });

  group('Categories (F-005)', () {
    test('create top-level and secondary categories', () async {
      final parentId = await catalog.createCategory(
        commandId: cmd(),
        accountBookId: 1,
        name: '数码科技',
        type: 0,
      );
      expect(parentId, greaterThan(0));

      final subId = await catalog.createCategory(
        commandId: cmd(),
        accountBookId: 1,
        name: '手机配件',
        type: 0,
        parentCatId: parentId,
      );
      expect(subId, greaterThan(0));

      // Cannot nest 3rd level
      expect(
        () => catalog.createCategory(
          commandId: cmd(),
          accountBookId: 1,
          name: '手机壳',
          type: 0,
          parentCatId: subId,
        ),
        throwsA(
          isA<Failure>()
              .having((f) => f.code, 'code', FailureCode.validation)
              .having((f) => f.message, 'message', contains('仅支持两级分类')),
        ),
      );

      // Cannot cross book
      final b2 = await catalog.createBook(commandId: cmd(), name: '新书');
      expect(
        () => catalog.createCategory(
          commandId: cmd(),
          accountBookId: b2,
          name: '跨账本子类',
          type: 0,
          parentCatId: parentId,
        ),
        throwsA(
          isA<Failure>().having((f) => f.code, 'code', FailureCode.validation),
        ),
      );

      // Cannot cross type
      expect(
        () => catalog.createCategory(
          commandId: cmd(),
          accountBookId: 1,
          name: '跨类型子类',
          type: 1,
          parentCatId: parentId,
        ),
        throwsA(
          isA<Failure>().having((f) => f.code, 'code', FailureCode.validation),
        ),
      );
    });

    test('update, hide, and reorder categories', () async {
      final catId = await catalog.createCategory(
        commandId: cmd(),
        accountBookId: 1,
        name: '宠物',
        type: 0,
      );

      await catalog.updateCategory(
        commandId: cmd(),
        categoryId: catId,
        name: '爱宠',
      );
      var all = await queries.watchCategories(1).first;
      expect(all.firstWhere((c) => c.id == catId).name, '爱宠');

      await catalog.setCategoryHidden(
        commandId: cmd(),
        categoryId: catId,
        isHide: true,
      );
      all = await queries.watchCategories(1).first;
      expect(all.firstWhere((c) => c.id == catId).isHide, isTrue);

      final active = await queries.watchActiveCategories(1).first;
      expect(active.any((c) => c.id == catId), isFalse);
    });

    test(
      'deleteCategory without bills deletes category and its children',
      () async {
        final parentId = await catalog.createCategory(
          commandId: cmd(),
          accountBookId: 1,
          name: '汽车',
          type: 0,
        );
        final subId = await catalog.createCategory(
          commandId: cmd(),
          accountBookId: 1,
          name: '加油',
          type: 0,
          parentCatId: parentId,
        );

        await catalog.deleteCategory(commandId: cmd(), categoryId: parentId);
        final all = await queries.watchCategories(1).first;
        expect(all.any((c) => c.id == parentId), isFalse);
        expect(all.any((c) => c.id == subId), isFalse);
      },
    );

    test(
      'deleteCategory with bills requires target and migrates correctly',
      () async {
        final cash = await ledger.createAsset(
          commandId: cmd(),
          name: '现金',
          initial: m('500.00'),
        );
        final allCats = await queries.watchCategories(1).first;
        final foodCat = allCats.firstWhere((c) => c.name == '餐饮');
        final snackCat = allCats.firstWhere((c) => c.name == '零食');

        // Create a subcategory under food
        final fastFoodId = await catalog.createCategory(
          commandId: cmd(),
          accountBookId: 1,
          name: '快餐',
          type: 0,
          parentCatId: foodCat.id,
        );

        // Record a bill under fastFood
        final recId = await ledger.saveRecord(
          commandId: cmd(),
          draft: RecordDraft(
            type: RecordType.expense,
            money: m('35.00'),
            bookId: 1,
            recordTime: 12345,
            categoryId: fastFoodId,
            assetId: cash,
          ),
        );

        expect(await queries.countRecordsInCategory(fastFoodId), 1);
        expect(await queries.countRecordsInCategory(foodCat.id), 1);

        // Deleting without targetCategoryId fails
        expect(
          () =>
              catalog.deleteCategory(commandId: cmd(), categoryId: fastFoodId),
          throwsA(
            isA<Failure>()
                .having((f) => f.code, 'code', FailureCode.validation)
                .having((f) => f.message, 'message', contains('请选择迁移目标分类')),
          ),
        );

        // Deleting with target pointing to itself or its child fails
        expect(
          () => catalog.deleteCategory(
            commandId: cmd(),
            categoryId: foodCat.id,
            targetCategoryId: fastFoodId,
          ),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.validation,
            ),
          ),
        );

        // Migrate bills to snackCat
        await catalog.deleteCategory(
          commandId: cmd(),
          categoryId: fastFoodId,
          targetCategoryId: snackCat.id,
        );

        // Record is migrated to snackCat
        final record = await (db.select(
          db.records,
        )..where((t) => t.recordId.equals(recId))).getSingle();
        expect(record.recordCatId, snackCat.id);

        // Cash balance unchanged: 500 - 35 = 465.00
        final cashAsset = await (db.select(
          db.assets,
        )..where((t) => t.id.equals(cash))).getSingle();
        expect(cashAsset.balanceMinor, BigInt.from(46500));
      },
    );
  });

  group('Tags (F-018)', () {
    test('create tag group, child tag, and standalone tag', () async {
      final grpId = await catalog.createTag(
        commandId: cmd(),
        name: '项目',
        isGroup: true,
      );
      final grp = await (db.select(
        db.tags,
      )..where((t) => t.tagId.equals(grpId))).getSingle();
      expect(grp.parent, 1);
      expect(grp.parentTagId, isNull);

      final childId = await catalog.createTag(
        commandId: cmd(),
        name: '子项目A',
        parentTagId: grpId,
      );
      final child = await (db.select(
        db.tags,
      )..where((t) => t.tagId.equals(childId))).getSingle();
      expect(child.parent, 0);
      expect(child.parentTagId, grpId);

      final standId = await catalog.createTag(commandId: cmd(), name: '报销单');
      final stand = await (db.select(
        db.tags,
      )..where((t) => t.tagId.equals(standId))).getSingle();
      expect(stand.parent, 0);
      expect(stand.parentTagId, isNull);
    });

    test('deleteTag cleans up tag_record links and child tags', () async {
      final cash = await ledger.createAsset(
        commandId: cmd(),
        name: '现金',
        initial: m('100.00'),
      );
      final foodCat = (await queries.watchCategories(1).first).firstWhere(
        (c) => c.name == '餐饮',
      );

      final grpId = await catalog.createTag(
        commandId: cmd(),
        name: '组1',
        isGroup: true,
      );
      final childId = await catalog.createTag(
        commandId: cmd(),
        name: '标签1',
        parentTagId: grpId,
      );

      // Record linked to tag
      final recId = await ledger.saveRecord(
        commandId: cmd(),
        draft: RecordDraft(
          type: RecordType.expense,
          money: m('10.00'),
          bookId: 1,
          recordTime: 1234,
          categoryId: foodCat.id,
          assetId: cash,
          tagIds: [childId],
        ),
      );

      var links = await (db.select(
        db.tagRecords,
      )..where((t) => t.recordId.equals(recId))).get();
      expect(links, hasLength(1));
      expect(links.first.tagId, childId);

      // Delete the parent tag group
      await catalog.deleteTag(commandId: cmd(), tagId: grpId);

      // Child tag and links are deleted
      expect(
        await (db.select(db.tags)..where((t) => t.tagId.equals(grpId))).get(),
        isEmpty,
      );
      expect(
        await (db.select(db.tags)..where((t) => t.tagId.equals(childId))).get(),
        isEmpty,
      );
      expect(
        await (db.select(
          db.tagRecords,
        )..where((t) => t.recordId.equals(recId))).get(),
        isEmpty,
      );
    });
  });

  group('Idempotency (ADR-009)', () {
    test(
      'same commandId with same payload returns cached result; changed payload conflicts',
      () async {
        final first = await catalog.createBook(
          commandId: 'idemp-1',
          name: '幂等账本',
          startDay: 5,
        );
        final second = await catalog.createBook(
          commandId: 'idemp-1',
          name: '幂等账本',
          startDay: 5,
        );
        expect(first, second);

        final count = await (db.select(
          db.accountBooks,
        )..where((t) => t.name.equals('幂等账本'))).get();
        expect(count, hasLength(1));

        // Changed payload
        expect(
          () => catalog.createBook(
            commandId: 'idemp-1',
            name: '不同名字',
            startDay: 5,
          ),
          throwsA(
            isA<Failure>().having((f) => f.code, 'code', FailureCode.conflict),
          ),
        );
      },
    );
  });
}
