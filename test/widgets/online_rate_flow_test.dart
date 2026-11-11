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

  testWidgets(
    'CurrenciesPage: defaults strictly offline (0 network requests), supports opt-in sync, custom source, and manual add/edit',
    (tester) async {
      final fixedMs = DateTime(2026, 11, 11, 15, 30).millisecondsSinceEpoch;
      final db = AppDatabase(NativeDatabase.memory(), nowMs: () => fixedMs);
      final requestedUrls = <String>[];

      HttpClient mockClientFactory() => _FakeHttpClient((uri) async {
        requestedUrls.add(uri.toString());
        if (uri.host == 'fx.internal.test') {
          // 1 USD = 7.00 CNY -> 1 CNY = 1/7 = 0.142857142857 USD
          return (200, '{"USD":"0.142857142857"}');
        }
        // Built-in public source: 1 USD = 7.20 CNY -> 1 CNY = 0.138888888889 USD
        return (
          200,
          '{"result":"success","base_code":"CNY","rates":{"USD":"0.138888888889"}}',
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

      // 1. Default privacy check: switch is OFF, offline text shown, ZERO network calls!
      final enableSwitchFinder = find.byKey(
        const Key('online-rate-enable-switch'),
      );
      expect(enableSwitchFinder, findsOneWidget);
      expect(tester.widget<SwitchListTile>(enableSwitchFinder).value, isFalse);
      expect(find.textContaining('默认离线（未开启联网汇率）'), findsOneWidget);
      expect(find.byKey(const Key('online-rate-auto-switch')), findsNothing);
      expect(find.byKey(const Key('online-rate-sync-now')), findsNothing);
      expect(find.byKey(const Key('online-rate-source-btn')), findsNothing);
      expect(requestedUrls, isEmpty);

      // 2. Manual currency add works while offline (0 network requests)
      await tester.tap(find.byKey(const Key('add-currency')));
      await settle(tester);
      await tester.enterText(find.byKey(const Key('currency-code')), 'USD');
      await tester.enterText(find.byKey(const Key('currency-name')), '美元');
      await tester.enterText(find.byKey(const Key('currency-price')), '8.00');
      await tester.tap(find.byKey(const Key('currency-save')));
      await settle(tester);

      expect(find.byKey(const Key('currency-USD')), findsOneWidget);
      expect(find.textContaining('1 USD = 8 CNY'), findsOneWidget);
      expect(requestedUrls, isEmpty);

      // 3. Opt-in: toggle online rate switch ON -> reveals controls without unsolicited sync
      await tester.tap(enableSwitchFinder);
      await settle(tester);

      expect(tester.widget<SwitchListTile>(enableSwitchFinder).value, isTrue);
      final autoSwitchFinder = find.byKey(const Key('online-rate-auto-switch'));
      expect(autoSwitchFinder, findsOneWidget);
      expect(tester.widget<SwitchListTile>(autoSwitchFinder).value, isTrue);
      expect(find.byKey(const Key('online-rate-sync-now')), findsOneWidget);
      expect(find.byKey(const Key('online-rate-source-btn')), findsOneWidget);
      expect(requestedUrls, isEmpty);

      // 4. Tap "立即同步汇率" -> fetches from built-in open.er-api.com and updates USD to 7.2 CNY
      await tester.tap(find.byKey(const Key('online-rate-sync-now')));
      await settle(tester);

      expect(requestedUrls, ['https://open.er-api.com/v6/latest/CNY']);
      expect(find.textContaining('1 USD = 7.2 CNY'), findsOneWidget);
      expect(find.textContaining('来源：open.er-api.com'), findsWidgets);

      // 5. Configure custom endpoint URL (with validation check first) and sync again
      await tester.tap(find.byKey(const Key('online-rate-source-btn')));
      await settle(tester);
      await tester.enterText(
        find.byKey(const Key('online-rate-custom-url-input')),
        'ftp://invalid-url',
      );
      await tester.tap(find.byKey(const Key('online-rate-save-source')));
      await tester.pump();
      expect(find.textContaining('https:// 或 http://'), findsWidgets);

      await tester.enterText(
        find.byKey(const Key('online-rate-custom-url-input')),
        'https://fx.internal.test/cny.json',
      );
      await tester.tap(find.byKey(const Key('online-rate-save-source')));
      await settle(tester);
      expect(find.textContaining('fx.internal.test/cny.json'), findsOneWidget);

      await tester.tap(find.byKey(const Key('online-rate-sync-now')));
      await settle(tester);
      expect(requestedUrls.last, 'https://fx.internal.test/cny.json');
      expect(find.textContaining('1 USD = 7 CNY'), findsOneWidget);
      expect(find.textContaining('来源：自定义源 (fx.internal.test)'), findsWidgets);

      // 6. Toggle auto-sync switch OFF and verify persistence
      await tester.tap(autoSwitchFinder);
      await settle(tester);
      expect(tester.widget<SwitchListTile>(autoSwitchFinder).value, isFalse);
      final persistedSettings = await tester.runAsync(
        () => CurrencyService(db).getOnlineRateSettings(),
      );
      expect(persistedSettings!.autoSyncOnLaunch, isFalse);

      // 7. Manual edit still works anytime while online sync is enabled!
      await tester.tap(find.byKey(const Key('currency-USD')));
      await settle(tester);
      await tester.enterText(find.byKey(const Key('currency-price')), '7.35');
      await tester.tap(find.byKey(const Key('currency-save')));
      await settle(tester);
      expect(find.textContaining('1 USD = 7.35 CNY'), findsOneWidget);

      await tearDownDb(tester, db);
    },
  );

  testWidgets(
    'CurrenciesPage: triggers silent 24h auto-sync on open ONLY when already opted in and cooldown elapsed',
    (tester) async {
      final fixedMs = DateTime(2026, 11, 11, 9, 0).millisecondsSinceEpoch;
      final db = AppDatabase(NativeDatabase.memory(), nowMs: () => fixedMs);
      final svc = CurrencyService(db);

      await tester.runAsync(() async {
        await svc.saveCurrency(
          commandId: 'seed-usd',
          code: 'USD',
          name: '美元',
          symbol: r'$',
          price: '8.00',
        );
        await svc.saveOnlineRateSettings(
          commandId: 'seed-opt-in',
          settings: const OnlineRateSettings(
            enabled: true,
            autoSyncOnLaunch: true,
            lastSyncedAtMs: 0,
          ),
        );
      });

      var networkCount = 0;
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            databaseProvider.overrideWith((ref) async => db),
            onlineRateHttpClientFactoryProvider.overrideWithValue(
              () => _FakeHttpClient((_) async {
                networkCount++;
                return (
                  200,
                  '{"date":"2026-11-11","cny":{"usd":"0.138888888889"}}',
                );
              }),
            ),
          ],
          child: const MaterialApp(home: CurrenciesPage()),
        ),
      );
      await settle(tester);

      expect(networkCount, 1);
      expect(find.textContaining('1 USD = 7.2 CNY'), findsOneWidget);

      await tearDownDb(tester, db);
    },
  );
}
