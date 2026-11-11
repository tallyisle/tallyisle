import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/features/automation/auto_bill_page.dart';
import 'package:tallyisle/features/automation/automation_providers.dart';
import 'package:tallyisle/features/automation/desktop_widgets_page.dart';
import 'package:tallyisle/features/automation/ocr_bill_page.dart';
import 'package:tallyisle/features/automation/url_scheme_page.dart';
import 'package:tallyisle/platform/app_widgets.dart';
import 'package:tallyisle/platform/auto_bill_bridge.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  Future<void> tearDownWidgetDb(
    WidgetTester tester,
    AppDatabase db, {
    AutoBillBridge? autoBridge,
    AppWidgetBridge? widgetBridge,
  }) async {
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    await autoBridge?.dispose();
    await widgetBridge?.dispose();
    await tester.runAsync(db.close);
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets(
    'UrlSchemePage (F-033): executes live yyjz://addbill and persists record into SQLite',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final autoBridge = InMemoryAutoBillBridge();
      final widgetBridge = InMemoryAppWidgetBridge();
      String? navigatedRoute;

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            autoBillBridgeProvider.overrideWithValue(autoBridge),
            appWidgetBridgeProvider.overrideWithValue(widgetBridge),
          ],
          child: MaterialApp(
            home: UrlSchemePage(onNavigateRoute: (r) => navigatedRoute = r),
          ),
        ),
      );
      await settle(tester);

      expect(find.byKey(const Key('url_scheme_page')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('url_scheme_test_input')),
        'yyjz://addbill?type=0&money=26.80&category=餐饮&remark=测试快捷早餐',
      );
      await tester.tap(find.byKey(const Key('url_scheme_execute_button')));
      await settle(tester);

      expect(
        find.byKey(const Key('url_scheme_result_success')),
        findsOneWidget,
      );
      final rows = await tester.runAsync(() => db.select(db.records).get());
      expect(rows, hasLength(1));
      expect(rows!.single.moneyMinor, BigInt.from(2680));
      expect(rows.single.remark, '测试快捷早餐');

      // Test navigation URI as well
      await tester.enterText(
        find.byKey(const Key('url_scheme_test_input')),
        'tallyisle://calendar',
      );
      await tester.tap(find.byKey(const Key('url_scheme_execute_button')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('url_scheme_open_route_button')));
      await tester.pump();
      expect(navigatedRoute, '/calendar');

      await tearDownWidgetDb(
        tester,
        db,
        autoBridge: autoBridge,
        widgetBridge: widgetBridge,
      );
    },
  );

  testWidgets(
    'DesktopWidgetsPage (F-034): renders 1x1, 2x2, and 4x1 live previews from ledger and pins widget',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final ledger = LedgerService(db);
      final widgetBridge = InMemoryAppWidgetBridge();

      final cats = await tester.runAsync(
        () => db.select(db.recordCategories).get(),
      );
      final foodId = cats!.firstWhere((c) => c.name == '餐饮').id;
      final salaryId = cats.firstWhere((c) => c.name == '工资').id;
      await tester.runAsync(() async {
        await ledger.saveRecord(
          commandId: 'seed-exp-1',
          draft: RecordDraft(
            type: RecordType.expense,
            money: Money.minor(BigInt.from(6650)),
            bookId: 1,
            recordTime: DateTime.now().millisecondsSinceEpoch,
            categoryId: foodId,
            remark: '午餐',
          ),
        );
        await ledger.saveRecord(
          commandId: 'seed-inc-1',
          draft: RecordDraft(
            type: RecordType.income,
            money: Money.minor(BigInt.from(20000)),
            bookId: 1,
            recordTime: DateTime.now().millisecondsSinceEpoch,
            categoryId: salaryId,
            remark: '补贴',
          ),
        );
      });

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            appWidgetBridgeProvider.overrideWithValue(widgetBridge),
          ],
          child: const MaterialApp(home: DesktopWidgetsPage()),
        ),
      );
      await settle(tester);

      expect(find.byKey(const Key('widget_preview_quick_add')), findsOneWidget);
      expect(
        find.byKey(const Key('widget_preview_month_summary')),
        findsOneWidget,
      );
      expect(find.textContaining('¥66.50'), findsWidgets);
      expect(find.textContaining('¥200.00'), findsWidgets);

      await tester.tap(find.byKey(const Key('widget_pin_quick_add')));
      await settle(tester);
      expect(widgetBridge.pinRequests, [DesktopWidgetKind.quickAdd]);
      expect(widgetBridge.lastSnapshot?.expenseMinor, BigInt.from(6650));

      await tester.scrollUntilVisible(
        find.byKey(const Key('widget_preview_month_bar')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byKey(const Key('widget_preview_month_bar')), findsOneWidget);

      await tearDownWidgetDb(tester, db, widgetBridge: widgetBridge);
    },
  );

  testWidgets(
    'AutoBillPage (F-020): shows honest 未开启 badge, creates rule, parses payment text, and confirms draft',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final ledger = LedgerService(db);
      final assetId = await tester.runAsync(
        () => ledger.createAsset(
          commandId: 'seed-card-1',
          name: '招商卡',
          initial: Money.minor(BigInt.from(50000)),
        ),
      );
      final autoBridge = InMemoryAutoBillBridge(
        status: const AccessibilityBridgeStatus.android(enabled: false),
      );
      final widgetBridge = InMemoryAppWidgetBridge();

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            autoBillBridgeProvider.overrideWithValue(autoBridge),
            appWidgetBridgeProvider.overrideWithValue(widgetBridge),
          ],
          child: const MaterialApp(home: AutoBillPage()),
        ),
      );
      await settle(tester);

      // Honest permission status badge + settings navigation
      expect(find.byKey(const Key('auto_bill_status_badge')), findsOneWidget);
      expect(find.text('未开启'), findsOneWidget);
      await tester.tap(find.byKey(const Key('auto_bill_open_settings_button')));
      await settle(tester);
      expect(autoBridge.openSettingsCount, 1);

      // Switch to rules tab and add a keyword rule mapping "瑞幸" -> 招商卡
      await tester.tap(find.byKey(const Key('auto_bill_tab_rules')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('auto_bill_add_rule_button')));
      await settle(tester);

      await tester.enterText(
        find.byKey(const Key('auto_bill_rule_key_input')),
        '瑞幸咖啡',
      );
      await tester.tap(find.byKey(const Key('auto_bill_rule_asset_dropdown')));
      await settle(tester);
      await tester.tap(find.text('招商卡').last);
      await settle(tester);

      await tester.tap(find.byKey(const Key('auto_bill_rule_save_button')));
      await settle(tester);
      expect(find.text('瑞幸咖啡'), findsOneWidget);

      // Switch back to drafts tab, paste bank SMS, and confirm draft into LedgerService
      await tester.tap(find.byKey(const Key('auto_bill_tab_drafts')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('auto_bill_paste_parse_button')));
      await settle(tester);

      await tester.enterText(
        find.byKey(const Key('auto_bill_paste_input')),
        '【招商银行】您账户于11月11日09:30消费人民币18.50元，商户：瑞幸咖啡',
      );
      await tester.tap(find.byKey(const Key('auto_bill_paste_submit')));
      await settle(tester);

      expect(find.text('¥18.50'), findsOneWidget);
      await tester.tap(find.text('确认入账'));
      await settle(tester);

      final records = await tester.runAsync(() => db.select(db.records).get());
      expect(records, hasLength(1));
      expect(records!.single.moneyMinor, BigInt.from(1850));
      expect(records.single.assetId, assetId);

      final updatedCard = await tester.runAsync(
        () => (db.select(
          db.assets,
        )..where((t) => t.id.equals(assetId!))).getSingle(),
      );
      expect(updatedCard!.balanceMinor, BigInt.from(48150)); // 500.00 - 18.50

      await tearDownWidgetDb(
        tester,
        db,
        autoBridge: autoBridge,
        widgetBridge: widgetBridge,
      );
    },
  );

  testWidgets(
    'OcrBillPage (F-021, ADR-017): displays explicit 未配置 badge, rejects fake image OCR, and batch-confirms parsed text',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final db = AppDatabase(NativeDatabase.memory());
      final widgetBridge = InMemoryAppWidgetBridge();

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            appWidgetBridgeProvider.overrideWithValue(widgetBridge),
          ],
          child: const MaterialApp(home: OcrBillPage()),
        ),
      );
      await settle(tester);

      // ADR-017: explicit "未配置" status badge
      expect(
        find.byKey(const Key('ocr_provider_status_badge')),
        findsOneWidget,
      );
      expect(find.text('未配置'), findsOneWidget);

      // Tapping image recognition when unconfigured surfaces honest error and creates 0 candidates
      await tester.tap(find.byKey(const Key('ocr_pick_image_button')));
      await settle(tester);
      expect(find.byKey(const Key('ocr_error_banner')), findsOneWidget);
      expect(find.textContaining('OCR 服务未配置'), findsOneWidget);

      // Offline text parsing -> review -> batch confirm into LedgerService
      await tester.enterText(
        find.byKey(const Key('ocr_text_input')),
        '2026年11月\n11月10日 09:15\n星巴克\n-32.00\n11月11日 12:10\n麦当劳\n-28.50',
      );
      await tester.tap(find.byKey(const Key('ocr_parse_text_button')));
      await settle(tester);

      expect(find.byKey(const Key('ocr_candidate_0')), findsOneWidget);
      expect(find.byKey(const Key('ocr_candidate_1')), findsOneWidget);

      await tester.tap(find.byKey(const Key('ocr_confirm_batch_button')));
      await settle(tester);

      final records = await tester.runAsync(() => db.select(db.records).get());
      expect(records, hasLength(2));
      expect(records!.map((r) => r.moneyMinor).toSet(), {
        BigInt.from(3200),
        BigInt.from(2850),
      });

      await tearDownWidgetDb(tester, db, widgetBridge: widgetBridge);
    },
  );
}
