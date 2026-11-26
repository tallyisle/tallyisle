import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart'
    show BooleanExpressionOperators, Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
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
import 'package:tallyisle/domain/rules/smart_bill_nlp_rules.dart';
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
            'tallyisle://addbill?type=0&money=22.00&discount=3.50'
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
            'tallyisle://addbill?type=0&money=99.00',
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

        // Legacy yyjz:// scheme is rejected cleanly
        await expectLater(
          () => service.executeUri('yyjz://home', commandId: cmd()),
          throwsA(
            isA<Failure>()
                .having((f) => f.code, 'code', FailureCode.validation)
                .having(
                  (f) => f.message,
                  'message',
                  contains('仅支持 tallyisle://'),
                ),
          ),
        );
        await expectLater(
          () => service.executeUri(
            'yyjz://addbill?type=0&money=22.00',
            commandId: cmd(),
          ),
          throwsA(
            isA<Failure>()
                .having((f) => f.code, 'code', FailureCode.validation)
                .having(
                  (f) => f.message,
                  'message',
                  contains('仅支持 tallyisle://'),
                ),
          ),
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
        const testChannel = MethodChannel('com.tallyisle/test_widgets');
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

  group('Smart auto-bookkeeping: tiered ingest, undo, batch, prompts', () {
    late int walletId;
    late int foodCatId;
    late int shopCatId;
    late InMemoryAutoBillBridge bridge;
    late AutoBillService service;
    var changes = 0;

    Future<BigInt> balanceOf(int id) async => (await (db.select(
      db.assets,
    )..where((t) => t.id.equals(id))).getSingle()).balanceMinor;

    setUp(() async {
      changes = 0;
      walletId = await ledger.createAsset(
        commandId: cmd(),
        name: '微信钱包',
        initial: Money.minor(BigInt.from(50000)),
      );
      foodCatId =
          (await (db.select(db.recordCategories)..where(
                    (t) => t.name.equals('餐饮') & t.accountBookId.equals(1),
                  ))
                  .getSingle())
              .id;
      shopCatId =
          (await (db.select(db.recordCategories)..where(
                    (t) => t.name.equals('购物') & t.accountBookId.equals(1),
                  ))
                  .getSingle())
              .id;
      bridge = InMemoryAutoBillBridge(
        status: const AccessibilityBridgeStatus.android(enabled: true),
        notificationListenerStatus:
            const AutoBillPermissionStatus.notificationListener(enabled: true),
        overlayStatus: const AutoBillPermissionStatus.overlay(granted: false),
      );
      service = AutoBillService(
        db,
        ledgerService: ledger,
        bridge: bridge,
        afterChange: () async => changes++,
      );
      await service.saveRule(
        commandId: cmd(),
        key: '瑞幸',
        info: AutoMapInfo(mapCategoryId: foodCatId, mapAssetId: walletId),
      );
      await service.saveRule(
        commandId: cmd(),
        key: '全家',
        info: AutoMapInfo(mapCategoryId: shopCatId),
      );
      await service.saveRule(
        commandId: cmd(),
        key: '星巴克',
        info: AutoMapInfo(
          mapCategoryId: foodCatId,
          mapAssetId: walletId,
          allowAutoConfirm: false,
        ),
      );
    });

    tearDown(() => bridge.dispose());

    test(
      'drafts by default, auto-confirms only when gate passes, dedupes cross-channel, undo restores draft',
      () async {
        expect(await service.getSettings(), const AutoBillSettings());
        expect(
          (await service.getNotificationListenerStatus()).statusLabel,
          '已开启',
        );
        expect((await service.getOverlayPermissionStatus()).statusLabel, '未授权');

        // 1. Global auto-confirm OFF → draft + notification prompt.
        final first = await service.ingestPaymentTextWithOutcome(
          commandId: cmd(),
          rawText: '微信支付\n瑞幸咖啡\n-¥18.50',
          packageName: 'com.tencent.mm',
          capturedAtMs: 1762845000000,
          channel: 'notification',
        );
        expect(first.kind, AutoBillIngestKind.draftQueued);
        expect(first.categoryId, foodCatId);
        expect(first.assetId, walletId);
        expect(bridge.prompts.single.promptKind, 'draft');
        expect(bridge.prompts.single.promptMode, 'notification');
        expect(bridge.prompts.single.amountFormatted, '18.50');
        expect(bridge.prompts.single.categoryName, '餐饮');
        expect(bridge.prompts.single.assetName, '微信钱包');
        expect(bridge.prompts.single.toMap()['draftId'], first.draftId);
        expect(changes, 1);

        // 2. Enable 熟店自动入账 + overlay; native receives pick lists.
        await service.saveSettings(
          commandId: cmd(),
          settings: const AutoBillSettings(
            autoConfirmMatchedRules: true,
            promptMode: AutoBillPromptMode.overlay,
          ),
        );
        expect((await service.getSettings()).autoConfirmMatchedRules, isTrue);
        final synced = bridge.lastSyncedConfig!.toMap();
        expect(synced['promptMode'], 'overlay');
        expect(synced['enableNotificationCapture'], isTrue);
        final cats = synced['categories']! as List;
        expect(
          (cats.first as Map).keys,
          containsAll(<String>['id', 'name', 'type', 'parentId']),
        );
        expect(
          synced['assets'],
          anyElement(equals({'id': walletId, 'name': '微信钱包'})),
        );

        // 3. Rule category + account resolved → booked directly.
        final auto = await service.ingestPaymentTextWithOutcome(
          commandId: cmd(),
          rawText: '微信支付\n瑞幸咖啡\n-¥25.00',
          packageName: 'com.tencent.mm',
          capturedAtMs: 1762846000000,
          channel: 'notification',
        );
        expect(auto.kind, AutoBillIngestKind.autoConfirmed);
        final rec = await (db.select(
          db.records,
        )..where((t) => t.recordId.equals(auto.recordId!))).getSingle();
        expect(rec.moneyMinor, BigInt.from(2500));
        expect(rec.recordCatId, foodCatId);
        expect(rec.assetId, walletId);
        expect(await balanceOf(walletId), BigInt.from(47500));
        expect(bridge.prompts.last.promptKind, 'auto_confirmed');
        expect(bridge.prompts.last.recordId, auto.recordId);
        expect(bridge.prompts.last.promptMode, 'overlay');

        // 4. Accessibility twin 3 s later (different wording) → merged.
        final twin = await service.ingestPaymentTextWithOutcome(
          commandId: cmd(),
          rawText: '付款成功 瑞幸咖啡(中关村店) 付款金额 25.00元',
          packageName: 'com.tencent.mm',
          capturedAtMs: 1762846003000,
          channel: 'accessibility',
        );
        expect(twin.kind, AutoBillIngestKind.duplicate);
        expect(twin.recordId, auto.recordId);
        // Same-channel re-delivery of identical text → merged.
        final again = await service.ingestPaymentTextWithOutcome(
          commandId: cmd(),
          rawText: '微信支付\n瑞幸咖啡\n-¥25.00',
          packageName: 'com.tencent.mm',
          capturedAtMs: 1762846001000,
          channel: 'notification',
        );
        expect(again.kind, AutoBillIngestKind.duplicate);
        expect(await db.select(db.records).get(), hasLength(1));

        // 5. Rule without account / rule switched off → draft (gate refuses).
        final noAccount = await service.ingestPaymentTextWithOutcome(
          commandId: cmd(),
          rawText: '支付宝 付款 ¥12.00 商户：全家便利店',
          packageName: 'com.eg.android.AlipayGphone',
          capturedAtMs: 1762847000000,
        );
        expect(noAccount.kind, AutoBillIngestKind.draftQueued);
        final ruleOff = await service.ingestPaymentTextWithOutcome(
          commandId: cmd(),
          rawText: '微信支付\n星巴克\n-¥36.00',
          packageName: 'com.tencent.mm',
          capturedAtMs: 1762848000000,
        );
        expect(ruleOff.kind, AutoBillIngestKind.draftQueued);

        // Compat wrapper never auto-confirms.
        final compatId = await service.ingestPaymentText(
          commandId: cmd(),
          rawText: '微信支付\n瑞幸咖啡\n-¥9.90',
          packageName: 'com.tencent.mm',
          capturedAtMs: 1762849000000,
        );
        expect(compatId, isNotNull);
        expect(await db.select(db.records).get(), hasLength(1));

        // 6. Undo auto-confirmed bill → record deleted, balance restored,
        // draft restored; idempotent.
        final undoCmd = cmd();
        final restoredId = await service.undoAutoConfirmedRecord(
          commandId: undoCmd,
          recordId: auto.recordId!,
        );
        expect(
          await service.undoAutoConfirmedRecord(
            commandId: undoCmd,
            recordId: auto.recordId!,
          ),
          restoredId,
        );
        expect(
          await service.undoAutoConfirmedRecord(
            commandId: cmd(),
            recordId: auto.recordId!,
          ),
          restoredId,
        );
        expect(await db.select(db.records).get(), isEmpty);
        expect(await balanceOf(walletId), BigInt.from(50000));
        final restored = (await service.listDrafts()).firstWhere(
          (d) => d.id == restoredId,
        );
        expect(restored.money.storageMinor, BigInt.from(2500));
        expect(restored.categoryId, foodCatId);
        expect(restored.assetId, walletId);
        expect(restored.sourceApp, '微信');
        await expectLater(
          service.undoAutoConfirmedRecord(
            commandId: cmd(),
            recordId: 'missing-record',
          ),
          throwsA(isA<Failure>()),
        );

        // 7. Prompt actions: confirm with overrides, ignore, edit routes.
        final confirmRes = await service.executePromptAction(
          AutoBillPromptActionEvent(
            action: AutoBillPromptActionKind.confirmDraft,
            draftId: first.draftId,
            remark: '生椰拿铁',
            actionAtMs: 1,
          ),
        );
        final confirmed = await (db.select(
          db.records,
        )..where((t) => t.recordId.equals(confirmRes.recordId!))).getSingle();
        expect(confirmed.remark, '生椰拿铁');
        expect(await balanceOf(walletId), BigInt.from(48150));

        bridge.simulatePromptAction(
          AutoBillPromptActionEvent(
            action: AutoBillPromptActionKind.ignoreDraft,
            draftId: ruleOff.draftId,
            actionAtMs: 2,
          ),
        );
        final queued = await service.consumeAndExecutePendingPromptActions();
        expect(queued.single.succeeded, isTrue);
        expect(
          (await service.listDrafts()).map((d) => d.id),
          isNot(contains(ruleOff.draftId)),
        );
        final edit = await service.executePromptAction(
          AutoBillPromptActionEvent(
            action: AutoBillPromptActionKind.editDraft,
            draftId: noAccount.draftId,
            actionAtMs: 3,
          ),
        );
        expect(
          edit.targetRoute,
          '/automation/auto-bill?draftId=${noAccount.draftId}',
        );
        final editRec = await service.executePromptAction(
          const AutoBillPromptActionEvent(
            action: AutoBillPromptActionKind.editRecord,
            recordId: 'abc',
            actionAtMs: 4,
          ),
        );
        expect(editRec.targetRoute, '/record/abc');

        // 8. Batch confirm is atomic.
        final before = (await db.select(db.records).get()).length;
        await expectLater(
          service.confirmDraftsBatch(
            commandId: cmd(),
            draftIds: [restoredId, 999999],
          ),
          throwsA(isA<Failure>()),
        );
        expect(await db.select(db.records).get(), hasLength(before));
        final remaining = (await service.listDrafts())
            .map((d) => d.id!)
            .toList();
        final batchIds = await service.confirmDraftsBatch(
          commandId: cmd(),
          draftIds: remaining,
        );
        expect(batchIds, hasLength(remaining.length));
        expect(await service.listDrafts(), isEmpty);
      },
    );

    test(
      'capture channel switches, NLP fallback and optional AI fallback',
      () async {
        await service.saveSettings(
          commandId: cmd(),
          settings: const AutoBillSettings(enableAccessibilityCapture: false),
        );
        bridge.simulateCapturedEvent(
          const CapturedPaymentEvent(
            packageName: 'com.tencent.mm',
            rawText: '微信支付 付款 ¥8.00 商户：便利店',
            capturedAtMs: 1762845000000,
            channel: 'accessibility',
          ),
        );
        bridge.simulateCapturedEvent(
          const CapturedPaymentEvent(
            packageName: 'com.tencent.mm',
            rawText: '群聊：明天一起吃饭吧 2个人',
            capturedAtMs: 1762845001000,
            channel: 'notification',
          ),
        );
        final outcomes = await service.ingestCapturedEventsWithOutcomes();
        expect(outcomes.map((o) => o.kind), [
          AutoBillIngestKind.skipped,
          AutoBillIngestKind.skipped,
        ]);
        expect(await service.listDrafts(), isEmpty);

        // Colloquial text (user-supplied) falls back to the NLP parser.
        final nlp = await service.ingestSmartText(
          commandId: cmd(),
          text: '昨天早饭买煎饼微信钱包花了9块5',
        );
        expect(nlp.kind, AutoBillIngestKind.draftQueued);
        expect(nlp.parseSource, 'nlp');
        expect(nlp.money!.storageMinor, BigInt.from(950));
        expect(nlp.assetId, walletId);
        expect(nlp.categoryId, foodCatId);

        // AI is only used when the user enabled it and offline parsing failed.
        final ai = _FakeAiClient();
        final aiService = AutoBillService(
          db,
          ledgerService: ledger,
          bridge: bridge,
          aiClient: ai,
        );
        await expectLater(
          aiService.ingestSmartText(commandId: cmd(), text: '一张看不清的小票'),
          throwsA(isA<Failure>()),
        );
        expect(ai.calls, 0);
        await aiService.saveAiParserConfig(
          commandId: cmd(),
          config: const AiBillParserConfig(
            enabled: true,
            baseUrl: 'https://api.example.com/v1',
            model: 'demo',
          ),
        );
        expect((await aiService.getAiParserConfig()).isConfigured, isTrue);
        final viaAi = await aiService.ingestSmartText(
          commandId: cmd(),
          text: '一张看不清的小票',
        );
        expect(ai.calls, 1);
        expect(viaAi.parseSource, 'ai');
        expect(viaAi.money!.storageMinor, BigInt.from(4200));
      },
    );

    test(
      'UrlSchemeService executes smartbill auto/draft/confirm and drafts/ocr routes',
      () async {
        final url = UrlSchemeService(
          db,
          ledgerService: ledger,
          bridge: bridge,
          autoBillService: service,
        );
        final draftRes = await url.executeUri(
          'tallyisle://smartbill?text=${Uri.encodeComponent('早饭包子8.5元')}&mode=draft&app=shortcut',
          commandId: cmd(),
        );
        expect(draftRes.action, UrlSchemeAction.smartBill);
        expect(draftRes.createdDraftId, isNotNull);
        expect(draftRes.wroteRecord, isFalse);

        final confirm = await url.executeUri(
          'tallyisle://smartbill?clipboard=1',
          commandId: cmd(),
        );
        expect(confirm.targetRoute, startsWith('/automation/smart-bill'));
        expect(confirm.createdDraftId, isNull);

        expect(
          (await url.executeUri(
            'tallyisle://drafts',
            commandId: cmd(),
          )).targetRoute,
          '/automation/auto-bill',
        );
        expect(
          (await url.executeUri(
            'tallyisle://ocr',
            commandId: cmd(),
          )).targetRoute,
          '/automation/ocr',
        );
      },
    );
  });

  group('Smart quick widget, native OCR provider and AI client', () {
    test(
      'snapshot carries pendingDraftCount and decodes smart_quick counts',
      () async {
        await db
            .into(db.autoMaps)
            .insert(
              AutoMapsCompanion.insert(
                key: autoMapDraftKey,
                draft: const Value('{"bt":0,"moneyMinor":"100","date":1}'),
              ),
            );
        Map<Object?, Object?>? wire;
        const testChannel = MethodChannel('com.tallyisle/test_widgets_v2');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(testChannel, (call) async {
              if (call.method == 'updateWidgetSnapshot') {
                wire = call.arguments as Map<Object?, Object?>;
                return {
                  'quick_add': 0,
                  'month_summary': 1,
                  'month_bar': 0,
                  'smart_quick': 2,
                };
              }
              return null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(testChannel, null),
        );
        final widgetService = WidgetSnapshotService(
          db,
          bridge: MethodChannelAppWidgetBridge(channel: testChannel),
        );
        final (snapshot, counts) = await widgetService.syncToPlatform(
          now: fixedNow,
        );
        expect(snapshot.pendingDraftCount, 1);
        expect(wire?['pendingDraftCount'], 1);
        expect(counts[DesktopWidgetKind.smartQuick], 2);
        expect(WidgetSnapshotPayload.fromMap(snapshot.toMap()), snapshot);
        expect(
          DesktopWidgetKind.fromWireKey('smart_quick'),
          DesktopWidgetKind.smartQuick,
        );
      },
    );

    test(
      'OcrService uses native offline engine on mobile, honest 未配置 elsewhere',
      () async {
        final bridge = InMemoryAutoBillBridge(
          offlineOcrText: '11月10日 09:00\n瑞幸咖啡\n-18.50',
        );
        addTearDown(bridge.dispose);
        final mobile = OcrService(
          db,
          ledgerService: ledger,
          bridge: bridge,
          nativeOfflineSupported: true,
        );
        final provider = await mobile.getProvider();
        expect(provider, isA<NativeOfflineOcrProvider>());
        expect(provider.isConfigured, isTrue);
        expect(provider.statusLabel, '本机离线引擎（免费就绪）');
        final (text, candidates) = await mobile.recognizeImageToCandidates(
          Uint8List.fromList([1, 2, 3]),
          now: fixedNow,
        );
        expect(text, contains('瑞幸咖啡'));
        expect(candidates.single.money.storageMinor, BigInt.from(1850));

        bridge.offlineOcrText = null;
        await expectLater(
          mobile.recognizeImageToCandidates(Uint8List.fromList([1])),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.unsupportedCapability,
            ),
          ),
        );

        final desktop = OcrService(
          db,
          ledgerService: ledger,
          bridge: bridge,
          nativeOfflineSupported: false,
        );
        final desktopProvider = await desktop.getProvider();
        expect(desktopProvider.statusLabel, '未配置');
        expect(desktopProvider.capability.reason, '当前平台仅支持文本解析或配置在线接口');

        // AI vision mode with a user AI config allowing images.
        final ai = _FakeAiClient();
        final aiOcr = OcrService(
          db,
          ledgerService: ledger,
          bridge: bridge,
          aiClient: ai,
          nativeOfflineSupported: true,
        );
        await aiOcr.saveConfig(
          commandId: cmd(),
          config: const OcrEndpointConfig(mode: OcrModePreference.aiVision),
        );
        expect(await aiOcr.getProvider(), isA<UnconfiguredOcrProvider>());
        await AutoBillService(
          db,
          ledgerService: ledger,
          bridge: bridge,
        ).saveAiParserConfig(
          commandId: cmd(),
          config: const AiBillParserConfig(
            enabled: true,
            baseUrl: 'https://api.example.com/v1',
            model: 'vl',
            useForImages: true,
          ),
        );
        final aiProvider = await aiOcr.getProvider();
        expect(aiProvider, isA<AiVisionOcrProvider>());
        expect(
          await aiProvider.recognizeImage(Uint8List.fromList([9])),
          '全家便利店\n实付金额: 12.00',
        );
      },
    );

    test(
      'OpenAiCompatibleBillParserClient talks to a loopback /chat/completions',
      () async {
        final previousOverrides = HttpOverrides.current;
        HttpOverrides.global = null;
        addTearDown(() => HttpOverrides.global = previousOverrides);

        final requests = <Map<String, Object?>>[];
        String? auth;
        String? path;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((req) async {
          auth = req.headers.value(HttpHeaders.authorizationHeader);
          path = req.uri.path;
          final body = await utf8.decoder.bind(req).join();
          final json = (jsonDecode(body) as Map).cast<String, Object?>();
          requests.add(json);
          final isImage = (json['messages']! as List).any(
            (m) => (m as Map)['content'] is List,
          );
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write(
              jsonEncode({
                'choices': [
                  {
                    'message': {
                      'content': isImage
                          ? '瑞幸咖啡\n-18.50'
                          : '```json\n{"bills":[{"type":"expense","amount":"18.50","remark":"瑞幸"}]}\n```',
                    },
                  },
                ],
              }),
            );
          await req.response.close();
        });

        final config = AiBillParserConfig(
          enabled: true,
          baseUrl: 'http://127.0.0.1:${server.port}/v1',
          apiKey: 'sk-test',
          model: 'deepseek-chat',
        );
        final client = OpenAiCompatibleBillParserClient();
        final bills = await client.parseText(
          '瑞幸咖啡18.5',
          config: config,
          nowMs: fixedNow.millisecondsSinceEpoch,
          categoryNames: const ['餐饮'],
        );
        expect(path, '/v1/chat/completions');
        expect(auth, 'Bearer sk-test');
        expect(requests.single['model'], 'deepseek-chat');
        expect(bills.single.money.storageMinor, BigInt.from(1850));

        final text = await client.transcribeImage(
          Uint8List.fromList([1, 2]),
          config: config,
          fileName: 'a.jpg',
        );
        expect(text, '瑞幸咖啡\n-18.50');
        final imageMsg = (requests.last['messages']! as List).single as Map;
        final parts = imageMsg['content'] as List;
        expect(
          ((parts.last as Map)['image_url'] as Map)['url'],
          startsWith('data:image/jpeg;base64,'),
        );

        await expectLater(
          client.parseText('x', config: const AiBillParserConfig(), nowMs: 0),
          throwsA(isA<Failure>()),
        );
      },
    );
  });

  group('MethodChannelAutoBillBridge canonical wire contract', () {
    test('Dart→native methods and native→Dart callbacks', () async {
      const name = 'com.tallyisle/test_automation_contract';
      const channel = MethodChannel(name);
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            switch (call.method) {
              case 'getNotificationListenerStatus':
                return {
                  'supported': true,
                  'enabled': true,
                  'statusLabel': '已开启',
                };
              case 'getOverlayPermissionStatus':
                return {
                  'supported': true,
                  'enabled': false,
                  'statusLabel': '未授权',
                };
              case 'openNotificationListenerSettings':
              case 'openOverlaySettings':
              case 'syncAndroidAutoBillConfig':
              case 'showAutoBillPrompt':
                return true;
              case 'consumeCapturedEvents':
                return [
                  {
                    'packageName': 'com.tencent.mm',
                    'rawText': '付款 ¥1.00',
                    'capturedAtMs': 5,
                    'channel': 'notification',
                  },
                ];
              case 'consumePendingSharedPayloads':
                return [
                  {
                    'kind': 'image',
                    'imagePaths': ['/tmp/a.png'],
                    'source': 'share',
                    'receivedAtMs': 7,
                  },
                  {
                    'kind': 'shortcut',
                    'shortcutAction': 'bogus',
                    'receivedAtMs': 8,
                  },
                  {
                    'kind': 'shortcut',
                    'shortcutAction': 'smart_bill',
                    'source': 'shortcut',
                    'receivedAtMs': 9,
                  },
                ];
              case 'consumePendingPromptActions':
                return [
                  {'action': 'undo_record', 'recordId': 'r1', 'actionAtMs': 3},
                  {'action': 'confirm_draft', 'actionAtMs': 4},
                ];
              case 'recognizeImageOffline':
                return {'supported': true, 'text': '瑞幸 18.50'};
              default:
                return null;
            }
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final bridge = MethodChannelAutoBillBridge(
        channel: channel,
        isOhosOverride: false,
      );
      addTearDown(bridge.dispose);

      expect(
        await bridge.getNotificationListenerStatus(),
        const AutoBillPermissionStatus.notificationListener(enabled: true),
      );
      expect(
        await bridge.getOverlayPermissionStatus(),
        const AutoBillPermissionStatus.overlay(granted: false),
      );
      expect(await bridge.openNotificationListenerSettings(), isTrue);
      expect(await bridge.openOverlaySettings(), isTrue);
      expect(
        await bridge.syncAndroidAutoBillConfig(
          const AutoBillNativeConfig(
            enableNotificationCapture: true,
            enableAccessibilityCapture: false,
            promptMode: 'overlay',
            categories: [
              {'id': 1, 'name': '餐饮', 'type': 0, 'parentId': -1},
            ],
            assets: [
              {'id': 2, 'name': '微信'},
            ],
          ),
        ),
        isTrue,
      );
      final syncArgs = calls.last.arguments as Map;
      expect(
        syncArgs.keys,
        containsAll(<String>[
          'enableNotificationCapture',
          'enableAccessibilityCapture',
          'promptMode',
          'categories',
          'assets',
        ]),
      );
      expect(
        await bridge.showAutoBillPrompt(
          const AutoBillPromptRequest(
            promptKind: 'draft',
            promptMode: 'notification',
            draftId: 3,
            recordType: 0,
            amountFormatted: '18.50',
            merchant: '瑞幸',
          ),
        ),
        isTrue,
      );
      expect(
        (calls.last.arguments as Map).keys,
        containsAll(<String>[
          'promptKind',
          'promptMode',
          'draftId',
          'recordId',
          'recordType',
          'amountFormatted',
          'currencySymbol',
          'merchant',
          'categoryId',
          'categoryName',
          'assetId',
          'assetName',
        ]),
      );

      final events = await bridge.consumeCapturedEvents();
      expect(events.single.channel, 'notification');
      final shares = await bridge.consumePendingSharedPayloads();
      expect(shares, hasLength(2));
      expect(shares.first.kind, AutoBillSharedPayloadKind.image);
      expect(shares.first.imagePaths, ['/tmp/a.png']);
      expect(shares.last.shortcutAction, 'smart_bill');
      final actions = await bridge.consumePendingPromptActions();
      expect(actions.single.action, 'undo_record');
      expect(actions.single.recordId, 'r1');

      final ocr = await bridge.recognizeImageOffline(
        Uint8List.fromList([1, 2, 3]),
        fileName: 'x.png',
      );
      expect(ocr.supported, isTrue);
      expect(ocr.text, '瑞幸 18.50');
      final ocrArgs = calls.last.arguments as Map;
      expect(ocrArgs['bytes'], isA<Uint8List>());
      expect(ocrArgs['fileName'], 'x.png');

      // Native → Dart callbacks: false without listener, true once handled.
      Future<Object?> send(String method, Object? args) async {
        final completer = Completer<ByteData?>();
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              name,
              const StandardMethodCodec().encodeMethodCall(
                MethodCall(method, args),
              ),
              completer.complete,
            );
        return const StandardMethodCodec().decodeEnvelope(
          (await completer.future)!,
        );
      }

      const sharedArgs = {
        'kind': 'text',
        'text': '早饭8元',
        'source': 'share',
        'receivedAtMs': 1,
      };
      const actionArgs = {
        'action': 'confirm_draft',
        'draftId': 5,
        'categoryId': 2,
        'actionAtMs': 1,
      };
      expect(await send('onSharedPayload', sharedArgs), isFalse);
      expect(await send('onPromptAction', actionArgs), isFalse);
      final shared = <AutoBillSharedPayload>[];
      final prompted = <AutoBillPromptActionEvent>[];
      final s1 = bridge.onSharedPayload.listen(shared.add);
      final s2 = bridge.onPromptAction.listen(prompted.add);
      addTearDown(s1.cancel);
      addTearDown(s2.cancel);
      expect(await send('onSharedPayload', sharedArgs), isTrue);
      expect(await send('onPromptAction', actionArgs), isTrue);
      expect(
        await send('onSharedPayload', const {
          'kind': 'text',
          'receivedAtMs': 1,
        }),
        isFalse,
      );
      await Future<void>.delayed(Duration.zero);
      expect(shared.single.text, '早饭8元');
      expect(prompted.single.draftId, 5);
      expect(prompted.single.categoryId, 2);
    });

    test(
      'iOS and HarmonyOS use the native channel with honest unsupported capture',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final ios = createAutoBillBridge();
        addTearDown(ios.dispose);
        expect(ios, isA<MethodChannelAutoBillBridge>());
        expect(ios.capability.reason, contains('iOS'));
        expect(
          await ios.getAccessibilityStatus(),
          const AccessibilityBridgeStatus.unsupported(),
        );
        expect(
          await ios.getNotificationListenerStatus(),
          const AutoBillPermissionStatus.unsupported(),
        );
        expect((await ios.getOverlayPermissionStatus()).statusLabel, '当前平台不支持');
        expect(
          (await ios.recognizeImageOffline(Uint8List.fromList([1]))).supported,
          isFalse,
        );

        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        final ohos = createAutoBillBridge(isOhosOverride: true);
        addTearDown(ohos.dispose);
        expect(ohos, isA<MethodChannelAutoBillBridge>());
        expect(
          await ohos.getNotificationListenerStatus(),
          const AutoBillPermissionStatus.unsupported(),
        );
        final desktop = createAutoBillBridge(isOhosOverride: false);
        addTearDown(desktop.dispose);
        expect(desktop, isA<InMemoryAutoBillBridge>());
      },
    );
  });
}

final class _FakeAiClient implements AiBillParserClient {
  int calls = 0;

  @override
  Future<List<SmartBillParseResult>> parseText(
    String text, {
    required AiBillParserConfig config,
    required int nowMs,
    List<String> categoryNames = const [],
    List<String> assetNames = const [],
  }) async {
    calls++;
    return parseAiBillJsonResponse(
      '{"bills":[{"type":"expense","amount":"42.00","remark":"小票"}]}',
      nowMs: nowMs,
    );
  }

  @override
  Future<String> transcribeImage(
    Uint8List imageBytes, {
    required AiBillParserConfig config,
    String? fileName,
  }) async => '全家便利店\n实付金额: 12.00';
}
