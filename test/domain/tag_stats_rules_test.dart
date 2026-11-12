import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/domain/ledger/record_extra.dart';
import 'package:tallyisle/domain/ledger/record_relations.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/category_stats.dart';
import 'package:tallyisle/domain/rules/tag_stats.dart';

void main() {
  group('tag_stats domain rules', () {
    final tags = <TagStatMeta>[
      const TagStatMeta(
        tagId: 'grp-trip',
        name: '2026日本旅行',
        parentId: '-1',
        isGroup: true,
        color: '#1E88E5',
        sort: 1,
      ),
      const TagStatMeta(
        tagId: 'tag-flight',
        name: '机票',
        parentId: 'grp-trip',
        color: '#3949AB',
        sort: 2,
      ),
      const TagStatMeta(
        tagId: 'tag-hotel',
        name: '酒店',
        parentId: 'grp-trip',
        color: '#8E24AA',
        sort: 3,
      ),
      const TagStatMeta(
        tagId: 'tag-empty-child',
        name: '签证',
        parentId: 'grp-trip',
        sort: 4,
      ),
      const TagStatMeta(
        tagId: 'tag-party',
        name: '聚会',
        color: '#E53935',
        sort: 5,
      ),
      const TagStatMeta(
        tagId: 'tag-bonus',
        name: '年终奖',
        color: '#43A047',
        sort: 6,
      ),
    ];

    final categories = <int, CategoryMeta>{
      10: const CategoryMeta(id: 10, name: '交通', type: 0, parentCatId: -1),
      11: const CategoryMeta(id: 11, name: '航班', type: 0, parentCatId: 10),
      20: const CategoryMeta(id: 20, name: '住宿', type: 0, parentCatId: -1),
      30: const CategoryMeta(id: 30, name: '餐饮', type: 0, parentCatId: -1),
      40: const CategoryMeta(id: 40, name: '薪资', type: 1, parentCatId: -1),
    };

    test(
      'computeTagRankings handles exact BigInt amounts, tie-breaking, and multi-tag deduplicated header totals',
      () {
        // Use amounts including large int64 minor units beyond IEEE-754 double 53-bit precision
        final hugeA = BigInt.parse('1000000000000001'); // 10,000,000,000,000.01
        final hugeB = BigInt.parse('1000000000000002'); // 10,000,000,000,000.02

        final entries = <CategoryStatEntry>[
          CategoryStatEntry(
            recordId: 'r1',
            accountBookId: 1,
            recordTime: 1000,
            type: RecordType.expense,
            moneyMinor: hugeA,
            recordCatId: 11,
          ),
          CategoryStatEntry(
            recordId: 'r2',
            accountBookId: 1,
            recordTime: 2000,
            type: RecordType.expense,
            moneyMinor: hugeB,
            recordCatId: 20,
          ),
        ];

        final recordTagIds = <String, List<String>>{
          // r1 carries both tag-flight and tag-party (plus duplicate tag-flight in input)
          'r1': ['tag-flight', 'tag-flight', 'tag-party'],
          'r2': ['tag-hotel'],
        };

        final res = computeTagRankings(
          entries: entries,
          recordTagIds: recordTagIds,
          tags: tags,
          bucket: StatBucket.expense,
        );

        // Header total must be exact BigInt sum of distinct tagged bills (r1 + r2)
        expect(res.totalMinor, hugeA + hugeB);
        expect(res.totalBillCount, 2);

        expect(res.items.length, 3);
        expect(res.items[0].tagId, 'tag-hotel');
        expect(res.items[0].moneyMinor, hugeB);
        expect(res.items[0].count, 1);
        expect(res.items[0].ratioBasisPoints, 5000);

        // tag-flight and tag-party tie on amount (hugeA) and count (1), ordered by sort
        expect(res.items[1].tagId, 'tag-flight');
        expect(res.items[1].moneyMinor, hugeA);
        expect(res.items[1].parentName, '2026日本旅行');
        expect(res.items[1].count, 1);

        expect(res.items[2].tagId, 'tag-party');
        expect(res.items[2].moneyMinor, hugeA);
        expect(res.items[2].count, 1);
      },
    );

    test(
      'foreign currency bills convert consistently via CurrencySnapshot (amountIn)',
      () {
        final usdSnap = CurrencySnapshot(
          sourceCode: 'USD',
          sourceGross: BigInt.from(10000), // $100.00
          assetCode: 'USD',
          assetNet: BigInt.from(10000),
          baseCode: 'CNY',
          baseAmount: BigInt.from(72535), // ¥725.35
        );

        final entries = <CategoryStatEntry>[
          CategoryStatEntry(
            recordId: 'fx-1',
            accountBookId: 1,
            recordTime: 1000,
            type: RecordType.expense,
            moneyMinor: BigInt.from(10000),
            recordCatId: 20,
            currency: usdSnap,
          ),
          CategoryStatEntry(
            recordId: 'cny-1',
            accountBookId: 1,
            recordTime: 2000,
            type: RecordType.expense,
            moneyMinor: BigInt.from(27465), // ¥274.65
            recordCatId: 30,
          ),
        ];

        final recordTagIds = <String, List<String>>{
          'fx-1': ['tag-hotel'],
          'cny-1': ['tag-party'],
        };

        final rankings = computeTagRankings(
          entries: entries,
          recordTagIds: recordTagIds,
          tags: tags,
          bucket: StatBucket.expense,
          targetCurrency: 'CNY',
        );

        expect(rankings.totalMinor, BigInt.from(100000)); // ¥1000.00
        expect(rankings.items.first.tagId, 'tag-hotel');
        expect(rankings.items.first.moneyMinor, BigInt.from(72535));
        expect(
          rankings.items.first.ratioBasisPoints,
          7254,
        ); // 72.535% -> 72.54%

        final single = computeSingleTagStats(
          targetTagId: 'tag-hotel',
          entries: entries,
          recordTagIds: recordTagIds,
          tags: tags,
          categories: categories,
          targetCurrency: 'CNY',
        );
        expect(single.totalExpense, BigInt.from(72535));
        expect(single.netBalance, BigInt.from(-72535));
      },
    );

    test(
      'parent tag group aggregation NEVER double-counts a record tagged with multiple child tags or group+child',
      () {
        final entries = <CategoryStatEntry>[
          // r-combo: ¥3500.00 tagged with BOTH child tags (机票 + 酒店)
          CategoryStatEntry(
            recordId: 'r-combo',
            accountBookId: 1,
            recordTime: 1000,
            type: RecordType.expense,
            moneyMinor: BigInt.from(350000),
            recordCatId: 11, // 航班 -> rolls up to 交通(10)
          ),
          // r-hotel-grp: ¥1200.00 tagged with BOTH child (酒店) AND parent group (2026日本旅行)
          CategoryStatEntry(
            recordId: 'r-hotel-grp',
            accountBookId: 1,
            recordTime: 2000,
            type: RecordType.expense,
            moneyMinor: BigInt.from(120000),
            recordCatId: 20, // 住宿
          ),
          // r-direct-only: ¥300.00 tagged directly on parent group only
          CategoryStatEntry(
            recordId: 'r-direct-only',
            accountBookId: 1,
            recordTime: 3000,
            type: RecordType.expense,
            moneyMinor: BigInt.from(30000),
            recordCatId: -1, // 未分类
          ),
          // r-income: ¥500.00 cashback tagged on 机票
          CategoryStatEntry(
            recordId: 'r-income',
            accountBookId: 1,
            recordTime: 4000,
            type: RecordType.income,
            moneyMinor: BigInt.from(50000),
            recordCatId: 40,
          ),
        ];

        final recordTagIds = <String, List<String>>{
          'r-combo': ['tag-flight', 'tag-hotel'],
          'r-hotel-grp': ['grp-trip', 'tag-hotel'],
          'r-direct-only': ['grp-trip'],
          'r-income': ['tag-flight'],
        };

        // 1. SingleTagStats on parent group
        final groupStats = computeSingleTagStats(
          targetTagId: 'grp-trip',
          entries: entries,
          recordTagIds: recordTagIds,
          tags: tags,
          categories: categories,
        );

        expect(groupStats.isGroup, isTrue);
        expect(groupStats.childTags.length, 3);
        // Distinct expense = 3500 + 1200 + 300 = 5000.00 (500000 minor)
        expect(groupStats.totalExpense, BigInt.from(500000));
        expect(groupStats.totalIncome, BigInt.from(50000));
        expect(groupStats.netBalance, BigInt.from(-450000));
        expect(groupStats.billCount, 4);
        expect(groupStats.matchingRecordIds, [
          'r-income',
          'r-direct-only',
          'r-hotel-grp',
          'r-combo',
        ]);

        // Category breakdown (secondary category 11 rolled up to 10 '交通', -1 to '未分类')
        expect(
          groupStats.expenseCategories
              .map((c) => (c.name, c.moneyMinor))
              .toList(),
          [
            ('交通', BigInt.from(350000)),
            ('住宿', BigInt.from(120000)),
            ('未分类', BigInt.from(30000)),
          ],
        );

        // Child breakdown shows individual contributions per child tag
        final hotelChild = groupStats.childBreakdowns.firstWhere(
          (c) => c.tagId == 'tag-hotel',
        );
        expect(hotelChild.expenseMinor, BigInt.from(470000)); // 3500 + 1200
        expect(hotelChild.billCount, 2);

        final flightChild = groupStats.childBreakdowns.firstWhere(
          (c) => c.tagId == 'tag-flight',
        );
        expect(flightChild.expenseMinor, BigInt.from(350000));
        expect(flightChild.incomeMinor, BigInt.from(50000));
        expect(flightChild.billCount, 2);

        // 2. TagRankings with rollupGroups: true also deduplicates!
        final rolledRankings = computeTagRankings(
          entries: entries,
          recordTagIds: recordTagIds,
          tags: tags,
          bucket: StatBucket.expense,
          rollupGroups: true,
        );
        expect(rolledRankings.items.single.tagId, 'grp-trip');
        expect(rolledRankings.items.single.moneyMinor, BigInt.from(500000));
        expect(rolledRankings.items.single.count, 3);

        // 3. computeTagRecordCounts also deduplicates group distinct bill count!
        final counts = computeTagRecordCounts(
          recordTagIds: recordTagIds,
          tags: tags,
        );
        expect(counts['grp-trip'], 4);
        expect(counts['tag-flight'], 2);
        expect(counts['tag-hotel'], 2);
        expect(counts['tag-empty-child'], 0);
      },
    );

    test(
      'refund netting, over-refund axis flip, reimbursable states, excludeExIn, transfer, and type 15 exclusion',
      () {
        final partialRefundRel = RecordRelations()
          ..refunds = BillLinks(
            children: [
              LinkedBill(billId: 'ref-child-1', amount: BigInt.from(3000)),
            ],
          );
        final refundChildRel = RecordRelations()
          ..refunds = BillLinks(originId: 'exp-origin');

        final overRefundRel = RecordRelations()
          ..refunds = BillLinks(
            children: [
              LinkedBill(billId: 'ref-child-2', amount: BigInt.from(15000)),
            ],
          );

        final partialReimbRel = RecordRelations()
          ..reimbursements = BillLinks(
            children: [
              LinkedBill(billId: 'reimb-rcpt-1', amount: BigInt.from(8000)),
            ],
          );

        final entries = <CategoryStatEntry>[
          // 1. ¥100.00 expense with ¥30.00 refund -> net ¥70.00 expense
          CategoryStatEntry(
            recordId: 'exp-origin',
            accountBookId: 1,
            recordTime: 1000,
            type: RecordType.expense,
            moneyMinor: BigInt.from(10000),
            recordCatId: 30,
            relations: partialRefundRel,
          ),
          // Linked refund child -> ignored in stats so never double-counted
          CategoryStatEntry(
            recordId: 'ref-child-1',
            accountBookId: 1,
            recordTime: 1100,
            type: RecordType.expense,
            moneyMinor: BigInt.from(-3000),
            recordCatId: 30,
            relations: refundChildRel,
          ),
          // 2. ¥100.00 expense with ¥150.00 refund -> ¥50.00 income!
          CategoryStatEntry(
            recordId: 'exp-overref',
            accountBookId: 1,
            recordTime: 2000,
            type: RecordType.expense,
            moneyMinor: BigInt.from(10000),
            recordCatId: 30,
            relations: overRefundRel,
          ),
          // 3. ¥200.00 reimbursable with ¥80.00 reimbursed -> ¥120.00 net expense
          CategoryStatEntry(
            recordId: 'reimb-partial',
            accountBookId: 1,
            recordTime: 3000,
            type: RecordType.reimbursable,
            moneyMinor: BigInt.from(20000),
            recordCatId: 10,
            relations: partialReimbRel,
          ),
          // 4. Reimburse receipt (type 15) -> strictly excluded from both stats and bill list
          CategoryStatEntry(
            recordId: 'reimb-rcpt-1',
            accountBookId: 1,
            recordTime: 3100,
            type: RecordType.reimburseReceipt,
            moneyMinor: BigInt.from(8000),
          ),
          // 5. excludeExIn == true -> excluded from expense/income totals, still visible in bill list
          CategoryStatEntry(
            recordId: 'exp-excluded',
            accountBookId: 1,
            recordTime: 4000,
            type: RecordType.expense,
            moneyMinor: BigInt.from(99900),
            excludeExIn: true,
            recordCatId: 30,
          ),
          // 6. Transfer -> excluded from expense/income totals, still visible in bill list
          CategoryStatEntry(
            recordId: 'transfer-1',
            accountBookId: 1,
            recordTime: 5000,
            type: RecordType.transfer,
            moneyMinor: BigInt.from(50000),
          ),
        ];

        final recordTagIds = <String, List<String>>{
          for (final e in entries) e.recordId: ['tag-party'],
        };

        final expRank = computeTagRankings(
          entries: entries,
          recordTagIds: recordTagIds,
          tags: tags,
          bucket: StatBucket.expense,
        );
        // 70.00 + 120.00 = 190.00 (19000 minor), 2 statistical bills
        expect(expRank.totalMinor, BigInt.from(19000));
        expect(expRank.items.single.moneyMinor, BigInt.from(19000));
        expect(expRank.items.single.count, 2);

        final incRank = computeTagRankings(
          entries: entries,
          recordTagIds: recordTagIds,
          tags: tags,
          bucket: StatBucket.income,
        );
        // Over-refund excess = 50.00 (5000 minor)
        expect(incRank.totalMinor, BigInt.from(5000));
        expect(incRank.items.single.moneyMinor, BigInt.from(5000));

        final detail = computeSingleTagStats(
          targetTagId: 'tag-party',
          entries: entries,
          recordTagIds: recordTagIds,
          tags: tags,
          categories: categories,
        );
        expect(detail.totalExpense, BigInt.from(19000));
        expect(detail.totalIncome, BigInt.from(5000));
        expect(detail.netBalance, BigInt.from(-14000));
        // Type 15 ('reimb-rcpt-1') is excluded; the other 6 non-type-15 records are included
        expect(detail.billCount, 6);
        expect(detail.matchingRecordIds.contains('reimb-rcpt-1'), isFalse);
      },
    );

    test('parseTagColorArgb parses hex and legacy integer colors', () {
      expect(parseTagColorArgb(null), isNull);
      expect(parseTagColorArgb('   '), isNull);
      expect(parseTagColorArgb('#E53935'), 0xFFE53935);
      expect(parseTagColorArgb('#801E88E5'), 0x801E88E5);
      expect(parseTagColorArgb('-1754827'), 0xFFE53935);
    });
  });
}
