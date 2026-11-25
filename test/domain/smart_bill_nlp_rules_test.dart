import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/smart_bill_nlp_rules.dart';

void main() {
  // 2026-11-11 14:00 local.
  final now = DateTime(2026, 11, 11, 14, 0);
  final nowMs = now.millisecondsSinceEpoch;
  BigInt minor(SmartBillParseResult? r) => r!.money.storageMinor;

  group('parseChineseInteger', () {
    test('standard and colloquial numerals', () {
      expect(parseChineseInteger('三十二'), BigInt.from(32));
      expect(parseChineseInteger('十五'), BigInt.from(15));
      expect(parseChineseInteger('一百零五'), BigInt.from(105));
      expect(parseChineseInteger('两千五'), BigInt.from(2500));
      expect(parseChineseInteger('三万五'), BigInt.from(35000));
      expect(parseChineseInteger('二十万'), BigInt.from(200000));
      expect(parseChineseInteger('一千二百三'), BigInt.from(1230));
      expect(parseChineseInteger('三四'), isNull);
      expect(parseChineseInteger('abc'), isNull);
    });
  });

  group('parseNaturalLanguageBill amounts (exact Money, zero double)', () {
    test('arabic, 块/毛 colloquial and chinese numerals', () {
      expect(
        minor(parseNaturalLanguageBill('午饭18.5', nowMs: nowMs)),
        BigInt.from(1850),
      );
      expect(
        minor(parseNaturalLanguageBill('奶茶18块5', nowMs: nowMs)),
        BigInt.from(1850),
      );
      expect(
        minor(parseNaturalLanguageBill('矿泉水9毛5', nowMs: nowMs)),
        BigInt.from(95),
      );
      expect(
        minor(parseNaturalLanguageBill('打车三十二块八', nowMs: nowMs)),
        BigInt.from(3280),
      );
      expect(
        minor(parseNaturalLanguageBill('收到工资8,500元', nowMs: nowMs)),
        BigInt.from(850000),
      );
      expect(
        minor(parseNaturalLanguageBill('超市 ¥ 66.66', nowMs: nowMs)),
        BigInt.from(6666),
      );
      expect(
        minor(parseNaturalLanguageBill('房租两千五百块', nowMs: nowMs)),
        BigInt.from(250000),
      );
    });

    test('ignores time/card digits and rejects text without amount', () {
      final r = parseNaturalLanguageBill('昨晚9点半吃火锅花了128', nowMs: nowMs)!;
      expect(r.money.storageMinor, BigInt.from(12800));
      final card = parseNaturalLanguageBill('尾号1234消费 买菜 35', nowMs: nowMs)!;
      expect(card.money.storageMinor, BigInt.from(3500));
      expect(parseNaturalLanguageBill('今天天气不错', nowMs: nowMs), isNull);
      expect(parseNaturalLanguageBill('', nowMs: nowMs), isNull);
    });
  });

  group('parseNaturalLanguageBill semantics', () {
    test('spec vector: 昨天早饭买煎饼微信花了9块5', () {
      final r = parseNaturalLanguageBill(
        '昨天早饭买煎饼微信花了9块5',
        nowMs: nowMs,
        categoryNames: const ['餐饮', '交通'],
        assetNames: const ['微信钱包', '招商银行储蓄卡'],
      )!;
      expect(r.recordType, RecordType.expense);
      expect(r.money, Money.minor(BigInt.from(950)));
      expect(
        r.recordTimeMs,
        DateTime(2026, 11, 10, 8, 0).millisecondsSinceEpoch,
      );
      expect(r.hasExplicitTime, isTrue);
      expect(r.assetHint, '微信钱包');
      expect(r.categoryHint, '餐饮');
      expect(r.remark, '买煎饼');
      expect(r.confidence, SmartBillConfidence.high);
    });

    test('早饭包子8.5微信 keeps now time and extracts remark', () {
      final r = parseNaturalLanguageBill(
        '早饭包子8.5微信',
        nowMs: nowMs,
        assetNames: const ['微信'],
      )!;
      expect(r.money.storageMinor, BigInt.from(850));
      expect(r.recordTimeMs, nowMs);
      expect(r.hasExplicitTime, isFalse);
      expect(r.assetHint, '微信');
      expect(r.categoryHint, '餐饮');
      expect(r.remark, '包子');
    });

    test('relative time words', () {
      int at(String text) =>
          parseNaturalLanguageBill(text, nowMs: nowMs)!.recordTimeMs;
      expect(at('今早8点豆浆5元'), DateTime(2026, 11, 11, 8).millisecondsSinceEpoch);
      expect(
        at('昨晚9点半烧烤88元'),
        DateTime(2026, 11, 10, 21, 30).millisecondsSinceEpoch,
      );
      expect(
        at('前天下午3点电影票45元'),
        DateTime(2026, 11, 9, 15).millisecondsSinceEpoch,
      );
      expect(at('今天买菜30元'), DateTime(2026, 11, 11, 14).millisecondsSinceEpoch);
      expect(
        at('11月3日 加油300元'),
        DateTime(2026, 11, 3, 14).millisecondsSinceEpoch,
      );
    });

    test('direction: income, refund and transfer with from/to assets', () {
      final income = parseNaturalLanguageBill(
        '收到工资8500元',
        nowMs: nowMs,
        categoryNames: const ['工资', '奖金'],
      )!;
      expect(income.recordType, RecordType.income);
      expect(income.categoryHint, '工资');

      final refund = parseNaturalLanguageBill('淘宝退回23.5', nowMs: nowMs)!;
      expect(refund.recordType, RecordType.income);

      final transfer = parseNaturalLanguageBill(
        '从招行转到余额宝500元',
        nowMs: nowMs,
        assetNames: const ['招商银行储蓄卡', '余额宝'],
      )!;
      expect(transfer.recordType, RecordType.transfer);
      expect(transfer.assetHint, '招商银行储蓄卡');
      expect(transfer.toAssetHint, '余额宝');
      expect(transfer.money.storageMinor, BigInt.from(50000));
    });

    test('bank colloquial alias maps onto real asset name', () {
      final r = parseNaturalLanguageBill(
        '招行卡刷了加油费300',
        nowMs: nowMs,
        assetNames: const ['招商银行信用卡', '现金'],
      )!;
      expect(r.assetHint, '招商银行信用卡');
      expect(r.categoryHint, '交通');
      expect(r.remark, '加油费');
    });
  });

  group('AutoBillSettings & AiBillParserConfig codecs', () {
    test('settings defaults and roundtrip', () {
      const defaults = AutoBillSettings();
      expect(defaults.enableNotificationCapture, isTrue);
      expect(defaults.enableAccessibilityCapture, isTrue);
      expect(defaults.promptMode, AutoBillPromptMode.notification);
      expect(defaults.autoConfirmMatchedRules, isFalse);
      expect(defaults.showHomeDraftBanner, isTrue);
      expect(AutoBillSettings.parse(null), defaults);
      expect(AutoBillSettings.parse('not json'), defaults);

      final custom = defaults.copyWith(
        promptMode: AutoBillPromptMode.overlay,
        autoConfirmMatchedRules: true,
        enableAccessibilityCapture: false,
      );
      expect(AutoBillSettings.parse(custom.encode()), custom);
      expect(custom.encode(), contains('"androidPromptMode":"overlay"'));
    });

    test('AI config validation and chat completions URI', () {
      const off = AiBillParserConfig();
      expect(off.isConfigured, isFalse);
      expect(off.fallbackOnly, isTrue);
      const on = AiBillParserConfig(
        enabled: true,
        baseUrl: 'https://api.deepseek.com/v1/',
        apiKey: 'k',
        model: 'deepseek-chat',
      );
      expect(on.isConfigured, isTrue);
      expect(
        on.chatCompletionsUri.toString(),
        'https://api.deepseek.com/v1/chat/completions',
      );
      expect(AiBillParserConfig.parse(on.encode()), on.validated());
      expect(
        () => const AiBillParserConfig(enabled: true, model: 'x').validated(),
        throwsA(isA<Failure>()),
      );
      expect(
        () => const AiBillParserConfig(baseUrl: 'ftp://x').validated(),
        throwsA(isA<Failure>()),
      );
    });

    test('AI JSON response: exact amounts, fences, invalid items skipped', () {
      const reply = '''```json
{"bills":[
  {"type":"expense","amount":18.50,"time":"2026-11-10 09:15","category":"餐饮","account":"微信","remark":"瑞幸咖啡"},
  {"type":"income","amount":"8,500.00","remark":"工资"},
  {"type":"expense","amount":"-0"},
  {"type":"expense","amount":"abc"}
]}
```''';
      final bills = parseAiBillJsonResponse(reply, nowMs: nowMs);
      expect(bills, hasLength(2));
      expect(bills[0].money, Money.minor(BigInt.from(1850)));
      expect(bills[0].recordType, RecordType.expense);
      expect(
        bills[0].recordTimeMs,
        DateTime(2026, 11, 10, 9, 15).millisecondsSinceEpoch,
      );
      expect(bills[0].assetHint, '微信');
      expect(bills[0].categoryHint, '餐饮');
      expect(bills[0].source, 'ai');
      expect(bills[1].recordType, RecordType.income);
      expect(bills[1].money.storageMinor, BigInt.from(850000));
      expect(bills[1].recordTimeMs, nowMs);

      // 0.1 + 0.2 style float literals stay exact (no double round-trip).
      final exact = parseAiBillJsonResponse(
        '{"amount":0.30,"type":"expense"}',
        nowMs: nowMs,
      );
      expect(exact.single.money.storageMinor, BigInt.from(30));

      expect(
        () => parseAiBillJsonResponse('{"bills":[]}', nowMs: nowMs),
        throwsA(isA<Failure>()),
      );
      expect(
        () => parseAiBillJsonResponse('no json here', nowMs: nowMs),
        throwsA(isA<Failure>()),
      );
      expect(
        () => parseAiBillJsonResponse(
          '{"amount":"88888888888.01"}',
          nowMs: nowMs,
        ),
        throwsA(isA<Failure>()),
      );
    });

    test('buildAiBillParserMessages embeds pick lists', () {
      final msgs = buildAiBillParserMessages(
        '早饭8元',
        nowMs: nowMs,
        categoryNames: const ['餐饮'],
        assetNames: const ['微信'],
      );
      expect(msgs, hasLength(2));
      expect(msgs.first['role'], 'system');
      expect(msgs.first['content'], contains('餐饮'));
      expect(msgs.first['content'], contains('2026-11-11 14:00'));
      expect(msgs.last['content'], '早饭8元');
    });
  });
}
