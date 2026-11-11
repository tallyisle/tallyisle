import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../../core/failure.dart';
import '../../domain/rules/reminder_rules.dart';
import '../../platform/notifications.dart';
import '../db/database.dart';
import '../db/failures.dart';
import '../repo/reminder_queries.dart';

/// Write & scheduler-synchronization service for daily bookkeeping reminders
/// (F-032, ADR-008, ADR-009).
final class ReminderService {
  ReminderService(this.db, {ReminderScheduler? scheduler})
    : scheduler = scheduler ?? createReminderScheduler(),
      _queries = ReminderQueries(db);

  final AppDatabase db;
  final ReminderScheduler scheduler;
  final ReminderQueries _queries;

  Future<void> _syncChain = Future<void>.value();

  int _now() => db.nowMs();

  Future<T> _command<T>(
    String commandId,
    List<Object?> payload,
    Future<String> Function() body,
    T Function(String resultId) result,
  ) async {
    if (commandId.isEmpty || commandId.length > 128) {
      throw const Failure(FailureCode.validation, '提交标识无效');
    }
    final hash = sha256.convert(utf8.encode(jsonEncode(payload))).toString();
    return guardDatabase(
      () => db.transaction(() async {
        final previous = await (db.select(
          db.writeCommands,
        )..where((t) => t.commandId.equals(commandId))).getSingleOrNull();
        if (previous != null) {
          if (previous.payloadHash != hash) {
            throw const Failure(FailureCode.conflict, '同一提交标识的内容发生变化');
          }
          return result(previous.resultId);
        }
        final id = await body();
        await db
            .into(db.writeCommands)
            .insert(
              WriteCommandsCompanion.insert(
                commandId: commandId,
                payloadHash: hash,
                resultId: id,
                committedAt: _now(),
              ),
            );
        return result(id);
      }),
    );
  }

  /// Creates a new daily reminder and synchronizes OS alarms (`RE-08`, `CE-RE-01..05`).
  Future<int> createReminder({
    required String commandId,
    required int hour,
    required int minute,
    String? tip,
  }) async {
    final time = ReminderTime(hour, minute);
    final cleanTip = normalizeReminderTip(tip);

    final createdId = await _command(
      commandId,
      ['reminder-create-v1', time.minuteOfDay, cleanTip],
      () async {
        final existingRows = await db.select(db.reminderEvents).get();
        final existingItems = existingRows.map(reminderItemFromRow);
        validateNoDuplicateReminderTime(existingItems, time);

        final newId = await db
            .into(db.reminderEvents)
            .insert(
              ReminderEventsCompanion.insert(
                reminderTime: time.minuteOfDay,
                reminderTip: Value(cleanTip),
              ),
            );
        return newId.toString();
      },
      int.parse,
    );

    await resyncAll();
    return createdId;
  }

  /// Updates an existing reminder's time and/or optional tip (`CE-RE-01`, `CE-RE-05`).
  ///
  /// Blank/null [tip] is preserved as `''` in DB rather than being overwritten
  /// by default copy (`CE-RE-05`). Legacy `reminder_time >= 1440` rows are
  /// cleanly upgraded to `minuteOfDay` upon edit.
  Future<void> updateReminder({
    required String commandId,
    required int id,
    required int hour,
    required int minute,
    String? tip,
  }) async {
    final time = ReminderTime(hour, minute);
    final cleanTip = normalizeReminderTip(tip);

    await _command(
      commandId,
      ['reminder-update-v1', id, time.minuteOfDay, cleanTip],
      () async {
        final target = await (db.select(
          db.reminderEvents,
        )..where((t) => t.id.equals(id))).getSingleOrNull();
        if (target == null) {
          throw const Failure(FailureCode.validation, '提醒不存在');
        }

        final existingRows = await db.select(db.reminderEvents).get();
        final existingItems = existingRows.map(reminderItemFromRow);
        validateNoDuplicateReminderTime(existingItems, time, excludingId: id);

        await (db.update(
          db.reminderEvents,
        )..where((t) => t.id.equals(id))).write(
          ReminderEventsCompanion(
            reminderTime: Value(time.minuteOfDay),
            reminderTip: Value(cleanTip),
          ),
        );
        return id.toString();
      },
      (_) {},
    );

    await resyncAll();
  }

  /// Deletes a reminder row and synchronizes OS alarms so removed reminders
  /// never fire again (`CE-RE-03`).
  Future<void> deleteReminder({
    required String commandId,
    required int id,
  }) async {
    await _command(commandId, ['reminder-delete-v1', id], () async {
      await (db.delete(db.reminderEvents)..where((t) => t.id.equals(id))).go();
      return id.toString();
    }, (_) {});

    await resyncAll();
  }

  /// Idempotently synchronizes the complete active reminder list from SQLite to
  /// [scheduler] (`CE-RE-02..06`).
  ///
  /// Call on cold start, after backup restore, and on system timezone/time
  /// changes, in addition to automatic calls after create/update/delete.
  Future<void> resyncAll() {
    final next = _syncChain.then((_) => _performSync());
    _syncChain = next.catchError((Object _) {});
    return next;
  }

  Future<void> _performSync() async {
    final items = await guardDatabase(_queries.getReminders);
    final scheduled = [
      for (final item in items) ScheduledReminder.fromItem(item),
    ];
    await scheduler.syncReminders(scheduled);
  }

  /// Checks whether system notifications are currently enabled.
  Future<bool> areNotificationsEnabled() => scheduler.areNotificationsEnabled();

  /// Requests runtime notification permission (Android 13+ `POST_NOTIFICATIONS`).
  Future<bool> requestNotificationPermission() => scheduler.requestPermission();

  /// Opens the OS notification settings page for this app.
  Future<void> openNotificationSettings() =>
      scheduler.openNotificationSettings();

  /// Consumes and clears any pending launch route (such as `'/record/new'`)
  /// when the app was opened by tapping a reminder notification.
  Future<String?> consumePendingLaunchRoute() =>
      scheduler.consumePendingLaunchRoute();

  /// Stream of launch routes emitted when a reminder notification is tapped
  /// while the app is already running.
  Stream<String> get onLaunchRoute => scheduler.onLaunchRoute;
}
