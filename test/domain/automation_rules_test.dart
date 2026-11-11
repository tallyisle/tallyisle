import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/auto_map_rules.dart';
import 'package:tallyisle/domain/rules/ocr_bill_rules.dart';
import 'package:tallyisle/domain/rules/url_scheme_rules.dart';

void main() {
  group('F-033 url_scheme_rules', () {
    test('parses tallyisle:// and yyjz:// navigation actions identically', () {
      final home1 = parseUrlScheme('tallyisle://home');
      final home2 = parseUrlScheme('yyjz://home');
      expect(home1.action, UrlSchemeAction.home);
      expect(home2.action, UrlSchemeAction.home);
      expect(home1.targetRoute, '/');
      expect(home2.targetRoute, '/');
      expect(home1.writesDirectly, isFalse);

      final cal = parseUrlScheme('tallyisle://calendar');
      expect(cal.action, UrlSchemeAction.calendar);
      expect(cal.targetRoute, '/calendar');

      final statMonth = parseUrlScheme('yyjz://stat?year=2026&month=11');
      expect(statMonth.action, UrlSchemeAction.stat);
      expect(statMonth.targetRoute, '/stats?year=2026&month=11');

      final statAnnual = parseUrlScheme('tallyisle://stat?year=2026&book=2');
      expect(statAnnual.action, UrlSchemeAction.stat);
      expect(statAnnual.targetRoute, '/stats/annual?year=2026&bookId=2');
    });

    test('parses newbill and addbill?showsheet=1 as editor prefill routes', () {
      final newBill = parseUrlScheme(
        'tallyisle://newbill?type=1&money=128.5&asset1=3&remark=兼职稿费',
      );
      expect(newBill.writesDirectly, isFalse);
      expect(newBill.action, UrlSchemeAction.newBill);
      expect(Uri.parse(newBill.targetRoute!).queryParameters, {
        'type': '1',
        'amount': '128.50',
        'asset': '3',
        'remark': '兼职稿费',
      });

      final sheetAdd = parseUrlScheme(
        'yyjz://addbill?type=2&money=500&asset1=1&asset2=2&showsheet=true',
      );
      expect(sheetAdd.writesDirectly, isFalse);
      expect(Uri.parse(sheetAdd.targetRoute!).queryParameters, {
        'type': '2',
        'amount': '500.00',
        'from': '1',
        'to': '2',
      });
    });

    test(
      'parses direct addbill with exact BigInt money, discount, fee, tags, and datetime',
      () {
        final cmd = parseUrlScheme(
          'tallyisle://addbill?type=0&money=¥1,234.56元&discount=34.56'
          '&book=家庭账本&category=餐饮>咖啡&asset1=招商卡&remark=下午茶'
          '&datetime=20261111143000&exbudget=1&exstat=true&tags=咖啡,下午茶',
        );
        expect(cmd.writesDirectly, isTrue);
        final add = cmd.addBill!;
        expect(add.type, RecordType.expense);
        expect(add.money, Money.minor(BigInt.from(123456)));
        expect(add.discount, Money.minor(BigInt.from(3456)));
        expect(add.netMoney, Money.minor(BigInt.from(120000)));
        expect(add.bookRef, '家庭账本');
        expect(add.categoryRef, '餐饮>咖啡');
        expect(add.asset1Ref, '招商卡');
        expect(add.remark, '下午茶');
        expect(
          add.recordTimeMs,
          DateTime(2026, 11, 11, 14, 30, 0).millisecondsSinceEpoch,
        );
        expect(add.excludeBudget, isTrue);
        expect(add.excludeExIn, isTrue);
        expect(add.tagRefs, ['咖啡', '下午茶']);
      },
    );

    test(
      'parseUrlMoney enforces HALF_UP rounding, cap 88888888888.00, and rejects invalid values',
      () {
        expect(
          parseUrlMoney('18.505', fieldLabel: '金额').storageMinor,
          BigInt.from(1851),
        );
        expect(
          parseUrlMoney('88888888888.00', fieldLabel: '金额').storageMinor,
          BigInt.parse('8888888888800'),
        );
        expect(
          () => parseUrlMoney('88888888888.01', fieldLabel: '金额'),
          throwsA(isA<Failure>()),
        );
        expect(
          () => parseUrlMoney('0', fieldLabel: '金额'),
          throwsA(isA<Failure>()),
        );
        expect(
          () => parseUrlMoney('-12.00', fieldLabel: '金额', allowZero: true),
          throwsA(isA<Failure>()),
        );
      },
    );

    test(
      'rejects unsupported scheme, discount > money, transfer missing asset2, and invalid dates',
      () {
        expect(
          () => parseUrlScheme('https://tallyisle.dev/addbill?money=10'),
          throwsA(isA<Failure>()),
        );
        expect(
          () => parseUrlScheme('tallyisle://addbill?money=10&discount=10.01'),
          throwsA(isA<Failure>()),
        );
        expect(
          () =>
              parseUrlScheme('tallyisle://addbill?type=2&money=100&asset1=储蓄卡'),
          throwsA(isA<Failure>()),
        );
        expect(
          () => parseUrlDateTimeMs('2026-02-30 12:00:00'),
          throwsA(isA<Failure>()),
        );
      },
    );
  });

  group('F-020 auto_map_rules', () {
    test(
      'AutoMapInfo preserves mapAssetId/mapCategoryId and unknown passthrough keys',
      () {
        final parsed = AutoMapInfo.parse(
          '{"mapAssetId":5,"mapCategoryId":12,"legacyExtra":"keep-me"}',
        );
        expect(parsed.mapAssetId, 5);
        expect(parsed.mapCategoryId, 12);
        expect(parsed.hasAnyMapping, isTrue);

        final reencoded = AutoMapInfo.parse(
          AutoMapInfo(
            raw: parsed.raw,
            mapAssetId: 8,
            mapCategoryId: 12,
            recordType: RecordType.expense,
          ).encode(),
        );
        expect(reencoded.mapAssetId, 8);
        expect(reencoded.mapCategoryId, 12);
        expect(reencoded.recordType, RecordType.expense);
        expect(reencoded.raw['legacyExtra'], 'keep-me');
      },
    );

    test(
      'validateAutoMapRuleKey rejects reserved sentinels KEY_DRAFT and KEY_CONFIG',
      () {
        expect(
          () => validateAutoMapRuleKey('KEY_DRAFT'),
          throwsA(isA<Failure>()),
        );
        expect(
          () => validateAutoMapRuleKey('key_config'),
          throwsA(isA<Failure>()),
        );
        expect(() => validateAutoMapRuleKey('   '), throwsA(isA<Failure>()));
        expect(validateAutoMapRuleKey(' 瑞幸咖啡 '), '瑞幸咖啡');
      },
    );

    test(
      'matchAutoMapRules orders longest keyword first and merges complementary fields',
      () {
        final rules = [
          AutoMapRule(
            id: 1,
            key: '瑞幸',
            info: AutoMapInfo(mapCategoryId: 10, mapAssetId: 2),
          ),
          AutoMapRule(
            id: 2,
            key: '瑞幸咖啡生椰',
            info: AutoMapInfo(mapCategoryId: 99),
          ),
          AutoMapRule(
            id: 3,
            key: '招商银行(8888)',
            info: AutoMapInfo(mapAssetId: 7),
          ),
        ];

        final res = matchAutoMapRules(rules, ['瑞幸咖啡生椰拿铁', '支付方式：招商银行(8888)']);
        expect(res.isMatched, isTrue);
        // Longest keyword "招商银行(8888)" (len 10) -> assetId 7; "瑞幸咖啡生椰" (len 6) -> categoryId 99
        expect(res.assetId, 7);
        expect(res.categoryId, 99);
      },
    );

    test(
      'AutoBillDraft parses legacy .penny AutoBillInfo JSON losslessly without double',
      () {
        const pennyDraftJson =
            '{"bt":0,"money":36.5,"discf":2.05,"date":1762848000000,'
            '"app":"com.tencent.mm","remark":["美团外卖","工作午餐"],'
            '"a1":"招商银行(8888)","cate":"餐饮","isrefund":false,"extraPassthrough":1}';
        final draft = AutoBillDraft.parse(
          pennyDraftJson,
          id: 42,
          fallbackNowMs: 1700000000000,
        );
        expect(draft.id, 42);
        expect(draft.recordType, RecordType.expense);
        expect(draft.money.storageMinor, BigInt.from(3650));
        expect(draft.discount?.storageMinor, BigInt.from(205));
        expect(draft.netMoney.storageMinor, BigInt.from(3445));
        expect(draft.displayApp, '微信');
        expect(draft.primaryRemark, '美团外卖 · 工作午餐');
        expect(draft.accountHint1, '招商银行(8888)');
        expect(draft.categoryHint, '餐饮');

        // Scientific notation in legacy Gson float/double export
        final sciDraft = AutoBillDraft.parse(
          '{"bt":1,"money":1.25E2,"date":1762848000000,"remark":"奖金"}',
          fallbackNowMs: 1700000000000,
        );
        expect(sciDraft.money.storageMinor, BigInt.from(12500));
      },
    );

    test(
      'parsePaymentText extracts WeChat, Alipay, bank SMS, and ignores balance noise',
      () {
        const sms =
            '【招商银行】您账户8888于11月11日12:30消费人民币36.50元，余额12,345.67元，商户：星巴克咖啡。';
        final parsedSms = parsePaymentText(sms, fallbackNowMs: 1762840000000)!;
        expect(parsedSms.sourceApp, '短信');
        expect(parsedSms.recordType, RecordType.expense);
        expect(parsedSms.money.storageMinor, BigInt.from(3650));
        expect(parsedSms.accountHint1, '招商银行(8888)');
        expect(parsedSms.merchant, '星巴克咖啡');
        expect(parsedSms.categoryHint, '餐饮');

        const wechatIncome = '微信支付\n二维码收款到账 ¥88.00\n收款账户：零钱';
        final parsedIn = parsePaymentText(
          wechatIncome,
          packageOrApp: 'com.tencent.mm',
          fallbackNowMs: 1762840000000,
        )!;
        expect(parsedIn.sourceApp, '微信');
        expect(parsedIn.recordType, RecordType.income);
        expect(parsedIn.money.storageMinor, BigInt.from(8800));
        expect(parsedIn.accountHint1, '微信零钱');

        expect(
          parsePaymentText('今天天气不错，没有任何收支信息', fallbackNowMs: 1762840000000),
          isNull,
        );
      },
    );
  });

  group('F-021 ocr_bill_rules (ADR-017)', () {
    test('OcrEndpointConfig reports explicit 未配置 when empty or non-HTTP', () {
      const emptyCfg = OcrEndpointConfig();
      expect(emptyCfg.isConfigured, isFalse);
      expect(emptyCfg.statusLabel, '未配置');

      const badCfg = OcrEndpointConfig(endpointUrl: 'ftp://example.com/ocr');
      expect(badCfg.isConfigured, isFalse);
      expect(badCfg.statusLabel, '未配置');
      expect(badCfg.validated, throwsA(isA<Failure>()));

      const okCfg = OcrEndpointConfig(
        endpointUrl: 'https://ocr.example.com/v1/parse',
        apiKey: 'secret-token',
      );
      expect(okCfg.isConfigured, isTrue);
      expect(okCfg.statusLabel, '已配置');
    });

    test('extractTextFromOcrJsonResponse supports standard JSON shapes', () {
      expect(
        extractTextFromOcrJsonResponse('{"text":"瑞幸咖啡\\n-18.50"}'),
        '瑞幸咖啡\n-18.50',
      );
      expect(
        extractTextFromOcrJsonResponse(
          '{"words_result":[{"words":"11月10日 09:15"},{"words":"地铁出行 -4.00"}]}',
        ),
        '11月10日 09:15\n地铁出行 -4.00',
      );
      expect(
        () => extractTextFromOcrJsonResponse('{}'),
        throwsA(isA<Failure>()),
      );
    });

    test(
      'parseOcrBillCandidates parses multi-item ledger lists and retail receipts',
      () {
        const ledgerText = '''
2026年11月
本月支出 ¥22.50 收入 ¥300.00
11月10日 09:15
瑞幸咖啡
-18.50
交易成功
11月11日 18:20 地铁出行 -4.00
11月11日 20:00
兼职稿费收入
+300.00
''';
        final items = parseOcrBillCandidates(
          ledgerText,
          defaultYear: 2026,
          fallbackTimeMs: 1762800000000,
        );
        expect(items, hasLength(3));
        expect(items[0].merchant, '瑞幸咖啡');
        expect(items[0].type, RecordType.expense);
        expect(items[0].money.storageMinor, BigInt.from(1850));
        expect(items[0].categoryHint, '餐饮');

        expect(items[1].merchant, '地铁出行');
        expect(items[1].type, RecordType.expense);
        expect(items[1].money.storageMinor, BigInt.from(400));
        expect(items[1].categoryHint, '交通');

        expect(items[2].merchant, '兼职稿费收入');
        expect(items[2].type, RecordType.income);
        expect(items[2].money.storageMinor, BigInt.from(30000));

        const receiptText = '''
全家便利店 FamilyMart
2026-11-11 08:35
鲜奶吐司   8.50
美式咖啡  12.00
应付金额: 20.50
实付金额: ¥18.50
谢谢惠顾
''';
        final receiptItems = parseOcrBillCandidates(
          receiptText,
          defaultYear: 2026,
          fallbackTimeMs: 1762800000000,
        );
        expect(receiptItems, hasLength(1));
        expect(receiptItems.single.merchant, '全家便利店 FamilyMart');
        expect(receiptItems.single.money.storageMinor, BigInt.from(1850));
        expect(receiptItems.single.categoryHint, '购物');
      },
    );
  });
}
