import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/domain/rules/asset_overview.dart';
import 'package:tallyisle/domain/rules/currency_rates.dart';
import 'package:tallyisle/domain/rules/online_rate_rules.dart';

void main() {
  group('OnlineRateSettings & privacy defaults (R1, R5)', () {
    test('defaults strictly to disabled (offline mode)', () {
      expect(OnlineRateSettings.defaults.enabled, isFalse);
      expect(OnlineRateSettings.defaults.autoSyncOnLaunch, isTrue);
      expect(OnlineRateSettings.defaults.syncIntervalHours, 24);
      expect(OnlineRateSettings.defaults.customEndpointUrl, isEmpty);
      expect(OnlineRateSettings.defaults.lastSyncedAtMs, 0);
      expect(OnlineRateSettings.defaults.lastSyncSource, isEmpty);

      expect(OnlineRateSettings.parse(null), OnlineRateSettings.defaults);
      expect(OnlineRateSettings.parse(''), OnlineRateSettings.defaults);
      expect(OnlineRateSettings.parse('   '), OnlineRateSettings.defaults);
    });

    test('round-trips JSON and rejects malformed settings payloads', () {
      const configured = OnlineRateSettings(
        enabled: true,
        autoSyncOnLaunch: false,
        syncIntervalHours: 24,
        customEndpointUrl: 'https://rates.example.org/cny.json',
        lastSyncedAtMs: 1762848000000,
        lastSyncSource: '自定义源 (rates.example.org)',
      );
      final encoded = configured.encode();
      final decoded = OnlineRateSettings.parse(encoded);
      expect(decoded, configured);
      expect(decoded.hasCustomEndpoint, isTrue);

      expect(
        () => OnlineRateSettings.parse('{not-json'),
        throwsA(
          isA<Failure>().having((f) => f.code, 'code', FailureCode.corruptData),
        ),
      );
      expect(
        () => OnlineRateSettings.parse('{"enabled":"yes"}'),
        throwsA(isA<Failure>()),
      );
      expect(
        () => OnlineRateSettings.parse(
          '{"enabled":true,"customEndpointUrl":"ftp://bad.host/rates"}',
        ),
        throwsA(isA<Failure>()),
      );
    });

    test('enforces 24-hour auto-sync cooldown and opt-in gates', () {
      const t0 = 1762800000000;
      const twentyFourHoursMs = 24 * 60 * 60 * 1000;

      // Disabled -> never auto-syncs even if never synced before
      expect(OnlineRateSettings.defaults.shouldAutoSync(nowMs: t0), isFalse);

      // Enabled + autoSyncOnLaunch == false -> never auto-syncs
      const manualOnly = OnlineRateSettings(
        enabled: true,
        autoSyncOnLaunch: false,
      );
      expect(manualOnly.shouldAutoSync(nowMs: t0), isFalse);

      // Enabled + never synced (lastSyncedAtMs == 0) -> auto-syncs
      const firstRunEnabled = OnlineRateSettings(enabled: true);
      expect(firstRunEnabled.shouldAutoSync(nowMs: t0), isTrue);

      // Synced at t0: blocked at 23h59m59.999s, allowed at exact 24h00m00s
      const synced = OnlineRateSettings(enabled: true, lastSyncedAtMs: t0);
      expect(synced.shouldAutoSync(nowMs: t0 + twentyFourHoursMs - 1), isFalse);
      expect(synced.shouldAutoSync(nowMs: t0 + twentyFourHoursMs), isTrue);
    });

    test('validates custom endpoint URL schemes', () {
      expect(validateCustomRateEndpointUrl('   '), '');
      expect(
        validateCustomRateEndpointUrl('  https://api.example.com/fx.json  '),
        'https://api.example.com/fx.json',
      );
      expect(
        validateCustomRateEndpointUrl('http://127.0.0.1:8080/cny'),
        'http://127.0.0.1:8080/cny',
      );
      for (final invalid in [
        'not-a-url',
        'ftp://example.com/rates.json',
        'file:///etc/passwd',
        'https://',
      ]) {
        expect(
          () => validateCustomRateEndpointUrl(invalid),
          throwsA(
            isA<Failure>().having(
              (f) => f.code,
              'code',
              FailureCode.validation,
            ),
          ),
          reason: 'Expected $invalid to be rejected',
        );
      }
    });
  });

  group('Exact BigInt decimal conversion & bounds (R2, ADR-011)', () {
    test(
      'normalizes numbers, strings, scientific notation, and HALF_UP 12 decimals',
      () {
        expect(convertOnlineQuoteToRateToAnchor('0.125000'), '0.125');
        expect(convertOnlineQuoteToRateToAnchor(21.35), '21.35');
        expect(
          convertOnlineQuoteToRateToAnchor('0.1388888888885'),
          '0.138888888889',
        );
        expect(
          convertOnlineQuoteToRateToAnchor('0.1388888888884'),
          '0.138888888888',
        );
        expect(convertOnlineQuoteToRateToAnchor('1.38889e-1'), '0.138889');
        expect(convertOnlineQuoteToRateToAnchor('1.5E-7'), '0.00000015');
        expect(convertOnlineQuoteToRateToAnchor('+3512.40'), '3512.4');
        expect(
          convertOnlineQuoteToRateToAnchor(
            '0.12345678901250000000000000000000009',
          ),
          '0.123456789013',
        );
        expect(
          convertOnlineQuoteToRateToAnchor(
            2135,
            perBaseAmount: DecimalValue.parse('100'),
          ),
          '21.35',
        );
      },
    );

    test(
      'strictly rejects <= 0, NaN, Infinity, non-numeric, and out-of-bounds values',
      () {
        final invalidInputs = <Object?>[
          null,
          true,
          false,
          <int>[],
          <String, int>{},
          '',
          '   ',
          'abc',
          0,
          '0',
          '0.000000',
          '-0.0',
          -1,
          '-0.1389',
          'NaN',
          'nan',
          'Infinity',
          '+Infinity',
          '-Infinity',
          'inf',
          '-inf',
          '0.0000000000004', // rounds to 0 at 12 decimals
          '1e-20',
          '1000000001', // exceeds 10^9 upper bound
          '1e15',
        ];

        for (final input in invalidInputs) {
          expect(
            () => convertOnlineQuoteToRateToAnchor(input),
            throwsA(
              isA<Failure>().having(
                (f) => f.code,
                'code',
                FailureCode.validation,
              ),
            ),
            reason: 'Input "$input" must be rejected',
          );
        }
      },
    );
  });

  group('Multi-format CNY-base JSON payload parser (R2)', () {
    test('Format 1: open.er-api.com payload', () {
      const payload = '''
      {
        "result": "success",
        "base_code": "CNY",
        "rates": {
          "CNY": 1,
          "USD": 0.1388888888885,
          "JPY": 21.3500,
          "HKD": 1.0825
        }
      }
      ''';
      final parsed = parseOnlineRatesPayload(payload);
      expect(parsed.baseCode, 'CNY');
      expect(parsed.ratesToAnchor.containsKey('CNY'), isFalse);
      expect(parsed.ratesToAnchor['USD'], '0.138888888889');
      expect(parsed.ratesToAnchor['JPY'], '21.35');
      expect(parsed.ratesToAnchor['HKD'], '1.0825');
      expect(parsed.rejectedCodes, isEmpty);

      // Verify RateTable exact BigInt conversion with parsed rate
      final table = RateTable({'CNY': '1', ...parsed.ratesToAnchor});
      // 100.00 USD at 1 CNY = 0.138888888889 USD -> 720.00 CNY (72000 minor)
      expect(
        table.convert(BigInt.from(10000), 'USD', 'CNY'),
        BigInt.from(72000),
      );
      expect(priceFromRateToAnchor(parsed.ratesToAnchor['USD']!), '7.2');
    });

    test('Format 2: fawazahmed0/currency-api lowercase nested payload', () {
      const payload = '''
      {
        "date": "2026-11-11",
        "cny": {
          "cny": 1,
          "usd": 0.138889,
          "hkd": "1.0800",
          "1inch": 0.42,
          "deadcoin": 0
        }
      }
      ''';
      final parsed = parseOnlineRatesPayload(payload);
      expect(parsed.baseCode, 'CNY');
      expect(parsed.providerDate, '2026-11-11');
      expect(parsed.ratesToAnchor, {'USD': '0.138889', 'HKD': '1.08'});
      expect(parsed.rejectedCodes, {'DEADCOIN'});
    });

    test(
      'Format 3: api.frankfurter.dev ECB payload (including amount scaling)',
      () {
        const payload1 = '''
      {
        "amount": 1.0,
        "base": "CNY",
        "date": "2026-11-10",
        "rates": {
          "USD": 0.1389,
          "EUR": 0.1295
        }
      }
      ''';
        final parsed1 = parseOnlineRatesPayload(payload1);
        expect(parsed1.providerDate, '2026-11-10');
        expect(parsed1.ratesToAnchor, {'USD': '0.1389', 'EUR': '0.1295'});

        const payload100 = '''
      {
        "amount": 100,
        "base": "CNY",
        "rates": {
          "JPY": 2135,
          "USD": "13.89"
        }
      }
      ''';
        final parsed100 = parseOnlineRatesPayload(payload100);
        expect(parsed100.ratesToAnchor, {'JPY': '21.35', 'USD': '0.1389'});
      },
    );

    test('Format 4: custom flat map and data-wrapped JSON maps', () {
      const flatPayload = '''
      {
        "date": "2026-11-11",
        "USD": "0.14",
        "SGD": 0.1865
      }
      ''';
      final parsedFlat = parseOnlineRatesPayload(flatPayload);
      expect(parsedFlat.ratesToAnchor, {'USD': '0.14', 'SGD': '0.1865'});

      const dataWrapped = '''
      {
        "success": true,
        "data": {
          "base": "CNY",
          "rates": {
            "GBP": "0.1095",
            "AUD": 0.2134
          }
        }
      }
      ''';
      final parsedData = parseOnlineRatesPayload(dataWrapped);
      expect(parsedData.ratesToAnchor, {'GBP': '0.1095', 'AUD': '0.2134'});
    });

    test(
      'rejects error payloads, mismatched base currencies, and empty valid sets',
      () {
        for (final badPayload in [
          '',
          '[]',
          '{"result":"error","error-type":"unsupported-code"}',
          '{"success":false,"rates":{"USD":0.14}}',
          '{"base_code":"USD","rates":{"EUR":0.92}}',
          '{"base":"EUR","rates":{"USD":1.08}}',
          '{"data":{"base":"USD","rates":{"JPY":150}}}',
          '{"base":"CNY","rates":{"USD":0,"EUR":"NaN","JPY":-5}}',
        ]) {
          expect(
            () => parseOnlineRatesPayload(badPayload),
            throwsA(
              isA<Failure>().having(
                (f) => f.code,
                'code',
                FailureCode.validation,
              ),
            ),
            reason: 'Payload $badPayload should fail validation',
          );
        }
      },
    );
  });
}
