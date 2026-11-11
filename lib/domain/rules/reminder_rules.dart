import '../../core/failure.dart';

/// Neutral default notification copy when custom tip is blank (BRAND-001, DR-RE-06).
const String defaultReminderTip = '是时候来记账啦！';

/// Android notification channel metadata (docs/modules/reminder.md §6).
const String reminderNotificationChannelId = 'bookkeeping_reminder';
const String reminderNotificationChannelName = '记账提醒';

/// Deep-link target route when tapping a reminder notification (R3).
const String reminderLaunchRoute = '/record/new';

const int minutesPerDay = 24 * 60;

/// Daily wall-clock reminder time decoupled from any epoch base date (R1 / CE-RE-01).
final class ReminderTime implements Comparable<ReminderTime> {
  factory ReminderTime(int hour, int minute) {
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
      throw const Failure(FailureCode.validation, '提醒时间无效');
    }
    return ReminderTime._(hour, minute);
  }

  const ReminderTime._(this.hour, this.minute);

  factory ReminderTime.fromMinuteOfDay(int minuteOfDay) {
    if (minuteOfDay < 0 || minuteOfDay >= minutesPerDay) {
      throw const Failure(FailureCode.validation, '提醒时间无效');
    }
    return ReminderTime._(minuteOfDay ~/ 60, minuteOfDay % 60);
  }

  /// Normalizes a stored `reminder_event.reminder_time` integer (`CE-RE-01`).
  ///
  /// Values in `0..1439` are already `minuteOfDay`. Legacy imported values
  /// `>= 1440` (such as `2020-12-19 HH:mm:00.000` epoch ms or any other base
  /// date) or negative epoch timestamps are converted via local [DateTime]
  /// into `(hour, minute)`.
  factory ReminderTime.normalizeStored(int rawReminderTime) {
    if (rawReminderTime >= 0 && rawReminderTime < minutesPerDay) {
      return ReminderTime._(rawReminderTime ~/ 60, rawReminderTime % 60);
    }
    final local = DateTime.fromMillisecondsSinceEpoch(rawReminderTime);
    return ReminderTime._(local.hour, local.minute);
  }

  final int hour;
  final int minute;

  /// `0..1439` (`hour * 60 + minute`).
  int get minuteOfDay => hour * 60 + minute;

  /// Zero-padded `"HH:mm"`, e.g. `"08:00"`, `"20:00"`.
  String get hhmm =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  /// Display time label in list UI, e.g. `"每天 20:00"`.
  String get dailyLabel => '每天 $hhmm';

  @override
  int compareTo(ReminderTime other) => minuteOfDay.compareTo(other.minuteOfDay);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReminderTime && hour == other.hour && minute == other.minute;

  @override
  int get hashCode => Object.hash(hour, minute);

  @override
  String toString() => hhmm;
}

/// Convenience helper returning `0..1439` for any stored `reminder_time`.
int normalizeReminderMinuteOfDay(int rawReminderTime) =>
    ReminderTime.normalizeStored(rawReminderTime).minuteOfDay;

/// Preserves blank/null `reminder_tip` as empty `''` for DB storage and edit
/// dialogs so blank tips are never overwritten by default copy (`CE-RE-05`).
String normalizeReminderTip(String? rawTip) {
  if (rawTip == null) return '';
  final trimmed = rawTip.trim();
  return trimmed.isEmpty ? '' : trimmed;
}

/// Resolves the user-visible / notification copy, falling back to
/// [defaultReminderTip] when [rawTip] is null or blank (`DR-RE-06`, `BRAND-001`).
String effectiveReminderTip(String? rawTip) {
  final clean = normalizeReminderTip(rawTip);
  return clean.isEmpty ? defaultReminderTip : clean;
}

/// Domain entity for a daily bookkeeping reminder (F-032).
final class ReminderItem {
  ReminderItem({required this.id, required this.time, String? customTip})
    : customTip = normalizeReminderTip(customTip);

  factory ReminderItem.fromStored({
    required int id,
    required int rawReminderTime,
    String? rawReminderTip,
  }) => ReminderItem(
    id: id,
    time: ReminderTime.normalizeStored(rawReminderTime),
    customTip: rawReminderTip,
  );

  final int id;
  final ReminderTime time;

  /// User's custom tip, or `''` when left blank (`CE-RE-05`).
  final String customTip;

  int get minuteOfDay => time.minuteOfDay;

  /// `"每天 HH:mm"` (`DR-RE-06`).
  String get displayTime => time.dailyLabel;

  /// Custom tip when non-empty, otherwise `'是时候来记账啦！'` (`DR-RE-06`).
  String get displayTip => effectiveReminderTip(customTip);

  /// Notification title when fired (`DR-RE-06`).
  String get notificationTitle => effectiveReminderTip(customTip);

  /// Secondary notification text when fired.
  String get notificationBody => '$displayTime · 点击记一笔';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReminderItem &&
          id == other.id &&
          time == other.time &&
          customTip == other.customTip;

  @override
  int get hashCode => Object.hash(id, time, customTip);
}

/// Rejects duplicate `(hour, minute)` across existing reminders (`RE-08`).
///
/// When updating an existing reminder, pass [excludingId] so editing only the
/// tip of the same reminder never collides with itself (`CE-RE-01`).
void validateNoDuplicateReminderTime(
  Iterable<ReminderItem> existing,
  ReminderTime candidate, {
  int? excludingId,
}) {
  for (final item in existing) {
    if (excludingId != null && item.id == excludingId) continue;
    if (item.time.minuteOfDay == candidate.minuteOfDay) {
      throw const Failure(FailureCode.validation, '不能重复创建提醒时间');
    }
  }
}

/// Sorts reminders ascending by `minuteOfDay` (`08:00 -> 12:30 -> 22:15`, `RE-06`),
/// breaking any ties deterministically by `id`.
List<ReminderItem> sortReminderItems(Iterable<ReminderItem> items) {
  final list = List<ReminderItem>.of(items);
  list.sort((a, b) {
    final cmp = a.time.minuteOfDay.compareTo(b.time.minuteOfDay);
    if (cmp != 0) return cmp;
    return a.id.compareTo(b.id);
  });
  return list;
}

/// Computes the next local calendar fire [DateTime] strictly after [now]
/// without fixed-millisecond drift or cross-midnight day skipping (`CE-RE-06`).
DateTime computeNextReminderFireTime(ReminderTime time, DateTime now) {
  final todayCandidate = DateTime(
    now.year,
    now.month,
    now.day,
    time.hour,
    time.minute,
  );
  if (todayCandidate.isAfter(now)) {
    return todayCandidate;
  }
  return DateTime(now.year, now.month, now.day + 1, time.hour, time.minute);
}
