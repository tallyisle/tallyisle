import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart'
    show PointerScrollEvent, kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tallyisle/app/adaptive.dart';
import 'package:tallyisle/app/app.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/backup/s3_client.dart';
import 'package:tallyisle/data/backup/webdav_client.dart';
import 'package:tallyisle/data/budget/budget_service.dart';
import 'package:tallyisle/data/catalog/catalog_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/billing_period.dart';
import 'package:tallyisle/domain/rules/budget_rules.dart';
import 'package:tallyisle/domain/rules/category_stats.dart';
import 'package:tallyisle/domain/rules/cloud_sync_rules.dart';
import 'package:tallyisle/features/backup/backup_providers.dart';
import 'package:tallyisle/features/budget/budget_page.dart';
import 'package:tallyisle/features/budget/budget_providers.dart';
import 'package:tallyisle/features/calendar/calendar_page.dart';
import 'package:tallyisle/features/common/desktop_modal_page.dart';
import 'package:tallyisle/features/reminder/reminder_providers.dart';
import 'package:tallyisle/features/settings/settings_page.dart';
import 'package:tallyisle/features/stats/annual_report_page.dart';
import 'package:tallyisle/features/stats/category_stats_page.dart';
import 'package:tallyisle/features/stats/category_stats_providers.dart';
import 'package:tallyisle/features/stats/tag_stats_page.dart';
import 'package:tallyisle/features/stats/tag_stats_providers.dart';
import 'package:tallyisle/platform/notifications.dart';

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 40));
  }
}

void _sendTrackpadHorizontalScroll(
  WidgetTester tester,
  Offset position,
  double dx,
) {
  tester.binding.handlePointerEvent(
    PointerScrollEvent(position: position, scrollDelta: Offset(dx, 0)),
  );
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets(
    'B-11, B-14, B-24b & SettingsPage: DesktopGlobalShortcuts dispatches across pushed routes, yields to branch popups, prevents duplicate /search, and resets Stats budget offset on active re-select',
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
        () => Directory.systemTemp.createTemp('shell_periods_b11_'),
      ))!;

      late String tagId;
      late String billId;
      await tester.runAsync(() async {
        final ledger = LedgerService(db);
        final catalog = CatalogService(db);
        final budgetSvc = BudgetService(db);
        final cats = await (db.select(
          db.recordCategories,
        )..where((t) => t.type.equals(RecordType.expense))).get();
        tagId = await catalog.createTag(
          commandId: 'seed-tag',
          name: '通勤标签',
          color: '#1E88E5',
        );
        final cashId = await ledger.createAsset(
          commandId: 'seed-cash',
          name: '日常卡',
          initial: Money.parse('5000.00'),
        );
        billId = await ledger.saveRecord(
          commandId: 'seed-bill',
          draft: RecordDraft(
            type: RecordType.expense,
            money: Money.parse('42.00'),
            bookId: 1,
            recordTime: DateTime.now().millisecondsSinceEpoch,
            categoryId: cats.first.id,
            assetId: cashId,
            remark: '早高峰地铁',
            tagIds: [tagId],
          ),
        );
        final curMonth = BillingPeriod.containing(DateTime.now(), 1);
        await budgetSvc.upsertTotalBudget(
          commandId: 'seed-budget',
          bookId: 1,
          section: BudgetMode.monthly.sectionFor(curMonth),
          amountMinor: BigInt.from(300000),
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
        await tester.runAsync(db.close);
        await tester.runAsync(() async {
          if (await tempRoot.exists()) {
            await tempRoot.delete(recursive: true);
          }
        });
      }

      addTearDown(cleanUp);

      late ProviderContainer container;
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
          child: Consumer(
            builder: (context, ref, _) {
              container = ProviderScope.containerOf(context, listen: false);
              return const TallyIsleApp();
            },
          ),
        ),
      );
      await _settle(tester);

      // 1. B-14 & B-13: Right-click bill row inside Home shell branch opens PopupMenu;
      // while branch popup is active, `[` and `Ctrl+2` must yield!
      final billRow = find.byKey(Key('record-$billId'));
      expect(billRow, findsOneWidget);
      final clickCenter = tester.getCenter(billRow);
      await tester.tapAt(clickCenter, buttons: kSecondaryMouseButton);
      await _settle(tester);
      expect(find.text('复制再记一笔'), findsOneWidget);
      // B-13: PopupMenu X position should align near clickCenter (not shifted +208px right).
      final menuItemRect = tester.getRect(find.text('复制再记一笔'));
      expect(menuItemRect.left, lessThan(clickCenter.dx + 80));

      await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
      await _settle(tester);
      expect(container.read(periodOffsetProvider), 0);

      // Dismiss popup menu via Esc -> shortcuts resume!
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(find.text('复制再记一笔'), findsNothing);

      // 2. B-11: Ctrl+F pushes /search; pressing Ctrl+F and Ctrl+K again must NOT push duplicates!
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await _settle(tester);
      expect(find.byKey(const Key('search-keyword-field')), findsOneWidget);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await _settle(tester);

      // Single Esc pops /search cleanly back to Home (proving only 1 /search was pushed).
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(find.byKey(const Key('search-keyword-field')), findsNothing);

      // 3. B-11: Period shortcuts on `/calendar`, plus `Ctrl+1` returns from `/calendar` to `'/'`!
      await tester.tap(find.byKey(const Key('desktop-nav-calendar')));
      await _settle(tester);
      expect(find.text('日历视图'), findsOneWidget);
      expect(container.read(calendarMonthOffsetProvider), 0);

      await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
      await _settle(tester);
      expect(container.read(calendarMonthOffsetProvider), -1);
      expect(container.read(periodOffsetProvider), 0);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await _settle(tester);
      expect(container.read(calendarMonthOffsetProvider), 0);

      await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
      await _settle(tester);
      expect(container.read(calendarMonthOffsetProvider), -1);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
      await _settle(tester);
      expect(container.read(calendarMonthOffsetProvider), 0);

      // Ctrl+1 from pushed `/calendar` returns to Home branch root `'/'`!
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await _settle(tester);
      expect(find.text('日历视图'), findsNothing);
      expect(find.byKey(const Key('home-desktop-overview')), findsOneWidget);

      // 4. B-24b: Navigate to `/stats`, step budget card to -1, re-tap active `nav-slot-stats` -> resets to 0!
      await tester.tap(find.byKey(const Key('nav-slot-stats')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('budget_card_period_prev')));
      await _settle(tester);
      expect(container.read(budgetOffsetProvider), -1);

      await tester.tap(find.byKey(const Key('nav-slot-stats')));
      await _settle(tester);
      expect(container.read(budgetOffsetProvider), 0);

      // 5. B-11: Period shortcuts on `/budget`, `/stats/category`, `/stats/tags`, `/stats/tag/:id`, `/stats/annual`
      await tester.tap(find.byKey(const Key('stats-budget-action')));
      await _settle(tester);
      expect(find.byKey(const Key('budget_page')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
      await _settle(tester);
      expect(container.read(budgetOffsetProvider), -1);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
      await _settle(tester);
      expect(container.read(budgetOffsetProvider), 0);

      // Ctrl+2 from pushed `/budget` returns to `/stats`!
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await _settle(tester);
      expect(find.byKey(const Key('budget_page')), findsNothing);
      expect(find.byKey(const Key('stats-hub-page')), findsOneWidget);

      // `/stats/category` shortcuts (active in month/year, blocked in custom)
      await tester.tap(find.text('查看完整分析'));
      await _settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
      await _settle(tester);
      expect(container.read(categoryStatsOffsetProvider), -1);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
      await _settle(tester);
      expect(container.read(categoryStatsOffsetProvider), 0);

      container
          .read(categoryStatsPeriodModeProvider.notifier)
          .setRangeKind(CategoryStatsPeriodMode.custom);
      await _settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
      await _settle(tester);
      expect(container.read(categoryStatsOffsetProvider), 0);
      await tester.tap(find.byType(BackButton));
      await _settle(tester);

      // `/stats/tags` & `/stats/tag/:id` shortcuts (blocked in `all`, active in `month`)
      await tester.tap(find.byKey(const Key('stats-tag-all-rankings-btn')));
      await _settle(tester);
      expect(
        container.read(tagStatsPeriodModeProvider),
        TagStatsPeriodMode.all,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
      await _settle(tester);
      expect(container.read(tagStatsOffsetProvider), 0);

      await tester.tap(find.byKey(const Key('tag-rankings-mode-month')));
      await _settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
      await _settle(tester);
      expect(container.read(tagStatsOffsetProvider), -1);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
      await _settle(tester);
      expect(container.read(tagStatsOffsetProvider), 0);

      await tester.tap(find.byKey(Key('tag-ranking-row-$tagId')));
      await _settle(tester);
      expect(find.byKey(const Key('tag-detail-stats-page')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
      await _settle(tester);
      expect(container.read(tagStatsOffsetProvider), -1);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
      await _settle(tester);
      expect(container.read(tagStatsOffsetProvider), 0);

      // Return to `/stats` via Ctrl+2, then test `/stats/annual` shortcuts
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await _settle(tester);

      final thisYear = DateTime.now().year;
      await tester.tap(find.byKey(const Key('stats-annual-action')));
      await _settle(tester);
      expect(container.read(annualReportYearProvider), thisYear);
      await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
      await _settle(tester);
      expect(container.read(annualReportYearProvider), thisYear - 1);
      expect(find.text('${thisYear - 1}年'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
      await _settle(tester);
      expect(container.read(annualReportYearProvider), thisYear);

      await cleanUp();
    },
  );

  testWidgets(
    'B-07b & SettingsPage shortcuts card: desktop sidebar scopes cloudSyncCursor to active targetFingerprint',
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

      const davA = WebDavConfig(
        serverUrl: 'https://dav-a.example.com/dav',
        username: 'u',
        password: 'p',
        remoteDirectory: 'TallyIsle',
      );
      const s3B = S3Config(
        endpoint: 'https://s3.example.com',
        region: 'auto',
        bucket: 'new-bucket',
        accessKeyId: 'ak',
        secretAccessKey: 'sk',
      );
      final syncedCursorForDavA = LocalSyncCursor(
        lastSyncedRevision: 7,
        lastSyncedDataSha256: 'a' * 64,
        lastSyncedAtMs: DateTime(2026, 11, 18, 9, 30).millisecondsSinceEpoch,
        targetFingerprint: davA.targetFingerprint,
      );

      var activeBackend = CloudBackendType.webdav;
      late StateSetter rebuildHost;

      var closed = false;
      Future<void> cleanUp() async {
        if (closed) return;
        closed = true;
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester);
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(reminderScheduler.dispose);
        await tester.runAsync(db.close);
      }

      addTearDown(cleanUp);

      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) {
            rebuildHost = setState;
            return ProviderScope(
              key: ValueKey(activeBackend),
              retry: (_, _) => null,
              overrides: [
                databaseProvider.overrideWith((ref) async => db),
                reminderSchedulerProvider.overrideWithValue(reminderScheduler),
                webDavConfigProvider.overrideWith(
                  (ref) => Stream<WebDavConfig>.value(davA),
                ),
                s3ConfigProvider.overrideWith(
                  (ref) => Stream<S3Config>.value(s3B),
                ),
                cloudSyncSettingsProvider.overrideWith(
                  (ref) => Stream<CloudSyncSettings>.value(
                    CloudSyncSettings(
                      backend: activeBackend,
                      explicitBackend: true,
                      deviceId: 'dev-1',
                    ),
                  ),
                ),
                cloudSyncCursorProvider.overrideWith(
                  (ref) => Stream<LocalSyncCursor>.value(syncedCursorForDavA),
                ),
              ],
              child: const TallyIsleApp(),
            );
          },
        ),
      );
      await _settle(tester);

      // Matching targetFingerprint -> shows synced timestamp & r7 tooltip
      expect(find.text('WebDAV · 11-18 09:30'), findsOneWidget);

      // Switch active target to S3 (different targetFingerprint) -> scopedToTarget clears stale timestamp/r7!
      rebuildHost(() => activeBackend = CloudBackendType.s3);
      await _settle(tester);
      expect(find.text('S3 对象存储 · 待同步'), findsOneWidget);
      expect(find.textContaining('09:30'), findsNothing);

      // Unconfigured S3 (empty targetFingerprint) or loading WebDAV config with legacy null-fingerprint cursor must NEVER leak prior rN/timestamp!
      final legacyCursor = LocalSyncCursor(
        lastSyncedRevision: 9,
        lastSyncedDataSha256: 'b' * 64,
        lastSyncedAtMs: DateTime(2026, 11, 18, 9, 30).millisecondsSinceEpoch,
      );
      await tester.pumpWidget(
        ProviderScope(
          key: const ValueKey('unconfigured-s3-scope'),
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            reminderSchedulerProvider.overrideWithValue(reminderScheduler),
            webDavConfigProvider.overrideWith(
              (ref) => const Stream<WebDavConfig>.empty(),
            ),
            s3ConfigProvider.overrideWith(
              (ref) => Stream<S3Config>.value(const S3Config()),
            ),
            cloudSyncSettingsProvider.overrideWith(
              (ref) => Stream<CloudSyncSettings>.value(
                const CloudSyncSettings(
                  backend: CloudBackendType.s3,
                  explicitBackend: true,
                  deviceId: 'dev-1',
                ),
              ),
            ),
            cloudSyncCursorProvider.overrideWith(
              (ref) => Stream<LocalSyncCursor>.value(legacyCursor),
            ),
          ],
          child: const TallyIsleApp(),
        ),
      );
      await _settle(tester);
      expect(find.text('S3 对象存储 · 待同步'), findsOneWidget);
      expect(find.textContaining('09:30'), findsNothing);

      // Verify SettingsPage _DesktopShortcutsCard mentions 明细 / 日历 / 预算 / 统计
      await tester.pumpWidget(
        ProviderScope(
          key: const ValueKey('settings-shortcuts-scope'),
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: const MaterialApp(home: SettingsPage()),
        ),
      );
      await _settle(tester);
      await tester.scrollUntilVisible(
        find.byKey(const Key('desktop_shortcuts_card')),
        220,
      );
      await _settle(tester);
      expect(find.text('切换账期（明细 / 日历 / 预算 / 统计）'), findsOneWidget);
      expect(find.text('回到当期（明细 / 日历 / 预算 / 统计）'), findsOneWidget);

      await cleanUp();
    },
  );

  testWidgets(
    'HomePage: 回本月 button (mobile 360dp @ 1.2x & desktop), horizontal period swipe & trackpad debounce, and B-15 stale detail pane clear',
    (tester) async {
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });

      final db = AppDatabase(NativeDatabase.memory());
      final reminderScheduler = InMemoryReminderScheduler();
      late String billId;
      await tester.runAsync(() async {
        final ledger = LedgerService(db);
        final cat = (await (db.select(
          db.recordCategories,
        )..where((t) => t.type.equals(RecordType.expense))).get()).first;
        billId = await ledger.saveRecord(
          commandId: 'home-swipe-bill',
          draft: RecordDraft(
            type: RecordType.expense,
            money: Money.parse('88.00'),
            bookId: 1,
            recordTime: DateTime.now().millisecondsSinceEpoch,
            categoryId: cat.id,
            remark: '生鲜水果',
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
        await tester.runAsync(db.close);
      }

      addTearDown(cleanUp);

      // 1. Mobile 360x640 @ 1.2x text scale
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      tester.platformDispatcher.textScaleFactorTestValue = 1.2;

      late ProviderContainer container;
      var forceDesktop = false;
      late StateSetter setMode;

      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) {
            setMode = setState;
            return ProviderScope(
              key: ValueKey(forceDesktop),
              retry: (_, _) => null,
              overrides: [
                databaseProvider.overrideWith((ref) async => db),
                reminderSchedulerProvider.overrideWithValue(reminderScheduler),
                desktopModeOverrideProvider.overrideWith((ref) => forceDesktop),
              ],
              child: Consumer(
                builder: (context, ref, _) {
                  container = ProviderScope.containerOf(context, listen: false);
                  return const TallyIsleApp();
                },
              ),
            );
          },
        ),
      );
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('home-reset-period-btn')), findsNothing);

      // Swipe right on HomePage body -> steps to previous period (-1) & shows `回本月` with zero overflow!
      await tester.drag(find.byType(CustomScrollView), const Offset(180, 0));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(container.read(periodOffsetProvider), -1);
      expect(find.byKey(const Key('home-reset-period-btn')), findsOneWidget);

      // Tap `回本月` pill -> resets to 0 and hides pill!
      await tester.tap(find.byKey(const Key('home-reset-period-btn')));
      await _settle(tester);
      expect(container.read(periodOffsetProvider), 0);
      expect(find.byKey(const Key('home-reset-period-btn')), findsNothing);

      // Swipe left -> steps to next period (+1); tap period title -> opens Year-Month picker!
      await tester.drag(find.byType(CustomScrollView), const Offset(-180, 0));
      await _settle(tester);
      expect(container.read(periodOffsetProvider), 1);
      await tester.tap(find.byKey(const Key('home-period-picker-trigger')));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('ym-picker-jump-current')), findsOneWidget);
      await tester.tap(find.byKey(const Key('ym-picker-jump-current')));
      await _settle(tester);
      expect(container.read(periodOffsetProvider), 0);

      // Open Home Year-Month picker again, toggle year grid, jump to previous year's March
      final nowPeriod = BillingPeriod.containing(DateTime.now(), 1);
      final targetYear = nowPeriod.year - 1;
      await tester.tap(find.byKey(const Key('home-period-picker-trigger')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('ym-picker-toggle-year-grid')));
      await _settle(tester);
      await tester.tap(find.byKey(Key('ym-picker-year-$targetYear')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('ym-picker-month-3')));
      await _settle(tester);
      expect(
        container.read(periodOffsetProvider),
        (targetYear - nowPeriod.year) * 12 + (3 - nowPeriod.month),
      );
      expect(find.text('$targetYear年3月'), findsOneWidget);
      expect(find.byKey(const Key('home-reset-period-btn')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('home-reset-period-btn')));
      await _settle(tester);
      expect(container.read(periodOffsetProvider), 0);

      // 2. Desktop 1280x800: trackpad horizontal scroll cooldown + B-15 detail pane clear
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      tester.view.physicalSize = const Size(1280, 800);
      setMode(() => forceDesktop = true);
      await _settle(tester);
      expect(tester.takeException(), isNull);

      // Open bill in right detail pane
      await tester.tap(find.byKey(Key('record-$billId')));
      await _settle(tester);
      expect(find.byKey(const Key('home-record-detail-pane')), findsOneWidget);

      // Trackpad two-finger horizontal scroll (2 rapid events within 50ms -> debounced to 1 step!)
      final listCenter = tester.getCenter(find.byType(CustomScrollView).first);
      _sendTrackpadHorizontalScroll(tester, listCenter, -40);
      await tester.pump(const Duration(milliseconds: 50));
      _sendTrackpadHorizontalScroll(tester, listCenter, -40);
      await _settle(tester);
      expect(container.read(periodOffsetProvider), -1);
      // B-15: Period change immediately cleared _selectedRecordId and closed detail pane!
      expect(find.byKey(const Key('home-record-detail-pane')), findsNothing);
      expect(find.byKey(const Key('home-reset-period-btn')), findsOneWidget);

      // After >320ms cooldown, trackpad scroll right steps back to 0!
      await tester.pump(const Duration(milliseconds: 350));
      _sendTrackpadHorizontalScroll(tester, listCenter, 40);
      await _settle(tester);
      expect(container.read(periodOffsetProvider), 0);

      // Re-open bill in right detail pane, then delete externally via LedgerService -> B-15 auto-closes pane!
      await tester.tap(find.byKey(Key('record-$billId')));
      await _settle(tester);
      expect(find.byKey(const Key('home-record-detail-pane')), findsOneWidget);

      await tester.runAsync(() async {
        final ledger = LedgerService(db);
        await ledger.deleteRecord(
          commandId: 'ext-delete-bill',
          recordId: billId,
        );
      });
      await _settle(tester);
      expect(find.byKey(const Key('home-record-detail-pane')), findsNothing);

      // Desktop medium (900x700) also renders `回本月` cleanly when offset != 0
      tester.view.physicalSize = const Size(900, 700);
      container.read(periodOffsetProvider.notifier).previous();
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('home-reset-period-btn')), findsOneWidget);
      await tester.tap(find.byKey(const Key('home-reset-period-btn')));
      await _settle(tester);
      expect(container.read(periodOffsetProvider), 0);

      await cleanUp();
    },
  );

  testWidgets(
    'CalendarPage: PageView.builder follow-finger month swipe, active-page Key guard mid-drag, short-month day clamp, and trackpad debounce',
    (tester) async {
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final db = AppDatabase(NativeDatabase.memory());
      var closed = false;
      Future<void> cleanUp() async {
        if (closed) return;
        closed = true;
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester);
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(db.close);
      }

      addTearDown(cleanUp);

      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;

      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: Consumer(
            builder: (context, ref, _) {
              container = ProviderScope.containerOf(context, listen: false);
              return const MaterialApp(home: CalendarPage());
            },
          ),
        ),
      );
      await _settle(tester);

      expect(find.byKey(const Key('calendar-month-pageview')), findsOneWidget);
      expect(find.byKey(const Key('calendar-grid')), findsOneWidget);
      expect(container.read(calendarMonthOffsetProvider), 0);

      // Mid-drag test-key guard: drag halfway so two month grids are mounted simultaneously!
      final gridCenter = tester.getCenter(
        find.byKey(const Key('calendar-grid')),
      );
      final dragGesture = await tester.startGesture(gridCenter);
      await dragGesture.moveBy(const Offset(24, 0));
      await tester.pump(const Duration(milliseconds: 16));
      await dragGesture.moveBy(const Offset(120, 0));
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.byKey(const Key('calendar-grid')), findsOneWidget);
      expect(find.byKey(const Key('calendar-cell-15')), findsOneWidget);

      // Complete swipe right (>50% of 390px viewport) -> lands on previous month (-1)!
      await dragGesture.moveBy(const Offset(140, 0));
      await tester.pump(const Duration(milliseconds: 16));
      await dragGesture.up();
      await tester.pumpAndSettle();
      expect(container.read(calendarMonthOffsetProvider), -1);
      expect(find.byKey(const Key('calendar-grid')), findsOneWidget);

      // Tap `calendar-today-button` -> jumps back to 0!
      await tester.tap(find.byKey(const Key('calendar-today-button')));
      await _settle(tester);
      expect(container.read(calendarMonthOffsetProvider), 0);

      // Tap calendar period header -> opens Year-Month picker, jumps cleanly & syncs PageView!
      final now = DateTime.now();
      final pickedCalYear = now.year - 1;
      await tester.tap(find.byKey(const Key('calendar-period-picker-trigger')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('ym-picker-prev-year')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('ym-picker-month-4')));
      await _settle(tester);
      final expectedPickedOffset =
          (pickedCalYear - now.year) * 12 + (4 - now.month);
      expect(container.read(calendarMonthOffsetProvider), expectedPickedOffset);
      expect(find.text('$pickedCalYear年4月'), findsOneWidget);
      expect(find.byKey(const Key('calendar-grid')), findsOneWidget);
      // Horizontal swipe right immediately after picker jump steps cleanly to March without glitch!
      await tester.drag(
        find.byKey(const Key('calendar-month-pageview')),
        const Offset(300, 0),
      );
      await tester.pumpAndSettle();
      expect(
        container.read(calendarMonthOffsetProvider),
        expectedPickedOffset - 1,
      );
      expect(find.text('$pickedCalYear年3月'), findsOneWidget);
      await tester.tap(find.byKey(const Key('calendar-today-button')));
      await _settle(tester);
      expect(container.read(calendarMonthOffsetProvider), 0);

      // Jump to January of current year (31 days), select day 31, then swipe left to February (28/29 days) -> clamps safely!
      final janOffset = (1 - now.month);
      container.read(calendarMonthOffsetProvider.notifier).setOffset(janOffset);
      await _settle(tester);
      expect(find.text('${now.year}年1月'), findsOneWidget);
      await tester.tap(find.byKey(const Key('calendar-cell-31')));
      await _settle(tester);
      expect(find.textContaining('1月31日'), findsOneWidget);

      // Swipe left on PageView to February (janOffset + 1)
      await tester.drag(
        find.byKey(const Key('calendar-month-pageview')),
        const Offset(-300, 0),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(container.read(calendarMonthOffsetProvider), janOffset + 1);
      final febDays = DateTime(now.year, 3, 0).day;
      expect(find.text('${now.year}年2月'), findsOneWidget);
      expect(find.textContaining('2月$febDays日'), findsOneWidget);

      // Desktop expanded split-pane (1280x800) + trackpad debounce
      tester.view.physicalSize = const Size(1280, 800);
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: DesktopAdaptiveScope(
            isDesktop: true,
            child: Consumer(
              builder: (context, ref, _) {
                container = ProviderScope.containerOf(context, listen: false);
                return const MaterialApp(home: CalendarPage());
              },
            ),
          ),
        ),
      );
      await _settle(tester);
      expect(find.byKey(const Key('calendar-desktop-split')), findsOneWidget);
      expect(find.byKey(const Key('calendar-grid')), findsOneWidget);

      final startOffset = container.read(calendarMonthOffsetProvider);
      final deskGridCenter = tester.getCenter(
        find.byKey(const Key('calendar-grid')),
      );
      _sendTrackpadHorizontalScroll(tester, deskGridCenter, 45);
      await tester.pump(const Duration(milliseconds: 40));
      _sendTrackpadHorizontalScroll(tester, deskGridCenter, 45);
      await _settle(tester);
      expect(container.read(calendarMonthOffsetProvider), startOffset + 1);

      // Resize across <1080px (900x700) ⇄ >=1080px (1280x800) while at offset -2:
      // PageView must stay synced on page 11998 so Key('calendar-grid') matches 1 widget showing month -2!
      await tester.pump(const Duration(milliseconds: 350));
      tester.view.physicalSize = const Size(900, 700);
      await _settle(tester);
      expect(find.byKey(const Key('calendar-desktop-split')), findsNothing);
      await tester.tap(find.byKey(const Key('calendar-today-button')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('calendar-prev-month')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('calendar-prev-month')));
      await _settle(tester);
      expect(container.read(calendarMonthOffsetProvider), -2);
      final minus2Month = container.read(calendarMonthForOffsetProvider(-2));
      expect(
        find.text('${minus2Month.year}年${minus2Month.month}月'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('calendar-grid')), findsOneWidget);

      // Widen 900x700 -> 1280x800 (singleColumnBody -> calendar-desktop-split)
      tester.view.physicalSize = const Size(1280, 800);
      await _settle(tester);
      expect(find.byKey(const Key('calendar-desktop-split')), findsOneWidget);
      expect(container.read(calendarMonthOffsetProvider), -2);
      expect(
        find.text('${minus2Month.year}年${minus2Month.month}月'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('calendar-grid')), findsOneWidget);
      expect(find.byKey(const Key('calendar-cell-15')), findsOneWidget);

      // Narrow 1280x800 -> 900x700 (calendar-desktop-split -> singleColumnBody)
      tester.view.physicalSize = const Size(900, 700);
      await _settle(tester);
      expect(find.byKey(const Key('calendar-desktop-split')), findsNothing);
      expect(container.read(calendarMonthOffsetProvider), -2);
      expect(
        find.text('${minus2Month.year}年${minus2Month.month}月'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('calendar-grid')), findsOneWidget);
      expect(find.byKey(const Key('calendar-cell-15')), findsOneWidget);

      await cleanUp();
    },
  );

  testWidgets(
    'BudgetPage, CategoryStatsPage (with _TrendChartCard scrub isolation & drawerEdgeDragWidth=0), TagStatsPages, AnnualReportPage 2-tab PageView, B-16, and B-24',
    (tester) async {
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;

      final db = AppDatabase(NativeDatabase.memory());
      late String soloTagId;
      await tester.runAsync(() async {
        final ledger = LedgerService(db);
        final catalog = CatalogService(db);
        final budgetSvc = BudgetService(db);
        final expCat = (await (db.select(
          db.recordCategories,
        )..where((t) => t.type.equals(RecordType.expense))).get()).first;
        final incCat = (await (db.select(
          db.recordCategories,
        )..where((t) => t.type.equals(RecordType.income))).get()).first;

        soloTagId = await catalog.createTag(
          commandId: 'seed-solo-tag',
          name: '学习成长',
          color: '#43A047',
        );
        final now = DateTime.now();
        final curMonth = BillingPeriod.containing(now, 1);
        await budgetSvc.upsertTotalBudget(
          commandId: 'seed-bg-cur',
          bookId: 1,
          section: BudgetMode.monthly.sectionFor(curMonth),
          amountMinor: BigInt.from(400000),
        );

        await ledger.saveRecord(
          commandId: 'seed-exp-rec',
          draft: RecordDraft(
            type: RecordType.expense,
            money: Money.parse('150.00'),
            bookId: 1,
            recordTime: now.millisecondsSinceEpoch,
            categoryId: expCat.id,
            remark: '专业书籍',
            tagIds: [soloTagId],
          ),
        );
        await ledger.saveRecord(
          commandId: 'seed-inc-rec',
          draft: RecordDraft(
            type: RecordType.income,
            money: Money.parse('9000.00'),
            bookId: 1,
            recordTime: now.millisecondsSinceEpoch - 10000,
            categoryId: incCat.id,
            remark: '技术稿费',
            tagIds: [soloTagId],
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
        await tester.runAsync(db.close);
      }

      addTearDown(cleanUp);

      late ProviderContainer container;

      // 1. BudgetPage: horizontal swipe & trackpad scroll cancelled; ‹/› buttons & reset pill work
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: Consumer(
            builder: (context, ref, _) {
              container = ProviderScope.containerOf(context, listen: false);
              return const MaterialApp(home: BudgetPage());
            },
          ),
        ),
      );
      await _settle(tester);
      expect(container.read(budgetOffsetProvider), 0);
      expect(find.byKey(const Key('budget_period_reset')), findsNothing);

      await tester.drag(find.byType(ListView).first, const Offset(180, 0));
      await _settle(tester);
      expect(container.read(budgetOffsetProvider), 0);

      await tester.drag(find.byType(ListView).first, const Offset(-180, 0));
      await _settle(tester);
      expect(container.read(budgetOffsetProvider), 0);

      final budgetCenter = tester.getCenter(find.byType(ListView).first);
      _sendTrackpadHorizontalScroll(tester, budgetCenter, -45);
      await _settle(tester);
      expect(container.read(budgetOffsetProvider), 0);

      await tester.tap(find.byKey(const Key('budget_period_prev')));
      await _settle(tester);
      expect(container.read(budgetOffsetProvider), -1);
      expect(find.byKey(const Key('budget_period_reset')), findsOneWidget);
      expect(find.text('回本月'), findsOneWidget);
      await tester.tap(find.byKey(const Key('budget_period_reset')));
      await _settle(tester);
      expect(container.read(budgetOffsetProvider), 0);
      expect(find.byKey(const Key('budget_period_reset')), findsNothing);

      // 2. CategoryStatsPage: drawerEdgeDragWidth == 0, swipe & trackpad scroll cancelled, ‹/› & reset pill work!
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: Consumer(
            builder: (context, ref, _) {
              container = ProviderScope.containerOf(context, listen: false);
              return const MaterialApp(home: CategoryStatsPage());
            },
          ),
        ),
      );
      await _settle(tester);
      final catScaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
      expect(catScaffold.drawerEdgeDragWidth, 0);
      expect(container.read(categoryStatsOffsetProvider), 0);
      expect(
        find.byKey(const Key('category-stats-period-reset')),
        findsNothing,
      );

      // Swiping on HeaderSummaryCard, CategoryRankingsCard, and TrendChartCard MUST NOT change offset!
      await tester.drag(
        find.byKey(const Key('header-total-amount')),
        const Offset(180, 0),
      );
      await _settle(tester);
      expect(container.read(categoryStatsOffsetProvider), 0);

      await tester.drag(find.text('分类排行榜'), const Offset(-180, 0));
      await _settle(tester);
      expect(container.read(categoryStatsOffsetProvider), 0);

      final catHeaderCenter = tester.getCenter(
        find.byKey(const Key('header-total-amount')),
      );
      _sendTrackpadHorizontalScroll(tester, catHeaderCenter, 45);
      await _settle(tester);
      expect(container.read(categoryStatsOffsetProvider), 0);

      final trendTitle = find.text('收支趋势');
      expect(trendTitle, findsOneWidget);
      final trendCard = find.ancestor(
        of: trendTitle,
        matching: find.byType(Card),
      );
      final chartCanvas = find.descendant(
        of: trendCard,
        matching: find.byType(CustomPaint),
      );
      await tester.drag(chartCanvas.first, const Offset(220, 0));
      await _settle(tester);
      expect(container.read(categoryStatsOffsetProvider), 0);

      // ‹ button steps to -1 and shows `回本月` pill -> tapping pill resets to 0
      await tester.tap(find.byKey(const Key('period-prev-button')));
      await _settle(tester);
      expect(container.read(categoryStatsOffsetProvider), -1);
      expect(
        find.byKey(const Key('category-stats-period-reset')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('category-stats-period-reset')));
      await _settle(tester);
      expect(container.read(categoryStatsOffsetProvider), 0);
      expect(
        find.byKey(const Key('category-stats-period-reset')),
        findsNothing,
      );

      // 3. TagRankingsPage & TagDetailStatsPage: horizontal swipe & trackpad scroll cancelled + B-16 popup modal check
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: Consumer(
            builder: (context, ref, _) {
              container = ProviderScope.containerOf(context, listen: false);
              return const MaterialApp(home: TagRankingsPage());
            },
          ),
        ),
      );
      await _settle(tester);
      expect(
        container.read(tagStatsPeriodModeProvider),
        TagStatsPeriodMode.all,
      );
      await tester.drag(find.byType(ListView).first, const Offset(180, 0));
      await _settle(tester);
      expect(container.read(tagStatsOffsetProvider), 0);

      await tester.tap(find.byKey(const Key('tag-rankings-mode-month')));
      await _settle(tester);
      await tester.drag(find.byType(ListView).first, const Offset(180, 0));
      await _settle(tester);
      expect(container.read(tagStatsOffsetProvider), 0);
      _sendTrackpadHorizontalScroll(
        tester,
        tester.getCenter(find.byType(ListView).first),
        -45,
      );
      await _settle(tester);
      expect(container.read(tagStatsOffsetProvider), 0);

      await tester.tap(find.byKey(const Key('tag-rankings-prev-period')));
      await _settle(tester);
      expect(container.read(tagStatsOffsetProvider), -1);
      expect(find.byKey(const Key('tag-stats-period-reset')), findsOneWidget);
      await tester.tap(find.byKey(const Key('tag-stats-period-reset')));
      await _settle(tester);
      expect(container.read(tagStatsOffsetProvider), 0);
      expect(find.byKey(const Key('tag-stats-period-reset')), findsNothing);

      // B-16: On empty month (-1 has 0 tag bills), open TagRankingsPage inside a desktop PopupRoute and tap `tag-rankings-manage-tags-btn` -> pops cleanly!
      tester.view.physicalSize = const Size(1280, 800);
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: DesktopAdaptiveScope(
            isDesktop: true,
            child: MaterialApp(
              home: Builder(
                builder: (ctx) => Scaffold(
                  body: Center(
                    child: ElevatedButton(
                      key: const Key('open-tag-rankings-modal'),
                      onPressed: () => pushDesktopModalOrMaterialRoute<void>(
                        ctx,
                        child: const TagRankingsPage(),
                      ),
                      child: const Text('OPEN_MODAL'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await _settle(tester);
      await tester.tap(find.byKey(const Key('open-tag-rankings-modal')));
      await _settle(tester);
      expect(find.byKey(const Key('tag-rankings-page')), findsOneWidget);
      // Step to -1 so empty state `tag-rankings-manage-tags-btn` renders
      await tester.tap(find.byKey(const Key('tag-rankings-prev-period')));
      await _settle(tester);
      expect(
        find.byKey(const Key('tag-rankings-manage-tags-btn')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('tag-rankings-manage-tags-btn')));
      await _settle(tester);
      expect(find.byKey(const Key('tag-rankings-page')), findsNothing);
      expect(tester.takeException(), isNull);

      // TagDetailStatsPage: swipe & trackpad scroll cancelled, ‹/› and reset pill work!
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: Consumer(
            builder: (context, ref, _) {
              container = ProviderScope.containerOf(context, listen: false);
              return MaterialApp(home: TagDetailStatsPage(tagId: soloTagId));
            },
          ),
        ),
      );
      await _settle(tester);
      expect(container.read(tagStatsOffsetProvider), -1);
      expect(find.byKey(const Key('tag-detail-period-reset')), findsOneWidget);
      await tester.drag(find.byType(ListView).first, const Offset(-180, 0));
      await _settle(tester);
      expect(container.read(tagStatsOffsetProvider), -1);

      final tagDetailCenter = tester.getCenter(find.byType(ListView).first);
      _sendTrackpadHorizontalScroll(tester, tagDetailCenter, 42);
      await _settle(tester);
      expect(container.read(tagStatsOffsetProvider), -1);

      await tester.tap(find.byKey(const Key('tag-detail-period-reset')));
      await _settle(tester);
      expect(container.read(tagStatsOffsetProvider), 0);
      expect(find.byKey(const Key('tag-detail-period-reset')), findsNothing);

      // 4. AnnualReportPage synced 2-page PageView swipe (年度账单 ⇄ 年度报告)
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: const MaterialApp(home: AnnualReportPage()),
        ),
      );
      await _settle(tester);
      expect(find.byKey(const Key('annual-report-bill-view')), findsOneWidget);

      await tester.drag(
        find.byKey(const Key('annual-report-tab-pageview')),
        const Offset(-320, 0),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('annual-report-highlight-view')),
        findsOneWidget,
      );
      final segAfterLeft = tester.widget<SegmentedButton<int>>(
        find.byKey(const Key('annual-report-segmented-tabs')),
      );
      expect(segAfterLeft.selected, <int>{1});

      await tester.drag(
        find.byKey(const Key('annual-report-tab-pageview')),
        const Offset(320, 0),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('annual-report-bill-view')), findsOneWidget);
      final segAfterRight = tester.widget<SegmentedButton<int>>(
        find.byKey(const Key('annual-report-segmented-tabs')),
      );
      expect(segAfterRight.selected, <int>{0});

      // 5. B-24: StatsPage expense isolation & TickerMode child-push preservation
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: Consumer(
            builder: (context, ref, _) {
              container = ProviderScope.containerOf(context, listen: false);
              return const TallyIsleApp();
            },
          ),
        ),
      );
      await _settle(tester);

      // Switch CategoryStats dimension to income, then open StatsPage -> hub Category & Tag cards MUST still show expense (¥150.00), NOT income (¥9000.00)!
      container
          .read(categoryStatsDimensionProvider.notifier)
          .setDimension(StatDimension.income);
      await tester.tap(find.text('统计'));
      await _settle(tester);
      expect(find.text('¥150.00 (100.00%)'), findsWidgets);
      expect(
        find.descendant(
          of: find.byKey(const Key('stats-category-overview-card')),
          matching: find.textContaining('9000.00'),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('stats-tag-overview-card')),
          matching: find.textContaining('9000.00'),
        ),
        findsNothing,
      );

      // Scroll to inline budget card on StatsPage, step to -1, push `/record/new`, pop -> MUST stay at -1!
      await tester.scrollUntilVisible(
        find.byKey(const Key('budget_summary_card')),
        200,
        scrollable: find.descendant(
          of: find.byKey(const Key('stats-hub-list')),
          matching: find.byType(Scrollable),
        ),
      );
      await _settle(tester);
      await tester.tap(find.byKey(const Key('budget_card_period_prev')));
      await _settle(tester);
      expect(container.read(budgetOffsetProvider), -1);

      // Push `/record/new` on top of `/stats` and pop back -> MUST stay at -1!
      await tester.tap(find.byKey(const Key('add-record')));
      await _settle(tester);
      await tester.tap(find.byType(BackButton));
      await _settle(tester);
      expect(container.read(budgetOffsetProvider), -1);

      // Push child route `/stats/annual` on top of `/stats` and pop back -> MUST also stay at -1!
      await tester.tap(find.byKey(const Key('stats-annual-action')));
      await _settle(tester);
      await tester.tap(find.byType(BackButton));
      await _settle(tester);
      expect(container.read(budgetOffsetProvider), -1);

      // Switch away to `明细` branch and back to `统计` -> resets to 0!
      await tester.tap(find.text('明细'));
      await _settle(tester);
      await tester.tap(find.text('统计'));
      await _settle(tester);
      expect(container.read(budgetOffsetProvider), 0);

      await cleanUp();
    },
  );
}
