import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/db/seed.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/csv_excel_codec.dart';
import 'package:tallyisle/domain/rules/csv_excel_rules.dart';
import 'package:tallyisle/features/csv_transfer/csv_export_page.dart';
import 'package:tallyisle/features/csv_transfer/csv_import_page.dart';
import 'package:tallyisle/platform/files.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Widget buildApp(Widget child, AppDatabase db) => ProviderScope(
    retry: (_, _) => null,
    overrides: [databaseProvider.overrideWith((ref) async => db)],
    child: MaterialApp(home: child),
  );

  (AppDatabase, Future<void> Function()) openTestDb(WidgetTester tester) {
    final db = AppDatabase(NativeDatabase.memory());
    var closed = false;
    addTearDown(() async {
      if (!closed) {
        closed = true;
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(db.close);
      }
    });
    Future<void> closeCleanly() async {
      if (closed) return;
      closed = true;
      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      await tester.pump(const Duration(seconds: 5));
      await tester.runAsync(db.close);
    }

    return (db, closeCleanly);
  }

  testWidgets(
    'End-to-end CSV import preview -> auto-create book -> batch detail -> hide/unhide -> batch undo',
    (tester) async {
      final (db, closeCleanly) = openTestDb(tester);

      final ledger = LedgerService(db);
      final cashId = (await tester.runAsync(
        () => ledger.createAsset(
          commandId: 'seed-cash',
          name: '现金',
          initial: Money.minor(BigInt.from(100000)), // 1000.00
        ),
      ))!;

      final csvBytes = encodeCsvBytes(const [
        csvExportHeader15,
        [
          '2026-03-18 12:00',
          '支出',
          '日常账本',
          '餐饮',
          '',
          '40.00',
          'CNY',
          '现金',
          '',
          '工作餐',
          '',
          '',
          '',
          '否',
          '否',
        ],
        [
          '2026-03-18 18:00',
          '支出',
          '副业账本',
          '办公',
          '',
          '25.00',
          'CNY',
          '未知零钱包',
          '',
          '打印资料',
          '',
          '',
          '',
          '否',
          '否',
        ],
        [
          '2026-03-18 19:00',
          '支出',
          '日常账本',
          '餐饮',
          '',
          'invalid_amount',
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

      await tester.pumpWidget(
        buildApp(
          CsvImportPage(
            pickFile: () async => SelectedBytes('march_bills.csv', csvBytes),
          ),
          db,
        ),
      );
      await settle(tester);

      expect(find.byKey(const Key('csv_import_page')), findsOneWidget);

      // Pick file and verify preview
      await tester.tap(find.byKey(const Key('pick_import_file_button')));
      await settle(tester);

      expect(find.byKey(const Key('import_preview_card')), findsOneWidget);
      expect(find.textContaining('有效账单 2 条'), findsOneWidget);
      expect(find.textContaining('失败行 1 条'), findsOneWidget);
      expect(find.byKey(const Key('unknown_assets_banner')), findsOneWidget);
      expect(
        find.byKey(const Key('restore_file_books_switch')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('import_fail_rows_section')), findsOneWidget);

      // Scroll to & tap Confirm Import
      final confirmBtn = find.byKey(const Key('confirm_import_button'));
      await tester.ensureVisible(confirmBtn);
      await settle(tester);
      await tester.tap(confirmBtn);
      await settle(tester);

      // Verify cash balance deducted (-40.00 -> 960.00) & 副业账本 created
      final cashAfterImport = await tester.runAsync(
        () => (db.select(
          db.assets,
        )..where((t) => t.id.equals(cashId))).getSingle(),
      );
      expect(cashAfterImport!.balanceMinor, BigInt.from(96000));

      final allBooks = await tester.runAsync(
        () => db.select(db.accountBooks).get(),
      );
      expect(allBooks!.map((b) => b.name), containsAll(['日常账本', '副业账本']));

      // Open Import Batches Page
      await tester.tap(find.byKey(const Key('open_import_batches_button')));
      await settle(tester);

      expect(find.byKey(const Key('import_batches_page')), findsOneWidget);
      final batches = await tester.runAsync(
        () => db.select(db.importPlatforms).get(),
      );
      final batchId = batches!.single.id;

      // Tap batch card to inspect ImportBatchDetailPage
      await tester.tap(find.byKey(Key('import_batch_card_$batchId')));
      await settle(tester);
      expect(find.byKey(const Key('import_batch_detail_page')), findsOneWidget);
      expect(find.textContaining('工作餐'), findsOneWidget);
      expect(find.textContaining('打印资料'), findsOneWidget);

      // Pop back to ImportBatchesPage
      await tester.tap(find.byType(BackButton));
      await settle(tester);

      // Hide batch -> switch to Hidden tab -> unhide -> back to Visible tab
      await tester.tap(find.byKey(Key('toggle_hide_batch_$batchId')));
      await settle(tester);
      expect(find.text('暂无导入批次记录'), findsOneWidget);

      await tester.tap(find.byKey(const Key('hidden_batches_tab')));
      await settle(tester);
      expect(find.byKey(Key('import_batch_card_$batchId')), findsOneWidget);

      await tester.tap(find.byKey(Key('toggle_hide_batch_$batchId')));
      await settle(tester);

      await tester.tap(find.byKey(const Key('visible_batches_tab')));
      await settle(tester);
      expect(find.byKey(Key('import_batch_card_$batchId')), findsOneWidget);

      // Undo batch with confirmation dialog
      await tester.tap(find.byKey(Key('undo_batch_button_$batchId')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('confirm_undo_batch_button')));
      await settle(tester);

      expect(find.text('暂无导入批次记录'), findsOneWidget);
      final cashAfterUndo = await tester.runAsync(
        () => (db.select(
          db.assets,
        )..where((t) => t.id.equals(cashId))).getSingle(),
      );
      expect(cashAfterUndo!.balanceMinor, BigInt.from(100000));
      await closeCleanly();
    },
  );

  testWidgets(
    'Shows HTML-disguised .xls guidance message and saves offline template3.csv',
    (tester) async {
      final (db, closeCleanly) = openTestDb(tester);

      String? savedName;
      Uint8List? savedBytes;

      await tester.pumpWidget(
        buildApp(
          CsvImportPage(
            pickFile: () async => SelectedBytes(
              'fake.xls',
              Uint8List.fromList(
                utf8.encode('<html><body><table></table></body></html>'),
              ),
            ),
            saveFile: (name, bytes) async {
              savedName = name;
              savedBytes = bytes;
            },
          ),
          db,
        ),
      );
      await settle(tester);

      await tester.tap(find.byKey(const Key('pick_import_file_button')));
      await settle(tester);

      expect(find.byKey(const Key('import_error_banner')), findsOneWidget);
      expect(
        find.text('该文件为网页伪装表格，请用 Excel 打开后另存为标准 .xlsx 格式再导入'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('export_template_v3_button')));
      await settle(tester);

      expect(savedName, 'template3.csv');
      expect(savedBytes, isNotNull);
      expect(savedBytes!.sublist(0, 3), const [0xEF, 0xBB, 0xBF]);
      await closeCleanly();
    },
  );

  testWidgets(
    'CsvExportPage exports 15-col UTF-8+BOM and 14-col GBK RFC 4180 CSV cleanly',
    (tester) async {
      final (db, closeCleanly) = openTestDb(tester);

      final ledger = LedgerService(db);
      final cashId = (await tester.runAsync(
        () => ledger.createAsset(
          commandId: 'exp-cash',
          name: '现金',
          initial: Money.minor(BigInt.from(50000)),
        ),
      ))!;
      final foodCat = (await tester.runAsync(
        () => (db.select(
          db.recordCategories,
        )..where((t) => t.name.equals('餐饮'))).getSingle(),
      ))!;

      await tester.runAsync(
        () => ledger.saveRecord(
          commandId: 'exp-rec-1',
          draft: RecordDraft(
            type: RecordType.expense,
            money: Money.minor(BigInt.from(3650)),
            bookId: defaultBookId,
            recordTime: DateTime(2026, 3, 21, 12, 15).millisecondsSinceEpoch,
            categoryId: foodCat.id,
            assetId: cashId,
            remark: '第一行\n第二行',
          ),
        ),
      );

      final exportedFiles = <(String, Uint8List)>[];
      await tester.pumpWidget(
        buildApp(
          CsvExportPage(
            saveFile: (name, bytes) async {
              exportedFiles.add((name, bytes));
            },
          ),
          db,
        ),
      );
      await settle(tester);

      // 1. Default export: 15-col UTF-8+BOM
      await tester.tap(find.byKey(const Key('confirm_csv_export_button')));
      await settle(tester);

      expect(exportedFiles, hasLength(1));
      final utf8Decoded = decodeSmartText(exportedFiles.first.$2);
      expect(utf8Decoded.encoding, CsvTextEncoding.utf8Bom);
      expect(utf8Decoded.text, contains('"第一行\n第二行"'));
      expect(utf8Decoded.text.split('\r\n').first, contains(',币种,'));

      // 2. Toggle 14-col (no currency) + GBK encoding and export again
      await tester.tap(find.byKey(const Key('export_include_currency_switch')));
      await settle(tester);
      await tester.tap(find.text('GBK（旧版兼容）'));
      await settle(tester);
      await tester.tap(find.byKey(const Key('confirm_csv_export_button')));
      await settle(tester);

      expect(exportedFiles, hasLength(2));
      final gbkDecoded = decodeSmartText(exportedFiles[1].$2);
      expect(gbkDecoded.encoding, CsvTextEncoding.gbk);
      expect(gbkDecoded.text, contains('"第一行\n第二行"'));
      expect(gbkDecoded.text.split('\r\n').first, isNot(contains(',币种,')));
      await closeCleanly();
    },
  );
}
