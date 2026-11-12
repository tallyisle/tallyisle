import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/domain/ledger/record_extra.dart';
import 'package:tallyisle/domain/ledger/record_relations.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/batch_edit_rules.dart';
import 'package:tallyisle/domain/rules/category_transfer_rules.dart';
import 'package:tallyisle/domain/rules/receipt_diy_rules.dart';

Matcher _fails(FailureCode code) =>
    throwsA(isA<Failure>().having((f) => f.code, 'code', code));

void main() {
  group('CategoryTransferRules (F-031)', () {
    test('CategoryPack 2-level nested JSON round-trip preserves hierarchy', () {
      final pack = CategoryPack(
        bookName: '日常账本',
        exportedAtMs: 1730000000000,
        categories: [
          CategoryNode(
            name: '餐饮',
            type: 0,
            icon: 'food',
            colorFill: '#FF8A65',
            sort: 0,
            children: [
              CategoryNode(name: '早餐', type: 0, icon: 'breakfast', sort: 0),
              CategoryNode(
                name: '咖啡',
                type: 0,
                icon: 'coffee',
                sort: 1,
                isHide: true,
              ),
            ],
          ),
          CategoryNode(name: '工资', type: 1, icon: 'salary', sort: 0),
        ],
      );

      expect(pack.topCategoryCount, 2);
      expect(pack.subCategoryCount, 2);
      expect(pack.totalCategoryCount, 4);
      expect(pack.expenseTopCount, 1);
      expect(pack.incomeTopCount, 1);

      final bytes = pack.encodeUtf8Bytes();
      final decoded = CategoryPack.decodeUtf8Bytes(bytes);

      expect(decoded.version, 1);
      expect(decoded.bookName, '日常账本');
      expect(decoded.exportedAtMs, 1730000000000);
      expect(decoded.categories, hasLength(2));
      expect(decoded.categories[0].name, '餐饮');
      expect(decoded.categories[0].children, hasLength(2));
      expect(decoded.categories[0].children[1].name, '咖啡');
      expect(decoded.categories[0].children[1].isHide, isTrue);
      expect(decoded.categories[1].name, '工资');
      expect(decoded.categories[1].type, 1);
    });

    test(
      'CategoryPack decodes flat {id, parent_cat_id} JSON representation',
      () {
        final flatJson = jsonEncode({
          'bookName': '平铺导入',
          'categories': [
            {'id': 10, 'name': '交通', 'type': 0, 'parent_cat_id': -1, 'sort': 1},
            {'id': 11, 'name': '地铁', 'type': 0, 'parent_cat_id': 10, 'sort': 0},
            {'id': 12, 'name': '打车', 'type': 0, 'parent_cat_id': 10, 'sort': 1},
          ],
        });

        final pack = CategoryPack.decodeJson(flatJson);
        expect(pack.topCategoryCount, 1);
        expect(pack.subCategoryCount, 2);
        expect(pack.categories.single.name, '交通');
        expect(pack.categories.single.children.map((c) => c.name).toList(), [
          '地铁',
          '打车',
        ]);
      },
    );

    test(
      'CategoryPack rejects 3rd-level nesting, future versions, and corrupt payloads',
      () {
        // 3rd level in nested JSON
        final threeLevelNested = jsonEncode({
          'format': categoryPackFormat,
          'version': 1,
          'categories': [
            {
              'name': '餐饮',
              'type': 0,
              'children': [
                {
                  'name': '早餐',
                  'type': 0,
                  'children': [
                    {'name': '豆浆', 'type': 0},
                  ],
                },
              ],
            },
          ],
        });
        expect(
          () => CategoryPack.decodeJson(threeLevelNested),
          _fails(FailureCode.validation),
        );

        // 3rd level in flat JSON
        final threeLevelFlat = jsonEncode([
          {'id': 1, 'name': 'A', 'type': 0, 'parent_cat_id': -1},
          {'id': 2, 'name': 'B', 'type': 0, 'parent_cat_id': 1},
          {'id': 3, 'name': 'C', 'type': 0, 'parent_cat_id': 2},
        ]);
        expect(
          () => CategoryPack.decodeJson(threeLevelFlat),
          _fails(FailureCode.validation),
        );

        // Future version
        final futureVersion = jsonEncode({
          'format': categoryPackFormat,
          'version': 99,
          'categories': [
            {'name': '餐饮', 'type': 0},
          ],
        });
        expect(
          () => CategoryPack.decodeJson(futureVersion),
          _fails(FailureCode.upgradeRequired),
        );

        // Empty / corrupt
        expect(
          () => CategoryPack.decodeUtf8Bytes(Uint8List(0)),
          _fails(FailureCode.validation),
        );
        expect(
          () => CategoryPack.decodeJson('{bad json'),
          _fails(FailureCode.corruptData),
        );
        expect(
          () => CategoryPack.decodeJson('{"categories":[]}'),
          _fails(FailureCode.validation),
        );
      },
    );

    test(
      'planCategoryMerge reuses matching (type, name) parents and merges children',
      () {
        const targetExisting = [
          ExistingCategorySnapshot(
            id: 1,
            name: '餐饮',
            type: 0,
            parentCatId: -1,
            sort: 0,
            accountBookId: 1,
          ),
          ExistingCategorySnapshot(
            id: 2,
            name: '早餐',
            type: 0,
            parentCatId: 1,
            sort: 0,
            accountBookId: 1,
          ),
          ExistingCategorySnapshot(
            id: 3,
            name: '工资',
            type: 1,
            parentCatId: -1,
            sort: 0,
            accountBookId: 1,
          ),
        ];

        final incoming = [
          CategoryNode(
            name: '餐饮',
            type: 0,
            children: [
              CategoryNode(name: '早餐', type: 0), // duplicate sub
              CategoryNode(
                name: '晚餐',
                type: 0,
              ), // new sub under existing parent
            ],
          ),
          // Internal duplicate top in incoming with another child
          CategoryNode(
            name: '餐饮',
            type: 0,
            children: [CategoryNode(name: '夜宵', type: 0)],
          ),
          // Same name '工资' as expense (type 0 != type 1) -> added as new top!
          CategoryNode(name: '工资', type: 0),
          // New top with 1 child
          CategoryNode(
            name: '宠物',
            type: 0,
            children: [CategoryNode(name: '猫粮', type: 0)],
          ),
        ];

        final plan = planCategoryMerge(
          targetExisting: targetExisting,
          incoming: incoming,
        );

        // Added tops: '工资'(type 0), '宠物'(type 0) -> 2
        expect(plan.addedTopCount, 2);
        // Added subs: '晚餐', '夜宵' under '餐饮' + '猫粮' under '宠物' -> 3
        expect(plan.addedSubCount, 3);
        // Skipped: 1 internal top ('餐饮') + 1 existing top ('餐饮') + 1 existing sub ('早餐') -> 3
        expect(plan.skippedDuplicateCount, 3);

        final foodPlan = plan.topCategories.firstWhere(
          (t) => t.node.name == '餐饮',
        );
        expect(foodPlan.reuseExistingId, 1);
        expect(foodPlan.children, hasLength(3));
        expect(foodPlan.children[0].reuseExistingId, 2);
        expect(foodPlan.children[1].reuseExistingId, isNull);
        expect(foodPlan.children[1].sort, 1);
        expect(foodPlan.children[2].sort, 2);
      },
    );

    test(
      'buildSelectedCategoryTree includes parent when only subcategory is selected',
      () {
        const rows = [
          ExistingCategorySnapshot(
            id: 10,
            name: '出行',
            type: 0,
            parentCatId: -1,
            accountBookId: 1,
          ),
          ExistingCategorySnapshot(
            id: 11,
            name: '高铁',
            type: 0,
            parentCatId: 10,
            accountBookId: 1,
          ),
          ExistingCategorySnapshot(
            id: 12,
            name: '机票',
            type: 0,
            parentCatId: 10,
            accountBookId: 1,
          ),
        ];

        // Selecting only child 11 brings parent 10 + child 11 (not 12).
        final subsetSub = buildSelectedCategoryTree(
          sourceRows: rows,
          selectedIds: {11},
        );
        expect(subsetSub, hasLength(1));
        expect(subsetSub.single.name, '出行');
        expect(subsetSub.single.children.map((c) => c.name).toList(), ['高铁']);

        // Selecting parent 10 without explicit children brings all visible children.
        final subsetTop = buildSelectedCategoryTree(
          sourceRows: rows,
          selectedIds: {10},
        );
        expect(subsetTop.single.children.map((c) => c.name).toList(), [
          '高铁',
          '机票',
        ]);
      },
    );

    test(
      'validateIntraBookMigration enforces book, type, self, and descendant guards',
      () {
        const topA = ExistingCategorySnapshot(
          id: 1,
          name: '餐饮',
          type: 0,
          parentCatId: -1,
          accountBookId: 1,
        );
        const subA1 = ExistingCategorySnapshot(
          id: 2,
          name: '外卖',
          type: 0,
          parentCatId: 1,
          accountBookId: 1,
        );
        const topB = ExistingCategorySnapshot(
          id: 3,
          name: '购物',
          type: 0,
          parentCatId: -1,
          accountBookId: 1,
        );
        const incomeCat = ExistingCategorySnapshot(
          id: 4,
          name: '工资',
          type: 1,
          parentCatId: -1,
          accountBookId: 1,
        );
        const otherBookCat = ExistingCategorySnapshot(
          id: 5,
          name: '餐饮',
          type: 0,
          parentCatId: -1,
          accountBookId: 2,
        );
        const all = [topA, subA1, topB, incomeCat];

        expect(
          validateIntraBookMigration(
            source: topA,
            target: topB,
            allBookCategories: all,
          ),
          [1, 2],
        );

        // Self
        expect(
          () => validateIntraBookMigration(
            source: topA,
            target: topA,
            allBookCategories: all,
          ),
          _fails(FailureCode.validation),
        );
        // Descendant
        expect(
          () => validateIntraBookMigration(
            source: topA,
            target: subA1,
            allBookCategories: all,
          ),
          _fails(FailureCode.validation),
        );
        // Cross-type
        expect(
          () => validateIntraBookMigration(
            source: topA,
            target: incomeCat,
            allBookCategories: all,
          ),
          _fails(FailureCode.validation),
        );
        // Cross-book
        expect(
          () => validateIntraBookMigration(
            source: topA,
            target: otherBookCat,
            allBookCategories: all,
          ),
          _fails(FailureCode.validation),
        );

        expect(
          formatCategoryPackFileName(
            '日常 账本/2026',
            DateTime(2026, 5, 9, 8, 7, 6),
          ),
          'categories_日常_账本_2026_20260509_080706.json',
        );
      },
    );
  });

  group('BatchEditRules (F-025)', () {
    test(
      'R1 guards reject linked children, transfer-fee children, and settled advances',
      () {
        // Normal expense is editable
        validateRecordEditableInBatch(
          type: RecordType.expense,
          relations: RecordRelations(),
          extra: RecordExtra(),
        );

        // Refund child
        final refundChildRel = RecordRelations()
          ..refunds = const BillLinks(originId: 'origin-1');
        expect(
          () => validateRecordEditableInBatch(
            type: RecordType.expense,
            relations: refundChildRel,
            extra: RecordExtra(),
          ),
          _fails(FailureCode.validation),
        );

        // Reimbursement receipt child
        expect(
          () => validateRecordEditableInBatch(
            type: RecordType.reimburseReceipt,
            relations: RecordRelations(),
            extra: RecordExtra(),
          ),
          _fails(FailureCode.validation),
        );

        // Transfer fee child
        final feeChildRel = RecordRelations()
          ..transferFee = const TransferFeeLink(
            feeFromTarget: false,
            parentId: 'tr-1',
          );
        expect(
          () => validateRecordEditableInBatch(
            type: RecordType.fee,
            relations: feeChildRel,
            extra: RecordExtra(),
          ),
          _fails(FailureCode.validation),
        );

        // Settled advance
        final settledAdvanceExtra = RecordExtra()
          ..advance = AdvanceBillInfo(
            advanceDate: 1700000000000,
            advanceMoney: BigInt.from(5000),
            advanceDiffMoney: BigInt.zero,
            partialInclude: false,
          );
        expect(
          () => validateRecordEditableInBatch(
            type: RecordType.advanceExpense,
            relations: RecordRelations(),
            extra: settledAdvanceExtra,
          ),
          _fails(FailureCode.validation),
        );
      },
    );

    test('R2 category & asset slots and multi-currency compatibility', () {
      expect(requiredCategoryTypeForRecord(RecordType.expense), 0);
      expect(requiredCategoryTypeForRecord(RecordType.reimbursable), 0);
      expect(requiredCategoryTypeForRecord(RecordType.advanceExpense), 0);
      expect(requiredCategoryTypeForRecord(RecordType.income), 1);
      expect(requiredCategoryTypeForRecord(RecordType.advanceIncome), 1);
      expect(requiredCategoryTypeForRecord(RecordType.transfer), isNull);
      expect(requiredCategoryTypeForRecord(RecordType.repay), isNull);
      expect(requiredCategoryTypeForRecord(RecordType.fee), isNull);

      expect(
        batchEditableAssetSlot(
          type: RecordType.reimbursable,
          relations: RecordRelations(),
        ),
        BatchAssetSlot.fromAssetColumn,
      );
      expect(
        batchEditableAssetSlot(
          type: RecordType.expense,
          relations: RecordRelations(),
        ),
        BatchAssetSlot.assetColumn,
      );
      expect(
        batchEditableAssetSlot(
          type: RecordType.transfer,
          relations: RecordRelations(),
        ),
        BatchAssetSlot.unsupported,
      );
      expect(
        batchEditableAssetSlot(
          type: RecordType.borrowIn,
          relations: RecordRelations(),
        ),
        BatchAssetSlot.unsupported,
      );

      // CNY -> CNY ok
      validateBatchAssetCurrencyCompatibility(
        oldAssetId: 1,
        oldAssetCurrency: null,
        targetAssetId: 2,
        targetAssetCurrency: 'CNY',
        recordCurrency: null,
      );

      // FX bill recorded in USD -> CNY account (curr.ac = CNY) moved to another CNY account -> ok!
      validateBatchAssetCurrencyCompatibility(
        oldAssetId: 1,
        oldAssetCurrency: 'CNY',
        targetAssetId: 2,
        targetAssetCurrency: 'CNY',
        recordCurrency: CurrencySnapshot(
          sourceCode: 'USD',
          sourceGross: BigInt.from(1000),
          assetCode: 'CNY',
        ),
      );

      // USD account bill moved to CNY account -> rejected!
      expect(
        () => validateBatchAssetCurrencyCompatibility(
          oldAssetId: 3,
          oldAssetCurrency: 'USD',
          targetAssetId: 2,
          targetAssetCurrency: 'CNY',
          recordCurrency: null,
        ),
        _fails(FailureCode.validation),
      );
    });

    test(
      'shiftRecordDatePreservingClock preserves time-of-day and midnight transfer-fee rule',
      () {
        final t1 = DateTime(
          2026,
          3,
          10,
          14,
          35,
          22,
          500,
        ).millisecondsSinceEpoch;
        final normalShift = shiftRecordDatePreservingClock(
          originalTimeMs: t1,
          targetDate: DateTime(2026, 4, 2),
          hasTransferFee: true,
        );
        final expectedNormal = DateTime(
          2026,
          4,
          2,
          14,
          35,
          22,
          500,
        ).millisecondsSinceEpoch;
        expect(normalShift.parentTimeMs, expectedNormal);
        expect(normalShift.feeTimeMs, expectedNormal + 1);

        // 23:59:59.999 boundary: +1ms would cross into next day, so parent shifts -1ms!
        final midnightEdge = DateTime(
          2026,
          3,
          10,
          23,
          59,
          59,
          999,
        ).millisecondsSinceEpoch;
        final edgeShift = shiftRecordDatePreservingClock(
          originalTimeMs: midnightEdge,
          targetDate: DateTime(2026, 4, 2),
          hasTransferFee: true,
        );
        final targetEdgeMs = DateTime(
          2026,
          4,
          2,
          23,
          59,
          59,
          999,
        ).millisecondsSinceEpoch;
        expect(edgeShift.parentTimeMs, targetEdgeMs - 1);
        expect(edgeShift.feeTimeMs, targetEdgeMs);
        expect(
          DateTime.fromMillisecondsSinceEpoch(edgeShift.parentTimeMs).day,
          2,
        );
        expect(
          DateTime.fromMillisecondsSinceEpoch(edgeShift.feeTimeMs!).day,
          2,
        );
      },
    );

    test(
      'mergeBatchTags applies (existing \\ remove) U add deterministically',
      () {
        expect(
          mergeBatchTags(
            existingTagIds: ['t2', 't1', 't3'],
            addTagIds: {'t4', 't1'},
            removeTagIds: {'t2', 't9'},
          ),
          ['t1', 't3', 't4'],
        );
      },
    );
  });

  group('ReceiptDiyRules (F-022 & F-036)', () {
    test(
      'attachment filename validation and CSV/JSON parsing reject unsafe paths & >9 images',
      () {
        expect(validateAttachmentFileName('img_abc123.jpg'), 'img_abc123.jpg');

        for (final bad in [
          '',
          '   ',
          '../secret.png',
          'a/b.png',
          r'a\b.png',
          'C:a.png',
          '.hidden.png',
          'img_1.jpg.tmp',
          'bad\nname.jpg',
        ]) {
          expect(
            () => validateAttachmentFileName(bad),
            _fails(FailureCode.validation),
            reason: 'Expected $bad to be rejected',
          );
        }

        // Comma-joined & legacy JSON array parsing
        expect(parseRecordImages(null), isEmpty);
        expect(parseRecordImages('  '), isEmpty);
        expect(parseRecordImages('a.jpg, b.png , a.jpg'), ['a.jpg', 'b.png']);
        expect(
          parseRecordImages(
            '[{"fname":"legacy1.jpg"},{"fname":"legacy2.png"}]',
          ),
          ['legacy1.jpg', 'legacy2.png'],
        );
        expect(encodeRecordImages(['x.jpg', 'y.png', 'x.jpg']), 'x.jpg,y.png');
        expect(encodeRecordImages(const []), isNull);

        // Max 9 images
        final ten = [for (var i = 0; i < 10; i++) 'img_$i.jpg'];
        expect(() => encodeRecordImages(ten), _fails(FailureCode.validation));
        expect(
          () => parseRecordImages(ten.join(',')),
          _fails(FailureCode.validation),
        );

        // Orphan scan keeps referenced & ignores .tmp staging files
        expect(
          computeOrphanAttachmentNames(
            filesOnDisk: ['a.jpg', 'b.jpg', 'c.jpg', 'staging.jpg.tmp'],
            referencedImageColumns: ['a.jpg', '[{"fname":"c.jpg"}]'],
          ),
          ['b.jpg'],
        );
      },
    );

    test(
      'BillLocationInfo & RecordExtraLocation preserve unknown keys in extra_info',
      () {
        final rawJson = jsonEncode({
          'curr': {'sc': 'USD', 'sm': '1200', 'ac': 'CNY'},
          'custom_future_key': 42,
        });
        final extra = RecordExtra.parse(rawJson);
        expect(extra.location, isNull);

        extra.location = BillLocationInfo(
          simpleName: '静安嘉里中心',
          name: '上海市静安区南京西路 1515 号',
          latitude: 31.2235,
          longitude: 121.4455,
        );

        final reencoded = extra.encode()!;
        final parsed2 = RecordExtra.parse(reencoded);
        expect(parsed2.currency?.sourceCode, 'USD');
        expect(parsed2.raw['custom_future_key'], 42);
        expect(parsed2.location?.displayLabel, '静安嘉里中心');
        expect(parsed2.location?.detailAddress, '上海市静安区南京西路 1515 号');
        expect(parsed2.location?.latitude, 31.2235);
        expect(parsed2.location?.longitude, 121.4455);

        // Clearing location removes 'loc' while keeping 'curr' & unknown keys
        parsed2.location = BillLocationInfo();
        final parsed3 = RecordExtra.parse(parsed2.encode());
        expect(parsed3.location, isNull);
        expect(parsed3.currency?.sourceCode, 'USD');
        expect(parsed3.raw['custom_future_key'], 42);

        // Coordinate bounds & pairing validation
        expect(
          () => BillLocationInfo(simpleName: 'A', latitude: 31.0),
          _fails(FailureCode.validation),
        );
        expect(
          () => BillLocationInfo(latitude: 95.0, longitude: 120.0),
          _fails(FailureCode.validation),
        );
      },
    );

    test(
      'DiyToolbarConfig normalizes missing/corrupt JSON, toggles, and reorders',
      () {
        final def = DiyToolbarConfig.defaults();
        expect(def.items, hasLength(DiyToolbarAction.values.length));
        expect(def.isEnabled(DiyToolbarAction.frequentRemarks), isFalse);
        expect(
          def.visibleActions,
          DiyToolbarAction.values.where((a) => a.defaultEnabled).toList(),
        );

        // Corrupt or partial JSON recovers missing actions cleanly
        final fallback = DiyToolbarConfig.decode('{not-json');
        expect(fallback.items, def.items);

        final partial = DiyToolbarConfig.decode(
          jsonEncode({
            'items': [
              {'key': 'location', 'enabled': true},
              {'key': 'tags', 'enabled': false},
              {'key': 'location', 'enabled': false}, // duplicate ignored
              {'key': 'unknown_action', 'enabled': true}, // unknown ignored
            ],
          }),
        );
        expect(partial.items.first.action, DiyToolbarAction.location);
        expect(partial.items[1].action, DiyToolbarAction.tags);
        expect(partial.isEnabled(DiyToolbarAction.tags), isFalse);
        expect(partial.items, hasLength(DiyToolbarAction.values.length));

        final moved = def
            .setEnabled(DiyToolbarAction.templates, false)
            .moveItem(3, 0);
        expect(moved.items.first.action, DiyToolbarAction.location);
        expect(moved.isEnabled(DiyToolbarAction.templates), isFalse);

        final roundTrip = DiyToolbarConfig.decode(moved.encode());
        expect(roundTrip.items, moved.items);
      },
    );

    test(
      'buildReceiptViewModel formats Money (BigInt) amounts, discount, FX, location, and brand',
      () {
        final extra = RecordExtra()
          ..currency = CurrencySnapshot(
            sourceCode: 'USD',
            sourceGross: BigInt.from(1000),
            assetCode: 'CNY',
          )
          ..location = BillLocationInfo(
            simpleName: '虹桥站',
            name: '上海市闵行区申贵路 1500 号',
          );

        final vm = buildReceiptViewModel(
          recordId: 'abcdef12-3456-7890',
          type: RecordType.expense,
          subType: RecordDirection.none,
          moneyMinor: BigInt.from(6850),
          discountMinor: BigInt.from(350),
          recordTimeMs: DateTime(2026, 6, 15, 9, 5).millisecondsSinceEpoch,
          bookName: '差旅账本',
          categoryLabel: '交通 · 高铁',
          accountLabel: '招商信用卡',
          currencyCode: 'CNY',
          remark: '出差车票',
          excludeBudget: true,
          excludeExIn: false,
          tagNames: ['出差', '报销'],
          extra: extra,
          attachmentCount: 2,
        );

        expect(vm.typeTitle, '支出小票');
        expect(vm.amountText, '-68.50');
        expect(vm.serialNo, 'NO.ABCDEF12');
        expect(vm.dateTimeText, '2026-06-15 09:05');
        expect(vm.brandStamp, '帐屿 · TallyIsle');
        expect(vm.suggestedFileName, 'receipt_20260615_abcdef12.png');
        expect(vm.flags, ['不计入预算']);

        final byLabel = {for (final l in vm.lines) l.label: l.value};
        expect(byLabel['账本'], '差旅账本');
        expect(byLabel['分类'], '交通 · 高铁');
        expect(byLabel['账户'], '招商信用卡');
        expect(byLabel['原价 / 优惠'], '72.00 / -3.50');
        expect(byLabel['外币原额'], 'USD 10.00');
        expect(byLabel['地点'], '虹桥站（上海市闵行区申贵路 1500 号）');
        expect(byLabel['标签'], '#出差 #报销');
        expect(byLabel['图片附件'], '2 张');
      },
    );
  });
}
