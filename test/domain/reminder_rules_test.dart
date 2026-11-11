import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/domain/rules/reminder_rules.dart';

void main() {
  group('ReminderTime & CE-RE-01 normalization', () {
    test('validates hour and minute boundaries', () {
      expect(ReminderTime(0, 0).minuteOfDay, 0);
      expect(ReminderTime(0, 0).dailyLabel, '每天 00:00');
      expect(ReminderTime(23, 59).minuteOfDay, 1439);
      expect(ReminderTime(23, 59).dailyLabel, '每天 23:59');
      expect(ReminderTime.fromMinuteOfDay(750), ReminderTime(12, 30));

      expect(
        () => ReminderTime(-1, 0),
        throwsA(
          isA<Failure>().having((f) => f.code, 'code', FailureCode.validation),
        ),
      );
      expect(() => ReminderTime(24, 0), throwsA(isA<Failure>()));
      expect(() => ReminderTime(10, 60), throwsA(isA<Failure>()));
      expect(() => ReminderTime.fromMinuteOfDay(1440), throwsA(isA<Failure>()));
    });

    test(
      'normalizes minuteOfDay (0..1439) and legacy epoch-ms timestamps across arbitrary base dates (CE-RE-01)',
      () {
        expect(ReminderTime.normalizeStored(480), ReminderTime(8, 0));
        expect(normalizeReminderMinuteOfDay(1200), 1200);

        // Original app synthetic base date: 2020-12-19 20:00:00.000 local time
        final legacy2020 = DateTime(2020, 12, 19, 20, 0).millisecondsSinceEpoch;
        expect(legacy2020, greaterThanOrEqualTo(1440));
        final norm2020 = ReminderTime.normalizeStored(legacy2020);
        expect(norm2020, ReminderTime(20, 0));
        expect(norm2020.minuteOfDay, 1200);
        expect(norm2020.dailyLabel, '每天 20:00');

        // Imported/synced row from a different calendar date: 2025-07-04 08:05:32.123
        final legacy2025 = DateTime(
          2025,
          7,
          4,
          8,
          5,
          32,
          123,
        ).millisecondsSinceEpoch;
        final norm2025 = ReminderTime.normalizeStored(legacy2025);
        expect(norm2025, ReminderTime(8, 5));
        expect(norm2025.minuteOfDay, 485);
      },
    );
  });

  group('Golden vectors: duplicate check, sorting, and neutral copy', () {
    test(
      'RE-08 (02aae): rejects duplicate (hour, minute) and allows editing tip of same ID',
      () {
        final legacy2000 = DateTime(2020, 12, 19, 20, 0).millisecondsSinceEpoch;
        final existing = [
          ReminderItem.fromStored(
            id: 1,
            rawReminderTime: legacy2000,
            rawReminderTip: '',
          ),
          ReminderItem(id: 2, time: ReminderTime(8, 30), customTip: '早饭'),
        ];

        // Adding another 20:00 reminder is rejected with exact message
        expect(
          () => validateNoDuplicateReminderTime(existing, ReminderTime(20, 0)),
          throwsA(
            isA<Failure>()
                .having((f) => f.code, 'code', FailureCode.validation)
                .having((f) => f.message, 'message', '不能重复创建提醒时间'),
          ),
        );

        // Editing item 1's own tip while keeping 20:00 does not collide with itself
        expect(
          () => validateNoDuplicateReminderTime(
            existing,
            ReminderTime(20, 0),
            excludingId: 1,
          ),
          returnsNormally,
        );

        // Editing item 1 to 08:30 collides with item 2
        expect(
          () => validateNoDuplicateReminderTime(
            existing,
            ReminderTime(8, 30),
            excludingId: 1,
          ),
          throwsA(
            isA<Failure>().having((f) => f.message, 'message', '不能重复创建提醒时间'),
          ),
        );
      },
    );

    test(
      'RE-06 (02aae): sorts 22:15, 08:00, 12:30 ascending to 08:00 -> 12:30 -> 22:15 even with mixed legacy timestamps',
      () {
        final items = [
          ReminderItem.fromStored(
            id: 10,
            rawReminderTime: DateTime(
              2020,
              12,
              19,
              22,
              15,
            ).millisecondsSinceEpoch,
          ),
          ReminderItem.fromStored(
            id: 11,
            rawReminderTime: DateTime(2026, 3, 15, 8, 0).millisecondsSinceEpoch,
          ),
          ReminderItem(id: 12, time: ReminderTime(12, 30)),
        ];

        final sorted = sortReminderItems(items);
        expect(sorted.map((e) => e.displayTime).toList(), [
          '每天 08:00',
          '每天 12:30',
          '每天 22:15',
        ]);
        expect(sorted.map((e) => e.id).toList(), [11, 12, 10]);
      },
    );

    test(
      'DR-RE-06, CE-RE-05 & BRAND-001: preserves blank tip as empty and displays neutral copy without original brand',
      () {
        final nullTipItem = ReminderItem.fromStored(
          id: 1,
          rawReminderTime: 20 * 60,
          rawReminderTip: null,
        );
        final blankTipItem = ReminderItem(
          id: 2,
          time: ReminderTime(20, 0),
          customTip: '   \t  ',
        );
        final customTipItem = ReminderItem(
          id: 3,
          time: ReminderTime(21, 0),
          customTip: '  睡前核对今日开销  ',
        );

        expect(nullTipItem.customTip, isEmpty);
        expect(nullTipItem.displayTime, '每天 20:00');
        expect(nullTipItem.displayTip, '是时候来记账啦！');
        expect(nullTipItem.notificationTitle, '是时候来记账啦！');
        expect(nullTipItem.notificationTitle.contains('一羽记账'), isFalse);
        expect(nullTipItem.notificationBody.contains('一羽记账'), isFalse);

        expect(blankTipItem.customTip, isEmpty);
        expect(blankTipItem.displayTip, '是时候来记账啦！');

        expect(customTipItem.customTip, '睡前核对今日开销');
        expect(customTipItem.displayTip, '睡前核对今日开销');
        expect(customTipItem.notificationTitle, '睡前核对今日开销');
      },
    );
  });

  group('CE-RE-06 daily fire calculation', () {
    test('schedules later today when before target time, else tomorrow', () {
      final target = ReminderTime(20, 0);

      final before = DateTime(2026, 11, 11, 19, 59, 30);
      expect(
        computeNextReminderFireTime(target, before),
        DateTime(2026, 11, 11, 20, 0),
      );

      final exact = DateTime(2026, 11, 11, 20, 0, 0);
      expect(
        computeNextReminderFireTime(target, exact),
        DateTime(2026, 11, 12, 20, 0),
      );

      // Cross-midnight delayed wakeup (23:55 reminder waking at 00:04 next day)
      // schedules 23:55 on that day instead of skipping to D+2!
      final lateNight = ReminderTime(23, 55);
      final afterMidnightWake = DateTime(2026, 11, 12, 0, 4, 0);
      expect(
        computeNextReminderFireTime(lateNight, afterMidnightWake),
        DateTime(2026, 11, 12, 23, 55),
      );
    });
  });
}
