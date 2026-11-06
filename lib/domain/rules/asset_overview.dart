import 'dart:convert';

import '../../core/money.dart';
import '../model/codes.dart';

/// Exchange rates as stored in the `currency` table: `rate_to_anchor` is the
/// amount of that currency per 1 anchor (base) unit (1 USD = 8 CNY -> 0.125).
final class RateTable {
  RateTable(Map<String, String> rates, {this.base = 'CNY'})
    : _rates = {
        for (final e in rates.entries)
          normalizeCurrency(e.key)!: DecimalValue.parse(e.value),
      };

  final String base;
  final Map<String, DecimalValue> _rates;

  /// Converts [minor] from [from] to [to] with HALF_UP to 2 decimals.
  /// Same/blank currency or a missing rate falls back to 1:1 and is reported
  /// through [missing]; a non-positive source rate yields 0 (DR-AST-04).
  BigInt convert(
    BigInt minor,
    String? from,
    String to, {
    Set<String>? missing,
  }) {
    final src = normalizeCurrency(from) ?? base;
    final dst = normalizeCurrency(to) ?? base;
    if (src == dst || minor == BigInt.zero) return minor;
    final s = _rates[src], d = _rates[dst];
    if (s == null || d == null) {
      missing?.add(s == null ? src : dst);
      return minor;
    }
    if (s.coefficient <= BigInt.zero) return BigInt.zero;
    // minor * d / s, both rates exact decimals.
    final numerator = minor * d.coefficient * powerOfTen(s.scale);
    final denominator = s.coefficient * powerOfTen(d.scale);
    return divideRounded(numerator, denominator, RoundingMode.halfUp);
  }
}

/// P-02 (AO-F01): currency codes are compared trimmed and upper-cased.
String? normalizeCurrency(String? code) {
  final c = code?.trim().toUpperCase();
  return c == null || c.isEmpty ? null : c;
}

/// Account data needed by the overview.
final class OverviewAccount {
  const OverviewAccount({
    required this.id,
    required this.type,
    this.subType = -1,
    required this.balanceMinor,
    required this.isEffectiveAsset,
    this.status = AssetStatus.active,
    this.currency,
    this.creditInfo,
  });
  final int id;
  final int type;
  final int subType;
  final BigInt balanceMinor;
  final int isEffectiveAsset;
  final int status;
  final String? currency;
  final String? creditInfo;

  /// Original gate: `type == 4 ? !eff : eff` (ledger-catalog §3).
  bool get counted =>
      type == AssetType.debt ? isEffectiveAsset == 0 : isEffectiveAsset == 1;
}

final class AssetOverview {
  const AssetOverview({
    required this.totalAsset,
    required this.totalLiabilities,
    required this.totalInstallment,
    required this.missingRates,
  });
  final BigInt totalAsset;
  final BigInt totalLiabilities;
  final BigInt totalInstallment;
  final Set<String> missingRates;
  BigInt get netAsset => totalAsset - totalLiabilities;
}

/// Uncredited installment amount of a credit card (docs/modules/asset-overview.md R4):
/// `inst` present -> Σ(b + i) regardless of cb/ci; `inst == []` -> 0;
/// only when `inst` is absent the legacy `installment` value is used.
/// Amounts inside our JSON are minor-unit strings.
BigInt uncreditedInstallment(String? creditInfoJson) {
  if (creditInfoJson == null || creditInfoJson.isEmpty) return BigInt.zero;
  final Object? decoded;
  try {
    decoded = jsonDecode(creditInfoJson);
  } on FormatException {
    return BigInt.zero;
  }
  if (decoded is! Map) return BigInt.zero;
  BigInt minor(Object? v) => v is String
      ? (BigInt.tryParse(v) ?? BigInt.zero)
      : (v is int ? BigInt.from(v) : BigInt.zero);
  final inst = decoded['inst'];
  if (inst is List) {
    var total = BigInt.zero;
    for (final item in inst) {
      if (item is Map) total += minor(item['b']) + minor(item['i']);
    }
    return total;
  }
  return minor(decoded['installment']);
}

/// Net worth summary (docs/modules/asset-overview.md R2..R5). The caller has
/// already selected the candidate accounts for the current book (R1).
AssetOverview computeAssetOverview(
  Iterable<OverviewAccount> accounts,
  RateTable rates,
) {
  var asset = BigInt.zero, liabilities = BigInt.zero, installment = BigInt.zero;
  final missing = <String>{};
  for (final a in accounts) {
    if (a.status != AssetStatus.active) continue;
    var balance = a.balanceMinor;
    if (a.type == AssetType.debt) {
      // R2: debts with a currency are pre-converted; settled or non-positive -> 0.
      if (normalizeCurrency(a.currency) != null) {
        balance = rates.convert(
          balance,
          a.currency,
          rates.base,
          missing: missing,
        );
        if (a.status == AssetStatus.settled || balance <= BigInt.zero) {
          balance = BigInt.zero;
        }
      }
    }
    if (!a.counted) continue;
    if (a.type != AssetType.debt) {
      balance = rates.convert(
        balance,
        a.currency,
        rates.base,
        missing: missing,
      );
    }
    if (a.type == AssetType.credit) {
      final inst = rates.convert(
        uncreditedInstallment(a.creditInfo),
        a.currency,
        rates.base,
        missing: missing,
      );
      installment += inst;
      liabilities += inst;
    }
    final borrowed =
        a.type == AssetType.debt && a.subType == AssetType.debtBorrow;
    if (borrowed) {
      if (balance > BigInt.zero) {
        liabilities += balance;
      } else {
        asset += -balance;
      }
    } else {
      if (balance > BigInt.zero) {
        asset += balance;
      } else {
        liabilities += -balance;
      }
    }
  }
  return AssetOverview(
    totalAsset: asset,
    totalLiabilities: liabilities,
    totalInstallment: installment,
    missingRates: missing,
  );
}
