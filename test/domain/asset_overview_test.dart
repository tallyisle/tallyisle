import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tallyisle/domain/model/codes.dart';
import 'package:tallyisle/domain/rules/asset_overview.dart';

BigInt y(num yuan) => BigInt.from((yuan * 100).round());

/// Vectors: docs/modules/asset-overview.md §4 (02zu + 03zi).
void main() {
  final rates = RateTable({
    'CNY': '1',
    'USD': '0.125',
    'HKD': '1.25',
    'EUR': '0.15',
  });

  OverviewAccount acc(
    int id,
    num balance, {
    int type = AssetType.normal,
    int sub = -1,
    int? eff,
    String? currency = 'CNY',
    Object? credit,
  }) => OverviewAccount(
    id: id,
    type: type,
    subType: sub,
    balanceMinor: y(balance),
    isEffectiveAsset: eff ?? (type == AssetType.debt ? 0 : 1),
    currency: currency,
    creditInfo: credit == null ? null : jsonEncode(credit),
  );

  AssetOverview one(OverviewAccount a) => computeAssetOverview([a], rates);

  final book101 = <String, OverviewAccount>{
    'A01': acc(1, 1000),
    'A02': acc(2, 250.5, currency: ''),
    'A03': acc(3, -80),
    'A04': acc(
      4,
      -1200,
      type: AssetType.credit,
      credit: {
        'inst': [
          {'b': '30000', 'i': '1500'},
          {'b': '20000', 'i': '1000', 'cb': false},
        ],
      },
    ),
    'A05': acc(5, 150, type: AssetType.credit),
    'A06': acc(6, 300, type: AssetType.debt, sub: 100),
    'A07': acc(7, 500, type: AssetType.debt, sub: 99),
    'A08': acc(8, -40, type: AssetType.debt, sub: 100, currency: null),
    'A09': acc(9, 5000, eff: 0),
    'A10': acc(
      10,
      -600,
      type: AssetType.credit,
      eff: 0,
      credit: {'installment': '42000'},
    ),
    'A11': acc(11, 900, type: AssetType.debt, sub: 100, eff: 1),
    'A12': acc(12, 100, currency: ' usd '),
    'A13': acc(
      13,
      -250,
      type: AssetType.credit,
      currency: 'HKD',
      credit: {'installment': '10000'},
    ),
    'A14': acc(14, 50, type: AssetType.debt, sub: 100, currency: 'USD'),
    'A15': acc(15, 1, currency: 'EUR'),
    'A16': acc(16, 1, currency: 'EUR'),
    'A17': acc(17, 1000, currency: 'JPY'),
    'A22': acc(22, -40, type: AssetType.debt, sub: 100, currency: 'CNY'),
  };

  void expectDelta(String id, num asset, num liabilities) {
    final o = one(book101[id]!);
    expect(
      (o.totalAsset, o.totalLiabilities),
      (y(asset), y(liabilities)),
      reason: id,
    );
  }

  test('single-account deltas', () {
    expectDelta('A01', 1000, 0);
    expectDelta('A02', 250.5, 0);
    expectDelta('A03', 0, 80);
    expectDelta('A04', 0, 1725);
    expectDelta('A05', 150, 0);
    expectDelta('A06', 0, 300);
    expectDelta('A07', 500, 0);
    expectDelta('A08', 40, 0);
    expectDelta('A09', 0, 0);
    expectDelta('A10', 0, 0);
    expectDelta('A11', 0, 0);
    expectDelta('A12', 800, 0); // AO-F01: " usd " normalised
    expectDelta('A13', 0, 280);
    expectDelta('A14', 0, 400);
    expectDelta('A17', 1000, 0);
    expectDelta('A22', 0, 0);
  });

  test('per-account rounding: 2 x 1 EUR = 13.34, not 13.33', () {
    final o = computeAssetOverview([book101['A15']!, book101['A16']!], rates);
    expect(o.totalAsset, y(13.34));
  });

  test('missing JPY rate falls back 1:1 and is reported', () {
    expect(one(book101['A17']!).missingRates, {'JPY'});
  });

  test('book 101 totals', () {
    final o = computeAssetOverview(book101.values, rates);
    expect(o.totalAsset, y(3753.84));
    expect(o.totalLiabilities, y(2785));
    expect(o.netAsset, y(968.84));
  });

  test('hidden and settled accounts are excluded', () {
    final hidden = OverviewAccount(
      id: 1,
      type: 0,
      balanceMinor: y(10),
      isEffectiveAsset: 1,
      status: AssetStatus.hidden,
    );
    expect(computeAssetOverview([hidden], rates).totalAsset, BigInt.zero);
  });
}
