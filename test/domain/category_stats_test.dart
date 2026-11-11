import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/domain/ledger/record_relations.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/billing_period.dart';
import 'package:tallyisle/domain/rules/category_stats.dart';

void main() {
  group('CategoryStats Golden Vectors (docs/modules/category-stats.md §4 & 02zy §2)', () {
    final period = BillingPeriod.starting(2026, 3, 15);
    final diningCat = const CategoryMeta(id: 100, name: '餐饮', parentCatId: -1);
    final mealSubCat = const CategoryMeta(
      id: 101,
      name: '正餐',
      parentCatId: 100,
    );
    final coffeeSubCat = const CategoryMeta(
      id: 102,
      name: '咖啡',
      parentCatId: 100,
    );
    final snackSubCat = const CategoryMeta(
      id: 103,
      name: '夜宵',
      parentCatId: 100,
    );
    final shoppingCat = const CategoryMeta(
      id: 300,
      name: '购物',
      parentCatId: -1,
    );
    final digitalSubCat = const CategoryMeta(
      id: 301,
      name: '数码',
      parentCatId: 300,
    );
    final livingCat = const CategoryMeta(id: 400, name: '居住', parentCatId: -1);
    final travelCat = const CategoryMeta(id: 500, name: '差旅', parentCatId: -1);
    final salaryParentCat = const CategoryMeta(
      id: 800,
      name: '薪资',
      parentCatId: -1,
    );
    final salarySubCat = const CategoryMeta(
      id: 801,
      name: '基本工资',
      parentCatId: 800,
    );

    final catMap = <int, CategoryMeta>{
      100: diningCat,
      101: mealSubCat,
      102: coffeeSubCat,
      103: snackSubCat,
      300: shoppingCat,
      301: digitalSubCat,
      400: livingCat,
      500: travelCat,
      800: salaryParentCat,
      801: salarySubCat,
    };

    test('1. 报销三态 (type = 3) 分类支出与行展示: 0 -> 70 -> 0 元与行无 -> 有 -> 无', () {
      // 120 元报销单: 未报销 / 报销 50 元 / 全额报销 120 元
      final bill120Unreimbursed = CategoryStatEntry(
        recordId: 'r1',
        accountBookId: 1,
        recordTime: period.startMs + 1000,
        type: RecordType.reimbursable,
        moneyMinor: BigInt.from(12000),
        recordCatId: 500,
      );

      final bill120Partial = CategoryStatEntry(
        recordId: 'r1',
        accountBookId: 1,
        recordTime: period.startMs + 1000,
        type: RecordType.reimbursable,
        moneyMinor: BigInt.from(12000),
        recordCatId: 500,
        relations: RecordRelations()
          ..reimbursements = BillLinks(
            children: [LinkedBill(billId: 'rm50', amount: BigInt.from(5000))],
          ),
      );

      final bill120Full = CategoryStatEntry(
        recordId: 'r1',
        accountBookId: 1,
        recordTime: period.startMs + 1000,
        type: RecordType.reimbursable,
        moneyMinor: BigInt.from(12000),
        recordCatId: 500,
        relations: RecordRelations()
          ..reimbursements = BillLinks(
            children: [LinkedBill(billId: 'rm120', amount: BigInt.from(12000))],
          ),
      );

      // State 1: 未报销 -> 0.00 元 / 0 笔 / 无分类行
      final res1 = aggregateCategoryStats(
        entries: [bill120Unreimbursed],
        categories: catMap,
        period: period,
        dimension: StatDimension.expense,
      );
      expect(res1.headerTotalMinor, BigInt.zero);
      expect(res1.headerCount, 0);
      expect(res1.firstLevelRows, isEmpty);
      expect(res1.flattenRows, isEmpty);

      // State 2: 报销 50 元 -> 70.00 元 / 1 笔 / 有分类行
      final res2 = aggregateCategoryStats(
        entries: [bill120Partial],
        categories: catMap,
        period: period,
        dimension: StatDimension.expense,
      );
      expect(res2.headerTotalMinor, BigInt.from(7000));
      expect(res2.headerCount, 1);
      expect(res2.firstLevelRows.length, 1);
      expect(res2.firstLevelRows.first.categoryId, 500);
      expect(res2.firstLevelRows.first.moneyMinor, BigInt.from(7000));
      expect(res2.firstLevelRows.first.count, 1);
      expect(res2.flattenRows.length, 1);

      // State 3: 全额报销 120 元 -> 0.00 元 / 0 笔 / 无分类行
      final res3 = aggregateCategoryStats(
        entries: [bill120Full],
        categories: catMap,
        period: period,
        dimension: StatDimension.expense,
      );
      expect(res3.headerTotalMinor, BigInt.zero);
      expect(res3.headerCount, 0);
      expect(res3.firstLevelRows, isEmpty);
      expect(res3.flattenRows, isEmpty);
    });

    test('2. 全额退款 vs 全额报销行表现: 全退 0元/1笔 保留 0 元行 vs 全报 0元/0笔 无分类行', () {
      final fullRefundBill = CategoryStatEntry(
        recordId: 'rf1',
        accountBookId: 1,
        recordTime: period.startMs + 2000,
        type: RecordType.expense,
        moneyMinor: BigInt.from(8000),
        recordCatId: 301, // 数码
        relations: RecordRelations()
          ..refunds = BillLinks(
            children: [LinkedBill(billId: 'rf80', amount: BigInt.from(8000))],
          ),
      );

      final fullReimburseBill = CategoryStatEntry(
        recordId: 'rm1',
        accountBookId: 1,
        recordTime: period.startMs + 3000,
        type: RecordType.reimbursable,
        moneyMinor: BigInt.from(12000),
        recordCatId: 500, // 差旅
        relations: RecordRelations()
          ..reimbursements = BillLinks(
            children: [LinkedBill(billId: 'rm120', amount: BigInt.from(12000))],
          ),
      );

      final res = aggregateCategoryStats(
        entries: [fullRefundBill, fullReimburseBill],
        categories: catMap,
        period: period,
        dimension: StatDimension.expense,
      );

      // Header should have 0.00 expense, exactly 1 count (the full refund bill)
      expect(res.headerTotalMinor, BigInt.zero);
      expect(res.headerCount, 1);

      // First-level rows should retain the full refund row (0.00元 / 1笔), but NOT the full reimburse row
      expect(res.firstLevelRows.length, 1);
      final shopRow = res.firstLevelRows.first;
      expect(shopRow.categoryId, 300); // 购物 parent
      expect(shopRow.moneyMinor, BigInt.zero);
      expect(shopRow.count, 1);
      // Zero denominator fallback to 100.00%
      expect(shopRow.ratioBasisPoints, 10000);
      expect(shopRow.ratioText, '100.00%');

      // Flatten list retains the subcategory row (数码) with 0.00元
      expect(res.flattenRows.length, 1);
      expect(res.flattenRows.first.categoryId, 301);
      expect(res.flattenRows.first.moneyMinor, BigInt.zero);
      expect(res.flattenRows.first.ratioBasisPoints, 10000);
    });

    test('3. F01 平铺比例最小反例: 有效分类 100 元，无分类记录 100 元', () {
      final validBill = CategoryStatEntry(
        recordId: 'v1',
        accountBookId: 1,
        recordTime: period.startMs + 1000,
        type: RecordType.expense,
        moneyMinor: BigInt.from(10000),
        recordCatId: 400, // 居住
      );
      final uncatBill = CategoryStatEntry(
        recordId: 'u1',
        accountBookId: 1,
        recordTime: period.startMs + 2000,
        type: RecordType.expense,
        moneyMinor: BigInt.from(10000),
        recordCatId: -1, // 无分类
      );

      final res = aggregateCategoryStats(
        entries: [validBill, uncatBill],
        categories: catMap,
        period: period,
        dimension: StatDimension.expense,
      );

      // Header is 200.00 元
      expect(res.headerTotalMinor, BigInt.from(20000));
      expect(res.headerCount, 2);

      // First level ratio: 100 / 200 = 50.00% (5000 bp)
      expect(res.firstLevelRows.length, 1);
      expect(res.firstLevelRows.first.moneyMinor, BigInt.from(10000));
      expect(res.firstLevelRows.first.ratioBasisPoints, 5000);
      expect(res.firstLevelRows.first.ratioText, '50.00%');

      // Flatten denominator is only the retained valid category: 100.00 元 (NOT 200.00!)
      expect(res.flattenDenominatorMinor, BigInt.from(10000));
      expect(res.flattenRows.length, 1);
      // Flatten ratio: 100 / 100 = 100.00% (10000 bp)
      expect(res.flattenRows.first.ratioBasisPoints, 10000);
      expect(res.flattenRows.first.ratioText, '100.00%');

      // Uncategorized closing row is present for closing book
      expect(res.uncategorizedRow, isNotNull);
      expect(res.uncategorizedRow!.moneyMinor, BigInt.from(10000));
      expect(res.uncategorizedRow!.ratioBasisPoints, 5000);
    });

    test('4. F01 完整收入平铺分母与比例: 工资 1000 元，直属居住 10 元，另 25 元未成行', () {
      final salaryBill = CategoryStatEntry(
        recordId: 's1',
        accountBookId: 1,
        recordTime: period.startMs + 1000,
        type: RecordType.income,
        moneyMinor: BigInt.from(100000),
        recordCatId: 801, // 基本工资 (child of 800)
      );
      final livingBill = CategoryStatEntry(
        recordId: 's2',
        accountBookId: 1,
        recordTime: period.startMs + 2000,
        type: RecordType.income,
        moneyMinor: BigInt.from(1000),
        recordCatId: 400, // 居住 (direct parent)
      );
      final uncatIncome = CategoryStatEntry(
        recordId: 's3',
        accountBookId: 1,
        recordTime: period.startMs + 3000,
        type: RecordType.income,
        moneyMinor: BigInt.from(2500),
        recordCatId: -1, // 未成行
      );

      final res = aggregateCategoryStats(
        entries: [salaryBill, livingBill, uncatIncome],
        categories: catMap,
        period: period,
        dimension: StatDimension.income,
      );

      // Header total: 1035.00 元
      expect(res.headerTotalMinor, BigInt.from(103500));
      expect(res.headerCount, 3);

      // First-level rows:
      // 工资 (800): 1000 / 1035 = 96.62% (9662 bp)
      // 居住 (400): 10 / 1035 = 0.97% (97 bp)
      expect(res.firstLevelRows.length, 2);
      final row800 = res.firstLevelRows.firstWhere((r) => r.categoryId == 800);
      final row400 = res.firstLevelRows.firstWhere((r) => r.categoryId == 400);

      expect(row800.moneyMinor, BigInt.from(100000));
      expect(row800.ratioBasisPoints, 9662);
      expect(row800.ratioText, '96.62%');

      expect(row400.moneyMinor, BigInt.from(1000));
      expect(row400.ratioBasisPoints, 97);
      expect(row400.ratioText, '0.97%');

      // Flatten denominator: 1000 + 10 = 1010.00 元
      expect(res.flattenDenominatorMinor, BigInt.from(101000));
      expect(res.flattenRows.length, 2);

      // Flatten ratios:
      // 工资: 1000 / 1010 = 99.01% (9901 bp)
      // 居住: 10 / 1010 = 0.99% (99 bp)
      final flSalary = res.flattenRows.firstWhere((r) => r.categoryId == 801);
      final flLiving = res.flattenRows.firstWhere((r) => r.categoryId == 400);

      expect(flSalary.ratioBasisPoints, 9901);
      expect(flSalary.ratioText, '99.01%');

      expect(flLiving.ratioBasisPoints, 99);
      expect(flLiving.ratioText, '0.99%');
    });

    test('5. 已知支出子集平铺分母 470 元与比例 (42.55/25.53/12.77/9.57/6.38/3.19/0%)', () {
      final entries = <CategoryStatEntry>[
        CategoryStatEntry(
          recordId: 'e1',
          accountBookId: 1,
          recordTime: period.startMs + 1000,
          type: RecordType.expense,
          moneyMinor: BigInt.from(20000),
          recordCatId: 400, // 居住 200
        ),
        CategoryStatEntry(
          recordId: 'e2',
          accountBookId: 1,
          recordTime: period.startMs + 2000,
          type: RecordType.expense,
          moneyMinor: BigInt.from(12000),
          recordCatId: 101, // 正餐 120
        ),
        CategoryStatEntry(
          recordId: 'e3',
          accountBookId: 1,
          recordTime: period.startMs + 3000,
          type: RecordType.expense,
          moneyMinor: BigInt.from(6000),
          recordCatId: 102, // 咖啡 60
        ),
        CategoryStatEntry(
          recordId: 'e4',
          accountBookId: 1,
          recordTime: period.startMs + 4000,
          type: RecordType.reimbursable,
          moneyMinor: BigInt.from(10000),
          recordCatId: 500, // 差旅 45 (通过报销部分支出: 100报55 -> 45)
          relations: RecordRelations()
            ..reimbursements = BillLinks(
              children: [LinkedBill(billId: 'rm55', amount: BigInt.from(5500))],
            ),
        ),
        CategoryStatEntry(
          recordId: 'e5',
          accountBookId: 1,
          recordTime: period.startMs + 5000,
          type: RecordType.expense,
          moneyMinor: BigInt.from(3000),
          recordCatId: 100, // 餐饮直属 30
        ),
        CategoryStatEntry(
          recordId: 'e6',
          accountBookId: 1,
          recordTime: period.startMs + 6000,
          type: RecordType.expense,
          moneyMinor: BigInt.from(1500),
          recordCatId: 103, // 夜宵 15
        ),
        CategoryStatEntry(
          recordId: 'e7',
          accountBookId: 1,
          recordTime: period.startMs + 7000,
          type: RecordType.expense,
          moneyMinor: BigInt.from(8000),
          recordCatId: 301, // 数码全退 0
          relations: RecordRelations()
            ..refunds = BillLinks(
              children: [LinkedBill(billId: 'rf80', amount: BigInt.from(8000))],
            ),
        ),
        CategoryStatEntry(
          recordId: 'e8',
          accountBookId: 1,
          recordTime: period.startMs + 8000,
          type: RecordType.fee,
          moneyMinor: BigInt.from(2000),
          recordCatId: -1, // 手续费 20 (无分类)
        ),
      ];

      final res = aggregateCategoryStats(
        entries: entries,
        categories: catMap,
        period: period,
        dimension: StatDimension.expense,
      );

      // Header total = 490.00 元
      expect(res.headerTotalMinor, BigInt.from(49000));

      // Flatten denominator = 470.00 元
      expect(res.flattenDenominatorMinor, BigInt.from(47000));
      expect(res.flattenRows.length, 7);

      final amounts = res.flattenRows.map((r) => r.moneyMinor.toInt()).toList();
      expect(amounts, [20000, 12000, 6000, 4500, 3000, 1500, 0]);

      final bps = res.flattenRows.map((r) => r.ratioBasisPoints).toList();
      expect(bps, [4255, 2553, 1277, 957, 638, 319, 0]);

      final texts = res.flattenRows.map((r) => r.ratioText).toList();
      expect(texts, [
        '42.55%',
        '25.53%',
        '12.77%',
        '9.57%',
        '6.38%',
        '3.19%',
        '0.00%',
      ]);
    });

    test('6. 普通正负支出 100/-100 抵消，零分母回退 100.00%', () {
      final posBill = CategoryStatEntry(
        recordId: 'p1',
        accountBookId: 1,
        recordTime: period.startMs + 1000,
        type: RecordType.expense,
        moneyMinor: BigInt.from(10000),
        recordCatId: 400,
      );
      final negBill = CategoryStatEntry(
        recordId: 'n1',
        accountBookId: 1,
        recordTime: period.startMs + 2000,
        type: RecordType.expense,
        moneyMinor: -BigInt.from(10000),
        recordCatId: 500,
      );
      final uncatBill = CategoryStatEntry(
        recordId: 'u1',
        accountBookId: 1,
        recordTime: period.startMs + 3000,
        type: RecordType.expense,
        moneyMinor: BigInt.from(5000),
        recordCatId: -1,
      );

      final res = aggregateCategoryStats(
        entries: [posBill, negBill, uncatBill],
        categories: catMap,
        period: period,
        dimension: StatDimension.expense,
      );

      expect(res.headerTotalMinor, BigInt.from(5000));
      expect(res.flattenDenominatorMinor, BigInt.zero);
      expect(res.flattenRows.length, 2);

      // Both retained rows fall back to 100.00%
      for (final r in res.flattenRows) {
        expect(r.ratioBasisPoints, 10000);
        expect(r.ratioText, '100.00%');
      }
    });

    test(r'7. R6 展开子项与同名直属项 "${parent.name}直属" 插入 index 0', () {
      final entries = <CategoryStatEntry>[
        CategoryStatEntry(
          recordId: 'd1',
          accountBookId: 1,
          recordTime: period.startMs + 1000,
          type: RecordType.expense,
          moneyMinor: BigInt.from(3000),
          recordCatId: 100, // 餐饮直属 30
        ),
        CategoryStatEntry(
          recordId: 'd2',
          accountBookId: 1,
          recordTime: period.startMs + 2000,
          type: RecordType.expense,
          moneyMinor: BigInt.from(12000),
          recordCatId: 101, // 正餐 120
        ),
        CategoryStatEntry(
          recordId: 'd3',
          accountBookId: 1,
          recordTime: period.startMs + 3000,
          type: RecordType.expense,
          moneyMinor: BigInt.from(4500),
          recordCatId: 102, // 咖啡 45
        ),
        CategoryStatEntry(
          recordId: 'd4',
          accountBookId: 1,
          recordTime: period.startMs + 4000,
          type: RecordType.expense,
          moneyMinor: BigInt.from(1500),
          recordCatId: 103, // 夜宵 15
        ),
      ];

      final res = aggregateCategoryStats(
        entries: entries,
        categories: catMap,
        period: period,
        dimension: StatDimension.expense,
      );

      expect(res.firstLevelRows.length, 1);
      final diningRow = res.firstLevelRows.first;
      expect(diningRow.categoryId, 100);
      expect(diningRow.moneyMinor, BigInt.from(21000)); // 210 元

      // Children list length is 4: direct item is inserted at index 0!
      expect(diningRow.children.length, 4);
      final directChild = diningRow.children[0];
      expect(directChild.name, '餐饮直属');
      expect(directChild.isDirectChild, isTrue);
      expect(directChild.moneyMinor, BigInt.from(3000));
      // 30 / 210 = 14.29% (1429 bp)
      expect(directChild.ratioBasisPoints, 1429);
      expect(directChild.ratioText, '14.29%');

      // Subsequent children are sorted by amount descending:
      // 正餐 (120), 咖啡 (45), 夜宵 (15)
      expect(diningRow.children[1].name, '正餐');
      expect(diningRow.children[1].moneyMinor, BigInt.from(12000));
      // 120 / 210 = 57.14% (5714 bp)
      expect(diningRow.children[1].ratioBasisPoints, 5714);

      expect(diningRow.children[2].name, '咖啡');
      expect(diningRow.children[2].moneyMinor, BigInt.from(4500));
      // 45 / 210 = 21.43% (2143 bp)
      expect(diningRow.children[2].ratioBasisPoints, 2143);

      expect(diningRow.children[3].name, '夜宵');
      expect(diningRow.children[3].moneyMinor, BigInt.from(1500));
      // 15 / 210 = 7.14% (714 bp)
      expect(diningRow.children[3].ratioBasisPoints, 714);
    });

    test('8. R1 日均计算与 elapsedDays 边界', () {
      final bill = CategoryStatEntry(
        recordId: 'b1',
        accountBookId: 1,
        recordTime: period.startMs + 1000,
        type: RecordType.expense,
        moneyMinor: BigInt.from(71200), // 712.00 元
        recordCatId: 100,
      );

      // Case A: 10 days elapsed (now is 2026-03-24, period starts 03-15)
      final now10 = DateTime(2026, 3, 24, 12, 0);
      final res10 = aggregateCategoryStats(
        entries: [bill],
        categories: catMap,
        period: period,
        dimension: StatDimension.expense,
        now: now10,
      );
      expect(res10.elapsedDays, 10);
      // 71200 / 10 = 7120 (71.20 元)
      expect(res10.dailyAverageMinor, BigInt.from(7120));

      // Case B: Future period (elapsedDays = 0)
      final futurePeriod = BillingPeriod.starting(2026, 5, 15);
      final resFuture = aggregateCategoryStats(
        entries: [bill],
        categories: catMap,
        period: futurePeriod,
        dimension: StatDimension.expense,
        now: now10,
      );
      expect(resFuture.elapsedDays, 0);
      expect(resFuture.dailyAverageMinor, BigInt.zero);
    });

    test('9. R7 Tukey IQR 异常值平滑截顶 (02zt §6.2: 15,30,45,60,72,120,500)', () {
      final amounts = [1500, 3000, 4500, 6000, 7200, 12000, 50000];
      final buckets = <TrendBucket>[];
      final baseDate = DateTime(2026, 3, 15);

      for (var i = 0; i < amounts.length; i++) {
        final d = baseDate.add(Duration(days: i));
        buckets.add(
          TrendBucket(
            label: '${d.month}-${d.day}',
            startDate: d,
            endDate: d.add(const Duration(days: 1)),
            actualMinor: BigInt.from(amounts[i]),
            displayMinor: BigInt.from(amounts[i]),
          ),
        );
      }

      // Test primary mode (k = 1.5): Q1 = 30, Q3 = 120, IQR = 90, median = 60
      // upperFence = 120 + 1.5 * 90 = 255. Outlier 500 > 255 truncated to median 60
      final smoothedPrimary = applyTukeySmoothing(
        buckets,
        OutlierSmoothing.primary,
      );
      expect(smoothedPrimary.length, 7);
      expect(smoothedPrimary.last.isOutlier, isTrue);
      expect(smoothedPrimary.last.actualMinor, BigInt.from(50000));
      expect(smoothedPrimary.last.displayMinor, BigInt.from(6000));
      expect(smoothedPrimary.last.upperFenceMinor, BigInt.from(25500));
      expect(smoothedPrimary.last.medianMinor, BigInt.from(6000));

      // Non-outliers keep actual display values
      for (var i = 0; i < 6; i++) {
        expect(smoothedPrimary[i].isOutlier, isFalse);
        expect(smoothedPrimary[i].displayMinor, BigInt.from(amounts[i]));
      }

      // Test secondary mode (k = 3.0): upperFence = 120 + 3 * 90 = 390
      // 500 > 390 is still an outlier, display is still truncated to median 60
      final smoothedSecondary = applyTukeySmoothing(
        buckets,
        OutlierSmoothing.secondary,
      );
      expect(smoothedSecondary.last.isOutlier, isTrue);
      expect(smoothedSecondary.last.actualMinor, BigInt.from(50000));
      expect(smoothedSecondary.last.displayMinor, BigInt.from(6000));
      expect(smoothedSecondary.last.upperFenceMinor, BigInt.from(39000));
    });

    test('10. R2 排除规则: excludeExIn 严格排除 & includeExcludeBudget 切换', () {
      final normalBill = CategoryStatEntry(
        recordId: 'b1',
        accountBookId: 1,
        recordTime: period.startMs + 1000,
        type: RecordType.expense,
        moneyMinor: BigInt.from(10000),
        recordCatId: 400,
      );
      final exclExInBill = CategoryStatEntry(
        recordId: 'b2',
        accountBookId: 1,
        recordTime: period.startMs + 2000,
        type: RecordType.expense,
        moneyMinor: BigInt.from(5000),
        recordCatId: 400,
        excludeExIn: true,
      );
      final exclBudgetBill = CategoryStatEntry(
        recordId: 'b3',
        accountBookId: 1,
        recordTime: period.startMs + 3000,
        type: RecordType.expense,
        moneyMinor: BigInt.from(7000),
        recordCatId: 400,
        excludeBudget: true,
      );

      // Default: includeExcludeBudget = true
      final resDefault = aggregateCategoryStats(
        entries: [normalBill, exclExInBill, exclBudgetBill],
        categories: catMap,
        period: period,
        dimension: StatDimension.expense,
        includeExcludeBudget: true,
      );
      // exclExIn is excluded, exclBudget is included: 10000 + 7000 = 17000
      expect(resDefault.headerTotalMinor, BigInt.from(17000));
      expect(resDefault.headerCount, 2);

      // Switched: includeExcludeBudget = false
      final resBudgetOff = aggregateCategoryStats(
        entries: [normalBill, exclExInBill, exclBudgetBill],
        categories: catMap,
        period: period,
        dimension: StatDimension.expense,
        includeExcludeBudget: false,
      );
      // Both exclExIn and exclBudget are excluded: only normalBill = 10000
      expect(resBudgetOff.headerTotalMinor, BigInt.from(10000));
      expect(resBudgetOff.headerCount, 1);
    });

    test('11. 环比上期计算: 修复 ASYM-CAT-04，上下期均使用完整退报净额', () {
      final currBill = CategoryStatEntry(
        recordId: 'curr1',
        accountBookId: 1,
        recordTime: period.startMs + 1000,
        type: RecordType.expense,
        moneyMinor: BigInt.from(21000), // 当期餐饮 210 元
        recordCatId: 100,
      );

      // 上期正餐 100 退 30 净 70 元 (修复 ASYM-CAT-04: 上期净额为 70 元，而不是未扣退款的 100 元)
      final lastPeriod = period.previous(15);
      final lastBill = CategoryStatEntry(
        recordId: 'last1',
        accountBookId: 1,
        recordTime: lastPeriod.startMs + 1000,
        type: RecordType.expense,
        moneyMinor: BigInt.from(10000),
        recordCatId: 101, // 正餐 (child of 100)
        relations: RecordRelations()
          ..refunds = BillLinks(
            children: [LinkedBill(billId: 'rf30', amount: BigInt.from(3000))],
          ),
      );

      final res = aggregateCategoryStats(
        entries: [currBill],
        categories: catMap,
        period: period,
        dimension: StatDimension.expense,
        lastPeriodEntries: [lastBill],
      );

      expect(res.lastPeriodTotalMinor, BigInt.from(7000)); // 70 元
      // Growth = (210 - 70) / 70 = +200% (20000 bp)
      expect(res.growthBasisPoints, 20000);
    });

    test('12. 超额退款差额转入收入轴', () {
      final overRefundBill = CategoryStatEntry(
        recordId: 'orf1',
        accountBookId: 1,
        recordTime: period.startMs + 1000,
        type: RecordType.expense,
        moneyMinor: BigInt.from(10000), // 100 元
        recordCatId: 301,
        relations: RecordRelations()
          ..refunds = BillLinks(
            children: [
              LinkedBill(
                billId: 'rf125',
                amount: BigInt.from(12500),
              ), // 退 125 元
            ],
          ),
      );

      // Under expense dimension: contributes 0
      final resExpense = aggregateCategoryStats(
        entries: [overRefundBill],
        categories: catMap,
        period: period,
        dimension: StatDimension.expense,
      );
      expect(resExpense.headerTotalMinor, BigInt.zero);
      expect(resExpense.headerCount, 0);

      // Under income dimension: contributes net 25 元!
      final resIncome = aggregateCategoryStats(
        entries: [overRefundBill],
        categories: catMap,
        period: period,
        dimension: StatDimension.income,
      );
      expect(resIncome.headerTotalMinor, BigInt.from(2500));
      expect(resIncome.headerCount, 1);
    });

    test('13. 空账单列表: 保持空列表，分母为 0，不制造 100% 假行', () {
      final res = aggregateCategoryStats(
        entries: const [],
        categories: catMap,
        period: period,
        dimension: StatDimension.expense,
      );
      expect(res.headerTotalMinor, BigInt.zero);
      expect(res.headerCount, 0);
      expect(res.firstLevelRows, isEmpty);
      expect(res.flattenRows, isEmpty);
      expect(res.flattenDenominatorMinor, BigInt.zero);
      expect(res.uncategorizedRow, isNull);
    });
  });
}
