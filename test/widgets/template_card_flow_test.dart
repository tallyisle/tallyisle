import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/data/tools/template_remark_service.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/features/bank_cards/bank_cards_page.dart';
import 'package:tallyisle/features/templates/templates_page.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  (AppDatabase, Future<void> Function()) openTestDb(WidgetTester tester) {
    final db = AppDatabase(NativeDatabase.memory());
    var closed = false;
    Future<void> closeCleanly() async {
      if (closed) return;
      closed = true;
      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(db.close);
    }

    addTearDown(() async {
      if (!closed) {
        closed = true;
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(db.close);
      }
    });
    return (db, closeCleanly);
  }

  Widget buildApp(AppDatabase db, Widget home) => ProviderScope(
    retry: (_, _) => null,
    overrides: [databaseProvider.overrideWith((ref) async => db)],
    child: MaterialApp(home: home),
  );

  testWidgets(
    'TemplatesPage & RemarksPage flow: create/edit/delete remarks, create template, instant apply, and delete template',
    (tester) async {
      final (db, closeCleanly) = openTestDb(tester);

      final accountId = await tester.runAsync(
        () => LedgerService(db).createAsset(
          commandId: 'seed-asset-1',
          name: '测试储蓄卡',
          initial: Money.parse('500.00'),
        ),
      );

      await tester.pumpWidget(buildApp(db, const TemplatesPage()));
      await settle(tester);

      expect(find.byKey(const Key('templates_empty_state')), findsOneWidget);

      // Open RemarksPage and exercise create + edit + delete + create flow
      await tester.tap(find.byKey(const Key('open_remarks_page_button')));
      await settle(tester);
      expect(find.byKey(const Key('remarks_empty_state')), findsOneWidget);

      // Create temporary remark (id = 1)
      await tester.tap(find.byKey(const Key('add_remark_fab')));
      await settle(tester);
      await tester.enterText(
        find.byKey(const Key('remark_dialog_content_input')),
        '临时备注',
      );
      await tester.tap(find.byKey(const Key('remark_dialog_save')));
      await settle(tester);
      expect(find.text('临时备注'), findsOneWidget);

      // Edit remark (id = 1)
      await tester.tap(find.byKey(const Key('edit_remark_1')));
      await settle(tester);
      await tester.enterText(
        find.byKey(const Key('remark_dialog_content_input')),
        '临时备注-已改',
      );
      await tester.tap(find.byKey(const Key('remark_dialog_save')));
      await settle(tester);
      expect(find.text('临时备注-已改'), findsOneWidget);

      // Delete remark (id = 1)
      await tester.tap(find.byKey(const Key('delete_remark_1')));
      await settle(tester);
      await tester.tap(find.text('删除'));
      await settle(tester);
      expect(find.text('临时备注-已改'), findsNothing);

      // Create reusable remark '工作日午餐'
      await tester.tap(find.byKey(const Key('add_remark_fab')));
      await settle(tester);
      await tester.enterText(
        find.byKey(const Key('remark_dialog_content_input')),
        '工作日午餐',
      );
      await tester.enterText(
        find.byKey(const Key('remark_dialog_used_times_input')),
        '3',
      );
      await tester.tap(find.byKey(const Key('remark_dialog_save')));
      await settle(tester);
      expect(find.text('工作日午餐'), findsOneWidget);

      // Let SnackBar auto-dismiss before navigating back
      await tester.pump(const Duration(seconds: 5));
      await settle(tester);

      // Navigate back to TemplatesPage
      await tester.pageBack();
      await settle(tester);

      // Create an expense template using the remark chip
      await tester.tap(find.byKey(const Key('add_template_fab')));
      await settle(tester);

      await tester.enterText(
        find.byKey(const Key('template_name_input')),
        '食堂简餐',
      );
      await tester.enterText(
        find.byKey(const Key('template_amount_input')),
        '25.50',
      );
      await tester.tap(find.byKey(const Key('template_cat_餐饮')));
      await settle(tester);

      // Select account from controlled DropdownButton<int>
      await tester.scrollUntilVisible(
        find.byKey(const Key('template_asset_dropdown')),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);
      await tester.tap(find.byKey(const Key('template_asset_dropdown')));
      await settle(tester);
      await tester.tap(find.text('测试储蓄卡').last);
      await settle(tester);

      // Tap frequent remark chip inside TemplateEditorPage
      await tester.scrollUntilVisible(
        find.text('工作日午餐'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);
      expect(find.text('工作日午餐'), findsOneWidget);
      await tester.tap(find.text('工作日午餐'));
      await settle(tester);

      await tester.scrollUntilVisible(
        find.byKey(const Key('template_autosave_tile')),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);
      await tester.tap(find.byKey(const Key('template_autosave_tile')));
      await settle(tester);

      await tester.tap(find.byKey(const Key('save_template_button')));
      await settle(tester);

      expect(find.text('食堂简餐'), findsOneWidget);

      // Click '记一笔' on the created template (id = 1)
      await tester.tap(find.byKey(const Key('template_apply_button_1')));
      await settle(tester);
      expect(find.text('已通过模板生成账单'), findsOneWidget);

      final updatedAsset = await tester.runAsync(
        () => (db.select(
          db.assets,
        )..where((a) => a.id.equals(accountId!))).getSingle(),
      );
      // 500.00 - 25.50 = 474.50 (47450 minor)
      expect(updatedAsset!.balanceMinor, BigInt.from(47450));

      // Delete template (id = 1)
      await tester.tap(find.byKey(const Key('template_delete_button_1')));
      await settle(tester);
      await tester.tap(find.text('删除'));
      await settle(tester);
      expect(find.byKey(const Key('templates_empty_state')), findsOneWidget);

      await closeCleanly();
    },
  );

  testWidgets(
    'TemplateQuickBar & FrequentRemarkChips integrate cleanly with prefill, autoSave, and settled-account fallback',
    (tester) async {
      final (db, closeCleanly) = openTestDb(tester);

      late int expCatId;
      late int assetId;
      late int prefillTplId;
      late int autoTplId;

      await tester.runAsync(() async {
        final cats = await db.select(db.recordCategories).get();
        expCatId = cats.firstWhere((c) => c.type == RecordType.expense).id;
        assetId = await LedgerService(db).createAsset(
          commandId: 'q-asset',
          name: '快捷钱包',
          initial: Money.parse('200.00'),
        );
        final svc = TemplateRemarkService(db);
        await svc.recordRemarkUsage(
          commandId: 'q-rem-1',
          recordCatId: expCatId,
          content: '美式咖啡',
        );
        prefillTplId = await svc.saveTemplate(
          commandId: 'q-tpl-prefill',
          draft: TemplateDraft(
            type: RecordType.expense,
            money: Money.parse('16.00'),
            bookId: 1,
            name: '下午咖啡',
            categoryId: expCatId,
            assetId: assetId,
            remark: '冰美式',
            autoSave: false,
          ),
        );
        autoTplId = await svc.saveTemplate(
          commandId: 'q-tpl-auto',
          draft: TemplateDraft(
            type: RecordType.expense,
            money: Money.parse('9.90'),
            bookId: 1,
            name: '瑞幸秒记',
            categoryId: expCatId,
            assetId: assetId,
            remark: '生椰拿铁',
            autoSave: true,
          ),
        );
      });

      TemplatePrefill? receivedPrefill;
      String? instantRecordId;
      String? chosenRemark;

      await tester.pumpWidget(
        buildApp(
          db,
          Scaffold(
            body: Column(
              children: [
                TemplateQuickBar(
                  bookId: 1,
                  recordType: RecordType.expense,
                  onPrefill: (p) => receivedPrefill = p,
                  onInstantSaved: (id) => instantRecordId = id,
                ),
                FrequentRemarkChips(
                  categoryId: expCatId,
                  onSelectRemark: (r) => chosenRemark = r,
                ),
              ],
            ),
          ),
        ),
      );
      await settle(tester);

      // Tap FrequentRemarkChips
      await tester.tap(find.text('美式咖啡'));
      await tester.pump();
      expect(chosenRemark, '美式咖啡');

      // Tap prefill template
      await tester.tap(find.byKey(Key('quick_template_$prefillTplId')));
      await settle(tester);
      expect(receivedPrefill, isNotNull);
      expect(receivedPrefill!.amountText, '16.00');
      expect(receivedPrefill!.remark, '冰美式');
      expect(instantRecordId, isNull);

      // Tap autoSave template -> books 1 record
      await tester.tap(find.byKey(Key('quick_template_$autoTplId')));
      await settle(tester);
      expect(instantRecordId, isNotNull);
      final records = await tester.runAsync(() => db.select(db.records).get());
      expect(records, hasLength(1));
      expect(records!.single.moneyMinor, BigInt.from(990));

      // Settle the linked account and tap autoSave template again -> falls back to prefill cleanly
      receivedPrefill = null;
      instantRecordId = null;
      await tester.runAsync(
        () => (db.update(db.assets)..where((a) => a.id.equals(assetId))).write(
          const AssetsCompanion(status: Value(AssetStatus.settled)),
        ),
      );
      await tester.tap(find.byKey(Key('quick_template_$autoTplId')));
      await settle(tester);
      expect(instantRecordId, isNull);
      expect(receivedPrefill, isNotNull);
      expect(receivedPrefill!.assetId, noRef);
      expect(receivedPrefill!.warnings, isNotEmpty);

      await closeCleanly();
    },
  );

  testWidgets(
    'BankCardsPage flow: add debit & non-Luhn credit cards, filter tabs, mask/unmask toggle, Clipboard copy, edit, and delete',
    (tester) async {
      final (db, closeCleanly) = openTestDb(tester);
      String clipboardText = '';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              final args = call.arguments as Map<Object?, Object?>;
              clipboardText = (args['text'] as String?) ?? '';
            } else if (call.method == 'Clipboard.getData') {
              return <String, Object?>{'text': clipboardText};
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      await tester.pumpWidget(buildApp(db, const BankCardsPage()));
      await settle(tester);

      expect(find.byKey(const Key('bank_cards_empty_state')), findsOneWidget);

      // 1. Add a Luhn-valid debit card (4111 1111 1111 1111)
      await tester.tap(find.byKey(const Key('add_bank_card_fab')));
      await settle(tester);
      await tester.enterText(
        find.byKey(const Key('bank_card_name_input')),
        '工商工资卡',
      );
      await tester.enterText(
        find.byKey(const Key('bank_card_no_input')),
        '4111-1111 1111 1111',
      );
      await tester.pump();
      expect(find.text('Luhn 校验通过'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('bank_card_owner_input')),
        '王五',
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('bank_card_remark_input')),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await settle(tester);
      await tester.enterText(
        find.byKey(const Key('bank_card_remark_input')),
        '北京中关村支行',
      );
      await tester.tap(find.byKey(const Key('save_bank_card_button')));
      await settle(tester);

      // 2. Add a non-Luhn credit card (informational badge allows saving!)
      await tester.tap(find.byKey(const Key('add_bank_card_fab')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('bank_card_type_1')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('bank_card_name_input')),
        '建行信用卡',
      );
      await tester.enterText(
        find.byKey(const Key('bank_card_no_input')),
        '6222 0000 0000 9876',
      );
      await tester.pump();
      expect(find.textContaining('仍可保存'), findsOneWidget);
      await tester.tap(find.byKey(const Key('save_bank_card_button')));
      await settle(tester);

      // Masked by default: '**** 1111' and '**** 9876'
      expect(find.text('**** 1111'), findsOneWidget);
      expect(find.text('**** 9876'), findsOneWidget);

      // Per-card unmask on card 1 reveals only card 1
      await tester.tap(find.byKey(const Key('toggle_card_mask_1')));
      await settle(tester);
      expect(find.text('4111 1111 1111 1111'), findsOneWidget);
      expect(find.text('**** 9876'), findsOneWidget);

      // Global unmask reveals both 4-digit grouped numbers
      await tester.tap(find.byKey(const Key('toggle_global_card_mask')));
      await settle(tester);
      expect(find.text('4111 1111 1111 1111'), findsOneWidget);
      expect(find.text('6222 0000 0000 9876'), findsOneWidget);

      // Filter tabs: 储蓄卡 only shows 工商工资卡
      await tester.tap(find.byKey(const Key('card_filter_0')));
      await settle(tester);
      expect(find.text('工商工资卡'), findsOneWidget);
      expect(find.text('建行信用卡'), findsNothing);

      // Edit card 1 owner
      await tester.tap(find.byKey(const Key('edit_bank_card_1')));
      await settle(tester);
      await tester.enterText(
        find.byKey(const Key('bank_card_owner_input')),
        '王五（本人）',
      );
      await tester.tap(find.byKey(const Key('save_bank_card_button')));
      await settle(tester);

      // Copy card number (normalized digits) and full info to Clipboard
      await tester.tap(find.byKey(const Key('copy_card_no_1')));
      await settle(tester);
      expect(clipboardText, '4111111111111111');

      await tester.tap(find.byKey(const Key('copy_card_full_1')));
      await settle(tester);
      expect(clipboardText, contains('工商工资卡（储蓄卡）'));
      expect(clipboardText, contains('4111 1111 1111 1111'));
      expect(clipboardText, contains('持卡人：王五（本人）'));
      expect(clipboardText, contains('备注：北京中关村支行'));

      // Delete debit card via confirmation dialog
      await tester.tap(find.byKey(const Key('delete_bank_card_1')));
      await settle(tester);
      await tester.tap(find.text('删除'));
      await settle(tester);
      expect(find.text('工商工资卡'), findsNothing);

      await closeCleanly();
    },
  );
}
