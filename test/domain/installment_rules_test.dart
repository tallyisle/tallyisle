import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/domain/ledger/asset_json.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/asset_overview.dart';
import 'package:tallyisle/domain/rules/credit_cycle.dart'
    show calculateCardDisplayBalance;
import 'package:tallyisle/domain/rules/installment_rules.dart';

void main() {
  BigInt m(int minor) => BigInt.from(minor);

  group('R1 per-period schedule golden vectors & exact conservation', () {
    test(
      'FLOOR2 (calWay=0) + perPeriod (chargeWay=1) + first/last remainder',
      () {
        final startMs = DateTime(2026, 3, 15).millisecondsSinceEpoch;
        final firstRem = buildInstallmentSchedule(
          installmentId: 1,
          principalMinor: m(100000), // 1000.00
          periods: 6,
          chargeMinor: m(3100), // 31.00
          chargeWay: InstallmentChargeWay.perPeriod,
          calWay: InstallmentCalWay.floor2,
          remainderIn: InstallmentRemainderIn.firstPeriod,
          startDateMs: startMs,
        );
        expect(firstRem.map((e) => e.principalMinor).toList(), [
          m(16670),
          m(16666),
          m(16666),
          m(16666),
          m(16666),
          m(16666),
        ]);
        expect(firstRem.map((e) => e.feeMinor).toList(), [
          m(520),
          m(516),
          m(516),
          m(516),
          m(516),
          m(516),
        ]);

        final lastRem = buildInstallmentSchedule(
          installmentId: 1,
          principalMinor: m(100000),
          periods: 6,
          chargeMinor: m(3100),
          chargeWay: InstallmentChargeWay.perPeriod,
          calWay: InstallmentCalWay.floor2,
          remainderIn: InstallmentRemainderIn.lastPeriod,
          startDateMs: startMs,
        );
        expect(lastRem.map((e) => e.principalMinor).toList(), [
          m(16666),
          m(16666),
          m(16666),
          m(16666),
          m(16666),
          m(16670),
        ]);
        expect(lastRem.map((e) => e.feeMinor).toList(), [
          m(516),
          m(516),
          m(516),
          m(516),
          m(516),
          m(520),
        ]);
      },
    );

    test(
      'HALF_UP0 (calWay=1) negative principal remainder + positive fee remainder',
      () {
        final startMs = DateTime(2026, 3, 15).millisecondsSinceEpoch;
        final s = buildInstallmentSchedule(
          installmentId: 2,
          principalMinor: m(100000), // 1000.00 -> base 167.00, rem -2.00
          periods: 6,
          chargeMinor: m(3100), // 31.00 -> base 5.00, rem +1.00
          chargeWay: InstallmentChargeWay.perPeriod,
          calWay: InstallmentCalWay.halfUp0,
          remainderIn: InstallmentRemainderIn.lastPeriod,
          startDateMs: startMs,
        );
        expect(s.map((e) => e.principalMinor).toList(), [
          m(16700),
          m(16700),
          m(16700),
          m(16700),
          m(16700),
          m(16500),
        ]);
        expect(s.map((e) => e.feeMinor).toList(), [
          m(500),
          m(500),
          m(500),
          m(500),
          m(500),
          m(600),
        ]);
      },
    );

    test(
      'HALF_UP2 (calWay=2) + lastPeriod remainder (1000.00 & 31.00 / 6)',
      () {
        final startMs = DateTime(2026, 3, 15).millisecondsSinceEpoch;
        final s = buildInstallmentSchedule(
          installmentId: 3,
          principalMinor: m(100000),
          periods: 6,
          chargeMinor: m(3100),
          chargeWay: InstallmentChargeWay.perPeriod,
          calWay: InstallmentCalWay.halfUp2,
          remainderIn: InstallmentRemainderIn.lastPeriod,
          startDateMs: startMs,
        );
        expect(s.map((e) => e.principalMinor).toList(), [
          m(16667),
          m(16667),
          m(16667),
          m(16667),
          m(16667),
          m(16665),
        ]);
        expect(s.map((e) => e.feeMinor).toList(), [
          m(517),
          m(517),
          m(517),
          m(517),
          m(517),
          m(515),
        ]);
      },
    );

    test(
      'FLOOR0 (calWay=3) + chargeWay=0 (firstPeriod) and chargeWay=2 (lastPeriod)',
      () {
        final startMs = DateTime(2026, 3, 15).millisecondsSinceEpoch;
        final firstFee = buildInstallmentSchedule(
          installmentId: 4,
          principalMinor: m(100000),
          periods: 6,
          chargeMinor: m(3100),
          chargeWay: InstallmentChargeWay.firstPeriod,
          calWay: InstallmentCalWay.floor0,
          remainderIn: InstallmentRemainderIn.firstPeriod,
          startDateMs: startMs,
        );
        expect(firstFee.map((e) => e.principalMinor).toList(), [
          m(17000),
          m(16600),
          m(16600),
          m(16600),
          m(16600),
          m(16600),
        ]);
        expect(firstFee.map((e) => e.feeMinor).toList(), [
          m(3100),
          m(0),
          m(0),
          m(0),
          m(0),
          m(0),
        ]);

        final lastFee = buildInstallmentSchedule(
          installmentId: 4,
          principalMinor: m(100100), // 1001.00 -> base 166.00, rem 5.00
          periods: 6,
          chargeMinor: m(3100),
          chargeWay: InstallmentChargeWay.lastPeriod,
          calWay: InstallmentCalWay.floor0,
          remainderIn: InstallmentRemainderIn.lastPeriod,
          startDateMs: startMs,
        );
        expect(lastFee.map((e) => e.principalMinor).toList(), [
          m(16600),
          m(16600),
          m(16600),
          m(16600),
          m(16600),
          m(17100),
        ]);
        expect(lastFee.map((e) => e.feeMinor).toList(), [
          m(0),
          m(0),
          m(0),
          m(0),
          m(0),
          m(3100),
        ]);
      },
    );

    test('AL-29 & AL-30 tiny-amount negative remainder golden vectors', () {
      final startMs = DateTime(2026, 5, 1).millisecondsSinceEpoch;
      // AL-29: principal 0.03 over 6 periods, HALF_UP2, remainder in last period
      final al29 = buildInstallmentSchedule(
        installmentId: 29,
        principalMinor: m(3),
        periods: 6,
        chargeMinor: m(0),
        chargeWay: InstallmentChargeWay.perPeriod,
        calWay: InstallmentCalWay.halfUp2,
        remainderIn: InstallmentRemainderIn.lastPeriod,
        startDateMs: startMs,
      );
      expect(al29.map((e) => e.principalMinor).toList(), [
        m(1),
        m(1),
        m(1),
        m(1),
        m(1),
        m(-2),
      ]);
      expect(
        al29.fold<BigInt>(BigInt.zero, (s, e) => s + e.principalMinor),
        m(3),
      );

      // AL-30: principal 6.00, fee 0.03 over 6 periods, HALF_UP2, remainder in first period
      final al30 = buildInstallmentSchedule(
        installmentId: 30,
        principalMinor: m(600),
        periods: 6,
        chargeMinor: m(3),
        chargeWay: InstallmentChargeWay.perPeriod,
        calWay: InstallmentCalWay.halfUp2,
        remainderIn: InstallmentRemainderIn.firstPeriod,
        startDateMs: startMs,
      );
      expect(al30.map((e) => e.feeMinor).toList(), [
        m(-2),
        m(1),
        m(1),
        m(1),
        m(1),
        m(1),
      ]);
      expect(al30.fold<BigInt>(BigInt.zero, (s, e) => s + e.feeMinor), m(3));
    });

    test(
      'exhaustive conservation across calWay, chargeWay, remainderIn, periods, and large BigInt',
      () {
        final startMs = DateTime(2026, 1, 10).millisecondsSinceEpoch;
        final principals = <BigInt>[
          m(1),
          m(3),
          m(7),
          m(100),
          m(99999),
          BigInt.parse('8888888888800'),
        ];
        final charges = <BigInt>[m(0), m(3), m(29), m(3100), m(123456)];
        final periodCounts = <int>[1, 2, 3, 6, 12, 24];

        for (final p in principals) {
          for (final c in charges) {
            for (final n in periodCounts) {
              for (final calWay in InstallmentCalWay.valid) {
                for (final chargeWay in InstallmentChargeWay.valid) {
                  for (final remIn in InstallmentRemainderIn.valid) {
                    final s = buildInstallmentSchedule(
                      installmentId: 1,
                      principalMinor: p,
                      periods: n,
                      chargeMinor: c,
                      chargeWay: chargeWay,
                      calWay: calWay,
                      remainderIn: remIn,
                      startDateMs: startMs,
                    );
                    final sumP = s.fold<BigInt>(
                      BigInt.zero,
                      (acc, item) => acc + item.principalMinor,
                    );
                    final sumF = s.fold<BigInt>(
                      BigInt.zero,
                      (acc, item) => acc + item.feeMinor,
                    );
                    expect(sumP, p);
                    expect(sumF, c);
                  }
                }
              }
            }
          }
        }
      },
    );
  });

  group('R2 month-end date clamping & out-of-order cursor progression', () {
    test(
      'month-end clamping restores original anchor day in longer months',
      () {
        final jan31 = DateTime(2026, 1, 31);
        expect(installmentPeriodLocalDate(jan31, 1), DateTime(2026, 1, 31));
        expect(installmentPeriodLocalDate(jan31, 2), DateTime(2026, 2, 28));
        expect(installmentPeriodLocalDate(jan31, 3), DateTime(2026, 3, 31));
        expect(installmentPeriodLocalDate(jan31, 4), DateTime(2026, 4, 30));
        expect(installmentPeriodLocalDate(jan31, 5), DateTime(2026, 5, 31));

        // Leap-year February 29 clamping
        final leapJan31 = DateTime(2024, 1, 31);
        expect(installmentPeriodLocalDate(leapJan31, 2), DateTime(2024, 2, 29));
        expect(installmentPeriodLocalDate(leapJan31, 3), DateTime(2024, 3, 31));
      },
    );

    test('LC out-of-order credited progression jumps contiguous prefix', () {
      final startMs = DateTime(2026, 1, 15).millisecondsSinceEpoch;

      // Post period 3 early -> nextPeriod stays 1
      final step1 = advanceNextPeriod(
        currentNextPeriod: 1,
        periods: 6,
        creditedPeriods: [3],
        startDateMs: startMs,
      );
      expect(step1.nextPeriod, 1);
      expect(step1.isFinished, isFalse);

      // Post period 1 -> nextPeriod advances to 2
      final step2 = advanceNextPeriod(
        currentNextPeriod: step1.nextPeriod,
        periods: 6,
        creditedPeriods: [1, 3],
        startDateMs: startMs,
      );
      expect(step2.nextPeriod, 2);
      expect(step2.isFinished, isFalse);

      // Post period 2 -> skips already-credited 3 and jumps to 4!
      final step3 = advanceNextPeriod(
        currentNextPeriod: step2.nextPeriod,
        periods: 6,
        creditedPeriods: [1, 2, 3],
        startDateMs: startMs,
      );
      expect(step3.nextPeriod, 4);
      expect(
        DateTime.fromMillisecondsSinceEpoch(step3.nextPeriodDateMs),
        DateTime(2026, 4, 15),
      );

      // Post remaining 4, 5, 6 -> nextPeriod = 7, isFinished = true
      final step4 = advanceNextPeriod(
        currentNextPeriod: step3.nextPeriod,
        periods: 6,
        creditedPeriods: [1, 2, 3, 4, 5, 6],
        startDateMs: startMs,
      );
      expect(step4.nextPeriod, 7);
      expect(step4.isFinished, isTrue);
    });

    test(
      'ASYM-INST-04 deduplicates and bounds-filters dirty credited JSON',
      () {
        final cleaned = parseCreditedPeriods(
          '[-1, 0, 3, 1, 3, 99, "2"]',
          maxPeriod: 6,
        );
        expect(cleaned, [1, 2, 3]);
        expect(encodeCreditedPeriods([3, 1, 3, 0, 8], maxPeriod: 6), '[1,3]');

        final startMs = DateTime(2026, 1, 10).millisecondsSinceEpoch;
        final schedule = buildInstallmentSchedule(
          installmentId: 5,
          principalMinor: m(60000),
          periods: 6,
          chargeMinor: m(600),
          chargeWay: InstallmentChargeWay.perPeriod,
          calWay: InstallmentCalWay.halfUp2,
          remainderIn: InstallmentRemainderIn.firstPeriod,
          startDateMs: startMs,
          creditedPeriods: cleaned,
        );
        final progress = computeInstallmentProgress(
          schedule: schedule,
          principalMinor: m(60000),
          chargeMinor: m(600),
          startDateMs: startMs,
        );
        expect(progress.creditedPrincipalMinor, m(30000));
        expect(progress.remainingPrincipalMinor, m(30000));
        expect(progress.creditedFeeMinor, m(300));
        expect(progress.remainingFeeMinor, m(300));
        expect(progress.nextPeriod, 4);
      },
    );
  });

  group('Record key, extra JSON & CreditInfo.installments sync', () {
    test('parseInstallmentRecordKey avoids prefix collision (1-1 vs 10-1)', () {
      expect(formatInstallmentRecordKey(1, 2), '1-2');
      expect(parseInstallmentRecordKey('1-2'), (installmentId: 1, period: 2));
      expect(parseInstallmentRecordKey('10-2'), (installmentId: 10, period: 2));
      expect(parseInstallmentRecordKey('0-1'), isNull);
      expect(parseInstallmentRecordKey('1-0'), isNull);
      expect(parseInstallmentRecordKey('abc'), isNull);
      expect(parseInstallmentRecordKey(null), isNull);
    });

    test(
      'InstallmentExtra preserves unknown keys and round-trips settlement fields',
      () {
        final ex = InstallmentExtra.parse(
          '{"custom_flag":42,"cb":true,"ci":true}',
        );
        expect(ex.principalCounted, isTrue);
        expect(ex.interestCounted, isTrue);

        ex
          ..settledEarly = true
          ..settledPeriod = 2
          ..settledPrincipalMinor = m(80000)
          ..settledFeeMinor = m(0)
          ..waivedFeeMinor = m(4000);

        final reparsed = InstallmentExtra.parse(ex.encode());
        expect(reparsed.raw['custom_flag'], 42);
        expect(reparsed.settledEarly, isTrue);
        expect(reparsed.settledPeriod, 2);
        expect(reparsed.settledPrincipalMinor, m(80000));
        expect(reparsed.settledFeeMinor, m(0));
        expect(reparsed.waivedFeeMinor, m(4000));
      },
    );

    test(
      'syncCreditInfoInstallment keeps uncreditedInstallment & calculateCardDisplayBalance exact & suppresses legacy fallback',
      () {
        // Legacy card that had old scalar `installment: "99900"` and bill_day=10
        final initial = CreditInfo({
          'bill_day': 10,
          'repayment_day': 28,
          'installment': '99900',
        }).encode();

        // Add installment #1 (remaining 1200.00 principal + 60.00 fee, cb=true, ci=true)
        final withInst1 = syncCreditInfoInstallment(
          currentCreditInfoJson: initial,
          installmentId: 1,
          remainingPrincipalMinor: m(120000),
          remainingFeeMinor: m(6000),
          isFinished: false,
          principalCounted: true,
          interestCounted: true,
        );
        expect(uncreditedInstallment(withInst1), m(126000));
        expect(
          calculateCardDisplayBalance(
            BigInt.zero,
            CreditInfo.parse(withInst1).installments,
          ),
          m(-126000),
        );

        // Add installment #2 on same card (remaining 500.00 principal + 30.00 fee, cb=true, ci=false)
        final withBoth = syncCreditInfoInstallment(
          currentCreditInfoJson: withInst1,
          installmentId: 2,
          remainingPrincipalMinor: m(50000),
          remainingFeeMinor: m(3000),
          isFinished: false,
          principalCounted: true,
          interestCounted: false,
        );
        // uncreditedInstallment sums all (b + i) = 1260 + 530 = 1790.00
        expect(uncreditedInstallment(withBoth), m(179000));
        // calculateCardDisplayBalance respects cb/ci = -(1260 + 500) = -1760.00
        expect(
          calculateCardDisplayBalance(
            BigInt.zero,
            CreditInfo.parse(withBoth).installments,
          ),
          m(-176000),
        );

        // Finish #1 -> only #2 remains (500.00 + 30.00 = 530.00 uncredited; -500.00 display balance)
        final afterFinish1 = syncCreditInfoInstallment(
          currentCreditInfoJson: withBoth,
          installmentId: 1,
          remainingPrincipalMinor: BigInt.zero,
          remainingFeeMinor: BigInt.zero,
          isFinished: true,
        );
        expect(uncreditedInstallment(afterFinish1), m(53000));
        expect(
          calculateCardDisplayBalance(
            BigInt.zero,
            CreditInfo.parse(afterFinish1).installments,
          ),
          m(-50000),
        );

        // Remove #2 -> `inst` stays `[]`, so uncreditedInstallment returns 0 (does NOT fallback to 99900!)
        final afterRemove2 = syncCreditInfoInstallment(
          currentCreditInfoJson: afterFinish1,
          installmentId: 2,
          remainingPrincipalMinor: BigInt.zero,
          remainingFeeMinor: BigInt.zero,
          isFinished: true,
          remove: true,
        );
        expect(uncreditedInstallment(afterRemove2), BigInt.zero);
        expect(CreditInfo.parse(afterRemove2).billDay, 10);
      },
    );

    test('validateInstallmentInput rejects invalid parameters', () {
      expect(
        () => validateInstallmentInput(
          name: '   ',
          principal: Money.parse('100.00'),
          periods: 3,
          charge: Money.zero(),
          chargeWay: 1,
          calWay: 2,
          remainderIn: 0,
          assetId: 1,
        ),
        throwsA(isA<Failure>()),
      );
      expect(
        () => validateInstallmentInput(
          name: '测试',
          principal: Money.zero(),
          periods: 3,
          charge: Money.zero(),
          chargeWay: 1,
          calWay: 2,
          remainderIn: 0,
          assetId: 1,
        ),
        throwsA(isA<Failure>()),
      );
      expect(
        () => validateInstallmentInput(
          name: '测试',
          principal: Money.parse('100.00'),
          periods: 0,
          charge: Money.zero(),
          chargeWay: 1,
          calWay: 2,
          remainderIn: 0,
          assetId: 1,
        ),
        throwsA(isA<Failure>()),
      );
      expect(
        () => validateInstallmentInput(
          name: '测试',
          principal: Money.parse('100.00'),
          periods: 3,
          charge: Money.zero(),
          chargeWay: 1,
          calWay: 2,
          remainderIn: 0,
          assetId: noRef,
        ),
        throwsA(isA<Failure>()),
      );
    });
  });
}
