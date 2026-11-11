import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart'
    show BooleanExpressionOperators, Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/automation/auto_bill_service.dart';
import 'package:tallyisle/data/automation/ocr_service.dart';
import 'package:tallyisle/data/automation/url_scheme_service.dart';
import 'package:tallyisle/data/automation/widget_snapshot_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/domain/ledger/record_extra.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/auto_map_rules.dart';
import 'package:tallyisle/domain/rules/currency_rates.dart'
    show rateToAnchorFromPrice;
import 'package:tallyisle/domain/rules/ocr_bill_rules.dart';
import 'package:tallyisle/domain/rules/url_scheme_rules.dart';
import 'package:tallyisle/platform/app_widgets.dart';
import 'package:tallyisle/platform/auto_bill_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  late LedgerService ledger;
  var seq = 0;
  String cmd() => 'auto-svc-cmd-${seq++}';

  final fixedNow = DateTime(2026, 11, 11, 14, 0, 0);

  setUp(() {
    db = AppDatabase(
      NativeDatabase.memory(),
      nowMs: () => fixedNow.millisecondsSinceEpoch,
    );
    ledger = LedgerService(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('UrlSchemeService (F-033)', () {
    test(
      'executes navigation URIs and resolves named book on annual stats',
      () async {
        final book2Id = await db
            .into(db.accountBooks)
            .insert(
              AccountBooksCompanion.insert(
                name: '旅行账本',
                createDate: fixedNow.millisecondsSinceEpoch,
              ),
            );

        final service = UrlSchemeService(db, ledgerService: ledger);
        final res = await service.executeUri(
          'tallyisle://stat?year=2026&book=旅行账本',
          commandId: cmd(),
        );
        expect(res.action, UrlSchemeAction.stat);
        expect(res.resolvedBookId, book2Id);
        expect(res.targetRoute, '/stats/annual?year=2026&bookId=$book2Id');

        final pref = await (db.select(
          db.preferences,
        )..where((t) => t.key.equals('current_book_id'))).getSingle();
        expect(pref.value, '$book2Id');
      },
    );

    test(
      'executes direct addbill with category path, asset, discount, tags, and ADR-009 idempotency',
      () async {
        final cardId = await ledger.createAsset(
          commandId: cmd(),
          name: '招商储蓄卡',
          initial: Money.minor(BigInt.from(100000)),
        );
        final foodCat =
            await (db.select(db.recordCategories)..where(
                  (t) => t.name.equals('餐饮') & t.accountBookId.equals(1),
                ))
                .getSingle();
        final coffeeCatId = await db
            .into(db.recordCategories)
            .insert(
              RecordCategoriesCompanion.insert(
                name: '咖啡',
                type: RecordType.expense,
                parentCatId: Value(foodCat.id),
                accountBookId: 1,
              ),
            );
        await db
            .into(db.tags)
            .insert(TagsCompanion.insert(tagId: 'tag-coffee', name: '提神'));

        final service = UrlSchemeService(db, ledgerService: ledger);
        const uri =
            'yyjz://addbill?type=0&money=22.00&discount=3.50'
            '&category=餐饮>咖啡&asset1=招商储蓄卡&remark=生椰拿铁&tags=提神';
        final fixedCmd = cmd();

        final r1 = await service.executeUri(uri, commandId: fixedCmd);
        expect(r1.wroteRecord, isTrue);
        expect(r1.resolvedBookId, 1);

        // Idempotent retry with identical commandId + URI
        final r2 = await service.executeUri(uri, commandId: fixedCmd);
        expect(r2.createdRecordId, r1.createdRecordId);

        // Conflicting payload with same commandId must fail
        await expectLater(
          () => service.executeUri(
            'yyjz://addbill?type=0&money=99.00',
            commandId: fixedCmd,
          ),
          throwsA(
            isA<Failure>().having((f) => f.code, 'code', FailureCode.conflict),
          ),
        );

        final record = await (db.select(
          db.records,
        )..where((t) => t.recordId.equals(r1.createdRecordId!))).getSingle();
        expect(
          record.moneyMinor,
          BigInt.from(1850),
        ); // net 22.00 - 3.50 = 18.50
        expect(record.discountMinor, BigInt.from(350));
        expect(record.recordCatId, coffeeCatId);
        expect(record.assetId, cardId);
        expect(record.remark, '生椰拿铁');

        final updatedAsset = await (db.select(
          db.assets,
        )..where((t) => t.id.equals(cardId))).getSingle();
        expect(
          updatedAsset.balanceMinor,
          BigInt.from(98150),
        ); // 1000.00 - 18.50

        final tagLinks = await (db.select(
          db.tagRecords,
        )..where((t) => t.recordId.equals(r1.createdRecordId!))).get();
        expect(tagLinks.map((t) => t.tagId).toList(), ['tag-coffee']);
      },
    );

    test(
      'executes transfer addbill with fee child and foreign-currency snapshot',
      () async {
        await db
            .into(db.currencies)
            .insert(
              CurrenciesCompanion.insert(
                code: 'USD',
                name: '美元',
                symbol: r'$',
                rateToAnchor: rateToAnchorFromPrice('7.20'),
                anchorCode: 'CNY',
              ),
            );
        final bankId = await ledger.createAsset(
          commandId: cmd(),
          name: '工商卡',
          initial: Money.minor(BigInt.from(500000)),
        );
        final walletId = await ledger.createAsset(
          commandId: cmd(),
          name: '零钱包',
          initial: Money.minor(BigInt.from(10000)),
        );
        final usdCardId = await ledger.createAsset(
          commandId: cmd(),
          name: '美元账户',
          currency: 'USD',
          initial: Money.minor(BigInt.from(20000), 'USD'),
        );

        final service = UrlSchemeService(db, ledgerService: ledger);
        final trRes = await service.executeUri(
          'tallyisle://addbill?type=2&money=1000.00&fee=1.50&asset1=工商卡&asset2=零钱包&remark=提现充值',
          commandId: cmd(),
        );
        expect(trRes.wroteRecord, isTrue);

        final bank = await (db.select(
          db.assets,
        )..where((t) => t.id.equals(bankId))).getSingle();
        final wallet = await (db.select(
          db.assets,
        )..where((t) => t.id.equals(walletId))).getSingle();
        expect(bank.balanceMinor, BigInt.from(399850)); // 5000 - 1000 - 1.50
        expect(wallet.balanceMinor, BigInt.from(110000)); // 100 + 1000

        // Foreign currency expense writes CurrencySnapshot
        final fxRes = await service.executeUri(
          'tallyisle://addbill?type=0&money=10.00&category=购物&asset1=美元账户&remark=订阅软件',
          commandId: cmd(),
        );
        final fxRow = await (db.select(
          db.records,
        )..where((t) => t.recordId.equals(fxRes.createdRecordId!))).getSingle();
        final snap = RecordExtra.parse(fxRow.extraInfo).currency;
        expect(snap, isNotNull);
        expect(snap!.assetCode, 'USD');
        expect(snap.baseCode, 'CNY');
        expect(
          snap.baseAmount,
          BigInt.from(7200),
        ); // 10.00 USD * 7.20 = 72.00 CNY

        final usdAfter = await (db.select(
          db.assets,
        )..where((t) => t.id.equals(usdCardId))).getSingle();
        expect(usdAfter.balanceMinor, BigInt.from(19000));

        // Unknown explicit category or asset fails cleanly
        await expectLater(
          () => service.executeUri(
            'tallyisle://addbill?type=0&money=12.00&category=不存在的分类',
            commandId: cmd(),
          ),
          throwsA(isA<Failure>()),
        );
      },
    );
  });

  group('WidgetSnapshotService & AppWidgetBridge (F-034)', () {
    test(
      'computes exact BigInt period/today/budget snapshot and wires MethodChannel',
      () async {
        final foodCat =
            await (db.select(db.recordCategories)..where(
                  (t) => t.name.equals('餐饮') & t.accountBookId.equals(1),
                ))
                .getSingle();
        final salaryCat =
            await (db.select(db.recordCategories)..where(
                  (t) => t.name.equals('工资') & t.accountBookId.equals(1),
                ))
                .getSingle();

        // Yesterday expense: 120.00
        await ledger.saveRecord(
          commandId: cmd(),
          draft: RecordDraft(
            type: RecordType.expense,
            money: Money.minor(BigInt.from(12000)),
            bookId: 1,
            recordTime: DateTime(2026, 11, 10, 12, 0).millisecondsSinceEpoch,
            categoryId: foodCat.id,
            remark: '聚餐',
          ),
        );
        // Today expense: 35.50
        await ledger.saveRecord(
          commandId: cmd(),
          draft: RecordDraft(
            type: RecordType.expense,
            money: Money.minor(BigInt.from(3550)),
            bookId: 1,
            recordTime: DateTime(2026, 11, 11, 9, 30).millisecondsSinceEpoch,
            categoryId: foodCat.id,
            remark: '早餐',
          ),
        );
        // Period income: 5000.00
        await ledger.saveRecord(
          commandId: cmd(),
          draft: RecordDraft(
            type: RecordType.income,
            money: Money.minor(BigInt.from(500000)),
            bookId: 1,
            recordTime: DateTime(2026, 11, 5, 10, 0).millisecondsSinceEpoch,
            categoryId: salaryCat.id,
            remark: '薪资',
          ),
        );
        // Monthly total budget: 2000.00 for section "2026-11"
        await db
            .into(db.budgets)
            .insert(
              BudgetsCompanion.insert(
                id: const Value(1),
                budgetType: 0,
                recordCatId: noRef,
                amountMinor: BigInt.from(200000),
                bookId: 1,
                section: '2026-11',
                createDate: fixedNow.millisecondsSinceEpoch,
              ),
            );

        Map<Object?, Object?>? capturedWirePayload;
        const testChannel = MethodChannel('dev.tallyisle/test_widgets');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(testChannel, (call) async {
              if (call.method == 'updateWidgetSnapshot') {
                capturedWirePayload = call.arguments as Map<Object?, Object?>;
                return {'quick_add': 1, 'month_summary': 2, 'month_bar': 1};
              }
              if (call.method == 'requestPinWidget') {
                return true;
              }
              return null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(testChannel, null),
        );

        final bridge = MethodChannelAppWidgetBridge(channel: testChannel);
        final widgetService = WidgetSnapshotService(db, bridge: bridge);
        final (snapshot, counts) = await widgetService.syncToPlatform(
          now: fixedNow,
        );

        expect(snapshot.bookName, '日常账本');
        expect(snapshot.periodLabel, '2026年11月');
        expect(snapshot.expenseMinor, BigInt.from(15550)); // 155.50
        expect(snapshot.incomeMinor, BigInt.from(500000)); // 5000.00
        expect(snapshot.balanceMinor, BigInt.from(484450)); // 4844.50
        expect(snapshot.todayExpenseMinor, BigInt.from(3550)); // 35.50
        expect(
          snapshot.budgetRemainingMinor,
          BigInt.from(184450),
        ); // 2000 - 155.50 = 1844.50
        expect(counts[DesktopWidgetKind.monthSummary], 2);

        expect(capturedWirePayload?['expenseMinor'], '15550');
        expect(capturedWirePayload?['expenseFormatted'], '155.50');
        expect(capturedWirePayload?['budgetRemainingFormatted'], '1844.50');
      },
    );
  });

  group('AutoBillService & .penny auto_map compatibility (F-020)', () {
    test(
      'reports honest accessibility status and ingests/confirms .penny rules & drafts into LedgerService',
      () async {
        final bankAssetId = await ledger.createAsset(
          commandId: cmd(),
          name: '招商储蓄卡',
          initial: Money.minor(BigInt.from(200000)),
        );
        final shopCat =
            await (db.select(db.recordCategories)..where(
                  (t) => t.name.equals('购物') & t.accountBookId.equals(1),
                ))
                .getSingle();

        final bridge = InMemoryAutoBillBridge(
          status: const AccessibilityBridgeStatus.android(enabled: false),
        );
        final service = AutoBillService(
          db,
          ledgerService: ledger,
          bridge: bridge,
        );
        addTearDown(bridge.dispose);

        expect((await service.getAccessibilityStatus()).statusLabel, '未开启');
        bridge.status = const AccessibilityBridgeStatus.android(enabled: true);
        expect((await service.getAccessibilityStatus()).statusLabel, '已开启');

        // Seed a raw .penny imported rule row and a raw .penny KEY_DRAFT row
        await db
            .into(db.autoMaps)
            .insert(
              AutoMapsCompanion.insert(
                key: '山姆会员商店',
                mapInfo: Value(
                  jsonEncode({
                    'mapAssetId': bankAssetId,
                    'mapCategoryId': shopCat.id,
                  }),
                ),
              ),
            );
        final pennyDraftId = await db
            .into(db.autoMaps)
            .insert(
              AutoMapsCompanion.insert(
                key: autoMapDraftKey,
                draft: const Value(
                  '{"bt":0,"money":128.8,"discf":8.8,"date":1762840000000,'
                  '"app":"com.tencent.mm","remark":["山姆会员商店","生鲜采购"],'
                  '"a1":"微信","cate":"购物","isrefund":false}',
                ),
              ),
            );

        final rules = await service.listRules();
        expect(rules, hasLength(1));
        expect(rules.single.key, '山姆会员商店');
        expect(rules.single.info.mapAssetId, bankAssetId);
        expect(rules.single.info.mapCategoryId, shopCat.id);

        final draftsBefore = await service.listDrafts();
        expect(draftsBefore, hasLength(1));
        expect(draftsBefore.single.money.storageMinor, BigInt.from(12880));
        expect(draftsBefore.single.discount?.storageMinor, BigInt.from(880));

        final confirmCmd = cmd();
        final recordId = await service.confirmDraft(
          commandId: confirmCmd,
          draftId: pennyDraftId,
          learnRule: true,
          ruleKeyword: '山姆生鲜',
        );
        // Idempotent retry returns identical recordId without error
        expect(
          await service.confirmDraft(
            commandId: confirmCmd,
            draftId: pennyDraftId,
            learnRule: true,
            ruleKeyword: '山姆生鲜',
          ),
          recordId,
        );

        // KEY_DRAFT is deleted, learned rule is added, and record + asset balance are updated
        expect(await service.listDrafts(), isEmpty);
        expect((await service.listRules()).map((r) => r.key), contains('山姆生鲜'));

        final savedRecord = await (db.select(
          db.records,
        )..where((t) => t.recordId.equals(recordId))).getSingle();
        expect(
          savedRecord.moneyMinor,
          BigInt.from(12000),
        ); // 128.80 - 8.80 = 120.00
        expect(savedRecord.discountMinor, BigInt.from(880));
        expect(savedRecord.assetId, bankAssetId);
        expect(savedRecord.recordCatId, shopCat.id);

        final assetAfter = await (db.select(
          db.assets,
        )..where((t) => t.id.equals(bankAssetId))).getSingle();
        expect(
          assetAfter.balanceMinor,
          BigInt.from(188000),
        ); // 2000 - 120 = 1880
      },
    );

    test(
      'deduplicates repeated captured payment notifications within time bucket',
      () async {
        final bridge = InMemoryAutoBillBridge(
          initialCapturedEvents: [
            const CapturedPaymentEvent(
              packageName: 'com.eg.android.AlipayGphone',
              rawText: '支付宝通知：付款 ¥15.00，商户：麦当劳',
              capturedAtMs: 1762845001000,
            ),
            const CapturedPaymentEvent(
              packageName: 'com.eg.android.AlipayGphone',
              rawText: '支付宝通知：付款 ¥15.00，商户：麦当劳',
              capturedAtMs: 1762845003000,
            ),
            const CapturedPaymentEvent(
              packageName: 'com.eg.android.AlipayGphone',
              rawText: '无金额普通系统提示',
              capturedAtMs: 1762845004000,
            ),
          ],
        );
        final service = AutoBillService(
          db,
          ledgerService: ledger,
          bridge: bridge,
        );
        addTearDown(bridge.dispose);

        await service.ingestCapturedEvents();
        final drafts = await service.listDrafts();
        expect(drafts, hasLength(1));
        expect(drafts.single.money.storageMinor, BigInt.from(1500));
      },
    );
  });

  group('OcrService & Pluggable OcrProvider (F-021, ADR-017)', () {
    test(
      'defaults to explicit 未配置 and refuses fake image OCR until configured',
      () async {
        final ocr = OcrService(db, ledgerService: ledger);
        final initialProvider = await ocr.getProvider();
        expect(initialProvider.isConfigured, isFalse);
        expect(initialProvider.statusLabel, '未配置');

        await expectLater(
          () => ocr.recognizeImageToCandidates(Uint8List.fromList([1, 2, 3])),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.unsupportedCapability,
            ),
          ),
        );
      },
    );

    test(
      'ConfigurableHttpOcrProvider posts to real loopback HTTP server and confirms batch atomically',
      () async {
        final previousOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() => HttpOverrides.global = previousOverrides);

        String? receivedAuth;
        Map<String, Object?>? receivedJson;

        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((HttpRequest req) async {
          receivedAuth = req.headers.value(HttpHeaders.authorizationHeader);
          final body = await utf8.decoder.bind(req).join();
          receivedJson = (jsonDecode(body) as Map).cast<String, Object?>();
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode({
                'lines': [
                  '2026年11月',
                  '11月10日 09:00',
                  '瑞幸咖啡',
                  '-18.50',
                  '11月11日 19:00',
                  '滴滴打车',
                  '-32.00',
                ],
              }),
            );
          await req.response.close();
        });

        final cardId = await ledger.createAsset(
          commandId: cmd(),
          name: '交通卡',
          initial: Money.minor(BigInt.from(50000)),
        );

        final ocr = OcrService(db, ledgerService: ledger);
        await ocr.saveConfig(
          commandId: cmd(),
          config: OcrEndpointConfig(
            endpointUrl: 'http://127.0.0.1:${server.port}/v1/ocr',
            apiKey: 'test-key-123',
          ),
        );

        final activeProvider = await ocr.getProvider();
        expect(activeProvider.isConfigured, isTrue);
        expect(activeProvider.statusLabel, '已配置');

        final sampleBytes = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]);
        final (_, candidates) = await ocr.recognizeImageToCandidates(
          sampleBytes,
          fileName: 'wechat_bills.png',
          now: fixedNow,
        );
        expect(receivedAuth, 'Bearer test-key-123');
        expect(receivedJson?['image_base64'], base64Encode(sampleBytes));
        expect(receivedJson?['file_name'], 'wechat_bills.png');
        expect(candidates, hasLength(2));
        expect(candidates[0].money.storageMinor, BigInt.from(1850));
        expect(candidates[1].money.storageMinor, BigInt.from(3200));

        // Atomic rollback check: if second candidate has invalid assetId, 0 records are written
        await expectLater(
          () => ocr.confirmCandidates(
            commandId: cmd(),
            candidates: [
              candidates[0],
              candidates[1].copyWith(assetId: 999999),
            ],
          ),
          throwsA(isA<Failure>()),
        );
        expect(await db.select(db.records).get(), isEmpty);

        // Valid batch confirm writes both records and updates defaultAssetId balance
        final batchCmd = cmd();
        final ids = await ocr.confirmCandidates(
          commandId: batchCmd,
          candidates: candidates,
          defaultAssetId: cardId,
        );
        expect(ids, hasLength(2));
        // Idempotent retry
        expect(
          await ocr.confirmCandidates(
            commandId: batchCmd,
            candidates: candidates,
            defaultAssetId: cardId,
          ),
          ids,
        );

        final cardAfter = await (db.select(
          db.assets,
        )..where((t) => t.id.equals(cardId))).getSingle();
        expect(
          cardAfter.balanceMinor,
          BigInt.from(44950),
        ); // 500.00 - 18.50 - 32.00 = 449.50
      },
    );
  });
}
