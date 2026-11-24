import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tallyisle/app/adaptive.dart';
import 'package:tallyisle/app/app.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/data/catalog/catalog_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/settings/app_lock_service.dart';
import 'package:tallyisle/features/automation/auto_bill_page.dart';
import 'package:tallyisle/features/automation/automation_providers.dart';
import 'package:tallyisle/features/backup/backup_providers.dart';
import 'package:tallyisle/features/reminder/reminder_page.dart';
import 'package:tallyisle/features/reminder/reminder_providers.dart';
import 'package:tallyisle/features/security/app_lock_providers.dart';
import 'package:tallyisle/features/security/app_lock_settings_page.dart';
import 'package:tallyisle/features/settings/settings_page.dart';
import 'package:tallyisle/platform/app_widgets.dart';
import 'package:tallyisle/platform/auto_bill_bridge.dart';
import 'package:tallyisle/platform/biometrics.dart';
import 'package:tallyisle/platform/notifications.dart';

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('DesktopAdaptive pure classification rules', () {
    test('classifyDesktopWindowWidth maps compact / medium / expanded', () {
      expect(classifyDesktopWindowWidth(420), DesktopWindowSizeClass.compact);
      expect(classifyDesktopWindowWidth(719.9), DesktopWindowSizeClass.compact);
      expect(classifyDesktopWindowWidth(720), DesktopWindowSizeClass.medium);
      expect(classifyDesktopWindowWidth(1079.9), DesktopWindowSizeClass.medium);
      expect(classifyDesktopWindowWidth(1080), DesktopWindowSizeClass.expanded);
      expect(classifyDesktopWindowWidth(1280), DesktopWindowSizeClass.expanded);
      expect(classifyDesktopWindowWidth(1920), DesktopWindowSizeClass.expanded);
    });

    test('isDesktopTargetPlatform distinguishes desktop from mobile OSes', () {
      expect(isDesktopTargetPlatform(TargetPlatform.linux), isTrue);
      expect(isDesktopTargetPlatform(TargetPlatform.windows), isTrue);
      expect(isDesktopTargetPlatform(TargetPlatform.macOS), isTrue);
      expect(isDesktopTargetPlatform(TargetPlatform.android), isFalse);
      expect(isDesktopTargetPlatform(TargetPlatform.iOS), isFalse);
      expect(isDesktopTargetPlatform(TargetPlatform.fuchsia), isFalse);
    });
  });

  testWidgets(
    'Desktop shell adapts across 1280x800 sidebar, 900x700 rail, and 520x600 compact fallback, with centered book switcher dialog',
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
        () => Directory.systemTemp.createTemp('desk_p1_shell_'),
      ))!;

      await tester.runAsync(() async {
        final catalog = CatalogService(db);
        await catalog.createBook(commandId: 'seed-book-2', name: '家庭账本');
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

      // True desktop bypasses legacy 960px mobile-tablet frame clamp
      expect(find.byKey(const Key('desktop_widescreen_frame')), findsNothing);
      expect(find.byKey(const Key('desktop-sidebar')), findsOneWidget);
      expect(find.byKey(const Key('shell-bottom-bar')), findsNothing);
      expect(
        tester.getSize(find.byKey(const Key('desktop-sidebar'))).width,
        208,
      );

      // Switch book from desktop sidebar -> centered dialog (not bottom sheet)
      await tester.tap(find.byKey(const Key('desktop-book-switcher')));
      await _settle(tester);
      expect(
        find.byKey(const Key('desktop-book-switcher-dialog')),
        findsOneWidget,
      );
      await tester.tap(find.text('家庭账本'));
      await _settle(tester);
      expect(
        find.descendant(
          of: find.byKey(const Key('desktop-sidebar')),
          matching: find.text('家庭账本'),
        ),
        findsOneWidget,
      );

      // Navigate across all 4 branches from sidebar without overflow
      for (final slotKey in const <Key>[
        Key('nav-slot-stats'),
        Key('nav-slot-assets'),
        Key('nav-slot-more'),
        Key('nav-slot-home'),
      ]) {
        await tester.tap(find.byKey(slotKey));
        await _settle(tester);
        expect(tester.takeException(), isNull);
      }

      // Honest offline sync indicator in sidebar
      expect(find.text('本地离线 · 备份同步'), findsOneWidget);

      // Resize to 900x700 -> Medium compact 76px NavigationRail
      tester.view.physicalSize = const Size(900, 700);
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('desktop-sidebar')), findsNothing);
      expect(find.byKey(const Key('desktop-nav-rail')), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const Key('desktop-nav-rail'))).width,
        76,
      );

      // Resize to minimum height 1280x600 -> zero vertical overflow
      tester.view.physicalSize = const Size(1280, 600);
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('desktop-sidebar')), findsOneWidget);

      // Resize narrow to 520x600 (< 720px) -> smooth fallback to 5-slot bottom bar
      tester.view.physicalSize = const Size(520, 600);
      await _settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('desktop-sidebar')), findsNothing);
      expect(find.byKey(const Key('desktop-nav-rail')), findsNothing);
      expect(find.byKey(const Key('shell-bottom-bar')), findsOneWidget);

      await cleanUp();
    },
  );

  testWidgets(
    'Desktop global shortcuts switch branches, cycle billing periods, auto-focus search with Esc clear/close, and open new record',
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
        () => Directory.systemTemp.createTemp('desk_p1_keys_'),
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

      // `[` / `Alt+Left` / `T` cycle periodOffsetProvider on Home
      expect(container.read(periodOffsetProvider), 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
      await _settle(tester);
      expect(container.read(periodOffsetProvider), -1);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await _settle(tester);
      expect(container.read(periodOffsetProvider), -2);

      await tester.sendKeyEvent(LogicalKeyboardKey.bracketRight);
      await _settle(tester);
      expect(container.read(periodOffsetProvider), -1);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
      await _settle(tester);
      expect(container.read(periodOffsetProvider), 0);

      // Ctrl+2 -> Stats, Ctrl+3 -> Assets, Ctrl+4 -> Me, Ctrl+1 -> Home
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await _settle(tester);
      expect(find.byKey(const Key('stats-hub-page')), findsOneWidget);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit4);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await _settle(tester);
      // On desktop MePage, Android-only desktop widget entry is hidden
      expect(find.byKey(const Key('me-books')), findsOneWidget);
      expect(find.byKey(const Key('me-widgets')), findsNothing);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await _settle(tester);

      // Ctrl+F -> opens SearchPage and auto-focuses search-keyword-field
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await _settle(tester);
      final searchField = find.byKey(const Key('search-keyword-field'));
      expect(searchField, findsOneWidget);
      final editable = tester.widget<EditableText>(
        find.descendant(of: searchField, matching: find.byType(EditableText)),
      );
      expect(editable.focusNode.hasFocus, isTrue);

      // Typing `[` inside focused search box must NOT mutate periodOffsetProvider
      await tester.enterText(searchField, '[早餐]');
      await tester.sendKeyEvent(LogicalKeyboardKey.bracketLeft);
      await _settle(tester);
      expect(container.read(periodOffsetProvider), 0);

      // First Esc clears keyword; second Esc pops SearchPage back to Home
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(tester.widget<TextField>(searchField).controller?.text, isEmpty);
      expect(searchField, findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(searchField, findsNothing);

      // Ctrl+N -> opens New Record editor
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await _settle(tester);
      expect(find.byKey(const Key('amount')), findsOneWidget);

      await cleanUp();
    },
  );

  testWidgets(
    'AppLockGate supports physical keyboard digits, numpad, and Backspace on desktop while blocking global shortcuts when locked',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final db = AppDatabase(NativeDatabase.memory());
      final bio = InMemoryBiometricAuthenticator();
      final reminderScheduler = InMemoryReminderScheduler();
      final tempRoot = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('desk_p1_lock_'),
      ))!;

      await tester.runAsync(() async {
        final svc = AppLockService(db, authenticator: bio);
        await svc.enableAppLock(
          commandId: 'desk-lock-seed',
          pin: '2580',
          biometricEnabled: true,
          timeoutSeconds: 30,
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

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            biometricAuthenticatorProvider.overrideWithValue(bio),
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

      // Shield is active; biometric unlock button is hidden on desktop
      expect(find.byKey(const Key('app_lock_overlay')), findsOneWidget);
      expect(find.byKey(const Key('app_lock_biometric_button')), findsNothing);

      // Global shortcut Ctrl+F must NOT bypass lock screen
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await _settle(tester);
      expect(find.byKey(const Key('search-keyword-field')), findsNothing);
      expect(find.byKey(const Key('app_lock_overlay')), findsOneWidget);

      // Type '2', numpad '5', wrong '9', Backspace, '8', numpad '0' -> unlocks!
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      await tester.sendKeyEvent(LogicalKeyboardKey.numpad5);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit9);
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit8);
      await tester.sendKeyEvent(LogicalKeyboardKey.numpad0);
      await _settle(tester);

      expect(find.byKey(const Key('app_lock_overlay')), findsNothing);
      expect(find.byKey(const Key('desktop-sidebar')), findsOneWidget);

      await cleanUp();
    },
  );

  testWidgets(
    'Desktop platform gating cleanly adapts AutoBillPage, ReminderPage, AppLockSettingsPage, and SettingsPage macOS shortcut labels',
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final db = AppDatabase(NativeDatabase.memory());
      final autoBridge = InMemoryAutoBillBridge();
      final widgetBridge = InMemoryAppWidgetBridge();
      final reminderScheduler = InMemoryReminderScheduler(
        notificationsEnabled: false,
      );

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
      }

      addTearDown(cleanUp);

      Widget wrap(Widget home) => ProviderScope(
        retry: (_, _) => null,
        overrides: [
          databaseProvider.overrideWith((ref) async => db),
          autoBillBridgeProvider.overrideWithValue(autoBridge),
          appWidgetBridgeProvider.overrideWithValue(widgetBridge),
          reminderSchedulerProvider.overrideWithValue(reminderScheduler),
        ],
        child: MaterialApp(home: home),
      );

      // 1. AutoBillPage hides Android Accessibility card and shows desktop paste banner
      await tester.pumpWidget(wrap(const AutoBillPage()));
      await _settle(tester);
      expect(find.byKey(const Key('auto_bill_desktop_banner')), findsOneWidget);
      expect(find.byKey(const Key('auto_bill_status_badge')), findsNothing);

      // 2. ReminderPage shows honest desktop sync banner instead of Android permission banner
      await tester.pumpWidget(wrap(const ReminderPage()));
      await _settle(tester);
      expect(
        find.byKey(const Key('reminder_desktop_sync_banner')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('reminder_permission_banner')), findsNothing);

      // 3. AppLockSettingsPage hides Android biometric switch
      await tester.pumpWidget(wrap(const AppLockSettingsPage()));
      await _settle(tester);
      expect(find.byKey(const Key('app_lock_biometric_switch')), findsNothing);
      expect(find.text('自动锁定策略'), findsOneWidget);

      // 4. SettingsPage renders desktop shortcuts card with macOS ⌘ / ⌥ modifiers
      await tester.pumpWidget(wrap(const SettingsPage()));
      await _settle(tester);
      await tester.scrollUntilVisible(
        find.byKey(const Key('desktop_shortcuts_card')),
        220,
      );
      await _settle(tester);
      expect(find.byKey(const Key('desktop_shortcuts_card')), findsOneWidget);
      expect(find.text('⌘ + N'), findsOneWidget);
      expect(find.text('⌥ + ← / → 或 [ / ]'), findsOneWidget);

      await cleanUp();
    },
  );
}
