import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/csv_import/csv_excel_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/db/seed.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/data/repo/import_batch_queries.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/csv_excel_codec.dart';
import 'package:tallyisle/domain/rules/csv_excel_rules.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<(AppDatabase, LedgerService, CsvExcelService, ImportBatchQueries)>
  openTestEnv() async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    return (db, LedgerService(db), CsvExcelService(db), ImportBatchQueries(db));
  }

  Future<Asset> getAsset(AppDatabase db, int id) =>
      (db.select(db.assets)..where((t) => t.id.equals(id))).getSingle();

  test(
    'commits batch atomically, auto-creates 1/2-level categories & tags, handles unknown accounts, and is idempotent',
    () async {
      final (db, ledger, csvService, batchQueries) = await openTestEnv();
      final cashId = await ledger.createAsset(
        commandId: 'mk-cash',
        name: '现金',
        initial: Money.minor(BigInt.from(100000)), // 1000.00
      );

      final csvBytes = encodeCsvBytes(const [
        csvExportHeader15,
        [
          '2026-03-15 12:00',
          '支出',
          '日常账本',
          '宠物开销', // new parent category (+1)
          '猫粮', // new sub-category (+1)
          '120.50',
          'CNY',
          '现金',
          '',
          '进口猫粮',
          '猫咪, 刚需',
          '',
          '10.00',
          '否',
          '否',
        ],
        [
          '2026-03-15 13:00',
          '支出',
          '日常账本',
          '餐饮', // existing preset category (+0)
          '',
          '35.00',
          'CNY',
          '不存在的卡', // unknown account -> assetId = -1
          '',
          '午餐',
          '',
          '',
          '',
          '否',
          '否',
        ],
        [
          '',
          '',
          '',
          '',
          '',
          '',
          '',
          '',
          '',
          '',
          '',
          '',
          '',
          '',
          '',
        ], // empty row
        [
          '2026-03-15 14:00',
          '支出',
          '日常账本',
          '餐饮',
          '',
          'bad_money', // fail row (+1 in importRecordCount)
          'CNY',
          '现金',
          '',
          '',
          '',
          '',
          '',
          '',
          '',
        ],
      ]);

      final preview = await csvService.previewImport(
        fileName: 'pet_and_lunch.csv',
        bytes: csvBytes,
        targetBookId: defaultBookId,
      );
      expect(preview.validRows, hasLength(2));
      expect(preview.failRows, hasLength(1));
      expect(preview.emptyRowCount, 1);
      expect(preview.totalRecordCount, 3); // 2 valid + 1 fail (excludes empty)
      expect(preview.unknownAssets, ['不存在的卡']);

      final committed = await csvService.commitImport(
        commandId: 'cmd-import-1',
        preview: preview,
        selectedBookId: defaultBookId,
      );
      expect(committed.importedBillCount, 2);
      expect(committed.createdCategoryCount, 2); // 宠物开销 + 猫粮

      // Replay with identical commandId + payload is idempotent (ADR-009):
      final replayed = await csvService.commitImport(
        commandId: 'cmd-import-1',
        preview: preview,
        selectedBookId: defaultBookId,
      );
      expect(replayed.batchId, committed.batchId);

      // Cash deducted only by 120.50 (unknown account row has assetId = -1)
      final cash = await getAsset(db, cashId);
      expect(
        cash.balanceMinor,
        BigInt.from(87950),
      ); // 1000.00 - 120.50 = 879.50

      final batch = await batchQueries.getBatch(committed.batchId);
      expect(batch, isNotNull);
      expect(batch!.importRecordCount, 3);
      expect(batch.importCategoryCount, 2);

      final tags = await db.select(db.tags).get();
      expect(tags.map((t) => t.name), containsAll(['猫咪', '刚需']));
    },
  );

  test(
    'ASYM-01: manually deleting an imported bill before undoBatch never double-refunds balance',
    () async {
      final (db, ledger, csvService, batchQueries) = await openTestEnv();
      final cashId = await ledger.createAsset(
        commandId: 'mk-cash-asym1',
        name: '现金',
        initial: Money.minor(BigInt.from(100000)), // 1000.00
      );

      final csvBytes = Uint8List.fromList(
        utf8.encode(
          '日期,类型,分类,金额,账户,账户2,备注\n'
          '2026-03-15 10:00,支出,餐饮,45.00,现金,,早餐\n'
          '2026-03-15 12:00,支出,餐饮,15.00,现金,,矿泉水\n',
        ),
      );
      final preview = await csvService.previewImport(
        fileName: 'asym01.csv',
        bytes: csvBytes,
      );
      final res = await csvService.commitImport(
        commandId: 'cmd-asym1-import',
        preview: preview,
        selectedBookId: defaultBookId,
      );
      expect((await getAsset(db, cashId)).balanceMinor, BigInt.from(94000));

      // Manually delete the 45.00 bill through LedgerService (refunds +45.00 -> 985.00)
      final records = await batchQueries.watchBatchRecords(res.batchId).first;
      final breakfast = records.firstWhere(
        (e) => e.record.moneyMinor == BigInt.from(4500),
      );
      await ledger.deleteRecord(
        commandId: 'del-breakfast',
        recordId: breakfast.record.recordId,
      );
      expect((await getAsset(db, cashId)).balanceMinor, BigInt.from(98500));

      final summaries = await batchQueries.watchBatches(hidden: false).first;
      expect(summaries.single.batch.importRecordCount, 2);
      expect(summaries.single.liveBillCount, 1);

      // Undo batch: ONLY the surviving 15.00 bill is reversed -> exact 1000.00!
      await csvService.undoBatch(
        commandId: 'cmd-asym1-undo',
        batchId: res.batchId,
      );
      expect((await getAsset(db, cashId)).balanceMinor, BigInt.from(100000));
      expect(await db.select(db.records).get(), isEmpty);
      expect(await db.select(db.importPlatforms).get(), isEmpty);
    },
  );

  test(
    'ASYM-02: 模板 v3 transfer fee child (type=12, parent+1ms) binds platformId and reverses symmetrically',
    () async {
      final (db, ledger, csvService, _) = await openTestEnv();
      final cardId = await ledger.createAsset(
        commandId: 'mk-card-asym2',
        name: '储蓄卡',
        initial: Money.minor(BigInt.from(200000)), // 2000.00
      );
      final cashId = await ledger.createAsset(
        commandId: 'mk-cash-asym2',
        name: '现金',
        initial: Money.minor(BigInt.from(50000)), // 500.00
      );

      final csvBytes = encodeCsvBytes(const [
        officialTemplateV3Header,
        [
          '2026-03-16 09:30',
          '转账',
          '',
          '300.00',
          '储蓄卡',
          '现金',
          '跨行取现',
          '',
          '',
          '2.50', // transfer fee!
          '',
          '',
          '',
        ],
      ]);

      final preview = await csvService.previewImport(
        fileName: 'asym02_v3.csv',
        bytes: csvBytes,
      );
      final res = await csvService.commitImport(
        commandId: 'cmd-asym2-import',
        preview: preview,
        selectedBookId: defaultBookId,
      );

      expect(
        (await getAsset(db, cardId)).balanceMinor,
        BigInt.from(169750),
      ); // 2000 - 302.50
      expect(
        (await getAsset(db, cashId)).balanceMinor,
        BigInt.from(80000),
      ); // 500 + 300.00

      final allRecords = await db.select(db.records).get();
      expect(allRecords, hasLength(2));
      final parent = allRecords.singleWhere(
        (r) => r.type == RecordType.transfer,
      );
      final feeChild = allRecords.singleWhere((r) => r.type == RecordType.fee);
      expect(parent.platformId, res.batchId);
      expect(feeChild.platformId, res.batchId);
      expect(feeChild.recordTime, parent.recordTime + 1);
      expect(feeChild.moneyMinor, BigInt.from(250));

      // Undo batch: restores full 302.50 on card, deducts 300.00 on cash, deletes fee child!
      await csvService.undoBatch(
        commandId: 'cmd-asym2-undo',
        batchId: res.batchId,
      );
      expect((await getAsset(db, cardId)).balanceMinor, BigInt.from(200000));
      expect((await getAsset(db, cashId)).balanceMinor, BigInt.from(50000));
      expect(await db.select(db.records).get(), isEmpty);
    },
  );

  test(
    'ASYM-03: cross-currency transfer & foreign-currency bill undo symmetrically using stored CurrencySnapshot',
    () async {
      final (db, ledger, csvService, _) = await openTestEnv();
      await db
          .into(db.currencies)
          .insert(
            CurrenciesCompanion.insert(
              code: 'USD',
              name: '美元',
              symbol: r'$',
              rateToAnchor: '0.125', // 1 CNY = 0.125 USD (1 USD = 8 CNY)
              anchorCode: 'CNY',
            ),
          );

      final cnyId = await ledger.createAsset(
        commandId: 'mk-cny',
        name: '人民币卡',
        initial: Money.minor(BigInt.from(100000)), // 1000.00 CNY
        currency: 'CNY',
      );
      final usdId = await ledger.createAsset(
        commandId: 'mk-usd',
        name: '美元卡',
        initial: Money.minor(BigInt.from(10000)), // 100.00 USD
        currency: 'USD',
      );

      final csvBytes = encodeCsvBytes(const [
        csvExportHeader15,
        [
          '2026-03-17 10:00',
          '转账',
          '日常账本',
          '',
          '',
          '800.00', // 800 CNY -> 100 USD at rateToAnchor 0.125
          'CNY',
          '人民币卡',
          '美元卡',
          '购汇',
          '',
          '',
          '',
          '',
          '',
        ],
        [
          '2026-03-17 11:00',
          '支出',
          '日常账本',
          '购物',
          '',
          '10.00', // 10 USD -> 80 CNY deducted from 人民币卡
          'USD',
          '人民币卡',
          '',
          '海外订阅',
          '',
          '',
          '',
          '',
          '',
        ],
      ]);

      final preview = await csvService.previewImport(
        fileName: 'asym03_fx.csv',
        bytes: csvBytes,
      );
      final res = await csvService.commitImport(
        commandId: 'cmd-asym3-import',
        preview: preview,
        selectedBookId: defaultBookId,
      );

      expect(
        (await getAsset(db, cnyId)).balanceMinor,
        BigInt.from(12000),
      ); // 1000 - 800 - 80 = 120 CNY
      expect(
        (await getAsset(db, usdId)).balanceMinor,
        BigInt.from(20000),
      ); // 100 + 100 = 200 USD

      // Mutate live exchange rate to 0.1 (1 USD = 10 CNY) before undo to prove CurrencySnapshot is used!
      await (db.update(db.currencies)..where((t) => t.code.equals('USD')))
          .write(const CurrenciesCompanion(rateToAnchor: Value('0.1')));

      await csvService.undoBatch(
        commandId: 'cmd-asym3-undo',
        batchId: res.batchId,
      );
      expect((await getAsset(db, cnyId)).balanceMinor, BigInt.from(100000));
      expect((await getAsset(db, usdId)).balanceMinor, BigInt.from(10000));
    },
  );

  test(
    'preserves manual twin bills (platform_id = -1), other batches, and created categories on undo, plus batch hiding',
    () async {
      final (db, ledger, csvService, batchQueries) = await openTestEnv();
      final cashId = await ledger.createAsset(
        commandId: 'mk-cash-twin',
        name: '现金',
        initial: Money.minor(BigInt.from(50000)), // 500.00
      );
      final foodCat = await (db.select(
        db.recordCategories,
      )..where((t) => t.name.equals('餐饮'))).getSingle();

      final sameTime = DateTime(2026, 3, 18, 12, 30).millisecondsSinceEpoch;
      final manualId = await ledger.saveRecord(
        commandId: 'manual-twin',
        draft: RecordDraft(
          type: RecordType.expense,
          money: Money.minor(BigInt.from(2500)),
          bookId: defaultBookId,
          recordTime: sameTime,
          categoryId: foodCat.id,
          assetId: cashId,
          remark: '手动双胞胎账单',
        ),
      );

      final csvBytes = Uint8List.fromList(
        utf8.encode(
          '日期,类型,分类,金额,账户,账户2,备注\n'
          '2026-03-18 12:30,支出,导入专属分类,25.00,现金,,手动双胞胎账单\n',
        ),
      );
      final preview = await csvService.previewImport(
        fileName: 'twin.csv',
        bytes: csvBytes,
        targetBookId: defaultBookId,
      );
      // Duplicate hint detects same time + type + moneyMinor without blocking!
      expect(preview.possibleDuplicateCount, 1);

      final batch1 = await csvService.commitImport(
        commandId: 'cmd-twin-b1',
        preview: preview,
        selectedBookId: defaultBookId,
      );
      final batch2 = await csvService.commitImport(
        commandId: 'cmd-twin-b2',
        preview: preview,
        selectedBookId: defaultBookId,
      );
      expect(
        (await getAsset(db, cashId)).balanceMinor,
        BigInt.from(42500),
      ); // 500 - 25*3

      // Test hide / unhide
      await csvService.setBatchHidden(
        commandId: 'hide-b2',
        batchId: batch2.batchId,
        hidden: true,
      );
      expect(
        (await batchQueries.watchBatches(hidden: false).first),
        hasLength(1),
      );
      expect(
        (await batchQueries.watchBatches(hidden: true).first),
        hasLength(1),
      );

      // Undo batch 1: manual twin and batch 2 survive, auto-created category survives!
      await csvService.undoBatch(commandId: 'undo-b1', batchId: batch1.batchId);
      expect(
        (await getAsset(db, cashId)).balanceMinor,
        BigInt.from(45000),
      ); // 500 - 25*2

      final remainingRecords = await db.select(db.records).get();
      expect(remainingRecords, hasLength(2));
      expect(
        remainingRecords.any(
          (r) => r.recordId == manualId && r.platformId == noRef,
        ),
        isTrue,
      );
      expect(
        remainingRecords.any((r) => r.platformId == batch2.batchId),
        isTrue,
      );

      final customCat = await (db.select(
        db.recordCategories,
      )..where((t) => t.name.equals('导入专属分类'))).getSingleOrNull();
      expect(customCat, isNotNull);
    },
  );

  test(
    'exports 15-col UTF-8 & 14-col GBK CSV and round-trips with restoreFileBooks true vs false',
    () async {
      final (db1, ledger1, csv1, _) = await openTestEnv();
      final card1 = await ledger1.createAsset(
        commandId: 'c1',
        name: '储蓄卡',
        initial: Money.minor(BigInt.from(100000)),
      );
      final cash1 = await ledger1.createAsset(
        commandId: 'c2',
        name: '现金',
        initial: Money.minor(BigInt.zero),
      );

      // Create a second book in db1 via importing with restoreFileBooks: true
      final seedCsv = encodeCsvBytes(const [
        csvExportHeader15,
        [
          '2026-03-20 09:00',
          '支出',
          '旅行账本',
          '餐饮',
          '特色小吃',
          '68.00',
          'CNY',
          '储蓄卡',
          '',
          '第一行\n第二行',
          '旅行',
          '',
          '2.00',
          '是',
          '否',
        ],
        [
          '2026-03-20 10:00',
          '转账',
          '日常账本',
          '',
          '',
          '200.00',
          'CNY',
          '储蓄卡',
          '现金',
          '备用金',
          '',
          '1.00',
          '',
          '否',
          '否',
        ],
      ]);
      final seedPreview = await csv1.previewImport(
        fileName: 'seed.csv',
        bytes: seedCsv,
      );
      final seedRes = await csv1.commitImport(
        commandId: 'seed-commit',
        preview: seedPreview,
        selectedBookId: defaultBookId,
        restoreFileBooks: true,
      );
      expect(seedRes.createdBookCount, 1);

      // Export 15-col UTF-8+BOM & 14-col GBK
      final exp15 = await csv1.exportCsv(
        includeCurrency: true,
        utf8WithBom: true,
      );
      expect(exp15.exportedCount, 2);
      final exp14Gbk = await csv1.exportCsv(
        includeCurrency: false,
        utf8WithBom: false,
      );
      expect(decodeSmartText(exp14Gbk.bytes).encoding, CsvTextEncoding.gbk);

      // Round-trip into db2 with restoreFileBooks: true (auto-creates 旅行账本)
      final (db2, ledger2, csv2, _) = await openTestEnv();
      await ledger2.createAsset(
        commandId: 'c1',
        name: '储蓄卡',
        initial: Money.minor(BigInt.from(100000)),
      );
      await ledger2.createAsset(
        commandId: 'c2',
        name: '现金',
        initial: Money.minor(BigInt.zero),
      );
      final p2 = await csv2.previewImport(
        fileName: exp15.suggestedFileName,
        bytes: exp15.bytes,
      );
      final r2 = await csv2.commitImport(
        commandId: 'rt-restore-true',
        preview: p2,
        selectedBookId: defaultBookId,
        restoreFileBooks: true,
      );
      expect(r2.createdBookCount, 1);
      final books2 = await db2.select(db2.accountBooks).get();
      expect(books2.map((b) => b.name), containsAll(['日常账本', '旅行账本']));
      expect(
        (await getAsset(db2, card1)).balanceMinor,
        BigInt.from(73100),
      ); // 1000 - 68 - 200 - 1
      expect((await getAsset(db2, cash1)).balanceMinor, BigInt.from(20000));

      // Round-trip 14-col GBK into db3 with restoreFileBooks: false (all into 日常账本)
      final (db3, ledger3, csv3, _) = await openTestEnv();
      await ledger3.createAsset(
        commandId: 'c1',
        name: '储蓄卡',
        initial: Money.minor(BigInt.from(100000)),
      );
      await ledger3.createAsset(
        commandId: 'c2',
        name: '现金',
        initial: Money.minor(BigInt.zero),
      );
      final p3 = await csv3.previewImport(
        fileName: 'exp14_gbk.csv',
        bytes: exp14Gbk.bytes,
      );
      final r3 = await csv3.commitImport(
        commandId: 'rt-restore-false',
        preview: p3,
        selectedBookId: defaultBookId,
        restoreFileBooks: false,
      );
      expect(r3.createdBookCount, 0);
      final books3 = await db3.select(db3.accountBooks).get();
      expect(books3, hasLength(1));
      final recs3 = await db3.select(db3.records).get();
      final snackRec = recs3.singleWhere((r) => r.type == RecordType.expense);
      expect(snackRec.remark, '第一行\n第二行');
    },
  );
}
