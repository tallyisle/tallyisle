import 'failure.dart';

enum RoundingMode { halfUp, floor, down }

BigInt powerOfTen(int scale) {
  if (scale < 0 || scale > 30) {
    throw const Failure(FailureCode.validation, '精度须在 0–30 之间');
  }
  return BigInt.from(10).pow(scale);
}

BigInt divideRounded(BigInt numerator, BigInt denominator, RoundingMode mode) {
  if (denominator == BigInt.zero) {
    throw const Failure(FailureCode.validation, '分母不能为零');
  }
  if (denominator.isNegative) {
    numerator = -numerator;
    denominator = -denominator;
  }
  final magnitude = numerator.abs();
  var quotient = magnitude ~/ denominator;
  final remainder = magnitude % denominator;
  switch (mode) {
    case RoundingMode.halfUp:
      if (remainder * BigInt.two >= denominator) quotient += BigInt.one;
    case RoundingMode.floor:
      if (numerator.isNegative && remainder != BigInt.zero)
        quotient += BigInt.one;
    case RoundingMode.down:
      break;
  }
  return numerator.isNegative ? -quotient : quotient;
}

final class DecimalValue {
  DecimalValue(this.coefficient, this.scale) {
    powerOfTen(scale);
  }
  final BigInt coefficient;
  final int scale;

  factory DecimalValue.parse(String text) {
    if (!RegExp(r'^-?[0-9]+(?:\.[0-9]+)?$').hasMatch(text)) {
      throw const Failure(FailureCode.validation, '请输入十进制金额');
    }
    final parts = text.split('.');
    final scale = parts.length == 2 ? parts[1].length : 0;
    powerOfTen(scale);
    return DecimalValue(BigInt.parse(parts.join()), scale);
  }

  BigInt unitsAt(int targetScale, {RoundingMode? rounding}) {
    powerOfTen(targetScale);
    if (targetScale >= scale)
      return coefficient * powerOfTen(targetScale - scale);
    final denominator = powerOfTen(scale - targetScale);
    if (rounding == null) {
      if (coefficient.remainder(denominator) != BigInt.zero) {
        throw const Failure(FailureCode.scaleMismatch, '金额超出指定小数位，请显式指定舍入');
      }
      return coefficient ~/ denominator;
    }
    return divideRounded(coefficient, denominator, rounding);
  }
}

final class Money {
  Money(this.units, this.scale, this.currency) {
    powerOfTen(scale);
    if (!RegExp(r'^[A-Z]{3,8}$').hasMatch(currency)) {
      throw const Failure(FailureCode.validation, '币种代码无效');
    }
  }
  final BigInt units;
  final int scale;
  final String currency;

  factory Money.parse(
    String text, {
    int scale = 2,
    String currency = 'CNY',
    RoundingMode? rounding,
  }) => Money(
    DecimalValue.parse(text).unitsAt(scale, rounding: rounding),
    scale,
    currency,
  );

  /// Ledger amounts are stored as int64 minor units with 2 decimals (ADR-011).
  static const ledgerScale = 2;
  static final _int64Max = BigInt.parse('9223372036854775807');
  static final _int64Min = -_int64Max - BigInt.one;

  factory Money.minor(BigInt units, [String currency = 'CNY']) =>
      Money(units, ledgerScale, currency);

  factory Money.zero([String currency = 'CNY']) =>
      Money(BigInt.zero, ledgerScale, currency);

  /// Value for an int64 `_minor` column; rejects out-of-range or wrong scale.
  BigInt get storageMinor {
    if (scale != ledgerScale) {
      throw const Failure(FailureCode.scaleMismatch, '账务金额必须为两位小数');
    }
    if (units > _int64Max || units < _int64Min) {
      throw const Failure(FailureCode.validation, '金额超出可存储范围');
    }
    return units;
  }

  bool get isZero => units == BigInt.zero;
  bool get isNegative => units.isNegative;
  Money abs() => Money(units.abs(), scale, currency);

  factory Money.fromStorage(String units, int scale, String currency) {
    if (!RegExp(r'^(?:0|-?[1-9][0-9]*)$').hasMatch(units)) {
      throw const Failure(FailureCode.corruptData, '存储的金额格式损坏');
    }
    try {
      return Money(BigInt.parse(units), scale, currency);
    } on Failure {
      throw const Failure(FailureCode.corruptData, '存储的金额精度或币种损坏');
    }
  }

  factory Money.fromJson(Map<String, dynamic> json) {
    if (json['units'] is! String ||
        json['scale'] is! int ||
        json['currency'] is! String) {
      throw const Failure(FailureCode.corruptData, '金额 JSON 必须包含字符串单位');
    }
    return Money.fromStorage(
      json['units'] as String,
      json['scale'] as int,
      json['currency'] as String,
    );
  }

  Map<String, Object> toJson() => {
    'units': units.toString(),
    'scale': scale,
    'currency': currency,
  };

  void _check(Money other) {
    if (scale != other.scale || currency != other.currency) {
      throw const Failure(FailureCode.validation, '币种和精度须一致');
    }
  }

  Money operator +(Money other) {
    _check(other);
    return Money(units + other.units, scale, currency);
  }

  Money operator -(Money other) {
    _check(other);
    return Money(units - other.units, scale, currency);
  }

  Money operator -() => Money(-units, scale, currency);
  Money multiply(DecimalValue value, {required RoundingMode rounding}) => Money(
    divideRounded(units * value.coefficient, powerOfTen(value.scale), rounding),
    scale,
    currency,
  );
  Money divideBy(BigInt divisor, {required RoundingMode rounding}) =>
      Money(divideRounded(units, divisor, rounding), scale, currency);

  String get decimal {
    if (scale == 0) return units.toString();
    final digits = units.abs().toString().padLeft(scale + 1, '0');
    return '${units.isNegative ? '-' : ''}${digits.substring(0, digits.length - scale)}.${digits.substring(digits.length - scale)}';
  }

  @override
  bool operator ==(Object other) =>
      other is Money &&
      units == other.units &&
      scale == other.scale &&
      currency == other.currency;
  @override
  int get hashCode => Object.hash(units, scale, currency);
  @override
  String toString() => '$currency $decimal';
}
