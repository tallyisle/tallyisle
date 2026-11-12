import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/app/providers.dart';
import 'package:tallyisle/data/catalog/currency_service.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/domain/rules/currency_rates.dart';
import 'package:tallyisle/domain/rules/online_rate_rules.dart';
import 'package:tallyisle/features/currencies/currencies_page.dart';
import 'package:tallyisle/features/currencies/currency_rate_providers.dart';

typedef _MockHttpHandler =
    Future<(int statusCode, String body)> Function(Uri uri);

final class _FakeHttpHeaders implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(this._handler);
  final _MockHttpHandler _handler;

  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      _FakeHttpClientRequest(url, _handler);

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeHttpClientRequest implements HttpClientRequest {
  _FakeHttpClientRequest(this.uri, this._handler);

  @override
  final Uri uri;
  final _MockHttpHandler _handler;

  @override
  final HttpHeaders headers = _FakeHttpHeaders();

  @override
  Future<HttpClientResponse> close() async {
    final (code, body) = await _handler(uri);
    return _FakeHttpClientResponse(code, utf8.encode(body));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _FakeHttpClientResponse(this.statusCode, this._bytes);

  @override
  final int statusCode;
  final List<int> _bytes;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(_bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  Future<void> tearDownDb(WidgetTester tester, AppDatabase db) async {
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    await tester.runAsync(db.close);
    await tester.pump(const Duration(seconds: 1));
  }

  String priceTextOf(WidgetTester tester) => tester
      .widget<TextField>(find.byKey(const Key('currency-price')))
      .controller!
      .text;

  testWidgets(
    '1. With online rates ON: preset USD auto-populates rate, switching to JPY reuses dialog cache (1 HTTP request), and clearing price on save still auto-fetches & persists exact rateToAnchor',
    (tester) async {
      final fixedMs = DateTime(2026, 11, 12, 10, 0).millisecondsSinceEpoch;
      final db = AppDatabase(NativeDatabase.memory(), nowMs: () => fixedMs);
      final svc = CurrencyService(db);

      await tester.runAsync(() async {
        await svc.saveOnlineRateSettings(
          commandId: 'seed-online-on',
          settings: OnlineRateSettings(
            enabled: true,
            autoSyncOnLaunch: true,
            lastSyncedAtMs: fixedMs - 1000,
          ),
        );
      });

      final requestedUrls = <String>[];
      HttpClient mockClientFactory() => _FakeHttpClient((uri) async {
        requestedUrls.add(uri.toString());
        return (
          200,
          jsonEncode({
            'result': 'success',
            'base_code': 'CNY',
            'rates': {
              'USD': '0.138888888889', // 1 USD = 7.2 CNY
              'JPY': '21.35', // 1 JPY = 0.0468 CNY (exact rateToAnchor = 21.35)
            },
          }),
        );
      });

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            onlineRateHttpClientFactoryProvider.overrideWithValue(
              mockClientFactory,
            ),
          ],
          child: const MaterialApp(home: CurrenciesPage()),
        ),
      );
      await settle(tester);
      expect(requestedUrls, isEmpty);

      // Open "+ 添加币种"
      await tester.tap(find.byKey(const Key('add-currency')));
      await settle(tester);
      expect(requestedUrls, isEmpty);

      // Pick 美元（USD） from preset -> auto-fetches once and populates 7.2
      await tester.tap(find.byKey(const Key('currency-preset')));
      await settle(tester);
      await tester.tap(find.text('美元（USD）').last);
      await settle(tester);

      expect(requestedUrls.length, 1);
      expect(priceTextOf(tester), '7.2');
      expect(find.textContaining('实时汇率来源：open.er-api.com'), findsOneWidget);

      // Switch preset to 日元（JPY） -> updates immediately from cached payload (still 1 HTTP request!)
      await tester.tap(find.byKey(const Key('currency-preset')));
      await settle(tester);
      await tester.tap(find.text('日元（JPY）').last);
      await tester.pump();

      expect(requestedUrls.length, 1);
      expect(priceTextOf(tester), '0.0468');

      // Clear currency-price and tap currency-save -> auto-fills from cache & saves JPY!
      await tester.enterText(find.byKey(const Key('currency-price')), '');
      await tester.pump();
      expect(priceTextOf(tester), isEmpty);

      await tester.tap(find.byKey(const Key('currency-save')));
      await settle(tester);

      expect(requestedUrls.length, 1);
      expect(find.byKey(const Key('currency-JPY')), findsOneWidget);
      expect(find.textContaining('1 JPY = 0.0468 CNY'), findsOneWidget);

      // Verify exact 12-decimal rateToAnchor ('21.35') was stored without rounding loss!
      final jpyRow = await tester.runAsync(
        () => (db.select(
          db.currencies,
        )..where((t) => t.code.equals('JPY'))).getSingle(),
      );
      expect(jpyRow!.rateToAnchor, '21.35');
      final afterSettings = await tester.runAsync(svc.getOnlineRateSettings);
      expect(afterSettings!.lastSyncedAtMs, fixedMs);
      expect(afterSettings.lastSyncSource, 'open.er-api.com');

      await tearDownDb(tester, db);
    },
  );

  testWidgets(
    '2a. With online rates initially OFF: tapping Key("currency-fetch-online-btn") enables online rates, populates EUR rate, and saves cleanly (also works in edit mode)',
    (tester) async {
      final fixedMs = DateTime(2026, 11, 12, 11, 0).millisecondsSinceEpoch;
      final db = AppDatabase(NativeDatabase.memory(), nowMs: () => fixedMs);
      final svc = CurrencyService(db);

      // Seed custom autoSyncOnLaunch: false while disabled to verify preservation
      await tester.runAsync(() async {
        await svc.saveOnlineRateSettings(
          commandId: 'seed-custom-off',
          settings: const OnlineRateSettings(
            enabled: false,
            autoSyncOnLaunch: false,
            customEndpointUrl: 'https://fx.internal.test/cny.json',
          ),
        );
      });

      final requestedUrls = <String>[];
      var eurQuote = '0.1295'; // 1 EUR = 7.722 CNY
      HttpClient mockClientFactory() => _FakeHttpClient((uri) async {
        requestedUrls.add(uri.toString());
        return (200, jsonEncode({'EUR': eurQuote}));
      });

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            onlineRateHttpClientFactoryProvider.overrideWithValue(
              mockClientFactory,
            ),
          ],
          child: const MaterialApp(home: CurrenciesPage()),
        ),
      );
      await settle(tester);

      final enableSwitch = find.byKey(const Key('online-rate-enable-switch'));
      expect(tester.widget<SwitchListTile>(enableSwitch).value, isFalse);
      expect(requestedUrls, isEmpty);

      // Open "+ 添加币种" and pick 欧元（EUR） -> still offline, so 0 HTTP calls and blank price
      await tester.tap(find.byKey(const Key('add-currency')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('currency-preset')));
      await settle(tester);
      await tester.tap(find.text('欧元（EUR）').last);
      await settle(tester);

      expect(requestedUrls, isEmpty);
      expect(priceTextOf(tester), isEmpty);

      // Tap "联网获取" button -> enables online rates (preserving autoSyncOnLaunch & customEndpointUrl), fetches & fills price
      await tester.tap(find.byKey(const Key('currency-fetch-online-btn')));
      await settle(tester);

      expect(requestedUrls, ['https://fx.internal.test/cny.json']);
      expect(priceTextOf(tester), '7.722');
      expect(
        find.textContaining('实时汇率来源：自定义源 (fx.internal.test)'),
        findsOneWidget,
      );

      // Save EUR
      await tester.tap(find.byKey(const Key('currency-save')));
      await settle(tester);

      expect(find.byKey(const Key('currency-EUR')), findsOneWidget);
      expect(find.textContaining('1 EUR = 7.722 CNY'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(enableSwitch).value, isTrue);

      final updatedSettings = await tester.runAsync(svc.getOnlineRateSettings);
      expect(updatedSettings!.enabled, isTrue);
      expect(updatedSettings.autoSyncOnLaunch, isFalse);
      expect(
        updatedSettings.customEndpointUrl,
        'https://fx.internal.test/cny.json',
      );

      // Open EUR in edit mode and tap "联网获取" -> refreshes to updated quote (0.125 -> 8 CNY)
      eurQuote = '0.125';
      await tester.tap(find.byKey(const Key('currency-EUR')));
      await settle(tester);
      expect(priceTextOf(tester), '7.722');
      expect(requestedUrls.length, 1);

      await tester.tap(find.byKey(const Key('currency-fetch-online-btn')));
      await settle(tester);
      expect(requestedUrls.length, 2);
      expect(priceTextOf(tester), '8');

      await tester.tap(find.byKey(const Key('currency-save')));
      await settle(tester);
      expect(find.textContaining('1 EUR = 8 CNY'), findsOneWidget);

      await tearDownDb(tester, db);
    },
  );

  testWidgets(
    '2b. With online rates initially OFF: leaving price blank and tapping save prompts confirmation; Key("confirm-online-fetch-save") enables online rates, fetches HKD, and saves',
    (tester) async {
      final fixedMs = DateTime(2026, 11, 12, 12, 0).millisecondsSinceEpoch;
      final db = AppDatabase(NativeDatabase.memory(), nowMs: () => fixedMs);
      final requestedUrls = <String>[];

      HttpClient mockClientFactory() => _FakeHttpClient((uri) async {
        requestedUrls.add(uri.toString());
        return (
          200,
          jsonEncode({
            'result': 'success',
            'base_code': 'CNY',
            'rates': {'HKD': '1.08'}, // 1 HKD = 0.9259 CNY
          }),
        );
      });

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            onlineRateHttpClientFactoryProvider.overrideWithValue(
              mockClientFactory,
            ),
          ],
          child: const MaterialApp(home: CurrenciesPage()),
        ),
      );
      await settle(tester);

      final enableSwitch = find.byKey(const Key('online-rate-enable-switch'));
      expect(tester.widget<SwitchListTile>(enableSwitch).value, isFalse);

      // Open "+ 添加币种", pick 港币（HKD）, leave price empty, tap 保存
      await tester.tap(find.byKey(const Key('add-currency')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('currency-preset')));
      await settle(tester);
      await tester.tap(find.text('港币（HKD）').last);
      await settle(tester);
      expect(priceTextOf(tester), isEmpty);

      await tester.tap(find.byKey(const Key('currency-save')));
      await settle(tester);

      // Verify confirmation prompt appears with 0 network calls so far
      expect(find.text('自动联网获取汇率？'), findsOneWidget);
      expect(
        find.text('尚未填写汇率，是否开启联网汇率并自动获取 HKD 的最新人民币汇率后保存？'),
        findsOneWidget,
      );
      expect(requestedUrls, isEmpty);

      // First verify "手动填写" dismisses prompt without network calls and keeps dialog open
      await tester.tap(find.text('手动填写'));
      await settle(tester);
      expect(find.text('自动联网获取汇率？'), findsNothing);
      expect(find.byKey(const Key('currency-price')), findsOneWidget);
      expect(requestedUrls, isEmpty);

      // Tap 保存 again -> tap "联网获取并保存" (Key('confirm-online-fetch-save'))
      await tester.tap(find.byKey(const Key('currency-save')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('confirm-online-fetch-save')));
      await settle(tester);

      expect(requestedUrls.length, 1);
      expect(tester.widget<SwitchListTile>(enableSwitch).value, isTrue);
      expect(find.byKey(const Key('currency-HKD')), findsOneWidget);
      expect(find.textContaining('1 HKD = 0.9259 CNY'), findsOneWidget);

      final hkdRow = await tester.runAsync(
        () => (db.select(
          db.currencies,
        )..where((t) => t.code.equals('HKD'))).getSingle(),
      );
      expect(hkdRow!.rateToAnchor, '1.08');

      await tearDownDb(tester, db);
    },
  );

  testWidgets(
    '3. Custom unknown currency code (FOOCOIN) when online rates ON: shows friendly manual-entry guidance without crashing and saves once manual rate entered',
    (tester) async {
      final fixedMs = DateTime(2026, 11, 12, 13, 0).millisecondsSinceEpoch;
      final db = AppDatabase(NativeDatabase.memory(), nowMs: () => fixedMs);
      final svc = CurrencyService(db);

      await tester.runAsync(() async {
        await svc.saveOnlineRateSettings(
          commandId: 'seed-online-on',
          settings: OnlineRateSettings(
            enabled: true,
            autoSyncOnLaunch: true,
            lastSyncedAtMs: fixedMs - 1000,
          ),
        );
      });

      var networkCount = 0;
      HttpClient mockClientFactory() => _FakeHttpClient((_) async {
        networkCount++;
        return (
          200,
          '{"result":"success","base_code":"CNY","rates":{"USD":"0.14"}}',
        );
      });

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            onlineRateHttpClientFactoryProvider.overrideWithValue(
              mockClientFactory,
            ),
          ],
          child: const MaterialApp(home: CurrenciesPage()),
        ),
      );
      await settle(tester);

      await tester.tap(find.byKey(const Key('add-currency')));
      await settle(tester);

      await tester.enterText(find.byKey(const Key('currency-code')), 'FOOCOIN');
      await tester.enterText(find.byKey(const Key('currency-name')), '积分币');
      await settle(tester);

      // Friendly helper guidance shown after auto-lookup, no crash
      expect(networkCount, 1);
      expect(priceTextOf(tester), isEmpty);
      expect(find.text('未查询到 FOOCOIN 的在线汇率，请手动填写汇率'), findsOneWidget);

      // Tapping save with empty price keeps dialog open and shows friendly inline error
      await tester.tap(find.byKey(const Key('currency-save')));
      await settle(tester);
      expect(networkCount, 1);
      expect(find.text('未查询到 FOOCOIN 的在线汇率，请手动填写汇率'), findsOneWidget);
      expect(find.byKey(const Key('currency-price')), findsOneWidget);

      // Entering manual rate saves FOOCOIN cleanly
      await tester.enterText(find.byKey(const Key('currency-price')), '2.50');
      await tester.tap(find.byKey(const Key('currency-save')));
      await settle(tester);

      expect(find.byKey(const Key('currency-FOOCOIN')), findsOneWidget);
      expect(find.textContaining('1 FOOCOIN = 2.5 CNY'), findsOneWidget);

      await tearDownDb(tester, db);
    },
  );

  testWidgets(
    '4. Existing manual offline flow: with online rates OFF, manual rate 7.25 makes ZERO HTTP calls, auto-fills preset name if omitted, and 0 / abc show validation error',
    (tester) async {
      final fixedMs = DateTime(2026, 11, 12, 14, 0).millisecondsSinceEpoch;
      final db = AppDatabase(NativeDatabase.memory(), nowMs: () => fixedMs);
      var httpCalls = 0;

      HttpClient mockClientFactory() => _FakeHttpClient((_) async {
        httpCalls++;
        return (200, '{"USD":"0.14"}');
      });

      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            onlineRateHttpClientFactoryProvider.overrideWithValue(
              mockClientFactory,
            ),
          ],
          child: const MaterialApp(home: CurrenciesPage()),
        ),
      );
      await settle(tester);

      await tester.tap(find.byKey(const Key('add-currency')));
      await settle(tester);

      // Enter USD code without typing name (auto-fills 美元 & $) and test invalid rates first
      await tester.enterText(find.byKey(const Key('currency-code')), 'USD');

      await tester.enterText(find.byKey(const Key('currency-price')), '0');
      await tester.tap(find.byKey(const Key('currency-save')));
      await tester.pump();
      expect(find.text('汇率须为正数'), findsOneWidget);
      expect(httpCalls, 0);

      await tester.enterText(find.byKey(const Key('currency-price')), 'abc');
      await tester.tap(find.byKey(const Key('currency-save')));
      await tester.pump();
      expect(find.text('汇率须为正数'), findsOneWidget);
      expect(httpCalls, 0);

      // Valid manual rate '7.25' saves cleanly with ZERO HTTP calls
      await tester.enterText(find.byKey(const Key('currency-price')), '7.25');
      await tester.tap(find.byKey(const Key('currency-save')));
      await settle(tester);

      expect(httpCalls, 0);
      expect(find.byKey(const Key('currency-USD')), findsOneWidget);
      expect(find.text('美元（USD）'), findsOneWidget);
      expect(find.textContaining('1 USD = 7.25 CNY'), findsOneWidget);

      final usdRow = await tester.runAsync(
        () => (db.select(
          db.currencies,
        )..where((t) => t.code.equals('USD'))).getSingle(),
      );
      expect(usdRow!.rateToAnchor, rateToAnchorFromPrice('7.25'));
      expect(usdRow.symbol, r'$');

      await tearDownDb(tester, db);
    },
  );
}
