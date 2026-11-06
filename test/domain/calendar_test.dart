import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/domain/ledger/record_relations.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/calendar.dart';
import 'package:tallyisle/domain/rules/income_expense.dart';

BigInt y(num yuan) => BigInt.from((yuan * 100).round());

final class _TestBill {
  const _TestBill({required this.time, required this.entry});
  final int time;
  final StatEntry entry;
}

void main() {
  group('CalendarMonth (calendar.md R1)', () {
    test('natural month boundaries are fixed (1st to last day)', () {
      final m202603 = CalendarMonth(2026, 3);
      expect(m202603.year, 2026);
      expect(m202603.month, 3);
      expect(m202603.daysInMonth, 31);
      expect(m202603.start, DateTime(2026, 3, 1));
      expect(m202603.end, DateTime(2026, 3, 31, 23, 59, 59, 999));
    });

    test('leap year vs non-leap year February length', () {
      final feb2026 = CalendarMonth(2026, 2);
      expect(feb2026.daysInMonth, 28);

      final feb2024 = CalendarMonth(2024, 2);
      expect(feb2024.daysInMonth, 29);
    });

    test('previous and next month navigation', () {
      final jan2026 = CalendarMonth(2026, 1);
      final prev = jan2026.previous();
      expect(prev.year, 2025);
      expect(prev.month, 12);

      final next = jan2026.next();
      expect(next.year, 2026);
      expect(next.month, 2);
    });
  });

  group('Calendar Golden Vectors (calendar.md §4)', () {
    final march = CalendarMonth(2026, 3);

    test('GV1: 报销三态日历支出与名单 (DR-CAL-04 / 03zf / 02zv)', () {
      // 1. 未报销: 日历支出 0.00 元，名单包含
      final unlinked = _TestBill(
        time: DateTime(2026, 3, 10, 10).millisecondsSinceEpoch,
        entry: StatEntry(
          type: RecordType.reimbursable,
          moneyMinor: y(120),
          relations: null,
        ),
      );
      final s1 = summarizeCalendarMonth(
        march,
        [unlinked],
        recordTimeOf: (b) => b.time,
        statEntryOf: (b) => b.entry,
      );
      expect(s1[10]!.incomeExpense.expense, BigInt.zero);
      expect(s1[10]!.records, hasLength(1));

      // 2. 部分报销 50 元: 自担差额 70 元计入日历支出，名单包含
      final partial = _TestBill(
        time: DateTime(2026, 3, 10, 10).millisecondsSinceEpoch,
        entry: StatEntry(
          type: RecordType.reimbursable,
          moneyMinor: y(120),
          relations: RecordRelations()
            ..reimbursements = BillLinks(
              children: [LinkedBill(billId: 'r1', amount: y(50))],
            ),
        ),
      );
      final s2 = summarizeCalendarMonth(
        march,
        [partial],
        recordTimeOf: (b) => b.time,
        statEntryOf: (b) => b.entry,
      );
      expect(s2[10]!.incomeExpense.expense, y(70));
      expect(s2[10]!.records, hasLength(1));

      // 3. 全额报销 120 元: 日历支出 0.00 元，名单包含
      final full = _TestBill(
        time: DateTime(2026, 3, 10, 10).millisecondsSinceEpoch,
        entry: StatEntry(
          type: RecordType.reimbursable,
          moneyMinor: y(120),
          relations: RecordRelations()
            ..reimbursements = BillLinks(
              children: [LinkedBill(billId: 'r2', amount: y(120))],
            ),
        ),
      );
      final s3 = summarizeCalendarMonth(
        march,
        [full],
        recordTimeOf: (b) => b.time,
        statEntryOf: (b) => b.entry,
      );
      expect(s3[10]!.incomeExpense.expense, BigInt.zero);
      expect(s3[10]!.records, hasLength(1));
    });

    test('GV2: 收支排除标志日历表现 (02zs / 02zv / R3)', () {
      // 普通支出 120 元，exclude_budget = 0, exclude_ex_in = 1
      // 日历收支计 0.00 元；当日底部流水列表正常显示
      final bill = _TestBill(
        time: DateTime(2026, 3, 5, 12).millisecondsSinceEpoch,
        entry: StatEntry(
          type: RecordType.expense,
          moneyMinor: y(120),
          excludeBudget: false,
          excludeExIn: true,
        ),
      );
      final s = summarizeCalendarMonth(
        march,
        [bill],
        recordTimeOf: (b) => b.time,
        statEntryOf: (b) => b.entry,
      );
      expect(s[5]!.incomeExpense.expense, BigInt.zero);
      expect(s[5]!.incomeExpense.income, BigInt.zero);
      expect(s[5]!.records, hasLength(1));
    });

    test('GV3: 预算排除标志日历表现 (02zs / 02zv / R3)', () {
      // 普通支出 120 元，exclude_budget = 1, exclude_ex_in = 0
      // 日历支出计 120.00 元；当日底部流水列表正常显示
      final bill = _TestBill(
        time: DateTime(2026, 3, 5, 12).millisecondsSinceEpoch,
        entry: StatEntry(
          type: RecordType.expense,
          moneyMinor: y(120),
          excludeBudget: true,
          excludeExIn: false,
        ),
      );
      final s = summarizeCalendarMonth(
        march,
        [bill],
        recordTimeOf: (b) => b.time,
        statEntryOf: (b) => b.entry,
      );
      expect(s[5]!.incomeExpense.expense, y(120));
      expect(s[5]!.records, hasLength(1));
    });

    test('GV4: 独立负额支出渲染 (02zs CAL-09 / R4)', () {
      // 支出 -25.00 元，无关联原单: 日历支出 -25.00 元（冲减支出）
      final bill = _TestBill(
        time: DateTime(2026, 3, 8, 9).millisecondsSinceEpoch,
        entry: StatEntry(
          type: RecordType.expense,
          moneyMinor: -y(25),
          relations: null,
        ),
      );
      final s = summarizeCalendarMonth(
        march,
        [bill],
        recordTimeOf: (b) => b.time,
        statEntryOf: (b) => b.entry,
      );
      expect(s[8]!.incomeExpense.expense, -y(25));
      expect(s[8]!.records, hasLength(1));
    });

    test('GV5: 退款回溯冲减与超额退款 (02zr R06 / R07 / R4)', () {
      // 普通全额退款: 原单 80 元，关联退款 80 元 -> 支出 0 元
      final fullRefund = _TestBill(
        time: DateTime(2026, 3, 12, 10).millisecondsSinceEpoch,
        entry: StatEntry(
          type: RecordType.expense,
          moneyMinor: y(80),
          relations: RecordRelations()
            ..refunds = BillLinks(
              children: [LinkedBill(billId: 'rf1', amount: y(80))],
            ),
        ),
      );
      final s1 = summarizeCalendarMonth(
        march,
        [fullRefund],
        recordTimeOf: (b) => b.time,
        statEntryOf: (b) => b.entry,
      );
      expect(s1[12]!.incomeExpense.expense, BigInt.zero);

      // 超额退款: 原单 50 元，关联退款 80 元 -> 支出 0 元，收入 30 元
      final overRefund = _TestBill(
        time: DateTime(2026, 3, 15, 10).millisecondsSinceEpoch,
        entry: StatEntry(
          type: RecordType.expense,
          moneyMinor: y(50),
          relations: RecordRelations()
            ..refunds = BillLinks(
              children: [LinkedBill(billId: 'rf2', amount: y(80))],
            ),
        ),
      );
      final s2 = summarizeCalendarMonth(
        march,
        [overRefund],
        recordTimeOf: (b) => b.time,
        statEntryOf: (b) => b.entry,
      );
      expect(s2[15]!.incomeExpense.expense, BigInt.zero);
      expect(s2[15]!.incomeExpense.income, y(30));
    });

    test('GV6: 转账类型在日历中计 0 元但列表正常可见 (R5 / CE-HM-04)', () {
      final transfer = _TestBill(
        time: DateTime(2026, 3, 20, 14).millisecondsSinceEpoch,
        entry: StatEntry(
          type: RecordType.transfer,
          subType: RecordDirection.none,
          moneyMinor: y(1000),
        ),
      );
      final s = summarizeCalendarMonth(
        march,
        [transfer],
        recordTimeOf: (b) => b.time,
        statEntryOf: (b) => b.entry,
      );
      expect(s[20]!.incomeExpense.expense, BigInt.zero);
      expect(s[20]!.incomeExpense.income, BigInt.zero);
      expect(s[20]!.records, hasLength(1));
    });

    test('GV7: type 4 和 15 在日历统计和列表中完全排除 (R2)', () {
      final balanceAdjust = _TestBill(
        time: DateTime(2026, 3, 21, 10).millisecondsSinceEpoch,
        entry: StatEntry(type: RecordType.balanceAdjust, moneyMinor: y(100)),
      );
      final reimburseReceipt = _TestBill(
        time: DateTime(2026, 3, 21, 11).millisecondsSinceEpoch,
        entry: StatEntry(type: RecordType.reimburseReceipt, moneyMinor: y(100)),
      );
      final s = summarizeCalendarMonth(
        march,
        [balanceAdjust, reimburseReceipt],
        recordTimeOf: (b) => b.time,
        statEntryOf: (b) => b.entry,
      );
      expect(s[21]!.incomeExpense.expense, BigInt.zero);
      expect(s[21]!.incomeExpense.income, BigInt.zero);
      expect(s[21]!.records, isEmpty);
    });

    test('GV8: 信用卡还款日夹逼 (R7 / ASYM-CD-01c)', () {
      // 平年 2 月 (28 天)，还款日 31 日 clamp 到 28 日
      expect(clampRepaymentDay(31, 2026, 2), 28);
      // 闰年 2 月 (29 天)，还款日 31 日 clamp 到 29 日
      expect(clampRepaymentDay(31, 2024, 2), 29);
      // 小月 4 月 (30 天)，还款日 31 日 clamp 到 30 日
      expect(clampRepaymentDay(31, 2026, 4), 30);
      // 月底还款日 (-2)
      expect(clampRepaymentDay(-2, 2026, 2), 28);
      expect(clampRepaymentDay(-2, 2026, 4), 30);
      expect(clampRepaymentDay(-2, 2026, 5), 31);

      // JSON 解析
      expect(parseRepaymentDay('{"repayment_day": 15}', 2026, 2), 15);
      expect(parseRepaymentDay('{"repayment_day": 31}', 2026, 2), 28);
      expect(parseRepaymentDay('{"repayment_day": -1}', 2026, 2), isNull);
      expect(parseRepaymentDay('{"repayment_day": -2}', 2026, 2), 28);
    });
  });
}
