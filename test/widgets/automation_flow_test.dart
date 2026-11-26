import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/app/app.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/automation/auto_bill_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/smart_bill_nlp_rules.dart';
import 'package:tallyisle/features/automation/auto_bill_page.dart';
import 'package:tallyisle/features/automation/automation_providers.dart';
import 'package:tallyisle/features/automation/desktop_widgets_page.dart';
import 'package:tallyisle/features/automation/ocr_bill_page.dart';
import 'package:tallyisle/features/automation/url_scheme_page.dart';
import 'package:tallyisle/features/home/home_page.dart';
import 'package:tallyisle/features/records/record_editor_page.dart';
import 'package:tallyisle/platform/app_widgets.dart';
import 'package:tallyisle/platform/auto_bill_bridge.dart';
import 'package:tallyisle/platform/files.dart';

final class _FakeImageFileAccess extends FileAccess {
  const _FakeImageFileAccess(this._bytes);

  final Uint8List _bytes;

  @override
  Future<SelectedBytes> pickBytes({List<String>? allowedExtensions}) async =>
      SelectedBytes('receipt.png', _bytes);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<void> settle(WidgetTester tester, [int ticks = 12]) async {
    for (var i = 0; i < ticks; i++) {
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
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester);
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() async {
      await autoBridge?.dispose();
      await widgetBridge?.dispose();
      await db.close();
    });
  }

  testWidgets(
    'UrlSchemePage (F-033): executes live tallyisle://addbill, smartbill draft, rejects yyjz://, and renders zero yyjz copy',
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
      expect(find.text('快捷链接'), findsOneWidget);
      expect(find.text('URL Scheme 外部调用'), findsNothing);
      expect(find.textContaining('yyjz'), findsNothing);
      expect(find.textContaining('双协议'), findsNothing);
      expect(find.text('复制 yyjz://'), findsNothing);
      expect(find.byKey(const Key('url_template_copy_legacy_0')), findsNothing);
      expect(find.byKey(const Key('url_template_copy_0')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('url_scheme_test_input')),
        'tallyisle://addbill?type=0&money=26.80&category=餐饮&remark=测试快捷早餐',
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

      // smartbill?mode=draft queues pending draft and links to inbox
      await tester.enterText(
        find.byKey(const Key('url_scheme_test_input')),
        'tallyisle://smartbill?text=早饭包子8.5微信&mode=draft',
      );
      await tester.tap(find.byKey(const Key('url_scheme_execute_button')));
      await settle(tester);
      expect(
        find.byKey(const Key('url_scheme_result_success')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('url_scheme_open_route_button')));
      await tester.pump();
      expect(navigatedRoute, '/automation/auto-bill');

      // Legacy yyjz:// scheme is rejected with validation error
      await tester.enterText(
        find.byKey(const Key('url_scheme_test_input')),
        'yyjz://addbill?type=0&money=12.00',
      );
      await tester.tap(find.byKey(const Key('url_scheme_execute_button')));
      await settle(tester);
      expect(find.byKey(const Key('url_scheme_result_error')), findsOneWidget);
      expect(find.textContaining('仅支持 tallyisle://'), findsOneWidget);

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
    'DesktopWidgetsPage (F-034): renders all 4 live previews including smartQuick with pending draft badge and pins widget',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final ledger = LedgerService(db);
      final autoBridge = InMemoryAutoBillBridge();
      final autoService = AutoBillService(db, bridge: autoBridge);
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
        await autoService.ingestPaymentText(
          commandId: 'seed-draft-1',
          rawText: '微信支付收款 15.00 元 早餐店',
        );
      });

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            autoBillBridgeProvider.overrideWithValue(autoBridge),
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

      final scrollable = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.byKey(const Key('widget_preview_month_bar')),
        200,
        scrollable: scrollable,
      );
      expect(find.byKey(const Key('widget_preview_month_bar')), findsOneWidget);

      await tester.scrollUntilVisible(
        find.byKey(const Key('widget_section_smart_quick')),
        200,
        scrollable: scrollable,
      );
      expect(
        find.byKey(const Key('widget_preview_smart_quick')),
        findsOneWidget,
      );
      expect(find.text('待确认 1'), findsOneWidget);
      expect(find.text('口语粘贴'), findsOneWidget);
      expect(find.text('识图'), findsOneWidget);

      await tester.tap(find.byKey(const Key('widget_pin_smart_quick')));
      await settle(tester);
      expect(widgetBridge.pinRequests.last, DesktopWidgetKind.smartQuick);

      await tearDownWidgetDb(
        tester,
        db,
        autoBridge: autoBridge,
        widgetBridge: widgetBridge,
      );
    },
  );

  testWidgets(
    'AutoBillPage (F-020): dual-channel badges, prompt mode & auto-confirm settings, rule creation, learn-rule confirm, and batch confirm',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

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
        notificationListenerStatus:
            const AutoBillPermissionStatus.notificationListener(enabled: true),
        overlayStatus: const AutoBillPermissionStatus.overlay(granted: false),
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

      // Dual-channel status badges + settings navigation
      expect(
        find.byKey(const Key('auto_bill_notif_status_badge')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('auto_bill_status_badge')), findsOneWidget);
      expect(find.text('已开启'), findsOneWidget);
      expect(find.text('未开启'), findsOneWidget);

      await tester.tap(
        find.byKey(const Key('auto_bill_open_notif_settings_button')),
      );
      await settle(tester);
      expect(autoBridge.openNotificationSettingsCount, 1);

      await tester.tap(find.byKey(const Key('auto_bill_open_settings_button')));
      await settle(tester);
      expect(autoBridge.openSettingsCount, 1);

      // Switch Android prompt mode to overlay -> shows overlay permission warning
      await tester.tap(find.text('底部悬浮窗'));
      await settle(tester);
      expect(
        find.byKey(const Key('auto_bill_overlay_warning')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const Key('auto_bill_open_overlay_settings_button')),
      );
      await settle(tester);
      expect(autoBridge.openOverlaySettingsCount, 1);

      // Switch to rules tab and add a keyword rule mapping "瑞幸咖啡" -> 招商卡
      await tester.tap(find.byKey(const Key('auto_bill_tab_rules')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('auto_bill_add_rule_button')));
      await settle(tester);

      expect(
        find.byKey(const Key('auto_rule_allow_auto_confirm_switch')),
        findsOneWidget,
      );
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

      // Switch back to drafts tab, paste two payment texts, and batch-confirm all
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
      expect(
        find.byKey(const Key('auto_bill_confirm_all_drafts_button')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const Key('auto_bill_confirm_all_drafts_button')),
      );
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
    'OcrBillPage (F-021, ADR-017): mobile defaults to native offline OCR ready; desktop unconfigured shows explicit 未配置',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Part A: Mobile default -> NativeOfflineOcrProvider ready & offline image recognition
      final db = AppDatabase(NativeDatabase.memory());
      final autoBridge = InMemoryAutoBillBridge(
        offlineOcrText:
            '2026年11月\n11月10日 09:15\n星巴克\n-32.00\n11月11日 12:10\n麦当劳\n-28.50',
      );
      final widgetBridge = InMemoryAppWidgetBridge();
      final fakeFiles = _FakeImageFileAccess(Uint8List.fromList([1, 2, 3, 4]));

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            autoBillBridgeProvider.overrideWithValue(autoBridge),
            appWidgetBridgeProvider.overrideWithValue(widgetBridge),
            ocrFileAccessProvider.overrideWithValue(fakeFiles),
          ],
          child: const MaterialApp(home: OcrBillPage()),
        ),
      );
      await settle(tester);

      expect(
        find.byKey(const Key('ocr_provider_status_badge')),
        findsOneWidget,
      );
      expect(find.text('本机离线引擎（免费就绪）'), findsOneWidget);

      await tester.tap(find.byKey(const Key('ocr_pick_image_button')));
      await settle(tester);
      expect(autoBridge.offlineOcrCalls, 1);
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

      // Part B: Desktop without HTTP/AI config -> explicit ADR-017 "未配置" status badge
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        final desktopDb = AppDatabase(NativeDatabase.memory());
        final desktopAutoBridge = InMemoryAutoBillBridge();
        final desktopWidgetBridge = InMemoryAppWidgetBridge();
        await tester.pumpWidget(
          ProviderScope(
            key: const ValueKey('desktop-ocr-scope'),
            retry: (_, _) => null,
            overrides: [
              databaseProvider.overrideWith((ref) async => desktopDb),
              autoBillBridgeProvider.overrideWithValue(desktopAutoBridge),
              appWidgetBridgeProvider.overrideWithValue(desktopWidgetBridge),
            ],
            child: MaterialApp(
              theme: ThemeData(
                platform: TargetPlatform.linux,
                useMaterial3: true,
              ),
              home: const OcrBillPage(),
            ),
          ),
        );
        await settle(tester);
        expect(find.text('未配置'), findsOneWidget);
        await tester.tap(find.byKey(const Key('ocr_pick_image_button')));
        await settle(tester);
        expect(find.byKey(const Key('ocr_error_banner')), findsOneWidget);
        expect(find.textContaining('OCR 服务未配置'), findsOneWidget);

        await tearDownWidgetDb(
          tester,
          desktopDb,
          autoBridge: desktopAutoBridge,
          widgetBridge: desktopWidgetBridge,
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }

      await autoBridge.dispose();
      await widgetBridge.dispose();
      await tester.runAsync(db.close);
    },
  );

  testWidgets(
    'RecordEditorPage + SmartQuickSheet: colloquial prefill in-place, explicit-only clipboard read, and rule self-learning',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      var clipboardReadCalls = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') {
            clipboardReadCalls++;
            return const <String, Object?>{'text': '午饭牛肉面支付宝花了22元'};
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      final db = AppDatabase(NativeDatabase.memory());
      final ledger = LedgerService(db);
      final wechatId = await tester.runAsync(
        () => ledger.createAsset(
          commandId: 'seed-wechat',
          name: '微信零钱',
          initial: Money.parse('200.00'),
        ),
      );
      final autoBridge = InMemoryAutoBillBridge();
      final widgetBridge = InMemoryAppWidgetBridge();

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            autoBillBridgeProvider.overrideWithValue(autoBridge),
            appWidgetBridgeProvider.overrideWithValue(widgetBridge),
          ],
          child: const MaterialApp(
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            supportedLocales: [Locale('zh'), Locale('en')],
            locale: Locale('zh'),
            home: RecordEditorPage(),
          ),
        ),
      );
      await settle(tester);

      // Zero automatic clipboard reads on RecordEditorPage startup
      expect(clipboardReadCalls, 0);

      final smartBtn = find.byKey(const Key('record_editor_smart_fill_button'));
      expect(smartBtn, findsOneWidget);
      await tester.tap(smartBtn);
      await settle(tester);

      // Still zero clipboard reads on opening SmartQuickSheet
      expect(clipboardReadCalls, 0);
      expect(find.byKey(const Key('smart_quick_sheet')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('smart_quick_text_input')),
        '早饭买煎饼微信花了9块5',
      );
      await tester.tap(find.byKey(const Key('smart_quick_parse_button')));
      await settle(tester);

      expect(find.byKey(const Key('smart_quick_single_card')), findsOneWidget);
      final learnCheck = tester.widget<CheckboxListTile>(
        find.byKey(const Key('smart_quick_learn_rule_toggle')),
      );
      expect(learnCheck.value, isTrue);

      final confirmBtn = find.byKey(const Key('smart_quick_confirm_button'));
      await tester.ensureVisible(confirmBtn);
      await settle(tester);
      await tester.tap(confirmBtn);
      await settle(tester);

      // Sheet closed, RecordEditorPage populated in-place with 9.50 & 买煎饼 & 微信零钱
      expect(find.byKey(const Key('smart_quick_sheet')), findsNothing);
      expect(find.text('9.50'), findsWidgets);

      // Save the prefilled record from RecordEditorPage
      await tester.tap(find.byKey(const Key('editor-quick-save-btn')));
      await settle(tester);

      final savedRecords = await tester.runAsync(
        () => db.select(db.records).get(),
      );
      expect(savedRecords, hasLength(1));
      expect(savedRecords!.single.moneyMinor, BigInt.from(950));
      expect(savedRecords.single.assetId, wechatId);
      expect(savedRecords.single.remark, contains('煎饼'));

      // Verify explicit paste button reads clipboard once when tapped
      await tester.tap(smartBtn);
      await settle(tester);
      expect(clipboardReadCalls, 0);
      await tester.tap(find.byKey(const Key('smart_quick_paste_button')));
      await settle(tester);
      expect(clipboardReadCalls, 1);
      expect(find.text('22.00'), findsWidgets);

      await tearDownWidgetDb(
        tester,
        db,
        autoBridge: autoBridge,
        widgetBridge: widgetBridge,
      );
    },
  );

  testWidgets(
    'AutoBillPage on iOS shows Apple Shortcuts card and 3-step guide dialog',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final autoBridge = InMemoryAutoBillBridge();
      final widgetBridge = InMemoryAppWidgetBridge();

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            autoBillBridgeProvider.overrideWithValue(autoBridge),
            appWidgetBridgeProvider.overrideWithValue(widgetBridge),
          ],
          child: MaterialApp(
            theme: ThemeData(platform: TargetPlatform.iOS, useMaterial3: true),
            home: const AutoBillPage(),
          ),
        ),
      );
      await settle(tester);
      expect(
        find.byKey(const Key('auto_bill_ios_shortcuts_card')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('auto_bill_ios_guide_button')));
      await settle(tester);
      expect(
        find.byKey(const Key('auto_bill_ios_guide_dialog')),
        findsOneWidget,
      );
      await tester.tap(find.text('我知道了'));
      await settle(tester);

      await tearDownWidgetDb(
        tester,
        db,
        autoBridge: autoBridge,
        widgetBridge: widgetBridge,
      );
    },
  );

  testWidgets(
    'HomePage pending drafts banner and TallyIsleApp shared payload / prompt action wiring',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final db = AppDatabase(NativeDatabase.memory());
      final autoBridge = InMemoryAutoBillBridge();
      final widgetBridge = InMemoryAppWidgetBridge();
      var closed = false;
      Future<void> closeCleanly() async {
        if (closed) return;
        closed = true;
        await tester.pumpWidget(const SizedBox.shrink());
        await settle(tester);
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(() async {
          await autoBridge.dispose();
          await widgetBridge.dispose();
          await db.close();
        });
      }

      addTearDown(closeCleanly);

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            autoBillBridgeProvider.overrideWithValue(autoBridge),
            appWidgetBridgeProvider.overrideWithValue(widgetBridge),
          ],
          child: const TallyIsleApp(),
        ),
      );
      await settle(tester, 20);
      expect(find.byType(HomePage), findsOneWidget);
      expect(find.byKey(const Key('home_pending_drafts_banner')), findsNothing);

      // Queue 1 draft via live bridge -> banner appears on HomePage
      autoBridge.simulateCapturedEvent(
        const CapturedPaymentEvent(
          packageName: 'com.eg.android.AlipayGphone',
          rawText: '支付宝付款 16.80 元 全家便利店',
          capturedAtMs: 1762860000000,
        ),
      );
      await settle(tester, 16);
      expect(
        find.byKey(const Key('home_pending_drafts_banner')),
        findsOneWidget,
      );
      expect(find.text('有 1 笔智能识别账单待确认'), findsOneWidget);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(Scaffold).first),
      );
      final drafts = container.read(autoBillDraftsProvider).value ?? const [];
      expect(drafts, hasLength(1));
      final draftId = drafts.single.id!;

      // Toggling showHomeDraftBanner false hides HomePendingDraftsBanner
      final autoService = container.read(autoBillServiceProvider).requireValue;
      // Run in widget test zone so Drift stream re-queries and follow-up reads advance together.
      // ignore: unawaited_futures
      autoService.saveSettings(
        commandId: 'hide-banner-1',
        settings: const AutoBillSettings(showHomeDraftBanner: false),
      );
      await settle(tester);
      expect(find.byKey(const Key('home_pending_drafts_banner')), findsNothing);

      // Prompt action confirm_draft executes live via TallyIsleApp listener
      autoBridge.simulatePromptAction(
        AutoBillPromptActionEvent(
          action: AutoBillPromptActionKind.confirmDraft,
          draftId: draftId,
          actionAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      await settle(tester, 16);
      final recordsAfterPrompt = await tester.runAsync(
        () => db.select(db.records).get(),
      );
      expect(recordsAfterPrompt, hasLength(1));
      expect(recordsAfterPrompt!.single.moneyMinor, BigInt.from(1680));

      // Shared text payload routes to /automation/smart-bill and parses automatically
      autoBridge.simulateSharedPayload(
        AutoBillSharedPayload(
          kind: AutoBillSharedPayloadKind.text,
          text: '打车花了26元微信',
          source: 'share',
          receivedAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      await settle(tester, 16);
      expect(find.byKey(const Key('smart_quick_bill_page')), findsOneWidget);
      expect(find.byKey(const Key('smart_quick_single_card')), findsOneWidget);
      expect(find.text('26.00'), findsWidgets);

      await closeCleanly();
    },
  );
}
