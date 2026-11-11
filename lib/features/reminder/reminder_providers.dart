import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../data/reminder/reminder_service.dart';
import '../../data/repo/reminder_queries.dart';
import '../../domain/rules/reminder_rules.dart';
import '../../platform/notifications.dart';

final reminderSchedulerProvider = Provider<ReminderScheduler>((ref) {
  final scheduler = createReminderScheduler();
  ref.onDispose(() => unawaited(scheduler.dispose()));
  return scheduler;
});

final reminderQueriesProvider = FutureProvider<ReminderQueries>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return ReminderQueries(db);
});

final reminderServiceProvider = FutureProvider<ReminderService>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  final scheduler = ref.watch(reminderSchedulerProvider);
  return ReminderService(db, scheduler: scheduler);
});

final remindersProvider = StreamProvider<List<ReminderItem>>((ref) async* {
  final q = await ref.watch(reminderQueriesProvider.future);
  yield* q.watchReminders();
});

final reminderCountProvider = StreamProvider<int>((ref) async* {
  final q = await ref.watch(reminderQueriesProvider.future);
  yield* q.watchReminderCount();
});

final reminderNotificationPermissionProvider = FutureProvider<bool>((
  ref,
) async {
  final scheduler = ref.watch(reminderSchedulerProvider);
  return scheduler.areNotificationsEnabled();
});

/// Optional bootstrap provider for cold-start idempotent alarm synchronization (`CE-RE-04`).
final reminderColdStartSyncProvider = FutureProvider<void>((ref) async {
  final service = await ref.watch(reminderServiceProvider.future);
  await service.resyncAll();
});
