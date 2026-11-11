import 'package:drift/drift.dart';

import '../../domain/rules/reminder_rules.dart';
import '../db/database.dart';

/// Maps a raw `reminder_event` row to normalized domain [ReminderItem] (`CE-RE-01`, `CE-RE-05`).
ReminderItem reminderItemFromRow(ReminderEvent row) => ReminderItem.fromStored(
  id: row.id,
  rawReminderTime: row.reminderTime,
  rawReminderTip: row.reminderTip,
);

/// Read-only queries for daily bookkeeping reminders (F-032, ADR-014).
final class ReminderQueries {
  ReminderQueries(this.db);
  final AppDatabase db;

  /// Watches all reminders normalized to `(hour, minute)` and sorted ascending
  /// by `minuteOfDay` (`08:00 -> 12:30 -> 22:15`, `RE-06` & `CE-RE-01`).
  Stream<List<ReminderItem>> watchReminders() {
    return db
        .select(db.reminderEvents)
        .watch()
        .map((rows) => sortReminderItems(rows.map(reminderItemFromRow)));
  }

  /// Loads all reminders normalized to `(hour, minute)` and sorted ascending
  /// by `minuteOfDay`.
  Future<List<ReminderItem>> getReminders() async {
    final rows = await db.select(db.reminderEvents).get();
    return sortReminderItems(rows.map(reminderItemFromRow));
  }

  /// Loads a single normalized reminder by [id], or `null` if absent.
  Future<ReminderItem?> getReminder(int id) async {
    final row = await (db.select(
      db.reminderEvents,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : reminderItemFromRow(row);
  }

  /// Watches total count of configured reminders across the app.
  Stream<int> watchReminderCount() {
    final countExpr = db.reminderEvents.id.count();
    final query = db.selectOnly(db.reminderEvents)..addColumns([countExpr]);
    return query.watchSingle().map((row) => row.read(countExpr) ?? 0);
  }
}
