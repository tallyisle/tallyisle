import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/domain/rules/currency_rates.dart';

void main() {
  group('WorldCurrencySpec & worldCurrencies ISO 4217 catalog', () {
    test('contains >= 150 unique valid 3-letter uppercase ISO 4217 codes', () {
      expect(worldCurrencies.length, greaterThanOrEqualTo(150));

      final seenCodes = <String>{};
      final isoPattern = RegExp(r'^[A-Z]{3}$');

      for (final spec in worldCurrencies) {
        expect(
          isoPattern.hasMatch(spec.code),
          isTrue,
          reason: 'Invalid ISO 4217 code: ${spec.code}',
        );
        expect(
          spec.code,
          isNot(baseCurrency),
          reason: 'Base currency CNY should not be in foreign worldCurrencies',
        );
        expect(
          seenCodes.add(spec.code),
          isTrue,
          reason: 'Duplicate currency code found: ${spec.code}',
        );
        expect(
          spec.name.trim(),
          isNotEmpty,
          reason: 'Empty Chinese name for ${spec.code}',
        );
        expect(
          spec.name.trim().length,
          lessThanOrEqualTo(30),
          reason: 'Name exceeds 30 chars for ${spec.code}',
        );
        expect(
          spec.symbol.trim(),
          isNotEmpty,
          reason: 'Empty symbol for ${spec.code}',
        );
      }

      expect(seenCodes.length, worldCurrencies.length);
    });

    test('covers all required global fiat currencies across continents', () {
      const requiredCodes = <String>[
        'TRY',
        'USD',
        'EUR',
        'JPY',
        'HKD',
        'MOP',
        'TWD',
        'GBP',
        'KRW',
        'SGD',
        'THB',
        'MYR',
        'AUD',
        'CAD',
        'CHF',
        'AED',
        'SAR',
        'QAR',
        'KWD',
        'BHD',
        'OMR',
        'JOD',
        'ILS',
        'EGP',
        'RUB',
        'NZD',
        'VND',
        'PHP',
        'IDR',
        'INR',
        'PKR',
        'BDT',
        'LKR',
        'NPR',
        'MVR',
        'KZT',
        'UZS',
        'GEL',
        'AMD',
        'AZN',
        'MNT',
        'LAK',
        'KHR',
        'MMK',
        'BND',
        'FJD',
        'SEK',
        'NOK',
        'DKK',
        'ISK',
        'PLN',
        'CZK',
        'HUF',
        'RON',
        'BGN',
        'RSD',
        'UAH',
        'BYN',
        'MXN',
        'BRL',
        'ARS',
        'CLP',
        'COP',
        'PEN',
        'UYU',
        'CRC',
        'DOP',
        'ZAR',
        'NGN',
        'KES',
        'MAD',
        'TND',
        'DZD',
        'ETB',
        'GHS',
        'TZS',
        'UGX',
        'MUR',
      ];
      for (final code in requiredCodes) {
        expect(
          findWorldCurrency(code),
          isNotNull,
          reason: 'Missing required ISO 4217 currency $code',
        );
      }

      // Backward compatibility: presetCurrencies entries match worldCurrencies
      expect(presetCurrencies, isNotEmpty);
      for (final (code, name, symbol) in presetCurrencies) {
        final spec = findWorldCurrency(code);
        expect(spec, isNotNull, reason: 'Preset $code missing from catalog');
        expect(spec!.name, name);
        expect(spec.symbol, symbol);
      }
    });

    test('TRY (土耳其里拉, ₺) lookup and multi-keyword search work cleanly', () {
      final trySpec = findWorldCurrency('TRY');
      expect(trySpec, isNotNull);
      expect(trySpec!.code, 'TRY');
      expect(trySpec.name, '土耳其里拉');
      expect(trySpec.symbol, '₺');
      expect(trySpec.popular, isTrue);
      expect(findWorldCurrency('  try '), equals(trySpec));
      expect(findWorldCurrency(null), isNull);
      expect(findWorldCurrency(''), isNull);
      expect(findWorldCurrency('UNKNOWN'), isNull);

      for (final query in ['土耳其', '里拉', 'try', 'TRY', 'turkey', 'lira', '₺']) {
        final hits = searchWorldCurrencies(query);
        expect(hits, isNotEmpty, reason: 'Expected hits for "$query"');
        expect(
          hits.first.code,
          'TRY',
          reason: 'Expected TRY first for query "$query"',
        );
      }
    });

    test(
      'defaultCurrencySymbol resolves CNY, ISO specs, and unknown codes',
      () {
        expect(defaultCurrencySymbol('CNY'), '¥');
        expect(defaultCurrencySymbol(' cny '), '¥');
        expect(defaultCurrencySymbol('TRY'), '₺');
        expect(defaultCurrencySymbol('try'), '₺');
        expect(defaultCurrencySymbol('USD'), r'$');
        expect(defaultCurrencySymbol('EUR'), '€');
        expect(defaultCurrencySymbol('GBP'), '£');
        expect(defaultCurrencySymbol('JPY'), '¥');
        expect(defaultCurrencySymbol('KRW'), '₩');
        expect(defaultCurrencySymbol('THB'), '฿');
        expect(defaultCurrencySymbol('CHF'), 'CHF');
        expect(defaultCurrencySymbol('FOOCOIN'), 'FOOCOIN');
        expect(defaultCurrencySymbol('foocoin'), 'FOOCOIN');
        expect(defaultCurrencySymbol(null), '');
        expect(defaultCurrencySymbol(''), '');
        expect(defaultCurrencySymbol('   '), '');
      },
    );

    test(
      'searchWorldCurrencies orders popular first on empty query, sorts remaining by code, and respects excludeCodes',
      () {
        final all = searchWorldCurrencies('');
        expect(all.length, worldCurrencies.length);

        final firstNonPopularIdx = all.indexWhere((c) => !c.popular);
        expect(firstNonPopularIdx, greaterThan(0));
        final popularPart = all.sublist(0, firstNonPopularIdx);
        final remainingPart = all.sublist(firstNonPopularIdx);

        expect(popularPart.every((c) => c.popular), isTrue);
        expect(
          popularPart.map((c) => c.code),
          containsAll(<String>[
            'USD',
            'EUR',
            'JPY',
            'HKD',
            'GBP',
            'THB',
            'KRW',
            'TRY',
          ]),
        );

        expect(remainingPart.every((c) => !c.popular), isTrue);
        final remainingCodes = remainingPart.map((c) => c.code).toList();
        final sortedRemaining = [...remainingCodes]..sort();
        expect(remainingCodes, sortedRemaining);

        final filtered = searchWorldCurrencies(
          '',
          excludeCodes: const {'USD', 'try', 'ZAR'},
        );
        expect(filtered.any((c) => c.code == 'USD'), isFalse);
        expect(filtered.any((c) => c.code == 'TRY'), isFalse);
        expect(filtered.any((c) => c.code == 'ZAR'), isFalse);

        final tryExcludedSearch = searchWorldCurrencies(
          '土耳其',
          excludeCodes: const {'TRY'},
        );
        expect(tryExcludedSearch.any((c) => c.code == 'TRY'), isFalse);
      },
    );
  });
}
