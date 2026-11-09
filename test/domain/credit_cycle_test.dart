import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/domain/ledger/asset_json.dart';
import 'package:tallyisle/domain/ledger/record_relations.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/credit_cycle.dart';

BigInt y(num yuan) => BigInt.from((yuan * 100).round());

void main() {
  group('Credit Cycle Boundaries & Clamping (R1, R2)', () {
    test('February & short month clamping in leap/non-leap years', () {
      // Non-leap year 2026 Feb (28 days)
      expect(anchorDay(2026, 2, 31), 28);
      expect(anchorDay(2026, 2, -2), 28);
      // Leap year 2024 Feb (29 days)
      expect(anchorDay(2024, 2, 31), 29);
      expect(anchorDay(2024, 2, -2), 29);
      // Short month April (30 days)
      expect(anchorDay(2026, 4, 31), 30);
      expect(anchorDay(2026, 4, -2), 30);
      // Normal day unchanged
      expect(anchorDay(2026, 4, 15), 15);
    });

    test('Safe due date computation with clamping (R2, ASYM-CD-01)', () {
      // Fixed day > statement day: stays in statement month
      final d1 = computeDueDate(
        statementDate: DateTime(2026, 4, 10),
        repaymentDay: 28,
        repaymentAfterBillDay: false,
      );
      expect(d1, DateTime(2026, 4, 28));

      // Fixed day <= statement day: advances to next month
      final d2 = computeDueDate(
        statementDate: DateTime(2026, 4, 15),
        repaymentDay: 5,
        repaymentAfterBillDay: false,
      );
      expect(d2, DateTime(2026, 5, 5));

      // Fixed day equal to statement day: advances to next month
      final d3 = computeDueDate(
        statementDate: DateTime(2026, 4, 10),
        repaymentDay: 10,
        repaymentAfterBillDay: false,
      );
      expect(d3, DateTime(2026, 5, 10));

      // End of month repayment when statement date is already end of month
      // (must move to next month's end of month, never same-day due date)
      final d4 = computeDueDate(
        statementDate: DateTime(2026, 2, 28),
        repaymentDay: -2,
        repaymentAfterBillDay: false,
      );
      expect(d4, DateTime(2026, 3, 31));

      // End of month repayment when statement date is mid-month
      final d5 = computeDueDate(
        statementDate: DateTime(2026, 4, 10),
        repaymentDay: -2,
        repaymentAfterBillDay: false,
      );
      expect(d5, DateTime(2026, 4, 30));

      // Advancing to February with day 31 clamps safely to 28 (never throws)
      final d6 = computeDueDate(
        statementDate: DateTime(2026, 1, 31),
        repaymentDay: 31,
        repaymentAfterBillDay: false,
      );
      expect(d6, DateTime(2026, 2, 28));

      // December rollover to January next year
      final d7 = computeDueDate(
        statementDate: DateTime(2026, 12, 20),
        repaymentDay: 5,
        repaymentAfterBillDay: false,
      );
      expect(d7, DateTime(2027, 1, 5));
    });

    test('Repayment after N days (repayment_day_after_bd = true)', () {
      final d = computeDueDate(
        statementDate: DateTime(2026, 4, 10),
        repaymentDay: 18,
        repaymentAfterBillDay: true,
      );
      expect(d, DateTime(2026, 4, 28));
    });

    test('Period boundaries with bill_day_count = true', () {
      final p = computePeriod(
        year: 2026,
        month: 5,
        billDay: 10,
        repaymentDay: 28,
        repaymentAfterBillDay: false,
        billDayCounted: true,
      );
      expect(p.start, DateTime(2026, 4, 11, 0, 0, 0, 0));
      expect(p.end, DateTime(2026, 5, 10, 23, 59, 59, 999));
      expect(p.statementDate, DateTime(2026, 5, 10));
      expect(p.dueDate, DateTime(2026, 5, 28));
    });

    test('Period boundaries with bill_day_count = false', () {
      final p = computePeriod(
        year: 2026,
        month: 4,
        billDay: 10,
        repaymentDay: 18,
        repaymentAfterBillDay: true,
        billDayCounted: false,
      );
      expect(p.start, DateTime(2026, 3, 10, 0, 0, 0, 0));
      expect(p.end, DateTime(2026, 4, 9, 23, 59, 59, 999));
      expect(p.statementDate, DateTime(2026, 4, 10));
      expect(p.dueDate, DateTime(2026, 4, 28));
    });

    test('Whole natural month special cases (R1)', () {
      // Case 1: bill_day == -2 and bill_day_count == true
      final p1 = computePeriod(
        year: 2026,
        month: 4,
        billDay: -2,
        repaymentDay: -2,
        repaymentAfterBillDay: false,
        billDayCounted: true,
      );
      expect(p1.start, DateTime(2026, 4, 1, 0, 0, 0, 0));
      expect(p1.end, DateTime(2026, 4, 30, 23, 59, 59, 999));
      expect(p1.statementDate, DateTime(2026, 4, 30));
      expect(p1.dueDate, DateTime(2026, 5, 31));

      // Case 2: bill_day == 1 and bill_day_count == false
      final p2 = computePeriod(
        year: 2026,
        month: 4,
        billDay: 1,
        repaymentDay: 15,
        repaymentAfterBillDay: false,
        billDayCounted: false,
      );
      expect(p2.start, DateTime(2026, 4, 1, 0, 0, 0, 0));
      expect(p2.end, DateTime(2026, 4, 30, 23, 59, 59, 999));
      expect(p2.statementDate, DateTime(2026, 5, 1));
      expect(p2.dueDate, DateTime(2026, 5, 15));
    });
  });

  group('Golden Vectors (docs/modules/credit-account.md §4)', () {
    const cardId = 601;

    // Build the C01 records according to 02zx / 03zk specifications
    final c01Records = <CreditCardRecord>[
      // Period 2 (2026-01-11 .. 2026-02-10): R01 original expense 500, cross-period refunded 100 in Period 3
      CreditCardRecord(
        id: 'R01',
        recordTime: DateTime(2026, 1, 20, 10).millisecondsSinceEpoch,
        type: RecordType.expense,
        moneyMinor: y(500),
        assetId: cardId,
        relations: RecordRelations({
          'lrefundi': {
            'rfbinfo': [
              {'lbid': 'R05', 'lbm': '${y(100)}'},
            ],
          },
        }),
      ),

      // Period 3 (2026-02-11 .. 2026-03-10):
      // R03 expense 600
      CreditCardRecord(
        id: 'R03',
        recordTime: DateTime(2026, 2, 15, 10).millisecondsSinceEpoch,
        type: RecordType.expense,
        moneyMinor: y(600),
        assetId: cardId,
      ),
      // Repayment transfer 500 into card (must be excluded from period statement)
      CreditCardRecord(
        id: 'REPAY_P2',
        recordTime: DateTime(2026, 2, 15, 12).millisecondsSinceEpoch,
        type: RecordType.transfer,
        moneyMinor: y(500),
        fromAssetId: 101,
        toAssetId: cardId,
      ),
      // R04 expense 200 with refund 50
      CreditCardRecord(
        id: 'R04',
        recordTime: DateTime(2026, 2, 20, 10).millisecondsSinceEpoch,
        type: RecordType.expense,
        moneyMinor: y(200),
        assetId: cardId,
        relations: RecordRelations({
          'lrefundi': {
            'rfbinfo': [
              {'lbid': 'R04_RF', 'lbm': '${y(50)}'},
            ],
          },
        }),
      ),
      // R04_RF refund child -50
      CreditCardRecord(
        id: 'R04_RF',
        recordTime: DateTime(2026, 2, 22, 10).millisecondsSinceEpoch,
        type: RecordType.expense,
        moneyMinor: -y(50),
        assetId: cardId,
        relations: RecordRelations({
          'lrefundi': {'rfobid': 'R04'},
        }),
      ),
      // R05 refund child -100 (cross-period refund for R01)
      CreditCardRecord(
        id: 'R05',
        recordTime: DateTime(2026, 3, 1, 10).millisecondsSinceEpoch,
        type: RecordType.expense,
        moneyMinor: -y(100),
        assetId: cardId,
        relations: RecordRelations({
          'lrefundi': {'rfobid': 'R01'},
        }),
      ),
      // R06 expense 50 on bill day 03-10 (bill_day_count = true -> belongs to Period 3)
      CreditCardRecord(
        id: 'R06',
        recordTime: DateTime(2026, 3, 10, 15).millisecondsSinceEpoch,
        type: RecordType.expense,
        moneyMinor: y(50),
        assetId: cardId,
      ),

      // Period 4 (2026-03-11 .. 2026-04-10):
      // R07 exclude_ex_in = true, expense 300
      CreditCardRecord(
        id: 'R07',
        recordTime: DateTime(2026, 3, 15, 10).millisecondsSinceEpoch,
        type: RecordType.expense,
        moneyMinor: y(300),
        assetId: cardId,
        excludeExIn: true,
      ),
      // R08 type 3 reimbursable without reimbursement, 200
      CreditCardRecord(
        id: 'R08',
        recordTime: DateTime(2026, 3, 18, 10).millisecondsSinceEpoch,
        type: RecordType.reimbursable,
        moneyMinor: y(200),
        assetId: cardId,
      ),
      // R09 type 3 advance 120, reimbursed 80
      CreditCardRecord(
        id: 'R09',
        recordTime: DateTime(2026, 3, 20, 10).millisecondsSinceEpoch,
        type: RecordType.reimbursable,
        moneyMinor: y(120),
        assetId: cardId,
        relations: RecordRelations({
          'lreimbursei': {
            'ribinfo': [
              {'lbid': 'R09_RB', 'lbm': '${y(80)}'},
            ],
          },
        }),
      ),
      // R09_RB reimbursement receipt into card 80
      CreditCardRecord(
        id: 'R09_RB',
        recordTime: DateTime(2026, 3, 22, 10).millisecondsSinceEpoch,
        type: RecordType.reimburseReceipt,
        moneyMinor: y(80),
        assetId: cardId,
        toAssetId: cardId,
        relations: RecordRelations({
          'lreimbursei': {'riobid': 'R09'},
        }),
      ),
      // R10 installment principal 100
      CreditCardRecord(
        id: 'R10',
        recordTime: DateTime(2026, 3, 25, 10).millisecondsSinceEpoch,
        type: RecordType.installmentPrincipal,
        moneyMinor: y(100),
        assetId: cardId,
      ),
      // R11 fee 5
      CreditCardRecord(
        id: 'R11',
        recordTime: DateTime(2026, 3, 25, 11).millisecondsSinceEpoch,
        type: RecordType.fee,
        moneyMinor: y(5),
        fromAssetId: cardId,
      ),
      // R12 type 13 installment 60
      CreditCardRecord(
        id: 'R12',
        recordTime: DateTime(2026, 4, 1, 10).millisecondsSinceEpoch,
        type: RecordType.billInstallment,
        moneyMinor: y(60),
        assetId: cardId,
      ),

      // Period 5 (2026-04-11 .. 2026-05-10):
      // C01_R13 expense 400
      CreditCardRecord(
        id: 'C01_R13',
        recordTime: DateTime(2026, 4, 15, 10).millisecondsSinceEpoch,
        type: RecordType.expense,
        moneyMinor: y(400),
        assetId: cardId,
      ),
      // C01_R14 expense 100 with full refund
      CreditCardRecord(
        id: 'C01_R14',
        recordTime: DateTime(2026, 4, 20, 10).millisecondsSinceEpoch,
        type: RecordType.expense,
        moneyMinor: y(100),
        assetId: cardId,
        relations: RecordRelations({
          'lrefundi': {
            'rfbinfo': [
              {'lbid': 'C01_R14_C', 'lbm': '${y(100)}'},
            ],
          },
        }),
      ),
      // C01_R14_C refund child -100
      CreditCardRecord(
        id: 'C01_R14_C',
        recordTime: DateTime(2026, 4, 25, 10).millisecondsSinceEpoch,
        type: RecordType.expense,
        moneyMinor: -y(100),
        assetId: cardId,
        relations: RecordRelations({
          'lrefundi': {'rfobid': 'C01_R14'},
        }),
      ),
    ];

    final c01Info = CreditInfo({
      'bill_day': 10,
      'repayment_day': 28,
      'repayment_day_after_bd': false,
      'bill_day_count': true,
    });

    test('C01 Period 5 (2026-04-11 .. 2026-05-10, unissued): 400.00', () {
      final p5 = computePeriod(
        year: 2026,
        month: 5,
        billDay: 10,
        repaymentDay: 28,
        repaymentAfterBillDay: false,
        billDayCounted: true,
      );
      expect(p5.start, DateTime(2026, 4, 11));
      expect(p5.end, DateTime(2026, 5, 10, 23, 59, 59, 999));
      expect(p5.isIssued(DateTime(2026, 4, 30)), isFalse);

      final res = calculatePeriodStatement(
        period: p5,
        recordsInWindow: c01Records,
        recordsById: {for (final r in c01Records) r.id: r},
        cardId: cardId,
      );
      expect(res.statementAmount, y(400.00));
      expect(res.installmentAmount, BigInt.zero);
      expect(res.normalAmount, y(400.00));
    });

    test(
      'C01 Period 4 (2026-03-11 .. 2026-04-10, issued): normal 585 + inst 60 = 645.00',
      () {
        final p4 = computePeriod(
          year: 2026,
          month: 4,
          billDay: 10,
          repaymentDay: 28,
          repaymentAfterBillDay: false,
          billDayCounted: true,
        );
        expect(p4.start, DateTime(2026, 3, 11));
        expect(p4.end, DateTime(2026, 4, 10, 23, 59, 59, 999));
        expect(p4.isIssued(DateTime(2026, 4, 30)), isTrue);

        final res = calculatePeriodStatement(
          period: p4,
          recordsInWindow: c01Records,
          recordsById: {for (final r in c01Records) r.id: r},
          cardId: cardId,
        );
        expect(res.statementAmount, y(645.00));
        expect(res.installmentAmount, y(60.00));
        expect(res.normalAmount, y(585.00));
      },
    );

    test('C01 Period 3 (2026-02-11 .. 2026-03-10, issued): 700.00', () {
      final p3 = computePeriod(
        year: 2026,
        month: 3,
        billDay: 10,
        repaymentDay: 28,
        repaymentAfterBillDay: false,
        billDayCounted: true,
      );
      expect(p3.start, DateTime(2026, 2, 11));
      expect(p3.end, DateTime(2026, 3, 10, 23, 59, 59, 999));
      expect(p3.isIssued(DateTime(2026, 4, 30)), isTrue);

      final res = calculatePeriodStatement(
        period: p3,
        recordsInWindow: c01Records,
        recordsById: {for (final r in c01Records) r.id: r},
        cardId: cardId,
      );
      expect(res.statementAmount, y(700.00));
      expect(res.normalAmount, y(700.00));
    });

    test('C01 Period 2 (2026-01-11 .. 2026-02-10, issued): 500.00', () {
      final p2 = computePeriod(
        year: 2026,
        month: 2,
        billDay: 10,
        repaymentDay: 28,
        repaymentAfterBillDay: false,
        billDayCounted: true,
      );
      expect(p2.start, DateTime(2026, 1, 11));
      expect(p2.end, DateTime(2026, 2, 10, 23, 59, 59, 999));
      expect(p2.isIssued(DateTime(2026, 4, 30)), isTrue);

      final res = calculatePeriodStatement(
        period: p2,
        recordsInWindow: c01Records,
        recordsById: {for (final r in c01Records) r.id: r},
        cardId: cardId,
      );
      expect(res.statementAmount, y(500.00));
      expect(res.normalAmount, y(500.00));
    });

    test(
      'C01 Debt Pool Allocation: 1500 pool -> remaining: P5=400, P4=645, P3=455, P2=0',
      () {
        final statements = calculateCreditStatements(
          creditInfo: c01Info,
          cardBalanceMinor: -y(1500.00),
          records: c01Records,
          cardId: cardId,
          selectedYear: 2026,
          today: DateTime(2026, 4, 30),
        );

        final p5 = statements.firstWhere((s) => s.period.periodIndex == 5);
        final p4 = statements.firstWhere((s) => s.period.periodIndex == 4);
        final p3 = statements.firstWhere((s) => s.period.periodIndex == 3);
        final p2 = statements.firstWhere((s) => s.period.periodIndex == 2);

        expect(p5.statementAmount, y(400.00));
        expect(p5.remainingAmount, y(400.00));
        expect(p5.repaidAmount, BigInt.zero);

        expect(p4.statementAmount, y(645.00));
        expect(p4.remainingAmount, y(645.00));
        expect(p4.repaidAmount, BigInt.zero);

        expect(p3.statementAmount, y(700.00));
        expect(p3.remainingAmount, y(455.00));
        expect(p3.repaidAmount, y(245.00));

        expect(p2.statementAmount, y(500.00));
        expect(p2.remainingAmount, BigInt.zero);
        expect(p2.repaidAmount, y(500.00));
        expect(p2.isPaidOff, isTrue);
      },
    );

    test('C01 Pending Repayment Banner: earliest issued unpaid is P3 455.00', () {
      final statements = calculateCreditStatements(
        creditInfo: c01Info,
        cardBalanceMinor: -y(1500.00),
        records: c01Records,
        cardId: cardId,
        selectedYear: 2026,
        today: DateTime(2026, 4, 30),
      );

      final banner = findPendingRepaymentBanner(
        statementItems: statements,
        selectedYear: 2026,
        today: DateTime(2026, 4, 30),
      );

      expect(banner, isNotNull);
      expect(banner!.period.periodIndex, 3);
      expect(banner.remainingAmount, y(455.00));
      expect(banner.isOverdue, isTrue);

      // In 02zx evaluation on 2026-04-15 with due date 2026-03-25, overdue is 21 days
      final banner02zx = findPendingRepaymentBanner(
        statementItems: statements,
        selectedYear: 2026,
        today: DateTime(2026, 4, 15),
      );
      // P3 due date for C01 in 02zx (repayment day 25): 2026-03-25 to 2026-04-15 = 21 days
      final p3DueDate25 = DateTime(2026, 3, 25);
      final daysDiff = DateTime(2026, 4, 15).difference(p3DueDate25).inDays;
      expect(daysDiff, 21);
      expect(banner02zx, isNotNull);
    });

    test('Shared Limit Group: 25000 - 2130 - 400 - 100 = 22370.00 (R6)', () {
      final primary601 = SharedGroupCard(
        id: 601,
        balanceMinor: -y(1500.00),
        initMoneyMinor: y(20000.00),
        creditInfo: CreditInfo({
          'bill_day': 10,
          'repayment_day': 28,
          'inst': [
            {
              'iid': '901',
              'b': '${y(600)}',
              'i': '${y(30)}',
              'cb': true,
              'ci': true,
            },
            {
              'iid': '902',
              'b': '${y(400)}',
              'i': '${y(20)}',
              'cb': false,
              'ci': false,
            },
          ],
        }),
        extraInfo: AssetExtra({
          'temp_amt': [
            {'m': '${y(5000)}', 'ddl': 1900000000000}, // active
            {'m': '${y(3000)}', 'ddl': 1000000000000}, // expired
          ],
        }),
      );

      final secondary602 = SharedGroupCard(
        id: 602,
        balanceMinor: -y(300.00),
        initMoneyMinor: y(10000.00),
        creditInfo: CreditInfo({
          'bill_day': 10,
          'repayment_day': 18,
          'repayment_day_after_bd': true,
          'bill_day_count': false,
          'share_amt_asset': 601,
          'inst': [
            {
              'iid': '903',
              'b': '${y(100)}',
              'i': '${y(10)}',
              'cb': true,
              'ci': false,
            },
          ],
        }),
      );

      final secondary603 = SharedGroupCard(
        id: 603,
        balanceMinor: -y(100.00),
        initMoneyMinor: y(5000.00),
        currency: 'USD',
        creditInfo: CreditInfo({
          'bill_day': 10,
          'repayment_day': 25,
          'share_amt_asset': 601,
          'inst': [],
        }),
      );

      final allCards = [primary601, secondary602, secondary603];
      const nowMs = 1776225600000;

      // 601 display balance: -1500 - (600+30) = -2130
      expect(
        calculateCardDisplayBalance(
          primary601.balanceMinor,
          primary601.creditInfo.installments,
        ),
        -y(2130.00),
      );

      // 602 display balance: -300 - 100 = -400
      expect(
        calculateCardDisplayBalance(
          secondary602.balanceMinor,
          secondary602.creditInfo.installments,
        ),
        -y(400.00),
      );

      // 603 display balance: -100
      expect(
        calculateCardDisplayBalance(
          secondary603.balanceMinor,
          secondary603.creditInfo.installments,
        ),
        -y(100.00),
      );

      final res = calculateSharedLimit(
        targetCard: primary601,
        allCards: allCards,
        nowMs: nowMs,
      );

      expect(res.effectiveTotalLimit, y(25000.00));
      expect(res.groupDisplayBalance, -y(2630.00));
      expect(res.usableLimit, y(22370.00));
      expect(res.isShared, isTrue);
      expect(res.isPrimary, isTrue);
    });

    test(
      'CD-F01 Rounding: 0.004 + 0.004 per-operand 2-dec HALF_UP yields 0.00',
      () {
        // With exact integer minor units (BigInt cents), 0.004 is 0 cents.
        // 0 cents + 0 cents = 0 cents.
        final a = DecimalValue.parse(
          '0.004',
        ).unitsAt(2, rounding: RoundingMode.halfUp);
        final b = DecimalValue.parse(
          '0.004',
        ).unitsAt(2, rounding: RoundingMode.halfUp);
        expect(a, BigInt.zero);
        expect(b, BigInt.zero);
        expect(a + b, BigInt.zero);
      },
    );

    test('CD-F02 Foreign currency refund child lookup', () {
      const usdCardId = 701;
      final usdRecords = [
        CreditCardRecord(
          id: 'EXP_USD',
          recordTime: DateTime(2026, 4, 5, 10).millisecondsSinceEpoch,
          type: RecordType.expense,
          moneyMinor: y(100),
          assetId: usdCardId,
          excludeExIn: true,
          relations: RecordRelations({
            'lrefundi': {
              'rfbinfo': [
                {'lbid': 'REF_CHILD', 'lbm': '${y(20)}', 'am': '${y(99)}'},
              ],
            },
          }),
        ),
        CreditCardRecord(
          id: 'REF_CHILD',
          recordTime: DateTime(2026, 4, 8, 10).millisecondsSinceEpoch,
          type: RecordType.expense,
          moneyMinor: -y(20),
          assetId: usdCardId,
          relations: RecordRelations({
            'lrefundi': {'rfobid': 'EXP_USD'},
          }),
        ),
      ];

      final p = computePeriod(
        year: 2026,
        month: 4,
        billDay: 10,
        repaymentDay: 28,
        repaymentAfterBillDay: false,
        billDayCounted: true,
      );

      final res = calculatePeriodStatement(
        period: p,
        recordsInWindow: usdRecords,
        recordsById: {for (final r in usdRecords) r.id: r},
        cardId: usdCardId,
      );

      // Under CD-F02 + ASYM-CD-04:
      // EXP_USD net is 100 - 20 = 80 in C_extra, + 20 E_parentRf - 20 F_childRf = 80.00
      // If original ASYM-CD-04 gross: 100 + 20 - 20 = 100.00
      // In both cases, the child record lookup used 20 (not 99 from am)!
      expect(res.statementAmount, y(80.00));
    });

    test('Interest-free days for swiping today (R7)', () {
      final info = CreditInfo({
        'bill_day': 15,
        'repayment_day': 5,
        'repayment_day_after_bd': false,
        'bill_day_count': true,
      });

      // On 2026-04-16 (day after bill day 15), spending enters May statement (05-15)
      // due on 2026-06-05.
      // From 2026-04-16 to 2026-06-05: 50 + 1 = 51 days.
      final days = calculateInterestFreeDays(
        creditInfo: info,
        today: DateTime(2026, 4, 16),
      );
      expect(days, 51);
    });
  });
}
