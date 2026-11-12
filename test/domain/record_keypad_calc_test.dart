import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/core/failure.dart';
import 'package:tallyisle/domain/rules/record_keypad_calc.dart';

void main() {
  group('RecordKeypadCalc — input editing rules (ledger-catalog §5)', () {
    String typeSequence(Iterable<String> keys, {String initial = ''}) {
      var expr = initial;
      for (final k in keys) {
        expr = applyKeypadKey(expr, k);
      }
      return expr;
    }

    test('handles leading zero, 00, and decimal point entry cleanly', () {
      expect(typeSequence(['0', '0']), '0');
      expect(typeSequence(['00']), '0');
      expect(typeSequence(['0', '5']), '5');
      expect(typeSequence(['0', '.', '5']), '0.5');
      expect(typeSequence(['.', '8']), '0.8');
      expect(typeSequence(['5', '00']), '500');
      expect(typeSequence(['1', '.', '00']), '1.00');
      expect(typeSequence(['1', '.', '2', '00']), '1.20');
      expect(typeSequence(['1', '2', '+', '0', '5']), '12+5');
      expect(typeSequence(['1', '2', '+', '.']), '12+0.');
    });

    test(
      'prevents multiple decimal points and caps fractional digits at 2 per operand',
      () {
        // KV rule: 2.345 -> truncated/blocked at 2.34
        expect(typeSequence(['2', '.', '3', '4', '5']), '2.34');
        expect(typeSequence(['1', '2', '.', '5', '.', '8']), '12.58');
        expect(
          typeSequence([
            '1',
            '2',
            '.',
            '5',
            '+',
            '3',
            '.',
            '8',
            '.',
            '9',
            '×',
            '2',
          ]),
          '12.5+3.89×2',
        );
      },
    );

    test(
      'replaces consecutive operators and handles leading operators cleanly',
      () {
        expect(typeSequence(['+']), '0+');
        expect(typeSequence(['*']), '0×');
        expect(typeSequence(['/']), '0÷');
        expect(typeSequence(['1', '2', '+', '-']), '12-');
        expect(typeSequence(['1', '2', '-', '*', '/']), '12÷');
        expect(typeSequence(['1', '2', '.', '+']), '12+');
      },
    );

    test('supports BACKSPACE, CLEAR, and in-place EQUALS', () {
      expect(
        typeSequence(['1', '2', '.', '5', 'BACKSPACE', 'BACKSPACE']),
        '12',
      );
      expect(typeSequence(['9', 'BACKSPACE', 'BACKSPACE']), '');
      expect(typeSequence(['1', '2', '+', '8', 'CLEAR']), '');
      expect(
        typeSequence(['1', '2', '.', '5', '+', '7', '.', '5', 'EQUALS']),
        '20.00',
      );
    });

    test(
      'hasPendingOperator distinguishes plain numbers from active expressions',
      () {
        expect(hasPendingOperator(''), isFalse);
        expect(hasPendingOperator('0'), isFalse);
        expect(hasPendingOperator('128.50'), isFalse);
        expect(hasPendingOperator('-25.00'), isFalse);

        expect(hasPendingOperator('12+'), isTrue);
        expect(hasPendingOperator('12+8'), isTrue);
        expect(hasPendingOperator('10*3'), isTrue);
        expect(hasPendingOperator('10/2'), isTrue);
        expect(hasPendingOperator('-5+12'), isTrue);
      },
    );
  });

  group(
    'RecordKeypadCalc — BigInt rational evaluation & rounding (DR-002/003)',
    () {
      test(
        'evaluates strictly left-to-right without operator precedence (KV-01)',
        () {
          // 2 + 3 * 4 -> (2 + 3) * 4 = 20.00
          expect(evaluateKeypadExpression('2+3*4').formatted, '20.00');
          // 10 + 2 × 3 -> (10 + 2) × 3 = 36.00
          expect(evaluateKeypadExpression('10 + 2 × 3').formatted, '36.00');
          // 100 - 40 ÷ 2 -> (100 - 40) ÷ 2 = 30.00
          expect(evaluateKeypadExpression('100-40÷2').formatted, '30.00');
          // 8 × 3 - 4 ÷ 5 -> ((8 × 3) - 4) ÷ 5 = 20 ÷ 5 = 4.00
          expect(evaluateKeypadExpression('8×3-4÷5').formatted, '4.00');
        },
      );

      test('preserves exact BigInt rational precision with zero float drift', () {
        expect(
          evaluateKeypadExpression('0.1+0.2').rawMinor,
          BigInt.from(30),
        ); // 0.30
        expect(evaluateKeypadExpression('0.1+0.2').formatted, '0.30');
        expect(evaluateKeypadExpression('10÷3×3').formatted, '10.00');
        expect(evaluateKeypadExpression('1÷7×7').formatted, '1.00');
        expect(evaluateKeypadExpression('0.1+0.1+0.1-0.3').formatted, '0.00');

        // Large 11-integer-digit boundary arithmetic where IEEE-754 double can drift
        expect(
          evaluateKeypadExpression('88888888887.99+0.01').rawMinor,
          BigInt.parse('8888888888800'),
        );
        expect(
          evaluateKeypadExpression('88888888888.00÷3×3').rawMinor,
          BigInt.parse('8888888888800'),
        );
      });

      test('applies HALF_UP rounding to 2 decimal places accurately', () {
        expect(evaluateKeypadExpression('10÷3').formatted, '3.33');
        expect(evaluateKeypadExpression('20÷3').formatted, '6.67');
        expect(evaluateKeypadExpression('1÷6').formatted, '0.17');
        expect(
          evaluateKeypadExpression('1÷8').formatted,
          '0.13',
        ); // 0.125 -> 0.13
        expect(
          evaluateKeypadExpression('5÷8').formatted,
          '0.63',
        ); // 0.625 -> 0.63
        expect(
          evaluateKeypadExpression('1÷200').formatted,
          '0.01',
        ); // 0.005 -> 0.01
        expect(evaluateKeypadExpression('1÷201').formatted, '0.00'); // < 0.005
      });

      test('handles division by zero safely as 0.00 without throwing', () {
        final res = evaluateKeypadExpression('10÷0');
        expect(res.dividedByZero, isTrue);
        expect(res.rawMinor, BigInt.zero);
        expect(res.formatted, '0.00');

        expect(evaluateKeypadExpression('12+8÷0').formatted, '0.00');
        expect(evaluateKeypadExpression('10÷0+5.25').formatted, '5.25');
        expect(confirmKeypadAmount('99÷0').decimal, '0.00');
      });

      test('trims trailing operators and decimal points on confirm/eval', () {
        expect(evaluateKeypadExpression('12.5+').formatted, '12.50');
        expect(evaluateKeypadExpression('12.').formatted, '12.00');
        expect(confirmKeypadAmount('38.6×').decimal, '38.60');
        expect(confirmKeypadAmount('').decimal, '0.00');
      });

      test(
        'enforces upper cap 88888888888.00 and clamps/rejects negative amounts',
        () {
          // Exact upper bound passes
          final atCap = confirmKeypadAmount('88888888888.00');
          expect(atCap.storageMinor, BigInt.parse('8888888888800'));

          // 88888888888.01 exceeds cap: clamped in display, rejected in confirm
          final overCap = evaluateKeypadExpression('88888888888+0.01');
          expect(overCap.exceededMax, isTrue);
          expect(overCap.clampedMinor, BigInt.parse('8888888888800'));
          expect(overCap.formatted, '88888888888.00');
          expect(
            () => confirmKeypadAmount('88888888888.01'),
            throwsA(isA<Failure>()),
          );

          // Negative result: clamped to 0.00 on EQUALS, rejected in confirm
          final neg = evaluateKeypadExpression('5-12.5');
          expect(neg.isNegative, isTrue);
          expect(neg.rawMinor, BigInt.from(-750));
          expect(neg.clampedMinor, BigInt.zero);
          expect(applyKeypadKey('5-12.5', 'EQUALS'), '0.00');
          expect(() => confirmKeypadAmount('5-12.5'), throwsA(isA<Failure>()));
        },
      );
    },
  );
}
