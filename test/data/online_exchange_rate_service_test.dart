import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/data/catalog/currency_service.dart';
import 'package:tallyisle/data/catalog/exchange_rate_provider.dart';
import 'package:tallyisle/data/db/database.dart';
import 'package:tallyisle/data/ledger/ledger_service.dart';
import 'package:tallyisle/data/repo/ledger_queries.dart';
import 'package:tallyisle/domain/ledger/record_extra.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/asset_overview.dart';
import 'package:tallyisle/domain/rules/currency_rates.dart';
import 'package:tallyisle/domain/rules/income_expense.dart';
import 'package:tallyisle/domain/rules/online_rate_rules.dart';
import 'package:tallyisle/platform/files.dart';

typedef _MockHttpHandler =
    Future<(int statusCode, String body)> Function(Uri uri);

final class _FakeHttpHeaders implements HttpHeaders {
  final Map<String, String> values = <String, String>{};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = value.toString();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(this._handler, {this.onClose});

  final _MockHttpHandler _handler;
  final void Function()? onClose;

  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async =>
      _FakeHttpClientRequest(url, _handler);

  @override
  void close({bool force = false}) => onClose?.call();

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
    final (statusCode, body) = await _handler(uri);
    return _FakeHttpClientResponse(statusCode, utf8.encode(body));
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

  late int clockMs;
  late AppDatabase db;
  late LedgerService ledger;
  late CurrencyService currencies;
  var seq = 0;
  String cmd() => 'fx-online-cmd-${seq++}';

  setUp(() {
    clockMs = DateTime(2026, 11, 11, 10, 0, 0).millisecondsSinceEpoch;
    db = AppDatabase(NativeDatabase.memory(), nowMs: () => clockMs);
    ledger = LedgerService(db);
    currencies = CurrencyService(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('Privacy default & OfflineExchangeRateProvider (R1, ADR-017)', () {
    test(
      'defaults to unconfigured offline state and makes ZERO HTTP calls when disabled',
      () async {
        final settings = await currencies.getOnlineRateSettings();
        expect(settings.enabled, isFalse);

        var httpClientsCreated = 0;
        final requestedUrls = <String>[];
        HttpClient spyFactory() {
          httpClientsCreated++;
          return _FakeHttpClient((uri) async {
            requestedUrls.add(uri.toString());
            return (200, '{"base":"CNY","rates":{"USD":0.14}}');
          });
        }

        const offline = OfflineExchangeRateProvider();
        expect(offline.capability.state, CapabilityState.unconfigured);
        expect(offline.capability.reason, '默认离线（未开启联网汇率）');

        final disabledHttp = HttpExchangeRateProvider(
          settings: settings,
          httpClientFactory: spyFactory,
          nowMs: () => clockMs,
        );
        expect(disabledHttp.capability.state, CapabilityState.unconfigured);
        expect(disabledHttp.capability.reason, '默认离线（未开启联网汇率）');

        await expectLater(
          () => disabledHttp.fetchRatesRelativeToBase(),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.unsupportedCapability,
            ),
          ),
        );
        await expectLater(
          () => currencies.syncOnlineRates(
            commandId: cmd(),
            provider: disabledHttp,
          ),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.unsupportedCapability,
            ),
          ),
        );

        final autoRes = await currencies.runAutoSyncIfNeeded(
          provider: disabledHttp,
        );
        expect(autoRes, isNull);
        expect(httpClientsCreated, 0);
        expect(requestedUrls, isEmpty);
      },
    );
  });

  group('HttpExchangeRateProvider multi-source failover & timeout (R3)', () {
    test(
      'fails over across custom URL -> open.er-api -> jsdelivr -> frankfurter and closes clients',
      () async {
        const settings = OnlineRateSettings(
          enabled: true,
          customEndpointUrl: 'https://custom.fx.invalid/latest/cny',
        );
        final requestedUrls = <String>[];
        var closedCount = 0;

        final provider = HttpExchangeRateProvider(
          settings: settings,
          timeout: const Duration(milliseconds: 50),
          nowMs: () => clockMs,
          httpClientFactory: () => _FakeHttpClient((uri) async {
            final u = uri.toString();
            requestedUrls.add(u);
            if (u.contains('custom.fx.invalid')) {
              return (503, 'Service Unavailable');
            }
            if (u.contains('open.er-api.com')) {
              await Future<void>.delayed(const Duration(milliseconds: 120));
              return (
                200,
                '{"result":"success","base_code":"CNY","rates":{"USD":0.14}}',
              );
            }
            if (u.contains('cdn.jsdelivr.net')) {
              return (200, '{"date":"2026-11-11","cny":{}}');
            }
            if (u.contains('api.frankfurter.dev')) {
              return (
                200,
                '{"amount":1.0,"base":"CNY","date":"2026-11-11","rates":{"USD":0.1389,"EUR":0.1295}}',
              );
            }
            throw const SocketException('unexpected host');
          }, onClose: () => closedCount++),
        );

        expect(provider.capability.state, CapabilityState.available);
        expect(provider.candidateEndpoints(), [
          'https://custom.fx.invalid/latest/cny',
          'https://open.er-api.com/v6/latest/CNY',
          'https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/cny.json',
          'https://api.frankfurter.dev/v1/latest?base=CNY',
        ]);

        final fetched = await provider.fetchRatesRelativeToBase();
        expect(requestedUrls, [
          'https://custom.fx.invalid/latest/cny',
          'https://open.er-api.com/v6/latest/CNY',
          'https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/cny.json',
          'https://api.frankfurter.dev/v1/latest?base=CNY',
        ]);
        expect(closedCount, 4);
        expect(fetched.sourceLabel, 'api.frankfurter.dev');
        expect(fetched.providerDate, '2026-11-11');
        expect(fetched.ratesToAnchor['USD'], '0.1389');
        expect(fetched.ratesToAnchor['EUR'], '0.1295');
      },
    );

    test(
      'stops on first succeeding custom source and throws remoteUnavailable when all fail',
      () async {
        const settings = OnlineRateSettings(
          enabled: true,
          customEndpointUrl: 'https://my-fx.example.com/cny.json',
        );
        final requested = <String>[];
        final okProvider = HttpExchangeRateProvider(
          settings: settings,
          nowMs: () => clockMs,
          httpClientFactory: () => _FakeHttpClient((uri) async {
            requested.add(uri.toString());
            return (200, '{"USD":"0.1400","HKD":1.08}');
          }),
        );

        final res = await okProvider.fetchRatesRelativeToBase();
        expect(requested, ['https://my-fx.example.com/cny.json']);
        expect(res.sourceLabel, '自定义源 (my-fx.example.com)');
        expect(res.ratesToAnchor, {'USD': '0.14', 'HKD': '1.08'});

        final failingProvider = HttpExchangeRateProvider(
          settings: const OnlineRateSettings(enabled: true),
          nowMs: () => clockMs,
          httpClientFactory: () => _FakeHttpClient((_) async {
            throw const SocketException('offline');
          }),
        );
        await expectLater(
          () => failingProvider.fetchRatesRelativeToBase(),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.remoteUnavailable,
            ),
          ),
        );
      },
    );
  });

  group(
    'CurrencyService.syncOnlineRates & historical snapshot immutability (R4, R5)',
    () {
      test(
        'returns 0 updated cleanly with zero network I/O when no foreign currencies exist',
        () async {
          await currencies.saveOnlineRateSettings(
            commandId: cmd(),
            settings: const OnlineRateSettings(enabled: true),
          );

          var httpCalls = 0;
          final provider = HttpExchangeRateProvider(
            settings: await currencies.getOnlineRateSettings(),
            nowMs: () => clockMs,
            httpClientFactory: () => _FakeHttpClient((_) async {
              httpCalls++;
              return (200, '{"base":"CNY","rates":{"USD":0.14}}');
            }),
          );

          final result = await currencies.syncOnlineRates(
            commandId: cmd(),
            provider: provider,
          );
          expect(result.updatedCount, 0);
          expect(result.updatedCodes, isEmpty);
          expect(result.skippedCodes, isEmpty);
          expect(httpCalls, 0);
        },
      );

      test(
        'updates matching currencies atomically, preserves custom currencies, '
        'enforces ADR-009 idempotency, and NEVER alters historical CurrencySnapshot',
        () async {
          // 1. Add USD, JPY, and a custom currency GOLD at t = clockMs
          await currencies.saveCurrency(
            commandId: cmd(),
            code: 'USD',
            name: '美元',
            symbol: r'$',
            price: '8.00', // rate_to_anchor = 0.125
          );
          await currencies.saveCurrency(
            commandId: cmd(),
            code: 'JPY',
            name: '日元',
            symbol: '¥',
            price: '0.05', // rate_to_anchor = 20
          );
          await currencies.saveCurrency(
            commandId: cmd(),
            code: 'GOLD',
            name: '黄金克',
            symbol: 'g',
            price: '500', // rate_to_anchor = 0.002
          );
          final initialGoldTime = clockMs;

          // 2. Book a historical USD expense on a USD account at 1 USD = 8.00 CNY (100 USD -> 800 CNY)
          final usdAssetId = await ledger.createAsset(
            commandId: cmd(),
            name: '美元钱包',
            initial: Money.parse('500.00'),
            currency: 'USD',
          );
          final foodCat = (await (db.select(
            db.recordCategories,
          )..where((t) => t.name.equals('餐饮'))).getSingle()).id;
          final historicalRates = RateTable({'CNY': '1', 'USD': '0.125'});
          final extra = RecordExtra()
            ..currency = billSnapshot(
              source: 'USD',
              sourceMinor: BigInt.from(10000),
              account: 'USD',
              assetMinor: BigInt.from(10000),
              rates: historicalRates,
            );
          final recordId = await ledger.saveRecord(
            commandId: cmd(),
            draft: RecordDraft(
              type: RecordType.expense,
              money: Money.parse('100.00'),
              bookId: 1,
              recordTime: clockMs,
              categoryId: foodCat,
              assetId: usdAssetId,
              extra: extra,
            ),
          );

          final recordBefore = await (db.select(
            db.records,
          )..where((t) => t.recordId.equals(recordId))).getSingle();
          expect(
            RecordExtra.parse(recordBefore.extraInfo).currency?.baseAmount,
            BigInt.from(80000),
          );

          // 3. Advance clock by 2 hours, enable online sync, and sync rates
          clockMs += 2 * 60 * 60 * 1000;
          final enabledSettings = await currencies.saveOnlineRateSettings(
            commandId: cmd(),
            settings: const OnlineRateSettings(enabled: true),
          );

          var networkCalls = 0;
          final provider = HttpExchangeRateProvider(
            settings: enabledSettings,
            nowMs: () => clockMs,
            httpClientFactory: () => _FakeHttpClient((uri) async {
              networkCalls++;
              return (
                200,
                jsonEncode({
                  'result': 'success',
                  'base_code': 'CNY',
                  'rates': {'CNY': 1, 'USD': 0.14, 'JPY': 21.35},
                }),
              );
            }),
          );

          final syncCmd = cmd();
          final res1 = await currencies.syncOnlineRates(
            commandId: syncCmd,
            provider: provider,
          );
          expect(networkCalls, 1);
          expect(res1.updatedCount, 2);
          expect(res1.updatedCodes, containsAll(['USD', 'JPY']));
          expect(res1.skippedCodes, ['GOLD']);
          expect(res1.sourceLabel, 'open.er-api.com');
          expect(res1.syncedAtMs, clockMs);

          // 4. ADR-009 idempotency: retrying same commandId makes 0 additional network calls
          final res2 = await currencies.syncOnlineRates(
            commandId: syncCmd,
            provider: provider,
          );
          expect(networkCalls, 1);
          expect(res2.updatedCount, 2);
          expect(res2.syncedAtMs, res1.syncedAtMs);

          // 5. Verify DB currencies: USD & JPY updated, GOLD & CNY untouched!
          final rows = {
            for (final c in await db.select(db.currencies).get()) c.code: c,
          };
          expect(rows['CNY']!.rateToAnchor, '1');
          expect(rows['USD']!.rateToAnchor, '0.14');
          expect(rows['USD']!.rateRefreshTime, clockMs);
          expect(rows['JPY']!.rateToAnchor, '21.35');
          expect(rows['JPY']!.rateRefreshTime, clockMs);
          expect(rows['GOLD']!.rateToAnchor, '0.002');
          expect(rows['GOLD']!.rateRefreshTime, initialGoldTime);

          // 6. Verify settings metadata persisted
          final afterSettings = await currencies.getOnlineRateSettings();
          expect(afterSettings.lastSyncedAtMs, clockMs);
          expect(afterSettings.lastSyncSource, 'open.er-api.com');

          // 7. Verify historical record extra_info.curr and period stats are 100% IMMUTABLE!
          final recordAfter = await (db.select(
            db.records,
          )..where((t) => t.recordId.equals(recordId))).getSingle();
          expect(recordAfter.extraInfo, recordBefore.extraInfo);
          expect(
            RecordExtra.parse(recordAfter.extraInfo).currency?.baseAmount,
            BigInt.from(80000),
          );
          final periodRows = await LedgerQueries(
            db,
          ).watchRecords(1, 0, clockMs + 10000).first;
          final summary = aggregateIncomeExpense(periodRows.map(statEntryOf));
          expect(summary.expense, BigInt.from(80000));
        },
      );

      test(
        'runAutoSyncIfNeeded respects 24h cooldown, autoSyncOnLaunch flag, and swallows transient network errors',
        () async {
          await currencies.saveCurrency(
            commandId: cmd(),
            code: 'USD',
            name: '美元',
            symbol: r'$',
            price: '8.00',
          );

          var networkCalls = 0;
          var shouldFailNetwork = false;
          var quotedUsdRate = '0.1389';

          Future<ExchangeRateProvider>
          currentProvider() async => HttpExchangeRateProvider(
            settings: await currencies.getOnlineRateSettings(),
            nowMs: () => clockMs,
            httpClientFactory: () => _FakeHttpClient((_) async {
              networkCalls++;
              if (shouldFailNetwork) {
                throw const SocketException('airplane mode');
              }
              return (
                200,
                '{"result":"success","base_code":"CNY","rates":{"USD":"$quotedUsdRate"}}',
              );
            }),
          );

          // 1. Disabled by default -> 0 calls
          expect(
            await currencies.runAutoSyncIfNeeded(
              provider: await currentProvider(),
            ),
            isNull,
          );
          expect(networkCalls, 0);

          // 2. Enabled with autoSyncOnLaunch == false -> 0 calls
          await currencies.saveOnlineRateSettings(
            commandId: cmd(),
            settings: const OnlineRateSettings(
              enabled: true,
              autoSyncOnLaunch: false,
            ),
          );
          expect(
            await currencies.runAutoSyncIfNeeded(
              provider: await currentProvider(),
            ),
            isNull,
          );
          expect(networkCalls, 0);

          // 3. Enabled with autoSyncOnLaunch == true -> initial sync runs!
          await currencies.saveOnlineRateSettings(
            commandId: cmd(),
            settings: const OnlineRateSettings(
              enabled: true,
              autoSyncOnLaunch: true,
            ),
          );
          final tSync1 = clockMs;
          final auto1 = await currencies.runAutoSyncIfNeeded(
            provider: await currentProvider(),
          );
          expect(auto1?.updatedCount, 1);
          expect(networkCalls, 1);

          // 4. Within 24h cooldown (e.g. +23h59m59s) -> 0 calls!
          clockMs = tSync1 + 24 * 60 * 60 * 1000 - 1000;
          expect(
            await currencies.runAutoSyncIfNeeded(
              provider: await currentProvider(),
            ),
            isNull,
          );
          expect(networkCalls, 1);

          // 5. After 24h, transient network failure -> swallowed silently, keeps previous USD rate!
          clockMs = tSync1 + 24 * 60 * 60 * 1000;
          shouldFailNetwork = true;
          expect(
            await currencies.runAutoSyncIfNeeded(
              provider: await currentProvider(),
            ),
            isNull,
          );
          expect(
            networkCalls,
            4,
          ); // tried all 3 builtin failover sources (1 + 3 = 4)
          final usdDuringOutage = await (db.select(
            db.currencies,
          )..where((t) => t.code.equals('USD'))).getSingle();
          expect(usdDuringOutage.rateToAnchor, '0.1389');
          expect(
            (await currencies.getOnlineRateSettings()).lastSyncedAtMs,
            tSync1,
          );

          // 6. Network recovers 5 minutes later -> auto-sync succeeds with updated rate!
          clockMs += 5 * 60 * 1000;
          shouldFailNetwork = false;
          quotedUsdRate = '0.142857142857';
          final auto2 = await currencies.runAutoSyncIfNeeded(
            provider: await currentProvider(),
          );
          expect(auto2?.updatedCount, 1);
          final usdAfterRecovery = await (db.select(
            db.currencies,
          )..where((t) => t.code.equals('USD'))).getSingle();
          expect(usdAfterRecovery.rateToAnchor, '0.142857142857');
          expect(
            (await currencies.getOnlineRateSettings()).lastSyncedAtMs,
            clockMs,
          );
        },
      );
    },
  );
}
