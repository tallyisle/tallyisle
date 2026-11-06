import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/money.dart';
import 'package:tallyisle/core/failure.dart';

void main() {
  test(
    'MV-01: decimal addition never passes through binary floating point',
    () {
      expect(
        (Money.parse('0.10') + Money.parse('0.20')).units.toString(),
        '30',
      );
      expect((Money.parse('0.10') + Money.parse('0.20')).decimal, '0.30');
    },
  );
  test('MV-02/03: signed HALF_UP, FLOOR and DOWN have explicit results', () {
    for (final vector in [
      ('1.005', RoundingMode.halfUp, '1.01'),
      ('-1.005', RoundingMode.halfUp, '-1.01'),
      ('-1.001', RoundingMode.floor, '-1.01'),
      ('-1.001', RoundingMode.down, '-1.00'),
      ('1.001', RoundingMode.floor, '1.00'),
      ('-0.005', RoundingMode.halfUp, '-0.01'),
    ]) {
      expect(Money.parse(vector.$1, rounding: vector.$2).decimal, vector.$3);
    }
  });
  test('MV-04: JSON retains 2^53+1 and arbitrary signed integer units', () {
    for (final units in [
      '9007199254740993',
      '-9007199254740993',
      '999999999999999999999999999999999999',
    ]) {
      final money = Money.fromStorage(units, 2, 'CNY');
      final text = jsonEncode(money.toJson());
      expect(jsonDecode(text)['units'], isA<String>());
      expect(Money.fromJson(jsonDecode(text)), money);
      expect(Money.parse(money.decimal), money);
    }
    final huge = Money.fromStorage('9007199254740993', 2, 'CNY');
    expect((huge + huge).units.toString(), '18014398509481986');
  });
  test('MV-05: invalid input and zero division are errors', () {
    for (final text in ['', 'NaN', 'Infinity', '1,234', ' 1', '1e3', '--1']) {
      expect(() => Money.parse(text), throwsA(isA<Failure>()));
    }
    expect(
      () => divideRounded(BigInt.one, BigInt.zero, RoundingMode.down),
      throwsA(isA<Failure>()),
    );
    expect(
      () => Money.parse('1') + Money.parse('1', currency: 'USD'),
      throwsA(isA<Failure>()),
    );
    expect(
      () => Money.parse('1') + Money.parse('1', scale: 3),
      throwsA(isA<Failure>()),
    );
  });
  test(
    'MV-06: exact parsing rejects loss and canonical storage rejects malformed text',
    () {
      expect(
        () => Money.parse('1.001'),
        throwsA(
          isA<Failure>().having(
            (e) => e.code,
            'code',
            FailureCode.scaleMismatch,
          ),
        ),
      );
      expect(Money.parse('1.000').decimal, '1.00');
      for (final units in ['-0', '00', '+1', '01', '1.0', '']) {
        expect(
          () => Money.fromStorage(units, 2, 'CNY'),
          throwsA(isA<Failure>()),
        );
      }
      expect(
        () => Money.fromJson({'units': 8550, 'scale': 2, 'currency': 'CNY'}),
        throwsA(isA<Failure>()),
      );
    },
  );
  test('MV-07: division preserves the requested rounding node', () {
    expect(
      Money.parse(
        '1000',
      ).divideBy(BigInt.from(6), rounding: RoundingMode.floor).decimal,
      '166.66',
    );
    expect(
      Money.parse(
        '1000',
      ).divideBy(BigInt.from(6), rounding: RoundingMode.halfUp).decimal,
      '166.67',
    );
    expect(
      Money.parse(
        '1001',
      ).divideBy(BigInt.from(6), rounding: RoundingMode.halfUp).decimal,
      '166.83',
    );
    expect(
      Money.parse('2.00')
          .multiply(DecimalValue.parse('0.125'), rounding: RoundingMode.halfUp)
          .decimal,
      '0.25',
    );
    expect(
      divideRounded(BigInt.from(5), BigInt.from(-2), RoundingMode.halfUp),
      BigInt.from(-3),
    );
  });
}
