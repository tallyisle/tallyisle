import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/reminder/reminder_service.dart';
import 'package:tallyisle/data/repo/reminder_queries.dart';
import 'package:tallyisle/platform/notifications.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late InMemoryReminderScheduler scheduler;
  late ReminderService service;
  late ReminderQueries queries;
  var seq = 0;
  String cmd() => 'rem-cmd-${seq++}';

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    scheduler = InMemoryReminderScheduler();
    service = ReminderService(db, scheduler: scheduler);
    queries = ReminderQueries(db);
  });

  tearDown(() async {
    await scheduler.dispose();
    await db.close();
  });

  group('ReminderService & ReminderQueries (F-032)', () {
    test(
      'creates, sorts ascending (RE-06), preserves blank tip in DB (CE-RE-05), and syncs independent notification IDs',
      () async {
        final id2215 = await service.createReminder(
          commandId: cmd(),
          hour: 22,
          minute: 15,
          tip: '   ',
        );
        final id0800 = await service.createReminder(
          commandId: cmd(),
          hour: 8,
          minute: 0,
          tip: '记得记早餐',
        );
        final id1230 = await service.createReminder(
          commandId: cmd(),
          hour: 12,
          minute: 30,
          tip: null,
        );

        // Sorted 08:00 -> 12:30 -> 22:15
        final items = await queries.getReminders();
        expect(items.map((e) => e.displayTime).toList(), [
          '每天 08:00',
          '每天 12:30',
          '每天 22:15',
        ]);
        expect(items[0].customTip, '记得记早餐');
        expect(items[1].customTip, isEmpty);
        expect(items[1].displayTip, '是时候来记账啦！');

        // Verify raw SQLite storage: minuteOfDay (0..1439) and empty string for blank tip
        final rawRows = await db.select(db.reminderEvents).get();
        final row2215 = rawRows.firstWhere((r) => r.id == id2215);
        expect(row2215.reminderTime, 22 * 60 + 15);
        expect(row2215.reminderTip, '');

        // Verify scheduler synced all 3 reminders with independent IDs and '/record/new'
        expect(
          scheduler.scheduledById.keys,
          containsAll([id2215, id0800, id1230]),
        );
        expect(scheduler.scheduledById[id2215]!.title, '是时候来记账啦！');
        expect(scheduler.scheduledById[id2215]!.route, '/record/new');
        expect(scheduler.scheduledById[id0800]!.title, '记得记早餐');
        expect(scheduler.scheduledById[id1230]!.hour, 12);
        expect(scheduler.scheduledById[id1230]!.minute, 30);
      },
    );

    test(
      'normalizes legacy imported epoch-ms timestamps for sorting, duplicate check, editing, and resyncAll (CE-RE-01, CE-RE-04, RE-08)',
      () async {
        // Simulate imported rows from original backup with different base dates
        final legacyEveningId = await db
            .into(db.reminderEvents)
            .insert(
              ReminderEventsCompanion.insert(
                reminderTime: DateTime(
                  2020,
                  12,
                  19,
                  20,
                  0,
                ).millisecondsSinceEpoch,
                reminderTip: const Value(null),
              ),
            );
        final legacyMorningId = await db
            .into(db.reminderEvents)
            .insert(
              ReminderEventsCompanion.insert(
                reminderTime: DateTime(
                  2024,
                  8,
                  10,
                  7,
                  45,
                ).millisecondsSinceEpoch,
                reminderTip: const Value('早安'),
              ),
            );

        // Cold-start / post-restore resyncAll normalizes both legacy rows
        await service.resyncAll();
        expect(scheduler.scheduledById[legacyMorningId]!.hour, 7);
        expect(scheduler.scheduledById[legacyMorningId]!.minute, 45);
        expect(scheduler.scheduledById[legacyEveningId]!.hour, 20);
        expect(scheduler.scheduledById[legacyEveningId]!.minute, 0);
        expect(scheduler.scheduledById[legacyEveningId]!.title, '是时候来记账啦！');

        // Queries return 07:45 before 20:00 despite 2024 epoch > 2020 epoch
        final list = await queries.getReminders();
        expect(list.map((e) => e.displayTime).toList(), [
          '每天 07:45',
          '每天 20:00',
        ]);

        // Duplicate 20:00 creation is rejected against legacy 20:00 row (RE-08)
        await expectLater(
          service.createReminder(commandId: cmd(), hour: 20, minute: 0),
          throwsA(
            isA<Failure>()
                .having((f) => f.code, 'code', FailureCode.validation)
                .having((f) => f.message, 'message', '不能重复创建提醒时间'),
          ),
        );

        // Editing only the tip of the legacy 20:00 row succeeds and upgrades DB column to minuteOfDay
        await service.updateReminder(
          commandId: cmd(),
          id: legacyEveningId,
          hour: 20,
          minute: 0,
          tip: '晚间复盘',
        );
        final upgradedRow = await (db.select(
          db.reminderEvents,
        )..where((t) => t.id.equals(legacyEveningId))).getSingle();
        expect(upgradedRow.reminderTime, 1200);
        expect(upgradedRow.reminderTip, '晚间复盘');
        expect(scheduler.scheduledById[legacyEveningId]!.title, '晚间复盘');
      },
    );

    test(
      'supports ADR-009 command idempotency, conflict rejection, and deletion alarm cleanup (CE-RE-03)',
      () async {
        final createCmd = cmd();
        final id1 = await service.createReminder(
          commandId: createCmd,
          hour: 9,
          minute: 15,
          tip: '记账',
        );
        final idRetry = await service.createReminder(
          commandId: createCmd,
          hour: 9,
          minute: 15,
          tip: '记账',
        );
        expect(idRetry, id1);
        expect(await queries.getReminders(), hasLength(1));

        // Same commandId with different time triggers conflict
        await expectLater(
          service.createReminder(
            commandId: createCmd,
            hour: 10,
            minute: 0,
            tip: '记账',
          ),
          throwsA(
            isA<Failure>().having((f) => f.code, 'code', FailureCode.conflict),
          ),
        );

        // Delete removes DB row and cancels alarm from scheduler
        await service.deleteReminder(commandId: cmd(), id: id1);
        expect(await queries.getReminders(), isEmpty);
        expect(scheduler.scheduledById, isEmpty);
      },
    );

    test(
      'consumes pending launch route /record/new once and streams live taps',
      () async {
        expect(await service.consumePendingLaunchRoute(), isNull);

        scheduler.simulateNotificationTap();
        expect(await service.consumePendingLaunchRoute(), '/record/new');
        expect(await service.consumePendingLaunchRoute(), isNull);

        final received = <String>[];
        final sub = service.onLaunchRoute.listen(received.add);
        scheduler.simulateNotificationTap();
        await Future<void>.delayed(Duration.zero);
        expect(received, ['/record/new']);
        await sub.cancel();
      },
    );
  });

  group('MethodChannelReminderScheduler wire protocol', () {
    test('invokes dev.tallyisle/reminders native methods accurately', () async {
      const channel = MethodChannel('dev.tallyisle/reminders_test');
      final calls = <MethodCall>[];
      var pendingRoute = '/record/new';

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            switch (call.method) {
              case 'areNotificationsEnabled':
                return false;
              case 'requestPermission':
                return true;
              case 'consumePendingLaunchRoute':
                final r = pendingRoute;
                pendingRoute = '';
                return r.isEmpty ? null : r;
              default:
                return null;
            }
          });

      final mcScheduler = MethodChannelReminderScheduler(channel: channel);
      addTearDown(() async {
        await mcScheduler.dispose();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      await mcScheduler.syncReminders([
        const ScheduledReminder(
          id: 7,
          hour: 20,
          minute: 0,
          title: '是时候来记账啦！',
          body: '每天 20:00 · 点击记一笔',
        ),
      ]);
      expect(await mcScheduler.areNotificationsEnabled(), isFalse);
      expect(await mcScheduler.requestPermission(), isTrue);
      await mcScheduler.openNotificationSettings();
      expect(await mcScheduler.consumePendingLaunchRoute(), '/record/new');
      expect(await mcScheduler.consumePendingLaunchRoute(), isNull);
      await mcScheduler.cancelReminder(7);
      await mcScheduler.cancelAll();

      expect(calls.map((c) => c.method).toList(), [
        'syncReminders',
        'areNotificationsEnabled',
        'requestPermission',
        'openNotificationSettings',
        'consumePendingLaunchRoute',
        'consumePendingLaunchRoute',
        'cancelReminder',
        'cancelAll',
      ]);
      final syncArg =
          (calls.first.arguments as Map<Object?, Object?>)['reminders']
              as List<Object?>;
      final firstMap = syncArg.single as Map<Object?, Object?>;
      expect(firstMap['id'], 7);
      expect(firstMap['hour'], 20);
      expect(firstMap['minute'], 0);
      expect(firstMap['title'], '是时候来记账啦！');
      expect(firstMap['route'], '/record/new');
    });
  });
}
