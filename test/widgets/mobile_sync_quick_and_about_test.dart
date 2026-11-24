import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/app/adaptive.dart';
import 'package:tallyisle/app/app.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/domain/rules/cloud_sync_rules.dart';
import 'package:tallyisle/features/backup/backup_page.dart';
import 'package:tallyisle/features/backup/backup_providers.dart';
import 'package:tallyisle/features/migration/migration_page.dart';
import 'package:tallyisle/features/settings/about_help_page.dart';

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 14; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pump(const Duration(milliseconds: 400));
}

Future<List<File>> _waitForBackups(
  WidgetTester tester,
  Directory tempDir,
  int minCount,
) async {
  var files = <File>[];
  for (var i = 0; i < 30; i++) {
    files = (await tester.runAsync(
      () async => tempDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.tally'))
          .toList(),
    ))!;
    await tester.pump(const Duration(milliseconds: 60));
    if (files.length >= minCount) break;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
  }
  await _settle(tester);
  return files;
}

Future<void> _disposeApp(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await _settle(tester);
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets(
    'BackupPage shows prominent single-device snapshot relay notice and AboutHelpPage + MigrationPage show 6-platform HarmonyOS & Cloud Sync FAQ',
    (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final tempDir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('sync_notice_test_'),
      ))!;
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final db = AppDatabase(NativeDatabase.memory());

      // 1. BackupPage single-device relay warning banner
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            backupLocalDirectoryOverrideProvider.overrideWithValue(
              () async => tempDir,
            ),
            desktopModeOverrideProvider.overrideWithValue(false),
          ],
          child: const MaterialApp(home: BackupPage()),
        ),
      );
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const Key('cloud_sync_single_device_notice')),
        findsOneWidget,
      );
      expect(find.text('使用前提：单设备主力记账 · 换设备前同步接力'), findsOneWidget);
      expect(find.textContaining('conflict_*.tally'), findsOneWidget);

      // 2. AboutHelpPage 6-platform HarmonyOS & Cloud Sync FAQ
      await tester.pumpWidget(const MaterialApp(home: AboutHelpPage()));
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(
        find.text(
          '基于 Flutter 构建 · 支持 Android / iOS / HarmonyOS / Windows / Linux / macOS 六端',
        ),
        findsOneWidget,
      );

      await tester.scrollUntilVisible(
        find.byKey(const Key('faq_cloud_sync_usage_tile')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await _settle(tester);
      await tester.tap(find.byKey(const Key('faq_cloud_sync_usage_tile')));
      await _settle(tester);
      expect(find.textContaining('整库快照版本接力'), findsOneWidget);
      expect(find.textContaining('conflict_*.tally'), findsOneWidget);

      // 3. MigrationPage 6-platform HarmonyOS note
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [databaseProvider.overrideWith((ref) async => db)],
          child: const MaterialApp(home: MigrationPage()),
        ),
      );
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(
        find.textContaining(
          'Android / iOS / HarmonyOS / Windows / Linux / macOS',
        ),
        findsOneWidget,
      );

      await _disposeApp(tester);
      await db.close();
    },
  );

  test(
    'CloudSyncSettings defaults quick entries to hidden and round-trips JSON safely',
    () {
      final defaults = resolveEffectiveCloudSyncSettings(
        rawJson: null,
        isWebDavConfigured: false,
        fallbackDeviceId: 'dev-1',
      );
      expect(defaults.showHomeQuickEntry, isFalse);
      expect(defaults.showMeQuickEntry, isFalse);

      final emptyJson = resolveEffectiveCloudSyncSettings(
        rawJson: '   ',
        isWebDavConfigured: true,
        fallbackDeviceId: 'dev-1',
      );
      expect(emptyJson.showHomeQuickEntry, isFalse);
      expect(emptyJson.showMeQuickEntry, isFalse);
      expect(emptyJson.backend, CloudBackendType.webdav);

      final legacyDecoded = CloudSyncSettings.fromJson(const <String, Object?>{
        'backend': 'none',
        'device_id': 'dev-1',
      }, fallbackDeviceId: 'dev-1');
      expect(legacyDecoded.showHomeQuickEntry, isFalse);
      expect(legacyDecoded.showMeQuickEntry, isFalse);

      final updated = defaults.copyWith(
        showHomeQuickEntry: true,
        showMeQuickEntry: true,
      );
      final encoded = updated.toJson();
      expect(encoded['show_home_quick_entry'], isTrue);
      expect(encoded['show_me_quick_entry'], isTrue);

      final roundTripped = resolveEffectiveCloudSyncSettings(
        rawJson: jsonEncode(encoded),
        isWebDavConfigured: false,
        fallbackDeviceId: 'dev-1',
      );
      expect(roundTripped, equals(updated));
      expect(roundTripped.showHomeQuickEntry, isTrue);
      expect(roundTripped.showMeQuickEntry, isTrue);
    },
  );

  testWidgets(
    'BackupPage quick_entry_visibility_card renders cleanly at 360x640 with 1.2x text scale in Light & Dark themes and hides on Desktop',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final tempDir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('quick_vis_layout_'),
      ))!;
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final db = AppDatabase(NativeDatabase.memory());

      for (final brightness in [Brightness.light, Brightness.dark]) {
        await tester.pumpWidget(
          ProviderScope(
            retry: (_, _) => null,
            overrides: [
              databaseProvider.overrideWith((ref) async => db),
              backupLocalDirectoryOverrideProvider.overrideWithValue(
                () async => tempDir,
              ),
              desktopModeOverrideProvider.overrideWithValue(false),
            ],
            child: MaterialApp(
              theme: ThemeData(brightness: brightness, useMaterial3: true),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(1.2)),
                child: child!,
              ),
              home: const DesktopAdaptiveScope(
                isDesktop: false,
                child: BackupPage(),
              ),
            ),
          ),
        );
        await _settle(tester);
        expect(tester.takeException(), isNull);

        await tester.scrollUntilVisible(
          find.byKey(const Key('quick_entry_visibility_card')),
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await _settle(tester);
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const Key('quick_entry_visibility_card')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('backup_show_home_quick_entry_switch')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('backup_show_me_quick_entry_switch')),
          findsOneWidget,
        );

        final cloudCardTop = tester
            .getTopLeft(find.widgetWithText(Card, '云端历史版本备份'))
            .dy;
        final quickCardTop = tester
            .getTopLeft(find.byKey(const Key('quick_entry_visibility_card')))
            .dy;
        expect(quickCardTop, greaterThan(cloudCardTop));
      }

      // Desktop mode hides quick_entry_visibility_card per ADR-018
      tester.view.physicalSize = const Size(1280, 800);
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            backupLocalDirectoryOverrideProvider.overrideWithValue(
              () async => tempDir,
            ),
            desktopModeOverrideProvider.overrideWithValue(true),
          ],
          child: const MaterialApp(
            home: DesktopAdaptiveScope(isDesktop: true, child: BackupPage()),
          ),
        ),
      );
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const Key('quick_entry_visibility_card')),
        findsNothing,
      );

      await _disposeApp(tester);
      await db.close();
    },
  );

  testWidgets(
    'Mobile HomePage & MePage quick entries default to hidden, persist when toggled ON in BackupPage, execute 1-tap backup, and stay hidden on Desktop',
    (tester) async {
      final tempDir = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('mobile_quick_sync_'),
      ))!;
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final db = AppDatabase(NativeDatabase.memory());

      // Mobile viewport (360x640)
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            backupLocalDirectoryOverrideProvider.overrideWithValue(
              () async => tempDir,
            ),
            desktopModeOverrideProvider.overrideWithValue(false),
          ],
          child: const TallyIsleApp(),
        ),
      );
      await _settle(tester);
      expect(tester.takeException(), isNull);

      // 1. Default hidden on Mobile HomePage & MePage
      expect(find.byKey(const Key('home-sync-backup-button')), findsNothing);
      await tester.tap(find.text('更多'));
      await _settle(tester);
      expect(find.byKey(const Key('me-mobile-sync-quick-card')), findsNothing);

      // 2. Navigate to BackupPage via MePage -> 云同步与备份, scroll to bottom, toggle both ON
      await tester.scrollUntilVisible(
        find.byKey(const Key('me-backup')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await _settle(tester);
      await tester.tap(find.byKey(const Key('me-backup')));
      await _settle(tester);
      expect(find.byKey(const Key('backup_page')), findsOneWidget);

      await tester.scrollUntilVisible(
        find.byKey(const Key('quick_entry_visibility_card')),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await _settle(tester);

      await tester.tap(
        find.byKey(const Key('backup_show_home_quick_entry_switch')),
      );
      await _settle(tester);
      await tester.tap(
        find.byKey(const Key('backup_show_me_quick_entry_switch')),
      );
      await _settle(tester);

      // Verify persisted in ti_preference even with CloudBackendType.none
      final prefRow = await tester.runAsync(
        () =>
            (db.select(db.preferences)
                  ..where((t) => t.key.equals(prefKeyCloudSyncSettings)))
                .getSingleOrNull(),
      );
      expect(prefRow, isNotNull);
      final persisted = resolveEffectiveCloudSyncSettings(
        rawJson: prefRow!.value,
        isWebDavConfigured: false,
        fallbackDeviceId: 'test',
      );
      expect(persisted.backend, CloudBackendType.none);
      expect(persisted.showHomeQuickEntry, isTrue);
      expect(persisted.showMeQuickEntry, isTrue);

      final backupContainer = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('backup_page'))),
      );
      final loaded = await tester.runAsync(() async {
        final service = await backupContainer.read(
          tallyBackupServiceProvider.future,
        );
        return service.getCloudSyncSettings();
      });
      expect(loaded!.showHomeQuickEntry, isTrue);
      expect(loaded.showMeQuickEntry, isTrue);

      // Return to MePage -> top pinned quick card is now visible, runs 1-tap backup & taps into BackupPage
      await tester.tap(find.byType(BackButton));
      await _settle(tester);
      expect(find.byKey(const Key('backup_page')), findsNothing);
      await tester.ensureVisible(
        find.byKey(const Key('me-mobile-sync-quick-card')),
      );
      await _settle(tester);

      expect(
        find.byKey(const Key('me-mobile-sync-quick-card')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('me-mobile-sync-quick-action')));
      var files = await _waitForBackups(tester, tempDir, 1);
      expect(files, hasLength(1));

      await tester.tap(find.byKey(const Key('me-mobile-sync-quick-card')));
      await _settle(tester);
      expect(find.byKey(const Key('backup_page')), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await _settle(tester);

      // 3. Switch back to '明细' (HomePage) -> home-sync-backup-button is now visible -> opens quick sheet -> 1-tap backup
      await tester.tap(find.text('明细'));
      await _settle(tester);
      expect(find.byKey(const Key('home-sync-backup-button')), findsOneWidget);
      await tester.tap(find.byKey(const Key('home-sync-backup-button')));
      await _settle(tester);
      expect(
        find.byKey(const Key('mobile_sync_backup_quick_sheet')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const Key('quick_sheet_local_backup_button')),
      );
      files = await _waitForBackups(tester, tempDir, 2);
      expect(files, hasLength(2));

      // Re-open quick sheet -> tap '完整设置' -> navigates to BackupPage
      await tester.tap(find.byKey(const Key('home-sync-backup-button')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('quick_sheet_open_backup_page')));
      await _settle(tester);
      expect(find.byKey(const Key('backup_page')), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await _settle(tester);

      // 4. Desktop mode (1280x800): mobile-only quick buttons/cards stay cleanly hidden even when enabled
      tester.view.physicalSize = const Size(1280, 800);
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            backupLocalDirectoryOverrideProvider.overrideWithValue(
              () async => tempDir,
            ),
            desktopModeOverrideProvider.overrideWithValue(true),
          ],
          child: const TallyIsleApp(),
        ),
      );
      await _settle(tester);
      expect(find.byKey(const Key('home-sync-backup-button')), findsNothing);
      await tester.tap(find.text('更多').first);
      await _settle(tester);
      expect(find.byKey(const Key('me-mobile-sync-quick-card')), findsNothing);

      await _disposeApp(tester);
      await db.close();
    },
  );
}
