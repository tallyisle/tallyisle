import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/domain/rules/periodic_records.dart';

void main() {
  group('Frequency clamping (PB-11)', () {
    test(
      'clamps daily to 1..100, weekly to 1..3, monthly to 1..10, yearly >= 1',
      () {
        // Golden vector PB-11 (docs/modules/periodic-records.md §4)
        expect(clampFrequency(PeriodType.daily, 120), 100);
        expect(clampFrequency(PeriodType.weekly, 5), 3);
        expect(clampFrequency(PeriodType.monthly, 15), 10);

        // Lower bounds and yearly >= 1
        expect(clampFrequency(PeriodType.daily, 0), 1);
        expect(clampFrequency(PeriodType.weekly, -2), 1);
        expect(clampFrequency(PeriodType.monthly, 0), 1);
        expect(clampFrequency(PeriodType.yearly, 0), 1);
        expect(clampFrequency(PeriodType.yearly, 4), 4);
        expect(clampFrequency(PeriodType.yearly, 12), 12);
      },
    );
  });

  group('Calendar progression (R2)', () {
    test('daily advances by clamped frequency from start date', () {
      final startMs = const CalendarDate(2026, 3, 1).startOfDayMs;
      final spec = PeriodScheduleSpec(
        periodType: PeriodType.daily,
        periodTypeDateJson: '[]',
        frequency: 2,
        periodStartDateMs: startMs,
        periodEndDate: periodEndNever,
      );

      final plan = computeCatchUpPlan(spec, const CalendarDate(2026, 3, 5));
      expect(plan.dueDates, const [
        CalendarDate(2026, 3, 1),
        CalendarDate(2026, 3, 3),
        CalendarDate(2026, 3, 5),
      ]);
      expect(plan.nextAddTimes, 3);
      expect(plan.nextState, PeriodState.active);
    });

    test(
      'weekly sorts multi-select weekdays ascending and advances +frequency weeks across week boundary (CE-PB-01)',
      () {
        // 2026-02-06 is Friday (weekday = 5). Targets ["4", "1"] -> [1, 4], freq 5 -> 3.
        final startMs = const CalendarDate(2026, 2, 6).startOfDayMs;
        final spec = PeriodScheduleSpec(
          periodType: PeriodType.weekly,
          periodTypeDateJson: '["4","1"]',
          frequency: 5,
          periodStartDateMs: startMs,
          periodEndDate: periodEndNever,
        );

        final plan = computeCatchUpPlan(spec, const CalendarDate(2026, 3, 5));
        expect(plan.dueDates, const [
          CalendarDate(2026, 2, 23), // Monday (+3 weeks from Feb 2..8 week)
          CalendarDate(2026, 2, 26), // Thursday in the same target week
        ]);

        final afterPlan = spec.copyWith(
          lastAddDateMs: plan.nextLastAddDateMs,
          periodAddTimes: plan.nextAddTimes,
        );
        expect(computeNextDueDate(afterPlan), const CalendarDate(2026, 3, 16));
      },
    );

    test(
      'monthly anchors initial 31st day across short months without chained clamping drift (CE-PB-02)',
      () {
        // Non-leap year 2026: Jan 31 -> Feb 28 -> Mar 31 -> Apr 30 -> May 31
        final spec2026 = PeriodScheduleSpec(
          periodType: PeriodType.monthly,
          periodTypeDateJson: '["31"]',
          frequency: 1,
          periodStartDateMs: const CalendarDate(2026, 1, 31).startOfDayMs,
          periodEndDate: periodEndNever,
        );

        final plan2026 = computeCatchUpPlan(
          spec2026,
          const CalendarDate(2026, 5, 31),
        );
        expect(plan2026.dueDates, const [
          CalendarDate(2026, 1, 31),
          CalendarDate(2026, 2, 28),
          CalendarDate(2026, 3, 31),
          CalendarDate(2026, 4, 30),
          CalendarDate(2026, 5, 31),
        ]);

        // Leap year 2024: Jan 31 -> Feb 29 -> Mar 31
        final spec2024 = PeriodScheduleSpec(
          periodType: PeriodType.monthly,
          periodTypeDateJson: '["31"]',
          frequency: 1,
          periodStartDateMs: const CalendarDate(2024, 1, 31).startOfDayMs,
          periodEndDate: periodEndNever,
        );
        final plan2024 = computeCatchUpPlan(
          spec2024,
          const CalendarDate(2024, 3, 31),
        );
        expect(plan2024.dueDates, const [
          CalendarDate(2024, 1, 31),
          CalendarDate(2024, 2, 29),
          CalendarDate(2024, 3, 31),
        ]);
      },
    );

    test(
      'monthly supports -12 month-end sentinel and deduplicates overlapping end-of-month targets',
      () {
        final spec = PeriodScheduleSpec(
          periodType: PeriodType.monthly,
          periodTypeDateJson: '["-12","15","31"]',
          frequency: 1,
          periodStartDateMs: const CalendarDate(2026, 1, 15).startOfDayMs,
          periodEndDate: periodEndNever,
        );

        final plan = computeCatchUpPlan(spec, const CalendarDate(2026, 3, 31));
        // Jan: 15, 31 (31 & -12 deduplicated); Feb: 15, 28 (31 & -12 both resolve to 28); Mar: 15, 31
        expect(plan.dueDates, const [
          CalendarDate(2026, 1, 15),
          CalendarDate(2026, 1, 31),
          CalendarDate(2026, 2, 15),
          CalendarDate(2026, 2, 28),
          CalendarDate(2026, 3, 15),
          CalendarDate(2026, 3, 31),
        ]);
      },
    );

    test(
      'yearly zero-pads before sorting and falls back 02-29 to Feb 28 in non-leap years (ASYM-PB-02/03, CE-PB-03)',
      () {
        expect(
          normalizePeriodTypeDates(PeriodType.yearly, ['10-5', '2-15', '2-29']),
          const ['02-15', '02-29', '10-05'],
        );

        // Unpadded JSON input ["10-05", "2-15"] must schedule 02-15 before 10-05
        final unpaddedSpec = PeriodScheduleSpec(
          periodType: PeriodType.yearly,
          periodTypeDateJson: '["10-05","2-15"]',
          frequency: 1,
          periodStartDateMs: const CalendarDate(2026, 1, 1).startOfDayMs,
          periodEndDate: periodEndNever,
        );
        expect(
          computeNextDueDate(unpaddedSpec),
          const CalendarDate(2026, 2, 15),
        );

        // 02-29 across leap & non-leap years without skipping any year
        final leapSpec = PeriodScheduleSpec(
          periodType: PeriodType.yearly,
          periodTypeDateJson: '["02-29"]',
          frequency: 1,
          periodStartDateMs: const CalendarDate(2024, 2, 29).startOfDayMs,
          periodEndDate: periodEndNever,
        );
        final leapPlan = computeCatchUpPlan(
          leapSpec,
          const CalendarDate(2028, 3, 1),
        );
        expect(leapPlan.dueDates, const [
          CalendarDate(2024, 2, 29),
          CalendarDate(2025, 2, 28),
          CalendarDate(2026, 2, 28),
          CalendarDate(2027, 2, 28),
          CalendarDate(2028, 2, 29),
        ]);

        // Start after Feb in non-leap year still hits 06-15 in the same year (fixes ASYM-PB-02)
        final multiYearly = PeriodScheduleSpec(
          periodType: PeriodType.yearly,
          periodTypeDateJson: '["2-29","6-15"]',
          frequency: 1,
          periodStartDateMs: const CalendarDate(2025, 3, 1).startOfDayMs,
          periodEndDate: periodEndNever,
        );
        expect(
          computeNextDueDate(multiYearly),
          const CalendarDate(2025, 6, 15),
        );
      },
    );
  });

  group('End conditions & state transitions (R3, DR-PB-03, ASYM-PB-04)', () {
    test(
      'count limit 1..366 transitions to state=1 immediately when count hits limit',
      () {
        // Golden vector: max 3, already generated 2, due once today -> state=1
        final spec = PeriodScheduleSpec(
          periodType: PeriodType.daily,
          periodTypeDateJson: '[]',
          frequency: 1,
          periodStartDateMs: const CalendarDate(2026, 11, 1).startOfDayMs,
          periodEndDate: 3,
          lastAddDateMs: const CalendarDate(2026, 11, 2).startOfDayMs,
          periodAddTimes: 2,
        );

        final plan = computeCatchUpPlan(spec, const CalendarDate(2026, 11, 5));
        expect(plan.dueDates, const [CalendarDate(2026, 11, 3)]);
        expect(plan.nextAddTimes, 3);
        expect(plan.nextState, PeriodState.ended);
      },
    );

    test(
      'end date >366 transitions to state=1 immediately when nextDue > endDate (ASYM-PB-04)',
      () {
        // Golden vector: end date 2026-11-05, after posting 11-05 nextDue is 11-06 > 11-05 -> state=1
        final dailySpec = PeriodScheduleSpec(
          periodType: PeriodType.daily,
          periodTypeDateJson: '[]',
          frequency: 1,
          periodStartDateMs: const CalendarDate(2026, 11, 4).startOfDayMs,
          periodEndDate: const CalendarDate(2026, 11, 5).startOfDayMs,
        );
        final dailyPlan = computeCatchUpPlan(
          dailySpec,
          const CalendarDate(2026, 11, 5),
        );
        expect(dailyPlan.dueDates, const [
          CalendarDate(2026, 11, 4),
          CalendarDate(2026, 11, 5),
        ]);
        expect(dailyPlan.nextState, PeriodState.ended);

        // PR-3 / CE-PB-04: monthly month-end with endDate = 2026-03-20 evaluated on today = 2026-03-05
        final monthlySpec = PeriodScheduleSpec(
          periodType: PeriodType.monthly,
          periodTypeDateJson: '["-12"]',
          frequency: 1,
          periodStartDateMs: const CalendarDate(2026, 1, 31).startOfDayMs,
          periodEndDate: const CalendarDate(2026, 3, 20).startOfDayMs,
        );
        final monthlyPlan = computeCatchUpPlan(
          monthlySpec,
          const CalendarDate(2026, 3, 5),
        );
        expect(monthlyPlan.dueDates, const [
          CalendarDate(2026, 1, 31),
          CalendarDate(2026, 2, 28),
        ]);
        expect(monthlyPlan.nextState, PeriodState.ended);
      },
    );
  });

  group('Resume fast-forward & deterministic timestamps (R5, ASYM-PB-06)', () {
    test(
      'fastForwardMissedDates skips strictly past dates without incrementing periodAddTimes',
      () {
        // PR-8: paused rule with lastAddDate = 2026-03-01, resumed on 2026-03-05
        final pausedSpec = PeriodScheduleSpec(
          periodType: PeriodType.daily,
          periodTypeDateJson: '[]',
          frequency: 1,
          periodStartDateMs: const CalendarDate(2026, 3, 1).startOfDayMs,
          periodEndDate: 5,
          lastAddDateMs: const CalendarDate(2026, 3, 1).startOfDayMs,
          periodAddTimes: 1,
          state: PeriodState.paused,
        );

        final resumed = fastForwardMissedDates(
          pausedSpec,
          const CalendarDate(2026, 3, 5),
        );
        expect(resumed.state, PeriodState.active);
        expect(
          resumed.lastAddDateMs,
          const CalendarDate(2026, 3, 4).startOfDayMs,
        );
        expect(resumed.periodAddTimes, 1);
        expect(computeNextDueDate(resumed), const CalendarDate(2026, 3, 5));
      },
    );

    test(
      'computePeriodicRecordTime follows rte/rt and today vs past 12:00 rule',
      () {
        final now = DateTime(
          2026,
          3,
          5,
          16,
          42,
          19,
          321,
        ).millisecondsSinceEpoch;
        const pastDue = CalendarDate(2026, 3, 3);
        const todayDue = CalendarDate(2026, 3, 5);

        // rte == false: past -> 12:00:00.000, today -> nowMs
        final disabledExtra = PeriodExtra()
          ..recordTimeEnabled = false
          ..recordTime = '08:30';
        expect(
          computePeriodicRecordTime(
            dueDate: pastDue,
            nowMs: now,
            extra: disabledExtra,
          ),
          DateTime(2026, 3, 3, 12).millisecondsSinceEpoch,
        );
        expect(
          computePeriodicRecordTime(
            dueDate: todayDue,
            nowMs: now,
            extra: disabledExtra,
          ),
          now,
        );

        // rte == true: uses dueDate + rt HH:mm:00.000 for both past and today
        final enabledExtra = PeriodExtra()
          ..recordTimeEnabled = true
          ..recordTime = '08:30';
        expect(
          computePeriodicRecordTime(
            dueDate: pastDue,
            nowMs: now,
            extra: enabledExtra,
          ),
          DateTime(2026, 3, 3, 8, 30).millisecondsSinceEpoch,
        );
        expect(
          computePeriodicRecordTime(
            dueDate: todayDue,
            nowMs: now,
            extra: enabledExtra,
          ),
          DateTime(2026, 3, 5, 8, 30).millisecondsSinceEpoch,
        );
      },
    );

    test(
      'computeTransferWithFeeTimestamps shifts parent by -1ms at 23:59:59.999',
      () {
        final normal = DateTime(2026, 3, 5, 23, 59).millisecondsSinceEpoch;
        expect(computeTransferWithFeeTimestamps(normal), (normal, normal + 1));

        final endOfDay = DateTime(
          2026,
          3,
          5,
          23,
          59,
          59,
          999,
        ).millisecondsSinceEpoch;
        expect(computeTransferWithFeeTimestamps(endOfDay), (
          endOfDay - 1,
          endOfDay,
        ));
      },
    );

    test('PeriodExtra preserves unknown keys and rejects corrupt JSON', () {
      final extra = PeriodExtra.parse('{"rt":"09:05","rte":true,"custom":42}');
      expect(extra.recordTimeEnabled, isTrue);
      expect(extra.recordTime, '09:05');
      extra.feeFromTarget = true;
      final roundTrip = PeriodExtra.parse(extra.encode());
      expect(roundTrip.feeFromTarget, isTrue);
      expect(roundTrip.raw['custom'], 42);

      expect(
        () => PeriodExtra.parse('not-json'),
        throwsA(
          isA<Failure>().having((f) => f.code, 'code', FailureCode.corruptData),
        ),
      );
    });
  });
}
