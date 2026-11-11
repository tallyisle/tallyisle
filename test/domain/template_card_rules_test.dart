import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/template_card_rules.dart';

void main() {
  group('Template domain rules (F-016)', () {
    test('supports exact 6 record types and maps category/amount rules', () {
      expect(supportedTemplateTypes, <int>[
        RecordType.expense,
        RecordType.income,
        RecordType.transfer,
        RecordType.reimbursable,
        RecordType.advanceExpense,
        RecordType.advanceIncome,
      ]);
      expect(isSupportedTemplateType(RecordType.expense), isTrue);
      expect(isSupportedTemplateType(RecordType.balanceAdjust), isFalse);

      expect(templateCategoryTypeFor(RecordType.expense), RecordType.expense);
      expect(
        templateCategoryTypeFor(RecordType.reimbursable),
        RecordType.expense,
      );
      expect(
        templateCategoryTypeFor(RecordType.advanceExpense),
        RecordType.expense,
      );
      expect(templateCategoryTypeFor(RecordType.income), RecordType.income);
      expect(
        templateCategoryTypeFor(RecordType.advanceIncome),
        RecordType.income,
      );
      expect(templateCategoryTypeFor(RecordType.transfer), isNull);

      expect(templateRequiresPositiveAmount(RecordType.expense), isFalse);
      expect(templateRequiresPositiveAmount(RecordType.income), isFalse);
      expect(templateRequiresPositiveAmount(RecordType.transfer), isTrue);
      expect(templateRequiresPositiveAmount(RecordType.reimbursable), isTrue);
      expect(templateRequiresPositiveAmount(RecordType.advanceIncome), isTrue);
      expect(templateRequiresPositiveAmount(RecordType.advanceExpense), isTrue);
    });

    test('parses exact BigInt Money without double and enforces bounds', () {
      expect(parseTemplateMoneyText('').storageMinor, BigInt.zero);
      expect(parseTemplateMoneyText('.5').storageMinor, BigInt.from(50));
      expect(parseTemplateMoneyText('128.').storageMinor, BigInt.from(12800));
      expect(
        parseTemplateMoneyText('88888888888.00').storageMinor,
        BigInt.parse('8888888888800'),
      );
      expect(
        () => parseTemplateMoneyText('88888888888.01'),
        throwsA(
          isA<Failure>().having((f) => f.code, 'code', FailureCode.validation),
        ),
      );
      expect(
        () => parseTemplateMoneyText('12.345'),
        throwsA(
          isA<Failure>().having(
            (f) => f.code,
            'code',
            FailureCode.scaleMismatch,
          ),
        ),
      );
    });

    test(
      'CSV tags codec deduplicates, trims, and handles legacy JSON array',
      () {
        expect(parseTemplateTagsCsv(null), isEmpty);
        expect(parseTemplateTagsCsv('   '), isEmpty);
        expect(parseTemplateTagsCsv('t1, t2 , t1, ,t3'), <String>[
          't1',
          't2',
          't3',
        ]);
        expect(parseTemplateTagsCsv('["t2","t1","t2"]'), <String>['t2', 't1']);

        expect(encodeTemplateTagsCsv(const <String>[]), isNull);
        expect(encodeTemplateTagsCsv(const <String>['  ', '']), isNull);
        expect(
          encodeTemplateTagsCsv(const <String>[' tagA ', 'tagB', 'tagA']),
          'tagA,tagB',
        );
      },
    );

    test(
      'TemplateExtra round-trips typed fields while preserving unknown keys',
      () {
        final extra = TemplateExtra.parse('{"legacy_flag":true,"fee_from":1}');
        expect(extra.feeFromTarget, isTrue);
        extra.name = '  通勤地铁  ';
        extra.sourceCurrency = 'usd';
        final encoded = extra.encode();

        final reparsed = TemplateExtra.parse(encoded);
        expect(reparsed.name, '通勤地铁');
        expect(reparsed.feeFromTarget, isTrue);
        expect(reparsed.sourceCurrency, 'USD');
        expect(reparsed.raw['legacy_flag'], isTrue);

        expect(
          () => TemplateExtra.parse('{not-json'),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.corruptData,
            ),
          ),
        );
      },
    );

    test(
      'resolveTemplatePrefill maps reimbursable to draftFromAssetId and falls back cleanly on deleted refs (SAFE-TM-01)',
      () {
        final reimbTemplate = TemplateSnapshot(
          id: 3,
          type: RecordType.reimbursable,
          moneyMinor: BigInt.from(12850),
          feeMinor: BigInt.zero,
          bookId: 1,
          recordCatId: 20,
          assetId: 5,
          remark: '差旅打车',
          autoSave: true,
          tags: 'tag1,deleted_tag',
          exi: '{"name":"出差打车"}',
        );

        final validPrefill = resolveTemplatePrefill(
          template: reimbTemplate,
          bookExists: true,
          categoriesById: const <int, TemplateCategoryRef>{
            10: TemplateCategoryRef(
              id: 10,
              name: '交通',
              type: RecordType.expense,
              bookId: 1,
            ),
            20: TemplateCategoryRef(
              id: 20,
              name: '打车',
              type: RecordType.expense,
              bookId: 1,
              parentCatId: 10,
            ),
          },
          assetsById: const <int, TemplateAssetRef>{
            5: TemplateAssetRef(
              id: 5,
              name: '招商信用卡',
              type: AssetType.credit,
              status: AssetStatus.active,
            ),
          },
          validTagIds: const <String>{'tag1'},
        );

        expect(validPrefill.displayTitle, '出差打车');
        expect(validPrefill.categoryId, 20);
        expect(validPrefill.parentCategoryId, 10);
        expect(validPrefill.assetId, 5);
        expect(validPrefill.draftAssetId, noRef);
        expect(validPrefill.draftFromAssetId, 5);
        expect(validPrefill.draftToAssetId, noRef);
        expect(validPrefill.amountText, '128.50');
        expect(validPrefill.tagIds, <String>['tag1']);
        expect(validPrefill.warnings, isEmpty);
        expect(validPrefill.canInstantSave, isTrue);

        // Now simulate category deleted & account settled
        final fallbackPrefill = resolveTemplatePrefill(
          template: reimbTemplate,
          bookExists: true,
          categoriesById: const <int, TemplateCategoryRef>{},
          assetsById: const <int, TemplateAssetRef>{
            5: TemplateAssetRef(
              id: 5,
              name: '招商信用卡',
              type: AssetType.credit,
              status: AssetStatus.settled,
            ),
          },
          validTagIds: const <String>{},
        );

        expect(fallbackPrefill.categoryId, isNull);
        expect(fallbackPrefill.assetId, noRef);
        expect(fallbackPrefill.hasDanglingReference, isTrue);
        expect(fallbackPrefill.canInstantSave, isFalse);
        expect(fallbackPrefill.warnings, hasLength(2));
      },
    );
  });

  group('Frequent Remarks rules (F-016 R4)', () {
    test(
      'golden vector: filters catId or -1 and sorts by usedTimes DESC, id DESC',
      () {
        final rows = <({int id, int catId, int used, String text})>[
          (id: 1, catId: 10, used: 2, text: 'A-早餐'),
          (id: 2, catId: 10, used: 5, text: 'B-午餐'),
          (id: 3, catId: 11, used: 9, text: 'D-其他分类'),
          (id: 4, catId: -1, used: 5, text: 'C-通用报销'),
        ];

        final result = filterAndSortRemarksForCategory(
          rows,
          categoryId: 10,
          recordCatIdOf: (r) => r.catId,
          usedTimesOf: (r) => r.used,
          idOf: (r) => r.id,
        );

        expect(result.map((r) => r.text).toList(), <String>[
          'C-通用报销',
          'B-午餐',
          'A-早餐',
        ]);
      },
    );
  });

  group('Bank Card rules (F-023 R5)', () {
    test(
      'golden vector: normalizes card digits, formats 4-digit groups and **** 1234 mask',
      () {
        const raw = '6222-0212 3456 7890 123';
        final normalized = normalizeBankCardNumber(raw);
        expect(normalized, '6222021234567890123');
        expect(formatCardNumberGrouped(raw), '6222 0212 3456 7890 123');
        expect(formatCardNumberMasked(raw), '**** 0123');

        expect(formatCardNumberMasked('6222021234561234'), '**** 1234');
        expect(formatCardNumberMasked('9876'), '**** 9876');

        expect(
          () => normalizeBankCardNumber('6222ABCD12345678'),
          throwsA(isA<Failure>()),
        );
        expect(
          () => normalizeBankCardNumber('1234567'),
          throwsA(isA<Failure>()),
        );
      },
    );

    test('golden vector: ISO 7812 Luhn check is accurate and never throws', () {
      expect(isValidLuhn('79927398713'), isTrue);
      expect(isValidLuhn('79927398714'), isFalse);
      expect(isValidLuhn('4111 1111-1111 1111'), isTrue);
      expect(isValidLuhn('4111 1111-1111 1112'), isFalse);
      expect(isValidLuhn('0000000000000000'), isFalse);
      expect(isValidLuhn('not-digits'), isFalse);

      expect(inspectCardLuhn('4111 1111 1111 1111').passesLuhn, isTrue);
      expect(inspectCardLuhn('6222 0000 0000 1235').passesLuhn, isFalse);
      expect(
        inspectCardLuhn('6222 0000 0000 1235').badgeLabel,
        contains('仍可保存'),
      );
    });

    test('normalizes card hex color and formats full clipboard summary', () {
      expect(normalizeCardColorHex(null), isNull);
      expect(normalizeCardColorHex('  '), isNull);
      expect(normalizeCardColorHex('1565c0'), '#1565C0');
      expect(normalizeCardColorHex('#ff00796b'), '#FF00796B');
      expect(() => normalizeCardColorHex('#XYZ'), throwsA(isA<Failure>()));

      final summary = formatBankCardFullInfo(
        cardName: '招商银行一卡通',
        cardType: BankCardType.debit,
        cardNo: '6225880112345678',
        cardOwner: '张三',
        remark: '深圳科技园支行',
        linkedAssetName: '招行储蓄卡',
      );
      expect(summary, contains('招商银行一卡通（储蓄卡）'));
      expect(summary, contains('卡号：6225 8801 1234 5678'));
      expect(summary, contains('持卡人：张三'));
      expect(summary, contains('关联账户：招行储蓄卡'));
      expect(summary, contains('备注：深圳科技园支行'));
    });
  });
}
