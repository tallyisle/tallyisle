import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/domain/rules/savings_plan.dart';

void main() {
  BigInt yuan(int whole, [int cents = 0]) => BigInt.from(whole * 100 + cents);

  group('R1 Target formulas & classic templates (SP-11, SP-23)', () {
    test('Golden vector SP-11: 365-day incremental template -> 66,795.00', () {
      const start = LocalCalendarDate(2026, 1, 1);
      final tpl = SavingsPlanTemplate.days365(start);

      expect(tpl.name, '365天存钱');
      expect(tpl.planType, SavingsPlanType.incremental);
      expect(tpl.cycleType, SavingsCycleType.daily);
      expect(tpl.periodCount, 365);
      expect(tpl.endDate, const LocalCalendarDate(2026, 12, 31));
      expect(tpl.startMoneyMinor, yuan(1));
      expect(tpl.incrementalMinor, yuan(1));
      expect(tpl.planMoneyMinor, yuan(66795));
    });

    test('Golden vector SP-11: 52-week incremental template -> 13,780.00', () {
      const start = LocalCalendarDate(2026, 1, 1);
      final tpl = SavingsPlanTemplate.weeks52(start);

      expect(tpl.name, '52周存钱');
      expect(tpl.planType, SavingsPlanType.incremental);
      expect(tpl.cycleType, SavingsCycleType.weekly);
      expect(tpl.periodCount, 52);
      expect(tpl.startMoneyMinor, yuan(10));
      expect(tpl.incrementalMinor, yuan(10));
      expect(tpl.planMoneyMinor, yuan(13780));
    });

    test(
      'Exact BigInt arithmetic avoids IEEE-754 drift (N=3, start=0.10, inc=0.20 -> 0.90)',
      () {
        final target = computePlanTargetMinor(
          planType: SavingsPlanType.incremental,
          periodCount: 3,
          startMoneyMinor: yuan(0, 10),
          incrementalMinor: yuan(0, 20),
        );
        expect(target, yuan(0, 90));

        final slots = generateScheduleSlots(
          planType: SavingsPlanType.incremental,
          cycleType: SavingsCycleType.daily,
          start: const LocalCalendarDate(2026, 3, 1),
          end: const LocalCalendarDate(2026, 3, 3),
          startMoneyMinor: yuan(0, 10),
          incrementalMinor: yuan(0, 20),
        );
        expect(slots.map((s) => s.plannedMoneyMinor).toList(), [
          yuan(0, 10),
          yuan(0, 30),
          yuan(0, 50),
        ]);
        expect(slots.last.plannedCumulativeMinor, target);
      },
    );

    test('Fixed plan target = N * start; Free plan uses custom target', () {
      final fixed = computePlanTargetMinor(
        planType: SavingsPlanType.fixed,
        periodCount: 12,
        startMoneyMinor: yuan(500),
      );
      expect(fixed, yuan(6000));

      final free = computePlanTargetMinor(
        planType: SavingsPlanType.free,
        customPlanMoneyMinor: yuan(8888, 88),
      );
      expect(free, yuan(8888, 88));

      expect(
        () => computePlanTargetMinor(
          planType: SavingsPlanType.free,
          customPlanMoneyMinor: BigInt.zero,
        ),
        throwsA(isA<Failure>()),
      );
    });

    test(
      'Golden vector SP-23: free plan cumulative target back-calculation (500 - 300 = 200)',
      () {
        final delta = computeFreePlanDeltaMinor(
          currentSavedMinor: yuan(300),
          targetCumulativeMinor: yuan(500),
        );
        expect(delta, yuan(200));

        // 02aad §4.1 SP-503: 230.55 - 150.00 = 80.55
        final delta2 = computeFreePlanDeltaMinor(
          currentSavedMinor: yuan(150),
          targetCumulativeMinor: yuan(230, 55),
        );
        expect(delta2, yuan(80, 55));

        expect(
          () => computeFreePlanDeltaMinor(
            currentSavedMinor: yuan(500),
            targetCumulativeMinor: yuan(500),
          ),
          throwsA(isA<Failure>()),
        );
        expect(
          () => computeFreePlanDeltaMinor(
            currentSavedMinor: yuan(500),
            targetCumulativeMinor: yuan(400),
          ),
          throwsA(isA<Failure>()),
        );
      },
    );
  });

  group('R4 Unified calendar progression & leap-day alignment (CE-SP-03)', () {
    test(
      'CE-SP-03: yearly leap-day range 2024-02-29..2025-02-28 yields N=2 in BOTH form and slots',
      () {
        const start = LocalCalendarDate(2024, 2, 29);
        const end = LocalCalendarDate(2025, 2, 28);

        final formPeriods = countSchedulePeriods(
          start: start,
          end: end,
          cycleType: SavingsCycleType.yearly,
        );
        final slots = generateScheduleSlots(
          planType: SavingsPlanType.fixed,
          cycleType: SavingsCycleType.yearly,
          start: start,
          end: end,
          startMoneyMinor: yuan(100),
          incrementalMinor: BigInt.zero,
        );

        expect(formPeriods, 2);
        expect(slots, hasLength(2));
        expect(slots[0].date, const LocalCalendarDate(2024, 2, 29));
        expect(slots[1].date, const LocalCalendarDate(2025, 2, 28));
        expect(
          computePlanTargetMinor(
            planType: SavingsPlanType.fixed,
            periodCount: formPeriods,
            startMoneyMinor: yuan(100),
          ),
          slots.last.plannedCumulativeMinor,
        );
      },
    );

    test(
      'DR-SP-02: monthly progression chains end-of-month clamping (01-31 -> 02-28 -> 03-28 -> 04-28)',
      () {
        final dates = generateScheduleDates(
          start: const LocalCalendarDate(2026, 1, 31),
          end: const LocalCalendarDate(2026, 4, 30),
          cycleType: SavingsCycleType.monthly,
        );
        expect(dates, const [
          LocalCalendarDate(2026, 1, 31),
          LocalCalendarDate(2026, 2, 28),
          LocalCalendarDate(2026, 3, 28),
          LocalCalendarDate(2026, 4, 28),
        ]);
      },
    );

    test(
      'Rejects invalid cycle codes (including unused code 4) and end < start',
      () {
        expect(
          () => generateScheduleDates(
            start: const LocalCalendarDate(2026, 1, 1),
            end: const LocalCalendarDate(2026, 1, 10),
            cycleType: 4,
          ),
          throwsA(isA<Failure>()),
        );
        expect(
          () => generateScheduleDates(
            start: const LocalCalendarDate(2026, 2, 1),
            end: const LocalCalendarDate(2026, 1, 31),
            cycleType: SavingsCycleType.daily,
          ),
          throwsA(isA<Failure>()),
        );
      },
    );
  });

  group('R7 Schedule merging & out-of-schedule preservation (CE-SP-07)', () {
    test(
      'Wall-clock manual check-in matches calendar slot and out-of-schedule records stay visible',
      () {
        const start = LocalCalendarDate(2026, 3, 2);
        const end = LocalCalendarDate(2026, 3, 4);

        final records = <({int id, int dateMs, BigInt money})>[
          // Historical record from before plan start date was edited:
          (
            id: 1,
            dateMs: DateTime(2026, 2, 25, 9, 0).millisecondsSinceEpoch,
            money: yuan(50),
          ),
          // Wall-clock check-in on 2026-03-02 12:30:00.000:
          (
            id: 2,
            dateMs: DateTime(2026, 3, 2, 12, 30).millisecondsSinceEpoch,
            money: yuan(10),
          ),
          // Historical record after plan end date:
          (
            id: 3,
            dateMs: DateTime(2026, 3, 10, 18, 15).millisecondsSinceEpoch,
            money: yuan(99),
          ),
        ];

        final merged = mergeSavingsSchedule(
          planType: SavingsPlanType.incremental,
          cycleType: SavingsCycleType.daily,
          startDateMs: start.startOfDayMs,
          endDateMs: end.startOfDayMs,
          startMoneyMinor: yuan(10),
          incrementalMinor: yuan(5),
          records: records,
          recordDateOf: (r) => r.dateMs,
          recordIdOf: (r) => r.id,
          recordMoneyOf: (r) => r.money,
        );

        expect(merged.slots, hasLength(3));
        expect(merged.slots[0].isSaved, isTrue);
        expect(merged.slots[0].matchedRecord?.id, 2);
        expect(merged.slots[1].isSaved, isFalse);
        expect(merged.slots[2].isSaved, isFalse);

        // Out-of-schedule records ordered newest-first, none lost!
        expect(merged.outOfScheduleRecords.map((r) => r.id).toList(), [3, 1]);
      },
    );

    test(
      'Free plan computes true chronological running cumulative and outputs newest-first (SP-503)',
      () {
        final records = <({int id, int dateMs, BigInt money})>[
          (
            id: 1,
            dateMs: DateTime(2026, 3, 1, 10, 0).millisecondsSinceEpoch,
            money: yuan(100),
          ),
          (
            id: 2,
            dateMs: DateTime(2026, 3, 2, 10, 0).millisecondsSinceEpoch,
            money: yuan(50),
          ),
          (
            id: 3,
            dateMs: DateTime(2026, 3, 3, 10, 0).millisecondsSinceEpoch,
            money: yuan(80, 55),
          ),
        ];

        final merged = mergeSavingsSchedule(
          planType: SavingsPlanType.free,
          cycleType: SavingsCycleType.free,
          startDateMs: const LocalCalendarDate(2026, 3, 1).startOfDayMs,
          endDateMs: -1,
          startMoneyMinor: BigInt.zero,
          incrementalMinor: BigInt.zero,
          records: records,
          recordDateOf: (r) => r.dateMs,
          recordIdOf: (r) => r.id,
          recordMoneyOf: (r) => r.money,
        );

        expect(merged.freePlanRows.map((r) => r.record.id).toList(), [3, 2, 1]);
        expect(
          merged.freePlanRows.map((r) => r.runningCumulativeMinor).toList(),
          [yuan(230, 55), yuan(150), yuan(100)],
        );
      },
    );
  });

  group('DR-SP-06 conductTip 5 branches & multi-currency quotes (CE-SP-08)', () {
    test('conductTip matches all 5 branches (SP-01b)', () {
      const today = LocalCalendarDate(2026, 3, 3);
      final mar1 = const LocalCalendarDate(2026, 3, 1).startOfDayMs;
      final mar3 = const LocalCalendarDate(2026, 3, 3).startOfDayMs;
      final mar5 = const LocalCalendarDate(2026, 3, 5).startOfDayMs;
      final mar10 = const LocalCalendarDate(2026, 3, 10).startOfDayMs;
      final feb28 = const LocalCalendarDate(2026, 2, 28).startOfDayMs;
      final feb20 = const LocalCalendarDate(2026, 2, 20).startOfDayMs;

      // 1. start == -1
      expect(
        formatConductTip(
          startDateMs: -1,
          endDateMs: mar10,
          status: SavingsPlanStatus.active,
          today: today,
        ),
        '',
      );
      // 2. start > today
      expect(
        formatConductTip(
          startDateMs: mar5,
          endDateMs: mar10,
          status: SavingsPlanStatus.active,
          today: today,
        ),
        '',
      );
      expect(
        formatConductTip(
          startDateMs: mar5,
          endDateMs: mar10,
          status: SavingsPlanStatus.archived,
          today: today,
        ),
        ' 已归档计划',
      );
      // 3. end == -1 (open-ended free plan)
      expect(
        formatConductTip(
          startDateMs: mar1,
          endDateMs: -1,
          status: SavingsPlanStatus.active,
          today: today,
        ),
        '已存钱3天',
      );
      // 4. end < today (capped to total plan span)
      expect(
        formatConductTip(
          startDateMs: feb20,
          endDateMs: feb28,
          status: SavingsPlanStatus.active,
          today: today,
        ),
        '已存钱9天',
      );
      // 5. start <= today <= end
      expect(
        formatConductTip(
          startDateMs: mar1,
          endDateMs: mar5,
          status: SavingsPlanStatus.active,
          today: today,
        ),
        '已存钱3天，还剩2天',
      );
      expect(
        formatConductTip(
          startDateMs: mar1,
          endDateMs: mar3,
          status: SavingsPlanStatus.active,
          today: today,
        ),
        '已存钱3天，还剩0天',
      );
      expect(
        formatConductTip(
          startDateMs: mar1,
          endDateMs: mar5,
          status: SavingsPlanStatus.archived,
          today: today,
        ),
        '已存钱3天 已归档计划',
      );
    });

    test(
      'CE-SP-08: summarizeActiveSavingsPlans converts valid FX and flags missing/zero rates',
      () {
        final summary = summarizeActiveSavingsPlans(
          plans: [
            SavingsActivePlanInput(
              id: 501,
              savedMoneyMinor: yuan(10),
              currency: 'CNY',
            ),
            SavingsActivePlanInput(
              id: 502,
              savedMoneyMinor: yuan(100),
              currency: 'USD',
            ),
            SavingsActivePlanInput(
              id: 503,
              savedMoneyMinor: yuan(120),
              currency: null,
            ),
            SavingsActivePlanInput(
              id: 504,
              savedMoneyMinor: yuan(50),
              currency: 'CNY',
            ),
            SavingsActivePlanInput(
              id: 506,
              savedMoneyMinor: yuan(30),
              currency: 'EUR', // missing rate
            ),
            SavingsActivePlanInput(
              id: 507,
              savedMoneyMinor: yuan(500),
              currency: 'JPY', // zero rate
            ),
          ],
          rawRates: {'CNY': '1', 'USD': '0.125', 'JPY': '0'},
        );

        // 10 + 100/0.125(=800) + 120 + 50 = 980.00 CNY; EUR & JPY flagged!
        expect(summary.totalSavedBaseMinor, yuan(980));
        expect(summary.activeCount, 6);
        expect(summary.missingRates, {'EUR', 'JPY'});
      },
    );

    test(
      'R5 / CE-SP-08: quoteSavingsTransfer builds CurrencySnapshot and rejects missing/<=0 rates',
      () {
        // SP-502: 100 USD plan, from CNY -> to USD (1 USD = 8 CNY => rateToAnchor 0.125)
        final quote = quoteSavingsTransfer(
          depositPlanMinor: yuan(100),
          planCurrency: 'USD',
          fromAssetCurrency: 'CNY',
          toAssetCurrency: 'USD',
          rawRates: {'CNY': '1', 'USD': '0.125'},
        );
        expect(quote.fromMinor, yuan(800));
        expect(quote.toMinor, yuan(100));
        expect(quote.snapshot?.sourceCode, 'CNY');
        expect(quote.snapshot?.sourceGross, yuan(800));
        expect(quote.snapshot?.assetCode, 'USD');
        expect(quote.snapshot?.assetNet, yuan(100));
        expect(quote.snapshot?.baseCode, 'CNY');
        expect(quote.snapshot?.baseAmount, yuan(800));

        // Missing EUR rate -> throws validation Failure
        expect(
          () => quoteSavingsTransfer(
            depositPlanMinor: yuan(50),
            planCurrency: 'EUR',
            fromAssetCurrency: 'CNY',
            toAssetCurrency: 'EUR',
            rawRates: {'CNY': '1'},
          ),
          throwsA(isA<Failure>()),
        );

        // Zero JPY rate -> throws validation Failure
        expect(
          () => quoteSavingsTransfer(
            depositPlanMinor: yuan(1000),
            planCurrency: 'JPY',
            fromAssetCurrency: 'CNY',
            toAssetCurrency: 'JPY',
            rawRates: {'CNY': '1', 'JPY': '0.0'},
          ),
          throwsA(isA<Failure>()),
        );
      },
    );

    test(
      'SavingsPlanExtra parses/encodes cleanly and progress bps is exact',
      () {
        expect(SavingsPlanExtra.parse(null).currency, 'CNY');
        expect(SavingsPlanExtra.parse('not-json').currency, 'CNY');
        final parsed = SavingsPlanExtra.parse('{"curr":" usd ","k":1}');
        expect(parsed.currency, 'USD');
        expect(parsed.raw['k'], 1);

        expect(
          computeProgressBasisPoints(yuan(100), yuan(300)),
          BigInt.from(3333),
        );
        expect(formatProgressPercent(yuan(100), yuan(300)), '33.33%');
        expect(clampedProgressPermille(yuan(1500), yuan(1000)), 1000);
        expect(clampedProgressPermille(BigInt.zero, yuan(1000)), 0);
      },
    );
  });
}
