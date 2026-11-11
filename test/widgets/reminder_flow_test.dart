import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/features/reminder/reminder_page.dart';
import 'package:tallyisle/features/reminder/reminder_providers.dart';
import 'package:tallyisle/platform/notifications.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Widget buildApp({
    required AppDatabase db,
    required ReminderScheduler scheduler,
  }) => ProviderScope(
    retry: (_, _) => null,
    overrides: [
      databaseProvider.overrideWith((ref) async => db),
      reminderSchedulerProvider.overrideWithValue(scheduler),
    ],
    child: const MaterialApp(home: ReminderPage()),
  );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  Future<void> enterReminderTime(
    WidgetTester tester,
    int hour,
    int minute,
  ) async {
    await tester.enterText(
      find.byKey(const Key('reminder_hour_input')),
      hour.toString().padLeft(2, '0'),
    );
    await tester.enterText(
      find.byKey(const Key('reminder_minute_input')),
      minute.toString().padLeft(2, '0'),
    );
    await tester.pump();
  }

  testWidgets(
    'R4 permission banner is non-blocking, opens settings or grants permission without force-exiting page',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final scheduler = InMemoryReminderScheduler(
        notificationsEnabled: false,
        permissionGrantResult: false,
      );

      await tester.pumpWidget(buildApp(db: db, scheduler: scheduler));
      await settle(tester);

      // Page stays open and displays non-blocking permission banner
      expect(find.byKey(const Key('reminder_page')), findsOneWidget);
      expect(
        find.byKey(const Key('reminder_permission_banner')),
        findsOneWidget,
      );

      // Tapping action when runtime permission is denied falls back to opening OS settings
      await tester.tap(find.byKey(const Key('reminder_permission_action')));
      await settle(tester);
      expect(scheduler.requestPermissionCount, 1);
      expect(scheduler.openSettingsCount, 1);
      expect(find.byKey(const Key('reminder_page')), findsOneWidget);

      // When permission is granted, banner disappears automatically
      scheduler.permissionGrantResult = true;
      await tester.tap(find.byKey(const Key('reminder_permission_action')));
      await settle(tester);
      expect(find.byKey(const Key('reminder_permission_banner')), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'ReminderPage flow: create, sort (RE-06), reject duplicate (RE-08), edit blank tip safely (CE-RE-05), and confirm before delete (R5)',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final scheduler = InMemoryReminderScheduler();

      await tester.pumpWidget(buildApp(db: db, scheduler: scheduler));
      await settle(tester);

      expect(find.byKey(const Key('reminder_empty_state')), findsOneWidget);

      // 1. Create 22:15 with blank tip
      await tester.tap(find.byKey(const Key('add_reminder_fab')));
      await settle(tester);
      await enterReminderTime(tester, 22, 15);
      await tester.tap(find.byKey(const Key('save_reminder_button')));
      await settle(tester);

      // 2. Create 08:00 with custom tip
      await tester.tap(find.byKey(const Key('add_reminder_fab')));
      await settle(tester);
      await enterReminderTime(tester, 8, 0);
      await tester.enterText(
        find.byKey(const Key('reminder_tip_input')),
        '早安记一笔',
      );
      await tester.tap(find.byKey(const Key('save_reminder_button')));
      await settle(tester);

      // 3. Create 12:30 with blank tip
      await tester.tap(find.byKey(const Key('add_reminder_fab')));
      await settle(tester);
      await enterReminderTime(tester, 12, 30);
      await tester.tap(find.byKey(const Key('save_reminder_button')));
      await settle(tester);

      // Verify ascending visual order: 08:00 -> 12:30 -> 22:15 (RE-06)
      final y0800 = tester.getTopLeft(find.text('每天 08:00')).dy;
      final y1230 = tester.getTopLeft(find.text('每天 12:30')).dy;
      final y2215 = tester.getTopLeft(find.text('每天 22:15')).dy;
      expect(y0800, lessThan(y1230));
      expect(y1230, lessThan(y2215));

      // Verify neutral default copy and absence of original brand (DR-RE-06, BRAND-001)
      expect(find.text('是时候来记账啦！'), findsNWidgets(2));
      expect(find.text('早安记一笔'), findsOneWidget);
      expect(find.textContaining('一羽记账'), findsNothing);

      // 4. Duplicate 12:30 is rejected with '不能重复创建提醒时间' (RE-08)
      await tester.tap(find.byKey(const Key('add_reminder_fab')));
      await settle(tester);
      await enterReminderTime(tester, 12, 30);
      await tester.tap(find.byKey(const Key('save_reminder_button')));
      await settle(tester);
      expect(find.text('不能重复创建提醒时间'), findsOneWidget);

      await tester.tap(find.byKey(const Key('cancel_reminder_button')));
      await settle(tester);

      // 5. Edit 12:30 (blank tip): tip input must be empty, NOT prefilled with default copy (CE-RE-05)
      await tester.tap(find.text('每天 12:30'));
      await settle(tester);
      final tipField = tester.widget<TextField>(
        find.byKey(const Key('reminder_tip_input')),
      );
      expect(tipField.controller!.text, isEmpty);

      // Change 12:30 -> 12:45 while leaving tip blank
      await enterReminderTime(tester, 12, 45);
      await tester.tap(find.byKey(const Key('save_reminder_button')));
      await settle(tester);

      expect(find.text('每天 12:45'), findsOneWidget);
      expect(find.text('每天 12:30'), findsNothing);
      final rawRows = await tester.runAsync(
        () => db.select(db.reminderEvents).get(),
      );
      final row1245 = rawRows!.firstWhere(
        (r) => r.reminderTime == 12 * 60 + 45,
      );
      expect(row1245.reminderTip, '');

      // 6. Delete confirmation dialog '确认删除此提醒？' (R5)
      await tester.tap(find.byKey(Key('delete_reminder_${row1245.id}')));
      await settle(tester);
      expect(find.text('确认删除此提醒？'), findsOneWidget);

      // Cancel keeps reminder intact
      await tester.tap(find.text('取消'));
      await settle(tester);
      expect(find.text('每天 12:45'), findsOneWidget);
      expect(scheduler.scheduledById.containsKey(row1245.id), isTrue);

      // Confirm deletes reminder and removes from scheduler
      await tester.tap(find.byKey(Key('delete_reminder_${row1245.id}')));
      await settle(tester);
      expect(find.text('确认删除此提醒？'), findsOneWidget);
      await tester.tap(find.text('删除'));
      await settle(tester);

      expect(find.text('每天 12:45'), findsNothing);
      expect(scheduler.scheduledById.containsKey(row1245.id), isFalse);

      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
    },
  );
}
