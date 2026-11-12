import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/core/zip_archive.dart';
import 'package:tallyisle/data/backup/tally_backup_service.dart';
import 'package:tallyisle/data/catalog/catalog_queries.dart';
import 'package:tallyisle/data/catalog/catalog_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/db/seed.dart';
import 'package:tallyisle/data/debt/debt_service.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/data/reminder/reminder_service.dart';
import 'package:tallyisle/data/tools/batch_record_service.dart';
import 'package:tallyisle/data/tools/bill_attachment_service.dart';
import 'package:tallyisle/data/tools/category_transfer_service.dart';
import 'package:tallyisle/domain/ledger/record_extra.dart';
import 'package:tallyisle/domain/ledger/record_relations.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/budget_rules.dart';
import 'package:tallyisle/platform/files.dart';
import 'package:tallyisle/platform/notifications.dart'
    show InMemoryReminderScheduler;

Money m(String s, [String code = 'CNY']) => Money.parse(s, currency: code);

Matcher _fails(FailureCode code) =>
    throwsA(isA<Failure>().having((f) => f.code, 'code', code));

/// Minimal 1x1 valid PNG bytes for deterministic image attachment tests.
final Uint8List _samplePngBytes = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

void main() {
  late AppDatabase db;
  late Directory tempRoot;
  late Directory attDir;
  late Directory backupDir;
  late CatalogService catalog;
  late CatalogQueries queries;
  late LedgerService ledger;
  late DebtService debt;
  late CategoryTransferService catTransfer;
  late BatchRecordService batchService;
  late BillAttachmentService attService;
  var seq = 0;
  String cmd() => 'm6-svc-${seq++}';

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    tempRoot = await Directory.systemTemp.createTemp('tallyisle_m6a_svc_');
    attDir = Directory(p.join(tempRoot.path, 'attachments'));
    backupDir = Directory(p.join(tempRoot.path, 'backups'));
    catalog = CatalogService(db);
    queries = CatalogQueries(db);
    ledger = LedgerService(db);
    debt = DebtService(db);
    catTransfer = CategoryTransferService(db);
    batchService = BatchRecordService(db);
    attService = BillAttachmentService(
      db,
      attachmentsDirectoryProvider: () async => attDir,
    );
  });

  tearDown(() async {
    await db.close();
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  Future<Asset> loadAsset(int id) async =>
      (await (db.select(db.assets)..where((t) => t.id.equals(id))).getSingle());

  Future<LedgerRecord?> loadRecord(String id) => (db.select(
    db.records,
  )..where((t) => t.recordId.equals(id))).getSingleOrNull();

  group('CategoryTransferService (F-031)', () {
    test(
      'export, share, pick, and duplicate-safe import via FileAccess',
      () async {
        // Seed a custom 2-level category in Book 1
        final petTopId = await catalog.createCategory(
          commandId: cmd(),
          accountBookId: defaultBookId,
          name: '宠物',
          type: 0,
          icon: 'pet',
        );
        await catalog.createCategory(
          commandId: cmd(),
          accountBookId: defaultBookId,
          name: '猫粮',
          type: 0,
          parentCatId: petTopId,
        );

        Uint8List? savedBytes;
        String? savedName;
        Uint8List? sharedBytes;
        final fileAccess = FileAccess(
          onSaveBytes: (name, bytes, mime) async {
            savedName = name;
            savedBytes = bytes;
            expect(mime, 'application/json');
          },
          onShareBytes: (name, bytes, mime, subject) async {
            sharedBytes = bytes;
            expect(mime, 'application/json');
            expect(subject, contains('帐屿分类方案'));
          },
          onPickBytes: (_) async => SelectedBytes(savedName!, savedBytes!),
        );

        await catTransfer.exportCategoriesToSaveLocation(
          bookId: defaultBookId,
          fileAccess: fileAccess,
        );
        await catTransfer.shareCategoriesPack(
          bookId: defaultBookId,
          fileAccess: fileAccess,
        );
        expect(savedBytes, isNotNull);
        expect(sharedBytes, isNotNull);

        final picked = await catTransfer.pickCategoryPack(
          fileAccess: fileAccess,
        );
        expect(picked.pack.bookName, '日常账本');
        expect(picked.pack.subCategoryCount, 1);

        // Import into Book 2 (which already has 16 preset categories)
        final book2Id = await catalog.createBook(
          commandId: cmd(),
          name: '家庭账本',
        );
        final importCmd = cmd();
        final res = await catTransfer.importCategoryPack(
          commandId: importCmd,
          targetBookId: book2Id,
          pack: picked.pack,
        );
        expect(res.addedTopCount, 1); // Only '宠物' is new
        expect(res.addedSubCount, 1); // '猫粮' under '宠物'
        expect(
          res.skippedDuplicateCount,
          16,
        ); // All 16 preset categories reused

        // ADR-009 idempotency retry & payload conflict
        final retry = await catTransfer.importCategoryPack(
          commandId: importCmd,
          targetBookId: book2Id,
          pack: picked.pack,
        );
        expect(retry.addedTopCount, 1);
        expect(retry.addedSubCount, 1);

        expect(
          () => catTransfer.importCategoryPack(
            commandId: importCmd,
            targetBookId: defaultBookId, // mutated payload!
            pack: picked.pack,
          ),
          _fails(FailureCode.conflict),
        );
      },
    );

    test(
      'copyCategoriesBetweenBooks copies all or selected 2-level subset',
      () async {
        final foodTop = (await queries.watchCategories(defaultBookId).first)
            .firstWhere((c) => c.type == 0 && c.name == '餐饮');
        final coffeeSubId = await catalog.createCategory(
          commandId: cmd(),
          accountBookId: defaultBookId,
          name: '精品咖啡',
          type: 0,
          parentCatId: foodTop.id,
        );
        final hobbyTopId = await catalog.createCategory(
          commandId: cmd(),
          accountBookId: defaultBookId,
          name: '摄影器材',
          type: 0,
        );

        final book2Id = await catalog.createBook(commandId: cmd(), name: '副账本');

        // Guard: same book rejected
        expect(
          () => catTransfer.copyCategoriesBetweenBooks(
            commandId: cmd(),
            sourceBookId: defaultBookId,
            targetBookId: defaultBookId,
          ),
          _fails(FailureCode.validation),
        );

        // Copy only coffeeSubId -> reuses Book 2's existing '餐饮' parent and adds '精品咖啡', without copying '摄影器材'!
        final subRes = await catTransfer.copyCategoriesBetweenBooks(
          commandId: cmd(),
          sourceBookId: defaultBookId,
          targetBookId: book2Id,
          sourceCategoryIds: {coffeeSubId},
        );
        expect(subRes.addedTopCount, 0);
        expect(subRes.addedSubCount, 1);
        expect(subRes.skippedDuplicateCount, 1);

        final book2CatsAfterSub = await queries.watchCategories(book2Id).first;
        expect(book2CatsAfterSub.any((c) => c.name == '精品咖啡'), isTrue);
        expect(book2CatsAfterSub.any((c) => c.name == '摄影器材'), isFalse);

        // Copy all remaining
        final allRes = await catTransfer.copyCategoriesBetweenBooks(
          commandId: cmd(),
          sourceBookId: defaultBookId,
          targetBookId: book2Id,
        );
        expect(allRes.addedTopCount, 1);
        expect(hobbyTopId, greaterThan(0));
        final book2CatsAfterAll = await queries.watchCategories(book2Id).first;
        expect(book2CatsAfterAll.any((c) => c.name == '摄影器材'), isTrue);
      },
    );

    test(
      'migrateCategoryBills atomically updates all 6 tables, merges budgets/remarks, and supports source deletion',
      () async {
        final cats = await queries.watchCategories(defaultBookId).first;
        final srcTop = cats.firstWhere((c) => c.type == 0 && c.name == '餐饮');
        final dstTop = cats.firstWhere((c) => c.type == 0 && c.name == '购物');
        final srcSubId = await catalog.createCategory(
          commandId: cmd(),
          accountBookId: defaultBookId,
          name: '下午茶',
          type: 0,
          parentCatId: srcTop.id,
        );
        final walletId = await ledger.createAsset(
          commandId: cmd(),
          name: '现金',
          initial: m('500.00'),
        );

        // 1. Seed `record` on both srcTop and srcSubId
        final r1 = await ledger.saveRecord(
          commandId: cmd(),
          draft: RecordDraft(
            type: RecordType.expense,
            money: m('25.00'),
            recordTime: 1730000000000,
            bookId: defaultBookId,
            categoryId: srcTop.id,
            assetId: walletId,
          ),
        );
        final r2 = await ledger.saveRecord(
          commandId: cmd(),
          draft: RecordDraft(
            type: RecordType.expense,
            money: m('18.00'),
            recordTime: 1730000100000,
            bookId: defaultBookId,
            categoryId: srcSubId,
            assetId: walletId,
          ),
        );

        // 2. Seed `budget` rows: total budget = 500, dstTop = 300, srcTop = 250 -> merged dstTop = 550, total bumped to 550 (R7)!
        await db
            .into(db.budgets)
            .insert(
              BudgetsCompanion.insert(
                id: const Value(100),
                budgetType: BudgetTypeCode.total,
                recordCatId: -1,
                amountMinor: BigInt.from(50000),
                bookId: defaultBookId,
                section: '2026-11',
                createDate: 1730000000000,
              ),
            );
        await db
            .into(db.budgets)
            .insert(
              BudgetsCompanion.insert(
                id: const Value(101),
                budgetType: BudgetTypeCode.expenseCategory,
                recordCatId: dstTop.id,
                amountMinor: BigInt.from(30000),
                bookId: defaultBookId,
                section: '2026-11',
                createDate: 1730000000000,
              ),
            );
        await db
            .into(db.budgets)
            .insert(
              BudgetsCompanion.insert(
                id: const Value(102),
                budgetType: BudgetTypeCode.expenseCategory,
                recordCatId: srcTop.id,
                amountMinor: BigInt.from(25000),
                bookId: defaultBookId,
                section: '2026-11',
                createDate: 1730000000000,
              ),
            );

        // 3. Seed `record_period`
        final periodRowId = await db
            .into(db.recordPeriods)
            .insert(
              RecordPeriodsCompanion.insert(
                recordType: RecordType.expense,
                moneyMinor: BigInt.from(1500),
                catId: Value(srcSubId),
                assetId: Value(walletId),
                bookId: defaultBookId,
                periodType: 2,
                periodTypeDate: '1',
                periodStartDate: 1730000000000,
                periodEndDate: -1,
                createTime: 1730000000000,
              ),
            );

        // 4. Seed `record_template` (explicit PK `id`)
        await db
            .into(db.recordTemplates)
            .insert(
              RecordTemplatesCompanion.insert(
                id: const Value(201),
                type: RecordType.expense,
                moneyMinor: BigInt.from(1200),
                recordCatId: Value(srcTop.id),
                assetId: Value(walletId),
                bookId: defaultBookId,
                createDate: 1730000000000,
              ),
            );

        // 5. Seed `installment`
        final instRowId = await db
            .into(db.installments)
            .insert(
              InstallmentsCompanion.insert(
                name: '咖啡机分期',
                catId: Value(srcSubId),
                principalMinor: BigInt.from(120000),
                periods: 6,
                chargeMinor: BigInt.zero,
                chargeWay: 0,
                remainderIn: 0,
                calWay: 0,
                startDate: 1730000000000,
                assetId: walletId,
                nextPeriod: 1,
                nextPeriodDate: 1730000000000,
                bookId: defaultBookId,
                createDate: 1730000000000,
              ),
            );

        // 6. Seed `remark` with duplicate content to verify `used_times` sum
        await db
            .into(db.remarks)
            .insert(
              RemarksCompanion.insert(
                content: '常买拿铁',
                recordCatId: srcTop.id,
                usedTimes: const Value(3),
              ),
            );
        await db
            .into(db.remarks)
            .insert(
              RemarksCompanion.insert(
                content: '常买拿铁',
                recordCatId: dstTop.id,
                usedTimes: const Value(5),
              ),
            );
        await db
            .into(db.remarks)
            .insert(
              RemarksCompanion.insert(
                content: '瑞幸生椰',
                recordCatId: srcSubId,
                usedTimes: const Value(2),
              ),
            );

        final migCmd = cmd();
        final migRes = await catTransfer.migrateCategoryBills(
          commandId: migCmd,
          sourceCategoryId: srcTop.id,
          targetCategoryId: dstTop.id,
          includeSubcategories: true,
          deleteSourceAfterMigrate: true,
        );

        expect(migRes.migratedRecordCount, 2);
        expect(migRes.migratedBudgetCount, 1);
        expect(migRes.migratedPeriodCount, 1);
        expect(migRes.migratedTemplateCount, 1);
        expect(migRes.migratedInstallmentCount, 1);
        expect(migRes.migratedRemarkCount, 2);
        expect(migRes.deletedCategoryCount, 2);

        // Verify records updated without changing wallet balance
        expect((await loadRecord(r1))!.recordCatId, dstTop.id);
        expect((await loadRecord(r2))!.recordCatId, dstTop.id);
        expect((await loadAsset(walletId)).balanceMinor, BigInt.from(45700));

        // Verify budget uniqueness + R7 total budget bump
        final budgets = await db.select(db.budgets).get();
        expect(budgets, hasLength(2));
        final dstBudget = budgets.singleWhere(
          (b) => b.budgetType == BudgetTypeCode.expenseCategory,
        );
        final totalBudget = budgets.singleWhere(
          (b) => b.budgetType == BudgetTypeCode.total,
        );
        expect(dstBudget.recordCatId, dstTop.id);
        expect(dstBudget.amountMinor, BigInt.from(55000));
        expect(totalBudget.amountMinor, BigInt.from(55000));

        // Verify period, template, installment, remarks, and deleted categories
        final pRow = await (db.select(
          db.recordPeriods,
        )..where((t) => t.id.equals(periodRowId))).getSingle();
        expect(pRow.catId, dstTop.id);

        final tRow = await (db.select(
          db.recordTemplates,
        )..where((t) => t.id.equals(201))).getSingle();
        expect(tRow.recordCatId, dstTop.id);

        final iRow = await (db.select(
          db.installments,
        )..where((t) => t.id.equals(instRowId))).getSingle();
        expect(iRow.catId, dstTop.id);

        final remarks = await db.select(db.remarks).get();
        expect(remarks, hasLength(2));
        expect(remarks.singleWhere((r) => r.content == '常买拿铁').usedTimes, 8);
        expect(remarks.every((r) => r.recordCatId == dstTop.id), isTrue);

        final remainingSrc = await (db.select(
          db.recordCategories,
        )..where((t) => t.id.isIn([srcTop.id, srcSubId]))).get();
        expect(remainingSrc, isEmpty);

        // Idempotent retry returns identical counts even after source was deleted
        final retry = await catTransfer.migrateCategoryBills(
          commandId: migCmd,
          sourceCategoryId: srcTop.id,
          targetCategoryId: dstTop.id,
          includeSubcategories: true,
          deleteSourceAfterMigrate: true,
        );
        expect(retry.migratedRecordCount, 2);
        expect(retry.deletedCategoryCount, 2);
      },
    );
  });

  group('BatchRecordService (F-025)', () {
    test(
      'batchEdit updates category, funding account (netEffects exact conservation), tags, flags, and date',
      () async {
        final cats = await queries.watchCategories(defaultBookId).first;
        final catFood = cats.firstWhere((c) => c.type == 0 && c.name == '餐饮');
        final catShop = cats.firstWhere((c) => c.type == 0 && c.name == '购物');
        final catSalary = cats.firstWhere((c) => c.type == 1 && c.name == '工资');

        final assetA = await ledger.createAsset(
          commandId: cmd(),
          name: '微信钱包',
          initial: m('1000.00'),
        );
        final assetB = await ledger.createAsset(
          commandId: cmd(),
          name: '招商储蓄卡',
          initial: m('2000.00'),
        );
        final assetUsd = await ledger.createAsset(
          commandId: cmd(),
          name: '美元卡',
          initial: m('500.00', 'USD'),
          currency: 'USD',
        );

        final tagA = await catalog.createTag(commandId: cmd(), name: '日常');
        final tagB = await catalog.createTag(commandId: cmd(), name: '公司');

        // Expense 100 on assetA with refund child 30 on assetA
        final expId = await ledger.saveRecord(
          commandId: cmd(),
          draft: RecordDraft(
            type: RecordType.expense,
            money: m('100.00'),
            recordTime: DateTime(2026, 5, 1, 12, 30, 15).millisecondsSinceEpoch,
            bookId: defaultBookId,
            categoryId: catFood.id,
            assetId: assetA,
            tagIds: [tagA],
          ),
        );
        final refundId = await ledger.addRefund(
          commandId: cmd(),
          originId: expId,
          amount: m('30.00'),
          assetId: assetA,
          recordTime: DateTime(2026, 5, 2, 10, 0).millisecondsSinceEpoch,
        );

        // Reimbursable 200 on assetA (stored in `from_asset_id`!)
        final reimbId = await ledger.saveRecord(
          commandId: cmd(),
          draft: RecordDraft(
            type: RecordType.reimbursable,
            money: m('200.00'),
            recordTime: DateTime(2026, 5, 1, 18, 45, 0).millisecondsSinceEpoch,
            bookId: defaultBookId,
            categoryId: catFood.id,
            fromAssetId: assetA,
          ),
        );

        // Balance before batch edit: assetA = 1000 - 100 + 30 - 200 = 730.00; assetB = 2000.00
        expect((await loadAsset(assetA)).balanceMinor, BigInt.from(73000));
        expect((await loadAsset(assetB)).balanceMinor, BigInt.from(200000));

        // Guard: selecting refund child directly is rejected
        expect(
          () => batchService.batchEdit(
            commandId: cmd(),
            recordIds: [refundId],
            patch: BatchEditPatch(excludeBudget: true),
          ),
          _fails(FailureCode.validation),
        );

        // Guard: assigning income category to expense records is rejected
        expect(
          () => batchService.batchEdit(
            commandId: cmd(),
            recordIds: [expId, reimbId],
            patch: BatchEditPatch(targetCategoryId: catSalary.id),
          ),
          _fails(FailureCode.validation),
        );

        // Guard: moving CNY bills to USD account is rejected
        expect(
          () => batchService.batchEdit(
            commandId: cmd(),
            recordIds: [expId],
            patch: BatchEditPatch(targetAssetId: assetUsd),
          ),
          _fails(FailureCode.validation),
        );

        // Execute atomic batch edit on [expId, reimbId] -> catShop, assetB, 2026-05-10, +tagB/-tagA, excludeBudget=true
        final editCmd = cmd();
        final patch = BatchEditPatch(
          targetCategoryId: catShop.id,
          targetAssetId: assetB,
          shiftToDate: DateTime(2026, 5, 10),
          addTagIds: {tagB},
          removeTagIds: {tagA},
          excludeBudget: true,
        );
        final res = await batchService.batchEdit(
          commandId: editCmd,
          recordIds: [expId, reimbId],
          patch: patch,
        );

        expect(res.updatedRecordCount, 2);
        expect(
          res.updatedChildCount,
          1,
        ); // refund child category + excludeBudget synced

        // Verify exact balance conservation:
        // exp (100) + reimb (200) moved from assetA to assetB; refund (+30) stayed on assetA!
        // assetA = 730 + 300 = 1030.00 (1000 initial + 30 refund); assetB = 2000 - 300 = 1700.00
        expect((await loadAsset(assetA)).balanceMinor, BigInt.from(103000));
        expect((await loadAsset(assetB)).balanceMinor, BigInt.from(170000));
        expect((await loadAsset(assetB)).usedTimes, greaterThan(0));

        final expAfter = (await loadRecord(expId))!;
        final reimbAfter = (await loadRecord(reimbId))!;
        final refundAfter = (await loadRecord(refundId))!;

        expect(expAfter.recordCatId, catShop.id);
        expect(expAfter.assetId, assetB);
        expect(expAfter.excludeBudget, isTrue);
        expect(
          DateTime.fromMillisecondsSinceEpoch(expAfter.recordTime),
          DateTime(2026, 5, 10, 12, 30, 15),
        );

        expect(reimbAfter.recordCatId, catShop.id);
        expect(reimbAfter.fromAssetId, assetB);
        expect(reimbAfter.assetId, noRef);
        expect(
          DateTime.fromMillisecondsSinceEpoch(reimbAfter.recordTime),
          DateTime(2026, 5, 10, 18, 45, 0),
        );

        expect(refundAfter.recordCatId, catShop.id);
        expect(refundAfter.excludeBudget, isTrue);

        final expTags = await (db.select(
          db.tagRecords,
        )..where((t) => t.recordId.equals(expId))).get();
        expect(expTags.map((t) => t.tagId).toList(), [tagB]);

        // Idempotent retry does NOT double-deduct assetB!
        final retry = await batchService.batchEdit(
          commandId: editCmd,
          recordIds: [expId, reimbId],
          patch: patch,
        );
        expect(retry.updatedRecordCount, 2);
        expect((await loadAsset(assetB)).balanceMinor, BigInt.from(170000));
      },
    );

    test(
      'batchEdit targetBookId moves linked children and maps/creates categories so zero cross-book orphans exist',
      () async {
        final book2Id = await catalog.createBook(
          commandId: cmd(),
          name: '差旅账本',
        );
        final book1Cats = await queries.watchCategories(defaultBookId).first;
        final book1Food = book1Cats.firstWhere(
          (c) => c.type == 0 && c.name == '餐饮',
        );

        final customTop = await catalog.createCategory(
          commandId: cmd(),
          accountBookId: defaultBookId,
          name: '差旅住宿',
          type: 0,
        );
        final customSub = await catalog.createCategory(
          commandId: cmd(),
          accountBookId: defaultBookId,
          name: '商务酒店',
          type: 0,
          parentCatId: customTop,
        );

        final cardA = await ledger.createAsset(
          commandId: cmd(),
          name: '银行卡A',
          initial: m('5000.00'),
        );
        final cardB = await ledger.createAsset(
          commandId: cmd(),
          name: '银行卡B',
          initial: m('1000.00'),
        );

        // 1. Expense with preset category '餐饮' + refund child
        final rFood = await ledger.saveRecord(
          commandId: cmd(),
          draft: RecordDraft(
            type: RecordType.expense,
            money: m('80.00'),
            recordTime: 1730000000000,
            bookId: defaultBookId,
            categoryId: book1Food.id,
            assetId: cardA,
          ),
        );
        final rFoodRefund = await ledger.addRefund(
          commandId: cmd(),
          originId: rFood,
          amount: m('20.00'),
          assetId: cardA,
          recordTime: 1730000050000,
        );

        // 2. Reimbursable with custom 2-level category + reimbursement receipt child
        final rHotel = await ledger.saveRecord(
          commandId: cmd(),
          draft: RecordDraft(
            type: RecordType.reimbursable,
            money: m('450.00'),
            recordTime: 1730000100000,
            bookId: defaultBookId,
            categoryId: customSub,
            fromAssetId: cardA,
          ),
        );
        final rHotelReceipt = await ledger.addReimbursement(
          commandId: cmd(),
          originId: rHotel,
          amount: m('450.00'),
          assetId: cardB,
          recordTime: 1730000200000,
        );

        // 3. Transfer with fee child
        final rTransfer = await ledger.saveRecord(
          commandId: cmd(),
          draft: RecordDraft(
            type: RecordType.transfer,
            money: m('300.00'),
            fee: m('2.00'),
            recordTime: 1730000300000,
            bookId: defaultBookId,
            fromAssetId: cardA,
            toAssetId: cardB,
          ),
        );

        // Guard: when createMissingTargetCategories == false, moving customSub fails cleanly
        expect(
          () => batchService.batchEdit(
            commandId: cmd(),
            recordIds: [rFood, rHotel, rTransfer],
            patch: BatchEditPatch(
              targetBookId: book2Id,
              createMissingTargetCategories: false,
            ),
          ),
          _fails(FailureCode.validation),
        );

        // Guard: settled advance cannot be batch-edited
        final advId = await ledger.saveRecord(
          commandId: cmd(),
          draft: RecordDraft(
            type: RecordType.advanceExpense,
            money: m('100.00'),
            recordTime: 1730000400000,
            bookId: defaultBookId,
            categoryId: book1Food.id,
            assetId: cardA,
          ),
        );
        await ledger.settleAdvance(
          commandId: cmd(),
          originId: advId,
          amount: m('100.00'),
          assetId: cardA,
          recordTime: 1730000500000,
        );
        expect(
          () => batchService.batchEdit(
            commandId: cmd(),
            recordIds: [advId],
            patch: BatchEditPatch(targetBookId: book2Id),
          ),
          _fails(FailureCode.validation),
        );

        // Move [rFood, rHotel, rTransfer] to book2Id with auto category mapping/creation
        final moveRes = await batchService.batchEdit(
          commandId: cmd(),
          recordIds: [rFood, rHotel, rTransfer],
          patch: BatchEditPatch(targetBookId: book2Id),
        );

        expect(moveRes.updatedRecordCount, 3);
        expect(
          moveRes.updatedChildCount,
          3,
        ); // refund + reimburseReceipt + transferFee
        expect(
          moveRes.createdTargetCategoryCount,
          2,
        ); // '差旅住宿' + '商务酒店' created in Book 2

        final book2Cats = await queries.watchCategories(book2Id).first;
        final book2CatIds = {for (final c in book2Cats) c.id};

        // Every moved record & child is now in book2Id AND its category belongs to book2Id (or is -1)!
        final movedFood = (await loadRecord(rFood))!;
        final movedRefund = (await loadRecord(rFoodRefund))!;
        final movedHotel = (await loadRecord(rHotel))!;
        final movedReceipt = (await loadRecord(rHotelReceipt))!;
        final movedTransfer = (await loadRecord(rTransfer))!;

        for (final row in [
          movedFood,
          movedRefund,
          movedHotel,
          movedReceipt,
          movedTransfer,
        ]) {
          expect(row.accountBookId, book2Id);
          if (row.recordCatId != noRef) {
            expect(book2CatIds.contains(row.recordCatId), isTrue);
          }
        }
        expect(movedRefund.recordCatId, movedFood.recordCatId);

        // Transfer fee child also moved to book2Id
        final feeChild = (await db.select(db.records).get()).singleWhere(
          (r) =>
              r.type == RecordType.fee &&
              RecordRelations.parse(r.relInfo).transferFee?.parentId ==
                  rTransfer,
        );
        expect(feeChild.accountBookId, book2Id);
      },
    );

    test(
      'batchDelete deduplicates parent+child selection, unlinks surviving origins, reverses netEffects, and recomputes debt principal',
      () async {
        final cats = await queries.watchCategories(defaultBookId).first;
        final catFood = cats.firstWhere((c) => c.type == 0 && c.name == '餐饮');

        final bank = await ledger.createAsset(
          commandId: cmd(),
          name: '建设银行',
          initial: m('1000.00'),
        );
        final cash = await ledger.createAsset(
          commandId: cmd(),
          name: '现金账户',
          initial: m('500.00'),
        );

        // Case A: Origin expense (100) + refund child (25) BOTH selected -> must reverse net -75 once!
        final expA = await ledger.saveRecord(
          commandId: cmd(),
          draft: RecordDraft(
            type: RecordType.expense,
            money: m('100.00'),
            recordTime: 1730000000000,
            bookId: defaultBookId,
            categoryId: catFood.id,
            assetId: bank,
          ),
        );
        final refundA = await ledger.addRefund(
          commandId: cmd(),
          originId: expA,
          amount: m('25.00'),
          assetId: bank,
          recordTime: 1730000010000,
        );

        // Case B: Origin expense (200) survives while ONLY its refund child (40) is batch-deleted -> origin rel_info unlinked!
        final expB = await ledger.saveRecord(
          commandId: cmd(),
          draft: RecordDraft(
            type: RecordType.expense,
            money: m('200.00'),
            recordTime: 1730000020000,
            bookId: defaultBookId,
            categoryId: catFood.id,
            assetId: bank,
          ),
        );
        final refundB = await ledger.addRefund(
          commandId: cmd(),
          originId: expB,
          amount: m('40.00'),
          assetId: bank,
          recordTime: 1730000030000,
        );

        // Case C: Transfer 150 from bank -> cash with fee 3 on bank
        final trC = await ledger.saveRecord(
          commandId: cmd(),
          draft: RecordDraft(
            type: RecordType.transfer,
            money: m('150.00'),
            fee: m('3.00'),
            recordTime: 1730000040000,
            bookId: defaultBookId,
            fromAssetId: bank,
            toAssetId: cash,
          ),
        );

        // Case D: Borrowing project (principal 300 into bank) + repayment 120 from bank
        final debtId = await debt.createDebt(
          commandId: cmd(),
          subType: AssetType.debtBorrow,
          name: '朋友周转',
          principal: m('300.00'),
          bookId: defaultBookId,
          startDate: 1730000100000,
          fundingAssetId: bank,
        );
        final repayId = await debt.recordRepayment(
          commandId: cmd(),
          debtId: debtId,
          principal: m('120.00'),
          operateDate: 1730000200000,
          bookId: defaultBookId,
          fundingAssetId: bank,
        );

        // Verify balances before batchDelete:
        // bank = 1000 - 100 + 25 - 200 + 40 - 150 - 3 + 300 - 120 = 792.00
        // cash = 500 + 150 = 650.00
        // debt = 180.00 remaining principal (18000 minor)
        expect((await loadAsset(bank)).balanceMinor, BigInt.from(79200));
        expect((await loadAsset(cash)).balanceMinor, BigInt.from(65000));
        expect((await loadAsset(debtId)).balanceMinor, BigInt.from(18000));

        // Batch delete [expA, refundA, refundB, trC, repayId] in ONE atomic command!
        final delCmd = cmd();
        final delRes = await batchService.batchDelete(
          commandId: delCmd,
          recordIds: [expA, refundA, refundB, trC, repayId],
        );
        // Primary = 5; total rows = 6 (expA, refundA, refundB, trC, trC's feeChild, repayId)
        expect(delRes.deletedPrimaryCount, 5);
        expect(delRes.deletedTotalRowCount, 6);

        // Surviving transactions on bank: ONLY expB (-200) and debt initial borrow (+300) -> 1000 - 200 + 300 = 1100.00!
        // Surviving on cash: initial 500.00!
        // Surviving on debt: initial borrow 300 -> balanceMinor = 30000!
        expect((await loadAsset(bank)).balanceMinor, BigInt.from(110000));
        expect((await loadAsset(cash)).balanceMinor, BigInt.from(50000));
        expect((await loadAsset(debtId)).balanceMinor, BigInt.from(30000));

        // Surviving expB has refundB cleanly unlinked from `rel_info`
        final survivingExpB = (await loadRecord(expB))!;
        expect(
          RecordRelations.parse(survivingExpB.relInfo).refunds?.children ??
              const [],
          isEmpty,
        );

        // Idempotent retry returns cached result without failing on already-deleted rows
        final retry = await batchService.batchDelete(
          commandId: delCmd,
          recordIds: [expA, refundA, refundB, trC, repayId],
        );
        expect(retry.deletedTotalRowCount, 6);
        expect((await loadAsset(bank)).balanceMinor, BigInt.from(110000));
      },
    );
  });

  group('BillAttachmentService & DIY / Location / .tally Backup (F-022 & F-036)', () {
    test(
      'saves attachments in <support>/attachments, packs into .tally backup, and cleans orphans safely',
      () async {
        final cats = await queries.watchCategories(defaultBookId).first;
        final catFood = cats.firstWhere((c) => c.type == 0 && c.name == '餐饮');

        final recId = await ledger.saveRecord(
          commandId: cmd(),
          draft: RecordDraft(
            type: RecordType.expense,
            money: m('42.00'),
            recordTime: 1730000000000,
            bookId: defaultBookId,
            categoryId: catFood.id,
          ),
        );

        final savedBillImg = await attService.saveImageBytes(
          bytes: _samplePngBytes,
          originalName: 'receipt.png',
        );
        expect(savedBillImg, endsWith('.png'));

        // Save a second image referenced ONLY by `record_period`, and a third unreferenced orphan image
        final periodImgBytes = Uint8List.fromList([..._samplePngBytes, 0x01]);
        final orphanImgBytes = Uint8List.fromList([..._samplePngBytes, 0x02]);
        final periodImg = await attService.saveImageBytes(
          bytes: periodImgBytes,
        );
        final orphanImg = await attService.saveImageBytes(
          bytes: orphanImgBytes,
        );

        await db
            .into(db.recordPeriods)
            .insert(
              RecordPeriodsCompanion.insert(
                recordType: RecordType.expense,
                moneyMinor: BigInt.from(1000),
                catId: Value(catFood.id),
                bookId: defaultBookId,
                images: Value(periodImg),
                periodType: 2,
                periodTypeDate: '1',
                periodStartDate: 1730000000000,
                periodEndDate: -1,
                createTime: 1730000000000,
              ),
            );

        // Bind savedBillImg to recId
        final setRes = await attService.setRecordImages(
          commandId: cmd(),
          recordId: recId,
          imageNames: [savedBillImg],
        );
        expect(setRes, [savedBillImg]);

        // Reject path traversal & >9 images in setRecordImages
        expect(
          () => attService.setRecordImages(
            commandId: cmd(),
            recordId: recId,
            imageNames: ['../hack.png'],
          ),
          _fails(FailureCode.validation),
        );
        expect(
          () => attService.setRecordImages(
            commandId: cmd(),
            recordId: recId,
            imageNames: [for (var i = 0; i < 10; i++) 'img_$i.png'],
          ),
          _fails(FailureCode.validation),
        );

        // Verify .tally backup includes our `<support>/attachments/` files under `attachments/<name>`!
        final scheduler = InMemoryReminderScheduler();
        addTearDown(scheduler.dispose);
        final reminderSvc = ReminderService(db, scheduler: scheduler);
        final backupSvc = TallyBackupService(
          db,
          reminderService: reminderSvc,
          localBackupsDirectoryProvider: () async => backupDir,
          attachmentsDirectoryProvider: () async => attDir,
        );
        final packed = await backupSvc.createBackupBytes(
          includeAttachments: true,
        );
        final zip = ZipArchive.decode(packed.bytes);
        final attEntry = zip['attachments/$savedBillImg'];
        expect(attEntry, isNotNull);
        expect(attEntry!.bytes, _samplePngBytes);

        // Scan & clean orphans: periodImg and savedBillImg MUST stay; ONLY orphanImg is deleted!
        final scanBefore = await attService.scanOrphanAttachments();
        expect(scanBefore.referencedCount, 2);
        expect(scanBefore.orphanFileNames, [orphanImg]);

        final cleanCmd = cmd();
        final cleaned = await attService.cleanupOrphanAttachments(
          commandId: cleanCmd,
        );
        expect(cleaned.deletedFileNames, [orphanImg]);
        expect(cleaned.freedBytes, orphanImgBytes.length);
        expect(
          await attService.readAttachmentBytes(savedBillImg),
          _samplePngBytes,
        );
        expect(await attService.readAttachmentBytes(periodImg), periodImgBytes);
        expect(await attService.readAttachmentBytes(orphanImg), isNull);

        // Idempotent retry returns identical cleanup result
        final retryClean = await attService.cleanupOrphanAttachments(
          commandId: cleanCmd,
        );
        expect(retryClean.deletedFileNames, [orphanImg]);
      },
    );

    test(
      'persists DiyToolbarConfig in ti_preference and updates record.extra_info.loc safely',
      () async {
        // Default DIY toolbar config emitted initially (frequentRemarks defaults OFF)
        final initial = await attService.getDiyToolbarConfig();
        expect(initial.isEnabled(DiyToolbarAction.frequentRemarks), isFalse);
        expect(
          initial.visibleActions,
          DiyToolbarAction.values.where((a) => a.defaultEnabled).toList(),
        );

        final custom = initial
            .setEnabled(DiyToolbarAction.currency, false)
            .moveItem(3, 0);
        final saveCmd = cmd();
        final saved = await attService.saveDiyToolbarConfig(
          commandId: saveCmd,
          config: custom,
        );
        expect(saved.items.first.action, DiyToolbarAction.location);
        expect(saved.isEnabled(DiyToolbarAction.currency), isFalse);

        final streamed = await attService.watchDiyToolbarConfig().first;
        expect(streamed.items, custom.items);

        // Location write preserves `curr` on multi-currency record
        final cats = await queries.watchCategories(defaultBookId).first;
        final catFood = cats.firstWhere((c) => c.type == 0 && c.name == '餐饮');
        final fxExtra = RecordExtra()
          ..currency = CurrencySnapshot(
            sourceCode: 'JPY',
            sourceGross: BigInt.from(150000),
            assetCode: 'CNY',
          );
        final recId = await ledger.saveRecord(
          commandId: cmd(),
          draft: RecordDraft(
            type: RecordType.expense,
            money: m('72.00'),
            recordTime: 1730000000000,
            bookId: defaultBookId,
            categoryId: catFood.id,
            extra: fxExtra,
          ),
        );

        final loc = BillLocationInfo(
          simpleName: '东京站',
          name: 'Chiyoda, Tokyo',
          latitude: 35.6812,
          longitude: 139.7671,
        );
        await attService.setRecordLocation(
          commandId: cmd(),
          recordId: recId,
          location: loc,
        );

        final afterSet = RecordExtra.parse(
          (await loadRecord(recId))!.extraInfo,
        );
        expect(afterSet.location, loc);
        expect(afterSet.currency?.sourceCode, 'JPY');

        // Clear location
        await attService.setRecordLocation(
          commandId: cmd(),
          recordId: recId,
          location: null,
        );
        final afterClear = RecordExtra.parse(
          (await loadRecord(recId))!.extraInfo,
        );
        expect(afterClear.location, isNull);
        expect(afterClear.currency?.sourceCode, 'JPY');
      },
    );
  });
}
