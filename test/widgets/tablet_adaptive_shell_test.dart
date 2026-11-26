import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tallyisle/app/adaptive.dart';
import 'package:tallyisle/app/app.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/catalog/catalog_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/features/automation/automation_providers.dart';
import 'package:tallyisle/features/backup/backup_providers.dart';
import 'package:tallyisle/features/records/desktop_record_editor_dialog.dart';
import 'package:tallyisle/features/reminder/reminder_providers.dart';
import 'package:tallyisle/features/security/app_lock_providers.dart';
import 'package:tallyisle/platform/app_widgets.dart';
import 'package:tallyisle/platform/auto_bill_bridge.dart';
import 'package:tallyisle/platform/biometrics.dart';
import 'package:tallyisle/platform/notifications.dart';

Future<void> _settle(WidgetTester tester, [int ticks = 12]) async {
  await tester.pump();
  for (var i = 0; i < ticks; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('Tablet dual-axis pure classification & DesktopAdaptive probes', () {
    test(
      'isMobileTabletViewport distinguishes Android/iOS/mobile tablets from phone landscape, split-screen, and desktop OSes',
      () {
        for (final mobilePlatform in const <TargetPlatform>[
          TargetPlatform.android,
          TargetPlatform.iOS,
          TargetPlatform.fuchsia,
        ]) {
          // Landscape tablet (1180x820) & portrait tablet (800x1180) & foldable (764x882)
          expect(
            isMobileTabletViewport(
              platform: mobilePlatform,
              viewportSize: const Size(1180, 820),
            ),
            isTrue,
          );
          expect(
            isMobileTabletViewport(
              platform: mobilePlatform,
              viewportSize: const Size(800, 1180),
            ),
            isTrue,
          );
          expect(
            isMobileTabletViewport(
              platform: mobilePlatform,
              viewportSize: const Size(764, 882),
            ),
            isTrue,
          );

          // Narrow split-screen (500x1024), phone landscape (844x390), default 800x600
          expect(
            isMobileTabletViewport(
              platform: mobilePlatform,
              viewportSize: const Size(500, 1024),
            ),
            isFalse,
          );
          expect(
            isMobileTabletViewport(
              platform: mobilePlatform,
              viewportSize: const Size(844, 390),
            ),
            isFalse,
          );
          expect(
            isMobileTabletViewport(
              platform: mobilePlatform,
              viewportSize: const Size(800, 600),
            ),
            isFalse,
          );
        }

        // Desktop targets stay false on isMobileTabletViewport
        for (final desktopPlatform in const <TargetPlatform>[
          TargetPlatform.linux,
          TargetPlatform.windows,
          TargetPlatform.macOS,
        ]) {
          expect(
            isMobileTabletViewport(
              platform: desktopPlatform,
              viewportSize: const Size(1180, 820),
            ),
            isFalse,
          );
        }
      },
    );

    testWidgets(
      'DesktopAdaptive preserves isDesktop==false on tablets while unlocking adaptive workspace, side nav, expanded workspace, and centered modal rules',
      (tester) async {
        late bool probeIsDesktop;
        late bool probeIsTablet;
        late bool probeAdaptiveWorkspace;
        late bool probeSideNav;
        late bool probeExpanded;
        late bool probeExpandedAlias;
        late bool probeCenteredModal;
        late bool probeMobileWidgets;

        Widget buildProbe({
          required TargetPlatform platform,
          required Size size,
        }) {
          return MaterialApp(
            home: Theme(
              data: ThemeData(platform: platform, useMaterial3: true),
              child: MediaQuery(
                data: MediaQueryData(size: size),
                child: DesktopAdaptiveScope(
                  isDesktop: isDesktopTargetPlatform(platform),
                  child: Builder(
                    builder: (context) {
                      probeIsDesktop = DesktopAdaptive.isDesktop(context);
                      probeIsTablet = DesktopAdaptive.isTablet(context);
                      probeAdaptiveWorkspace =
                          DesktopAdaptive.useAdaptiveWorkspace(context);
                      probeSideNav = DesktopAdaptive.useSideNavigation(context);
                      probeExpanded = DesktopAdaptive.isExpandedDesktop(
                        context,
                      );
                      probeExpandedAlias = DesktopAdaptive.isExpandedWorkspace(
                        context,
                      );
                      probeCenteredModal =
                          DesktopAdaptive.useCenteredModalDialog(context);
                      probeMobileWidgets =
                          DesktopAdaptive.supportsMobileHomeWidgets(context);
                      return const SizedBox.shrink();
                    },
                  ),
                ),
              ),
            ),
          );
        }

        // 1. Android 1180x820 landscape tablet
        await tester.pumpWidget(
          buildProbe(
            platform: TargetPlatform.android,
            size: const Size(1180, 820),
          ),
        );
        expect(probeIsDesktop, isFalse);
        expect(probeIsTablet, isTrue);
        expect(probeAdaptiveWorkspace, isTrue);
        expect(probeSideNav, isTrue);
        expect(probeExpanded, isTrue);
        expect(probeExpandedAlias, isTrue);
        expect(probeCenteredModal, isTrue);
        expect(probeMobileWidgets, isTrue);

        // 2. iPad (iOS) 800x1180 portrait tablet
        await tester.pumpWidget(
          buildProbe(platform: TargetPlatform.iOS, size: const Size(800, 1180)),
        );
        expect(probeIsDesktop, isFalse);
        expect(probeIsTablet, isTrue);
        expect(probeAdaptiveWorkspace, isTrue);
        expect(probeSideNav, isTrue);
        expect(probeExpanded, isFalse);
        expect(probeExpandedAlias, isFalse);
        expect(probeCenteredModal, isTrue);
        expect(probeMobileWidgets, isFalse);

        // 3. Compact split-screen on large tablet (650x1024: isTablet true, width < 720)
        await tester.pumpWidget(
          buildProbe(
            platform: TargetPlatform.android,
            size: const Size(650, 1024),
          ),
        );
        expect(probeIsDesktop, isFalse);
        expect(probeIsTablet, isTrue);
        expect(probeAdaptiveWorkspace, isTrue);
        expect(probeSideNav, isFalse);
        expect(probeExpanded, isFalse);
        expect(probeCenteredModal, isFalse);

        // 4. Narrow split-screen (500x1024) & phone landscape (844x390)
        for (final size in const <Size>[Size(500, 1024), Size(844, 390)]) {
          await tester.pumpWidget(
            buildProbe(platform: TargetPlatform.android, size: size),
          );
          expect(probeIsDesktop, isFalse);
          expect(probeIsTablet, isFalse);
          expect(probeAdaptiveWorkspace, isFalse);
          expect(probeSideNav, isFalse);
          expect(probeExpanded, isFalse);
          expect(probeCenteredModal, isFalse);
        }
      },
    );
  });

  testWidgets(
    'Android tablet adapts across 1180x820 landscape (208px sidebar, Master-Detail, centered record dialog with touch keypad, mobile widgets visible), 800x1180 portrait (76px rail), 500x1024 split-screen, and 844x390 phone landscape',
    variant: TargetPlatformVariant.only(TargetPlatform.android),
    (tester) async {
      tester.view.physicalSize = const Size(1180, 820);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final db = AppDatabase(NativeDatabase.memory());
      final reminderScheduler = InMemoryReminderScheduler();
      final autoBridge = InMemoryAutoBillBridge();
      final widgetBridge = InMemoryAppWidgetBridge();
      final bio = InMemoryBiometricAuthenticator();
      final tempRoot = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('tablet_android_shell_'),
      ))!;

      late final String rec1Id;
      late final String rec2Id;
      await tester.runAsync(() async {
        final catalog = CatalogService(db);
        await catalog.createBook(commandId: 'tab-book-2', name: '家庭账本');

        final ledger = LedgerService(db);
        final debitId = await ledger.createAsset(
          commandId: 'tab-asset-debit',
          name: '招商储蓄卡',
          initial: Money.parse('8600.00'),
        );
        await ledger.createAsset(
          commandId: 'tab-asset-credit',
          name: '建设信用卡',
          type: AssetType.credit,
          initial: Money.parse('-320.00'),
          limit: Money.parse('20000.00'),
        );

        final cats = await db.select(db.recordCategories).get();
        final foodCat = cats.firstWhere((c) => c.name == '餐饮').id;
        final trafficCat = cats.firstWhere((c) => c.name == '交通').id;
        final now = DateTime.now();
        final noonMs = DateTime(
          now.year,
          now.month,
          now.day,
          12,
          0,
        ).millisecondsSinceEpoch;

        rec1Id = await ledger.saveRecord(
          commandId: 'tab-rec-1',
          draft: RecordDraft(
            type: RecordType.expense,
            money: Money.parse('28.00'),
            bookId: 1,
            recordTime: noonMs,
            categoryId: foodCat,
            assetId: debitId,
            remark: '平板测试拉面',
          ),
        );
        rec2Id = await ledger.saveRecord(
          commandId: 'tab-rec-2',
          draft: RecordDraft(
            type: RecordType.expense,
            money: Money.parse('6.00'),
            bookId: 1,
            recordTime: noonMs + 60000,
            categoryId: trafficCat,
            assetId: debitId,
            remark: '平板测试地铁',
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
        await autoBridge.dispose();
        await widgetBridge.dispose();
        await tester.runAsync(reminderScheduler.dispose);
        await tester.runAsync(db.close);
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
            autoBillBridgeProvider.overrideWithValue(autoBridge),
            appWidgetBridgeProvider.overrideWithValue(widgetBridge),
            biometricAuthenticatorProvider.overrideWithValue(bio),
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

      // --- Scenario A: 1180x820 Landscape Tablet ---
      // 1. Bypasses 960px single-column frame and renders 208px expanded sidebar
      expect(find.byKey(const Key('desktop_widescreen_frame')), findsNothing);
      expect(find.byKey(const Key('desktop-sidebar')), findsOneWidget);
      expect(find.byKey(const Key('shell-bottom-bar')), findsNothing);
      expect(
        tester.getSize(find.byKey(const Key('desktop-sidebar'))).width,
        208,
      );
      // Touch tablet hides desktop-only keyboard shortcut badges
      expect(find.text('Ctrl+N'), findsNothing);

      // 2. HomePage Master-Detail: tapping records opens & switches right detail pane in-place
      expect(find.byKey(const Key('home-record-detail-pane')), findsNothing);
      await tester.tap(find.byKey(Key('record-$rec1Id')));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('home-record-detail-pane')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('home-record-detail-pane')),
          matching: find.textContaining('平板测试拉面'),
        ),
        findsWidgets,
      );

      await tester.tap(find.byKey(Key('record-$rec2Id')));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(
        find.descendant(
          of: find.byKey(const Key('home-record-detail-pane')),
          matching: find.textContaining('平板测试地铁'),
        ),
        findsWidgets,
      );

      // 3. Book switcher opens centered dialog on tablet landscape
      await tester.tap(find.byKey(const Key('desktop-book-switcher')));
      await _settle(tester);
      expect(
        find.byKey(const Key('desktop-book-switcher-dialog')),
        findsOneWidget,
      );
      await tester.tap(find.text('日常账本').last);
      await _settle(tester);

      // 4. Tapping '记一笔' opens centered modal dialog WITH touch RecordKeypad!
      await tester.tap(find.byKey(const Key('add-record')));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      final recordDialog = find.byKey(
        const Key('desktop-record-editor-dialog'),
      );
      expect(recordDialog, findsOneWidget);
      expect(find.byKey(const Key('record-custom-keypad')), findsOneWidget);
      final dialogSize = tester.getSize(
        find
            .descendant(of: recordDialog, matching: find.byType(ConstrainedBox))
            .first,
      );
      expect(dialogSize.width, lessThanOrEqualTo(kDesktopRecordDialogMaxWidth));
      expect(
        dialogSize.height,
        lessThanOrEqualTo(kTabletRecordDialogMaxHeight),
      );
      await tester.tap(find.byType(BackButton).last);
      await _settle(tester);
      expect(recordDialog, findsNothing);

      // 5. StatsPage widescreen 2-column Bento grid & CalendarPage split pane
      await tester.tap(find.byKey(const Key('nav-slot-stats')));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('stats-desktop-grid')), findsOneWidget);

      await tester.tap(find.byKey(const Key('desktop-nav-calendar')));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('calendar-desktop-split')), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await _settle(tester);

      // 6. AssetsPage Master-Detail: touch tap selects right pane in-place + highlight,
      // long-press drag listener preserved, and '点击自定义图标' header text removed!
      await tester.tap(find.byKey(const Key('nav-slot-assets')));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('assets-master-pane')), findsOneWidget);
      expect(find.byKey(const Key('assets-detail-pane')), findsOneWidget);
      expect(find.text('点击自定义图标'), findsNothing);
      expect(find.byType(ReorderableDelayedDragStartListener), findsWidgets);

      final debitTileFinder = find.byKey(const Key('asset-招商储蓄卡'));
      final creditTileFinder = find.byKey(const Key('asset-建设信用卡'));
      expect(tester.widget<ListTile>(debitTileFinder).selected, isTrue);
      expect(tester.widget<ListTile>(creditTileFinder).selected, isFalse);

      // Tap second account -> updates right detail pane & selection highlight without route push
      await tester.tap(creditTileFinder);
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('assets-master-pane')), findsOneWidget);
      expect(tester.widget<ListTile>(debitTileFinder).selected, isFalse);
      expect(tester.widget<ListTile>(creditTileFinder).selected, isTrue);
      expect(
        find.descendant(
          of: find.byKey(const Key('assets-detail-pane')),
          matching: find.text('建设信用卡'),
        ),
        findsOneWidget,
      );

      // 7. MePage ('更多') Master-Detail keeps Android '桌面小组件' visible!
      await tester.tap(find.byKey(const Key('nav-slot-more')));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('me-desktop-directory')), findsOneWidget);
      expect(find.byKey(const Key('me-desktop-content-pane')), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const Key('me-widgets')),
        180,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('me-desktop-directory')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await _settle(tester, 4);
      expect(find.byKey(const Key('me-widgets')), findsOneWidget);
      expect(find.text('桌面小组件'), findsWidgets);

      // --- Scenario B: 800x1180 Portrait Tablet -> 76px NavigationRail ---
      tester.view.physicalSize = const Size(800, 1180);
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('desktop-sidebar')), findsNothing);
      expect(find.byKey(const Key('desktop-nav-rail')), findsOneWidget);
      expect(find.byKey(const Key('shell-bottom-bar')), findsNothing);
      expect(
        tester.getSize(find.byKey(const Key('desktop-nav-rail'))).width,
        76,
      );
      expect(find.byKey(const Key('me-desktop-card-grid')), findsOneWidget);

      await tester.tap(find.byKey(const Key('nav-slot-home')));
      await _settle(tester);
      expect(tester.takeException(), isNull);

      // --- Scenario C: 500x1024 Split-Screen Narrow Window -> 5-slot Bottom Bar ---
      tester.view.physicalSize = const Size(500, 1024);
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('desktop-sidebar')), findsNothing);
      expect(find.byKey(const Key('desktop-nav-rail')), findsNothing);
      expect(find.byKey(const Key('shell-bottom-bar')), findsOneWidget);

      // --- Scenario D: 844x390 Phone Landscape -> Stays Phone Bottom Bar ---
      tester.view.physicalSize = const Size(844, 390);
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('desktop-sidebar')), findsNothing);
      expect(find.byKey(const Key('desktop-nav-rail')), findsNothing);
      expect(find.byKey(const Key('shell-bottom-bar')), findsOneWidget);

      await cleanUp();
    },
  );

  testWidgets(
    'iPad (TargetPlatform.iOS) adapts across 1180x820 landscape, 800x1180 portrait (relaxed 820px record modal with touch keypad), and 500x1024 Split View while hiding Android-only widgets',
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    (tester) async {
      tester.view.physicalSize = const Size(1180, 820);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final db = AppDatabase(NativeDatabase.memory());
      final reminderScheduler = InMemoryReminderScheduler();
      final tempRoot = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('tablet_ipad_shell_'),
      ))!;

      var closed = false;
      Future<void> cleanUp() async {
        if (closed) return;
        closed = true;
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester);
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(reminderScheduler.dispose);
        await tester.runAsync(db.close);
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

      // 1180x820 iPad landscape: 208px sidebar + Master-Detail MePage without Android home widgets
      expect(find.byKey(const Key('desktop-sidebar')), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const Key('desktop-sidebar'))).width,
        208,
      );
      await tester.tap(find.byKey(const Key('nav-slot-more')));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('me-desktop-directory')), findsOneWidget);
      expect(find.byKey(const Key('me-widgets')), findsNothing);

      // 800x1180 iPad portrait: 76px rail + centered 820px maxHeight record dialog with touch keypad
      tester.view.physicalSize = const Size(800, 1180);
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('desktop-nav-rail')), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const Key('desktop-nav-rail'))).width,
        76,
      );

      await tester.tap(find.byKey(const Key('add-record')));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      final dialogFinder = find.byKey(
        const Key('desktop-record-editor-dialog'),
      );
      expect(dialogFinder, findsOneWidget);
      expect(find.byKey(const Key('record-custom-keypad')), findsOneWidget);
      final dialogBox = tester.widget<ConstrainedBox>(
        find
            .descendant(
              of: dialogFinder,
              matching: find.byWidgetPredicate(
                (w) =>
                    w is ConstrainedBox &&
                    w.constraints.maxWidth == kDesktopRecordDialogMaxWidth,
              ),
            )
            .first,
      );
      expect(dialogBox.constraints.maxHeight, kTabletRecordDialogMaxHeight);

      await tester.tap(find.byType(BackButton).last);
      await _settle(tester);

      // 500x1024 iPad Split View: falls back to 5-slot bottom bar
      tester.view.physicalSize = const Size(500, 1024);
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('desktop-nav-rail')), findsNothing);
      expect(find.byKey(const Key('shell-bottom-bar')), findsOneWidget);

      await cleanUp();
    },
  );
}
