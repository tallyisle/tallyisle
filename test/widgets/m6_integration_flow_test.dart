import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/app/app.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/app_settings_rules.dart';
import 'package:tallyisle/features/automation/automation_providers.dart';
import 'package:tallyisle/features/security/app_lock_providers.dart';
import 'package:tallyisle/platform/auto_bill_bridge.dart';

Future<void> _settle(WidgetTester tester, [int ticks = 8]) async {
  for (var i = 0; i < ticks; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

Future<void> _goBack(WidgetTester tester) async {
  final backButton = find.byType(BackButton);
  if (backButton.evaluate().isNotEmpty) {
    await tester.tap(backButton.last);
  } else {
    final nav = tester.state<NavigatorState>(find.byType(Navigator).last);
    nav.pop();
  }
  await _settle(tester);
}

(AppDatabase, Future<void> Function()) _openTestDb(WidgetTester tester) {
  final db = AppDatabase(NativeDatabase.memory());
  var closed = false;
  Future<void> closeCleanly() async {
    if (closed) return;
    closed = true;
    await tester.pumpWidget(const SizedBox.shrink());
    await _settle(tester, 4);
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(db.close);
  }

  addTearDown(() async {
    if (!closed) {
      closed = true;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(db.close);
    }
  });
  return (db, closeCleanly);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('M6 end-to-end integration flows', () {
    testWidgets(
      'MePage M6 sections and Categories/Search/Stats AppBar entries navigate cleanly',
      (tester) async {
        final (db, closeCleanly) = _openTestDb(tester);

        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [databaseProvider.overrideWith((ref) async => db)],
            child: const TallyIsleApp(),
          ),
        );
        await _settle(tester);

        // 1. SearchPage -> BatchEditPage
        await tester.tap(find.byKey(const Key('home-search-button')));
        await _settle(tester);
        await tester.tap(find.byKey(const Key('search-batch-action')));
        await _settle(tester);
        expect(find.text('账单批量管理'), findsOneWidget);
        await _goBack(tester);
        await _goBack(tester);

        // 2. StatsPage -> StatStoriesPage
        await tester.tap(find.text('统计'));
        await _settle(tester);
        await tester.tap(find.byKey(const Key('stats-stories-action')));
        await _settle(tester);
        expect(find.text('统计故事'), findsOneWidget);
        await _goBack(tester);

        // 3. MePage -> CategoriesPage -> CategoryTransferPage
        await tester.tap(find.text('更多'));
        await _settle(tester);
        await tester.tap(find.byKey(const Key('me-categories')));
        await _settle(tester);
        await tester.tap(find.byKey(const Key('categories-transfer-action')));
        await _settle(tester);
        expect(find.text('分类导入导出与迁移'), findsOneWidget);
        await _goBack(tester);
        await _goBack(tester);

        // 4. All 18 M6 destinations on MePage across 3 sections
        expect(find.text('常用工具'), findsOneWidget);
        expect(find.text('智能与外部联动'), findsOneWidget);
        expect(find.text('安全与系统设置'), findsOneWidget);

        const meRoutes = <(Key, String)>[
          (Key('me-wishes'), '心愿单'),
          (Key('me-notes'), '便签'),
          (Key('me-templates'), '账单模板'),
          (Key('me-remarks'), '常用备注管理'),
          (Key('me-bank-cards'), '银行卡备忘'),
          (Key('me-batch-records'), '账单批量管理'),
          (Key('me-category-transfer'), '分类导入导出与迁移'),
          (Key('me-attachments'), '账单图片库'),
          (Key('me-stat-stories'), '统计故事'),
          (Key('me-auto-bill'), '自动记账'),
          (Key('me-ocr'), '账单图 / 文本识别'),
          (Key('me-widgets'), '桌面小组件'),
          (Key('me-url-scheme'), 'URL Scheme 外部调用'),
          (Key('me-app-lock'), '应用安全锁'),
          (Key('me-settings'), '系统与首页设置'),
          (Key('me-diy-toolbar'), '记账工具栏自定义'),
          (Key('me-data-health'), '数据体检'),
          (Key('me-about'), '帮助与关于'),
        ];

        for (final (tileKey, expectedTitle) in meRoutes) {
          await tester.scrollUntilVisible(
            find.byKey(tileKey),
            220,
            scrollable: find.byType(Scrollable).first,
          );
          await _settle(tester, 4);
          await tester.tap(find.byKey(tileKey));
          await _settle(tester);
          expect(find.text(expectedTitle), findsWidgets);
          await _goBack(tester);
          expect(find.text('更多'), findsWidgets);
        }

        await closeCleanly();
      },
    );

    testWidgets(
      'showBalanceChangeRecordOnHome, showHomeAssetSummaryBanner, and defaultRecordType drive HomePage',
      (tester) async {
        final (db, closeCleanly) = _openTestDb(tester);

        late int cashId;
        await tester.runAsync(() async {
          final ledger = LedgerService(db);
          cashId = await ledger.createAsset(
            commandId: 'seed-cash',
            name: '日常现金',
            type: AssetType.normal,
            initial: Money.parse('1000.00'),
          );
          await ledger.adjustBalance(
            commandId: 'adjust-cash-balance',
            assetId: cashId,
            target: Money.parse('1200.00'),
            bookId: 1,
          );
        });

        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [databaseProvider.overrideWith((ref) async => db)],
            child: const TallyIsleApp(),
          ),
        );
        await _settle(tester);

        // By default: asset banner visible, type=4 balance adjustment hidden on Home.
        expect(
          find.byKey(const Key('home-asset-summary-banner')),
          findsOneWidget,
        );
        expect(find.text('净资产 ¥1200.00'), findsOneWidget);
        expect(find.text('余额调整'), findsNothing);
        expect(find.text('本期暂无账单'), findsOneWidget);

        // Enable showBalanceChangeRecordOnHome and switch defaultRecordType to income.
        final container = ProviderScope.containerOf(
          tester.element(find.byType(Scaffold).first),
        );
        await tester.runAsync(() async {
          final settingsSvc = await container.read(
            appSettingsServiceProvider.future,
          );
          await settingsSvc.saveSettings(
            commandId: 'enable-home-balance-adjust',
            settings: AppSettings.defaults.copyWith(
              showBalanceChangeRecordOnHome: true,
              showHomeAssetSummaryBanner: false,
              defaultRecordType: RecordType.income,
            ),
          );
        });
        await _settle(tester);

        // Asset banner hidden; type=4 balance adjustment row appears without polluting income/expense!
        expect(
          find.byKey(const Key('home-asset-summary-banner')),
          findsNothing,
        );
        expect(find.text('余额调整'), findsOneWidget);
        expect(find.text('+200.00'), findsOneWidget);
        expect(
          tester.widget<Text>(find.byKey(const Key('sum-income'))).data,
          '0.00',
        );
        expect(
          tester.widget<Text>(find.byKey(const Key('sum-expense'))).data,
          '0.00',
        );

        // Tapping FAB opens RecordEditorPage preselected on RecordType.income (type-1).
        await tester.tap(find.byKey(const Key('add-record')));
        await _settle(tester);
        final incomeChip = tester.widget<ChoiceChip>(
          find.byKey(const Key('type-1')),
        );
        expect(incomeChip.selected, isTrue);

        await closeCleanly();
      },
    );

    testWidgets(
      'AppLockGate shields TallyIsleApp on background/resume and unlocks with PIN',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 1100));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final (db, closeCleanly) = _openTestDb(tester);

        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [databaseProvider.overrideWith((ref) async => db)],
            child: const TallyIsleApp(),
          ),
        );
        await _settle(tester);
        expect(find.text('日常账本'), findsOneWidget);
        expect(find.byKey(const Key('app_lock_overlay')), findsNothing);

        final container = ProviderScope.containerOf(
          tester.element(find.byType(Scaffold).first),
        );
        await tester.runAsync(() async {
          final lockSvc = await container.read(appLockServiceProvider.future);
          await lockSvc.enableAppLock(
            commandId: 'setup-pin-2580',
            pin: '2580',
            timeoutSeconds: 0,
          );
        });
        await _settle(tester);

        // Simulate app moving to background and resuming -> immediate lock overlay!
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await _settle(tester);

        expect(find.byKey(const Key('app_lock_overlay')), findsOneWidget);
        expect(find.text('帐屿已锁定'), findsOneWidget);
        // Underlying HomePage widgets are hidden by Visibility(visible: false).
        expect(find.text('日常账本').hitTestable(), findsNothing);

        // Forgot PIN dialog opens cleanly above the lock shield inside TallyIsleApp!
        await tester.tap(find.byKey(const Key('app_lock_forgot_button')));
        await _settle(tester, 4);
        expect(find.text('忘记安全锁密码？'), findsOneWidget);
        await tester.tap(find.text('知道了'));
        await _settle(tester, 4);

        // Wrong PIN rejected, stays locked.
        for (final d in ['1', '1', '1', '1']) {
          await tester.tap(find.byKey(Key('app_lock_key_$d')));
          await _settle(tester, 4);
        }
        expect(find.byKey(const Key('app_lock_overlay')), findsOneWidget);
        expect(find.byKey(const Key('app_lock_message')), findsOneWidget);

        // Correct PIN ('2580') unlocks and reveals HomePage.
        for (final d in ['2', '5', '8', '0']) {
          await tester.tap(find.byKey(Key('app_lock_key_$d')));
          await _settle(tester, 4);
        }
        expect(find.byKey(const Key('app_lock_overlay')), findsNothing);
        expect(find.text('日常账本').hitTestable(), findsOneWidget);

        await closeCleanly();
      },
    );

    testWidgets(
      'RecordEditorPage saves location/discount/remark usage, RecordDetailPage opens receipt dialog, and AutomationBridge ingests live events',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(800, 1100));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final (db, closeCleanly) = _openTestDb(tester);
        final autoBridge = InMemoryAutoBillBridge();
        addTearDown(() => tester.runAsync(autoBridge.dispose));

        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [
              databaseProvider.overrideWith((ref) async => db),
              autoBillBridgeProvider.overrideWithValue(autoBridge),
            ],
            child: const TallyIsleApp(),
          ),
        );
        await _settle(tester);

        // 1. Enable frequentRemarks via DIY toolbar settings, then record an expense with remark, discount, and location.
        await tester.tap(find.byKey(const Key('add-record')));
        await _settle(tester);
        expect(find.byKey(const Key('editor-remarks-btn')), findsNothing);
        await tester.tap(find.byKey(const Key('editor-diy-toolbar-btn')));
        await _settle(tester);
        await tester.scrollUntilVisible(
          find.byKey(const Key('diy-switch-frequent_remarks')),
          160,
          scrollable: find.byType(Scrollable).last,
        );
        await _settle(tester, 4);
        await tester.tap(find.byKey(const Key('diy-switch-frequent_remarks')));
        await _settle(tester);
        await _goBack(tester);

        await tester.enterText(find.byKey(const Key('amount')), '35.00');
        await tester.tap(find.byKey(const Key('cat-餐饮')));
        await _settle(tester, 4);
        await tester.enterText(find.byKey(const Key('remark')), '星巴克拿铁');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();

        await tester.scrollUntilVisible(
          find.byKey(const Key('editor-discount-pill')),
          180,
          scrollable: find
              .descendant(
                of: find.byKey(const Key('editor-pill-toolbar')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.tap(find.byKey(const Key('editor-discount-pill')));
        await _settle(tester, 4);
        await tester.enterText(find.byKey(const Key('discount')), '5.00');
        await tester.tap(find.byKey(const Key('discount-confirm-btn')));
        await _settle(tester, 4);
        expect(find.text('优惠 ¥5.00'), findsOneWidget);

        await tester.scrollUntilVisible(
          find.byKey(const Key('record-location-tile')),
          180,
          scrollable: find
              .descendant(
                of: find.byKey(const Key('editor-pill-toolbar')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.tap(find.byKey(const Key('record-location-tile')));
        await _settle(tester, 4);
        await tester.enterText(
          find.byKey(const Key('loc-simple-name')),
          '静安嘉里中心',
        );
        await tester.tap(find.byKey(const Key('loc-save-btn')));
        await _settle(tester, 4);
        expect(find.text('静安嘉里中心'), findsOneWidget);

        await tester.tap(find.byKey(const Key('save')));
        await _settle(tester);

        // Verify HomePage recorded the bill and open RecordDetailPage.
        expect(find.text('星巴克拿铁'), findsOneWidget);
        await tester.tap(find.text('星巴克拿铁'));
        await _settle(tester);

        expect(find.byKey(const Key('detail-discount-tile')), findsOneWidget);
        expect(find.byKey(const Key('detail-location-tile')), findsOneWidget);
        expect(find.text('静安嘉里中心'), findsOneWidget);

        // 2. Open RecordReceiptDialog ("生成小票").
        await tester.tap(find.byKey(const Key('open-receipt-button')));
        await _settle(tester);
        expect(find.text('支出小票'), findsOneWidget);
        expect(find.byKey(const Key('receipt-amount-text')), findsOneWidget);
        await tester.ensureVisible(find.byKey(const Key('receipt-close-btn')));
        await tester.tap(find.byKey(const Key('receipt-close-btn')));
        await _settle(tester);
        await _goBack(tester);

        // 3. Re-open RecordEditorPage on 餐饮 -> Plan A frequent remarks panel opens
        // in bottom keypad slot via toggle button, and tapping chip fills remark & returns to keypad!
        await tester.tap(find.byKey(const Key('add-record')));
        await _settle(tester);
        await tester.tap(find.byKey(const Key('cat-餐饮')));
        await _settle(tester);
        expect(
          find.byKey(const Key('editor-remarks-toggle-btn')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('editor-frequent-remarks-panel')),
          findsNothing,
        );
        await tester.tap(find.byKey(const Key('editor-remarks-toggle-btn')));
        await _settle(tester, 4);
        expect(
          find.byKey(const Key('editor-frequent-remarks-panel')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('frequent_remark_chips')), findsOneWidget);
        expect(find.text('星巴克拿铁'), findsOneWidget);
        await tester.tap(find.text('星巴克拿铁'));
        await _settle(tester, 2);
        expect(find.byKey(const Key('record-custom-keypad')), findsOneWidget);
        await _goBack(tester);

        // 4. Live URL Scheme addbill + live Accessibility captured payment event via AutomationBridge.
        autoBridge.simulateDeepLink(
          'tallyisle://addbill?type=0&money=18.50&category=餐饮&remark=快捷深链午餐',
        );
        autoBridge.simulateCapturedEvent(
          const CapturedPaymentEvent(
            packageName: 'com.tencent.mm',
            rawText: '微信支付 瑞幸咖啡 付款成功 ¥9.90',
            capturedAtMs: 1762860000000,
          ),
        );
        await _settle(tester, 10);

        // Deep link bill booked on HomePage; captured payment queued as draft in AutoBill!
        expect(find.text('快捷深链午餐'), findsOneWidget);
        await tester.tap(find.text('更多'));
        await _settle(tester);
        await tester.scrollUntilVisible(
          find.byKey(const Key('me-auto-bill')),
          220,
          scrollable: find.byType(Scrollable).first,
        );
        await _settle(tester, 4);
        await tester.tap(find.byKey(const Key('me-auto-bill')));
        await _settle(tester);
        expect(find.textContaining('9.90'), findsWidgets);

        await closeCleanly();
      },
    );
  });
}
