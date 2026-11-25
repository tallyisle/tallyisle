import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as raw_sqlite;
import 'package:tallyisle/app/adaptive.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/data/automation/mcp_server_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/migration/cross_migration_service.dart';
import 'package:tallyisle/data/settings/app_lock_service.dart';
import 'package:tallyisle/features/automation/auto_bill_page.dart';
import 'package:tallyisle/features/automation/automation_providers.dart';
import 'package:tallyisle/features/automation/desktop_widgets_page.dart';
import 'package:tallyisle/features/automation/mcp_settings_page.dart';
import 'package:tallyisle/features/automation/url_scheme_page.dart';
import 'package:tallyisle/features/me/me_page.dart';
import 'package:tallyisle/features/reminder/reminder_page.dart';
import 'package:tallyisle/features/reminder/reminder_providers.dart';
import 'package:tallyisle/features/security/app_lock_providers.dart';
import 'package:tallyisle/features/security/app_lock_settings_page.dart';
import 'package:tallyisle/features/settings/settings_page.dart';
import 'package:tallyisle/platform/app_widgets.dart';
import 'package:tallyisle/platform/auto_bill_bridge.dart';
import 'package:tallyisle/platform/biometrics.dart';
import 'package:tallyisle/platform/files.dart';
import 'package:tallyisle/platform/notifications.dart';

final class _RealHttpOverrides extends HttpOverrides {}

/// Resolves `TargetPlatform.ohos` dynamically via `.name == 'ohos'` so this
/// test suite compiles cleanly on both `CPF-Flutter` and upstream Flutter.
TargetPlatform? _lookupOhosTargetPlatform() {
  for (final value in TargetPlatform.values) {
    if (value.name == 'ohos') {
      return value;
    }
  }
  return null;
}

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

  group('TargetPlatform.ohos exhaustiveness & adaptive helpers', () {
    test(
      'isDesktopTargetPlatform handles every TargetPlatform including ohos',
      () {
        for (final platform in TargetPlatform.values) {
          final isDesktop = isDesktopTargetPlatform(platform);
          if (platform == TargetPlatform.linux ||
              platform == TargetPlatform.windows ||
              platform == TargetPlatform.macOS) {
            expect(isDesktop, isTrue, reason: '${platform.name} is desktop');
          } else {
            expect(
              isDesktop,
              isFalse,
              reason: '${platform.name} must resolve to mobile/non-desktop',
            );
          }
        }

        final ohos = _lookupOhosTargetPlatform();
        if (ohos != null) {
          expect(isDesktopTargetPlatform(ohos), isFalse);
          expect(isOhosTargetPlatform(ohos), isTrue);
          expect(isAndroidAppWidgetSupportedPlatform(ohos), isFalse);
          expect(isMobileHomeWidgetSupportedPlatform(ohos), isTrue);
          expect(isNativeOfflineOcrSupportedPlatform(ohos), isTrue);
          expect(isAndroidAccessibilitySupportedPlatform(ohos), isFalse);
        }
      },
    );

    test(
      'platform capability predicates distinguish Android, iOS, and ohos',
      () {
        expect(isOhosTargetPlatform(TargetPlatform.android), isFalse);
        expect(isOhosTargetPlatform(TargetPlatform.iOS), isFalse);
        expect(isOhosTargetPlatform(TargetPlatform.linux), isFalse);

        expect(
          isAndroidAppWidgetSupportedPlatform(TargetPlatform.android),
          isTrue,
        );
        expect(
          isAndroidAppWidgetSupportedPlatform(TargetPlatform.iOS),
          isFalse,
        );
        expect(
          isMobileHomeWidgetSupportedPlatform(TargetPlatform.android),
          isTrue,
        );
        expect(
          isMobileHomeWidgetSupportedPlatform(TargetPlatform.iOS),
          isFalse,
        );
        expect(
          isMobileHomeWidgetSupportedPlatform(TargetPlatform.linux),
          isFalse,
        );
        expect(
          isNativeOfflineOcrSupportedPlatform(TargetPlatform.android),
          isTrue,
        );
        expect(isNativeOfflineOcrSupportedPlatform(TargetPlatform.iOS), isTrue);
        expect(
          isNativeOfflineOcrSupportedPlatform(TargetPlatform.linux),
          isFalse,
        );
        expect(
          isAndroidAccessibilitySupportedPlatform(TargetPlatform.android),
          isTrue,
        );
        expect(
          isAndroidAccessibilitySupportedPlatform(TargetPlatform.iOS),
          isFalse,
        );
      },
    );
  });

  group('HarmonyOS UI capability gating', () {
    testWidgets(
      'HarmonyOS MePage exposes mobile service-card widgets (me-widgets) alongside Reminders, App Lock, Auto-Bill inbox, URL Scheme, and MCP',
      (tester) async {
        // When running on official Flutter (no TargetPlatform.ohos enum value),
        // verify mobile home-widget gating via TargetPlatform.android vs iOS;
        // on CPF-Flutter, verify real TargetPlatform.ohos directly!
        final ohos = _lookupOhosTargetPlatform();
        final testPlatform = ohos ?? TargetPlatform.android;
        final isRealOhos = ohos != null;
        debugDefaultTargetPlatformOverride = testPlatform;
        try {
          await tester.binding.setSurfaceSize(const Size(390, 844));
          addTearDown(() => tester.binding.setSurfaceSize(null));

          await tester.pumpWidget(
            ProviderScope(
              overrides: [autoBillDraftCountProvider.overrideWithValue(2)],
              child: MaterialApp(
                localizationsDelegates: GlobalMaterialLocalizations.delegates,
                supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
                theme: ThemeData(platform: testPlatform, useMaterial3: true),
                home: Builder(
                  builder: (context) {
                    expect(DesktopAdaptive.isDesktop(context), isFalse);
                    expect(DesktopAdaptive.isOhos(context), isRealOhos);
                    expect(
                      DesktopAdaptive.supportsAndroidAppWidgets(context),
                      !isRealOhos,
                    );
                    expect(
                      DesktopAdaptive.supportsMobileHomeWidgets(context),
                      isTrue,
                    );
                    return const MePage();
                  },
                ),
              ),
            ),
          );
          await _settle(tester);

          // Visible & enabled HarmonyOS capabilities in MePage (now including me-widgets!)
          final scrollable = find.byType(Scrollable).first;
          for (final key in const <Key>[
            Key('me-reminders'),
            Key('me-migration'),
            Key('me-auto-bill'),
            Key('me-ocr'),
            Key('me-widgets'),
            Key('me-url-scheme'),
            Key('me-mcp'),
            Key('me-app-lock'),
            Key('me-settings'),
          ]) {
            await tester.scrollUntilVisible(
              find.byKey(key),
              200,
              scrollable: scrollable,
            );
            expect(find.byKey(key), findsOneWidget);
          }
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets(
      'HarmonyOS pages expose Biometrics, Daily Reminders, tallyisle:// URL Scheme, MCP hints, 4 native Form service cards, and honest unsupported Accessibility state',
      (tester) async {
        final ohos = _lookupOhosTargetPlatform() ?? TargetPlatform.iOS;
        final isRealOhos = ohos.name == 'ohos';
        debugDefaultTargetPlatformOverride = ohos;

        final db = AppDatabase(NativeDatabase.memory());
        final bio = InMemoryBiometricAuthenticator();
        final reminderScheduler = InMemoryReminderScheduler(
          notificationsEnabled: false,
        );
        final autoBridge = createAutoBillBridge(isOhosOverride: true);
        final widgetBridge = createAppWidgetBridge(isOhosOverride: true);

        await tester.runAsync(() async {
          final lockSvc = AppLockService(db, authenticator: bio);
          await lockSvc.enableAppLock(
            commandId: 'ohos-lock-enable',
            pin: '1357',
            biometricEnabled: true,
          );
        });

        var cleaned = false;
        Future<void> cleanUp() async {
          if (cleaned) return;
          cleaned = true;
          debugDefaultTargetPlatformOverride = null;
          await tester.pumpWidget(const SizedBox.shrink());
          await _settle(tester);
          await autoBridge.dispose();
          await widgetBridge.dispose();
          await tester.runAsync(reminderScheduler.dispose);
          await tester.runAsync(db.close);
        }

        addTearDown(cleanUp);

        Widget buildApp(Widget home) => ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            biometricAuthenticatorProvider.overrideWithValue(bio),
            reminderSchedulerProvider.overrideWithValue(reminderScheduler),
            autoBillBridgeProvider.overrideWithValue(autoBridge),
            appWidgetBridgeProvider.overrideWithValue(widgetBridge),
          ],
          child: MaterialApp(
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
            theme: ThemeData(platform: ohos, useMaterial3: true),
            home: home,
          ),
        );

        // 1. AppLockSettingsPage: biometric switch visible & enabled on HarmonyOS
        await tester.pumpWidget(buildApp(const AppLockSettingsPage()));
        await _settle(tester);
        final bioSwitch = find.byKey(const Key('app_lock_biometric_switch'));
        expect(bioSwitch, findsOneWidget);
        expect(tester.widget<SwitchListTile>(bioSwitch).onChanged, isNotNull);

        // 2. ReminderPage: mobile reminder FAB & permission banner visible (not desktop banner)
        await tester.pumpWidget(buildApp(const ReminderPage()));
        await _settle(tester);
        expect(find.byKey(const Key('add_reminder_fab')), findsOneWidget);
        expect(
          find.byKey(const Key('reminder_permission_banner')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('reminder_desktop_sync_banner')),
          findsNothing,
        );

        // 3. UrlSchemePage: HarmonyOS badge & protocol description, zero yyjz
        await tester.pumpWidget(buildApp(const UrlSchemePage()));
        await _settle(tester);
        expect(
          find.byKey(const Key('url_scheme_platform_badge')),
          findsOneWidget,
        );
        if (isRealOhos) {
          expect(find.text('HarmonyOS 原生已接入'), findsOneWidget);
        }
        expect(find.textContaining('HarmonyOS'), findsWidgets);
        expect(find.textContaining('yyjz'), findsNothing);

        // 4. McpSettingsPage: renders cleanly with mobile/HarmonyOS foreground & LAN guidance
        await tester.pumpWidget(buildApp(const McpSettingsPage()));
        await _settle(tester);
        expect(find.byKey(const Key('mcp_enable_switch')), findsOneWidget);
        await tester.scrollUntilVisible(
          find.byKey(const Key('mcp_copy_client_config_button')),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        if (isRealOhos) {
          expect(
            find.textContaining('HarmonyOS 设备运行时请保持帐屿处于前台'),
            findsOneWidget,
          );
        }

        // 5. AutoBillPage: honest 当前平台不支持 badge, zero dead settings button, HarmonyOS share guide strip
        await tester.pumpWidget(buildApp(const AutoBillPage()));
        await _settle(tester);
        expect(find.byKey(const Key('auto_bill_status_badge')), findsOneWidget);
        expect(find.text('当前平台不支持'), findsOneWidget);
        expect(
          find.byKey(const Key('auto_bill_open_settings_button')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('auto_bill_ohos_guide_strip')),
          findsOneWidget,
        );
        expect(find.textContaining('开启无障碍识别'), findsNothing);

        // 6. DesktopWidgetsPage: CapabilityState.available on HarmonyOS with all 4 service cards & HarmonyOS guide
        await tester.pumpWidget(buildApp(const DesktopWidgetsPage()));
        await _settle(tester);
        expect(widgetBridge.capability.state, CapabilityState.available);
        expect(find.byKey(const Key('widget_capability_banner')), findsNothing);
        final widgetScroll = find.byType(Scrollable).first;
        for (final kind in DesktopWidgetKind.values) {
          final pinFinder = find.byKey(Key('widget_pin_${kind.wireKey}'));
          await tester.scrollUntilVisible(
            pinFinder,
            220,
            scrollable: widgetScroll,
          );
          expect(
            find.byKey(Key('widget_section_${kind.wireKey}')),
            findsOneWidget,
          );
          final pinBtn = tester.widget<FilledButton>(pinFinder);
          expect(pinBtn.onPressed, isNotNull);
        }
        await tester.scrollUntilVisible(
          find.byKey(const Key('widget_ohos_guide_card')),
          220,
          scrollable: widgetScroll,
        );
        expect(find.byKey(const Key('widget_ohos_guide_card')), findsOneWidget);
        expect(find.textContaining('仅支持 Android'), findsNothing);

        // 7. SettingsPage compiles and renders cleanly without desktop shortcuts card
        await tester.pumpWidget(buildApp(const SettingsPage()));
        await _settle(tester);
        expect(find.byKey(const Key('desktop_shortcuts_card')), findsNothing);

        await cleanUp();
      },
    );
  });

  group('Item 6 Dart-side SQLite read-only import & MCP HttpServer.bind', () {
    test(
      'CrossMigrationService.inspectHaohaoDb opens external sandbox temp .db read-only and McpServerService binds loopback HTTP',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'ohos_item6_verify_',
        );
        final appDb = AppDatabase(NativeDatabase.memory());
        final reminderScheduler = InMemoryReminderScheduler();
        McpServerService? mcpService;
        try {
          // 1. Build a minimal valid Haohaojizhang SQLite backup file in sandbox temp path
          final haohaoPath = p.join(tempDir.path, 'account_record_ohos.db');
          final rawDb = raw_sqlite.sqlite3.open(haohaoPath);
          rawDb.execute('''
            CREATE TABLE account_book (
              account_book_id INTEGER PRIMARY KEY,
              name TEXT NOT NULL,
              start_bill_day INTEGER DEFAULT 1,
              status INTEGER DEFAULT 0
            );
            CREATE TABLE assets_account (
              assets_account_id INTEGER PRIMARY KEY,
              name TEXT NOT NULL,
              category TEXT NOT NULL,
              amount REAL DEFAULT 0,
              currency_code TEXT DEFAULT 'CNY',
              status INTEGER DEFAULT 0
            );
            CREATE TABLE bill_category (
              bill_category_id INTEGER PRIMARY KEY,
              account_book_id INTEGER NOT NULL,
              name TEXT NOT NULL,
              category TEXT NOT NULL,
              parent_id INTEGER DEFAULT 0,
              status INTEGER DEFAULT 0
            );
            CREATE TABLE bill_info (
              bill_info_id INTEGER PRIMARY KEY,
              account_book_id INTEGER NOT NULL,
              bill_type INTEGER DEFAULT 0,
              consume REAL DEFAULT 0,
              income REAL DEFAULT 0,
              category TEXT DEFAULT '支出',
              bill_category_id INTEGER DEFAULT 0,
              assets_account_id INTEGER DEFAULT 0,
              create_by INTEGER NOT NULL,
              remark TEXT DEFAULT '',
              status INTEGER DEFAULT 0
            );
          ''');
          rawDb.execute(
            "INSERT INTO account_book (account_book_id, name, start_bill_day, status) VALUES (1, '鸿蒙账本', 1, 0)",
          );
          rawDb.execute(
            "INSERT INTO assets_account (assets_account_id, name, category, amount, currency_code, status) VALUES (1, '华为钱包', '电子账户', 500.00, 'CNY', 0)",
          );
          rawDb.execute(
            "INSERT INTO bill_category (bill_category_id, account_book_id, name, category, parent_id, status) VALUES (10, 1, '餐饮', '支出', 0, 0)",
          );
          rawDb.execute(
            "INSERT INTO bill_info (bill_info_id, account_book_id, bill_type, consume, income, category, bill_category_id, assets_account_id, create_by, remark, status) VALUES (100, 1, 0, 25.80, 0, '支出', 10, 1, 1732435200000, '鸿蒙迁移测试午餐', 0)",
          );
          rawDb.close();

          final dbBytes = await File(haohaoPath).readAsBytes();
          final migrationSvc = CrossMigrationService(
            appDb,
            reminderScheduler: reminderScheduler,
            tempRootDir: tempDir,
          );
          final preview = await migrationSvc.inspectHaohaoDb(
            fileName: 'account_record_ohos.db',
            bytes: dbBytes,
          );
          expect(preview.sourceKind, MigrationSourceKind.haohaoDb);
          expect(preview.bookCount, 1);
          expect(preview.assetCount, 1);
          expect(preview.recordCount, 1);
          expect(preview.payload.records.single.moneyMinor, BigInt.from(2580));

          // 2. Bind real dart:io HttpServer via McpServerService on 127.0.0.1 ephemeral port
          mcpService = McpServerService(appDb, bindPortOverride: 0);
          expect(mcpService.isPlatformSupported, isTrue);
          await mcpService.setEnabled(true, commandId: 'ohos-mcp-bind-test');
          expect(mcpService.currentStatus.isRunning, isTrue);
          expect(mcpService.currentStatus.boundHost, '127.0.0.1');
          expect(mcpService.currentStatus.port, greaterThan(0));

          await HttpOverrides.runWithHttpOverrides(() async {
            final client = HttpClient();
            try {
              final req = await client.getUrl(
                Uri.parse(
                  'http://127.0.0.1:${mcpService!.currentStatus.port}/health',
                ),
              );
              final res = await req.close();
              expect(res.statusCode, 200);
              final body = await utf8.decoder.bind(res).join();
              final decoded = jsonDecode(body) as Map<String, Object?>;
              expect(decoded['status'], 'ok');
              expect(decoded['service'], 'tallyisle-mcp');
            } finally {
              client.close(force: true);
            }
          }, _RealHttpOverrides());
        } finally {
          await mcpService?.dispose();
          await reminderScheduler.dispose();
          await appDb.close();
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        }
      },
    );
  });
}
