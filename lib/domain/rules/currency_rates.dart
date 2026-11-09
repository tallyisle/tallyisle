import '../../core/failure.dart';
import '../../core/money.dart';
import '../ledger/record_extra.dart';
import 'asset_overview.dart';

/// App base (anchor) currency. Rates in the `currency` table are relative to it.
const baseCurrency = 'CNY';

/// Common currencies offered when adding one (code, Chinese name, symbol).
const presetCurrencies = <(String, String, String)>[
  ('USD', '美元', r'$'),
  ('EUR', '欧元', '€'),
  ('JPY', '日元', '¥'),
  ('HKD', '港币', r'HK$'),
  ('MOP', '澳门元', r'MOP$'),
  ('TWD', '新台币', r'NT$'),
  ('GBP', '英镑', '£'),
  ('KRW', '韩元', '₩'),
  ('SGD', '新加坡元', r'S$'),
  ('AUD', '澳元', r'A$'),
  ('CAD', '加元', r'C$'),
  ('CHF', '瑞士法郎', 'CHF'),
  ('THB', '泰铢', '฿'),
  ('MYR', '马来西亚林吉特', 'RM'),
  ('RUB', '俄罗斯卢布', '₽'),
  ('NZD', '新西兰元', r'NZ$'),
  ('VND', '越南盾', '₫'),
  ('PHP', '菲律宾比索', '₱'),
  ('IDR', '印尼盾', 'Rp'),
  ('INR', '印度卢比', '₹'),
  ('AED', '阿联酋迪拉姆', 'AED'),
];

const _rateScale = 12;

String _trim(String s) {
  if (!s.contains('.')) return s;
  var t = s.replaceFirst(RegExp(r'0+$'), '');
  if (t.endsWith('.')) t = t.substring(0, t.length - 1);
  return t;
}

String _decimalString(BigInt coefficient, int scale) {
  final negative = coefficient.isNegative;
  var digits = coefficient.abs().toString().padLeft(scale + 1, '0');
  final text = scale == 0
      ? digits
      : '${digits.substring(0, digits.length - scale)}.'
            '${digits.substring(digits.length - scale)}';
  return '${negative ? '-' : ''}${_trim(text)}';
}

/// "1 USD = 7.10 CNY" (user input `price`) -> stored `rate_to_anchor`
/// (= amount of that currency per 1 CNY), HALF_UP to 12 decimals.
String rateToAnchorFromPrice(String price) {
  final DecimalValue p;
  try {
    p = DecimalValue.parse(price.trim());
  } on Failure {
    throw const Failure(FailureCode.validation, '汇率须为正数');
  }
  if (p.coefficient <= BigInt.zero) {
    throw const Failure(FailureCode.validation, '汇率须为正数');
  }
  // 1 / (c / 10^s) = 10^s / c, expressed with _rateScale decimals.
  final coefficient = divideRounded(
    powerOfTen(p.scale + _rateScale),
    p.coefficient,
    RoundingMode.halfUp,
  );
  if (coefficient == BigInt.zero) {
    throw const Failure(FailureCode.validation, '汇率过大');
  }
  return _decimalString(coefficient, _rateScale);
}

/// Stored `rate_to_anchor` -> price of 1 unit in CNY, HALF_UP to 4 decimals.
String priceFromRateToAnchor(String rateToAnchor) {
  final r = DecimalValue.parse(rateToAnchor);
  if (r.coefficient <= BigInt.zero) return '0';
  final coefficient = divideRounded(
    powerOfTen(r.scale + 4),
    r.coefficient,
    RoundingMode.halfUp,
  );
  return _decimalString(coefficient, 4);
}

/// Builds the `extra_info.curr` snapshot for an income/expense bill entered as
/// [sourceMinor] in [source], booked as [assetMinor] in the account currency
/// [account]. Returns null when every currency is the base currency.
CurrencySnapshot? billSnapshot({
  required String source,
  required BigInt sourceMinor,
  required String account,
  required BigInt assetMinor,
  required RateTable rates,
}) {
  final sc = normalizeCurrency(source) ?? baseCurrency;
  final ac = normalizeCurrency(account) ?? baseCurrency;
  if (sc == baseCurrency && ac == baseCurrency) return null;
  final bm = ac == baseCurrency
      ? assetMinor
      : sc == baseCurrency
      ? sourceMinor
      : rates.convert(assetMinor, ac, baseCurrency);
  return CurrencySnapshot(
    sourceCode: sc,
    sourceGross: sourceMinor,
    assetCode: ac,
    assetNet: assetMinor,
    baseCode: baseCurrency,
    baseAmount: bm,
  );
}
