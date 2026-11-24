import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:tallyisle/app/adaptive.dart';
import 'package:tallyisle/app/app.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/budget/budget_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/debt/debt_service.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/domain/ledger/asset_json.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/app_settings_rules.dart';
import 'package:tallyisle/domain/rules/billing_period.dart';
import 'package:tallyisle/domain/rules/budget_rules.dart';
import 'package:tallyisle/features/assets/asset_detail_page.dart';
import 'package:tallyisle/features/assets/assets_page.dart';
import 'package:tallyisle/features/backup/backup_providers.dart';
import 'package:tallyisle/features/home/home_page.dart';
import 'package:tallyisle/features/records/record_detail_page.dart';
import 'package:tallyisle/features/reminder/reminder_providers.dart';
import 'package:tallyisle/platform/notifications.dart';

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 40));
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets(
    'Desktop 1280x800 HomePage compact overview, Master-Detail pane, Esc close (yielding to dialogs), in-pane delete, and <1080px push fallback',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final db = AppDatabase(NativeDatabase.memory());
      final reminderScheduler = InMemoryReminderScheduler();
      final tempRoot = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('desk_p3_home_'),
      ))!;

      late int cashAssetId;
      late String r1Id;
      late String r2Id;
      final now = DateTime.now();
      final nowMs = now.millisecondsSinceEpoch;

      await tester.runAsync(() async {
        final ledger = LedgerService(db);
        final budgetService = BudgetService(db);
        final book = await (db.select(db.accountBooks)..limit(1)).getSingle();
        final expCats = await (db.select(
          db.recordCategories,
        )..where((t) => t.type.equals(RecordType.expense))).get();

        cashAssetId = await ledger.createAsset(
          commandId: 'seed-cash',
          name: '现金钱包',
          initial: Money.minor(BigInt.from(100000)),
        );

        final period = BillingPeriod.containing(now, book.startDay);
        final section = BudgetMode.monthly.sectionFor(period);
        await budgetService.upsertTotalBudget(
          commandId: 'seed-budget',
          bookId: book.id,
          section: section,
          amountMinor: BigInt.from(200000),
        );

        r1Id = await ledger.saveRecord(
          commandId: 'seed-r1',
          draft: RecordDraft(
            type: RecordType.expense,
            money: Money.minor(BigInt.from(4500)),
            bookId: book.id,
            recordTime: nowMs - 60000,
            categoryId: expCats.first.id,
            assetId: cashAssetId,
            remark: '午饭便当',
          ),
        );
        r2Id = await ledger.saveRecord(
          commandId: 'seed-r2',
          draft: RecordDraft(
            type: RecordType.expense,
            money: Money.minor(BigInt.from(1200)),
            bookId: book.id,
            recordTime: nowMs,
            categoryId: expCats.length > 1 ? expCats[1].id : expCats.first.id,
            assetId: cashAssetId,
            remark: '地铁通勤',
          ),
        );
      });

      var closed = false;
      Future<void> cleanUp() async {
        if (closed) return;
        closed = true;
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester);
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(reminderScheduler.dispose);
        await tester.runAsync(() async {
          if (await tempRoot.exists()) {
            await tempRoot.delete(recursive: true);
          }
        });
      }

      addTearDown(cleanUp);

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            reminderSchedulerProvider.overrideWithValue(reminderScheduler),
            backupLocalDirectoryOverrideProvider.overrideWithValue(
              () async => Directory(p.join(tempRoot.path, 'local')),
            ),
            backupAttachmentsDirectoryOverrideProvider.overrideWithValue(
              () async => Directory(p.join(tempRoot.path, 'att')),
            ),
          ],
          child: const TallyIsleApp(),
        ),
      );
      await _settle(tester);
      expect(tester.takeException(), isNull);

      // Compact desktop overview preserves all critical keys and side-by-side metrics + budget.
      expect(find.byKey(const Key('home-desktop-overview')), findsOneWidget);
      expect(
        find.byKey(const Key('home-asset-summary-banner')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('sum-balance')), findsOneWidget);
      expect(find.byKey(const Key('sum-expense')), findsOneWidget);
      expect(find.byKey(const Key('sum-income')), findsOneWidget);
      expect(find.byKey(const Key('budget_summary_card')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('sum-expense'))).data,
        '57.00',
      );
      expect(find.byKey(const Key('home-record-detail-pane')), findsNothing);

      // Verify showHomeAssetSummaryBanner & showHomeBudgetCard toggles + Dark mode are honored.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(Scaffold).first),
      );
      await tester.runAsync(() async {
        final settingsSvc = await container.read(
          appSettingsServiceProvider.future,
        );
        await settingsSvc.saveSettings(
          commandId: 'hide-home-banners',
          settings: AppSettings.defaults.copyWith(
            showHomeAssetSummaryBanner: false,
            showHomeBudgetCard: false,
            themeMode: AppThemeModePreference.dark,
          ),
        );
      });
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('home-asset-summary-banner')), findsNothing);
      expect(find.byKey(const Key('budget_summary_card')), findsNothing);

      await tester.runAsync(() async {
        final settingsSvc = await container.read(
          appSettingsServiceProvider.future,
        );
        await settingsSvc.saveSettings(
          commandId: 'restore-home-banners',
          settings: AppSettings.defaults,
        );
      });
      await _settle(tester);
      expect(
        find.byKey(const Key('home-asset-summary-banner')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('budget_summary_card')), findsOneWidget);

      // Click first bill -> opens 392px right detail pane without pushing a full-screen route.
      await tester.tap(find.byKey(Key('record-$r1Id')));
      await _settle(tester);
      expect(tester.takeException(), isNull);

      final detailPane = find.byKey(const Key('home-record-detail-pane'));
      expect(detailPane, findsOneWidget);
      final paneWidth = tester.getSize(detailPane).width;
      expect(paneWidth, inInclusiveRange(380.0, 400.0));
      expect(find.byKey(const Key('close-record-detail-pane')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('detail-amount'))).data,
        '-45.00',
      );
      expect(
        find.descendant(of: detailPane, matching: find.text('午饭便当')),
        findsOneWidget,
      );

      // Verify 1080x600 minimum widescreen viewport with pane open has zero overflow!
      tester.view.physicalSize = const Size(1080, 600);
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(detailPane, findsOneWidget);

      tester.view.physicalSize = const Size(1280, 800);
      await _settle(tester);

      // Click second bill -> detail pane seamlessly switches to r2 in-place.
      await tester.tap(find.byKey(Key('record-$r2Id')));
      await _settle(tester);
      expect(
        tester.widget<Text>(find.byKey(const Key('detail-amount'))).data,
        '-12.00',
      );
      expect(
        find.descendant(of: detailPane, matching: find.text('地铁通勤')),
        findsOneWidget,
      );

      // Open Refund dialog inside pane -> pressing Esc closes ONLY the dialog, keeping pane open!
      await tester.tap(find.byKey(const Key('add-refund')));
      await _settle(tester);
      expect(find.text('添加退款'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(find.text('添加退款'), findsNothing);
      expect(detailPane, findsOneWidget);

      // Now with no dialog open, pressing Esc closes the right detail pane!
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(detailPane, findsNothing);

      // Re-open r2, verify close button works, then re-open and delete in-pane -> auto-closes pane.
      await tester.tap(find.byKey(Key('record-$r2Id')));
      await _settle(tester);
      expect(detailPane, findsOneWidget);
      await tester.tap(find.byKey(const Key('close-record-detail-pane')));
      await _settle(tester);
      expect(detailPane, findsNothing);

      await tester.tap(find.byKey(Key('record-$r2Id')));
      await _settle(tester);
      expect(detailPane, findsOneWidget);
      await tester.scrollUntilVisible(
        find.descendant(
          of: detailPane,
          matching: find.byKey(const Key('delete')),
        ),
        160,
        scrollable: find.descendant(
          of: detailPane,
          matching: find.byType(Scrollable),
        ),
      );
      await _settle(tester);
      await tester.tap(
        find.descendant(
          of: detailPane,
          matching: find.byKey(const Key('delete')),
        ),
      );
      await _settle(tester);
      expect(find.text('删除这笔账单？'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await _settle(tester);

      // Pane closed automatically and expense total updated from 57.00 to 45.00!
      expect(detailPane, findsNothing);
      expect(find.byKey(Key('record-$r2Id')), findsNothing);
      expect(
        tester.widget<Text>(find.byKey(const Key('sum-expense'))).data,
        '45.00',
      );

      // Shrink window below 1080px (900x700) -> falls back to single-column route push!
      tester.view.physicalSize = const Size(900, 700);
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('home-record-detail-pane')), findsNothing);

      await tester.tap(find.byKey(Key('record-$r1Id')));
      await _settle(tester);
      expect(find.byType(RecordDetailPage), findsOneWidget);
      expect(find.byKey(const Key('home-record-detail-pane')), findsNothing);
      expect(
        tester.widget<Text>(find.byKey(const Key('detail-amount'))).data,
        '-45.00',
      );
      await tester.tap(find.byType(BackButton));
      await _settle(tester);
      expect(find.byKey(Key('record-$r1Id')), findsOneWidget);

      await cleanUp();
    },
  );

  testWidgets(
    'Desktop HomePage bill row hover quick icons and right-click context menu actions',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final db = AppDatabase(NativeDatabase.memory());
      late int assetId;
      late int catId;
      late String recordId;

      await tester.runAsync(() async {
        final ledger = LedgerService(db);
        final book = await (db.select(db.accountBooks)..limit(1)).getSingle();
        final cat = (await (db.select(
          db.recordCategories,
        )..where((t) => t.type.equals(RecordType.expense))).get()).first;
        catId = cat.id;
        assetId = await ledger.createAsset(
          commandId: 'hover-asset',
          name: '招行卡',
          initial: Money.minor(BigInt.from(50000)),
        );
        recordId = await ledger.saveRecord(
          commandId: 'hover-record',
          draft: RecordDraft(
            type: RecordType.expense,
            money: Money.minor(BigInt.from(3680)),
            bookId: book.id,
            recordTime: DateTime.now().millisecondsSinceEpoch,
            categoryId: catId,
            assetId: assetId,
            remark: '精品咖啡',
          ),
        );
      });

      String? lastPushedUri;
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(path: '/', builder: (_, _) => const HomePage()),
          GoRoute(
            path: '/record/new',
            builder: (_, state) {
              lastPushedUri = state.uri.toString();
              return Scaffold(
                appBar: AppBar(title: const Text('NEW_RECORD_ROUTE')),
                body: Text(state.uri.toString()),
              );
            },
          ),
          GoRoute(
            path: '/record/:id/edit',
            builder: (_, state) {
              lastPushedUri = state.uri.toString();
              return Scaffold(
                appBar: AppBar(title: const Text('EDIT_RECORD_ROUTE')),
                body: Text(state.uri.toString()),
              );
            },
          ),
          GoRoute(
            path: '/record/:id',
            builder: (_, state) =>
                RecordDetailPage(recordId: state.pathParameters['id']!),
          ),
        ],
      );

      var closed = false;
      Future<void> cleanUp() async {
        if (closed) return;
        closed = true;
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester);
        await tester.pump(const Duration(seconds: 1));
        router.dispose();
      }

      addTearDown(cleanUp);

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: DesktopAdaptiveScope(
            isDesktop: true,
            child: MaterialApp.router(routerConfig: router),
          ),
        ),
      );
      await _settle(tester);

      final rowFinder = find.byKey(Key('record-$recordId'));
      expect(rowFinder, findsOneWidget);
      expect(find.byKey(Key('record-hover-edit-$recordId')), findsNothing);
      expect(find.byKey(Key('record-hover-detail-$recordId')), findsNothing);

      // Hover mouse over the bill row -> quick icons appear!
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await tester.pump();
      await mouse.moveTo(tester.getCenter(rowFinder));
      await _settle(tester);

      expect(find.byKey(Key('record-hover-edit-$recordId')), findsOneWidget);
      expect(find.byKey(Key('record-hover-detail-$recordId')), findsOneWidget);

      // Click hover '查看详情' -> opens right detail pane.
      await tester.tap(find.byKey(Key('record-hover-detail-$recordId')));
      await _settle(tester);
      expect(find.byKey(const Key('home-record-detail-pane')), findsOneWidget);

      // Move mouse back onto row and click hover '编辑' -> /record/$id/edit.
      await mouse.moveTo(tester.getCenter(rowFinder));
      await _settle(tester);
      await tester.tap(find.byKey(Key('record-hover-edit-$recordId')));
      await _settle(tester);
      expect(find.text('EDIT_RECORD_ROUTE'), findsOneWidget);
      expect(lastPushedUri, '/record/$recordId/edit');
      router.pop();
      await _settle(tester);

      // Right-click bill row -> context menu shows all 5 actions!
      await tester.tap(rowFinder, buttons: kSecondaryMouseButton);
      await _settle(tester);
      expect(find.text('查看详情'), findsOneWidget);
      expect(find.text('编辑'), findsWidgets);
      expect(find.text('复制再记一笔'), findsOneWidget);
      expect(find.text('生成小票'), findsOneWidget);
      expect(find.text('删除'), findsWidgets);

      // Select '复制再记一笔' -> navigates to /record/new with prefilled draft query!
      await tester.tap(find.text('复制再记一笔'));
      await _settle(tester);
      expect(find.text('NEW_RECORD_ROUTE'), findsOneWidget);
      final dupUri = Uri.parse(lastPushedUri!);
      expect(dupUri.path, '/record/new');
      expect(dupUri.queryParameters['type'], '${RecordType.expense}');
      expect(dupUri.queryParameters['cat'], '$catId');
      expect(dupUri.queryParameters['asset'], '$assetId');
      expect(dupUri.queryParameters['amount'], '36.80');
      expect(dupUri.queryParameters['remark'], '精品咖啡');
      router.pop();
      await _settle(tester);

      // Right-click -> '生成小票' -> opens receipt dialog cleanly, Esc closes only dialog.
      await tester.tap(rowFinder, buttons: kSecondaryMouseButton);
      await _settle(tester);
      await tester.tap(find.text('生成小票'));
      await _settle(tester);
      expect(find.byType(Dialog), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(find.byKey(const Key('home-record-detail-pane')), findsOneWidget);

      // Right-click -> '删除' -> deletes bill and auto-closes detail pane!
      await tester.tap(rowFinder, buttons: kSecondaryMouseButton);
      await _settle(tester);
      await tester.tap(find.text('删除').last);
      await _settle(tester);
      expect(find.text('删除这笔账单？'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await _settle(tester);

      expect(find.byKey(Key('record-$recordId')), findsNothing);
      expect(find.byKey(const Key('home-record-detail-pane')), findsNothing);
      expect(find.text('本期暂无账单'), findsOneWidget);

      await cleanUp();
    },
  );

  testWidgets(
    'Desktop 1280x800 AssetsPage empty Master-Detail guide renders cleanly',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final db = AppDatabase(NativeDatabase.memory());

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: DesktopAdaptiveScope(
            isDesktop: true,
            child: const MaterialApp(home: AssetsPage()),
          ),
        ),
      );
      await _settle(tester);
      expect(tester.takeException(), isNull);

      final masterPane = find.byKey(const Key('assets-master-pane'));
      final detailPane = find.byKey(const Key('assets-detail-pane'));
      expect(masterPane, findsOneWidget);
      expect(detailPane, findsOneWidget);
      expect(tester.getSize(masterPane).width, 380.0);
      expect(find.byKey(const Key('assets-quick-bar')), findsOneWidget);
      expect(find.byKey(const Key('empty-add-normal-asset')), findsOneWidget);
      expect(find.byKey(const Key('empty-add-credit-asset')), findsOneWidget);
      expect(find.text('暂无可展示的账户流水'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'Desktop 1280x800 AssetsPage Master-Detail live switching across fund & credit accounts, reconciliation mode, balance adjust, debt route, and <1080px fallback',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final db = AppDatabase(NativeDatabase.memory());
      final reminderScheduler = InMemoryReminderScheduler();
      final tempRoot = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('desk_p3_assets_'),
      ))!;

      await tester.runAsync(() async {
        final ledger = LedgerService(db);
        final debtSvc = DebtService(db);
        final book = await (db.select(db.accountBooks)..limit(1)).getSingle();
        final expCat = (await (db.select(
          db.recordCategories,
        )..where((t) => t.type.equals(RecordType.expense))).get()).first;

        final savingsId = await ledger.createAsset(
          commandId: 'seed-savings',
          name: '招行储蓄卡',
          initial: Money.minor(BigInt.from(100000)),
        );
        final creditId = await ledger.createAsset(
          commandId: 'seed-credit',
          name: '招行信用卡',
          type: AssetType.credit,
          initial: Money.zero(),
          limit: Money.minor(BigInt.from(1000000)),
          creditInfo: CreditInfo({
            'bill_day': 10,
            'repayment_day': 28,
          }).encode(),
        );
        await debtSvc.createDebt(
          commandId: 'seed-debt',
          subType: AssetType.debtLend,
          name: '朋友借款',
          principal: Money.minor(BigInt.from(50000)),
          bookId: book.id,
          startDate: DateTime.now().millisecondsSinceEpoch - 86400000,
        );

        await ledger.saveRecord(
          commandId: 'seed-sav-exp',
          draft: RecordDraft(
            type: RecordType.expense,
            money: Money.minor(BigInt.from(8000)),
            bookId: book.id,
            recordTime: DateTime.now().millisecondsSinceEpoch - 30000,
            categoryId: expCat.id,
            assetId: savingsId,
            remark: '超市采购',
          ),
        );
        await ledger.saveRecord(
          commandId: 'seed-crd-exp',
          draft: RecordDraft(
            type: RecordType.expense,
            money: Money.minor(BigInt.from(32000)),
            bookId: book.id,
            recordTime: DateTime.now().millisecondsSinceEpoch,
            categoryId: expCat.id,
            assetId: creditId,
            remark: '数码配件',
          ),
        );
      });

      var closed = false;
      Future<void> cleanUp() async {
        if (closed) return;
        closed = true;
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester);
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(reminderScheduler.dispose);
        await tester.runAsync(() async {
          if (await tempRoot.exists()) {
            await tempRoot.delete(recursive: true);
          }
        });
      }

      addTearDown(cleanUp);

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            reminderSchedulerProvider.overrideWithValue(reminderScheduler),
            backupLocalDirectoryOverrideProvider.overrideWithValue(
              () async => Directory(p.join(tempRoot.path, 'local')),
            ),
            backupAttachmentsDirectoryOverrideProvider.overrideWithValue(
              () async => Directory(p.join(tempRoot.path, 'att')),
            ),
          ],
          child: const TallyIsleApp(),
        ),
      );
      await _settle(tester);

      // Navigate to Assets branch via desktop sidebar.
      await tester.tap(find.byKey(const Key('nav-slot-assets')));
      await _settle(tester);
      expect(tester.takeException(), isNull);

      final masterPane = find.byKey(const Key('assets-master-pane'));
      final detailPane = find.byKey(const Key('assets-detail-pane'));
      expect(masterPane, findsOneWidget);
      expect(detailPane, findsOneWidget);
      expect(tester.getSize(masterPane).width, 380.0);

      // Normal accounts precede credit accounts -> '招行储蓄卡' is auto-selected!
      expect(
        find.descendant(
          of: detailPane,
          matching: find.byKey(const Key('asset-detail-balance')),
        ),
        findsOneWidget,
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('asset-detail-balance'))).data,
        '920.00',
      );
      expect(
        find.descendant(
          of: detailPane,
          matching: find.byKey(const Key('fund-tab-flows')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: detailPane,
          matching: find.byKey(const Key('fund-tab-statements')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: detailPane, matching: find.text('累计 1 笔流水')),
        findsOneWidget,
      );

      // Switch fund account to '月度账单' tab -> renders 2-column grid + sticky year switcher!
      await tester.tap(
        find.descendant(
          of: detailPane,
          matching: find.byKey(const Key('fund-tab-statements')),
        ),
      );
      await _settle(tester);
      expect(
        find.descendant(
          of: detailPane,
          matching: find.byKey(const Key('fund-statements-two-column-grid')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: detailPane,
          matching: find.byKey(const Key('statement-year-label')),
        ),
        findsOneWidget,
      );
      // Switch back to '流水明细' tab before toggling reconMode.
      await tester.tap(
        find.descendant(
          of: detailPane,
          matching: find.byKey(const Key('fund-tab-flows')),
        ),
      );
      await _settle(tester);

      // Toggle reconciliation mode ON in right pane -> shows running balance '余额：920.00'!
      await tester.tap(
        find.descendant(
          of: detailPane,
          matching: find.byKey(const Key('reconciliation-switch')),
        ),
      );
      await _settle(tester);
      expect(
        find.descendant(of: detailPane, matching: find.text('余额：920.00')),
        findsOneWidget,
      );

      // Click '招行信用卡' in left tree -> right pane seamlessly switches to credit card flows
      // & unified dual-metric header with zero vertical jump on sticky bar, resets _reconMode cleanly (B-15),
      // and shows '欠款 320.00' immediately on first screen once toggled on!
      final fundStickyTop = tester
          .getTopLeft(
            find.descendant(
              of: detailPane,
              matching: find.byKey(const Key('asset-sticky-control-bar')),
            ),
          )
          .dy;

      await tester.tap(find.byKey(const Key('asset-招行信用卡')));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(
        find.descendant(
          of: detailPane,
          matching: find.byKey(const Key('credit-repay')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: detailPane,
          matching: find.byKey(const Key('credit-usable-limit')),
        ),
        findsOneWidget,
      );

      final creditStickyTop = tester
          .getTopLeft(
            find.descendant(
              of: detailPane,
              matching: find.byKey(const Key('asset-sticky-control-bar')),
            ),
          )
          .dy;
      // Verify visual skeleton alignment: Fund vs Credit header heights align tightly!
      expect((creditStickyTop - fundStickyTop).abs(), lessThanOrEqualTo(6.0));

      final creditReconSwitch = find.descendant(
        of: detailPane,
        matching: find.byKey(const Key('reconciliation-switch')),
      );
      expect(creditReconSwitch.hitTestable(), findsOneWidget);
      expect(tester.widget<Switch>(creditReconSwitch).value, isFalse);
      await tester.tap(creditReconSwitch);
      await _settle(tester);
      expect(
        find.descendant(of: detailPane, matching: find.text('-320.00')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: detailPane, matching: find.text('欠款 320.00')),
        findsWidgets,
      );
      expect(find.textContaining('欠款 -'), findsNothing);

      // Switch to '账期账单' tab inside 1280x800 right detail pane -> renders 2-column grid!
      await tester.tap(
        find.descendant(
          of: detailPane,
          matching: find.byKey(const Key('credit-tab-statements')),
        ),
      );
      await _settle(tester);
      expect(
        find.descendant(
          of: detailPane,
          matching: find.byKey(const Key('credit-statements-two-column-grid')),
        ),
        findsOneWidget,
      );

      // Switch back to '招行储蓄卡' and adjust balance from right pane's asset-menu -> updates both panes!
      await tester.tap(find.byKey(const Key('asset-招行储蓄卡')));
      await _settle(tester);
      await tester.tap(
        find.descendant(
          of: detailPane,
          matching: find.byKey(const Key('asset-menu')),
        ),
      );
      await _settle(tester);
      await tester.tap(find.byKey(const Key('menu-adjust')));
      await _settle(tester);
      await tester.enterText(find.byKey(const Key('adjust-amount')), '1500');
      await tester.tap(find.byKey(const Key('adjust-save')));
      await _settle(tester);

      expect(
        tester.widget<Text>(find.byKey(const Key('asset-detail-balance'))).data,
        '1500.00',
      );
      expect(
        find.descendant(of: masterPane, matching: find.text('1500.00')),
        findsOneWidget,
      );

      // Click debt item '朋友借款' in left tree -> pushes /debts/:id route instead of loading in right pane!
      await tester.scrollUntilVisible(
        find.byKey(const Key('asset-朋友借款')),
        180,
        scrollable: find
            .descendant(of: masterPane, matching: find.byType(Scrollable))
            .first,
      );
      await _settle(tester);
      await tester.tap(find.byKey(const Key('asset-朋友借款')));
      await _settle(tester);
      expect(find.text('朋友借款'), findsWidgets);
      await tester.tap(find.byType(BackButton));
      await _settle(tester);

      // Shrink window below 1080px (900x700) -> falls back to single-column route push!
      tester.view.physicalSize = const Size(900, 700);
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('assets-detail-pane')), findsNothing);

      await tester.tap(find.byKey(const Key('asset-招行储蓄卡')));
      await _settle(tester);
      expect(find.byType(AssetDetailPage), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await _settle(tester);

      await cleanUp();
    },
  );

  testWidgets(
    'Desktop AssetsPage right-click context menu routes and selection',
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final db = AppDatabase(NativeDatabase.memory());
      late int cashId;
      late int bankId;

      await tester.runAsync(() async {
        final ledger = LedgerService(db);
        cashId = await ledger.createAsset(
          commandId: 'ctx-cash',
          name: '零钱袋',
          initial: Money.minor(BigInt.from(20000)),
        );
        bankId = await ledger.createAsset(
          commandId: 'ctx-bank',
          name: '工资卡',
          initial: Money.minor(BigInt.from(800000)),
        );
      });

      String? lastPushedUri;
      final router = GoRouter(
        initialLocation: '/assets',
        routes: [
          GoRoute(path: '/assets', builder: (_, _) => const AssetsPage()),
          GoRoute(
            path: '/record/new',
            builder: (_, state) {
              lastPushedUri = state.uri.toString();
              return Scaffold(
                appBar: AppBar(title: const Text('NEW_RECORD_FOR_ASSET')),
                body: Text(state.uri.toString()),
              );
            },
          ),
          GoRoute(
            path: '/assets/:id/edit',
            builder: (_, state) {
              lastPushedUri = state.uri.toString();
              return Scaffold(
                appBar: AppBar(title: const Text('EDIT_ASSET_ROUTE')),
                body: Text(state.uri.toString()),
              );
            },
          ),
          GoRoute(
            path: '/stats/trend',
            builder: (_, state) {
              lastPushedUri = state.uri.toString();
              return Scaffold(
                appBar: AppBar(title: const Text('ASSET_TREND_ROUTE')),
                body: Text(state.uri.toString()),
              );
            },
          ),
        ],
      );

      var closed = false;
      Future<void> cleanUp() async {
        if (closed) return;
        closed = true;
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester);
        await tester.pump(const Duration(seconds: 1));
        router.dispose();
      }

      addTearDown(cleanUp);

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: DesktopAdaptiveScope(
            isDesktop: true,
            child: MaterialApp.router(routerConfig: router),
          ),
        ),
      );
      await _settle(tester);

      // '工资卡' was created second so it has smaller sort and is initially selected (8000.00).
      expect(
        tester.widget<Text>(find.byKey(const Key('asset-detail-balance'))).data,
        '8000.00',
      );

      // Right-click '零钱袋' -> '查看账户流水' switches right detail pane to '零钱袋' (200.00)!
      final cashTile = find.byKey(const Key('asset-零钱袋'));
      await tester.tap(cashTile, buttons: kSecondaryMouseButton);
      await _settle(tester);
      expect(find.text('查看账户流水'), findsOneWidget);
      expect(find.text('记一笔到此账户'), findsOneWidget);
      expect(find.text('编辑账户'), findsOneWidget);
      expect(find.text('资产趋势'), findsOneWidget);

      await tester.tap(find.text('查看账户流水'));
      await _settle(tester);
      expect(
        tester.widget<Text>(find.byKey(const Key('asset-detail-balance'))).data,
        '200.00',
      );

      // Right-click '零钱袋' -> '记一笔到此账户' -> /record/new?assetId=...
      await tester.tap(cashTile, buttons: kSecondaryMouseButton);
      await _settle(tester);
      await tester.tap(find.text('记一笔到此账户'));
      await _settle(tester);
      expect(find.text('NEW_RECORD_FOR_ASSET'), findsOneWidget);
      final newRecUri = Uri.parse(lastPushedUri!);
      expect(newRecUri.path, '/record/new');
      expect(newRecUri.queryParameters['assetId'], '$cashId');
      expect(newRecUri.queryParameters['asset'], '$cashId');
      router.pop();
      await _settle(tester);

      // Right-click '工资卡' -> '编辑账户' -> /assets/:id/edit
      final bankTile = find.byKey(const Key('asset-工资卡'));
      await tester.tap(bankTile, buttons: kSecondaryMouseButton);
      await _settle(tester);
      await tester.tap(find.text('编辑账户'));
      await _settle(tester);
      expect(find.text('EDIT_ASSET_ROUTE'), findsOneWidget);
      expect(lastPushedUri, '/assets/$bankId/edit');
      router.pop();
      await _settle(tester);

      // Right-click '工资卡' -> '资产趋势' -> /stats/trend?assetId=:id
      await tester.tap(bankTile, buttons: kSecondaryMouseButton);
      await _settle(tester);
      await tester.tap(find.text('资产趋势'));
      await _settle(tester);
      expect(find.text('ASSET_TREND_ROUTE'), findsOneWidget);
      expect(lastPushedUri, '/stats/trend?assetId=$bankId');
      router.pop();
      await _settle(tester);

      await cleanUp();
    },
  );

  testWidgets(
    'Mobile 360x640 Android keeps 100% original HomePage & AssetsPage single-column layout without desktop panes or context menus',
    variant: TargetPlatformVariant.only(TargetPlatform.android),
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final db = AppDatabase(NativeDatabase.memory());
      late String recId;
      await tester.runAsync(() async {
        final ledger = LedgerService(db);
        final book = await (db.select(db.accountBooks)..limit(1)).getSingle();
        final cat = (await (db.select(
          db.recordCategories,
        )..where((t) => t.type.equals(RecordType.expense))).get()).first;
        final assetId = await ledger.createAsset(
          commandId: 'mob-asset',
          name: '手机现金',
          initial: Money.minor(BigInt.from(30000)),
        );
        recId = await ledger.saveRecord(
          commandId: 'mob-rec',
          draft: RecordDraft(
            type: RecordType.expense,
            money: Money.minor(BigInt.from(1500)),
            bookId: book.id,
            recordTime: DateTime.now().millisecondsSinceEpoch,
            categoryId: cat.id,
            assetId: assetId,
          ),
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
      expect(tester.takeException(), isNull);

      expect(find.byKey(const Key('home-desktop-overview')), findsNothing);
      expect(find.byKey(const Key('home-record-detail-pane')), findsNothing);
      expect(find.byType(ListTile), findsWidgets);

      // Right-click on mobile does NOT open desktop context menu.
      await tester.tap(
        find.byKey(Key('record-$recId')),
        buttons: kSecondaryMouseButton,
      );
      await _settle(tester);
      expect(find.text('复制再记一笔'), findsNothing);

      // Switch to Assets tab -> mobile single-column layout + FAB.
      await tester.tap(find.byKey(const Key('nav-slot-assets')));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('assets-master-pane')), findsNothing);
      expect(find.byKey(const Key('assets-detail-pane')), findsNothing);
      expect(find.byType(FloatingActionButton), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      await tester.pump(const Duration(seconds: 1));
    },
  );
}
