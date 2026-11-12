import '../../core/failure.dart';
import '../../core/money.dart';

/// Original keyboard upper bound: `88888888888.00` (`8888888888800` minor units,
/// `docs/reference/ledger-catalog.md` §5, DR-003).
final BigInt maxKeypadAmountMinor = BigInt.parse('8888888888800');
final Money maxKeypadAmount = Money.minor(maxKeypadAmountMinor);

/// Default decimal precision per entered operand (`ledger-catalog.md` §5).
const int defaultMaxKeypadDecimals = 2;

/// Maximum integer digits per operand token before blocking further digit entry
/// (`ledger-catalog.md` §5 single-number length guard).
const int maxOperandIntegerDigits = 15;

/// Exact rational number `numerator / denominator` backed purely by [BigInt]
/// (`denominator > 0`, reduced by `gcd`, zero IEEE-754 `double` usage).
final class BigRational {
  factory BigRational(BigInt numerator, BigInt denominator) {
    if (denominator == BigInt.zero) {
      throw const Failure(FailureCode.validation, '分母不能为零');
    }
    if (numerator == BigInt.zero) {
      return zero;
    }
    var num = numerator;
    var den = denominator;
    if (den.isNegative) {
      num = -num;
      den = -den;
    }
    final g = num.abs().gcd(den);
    return BigRational._(num ~/ g, den ~/ g);
  }

  const BigRational._(this.numerator, this.denominator);

  static final BigRational zero = BigRational._(BigInt.zero, BigInt.one);

  /// Parses a signed or unsigned decimal token (e.g. `'12.5'`, `'.5'`, `'12.'`,
  /// `'-0.125'`) into an exact [BigRational] without floating-point math.
  factory BigRational.parseDecimal(String rawToken) {
    final token = rawToken.trim();
    if (token.isEmpty) return zero;

    var negative = false;
    var idx = 0;
    if (token.startsWith('-')) {
      negative = true;
      idx = 1;
    } else if (token.startsWith('+')) {
      idx = 1;
    }

    final body = token.substring(idx);
    if (body.isEmpty || body == '.') return zero;

    final parts = body.split('.');
    if (parts.length > 2) {
      throw const Failure(FailureCode.validation, '请输入有效的金额或算式');
    }
    final intPart = parts[0].isEmpty ? '0' : parts[0];
    final fracPart = parts.length == 2 ? parts[1] : '';
    if (!RegExp(r'^[0-9]+$').hasMatch(intPart) ||
        (fracPart.isNotEmpty && !RegExp(r'^[0-9]+$').hasMatch(fracPart))) {
      throw const Failure(FailureCode.validation, '请输入有效的金额或算式');
    }

    final coeffAbs = BigInt.parse('$intPart$fracPart');
    final coeff = negative ? -coeffAbs : coeffAbs;
    final den = BigInt.from(10).pow(fracPart.length);
    return BigRational(coeff, den);
  }

  final BigInt numerator;
  final BigInt denominator;

  bool get isZero => numerator == BigInt.zero;
  bool get isNegative => numerator.isNegative;

  BigRational operator +(BigRational other) => BigRational(
    numerator * other.denominator + other.numerator * denominator,
    denominator * other.denominator,
  );

  BigRational operator -(BigRational other) => BigRational(
    numerator * other.denominator - other.numerator * denominator,
    denominator * other.denominator,
  );

  BigRational operator *(BigRational other) =>
      BigRational(numerator * other.numerator, denominator * other.denominator);

  /// Divides by [divisor]; returns [zero] safely when [divisor] is zero
  /// (`ledger-catalog.md` §5: division by zero evaluates to `0`).
  BigRational divideOrZero(BigRational divisor) {
    if (divisor.isZero) return zero;
    return BigRational(
      numerator * divisor.denominator,
      denominator * divisor.numerator,
    );
  }

  /// Rounds this rational value to 2-decimal minor units (cents) via `HALF_UP`.
  BigInt toMinorHalfUp() => divideRounded(
    numerator * BigInt.from(100),
    denominator,
    RoundingMode.halfUp,
  );

  @override
  bool operator ==(Object other) =>
      other is BigRational &&
      numerator == other.numerator &&
      denominator == other.denominator;

  @override
  int get hashCode => Object.hash(numerator, denominator);

  @override
  String toString() => '$numerator/$denominator';
}

/// Evaluation outcome of a `RecordKeyboard` expression (`ledger-catalog.md` §5).
final class KeypadEvalResult {
  const KeypadEvalResult({
    required this.rawMinor,
    required this.clampedMinor,
    required this.isNegative,
    required this.exceededMax,
    required this.dividedByZero,
  });

  static final KeypadEvalResult zero = KeypadEvalResult(
    rawMinor: BigInt.zero,
    clampedMinor: BigInt.zero,
    isNegative: false,
    exceededMax: false,
    dividedByZero: false,
  );

  /// Exact `HALF_UP` rounded minor units before `[0, 88888888888.00]` clamping.
  final BigInt rawMinor;

  /// Minor units clamped into `[0, maxKeypadAmountMinor]`.
  final BigInt clampedMinor;

  /// Whether [rawMinor] evaluated below `0`.
  final bool isNegative;

  /// Whether [rawMinor] exceeded `88888888888.00` (`8888888888800` minor).
  final bool exceededMax;

  /// Whether any `÷ 0` step occurred during evaluation.
  final bool dividedByZero;

  Money get money => Money.minor(clampedMinor);
  Money get rawMoney => Money.minor(rawMinor);

  /// Clamped 2-decimal representation (e.g. `'20.00'`, `'88888888888.00'`).
  String get formatted => Money.minor(clampedMinor).decimal;

  /// Raw signed 2-decimal representation (e.g. `'-5.00'`).
  String get rawFormatted => Money.minor(rawMinor).decimal;
}

bool _isCanonicalOp(String ch) =>
    ch == '+' || ch == '-' || ch == '×' || ch == '÷';

bool _isDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;

/// Normalizes ASCII/Unicode operator aliases and strips whitespace.
String sanitizeKeypadExpression(String raw) => raw
    .replaceAll(RegExp(r'\s+'), '')
    .replaceAll('*', '×')
    .replaceAll('/', '÷')
    .replaceAll('−', '-');

/// Maps an operator token (`+`, `-`, `×`, `*`, `÷`, `/`) to its canonical display symbol.
String? canonicalKeypadOperator(String key) => switch (key) {
  '+' => '+',
  '-' || '−' => '-',
  '×' || '*' => '×',
  '÷' || '/' => '÷',
  _ => null,
};

/// Returns `true` when [expr] contains a binary operator so the primary keypad
/// button should show `'='` instead of `'保存'`.
bool hasPendingOperator(String expr) {
  final clean = sanitizeKeypadExpression(expr);
  if (clean.isEmpty) return false;
  final start = (clean.startsWith('-') || clean.startsWith('+')) ? 1 : 0;
  if (start >= clean.length) return false;
  for (var i = start; i < clean.length; i++) {
    if (_isCanonicalOp(clean[i])) return true;
  }
  return false;
}

int _lastBinaryOperatorIndex(String clean) {
  final start = (clean.startsWith('-') || clean.startsWith('+')) ? 1 : 0;
  for (var i = clean.length - 1; i >= start; i--) {
    if (_isCanonicalOp(clean[i])) return i;
  }
  return -1;
}

/// Applies a single `RecordKeyboard` key press to [currentExpr] following
/// `ledger-catalog.md` §5 editing rules:
/// - Digits `'0'`..`'9'` (and `'00'`), `'.'`, `'+'`, `'-'`, `'×'`/`'*'`, `'÷'`/`'/'`,
///   `'BACKSPACE'`, `'CLEAR'`, `'EQUALS'`.
/// - Single decimal point per operand, max [maxDecimals] fractional digits.
/// - Consecutive operators replace the trailing operator (`'12+'` + `'-'` -> `'12-'`).
/// - Leading `'0'` replacement (`'0'` + `'5'` -> `'5'`, `'0.'` preserved).
String applyKeypadKey(
  String currentExpr,
  String key, {
  int maxDecimals = defaultMaxKeypadDecimals,
}) {
  var expr = sanitizeKeypadExpression(currentExpr);
  final upper = key.trim().toUpperCase();

  if (upper == 'CLEAR') {
    return '';
  }
  if (upper == 'BACKSPACE') {
    if (expr.isEmpty) return '';
    final next = expr.substring(0, expr.length - 1);
    if (next == '-' || next == '+') return '';
    return next;
  }
  if (upper == 'EQUALS' || key == '=') {
    if (expr.isEmpty) return '0.00';
    return evaluateKeypadExpression(expr).formatted;
  }

  final op = canonicalKeypadOperator(key.trim());
  if (op != null) {
    if (expr.isEmpty) return '0$op';
    if (expr.endsWith('.')) {
      expr = expr.substring(0, expr.length - 1);
      if (expr.isEmpty || expr == '-' || expr == '+') return '0$op';
    }
    while (expr.isNotEmpty && _isCanonicalOp(expr[expr.length - 1])) {
      expr = expr.substring(0, expr.length - 1);
    }
    if (expr.isEmpty) return '0$op';
    return '$expr$op';
  }

  if (key == '.') {
    if (maxDecimals <= 0) return expr;
    final opIdx = _lastBinaryOperatorIndex(expr);
    final tokenStart = opIdx >= 0
        ? opIdx + 1
        : ((expr.startsWith('-') || expr.startsWith('+')) ? 1 : 0);
    final currentOperand = expr.substring(tokenStart);
    if (currentOperand.contains('.')) return expr;
    if (currentOperand.isEmpty) return '${expr}0.';
    return '$expr.';
  }

  if (key == '00') {
    final once = applyKeypadKey(expr, '0', maxDecimals: maxDecimals);
    return applyKeypadKey(once, '0', maxDecimals: maxDecimals);
  }

  if (key.length == 1 && _isDigit(key.codeUnitAt(0))) {
    final opIdx = _lastBinaryOperatorIndex(expr);
    final tokenStart = opIdx >= 0
        ? opIdx + 1
        : ((expr.startsWith('-') || expr.startsWith('+')) ? 1 : 0);
    final prefix = expr.substring(0, tokenStart);
    final currentOperand = expr.substring(tokenStart);

    if (currentOperand.contains('.')) {
      final dotIdx = currentOperand.indexOf('.');
      final fracLen = currentOperand.length - dotIdx - 1;
      if (fracLen >= maxDecimals) return expr;
      return '$expr$key';
    }

    if (currentOperand == '0') {
      if (key == '0') return expr;
      return '$prefix$key';
    }

    if (currentOperand.length >= maxOperandIntegerDigits) return expr;
    return '$expr$key';
  }

  throw Failure(FailureCode.validation, '不支持的键盘按键：$key');
}

/// Evaluates [rawExpr] sequentially **left-to-right** (`10 + 2 × 3 = 36`)
/// using exact [BigRational] arithmetic and `HALF_UP` rounding to 2 decimals
/// (`docs/reference/ledger-catalog.md` §5, DR-002/003).
KeypadEvalResult evaluateKeypadExpression(String rawExpr) {
  var expr = sanitizeKeypadExpression(rawExpr);
  if (expr.isEmpty) return KeypadEvalResult.zero;

  // Trim trailing binary operators and trailing decimal points on confirm/eval.
  while (expr.isNotEmpty &&
      (_isCanonicalOp(expr[expr.length - 1]) || expr.endsWith('.'))) {
    expr = expr.substring(0, expr.length - 1);
  }
  if (expr.isEmpty) return KeypadEvalResult.zero;

  var i = 0;
  var leadingNegative = false;
  while (i < expr.length && (expr[i] == '+' || expr[i] == '-')) {
    leadingNegative = expr[i] == '-';
    i++;
  }
  if (i >= expr.length) return KeypadEvalResult.zero;

  String readUnsignedNumber() {
    final start = i;
    var seenDot = false;
    var seenDigit = false;
    while (i < expr.length) {
      final ch = expr[i];
      if (_isDigit(ch.codeUnitAt(0))) {
        seenDigit = true;
        i++;
      } else if (ch == '.') {
        if (seenDot) {
          throw const Failure(FailureCode.validation, '请输入有效的金额或算式');
        }
        seenDot = true;
        i++;
      } else {
        break;
      }
    }
    if (!seenDigit) {
      throw const Failure(FailureCode.validation, '请输入有效的金额或算式');
    }
    return expr.substring(start, i);
  }

  final firstDigits = readUnsignedNumber();
  var acc = BigRational.parseDecimal(
    leadingNegative ? '-$firstDigits' : firstDigits,
  );
  var dividedByZero = false;

  while (i < expr.length) {
    if (!_isCanonicalOp(expr[i])) {
      throw const Failure(FailureCode.validation, '请输入有效的金额或算式');
    }
    // Consecutive operators collapse to the last operator (`ledger-catalog.md` §5).
    var op = expr[i];
    while (i < expr.length && _isCanonicalOp(expr[i])) {
      op = expr[i];
      i++;
    }
    if (i >= expr.length) break;

    final rhsDigits = readUnsignedNumber();
    final rhs = BigRational.parseDecimal(rhsDigits);
    switch (op) {
      case '+':
        acc = acc + rhs;
      case '-':
        acc = acc - rhs;
      case '×':
        acc = acc * rhs;
      case '÷':
        if (rhs.isZero) {
          dividedByZero = true;
          acc = BigRational.zero;
        } else {
          acc = acc.divideOrZero(rhs);
        }
    }
  }

  final rawMinor = acc.toMinorHalfUp();
  final isNegative = rawMinor < BigInt.zero;
  final exceededMax = rawMinor > maxKeypadAmountMinor;
  final clampedMinor = isNegative
      ? BigInt.zero
      : (exceededMax ? maxKeypadAmountMinor : rawMinor);

  return KeypadEvalResult(
    rawMinor: rawMinor,
    clampedMinor: clampedMinor,
    isNegative: isNegative,
    exceededMax: exceededMax,
    dividedByZero: dividedByZero,
  );
}

/// Evaluates and validates [rawExpr] for saving a bill (`ledger-catalog.md` §5):
/// - Auto-trims trailing operators (`12.5+` -> `12.50`) and evaluates pending ops.
/// - Rejects negative results (`< 0`) and results exceeding `88888888888.00`.
Money confirmKeypadAmount(String rawExpr, {String currency = 'CNY'}) {
  final res = evaluateKeypadExpression(rawExpr);
  if (res.isNegative) {
    throw const Failure(FailureCode.validation, '金额不能小于 0');
  }
  if (res.exceededMax) {
    throw const Failure(FailureCode.validation, '金额不能超过 88888888888.00');
  }
  return Money(res.rawMinor, Money.ledgerScale, currency);
}
