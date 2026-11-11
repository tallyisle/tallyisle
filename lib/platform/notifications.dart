import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/failure.dart';
import '../domain/rules/reminder_rules.dart';
import 'files.dart';

/// Platform payload for a single daily repeating reminder (ADR-008, F-032).
final class ScheduledReminder {
  const ScheduledReminder({
    required this.id,
    required this.hour,
    required this.minute,
    required this.title,
    required this.body,
    this.route = reminderLaunchRoute,
  });

  factory ScheduledReminder.fromItem(ReminderItem item) => ScheduledReminder(
    id: item.id,
    hour: item.time.hour,
    minute: item.time.minute,
    title: item.notificationTitle,
    body: item.notificationBody,
    route: reminderLaunchRoute,
  );

  factory ScheduledReminder.fromMap(Map<Object?, Object?> map) =>
      ScheduledReminder(
        id: map['id'] as int,
        hour: map['hour'] as int,
        minute: map['minute'] as int,
        title: (map['title'] as String?) ?? defaultReminderTip,
        body: (map['body'] as String?) ?? '',
        route: (map['route'] as String?) ?? reminderLaunchRoute,
      );

  final int id;
  final int hour;
  final int minute;
  final String title;
  final String body;
  final String route;

  Map<String, Object> toMap() => {
    'id': id,
    'hour': hour,
    'minute': minute,
    'title': title,
    'body': body,
    'route': route,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ScheduledReminder &&
          id == other.id &&
          hour == other.hour &&
          minute == other.minute &&
          title == other.title &&
          body == other.body &&
          route == other.route;

  @override
  int get hashCode => Object.hash(id, hour, minute, title, body, route);
}

/// Platform boundary for local daily bookkeeping notifications (ADR-008).
abstract interface class ReminderScheduler {
  Capability get capability;

  /// Idempotently synchronizes all active daily reminders with OS scheduling.
  Future<void> syncReminders(List<ScheduledReminder> reminders);

  /// Cancels a single scheduled reminder by [id].
  Future<void> cancelReminder(int id);

  /// Cancels all scheduled reminders.
  Future<void> cancelAll();

  /// Checks whether system notifications are currently enabled for this app.
  Future<bool> areNotificationsEnabled();

  /// Requests runtime notification permission (Android 13+ `POST_NOTIFICATIONS`).
  Future<bool> requestPermission();

  /// Opens the OS notification settings page for this app.
  Future<void> openNotificationSettings();

  /// Consumes and clears any pending deep-link route triggered by tapping a
  /// reminder notification (e.g. `'/record/new'`).
  Future<String?> consumePendingLaunchRoute();

  /// Emits routes when a reminder notification is tapped while the app is alive.
  Stream<String> get onLaunchRoute;

  /// Releases stream resources owned by this scheduler instance.
  Future<void> dispose();
}

const String reminderChannelName = 'dev.tallyisle/reminders';

/// Creates the platform-appropriate [ReminderScheduler].
ReminderScheduler createReminderScheduler() {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    return MethodChannelReminderScheduler();
  }
  return InMemoryReminderScheduler(
    capability: const Capability(
      CapabilityState.unsupported,
      '当前平台使用内存态提醒调度器，系统本地通知仅在 Android 原生端生效',
    ),
  );
}

/// Android native implementation bridged via `MethodChannel('dev.tallyisle/reminders')`.
///
/// If invoked inside headless Flutter widget tests where no native host is
/// attached (`MissingPluginException`), degrades cleanly to an internal
/// [InMemoryReminderScheduler] while surfacing real `PlatformException`s.
final class MethodChannelReminderScheduler implements ReminderScheduler {
  MethodChannelReminderScheduler({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(reminderChannelName) {
    _channel.setMethodCallHandler(_handleNativeCallback);
  }

  final MethodChannel _channel;
  final InMemoryReminderScheduler _fallback = InMemoryReminderScheduler();
  final StreamController<String> _launchRouteController =
      StreamController<String>.broadcast();

  @override
  Capability get capability =>
      const Capability(CapabilityState.available, 'Android 原生每日提醒通知已接入');

  @override
  Stream<String> get onLaunchRoute => _launchRouteController.stream;

  Future<Object?> _handleNativeCallback(MethodCall call) async {
    if (call.method == 'onLaunchRoute') {
      final route = call.arguments as String?;
      if (route != null &&
          route.isNotEmpty &&
          !_launchRouteController.isClosed &&
          _launchRouteController.hasListener) {
        _launchRouteController.add(route);
        return true;
      }
      return false;
    }
    return null;
  }

  @override
  Future<void> syncReminders(List<ScheduledReminder> reminders) async {
    try {
      await _channel.invokeMethod<void>('syncReminders', {
        'reminders': [for (final r in reminders) r.toMap()],
      });
    } on MissingPluginException {
      await _fallback.syncReminders(reminders);
    } on PlatformException catch (e) {
      throw Failure(
        FailureCode.storageUnavailable,
        e.message ?? '同步系统提醒失败，请稍后重试',
      );
    }
  }

  @override
  Future<void> cancelReminder(int id) async {
    try {
      await _channel.invokeMethod<void>('cancelReminder', {'id': id});
    } on MissingPluginException {
      await _fallback.cancelReminder(id);
    } on PlatformException catch (e) {
      throw Failure(
        FailureCode.storageUnavailable,
        e.message ?? '取消系统提醒失败，请稍后重试',
      );
    }
  }

  @override
  Future<void> cancelAll() async {
    try {
      await _channel.invokeMethod<void>('cancelAll');
    } on MissingPluginException {
      await _fallback.cancelAll();
    } on PlatformException catch (e) {
      throw Failure(
        FailureCode.storageUnavailable,
        e.message ?? '清理系统提醒失败，请稍后重试',
      );
    }
  }

  @override
  Future<bool> areNotificationsEnabled() async {
    try {
      return (await _channel.invokeMethod<bool>('areNotificationsEnabled')) ??
          false;
    } on MissingPluginException {
      return _fallback.areNotificationsEnabled();
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<bool> requestPermission() async {
    try {
      return (await _channel.invokeMethod<bool>('requestPermission')) ?? false;
    } on MissingPluginException {
      return _fallback.requestPermission();
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> openNotificationSettings() async {
    try {
      await _channel.invokeMethod<void>('openNotificationSettings');
    } on MissingPluginException {
      await _fallback.openNotificationSettings();
    } on PlatformException catch (e) {
      throw Failure(
        FailureCode.unsupportedCapability,
        e.message ?? '无法打开系统通知设置',
      );
    }
  }

  @override
  Future<String?> consumePendingLaunchRoute() async {
    try {
      return await _channel.invokeMethod<String>('consumePendingLaunchRoute');
    } on MissingPluginException {
      return _fallback.consumePendingLaunchRoute();
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    await _fallback.dispose();
    await _launchRouteController.close();
  }
}

/// Clean deterministic in-memory / no-op implementation for non-Android hosts
/// and automated tests.
final class InMemoryReminderScheduler implements ReminderScheduler {
  InMemoryReminderScheduler({
    this.capability = const Capability(CapabilityState.available, '内存提醒调度器'),
    this.notificationsEnabled = true,
    this.permissionGrantResult = true,
    String? initialPendingLaunchRoute,
  }) : _pendingLaunchRoute = initialPendingLaunchRoute;

  @override
  final Capability capability;

  bool notificationsEnabled;
  bool permissionGrantResult;

  final Map<int, ScheduledReminder> _scheduled = <int, ScheduledReminder>{};
  final List<List<ScheduledReminder>> _syncHistory =
      <List<ScheduledReminder>>[];
  final StreamController<String> _launchRouteController =
      StreamController<String>.broadcast();

  String? _pendingLaunchRoute;
  int requestPermissionCount = 0;
  int openSettingsCount = 0;

  /// Active reminders currently registered in the scheduler, keyed by `reminder.id`.
  Map<int, ScheduledReminder> get scheduledById =>
      Map<int, ScheduledReminder>.unmodifiable(_scheduled);

  /// Active reminders sorted by `id` for assertions.
  List<ScheduledReminder> get scheduledList {
    final items = _scheduled.values.toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    return List<ScheduledReminder>.unmodifiable(items);
  }

  /// Recorded history of every `syncReminders` snapshot call.
  List<List<ScheduledReminder>> get syncHistory =>
      List<List<ScheduledReminder>>.unmodifiable(_syncHistory);

  @override
  Stream<String> get onLaunchRoute => _launchRouteController.stream;

  @override
  Future<void> syncReminders(List<ScheduledReminder> reminders) async {
    _scheduled
      ..clear()
      ..addEntries(reminders.map((r) => MapEntry(r.id, r)));
    _syncHistory.add(List<ScheduledReminder>.unmodifiable(reminders));
  }

  @override
  Future<void> cancelReminder(int id) async {
    _scheduled.remove(id);
  }

  @override
  Future<void> cancelAll() async {
    _scheduled.clear();
  }

  @override
  Future<bool> areNotificationsEnabled() async => notificationsEnabled;

  @override
  Future<bool> requestPermission() async {
    requestPermissionCount++;
    if (permissionGrantResult) {
      notificationsEnabled = true;
    }
    return notificationsEnabled;
  }

  @override
  Future<void> openNotificationSettings() async {
    openSettingsCount++;
  }

  @override
  Future<String?> consumePendingLaunchRoute() async {
    final route = _pendingLaunchRoute;
    _pendingLaunchRoute = null;
    return route;
  }

  /// Simulates a user tapping a fired notification.
  void simulateNotificationTap({String route = reminderLaunchRoute}) {
    if (!_launchRouteController.isClosed &&
        _launchRouteController.hasListener) {
      _launchRouteController.add(route);
    } else {
      _pendingLaunchRoute = route;
    }
  }

  @override
  Future<void> dispose() async {
    await _launchRouteController.close();
  }
}
