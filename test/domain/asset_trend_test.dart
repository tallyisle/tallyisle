import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/domain/ledger/record_extra.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/asset_overview.dart';
import 'package:tallyisle/domain/rules/asset_trend.dart';

BigInt y(num yuan) => BigInt.from((yuan * 100).round());

void main() {
  final rates = RateTable({
    'CNY': '1.0',
    'USD': '0.14', // 1 USD = 7.14285714 CNY
  });

  TrendAccount acc(
    int id,
    String name,
    num balance, {
    int type = AssetType.normal,
    int sub = -1,
    int? eff,
    int status = AssetStatus.active,
    String? currency = 'CNY',
    String? groupName,
    Object? credit,
  }) => TrendAccount(
    id: id,
    name: name,
    type: type,
    subType: sub,
    balanceMinor: y(balance),
    isEffectiveAsset: eff ?? (type == AssetType.debt ? 0 : 1),
    status: status,
    currency: currency,
    groupName: groupName,
    creditInfo: credit == null ? null : jsonEncode(credit),
  );

  group('Golden Vectors (docs/modules/asset-trend.md §4)', () {
    test('CE-AT-02: Total asset vs net worth perspective口径 (ASYM-AT-01)', () {
      // 2026-03 Book 1 test accounts:
      final accounts = [
        acc(101, '招行储蓄卡', 1000), // +1000
        acc(102, '共享现金', 300), // +300
        acc(103, '美元储蓄', 100, currency: 'USD'), // +714.29
        acc(
          104,
          '招行信用卡',
          -200,
          type: AssetType.credit,
          credit: {
            'inst': [
              {'b': '20000', 'i': '1500', 'cb': true, 'ci': true},
              {'b': '7500', 'i': '1000', 'cb': false, 'ci': false},
            ],
          },
        ), // -200 bal, 300 uncredited inst
        acc(
          105,
          '朋友借入',
          400,
          type: AssetType.debt,
          sub: 100,
          eff: 0,
        ), // 400 debt
      ];

      // Total gross assets = 1000 + 300 + 714.29 = 2014.29
      final grossAnchor = computeTrendAnchor(
        accounts: accounts,
        rates: rates,
        filter: const AssetTrendFilter.allEffective(),
        perspective: AssetTrendPerspective.totalAsset,
      );
      expect(grossAnchor, y(2014.29));

      // Net worth with uncredited installment: 2014.29 - (200 + 400 + 300) = 1114.29
      final netWithInst = computeTrendAnchor(
        accounts: accounts,
        rates: rates,
        filter: const AssetTrendFilter.allEffective(),
        perspective: AssetTrendPerspective.netWorth,
        includeInstallment: true,
      );
      expect(netWithInst, y(1114.29));

      // Trend backward engine under net worth perspective with anchor 1114.29:
      final trend = computeAssetTrend(
        accounts: accounts,
        records: const [],
        rates: rates,
        filter: const AssetTrendFilter.allEffective(),
        perspective: AssetTrendPerspective.netWorth,
        explicitAnchorMinor: y(1114.29),
        selectedYear: 2026,
      );
      expect(trend.anchorMinor, y(1114.29));
      expect(trend.chartPoints.last.balanceMinor, y(1114.29));
    });

    test(
      'CE-AT-06: Cross-boundary transfer & interest backward walk (ASYM-AT-06 / 07b)',
      () {
        final accounts = [
          acc(101, '储蓄卡', 1000),
          acc(102, '现金', 300),
          acc(103, '美元', 100, currency: 'USD'),
          acc(104, '信用卡', -200, type: AssetType.credit),
          acc(105, '借入', 400, type: AssetType.debt, sub: 100, eff: 0),
          acc(107, '理财（不计入）', 600, eff: 0), // outside S!
        ];

        // Records in 2026-03:
        // Inflow: 640 (R02 +500, R07 +140)
        // Outflow: 150 (R01 100, R03 50) + R06 (80 from 101 to 107 outside S) + R09 (15 interest expense) = 245
        // Net flow = 640 - 245 = +395
        // Backward walk from 1114.29: 1114.29 - 395 = 719.29
        final records = [
          // R02: income 500
          TrendRecord(
            id: 'R02',
            type: RecordType.income,
            moneyMinor: y(500),
            recordTime: DateTime(2026, 3, 10).millisecondsSinceEpoch,
            assetId: 101,
          ),
          // R07: 20 USD income with bm = 140 CNY
          TrendRecord(
            id: 'R07',
            type: RecordType.income,
            moneyMinor: y(20),
            recordTime: DateTime(2026, 3, 15).millisecondsSinceEpoch,
            assetId: 103,
            currency: CurrencySnapshot(
              sourceCode: 'USD',
              sourceGross: BigInt.from(2000),
              baseCode: 'CNY',
              baseAmount: BigInt.from(14000),
            ),
          ),
          // R01: expense 100 (sm 120, discount 20)
          TrendRecord(
            id: 'R01',
            type: RecordType.expense,
            moneyMinor: y(100),
            discountMinor: y(20),
            recordTime: DateTime(2026, 3, 5).millisecondsSinceEpoch,
            assetId: 101,
            currency: CurrencySnapshot(
              sourceCode: 'CNY',
              sourceGross: BigInt.from(12000),
            ),
          ),
          // R03: Book 2 expense 50 on shared account 102
          TrendRecord(
            id: 'R03',
            type: RecordType.expense,
            moneyMinor: y(50),
            recordTime: DateTime(2026, 3, 8).millisecondsSinceEpoch,
            assetId: 102,
            accountBookId: 2,
          ),
          // R06: cross-boundary transfer 80 from 101 (in S) to 107 (outside S)
          TrendRecord(
            id: 'R06',
            type: RecordType.transfer,
            moneyMinor: y(80),
            recordTime: DateTime(2026, 3, 12).millisecondsSinceEpoch,
            fromAssetId: 101,
            toAssetId: 107,
          ),
          // R09: debt interest payment 15 (type=14 or debtInterest sub=0)
          TrendRecord(
            id: 'R09',
            type: RecordType.installmentPrincipal, // type 14
            moneyMinor: y(15),
            recordTime: DateTime(2026, 3, 18).millisecondsSinceEpoch,
            assetId: 105,
          ),
          // Earlier record in 2026-01 establishing history baseline
          TrendRecord(
            id: 'R_EARLIER',
            type: RecordType.income,
            moneyMinor: y(100),
            recordTime: DateTime(2026, 1, 15).millisecondsSinceEpoch,
            assetId: 101,
          ),
        ];

        final trend = computeAssetTrend(
          accounts: accounts,
          records: records,
          rates: rates,
          filter: const AssetTrendFilter.allEffective(),
          perspective: AssetTrendPerspective.netWorth,
          explicitAnchorMinor: y(1114.29),
          selectedYear: 2026,
          referenceDate: DateTime(2026, 3, 31),
        );

        final p2026_03 = trend.chartPoints.firstWhere(
          (p) => p.yearMonth == '2026-03',
        );
        final p2026_02 = trend.chartPoints.firstWhere(
          (p) => p.yearMonth == '2026-02',
        );

        expect(p2026_03.inflowMinor, y(640));
        expect(p2026_03.outflowMinor, y(245));
        expect(p2026_03.balanceMinor, y(1114.29));

        // 2026-02 end-of-period net asset correctly backward walked to 719.29 (NOT original bug 624.29)
        expect(p2026_02.balanceMinor, y(719.29));
        expect(p2026_02.hasRecords, false);
        expect(p2026_02.isCarriedForward, true);
      },
    );

    test(
      'CE-AT-01: Deposit interest type=17 backward deduction (ASYM-AT-07a)',
      () {
        final accounts = [acc(101, '定存账户', 1000)];

        final records = [
          TrendRecord(
            id: 'R_DEPOSIT_INIT',
            type: RecordType.income,
            moneyMinor: y(940),
            recordTime: DateTime(2026, 1, 10).millisecondsSinceEpoch,
            assetId: 101,
          ),
          TrendRecord(
            id: 'R04',
            type: RecordType.depositInterest, // type 17
            moneyMinor: y(60),
            recordTime: DateTime(2026, 3, 20).millisecondsSinceEpoch,
            assetId: 101,
          ),
        ];

        final trend = computeAssetTrend(
          accounts: accounts,
          records: records,
          rates: rates,
          filter: const AssetTrendFilter.singleAsset(101),
          explicitAnchorMinor: y(1000),
          selectedYear: 2026,
          referenceDate: DateTime(2026, 3, 31),
        );

        final p03 = trend.chartPoints.firstWhere(
          (p) => p.yearMonth == '2026-03',
        );
        final p02 = trend.chartPoints.firstWhere(
          (p) => p.yearMonth == '2026-02',
        );

        expect(p03.balanceMinor, y(1000));
        expect(p03.inflowMinor, y(60));
        // Prior month deducts the 60 deposit interest: 1000 - 60 = 940
        expect(p02.balanceMinor, y(940));
      },
    );

    test(
      'CE-AT-05: Credit card arrears without double negative (ASYM-AT-04b)',
      () {
        final accounts = [acc(104, '招行信用卡', -200, type: AssetType.credit)];

        final trend = computeAssetTrend(
          accounts: accounts,
          records: const [],
          rates: rates,
          filter: const AssetTrendFilter.singleAsset(104),
          selectedYear: 2026,
        );

        expect(trend.isCredit, true);
        expect(trend.anchorMinor, y(-200));

        // Formatted text test:
        final textArrears = formatTrendBalance(y(-200), isCredit: true);
        expect(textArrears, '欠款：¥200.00'); // strictly NO "欠款：-¥200.00"

        final textZero = formatTrendBalance(BigInt.zero, isCredit: true);
        expect(textZero, '欠款：¥0.00');

        final textPositive = formatTrendBalance(y(150), isCredit: true);
        expect(textPositive, '溢存款：¥150.00');
      },
    );

    test(
      'CE-AT-08: Foreign currency single account symbol and value consistency (ASYM-AT-05)',
      () {
        final accounts = [acc(103, '美元储蓄', 100, currency: 'USD')];

        // 1. Default: convert to base currency CNY
        final trendCny = computeAssetTrend(
          accounts: accounts,
          records: const [],
          rates: rates,
          filter: const AssetTrendFilter.singleAsset(103),
          useOriginalCurrency: false,
          selectedYear: 2026,
        );
        expect(trendCny.currencySymbol, '¥');
        expect(trendCny.anchorMinor, y(714.29));
        expect(
          formatTrendBalance(
            trendCny.anchorMinor,
            isCredit: false,
            symbol: trendCny.currencySymbol,
          ),
          '余额：¥714.29',
        );

        // 2. Switched to original currency USD
        final trendUsd = computeAssetTrend(
          accounts: accounts,
          records: const [],
          rates: rates,
          filter: const AssetTrendFilter.singleAsset(103),
          useOriginalCurrency: true,
          selectedYear: 2026,
        );
        expect(trendUsd.currencySymbol, r'$');
        expect(trendUsd.anchorMinor, y(100));
        expect(
          formatTrendBalance(
            trendUsd.anchorMinor,
            isCredit: false,
            symbol: trendUsd.currencySymbol,
          ),
          r'余额：$100.00',
        );
      },
    );

    test('Historical year selection: generates full 12 months (CE-AT-09)', () {
      final accounts = [acc(101, '储蓄卡', 500)];
      final records = [
        // One record in 2025-12
        TrendRecord(
          id: 'R2025',
          type: RecordType.income,
          moneyMinor: y(100),
          recordTime: DateTime(2025, 12, 10).millisecondsSinceEpoch,
          assetId: 101,
        ),
      ];

      final trend = computeAssetTrend(
        accounts: accounts,
        records: records,
        rates: rates,
        filter: const AssetTrendFilter.singleAsset(101),
        explicitAnchorMinor: y(500),
        selectedYear: 2025,
      );

      expect(trend.chartPoints.length, 12);
      expect(trend.chartPoints.first.yearMonth, '2025-01');
      expect(trend.chartPoints.last.yearMonth, '2025-12');
      // Before first record (2025-01..11), balance is 0
      expect(trend.chartPoints.first.balanceMinor, BigInt.zero);
      expect(trend.chartPoints[10].balanceMinor, BigInt.zero); // 2025-11
      expect(trend.chartPoints[11].balanceMinor, y(500)); // 2025-12
      expect(trend.tableRows.length, 12);
      expect(trend.tableRows.first.yearMonth, '2025-12'); // descending
    });

    test(
      '< 3 months in all-time mode: future extension padding in chartPoints and stripped in tableRows',
      () {
        final accounts = [acc(101, '储蓄卡', 500)];
        final records = [
          TrendRecord(
            id: 'R01',
            type: RecordType.income,
            moneyMinor: y(100),
            recordTime: DateTime(2026, 3, 10).millisecondsSinceEpoch,
            assetId: 101,
          ),
        ];

        final trend = computeAssetTrend(
          accounts: accounts,
          records: records,
          rates: rates,
          filter: const AssetTrendFilter.singleAsset(101),
          explicitAnchorMinor: y(500),
          selectedYear: null, // "所有时间"
          referenceDate: DateTime(2026, 3, 31),
        );

        // chartPoints padded to 3 points: 2026-03, 2026-04, 2026-05
        expect(trend.chartPoints.length, 3);
        expect(trend.chartPoints[0].yearMonth, '2026-03');
        expect(trend.chartPoints[0].isFuturePadding, false);
        expect(trend.chartPoints[1].yearMonth, '2026-04');
        expect(trend.chartPoints[1].isFuturePadding, true);
        expect(trend.chartPoints[2].yearMonth, '2026-05');
        expect(trend.chartPoints[2].isFuturePadding, true);

        // tableRows strips future padding: only 2026-03
        expect(trend.tableRows.length, 1);
        expect(trend.tableRows[0].yearMonth, '2026-03');
      },
    );

    test(
      'Card 1: computeAssetDistribution excludes isEffectiveAsset=0 and hidden/archived accounts (ASYM-AT-02)',
      () {
        final accounts = [
          acc(101, '招行储蓄卡', 1000), // active, counted -> positive 1000
          acc(102, '现金', 300), // active, counted -> positive 300
          acc(
            104,
            '信用卡',
            -200,
            type: AssetType.credit,
          ), // active, counted -> liability 200
          acc(
            105,
            '朋友借入',
            400,
            type: AssetType.debt,
            sub: 100,
            eff: 0,
          ), // active, counted -> liability 400
          acc(
            106,
            '借给同事',
            250,
            type: AssetType.debt,
            sub: 99,
            eff: 1,
          ), // debt eff=1 -> NOT counted!
          acc(107, '理财（不计入）', 600, eff: 0), // eff=0 -> NOT counted!
          acc(
            108,
            '隐藏备用金',
            150,
            status: AssetStatus.hidden,
          ), // hidden -> excluded!
          acc(
            109,
            '归档备用金',
            50,
            status: AssetStatus.settled,
          ), // settled -> excluded!
        ];

        final dist = computeAssetDistribution(accounts, rates);

        // Positive total: 1000 + 300 = 1300
        expect(dist.positiveTotalMinor, y(1300));
        expect(dist.positiveItems.length, 2);
        expect(dist.positiveItems[0].name, '招行储蓄卡');
        expect(dist.positiveItems[0].amountMinor, y(1000));
        expect(dist.positiveItems[1].name, '现金');
        expect(dist.positiveItems[1].amountMinor, y(300));

        // Liability total: 200 + 400 = 600
        expect(dist.liabilityTotalMinor, y(600));
        expect(dist.liabilityItems.length, 2);
        expect(dist.liabilityItems[0].name, '朋友借入');
        expect(dist.liabilityItems[0].amountMinor, y(400));
        expect(dist.liabilityItems[1].name, '信用卡');
        expect(dist.liabilityItems[1].amountMinor, y(200));

        // 106, 107, 108, 109 are completely excluded!
        final allNames = [
          ...dist.positiveItems.map((e) => e.name),
          ...dist.liabilityItems.map((e) => e.name),
        ];
        expect(allNames.contains('借给同事'), false);
        expect(allNames.contains('理财（不计入）'), false);
        expect(allNames.contains('隐藏备用金'), false);
        expect(allNames.contains('归档备用金'), false);
      },
    );

    test(
      'Filter scope: built-in category & custom group filter active only, singleAsset includes hidden (ASYM-AT-03 / R3)',
      () {
        final accounts = [
          acc(101, '活期卡', 1000, groupName: '常用'),
          acc(108, '隐藏卡', 500, groupName: '常用', status: AssetStatus.hidden),
          acc(109, '归档卡', 200, groupName: '常用', status: AssetStatus.settled),
        ];

        // Custom group strictly filters active accounts
        const groupFilter = AssetTrendFilter.customGroup('常用');
        final groupMatches = accounts.where(groupFilter.matches).toList();
        expect(groupMatches.length, 1);
        expect(groupMatches.first.id, 101);

        // Single asset allows viewing hidden account
        const hiddenFilter = AssetTrendFilter.singleAsset(108);
        final hiddenMatches = accounts.where(hiddenFilter.matches).toList();
        expect(hiddenMatches.length, 1);
        expect(hiddenMatches.first.id, 108);
      },
    );

    test('Billing period startDay attribution (R4)', () {
      // Book 1 start_day = 5
      // 2026-01-03: day 3 < 5 -> belongs to 2025-12
      final k1 = getPeriodKey(
        DateTime(2026, 1, 3, 10, 0).millisecondsSinceEpoch,
        5,
      );
      expect(k1, '2025-12');

      // 2026-01-05: day 5 >= 5 -> belongs to 2026-01
      final k2 = getPeriodKey(
        DateTime(2026, 1, 5, 10, 0).millisecondsSinceEpoch,
        5,
      );
      expect(k2, '2026-01');

      // start_day = 1 (standard calendar month)
      final k3 = getPeriodKey(
        DateTime(2026, 1, 1, 10, 0).millisecondsSinceEpoch,
        1,
      );
      expect(k3, '2026-01');
    });
  });
}
