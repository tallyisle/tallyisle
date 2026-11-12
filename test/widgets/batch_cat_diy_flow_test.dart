import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/catalog/catalog_queries.dart';
import 'package:tallyisle/data/catalog/catalog_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/db/seed.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/domain/ledger/record_extra.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/features/attachments/attachment_providers.dart';
import 'package:tallyisle/features/batch_edit/batch_edit_page.dart';
import 'package:tallyisle/features/category_transfer/category_transfer_page.dart';
import 'package:tallyisle/features/category_transfer/category_transfer_providers.dart';
import 'package:tallyisle/features/receipt/diy_toolbar_settings_page.dart';
import 'package:tallyisle/features/receipt/receipt_diy_providers.dart';
import 'package:tallyisle/features/receipt/record_receipt_dialog.dart';
import 'package:tallyisle/platform/files.dart';

final Uint8List _validPng = Uint8List.fromList(<int>[
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
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    for (var i = 0; i < 14; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  Future<void> unmountCleanly(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester);
    await tester.pump(const Duration(seconds: 1));
  }

  void clearSnacks(WidgetTester tester, Type pageType) {
    final matches = find.byType(pageType).evaluate();
    if (matches.isNotEmpty) {
      ScaffoldMessenger.of(matches.first).clearSnackBars();
    }
  }

  testWidgets(
    'CategoryTransferPage exports/imports JSON, copies across books, and migrates category bills',
    (tester) async {
      late final AppDatabase db;
      await tester.runAsync(() async {
        db = AppDatabase(NativeDatabase.memory());
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(db.close);
      });

      final catalog = CatalogService(db);
      final queries = CatalogQueries(db);
      final ledger = LedgerService(db);

      int book2Id = 0;
      await tester.runAsync(() async {
        book2Id = await catalog.createBook(
          commandId: 'w-cat-book2',
          name: '旅行账本',
        );
        await catalog.createCategory(
          commandId: 'w-cat-custom',
          accountBookId: defaultBookId,
          name: '露营装备',
          type: 0,
        );
        final cats = await queries.watchCategories(defaultBookId).first;
        final src = cats.first;
        await ledger.saveRecord(
          commandId: 'w-cat-rec1',
          draft: RecordDraft(
            type: RecordType.expense,
            money: Money.parse('36.00'),
            recordTime: DateTime(2026, 6, 1, 10).millisecondsSinceEpoch,
            bookId: defaultBookId,
            categoryId: src.id,
          ),
        );
      });

      Uint8List? exportedJsonBytes;
      final incomingPackBytes = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'format': categoryPackFormat,
            'version': 1,
            'bookName': '外部方案',
            'exportedAtMs': 1730000000000,
            'categories': [
              {
                'name': '数码配件',
                'type': 0,
                'children': [
                  {'name': '充电器', 'type': 0},
                ],
              },
            ],
          }),
        ),
      );

      final fileAccess = FileAccess(
        onSaveBytes: (name, bytes, mime) async {
          exportedJsonBytes = bytes;
        },
        onShareBytes: (name, bytes, mime, subject) async {},
        onPickBytes: (_) async => SelectedBytes('pack.json', incomingPackBytes),
      );

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            categoryTransferFileAccessProvider.overrideWithValue(fileAccess),
          ],
          child: const MaterialApp(home: CategoryTransferPage()),
        ),
      );
      await settle(tester);

      // Tab 1: Export & Import JSON
      await tester.tap(find.byKey(const Key('cat-export-save-btn')));
      await settle(tester);
      expect(exportedJsonBytes, isNotNull);
      expect(
        find.byKey(const Key('cat-transfer-status-banner')),
        findsOneWidget,
      );

      clearSnacks(tester, CategoryTransferPage);
      await tester.pump();
      await tester.drag(find.byType(ListView).first, const Offset(0, -250));
      await settle(tester);
      final importBtn = find.byKey(const Key('cat-import-pick-btn'));
      await tester.ensureVisible(importBtn);
      await settle(tester);
      await tester.tap(importBtn);
      await settle(tester);
      expect(find.text('确认导入分类方案'), findsOneWidget);
      await tester.tap(find.text('确认导入'));
      await settle(tester);

      final book1Cats = await tester.runAsync(
        () => queries.watchCategories(defaultBookId).first,
      );
      expect(book1Cats!.any((c) => c.name == '数码配件'), isTrue);
      expect(book1Cats.any((c) => c.name == '充电器'), isTrue);

      clearSnacks(tester, CategoryTransferPage);
      await tester.pump();

      // Tab 2: Cross-book copy from Book 1 -> Book 2
      await tester.tap(find.byKey(const Key('cat-transfer-tab-copy')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('cat-copy-submit-btn')));
      await settle(tester);

      final book2Cats = await tester.runAsync(
        () => queries.watchCategories(book2Id).first,
      );
      expect(book2Cats!.any((c) => c.name == '露营装备'), isTrue);
      expect(book2Cats.any((c) => c.name == '数码配件'), isTrue);

      if (find.text('知道了').evaluate().isNotEmpty) {
        await tester.tap(find.text('知道了'));
        await settle(tester);
      }
      clearSnacks(tester, CategoryTransferPage);
      await tester.pump();

      // Tab 3: Intra-book category migration
      await tester.tap(find.byKey(const Key('cat-transfer-tab-migrate')));
      await settle(tester);
      await tester.drag(find.byType(ListView).first, const Offset(0, -300));
      await settle(tester);
      final migrateBtn = find.byKey(const Key('cat-migrate-submit-btn'));
      await tester.ensureVisible(migrateBtn);
      await settle(tester);
      await tester.tap(migrateBtn);
      await settle(tester);
      expect(find.text('确认迁移分类关联数据'), findsOneWidget);
      await tester.tap(find.text('确认迁移'));
      await settle(tester);
      expect(find.textContaining('迁移完成'), findsWidgets);

      await unmountCleanly(tester);
    },
  );

  testWidgets(
    'BatchEditPage supports select/invert, batch edit sheet, and batch delete with balance conservation',
    (tester) async {
      late final AppDatabase db;
      await tester.runAsync(() async {
        db = AppDatabase(NativeDatabase.memory());
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(db.close);
      });

      final catalog = CatalogService(db);
      final queries = CatalogQueries(db);
      final ledger = LedgerService(db);

      var walletA = 0;
      var walletB = 0;
      var tagId = '';
      var rec1 = '';
      var rec2 = '';
      await tester.runAsync(() async {
        walletA = await ledger.createAsset(
          commandId: 'w-be-a1',
          name: '钱包A',
          initial: Money.parse('500.00'),
        );
        walletB = await ledger.createAsset(
          commandId: 'w-be-a2',
          name: '钱包B',
          initial: Money.parse('800.00'),
        );
        tagId = await catalog.createTag(commandId: 'w-be-tag', name: '餐饮标签');
        final cats = await queries.watchCategories(defaultBookId).first;
        final food = cats.firstWhere((c) => c.type == 0 && c.name == '餐饮');

        rec1 = await ledger.saveRecord(
          commandId: 'w-be-r1',
          draft: RecordDraft(
            type: RecordType.expense,
            money: Money.parse('40.00'),
            recordTime: DateTime(2026, 7, 1, 12).millisecondsSinceEpoch,
            bookId: defaultBookId,
            categoryId: food.id,
            assetId: walletA,
            remark: '午餐面条',
          ),
        );
        rec2 = await ledger.saveRecord(
          commandId: 'w-be-r2',
          draft: RecordDraft(
            type: RecordType.expense,
            money: Money.parse('60.00'),
            recordTime: DateTime(2026, 7, 2, 19).millisecondsSinceEpoch,
            bookId: defaultBookId,
            categoryId: food.id,
            assetId: walletA,
            remark: '晚餐火锅',
          ),
        );
      });

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: const MaterialApp(home: BatchEditPage()),
        ),
      );
      await settle(tester);

      expect(find.text('已选 0 笔'), findsOneWidget);

      // Select all -> 2 selected
      await tester.tap(find.byKey(const Key('batch-select-all')));
      await settle(tester);
      expect(find.text('已选 2 笔'), findsOneWidget);

      // Open batch edit sheet -> change funding account to walletB + add tag
      await tester.tap(find.byKey(const Key('batch-open-edit-btn')));
      await settle(tester);

      await tester.tap(find.byKey(const Key('batch-toggle-asset')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('batch-target-asset')));
      await settle(tester);
      await tester.tap(find.text('钱包B').last);
      await settle(tester);

      final addTagFinder = find.byKey(Key('batch-add-tag-$tagId'));
      await tester.ensureVisible(addTagFinder);
      await tester.tap(addTagFinder);
      await settle(tester);

      final applyBtn = find.byKey(const Key('batch-apply-edit-btn'));
      await tester.ensureVisible(applyBtn);
      await tester.tap(applyBtn);
      await settle(tester);

      clearSnacks(tester, BatchEditPage);
      await tester.pump();

      // Verify walletA restored to 500.00 and walletB updated to 700.00
      final assetsAfterEdit = await tester.runAsync(
        () => db.select(db.assets).get(),
      );
      expect(
        assetsAfterEdit!.singleWhere((a) => a.id == walletA).balanceMinor,
        BigInt.from(50000),
      );
      expect(
        assetsAfterEdit.singleWhere((a) => a.id == walletB).balanceMinor,
        BigInt.from(70000),
      );

      // Now select rec1 and batch delete it -> walletB becomes 740.00
      await tester.tap(find.byKey(Key('batch-item-$rec1')));
      await settle(tester);
      expect(find.text('已选 1 笔'), findsOneWidget);

      await tester.tap(find.byKey(const Key('batch-delete-btn')));
      await settle(tester);
      expect(find.text('确认批量删除'), findsOneWidget);
      await tester.tap(find.text('确认删除'));
      await settle(tester);

      final remaining = await tester.runAsync(
        () => db.select(db.records).get(),
      );
      expect(remaining!.map((r) => r.recordId).toList(), [rec2]);
      final walletBAfterDelete = await tester.runAsync(
        () => (db.select(
          db.assets,
        )..where((t) => t.id.equals(walletB))).getSingle(),
      );
      expect(walletBAfterDelete!.balanceMinor, BigInt.from(74000));

      await unmountCleanly(tester);
    },
  );

  testWidgets(
    'BillAttachmentStrip & BillImagesPage add image, render monthly gallery, and clean orphan cache',
    (tester) async {
      late final AppDatabase db;
      await tester.runAsync(() async {
        db = AppDatabase(NativeDatabase.memory());
      });
      final tempDir = await tester.runAsync(
        () => Directory.systemTemp.createTemp('tallyisle_m6a_ui_'),
      );
      final attDir = Directory(p.join(tempDir!.path, 'attachments'));

      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(db.close);
        await tester.runAsync(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });
      });

      final queries = CatalogQueries(db);
      final ledger = LedgerService(db);
      var recId = '';
      await tester.runAsync(() async {
        await attDir.create(recursive: true);
        await File(
          p.join(attDir.path, 'orphan_extra.png'),
        ).writeAsBytes(_validPng);

        final cats = await queries.watchCategories(defaultBookId).first;
        final food = cats.firstWhere((c) => c.type == 0 && c.name == '餐饮');
        recId = await ledger.saveRecord(
          commandId: 'w-att-r1',
          draft: RecordDraft(
            type: RecordType.expense,
            money: Money.parse('28.50'),
            recordTime: DateTime(2026, 8, 12, 13, 20).millisecondsSinceEpoch,
            bookId: defaultBookId,
            categoryId: food.id,
            remark: '咖啡小票',
          ),
        );
      });

      final fileAccess = FileAccess(
        onPickBytes: (_) async => SelectedBytes('ticket.png', _validPng),
      );

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            attachmentDirectoryOverrideProvider.overrideWithValue(
              () async => attDir,
            ),
            attachmentFileAccessProvider.overrideWithValue(fileAccess),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  BillAttachmentStrip(recordId: recId),
                  const Expanded(child: BillImagesPage()),
                ],
              ),
            ),
          ),
        ),
      );
      await settle(tester);

      expect(find.text('图片附件（0/9）'), findsOneWidget);
      expect(find.textContaining('无用缓存 1 个'), findsOneWidget);

      await tester.tap(find.byKey(const Key('att-strip-add-btn')));
      await settle(tester);

      expect(find.text('图片附件（1/9）'), findsOneWidget);
      expect(find.textContaining('2026年08月（1 张）'), findsOneWidget);

      await tester.tap(find.byKey(const Key('bill-images-cleanup-btn')));
      await settle(tester);
      expect(find.text('清理无用图片缓存'), findsOneWidget);
      await tester.tap(find.text('立即清理'));
      await settle(tester);

      expect(find.textContaining('无用缓存 0 个'), findsOneWidget);
      final orphanExists = await tester.runAsync(
        () => File(p.join(attDir.path, 'orphan_extra.png')).exists(),
      );
      expect(orphanExists, isFalse);

      await unmountCleanly(tester);
    },
  );

  testWidgets(
    'DiyToolbarSettingsPage, BillLocationEditorDialog & RecordReceiptDialog work end-to-end',
    (tester) async {
      late final AppDatabase db;
      await tester.runAsync(() async {
        db = AppDatabase(NativeDatabase.memory());
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(db.close);
      });

      final queries = CatalogQueries(db);
      final ledger = LedgerService(db);
      var recId = '';
      await tester.runAsync(() async {
        final bankId = await ledger.createAsset(
          commandId: 'w-rcp-bank',
          name: '招商信用卡',
          initial: Money.parse('1000.00'),
        );
        final cats = await queries.watchCategories(defaultBookId).first;
        final food = cats.firstWhere((c) => c.type == 0 && c.name == '餐饮');
        final extra = RecordExtra()
          ..location = BillLocationInfo(
            simpleName: '新天地',
            name: '上海市黄浦区太仓路 181 弄',
          );
        recId = await ledger.saveRecord(
          commandId: 'w-rcp-r1',
          draft: RecordDraft(
            type: RecordType.expense,
            money: Money.parse('88.80'),
            discount: Money.parse('11.20'),
            recordTime: DateTime(2026, 9, 20, 19, 30).millisecondsSinceEpoch,
            bookId: defaultBookId,
            categoryId: food.id,
            assetId: bankId,
            remark: '聚餐小票',
            extra: extra,
          ),
        );
      });

      String? savedPngName;
      String? sharedPngName;
      var boundaryCaptured = false;

      final fileAccess = FileAccess(
        onSaveBytes: (name, bytes, mime) async {
          savedPngName = name;
          expect(mime, 'image/png');
          expect(bytes, _validPng);
        },
        onShareBytes: (name, bytes, mime, subject) async {
          sharedPngName = name;
          expect(mime, 'image/png');
          expect(subject, contains('帐屿账单小票'));
        },
      );

      // 1. Test DiyToolbarSettingsPage
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            receiptFileAccessProvider.overrideWithValue(fileAccess),
            receiptPngCapturerProvider.overrideWithValue((boundaryKey) async {
              final ro = boundaryKey.currentContext?.findRenderObject();
              expect(ro, isA<RenderRepaintBoundary>());
              boundaryCaptured = true;
              return _validPng;
            }),
          ],
          child: const MaterialApp(home: DiyToolbarSettingsPage()),
        ),
      );
      await settle(tester);

      expect(find.text('当前启用预览（8/9）'), findsOneWidget);
      await tester.tap(find.byKey(const Key('diy-switch-tags')));
      await settle(tester);
      expect(find.text('当前启用预览（7/9）'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.byKey(const Key('diy-switch-frequent_remarks')),
        160,
        scrollable: find.byType(Scrollable).last,
      );
      await settle(tester);
      final remarkSwitchBefore = tester.widget<Switch>(
        find.byKey(const Key('diy-switch-frequent_remarks')),
      );
      expect(remarkSwitchBefore.value, isFalse);

      await tester.tap(find.byKey(const Key('diy-switch-frequent_remarks')));
      await settle(tester);
      expect(find.text('当前启用预览（8/9）'), findsOneWidget);

      await tester.tap(find.byKey(const Key('diy-toolbar-reset-btn')));
      await settle(tester);
      expect(find.text('当前启用预览（8/9）'), findsOneWidget);

      await unmountCleanly(tester);

      // 2. Test BillLocationEditorDialog
      BillLocationInfo? editedLocation;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: ElevatedButton(
                key: const Key('open-loc-editor'),
                onPressed: () async {
                  editedLocation = await showDialog<BillLocationInfo>(
                    context: ctx,
                    builder: (_) => const BillLocationEditorDialog(),
                  );
                },
                child: const Text('编辑地点'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open-loc-editor')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('loc-simple-name')), '外滩');
      await tester.enterText(find.byKey(const Key('loc-latitude')), '31.24');
      await tester.enterText(find.byKey(const Key('loc-longitude')), '121.49');
      await tester.tap(find.byKey(const Key('loc-save-btn')));
      await tester.pumpAndSettle();
      expect(editedLocation?.simpleName, '外滩');
      expect(editedLocation?.latitude, 31.24);

      // 3. Test RecordReceiptDialog
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            receiptFileAccessProvider.overrideWithValue(fileAccess),
            receiptPngCapturerProvider.overrideWithValue((boundaryKey) async {
              final ro = boundaryKey.currentContext?.findRenderObject();
              expect(ro, isA<RenderRepaintBoundary>());
              boundaryCaptured = true;
              return _validPng;
            }),
          ],
          child: MaterialApp(
            home: Scaffold(body: RecordReceiptDialog(recordId: recId)),
          ),
        ),
      );
      await settle(tester);

      expect(find.byKey(const Key('receipt-amount-text')), findsOneWidget);
      expect(find.text('-88.80'), findsOneWidget);
      expect(find.text('帐屿 · TallyIsle'), findsOneWidget);
      expect(find.textContaining('新天地'), findsOneWidget);
      expect(find.text('100.00 / -11.20'), findsOneWidget);

      await tester.tap(find.byKey(const Key('receipt-save-btn')));
      await settle(tester);
      expect(boundaryCaptured, isTrue);
      expect(savedPngName, startsWith('receipt_20260920_'));

      await tester.tap(find.byKey(const Key('receipt-share-btn')));
      await settle(tester);
      expect(sharedPngName, startsWith('receipt_20260920_'));

      await unmountCleanly(tester);
    },
  );
}
